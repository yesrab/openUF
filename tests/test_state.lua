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
				local st = state.load()
				assert_eq(st.authkey, DEFKEY, "defaults on bad JSON")
				assert_eq(st.adopted, false,  "defaults on bad JSON")
			end)
		end
	},
}
