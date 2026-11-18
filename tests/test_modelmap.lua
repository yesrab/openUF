-- Structural tests for every file in openuf/modelmap/.
-- Run from project root: lua tests/run_tests.lua
--
-- Nothing loaded the modelmaps before this file existed, so a syntax error or
-- a structural mistake in one shipped silently and only surfaced on the device
-- -- as a daemon that dies at startup, an LED that never lights, or, worst,
-- a per-port VLAN push landing on the uplink. These are cheap invariants that
-- every board profile has to hold, checked for all of them at once so a newly
-- added map cannot skip them.

local lfs_ls = function(dir)
	local names = {}
	local h = io.popen("ls " .. dir .. " 2>/dev/null")
	if not h then return names end
	for line in h:lines() do
		if line:match("%.lua$") then names[#names + 1] = line end
	end
	h:close()
	return names
end

local MODELMAP_DIR = "openuf/modelmap"

local function each_modelmap(fn)
	local files = lfs_ls(MODELMAP_DIR)
	assert_true(#files > 0, "modelmap directory is not empty (found " .. #files .. ")")
	for _, name in ipairs(files) do
		local path = MODELMAP_DIR .. "/" .. name
		local ok, dev = pcall(dofile, path)
		assert_true(ok, path .. " loads: " .. tostring(dev))
		assert_true(type(dev) == "table", path .. " returns a table")
		fn(name, dev)
	end
end

return {
	{
		name = "modelmap: every map loads and declares conf + a ufmodel that exists",
		fn = function()
			each_modelmap(function(name, dev)
				assert_true(type(dev.conf) == "table", name .. ": has dev.conf")
				assert_true(type(dev.openuf) == "table", name .. ": has dev.openuf")
				assert_true(type(dev.openuf.uap) == "table", name .. ": has dev.openuf.uap")
				local ufmodel = dev.openuf.uap.ufmodel
				assert_true(type(ufmodel) == "string" and ufmodel ~= "",
					name .. ": names a ufmodel")
				-- conf.lua dofiles "ufmodel/<name>.lua"; a typo here is a
				-- startup crash on the device, not a warning.
				local f = io.open("openuf/ufmodel/" .. ufmodel .. ".lua", "r")
				assert_not_nil(f, name .. ": ufmodel file openuf/ufmodel/" .. ufmodel .. ".lua exists")
				if f then f:close() end
			end)
		end
	},
	{
		name = "modelmap: net.ports entries are well-formed and never VLAN-assign the uplink",
		fn = function()
			each_modelmap(function(name, dev)
				local net = dev.conf.net
				assert_true(type(net) == "table", name .. ": has dev.conf.net")
				assert_true(type(net.lan_cpueth) == "string",
					name .. ": names a LAN CPU port")
				if net.ports == nil then return end   -- optional; inform.lua defaults
				assert_true(type(net.ports) == "table", name .. ": net.ports is a table")
				local seen_idx = {}
				for _, p in ipairs(net.ports) do
					assert_true(type(p.idx) == "number", name .. ": port has a numeric idx")
					assert_nil(seen_idx[p.idx], name .. ": port_idx " .. tostring(p.idx) .. " is unique")
					seen_idx[p.idx] = true
					-- Two shapes, and a port must be one of them: a socket
					-- (`swport`, measured through the switch) or a netdev
					-- (`ifname`, for boards with no switch map). An entry that
					-- names neither is a port openUF can report nothing about.
					assert_true((type(p.swport) == "string" or type(p.swport) == "number")
						or (type(p.ifname) == "string" and p.ifname ~= ""),
						name .. ": port " .. p.idx .. " names a swport or an ifname")
					-- The load-bearing invariant: reassigning the uplink's VLAN
					-- strands the device on the far side of its own switch, so
					-- an uplink port must never be VLAN-assignable. Enforced by
					-- convention in switchvlan.lua; pinned here at the source.
					if p.uplink then
						assert_nil(p.swport,
							name .. ": uplink port " .. p.idx .. " must not carry a swport")
					end
					-- A swport either names a dev.conf.vlan.ports key or is a
					-- physical port number outright; anything else is silently
					-- skipped at apply time, i.e. a control that does nothing.
					if p.swport ~= nil then
						local vlan = dev.conf.vlan
						assert_true(type(vlan) == "table" and type(vlan.ports) == "table",
							name .. ": swport requires dev.conf.vlan.ports")
						local ok = type(p.swport) == "number"
							or vlan.ports[p.swport] ~= nil
						assert_true(ok, name .. ": swport " .. tostring(p.swport)
							.. " resolves to a physical port")
					end
				end
			end)
		end
	},
	{
		name = "modelmap: led is a usable shape and hwassign a non-empty list of names",
		fn = function()
			each_modelmap(function(name, dev)
				local led = dev.conf.led
				-- led.lua accepts a bare name, a full sysfs path, or the legacy
				-- {sysfs=...} table; nil means "no LED on this profile".
				if led ~= nil then
					local ok = type(led) == "string"
						or (type(led) == "table" and type(led.sysfs) == "string")
					assert_true(ok, name .. ": led is a string or {sysfs=...}")
					if type(led) == "string" then
						assert_true(led ~= "", name .. ": led name is not empty")
					end
				end
				local hwassign = dev.openuf.uap.hwassign
				if hwassign ~= nil then
					assert_true(type(hwassign) == "table", name .. ": hwassign is a table")
					assert_true(#hwassign > 0,
						name .. ": hwassign is non-empty (an empty list means 'unset')")
					for _, r in ipairs(hwassign) do
						assert_true(type(r) == "string" and r ~= "",
							name .. ": hwassign entries are radio names")
					end
				end
			end)
		end
	},
	{
		name = "modelmap: archer-c5-v1 reports its real sockets and a driveable LED",
		fn = function()
			-- Board-specific regression guard, from the live install on this
			-- hardware: deployed as an AP it uplinks through eth1 (CPU switch
			-- port 0) and never uses eth0, and it has a green:system LED --
			-- the generic profile gets both wrong.
			local dev = dofile(MODELMAP_DIR .. "/archer-c5-v1.lua")
			assert_eq(dev.conf.net.lan_cpueth, "eth1", "LAN CPU port")
			assert_eq(dev.conf.led, "green:system", "LED name set so Locate works")

			-- One port per physical socket, and no static uplink flag: the
			-- board reported a single CPU netdev as "the port" until the first
			-- real-hardware run showed what that costs -- a link speed no
			-- cable had negotiated, and not one wired host placeable on a
			-- socket. The uplink is detected from the switch's ARL table
			-- instead, because on this board it is simply whichever LAN socket
			-- the installer used.
			local ports = dev.conf.net.ports
			assert_eq(#ports, 5, "one port per socket (4 LAN + WAN)")
			local phys = {}
			for _, p in ipairs(ports) do
				assert_nil(p.uplink, "port " .. p.idx .. " is not statically flagged uplink")
				assert_not_nil(p.swport, "port " .. p.idx .. " names a socket")
				local n = dev.conf.vlan.ports[p.swport]
				assert_not_nil(n, "swport " .. tostring(p.swport) .. " is in the switch map")
				phys[#phys + 1] = n
			end
			table.sort(phys)
			assert_eq(table.concat(phys, ","), "1,2,3,4,5",
				"the five sockets, none of them a CPU port")

			-- Switch port map, read off this board's own stock config: VLAN 2
			-- (WAN) is `ports '1 6'`, so physical 1 is the WAN socket and the
			-- LAN sockets are 2-5. The map said lan1..lan4 = 1..4 until a
			-- tagged SSID needed a trunk and the generated port string tagged
			-- the WAN socket while skipping a LAN one. No generic invariant
			-- can catch that -- which physical port faces which socket is
			-- board truth, not derivable from the table -- so it is pinned
			-- here, by the board.
			assert_eq(dev.conf.vlan.ports.wan, 1, "physical 1 is the WAN socket")
			local lan = {}
			for i = 1, 4 do lan[#lan + 1] = dev.conf.vlan.ports["lan" .. i] end
			table.sort(lan)
			assert_eq(table.concat(lan, ","), "2,3,4,5", "the LAN sockets are 2-5")
			assert_eq(dev.conf.vlan.cpu_lan, 0, "eth1 hangs off CPU port 0")
		end
	},
	{
		name = "modelmap: the JioRouter AX6000 maps use the DSA netdev shape",
		fn = function()
			-- Board-specific regression guard for both MT7986A profiles. These
			-- are the tree's only DSA boards and they need the OTHER of
			-- openUF's two port shapes: the MT7531 is kernel-driven, so each
			-- socket is a netdev with its own link state and FDB slice, and
			-- there is no swconfig to ask.
			--
			-- Checked as a pair because they ARE a pair -- same SoC, same
			-- MT7976 radios, same shared dtsi -- and the JIDU6J01 map was
			-- written from the JIDU6101 one. Anything that drifts apart here
			-- should drift on purpose.
			for _, map in ipairs({"jiorouter-ax6000-jidu6101",
			                      "jiorouter-ax6000-jidu6j01"}) do
				local dev = dofile(MODELMAP_DIR .. "/" .. map .. ".lua")

				-- lan_cpueth is the BRIDGE, not a port: it decides the
				-- identity MAC, and on a board where the cable can move
				-- between four equally-valid socket netdevs, naming one of
				-- them would make the device's identity depend on which hole
				-- the installer used. It is also what a tagged SSID's
				-- sub-device hangs off (br-lan.20), and a sub-device on a
				-- bridge PORT would never see a frame.
				assert_eq(dev.conf.net.lan_cpueth, "br-lan",
					map .. ": identity/trunk is the bridge")
				assert_eq(dev.conf.led, "green:status",
					map .. ": LED name set so Locate works")

				-- No swconfig map: setting one would send inform.lua down the
				-- switch path, shelling out to a swconfig that isn't
				-- installed, and switchvlan.lua would have to detect DSA and
				-- refuse on every push. Its absence keeps both on the netdev
				-- path.
				assert_nil(dev.conf.vlan, map .. ": no swconfig port map on a DSA board")

				assert_eq(dev.conf.net.uplink_detect, "fdb",
					map .. ": the uplink socket is measured, not declared")
				local ports = dev.conf.net.ports
				assert_eq(#ports, 5, map .. ": one port per socket (4 LAN + WAN)")
				local names = {}
				for _, p in ipairs(ports) do
					assert_nil(p.uplink, map .. ": port " .. p.idx .. " is not statically flagged uplink")
					assert_nil(p.swport, map .. ": port " .. p.idx .. " names no swconfig socket")
					assert_not_nil(p.ifname, map .. ": port " .. p.idx .. " names a netdev")
					names[#names + 1] = p.ifname
				end
				-- The SET is the invariant; the ORDER is a board choice. `idx`
				-- is the UniFi port_idx and the controller keys per-port
				-- settings on it, so what actually matters is that every
				-- socket appears exactly once and that the numbering stays
				-- PINNED once a device is adopted -- renumbering later moves
				-- which physical socket the controller's "Port 1" means.
				-- Asserting the declared order instead just made this test
				-- fail every time a map was legitimately re-ordered.
				--
				-- Both boards land on the same five names even though their
				-- DTS files disagree about which switch reg carries which
				-- label (the 6101 rotates, the 6J01 is straight): a DSA netdev
				-- is named for its label, not its reg.
				table.sort(names)
				assert_eq(table.concat(names, ","), "lan1,lan2,lan3,lan4,wan",
					map .. ": all five sockets, each exactly once")
			end
		end
	},
	{
		name = "modelmap: one JIDU6J01 profile serves the whole retail family",
		fn = function()
			-- OpenWrt builds ONE image for JIDU6J01/6201/6401/6601/6701 from a
			-- single DTS, so all five report the same compatible string and
			-- differ only in where board.d reads the label MAC from in the MFG
			-- partition -- resolved at first boot, before openUF starts.
			--
			-- The tempting mistake is to "complete" the list by adding the
			-- retail names. `ubus call system board` never emits them, so the
			-- extra entries would be dead weight that reads like coverage, and
			-- a real second map claiming any of them would make setup.sh's
			-- choice between the two arbitrary.
			local dev = dofile(MODELMAP_DIR .. "/jiorouter-ax6000-jidu6j01.lua")
			assert_eq(#dev.openwrt_boards, 1, "exactly one board name for five variants")
			assert_eq(dev.openwrt_boards[1], "jiorouter,ax6000-jidu6j01",
				"the family compatible string, not a retail variant name")

			-- The variant digits appear in no map's board list, in either
			-- direction: not here, and not as a separate profile.
			each_modelmap(function(name, d)
				for _, b in ipairs(d.openwrt_boards or {}) do
					assert_true(b:match("jidu6[2467]01$") == nil,
						name .. ": '" .. b .. "' is a retail variant ubus never reports")
				end
			end)
		end
	},
	{
		name = "modelmap: uplink_detect is only ever asked for on the netdev shape",
		fn = function()
			-- The two uplink-detection paths read different sources (bridge FDB
			-- vs swconfig ARL) and inform.lua picks between them on the shape
			-- of the port entry, not on this flag. A map that set both would
			-- have its `fdb` request silently ignored on any port with a
			-- swport, which is a control that does nothing.
			each_modelmap(function(name, dev)
				local detect = dev.conf.net.uplink_detect
				if detect == nil then return end
				assert_eq(detect, "fdb", name .. ": the only detection mode is fdb")
				assert_nil(dev.conf.vlan,
					name .. ": fdb detection is for boards with no swconfig map")
				for _, p in ipairs(dev.conf.net.ports or {}) do
					assert_nil(p.swport,
						name .. ": port " .. p.idx .. " must not also name a swport")
					assert_nil(p.uplink,
						name .. ": port " .. p.idx .. " must not also declare the uplink")
				end
			end)
		end
	},
	{
		name = "modelmap: openwrt_boards names real board strings, and no two maps claim one",
		fn = function()
			-- tools/openuf-setup.sh reads this to preselect a profile from
			-- `ubus call system board`. Two maps claiming the same board makes
			-- that choice arbitrary; a malformed entry makes it silently never
			-- match, and the installer falls back to a generic profile on
			-- hardware it actually has a map for.
			local claimed = {}
			each_modelmap(function(name, dev)
				local boards = dev.openwrt_boards
				-- Optional: the generic profiles are for no board in
				-- particular, which is the whole point of them.
				-- "autodetected.lua" is what setup.sh writes when it profiles an
				-- unknown DSA board on the device. It is never committed, but the
				-- suite runs against a working tree that may have one lying
				-- around, and it legitimately claims no board -- it describes
				-- exactly one machine.
				if boards == nil then
					assert_true(name:match("^generic%-") ~= nil or name == "autodetected.lua",
						name .. ": only a generic or generated profile may omit openwrt_boards")
					return
				end
				assert_true(type(boards) == "table", name .. ": openwrt_boards is a table")
				assert_true(#boards > 0, name .. ": openwrt_boards is non-empty")
				for _, b in ipairs(boards) do
					-- OpenWrt board names are the DTS compatible string:
					-- "vendor,model". Anything else never matches ubus.
					assert_true(type(b) == "string" and b:match("^[%w_%-]+,[%w_%-%.]+$") ~= nil,
						name .. ": '" .. tostring(b) .. "' is a vendor,model board name")
					assert_nil(claimed[b], "board " .. b .. " is claimed by "
						.. tostring(claimed[b]) .. " as well as " .. name)
					claimed[b] = name
				end
			end)
		end
	},
	{
		name = "modelmap: a board's LAN ports never collide with its WAN port",
		fn = function()
			-- The trunk a tagged SSID needs is built from dev.conf.vlan.ports,
			-- tagging every LAN entry. Getting the map wrong therefore tags a
			-- socket facing a different network and skips one that matters --
			-- which is exactly what the Archer map did (lan1..lan4 = 1..4
			-- while physical 1 is the WAN socket), latent right up until the
			-- first VLAN SSID.
			each_modelmap(function(name, dev)
				local vlan = dev.conf.vlan
				if vlan == nil or vlan.ports == nil then return end
				local wan = vlan.ports.wan
				local seen = {}
				for label, phys in pairs(vlan.ports) do
					assert_true(type(phys) == "number",
						name .. ": vlan.ports." .. label .. " is a physical port number")
					assert_nil(seen[phys],
						name .. ": physical port " .. tostring(phys) .. " is mapped twice")
					seen[phys] = label
					if label ~= "wan" and wan ~= nil then
						assert_true(phys ~= wan,
							name .. ": " .. label .. " must not be the WAN port")
					end
					assert_true(phys ~= vlan.cpu_lan and phys ~= vlan.cpu_wan,
						name .. ": " .. label .. " must not be a CPU port")
				end
			end)
		end
	},
	{
		name = "modelmap: xiaomi-ax3000t reports its real sockets on a DSA board",
		fn = function()
			-- Upstream's first DSA board, adopted here. Its shape differs from
			-- the JioRouter maps in one deliberate way: lan_cpueth names the
			-- uplink SOCKET (whose MAC is the board's label MAC), not the
			-- bridge -- so sysinfo.lan_bridge has to find br-lan through the
			-- socket's master, and this pins that the map still asks for FDB
			-- detection like every other DSA map here.
			local dev = dofile("openuf/modelmap/xiaomi-ax3000t.lua")
			assert_eq(dev.conf.net.lan_cpueth, "wan",
				"the uplink socket, whose MAC is the board's label MAC")
			assert_eq(dev.conf.net.uplink_detect, "fdb", "uplink is detected, never declared")
			assert_eq(dev.conf.led, "blue:status",
				"the board's real case LED, not the unwired mt76 radio LED")
			assert_eq(dev.openwrt_boards[1], "xiaomi,mi-router-ax3000t",
				"claims the stock board name so setup.sh preselects it")
			assert_eq(dev.openwrt_boards[2], "xiaomi,mi-router-ax3000t-ubootmod",
				"and the ubootmod build, which shares the DTS sockets")
			local ports = dev.conf.net.ports
			assert_eq(#ports, 4, "four sockets -- this board has no lan1")
			local names = {}
			for _, p in ipairs(ports) do
				assert_nil(p.uplink, "port " .. p.idx .. " is not statically flagged uplink")
				assert_nil(p.swport, "port " .. p.idx .. " carries no swconfig port")
				names[#names + 1] = p.ifname
			end
			table.sort(names)
			assert_eq(table.concat(names, ","), "lan2,lan3,lan4,wan", "the board's real DSA port names")
			assert_nil(dev.conf.vlan, "no swconfig port map on a DSA board")
		end
	},
	{
		-- Five call sites read cfg.vlan.device -- switchvlan's backend
		-- detection, its VLAN-table sizing and the swconfig port reads in
		-- inform -- and every one of them fell through to a hardcoded
		-- "switch0", because no modelmap ever set it. On a board whose switch
		-- is switch1 (common on ath79 and ramips) every swconfig call then
		-- addressed a device that does not exist, silently: per-socket port
		-- reporting degraded to the CPU-port netdev with nothing logged.
		name = "modelmap: every swconfig map names its switch device",
		fn = function()
			each_modelmap(function(name, dev)
				local vlan = dev.conf and dev.conf.vlan
				-- A DSA board has no swconfig and declares no vlan block at
				-- all; the key is meaningless there.
				if type(vlan) ~= "table" then return end
				assert_eq(type(vlan.device), "string",
					name .. ": declares vlan.device rather than relying on the "
					.. "\"switch0\" fallback")
				assert_true(vlan.device:match("^%w+$") ~= nil,
					name .. ": vlan.device looks like a swconfig device name")
			end)
		end
	},
	{
		name = "modelmap: archer-a7-v5 pins the one-trunk AR8327 board for all three Archers",
		fn = function()
			-- Board-specific regression guard, from the OpenWrt tree rather
			-- than a live unit (none has run openUF yet). board.d gives the
			-- A7 v5, C7 v4 and C7 v5 ONE case arm -- `0@eth0`, a TAGGED CPU
			-- port on a single trunk, WAN on physical 1 and LAN1..4 on 2..5
			-- -- and 01_leds' per-socket LED port masks say the same. None
			-- of it is derivable from the table, so it is pinned here.
			local dev = dofile(MODELMAP_DIR .. "/archer-a7-v5.lua")

			-- One trunk: the identity / VLAN netdev is eth0 itself, never the
			-- eth0.1 sub-device. A pushed VLAN must become eth0.20, a sibling
			-- of eth0.1, not a sub-device of a sub-device.
			assert_eq(dev.conf.net.lan_cpueth, "eth0", "the trunk, not the LAN VLAN sub-device")
			assert_eq(dev.conf.vlan.cpu_lan, 0, "CPU port 0 serves the LAN VLAN")
			assert_eq(dev.conf.vlan.cpu_wan, 0,
				"and the same port serves the WAN VLAN -- the board has no second CPU port")

			-- The LED is one no DTS alias drives: led-boot / led-failsafe /
			-- led-running / led-upgrade all name green:system on these boards.
			assert_eq(dev.conf.led, "green:wps", "an LED procd does not own")

			-- Three compatible strings, one board as far as openUF reads.
			local boards = {}
			for _, b in ipairs(dev.openwrt_boards) do boards[#boards + 1] = b end
			table.sort(boards)
			assert_eq(table.concat(boards, " "),
				"tplink,archer-a7-v5 tplink,archer-c7-v4 tplink,archer-c7-v5",
				"claims the A7 v5 and both C7 revisions that share its board.d entry")

			-- Five sockets, none a CPU port, none statically the uplink.
			local ports = dev.conf.net.ports
			assert_eq(#ports, 5, "one port per socket (4 LAN + WAN)")
			local phys = {}
			for _, p in ipairs(ports) do
				assert_nil(p.uplink, "port " .. p.idx .. " is not statically flagged uplink")
				assert_not_nil(p.swport, "port " .. p.idx .. " names a socket")
				local n = dev.conf.vlan.ports[p.swport]
				assert_not_nil(n, "swport " .. tostring(p.swport) .. " is in the switch map")
				phys[#phys + 1] = n
			end
			table.sort(phys)
			assert_eq(table.concat(phys, ","), "1,2,3,4,5",
				"the five sockets, none of them the CPU port")

			-- Switch map in case-label order: board.d "2:lan:1" .. "5:lan:4"
			-- "1:wan", and 01_leds WAN=0x02, LAN1=0x04 .. LAN4=0x20. Unlike
			-- the Archer C5 test this pins the ORDER, because the source
			-- states it; a unit proving the labels reversed changes the map
			-- and this assertion together.
			assert_eq(dev.conf.vlan.ports.wan, 1, "physical 1 is the WAN socket")
			for i = 1, 4 do
				assert_eq(dev.conf.vlan.ports["lan" .. i], i + 1,
					"LAN" .. i .. " is physical " .. (i + 1))
			end

			-- The WiFi 5 identity for WiFi 5 hardware with the same five
			-- sockets. If this ever goes back to u6iw it should be because a
			-- controller refused UHDIW, and the map header should say so.
			assert_eq(dev.openuf.uap.ufmodel, "uhdiw", "presents as a UAP-IW-HD")
			assert_eq(#dev.openuf.uap.hwassign, 2, "both radios reported")
		end
	},
	{
		name = "modelmap: deco-m5 pins the two-socket IPQ4019 DSA board for all three revisions",
		fn = function()
			-- Board-specific regression guard, from the OpenWrt tree rather
			-- than a live unit (none has run openUF yet). One .dtsi gives the
			-- v1, v2 and v3 the same two DSA sockets ("lan" = swport4, "wan" =
			-- swport5) and board.d one case arm; the revisions differ only in
			-- how the single RGB LED is wired, which the map resolves at load.
			local dev = dofile(MODELMAP_DIR .. "/deco-m5.lua")

			-- DSA: the bridge is the identity / trunk netdev, the uplink is
			-- measured, and there is no swconfig map to drift.
			assert_eq(dev.conf.net.lan_cpueth, "br-lan", "the LAN bridge, per the DSA rule")
			assert_eq(dev.conf.net.uplink_detect, "fdb", "uplink is detected, never declared")
			assert_nil(dev.conf.vlan, "no swconfig port map on a DSA board")

			-- Three compatible strings, one board as far as openUF reads.
			local boards = {}
			for _, b in ipairs(dev.openwrt_boards) do boards[#boards + 1] = b end
			table.sort(boards)
			assert_eq(table.concat(boards, " "),
				"tplink,deco-m5-v1 tplink,deco-m5-v2 tplink,deco-m5-v3",
				"claims all three Deco M5 revisions, which share one .dtsi")

			-- Two sockets and nothing else: no CPU netdev row, no static
			-- uplink, no swconfig port.
			local ports = dev.conf.net.ports
			assert_eq(#ports, 2, "one port per socket -- the board has two")
			local names = {}
			for _, p in ipairs(ports) do
				assert_nil(p.uplink, "port " .. p.idx .. " is not statically flagged uplink")
				assert_nil(p.swport, "port " .. p.idx .. " carries no swconfig port")
				names[#names + 1] = p.ifname
			end
			table.sort(names)
			assert_eq(table.concat(names, ","), "lan,wan", "the board's real DSA port names")

			-- The LED is resolved from /sys/class/leds at load: the lp5521's
			-- chan-name on v1/v2, the gpio-leds color:function on v3. On a
			-- build host neither exists and the map must fall back to nil (a
			-- no-op), never to a guessed name.
			local led = dev.conf.led
			assert_true(led == nil or led == "power:green" or led == "green:power",
				"led is one of the two revision names or nil, got " .. tostring(led))

			-- The two-socket WiFi 5 identity. If this ever goes back to u6iw
			-- it should be because a controller refused U7HD, and the map
			-- header should say so.
			assert_eq(dev.openuf.uap.ufmodel, "u7hd", "presents as a UAP-AC-HD")
			assert_eq(#dev.openuf.uap.hwassign, 2, "both radios reported")
		end
	},
	{
		name = "modelmap: deco-m4r-v1 pins the two-socket QCA9563 swconfig board, one name for the v1 and v2",
		fn = function()
			-- Board-specific regression guard, from the OpenWrt tree rather
			-- than a live unit (none has run openUF yet). board.d gives the
			-- board `0@eth0` -- a TAGGED CPU port on a single trunk -- and
			-- exactly two sockets, physical 3 ("lan:1") and 5 ("lan:2"),
			-- with NO wan entry at all; OpenWrt's commit 063e9047cc builds
			-- the v2 from the v1's DTS, so there is one compatible string.
			local dev = dofile(MODELMAP_DIR .. "/deco-m4r-v1.lua")

			-- One trunk: the identity / VLAN netdev is eth0 itself, never the
			-- eth0.1 sub-device.
			assert_eq(dev.conf.net.lan_cpueth, "eth0", "the trunk, not the LAN VLAN sub-device")
			assert_eq(dev.conf.vlan.device, "switch0", "the swconfig device")
			assert_eq(dev.conf.vlan.cpu_lan, 0, "CPU port 0 serves the LAN VLAN")
			assert_eq(dev.conf.vlan.cpu_wan, 0, "and is the only CPU port")

			-- No WAN role anywhere: not a switch port, not a CPU netdev.
			-- OpenWrt makes both sockets LAN, so a `wan` here would name a
			-- socket that does not exist and tag the trunk for it.
			assert_nil(dev.conf.vlan.ports.wan, "the board has no WAN socket")
			assert_nil(dev.conf.net.wan_cpueth, "and no WAN CPU netdev to name")

			-- One board name. A v2 reports "tplink,deco-m4r-v1" too (no v2
			-- DTS exists), and the MediaTek v4 is another map.
			assert_eq(#dev.openwrt_boards, 1, "exactly one compatible string")
			assert_eq(dev.openwrt_boards[1], "tplink,deco-m4r-v1",
				"the one DTS OpenWrt builds for the v1 and the v2")

			-- Two sockets, physical 3 and 5, neither the CPU port, neither
			-- statically the uplink.
			local ports = dev.conf.net.ports
			assert_eq(#ports, 2, "one port per socket -- the board has two")
			local phys = {}
			for _, p in ipairs(ports) do
				assert_nil(p.uplink, "port " .. p.idx .. " is not statically flagged uplink")
				assert_not_nil(p.swport, "port " .. p.idx .. " names a socket")
				local n = dev.conf.vlan.ports[p.swport]
				assert_not_nil(n, "swport " .. tostring(p.swport) .. " is in the switch map")
				phys[#phys + 1] = n
			end
			table.sort(phys)
			assert_eq(table.concat(phys, ","), "3,5",
				"board.d's \"3:lan:1\" \"5:lan:2\" -- the set is certain, the order is one sample")
			assert_eq(dev.conf.vlan.ports.lan1, 3, "LAN1 is physical 3")
			assert_eq(dev.conf.vlan.ports.lan2, 5, "LAN2 is physical 5")

			-- The running LED, the Deco M5's trade: procd owns every channel
			-- of the one case light, so the green it leaves steady is taken.
			assert_eq(dev.conf.led, "green:power", "the case light's green channel")

			-- The two-socket WiFi 5 identity, shared with the v4 map.
			assert_eq(dev.openuf.uap.ufmodel, "u7hd", "presents as a UAP-AC-HD")
			assert_eq(#dev.openuf.uap.hwassign, 2, "both radios reported")
		end
	},
	{
		name = "modelmap: deco-m4r-v4 pins the MT7621 DSA board whose two sockets are named eth0 and eth1",
		fn = function()
			-- Board-specific regression guard, from the OpenWrt tree rather
			-- than a live unit (none has run openUF yet). The DTS (commit
			-- 4fed462454) names switch port 0 "eth0", switch port 1 "eth1"
			-- and the CPU conduit "dsa", so the swconfig-era reading of
			-- "eth0" -- a CPU trunk -- is exactly wrong here. board.d:
			-- ucidef_set_interfaces_lan_wan "eth1" "eth0".
			local dev = dofile(MODELMAP_DIR .. "/deco-m4r-v4.lua")

			-- DSA: the bridge is the identity / trunk netdev, the uplink is
			-- measured, and there is no swconfig map to drift.
			assert_eq(dev.conf.net.lan_cpueth, "br-lan", "the LAN bridge, per the DSA rule")
			assert_eq(dev.conf.net.uplink_detect, "fdb", "uplink is detected, never declared")
			assert_nil(dev.conf.vlan, "no swconfig port map on a DSA board")
			assert_eq(dev.conf.net.wan_cpueth, "eth0", "OpenWrt's WAN role is the socket eth0")

			-- One board name; the Qualcomm v1/v2 is another map.
			assert_eq(#dev.openwrt_boards, 1, "exactly one compatible string")
			assert_eq(dev.openwrt_boards[1], "tplink,deco-m4r-v4", "the v4 DTS")

			-- Two sockets named eth0 and eth1 -- as netdevs, not as CPU
			-- ports: no swport, no static uplink.
			local ports = dev.conf.net.ports
			assert_eq(#ports, 2, "one port per socket -- the board has two")
			local names = {}
			for _, p in ipairs(ports) do
				assert_nil(p.uplink, "port " .. p.idx .. " is not statically flagged uplink")
				assert_nil(p.swport, "port " .. p.idx .. " carries no swconfig port")
				names[#names + 1] = p.ifname
			end
			table.sort(names)
			assert_eq(table.concat(names, ","), "eth0,eth1",
				"the board's real DSA port names -- sockets, despite the names")

			-- The running LED, the Deco M5's trade, on the one case light.
			assert_eq(dev.conf.led, "green:logo", "the logo's green channel")

			-- Both M4R maps present the same identity: the controller sees
			-- one retail product whichever silicon is inside.
			local v1 = dofile(MODELMAP_DIR .. "/deco-m4r-v1.lua")
			assert_eq(dev.openuf.uap.ufmodel, "u7hd", "presents as a UAP-AC-HD")
			assert_eq(v1.openuf.uap.ufmodel, dev.openuf.uap.ufmodel,
				"the Qualcomm and MediaTek revisions share one UniFi identity")
			assert_eq(#dev.openuf.uap.hwassign, 2, "both radios reported")
		end
	},
	{
		name = "modelmap: openwrt-one pins the switchless two-socket board and its U6 Mesh Pro identity",
		fn = function()
			-- Board-specific regression guard, from the OpenWrt tree rather
			-- than a live unit (none has run openUF yet). The board has no
			-- switch: mt7981b-openwrt-one.dts gives each socket its own
			-- ethernet MAC (gmac0 = eth0, 2.5 GbE; gmac1 = eth1, GbE) and
			-- board.d says ucidef_set_interfaces_lan_wan eth1 eth0.
			local dev = dofile(MODELMAP_DIR .. "/openwrt-one.lua")

			-- The netdev shape without a DSA switch: the bridge is the
			-- identity / trunk netdev, the uplink is measured, and there
			-- is no swconfig map. "eth0" as lan_cpueth -- the generic
			-- maps' reading -- would name a bridge port here.
			assert_eq(dev.conf.net.lan_cpueth, "br-lan", "the LAN bridge, not a socket")
			assert_eq(dev.conf.net.uplink_detect, "fdb", "uplink is detected, never declared")
			assert_nil(dev.conf.vlan, "no swconfig port map on a board with no switch")
			assert_eq(dev.conf.net.wan_cpueth, "eth0", "OpenWrt's WAN role is the 2.5 GbE socket eth0")

			-- One retail model, one compatible string (no DEVICE_ALT in
			-- filogic.mk's Device/openwrt_one).
			assert_eq(#dev.openwrt_boards, 1, "exactly one compatible string")
			assert_eq(dev.openwrt_boards[1], "openwrt,one", "the DTS compatible")

			-- Two sockets, pinned to their idx: the controller keys
			-- per-port settings on it, so the order is a contract once a
			-- unit is adopted. idx 1 is the 2.5 GbE / PoE-in socket, the
			-- U6 Mesh Pro's port 1.
			local ports = dev.conf.net.ports
			assert_eq(#ports, 2, "one port per socket -- the board has two")
			for _, p in ipairs(ports) do
				assert_nil(p.uplink, "port " .. p.idx .. " is not statically flagged uplink")
				assert_nil(p.swport, "port " .. p.idx .. " carries no swconfig port")
			end
			assert_eq(ports[1].idx, 1, "first entry is port 1")
			assert_eq(ports[1].ifname, "eth0", "port 1 is eth0, the 2.5 GbE socket")
			assert_eq(ports[2].idx, 2, "second entry is port 2")
			assert_eq(ports[2].ifname, "eth1", "port 2 is eth1, the GbE socket")

			-- The running LED: procd claims all three status channels
			-- (DTS aliases), so the map takes led-running's.
			assert_eq(dev.conf.led, "green:status", "the status light's green channel")

			-- Nothing measured, so no policy that overrides the controller.
			assert_nil(dev.conf.radio, "no radio policy until one is measured on a unit")

			-- The WiFi 6 two-socket identity. If this ever reads u6iw it
			-- should be because a controller refused U6MP, and the map
			-- header should say so.
			assert_eq(dev.openuf.uap.ufmodel, "u6mp", "presents as a U6 Mesh Pro")
			assert_eq(#dev.openuf.uap.hwassign, 2, "both radios reported")
		end
	},
	{
		name = "modelmap: linksys-wrt3200acm pins the five-socket mv88e6xxx board, two of its three radios and the WPS LED",
		fn = function()
			-- Board-specific regression guard, from the OpenWrt tree and
			-- the kernel's armada-385-linksys{.dtsi,-rango.dts} rather
			-- than a live unit (none has run openUF yet).
			local dev = dofile(MODELMAP_DIR .. "/linksys-wrt3200acm.lua")

			-- DSA: the bridge is the identity / trunk netdev, the uplink is
			-- measured, and there is no swconfig map to drift.
			assert_eq(dev.conf.net.lan_cpueth, "br-lan", "the LAN bridge, per the DSA rule")
			assert_eq(dev.conf.net.uplink_detect, "fdb", "uplink is detected, never declared")
			assert_nil(dev.conf.vlan, "no swconfig port map on a DSA board")
			assert_eq(dev.conf.net.wan_cpueth, "wan", "OpenWrt's WAN role is the socket wan")

			-- board_name is the FIRST compatible string (patch 311).
			-- "linksys,rango", the second, is never reported, and the
			-- WRT32X ("linksys,wrt32x") is another device.
			assert_eq(#dev.openwrt_boards, 1, "exactly one compatible string")
			assert_eq(dev.openwrt_boards[1], "linksys,wrt3200acm", "the patched DTS compatible")

			-- Five sockets in case order, pinned to their idx: the
			-- controller keys per-port settings on it.
			local ports = dev.conf.net.ports
			assert_eq(#ports, 5, "one port per socket -- the board has five")
			local want = {"lan1", "lan2", "lan3", "lan4", "wan"}
			for i, p in ipairs(ports) do
				assert_eq(p.idx, i, "entry " .. i .. " is port " .. i)
				assert_eq(p.ifname, want[i], "port " .. i .. " is " .. want[i])
				assert_nil(p.uplink, "port " .. i .. " is not statically flagged uplink")
				assert_nil(p.swport, "port " .. i .. " carries no swconfig port")
			end

			-- The WPS light: the one no procd alias or board.d trigger
			-- drives. And never the two "wlan" LEDs of the release
			-- images, which are the WiFi cards' reset lines (patch 950):
			-- blinking one takes a radio off the bus until a reboot.
			assert_eq(dev.conf.led, "pca963x:rango:white:wps", "the WPS light's white channel")
			assert_true(not tostring(dev.conf.led):find("wlan", 1, true),
				"the LED is not one of the WiFi cards' reset lines")

			-- Nothing measured, so no policy that overrides the controller.
			assert_nil(dev.conf.radio, "no radio policy until one is measured on a unit")

			-- Two radios reported. radio2 is the 88W8887 on SDIO, which a
			-- UAP-IW-HD has no counterpart for; listing it would show the
			-- controller a third radio.
			local hw = dev.openuf.uap.hwassign
			assert_eq(table.concat(hw, ","), "radio0,radio1", "the two 88W8964 cards, not radio2")

			-- The five-socket WiFi 5 identity, as on the Archer A7 map.
			assert_eq(dev.openuf.uap.ufmodel, "uhdiw", "presents as a UAP-IW-HD")
		end
	},
	{
		name = "modelmap: dynalink-dl-wrx36 pins the five-socket IPQ8072A board in the netdev shape",
		fn = function()
			-- Board-specific regression guard, from the OpenWrt tree rather
			-- than a live unit (none has run openUF yet). The DTS labels its
			-- switch ports lan4, lan3, lan2, lan1 (ports 1-4) and wan (port
			-- 6); OpenWrt main drives them as DSA user ports, 24.10/25.12 as
			-- nss-dp netdevs of the same names, and board.d gives
			-- ucidef_set_interfaces_lan_wan "lan1 lan2 lan3 lan4" "wan".
			local dev = dofile(MODELMAP_DIR .. "/dynalink-dl-wrx36.lua")

			assert_eq(#dev.openwrt_boards, 1, "exactly one compatible string")
			assert_eq(dev.openwrt_boards[1], "dynalink,dl-wrx36", "the DTS compatible")

			-- The netdev shape: the bridge is the identity / trunk netdev, the
			-- uplink is measured, and there is no swconfig map.
			assert_eq(dev.conf.net.lan_cpueth, "br-lan", "the LAN bridge, per the DSA rule")
			assert_eq(dev.conf.net.uplink_detect, "fdb", "uplink is detected, never declared")
			assert_nil(dev.conf.vlan, "no swconfig port map")
			assert_eq(dev.conf.net.wan_cpueth, "wan", "OpenWrt's WAN role is the socket wan")

			local ports = dev.conf.net.ports
			assert_eq(#ports, 5, "one port per socket: four LAN and the 2.5G WAN")
			local names = {}
			for _, p in ipairs(ports) do
				assert_nil(p.uplink, "port " .. p.idx .. " is not statically flagged uplink")
				assert_nil(p.swport, "port " .. p.idx .. " carries no swconfig port")
				names[#names + 1] = p.ifname
			end
			table.sort(names)
			assert_eq(table.concat(names, ","), "lan1,lan2,lan3,lan4,wan", "every socket once")

			-- The running LED, named by colour alone: the nodes lost their
			-- "blue:system" label in 2e659930d3 and have no function, so the
			-- kernel calls them "blue:" and "red:".
			assert_eq(dev.conf.led, "blue:", "procd's running channel, by its colour-only name")

			-- The identity's width floor, not a hardware measurement; the
			-- mt7915-specific DFS and 160 MHz answers stay with the JioRouters.
			assert_eq(dev.conf.radio.na.htmode_floor, "HE80", "the U6IW 40 MHz default raised")
			assert_nil(dev.conf.radio.na.acs_exclude_dfs, "no DFS exclusion without evidence on ath11k")
			assert_nil(dev.conf.radio.na.htmode_max, "no ceiling without evidence")

			assert_eq(dev.openuf.uap.ufmodel, "u6iw", "presents as a U6-InWall, as the JioRouters do")
			assert_eq(#dev.openuf.uap.hwassign, 2, "both radios reported")
		end
	},
}
