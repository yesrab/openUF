--[[
	Fake `uci` Lua module for the disposable validation AP container ONLY.

	This is not part of openUF -- it exists purely so `openuf/ucihelper.lua`'s
	`require("uci")` fallback resolves to something real inside this
	hardware-less Alpine container, unblocking the parts of
	PROTOCOL-VALIDATION.md that need a non-empty radio_table (SSID push, VLAN
	join, Fast Roaming, TX power, RF-scan trigger). openUF's product code is
	untouched -- ucihelper.lua already has the `M._uci` injection seam this
	relies on for unit tests; this file just makes the SAME fallback path
	(`require("uci")`, used when `M._uci` is nil) resolve to an in-memory
	backend instead of a real UCI binding that doesn't exist here.

	Implements only the subset of the real `uci` Lua binding's cursor API
	that ucihelper.lua actually calls: cursor:foreach/set/delete/commit.
	Mirrors the exact same mock shape already proven correct by
	tests/test_ucihelper.lua's `new_mock_uci()` -- same semantics, just
	exposed as a real requirable module instead of an in-process table.

	Seeded with two wifi-device radio sections (radio0 = 2.4GHz, radio1 =
	5GHz) matching openuf/modelmap/generic-dualband-ap.lua's
	`dev.openuf.uap.hwassign` -- the real target hardware's documented radio
	naming convention -- so get_radio_table() returns real, non-empty
	entries immediately, exactly as real OpenWrt's wireless driver would
	populate at boot regardless of any configured SSID.
]]--

local M = {}

local db = {}             -- db[config][section] = { [".name"]=, [".type"]=, key=val, ... }
local section_order = {}  -- section_order[config] = {name, ...} (foreach iteration order)

local function seed()
	db.wireless = {
		radio0 = {
			[".name"] = "radio0", [".type"] = "wifi-device",
			channel = "6", htmode = "HT40", txpower = "20", disabled = "0",
		},
		radio1 = {
			[".name"] = "radio1", [".type"] = "wifi-device",
			channel = "36", htmode = "VHT80", txpower = "20", disabled = "0",
		},
	}
	section_order.wireless = {"radio0", "radio1"}
	db.network = {}
	section_order.network = {}
end
seed()

function M.cursor()
	local cursor = {}

	function cursor:set(config, section, a, b)
		db[config] = db[config] or {}
		if not db[config][section] then
			db[config][section] = {[".name"] = section}
			section_order[config] = section_order[config] or {}
			section_order[config][#section_order[config] + 1] = section
		end
		if b == nil then
			db[config][section][".type"] = a
		else
			db[config][section][a] = b
		end
	end

	function cursor:foreach(config, stype, fn)
		for _, name in ipairs(section_order[config] or {}) do
			local s = db[config] and db[config][name]
			if s and s[".type"] == stype then fn(s) end
		end
	end

	function cursor:delete(config, section)
		if db[config] then db[config][section] = nil end
		if section_order[config] then
			for i, name in ipairs(section_order[config]) do
				if name == section then table.remove(section_order[config], i); break end
			end
		end
	end

	function cursor:commit(config) end

	return cursor
end

-- Test/debug hook only -- not part of the real uci API, but handy for
-- inspecting the mock's live state from a REPL during validation work.
M._db = db

return M
