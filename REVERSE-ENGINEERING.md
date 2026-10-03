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
| Controller | UniFi Cloud Gateway Ultra at `192.168.1.1` | Network **10.6.106** as of 2026-10-03 (discovery TLV 0x16 and the decompiled build; 10.6.101 on 2026-09-06, 10.4.57 on 2026-09-01). The exact build's `.deb` is downloadable from Ubiquiti's firmware catalog and decompiles with jadx (PROTOCOL-VALIDATION.md § Decompiling the controller), so bytecode findings can be made against the running version; the pinned Docker baseline is still 10.4.57. A UniFi OS API key exists for read/write REST and the frontend chunks (never recorded; ask) |
| AP1 "cave" | `192.168.1.22` (DHCP; was `.25` on 2026-09-01) | openUF on `jiorouter,ax6000-jidu6j01`, **wired, and the mesh parent** since AP2 went wireless. Since 2026-10-03 an **official** OpenWrt SNAPSHOT from the firmware selector (r36662) with the installed package `openuf-0.0.3-r1` + `luci-app-openuf`, running from `/usr/lib/openuf` (the init prefers it over a dormant `/opt/openuf`) and hot-patched to the current tree with `tools/hotpatch.sh` (which also ships `/etc/init.d/openuf` when it differs). UCI-managed; its `modelmap` says `jiorouter-ax6000-jidu6101`, which differs from the `jidu6j01` map only in comments. The `debug_caps` override from the mesh experiment was cleared 2026-10-03 (controller holds `wifi_caps 0x10083D`, `wifi_caps2 0xE2` for both APs). Root login is password-only (not recorded; `OPENUF_SSH_PASS` for deploy/hotpatch, or an `SSH_ASKPASS` helper). **The dev machine is on AP1's 5 GHz WiFi** — never change AP1 and AP2 at the same time, and prefer AP2 |
| AP2 "kitchen" | `192.168.1.147` (DHCP; was `.148` from 2026-09-28, `.149` on 2026-09-06, `.151` on 2026-09-01) | openUF on `jiorouter,ax6000-jidu6101`, `country_override = "PA"`. **A wireless child of AP1 since 2026-10-03** (powered on without the cable: the 4-address station on its 5 GHz radio joined AP1's hidden downlink; the controller draws it under AP1 and refuses Quick/Airtime scans for it while meshed, `api.err.InvalidTarget`, as for any meshed AP). Runs from `/opt/openuf` -- no package there, so `sh tools/deploy.sh 192.168.1.147` IS the live update. UCI-managed by the hand-installed LuCI app, `neighbour_scan_interval = 90` set there (back-to-back chunked sweeps; 0 or 300+ is saner), dump armed at `/tmp/openuf-dump.txt`. root has no password and dropbear accepts the blank login, so `ssh -o BatchMode=yes root@192.168.1.147` works with no helper. **The on-device test box** (2026-09-15): packages may be installed on it. Its clock drifts days behind with `sysntpd` running (backlog row 13); step it with an unjailed `ntpd -q` or `date -u -s` before trusting a timestamp; the box prints IST (UTC+5:30). `tcpdump-mini` is installed on it |

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

## Investigation 1 — Mesh / wireless uplink  ✅ WORKING (verified end to end 2026-10-03)

**Status (2026-10-03, night): mesh works, end to end, and the controller agrees.** With the
user running the two actions the agent could not (hot-patching AP1 and pulling AP2's cable):
AP2 lost its wire, `backhaul.lua` enabled its 4-address station 20 s later, it joined AP1's
hidden downlink (`phy1-sta0` → `7a:bb:c1:fe:3f:cb`, −10 dBm, HE160 4×4 at 4.8 Gbit/s both
ways, `4addr: on`), kept `192.168.1.147` over the bridge, resumed informing over the hop
(gateway at 1.5 ms), brought its own 5 GHz SSID back up on AP1's channel 100 (DFS was no
obstacle), and a VLAN-10 IoT client behind it kept its `192.168.10.x` address and a
satisfaction of 100. AP1 shows the per-station WDS netdev `phy1-ap1.sta1` in br-lan with
AP2 and its clients learned behind it. The controller's record for AP2 now reads
`uplink.type=wireless`, `uplink_mac`=AP1, `is_mesh_v3=true`, `uplink_table=[AP1]`, and the
`wireless-links` view pairs the two. **What made the controller agree was its own code**:
the matching Network package was downloaded from Ubiquiti, its jar decompiled, and the
inform processor read — the contract is in PROTOCOL-VALIDATION § Wireless uplink; three
plausible shapes had failed before that. Still open: multi-hop, and the downlink's child resolution on the parent (the
controller logs "Can't resolve wireless mac" for our station MACs; cosmetic, the child's
report carries the link).

### Evidence — 2026-10-03, live, UCG Ultra / Network 10.6.106, AP2 only

Tooling first, because it changed what was reachable: the user provisioned a UniFi OS
**API key**. Sent as `X-API-KEY`, it is accepted by the legacy API (`stat/device`,
`rest/device` PUT, `rest/setting`, `cmd/devmgr`) and by the Network app's static files, so
the controller's device records, the REST write path and the frontend bundles were all
readable with no browser session. The key is not recorded anywhere; ask for it.

**1. The gate is `wifi_caps` `0x1` (VWIRE), and it gates the *backend*, not the UI.**
The frontend's own constant table (`swai.*.js`) names the bits: `VWIRE:1, ZERO_HANDOFF:2,
BANDSTEER:4, BANDSTEER_PER_VAP:8, RF_SCAN:16, AIRTIME_CONFIG:32, BGA_FILTER:64, MESH:128,
MIN_RSSI_STRICT_MODE:256, MULTIPLE_ACL_LIST:1024, MESHV3:2048, UNIFI_WIFI_CAP_RADIUS_MAC_AUTH:4096,
HIDE_CH_WIDTH:65536, STA_ONLY:33554432, LOW_PERFORMANCE_MODE:67108864, RF_SCAN_6G:134217728`
(now in PROTOCOL-VALIDATION § Capability bitmasks). The mesh-connect checkbox saves
`mesh_sta_vap_enabled` with `PUT rest/device/<_id>`; the controller answers `rc: ok` either
way, but **persists the flag only when the device claims `0x1`** — otherwise the response
carries an empty `data` and the next read says `false`, which is exactly the "tick reverts"
symptom of 2026-09-01. Bisected on AP2 by claiming masks through `debug_caps` and writing
the flag through the REST API after each restart (a control write of `snmp_contact`
persisted every time):

| `wifi_caps` claimed | flag persists |
|---|---|
| `0x1000AC` = shipped + MESH `0x80` | no |
| `0x1008AC` = + MESH + MESHV3 `0x800` | no |
| `0x1000AD` = + VWIRE `0x1` + MESH | **yes** |
| `0x10002D` = + VWIRE only | **yes** |
| `0x1008AD` = + VWIRE + MESH + MESHV3 | **yes** |

**2. What each bit changes in the push** (eight `setparam`s diffed on AP2, then AP1's own):

- **VWIRE `0x1` alone** → `connectivity.status=enabled`, `connectivity.uplink_eth=eth0`,
  `connectivity.uplink_bridge=br0`; and, once the device's mesh flag is on, the **uplink
  station**: a second virtual interface on the 5 GHz radio, `radio.2.virtual.<k>.mode=managed`,
  `wireless.<n>.mode=managed usage=uplink wds=enabled vport=enabled hide_ssid=true`,
  `ssid=vport-<own MAC, no colons>` (fxkr's 2015 capture had the same `vport-<SERIAL>`
  naming), its `aaa.<n>.status=disabled`, plus `connectivity.uplink_wds=<that devname>`.
- **VWIRE `0x1` + MESHV3 `0x800`** → additionally the `mesh` block — `mesh.status=enabled`,
  `mesh.version=3`, `mesh.essid=vwire-<16 hex>` (the site's `connectivity.x_mesh_essid`,
  22 chars), `mesh.psk=<32 chars>` (`connectivity.x_mesh_psk`), and `mesh.serial1=<MAC>`
  only while a priority-1 parent is set — and the **downlink**: a third 5 GHz virtual
  interface `vwire3`, `mode=master`, `wireless.<n>.mode=master usage=downlink wds=enabled
  vwire=enabled hide_ssid=true`, `ssid=<mesh.essid>`, with a full `aaa.<n>` WPA2-PSK block
  carrying the same PSK — the hidden network children join. **The downlink and the `mesh`
  block come regardless of the device's own flag**: a wired, mesh-capable device is a
  parent by default (AP2 with the flag off: `+80` lines vs wired, exactly these). Every new
  devname is added to `bridge.1`, to the VLAN-10 bridge as `<dev>.10`, with `vlan.*` and
  `netconf.*` rows (raw dev `up=disabled`, `.10` `up=enabled`).
- **MESHV3 `0x800` without `0x1`** → nothing (identical to wired). **MESH `0x80`** → nothing,
  with or without the others.
- **The flag defaults to on.** The moment a device claims `0x1` the controller sets
  `mesh_sta_vap_enabled: true` on its record by itself — both APs read `true` after
  claiming, AP2 after an explicit `false` minutes earlier; the UI form's default
  (`mesh_sta_vap_enabled ?? true`) is the same rule. So a freshly capable AP gets *both*
  VAPs, as AP1 did.

So UniFi mesh is a **4-address WDS station joining a hidden WPA2-PSK AP**, not 802.11s —
the open question from 2026-09-01 is answered. The backhaul SSID and PSK are **site
settings pushed per device**, not derived: `rest/setting` key `connectivity` holds
`x_mesh_essid`/`x_mesh_psk` (and `element_adopt` holds the Element pair). `unifi.key`
turned out to be none of `x_vwirekey`, `x_mesh_psk` or `x_element_psk` — still unknown.

**3. The UI, from its code.** The device settings form (lazy chunks of the Network app)
submits `mesh_sta_vap_enabled` via the REST PUT and, when a priority changed, the device
command `set-priority-uplink` with `mac` and **`prefer1`** (`prefer2` optional) — the
controller's own error names the field (`api.err.InvalidTarget`, "no priority 1 input")
when it is missing; `unset-priority-uplink` clears it. `set-priority-uplink` persisted
`mesh_uplink_1` on AP2 and triggered a push even while the flag was still `false`. The
**uplink-priority dropdown is filled from the device's own `uplink_table`**: each entry
must name a site device by `mac`, and carries `radio`, `channel`, `signal` (or `rssi`),
optionally `mlo_mesh_supported`; entries for the same `mac` collapse into one option with
per-radio `radioLinks`. An empty `uplink_table` is an empty dropdown. The site-level
**Wireless Meshing** toggle is the `connectivity` setting (`enabled: true` here), checked
at adoption via `adopt-info/<mac>` → `requires_enabling_meshing`.

**4. What the controller does *not* take from the device, and what it already knows.**
`uplink_table` and `vwire_table` sent in the inform (tried bare, then with `ap_mac`,
`bssid`, `essid`, `type`, `up`) are **not** stored — the record kept `uplink_table: []`
with the flag on and off. The controller builds the list itself, and it has the raw
material: with `neighbour_scan_interval` on, AP2 reports **AP1 on both bands, tagged**
(`is_unifi=true`, `serialno=78:bb:c1:fe:3f:c9`; 5 GHz ch 100 at −10 dBm in 23 of 40
informs), and the controller's `stat/rogueap` (26 rows) lists **none** of AP1's BSSes —
the sibling element is recognised on this tree's hardware (PROTOCOL-VALIDATION feature 49
upgraded). Note for the next reader: a device's `scan_radio_table` never appears in its own
`stat/device` record, only in `stat/rogueap` after filtering; two hours were lost reading
the wrong place. With the child reporting a tagged parent and still an empty
`uplink_table`, the one variable left is the **parent**: AP1 claims no vwire bit and runs
no downlink VAP, and a parent candidate presumably has to be both.
**Then AP1 was made capable too (16:08 UTC):** both APs claim `0x10082D`, both have the
flag on, AP2 reports AP1 tagged on both bands — and both `uplink_table`s are still `[]`,
`wireless-links` is `[]`. So "scan ∩ capable" is not the rule either. The remaining
hypothesis is the obvious one: a candidate parent is a device whose **downlink VAP is on
the air** — the child's scan has to contain the hidden `vwire-<site>` BSS, matched to the
parent through the vendor element's serial or the parent's reported `vwire_vap_table`.
Neither AP beacons it (the guard skips the downlink), so there is nothing to list. That
test is the first implementation step, not a probe.

**5. State left on both APs and how to undo it.** AP2 (`/opt/openuf/conf.lua`):
`debug_caps = {wifi_caps = 0x10082D}`, `debug_payload_extra` with two synthetic tables,
UCI `neighbour_scan_interval=90`; backup `conf.lua.pre-mesh-20261003`. AP1 (the running
tree is the **package** at `/usr/lib/openuf`; `/opt/openuf` is a dormant tarball install):
`inform.lua` replaced by this tree's copy with the guard (original kept as
`inform.lua.pkg-0.0.3`; `apk fix openuf` or a reinstall also restores it), `conf.lua`
`debug_caps = {wifi_caps = 0x10082D}` (backup `conf.lua.pre-mesh-20261003`), UCI
`debug_dump_file=/tmp/openuf-dump.txt` + `debug_dump_requests=1`. The controller holds
`mesh_sta_vap_enabled: true` for both (its own default) and no priority uplink. Undo, per
AP, one at a time: `debug_caps = nil` (and on AP2 `debug_payload_extra = nil`), restart;
then `PUT rest/device/<_id> {"mesh_sta_vap_enabled": false}` for each. The guard kept
every push harmless: each AP still runs exactly its three SSIDs and hostapd's PIDs never
changed through any of it.

### What is still open, and the next steps

**Built on 2026-10-03** (design below, kept for the reasoning): `openuf/backhaul.lua` plans
the sections from the push, runs the wired-first uplink policy once per heartbeat
(`inform._backhaul_tick`), and reports a wireless `uplink` object while associated;
`ucihelper.backhaul_apply` writes `openuf_bh_dl_<radio>` (hidden `wds 1` AP, `psk2`,
`network lan`) and `openuf_bh_ul_<radio>` (`sta`, `wds 1`, `disabled` unless the policy says
wireless) after `wlan_clear` on every push; `get_vap_table` and `ap_ifnames` skip anything
with `openuf_backhaul`, so the downlink is neither a reported VAP nor an l2guard target;
`state.json` carries `backhaul_mode`, `backhaul_wired_port`, `backhaul_parent`. The policy
reads the remembered uplink socket's `operstate` (a pulled cable reads `lowerlayerdown`, an
admin-down port `down`; both are "no wire"), waits two heartbeats before enabling the
station, and disables it on the first heartbeat with the wire back — never both uplinks at
once. **Verified live on AP2 (parent half):** `iw dev` shows `phy1-ap1` with the mesh ESSID
on radio1, `/var/run/hostapd-phy1.conf` has `bss=phy1-ap1`, `ignore_broadcast_ssid=1`,
`wds_sta=1`; `bridge link` has it in br-lan; the inform's `vap_table` lists only the three
user SSIDs; mt76 on mt7986 took the WDS AP without complaint. **Not verified:** a station
joining it (needs a second device, i.e. AP1), the policy on a real cable pull, the `uplink`
report's reception by the controller, `uplink_table` filling.

**Done 2026-10-03 (user-run where the agent was refused):** AP1 hot-patched twice with
`tools/hotpatch.sh --repush` (the init prefers the package tree, so deploy.sh cannot reach
it); AP2's cable pulled at 12:56 UTC; association, DHCP continuity, informs, the VLAN client
and the controller's wireless uplink all observed, the last after reading the controller's
code (contract in PROTOCOL-VALIDATION). Remaining, in order of value:

1. ✅ (14:07 UTC) **AP2's cable back in:** `backhaul: wired uplink back on wan -- disabling
   the WDS station` on the first heartbeat, radio1 reloaded (ACS picked ch 36, both BSSes
   back), the inform's `uplink` string gone, the controller back to "wired via UCG port 2"
   with the gateway's LLDP listing AP2 again. The wired-first policy is verified both ways.
2. **AP1 on the final build** (`sh tools/hotpatch.sh --repush 192.168.1.22`): its downlink
   then reports the controller's devname and the kick guard applies to its children.
3. **Retire the `debug_caps` claims** on both APs once the final build runs there: the mesh
   bits are claimed by default on DSA boards now.
4. **Downlink child resolution:** the controller cannot map our station MACs to devices (it
   knows only Ubiquiti OUIs and `serialno`); harmless, but the parent's `downlink_table` stays
   empty. A child could advertise its identity MAC in its association request, or the parent
   could learn it from the sibling element — neither is built.
5. **Multi-hop and parent preference**: a child that is also a parent is untested; the
   station joins whichever downlink wpa_supplicant picks, `mesh.serial1` only names the
   parent for reporting.

3. **Adoption over a wireless uplink** is untested and separate: a factory-reset openUF
   device has no backhaul credentials. Probably out of scope for a first version.

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

### Experiment plan (in order, cheapest first) — ✅ done 2026-10-03, kept for the method

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

### Open questions (as written 2026-09-01; the 2026-10-03 evidence above answers most)

- ~~Which bit~~ **Answered:** `wifi_caps` `0x1` (VWIRE) gates the flag; `0x800` (MESHV3) gates the `mesh` block and the downlink VAP; `0x80` does nothing. The dropdown is gated by the device-reported `uplink_table`, not by a bit. Original text: Which bit — or which model-registry property — gates mesh-parent eligibility? `wifi_caps`
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

- **Claiming `wifi_caps` `0x80` for anything.** It changed nothing in three diffed pushes (2026-10-03).
- **Sending `uplink_table` or `vwire_table` in the inform expecting the controller to store them.** It does not, with any field set tried (2026-10-03).
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

## Investigation 2 — RF scan trigger  ✅ IMPLEMENTED (Quick Scan, Airtime Scan, Radio AI sweep — verified live 2026-10-03)

**Resolution (2026-10-03).** All three verbs are handled and the result reaches the
controller's Airtime view: `quick-scan` (`wifi_caps2` `0x80`, integer `scan-band`/
`scan-bw`), `spectrum-scan` (`wifi_caps` `0x10`) and the controller's own `scan_band`.
One forced sweep plus `iw survey dump` becomes `radio_table[].spectrum_table` rows at
every width the band offers, `spectrum_table_time` is an age, `quickscan_scanning: false`
on the next inform is the completion edge, and one `EVT_AP_QuickScanEvent` notification
inform dates the sweep. The whole contract, the two mistakes made on the way (table only
in `radio_table_stats`; noise dBm as "interference") and the live evidence are in
PROTOCOL-VALIDATION.md § RF scans. What follows is the history.


**Status:** the mobile app's RF-scan action **does** reach an openUF device now. AP1's
unhandled ledger holds it, recorded 2026-10-02 21:30Z (controller 10.6.106), twice:

```json
{"_type":"cmd","cmd":"scan_band","band":"na","device_id":"…","_id":"…","time":…,"datetime":"2026-10-02T21:31:25Z","server_time_in_utc":"…"}
```

One argument, `band` (`na` here; `ng` is the other). The Network app's constant table has
both device commands, `quick-scan` and `spectrum-scan`, and the device record carries
`quick_scan_state: {in_progress, last_band, last_width}` and `quickscan_scanning` — this is
the **Quick Scan**, whose gate is `wifi_caps2` `0x80` (`QUICK_SCAN`; `MONITOR_RF_SCAN` is
`0x2`) per the same table. openUF claims neither, and the verb arrived anyway, so either the
app does not check the bit or it checks something else; the 2026-09-06 run against 10.6.101
saw nothing, which may simply be the version. Device side there is nothing yet: the `cmd`
dispatcher logged it and the ledger kept the body. Next step is a handler — a sweep on the
named band (the `11k-scan` machinery already does this per radio) reported back in
`scan_radio_table`, and whatever `quick_scan_state` the controller expects (decompile or a
further capture; `last_width` suggests the band's channel width is reported too). The
original evidence and the REST-probe plan below stand as history.

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

## Investigation 4 — Bluetooth setup over a USB adapter  ⚪ PARKED (by choice)

**Status:** assessed 2026-10-03, nothing built. Not a pressing need, so parked; this section
exists so the next session starts at step 1 of the plan rather than at the research. Nothing
in this tree or in the three reference repos (amd989/unifi-gateway, jk-5, fxkr) mentions
Bluetooth at all — it is a new track, outside the inform protocol.

### What Bluetooth is for on a real UniFi AP

Public evidence, read 2026-10-03:

- Ubiquiti's help article *Bluetooth APs in UniFi Network* names exactly two uses: adopting
  and keeping connected **Protect All-in-One Sensors** (up to 7 UP-Senses per AP; the U6
  In-Wall is on the list), and **Device Setup** — "your UniFi Network mobile app can detect the
  Bluetooth signal of *unadopted* UniFi APs, allowing you to instantly set them up with the
  tap of a button".
- The U6-IW datasheet lists "Management interfaces: Ethernet and Bluetooth". A U6IW identity
  with a Bluetooth radio is therefore consistent with the real device.
- There is **no beacon / iBeacon feature** in UniFi Network. The Purple.ai article that claims
  one is generic boilerplate ("the option might be named differently"), and no `ble.*` or
  `bluetooth.*` key has ever appeared in a push here (the unhandled ledger is clean).

**What it would buy openUF:** the one thing that still needs a shell today. An openUF device
at a site with no local controller needs someone to SSH in and run `set-inform`; over
Bluetooth the installer taps the device in the app, the app hands it the inform target, the
device sends its first inform, and the **existing L3 adoption path** (authkey delivered in
the first `mgmt_cfg` while unadopted — PROTOCOL-VALIDATION) finishes the job. The controller
never learns how the inform URL got there, so nothing changes in its view after adoption.
Sensor bridging is **out of scope**: it needs a Protect console and the AP acting as a BLE
central relaying sensor data — same category as USG/USW emulation.

### What is already public

[zerotypic/unifi-ble-client](https://github.com/zerotypic/unifi-ble-client) reverse
engineered Ubiquiti's shared BLE library (`com.ubnt.ble.*`; the class names still say
AmpliFi) out of the UniFi **Protect** Android app v1.15.0 and drove a G3 Instant camera with
it. Its `doc/protocol.md` is the spec; the transport and crypto layers are fully described:

```
service UUID            per model (G3 Instant: 0c430d0c-00ef-4367-bc6f-ca7c51e6b61f; U6IW: unknown)
read  (notify)          d587c47f-ac6e-4388-a31c-e6cd380ba043        device -> host
write (with response)   9280f26c-a56f-43ea-b769-d5d732e1ac67        host -> device
discovery               BT name prefix per model + the service UUID in the advertisement

packet   2-byte length | crypto_secretbox_easy( 2-byte seq | 1-byte proto | data )
         nonce = seq (2 bytes) + 22 zero bytes; both sides start from a hard-coded DEFAULT_KEY
auth     proto 0, msgpack ["DHPK", false, 32-byte X25519 pubkey]  then  ["AUTH", "DH"]
         shared key = BLAKE2b-256( scalarmult || host_pub || device_pub )   (libsodium generichash)
api      proto 3, header part (JSON, zlib) + body part (JSON); HTTP-shaped {requestId, method, path}
         GET  /api/1.2/ap        wifi scan list (a camera thing)
         POST /api/1.2/manage    {"mgmt":{"hosts":[…],"protocol":"http","token":"…"},"wifi":{…}}
```

Caveats on that source: it is Protect-era (2020-ish), the per-model service UUID and name
prefix for any **AP** are not in it, the code mentions an alternative `"SRP"` auth type it
never saw used, and the MTU bug it works around is the camera firmware's, not something to
replicate.

### What it changes in openUF

- **Not a Lua module.** Lua on OpenWrt cannot open an `AF_BLUETOOTH` socket, and the crypto
  is libsodium's: XSalsa20-Poly1305, X25519, BLAKE2b with a 32-byte output. OpenSSL has no
  Salsa at all, and BLAKE2b-256 is a *different hash* from a truncated `blake2b512` (the
  output length is in the parameter block), which `lua-openssl` could not express anyway. So:
  a small C daemon, call it `openuf-bled`.
- **No BlueZ.** `bluez-daemon` in the feed depends on glib2, dbus, libical, readline and
  ncurses — the end of the 16 MB boards. Serve GATT without `bluetoothd`: the kernel mgmt
  socket (power, LE, connectable, add-advertising) plus an L2CAP socket bound to the ATT
  channel (CID 4), handling MTU exchange, Read-by-Group/Read-by-Type/Find-Information for
  discovery, Write Request and Handle Value Notification. bleno and PayPal's `gatt` did
  exactly this. Kernel side is only `kmod-bluetooth` + `kmod-btusb`.
- **Crypto with no OpenSSL involvement:** link the feed's `libsodium` (1.0.20), or vendor
  TweetNaCl plus the reference BLAKE2b — a few hundred lines, zero package dependencies.
  msgpack is needed for two fixed messages only (hand-roll it); JSON from libubox's blobmsg,
  which every device has; zlib is in base.
- **Handover costs nothing new.** On a valid `manage` the daemon runs the existing
  `syswrapper.sh set-inform <url>`; the inform loop is untouched. The daemon reads `adopted`
  from `state.json` and advertises **only while unadopted** — the mirror of the rule that the
  `mgmt_cfg` authkey is accepted only while unadopted.
- **Config and UI:** one main option (`ble_setup`), on automatically when
  `/sys/class/bluetooth/hci0` exists, plus a LuCI toggle and a status line. The modelmap stays
  untouched (a dongle is not board truth). The ufmodel probably stays untouched too — whether a
  real U6IW reports a Bluetooth field in its inform is unknown and is a 30-minute grep of the
  controller jar (PROTOCOL-VALIDATION → "Decompiling the controller").
- **Packaging stops being arch-independent.** Both packages are `PKGARCH:=all` today; a C
  daemon is the first per-target artefact. Keep it its own package (`openuf-ble`, depending on
  `kmod-bluetooth` and `kmod-btusb`) so the base stays `all`, and grow the release matrix to
  the targets shipped for.
- **Hardware fit:** USB exists on the JioRouter boards (`&ssusb` is `okay` in the common
  dtsi), the Archer C5 v1, A7/C7, WR1043ND v2 and WDR3500; **none on the AX3000T**. OpenWrt
  builds `btusb` with Realtek and MediaTek firmware loading **on** and Broadcom **off**, so:
  CSR 4.0 dongles (no firmware; beware the fake CSR clones with broken LE, the kernel has a
  quirk list) or RTL8761B with the `rtl8761b-firmware` package. Keep the dongle off a USB 3
  port next to the 2.4 GHz antennas.
- **Security model is the unadopted-device model, nothing better.** `DEFAULT_KEY` is public,
  so the Diffie-Hellman exchange is encrypted but **unauthenticated**: anyone in range with
  the app can point an unadopted device at their controller — exactly the trust level of
  `ubnt`/`ubnt` SSH on an unadopted real AP. Rules for the daemon: accept `manage` only while
  unadopted, serve no other endpoint, never put a PSK or an authkey on the air, go silent the
  moment the device is adopted.

### Plan (in order, cheapest first)

1. **Decompile the UniFi Network Android app** (`com.ubnt.easyunifi`) with jadx and confirm
   its Bluetooth client is the same library. Pull the AP entries: Bluetooth name prefix and
   service UUID for U6IW (and the other ufmodels), the AP-shaped `manage` payload, any
   device-info `GET` the app issues before offering adoption, and whether `"SRP"` is used for
   APs now. **This is the gate: nothing is built until it passes.**
2. **Build the daemon against AP2 with a dongle** — it has USB, 140 MB of flash, and the feed
   has an on-device `gcc`, so no SDK is needed for the dev loop. The real app is the oracle,
   the way the controller is for inform: is the device listed → does auth complete → does
   `manage` land and `set-inform` fire.
3. **Watch the handover end to end** on the UCG Ultra: first inform → authkey in `mgmt_cfg`
   → Connected. Then the factory-reset round trip (`reset-inform` must make it advertise
   again).
4. **Integrate and document:** init script (start only with an adapter and the option on),
   LuCI toggle, a README row, a USAGE section, and the evidence into PROTOCOL-VALIDATION under
   the confirmed-live rule.

### Open questions

- What `mgmt.token` means to a **Network** controller. In the camera flow it is a Protect
  NVR token the app fetched from the console; for an AP it may be nothing openUF needs, or the
  thing that lets the controller skip the "pending adoption" click. Step 1 answers it.
- How `hosts` + `protocol` become an inform URL (port 8080? `/inform` path implied?).
- Does a real AP keep advertising after adoption (with an "adopted" flag), or stop? The help
  article says *unadopted*; stopping is the safe default until a real one is observed.
- Does the app take the AP's identity MAC from the API or from the BD_ADDR? A dongle's address
  has nothing to do with `lan_cpueth`'s MAC.
- Does a real U6IW's inform carry a Bluetooth field the controller shows anywhere?

### Do not

- Reach for `bluez-daemon`/`bluetoothd`, even "just to prototype": its dependency set does
  not fit the reference boards and the raw-socket path is the proven one anyway.
- Try to do the crypto in Lua or through OpenSSL — see above, it is not a matter of effort.
- Buy Broadcom USB dongles for this; OpenWrt's `btusb` has their firmware patching off.
- Claim any capability bit for this. Nothing on the inform side is involved.
- Write a line of the daemon before step 1 has confirmed the Network app's protocol.

**Sources:** [Bluetooth APs in UniFi Network](https://help.ui.com/hc/en-us/articles/10000263945111-Bluetooth-APs-in-UniFi-Network) ·
[U6-IW datasheet](https://dl.ui.com/ds/u6-iw_ds) ·
[zerotypic/unifi-ble-client](https://github.com/zerotypic/unifi-ble-client) and its
[protocol.md](https://github.com/zerotypic/unifi-ble-client/blob/main/doc/protocol.md) ·
[Purple.ai "Configure BLE on Ubiquiti Networks APs"](https://support.purple.ai/hc/en-gb/articles/12802080728989-Configure-BLE-on-Ubiquiti-Networks-APs) (ruled out) ·
OpenWrt `package/kernel/linux/modules/bluetooth.mk`, `packages/utils/bluez/Makefile`,
`packages/libs/libsodium/Makefile` (local checkouts, read 2026-10-03).

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
| 15 | ~~`ebtables.*` hardening rules~~ | **Implemented 2026-09-15** (`l2guard.lua`, VAPs only); PROTOCOL-VALIDATION.md feature 42. Once-a-minute VAP resync and teardown on factory reset adopted from upstream 2026-09-28. | On-air check: from a wireless client, inject a VLAN-tagged frame or a BPDU and confirm it never reaches the wire. |
| 16 | **`blocked_sta` on setparam** | Every `setparam` carries a top-level **`blocked_sta`**, a *string*, `""` here with nothing blocked. PROTOCOL-VALIDATION ruled out `include_blocks` (always `[]`) as the persistent block list and concluded the device must remember `block-sta` itself; nobody looked at this field. If it is a MAC list, it is the controller's own copy of the block list -- and a block issued while an AP is rebooting is currently lost for good. | One UI click: block a client on AP2 with `debug_dump_file` armed and read `blocked_sta` on the next `setparam`. If it lists MACs, reconcile `state.blocked_stas` from it. |
| 17 | **`live_update` on noop** | Every `noop` carries **`live_update: false`** alongside `interval`. Unknown purpose; the name suggests the controller flips it while an admin has the device's page open, asking for faster or richer reporting -- which would be the H3 explanation for fast UI updates in Investigation 3. **Tried once, 2026-09-15:** the RF stats page kept open on AP2 for 30 s left `live_update` at `false` in every one of the 244 noops on file and produced no `cmd` -- but **`interval` moved**: two runs of noops at 16–19 s (14:20:05–14:20:58Z and 14:31:31–14:33:19Z, the second matching the page being open) against 10 everywhere else, and the inform gaps followed (17/18/19 s), since the field is honoured as of today. So the controller does vary the cadence with UI activity -- *upwards*, which reads as load-shedding on a busy UCG Ultra rather than as a live-view mode. `live_update` is still unexplained. | Pending experiment A above (the device panel and its Radios/Clients tabs). If still `false`, it is the capability route: grep the controller's frontend chunks for `live_update`. |
| 18 | **UHDIW identity (UAP-IW-HD) live validation** | `ufmodel/uhdiw.lua` presents the WiFi 5 in-wall: model code and `fw.ver` `6.7.57.15670` from Ubiquiti's firmware catalog (`fw-update.ubnt.com/api/firmware-latest`, platform `UHDIW`, release channel, 2026-09-21), selected by `modelmap/archer-a7-v5.lua`. Never adopted. Unknown: whether the model registry gives UHDIW the 5-port switch feature U6IW has (wired clients and the Ports view depend on `isSwitch()`), whether any WLAN option is gated per model, and that the version string matches the catalog (no "Update Available"). | Adopt a spare board under it -- **not AP1/AP2**, whose adoption records are keyed to U6IW (changing `model` on an adopted device is untested). Check: adopts and provisions; Ports view populated with five ports; no update banner; the WLAN mode menu stops at 802.11ac. Then drop the ⚠️ from the two files, README and USAGE. |
| 19 | **WLAN Schedule** | Not implemented. The controller emits `wireless.<n>.schedule_<day>` keys for a scheduled WLAN regardless of any bit (they land in the unhandled ledger); `fw_caps` `0x1000` and `0x400000` change the shape to `schedule_<day>.<i>` and add `schedule_invert` (upstream's decompile, 2026-09-27). | Capture a scheduled WLAN's keys on AP2, then a cron/`wifi` toggle per block; claim both bits only when built. |
| 20 | **Hardware check of the 2026-09-28 upstream adoptions** | Roaming Assistant, device-level Band Steering, Airtime Fairness, OWE, PPSK, the sibling-AP element, the reworked satisfaction score and `scan ap-force` all arrived from upstream with **their** evidence (AX3000T/Archer C5). None has run on the JioRouter boards. | On AP2 first: deploy, then (1) `cat /sys/kernel/debug/ieee80211/phy*/airtime_flags` and the controller's Airtime Fairness switch -- **read the controller's stored value before the first push**, upstream found `atf_enabled: false` waiting; (2) `uci get wireless.<section>.vendor_elements` and, once AP1 follows, whether each stops appearing as a rogue in Insights; (3) `ubus call usteer get_config` for `band_steering_interval` with the WLAN toggle off; (4) `logread \| grep roamassist` with a client walked between AP1 and AP2; (5) an OWE-transition and a PPSK test WLAN on AP2 only; (6) `iw dev phy0-ap0 scan ap-force` by hand, and the 11k-scan count in the log; (7) the Experience column against the previous build for the same clients. **AP2 done 2026-09-28** (build `d4c3460`, at `192.168.1.148` after a reboot): all 38 Lua files load under its Lua 5.1.5; every prerequisite present (ucode `nl80211`, `airtime_flags` on both phys, `hostapd -vowe` 0, `vlanid=` and `wpa_psk_file` strings); `iw dev phy1-ap0 scan ap-force` rc 0 on mt76; the wire claims `wifi_caps` 0x10002C, `wifi_caps2` 0x60, `radio_caps2` 0xB; the forced re-push (blank `cfgversion`, restart) put the sibling element in both hostapd configs, restarted usteer on `openuf_active` with the old threshold gone, rebuilt l2guard's three rules, 0 handler failures, nothing new in the ledger -- **and carried `atf.mode=disabled`, so AP2's airtime scheduler is now off until the device panel says On** (check 1 answered the hard way). Still owed: AP1 (its root password is not on file), the Environment tab once AP1 beacons too, a Roaming Assistant walk between the two, OWE/PPSK test WLANs, and the Experience score (no client was associated). |
| 11 | **Discovery on multicast too** | jk-5 and fxkr both say a real AP sends the identical announce to `255.255.255.255` **and** `233.89.188.1`; openUF sends broadcast only, amd989/unifi-gateway multicast only (and is discovered fine). Matters only where broadcast does not reach the controller but multicast routing does. | One extra `sendto` in `announce.lua` with `ip-multicast-ttl` set. Trivial; low value. |
| 2 | **`wifi_caps` / `wifi_caps2` full bit map** | **Mapped by upstream 2026-09-27** (full sweep of the controller's gates, PROTOCOL-VALIDATION.md § Capability bitmasks), and the feature bits are claimed here since 2026-09-28: `wifi_caps` `0x4`/`0x8`/`0x20`/`0x100000` (+`0x1`/`0x800` mesh and `0x10` RF scan since 2026-10-03), `wifi_caps2` `0x20`/`0x40` (+`0x2`/`0x80` since 2026-10-03), `radio_caps2` `0x1`/`0x2`/`0x8`. Still unclaimed on purpose: the mesh bits (this file's mesh experiment), WLAN Schedule (`fw_caps` `0x1000`/`0x400000`, row 19), and everything with no OpenWrt equivalent. | Enumerate `hasWifiCapability*` call sites in `com.ubnt.data.uuvchZbWVhirD` and map each bit to the feature it gates. **This is the master key** — mesh, assisted roaming, band steering and quick scan all hang off it, so doing it once unblocks several features at a time. Highest leverage item in this file. |
| 3 | **Per-chain RSSI** | Identified in an earlier session, never wired. `iw` exposes per-chain signal. | Find the controller-side field name, then read from `iw dev <if> station dump`. |
| 4 | **Per-STA `noise`** | Same — available from `iw`/survey, not currently reported. | As above. |
| 5 | **Expected throughput / `linkscore`** | Both currently report `0`. `iw` gives `expected throughput` per station. | Confirm whether the controller consumes it before implementing. |
| 6 | **WiFiman** | **Reopened and closed properly 2026-10-03.** The 09-06 verdict ("a separate proprietary agent") was wrong about the mechanism: WiFiman is console-side REST (`/v2/api/site/<site>/wifiman/<clientIp>`, `com.ubnt.service.wifiman.*`), keyed on the app's own IP, and it already answers fully for a client on an openUF AP. What the app could not show was the **AP itself** in its Discovery list: openUF never answered the UDP 10001 discovery probes a UCG Ultra answers. `announce.lua` now does (PROTOCOL-VALIDATION.md § Discovery requests and WiFiman). | Nothing on the inform side. If the app still shows a thin entry, compare its probe against the capture recipe in PROTOCOL-VALIDATION.md. |
| 7 | **AirView / spectrum scan trigger** | **Done 2026-10-03.** The web UI's Airtime Scan is gated by `wifi_caps` `0x10` (now claimed) and sends `spectrum-scan`; the view reads `stat/spectrum-scan`, which strips nothing, while `stat/device` strips the tables unless a scan is running — the reason earlier probes looked empty. See Investigation 2. | — |
| 21 | **Bluetooth setup via a USB adapter** | Parked by choice 2026-10-03, assessed in **Investigation 4**: app-driven setup of an *unadopted* device that hands over to the existing L3 adoption; protocol public from the Protect app (zerotypic/unifi-ble-client), AP specifics not; needs a small C daemon (libsodium crypto, raw mgmt + L2CAP ATT, no BlueZ) and a per-target package. Sensor bridging and beacons are out of scope. | Investigation 4, step 1: jadx the Network app for the U6IW service UUID, name prefix and `manage` shape. Nothing before that. |
| 22 | **Quick Scan and `cmd: scan_band`** | **Done 2026-10-03.** Two different things: `scan_band {band}` is the controller's own Radio AI neighbour sweep (it sets `scanning`, reads the next `scan_radio_table`); the app's Quick Scan is `quick-scan {scan-band, scan-bw}` behind `wifi_caps2` `0x80`, with `quick_scan_state` written by the controller and `quickscan_scanning` reported by the device. Both handled; verified live on AP2. See Investigation 2. | — |

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
| 2026-09-28 | Upstream review and selective adoption, round three | jonasevcik/openUF had 26 commits since the last review (`12b4db0..08d0003`, 25–27 September, tag v0.9.3). The first seven were upstream taking this fork's 2026-09-15 work (`sysconf`, `l2guard`, the `noop` interval, the bootstrap re-lock guard, credited in their headers) -- checked for equivalence and left alone. Adopted, re-implemented in this tree's style with their tests: the sibling-AP vendor element and its nl80211/`ucode` reader (`scan_table[].is_unifi`/`serialno`), `\xNN` SSID decoding, Roaming Assistant (`roamassist.lua`, `wifi_caps2` 0x60, `openuf_roam_assist`, `roam_assist_diff_db`), the usteer off-switch fix (`band_steering_interval`, not the inert threshold), device-level Band Steering (`wifi_caps` 0xC, `bandsteering.*`), Airtime Fairness (`airtime.lua`, `wifi_caps` 0x20, `atf_enabled` in state, reapplied at start), Enhanced Open incl. transition (`radio_caps2` 0x8, `owe_supported`, `get_ifnames_for_vap`), FT with WPA3 (`radio_caps2` 0x2), Private Pre-Shared Keys (`wifi_caps` 0x100000, `ppsk_add`, `wifi-station`/`wifi-vlan`, `bss_ifname`), the three-term WiFi Experience estimate (`hostapd_sta_caps`, `tx_duration`, SNR), `_forget_controller` on `setdefault` and `reset-inform`, the once-a-minute l2guard VAP resync, `_force_scan` (`ap-force` + exit status) for both scan paths, the uninstall cron cleanup, the lab stubs, and upstream's full capability-gate sweep into PROTOCOL-VALIDATION.md. Kept ours: `debug_caps`, `state.lua`'s design, the function names, this CLAUDE.md. 844 tests pass (777 before). Deployed to AP2 the same day (build `d4c3460`; AP2 had rebooted onto `192.168.1.148`, and its clock was 11 days slow again -- stepped from the dev machine, `ntpd -q` does nothing there): backlog row 20 records the checks, including the controller's stored `atf.mode=disabled` taking effect on the first push. AP1 waits for its root password. |
| 2026-09-21 | UAP-IW-HD identity; Archer A7 / C7 profile | `ufmodel/uhdiw.lua` added so a WiFi 5 board can present as a WiFi 5 in-wall with the same five sockets: model code and firmware from Ubiquiti's own catalog (`fw-update.ubnt.com/api/firmware-latest`, platform `UHDIW`, release v6.7.57+15670 published 2026-09-03), `buildtime`/`factoryver` marked cosmetic. `modelmap/archer-a7-v5.lua` written from the OpenWrt tree for the Archer A7 v5, C7 v4 and C7 v5 -- one `board.d` case arm for all three: tagged CPU port 0 on a single `eth0` trunk (the WDR3500 shape, `lan_cpueth = "eth0"`), WAN = physical 1 and LAN1..4 = 2..5 from both `02_network`'s labels and `01_leds`' port masks, `green:wps` as the LED no DTS alias drives, radio0 expected to be the 5 GHz ath10k (`phy0tpt`). Neither has touched hardware or a controller (backlog row 18; the identity is not to be tried on AP1/AP2). Tests: `tests/test_ufmodel.lua` loads every identity and pins UHDIW's shape, the A7 map's board truth is pinned in `test_modelmap.lua`, and the identity is driven through `build_json` and `announce.build_packet`. |
| 2026-10-03 | Bluetooth setup over a USB adapter (assessment only) | Asked how a real AP's Bluetooth would play in openUF. Found Ubiquiti's two uses (Protect sensor bridging, out of scope; app setup of unadopted APs, worthwhile), a public reverse-engineering of the BLE protocol from the Protect app, and that it cannot be done in Lua or with OpenSSL (libsodium crypto, `AF_BLUETOOTH`) — so a C daemon and the first non-`all` package. **Parked by choice**; Investigation 4 and backlog row 21 hold the plan, gated on decompiling the Network app first. |
| 2026-10-03 | Mesh / wireless uplink — status review | No experiment. Collected what moved since 09-01: the mesh bits are named by upstream's sweep (`wifi_caps` `0x1`/`0x80`/`0x800`/`0x4000`/`0x8000`), so step 2's go/no-go is runnable with `debug_caps = {wifi_caps = 0x1000AC}` on AP2; AP2's ledger holds the first `mesh-halt` **body** (bare envelope, 2026-09-29, the only unhandled `cmd` ever) ; `mesh.status`/`unifi.key` in all 6 full pushes. Written up as a status update in Investigation 1. AP2 is at `.147` again and its clock was four days slow after a reboot. |
| 2026-10-03 | Mesh / wireless uplink — gate found, wire captured | With the user's UniFi API key the controller's records, REST write path and frontend bundles were readable. **Gate:** `wifi_caps` `0x1` VWIRE makes `mesh_sta_vap_enabled` persist (bisected over five masks; `0x80` MESH does nothing, `0x800` MESHV3 adds the `mesh.*` block and the downlink VAP). The UI's dropdown is the device's own `uplink_table`; the UI saves via `PUT rest/device` + `cmd/devmgr set-priority-uplink {prefer1}`. **First mesh push captured on AP2:** a 4addr WDS station `vport-<mac>` (`usage=uplink`) and a hidden WPA2 AP `vwire-<site>` (`usage=downlink`), `mesh.essid/psk/serial1/version=3`, `connectivity.uplink_*`. Parser guard added so neither is beaconed (unit-tested; deployed to AP2, hot-patched into AP1's package tree). Then both APs made capable (`0x10082D`): the controller turns the mesh flag on by itself, sends both VAPs to both, hostapd untouched on either. `uplink_table` still empty with both capable and tagged — the parent list most likely needs a downlink actually beaconing, i.e. implementation step one. A full mesh test is not yet possible; plan in Investigation 1. Also found: AP1's ledger holds the app's RF-scan verb `scan_band` (Investigation 2). |
| 2026-10-03 | Mesh backhaul implemented | `backhaul.lua` + ucihelper/parser/state changes, 10 tests (872 pass). Deployed to AP2 and verified on the air: the push's downlink becomes a hidden `wds_sta=1` BSS on radio1 in br-lan, excluded from the VAP table and l2guard; the 4addr station is written disabled; the wired-first policy is unit-tested. Found and fixed an `and/or` false-to-nil bug in the policy before it reached a device. The two hardware proofs left (a parent on AP1, AP2's cable out) were refused to the agent by the permission classifier and are written up as the user's next two steps. Also: busybox on these boards has no `nohup`; `start-stop-daemon -S -b` is the way to detach. |
| 2026-10-03 | Mesh — working end to end | User hot-patched AP1 (`tools/hotpatch.sh --repush`) and pulled AP2's cable: station up in 20 s, joined AP1's downlink at −10 dBm, address kept, informs over the hop, VLAN-10 client intact, AP2's 5 GHz back on ch 100. Controller still said "wired via port 2" until the matching Network 10.6.106 package was fetched from Ubiquiti and its inform processor decompiled (jadx, case-sensitive volume): `uplink` is a **string** naming the uplink VAP, the link is that VAP's one station (the parent's downlink BSS) resolved by **`serialno`**, the tables are controller-computed. Reporting rewritten to that contract: controller shows `uplink.type=wireless`, parent AP1, `uplink_table=[AP1]`, `wireless-links` paired. Mesh bits now claimed by default on DSA boards. |
| 2026-10-03 | Mesh — wire back | Cable re-plugged at 14:07 UTC: the station was disabled on the first heartbeat, radio1 reloaded, AP2 informed wired again and the controller returned to the LLDP-derived port-2 uplink. Both directions of the uplink policy are now seen on hardware. AP1 hot-patched to the final build by the user; both APs claim `0x10082D`, AP2 with no override. |
| 2026-10-03 | Mesh — the parent names its children | The controller could not resolve AP2's 4-address station behind AP1's downlink (no Ubiquiti OUI, no beacon to match): "Can't resolve wireless mac", empty `downlink_table`. Chosen fix: the parent sets the station's `serialno` from the bridge FDB behind that station's WDS netdev ∩ the sibling-AP set from its own scans (`backhaul.child_serialno`), refusing when two siblings share a netdev. On both trees; runs on whichever AP is the parent. | PROTOCOL-VALIDATION.md § The parent names its children |
| 2026-10-03 | RF scan — contract decompiled and implemented | Quick Scan (`wifi_caps2` `0x80`, `quick-scan {scan-band int, scan-bw int}`), Airtime Scan (`wifi_caps` `0x10`, `spectrum-scan`) and Radio AI's `scan_band` all land in one sweep handler. Rows per 20 MHz channel per width, percentages, age not epoch, `quickscan_scanning` edge, and the `EVT_AP_QuickScanEvent` notification inform (`inform_as_notif`/`notif_reason: event`). Live on AP2: cmd received, state flipped, timestamp stamped, rows in `stat/spectrum-scan`. Two wrong turns fixed the same day: table only in `radio_table_stats` (the processor walks `radio_table`), and `stat/device` as the read path (it strips the tables). | PROTOCOL-VALIDATION.md § RF scans |
| 2026-10-03 | WiFiman + discovery requests | WiFiman decompiled: console-side REST keyed on the app's IP; answers fully for a client on openUF's AP (queried with the API key). The AP-side gap: openUF never answered UDP 10001 discovery probes (`01 00 00 00`, `02 08 00 00`), which is what WiFiman's Discovery lists; a UCG Ultra answers both. `announce.lua` now listens and replies (v1 → version 1/cmd 0, v2 → version 2/cmd 9); AP2 answered four probes after the deploy. | PROTOCOL-VALIDATION.md § Discovery requests and WiFiman |
| 2026-10-03 | Mesh — cold boot onto the air | User powered AP2 off and on without the cable: joined AP1, informed over the hop, AP1 named the child, yet the controller drew AP2 wired on gateway port 2. The uplink station carried no `serialno`: `parent_for_bssid()` read `is_unifi`/`serialno` off raw scan entries that only carry `peer_mac`; the earlier pass had leaned on the push's `mesh.serial1`, which a cold boot with a matching cfgversion never gets. Fixed (raw element read, joined BSS first, push's parent as fallback); controller flipped to wireless/AP1 on the next heartbeat. | PROTOCOL-VALIDATION.md § The parent names its children |
| 2026-10-03 | RF scan — the sweep itself was the outage | A Quick Scan from Channel AI kicked every client off for a minute. The handler swept the whole band in one `iw scan ap-force`: on an AP radio mac80211 stops beaconing for the whole off-channel run (~3 s), clients gave the AP up, and Radio AI had asked both APs, both bands, at once. Measured ~600 ms/channel wall time with a station on the radio, none of it dropping the uplink; no dwell control on mt76. Every sweep is now a per-heartbeat job of four-channel chunks (≤ ~0.45 s silent), rows and one event per chunk, flags held until the last chunk — including the controller's nightly 11k-scan. | PROTOCOL-VALIDATION.md § RF scans |
