-- Tests for openuf/netconfig.lua (IP Settings: DHCP/Static network config).
-- Run from project root: lua tests/run_tests.lua

local netconfig = dofile("openuf/netconfig.lua")

local function with_capture(fn)
	local cmds = {}
	local orig = netconfig._exec
	netconfig._exec = function(cmd)
		cmds[#cmds + 1] = cmd
		return true
	end
	fn(cmds)
	netconfig._exec = orig
end

return {
	{
		name = "netconfig: netmask_to_prefix converts common netmasks",
		fn = function()
			assert_eq(netconfig.netmask_to_prefix("255.255.255.0"), 24, "/24")
			assert_eq(netconfig.netmask_to_prefix("255.255.255.128"), 25, "/25")
			assert_eq(netconfig.netmask_to_prefix("255.255.0.0"), 16, "/16")
			assert_eq(netconfig.netmask_to_prefix("255.255.255.255"), 32, "/32")
		end
	},
	{
		name = "netconfig: netmask_to_prefix defaults to 24 for nil/malformed input",
		fn = function()
			assert_eq(netconfig.netmask_to_prefix(nil), 24, "nil defaults to /24")
			assert_eq(netconfig.netmask_to_prefix("not-a-netmask"), 24, "malformed defaults to /24")
		end
	},
	{
		name = "netconfig: apply_static returns false without iface or ip",
		fn = function()
			assert_false(netconfig.apply_static(nil, "10.0.0.5", "255.255.255.0"), "no-op without iface")
			assert_false(netconfig.apply_static("eth0", nil, "255.255.255.0"), "no-op without ip")
			assert_false(netconfig.apply_static("eth0", "0.0.0.0", "255.255.255.0"), "no-op for 0.0.0.0")
		end
	},
	{
		name = "netconfig: apply_static flushes and adds the address with correct prefix",
		fn = function()
			with_capture(function(cmds)
				local ok = netconfig.apply_static("eth0", "172.19.0.50", "255.255.255.0", "172.19.0.1")
				assert_true(ok, "apply_static returns true")
				assert_eq(#cmds, 3, "three shell commands")
				assert_contains(cmds[1], "ip addr flush dev eth0", "flush existing address")
				assert_contains(cmds[2], "ip addr add 172.19.0.50/24 dev eth0", "add static address with /24")
				assert_contains(cmds[3], "ip route replace default via 172.19.0.1", "set default route")
			end)
		end
	},
	{
		name = "netconfig: apply_static skips the route command without a gateway",
		fn = function()
			with_capture(function(cmds)
				netconfig.apply_static("eth0", "172.19.0.50", "255.255.255.0", nil)
				assert_eq(#cmds, 2, "no route command without gateway")
			end)
		end
	},
	{
		name = "netconfig: apply_static skips the route command for gateway 0.0.0.0",
		fn = function()
			with_capture(function(cmds)
				netconfig.apply_static("eth0", "172.19.0.50", "255.255.255.0", "0.0.0.0")
				assert_eq(#cmds, 2, "no route command for 0.0.0.0 gateway")
			end)
		end
	},
	{
		name = "netconfig: apply_dhcp returns false without iface",
		fn = function()
			assert_false(netconfig.apply_dhcp(nil), "no-op without iface")
		end
	},
	{
		name = "netconfig: apply_dhcp flushes the address and invokes udhcpc",
		fn = function()
			with_capture(function(cmds)
				local ok = netconfig.apply_dhcp("eth0")
				assert_true(ok, "apply_dhcp returns true")
				assert_eq(#cmds, 2, "two shell commands")
				assert_contains(cmds[1], "ip addr flush dev eth0", "flush existing address")
				assert_contains(cmds[2], "udhcpc -i eth0", "invoke udhcpc on the right interface")
			end)
		end
	},
}
