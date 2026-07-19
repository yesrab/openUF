-- Tests for openuf/switchvlan.lua (per-port VLAN assignment, swconfig boards).
-- Run from project root: lua tests/run_tests.lua
--
-- In-memory mock UCI cursor, same shape as test_ucihelper.lua's plus the
-- cursor:get() switchvlan.lua needs for its no-op check.

local switchvlan = dofile("openuf/switchvlan.lua")

local function new_mock_uci()
	local db, order = {}, {}
	local cursor = {}

	function cursor:set(config, section, a, b)
		db[config] = db[config] or {}
		if not db[config][section] then
			db[config][section] = {[".name"] = section}
			order[config] = order[config] or {}
			order[config][#order[config] + 1] = section
		end
		if b == nil then db[config][section][".type"] = a
		else db[config][section][a] = b end
	end

	function cursor:get(config, section, key)
		local s = db[config] and db[config][section]
		return s and s[key]
	end

	function cursor:foreach(config, stype, fn)
		for _, name in ipairs(order[config] or {}) do
			local s = db[config][name]
			if s and s[".type"] == stype then fn(s) end
		end
	end

	function cursor:delete(config, section)
		if db[config] then db[config][section] = nil end
		for i, name in ipairs(order[config] or {}) do
			if name == section then table.remove(order[config], i) break end
		end
	end

	function cursor:commit() end

	return {mock = {cursor = function() return cursor end}, db = db, cursor = cursor}
end

-- A board with a real swconfig switch and a stock VLAN 1 section.
local function swconfig_board()
	local u = new_mock_uci()
	u.cursor:set("network", "sw0", "switch")
	u.cursor:set("network", "sw0", "name", "switch0")
	u.cursor:set("network", "stock_vlan1", "switch_vlan")
	u.cursor:set("network", "stock_vlan1", "vlan", "1")
	u.cursor:set("network", "stock_vlan1", "ports", "0t 1 2 3 4")
	return u
end

local CFG = {
	net  = {lan_vlanid = 1, ports = {
		{idx = 1, ifname = "eth0", uplink = true},
		{idx = 2, ifname = "eth1", swport = "lan1"},
	}},
	vlan = {cpu_lan = 0, cpu_wan = 6, ports = {lan1 = 1, lan2 = 2, lan3 = 3, lan4 = 4, wan = 5}},
}

-- Port 2 native VLAN 20, VLAN 1 excluded -- the live-captured C3 shape.
local function override()
	return {
		enabled = true,
		vlans   = {[1] = {mode = "untagged", enabled = true},
		           [20] = {mode = "tagged", enabled = true}},
		ports   = {[2] = {pvid = 20, vlans = {[1] = "exclude", [20] = "untagged"}}},
	}
end

local function with_capture(fn)
	local cmds = {}
	local orig = switchvlan._exec
	switchvlan._exec = function(c) cmds[#cmds + 1] = c return true end
	local ok, err = pcall(fn, cmds)
	switchvlan._exec = orig
	switchvlan._uci = nil
	if not ok then error(err, 0) end
end

local function silently(fn)
	local real = io.stderr
	io.stderr = {write = function() end}
	local ok, err = pcall(fn)
	io.stderr = real
	if not ok then error(err, 0) end
end

return {
	{
		name = "switchvlan: physical_port walks port_idx -> swport -> physical",
		fn = function()
			assert_eq(switchvlan.physical_port(CFG, 2), 1, "port_idx 2 is lan1, physical 1")
			assert_nil(switchvlan.physical_port(CFG, 1), "uplink port is never mappable")
			assert_nil(switchvlan.physical_port(CFG, 9), "unknown port_idx")
			assert_nil(switchvlan.physical_port({}, 2), "no dev.conf.vlan at all")
		end
	},
	{
		name = "switchvlan: build_ports renders swconfig membership syntax",
		fn = function()
			-- untagged -> bare number, tagged -> Nt, exclude -> omitted.
			-- The CPU port is always tagged in.
			assert_eq(switchvlan.build_ports(CFG, 20, {[2] = "untagged"}), "0t 1",
				"untagged member")
			assert_eq(switchvlan.build_ports(CFG, 20, {[2] = "tagged"}), "0t 1t",
				"tagged member")
			assert_nil(switchvlan.build_ports(CFG, 1, {[2] = "exclude"}),
				"a VLAN with only exclusions is not written at all")
		end
	},
	{
		name = "switchvlan: apply writes an openuf-prefixed section and reloads",
		fn = function()
			with_capture(function(cmds)
				local u = swconfig_board()
				switchvlan._uci = u.mock
				local st = {}
				assert_true(switchvlan.apply(override(), CFG, st), "apply reports a change")
				local sec = u.db.network.openuf_swvlan20
				assert_not_nil(sec, "openuf_swvlan20 section created")
				assert_eq(sec.vlan, "20", "VLAN id written")
				assert_eq(sec.ports, "0t 1", "port 2 (physical 1) untagged, CPU tagged")
				assert_eq(sec.device, "switch0", "bound to the switch device")
				assert_eq(#cmds, 1, "one reload")
				assert_contains(cmds[1], "/etc/init.d/network reload", "reload, not restart")
			end)
		end
	},
	{
		name = "switchvlan: apply is idempotent -- no second commit or reload",
		fn = function()
			-- Every steady-state setparam re-carries this block. Reloading the
			-- network on each one would bounce the uplink every inform.
			with_capture(function(cmds)
				local u = swconfig_board()
				switchvlan._uci = u.mock
				local st = {}
				switchvlan.apply(override(), CFG, st)
				assert_eq(#cmds, 1, "first apply reloads")
				assert_false(switchvlan.apply(override(), CFG, st), "second apply is a no-op")
				assert_eq(#cmds, 1, "no second reload")
			end)
		end
	},
	{
		name = "switchvlan: apply snapshots stock sections and restore puts them back",
		fn = function()
			with_capture(function()
				local u = swconfig_board()
				switchvlan._uci = u.mock
				local st = {}
				switchvlan.apply(override(), CFG, st)
				assert_eq(st.swvlan_backup["1"], "0t 1 2 3 4", "stock VLAN 1 snapshotted")

				assert_true(switchvlan.restore(st), "restore reports a change")
				assert_nil(u.db.network.openuf_swvlan20, "openUF's section removed")
				assert_eq(u.db.network.stock_vlan1.ports, "0t 1 2 3 4", "stock ports intact")
				assert_nil(st.swvlan_backup, "ledger cleared")
			end)
		end
	},
	{
		name = "switchvlan: apply refuses on a DSA board",
		fn = function()
			with_capture(function(cmds)
				local u = new_mock_uci()
				u.cursor:set("network", "br0v20", "bridge-vlan")
				switchvlan._uci = u.mock
				assert_eq(switchvlan.detect_backend(u.cursor), "dsa", "DSA detected")
				silently(function()
					assert_false(switchvlan.apply(override(), CFG, {}), "no apply on DSA")
				end)
				assert_eq(#cmds, 0, "no command issued -- bridge-vlan is unverifiable here")
			end)
		end
	},
	{
		name = "switchvlan: apply refuses without dev.conf.vlan",
		fn = function()
			with_capture(function(cmds)
				local u = swconfig_board()
				switchvlan._uci = u.mock
				silently(function()
					assert_false(switchvlan.apply(override(), {net = CFG.net}, {}),
						"a guessed switch port map would strand the device")
				end)
				assert_eq(#cmds, 0, "no command issued")
			end)
		end
	},
	{
		name = "switchvlan: apply skips ports with no swport rather than defaulting",
		fn = function()
			with_capture(function(cmds)
				local u = swconfig_board()
				switchvlan._uci = u.mock
				local cfg = {net = {lan_vlanid = 1, ports = {
					{idx = 2, ifname = "eth1"},   -- no swport
				}}, vlan = CFG.vlan}
				silently(function()
					assert_false(switchvlan.apply(override(), cfg, {}), "nothing applied")
				end)
				assert_eq(#cmds, 0, "an unmappable port is skipped, never guessed at")
			end)
		end
	},
	{
		name = "switchvlan: apply never touches the uplink port",
		fn = function()
			with_capture(function(cmds)
				local u = swconfig_board()
				switchvlan._uci = u.mock
				local sw = {
					enabled = true,
					vlans   = {[20] = {mode = "tagged", enabled = true}},
					-- port_idx 1 is the uplink -- reassigning its VLAN strands
					-- the device.
					ports   = {[1] = {pvid = 20, vlans = {[20] = "untagged"}}},
				}
				-- The uplink here is given a valid swport ON PURPOSE, so the
				-- ONLY thing that can reject it is the uplink guard. With the
				-- production modelmaps (which give uplinks no swport) this test
				-- would pass even with the guard deleted -- mutation-tested.
				local cfg = {net = {lan_vlanid = 1, ports = {
					{idx = 1, ifname = "eth0", uplink = true, swport = "wan"},
					{idx = 2, ifname = "eth1", swport = "lan1"},
				}}, vlan = CFG.vlan}
				silently(function()
					assert_false(switchvlan.apply(sw, cfg, {}), "uplink override ignored")
				end)
				assert_eq(#cmds, 0, "no command issued")
			end)
		end
	},
	{
		name = "switchvlan: apply is a no-op when gated off or absent",
		fn = function()
			with_capture(function(cmds)
				local u = swconfig_board()
				switchvlan._uci = u.mock
				assert_false(switchvlan.apply(nil, CFG, {}), "nil block")
				local off = override()
				off.enabled = false
				assert_false(switchvlan.apply(off, CFG, {}), "gated off")
				local bare = override()
				bare.ports = {}
				assert_false(switchvlan.apply(bare, CFG, {}), "gate on but no override")
				assert_eq(#cmds, 0, "no command in any case")
			end)
		end
	},
}
