--[[
	The encrypted-syslog forwarder: `logread -f | lua logfwd.lua <conf>`.

	Started by remotelog.forwarder_ensure() from the inform daemon's working
	directory (openuf/), which is where the siblings below are found. Reads
	one log line at a time from stdin, seals it the way the controller's
	listener expects (remotelog.lua has the format and its evidence) and sends
	it as one UDP datagram. Everything it needs is in the conf file: the key
	never travels on a command line.

	It ends when stdin does (logread gone) or when it is killed. A send that
	fails is said once, not per line: a line written for every failed line is
	a line to forward, and that loop fills a log.
]]--

local function sibling(name)
	for _, p in ipairs({name .. ".lua", "openuf/" .. name .. ".lua"}) do
		local f = io.open(p, "r")
		if f then f:close(); return dofile(p) end
	end
	error("logfwd: cannot find " .. name .. ".lua")
end

local M = {}

-- At most BURST lines at once and RATE a second after that. Without it a
-- driver that logs in a loop turns the AP into a datagram source aimed at the
-- controller. Lines past the budget are dropped, not queued.
M.RATE  = 50
M.BURST = 100

-- The budget after `dt` seconds, and whether one line may go.
function M.take(tokens, dt)
	tokens = math.min(M.BURST, tokens + dt * M.RATE)
	if tokens < 1 then return tokens, false end
	return tokens - 1, true
end

function M.run(conf_path, opts)
	opts = opts or {}
	local remotelog = opts.remotelog or sibling("remotelog")
	local crypto    = opts.crypto or sibling("crypto")
	remotelog._crypto = crypto
	local f = io.open(conf_path, "r")
	if not f then error("logfwd: cannot read " .. tostring(conf_path)) end
	local conf = remotelog.parse_conf(f:read("*a"))
	f:close()
	if not (remotelog.is_valid_host(conf.ip) and remotelog.is_valid_port(conf.port)
	   and remotelog.is_valid_key(conf.key) and remotelog.is_valid_hash_id(conf.hash_id)) then
		error("logfwd: " .. conf_path .. " is incomplete")
	end
	local udp = opts.udp
	if not udp then
		local socket = require("socket")
		udp = assert(socket.udp())
		assert(udp:setpeername(conf.ip, tonumber(conf.port)))
	end
	local clock = opts.clock or os.time
	local lines = opts.lines or io.lines()
	local tokens, last, failed = M.BURST, clock(), false
	for line in lines do
		local now = clock()
		local go
		tokens, go = M.take(tokens, now - last)
		last = now
		if go and line ~= "" then
			local ok, err = pcall(function()
				local d = remotelog.seal(conf.key, conf.hash_id,
					remotelog.format_line(line, conf.host or "", conf.tag or "", now))
				local sent, serr = udp:send(d)
				if not sent then error(serr) end
			end)
			if not ok and not failed then
				failed = true
				io.stderr:write("logfwd: send failed: " .. tostring(err) .. " (further failures not logged)\n")
			end
		end
	end
end

-- Run as a script (`lua logfwd.lua <conf>`), loaded as a module by the tests.
if type(arg) == "table" and arg[0] and arg[0]:match("logfwd%.lua$") and arg[1] then
	M.run(arg[1])
end

return M
