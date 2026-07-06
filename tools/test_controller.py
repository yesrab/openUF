#!/usr/bin/env python3
"""
test_controller.py — minimal UniFi controller stub for local development.

Listens on HTTP port 8080, handles POST /inform from openUF devices, and
responds with TNBU-framed JSON payloads.  Use --adopt to simulate the full
adoption handshake on first contact.

Usage:
  python3 tools/test_controller.py [--port PORT] [--adopt] [--verbose]

Requirements (host only, not OpenWrt):
  pip install pycryptodome
"""

import argparse
import json
import os
import secrets
import struct
import sys
import zlib
from http.server import BaseHTTPRequestHandler, HTTPServer
from typing import Optional, Tuple

# Default pre-adoption key (hex) — must match state.DEFAULT_KEY in state.lua
DEFAULT_KEY_HEX = "ba86f2bbe107c7c57eb5f2690775c712"

# TNBU packet flags
FLAG_ENCRYPTED  = 0x01
FLAG_COMPRESSED = 0x02
FLAG_GCM        = 0x08

# ──────────────────────────────────────────────────────────────────────────────
# Crypto helpers
# ──────────────────────────────────────────────────────────────────────────────

def _import_crypto():
    try:
        from Crypto.Cipher import AES
        return AES
    except ImportError:
        print("ERROR: pycryptodome not installed.  Run: pip install pycryptodome",
              file=sys.stderr)
        sys.exit(1)

def aes_cbc_decrypt(key_hex: str, iv: bytes, ciphertext: bytes) -> bytes:
    AES = _import_crypto()
    key = bytes.fromhex(key_hex)
    cipher = AES.new(key, AES.MODE_CBC, iv)
    padded = cipher.decrypt(ciphertext)
    # PKCS#7 unpad
    pad_len = padded[-1]
    return padded[:-pad_len]

def aes_cbc_encrypt(key_hex: str, iv: bytes, plaintext: bytes) -> bytes:
    AES = _import_crypto()
    key = bytes.fromhex(key_hex)
    # PKCS#7 pad
    pad_len = 16 - (len(plaintext) % 16)
    plaintext += bytes([pad_len] * pad_len)
    cipher = AES.new(key, AES.MODE_CBC, iv)
    return cipher.encrypt(plaintext)

def aes_gcm_decrypt(key_hex: str, iv: bytes, ciphertext: bytes, tag: bytes) -> bytes:
    AES = _import_crypto()
    key = bytes.fromhex(key_hex)
    cipher = AES.new(key, AES.MODE_GCM, nonce=iv)
    return cipher.decrypt_and_verify(ciphertext, tag)

def aes_gcm_encrypt(key_hex: str, iv: bytes, plaintext: bytes) -> Tuple[bytes, bytes]:
    AES = _import_crypto()
    key = bytes.fromhex(key_hex)
    cipher = AES.new(key, AES.MODE_GCM, nonce=iv)
    ciphertext, tag = cipher.encrypt_and_digest(plaintext)
    return ciphertext, tag

# ──────────────────────────────────────────────────────────────────────────────
# TNBU packet framing
# ──────────────────────────────────────────────────────────────────────────────

def decode_packet(raw: bytes, key_hex: str) -> Tuple[dict, int]:
    """
    Parse a TNBU packet, decrypt and decompress the payload.

    Returns (payload_dict, flags) or raises ValueError.
    """
    if len(raw) < 40:
        raise ValueError(f"packet too short: {len(raw)} bytes")
    magic = raw[:4]
    if magic != b"TNBU":
        raise ValueError(f"bad magic: {magic!r}")

    _pkt_ver  = struct.unpack_from(">I", raw, 4)[0]
    mac       = raw[8:14]
    flags     = struct.unpack_from(">H", raw, 14)[0]
    iv        = raw[16:32]
    _data_ver = struct.unpack_from(">I", raw, 32)[0]
    plen      = struct.unpack_from(">I", raw, 36)[0]
    payload   = raw[40:40 + plen]

    if flags & FLAG_ENCRYPTED:
        if flags & FLAG_GCM:
            ct, tag = payload[:-16], payload[-16:]
            payload = aes_gcm_decrypt(key_hex, iv, ct, tag)
        else:
            payload = aes_cbc_decrypt(key_hex, iv, payload)

    if flags & FLAG_COMPRESSED:
        payload = zlib.decompress(payload)

    return json.loads(payload.decode()), flags, mac


def encode_packet(payload_dict: dict, key_hex: str, mac: bytes = b"\x00" * 6) -> bytes:
    """
    Build a TNBU packet containing an AES-128-CBC encrypted JSON payload.
    """
    payload = json.dumps(payload_dict).encode()

    # Compress if worthwhile
    compressed = zlib.compress(payload)
    flags = FLAG_ENCRYPTED
    if len(compressed) < len(payload):
        payload = compressed
        flags |= FLAG_COMPRESSED

    iv = os.urandom(16)
    ciphertext = aes_cbc_encrypt(key_hex, iv, payload)

    return (
        b"TNBU"
        + struct.pack(">I", 0)    # pkt_version
        + mac
        + struct.pack(">H", flags)
        + iv
        + struct.pack(">I", 1)    # data_version (JSON)
        + struct.pack(">I", len(ciphertext))
        + ciphertext
    )

# ──────────────────────────────────────────────────────────────────────────────
# HTTP handler
# ──────────────────────────────────────────────────────────────────────────────

class ControllerState:
    """Mutable state shared across all requests."""
    def __init__(self, do_adopt: bool, verbose: bool):
        self.do_adopt   = do_adopt
        self.verbose    = verbose
        self.current_key = DEFAULT_KEY_HEX
        self.adopted    = False
        self.request_count = 0


class InformHandler(BaseHTTPRequestHandler):
    state: ControllerState  # injected by factory

    def log_message(self, fmt, *args):
        if self.state.verbose:
            super().log_message(fmt, *args)

    def do_POST(self):
        if self.path != "/inform":
            self.send_response(404)
            self.end_headers()
            return

        length = int(self.headers.get("Content-Length", 0))
        body   = self.rfile.read(length)
        self.state.request_count += 1

        try:
            payload, flags, mac = decode_packet(body, self.state.current_key)
        except Exception as exc:
            print(f"[{self.state.request_count}] DECODE ERROR: {exc}", file=sys.stderr)
            self.send_response(400)
            self.end_headers()
            return

        mac_str = ":".join(f"{b:02x}" for b in mac)
        print(f"\n[{self.state.request_count}] inform from {mac_str}  "
              f"flags=0x{flags:02x}  adopted={payload.get('default', True) == False}")
        if self.state.verbose:
            print(json.dumps(payload, indent=2))
        else:
            # Short summary
            for key in ("model", "version", "ip", "uptime", "cfgversion"):
                if key in payload:
                    print(f"  {key}: {payload[key]}")
            if payload.get("sta_table"):
                print(f"  clients: {len(payload['sta_table'])}")

        # Build response
        if self.state.do_adopt and not self.state.adopted:
            new_key = secrets.token_hex(16)
            self.state.current_key = new_key
            self.state.adopted     = True
            resp = {
                "_type":    "setparam",
                "mgmt_cfg": {
                    "inform_url": f"http://{self.server.server_address[0]}:"
                                  f"{self.server.server_address[1]}/inform",
                },
            }
            print(f"  → ADOPTING with new authkey: {new_key}")
            print("  NOTE: run this on the device to complete adoption:")
            print(f"    syswrapper.sh set-adopt http://... {new_key}")
        else:
            resp = {"_type": "noop"}

        response_pkt = encode_packet(resp, self.state.current_key, mac)
        self.send_response(200)
        self.send_header("Content-Type",   "application/x-binary")
        self.send_header("Content-Length", str(len(response_pkt)))
        self.end_headers()
        self.wfile.write(response_pkt)


def make_handler(state: ControllerState):
    """Return an InformHandler subclass with state injected."""
    class BoundHandler(InformHandler):
        pass
    BoundHandler.state = state
    return BoundHandler


def main():
    parser = argparse.ArgumentParser(
        description="openUF test controller stub"
    )
    parser.add_argument("--port",    type=int, default=8080,
                        help="TCP port to listen on (default: 8080)")
    parser.add_argument("--adopt",   action="store_true",
                        help="simulate adoption on first inform (prints new authkey)")
    parser.add_argument("--verbose", action="store_true",
                        help="print full JSON payload for each inform")
    args = parser.parse_args()

    state   = ControllerState(do_adopt=args.adopt, verbose=args.verbose)
    handler = make_handler(state)
    server  = HTTPServer(("0.0.0.0", args.port), handler)

    print(f"openUF test controller listening on port {args.port}")
    print(f"  adoption mode: {'ON (--adopt)' if args.adopt else 'OFF (noop only)'}")
    print(f"  current key:   {state.current_key}")
    print(f"  Press Ctrl+C to stop")

    try:
        server.serve_forever()
    except KeyboardInterrupt:
        print("\nStopped.")


if __name__ == "__main__":
    main()
