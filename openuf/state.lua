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

-- The inform URL a device uses until a controller (or `syswrapper.sh
-- set-inform`) gives it one. inform.lua's entry point sets this from
-- conf.lua's inform_url; it only ever fills a state.json that has no URL of
-- its own, so an adopted device keeps whatever it was assigned and a factory
-- reset goes back to conf.lua.
M.DEFAULT_INFORM_URL = "http://unifi:8080/inform"

local function defaults()
	return {
		authkey                  = M.DEFAULT_KEY,
		adopted                  = false,
		cfgversion               = "",
		inform_url               = M.DEFAULT_INFORM_URL,
		use_gcm                  = false,
		upgrade_requested_version = "",
		upgrade_requested_url     = "",
		blocked_stas             = {},
	}
end

-- The fields with a fixed type. Anything else in the file is carried through
-- untouched (see the header), but these are DROPPED when the on-disk value
-- has the wrong type -- the eight with a default fall back to it, the rest
-- come back absent. A corrupted `adopted: "yes"` must not become truthy, and
-- a `locating: "no"` must not read as "still locating" at startup. The list
-- is documentation as much as protection: every field openUF persists is
-- named here with its type, without making the name a registration step a
-- new field can forget (upstream's whitelist approach reintroduced exactly
-- that hazard). state.json is not a trusted input -- an operator edits it,
-- syswrapper writes it.
local TYPED = {
	authkey                   = "string",
	adopted                   = "boolean",
	cfgversion                = "string",
	inform_url                = "string",
	use_gcm                   = "boolean",
	upgrade_requested_version = "string",
	upgrade_requested_url     = "string",
	blocked_stas              = "table",
	-- Identity, re-derived at startup by inform's _populate_net_info. Kept
	-- so the PREVIOUS run's values are readable at that moment: M.run
	-- compares the loaded mac against the live one to catch a modelmap
	-- change that silently re-identifies an adopted device.
	mac                       = "string",
	ip                        = "string",
	hostname                  = "string",
	-- Controller-pushed IP settings. ip_mode is the "was I static before?"
	-- guard on the DHCP path, which must not flush a working lease just
	-- because a steady-state push reaffirmed DHCP.
	ip_mode                   = "string",
	static_ip                 = "string",
	static_netmask            = "string",
	static_gateway            = "string",
	static_dns                = "table",
	-- Live kernel state, not UCI, so it is reapplied from here at startup the
	-- way the blocked-client rules are. locate_prev_trigger is the LED
	-- trigger a Locate displaced, for the unset-locate that may arrive after
	-- a restart.
	led_enabled               = "boolean",
	locating                  = "boolean",
	locate_prev_trigger       = "string",
	-- The per-port VLAN reversibility ledgers: the stock switch_vlan `ports`
	-- strings openUF overwrote (swconfig), and br-lan's port list exactly as
	-- the board shipped it (DSA). Without them restore() has nothing to put
	-- back and the board keeps openUF's VLAN config forever.
	swvlan_backup             = "table",
	dsa_brlan_ports           = "table",
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
