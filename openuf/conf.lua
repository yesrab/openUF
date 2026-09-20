--[[
	openUF main configuration.

	Select the modelmap that matches your hardware (see openuf/modelmap/).
	setup.sh picks this for you from the board name; edit it by hand only if
	you are installing without the guided installer.

	  archer-c5-v1.lua                   TP-Link Archer C5 v1   (swconfig, 2-band)
	  tl-wdr3500-v1.lua                  TP-Link TL-WDR3500 v1  (swconfig, 2-band)
	  tl-wr1043ndv2.lua                  TP-Link WR1043ND v2    (swconfig, 1-band)
	  archer-a7-v5.lua                   TP-Link Archer A7 v5 / C7 v4 / C7 v5 (swconfig, 2-band; ⚠️ unverified)
	  jiorouter-ax6000-jidu6101.lua      JioRouter AX6000       (DSA, 2-band)
	  jiorouter-ax6000-jidu6j01.lua      JioRouter AX6000 J-fam (DSA, 2-band)
	  xiaomi-ax3000t.lua                 Xiaomi Mi Router AX3000T (DSA, 2-band)
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
	              same five sockets ← the Archer A7/C7 map; ⚠️ not yet adopted
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
	-- boot. A scan takes the radio off-channel briefly (clients see a short
	-- stall), which is why this is off unless you turn it on; 300 is sane.
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
	-- (they are asked one at a time, round-robin). Deliberately slow: the
	-- point is to keep the Environment view honest, not to poll.
	rrm_request_interval = 600,

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
