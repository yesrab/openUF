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

	Where it lands: given the UCI interface name
	(dev.conf.net.lan_name) and a libuci that knows it, the address is written
	to network.<name> and netifd is reloaded -- persistent, and on the L3
	device netifd runs rather than a bridge port. Otherwise (no libuci, no
	such interface) the old path: `ip addr`/`ip route` on iface, kernel only.
]]--

local M = {}

-- Injectable: shell command runner, for real `ip`/`udhcpc` invocations.
M._exec = os.execute

-- Overridable: where apply_dns() writes. On OpenWrt this is frequently a
-- symlink into /tmp that netifd owns; writing through it is still the right
-- move for a controller-pushed static config, since netifd has no lease to
-- re-assert over it.
M.RESOLV_CONF = "/etc/resolv.conf"

-- Strict IPv4 dotted-quad check. DNS servers arrive straight off the wire and
-- are interpolated into a shell command in apply_dns(), so anything that isn't
-- four 0-255 octets is dropped rather than escaped.
local function is_ipv4(s)
	if type(s) ~= "string" then return false end
	local octets = {s:match("^(%d+)%.(%d+)%.(%d+)%.(%d+)$")}
	if #octets ~= 4 then return false end
	for _, o in ipairs(octets) do
		if #o > 3 or tonumber(o) > 255 then return false end
	end
	return true
end
-- Exported so inform.lua can refuse a malformed push before recording it in
-- state.json, not only before running it.
M.is_ipv4 = is_ipv4

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

-- iface goes into a command line: a netdev name only (as util.valid_ifname), else refused.
local function valid_iface(s)
	return type(s) == "string" and #s <= 15 and s:match("^[%w%._][%w%-%._]*$") ~= nil
		and s ~= "." and s ~= ".."
end

-- ── UCI path ──────────────────────────────────────────────────────────────
-- Injectable: the libuci binding (nil = require("uci"), absent off OpenWrt).
M._uci = nil
local RELOAD = "/etc/init.d/network reload 2>/dev/null"
local UCI_OPTS = {"proto", "ipaddr", "netmask", "gateway", "dns"}

-- A cursor when network.<ifname> is an interface netifd runs, else nil and
-- the caller takes the `ip addr` path. Silent when there is no libuci at all
-- (Alpine/docker targets); one line when UCI is there but the name is wrong.
local function uci_iface(ifname)
	if type(ifname) ~= "string" then return nil end
	local uci = M._uci
	if not uci then
		local ok, mod = pcall(require, "uci")
		if not ok then return nil end
		uci = mod
	end
	local ok, c = pcall(uci.cursor)
	if not ok or not c then
		io.stderr:write("netconfig: libuci cursor failed; IP Settings go on with `ip addr`\n")
		return nil
	end
	if ifname:match("^[%w_]+$") and c:get("network", ifname) == "interface" then return c end
	io.stderr:write(("netconfig: no interface %q in /etc/config/network (dev.conf.net.lan_name);"
		.. " IP Settings go onto the port with `ip addr` and die at reboot\n"):format(ifname))
	return nil
end

-- libuci returns a plain option as a string (netifd splits it on spaces) and
-- a list as a table; compare and check both forms as a list of words.
local function words(v)
	if type(v) ~= "string" then return v end
	local t = {}
	for w in v:gmatch("%S+") do t[#t + 1] = w end
	return t
end

local function same(a, b)
	if type(a) == "table" or type(b) == "table" then a, b = words(a), words(b) end
	if type(a) == "table" and type(b) == "table" then
		if #a ~= #b then return false end
		for i = 1, #a do if tostring(a[i]) ~= tostring(b[i]) then return false end end
		return true
	end
	return a == b
end

-- Make network.<ifname> carry exactly `want` (nil = delete), commit and
-- reload only when something changed: every steady-state push repeats it.
local function write_opts(c, ifname, want)
	local changed = false
	for _, o in ipairs(UCI_OPTS) do
		local have = c:get("network", ifname, o)
		if not same(have, want[o]) then
			if want[o] == nil then c:delete("network", ifname, o)
			else c:set("network", ifname, o, want[o]) end
			changed = true
		end
	end
	if changed then
		-- A failed commit (overlay full) changed nothing on disk: say so, so
		-- the caller does not record a static address that is not there.
		if not c:commit("network") then return false end
		M._exec(RELOAD)
	end
	return true
end

local function ipv4_list(t)
	local out = {}
	for _, ip in ipairs(type(t) == "table" and t or {}) do
		if is_ipv4(ip) then out[#out + 1] = ip end
	end
	return #out > 0 and out or nil
end

-- Replace /etc/resolv.conf with the controller-pushed nameservers.
-- servers: array of IPv4 strings in controller order (resolv.nameserver.<k>.ip,
-- sorted by <k>).
--
-- A nil/empty list is a no-op: the controller simply not sending nameservers
-- must never blank out working resolution. Same reasoning as apply_dhcp()'s
-- guard below -- absence of a key is not an instruction to tear something down.
function M.apply_dns(servers)
	if type(servers) ~= "table" or #servers == 0 then return false end
	local args = {}
	for _, ip in ipairs(servers) do
		if is_ipv4(ip) then args[#args + 1] = "'nameserver " .. ip .. "'" end
	end
	if #args == 0 then return false end
	M._exec(string.format("printf '%%s\\n' %s > %s 2>/dev/null",
		table.concat(args, " "), M.RESOLV_CONF))
	return true
end

-- Apply a static IPv4 address (+ optional gateway and DNS servers) to iface.
-- Replaces any existing address on iface -- callers are responsible for
-- deciding this is the right moment (e.g. a genuine controller push).
-- dns: optional array of nameserver IPs, applied via apply_dns().
-- ifname: the UCI interface (dev.conf.net.lan_name); when it is one, the
-- address goes there and netifd applies it, so it survives a reboot and sits
-- on whatever L3 device netifd binds, never on a bridge port.
function M.apply_static(iface, ip, netmask, gateway, dns, ifname)
	if not valid_iface(iface) or not ip or ip == "0.0.0.0" then return false end
	-- Same rule as apply_dns, for the same reason: ip and gateway come off
	-- the wire and go into a command line, and pre-adoption that wire is
	-- plain HTTP under the well-known key. Refused whole rather than
	-- half-applied -- an address with no route is not what was asked for.
	-- (The netmask only ever reaches the command as a digit count.)
	if not is_ipv4(ip) then return false end
	if gateway and gateway ~= "" and gateway ~= "0.0.0.0" and not is_ipv4(gateway) then
		return false
	end
	local c = uci_iface(ifname)
	if c then
		-- netifd writes resolv.conf from `dns`; no direct write here. The
		-- interface mirrors the push: no valid DNS pushed = the board's own
		-- `dns` is deleted (netifd then uses the gateway / lease DNS).
		return write_opts(c, ifname, {proto = "static", ipaddr = ip,
			netmask = is_ipv4(netmask) and netmask or "255.255.255.0",
			gateway = (gateway and gateway ~= "" and gateway ~= "0.0.0.0") and gateway or nil,
			dns = ipv4_list(dns)})
	end
	iface = M._l3dev(iface)
	local prefix = M.netmask_to_prefix(netmask)
	M._exec(string.format("ip addr flush dev %s 2>/dev/null", iface))
	M._exec(string.format("ip addr add %s/%d dev %s 2>/dev/null", ip, prefix, iface))
	if gateway and gateway ~= "0.0.0.0" then
		M._exec(string.format("ip route replace default via %s 2>/dev/null", gateway))
	end
	M.apply_dns(dns)
	return true
end

-- Injectable: run a command and return its output ("" when it cannot run).
M._read = function(cmd)
	local p = io.popen(cmd)
	if not p then return "" end
	local s = p:read("*a") or ""
	p:close()
	return s
end

local function is_cidr(s)
	if type(s) ~= "string" then return false end
	local a, p = s:match("^(%d+%.%d+%.%d+%.%d+)/(%d+)$")
	return a ~= nil and is_ipv4(a) and tonumber(p) <= 32
end

-- The device the `ip addr` fallback acts on. Most board maps name a bridge
-- PORT as lan_cpueth (eth0, lan1, wan); an address on a port is never
-- answered, the bridge owns the traffic. So a port that has a master (its
-- bridge, or a bond) gives way to that master. Anything else stays as named.
function M._l3dev(iface)
	if not valid_iface(iface) then return iface end
	-- readlink gives a relative sysfs path, ../../virtual/net/br-lan
	local m = M._read(string.format("readlink /sys/class/net/%s/master 2>/dev/null", iface))
		:match("^%.%./%S*/([^/%s]+)%s*$")
	return valid_iface(m) and m or iface
end

-- What iface carries now, for a commit-confirm rollback (inform.lua):
-- {addrs = {"a.b.c.d/nn", ...}, gw = "a.b.c.d" or nil, dns = {...}}.
-- The kernel's view, not ours: it is right whether the address came from a
-- lease, the router's own config or an earlier push. nil without an iface.
-- With ifname on the UCI path, snap.uci also keeps that interface's options
-- as they are, which is what restore() puts back there.
function M.snapshot(iface, ifname)
	if not iface then return nil end
	local snap = {addrs = {}, dns = {}}
	local c = uci_iface(ifname)
	if c then
		snap.uci = {}
		for _, o in ipairs(UCI_OPTS) do snap.uci[o] = c:get("network", ifname, o) end
	end
	iface = M._l3dev(iface)
	local out = M._read(string.format("ip -4 -o addr show dev %s 2>/dev/null", iface))
	for cidr in out:gmatch("inet (%d+%.%d+%.%d+%.%d+/%d+)") do
		if is_cidr(cidr) then snap.addrs[#snap.addrs + 1] = cidr end
	end
	local gw = M._read("ip -4 route show default 2>/dev/null"):match("default via (%d+%.%d+%.%d+%.%d+)")
	if is_ipv4(gw) then snap.gw = gw end
	local f = io.open(M.RESOLV_CONF, "r")
	if f then
		for ns in (f:read("*a") or ""):gmatch("nameserver%s+([%d%.]+)") do
			if is_ipv4(ns) then snap.dns[#snap.dns + 1] = ns end
		end
		f:close()
	end
	return snap
end

-- Put a snapshot back. It comes from state.json, so every entry is checked
-- again before it reaches a command line; a bad one is skipped. DNS is only
-- rewritten when the snapshot had nameservers (apply_dns's own rule).
function M.restore(iface, snap, ifname)
	if not valid_iface(iface) or type(snap) ~= "table" or type(snap.addrs) ~= "table" then return false end
	local c = type(snap.uci) == "table" and uci_iface(ifname)
	if c then
		local u = snap.uci
		local function addr(v) return is_ipv4(v) or is_cidr(v) end
		local function each(v, ok)
			if v == nil then return true end
			v = words(v)
			if type(v) ~= "table" then return false end
			for _, x in ipairs(v) do if not ok(x) then return false end end
			return #v > 0
		end
		if not ((u.proto == "static" or u.proto == "dhcp") and each(u.ipaddr, addr)
				and (u.netmask == nil or is_ipv4(u.netmask))
				and (u.gateway == nil or is_ipv4(u.gateway)) and each(u.dns, is_ipv4)) then
			return false
		end
		return write_opts(c, ifname, u)
	end
	local good = {}
	for _, cidr in ipairs(snap.addrs) do
		if is_cidr(cidr) then good[#good + 1] = cidr end
	end
	-- Had addresses, none usable: a corrupt record. Flushing would leave
	-- the port with nothing, worse than the push it means to undo.
	if #snap.addrs > 0 and #good == 0 then return false end
	iface = M._l3dev(iface)
	M._exec(string.format("ip -4 addr flush dev %s 2>/dev/null", iface))
	for _, cidr in ipairs(good) do
		M._exec(string.format("ip addr add %s dev %s 2>/dev/null", cidr, iface))
	end
	if is_ipv4(snap.gw) then
		M._exec(string.format("ip route replace default via %s 2>/dev/null", snap.gw))
	end
	if type(snap.dns) == "table" then M.apply_dns(snap.dns) end
	return true
end

-- Release any static config and let a DHCP client re-acquire an address.
-- Best-effort: real hardware's netifd handles this natively; here we shell
-- out to udhcpc directly (present on both Alpine and OpenWrt).
-- On the UCI path: proto dhcp, the address options dropped (`dns` too: the
-- lease brings DNS), and netifd's own client takes over (no one-shot udhcpc).
function M.apply_dhcp(iface, ifname)
	if not valid_iface(iface) then return false end
	local c = uci_iface(ifname)
	if c then return write_opts(c, ifname, {proto = "dhcp"}) end
	iface = M._l3dev(iface)
	M._exec(string.format("ip addr flush dev %s 2>/dev/null", iface))
	M._exec(string.format("udhcpc -i %s -n -q 2>/dev/null", iface))
	return true
end

return M
