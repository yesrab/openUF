# File map

Part of the agent notes: [CLAUDE.md](../../CLAUDE.md) is the index and holds the hard constraints.

What each file is for.

```
openuf/
  conf.lua          modelmap + ufmodel selection, runtime options (user-editable)
  modelmap/*.lua    hardware profiles          ufmodel/*.lua  UniFi identities
  inform.lua        TNBU inform loop, response dispatch, payload assembly (the core)
  announce.lua      L2 UDP discovery broadcasts (port 10001)
  crypto.lua        AES-128-CBC/GCM            inflate.lua  pure-Lua zlib inflate
  aeslua.lua        AES-128-CBC in plain Lua: crypto.lua's path when no binding is installed
  ucihelper.lua     all wireless UCI writes (VAPs, radios, VLAN networks)
  sysinfo.lua       /proc, iw, swconfig and bridge-fdb parsing; the per-payload lookup
                    pass and the 300 s uplink cache; the nft MAC-tap reader
  switchvlan.lua    per-port VLAN assignment: switch_vlan sections on swconfig, a bridge
                    move + learning off + nft tap (`bridge openuf_learn`) on DSA
  netconfig.lua     controller-pushed IP settings   led.lua  Locate / LED toggle
  firewall.lua      client block/unblock (nft `bridge openuf`)
  bcfilter.lua      multicast/broadcast blocker (nft `bridge openuf_bcfilt`)
  shaper.lua        WiFi speed limit: per-client HTB classes on the VAP (download) and an
                    IFB device (upload), synced every heartbeat from what build_json listed
  usteer.lua        band steering + the nft filter keeping usteerd's sync off the VAPs
  lldp.lua          neighbour table via lldpctl, read fresh every heartbeat (no cache, by
                    decision -- see the lookup-pass landmine in daemon.md)
  rrmscan.lua       802.11k beacon-report neighbour enrichment; the hostapd event collector
                    (ubus subscribe + control-socket monitors + `bridge monitor fdb`) that
                    assoctrack reads too
  satisfaction.lua  WiFi Experience: the UniFi firmware's formula (libubnt 4.0.15)
  assoctrack.lua    AirView Connectivity stages and Roaming reports as notif informs
  minrssi.lua       Minimum RSSI: refusal margin, 30 s hold before the kick
  loadbalance.lua   Load balance: the most idle stations above a radio's cap
  wlansched.lua     WiFi Blackout Schedule: the firmware's schedule lines, netdev down/up
  stun.lua          the STUN client whose mapped address the controller wakes
  rrbguard.lua      repairs hostapd's stale 802.11r key-exchange socket (wpad restart)
  plugins.lua       the third-party plugin hook: upstream's api-1 `vap_options(extra, vap,
                    ctx)` contract as it is (a plugin written for upstream runs here), the
                    list from conf.lua / UCI `list plugin` / /etc/openuf/plugins.enabled,
                    the fingerprint inform re-pushes on; PLUGINS.md is the author guide
  util.lua          shared helpers: file/command reads, exec_ok, is_mac, bit shim, sysfs
                    master_of/driver_of, nft_apply (one `nft -f` transaction per table)
  unhandled.lua     /etc/openuf/unhandled.json: every _type, cmd, mgmt_cfg key and
                    system_cfg key shape the controller sent that nothing here acted on,
                    with counts and a redacted body -- always on, bounded
  sysconf.lua       controller-managed system settings: system.timezone and ntpclient.*
                    into UCI (stamped, reversible), cron.* into a marked block of
                    /etc/crontabs/root (allow-listed commands only: `syswrapper.sh 11k-scan`)
  guestportal.lua   the guest portal (Hotspot): nft `bridge openuf_guest` holding
                    unauthorized guests, the HTTP redirector served from `_idle`, the walled
                    garden by address and by resolved domain (upstream's, lab-validated only)
  remotelog.lua     the syslog.* block: a plain server into logd's UCI options (stamped),
                    "this controller, encrypted" as AES-256-GCM datagrams; the forwarder's
                    start/stop and its 0600 key file
  logfwd.lua        that forwarder: `logread -f | lua logfwd.lua <conf>`, rate-limited
  applyguard.lua    rollback of a config push that broke the AP (opt-in): the copy in
                    /etc/openuf/rollback, the verdict (hostapd serving + an answered inform),
                    the restore
  nrlist.lua        the 802.11k neighbour list: scanned siblings and the other band into
                    hostapd's rrm_nr_set; inert where usteer runs
  devlogin.lua      Device SSH Authentication (opt-in): the pushed users.* login as a uid-0
                    account, only after adoption, only accounts it made
  mcsnoop.lua       IGMP/MLD snooping (config.igmp_snooping, opt-in): a U6 Pro's three bridge
                    values on the LAN bridge and br-openuf<vid>, sysfs only, ledger in /var/run
  l2guard.lua       the ebtables.* block as nft `bridge openuf_l2guard`: BPDU and 802.1Q
                    drop on the AP VAPs only; intent + names in state.json for the reboot
  backhaul.lua      the mesh (wireless uplink): plan of the WDS downlink/uplink sections,
                    the wired-first policy (switch port link on swconfig), the `uplink` report
  meshvlan.lua      swconfig only: a tagged SSID's VLAN over the mesh hop, as a runtime
                    `br-lan.<vid>` port behind nft `bridge openuf_meshvlan`
  state.lua         /etc/openuf/state.json (authkey, adopted, cfgversion, inform_url)
  lib/lib.lua       globals every script expects; wraps `bit` so the same source runs
                    on the device's Lua 5.1 (luabitop) and a 5.3+ dev interpreter
  uciconf.lua       /etc/config/openuf -> the `dev`/`config` tables when a `main` section
                    exists; a custom profile passes test_modelmap's invariants or is refused
  hook/             syswrapper.sh|.lua (set-adopt / set-inform / reset-inform),
                    adopt-shell.sh — the forced login shell for the bootstrap account,
                    which permits exactly `syswrapper.sh set-adopt <url> <key>` and
                    refuses everything else. That restriction IS the security boundary;
                    openuf-cli.sh (/usr/bin/openuf), probe.lua (`openuf probe status|
                    presets|discover|export`, the one source the LuCI app reads),
                    openuf-convert.sh (/usr/sbin/openuf-convert: setup.sh's AP
                    conversion as --check/--convert/--revert), openuf-deps.sh
                    (/usr/sbin/openuf-deps, `openuf deps`: what openUF needs
                    installed as JSON and the basic-to-full wpad swap), openuf-ota.sh
                    (`openuf ota`: the latest GitHub release, checked and installed
                    for either install kind; the LuCI overview's Updates section)
  etc/init.d/openuf procd service: announce + inform instances; finds either prefix
package/            the OpenWrt feed: openuf (net/), luci-app-openuf (the LuCI pages, the device
                    page htdocs/openuf/ and its gate root/usr/share/ucode/openuf/gate.uc) and
                    luci-theme-halo (see PACKAGING.md)
setup.sh            guided installer: AP conversion + deps + install
install.sh          file/service install and dependency resolution
update.sh           on-device updater (installed as openuf-update): backup, install keeping
                    conf.lua, restart, wait for /tmp/openuf-status, roll back on failure
tools/              dist.sh (package), check.sh (preflight), simulate.sh (e2e),
                    deploy.sh (push a build to adopted APs and run update.sh on each),
                    heartbeat-probe.lua (what one inform costs a board: forks and reads),
                    cfg-coverage.lua (replay a captured system_cfg through every parser and
                    sort each key into consumed / inert / ignored; the suite dofile()s it,
                    so dist.sh --verify copies tools/ into the verify tree),
                    fw-extract.sh (a UniFi MIPS AP firmware's rootfs: xz, cpio, binwalk),
                    fw-oracle/ (run a libubnt function under Unicorn to check a formula),
                    strip.lua, test_controller.py, validation/ (docker controller; the
                    radius/ files are upstream's FreeRADIUS profile for an EAP WLAN)
PROTOCOL-VALIDATION.md   evidence for every protocol claim — read before disputing one
REVERSE-ENGINEERING.md   the open questions: unimplemented surfaces + experiment plans
```
