--[[
	State persistence for openuf.

	Reads and writes /etc/openuf/state.json (configurable via M._state_file,
	which the entry points set from conf.lua's config.state_file).

	Typed fields, each with a default that a wrong-typed value on disk falls
	back to: authkey (32-char hex), adopted (bool), cfgversion (string),
	inform_url (string), use_gcm (bool), upgrade_requested_version (string),
	upgrade_requested_url (string), blocked_stas (array of MAC strings).

	Everything else save() was handed comes back from load() as-is. That is
	not an accident of cjson.encode -- it is load-bearing: inform.lua keeps
	the switch reversibility ledger (swvlan_backup), the IP Settings mode
	(ip_mode, static_*), the last identity MAC (mac), the Locate and LED
	state here too, and USAGE.md documents them as persisted. load() used to
	read back only the typed fields above, so all of those were written on
	every save and silently discarded on every start: the identity-change
	warning never had a previous MAC to compare against, and a daemon
	restart made the switch ledger re-snapshot already-mutated sections as
	the board's originals.

	Security invariant: if adopted == false, authkey is always reset to the
	default key on load, regardless of what the file contains. This prevents a
	stale key from blocking adoption after a reset.
]]--

local cjson = require("cjson")

local M = {}

-- Default adoption key (pre-shared, well-known across all UniFi firmware)
M.DEFAULT_KEY = "ba86f2bbe107c7c57eb5f2690775c712"

-- Override this in tests to point at a temp file
M._state_file = "/etc/openuf/state.json"

local function defaults()
	return {
		authkey                  = M.DEFAULT_KEY,
		adopted                  = false,
		cfgversion               = "",
		inform_url               = "http://unifi:8080/inform",
		use_gcm                  = false,
		upgrade_requested_version = "",
		upgrade_requested_url     = "",
		blocked_stas             = {},
	}
end

-- The fields with a fixed type. Anything else in the file is carried through
-- untouched (see the header), but these fall back to their default when the
-- on-disk value has the wrong type -- a corrupted `adopted: "yes"` must not
-- become truthy.
local TYPED = {
	authkey                   = "string",
	adopted                   = "boolean",
	cfgversion                = "string",
	inform_url                = "string",
	use_gcm                   = "boolean",
	upgrade_requested_version = "string",
	upgrade_requested_url     = "string",
	blocked_stas              = "table",
}

-- Load state from disk. Missing file returns defaults. Applies security
-- invariant: resets authkey if adopted == false.
function M.load()
	local f = io.open(M._state_file, "r")
	if not f then
		return defaults()
	end
	local raw = f:read("*a")
	f:close()

	local ok, tbl = pcall(cjson.decode, raw)
	if not ok or type(tbl) ~= "table" then
		-- Falling back to defaults here means the device comes up UNADOPTED
		-- with the well-known key -- the right call for a garbage file, but
		-- it must not be silent, because from the controller's side it is
		-- indistinguishable from a factory reset. An EMPTY file is normal
		-- (install.sh --bootstrap-adopt pre-creates one) and says nothing.
		if type(raw) == "string" and raw:match("%S") then
			io.stderr:write("state: " .. M._state_file .. " is not valid JSON -- "
				.. "starting from defaults; the device will appear unadopted\n")
		end
		return defaults()
	end

	local st = defaults()
	for k, v in pairs(tbl) do
		local want = TYPED[k]
		if want then
			if type(v) == want then st[k] = v end
		else
			-- cjson decodes JSON null to a userdata sentinel, which is the
			-- one value type that has no business in the state table.
			local t = type(v)
			if t == "string" or t == "boolean" or t == "number" or t == "table" then
				st[k] = v
			end
		end
	end

	-- Security invariant: never use a custom key when not adopted
	if not st.adopted then
		st.authkey = M.DEFAULT_KEY
	end

	return st
end

-- Save state to disk. Creates the parent directory only if the first write
-- fails (avoids shelling out to `mkdir -p` on every heartbeat, since the
-- directory almost always already exists).
--
-- Written to a sibling temp file and renamed into place. rename(2) is atomic
-- on the same filesystem, so a power cut or a full overlay mid-write leaves
-- either the old file or the new one -- never a truncated one. That matters
-- more here than for most files: load() treats unparseable JSON as "start
-- from defaults", which resets the authkey and un-adopts the device, so an
-- in-place write interrupted at the wrong moment cost the adoption outright.
-- A side effect worth knowing: the bootstrap `ubnt` account only needs write
-- permission on the DIRECTORY now, not on the previous file.
function M.save(st)
	local tmp = M._state_file .. ".tmp"
	local f = io.open(tmp, "w")
	if not f then
		local dir = M._state_file:match("^(.*)/[^/]+$")
		if dir then os.execute("mkdir -p '" .. dir .. "'") end
		f = io.open(tmp, "w")
		if not f then
			error("state.save: cannot write to " .. tmp)
		end
	end
	f:write(cjson.encode(st))
	f:close()
	local ok, err = os.rename(tmp, M._state_file)
	if not ok then
		os.remove(tmp)
		error("state.save: cannot replace " .. M._state_file .. ": " .. tostring(err))
	end
end

-- Reset state to defaults and persist immediately.
function M.reset()
	local st = defaults()
	M.save(st)
	return st
end

return M
