-- uciconf: /etc/config/openuf -> the dev/config tables conf.lua produces.
-- A mock cursor stands in for libuci-lua; the presets are the real files.

local uciconf = dofile("openuf/uciconf.lua")
uciconf._modelmap_dir = "openuf/modelmap"
uciconf._ufmodel_dir  = "openuf/ufmodel"

-- sections: list of {name=, type=, <options>}; get_all/foreach return them
-- the way libuci-lua does (".name"/".type" keys, lists as tables).
local function mock_cursor(sections)
	local by_name = {}
	for _, s in ipairs(sections) do
		local t = {[".name"] = s.name, [".type"] = s.type}
		for k, v in pairs(s) do
			if k ~= "name" and k ~= "type" then t[k] = v end
		end
		s._t = t
		if s.name then by_name[s.name] = t end
	end
	return {
		get_all = function(_, cfg, section)
			if cfg ~= "openuf" then return nil end
			return by_name[section]
		end,
		foreach = function(_, cfg, stype, fn)
			if cfg ~= "openuf" then return end
			for _, s in ipairs(sections) do
				if s.type == stype then fn(s._t) end
			end
		end,
	}
end

local function with_board(name, fn)
	local orig = uciconf._read_file
	uciconf._read_file = function(path)
		if path == uciconf._board_name_file then return name and (name .. "\n") or nil end
		return orig(path)
	end
	local ok, err = pcall(fn)
	uciconf._read_file = orig
	if not ok then error(err, 0) end
end

local DEFAULTS = {inform_url = "http://unifi:8080/inform", use_only_unifi_wlan = true,
	keep_wlan_sections = {}, l2_announce = true, rrm_request_interval = 600,
	neighbour_scan_interval = 0, debug_dump_file = nil}

local function main(opts)
	local s = {name = "main", type = "openuf"}
	for k, v in pairs(opts or {}) do s[k] = v end
	return s
end

return {
	{
		name = "uciconf: present() only with a main section",
		fn = function()
			assert_false(uciconf.present(mock_cursor({})), "empty config")
			assert_false(uciconf.present(mock_cursor({{name = "custom", type = "device"}})), "no main")
			assert_true(uciconf.present(mock_cursor({main({})})), "main present")
		end
	},
	{
		name = "uciconf: main options are coerced and defaults survive what the section leaves out",
		fn = function()
			local c = mock_cursor({main({modelmap = "jiorouter-ax6000-jidu6101",
				use_only_unifi_wlan = "0", rrm_request_interval = "300", inform_url = "http://c:8080/inform",
				debug_dump_file = "", keep_wlan_section = {"a", "b"}, country_override = "SE"})})
			local got, err = uciconf.load(c, DEFAULTS)
			assert_not_nil(got, tostring(err))
			assert_eq(got.config.use_only_unifi_wlan, false, "'0' is false")
			assert_eq(got.config.rrm_request_interval, 300, "numbers are numbers")
			assert_eq(got.config.inform_url, "http://c:8080/inform", "strings pass through")
			assert_nil(got.config.debug_dump_file, "'' is unset, as conf.lua's nil")
			assert_eq(got.config.l2_announce, true, "an option left out keeps conf.lua's default")
			assert_eq(got.config.neighbour_scan_interval, 0, "including numbers")
			assert_eq(#got.config.keep_wlan_sections, 2, "a list arrives as a list")
			assert_eq(got.config.country_override, "SE", "optional strings")
			assert_eq(got.dev.modelmap_name, "jiorouter-ax6000-jidu6101", "the named preset")
			assert_eq(got.dev.conf.net.lan_cpueth, "br-lan", "and its fields")
			assert_nil(got.uap, "no custom identity")
			assert_eq(DEFAULTS.use_only_unifi_wlan, true, "the defaults table is not mutated")
		end
	},
	{
		name = "uciconf: a mistyped boolean is refused, not read as false",
		fn = function()
			local c = mock_cursor({main({modelmap = "archer-c5-v1", l2_announce = "ture"})})
			local got, err = uciconf.load(c, DEFAULTS)
			assert_nil(got, "refused")
			assert_contains(err, "l2_announce", "names the option")
		end
	},
	{
		name = "uciconf: modelmap 'auto' matches the board name against the presets, and refuses an unknown board",
		fn = function()
			with_board("jiorouter,ax6000-jidu6j01", function()
				local got, err = uciconf.load(mock_cursor({main({})}), DEFAULTS)
				assert_not_nil(got, tostring(err))
				assert_eq(got.dev.modelmap_name, "jiorouter-ax6000-jidu6j01", "the J family map")
			end)
			with_board("tplink,archer-c5-v1", function()
				local got = uciconf.load(mock_cursor({main({modelmap = "auto"})}), DEFAULTS)
				assert_eq(got.dev.modelmap_name, "archer-c5-v1", "a swconfig board")
			end)
			with_board("acme,unknown-board", function()
				local got, err = uciconf.load(mock_cursor({main({})}), DEFAULTS)
				assert_nil(got, "no generic fallback: that would be a guess at the identity netdev")
				assert_contains(err, "acme,unknown-board", "names the board")
			end)
			with_board(nil, function()
				local got, err = uciconf.load(mock_cursor({main({})}), DEFAULTS)
				assert_nil(got, "no board file")
				assert_contains(err, "board_name", "says why")
			end)
		end
	},
	{
		name = "uciconf: a preset that is not shipped is refused by name",
		fn = function()
			local got, err = uciconf.load(mock_cursor({main({modelmap = "no-such-map"})}), DEFAULTS)
			assert_nil(got, "refused")
			assert_contains(err, "no-such-map", "names it")
			got, err = uciconf.load(mock_cursor({main({modelmap = "archer-c5-v1", ufmodel = "nope"})}), DEFAULTS)
			assert_nil(got, "unknown ufmodel refused")
			assert_contains(err, "nope", "names it")
		end
	},
	{
		name = "uciconf: ufmodel overrides the preset's identity, and custom builds one from the identity section",
		fn = function()
			local got = uciconf.load(mock_cursor({main({modelmap = "archer-c5-v1", ufmodel = "uhdiw"})}), DEFAULTS)
			assert_eq(got.dev.openuf.uap.ufmodel, "uhdiw", "preset identity replaced")
			assert_nil(got.uap, "a preset identity is loaded from its file by the caller")

			local c = mock_cursor({main({modelmap = "archer-c5-v1", ufmodel = "custom"}),
				{name = "custom_identity", type = "identity", platform = "UHDIW", model = "UHDIW",
				 fw_ver = "6.7.57.15670", fw_buildtime = "260101.0000", fw_factoryver = "6.5.28"}})
			got = uciconf.load(c, DEFAULTS)
			assert_not_nil(got.uap, "custom identity built")
			assert_eq(got.uap.model, "UHDIW", "model")
			assert_eq(got.uap.fw.pre, "UHDIW.", "fw.pre defaults to <model>.")
			assert_eq(got.uap.fw.ver, "6.7.57.15670", "bare version")
			assert_eq(got.uap.required_version, "6.0.0", "default required_version")
			assert_eq(got.dev.openuf.uap.ufmodel, "custom", "the dev table says so")
			-- The cosmetic fields left empty must be strings: announce.lua packs
			-- them into TLVs and a nil crash-looped it on AP2.
			c = mock_cursor({main({modelmap = "archer-c5-v1", ufmodel = "custom"}),
				{name = "custom_identity", type = "identity", platform = "U6IW", model = "U6IW", fw_ver = "6.8.2.15592"}})
			got = uciconf.load(c, DEFAULTS)
			assert_eq(got.uap.fw.buildtime, "", "buildtime is a string")
			assert_eq(got.uap.fw.factoryver, "", "factoryver is a string")
			assert_eq(got.uap.bootver, "", "bootver is a string")
			OPENUF_TEST_MODE = true
			dofile("openuf/lib/lib.lua")
			local announce = dofile("openuf/announce.lua")
			-- The same cfg announce.lua's entry point builds from the identity.
			local pkt = announce.build_packet({
				mac = {0, 0, 0x5e, 0, 0x53, 1}, ip = {192, 0, 2, 10}, hostname = "ap",
				platform = got.uap.platform, fw_pre = got.uap.fw.pre, fw_ver = got.uap.fw.ver,
				fw_buildtime = got.uap.fw.buildtime, fw_factoryver = got.uap.fw.factoryver,
				version_suffix = "-t", uptime = 1, counter = 1,
			})
			assert_true(type(pkt) == "string" and #pkt > 20, "and the discovery packet builds from it")

			c = mock_cursor({main({modelmap = "archer-c5-v1", ufmodel = "custom"}),
				{name = "custom_identity", type = "identity", platform = "UHDIW", model = "UHDIW",
				 fw_ver = "v6.7.57+15670"}})
			local bad, err = uciconf.load(c, DEFAULTS)
			assert_nil(bad, "a prefixed version is refused")
			assert_contains(err, "fw_ver", "the controller compares it verbatim")
			bad, err = uciconf.load(mock_cursor({main({modelmap = "archer-c5-v1", ufmodel = "custom"})}), DEFAULTS)
			assert_nil(bad, "custom without a section")
			assert_contains(err, "custom_identity", "names the section")
		end
	},
	{
		name = "uciconf: a custom DSA map builds the netdev shape, with radios, LED and hwassign",
		fn = function()
			local c = mock_cursor({main({modelmap = "custom"}),
				{name = "custom", type = "device", lan_cpueth = "br-lan", wan_cpueth = "wan",
				 uplink_detect = "fdb", led = "green:status", hwassign = {"radio0", "radio1"},
				 openwrt_board = "acme,ap1", ufmodel = "u6iw"},
				{type = "port", idx = "2", ifname = "lan2"},
				{type = "port", idx = "1", ifname = "lan1"},
				{type = "port", idx = "5", ifname = "wan"},
				{name = "na", type = "radio", acs_exclude_dfs = "1", htmode_floor = "HE80",
				 htmode_max = "HE160", channel = {"36", "40"}},
				{name = "ng", type = "radio", htmode_floor = "HE20"}})
			local got, err = uciconf.load(c, DEFAULTS)
			assert_not_nil(got, tostring(err))
			local dev = got.dev
			assert_eq(dev.modelmap_name, "custom", "custom map")
			assert_eq(dev.conf.net.lan_cpueth, "br-lan", "identity netdev")
			assert_eq(dev.conf.net.lan_name, "lan", "default lan_name")
			assert_eq(dev.conf.net.lan_vlanid, 1, "default lan_vlanid")
			assert_eq(dev.conf.net.uplink_detect, "fdb", "DSA uplink detection")
			assert_nil(dev.conf.vlan, "no vlan section on DSA")
			assert_eq(#dev.conf.net.ports, 3, "three sockets")
			assert_eq(dev.conf.net.ports[1].idx, 1, "sorted by idx")
			assert_eq(dev.conf.net.ports[1].ifname, "lan1", "netdev per socket")
			assert_eq(dev.conf.net.ports[3].ifname, "wan", "the wan socket is just a socket")
			assert_eq(dev.conf.led, "green:status", "LED")
			assert_eq(dev.conf.radio.na.acs_exclude_dfs, true, "band policy")
			assert_eq(dev.conf.radio.na.htmode_max, "HE160", "width cap")
			assert_eq(dev.conf.radio.na.channels[2], 40, "channels as numbers")
			assert_eq(dev.conf.radio.ng.htmode_floor, "HE20", "the other band")
			assert_eq(dev.openuf.uap.hwassign[2], "radio1", "hwassign list")
			assert_eq(dev.openwrt_boards[1], "acme,ap1", "a single option is a one-entry list")
			assert_eq(dev.openuf.uap.ufmodel, "u6iw", "identity")
		end
	},
	{
		name = "uciconf: a custom swconfig map builds the switch shape from vlan and swport sections",
		fn = function()
			local c = mock_cursor({main({modelmap = "custom"}),
				{name = "custom", type = "device", lan_cpueth = "eth1", wan_cpueth = "eth0",
				 hwassign = {"radio0"}},
				{type = "port", idx = "1", swport = "lan1"},
				{type = "port", idx = "2", swport = "wan"},
				{name = "custom_vlan", type = "vlan", device = "switch0", cpu_lan = "0", cpu_wan = "6"},
				{type = "swport", label = "lan1", num = "2"},
				{type = "swport", label = "wan", num = "1"}})
			local got, err = uciconf.load(c, DEFAULTS)
			assert_not_nil(got, tostring(err))
			local dev = got.dev
			assert_eq(dev.conf.vlan.device, "switch0", "switch device")
			assert_eq(dev.conf.vlan.cpu_lan, 0, "cpu ports as numbers")
			assert_eq(dev.conf.vlan.cpu_wan, 6, "cpu ports as numbers")
			assert_eq(dev.conf.vlan.ports.lan1, 2, "label -> physical port")
			assert_eq(dev.conf.vlan.ports.wan, 1, "label -> physical port")
			assert_eq(dev.conf.net.ports[1].swport, "lan1", "swport shape")
			assert_nil(dev.conf.net.uplink_detect, "no DSA detection")
		end
	},
	{
		name = "uciconf: a custom map that breaks a preset invariant is refused with the reason",
		fn = function()
			local function try(sections, what)
				local all = {main({modelmap = "custom"})}
				for _, s in ipairs(sections) do all[#all + 1] = s end
				local got, err = uciconf.load(mock_cursor(all), DEFAULTS)
				assert_nil(got, what .. ": refused")
				return err
			end
			local dev = {name = "custom", type = "device", lan_cpueth = "br-lan", uplink_detect = "fdb"}
			assert_contains(try({{name = "custom", type = "device"}}, "no lan_cpueth"), "lan_cpueth", "the identity netdev is required")
			assert_contains(try({dev, {type = "port", idx = "1", ifname = "lan1"},
				{type = "port", idx = "1", ifname = "lan2"}}, "dup idx"), "used twice", "port_idx is the controller's key")
			assert_contains(try({dev, {type = "port", idx = "1"}}, "no netdev"), "neither", "a port needs a name")
			assert_contains(try({dev, {type = "port", idx = "1", swport = "lan1"},
				{name = "custom_vlan", type = "vlan", cpu_lan = "0"},
				{type = "swport", label = "lan1", num = "2"}}, "dsa+vlan"), "uplink_detect", "DSA and swconfig do not mix")
			assert_contains(try({{name = "custom", type = "device", lan_cpueth = "eth1"},
				{type = "port", idx = "1", swport = "lan9"},
				{name = "custom_vlan", type = "vlan", cpu_lan = "0"},
				{type = "swport", label = "lan1", num = "2"}}, "bad swport"), "lan9", "a swport must resolve")
			assert_contains(try({{name = "custom", type = "device", lan_cpueth = "eth1"},
				{type = "port", idx = "1", swport = "lan1"},
				{name = "custom_vlan", type = "vlan", cpu_lan = "0", cpu_wan = "6"},
				{type = "swport", label = "lan1", num = "1"},
				{type = "swport", label = "wan", num = "1"}}, "wan collision"), "collides with the WAN", "one bitmask per port")
			assert_contains(try({{name = "custom", type = "device", lan_cpueth = "eth1"},
				{type = "port", idx = "1", swport = "lan1", uplink = "1"},
				{name = "custom_vlan", type = "vlan", cpu_lan = "0"},
				{type = "swport", label = "lan1", num = "2"}}, "uplink swport"), "uplink", "reassigning the uplink strands the AP")
			assert_contains(try({{name = "custom", type = "device", lan_cpueth = "br-lan", openwrt_board = "notaboard"}}, "board shape"), "vendor,model", "board strings are vendor,model")
			assert_contains(try({}, "no device section"), "config device", "says which section is missing")
		end
	},
	{
		name = "uciconf: apply() replaces the globals only when UCI is in charge, and refuses a broken config loudly",
		fn = function()
			local orig_uci = uciconf._uci
			local orig_dev, orig_config = dev, config
			dev, config = {conf = {net = {lan_cpueth = "eth1"}}}, {inform_url = "http://from-conf-lua/", l2_announce = true}

			uciconf._uci = {cursor = function() return mock_cursor({}) end}
			assert_nil(uciconf.apply(), "no main section: nothing returned")
			assert_eq(config.inform_url, "http://from-conf-lua/", "conf.lua untouched")

			uciconf._uci = {cursor = function()
				return mock_cursor({main({modelmap = "xiaomi-ax3000t", inform_url = "http://uci/", l2_announce = "0"})})
			end}
			local uap = uciconf.apply()
			assert_nil(uap, "a preset identity is loaded by the caller")
			assert_eq(dev.modelmap_name, "xiaomi-ax3000t", "dev replaced")
			assert_eq(config.inform_url, "http://uci/", "config replaced")
			assert_eq(config.l2_announce, false, "with UCI's values")

			uciconf._uci = {cursor = function() return mock_cursor({main({modelmap = "no-such"})}) end}
			local ok, err = pcall(uciconf.apply)
			assert_false(ok, "a broken config is an error, not a fallback")
			assert_contains(tostring(err), "/etc/config/openuf", "names the file")

			uciconf._uci = {cursor = function() error("no libuci-lua") end}
			dev, config = {conf = {}}, {inform_url = "x"}
			assert_nil(uciconf.apply(), "no uci binding: conf.lua rules")
			assert_eq(config.inform_url, "x", "untouched")

			uciconf._uci = orig_uci
			dev, config = orig_dev, orig_config
		end
	},
}
