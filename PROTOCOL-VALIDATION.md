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

### Cross-check against fxkr/unifi-protocol-reverse-engineering's "Inform" docs

Header layout, flags (0x01 encrypted, 0x02 compressed), zlib-before-encrypt
ordering, AES-128-CBC+PKCS#7, and the default `http://unifi:8080/inform` URL all
match openUF's implementation exactly — no divergence there (fxkr's doc predates
GCM/Snappy, which `amd989`'s docs cover instead; not a conflict, just an older/
simpler snapshot of the protocol).

One real divergence found: fxkr's doc states *"Upon receiving a command message, an
AP will execute a command and then send another inform immediately."* openUF's
`_type == "cmd"` dispatch (`inform.lua`, the `cmd` branch) unconditionally
`return false`d regardless of which command ran (`set-locate`, `spectrum-scan`, or
an unhandled command) — meaning it never re-informed immediately after executing a
command, unlike the `cfgversion` branch just below it, which already did this
correctly. Fixed: the `cmd` branch now always `return true`s, matching the
documented behavior and matching how the `cfgversion` branch already worked. Not
verified against a live controller in this session (no adopted device to receive
`cmd` responses against, given the L3 deadlock above) — a genuine protocol-shape
fix based on independent published documentation, same standard as the `mgmt_cfg`
work.

**Methodology note on how this whole investigation's findings were verified**:
every earlier "raw response" observation in this document came from decrypting
*inside* the client process itself (openUF, or a one-shot script, or `amd989`'s own
code) — valid since we always control the client and already have the key, but it
only shows what that client's own logging chose to surface. Cross-checked this
independently with a minimal raw TCP relay (same purpose as fxkr's own
mitmproxy-based capture technique — observe bytes on the wire, independent of any
client-side code — just a plain byte-logging relay rather than an HTTP/TNBU-aware
mitmproxy extension, since tampering wasn't needed, only observation). Captured
both the 404 and 400 cases at the wire level through it: confirms the `100
Continue` handshake completes normally and the final response genuinely has
`Content-Length: 0` in both cases — nothing hidden that the client-side logs had
been suppressing or misreporting.

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
`mgmt_cfg` either. Reproduced identically on a fully clean run (fresh mongo + fresh
AP container), ruling out leftover state from earlier attempts.

**Full state machine (only visible if you let it run ~10+ minutes — every earlier
test in this doc's history ran under 90 seconds and never saw this)**: letting the
AP's normal 10s-interval inform loop retry continuously after the Adopt click
(no artificial probing) reveals a real internal device lifecycle, confirmed via the
*unfiltered* `server.log` (grep `-i inform|adopt|ssh` had been silently swallowing
the key transition line because of how the earlier greps were scoped/timed, not
because the line doesn't exist):

```
20:06:06  webapi  adopt   device[<mac>] discovered via L3 inform, skip SSH adoption
20:06:41  \
20:07:40   | inform decryption failed with defaultAuthKey=false ... invalid JSON
20:08:39   | invalid inform_ip controller                                        } x6, ~1 min apart
20:09:38   |
20:10:37   |
20:11:36  /
20:12:35  inform  dev[<mac>] used default key in UNKNOWN state, reject it!        <- state flips
20:13:34  inform  dev[<mac>] used default key in INFORM_ERROR state, reject it!   <- and settles
20:14:33  ... (repeats indefinitely from here)
```

So: ~6 failed decrypt attempts over ~5–6 minutes, then the device transitions
`(adopting) → UNKNOWN → INFORM_ERROR` and the server stops even trying to validate
`inform_ip` — it now rejects default-key informs outright, unconditionally, every
time. This looks like a deliberate circuit-breaker: after enough failures the
server gives up on the normal recovery path entirely.

**This explains the UI status you'll see if you leave a device long enough**: once
in `INFORM_ERROR`/`UNKNOWN`, the **Status** column shows a bare `-` (this
controller build's frontend has no display string for those two states) while the
**status dot stays orange** (never told otherwise) — easy to misread as "still
pending" when it's actually a dead end. The device detail panel's Settings tab
still shows a full set of controls (Remove, Disable, Set Replacement Device, Load
Configuration) — the server hasn't discarded the device record, it's just
unreachable from this state via any inform-protocol retry. **Removing (forgetting)
the device via the UI and re-adopting from scratch is the only observed way out.**

**Hypothesis 1 (tested, implemented, did not resolve it):** real L3 adoption might
deliver the new key via `mgmt_cfg` in a `setparam` response on the inform right
after the Adopt click — `inform.lua`'s `setparam` handler previously ignored
`mgmt_cfg.authkey` entirely as intentional "security hardening" (only SSH
`set-adopt` could set a new key). Cross-checked against three independent reference
implementations — `amd989/unifi-gateway` (this project's own primary reference)
applies `mgmt_cfg.authkey` unconditionally with no SSH mechanism anywhere in its
codebase; `jeffreykog/unifi-inform-protocol`'s docs describe controller-initiated
SSH only for the L2 case. Implemented in `5bf6c5e`: accept a hex32 `authkey` from
`mgmt_cfg` while `st.adopted == false`, matching the reference behavior. **Live
re-test (with a tight 1-second-interval probe loop, no backoff, spanning the exact
Adopt-click moment) found this doesn't fix it**: the client never receives a `200`
response at all, at any polling interval — the transition from `404` to `400`
(decrypt-fail) happens between two consecutive 1-second-apart polls with zero
`200`/`setparam` response ever observed in between. So the fix is inert in this
environment specifically because there's no response body to apply it to. Kept the
code change regardless — it's strictly safer than before (only weakens the
already-public-key pre-adoption case) and matches the reference implementations
independently of whether it resolves this particular deadlock.

**Hypothesis 2 (tested, did not resolve it):** Docker deployments of the UniFi
Network Application require **Settings → System → Advanced → Device SSH Settings
→ Inform Host Override** to be explicitly set (a well-documented requirement per
linuxserver.io's own docs and community threads — without it the controller
doesn't know its own externally-reachable address). Configured `Inform Host =
controller` (this stack's Docker Compose service name) and matching SSH
credentials (`root`/AP container's real sshd password) from a **fully clean
first-contact** (fresh mongo, fresh AP, setting applied before the AP ever sent an
inform) — same exact `invalid inform_ip controller` / `defaultAuthKey=false`
failure sequence, unchanged. Still documented as a required setting in
`tools/validation/README.md` (real, independently-verified Docker requirement,
worth having correctly configured as a baseline) but ruled out as *the* cause of
this specific deadlock.

**Hypothesis 3 (tested with amd989/unifi-gateway's actual upstream code, not a
re-implementation — did not resolve it, and is the most conclusive result of the
three):** cloned `amd989/unifi-gateway` and ran its real, documented adoption
procedure verbatim (`README.md#3-adopt-to-controller`): `set-adopt -s <url>`
(404, "adopt from GUI and re-run this command") → click Adopt in the UI → re-run
the *same* one-shot `set-adopt` command immediately. This differs architecturally
from openUF's own loop: `amd989`'s daemon never repeatedly POSTs `/inform` while
unadopted at all (its main loop only sends L2 broadcast while unadopted — the only
pre-adoption inform is this one-shot CLI call), so this ruled out both "continuous
retry loop confuses the server's per-device state" and "wrong request timing" as
explanations. (Hit and fixed one unrelated bug along the way: `amd989`'s own
`BaseCollector._get_interface_macs()` returns the literal string
`'00:00:00:00:00:00'` instead of `None` when it can't resolve an interface's MAC,
which defeats its own `_resolve_lan_identity()` config-fallback check — pointed
`realif` at a real macOS interface, `en0`, to get a correct identity and eliminate
this as a confound.) **Result: identical failure.** Server log:
```
INFO  adopt  -    device[46:fc:f2:aa:ef:ea] discovered via L3 inform, skip SSH adoption
WARN  inform - dev[46-FC-F2-AA-EF-EA] inform decryption failed with defaultAuthKey=false, ... DataFormatException
ERROR inform - dev[46:fc:f2:aa:ef:ea] invalid inform_ip localhost
```
(`DataFormatException` here instead of `invalid JSON` because `amd989` zlib-compresses
its payload, so garbage-decrypted bytes fail differently downstream than openUF's
uncompressed case — same root cause, different visible symptom.) This also
corrects an earlier guess in this doc: `invalid inform_ip <value>` **is dynamic**,
not a static log-context tag — it read `controller` when reached via the Docker
Compose hostname and `localhost` here when reached from the host machine directly,
confirming it reflects whatever inform-host value the request context resolves to.

**Conclusion: this is very likely a genuine controller-version incompatibility, not
a client bug in either project.** `amd989/unifi-gateway`'s own actual code,
run exactly as its README documents, fails against this controller
(`10.4.57`) in the identical way openUF does. Given the controller's own
"Upgrade to UniFi OS Server" push, the `ucore`-microservice log noise from an
earlier finding, and the `UNKNOWN`/`INFORM_ERROR` circuit-breaker state machine
found in this investigation, this controller generation appears to have changed
internal L3-adoption behavior in ways that predate-and-break every third-party
reference implementation checked so far. Confirming this would need either a
packet capture from genuine UBNT hardware doing real L3 adoption against a
*matching* controller version, or testing against an older pinned controller
release (`10.1.x`/`10.3.x` tags exist on Docker Hub) to see if the older behavior
differs.

L2 discovery (which *would* use real SSH `set-adopt`, avoiding this whole issue) was
attempted as a fallback but `announce.lua`'s UDP broadcast fails on this Docker
bridge network (`calling 'send' on bad self` — broadcast likely unsupported/blocked
at the network level here); this is an environment limitation, not an openUF bug.
**Completing the rest of the validation matrix requires either a network where L2
broadcast actually works (e.g. macvlan instead of bridge, or real hardware), or a
genuine breakthrough on the L3 mechanism above.**

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
