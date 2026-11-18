--[[
	TP-Link Deco M4R v1 / v2 hardware profile.

	⚠️  Only a first, shallow run on real hardware: a v1, adopted as a
	UAP-AC-HD on 2026-10-18 and meshed on 2026-10-19 (user). None of the
	per-fact checks below was part of it, so they stand as written.
	Everything below is read from the OpenWrt source tree (ath79/generic,
	kernel 6.18, read 2026-10-18), each fact with the file it came from so it
	can be re-checked:
	  • target/linux/ath79/dts/qca9563_tplink_deco-m4r-v1.dts
	        LEDs, the AR8327-class switch on one SGMII link, flash, MACs
	  • target/linux/ath79/generic/base-files/etc/board.d/02_network
	        ucidef_add_switch "switch0" "0@eth0" "3:lan:1" "5:lan:2" -- one
	        case arm shared with the Deco S4 v2
	  • target/linux/ath79/generic/base-files/etc/board.d/01_leds
	        no entry: nothing binds an LED to a socket
	  • target/linux/ath79/image/generic-tp-link.mk
	        kmod-ath10k-ct + ath10k-firmware-qca9888-ct, image size 13824k
	  • target/linux/ath79/config-6.18
	        CONFIG_SWCONFIG=y -- a swconfig board
	  • OpenWrt commit 063e9047cc ("ath79: add support for TP-Link Deco M4R
	    v1 and v2", 2022-04-21): the v2 has a different board layout but the
	    same chips and the same OEM firmware, so OpenWrt builds ONE image and
	    ONE compatible string, "tplink,deco-m4r-v1", for both.

	Two retail revisions, one board name. ubus reports "tplink,deco-m4r-v1"
	on a v2 as well (there is no v2 DTS), so that single string is all this
	map can claim -- the family rule in docs/agents/device-maps.md. The v4 is a different
	board altogether (MediaTek MT7621, DSA) and has its own map,
	modelmap/deco-m4r-v4.lua: everything openUF reads differs between the
	two (switch backend, identity netdev, port shape, LED name), so they are
	not one file. The OpenWrt tree has no Deco M4R v3.

	Hardware, per the DTS, the image recipe and the commit:
	  • QCA9563 SoC: built-in 2.4 GHz radio (ath9k, 802.11n, HT40; the chip
	    is 3x3-capable, the retail AC1200 rating says 2x2 -- `iw phy` decides)
	  • QCA9886 on PCIe: 5 GHz (ath10k-ct with the qca9888 firmware, 2x2
	    802.11ac Wave 2, VHT80)
	  • QCA8337N gigabit switch (the DTS binds it as qca,ar8327) on ONE SGMII
	    link, eth0, swconfig-era; TWO sockets wired, physical ports 3 and 5
	  • 16 MB SPI-NOR, firmware partition 0xe00000 (14 MiB); OpenWrt's image
	    limit is 13824k. ⚠️ Free overlay after a stock image is unmeasured,
	    but REFERENCE.md's 5 MB for lua-openssl should fit, as on the Archer A7
	  • one case light with two GPIO channels: green (power), blue (5 GHz)
	  • no USB
	Expected radio order: radio0 = 5 GHz (ath10k), radio1 = 2.4 GHz (ath9k).
	wifi-detect numbers radios in wiphy registration order (wifi-scripts'
	wifi-detect.uc walks nl80211's phy list and mac80211.uc names them in
	that order), and the Archer C5 v1 -- the same ahb + PCIe layout --
	measured the PCIe ath10k first. Nothing here depends on it: band is read
	from each radio's own UCI `band`/`hwmode`. Check `uci show wireless` on
	the first unit anyway.

	Mesh (wireless uplink): claimed here as on every board since 2026-10-18,
	and the first swconfig board to run it. First run 2026-10-19 (user, a
	shallow test on a v1): with the cable pulled the device came up online
	over the wireless uplink, so the 4-address station on the 5 GHz radio
	(ath10k-ct, QCA9888) works, and the uplink policy reads socket 3/5's
	link from the switch rather than eth0.1's, as intended. Not yet tried:
	the cable coming back, a tagged SSID across the hop. USAGE.md § 6b lists
	what to look at.

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
-- never reads the field. One string only: the v2 has no DTS of its own and
-- reports the v1's (see the header). Keep it on ONE line -- setup.sh's
-- map_boards() parses it with sed.
dev.openwrt_boards = {"tplink,deco-m4r-v1"}

-- OpenWrt network layout.
--
-- ONE CPU netdev, and NO WAN role. board.d 02_network:
--   ucidef_add_switch "switch0" "0@eth0" "3:lan:1" "5:lan:2"
-- The CPU port (0) carries no `u`, so it is TAGGED: the LAN reaches the SoC
-- as eth0.1 (bridged into br-lan) over the eth0 trunk -- the Archer A7's
-- shape. Unlike the A7 there is no "1:wan" and no VLAN 2: OpenWrt gives BOTH
-- sockets the lan role, the stock config has no network.wan, and the case
-- prints no WAN/LAN labels (the stock firmware auto-senses). So setup.sh's
-- AP conversion has nothing to move: absorb_wan_swconfig finds no second
-- switch VLAN and says so, the bridge path finds no WAN netdev, and both
-- sockets are already where an AP wants them.
--
-- lan_cpueth is the TRUNK, eth0, not the VLAN sub-device eth0.1: a pushed
-- VLAN 20 becomes eth0.20 beside the LAN's own eth0.1, which is what the
-- switch expects. Its MAC is the board's config-partition MAC (DTS:
-- macaddr_config_8 +0, shared with the 2.4 GHz radio; the 5 GHz radio
-- carries -1) and is the identity the controller adopts the device under --
-- see docs/agents/device-maps.md on lan_cpueth. The management IP lives on br-lan;
-- announce.get_ip and sysinfo.lan_bridge follow the trunk to its bridge on
-- their own.
dev.conf.net = {
	lan_name	= "lan",
	lan_cpueth	= "eth0",
	lan_vlanid	= 1,
	-- No wan_cpueth: there is no WAN CPU netdev to name on this board. Its
	-- only reader is inform.lua's fallback port table, used when `ports`
	-- below is absent (it is not); probe.lua's export simply omits the line.

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
	-- Two sockets is exactly the UAP-AC-HD's count: idx 1 lines up with its
	-- "Main" (PoE-in uplink) socket and idx 2 with its "Secondary" (bridged)
	-- one. Neither is the uplink by declaration.
	ports = {
		{idx = 1, swport = "lan1"},
		{idx = 2, swport = "lan2"},
	},
}

-- Status LED for the controller's Locate action and its Manage > LED toggle.
--
-- The case has one light, and the DTS gives it two GPIO channels: green
-- (`power`: color + function and no label, which the LED core registers as
-- "green:power") and blue ("blue:wlan5g", on the phy0tpt throughput
-- trigger). procd claims the green one for all four of its roles (led-boot,
-- led-failsafe, led-running, led-upgrade), so there is no channel no alias
-- drives -- the Deco M5's situation, and the same trade as its map rather
-- than the Archer A7's: take the RUNNING channel and rely on procd leaving
-- it alone once booted. diag.sh's `done` state leaves led-running steady on
-- (trigger none, full brightness) and never touches it again outside
-- failsafe and sysupgrade -- exactly the state set_enabled(true) writes. So
-- the controller's LED toggle darkens the green the AP shows when healthy
-- and Locate blinks it, as on the M5. The blue channel is left to the
-- kernel's 5 GHz activity blink; taking it instead would stop that blink
-- for good (set_enabled pins the trigger to none) and leave the case lit
-- green with the toggle off. A plain GPIO LED (max_brightness 1), so there
-- is no M5-style dimming to get wrong.
--
-- ⚠️ "green:power" is a reading of the LED core's naming rule for a
-- gpio-leds node with color + function and no label (led_compose_name), not
-- `ls /sys/class/leds` on a unit. If the probe (LuCI, or setup.sh) shows no
-- LED, run that ls and put the real name here.
dev.conf.led = "green:power"

-- Switch layout (QCA8337N, bound as an AR8327, via swconfig, ath79).
--
-- Physical port numbers from board.d 02_network, which labels them outright:
-- "3:lan:1" = physical 3 is the socket OpenWrt calls LAN1, "5:lan:2" =
-- physical 5 is LAN2. 01_leds has no entry for this board (no per-socket
-- LEDs), so there is no second source to cross-check against, as the Archer
-- A7 map had. Port 0 is the CPU, tagged, and the only CPU port: cpu_lan and
-- cpu_wan are the same number. There is no WAN VLAN and no `wan` entry --
-- the board has no WAN role (see dev.conf.net) -- so cpu_wan only says
-- which port a WAN VLAN would have used, which keeps it out of every
-- "is this a socket" test.
--
-- ⚠️ Which of the two unlabelled holes is physical 3 is OpenWrt's naming of
-- one sample; the SET {3, 5} is certain. `swconfig dev switch0 show |
-- grep -A1 "^Port"` while moving a cable between the sockets settles it. A
-- swap would put a cable on the other Ports-view row and land a per-port
-- override on the other socket; the uplink itself would still be right,
-- since that comes from the ARL table. If a unit proves it reversed, change
-- the map and the deco-m4r-v1 test in tests/test_modelmap.lua together.
dev.conf.vlan = {
	-- swconfig device name, as `swconfig list` reports it.
	device	= "switch0",
	cpu_lan	= 0,
	cpu_wan	= 0,
	ports	= {
		lan1	= 3,
		lan2	= 5,
	}
}

-- No dev.conf.radio policy: nothing has been measured on this board, and
-- every field there overrides the controller, so the evidence has to go in
-- the comment first. The hardware clamp (ucihelper.clamp_htmode) already
-- keeps a pushed HE mode down to VHT80 / HT40 here.

-- UniFi configuration
dev.openuf = {}

dev.openuf.uap = {
	-- UAP-AC-HD: WiFi 5 with two sockets, like this board -- see the header.
	-- "u6iw" is the validated fallback if a controller will not adopt under it.
	-- The MediaTek v4 (modelmap/deco-m4r-v4.lua) presents the same identity:
	-- to the controller the revisions are one retail product.
	ufmodel		= "u7hd",
	hwassign	= {"radio0", "radio1"},	-- expected radio0 = 5 GHz, radio1 = 2.4 GHz (unverified)
}

return dev
