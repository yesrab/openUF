--[[
	Dynalink DL-WRX36 hardware profile.

	⚠️  NOT verified on real hardware -- openUF has never run on a DL-WRX36.
	Everything below is read from the OpenWrt source tree (qualcommax/ipq807x,
	main at 64129c4282, kernel 6.18, read 2026-10-19), each fact with the file
	and line it came from so it can be re-checked:
	  • target/linux/qualcommax/dts/ipq8072-dl-wrx36.dts
	        compatible :15, procd LED aliases :17-23, the two status LEDs
	        :46-58, the ART MAC cells :117-149, the switch ports :241-309,
	        the ath11k calibration :315-320
	  • target/linux/qualcommax/files/drivers/net/ethernet/qualcomm/qca_ppe_main.c
	        the PPE switch registers with DSA (:1988, tag protocol :515) and
	        offloads bridging (port_bridge_join, port_fdb_add in the ops at
	        :1762)
	  • target/linux/qualcommax/ipq807x/base-files/etc/board.d/02_network
	        :27,33 ucidef_set_interfaces_lan_wan "lan1 lan2 lan3 lan4" "wan";
	        ipq807x_setup_macs (:93-130) has no case for this board
	  • target/linux/qualcommax/ipq807x/base-files/etc/board.d/01_leds
	        :19-23 only the WAN PHY's two link LEDs
	  • target/linux/qualcommax/image/ipq807x.mk :154-165
	        NAND (UBI), SOC ipq8072, ipq-wifi-dynalink_dl-wrx36, and no
	        DEVICE_ALT variants: one retail model, one board name
	  • the openwrt-25.12 branch, for the release a unit most likely runs
	    (see "Two network stacks" below)

	Hardware, per the DTS and the image recipe:
	  • IPQ8072A SoC (qcom,ipq8074 family) with both radios built in, driven
	    by ath11k over AHB (ath11k-firmware-ipq8074, board data from
	    ipq-wifi-dynalink_dl-wrx36): 2.4 GHz and 5 GHz, 802.11ax. The AX3600
	    rating is the vendor's; `iw phy` decides streams and widths.
	  • five sockets: four GbE LAN on a QCA8075 quad PHY (QSGMII) and one
	    2.5 GbE WAN on a QCA8081, all behind the IPQ8074 PPE switch
	  • one case light with two GPIO channels, blue (GPIO 26) and red (25)
	  • NAND flash with a UBI root, so space is not the question it is on
	    the 16 MB SPI-NOR boards
	  • USB 3.0 host, reset and WPS buttons: nothing openUF reads

	Two network stacks, one netdev shape. OpenWrt main drives the switch
	with the PPE driver since f50435627d (2026-07-11): a real DSA switch,
	EDMA conduit, user ports lan1..lan4 and wan, bridging offloaded to the
	switch. The 24.10 and 25.12 releases still use the old NSS dataplane:
	the same five netdevs, made by nss-dp from the same DT labels, bridged
	in software. openUF sees the same thing either way -- one netdev per
	socket, all of them in br-lan -- which is the DSA shape
	(docs/agents/device-maps.md, "Decide swconfig or DSA first"): lan_cpueth = br-lan, uplink_detect =
	"fdb", no dev.conf.vlan.
	⚠️ Per-port VLAN (a Native VLAN on a port) moves the socket into its
	VLAN's bridge (switchvlan.dsa_apply). Verified upstream on an mt7530,
	never run on the PPE driver or on nss-dp.

	Expected radio order: radio0 = 5 GHz (phy0), radio1 = 2.4 GHz (phy1) --
	the OPPOSITE of the JioRouter maps. ath11k registers the IPQ807x's 5 GHz
	radio first: three IPQ807x boards in the tree bind their 5 GHz LED to
	phy0radio and the 2.4 GHz one to phy1radio
	(target/linux/qualcommax/dts/ipq8071-ap8220.dts:54,61,
	ipq8072-zbt-z800ax.dts:85,92, ipq8074-rax120v2.dts:82,88). Nothing here
	depends on it: band is read from each radio's own UCI `band`.
	⚠️ Confirm with `iw phy phy0 info | grep -m1 MHz` on the first unit.

	Presented to the controller as a U6-InWall (ufmodel/u6iw.lua), the
	identity the JioRouter maps use and the one validated end to end: WiFi 6
	on two bands like this hardware, and five sockets, this board's count.
]]--

local dev = {}
dev.conf = {}

-- OpenWrt board names this profile is for: the DTS compatible string, as
-- `ubus call system board` / /tmp/sysinfo/board_name report it. setup.sh
-- preselects this map when the running board is this one; openUF itself
-- never reads the field. Keep it on ONE line -- setup.sh's map_boards()
-- parses it with sed.
dev.openwrt_boards = {"dynalink,dl-wrx36"}

-- OpenWrt network layout.
--
-- lan_cpueth is "br-lan", the LAN BRIDGE, not a socket -- the DSA rule
-- (docs/agents/device-maps.md, "lan_cpueth decides the device's IDENTITY"):
--
--   1. IDENTITY. Its MAC is what the controller adopts the device under,
--      and on an AP the cable may sit in any of the five sockets. Unlike on
--      the JioRouters, board.d sets no MAC on this board's br-lan, so
--      netifd's rule applies (netifd bridge.c, bridge_reset_primary): the
--      bridge takes the MAC of its first present member by name -- "lan1",
--      ahead of lan2..lan4 and the "wan" setup.sh's AP conversion adds.
--      lan1 carries ART +0x6 on main (its nvmem cell, DTS :289-297) and
--      whatever U-Boot patches into the ethernet1 alias on 25.12. 25.12
--      names the WAN port's MAC as the label MAC (label-mac-device), so
--      expect the controller to list a MAC other than the sticker's.
--      ⚠️ br-lan is lan1's MAC only while lan1 is in br-lan. A Native VLAN
--      on Port 1 moves lan1 into br-openuf<vid>, netifd hands the primary
--      to lan2, and every inform afterwards carries a MAC the controller
--      never adopted: HTTP 400 forever. Pin the address BEFORE the first
--      adoption so membership can never move it:
--        BR=$(uci show network | sed -n "s/^network\.\([^.]*\)\.name='br-lan'$/\1/p")
--        uci set network.$BR.macaddr="$(cat /sys/class/net/br-lan/address)"
--        uci commit network && /etc/init.d/network reload
--      Changing it after adoption means Forget and re-adopt.
--   2. MANAGEMENT ADDRESS. netconfig.lua runs `ip addr`/`udhcpc` straight
--      on this netdev for a controller-pushed IP Settings change, and the
--      address lives on br-lan.
--   3. VLAN TRUNK. ensure_vlan_network() builds "<lan_cpueth>.<vid>" for a
--      tagged SSID -- here "br-lan.20". OpenWrt's stock bridge is not
--      VLAN-filtering, so a tagged frame crosses it untouched and the
--      sub-device on the bridge sees it whichever socket the uplink is in.
--      A sub-device on a bridge PORT ("lan1.20") would never see a frame.
dev.conf.net = {
	lan_name	= "lan",
	lan_cpueth	= "br-lan",
	lan_vlanid	= 1,
	-- The socket OpenWrt gives the WAN role at first boot. Only read as a
	-- fallback when `ports` below is absent (it is not); setup.sh's AP
	-- conversion folds it into br-lan.
	wan_cpueth	= "wan",

	-- UniFi port_idx -> netdev, for the inform payload's port_table.
	--
	-- The NETDEV shape: each socket is its own netdev with its own carrier,
	-- negotiated speed/duplex and its own slice of the bridge FDB. The
	-- names are the DT labels, and note the order there: switch port 1 is
	-- "lan4" and port 4 is "lan1" (DTS :259-297). A netdev is named for its
	-- label, not its port number, so the idx numbering below simply follows
	-- the labels, LAN1..LAN4 then WAN, as on the JioRouter maps.
	-- ⚠️ That the case's LAN1 is the "lan1" netdev is the DTS author's
	-- reading; `cat /sys/class/net/lan1/carrier` with one cable in settles it.
	--
	-- No `uplink` flag: which socket is the uplink is detected at runtime
	-- (uplink_detect below), never declared -- a declared uplink is wrong
	-- the moment someone moves the cable, and a socket wrongly treated as
	-- downstream makes the AP report the whole LAN as hosts plugged into it.
	-- `idx` is the UniFi port_idx the controller keys per-port settings on:
	-- pinned to a socket, never renumbered once a unit is adopted.
	--
	-- Five sockets is exactly the U6-InWall's count. The WAN socket links
	-- at 2.5 Gbit/s, which port_table reports as measured.
	ports = {
		{idx = 1, ifname = "lan1"},
		{idx = 2, ifname = "lan2"},
		{idx = 3, ifname = "lan3"},
		{idx = 4, ifname = "lan4"},
		{idx = 5, ifname = "wan"},
	},

	-- Find the uplink socket from the bridge FDB: the port the default
	-- gateway's MAC was learned on (sysinfo.uplink_netdev). Required, not
	-- cosmetic -- without it every host beyond the uplink is reported as a
	-- wired client of this AP. When detection cannot answer, inform.lua
	-- reports the ports but no wired clients, rather than guessing.
	uplink_detect = "fdb",
}

-- Status LED for the controller's Locate action and its Manage > LED toggle.
--
-- One case light, two GPIO channels, and procd claims both: red for
-- led-boot, led-failsafe and led-upgrade, blue for led-running (DTS :17-23).
-- With no channel free, this takes the RUNNING one, the Deco maps' trade:
-- diag.sh leaves led-running steady on once the board is up and never
-- touches it again outside failsafe and sysupgrade, which is exactly the
-- state set_enabled(true) writes. Locate blinks the blue and the LED toggle
-- darkens it; the red stays procd's, for boot and upgrade.
--
-- The name is "blue:" -- colour, colon, nothing. These nodes have a colour
-- and neither a function nor a label (DTS :49-57), and for that the
-- kernel's led_compose_name() writes "<colour>:" with an empty function
-- (drivers/leds/led-core.c, read at v6.12 and v6.18: the kernels of 25.12
-- and main). Until 2e659930d3 (2024-02-07) they were labelled "blue:system"
-- and "red:system"; that commit dropped the labels as redundant beside a
-- colour/function pair this board never had. A build older than it, such
-- as 23.05, names this LED "blue:system".
-- ⚠️ Confirm with `ls /sys/class/leds` on the first unit.
dev.conf.led = "blue:"

-- Radio policy: what the controller's defaults mean on THIS board. Keyed by
-- openUF's band keys: ng = 2.4 GHz, na = 5 GHz.
--
-- Nothing has been measured on this board, so only what does not depend on
-- the hardware is set: the floors the JioRouter maps carry for the IDENTITY.
-- A controller adopting a U6-InWall pushes 5 GHz at 40 MHz by default
-- (radio.2.ieee_mode=11naht40, seen live from a UCG Ultra on a JIDU6101) --
-- a default for the model rather than an intent, and half of what this
-- WiFi 6 radio can do. The floor raises the width to 80 MHz; a controller
-- that asks for more keeps its value, and the hardware clamp
-- (ucihelper.clamp_htmode) still runs afterwards. On 2.4 GHz the floor is
-- documentation: a bare HT40 push already runs as HE40. Delete a floor to
-- have the controller's width honoured as pushed.
--
-- Deliberately NOT copied from the JioRouters: acs_exclude_dfs and
-- htmode_max. Both answer failures of the mt7915 driver measured there (a
-- DFS channel whose CAC never starts, a 160 MHz block that comes up down),
-- and ath11k is a different driver. If 5 GHz Auto lands on a DFS channel and
-- the radio stays down, `logread | grep -i dfs` is the evidence that would
-- justify adding them.
dev.conf.radio = {
	na = {htmode_floor = "HE80"},
	ng = {htmode_floor = "HE20"},
}

-- dev.conf.vlan is deliberately ABSENT: it is the swconfig physical-port
-- map, and this board has no swconfig. Setting it would send inform.lua down
-- the switch path, shelling out to a `swconfig` that is not installed.

-- UniFi configuration
dev.openuf = {}

dev.openuf.uap = {
	-- U6-InWall: WiFi 6 with five sockets, like this board, and the identity
	-- validated end to end on the JioRouters.
	ufmodel		= "u6iw",
	hwassign	= {"radio0", "radio1"},	-- expected radio0 = 5 GHz, radio1 = 2.4 GHz (unverified)
}

return dev
