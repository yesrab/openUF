--[[
	openUF main configuration.

	On an OpenWrt PACKAGE install this file is only the shipped default: the
	configuration is /etc/config/openuf (see USAGE.md § 3 and the section
	reference at the top of uciconf.lua), and whenever that file has a `main`
	section it replaces the `dev` and `config` tables set here. Everything
	below applies as written to a tarball install (setup.sh / install.sh).

	Select the modelmap that matches your hardware (see openuf/modelmap/).
	setup.sh picks this for you from the board name; edit it by hand only if
	you are installing without the guided installer.

	  archer-c5-v1.lua                   TP-Link Archer C5 v1   (swconfig, 2-band)
	  tl-wdr3500-v1.lua                  TP-Link TL-WDR3500 v1  (swconfig, 2-band)
	  tl-wr1043ndv2.lua                  TP-Link WR1043ND v2    (swconfig, 1-band)
	  archer-a7-v5.lua                   TP-Link Archer A7 v5 / C7 v4 / C7 v5 (swconfig, 2-band; ⚠️ unverified)
	  deco-m5.lua                        TP-Link Deco M5 v1 / v2 / v3 (DSA, 2-band, 2 sockets; ⚠️ unverified)
	  deco-m4r-v1.lua                    TP-Link Deco M4R v1 / v2 (swconfig, 2-band, 2 sockets, no WAN role; ⚠️ unverified)
	  deco-m4r-v4.lua                    TP-Link Deco M4R v4 (DSA, 2-band, 2 sockets named eth0/eth1; ⚠️ unverified)
	  jiorouter-ax6000-jidu6101.lua      JioRouter AX6000       (DSA, 2-band)
	  jiorouter-ax6000-jidu6j01.lua      JioRouter AX6000 J-fam (DSA, 2-band)
	  jiorouter-ax6000-jidu6j11.lua      JioRouter AX6000 6J11 family (Qualcomm, 2-band)
	  dynalink-dl-wrx36.lua              Dynalink DL-WRX36      (DSA, 2-band, 5 sockets; ⚠️ unverified)
	  xiaomi-ax3000t.lua                 Xiaomi Mi Router AX3000T (DSA, 2-band)
	  linksys-wrt3200acm.lua             Linksys WRT3200ACM     (DSA, 2-band + an unused third radio, 5 sockets; ⚠️ unverified)
	  openwrt-one.lua                    OpenWrt One            (no switch, 2-band, 2 sockets eth0/eth1; ⚠️ unverified)
	  bt-homehub-v5a.lua                 BT Home Hub 5 Type A   (DSA, 2-band; upstream's)
	  generic-dualband-ap.lua            any other dual-band swconfig board
	  generic-singleband-ap.lua          any other single-band swconfig board

	Prefer a board-specific map where one exists: the generic profile cannot
	know the board's LED name or which of its ports is the uplink, and gets
	both wrong on an Archer C5. The generics also assume a swconfig board with
	eth0/eth1 CPU netdevs -- on a DSA board neither exists and every socket is
	its own netdev, so use a board-specific map or let setup.sh generate one.

	The modelmap drives:
	  • dev.conf.net.*          network interface assignments
	  • dev.openuf.uap.ufmodel  which ufmodel/* to load (e.g. "u6iw")
	  • dev.openuf.uap.hwassign radio names to include in the inform payload

	The ufmodel controls the device identity presented to the controller:
	  u6iw.lua  — presents as U6-InWall (U6IW)  ← default for AP emulation
	  uhdiw.lua — presents as UAP-IW-HD (UHDIW), the WiFi 5 in-wall with the
	              same five sockets ← the Archer A7/C7 and WRT3200ACM maps;
	              ⚠️ not yet adopted
	  u7hd.lua  — presents as UAP-AC-HD (U7HD), the WiFi 5 ceiling AP with
	              two sockets ← the Deco M5 and M4R maps; ⚠️ adopted once (M4R v1)
	  u6mp.lua  — presents as U6 Mesh Pro (U6MP), the WiFi 6 AP with two
	              sockets ← the OpenWrt One map; ⚠️ not yet adopted
	  uapg1.lua — presents as UAP Gen1
	  uapg2-ac-lr.lua — presents as UAP-AC-LR

	openUF emulates a UniFi AP only. Gateway (USG) and switch (USW) emulation
	are not implemented and are not planned.
]]--

-- Select your hardware model map here:
dev = dofile("modelmap/generic-dualband-ap.lua")

config = {
	-- When true, any wifi-iface sections NOT prefixed with "openuf_" are disabled
	-- during WiFi provisioning, so the radios carry only what the controller
	-- pushed.  Set false to keep hand-configured SSIDs broadcasting; openUF
	-- stamps each SSID it disables, so switching back to false re-enables
	-- exactly those and leaves ones you disabled yourself alone.
	use_only_unifi_wlan = true,

	-- wifi-iface section names use_only_unifi_wlan must leave alone, e.g.
	-- {"mesh0"} for a hand-made 802.11s backhaul. Sections whose mode is not
	-- "ap" (mesh, sta) are exempt without being listed -- a link is not a
	-- competing SSID, and it may be this AP's own uplink -- so this is for an
	-- AP-mode SSID you want kept regardless. A listed section openUF had
	-- already switched off is switched back on.
	keep_wlan_sections = {},

	-- Third-party plugins to load from /etc/openuf/plugins/<name>.lua, by name
	-- (plugins.lua). A plugin edits the UCI options of each WLAN openUF
	-- provisions, so it runs as root with the same trust as this file: list
	-- only code you have read. Empty (the default) loads nothing; an installer
	-- adds its name to /etc/openuf/plugins.enabled instead of editing this
	-- file, and a UCI-managed device lists it as `list plugin 'name'`. 802.11r
	-- fast roaming with genuine UniFi APs is such a plugin: d-malinowski's
	-- rrb-unifi (github.com/d-malinowski/unifi-openwrt-roaming), which
	-- setup.sh offers to install. See USAGE.md, "Plugins".
	plugins = {},

	-- URL the inform loop posts to.  Overwritten at runtime when the controller
	-- sends a new URL or when syswrapper.sh set-inform is called.
	-- The value here is only used while state.json carries no URL of its own
	-- (first boot, or after a factory reset). An https:// URL here also makes
	-- install.sh pull in luasec.
	inform_url = "http://unifi:8080/inform",

	-- Path for persistent state (authkey, adopted flag, cfgversion, inform_url,
	-- and everything else state.lua's header lists). Read by inform.lua,
	-- announce.lua and syswrapper.lua alike.
	state_file = "/etc/openuf/state.json",

	-- L2 discovery broadcasts (announce.lua, UDP port 10001). On by default:
	-- it is how the device shows up in UniFi Discover without any set-inform.
	--
	-- Set false to adopt over L3 only. This is not just noise reduction: a
	-- controller that discovers a device via L2 adopts it by SSHing in and
	-- running `syswrapper.sh set-adopt`, and if that login cannot succeed
	-- (no password auth, no bootstrap account -- see install.sh's
	-- --bootstrap-adopt) adoption fails with "Connection Interrupted" no
	-- matter how healthy the inform loop is. With broadcasts off the
	-- controller treats the device as L3-discovered instead and delivers the
	-- adoption key over the inform channel, needing no SSH at all.
	-- Takes effect on service restart (the init script reads it).
	l2_announce = true,

	-- Where openUF keeps the ledger of what the controller sent that nothing
	-- here acted on: unknown response types and commands (with their whole
	-- body), mgmt_cfg keys and system_cfg key shapes no parser reads, each
	-- with a count and first/last seen. Always on -- it is how the next
	-- `mesh-halt` leaves more behind than one log line. Values are redacted
	-- by field name (psk, passphrase, authkey, token, *key) and the file is
	-- bounded (150 entries, 2 KiB per body). nil = this default path; false
	-- = count in memory only, never write. See USAGE.md § 3.
	unhandled_file = "/etc/openuf/unhandled.json",

	-- Opt-in: when set, every decrypted controller inform response is appended
	-- verbatim (with a UTC timestamp) to this file, before dispatch. Off by
	-- default. Used to capture ground-truth payload shapes when validating
	-- against a real UniFi controller -- see PROTOCOL-VALIDATION.md.
	debug_dump_file = nil,

	-- With debug_dump_file set: also record what openUF SENDS (one "TX" line
	-- per inform, i.e. every 10 s) and any transport failure ("ERR" lines,
	-- e.g. "HTTP 400"). Response lines keep their untagged shape, so the
	-- capture recipes in REVERSE-ENGINEERING.md still work; filter with
	-- grep ' TX ' / grep -v ' TX '. Off by default because it multiplies the
	-- file's growth and the payload carries no secrets the responses do not.
	debug_dump_requests = false,

	-- Ceiling on debug_dump_file, in bytes. The file lives on /tmp, a RAM
	-- disk shared with state.json and the package manager; unbounded, it
	-- reached 31.7 MB on one board. Past the cap the file restarts with a
	-- marker line rather than rotating (a second generation would double the
	-- peak footprint). 0 disables the cap; nil means the 4 MiB default.
	debug_dump_max_bytes = 4 * 1024 * 1024,

	-- RESEARCH ONLY. Override the capability bitmasks the payload claims:
	--   debug_caps = {fw_caps = 0x110, wifi_caps = 0x0, wifi_caps2 = 0x40},
	-- and/or merge extra top-level fields into every payload verbatim:
	--   debug_payload_extra = {uplink = {type = "wireless"}},
	-- A claimed bit makes the controller push config and show UI for a
	-- feature this device does not implement -- the one thing openUF
	-- otherwise never does (see inform.lua's build_json). These exist so the
	-- go/no-go experiments in REVERSE-ENGINEERING.md are a conf.lua edit and
	-- a restart; the daemon shouts at startup while either is set. nil = off.
	debug_caps = nil,
	debug_payload_extra = nil,

	-- Seconds between background neighbour scans (`iw dev <if> scan` on each
	-- radio), 0 = never. The Environment view is fed from the kernel's cached
	-- BSS list, which forgets a network ~30 s after it was last seen -- and
	-- nothing else in openUF ever scans, so the view drains to empty after
	-- boot. A sweep runs in four-channel chunks, one per heartbeat, so the
	-- radio is never off the air for more than ~0.5 s at a time (a whole-band
	-- sweep in one go dropped every client); still, it is off unless you turn
	-- it on; 300 is sane.
	neighbour_scan_interval = 0,

	-- Client-assisted RF environment enrichment (802.11k beacon reports) --
	-- the mechanism Ubiquiti's Channel AI describes as "neighbor reports and
	-- automated RRM scans", and the no-cost complement to the scan interval
	-- above. The Environment view is otherwise fed from the kernel's PASSIVE
	-- scan cache, which only ever holds neighbours on the channel a radio is
	-- already serving (measured on AP2: 0 on 5 GHz, 4 co-channel on 2.4 GHz).
	-- With this on, openUF periodically asks ONE 802.11k-capable client to
	-- sweep and report back; the client goes off-channel, the AP never does.
	-- A single answer returned 15 BSSes across both bands upstream.
	--
	-- Costs the AP nothing. Costs a participating client roughly a second
	-- off-channel, once per rrm_request_interval, and only clients that
	-- advertise active/passive beacon measurement are ever asked -- a
	-- minority in practice. false never sends a beacon request; an absent
	-- key means on, so a conf.lua kept across an upgrade picks this up.
	rrm_enrichment = true,

	-- Seconds between beacon requests, across all radios and clients combined
	-- (they are asked one at a time, round-robin). Deliberately slow: the point
	-- is to keep the Environment tab honest, not to poll. Each answer also puts
	-- ~15 long BEACON-RESP-RX lines in hostapd's syslog, so a short interval
	-- crowds everything else out of logread.
	rrm_request_interval = 600,

	-- WiFi Connectivity (controller: Insights -> AirView -> Connectivity): report
	-- each client connection's Association / Authentication / DHCP / DNS stages,
	-- the way a UniFi AP does, when the controller asks for them (it does). Reads
	-- hostapd's connect events and installs one passive nft table
	-- (`bridge openuf_assoc`) that only records first-seen DHCP/DNS frames per
	-- station; it never drops or alters traffic. Set false to send nothing and
	-- remove the table.
	assoc_tracker = true,

	-- 802.11k neighbour reports that name the site's other APs. On a WLAN
	-- with 802.11k on, a client may ask the AP where else it could go; without
	-- this hostapd answers with the AP itself and nothing more. openUF fills
	-- the list with the sibling BSSes it has scanned (other openUF APs and
	-- genuine UniFi APs carrying the same SSID) and its own BSS on the other
	-- band, and keeps it filled across WiFi reloads. Where openUF runs usteer
	-- (Band Steering or Roaming Assistant on) usteer keeps the list instead,
	-- and this does nothing. Set false to leave hostapd's list alone.
	neighbour_list = true,

	-- Device SSH Authentication (controller: Settings -> System -> Advanced ->
	-- Device Authentication). true creates the site's device login on this
	-- AP with the password the controller pushes (as a hash), and removes it
	-- when the controller stops pushing it or forgets the device. The
	-- account is root in all but name (uid 0, /bin/ash): that is what a
	-- UniFi device login is. Off by default for exactly that reason. It is
	-- only ever created from a response sealed with this device's own
	-- adoption key, never before adoption, and an account that already
	-- exists on the AP is never touched (devlogin.lua). Whether dropbear
	-- accepts password logins at all stays your setting.
	device_login = false,

	-- Undo a controller config push that takes the AP off the air. Before a
	-- push is applied openUF copies the wireless and network configuration
	-- (and its own state) to /etc/openuf/rollback; if, four minutes later, a
	-- radio that was up has not come back or the controller has not answered
	-- once, the copy is restored and the daemon restarts. The device then
	-- keeps reporting the undone push's version so the controller does not
	-- send it again, and says so in the log and in /tmp/openuf-status
	-- (applyguard.lua has the whole story). Off by default: it has run on the
	-- test VM only, and it will also undo a push that was MEANT to move the
	-- device somewhere the controller cannot follow at once (a new management
	-- VLAN before the switch port is ready).
	apply_rollback = false,

	-- Remote Logging to "this controller, encrypted" (controller: Settings ->
	-- System -> Remote Logging). A syslog server of your own needs nothing
	-- here: openUF hands it to logd whenever the controller pushes one. The
	-- encrypted kind is different: the controller only sends it to a device
	-- that claims the capability, and that claim plus the datagram format are
	-- taken from antoniocosta/unifi-openwrt (UniFi Network 10.6), not yet run
	-- against a controller from this tree. true claims it (fw_caps 0x1000000)
	-- and reports a hash_id; logs then leave through a small forwarder
	-- (logfwd.lua) sealed with the controller's key. Needs lua-openssl.
	encrypted_syslog = false,

	-- IGMP/MLD snooping on the LAN bridge and on openUF's VLAN bridges, as a
	-- UniFi AP runs its own bridges: a multicast group a client joined (IPTV,
	-- a casting stream) goes only to the WLANs with a member, where a bridge
	-- without snooping sends it out of every SSID at the lowest rate. Off by
	-- default, which is OpenWrt's own setting. true writes it to the running
	-- bridges only (never to /etc/config/network) and keeps it there; back
	-- to false and a restart switches off what openUF switched on. Without a
	-- multicast querier on the network nothing is pruned and nothing breaks.
	-- mDNS and the other link-local groups are never pruned. Not yet run on
	-- an AP from this tree (mcsnoop.lua).
	igmp_snooping = false,

	-- RTS/CTS, per band: frames longer than this many bytes are announced
	-- with an RTS first. A UniFi AP turns RTS on (enablertscts on a U6 Pro);
	-- OpenWrt leaves it off. It costs a little airtime per frame and saves
	-- whole retransmissions where clients cannot hear each other (two ends
	-- of a house on one 2.4 GHz channel), so it is worth a try on a band
	-- whose clients show high TX retries and useless on a clean one. nil
	-- (the default) leaves the radio as it is; 0-2347, where 500 is a common
	-- starting point and 2347 means off. Written as the radio's UCI `rts`
	-- at the controller's next configuration push; nil again removes it at
	-- the push after. The effect on mt76 has not been measured from this
	-- tree: compare a client's TX retries before and after.
	rts_threshold_ng = nil,   -- 2.4 GHz
	rts_threshold_na = nil,   -- 5 GHz

	-- Roaming Assistant (controller: WLAN -> Advanced, 5 GHz): how much louder,
	-- in dB, another AP must hear a weak client before openUF moves it there.
	-- The threshold itself comes from the controller.
	roam_assist_diff_db = 8,

	-- Regulatory domain override: an ISO 3166-1 alpha-2 code programmed into
	-- the driver INSTEAD of the one the controller pushes. nil = off, and the
	-- controller's own value is used (the normal case).
	--
	-- The regdomain decides which channels carry a DFS flag, and DFS is
	-- unusable on some drivers -- an mt7915/MT7986 cannot start CAC at all. Set
	-- against such a board that means every 160 MHz block is unreachable,
	-- because every one that fits overlaps DFS spectrum. Measured on a
	-- JIDU6101: under IN, channels 52-144 are all "(radar detection)" and HE160
	-- never comes up; under PA the same channels carry no DFS flag and the
	-- identical config comes up first try at 160 MHz, centre 5250.
	--
	-- The controller is still told its OWN value, not this one -- openUF stamps
	-- it per radio (openuf_country) and reports that, so the site setting does
	-- not appear to change. Clearing this option puts the controller's
	-- regdomain back into UCI and removes the stamp.
	--
	-- Note this programs a regulatory domain the device may not physically be
	-- in. Which channels may be used, and at what power, is a legal constraint
	-- rather than a preference; that call belongs to whoever runs the AP, which
	-- is why it is off unless deliberately set.
	country_override = nil,

	-- Set (by install.sh's --bootstrap-adopt, not by hand) to the name of a
	-- temporary, non-root SSH bootstrap account matching real Ubiquiti
	-- hardware's factory-default "ubnt" login -- lets first adoption succeed
	-- without presetting a root password. nil unless that install flag was
	-- used. When set, inform.lua locks the account once the device becomes
	-- adopted and re-enables it on factory reset -- see USAGE.md's SSH
	-- prerequisite section.
	bootstrap_adopt_user = nil,
}
