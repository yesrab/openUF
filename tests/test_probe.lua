-- hook/probe.lua: the JSON the web UI reads, built through seams.
OPENUF_TEST_MODE = true
local probe = dofile("openuf/hook/probe.lua")
probe._modelmap_dir = "openuf/modelmap"
probe._ufmodel_dir  = "openuf/ufmodel"

-- A whole fake device for discover(): board.json text, sysfs LEDs, device-tree
-- LED aliases and nodes, netdevs, the wireless config's radios, iw output.
local function with_device(d, fn)
	local orig = {read = probe._read_file, list = probe._list_dir_plain, exists = probe._exists,
		run = probe._run_cmd, uci = probe._uci}
	local function be32(n)
		return string.char(math.floor(n / 16777216) % 256, math.floor(n / 65536) % 256,
			math.floor(n / 256) % 256, n % 256)
	end
	-- The directories go into patterns; "device-tree" has a magic "-".
	local function esc(str) return (str:gsub("%p", "%%%0")) end
	local LEDS, ALIASES, DT, NET = esc(probe._leds_dir), esc(probe._dt_aliases_dir), esc(probe._dt_root), esc(probe._net_dir)
	probe._read_file = function(path)
		if path == probe._board_json_file then return d.board end
		if path == probe._board_name_file then return d.board_name end
		local led, what = path:match("^" .. LEDS .. "/([^/]+)/(%w+)$")
		if led and what == "trigger" then
			local t = d.leds and d.leds[led]
			return t and ("none " .. (t.trigger ~= "none" and ("[" .. t.trigger .. "]") or "[none]") .. "\n") or nil
		end
		local alias = path:match("^" .. ALIASES .. "/(.+)$")
		if alias then return d.aliases and d.aliases[alias] and (d.aliases[alias] .. "\0") or nil end
		local node, prop = path:match("^" .. DT .. "(/leds/[^/]+)/(.+)$")
		if node then
			local n = d.dt and d.dt[node]
			if not n then return nil end
			if prop == "label" then return n.label and (n.label .. "\0") or nil end
			if prop == "function" then return n["function"] and (n["function"] .. "\0") or nil end
			if prop == "color" then return n.color and be32(n.color) or nil end
			return nil
		end
		local dev, attr = path:match("^" .. NET .. "/([^/]+)/(.+)$")
		if dev then
			local n = d.net and d.net[dev]
			if not n then return nil end
			if attr == "address" then return n.mac .. "\n" end
			if attr == "operstate" then return (n.state or "up") .. "\n" end
			return nil
		end
		return orig.read(path)
	end
	probe._list_dir_plain = function(dir)
		local names = {}
		local src = (dir == probe._leds_dir and d.leds) or (dir == probe._dt_aliases_dir and d.aliases)
			or (dir == probe._net_dir and d.net) or {}
		for k in pairs(src) do names[#names + 1] = k end
		table.sort(names)
		return names
	end
	probe._exists = function(path)
		local dev, attr = path:match("^" .. NET .. "/([^/]+)/(.+)$")
		if dev and d.net and d.net[dev] then
			if attr == "dsa/tagging" then return d.net[dev].dsa or false end
			if attr == "bridge/bridge_id" then return d.net[dev].bridge or false end
		end
		return false
	end
	probe._run_cmd = function(cmd)
		local phy = cmd:match("iw phy (%S+) info")
		return phy and d.iw and d.iw[phy] or ""
	end
	probe._uci = {cursor = function()
		return {foreach = function(_, cfg, stype, cb)
			if cfg == "wireless" and stype == "wifi-device" then
				for _, r in ipairs(d.radios or {}) do
					cb({[".name"] = r.name, [".type"] = "wifi-device", path = r.path, band = r.band})
				end
			end
		end, get_all = function() return nil end}
	end}
	local ok, err = pcall(fn)
	probe._read_file, probe._list_dir_plain, probe._exists, probe._run_cmd, probe._uci =
		orig.read, orig.list, orig.exists, orig.run, orig.uci
	if not ok then error(err, 0) end
end

local function fixture(name)
	local f = io.open("tests/fixtures/" .. name, "r")
	if not f then return nil end
	local s = f:read("*a"); f:close(); return s
end

local function with_files(files, fn)
	local orig = {read = probe._read_file, vaps = probe._vaps}
	probe._read_file = function(path)
		if files[path] ~= nil then return files[path] or nil end
		return orig.read(path)
	end
	probe._vaps = files.vaps or function() return {} end
	local ok, err = pcall(fn)
	probe._read_file, probe._vaps = orig.read, orig.vaps
	if not ok then error(err, 0) end
end

return {
	{
		name = "probe: presets lists every shipped map with its title, boards and the auto match",
		fn = function()
			with_files({[probe._board_name_file] = "jiorouter,ax6000-jidu6101\n"}, function()
				local p = probe.presets()
				assert_eq(p.board, "jiorouter,ax6000-jidu6101", "board read")
				assert_eq(p.auto, "jiorouter-ax6000-jidu6101", "the preset auto would pick")
				local by = {}
				for _, m in ipairs(p.modelmaps) do by[m.name] = m end
				assert_not_nil(by["archer-c5-v1"], "swconfig map listed")
				assert_eq(by["archer-c5-v1"].title, "TP-Link Archer C5 v1", "title from the header, suffix dropped")
				assert_eq(by["archer-c5-v1"].boards[1], "tplink,archer-c5-v1", "boards from dev.openwrt_boards")
				assert_eq(by["archer-c5-v1"].ufmodel, "u6iw", "its identity")
				assert_false(by["archer-c5-v1"].dsa, "swconfig")
				assert_true(by["jiorouter-ax6000-jidu6101"].dsa, "DSA")
				assert_true(by["archer-a7-v5"].unverified, "the ⚠ header is reported")
				assert_true(#p.ufmodels >= 4, "identities listed")
				local u6
				for _, u in ipairs(p.ufmodels) do if u.name == "u6iw" then u6 = u end end
				assert_eq(u6.model, "U6IW", "identity model")
				assert_true(u6.fw_ver:match("^%d+%.%d+%.%d+%.%d+$") ~= nil, "bare firmware version")
				assert_eq(u6.title, "U6-InWall", "identity title, suffix dropped")
			end)
			with_files({[probe._board_name_file] = false}, function()
				local p = probe.presets()
				assert_nil(p.board, "no board file")
				assert_nil(p.auto, "no auto match without a board")
			end)
		end
	},
	{
		name = "probe: describe() reports the resolved profile, identity, config, state (no authkey), health and ledger",
		fn = function()
			local dev = dofile("openuf/modelmap/jiorouter-ax6000-jidu6101.lua")
			dev.modelmap_name = "jiorouter-ax6000-jidu6101"
			local config = {inform_url = "http://c:8080/inform", use_only_unifi_wlan = true,
				l2_announce = false, rrm_request_interval = 600, state_file = "/tmp/t-state.json",
				unhandled_file = "/tmp/t-unhandled.json", debug_caps = {wifi_caps = 1}}
			with_files({
				["/tmp/t-state.json"] = '{"adopted":true,"authkey":"deadbeef","mac":"00:00:5e:00:53:01",'
					.. '"inform_url":"http://c:8080/inform","cfgversion":"abc","l2guard":{"bpdu":true,"tagdrop":true,"ifnames":["a","b"]}}',
				["/tmp/t-unhandled.json"] = '{"entries":{"k1":{"count":1},"k2":{"count":3}}}',
				[probe._status_file] = "last_ok=1790000000\nlast_type=noop\nlast_fail=0\nlast_fail_msg=\nadopted=true\n",
				[probe._board_name_file] = "jiorouter,ax6000-jidu6101\n",
				VERSION = "0.9.0\n", BUILD = "v0.9.0 2026-09-29T00:00Z\n",
				vaps = function() return {{name = "openuf_radio0_x", essid = "x", radio_name = "radio0",
					encryption = "psk2", disabled = false, bssid = "00:00:5e:00:53:02"}} end,
			}, function()
				local d = probe.describe(dev, config, {uci_managed = true})
				assert_true(d.uci_managed, "UCI in charge")
				assert_nil(d.config_error, "no error")
				assert_eq(d.version, "0.9.0", "VERSION")
				assert_eq(d.build, "v0.9.0 2026-09-29T00:00Z", "BUILD")
				assert_eq(d.modelmap.name, "jiorouter-ax6000-jidu6101", "resolved preset")
				assert_eq(d.modelmap.title, "JioRouter AX6000 JIDU6101", "its title")
				assert_eq(d.modelmap.lan_cpueth, "br-lan", "identity netdev")
				assert_true(d.modelmap.dsa, "DSA shape")
				assert_eq(#d.modelmap.ports, 5, "sockets")
				assert_eq(d.modelmap.led, "green:status", "LED")
				assert_eq(d.identity.name, "u6iw", "identity preset")
				assert_eq(d.identity.model, "U6IW", "loaded from its file")
				assert_false(d.identity.custom, "not custom")
				assert_eq(d.config.inform_url, "http://c:8080/inform", "config echoed")
				assert_eq(d.config.l2_announce, false, "booleans kept")
				assert_true(d.config.debug_overrides, "research overrides flagged")
				assert_eq(d.state.adopted, true, "state read")
				assert_nil(d.state.authkey, "the secret never leaves")
				assert_eq(d.state.l2guard.vaps, 2, "l2guard summarised")
				assert_eq(d.health.last_ok, 1790000000, "health numbers are numbers")
				assert_true(type(d.now) == "number", "the device clock rides along for ages")
				assert_eq(d.health.last_type, "noop", "health strings")
				assert_eq(d.ledger.entries, 2, "ledger counted")
				assert_eq(d.wlans[1].ssid, "x", "provisioned WLANs")
				assert_eq(d.wlans[1].encryption, "psk2", "with their encryption")
			end)
		end
	},
	{
		name = "probe: discover() reads a DSA board: sockets, bridge identity, radios with UCI names, LEDs and their owners, and a draft profile",
		fn = function()
			with_device({
				board = fixture("board_json_dsa.json"), board_name = "jiorouter,ax6000-jidu6101\n",
				leds = {["blue:status"] = {trigger = "none"}, ["green:status"] = {trigger = "none"},
					["red:status"] = {trigger = "none"}, ["mt76-phy0"] = {trigger = "phy0tpt"}},
				aliases = {["led-boot"] = "/leds/led-0", ["led-running"] = "/leds/led-0", ["led-upgrade"] = "/leds/led-2"},
				dt = {["/leds/led-0"] = {["function"] = "status", color = 3}, ["/leds/led-2"] = {["function"] = "status", color = 1}},
				net = {["br-lan"] = {mac = "00:00:5e:00:53:20", bridge = true}, eth0 = {mac = "00:00:5e:00:53:2e"},
					lan1 = {mac = "00:00:5e:00:53:20", dsa = true, state = "lowerlayerdown"}, lan2 = {mac = "00:00:5e:00:53:20", dsa = true},
					lan3 = {mac = "00:00:5e:00:53:20", dsa = true}, lan4 = {mac = "00:00:5e:00:53:20", dsa = true},
					wan = {mac = "00:00:5e:00:53:1f", dsa = true}, ["phy0-ap0"] = {mac = "00:00:5e:00:53:21"}},
				radios = {{name = "radio0", path = "platform/soc/18000000.wifi", band = "2g"},
					{name = "radio1", path = "platform/soc/18000000.wifi+1", band = "5g"}},
				iw = {phy1 = "\t\t\t* 5260.0 MHz [52] (30.0 dBm) (radar detection)\n"},
			}, function()
				local d = probe.discover()
				assert_eq(d.board.id, "jiorouter,ax6000-jidu6101", "board id")
				assert_eq(d.layout, "dsa", "DSA from the netdevs' dsa marker")
				assert_eq(#d.sockets, 5, "four LAN sockets and the WAN socket")
				assert_eq(d.sockets[1].netdev, "lan1", "socket netdevs")
				assert_eq(d.sockets[5].role, "wan", "the WAN socket last")
				assert_eq(d.cpu.lan_cpueth, "br-lan", "identity is the LAN bridge on DSA")
				assert_eq(d.cpu.wan_cpueth, "wan", "wan netdev")
				assert_eq(#d.radios, 2, "two radios")
				assert_eq(d.radios[1].uci, "radio0", "UCI name matched by path")
				assert_eq(d.radios[1].openuf_band, "ng", "2G is ng")
				assert_eq(d.radios[2].openuf_band, "na", "5G is na")
				assert_true(d.radios[2].dfs, "DFS from iw")
				assert_eq(d.radios[2].max_width, 160, "max width from board.json")
				assert_true(d.radios[2].he, "HE capable")
				local by = {}
				for _, l in ipairs(d.leds) do by[l.name] = l end
				assert_eq(table.concat(by["blue:status"].used_by, ","), "led-boot,led-running", "blue:status is procd's, resolved from colour+function")
				assert_eq(by["red:status"].used_by[1], "led-upgrade", "red:status too")
				assert_eq(#by["green:status"].used_by, 0, "green:status is free")
				assert_eq(by["mt76-phy0"].trigger, "phy0tpt", "trigger read")
				local dr = d.draft
				assert_eq(dr.lan_cpueth, "br-lan", "draft identity netdev")
				assert_eq(dr.uplink_detect, "fdb", "draft: detect the uplink on DSA")
				assert_eq(#dr.ports, 5, "draft ports")
				assert_eq(dr.ports[5].ifname, "wan", "as netdevs")
				assert_nil(dr.vlan, "no switch geometry on DSA")
				assert_eq(dr.hwassign[2], "radio1", "draft hwassign")
				assert_eq(dr.led, "green:status", "the free status LED, not procd's")
				assert_true(dr.led_unverified, "and flagged")
				assert_eq(dr.radio.na.acs_exclude_dfs, true, "DFS excluded by default on 5 GHz")
				assert_eq(dr.radio.na.htmode_floor, "HE80", "HE floor on 5 GHz")
				assert_eq(dr.radio.na.htmode_max, "HE160", "max from board.json")
				assert_eq(dr.radio.ng.htmode_max, "HE40", "2 GHz max")
				assert_eq(dr.openwrt_board, "jiorouter,ax6000-jidu6101", "board string")
				assert_eq(d.auto, "jiorouter-ax6000-jidu6101", "the preset auto would pick")
			end)
		end
	},
	{
		name = "probe: discover() reads a swconfig board with two CPU ports, and one with a tagged trunk",
		fn = function()
			with_device({
				board = fixture("board_json_swconfig.json"), board_name = "tplink,archer-c5-v1\n",
				leds = {["blue:wlan2g"] = {trigger = "phy1tpt"}, ["blue:system"] = {trigger = "none"}, ["green:system"] = {trigger = "none"}},
				aliases = {["led-boot"] = "/leds/led-0"}, dt = {["/leds/led-0"] = {label = "blue:system"}},
				net = {eth0 = {mac = "00:00:5e:00:53:30"}, eth1 = {mac = "00:00:5e:00:53:31"}, ["br-lan"] = {mac = "00:00:5e:00:53:31", bridge = true}},
				radios = {{name = "radio0", path = "pci0000:00/0000:00:00.0", band = "5g"},
					{name = "radio1", path = "platform/ahb/18100000.wmac", band = "2g"}},
				iw = {phy0 = ""},
			}, function()
				local d = probe.discover()
				assert_eq(d.layout, "swconfig", "switch section, no dsa marker")
				assert_eq(#d.sockets, 5, "five sockets")
				assert_eq(d.sockets[1].label, "lan1", "labelled in board.d order")
				assert_eq(d.sockets[1].swport, 2, "physical port number")
				assert_true(d.sockets[1].label_unverified, "the case label is a guess")
				assert_eq(d.sockets[5].label, "wan", "wan socket")
				assert_eq(d.sockets[5].swport, 1, "on port 1")
				assert_eq(d.cpu.switch, "switch0", "switch device")
				assert_eq(d.cpu.lan_cpueth, "eth1", "LAN CPU netdev")
				assert_eq(d.cpu.lan_vlanid, 1, "untagged CPU: vlan 1")
				assert_eq(d.cpu.wan_cpueth, "eth0", "WAN CPU netdev")
				assert_eq(d.cpu.cpu_lan, 0, "cpu_lan")
				assert_eq(d.cpu.cpu_wan, 6, "cpu_wan")
				assert_eq(d.draft.vlan.ports.lan1, 2, "draft label map")
				assert_eq(d.draft.vlan.ports.wan, 1, "draft label map")
				assert_eq(d.draft.ports[1].swport, "lan1", "draft ports by label")
				assert_nil(d.draft.uplink_detect, "no FDB detection on swconfig")
				assert_eq(d.draft.radio.na.htmode_floor, "VHT80", "VHT floor without HE")
				assert_eq(d.draft.radio.na.htmode_max, "VHT80", "max")
				assert_nil(d.draft.radio.na.acs_exclude_dfs, "no DFS flag seen: not excluded")
				assert_eq(d.draft.hwassign[1], "radio0", "hwassign in phy order")
				local by = {}
				for _, l in ipairs(d.leds) do by[l.name] = l end
				assert_eq(by["blue:wlan2g"].used_by[1], "openwrt:WLAN2G", "board.json LEDs are OpenWrt's")
				assert_eq(by["blue:system"].used_by[1], "led-boot", "a DT label resolves too")
				assert_eq(d.draft.led, "green:system", "the free one")
			end)
			with_device({
				board = fixture("board_json_swconfig_tagged.json"), board_name = "tplink,archer-c7-v5\n",
				leds = {}, aliases = {}, dt = {}, net = {eth0 = {mac = "00:00:5e:00:53:40"}},
				radios = {}, iw = {},
			}, function()
				local d = probe.discover()
				assert_eq(d.cpu.lan_cpueth, "eth0", "the bare trunk netdev")
				assert_eq(d.cpu.lan_vlanid, 1, "vid from eth0.1")
				assert_eq(d.cpu.wan_cpueth, "eth0", "same trunk for WAN")
				assert_eq(d.cpu.cpu_lan, 0, "cpu port 0")
				assert_eq(d.cpu.cpu_wan, 0, "and the same port serves WAN")
				assert_true(d.cpu_ports[1].tagged, "tagged")
				assert_nil(d.draft.led, "no LED to offer")
				assert_eq(#d.draft.hwassign, 0, "no UCI radios known")
			end)
		end
	},
	{
		name = "probe: export_modelmap() writes a loadable preset that passes the daemon's own checks",
		fn = function()
			local uciconf = dofile("openuf/uciconf.lua")
			for _, name in ipairs({"archer-c5-v1", "jiorouter-ax6000-jidu6101", "archer-a7-v5"}) do
				local dev = dofile("openuf/modelmap/" .. name .. ".lua")
				local text, filename = probe.export_modelmap(dev)
				assert_contains(text, "return dev", name .. ": a modelmap file")
				assert_contains(text, "NOT verified by the openUF maintainers", name .. ": says so in the header")
				local chunk = (loadstring or load)(text)
				assert_not_nil(chunk, name .. ": the text is valid Lua")
				local back = chunk()
				local ok, err = uciconf.validate(back)
				assert_true(ok, name .. ": round trip validates: " .. tostring(err))
				assert_eq(back.conf.net.lan_cpueth, dev.conf.net.lan_cpueth, name .. ": identity netdev survives")
				assert_eq(#back.conf.net.ports, #dev.conf.net.ports, name .. ": every socket survives")
				assert_eq(back.openwrt_boards[1], dev.openwrt_boards[1], name .. ": board string")
				if dev.conf.vlan then
					assert_eq(back.conf.vlan.ports.wan, dev.conf.vlan.ports.wan, name .. ": switch map survives")
					assert_eq(back.conf.vlan.cpu_lan, dev.conf.vlan.cpu_lan, name .. ": cpu ports survive")
				end
				assert_eq(back.conf.led, dev.conf.led, name .. ": LED survives")
				assert_eq(filename, dev.openwrt_boards[1]:gsub("[^%w]+", "-") .. ".lua", name .. ": file name from the board")
			end
		end
	},
	{
		name = "probe: export_modelmap() never names the 'custom' identity, which no shipped file can load",
		fn = function()
			local uciconf = dofile("openuf/uciconf.lua")
			local dev = dofile("openuf/modelmap/jiorouter-ax6000-jidu6101.lua")
			dev.openuf.uap.ufmodel = "custom"   -- what uciconf.load leaves behind for a custom identity
			-- The exporting device's own profile choice wins ...
			local text = probe.export_modelmap(dev, {ufmodel = "uhdiw", identity_platform = "UHDIW"})
			assert_contains(text, 'ufmodel\t\t= "uhdiw"', "the device section's ufmodel is what ships")
			assert_contains(text, "custom identity (UHDIW)", "and the file says why")
			assert_nil(text:find('"custom"', 1, true), "never the word custom as a value")
			local back = (loadstring or load)(text)()
			local ok, err = uciconf.validate(back)
			assert_true(ok, "round trip validates: " .. tostring(err))
			-- ... and with no usable choice the default identity is named, never 'custom'.
			text = probe.export_modelmap(dev, {ufmodel = "custom"})
			assert_contains(text, 'ufmodel\t\t= "u6iw"', "falls back to the default identity")
			text = probe.export_modelmap(dev)
			assert_contains(text, 'ufmodel\t\t= "u6iw"', "also with no opts at all")
		end
	},
	{
		name = "probe: describe() names the conf.lua preset on a tarball install, and carries a config error",
		fn = function()
			local dev = dofile("openuf/modelmap/archer-c5-v1.lua")
			with_files({[probe._board_name_file] = false, VERSION = false, BUILD = false,
				["/etc/openuf/state.json"] = false, [probe._status_file] = false,
				["/etc/openuf/unhandled.json"] = false}, function()
				local d = probe.describe(dev, {}, {conf_lua = 'dev = dofile("modelmap/archer-c5-v1.lua")\nconfig = {}\n'})
				assert_false(d.uci_managed, "conf.lua rules")
				assert_eq(d.modelmap.name, "archer-c5-v1", "read off conf.lua's dofile line")
				assert_nil(d.version, "no VERSION on a tarball install")
				assert_nil(d.state, "no state file yet")
				assert_eq(d.ledger.entries, 0, "no ledger yet")
				local e = probe.describe(nil, nil, {config_error = "/etc/config/openuf: modelmap 'x' is not shipped"})
				assert_contains(e.config_error, "not shipped", "the reason travels")
				assert_nil(e.modelmap.name, "nothing resolved")
				assert_eq(#e.modelmap.ports, 0, "and no ports invented")
			end)
		end
	},
}
