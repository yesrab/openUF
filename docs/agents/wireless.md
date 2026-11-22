# Wireless provisioning: landmines

Part of the agent notes: [CLAUDE.md](../../CLAUDE.md) is the index and holds the hard constraints.

Read before changing `ucihelper.lua` or anything that provisions, steers, limits or schedules a
WLAN or a radio (`usteer`, `roamassist`, `shaper`, `minrssi`, `loadbalance`, `wlansched`, `rrmscan`).

- **One VAP can be several netdevs.** An OWE-transition section brings up a second, open BSS
  that netifd's status never lists (read from `hostapd bss_info`), and each private
  pre-shared key VLAN gets `<vap>-<vid>` (listed under the interface's `vlans[]`).
  `get_ifnames_for_vap` returns all of them, and stations, the blocker and the shaper must
  cover all of them; `get_ifname_for_vap` (singular) is only for something that addresses the
  hostapd BSS itself. A station seen on a VLAN netdev is kicked or BTM-requested through its
  BSS (`bss_ifname`), which is the only place hostapd listens.
- **Roaming Assistant and Band Steering share usteer but not its decision.** `usteer.lua`
  writes `band_steering_interval` (0 = off; the daemon default steers) and never the inert
  `band_steering_threshold`; `roamassist.lua` reads usteer's cross-AP table and sends its own
  BTM request and disassociation, per WLAN, only toward an AP that hears the client
  `roam_assist_diff_db` louder. `usteer.set_enabled(steering, cfg, roam_assist)` runs the
  daemon for either.
- **`get_vap_table` reports AP-mode sections only, and `use_only_unifi_wlan` never touches
  a non-AP one.** A mesh point or station interface (a wireless backhaul) is a link, not a
  competing SSID, and may be the device's own uplink. `keep_wlan_sections` exempts named
  AP sections. Each VAP reports its own BSSID via `get_ifname_for_vap`, not the radio's
  first interface's.
- **WiFi Speed Limit is per client and lives in `_shaper_resync`, not in the UCI reapply.**
  `build_json` records which netdev lists which station (`M._shape_obs`), the heartbeat
  hands that plus `st.sta_rates` (the `rate-update` ledger, one association each) to
  `shaper.sync`, which diffs per station. `reapply_runtime_rules` rebuilds the blocker
  only. Upload is queued on an IFB device (`kmod-ifb`); without it the police fallback
  needs `kmod-sched-act-police`, and both are listed in every installer.
- **Minimum RSSI and Load balance are per radio and decided after the station loop.**
  The loop only collects observations (`minrssi_obs`, `lb_obs`); `minrssi.tick` kicks
  after HOLD (30 s) below, `loadbalance.kicks` the most idle above the cap, and
  `rf_config` writes hostapd's refusal (`rssi_reject_assoc_rssi`, stamped
  `openuf_minrssi`). A backhaul VAP's stations are never observed.
- **A WLAN Schedule waits for a trusted clock.** `_sched_resync` does nothing until a
  controller answer's `server_time_in_utc` agrees with the local clock within 60 s, which
  touches `/var/run/openuf.clock-ok` (survives a restart, not a reboot). The firmware
  keeps every VAP up until NTP has set the time; so does this. Down is the netdev; up is
  the netdev plus hostapd `STOP_AP` + `update_beacon`, or the BSS stays silent.
- **`openuf_` is a UCI section name, not an SSID filter.** Sections are
  `openuf_<radio>_<sanitized ssid>`; the broadcast SSID is exactly what the controller
  sent, and every pushed WLAN is provisioned whatever it is called. The prefix only marks
  what openUF may delete. `get_vap_table` reports *every* enabled `wifi-iface`, including
  hand-made ones. What is configurable is whether hand-made SSIDs keep broadcasting:
  `use_only_unifi_wlan`, which stamps `openuf_autodisabled=1` on what it turns off so the
  change is reversible.
- **Controller channel "Auto" means hostapd ACS picks**, and on mt7915/mt7986 it readily
  picks a DFS channel whose CAC then fails (`start_dfs_cac() failed` → `AP-DISABLED`), so
  a 5 GHz SSID silently never comes up while the controller reports it provisioned. The
  fix is `dev.conf.radio.<band>.acs_exclude_dfs = true` in the modelmap. A *maximum
  channel* is not a fix: DFS runs 52–144, so any cap below 149 keeps every failing channel
  and drops the working ones.
- **UniFi's `ieee_mode` token lies about the PHY, not the width.** 80 MHz on 5 GHz arrives
  as `11naht80` — still `ht`, which has no 80 MHz. Taken literally that became `HT80`, and
  `clamp_htmode` knocked it back to `HT40`, silently discarding the operator's setting.
  The width is the authoritative half; a width above 40 promotes to `VHT`. Confirmed live
  on a UCG Ultra.
- **The REGDOMAIN, not the hardware, applies the DFS flags.** Measured on one JIDU6101:
  under `IN`/`DE`/`US` channels 52–144 are all `(radar detection)`; under `PA` they carry no
  flag at all, and the identical HE160 config that never came up starts first try. That is
  what `config.country_override` is for — it programs the override into UCI `country` while
  stamping the controller's own value in `openuf_country`, which `get_radio_table` reports
  in preference, so the controller's site setting does not appear to change. Removing the
  override reverses both halves; never leave a foreign regdomain programmed silently.
- **160 MHz on 5 GHz needs working DFS** (or a regdomain that flags none), whatever `iw phy` claims. Every 160 MHz block is
  8 contiguous channels and every one that fits overlaps DFS (ch36 → seg0=50 spans 36–64;
  ch100 → 114 spans 100–128); the clear 149–173 range is only 140 MHz wide. So on a board
  with broken CAC, 160 MHz is unreachable on *any* channel and `acs_exclude_dfs` cannot
  help (a fixed channel skips ACS). That is what `htmode_max` is for.
- **"Force WiFi 4 Mode" does not touch `radio.<n>.ieee_mode`.** It works by making the WLAN
  2.4-only + WPA2 + no 802.11k/v + `bss_load_update_period=0`. So it collides with
  `htmode_floor`, which would put the HE IEs back in the beacon that the mode exists to
  remove — hence the per-radio suppression in `rf_config`. The mode is per WLAN, htmode is
  per radio; that mismatch is the whole difficulty.
- **`htmode_floor` is the ONE exception to "clamp downward only"** (`ucihelper.lua:124`).
  A controller that does not know the hardware pushes its default for the emulated model —
  802.11n/40 at a 4x4 WiFi-6 radio. A modelmap may declare a floor; the hardware clamp
  still runs after it, so a floor can never invent capability. Keep it opt-in per board.
- **A UCI section name may contain only `[A-Za-z0-9_]`, and libuci discards anything else
  silently** (`set` and `commit` both return true). `wlan_add` sanitizes with `[^%w_]` and
  appends a hash of the original SSID when it had to change anything; the test mocks refuse
  an invalid name so the class cannot quietly widen again. An SSID with a hyphen used to
  provision nothing.
- **Minimum RSSI is a fixed wire offset, `dBm = raw - 95`**, not "raw plus the live noise
  floor". The controller never learns a radio's noise floor, so it has nothing but a
  constant to encode with; the old conversion drifted 12 dB between drivers.
- **Never set `ft_psk_generate_local`.** It is FT-PSK-only, and pinning it stops OpenWrt
  configuring the key holders FT-SAE needs, so WPA3 clients silently lose fast roaming.
  The one thing that does set it to `0` is d-malinowski's rrb-unifi plugin, which writes the
  wildcard `r0kh`/`r1kh` key holders in the same breath and points hostapd's `ft_iface` at its
  translator's veth only while the veth exists (hostapd fails a BSS whose `ft_iface` is
  missing). That is a plugin's business now, not this tree's: `plugins.lua` is the hook, and
  nothing in `ucihelper` knows about the veth.
- **`rrm_enrichment` absent means ON here, off upstream.** Their tests pass `nil` for "off";
  ported tests must pass an explicit `false` (the AP2 lesson in `_rrm_tick`'s comment).
- **The ACS candidate list is UCI `channels`, one write, board policy first.** 24.10's generator
  reads the `channels` list; 25.12's schema declares it as the alias of `chanlist`, which is what
  `hostapd.uc` appends -- so `channels` serves both (upstream writes `chanlist`, which 24.10
  ignores). `rf_config` folds the modelmap's `dev.conf.radio.<band>.channels` with the
  controller's blacklist (`radio.<n>.blklst`, inverted against `phy_caps`' legal list): the
  board's list minus the blacklist, the board's alone when that is empty, and
  `dev.conf.radio.<band>.acs_exclude_dfs = true` is never overridden by the site's
  `radio.<n>.acsdfs`. Both are written only while the channel is `auto`; a fixed channel
  deletes them. A hand-set `channels` on an openUF-managed radio is replaced, as every radio
  option `rf_config` owns is.
- **`ieee80211d=0` kills a 5 GHz radio.** `hostapd.uc` emits `ieee80211h` for every radio with
  hw_mode `a` and a country, and hostapd refuses 802.11h without 802.11d, at the NEXT `wifi
  reload`, not at the push that writes it (upstream lost both 5 GHz radios an hour after a
  clean-looking provision). `rf_config` writes `1` on 5 GHz whatever `country_beacon` said, and
  a radio whose band is unknown counts as 5 GHz.
- **The wire's `11naht40` names a width, not 802.11n.** `rf_config` runs a bare `HT<width>`
  at the band's best PHY (`best_phy`) unless the WLAN has Force WiFi 4 Mode; the modelmap
  `htmode_floor` is now only needed to raise the WIDTH. 2.4 GHz is capped at 40 MHz in
  `parse_phy_caps` whatever the PHY says.
- **A station's RRM capability bits are not a promise.** AP2's one "capable" client
  advertises passive, active and table beacon measurement and answers every request with
  mode 0x02 "incapable" -- and hostapd never notifies a bodiless refusal over ubus, so the
  only signal is silence. `_rrm_tick` asks a station at most `RRM_MAX_UNANSWERED` times
  without a mode-0 report before benching it for `RRM_BENCH_SECONDS`; the operating class
  follows the band the station is on (81 for 2.4 GHz, 115 for 5 GHz), because a 2.4-only
  client cannot measure a 5 GHz class at all.
- **WPA-Enterprise is provisioned since 2026-11-02, and the old "the wire carries no RADIUS
  server" claim was a capture artefact** (a site with no RADIUS profile, the absence-as-
  discriminator trap this file warns about). `_wire_radius` reads `aaa.<n>.radius.*`; the
  canonical UCI names (`auth_server_addr`...), never the schema's aliases; an EAP BSS carries no
  passphrase (`PASSPHRASE_ENC` is an allow-set, so a new encryption value fails closed) and no
  private keys; `hostapd_bss_options` has several producers now, so always `add_bss_option`,
  never assign the list. RADIUS MAC authentication fails CLOSED (a WLAN that cannot have its
  ACL is skipped, loudly); Hotspot 2.0 lists are raw lines; MAC-based VLANs write the accept
  file BEFORE pointing hostapd at it. A `wpad-basic-*` has no RADIUS client: warn, never gate.
- **`rts` on a radio is the operator's unless `openuf_rts` is stamped.** `config.rts_threshold_ng`
  / `_na` reach `rf_config` as `opts.rts_threshold` and are written only with the stamp; the
  option taken away removes only a stamped value, and `forget` does the same. They are config
  options and not modelmap radio policy on purpose: `dev.conf.radio` comes from UCI only for a
  `custom` map, and both production APs run a preset. Nothing here has been measured on mt76.
