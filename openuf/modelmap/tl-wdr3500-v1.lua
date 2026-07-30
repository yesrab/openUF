--[[
	TP-Link TL-WDR3500 v1 hardware profile.

	Verified on OpenWrt 25.12.5 (ath79/generic) against the real board:
	  • radio0 = 2.4 GHz (ath9k, platform/ahb/18100000.wmac)
	  • radio1 = 5 GHz   (ath9k, pci0000:00/0000:00:00.0)
	Both radios are 2x2 802.11n (MCS 0-15). Note the ordering is the OPPOSITE
	of the Archer C5's, where radio0 is the 5 GHz radio -- band is always read
	from each radio's own UCI `band`/`hwmode`, never from this order, but it is
	the first thing to check when reading a `uci show wireless` dump.

	⚠️  8 MB flash. This board cannot run openUF from a stock OpenWrt image:
	the AES-GCM backend (lua-openssl -> libopenssl3) needs ~1.7 MB compressed
	and a stock build leaves ~1.6 MB of overlay, which no crypto backend fits
	in. It needs a custom image with lua-openssl, luasocket, lua-cjson and
	luabitop built into squashfs -- see README's hardware requirements.

	Even then, expect nftables NOT to fit alongside everything else (~490 KB
	with its kernel modules). Without it these two features are unavailable and
	openUF logs the fact rather than pretending:
	  • client Block / Unblock       (openuf/firewall.lua)
	  • Multicast and Broadcast Blocker (openuf/bcfilter.lua)
	Everything else -- adoption, SSID provisioning, 802.11r/k/v, Band Steering,
	Minimum RSSI, WiFi Speed Limit -- works, given hostapd-utils, usteer,
	ip-bridge and tc-tiny in the image.
]]--

local dev = {}
dev.conf = {}

-- OpenWrt network layout.
--
-- Deployed as an AP, this board's uplink is a LAN socket on the switch, which
-- reaches the CPU as VLAN 1 over the eth0 trunk (`eth0.1`, bridged into
-- br-lan). eth1 -- the WAN socket -- is unused and stays DOWN: confirmed on
-- the real board, where it carries zero bytes while all traffic goes over
-- eth0. That is why lan_cpueth is eth0 and not eth1 as the generic profile
-- assumes: naming eth1 here would hang controller-pushed VLAN SSIDs off a
-- dead socket.
--
-- lan_cpueth is the TRUNK (eth0), not the VLAN sub-device (eth0.1), so a
-- pushed VLAN 20 becomes eth0.20 -- a second VLAN alongside the LAN's own,
-- which is what the switch expects.
dev.conf.net = {
	lan_name	= "lan",
	lan_cpueth	= "eth0",
	lan_vlanid	= 1,
	wan_name	= "wan",
	wan_cpueth	= "eth1",
	wan_vlanid	= 2,
	-- One port, the uplink. The board has four LAN sockets, but they all sit
	-- behind this single netdev: which socket a given host is on is knowable
	-- only from the switch's ARL table, which openUF does not read. Declaring
	-- a downstream port instead would report the entire LAN segment -- the
	-- gateway included -- as clients plugged into the AP. Uplink ports get no
	-- `swport`, so no controller-pushed port VLAN can strand the device.
	ports = {
		{idx = 1, ifname = "eth0", uplink = true},
	},
}

-- Status LED for Locate and the Manage > LED toggle. The board also has
-- green:wlan2g, green:qss and green:usb; `ls /sys/class/leds` for the set.
-- (Unlike the Archer C5 there is no 5 GHz LED on this board.)
dev.conf.led = "green:system"

-- Switch layout (AR9344 built-in switch, swconfig-era ath79).
-- Stock config puts LAN sockets 1-4 on VLAN 1 with the CPU port tagged
-- ("1 2 3 4 0t"), which is what dev.conf.net above assumes.
dev.conf.vlan = {
	cpu_lan	= 0,
	cpu_wan	= 0,
	ports	= {
		lan1	= 1,
		lan2	= 2,
		lan3	= 3,
		lan4	= 4,
	}
}

-- UniFi configuration
dev.openuf = {}

dev.openuf.uap = {
	ufmodel		= "u6iw",
	hwassign	= {"radio0", "radio1"},	-- radio0 = 2.4 GHz, radio1 = 5 GHz
}

return dev
