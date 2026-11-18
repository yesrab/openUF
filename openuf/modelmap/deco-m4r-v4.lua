--[[
	TP-Link Deco M4R v4 hardware profile.

	⚠️  NOT verified on real hardware -- openUF has never run on a Deco M4R.
	Everything below is read from the OpenWrt source tree (ramips/mt7621,
	kernel 6.18, read 2026-10-18), each fact with the file it came from so it
	can be re-checked:
	  • target/linux/ramips/dts/mt7621_tplink_deco-m4r-v4.dts
	        LEDs, the two switch ports and their netdev names, the conduit's
	        name, the label MAC, flash, radios
	  • target/linux/ramips/dts/mt7621.dtsi
	        the MT7621's built-in switch: user ports 0-4, CPU port 6 -> gmac0
	  • target/linux/ramips/mt7621/base-files/etc/board.d/02_network
	        ucidef_set_interfaces_lan_wan "eth1" "eth0"
	  • target/linux/ramips/mt7621/base-files/etc/board.d/01_leds
	        green:lan on a netdev trigger for br-lan
	  • target/linux/ramips/image/mt7621.mk
	        kmod-mt7603 + kmod-mt7615e + kmod-mt7663-firmware-ap, image size
	        15744k, Device/dsa-migration
	  • target/linux/ramips/mt7621/config-6.18
	        CONFIG_NET_DSA_MT7530=y -- a DSA board
	  • OpenWrt commits d4c63c7786 ("ramips: add support for TP-Link Deco M4R
	    v4", 2023-01-29: "a complete overhaul of the hardware compared to V1
	    and V2") and 4fed462454 (2025-02-23: the netdev names below)

	One revision, one map. The v1 and v2 are a Qualcomm QCA9563 board with a
	swconfig switch and have their own map, modelmap/deco-m4r-v1.lua;
	everything openUF reads differs (switch backend, identity netdev, port
	shape, LED name), which is why the two are separate files rather than one
	map that branches at load. Each claims only its own compatible string, so
	setup.sh's choice between them is never arbitrary.

	Hardware, per the DTS, the image recipe and the commit:
	  • MT7621AT SoC (2 cores, 880 MHz), 256 MB RAM
	  • MT7603EN on pcie0: 2.4 GHz (mt7603, 2x2 802.11n, HT40)
	  • MT7613BEN on pcie1: 5 GHz (driven by mt7615e with the mt7663 AP
	    firmware, 2x2 802.11ac Wave 2, VHT80)
	  • the SoC's own MT7530 switch under DSA, TWO sockets wired: switch
	    port 0 and port 1
	  • 16 MB SPI-NOR, firmware partition 0xf60000 (15.4 MiB); OpenWrt's
	    image limit is 15744k. ⚠️ Free overlay after a stock image is
	    unmeasured, but REFERENCE.md's 5 MB for lua-openssl should fit
	  • one RGB case light ("logo": red / green / blue GPIOs) plus four more
	    green GPIO LEDs (rssi, lan, sys, wifi2g) whose visibility through
	    the case the tree does not say
	  • no USB
	Expected radio order: radio0 = 2.4 GHz (mt7603), radio1 = 5 GHz (mt7613).
	wifi-detect numbers radios in wiphy registration order (wifi-scripts'
	wifi-detect.uc walks nl80211's phy list and mac80211.uc names them in
	that order), which here is module load order; the other mt76 boards in
	this tree (JioRouter, AX3000T) all put 2.4 GHz first. Nothing here
	depends on it: band is read from each radio's own UCI `band`/`hwmode`.
	Check `uci show wireless` on the first unit anyway.

	=== THE TRAP ON THIS BOARD: eth0 and eth1 are SOCKETS ===

	Since OpenWrt 24.10 the DTS renames the netdevs to keep the stock names
	working: switch port 0 is the netdev "eth0", switch port 1 is "eth1",
	and the CPU-side conduit (gmac0) is named "dsa" (commit 4fed462454:
	without the rename the conduit and port 0 fought over "eth0" and the WAN
	socket never came up). So on this board "eth0" is a DSA user port -- a
	hole in the case with its own carrier and its own slice of the bridge
	FDB -- and NOT a CPU netdev. Every swconfig-era assumption in the generic
	maps (lan_cpueth = "eth0" as the trunk, VLAN sub-devices on it) is wrong
	here: a sub-device on a bridge PORT never sees a frame. `ls -d
	/sys/class/net/eth0/dsa` on a unit shows the shape.

	Presented to the controller as a UAP-AC-HD (ufmodel/u7hd.lua): WiFi 5
	like this hardware, TWO ethernet sockets like this hardware. That
	identity is itself unvalidated -- if adoption stalls under it, switch
	the ufmodel line at the bottom to "u6iw", which is validated end-to-end;
	the two real sockets keep being reported and the registry's three extra
	rows simply never link up.
]]--

local dev = {}
dev.conf = {}

-- OpenWrt board names this profile is for: the DTS compatible string, as
-- `ubus call system board` / /tmp/sysinfo/board_name report it. setup.sh
-- preselects this map when the running board is this one; openUF itself
-- never reads the field. Keep it on ONE line -- setup.sh's map_boards()
-- parses it with sed.
dev.openwrt_boards = {"tplink,deco-m4r-v4"}

-- OpenWrt network layout.
--
-- lan_cpueth is "br-lan", the LAN BRIDGE, not a socket -- the DSA rule
-- (docs/agents/device-maps.md, "lan_cpueth decides the device's IDENTITY"), and on this board
-- it answers all three questions it decides:
--
--   1. IDENTITY. Its MAC is what the controller adopts the device under.
--      The two sockets are equals on an AP -- the cable goes in whichever
--      hole was convenient -- so naming one would tie the identity to the
--      installer's choice. The label MAC is gmac0's (DTS: label-mac-device
--      = &gmac0, macaddr_config_8), and the DTS gives neither switch port an
--      address of its own, so both DSA user ports inherit the conduit's
--      (net/dsa/user.c: eth_hw_addr_inherit when the port node has no
--      mac-address) -- eth0, eth1 and dsa all carry the label MAC, and
--      board.d sets no per-interface MAC for this board. netifd's rule
--      (bridge.c, bridge_reset_primary: br-lan takes the MAC of its FIRST
--      present member and follows that member) therefore lands on the label
--      MAC whichever member it picks. That is why the Deco M5 header's
--      hazard -- a Native-VLAN push moving the primary member out of br-lan
--      and the identity with it -- does not bite here: the member it moves
--      to carries the same address.
--      ⚠️ That is a reading of two source trees, not of a unit. Before
--      adopting, check `cat /sys/class/net/br-lan/address` against the
--      sticker; if they differ, pin it as the M5 header does:
--        BR=$(uci show network | sed -n "s/^network\.\([^.]*\)\.name='br-lan'$/\1/p")
--        uci set network.$BR.macaddr="$(cat /sys/class/net/dsa/address)"
--        uci commit network && /etc/init.d/network reload
--      Changing it after adoption means Forget and re-adopt.
--   2. MANAGEMENT ADDRESS. netconfig.lua runs `ip addr`/`udhcpc` straight
--      on this netdev for a controller-pushed IP Settings change, and the
--      address lives on br-lan.
--   3. VLAN TRUNK. ensure_vlan_network() builds "<lan_cpueth>.<vid>" for a
--      tagged SSID -- here "br-lan.20". OpenWrt's stock bridge is not
--      VLAN-filtering, so a tagged frame crosses it untouched and the
--      sub-device on the bridge sees it whichever socket the uplink is in.
--      "eth0.20" -- a sub-device on a bridge PORT -- would never see a frame.
dev.conf.net = {
	lan_name	= "lan",
	lan_cpueth	= "br-lan",
	lan_vlanid	= 1,
	-- The socket OpenWrt gives the WAN role at first boot: switch port 0,
	-- netdev "eth0" (board.d: ucidef_set_interfaces_lan_wan "eth1" "eth0").
	-- Only read as a fallback when `ports` below is absent (it is not), and
	-- folded into br-lan by setup.sh's AP conversion -- the DSA path, which
	-- adds the socket's own netdev to the bridge.
	wan_cpueth	= "eth0",

	-- UniFi port_idx -> netdev, for the inform payload's port_table.
	--
	-- The NETDEV shape: the switch is DSA, so each socket is its own netdev
	-- with its own carrier, negotiated speed/duplex and its own slice of the
	-- bridge FDB. No dev.conf.vlan and no `swport` -- there is no swconfig
	-- here (see the note at the bottom).
	--
	-- Two sockets, which is exactly the UAP-AC-HD's count: idx 1 lines up
	-- with its "Main" (PoE-in uplink) socket and idx 2 with its "Secondary"
	-- (bridged) one. "eth0" takes idx 1 because it is the hole OpenWrt
	-- itself treats as the uplink; which socket is the uplink IN FACT is
	-- detected at runtime (uplink_detect below), never declared -- a
	-- declared uplink is wrong the moment someone moves the cable, and a
	-- socket wrongly treated as downstream makes the AP report the whole
	-- LAN as hosts plugged into it. `idx` is the UniFi port_idx the
	-- controller keys per-port settings on: pinned to a socket, never
	-- renumbered once a unit is adopted.
	--
	-- ⚠️ Which of the two physical holes is switch port 0 is not in the DTS.
	-- The case prints no WAN/LAN labels -- stock firmware auto-senses -- so
	-- only a cable and `ip link` on a unit tell. It affects which Ports-view
	-- row a cable shows on, not what works.
	ports = {
		{idx = 1, ifname = "eth0"},
		{idx = 2, ifname = "eth1"},
	},

	-- Find the uplink socket at runtime from the bridge FDB: the socket the
	-- default gateway's MAC was learned on (sysinfo.uplink_netdev). Required,
	-- not cosmetic -- without it every host on the far side of the uplink is
	-- reported as a wired client of this AP. When detection cannot answer
	-- (no default route yet, no `bridge` binary) inform.lua reports the
	-- ports but no wired clients at all, rather than attributing the LAN to
	-- a guessed socket.
	uplink_detect = "fdb",
}

-- Status LED for the controller's Locate action and its Manage > LED toggle.
--
-- The case light is the "logo" RGB: three GPIO channels, wired as OpenWrt's
-- DTS comment puts it, "match usage in v1 and v2" -- green:logo is
-- led_power, claimed by all four procd aliases (led-boot, led-failsafe,
-- led-running, led-upgrade); red:logo blinks on phy0tpt (2.4 GHz traffic)
-- and blue:logo on phy1tpt (5 GHz traffic). There is no logo channel no
-- alias or trigger drives, so this is the Deco M5's trade: take the RUNNING
-- channel, green, and rely on procd leaving it alone once booted (diag.sh's
-- `done` state leaves led-running steady on -- trigger none, full brightness
-- -- which is exactly what set_enabled(true) writes). The controller's LED
-- toggle darkens the green the AP shows when healthy, Locate blinks it, and
-- the red and blue traffic blinks are left to the kernel. (The DTS spells
-- the green channel's `default_state` with an underscore, which the binding
-- ignores; procd's led-boot claims it early enough that this is cosmetic.)
--
-- The DTS also declares green:rssi, green:sys, green:lan (01_leds puts it on
-- a netdev trigger for br-lan) and green:wifi2g (phy0tpt). green:rssi and
-- green:sys have no alias and no trigger -- the Archer A7 rule's ideal pick
-- -- but whether either is visible through the case is not in the tree; the
-- Deco M4 case shows one light, and TP-Link routinely populates debug LEDs
-- on the PCB only. ⚠️ If a unit shows green:sys through the case, prefer it
-- here and leave the logo entirely to procd.
--
-- All of them are plain GPIO LEDs (max_brightness 1), so there is no
-- M5-style dimming to get wrong.
dev.conf.led = "green:logo"

-- No dev.conf.radio policy: nothing has been measured on this board, and
-- every field there overrides the controller, so the evidence has to go in
-- the comment first. The knobs, if the first unit needs them:
-- `acs_exclude_dfs = true` under `na` if hostapd's ACS keeps landing on a
-- radar channel this mt7613 cannot clear CAC on (the mt7915/mt7986 boards
-- in this tree needed it; the JioRouter map shows the logread signature),
-- and `htmode_max` if `iw phy phy1 info` advertises a width the radio will
-- not come up at. The hardware clamp (ucihelper.clamp_htmode) already keeps
-- a pushed HE mode down to VHT80 / HT40 here.

-- dev.conf.vlan is deliberately ABSENT.
--
-- It is the swconfig physical-port map, and this board has no swconfig: the
-- MT7530 switch is driven by DSA (mt7530-mdio). Setting it would send
-- inform.lua down the per-socket switch path and shell out to a `swconfig`
-- that is not installed; its absence is what keeps port reporting on the
-- netdev path and lets switchvlan detect the DSA backend (the assigned
-- socket moves between bridges; Native VLAN only).

-- UniFi configuration
dev.openuf = {}

dev.openuf.uap = {
	-- UAP-AC-HD: WiFi 5 with two sockets, like this board -- see the header.
	-- "u6iw" is the validated fallback if a controller will not adopt under it.
	-- The Qualcomm v1/v2 (modelmap/deco-m4r-v1.lua) presents the same
	-- identity: to the controller the revisions are one retail product.
	ufmodel		= "u7hd",
	hwassign	= {"radio0", "radio1"},	-- expected radio0 = 2.4 GHz, radio1 = 5 GHz (unverified)
}

return dev
