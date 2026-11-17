--[[
	Controller-managed remote syslog: the `syslog.*` block of system_cfg.

	Settings -> System -> Remote Logging on the controller has two shapes on
	the wire, and until 2026-11-17 openUF read neither (the keys sat in the
	unhandled ledger):

	  syslog.status=enabled
	  syslog.remote.status=enabled
	  syslog.remote.ip=<server>        syslog.remote.port=<port>
	  syslog.remote.encrypt=enabled    syslog.remote.key=<64 hex digits>

	1. A syslog server of the operator's own (no `encrypt`): plain RFC 3164
	   over UDP. OpenWrt's logd does exactly that, so this becomes UCI
	   system.@system[0].log_ip / log_port / log_proto, stamped so it can be
	   put back (openuf_log_managed, openuf_log_*_orig), and a logd restart.

	2. "This controller, encrypted": the controller's own listener (UDP 5514
	   on Network 10.6) takes one datagram per message, sealed with
	   AES-256-GCM under the pushed key:

	     0  4  magic AB CD DC BA
	     4  1  0x01
	     5  4  00 00 00 01
	     9  8  the device's hash_id (the 16 hex digits it reports in its inform)
	     17 12 GCM nonce, random per datagram
	     29 n  ciphertext || 16-byte tag; additional data = bytes 0..28

	   The plaintext is one syslog line tagged the way a UAP tags its own:
	   "<pri>Mon dd hh:mm:ss <host> <MODEL>,<mac12>,<version>: <message>".
	   logd cannot seal anything, so a small forwarder (logfwd.lua) follows
	   `logread -f` and sends each line. It is a child of nobody: started with
	   a trailing &, like rrmscan's collector, and stopped from the same three
	   places (a push that turns it off, _forget_controller, the init script).

	⚠️ EVIDENCE. The datagram format, the port, the line tag and the gate are
	antoniocosta/unifi-openwrt's (GPL-2.0-or-later; docs/internals.md
	"Encrypted remote syslog" and internal/device/syslog.go, read 2026-11-17),
	decompiled by them from Network 10.6.109's RemoteLoggerServer and run live
	on their OnHub against a UniFi Express 7. Re-implemented here, not copied;
	NOTHING of shape 2 has been run against a controller from this tree. Per
	their reading the controller sends the block in "encrypted only" mode
	solely to a device whose fw_caps carries 0x1000000, which is why that bit
	is behind `config.encrypted_syslog` (default off) rather than claimed.

	The key is a secret: it reaches the forwarder through a 0600 file under
	/var/run, never a command line, and is never logged.
]]--

local M = {}
local util = package.loaded["openuf.util"]
	or assert(loadfile("util.lua") or loadfile("openuf/util.lua"))()

-- Injectable seams, as in the other modules.
M._uci       = nil            -- mock UCI table; nil = require("uci")
M._exec      = os.execute
M._popen     = util.popen
M._read_file = util.read_file
M._crypto    = nil            -- set by inform.lua / logfwd.lua (one crypto instance)
M._open      = io.open

M.HEADER_LEN     = 29
M.TAG_LEN        = 16
-- The controller's receive buffer: a longer datagram is cut there and its
-- tag lost, so the message is cut here instead.
M.MAX_DATAGRAM   = 4096
M.ENCRYPTED_PORT = 5514
M.PLAIN_PORT     = 514
M.CONF_FILE      = "/var/run/openuf-logfwd.conf"
M.FORWARDER      = "logfwd.lua"

local MAGIC = string.char(0xAB, 0xCD, 0xDC, 0xBA, 0x01, 0x00, 0x00, 0x00, 0x01)

local function get_uci()
	if M._uci then return M._uci end
	return require("uci")
end

-- ─── Validation ──────────────────────────────────────────────────────────────
-- The address goes into UCI and into a file the forwarder reads; the key into
-- a cipher. Each is checked for shape before it goes anywhere.

function M.is_valid_host(s)
	return type(s) == "string" and #s > 0 and #s <= 253
		and s:match("^[%w%.%-]+$") ~= nil and not s:match("^[%.%-]")
end

function M.is_valid_port(p)
	p = tonumber(p)
	return p ~= nil and p >= 1 and p <= 65535 and p == math.floor(p)
end

function M.is_valid_key(k)
	return type(k) == "string" and #k == 64 and k:match("^%x+$") ~= nil
end

function M.is_valid_hash_id(h)
	return type(h) == "string" and #h == 16 and h:match("^%x+$") ~= nil
		and h ~= "0000000000000000"
end

-- A fresh hash_id: 16 hex digits, never all zero (the controller treats that
-- as "none").
function M.new_hash_id(crypto)
	crypto = crypto or M._crypto
	local id
	repeat
		id = crypto.bin_to_hex(crypto.random_iv(8))
	until id ~= "0000000000000000"
	return id
end

-- ─── Parsing ─────────────────────────────────────────────────────────────────

-- The block out of a system_cfg blob, nil when the blob carries no syslog.*
-- key at all (a partial push: apply() must then leave things as they are).
-- `target` is nil unless the block asks for a remote server it names validly.
function M.parse(sys_raw)
	if type(sys_raw) ~= "string" then return nil end
	local kv, seen = {}, false
	for line in (sys_raw .. "\n"):gmatch("([^\n]*)\n") do
		local k, v = line:match("^(syslog%.[^=]+)=(.*)$")
		if k then kv[k] = v; seen = true end
	end
	if not seen then return nil end
	local out = {
		enabled = kv["syslog.status"] == "enabled",
		remote  = kv["syslog.remote.status"] == "enabled",
		encrypt = kv["syslog.remote.encrypt"] == "enabled",
	}
	if not (out.enabled and out.remote) then return out end
	local ip, port, key = kv["syslog.remote.ip"], kv["syslog.remote.port"], kv["syslog.remote.key"]
	if ip == nil or ip == "" then return out end
	if not M.is_valid_host(ip) then
		io.stderr:write("remotelog: ignoring malformed syslog server " .. ("%q"):format(ip) .. "\n")
		return out
	end
	if port == nil or port == "" then
		port = out.encrypt and M.ENCRYPTED_PORT or M.PLAIN_PORT
	elseif not M.is_valid_port(port) then
		io.stderr:write("remotelog: ignoring malformed syslog port " .. ("%q"):format(port) .. "\n")
		return out
	end
	if out.encrypt and not M.is_valid_key(key) then
		-- Said without the value: it is the secret, or what was sent as one.
		io.stderr:write("remotelog: encrypted syslog asked for without a 64-hex-digit key -- not started\n")
		return out
	end
	out.target = {ip = ip, port = tonumber(port), encrypt = out.encrypt,
		key = out.encrypt and key:lower() or nil}
	return out
end

-- ─── The datagram ────────────────────────────────────────────────────────────

-- One sealed datagram. `nonce` is injectable for the tests; 12 random bytes
-- otherwise. Raises on a bad key or hash_id rather than sending something the
-- controller cannot attribute.
function M.seal(key_hex, hash_id, msg, nonce, crypto)
	crypto = crypto or M._crypto
	if not M.is_valid_key(key_hex) then error("remotelog: syslog key must be 64 hex digits") end
	if not M.is_valid_hash_id(hash_id) then error("remotelog: hash_id must be 16 hex digits") end
	local max = M.MAX_DATAGRAM - M.HEADER_LEN - M.TAG_LEN
	if #msg > max then msg = msg:sub(1, max) end
	nonce = nonce or crypto.random_iv(12)
	local header = MAGIC .. crypto.hex_to_bin(hash_id:lower()) .. nonce
	local ct, tag = crypto.aes256_gcm_encrypt(key_hex, nonce, msg, header)
	return header .. ct .. tag
end

-- The controller's side, for the tests: hash_id, message. Raises when the
-- datagram is not one or its tag does not verify.
function M.open(key_hex, datagram, crypto)
	crypto = crypto or M._crypto
	if type(datagram) ~= "string" or #datagram < M.HEADER_LEN + M.TAG_LEN
	   or datagram:sub(1, #MAGIC) ~= MAGIC then
		error("remotelog: not an encrypted syslog datagram")
	end
	local header = datagram:sub(1, M.HEADER_LEN)
	local nonce  = datagram:sub(18, M.HEADER_LEN)
	local ct     = datagram:sub(M.HEADER_LEN + 1, #datagram - M.TAG_LEN)
	local tag    = datagram:sub(#datagram - M.TAG_LEN + 1)
	local msg = crypto.aes256_gcm_decrypt(key_hex, nonce, ct, tag, header)
	return crypto.bin_to_hex(datagram:sub(10, 17)), msg
end

-- ─── The line ────────────────────────────────────────────────────────────────

local FACILITY = {kern = 0, user = 1, mail = 2, daemon = 3, auth = 4, syslog = 5,
	lpr = 6, news = 7, uucp = 8, cron = 9, authpriv = 10, ftp = 11,
	local0 = 16, local1 = 17, local2 = 18, local3 = 19, local4 = 20,
	local5 = 21, local6 = 22, local7 = 23}
local LEVEL = {emerg = 0, alert = 1, crit = 2, err = 3, warn = 4, warning = 4,
	notice = 5, info = 6, debug = 7}

-- "U6IW,00005e005310,6.6.77.15402:" -- what a UAP puts after its hostname.
function M.line_tag(model, mac, version)
	return ("%s,%s,%s:"):format(tostring(model or ""),
		tostring(mac or ""):lower():gsub("[^%x]", ""), tostring(version or ""))
end

-- A `logread` line ("Tue Nov 17 07:13:59 2026 daemon.err openuf[550]: msg")
-- as the syslog line a UAP would send
-- ("<27>Nov 17 07:13:59 <host> <tag> openuf[550]: msg"). A line of any other
-- shape goes out whole at user.info with `now`'s stamp: never dropped, the
-- reader of a log wants the odd line most.
function M.format_line(line, host, tag, now)
	local _, mon, day, hms, _, prio, rest =
		line:match("^(%a+)%s+(%a+)%s+(%d+)%s+(%d+:%d+:%d+)%s+(%d+)%s+(%S+)%s+(.*)$")
	if not mon then
		return ("<14>%s %s %s %s"):format(os.date("%b %e %H:%M:%S", now), host, tag, line)
	end
	local fac, lvl = prio:match("^([%w]+)%.([%w]+)$")
	local pri = 14
	if fac and FACILITY[fac] and LEVEL[lvl] then pri = FACILITY[fac] * 8 + LEVEL[lvl] end
	return ("<%d>%s %2d %s %s %s %s"):format(pri, mon, tonumber(day), hms, host, tag, rest)
end

-- ─── Plain remote syslog: logd ───────────────────────────────────────────────

local function system_section(cursor)
	local sec
	cursor:foreach("system", "system", function(s)
		if not sec then sec = s[".name"] end
	end)
	return sec
end

local LOG_OPTS = {"log_ip", "log_port", "log_proto"}

-- UCI system.@system[0].log_ip/log_port/log_proto <- target, or the board's own
-- values back when target is nil. What was there is stamped once; an option
-- that did not exist is restored by deleting it. Returns true when written.
function M.apply_plain(target)
	local cursor = get_uci().cursor()
	local sec = system_section(cursor)
	if not sec then return false end
	local managed = cursor:get("system", sec, "openuf_log_managed") == "1"
	if target then
		local want = {log_ip = target.ip, log_port = tostring(target.port), log_proto = "udp"}
		local same = managed
		for _, o in ipairs(LOG_OPTS) do
			if cursor:get("system", sec, o) ~= want[o] then same = false end
		end
		if same then return false end
		if not managed then
			for _, o in ipairs(LOG_OPTS) do
				local cur = cursor:get("system", sec, o)
				if cur then cursor:set("system", sec, "openuf_" .. o .. "_orig", cur) end
			end
			cursor:set("system", sec, "openuf_log_managed", "1")
		end
		for _, o in ipairs(LOG_OPTS) do cursor:set("system", sec, o, want[o]) end
		cursor:commit("system")
		io.stderr:write(("remotelog: syslog -> %s:%d (controller)\n"):format(target.ip, target.port))
		M._exec("/etc/init.d/log restart >/dev/null 2>&1")
		return true
	end
	if not managed then return false end
	for _, o in ipairs(LOG_OPTS) do
		local orig = cursor:get("system", sec, "openuf_" .. o .. "_orig")
		if orig then
			cursor:set("system", sec, o, orig)
			cursor:delete("system", sec, "openuf_" .. o .. "_orig")
		else
			cursor:delete("system", sec, o)
		end
	end
	cursor:delete("system", sec, "openuf_log_managed")
	cursor:commit("system")
	io.stderr:write("remotelog: syslog server restored to the board's own (controller turned remote logging off)\n")
	M._exec("/etc/init.d/log restart >/dev/null 2>&1")
	return true
end

-- ─── Encrypted remote syslog: the forwarder ──────────────────────────────────

-- The forwarder's whole input, flat key=value like /tmp/openuf-status.
function M.forwarder_conf(target, ident)
	return table.concat({
		"ip=" .. target.ip,
		"port=" .. tostring(target.port),
		"key=" .. target.key,
		"hash_id=" .. ident.hash_id,
		"host=" .. ident.host,
		"tag=" .. ident.tag,
	}, "\n") .. "\n"
end

function M.parse_conf(text)
	local c = {}
	for line in ((text or "") .. "\n"):gmatch("([^\n]*)\n") do
		local k, v = line:match("^([%w_]+)=(.*)$")
		if k then c[k] = v end
	end
	return c
end

-- pgrep's own shell contains the pattern, hence the bracket (rrmscan's
-- collector_stop has the long version of this story).
local MATCH      = "[l]ogfwd.lua"
function M.forwarder_running()
	local out = M._popen("pgrep -f '" .. MATCH .. "' 2>/dev/null") or ""
	return out:match("%d") ~= nil
end

-- The children first, then the processes that name logfwd.lua (the wrapping
-- shell and the forwarder). Killing only those left `logread -f` behind: it
-- is the wrapper's child and names nothing of ours, and on the test VM it
-- outlived a log line written after its reader was gone, so every restart
-- would have added one (2026-11-17). `pgrep -P` finds it by its parent.
function M.forwarder_stop()
	M._exec("for p in $(pgrep -f '" .. MATCH .. "'); do "
		.. "kill $(pgrep -P $p) 2>/dev/null; kill $p 2>/dev/null; done")
	M._exec("rm -f " .. M.CONF_FILE .. " 2>/dev/null")
end

-- Start the forwarder for target, or keep the one running when it already has
-- this configuration. Returns true when one was (re)started.
--
-- The file is made empty, closed to everyone but root, and only then given
-- the key: a file that is created with the key in it is readable for as long
-- as the chmod takes.
function M.forwarder_ensure(target, ident)
	local want = M.forwarder_conf(target, ident)
	if M.forwarder_running() then
		if M._read_file(M.CONF_FILE) == want then return false end
		M.forwarder_stop()
	end
	local f = M._open(M.CONF_FILE, "w")
	if not f then
		io.stderr:write("remotelog: cannot write " .. M.CONF_FILE .. "\n")
		return false
	end
	f:close()
	M._exec("chmod 600 " .. M.CONF_FILE)
	f = M._open(M.CONF_FILE, "w")
	if not f then return false end
	f:write(want)
	f:close()
	-- cwd is the daemon's (openuf/), which is where logfwd.lua finds its
	-- siblings. logread ends on its own: the first line it writes after the
	-- forwarder is gone raises SIGPIPE.
	M._exec("(logread -f 2>/dev/null | lua " .. M.FORWARDER .. " " .. M.CONF_FILE
		.. ") >/dev/null 2>&1 </dev/null &")
	return true
end

-- Can this board seal a datagram and follow its log at all?
function M.supported(crypto)
	crypto = crypto or M._crypto
	if not (crypto and crypto.gcm256_available and crypto.gcm256_available()) then return false end
	local out = M._popen("command -v logread 2>/dev/null") or ""
	return out:match("%S") ~= nil
end

-- ─── Apply ───────────────────────────────────────────────────────────────────

-- Bring the board in line with `target` (nil = no remote logging).
-- ident = {hash_id, host, tag}, needed only for an encrypted target.
-- Returns "plain", "encrypted" or "off": what is in force afterwards.
function M.sync(target, ident)
	if target and target.encrypt then
		M.apply_plain(nil)
		if not M.supported() then
			io.stderr:write("remotelog: encrypted syslog asked for, but this board cannot seal it "
				.. "(needs lua-openssl with AES-256-GCM, and logread) -- nothing is forwarded\n")
			M.forwarder_stop()
			return "off"
		end
		if not (ident and M.is_valid_hash_id(ident.hash_id)) then
			io.stderr:write("remotelog: no hash_id to sign encrypted syslog with -- nothing is forwarded\n")
			M.forwarder_stop()
			return "off"
		end
		if M.forwarder_ensure(target, ident) then
			io.stderr:write(("remotelog: encrypted syslog -> %s:%d (controller)\n")
				:format(target.ip, target.port))
		end
		return "encrypted"
	end
	if M.forwarder_running() then
		M.forwarder_stop()
		io.stderr:write("remotelog: encrypted syslog forwarding stopped\n")
	end
	M.apply_plain(target)
	return target and "plain" or "off"
end

return M
