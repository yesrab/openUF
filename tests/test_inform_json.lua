-- Integration test: inform.build_json() produces a well-formed payload.
-- Tests the full JSON structure without needing a real controller.
-- Run from project root: lua tests/run_tests.lua

OPENUF_TEST_MODE = true
dofile("openuf/lib/lib.lua")

local cjson  = require("cjson")
local state  = dofile("openuf/state.lua")
local inform = dofile("openuf/inform.lua")

local function fixture(name)
	local f = io.open("tests/fixtures/" .. name, "r")
	if not f then return "" end
	local s = f:read("*a"); f:close(); return s
end

-- Inject sysinfo fixtures via inform's exposed _sysinfo reference
-- (inform.lua loads its own sysinfo instance; M._sysinfo is that instance)
-- with_clients: when true, sta_table()/radio_stats() return real fixture data
-- (2 connected clients, one in-use channel survey entry) instead of empty.
local function inject_sysinfo(with_clients)
	inform._sysinfo._read_file = function(path)
		if path:find("uptime")  then return fixture("proc_uptime.txt")  end
		if path:find("loadavg") then return fixture("proc_loadavg.txt") end
		if path:find("meminfo") then return fixture("proc_meminfo.txt") end
		if path:find("net/dev") then return fixture("proc_net_dev.txt") end
		return ""
	end
	inform._sysinfo._run_cmd = function(cmd)
		if with_clients and cmd:find("station dump") then
			return fixture("iw_station_dump.txt")
		end
		if with_clients and cmd:find("survey dump") then
			return fixture("iw_survey_dump.txt")
		end
		return ""
	end
	-- Return empty neighbor list (no lldpd on dev machine)
	inform._lldp._run_cmd = function() return "" end
end

-- Inject a mock ucihelper so build_json's radio/vap/stats wiring can be
-- exercised without a real UCI environment.
local function inject_ucihelper()
	inform._ucihelper = {
		get_radio_table = function()
			return {
				{ name = "radio0", channel = "6", ht = "HT20", tx_power = "20",
				  disabled = false, builtin_antenna = true, builtin_ant_gain = 3,
				  max_txpower = 20 },
			}
		end,
		get_vap_table = function()
			return {
				{ name = "openuf_test", essid = "test", radio = "radio0",
				  encryption = "psk2", disabled = false, bssid = "aa:bb:cc:00:00:01",
				  channel = "6", tx_power = "20", usage = "user" },
			}
		end,
		get_ifname_for_radio = function(radio) return "wlan0" end,
	}
end

-- Minimal ufhw matching the u6iw model
local ufhw = {
	uap = {
		platform = "U6IW",
		model    = "U6IW",
		fw       = {pre="U6IW.", ver="6.6.55", buildtime="230801.1200", factoryver="6.5.28"},
		required_version = "6.0.0",
		bootver  = "",
	}
}

local function build(opts)
	inject_sysinfo(opts and opts.with_clients)
	if opts and opts.with_uci then inject_ucihelper() end
	local st = {
		authkey    = state.DEFAULT_KEY,
		adopted    = opts and opts.adopted or false,
		cfgversion = opts and opts.cfgversion or "",
		inform_url = "http://10.0.0.1:8080/inform",
		mac        = "aa:bb:cc:dd:ee:ff",
		ip         = "192.168.1.100",
		hostname   = "testap",
		locating   = opts and opts.locating,
	}
	local json_str = inform.build_json(st, nil, ufhw)
	return cjson.decode(json_str), st
end

return {
	{
		name = "inform json: _type is 'state'",
		fn = function()
			local d = build()
			assert_eq(d._type, "state", "_type")
		end
	},
	{
		name = "inform json: required top-level fields present",
		fn = function()
			local d = build()
			for _, field in ipairs({"mac","serial","model","platform","hostname",
				"ip","version","uptime","time","mem_total","mem_used"}) do
				assert_not_nil(d[field], "field present: " .. field)
			end
		end
	},
	{
		name = "inform json: mac matches state",
		fn = function()
			local d = build()
			assert_eq(d.mac, "aa:bb:cc:dd:ee:ff", "mac")
		end
	},
	{
		name = "inform json: serial is mac without colons",
		fn = function()
			local d = build()
			assert_eq(d.serial, "aabbccddeeff", "serial")
		end
	},
	{
		name = "inform json: model and platform match u6iw",
		fn = function()
			local d = build()
			assert_eq(d.model,    "U6IW", "model")
			assert_eq(d.platform, "U6IW", "platform")
		end
	},
	{
		name = "inform json: version contains fw prefix and version",
		fn = function()
			local d = build()
			assert_contains(d.version, "U6IW.", "fw prefix in version")
			assert_contains(d.version, "6.6.55", "fw ver in version")
		end
	},
	{
		name = "inform json: default=true when not adopted",
		fn = function()
			local d = build({adopted = false})
			assert_true(d["default"], "default true when not adopted")
		end
	},
	{
		name = "inform json: default=false when adopted",
		fn = function()
			local d = build({adopted = true})
			assert_false(d["default"], "default false when adopted")
		end
	},
	{
		name = "inform json: uptime from fixture is 12345",
		fn = function()
			local d = build()
			assert_eq(d.uptime, 12345, "uptime from /proc/uptime fixture")
		end
	},
	{
		name = "inform json: mem_total and mem_used from fixture (bytes)",
		fn = function()
			local d = build()
			assert_eq(d.mem_total, 131072 * 1024, "mem_total bytes")
			assert_eq(d.mem_used, (131072 - 65536) * 1024, "mem_used = (total - free) bytes")
		end
	},
	{
		name = "inform json: if_table is a list",
		fn = function()
			local d = build()
			assert_not_nil(d.if_table, "if_table present")
			assert_true(type(d.if_table) == "table", "if_table is table")
			-- Fixture has lo, eth0, eth1
			assert_true(#d.if_table >= 3, "at least 3 interfaces")
		end
	},
	{
		name = "inform json: if_table entries have required fields",
		fn = function()
			local d = build()
			local eth0
			for _, iface in ipairs(d.if_table) do
				if iface.name == "eth0" then eth0 = iface end
			end
			assert_not_nil(eth0, "eth0 in if_table")
			assert_not_nil(eth0.rx_bytes,  "eth0 rx_bytes")
			assert_not_nil(eth0.tx_bytes,  "eth0 tx_bytes")
		end
	},
	{
		name = "inform json: cfgversion reflects state",
		fn = function()
			local d = build({cfgversion = "abc123"})
			assert_eq(d.cfgversion, "abc123", "cfgversion")
		end
	},
	{
		name = "inform json: inform_url present",
		fn = function()
			local d = build()
			assert_eq(d.inform_url, "http://10.0.0.1:8080/inform", "inform_url")
		end
	},
	{
		name = "inform json: lldp_table is a list (may be empty without lldpd)",
		fn = function()
			local d = build()
			assert_not_nil(d.lldp_table, "lldp_table present")
			assert_true(type(d.lldp_table) == "table", "lldp_table is table")
		end
	},
	{
		name = "inform json: locating defaults to false",
		fn = function()
			local d = build()
			assert_false(d.locating, "locating false by default")
		end
	},
	{
		name = "inform json: locating reflects state.locating",
		fn = function()
			local d = build({locating = true})
			assert_true(d.locating, "locating true from state")
		end
	},
	{
		name = "inform json: system-stats present with cpu/mem/uptime (real capture key/shape)",
		fn = function()
			local d = build()
			-- Real devices report this under the hyphenated key "system-stats"
			-- (verified against a real captured USG payload) -- not "sys_stats".
			local stats = d["system-stats"]
			assert_not_nil(stats, "system-stats present")
			assert_not_nil(stats.cpu, "cpu field present")
			assert_not_nil(stats.uptime, "uptime field present")
			-- meminfo fixture: total=131072kB, free=65536kB -> 50% used
			assert_eq(stats.mem, "50", "mem percent computed from meminfo fixture")
		end
	},
	{
		name = "inform json: vap_table num_sta reflects connected clients",
		fn = function()
			local d = build({with_uci = true, with_clients = true})
			assert_eq(#d.vap_table, 1, "one vap")
			assert_eq(d.vap_table[1].num_sta, 2, "two clients from fixture")
		end
	},
	{
		name = "inform json: vap_table num_sta is 0 with no clients",
		fn = function()
			local d = build({with_uci = true, with_clients = false})
			assert_eq(d.vap_table[1].num_sta, 0, "no clients")
		end
	},
	{
		name = "inform json: user_table flattens per-vap clients",
		fn = function()
			local d = build({with_uci = true, with_clients = true})
			assert_eq(#d.user_table, 2, "two entries in user_table")
			assert_eq(d.user_table[1].mac, "aa:bb:cc:dd:ee:ff", "first client mac")
			assert_eq(d.user_table[1].essid, "test", "essid attached from vap")
			assert_eq(d.user_table[1].ap_mac, "aa:bb:cc:dd:ee:ff", "ap_mac from device mac")
		end
	},
	{
		name = "inform json: radio_table_stats derived from survey dump",
		fn = function()
			local d = build({with_uci = true, with_clients = true})
			assert_eq(#d.radio_table_stats, 1, "one radio_table_stats entry")
			assert_eq(d.radio_table_stats[1].name, "radio0", "keyed by radio name")
			assert_eq(d.radio_table_stats[1].cu_total, 37, "cu_total = busy/total*100")
			assert_eq(d.radio_table_stats[1].cu_self_rx, 18, "cu_self_rx = channel_time_rx/total*100")
			assert_eq(d.radio_table_stats[1].cu_self_tx, 9, "cu_self_tx = channel_time_tx/total*100")
		end
	},
	{
		name = "inform json: radio_table_stats includes spectrum_table when cached from a prior spectrum-scan cmd",
		fn = function()
			inform._spectrum_cache = {
				radio0 = {
					table = { { channel = 6, center_freq = 2437, width = 20, utilization = 37, interference = -95 } },
					table_time = 111,
					scan_timestamp = 222,
				},
			}
			local d = build({with_uci = true, with_clients = true})
			local rts = d.radio_table_stats[1]
			-- spectrum_scanning/spectrum_scan_timestamp are device-level
			-- (top-level payload) fields, not per-radio.
			assert_eq(d.spectrum_scanning, false, "spectrum_scanning false once results are cached")
			assert_eq(d.spectrum_scan_timestamp, 222, "spectrum_scan_timestamp from cache")
			assert_eq(rts.spectrum_table_time, 111, "spectrum_table_time from cache")
			assert_eq(#rts.spectrum_table, 1, "one spectrum_table entry")
			assert_eq(rts.spectrum_table[1].channel, 6, "spectrum_table entry channel")
			inform._spectrum_cache = {}
		end
	},
	{
		name = "inform json: radio_table_stats omits spectrum_table without a prior spectrum-scan cmd",
		fn = function()
			inform._spectrum_cache = {}
			local d = build({with_uci = true, with_clients = true})
			assert_true(d.radio_table_stats[1].spectrum_table == nil,
				"no spectrum_table until a spectrum-scan cmd has run")
			assert_true(d.spectrum_scan_timestamp == nil,
				"no spectrum_scan_timestamp until a spectrum-scan cmd has run")
		end
	},
	{
		name = "inform json: radio_table includes capability defaults",
		fn = function()
			local d = build({with_uci = true})
			assert_eq(d.radio_table[1].builtin_ant_gain, 3, "builtin_ant_gain")
			assert_eq(d.radio_table[1].max_txpower, 20, "max_txpower")
		end
	},
}
