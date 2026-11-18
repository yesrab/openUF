--[[
	TP-Link Deco M5 v1 / v2 / v3 hardware profile.

	⚠️  NOT verified on real hardware -- openUF has never run on a Deco M5.
	Everything below is read from the OpenWrt source tree (ipq40xx/generic,
	kernel 6.18, read 2026-10-18), each fact with the file it came from so it
	can be re-checked:
	  • target/linux/ipq40xx/dts/qcom-ipq4019-deco-m5.dtsi
	        sockets, MACs, flash, the lp5521 LED, USB disabled
	    target/linux/ipq40xx/dts/qcom-ipq4019-deco-m5-v{1,2,3}.dts
	        per-revision LED wiring and the procd LED aliases
	  • target/linux/ipq40xx/patches-6.18/707-arm-dts-ipq4019-add-switch-node.patch
	        the IPQ4019 switch and its port numbering
	  • target/linux/ipq40xx/base-files/etc/board.d/02_network
	        "lan" + "wan", one case arm for all three revisions
	  • target/linux/ipq40xx/base-files/etc/hotplug.d/firmware/11-ath10k-caldata
	        which radio is which band
	  • target/linux/ipq40xx/image/generic-tp-link.mk
	        image size limit, kmod-leds-lp5521
	  • target/linux/ipq40xx/config-6.18
	        CONFIG_NET_DSA_QCA8K_IPQ4019=y -- a DSA board
	  • github.com/dutchmillbytes/openwrt, read through GitHub's API on
	    2026-10-19: its release images, their device tree, and the board-data
	    fix on its branches -- see the next section

	Where a unit's OpenWrt comes from, as of 2026-10-19:
	  • Upstream builds the M5 only as a snapshot. It reached main in
	    c60be6e983 (2026-03-25), after the 25.12 branch was cut, and was not
	    backported to 25.12 or 24.10.
	  • github.com/dutchmillbytes/openwrt publishes release-based images for
	    the v1, v2 and v3, from v24.10.2-deco to v25.12.5-deco (2026-09-23),
	    built from an earlier version of the same support. To openUF the
	    board is the same -- the same DSA ports, the same LED wiring, the
	    v1 and v3 device trees identical -- except for which netdev carries
	    the label MAC (see dev.conf.net below).
	  • ⚠️ No image ships the M5's WiFi board data yet, upstream or forked:
	    the package ipq-wifi-tplink_deco-m5 exists only on the fork's
	    branches, added 2026-10-10 (ae7ea92b35). Without it ath10k does not
	    find the board's calibration variant ("TP-Link-Deco-M5-v1", "-v3")
	    and falls back to the generic QCA4019 board data, tuned for a
	    reference board. The radios should still come up; judge a mesh
	    link's quality with that in mind.

	Three revisions, one map. Each has its own compatible string and ubus
	reports whichever the unit is, so all three are claimed; board.d handles
	them in a single case arm and they share one .dtsi for the sockets, MACs,
	radios and flash. What differs is ONLY how the single RGB LED is wired
	(an lp5521 I2C driver on v1/v2, three GPIOs on v3) and the 5 GHz
	calibration variant. The LED is the one difference openUF reads, and
	this map resolves it at load time (see dev.conf.led) rather than
	carrying three near-identical files.

	Hardware, per the DTS and the image recipe:
	  • IPQ4019 SoC, two built-in 2x2 radios (ath10k-ct, QCA4019 firmware):
	    wifi0 @ a000000 = 2.4 GHz (HT40), wifi1 @ a800000 = 5 GHz (VHT80) --
	    an AC1300 board, 802.11ac Wave 2
	  • the SoC's own 5-port switch under DSA (qca8k-ipq4019): two sockets
	    wired, swport4 labelled "lan" and swport5 "wan"; CPU port 0 is eth0
	    (the ipqess "gmac")
	  • one RGB LED (red / green / blue channels), no per-socket LEDs
	  • USB-C is power only: the DTS disables usb2 and usb3 outright
	  • Bluetooth on blsp1_uart2 -- OpenWrt enables the UART, nothing uses it
	  • 32 MB SPI-NOR, of which the "firmware" partition is 0x1270000 bytes
	    (18.4 MiB); OpenWrt's image limit is 16640k. ⚠️ Free overlay after a
	    stock image is unmeasured, but REFERENCE.md's 5 MB for lua-openssl should
	    fit comfortably -- an Archer A7 with a 16 MB chip does.
	Expected radio order: radio0 = 2.4 GHz (wifi0), radio1 = 5 GHz (wifi1).
	11-ath10k-caldata feeds a000000.wifi from ART offset 0x1000 and
	a800000.wifi from 0x5000, the 2G and 5G halves of an IPQ40xx ART, and
	the Deco DTS hands wifi0 precal@1000 and wifi1 precal@5000. OpenWrt
	numbers radios in wiphy registration order (wifi-scripts' wifi-detect.uc
	walks nl80211's phy list and mac80211.uc names them in that order), and
	both radios are platform devices of one driver, probed in DT order --
	a000000 before a800000. Nothing here depends on it: band is read from
	each radio's own UCI `band`/`hwmode`.
	Check `uci show wireless` on the first unit anyway.

	Presented to the controller as a UAP-AC-HD (ufmodel/u7hd.lua): WiFi 5
	like this hardware, TWO ethernet sockets like this hardware (the in-wall
	identities carry five), and a USB-C socket that does nothing on either
	device. That identity is itself unvalidated -- if adoption stalls under
	it, switch the ufmodel line at the bottom to "u6iw", which is validated
	end-to-end; the two real sockets keep being reported and the registry's
	three extra rows simply never link up.
]]--

local dev = {}
dev.conf = {}

-- OpenWrt board names this profile is for: the DTS compatible strings, as
-- `ubus call system board` / /tmp/sysinfo/board_name report them. setup.sh
-- preselects this map when the running board is one of these; openUF itself
-- never reads the field. Keep it on ONE line -- setup.sh's map_boards()
-- parses it with sed.
dev.openwrt_boards = {"tplink,deco-m5-v1", "tplink,deco-m5-v2", "tplink,deco-m5-v3"}

-- OpenWrt network layout.
--
-- lan_cpueth is "br-lan", the LAN BRIDGE, not a socket -- the DSA rule
-- (docs/agents/device-maps.md, "lan_cpueth decides the device's IDENTITY"), and on this board
-- it answers all three questions it decides:
--
--   1. IDENTITY. Its MAC is what the controller adopts the device under.
--      The two sockets are equals on an AP -- the cable goes in whichever
--      hole was convenient -- so naming one would tie the identity to the
--      installer's choice. Nothing in board.d sets a MAC on br-lan for this
--      board, so netifd's rule applies (netifd bridge.c,
--      bridge_reset_primary): the bridge takes the MAC of its FIRST present
--      member -- not the kernel's lowest-address rule -- and keeps following
--      that "primary" member. Members sort by name, so that is "lan": alone
--      at first boot, beside "wan" after setup.sh's AP conversion. "lan"
--      carries the label MAC (macaddr_gmac0 +0) and "wan" +1, by one of two
--      routes. Upstream's DTS puts the address on the DSA conduit eth0
--      (label-mac-device = &gmac) and "lan", having no cell of its own,
--      inherits it. The dutchmillbytes images give "lan" the cell itself
--      (label-mac-device = &swport4) and leave eth0 without one, so eth0
--      takes a RANDOM address at every boot (the ipqess driver,
--      ipqess.c:1135-1140). Either way br-lan IS the label MAC -- for as
--      long as "lan" is a member.
--      ⚠️ That last clause is a live hazard, not a footnote. A controller
--      Native-VLAN assignment on port 2 ("lan") while the uplink sits in
--      "wan" moves "lan" OUT of br-lan (switchvlan.dsa_apply rewrites the
--      bridge's ports list), netifd hands the primary to "wan", br-lan
--      becomes +1, and every inform afterwards carries a MAC the controller
--      never adopted: HTTP 400 forever (docs/agents/device-maps.md, lan_cpueth). Pin the
--      address BEFORE the first adoption, so that membership can never move
--      it again. Check first that `cat /sys/class/net/br-lan/address`
--      matches the sticker, then copy br-lan's OWN address -- never eth0's,
--      which is random on the dutchmillbytes images:
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
--      A sub-device on a bridge PORT ("lan.20") would never see a frame.
dev.conf.net = {
	lan_name	= "lan",
	lan_cpueth	= "br-lan",
	lan_vlanid	= 1,
	-- The socket OpenWrt gives the WAN role at first boot. Only read as a
	-- fallback when `ports` below is absent (it is not), and folded into
	-- br-lan by setup.sh's AP conversion.
	wan_cpueth	= "wan",

	-- UniFi port_idx -> netdev, for the inform payload's port_table.
	--
	-- The NETDEV shape: the switch is DSA, so each socket is its own netdev
	-- with its own carrier, negotiated speed/duplex and its own slice of the
	-- bridge FDB. No dev.conf.vlan and no `swport` -- there is no swconfig
	-- here (see the note at the bottom).
	--
	-- Two sockets, which is exactly the UAP-AC-HD's count: idx 1 lines up
	-- with its "Main" (PoE-in uplink) socket and idx 2 with its "Secondary"
	-- (bridged) one. "wan" takes idx 1 because it is the hole OpenWrt itself
	-- treats as the uplink; which socket is the uplink IN FACT is detected at
	-- runtime (uplink_detect below), never declared -- a declared uplink is
	-- wrong the moment someone moves the cable, and a socket wrongly treated
	-- as downstream makes the AP report the whole LAN as hosts plugged into
	-- it. `idx` is the UniFi port_idx the controller keys per-port settings
	-- on: pinned to a socket, never renumbered once a unit is adopted.
	--
	-- ⚠️ Which of the two physical holes OpenWrt calls "wan" (swport5) is
	-- not in the DTS. The case prints no WAN/LAN labels -- stock firmware
	-- auto-senses -- so only a cable and `ip link` on a unit tell. It
	-- affects which Ports-view row a cable shows on, not what works.
	ports = {
		{idx = 1, ifname = "wan"},
		{idx = 2, ifname = "lan"},
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
-- The board has ONE LED, an RGB one, and procd claims all three channels on
-- every revision: led-boot = blue, led-failsafe = red, led-upgrade = red,
-- led-running = green. There is no channel "no DTS alias drives", so this is
-- the Archer C5's trade rather than the Archer A7's: take the RUNNING
-- channel, green, and rely on procd leaving it alone once booted. diag.sh's
-- `done` state turns led-boot off and led-running steady on (trigger none,
-- full brightness) and never touches it again outside failsafe and
-- sysupgrade -- which is exactly the state set_enabled(true) writes (it
-- drives the LED's own max_brightness: 255 on the lp5521, where the literal
-- 1 it used to write is 0.4 %, a case light that went dark). So the
-- controller's LED toggle darkens the whole case light, Locate blinks the
-- same green the AP shows when healthy, and nothing mixes colours. Blue
-- would have been free after boot too (procd switches it off at `done`), but
-- driving it beside a steady green shows cyan, and "LED off" would still
-- leave the case lit.
--
-- The NAME differs by revision, and it is the one thing openUF reads that
-- the three DTS files do not share:
--   v1, v2: an lp5521 I2C driver whose channels carry explicit chan-name
--           properties -- "fault:red", "power:green", "boot:blue". The
--           lp55xx driver registers a channel under its chan-name verbatim
--           (drivers/leds/leds-lp55xx-common.c, lp55xx_init_led: the
--           chan-name branch sets cdev.name directly; no init_data, so the
--           color/function properties are not consulted). Needs the
--           kmod-leds-lp5521 package, which the image recipe ships.
--   v3:     plain gpio-leds with color + function and no label, which the
--           LED core names "<color>:<function>" -- "green:power".
-- Rather than one map per revision for a single string, resolve it here:
-- take whichever of the two names /sys/class/leds actually has. On a build
-- host neither exists and the LED is nil (a silent no-op, like the generic
-- maps); on a unit exactly one does.
-- ⚠️ Both names are a reading of the drivers, not `ls /sys/class/leds` on a
-- unit. If the probe (LuCI, or setup.sh) shows no LED, run that ls and put
-- the real name here.
local function first_led(candidates)
	for _, name in ipairs(candidates) do
		local f = io.open("/sys/class/leds/" .. name .. "/brightness", "r")
		if f then
			f:close()
			return name
		end
	end
	return nil
end
dev.conf.led = first_led({"power:green", "green:power"})

-- No dev.conf.radio policy: nothing has been measured on this board, and
-- every field there overrides the controller, so the evidence has to go in
-- the comment first. The knobs, if the first unit needs them:
-- `acs_exclude_dfs = true` under `na` if hostapd's ACS keeps landing on a
-- radar channel this ath10k cannot clear CAC on (the JioRouter map shows the
-- logread signature), and `htmode_max` if `iw phy phy1 info` advertises a
-- width the radio will not come up at. The hardware clamp
-- (ucihelper.clamp_htmode) already keeps a pushed HE mode down to VHT80 /
-- HT40 here.

-- dev.conf.vlan is deliberately ABSENT.
--
-- It is the swconfig physical-port map, and this board has no swconfig: the
-- IPQ4019 switch is driven by DSA (qca8k-ipq4019). Setting it would send
-- inform.lua down the per-socket switch path and shell out to a `swconfig`
-- that is not installed; its absence is what keeps port reporting on the
-- netdev path and lets switchvlan detect the DSA backend (the assigned
-- socket moves between bridges; Native VLAN only).

-- UniFi configuration
dev.openuf = {}

dev.openuf.uap = {
	-- UAP-AC-HD: WiFi 5 with two sockets, like this board -- see the header.
	-- "u6iw" is the validated fallback if a controller will not adopt under it.
	ufmodel		= "u7hd",
	hwassign	= {"radio0", "radio1"},	-- expected radio0 = 2.4 GHz, radio1 = 5 GHz (unverified)
}

return dev
