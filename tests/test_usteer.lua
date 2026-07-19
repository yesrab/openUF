-- Tests for openuf/usteer.lua (Band Steering via the usteer daemon).
-- Run from project root: lua tests/run_tests.lua
--
-- Uses the same in-memory mock UCI cursor shape as test_ucihelper.lua
-- (cursor:set/get/commit).

local usteer = dofile("openuf/usteer.lua")

local function new_mock_uci()
	local db = {}  -- db[config][section] = { [".name"]=.., [".type"]=.., key=val, ... }

	local cursor = {}

	function cursor:set(config, section, a, b)
		db[config] = db[config] or {}
		if not db[config][section] then
			db[config][section] = {[".name"] = section}
		end
		if b == nil then
			db[config][section][".type"] = a
		else
			db[config][section][a] = b
		end
	end

	function cursor:get(config, section, option)
		local s = db[config] and db[config][section]
		return s and s[option]
	end

	-- Recorded, not applied -- the counter lets tests catch a dropped commit.
	local commits = {}
	function cursor:commit(config)
		commits[config] = (commits[config] or 0) + 1
	end

	return {mock = {cursor = function() return cursor end}, db = db, commits = commits}
end

-- Fresh mock UCI + captured commands for each test.
local function with_usteer(fn)
	local m = new_mock_uci()
	local cmds = {}
	local orig_uci, orig_run = usteer._uci, usteer._run_cmd
	usteer._uci = m.mock
	usteer._run_cmd = function(cmd) cmds[#cmds + 1] = cmd; return true end
	local ok, err = pcall(fn, m.db, cmds, m.commits)
	usteer._uci, usteer._run_cmd = orig_uci, orig_run
	if not ok then error(err, 2) end
end

local function cmds_contain(cmds, substr)
	for _, c in ipairs(cmds) do
		if c:find(substr, 1, true) then return true end
	end
	return false
end

return {
	{
		name = "usteer: set_enabled(false) neutralizes threshold and stops/disables the daemon",
		fn = function()
			with_usteer(function(db, cmds)
				local ok = usteer.set_enabled(false, nil)
				assert_true(ok, "set_enabled returns true")
				local s = db.usteer["local"]
				assert_eq(s.band_steering_threshold, "0", "threshold neutralized")
				assert_eq(s.network, "lan", "defaults network to lan without cfg")
				assert_true(cmds_contain(cmds, "usteer stop"), "stops the daemon")
				assert_true(cmds_contain(cmds, "usteer disable"), "disables the daemon")
			end)
		end
	},
	{
		name = "usteer: set_enabled(true) runs the daemon with a nonzero threshold",
		fn = function()
			with_usteer(function(db, cmds)
				local ok = usteer.set_enabled(true, nil)
				assert_true(ok, "set_enabled returns true")
				local s = db.usteer["local"]
				-- NB: this pins the option NAME as a regression lock only --
				-- usteer.lua's header flags `band_steering_threshold` and its
				-- default as BEST-EFFORT/UNCONFIRMED against the real usteer
				-- schema. If a real-deploy verification renames the option,
				-- update this assertion together with the source; a red here
				-- after such a change is expected, not a regression.
				assert_eq(s.band_steering_threshold,
					tostring(usteer.USTEER_DEFAULTS.band_steering_threshold),
					"nonzero band-preference threshold")
				assert_true(cmds_contain(cmds, "usteer enable"), "enables the daemon")
				assert_true(cmds_contain(cmds, "usteer restart"), "restarts the daemon")
			end)
		end
	},
	{
		name = "usteer: a repeated set_enabled is a no-op (no restart churn)",
		fn = function()
			-- set_enabled runs on every WiFi setparam; before the guard each
			-- steady-state inform restarted the daemon, dropping its learned
			-- station table.
			with_usteer(function(db, cmds, commits)
				assert_true(usteer.set_enabled(true, nil), "first call writes")
				local after_first = #cmds
				assert_eq(commits.usteer, 1, "first call commits")
				assert_true(usteer.set_enabled(true, nil), "second call still reports success")
				assert_eq(#cmds, after_first, "no second enable/restart issued")
				assert_eq(commits.usteer, 1, "steady state issues no further commits")

				usteer.set_enabled(false, nil)
				local after_disable = #cmds
				assert_true(after_disable > after_first, "transition to disabled acts")
				usteer.set_enabled(false, nil)
				assert_eq(#cmds, after_disable, "repeated disable issues no further commands")
			end)
		end
	},
	{
		name = "usteer: set_enabled uses cfg.net.lan_name when present",
		fn = function()
			with_usteer(function(db, cmds)
				usteer.set_enabled(true, {net = {lan_name = "br-lan"}})
				assert_eq(db.usteer["local"].network, "br-lan", "network taken from cfg")
			end)
		end
	},
}
