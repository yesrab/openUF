--[[
	State persistence for openuf.

	Reads and writes /etc/openuf/state.json (configurable via M._state_file).
	Fields: authkey (32-char hex), adopted (bool), cfgversion (string),
	        inform_url (string).

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
		authkey    = M.DEFAULT_KEY,
		adopted    = false,
		cfgversion = "",
		inform_url = "http://unifi:8080/inform",
		use_gcm    = false,
	}
end

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
		return defaults()
	end

	local st = defaults()
	if type(tbl.authkey)    == "string"  then st.authkey    = tbl.authkey    end
	if type(tbl.adopted)    == "boolean" then st.adopted    = tbl.adopted    end
	if type(tbl.cfgversion) == "string"  then st.cfgversion = tbl.cfgversion end
	if type(tbl.inform_url) == "string"  then st.inform_url = tbl.inform_url end
	if type(tbl.use_gcm)    == "boolean" then st.use_gcm    = tbl.use_gcm    end

	-- Security invariant: never use a custom key when not adopted
	if not st.adopted then
		st.authkey = M.DEFAULT_KEY
	end

	return st
end

-- Save state to disk. Creates the directory if needed.
function M.save(st)
	-- Ensure directory exists
	local dir = M._state_file:match("^(.*)/[^/]+$")
	if dir then os.execute("mkdir -p " .. dir) end

	local f = io.open(M._state_file, "w")
	if not f then
		error("state.save: cannot write to " .. M._state_file)
	end
	f:write(cjson.encode(st))
	f:close()
end

-- Reset state to defaults and persist immediately.
function M.reset()
	local st = defaults()
	M.save(st)
	return st
end

return M
