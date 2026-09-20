--[[
	TP-Link Archer A7 v5 / C7 v4 / C7 v5 hardware profile.

	⚠️  NOT verified on real hardware -- openUF has never run on one of these.
	Everything below is read from the OpenWrt source tree (ath79/generic),
	each fact with the file it came from so it can be re-checked:
	  • target/linux/ath79/dts/qca9563_tplink_archer-x7-v5.dtsi  (A7 v5, C7 v5)
	    target/linux/ath79/dts/qca9563_tplink_archer-c7-v4.dts   (C7 v4)
	  • .../generic/base-files/etc/board.d/02_network   switch layout and labels
	  • .../generic/base-files/etc/board.d/01_leds      which LED lights for which socket
	  • target/linux/ath79/image/generic-tp-link.mk     5 GHz driver + firmware

	Three boards, one map. board.d handles all three in a single case arm in
	both files (same switch geometry, same LED names); the A7 v5 and C7 v5 are
	one dtsi that differ in flash layout and reset GPIO; the C7 v4 wires its
	LEDs through a 74HC595 shift register but registers them under the same
	sysfs names. Each has its own compatible string and ubus reports whichever
	the unit is, so all three are claimed. What openUF reads is identical on
	all of them; what differs (partitions, USB socket count, LED wiring) it
	never touches.

	Hardware, per the DTS and the image recipe:
	  • QCA9563 SoC: built-in 2.4 GHz radio (ath9k, 3x3 802.11n, HT40)
	  • QCA9880 on PCIe: 5 GHz (ath10k-ct, qca988x firmware, 3x3 802.11ac, VHT80)
	  • AR8327 gigabit switch on ONE SGMII link (eth0), swconfig-era
	  • 16 MB flash -- a stock image leaves room for lua-openssl
	Expected radio order: radio0 = 5 GHz (ath10k), radio1 = 2.4 GHz (ath9k).
	The DTS hangs the 5 GHz LED off `phy0tpt` (and, on the C7 v4, the 2.4 GHz
	LED off `phy1tpt`), and the Archer C5 v1 -- the same ahb + PCIe layout --
	measured the same order. Nothing here depends on it: band is read from
	each radio's own UCI `band`/`hwmode`. Check `uci show wireless` on the
	first unit anyway.

	Presented to the controller as a UAP-IW-HD (ufmodel/uhdiw.lua): WiFi 5
	like this hardware, five ethernet sockets like this hardware. That
	identity is itself unvalidated -- if adoption stalls under it, switch the
	ufmodel line at the bottom to "u6iw", which is validated end-to-end.
]]--

local dev = {}
dev.conf = {}

-- OpenWrt board names this profile is for: the DTS compatible strings, as
-- `ubus call system board` / /tmp/sysinfo/board_name report them. setup.sh
-- preselects this map when the running board is one of these; openUF itself
-- never reads the field. Keep it on ONE line -- setup.sh's map_boards()
-- parses it with sed.
dev.openwrt_boards = {"tplink,archer-a7-v5", "tplink,archer-c7-v4", "tplink,archer-c7-v5"}

-- OpenWrt network layout.
--
-- ONE CPU netdev. board.d 02_network:
--   ucidef_add_switch "switch0" "0@eth0" "2:lan:1" "3:lan:2" "4:lan:3" "5:lan:4" "1:wan"
-- The CPU port (0) carries no `u`, so it is TAGGED: the LAN reaches the SoC
-- as eth0.1 (bridged into br-lan) and the WAN as eth0.2, both over the single
-- eth0 trunk. That is the TL-WDR3500's shape (verified on that board), not
-- the Archer C5's two untagged CPU netdevs.
--
-- lan_cpueth is the TRUNK, eth0, not the VLAN sub-device eth0.1: a pushed
-- VLAN 20 becomes eth0.20 beside the LAN's own eth0.1, which is what the
-- switch expects. Its MAC is the board's label MAC (DTS: label-mac-device =
-- &eth0) and is the identity the controller adopts the device under -- see
-- CLAUDE.md on lan_cpueth. The management IP lives on br-lan; announce.get_ip
-- and sysinfo.lan_bridge follow the trunk to its bridge on their own.
dev.conf.net = {
	lan_name	= "lan",
	lan_cpueth	= "eth0",
	lan_vlanid	= 1,
	-- The WAN side's CPU netdev is the VLAN-2 sub-device of the same trunk.
	-- Only read as a fallback when `ports` below is absent (it is not), and
	-- gone once setup.sh's AP conversion folds the WAN socket into VLAN 1.
	wan_cpueth	= "eth0.2",
	-- One entry per RJ45 socket on the case, not per netdev: the only netdev
	-- is the CPU trunk, whose link is the internal SoC<->switch one (always
	-- 1000/full) and behind which every wired host looks the same. Speed,
	-- duplex and which socket a host sits on come from the switch itself
	-- (sysinfo.switch_status); which socket is the UPLINK is detected from
	-- its ARL table at runtime (sysinfo.uplink_phys_port), never declared --
	-- on an AP the cable is in whichever socket the installer used. `idx` is
	-- the UniFi port_idx the controller keys per-port settings on, so it is
	-- pinned to a socket and must never be renumbered once a unit is adopted.
	--
	-- Five sockets is also exactly the UAP-IW-HD's port count (one PoE-in
	-- uplink plus a four-port switch), so the controller's port inventory
	-- and this table line up one-to-one.
	ports = {
		{idx = 1, swport = "lan1"},
		{idx = 2, swport = "lan2"},
		{idx = 3, swport = "lan3"},
		{idx = 4, swport = "lan4"},
		{idx = 5, swport = "wan"},
	},
}

-- Status LED for the controller's Locate action and its Manage > LED toggle.
--
-- Not green:system, although that is the case's power LED: the DTS aliases
-- led-boot, led-failsafe, led-running and led-upgrade all to it, so procd
-- owns it through boot, failsafe and sysupgrade, and openUF blinking the same
-- GPIO reads as boot trouble. (The Archer C5 map predates that rule and does
-- drive its system LED; it gets away with it because procd leaves
-- led-running alone once booted.) board.d 01_leds binds green:wan and
-- green:lan1..4 to switch-port triggers, the DTS gives green:wlan5g the
-- phy0tpt trigger and the USB LED(s) the usbport one. That leaves green:wps
-- -- a WPS indicator nothing drives on an AP without WPS -- and orange:wan.
-- `ls /sys/class/leds` on the device for the full set; set this to
-- "green:system" if you would rather have the power LED and accept the
-- shared GPIO.
dev.conf.led = "green:wps"

-- Switch layout (AR8327 via swconfig, ath79).
--
-- Physical port numbers from two places in the OpenWrt tree that agree:
-- board.d 02_network labels them outright ("2:lan:1" = physical 2 is the
-- socket printed LAN1, ..., "1:wan"), and 01_leds binds each socket's LED to
-- a port mask (WAN 0x02 = port 1, LAN1 0x04 = port 2, LAN2 0x08 = port 3,
-- LAN3 0x10 = port 4, LAN4 0x20 = port 5). So the WAN socket is physical 1
-- and the four LAN sockets are 2-5 in case-label order -- the TP-Link pattern
-- the Archer C5 map learned the hard way (see its dev.conf.vlan note). Port 0
-- is the CPU, tagged, and serves BOTH VLANs: this board has no second CPU
-- port, so cpu_lan and cpu_wan are the same number.
--
-- ⚠️ Still unmeasured on a unit: that the case labels really run LAN1..LAN4 =
-- 2..5 rather than reversed. The SET {2,3,4,5} is certain; the order is
-- OpenWrt's reading of one sample. `swconfig dev switch0 show | grep -A1
-- "^Port"` while moving a cable between sockets settles it. A reversal would
-- mislabel the Ports view and land per-port overrides on the wrong socket;
-- the uplink itself would still be right, since that comes from the ARL
-- table. If a unit proves the labels reversed, change the map and the
-- archer-a7-v5 test in tests/test_modelmap.lua together.
dev.conf.vlan = {
	-- swconfig device name, as `swconfig list` reports it. Every reader used
	-- to fall through to a hardcoded "switch0" because no map set this; on a
	-- board whose switch is switch1 every swconfig call then silently
	-- addressed a device that does not exist.
	device	= "switch0",
	cpu_lan	= 0,
	cpu_wan	= 0,
	ports	= {
		lan1	= 2,
		lan2	= 3,
		lan3	= 4,
		lan4	= 5,
		wan		= 1,
	}
}

-- UniFi configuration
dev.openuf = {}

dev.openuf.uap = {
	-- UAP-IW-HD: WiFi 5 with five sockets, like this board -- see the header.
	-- "u6iw" is the validated fallback if a controller will not adopt under it.
	ufmodel		= "uhdiw",
	hwassign	= {"radio0", "radio1"},	-- expected radio0 = 5 GHz, radio1 = 2.4 GHz (unverified)
}

return dev
