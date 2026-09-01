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
| Controller | UniFi Cloud Gateway Ultra | Network **10.4.57** — same version as the pinned Docker baseline, so captures are comparable |
| AP1 | `192.168.1.25` | openUF on `jiorouter,ax6000-*`, wired |
| AP2 | `192.168.1.151` | openUF on `jiorouter,ax6000-jidu6101`, wired, `country_override = "PA"` |

Both APs present as `u6iw`. SSH credentials are deliberately **not** recorded here — this
file is committed. Keep them in your own notes or a gitignored file.

Site WiFi as of 2026-09-01: `The SCP Foundation` (both bands) and `SCP IOT` (2.4 GHz,
tagged VLAN 10 via `br-openuf10`).

### Capturing what the controller sends

The one tool that matters. In `conf.lua` on the device:

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

⚠️ The file contains PSKs and the `authkey`. It is on tmpfs (gone on reboot); set the
option back to `nil` and delete the file when done.

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

**Step 2 — the go/no-go.** Claim the candidate bit on **both** APs, restart, and look at
the dropdown. If AP1 appears as a selectable parent, the gate is understood and everything
downstream is ordinary work. If it stays empty, the gate is elsewhere — likely the model
registry or a field we have not found. This is a one-line change and a 30-second test;
do it before writing any implementation.

**Step 3 — only now is the wire useful.** With the bit claimed, arm `debug_dump_file` on
both APs, select the parent, Apply, and capture. That push is the backhaul specification:
SSID, PSK/derivation, and whichever `radio.<n>`/`wireless.<n>` keys carry it.

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
  is a much larger job than reading a pushed field.)
- What is the exact shape of `uplink` for a wireless-uplinked AP? Candidate fields from a
  real capture: `type`, `ap_mac`, `essid`, `bssid`, `rssi`, `channel`, `uplink_source`.
  Compare with the wired shape already recorded in PROTOCOL-VALIDATION (`uplink_remote_port`,
  `uplink_source:"lldp_downlink"`).
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

- **`use_only_unifi_wlan = true` (currently set on AP2) would disable it.** That option
  disables every `wifi-iface` not named `openuf_*`. Set it `false`. Naming the section
  `openuf_backhaul` is worse, not better — `wlan_prune` *deletes* `openuf_*` sections.
- **The channel must be fixed in the controller, on both APs.** A mesh/WDS station has to
  sit on the parent's channel, and openUF rewrites `radio.<n>.channel` from every push.
  Both radios are currently `channel='auto'`, which is exactly why they drifted apart to
  ch 100 (AP1) and ch 36 (AP2). Auto will break the backhaul at random. A mesh point can
  coexist with the AP interface on the same radio and channel, so no radio has to be
  sacrificed.
- **`uplink_detect = "fdb"` will find the gateway on the mesh interface**, not on lan1-4.
  That is the correct outcome: no ethernet socket gets falsely credited with the whole LAN.

---

## Backlog — other unimplemented surfaces

Ordered by (value ÷ effort). None started.

| # | Target | What is known | Next step |
|---|---|---|---|
| 2 | **`wifi_caps` / `wifi_caps2` full bit map** | Only `wifi_caps2` bit `0x40` is understood. `fw_caps` `0x10`/`0x100` are understood. Everything else is unexplored. | Enumerate `hasWifiCapability*` call sites in `com.ubnt.data.uuvchZbWVhirD` and map each bit to the feature it gates. **This is the master key** — mesh, assisted roaming, band steering and quick scan all hang off it, so doing it once unblocks several features at a time. Highest leverage item in this file. |
| 3 | **Per-chain RSSI** | Identified in an earlier session, never wired. `iw` exposes per-chain signal. | Find the controller-side field name, then read from `iw dev <if> station dump`. |
| 4 | **Per-STA `noise`** | Same — available from `iw`/survey, not currently reported. | As above. |
| 5 | **Expected throughput / `linkscore`** | Both currently report `0`. `iw` gives `expected throughput` per station. | Confirm whether the controller consumes it before implementing. |
| 6 | **WiFiman** | Investigated and **closed**: it is a separate proprietary agent, not part of the inform protocol. Zero references in the repo, nothing on the wire. | Nothing. Do not re-investigate without new evidence. |
| 7 | **AirView / spectrum scan trigger** | Handler implemented and exercised against real radios; **no UI affordance exists in 10.4.57** to fire it. AirView is fed passively. | Nothing until a controller version exposes a trigger. |

---

## Session log

| Date | Subject | Outcome |
|---|---|---|
| 2026-09-01 | Mesh / wireless uplink | Blocked at the capability gate. Controller sends nothing (83/83 `noop`); RF and scan reporting ruled out; experiment plan written. Deprioritised by choice. |
