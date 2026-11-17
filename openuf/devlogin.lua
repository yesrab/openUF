--[[
	Device SSH Authentication: the controller's `users.*` block.

	Settings -> System -> Advanced -> Device Authentication is the login an
	admin expects to SSH into every adopted device with. Every full push
	carries it (REVERSE-ENGINEERING.md backlog row 14, seen on AP2 from the
	first run of the unhandled ledger):

	  users.status=enabled
	  users.1.name=<the site's SSH username>
	  users.1.password=$1$...          (a crypt(3) hash: MD5-crypt on 10.x)
	  users.2.name=nobody  users.2.shell=/bin/false
	  sshd.status=enabled  sshd.auth.passwd=enabled  sshd.1.ifname=br0

	openUF ignored it: the AP was reachable only by whatever its own root
	account was. With conf.lua `device_login = true` the pushed login exists
	on the AP, with the pushed hash, and stops existing when the controller
	stops pushing it or forgets the device.

	This is the one openUF feature that creates a way IN, so its rules are
	narrow and each is enforced here, not left to the caller:

	  - OFF unless the operator turns it on.
	  - Never before adoption. Until then the inform channel is plain HTTP
	    under a key the whole world knows, and anyone on the path can forge a
	    setparam; honouring `users.*` there would be handing out root. The
	    caller passes `trusted` (adopted, and not on the default key) and
	    sync() does nothing without it.
	  - Only accounts this module created are ever changed or removed. They
	    are named in state.json (`device_logins`). A pushed name that already
	    exists on the AP and is not in that list -- root, the bootstrap
	    account, a system user, somebody's own login -- is skipped, loudly.
	  - The name and the hash are shape-checked before they reach a file
	    that login reads: a `:` or a newline in either is a second account.
	  - The account is uid 0 with /bin/ash and root's home. That is what a
	    UniFi device login is (an admin login, not a guest), and on OpenWrt a
	    non-root user can administer nothing. It is also why the rules above
	    are what they are.
	  - /etc/passwd and /etc/shadow are replaced by rename, never edited in
	    place, and shadow's copy is closed to everyone before the hash is
	    written into it.

	Not done: `sshd.*`. Whether dropbear takes passwords, and on which
	interface, stays the operator's setting on the AP; the keys stay in the
	unhandled ledger.

	The idea and the "only what we created" rule are antoniocosta/unifi-openwrt's
	(GPL-2.0-or-later, internal/openwrt/users.go, read 2026-11-17, run by
	them on an OnHub); the adoption gate, the state ledger and the rename are
	this tree's. ⚠️ Run on the test VM only.
]]--

local M = {}
local util = package.loaded["openuf.util"]
	or assert(loadfile("util.lua") or loadfile("openuf/util.lua"))()

M.PASSWD = "/etc/passwd"
M.SHADOW = "/etc/shadow"
M.GECOS  = "UniFi device login"
M.HOME   = "/root"
M.SHELL  = "/bin/ash"

M._read_file = util.read_file
M._exec      = os.execute
M._time      = os.time
-- Sibling temp file and rename. `private` closes the file before anything is
-- written into it (shadow): created with the hash in it, it would be
-- world-readable for as long as the chmod takes.
M._write_file = function(path, content, private)
	local tmp = path .. ".openuf"
	local f = io.open(tmp, "w")
	if not f then return false end
	f:close()
	M._exec("chmod " .. (private and "600" or "644") .. " '" .. tmp .. "'")
	f = io.open(tmp, "w")
	if not f then os.remove(tmp); return false end
	local wrote = f:write(content)
	local closed = f:close()
	if not (wrote and closed) then os.remove(tmp); return false end
	local ok = os.rename(tmp, path)
	if not ok then os.remove(tmp) end
	return ok and true or false
end

-- ─── Validation ──────────────────────────────────────────────────────────────

-- A login name as useradd would take it. Lower case only: the controller's
-- field is free text, and "Root" beside "root" is a trap, not a login.
function M.is_valid_name(s)
	return type(s) == "string" and #s <= 32 and s:match("^[a-z_][a-z0-9_%-]*$") ~= nil
end

-- A crypt(3) hash: $id$[params$]salt$digest. No colon, no whitespace, which
-- is what keeps it inside its shadow field.
function M.is_valid_hash(s)
	return type(s) == "string" and #s >= 8 and #s <= 256
		and s:match("^%$[0-9a-z]+%$[%w%./%$=,%-]+$") ~= nil
end

-- ─── Parsing ─────────────────────────────────────────────────────────────────

-- nil when the blob carries no users.* key at all (a partial push). Else
-- {enabled, users = {{name, hash}...}, skipped = {reasons}}: the logins that
-- are enabled, have a shell and pass the shape checks.
function M.parse(sys_raw)
	if type(sys_raw) ~= "string" then return nil end
	local status, rows, seen = nil, {}, false
	for line in (sys_raw .. "\n"):gmatch("([^\n]*)\n") do
		local k, v = line:match("^(users%.[^=]+)=(.*)$")
		if k then
			seen = true
			if k == "users.status" then
				status = v
			else
				local i, key = k:match("^users%.(%d+)%.(.+)$")
				if i then
					i = tonumber(i)
					rows[i] = rows[i] or {}
					rows[i][key] = v
				end
			end
		end
	end
	if not seen then return nil end
	local out = {enabled = (status == "enabled"), users = {}, skipped = {}}
	if not out.enabled then return out end
	local idx, names = {}, {}
	for i in pairs(rows) do idx[#idx + 1] = i end
	table.sort(idx)
	for _, i in ipairs(idx) do
		local r = rows[i]
		local shell = r.shell or ""
		if r.status == "disabled" then
			-- not wanted: says nothing
		elseif shell:match("/false$") or shell:match("/nologin$") then
			-- the `nobody` row every push carries: not a login
		elseif not M.is_valid_name(r.name) then
			out.skipped[#out.skipped + 1] = ("users.%d: not a usable login name"):format(i)
		elseif not M.is_valid_hash(r.password) then
			out.skipped[#out.skipped + 1] = ("users.%d (%s): no crypt hash"):format(i, r.name)
		elseif names[r.name] then
			out.skipped[#out.skipped + 1] = ("users.%d (%s): named twice"):format(i, r.name)
		else
			names[r.name] = true
			out.users[#out.users + 1] = {name = r.name, hash = r.password}
		end
	end
	return out
end

-- ─── /etc/passwd and /etc/shadow ─────────────────────────────────────────────

local function lines_of(text)
	local out = {}
	for line in ((text or "") .. "\n"):gmatch("([^\n]*)\n") do out[#out + 1] = line end
	-- the sentinel newline's empty tail
	while #out > 0 and out[#out] == "" do out[#out] = nil end
	return out
end

local function name_of(line) return line:match("^([^:]*):") end

local function has(lines, name)
	for _, l in ipairs(lines) do if name_of(l) == name then return true end end
	return false
end

local function without(lines, name)
	local out = {}
	for _, l in ipairs(lines) do if name_of(l) ~= name then out[#out + 1] = l end end
	return out
end

local function join(lines) return #lines > 0 and (table.concat(lines, "\n") .. "\n") or "" end

-- Make the AP's logins match `want` ({{name, hash}...}), touching only the
-- names in `managed` (a list: what this module created before) and the new
-- ones it creates now. `trusted` must be true or nothing happens at all.
-- Returns the new managed list and a list of what changed ("added x",
-- "updated x", "removed x", "skipped x: ..."); nil, why when it could not
-- write, in which case the caller keeps the old list.
function M.sync(want, managed, trusted)
	if not trusted then return managed or {}, {} end
	local passwd_text, shadow_text = M._read_file(M.PASSWD), M._read_file(M.SHADOW)
	if passwd_text == nil or shadow_text == nil then
		return nil, "cannot read " .. M.PASSWD .. " or " .. M.SHADOW
	end
	local passwd, shadow = lines_of(passwd_text), lines_of(shadow_text)
	local ours, wanted, changes, new_managed = {}, {}, {}, {}
	for _, n in ipairs(managed or {}) do ours[n] = true end
	local day = math.floor(M._time() / 86400)

	for _, u in ipairs(want or {}) do
		if not (M.is_valid_name(u.name) and M.is_valid_hash(u.hash)) then
			changes[#changes + 1] = "skipped " .. tostring(u.name) .. ": malformed"
		elseif has(passwd, u.name) and not ours[u.name] then
			changes[#changes + 1] = "skipped " .. u.name .. ": an account of that name already exists and is not openUF's"
		else
			wanted[u.name] = true
			new_managed[#new_managed + 1] = u.name
			if not has(passwd, u.name) then
				passwd[#passwd + 1] = ("%s:x:0:0:%s:%s:%s"):format(u.name, M.GECOS, M.HOME, M.SHELL)
				changes[#changes + 1] = "added " .. u.name
			end
			local cur
			for _, l in ipairs(shadow) do
				if name_of(l) == u.name then cur = l:match("^[^:]*:([^:]*)") end
			end
			if cur ~= u.hash then
				shadow = without(shadow, u.name)
				shadow[#shadow + 1] = ("%s:%s:%d:0:99999:7:::"):format(u.name, u.hash, day)
				if cur ~= nil then changes[#changes + 1] = "updated " .. u.name end
			end
		end
	end
	for _, n in ipairs(managed or {}) do
		if not wanted[n] then
			if has(passwd, n) or has(shadow, n) then changes[#changes + 1] = "removed " .. n end
			passwd, shadow = without(passwd, n), without(shadow, n)
		end
	end

	local new_passwd, new_shadow = join(passwd), join(shadow)
	-- shadow before passwd: a new account must never exist, even for the
	-- moment between two renames, without the line that holds its hash.
	if new_shadow ~= join(lines_of(shadow_text)) then
		if not M._write_file(M.SHADOW, new_shadow, true) then return nil, "cannot write " .. M.SHADOW end
	end
	if new_passwd ~= join(lines_of(passwd_text)) then
		if not M._write_file(M.PASSWD, new_passwd, false) then return nil, "cannot write " .. M.PASSWD end
	end
	return new_managed, changes
end

return M
