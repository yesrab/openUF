--[[
	STUN wake-up: how the controller makes a managed AP inform now, instead
	of at its next heartbeat, when it has a command or a config change for it.

	THE CONTROLLER (Network 10.6, stun.type=local, the default)

	It runs a classic RFC 3489 STUN server (jstun) on UDP 3478 and puts
	stun_url=stun://<host>:3478/ in every mgmt_cfg. It answers a Binding
	Request that carries a CHANGE-REQUEST attribute (it rejects one without)
	with MAPPED-ADDRESS = the request's source address. Whenever it queues a
	command or a config change for a connected device whose inform carried
	connect_request_ip and connect_request_port, it sends a "connection
	request" from port 3478 to that address: 20 bytes, type 0x8888, length 0,
	the rest zero.

	THE FIRMWARE (mcad stun_init/stun_send/stun_recv, firmware-confirmed
	for 4.0.15)

	One UDP socket bound to 0.0.0.0 on an ephemeral port, used only while the
	AP is managed and stun_url is set. Every 30 s (5 s after a failure) it
	sends a 28-byte Binding Request: a zero transaction id and CHANGE-REQUEST
	0. A Binding Response's MAPPED-ADDRESS becomes connect_request_ip and
	connect_request_port, both JSON strings, sent while the port is non-zero.
	A changed address triggers an inform at once, and so does a 0x8888
	packet. Neither checks the sender or the transaction id.
]]--

local M = {}

M.PORT = 3478      -- the controller's STUN port, when stun_url names none
M.INTERVAL = 30    -- seconds between Binding Requests
M.RETRY = 5        -- seconds after a failed resolve or send
M.DRAIN = 64       -- packets read per wake-up at most
-- Binding Requests in a row without a Binding Response before the
-- controller's name is resolved again. A UDP send to an address nobody
-- answers on still succeeds, so a send failure alone would never notice a
-- controller that moved (a new DHCP lease behind the same name).
M.RESOLVE_AFTER = 3
-- dns.toip blocks the inform loop for as long as the resolver takes, which
-- with a dead DNS server is its full timeout. Failed lookups back off
-- (RETRY, doubling, up to this), and a name that resolved once keeps its
-- last address meanwhile. An address literal is never looked up.
M.RESOLVE_BACKOFF_MAX = 300

local T_BINDING_REQUEST  = 0x0001
local T_BINDING_RESPONSE = 0x0101
local T_CONN_REQUEST     = 0x8888
local A_MAPPED_ADDRESS   = 0x0001
local A_CHANGE_REQUEST   = 0x0003

local function u16(s, i) return s:byte(i) * 256 + s:byte(i + 1) end
local function be16(n) return string.char(math.floor(n / 256) % 256, n % 256) end

-- "stun://host:port/" -> host, port. nil for anything else.
function M.parse_url(url)
	if type(url) ~= "string" then return nil end
	local host, port = url:match("^stun://([^/:%[%]]+):?(%d*)/?$")
	if not host then return nil end
	port = tonumber(port) or M.PORT
	if port < 1 or port > 65535 then return nil end
	return host, port
end

-- The firmware's Binding Request, byte for byte.
function M.request()
	return be16(T_BINDING_REQUEST) .. be16(8) .. string.rep(string.char(0), 16)
		.. be16(A_CHANGE_REQUEST) .. be16(4) .. string.rep(string.char(0), 4)
end

-- One datagram -> "wake", or "mapped", ip, port, or nil for anything else.
function M.parse(pkt)
	if type(pkt) ~= "string" or #pkt < 20 then return nil end
	local t = u16(pkt, 1)
	if t == T_CONN_REQUEST then return "wake" end
	if t ~= T_BINDING_RESPONSE then return nil end
	local i = 21
	while i + 3 <= #pkt do
		local at, len = u16(pkt, i), u16(pkt, i + 2)
		if i + 3 + len > #pkt then return nil end
		-- Family 1 is IPv4. The socket is IPv4, so an IPv6 mapping (family
		-- 2, which the firmware also takes) cannot be this socket's address.
		if at == A_MAPPED_ADDRESS and len >= 8 and pkt:byte(i + 5) == 1 then
			local port = u16(pkt, i + 6)
			local ip = ("%d.%d.%d.%d"):format(pkt:byte(i + 8, i + 11))
			if port == 0 then return nil end
			return "mapped", ip, port
		end
		i = i + 4 + len
	end
	return nil
end

-- A client: c = M.new(socket). socket is LuaSocket (or a test double).
function M.new(socket)
	return {socket = socket}
end

function M.close(c)
	if c.sock then pcall(c.sock.close, c.sock) end
	c.sock, c.ip, c.mapped_ip, c.mapped_port = nil, nil, nil, nil
	c.next_send, c.unanswered = nil, 0
end

-- Follow the wanted URL: open on a new one, close when there is none.
-- active is false while the AP is not managed.
function M.sync(c, url, active)
	local host, port = M.parse_url(url)
	if not (active and host) then
		if c.sock then M.close(c) end
		c.url = nil
		return
	end
	if c.url ~= url then
		M.close(c)
		c.url, c.host, c.port = url, host, port
		c.last_ip, c.resolve_fails, c.resolve_at = nil, 0, nil
	end
	if not c.sock then
		local s, err = c.socket.udp()
		if not s then return nil, err end
		local ok, err2 = s:setsockname("*", 0)
		if not ok then pcall(s.close, s) return nil, err2 end
		s:settimeout(0)
		c.sock = s
	end
	return true
end

-- The server's address: the host itself when it is an IPv4 literal, else a
-- lookup, at most once per backoff step while lookups fail. nil when there
-- is none to use.
local function resolve(c, now)
	if c.host:match("^%d+%.%d+%.%d+%.%d+$") then return c.host end
	if c.resolve_at and now < c.resolve_at then return c.last_ip end
	local ip = c.socket.dns and c.socket.dns.toip(c.host)
	if ip then
		c.last_ip, c.resolve_fails, c.resolve_at = ip, 0, nil
		return ip
	end
	c.resolve_fails = (c.resolve_fails or 0) + 1
	c.resolve_at = now + math.min(M.RETRY * 2 ^ (c.resolve_fails - 1), M.RESOLVE_BACKOFF_MAX)
	return c.last_ip
end

-- Send the Binding Request when due. now is in seconds.
function M.send_due(c, now)
	if not c.sock or (c.next_send and now < c.next_send) then return false end
	if c.ip and (c.unanswered or 0) >= M.RESOLVE_AFTER then
		c.ip, c.unanswered = nil, 0
	end
	if not c.ip then
		local ip = resolve(c, now)
		if not ip then
			c.next_send = math.max(now + M.RETRY, c.resolve_at or 0)
			return false, "cannot resolve " .. tostring(c.host)
		end
		c.ip = ip
	end
	local req = M.request()
	local n, err = c.sock:sendto(req, c.ip, c.port)
	if n ~= #req then
		-- Re-resolve on the next try, as the firmware does after a failure.
		c.ip = nil
		c.next_send = now + M.RETRY
		return false, err
	end
	c.next_send = now + M.INTERVAL
	c.unanswered = (c.unanswered or 0) + 1
	return true
end

-- Read what is queued. Returns wake: true when the controller asked for an
-- inform or this socket's mapped address changed.
--
-- Only what the STUN server's own address sent counts. The firmware checks
-- no sender, so any LAN host could make an AP inform over and over with a
-- stream of 0x8888 packets, or plant a connect_request address the
-- controller then sends its wake-ups to (fonix232/openUF 168c362,
-- COMPLETION-PLAN D3). Nothing can matter before the first Binding Request,
-- and that one sets c.ip.
function M.receive(c)
	if not c.sock then return false end
	local wake = false
	local server = c.ip or c.last_ip
	for _ = 1, M.DRAIN do
		local pkt, from = c.sock:receivefrom()
		if not pkt then
			-- Anything but "nothing queued" ends this socket; sync opens a
			-- new one on the next tick, as the firmware reinits.
			if from ~= "timeout" then M.close(c) end
			break
		end
		local kind, ip, port
		if server and from == server then kind, ip, port = M.parse(pkt) end
		if kind == "wake" then
			wake = true
		elseif kind == "mapped" then
			c.unanswered = 0
			if ip ~= c.mapped_ip or port ~= c.mapped_port then
				c.mapped_ip, c.mapped_port = ip, port
				wake = true
			end
		end
	end
	return wake
end

-- The inform's connect_request_ip and connect_request_port, or nil.
function M.fields(c)
	if not (c and c.sock and c.mapped_port) then return nil end
	return c.mapped_ip, tostring(c.mapped_port)
end

return M
