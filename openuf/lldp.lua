--[[
	LLDP topology data reader.

	Queries lldpd (the lldpd OpenWrt package) for neighbor information to
	include in the inform payload. The actual LLDP frame transmission is
	handled by lldpd itself; this module only reads its output.

	If lldpd / lldpctl is unavailable, all functions return empty tables —
	LLDP data is optional and its absence does not affect adoption or
	WiFi provisioning.

	Injectable: override M._run_cmd in tests to supply fixture output.
]]--

local cjson = require("cjson")

local M = {}

-- Injectable: override in tests to return fixture lldpctl output
M._run_cmd = function(cmd)
	local h = io.popen(cmd .. " 2>/dev/null")
	if not h then return "" end
	local s = h:read("*a")
	h:close()
	return s or ""
end

-- Injectable: override in tests to return fixture file contents
M._read_file = function(path)
	local f = io.open(path, "r")
	if not f then return nil end
	local s = f:read("*a")
	f:close()
	return s
end

-- Returns the local port's kernel ifindex (an integer), or nil if the
-- interface doesn't exist / /sys is unavailable (e.g. off-target tests).
function M._local_port_idx(port_name)
	local s = M._read_file("/sys/class/net/" .. port_name .. "/ifindex")
	return s and tonumber(s:match("%d+")) or nil
end

-- Returns a table of LLDP neighbors, one entry per port/neighbor pair.
-- Each entry: {port, local_port_idx, chassis_id, port_id, port_descr,
--              system_name, system_desc, capabilities}
-- Returns {} if lldpctl is not available or has no neighbors.
function M.neighbors()
	local output = M._run_cmd("lldpctl -f json")
	if not output or output == "" then return {} end

	local ok, data = pcall(cjson.decode, output)
	if not ok or type(data) ~= "table" then return {} end

	local result = {}

	-- lldpctl -f json structure: {"lldp": {"interface": {...}}}
	local lldp = data.lldp
	if type(lldp) ~= "table" then return {} end

	local ifaces = lldp.interface
	if type(ifaces) ~= "table" then return {} end

	-- ifaces can be a single object or array depending on lldpd version
	local iface_list = {}
	if ifaces[1] ~= nil then
		iface_list = ifaces
	else
		iface_list = {ifaces}
	end

	for _, iface in ipairs(iface_list) do
		-- Each interface may have one or more neighbors
		local port_name = iface.name or ""
		local neighbors = iface.neighbor
		if type(neighbors) ~= "table" then
			-- no neighbors on this port
		elseif neighbors[1] ~= nil then
			-- array of neighbors
			for _, nbr in ipairs(neighbors) do
				result[#result + 1] = M._parse_neighbor(port_name, nbr)
			end
		else
			-- single neighbor
			result[#result + 1] = M._parse_neighbor(port_name, neighbors)
		end
	end

	return result
end

-- Parse a single neighbor table from lldpctl JSON output.
function M._parse_neighbor(port_name, nbr)
	local chassis = type(nbr.chassis) == "table" and nbr.chassis or {}
	local port    = type(nbr.port)    == "table" and nbr.port    or {}

	-- chassis.id.value can be a MAC, IP or string
	local chassis_id = ""
	if type(chassis.id) == "table" then
		chassis_id = chassis.id.value or ""
	elseif type(chassis.id) == "string" then
		chassis_id = chassis.id
	end

	local port_id = ""
	if type(port.id) == "table" then
		port_id = port.id.value or ""
	elseif type(port.id) == "string" then
		port_id = port.id
	end

	local sys_name = ""
	if type(chassis.name) == "table" then
		sys_name = chassis.name.value or ""
	elseif type(chassis.name) == "string" then
		sys_name = chassis.name
	end

	local sys_desc = ""
	if type(chassis.descr) == "table" then
		sys_desc = chassis.descr.value or ""
	elseif type(chassis.descr) == "string" then
		sys_desc = chassis.descr
	end

	local port_descr = ""
	if type(port.descr) == "table" then
		port_descr = port.descr.value or ""
	elseif type(port.descr) == "string" then
		port_descr = port.descr
	end

	-- Collect capability strings
	local caps = {}
	if type(chassis.capability) == "table" then
		local cap_list = chassis.capability[1] ~= nil
			and chassis.capability or {chassis.capability}
		for _, cap in ipairs(cap_list) do
			if cap.enabled and cap.type then
				caps[#caps + 1] = cap.type
			end
		end
	end

	return {
		port          = port_name,
		local_port_idx = M._local_port_idx(port_name),
		chassis_id    = chassis_id,
		port_id       = port_id,
		port_descr    = port_descr,
		system_name   = sys_name,
		system_desc   = sys_desc,
		capabilities  = caps,
	}
end

return M
