-- Tests for openuf/crypto.lua (AES-128-CBC/GCM wrappers).
-- Run from project root: lua tests/run_tests.lua
-- Requires: lua-openssl or luacrypto (or the openssl CLI for CBC fallback)

local crypto = dofile("openuf/crypto.lua")

-- Fixed IV for deterministic tests
local FIXED_IV = string.rep("\0", 16)

-- NIST AES-128-CBC test vector (from NIST SP 800-38A, F.2.1):
-- Key:  2b7e151628aed2a6abf7158809cf4f3c
-- IV:   000102030405060708090a0b0c0d0e0f
-- PT:   6bc1bee22e409f96e93d7e117393172a
-- CT:   7649abac8119b246cee98e9b12e9197d
local NIST_KEY = "2b7e151628aed2a6abf7158809cf4f3c"
local NIST_IV  = string.char(
	0x00, 0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07,
	0x08, 0x09, 0x0a, 0x0b, 0x0c, 0x0d, 0x0e, 0x0f
)
local NIST_PT  = string.char(
	0x6b, 0xc1, 0xbe, 0xe2, 0x2e, 0x40, 0x9f, 0x96,
	0xe9, 0x3d, 0x7e, 0x11, 0x73, 0x93, 0x17, 0x2a
)
local NIST_CT  = string.char(
	0x76, 0x49, 0xab, 0xac, 0x81, 0x19, 0xb2, 0x46,
	0xce, 0xe9, 0x8e, 0x9b, 0x12, 0xe9, 0x19, 0x7d
)

return {
	{
		name = "crypto: hex_to_bin converts correctly",
		fn = function()
			local b = crypto.hex_to_bin("deadbeef")
			assert_eq(#b, 4, "byte count")
			assert_eq(string.byte(b, 1), 0xde, "byte 1")
			assert_eq(string.byte(b, 4), 0xef, "byte 4")
		end
	},
	{
		name = "crypto: bin_to_hex converts correctly",
		fn = function()
			local h = crypto.bin_to_hex(string.char(0xde, 0xad, 0xbe, 0xef))
			assert_eq(h, "deadbeef", "hex string")
		end
	},
	{
		name = "crypto: hex_to_bin + bin_to_hex round-trip",
		fn = function()
			local original = crypto.DEFAULT_KEY
			assert_eq(crypto.bin_to_hex(crypto.hex_to_bin(original)), original, "round-trip")
		end
	},
	{
		name = "crypto: random_iv returns 16 bytes by default",
		fn = function()
			local iv = crypto.random_iv()
			assert_eq(#iv, 16, "IV length")
		end
	},
	{
		name = "crypto: random_iv injectable override works",
		fn = function()
			local called = false
			crypto._random_bytes = function(n)
				called = true
				return string.rep("\66", n)
			end
			local iv = crypto.random_iv(16)
			crypto._random_bytes = nil
			assert_true(called, "override was called")
			assert_eq(iv, string.rep("\66", 16), "returned injected value")
		end
	},
	{
		name = "crypto: CBC encrypt + decrypt round-trip",
		fn = function()
			local key = crypto.DEFAULT_KEY
			local plaintext = "Hello, UniFi! OK"	-- exactly 16 bytes
			local ct = crypto.aes_cbc_encrypt(key, FIXED_IV, plaintext)
			local pt = crypto.aes_cbc_decrypt(key, FIXED_IV, ct)
			assert_eq(pt, plaintext, "round-trip plaintext")
		end
	},
	{
		name = "crypto: CBC encrypt + decrypt round-trip with non-block-aligned plaintext",
		fn = function()
			local key = crypto.DEFAULT_KEY
			local plaintext = "short"
			local ct = crypto.aes_cbc_encrypt(key, FIXED_IV, plaintext)
			local pt = crypto.aes_cbc_decrypt(key, FIXED_IV, ct)
			assert_eq(pt, plaintext, "round-trip non-block-aligned")
		end
	},
	{
		name = "crypto: CBC ciphertext length is multiple of 16 (PKCS7 padded)",
		fn = function()
			local key = crypto.DEFAULT_KEY
			-- 16-byte plaintext should produce 32-byte ciphertext (padding block added)
			local ct = crypto.aes_cbc_encrypt(key, FIXED_IV, string.rep("A", 16))
			assert_eq(#ct % 16, 0, "ciphertext is block-aligned")
			assert_true(#ct >= 32, "PKCS7 padding block added for 16-byte input")
		end
	},
	{
		name = "crypto: CBC NIST test vector",
		fn = function()
			-- Encrypt exactly one block (16 bytes, no PKCS7 needed for this check)
			-- We check that the first 16 bytes of the ciphertext match NIST
			local ct = crypto.aes_cbc_encrypt(NIST_KEY, NIST_IV, NIST_PT)
			-- ct includes PKCS7 padding block; first 16 bytes must match NIST_CT
			assert_eq(#ct >= 16, true, "ciphertext at least 16 bytes")
			local first_block = ct:sub(1, 16)
			assert_bytes_eq(first_block, NIST_CT, "NIST AES-128-CBC first block")
		end
	},
	{
		name = "crypto: CBC different keys produce different ciphertext",
		fn = function()
			local pt = "same plaintext!!"
			local ct1 = crypto.aes_cbc_encrypt(crypto.DEFAULT_KEY, FIXED_IV, pt)
			local ct2 = crypto.aes_cbc_encrypt("ffffffffffffffffffffffffffffffff", FIXED_IV, pt)
			assert_neq(ct1, ct2, "different keys produce different ciphertext")
		end
	},
	{
		name = "crypto: CBC different IVs produce different ciphertext",
		fn = function()
			local key = crypto.DEFAULT_KEY
			local pt = "same plaintext!!"
			local iv2 = string.rep("\255", 16)
			local ct1 = crypto.aes_cbc_encrypt(key, FIXED_IV, pt)
			local ct2 = crypto.aes_cbc_encrypt(key, iv2, pt)
			assert_neq(ct1, ct2, "different IVs produce different ciphertext")
		end
	},
	{
		name = "crypto: CBC decrypt with wrong key produces garbage (not original)",
		fn = function()
			local pt = "secret message!!"
			local ct = crypto.aes_cbc_encrypt(crypto.DEFAULT_KEY, FIXED_IV, pt)
			-- Decrypting with wrong key should either error or return wrong data
			local ok, result = pcall(crypto.aes_cbc_decrypt,
				"ffffffffffffffffffffffffffffffff", FIXED_IV, ct)
			if ok then
				assert_neq(result, pt, "wrong key produces different result")
			end
			-- error path is also acceptable
		end
	},
	{
		-- GCM needs a Lua crypto binding (lua-openssl/luacrypto). When neither is
		-- present (e.g. the CLI-only dev host) the round-trip is skipped, but the
		-- no-backend contract is still asserted.
		name = "crypto: GCM encrypt + decrypt round-trip with AAD (or errors cleanly)",
		fn = function()
			local key = crypto.DEFAULT_KEY
			local pt  = "GCM secret body!"
			local aad = string.rep("\1", 40)  -- 40-byte TNBU header, as on the wire
			if not crypto.gcm_available() then
				assert_error(function()
					crypto.aes_gcm_encrypt(key, FIXED_IV, pt, aad)
				end, "gcm_encrypt errors when no backend is available")
				return
			end
			local ct, tag = crypto.aes_gcm_encrypt(key, FIXED_IV, pt, aad)
			assert_eq(#tag, 16, "GCM tag is 16 bytes")
			assert_neq(ct, pt, "ciphertext differs from plaintext")
			local out = crypto.aes_gcm_decrypt(key, FIXED_IV, ct, tag, aad)
			assert_eq(out, pt, "GCM round-trip plaintext")
		end
	},
	{
		name = "crypto: GCM decrypt fails on tampered AAD or tag",
		fn = function()
			if not crypto.gcm_available() then return end  -- covered by the test above
			local key = crypto.DEFAULT_KEY
			local pt  = "GCM secret body!"
			local aad = string.rep("\1", 40)
			local ct, tag = crypto.aes_gcm_encrypt(key, FIXED_IV, pt, aad)
			assert_error(function()
				crypto.aes_gcm_decrypt(key, FIXED_IV, ct, tag, string.rep("\2", 40))
			end, "wrong AAD must fail verification")
			local bad_tag = string.rep("\0", 16)
			assert_error(function()
				crypto.aes_gcm_decrypt(key, FIXED_IV, ct, bad_tag, aad)
			end, "wrong tag must fail verification")
		end
	},
}
