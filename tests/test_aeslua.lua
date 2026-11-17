-- Tests for openuf/aeslua.lua: AES-128-CBC in plain Lua, what crypto.lua
-- uses on a machine with no AES binding.
-- Run from project root: lua tests/run_tests.lua

local aes = dofile("openuf/aeslua.lua")

local function unhex(h) return (h:gsub("..", function(b) return string.char(tonumber(b, 16)) end)) end
local function hex(s) return (s:gsub(".", function(c) return string.format("%02x", c:byte()) end)) end

local ZERO_IV = string.rep("\0", 16)

return {
	{
		-- The S-box is computed, not typed in: hold the computation to the
		-- table in FIPS-197 figure 7.
		name = "aeslua: the computed S-box is FIPS-197's",
		fn = function()
			local s = aes._sbox
			assert_eq(s[0x00], 0x63, "S(00)")
			assert_eq(s[0x01], 0x7c, "S(01)")
			assert_eq(s[0x53], 0xed, "S(53), the standard's own worked example")
			assert_eq(s[0x80], 0xcd, "S(80)")
			assert_eq(s[0xff], 0x16, "S(ff)")
			local seen, n = {}, 0
			for i = 0, 255 do
				assert_true(s[i] ~= nil, "every byte has an image: " .. i)
				if not seen[s[i]] then seen[s[i]] = true; n = n + 1 end
			end
			assert_eq(n, 256, "and it is a permutation")
		end
	},
	{
		-- FIPS-197 appendix C.1. One block under a zero IV is the block
		-- cipher itself.
		name = "aeslua: one block matches FIPS-197 appendix C.1, both ways",
		fn = function()
			local key = unhex("000102030405060708090a0b0c0d0e0f")
			local pt  = unhex("00112233445566778899aabbccddeeff")
			local ct  = aes.cbc_encrypt(key, ZERO_IV, pt)
			assert_eq(hex(ct), "69c4e0d86a7b0430d8cdb78070b4c55a", "ciphertext")
			assert_eq(hex(aes.cbc_decrypt(key, ZERO_IV, ct)), hex(pt), "and back")
		end
	},
	{
		-- NIST SP 800-38A F.2.1 / F.2.2: all four blocks, so the chaining is
		-- tested and not only the block.
		name = "aeslua: CBC matches SP 800-38A's four-block vector, both ways",
		fn = function()
			local key = unhex("2b7e151628aed2a6abf7158809cf4f3c")
			local iv  = unhex("000102030405060708090a0b0c0d0e0f")
			local pt  = unhex("6bc1bee22e409f96e93d7e117393172a" .. "ae2d8a571e03ac9c9eb76fac45af8e51"
				.. "30c81c46a35ce411e5fbc1191a0a52ef" .. "f69f2445df4f9b17ad2b417be66c3710")
			local want = "7649abac8119b246cee98e9b12e9197d" .. "5086cb9b507219ee95db113a917678b2"
				.. "73bed6b8e3c1743b7116e69e22229516" .. "3ff1caa1681fac09120eca307586e1a7"
			local ct = aes.cbc_encrypt(key, iv, pt)
			assert_eq(hex(ct), want, "ciphertext")
			assert_eq(hex(aes.cbc_decrypt(key, iv, ct)), hex(pt), "and back")
		end
	},
	{
		name = "aeslua: every byte value survives a round trip",
		fn = function()
			local t = {}
			for i = 0, 255 do t[#t + 1] = string.char(i) end
			local pt = table.concat(t)
			local key, iv = unhex("ba86f2bbe107c7c57eb5f2690775c712"), unhex("0f0e0d0c0b0a09080706050403020100")
			local ct = aes.cbc_encrypt(key, iv, pt)
			assert_eq(#ct, 256, "same length: no padding of its own")
			assert_true(ct ~= pt, "and not the plaintext")
			assert_eq(aes.cbc_decrypt(key, iv, ct), pt, "round trip")
		end
	},
	{
		name = "aeslua: a wrong-sized key, IV or input is refused, not padded or cut",
		fn = function()
			local key, blk = string.rep("k", 16), string.rep("p", 16)
			assert_error(function() aes.cbc_encrypt("short", ZERO_IV, blk) end, "short key")
			assert_error(function() aes.cbc_encrypt(string.rep("k", 32), ZERO_IV, blk) end, "a 256-bit key is not this cipher's")
			assert_error(function() aes.cbc_encrypt(key, "iv", blk) end, "short IV")
			assert_error(function() aes.cbc_encrypt(key, ZERO_IV, "seventeen bytes!!") end, "a partial block")
			assert_error(function() aes.cbc_decrypt(key, ZERO_IV, "x") end, "a partial block to decrypt")
		end
	},
}
