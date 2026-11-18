# openUF — working notes

A Lua daemon that makes an OpenWrt device appear to a UniFi Network Application as a
Ubiquiti **U6-InWall** access point: L2/L3 adoption, controller-pushed SSID and radio
config, live client/radio/port statistics. AP emulation only — gateway (USG) and switch
(USW) are not implemented and not planned.

Two orthogonal concepts, constantly confused:

- **modelmap** (`openuf/modelmap/*.lua`) — *your real hardware*: radio names, ethernet
  sockets, switch geometry, status LED.
- **ufmodel** (`openuf/ufmodel/*.lua`) — *the UniFi identity presented to the controller*.
  `u6iw` is the only one validated end-to-end. `uhdiw` (UAP-IW-HD: WiFi 5, the same five
  sockets), `u7hd` (UAP-AC-HD: WiFi 5, two sockets, for the Deco M5 and M4R; adopted once) and
  `u6mp` (U6 Mesh Pro: WiFi 6, two sockets, for the OpenWrt One; never adopted) are sourced from
  Ubiquiti's firmware catalog and device database -- see `docs/agents/device-maps.md`, "Adding a UniFi identity".

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
# to the source and still passes the suite. Run it in the same shell as the
# luarocks eval above: without LUA_PATH the suite step fails on lua-cjson and
# --verify reports a false failure.
sh tools/dist.sh --verify

# Push this tree to adopted APs: builds with --verify, then runs the on-device updater
# on each (backup → install keeping conf.lua → restart → wait for an inform → roll back)
sh tools/deploy.sh --check <ap-ip>...   # read-only: what each AP runs
sh tools/deploy.sh <ap-ip>...           # OPENUF_SSH_PASS=... for a password-protected root

# Put this tree onto an AP's RUNNING prefix -- the package's /usr/lib/openuf or
# install.sh's /opt/openuf, whichever holds inform.lua -- with .pre-hotpatch backups,
# the init script included when it differs. deploy.sh only ever updates /opt/openuf,
# which on a device that also has the package installed is the dormant copy.
sh tools/hotpatch.sh [--repush] <ap-ip>  # --repush blanks cfgversion for a full config push

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
operators (`luabitop` provides `bit.*`), `break` must be the last statement in its block,
no `\xNN` string escapes (5.1 silently emits the letters `x07`; use `string.char`), no `\z`,
`\u{}` or `table.unpack`. `os.execute` returns a number on 5.1, and both 0 and 1 are truthy,
so normalise before branching. OpenWrt's Lua carries the LNUM patch: `string.format("%d", x)`
**raises** for |x| > 2^31 on the APs (reproduced on AP2's 5.1.5, 2026-10-18) and not on CI or a
dev machine -- format epochs in ms and other large values with `%.0f`. A newer local Lua will happily accept code the device rejects —
CI is the check, and AP2's own `lua` (`loadfile` on each module) is the quickest local one.
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

## Read the notes for the area you are changing

This file is the index. The detail lives in `docs/agents/`, one file per area, and is NOT
loaded for you: **open the file for the area before you change anything in it.** Each is a list
of things that are invisible without hardware and have already been broken once.

| Changing | Read first |
|---|---|
| `openuf/modelmap/*`, `openuf/ufmodel/*`: a new board, a new UniFi identity, `lan_cpueth`, LEDs | [docs/agents/device-maps.md](docs/agents/device-maps.md) |
| `inform.lua`, `announce.lua`, `state.lua`, `sysinfo.lua` caches, crypto, STUN, capability bits, startup reapply, anything a controller push drives | [docs/agents/daemon.md](docs/agents/daemon.md) |
| `ucihelper.lua`: WLANs, radios, channel width, DFS, security, roaming, speed limit, schedules | [docs/agents/wireless.md](docs/agents/wireless.md) |
| `switchvlan.lua`, `l2guard.lua`, `meshvlan.lua`, `backhaul.lua`: per-port VLAN, tagged SSIDs, uplink detection, mesh | [docs/agents/network-and-switch.md](docs/agents/network-and-switch.md) |
| `setup.sh`, `install.sh`, `update.sh`, `tools/deploy.sh`, `openuf/hook/*`, dependencies, the AP conversion | [docs/agents/installers.md](docs/agents/installers.md) |
| `package/`: the LuCI app, the device page, the Halo theme, SDK builds | [docs/agents/luci.md](docs/agents/luci.md) and PACKAGING.md |
| An upstream sync, another fork, `plugins.lua`, the licence, test fixtures | [docs/agents/upstream.md](docs/agents/upstream.md) |
| Finding which file does what | [docs/agents/file-map.md](docs/agents/file-map.md) |

A change that crosses areas reads each file it crosses. When unsure which area a symptom
belongs to, `grep -rn "<symbol>" docs/agents/` finds the note.

**Keeping it this way.** A new landmine or procedure goes into the area file, not here. This
file changes only for a command, a hard constraint, or a new row in the table above. Code
comments that cite a note name the area file (`docs/agents/wireless.md, "..."`).

---

## The two evidence documents

`PROTOCOL-VALIDATION.md` records what was confirmed against a live controller versus
inferred from decompilation, and **supersedes REFERENCE/USAGE where they disagree**. If you
are about to change protocol behaviour, check there first for why it is the way it is.

`REVERSE-ENGINEERING.md` is the other half: what is *not* implemented, what is known about
each, and the next experiment. Before starting work on an unimplemented protocol feature,
read its entry — several have a "do not re-attempt" list that will save you a session. Its
first rule is the one to internalise: **never claim a capability bit openUF cannot honour**,
because that turns a missing feature into a silently broken one.
