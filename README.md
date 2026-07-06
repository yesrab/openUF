# openUF

openUF is a Lua daemon that makes an OpenWrt device appear as a **Ubiquiti UniFi U6-InWall** (or other UniFi AP models) to a UniFi Network Application controller.  The controller can then adopt the device, push SSID configuration, and display client statistics — all without genuine Ubiquiti hardware.

## What it does

| Feature | Status |
|---|---|
| L2 UDP discovery (port 10001) | ✅ Working |
| TNBU inform protocol (AES-128-CBC) | ✅ Working |
| Adoption via `syswrapper.sh set-adopt` | ✅ Working |
| L3 inform (`set-inform` before adoption) | ✅ Working |
| Controller-pushed SSID provisioning | ✅ Working (UCI) |
| Client & radio statistics in payload | ✅ Working |
| LLDP topology announcement | ✅ Working (via lldpd) |
| AES-128-GCM (newer firmware flag) | Implemented, untested |
| USG / USW emulation | Not implemented |

Tested against **UniFi Network Application 10.4.57**.  The device identity presented is **U6-InWall** (model `U6IW`).

## Supported hardware

Any OpenWrt device with at least 8 MB flash and a dual-band wireless chipset.  Known-working:

- **TP-Link WDR3500** (dual-band 802.11n) — use `modelmap/generic-dualband-ap.lua`
- **TP-Link Archer C5 v1** (dual-band 802.11n/ac) — use `modelmap/generic-dualband-ap.lua`
- **TP-Link WR1043ND v2** (single-band 802.11n) — use `modelmap/tl-wr1043ndv2.lua`

## Quick start

```sh
# 1. Install dependencies on the OpenWrt device
opkg update
opkg install lua lua-cjson lua-lzlib luacrypto iw lldpd

# 2. Transfer files and install
scp -r openuf/ install.sh root@<device>:/tmp/openuf-install/
ssh root@<device> "cd /tmp/openuf-install && sh install.sh install"

# 3a. L2 adoption (device and controller on same subnet)
#     — The device will appear in UniFi Discover automatically.
#     — Click Adopt in the controller UI.

# 3b. L3 adoption (different subnets)
ssh root@<device> syswrapper.sh set-inform http://<controller-ip>:8080/inform
#     — The device will appear as pending in the controller.
#     — Click Adopt.
```

See [USAGE.md](USAGE.md) for full dependency details, configuration reference, and troubleshooting.

## Local testing (no hardware required)

```sh
# Install Lua on macOS/Linux
brew install lua luarocks      # macOS
# or: apt install lua5.1 luarocks  # Debian/Ubuntu

# Install test dependencies
luarocks install --local lua-cjson

# Run unit tests (66 tests, all pure Lua)
eval $(luarocks path --local)
lua tests/run_tests.lua

# Run the Python controller stub (simulates adoption handshake)
pip install pycryptodome
python3 tools/test_controller.py --adopt --verbose
# In another terminal: lua openuf/inform.lua  (needs luasocket on dev machine)
```

## Protocol notes

openUF implements the **TNBU binary inform protocol**:

- HTTP POST to `/inform` every 10 seconds
- Binary header: `TNBU` magic + version + MAC + flags + 16-byte IV + data version + payload length
- Payload: zlib-compressed JSON, AES-128-CBC encrypted with the device's authkey
- Default pre-adoption key: `ba86f2bbe107c7c57eb5f2690775c712`
- Adoption: controller SSHes in and calls `syswrapper.sh set-adopt <url> <newkey>`

Key reference material:
- [jeffreykog/unifi-inform-protocol](https://github.com/jeffreykog/unifi-inform-protocol)
- [fxkr/unifi-protocol-reverse-engineering](https://github.com/fxkr/unifi-protocol-reverse-engineering)

## Differences from Coll147/OpenUniFi

The [Coll147/OpenUniFi](https://github.com/Coll147/OpenUniFi) C-language fork carried two bugs not present here:

1. **authkey injection via setparam** — the controller's `setparam` response should never update the authkey; only `set-adopt` (SSH) can do that.  The C port updated the key from JSON, which allows key substitution attacks.
2. **Announce packet length off-by-one** — the original Lua code and the C port both wrote only the low byte of the 16-bit packet length field.  Packets > 255 bytes were misreported.  Both bugs are fixed in this version.

## License

MIT — see LICENSE file (or add one if absent).
