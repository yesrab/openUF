# openUF

[![Tests](https://github.com/yesrab/openUF/actions/workflows/test.yml/badge.svg)](https://github.com/yesrab/openUF/actions/workflows/test.yml)
[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)
[![Lua 5.1+](https://img.shields.io/badge/Lua-5.1%2B-blue.svg)](https://www.lua.org/)

openUF is a Lua daemon that makes an OpenWrt device appear as a **Ubiquiti UniFi U6-InWall** (or other UniFi AP models) to a UniFi Network Application controller.  The controller can then adopt the device, push SSID and network configuration, and display live client and radio statistics — all without genuine Ubiquiti hardware.

Tested end-to-end against **UniFi Network Application 10.4.57** — both a self-hosted Docker controller and a real UniFi Cloud Gateway Ultra adopting a TP-Link Archer C5 v1 running openUF, with real clients associating to the pushed SSID.  The default device identity presented is **U6-InWall** (model `U6IW`).  openUF emulates a UniFi **access point** only — gateway (USG) and switch (USW) emulation are not implemented and not planned.

Most rows below marked ✅ were verified by driving the real controller UI against a live openUF device and reading back the resulting wire capture; [PROTOCOL-VALIDATION.md](PROTOCOL-VALIDATION.md) records the evidence, including where a claim rests on decompiling the controller rather than a live capture.

## What it does

### Adoption and transport

| Feature | Status |
|---|---|
| L2 UDP discovery (port 10001) | ✅ Working |
| TNBU inform protocol | ✅ Working — AES-128-CBC and AES-128-GCM |
| AES-128-GCM | ✅ Working — **required**: 10.4.57 will not finish provisioning a device until it receives a genuine GCM inform. Needs a GCM-capable `lua-openssl` build |
| L2 adoption (SSH `syswrapper.sh set-adopt`) | ✅ Working — completes to **Connected** |
| L3 adoption (`set-inform`, no SSH) | ✅ Working — the controller skips SSH entirely and delivers the new authkey in the `setparam` `mgmt_cfg`; openUF accepts it only while unadopted. The controller chooses this path when it has *not* discovered the device via broadcast, which is what `config.l2_announce = false` is for — same-subnet devices that can't accept an SSH login need it |
| Zero-touch bootstrap adoption | ✅ Optional (`install.sh install --bootstrap-adopt`) — a locked-down, non-root SSH account auto-disabled after adoption |
| Forget device / factory reset | ✅ Working (`syswrapper.sh reset-inform`) |
| Restart / reboot command | ✅ Working |
| Firmware upgrade requests | Stored (version/url), never applied — flashing controller-supplied firmware onto non-Ubiquiti hardware would brick it |

### WiFi provisioning

| Feature | Status |
|---|---|
| Controller-pushed SSID provisioning | ✅ Working (UCI); only `openuf_`-prefixed sections are created or deleted |
| Exclusive-WLAN mode (`use_only_unifi_wlan`) | ✅ Working — default `true` disables hand-configured SSIDs so the radios carry only what the controller pushed; reversible (openUF stamps what it disabled). Non-AP interfaces (mesh point, station — a wireless backhaul) are never touched, and `keep_wlan_sections` exempts named AP sections |
| WPA2 / WPA3 / WPA2-WPA3 mixed security | ✅ Working — derived from the pushed AKM set plus `wpa3.support`/`wpa3.transition`. Requires `radio_caps2` bit `0x1` on each radio, which openUF sends when hostapd can really do SAE — without it the controller silently downgrades every WPA3 WLAN to WPA2. **WPA-Enterprise (802.1X) is not supported**: the wire protocol carries no RADIUS server, port or secret, so such a WLAN is skipped with a log line rather than mis-provisioned as a keyless WPA2 SSID |
| PMF / 802.11w (`ieee80211w`) | ✅ Working — from `aaa.<n>.pmf.status`/`pmf.mode`. PMF is just PMF: the WPA3-transition signal is `wpa3.support`/`wpa3.transition`, not these keys |
| Fast Roaming (802.11r) | ✅ Working — both the WLAN-level `ft.status` and the SAE-only `wpa3.ft.status` are read; FT is enabled if either asks for it, since OpenWrt cannot enable 802.11r for one AKM alone |
| VLAN-tagged SSIDs | ✅ Working — verified end-to-end on real hardware with a client on a tagged IoT network. From `aaa.<n>.br.devname` (`br0.<vlan>`), the wire's only VLAN signal: openUF builds a `br-openuf<id>` bridge holding the tagged uplink sub-device, joins the VAP to it, and trunks the VID through a swconfig switch — tagging the CPU port and the uplink socket only, never the LAN sockets, since on `ar8216`-family switches the tag flag is one global per-port bitmask and tagging a socket for the IoT VLAN makes it egress-tagged in VLAN 1 too, deafening the untagged wired client on it. Keep VLAN ids **below the switch's VLAN table size** (16 on some boards) — netifd has no `vid` option, so the id doubles as the table slot |
| Channel and TX power per radio | ✅ Working (Low/Medium/High/Custom; channel **Auto** is written through as UCI `channel=auto`, i.e. hostapd ACS picks on the AP; TX power **Auto** deletes the `txpower` option so the driver default applies again) |
| Radio enable / disable | ✅ Working — Transmit Power → **Disabled** arrives as `radio.<n>.status=disabled` (plus `wireless.<n>.status` on each of that radio's WLANs) → UCI `disabled`. Only an explicit value is written, so a push that omits the key leaves a hand-disabled radio alone |
| Device identity vs. management MAC | ✅ openUF identifies by `dev.conf.net.lan_cpueth`'s MAC but reports the IP of the bridge that port is enslaved to. Where those are different netdevs — a DSA map naming a socket that carries the label MAC while `br-lan` inherits the conduit's — the AP claims an address that ARP attributes to a different MAC, and the gateway raises an IP conflict against a correctly configured network. `ucihelper.ensure_bridge_identity` pins the bridge to the identity MAC at startup, only when they differ (upstream verified it on the AX3000T, including the no-op path on a swconfig board). This fork's JioRouter maps name `br-lan` itself, so it is a no-op there |
| Channel width per radio | ✅ Working — from `radio.<n>.ieee_mode` (`11nght20`/`11naht40`/…) → `htmode`, clamped down to what `iw phy` says the radio supports (a WiFi-6 identity invites HE pushes at n/ac hardware, which hostapd would refuse to start on). This is also the only 802.11n/ac/ax mode signal the wire carries |
| IoT Optimization: Lock 2.4 GHz to Channel 6 / DTIM Interval Lock | ✅ Working — both are controller-side shortcuts that arrive as an ordinary `radio.<n>.channel=6` and `dtim_period=3`, needing no dedicated handling |
| IoT Optimization: Force WiFi 4 Mode | ✅ Working — **verified end to end on real hardware**. Most of the mode arrives as ordinary keys (2.4 GHz-only, WPA2, PMF/BSS-transition off) and its one distinct effect, suppressing the QBSS Load IE, reaches hostapd as `bss_load_update_period=0` — read back out of a live `hostapd-phy0.conf`. Note it does **not** change `radio.<n>.ieee_mode`: the radio keeps its configured width, so on a board with a `dev.conf.radio.<band>.htmode_floor` that floor is suppressed for the radio while any WLAN on it has the mode on, or the HE IEs the mode exists to remove go straight back into the beacon |
| BSS Transition (802.11v) | ✅ Working (`bss_transition`) — needs a full `wpad` build |
| Band Steering | ✅ Working via `usteer` — requires the `usteer` package and a full `wpad` build (see Quick start) |
| Auto 802.11 DTIM Period | ✅ Working — Auto and Custom both arrive as a concrete `dtim_period` |
| Multicast Enhancement (multicast-to-unicast) | ✅ Working — from `wireless.<n>.mcast.enhance` |
| Multicast and Broadcast Blocker | ⚠️ Wire protocol confirmed live (`wireless.<n>.bcfilt.*`). No hostapd/OpenWrt option exists for it, so it is enforced with nftables in a dedicated `bridge openuf_bcfilt` table; the generated ruleset is verified against real `nft`, but its on-air effect is not (no real radios available). **Blocks LAN→WLAN broadcast/multicast except from allow-listed source MACs — this breaks DHCP for wireless clients unless the DHCP server's MAC is on the list**, which is Ubiquiti's own documented behavior. The ruleset is rebuilt from UCI on every start, so it survives a reboot the controller does not re-push after |
| Minimum Data Rate Control | ✅ Wire protocol confirmed live (`wireless.<n>.minrate_data` + `beacon_rate`/`minrate_cck_rates.status`/`minrate_below_disable`). Applied per **radio** — OpenWrt's `basic_rate`/`supported_rates`/`legacy_rates`/`beacon_rate` are `wifi-device` options, so WLANs sharing a radio collapse to the most permissive floor. Turning the control off tears the options down again (marker-tracked, hand-tuned rates untouched) |
| Proxy ARP | ✅ Wire protocol confirmed live (`aaa.<n>.proxy_arp`) → `proxy_arp`. Needs a full `wpad` build (hostapd only compiles proxy-ARP support in with `CONFIG_PROXYARP`) |
| Client Isolation | ✅ Wire protocol confirmed live (`wireless.<n>.l2_isolation`) → `isolate` (hostapd `ap_isolate`) |
| Hide WiFi Name | ✅ Wire protocol confirmed live (`wireless.<n>.hide_ssid`, duplicated as `aaa.<n>.hide_ssid`) → `hidden` (hostapd `ignore_broadcast_ssid`) |
| MAC Address Filter | ✅ Wire protocol confirmed live. Arrives in a top-level `macacl.<m>.*` section keyed by **devname**, not by WLAN index, so it is joined on `wireless.<n>.devname` → `macfilter` + `maclist`. Allow/deny policy maps 1:1 onto OpenWrt's; enforced by hostapd itself |
| WiFi Speed Limit | ⚠️ Wire protocol confirmed live (top-level `qos.vap.<m>.*`, joined on devname; kbps; a **per-VAP aggregate** cap, not per-client). Needs a speed-limit profile to exist in site settings before the per-WLAN toggle emits anything. No hostapd/OpenWrt option expresses a throughput cap, so it is enforced with `tc` — HTB on egress for downlink, ingress policing for uplink. The generated commands are verified against real `tc`, but the on-air throughput is not (no real radios available). The qdiscs are rebuilt from UCI on every start, so the cap survives a reboot |
| Minimum RSSI | ✅ Working — per **radio**, not per WLAN; enforced by deauthenticating clients below the threshold (a one-shot kick, not a persistent block). Disabling it in the controller stops the enforcement (the wire signals disable by omitting the whole `stamgr.<n>` block) |
| Show Access Point Name in Beacon | ❌ **Not implemented on the OpenWrt side.** The wire protocol and its `wifi_caps2` bit `0x40` gating are confirmed live, and openUF writes `wps_device_name`/`ap_setup_locked` — but a beacon never carries the name. OpenWrt emits the whole WPS/WSC block, `device_name` included, only when `config_methods` is non-empty, which needs `wps_pushbutton` or `wps_label`; openUF sets neither, so WPS never activates. Upstream verified this 2026-09-10 on an Archer C5 and an AX3000T (both 25.12.5): the gate is `/usr/share/ucode/wifi/ap.uc:227`, and no live BSS config carries a single WPS key. Enabling WPS to broadcast a name is a real security surface for a cosmetic feature, so this is left unimplemented deliberately |
| SAE Anti-clogging / SAE Sync Time | ❌ **Not applicable on OpenWrt.** The wire keys (`aaa.<n>.sae.anti_clogging` / `.sae.sync`) are real and emitted only for a genuine WPA3/SAE WLAN, but `sae_anti_clogging_threshold` and `sae_sync` are hostapd keys with **no** wifi-iface UCI option behind them — upstream checked the wifi-iface schema, `/usr/share/ucode/wifi/` and `hostapd.sh`'s `config_add_*` lists on two boards (25.12.5) and found neither. openUF used to write them; UCI stored them and the generator dropped them in silence. Removed, along with the parser fields nothing could consume |

### Reporting and statistics

| Feature | Status |
|---|---|
| Wireless client statistics | ✅ Working — per-client traffic, signal, MIMO/generation, TX MCS (`vap_table[].sta_table`) |
| Radio statistics | ✅ Working — channel utilization, avg. signal/interference/airtime, per-VAP "Air Stats" |
| WiFi Experience / satisfaction score | ✅ Working — device-computed, confirmed rendering live |
| Ethernet port statistics (`port_table[]`) | ✅ Working — one entry per **physical socket** on swconfig boards, each with the link speed and duplex that socket actually negotiated, read from the switch (the CPU netdev only ever knows the internal SoC↔switch link, which is always 1000/full). Which socket is the uplink is detected from the switch's ARL table, so it follows the cable. Per-port byte counters from the switch's MIB, which openUF switches on at startup where the driver ships it off (`ar8xxx_mib_poll_interval`); packet/multicast/broadcast/drop counts are not available per socket, so those columns stay empty rather than carrying the CPU port's totals. Anomaly, STP and Profile are controller-side or USW-only — they read `-` for a real UniFi gateway's ports too. Boards with no readable switch keep the netdev-based single-port shape |
| Wired client statistics (`port_table[].mac_table`) | ✅ Working — hosts are placed on the socket they are really plugged into, from the switch's ARL table on swconfig boards (there `bridge fdb` can only ever say "behind the CPU port") and from the bridge FDB on DSA, where each socket is its own bridge port. Each socket is asked about **its own** bridge, not the uplink's, so a socket openUF has moved into a VLAN bridge still reports its hosts; where that socket has MAC learning off (see per-port VLAN below) the FDB has nothing to say and the hosts come from an nftables tap instead. Rows carry `vlan` (the VLAN of the bridge the socket sits in) and, for such a socket, an `ip` harvested by the tap — which is what puts the client on the right **network**, not just the right port. The uplink socket reports none, and neither does a socket on a VLAN openUF does not carry (a swconfig board's WAN socket stranded on VLAN 2 — a host there is not reachable on the LAN it would be listed in). The AP's own MACs and its wireless stations are never reported as wired clients. One `bridge fdb` dump serves every socket in a payload |
| Environment / rogue-AP scanning (`scan_radio_table`) | ✅ Working — confirmed rendering live in the Environment tab. Read from the kernel's passive BSS cache, so on its own it lists only neighbours on the radio's **own** channel (measured: 0 on 5 GHz, co-channel only on 2.4 GHz); an optional `neighbour_scan_interval` adds a real sweep at the cost of a brief client stall |
| RF environment enrichment (802.11k beacon reports) | ✅ Working — the mechanism Ubiquiti's Channel AI describes as *"neighbor reports and automated RRM scans"*, adopted from upstream. openUF periodically asks one 802.11k-capable **client** to sweep and report back; the client goes off-channel, the AP never does. Upstream measured a 5 GHz Environment list going from 0 neighbours to 4. Off with `rrm_enrichment = false` |
| LLDP topology announcement | ✅ Working (via `lldpd`) — **set `lldpd.config.cid_interface` to your LAN network**, or the controller shows the wrong Parent Device: lldpd's default chassis ID is some other interface's MAC, which the controller can't match to the MAC openUF is adopted under. See [USAGE](USAGE.md#7-lldp-topology) |
| RF/spectrum scan | ⚠️ Best-effort trigger only — the result-reporting wire format is unconfirmed |

### Device management

| Feature | Status |
|---|---|
| Locate (LED identify blink) | ✅ Working — requires `dev.conf.led` set per board, naming an LED that is **actually wired** (see USAGE § 3). Locate snapshots whatever trigger the LED was driving, persists it, and restores it on stop, so it survives a restart landing between `set-locate` and `unset-locate`; an interrupted Locate is torn down at the next start rather than blinking forever |
| Manage → LED steady on/off toggle | ✅ Working — same `dev.conf.led` requirement. Persisted and re-applied at startup, so it survives a reboot; also re-asserted when a Locate ends, since restoring the blink's previous trigger alone would leave a status LED dark |
| Client block / unblock | ✅ Working — enforced via nftables, persists across restarts |
| IP Settings (DHCP / static) | ✅ Working — reconfigures the device's own management interface, including the DNS servers (`resolv.nameserver.<k>.ip` → `/etc/resolv.conf`, in the controller's primary/secondary order). DNS is applied on the static path only; on DHCP the lease supplies it. A static address is re-applied on every start, so it survives a reboot the controller never re-pushes it after |
| Per-port VLAN assignment | ⚠️ Wire format fully mapped live (`switch.*`: device-level gate, per-VLAN table, per-port `pvid` plus a tagged/untagged/`exclude` matrix joined on `port_table[].port_idx`); requires reporting the `hasOWRTSwitch` capability bit and ticking **Port VLAN** on the device. Applied two ways. On **swconfig** boards, as `switch_vlan` sections: requires a `dev.conf.vlan` port map plus a `swport` on the port, never touches the socket the uplink cable is in (detected at runtime, and refused outright when it cannot be determined), and is reversible — unticking the device-level **Port VLAN** box tears openUF's sections down and restores the stock port strings; the generated UCI is unit-tested, but that it programs a real switch ASIC is **not verified**. On **DSA** boards (adopted from upstream, verified there on an AX3000T against a UCG Ultra) there is no switch table to write and `bridge-vlan` is deliberately not used: the assigned socket is moved out of `br-lan` and into that VLAN's `br-openuf<id>` bridge — the same L2 a tagged SSID on the same VLAN already uses. `br-lan` keeps the uplink and the management address and nothing runs with `vlan_filtering`, so a wrong answer cannot strand the AP. The moved socket gets MAC learning switched **off** (`openuf_brport<vid>_<socket>`): the ASIC has one address table shared with the uplink, and with learning on it hardware-drops every VLAN-tagged reply to the socket while outbound stays perfect — measured upstream as four DHCP DISCOVERs out and nothing back, versus a 2 ms OFFER with learning off. The hosts behind that socket, which learning off takes out of `bridge fdb`, come from an nftables tap (`bridge openuf_learn`) instead. Native VLAN only; a tagged-only port is refused out loud. ⚠️ Not yet exercised on this fork's JioRouter boards |
| Set Replacement Device / Load Configuration | ✅ Working — both are controller-side clones; no device-side protocol involved |
| Power / PoE reporting | Not applicable — the flagged UI field belongs to the upstream parent device, not the AP |
| Speed test | Not applicable — gateway-only feature in current UniFi Network |
| USG / USW emulation | Not implemented, not planned |

## Supported hardware

A dual-band OpenWrt device with **at least 16 MB flash**, and roughly **5 MB free on
`/overlay`** after the stock image.  8 MB is not enough: the AES-GCM backend
(`lua-openssl`) pulls in `libopenssl3` at ~4.35 MB, and adoption cannot complete without
GCM — a stock 8 MB build leaves only ~1.6 MB of overlay, which no crypto backend fits in
(`openssl-util` and `luaossl` depend on the same library).  Measured on a TL-WDR3500 v1,
which is 3.2 MB short and therefore **cannot run openUF from a stock image** — it needs
USB extroot or a custom build with the crypto baked into squashfs.  Known-working:

- **TP-Link Archer C5 v1** (dual-band 802.11n/ac) — use `modelmap/archer-c5-v1.lua`.
  **The reference device**: install, adoption, the WiFi config push, live clients and the
  radios themselves are confirmed on this board (OpenWrt 25.12.5) against a real UniFi Cloud
  Gateway Ultra — see [PROTOCOL-VALIDATION.md](PROTOCOL-VALIDATION.md#the-first-real-hardware-run)
- **TP-Link TL-WDR3500 v1** (dual-band 802.11n, 2x2) — use `modelmap/tl-wdr3500-v1.lua`.
  Adoption, SSID provisioning, 802.11r/k/v, Band Steering, Minimum RSSI and WiFi Speed
  Limit all confirmed on real hardware against a UCG Ultra.
  ⚠️ **8 MB flash: does not fit a stock image** (see the space requirement above) — it needs
  a custom build with the crypto in squashfs. Even then **`nftables` typically does not fit**
  (~490 KB with its kernel modules), which leaves two features unavailable on this board:
  **client Block/Unblock** and the **Multicast and Broadcast Blocker**. Its radio order is
  also the reverse of the Archer C5's — `radio0` is 2.4 GHz here
- **TP-Link WR1043ND v2** (single-band 802.11n) — use `modelmap/tl-wr1043ndv2.lua`
- **Xiaomi Mi Router AX3000T** (dual-band 802.11ax, 2x2, MT7981 / mediatek-filogic) — use
  `modelmap/xiaomi-ax3000t.lua`. Profile adopted from upstream (jonasevcik/openUF), where
  it is verified on the hardware: HE on both bands, 160 MHz on 5 GHz, DSA. Its four sockets
  are the netdevs `wan`/`lan2`/`lan3`/`lan4` (no `lan1`), and its case LED needs
  **`kmod-leds-gpio`** or the board has no drivable LED at all — `install.sh` adds the
  module when it sees only radio LEDs registered. ⚠️ Not yet run on this fork's own
  hardware; the map differs from the JioRouter ones in naming the uplink socket as
  `lan_cpueth` rather than the bridge, which openUF now handles either way
- **JioRouter AX6000 JIDU6101** (MT7986A / mediatek-filogic, dual-band 802.11ax) — use
  `modelmap/jiorouter-ax6000-jidu6101.lua`. ⚠️ **Not yet confirmed on the hardware**: the
  profile is derived from the board's OpenWrt DTS and `board.d` entry rather than from a
  live run, and its header flags the two facts to check first (the LED name and which
  radio is which band). The first **DSA** board here rather than swconfig, which changes
  how ports are reported — see below. 140 MB of SPI-NAND, so space is a non-issue.
  Carries a `dev.conf.radio` policy: its 5 GHz radio cannot be handed the controller's
  channel **Auto** unqualified (hostapd ACS picks a DFS channel, the mt7915 driver fails
  to start CAC, and the radio is left down), and the controller's default mode for the
  emulated U6IW is 802.11n at 40 MHz on a 4x4 WiFi-6 phy — see
  [USAGE](USAGE.md#radio-policy-devconfradio)
- **JioRouter AX6000 JIDU6J01 / JIDU6201 / JIDU6401 / JIDU6601 / JIDU6701** (MT7986A /
  mediatek-filogic, dual-band 802.11ax) — use `modelmap/jiorouter-ax6000-jidu6j01.lua`.
  **One profile for all five**: OpenWrt builds a single image from one DTS, so every
  variant reports the same board name and differs only in where `board.d` reads the label
  MAC from in the MFG partition — resolved at first boot, before openUF starts.
  ⚠️ **Not yet confirmed on the hardware**: derived from the OpenWrt DTS plus the
  JIDU6101 profile, which is the same SoC and the same MT7976 radios. It inherits that
  board’s measured `dev.conf.radio` policy; the header flags what to re-check first

Anything else: `modelmap/generic-dualband-ap.lua` or `modelmap/generic-singleband-ap.lua`,
or let `setup.sh` generate a profile from the running device (DSA boards only, where every
socket is a netdev and a correct profile really is derivable — on a swconfig board the
physical port numbering is board truth that cannot be probed, and it refuses rather than
guessing).

**swconfig vs DSA.** These change which of two port-reporting shapes a profile uses, and
getting it wrong is not cosmetic — a socket wrongly treated as downstream makes the AP
report the whole LAN, gateway included, as hosts plugged into it:

| | swconfig (ath79) | DSA (filogic and later) |
|---|---|---|
| Sockets in the kernel | one CPU netdev for all of them | one netdev per socket |
| Port link speed / duplex | `swconfig dev switch0 show` | the netdev's own sysfs |
| Which socket a host is on | the switch's ARL table | that socket's bridge-FDB slice |
| Uplink socket | `dev.conf.vlan` + ARL lookup | `dev.conf.net.uplink_detect = "fdb"` |
| Per-port VLAN assignment | supported (`switch_vlan` sections) | supported (the socket moves into the VLAN's bridge; Native VLAN only) |
| `dev.conf.vlan` | required | must be **absent** |

The *modelmap* describes your real hardware; the *ufmodel* picks the UniFi identity to present.  `ufmodel/u6iw.lua` (U6-InWall) is the default and the only one validated end-to-end — `uapg1`, `uapg1-lr`, and `uapg2-ac-lr` are also provided but untested.

## Quick start

One command on the device, over SSH:

```sh
wget -qO- https://raw.githubusercontent.com/yesrab/openUF/main/setup.sh | sh
```

`setup.sh` is the whole conversion, guided: it identifies the board, asks what it
cannot know, and does everything in an order chosen so a failure never leaves the
device unreachable.

1. **Interview** — every question first, before anything is changed.
2. **Access-point conversion** — a device still acting as a router fights the real
   gateway for DHCP and NAT, so the router role goes: no WAN interface, the WAN
   socket folded into the LAN side, DHCP server off, `firewall`/`dnsmasq`/`odhcpd`
   stopped and out of the boot sequence, and the resolver pointed back at the real
   nameservers `dnsmasq` was fronting. The packages are left installed, only
   disabled, so it is one command to undo.

   Folding in the WAN socket means two different things: on **DSA** it is the
   socket's own netdev, so it joins the LAN bridge and stays hardware-switched. On
   **swconfig** it is a CPU netdev reaching a socket the ASIC has segmented into its
   own VLAN — bridging that in works but hairpins every frame through the SoC, so
   `setup.sh` moves the port into the LAN VLAN in the switch instead, and only when
   it can prove which port that is. See [USAGE](USAGE.md#moving-the-wan-socket-to-the-lan-side).
3. **Hardware profile** — the board-specific profiles are listed with the detected
   one marked, the generics below them, and generating one from the running device
   at the bottom. Enter takes the detected board's profile, or a generic chosen by
   radio count when there is none.
4. **Controller** — an address, or nothing at all to be found by L2 discovery.
5. **Adoption account** — the locked-down `ubnt`/`ubnt` bootstrap login, so first
   adoption works without presetting a root password. Whether it exists also decides
   the adoption path: with no bootstrap account and no root password, L2 discovery is
   switched **off**, because a controller that discovered a device over L2 insists on
   adopting it over SSH and fails outright when it cannot log in.
6. **Dependencies** — installed, including swapping a `wpad-basic-*` build for the
   matching full one (`wpad-basic-mbedtls` → `wpad-mbedtls`, same crypto library, so
   no extra flash). A basic build has no `bss_transition` option at all and errors
   the radio down; `install.sh` alone cannot fix that, because the two packages
   conflict and `add` without `del` fails.
7. **Install and reboot.**

Package installation deliberately runs *before* the network teardown: the teardown
can take this device's internet with it, so nothing is left to download by then.

Everything it asks can also be passed as an option, so the same script drives an
unattended install:

```sh
wget -qO- https://raw.githubusercontent.com/yesrab/openUF/main/setup.sh | sh -s -- \
    --yes --controller 10.0.0.5 --modelmap jiorouter-ax6000-jidu6101 --no-reboot
```

`sh setup.sh --help` lists them all. `OPENUF_REPO`, `OPENUF_REF` and `OPENUF_SRC`
point it at a different fork, branch, or a checkout already on the device.

<details>
<summary>Doing it by hand instead</summary>

```sh
# 1. SSH into the OpenWrt device, install dependencies (OpenWrt 25.12+ uses apk)
apk update
apk add lua lua-cjson luasocket lua-openssl luabitop libuci-lua iw lldpd nftables kmod-nft-bridge hostapd-utils usteer ip-bridge tc-tiny kmod-sched-act-police wpad-wolfssl

# 2. Download and install (no git client or scp needed). This is the source
#    tree; install.sh comment-strips it on the way in. A tagged release
#    (vX.Y.Z) publishes a pre-stripped openuf.tar.gz under Releases instead.
wget -O openuf-src.tar.gz https://codeload.github.com/yesrab/openUF/tar.gz/main
tar xzf openuf-src.tar.gz && cd openUF-main
sh install.sh install
#    Re-running this later upgrades in place and KEEPS the device's conf.lua
#    (its modelmap above all); add --replace-conf to start from the default.
#    Later upgrades: `openuf-update` on the device, or from your dev machine
#    `sh tools/deploy.sh <ap-ip>...` (USAGE § 2, "Upgrading an installed AP").

# 3a. L2 adoption (device and controller on same subnet)
#     — The device will appear in UniFi Discover automatically.
#     — Click Adopt in the controller UI.

# 3b. L3 adoption (different subnets — no SSH from the controller needed)
ssh root@<device> syswrapper.sh set-inform http://<controller-ip>:8080/inform
#     — The device will appear as Pending in the controller.
#     — Click Adopt.
```

`install.sh` does not touch the network configuration, so a device installed this way
is still a router unless you convert it yourself.
</details>

Both adoption paths complete to **Connected**.  L2 requires the controller to
SSH in (set a root password first, or use `--bootstrap-adopt`); L3 skips SSH
entirely and delivers the adoption key over the inform channel.

The `apk add` step is optional: `install.sh install` installs every dependency that
is missing, including `usteer` and a full `wpad` build — both required for BSS
Transition (802.11v) and Band Steering to work at all. Any full build counts
(`wpad`, `wpad-wolfssl`, `wpad-openssl`, `wpad-mbedtls`), and an existing one is
left in place. `wpad-basic-*` builds lack 802.11v support entirely and will error
with "unknown configuration item 'bss_transition'" — `install.sh` cannot swap one
out (the packages conflict, so `add` without `del` fails), which is why `setup.sh`
does it. By hand: `apk del wpad-basic-mbedtls && apk add wpad-mbedtls`, matching the
crypto library already on the device.

`install.sh` works on both package managers: `apk` on OpenWrt 25.12+ and `opkg` on
24.10 and earlier.

`install.sh install` also registers `/etc/openuf/` and `/opt/openuf/conf.lua` with
`sysupgrade`, so an adopted AP stays adopted across a firmware upgrade — stock
`sysupgrade` backs up neither, and would take the authkey and the modelmap selection with
it. Existing entries in `/etc/sysupgrade.conf` are left alone; see
[USAGE.md](USAGE.md) for what uninstall does to them.

Installing from a git checkout instead (for contributors/dev builds) still works — `scp -r
openuf/ install.sh setup.sh root@<device>:/tmp/openuf/` and run `setup.sh` (or just
`install.sh`) from there.

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

On a real AP, `tools/heartbeat-probe.lua` reports what one inform actually costs
that board — every process spawned and file opened, per command and path — by
building its own payload in a throwaway process alongside the running daemon.
See [USAGE § 8](USAGE.md#measuring-what-a-heartbeat-costs-on-the-device).

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
- [REVERSE-ENGINEERING.md](REVERSE-ENGINEERING.md) — the open questions: protocol surfaces not implemented yet, what is known about each, and the experiment plan. Mesh/wireless uplink is the current head item
- [amd989/unifi-gateway](https://github.com/amd989/unifi-gateway) — primary protocol reference; live Python daemon tested against real controllers
- [jeffreykog/unifi-inform-protocol](https://github.com/jeffreykog/unifi-inform-protocol)
- [fxkr/unifi-protocol-reverse-engineering](https://github.com/fxkr/unifi-protocol-reverse-engineering)

## License

MIT — see [LICENSE](LICENSE).
