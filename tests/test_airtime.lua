-- Tests for openuf/airtime.lua (Airtime Fairness via mac80211 debugfs).
-- Run from project root: lua tests/run_tests.lua

local airtime = dofile("openuf/airtime.lua")

local P0 = "/sys/kernel/debug/ieee80211/phy0/airtime_flags"
local P1 = "/sys/kernel/debug/ieee80211/phy1/airtime_flags"

-- What mac80211's airtime_flags read returns for a value: one line per set bit.
local function render(v)
	local n, out = tonumber(v) or 0, ""
	if n % 2 == 1 then out = out .. "AIRTIME_TX\t(1)\n" end
	if math.floor(n / 2) % 2 == 1 then out = out .. "AIRTIME_RX\t(2)\n" end
	return out
end

-- A fake debugfs: `phys` maps path -> current value. `reject` makes a write to
-- that path fail. Returns the list of writes.
local function with_debugfs(phys, fn, reject)
	local o_cmd, o_w, o_r = airtime._run_cmd, airtime._write_file, airtime._read_file
	local writes = {}
	airtime._run_cmd = function(cmd)
		local out = {}
		for p in pairs(phys) do out[#out + 1] = p end
		table.sort(out, function(a, b) return a > b end)  -- unsorted on purpose
		return table.concat(out, "\n") .. (#out > 0 and "\n" or "")
	end
	airtime._write_file = function(path, v)
		writes[#writes + 1] = {path = path, v = v}
		if reject and reject[path] then return false end
		phys[path] = v
		return true
	end
	airtime._read_file = function(path)
		return phys[path] and render(phys[path]) or nil
	end
	airtime._supported_cache = nil
	local ok, err = pcall(fn, writes)
	airtime._run_cmd, airtime._write_file, airtime._read_file = o_cmd, o_w, o_r
	airtime._supported_cache = nil
	if not ok then error(err, 0) end
end

return {
	{
		name = "airtime: parse reads atf.mode, nil without it",
		fn = function()
			-- Captured on 10.4.57 2026-09-27 with wifi_caps 0x2C claimed.
			assert_true(airtime.parse("x=1\natf.status=enabled\natf.mode=enabled\n"), "enabled")
			assert_false(airtime.parse("atf.status=enabled\natf.mode=disabled\n"), "disabled, at blob start")
			assert_nil(airtime.parse("radio.1.channel=6\n"), "no block")
			assert_nil(airtime.parse("atf.status=enabled\n"), "status alone is not the switch")
			assert_nil(airtime.parse("x=1\natf.mode=bogus\n"), "unknown mode")
			assert_nil(airtime.parse(nil), "nil blob")
		end
	},
	{
		name = "airtime: supported only when a phy exposes airtime_flags",
		fn = function()
			with_debugfs({}, function()
				assert_false(airtime.supported(), "no phys")
			end)
			with_debugfs({[P0] = "3"}, function()
				assert_true(airtime.supported(), "one phy")
			end)
		end
	},
	{
		name = "airtime: set_enabled(false) writes 0 to every phy and reads it back",
		fn = function()
			local phys = {[P0] = "3", [P1] = "3"}
			with_debugfs(phys, function(writes)
				local done, total = airtime.set_enabled(false)
				assert_eq(total, 2, "two phys")
				assert_eq(done, 2, "both read back off")
				assert_eq(writes[1].path, P0, "sorted: phy0 first")
				assert_eq(writes[1].v, "0", "0 = charge nothing")
				assert_eq(phys[P1], "0", "phy1 off")
			end)
		end
	},
	{
		name = "airtime: set_enabled(true) restores mac80211's default 3",
		fn = function()
			local phys = {[P0] = "0", [P1] = "0"}
			with_debugfs(phys, function()
				local done = airtime.set_enabled(true)
				assert_eq(done, 2, "both read back on")
				assert_eq(phys[P0], "3", "TX|RX")
			end)
		end
	},
	{
		name = "airtime: a rejected write is not counted as done",
		fn = function()
			local phys = {[P0] = "3", [P1] = "3"}
			with_debugfs(phys, function()
				local done, total = airtime.set_enabled(false)
				assert_eq(done, 1, "only phy0")
				assert_eq(total, 2, "of two")
			end, {[P1] = true})
		end
	},
	{
		name = "airtime: a write that reads back wrong is not counted as done",
		fn = function()
			local phys = {[P0] = "3"}
			with_debugfs(phys, function()
				local r = airtime._read_file
				airtime._read_file = function() return render("1") end  -- RX refused
				local done = airtime.set_enabled(true)
				airtime._read_file = r
				assert_eq(done, 0, "TX alone is not on")
			end)
		end
	},
	{
		name = "airtime: flag_files ignores anything but phyN/airtime_flags",
		fn = function()
			local o = airtime._run_cmd
			airtime._run_cmd = function()
				return "ls: /sys/kernel/debug/ieee80211/phy*/airtime_flags: No such file\n"
					.. P0 .. "\n/sys/kernel/debug/ieee80211/phy0/aql_enable\n"
			end
			local files = airtime.flag_files()
			airtime._run_cmd = o
			assert_eq(#files, 1, "one")
			assert_eq(files[1], P0, "phy0")
		end
	},
}
