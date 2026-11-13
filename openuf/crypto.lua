--[[
	AES-128-CBC and AES-128-GCM wrappers.

	Backend selection (in priority order):
	  1. lua-openssl (require "openssl") — preferred. apk package "lua-openssl"
	     on OpenWrt 25.12+. In-process, supports both CBC and GCM.
	  2. luacrypto  (require "crypto")   — legacy. Only on older OpenWrt where the
	     "luacrypto" package still exists (dropped from the 25.12 feeds).
	  3. openssl(1) CLI                  — last resort when neither binding is
	     present. CBC only; GCM is unavailable on this path.

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
	-- No fallback to math.random seeded from os.time(): an IV anyone can
	-- guess from the clock is worse than an inform that is not sent.
	error("crypto: /dev/urandom unreadable -- no IV")
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

-- Backend detection. lua-openssl is preferred; luacrypto is a legacy fallback.
--
-- luacrypto is only looked for without lua-openssl, and only as the C module
-- it is: Lua's default package.path includes "./?.lua", and the daemons run
-- from /opt/openuf, so require("crypto") resolved right back to this file and
-- loaded a second copy of it into package.loaded for the life of the process.
-- package.path is emptied for that one require. The shape check stays as a
-- belt: this module's own table has no `encrypt`.
local _ossl_ok,   _ossl    = pcall(require, "openssl")
local _crypto_ok, _lcrypto = false, nil
if not _ossl_ok then
	local path = package.path
	package.path = ""
	_crypto_ok, _lcrypto = pcall(require, "crypto")
	package.path = path
	_crypto_ok = _crypto_ok and type(_lcrypto) == "table" and type(_lcrypto.encrypt) == "function"
end

-- No AES binding at all. There used to be an openssl(1) CLI fallback here; it
-- put the authkey on a command line (readable in /proc by any local user) and
-- the plaintext inform in /tmp. lua-openssl is a hard dependency (Makefile
-- DEPENDS, install.sh), so its absence is a broken install and is said so.
local function _no_binding()
	error("crypto: no AES binding (install lua-openssl) -- refusing the openssl CLI, "
		.. "which would expose the key on a command line")
end

-- AES-128-CBC encrypt
-- key_hex: 32-char hex string
-- iv: 16-byte binary string (from M.random_iv())
-- plaintext: binary string
-- returns: ciphertext binary string (PKCS#7 padded)
function M.aes_cbc_encrypt(key_hex, iv, plaintext)
	local padded = pkcs7_pad(plaintext, 16)
	local key = M.hex_to_bin(key_hex)
	if _ossl_ok then
		-- lua-openssl: pad ourselves (padding(false)) so the wire format matches
		-- the controller, which PKCS#7-pads then encrypts with no extra padding.
		local ctx = _ossl.cipher.get("aes-128-cbc"):new(true, key, iv)
		ctx:padding(false)
		return ctx:update(padded) .. ctx:final()
	elseif _crypto_ok then
		-- luacrypto: encrypt(algo, data, key, iv[, raw])
		-- Pass raw=true (or omit for raw binary output depending on version)
		local ok, result = pcall(_lcrypto.encrypt, "aes-128-cbc", padded, key, iv, true)
		if not ok then
			-- Some versions don't take the raw flag; try without
			result = _lcrypto.encrypt("aes-128-cbc", padded, key, iv)
			-- Raw or base64, decided by length, not by guessing from the
			-- bytes: with no padding added, raw ciphertext is exactly as long
			-- as the padded input, and its bytes can by chance all be
			-- base64 letters. Anything else must decode to that length.
			if type(result) == "string" and #result ~= #padded then
				local ok2, dec = pcall(function() return require("mime").unb64(result) end)
				if not (ok2 and type(dec) == "string" and #dec == #padded) then
					error("crypto: luacrypto returned neither raw nor base64 ciphertext")
				end
				result = dec
			end
		end
		return result
	else
		_no_binding()
	end
end

-- AES-128-CBC decrypt
-- key_hex: 32-char hex string
-- iv: 16-byte binary string
-- ciphertext: binary string
-- returns: plaintext binary string (PKCS#7 stripped)
function M.aes_cbc_decrypt(key_hex, iv, ciphertext)
	local key = M.hex_to_bin(key_hex)
	if _ossl_ok then
		local ctx = _ossl.cipher.get("aes-128-cbc"):new(false, key, iv)
		ctx:padding(false)
		return pkcs7_unpad(ctx:update(ciphertext) .. ctx:final())
	elseif _crypto_ok then
		local ok, result = pcall(_lcrypto.decrypt, "aes-128-cbc", ciphertext, key, iv, true)
		if not ok then
			result = _lcrypto.decrypt("aes-128-cbc", ciphertext, key, iv)
		end
		return pkcs7_unpad(result)
	else
		_no_binding()
	end
end

-- AES-128-GCM encrypt (requires luacrypto with AEAD/GCM support)
-- aad: optional binary string for authenticated additional data (the 40-byte
--      TNBU header per amd989/unifi-gateway; nil = no AAD)
-- Returns: ciphertext (binary string), auth_tag (16-byte binary string)
function M.aes_gcm_encrypt(key_hex, iv, plaintext, aad)
	local key = M.hex_to_bin(key_hex)
	if _ossl_ok then
		-- The TNBU IV field is 16 bytes; OpenSSL GCM defaults to a 12-byte
		-- nonce, so SET_IVLEN must precede init to accept the full IV.
		local C   = _ossl.cipher
		local ctx = C.get("aes-128-gcm"):encrypt_new()
		ctx:ctrl(C.EVP_CTRL_GCM_SET_IVLEN, #iv)
		ctx:init(key, iv)
		ctx:padding(false)
		if aad and #aad > 0 then ctx:update(aad, true) end  -- true = AAD, not plaintext
		local ct  = ctx:update(plaintext) .. ctx:final()
		local tag = ctx:ctrl(C.EVP_CTRL_GCM_GET_TAG, 16)
		return ct, tag
	elseif _crypto_ok and _lcrypto.aead then
		local ctx = _lcrypto.aead("aes-128-gcm", key, iv, true)
		-- Feed AAD if the luacrypto binding exposes updateAAD (version-dependent)
		if aad and #aad > 0 and type(ctx.updateAAD) == "function" then
			ctx:updateAAD(aad)
		end
		local ct = ctx:update(plaintext)
		ct = ct .. ctx:final()
		local tag = ctx:getTag(16)
		return ct, tag
	end
	error("aes_gcm_encrypt: no GCM backend (install lua-openssl); use CBC instead")
end

-- AES-128-GCM decrypt
-- aad: optional binary string for AAD verification (must match what was used to encrypt)
-- Raises an error if authentication tag verification fails
function M.aes_gcm_decrypt(key_hex, iv, ciphertext, tag, aad)
	local key = M.hex_to_bin(key_hex)
	if _ossl_ok then
		local C   = _ossl.cipher
		local ctx = C.get("aes-128-gcm"):decrypt_new()
		ctx:ctrl(C.EVP_CTRL_GCM_SET_IVLEN, #iv)
		ctx:init(key, iv)
		ctx:padding(false)
		if aad and #aad > 0 then ctx:update(aad, true) end
		local pt = ctx:update(ciphertext)
		ctx:ctrl(C.EVP_CTRL_GCM_SET_TAG, tag)
		local final = ctx:final()  -- verifies the tag; falsy on mismatch
		if not final then error("aes_gcm_decrypt: authentication tag verification failed") end
		return pt .. final
	elseif _crypto_ok and _lcrypto.aead then
		local ctx = _lcrypto.aead("aes-128-gcm", key, iv, false)
		if aad and #aad > 0 and type(ctx.updateAAD) == "function" then
			ctx:updateAAD(aad)
		end
		ctx:setTag(tag)
		local pt = ctx:update(ciphertext)
		pt = pt .. ctx:final()  -- final() verifies the tag; throws on mismatch
		return pt
	end
	error("aes_gcm_decrypt: no GCM backend (install lua-openssl)")
end

-- Returns true if GCM is supported by the available backend
function M.gcm_available()
	return (_ossl_ok and _ossl.cipher ~= nil)
		or (_crypto_ok and _lcrypto.aead ~= nil)
end

return M
