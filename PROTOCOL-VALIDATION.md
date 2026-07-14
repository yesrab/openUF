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

**2026-07-12, second pass — remaining UI-surfaced functionality verified.**
With the device genuinely Connected, worked through every remaining
controller-UI control: **Locate** (✅ confirmed, section 7), **Firmware
upgrade** (✅ confirmed, section 9), **Restart** (✅ confirmed, section 12,
`_type:"reboot"` — real container reboot observed), **Manage LED** (✅ real
gap found and fixed, section 13), **IP Settings/Static IP** (✅ real gap
found and fixed end-to-end including a live-fired regression, section 14).
Root-caused (via CFR decompile again) why SSID push/TX power/RF-scan/VLAN
(sections 3–6, 8) and the CPU/mem stats history graph are still blocked:
this disposable Alpine validation container has no real `uci` binding at
all, so `radio_table` is always empty — a validation-*environment* gap
(real OpenWrt hardware has genuine UCI), not an openUF code bug — see
"RESOLVED-ish: no radios reported" and the CPU-stats section below. Power/
PoE (section 15) scoped and concluded environmental (no parent PoE switch
in this setup). "Forget device" (section 10) partially confirmed — the
controller doesn't appear to dispatch a live `setdefault` command in this
environment, cache-staleness artifact, matching the earlier
`wait_for_initial_inform` findings.

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

- **Status:** ✅ confirmed working end-to-end 2026-07-12, against a real
  controller, after fixing three real bugs this exact test surfaced (see
  the three commits/sections below: the missing radio `band` field, the
  `system_cfg`-not-`vap_table` wire format, and the SSID-collision section
  naming). Previously blocked purely by the validation container having no
  real `uci` binding at all (see "RESOLVED: hand-stubbed a UCI mock" above)
  — now unblocked by the hand-stubbed `uci-mock.lua`.
- **Compare against:** originally assumed `vap_table` JSON field names
  (`openuf/ucihelper.lua` `apply_config()`) — **wrong assumption**, see
  next bullet.
- **Findings:** created a real WiFi network ("openuf-test", Native Network,
  broadcasting to "All APs", both 2.4GHz+5GHz radio bands) in the
  controller UI. Two real, previously-invisible bugs found and fixed:
  1. The controller's pushed `setparam` response carries the WiFi
     config entirely inside the flat `system_cfg` UCI-style blob
     (`aaa.<n>.ssid`, `aaa.<n>.wpa`, `aaa.<n>.wpa.psk`,
     `wireless.<n>.parent`, `radio.<n>.phyname`, etc.) — **a real
     controller never sends `resp.vap_table`/`radio_table`/`network_table`
     as JSON at all**, so `ucihelper.apply_config()` (gated on
     `resp.network_table`) never actually ran in practice despite being
     fully unit-tested. Fixed: added `inform.lua`'s
     `M._parse_wifi_system_cfg()` to translate the flat blob into the
     shape `apply_config()` already expects, reusing its existing
     VLAN-join/fast-roaming logic unchanged.
  2. Broadcasting one SSID on both radios (the default) calls
     `ucihelper.wlan_add()` twice with an identical `ssid` — UCI section
     names keyed purely by SSID collapsed both calls into one section, so
     the second radio's `wlan_add()` silently overwrote the first. Fixed:
     section names now include the radio (`openuf_<radio>_<ssid>`).
  Verified live via a debug-only commit hook added to
  `tools/validation/ap/uci-mock.lua` (dumps mock state to a file, since a
  fresh `lua -e` script can't see the long-running `inform.lua` process's
  own in-memory mock instance) — confirmed both
  `openuf_radio0_openuf-test` and `openuf_radio1_openuf-test` sections
  exist independently, each with the correct `ssid`/`encryption: psk2`/
  `key`/`device`.
- **Code changes:** `openuf/inform.lua` (`M._parse_wifi_system_cfg`, wired
  into the `setparam` handler), `openuf/ucihelper.lua` (radio-scoped
  section naming in `wlan_add`), `tools/validation/ap/uci-mock.lua`
  (debug dump-on-commit, validation-only). Unit tests added for both
  fixes.

## 4. VLAN-tagged network + SSID assignment

- **Status:** ✅ confirmed working end-to-end 2026-07-12, against a real
  controller.
- **Compare against:** originally assumed a `network_table`/`networkconf_id`
  join shape (`openuf/ucihelper.lua`) — **wrong assumption**, see below (the
  real wire format has no such join at all).
- **Findings:** created a VLAN-tagged network ("openuf-vlan20", VLAN id 20)
  in Settings → Networks, then reassigned the existing "openuf-test" WiFi
  network from "Native Network" to it. There is **no `network_table`/
  `networkconf_id` join in the real wire format** — the real controller
  signals VLAN tagging purely by changing `aaa.<n>.br.devname` from `"br0"`
  to `"br0.<vlan>"` (e.g. `br0.20`), and adds companion `vlan.*`
  (`vlan.1.devname=eth0`, `vlan.1.id=20`), `bridge.*` (a new `br0.20`
  bridge with the WiFi interfaces as members), and `netconf.*` blocks
  declaring the VLAN subinterface — all of which openUF doesn't need to
  reproduce, since real hardware's own OpenWrt network stack (not openUF)
  would set those up from the UCI `network`/`wireless` config `ucihelper`
  already writes. Fixed: `M._parse_wifi_system_cfg()` extracts the VLAN id
  from the `br0.<vlan>` suffix and sets `vlan_enabled`/`vlan` on the parsed
  vap, so `apply_config()`'s existing (already correct, already
  unit-tested) `ensure_vlan_network()` join picks it up unchanged. Verified
  live via the debug commit-hook dump: both radios' `openuf_radio<N>_
  openuf-test` sections show `network: "openuf_vlan20"`, and a matching
  `openuf_vlan20` interface section exists with `ifname: "eth0.20"`.
- **Code changes:** `openuf/inform.lua` (`M._parse_wifi_system_cfg`'s VLAN
  id extraction). Unit test added.

## 5. Fast Roaming / WPA3 fast roaming toggle

- **Status:** ✅ confirmed working end-to-end 2026-07-12, against a real
  controller — **no code changes needed**, section 3's `system_cfg` parser
  already handled it correctly.
- **Compare against:** presence/absence and real field name of
  `mobility_domain`/`r0kh`/`r1kh`/`fast_roaming_enabled`
  (`openuf/ucihelper.lua` `derive_mobility_domain` stopgap)
- **Findings:** enabled "Fast Roaming (802.11r)" on the "openuf-test" WiFi
  network (only reachable via the Advanced panel's "Manual" mode — greyed
  out under "Auto"). Confirms `ucihelper.lua`'s existing design assumption
  exactly: the real controller sends **only** `aaa.<n>.ft.status=enabled`
  — no `mobility_domain`, `r0kh`, or `r1kh` field anywhere in `system_cfg`,
  matching the code comment that "UniFi's admin API has no such fields --
  it computes and syncs them internally across all APs on a site."
  `M._parse_wifi_system_cfg()` (added for section 3) already reads
  `ft.status` into `vap.fast_roaming_enabled`, and `apply_config()`'s
  existing `derive_mobility_domain()` stopgap took it from there. Verified
  live via the debug commit-hook dump: both radio sections show
  `ieee80211r: "1"`, `mobility_domain: "dcc4"` (same value on both,
  confirming the derivation is stable per-SSID as designed),
  `ft_psk_generate_local: "1"`, `ft_over_ds: "0"`.
- **Code changes:** none — already correct from section 3's fix.

## 6. TX power (Low/Medium/High/Custom) per radio

- **Status:** ✅ confirmed working end-to-end 2026-07-12, against a real
  controller — **no code changes needed**, section 3's `system_cfg` parser
  already handled it correctly.
- **Compare against:** `radio_table` field name/value shape
  (`openuf/ucihelper.lua` `rf_config()`)
- **Findings:** in the device's Settings → Radios panel, set the 2.4GHz
  radio's channel to `6` (was Auto) and Transmit Power to Custom `15 dBm`
  (was Auto). The pushed `system_cfg` carries this as plain
  `radio.1.channel=6`/`radio.1.txpower=15`/`radio.1.txpower_mode=custom` —
  already handled by `M._parse_wifi_system_cfg()`'s existing
  `tonumber(r.channel)`/`tonumber(r.txpower)` parsing (added for section 3,
  before any live TX-power-specific data existed to confirm the "auto"
  case against). Verified live via the debug commit-hook dump: the mock's
  `radio0` section shows `channel: "6"`, `txpower: "15"` (updated from the
  prior default `20`).
- **Code changes:** none — already correct from section 3's fix.

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

- **Status:** ⚠️ inconclusive 2026-07-12 — the original blocker (empty
  `radio_table`) is resolved (see the UCI mock section above), but **no
  manual on-demand RF-scan trigger control was found anywhere in this
  controller version's UI** (10.4.57), so the trigger itself was never
  fired live.
- **Compare against:** exact `cmd` string for the scan trigger
  (`openuf/inform.lua:461-478`)
- **Note:** result-reporting (AP→controller direction) is out of scope for this
  stage — see Stage 2b findings elsewhere in this doc.
- **Findings:** searched thoroughly with a live, fully-adopted, Connected
  device: the device's own Settings → Manage panel has Locate/Restart/
  Disable/Remove but no scan action; the top-level **AirView** page (which
  now shows real, non-empty per-radio data once the UCI mock made
  `radio_table` non-empty — e.g. its "Radios" tab correctly lists this
  device's live channel/6/15dBm settings from section 6's test) has three
  tabs (Radios, Connectivity, Environment) and a "Radio Settings" side
  panel, but none of them expose a "scan now"/"run RF scan" button —
  every chart is populated passively from ongoing stats, not from a
  one-shot trigger. Settings search for "spectrum" returns no results.
  Waited ~2 minutes with AirView open to see whether the controller issues
  a `cmd`-type inform on its own (continuous background monitoring
  triggering a scan without a manual click) — zero `_type:"cmd"` responses
  arrived in that window. This suggests that in this controller version,
  spectrum/RF visibility is delivered entirely through passive,
  continuously-collected stats (`radio_table_stats`, channel utilization)
  rather than an admin-triggered one-shot scan command — plausibly a UI/
  workflow change since whatever version the original `cmd:"spectrum-scan"`
  UI affordance this doc's compare-against target was based on. Not
  conclusive either way without decompiling the controller's own AirView
  data-source logic (out of scope for this pass) — documenting as an open
  question rather than guessing.
- **Code changes:** none — `openuf/inform.lua`'s existing
  `cmd:"spectrum-scan"` dispatch (already unit-tested per earlier stages of
  this project) remains unverified against a live controller-issued
  command, but nothing found here contradicts its correctness.

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

## RESOLVED: hand-stubbed a UCI mock, and it immediately found a real bug (2026-07-12)

The "out of scope for this pass" note above was revisited: hand-stubbing a
fake UCI config tree turned out to be cheap (`ucihelper.lua` already has an
`M._uci` injection seam built for unit tests, and the exact same in-memory
cursor mock from `tests/test_ucihelper.lua`'s `new_mock_uci()` just needed
exposing as a real requirable module). Added
`tools/validation/ap/uci-mock.lua`, installed at
`/usr/local/share/lua/5.1/uci.lua` in the validation-only AP image (not part
of openUF proper — `ucihelper.lua`'s product code is untouched), seeded with
two `wifi-device` sections (`radio0`/`radio1`) matching
`generic-dualband-ap.lua`'s `hwassign`. `get_radio_table()` immediately
returned real, non-empty entries.

This unblocked sections 3-6 and 8 as intended, but also **found a real
openUF bug that had been completely invisible until this exact moment**:
every single inform after `radio_table` went non-empty caused the real
controller to throw `java.lang.NullPointerException: Cannot invoke
"String.toLowerCase()" because "<parameter1>" is null` inside
`InformServlet` → `MiVjHefaf` (devmgr adopt processing) →
`eWivisHeQsnaqDtx` (config service), on every single inform cycle. Live
symptom: the device would reach `adopted:true` in Mongo (`last_seen`
genuinely advancing) but the Devices list UI would show "No UniFi Devices
Have Been Adopted" and Settings → WiFi would refuse to apply config
("requires a UniFi Access Point to be adopted") — the exception was
corrupting the controller's adopt/UI-facing device cache on every cycle,
not the persistent Mongo doc.

Root-caused by decompiling (CFR) the referenced classes out of
`internal-dependencies.jar`: `com.ubnt.g.f.e.rYtJfMBbtgWvku` is the
controller's own radio-band enum (`BAND_NG="ng"`, `BAND_NA="na"`,
`BAND_AD="ad"`, `BAND_6E="6e"`), and its string-parsing factory
(`chgwykfBxZCAuEHPPQ(String)`) is exactly `string.toLowerCase()` with no
null guard. `eWivisHeQsnaqDtx.java` reads a `"radio"` field off each
`radio_table` entry throughout (`getString("radio", "ng")` in most places,
but at least one call site has no default) — and openUF's
`ucihelper.get_radio_table()` never emitted a `"radio"` field at all. This
was invisible for the entire project up to this point because
`radio_table` was always `{}` (see the section above), so this code path
never ran even once.

**Fixed** in `openuf/ucihelper.lua`: added a `band_for_channel()` helper
(channel 1-14 → `"ng"`, else → `"na"` — openUF only targets dual-band
2.4/5GHz hardware, see `hwassign`; 60GHz/6GHz channel numbers overlap
5GHz's and aren't disambiguable from channel number alone, so unsupported)
and wired it into `get_radio_table()`'s `radio` field. Verified live: after
rebuilding the AP image and re-adopting, zero NPEs across a full adopt
cycle (previously one every ~10s, every inform), and the device reached
"Up to date" (green, connected, `GbE` uplink) in the UI for the first time
this session. Unit test added
(`ucihelper: get_radio_table derives radio band from channel`).

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

## RESOLVED: "Air Stats" panel always showed 0/0B, 0.0% (2026-07-12)

User noticed the live controller UI's device detail panel had a whole
section, "Air Stats" (per-band Tx/Rx Pkts/Bytes, Tx/Rx Retry/Dropped),
that always showed zero regardless of anything else in this
investigation. Two separate causes, both real:

1. **Missing fields, all environments.** `vap_table` entries never sent
   `rx_bytes`/`rx_packets`/`tx_bytes`/`tx_packets`/`tx_retries`/
   `tx_dropped` at all. Confirmed real field names via a second nested
   class in the same decompiled device-schema jar as Stage 2c above
   (`com/ubnt/data/cVbZoFIZsWYaVCquTr$QCtdvLKOBb`, the actual vap-stats
   DTO — note the *top-level* `com/ubnt/data/QCtdvLKOBb` is an unrelated
   FirewallRule class; obfuscated short names collide across packages, so
   always extract by full package path). `iw(8)` only exposes these as
   per-station counters, not an already-aggregated per-VAP one, so
   `build_json` now sums each connected station's counters while it
   already iterates them to build `sta_table`. Added `tx_retries`/
   `tx_failed` parsing to `sysinfo.sta_table()` (`iw`'s `"tx retries:"`/
   `"tx failed:"` fields — TX-side only, 802.11 ARQ retries have no RX-side
   equivalent). `rx_dropped`/`rx_errors`/`tx_errors`/`satisfaction` have no
   source data anywhere in `iw`'s output — left unset, matching the
   `linkscore`/`multicast` "no local source" precedent from Stage 2c.
2. **Environment-only: `ubus`/`iw` don't work at all in this Alpine
   container.** `get_ifname_for_radio()` shells out to `ubus call
   network.wireless status`, then `radio_stats()`/`sta_table()` shell out
   to `iw dev <ifname> survey/station dump` — none of which exist/work
   here (no `ubus`/netifd, no real wireless netdevs), so both were always
   silently empty regardless of item 1. Added `tools/validation/ap/
   ubus-mock.sh` and `iw-mock.sh` (validation-only, same pattern as
   `uci-mock.lua`), seeded with a static `radio0`→`wlan0`/`radio1`→`wlan1`
   mapping and one fake connected station.
3. **A third, genuinely separate bug found investigating item 1's
   neighbor:** `sysinfo.radio_stats()`'s survey-dump parser expected
   `"channel time:"`/`"channel time busy:"`/`"channel time rx:"`/
   `"channel time tx:"`, but `strings /usr/sbin/iw` shows the real binary
   prints `"channel active time:"`/`"channel busy time:"`/`"channel
   receive time:"`/`"channel transmit time:"` — these patterns never
   matched real `iw` output **on any hardware, ever**, going undetected
   because the test fixture was itself fabricated with the same wrong
   names rather than sourced from real `iw` output. Fixed and anchored to
   line-start so `"channel busy time:"` doesn't also match inside the
   separate `"extension channel busy time:"` field `iw` emits on wider
   channels (a literal substring collision).

**Verified live, end-to-end, twice:** first confirmed `build_json` sends
correct non-zero absolute counters via a live one-off script — but the
"Air Stats" UI widget still showed 0/0B. Root-caused: the widget reads as
a rate/delta between informs, and the fake client's counters were static
(same value every call) — a real client's counters only ever grow while
associated, so a static value produces a zero delta even though the raw
per-inform counter is genuinely non-zero. Made `iw-mock.sh`'s fake
counters monotonically increase (persisted counter file); the UI then
showed real traffic: **Tx Pkts/Bytes: 198/180 KB, Rx Pkts/Bytes: 132/90.1
KB, Tx Retry/Dropped: 10.0%/0.0%** on both bands.

**Code changes:** `openuf/inform.lua` (per-VAP aggregation),
`openuf/sysinfo.lua` (`tx_retries`/`tx_failed` parsing, survey-dump field
names), `tools/validation/ap/{ubus,iw}-mock.sh` (validation-only). Unit
tests added in `tests/test_inform_json.lua`, `tests/test_sysinfo.lua`.

## RESOLVED (partially): vap_table's `radio` field was the UCI device name, not the band (2026-07-12)

Continuing the Air Stats investigation: the fake client's traffic counters
showed correctly, but the client never appeared in the Clients list. Found
a second real bug while chasing this — decompiling the controller's stats
pipeline (`com.ubnt.service.system.QDcGUYAmLvJwylXw`) showed `vap_table`'s
`radio` field is parsed through the *exact same* band-parsing enum
(`com.ubnt.g.f.e.rYtJfMBbtgWvku`, `"ng"`/`"na"`/`"ad"`/`"6e"`) already
fixed for `radio_table`'s `radio` field earlier — but
`ucihelper.get_vap_table()` was still sending the raw UCI device name
(`"radio0"`/`"radio1"`). Confirmed live: `WARN stat - unexpected
radio[radio0] while processing stats` logged on every single inform
since the UCI mock started returning real VAPs — almost certainly also
the (or a) cause of the CPU/stats-history graphs staying empty
(documented earlier in this file).

**Fixed:** `get_vap_table()` now derives `radio` from the matching
`radio_table` entry's already-correct band field, and keeps the UCI
device name in a separate `radio_name` field (confirmed as a distinct,
real field on the same decompiled vap-stats DTO,
`cVbZoFIZsWYaVCquTr$QCtdvLKOBb`, alongside `radio`). **Verified live,
twice** (once against the accumulated dev environment, once against a
fully fresh `docker compose down -v` rebuild): the `"unexpected radio"`
warnings stopped completely in both runs. Unit test added in
`tests/test_ucihelper.lua`.

## RESOLVED: fake client never appeared in the Clients list (2026-07-13)

The `SNMiFVJXxaonBOtqbJ`/`rMxwXnPhhdotvjERKoA` gate hypothesis above was
**disproven** by fully decompiling it: it's a pure in-memory Caffeine
`getIfPresent` existence check, keyed *only* by a device's primary `mac`
field (no DB fallback on a miss, no BSSID/ethernet/uplink MACs in its key
space). `de:ad:be:ef:00:01` never collided with anything in that cache,
so this gate was never the cause — it just happened to be the last thing
static analysis had reached before the previous investigation stopped.

**Real root cause, found by tracing the actual client-creation call
chain (`TtZhv.chgwykfBxZCAuEHPPQ`, the `sta_table`→client-record method)
one level further back, into how `vap_table` itself reaches that method:**
both inform processors populate `cachedDevice.vap_table` via a shared
`vapInformProcessor` (`com.ubnt.service.devmgr.C.KHUkYjHujLgFBD`) that
filters the inform's raw `vap_table` *before* any per-station processing
ever runs. For a `usage=user` VAP (openUF's default and only usage), the
filter requires a non-`"unknown"` `id` field — the wlanconf's Mongo
ObjectId — and then re-looks it up via `configCache.get(siteId, id)` to
attach `wlanconf_id`/`ap_mac`/`site_id`/`is_guest`/`is_wep` onto the vap.
**openUF never sent `id`,** so every VAP (and everything nested inside
it, including `sta_table`) was silently dropped before the client-creation
code even ran — no log line, no error, consistent with the total log
silence observed both here and in the `wait_for_initial_inform`
investigation above (this filter's "Inconsistent vap"/"Invalid id" warn
paths only fire on an actual lookup *failure*, not on a missing `id`
being silently absent-checked via `!"unknown".equals(id)`).

`id` is delivered by the controller in the pushed `system_cfg` blob as
`aaa.<n>.id` — confirmed live (`aaa.1.id=<wlanconf ObjectId>`, matching
`db.wlanconf`'s `_id` exactly) — but `openuf/inform.lua`'s
`_parse_wifi_system_cfg` never extracted it, and `ucihelper.lua`'s
`get_vap_table()` never echoed anything back as `id` (its `wlanconf_id`
field was, at the time, wired to the *networkconf* id instead — a
different object entirely, and nil in the real live-controller flow since
the parser never populated it either).

**A second, independent bug was found while verifying the fix live:**
even after `vap_table` started reaching the controller with a valid `id`,
the fake client's entry inside it still wasn't finding its way into
`sta_table` — `openuf/inform.lua`'s `sta_table`-population loop resolves
each vap's live network interface via `ufuci.get_ifname_for_radio(vap.radio)`,
but `vap.radio` had already been repointed (by the earlier `radio`/`radio_name`
fix in this document) to hold the *band* (`"ng"`/`"na"`), not the UCI
device name `get_ifname_for_radio()` actually expects (`"radio0"`/
`"radio1"`, now on the separate `vap.radio_name` field). This callsite was
never updated when that split was made, so it always failed to resolve an
ifname and `sta_table` stayed empty on every real inform, independent of
the `id` fix above — a client could never have appeared even with `id`
sent correctly.

**Fixed:** `_parse_wifi_system_cfg` now extracts `wlanconf_id` from
`aaa.<n>.id`; `ucihelper.wlan_add`/`apply_config`/`get_vap_table` carry it
through end-to-end (new UCI option `openuf_wlanconf_id`, echoed back as
both `id` and `wlanconf_id` — matching the real DTO, which carries both
side by side); `inform.lua`'s ifname resolution now uses `vap.radio_name`.

**Verified live, full chain, from a genuinely fresh `docker compose down
-v` rebuild** (fresh controller setup wizard, fresh WLAN creation, fresh
L2 broadcast discovery + real SSH adoption, per this file's own
documented procedure — not a shortcut): outgoing inform payload confirmed
(via temporary instrumentation, since `debug_dump_file` only captures
*inbound* controller responses) to carry `vap_table[].id` =
`vap_table[].wlanconf_id` = the real wlanconf ObjectId, and
`vap_table[].sta_table` = `[{mac: "de:ad:be:ef:00:01", ...}]`. Confirmed
by direct Mongo query: `db.user.findOne({mac:"de:ad:be:ef:00:01"})` now
returns a real client record (`wlanconf_id`, `last_uplink_mac`,
`last_radio`, `site_id` all correctly populated). Confirmed in the
controller UI: the client appears in the Clients list, Online, connected
via WiFi to `openuf-test` through the `U6 IW` access point.

**Code changes:** `openuf/inform.lua` (`wlanconf_id` extraction in
`_parse_wifi_system_cfg`; `vap.radio_name` fix in the `sta_table` ifname
resolution), `openuf/ucihelper.lua` (`wlanconf_id` parameter on
`wlan_add`/`apply_config`; `id`/`wlanconf_id` fields on `get_vap_table()`).
Tests updated/added in `tests/test_inform_packet.lua`,
`tests/test_ucihelper.lua`, `tests/test_inform_json.lua` (the latter's
`get_ifname_for_radio` mock was previously argument-insensitive, which is
why it didn't catch the `vap.radio`/`vap.radio_name` regression — made
strict). All 187 tests pass.

**Code changes:** `openuf/ucihelper.lua` (`radio`/`radio_name` fields on
`get_vap_table()`). Unit test added in `tests/test_ucihelper.lua`.

## RESOLVED: fake client's "Traffic Activity" was empty in the UI (2026-07-13)

**Symptom:** with the previous client-creation fix in place, `de:ad:be:ef:00:01`
appeared in the Clients list and Online, but its Traffic Activity panel (the
per-client rx/tx bytes graph) showed no data.

**Root cause:** each `sta_table` entry built in `openuf/inform.lua`'s
`build_json` carried only `active/mac/ap_mac/channel/radio/signal/rssi/
capacity/throughput/linkscore/multicast`. The per-station counters
(`rx_bytes`/`tx_bytes`/`rx_packets`/`tx_packets`) parsed by
`sysinfo.sta_table()` were read but only summed into the *per-VAP* totals
("Air Stats" — see the section above); they were never copied onto the
per-client entry itself, and no PHY rate (`tx_rate`/`rx_rate`) or
uptime/idletime was sent per client either.

**Field names confirmed via decompilation** (`internal-dependencies.jar`
from `unifi-network-application:10.4.57`, CFR): the vapInformProcessor class
`com.ubnt.service.devmgr.c.KHUkYjHujLgFBD` copies exactly these attributes
off each incoming `sta_table` entry via `copyAttrsIfPresent`: `"channel",
"radio", "name", "signal", "rssi", "tx_rate", "rx_rate", "tx_packets",
"rx_packets", "tx_bytes", "rx_bytes"`. The same class computes its own
inform-to-inform deltas server-side (`tx_bytes-d`, `rx_bytes-d`, `bytes-d`,
`bytes-r`, keyed by `time_delta`) — meaning, like the VAP-level Air Stats,
openUF must send **raw cumulative counters**, not a pre-computed rate.
`tx_rate`/`rx_rate` are in **Kbps** (matches real-device captures, e.g.
`tx_rate: 39000` for a 39 Mbps MCS rate elsewhere in the reference
material); `iw station dump` reports Mbit/s, so `openuf/inform.lua` now
converts (`tx_bitrate * 1000`). `uptime`/`idletime` map directly to iw's
"connected time"/"inactive time" (seconds associated / seconds since last
activity) — `sysinfo.sta_table()` didn't parse "connected time" at all
before this fix.

**Verified live** (full validation-stack reset per convention, `docker
compose down -v` + rebuild): before the fix, `unifi_stat.stat_5minutes`
already contained `o:"user"` records for `de:ad:be:ef:00:01` with correct
`signal`/`rssi` (-58) but `rx_bytes`/`tx_bytes`/`rx_rate` all 0 — direct
confirmation the gap was specifically the missing per-client counters, not
a broken pipeline. After the fix and another full reset, the same query
shows non-zero `rx_bytes`/`tx_bytes`/`x-total-*`/`rx_rate`, and the
controller UI's Traffic Activity graph populates (needs ~15 minutes /
a few 5-minute buckets before it's visible).

**Correction to the 2026-07-12 "CPU/memory stats history" finding above:**
that investigation queried `db.stat.count()` in the **`unifi`** database and
found it empty, concluding the controller's historical stats-flush job was
likely disabled in this Docker deployment. The historical time-series
collections actually live in the separate **`unifi_stat`** database
(`stat_5minutes`, `stat_hourly`, `stat_archive` — all populated and
growing, confirmed by direct query this session). There is no disabled
background job; the earlier finding queried the wrong database. Both the
CPU/mem history gap and this Traffic Activity gap have the same
explanation: openUF wasn't sending the field, not a controller-side
persistence problem.

**Code changes:** `openuf/sysinfo.lua` (`M.sta_table()` now parses
"connected time" into `connected_sec`); `openuf/inform.lua` (per-client
`sta_table` entry now includes `rx_bytes`/`tx_bytes`/`rx_packets`/
`tx_packets`/`tx_rate`/`rx_rate`/`uptime`/`idletime`); `tools/validation/ap/
iw-mock.sh` (emits `connected time`, and larger per-poll byte increments so
the graph has a visible slope). Tests updated in `tests/test_sysinfo.lua`
and `tests/test_inform_json.lua`; fixture `tests/fixtures/
iw_station_dump.txt` updated. All 187 tests pass.

## RESOLVED: "WiFi Experience: No Experience" — score is a device-computed field, not controller math (2026-07-13)

**Symptom:** with per-client traffic counters now flowing correctly (see the
Traffic Activity section above), the client's Insights panel still showed
"WiFi Experience: No Experience" instead of a percentage.

**Root cause, found by decompiling the ucore client-JSON view** (`internal-
dependencies.jar` from `unifi-network-application:10.4.57`, CFR): the
controller's `wifi_experience_score` UI field is a straight passthrough of
the client doc's **`satisfaction`** field —
`com.ubnt.service.l.e.AcrQJeJCScLn`: `wifi_experience_score =
doc.getOptionalInt("satisfaction")` for wireless clients (`rYtJfMBbtgWvku2
== WIRELESS`). The wireless-client model
(`com.ubnt.service.l.e.AQODNNoMmBlFpWXX`) reads `satisfaction`,
`satisfaction_now`, `satisfaction_real`, `satisfaction_reason`,
`wifi_tx_attempts`, `wifi_tx_retries_percentage`, `tx_mcs`, `ccq`, `noise`,
`nss` as **plain data off the client doc** — the controller computes
nothing itself, it only maintains a running `satisfaction_avg` accumulator
(`{total, count}`, `com.ubnt.service.l.yaQAAsFQlixKuZ`). Real AP firmware
computes `satisfaction` (0–100) on-device with a proprietary,
undocumented formula; corroborated by community reports of `satisfaction_now=NN`
appearing in AP-side wireless-anomaly log lines, and community.ui.com threads
describing it as driven by signal quality and tx-retry ratio (a client with
great signal but very low PHY rate/high retries still scores low — i.e. the
worse factor dominates). Since openUF never sent a `satisfaction` value at
all, "No Experience" was the correct rendering of missing data, not a
controller-side bug.

**Bug found in the prior session's fix:** the field is `tx_mcs`, not
`tx_mcs_index` — `tx_mcs_index` is only the *ucore-message* JSON name
(`com.ubnt.g.q.lhuvxd`, used for a different internal event), not the
wire name the client-stat pipeline above reads. Corrected in this fix;
`rx_mcs` added alongside it (same iw source, `rx bitrate:` line's `MCS N`
suffix, previously unparsed).

**`wifi_tx_attempts`** = total transmission attempts, i.e. `tx_packets +
tx_retries` (both already parsed from `iw`) — confirmed via the decompiled
model above and cross-checked against `unpoller/unifi`'s REST `Client`
struct (`WifiTxAttempts` / `TxMcs` / `RxMcs` / `Ccq` fields, same shape).
`wifi_tx_retries_percentage` is retries as a percentage of attempts.

**Best-effort `satisfaction` estimate** (`estimate_satisfaction()` in
`openuf/inform.lua`, new local helper): combines a signal-quality score
(linear −85 dBm → 0, −50 dBm → 100) and a retry-quality score (`100 -
wifi_tx_retries_percentage`), and takes the **worse** of the two — matching
the community description above. This is explicitly a proxy for Ubiquiti's
real, undocumented on-device formula, not a measured value; flagged in code
the same way as the pre-existing `capacity`/`linkscore`/`multicast`
placeholders. `satisfaction`/`satisfaction_now` are both sent (the UI reads
`satisfaction`; the controller's own `satisfaction_avg` accumulator is fed
from whichever field it reads server-side — sending both covers either).

**Code changes:** `openuf/sysinfo.lua` (`M.sta_table()`: `tx_mcs_index` →
`tx_mcs`, `rx_mcs` added); `openuf/inform.lua` (new `estimate_satisfaction()`
helper; per-client `sta_table` entry: `tx_mcs`/`rx_mcs` rename+addition,
`wifi_tx_attempts`, `wifi_tx_retries_percentage`, `satisfaction`,
`satisfaction_now`). Tests updated in `tests/test_sysinfo.lua` and
`tests/test_inform_json.lua`.

**Confirmed live end-to-end** (full `docker compose down -v` + rebuild,
fresh adopt, WLAN created through the real UI, `iw-mock.sh`'s synthetic
station at signal −58 dBm): client Insights panel now reads **"WiFi
Experience: Good (77%)"** instead of "No Experience". 77% matches
`estimate_satisfaction()`'s signal-score branch exactly — (85−58)/35×100 ≈
77.1, floored, with the retry score not the limiting factor at this
station's near-zero retry percentage.

### Multi-client verification (2026-07-13)

The above was only ever proven against a single synthetic client. Extended
`tools/validation/ap/iw-mock.sh` to emit **three** stations instead of one —
two on `wlan0` (`de:ad:be:ef:00:01` at −58 dBm, MCS-based rate; and
`de:ad:be:ef:00:02` at −70 dBm, a **legacy pre-11n rate string with no "MCS"
suffix**) and one on `wlan1` (`de:ad:be:ef:00:03` at −50 dBm) — each with its
own counter file (keyed by ifname+MAC) so cumulative byte/packet counters and
per-poll throughput deltas grow independently and distinctly per station. No
`openuf/*.lua` changes were needed: `sysinfo.lua`'s `M.sta_table()` already
parsed an arbitrary number of consecutive `Station ...` blocks, and
`inform.lua`'s per-vap loop already summed/keyed everything by MAC.

**Confirmed live end-to-end** (full `docker compose down -v` + rebuild, fresh
adopt, WLAN `openuf-validate` created on both radios through the real UI):

- All 3 clients appear as distinct entries in the controller's Clients list,
  correctly split 2 on the 2.4 GHz radio / 1 on the 5 GHz radio (matches the
  AP detail page's per-channel client counts and "Most Active Clients").
- WiFi Experience matches `estimate_satisfaction()` for each configured
  signal: **Good (77%)** at −58 dBm, **Poor (42%)** at −70 dBm, **Excellent
  (99%)** at −50 dBm.
- The legacy (no-MCS) client correctly renders as **WiFi 2**, vs **WiFi 3**
  for the two MCS-based clients — `tx_mcs`/`rx_mcs` staying `nil` for one
  station doesn't affect its neighbor in the same `station dump` output.
- Per-client throughput (inform.lua's delta-sampled rate) is independent and
  clearly distinct per station once each station's mock byte-counter step
  was also varied, not just its base offset: ↓418/↑209 Kbps, ↓26/↑13 Kbps,
  ↓1.24 Mbps/↑622 Kbps respectively — confirming `M._sta_stats_cache` doesn't
  collide across MACs.

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

## 13. Manage LED (steady on/off toggle)

- **Status:** ✅ fixed and captured (real, via `debug_dump_file`) — 2026-07-12.
  Genuine gap, not just an unverified feature: the controller already sent
  `led_enabled=true` in every `mgmt_cfg` (visible since the very first
  captured baseline inform, back in section 2), but `openuf/inform.lua`'s
  `setparam` handler never parsed it, and `openuf/led.lua` only had
  `locate_start`/`locate_stop` (the transient identify blink) — no
  steady-state on/off API existed at all. The UI's "Manage → LED" checkbox
  would have silently had zero effect on the device.
- **Compare against:** `led_enabled` key in `mgmt_cfg` (confirmed live, both
  `true` and `false` values captured via `debug_dump_file` before writing any
  code).
- **Findings:** unchecked the real "LED" checkbox in the controller UI against
  the Connected device; captured `mgmt_cfg` containing `led_enabled=false`.
  **Fix:** added `openuf/led.lua`'s `M.set_enabled(led_path, enabled)`
  (`trigger=none` + `brightness=1`/`0`, distinct from the locate blink's timer
  trigger), and a `led_enabled` branch in `inform.lua`'s `setparam` handler
  that sets `st.led_enabled` and calls it. **Verified live with the actual
  fix** (not a hack): rebuilt the AP image, adopted fresh — `state.json`
  picked up `led_enabled:true` from the initial adopt `mgmt_cfg`
  automatically, then toggling the real UI checkbox off flipped
  `state.json`'s `led_enabled` to `false` end to end. This validation
  container has no real LED hardware (`dev.conf.led` is `nil`, same as the
  Locate scenario), so the actual sysfs writes are covered by
  `tests/test_led.lua`'s mocked-write unit tests rather than a live sysfs
  observation — matches how Locate's LED hardware interaction was verified.
- **Code changes:** `openuf/led.lua` (`M.set_enabled`), `openuf/inform.lua`
  (`setparam` handler). Tests: `tests/test_led.lua`,
  `tests/test_inform_packet.lua`. All 165 tests pass.

## 14. IP Settings (DHCP/Static) + Port VLAN

- **Status:** ✅ fixed and fully verified live (real controller UI → real
  Linux network reconfiguration → real reported inform payload) — 2026-07-12.
  A brand-new, previously entirely unimplemented protocol surface (grep for
  `config_network`/`dhcp`/`netconf` across `openuf/` returned nothing before
  this pass). **A real, live-fired regression was found and fixed during this
  work — see the incident writeup below before reusing this pattern.**
- **Compare against:** unknown going in — no prior assumption existed.
- **Findings — the real wire shape:** toggling "Static" + entering an IP in
  the controller UI's IP Settings panel does **not** produce a `vap_table`/
  `network_table`-style typed JSON field. It arrives inside the *same*
  `system_cfg` flat OpenWrt-UCI-style key=value blob already seen for initial
  adoption and the "no radio found" finding (sections 3-8/CPU-stats above) —
  confirmed via `debug_dump_file` before writing any code:
  ```
  netconf.1.devname=br0
  netconf.1.ip=172.19.0.50
  netconf.1.netmask=255.255.255.0
  netconf.1.autoip.status=disabled
  route.1.gateway=172.19.0.1
  resolv.nameserver.1.ip=192.168.1.1
  dhcpc.status=enabled        <- present when DHCP; dhcpc.1.* SUB-KEYS
                                  (dhcpc.1.status, dhcpc.1.devname) are the
                                  actual DHCP-vs-static signal, not an
                                  explicit boolean flag
  ```
  "Port VLAN" (a plain checkbox with no VLAN ID input in this UI) produced
  **no observable change** in `system_cfg` (`vlan.status` stayed `disabled`
  both times tested) — inconclusive; likely needs a real VLAN network to
  already exist site-wide, or additional UI not surfaced in this simplified
  view. Not implemented — genuinely no confirmed field to implement against.
- **Fix:** new `openuf/netconfig.lua` (`apply_static`/`apply_dhcp`, shelling
  out to real `ip addr`/`ip route`/`udhcpc` — the same primitives real
  OpenWrt hardware and this validation container both have, unlike UCI).
  `inform.lua`'s `setparam` handler parses `system_cfg` and calls the right
  one, using the existing `cfg.net.lan_cpueth` interface-resolution
  convention already established by `announce.lua`'s `get_mac`/`get_ip`
  (reused, not reinvented). Also syncs `st.ip` after a successful apply (it
  was previously a boot-time-only snapshot, per `_populate_net_info` — see
  the incident below for why this mattered).
- **Live-fired incident, found and fixed mid-session:** the first live test
  of `apply_dhcp` **stranded the AP container** — `ip -4 addr show`/
  `ip route show` returned completely empty, `inform.lua` started logging
  `connect failed: Network unreachable`. Root cause: a fresh device's
  *very first* post-adopt `setparam` **always** carries `system_cfg` with
  `dhcpc.1.status=enabled` (a brand-new device starts in DHCP by
  definition), and the original code called `apply_dhcp` (flush + `udhcpc`)
  on *every* dhcp-signalling `system_cfg`, not just genuine static→DHCP
  reversions. This validation container's Docker bridge has no real DHCP
  server to grant a fresh lease, so the flush succeeded but the re-lease
  never did, leaving the interface with zero addresses. **Fixed**: `dhcp`
  branch now only calls `apply_dhcp` when `st.ip_mode == "static"` already
  (i.e. genuinely undoing our own prior static push) — first contact and
  every steady-state DHCP reaffirmation are now a no-op, matching how real
  hardware's own continuously-running DHCP client doesn't need us to
  manually re-invoke it just because the controller confirmed the mode.
  Added a regression test
  (`test_inform_packet.lua`: "does NOT flush dhcp on first contact")
  and recovered the stranded container via `docker exec` (works regardless
  of the container's own network state) before re-testing.
- **Separate environmental fix required:** `apply_static`'s real `ip addr
  add`/`ip route replace` initially failed with
  `RTNETLINK answers: Operation not permitted` — Docker containers lack
  `CAP_NET_ADMIN` by default even running as root (confirmed by running the
  identical command manually, same error). Added `cap_add: [NET_ADMIN]` to
  `tools/validation/docker-compose.yml`'s `ap` service — needed only to
  validate this code path in this disposable container; real target
  hardware has full kernel privileges and would never hit this.
- **Verified live, twice, with the corrected code**: adopted a device fresh,
  confirmed the interface survived the initial-adopt DHCP-reaffirm cycle
  intact (no flush), then pushed a real static IP (`172.19.0.88`,
  gateway `172.19.0.1`) via the controller UI. Confirmed **all** of: the
  real kernel interface actually changed (`ip addr show` →
  `172.19.0.88/24`), the real default route was set, `inform.lua` kept
  informing successfully *from the new address* (same-subnet traffic
  doesn't need the gateway, so this was safe to test for real), `state.json`
  recorded `ip_mode`/`static_ip`/`static_netmask`/`static_gateway` and the
  synced `ip` field correctly, and — the full loop closed — the controller's
  own Overview panel displayed the new `IP Address: 172.19.0.88` back to the
  admin.
- **Code changes:** `openuf/netconfig.lua` (new), `openuf/inform.lua`
  (`setparam` handler), `tools/validation/docker-compose.yml`
  (`cap_add: NET_ADMIN`, validation-env only). Tests:
  `tests/test_netconfig.lua` (new), `tests/test_inform_packet.lua`. All 177
  tests pass.

## 15. Power/PoE (Overview → Parent Device → "Power")

- **Status:** 🔍 scoped, not implemented — **concluded environmental, not an
  openUF gap** — 2026-07-12.
- **Compare against:** none going in; no PoE/power field existed anywhere in
  `openuf/` (confirmed via repo-wide grep during Stage 2's investigation).
- **Findings:** the specific UI element flagged ("Power: -") lives inside
  the **"Parent Device"** subsection of the Overview panel, directly
  alongside "Experience" and the uplink's Down/Up Pkts/Bytes counters — all
  of which are properties of the **upstream switch/gateway this AP connects
  through** (LLDP-linked), not self-reported attributes of the AP itself.
  Confirmed no separate self-power section exists anywhere else in the
  Overview panel for the AP's own values. This disposable validation
  environment has no real PoE-capable switch adopted as this AP's parent
  (single AP, no switch container) — there is nothing to LLDP-link to and
  report PoE delivery from, regardless of what openUF's own inform contains.
  **This specific UI element cannot be made to show real data without adding
  a real (or emulated) PoE switch to the validation environment** — out of
  scope for this pass.
- **Adjacent finding, for a future pass**: Stage 2's decompile of
  `com.ubnt.service.devmgr.tFhABnrHYJqvjaoEa` (line ~1405) found
  `uuvchZbWVhirD2.copyAttrsIfPresent(inform, "power_source",
  "power_source_voltage", "psu_table", "power-monitor", "total_max_power",
  "led_state", "outlet_table")` — these fields **are** copied directly from
  a device's own raw inform payload when present, confirming at least some
  power/PoE reporting genuinely is self-reportable, independent of any
  parent switch. Field names are confirmed; nothing about their expected
  values/format was researched (out of scope here, and openUF has no local
  signal to determine a real PoE negotiation class in a generic Linux
  environment — any value added now would be a speculative hardcoded
  placeholder, unlike the well-evidenced best-effort fields elsewhere in
  this document). Worth reopening if the validation environment ever gains
  a real switch container, or if a different, non-Parent-Device UI surface
  for these fields is found.
- **Code changes:** none.

---

## 16. "Set Replacement Device" / "Load Configuration" (device-to-device config clone) — 2026-07-13

- **Status:** ✅ both flows verified working end-to-end with openUF devices,
  **zero product-code changes needed**.
- **What these are:** device settings → Manage offers two config-transfer
  actions. Decompiled controller sources
  (`SNMiFVJXxaonBOtqbJ.java:2292/2317` — replace + clone;
  `InformServlet.java:288-302` — reply types) prove **neither involves a
  device-side export/import protocol**: the "configuration" is the source
  device's stored MongoDB document, cloned field-by-field controller-side
  (`commonDeviceCloneConfigService`), after which the target simply receives
  an ordinary adopt + `setparam` push. The inform reply `_type`s remain only
  noop/setparam/cmd/upgrade/reboot/setdefault — there is no
  export/backup/dump command for openUF to implement.
- **Environment:** needs two same-model devices → new `ap2` compose service
  (`tools/validation/docker-compose.yml`, `replacement` profile); recipes in
  `tools/validation/README.md` section 6. MAC/IP identity comes free from
  each container's own `eth0`.
- **Set Replacement Device, verified live:** with AP1 adopted+configured
  (alias `openuf-src`, 2.4 GHz channel pinned to 6) and AP2 announcing
  unadopted (L2 broadcast → "Pending Adoption"), entering AP2's MAC in the
  dialog armed the replacement ("Replacement Device Set" toast; UI issues no
  device command — it just stores the MAC). After `docker stop` on AP1, the
  controller **auto-adopted AP2 ~50 s later with no UI interaction** (real
  SSH `set-adopt`, same as manual adoption) and provisioned it with the
  cloned config: AP2's first `system_cfg` already carried
  `radio.1.channel=6`, and the UI showed a single migrated `openuf-src`
  entry at AP2's IP. The old device entry is consumed by the migration.
- **Load Configuration, verified live:** the dialog's dropdown is backed by
  `GET /v2/api/site/default/device/<mac>/clone-candidates`. With only one
  device it returns nothing ("No Devices Found"); once a second same-model
  openUF device was adopted, it listed the other device — so an
  adopted+online openUF AP qualifies as a clone source with no extra fields.
  Selecting it → Apply produced "Configuration Loaded" and an immediate
  `setparam` on the target: log showed `radio.1.channel=auto` → `=6`, fresh
  `cfgversion`, settling back to `noop` within one cycle. Even the alias was
  cloned (target renamed to `openuf-src` in the UI).
- **Incidental but load-bearing observation:** a `docker stop`/`start` of an
  AP container gets a **fresh MAC from Docker** (observed
  `32:67:0d:e1:42:a9` → `a6:5c:1a:34:36:a5` across one restart, same
  compose service). So a restarted AP container is a *brand-new device* to
  the controller — convenient for producing fresh replacement targets, but
  it means a stopped device's controller entry can never be resumed by
  simply starting the container again.
- **Why this matters for future UI tests:** a fully fresh openUF device can
  now inherit a configured device's settings in ~1 minute without redoing
  any UI configuration — either automatically (replacement) or with two
  clicks (load configuration) — instead of hand-reconfiguring after every
  device reset.
- **Code changes:** validation environment + docs only (`ap2` service,
  README section 6); `openuf/` untouched.

---

## 17. Wired clients (`port_table`/`mac_table`) — decompile + implementation (2026-07-13)

- **Status:** ✅ implemented, unit-tested, and confirmed live end-to-end
  against a real running controller: adopted, both fake wired hosts appear
  in the client list as wired with the correct port, and the Ports view
  renders them on the correct port. See "Confirmed live against the running
  controller" below.
- **Why this was investigated:** openUF had never simulated or reported
  wired clients, and there was no wired-client code path anywhere in the
  daemon. Extracted `internal-dependencies.jar` from the pinned controller
  image (`lscr.io/linuxserver/unifi-network-application:10.4.57`,
  `docker cp` + CFR 0.152, same tooling this doc's other decompile findings
  used) to determine whether that's a real gap for the U6-InWall model
  openUF impersonates, or genuinely out of scope for an AP.
- **It is a real gap.** In the model registry
  (`com.ubnt.data.dhdeXcHqLRBKMUZk`), the `U6IW` entry is constructed with
  device type `uap`, **5 ethernet ports**, and feature set
  `{MYeBKiwr.yojQKHv, MYeBKiwr.nJYYFGHEYoaNo}`. `Device.isSwitch()`
  (`com.ubnt.data.uuvchZbWVhirD:4693`) is
  `hasFeature(MYeBKiwr.UiHQyVmgX) || hasFeature(MYeBKiwr.yojQKHv)` — true
  for U6IW (a plain AP like `U6MP` only gets `nJYYFGHEYoaNo` and is not a
  switch). This matches reality: a U6-InWall has a 4-port downstream
  switch built in.
- **The AP inform processor runs the full wired-client path for such
  devices.** `com.ubnt.service.devmgr.PGOcbDWlbnYQdFW` (the `uap`/`uacc`
  state processor), guarded by exactly `if (device.isSwitch())`, iterates
  incoming `port_table[]` entries with `port_idx > 0` and, per port, calls
  `com.ubnt.service.devmgr.DyonYyyYJkiyv`, which reads that port's
  **`mac_table[]`** (plus `mac_table_ipv6[]` when `fw2_caps` bit 32 is set)
  and feeds each entry to the client updater `kdjMkHbtXkncIhL` → `TtZhv`.
  `TtZhv` is what writes the client record: **`is_wired=true`, `sw_mac`**
  (the reporting device's MAC), **`sw_port`** (`port_idx`), and `ip`/
  `hostname`/`age`/`uptime`/`ipv6_addresses` off the mac_table entry. The
  same pass builds `downlink_table` and each port's `last_connection`/
  `last_connection_state`. Ports flagged `is_uplink: true` are skipped for
  client creation. Since openUF sent no `port_table` at all, this loop
  always iterated empty — zero wired clients could ever appear, and the
  Ports view had nothing behind it, regardless of what was genuinely
  bridged into a real device's `br-lan`.
- **`fw_caps` bit `0x10` (16) is a separate, second gate**, only for the
  Ports view's projection of `port_table` into the device DTO —
  `Device.hasQCASwitch()` is exactly `hasFirmwareCapability(16)`. Client
  ingestion itself is gated only on `isSwitch()` (a model-registry
  property, not this bit), so wired clients can appear in the client list
  without it; the Ports view needs it. openUF now sends both.
- **Payload contract implemented** (`openuf/inform.lua`, `openuf/sysinfo.lua`):
  a top-level `port_table`, one entry per `cfg.net.ports` entry (new
  modelmap field: `{idx, ifname, uplink}, ...`, defaulting to
  `{wan_cpueth=uplink, lan_cpueth=lan}` when a modelmap omits it), each
  carrying `port_idx` (1-based), `name`, `media`, `up`, `enable`, `speed`,
  `full_duplex`, `is_uplink`, `speed_caps`, `port_poe`, `poe_caps`, and
  `rx_bytes`/`tx_bytes`/`rx_packets`/`tx_packets`/`rx_errors`/`tx_errors`
  from the same `M._sysinfo.interfaces()` counters `if_table` already uses.
  Non-uplink ports additionally carry `mac_table`, sourced from a new
  `sysinfo.mac_table(ifname)` that joins `bridge fdb show dev <ifname>`
  (authoritative MAC↔port map; dynamic "master br-lan" entries only —
  "self"/"permanent" lines and multicast/broadcast MACs are filtered out)
  with `/proc/net/arp` (MAC→IP) and `/tmp/dhcp.leases` when present
  (MAC→hostname, optional — an AP is usually not the DHCP server). Two
  exclusion filters in `inform.lua` prevent double-reporting: the device's
  own MACs, and any MAC currently associated as a wireless station
  (collected while building `vap_table`) — a wireless client bridged into
  `br-lan` is genuinely visible in the bridge FDB too, so without this a
  wireless client would also appear as a wired one.
- **Environment:** `tools/validation/ap/bridge-mock.sh` (fakes two wired
  hosts on the container's one downstream port, mirroring `iw-mock.sh`'s
  established shadow-the-real-binary pattern) and
  `tools/validation/ap/entrypoint.sh` (seeds `/proc/net/arp` with
  `ip neigh replace ... nud permanent` for those two fake MACs — kernel
  neighbor-table state can't be baked into an image layer, so this has to
  run at container start; the `ap` compose service already has the
  `NET_ADMIN` capability this needs, added earlier for `netconfig.lua`).
  One of the two fake hosts has no `/tmp/dhcp.leases` entry, to prove
  `hostname` stays correctly optional rather than invented.
- **Verified directly inside the built container** (bypassing the
  browser-blocked controller UI step): ran `entrypoint.sh` then
  `inform.build_json()` by hand inside `openuf-validation-ap` and decoded
  the resulting JSON —
  ```
  port_table entries: 2
    port_idx=1 is_uplink=true  mac_table_count=0
    port_idx=2 is_uplink=false mac_table_count=2
      mac=ca:fe:be:ef:00:01 ip=192.168.1.101 hostname=printer age=0 uptime=0
      mac=ca:fe:be:ef:00:02 ip=192.168.1.102 hostname=nil    age=0 uptime=0
  fw_caps: 16
  ```
  Confirms the uplink port correctly carries no wired clients, the
  downstream port correctly reports both fake hosts (one with, one
  without a hostname), and `fw_caps` is set — end to end through the real
  `bridge`/ARP mocks, not just fixture-driven unit tests.
- **Confirmed live against the running controller:** ran the environment's
  first-run setup (Advanced Setup → Skip, per this doc's existing
  guidance), set the Inform Host Override to the controller container's
  own IP and a compliant Device SSH Authentication password (both required
  by the controller's own validators — the override rejects a hostname,
  and the password field enforces ≥12 characters), then pointed the AP's
  `inform_url` at the controller (`syswrapper.sh set-inform
  http://controller:8080/inform` — the compose service name, not the
  stale `unifi` hostname `conf.lua`'s in-repo default still has) and ran
  `lua announce.lua &` + `lua inform.lua`. L2 discovery → **Click to
  Adopt** → controller log showed `Device[...] adoption - completed`. Once
  adopted:
  - **Clients list:** both `bridge-mock.sh` hosts appear, filterable under
    **Connection → Wired (2)**, each showing **Connection: "U6 IW Port
    2"** — the LAN port, never the uplink (port 1). One shows as
    **"printer 00:01"** (hostname from `/tmp/dhcp.leases`); the other as
    its bare MAC **"ca:fe:be:ef:00:02"** (no lease entry) — confirming
    `hostname` is genuinely optional, not invented, on the real client
    detail view too (IP `192.168.1.101`, Network `Default`, Hostname
    `printer` all matched the fixture exactly).
  - **Ports view** (`/manage/default/ports`) renders correctly: port 1
    shown as the uplink (separate icon, no client), port 2 shown as
    "Data" with the connected wired client listed directly on the port
    row — this is the `fw_caps` bit `0x10` projection working, not just
    client-list ingestion.
  - Not separately re-verified live in this session: the wireless/wired
    double-report exclusion (no `iw-mock.sh` stations were running
    alongside this run) — already covered with high confidence by the
    dedicated unit tests in `tests/test_inform_json.lua`.
  - **The Ports view's Bps/Bytes chart itself was flat/empty** when checked
    a couple of minutes after adoption. **Not a bug** — same explanation as
    the CPU/mem and wireless "Traffic Activity" gaps earlier in this doc:
    decompiling confirms `port_table[].rx_bytes`/`tx_bytes` is read by
    `com.ubnt.service.system.QDcGUYAmLvJwylXw` (internally labeled
    `"stat-processor"`, the same class that handles CPU/mem and per-client
    wireless stats), which archives into the separate `unifi_stat`
    database (`stat_5minutes`/`stat_hourly`/`stat_archive`) on its own
    schedule rather than rendering live inform data directly. The earlier
    Traffic Activity fix needed ~15 minutes / a few 5-minute buckets before
    its graph populated — this session's check came nowhere close to that
    window, so the flat line is expected, not evidence of a problem with
    the counters themselves.
  - **Wired hosts will never show per-client traffic**, by design, not as
    a gap: `TtZhv` (the `mac_table`-entry consumer) only reads `mac`/`ip`/
    `hostname`/`age`/`uptime` off each entry — there is no per-client
    byte-counter field anywhere in the real wired-client wire protocol,
    unlike wireless `sta_table` entries (which do carry `rx_bytes`/
    `tx_bytes`). A wired client's traffic is attributed via its switch
    port's own counters, not a separate per-MAC one.
- **Code changes:** `openuf/sysinfo.lua` (`mac_table()`), `openuf/inform.lua`
  (`port_table`/`fw_caps` in `build_json()`), both modelmaps (new
  `cfg.net.ports`), `tests/test_sysinfo.lua` + `tests/test_inform_json.lua`
  (new fixtures/cases), `tools/validation/ap/bridge-mock.sh` +
  `entrypoint.sh` + `Dockerfile` changes.

## 18. Per-port VLAN assignment — RESOLVED: missing `fw_caps` bit 0x100 (`hasOWRTSwitch`) (2026-07-13)

- **Status:** ✅ fixed and confirmed live end-to-end (real controller UI → real per-port VLAN
  assignment saved → real `switch.vlan.*` config pushed back to the device).
- **Trigger:** user noticed the Ports view's "Native VLAN Assignment" always showed `1` on both
  ports and asked whether per-port VLAN tagging is actually supported/editable.
- **Finding 1 — it's a real, gated UI feature.** The device settings panel's IP Settings section
  has a **"Port VLAN"** checkbox (the same one section 14 above found produced no observable
  `system_cfg` change back on 2026-07-12 — that test predates this session's `port_table`/
  `isSwitch()` work, which is what makes the controller treat this device as switch-capable at
  all). Enabling it and applying now genuinely does something new: the next `setparam` carries a
  brand-new **`switch.*`** UCI-style block in `system_cfg`, never previously seen in this
  project's captures (`switch.status`, `switch.vlan.status`, `switch.vlan.N.id/mode/status`,
  `switch.port.N.name/opmode` — one entry per the U6IW model's 5 physical ports, derived from the
  model registry, not from whatever `port_table` openUF actually reports). openUF does not parse
  or apply this `switch.*` block at all (`M._parse_wifi_system_cfg`/the `setparam` handler only
  understand `aaa.*`/`wireless.*`/`radio.*` and `netconf.*`/`dhcpc.*`/`route.*`) — a new, wholly
  separate config domain, out of scope for this fix (nothing depends on openUF consuming it; the
  controller manages VLAN membership purely server-side and only needs the device to *accept*
  the port_overrides push, which is what was actually broken).
- **Finding 2 — actually assigning a non-default VLAN to a port was rejected outright.** With
  "Port VLAN" enabled, each port's settings panel exposes a genuinely editable **"Native VLAN /
  Network"** dropdown and **"Tagged VLAN Management"** (Allow All / Block All / Custom). Creating
  a second network ("IOT", VLAN 20) and assigning it as port 2's Native VLAN failed before any
  `system_cfg` was ever generated — the controller's REST layer rejected the request outright:
  ```
  PUT /api/s/default/rest/device/<id>  ->  400
  {"meta":{"rc":"error","port_idx":2,"msg":"api.err.VlanTaggingUnsupportedByDevice"},"data":[]}
  ```
  Captured directly from the browser (`window.fetch` monkey-patch on the request/response, not
  inferred from logs).
- **Root cause — traced through a genuine extraction pitfall.** The obfuscated class names
  `com.ubnt.service.aa.*` and `com.ubnt.service.aA.*` (and ~55 other single/double-letter package
  pairs differing only by case) are **distinct real packages** in the jar, but macOS's
  case-insensitive filesystem silently folded them into one directory on `unzip`, corrupting the
  first extraction this session used and producing a misleading read of the wrong class's method
  body. Re-extracted the jar inside a Linux container (`docker cp` the jar into
  `linuxserver/unifi-network-application:10.4.57` itself, which already has a JVM, then
  `unzip`+CFR entirely on its own case-sensitive filesystem) to get a trustworthy decompile. This
  only affected this section's investigation — section 17's wired-client work relied on
  `com.ubnt.data.*`/`com.ubnt.service.devmgr.*`, real English package names with no case-collision
  risk, so nothing there needed re-verification.
  With the corrected extraction, the actual throw site is
  `com.ubnt.ace.api.e.VVyiC`'s private per-port validator (called only when
  `Device.hasQCASwitch()` — `hasFirmwareCapability(16)` — is true, which openUF's `fw_caps`
  already satisfied):
  ```java
  private void chgwykfBxZCAuEHPPQ(UCthhvfQNZ port, boolean hasOWRTSwitch, boolean hasSwitchVlanCap8) {
      nwTNVfYOnNbEWSoCkPq.guoZiIiLhURleoJ(port).ifPresent(forwardMode -> {
          if (!((forwardMode != ALL && forwardMode != CUSTOMIZE) || hasOWRTSwitch)) {
              throw new QnvUxbsXyAJZ(VLAN_TAGGING_UNSUPPORTED, ...);
          }
          if (hasSwitchVlanCap8 && forwardMode NOT IN {CUSTOMIZE, NATIVE, DISABLED}) {
              throw new QnvUxbsXyAJZ(VLAN_TAGGING_UNSUPPORTED, ...);
          }
      });
  }
  ```
  called as `this.chgwykfBxZCAuEHPPQ(portOverrides, device.hasOWRTSwitch(), device.hasSwitchVlanCapability(8))`.
  For a port with no explicit `forward` override (the default, "all" mode — true for every port
  we'd ever send), the first branch collapses to `!hasOWRTSwitch()`: **if the device doesn't
  declare `hasOWRTSwitch()`, every default-mode port is unconditionally rejected**, regardless of
  `vlan_caps` or anything port-specific (confirmed by sweeping `switch_caps.vlan_caps` through
  0/3/4/5/6/7/15/31/255 directly in Mongo — bit 4 present vs. absent only changed *which* of two
  near-identical errors fired, never fixed the underlying rejection). `hasOWRTSwitch()` is exactly
  `hasFirmwareCapability(256)` (bit `0x100`) — literally "OpenWrt switch" as opposed to a genuine
  QCA hardware switch ASIC, which is thematically exactly what openUF is.
- **Fix, confirmed two ways:**
  1. Directly against the REST endpoint (bypassing the UI, via `curl` with a session cookie):
     `fw_caps=0x10` → `VlanTaggingUnsupportedByDevice`; `fw_caps=0x10|0x100=0x110` → `{"rc":"ok"}`.
  2. End-to-end for real: updated `openuf/inform.lua`'s `fw_caps` to `0x110`, deployed it into the
     running `openuf-validation-ap` container, confirmed the controller's own device doc picked up
     `fw_caps: 272` from a genuine inform (not a Mongo edit), then reassigned port 2's Native
     VLAN to "IOT (20)" through the actual controller UI — saved with no error, and the next
     inform's `system_cfg` carried a **second** VLAN block it had never sent before:
     `switch.vlan.2.id=20`, `switch.vlan.2.mode=tagged`, `switch.vlan.2.status=enabled`.
- **Code changes:** `openuf/inform.lua` (`fw_caps` now `0x110` — bit `0x10` `hasQCASwitch` +
  bit `0x100` `hasOWRTSwitch`), `tests/test_inform_json.lua` (updated assertion). All 199 tests
  pass.

## 19. Client block/unblock — implemented and verified live (2026-07-13/14)

- **Status:** ✅ implemented, unit-tested, and confirmed live end-to-end (real controller UI →
  real wire `cmd` → real persisted state → real kernel-level nftables enforcement, surviving a
  simulated restart).
- **Wire format, captured directly (not inferred):** both Block and Unblock (device Settings tab
  → Quick Actions area, works for both wireless and wired clients) send a one-shot inform-response
  `cmd`, not a persistent field on every inform:
  ```
  {"_type":"cmd","cmd":"block-sta","mac":"ca:fe:be:ef:00:02", ...}
  {"_type":"cmd","cmd":"unblock-sta","mac":"ca:fe:be:ef:00:02", ...}
  ```
  A candidate persistent field (`include_blocks`, present on every `noop`/`state` response) was
  checked and ruled out — it stayed `[]` even while a client was genuinely blocked, so it isn't the
  real mechanism. The device itself is expected to remember the block after the one-shot command,
  the same way real hardware would.
- **"Remove" sends no wire command at all.** Confirmed by watching the inform log across the
  whole action — nothing but `noop`. It's pure controller-side bookkeeping (deletes the Mongo
  client record); a still-physically-present client reappears on the very next inform, since
  nothing tells the device to stop reporting a MAC it's still genuinely seeing. No code change
  needed or possible here.
- **Implementation:**
  - `openuf/firewall.lua` (new) — nftables-based enforcement, in a dedicated `bridge openuf` table
    so it can't collide with (or be wiped by) OpenWrt's own fw4-managed tables. A single dynamic
    set (`blocked_macs`, `type ether_addr`) holds every blocked MAC; two static rules
    (`ether saddr/daddr @blocked_macs drop`) reference the set once and never change — blocking/
    unblocking is then just `nft add|delete element`, never touching the rules themselves.
    `M.reconcile(blocked_macs)` rebuilds the whole table from scratch (delete + recreate) rather
    than diffing, mirroring `netconfig.lua`'s existing flush-then-reapply precedent for the same
    reason: simpler and self-healing regardless of prior state. `M.deauth(mac, ifnames)` issues
    `hostapd_cli -i <ifname> deauthenticate <mac>` per configured radio, best-effort, to
    immediately kick an already-associated station (the nft rule alone only stops *future*
    traffic).
  - `openuf/state.lua` — new persisted `blocked_stas` field (array of MAC strings). Like
    `netconfig.lua`'s live `ip addr`/`ip route` state, nft rules are kernel-only and don't survive
    a restart on their own, so the persisted list is what actually survives — `M.reconcile` is
    called with it at `M.run()` startup, in the `setdefault` (factory reset) handler, and in
    `_reload_if_changed` (out-of-band state.json edits), so every path that (re)establishes the
    device's live state also re-establishes its enforcement to match.
  - `openuf/inform.lua`'s `cmd` dispatch — new `block-sta`/`unblock-sta` branch: updates
    `st.blocked_stas` (deduped), persists it, calls `M._firewall.reconcile`, and — for
    `block-sta` only — resolves every configured radio's live ifname via the existing
    `ucihelper.get_radio_table`/`get_ifname_for_radio` (same pattern the `spectrum-scan` cmd
    handler already uses) and calls `M._firewall.deauth`.
- **Verified live, twice:**
  1. Blocked a fake wired client through the real controller UI. Confirmed all of: the wire `cmd`
     arrived (`{"cmd":"block-sta","mac":"ca:fe:be:ef:00:02",...}`), `state.json` persisted
     `"blocked_stas":["ca:fe:be:ef:00:02"]`, and the *live kernel nftables ruleset* inside the
     validation AP container showed the MAC as a real set element
     (`nft list table bridge openuf` → `elements = { ca:fe:be:ef:00:02 }`) — genuine enforcement,
     not just a state-file flag. Unblocking through the UI removed it from both the persisted
     state and the live nft set.
  2. **Restart survival**: with the client still blocked, killed `inform.lua`, manually deleted
     the `bridge openuf` nft table (simulating a reboot losing all kernel-only firewall state),
     and restarted `inform.lua` fresh — with no new `cmd` from the controller at all, the block
     was re-established purely from `state.json`, confirming the reconcile-at-startup path
     actually works, not just the cmd-time path.
- **Environment:** `nftables` and `hostapd` added to `tools/validation/ap/Dockerfile` (both
  previously absent — installed and verified working, `nft` included, inside the already-present
  `NET_ADMIN` capability added earlier for `netconfig.lua`). `hostapd_cli` itself has nothing to
  actually talk to in this hardware-less container (no real hostapd process, since there's no real
  wireless hardware) — the deauth call is exercised and asserted via unit tests (captured command
  string, right MAC, right interface), not live, for that specific piece.
- **Code changes:** `openuf/firewall.lua` (new), `openuf/state.lua` (`blocked_stas`),
  `openuf/inform.lua` (`cmd` dispatch + reconcile-at-startup/setdefault/reload),
  `tests/test_firewall.lua` (new), `tests/test_inform_packet.lua` (new block-sta/unblock-sta
  cases), `tools/validation/ap/Dockerfile` (`nftables`, `hostapd`). All 203 tests pass.

## 20. Environment / rogue-AP scanning (`scan_radio_table`) — decompile + four real bugs found live (2026-07-14)

- **Status:** ✅ openUF's side fully implemented, unit-tested, and confirmed correct end-to-end —
  four real bugs found and fixed this session via decompiled backend Java, direct REST
  verification, and decompiling the controller's own React frontend bundle. openUF's payload and
  the controller's backend ingestion/storage are both proven 100% reliable (direct polling never
  missed). ⚠️ Separately, the controller's own Environment tab has a real, reproducible frontend
  bug where the table stops reflecting fresh data ~10s after mount with no user interaction, only
  recoverable by manually changing a filter/tab — see "Correction" below. That bug is outside
  openUF's control; it is not evidence of anything wrong on openUF's side.
- **What this adds:** openUF now reports neighboring wireless networks per radio (rogue-AP /
  WiFi-environment scanning), backing the controller's Insights → AirView → **Environment** tab
  (`GET /api/s/default/stat/rogueap`). Implementation: `openuf/sysinfo.lua`'s `M.scan_table(ifname)`
  parses `iw dev <ifname> scan dump` (the kernel's already-cached BSS list — cheap, non-disruptive,
  unlike the existing `spectrum-scan` cmd's real `iw scan` trigger) into
  `{bssid, essid, freq, channel, signal, security, age}`; `openuf/inform.lua` wires one
  `scan_radio_table` entry per configured radio, each carrying that radio's `scan_table` list, into
  `build_json()`'s payload.
- **Wire shape confirmed via decompile**, cross-checked against two controller classes pulled from
  `internal-dependencies.jar` (10.4.57, `docker cp` + CFR 0.152, never a bind mount or macOS-native
  unzip — see this doc's standing case-collision warning):
  - `com.ubnt.service.devmgr.PGOcbDWlbnYQdFW` (the AP inform processor) reads a top-level
    `scan_radio_table` array; for each entry with a `scan_table` field, it extracts `radio`
    (default `"scan"`) and `name` (default `"unknown"`) and hands the nested `scan_table` list to
    the scan-ingestion service — confirming the nested `scan_radio_table[].scan_table[]` shape is
    exactly right, not a flat list.
  - `com.ubnt.service.aO.hhFgUVZPT` (the scan-ingestion service, freshly re-decompiled 2026-07-14
    after finding its package, `com.ubnt.service.aO`, had been silently merged into a differently-
    cased sibling by an earlier macOS-native extraction — the exact corruption class this doc
    already warns about) is where each entry is validated and cached. Its consumer DTO,
    `com.ubnt.service.aO.bLwwMKkr` (literally named `"PeerScan"` in its own builder's `toString`),
    confirmed the full field list: `mac, ap_mac, bssid, serialno, radio, radio_name, band, channel,
    bw, freq, rssi, signal, last_seen, vwire_enabled, security, essid, model, model_display`.
- **Real bug #1 (found live, unrelated to this feature but broke it in testing): `mgmt_url` was
  wrongly treated as an alias for `inform_url`.** `inform.lua`'s `setparam` handler had
  `if k == "mgmt_url" or k == "inform_url" then st.inform_url = v`. Live capture against a real
  controller showed `mgmt_url` is the **web UI deep link**
  (`https://host:8443/manage/site/default`), not an inform endpoint — completely different from the
  genuine `inform_url` key the controller separately sends during initial adoption (already
  correctly documented in §"L2 discovery + real SSH adoption", where a captured `mgmt_cfg` shows
  both keys side by side with different values). Conflating the two meant that on the very first
  routine `setparam` after adoption, the device overwrote its own working `inform_url` with the web
  UI link and started POSTing informs there instead — fatal on an http-only build (`inform: POST
  failed: https inform URL requires luasec`), and the device was never seen again by the controller
  (`invalid inform_ip` / stuck in "Adopting"-adjacent limbo). **Fix:** only `inform_url` updates
  `st.inform_url`; `mgmt_url` is ignored. Existing test that encoded the wrong assumption
  (`tests/test_inform_packet.lua`, "setparam updates inform_url from key=value string") was fixed to
  use a real `inform_url=` fixture; a new companion test asserts `mgmt_url` alone leaves
  `st.inform_url` untouched.
- **Real bug #2: scan entries need `age` (elapsed seconds), not an absolute `last_seen`
  timestamp.** The first implementation computed `last_seen = M._time()` (an absolute Unix
  timestamp) per entry. `hhFgUVZPT`'s ingestion code reads `uCthhvfQNZ.getInt("age")` — elapsed
  seconds since the neighbor was last seen — and computes the absolute `last_seen` itself as
  `report_time - age`; it also silently drops any entry with `age >= 30` before it ever reaches the
  scan cache, as a staleness guard. Sending an absolute timestamp under either key is not just
  wrong, it is silently discarded — no error, just an empty result, which is what made this bug hard
  to spot without decompiling the consumer. **Fix:** `sysinfo.lua`'s `scan_table()` now parses `iw`'s
  own `"last seen: N ms ago"` line (already present in real `iw scan dump` output) into `age =
  floor(N / 1000)` seconds; `inform.lua` sends that instead of a timestamp.
- **Confirmed live against the running controller (2026-07-14):** with both fixes applied, adopted
  fresh (full `docker compose down -v` + `up -d --build` reset), pointed `iw-mock.sh` at three fake
  neighbor BSSes across both radios (`tools/validation/ap/iw-mock.sh`, mirroring its established
  shadow-the-real-binary pattern for `survey dump`/`station dump`). Verified in order:
  1. `inform.lua` ran cleanly with no POST failures once the `mgmt_url` fix was in place (previously
     crashed permanently on the very first post-adopt `setparam`).
  2. Direct `GET /api/s/default/stat/rogueap?start=...&end=...` (executed via the browser's own
     authenticated session, `javascript_tool` + `fetch`) returned all three fake neighbors with
     fully correct fields — `age: 0`, correct `bssid`/`essid`/`channel`/`security`/`signal`/
     `radio`/`radio_name`/`ap_mac` — proving the backend ingestion path (`PGOcbDWlbnYQdFW` →
     `hhFgUVZPT` → cache) accepts and correctly stores openUF's payload end-to-end.
  3. Also confirmed (from the same decompile) that `is_rogue` is a much narrower concept than the
     tab's name suggests: it's only set `true` when a neighboring BSSID broadcasts the **same
     essid as one of the site's own configured networks** (an evil-twin/spoofing check that raises
     an `EVT_AP_DetectRogueAP` alert), not "any third-party network nearby." Ordinary neighbor
     networks (openUF's fake ones included) are expected to have `is_rogue: false` and still appear
     in the general Environment scan list — confirmed they do, per point 2.
- **Real bug #3 (RESOLVED 2026-07-14): the Environment tab's own table rendered "No WiFi broadcasts
  found" despite the API returning data — root-caused by decompiling the controller's own React
  bundle, not just its backend jar.** Downloaded and grepped every `.js` chunk the `wifiScanner`
  route loads (`react-app-wrapper.*.js` turned out to hold the relevant module). Found the actual
  list selector applies an *unconditional* filter, upstream of every visible sidebar filter:
  ```js
  S=(0,s.Mz)(p,A=>A.filter(A=>!!T.R?.[A?.band]?.[A?.bw>0?A.bw:m.L?.[A?.band]]))
  ```
  This indexes a per-band/per-channel-width lookup table by **`A.band`** — a field distinct from
  `radio`, which openUF's payload never sent at all. `T.R[undefined]` is `undefined`, so
  `!!undefined` is `false` for every entry, unconditionally, regardless of any sidebar filter state
  — indistinguishable from "no data" in the UI, even though the API response (confirmed in point 2
  above) was correct and complete the whole time. The same bundle's own enum definition
  (`function(e){e.RADIO_NA="na",e.RADIO_NG="ng",e.RADIO_AD="ad",e.RADIO_6E="6e"}`) confirmed `band`
  takes the exact same string values as `radio`. **Fix:** `inform.lua` now sends
  `band = radio.radio` alongside `radio`/`radio_name` on every `scan_table` entry.
- **Confirmed live after the fix:** reloading the Environment tab showed a real row — "Channel 36",
  "802.11n/a/be" — and the previously-static, greyed-out **Channel** and **Security** sidebar
  filters populated with real facets (`36`, `wpa2`), which they had never done before (a filter
  UI's own facet list appears to derive from the same now-populated dataset, so their prior
  permanently-disabled appearance was itself a symptom of this bug). Reproduced this successfully
  twice across separate page loads.
- **Correction (2026-07-14, prompted by the user questioning the first write-up of this): the
  disappearing row is a real controller-frontend bug, not backend cache timing, and not
  "expected live behavior" — that initial framing was wrong and too quick.** Verified properly:
  - Polled `stat/rogueap` directly (bypassing the UI entirely) 10 times over 23 real seconds, 2–3s
    apart: **10/10 returned all 3 entries**, no misses, no staleness. The backend/API never lost
    the data once.
  - Passively watched the mounted tab with **zero interaction**: row visible at page load; by ~10s
    later, "No WiFi broadcasts found" and the Ch. Width/Channel/Security sidebar filters greyed out
    again — with no click, no reload, nothing triggered by the user in between.
  - Clicking a *different* Time Range tab (`1h`) at that point **instantly restored everything**:
    the row reappeared, a correct signal-vs-channel curve rendered on the graph, and all sidebar
    filters repopulated with real facets (`80`, `36`, `wpa2`).
  - Conclusion: the data is reliably present server-side the entire time (confirmed both by direct
    polling and by the fact that a mere tab click — not a new inform, not new data — instantly
    fixes the display). Something in the frontend's own component state gets stuck a few seconds
    after mount and does not self-heal on its own; only a manual filter/tab-triggered re-render
    recovers it. Plausible mechanism from the decompiled bundle: the table's pagination state
    (`useState({pageNumber:0,from:0,rowsPerPage:r.length})`) captures `rowsPerPage` from the
    *current* (pre-fetch, empty) selector result at mount time and never recomputes it, so once the
    real data arrives the client-side `.slice(from, from+rowsPerPage)` keeps clipping it to nothing
    until something else (a tab change) resets the pagination state. Not confirmed via React
    DevTools/live debugging, but consistent with every observation above.
  - This is a genuine defect in the controller's own web application, entirely outside openUF's
    control (proprietary compiled frontend, not something a device's wire payload can influence)
    — but it is a real, reproducible, unprompted bug, and a real (if narrow) UX problem for anyone
    passively watching this tab. Not something to wave away as "expected."
- **Real bug #4 (found by the user visually inspecting the live UI after bug #3's fix, RESOLVED
  2026-07-14): the rendered row's "Ch. Width" column was blank.** Same frontend bundle, same table's
  column definitions:
  ```js
  {id:Nt.ye.BW, ..., renderCell:({bw:A})=>A?(0,n.jsxs)(Pt,{children:[A," ",(0,n.jsx)(k.sA,{id:"COMMON_UNIT_MHZ"})]}):null, ...}
  ```
  The cell reads `bw` directly and renders nothing at all when it's falsy — openUF's payload never
  sent a `bw` field, only the filter-satisfying `band`. **Fix:** `sysinfo.lua`'s `scan_table()` now
  parses `iw`'s own `"BSS operating channel width: N MHz"` line (confirmed via `strings
  /usr/sbin/iw`; only present for HE/VHT-capable neighbors) into `bw`, defaulting to `20` (legacy-
  safe, valid for both bands) when a neighbor doesn't advertise it, rather than leaving the wire
  field absent and the column blank. `inform.lua` sends `bw = net.bw or 20` per entry.
- **Confirmed live:** reloaded the Environment tab after redeploying — the 5 GHz row rendered "Ch.
  Width: 80 MHz", matching the fake neighbor's mocked `iw-mock.sh` width line exactly (the 2.4 GHz
  neighbors, which have no width line in the mock, fall back to the 20 MHz default).
- **Code changes:** `openuf/sysinfo.lua` (`M.scan_table()`: `age`, `band` support via `radio`, `bw`
  parsing/default), `openuf/inform.lua` (`scan_radio_table` in `build_json()` including `band`/`bw`,
  `mgmt_url`/`inform_url` fix in `handle_response()`), `tests/test_sysinfo.lua` +
  `tests/test_inform_json.lua` + `tests/test_inform_packet.lua` (new/fixed cases),
  `tests/fixtures/iw_scan_dump.txt` (new, includes a width line on one entry),
  `tools/validation/ap/iw-mock.sh` (fake `scan dump` entries, one with a width line). All 217 tests
  pass.

## 21. Radios tab ("We Couldn't Find a Match") + client MIMO column — decompile + two more real bugs (2026-07-14)

- **Status:** ✅ Radio hardware-capability fields (`nss`/`is_11ac`/`is_11ax`/`is_11be`/`has_dfs`/
  `has_fccdfs`/`has_ht160`/live `channel`) and per-station `radio_proto`/`nss` both implemented,
  unit-tested, and confirmed correct live. The Radios tab's "We Couldn't Find a Match" turned out to
  be two separate things: a real openUF gap (missing radio capability fields, now fixed) and a
  controller UI/filter-semantics red herring (the "Type: Wired/Meshed" filter defaults to showing
  nothing until one is explicitly checked, unlike every other filter on the same page — not a bug).
- **"Type: Wired" filter reframing (user-caught):** checking "Wired" under Type unexpectedly
  revealed the device's two radio rows. This looked backwards (a WiFi radio showing under "Wired")
  until reframed correctly: "Type" here means the **AP's own uplink connection type** (matches the
  row's own "Uplink: GbE" column), not the radio's wireless/wired nature — our AP is genuinely wired-
  uplinked, so "Wired" is the correct bucket. Unlike Band/MIMO/Status on the same page (empty
  selection = show all, confirmed by testing each), the Type filter's empty state shows nothing —
  an inconsistent, confusing default in the controller's own UI, not an openUF-side defect.
- **Real bug: radio_table never carried hardware capability fields at all.** Confirmed via decompile
  (`com.ubnt.service.devmgr.PGOcbDWlbnYQdFW`, `copyAttrsIfPresent`) that the controller reads
  `nss`/`is_11ac`/`is_11ax`/`is_11be`/`has_dfs`/`has_fccdfs`/`has_ht160`/`has_eht240`/`has_eht320`
  directly off each incoming `radio_table` entry, independent of `radio_caps`/`radio_caps2` — openUF
  sent none of them. **Fix:** new `sysinfo.radio_caps(ifname)` resolves the radio's wiphy index via
  `iw dev <ifname> info` and parses `iw phy phyN info` for these fields (`VHT Capabilities`/`HE PHY
  Capabilities`/`EHT PHY Capabilities` section presence, `radar detection` per-frequency annotation,
  `Supported Channel Width: ... 160 MHz`, and `HT TX Max spatial streams: N` — falling back to
  counting `N streams: MCS ...` lines when that summary line is absent), all derived from the real
  board's own driver/firmware report, not invented. Also returns the live negotiated `channel`
  (from `iw dev`'s own "channel N (...)" line), which is more authoritative than UCI's own config
  value (frequently the literal string `"auto"`, which the controller does not resolve to a number).
  Confirmed correctly persisted via direct Mongo/API checks on both a reused and a fully fresh
  (never-adopted-before) device — capability fields alone were not sufficient to make the Radios
  table show data; see "Type" filter finding above for why.
- **Real bug: per-station `radio_proto`/`nss` were never sent, only `tx_mcs`/`rx_mcs`.** Confirmed
  via decompile that the real controller's client updater (`com.ubnt.service.devmgr.TtZhv`) reads
  `radio_proto` and `nss` as independent per-station wire fields — neither is derived from
  `tx_mcs`/`rx_mcs` on the controller's side. Without them, every station showed generation `"g"`
  (the controller's own fallback default) and no MIMO/stream-count data at all in the client list's
  Technology column, regardless of what `tx_mcs`/`rx_mcs` said. Root-caused after ruling out several
  false leads (see "Debugging false starts" below).
- **Fix:** `sysinfo.lua`'s `sta_table()` now derives `{tx_generation, tx_nss}` (and the `rx_*`
  equivalents) from `iw`'s own tx/rx bitrate line tokens: bare `MCS N` → generation `"n"`, nss =
  `floor(N/8)+1` (real HT MCS-index layout — MCS 0-7 is 1 stream, 8-15 is 2, ...); `VHT-MCS`/
  `VHT-NSS` → generation `"ac"` with nss read directly; `HE-MCS`/`HE-NSS` → `"ax"`; `EHT-MCS`/
  `EHT-NSS` → `"be"` (confirmed real `iw` format strings via `strings /usr/sbin/iw`). Legacy
  (pre-MCS) rates carry no generation token at all; `inform.lua` falls back to the known radio band
  (`"a"` for `na`, `"g"` for `ng`) in that case only — never `"b"`, since real dual-band 11n+
  hardware doesn't negotiate down to 802.11b-only rates.
- **Confirmed live:** a brand-new, never-before-seen fake station (VHT/HE-MCS, NSS 2) and the
  existing MCS-6/MCS-15 stations all show up in the client list's Technology column with `mimo:
  "MIMO_2"` / `"MIMO_1"` matching their real stream counts exactly — the original "missing values"
  the user spotted. **`radio_proto` itself still shows the coarser band letter ("g"/"a") instead of
  the finer generation ("n"/"ac"/"ax")** despite being sent correctly (confirmed via the same live
  check) — a smaller, separate residual gap, not chased further this session; `mimo`/`nss` was the
  concrete, user-visible problem and is resolved.
- **Debugging false starts, recorded so they aren't re-walked:**
  1. Deleting a stale client record and waiting for it to "reappear on next inform" (the established
     wired-client pattern) does **not** apply the same way to wireless clients in this validation
     setup — they simply never came back, even after 45+ seconds. Not resolved; worked around by
     recreating the whole WiFi network instead (see next point).
  2. `tools/validation/ap/uci-mock.lua` is an **in-memory-only** mock, explicit in its own header
     comment: its `db` table is seeded fresh per-process and only ever one-way-dumped to a debug
     JSON file on `commit()`, never read back. Restarting `inform.lua` to pick up new code silently
     wipes any WiFi network config that was only ever pushed to the *previous* process's memory —
     any fresh throwaway `lua5.1 script.lua` invocation (including ones that call `apply_config`
     directly and appear to "work") is **also** a brand-new process with its own pristine mock state,
     completely disconnected from the live daemon. Neither proves anything about the live process's
     actual state. The only reliable way to verify live per-cycle wire data in this setup is to check
     what the **controller actually received** (Mongo/API), never a fresh local script.
  3. Following directly from (2): after restarting the daemon for this session's code changes, the
     previously-created WiFi network was gone from the live process's memory, so no new wireless
     clients (old or new) could be reported at all — mistaken at first for the code fix not working.
     Recreating the WiFi network (delete + re-create, since the in-place edit panel's fields were
     mostly disabled for this network) re-pushed a fresh `system_cfg`, and the live daemon picked it
     up correctly, closing the loop.
- **Code changes:** `openuf/sysinfo.lua` (`sta_table()`: `tx_generation`/`tx_nss`/`rx_generation`/
  `rx_nss` derivation), `openuf/inform.lua` (`radio_proto`/`nss` per sta_table entry),
  `tests/test_sysinfo.lua` + `tests/test_inform_json.lua` (new cases for HT/VHT/HE/legacy
  derivation), `tools/validation/ap/iw-mock.sh` (wlan1's fake station now uses realistic VHT-MCS/
  VHT-NSS tokens instead of bare MCS, matching real 5GHz hardware). All 224 tests pass.

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
