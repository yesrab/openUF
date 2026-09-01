--[[
	Generic single-band OpenWrt AP hardware profile.

	The one-radio counterpart of generic-dualband-ap.lua, for a board with a
	single 2.4 GHz radio. Everything the dual-band generic's header warns about
	applies here too: a generic profile cannot know a board's LED name, its
	socket layout, or which of its ports the uplink cable is in, and the
	eth0 = WAN / eth1 = LAN assumption below is wrong on plenty of boards.
	Prefer a board-specific map where one exists, and check these values with
	`uci show network`, `uci show wireless` and `ls /sys/class/leds` before
	trusting them.

	Identity: uapg1-lr (UAP-LR Gen1), a genuinely single-radio 2.4 GHz UniFi
	model -- the same choice modelmap/tl-wr1043ndv2.lua makes. u6iw is the only
	identity validated end-to-end, but it is a dual-band WiFi 6 AP, so a
	one-radio device reporting it leaves the controller showing a radio that
	never comes up. Switch dev.openuf.uap.ufmodel to "u6iw" if your controller
	rejects the Gen1 identity; expect the missing-radio cosmetics.
]]--

local dev = {}
dev.conf = {}

-- OpenWrt network layout
dev.conf.net = {
	lan_name	= "lan",
	lan_cpueth	= "eth1",
	lan_vlanid	= 1,
	wan_name	= "wan",
	wan_cpueth	= "eth0",
	wan_vlanid	= 4090,
	-- UniFi port_idx -> netdev mapping for the inform payload's port_table.
	-- The netdev-based shape, for the same reason the dual-band generic uses
	-- it: a generic profile cannot know a board's socket layout. See
	-- modelmap/archer-c5-v1.lua (swconfig) or
	-- modelmap/jiorouter-ax6000-jidu6101.lua (DSA) for the per-socket shapes.
	ports = {
		{idx = 1, ifname = "eth0", uplink = true},
		{idx = 2, ifname = "eth1", swport = "lan1"},
	},
}

-- Status LED driven for Locate and the controller's Manage > LED toggle.
-- Left unset because a generic profile can't know the board's LED name; LED
-- control is a silent no-op until you set it. Find yours with
-- `ls /sys/class/leds` and set either a bare name or a full path, e.g.
--   dev.conf.led = "tp-link:green:system"
dev.conf.led = nil

-- Switch layout. The common ath79 shape (CPU 0 = LAN, CPU 6 = WAN, four LAN
-- sockets then the WAN socket) -- verify with `swconfig dev switch0 show`
-- before relying on per-port VLAN assignment, which is the only feature that
-- reads it. TP-Link boards commonly put the WAN socket on physical 1 with the
-- LAN sockets at 2-5, as the Archer C5 turned out to.
dev.conf.vlan = {
	cpu_lan	= 0,
	cpu_wan	= 6,
	ports	= {
		lan1	= 1,
		lan2	= 2,
		lan3	= 3,
		lan4	= 4,
		wan		= 5,
	}
}

-- UniFi configuration
dev.openuf = {}

dev.openuf.uap = {
	ufmodel		= "uapg1-lr",
	hwassign	= {"radio0"},
}

return dev
