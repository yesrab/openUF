-- Tests for openuf/state.lua (state persistence).
-- Run from project root: lua tests/run_tests.lua

local state = dofile("openuf/state.lua")
local TMP = "/tmp/openuf_test_state.json"
local DEFKEY = state.DEFAULT_KEY

-- Helper: redirect state file to temp path for isolation
local function with_tmp(fn)
	state._state_file = TMP
	os.remove(TMP)
	local ok, err = pcall(fn)
	os.remove(TMP)
	state._state_file = "/etc/openuf/state.json"  -- restore
	if not ok then error(err, 2) end
end

return {
	{
		name = "state: load from missing file returns defaults",
		fn = function()
			with_tmp(function()
				local st = state.load()
				assert_eq(st.authkey,    DEFKEY,                      "authkey default")
				assert_eq(st.adopted,    false,                       "adopted default")
				assert_eq(st.cfgversion, "",                          "cfgversion default")
				assert_eq(st.inform_url, "http://unifi:8080/inform",  "inform_url default")
			end)
		end
	},
	{
		name = "state: save + load round-trip preserves all fields",
		fn = function()
			with_tmp(function()
				local saved = {
					authkey    = "aabbccddeeff00112233445566778899",
					adopted    = true,
					cfgversion = "abc123",
					inform_url = "http://10.0.0.1:8080/inform",
				}
				state.save(saved)
				local loaded = state.load()
				assert_eq(loaded.authkey,    saved.authkey,    "authkey round-trip")
				assert_eq(loaded.adopted,    saved.adopted,    "adopted round-trip")
				assert_eq(loaded.cfgversion, saved.cfgversion, "cfgversion round-trip")
				assert_eq(loaded.inform_url, saved.inform_url, "inform_url round-trip")
			end)
		end
	},
	{
		name = "state: load resets authkey to default when adopted=false",
		fn = function()
			with_tmp(function()
				-- Save a state that claims not-adopted but has a custom key
				state.save({
					authkey    = "deadbeefdeadbeefdeadbeefdeadbeef",
					adopted    = false,
					cfgversion = "",
					inform_url = "http://unifi:8080/inform",
				})
				local loaded = state.load()
				assert_eq(loaded.authkey, DEFKEY, "authkey reset to default when not adopted")
				assert_eq(loaded.adopted, false,  "adopted still false")
			end)
		end
	},
	{
		name = "state: load preserves custom authkey when adopted=true",
		fn = function()
			with_tmp(function()
				local custom = "aabbccddeeff00112233445566778899"
				state.save({
					authkey    = custom,
					adopted    = true,
					cfgversion = "v1",
					inform_url = "http://unifi:8080/inform",
				})
				local loaded = state.load()
				assert_eq(loaded.authkey, custom, "custom authkey preserved when adopted")
				assert_eq(loaded.adopted, true,   "adopted preserved")
			end)
		end
	},
	{
		name = "state: reset sets adopted=false and clears authkey",
		fn = function()
			with_tmp(function()
				-- First save a custom adopted state
				state.save({
					authkey = "aabbccddeeff00112233445566778899",
					adopted = true,
					cfgversion = "v5",
					inform_url = "http://controller/inform",
				})
				-- Now reset
				local st = state.reset()
				assert_eq(st.authkey,    DEFKEY,                     "authkey reset")
				assert_eq(st.adopted,    false,                      "adopted reset")
				assert_eq(st.cfgversion, "",                         "cfgversion reset")
				assert_eq(st.inform_url, "http://unifi:8080/inform", "inform_url reset")
				-- Verify the file was also written
				local loaded = state.load()
				assert_eq(loaded.authkey, DEFKEY, "persisted authkey after reset")
			end)
		end
	},
	{
		name = "state: use_gcm field defaults to false and round-trips",
		fn = function()
			with_tmp(function()
				local st = state.load()
				assert_false(st.use_gcm, "use_gcm defaults to false")
				st.use_gcm = true
				st.adopted = true  -- need adopted=true to keep custom authkey
				state.save(st)
				local loaded = state.load()
				assert_true(loaded.use_gcm, "use_gcm round-trips as true")
				-- reset() must also clear use_gcm
				local fresh = state.reset()
				assert_false(fresh.use_gcm, "use_gcm cleared by reset")
			end)
		end
	},
	{
		name = "state: load from malformed JSON returns defaults",
		fn = function()
			with_tmp(function()
				local f = io.open(TMP, "w")
				f:write("this is not json {{{")
				f:close()
				-- The warning this emits is tested on its own below; keep
				-- the suite's output clean here.
				local real = io.stderr
				io.stderr = {write = function() end}
				local ok, st = pcall(state.load)
				io.stderr = real
				assert_true(ok, "load survives garbage")
				assert_eq(st.authkey, DEFKEY, "defaults on bad JSON")
				assert_eq(st.adopted, false,  "defaults on bad JSON")
			end)
		end
	},
	{
		name = "state: blocked_stas and upgrade_requested_* round-trip type-checked",
		fn = function()
			-- These load() type-checks existed but were never exercised: a
			-- valid table/string round-trips, a wrong-typed value on disk
			-- falls back to the default instead of poisoning the state.
			with_tmp(function()
				local st = state.load()
				st.adopted = true
				st.blocked_stas = {"aa:bb:cc:dd:ee:ff"}
				st.upgrade_requested_version = "6.8.2"
				st.upgrade_requested_url = "http://x/fw.bin"
				state.save(st)
				local loaded = state.load()
				assert_eq(loaded.blocked_stas[1], "aa:bb:cc:dd:ee:ff", "block list round-trips")
				assert_eq(loaded.upgrade_requested_version, "6.8.2", "version round-trips")
				assert_eq(loaded.upgrade_requested_url, "http://x/fw.bin", "url round-trips")

				local f = io.open(TMP, "w")
				f:write('{"adopted":false,"blocked_stas":"not-a-table",'
					.. '"upgrade_requested_version":42}')
				f:close()
				local bad = state.load()
				assert_eq(type(bad.blocked_stas), "table", "wrong-typed block list -> default table")
				assert_eq(#bad.blocked_stas, 0, "default block list is empty")
				assert_eq(bad.upgrade_requested_version, "", "wrong-typed version -> default")
			end)
		end
	},
	{
		name = "state: every field save() writes comes back from load()",
		fn = function()
			-- save() has always serialized the whole table while load() read
			-- back eight named fields, so everything else was written on
			-- every heartbeat and dropped on every start. The identity MAC
			-- (the previous-run comparison the HTTP 400 warning needs), the
			-- switch reversibility ledger, the IP Settings mode and the
			-- Locate/LED state all live here -- and USAGE.md has documented
			-- swvlan_backup and ip_mode as persisted all along.
			with_tmp(function()
				local st = state.load()
				st.adopted       = true
				st.mac           = "00:00:5e:00:53:1a"
				st.ip_mode       = "static"
				st.static_ip     = "10.0.0.20"
				st.static_dns    = {"10.0.0.1", "10.0.0.2"}
				st.swvlan_backup = {["1"] = "0t 1 2 3 4"}
				st.locating      = true
				st.led_enabled   = false
				state.save(st)
				local loaded = state.load()
				assert_eq(loaded.mac, "00:00:5e:00:53:1a", "identity MAC round-trips")
				assert_eq(loaded.ip_mode, "static", "ip_mode round-trips")
				assert_eq(loaded.static_ip, "10.0.0.20", "static_ip round-trips")
				assert_eq(loaded.static_dns[2], "10.0.0.2", "static_dns list round-trips")
				assert_eq(loaded.swvlan_backup["1"], "0t 1 2 3 4", "switch ledger round-trips")
				assert_eq(loaded.locating, true, "locating round-trips")
				assert_eq(loaded.led_enabled, false, "an explicit false round-trips")
			end)
		end
	},
	{
		name = "state: a wrong-typed persisted field is dropped, whether or not it has a default",
		fn = function()
			-- state.json is edited by operators and written by syswrapper. A
			-- `locating: "no"` read as truthy would make the next start tear
			-- down a Locate that never happened; a `dsa_brlan_ports: "lan1"`
			-- would make restore() iterate a string.
			with_tmp(function()
				local f = io.open(TMP, "w")
				f:write('{"adopted":true,"authkey":"aabbccddeeff00112233445566778899",'
					.. '"locating":"no","dsa_brlan_ports":"lan1","led_enabled":true,'
					.. '"mac":42,"some_future_field":"kept"}')
				f:close()
				local st = state.load()
				assert_nil(st.locating, "wrong-typed locating is absent, not truthy")
				assert_nil(st.dsa_brlan_ports, "wrong-typed ledger is absent")
				assert_nil(st.mac, "wrong-typed mac is absent")
				assert_eq(st.led_enabled, true, "a well-typed neighbour survives")
				assert_eq(st.some_future_field, "kept", "an unknown field still passes through")
			end)
		end
	},
	{
		name = "state: a JSON null on disk is dropped rather than carried as a userdata",
		fn = function()
			with_tmp(function()
				local f = io.open(TMP, "w")
				f:write('{"adopted":true,"authkey":"aabbccddeeff00112233445566778899",'
					.. '"ip_mode":null,"static_ip":"10.0.0.20"}')
				f:close()
				local st = state.load()
				assert_nil(st.ip_mode, "null -> absent, not cjson.null")
				assert_eq(st.static_ip, "10.0.0.20", "the string next to it survives")
			end)
		end
	},
	{
		name = "state: save writes through a temp file and leaves none behind",
		fn = function()
			-- A truncated state.json is read as "defaults", i.e. unadopted with
			-- the well-known key -- so the write must be all-or-nothing. The
			-- temp file is a sibling (same filesystem, so rename is atomic)
			-- and must be gone once save() returns.
			with_tmp(function()
				state.save({adopted = true, authkey = "aabbccddeeff00112233445566778899",
					cfgversion = "", inform_url = "http://x/inform"})
				assert_nil(io.open(TMP .. ".tmp", "r"), "no temp file left behind")
				local f = io.open(TMP, "r")
				assert_not_nil(f, "state file written")
				local raw = f:read("*a"); f:close()
				assert_contains(raw, '"adopted":true', "with the new contents")
				-- and a second save replaces, not appends
				state.save({adopted = false, authkey = "x", cfgversion = "", inform_url = "u"})
				f = io.open(TMP, "r"); raw = f:read("*a"); f:close()
				assert_eq(select(2, raw:gsub("adopted", "")), 1, "exactly one document in the file")
			end)
		end
	},
	{
		name = "state: an unreadable non-empty file warns; an empty one is silent",
		fn = function()
			-- Defaults are still the right answer, but from the controller's
			-- side a device that lost its state looks factory-reset, so the
			-- log has to say why. An empty file is the normal pre-adoption
			-- state install.sh --bootstrap-adopt leaves behind and must not
			-- warn on every start.
			local function capture(fn)
				local buf, real = {}, io.stderr
				io.stderr = {write = function(_, s) buf[#buf + 1] = s end}
				local ok, err = pcall(fn)
				io.stderr = real
				if not ok then error(err, 0) end
				return table.concat(buf)
			end
			with_tmp(function()
				local f = io.open(TMP, "w"); f:write("garbage {{"); f:close()
				local out = capture(function() state.load() end)
				assert_contains(out, "not valid JSON", "corrupt file is named")
				assert_contains(out, "unadopted", "and the consequence spelled out")
				f = io.open(TMP, "w"); f:write(""); f:close()
				assert_eq(capture(function() state.load() end), "", "empty file: no warning")
			end)
		end
	},

	{
		-- conf.lua's inform_url was documented as the first-boot URL and read
		-- by nothing -- defaults() carried its own hardcoded copy, so editing
		-- conf.lua moved no traffic, while install.sh parsed that key to
		-- decide whether an https:// controller needed luasec.
		name = "state: DEFAULT_INFORM_URL supplies the first-boot URL and yields to state.json",
		fn = function()
			local orig_default = state.DEFAULT_INFORM_URL
			with_tmp(function()
				local path = TMP
				state.DEFAULT_INFORM_URL = "https://unifi.example.com:8443/inform"

				-- No file at all: the conf.lua-supplied default is what a fresh
				-- device informs to.
				os.remove(path)
				assert_eq(state.load().inform_url,
					"https://unifi.example.com:8443/inform",
					"first boot uses the configured URL")

				-- A file with no inform_url is the same case.
				local f = io.open(path, "w")
				f:write('{"adopted":false}')
				f:close()
				assert_eq(state.load().inform_url,
					"https://unifi.example.com:8443/inform",
					"a state file without a URL still falls back to it")

				-- An adopted device keeps whatever the controller assigned:
				-- the default must never override a stored URL.
				f = io.open(path, "w")
				f:write('{"adopted":true,"authkey":"'
					.. string.rep("a", 32) .. '","inform_url":"http://10.0.0.5:8080/inform"}')
				f:close()
				assert_eq(state.load().inform_url, "http://10.0.0.5:8080/inform",
					"a controller-assigned URL wins over the default")
			end)
			state.DEFAULT_INFORM_URL = orig_default
		end
	},
}
