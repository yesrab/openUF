-- Tests for openuf/devlogin.lua (Device SSH Authentication: the controller's
-- users.* block) and its wiring in inform.lua.
-- Run from project root: lua tests/run_tests.lua

OPENUF_TEST_MODE = true
local devlogin = dofile("openuf/devlogin.lua")
local inform   = dofile("openuf/inform.lua")
local state    = dofile("openuf/state.lua")

local HASH  = "$1$abcdefgh$0123456789ABCDEFGHIJKL"   -- the shape of MD5-crypt
local HASH2 = "$6$rounds=5000$saltsalt$" .. string.rep("x", 86)

local PASSWD = "root:x:0:0:root:/root:/bin/ash\nubnt:x:900:900:openuf bootstrap adoption:/etc/openuf:/usr/lib/openuf/hook/adopt-shell.sh\nnobody:*:65534:65534:nobody:/var:/bin/false\n"
local SHADOW = "root:$1$rootroot$rrrrrrrrrrrrrrrrrrrrrr:19000:0:99999:7:::\nubnt:!:::::::\nnobody:*:0:0:99999:7:::\n"

local function fresh(passwd, shadow)
	local rec = {files = {[devlogin.PASSWD] = passwd or PASSWD, [devlogin.SHADOW] = shadow or SHADOW},
		writes = {}}
	devlogin._read_file = function(p) return rec.files[p] end
	devlogin._write_file = function(p, c, private)
		if rec.readonly then return false end
		rec.files[p] = c
		rec.writes[#rec.writes + 1] = {path = p, private = private and true or false}
		return true
	end
	devlogin._time = function() return 86400 * 20000 + 5 end
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

local function line_of(text, name)
	for l in text:gmatch("[^\n]+") do if l:match("^" .. name .. ":") then return l end end
end

-- The block as every full push carries it (backlog row 14), the name changed.
local PUSH = table.concat({
	"users.status=enabled",
	"users.1.name=siteadmin",
	"users.1.password=" .. HASH,
	"users.1.status=enabled",
	"users.2.name=nobody",
	"users.2.shell=/bin/false",
	"users.2.status=enabled",
	"sshd.status=enabled",
	"sshd.auth.passwd=enabled",
	"sshd.1.ifname=br0",
}, "\n") .. "\n"

return {
	-- ── validation and parsing ────────────────────────────────────────────
	{
		name = "devlogin: a login name and a crypt hash are checked for the shapes that stay inside their field",
		fn = function()
			assert_true(devlogin.is_valid_name("siteadmin"), "plain")
			assert_true(devlogin.is_valid_name("_svc-1"), "underscore, digit, hyphen")
			assert_false(devlogin.is_valid_name("Root"), "capitals: 'Root' beside 'root' is a trap")
			assert_false(devlogin.is_valid_name("a:b"), "a colon is a second field")
			assert_false(devlogin.is_valid_name("a\nb:x:0:0"), "a newline is a second account")
			assert_false(devlogin.is_valid_name(""), "empty")
			assert_false(devlogin.is_valid_name(string.rep("a", 33)), "too long")
			assert_true(devlogin.is_valid_hash(HASH), "MD5-crypt")
			assert_true(devlogin.is_valid_hash(HASH2), "SHA-512 with rounds")
			assert_false(devlogin.is_valid_hash("plaintext"), "not a hash")
			assert_false(devlogin.is_valid_hash(""), "empty would be an account with no password")
			assert_false(devlogin.is_valid_hash(HASH .. ":0:0"), "a colon")
			assert_false(devlogin.is_valid_hash(HASH .. "\nroot::0"), "a newline")
		end
	},
	{
		name = "devlogin: the pushed block parses to the one login; nobody and its /bin/false are not one",
		fn = function()
			local p = devlogin.parse(PUSH)
			assert_true(p.enabled, "enabled")
			assert_eq(#p.users, 1, "one login")
			assert_eq(p.users[1].name, "siteadmin", "name")
			assert_eq(p.users[1].hash, HASH, "hash")
			assert_eq(#p.skipped, 0, "nothing to complain about")
			assert_nil(devlogin.parse("aaa.1.ssid=x\nsshd.status=enabled\n"), "no users key: a partial push")
		end
	},
	{
		name = "devlogin: a disabled block wants no login; malformed rows are skipped with a reason and no secret",
		fn = function()
			local off = devlogin.parse("users.status=disabled\nusers.1.name=siteadmin\nusers.1.password=" .. HASH .. "\n")
			assert_false(off.enabled, "disabled")
			assert_eq(#off.users, 0, "no login")
			local p = devlogin.parse(table.concat({"users.status=enabled",
				"users.1.name=Bad Name", "users.1.password=" .. HASH,
				"users.2.name=plain", "users.2.password=hunter2secret",
				"users.3.name=dup", "users.3.password=" .. HASH,
				"users.4.name=dup", "users.4.password=" .. HASH,
				"users.5.name=off", "users.5.password=" .. HASH, "users.5.status=disabled"}, "\n") .. "\n")
			assert_eq(#p.users, 1, "only the well-formed, enabled, first-named one")
			assert_eq(p.users[1].name, "dup", "which")
			assert_eq(#p.skipped, 3, "three reasons")
			assert_true(table.concat(p.skipped, " "):find("hunter2secret", 1, true) == nil,
				"what arrived where a hash belongs is not repeated")
		end
	},
	-- ── passwd and shadow ─────────────────────────────────────────────────
	{
		name = "devlogin: nothing at all without trust",
		fn = function()
			local rec = fresh()
			local managed, changes = devlogin.sync({{name = "siteadmin", hash = HASH}}, {}, false)
			assert_eq(#managed, 0, "no account")
			assert_eq(#changes, 0, "no change")
			assert_eq(#rec.writes, 0, "no file written")
		end
	},
	{
		name = "devlogin: a new login is a uid-0 passwd line and a shadow line with the pushed hash, shadow written first and closed",
		fn = function()
			local rec = fresh()
			local managed, changes = devlogin.sync({{name = "siteadmin", hash = HASH}}, {}, true)
			assert_eq(managed[1], "siteadmin", "now openUF's")
			assert_eq(changes[1], "added siteadmin", "said")
			assert_eq(line_of(rec.files[devlogin.PASSWD], "siteadmin"),
				"siteadmin:x:0:0:UniFi device login:/root:/bin/ash", "passwd line")
			assert_eq(line_of(rec.files[devlogin.SHADOW], "siteadmin"),
				"siteadmin:" .. HASH .. ":20000:0:99999:7:::", "shadow line, dated today")
			assert_eq(rec.writes[1].path, devlogin.SHADOW, "the hash is in place before the account exists")
			assert_true(rec.writes[1].private, "shadow written closed")
			assert_false(rec.writes[2].private, "passwd stays readable")
			assert_eq(line_of(rec.files[devlogin.PASSWD], "root"), "root:x:0:0:root:/root:/bin/ash", "root untouched")
			assert_contains(rec.files[devlogin.SHADOW], "root:$1$rootroot$", "root's hash untouched")
		end
	},
	{
		name = "devlogin: the same push again writes nothing; a new password rewrites only the hash",
		fn = function()
			local rec = fresh()
			local managed = devlogin.sync({{name = "siteadmin", hash = HASH}}, {}, true)
			local n = #rec.writes
			local _, changes = devlogin.sync({{name = "siteadmin", hash = HASH}}, managed, true)
			assert_eq(#changes, 0, "nothing changed")
			assert_eq(#rec.writes, n, "nothing written")
			_, changes = devlogin.sync({{name = "siteadmin", hash = HASH2}}, managed, true)
			assert_eq(changes[1], "updated siteadmin", "said")
			assert_eq(#rec.writes, n + 1, "one file")
			assert_eq(rec.writes[n + 1].path, devlogin.SHADOW, "shadow only")
			assert_contains(line_of(rec.files[devlogin.SHADOW], "siteadmin"), HASH2, "the new hash")
		end
	},
	{
		name = "devlogin: an account that already exists and is not openUF's is never touched",
		fn = function()
			for _, name in ipairs({"root", "ubnt", "nobody"}) do
				local rec = fresh()
				local managed, changes = devlogin.sync({{name = name, hash = HASH}}, {}, true)
				assert_eq(#managed, 0, name .. ": not adopted into the ledger")
				assert_contains(changes[1], "skipped " .. name, name .. ": said")
				assert_eq(#rec.writes, 0, name .. ": no file written")
			end
		end
	},
	{
		name = "devlogin: a login the controller no longer pushes is removed, and only that one",
		fn = function()
			local rec = fresh()
			local managed = devlogin.sync({{name = "siteadmin", hash = HASH}, {name = "second", hash = HASH2}}, {}, true)
			assert_eq(#managed, 2, "two")
			local left, changes = devlogin.sync({{name = "second", hash = HASH2}}, managed, true)
			assert_eq(#left, 1, "one left")
			assert_eq(changes[1], "removed siteadmin", "said")
			assert_nil(line_of(rec.files[devlogin.PASSWD], "siteadmin"), "gone from passwd")
			assert_nil(line_of(rec.files[devlogin.SHADOW], "siteadmin"), "gone from shadow")
			assert_not_nil(line_of(rec.files[devlogin.PASSWD], "second"), "the other stays")
			left = devlogin.sync({}, left, true)
			assert_eq(#left, 0, "none")
			assert_eq(rec.files[devlogin.PASSWD], PASSWD, "passwd exactly as it was before openUF")
			assert_eq(rec.files[devlogin.SHADOW], SHADOW, "shadow exactly as it was before openUF")
		end
	},
	{
		name = "devlogin: a file that cannot be written leaves the ledger as it was",
		fn = function()
			local rec = fresh()
			rec.readonly = true
			local managed, why = devlogin.sync({{name = "siteadmin", hash = HASH}}, {}, true)
			assert_nil(managed, "no new ledger")
			assert_contains(why, "cannot write", "why")
			devlogin._read_file = function() return nil end
			managed, why = devlogin.sync({{name = "siteadmin", hash = HASH}}, {}, true)
			assert_nil(managed, "unreadable files: nothing")
			assert_contains(why, "cannot read", "why")
		end
	},
	-- ── inform.lua ────────────────────────────────────────────────────────
	{
		name = "inform: the device login is off by default, and with it off a push creates nothing",
		fn = function()
			local rec = fresh()
			local o = inform._devlogin
			inform._devlogin = devlogin
			local st = {adopted = true, authkey = string.rep("ab", 16), cfgversion = "v1"}
			local ok, err = pcall(function()
				assert_false(inform._devlogin_push(st, {config = {}}, PUSH, true), "nothing")
				assert_eq(#rec.writes, 0, "no file written")
				assert_nil(st.device_logins, "no ledger")
			end)
			inform._devlogin = o
			if not ok then error(err, 0) end
		end
	},
	{
		name = "inform: with device_login a trusted push creates the login and keeps its name in state",
		fn = function()
			local rec = fresh()
			local o = inform._devlogin
			inform._devlogin = devlogin
			local st = {adopted = true, authkey = string.rep("ab", 16), cfgversion = "v1"}
			local out
			local ok, err = pcall(function()
				out = with_stderr(function()
					assert_true(inform._devlogin_push(st, {config = {device_login = true}}, PUSH, true), "created")
				end)
				assert_eq(st.device_logins[1], "siteadmin", "ledger")
				assert_not_nil(line_of(rec.files[devlogin.PASSWD], "siteadmin"), "account")
				assert_true(out:find(HASH, 1, true) == nil, "the hash is not logged")
				-- A push without the block changes nothing.
				assert_false(inform._devlogin_push(st, {config = {device_login = true}}, "aaa.1.ssid=x\n", true), "partial push")
				assert_eq(st.device_logins[1], "siteadmin", "still there")
				-- The controller turned Device Authentication off.
				with_stderr(function()
					inform._devlogin_push(st, {config = {device_login = true}}, "users.status=disabled\n", true)
				end)
				assert_nil(st.device_logins, "ledger empty")
				assert_nil(line_of(rec.files[devlogin.PASSWD], "siteadmin"), "account gone")
			end)
			inform._devlogin = o
			if not ok then error(err, 0) end
			assert_contains(out, "added siteadmin", "said")
		end
	},
	{
		-- Before adoption the inform channel is plain HTTP under the key every
		-- UniFi device ships with: anyone on the path can forge a setparam.
		name = "inform: a response the default key could have sealed creates no login, even one that adopts the device",
		fn = function()
			local rec = fresh()
			local o = inform._devlogin
			inform._devlogin = devlogin
			local ok, err = pcall(function()
				local cfg = {config = {device_login = true}}
				assert_false(inform._trusted({adopted = false, authkey = state.DEFAULT_KEY}), "unadopted")
				assert_false(inform._trusted({adopted = true, authkey = state.DEFAULT_KEY}), "adopted on the default key")
				assert_true(inform._trusted({adopted = true, authkey = string.rep("ab", 16)}), "adopted, own key")
				-- Never adopted: nothing, and nothing to ask again for.
				local st = {adopted = false, authkey = state.DEFAULT_KEY, cfgversion = "v1"}
				local out = with_stderr(function()
					assert_false(inform._devlogin_push(st, cfg, PUSH, false), "nothing")
				end)
				assert_eq(#rec.writes, 0, "no file written")
				assert_eq(st.cfgversion, "v1", "cfgversion untouched")
				assert_contains(out, "default key", "said why")
				-- The response itself brought the key (trusted_response was read
				-- before it did): still nothing now, and the configuration is
				-- asked for once more, under that key.
				st = {adopted = true, authkey = string.rep("ab", 16), cfgversion = "v1"}
				with_stderr(function()
					assert_false(inform._devlogin_push(st, cfg, PUSH, false), "nothing from THIS response")
				end)
				assert_eq(#rec.writes, 0, "no file written")
				assert_eq(st.cfgversion, "", "the controller will push again")
			end)
			inform._devlogin = o
			if not ok then error(err, 0) end
		end
	},
	{
		name = "inform: switching device_login off, or forgetting the controller, removes the logins openUF made",
		fn = function()
			local rec = fresh()
			local o = {inform._devlogin, inform._remotelog, inform._applyguard}
			inform._devlogin = devlogin
			inform._remotelog = {sync = function() end}
			inform._applyguard = {discard = function() end}
			local ok, err = pcall(function()
				local st = {adopted = true, authkey = string.rep("ab", 16), cfgversion = "v1"}
				with_stderr(function()
					inform._devlogin_push(st, {config = {device_login = true}}, PUSH, true)
					assert_not_nil(line_of(rec.files[devlogin.PASSWD], "siteadmin"), "made")
					inform._devlogin_push(st, {config = {}}, PUSH, true)      -- option off, next push
				end)
				assert_nil(line_of(rec.files[devlogin.PASSWD], "siteadmin"), "option off: gone")
				assert_nil(st.device_logins, "ledger empty")
				with_stderr(function()
					inform._devlogin_push(st, {config = {device_login = true}}, PUSH, true)
					inform._forget_controller({device_logins = {"siteadmin"}}, {})
				end)
				assert_nil(line_of(rec.files[devlogin.PASSWD], "siteadmin"), "forgotten: gone")
				assert_nil(line_of(rec.files[devlogin.SHADOW], "siteadmin"), "and its hash with it")
				assert_not_nil(line_of(rec.files[devlogin.PASSWD], "root"), "root stays")
			end)
			inform._devlogin, inform._remotelog, inform._applyguard = o[1], o[2], o[3]
			if not ok then error(err, 0) end
		end
	},
	{
		name = "inform: the users keys devlogin reads are recognised; sshd stays in the ledger",
		fn = function()
			local function known(k)
				for _, pat in ipairs(inform.RECOGNIZED_SYSTEM_CFG) do
					if k:match(pat) then return true end
				end
				return false
			end
			for _, k in ipairs({"users.status", "users.1.name", "users.1.password", "users.2.shell", "users.2.status"}) do
				assert_true(known(k), k .. " is read")
			end
			assert_false(known("sshd.status"), "not read, not claimed")
			assert_false(known("sshd.auth.passwd"), "not read, not claimed")
		end
	},
}
