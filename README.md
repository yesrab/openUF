# openUF

[![Tests](https://github.com/jonasevcik/openUF/actions/workflows/test.yml/badge.svg)](https://github.com/jonasevcik/openUF/actions/workflows/test.yml)
[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)
[![Lua 5.1+](https://img.shields.io/badge/Lua-5.1%2B-blue.svg)](https://www.lua.org/)

openUF is a Lua daemon that makes an OpenWrt device appear as a **Ubiquiti UniFi U6-InWall** (or other UniFi AP models) to a UniFi Network Application controller.  The controller can then adopt the device, push SSID configuration, and display client statistics — all without genuine Ubiquiti hardware.

## What it does

| Feature | Status |
|---|---|
| L2 UDP discovery (port 10001) | ✅ Working |
| TNBU inform protocol (AES-128-CBC) | ✅ Working |
| Adoption via `syswrapper.sh set-adopt` | ✅ Working |
| L3 inform (`set-inform` before adoption) | Sends informs and appears Pending, but adoption does not complete against a real controller (see [PROTOCOL-VALIDATION.md](PROTOCOL-VALIDATION.md)) — use L2 adoption |
| Controller-pushed SSID provisioning | ✅ Working (UCI) |
| VLAN-tagged SSIDs (`network_table` join) | ✅ Working — field shapes unverified against a live capture |
| BSS Transition (802.11v, Behavior Controls) | ✅ Working (`bss_transition` UCI option) — confirmed live against a real controller |
| Auto 802.11 DTIM Period (Behavior Controls) | ✅ Working — always reads the controller's `dtim_period` (Auto and Custom both send a concrete value) — confirmed live against a real controller |
| Band Steering (Behavior Controls) | ✅ Working via `usteer` — requires the `usteer` package and a full `wpad` build (see Quick start); wire key confirmed live against a real controller |
| Show Access Point Name in Beacon (Behavior Controls) | ✅ Wire protocol confirmed live (requires reporting the `wifi_caps2` device capability bit); OpenWrt-side beacon effect uses the standard WPS Device Name element (`wps_device_name`), not independently verified against real hardware |
| SAE Anti-clogging / SAE Sync Time (WPA3-SAE tuning) | ✅ Wire key names and gating logic confirmed via decompile (`sae_anti_clogging_threshold`/`sae_sync` hostapd options); only sent by the controller when the WLAN is genuinely in WPA3/SAE mode, not the mixed "WPA2/WPA3" option — the emitting case wasn't reachable in this session's validation environment (see PROTOCOL-VALIDATION.md) |
| Wireless client & radio statistics in payload | ✅ Working (`vap_table[].sta_table`, `num_sta`, `radio_table_stats`) |
| Wired client statistics (`port_table[].mac_table`) | ✅ Working — U6-InWall's downstream switch ports report bridge-learned hosts as `is_wired` clients |
| Client block/unblock | ✅ Working — enforced via nftables (`block-sta`/`unblock-sta` cmd), persists across restarts |
| Locate (LED identify) | ✅ Working — requires `dev.conf.led` sysfs path set per board |
| RF/spectrum scan | Best-effort trigger only — result-reporting wire format unconfirmed |
| Environment / rogue-AP scanning (`scan_radio_table`) | ✅ Working — confirmed rendering live in the controller's Environment tab UI |
| Firmware upgrade requests | Stored (version/url), never applied — flashing controller-supplied firmware onto non-Ubiquiti hardware would brick it |
| LLDP topology announcement | ✅ Working (via lldpd) |
| AES-128-GCM (newer firmware flag) | Implemented, untested |
| Speed test | Not applicable — gateway-only feature in current UniFi Network, doesn't apply to APs |
| USG / USW emulation | Not implemented |

Tested against **UniFi Network Application 10.4.57**.  The device identity presented is **U6-InWall** (model `U6IW`).

## Supported hardware

Any OpenWrt device with at least 8 MB flash and a dual-band wireless chipset.  Known-working:

- **TP-Link WDR3500** (dual-band 802.11n) — use `modelmap/generic-dualband-ap.lua`
- **TP-Link Archer C5 v1** (dual-band 802.11n/ac) — use `modelmap/generic-dualband-ap.lua`
- **TP-Link WR1043ND v2** (single-band 802.11n) — use `modelmap/tl-wr1043ndv2.lua`

## Quick start

```sh
# 1. SSH into the OpenWrt device, install dependencies (OpenWrt 25.12+ uses apk)
apk update
apk add lua lua-cjson luasocket lua-openssl iw lldpd openssl-util usteer wpad-wolfssl

# 2. Download and install the latest release (no git client or scp needed)
mkdir openuf-install && cd openuf-install
wget https://github.com/jonasevcik/openUF/releases/latest/download/openuf.tar.gz
tar xzf openuf.tar.gz
sh install.sh install

# 3a. L2 adoption (device and controller on same subnet)
#     — The device will appear in UniFi Discover automatically.
#     — Click Adopt in the controller UI.

# 3b. L3 adoption (different subnets)
ssh root@<device> syswrapper.sh set-inform http://<controller-ip>:8080/inform
#     — The device will appear as pending in the controller.
#     — Click Adopt.
```

`install.sh install` automatically installs `usteer` and a full `wpad` build
(`wpad-wolfssl`, falling back to `wpad-openssl`) if either is missing — both are
required for BSS Transition (802.11v) and Band Steering to work at all.
`wpad-basic-*` builds lack 802.11v support entirely and will error with
"unknown configuration item 'bss_transition'"; if you've manually installed a
basic wpad build, replace it with `apk add wpad-wolfssl` first.

Installing from a git checkout instead (for contributors/dev builds) still works — `scp -r
openuf/ install.sh root@<device>:/tmp/openuf/` and run `install.sh` from there.

See [USAGE.md](USAGE.md) for full dependency details, configuration reference, and troubleshooting.

## Local testing (no hardware required)

```sh
# Install Lua on macOS/Linux
brew install lua luarocks      # macOS
# or: apt install lua5.1 luarocks  # Debian/Ubuntu

# Install test dependencies
luarocks install --local lua-cjson

# Run unit tests (all pure Lua)
eval $(luarocks path --local)
lua tests/run_tests.lua

# Full end-to-end adoption round-trip against the Python controller stub
# (needs pycryptodome, luasocket and lua-cjson):
sh tools/simulate.sh --adopt

# Or drive it manually:
pip install pycryptodome
python3 tools/test_controller.py --adopt --verbose
# In another terminal, run from inside the openuf/ dir (the scripts load
# conf.lua and the modelmap with cwd-relative paths):
cd openuf && lua inform.lua
```

## Protocol notes

openUF implements the **TNBU binary inform protocol**:

- HTTP POST to `/inform` every 10 seconds
- Binary header: `TNBU` magic + version + MAC + flags + 16-byte IV + data version + payload length
- Payload: zlib-compressed JSON, AES-128-CBC encrypted with the device's authkey
- Default pre-adoption key: `ba86f2bbe107c7c57eb5f2690775c712`
- Adoption: controller SSHes in and calls `syswrapper.sh set-adopt <url> <newkey>`

Key reference material:
- [PROTOCOL-VALIDATION.md](PROTOCOL-VALIDATION.md) — this project's own findings from running openUF against a real self-hosted UniFi controller; supersedes the below where they disagree
- [amd989/unifi-gateway](https://github.com/amd989/unifi-gateway) — primary protocol reference; live Python daemon tested against real controllers
- [jeffreykog/unifi-inform-protocol](https://github.com/jeffreykog/unifi-inform-protocol)
- [fxkr/unifi-protocol-reverse-engineering](https://github.com/fxkr/unifi-protocol-reverse-engineering)

## License

MIT — see [LICENSE](LICENSE).
