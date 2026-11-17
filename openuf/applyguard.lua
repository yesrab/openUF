--[[
	A config push that takes the AP off the air is undone.

	The controller pushes a `system_cfg`, openUF writes it into UCI and
	reloads WiFi and the network. Nothing checked afterwards: a push that
	left a radio down, or cut the AP off from the controller (a management
	VLAN, a mesh uplink, a static address), stayed in force until somebody
	reached the device another way. On a wireless child that is a ladder.

	With conf.lua `apply_rollback = true`:

	  1. Before a push writes anything, /etc/config/wireless, /etc/config/network
	     and state.json are copied to /etc/openuf/rollback/ (flash, on purpose:
	     the first thing a person does to an AP that stopped working is pull
	     its power, and the copy has to be there afterwards).
	  2. After the push, state.json carries `apply_guard`: when, which radios
	     were up before, and the cfgversion the push brought.
	  3. Every heartbeat until a verdict:
	       confirmed   an inform succeeded after the push AND every radio that
	                   was carrying a WLAN before it, is still enabled and has
	                   interfaces, is on the air again (hostapd serving at
	                   least one of its AP interfaces -- see radio_state). Not before SETTLE seconds: `wifi reload`
	                   lands asynchronously, and a radio that has not gone
	                   down yet looks exactly like one that came back.
	       rolled back neither happened within WINDOW seconds.
	  4. A rollback puts the three files back, reloads the network and WiFi,
	     and ends the daemon. procd starts it again, and the ordinary startup
	     path rebuilds every piece of kernel state from the restored files --
	     the one path that is already known to do that completely.

	After a rollback the device reports the cfgversion of the push it undid.
	That is deliberate and it is a lie the log, /tmp/openuf-status and
	`st.rollback` all own up to: reporting the old one makes the controller
	push the same configuration again, and a push that breaks the AP every
	four minutes is worse than one that was refused once. Change the setting
	on the controller (any change moves cfgversion) to have it tried again.

	What it does not cover: a daemon that hangs (no heartbeat, no verdict; the
	other project runs a detached timer for that), and state outside the three
	files -- the system package (timezone, NTP, syslog) is not network-critical
	and is left as pushed.

	The idea, and the rule that a radio the push disabled or emptied is not a
	casualty, are antoniocosta/unifi-openwrt's (GPL-2.0-or-later, internal/
	openwrt/apply.go, read 2026-11-17). Asking hostapd rather than netifd
	whether a radio is on the air, the controller-reachability half, the copy
	on flash, the resume after a restart and the rebuild-by-restart are this
	tree's. ⚠️ Run on the hwsim test VM only (2026-11-17: a radio pushed onto
	a channel its band does not have was detected and restored); never on
	AP1/AP2.
]]--

local M = {}
local util = package.loaded["openuf.util"]
	or assert(loadfile("util.lua") or loadfile("openuf/util.lua"))()

-- Injectable seams.
M._exec      = os.execute
M._popen     = util.popen
M._read_file = util.read_file
M._remove    = os.remove
M._write_file = function(path, content)
	local tmp = path .. ".tmp"
	local f = io.open(tmp, "w")
	if not f then return false end
	local wrote = f:write(content)
	local closed = f:close()
	if not (wrote and closed) then os.remove(tmp); return false end
	local ok = os.rename(tmp, path)
	if not ok then os.remove(tmp) end
	return ok and true or false
end
M._decode = function(s)
	local ok, cjson = pcall(require, "cjson")
	if not ok then return nil end
	local ok2, t = pcall(cjson.decode, s)
	return ok2 and type(t) == "table" and t or nil
end

M.DIR        = "/etc/openuf/rollback"
M.CONFIG_DIR = "/etc/config"
M.PACKAGES   = {"wireless", "network"}
M.STATE_COPY = "state.json"

-- No verdict before this many seconds: the reload a push runs is asynchronous.
M.SETTLE = 20
-- No rollback before this many: a DFS channel's availability check alone is
-- 60 s (600 on the weather-radar channels, which is why a radio in CAC must
-- not be what decides -- see radio_state), and the controller may be a
-- moment in answering.
M.WINDOW = 240

-- ─── Radios ──────────────────────────────────────────────────────────────────

-- What each radio is doing, nil when it cannot be read (no ubus yet, no
-- wireless at all):
--   {radio = {up, disabled, interfaces, ap, live}}
-- `up` is netifd's word and it is not enough: on the test VM a radio given a
-- channel its band does not have stayed `up: true` with its interface listed
-- while hostapd had refused it ("hostapd.add_iface failed", 2026-11-17) --
-- the exact outage this module exists for, invisible to the rule the idea
-- came with. So an AP interface counts only when hostapd is serving it:
-- `ap` is how many AP-mode interfaces the radio has, `live` how many of
-- them have their hostapd object on ubus in a state other than DISABLED.
-- A channel availability check in progress (DFS) is alive, not down.
function M.radio_state()
	local t = M._decode(M._popen("ubus call network.wireless status 2>/dev/null") or "")
	if not t then return nil end
	local objs = {}
	for line in (M._popen("ubus list 'hostapd.*' 2>/dev/null") or ""):gmatch("[^\n]+") do
		local ifname = line:match("^hostapd%.(%S+)$")
		if ifname then objs[ifname] = true end
	end
	local out = {}
	for name, r in pairs(t) do
		if type(r) == "table" then
			local ifaces = type(r.interfaces) == "table" and r.interfaces or {}
			local ap, live = 0, 0
			for _, i in ipairs(ifaces) do
				local mode = type(i) == "table" and type(i.config) == "table" and i.config.mode
				if mode == "ap" then
					ap = ap + 1
					local ifname = i.ifname
					if type(ifname) == "string" and objs[ifname] and util.valid_ifname(ifname) then
						local st = M._decode(M._popen("ubus call hostapd." .. ifname
							.. " get_status 2>/dev/null") or "")
						if not (st and st.status == "DISABLED") then live = live + 1 end
					end
				end
			end
			out[name] = {up = r.up == true, disabled = r.disabled == true,
				interfaces = #ifaces, ap = ap, live = live}
		end
	end
	return out
end

-- Is this radio carrying what it is configured to carry? With AP interfaces:
-- at least one of them on the air. Without (a mesh or station radio, which
-- hostapd does not serve): netifd's `up`, the best there is.
local function carrying(r)
	if (r.ap or 0) > 0 then return (r.live or 0) > 0 end
	return r.up and r.interfaces > 0
end

-- The radios that are carrying something now.
function M.up_radios(state)
	local names = {}
	for name, r in pairs(state or {}) do
		if carrying(r) then names[#names + 1] = name end
	end
	table.sort(names)
	return names
end

-- Which of `before` (a list of names) is not back: still enabled, still has
-- interfaces, and not carrying them. A radio the push disabled, or left with
-- no WLAN, is not a casualty. An unreadable state names every radio: it
-- cannot be said they are up.
function M.radios_down(before, state)
	local down = {}
	for _, name in ipairs(before or {}) do
		local r = state and state[name]
		if state == nil then
			down[#down + 1] = name
		elseif r and not r.disabled and r.interfaces > 0 and not carrying(r) then
			down[#down + 1] = name
		end
	end
	return down
end

-- ─── The copy ────────────────────────────────────────────────────────────────

local function copy_path(name) return M.DIR .. "/" .. name end

-- Copy the two config packages and the state file aside. All or nothing: a
-- copy that is missing a file is removed, because restoring half of one
-- (the old wireless config under the new network config) is its own outage.
-- Returns true when a complete copy is in place.
function M.snapshot(state_file)
	M._exec("mkdir -p '" .. M.DIR .. "' 2>/dev/null")
	local files = {}
	for _, p in ipairs(M.PACKAGES) do
		files[#files + 1] = {from = M.CONFIG_DIR .. "/" .. p, to = copy_path(p)}
	end
	files[#files + 1] = {from = state_file, to = copy_path(M.STATE_COPY)}
	for _, f in ipairs(files) do
		local content = M._read_file(f.from)
		if content == nil or not M._write_file(f.to, content) then
			io.stderr:write("applyguard: cannot copy " .. tostring(f.from)
				.. " aside -- this push is not guarded\n")
			M.discard()
			return false
		end
	end
	return true
end

function M.have_snapshot()
	for _, p in ipairs(M.PACKAGES) do
		if M._read_file(copy_path(p)) == nil then return false end
	end
	return M._read_file(copy_path(M.STATE_COPY)) ~= nil
end

function M.discard()
	for _, p in ipairs(M.PACKAGES) do M._remove(copy_path(p)) end
	M._remove(copy_path(M.STATE_COPY))
end

-- ─── The verdict ─────────────────────────────────────────────────────────────

-- guard = {at, radios, cfgversion}; last_ok = epoch of the last inform the
-- controller answered; state = radio_state(). Returns
--   "pending"
--   "confirmed"
--   "rollback", reason
function M.verdict(guard, now, last_ok, state)
	local age = now - (guard.at or now)
	if age < M.SETTLE then return "pending" end
	local answered = (tonumber(last_ok) or 0) > (guard.at or 0)
	local down = M.radios_down(guard.radios, state)
	if answered and #down == 0 then return "confirmed" end
	if age < M.WINDOW then return "pending" end
	local why = {}
	if not answered then why[#why + 1] = "no answer from the controller since the push" end
	if #down > 0 then why[#why + 1] = "radio(s) not back up: " .. table.concat(down, " ") end
	return "rollback", table.concat(why, "; ")
end

-- ─── The rollback ────────────────────────────────────────────────────────────

-- Put the copies back. `patch_state(old_state_text)` returns the state file's
-- new contents (inform.lua stamps the undone push's cfgversion and the
-- rollback record into the old state there). Returns true when all three
-- files were written; the copies are kept until the caller discards them.
function M.restore(state_file, patch_state)
	if not M.have_snapshot() then
		io.stderr:write("applyguard: nothing to roll back to (" .. M.DIR .. " is incomplete)\n")
		return false
	end
	local ok = true
	for _, p in ipairs(M.PACKAGES) do
		if not M._write_file(M.CONFIG_DIR .. "/" .. p, M._read_file(copy_path(p))) then
			io.stderr:write("applyguard: cannot restore " .. M.CONFIG_DIR .. "/" .. p .. "\n")
			ok = false
		end
	end
	local old = M._read_file(copy_path(M.STATE_COPY))
	local new = patch_state and patch_state(old) or old
	if type(new) ~= "string" or not M._write_file(state_file, new) then
		io.stderr:write("applyguard: cannot restore " .. tostring(state_file) .. "\n")
		ok = false
	end
	return ok
end

-- The network first (bridges and VLAN devices the radios attach to), then a
-- full WiFi restart rather than a reload: the point is that nothing of the
-- undone push survives in a running hostapd.
function M.reload()
	M._exec("/etc/init.d/network reload >/dev/null 2>&1")
	M._exec("wifi >/dev/null 2>&1")
end

return M
