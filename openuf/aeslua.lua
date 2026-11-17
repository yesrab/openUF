--[[
	AES-128-CBC in plain Lua, for a machine with no AES binding.

	crypto.lua uses lua-openssl, and on a device it always has it (a hard
	dependency of the package and of install.sh). This module is what is left
	when it does not: a developer's machine whose Lua has no lua-openssl rock
	(there is none for Lua 5.5), a CI job that did not install it, a board
	whose install is broken.

	It replaced nothing on a device. What it replaced on those machines is
	the old fallback to the openssl(1) command, removed on 2026-11-17 (PR #6)
	because it put the authkey on a command line and the plaintext inform in
	/tmp. This does neither: the key never leaves the process, and the code
	is the same on every platform Lua runs on.

	What it is NOT: fast, or constant-time. Table lookups indexed by key and
	data bytes leak timing, which matters where an attacker can measure this
	process closely -- not on a development machine, and a device should
	never get here (crypto.lua says so, loudly, when it does). CBC only:
	AES-GCM, which adoption needs, stays lua-openssl's.

	FIPS-197, byte-wise. The S-box is computed at load from the field
	arithmetic rather than typed in, so there is no table to mistype; the
	tests hold it to the FIPS-197 and SP 800-38A vectors.
]]--

local util = package.loaded["openuf.util"]
	or assert(loadfile("util.lua") or loadfile("openuf/util.lua"))()
local bxor = util.bit().bxor

local M = {}

-- Multiplication by x in GF(2^8) mod x^8 + x^4 + x^3 + x + 1.
local function xtime(a)
	a = a * 2
	if a >= 256 then a = bxor(a - 256, 0x1b) end
	return a
end

local function gmul(a, b)
	local p = 0
	while b > 0 do
		if b % 2 == 1 then p = bxor(p, a) end
		a = xtime(a)
		b = math.floor(b / 2)
	end
	return p
end

-- The S-box: the multiplicative inverse, then the affine transform.
local SBOX, INV = {}, {}
do
	local function rotl8(x, n) return (x * 2 ^ n) % 256 + math.floor(x / 2 ^ (8 - n)) end
	-- 3 generates the field's multiplicative group: walk its powers to pair
	-- each element with its inverse.
	local p, q = 1, 1
	repeat
		p = bxor(p, xtime(p))                      -- p * 3
		-- q / 3
		q = bxor(q, (q * 2) % 256)
		q = bxor(q, (q * 4) % 256)
		q = bxor(q, (q * 16) % 256)
		if q >= 128 then q = bxor(q, 0x09) end
		local s = bxor(bxor(bxor(bxor(q, rotl8(q, 1)), rotl8(q, 2)), rotl8(q, 3)), rotl8(q, 4))
		s = bxor(s, 0x63)
		SBOX[p], INV[s] = s, p
	until p == 1
	SBOX[0], INV[0x63] = 0x63, 0
end

-- Multiplication tables for MixColumns and its inverse.
local M2, M3, M9, M11, M13, M14 = {}, {}, {}, {}, {}, {}
for i = 0, 255 do
	M2[i], M3[i] = gmul(i, 2), gmul(i, 3)
	M9[i], M11[i], M13[i], M14[i] = gmul(i, 9), gmul(i, 11), gmul(i, 13), gmul(i, 14)
end

-- The 11 round keys of a 16-byte key, as one array of 176 bytes (1-based).
local function expand(key)
	if #key ~= 16 then error("aeslua: key must be 16 bytes") end
	local w = {key:byte(1, 16)}
	local rcon = 1
	for i = 17, 176, 4 do
		local a, b, c, d = w[i - 4], w[i - 3], w[i - 2], w[i - 1]
		if (i - 1) % 16 == 0 then
			a, b, c, d = bxor(SBOX[b], rcon), SBOX[c], SBOX[d], SBOX[a]
			rcon = xtime(rcon)
		end
		w[i], w[i + 1] = bxor(w[i - 16], a), bxor(w[i - 15], b)
		w[i + 2], w[i + 3] = bxor(w[i - 14], c), bxor(w[i - 13], d)
	end
	return w
end

-- One block, in place in s (16 bytes, column-major as FIPS-197 lays it out).
local function encrypt_block(s, w)
	for i = 1, 16 do s[i] = bxor(s[i], w[i]) end
	for round = 1, 10 do
		-- SubBytes and ShiftRows together.
		local t = {
			SBOX[s[1]],  SBOX[s[6]],  SBOX[s[11]], SBOX[s[16]],
			SBOX[s[5]],  SBOX[s[10]], SBOX[s[15]], SBOX[s[4]],
			SBOX[s[9]],  SBOX[s[14]], SBOX[s[3]],  SBOX[s[8]],
			SBOX[s[13]], SBOX[s[2]],  SBOX[s[7]],  SBOX[s[12]],
		}
		local k = round * 16
		if round < 10 then
			for c = 0, 12, 4 do
				local a, b, cc, d = t[c + 1], t[c + 2], t[c + 3], t[c + 4]
				s[c + 1] = bxor(bxor(bxor(bxor(M2[a], M3[b]), cc), d), w[k + c + 1])
				s[c + 2] = bxor(bxor(bxor(bxor(a, M2[b]), M3[cc]), d), w[k + c + 2])
				s[c + 3] = bxor(bxor(bxor(bxor(a, b), M2[cc]), M3[d]), w[k + c + 3])
				s[c + 4] = bxor(bxor(bxor(bxor(M3[a], b), cc), M2[d]), w[k + c + 4])
			end
		else
			for i = 1, 16 do s[i] = bxor(t[i], w[k + i]) end
		end
	end
end

local function decrypt_block(s, w)
	for i = 1, 16 do s[i] = bxor(s[i], w[160 + i]) end
	for round = 9, 0, -1 do
		-- InvShiftRows and InvSubBytes together.
		local t = {
			INV[s[1]],  INV[s[14]], INV[s[11]], INV[s[8]],
			INV[s[5]],  INV[s[2]],  INV[s[15]], INV[s[12]],
			INV[s[9]],  INV[s[6]],  INV[s[3]],  INV[s[16]],
			INV[s[13]], INV[s[10]], INV[s[7]],  INV[s[4]],
		}
		local k = round * 16
		for i = 1, 16 do t[i] = bxor(t[i], w[k + i]) end
		if round > 0 then
			for c = 0, 12, 4 do
				local a, b, cc, d = t[c + 1], t[c + 2], t[c + 3], t[c + 4]
				s[c + 1] = bxor(bxor(bxor(M14[a], M11[b]), M13[cc]), M9[d])
				s[c + 2] = bxor(bxor(bxor(M9[a], M14[b]), M11[cc]), M13[d])
				s[c + 3] = bxor(bxor(bxor(M13[a], M9[b]), M14[cc]), M11[d])
				s[c + 4] = bxor(bxor(bxor(M11[a], M13[b]), M9[cc]), M14[d])
			end
		else
			for i = 1, 16 do s[i] = t[i] end
		end
	end
end

local char = string.char

-- AES-128-CBC over whole blocks: no padding is added or removed (crypto.lua
-- pads). key and iv are 16-byte strings; #data must be a multiple of 16.
function M.cbc_encrypt(key, iv, data)
	if #iv ~= 16 then error("aeslua: IV must be 16 bytes") end
	if #data % 16 ~= 0 then error("aeslua: data is not a whole number of blocks") end
	local w = expand(key)
	local prev = {iv:byte(1, 16)}
	local out = {}
	for pos = 1, #data, 16 do
		local s = {data:byte(pos, pos + 15)}
		for i = 1, 16 do s[i] = bxor(s[i], prev[i]) end
		encrypt_block(s, w)
		out[#out + 1] = char(s[1], s[2], s[3], s[4], s[5], s[6], s[7], s[8],
			s[9], s[10], s[11], s[12], s[13], s[14], s[15], s[16])
		prev = s
	end
	return table.concat(out)
end

function M.cbc_decrypt(key, iv, data)
	if #iv ~= 16 then error("aeslua: IV must be 16 bytes") end
	if #data % 16 ~= 0 then error("aeslua: data is not a whole number of blocks") end
	local w = expand(key)
	local prev = {iv:byte(1, 16)}
	local out = {}
	for pos = 1, #data, 16 do
		local c = {data:byte(pos, pos + 15)}
		local s = {c[1], c[2], c[3], c[4], c[5], c[6], c[7], c[8],
			c[9], c[10], c[11], c[12], c[13], c[14], c[15], c[16]}
		decrypt_block(s, w)
		for i = 1, 16 do s[i] = bxor(s[i], prev[i]) end
		out[#out + 1] = char(s[1], s[2], s[3], s[4], s[5], s[6], s[7], s[8],
			s[9], s[10], s[11], s[12], s[13], s[14], s[15], s[16])
		prev = c
	end
	return table.concat(out)
end

-- For the tests: the S-box, so its construction can be held to FIPS-197.
M._sbox = SBOX

return M
