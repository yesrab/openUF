--[[
	plugins.lua -- plugins: opt-in extensions, third-party and built in.

	The `api = 1` contract and its guard rails are jonasevcik/openUF's
	(feature/plugin-hooks, 26ad689, 2026-10-25), taken as they are so that a
	plugin written for upstream runs here unchanged: a plugin is a Lua table
	with `api = 1` and a `vap_options(extra, vap, ctx)` function that edits
	the UCI options of one WLAN after every built-in option is in place.
	Upstream ignores fields it does not know, so a plugin that also declares
	the hooks below still loads there.

	What this tree adds, all optional, because its own 802.11r translator
	(plugins/rrb.lua, the first built-in plugin) needed every one of them:

	    radio_options(extra, radio, ctx)   per wifi-device, after rf_config
	    before_push(ctx, push)             before the WLANs are written
	    after_push(ctx, push)              after the wifi reload
	    tick(ctx)                          once per heartbeat, time-budgeted
	    on_boot(ctx)                       at daemon start (kernel state is
	                                       rebuilt then; the controller never
	                                       re-pushes it)
	    on_forget(ctx)                     when the controller is forgotten
	    status(ctx)                        a JSON-able table for the UI
	    enabled(cfg)                       built-ins only: when to load
	    packages = {{pkg=, evidence=, unlocks=}, ...}
	    services = {"name", ...}           procd services openuf deps enables
	    nft_tables = {"bridge x", ...}     what on_forget must leave clean

	and ctx carries, besides upstream's DELETE, bssid(), cursor(), read_file
	and log: exists(path), run(cmd), reload_network(), util (a frozen subset:
	bit, is_mac, valid_ifname, sha1), store (a table persisted for this plugin
	in state.json) and repush() (asks the controller for the full config
	again, rate-limited by openUF, never by the plugin).

	Two kinds of plugin, one loader:

	  * third-party: /etc/openuf/plugins/<name>.lua, loaded only when
	    conf.lua / openuf.main lists the name (`plugins = {"name"}`,
	    `list plugin 'name'`). Off by default; with the list empty nothing
	    changes.
	  * built in: plugins/<name>.lua in the tree, named in BUILTIN, loaded
	    when its own `enabled(cfg)` says so (rrb: cfg.config.unifi_ft_interop).
	    A built-in has no entry in the plugins list; it is a feature with its
	    own switch, written against the same hooks so the hooks are proven.

	Guard rails (upstream's): a plugin that fails to load, has another `api`,
	raises, or returns a bad edit is logged and skipped, and the push goes on.
	An edit is all-or-nothing per VAP. An option name must be [A-Za-z0-9_]+
	(libuci drops anything else silently), and a plugin may not touch the
	section's identity (device, mode, ssid, encryption, network, key) or the
	openuf_* stamps that drive openUF's own enforcement. Capability bits and
	the inform payload are not reachable through any hook: never claim what
	the device cannot honour. A hook that raises is logged and skipped; a
	tick that takes longer than TICK_BUDGET seconds is logged too.

	No teardown is needed for UCI options: apply_config rebuilds every
	openuf_ section on each push, so dropping a plugin drops its options with
	the next push. Anything else a plugin leaves on the device (network
	sections, nft tables, a daemon) is its on_forget's job.

	A plugin is arbitrary Lua running as root, exactly as conf.lua is. This
	module is a hook, not a sandbox.
]]--

local M = {}
local util = package.loaded["openuf.util"]
	or assert(loadfile("util.lua") or loadfile("openuf/util.lua"))()

M.API = 1
M.DIR = "/etc/openuf/plugins"
-- Built-in plugins, by name; each is plugins/<name>.lua next to this module.
M.BUILTIN = {"rrb"}
M.BUILTIN_DIRS = {"plugins", "openuf/plugins"}
-- Seconds a plugin's tick may take before a log line says so.
M.TICK_BUDGET = 1

-- Injectable seams.
M._read_file = util.read_file
M._log = function(msg) io.stderr:write("openuf: plugin " .. msg .. "\n") end
M._clock = os.clock

-- Options a plugin may not set: the section's identity, which wlan_add writes
-- before `extra`, and openUF's own stamps (openuf_*).
local RESERVED = {
	device = true, mode = true, ssid = true, encryption = true,
	network = true, key = true,
}
-- The same for a wifi-device: what names the radio and what the controller
-- drives through rf_config.
local RESERVED_RADIO = {
	type = true, path = true, phy = true, band = true, hwmode = true,
	disabled = true, channel = true, htmode = true, txpower = true, country = true,
}

-- Load plugin `name`: its table, or nil and the reason. Cached per process, so
-- a changed plugin file takes a restart (as conf.lua does).
local loaded = {}

function M._load(name, builtin)
	local paths = {}
	if builtin then
		for _, d in ipairs(M.BUILTIN_DIRS) do paths[#paths + 1] = d .. "/" .. name .. ".lua" end
	else
		paths[1] = M.DIR .. "/" .. name .. ".lua"
	end
	local src, path
	for _, p in ipairs(paths) do
		src = M._read_file(p)
		if src then path = p break end
	end
	if not src then return nil, "cannot read " .. paths[1] end
	local chunk, err = (loadstring or load)(src, "=" .. path)
	if not chunk then return nil, err end
	local ok, mod = pcall(chunk)
	if not ok then return nil, tostring(mod) end
	return mod
end

-- Forget what has been loaded (tests).
function M._reset() loaded = {} end

local HOOKS = {"vap_options", "radio_options", "before_push", "after_push",
	"tick", "on_boot", "on_forget", "status"}

local function get(name, builtin)
	local key = (builtin and "builtin:" or "") .. tostring(name)
	if loaded[key] == nil then
		local mod, err
		if not tostring(name):match("^[%w_%-]+$") then
			err = "invalid plugin name"
		else
			mod, err = M._load(name, builtin)
		end
		if mod ~= nil and type(mod) ~= "table" then
			mod, err = nil, "did not return a table"
		end
		if mod and mod.api ~= M.API then
			mod, err = nil, string.format("api %s, this openUF speaks api %d",
				tostring(mod.api), M.API)
		end
		if mod then
			-- Upstream's contract: vap_options is the one required hook.
			-- Here a plugin may instead provide any other hook, but at
			-- least one of them.
			local any = false
			for _, h in ipairs(HOOKS) do
				if mod[h] ~= nil then
					if type(mod[h]) ~= "function" then
						mod, err = nil, h .. " is not a function"
						break
					end
					any = true
				end
			end
			if mod and not any then mod, err = nil, "has no vap_options function (nor any other hook)" end
		end
		if not mod then
			M._log(string.format("%s: not loaded: %s", tostring(name), tostring(err)))
		end
		loaded[key] = mod or false
	end
	return loaded[key] or nil
end

-- Why a built-in is off, or nil when it should load.
local function builtin_off(mod, cfg)
	if type(mod.enabled) ~= "function" then return nil end
	local ok, on = pcall(mod.enabled, cfg)
	if not ok then return "enabled() raised: " .. tostring(on) end
	if not on then return "off" end
	return nil
end

-- The enabled plugins, built-ins first (tree order), then conf.lua's list in
-- its order. A name listed twice runs once. Each entry: {name, mod, builtin}.
function M.enabled(cfg)
	local out, seen = {}, {}
	for _, name in ipairs(M.BUILTIN) do
		local mod = get(name, true)
		if mod and not builtin_off(mod, cfg) then
			seen[name] = true
			out[#out + 1] = {name = name, mod = mod, builtin = true}
		end
	end
	local names = cfg and cfg.config and cfg.config.plugins
	if names ~= nil and type(names) ~= "table" then
		M._log("config.plugins must be a list of names; ignored")
		names = nil
	end
	for _, name in ipairs(names or {}) do
		if not seen[name] then
			seen[name] = true
			local mod = get(name, false)
			if mod then out[#out + 1] = {name = name, mod = mod, builtin = false} end
		end
	end
	return out
end

-- Every built-in and listed plugin with its load state, for the UI and the
-- fingerprint: {name, builtin, loaded, reason}.
function M.list(cfg)
	local out = {}
	for _, name in ipairs(M.BUILTIN) do
		local mod = get(name, true)
		local off = mod and builtin_off(mod, cfg)
		out[#out + 1] = {name = name, builtin = true, loaded = mod ~= nil and not off,
			reason = (not mod and "not loaded (see the log)") or off}
	end
	local names = cfg and cfg.config and cfg.config.plugins
	if type(names) == "table" then
		local seen = {}
		for _, name in ipairs(names) do
			if not seen[name] then
				seen[name] = true
				local mod = get(name, false)
				out[#out + 1] = {name = tostring(name), builtin = false, loaded = mod ~= nil,
					reason = not mod and "not loaded (see the log)" or nil}
			end
		end
	end
	return out
end

-- A string that changes when the set of plugins that would run changes
-- (names, their api, what they declare and the size of their source). The
-- daemon compares it with the one state.json holds and asks the controller
-- for the full config again when it moved, so enabling or removing a plugin
-- takes effect without a Force Provision.
function M.fingerprint(cfg)
	local parts = {}
	for _, p in ipairs(M.enabled(cfg)) do
		local hooks = {}
		for _, h in ipairs(HOOKS) do if p.mod[h] then hooks[#hooks + 1] = h end end
		parts[#parts + 1] = p.name .. ":" .. tostring(p.mod.api) .. ":" .. table.concat(hooks, "+")
	end
	return table.concat(parts, ",")
end

-- Deep copy that keeps the DELETE sentinel itself: it is compared by identity.
local function copy(t, keep)
	local out = {}
	for k, v in pairs(t) do
		out[k] = (type(v) == "table" and v ~= keep) and copy(v, keep) or v
	end
	return out
end

local function same(a, b)
	if type(a) ~= "table" or type(b) ~= "table" then return a == b end
	if #a ~= #b then return false end
	for i = 1, #a do
		if a[i] ~= b[i] then return false end
	end
	return true
end

-- Why `v` is not a legal option value, or nil.
local function bad_value(v, DELETE)
	if v == DELETE then return nil end
	local t = type(v)
	if t == "string" or t == "number" or t == "boolean" then return nil end
	if t == "table" then
		for _, e in ipairs(v) do
			local et = type(e)
			if et ~= "string" and et ~= "number" then return "list element is a " .. et end
		end
		return nil
	end
	return "a " .. t
end

-- Why the edit from `before` to `after` is not allowed, or nil.
local function bad_edit(before, after, DELETE, reserved)
	for k, v in pairs(after) do
		if type(k) ~= "string" or not k:match("^[%w_]+$") then
			return "option name " .. string.format("%q", tostring(k)) .. " is not [A-Za-z0-9_]+"
		end
		if not same(before[k], v) then
			if reserved[k] or k:sub(1, 7) == "openuf_" then
				return "option '" .. k .. "' is reserved to openUF"
			end
			local why = bad_value(v, DELETE)
			if why then return "option '" .. k .. "' is " .. why end
		end
	end
	return nil
end

-- The frozen helper subset a plugin may rely on, so it need not reach into
-- openUF's modules (which may move).
local function util_view()
	return {
		bit = util.bit, is_mac = util.is_mac, valid_ifname = util.valid_ifname,
		read_file = util.read_file,
		sha1 = function(s)
			local fti = package.loaded["openuf.ftinterop"]
				or (loadfile("ftinterop.lua") or loadfile("openuf/ftinterop.lua"))()
			return fti.sha1(s)
		end,
	}
end

-- The ctx one plugin sees. `env` comes from the caller (ucihelper, inform,
-- probe), each supplying what it has: DELETE, bssid, cursor, read_file,
-- exists, run, reload_network, store(name), repush(name).
local function context(p, env)
	env = env or {}
	local function exists(path)
		if env.exists then return env.exists(path) end
		local f = io.open(path, "r")
		if f then f:close() return true end
		return false
	end
	return {
		DELETE         = env.DELETE,
		bssid          = env.bssid,
		cursor         = env.cursor,
		read_file      = env.read_file or M._read_file,
		exists         = exists,
		run            = env.run,
		reload_network = env.reload_network,
		log            = function(msg) M._log(p.name .. ": " .. tostring(msg)) end,
		util           = util_view(),
		store          = env.store and env.store(p.name) or nil,
		repush         = env.repush and function() return env.repush(p.name) end or nil,
		name           = p.name,
	}
end

-- Run every enabled plugin's vap_options on `extra`, in place. Never raises.
function M.vap_options(extra, vap, cfg, env)
	local list = M.enabled(cfg)
	if #list == 0 then return extra end
	local view = copy(vap, env.DELETE)
	view.x_passphrase = nil
	for _, p in ipairs(list) do
		if p.mod.vap_options then
			local ctx = context(p, env)
			local work = copy(extra, env.DELETE)
			local ok, err = pcall(p.mod.vap_options, work, copy(view, env.DELETE), ctx)
			if ok then err = bad_edit(extra, work, env.DELETE, RESERVED) end
			if ok and not err then
				for k in pairs(extra) do extra[k] = nil end
				for k, v in pairs(work) do extra[k] = v end
			else
				M._log(string.format("%s: skipped for %s on %s: %s", p.name,
					tostring(vap.ssid), tostring(vap.radio), tostring(err)))
			end
		end
	end
	return extra
end

-- The same for one wifi-device: `extra` starts empty and holds what the
-- plugins want set on the radio (ucihelper writes it). `radio` is a copy of
-- the controller's radio row plus `name` (the UCI section).
function M.radio_options(extra, radio, cfg, env)
	local list = M.enabled(cfg)
	if #list == 0 then return extra end
	for _, p in ipairs(list) do
		if p.mod.radio_options then
			local ctx = context(p, env)
			local work = copy(extra, env.DELETE)
			local ok, err = pcall(p.mod.radio_options, work, copy(radio, env.DELETE), ctx)
			if ok then err = bad_edit(extra, work, env.DELETE, RESERVED_RADIO) end
			if ok and not err then
				for k in pairs(extra) do extra[k] = nil end
				for k, v in pairs(work) do extra[k] = v end
			else
				M._log(string.format("%s: skipped for radio %s: %s", p.name,
					tostring(radio.name), tostring(err)))
			end
		end
	end
	return extra
end

-- Run one optional hook of every enabled plugin that has it. Each call is
-- pcall'd and logged on failure; a tick over TICK_BUDGET is logged. Returns
-- {name = result} for the hooks that ran without raising.
function M.run_hook(hook, cfg, env, ...)
	local out = {}
	for _, p in ipairs(M.enabled(cfg)) do
		local fn = p.mod[hook]
		if type(fn) == "function" then
			local t0 = M._clock()
			local ok, res = pcall(fn, context(p, env), ...)
			if ok then
				out[p.name] = res == nil and true or res
			else
				M._log(string.format("%s: %s raised: %s", p.name, hook, tostring(res)))
			end
			if hook == "tick" then
				local took = M._clock() - t0
				if took > M.TICK_BUDGET then
					M._log(string.format("%s: tick took %.1f s (budget %d s)", p.name, took, M.TICK_BUDGET))
				end
			end
		end
	end
	return out
end

-- Everything the enabled plugins declare under `field` (packages, services,
-- nft_tables), each entry tagged with its plugin: {{plugin=, ...}, ...}.
function M.declared(cfg, field)
	local out = {}
	for _, p in ipairs(M.enabled(cfg)) do
		local v = p.mod[field]
		if type(v) == "table" then
			for _, e in ipairs(v) do
				if type(e) == "table" then
					local c = copy(e)
					c.plugin = p.name
					out[#out + 1] = c
				elseif type(e) == "string" then
					out[#out + 1] = {name = e, plugin = p.name}
				end
			end
		end
	end
	return out
end

-- For the UI: every plugin with its load state, and for the loaded ones
-- their declarations and what their status() says.
function M.status(cfg, env)
	local by = {}
	for _, p in ipairs(M.enabled(cfg)) do by[p.name] = p end
	local out = M.list(cfg)
	for _, row in ipairs(out) do
		local p = by[row.name]
		if p then
			row.api = p.mod.api
			row.hooks = {}
			for _, h in ipairs(HOOKS) do if p.mod[h] then row.hooks[#row.hooks + 1] = h end end
			row.packages = type(p.mod.packages) == "table" and copy(p.mod.packages) or nil
			row.services = type(p.mod.services) == "table" and copy(p.mod.services) or nil
			if type(p.mod.status) == "function" then
				local ok, st = pcall(p.mod.status, context(p, env))
				if ok and type(st) == "table" then row.status = st
				elseif not ok then row.status_error = tostring(st) end
			end
		end
	end
	return out
end

return M
