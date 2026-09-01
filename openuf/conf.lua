--[[
	openUF main configuration.

	Select the modelmap that matches your hardware (see openuf/modelmap/).
	setup.sh picks this for you from the board name; edit it by hand only if
	you are installing without the guided installer.

	  archer-c5-v1.lua                   TP-Link Archer C5 v1   (swconfig, 2-band)
	  tl-wdr3500-v1.lua                  TP-Link TL-WDR3500 v1  (swconfig, 2-band)
	  tl-wr1043ndv2.lua                  TP-Link WR1043ND v2    (swconfig, 1-band)
	  jiorouter-ax6000-jidu6101.lua      JioRouter AX6000       (DSA, 2-band)
	  jiorouter-ax6000-jidu6j01.lua      JioRouter AX6000 J-fam (DSA, 2-band)
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

	-- URL the inform loop posts to.  Overwritten at runtime when the controller
	-- sends a new URL or when syswrapper.sh set-inform is called.
	-- The value here is only used on first boot (before state.json exists).
	inform_url = "http://unifi:8080/inform",

	-- Path for persistent state (authkey, adopted flag, cfgversion, inform_url).
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

	-- Opt-in: when set, every decrypted controller inform response is appended
	-- verbatim (with a UTC timestamp) to this file, before dispatch. Off by
	-- default. Used to capture ground-truth payload shapes when validating
	-- against a real UniFi controller -- see PROTOCOL-VALIDATION.md.
	debug_dump_file = nil,

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
