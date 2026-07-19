-- Tests for openuf/lldp.lua (lldpctl JSON parsing).
-- Run from project root: lua tests/run_tests.lua

local lldp = dofile("openuf/lldp.lua")

local function fixture(name)
	local f = io.open("tests/fixtures/" .. name, "r")
	if not f then error("fixture not found: " .. name) end
	local s = f:read("*a"); f:close()
	return s
end

local function with_cmd(output_or_fn, fn)
	local orig = lldp._run_cmd
	lldp._run_cmd = type(output_or_fn) == "function"
		and output_or_fn
		or function() return output_or_fn end
	local ok, err = pcall(fn)
	lldp._run_cmd = orig
	if not ok then error(err, 2) end
end

return {
	{
		name = "lldp: neighbors() parses fixture JSON and returns one neighbor",
		fn = function()
			with_cmd(fixture("lldpctl_output.json"), function()
				local nbrs = lldp.neighbors()
				assert_eq(#nbrs, 1, "one neighbor")
				assert_eq(nbrs[1].chassis_id,  "aa:bb:cc:dd:ee:01",             "chassis_id")
				assert_eq(nbrs[1].system_name, "switch01",                       "system_name")
				assert_eq(nbrs[1].port_id,     "GigabitEthernet0/1",             "port_id")
				assert_eq(nbrs[1].port,        "eth0",                           "local port")
				assert_contains(nbrs[1].system_desc, "UniFi Switch",             "system_desc")
				assert_eq(nbrs[1].port_descr,  "Uplink port",                    "port_descr")
			end)
		end
	},
	{
		name = "lldp: neighbors() reads local_port_idx from /sys/class/net/<port>/ifindex",
		fn = function()
			local orig_read = lldp._read_file
			lldp._read_file = function(path)
				if path == "/sys/class/net/eth0/ifindex" then return "3\n" end
				return nil
			end
			with_cmd(fixture("lldpctl_output.json"), function()
				local nbrs = lldp.neighbors()
				assert_eq(nbrs[1].local_port_idx, 3, "local_port_idx from sysfs")
			end)
			lldp._read_file = orig_read
		end
	},
	{
		name = "lldp: neighbors() local_port_idx is nil when sysfs is unavailable",
		fn = function()
			-- Explicitly mock sysfs as absent rather than relying on the
			-- ambient environment actually lacking it: real Linux CI
			-- runners/containers always have a genuine eth0 with a real
			-- /sys/class/net/eth0/ifindex, so this only ever passed by
			-- accident on a /sys-less macOS dev machine.
			local orig_read = lldp._read_file
			lldp._read_file = function() return nil end
			with_cmd(fixture("lldpctl_output.json"), function()
				local nbrs = lldp.neighbors()
				assert_true(nbrs[1].local_port_idx == nil, "nil without /sys access")
			end)
			lldp._read_file = orig_read
		end
	},
	{
		name = "lldp: neighbors() returns {} for empty output",
		fn = function()
			with_cmd("", function()
				assert_eq(#lldp.neighbors(), 0, "empty result")
			end)
		end
	},
	{
		name = "lldp: neighbors() returns {} for malformed JSON",
		fn = function()
			with_cmd("{this is not valid json!!!}", function()
				assert_eq(#lldp.neighbors(), 0, "empty on bad JSON")
			end)
		end
	},
	{
		name = "lldp: neighbors() returns {} when lldp key is absent",
		fn = function()
			with_cmd('{"something_else": {}}', function()
				assert_eq(#lldp.neighbors(), 0, "empty when no lldp key")
			end)
		end
	},
	{
		name = "lldp: neighbor capabilities list is parsed",
		fn = function()
			with_cmd(fixture("lldpctl_output.json"), function()
				local nbrs = lldp.neighbors()
				assert_true(#nbrs[1].capabilities >= 1, "at least one capability")
				-- The fixture has Bridge enabled and Router disabled -- the
				-- `if cap.enabled` filter must include one and EXCLUDE the
				-- other, or a regression emitting disabled caps passes.
				local has_bridge, has_router = false, false
				for _, cap in ipairs(nbrs[1].capabilities) do
					if cap == "Bridge" then has_bridge = true end
					if cap == "Router" then has_router = true end
				end
				assert_true(has_bridge, "enabled Bridge capability present")
				assert_false(has_router, "disabled Router capability excluded")
			end)
		end
	},
}
