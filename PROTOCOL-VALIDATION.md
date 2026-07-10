# Protocol validation findings

openUF's assumptions about controller-pushed inform payloads (`vap_table`,
`network_table`, `radio_table`, the `cmd`/`setparam`/`upgrade`/`setdefault` response
shapes) were originally inferred from third-party reference material —
[amd989/unifi-gateway](https://github.com/amd989/unifi-gateway) and
[paultyng/go-unifi](https://github.com/paultyng/go-unifi) — never checked against a
real UniFi Network Application. This document is the project's own ground truth,
captured by running openUF against a real self-hosted controller and dumping raw
decrypted inform responses via the `debug_dump_file` opt-in flag (see
[USAGE.md](USAGE.md#3-configuration)).

Where this document and the third-party references disagree, this document wins.

**Environment used:** `linuxserver/unifi-network-application:10.4.57` (Docker,
pinned — see rationale below), with openUF running as the AP inside a disposable
Alpine Linux container on the same Docker network (see `tools/validation/`).

**Status:** in progress — Stage 1 of the controller→AP validation plan. General
findings below are confirmed; the per-scenario matrix is blocked on completing
adoption (see "L3 adoption never completes" below) — everything past the initial
handshake requires an adopted device to receive config pushes at all.

---

## General protocol findings (apply across the whole matrix)

### Critical bug found and fixed: `inform.lua` never actually ran outside tests

Not a wire-protocol finding, but the most important thing this exercise surfaced.
`inform.lua`'s `M.run()` reuses `announce.lua`'s `get_mac`/`get_ip` via
`_require_sibling`, which `dofile()`s `announce.lua` fresh every call. `dofile`
(unlike `require`) never caches, so this re-runs `announce.lua`'s own
self-executing "script entry point" block at the bottom of that file too — guarded
only by `if not OPENUF_TEST_MODE`. Every unit test and `tools/simulate.sh` run sets
that flag globally before loading `inform.lua`, which masked this completely: in
any **real** (non-test) run, that block fires and either nests `announce.lua`'s own
*infinite* L2 broadcast loop inside `inform.lua`'s `M.run` (silently preventing the
real inform loop from ever starting), or — as happened immediately when actually
running `lua inform.lua` for real inside the validation container — calls
`os.exit(1)` when the broadcast send fails (this Docker bridge network doesn't
support UDP broadcast), killing the whole inform process outright. **This means
`inform.lua` had effectively never been run for real prior to this session** — only
ever under `OPENUF_TEST_MODE`. Fixed in commit `3955477`: extracted the MAC/IP
population into `M._populate_net_info` and suppressed `OPENUF_TEST_MODE` for just
that one reuse-only `dofile`.

### A 404 with an empty body does not mean the inform was rejected

A structurally well-formed, correctly-encrypted first-contact inform (magic,
pkt_version, MAC, flags, IV, data_version, payload_len all correct, verified via
manual hexdump) gets **HTTP 404 with `Content-Length: 0`** back from the real
controller — with **zero** corresponding entry in the server's own `inform` logger,
unlike every malformed test packet tried (which get 400 with a specific,
logged reason: "Bad packet magic", "Data version 0 is not supported", "Content too
short"). Despite the 404, the device is correctly created server-side and shows up
in the UI as "1 device is ready to adopt." **openUF's `http_post` currently treats
any non-200 status as a hard failure and never inspects the body** — in the cases
observed here the body was genuinely empty so nothing was lost, but this means the
client has no way to distinguish "processed, no update right now" from "rejected,"
and always backs off/retries identically either way.

Ruled out during investigation (documented so it isn't re-tried): this is **not**
about compression (tested with a real zlib-compressed, correctly-flagged payload —
same 404), **not** about GCM vs CBC (tested both — same 404, and this environment's
`crypto.gcm_available()` is false anyway since there's no `lua-openssl` package, so
GCM requests silently downgrade to CBC), and initially suspected to be an
internal-microservice dependency in newer controller builds (an unrelated
`127.0.0.1:9080/api/ucore/manifest` connection-refused error appears in the logs of
both `latest` and the pinned `10.4.57` image — a background licensing/manifest
fetch, present regardless of version, not the cause).

### L3 adoption never completes in this environment — contradicts current USAGE.md

`USAGE.md` §4 currently states, for L3 adoption: *"Click Adopt — the controller
SSHes in and completes the handshake."* **This is confirmed wrong**, at least for
this controller version/deployment: clicking Adopt on an L3-discovered device
produces this exact log line, immediately and every time (reproduced on two
independent clean runs):

```
INFO  adopt  -    device[<mac>] discovered via L3 inform, skip SSH adoption
```

No SSH connection is ever attempted — confirmed both by this log line and by zero
entries in the AP container's sshd for the entire session. Immediately after this,
every subsequent inform from that device fails to decrypt:

```
WARN  inform - dev[<mac>] inform decryption failed with defaultAuthKey=false, ... invalid JSON
ERROR inform - dev[<mac>] invalid inform_ip controller
ERROR inform - Inform Invalid for Device[...], Invalid
```

`defaultAuthKey=false` means the server has already committed to expecting a
*non-default* key for this device — but there was no successful round-trip in
between (every response was non-200 and thus never reached `handle_response`/the
`debug_dump_file` dump) in which a new key could plausibly have been delivered via
`mgmt_cfg` either. The device is permanently stuck in "Adopting" from this point.
Reproduced identically on a fully clean run (fresh mongo + fresh AP container),
ruling out leftover state from earlier attempts.

**Working hypothesis:** real L3 adoption may deliver the new key via `mgmt_cfg` in
a `setparam` response on the *very first* default-key-encrypted inform after the
Adopt click — a response openUF's own code is built to explicitly ignore:
`inform.lua`'s `setparam` handler (~line 415) never applies `mgmt_cfg.authkey`,
documented as intentional "security hardening" (only SSH `set-adopt` may set a new
key). **If that hypothesis is right, this policy is specifically incompatible with
L3 adoption against real controllers, since real controllers skip SSH entirely for
L3-discovered devices.** This needs either (a) a packet capture from genuine
hardware doing real L3 adoption to confirm the mechanism, or (b) a deliberate
product decision on whether to accept `mgmt_cfg.authkey` for L3-discovered/not-yet-
adopted devices specifically (a real security tradeoff — flagged for the user, not
changed unilaterally here).

L2 discovery (which *would* use real SSH `set-adopt`, avoiding this whole issue) was
attempted as a fallback but `announce.lua`'s UDP broadcast fails on this Docker
bridge network (`calling 'send' on bad self` — broadcast likely unsupported/blocked
at the network level here); this is a environment limitation, not an openUF bug.
**Completing the rest of the validation matrix requires either a network where L2
broadcast actually works (e.g. macvlan instead of bridge, or real hardware), or
resolving the L3 authkey-delivery question above.**

---

## 1. Initial adopt handshake

- **Status:** 🟡 partially captured, blocked — see "L3 adoption never completes" above
- **Compare against:** `mgmt_cfg` key=value string format, `set-adopt` invocation
  shape (`openuf/hook/syswrapper.lua`)
- **Findings:** for L3-discovered devices, no SSH `set-adopt` is ever attempted
  (contradicts current `USAGE.md`). The `mgmt_cfg` key=value format itself is still
  unverified — no `setparam` response was ever successfully captured.
- **Code changes:** none yet — pending resolution of the authkey-delivery question.

## 2. Baseline post-adopt inform response

- **Status:** 🛑 blocked — requires adopted state, see "L3 adoption never completes" above
- **Compare against:** top-level `_type` field name/values (`noop`/`config`/`cmd`)
  (`openuf/inform.lua:388-490`)
- **Findings:**
- **Code changes:**

## 3. Default SSID push (no VLAN)

- **Status:** 🛑 blocked — requires adopted state, see "L3 adoption never completes" above
- **Compare against:** `vap_table` field names (`openuf/ucihelper.lua` `apply_config()`)
- **Findings:**
- **Code changes:**

## 4. VLAN-tagged network + SSID assignment

- **Status:** 🛑 blocked — requires adopted state, see "L3 adoption never completes" above
- **Compare against:** `network_table`/`networkconf_id` join shape
  (`openuf/ucihelper.lua`)
- **Findings:**
- **Code changes:**

## 5. Fast Roaming / WPA3 fast roaming toggle

- **Status:** 🛑 blocked — requires adopted state, see "L3 adoption never completes" above
- **Compare against:** presence/absence and real field name of
  `mobility_domain`/`r0kh`/`r1kh`/`fast_roaming_enabled`
  (`openuf/ucihelper.lua` `derive_mobility_domain` stopgap)
- **Findings:**
- **Code changes:**

## 6. TX power (Low/Medium/High/Custom) per radio

- **Status:** 🛑 blocked — requires adopted state, see "L3 adoption never completes" above
- **Compare against:** `radio_table` field name/value shape
  (`openuf/ucihelper.lua` `rf_config()`)
- **Findings:**
- **Code changes:**

## 7. Locate trigger

- **Status:** 🛑 blocked — requires adopted state, see "L3 adoption never completes" above
- **Compare against:** exact `cmd` string(s) (`openuf/inform.lua:455-460`)
- **Findings:**
- **Code changes:**

## 8. RF/spectrum scan trigger (trigger only)

- **Status:** 🛑 blocked — requires adopted state, see "L3 adoption never completes" above
- **Compare against:** exact `cmd` string for the scan trigger
  (`openuf/inform.lua:461-478`)
- **Note:** result-reporting (AP→controller direction) is out of scope for this
  stage — see Stage 2.
- **Findings:**
- **Code changes:**

## 9. Firmware upgrade offer

- **Status:** 🛑 blocked — requires adopted state, see "L3 adoption never completes" above
- **Compare against:** `_type:"upgrade"` shape, `version`/`url` field names
  (`openuf/inform.lua:438-448`)
- **Findings:**
- **Code changes:**

## 10. Forget device / factory reset

- **Status:** 🛑 blocked — requires adopted state, see "L3 adoption never completes" above
- **Compare against:** `_type:"setdefault"` shape (`openuf/inform.lua:423-430`)
- **Findings:**
- **Code changes:**

## 11. fw.ver acceptance (passive)

- **Status:** 🛑 blocked — requires adopted state, see "L3 adoption never completes" above
- **Compare against:** does the current `openuf/ufmodel/u6iw.lua` `fw.ver` get
  accepted by the real controller, or rejected?
- **Findings:**
- **Code changes:**

---

## Stage 2 (future, not started)

Static extraction of a real AP firmware image (`binwalk` + `strings`/Ghidra) to
determine the AP→controller spectrum-scan-result reporting shape — the one item
Stage 1's controller-only setup can't resolve, since it requires observing what a
genuine AP sends up, not what the controller pushes down.
