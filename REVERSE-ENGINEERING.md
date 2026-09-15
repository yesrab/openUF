# Reverse-engineering notebook

Working notes for protocol surfaces openUF does **not** implement yet, and the plan for
each. This file is the *open questions*; [PROTOCOL-VALIDATION.md](PROTOCOL-VALIDATION.md)
is the *answers*.

**Promotion rule:** the moment something here is confirmed against a live controller, move
it into `PROTOCOL-VALIDATION.md` (with the evidence) and leave only a one-line pointer
behind. Nothing should be documented in two places — this file drifts the fastest.

## Aim and ground rules

The goal is **breadth of genuine compatibility**, not a demo that lights up one checkbox.
Concretely, carried over from how the confirmed work was done:

1. **Never claim a capability that isn't implemented.** A capability bit makes the
   controller emit config and change its UI. Claiming one openUF cannot honour converts a
   missing feature into a silently broken one, which is strictly worse — the controller
   reports success and the device does nothing. `inform.lua` already says this about
   `wifi_caps2`, and it is the single most important rule in this file.
2. **Confirmed-live beats decompiled beats inferred**, and the difference is always
   recorded. A decompile tells you what the controller *can* do; only a capture tells you
   what it *does*.
3. **One variable per experiment.** Every hard bug in this project so far looked like
   something else first (see PROTOCOL-VALIDATION's FIXED sections).
4. **Silence is data.** A push that never arrives is as diagnostic as a malformed one —
   see the mesh investigation below, where 83 consecutive `noop`s were the finding.

---

## How to resume

### Lab

| Role | Address | Notes |
|---|---|---|
| Controller | UniFi Cloud Gateway Ultra | Network **10.6.101** as of 2026-09-06 (`unifi.version` in its own `system_cfg`; it was 10.4.57 on 2026-09-01). The pinned Docker baseline is still 10.4.57, so a bytecode finding from it needs a live re-check before it is trusted against this gateway |
| AP1 | `192.168.1.22` (DHCP; was `.25` on 2026-09-01) | openUF on `jiorouter,ax6000-jidu6j01`, wired. Runs a custom OpenWrt SNAPSHOT image (r36016+4, kernel 6.18.44) whose package feed carries no `kmod-nft-bridge` / `kmod-sched-act-police`, so the Blocker's `meta` rule and the upload shaper are inert on it until the image is rebuilt with both. root has a password (not recorded here — `OPENUF_SSH_PASS` for `tools/deploy.sh`). Clock is UTC, AP2's is local |
| AP2 | `192.168.1.147` (DHCP; was `.149` on 2026-09-06, `.151` on 2026-09-01) | openUF on `jiorouter,ax6000-jidu6101`, wired, `country_override = "PA"`. root has no password and dropbear accepts the blank login, so `ssh -o BatchMode=yes root@192.168.1.147` works with no helper. **The on-device test box** (2026-09-15): packages may be installed on it; AP1 runs a custom image and is not for testing. Its clock was **8 days 4 h slow** on 2026-09-15 with `sysntpd` running (backlog row 13) and was stepped by hand with an unjailed `ntpd -q`; ledger and dump timestamps before 13:22 UTC that day read "September 7" for that reason. `tcpdump-mini` is installed on it |

Both APs present as `u6iw`. SSH credentials are deliberately **not** recorded here — this
file is committed. Keep them in your own notes or a gitignored file.

Site WiFi as of 2026-09-01: `The SCP Foundation` (both bands) and `SCP IOT` (2.4 GHz,
tagged VLAN 10 via `br-openuf10`).

### Pending UI experiments (need a controller click; AP2 is armed)

Each is one action in the controller UI with `debug_dump_file` armed on AP2 (it is, as of
2026-09-15 -- `grep debug_dump /opt/openuf/conf.lua`; a reboot empties the tmpfs file but
the option re-arms it). Read-out for all three:

```sh
grep -v ' TX ' /tmp/openuf-dump.txt | tail -20          # what arrived, newest last
lua -e 'local c=require"cjson"; local d=c.decode(io.open("/etc/openuf/unhandled.json"):read("*a"))
  for id,e in pairs(d.entries) do if id:match("^field/") or id:match("^cmd/") then print(e.count, e.last_seen, id, c.encode(e.payload)) end end'
```

| # | Do | Look for | Row |
|---|---|---|---|
| A | Open **AP2's device panel** and its **Radios** and **Clients** tabs for 30 s (the RF stats / Environment page was already tried on 2026-09-15: `live_update` stayed `false`, `interval` rose to 16–19) | a `noop` with `live_update: true`; note what `interval` does | 17 |
| B | **Block** any client connected to AP2, wait 20 s, **unblock** it | the `setparam` after the block: is `blocked_sta` still `""` or does it carry the MAC? (and the `cmd:block-sta` itself, already handled) | 16 |
| C | Create a **new** test WLAN marked as a **Guest** network, Apply, wait 30 s, delete it | new `system_cfg` key shapes in the ledger (`guest.*`, `redirector.*` moving off `disabled`, anything else), and whether the guest option was even offered for this device | 8 |

### Capturing what the controller sends

**First stop, no setup: `/etc/openuf/unhandled.json`.** Since 2026-09-15 every response
`_type` and `cmd` openUF does not handle is recorded there **with its whole body**, and
every `mgmt_cfg` key and `system_cfg` key shape no parser reads with one sample value --
always, on every AP, with a count and first/last seen (USAGE § 3, `unhandled_file`). Had it
existed on 2026-09-06, the `mesh-halt` body would be in it. Read it with:

```sh
lua -e 'local c=require"cjson"; local d=c.decode(io.open("/etc/openuf/unhandled.json"):read("*a"))
  for id,e in pairs(d.entries) do print(e.count, e.first_seen, e.last_seen, id) end' | sort -k4
```

An entry under `cmd/` or `response/` is a new verb; under `mgmt_cfg/` and `system_cfg/`,
most rows are keys dropped on purpose (each explained in PROTOCOL-VALIDATION.md) -- what
matters is a row whose `first_seen` is today. The full capture below is still what a
new *shape* needs, because the ledger keeps one sample per key shape, not the whole blob.

The one tool that matters for a full capture. In `conf.lua` on the device:

```lua
debug_dump_file = "/tmp/openuf-dump.txt",   -- default nil
```

then `/etc/init.d/openuf restart`. Every decrypted inform **response** is appended
verbatim with a UTC timestamp, before dispatch. It shares its gate with the
dropped-key reporter (`M._debug_dropped_keys`), which logs the key *prefixes* of any
config blob no pass recognised — that is how you find fields openUF is ignoring.

Read it with:

```sh
grep -o '"_type":"[a-z_]*"' /tmp/openuf-dump.txt | sort | uniq -c   # is anything arriving?
grep -v '"_type":"noop"' /tmp/openuf-dump.txt                       # only the real pushes
```

To see both directions, add `debug_dump_requests = true`: every payload openUF sends is
appended as a line tagged ` TX ` and every transport failure as ` ERR ` (an `ERR HTTP
400` streak is the identity-MAC problem, see CLAUDE.md). Response lines stay untagged,
so the two recipes above keep working; `grep -v ' TX '` hides the requests again.

⚠️ The file contains PSKs and the `authkey`. It is on tmpfs (gone on reboot); set the
option back to `nil` and delete the file when done.

### Claiming a capability without a code change

`conf.lua` has two research-only switches for exactly the experiments below:

```lua
debug_caps = {wifi_caps2 = 0x41},              -- replace a claimed mask (nil = shipped value)
debug_payload_extra = {uplink = {type = "wireless"}},   -- extra top-level payload fields
```

`inform.lua`'s rule is "never claim a bit openUF cannot honour"; these are the sanctioned
exception, and the daemon logs `DEBUG OVERRIDES ACTIVE` at every start while either is set.
Unset them when the experiment is over.

### Neighbour visibility

`scan_radio_table` is read from the kernel's BSS cache, which forgets a network ~30 s
after it was last seen (and the controller drops `age >= 30`). The AP itself never scans
unless asked, so the Environment view — and any parent-AP list built from neighbours — is
only populated right after a scan. Two `conf.lua` options fill it: `rrm_enrichment` (on by
default, adopted from upstream) asks one 802.11k-capable client at a time to sweep and
report, at no cost to the AP; `neighbour_scan_interval = 300` makes the AP sweep itself at
that cadence (off by default: each scan stalls clients for a moment). The 13-neighbour
figure below was measured right after a manual `iw scan`.

To force a re-push when the controller has gone quiet, blank `cfgversion` in
`/etc/openuf/state.json` and restart. **Note:** this stopped working reliably part-way
through the earlier validation sessions — the controller sometimes answers only `noop`
regardless. When that happens, verify the code path with a synthetic wire payload against
the test suite instead of fighting the controller.

### SSH helper

`/tmp` helpers do not survive; expect to rebuild them. Pattern (no password in-repo):

```sh
# /tmp/rsh — expect wrapper; raise `set timeout` for long watch loops
set timeout 300
spawn -noecho ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
    -o LogLevel=ERROR -o PreferredAuthentications=password \
    -o PubkeyAuthentication=no root@<ap-ip> [lindex $argv 0]
expect { -re "(?i)password:" { send "<password>\r"; exp_continue }  eof {} }
```

Device shell is busybox ash: `grep -vc` prints `0` **and exits 1**, so
`n=$(grep -vc X f || echo 0)` yields `"0\n0"` and then `bad number`. Use
`n=$(grep -v X f | wc -l)`.

---

## Investigation 1 — Mesh / wireless uplink  🔴 BLOCKED

**Status:** not implemented, and **not reachable by capture** in its current state. The
blocker is identified and the next experiment is cheap. Deprioritised 2026-09-01 by
choice, not by difficulty.

### The symptom

Ticking **mesh connect** on AP2 reverts to unticked on the next inform. Selecting it also
reveals an **uplink priority dropdown that is empty** — nothing can be chosen.

### Evidence — 2026-09-01, live, UCG Ultra 10.4.57

**1. The controller sends nothing at all.** `debug_dump_file` armed on AP2 across ~9
minutes and *multiple* Apply clicks:

```
=== distinct _type values seen ===
     83 "_type":"noop"
```

83 responses, 83 `noop`. Zero config pushes, zero `cmd`. **The mesh setting is rejected
client-side in the controller UI and never reaches the wire.** This is the central fact:
there is no malformed push to study and no handler to fix.

**2. RF is not the cause.** AP2 → AP1, measured with `iw scan`:

| Band | Detail | Signal |
|---|---|---|
| 2.4 GHz | both APs co-channel on ch 1 | **−12 dBm** |
| 5 GHz | AP1 on ch 100 (160 MHz) | **−13 dBm** |

**3. Neighbour reporting is not the cause.** openUF's own `sysinfo.scan_table` returns 13
neighbours on `phy0-ap0`, including both of AP1's BSSIDs with correct ESSID and RSSI, and
these go upstream in `scan_radio_table`:

```
AP1 SEEN: 78:bb:c1:fe:3f:ca  The SCP Foundation  rssi=-11
AP1 SEEN: 7a:bb:c1:fe:3f:ca  SCP IOT             rssi=-12
```

**Conclusion:** the child can see the parent, at near-touching signal, and says so. The
dropdown is still empty. Therefore the parent list is built from **adopted, mesh-*capable*
devices**, and capability is asserted by the device — not derived from scan data. Neither
AP claims it, so the site contains no eligible parent, the form is invalid, and Apply is a
no-op.

### Evidence — 2026-09-06, AP1's log, UCG Ultra 10.6.101

The first mesh-related command recorded in this lab. AP1's `logread` holds, at 10:59:05
UTC (that box's clock is UTC), between two ordinary config pushes:

```
inform: cmd: mesh-halt
```

That is the `cmd` dispatcher logging a command it does not handle — so the controller
*does* have a device-facing mesh verb, and it sent it to a device that claims no mesh
capability at all. It arrived during the RF-scan session against AP2, while the app was in
use against both APs; nothing was captured on AP1 that day (`debug_dump_file` was armed on
AP2 only), so it is not yet tied to a specific action. Worth chasing before step 1 of the
experiment plan, because it is a capture that needs no capability claim: arm
`debug_dump_file` on AP1, repeat what the app was doing around that time (ticking and
un-ticking **mesh connect** on either AP, the uplink priority dropdown, an RF scan), and
see whether `mesh-halt` carries a body — and whether it has a counterpart that *starts*
something.

### The three gaps in openUF

1. **No `uplink` object in the payload.** Every top-level key `build_json` emits
   (`inform.lua:1380-1473`, built once and handed straight to `cjson.encode` — nothing
   mutates it later):

   ```
   mac serial model platform hostname ip inform_url cfgversion uptime time
   version required_version bootrom_version country_code mem_total mem_used
   fw_caps wifi_caps2 satisfaction spectrum_scanning spectrum_scan_timestamp
   system-stats if_table radio_table radio_table_stats vap_table
   scan_radio_table port_table lldp_table
   ```

   No `uplink`, no `uplink_table`, no `mesh_*`.

   **Why openUF gets away with this while wired, and cannot while meshed.** The controller
   already holds an `uplink` object for these APs, and PROTOCOL-VALIDATION records its
   provenance: `uplink_source: "lldp_downlink"`. The controller *synthesises* the wired
   uplink from the **gateway's** LLDP view of its own downlink — the AP never has to report
   it. There is no equivalent for an over-the-air hop: no gateway port faces it and no LLDP
   crosses it, so a wireless uplink can only ever come from the AP's own report. That is
   why this gap is invisible today and fatal for mesh, and it means `uplink` must be
   *emitted*, not merely permitted.

2. **Capability bits deliberately unset.** `fw_caps = 0x110`, `wifi_caps2 = 0x40`, and
   `wifi_caps` is not sent at all. Per rule 1 above, this is correct as long as mesh is
   unimplemented.

3. **No station/mesh-mode interface support.** `ucihelper` only ever writes `mode=ap`.
   Live on AP2, all three interfaces are `type AP` — no mesh point, no sta.

### Where it is blocked, and the chicken-and-egg

The obvious move — capture the mesh push and implement what it says — **cannot work**. The
controller will not push mesh config until it believes mesh is possible, and it will not
believe that until openUF claims the capability. So *finding the gate* is step one, not
step three, and it has to come from static analysis rather than from the wire.

### Experiment plan (in order, cheapest first)

**Step 0 — find the field the dropdown filters on. Start in the frontend, not the JVM.**
The dropdown is rendered client-side, so its filter predicate is plain JS in the live
controller's own React chunks — greppable, and it names the exact device field. This is
the same technique that cracked `band` in `scan_table` and `advertise_ap_name`
(PROTOCOL-VALIDATION → "Decompiling the controller", step 4), and it is far cheaper than
a decompile. Fetch the chunks from the live controller and grep for `mesh`, `uplink`,
`wirelessUplink`, `meshParent`, `uplinkPriority`.

**Step 1 — confirm in the bytecode.** Targets, from the existing class index:
- `com.ubnt.data.uuvchZbWVhirD` — `hasFirmwareCapability` / `hasWifiCapability2`; find the
  method the mesh UI gates on and read off its bit.
- `com.ubnt.data.dhdeXcHqLRBKMUZk` — the **model registry**. A real U6-InWall does support
  wireless uplink, so check whether eligibility is a registry property (which openUF gets
  for free by presenting as `u6iw`) or a device-reported bit (which it must claim). This
  distinction decides how much work the whole feature is.
- `com.ubnt.service.config.eWivisHeQsnaqDtx` — the `system_cfg` generator; find the branch
  that would emit backhaul fields, which previews step 3 for free.

**Step 2 — the go/no-go.** Claim the candidate bit on **both** APs via `debug_caps` in
`conf.lua` (see "Claiming a capability without a code change" above), restart, and look
at the dropdown. If AP1 appears as a selectable parent, the gate is understood and
everything downstream is ordinary work. If it stays empty, the gate is elsewhere — likely
the model registry or a field we have not found. This is a `conf.lua` edit and a
30-second test; do it before writing any implementation. If the candidate is a payload
field rather than a bit, `debug_payload_extra` puts it on the wire the same way.

**Step 3 — only now is the wire useful.** With the bit claimed, arm `debug_dump_file`
(plus `debug_dump_requests`, so the capture shows what was claimed next to what came
back) on both APs, select the parent, Apply, and capture. That push is the backhaul
specification: SSID, PSK/derivation, and whichever `radio.<n>`/`wireless.<n>` keys carry
it.

**Step 4 — implement.** `uplink` in the payload, sta-or-mesh mode in `ucihelper`, and the
adopt-over-wireless bootstrap if it turns out to be separate.

### Open questions

- Which bit — or which model-registry property — gates mesh-parent eligibility? `wifi_caps`
  is entirely unexplored (it gates `supportBandsteering()`/`supportZeroHandoff()`, and
  openUF sends neither). `wifi_caps2`'s other bits are documented as gating "Mesh MLO
  parent/child" — but **MLO is WiFi 7**, so that is probably *not* classic wireless uplink.
  Do not assume the two share a bit.
- Does the parent advertise a dedicated backhaul BSS? If so, is its SSID/PSK pushed
  per-device or derived from the site key? (A derivation would have to be reproduced, which
  is a much larger job than reading a pushed field.) **Two candidates surfaced by the
  ledger on 2026-09-15**, from a full push to AP2: a top-level **`mesh.status=disabled`**
  block -- so the mesh config has a home in `system_cfg`, gated like every other block --
  and **`unifi.key`**, a 32-hex-character value that is *not* the device's authkey and not
  any WLAN's PSK. A site-wide 16-byte key pushed to every device is exactly what a
  derived backhaul PSK would be computed from. Neither is understood yet.
- What is the exact shape of `uplink` for a wireless-uplinked AP? Candidate fields from a
  real capture: `type`, `ap_mac`, `essid`, `bssid`, `rssi`, `channel`, `uplink_source`.
  Compare with the wired shape already recorded in PROTOCOL-VALIDATION (`uplink_remote_port`,
  `uplink_source:"lldp_downlink"`). **A historical answer exists:** fxkr's real UAP capture
  (2015 firmware, `unifi-protocol-reverse-engineering/README.md`) has a top-level `uplink:
  "eth0"` *string* and, in `vap_table`, an entry with `usage: "uplink"`, `essid:
  "vport-<SERIAL>"`, `state: "INIT"` (vs `"RUN"` on the user VAP), `bssid` all-zero while
  down -- the wireless uplink as a station VAP. Whether the 10.x controller still reads
  `usage`/`vport` is a constant-pool grep away (step 1). The same payload carries
  `isolated: false` and per-VAP `ccq`, `rx_nwids`, `rx_crypts`, `rx_frags`, none of which
  openUF sends.
- Does real UniFi mesh use **4addr/WDS** or **802.11s**? This decides the `ucihelper`
  implementation and cannot be guessed from the controller side alone.
- Is adoption over a wireless uplink a separate bootstrap flow, or does the child simply
  inform normally once bridged?

### Do not re-attempt

- **Waiting on the wire for mesh config while capabilities are unclaimed.** Measured:
  83/83 `noop` over 9 minutes with repeated Applies. Nothing arrives. Ever.
- **Blaming RF or the scan table.** Both measured and ruled out above (−12 dBm, 13
  neighbours reported correctly).
- **Reading the AP-side client out of U6-IW firmware.** Already a documented dead end —
  the official image is a kernel-only OTA delta with no rootfs (PROTOCOL-VALIDATION →
  "Dead ends"). If the AP-side mesh behaviour ever has to be known first-hand, the only
  live routes are a packet capture between *real* hardware and a real controller, or
  pulling the binary off an owned device over SSH.

### The pragmatic fallback, if mesh is ever needed before it is understood

A wireless hop can be had **today**, outside openUF: 802.11s (or 4addr WDS) between the
two APs, bridged into `br-lan`. The controller keeps seeing a wired uplink — as far as the
inform payload is concerned it *is* wired, since the uplink is a bridge port — so there is
no mesh topology in the UI, but the physical link is real. Three gotchas, all verified:

- **`use_only_unifi_wlan` no longer disables it, and it is not reported as a VAP.** Since
  2026-09-06 that option exempts every `wifi-iface` whose `mode` is not `ap`, and
  `get_vap_table` skips them, so an 802.11s or `sta` backhaul survives with the option
  left `true` and does not show up in the controller as a nameless phantom SSID. Only
  an AP-mode section needs listing in `keep_wlan_sections`. Naming the section
  `openuf_backhaul` is still wrong — `wlan_clear` *deletes* `openuf_*` sections on every
  push.
- **The channel must be fixed in the controller, on both APs.** A mesh/WDS station has to
  sit on the parent's channel, and openUF rewrites `radio.<n>.channel` from every push.
  Both radios are currently `channel='auto'`, which is exactly why they drifted apart to
  ch 100 (AP1) and ch 36 (AP2). Auto will break the backhaul at random. A mesh point can
  coexist with the AP interface on the same radio and channel, so no radio has to be
  sacrificed.
- **`uplink_detect = "fdb"` will find the gateway on the mesh interface**, not on lan1-4.
  That is the correct outcome: no ethernet socket gets falsely credited with the whole LAN.

---

## Investigation 2 — RF scan trigger  🟡 GATED

**Status:** the UniFi mobile app has an RF Environment "scan" action for an AP, and it
does **not** reach the wire for an openUF device. Same shape as Investigation 1: the
controller sends nothing, so the gate has to be found by static analysis or a REST probe,
not by capture.

### Evidence — 2026-09-06, live, UCG Ultra 10.6.101

`debug_dump_file` + `debug_dump_requests` armed on AP2 across ~10 minutes while the RF scan
was triggered from the app several times:

```
     60 "_type":"noop"
      1 "_type":"setparam"      # a full config push at 11:45:33Z -- not a command
```

No `_type:"cmd"` of any kind. The one `setparam` is an ordinary complete `system_cfg`
(the 5 GHz `ieee_mode` moved to `11naht160` in it) and carries, per radio,
`radio.<n>.rfscan=disabled` and `radio.<n>.bgscan.status=disabled` — static keys that
every push carries, not the trigger. openUF's own reply reported `spectrum_scanning:false`
and no `spectrum_table` throughout, as expected with no command received.

### What the device side already does

`inform.lua`'s `cmd:"spectrum-scan"` handler runs `iw dev <if> scan` per radio and builds
a per-channel `spectrum_table` from the survey dump; it has been exercised by invoking it
directly on real radios (PROTOCOL-VALIDATION.md, feature 8). Scanning on the live AP
interfaces works on this driver: 2.7 s on 5 GHz, 1.5 s on 2.4 GHz, measured 2026-09-06.
So once the command arrives, the remaining unknowns are (a) its exact name and arguments,
(b) whether the controller expects `spectrum_scanning` to go `true` for a while and then
`false` with a fresh `spectrum_scan_timestamp` (a real AP takes the radios off the air for
the scan), and (c) whether the `spectrum_table` field semantics (`width`, `interference`,
`utilization`) are what the RF Environment view expects.

### Experiment plan

**Step 0 — the REST probe (needs a controller admin login; do this first).** The scan
button ends up as the device-manager command `spectrum-scan`. Sending it directly tells
apart the two possible gates in one shot: if the capture shows a `cmd` arriving, the gate is
in the app's UI only; if the API answers `api.err.…`, the gate is in the controller and the
error names the reason.

```sh
# UniFi OS login -> cookie + CSRF token
curl -sk -c /tmp/uc.jar -D /tmp/uc.hdr -H 'Content-Type: application/json' \
  -d '{"username":"<admin>","password":"<password>"}' https://192.168.1.1/api/auth/login >/dev/null
TOKEN=$(sed -n 's/^x-csrf-token: *\([^\r]*\).*/\1/Ip' /tmp/uc.hdr)
# the command the scan button issues
curl -sk -b /tmp/uc.jar -H "x-csrf-token: $TOKEN" -H 'Content-Type: application/json' \
  -d '{"cmd":"spectrum-scan","mac":"ac:10:07:6f:c6:70"}' \
  https://192.168.1.1/proxy/network/api/s/default/cmd/devmgr
# then, on AP2:
grep -v ' TX ' /tmp/openuf-dump.txt | grep '"cmd"'
```

**Step 1 — the frontend gate, same login.** UniFi OS answers 401 for
`/proxy/network/manage/` without a session, so the Network app's chunks need the cookie
from step 0. Fetch them and grep for `spectrum`, `rfScan`, `rf_scan`, `RF Environment`;
the button's enable condition names the device field or capability bit.

**Step 2 — the bytecode.** `com.ubnt.data.uuvchZbWVhirD`'s `hasFirmwareCapability` /
`hasWifiCapability*` callers, looking for the one guarding the `spectrum-scan` devmgr
command (grep the jar for the string `spectrum-scan` first — Java keeps it in the constant
pool). The Docker baseline is 10.4.57 and the gateway is 10.6.101; a bit found there must
be confirmed by step 0 against the live controller before it is claimed.

**Step 3 — claim and capture.** `debug_caps` on AP2, trigger from the app, read the `cmd`
and the app's behaviour while the device reports `spectrum_scanning`.

### Do not re-attempt

- **Triggering from the app and waiting for a `cmd` with the shipped capability bits.**
  Measured: 60/60 `noop` plus one unrelated config push over ~10 minutes and several taps.
  Repeated 2026-09-15 on AP2 with the unhandled ledger in place: 30/30 `noop`, `interval` 10,
  no `cmd`, nothing in the ledger. The ledger now catches this without any capture armed, so
  a future attempt needs no preparation -- and no repeat is worth making until a capability
  bit is claimed (step 0 above).

---

## Investigation 3 — The STUN channel  🔴 BLOCKED (no wire evidence obtainable from the device)

**Status:** not implemented, and both testable hypotheses are refuted. Opened and closed to
the device-side experiment on 2026-09-15; what is left needs the controller's bytecode or a
shell on the gateway.

**The Apply click, 2026-09-15 13:45:44Z, live, UCG Ultra 10.6.101.** With
`tools/stun-probe.lua` bound to AP2's port 3478 sending a Binding Request every 10 s and
`tcpdump udp port 3478` on `br-lan`, the user changed a WiFi setting for AP2 and applied it.
The capture, 37 minutes in total: **202 datagrams, every one of them outbound** (180 from
port 3478, 22 from an ephemeral port), **zero from the controller** -- no Binding Response at
any time, and nothing at all around the Apply. The `setparam` itself arrived on the ordinary
cadence, as the answer to the inform openUF sent at 13:45:43Z. So: **H1 refuted** (the gateway
does not act as a STUN server for a bare RFC 5389 request from the LAN), **H2 refuted** (no
unsolicited poke to `<device>:3478` on Apply), and H3 -- fast UI updates come from something
other than STUN -- is what remains, with `live_update` and `capability=notif,notif-assoc-stat`
as the candidates (backlog rows 17 and 10).

**What would move it:** the controller's STUN server class -- grep the jar's constant pool
for `stun`, `3478` and `STUN` and read what it keys a binding on (a device-identifying
attribute would explain the silence to an anonymous request) -- or a shell on the UCG Ultra
(`ss -lunp | grep 3478`: is anything listening on the LAN address at all?). Neither is
available from the AP side, and the probe stays in the tree for the day one of them is.

**Earlier the same day, before the click:** `192.168.1.1:3478` answers a bare
RFC 5389 Binding Request with **nothing** -- 13 requests from AP2's port 3478 and 3 from an
ephemeral port, `tcpdump` on `br-lan` showing only the outbound packets, no reply, no ICMP.
So the gateway either does not run a standards-conformant STUN server on the LAN side, or
its server wants something in the request a bare Binding Request does not carry (a device
identifier attribute, say). **H1 as written is not confirmed and cannot be tested further
without knowing that.** H2 (an unsolicited poke to `<device>:3478` on Apply) is still open:
the probe and the capture are left running on AP2 and need the Apply click.

### What is known

- Every `mgmt_cfg` the controller sends carries `stun_url=stun://<controller>:3478/` (the
  L3 adoption blob in PROTOCOL-VALIDATION.md has it; AP2's ledger now counts it under
  `mgmt_cfg/stun_url` on every push). openUF has never opened that channel: `grep -ri stun
  openuf/` is empty.
- Ubiquiti's own port documentation: UDP 3478 is "used for STUN", and STUN is how the
  Network application "communicates with devices to speed up configuration changes" — an
  Apply reaches a real AP in about a second, while openUF learns of it on its next
  heartbeat, up to 10 s later. Devices that cannot reach the STUN port raise a "STUN
  communication failure" warning on their device page in the UI. **Whether the UCG Ultra
  shows that warning for an openUF device has never been looked at** — it is the cheapest
  observation in this section and needs no tools: open AP2's page, look for a STUN alert.
- The mechanism is not documented beyond that. Three hypotheses, and the experiment is
  built to tell them apart in one run:
  - **H1** — the device sends STUN Binding Requests to `<controller>:3478`; the controller
    records the source address and port, and on Apply sends a datagram *back to that
    binding* as the "inform now" trigger.
  - **H2** — the controller sends the trigger unsolicited to `<device-ip>:3478`, keyed on
    the `ip` the device reports in its informs, and the binding only matters behind NAT.
  - **H3** — nothing is ever sent to the device; STUN is only the controller learning
    whether the device is behind NAT, and the fast Apply on real hardware comes from
    something else (a `notif`-style channel — see the backlog).

### Experiment (one variable: is anything sent to the device on Apply, and where)

`tools/stun-probe.lua` runs on the AP with openUF's own luasocket. It binds **local port
3478** (so H1's reply-to-binding and H2's unsolicited poke both land on the same socket),
sends a standard RFC 5389 Binding Request to the controller every 10 s, and timestamps,
decodes and hex-dumps every datagram it receives — STUN or not.

```sh
# on AP2
apk add tcpdump-mini
nohup tcpdump -ni br-lan -w /tmp/stun.pcap udp port 3478 >/dev/null 2>&1 &
cd /opt/openuf && nohup lua /tmp/stun-probe.lua 192.168.1.1 > /tmp/stun-probe.log 2>&1 &
# in the controller UI: change something on AP2 only (its alias, or a radio's TX power) and Apply
# then
cat /tmp/stun-probe.log
```

Read-out:

| Seen | Meaning | Next |
|---|---|---|
| Binding Success Responses only, nothing after Apply | H3, or the trigger needs the binding to carry something a bare request does not (a device identifier) | Decompile: grep the jar's constant pool for `stun`, find the class that sends to devices and what it keys on |
| A datagram from the controller within ~2 s of Apply, to port 3478 | H1 or H2 (tcpdump's destination port and the probe's `from` line say which) | Implement: `_tick` waits in `socket.select` on the STUN socket instead of sleeping, an inbound datagram means "inform now", a Binding Request every N s keeps the binding alive |
| Nothing at all, not even a Binding Response | The gateway's STUN server is not on 3478, or is scoped | `nmap -sU -p 3478 192.168.1.1`; check the `stun_url` the ledger recorded |

### Implementation sketch, once the trigger is known

The inform loop already has one blocking point: the `socket.select(nil, nil, interval)`
sleep in `M.run`. Replacing it with a select on the STUN socket costs nothing when quiet and
wakes the loop the moment a trigger lands; `_tick` then runs immediately. The binding
keepalive is one `sendto` per cycle. Both belong inside the existing pcall boundaries, and
the STUN socket must never be a reason a heartbeat is missed: on any error the loop falls
back to the timed sleep and logs once.

### Do not

- Assume the trigger is a well-formed STUN message. The probe prints non-STUN datagrams in
  full for exactly that reason.
- Claim any capability bit for this. Nothing in the capability discussion mentions STUN;
  the channel is offered to every device via `mgmt_cfg`.

---

## Backlog — other unimplemented surfaces

Ordered by (value ÷ effort). Rows 8–11 were added on 2026-09-15 from the reference-material
review (session log); none started.

| # | Target | What is known | Next step |
|---|---|---|---|
| 8 | **Guest Hotspot / captive portal** | `guest_token` is in fxkr's real UAP capture; `selfrun_guest_mode=pass` is in every `mgmt_cfg` this lab receives (what a guest AP does when the controller is unreachable); `authorize-guest` / `unauthorize-guest` are the controller's known device-manager commands, with `mac`, `minutes`, `up`, `down`, `bytes`. Nothing in openUF handles any of it. On OpenWrt it is the inverse of `block-sta`: nft redirects unauthorised clients' HTTP on the guest VAP to the controller's portal and an allow set holds the authorised MACs. | Capture first: arm `debug_dump_file` on AP2, create a **new** test WLAN marked as a Guest network (do not convert a live SSID), Apply, and diff `system_cfg` for `guest.*` / `redirector.*` keys — and whether the guest option is gated on a capability the device must claim. The ledger will list the new key shapes on its own. |
| 9 | **DHCP option 43 controller discovery** | fxkr: the inform URL can be set by DHCP option 43 (vendor-specific), sub-option 1 = controller IP — Ubiquiti's documented zero-touch L3 method. openUF only ever falls back to `http://unifi:8080/inform`. On OpenWrt: `list reqopts 43` on the LAN interface (`netifd` passes it to `udhcpc -O`), and busybox exports an unknown requested option as `$opt43` (hex) to `/etc/udhcpc.user.d/*`. | A hook script in `/etc/udhcpc.user.d/openuf` that parses sub-option 1 and calls `syswrapper.sh set-inform http://<ip>:8080/inform` **only while unadopted**; `setup.sh` adds the `reqopts`. Small. |
| 10 | **Notifications (`capability=notif,notif-assoc-stat`)** | In every `mgmt_cfg`: the controller declares it accepts `notif` and `notif-assoc-stat` from the device. Presumably an out-of-band message a real AP sends on client association/disassociation instead of waiting for the heartbeat — which would also be the H3 explanation for fast UI updates in Investigation 3. Format unknown; never captured. | Decompile: grep the jar for `notif-assoc-stat`, find the `_type` values InformServlet accepts from a device besides `state`. Only then a capture. |
| 12 | ~~Controller-scheduled `11k-scan` (cron)~~ | **Implemented 2026-09-15** (`sysconf.lua`, `syswrapper.sh 11k-scan`); wire and device side in PROTOCOL-VALIDATION.md features 40. | Wait for one 04:00 firing on AP2 and check `logread` for `11k-scan requested`. |
| 13 | ~~NTP servers and timezone from the controller~~ | **Implemented 2026-09-15** (`sysconf.lua`); PROTOCOL-VALIDATION.md feature 41. Still open underneath it: why the jailed `sysntpd` on AP2 never synced in 30 minutes (the unjailed `ntpd -q` did at once). | Watch `logread \| grep ntpd` on AP2 after the restart `sysconf` issued; if still silent, compare the jail's resolver and socket access with an unjailed run. |
| 14 | **Device SSH Authentication (`users.*` / `sshd.*`)** | The push carries `users.1.name=<site's SSH username>`, `users.1.password=$1$…` (a 34-character MD5-crypt hash), `users.2.name=nobody` (`/bin/false`), `sshd.status=enabled`, `sshd.auth.passwd=enabled`, `sshd.1.ifname=br0`. This is Settings → System → **Device SSH Authentication**: the credentials an admin expects to SSH into every adopted device with. openUF ignores them -- AP2's root has no password at all. | Create/update the pushed user with the pushed hash (musl's crypt handles `$1$`), default shell, and make sure dropbear allows password auth for it; remove it when the block goes. This would also retire most of the reason for `--bootstrap-adopt`'s `ubnt` account after adoption. Security-relevant: design before code. |
| 15 | ~~`ebtables.*` hardening rules~~ | **Implemented 2026-09-15** (`l2guard.lua`, VAPs only); PROTOCOL-VALIDATION.md feature 42. | On-air check: from a wireless client, inject a VLAN-tagged frame or a BPDU and confirm it never reaches the wire. |
| 16 | **`blocked_sta` on setparam** | Every `setparam` carries a top-level **`blocked_sta`**, a *string*, `""` here with nothing blocked. PROTOCOL-VALIDATION ruled out `include_blocks` (always `[]`) as the persistent block list and concluded the device must remember `block-sta` itself; nobody looked at this field. If it is a MAC list, it is the controller's own copy of the block list -- and a block issued while an AP is rebooting is currently lost for good. | One UI click: block a client on AP2 with `debug_dump_file` armed and read `blocked_sta` on the next `setparam`. If it lists MACs, reconcile `state.blocked_stas` from it. |
| 17 | **`live_update` on noop** | Every `noop` carries **`live_update: false`** alongside `interval`. Unknown purpose; the name suggests the controller flips it while an admin has the device's page open, asking for faster or richer reporting -- which would be the H3 explanation for fast UI updates in Investigation 3. **Tried once, 2026-09-15:** the RF stats page kept open on AP2 for 30 s left `live_update` at `false` in every one of the 244 noops on file and produced no `cmd` -- but **`interval` moved**: two runs of noops at 16–19 s (14:20:05–14:20:58Z and 14:31:31–14:33:19Z, the second matching the page being open) against 10 everywhere else, and the inform gaps followed (17/18/19 s), since the field is honoured as of today. So the controller does vary the cadence with UI activity -- *upwards*, which reads as load-shedding on a busy UCG Ultra rather than as a live-view mode. `live_update` is still unexplained. | Pending experiment A above (the device panel and its Radios/Clients tabs). If still `false`, it is the capability route: grep the controller's frontend chunks for `live_update`. |
| 11 | **Discovery on multicast too** | jk-5 and fxkr both say a real AP sends the identical announce to `255.255.255.255` **and** `233.89.188.1`; openUF sends broadcast only, amd989/unifi-gateway multicast only (and is discovered fine). Matters only where broadcast does not reach the controller but multicast routing does. | One extra `sendto` in `announce.lua` with `ip-multicast-ttl` set. Trivial; low value. |
| 2 | **`wifi_caps` / `wifi_caps2` full bit map** | Only `wifi_caps2` bit `0x40` is understood. `fw_caps` `0x10`/`0x100` are understood. Everything else is unexplored. | Enumerate `hasWifiCapability*` call sites in `com.ubnt.data.uuvchZbWVhirD` and map each bit to the feature it gates. **This is the master key** — mesh, assisted roaming, band steering and quick scan all hang off it, so doing it once unblocks several features at a time. Highest leverage item in this file. |
| 3 | **Per-chain RSSI** | Identified in an earlier session, never wired. `iw` exposes per-chain signal. | Find the controller-side field name, then read from `iw dev <if> station dump`. |
| 4 | **Per-STA `noise`** | Same — available from `iw`/survey, not currently reported. | As above. |
| 5 | **Expected throughput / `linkscore`** | Both currently report `0`. `iw` gives `expected throughput` per station. | Confirm whether the controller consumes it before implementing. |
| 6 | **WiFiman** | Investigated and **closed**: it is a separate proprietary agent, not part of the inform protocol. Zero references in the repo, nothing on the wire. | Nothing. Do not re-investigate without new evidence. |
| 7 | **AirView / spectrum scan trigger** | Handler implemented and exercised against real radios. The web UI of 10.4.57 had no trigger; the **mobile app has one**, and against 10.6.101 it sends the device nothing — see Investigation 2. | Investigation 2, step 0: the REST `spectrum-scan` probe. |

---

## Session log

| Date | Subject | Outcome |
|---|---|---|
| 2026-09-01 | Mesh / wireless uplink | Blocked at the capability gate. Controller sends nothing (83/83 `noop`); RF and scan reporting ruled out; experiment plan written. Deprioritised by choice. |
| 2026-09-06 | Upstream review and selective adoption | jonasevcik/openUF had 20 commits since the fork point (677f732). Adopted, re-implemented in this tree's style with their hardware-verified tests: 802.11k neighbour enrichment (`rrmscan.lua`), per-port VLAN on DSA as a bridge move, Locate restoring and persisting the LED trigger, the `ft_psk_generate_local` removal, the Minimum RSSI fixed offset, the `[A-Za-z0-9_]` section-name rule (our hash suffix kept), the 2.4 GHz 40 MHz cap, the bare-`ht` best-PHY rule (done in `rf_config` so it composes with the floor and Force WiFi 4), the bridge-scoped uplink lookup, `kmod-nft-bridge` / `kmod-sched-act-police` / `kmod-leds-gpio`, the `os.execute` normalisation, and the AX3000T profile. Kept ours where ours was stronger: atomic state writes and generic field passthrough, `_tick` error boundaries, wire validation, caches, `--replace-conf`, the debug switches. Not a git merge. |
| 2026-09-06 | RF scan trigger | The app's RF Environment scan, triggered several times against AP2 on the now-10.6.101 gateway, produced no `cmd` at all (60/60 `noop`, one unrelated `setparam`). Gated like mesh. Investigation 2 written; REST probe is the next step and needs a controller login. Also confirmed live: the kernel's BSS cache forgets neighbours ~30 s after a scan, `iw scan` works on the live AP interfaces here, and iw 6.17 prints neither the `ms ago` nor the `BSS operating channel width` lines the parser relied on (both fixed). |
| 2026-09-06 | Upgrade path | `update.sh` (installed as `openuf-update`) and `tools/deploy.sh` added: backup → `install.sh install` keeping `conf.lua` → restart → wait for the new daemon's first completed inform through `/tmp/openuf-status` (new; `_tick` rewrites it every cycle) → roll back on failure; a `BUILD` stamp from `dist.sh` / `git describe` says what an AP runs. Both APs updated from this tree with it, no re-adoption; AP1 (now `.22`, root password set) received the day's work for the first time. AP1's custom SNAPSHOT feed has neither `kmod-nft-bridge` nor `kmod-sched-act-police`, so the Blocker `meta` rule and the upload shaper are inert there. The first deploy exposed two script bugs — a pipeline hiding `dist.sh`'s failure, and a stale tarball being shipped — both fixed and written into CLAUDE.md. AP1's log also holds `inform: cmd: mesh-halt` from 10:59 UTC, the first device-facing mesh verb seen from a controller here (Investigation 1). |
| 2026-09-06 | Pre-research hardening | Code review of openUF before resuming. Fixed ahead of the mesh work: non-AP `wifi-iface` sections are neither disabled by `use_only_unifi_wlan` nor reported as VAPs; each VAP reports its own BSSID; `debug_caps` / `debug_payload_extra` / `debug_dump_requests` / `neighbour_scan_interval` added to `conf.lua` so steps 2–3 need no code change. Independent bugs fixed in the same pass: `state.load` dropped every field but eight (the identity-MAC warning could never fire, the switch ledger was lost on restart), `state.save` was not atomic, the L2 announce never reflected adoption or the current IP, `phy_caps` re-cached the old regdomain before the reload, the inform loop had no error boundary, wire values reached `ip`/`nft`/`hostapd_cli` unvalidated, and `install.sh` overwrote `conf.lua` on reinstall. |
| 2026-09-13 | Upstream review and selective adoption, round two | jonasevcik/openUF had 61 commits since the last review (`d7d7e21..12b4db0`, 3–12 September). About twenty were fixes this fork had already made on 2026-09-06 (checked for equivalence, left alone). Adopted, re-implemented in this tree's style with their tests: the DSA learning-off rule for moved sockets and the tagged uplink, the `bridge openuf_learn` nft MAC tap and the per-socket bridge lookup that give a moved socket its hosts back, `mac_table[].vlan` + tap-harvested `ip` (the field the controller files a wired client's network by), `ensure_bridge_identity`, startup reapply of the static IP and of the blocker/speed-limit rulesets, the early state save in the IP branch, the RRM collector teardown and once-a-minute liveness check, the 4 MiB debug-dump cap, `conf.lua`'s `inform_url` as the first-boot default, the sysinfo lookup pass plus the uplink/phy/LLDP TTL caches and the per-pass radio rows, the inflate truncated-stream fix with the module's first tests, the `sysupgrade.conf` keep list in `install.sh`, `vlan.device` in every swconfig map, the dead-key and dead-export cleanup, the removal of the two non-UCI SAE writes (features 26/27 re-graded), the heartbeat cost probe, the lab's persistent UCI mock and scripted flow, and the documentation-range fixtures. Kept ours: `lan_bridge`, the `uplink_unknown` gate, `keep_wlan_sections`, `--replace-conf`, `update.sh`/`/tmp/openuf-status`; went further than upstream by dropping `coreutils-stat` (nothing reads `stat` any more). Not taken: their README screenshots. 729 tests pass. **Nothing new has been exercised on the JioRouter boards yet** -- the DSA learning/tap work in particular is upstream's AX3000T evidence and needs a live per-port VLAN assignment here to confirm. |
| 2026-09-15 | Reference-material review; unhandled ledger; `interval` | The three reference repos from README (amd989/unifi-gateway, jk-5, fxkr) were cloned beside this tree and read end to end. The two READMEs are behind PROTOCOL-VALIDATION.md on every point they cover; unifi-gateway is a UGW3 emulator, so most of its payload is N/A here. What came out of it, ranked: a STUN channel (`stun_url` is in every `mgmt_cfg`, openUF has no reference to it -- Investigation 3 below), a persistent ledger of unhandled surfaces (done today: `unhandled.lua`), Guest Hotspot (`guest_token` in fxkr's real capture, `selfrun_guest_mode=pass` in our own `mgmt_cfg`), DHCP option 43 discovery, honouring the `noop` `interval` (done today), multicast discovery alongside broadcast, a `User-Agent`, and fxkr's 2015 UAP payload as the historical wireless-uplink shape (`vap_table[].usage="uplink"`, `essid="vport-<serial>"`, top-level `uplink` string, `isolated`) -- added to Investigation 1's open questions. Not worth doing: snappy, speed-test, the gateway-only tables, jk-5's TLV `0x14`. Deployed to AP2 the same day (v0.8.0-17, no re-adoption) and a forced re-push filled the ledger with 79 rows in one cycle -- among them six surfaces nobody had noticed in a year of captures: the controller-scheduled nightly `syswrapper.sh 11k-scan` cron job, `ntpclient.*` servers and `system.timezone`, a pushed SSH user with an MD5-crypt hash (`users.*`/`sshd.*`), ten `ebtables` hardening rules, a top-level `mesh.status` block and a 32-hex `unifi.key` that is neither the authkey nor a PSK, `blocked_sta` on every `setparam`, and `live_update: false` on every `noop` (backlog rows 12–17). The STUN probe (`tools/stun-probe.lua`) went out with it: no reply from `192.168.1.1:3478` to a bare Binding Request (Investigation 3). AP2's clock turned out to be 8 days slow and was stepped by hand. Second batch the same day, on the user's go-ahead: backlog rows 12, 13 and 15 implemented as `sysconf.lua` (timezone, NTP, cron with the `11k-scan` verb) and `l2guard.lua` (the ebtables block as nft on the VAPs), deployed to AP2 and verified on a forced re-push -- crontab block written and crond up, `system.ntp.server` moved to the four `ubnt.pool.ntp.org` hosts with the OpenWrt pool stamped, `bridge openuf_l2guard` live on `phy0-ap0`/`phy0-ap1`/`phy1-ap0`, a hand-run `syswrapper.sh 11k-scan` consumed within one heartbeat and the next payload carrying 26 `scan_table` rows. The dropped-key report fell from 124 to 99 key shapes. Row 14 (the pushed SSH user) deferred for a design pass. 770 tests. The user's Apply on a WiFi setting then closed Investigation 3 (nothing on UDP 3478, see there) and a 30 s stay on the RF stats page left `live_update` at `false` while `interval` rose to 16–19 s and was followed (row 17; the first live proof that honouring it matters); the block/unblock and guest-WLAN clicks are pending as experiments B and C in "How to resume", with the dump left armed on AP2 for them. |
