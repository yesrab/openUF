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

### Cross-check against a real captured USG inform payload — `sys_stats` was wrong

`stephanlascar/unifi-gateway`'s `poc/real_inform_payload_exemple.json` is a genuine
captured inform payload from a real UniFi Security Gateway (model `UGW3`), not an
AP — so gateway-only fields (WAN config, routing, DPI, VPN, speedtest, port table)
don't apply to openUF's AP emulation and aren't a divergence. But diffing the
common envelope fields against openUF's `build_json` output found a real,
two-part bug:

- **Wrong key**: the real capture reports live CPU/memory/uptime under the
  hyphenated key `"system-stats"`. openUF sent `"sys_stats"` (underscore) — a real
  controller would never recognize this key at all, silently ignoring it (matching
  this whole investigation's pattern of unrecognized fields producing no error, just
  quiet non-functionality).
- **Wrong shape**: even the key were right, the *content* didn't match. Real
  devices send `{cpu: "<percent>", mem: "<percent>", uptime: "<seconds>"}` (all
  three as strings). openUF sent `{loadavg_1, loadavg_5, loadavg_15}` — Unix load
  averages, a completely different metric real devices don't report under this
  field at all.

Fixed: renamed to `["system-stats"]`, restructured to `{cpu, mem, uptime}`.
`mem` is computed correctly from existing `meminfo()` data. `uptime` reuses the
existing `M.uptime()` value, stringified. `cpu` needed a genuinely new capability —
added `sysinfo.cpu_percent()`, delta-sampling the aggregate `cpu` line in
`/proc/stat` between successive calls (returns `0` on the first call, since there's
no prior sample to diff against yet — this means the very first inform after
startup always reports `cpu: "0"`, which is expected and harmless). The pre-existing
top-level `mem_total`/`mem_free` (raw byte counts) fields were left alone — not
seen in this gateway capture either, but unconfirmed whether real *AP* payloads
include them, so removing them isn't justified by this evidence alone (unlike the
`system-stats` key, which is a documented, cross-referenced device-type-agnostic
field this capture and `amd989`'s `_create_complete_inform` both confirm).

**Resolved 2026-07-11** (see "Stage 2c" section below): the real controller's own
device schema has `mem_used`, not `mem_free`. Fixed — see Stage 2c.

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

### Re-tested against an older controller (`10.1.84`) — identical deadlock, and the real root cause

Ran the exact same `amd989/unifi-gateway` one-shot procedure
(`docker-compose.old-version.yml`, pinning
`lscr.io/linuxserver/unifi-network-application:10.1.84` against a fully fresh
mongo/AP stack) to test the leading hypothesis from the previous section — that this
is a controller-version regression. **Result: identical deadlock.** This makes it
two independent controller generations (`10.4.57` and `10.1.84`) failing the same
way, which rules out "version regression" as the explanation.

Inspecting the controller's own device record directly in Mongo after clicking Adopt
(`db.device.find(...)` in the `unifi` database) showed:

```json
{ "mac": "46:fc:f2:aa:ef:ea", "adopted": true, "x_authkey": "b9fd6298283fe1f1a4f59e5de221307c" }
```

So the controller *does* commit to adoption server-side (`adopted: true`, a real new
`x_authkey` generated) — it just never delivers that key to the device over any
channel the device can observe. `server.log` confirms only a single relevant line
for the entire session, logged *before* the UI Adopt click:

```
INFO  adopt  -    device[46:fc:f2:aa:ef:ea] discovered via L3 inform, skip SSH adoption
```

No further adopt/inform log lines appear afterward — not even the `defaultAuthKey`
decrypt-failure noise seen on `10.4.57`. `inform_request.log` (a dedicated request
logger declared at startup) stayed at 0 bytes for the whole session: post-adopt
informs from the client aren't being rejected with an explicit error, they're being
silently dropped before reaching any logged code path. The UI reflects this too —
the device sits at status **"Adopting"** indefinitely rather than surfacing the
`INFORM_ERROR`/`UNKNOWN` state `10.4.57` eventually showed.

Tried manually forcing the issue: re-ran `set-adopt -k b9fd6298283fe1f1a4f59e5de221307c`
(amd989's CLI does accept an explicit key argument) — still 404, no change. Reading
`unifi_protocol.py:30-39` (`encode_inform`) explains why this couldn't have worked
regardless of what the controller does: it only switches encryption to
`config.get('gateway', 'key')` when `config.getboolean('gateway', 'is_adopted')` is
already `True`. `set_adopt()` stores the passed-in key into that same config slot but
never flips `is_adopted`, so the retry re-encrypts with `MASTER_KEY` (the hardcoded
default) regardless of `-k`. This is a genuine bug in `amd989`'s own CLI tooling —
worth knowing, but it's a red herring for the controller-side question: even a
perfectly-encrypted inform using the real key would still need the controller to
*attempt* SSH or *respond* to it, and the log shows the controller decided
`skip SSH adoption` before that retry ever happened.

**Conclusion — this supersedes the "version incompatibility" theory from the
`10.4.57` section above:** the deadlock is not version-specific and not a decrypt
mismatch. It is the controller's adopt logic itself: when a device is discovered via
L3 inform (as opposed to L2 broadcast + mDNS), the controller explicitly decides not
to *attempt* SSH at all — the `skip SSH adoption` log line fires unconditionally, with
no credential check or connection attempt logged either way. (This run's **Device SSH
Authentication** was left at the panel's prefilled `admin`/placeholder value, which
doesn't match the AP container's real `root` sshd user per §3 above — but that's
irrelevant here precisely because the skip happens before credentials would ever be
checked.) The controller provides no alternative channel to hand the device its new
key once it's made this decision. This reads as an intentional real-hardware
assumption baked into the controller (an L3-only-visible device is presumed to be
behind NAT/remote and therefore not SSH-reachable, so don't bother trying), not a
Docker-deployment or version quirk. **Practically, this means: this Docker Compose
validation environment cannot complete inform-protocol-only (SSH-less) adoption end
to end, full stop — not because of a bug in openUF, amd989, or this controller
version, but because that adoption path apparently requires the controller to
successfully reach the device via L2 discovery in the first place**, which brings us
back to the `announce.lua` UDP broadcast failure on this Docker bridge network as
the actual blocker to unblocking the rest of the validation matrix.

### L2 discovery + real SSH adoption now works end-to-end — four real bugs found and fixed

The broadcast failure above (`calling 'send' on bad self`) turned out to be fixable,
not a fundamental Docker-network limitation — `strace` on the actual syscalls showed
why: `socket.udp()` in luasocket creates its underlying OS socket **lazily**, on
first real use (bind/connect/send), not at `socket.udp()` call time. `announce.lua`
called `setoption("broadcast", true)` before anything else had touched the socket,
so that call silently no-op'd against file descriptor `-1` (`setsockopt(-1, ...)  =
-1 EBADF`), meaning `SO_BROADCAST` never actually got set. The later
`setpeername(BROADCAST_ADDR, PORT)` *did* create the real socket, but without
`SO_BROADCAST` its `connect()` to `255.255.255.255` failed with `EACCES` — standard
POSIX behavior, not a container restriction. **Fix (`announce.lua`):** call
`setsockname("*", 0)` first to force real socket creation before `setoption()`.
Verified with a raw `nc -u -l` listener on the loopback that broadcast packets are
now genuinely transmitted — no faking/unicast workaround needed.

With real broadcast working, the controller picked up the announced device
immediately as a new "U6 IW" / Access Point entry (distinct from the USG's L3-only
"Gateway" entry) and, critically, **did attempt real SSH** on the resulting Adopt
click — `server.log` showed actual `sshCommand exec` / `sshj` transport activity
against the AP container's real sshd, something the L3-only path above never did.
Getting all the way to a completed adopt took three more real, unrelated fixes:

1. **SSH host key algorithm mismatch.** First attempts failed with `Unable to reach
   a settlement of HostKeyAlgorithms: [ssh-rsa] and [rsa-sha2-512, rsa-sha2-256,
   ecdsa-sha2-nistp256, ssh-ed25519]`. The controller's SSH client (`sshj`) only
   offers the legacy `ssh-rsa` (SHA-1) signature scheme — matching genuine aging
   UBNT firmware's SSH stack — but OpenSSH has excluded `ssh-rsa` from its default
   algorithm list since 8.8, and this image ships 9.7. **Fix (`ap/Dockerfile`):**
   `HostKeyAlgorithms +ssh-rsa` / `PubkeyAcceptedAlgorithms +ssh-rsa` in
   `sshd_config`. An RSA host key already existed; it just wasn't being offered.
2. **Wrong SSH account.** With the algorithm fixed, SSH negotiated but auth failed
   (`msg[loginfail]`). Bumping `sshd`'s `LogLevel` to `DEBUG3` and routing it through
   a manually-started `busybox syslogd` (the image ships no syslog daemon, so
   `LogLevel DEBUG3` output was being silently dropped, not written anywhere) showed
   the real cause: `userauth-request for user ubnt`. The controller wasn't trying
   the admin-configured **Device SSH Authentication** credentials at all — it tried
   the genuine Ubiquiti factory-default account, `ubnt`/`ubnt`. This is *correct*
   behavior, not a bug: our announce packet's `IsDefault` byte (`0x17` in the TLV
   blob, see `announce.lua`'s `make_blob_17_1a`) correctly declared the device
   unadopted/default, so the controller rightly tried real hardware's factory
   defaults instead of custom creds. **Fix (`ap/Dockerfile`):** added a `ubnt` user
   (UID 0, so it's root-equivalent like real UBNT firmware's `ubnt` account),
   password `ubnt`.
3. **`invalid inform_ip <host>` after a successful decrypt.** Once SSH auth
   succeeded, `syswrapper.sh set-adopt` genuinely ran over real SSH and wrote a real
   `/etc/openuf/state.json` with a controller-issued `authkey` — direct proof the
   full real adopt flow (SSH in, run `syswrapper.sh set-adopt <url> <key>`) works
   exactly as `USAGE.md` describes for L2. But the resulting inform loop then hit
   the same `invalid inform_ip <value>` error documented above, now provably
   *not* about the Inform Host Override setting (confirmed correctly applied via a
   direct Mongo read of `super_mgmt.override_inform_host_location`) — the value in
   the error is the AP's own `inform_url` host, echoed back. `state.json` had
   `inform_url: "http://controller:8080/inform"` (the Docker Compose service name,
   matching this repo's own documented convention), and the controller rejects a
   bare hostname there — it wants a literal IP. **Fix (validation-only, not a code
   change):** rewriting `state.json`'s `inform_url` to the controller container's
   real IP (`http://172.19.0.4:8080/inform`) and restarting `inform.lua` immediately
   produced `Device[...] adoption - completed` in `server.log`, genuine `HTTP/1.1
   200` responses on the wire (confirmed via `tcpdump`), and real decrypted
   `setparam` responses in the `debug_dump_file` capture (see §1 below) — the first
   real captured controller→AP payloads this project has ever obtained.

**A fourth, unrelated bug surfaced once real setparam responses started flowing:**
`debug_dump_file` (added in an earlier session for exactly this validation work) had
never actually fired, in any test in this document, ever — including the L3
attempts above. `handle_response` checks `cfg.config.debug_dump_file`, but the
production entry point called `M.run(dev.conf, ufhw)`, and `dev.conf` (network/LED/
VLAN hardware layout, from the modelmap file) has no `.config` sub-table — the
global `config` table (`debug_dump_file`, `state_file`, `inform_url` defaults,
declared separately in `conf.lua`) was never threaded through. The condition's `and`
short-circuit meant this was a silent no-op, not a crash, so it went unnoticed
through every prior real-controller test in this document. **Fix (`inform.lua`):**
`dev.conf.config = config` before calling `M.run`, matching the shape
`tests/test_inform_packet.lua` already asserts (`cfg = { config = { debug_dump_file
= path } }`) — the test coverage was correct all along; only the real entry point's
wiring was wrong.

**Open item — device never leaves "Adopting" in the UI despite a completed adopt and
a continuous stream of successful, decrypted informs:** with all four fixes applied,
`server.log` shows genuine `Device[...] adoption - completed`, `tcpdump` confirms
real `HTTP/1.1 200` responses roughly every 10s, and `debug_dump_file` captures real
`_type: "setparam"` responses each cycle — but the device's Mongo record never gets
a `last_seen` field and keeps `wait_for_initial_inform: true` indefinitely, and the
controller sends a **freshly different `cfgversion` on every single cycle** (not a
stable value settling once applied) even though this device's own `state.json`
correctly tracks and echoes back whatever `cfgversion` it was last given. Also
observed: the controller told the device to switch on `use_aes_gcm=true` via
`mgmt_cfg`, the device did (`state.json`'s `use_gcm` flips to `true`, and subsequent
GCM-encrypted informs continue to decrypt successfully server-side, so the switch
itself works) — yet the device's own Mongo record still shows `x_aes_gcm: false`.
Not yet root-caused; noted here as the next concrete thread rather than something
resolved by the four fixes above. Does not block the matrix rows below, since a real
`setparam` payload was captured regardless of the device settling to "Connected".

---

## 1. Initial adopt handshake

- **Status:** ✅ captured via real L2 (SSH) adoption — see "L2 discovery + real SSH
  adoption now works end-to-end" above. L3-only adoption (no SSH) remains blocked as
  documented above.
- **Compare against:** `mgmt_cfg` key=value string format, `set-adopt` invocation
  shape (`openuf/hook/syswrapper.lua`)
- **Findings:** `syswrapper.sh set-adopt <url> <key>` ran for real over genuine SSH
  and wrote a real `/etc/openuf/state.json` — the actual shape openUF already
  produces matches what real SSH adoption expects (`adopted`, `authkey`,
  `inform_url`, `cfgversion`, `use_gcm` keys). No code changes needed here; this
  confirms the existing `syswrapper.lua`/`state.lua` shape is correct.
- **Code changes:** none — existing implementation confirmed correct by a real SSH
  adopt round-trip.

## 2. Baseline post-adopt inform response

- **Status:** ✅ captured (real, via `debug_dump_file`)
- **Compare against:** top-level `_type` field name/values (`noop`/`config`/`cmd`)
  (`openuf/inform.lua:388-490`)
- **Findings:** real captured response, repeated every ~10s with a fresh
  `cfgversion` each time (see "Open item" above):
  ```json
  {
    "_type": "setparam",
    "mgmt_cfg": "capability=notif,notif-assoc-stat\nselfrun_guest_mode=pass\ncfgversion=fe34084c2ffa1eeb\nled_enabled=true\nstun_url=stun://172.19.0.4:3478/\nmgmt_url=https://172.19.0.4:8443/manage/site/default\ninform_url=http://172.19.0.4:8080/inform\nuse_aes_gcm=true\nreport_crash=true\n",
    "server_time_in_utc": "1783723586794"
  }
  ```
  Confirms `_type: "setparam"` (not `"config"`) is the real response type for this
  baseline case, and `mgmt_cfg` is genuinely a `key=value\n`-joined string (matching
  this project's prior reference-material-derived assumption, now verified against
  a real controller) — not JSON. Field names `stun_url`, `mgmt_url`, `inform_url`,
  `use_aes_gcm`, `report_crash`, `selfrun_guest_mode`, `led_enabled`, `capability`
  all confirmed real. No `vap_table`/`radio_table`/`network_table` present in this
  baseline case (device has no WiFi config assigned yet in the controller UI).
- **Code changes:** none — `inform.lua`'s existing `mgmt_cfg` key=value parser
  (§ `setparam` handler) already handles this shape correctly, including the
  `use_aes_gcm` → `st.use_gcm` and `cfgversion` fields seen here.

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

## Stage 2b findings (2026-07-11): spectrum-scan result shape, from the controller side

**Result: high-confidence field names recovered. Implemented in
`openuf/inform.lua` and `openuf/sysinfo.lua` — see "Code changes" below.**

Stage 2 (static AP firmware analysis, above) hit a dead end because the
U6-InWall's public firmware is a kernel-only OTA delta with an encrypted OS
partition (see that section for the full writeup). The controller side turned
out to be much more tractable: **UniFi Network Application is a Java app, and
Java bytecode retains field-name string constants in the class-file constant
pool even when ProGuard-style obfuscation has renamed the classes/methods
themselves** — a fundamentally different (and much friendlier) analysis
target than the AP's encrypted ARM firmware.

- **Method:** pulled `lscr.io/linuxserver/unifi-network-application:10.4.57`
  (the exact version already pinned for Stage 1 live-controller validation —
  see `tools/validation/docker-compose.yml`), exported the container
  filesystem with `docker create` + `docker export` (no need to actually run
  it), and extracted `/usr/lib/unifi/lib/internal/internal-dependencies.jar`
  (the real 29MB application jar — `ace.jar` itself is just a
  license-protected bootstrap `Launcher`, not the app logic). Decompressed
  every `.class` entry (`unzip -p ... '*.class'`) into one blob and extracted
  printable-ASCII runs directly in Python (`strings` on macOS chokes on
  concatenated class files because `0xCAFEBABE`, the Java class magic number,
  also happens to be the Mach-O fat-binary magic number it tries to parse).
- **Confirmed field names** (found repeatedly, clustered with unmistakable
  neighbors like `radio`, `radio_name`, `radio_table_stats`,
  `getRadioTableStats` — i.e. genuinely part of the per-radio stats object,
  not coincidental string matches):
  - `spectrum_table` — array, nested inside each `radio_table_stats` entry
    (sibling of the already-implemented `cu_total`/`cu_self_rx`/`cu_self_tx`
    fields, and of `last_channel`/`last_interference_at`/`gain`/`tx_power`
    etc. — confirms openUF's existing `radio_table_stats` shape is on the
    right track).
  - `spectrum_table_time`, `spectrum_scan_timestamp` — sibling timestamp
    fields alongside `spectrum_table`.
  - `spectrum_scanning` (wire field; Java bean `isSpectrumScanning`/
    `setIsSpectrumScanning`) — boolean, live scanning-in-progress state.
  - `spectrum_enabled`, `spectrum_cfg` — a config-side toggle/cmd-payload key
    (controller→AP), separate from the result-reporting direction.
  - `supportSpectrumScan` — AP-declared capability flag.
  - Per-entry fields inside `spectrum_table`, found in **two independent**
    Lombok-generated (`Llombok/Generated;`) data-class constant pools, both
    with the identical field set: **`channel`, `center_freq`, `width`,
    `utilization`, `interference`**. One of the two classes additionally has
    `radio`/`radio_name` fields (confirms per-radio, per-channel entries).
  - A response-code enum in the same area: `SUCCESS`, `GENERAL_FAILURE`,
    `INVALID_PARAM`, `INVALID_VALUE`, `MISSING_PARAM`, `DEVICE_DISALLOWED`,
    `UNSUPPORTED_CHANNEL`, `UNSUPPORTED_SPECTRUM`, `VERSION_NOT_SUPPORTED` —
    likely the controller's own pre-send capability-check result, not
    something the AP returns; recorded for completeness, not acted on.
  - **Adjacent finding, now fixed:** the same class shows `cu_self_rx`/
    `cu_self_tx` as two separate fields, whereas openUF's `radio_table_stats`
    builder used to combine rx+tx into one `cu_self` field. Split into
    `cu_self_rx`/`cu_self_tx` in `openuf/inform.lua` build_json (~line
    338-343), each computed independently as `channel_time_rx` (or `_tx`)
    over `channel_time`, matching the real controller's field names.
- **What's still a guess (field names are confirmed; exact semantics/units
  are not):** `width` — no live-scan source gives per-channel width, so the
  implementation uses the radio's own configured `htmode` (e.g. `HT40` → 40)
  as a uniform approximation, not a true per-entry measurement.
  `interference` — no equivalent metric exists in `iw survey dump` output;
  implementation passes through the raw noise-floor dBm value as the closest
  available proxy. Both are clearly commented as best-effort in the code.
  `channel`/`center_freq`/`utilization` are derived directly and mechanically
  from `iw dev <ifname> survey dump` (already-parsed by
  `openuf/sysinfo.lua`'s `radio_stats()`) and are high-confidence.
- **Code changes:**
  - `openuf/sysinfo.lua`: added `M.channel_from_freq(freq)` (2.4/5/6GHz
    frequency→channel helper).
  - `openuf/inform.lua`: `spectrum-scan` cmd handler (~line 540) now builds
    a `spectrum_table` per radio from `iw dev <ifname> survey dump` output
    and caches it in the new module-level `M._spectrum_cache` (in-memory
    only, not persisted to `state.json` — ephemeral like `radio_stats()`/
    `sta_table()`). `build_json`'s `radio_table_stats` loop (~line 333)
    attaches the cached `spectrum_table`/`spectrum_table_time`/
    `spectrum_scan_timestamp`/`spectrum_scanning` fields when present.
  - Tests: `tests/test_inform_packet.lua` (cmd handler builds the cache
    correctly from survey-dump fixture data) and
    `tests/test_inform_json.lua` (build_json surfaces/omits the cached
    fields correctly).
- **Not yet possible:** validating against a real captured wire payload
  (Stage 1's L3-adoption blocker still applies) — this is a strong,
  code-derived hypothesis, not a live-verified capture. Re-verify against a
  real inform if/when L2 adoption or a live capture becomes possible.

## Stage 2 findings (2026-07-11): AP→controller spectrum-scan-result shape

**Result: inconclusive — the JSON key names could not be recovered from the
public firmware image. Do not re-attempt this exact approach without a new
angle (see "Possible follow-ups" below).**

- **Image analyzed:** official U6-InWall (`U6IW`) release firmware
  `v6.8.2+15592`, pulled directly from Ubiquiti's own firmware API
  (`fw-update.ubnt.com/api/firmware-latest`, `platform=U6IW`), file
  `6bbe-U6IW-6.8.2-4640c65b-3bb0-4844-943b-b2103ecd4bf9.bin`, md5
  `0fec04452cadd2d025777d36ab2974ea` — this is the exact image a real device
  would pull, not a repackaged/third-party mirror.
- **Container format:** `file` identifies it as "HIT archive data". `binwalk`
  finds 5 small statically-linked ARM/ARM64 ELF binaries and an LZMA blob +
  a gzip'd `dtb_combined.bin` before an EFI GPT partition table at
  offset `0x131974`.
- **GPT partitions (5 total, confirmed both via `binwalk`'s efigpt extractor
  and a manual GPT header parse — `num_part_entries=5`):**
  `HLOS` (~21.3MB, has data), `HLOS_1` (backup/inactive slot, **0 bytes**),
  `bs` (**0 bytes**), `cfg` (**0 bytes**), `log` (**0 bytes**). **No
  system/rootfs/application partition exists in this image at all.**
- **`HLOS.img` is not readable plaintext:** true Shannon entropy is a flat
  **8.0 bits/byte** (maximum) across ~95% of the file (computed per-1MB-block
  in Python, not just eyeballing binwalk's entropy graph, which is easy to
  misread), with no gzip/xz/lzma magic bytes anywhere in that region and zero
  `strings` hits for a kernel version banner ("Linux version ..."), any
  `ath11k`/driver strings, or any of `scan/spectrum/rssi/noise/channel/bssid`.
  Only the last ~1.3MB (entropy drops to ~4.1) is plaintext — and that's just
  device-tree blobs (`qcom,ipq5018-*` compatible strings), not application
  code. **HLOS is therefore either encrypted or compressed with a scheme this
  toolchain doesn't recognize** — consistent with Ubiquiti's newer
  WiFi6/Qualcomm-IPQ line using verified/encrypted boot, unlike legacy
  MIPS/AirOS-era squashfs firmware (which the community has always been able
  to `binwalk`/`strings` freely — this device generation is different).
- **The 5 early ELF binaries** (carved directly, all statically-linked,
  no section headers — bootloader-stage, not userspace) contain no
  scan/spectrum-related strings; one has generic PCI-bus-enumeration/VGA-mode
  strings ("Scanning PCI devices...", "doublescan"), consistent with a
  generic bootloader/firmware library, not AP-specific code.
- **Conclusion:** the public OTA download for this device is a *kernel-only*
  delta update — no separate userspace/application partition ships through
  this channel at all, so the inform-client binary that would contain the
  spectrum-scan JSON key strings simply isn't present in this artifact,
  encrypted or not.
- **Possible follow-ups (not attempted this session):** (a) an *older*
  pre-2023 U6-IW firmware build might predate encrypted/kernel-only OTA
  packaging and could still ship a full squashfs rootfs — untested; (b) SSH
  into a real, owned U6-IW device directly (once/if L2 adoption is validated)
  and pull the running inform-daemon binary or its `/proc/<pid>/maps`-mapped
  file straight off the live filesystem, sidestepping the OTA-package
  question entirely; (c) live-capture the actual wire bytes AP→controller
  during a real scan on real hardware (packet capture on the LAN between a
  real AP and a real controller) rather than trying to derive the shape
  statically.

## Stage 2c (2026-07-11): full-payload audit against the controller's device schema

Prompted by "have you validated all payloads being sent?" — Stage 2b only
checked the spectrum-scan fields. Since the same decompiled
`internal-dependencies.jar` (see Stage 2b) turned out to contain the
controller's **entire internal Device model** in one class,
`com/ubnt/data/cVbZoFIZsWYaVCquTr` (plus ~90 nested classes, one per wire
sub-object — vap stats, sta entries, radio config, lldp neighbors, sysinfo,
LTE, PoE, PTP, etc.), it was cheap to cross-check every field name openUF
sends against it, not just the spectrum ones. Decompiled with `jadx` this
time (not just raw string extraction) to get properly-scoped classes instead
of one flat string soup — much easier to confirm which fields belong
together. Checked every outbound field name (`grep` against the full
constant-pool string dump, ~1.2M lines) with high hit/no-hit confidence.

**Confirmed and fixed (mechanical renames, unambiguous — implemented in this
pass):**

| Location | Was | Now | Evidence |
|---|---|---|---|
| top-level payload | `mem_free` | `mem_used` (= total − free) | found alongside `mem_total`/`mem_buffer`/`loadavg_1/5/15` in a Lombok sysinfo DTO |
| `radio_table` entry | `htmode` | `ht` | found in the real radio-config DTO (`eWivisHeQsnaqDtx`), alongside `channel`/`tx_power`/`builtin_antenna`/`max_txpower` — confirms this is the right class |
| `radio_table`/`vap_table` entry | `txpower` | `tx_power` | same DTO as above |
| `vap_table` entry | `ssid` | `essid` | found in the real vap-stats DTO (`QCtdvLKOBb`), alongside `num_sta`/`is_guest`/`bssid`/`radio_name`/`rx_bytes` etc. |
| `vap_table` entry | `networkconf_id` | `wlanconf_id` | same DTO as above (note: `apply_config`'s **inbound**, controller-pushed config parsing still correctly uses `ssid`/`networkconf_id` — that's a different direction/DTO, go-unifi's admin REST model, not touched) |
| top-level payload | `spectrum_scanning`/`spectrum_scan_timestamp` nested in each `radio_table_stats` entry | moved to top-level (device-level) fields | found as flat fields on the outer `cVbZoFIZsWYaVCquTr` class itself, distinct from `spectrum_table`/`spectrum_table_time` which are confirmed inside the per-radio DTO |

Code: `openuf/inform.lua` (mem_used, spectrum fields relocation),
`openuf/ucihelper.lua` (`ht`/`tx_power`/`essid`/`wlanconf_id` in
`get_radio_table`/`get_vap_table`). Tests updated to match in
`tests/test_inform_json.lua`, `tests/test_inform_packet.lua`,
`tests/test_ucihelper.lua`. All 156 tests pass.

**Found, NOT yet fixed — needs a decision before implementing (bigger
structural change, and/or requires inventing data with no local source):**

- **`user_table` (flat, top-level) is likely structurally wrong.** The string
  `sta_table` (not `user_table`) appears repeatedly, including nested inside
  the vap-stats DTO itself (`QCtdvLKOBb` has a field `wJxjaSoY = "sta_table"`)
  — i.e. the real per-client list is probably **nested inside each
  `vap_table` entry**, not flattened into one top-level array. The per-client
  entry DTO (`QCtdvLKOBb$KHUkYjHujLgFBD`) has fields `active`, `mac`,
  `ap_mac`, `name`, `channel`, `radio`, `capacity`, `linkscore`, `signal`,
  `throughput`, `rssi`, `multicast` — notably **no `rx_bytes`/`tx_bytes`/
  `rx_packets`/`tx_packets`** (openUF's current `user_table` fields), and
  four fields (`capacity`, `linkscore`, `throughput`, `multicast`) that have
  no obvious source in `iw station dump` output — would need invented/
  approximated values, same category of guess as spectrum's `width`/
  `interference`.
- **`lldp_table` entries are mostly wrong.** Real DTO (`OXMua`): `chassis_descr`,
  `chassis_id`, `local_port_name`, `local_port_idx`, `is_wired`, `port_id`,
  `port_descr`. openUF currently sends `chassis_id`, `port_id` (both
  correct) plus `system_name`, `port` (neither matches — `port` should
  likely be `local_port_name`, and `system_name`/`chassis_descr` are
  probably two *different* LLDP TLVs — System Name vs. System Description —
  not interchangeable, so mapping openUF's captured system-name value into a
  field called `chassis_descr` would put the right-shaped but
  wrong-*meaning* data under that key). Fixing this properly means extending
  `openuf/lldp.lua`'s `_parse_neighbor` to also pull `chassis.descr`/
  `port.descr` from `lldpctl -f json` output, which needs new fixture data,
  not just a rename.
- **`bootrom_version` has no confirmed replacement.** Searched the entire
  device schema (all ~90 nested classes) — no field resembling it exists at
  all (closest is `boot_time`, a timestamp, not a version string). Likely
  just an extraneous key the real controller ignores rather than a
  misnamed one — no evidence for what, if anything, to rename it to.

Not acted on without direction because the first item changes the payload's
top-level shape (removes `user_table`, restructures `vap_table`) and the
second requires extending a different module's data collection — both bigger
than the mechanical renames above, and the "correct" values for
capacity/linkscore/throughput/multicast aren't derivable from anything on a
stock OpenWrt AP.

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

## Stage 2 (attempted 2026-07-11: firmware side inconclusive, controller side succeeded)

Goal: determine the AP→controller spectrum-scan-result reporting shape — the
one item Stage 1's controller-only setup can't resolve on its own, since it
requires observing what a genuine AP sends up, not just what the controller
pushes down.

- **Stage 2 (AP firmware, static extraction via `binwalk`/`strings`/`radare2`):
  inconclusive.** The real, current U6-InWall firmware image turned out to be
  a kernel-only OTA delta with an encrypted OS partition — no usable result.
  See "Stage 2 findings" under section 8 above for the full analysis. Don't
  re-run the same binwalk/strings pass against the same (or a
  same-generation) firmware build expecting a different outcome.
- **Stage 2b (controller side, decompiling the real UniFi Network
  Application's Java bytecode): succeeded.** Recovered high-confidence field
  names (`spectrum_table`, `spectrum_table_time`, `spectrum_scan_timestamp`,
  `spectrum_scanning`, and per-entry `channel`/`center_freq`/`width`/
  `utilization`/`interference`) directly from the controller's own
  constant-pool strings — see "Stage 2b findings" under section 8 above.
  Implemented in `openuf/inform.lua`/`openuf/sysinfo.lua`, tested, not yet
  live-verified against a real captured inform payload.
