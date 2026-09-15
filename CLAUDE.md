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

# Push this tree to adopted APs: builds with --verify, then runs the on-device updater
# on each (backup → install keeping conf.lua → restart → wait for an inform → roll back)
sh tools/deploy.sh --check <ap-ip>...   # read-only: what each AP runs
sh tools/deploy.sh <ap-ip>...           # OPENUF_SSH_PASS=... for a password-protected root

# Shell syntax — BOTH, every time (see "Shell code" below)
bash -n setup.sh && dash -n setup.sh
```

A new test file must be added to the hardcoded `test_files` list in
`tests/run_tests.lua` — it is not globbed. The runner now fails the run if a
`tests/test_*.lua` exists on disk that is not in the list, so forgetting is loud rather
than silent. CI also runs `tools/dist.sh --verify` on every push, not only on a release
tag.

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
catches bashisms `bash -n` accepts. CI does both for `setup.sh`, `install.sh`, `update.sh`
and `tools/deploy.sh`.

- `sed -i` with no suffix (GNU/busybox form). This **fails on macOS/BSD** — use
  `/opt/homebrew/opt/gnu-sed/libexec/gnubin` in `PATH` when testing locally.
- Avoid `case` inside `$( )`. It has bitten this repo: a `)` in a case pattern terminated
  the substitution early and wrote a garbage netmask. Assign to a variable first.
- `local` is fine inside functions, never at top level.
- A pipeline's exit status is its **last** command's. `sh tools/dist.sh --verify | tail -3`
  reported success while dist.sh had failed, and `deploy.sh` shipped the previous run's
  tarball. Send output to a file and test the command itself, and delete stale outputs
  before building.
- Test POSIX snippets under `sh`, not in the zsh you are typing into: zsh does not
  word-split an unquoted `$var`, so `for k in $list` runs once over the whole string and a
  correct `case`/`for` loop looks broken — or a broken one looks fine.
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

**An existing `conf.lua` is kept.** It holds the modelmap the device was adopted under,
and overwriting it on a reinstall (the natural upgrade path) reset the modelmap to the
generic one — on a DSA board that moves `lan_cpueth`, hence the identity MAC, hence
HTTP 400 forever. The shipped default lands as `conf.lua.dist`; `--replace-conf`
overwrites, and `setup.sh` passes it because it has just written `conf.lua` from its
interview. Options come after the action and an unknown one is an error, so a mistyped
flag cannot install silently without what it asked for.

**`update.sh` is the upgrade path, and it leans on two things `install.sh` provides.** It
installs `update.sh` as `/usr/bin/openuf-update` (a copy, not a symlink — it has to survive
its own `rm -rf /opt/openuf` during a rollback), and it leaves a build stamp in
`/opt/openuf/BUILD` (`dist.sh` writes one into a release tarball; a git checkout gets
`git describe`). The updater's health check reads `/tmp/openuf-status`, which `_tick`
rewrites after every completed cycle — `last_ok` on success, `last_fail` on a transport
failure, both kept, so a controller outage after a good update reads as "up but
unanswered" and is not rolled back. Keep that file flat `key=value`: busybox `sed` is what
parses it. `tools/deploy.sh` is the same updater driven from the dev machine over ssh, one
host at a time, with `dist.sh --verify` gating every push.

`--bootstrap-adopt` creates the locked-down non-root `ubnt`/`ubnt` account, scoped to
running `syswrapper.sh set-adopt` only, which self-locks once adopted and re-enables on
factory reset.

---

## Landmines

- **Everything the controller sends that openUF does not act on goes to the unhandled
  ledger, always.** `handle_response` records an unknown `_type` or `cmd` with its whole
  body, unknown top-level fields, and (through `_report_dropped_keys`) every `mgmt_cfg` key
  and `system_cfg` key shape no parser reads, into `unhandled.lua` → `/etc/openuf/unhandled.json`.
  So: implementing a new cmd or key means adding it to the dispatch or to `RECOGNIZED_*`, or
  it keeps being counted as ignored -- which is the honest state until it IS implemented.
  The ledger redacts by field NAME (`psk`, `passphrase`, `authkey`, `token`, `*key`...), so
  never hand it a payload whose secret sits under an innocent name, and never name a
  payload field of your own `*_key` (the first version did, and redacted its own sample).
  The `noop`'s `interval` is honoured (clamped 5–300 s); `_tick` re-reads it every cycle.
- **`syswrapper.sh 11k-scan` does not scan. It leaves a dated request file** (`/tmp/openuf-
  scan-request`) that the daemon's `_maybe_scan_neighbours` consumes on the next heartbeat,
  ignoring anything older than ten minutes. The scan code, the radios' netdev names and the
  cache the result lands in all live in the daemon; a second implementation in the hook
  would drift. A request older than the cutoff is what a stopped daemon leaves behind, and
  firing it at the next boot would land in hostapd's ACS sweep.
- **`l2guard` protects the VAPs only, never a wired socket, by design.** The controller's
  `--vlan-id <n> -p 802_1Q -j DROP` is bridge-wide on the stock firmware because there the
  tagged uplink is an 8021q sub-device that takes tagged frames before the bridge sees them.
  On a DSA board openUF's tagged uplink is `br-lan.<n>`, ON the bridge, so tagged frames
  from the uplink socket traverse it -- a bridge-wide rule kills the IoT WLAN's uplink. The
  uplink socket is a runtime detection that is refused when unsure, so the rule stays on
  the interfaces the controller's other eight rules name: the VAPs.
- **`sysconf` installs only commands in `CRON_COMMANDS`.** A pushed cron line is a string
  crond runs as root; the controller's is `syswrapper.sh 11k-scan`, and that maps to the
  verb this tree ships. Extend the table only alongside a new verb, never to "pass through".
- **`state.save` writes the whole table and `state.load` reads all of it back.** Eight
  fields are type-checked with defaults; everything else round-trips as-is. That
  symmetry is load-bearing: `swvlan_backup` (the switch reversibility ledger), `ip_mode`
  and the `static_*` fields, `locating`, `led_enabled` and the previous run's `mac` all
  live there, and `_warn_identity_change` only works because the previous MAC comes back.
  `load()` used to whitelist the eight and drop the rest on every start. The write is
  temp-file-and-rename, because a truncated file reads as "defaults" and un-adopts the
  device.
- **The inform loop is `_tick()`, and every stage in it is pcall-wrapped.** `build_json`
  shells out to a dozen tools; one nil in one field once crash-looped the daemon under
  procd. A bad cycle costs one heartbeat and one log line. Keep new stages inside the
  boundary, and keep `M.run` as nothing but the sleep loop around `_tick`.
- **Wire values that reach a shell are shape-checked first.** `netconf.1.ip`, the netmask,
  `route.1.gateway`, block-sta's `resp.mac`, the bcfilt allow-list and the MAC filter all
  go through `is_ipv4`/`is_mac` at the parser *and* again in netconfig/firewall/bcfilter.
  Pre-adoption the inform channel is plain HTTP under the well-known key, so a forged
  `setparam` is within reach of anyone on the path; without these it was a root shell.
- **`get_vap_table` reports AP-mode sections only, and `use_only_unifi_wlan` never touches
  a non-AP one.** A mesh point or station interface (a wireless backhaul) is a link, not a
  competing SSID, and may be the device's own uplink. `keep_wlan_sections` exempts named
  AP sections. Each VAP reports its own BSSID via `get_ifname_for_vap`, not the radio's
  first interface's.
- **`debug_caps` / `debug_payload_extra` are the one sanctioned exception to "never claim a
  capability you cannot honour".** They exist so the mesh go/no-go experiment is a
  `conf.lua` edit; the daemon shouts at startup while either is set. Never ship a default
  for them, and never let a real feature depend on them.
- **`ubus call network.wireless status` is cached per `build_json` pass** (`begin_pass` /
  `end_pass`), and `iw phy phyN info` per phy with a five-minute TTL in sysinfo. Both
  caches are dropped after `wifi reload`; `phy_caps` additionally re-reads for a minute
  after a regdomain write, because the driver applies the new domain only when the
  radios come back up. Tests that stub `_popen`/`_run_cmd` must reset these (the harnesses
  do).
- **sysinfo has the same lookup pass, and two TTL caches.** `sysinfo.begin_pass` is opened
  at the very TOP of `build_json` (before the uptime read) and closed on return and in
  `_tick`; inside it `/proc/net/arp`, `/tmp/dhcp.leases`, `/proc/uptime`, each `bridge fdb
  show br` dump and the bucketed ARL/FDB (`hosts_by_port`) are read once per payload.
  `bridge_of` and the default gateway's IP are cached for `UPLINK_TTL` (300 s) -- **a nil
  answer is never cached**, boot is full of them -- and `forget_uplink_cache` runs after a
  switch push because openUF moving a socket is the one change the TTL cannot see. The
  parsed phy caps live in the same cache entry as the dump's text. `lldp.neighbors` is
  cached 60 s, empty answers never. `ucihelper.get_radio_table` reads the wifi-device rows
  once per pass and hands each caller a COPY. Outside a pass everything reads every time,
  which is what keeps per-test stubs independent; harnesses reset `_uplink_cache`,
  `_phy_info_cache`, the lldp caches and call `end_pass()` on the way in and out.
- **Kernel state is rebuilt at startup, because the controller never re-pushes it.** After
  a reboot `cfgversion` matches and the reply is `noop` with no `system_cfg`, so anything
  applied only from `apply_config`/`handle_response` is gone for good. `M.run` therefore
  reapplies, in order: the pushed static IP (`_reapply_static_ip`, before
  `_populate_net_info`), the bridge identity (`ensure_bridge_identity`), the blocked-client
  rules, the blocker and speed limit from the `openuf_bcfilt*`/`openuf_ratelimit_*` stamps
  (`reapply_runtime_rules`), the LED state, and the nft MAC tap
  (`switchvlan.reconcile_mac_taps`, from the `openuf_brport<vid>_<socket>` sections). Every
  one is pcall'd. A new kernel-resident feature belongs in that list or it is a reboot bug.
  The IP branch of `handle_response` saves state the moment the interface changes, not at
  the tail: anything after it can raise, and the startup reapply reads what was saved.
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
- **A UCI section name may contain only `[A-Za-z0-9_]`, and libuci discards anything else
  silently** (`set` and `commit` both return true). `wlan_add` sanitizes with `[^%w_]` and
  appends a hash of the original SSID when it had to change anything; the test mocks refuse
  an invalid name so the class cannot quietly widen again. An SSID with a hyphen used to
  provision nothing.
- **Minimum RSSI is a fixed wire offset, `dBm = raw - 95`**, not "raw plus the live noise
  floor". The controller never learns a radio's noise floor, so it has nothing but a
  constant to encode with; the old conversion drifted 12 dB between drivers.
- **Never set `ft_psk_generate_local`.** It is FT-PSK-only, and pinning it stops OpenWrt
  configuring the key holders FT-SAE needs, so WPA3 clients silently lose fast roaming.
- **Two kernel modules are not implied by their packages.** `kmod-nft-bridge` for the
  Multicast/Broadcast Blocker's `meta` rule (everything else in that table builds without
  it, so the control looks enabled and filters nothing) and `kmod-sched-act-police` for the
  upload half of WiFi Speed Limit. Both modules now warn by name when `nft`/`tc` reject the
  rule, and both installers add them. `os.execute` returns the raw exit status on Lua 5.1
  (0 = success, non-zero = failure, BOTH truthy), so any "did it work" check needs
  `exec_ok`, not a bare truth test.
- **The wire's `11naht40` names a width, not 802.11n.** `rf_config` runs a bare `HT<width>`
  at the band's best PHY (`best_phy`) unless the WLAN has Force WiFi 4 Mode; the modelmap
  `htmode_floor` is now only needed to raise the WIDTH. 2.4 GHz is capped at 40 MHz in
  `parse_phy_caps` whatever the PHY says.
- **`uplink_detect = "fdb"` reads ONE bridge's FDB** (`sysinfo.lan_bridge` resolves
  `lan_cpueth` whether it names the bridge or a socket). The whole-FDB read took whichever
  learned line came first for the gateway's MAC, which on an AP with a tagged SSID can be
  the VLAN bridge's own port.
- **DSA per-port VLAN is a bridge move, never `bridge-vlan`.** `switchvlan.dsa_apply` moves
  the socket into `br-openuf<id>`; `ucihelper.ensure_vlan_network` owns the tagged uplink
  member and never evicts anyone else; `apply_config`'s `keep_vlans` keeps a wired-only
  VLAN's bridge alive. The ledger is `st.dsa_brlan_ports`, and a push with no `switch.*`
  keys counts as "off" only while a ledger exists.
- **A moved DSA socket, and the tagged uplink sub-device, run with MAC learning OFF, and
  that is not optional.** The VLAN bridge is software but the socket is a port on the same
  ASIC as the uplink, and the ASIC has ONE address table: with learning on it files the
  attached device against the socket and hardware-drops every VLAN-tagged reply to it,
  while outbound stays perfect and every counter says the move worked (upstream: 4 DHCP
  DISCOVERs out, nothing back; 2 ms OFFER with learning off). `dsa_apply` writes
  `openuf_brport<vid>_<socket>` (`learning '0'`), `ensure_vlan_network` writes
  `openuf_brport<vid>` for `<uplink>.<vid>`; both are swept by `prune_vlan_networks` and
  `dsa_restore`. The bill: that socket's hosts vanish from `bridge fdb`, the only
  wired-host source on DSA. `switchvlan.reconcile_mac_taps` pays it with an nft
  bridge-family tap (`table bridge openuf_learn`, sets `portmacs` and `portips`, 5-minute
  timeouts), read by `sysinfo.mac_table(ifname, bridge, allow_tap)` only when the FDB is
  silent and only for a socket whose bridge is not the uplink's. Rows carry `vlan` (from
  the `br-openuf<vid>` name) and the tap's `ip`, because the controller files a wired
  client under a network by `host.vlan` (default 1) and the AP has no ARP entry for a host
  on a VLAN it holds no address on. **None of this has run on a JioRouter yet.** The
  uplink socket stays silent, gateway included: one known MAC alone on a port lands in
  `downlink_table` and inverts the topology (feature 39 in PROTOCOL-VALIDATION.md).
- **`_state_mtime` is the file's CONTENTS, not an mtime**, and nothing forks `stat` any more
  (BusyBox may have no applet; contents beat one-second mtime granularity anyway).
  `coreutils-stat` is no longer installed. `conf.lua`'s `inform_url` seeds
  `state.DEFAULT_INFORM_URL` and only fills a `state.json` with no URL of its own.
  `debug_dump_file` is capped at `debug_dump_max_bytes` (4 MiB, restart with a marker line,
  never rotate). `inflate` RAISES on a truncated stream -- it used to feed zero bits and
  spin forever inside a pcall nothing could interrupt.
- **`install.sh` registers `/etc/openuf/` and `conf.lua` in `/etc/sysupgrade.conf`**, or a
  firmware upgrade un-adopts the device. Append only when absent (`grep -qxF`), terminate a
  last line that lacks a newline first, and on uninstall drop only the `conf.lua` line --
  the state dir line stays because the directory does. Rewrite the file only on grep exit
  0 or 1; exit 2 with a full `/tmp` would otherwise truncate the user's own keep list.
- **A station's RRM capability bits are not a promise.** AP2's one "capable" client
  advertises passive, active and table beacon measurement and answers every request with
  mode 0x02 "incapable" -- and hostapd never notifies a bodiless refusal over ubus, so the
  only signal is silence. `_rrm_tick` asks a station at most `RRM_MAX_UNANSWERED` times
  without a mode-0 report before benching it for `RRM_BENCH_SECONDS`; the operating class
  follows the band the station is on (81 for 2.4 GHz, 115 for 5 GHz), because a 2.4-only
  client cannot measure a 5 GHz class at all.
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
  sysinfo.lua       /proc, iw, swconfig and bridge-fdb parsing; the per-payload lookup
                    pass and the 300 s uplink cache; the nft MAC-tap reader
  switchvlan.lua    per-port VLAN assignment: switch_vlan sections on swconfig, a bridge
                    move + learning off + nft tap (`bridge openuf_learn`) on DSA
  netconfig.lua     controller-pushed IP settings   led.lua  Locate / LED toggle
  firewall.lua      client block/unblock (nft `bridge openuf`)
  bcfilter.lua      multicast/broadcast blocker (nft `bridge openuf_bcfilt`)
  shaper.lua        WiFi speed limit (tc)       usteer.lua  band steering
  lldp.lua          neighbour table via lldpctl (cached 60 s; an empty answer never is)
  rrmscan.lua       802.11k beacon-report neighbour enrichment (from upstream)
  unhandled.lua     /etc/openuf/unhandled.json: every _type, cmd, mgmt_cfg key and
                    system_cfg key shape the controller sent that nothing here acted on,
                    with counts and a redacted body -- always on, bounded
  sysconf.lua       controller-managed system settings: system.timezone and ntpclient.*
                    into UCI (stamped, reversible), cron.* into a marked block of
                    /etc/crontabs/root (allow-listed commands only: `syswrapper.sh 11k-scan`)
  l2guard.lua       the ebtables.* block as nft `bridge openuf_l2guard`: BPDU and 802.1Q
                    drop on the AP VAPs only; intent + names in state.json for the reboot
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
update.sh           on-device updater (installed as openuf-update): backup, install keeping
                    conf.lua, restart, wait for /tmp/openuf-status, roll back on failure
tools/              dist.sh (package), check.sh (preflight), simulate.sh (e2e),
                    deploy.sh (push a build to adopted APs and run update.sh on each),
                    heartbeat-probe.lua (what one inform costs a board: forks and reads),
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
