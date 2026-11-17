-- Tests for openuf/remotelog.lua and openuf/logfwd.lua (the controller's
-- Remote Logging: plain through logd, encrypted through the forwarder).
-- Run from project root: lua tests/run_tests.lua

OPENUF_TEST_MODE = true
local remotelog = dofile("openuf/remotelog.lua")
local logfwd    = dofile("openuf/logfwd.lua")
local crypto    = dofile("openuf/crypto.lua")

local KEY  = string.rep("0123456789abcdef", 4)   -- 64 hex digits
local HASH = "00005e0053100001"

-- A cipher that is not one, so the datagram's LAYOUT is tested on a machine
-- with no lua-openssl: the "ciphertext" is the plaintext reversed and the tag
-- names the additional data it was given.
local function fake_crypto()
	local c = {calls = {}}
	c.hex_to_bin, c.bin_to_hex = crypto.hex_to_bin, crypto.bin_to_hex
	c.random_iv = function(n) return string.rep("N", n) end
	c.aes256_gcm_encrypt = function(key, iv, pt, aad)
		c.calls[#c.calls + 1] = {key = key, iv = iv, pt = pt, aad = aad}
		return pt:reverse(), ("T%015d"):format(#aad)
	end
	c.gcm256_available = function() return true end
	return c
end

local function mock_uci(db, commits)
	local cursor = {}
	function cursor:get(c, s, o)
		local sec = db[c] and db[c][s]
		if not sec then return nil end
		if o == nil then return sec[".type"] end
		return sec[o]
	end
	function cursor:set(c, s, o, v) db[c][s][o] = tostring(v); return true end
	function cursor:delete(c, s, o) if db[c] and db[c][s] then db[c][s][o] = nil end; return true end
	function cursor:commit(c) commits[#commits + 1] = c; return true end
	function cursor:foreach(c, t, fn)
		for _, sec in pairs(db[c] or {}) do if sec[".type"] == t then fn(sec) end end
	end
	return {cursor = function() return cursor end}
end

-- Every seam stubbed; returns what the module did.
local function fresh(db, opts)
	opts = opts or {}
	local rec = {commits = {}, cmds = {}, files = {}, running = opts.running or false}
	remotelog._uci = mock_uci(db or {system = {cfg01 = {[".name"] = "cfg01", [".type"] = "system"}}}, rec.commits)
	remotelog._exec = function(cmd)
		rec.cmds[#rec.cmds + 1] = cmd
		if cmd:find("kill $p", 1, true) then rec.running = false end
		if cmd:find("logread %-f") then rec.running = true end
		return 0
	end
	remotelog._popen = function(cmd)
		if cmd:find("pgrep", 1, true) then return rec.running and "4242\n" or "" end
		if cmd:find("command -v logread", 1, true) then return opts.no_logread and "" or "/sbin/logread\n" end
		return ""
	end
	remotelog._read_file = function(p) return rec.files[p] end
	remotelog._open = function(p)
		rec.files[p] = ""
		return {write = function(_, s) rec.files[p] = rec.files[p] .. s end, close = function() end}
	end
	remotelog._crypto = opts.crypto or fake_crypto()
	return rec
end

local function with_stderr(fn)
	local buf, real = {}, io.stderr
	io.stderr = {write = function(_, ...) for _, s in ipairs({...}) do buf[#buf + 1] = s end end}
	local ok, err = pcall(fn)
	io.stderr = real
	if not ok then error(err, 0) end
	return table.concat(buf)
end

local function cfg(lines) return table.concat(lines, "\n") .. "\n" end

local ENCRYPTED = cfg({
	"syslog.status=enabled",
	"syslog.remote.status=enabled",
	"syslog.remote.encrypt=enabled",
	"syslog.remote.ip=192.0.2.10",
	"syslog.remote.port=5514",
	"syslog.remote.key=" .. KEY:upper(),
})

return {
	-- ── parse ─────────────────────────────────────────────────────────────
	{
		name = "remotelog: a blob with no syslog key parses to nil (a partial push changes nothing)",
		fn = function()
			assert_nil(remotelog.parse("system.timezone=UTC\naaa.1.ssid=x\n"), "no block")
			assert_nil(remotelog.parse(nil), "no blob")
		end
	},
	{
		name = "remotelog: a plain syslog server parses to a target with the default port",
		fn = function()
			local p = remotelog.parse(cfg({"syslog.status=enabled", "syslog.remote.status=enabled",
				"syslog.remote.ip=192.0.2.20"}))
			assert_true(p.enabled and p.remote, "on")
			assert_false(p.encrypt, "not encrypted")
			assert_eq(p.target.ip, "192.0.2.20", "server")
			assert_eq(p.target.port, 514, "syslog's own port when none is pushed")
			assert_nil(p.target.key, "no key for a plain server")
		end
	},
	{
		name = "remotelog: the encrypted block parses to a target with its key, lower-cased",
		fn = function()
			local p = remotelog.parse(ENCRYPTED)
			assert_true(p.target.encrypt, "encrypted")
			assert_eq(p.target.port, 5514, "the pushed port")
			assert_eq(p.target.key, KEY, "the key")
			local q = remotelog.parse(cfg({"syslog.status=enabled", "syslog.remote.status=enabled",
				"syslog.remote.encrypt=enabled", "syslog.remote.ip=192.0.2.10", "syslog.remote.key=" .. KEY}))
			assert_eq(q.target.port, 5514, "the controller's listener when no port is pushed")
		end
	},
	{
		name = "remotelog: disabled, or no server, parses to a block without a target",
		fn = function()
			local off = remotelog.parse("syslog.status=disabled\nsyslog.remote.ip=192.0.2.10\n")
			assert_not_nil(off, "the block is there")
			assert_nil(off.target, "status disabled: nothing to send to")
			local local_only = remotelog.parse("syslog.status=enabled\nsyslog.remote.status=disabled\n")
			assert_nil(local_only.target, "remote disabled")
			assert_nil(remotelog.parse("syslog.status=enabled\nsyslog.remote.status=enabled\n").target, "no ip")
		end
	},
	{
		name = "remotelog: a malformed server, port or key is refused and never echoes the key",
		fn = function()
			local out = with_stderr(function()
				assert_nil(remotelog.parse(cfg({"syslog.status=enabled", "syslog.remote.status=enabled",
					"syslog.remote.ip=192.0.2.10; reboot"})).target, "shell in the address")
				assert_nil(remotelog.parse(cfg({"syslog.status=enabled", "syslog.remote.status=enabled",
					"syslog.remote.ip=192.0.2.10", "syslog.remote.port=99999"})).target, "port out of range")
				assert_nil(remotelog.parse(cfg({"syslog.status=enabled", "syslog.remote.status=enabled",
					"syslog.remote.encrypt=enabled", "syslog.remote.ip=192.0.2.10",
					"syslog.remote.key=SECRETSECRET"})).target, "a key that is not 64 hex digits")
			end)
			assert_contains(out, "malformed syslog server", "said")
			assert_contains(out, "without a 64-hex-digit key", "said")
			assert_true(out:find("SECRETSECRET", 1, true) == nil, "the would-be key is not logged")
		end
	},
	-- ── the datagram ──────────────────────────────────────────────────────
	{
		name = "remotelog: a sealed datagram is magic, hash_id, nonce, ciphertext, tag, with the header as AAD",
		fn = function()
			local fc = fake_crypto()
			local d = remotelog.seal(KEY, HASH, "hello", nil, fc)
			assert_bytes_eq(d:sub(1, 9), string.char(0xAB, 0xCD, 0xDC, 0xBA, 0x01, 0, 0, 0, 1), "magic and version")
			assert_eq(crypto.bin_to_hex(d:sub(10, 17)), HASH, "the device's hash_id")
			assert_eq(d:sub(18, 29), string.rep("N", 12), "a 12-byte nonce")
			assert_eq(d:sub(30, 34), "olleh", "then the ciphertext")
			assert_eq(#d, 29 + 5 + 16, "and a 16-byte tag")
			assert_eq(fc.calls[1].aad, d:sub(1, 29), "additional data is bytes 0..28")
			assert_eq(fc.calls[1].iv, string.rep("N", 12), "the cipher gets the same nonce")
			assert_eq(fc.calls[1].key, KEY, "and the pushed key")
		end
	},
	{
		name = "remotelog: a message past the controller's 4096-byte buffer is cut, not the tag",
		fn = function()
			local d = remotelog.seal(KEY, HASH, string.rep("x", 5000), nil, fake_crypto())
			assert_eq(#d, 4096, "exactly the listener's buffer")
		end
	},
	{
		name = "remotelog: seal refuses a bad key or hash_id rather than send what cannot be attributed",
		fn = function()
			local fc = fake_crypto()
			assert_error(function() remotelog.seal("abcd", HASH, "x", nil, fc) end, "short key")
			assert_error(function() remotelog.seal(KEY, "0000000000000000", "x", nil, fc) end, "all-zero hash_id")
			assert_error(function() remotelog.seal(KEY, "xyz", "x", nil, fc) end, "not hex")
		end
	},
	{
		name = "remotelog: a sealed datagram opens with the real cipher, and not with a changed byte",
		fn = function()
			if not crypto.gcm256_available() then
				if os.getenv("OPENUF_REQUIRE_GCM") == "1" then
					error("OPENUF_REQUIRE_GCM=1 but no AES-256-GCM backend -- CI must install lua-openssl")
				end
				print("SKIP  encrypted syslog round trip (no backend -- luarocks install --local openssl)")
				return
			end
			local line = "<30>Nov 17 07:13:59 testap U6IW,00005e005310,6.6.77.15402: openuf: hello"
			local d = remotelog.seal(KEY, HASH, line, nil, crypto)
			local id, msg = remotelog.open(KEY, d, crypto)
			assert_eq(id, HASH, "hash_id read back")
			assert_eq(msg, line, "message read back")
			local flipped = d:sub(1, 12) .. string.char((d:byte(13) + 1) % 256) .. d:sub(14)
			assert_error(function() remotelog.open(KEY, flipped, crypto) end,
				"a changed header byte fails the tag (the header is authenticated)")
			assert_error(function() remotelog.open(string.rep("f", 64), d, crypto) end, "another key")
		end
	},
	-- ── the line ──────────────────────────────────────────────────────────
	{
		name = "remotelog: a logread line becomes the syslog line a UAP sends",
		fn = function()
			local tag = remotelog.line_tag("U6IW", "00:00:5E:00:53:10", "6.6.77.15402")
			assert_eq(tag, "U6IW,00005e005310,6.6.77.15402:", "MODEL,mac12,version:")
			assert_eq(remotelog.format_line("Tue Nov 17 07:13:59 2026 daemon.err openuf[550]: inform failed",
				"testap", tag),
				"<27>Nov 17 07:13:59 testap U6IW,00005e005310,6.6.77.15402: openuf[550]: inform failed",
				"daemon.err is 3*8+3")
			assert_eq(remotelog.format_line("Mon Nov  2 01:02:03 2026 kern.warn kernel: x", "ap", tag),
				"<4>Nov  2 01:02:03 ap U6IW,00005e005310,6.6.77.15402: kernel: x",
				"a one-digit day keeps its column")
		end
	},
	{
		name = "remotelog: a line of another shape goes out whole at user.info",
		fn = function()
			local out = remotelog.format_line("no timestamp here", "ap", "T:", 0)
			assert_true(out:match("^<14>%a%a%a [ %d]%d %d%d:%d%d:%d%d ap T: no timestamp here$") ~= nil, out)
		end
	},
	-- ── plain: logd ───────────────────────────────────────────────────────
	{
		name = "remotelog: a plain target lands in logd's UCI options, stamped, and logd restarts",
		fn = function()
			local db = {system = {cfg01 = {[".name"] = "cfg01", [".type"] = "system", log_ip = "198.51.100.5"}}}
			local rec = fresh(db)
			local out = with_stderr(function()
				assert_true(remotelog.apply_plain({ip = "192.0.2.20", port = 514}), "written")
			end)
			local s = db.system.cfg01
			assert_eq(s.log_ip, "192.0.2.20", "server")
			assert_eq(s.log_port, "514", "port")
			assert_eq(s.log_proto, "udp", "udp")
			assert_eq(s.openuf_log_managed, "1", "stamped")
			assert_eq(s.openuf_log_ip_orig, "198.51.100.5", "what was there is kept")
			assert_nil(s.openuf_log_port_orig, "an option that did not exist has no stamp")
			assert_eq(#rec.commits, 1, "one commit")
			assert_contains(rec.cmds[1], "/etc/init.d/log restart", "logd told")
			assert_contains(out, "192.0.2.20:514", "said")
			assert_false(remotelog.apply_plain({ip = "192.0.2.20", port = 514}), "same again: nothing written")
			assert_eq(#rec.commits, 1, "no second commit")
		end
	},
	{
		name = "remotelog: turning it off puts the board's own syslog server back",
		fn = function()
			local db = {system = {cfg01 = {[".name"] = "cfg01", [".type"] = "system", log_ip = "198.51.100.5"}}}
			fresh(db)
			with_stderr(function()
				remotelog.apply_plain({ip = "192.0.2.20", port = 1514})
				assert_true(remotelog.apply_plain(nil), "restored")
			end)
			local s = db.system.cfg01
			assert_eq(s.log_ip, "198.51.100.5", "the original server")
			assert_nil(s.log_port, "an option openUF added is gone")
			assert_nil(s.log_proto, "an option openUF added is gone")
			assert_nil(s.openuf_log_managed, "stamp gone")
			assert_nil(s.openuf_log_ip_orig, "stamp gone")
		end
	},
	{
		name = "remotelog: off on a board openUF never configured touches nothing",
		fn = function()
			local db = {system = {cfg01 = {[".name"] = "cfg01", [".type"] = "system", log_ip = "198.51.100.5"}}}
			local rec = fresh(db)
			assert_false(remotelog.apply_plain(nil), "nothing to restore")
			assert_eq(db.system.cfg01.log_ip, "198.51.100.5", "the operator's own server stays")
			assert_eq(#rec.commits, 0, "no commit")
			assert_eq(#rec.cmds, 0, "no restart")
		end
	},
	-- ── encrypted: the forwarder ──────────────────────────────────────────
	{
		name = "remotelog: the forwarder gets its key through a 0600 file, never a command line",
		fn = function()
			local rec = fresh()
			local target = remotelog.parse(ENCRYPTED).target
			local ident = {hash_id = HASH, host = "testap", tag = "U6IW,00005e005310,6.6.77.15402:"}
			assert_true(remotelog.forwarder_ensure(target, ident), "started")
			assert_eq(rec.cmds[1], "chmod 600 " .. remotelog.CONF_FILE, "closed before the key is written")
			assert_contains(rec.cmds[2], "logread -f", "follows the log")
			assert_contains(rec.cmds[2], "lua logfwd.lua " .. remotelog.CONF_FILE, "into the forwarder")
			for _, c in ipairs(rec.cmds) do
				assert_true(c:find(KEY, 1, true) == nil, "no command carries the key: " .. c)
			end
			local conf = remotelog.parse_conf(rec.files[remotelog.CONF_FILE])
			assert_eq(conf.key, KEY, "the file does")
			assert_eq(conf.ip, "192.0.2.10", "server")
			assert_eq(conf.port, "5514", "port")
			assert_eq(conf.hash_id, HASH, "hash_id")
			assert_eq(conf.tag, ident.tag, "tag")
		end
	},
	{
		name = "remotelog: a running forwarder with the same configuration is left alone; a changed one restarts",
		fn = function()
			local rec = fresh()
			local target = remotelog.parse(ENCRYPTED).target
			local ident = {hash_id = HASH, host = "testap", tag = "T:"}
			remotelog.forwarder_ensure(target, ident)
			local n = #rec.cmds
			assert_false(remotelog.forwarder_ensure(target, ident), "nothing to do")
			assert_eq(#rec.cmds, n, "no command")
			ident.tag = "U:"   -- a virtual firmware upgrade changes the tag
			assert_true(remotelog.forwarder_ensure(target, ident), "restarted")
			assert_contains(rec.cmds[n + 1], "pgrep -f '[l]ogfwd.lua'", "the old one killed first")
			assert_contains(rec.cmds[n + 1], "kill $(pgrep -P $p)", "its logread child with it")
		end
	},
	{
		name = "remotelog: sync runs the forwarder for an encrypted target and clears logd's server",
		fn = function()
			local db = {system = {cfg01 = {[".name"] = "cfg01", [".type"] = "system",
				log_ip = "192.0.2.20", log_port = "514", log_proto = "udp", openuf_log_managed = "1"}}}
			local rec = fresh(db)
			local mode
			local out = with_stderr(function()
				mode = remotelog.sync(remotelog.parse(ENCRYPTED).target,
					{hash_id = HASH, host = "testap", tag = "T:"})
			end)
			assert_eq(mode, "encrypted", "in force")
			assert_nil(db.system.cfg01.log_ip, "the plain server from an earlier push is gone")
			assert_true(rec.running, "forwarder running")
			assert_contains(out, "encrypted syslog -> 192.0.2.10:5514", "said")
		end
	},
	{
		name = "remotelog: sync refuses encrypted syslog without a cipher, logread or hash_id, loudly",
		fn = function()
			local target = remotelog.parse(ENCRYPTED).target
			local no_cipher = fake_crypto()
			no_cipher.gcm256_available = function() return false end
			local rec = fresh(nil, {crypto = no_cipher})
			local out = with_stderr(function()
				assert_eq(remotelog.sync(target, {hash_id = HASH, host = "a", tag = "T:"}), "off", "no cipher")
			end)
			assert_contains(out, "cannot seal", "said why")
			assert_false(rec.running, "nothing started")
			rec = fresh(nil, {no_logread = true})
			with_stderr(function()
				assert_eq(remotelog.sync(target, {hash_id = HASH, host = "a", tag = "T:"}), "off", "no logread")
			end)
			rec = fresh()
			out = with_stderr(function()
				assert_eq(remotelog.sync(target, {host = "a", tag = "T:"}), "off", "no hash_id")
			end)
			assert_contains(out, "no hash_id", "said why")
			assert_false(rec.running, "nothing started")
		end
	},
	{
		name = "remotelog: sync(nil) stops a running forwarder and removes its key file",
		fn = function()
			local rec = fresh(nil, {running = true})
			rec.files[remotelog.CONF_FILE] = "key=" .. KEY .. "\n"
			local out = with_stderr(function()
				assert_eq(remotelog.sync(nil), "off", "off")
			end)
			assert_false(rec.running, "killed")
			assert_contains(table.concat(rec.cmds, "\n"), "rm -f " .. remotelog.CONF_FILE, "key file removed")
			assert_contains(out, "forwarding stopped", "said")
		end
	},
	-- ── logfwd.lua ────────────────────────────────────────────────────────
	{
		name = "logfwd: the budget is a burst of 100 and 50 a second after that",
		fn = function()
			local tokens, go = logfwd.BURST, nil
			local sent = 0
			for _ = 1, 150 do
				tokens, go = logfwd.take(tokens, 0)
				if go then sent = sent + 1 end
			end
			assert_eq(sent, 100, "100 at once, the rest dropped")
			tokens, go = logfwd.take(tokens, 1)
			assert_true(go, "a second later there is budget again")
			assert_true(tokens <= 50, "50 lines' worth of it")
		end
	},
	{
		name = "logfwd: each line is formatted, sealed and sent as one datagram; a failing send is said once",
		fn = function()
			local fc = fake_crypto()
			remotelog._crypto = fc
			local path = os.tmpname()
			local f = io.open(path, "w")
			f:write(remotelog.forwarder_conf({ip = "192.0.2.10", port = 5514, key = KEY},
				{hash_id = HASH, host = "testap", tag = "U6IW,00005e005310,6.6.77.15402:"}))
			f:close()
			local sent, fail = {}, false
			local udp = {send = function(_, d)
				if fail then return nil, "refused" end
				sent[#sent + 1] = d
				return #d
			end}
			local input = {"Tue Nov 17 07:13:59 2026 daemon.info openuf[1]: one", "",
				"Tue Nov 17 07:14:00 2026 daemon.info openuf[1]: two"}
			local i = 0
			local out = with_stderr(function()
				logfwd.run(path, {remotelog = remotelog, crypto = fc, udp = udp, clock = function() return 0 end,
					lines = function() i = i + 1; return input[i] end})
				assert_eq(#sent, 2, "two lines, two datagrams (the empty line is not one)")
				assert_eq(fc.calls[1].pt, "<30>Nov 17 07:13:59 testap U6IW,00005e005310,6.6.77.15402: openuf[1]: one",
					"formatted before it is sealed")
				assert_eq(crypto.bin_to_hex(sent[1]:sub(10, 17)), HASH, "under this device's hash_id")
				fail, i = true, 0
				logfwd.run(path, {remotelog = remotelog, crypto = fc, udp = udp, clock = function() return 0 end,
					lines = function() i = i + 1; return input[i] end})
			end)
			os.remove(path)
			local _, n = out:gsub("send failed", "")
			assert_eq(n, 1, "one line for two failed sends")
		end
	},
	{
		name = "logfwd: an incomplete conf file is refused",
		fn = function()
			local path = os.tmpname()
			local f = io.open(path, "w"); f:write("ip=192.0.2.10\nport=5514\n"); f:close()
			local ok, err = pcall(logfwd.run, path, {remotelog = remotelog, crypto = fake_crypto(),
				udp = {send = function() end}, lines = function() return nil end})
			os.remove(path)
			assert_false(ok, "no key, no forwarder")
			assert_contains(tostring(err), "incomplete", "said why")
		end
	},
}
