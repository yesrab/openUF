# VLANs, the switch, bridges and mesh: landmines

Part of the agent notes: [CLAUDE.md](../../CLAUDE.md) is the index and holds the hard constraints.

Read before changing `switchvlan.lua`, `l2guard.lua`, `meshvlan.lua`, `backhaul.lua`, the VLAN
network code in `ucihelper.lua` or the uplink / wired-host code in `sysinfo.lua`.
The bridge-MAC and `lan_cpueth` rules are in [device-maps.md](device-maps.md).

- **`l2guard` protects the VAPs only, never a wired socket, by design.** The controller's
  `--vlan-id <n> -p 802_1Q -j DROP` is bridge-wide on the stock firmware because there the
  tagged uplink is an 8021q sub-device that takes tagged frames before the bridge sees them.
  On a DSA board openUF's tagged uplink is `br-lan.<n>`, ON the bridge, so tagged frames
  from the uplink socket traverse it -- a bridge-wide rule kills the IoT WLAN's uplink. The
  uplink socket is a runtime detection that is refused when unsure, so the rule stays on
  the interfaces the controller's other eight rules name: the VAPs.
- **VLAN ids must be below the switch's VLAN table size** (16 on some boards) — netifd has
  no `vid` option, so the id doubles as the table slot.
- **`uplink_detect = "fdb"` reads ONE bridge's FDB** (`sysinfo.lan_bridge` resolves
  `lan_cpueth` whether it names the bridge or a socket). The whole-FDB read took whichever
  learned line came first for the gateway's MAC, which on an AP with a tagged SSID can be
  the VLAN bridge's own port.
- **DSA per-port VLAN is a bridge move, never `bridge-vlan`.** `switchvlan.dsa_apply` moves
  the socket into `br-openuf<id>`; `ucihelper.ensure_vlan_network` owns the tagged uplink
  member and never evicts anyone else; `apply_config`'s `keep_vlans` keeps a wired-only
  VLAN's bridge alive. The ledger is `st.dsa_brlan_ports`, and a push with no `switch.*`
  keys counts as "off" only while a ledger exists.
- **A moved DSA socket, and the tagged uplink sub-device, run with MAC learning OFF, and
  that is not optional.** The VLAN bridge is software but the socket is a port on the same
  ASIC as the uplink, and the ASIC has ONE address table: with learning on it files the
  attached device against the socket and hardware-drops every VLAN-tagged reply to it,
  while outbound stays perfect and every counter says the move worked (upstream: 4 DHCP
  DISCOVERs out, nothing back; 2 ms OFFER with learning off). `dsa_apply` writes
  `openuf_brport<vid>_<socket>` (`learning '0'`), `ensure_vlan_network` writes
  `openuf_brport<vid>` for `<uplink>.<vid>`; both are swept by `prune_vlan_networks` and
  `dsa_restore`. The bill: that socket's hosts vanish from `bridge fdb`, the only
  wired-host source on DSA. `switchvlan.reconcile_mac_taps` pays it with an nft
  bridge-family tap (`table bridge openuf_learn`, sets `portmacs` and `portips`, 5-minute
  timeouts), read by `sysinfo.mac_table(ifname, bridge, allow_tap)` only when the FDB is
  silent and only for a socket whose bridge is not the uplink's. Rows carry `vlan` (from
  the `br-openuf<vid>` name) and the tap's `ip`, because the controller files a wired
  client under a network by `host.vlan` (default 1) and the AP has no ARP entry for a host
  on a VLAN it holds no address on. **None of this has run on a JioRouter yet.** The
  uplink socket stays silent, gateway included: one known MAC alone on a port lands in
  `downlink_table` and inverts the topology (feature 39 in PROTOCOL-VALIDATION.md).
- **On swconfig, mesh is two problems DSA does not have** (since 2026-10-18; first run on a
  Deco M4R v1 on 2026-10-19: untagged, online over the air with the cable pulled). (1)
  `br-lan`'s wired port is the CPU trunk's sub-device, whose carrier never
  drops: the uplink policy must read the socket's link from the switch
  (`st.backhaul_wired_phys`, `backhaul.tick`), and on a switch between wire and air the
  bridges are flushed by hand. (2) The VLAN bridges ride `eth0.<vid>`, so a tagged SSID
  needs `br-lan.<vid>` as a second uplink over the hop -- and that port next to `eth0.1` is
  a loop (`br-lan` -> `eth0.1` double-tags, the switch strips the outer tag onto the
  uplink). `meshvlan.lua` therefore keeps it runtime-only and strictly behind nft `bridge
  openuf_meshvlan` (802.1Q in or out of `br-lan` through wireless ports only): guard in
  before the port, port out before the guard, one atomic `nft -f` (not `util.nft_apply`,
  whose fallback deletes the table first). Never move that port into UCI: netifd would
  bring it up at boot, before any guard exists.
