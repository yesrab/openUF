--[[
	Ledger of what the controller sent that openUF did not act on.

	Every response `_type`, `cmd`, `mgmt_cfg` key, top-level setparam field
	and `system_cfg` key shape that no handler consumed is recorded here with
	a count, first/last seen and a redacted copy of what arrived, and written
	to /etc/openuf/unhandled.json. Always on -- unlike inform.lua's
	dropped-key report, which shares debug_dump_file's gate and goes to the
	log as names and counts only.

	Why: on 2026-09-06 the controller sent AP1 a `cmd` it had never sent
	before -- `mesh-halt`, the first device-facing mesh verb seen in this lab
	-- and all that survives of it is one logread line naming the verb. The
	unknown-cmd path logged the name and dropped the body, and nothing was
	capturing at the time. The investigation that could have used that body
	(REVERSE-ENGINEERING.md, Investigation 1) is blocked on exactly this kind
	of evidence. amd989/unifi-gateway keeps such a file
	(unhandled_commands.json) as its "living TODO"; this is the same idea
	with the bounds a flash-backed file on a small board needs.

	Bounds: MAX_ENTRIES entries (the oldest last_seen is evicted),
	MAX_PAYLOAD_BYTES per recorded payload (replaced by its key list past
	that), strings cut at MAX_VALUE_CHARS, and any field whose NAME looks
	like a secret (psk, passphrase, password, secret, authkey, token, *key)
	redacted at any depth. Writes are the rare event: a NEW entry is written
	at once, a repeat count only every FLUSH_INTERVAL seconds, both through a
	sibling temp file and rename the way state.json is. The file is research
	data, not adoption state: a factory reset leaves it alone, and losing it
	costs nothing but history.
]]--

local cjson = require("cjson")

local M = {}

M.DEFAULT_FILE      = "/etc/openuf/unhandled.json"
-- false disables the file: entries are still counted in memory for the
-- life of the process (conf.lua: unhandled_file = false).
M._file             = M.DEFAULT_FILE
M.MAX_ENTRIES       = 150
M.MAX_PAYLOAD_BYTES = 2048
M.MAX_VALUE_CHARS   = 200
M.FLUSH_INTERVAL    = 300
-- Injectable clock, as in inform.lua.
M._time             = os.time

M._entries         = {}
M._dirty           = false
M._new_since_flush = false
M._last_flush      = 0

-- Field NAMES whose values are never recorded. Matched case-insensitively
-- against the lowercased name; deliberately broad ("token" catches
-- guest_token, "*key" catches authkey and a hypothetical radius_key, and
-- "psk" catches wpa.psk). Over-redacting an unknown field costs a re-capture
-- with debug_dump_file; under-redacting puts a passphrase on the overlay.
local SECRET_NAMES = {
	"psk", "passphrase", "password", "secret", "authkey", "token", "private",
	"^key$", "%.key$", "_key$", "%-key$",
}

function M.is_secret_name(name)
	if type(name) ~= "string" then return false end
	local n = name:lower()
	for _, pat in ipairs(SECRET_NAMES) do
		if n:find(pat) then return true end
	end
	return false
end

local function iso(t)
	return os.date("!%Y-%m-%dT%H:%M:%SZ", t)
end

-- A copy of `value` safe to write to disk: secrets replaced by their name's
-- verdict, long strings cut, nesting capped. `name` is the field the value
-- sits under (nil for a bare value or an array element).
function M.redact(value, name, depth)
	depth = depth or 0
	if M.is_secret_name(name) then return "<redacted>" end
	local t = type(value)
	if t == "string" then
		if #value > M.MAX_VALUE_CHARS then
			return value:sub(1, M.MAX_VALUE_CHARS)
				.. ("...(+%d chars)"):format(#value - M.MAX_VALUE_CHARS)
		end
		return value
	elseif t == "number" or t == "boolean" then
		return value
	elseif t == "table" then
		if depth >= 4 then return "<nested>" end
		local out = {}
		for k, v in pairs(value) do
			out[k] = M.redact(v, type(k) == "string" and k or nil, depth + 1)
		end
		return out
	elseif value == cjson.null then
		return cjson.null
	end
	return "<" .. t .. ">"
end

-- Keep a payload within MAX_PAYLOAD_BYTES once encoded; past that only its
-- top-level key list survives, which still says what shape arrived.
local function bound_payload(p)
	local ok, enc = pcall(cjson.encode, p)
	if not ok then return {_unencodable = tostring(enc)} end
	if #enc <= M.MAX_PAYLOAD_BYTES then return p end
	local keys = {}
	if type(p) == "table" then
		for k in pairs(p) do keys[#keys + 1] = tostring(k) end
		table.sort(keys)
	end
	return {_truncated_bytes = #enc, _keys = keys}
end

local function evict()
	local n = 0
	for _ in pairs(M._entries) do n = n + 1 end
	while n > M.MAX_ENTRIES do
		local oldest_id, oldest_ts
		for id, e in pairs(M._entries) do
			local ts = tonumber(e.last_ts) or 0
			if not oldest_ts or ts < oldest_ts then oldest_id, oldest_ts = id, ts end
		end
		M._entries[oldest_id] = nil
		n = n - 1
	end
end

-- Record one sighting. category: "response" | "field" | "cmd" | "mgmt_cfg"
-- | "system_cfg"; key: the thing openUF did not understand (the _type, the
-- cmd name, the config key shape); payload: what came with it, redacted
-- here. Returns the entry and whether it was new.
function M.record(category, key, payload)
	category, key = tostring(category), tostring(key)
	local id  = category .. "/" .. key
	local now = M._time()
	local e = M._entries[id]
	local is_new = (e == nil)
	if is_new then
		e = {category = category, key = key, count = 0, first_seen = iso(now)}
		M._entries[id] = e
		M._new_since_flush = true
	end
	e.count     = e.count + 1
	e.last_seen = iso(now)
	e.last_ts   = now
	if payload ~= nil then e.payload = bound_payload(M.redact(payload)) end
	M._dirty = true
	evict()
	return e, is_new
end

function M.entry(category, key)
	return M._entries[tostring(category) .. "/" .. tostring(key)]
end

function M.count()
	local n = 0
	for _ in pairs(M._entries) do n = n + 1 end
	return n
end

-- Read the ledger back so counts and first_seen carry across restarts. A
-- missing or unparseable file starts empty -- loudly when it had content,
-- silently when it did not.
function M.load()
	M._entries, M._dirty, M._new_since_flush = {}, false, false
	M._last_flush = M._time()
	if not M._file then return M._entries end
	local f = io.open(M._file, "r")
	if not f then return M._entries end
	local raw = f:read("*a")
	f:close()
	local ok, tbl = pcall(cjson.decode, raw)
	if ok and type(tbl) == "table" and type(tbl.entries) == "table" then
		for id, e in pairs(tbl.entries) do
			if type(e) == "table" and type(e.category) == "string"
			   and type(e.key) == "string" then
				e.count = tonumber(e.count) or 0
				M._entries[id] = e
			end
		end
	elseif type(raw) == "string" and raw:match("%S") then
		io.stderr:write("unhandled: " .. M._file
			.. " is not valid JSON -- starting an empty ledger\n")
	end
	return M._entries
end

-- Write if there is anything to write and it is time to: at once for a new
-- entry, every FLUSH_INTERVAL for repeat counts, always with force. Returns
-- true when the file was written.
function M.flush(force)
	if not M._dirty then return false end
	if not M._file then
		M._dirty, M._new_since_flush = false, false
		return false
	end
	local now = M._time()
	if not (force or M._new_since_flush
	        or now - M._last_flush >= M.FLUSH_INTERVAL) then
		return false
	end
	local doc = {version = 1, updated = iso(now), entries = M._entries}
	local tmp = M._file .. ".tmp"
	local f = io.open(tmp, "w")
	if not f then
		local dir = M._file:match("^(.*)/[^/]+$")
		if dir then os.execute("mkdir -p '" .. dir .. "'") end
		f = io.open(tmp, "w")
		if not f then return false, "unhandled: cannot write " .. tmp end
	end
	f:write(cjson.encode(doc))
	f:close()
	local ok, err = os.rename(tmp, M._file)
	if not ok then
		os.remove(tmp)
		return false, "unhandled: cannot replace " .. M._file .. ": " .. tostring(err)
	end
	M._dirty, M._new_since_flush, M._last_flush = false, false, now
	return true
end

-- Test seam: forget everything; optionally point at another file.
function M._reset(file)
	M._entries, M._dirty, M._new_since_flush, M._last_flush = {}, false, false, 0
	if file ~= nil then M._file = file end
end

return M
