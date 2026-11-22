-- Tests for openuf/netconfig.lua (IP Settings: DHCP/Static network config).
-- Run from project root: lua tests/run_tests.lua

local netconfig = dofile("openuf/netconfig.lua")
-- No test reads the host's own interfaces: a port with no master by default.
netconfig._read = function() return "" end

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

-- Runs fn(cmds) with eth0 a port of `master` (nil: no master).
local function with_master(master, fn)
	local o_read = netconfig._read
	netconfig._read = function(cmd)
		if cmd == "readlink /sys/class/net/eth0/master 2>/dev/null" and master then
			return "../../../virtual/net/" .. master .. "\n"
		end
		return ""
	end
	local ok, err = pcall(with_capture, fn)
	netconfig._read = o_read
	if not ok then error(err, 0) end
end

local RELOAD = "/etc/init.d/network reload 2>/dev/null"

-- A fake libuci for one `network` config: get() returns the section type
-- when no option is asked, and (nil, "Entry not found") on a miss, as libuci.
local function fake_uci(sections)
	local u = {db = {network = sections}, commits = 0}
	local c = {}
	function c:get(cfg, sec, opt)
		local s = u.db[cfg] and u.db[cfg][sec]
		if not s then return nil, "Entry not found" end
		if opt == nil then return s[".type"] end
		if s[opt] == nil then return nil, "Entry not found" end
		return s[opt]
	end
	function c:set(cfg, sec, opt, val) u.db[cfg][sec][opt] = val return true end
	function c:delete(cfg, sec, opt) u.db[cfg][sec][opt] = nil return true end
	function c:commit() u.commits = u.commits + 1 return true end
	u.mock = {cursor = function() return c end}
	return u
end

-- Runs fn(u, cmds) with the fake UCI and a command capture; stderr muted.
local function with_uci(sections, fn)
	local u = fake_uci(sections)
	local o_uci, o_err = netconfig._uci, io.stderr
	netconfig._uci = u.mock
	io.stderr = {write = function() end}
	local ok, err = pcall(with_capture, function(cmds) fn(u, cmds) end)
	netconfig._uci, io.stderr = o_uci, o_err
	if not ok then error(err, 0) end
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
		name = "netconfig: apply_dns writes nameservers in controller order",
		fn = function()
			with_capture(function(cmds)
				local ok = netconfig.apply_dns({"192.168.1.1", "8.8.8.8"})
				assert_true(ok, "apply_dns returns true")
				assert_eq(#cmds, 1, "one shell command")
				assert_contains(cmds[1], "'nameserver 192.168.1.1' 'nameserver 8.8.8.8'",
					"both servers, primary first")
				assert_contains(cmds[1], "> /etc/resolv.conf", "writes resolv.conf")
			end)
		end
	},
	{
		name = "netconfig: apply_dns is a no-op for nil/empty input",
		fn = function()
			with_capture(function(cmds)
				-- The controller omitting nameservers must never blank out
				-- working resolution.
				assert_false(netconfig.apply_dns(nil), "nil is a no-op")
				assert_false(netconfig.apply_dns({}), "empty list is a no-op")
				assert_eq(#cmds, 0, "no shell command issued")
			end)
		end
	},
	{
		name = "netconfig: apply_dns drops non-IPv4 entries rather than shelling them out",
		fn = function()
			with_capture(function(cmds)
				-- These values come straight off the wire and are interpolated
				-- into a shell command, so they must never reach it.
				assert_false(netconfig.apply_dns({"'; touch /tmp/pwned; '"}),
					"injection attempt rejected")
				assert_false(netconfig.apply_dns({"999.1.1.1"}), "out-of-range octet rejected")
				assert_false(netconfig.apply_dns({"not-an-ip"}), "garbage rejected")
				assert_eq(#cmds, 0, "no shell command issued")

				netconfig.apply_dns({"192.168.1.1", "nope"})
				assert_eq(#cmds, 1, "valid entry still applied")
				assert_contains(cmds[1], "'nameserver 192.168.1.1'", "valid server kept")
				assert_nil(cmds[1]:find("nope", 1, true), "invalid server dropped")
			end)
		end
	},
	{
		name = "netconfig: apply_static applies DNS alongside the address",
		fn = function()
			with_capture(function(cmds)
				netconfig.apply_static("eth0", "172.19.0.50", "255.255.255.0",
					"172.19.0.1", {"172.19.0.1"})
				assert_eq(#cmds, 4, "flush, add, route, resolv.conf")
				assert_contains(cmds[4], "'nameserver 172.19.0.1'", "DNS written last")
			end)
		end
	},
	{
		name = "netconfig: apply_static without DNS leaves resolv.conf alone",
		fn = function()
			with_capture(function(cmds)
				netconfig.apply_static("eth0", "172.19.0.50", "255.255.255.0", "172.19.0.1")
				assert_eq(#cmds, 3, "no resolv.conf write without DNS servers")
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
	{
		name = "netconfig: apply_static refuses a malformed address or gateway without running anything",
		fn = function()
			-- ip and gateway are spliced into command lines. Refused whole,
			-- not half-applied: an address with no route is not what was asked.
			with_capture(function(cmds)
				assert_false(netconfig.apply_static("eth0", "10.0.0.5; reboot", "255.255.255.0"),
					"shell metacharacters in the address")
				assert_false(netconfig.apply_static("eth0", "10.0.0.5", "255.255.255.0", "$(reboot)"),
					"shell metacharacters in the gateway")
				assert_false(netconfig.apply_static("eth0", "300.1.1.1", "255.255.255.0"),
					"an octet out of range")
				assert_eq(#cmds, 0, "nothing was run")
				assert_true(netconfig.apply_static("eth0", "10.0.0.5", "255.255.255.0", "10.0.0.1"),
					"a well-formed push still applies")
				assert_eq(#cmds, 3, "flush, add, route")
			end)
		end
	},
	{
		name = "netconfig: is_ipv4 is exported for the parser's own refusal",
		fn = function()
			assert_true(netconfig.is_ipv4("10.0.0.1"), "dotted quad")
			assert_false(netconfig.is_ipv4("10.0.0"), "three octets")
			assert_false(netconfig.is_ipv4("10.0.0.1 "), "trailing space")
			assert_false(netconfig.is_ipv4(nil), "nil")
		end
	},
	{
		name = "netconfig: snapshot reads addresses, default route and DNS; restore puts them back",
		fn = function()
			local tmp = os.tmpname()
			local f = assert(io.open(tmp, "w"))
			f:write("# x\nnameserver 192.0.2.53\nnameserver bad\n")
			f:close()
			local o_read, o_exec, o_rc = netconfig._read, netconfig._exec, netconfig.RESOLV_CONF
			local cmds = {}
			netconfig.RESOLV_CONF = tmp
			netconfig._read = function(cmd)
				if cmd:find("addr show", 1, true) then
					return "2: br0    inet 192.0.2.10/24 brd 192.0.2.255 scope global br0\n"
						.. "2: br0    inet 198.51.100.7/16 scope global br0\n"
				end
				return "default via 192.0.2.1 dev br0 proto static\n"
			end
			netconfig._exec = function(c) cmds[#cmds + 1] = c return true end
			local ok, err = pcall(function()
				local s = netconfig.snapshot("br0")
				assert_eq(table.concat(s.addrs, " "), "192.0.2.10/24 198.51.100.7/16", "both addresses")
				assert_eq(s.gw, "192.0.2.1", "gateway")
				assert_eq(table.concat(s.dns, " "), "192.0.2.53", "valid nameservers only")
				assert_true(netconfig.restore("br0", s), "restored")
				assert_eq(cmds[1], "ip -4 addr flush dev br0 2>/dev/null", "flush first")
				assert_eq(cmds[2], "ip addr add 192.0.2.10/24 dev br0 2>/dev/null", "first address")
				assert_eq(cmds[3], "ip addr add 198.51.100.7/16 dev br0 2>/dev/null", "second")
				assert_eq(cmds[4], "ip route replace default via 192.0.2.1 2>/dev/null", "route")
				assert_contains(cmds[5], "nameserver 192.0.2.53", "dns")
				cmds = {}
				assert_false(netconfig.restore("br0", {addrs = {"192.0.2.4/24; reboot",
					"300.1.1.1/24", "192.0.2.4/40", 7}, gw = "x; y", dns = "z"}), "all bad: refused")
				assert_eq(#cmds, 0, "and no flush, the port keeps what it has")
				assert_true(netconfig.restore("br0", {addrs = {"192.0.2.4/24", "x; reboot"},
					gw = "x; y", dns = "z"}), "a bad entry next to a good one")
				assert_eq(#cmds, 2, "flush and the good address only")
				cmds = {}
				assert_true(netconfig.restore("br0", {addrs = {}}), "port had no address")
				assert_eq(#cmds, 1, "flush only: back to nothing")
				assert_false(netconfig.restore(nil, s), "no iface")
				assert_false(netconfig.restore("br0", {addrs = "x"}), "malformed record")
				assert_eq(netconfig.snapshot(nil), nil, "no iface, no snapshot")
			end)
			netconfig._read, netconfig._exec, netconfig.RESOLV_CONF = o_read, o_exec, o_rc
			os.remove(tmp)
			if not ok then error(err, 0) end
		end
	},
	{
		name = "netconfig: a bad interface name reaches no command line",
		fn = function()
			with_capture(function(cmds)
				assert_eq(netconfig.apply_static("br0;reboot", "10.0.0.2", "255.255.255.0", nil), false, "static")
				assert_eq(netconfig.apply_dhcp("-br0"), false, "dhcp")
				assert_eq(netconfig.restore("a b", {addrs = {}}), false, "restore")
				assert_eq(#cmds, 0, "nothing was run")
			end)
		end
	},
	{
		name = "netconfig: uci apply_static writes the lan interface and reloads once",
		fn = function()
			with_uci({lan = {[".type"] = "interface", proto = "dhcp"}}, function(u, cmds)
				assert_true(netconfig.apply_static("br-lan", "192.0.2.10", "255.255.255.0",
					"192.0.2.1", {"192.0.2.53", "bad"}, "lan"), "applied")
				local lan = u.db.network.lan
				assert_eq(lan.proto, "static", "proto")
				assert_eq(lan.ipaddr, "192.0.2.10", "ipaddr")
				assert_eq(lan.netmask, "255.255.255.0", "netmask")
				assert_eq(lan.gateway, "192.0.2.1", "gateway")
				assert_eq(table.concat(lan.dns, " "), "192.0.2.53", "valid dns only")
				assert_eq(u.commits, 1, "one commit")
				assert_eq(#cmds, 1, "one command")
				assert_eq(cmds[1], RELOAD, "the reload, no ip addr, no resolv.conf")
			end)
		end
	},
	{
		name = "netconfig: uci same values again: no commit, no reload",
		fn = function()
			with_uci({lan = {[".type"] = "interface", proto = "dhcp"}}, function(u, cmds)
				for _ = 1, 2 do
					assert_true(netconfig.apply_static("br-lan", "192.0.2.10", "255.255.255.0",
						"192.0.2.1", {"192.0.2.53"}, "lan"), "applied")
				end
				assert_eq(u.commits, 1, "second call commits nothing")
				assert_eq(#cmds, 1, "and reloads nothing")
			end)
		end
	},
	{
		name = "netconfig: uci static defaults the netmask and deletes an empty gateway and dns",
		fn = function()
			with_uci({lan = {[".type"] = "interface", proto = "static", ipaddr = "192.0.2.9",
					gateway = "192.0.2.1", dns = {"192.0.2.53"}}}, function(u)
				assert_true(netconfig.apply_static("br-lan", "192.0.2.10", nil, "0.0.0.0",
					{"bad"}, "lan"), "applied")
				local lan = u.db.network.lan
				assert_eq(lan.netmask, "255.255.255.0", "default netmask")
				assert_nil(lan.gateway, "gateway 0.0.0.0 deleted")
				assert_nil(lan.dns, "no valid dns: deleted, not an empty list")
			end)
		end
	},
	{
		name = "netconfig: uci apply_dhcp sets proto dhcp and drops the address options",
		fn = function()
			with_uci({lan = {[".type"] = "interface", proto = "static", ipaddr = "192.0.2.10",
					netmask = "255.255.255.0", gateway = "192.0.2.1", dns = {"192.0.2.53"}}},
					function(u, cmds)
				assert_true(netconfig.apply_dhcp("br-lan", "lan"), "applied")
				local lan = u.db.network.lan
				assert_eq(lan.proto, "dhcp", "proto")
				assert_nil(lan.ipaddr, "ipaddr")
				assert_nil(lan.netmask, "netmask")
				assert_nil(lan.gateway, "gateway")
				assert_nil(lan.dns, "dns")
				assert_eq(u.commits, 1, "one commit")
				assert_eq(#cmds, 1, "no udhcpc, no ip addr")
				assert_eq(cmds[1], RELOAD, "the reload")
			end)
		end
	},
	{
		name = "netconfig: uci falls back to ip addr when the section is not an interface",
		fn = function()
			for _, name in ipairs({"wan6", "lan;x", "brdev"}) do
				with_uci({brdev = {[".type"] = "device", name = "br-lan"}}, function(u, cmds)
					assert_true(netconfig.apply_static("br-lan", "192.0.2.10", "255.255.255.0",
						nil, nil, name), name .. ": applied")
					assert_eq(cmds[1], "ip addr flush dev br-lan 2>/dev/null", name .. ": flush")
					assert_eq(cmds[2], "ip addr add 192.0.2.10/24 dev br-lan 2>/dev/null", name .. ": add")
					assert_eq(u.commits, 0, name .. ": no uci write")
				end)
			end
		end
	},
	{
		name = "netconfig: uci snapshot captures the section, list ipaddr too",
		fn = function()
			with_uci({lan = {[".type"] = "interface", proto = "static",
					ipaddr = {"192.0.2.10/24"}, dns = {"192.0.2.53"}}}, function()
				local o_read = netconfig._read
				netconfig._read = function() return "" end
				local s = netconfig.snapshot("br-lan", "lan")
				local s2 = netconfig.snapshot("br-lan")
				netconfig._read = o_read
				assert_eq(s.uci.proto, "static", "proto")
				assert_eq(s.uci.ipaddr[1], "192.0.2.10/24", "list ipaddr kept")
				assert_eq(s.uci.dns[1], "192.0.2.53", "dns")
				assert_nil(s.uci.netmask, "absent stays absent")
				assert_nil(s2.uci, "no ifname: no uci part")
			end)
		end
	},
	{
		name = "netconfig: uci restore writes the snapshot back exactly",
		fn = function()
			with_uci({lan = {[".type"] = "interface", proto = "static", ipaddr = "192.0.2.10",
					netmask = "255.255.255.0"}}, function(u, cmds)
				assert_true(netconfig.restore("br-lan", {addrs = {}, uci = {proto = "dhcp"}}, "lan"),
					"restored")
				local lan = u.db.network.lan
				assert_eq(lan.proto, "dhcp", "proto back")
				assert_nil(lan.ipaddr, "ipaddr gone")
				assert_nil(lan.netmask, "netmask gone")
				assert_eq(#cmds, 1, "no ip addr")
				assert_eq(cmds[1], RELOAD, "the reload")
				assert_true(netconfig.restore("br-lan", {addrs = {},
					uci = {proto = "static", ipaddr = {"192.0.2.10/24"}}}, "lan"), "list form")
				assert_eq(type(lan.ipaddr), "table", "written as a list")
				assert_eq(lan.ipaddr[1], "192.0.2.10/24", "same entry")
			end)
		end
	},
	{
		name = "netconfig: uci restore refuses a bad record",
		fn = function()
			for i, bad in ipairs({{proto = "static; reboot"}, {proto = "static", ipaddr = "x; y"},
					{proto = "static", dns = {"192.0.2.53", "x"}}, {proto = "static", gateway = 7},
					{ipaddr = "192.0.2.10"}}) do
				with_uci({lan = {[".type"] = "interface", proto = "dhcp"}}, function(u, cmds)
					assert_false(netconfig.restore("br-lan", {addrs = {}, uci = bad}, "lan"),
						"record " .. i .. " refused")
					assert_eq(u.db.network.lan.proto, "dhcp", "record " .. i .. ": untouched")
					assert_eq(u.commits, 0, "record " .. i .. ": no commit")
					assert_eq(#cmds, 0, "record " .. i .. ": no command")
				end)
			end
		end
	},
	{
		name = "netconfig: uci restore without snap.uci uses the kernel path",
		fn = function()
			with_uci({lan = {[".type"] = "interface", proto = "dhcp"}}, function(u, cmds)
				assert_true(netconfig.restore("br0", {addrs = {"192.0.2.10/24"}}, "lan"), "restored")
				assert_eq(cmds[1], "ip -4 addr flush dev br0 2>/dev/null", "kernel flush")
				assert_eq(u.commits, 0, "no uci write")
			end)
		end
	},
	{
		-- libuci hands a plain option back as a string, a list as a table.
		name = "netconfig: uci a plain option equal to the pushed list is no change",
		fn = function()
			with_uci({lan = {[".type"] = "interface", proto = "static", ipaddr = "192.0.2.10",
					netmask = "255.255.255.0", gateway = "192.0.2.1", dns = "192.0.2.53"}},
					function(u, cmds)
				assert_true(netconfig.apply_static("br-lan", "192.0.2.10", "255.255.255.0",
					"192.0.2.1", {"192.0.2.53"}, "lan"), "applied")
				assert_eq(u.commits, 0, "no commit")
				assert_eq(#cmds, 0, "no reload")
			end)
		end
	},
	{
		name = "netconfig: uci restore takes a space-separated dns option",
		fn = function()
			with_uci({lan = {[".type"] = "interface", proto = "dhcp"}}, function(u)
				assert_true(netconfig.restore("br-lan", {addrs = {}, uci = {proto = "static",
					ipaddr = "192.0.2.10", netmask = "255.255.255.0",
					dns = "192.0.2.53 192.0.2.54"}}, "lan"), "restored")
				assert_eq(u.db.network.lan.dns, "192.0.2.53 192.0.2.54", "written back as it was")
				assert_false(netconfig.restore("br-lan", {addrs = {}, uci = {proto = "static",
					dns = "192.0.2.53 x;y"}}, "lan"), "a bad word still refused")
			end)
		end
	},
	{
		name = "netconfig: uci a failed commit is a failure and reloads nothing",
		fn = function()
			with_uci({lan = {[".type"] = "interface", proto = "dhcp"}}, function(u, cmds)
				u.mock.cursor().commit = function() return nil, "I/O error" end
				assert_false(netconfig.apply_static("br-lan", "192.0.2.10", "255.255.255.0",
					nil, nil, "lan"), "not applied")
				assert_eq(#cmds, 0, "no reload")
			end)
		end
	},
	{
		name = "netconfig: uci a cursor that throws falls back to ip addr",
		fn = function()
			with_uci({}, function(_, cmds)
				netconfig._uci = {cursor = function() error("libuci broke") end}
				assert_true(netconfig.apply_static("br-lan", "192.0.2.10", "255.255.255.0",
					nil, nil, "lan"), "applied the old way")
				assert_eq(cmds[1], "ip addr flush dev br-lan 2>/dev/null", "kernel path")
			end)
		end
	},
	{
		name = "netconfig: _l3dev gives a bridge port's master, else the name as given",
		fn = function()
			with_master("br-lan", function()
				assert_eq(netconfig._l3dev("eth0"), "br-lan", "port of br-lan")
			end)
			with_master(nil, function()
				assert_eq(netconfig._l3dev("eth0"), "eth0", "no master: unchanged")
			end)
			with_master("br-lan;reboot", function()
				assert_eq(netconfig._l3dev("eth0"), "eth0", "a master name that is not one: unchanged")
			end)
			assert_eq(netconfig._l3dev("eth0;x"), "eth0;x", "a bad name is never read with")
		end
	},
	{
		name = "netconfig: ip addr fallback puts the address on the port's bridge, not the port",
		fn = function()
			with_master("br-lan", function(cmds)
				assert_true(netconfig.apply_static("eth0", "192.0.2.10", "255.255.255.0", "192.0.2.1"),
					"applied")
				assert_eq(cmds[1], "ip addr flush dev br-lan 2>/dev/null", "flush the bridge")
				assert_eq(cmds[2], "ip addr add 192.0.2.10/24 dev br-lan 2>/dev/null", "add on the bridge")
			end)
			with_master("br-lan", function(cmds)
				assert_true(netconfig.apply_dhcp("eth0"), "dhcp")
				assert_eq(cmds[1], "ip addr flush dev br-lan 2>/dev/null", "dhcp: flush the bridge")
				assert_eq(cmds[2], "udhcpc -i br-lan -n -q 2>/dev/null", "dhcp: lease on the bridge")
			end)
			with_master("br-lan", function(cmds)
				assert_true(netconfig.restore("eth0", {addrs = {"192.0.2.10/24"}}), "restore")
				assert_eq(cmds[1], "ip -4 addr flush dev br-lan 2>/dev/null", "restore: the bridge")
			end)
		end
	},
}
