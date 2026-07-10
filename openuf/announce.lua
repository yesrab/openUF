--[[
	Ubiquiti L2 discovery broadcaster (UDP port 10001).

	Sends a TLV-encoded announce packet to 255.255.255.255 every 10 seconds.
	This makes the device visible in UniFi Discover / UBNT-Discovery before
	and after adoption.

	Can be loaded as a module (returns M) or run as a standalone script.
	When run as a script, call M.run(cfg) at the bottom of this file.
]]--

local bit = (function()
	local ok, b = pcall(require, "bit")
	if ok then return b end
	ok, b = pcall(require, "bit32")
	if ok then return b end
	local _l = load or loadstring
	local function _f(e) return _l("return function(a,b) return "..e.." end")() end
	return {band=_f("a&b"), bor=_f("a|b"), lshift=_f("a<<b"), rshift=_f("a>>b")}
end)()

local M = {}

-- Discovery destination addresses and port
M.BROADCAST_ADDR = "255.255.255.255"
M.MULTICAST_ADDR = "233.89.188.1"
M.PORT = 10001

-- TLV type codes for the Ubiquiti discovery protocol
local PKT = {
	HW_ADDR        = 0x01,
	IP_ADDR        = 0x02,
	FWVER_VERBOSE  = 0x03,
	UPTIME         = 0x0a,
	HOSTNAME       = 0x0b,
	PLATFORM       = 0x0c,
	INC_COUNTER    = 0x12,
	HW_ADDR2       = 0x13,
	PLATFORM2      = 0x15,
	FWVER_SHORT    = 0x16,
	FWVER_FACTORY  = 0x1b,
}

-- Build TLV blob for types 0x17–0x1a.
-- 0x17 = IsDefault (1 = unadopted, 0 = adopted) — must reflect actual adoption state.
-- cfg.adopted controls the byte; defaults to unadopted (1) when not set.
local function make_blob_17_1a(adopted)
	return {
		0x17, 0x00, 0x01, adopted and 0x00 or 0x01,
		0x18, 0x00, 0x01, 0x00,
		0x19, 0x00, 0x01, 0x01,
		0x1a, 0x00, 0x01, 0x00,
	}
end

-- Build a complete announce packet as a Lua binary string.
--
-- cfg fields:
--   mac          {byte, ...}  6-element table of MAC bytes
--   ip           {byte, ...}  4-element table of IP bytes
--   hostname     string
--   platform     string       e.g. "U6IW"
--   fw_pre       string       e.g. "U6IW."
--   fw_ver       string       e.g. "6.6.55"
--   fw_buildtime string       e.g. "230801.1200"
--   fw_factoryver string      e.g. "6.5.28"
--   version_suffix string     appended after fw_ver in verbose/short strings
--   uptime       number       seconds since boot
--   counter      number       monotonically increasing send counter
function M.build_packet(cfg)
	-- Outer packet: 2-byte header + 2-byte length field (filled in at end)
	local packet = {0x02, 0x06, 0x00, 0x00}
	local w

	-- 0x02: IP address (MAC + IP concatenated)
	w = ufpkt.init(PKT.IP_ADDR)
	ufpkt.cattbl(w, cfg.mac)
	ufpkt.cattbl(w, cfg.ip)
	ufpkt.finish(w, packet)

	-- 0x01: Hardware address
	w = ufpkt.init(PKT.HW_ADDR)
	ufpkt.cattbl(w, cfg.mac)
	ufpkt.finish(w, packet)

	-- 0x0a: Uptime (32-bit big-endian seconds)
	w = ufpkt.init(PKT.UPTIME)
	ufpkt.cattbl(w, ufpkt.gen4(cfg.uptime or 0))
	ufpkt.finish(w, packet)

	-- 0x0b: Hostname
	w = ufpkt.init(PKT.HOSTNAME)
	ufpkt.catstr(w, cfg.hostname or "openUF")
	ufpkt.finish(w, packet)

	-- 0x0c: Platform string
	w = ufpkt.init(PKT.PLATFORM)
	ufpkt.catstr(w, cfg.platform)
	ufpkt.finish(w, packet)

	-- 0x03: Firmware version verbose
	local suffix = cfg.version_suffix or "-openUF-0.2"
	w = ufpkt.init(PKT.FWVER_VERBOSE)
	ufpkt.catstr(w, cfg.fw_pre)
	ufpkt.catstr(w, cfg.fw_ver)
	ufpkt.catstr(w, suffix .. ".")
	ufpkt.catstr(w, cfg.fw_buildtime)
	ufpkt.finish(w, packet)

	-- 0x16: Firmware version short
	w = ufpkt.init(PKT.FWVER_SHORT)
	ufpkt.catstr(w, cfg.fw_ver)
	ufpkt.catstr(w, suffix)
	ufpkt.finish(w, packet)

	-- 0x15: Platform2 (same as platform)
	w = ufpkt.init(PKT.PLATFORM2)
	ufpkt.catstr(w, cfg.platform)
	ufpkt.finish(w, packet)

	-- Opaque blob 0x17–0x1a (IsDefault reflects adoption state)
	ufpkt.cattbl(packet, make_blob_17_1a(cfg.adopted))

	-- 0x13: Hardware address 2
	w = ufpkt.init(PKT.HW_ADDR2)
	ufpkt.cattbl(w, cfg.mac)
	ufpkt.finish(w, packet)

	-- 0x12: Incrementing counter (32-bit big-endian)
	w = ufpkt.init(PKT.INC_COUNTER)
	ufpkt.cattbl(w, ufpkt.gen4(cfg.counter or 0))
	ufpkt.finish(w, packet)

	-- 0x1b: Factory firmware version
	w = ufpkt.init(PKT.FWVER_FACTORY)
	ufpkt.catstr(w, cfg.fw_factoryver)
	ufpkt.finish(w, packet)

	-- Write full 16-bit packet length (big-endian) into bytes 3–4.
	-- BUG IN ORIGINAL: packet[4] = (len & 0xff) only wrote the low byte.
	-- FIX: write both bytes so packets >= 256 bytes are described correctly.
	local plen = #packet - 4
	packet[3] = bit.band(bit.rshift(plen, 8), 0xff)	-- high byte
	packet[4] = bit.band(plen, 0xff)					-- low byte

	-- Serialise byte table to binary string
	local out = {}
	for _, byte in ipairs(packet) do
		out[#out + 1] = string.char(byte)
	end
	return table.concat(out)
end

-- Read MAC address from sysfs for the given interface.
-- Returns a 6-element byte table or nil on failure.
function M.get_mac(iface)
	iface = iface or "eth0"
	local f = io.open("/sys/class/net/" .. iface .. "/address", "r")
	if not f then return nil end
	local line = f:read("*l"); f:close()
	if not line then return nil end
	local mac = {}
	for byte in line:gmatch("[0-9a-fA-F]+") do
		mac[#mac + 1] = tonumber(byte, 16)
	end
	return #mac == 6 and mac or nil
end

-- Read primary IPv4 address for the given interface.
-- Returns a 4-element byte table or nil on failure.
function M.get_ip(iface)
	iface = iface or "eth0"
	local handle = io.popen("ip -4 addr show dev " .. iface ..
		" 2>/dev/null | grep -m1 'inet '")
	if not handle then return nil end
	local line = handle:read("*l"); handle:close()
	if not line then return nil end
	local a, b, c, d = line:match("inet (%d+)%.(%d+)%.(%d+)%.(%d+)")
	if a then
		return {tonumber(a), tonumber(b), tonumber(c), tonumber(d)}
	end
	return nil
end

-- Start the main announce loop (blocks forever).
-- cfg: same table as build_packet() requires, plus:
--   interval  number  seconds between sends (default 10)
function M.run(cfg)
	local socket = require("socket")

	local udpb = socket.udp()
	-- luasocket creates the underlying OS socket lazily on first real use
	-- (bind/connect/send), not in socket.udp() itself. setoption() before
	-- that point silently no-ops against fd -1, so SO_BROADCAST never
	-- actually gets set and the later setpeername() to a broadcast address
	-- fails with EACCES. Force real socket creation first via a bind.
	udpb:setsockname("*", 0)
	udpb:setoption("broadcast", true)
	udpb:setpeername(M.BROADCAST_ADDR, M.PORT)

	local counter = cfg.counter or 0
	local uptime  = cfg.uptime  or 0
	local interval = cfg.interval or 10

	while true do
		counter = counter + 1
		uptime  = uptime + interval
		cfg.counter = counter
		cfg.uptime  = uptime

		udpb:send(M.build_packet(cfg))
		socket.select(nil, nil, interval)
	end
end

-- ─── Script entry point ───────────────────────────────────────────────────────
-- When run directly (lua announce.lua from the openuf/ directory), load config
-- and start the main loop. When loaded as a module via dofile/require, the
-- caller drives execution.

if not OPENUF_TEST_MODE then
	local ok, err = pcall(function()
		if not ufpkt then dofile("lib/lib.lua") end
		dofile("conf.lua")

		local ufhw = {}
		ufhw.uap = dofile("ufmodel/" .. dev.openuf.uap.ufmodel .. ".lua")

		local iface = dev.conf.net.lan_cpueth or "eth1"
		local mac   = M.get_mac(iface) or {0x24, 0xa4, 0x3c, 0x00, 0xd3, 0xad}
		local ip    = M.get_ip(iface)  or {192, 168, 1, 1}
		local h     = io.popen("hostname 2>/dev/null")
		local hostname = h and h:read("*l") or "openUF"
		if h then h:close() end

		M.run({
			mac           = mac,
			ip            = ip,
			hostname      = hostname,
			platform      = ufhw.uap.platform,
			fw_pre        = ufhw.uap.fw.pre,
			fw_ver        = ufhw.uap.fw.ver,
			fw_buildtime  = ufhw.uap.fw.buildtime,
			fw_factoryver = ufhw.uap.fw.factoryver,
			version_suffix = "-openUF-0.2",
		})
	end)
	if not ok then
		io.stderr:write("announce: " .. tostring(err) .. "\n")
		os.exit(1)
	end
end

return M
