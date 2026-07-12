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
findings below are confirmed; the per-scenario matrix is blocked on reaching a
fully "Connected" device — the adoption *handshake* itself works fine (both
L2/SSH and L3/`mgmt_cfg`-only, see "L3 adoption — confirmed working via
mgmt_cfg" below), but every device gets stuck at "Adopting" indefinitely
afterward (`wait_for_initial_inform: true` never clears) regardless of which
adoption path was used — see "wait_for_initial_inform: what actually flips it"
for the root-cause investigation into that, which is the current blocker for
the rest of the matrix.

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

### L3 adoption — confirmed working via `mgmt_cfg` (no SSH)

For L3-discovered devices, the controller never SSHes in at all:

```
INFO  adopt  -    device[<mac>] discovered via L3 inform, skip SSH adoption
```

This is expected controller behavior, not an error — L3-discovered devices get
their new `authkey` a different way: delivered directly in the `mgmt_cfg` field
of the `setparam` response sent immediately after the Adopt click. Confirmed via
a clean test (fresh `docker compose down -v` + `up -d --build`, `announce.lua`
never started at all — pure L3, no broadcast, no SSH actor anywhere in the
loop — just `syswrapper.sh set-inform <url>` then `inform.lua`, then Adopt
clicked in the UI):

```
INFO  adopt  -    device[c2:0b:bc:4c:3f:97] discovered via L3 inform, skip SSH adoption
INFO  adopt  - Device adoption - initial mgmt_cfg sent for device[c2:0b:bc:4c:3f:97]
INFO  adopt  - Device[c2:0b:bc:4c:3f:97] adoption - completed
```

The decrypted `debug_dump_file` capture shows the real `setparam` that delivered
the key:

```json
{"_type":"setparam","mgmt_cfg":"capability=notif,notif-assoc-stat\nselfrun_guest_mode=pass\ncfgversion=e07e7991b8c62b47\nled_enabled=true\nstun_url=stun://172.19.0.4:3478/\nmgmt_url=https://172.19.0.4:8443/manage/site/default\nauthkey=ccc32a3bbe40157773294de8ed683627\ninform_url=http://172.19.0.4:8080/inform\nuse_aes_gcm=true\nreport_crash=true\n","server_time_in_utc":"1783841863822"}
```

`inform.lua`'s `setparam` handler already accepts this correctly (`5bf6c5e`:
accepts a hex32 `authkey` from `mgmt_cfg` only while `st.adopted == false`,
matching `amd989/unifi-gateway`'s own unconditional acceptance — that project has
no SSH mechanism anywhere in its codebase, since L3 is its only adoption path).
`state.json` picked up the real controller-issued key
(`ccc32a3bbe40157773294de8ed683627`) and every cycle since (8+ consecutive,
~10s apart, over 80+ seconds observed) decrypted successfully with zero new
failures.

**The still-open issue is separate from the adoption handshake itself:** the
device gets stuck at "Adopting" in the UI indefinitely afterward, for both L2
and L3 alike — see "wait_for_initial_inform: what actually flips it" further
below for the root-cause investigation into that.

L2 discovery requires `announce.lua`'s UDP broadcast to actually work on the
network in use — see the next section for the real fixes that made that work on
this Docker bridge network.

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

**Reconfirmed 2026-07-12** on a from-scratch rebuild of this whole environment
(`docker compose down -v` + `up -d --build`, fresh mongo/controller/AP, after this
session's `sta_table`/`lldp_table`/`mem_used`/spectrum-scan payload changes): the exact
same behavior reproduces — `adoption_completed: true`, `wait_for_initial_inform: true`
stuck indefinitely, `x_aes_gcm: false` in Mongo despite the device's own `state.json`
correctly tracking `use_gcm: true` and GCM decryption clearly succeeding every cycle,
and `cfgversion` changing on literally every single `setparam` (`105777b8` →
`02103d91` → `5c8972d9` → `4e6a0499` → `9c06e675` over five consecutive cycles, no
stabilization). One difference from the original observation: `last_seen` **does**
now populate and update on the Mongo device doc (`1783839075` and climbing) — the
earlier claim that it "never gets a `last_seen` field" no longer holds, though this
alone isn't enough to flip `wait_for_initial_inform`. Useful confirmation either way:
none of this session's payload-shape changes broke anything (informs keep decrypting
and updating `last_seen`/`cfgversion` cleanly, no new parse errors in `server.log`),
and this stuck-adopting issue is clearly independent of them, reproducing identically
before and after.

## wait_for_initial_inform: what actually flips it

Root-caused directly from the real controller's own decompiled logic (same
`internal-dependencies.jar` from `unifi-network-application:10.4.57` used for
Stage 2b/2c — `jadx`-decompiled, cross-checked against raw `javap -v` bytecode
disassembly where `jadx` silently failed to reconstruct readable Java for
specific methods without any warning).

**High confidence (exact bytecode, unambiguous):** `wait_for_initial_inform`
only clears when the device's own `isWaitingForInitialInform()` is true *and*
`need_pre_provisioning` is falsy. Found in
`com.ubnt.service.devmgr.l.MiVjHefaf`'s fallback inform-handler method
(`javap` bytecode, since `jadx`'s decompile of this exact method silently
dropped its body — no warning marker, just absent from the output; the
surrounding class decompiled fine everywhere else):

```
invokevirtual  uuvchZbWVhirD.isWaitingForInitialInform:()Z
ifeq           <skip>
aload          device
ldc            "need_pre_provisioning"
iconst_0
invokevirtual  uuvchZbWVhirD.is:(Ljava/lang/String;Z)Z
ifne           <skip>                 ; need_pre_provisioning == true -> skip clearing
ldc            "wait_for_initial_inform"
aconst_null
invokevirtual  SNMiFVJXxaonBOtqbJ.<setDeviceField>:(...)V   ; clears it (sets null)
```

On our own test device, `need_pre_provisioning` is absent from the Mongo
record at all (confirmed via direct query) — `.is(key, false)` returns the
default (`false`) for an absent key, so this specific condition is already
satisfied. The flag not clearing therefore isn't about this condition itself;
it's about whether this code ever runs at all for our informs — see below.

**High confidence:** this fallback method is the last stage of a
chain-of-responsibility across several inner-class handlers
(`MiVjHefaf$VVyiC`, `MiVjHefaf$MiVjHefaf` (site lookup), `MiVjHefaf$aeyOUcXIsMsQw`
(encryption check), `MiVjHefaf$jRsSex` (device-cache lookup),
`MiVjHefaf$rYtJfMBbtgWvku` (MAC consistency)), each of which can short-circuit
with an early response before ever reaching the fallback, wrapped in a
per-device lock (`deviceLockService`, a thin wrapper over a generic
lock-by-string-key utility — ruled out as a stuck-lock explanation, since our
informs complete quickly and normally end-to-end, not hanging).

**Traced further, then hit the real limit of static analysis:**

- **`getDeviceRecord(mac)` (the `informHandler.bLwwMKkr` interface method
  called by `InformServlet`) is implemented by `MiVjHefaf` itself, which
  delegates to `deviceManager.<lookup>(mac, dbCallback=true)`
  (`com.ubnt.service.devmgr.SNMiFVJXxaonBOtqbJ`).** That method is a genuine
  **cache-then-DB-fallback**: check an in-memory cache namespaced
  `("global", "minidev", mac)` first; on a cache miss, if `dbCallback` is
  true (it is, here), fall through to a real Mongo lookup by MAC, and — only
  on a DB hit — build a small "minidev" summary record (`_id`, `site_id`,
  `authkeys`, `x_aes_gcm`, `hash_id`) and cache it. So on paper this should
  self-heal within one inform even after a cold cache: DB hit → cache
  populated → every subsequent call cached. No negative-caching path exists
  (a DB miss just returns `null` without writing anything to the cache).
- **Checked empirically whether the early-exit paths were actually firing**:
  none of the short-circuit log lines from any handler in the chain
  (`"doesn't belong to any site"`, `"not found in cache, rejecting inform"`,
  `"sent unencrypted inform, rejecting inform"`, `"invalid inform (mac
  inconsistent...)"`) appear in `server.log` even once across hundreds of
  real inform cycles. Initially assumed this meant the code wasn't running,
  but this turned out to be a red herring the first time: **all of these
  route through custom, *flat* logger names, not per-class/per-package
  ones** — found by decompiling the shared logging helper,
  `com.ubnt.service.system.HCKpgcBFPLu`, which does
  `LoggerFactory.getLogger("inform")`, `getLogger("adopt")`, etc. (dozens of
  hand-picked flat names, e.g. `"inform.uap"`, `"core.lock"`,
  `"web.api"` — nothing resembling a Java package path). The default config
  only sets `com.ubnt` (a real package prefix) to INFO, which does nothing
  for these flat names, but they still default to the root logger's INFO
  level, hiding the `.debug()` calls. **Fixed properly this time**: built a
  custom `logback.xml` (extracted from `ace.jar`, this project's own
  original) with explicit `<logger name="inform" level="DEBUG"/>` and
  `<logger name="adopt" level="DEBUG"/>` entries, pointed the container at it
  via `-Dlogback.configurationFile=` (added to
  `/etc/s6-overlay/s6-rc.d/svc-unifi-network-application/run`), and
  restarted. **Result: still zero messages from the "inform" logger** for
  ongoing post-adopt informs (a single one-off `WARN` from *before* adoption
  completed is the only hit in the whole log). Since several of the chain's
  handlers only log on their *short-circuit* branch and silently pass
  through on the normal/happy path (re-reading each one's source: `VVyiC` and
  the site-lookup handler both return silently when `_devsiteid` is already
  present; the encryption check returns silently when the inform is
  correctly encrypted; the cache-lookup handler returns silently on a cache
  hit) — **zero log output is actually consistent with everything passing
  normally**, not proof that the chain is being skipped. This means the
  `_devsiteid`-null hypothesis from the previous pass was likely a red
  herring too, not a confirmed cause.
- **The actual fallback method (`chgwykfBxZCAuEHPPQ(KHUkYjHujLgFBD)`, the one
  containing the `wait_for_initial_inform` clear) is ~5,182 bytecode
  instruction units long** (`jadx`'s own reported count when it gave up
  decompiling it) — far too large to fully re-derive via manual `javap`
  reading in reasonable time. The `need_pre_provisioning` check is roughly
  60% of the way through it; there is a large amount of other logic before
  that point whose branches haven't been individually mapped.

**This is where static bytecode analysis stops being the right tool.**
Everything traceable via decompilation/disassembly has been traced; the
remaining question — which specific branch inside that one large method is
being taken for our device, and why — needs either runtime instrumentation
(attaching a Java debugger via JDWP, or patching in extra log statements and
repackaging the jar) or a source-level report from Ubiquiti. Both are a
meaningfully bigger undertaking than continuing to read disassembly, and
would need explicit buy-in before spending more time on this specific thread.

**Environment note:** the live validation controller currently has a
DEBUG-level `custom-logback.xml` and a modified startup script (see above) —
left in place since it's harmless and this environment gets rebuilt from
scratch regularly anyway, but worth knowing if `server.log` looks chattier
than expected in a future session.

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

- **Status:** 🛑 blocked — requires a fully "Connected" device, see "wait_for_initial_inform: what actually flips it" below
- **Compare against:** `vap_table` field names (`openuf/ucihelper.lua` `apply_config()`)
- **Findings:**
- **Code changes:**

## 4. VLAN-tagged network + SSID assignment

- **Status:** 🛑 blocked — requires a fully "Connected" device, see "wait_for_initial_inform: what actually flips it" below
- **Compare against:** `network_table`/`networkconf_id` join shape
  (`openuf/ucihelper.lua`)
- **Findings:**
- **Code changes:**

## 5. Fast Roaming / WPA3 fast roaming toggle

- **Status:** 🛑 blocked — requires a fully "Connected" device, see "wait_for_initial_inform: what actually flips it" below
- **Compare against:** presence/absence and real field name of
  `mobility_domain`/`r0kh`/`r1kh`/`fast_roaming_enabled`
  (`openuf/ucihelper.lua` `derive_mobility_domain` stopgap)
- **Findings:**
- **Code changes:**

## 6. TX power (Low/Medium/High/Custom) per radio

- **Status:** 🛑 blocked — requires a fully "Connected" device, see "wait_for_initial_inform: what actually flips it" below
- **Compare against:** `radio_table` field name/value shape
  (`openuf/ucihelper.lua` `rf_config()`)
- **Findings:**
- **Code changes:**

## 7. Locate trigger

- **Status:** 🛑 blocked — requires a fully "Connected" device, see "wait_for_initial_inform: what actually flips it" below
- **Compare against:** exact `cmd` string(s) (`openuf/inform.lua:455-460`)
- **Findings:**
- **Code changes:**

## 8. RF/spectrum scan trigger (trigger only)

- **Status:** 🛑 blocked — requires a fully "Connected" device, see "wait_for_initial_inform: what actually flips it" below
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

**Fixed 2026-07-12 (both structural items, user asked to proceed on both):**

- **`user_table` (flat, top-level) → nested `sta_table` per `vap_table`
  entry.** The string `sta_table` (not `user_table`) appears repeatedly,
  including nested inside the vap-stats DTO itself (`QCtdvLKOBb` has a
  field `wJxjaSoY = "sta_table"`) — the real per-client list is nested
  inside each `vap_table` entry, not flattened into one top-level array.
  `openuf/inform.lua`'s `build_json` now attaches `vap.sta_table` instead
  of appending to a top-level `user_table` (removed from the payload
  entirely); `vap.num_sta` is unchanged (the real DTO has both `num_sta`
  and the nested `sta_table` side by side).
  - Per-entry fields: `mac`, `ap_mac`, `channel`, `radio`, `signal` — direct,
    high confidence. `rssi` — aliased to the same `signal` value from `iw
    station dump` (that command doesn't expose a separately-measured RSSI).
    `active` — always `true` (an entry only exists if `iw station dump`
    currently lists it as associated). `name` — omitted (controller/admin
    assigned, no local source; not invented).
  - **`capacity`/`linkscore`/`throughput`/`multicast`: researched online
    before implementing** (`paultyng/go-unifi`'s generated `User` REST model,
    and `unpoller/unifi`'s `clients.go`, which models the live `/stat/sta`
    REST client-stats object in detail — confirms `rssi`/`signal`/`noise`/
    `tx_power`/`satisfaction`/`roam_count`/etc. as real UniFi client-stat
    concepts, but **neither reference has `capacity`, `linkscore`,
    `throughput`, or `multicast` at all**). Conclusion: these are likely
    AP-native single-inform-snapshot concepts with no public documentation
    anywhere (the REST client model is a richer, controller-side aggregate
    across time/devices, not a 1:1 mirror of one inform's raw `sta_table`).
    Implemented as best-effort, explicitly flagged in code:
    `capacity` = negotiated `tx_bitrate` from `iw station dump` (Mbps,
    floored) — closest available proxy for "available bandwidth to this
    client". `throughput` = delta-sampled byte rate (bytes/sec), reusing
    the same pattern as `sysinfo.cpu_percent()`'s `/proc/stat` delta
    sampling (0 on the first sample for a given MAC, no prior sample to
    diff against) — new module-level `M._sta_stats_cache` in
    `openuf/inform.lua`, and a new injectable `M._time` (defaults to
    `os.time`) so the delta can be tested deterministically.
    `linkscore`/`multicast` = `0` placeholders — genuinely no local source
    or public reference found for either; **still needs live-capture
    verification**, unlike everything else in this document.
- **`lldp_table` field names fixed.** Real DTO (`OXMua`): `chassis_descr`,
  `chassis_id`, `local_port_name`, `local_port_idx`, `is_wired`, `port_id`,
  `port_descr`. `openuf/lldp.lua`'s `_parse_neighbor` already extracted
  `chassis.descr` (as `system_desc`) but it wasn't wired into the payload;
  added extraction of `port.descr` (`port_descr`, same dual table/string
  handling as `chassis.descr` — the test fixture already contained a
  `port.descr` value, proving lldpd emits it) and a new
  `M._local_port_idx(port_name)` that reads
  `/sys/class/net/<port>/ifindex` directly (this is *our own* local
  interface, not something lldpctl reports about the neighbor, so it's a
  local sysfs lookup, not a protocol field — nil/omitted off-target or in
  tests without a real interface). `openuf/inform.lua`'s `lldp_table`
  construction renamed `system_name`→`chassis_descr` (note: these are
  **not the same underlying value** — System Name vs. System Description
  are different LLDP TLVs; `chassis_descr` is now correctly sourced from
  `chassis.descr`, not `chassis.name`) and `port`→`local_port_name`, and
  added `is_wired = true` unconditionally (LLDP is inherently a wired-link
  protocol, not a guess).
- **`bootrom_version` has no confirmed replacement.** Searched the entire
  device schema (all ~90 nested classes) — no field resembling it exists at
  all (closest is `boot_time`, a timestamp, not a version string). Likely
  just an extraneous key the real controller ignores rather than a
  misnamed one — left as-is, no evidence for what to rename it to.

Code: `openuf/inform.lua`, `openuf/lldp.lua`. Tests:
`tests/test_inform_json.lua`, `tests/test_lldp.lua`. All 160 tests pass.

## 9. Firmware upgrade offer

- **Status:** ⚠️ attempted 2026-07-12 (real click via UI, real traffic capture) —
  **no `_type:"upgrade"` payload obtainable in this environment**, root cause
  identified (not a new bug — same underlying cause as the "stuck in Adopting"
  open item above).
- **Compare against:** `_type:"upgrade"` shape, `version`/`url` field names
  (`openuf/inform.lua:438-448`)
- **Findings:** Clicked the real "Update" button in the controller UI while
  running `tcpdump` on the AP container's inform port (8080) plus the existing
  `debug_dump_file` decrypted-response capture in parallel. **Result: nothing
  was sent to the device at all.** `tcpdump` shows only the same-shaped,
  same-size (2242-byte request / ~522-byte response) periodic inform/`setparam`
  cycle before and after the click — no new connection, no larger response.
  `debug_dump_file` never captured a `_type:"upgrade"` entry. The controller's
  own `server.log` has zero mentions of "upgrade" anywhere. The only visible
  effect was internal: the device's MongoDB record's `device_upgraded` flag
  flipped to `true` with no corresponding wire traffic — the controller
  appears to silently no-op the upgrade dispatch for a device stuck in
  "Adopting" (never reaching "Connected") rather than queuing/sending it,
  consistent with the other device-targeted actions (Locate, RF scan) already
  known to be blocked by that same root issue.
- **Separately, found and fixed the *cause* of the "1 device has an update"
  offer in the first place:** the controller's own `autoupdate-check` log
  states plainly `firmware[U6IW] new version (6.8.2.15592) is available` —
  openUF's `openuf/ufmodel/u6iw.lua` `fw.ver` was still `"6.6.55"` (a stale
  placeholder), which is exactly the real current U6IW release firmware
  version independently confirmed via Ubiquiti's own firmware API during the
  Stage 2 firmware-analysis research (`U6IW v6.8.2+15592`). Updated `fw.ver`
  to `"6.8.2.15592"`; after restarting `inform.lua` with the change, the
  device's Mongo record correctly updated (`version: "U6IW.6.8.2.15592"`,
  `previous_firmware_version: "U6IW.6.6.55"`, confirming the controller
  registered a real version transition from the new inform, not a fluke).
  The sidebar "1 device has an update" banner didn't immediately clear after
  this — likely a stale client-side notification left over from the earlier
  manual "Update" click rather than a live re-evaluation; `upgradable` stayed
  `undefined` (not `true`) at the DB level throughout, so the underlying
  "needs update" condition does appear resolved.
- **Code changes:** `openuf/ufmodel/u6iw.lua` (`fw.ver`/`buildtime` updated to
  the real current release).

## 10. Forget device / factory reset

- **Status:** 🛑 blocked — requires a fully "Connected" device, see "wait_for_initial_inform: what actually flips it" below
- **Compare against:** `_type:"setdefault"` shape (`openuf/inform.lua:423-430`)
- **Findings:**
- **Code changes:**

## 11. fw.ver acceptance (passive)

- **Status:** ✅ answered 2026-07-12, as a side effect of the section 9 firmware
  investigation above (didn't need "Connected" state for this one — the
  device was still "Adopting" throughout).
- **Compare against:** does the current `openuf/ufmodel/u6iw.lua` `fw.ver` get
  accepted by the real controller, or rejected?
- **Findings:** Accepted, not rejected — any `fw.ver` string of this shape is
  simply stored as the device's reported `version` verbatim, no validation
  beyond that observed. The real finding wasn't acceptance/rejection but a
  *staleness* problem: the old placeholder `"6.6.55"` was old enough (versus
  the real current U6IW release, `6.8.2.15592`) that the controller's own
  `autoupdate-check` flagged it as needing an update — the spurious
  "1 device has an update" UI notification came directly from this, not from
  anything malformed. Bumping `fw.ver` to the real current version and
  restarting `inform.lua` was immediately reflected correctly in the
  device's Mongo record (`version`, `previous_firmware_version`), confirming
  live acceptance of an updated value with no rejection or side effects.
- **Code changes:** `openuf/ufmodel/u6iw.lua` (see section 9 above — same
  fix answers both).

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
