--[[
	IGMP/MLD snooping on the bridges the WLANs sit on (config.igmp_snooping,
	off by default).

	A U6 Pro runs every bridge it has (br0 and each br0.<vlan>) with
	multicast_snooping 1, multicast_querier 0 and hash_max 2048 (its
	bridge.conf and mcsd.conf, firmware 8.8.14, as captured in
	dtechterminal/udeco docs/reference/u6pro/config-apply/sysinit). A group a
	client has joined is then sent only to the ports with a member, where a
	bridge without snooping floods it to every VAP at the lowest basic rate.
	OpenWrt's bridges come with snooping off (both of AP1's read 0 on
	2026-11-22).

	The same three values are written here, to sysfs and nowhere else:

	  /sys/class/net/<bridge>/bridge/{hash_max,multicast_querier,multicast_snooping}

	Not to /etc/config/network: br-lan is the board's own bridge, set up by
	the installer or the operator, and its `config device` is not openUF's to
	edit. sysfs is live kernel state, so a bridge netifd re-creates comes back
	without it; resync() is called once a minute and writes only a value that
	reads otherwise. The bridges it has switched are kept in a file under
	/var/run, so turning the option off (which takes a restart) puts
	multicast_snooping back to 0 on exactly those and on no bridge whose
	snooping somebody else turned on.

	With no querier on a VLAN the kernel floods a group as before (a bridge
	only prunes once it has seen a query), which is the firmware's own
	"policy flood" for unknown groups. Link-local groups (224.0.0.x, mDNS
	among them) are never pruned by the kernel.
]]--

local M = {}
local util = package.loaded["openuf.util"]
	or assert(loadfile("util.lua") or loadfile("openuf/util.lua"))()

M.SYSFS = "/sys/class/net"
-- tmpfs: gone at reboot, as the sysfs values are.
M.LEDGER = "/var/run/openuf.mcsnoop"
-- In this order: the table size before snooping starts filling it.
M.WANT = {{"hash_max", "2048"}, {"multicast_querier", "0"}, {"multicast_snooping", "1"}}

M._run_cmd = util.capture
M._read_file = util.read_file
M._write_file = function(path, contents)
	local f = io.open(path, "w")
	if not f then return false end
	local ok = f:write(contents)
	-- sysfs reports a rejected value on close, not on write.
	local closed = f:close()
	return ok ~= nil and closed ~= nil and closed ~= false
end

local function valid(name)
	return type(name) == "string" and #name <= 15
		and name:match("^[%w%._][%w%-%._]*$") ~= nil and name ~= "." and name ~= ".."
end

local function attr(bridge, name)
	return M.SYSFS .. "/" .. bridge .. "/bridge/" .. name
end

local function read(bridge, name)
	local v = M._read_file(attr(bridge, name))
	return type(v) == "string" and v:match("^%s*(%-?%d+)") or nil
end

-- The bridges to switch: the LAN bridge the caller resolved (nil when it
-- could not tell, and then it is left out, not guessed) and every VLAN
-- bridge openUF made (br-openuf<vid>). Only ones the kernel can snoop on.
function M.bridges(lan_bridge)
	local seen, out = {}, {}
	local function add(name)
		if valid(name) and not seen[name] and read(name, "multicast_snooping") then
			seen[name] = true
			out[#out + 1] = name
		end
	end
	add(lan_bridge)
	for line in (M._run_cmd("ls -d " .. M.SYSFS .. "/br-openuf*/bridge 2>/dev/null") or ""):gmatch("[^\n]+") do
		add(line:match("^" .. M.SYSFS:gsub("%p", "%%%0") .. "/(br%-openuf%d+)/bridge$"))
	end
	table.sort(out)
	return out
end

local function ledger_read()
	local out = {}
	for name in (M._read_file(M.LEDGER) or ""):gmatch("[^\n]+") do
		if valid(name) then out[name] = true end
	end
	return out
end

local function ledger_write(set)
	local names = {}
	for name in pairs(set) do names[#names + 1] = name end
	table.sort(names)
	if #names == 0 then
		os.remove(M.LEDGER)
		return true
	end
	return M._write_file(M.LEDGER, table.concat(names, "\n") .. "\n")
end

-- Bring the bridges to the wanted state. enabled: config.igmp_snooping.
-- Returns the number of values written.
--
-- A bridge that already snooped before openUF touched it is never entered in
-- the ledger, so "off" leaves it snooping: it was not ours.
function M.resync(enabled, lan_bridge)
	local ours = ledger_read()
	local writes, dirty = 0, false
	if enabled then
		for _, br in ipairs(M.bridges(lan_bridge)) do
			local was_on = read(br, "multicast_snooping") == "1"
			for _, w in ipairs(M.WANT) do
				-- An operator's own snooping bridge keeps its own querier and
				-- table size.
				if (ours[br] or not was_on) and read(br, w[1]) ~= w[2]
						and M._write_file(attr(br, w[1]), w[2]) then
					writes = writes + 1
				end
			end
			if not was_on and not ours[br] and read(br, "multicast_snooping") == "1" then
				ours[br], dirty = true, true
			end
		end
	else
		for br in pairs(ours) do
			if read(br, "multicast_snooping") == "1"
					and M._write_file(attr(br, "multicast_snooping"), "0") then
				writes = writes + 1
			end
			ours[br], dirty = nil, true
		end
	end
	if dirty then ledger_write(ours) end
	return writes
end

return M
