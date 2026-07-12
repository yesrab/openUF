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
findings below are confirmed. **The "stuck in Adopting" blocker is now RESOLVED**
(2026-07-12): the root cause was that the disposable Alpine AP container had no
AES-GCM backend, so openUF silently sent CBC informs, and this controller refuses
to provision a device until it receives a genuine GCM-encrypted inform. Fixed by
building `lua-openssl` into `tools/validation/ap/Dockerfile`. Once openUF sent
GCM, the live device immediately flipped `x_aes_gcm: true`, `cfgversion`
stabilised, `provisioned_at` was set, and `wait_for_initial_inform` cleared — the
device provisioned. See **"RESOLVED: AES-GCM is mandatory for adoption"** below
for the decompiled controller state machine that proves this. This was a
validation-tooling gap, **not an openUF product bug** — `install.sh` already
installs `lua-openssl` on real OpenWrt hardware. The per-scenario matrix
(sections 3–8, 10) is now unblocked.

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

**[RESOLVED 2026-07-12 — see "AES-GCM is mandatory for adoption" above. The cause
was CBC-instead-of-GCM informs, not anything in the four fixes below.]**

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

## RESOLVED: AES-GCM is mandatory for adoption — the real root cause (2026-07-12)

Everything below in "wait_for_initial_inform: what actually flips it" was
chasing a *symptom*. The actual blocker, found by fully decompiling the
controller's inform handler, is this: **on `unifi-network-application:10.4.57`,
the controller will not provision a device until it has received a genuine
AES-GCM-encrypted inform.** Our disposable AP container had no GCM backend, so
openUF silently downgraded to CBC every cycle, and the controller held the
device in a pre-provisioning loop forever.

### How it was found

`jadx` had silently dropped the one ~5,182-unit method that gates provisioning
(`com.ubnt.service.devmgr.l.MiVjHefaf.chgwykfBxZCAuEHPPQ(...c.KHUkYjHujLgFBD)`).
**CFR (`cfr.jar` 0.152) decompiled it cleanly** where jadx couldn't — a
different control-flow reconstruction engine, and the right tool once jadx gives
up on a large method. That recovered the full inform-handling state machine.

### The decompiled state machine (per-inform, `MiVjHefaf`)

- **Default-key inform** (unadopted, using the well-known default authkey
  `ba86f2bbe107c7c57eb5f2690775c712`): controller returns `setparam` with the
  adopt `mgmt_cfg`, and — unless the device is already in two-phase adoption —
  **sets `cfgversion` to a fresh random 16-hex value each time**
  (`kcUKRHuvLEpxrxxpLX.guoZiIiLhURleoJ("0123456789abcdef", 16)`). Logs
  `"Device adoption - initial mgmt_cfg sent"`.
- **First non-default inform**: logs `"Device[...] adoption - completed"`, sets
  `adoption_completed=true`. Handshake done — but this is *not* "Connected".
- **The provisioning gate** (the crux), roughly:
  ```java
  if (!(dev.isUnsupported() || dev.aesGcmInformEncryptionOnly() || <globalFlag>)) {
      // "dev[..] : mgmt config update before provision"
      resp = new setparam; resp.put("mgmt_cfg", ...);
      dev.set("cfgversion", <fresh random 16-hex>);   // <-- rolls every cycle
      return resp;                                     // <-- returns BEFORE provisioning
  }
  ```
  `aesGcmInformEncryptionOnly()` just returns the device-doc boolean
  `x_aes_gcm`. So while `x_aes_gcm` is false, **every** inform hits this branch,
  gets a brand-new random `cfgversion`, and returns early — never reaching the
  `cfgversion`-convergence provisioning, never reaching the
  `wait_for_initial_inform` clear (`if (isWaitingForInitialInform() &&
  !is("need_pre_provisioning", false)) set("wait_for_initial_inform", null)`).
  This is exactly the observed "fresh cfgversion every cycle, stuck at Adopting"
  behavior.
- **How `x_aes_gcm` flips true**: only in the inform *decrypt* path.
  `InformServlet` reads the packet's on-the-wire encryption flag
  (`header.isGcm()`) and passes a GCM-vs-CBC enum to the handler; on GCM the
  handler does `dev.set("x_aes_gcm", true)`. There is **no JSON/payload field**
  that sets it — the packet itself must be GCM-encrypted. `InformServlet` even
  rejects a GCM→CBC *downgrade* once `x_aes_gcm` is set
  (`"tried to downgrade inform encryption from AES-GCM to AES-CBC, rejecting"`).
  The controller always requests GCM: `config.GWoWvNEX` unconditionally writes
  `use_aes_gcm=true` into every `mgmt_cfg`.

### Why openUF was stuck

`openuf/inform.lua` `build_packet` sets `use_gcm = st.use_gcm and
crypto.gcm_available()`. In the Alpine AP container `crypto.gcm_available()` was
**false** — no `lua-openssl`, no `luacrypto`, and the `openssl(1)` CLI fallback
in `crypto.lua` cannot do GCM (`enc` refuses AEAD ciphers). So even though the
controller set `use_aes_gcm=true` (and `state.json` correctly flipped
`use_gcm=true`), openUF sent CBC every cycle. `x_aes_gcm` never flipped and the
provisioning gate looped forever. The earlier note that "GCM silently downgrades
to CBC ... nothing was lost" was wrong: on this controller the downgrade is the
entire blocker.

### The fix, and the live proof

Built the `zhaozg/lua-openssl` rock into `tools/validation/ap/Dockerfile`
(`luarocks-5.1 install openssl`, in a prunable `.build-deps` virtual group). No
prebuilt apk exists; the rock links `libssl3`/`libcrypto3` (already present).
`crypto.lua`'s existing GCM code (previously never executed) worked against this
binding with **no changes** — encrypt/decrypt round-trips, and the 40-byte AAD
is handled correctly. **No openUF product code change was needed.**

Verified live on the running device the instant openUF started sending GCM
(restarted `inform.lua` in the now-GCM-capable container):

```
x_aes_gcm:        false  ->  true
cfgversion:       (fresh every cycle)  ->  stable at 981163ecdabb1b8f
provisioned_at:   (absent)  ->  set
wait_for_initial_inform / need_pre_provisioning: cleared / absent
disconnected_at:  absent, last_seen current
```

**Re-confirmed 2026-07-12 on a fully from-scratch rebuild** (`docker compose down
-v` + `up -d --build` with the fixed Dockerfile baked in, fresh setup wizard,
fresh Inform Host Override + Device SSH Authentication, and — critically — no
leftover `/etc/openuf/state.json` on the AP side, so this was a genuine
never-before-seen device end to end, not the earlier manually-poked record).
L2/SSH adoption completed for real (`server.log`: `[sshCommand exec] Execute SSH
without host key verification!` then `Device[...] adoption - completed`), and
**the controller UI itself was read directly** (not inferred from Mongo) to
confirm this actually resolves the original complaint:

- Device list: green status dot, bucketed under **"Online (1)"** (not "Pending
  Adoption"/"Adopting").
- Device detail panel: **"U6 IW — Connected To -"**, with live TX Retries,
  uptime, and 60% memory usage streaming from real informs.
- Mongo device doc: `x_aes_gcm: true`, `adoption_completed: true`,
  `connected_at` set (a field the earlier contaminated device record never had
  at all), `provisioned_at` set, `cfgversion` stable across samples 10s apart,
  no `wait_for_initial_inform`/`need_pre_provisioning`, no `disconnected_at`.

This closes the loop the earlier verification pass had left open (Mongo doesn't
store the UI's computed `state` label, so that pass could only infer
"Connected" from side effects) — the literal UI status is now confirmed.

**Not an openUF product bug.** `install.sh` already installs `lua-openssl` in
its package list for real OpenWrt hardware (which has a prebuilt `lua-openssl`
feed), so genuine deployments already send GCM and would adopt cleanly. This was
purely a gap in the disposable validation container, whose Dockerfile even
acknowledged "no lua-openssl ... falls back to openssl CLI" but wrongly assumed
CBC was acceptable.

**Methodology note:** the `internal-dependencies.jar` was re-extracted from the
running controller and decompiled with both `jadx` (browsing) and **CFR**
(the large gated method). CFR is the key addition over prior sessions — it read
the method `jadx` had been silently dropping, which is what made the whole state
machine legible.

## wait_for_initial_inform: what actually flips it (SUPERSEDED — see the AES-GCM section above)

**This entire section is now superseded.** It correctly located *where* the flag
clears but never found *why* it wasn't clearing, because the real cause was one
layer up: the provisioning gate returned early (device sending CBC, `x_aes_gcm`
false) before execution ever reached the clear. With GCM sending, the gate
passes and the flag clears normally. Kept below for the investigation trail.

### wait_for_initial_inform: what actually flips it (original notes)

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

**Direct experiment: manually clearing the flag in Mongo does not change the
UI status.** On a freshly, cleanly adopted device (no prior restart
confound — `adopted: true`, `adoption_completed: true`, no `disconnected_at`),
ran `db.device.updateOne({mac:...}, {$unset: {wait_for_initial_inform: ""}})`
directly against the live Mongo instance while the controller kept running
(no restart). Confirmed via direct query that the field stayed absent through
at least one subsequent real inform cycle (`cfgversion` changed between
checks, proving the AP's informs were still landing) — yet the device's UI
status stayed on **"Adopting"**, unchanged. This is consistent with the
cache-then-DB-fallback pattern found in `SNMiFVJXxaonBOtqbJ`: the in-memory
"minidev" cache (keyed `("global","minidev",mac)`) is populated once on the
first DB hit and is never invalidated by an external write — so a live
controller process simply never observes a Mongo-only edit to an
already-cached device's record. Restarting the controller is the only way
found so far to force it to reload from Mongo.

**Restarting the controller to force a fresh read surfaces a second,
separate, reproducible artifact: the device flips to "Offline".** After
restarting just the controller process (container restart, not a full
environment rebuild) with the flag already cleared in Mongo beforehand, the
device's UI status became **"Offline"** — even though `last_seen` continued
updating to within ~15 seconds of "now" and `cfgversion` kept changing
(informs were actively landing, confirmed by direct Mongo query immediately
after the restart), and neither `disconnected_at` nor any other stale
timestamp field was present in the record. Ruled out a stale-browser-cache
explanation (hard-reloaded the page, same result). So "Offline" here isn't
derived purely from `last_seen` recency at request time — it appears to
depend on some other in-memory, per-connection session/handshake state that
a process restart wipes and that isn't being rebuilt just from ordinary
periodic informs landing. This reproduced identically to an earlier,
initially-dismissed observation from a previous restart during this same
investigation (previously assumed to be an unrelated one-off confound — it
is not; it's a deterministic side effect of restarting the controller
process on this device, independent of the `wait_for_initial_inform`
experiment).

**Net conclusion:** neither of the two most direct, practical levers
(editing Mongo live, or editing Mongo + restarting to force a cache reload)
actually got the device to "Connected" — the first because the running
process never re-reads the edit, the second because restarting introduces
its own distinct "Offline" state that ordinary informs don't seem to clear
either (not observed to self-heal within the observation window). Both
findings are new, concrete, and reproducible, but neither identifies the
actual clearing trigger. Confirms the earlier assessment: further progress
needs runtime instrumentation (JDWP attach, or jar-patched logging) rather
than more black-box experimentation, since black-box experimentation has now
been tried from two different angles and both dead-ended on
infrastructure-level side effects rather than answering the original
question.

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

- **Status:** 🛑 blocked — **new root cause found 2026-07-12** (device is now
  Connected, so this is no longer blocked by adoption; it's blocked by a
  separate, environmental limitation of the validation container — see
  "RESOLVED-ish: no radios reported, environmental not a code bug" below).
- **Compare against:** `vap_table` field names (`openuf/ucihelper.lua` `apply_config()`)
- **Findings:** created a real WiFi network ("openuf-test", Native Network,
  broadcasting to "All APs") in the controller UI. The controller's pushed
  `setparam` response contains a `system_cfg` blob (not `vap_table` JSON —
  see below) with the literal line `# no wlan provisioned as no radio found` /
  `radio.status=disabled` — the controller refuses to provision any SSID onto
  this device because it believes the device has **zero physical radios**.
  Root-caused: this disposable Alpine AP container has no `uci` binary/Lua
  binding at all (`apk search uci` returns nothing), so
  `openuf/inform.lua:334`'s `pcall(ufuci.get_radio_table)` always fails and
  `radio_table` stays permanently `{}` (its default at `inform.lua:322`) in
  every inform this container ever sends. Confirmed via `debug_dump_file`
  that our own `radio_table` field really is present-but-empty (not
  absent) — matching the controller's own "Missing radio_table" check
  (`list3.isEmpty()`, decompiled, see below). **Real target hardware (WDR3500
  / Archer C5 v1, genuine OpenWrt) has actual UCI with real `wifi-device`
  sections and would not hit this** — this is a validation-*environment* gap,
  not an openUF code bug. Testing this scenario for real would need either
  building a `uci` Lua binding for Alpine (much larger effort than the
  `lua-openssl` rock — `uci`/`libuci` is OpenWrt-specific, not in Alpine's
  repos) or stubbing a fake `/etc/config/wireless` + a `uci`-compatible mock
  module.
- **Code changes:** none in this pass (environmental, not fixable in
  `openuf/`) — `radio_table`'s empty-on-error fallback is itself correct
  defensive behavior, not the bug.

## 4. VLAN-tagged network + SSID assignment

- **Status:** 🛑 blocked — same root cause as section 3 (no radios reported by
  this validation container; the controller won't push any WLAN config,
  VLAN-tagged or not, onto a device it believes has zero radios).
- **Compare against:** `network_table`/`networkconf_id` join shape
  (`openuf/ucihelper.lua`)
- **Findings:** not independently re-attempted — section 3 already
  demonstrates the blocking condition applies before VLAN-specific logic is
  ever reached.
- **Code changes:**

## 5. Fast Roaming / WPA3 fast roaming toggle

- **Status:** 🛑 blocked — same root cause as section 3.
- **Compare against:** presence/absence and real field name of
  `mobility_domain`/`r0kh`/`r1kh`/`fast_roaming_enabled`
  (`openuf/ucihelper.lua` `derive_mobility_domain` stopgap)
- **Findings:**
- **Code changes:**

## 6. TX power (Low/Medium/High/Custom) per radio

- **Status:** 🛑 blocked — same root cause as section 3 (no radios reported,
  so there's no per-radio config surface for the controller to push TX power
  onto).
- **Compare against:** `radio_table` field name/value shape
  (`openuf/ucihelper.lua` `rf_config()`)
- **Findings:**
- **Code changes:**

## 7. Locate trigger

- **Status:** ✅ captured (real, via `debug_dump_file`) — 2026-07-12, first
  scenario re-run against the now-Connected device.
- **Compare against:** exact `cmd` string(s) (`openuf/inform.lua:455-460`)
- **Findings:** clicked "Locate" for real in the controller UI. Real captured
  payload:
  ```json
  {"_type":"cmd","cmd":"set-locate","device_id":"...","time":...,"datetime":"...","_id":"...","server_time_in_utc":"..."}
  ```
  Confirms `cmd:"set-locate"` (not e.g. `"locate"` or `"identify"`) is the
  real trigger string, matching `openuf/inform.lua`'s existing `cmd ==
  "set-locate"` branch exactly — no code change needed. `inform.lua` logged
  `cmd: set-locate`, and `state.json` correctly picked up `"locating":true`.
  Also confirms the `cmd` branch's "always re-inform immediately" fix (see
  the fxkr cross-check finding above): the controller's next response
  (`noop`) landed in the same second as the `cmd` response, proving the
  immediate re-inform after executing a command works. On this hardware-less
  validation container `dev.conf.led` is `nil` (no real LED, only the real
  target hardware's modelmap sets a real sysfs path), so
  `led.locate_start(nil)` correctly no-ops per its own unit test — the LED
  *hardware* interaction itself needs re-verification on real target
  hardware, but the wire protocol and state-tracking are now fully confirmed.
- **Code changes:** none — existing implementation confirmed correct.

## 8. RF/spectrum scan trigger (trigger only)

- **Status:** 🛑 blocked — same root cause as section 3. The controller's
  RF-scan trigger lives under a per-radio UI control that never renders at
  all for a device it believes has zero radios (no "Radios" panel appears
  anywhere in this device's Overview/Settings while `radio_table` is empty).
- **Compare against:** exact `cmd` string for the scan trigger
  (`openuf/inform.lua:461-478`)
- **Note:** result-reporting (AP→controller direction) is out of scope for this
  stage — see Stage 2b findings elsewhere in this doc.
- **Findings:**
- **Code changes:**

## RESOLVED-ish: no radios reported — environmental, not a code bug (2026-07-12)

Root cause for sections 3-6 and 8 all being blocked, and (very likely) a
contributing factor to the CPU/stats-history investigation below. Confirmed
via direct capture and code inspection, not guesswork:

- The controller's pushed `setparam` response, captured live via
  `debug_dump_file` after creating a real WiFi network and assigning it to
  this AP, contains a `system_cfg` blob with the literal comment
  `# no wlan provisioned as no radio found` and `radio.status=disabled`.
- `openuf/inform.lua:322-334`: `radio_table` defaults to `{}` and is only
  populated via `pcall(ufuci.get_radio_table)`. `openuf/ucihelper.lua`'s
  `get_radio_table()` calls `require("uci")` and iterates real
  `wifi-device` UCI sections — both genuinely absent on this validation
  container (`apk search uci` returns nothing; no `/etc/config/` directory
  exists at all). The `pcall` correctly swallows the resulting error and
  `radio_table` stays `{}` — this is defensively-correct behavior, not a bug,
  but it means **every inform this container has ever sent has an empty
  `radio_table`**.
- Decompiled the controller's own check (`internal-dependencies.jar`, CFR):
  `com.ubnt.service.devmgr.tFhABnrHYJqvjaoEa` (and a near-duplicate,
  `PGOcbDWlbnYQdFW`) reads `list3 = ekfCWfaSnrqscUb2.getList("radio_table")`
  and does `if (list3.isEmpty()) { ... "Missing radio_table in inform..." }`
  — confirms the controller received our `radio_table` field fine, it's just
  empty, and that's exactly the "no radio found" condition.
- **Real target hardware (WDR3500 / Archer C5 v1, genuine OpenWrt) has actual
  UCI with real `wifi-device` sections populated by the wireless driver at
  boot, independent of any configured SSID** — this whole class of blockage
  is specific to this disposable Alpine validation container, not something
  real deployments would hit. Porting a working `uci`/`libuci` Lua binding to
  Alpine (unlike `lua-openssl`, not available as any Alpine package, and not
  a generic luarocks package either — it's OpenWrt-specific) or hand-stubbing
  a fake UCI config tree would be needed to test sections 3-6 and 8 for real
  in this environment; out of scope for this pass.

## CPU/memory stats history investigation (2026-07-12)

The controller UI's Insights → Stats → "System Utilization" chart was
completely empty (no data series at all, not just a flat 0% line) despite
1+ day of continuous informs. `openuf/sysinfo.lua`'s `cpu_percent()` and
`openuf/inform.lua`'s `system-stats.cpu`/`mem`/`uptime` construction were
re-read and confirmed correct (delta-sampling `/proc/stat`, correctly wired
into `build_json`) — this is not a `build_json` bug. Investigated further via
direct MongoDB inspection and CFR decompilation of
`internal-dependencies.jar`:

- **`db.stat.count()` is `0` for the entire database** — not just this
  device. This is the controller's own historical time-series collection
  that backs the Insights charts.
- Decompiled the controller's inform-time stats-recording path
  (`com.ubnt.service.devmgr.tFhABnrHYJqvjaoEa` calling into
  `com.ubnt.service.system.QDcGUYAmLvJwylXw`, which reads `system-stats.cpu`/
  `mem` at several points across different device-type branches). Traced the
  call site (`tFhABnrHYJqvjaoEa.java:1689`) that appears to cover our
  device's case: it sits **unconditionally after** the `hasRadio("na")`
  if/else block (not nested inside it), gated only by `inMeshMode`/
  `inManagedShadowGatewayMode` — both false for a plain, non-mesh,
  non-shadow-gateway device. This means the empty `radio_table` finding above
  does **not** appear to gate this particular cpu/mem-recording call, unlike
  `radio_table_stats` (which genuinely is skipped when `radio_table` is
  empty, per the earlier "Missing radio_table" trace) — the two are separate
  code paths.
- Given the write call itself appears reachable, but zero documents exist in
  `stat` **anywhere in the database**, this looks like a missing/disabled
  background flush job in this specific minimal Docker deployment, not
  something gated by what any individual device reports. Consistent with
  other already-documented background-service gaps in this same environment
  (the `127.0.0.1:9080/api/ucore/manifest` connection-refused error, the
  `get-ulp-manifest` fetch failures — both present regardless of device
  activity, both pre-existing/known-harmless per earlier sessions).
- **Not fully conclusive** — this is as far as static bytecode tracing
  reasonably goes without runtime instrumentation (matching the same limit
  reached during the original `wait_for_initial_inform` investigation).
  The proximate cause (empty `stat` collection database-wide) is solid,
  directly-queried fact; the *reason* the flush job isn't running is
  inferred, not proven. No evidence was found implicating openUF's own
  output.
- **Bonus finding, relevant to future Power/PoE work**: the same decompiled
  method (`tFhABnrHYJqvjaoEa.java:1405`) copies these fields from the raw
  inform directly onto the device doc if present: `power_source`,
  `power_source_voltage`, `psu_table`, `power-monitor`, `total_max_power`,
  `led_state`, `outlet_table` — confirming at least some power/PoE reporting
  is genuinely self-reported by the device in its own inform, not solely
  derived from an upstream PoE switch. See the Power/PoE section below.

**Conclusion: not an openUF bug.** No code change made. If this needs to be
proven conclusively, the next step would be JDWP runtime attach (as
previously scoped but not needed for the AES-GCM investigation) to watch
whether the stats-flush actually executes and where it stops, rather than
further static tracing.

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

- **Status:** ✅ captured (real, via `debug_dump_file` + independent `tcpdump`
  wire capture) — **re-attempted 2026-07-12 on the now-Connected device** (see
  "AES-GCM is mandatory for adoption" above). The original 2026-07-12 attempt
  below (before the GCM fix) was correctly diagnosed as blocked by the same
  root cause as everything else in this matrix — confirmed here, since the
  identical action now produces a full real payload once the device is
  actually Connected. **The "intentional force-reinstall affordance" theory
  further below is WRONG and superseded — see "RESOLVED: wrong `version`
  field format" immediately below, found the same session by digging further
  at the user's prompting ("I'm suspecting we're reporting the FW version
  wrong").**

### RESOLVED: outbound `version` field was wrongly model-prefixed

Root cause of the *persistent* "1 device has an update" / "Update Available"
banner (independent of the GCM/adoption blocker above — this one reproduces
even on a fully Connected, fully up-to-date-firmware device). Decompiled
`com.ubnt.service.devmgr.l.MiVjHefaf`'s upgrade-offer gate (CFR, same method as
the AES-GCM investigation) and `com.ubnt.service.aF.AcrQJeJCScLn` (the
controller's internal `ProductInfo`/firmware-catalog DTO, confirmed via its
`toString()`):

```java
private boolean chgwykfBxZCAuEHPPQ(String string, String string2) {
    return this.TgovGTpPRqBiOa(string) && !StringUtils.equals(string, string2);
}
// called as: chgwykfBxZCAuEHPPQ(object3, string)
//   object3 = acrQJeJCScLn.ZpkRBEhhrxi()   -- ProductInfo.version, e.g. "6.8.2.15592" (bare)
//   string  = ekfCWfaSnrqscUb2.getString("version")  -- the inform's raw "version" field
```

This is a **strict, unnormalized `StringUtils.equals`** — no prefix-stripping,
no numeric parsing. Confirmed the catalog's `version` field is bare (no model
prefix) via an independent second usage of the exact same `ProductInfo` DTO in
`com.ubnt.service.af.VVyiC` (the `autoupdate-check` startup log,
`"firmware[{}] new version ({}) is available"`, which literally logged
`firmware[U6IW] new version (6.8.2.15592) is available` — no `"U6IW."`
anywhere). Meanwhile `openuf/inform.lua`'s `build_json` was sending:
```lua
version = (uap.fw and uap.fw.pre or "U6IW.") .. (uap.fw and uap.fw.ver or "6.6.55")
-- => "U6IW.6.8.2.15592"
```
`"U6IW.6.8.2.15592" != "6.8.2.15592"` under strict string equality — **so the
upgrade-offer gate opens regardless of whether the numeric firmware version
genuinely matches the catalog**, since the comparison never had a chance to
pass. This is a real, permanent openUF bug, not intentional controller
behavior; the earlier "force reinstall affordance" read on the confirmation
dialog text ("Update U6 IW from 6.8.2 to 6.8.2?") was a red herring — the UI
truncates to 3 version components, hiding that the two full strings never
matched underneath.

**Fix (`openuf/inform.lua`):** stop reusing `fw.pre` for the inform JSON's
`version` field — send the bare `uap.fw.ver` only. `fw.pre` (`"U6IW."`) is
still correct and untouched where it's actually used:
`openuf/announce.lua`'s L2 discovery "firmware version verbose" TLV field, a
different protocol surface with no evidence it's wrong. Updated
`tests/test_inform_json.lua`'s assertion (it had been asserting the *buggy*
prefixed behavior as correct).

**Verified live, twice:**
1. Live-patched the running (already-adopted) container's `fw.pre` to `""`
   and restarted `inform.lua` — device flipped from "Update Available" to
   **"Up to date"** in the UI within one inform cycle, `server.log`'s
   `inform_stat` lines showed the bare `version - 6.8.2.15592;`, and Mongo's
   `device.version` updated to the bare string. Reverted the hack afterward
   (it also would have wrongly changed `announce.lua`'s field).
2. Applied the real fix to `openuf/inform.lua`, rebuilt the AP image from
   scratch, and adopted a **brand-new device from a clean SSH handshake**
   (`ea:ac:9a:98:37:92`) — it went straight to **"Up to date"** on first
   adoption, never showing "Update Available" at all. Confirms the fix, not
   just the hack, and confirms it holds from a genuinely first-contact device.

**Code changes:** `openuf/inform.lua` (`version` field no longer prefixed),
`tests/test_inform_json.lua` (assertion corrected to expect the bare version).
- **Compare against:** `_type:"upgrade"` shape, `version`/`url` field names
  (`openuf/inform.lua:438-448`)
- **Findings (re-run against a Connected device):** started `tcpdump` on the AP
  container's inform port (8080) plus the existing `debug_dump_file` capture,
  then clicked "Update" for real in the controller UI (confirmed the "Update
  U6 IW from 6.8.2 to 6.8.2?" dialog — the truncated UI version string hides
  that this is a full-build reassert of the catalog firmware, not a
  no-op). **This time a real command was queued and delivered:**
  ```json
  {"_type":"upgrade","version":"6.8.2.15592","md5sum":"0fec04452cadd2d025777d36ab2974ea","url":"http://fw-download.ubnt.com/data/unifi-firmware/6bbe-U6IW-6.8.2-4640c65b-3bb0-4844-943b-b2103ecd4bf9.bin","server_time_in_utc":"1783859283572"}
  ```
  `server.log` logged it plainly: `Device U6IW[...] will be upgraded to
  version: 6.8.2.15592, scheduled: [false], rolling: [false], external:
  [false], wanAdoptedUmbb: [false]`. **Independent wire-level cross-check**:
  the `tcpdump` capture shows this specific response was **423 bytes**, vs. the
  steady ~293-byte responses for ordinary `noop`/`setparam` cycles immediately
  before and after — confirms a real, larger payload hit the wire, not just a
  client-side log artifact (same cross-validation principle as the earlier raw
  TCP relay work, this time via a real packet capture on the container's own
  interface). **Notable independent confirmation**: the pushed `md5sum` and
  firmware filename are byte-for-byte identical to the genuine Ubiquiti
  artifact pulled directly from `fw-update.ubnt.com` during the unrelated
  Stage 2 firmware-analysis research above — the controller's real firmware
  catalog matches Ubiquiti's real CDN, not a stub.
  The controller sent this exactly once (fire-and-forget) and returned to
  normal `noop`/`setparam` cycling — it does not retry or wait for
  confirmation; it's up to the device to eventually self-report a new
  `version` in a later inform.
- **openUF's safety mechanism verified working as designed**: `inform.lua`'s
  `upgrade` handler (`openuf/inform.lua`, `_type == "upgrade"` branch) never
  downloads/verifies/flashes/reboots — it only stores `upgrade_requested_version`
  / `upgrade_requested_url` in `state.json` and logs `"upgrade requested
  (version=...) -- stored only, not applying"`. Confirmed live:
  `state.json` picked up the exact real version/URL from the captured payload,
  no other side effects, and the device stayed genuinely Connected in the UI
  throughout and after (progress bar reverted to a plain "Update" button once
  the controller stopped waiting). No code change needed — this is the design
  amd989/unifi-gateway also uses (log + store, no real upgrade path), now
  proven correct against a real controller-issued command.
- **Separately, found and fixed the *cause* of the "1 device has an update"
  offer in the first place (original 2026-07-12 finding, unchanged):** the
  controller's own `autoupdate-check` log states plainly `firmware[U6IW] new
  version (6.8.2.15592) is available` — openUF's `openuf/ufmodel/u6iw.lua`
  `fw.ver` was still `"6.6.55"` (a stale placeholder), which is exactly the
  real current U6IW release firmware version independently confirmed via
  Ubiquiti's own firmware API during the Stage 2 firmware-analysis research
  (`U6IW v6.8.2+15592`). Updated `fw.ver` to `"6.8.2.15592"`. **Correction:**
  this alone did *not* fully resolve it — the banner persisted even with the
  numerically-correct version, which turned out to be a second, independent
  bug (the `version` field's wrongful `"U6IW."` model prefix — see "RESOLVED:
  outbound `version` field was wrongly model-prefixed" above). The
  "intentional force-reinstall affordance" read on the confirmation dialog
  ("from 6.8.2 to 6.8.2") was wrong — that truncated UI text was masking a
  real full-string mismatch (`"U6IW.6.8.2.15592"` vs `"6.8.2.15592"`), not an
  intentional reinstall-regardless-of-version control.
- **Code changes:** `openuf/ufmodel/u6iw.lua` (`fw.ver`/`buildtime` updated to
  the real current release) **and** `openuf/inform.lua` (`version` field
  de-prefixed — see "RESOLVED" section above for the actual fix that made
  "Up to date" appear). The `_type:"upgrade"` handler itself needed no
  changes — see the safety-mechanism verification above.

## 10. Forget device / factory reset

- **Status:** ⚠️ attempted 2026-07-12 (real click via UI) — **the controller
  never actually dispatched a `_type:"setdefault"` wire command in this test**,
  so `openuf/inform.lua`'s handler itself remains unverified against a live
  controller-issued command, though the admin-facing UI action and
  server-side deletion do work.
- **Compare against:** `_type:"setdefault"` shape (`openuf/inform.lua:423-430`)
- **Findings:** clicked "Remove" for real in the controller UI (confirmed the
  real "The device will be restored to factory settings..." dialog) against
  the Connected device. Result: the UI correctly flipped the device back to
  "1 device is ready to adopt" (i.e. the controller genuinely deleted/reset
  the device record server-side), but `debug_dump_file` captured **no**
  `_type:"setdefault"` payload — only continuing `noop` responses — and
  `state.json` still showed `adopted:true` with the *old* authkey afterward,
  meaning openUF's own client-side state was never told to reset. `server.log`
  has zero log lines mentioning forget/remove/setdefault for this device's MAC
  around the removal timestamp either. This is consistent with the same
  in-memory device-cache staleness documented in "wait_for_initial_inform:
  what actually flips it" above (`SNMiFVJXxaonBOtqbJ`'s cache-then-DB-fallback
  device lookup, populated once and never invalidated by an external write) —
  informs kept decrypting successfully post-"removal" purely from a stale
  cache entry, while the underlying Mongo doc was already gone and a fresh
  "pending adoption" entry existed for the same MAC. Whether a real
  `setdefault` command is sent under different circumstances (e.g. only via
  SSH for L2-discovered devices, mirroring how initial adopt differs between
  L2/SSH and L3/mgmt_cfg) is unconfirmed — not re-tested this pass.
- **Code changes:** none — `openuf/inform.lua`'s `setdefault` handler is
  unverified but no evidence found that it's wrong; the controller's own
  dispatch behavior is the open question here, not the client code.

## 11. fw.ver acceptance (passive)

- **Status:** ✅ answered 2026-07-12, as a side effect of the section 9 firmware
  investigation above (didn't need "Connected" state for this one — the
  device was still "Adopting" throughout).
- **Compare against:** does the current `openuf/ufmodel/u6iw.lua` `fw.ver` get
  accepted by the real controller, or rejected?
- **Findings:** Accepted, not rejected — any `fw.ver` string of this shape is
  simply stored as the device's reported `version` verbatim, no validation
  beyond that observed. The staleness half of the finding stands (the old
  placeholder `"6.6.55"` was genuinely old versus the real current U6IW
  release, `6.8.2.15592`), but bumping `fw.ver` alone did **not** fully clear
  the spurious "1 device has an update" notification, as this section
  originally concluded — see section 9's "RESOLVED: outbound `version` field
  was wrongly model-prefixed" for the second, independent bug (a `"U6IW."`
  prefix defeating the controller's strict string-equality catalog check)
  that was the actual full cause.
- **Code changes:** `openuf/ufmodel/u6iw.lua` and `openuf/inform.lua` (see
  section 9 above — same investigation answers both).

## 12. Restart / reboot

- **Status:** ✅ captured (real, via `debug_dump_file`) — 2026-07-12, live-fired
  for real against a freshly, cleanly adopted device.
- **Compare against:** wire form ambiguity — top-level `_type:"reboot"`
  (`openuf/inform.lua:601-605`, implemented) vs. `{"_type":"cmd","cmd":"restart"}`
  (explicitly a no-op today, `openuf/inform.lua:681`).
- **Findings:** clicked "Restart" for real in the controller UI (confirmed
  the real "Devices cannot be managed while they restart..." tooltip and
  "Restart U6 IW? Are you sure..." confirmation dialog first). Real captured
  payload:
  ```json
  {"_type":"reboot","reboot_type":"soft","device_id":"...","time":...,"datetime":"...","_id":"...","server_time_in_utc":"..."}
  ```
  **Confirms the top-level `_type:"reboot"` form is correct** — the
  `cmd:"restart"` no-op branch was never the relevant path for this action;
  no code change needed, `openuf/inform.lua`'s existing handler already
  matches exactly. `reboot_type:"soft"` is a field openUF doesn't currently
  read or need to. The handler's `os.execute("reboot"); os.exit(0)` had a
  real, complete effect in this environment: the entire AP **container**
  exited (clean exit code 0, not a crash) — Alpine's `reboot` genuinely
  invoked a system reboot inside the container's namespace, and with no
  init/supervisor to survive it, the whole container went down, exactly the
  destructive-but-correct behavior expected of a real device reboot. Recovered
  the capture by `docker start`ing the stopped (not removed) container
  afterward — the filesystem/log survived intact.
- **Code changes:** none — existing implementation confirmed correct.

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
