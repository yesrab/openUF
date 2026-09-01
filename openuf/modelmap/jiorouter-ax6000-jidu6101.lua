--[[
	JioRouter AX6000 JIDU6101 hardware profile.
	OpenWrt board name (`ubus call system board`): jiorouter,ax6000-jidu6101
	Target: mediatek/filogic — MT7986A (Filogic 830), SPI-NAND, MT7531 switch.

	Read off the OpenWrt source rather than a live board:
	  target/linux/mediatek/dts/mt7986a-jiorouter-ax6000-jidu6101.dts
	  target/linux/mediatek/dts/mt7986a-jiorouter-common.dtsi
	  target/linux/mediatek/filogic/base-files/etc/board.d/02_network
	  target/linux/mediatek/filogic/base-files/etc/hotplug.d/ieee80211/11_fix_wifi_mac
	⚠️ NOT yet verified against the hardware. Everything below is derivable from
	those files, but confirm the two board facts flagged ⚠️ on first install:
	the LED name and the radio band order.

	Radios (MT7986A built-in, mt7915e/mt7986-firmware, DBDC):
	  • radio0 = 2.4 GHz (phy0, platform/soc/18000000.wifi)
	  • radio1 = 5 GHz   (phy1, platform/soc/18000000.wifi+1)
	Note this is the OPPOSITE order to the Archer C5 v1 map. Nothing in openUF
	depends on it (each radio's band is read from its own UCI `band`/`hwmode`),
	but it is the first thing to check against a `uci show wireless` dump.
	⚠️ Confirm with: `iw phy phy0 info | grep -m1 MHz`.

	Unlike every other map here this is a **DSA** board, not swconfig, and that
	changes which of openUF's two port-reporting shapes applies -- see
	dev.conf.net.ports and the dev.conf.vlan note at the bottom.

	openUF presents itself as a 2x2 802.11ax U6-InWall on top of what is really
	a 4x4+4x4 AX6000. The identity is what the controller believes; the pushed
	channel widths are clamped to what `iw phy` really reports, so a HE160 push
	is honoured here where an 802.11ac board would have it clamped down.
]]--

local dev = {}
dev.conf = {}

-- OpenWrt board names this profile is for. Read by tools/openuf-setup.sh to
-- preselect the right map from `ubus call system board`; openUF itself never
-- looks at it, so a map without this field is still perfectly valid.
dev.openwrt_boards = {"jiorouter,ax6000-jidu6101"}

-- OpenWrt network layout.
--
-- lan_cpueth is "br-lan", the LAN BRIDGE, not a port -- and on this board that
-- is the correct answer to all three questions it decides:
--
--   1. IDENTITY. Its MAC is what the controller adopts the device under (see
--      inform.lua's _warn_identity_change). On a DSA board the four LAN
--      sockets are individual netdevs and the cable can move between them, so
--      naming any one socket would make the device's identity depend on which
--      hole the installer used. br-lan's MAC is set from board.d (label_mac+1)
--      and does not move.
--   2. MANAGEMENT ADDRESS. netconfig.lua runs `ip addr`/`udhcpc` straight on
--      this netdev for a controller-pushed IP Settings change, and the address
--      lives on br-lan, not on a port.
--   3. VLAN TRUNK. ensure_vlan_network() builds "<lan_cpueth>.<vid>" for a
--      tagged SSID -- here "br-lan.20". OpenWrt's stock filogic bridge is not
--      VLAN-filtering, so a tagged frame crosses it untouched and an 802.1q
--      sub-device *on the bridge* both receives and egresses it out whichever
--      socket the uplink is in. A sub-device on a bridge PORT (lan1.20) would
--      never see a frame: the port hands everything to br-lan.
dev.conf.net = {
	lan_name	= "lan",
	lan_cpueth	= "br-lan",
	lan_vlanid	= 1,
	wan_name	= "wan",
	wan_cpueth	= "wan",
	wan_vlanid	= 4090,

	-- UniFi port_idx -> netdev, for the inform payload's port_table.
	--
	-- The NETDEV shape, and here it is the strictly better one: MT7531 is
	-- driven by DSA, so every socket already has its own netdev with its own
	-- carrier, negotiated speed/duplex and its own slice of the bridge FDB.
	-- The swconfig detour the ath79 maps need (dev.conf.vlan + the ASIC's ARL
	-- table) exists only because there the kernel can see nothing but the CPU
	-- port; asking the kernel is both simpler and more accurate here.
	--
	-- Socket labels come from the DTS port nodes, and note the order: the
	-- silkscreened LAN1 is switch port 4, while ports 1-3 are LAN2-LAN4. The
	-- idx numbering below follows the case labels (LAN1..LAN4, then WAN), which
	-- is what an installer reading the controller's Ports view expects to see.
	--
	-- No `uplink` flag, deliberately -- same reasoning as the Archer C5 map.
	-- Deployed as an AP, the uplink is whichever socket was convenient, and a
	-- socket wrongly treated as downstream makes the AP report the whole LAN,
	-- gateway included, as hosts plugged into it. uplink_detect below measures
	-- it instead.
	--
	-- No `swport` either: that is the swconfig bridge and there is no swconfig
	-- here. Per-port VLAN assignment is therefore unavailable on this board
	-- (switchvlan.lua detects DSA and refuses rather than guessing).
	ports = {
		{idx = 1, ifname = "wan"},
		{idx = 2, ifname = "lan1"},
		{idx = 3, ifname = "lan2"},
		{idx = 4, ifname = "lan3"},
		{idx = 5, ifname = "lan4"},
	},

	-- Find the uplink socket at runtime from the bridge FDB: the port the
	-- default gateway's MAC was learned on (sysinfo.uplink_netdev). This is
	-- the DSA counterpart of what sysinfo.uplink_phys_port does through a
	-- swconfig ARL table, and it is required, not cosmetic -- without it every
	-- host on the far side of the uplink is reported as a wired client of this
	-- AP. When detection cannot answer (no default route yet, no `bridge`
	-- binary) inform.lua reports the ports but no wired clients at all, rather
	-- than attributing the LAN to a guessed socket.
	uplink_detect = "fdb",
}

-- Status LED for the controller's Locate action and its Manage > LED toggle.
--
-- The board has three GPIO LEDs, all function=status: red (which the DTS
-- claims for led-boot/led-failsafe/led-running), green (unclaimed), and blue
-- (led-upgrade). Green is the one no OpenWrt alias drives, so openUF can own
-- it without fighting procd over the boot indicator.
-- ⚠️ Confirm the exact sysfs name with `ls /sys/class/leds` -- gpio-leds
-- composes it from color+function, which yields "green:status", but a
-- board-specific `label` in a future DTS revision would change it.
dev.conf.led = "green:status"

-- Radio policy: what the controller's "Auto" -- and its blind defaults -- mean
-- on THIS board. Keyed by openUF's band keys: ng = 2.4GHz, na = 5/6GHz.
-- Everything here is measured on the real device, not assumed.
dev.conf.radio = {
	na = {
		-- 5 GHz "Auto" channel is the one setting that must not be handed
		-- straight to hostapd ACS on this board. Verified live, repeatedly:
		--     phy1-ap0: ACS-COMPLETED freq=5260 channel=52
		--     phy1-ap0: DFS-CAC-START freq=5260 chan=52 cac_time=60s
		--     hostapd: DFS start_dfs_cac() failed, -1
		--     phy1-ap0: interface state DFS->DISABLED / AP-DISABLED
		-- ACS keeps choosing a DFS channel and the mt7915/MT7986 driver cannot
		-- start CAC on it, so the radio ends up DOWN with the controller
		-- reporting the WLAN as provisioned. `iw phy phy1 info` in the IN
		-- regdomain marks 52-64 and 100-144 "(radar detection)"; only 36-48
		-- and 149-173 are clear.
		--
		-- acs_exclude_dfs is a stock OpenWrt wifi-device option (it reaches
		-- hostapd as acs_exclude_dfs=1 and applies only when the channel is
		-- auto). With it set, the same radio came up first try:
		--     ACS-COMPLETED freq=5765 channel=153 -> HT_SCAN -> AP-ENABLED
		--     live: channel 149, width 80 MHz, ieee80211ax=1
		acs_exclude_dfs = true,

		-- Optional and NOT set: an explicit ACS candidate list, if you want to
		-- narrow it further than "anything non-DFS" (it becomes hostapd's
		-- chanlist). The full non-DFS set this board reports under IN is:
		--   channels = {36, 40, 44, 48, 149, 153, 157, 161, 165, 169, 173},
		-- Note there is no useful "maximum channel" for this board: capping at
		-- 128 would still leave every DFS channel from 52 up in range, which is
		-- exactly what fails, while excluding 149-165 -- the channels that
		-- actually work here.

		-- The UCG Ultra pushes radio.2.ieee_mode=11naht40 to this AP -- 802.11n
		-- at 40 MHz -- which is what openUF then writes, throwing away most of
		-- a 4x4 WiFi-6 radio (a client associated at MCS 15, 144 Mbit/s). It is
		-- a controller-side default for the emulated model rather than an
		-- intent, so this board raises it. Kind and width are raised
		-- independently, so a controller that genuinely asks for MORE than this
		-- keeps its value, and openUF's hardware clamp still runs afterwards.
		htmode_floor = "HE80",

		-- ...and a ceiling, because this radio ADVERTISES 160 MHz and cannot
		-- run it. Verified live, on every legal primary channel:
		--     DFS-CAC-START freq=5180 chan=36 sec_chan=1 width=2 seg0=50
		--     hostapd: DFS start_dfs_cac() failed, -1
		--     hostapd: Interface initialization failed  -> AP-DISABLED
		-- A 160 MHz block is 8 contiguous 20 MHz channels, and under IN every
		-- one that fits overlaps DFS: ch36 centres on seg0=50 (36-64, and 52-64
		-- are DFS), ch100 centres on 114 (100-128, all DFS). The only clear
		-- range, 149-173, is 7 channels -- 140 MHz -- and 177 is disabled, so no
		-- 160 MHz block fits there at all. With CAC broken in this driver, 160
		-- MHz is therefore unreachable no matter which channel is chosen, and
		-- acs_exclude_dfs cannot help because a FIXED channel skips ACS
		-- entirely.
		--
		-- `iw phy` reports "Supported Channel Width: 160 MHz", so clamp_htmode
		-- passes HE160 straight through and the radio simply comes up down.
		-- Only the board can know the difference; remove this if a future
		-- driver/firmware fixes DFS.
		htmode_max = "HE160",
	},
	ng = {
		-- No DFS on 2.4 GHz, so ACS needs no help here.
		--
		-- HE20 as a floor means "at least 802.11ax, at least 20 MHz": the
		-- controller's 11nght40 keeps its 40 MHz (the floor only raises what is
		-- below it) and gains the HE generation. Set HE40 here if you want to
		-- force 40 MHz, but on 2.4 GHz with three non-overlapping channels that
		-- is usually the wrong trade.
		htmode_floor = "HE20",
	},
}

-- dev.conf.vlan is deliberately ABSENT.
--
-- It is the swconfig physical-port map, and this board has no swconfig: the
-- MT7531 is a DSA switch. Setting it would be worse than useless -- inform.lua
-- gates its per-socket switch path on `cfg.vlan.ports` existing and would then
-- shell out to a `swconfig` that isn't installed, and switchvlan.lua would
-- have to detect DSA and refuse on every push. Leaving it unset is what keeps
-- both on the netdev path, which is the accurate one here.

-- UniFi configuration
dev.openuf = {}

dev.openuf.uap = {
	ufmodel		= "u6iw",
	hwassign	= {"radio0", "radio1"},	-- radio0 = 2.4 GHz, radio1 = 5 GHz
}

return dev
