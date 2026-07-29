--[[
	TP-Link Archer C5 v1 hardware profile.

	Verified on OpenWrt 25.12.5 (ath79/generic) against the real board:
	  • radio0 = 5 GHz  (ath10k, pci0000:00/0000:00:00.0 — HT/VHT, no HE)
	  • radio1 = 2.4 GHz (ath9k, platform/ahb/18100000.wmac — HT only)
	Note the ordering: radio0 is the 5 GHz radio here, the opposite of what a
	generic profile would assume. Nothing in openUF depends on that ordering
	(each radio's band is read from its own UCI `band`/`hwmode`), but it is the
	first thing to check when reading a `uci show wireless` dump from this board.

	openUF presents itself as an 802.11ax U6-InWall on top of this 802.11n/ac
	hardware; controller-pushed channel widths are clamped down to what these
	radios can really do (see ucihelper's clamp_htmode).
]]--

local dev = {}
dev.conf = {}

-- OpenWrt network layout.
--
-- The uplink is the LAN side: this board is deployed as a pure AP, with
-- br-lan (eth1 → CPU switch port 0) carrying everything and the WAN port
-- (eth0) unused. lan_cpueth therefore names the *port*, not the bridge --
-- VLAN-tagged SSIDs need a real trunk port to hang sub-interfaces off, and
-- the IP lookup follows the bridge on its own (see announce.get_ip).
dev.conf.net = {
	lan_name	= "lan",
	lan_cpueth	= "eth1",
	lan_vlanid	= 1,
	wan_name	= "wan",
	wan_cpueth	= "eth0",
	wan_vlanid	= 4090,
	-- UniFi port_idx -> netdev mapping for the inform payload's port_table.
	--
	-- One entry, deliberately. The board exposes two netdevs, but eth0/WAN is
	-- unused in this AP role -- reporting it as the uplink (as the generic
	-- profile does) tells the controller the uplink carries no traffic while
	-- the port that actually carries it is reported as a downstream port, and
	-- offers the real uplink up for per-port VLAN reassignment. Uplink ports
	-- never get a `swport`, so no controller-pushed port VLAN can strand this
	-- device.
	--
	-- Consequence worth knowing: wired clients are only ever reported on
	-- non-uplink ports (the controller skips client creation on the uplink,
	-- which faces its own network), so this board reports none. That is the
	-- honest answer here -- every host the bridge learns is reached through
	-- this one netdev, and which physical socket each sits on is knowable
	-- only from the switch's own ARL table, which openUF does not read. The
	-- alternative, declaring eth1 a downstream port, would report the whole
	-- LAN segment -- gateway included -- as clients plugged into the AP.
	ports = {
		{idx = 1, ifname = "eth1", uplink = true},
	},
}

-- Status LED for the controller's Locate action and its Manage > LED toggle.
-- The board also has green:wlan2g / green:wlan5g if you would rather flash a
-- radio LED; `ls /sys/class/leds` on the device for the full set.
dev.conf.led = "green:system"

-- Switch layout (AR8327, swconfig-era ath79).
-- Physical port 5 is the uplink socket on this unit; ports 1-4 are the LAN
-- sockets. Only ports named here can ever be VLAN-assigned.
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
	ufmodel		= "u6iw",
	hwassign	= {"radio0", "radio1"},	-- radio0 = 5 GHz, radio1 = 2.4 GHz
}

return dev
