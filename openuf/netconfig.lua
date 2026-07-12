--[[
	Network interface configuration, driven by the controller's "IP Settings"
	(DHCP vs Static) push. Delivered via the inform response's `system_cfg`
	field -- a flat OpenWrt-UCI-style key=value blob (same format as
	`mgmt_cfg`, different keys), NOT the vap_table/network_table-shaped JSON
	used elsewhere. Confirmed live against a real controller: static IP is
	`netconf.1.ip`/`netconf.1.netmask`, gateway is `route.1.gateway`, DNS is
	`resolv.nameserver.N.ip`, and DHCP-vs-static is signalled by the
	presence/absence of `dhcpc.1.*` sub-keys (not an explicit flag) -- see
	PROTOCOL-VALIDATION.md.

	All operations are safe no-ops without an iface (unconfigured hardware),
	matching led.lua/ucihelper.lua's convention.
]]--

local M = {}

-- Injectable: shell command runner, for real `ip`/`udhcpc` invocations.
M._exec = function(cmd) return os.execute(cmd) end

-- Convert a dotted-quad netmask ("255.255.255.0") to a CIDR prefix length.
-- Returns 24 (a common default) if netmask is nil/unparseable.
function M.netmask_to_prefix(netmask)
	if type(netmask) ~= "string" then return 24 end
	local bits = 0
	local octets = 0
	for octet in netmask:gmatch("%d+") do
		local n = tonumber(octet)
		if n then
			while n > 0 do
				bits = bits + (n % 2)
				n = math.floor(n / 2)
			end
			octets = octets + 1
		end
	end
	return octets == 4 and bits or 24
end

-- Apply a static IPv4 address (+ optional gateway/DNS) to iface.
-- Replaces any existing address on iface -- callers are responsible for
-- deciding this is the right moment (e.g. a genuine controller push).
function M.apply_static(iface, ip, netmask, gateway)
	if not iface or not ip or ip == "0.0.0.0" then return false end
	local prefix = M.netmask_to_prefix(netmask)
	M._exec(string.format("ip addr flush dev %s 2>/dev/null", iface))
	M._exec(string.format("ip addr add %s/%d dev %s 2>/dev/null", ip, prefix, iface))
	if gateway and gateway ~= "0.0.0.0" then
		M._exec(string.format("ip route replace default via %s 2>/dev/null", gateway))
	end
	return true
end

-- Release any static config and let a DHCP client re-acquire an address.
-- Best-effort: real hardware's netifd handles this natively; here we shell
-- out to udhcpc directly (present on both Alpine and OpenWrt).
function M.apply_dhcp(iface)
	if not iface then return false end
	M._exec(string.format("ip addr flush dev %s 2>/dev/null", iface))
	M._exec(string.format("udhcpc -i %s -n -q 2>/dev/null", iface))
	return true
end

return M
