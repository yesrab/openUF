--[[
	openUF Lua comment stripper.

	Removes comments and blank lines from a Lua source file, writing the result
	to stdout. Used by tools/dist.sh (and install.sh) to halve the on-device
	footprint without touching the source of truth -- the repo keeps its
	protocol-archaeology comments, the device does not.

	This is a real character scanner, not a line/regex filter: it tracks quoted
	strings and long brackets so it can never mistake a "--" inside a string
	literal for a comment. Indentation is preserved so the installed copy stays
	readable when debugging on a live AP.

	Plain Lua 5.1-5.5 (no goto, no bitwise ops, no integer division) -- it runs
	under the CI's 5.1 and a dev box's 5.4/5.5 alike.

	Usage:
	  lua tools/strip.lua <file.lua> > out.lua
]]--

local path = ...
if not path then
	io.stderr:write("usage: lua tools/strip.lua <file.lua>\n")
	os.exit(2)
end

local f, err = io.open(path, "r")
if not f then
	io.stderr:write("strip: " .. tostring(err) .. "\n")
	os.exit(1)
end
local src = f:read("*a")
f:close()

-- ── Output assembly ─────────────────────────────────────────────────────────
-- Lines are finalized one at a time. A line that carried long-string content is
-- emitted verbatim (trimming it would change the string's value); any other
-- line gets its trailing whitespace removed and is dropped if nothing is left.

local lines = {}
local cur = {}
local protected = false

local function endline()
	local s = table.concat(cur)
	cur = {}
	if protected then
		lines[#lines + 1] = s
	else
		s = s:gsub("%s+$", "")
		if s ~= "" then lines[#lines + 1] = s end
	end
	protected = false
end

-- Append text, splitting it into lines as it goes. prot marks the text as
-- long-string content, which must survive verbatim.
local function put(text, prot)
	if prot then protected = true end
	for i = 1, #text do
		local ch = text:sub(i, i)
		if ch == "\n" then
			endline()
			protected = prot or false
		else
			cur[#cur + 1] = ch
		end
	end
end

-- ── Scanner ─────────────────────────────────────────────────────────────────

-- If a long bracket opens at pos ("[", n "="s, "["), return its level and the
-- position just past the opener. Otherwise return nil.
local function long_open(s, pos)
	if s:sub(pos, pos) ~= "[" then return nil end
	local p = pos + 1
	while s:sub(p, p) == "=" do p = p + 1 end
	if s:sub(p, p) ~= "[" then return nil end
	return p - pos - 1, p + 1
end

-- Find the end of a long bracket of the given level, starting at pos. Returns
-- the position just past the closer, and the position of the closer itself.
local function long_close(s, pos, level)
	local closer = "]" .. string.rep("=", level) .. "]"
	local a, b = s:find(closer, pos, true)
	if not a then return #s + 1, #s + 1 end	-- unterminated: consume the rest
	return b + 1, a
end

local i, n = 1, #src
while i <= n do
	local c = src:sub(i, i)

	if c == "-" and src:sub(i + 1, i + 1) == "-" then
		-- Comment. Long form first, so --[[ ]] does not fall through to the
		-- line-comment case.
		local level, after = long_open(src, i + 2)
		if level then
			i = (long_close(src, after, level))
		else
			local nl = src:find("\n", i, true)
			i = nl or (n + 1)	-- leave the newline for normal handling
		end

	elseif c == '"' or c == "'" then
		-- Quoted string: copy verbatim, honouring backslash escapes so an
		-- escaped quote does not look like the terminator.
		local j = i + 1
		while j <= n do
			local d = src:sub(j, j)
			if d == "\\" then
				j = j + 2
			elseif d == c then
				j = j + 1
				break
			else
				j = j + 1
			end
		end
		put(src:sub(i, j - 1), false)
		i = j

	elseif c == "[" then
		local level, after = long_open(src, i)
		if level then
			local stop = (long_close(src, after, level))
			put(src:sub(i, stop - 1), true)
			i = stop
		else
			put(c, false)
			i = i + 1
		end

	else
		put(c, false)
		i = i + 1
	end
end

if #cur > 0 then endline() end

io.write(table.concat(lines, "\n"))
if #lines > 0 then io.write("\n") end
