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
}
