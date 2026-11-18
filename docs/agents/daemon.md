# The inform daemon: landmines

Part of the agent notes: [CLAUDE.md](../../CLAUDE.md) is the index and holds the hard constraints.

Read before changing `inform.lua`, `announce.lua`, `state.lua`, `sysinfo.lua`, `crypto.lua`,
`stun.lua`, `util.lua`, the capability masks, or any module the controller drives through a push
(`sysconf`, `remotelog`, `applyguard`, `nrlist`, `devlogin`, `guestportal`, `unhandled`).
Wireless provisioning is in [wireless.md](wireless.md); VLANs and the switch in
[network-and-switch.md](network-and-switch.md).

- **Everything the controller sends that openUF does not act on goes to the unhandled
  ledger, always.** `handle_response` records an unknown `_type` or `cmd` with its whole
  body, unknown top-level fields, and (through `_report_dropped_keys`) every `mgmt_cfg` key
  and `system_cfg` key shape no parser reads, into `unhandled.lua` → `/etc/openuf/unhandled.json`.
  So: implementing a new cmd or key means adding it to the dispatch or to `RECOGNIZED_*`, or
  it keeps being counted as ignored -- which is the honest state until it IS implemented.
  The ledger redacts by field NAME (`psk`, `passphrase`, `authkey`, `token`, `*key`...), so
  never hand it a payload whose secret sits under an innocent name, and never name a
  payload field of your own `*_key` (the first version did, and redacted its own sample).
  The `noop`'s `interval` is honoured (clamped 1–300 s since 2026-11-03: a watched device
  that reports `inform_min_interval: 1`, as `build_json` does, is asked for 1 s heartbeats);
  `_tick` re-reads it every cycle.
- **`syswrapper.sh 11k-scan` does not scan. It leaves a dated request file** (`/tmp/openuf-
  scan-request`) that the daemon's `_maybe_scan_neighbours` consumes on the next heartbeat,
  ignoring anything older than ten minutes. Every sweep goes through `_force_scan`
  (`iw dev <if> scan ap-force`, exit status judged through `_popen`'s `&& echo scan-ok`):
  `_popen` drops stderr, so before that a refused scan looked exactly like a successful one. The scan code, the radios' netdev names and the
  cache the result lands in all live in the daemon; a second implementation in the hook
  would drift. A request older than the cutoff is what a stopped daemon leaves behind, and
  firing it at the next boot would land in hostapd's ACS sweep.
- **A capability bit is claimed only where a device-side probe passes**, and the probe is
  cached: `sae_supported` (`radio_caps2` 0x1/0x2), `owe_supported` (0x8), `airtime.supported`
  (`wifi_caps` 0x20), `ppsk_supported` (0x100000), `hs20_supported` (`fw_caps` 0x800000 +
  `fw2_caps` 0x80000). `wifi_caps` 0xC, `wifi_caps2` 0x60|0x10|0x400000 and `fw_caps`
  0x100000|0x80000000 are unconditional because they only make the controller *send* blocks
  openUF parses (the `fw_caps` landmine below says why the last one makes the field negative). The
  controller keeps a setting it could not push (upstream found `atf_enabled: false` stored
  from before the bit existed), so a newly claimed bit can change device state on the first
  push after an upgrade. `debug_caps` replaces a mask whole. PROTOCOL-VALIDATION.md's
  "Capability bitmasks" lists what every other bit would unlock and why it is not claimed.
- **`_forget_controller` is what a factory reset owes the kernel.** `setdefault` and an
  out-of-process `reset-inform` (seen by `_reload_if_changed` as adopted → not adopted) both
  drop the controller's interval, the l2guard table, the cron block and put Airtime Fairness
  back on. A new controller-driven kernel or system state belongs in that function too, or a
  forgotten AP keeps acting for a controller that no longer manages it.
- **Four modules of 2026-11-17 follow antoniocosta/unifi-openwrt, and three of them are opt-in
  for a reason** (PROTOCOL-VALIDATION.md § Adopted from antoniocosta/unifi-openwrt has what is
  theirs and what was run here: the test VM only).
  - `remotelog.lua` + `logfwd.lua`: the `syslog.*` block. Plain goes to logd's UCI options,
    stamped and reversible. Encrypted is a forwarder process (`logread -f | lua logfwd.lua
    <conf>`), an orphan like rrmscan's collector: started by `_remotelog_resync` (once a minute
    while `st.remotelog.encrypt`, which is also what restarts it after a reboot), stopped by a
    push that turns it off, `_forget_controller` and the init script. **`forwarder_stop` kills the
    wrapper's children first** (`pgrep -P`): `logread -f` names nothing of ours and outlived its
    reader on the VM. The key reaches the forwarder through a 0600 file made empty, chmod'ed, then
    written; `probe.lua` strips it from the state it shows. `fw_caps 0x1000000` and `hash_id` are
    behind `encrypted_syslog` because the bit is not this tree's own finding.
  - `applyguard.lua` (`apply_rollback`): the copy in `/etc/openuf/rollback` is the last
    CONFIRMED configuration, so a second push while one is undecided must not replace it
    (`_applyguard_begin`). **netifd's `up` is not evidence**: it stayed true for a radio hostapd
    had refused; `radio_state` counts AP interfaces whose `hostapd.<ifname>` object is on ubus
    and not DISABLED (a CAC in progress is alive). A rollback restores three files, reloads, and
    ENDS THE DAEMON (`M._exit`) so the startup reapply list rebuilds everything; it keeps the
    undone push's cfgversion on purpose (reporting the old one is a push/rollback loop).
    `_applyguard_tick` is the one tick stage whose error is printed rather than swallowed.
  - `nrlist.lua` (`neighbour_list`, on): does nothing where `usteer.filter_wanted()` is true,
    because usteer writes the same hostapd list. Siblings come from `scan_table`'s `peer_mac`
    via `observe` in `build_json`; `_deny_reloaded` brings the next sync forward because
    hostapd forgets the list with the BSS. "No own neighbour entry" is both "802.11k off" and
    "BSS not up yet", so it is retried only for three minutes after a reload.
  - `devlogin.lua` (`device_login`): a uid-0 account from controller data. The trust flag is
    read at the TOP of the setparam branch (`trusted_response`), before the response can adopt
    the device; never move that read below the mgmt_cfg parse. Only names in
    `st.device_logins` are ever changed; `_forget_controller` needs `prev` for that ledger.
- **The guest portal is upstream's code at upstream's head, and it is in three places.**
  `guestportal.lua` (the nft tables `bridge openuf_guest` + the HTTP redirector + the walled
  garden's parser and resolver), the `_guest_*` section of `inform.lua`, and `_idle`, which now
  selects on the portal's listening socket as well as the STUN socket. It builds nothing until
  a push carries a guest WLAN with `redirector.status=enabled`. `nslookup` blocks and the loop
  is single-threaded: the garden's resolver is bounded (`GUEST_WG_BUDGET`, `WG_MAX_SITES`, the
  name list's signature) and those bounds are why. `_guest_selfrun` counts unanswered informs
  (`M._inform_fails`) and STUN stops in selfrun, as the firmware's does. `M._socket()` is
  evaluated BEFORE the pcall around `gp.listen`, so tests need LuaSocket or the harness's
  stand-in. Lab-validated only upstream; nothing of it has run on AP1/AP2.
- **`sysconf` installs only commands in `CRON_COMMANDS`.** A pushed cron line is a string
  crond runs as root; the controller's is `syswrapper.sh 11k-scan`, and that maps to the
  verb this tree ships. Extend the table only alongside a new verb, never to "pass through".
- **`state.save` writes the whole table and `state.load` reads all of it back.** Eight
  fields are type-checked with defaults; everything else round-trips as-is. That
  symmetry is load-bearing: `swvlan_backup` (the switch reversibility ledger), `ip_mode`
  and the `static_*` fields, `locating`, `led_enabled` and the previous run's `mac` all
  live there, and `_warn_identity_change` only works because the previous MAC comes back.
  `load()` used to whitelist the eight and drop the rest on every start. The write is
  temp-file-and-rename, because a truncated file reads as "defaults" and un-adopts the
  device.
- **The inform loop is `_tick()`, and every stage in it is pcall-wrapped.** `build_json`
  shells out to a dozen tools; one nil in one field once crash-looped the daemon under
  procd. A bad cycle costs one heartbeat and one log line. Keep new stages inside the
  boundary, and keep `M.run` as nothing but the sleep loop around `_tick`.
- **Wire values that reach a shell are shape-checked first.** `netconf.1.ip`, the netmask,
  `route.1.gateway`, block-sta's `resp.mac`, the bcfilt allow-list and the MAC filter all
  go through `is_ipv4`/`is_mac` at the parser *and* again in netconfig/firewall/bcfilter.
  Pre-adoption the inform channel is plain HTTP under the well-known key, so a forged
  `setparam` is within reach of anyone on the path; without these it was a root shell.
- **`debug_caps` / `debug_payload_extra` are the one sanctioned exception to "never claim a
  capability you cannot honour".** They exist so the mesh go/no-go experiment is a
  `conf.lua` edit; the daemon shouts at startup while either is set. Never ship a default
  for them, and never let a real feature depend on them.
- **`ubus call network.wireless status` is cached per `build_json` pass** (`begin_pass` /
  `end_pass`), and `iw phy phyN info` per phy with a five-minute TTL in sysinfo. Both
  caches are dropped after `wifi reload`; `phy_caps` additionally re-reads for a minute
  after a regdomain write, because the driver applies the new domain only when the
  radios come back up. Tests that stub `_popen`/`_run_cmd` must reset these (the harnesses
  do).
- **sysinfo has the same lookup pass, and two TTL caches.** `sysinfo.begin_pass` is opened
  at the very TOP of `build_json` (before the uptime read) and closed on return and in
  `_tick`; inside it `/proc/net/arp`, `/tmp/dhcp.leases`, `/proc/uptime`, each `bridge fdb
  show br` dump and the bucketed ARL/FDB (`hosts_by_port`) are read once per payload.
  The default gateway's IP is cached for `UPLINK_TTL` (300 s) -- **a nil answer is never
  cached**, boot is full of them -- and `forget_uplink_cache` still runs after a switch
  push. `bridge_of` is a live sysfs read since 2026-10-18 (`util.master_of` on
  `/sys/class/net/<if>/master/uevent`, no `readlink` fork, no memo); `lan_bridge` resolves
  `lan_cpueth` whether it names the bridge or a socket, and is what inform's DSA paths
  call. The parsed phy caps live in the same cache entry as the dump's text.
  `lldp.neighbors` is **not cached at all** (the user's rule, 2026-10-18: anything the
  controller shows follows reality on the next heartbeat; upstream's 60 s cache, empty
  answers included, was taken out again -- one lldpctl fork per 10 s is the accepted
  price, and the same rule applies to any future "report it a bit later to save a fork"
  trade -- the sibling-tag cache and the hourly beacon requests went the same way; the
  goal is the most accurate emulation, so what a real AP does by design, like spreading
  the nightly 11k-scan over the hour, is kept). `ucihelper.get_radio_table` reads the wifi-device rows once
  per pass and hands each caller a COPY. `ucihelper.begin_pass` is nest-safe: `_tick`
  opens ONE pass from its first resync to the payload and `build_json` only closes a pass
  it opened itself. Outside a pass everything reads every time, which is what keeps
  per-test stubs independent; harnesses reset `_uplink_cache`, `_phy_info_cache`, the lldp
  caches and call `end_pass()` on the way in and out.
- **The reported address is read every heartbeat, not once.** `_populate_net_info` runs at
  startup, and on a DHCP-managed AP that is before the lease: START=99 is after `network`,
  but udhcpc is still broadcasting its DISCOVER (AP1, 2026-10-26: udhcpc started 01:18:41,
  the lease arrived :44), so `st.ip` stayed nil and every inform carried `ip "0.0.0.0"` --
  the controller showed both APs at 0.0.0.0 until a lucky reboot. `_refresh_net_info` in
  `_tick` asks `announce.get_ip` again before each payload (one `ip addr` per cycle, the
  holder cached), keeps the last address on a nil read, and logs each change. The announce
  module is loaded once (`M._load_announce`, `M._announce`); tests stub `inform._announce`.
- **Kernel state is rebuilt at startup, because the controller never re-pushes it.** After
  a reboot `cfgversion` matches and the reply is `noop` with no `system_cfg`, so anything
  applied only from `apply_config`/`handle_response` is gone for good. `M.run` therefore
  reapplies, in order: the pushed static IP (`_reapply_static_ip`, before
  `_populate_net_info`), the bridge identity (`ensure_bridge_identity`), the blocked-client
  rules, the blocker and speed limit from the `openuf_bcfilt*`/`openuf_ratelimit_*` stamps
  (`reapply_runtime_rules`), the LED state, Airtime Fairness from `st.atf_enabled`
  (`_reapply_airtime`; debugfs resets to on), the nft MAC tap
  (`switchvlan.reconcile_mac_taps`, from the `openuf_brport<vid>_<socket>` sections) and the
  l2guard table from `st.l2guard`, whose VAP list `_l2guard_resync` then corrects once a
  minute. Every one is pcall'd. A new kernel-resident feature belongs in that list or it is a
  reboot bug.
  The IP branch of `handle_response` saves state the moment the interface changes, not at
  the tail: anything after it can raise, and the startup reapply reads what was saved.
- **Every openUF nft table is rebuilt in ONE `nft -f` transaction** (`util.nft_apply`):
  `add table` + `delete table` + the new statements in one commit, so a blocked client
  never slips through between the delete and the rebuild. When the batch is rejected the
  statements are re-run one at a time so the warning can name the rule (the
  `kmod-nft-bridge` case). Tests capture the script through the runner's `fake_nft`,
  which expands `nft -f <file>` into its statements; a module's `_exec` seam gets the
  `nft -f` line, never the statements.
- **The controller's wake-up is STUN, and openUF is the client** (`stun.lua`): a Binding
  Request with CHANGE-REQUEST every 30 s to `mgmt_cfg stun_url`, the mapped address out as
  `connect_request_ip`/`port`, and a type `0x8888` datagram back is "inform now". `_idle`
  is the one place that sleeps: it selects on the STUN socket, and while roam reports are
  on it also wakes every 250 ms for `_roam_poll`. Keep every wait inside `_idle`.
- **AirView needs two things the heartbeat cannot give.** Connection stages
  (`assoctrack.lua`) ride in `notif` informs, one POST each, sent only after the state
  inform and only while `st.notif_assoc_stat` (from `mgmt_cfg capability`) is true; roam
  reports must reach the controller within a second of the event, which is what the
  250 ms poll is for. `wifi_caps2` `0x2000` is claimed ONLY while those reports are sent --
  with it and no reports every roam vanishes from the controller. `_post_notif` (a finished
  RF sweep) is the other notif path; the two share nothing but the envelope.
- **A `setdefault` or `reset-inform` now tears the controller's config DOWN**
  (`_forget_controller(prev, cfg)` → `ucihelper.forget`, `switchvlan.restore`, usteer
  off, LED back). It needs the state from BEFORE the reset (`prev`): the per-port VLAN
  ledgers live only there. Anything new a controller leaves in UCI or the kernel belongs
  in `ucihelper.forget` or that function.
- **`_sta_stats_cache` holds the Experience window only** (`satisfaction.lua`): the
  firmware's retry term moves once a minute from the `_mov` deltas, so a station scores
  100 on retries until its first full minute. Capacity, throughput, linkscore and
  multicast are not sent any more; a test that expects them is wrong.
- **AES-GCM is mandatory for adoption.** UniFi 10.4.57 will not finish provisioning a
  device that has never sent a genuine GCM inform; a CBC-only device sticks at "Adopting"
  forever. Needs a GCM-capable `lua-openssl`. There is no `openssl` CLI fallback any more
  (PR #6: it put the authkey on a command line); with no binding `crypto.lua` uses
  `aeslua.lua`, AES-128-CBC in plain Lua, which is what lets the suite run on a dev machine
  whose Lua has no lua-openssl rock (Lua 5.5 has none) and is CBC-only, slow and not
  constant-time -- a device that reaches it has a broken install and says so on stderr.
  Byte-identical to lua-openssl on the test VM, both directions.
- **`fw_caps` goes out SIGNED.** Bit `0x80000000` (MAC-based VLANs) sets the sign bit of a Java
  `int` on the controller side; `0x80101110` as an unsigned 2148537104 is out of range for the
  deserializer, so the sum is written as `0x101110 - 0x80000000 + ...` (a genuine gateway reports
  its own caps negative too). `debug_caps.fw_caps` still replaces the whole value. The other
  bits claimed since 2026-11-02 and why: `fw_caps 0x100000` (RADIUS DAS: hostapd is the
  listener), `fw_caps 0x800000` + `fw2_caps 0x80000` (Hotspot 2.0 + RadSec, both behind
  `sysinfo.hs20_supported`; RadSec is NOT implemented, the claim only makes a RadSec server
  arrive distinguishable so it can be dropped), `wifi_caps2 0x10` (auto-channel limits) and
  `0x400000` (Multicast Suppression's three positions). Each one is a controller feature that
  pushes nothing at all without the bit.
- **`_state_mtime` is the file's CONTENTS, not an mtime**, and nothing forks `stat` any more
  (BusyBox may have no applet; contents beat one-second mtime granularity anyway).
  `coreutils-stat` is no longer installed. `conf.lua`'s `inform_url` seeds
  `state.DEFAULT_INFORM_URL` and only fills a `state.json` with no URL of its own.
  `debug_dump_file` is capped at `debug_dump_max_bytes` (4 MiB, restart with a marker line,
  never rotate). `inflate` RAISES on a truncated stream -- it used to feed zero bits and
  spin forever inside a pcall nothing could interrupt.
