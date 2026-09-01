# openUF — working notes

A Lua daemon that makes an OpenWrt device appear to a UniFi Network Application as a
Ubiquiti **U6-InWall** access point: L2/L3 adoption, controller-pushed SSID and radio
config, live client/radio/port statistics. AP emulation only — gateway (USG) and switch
(USW) are not implemented and not planned.

Two orthogonal concepts, constantly confused:

- **modelmap** (`openuf/modelmap/*.lua`) — *your real hardware*: radio names, ethernet
  sockets, switch geometry, status LED.
- **ufmodel** (`openuf/ufmodel/*.lua`) — *the UniFi identity presented to the controller*.
  `u6iw` is the only one validated end-to-end.

`openuf/conf.lua` picks one of each and holds runtime options. It is the file users
hand-edit on the device, so it (and `modelmap/*`) keep their comments when packaged.

---

## Commands

```sh
# Tests. Must run from the project root — test files dofile("openuf/...") relatively.
eval $(luarocks path --local) && lua tests/run_tests.lua

# End-to-end adoption round-trip against the Python controller stub
sh tools/simulate.sh --adopt          # needs pycryptodome, luasocket, lua-cjson

# Release tarball; --verify proves the comment-stripped tree is bytecode-identical
# to the source and still passes the suite
sh tools/dist.sh --verify

# Shell syntax — BOTH, every time (see "Shell code" below)
bash -n setup.sh && dash -n setup.sh
```

A new test file must be added to the hardcoded `test_files` list in
`tests/run_tests.lua` — it is not globbed, and an unregistered file silently never runs.

---

## Hard constraints

### Lua

**Lua 5.1** on the device (CI runs `lua5.1`). No `goto`, no `//`, no native bitwise
operators (`luabitop` provides `bit.*`), `break` must be the last statement in its block.
A newer local Lua will happily accept code the device rejects — CI is the check.
`openuf/lib/lib.lua` is what lets one source tree run on both: it resolves `bit` from
luabitop, bit32, or native 5.3+ operators built with `load()` so 5.1 never parses the
newer syntax. Follow that pattern rather than branching on `_VERSION`.

Every script loads siblings by **cwd-relative path**, and `conf.lua` does
`dofile("modelmap/…")`. Everything therefore runs from `openuf/`; the procd init script
does `sh -c "cd /opt/openuf && exec lua inform.lua"` for exactly this reason. Anything
that shells out to Lua from elsewhere must `cd` first.

Flash is scarce. `tools/dist.sh` strips comments from every `.lua` except `conf.lua` and
`modelmap/*`, roughly halving the installed bytes. `--verify` compares `luac` opcode
streams before and after, so it catches a "comment" edit that changed behaviour.

### Shell code

`install.sh`, `setup.sh` and `tools/*.sh` run under **busybox ash**, not bash. Check with
`bash -n` *and* `dash -n` — dash is the strictest POSIX shell available on a runner and
catches bashisms `bash -n` accepts. CI does both for `setup.sh` and `install.sh`.

- `sed -i` with no suffix (GNU/busybox form). This **fails on macOS/BSD** — use
  `/opt/homebrew/opt/gnu-sed/libexec/gnubin` in `PATH` when testing locally.
- Avoid `case` inside `$( )`. It has bitten this repo: a `)` in a case pattern terminated
  the substitution early and wrote a garbage netmask. Assign to a variable first.
- `local` is fine inside functions, never at top level.
- Support both package managers: OpenWrt 25.12 uses `apk`, 24.10 and earlier `opkg`, with
  identical package names. Both scripts define `pkg_installed` / `pkg_add` wrappers — use
  them rather than naming a manager.

### Conventions

Tabs, 4 wide — `.editorconfig` scopes that to `[*.lua]`, but the shell scripts use tabs
too. Comments in this repo explain **why**, and usually name the failure that motivated
the code ("this was hardcoded 1000/full, so every device reported GbE"). Match that
density — it is the repo's main defence against re-breaking things that are invisible
without hardware.

The load-bearing discipline: **refuse rather than guess.** Where a fact cannot be
determined (which socket the uplink is in, which physical port is which), report nothing
rather than a plausible wrong answer. A wrong answer here means the AP tells the
controller the whole LAN is plugged into it, or a VLAN push strands the device.

---

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
| Per-port VLAN assignment | supported | detected and refused |

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
`jiorouter-ax6000-jidu6101.lua` for DSA, `archer-c5-v1.lua` for swconfig.

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
- **`dev.openuf.uap.hwassign`** — UCI radio names to report. Radio order is **not**
  band order: the Archer C5 has `radio0` = 5 GHz, the WDR3500 and jidu6101 have
  `radio0` = 2.4 GHz. Nothing depends on the order (band is read from each radio's own
  UCI `band`/`hwmode`) but the comment should say which is which. Radios left out of
  `hwassign` are never reported and never touched.
- **`dev.openuf.uap.ufmodel`** — `"u6iw"` for anything dual-band. A single-radio board
  should use `"uapg1-lr"`; a one-radio device reporting U6IW leaves the controller
  showing a radio that never comes up.

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

- `README.md` → **Supported hardware**, with an honest ⚠️ if it is not confirmed on the
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
[ ] ufmodel: u6iw dual-band, uapg1-lr single-radio
[ ] ⚠️ marks on everything not confirmed on real hardware
[ ] board-specific test added to tests/test_modelmap.lua
[ ] lua tests/run_tests.lua passes
[ ] README / USAGE / conf.lua header updated
```

---

## Changing `setup.sh`

The guided installer: interview → packages → openUF → AP conversion → reboot.

**The phase order is load-bearing.** Packages install *before* the network teardown,
because the teardown can take the device's internet with it (this box stops being the
router). A failure in the first three phases leaves a working router; a failure in the
fourth leaves a working router with openUF installed but idle. Do not reorder.

Other things to preserve:

- **The re-exec.** `wget -qO- … | sh` hands the *script* to the shell on stdin, so a
  `read` would consume the script's own remaining bytes. It re-execs from a file with
  stdin on `/dev/tty`. It must be an `exec`, not `exec < /dev/tty` mid-script, which would
  take the rest of the script away from the shell still reading it. And test whether
  `/dev/tty` can be **opened** (`( exec < /dev/tty )` in a subshell) — `[ -r /dev/tty ]`
  answers yes in places where the open then fails.
- **Every question is asked before anything changes**, and each has a matching option so
  the same script runs unattended. Adding a prompt means adding an option.
- **Value-taking options** must go through `need_val`, or a forgotten value silently
  configures the empty string.

### Testing it without hardware

The technique used so far, and worth reusing: extract the real block from `setup.sh` with
`sed -n` and run it against stub functions, so the test exercises the shipped code rather
than a copy that can drift.

```sh
{ cat harness-prologue.sh                      # stub uci/init.d/say/ok/warn/die, fake state
  sed -n "$(grep -n '^absorb_wan_swconfig() {' setup.sh | cut -d: -f1),NNNp" setup.sh
} > /tmp/t.sh && sh /tmp/t.sh
```

Stub `uci` over a flat `key=value` file — and use `grep -F` / `grep -vF`, because section
ids like `@switch_vlan[0]` are regex character classes and a plain `grep` silently matches
the wrong thing (this cost a debugging cycle and looked like a script bug).

Shapes worth covering: DSA and swconfig; untagged- and tagged-CPU swconfig; 21.02+
(`config device` bridge) and pre-21.02 (`network.lan.type=bridge`) layouts; every refusal
path; and the static-address forms `1.2.3.4/24`, `1.2.3.4,255.255.255.0`, bare `1.2.3.4`.

### The AP conversion

Reversible, and committed but not applied until the reboot. `wan`/`wan6` deleted,
`dhcp.lan.ignore=1`, `firewall`/`dnsmasq`/`odhcpd` stopped and disabled (packages kept),
`/tmp/resolv.conf` relinked to `resolv.conf.auto` (nothing listens on 127.0.0.1 once
dnsmasq is off, and a hostname inform URL would stop resolving), radios un-`disabled`,
`lldpd.config.cid_interface` set.

Moving the WAN socket is two different jobs — on DSA its netdev joins `br-lan`; on
swconfig `absorb_wan_swconfig` moves the physical port into the LAN VLAN inside the switch
(bridging the WAN *CPU* netdev works but hairpins every frame through the SoC). That
function refuses and falls back to the bridge unless it can prove the geometry. Keep it
that way.

An interface with proto `pppoe`/`wwan`/`dhcpv6` is **named and left alone**, not deleted —
it may be a management link.

---

## Changing `install.sh`

Copies `openuf/` to `/opt/openuf`, creates `/etc/openuf`, symlinks `syswrapper.sh`,
installs `/etc/init.d/openuf`, then dependencies.

**openUF's own files go in before any package install.** The optional feature packages are
collectively larger than openUF (nftables alone is ~490 KB with its kernel modules), and
installing them first has filled a small overlay and left the product itself uncopied —
the install "succeeded" with no `/opt/openuf` on disk. Product first means a space
shortage costs a feature, never openUF.

`try_optional` only installs when there is room to spare *afterwards*: filling an overlay
to 100% breaks `state.json` writes, the package database, and any later upgrade.

`--bootstrap-adopt` creates the locked-down non-root `ubnt`/`ubnt` account, scoped to
running `syswrapper.sh set-adopt` only, which self-locks once adopted and re-enables on
factory reset.

---

## Landmines

- **AES-GCM is mandatory for adoption.** UniFi 10.4.57 will not finish provisioning a
  device that has never sent a genuine GCM inform; a CBC-only device sticks at "Adopting"
  forever. Needs a GCM-capable `lua-openssl`; the `openssl` CLI fallback is CBC-only.
- **`openuf_` is a UCI section name, not an SSID filter.** Sections are
  `openuf_<radio>_<sanitized ssid>`; the broadcast SSID is exactly what the controller
  sent, and every pushed WLAN is provisioned whatever it is called. The prefix only marks
  what openUF may delete. `get_vap_table` reports *every* enabled `wifi-iface`, including
  hand-made ones. What is configurable is whether hand-made SSIDs keep broadcasting:
  `use_only_unifi_wlan`, which stamps `openuf_autodisabled=1` on what it turns off so the
  change is reversible.
- **`libuci-lua` is required and fails silently.** It provides `require("uci")`, which
  every wireless read and write goes through, and it is not pulled in by `lua`. Without it
  the device adopts, reports its ports and statistics and looks completely healthy, while
  `radio_table` goes out **empty** — so the controller has no radio to provision a WLAN
  onto, accepts the push, and creates nothing. It is silent because every ucihelper call
  is `pcall`-wrapped (correctly — a UCI error must not take the inform loop down). Found
  on a real JIDU6101 after four pushed WLANs produced zero UCI sections. `inform.lua`'s
  `_warn_missing_uci` now shouts at startup and `tools/check.sh` tests for it; keep both.
- **Controller channel "Auto" means hostapd ACS picks**, and on mt7915/mt7986 it readily
  picks a DFS channel whose CAC then fails (`start_dfs_cac() failed` → `AP-DISABLED`), so
  a 5 GHz SSID silently never comes up while the controller reports it provisioned. The
  fix is `dev.conf.radio.<band>.acs_exclude_dfs = true` in the modelmap. A *maximum
  channel* is not a fix: DFS runs 52–144, so any cap below 149 keeps every failing channel
  and drops the working ones.
- **UniFi's `ieee_mode` token lies about the PHY, not the width.** 80 MHz on 5 GHz arrives
  as `11naht80` — still `ht`, which has no 80 MHz. Taken literally that became `HT80`, and
  `clamp_htmode` knocked it back to `HT40`, silently discarding the operator's setting.
  The width is the authoritative half; a width above 40 promotes to `VHT`. Confirmed live
  on a UCG Ultra.
- **The REGDOMAIN, not the hardware, applies the DFS flags.** Measured on one JIDU6101:
  under `IN`/`DE`/`US` channels 52–144 are all `(radar detection)`; under `PA` they carry no
  flag at all, and the identical HE160 config that never came up starts first try. That is
  what `config.country_override` is for — it programs the override into UCI `country` while
  stamping the controller's own value in `openuf_country`, which `get_radio_table` reports
  in preference, so the controller's site setting does not appear to change. Removing the
  override reverses both halves; never leave a foreign regdomain programmed silently.
- **160 MHz on 5 GHz needs working DFS** (or a regdomain that flags none), whatever `iw phy` claims. Every 160 MHz block is
  8 contiguous channels and every one that fits overlaps DFS (ch36 → seg0=50 spans 36–64;
  ch100 → 114 spans 100–128); the clear 149–173 range is only 140 MHz wide. So on a board
  with broken CAC, 160 MHz is unreachable on *any* channel and `acs_exclude_dfs` cannot
  help (a fixed channel skips ACS). That is what `htmode_max` is for.
- **"Force WiFi 4 Mode" does not touch `radio.<n>.ieee_mode`.** It works by making the WLAN
  2.4-only + WPA2 + no 802.11k/v + `bss_load_update_period=0`. So it collides with
  `htmode_floor`, which would put the HE IEs back in the beacon that the mode exists to
  remove — hence the per-radio suppression in `rf_config`. The mode is per WLAN, htmode is
  per radio; that mismatch is the whole difficulty.
- **`htmode_floor` is the ONE exception to "clamp downward only"** (`ucihelper.lua:124`).
  A controller that does not know the hardware pushes its default for the emulated model —
  802.11n/40 at a 4x4 WiFi-6 radio. A modelmap may declare a floor; the hardware clamp
  still runs after it, so a floor can never invent capability. Keep it opt-in per board.
- **A fresh OpenWrt ships every radio `disabled='1'`.** openUF writes that option only
  when the controller explicitly pushes a radio status, so a push that omits it leaves the
  radio off — provisioning "succeeds" and not one SSID is on the air. `setup.sh` clears it.
- **`wpad-basic-*` has no `bss_transition` at all** and errors the radio down. A full build
  is required for BSS Transition and Band Steering. `install.sh` cannot swap one out (the
  packages conflict, so `add` without `del` fails) — `setup.sh` does, keeping the same
  crypto library so it costs no extra flash.
- **lldpd's chassis ID must match `lan_cpueth`'s MAC** (`uci set
  lldpd.config.cid_interface=lan`) or the controller shows the wrong Parent Device: lldpd
  otherwise picks the lowest-numbered interface, which the gateway then learns under an ID
  matching no adopted device.
- **VLAN ids must be below the switch's VLAN table size** (16 on some boards) — netifd has
  no `vid` option, so the id doubles as the table slot.
- **8 MB flash is not enough** from a stock image: `lua-openssl` pulls in `libopenssl3`
  (~4.35 MB installed) and a stock 8 MB build leaves ~1.6 MB of overlay. Needs a custom
  image with the crypto in squashfs, or extroot.
- **WPA-Enterprise is unsupported and skipped**, not mis-provisioned: the wire protocol
  carries no RADIUS server, port or secret.

---

## File map

```
openuf/
  conf.lua          modelmap + ufmodel selection, runtime options (user-editable)
  modelmap/*.lua    hardware profiles          ufmodel/*.lua  UniFi identities
  inform.lua        TNBU inform loop, response dispatch, payload assembly (the core)
  announce.lua      L2 UDP discovery broadcasts (port 10001)
  crypto.lua        AES-128-CBC/GCM            inflate.lua  pure-Lua zlib inflate
  ucihelper.lua     all wireless UCI writes (VAPs, radios, VLAN networks)
  sysinfo.lua       /proc, iw, swconfig and bridge-fdb parsing
  switchvlan.lua    per-port VLAN assignment (swconfig only; refuses DSA)
  netconfig.lua     controller-pushed IP settings   led.lua  Locate / LED toggle
  firewall.lua      client block/unblock (nft `bridge openuf`)
  bcfilter.lua      multicast/broadcast blocker (nft `bridge openuf_bcfilt`)
  shaper.lua        WiFi speed limit (tc)       usteer.lua  band steering
  lldp.lua          neighbour table via lldpctl
  state.lua         /etc/openuf/state.json (authkey, adopted, cfgversion, inform_url)
  lib/lib.lua       globals every script expects; wraps `bit` so the same source runs
                    on the device's Lua 5.1 (luabitop) and a 5.3+ dev interpreter
  hook/             syswrapper.sh|.lua (set-adopt / set-inform / reset-inform),
                    adopt-shell.sh — the forced login shell for the bootstrap account,
                    which permits exactly `syswrapper.sh set-adopt <url> <key>` and
                    refuses everything else. That restriction IS the security boundary
  etc/init.d/openuf procd service: announce + inform instances
setup.sh            guided installer: AP conversion + deps + install
install.sh          file/service install and dependency resolution
tools/              dist.sh (package), check.sh (preflight), simulate.sh (e2e),
                    strip.lua, test_controller.py, validation/ (docker controller)
PROTOCOL-VALIDATION.md   evidence for every protocol claim — read before disputing one
REVERSE-ENGINEERING.md   the open questions: unimplemented surfaces + experiment plans
```

`PROTOCOL-VALIDATION.md` records what was confirmed against a live controller versus
inferred from decompilation, and **supersedes README/USAGE where they disagree**. If you
are about to change protocol behaviour, check there first for why it is the way it is.

`REVERSE-ENGINEERING.md` is the other half: what is *not* implemented, what is known about
each, and the next experiment. Before starting work on an unimplemented protocol feature,
read its entry — several have a "do not re-attempt" list that will save you a session. Its
first rule is the one to internalise: **never claim a capability bit openUF cannot honour**,
because that turns a missing feature into a silently broken one.
