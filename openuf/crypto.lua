--[[
	AES-128-CBC and AES-128-GCM wrappers.

	Primary backend: luacrypto (OpenSSL bindings), available as opkg package
	"luacrypto" on OpenWrt and via LuaRocks on development hosts.

	Fallback backend: openssl(1) CLI — used when luacrypto is absent.
	The CLI fallback supports CBC only; GCM requires luacrypto.

	All keys and IVs are passed as 32-char hex strings (16 raw bytes).
	Plaintext and ciphertext are Lua binary strings.
]]--

local M = {}

M.DEFAULT_KEY = "ba86f2bbe107c7c57eb5f2690775c712"

-- Injectable for tests: override to return deterministic IVs
M._random_bytes = nil

-- Convert 32-char hex string → 16-byte binary string
function M.hex_to_bin(hex)
	return (hex:gsub("..", function(h) return string.char(tonumber(h, 16)) end))
end

-- Convert binary string → hex string
function M.bin_to_hex(bin)
	return (bin:gsub(".", function(c) return string.format("%02x", string.byte(c)) end))
end

-- Generate a random binary string of `len` bytes (default 16)
function M.random_iv(len)
	len = len or 16
	if M._random_bytes then
		return M._random_bytes(len)
	end
	-- Try /dev/urandom (available on Linux and macOS)
	local f = io.open("/dev/urandom", "rb")
	if f then
		local bytes = f:read(len)
		f:close()
		if bytes and #bytes == len then return bytes end
	end
	-- Last resort: math.random (weak, only if /dev/urandom unavailable)
	math.randomseed(os.time())
	local t = {}
	for i = 1, len do t[i] = string.char(math.random(0, 255)) end
	return table.concat(t)
end

-- PKCS#7 pad to block boundary
local function pkcs7_pad(data, blocksize)
	blocksize = blocksize or 16
	local pad = blocksize - (#data % blocksize)
	return data .. string.rep(string.char(pad), pad)
end

-- Strip PKCS#7 padding; raises error on invalid padding
local function pkcs7_unpad(data)
	if #data == 0 then error("pkcs7_unpad: empty input") end
	local pad = string.byte(data, #data)
	if pad < 1 or pad > 16 then
		error("pkcs7_unpad: invalid padding byte " .. tostring(pad))
	end
	for i = #data - pad + 1, #data do
		if string.byte(data, i) ~= pad then
			error("pkcs7_unpad: padding mismatch at byte " .. i)
		end
	end
	return data:sub(1, #data - pad)
end

-- Try loading luacrypto
local _crypto_ok, _lcrypto = pcall(require, "crypto")

-- Internal: AES-128-CBC via openssl CLI (fallback when luacrypto absent)
local function _openssl_cbc(decrypt, key_hex, iv_hex, data)
	local tmpIn  = "/tmp/uf_cbc_in_"  .. os.time()
	local tmpOut = "/tmp/uf_cbc_out_" .. os.time()
	local fIn = io.open(tmpIn, "wb")
	if not fIn then error("crypto: cannot write temp file") end
	fIn:write(data)
	fIn:close()
	local dcflag = decrypt and "-d " or ""
	local cmd = string.format(
		"openssl enc -aes-128-cbc %s-K %s -iv %s -nopad -nosalt -in %s -out %s 2>/dev/null",
		dcflag, key_hex, iv_hex, tmpIn, tmpOut
	)
	local rc = os.execute(cmd)
	local result
	if rc == 0 or rc == true then
		local fOut = io.open(tmpOut, "rb")
		if fOut then
			result = fOut:read("*a")
			fOut:close()
		end
	end
	os.remove(tmpIn)
	os.remove(tmpOut)
	if not result then error("crypto: openssl enc failed") end
	return result
end

-- AES-128-CBC encrypt
-- key_hex: 32-char hex string
-- iv: 16-byte binary string (from M.random_iv())
-- plaintext: binary string
-- returns: ciphertext binary string (PKCS#7 padded)
function M.aes_cbc_encrypt(key_hex, iv, plaintext)
	local padded = pkcs7_pad(plaintext, 16)
	if _crypto_ok then
		local key = M.hex_to_bin(key_hex)
		-- luacrypto: encrypt(algo, data, key, iv[, raw])
		-- Pass raw=true (or omit for raw binary output depending on version)
		local ok, result = pcall(_lcrypto.encrypt, "aes-128-cbc", padded, key, iv, true)
		if not ok then
			-- Some versions don't take the raw flag; try without
			result = _lcrypto.encrypt("aes-128-cbc", padded, key, iv)
			-- Decode base64 if returned as base64
			if result and result:find("[A-Za-z0-9+/=]") and not result:find("[\0-\31]") then
				local ok2, dec = pcall(require("mime").unb64, result)
				if ok2 then result = dec end
			end
		end
		return result
	else
		return _openssl_cbc(false, key_hex, M.bin_to_hex(iv), padded)
	end
end

-- AES-128-CBC decrypt
-- key_hex: 32-char hex string
-- iv: 16-byte binary string
-- ciphertext: binary string
-- returns: plaintext binary string (PKCS#7 stripped)
function M.aes_cbc_decrypt(key_hex, iv, ciphertext)
	if _crypto_ok then
		local key = M.hex_to_bin(key_hex)
		local ok, result = pcall(_lcrypto.decrypt, "aes-128-cbc", ciphertext, key, iv, true)
		if not ok then
			result = _lcrypto.decrypt("aes-128-cbc", ciphertext, key, iv)
		end
		return pkcs7_unpad(result)
	else
		local raw = _openssl_cbc(true, key_hex, M.bin_to_hex(iv), ciphertext)
		return pkcs7_unpad(raw)
	end
end

-- AES-128-GCM encrypt (requires luacrypto with AEAD/GCM support)
-- Returns: ciphertext (binary string), auth_tag (16-byte binary string)
function M.aes_gcm_encrypt(key_hex, iv, plaintext)
	if not _crypto_ok then
		error("aes_gcm_encrypt: luacrypto not available; GCM requires it")
	end
	local key = M.hex_to_bin(key_hex)
	-- Try EVP AEAD interface (luacrypto >= 2.x or lua-openssl)
	if _lcrypto.aead then
		local ctx = _lcrypto.aead("aes-128-gcm", key, iv, true)
		local ct = ctx:update(plaintext)
		ct = ct .. ctx:final()
		local tag = ctx:getTag(16)
		return ct, tag
	end
	-- Alternative: use EVP directly
	error("aes_gcm_encrypt: luacrypto version lacks GCM support; update luacrypto or use CBC")
end

-- AES-128-GCM decrypt
-- Raises an error if authentication tag verification fails
function M.aes_gcm_decrypt(key_hex, iv, ciphertext, tag)
	if not _crypto_ok then
		error("aes_gcm_decrypt: luacrypto not available")
	end
	local key = M.hex_to_bin(key_hex)
	if _lcrypto.aead then
		local ctx = _lcrypto.aead("aes-128-gcm", key, iv, false)
		ctx:setTag(tag)
		local pt = ctx:update(ciphertext)
		pt = pt .. ctx:final()  -- final() verifies the tag; throws on mismatch
		return pt
	end
	error("aes_gcm_decrypt: luacrypto version lacks GCM support")
end

-- Returns true if GCM is supported by the available backend
function M.gcm_available()
	return _crypto_ok and (_lcrypto.aead ~= nil)
end

return M
