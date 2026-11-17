-- Tests for openuf/applyguard.lua (rollback of a config push that broke the
-- AP) and its wiring in inform.lua.
-- Run from project root: lua tests/run_tests.lua

OPENUF_TEST_MODE = true
local guard  = dofile("openuf/applyguard.lua")
local inform = dofile("openuf/inform.lua")
local cjson  = require("cjson")

-- A file system in a table, and the status ubus would print.
local function fresh(files, status)
	local rec = {files = files or {}, cmds = {}, status = status}
	guard.DIR, guard.CONFIG_DIR = "/rb", "/cfg"
	guard._read_file  = function(p) return rec.files[p] end
	rec.private = {}
	guard._write_file = function(p, c, private)
		if rec.readonly and rec.readonly[p] then return false end
		rec.files[p] = c
		rec.private[p] = private and true or false
		return true
	end
	guard._remove = function(p) rec.files[p] = nil end
	guard._exec   = function(c) rec.cmds[#rec.cmds + 1] = c; return 0 end
	-- rec.status is `network.wireless status`; rec.hostapd maps an AP ifname
	-- to its get_status status (absent = no hostapd object on ubus).
	guard._popen  = function(cmd)
		if cmd:find("network.wireless status", 1, true) then
			return rec.status and cjson.encode(rec.status) or ""
		end
		local hostapd = rec.hostapd or {}
		if cmd:find("ubus list", 1, true) then
			local out = {}
			for ifname in pairs(hostapd) do out[#out + 1] = "hostapd." .. ifname end
			return table.concat(out, "\n") .. "\n"
		end
		local ifname = cmd:match("ubus call hostapd%.(%S+) get_status")
		if ifname and hostapd[ifname] then return cjson.encode({status = hostapd[ifname]}) end
		return ""
	end
	return rec
end

local function with_stderr(fn)
	local buf, real = {}, io.stderr
	io.stderr = {write = function(_, ...) for _, s in ipairs({...}) do buf[#buf + 1] = s end end}
	local ok, err = pcall(fn)
	io.stderr = real
	if not ok then error(err, 0) end
	return table.concat(buf)
end

-- Two radios with no AP interface (a mesh or station radio): netifd's `up`
-- is all there is to go by.
local UP   = {radio0 = {up = true,  disabled = false, interfaces = {{}, {}}},
              radio1 = {up = true,  disabled = false, interfaces = {{}}}}
local DOWN = {radio0 = {up = true,  disabled = false, interfaces = {{}, {}}},
              radio1 = {up = false, disabled = false, interfaces = {{}}}}
-- One radio with an AP interface, as netifd reports it whether or not
-- hostapd is serving it.
local AP_STATUS = {radio0 = {up = true, disabled = false,
	interfaces = {{ifname = "phy0-ap0", config = {mode = "ap"}}}}}

local function base_files()
	return {["/cfg/wireless"] = "W-old", ["/cfg/network"] = "N-old", ["/st.json"] = '{"cfgversion":"old","adopted":true}'}
end

return {
	-- ── radios ────────────────────────────────────────────────────────────
	{
		name = "applyguard: the radios held to account are those up with an interface",
		fn = function()
			fresh(nil, {radio0 = {up = true, interfaces = {{}}}, radio1 = {up = true, interfaces = {}},
				radio2 = {up = false, interfaces = {{}}}})
			local names = guard.up_radios(guard.radio_state())
			assert_eq(#names, 1, "one")
			assert_eq(names[1], "radio0", "up and carrying a WLAN")
		end
	},
	{
		name = "applyguard: a radio the push disabled or emptied is not a casualty; one that stayed down is",
		fn = function()
			local before = {"radio0", "radio1"}
			assert_eq(#guard.radios_down(before, {radio0 = {up = true, disabled = false, interfaces = 1},
				radio1 = {up = false, disabled = true, interfaces = 1}}), 0, "disabled by the push")
			assert_eq(#guard.radios_down(before, {radio0 = {up = true, disabled = false, interfaces = 1},
				radio1 = {up = false, disabled = false, interfaces = 0}}), 0, "left with no WLAN")
			local down = guard.radios_down(before, {radio0 = {up = true, disabled = false, interfaces = 1},
				radio1 = {up = false, disabled = false, interfaces = 1}})
			assert_eq(#down, 1, "one down")
			assert_eq(down[1], "radio1", "named")
			assert_eq(#guard.radios_down(before, nil), 2, "an unreadable status proves nothing is up")
		end
	},
	{
		-- The test VM, 2026-11-17: channel 209 on a 2.4 GHz radio. netifd kept
		-- saying up:true with the interface listed; hostapd had refused it.
		name = "applyguard: an AP radio is on the air only while hostapd serves it, whatever netifd says",
		fn = function()
			local rec = fresh(nil, AP_STATUS)
			rec.hostapd = {["phy0-ap0"] = "ENABLED"}
			local st = guard.radio_state()
			assert_eq(st.radio0.ap, 1, "one AP interface")
			assert_eq(st.radio0.live, 1, "served")
			assert_eq(#guard.radios_down({"radio0"}, st), 0, "on the air")
			rec.hostapd = {}                                   -- hostapd.add_iface failed
			st = guard.radio_state()
			assert_true(st.radio0.up, "netifd still says up")
			assert_eq(st.radio0.live, 0, "but nothing is served")
			assert_eq(guard.radios_down({"radio0"}, st)[1], "radio0", "down")
			assert_eq(#guard.up_radios(st), 0, "and not a radio to hold a later push to")
			rec.hostapd = {["phy0-ap0"] = "DISABLED"}          -- AP-DISABLED after a failed CAC
			assert_eq(guard.radios_down({"radio0"}, guard.radio_state())[1], "radio0", "DISABLED is down")
			rec.hostapd = {["phy0-ap0"] = "DFS"}               -- a CAC in progress
			assert_eq(#guard.radios_down({"radio0"}, guard.radio_state()), 0,
				"a channel check under way is not an outage")
		end
	},
	-- ── the verdict ───────────────────────────────────────────────────────
	{
		name = "applyguard: no verdict while the reload settles, however healthy things look",
		fn = function()
			fresh(nil, UP)
			local g = {at = 1000, radios = {"radio0", "radio1"}}
			assert_eq(guard.verdict(g, 1000 + guard.SETTLE - 1, 1005, guard.radio_state()), "pending",
				"a radio that has not gone down yet looks like one that came back")
		end
	},
	{
		name = "applyguard: confirmed needs BOTH an inform answered after the push and the radios back",
		fn = function()
			fresh(nil, UP)
			local g = {at = 1000, radios = {"radio0", "radio1"}}
			local t = 1000 + guard.SETTLE
			assert_eq(guard.verdict(g, t, 1010, guard.radio_state()), "confirmed", "both")
			assert_eq(guard.verdict(g, t, 990, guard.radio_state()), "pending",
				"an answer from BEFORE the push says nothing about it")
			fresh(nil, DOWN)
			assert_eq(guard.verdict(g, t, 1010, guard.radio_state()), "pending", "answered, a radio still down")
		end
	},
	{
		name = "applyguard: after the window it is a rollback, and the reason names what failed",
		fn = function()
			fresh(nil, DOWN)
			local g = {at = 1000, radios = {"radio0", "radio1"}}
			local late = 1000 + guard.WINDOW
			local v, why = guard.verdict(g, late, 1010, guard.radio_state())
			assert_eq(v, "rollback", "a radio never came back")
			assert_contains(why, "radio1", "which one")
			assert_true(why:find("controller", 1, true) == nil, "the controller answered: not blamed")
			fresh(nil, UP)
			v, why = guard.verdict(g, late, 0, guard.radio_state())
			assert_eq(v, "rollback", "radios up but cut off from the controller")
			assert_contains(why, "no answer from the controller", "said")
			assert_eq(guard.verdict(g, late - 1, 0, guard.radio_state()), "pending", "not one second early")
		end
	},
	-- ── the copy ──────────────────────────────────────────────────────────
	{
		name = "applyguard: snapshot copies wireless, network and the state file; restore puts them back",
		fn = function()
			local rec = fresh(base_files())
			assert_true(guard.snapshot("/st.json"), "copied")
			assert_true(guard.have_snapshot(), "complete")
			rec.files["/cfg/wireless"], rec.files["/cfg/network"] = "W-new", "N-new"
			rec.files["/st.json"] = '{"cfgversion":"new"}'
			assert_true(rec.private["/rb/state.json"], "the copy of the state (it holds the authkey) is closed to others")
			assert_false(rec.private["/rb/wireless"], "the config copies keep the config's own mode")
			assert_true(guard.restore("/st.json", function(old)
				rec.files["/st.json"] = old .. "+patched"
				return true
			end), "restored")
			assert_eq(rec.files["/cfg/wireless"], "W-old", "wireless")
			assert_eq(rec.files["/cfg/network"], "N-old", "network")
			assert_eq(rec.files["/st.json"], '{"cfgversion":"old","adopted":true}+patched',
				"the old state, as the caller wrote it")
			-- No writer: the copy goes back as it is, and privately.
			rec.files["/st.json"] = "junk"
			assert_true(guard.restore("/st.json"), "restored without a writer")
			assert_eq(rec.files["/st.json"], '{"cfgversion":"old","adopted":true}', "the copy itself")
			assert_true(rec.private["/st.json"], "written closed")
			-- A writer that fails is a failed restore.
			local out = with_stderr(function()
				assert_false(guard.restore("/st.json", function() return false end), "the writer said no")
			end)
			assert_contains(out, "cannot restore /st.json", "said")
			assert_true(guard.have_snapshot(), "the copy outlives the restore until discarded")
			guard.discard()
			assert_false(guard.have_snapshot(), "gone")
		end
	},
	{
		name = "applyguard: a copy that cannot be completed is removed, never left half",
		fn = function()
			local rec = fresh(base_files())
			rec.readonly = {["/rb/network"] = true}   -- a full overlay
			local out = with_stderr(function()
				assert_false(guard.snapshot("/st.json"), "not guarded")
			end)
			assert_contains(out, "not guarded", "said")
			assert_nil(rec.files["/rb/wireless"], "the half that was written is gone")
			assert_false(guard.have_snapshot(), "no copy")
		end
	},
	{
		name = "applyguard: restore with no complete copy changes nothing",
		fn = function()
			local rec = fresh(base_files())
			rec.files["/rb/wireless"] = "W-old"   -- only one of three
			local out = with_stderr(function()
				assert_false(guard.restore("/st.json"), "refused")
			end)
			assert_contains(out, "nothing to roll back to", "said")
			assert_eq(rec.files["/cfg/network"], "N-old", "untouched")
		end
	},
	{
		name = "applyguard: reload brings the network back before the radios",
		fn = function()
			local rec = fresh()
			guard.reload()
			assert_contains(rec.cmds[1], "/etc/init.d/network reload", "network first")
			assert_contains(rec.cmds[2], "wifi ", "then a full WiFi restart")
		end
	},
	-- ── inform.lua ────────────────────────────────────────────────────────
	{
		name = "inform: a push is guarded only with apply_rollback, and a guarded one records the radios that were up",
		fn = function()
			local rec = fresh(base_files(), UP)
			local o_ag, o_sf = inform._applyguard, inform._state._state_file
			inform._applyguard, inform._state._state_file = guard, "/st.json"
			local ok, err = pcall(function()
				assert_nil(inform._applyguard_begin({}, {config = {}}), "off by default")
				assert_false(guard.have_snapshot(), "and nothing copied")
				local radios = inform._applyguard_begin({}, {config = {apply_rollback = true}})
				assert_eq(table.concat(radios, " "), "radio0 radio1", "both radios were up")
				assert_eq(rec.files["/rb/wireless"], "W-old", "copied before anything is written")
			end)
			inform._applyguard, inform._state._state_file = o_ag, o_sf
			if not ok then error(err, 0) end
		end
	},
	{
		name = "inform: a second push while the first is undecided keeps the last confirmed copy",
		fn = function()
			local rec = fresh(base_files(), UP)
			local o_ag, o_sf = inform._applyguard, inform._state._state_file
			inform._applyguard, inform._state._state_file = guard, "/st.json"
			local ok, err = pcall(function()
				local cfg = {config = {apply_rollback = true}}
				local st = {}
				st.apply_guard = {at = 1, radios = inform._applyguard_begin(st, cfg)}
				rec.files["/cfg/wireless"] = "W-first-push"      -- written, not yet confirmed
				rec.status = DOWN                                 -- and it took a radio down
				local radios = inform._applyguard_begin(st, cfg)
				assert_eq(rec.files["/rb/wireless"], "W-old", "the copy is still the confirmed configuration")
				assert_eq(table.concat(radios, " "), "radio0 radio1", "and still held to the radios of before")
			end)
			inform._applyguard, inform._state._state_file = o_ag, o_sf
			if not ok then error(err, 0) end
		end
	},
	{
		name = "inform: a confirmed push drops the guard, the copy and an older rollback note",
		fn = function()
			local rec = fresh(base_files(), UP)
			local o = {inform._applyguard, inform._state._state_file, inform._time, inform._state.save,
				inform._status.last_ok, inform._exit}
			inform._applyguard, inform._state._state_file = guard, "/st.json"
			local saved, exited = 0, false
			inform._state.save = function() saved = saved + 1 end
			inform._exit = function() exited = true end
			inform._time = function() return 1000 + guard.SETTLE end
			inform._status.last_ok = 1010
			local out
			local ok, err = pcall(function()
				guard.snapshot("/st.json")
				local st = {cfgversion = "new", apply_guard = {at = 1000, radios = {"radio0", "radio1"}},
					rollback = {at = 5, cfgversion = "older", reason = "x"}}
				out = with_stderr(function()
					assert_eq(inform._applyguard_tick(st, {config = {apply_rollback = true}}), "confirmed", "verdict")
				end)
				assert_nil(st.apply_guard, "guard gone")
				assert_nil(st.rollback, "an older rollback is history once a push works")
				assert_false(guard.have_snapshot(), "copy removed")
				assert_eq(saved, 1, "saved")
				assert_false(exited, "the daemon carries on")
				assert_eq(rec.files["/cfg/wireless"], "W-old", "nothing restored")
			end)
			inform._applyguard, inform._state._state_file, inform._time, inform._state.save,
				inform._status.last_ok, inform._exit = o[1], o[2], o[3], o[4], o[5], o[6]
			if not ok then error(err, 0) end
			assert_contains(out, "config push confirmed", "said")
		end
	},
	{
		name = "inform: a push that leaves a radio down is rolled back: files restored, cfgversion kept, daemon restarted",
		fn = function()
			local rec = fresh(base_files(), UP)
			local o = {inform._applyguard, inform._state._state_file, inform._time, inform._state.save,
				inform._status.last_ok, inform._exit, inform._write_status}
			inform._applyguard, inform._state._state_file = guard, "/st.json"
			local exited, status
			-- The restored state goes through state.save (mode and group kept).
			inform._state.save = function(t) rec.files["/st.json"] = cjson.encode(t) end
			inform._exit = function(code) exited = code end
			inform._write_status = function(_, f) status = f end
			inform._time = function() return 1000 + guard.WINDOW end
			inform._status.last_ok = 1010
			local out
			local ok, err = pcall(function()
				guard.snapshot("/st.json")
				rec.files["/cfg/wireless"], rec.files["/cfg/network"] = "W-new", "N-new"
				rec.files["/st.json"] = '{"cfgversion":"new","adopted":true}'
				rec.status = DOWN
				local st = {cfgversion = "new", adopted = true,
					apply_guard = {at = 1000, radios = {"radio0", "radio1"}}}
				out = with_stderr(function()
					inform._applyguard_tick(st, {config = {apply_rollback = true}})
				end)
				assert_eq(rec.files["/cfg/wireless"], "W-old", "wireless restored")
				assert_eq(rec.files["/cfg/network"], "N-old", "network restored")
				local back = cjson.decode(rec.files["/st.json"])
				assert_true(back.adopted, "the old state")
				assert_eq(back.cfgversion, "new", "but reporting the undone push's version: no re-push loop")
				assert_nil(back.apply_guard, "no guard carried over")
				assert_eq(back.rollback.cfgversion, "new", "the rollback is on record")
				assert_contains(back.rollback.reason, "radio1", "with its reason")
				assert_contains(rec.cmds[#rec.cmds - 1], "network reload", "network reloaded")
				assert_contains(rec.cmds[#rec.cmds], "wifi ", "WiFi restarted")
				assert_false(guard.have_snapshot(), "copy used up")
				assert_eq(exited, 1, "the daemon ends, for procd to start it on the restored files")
				assert_eq(status.rollback, 1000 + guard.WINDOW, "and the status file says so")
			end)
			inform._applyguard, inform._state._state_file, inform._time, inform._state.save,
				inform._status.last_ok, inform._exit, inform._write_status =
				o[1], o[2], o[3], o[4], o[5], o[6], o[7]
			if not ok then error(err, 0) end
			assert_contains(out, "ROLLING BACK", "loud")
			assert_contains(out, "change the setting on the controller to retry", "and says how to try again")
		end
	},
	{
		name = "inform: turning apply_rollback off lets an undecided push stand and removes the copy",
		fn = function()
			fresh(base_files(), DOWN)
			local o = {inform._applyguard, inform._state._state_file, inform._state.save, inform._exit}
			inform._applyguard, inform._state._state_file = guard, "/st.json"
			local exited = false
			inform._state.save = function() end
			inform._exit = function() exited = true end
			local ok, err = pcall(function()
				guard.snapshot("/st.json")
				local st = {apply_guard = {at = 0, radios = {"radio0", "radio1"}}}
				assert_nil(inform._applyguard_tick(st, {config = {}}), "no verdict")
				assert_nil(st.apply_guard, "guard dropped")
				assert_false(guard.have_snapshot(), "copy removed")
				assert_false(exited, "no rollback")
			end)
			inform._applyguard, inform._state._state_file, inform._state.save, inform._exit = o[1], o[2], o[3], o[4]
			if not ok then error(err, 0) end
		end
	},
	{
		name = "inform: forgetting the controller discards a pending rollback copy",
		fn = function()
			fresh(base_files(), UP)
			local o_ag, o_rl = inform._applyguard, inform._remotelog
			inform._applyguard = guard
			inform._remotelog = {sync = function() end}
			local ok, err = pcall(function()
				guard.snapshot("/st.json")
				with_stderr(function() inform._forget_controller({}, {}) end)
				assert_false(guard.have_snapshot(), "nothing of that controller's is waiting any more")
			end)
			inform._applyguard, inform._remotelog = o_ag, o_rl
			if not ok then error(err, 0) end
		end
	},
}
