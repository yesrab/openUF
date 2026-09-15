--[[
	STUN probe -- the go/no-go experiment for REVERSE-ENGINEERING.md's
	Investigation 3 (the controller's STUN channel).

	Every mgmt_cfg the controller sends carries stun_url=stun://<host>:3478/
	and openUF has never opened that channel. Real devices keep a STUN
	binding to the controller and, per Ubiquiti's own port documentation,
	the controller uses it to tell a device to inform NOW when an admin hits
	Apply -- which is why a real AP reacts in about a second and openUF in
	up to ten. What the controller actually sends, and to which address and
	port, is what this probe finds out. It sends nothing to the controller
	but standard RFC 5389 Binding Requests, and decodes whatever comes back
	or arrives unsolicited.

	Runs ON the AP (needs luasocket, which openUF already requires):

	    lua tools/stun-probe.lua <controller-ip> [stun-port] [local-port] [interval]
	    lua tools/stun-probe.lua 192.168.1.1                 # 3478 -> 3478 every 10 s

	The local port defaults to 3478 so both hypotheses are covered at once:
	a controller that answers to the binding's source port, and one that
	pokes <device-ip>:3478 unsolicited. Run it under nohup with the output
	to a file, then make a change to THIS device in the controller UI and
	click Apply; every datagram is timestamped (UTC), decoded and hex-dumped.
	Ctrl-C (or kill) to stop. Nothing here touches openUF's own state.
]]--

local socket = require("socket")

local host     = arg[1]
local port     = tonumber(arg[2]) or 3478
local lport    = tonumber(arg[3]) or 3478
local interval = tonumber(arg[4]) or 10
if not host then
	io.stderr:write("usage: lua stun-probe.lua <controller-ip> [stun-port=3478] [local-port=3478] [interval=10]\n")
	os.exit(2)
end

-- Lua 5.1: no native bitwise operators. luabitop when present, arithmetic
-- otherwise (the probe must run wherever openUF runs).
local ok_bit, bit = pcall(require, "bit")
local function bxor(a, b)
	if ok_bit and bit.bxor then return bit.bxor(a, b) end
	local r, p = 0, 1
	while a > 0 or b > 0 do
		local x, y = a % 2, b % 2
		if x ~= y then r = r + p end
		a, b, p = (a - x) / 2, (b - y) / 2, p * 2
	end
	return r
end

local MAGIC = 0x2112A442
local MAGIC_BYTES = {0x21, 0x12, 0xA4, 0x42}

local function u16(s, i) local a, b = s:byte(i, i + 1); return a * 256 + b end
local function u32(s, i)
	local a, b, c, d = s:byte(i, i + 3)
	return ((a * 256 + b) * 256 + c) * 256 + d
end
local function be16(n) return string.char(math.floor(n / 256) % 256, n % 256) end
local function be32(n)
	return string.char(math.floor(n / 16777216) % 256, math.floor(n / 65536) % 256,
		math.floor(n / 256) % 256, n % 256)
end
local function hex(s)
	return (s:gsub(".", function(c) return ("%02x"):format(c:byte()) end))
end
local function txid()
	local t = {}
	for i = 1, 12 do t[i] = string.char(math.random(0, 255)) end
	return table.concat(t)
end

-- RFC 5389 Binding Request: type 0x0001, no attributes.
local function binding_request()
	return be16(0x0001) .. be16(0) .. be32(MAGIC) .. txid()
end

local ATTR = {
	[0x0001] = "MAPPED-ADDRESS",     [0x0002] = "RESPONSE-ADDRESS",
	[0x0003] = "CHANGE-REQUEST",     [0x0004] = "SOURCE-ADDRESS",
	[0x0005] = "CHANGED-ADDRESS",    [0x0006] = "USERNAME",
	[0x0008] = "MESSAGE-INTEGRITY",  [0x0009] = "ERROR-CODE",
	[0x000A] = "UNKNOWN-ATTRIBUTES", [0x0014] = "REALM",
	[0x0015] = "NONCE",              [0x0020] = "XOR-MAPPED-ADDRESS",
	[0x8020] = "XOR-MAPPED-ADDRESS(legacy)", [0x8022] = "SOFTWARE",
	[0x8023] = "ALTERNATE-SERVER",   [0x8028] = "FINGERPRINT",
}
local CLASS = {[0] = "request", [1] = "indication", [2] = "success-response", [3] = "error-response"}

local function decode_addr(v, xor)
	if #v < 8 then return "short address attribute: " .. hex(v) end
	local fam, p = v:byte(2), u16(v, 3)
	if fam ~= 1 then return "ipv6/other family " .. fam .. ": " .. hex(v:sub(3)) end
	local b = {v:byte(5, 8)}
	if xor then
		p = bxor(p, math.floor(MAGIC / 65536))
		for i = 1, 4 do b[i] = bxor(b[i], MAGIC_BYTES[i]) end
	end
	return table.concat(b, ".") .. ":" .. p
end

-- One line for the header, one per attribute. Anything that is not STUN
-- is still shown, in full, because a proprietary poke is exactly what
-- this experiment is looking for.
local function decode(pkt)
	if #pkt < 20 then return "not STUN (" .. #pkt .. " bytes)" end
	local mtype, mlen, magic = u16(pkt, 1), u16(pkt, 3), u32(pkt, 5)
	local c1, c0 = math.floor(mtype / 256) % 2, math.floor(mtype / 16) % 2
	local meth = math.floor(mtype / 512) % 32 * 128 + math.floor(mtype / 32) % 8 * 16 + mtype % 16
	local out = {("STUN type=0x%04x class=%s method=0x%03x%s len=%d magic=%s txid=%s"):format(
		mtype, CLASS[c1 * 2 + c0], meth, meth == 1 and "(Binding)" or "", mlen,
		magic == MAGIC and "ok" or ("BAD 0x%08x"):format(magic), hex(pkt:sub(9, 20)))}
	if magic ~= MAGIC then out[#out + 1] = "  (magic mismatch: not RFC 5389 STUN, or a proprietary message)" end
	local i = 21
	while i + 3 <= #pkt do
		local at, al = u16(pkt, i), u16(pkt, i + 2)
		local v = pkt:sub(i + 4, i + 3 + al)
		local shown
		if at == 0x0001 or at == 0x0004 or at == 0x0005 or at == 0x8023 then
			shown = decode_addr(v, false)
		elseif at == 0x0020 or at == 0x8020 then
			shown = decode_addr(v, true)
		elseif at == 0x8022 or at == 0x0006 or at == 0x0014 or at == 0x0015 then
			shown = ("%q"):format(v)
		elseif at == 0x0009 and #v >= 4 then
			shown = ("%d%02d %s"):format(v:byte(3) % 8, v:byte(4), v:sub(5))
		else
			shown = hex(v)
		end
		out[#out + 1] = ("  attr %s len=%d %s"):format(ATTR[at] or ("0x%04x"):format(at), al, shown)
		i = i + 4 + al + (4 - al % 4) % 4   -- attributes are padded to 32 bits
	end
	return table.concat(out, "\n")
end

math.randomseed(os.time())
local udp = assert(socket.udp())
assert(udp:setsockname("*", lport))
udp:settimeout(1)

local function log(s)
	io.stdout:write(os.date("!%Y-%m-%dT%H:%M:%SZ"), " ", s, "\n")
	io.stdout:flush()
end

log(("stun-probe: listening on *:%d, binding requests to %s:%d every %d s"):format(lport, host, port, interval))
local next_send = 0
while true do
	local now = os.time()
	if now >= next_send then
		local req = binding_request()
		local ok, err = udp:sendto(req, host, port)
		log(ok and ("TX binding request txid=" .. hex(req:sub(9, 20))) or ("TX failed: " .. tostring(err)))
		next_send = now + interval
	end
	local data, ip, rport = udp:receivefrom()
	if data then
		log(("RX %d bytes from %s:%s"):format(#data, tostring(ip), tostring(rport)))
		log(decode(data))
		log("  raw " .. hex(data))
	elseif ip ~= "timeout" then
		log("RX error: " .. tostring(ip))
	end
end
