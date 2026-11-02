<p align="center">
  <img src="package/luci-theme-halo/htdocs/luci-static/halo/logo.svg" width="72" alt="">
</p>

<h1 align="center">openUF</h1>

<p align="center">
  <b>Run your OpenWrt access points from UniFi Network.</b><br>
  openUF makes an OpenWrt device look like a Ubiquiti access point to the UniFi controller:
  adopt it, push your WiFi networks to it, watch its clients, and roam between it and real UniFi APs.
</p>

<p align="center">
  <a href="https://github.com/yesrab/openUF/actions/workflows/test.yml"><img src="https://github.com/yesrab/openUF/actions/workflows/test.yml/badge.svg" alt="Tests"></a>
  <a href="https://github.com/yesrab/openUF/releases"><img src="https://img.shields.io/github/v/release/yesrab/openUF?label=release" alt="Release"></a>
  <a href="LICENSE"><img src="https://img.shields.io/badge/License-GPL--3.0--or--later-blue.svg" alt="License: GPL-3.0-or-later"></a>
  <a href="https://www.lua.org/"><img src="https://img.shields.io/badge/Lua-5.1-blue.svg" alt="Lua 5.1"></a>
</p>

<p align="center">
  <a href="#install">Install</a> ·
  <a href="#what-it-does">What it does</a> ·
  <a href="#hardware">Hardware</a> ·
  <a href="#documentation">Documentation</a> ·
  <a href="#contributing">Contributing</a> ·
  <a href="REFERENCE.md">Full reference</a>
</p>

---

## See it

The device's own page, before and after the controller adopts it:

| Waiting to be adopted | Managed by UniFi Network |
|:---:|:---:|
| ![The device page before adoption: "Waiting to be adopted", the controller's address and the device facts](screenshots/device-page-ready-for-adoption.png) | ![The device page after adoption: "This device is managed by UniFi Network"](screenshots/device-page-managed-by-unifi.png) |

Two openUF access points, the **U6 IW** nodes, in a real UniFi Network topology beside a
UniFi Cloud Gateway Ultra, serving phones, laptops and IoT devices on two WiFi networks:

![UniFi Network's topology view with two openUF access points and their clients](screenshots/unifi-topology.png)

It shows up in UniFi Network as a U6 In-Wall and adopts with one click:

![UniFi Network's device list with an openUF access point ready to adopt](screenshots/unifi-devices-ready-to-adopt.png)

The few settings that stay on the device, behind the root password:

| Controller and hardware profile | Wireless, this page, service |
|:---:|:---:|
| ![Local Settings: inform URL, adoption state, hardware profile and the identity presented](screenshots/device-page-local-settings-top.png) | ![Local Settings: wireless options, the page switch, restarts](screenshots/device-page-local-settings-bottom.png) |

## What it does

- **Adoption like real hardware.** The AP announces itself on the LAN, appears in UniFi
  Network, WiFiman and the UniFi app, and adopts with one click through the same locked-down
  `ubnt` login the controller expects. A controller on another subnet adopts it by inform
  URL instead, with no SSH at all.
- **WiFi from the controller.** Networks with WPA2, WPA3 and Enhanced Open, per-network
  VLANs, private pre-shared keys, hidden SSIDs, channel, width and power per radio,
  802.11r/k/v, band steering, minimum RSSI, per-client speed limits, WiFi schedules, client
  blocking and Locate.
- **Fast roaming with genuine UniFi APs.** The installer offers d-malinowski's rrb-unifi
  plugin, which speaks UniFi's 802.11r key exchange, so phones move between openUF and real
  UniFi access points without a reconnect. Plugins are the way to add such recipes
  ([PLUGINS.md](PLUGINS.md)).
- **WPA-Enterprise, RADIUS MAC authentication, Hotspot 2.0, MAC-based VLANs, DFS radar
  reports and the site's auto-channel limits.** Adopted from upstream in November 2026 with
  their evidence; not yet exercised on this tree's own access points.
- **Live statistics.** Clients with WiFi Experience scores, radios and channel utilisation,
  wired hosts per port, the uplink, neighbouring access points and RF scans.
- **Switch ports and mesh.** Per-port VLANs from the controller's Port settings, and a
  wireless uplink to another openUF AP when the cable is out.
- **A device page instead of LuCI's login.** Like a Ubiquiti device, the AP's address shows
  its status and sends you to the controller; LuCI stays one hidden step away, with a
  dashboard and the matching Halo theme.
- **Pure Lua, no toolchain.** One command installs it on OpenWrt 24.10 or 25.12, as packages
  or as files, with upgrades in place.

Everything above was validated against a real controller, a UniFi Cloud Gateway Ultra on
UniFi Network 10.x. [REFERENCE.md](REFERENCE.md) has the feature-by-feature status and
[PROTOCOL-VALIDATION.md](PROTOCOL-VALIDATION.md) the evidence. openUF emulates an access
point only: no gateway or switch emulation, by design.

## Hardware

Any dual-band OpenWrt device with **16 MB of flash or more** and about 5 MB free on
`/overlay` (the AES-GCM crypto the controller insists on needs `libopenssl3`). A **full
`wpad` build** is required and the installer swaps it in. Boards with a profile:

| Board | Notes |
|---|---|
| TP-Link Archer C5 v1 | The reference device, confirmed end to end |
| TP-Link TL-WDR3500 v1 | Confirmed; 8 MB flash, needs a custom image with the crypto built in |
| JioRouter AX6000 JIDU6101 and JIDU6J01 family | Confirmed; WiFi 6, DSA, the project's own lab APs |
| TP-Link Deco M4R v1 / v2 | Adopted and meshed on a v1 by a user |
| Xiaomi Mi Router AX3000T | Confirmed upstream, WiFi 6 |
| TP-Link Archer A7 v5 / C7 v4 / C7 v5 | From the OpenWrt sources, not yet run on the board |
| TP-Link Deco M5 v1 / v2 / v3 | From the OpenWrt sources, not yet run on the board |
| TP-Link Deco M4R v4 | From the OpenWrt sources, not yet run on the board |
| Dynalink DL-WRX36 | From the OpenWrt sources, not yet run on the board |
| TP-Link WR1043ND v2 | Single band; profile only |

Anything else runs on a generic dual-band or single-band profile, or on one the installer
generates from the running device. Details, caveats and the identity each board presents
are in [REFERENCE.md § Supported hardware](REFERENCE.md#supported-hardware).

## Install

One command on the device, over SSH:

```sh
wget -qO- https://raw.githubusercontent.com/yesrab/openUF/main/setup.sh | sh
```

The guided installer identifies the board, asks the few things it cannot know, and does
the rest in an order that never leaves the device unreachable:

1. **Interview.** Every question first. The default installs the `openuf` and
   `luci-app-openuf` packages from the latest release, plus the Halo theme where there is
   room; `--headless` installs the daemon alone.
2. **Access-point conversion.** The router role goes: no WAN, the WAN socket joins the LAN,
   DHCP server and firewall off. Everything is left installed and is one command to undo.
3. **Hardware profile**, **controller address** and the **adoption account**, which locks
   itself once the device is adopted.
4. **Dependencies**, including the full `wpad` build, then install and reboot.

Then open UniFi Network. The AP appears under Devices (or under *Pending* when you gave it
the controller's address), and **Adopt** does the rest.

Unattended, with every answer as an option:

```sh
wget -qO- https://raw.githubusercontent.com/yesrab/openUF/main/setup.sh | sh -s -- \
    --yes --controller 10.0.0.5 --modelmap jiorouter-ax6000-jidu6101 --no-reboot
```

`sh setup.sh --help` lists them all. The packages alone, from the
[release page](https://github.com/yesrab/openUF/releases):

```sh
apk add --allow-untrusted ./openuf-<ver>.apk ./luci-app-openuf-<ver>.apk   # OpenWrt 25.12
opkg install ./openuf_<ver>_all.ipk ./luci-app-openuf_<ver>_all.ipk         # OpenWrt 24.10
openuf deps --install        # swaps a wpad-basic build for the full one
```

Upgrades: `openuf-update` on the device, or install the next release's packages. The
[usage guide](USAGE.md) covers configuration, the device page, upgrading, uninstalling and
troubleshooting.

## Documentation

| Document | What it is for |
|---|---|
| [REFERENCE.md](REFERENCE.md) | **The full reference.** Every feature with its validation status, the hardware matrix, the detailed quick start, local testing and protocol notes |
| [USAGE.md](USAGE.md) | Installing by hand, every configuration option, the device page and LuCI app, upgrading, troubleshooting |
| [PROTOCOL-VALIDATION.md](PROTOCOL-VALIDATION.md) | What was confirmed against a live controller, with the wire evidence; it wins where other documents disagree |
| [REVERSE-ENGINEERING.md](REVERSE-ENGINEERING.md) | What is not implemented yet, what is known about it, and the experiment plan |
| [PACKAGING.md](PACKAGING.md) | The OpenWrt packages, the LuCI app, the theme and the release workflow |
| [CLAUDE.md](CLAUDE.md) | Working notes for contributors: the constraints, the landmines, and how to add a hardware profile |

## Contributing

Issues and pull requests are welcome at [github.com/yesrab/openUF](https://github.com/yesrab/openUF).

**Report a problem** with the board and OpenWrt version, the controller version, and the
output of `openuf status` and `logread -e openuf` on the device. Say what the controller
showed.

**Add a hardware profile.** The most useful contribution. On a DSA board the installer can
generate one (`setup.sh`, or *Export* on the LuCI settings page); otherwise write
`openuf/modelmap/<vendor>-<model>.lua` from the board's OpenWrt DTS and `board.d` entry,
following [CLAUDE.md § Adding a new device map](CLAUDE.md#adding-a-new-device-map), and say
in its header what was and was not confirmed on the hardware.

**Change the code.** The daemon is Lua 5.1 as OpenWrt ships it, the installers are POSIX
shell for busybox; the constraints are listed in [CLAUDE.md](CLAUDE.md). Before a pull
request:

```sh
eval $(luarocks path --local) && lua tests/run_tests.lua   # the suite, pure Lua, no hardware
bash -n setup.sh && dash -n setup.sh                         # both shells, for every script touched
sh tools/dist.sh --verify                                    # the stripped tree is bytecode-identical and still passes
```

A new test file is registered in `tests/run_tests.lua`. Comments explain *why*, naming the
failure that motivated the code. Where a fact cannot be determined, report nothing rather
than a plausible guess. Protocol changes start from PROTOCOL-VALIDATION.md, and anything
the controller sends that openUF does not act on stays counted in the unhandled ledger
until it is implemented. No device addresses, passwords or controller keys go into the
tree. CI runs the suite and the release verification on every push.

**Test without hardware.** `sh tools/simulate.sh --adopt` runs an adoption round-trip against
the Python controller stub; `tools/validation/` has a Docker UniFi controller for the real
thing.

## Credits

openUF began as a fork of [jonasevcik/openUF](https://github.com/jonasevcik/openUF) and
still exchanges work with it. Fast roaming with genuine UniFi APs is
[d-malinowski/unifi-openwrt-roaming](https://github.com/d-malinowski/unifi-openwrt-roaming),
whose translator and openUF plugin the installer offers to set up. The protocol groundwork
came from [amd989/unifi-gateway](https://github.com/amd989/unifi-gateway),
[jeffreykog/unifi-inform-protocol](https://github.com/jeffreykog/unifi-inform-protocol) and
[fxkr/unifi-protocol-reverse-engineering](https://github.com/fxkr/unifi-protocol-reverse-engineering).
Built on [OpenWrt](https://openwrt.org/) and [LuCI](https://github.com/openwrt/luci).

## License

[GPL-3.0-or-later](LICENSE). [NOTICE](NOTICE) lists the copyright holders and preserves the
MIT notice of the original openUF. `luci-theme-halo` is Apache-2.0.
