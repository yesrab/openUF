# openUF

[![Tests](https://github.com/jonasevcik/openUF/actions/workflows/test.yml/badge.svg)](https://github.com/jonasevcik/openUF/actions/workflows/test.yml)
[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)
[![Lua 5.1+](https://img.shields.io/badge/Lua-5.1%2B-blue.svg)](https://www.lua.org/)

openUF is a Lua daemon that makes an OpenWrt device appear as a **Ubiquiti UniFi U6-InWall** (or other UniFi AP models) to a UniFi Network Application controller.  The controller can then adopt the device, push SSID and network configuration, and display live client and radio statistics — all without genuine Ubiquiti hardware.

Tested end-to-end against **UniFi Network Application 10.4.57**.  The default device identity presented is **U6-InWall** (model `U6IW`).  openUF emulates a UniFi **access point** only — gateway (USG) and switch (USW) emulation are not implemented and not planned.

Most rows below marked ✅ were verified by driving the real controller UI against a live openUF device and reading back the resulting wire capture; [PROTOCOL-VALIDATION.md](PROTOCOL-VALIDATION.md) records the evidence, including where a claim rests on decompiling the controller rather than a live capture.

## What it does

### Adoption and transport

| Feature | Status |
|---|---|
| L2 UDP discovery (port 10001) | ✅ Working |
| TNBU inform protocol | ✅ Working — AES-128-CBC and AES-128-GCM |
| AES-128-GCM | ✅ Working — **required**: 10.4.57 will not finish provisioning a device until it receives a genuine GCM inform. Needs a GCM-capable `lua-openssl` build |
| L2 adoption (SSH `syswrapper.sh set-adopt`) | ✅ Working — completes to **Connected** |
| L3 adoption (`set-inform`, different subnets) | ✅ Working — the controller skips SSH entirely and delivers the new authkey in the `setparam` `mgmt_cfg`; openUF accepts it only while unadopted |
| Zero-touch bootstrap adoption | ✅ Optional (`install.sh install --bootstrap-adopt`) — a locked-down, non-root SSH account auto-disabled after adoption |
| Forget device / factory reset | ✅ Working (`syswrapper.sh reset-inform`) |
| Restart / reboot command | ✅ Working |
| Firmware upgrade requests | Stored (version/url), never applied — flashing controller-supplied firmware onto non-Ubiquiti hardware would brick it |

### WiFi provisioning

| Feature | Status |
|---|---|
| Controller-pushed SSID provisioning | ✅ Working (UCI); only `openuf_`-prefixed sections are created or deleted |
| Exclusive-WLAN mode (`use_only_unifi_wlan`) | ✅ Working — default `true` disables hand-configured SSIDs so the radios carry only what the controller pushed; reversible (openUF stamps what it disabled) |
| WPA2 / WPA3 / WPA2-WPA3 mixed security | ✅ Working — derived from the pushed AKM set |
| PMF / 802.11w (`ieee80211w`) | ✅ Working — from `aaa.<n>.pmf.status`/`pmf.mode`; also what carries WPA3-transition intent on a mixed WLAN |
| Fast Roaming (802.11r) | ✅ Working |
| VLAN-tagged SSIDs | ✅ Working — from `aaa.<n>.br.devname` (`br0.<vlan>`), the wire's only VLAN signal; bridges onto a matching per-VLAN device |
| Channel and TX power per radio | ✅ Working (Low/Medium/High/Custom) |
| Channel width per radio | ✅ Working — from `radio.<n>.ieee_mode` (`11nght20`/`11naht40`/…) → `htmode`. This is also the only 802.11n/ac/ax mode signal the wire carries |
| IoT Optimization: Lock 2.4 GHz to Channel 6 / DTIM Interval Lock | ✅ Working — both are controller-side shortcuts that arrive as an ordinary `radio.<n>.channel=6` and `dtim_period=3`, needing no dedicated handling |
| IoT Optimization: Force WiFi 4 Mode | ✅ Wire protocol confirmed live (`wireless.<n>.iot` + `qbssload`); most of the mode arrives as ordinary keys (2.4 GHz-only, WPA2, PMF/BSS-transition/proxy-ARP off). Its one distinct effect, suppressing the QBSS Load IE via `bss_load_update_period`, is not verified against real hardware |
| BSS Transition (802.11v) | ✅ Working (`bss_transition`) — needs a full `wpad` build |
| Band Steering | ✅ Working via `usteer` — requires the `usteer` package and a full `wpad` build (see Quick start) |
| Auto 802.11 DTIM Period | ✅ Working — Auto and Custom both arrive as a concrete `dtim_period` |
| Multicast Enhancement (multicast-to-unicast) | ✅ Working — from `wireless.<n>.mcast.enhance` |
| Multicast and Broadcast Blocker | ⚠️ Wire protocol confirmed live (`wireless.<n>.bcfilt.*`). No hostapd/OpenWrt option exists for it, so it is enforced with nftables in a dedicated `bridge openuf_bcfilt` table; the generated ruleset is verified against real `nft`, but its on-air effect is not (no real radios available). **Blocks LAN→WLAN broadcast/multicast except from allow-listed source MACs — this breaks DHCP for wireless clients unless the DHCP server's MAC is on the list**, which is Ubiquiti's own documented behavior |
| Minimum Data Rate Control | ✅ Wire protocol confirmed live (`wireless.<n>.minrate_data` + `beacon_rate`/`minrate_cck_rates.status`/`minrate_below_disable`). Applied per **radio** — OpenWrt's `basic_rate`/`supported_rates`/`legacy_rates`/`beacon_rate` are `wifi-device` options, so WLANs sharing a radio collapse to the most permissive floor |
| Proxy ARP | ✅ Wire protocol confirmed live (`aaa.<n>.proxy_arp`) → `proxy_arp`. Needs a full `wpad` build (hostapd only compiles proxy-ARP support in with `CONFIG_PROXYARP`) |
| Client Isolation | ✅ Wire protocol confirmed live (`wireless.<n>.l2_isolation`) → `isolate` (hostapd `ap_isolate`) |
| Hide WiFi Name | ✅ Wire protocol confirmed live (`wireless.<n>.hide_ssid`, duplicated as `aaa.<n>.hide_ssid`) → `hidden` (hostapd `ignore_broadcast_ssid`) |
| Minimum RSSI | ✅ Working — per **radio**, not per WLAN; enforced by deauthenticating clients below the threshold (a one-shot kick, not a persistent block) |
| Show Access Point Name in Beacon | ✅ Wire protocol confirmed live (requires reporting the `wifi_caps2` capability bit); the OpenWrt-side beacon effect uses the standard WPS Device Name element, not independently verified against real hardware |
| SAE Anti-clogging / SAE Sync Time | ⚠️ Implemented from a decompile of the controller's WLAN-config generator. The controller only emits these for a genuine WPA3/SAE WLAN — not the mixed "WPA2/WPA3" option — and that emitting case was never reachable in the validation environment, so it is unconfirmed on the wire |

### Reporting and statistics

| Feature | Status |
|---|---|
| Wireless client statistics | ✅ Working — per-client traffic, signal, MIMO/generation, TX MCS (`vap_table[].sta_table`) |
| Radio statistics | ✅ Working — channel utilization, avg. signal/interference/airtime, per-VAP "Air Stats" |
| WiFi Experience / satisfaction score | ✅ Working — device-computed, confirmed rendering live |
| Wired client statistics (`port_table[].mac_table`) | ✅ Working — bridge-learned hosts on downstream switch ports report as `is_wired` clients |
| Environment / rogue-AP scanning (`scan_radio_table`) | ✅ Working — confirmed rendering live in the Environment tab |
| LLDP topology announcement | ✅ Working (via `lldpd`) |
| RF/spectrum scan | ⚠️ Best-effort trigger only — the result-reporting wire format is unconfirmed |

### Device management

| Feature | Status |
|---|---|
| Locate (LED identify blink) | ✅ Working — requires `dev.conf.led` set per board |
| Manage → LED steady on/off toggle | ✅ Working — same `dev.conf.led` requirement |
| Client block / unblock | ✅ Working — enforced via nftables, persists across restarts |
| IP Settings (DHCP / static) | ✅ Working — reconfigures the device's own management interface |
| Per-port VLAN assignment | ✅ Working — requires reporting the `hasOWRTSwitch` capability bit |
| Set Replacement Device / Load Configuration | ✅ Working — both are controller-side clones; no device-side protocol involved |
| Power / PoE reporting | Not applicable — the flagged UI field belongs to the upstream parent device, not the AP |
| Speed test | Not applicable — gateway-only feature in current UniFi Network |
| USG / USW emulation | Not implemented, not planned |

## Supported hardware

Any OpenWrt device with at least 8 MB flash and a dual-band wireless chipset.  Known-working:

- **TP-Link WDR3500** (dual-band 802.11n) — use `modelmap/generic-dualband-ap.lua`
- **TP-Link Archer C5 v1** (dual-band 802.11n/ac) — use `modelmap/generic-dualband-ap.lua`
- **TP-Link WR1043ND v2** (single-band 802.11n) — use `modelmap/tl-wr1043ndv2.lua`

The *modelmap* describes your real hardware; the *ufmodel* picks the UniFi identity to present.  `ufmodel/u6iw.lua` (U6-InWall) is the default and the only one validated end-to-end — `uapg1`, `uapg1-lr`, and `uapg2-ac-lr` are also provided but untested.

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

# 3b. L3 adoption (different subnets — no SSH from the controller needed)
ssh root@<device> syswrapper.sh set-inform http://<controller-ip>:8080/inform
#     — The device will appear as Pending in the controller.
#     — Click Adopt.
```

Both adoption paths complete to **Connected**.  L2 requires the controller to
SSH in (set a root password first, or use `--bootstrap-adopt`); L3 skips SSH
entirely and delivers the adoption key over the inform channel.

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
- Payload: JSON, AES-128 encrypted with the device's authkey — CBC, or GCM (with a
  40-byte AAD) once the controller sets `use_aes_gcm`.  Controller responses may be
  zlib-compressed; openUF decompresses them with a bundled pure-Lua inflater
- Default pre-adoption key: `ba86f2bbe107c7c57eb5f2690775c712`
- Adoption: L2 — controller SSHes in and calls `syswrapper.sh set-adopt <url> <newkey>`;
  L3 — new authkey arrives in the `setparam` response's `mgmt_cfg`

Key reference material:
- [PROTOCOL-VALIDATION.md](PROTOCOL-VALIDATION.md) — this project's own findings from running openUF against a real self-hosted UniFi controller; supersedes the below where they disagree
- [amd989/unifi-gateway](https://github.com/amd989/unifi-gateway) — primary protocol reference; live Python daemon tested against real controllers
- [jeffreykog/unifi-inform-protocol](https://github.com/jeffreykog/unifi-inform-protocol)
- [fxkr/unifi-protocol-reverse-engineering](https://github.com/fxkr/unifi-protocol-reverse-engineering)

## License

MIT — see [LICENSE](LICENSE).
