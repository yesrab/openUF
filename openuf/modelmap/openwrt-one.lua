--[[
	OpenWrt One hardware profile.

	⚠️  NOT verified on real hardware -- openUF has never run on an OpenWrt
	One. Everything below is read from the OpenWrt source tree
	(mediatek/filogic, main at 2ccaccdb98, read 2026-11-18), each fact with
	the file and line it came from so it can be re-checked:
	  • target/linux/mediatek/dts/mt7981b-openwrt-one.dts
	        compatible :8, the MAC and procd LED aliases :10-18, the status
	        LEDs :64-102, the two ethernet MACs :135-153, the 2.5 GbE PHY
	        :155-188, the factory MAC cells :375-394, the radios :436-454
	  • target/linux/mediatek/filogic/base-files/etc/board.d/02_network
	        :195-196 ucidef_set_interfaces_lan_wan eth1 eth0; no MAC case
	        for this board
	  • target/linux/mediatek/filogic/base-files/etc/board.d/01_leds
	        :274-278 the four socket LEDs on netdev triggers: the WAN pair
	        follows eth0, the LAN pair eth1
	  • target/linux/mediatek/image/filogic.mk :3456-3463
	        kmod-mt7915e + kmod-mt7981-firmware, kmod-phy-airoha-en8811h,
	        and no DEVICE_ALT variants: one retail model, one board name
	  • package/boot/uboot-mediatek/patches/453-add-openwrt-one.patch :477
	        U-Boot reads `ethaddr` from the factory partition at 0x2a
	  • OpenWrt commit 27be0f8565 (2024-09-19, "let U-Boot set LAN MAC
	    address")

	Hardware, per the DTS and the image recipe:
	  • MT7981B SoC (Filogic 820) with both radios built in, driven by
	    mt7915e: 2.4 GHz and 5 GHz, 802.11ax. `iw phy` decides streams and
	    widths.
	  • TWO sockets and NO switch: each is its own ethernet MAC.
	    gmac0 = "eth0", an Airoha EN8811H 2.5 GbE PHY, OpenWrt's WAN;
	    gmac1 = "eth1", the SoC's built-in GbE PHY, OpenWrt's LAN.
	  • one status light with three channels (white and green on PWM, red on
	    a GPIO) and two LEDs on each socket
	  • SPI-NAND with a UBI root, so space is not the question it is on the
	    16 MB boards
	  • USB, an M.2 slot, mikroBUS, an RTC and two buttons: nothing openUF
	    reads

	=== Neither swconfig nor DSA, and it takes the DSA shape ===

	There is no switch chip, so there is no `swconfig` and no
	/sys/class/net/*/dsa either; setup.sh prints "switch none/unknown". What
	openUF needs from "DSA" is only this: one netdev per socket, each with
	its own carrier, speed and slice of the bridge FDB, all of them ports of
	br-lan. Two plain ethernet MACs in a bridge are exactly that, with one
	thing less to go wrong: the bridge is pure software, so the one-address-
	table trap of a switch ASIC (CLAUDE.md, "A moved DSA socket") cannot
	apply. Hence the bridge as lan_cpueth, uplink_detect = "fdb", and no
	dev.conf.vlan.
	"eth0" and "eth1" are SOCKETS here, as on the Deco M4R v4, not the CPU
	netdevs the generic maps mean by those names: a VLAN sub-device on
	either would be on a bridge port and never see a frame.
	The price of no switch: a frame between the two sockets crosses the SoC.
	An AP's second socket carries one wired device, not a LAN, so that is
	what this board's router role already costs.

	Expected radio order: radio0 = 2.4 GHz (band@0), radio1 = 5 GHz (band@1),
	the DTS's order and the one confirmed on the other MT7981 board here, the
	Xiaomi AX3000T. Nothing depends on it: band is read from each radio's own
	UCI `band`.
	⚠️ Confirm with `iw phy phy0 info | grep -m1 MHz` on the first unit.

	Presented to the controller as a U6 Mesh Pro (ufmodel/u6mp.lua): WiFi 6
	on two bands like this hardware, and TWO sockets, this board's count.
	⚠️ That identity has not been adopted by any controller yet -- if
	adoption stalls under it, switch the ufmodel line at the bottom to
	"u6iw", which is validated end to end; the two real sockets keep being
	reported and the registry's three extra rows simply never link up.
]]--

local dev = {}
dev.conf = {}

-- OpenWrt board names this profile is for: the DTS compatible string, as
-- `ubus call system board` / /tmp/sysinfo/board_name report it. setup.sh
-- preselects this map when the running board is this one; openUF itself
-- never reads the field. Keep it on ONE line -- setup.sh's map_boards()
-- parses it with sed.
dev.openwrt_boards = {"openwrt,one"}

-- OpenWrt network layout.
--
-- lan_cpueth is "br-lan", the LAN BRIDGE, not a socket (CLAUDE.md,
-- "lan_cpueth decides the device's IDENTITY"):
--
--   1. IDENTITY. Its MAC is what the controller adopts the device under,
--      and on an AP the cable may sit in either socket. board.d sets no MAC
--      on this board's br-lan, so netifd's rule applies (netifd bridge.c,
--      bridge_reset_primary): the bridge takes the MAC of its first present
--      member by name and follows that member. The two members have
--      DIFFERENT addresses, both fixed at the factory:
--        eth0 (2.5 GbE)  factory 0x24, the label MAC (DTS :12, :143-144)
--        eth1 (GbE)      factory 0x2a, handed over by U-Boot as `ethaddr`
--                        through the ethernet0 alias (DTS :11; 27be0f8565)
--      A stock install has only eth1 in br-lan. setup.sh's AP conversion
--      adds eth0, which sorts first, so after the conversion's reboot
--      br-lan carries the LABEL MAC, and that is the address to expect in
--      the controller.
--      ⚠️ br-lan is eth0's MAC only while eth0 is in br-lan. A Native VLAN
--      on Port 1 moves eth0 into br-openuf<vid> (possible whenever the
--      uplink cable is in the other socket), netifd hands the primary to
--      eth1, and every inform afterwards carries a MAC the controller never
--      adopted: HTTP 400 forever. Pin the address AFTER the conversion's
--      reboot and BEFORE the first adoption, so membership can never move
--      it. Check first that `cat /sys/class/net/br-lan/address` matches the
--      sticker, then:
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
--      "eth0.20" -- a sub-device on a bridge PORT -- would never see a frame.
dev.conf.net = {
	lan_name	= "lan",
	lan_cpueth	= "br-lan",
	lan_vlanid	= 1,
	-- The socket OpenWrt gives the WAN role at first boot (board.d:
	-- ucidef_set_interfaces_lan_wan eth1 eth0). Only read as a fallback
	-- when `ports` below is absent (it is not); setup.sh's AP conversion
	-- folds it into br-lan.
	wan_cpueth	= "eth0",

	-- UniFi port_idx -> netdev, for the inform payload's port_table.
	--
	-- The NETDEV shape: each socket is its own netdev with its own carrier,
	-- negotiated speed/duplex and its own slice of the bridge FDB. No
	-- `swport` and no dev.conf.vlan -- there is no switch (see the header).
	--
	-- Two sockets, the U6 Mesh Pro's count. idx 1 is "eth0", the 2.5 GbE
	-- socket: the one OpenWrt treats as the uplink, and the one that takes
	-- PoE in where the board's PoE module is fitted (openwrt.org/toh/openwrt/one;
	-- not in the DTS), which is the U6 Mesh Pro's port 1 as well. Which
	-- socket is the uplink IN FACT is detected at runtime (uplink_detect
	-- below), never declared -- a declared uplink is wrong the moment
	-- someone moves the cable, and a socket wrongly treated as downstream
	-- makes the AP report the whole LAN as hosts plugged into it. `idx` is
	-- the UniFi port_idx the controller keys per-port settings on: pinned
	-- to a socket, never renumbered once a unit is adopted.
	--
	-- eth0 links at up to 2.5 Gbit/s, which port_table reports as measured.
	ports = {
		{idx = 1, ifname = "eth0"},
		{idx = 2, ifname = "eth1"},
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
-- One status light, three channels, and procd claims all three (DTS
-- :13-16): white for led-boot, red for led-failsafe, green for led-running
-- and led-upgrade. With no channel free, this takes the RUNNING one, the
-- Deco maps' trade: diag.sh leaves led-running steady on once the board is
-- up and never touches it again outside failsafe and sysupgrade, which is
-- exactly the state set_enabled(true) writes. Locate blinks the green and
-- the LED toggle darkens it; white and red stay procd's.
--
-- The name is the kernel's own composition of colour and function, and the
-- node has no label to override it (DTS :75-79). It is a PWM LED, so its
-- ceiling is 255 rather than 1; led.set_enabled writes the LED's own
-- max_brightness, so "on" is full brightness here too.
-- ⚠️ Confirm with `ls /sys/class/leds` on the first unit.
--
-- Not the socket LEDs (green:lan, amber:lan, and the WAN pair on the PHY):
-- 01_leds puts all four on netdev triggers, and a link light is the wrong
-- thing to blink for Locate.
dev.conf.led = "green:status"

-- No dev.conf.radio policy: nothing has been measured on this board, and
-- every field there overrides the controller, so the evidence has to go in
-- the comment first. The one other MT7981 board here, the Xiaomi AX3000T,
-- runs without any. The knobs, if the first unit needs them:
-- `acs_exclude_dfs = true` under `na` if hostapd's ACS keeps landing on a
-- radar channel whose CAC never starts (the MT7986 JioRouter map shows the
-- logread signature), `htmode_max` if `iw phy phy1 info` advertises a width
-- the radio will not come up at, and `htmode_floor` if a controller's
-- default width for a U6 Mesh Pro turns out to be narrower than wanted.

-- dev.conf.vlan is deliberately ABSENT: it is the swconfig physical-port
-- map, and this board has no switch at all. Setting it would send
-- inform.lua down the switch path, shelling out to a `swconfig` that is not
-- installed; its absence is what keeps port reporting on the netdev path
-- and per-port VLAN on the bridge move (switchvlan.dsa_apply; Native VLAN
-- only), which never ran on a board with no switch.

-- UniFi configuration
dev.openuf = {}

dev.openuf.uap = {
	-- U6 Mesh Pro: WiFi 6 with two sockets, like this board -- see the
	-- header. "u6iw" is the validated fallback if a controller will not
	-- adopt under it.
	ufmodel		= "u6mp",
	hwassign	= {"radio0", "radio1"},	-- expected radio0 = 2.4 GHz, radio1 = 5 GHz (unverified)
}

return dev
