--[[
	JioRouter AX6000 JIDU6J01 family hardware profile.
	OpenWrt board name (`ubus call system board`): jiorouter,ax6000-jidu6j01
	Target: mediatek/filogic — MT7986A (Filogic 830), SPI-NAND, MT7531 switch.

	ONE profile, FIVE retail variants. OpenWrt builds a single image for
	JIDU6J01 / JIDU6201 / JIDU6401 / JIDU6601 / JIDU6701 off one DTS, so every
	one of them reports the SAME compatible string and this map serves them
	all. The variants differ in exactly one thing -- where the label MAC is
	stored in the MFG partition (binary at 0x00, binary at 0x20, ASCII text at
	0x1d0, or an ASCII `mac=` key) -- and board.d resolves that at first boot,
	long before openUF starts. By the time this profile is read there is
	nothing variant-specific left to describe. Do NOT add per-variant maps:
	`ubus` cannot tell them apart, so a second map claiming the same board name
	would make the installer's choice arbitrary (and trips the "no two maps
	claim one board" test).

	Read off the OpenWrt source rather than a live board:
	  target/linux/mediatek/dts/mt7986a-jiorouter-ax6000-jidu6j01.dts
	  target/linux/mediatek/dts/mt7986a-jiorouter-common.dtsi
	  target/linux/mediatek/filogic/base-files/etc/board.d/02_network
	  target/linux/mediatek/filogic/base-files/etc/hotplug.d/ieee80211/11_fix_wifi_mac
	  target/linux/mediatek/image/filogic.mk
	⚠️ NOT yet verified against the hardware. Everything below is derivable
	from those files or inherited from the JIDU6101, which is the same SoC and
	the same radios; confirm the items flagged ⚠️ on first install.

	Radios (MT7986A built-in, mt7915e/mt7986-firmware, DBDC):
	  • radio0 = 2.4 GHz — MT7976GN, 4x4, 802.11b/g/n/ax (phy0)
	  • radio1 = 5 GHz   — MT7976AN, 4x4, 802.11n/ac/ax  (phy1)
	Same order as the JIDU6101 and the OPPOSITE of the Archer C5 v1 map.
	Nothing in openUF depends on it (each radio's band is read from its own UCI
	`band`/`hwmode`), but it is the first thing to check against a
	`uci show wireless` dump. ⚠️ Confirm with: `iw phy phy0 info | grep -m1 MHz`.

	Like the JIDU6101 this is a **DSA** board, not swconfig, which decides
	which of openUF's two port-reporting shapes applies -- see
	dev.conf.net.ports and the dev.conf.vlan note at the bottom.

	openUF presents itself as a 2x2 802.11ax U6-InWall on top of what is really
	a 4x4+4x4 AX6000. The identity is what the controller believes; the pushed
	channel widths are clamped to what `iw phy` really reports, so a HE160 push
	is honoured here where an 802.11ac board would have it clamped down.
]]--

local dev = {}
dev.conf = {}

-- OpenWrt board names this profile is for. Read by setup.sh to preselect the
-- right map from `ubus call system board`; openUF itself never looks at it, so
-- a map without this field is still perfectly valid.
--
-- One entry, deliberately: see the family note in the header. All five retail
-- variants share this compatible string.
dev.openwrt_boards = {"jiorouter,ax6000-jidu6j01"}

-- OpenWrt network layout.
--
-- lan_cpueth is "br-lan", the LAN BRIDGE, not a port -- and on this board that
-- is the correct answer to all three questions it decides:
--
--   1. IDENTITY. Its MAC is what the controller adopts the device under (see
--      inform.lua's _warn_identity_change). On a DSA board the four LAN
--      sockets are individual netdevs and the cable can move between them, so
--      naming any one socket would make the device's identity depend on which
--      hole the installer used. br-lan's MAC comes from board.d as
--      label_mac+1 -- for every variant, whichever MFG offset the label MAC
--      itself was read from -- and does not move.
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
	-- The netdev names are the DTS port labels, and unlike the JIDU6101 this
	-- board's DTS maps them STRAIGHT onto the switch: reg 0 = wan and reg 1-4
	-- = lan1-lan4 (the 6101 rotates, with the silkscreened LAN1 on switch port
	-- 4). That difference is invisible from here -- a DSA netdev is named for
	-- its label, not its reg -- so the table below is identical on both
	-- boards. It is recorded only so the next person diffing the two DTS files
	-- does not go looking for a consequence that isn't there.
	--
	-- idx follows the case labels (LAN1..LAN4, then WAN), which is what an
	-- installer reading the controller's Ports view expects. Once a device is
	-- ADOPTED this numbering is pinned: the controller keys per-port settings
	-- on idx, so renumbering later silently moves which physical socket its
	-- "Port 1" means.
	--
	-- ⚠️ Five sockets, from the shared DTS and filogic.mk's family listing
	-- ("5x 10/100/1000, 1 WAN + 4 LAN"). If some variant in this family turns
	-- out to have fewer holes in the case, drop the surplus entries rather
	-- than reporting phantom ports -- OpenWrt would show them too, since the
	-- DTS is shared, so this is not something the board can be asked.
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
		{idx = 1, ifname = "lan1"},
		{idx = 2, ifname = "lan2"},
		{idx = 3, ifname = "lan3"},
		{idx = 4, ifname = "lan4"},
		{idx = 5, ifname = "wan"},
	},

	-- Find the uplink socket at runtime from the bridge FDB: the port the
	-- default gateway's MAC was learned on (sysinfo.uplink_netdev). This is
	-- the DSA counterpart of what sysinfo.uplink_phys_port does through a
	-- swconfig ARL table, and it is required, not cosmetic -- without it every
	-- host on the far side of the uplink is reported as a wired client of this
	-- AP. When detection cannot answer (no default route yet, no `bridge`
	-- binary) inform.lua reports the ports but no wired clients at all, rather
	-- than attributing the LAN to a guessed socket.
	--
	-- It also means the WAN socket is a perfectly good uplink after the AP
	-- conversion: setup.sh folds it into br-lan and detection then finds the
	-- gateway on whichever of the five sockets the cable is actually in.
	uplink_detect = "fdb",
}

-- Status LED for the controller's Locate action and its Manage > LED toggle.
--
-- The case has ONE LED -- an RGB package -- wired as three GPIO channels, all
-- color+function=status in the shared dtsi: red (claimed by the DTS aliases
-- led-boot/led-failsafe/led-running, and `default-state = "on"`), green
-- (unclaimed) and blue (led-upgrade). Green is the one no OpenWrt alias
-- drives, so openUF can own it without fighting procd over the boot indicator.
--
-- Because it is one physical LED, expect a BLEND rather than a clean green:
-- procd holds red on while the system is running, so openUF turning green on
-- reads as amber, and Locate blinks between amber and red. Cosmetic, and the
-- alternative -- taking red -- costs the boot/failsafe indicator.
-- ⚠️ Confirm the exact sysfs name with `ls /sys/class/leds` -- gpio-leds
-- composes it from color+function, which yields "green:status", but a
-- board-specific `label` in a future DTS revision would change it.
dev.conf.led = "green:status"

-- Radio policy: what the controller's "Auto" -- and its blind defaults -- mean
-- on THIS board. Keyed by openUF's band keys: ng = 2.4GHz, na = 5/6GHz.
--
-- Inherited wholesale from jiorouter-ax6000-jidu6101.lua, where every value
-- below was measured on real hardware. That is a defensible starting point
-- rather than a guess: the two boards are the same MT7986A running the same
-- mt7915e driver against the same MT7976 radios, and each finding below is a
-- property of that driver plus the regulatory domain, not of the case or the
-- ethernet wiring. ⚠️ Still worth re-checking the 5GHz numbers on first
-- install -- `logread -f | grep -i 'DFS\|ACS\|AP-ENABLED'` while the
-- controller provisions -- and if they differ, fix them HERE and note it,
-- rather than editing the 6101 map.
dev.conf.radio = {
	na = {
		-- 5 GHz "Auto" channel is the one setting that must not be handed
		-- straight to hostapd ACS on this board. Verified live on the 6101,
		-- repeatedly:
		--     phy1-ap0: ACS-COMPLETED freq=5260 channel=52
		--     phy1-ap0: DFS-CAC-START freq=5260 chan=52 cac_time=60s
		--     hostapd: DFS start_dfs_cac() failed, -1
		--     phy1-ap0: interface state DFS->DISABLED / AP-DISABLED
		-- ACS keeps choosing a DFS channel and the mt7915/MT7986 driver cannot
		-- start CAC on it, so the radio ends up DOWN with the controller
		-- reporting the WLAN as provisioned -- the worst failure shape there
		-- is, because nothing upstream looks wrong.
		--
		-- acs_exclude_dfs is a stock OpenWrt wifi-device option (it reaches
		-- hostapd as acs_exclude_dfs=1 and applies only when the channel is
		-- auto). With it set, the same radio came up first try:
		--     ACS-COMPLETED freq=5765 channel=153 -> HT_SCAN -> AP-ENABLED
		acs_exclude_dfs = true,

		-- Optional and NOT set: an explicit ACS candidate list, if you want to
		-- narrow it further than "anything non-DFS" (it becomes hostapd's
		-- chanlist). The non-DFS set depends entirely on the regdomain in
		-- force -- under IN the 6101 reports:
		--   channels = {36, 40, 44, 48, 149, 153, 157, 161, 165, 169, 173},
		-- Note there is no useful "maximum channel" for this board: capping at
		-- 128 would still leave every DFS channel from 52 up in range, which
		-- is exactly what fails, while excluding 149-165 -- the channels that
		-- actually work.

		-- The UCG Ultra pushes radio.2.ieee_mode=11naht40 to this AP -- 802.11n
		-- at 40 MHz -- which is what openUF would then write, throwing away
		-- most of a 4x4 WiFi-6 radio (a client associated at MCS 15,
		-- 144 Mbit/s). It is a controller-side default for the emulated model
		-- rather than an intent, so this board raises it. Kind and width are
		-- raised independently, so a controller that genuinely asks for MORE
		-- than this keeps its value, and openUF's hardware clamp still runs
		-- afterwards.
		htmode_floor = "HE80",

		-- Ceiling, in the same units. HE160 is the widest openUF ever derives
		-- from a controller push, so as written this is a NO-OP that documents
		-- the board rather than restricting it -- 160 MHz is reachable here.
		--
		-- It is kept because it is the one control that can express "the
		-- driver says yes and the radio then comes up DOWN", which `iw phy`
		-- cannot (clamp_htmode asks the driver, and the driver advertises
		-- "Supported Channel Width: 160 MHz" regardless). Two ways this stops
		-- being a no-op:
		--   • A regdomain where no 160 MHz block clears DFS. Under IN every
		--     one that fits overlaps radar channels (ch36 centres on seg0=50,
		--     so 52-64; ch100 centres on 114, all DFS) and the only clear
		--     range, 149-173, is 7 channels -- 140 MHz. With CAC broken in
		--     this driver 160 MHz is then unreachable at ANY channel, and
		--     acs_exclude_dfs cannot help because a FIXED channel skips ACS
		--     entirely. Set "HE80" here if that is your situation; the way out
		--     is config.country_override in conf.lua (a regdomain such as PA
		--     that has a clear 160 MHz block, reported upstream as whatever
		--     the controller expects).
		--   • A future EHT320 push, which no MT7986 can run.
		htmode_max = "HE160",
	},
	ng = {
		-- No DFS on 2.4 GHz, so ACS needs no help here.
		--
		-- HE20 as a floor means "at least 802.11ax, at least 20 MHz": the
		-- controller's 11nght40 keeps its 40 MHz (the floor only raises what
		-- is below it) and gains the HE generation. Set HE40 here if you want
		-- to force 40 MHz, but on 2.4 GHz with three non-overlapping channels
		-- that is usually the wrong trade.
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
