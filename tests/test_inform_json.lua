-- Integration test: inform.build_json() produces a well-formed payload.
-- Tests the full JSON structure without needing a real controller.
-- Run from project root: lua tests/run_tests.lua

OPENUF_TEST_MODE = true
dofile("openuf/lib/lib.lua")

local cjson  = require("cjson")
local state  = dofile("openuf/state.lua")
local inform = dofile("openuf/inform.lua")

-- Inject sysinfo fixtures via inform's exposed _sysinfo reference
-- (inform.lua loads its own sysinfo instance; M._sysinfo is that instance)
local function inject_sysinfo()
	local function fixture(name)
		local f = io.open("tests/fixtures/" .. name, "r")
		if not f then return "" end
		local s = f:read("*a"); f:close(); return s
	end
	inform._sysinfo._read_file = function(path)
		if path:find("uptime")  then return fixture("proc_uptime.txt")  end
		if path:find("loadavg") then return fixture("proc_loadavg.txt") end
		if path:find("meminfo") then return fixture("proc_meminfo.txt") end
		if path:find("net/dev") then return fixture("proc_net_dev.txt") end
		return ""
	end
	inform._sysinfo._run_cmd = function(cmd)
		if cmd:find("station dump") then return "" end
		return ""
	end
	-- Return empty neighbor list (no lldpd on dev machine)
	inform._lldp._run_cmd = function() return "" end
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
	inject_sysinfo()
	local st = {
		authkey    = state.DEFAULT_KEY,
		adopted    = opts and opts.adopted or false,
		cfgversion = opts and opts.cfgversion or "",
		inform_url = "http://10.0.0.1:8080/inform",
		mac        = "aa:bb:cc:dd:ee:ff",
		ip         = "192.168.1.100",
		hostname   = "testap",
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
				"ip","version","uptime","time","mem_total","mem_free"}) do
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
		name = "inform json: mem_total and mem_free from fixture (bytes)",
		fn = function()
			local d = build()
			assert_eq(d.mem_total, 131072 * 1024, "mem_total bytes")
			assert_eq(d.mem_free,   65536 * 1024, "mem_free bytes")
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
}
