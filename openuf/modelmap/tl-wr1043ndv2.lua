--[[


]]--

local dev = {}
dev.conf = {}

-- openwrt hw config
dev.conf.net = {
	lan_name 	= "lan",
	lan_cpueth 	= "eth1",
	lan_vlanid  = 1,
	wan_name 	= "wan",
	wan_cpueth 	= "eth0",
	wan_vlanid 	= 4090,
	-- UniFi port_idx -> netdev mapping for the inform payload's port_table
	-- (separate numbering space from dev.conf.vlan.ports below, which is
	-- swconfig physical-switch-port numbering, not UniFi's port_idx).
	-- This board exposes only two netdevs (no per-physical-port netdevs),
	-- so the single "lan" entry reports every downstream host behind eth1.
	-- `swport` names a key in dev.conf.vlan.ports below; it is what per-port
	-- VLAN assignment (switchvlan.lua) joins the controller's port_idx on.
	ports = {
		{idx = 1, ifname = "eth0", uplink = true},
		{idx = 2, ifname = "eth1", swport = "lan1"},
	},
}

-- Status LED driven for Locate and the controller's Manage > LED toggle.
dev.conf.led = "/sys/class/leds/tp-link:green:system"

dev.conf.vlan = {
	cpu_lan 	= 0,
	cpu_wan 	= 6,
	ports 		= {
		lan1 	= 1,
		lan2 	= 2,
		lan3 	= 3,
		lan4 	= 4,
		wan 	= 5
	}
}


-- unifi configurations
dev.openuf = {}

dev.openuf.uap = {
	ufmodel 	= "uapg1-lr",
	hwassign 	= {"radio0"}
}

return dev
