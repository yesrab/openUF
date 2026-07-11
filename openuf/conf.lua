--[[
	openUF main configuration.

	Select the modelmap that matches your hardware (see openuf/modelmap/).
	Known-working modelmap files:
	  generic-dualband-ap.lua — TP-Link WDR3500, Archer C5 v1 (dual-band)
	  tl-wr1043ndv2.lua       — TP-Link WR1043ND v2 (single-band)

	The modelmap drives:
	  • dev.conf.net.*          network interface assignments
	  • dev.openuf.uap.ufmodel  which ufmodel/* to load (e.g. "u6iw")
	  • dev.openuf.uap.hwassign radio names to include in the inform payload

	The ufmodel controls the device identity presented to the controller:
	  u6iw.lua  — presents as U6-InWall (U6IW)  ← default for AP emulation
	  uapg1.lua — presents as UAP Gen1
	  uapg2-ac-lr.lua — presents as UAP-AC-LR
]]--

-- Select your hardware model map here:
dev = dofile("modelmap/generic-dualband-ap.lua")

-- Feature switches
enable = {
	led = true,		-- provision/status LED: slow blink = unconfigured, solid = connected
	uap = true,		-- emulate a UniFi AP (sends announce + inform)
	usg = false,	-- USG (gateway) mode — not implemented
	usw = false,	-- USW (switch) mode  — not implemented
}

config = {
	-- When true, any wifi-iface sections NOT prefixed with "openuf_" are disabled
	-- during WiFi provisioning.  Set false to preserve hand-configured SSIDs.
	use_only_unifi_wlan = true,

	-- URL the inform loop posts to.  Overwritten at runtime when the controller
	-- sends a new URL or when syswrapper.sh set-inform is called.
	-- The value here is only used on first boot (before state.json exists).
	inform_url = "http://unifi:8080/inform",

	-- Path for persistent state (authkey, adopted flag, cfgversion, inform_url).
	state_file = "/etc/openuf/state.json",

	-- Log file (used by the init.d service wrapper).
	log_file = "/var/log/openuf.log",

	-- Opt-in: when set, every decrypted controller inform response is appended
	-- verbatim (with a UTC timestamp) to this file, before dispatch. Off by
	-- default. Used to capture ground-truth payload shapes when validating
	-- against a real UniFi controller -- see PROTOCOL-VALIDATION.md.
	debug_dump_file = nil,

	-- Set (by install.sh's --bootstrap-adopt, not by hand) to the name of a
	-- temporary, non-root SSH bootstrap account matching real Ubiquiti
	-- hardware's factory-default "ubnt" login -- lets first adoption succeed
	-- without presetting a root password. nil unless that install flag was
	-- used. When set, inform.lua locks the account once the device becomes
	-- adopted and re-enables it on factory reset -- see USAGE.md's SSH
	-- prerequisite section.
	bootstrap_adopt_user = nil,
}
