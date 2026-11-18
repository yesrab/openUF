--[[
	Linksys WRT3200ACM hardware profile.

	⚠️  NOT verified on real hardware -- openUF has never run on a
	WRT3200ACM. Everything below is read from the OpenWrt source tree
	(mvebu/cortexa9, main at 2ccaccdb98, kernel 6.18, read 2026-11-18) and
	from the kernel's own device tree, which OpenWrt patches rather than
	carries, each fact with the file and line it came from so it can be
	re-checked:
	  • linux v6.18 arch/arm/boot/dts/marvell/armada-385-linksys.dtsi
	        the power LED :69-77, the conduit eth0 :99-109, the LED
	        expander :133-138, the switch and its port labels :161-205, the
	        two WiFi cards :212-220
	  • linux v6.18 arch/arm/boot/dts/marvell/armada-385-linksys-rango.dts
	        the expander's LEDs :19-54, the GPIO LEDs :56-76, flash :82-158,
	        the SDIO slot of the third radio :160-168
	  • target/linux/mvebu/patches-6.18/
	        309-linksys-status-led.patch       all four procd LED aliases
	                                           -> the power LED
	        310-linksys-use-eth0-as-cpu-port.patch   CPU port 6 -> eth0,
	                                           eth2 disabled
	        311-adjust-compatible-for-linksys.patch  "linksys,wrt3200acm"
	        950-armada-385-linksys-rango-wifi-pcie-resets.patch
	                                           see dev.conf.led
	  • target/linux/mvebu/cortexa9/base-files/etc/board.d/02_network
	        :31-33 ucidef_set_interfaces_lan_wan "lan1 lan2 lan3 lan4"
	        "wan"; :88-95 the label MAC, a MAC for the wan interface, none
	        for lan
	  • target/linux/mvebu/cortexa9/base-files/etc/board.d/01_leds :45-50
	        the WAN and USB LEDs on triggers
	  • target/linux/mvebu/cortexa9/base-files/etc/uci-defaults/03_wireless
	        which radio is which band
	  • target/linux/mvebu/image/cortexa9.mk :248-256, :314-325
	        kmod-mwlwifi + mwlwifi-firmware-88w8964, kmod-mwifiex-sdio,
	        kmod-dsa-mv88e6xxx, wpad-basic-mbedtls. "Rango" (DEVICE_ALT0)
	        is this board's code name, not a second model: one board name.
	        The WRT32X is a different device with its own compatible.

	Hardware, per the device tree and the image recipe:
	  • Armada 385 SoC, 512 MB RAM, 256 MB NAND: space is not a question
	  • two Marvell 88W8964 PCIe cards driven by mwlwifi: 5 GHz on pcie1,
	    2.4 GHz on pcie2, 802.11ac Wave 2. `iw phy` decides streams and
	    widths.
	  • a THIRD radio, a Marvell 88W8887 on SDIO (mwifiex), which the stock
	    firmware uses for DFS scanning and Bluetooth. OpenWrt lists it as
	    radio2. openUF leaves it out (see hwassign at the bottom).
	  • five sockets behind a Marvell 88E6352-family switch under DSA
	    (mv88e6xxx): lan1..lan4 and wan, conduit eth0
	  • a power LED on a GPIO and a PCA9635 expander driving the WAN, USB
	    and WPS lights

	The stock image ships wpad-basic-mbedtls, which cannot run a
	controller-pushed WLAN (CLAUDE.md, "wpad-basic"): setup.sh and
	`openuf deps --install` swap it for the full build.

	Radio order: radio0 = 5 GHz, radio1 = 2.4 GHz -- the OPPOSITE of the
	MediaTek maps. 03_wireless assigns radio0's interface the 5 GHz MAC and
	radio1's the 2.4 GHz one on every Linksys board but the WRT1900AC v1,
	and pcie1, the 5 GHz card, probes first. Nothing here depends on it:
	band is read from each radio's own UCI `band`.
	⚠️ Confirm with `iw phy phy0 info | grep -m1 MHz` on the first unit.

	⚠️ mwlwifi is an unmaintained driver with a closed firmware, and none of
	openUF's wireless features has run on it. Reported for it elsewhere and
	NOT measured here: protected management frames, and with them WPA3,
	fail with many clients. If a WPA3 or WPA2/WPA3 WLAN will not take
	clients, set it to WPA2 in the controller before suspecting openUF.

	Presented to the controller as a UAP-IW-HD (ufmodel/uhdiw.lua): WiFi 5
	on two bands like this hardware, and five sockets, this board's count.
	⚠️ That identity has not been adopted by any controller yet -- if
	adoption stalls under it, switch the ufmodel line at the bottom to
	"u6iw", which is validated end to end and has the same five sockets;
	the controller then offers WiFi 6 modes, which openUF clamps to what the
	radios report.
]]--

local dev = {}
dev.conf = {}

-- OpenWrt board names this profile is for: the first DTS compatible string,
-- as `ubus call system board` / /tmp/sysinfo/board_name report it. setup.sh
-- preselects this map when the running board is this one; openUF itself
-- never reads the field. Keep it on ONE line -- setup.sh's map_boards()
-- parses it with sed. "linksys,rango" is the second compatible string and
-- is never what board_name reports, so it is not claimed.
dev.openwrt_boards = {"linksys,wrt3200acm"}

-- OpenWrt network layout.
--
-- lan_cpueth is "br-lan", the LAN BRIDGE, not a socket -- the DSA rule
-- (CLAUDE.md, "lan_cpueth decides the device's IDENTITY"):
--
--   1. IDENTITY. Its MAC is what the controller adopts the device under,
--      and on an AP the cable may sit in any of the five sockets. board.d
--      sets a MAC for wan only (the label MAC with the
--      locally-administered bit) and none for lan, so netifd's rule applies
--      (netifd bridge.c, bridge_reset_primary): br-lan takes the MAC of its
--      first present member by name, "lan1". The device tree gives no
--      switch port an address of its own, so the DSA ports inherit the
--      conduit's (net/dsa/user.c: eth_hw_addr_inherit) -- lan1..lan4 all
--      carry eth0's MAC, and "wan", whichever address it ends up with,
--      sorts after all four. That is why the Deco M5's hazard, a
--      Native-VLAN push moving the primary member out of br-lan and the
--      identity with it, should not bite here: the member it moves to
--      carries the same address. The Deco M4R v4 map rests on the same
--      reading.
--      ⚠️ Where eth0's own MAC comes from is NOT in the tree: its node has
--      no address, so the mvneta driver keeps what the bootloader left in
--      the controller's registers and falls back to a RANDOM address when
--      that is not valid. Before adopting, reboot once and check that
--      `cat /sys/class/net/br-lan/address` is the same both times; whether
--      it also matches the sticker decides only which MAC the controller
--      lists. If it changed, or to be safe either way, pin it:
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
--      ⚠️ That a tag crosses the switch untouched is measured on an
--      mt7530, never on an mv88e6xxx.
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
	-- names are the DT labels, and note the order there: switch port 0 is
	-- "lan4" and port 3 is "lan1" (dtsi :169-187). A netdev is named for
	-- its label, not its port number, so the idx numbering below simply
	-- follows the case, 1..4 then Internet, as on the JioRouter maps.
	--
	-- No `uplink` flag: which socket is the uplink is detected at runtime
	-- (uplink_detect below), never declared -- a declared uplink is wrong
	-- the moment someone moves the cable, and a socket wrongly treated as
	-- downstream makes the AP report the whole LAN as hosts plugged into it.
	-- `idx` is the UniFi port_idx the controller keys per-port settings on:
	-- pinned to a socket, never renumbered once a unit is adopted.
	--
	-- Five sockets is exactly the UAP-IW-HD's count.
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
-- The WPS light's white channel, on the PCA9635 expander. It is the one
-- front-panel light nothing else drives: the power LED belongs to procd
-- (all four aliases, patch 309), the WAN and USB lights are on triggers
-- (01_leds), and openUF has no use for WPS. The name is the kernel's: the
-- leds-pca963x driver prefixes the node's label with "pca963x:", as
-- 01_leds' own "pca963x:rango:white:wan" shows. The expander is an 8-bit
-- dimmer (max_brightness 255); led.set_enabled writes the LED's own
-- ceiling, so "on" is full brightness.
-- ⚠️ Confirm with `ls /sys/class/leds` on the first unit.
--
-- ⚠️ NEVER point this at rango:white:wlan_2g or rango:white:wlan_5g. Every
-- release image lists them as LEDs, and they are not: those two GPIOs are
-- the RESET lines of the WiFi cards. Blinking one takes its radio off the
-- bus until the next reboot ("adapter does not exist" from mwlwifi).
-- OpenWrt main removed them on 2026-10-23 (patch 950, openwrt issue 9517).
dev.conf.led = "pca963x:rango:white:wps"

-- No dev.conf.radio policy: nothing has been measured on this board, and
-- every field there overrides the controller, so the evidence has to go in
-- the comment first. The floors and limits the MediaTek maps carry answer
-- the mt7915 driver and the U6-InWall's defaults, neither of which is
-- here. The knobs, if the first unit needs them: `acs_exclude_dfs = true`
-- under `na` if hostapd's ACS lands on a radar channel and the radio stays
-- down (`logread | grep -i dfs`), and `htmode_max = "VHT80"` if 160 MHz is
-- advertised by `iw phy phy0 info` and does not come up.

-- dev.conf.vlan is deliberately ABSENT: it is the swconfig physical-port
-- map, and this board has no swconfig. Setting it would send inform.lua down
-- the switch path, shelling out to a `swconfig` that is not installed; its
-- absence is what keeps port reporting on the netdev path and per-port VLAN
-- on the bridge move (switchvlan.dsa_apply; Native VLAN only).
-- ⚠️ That move, and the learning-off it depends on (CLAUDE.md, "A moved DSA
-- socket"), are verified upstream on an mt7530 and never ran on an
-- mv88e6xxx.

-- UniFi configuration
dev.openuf = {}

dev.openuf.uap = {
	-- UAP-IW-HD: WiFi 5 with five sockets, like this board -- see the
	-- header. "u6iw" is the validated fallback if a controller will not
	-- adopt under it.
	ufmodel		= "uhdiw",
	-- radio0 = 5 GHz, radio1 = 2.4 GHz (expected, unverified): the two
	-- 88W8964 cards. radio2, the 88W8887, is deliberately NOT listed: a
	-- radio left out is never reported and never touched, and a UAP-IW-HD
	-- has two radios. setup.sh enables every radio it finds, this one
	-- included, so switch it off by hand once:
	--   uci set wireless.radio2.disabled=1; uci commit wireless; wifi reload
	hwassign	= {"radio0", "radio1"},
}

return dev
