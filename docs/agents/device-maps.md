# Board profiles and UniFi identities

Part of the agent notes: [CLAUDE.md](../../CLAUDE.md) is the index and holds the hard constraints.

Read before adding or changing a file in `openuf/modelmap/` or `openuf/ufmodel/`.
Per-port VLAN and uplink detection on a board are in [network-and-switch.md](network-and-switch.md).

## Adding a new device map

### 0. Decide swconfig or DSA first — it determines everything else

| | swconfig (ath79, pre-DSA) | DSA (mediatek/filogic and later) |
|---|---|---|
| Sockets in the kernel | one CPU netdev for all of them | one netdev per socket |
| Port link speed/duplex | `swconfig dev switch0 show` | that netdev's own sysfs |
| Which socket a host is on | the switch's ARL table | that socket's bridge-FDB slice |
| Uplink socket | `dev.conf.vlan` + ARL lookup | `dev.conf.net.uplink_detect = "fdb"` |
| `dev.conf.net.ports` entries | `{idx = 1, swport = "lan1"}` | `{idx = 1, ifname = "lan1"}` |
| `dev.conf.vlan` | **required** | **must be absent** |
| `lan_cpueth` | the CPU netdev / trunk (`eth1`) | the LAN **bridge** (`br-lan`) |
| Per-port VLAN assignment | `switch_vlan` sections | the socket moves into the VLAN's `br-openuf<id>` bridge (Native VLAN only) |

On the device: `swconfig list` printing `Found:` means swconfig; a
`/sys/class/net/*/dsa` directory or per-socket `lanN` netdevs with no swconfig means DSA.

### 1. Get the facts from the OpenWrt source, not from guesswork

With an `openwrt` checkout alongside this repo:

```sh
target/linux/<target>/dts/<soc>-<vendor>-<model>.dts      # LEDs, switch port labels, flash
target/linux/<target>/<sub>/base-files/etc/board.d/02_network
      # -> ucidef_set_interfaces_lan_wan / ucidef_add_switch: the stock network layout
target/linux/<target>/<sub>/base-files/etc/hotplug.d/ieee80211/11_fix_wifi_mac
      # -> per-phy MAC assignment, i.e. how many radios and their order
target/linux/<target>/image/<sub>.mk                       # DEVICE_PACKAGES -> wifi driver
```

Two things worth knowing about what `config_generate` produces from those:

- It **force-bridges `lan`** even for a single device, so there is always a
  `config device` section named `br-lan` with a `ports` list.
- `ucidef_add_switch "switch0" "0u@eth1" "2:lan" … "6u@eth0" "1:wan"` — the `u` suffix
  means the CPU port stays *untagged*, so the netdev is bare `eth1`/`eth0`. Without `u`
  the CPU port is tagged and the netdev becomes `eth0.<vlan>`. Roles become anonymous
  `config switch_vlan` sections with bare-number `ports` lists.

**Check whether the board is really a FAMILY.** Look at its `define Device/…` block in
`image/<sub>.mk`: a `DEVICE_ALT0_VARIANT` / `ALT1` / `ALT2` … list means OpenWrt builds
**one image from one DTS** for several retail models, and every one of them reports the
same `compatible` string. `ubus call system board` therefore cannot tell them apart, and
neither can openUF.

That is not a problem to work around — it is a shortcut. Write **one** map, claim the
single family board name, and say so in the header. Then check what the variants actually
differ in, in `board.d/02_network`; if the whole difference is where the label MAC is read
from (the `jiorouter,ax6000-jidu6j01` case: four different MFG offsets and encodings), it
is resolved at first boot long before openUF starts and there is nothing left to describe.

The tempting mistake is to "complete" `dev.openwrt_boards` with the retail names. `ubus`
never emits them, so they are dead weight that reads like coverage — and a real second map
claiming one would make `setup.sh`'s choice between the two arbitrary. Pin it with a test
(see `modelmap: one JIDU6J01 profile serves the whole retail family`).

What *would* justify a second map is a variant that differs in something openUF reads:
a different socket count, radio count, or LED wiring. Those come from the DTS, and a
shared DTS means shared answers — but the DTS is written from one sample, so if a variant
turns out to have fewer holes in the case than the DTS claims, that is a real divergence
and the map needs a ⚠️ rather than silence.

### 2. Write the file

`openuf/modelmap/<vendor>-<model>.lua`. Copy the closest existing map:
`jiorouter-ax6000-jidu6101.lua` for DSA (`deco-m5.lua` for a two-socket DSA board whose LED name
varies by revision), `archer-c5-v1.lua` for swconfig with two CPU
netdevs, `archer-a7-v5.lua` for swconfig with one tagged CPU trunk (`0@eth0`), `deco-m4r-v1.lua`
for that trunk on a board OpenWrt gives no WAN role at all, `deco-m4r-v4.lua` for a DSA board whose
sockets are named `eth0`/`eth1`, `openwrt-one.lua` for a board with no switch at all (one ethernet
MAC per socket: the DSA column of the table above applies, though neither on-device test says DSA).

```lua
--[[
	<Vendor> <Model> hardware profile.        <- line 2 becomes the setup.sh menu title
	                                             (" hardware profile." is stripped)
	Where the facts came from, and ⚠️ anything NOT verified on real hardware.
]]--

dev.openwrt_boards = {"vendor,model"}   -- the DTS compatible string; setup.sh matches
                                        -- this against /tmp/sysinfo/board_name
```

Then set:

- **`dev.conf.net.lan_cpueth`** — read the warning below. This is the single most
  dangerous field in the file.
- **`dev.conf.net.ports`** — one entry per RJ45 socket on the case. `idx` is the UniFi
  `port_idx` and the controller keys per-port settings on it, so pin it to a socket and
  never renumber. **Do not set `uplink`** on a board deployed as an AP: the cable goes in
  whichever socket was convenient, and it is detected at runtime instead.
- **`dev.conf.net.uplink_detect = "fdb"`** — DSA only.
- **`dev.conf.radio`** — optional per-band policy (`ng`/`na`): `acs_exclude_dfs`,
  `channels`, `htmode_floor`, `htmode_max`. This is where "what does Auto mean on this
  board" lives, and where "the driver advertises a width it cannot run" goes.
  Measure it on the hardware (`iw phy phyN info` for DFS flags, `logread` for what ACS
  actually picked) and cite the evidence in the comment — every field here overrides the
  controller, so the justification has to be in the file.
- **`dev.conf.vlan`** — swconfig only: `cpu_lan`, `cpu_wan`, and `ports` mapping label →
  physical port number. **This is board truth, not derivable.** TP-Link boards commonly
  put the WAN socket on physical 1 with LAN at 2–5 — the Archer C5 map had `lan1..lan4 =
  1..4` for a long time, which put "lan1" on the WAN socket and left one LAN socket
  unaddressable. Latent until a tagged SSID needed a trunk. Read it off the board's own
  stock config and `swconfig dev switch0 show`.
- **`dev.conf.led`** — the sysfs LED name (`green:status`) or full path. Pick one **no
  OpenWrt DTS alias already drives**: `led-boot`, `led-failsafe`, `led-running` and
  `led-upgrade` in the DTS claim specific LEDs, and openUF fighting procd over the same
  GPIO is visible confusion. `nil` makes Locate and the LED toggle silent no-ops.
- **`dev.openuf.uap.hwassign`** — UCI radio names to report. A board can have more radios than its
  identity (the WRT3200ACM's third, an 88W8887 for DFS scanning and Bluetooth): leave the extra out
  and say in the comment that `setup.sh` still enables it. Radio order is **not**
  band order: the Archer C5 has `radio0` = 5 GHz, the WDR3500 and jidu6101 have
  `radio0` = 2.4 GHz. Nothing depends on the order (band is read from each radio's own
  UCI `band`/`hwmode`) but the comment should say which is which. Radios left out of
  `hwassign` are never reported and never touched.
- **`dev.openuf.uap.ufmodel`** — `"u6iw"` for anything dual-band. A single-radio board
  should use `"uapg1-lr"`; a one-radio device reporting U6IW leaves the controller
  showing a radio that never comes up. `"uhdiw"` (UAP-IW-HD) is the WiFi 5 dual-band
  choice -- the controller then offers 802.11ac modes instead of HE ones the hardware
  cannot run -- but it is unvalidated until a controller adopts under it. The
  `archer-a7-v5` map is the first to use it (the `linksys-wrt3200acm` map the second), and names
  `u6iw` as the fallback. `"u7hd"` (UAP-AC-HD)
  is the WiFi 5 choice for a TWO-socket board -- both in-wall identities carry five -- and has
  been adopted once, on a Deco M4R v1 (2026-10-18); the `deco-m5` and both `deco-m4r` maps use it.
  `"u6mp"` (U6 Mesh Pro) is the WiFi 6 choice for a TWO-socket board; the `openwrt-one` map is the
  first to use it, and no controller has adopted under it yet.

### 3. `lan_cpueth` decides the device's IDENTITY

Its MAC is what the controller adopts the device under. Change it on an already-adopted
device — switching modelmaps, say — and every inform afterwards arrives under a MAC the
controller has no adoption for: **HTTP 400 forever**, while the old record sits there
going Offline. Invisible from the device: the daemon is healthy, the radios are up, and
the log just fills with anonymous 400s. `inform.lua`'s `_warn_identity_change` shouts
about it; the fix is to Forget and re-adopt, or point it back.

It also decides two other things, which is why DSA wants the bridge:

- The **management address** — `netconfig.lua` runs `ip addr`/`udhcpc` straight on this
  netdev for a controller-pushed IP Settings change, and the address lives on `br-lan`.
- The **VLAN trunk** — `ensure_vlan_network` builds `<lan_cpueth>.<vid>`. On DSA that must
  be `br-lan.20`: OpenWrt's stock filogic bridge is not VLAN-filtering so a tagged frame
  crosses it untouched, but a sub-device on a bridge *port* (`lan1.20`) never sees a frame
  at all, because the port hands everything to the bridge.

### 4. Test it

`tests/test_modelmap.lua` loads **every** file in `openuf/modelmap/` and enforces:

- returns a table with `dev.conf`, `dev.openuf.uap`, and a `ufmodel` whose file exists
- `lan_cpueth` is a string; each port has a unique numeric `idx` and names either a
  `swport` or an `ifname`
- an `uplink` port never carries a `swport` (reassigning the uplink's VLAN strands the device)
- a `swport` resolves through `dev.conf.vlan.ports`
- `uplink_detect` implies no `dev.conf.vlan`, no `swport`, no static `uplink`
- `openwrt_boards` entries look like `vendor,model` and no two maps claim the same board
- `led` is a string or `{sysfs=…}`; `hwassign` is a non-empty list of names
- no LAN port collides with the WAN port or a CPU port

Then add a **board-specific** test pinning the facts a generic invariant cannot catch —
see the `archer-c5-v1` and `JioRouter AX6000` cases (the latter checks both
JIDU maps in one loop — they are the same SoC and radios, so anything that drifts apart
should drift on purpose). Pin the things that are
board truth (which physical port is the WAN socket, `lan_cpueth`, the LED) with a comment
saying how you know.

### 5. Tell setup.sh about it

Nothing to do beyond `dev.openwrt_boards` — the installer reads the modelmap directory and
each file's declared boards at runtime, so there is no second table to update. A file
named `generic-*` is listed under "Generic"; anything else under "Board-specific".

### 6. Update the docs

Three places name the profiles and will drift silently:

- `REFERENCE.md` → **Supported hardware**, with an honest ⚠️ if it is not confirmed on the
  hardware, and the flash/space caveat if there is one.
- `USAGE.md` → **Hardware model map**, the `dev = dofile("modelmap/…")` list.
- `openuf/conf.lua`'s own header comment, which lists the known-working maps.

### Checklist

```
[ ] swconfig or DSA established (swconfig list / /sys/class/net/*/dsa)
[ ] facts sourced from the OpenWrt DTS + board.d, and cited in the file header
[ ] header line 2 reads "<Vendor> <Model> hardware profile." (the menu title)
[ ] dev.openwrt_boards = {"vendor,model"}
[ ] DEVICE_ALT*_VARIANT checked in image/<sub>.mk — a family gets ONE map, one board name
[ ] lan_cpueth: bridge on DSA, CPU netdev/trunk on swconfig
[ ] one ports entry per RJ45 socket; no static uplink flag
[ ] DSA: uplink_detect = "fdb", NO dev.conf.vlan
[ ] swconfig: dev.conf.vlan with verified physical port numbers
[ ] led = an LED no DTS alias drives (or nil)
[ ] hwassign, with a comment saying which radio is which band
[ ] ufmodel: u6iw dual-band (u6mp for two sockets; uhdiw five-socket / u7hd two-socket for WiFi 5 hardware, once validated), uapg1-lr single-radio
[ ] ⚠️ marks on everything not confirmed on real hardware
[ ] board-specific test added to tests/test_modelmap.lua
[ ] lua tests/run_tests.lua passes
[ ] REFERENCE / USAGE / conf.lua header updated
```

## Adding a UniFi identity (ufmodel)

Rarer than a modelmap, and the facts come from Ubiquiti, not OpenWrt:

- **The model code, port count and capabilities** are in Ubiquiti's public device database,
  `https://static.ui.com/fingerprint/ui/public.json` (one entry per product: `shortnames`,
  `unifi.network.model`, `numberOfPorts`, `deviceCapabilities`, `minAdoptVersion.net`). Look the
  product up by name there first: the codes are not guessable (`U6MP` is the U6 Mesh Pro,
  `UAP6MP` the U6 Pro). What the controller does with those capabilities is still unknown.
- **The current firmware** is in the controller's own catalog:
  `https://fw-update.ubnt.com/api/firmware-latest?filter=eq~~product~~unifi-firmware&filter=eq~~platform~~<CODE>&filter=eq~~channel~~release`
  returns `"platform": "UHDIW", "version": "v6.7.57+15670"`. `fw.ver` is that version
  **bare**, `6.7.57.15670` -- the controller compares the inform's `version` to its catalog
  entry with a strict string equality, so a prefix or a `+` is a permanent "Update
  Available" (PROTOCOL-VALIDATION.md, "Why version must be bare"). Since 2026-11-13 `fw.ver`
  is only the starting value: a controller `upgrade` is accepted virtually (`st.fw_version`,
  reported by `build_json` and `announce.lua`), so the badge clears without a hand edit.
- **`buildtime` and `factoryver` are cosmetic**: they reach only the L2 discovery TLVs. Say
  in the file where the values came from rather than making them look captured.
- **What the model registry says about the code cannot be read from the device side.**
  Port count and the switch feature decide whether `port_table` is processed at all
  (`Device.isSwitch()`), and per-model WLAN gating is unknown. Until a controller has
  adopted under the identity, the file and every map that selects it carry a ⚠️ and name
  `u6iw` as the fallback. Never validate on AP1/AP2: their adoption records are keyed to
  U6IW and changing `model` on an adopted device is untested.
- `tests/test_ufmodel.lua` loads every identity and pins the shape both `announce.lua` and
  `inform.build_json` read; add the model-specific facts there.

## Landmines

- **lldpd's chassis ID must match `lan_cpueth`'s MAC** (`uci set
  lldpd.config.cid_interface=lan`) or the controller shows the wrong Parent Device: lldpd
  otherwise picks the lowest-numbered interface, which the gateway then learns under an ID
  matching no adopted device.
- **A DSA bridge's MAC follows its FIRST member, not the lowest address** (netifd `bridge.c`,
  `bridge_reset_primary`): with no `macaddr` on the bridge's `config device` section, br-lan
  takes the MAC of its alphabetically-first present port and re-picks whenever that port
  leaves. On a board whose `board.d` sets no LAN MAC (the Deco M5) a map with
  `lan_cpueth = "br-lan"` therefore has an identity that `switchvlan.dsa_apply` can move: a
  Native-VLAN push on that first socket takes it out of br-lan and the next inform arrives
  under a MAC the controller never adopted. Pin the address in UCI before adopting (the
  `deco-m5` header has the three lines). The JioRouters escape it because `board.d` sets
  `lan`'s MAC for them, the AX3000T because its map names a socket, the Deco M4R v4 because every
  one of its DSA ports inherits the conduit's label MAC.
- **On the Deco M4R v4, `eth0` and `eth1` are DSA sockets and the CPU conduit is `dsa`** (OpenWrt
  24.10 renamed them, commit 4fed462454, to keep the stock names working). The daemon keys on the
  name `eth0` in one place only, inform's fallback port table for a map with no `ports`; the generic
  maps' `lan_cpueth = "eth0"` would name a bridge port there, and a VLAN sub-device on a bridge
  port never sees a frame. Its map uses `br-lan`. New code that treats `eth<n>` as a CPU netdev is
  wrong on that board.
- **`led.set_enabled` writes the LED's own `max_brightness`, read from sysfs, not a literal 1.**
  A GPIO LED's ceiling is 1, so the literal was invisible on every board until the Deco M5's
  lp5521 (ceiling 255), where 1 is 0.4 %: the case light went dark the moment openUF started,
  Locate included, since the timer trigger blinks at the current brightness. Unreadable or
  non-numeric falls back to 1.
