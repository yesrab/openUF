/*
 * openuf_crypto -- AES-128-CBC and AES-128-GCM for openUF's inform transport,
 * on whichever TLS library the box already has.
 *
 * openUF needs exactly two primitives to talk to a UniFi controller: AES-128
 * in CBC mode (the pre-adoption inform under the well-known key) and AES-128
 * in GCM mode with the 40-byte TNBU header as AAD (every inform after that;
 * a controller will not finish adoption without a genuine GCM inform). Until
 * this module existed the only in-process binding was lua-openssl, which
 * drags libopenssl3 -- 4.9 MB of flash -- onto a box whose hostapd already
 * carries an AES implementation in libmbedtls, libwolfssl or libopenssl.
 * This file is one source, compiled once per library (-DOPENUF_CRYPTO_MBEDTLS,
 * -DOPENUF_CRYPTO_WOLFSSL, -DOPENUF_CRYPTO_OPENSSL), so the package manager
 * can pick the variant that links against what is already there.
 *
 * Lua 5.1 module "openuf_crypto" (also loads on 5.2+ for the host tests).
 * Every string is raw bytes; keys are 16 bytes (AES-128 is the protocol).
 *
 *   backend()                                   -> name, version
 *   aes_cbc(encrypt, key, iv16, data)           -> out
 *       raw CBC, NO padding: #data must be a multiple of 16. openuf/crypto.lua
 *       does PKCS#7 itself, exactly as it does for lua-openssl.
 *   aes_gcm_encrypt(key, iv, plaintext, aad)    -> ciphertext, tag16
 *   aes_gcm_decrypt(key, iv, ciphertext, tag16, aad) -> plaintext | nil, "auth"
 *       The IV may be any length >= 1: TNBU uses 16 bytes, not GCM's 12-byte
 *       default, and every library here takes the length explicitly.
 *
 * Argument errors raise (they are programming errors); a failed GCM
 * authentication returns nil, "auth" so crypto.lua can raise its own message.
 */

#include <stdlib.h>
#include <string.h>

#include <lua.h>
#include <lauxlib.h>

#if defined(OPENUF_CRYPTO_MBEDTLS)
#  include <mbedtls/aes.h>
#  include <mbedtls/gcm.h>
#  include <mbedtls/cipher.h>
#  include <mbedtls/version.h>
#  define OPENUF_BACKEND_NAME "mbedtls"
#  define OPENUF_BACKEND_VERSION MBEDTLS_VERSION_STRING
#elif defined(OPENUF_CRYPTO_WOLFSSL)
#  include <wolfssl/options.h>
#  include <wolfssl/wolfcrypt/aes.h>
#  include <wolfssl/wolfcrypt/error-crypt.h>
#  include <wolfssl/version.h>
#  define OPENUF_BACKEND_NAME "wolfssl"
#  define OPENUF_BACKEND_VERSION LIBWOLFSSL_VERSION_STRING
#elif defined(OPENUF_CRYPTO_OPENSSL)
#  include <openssl/evp.h>
#  include <openssl/crypto.h>
#  include <openssl/opensslv.h>
#  define OPENUF_BACKEND_NAME "openssl"
#  define OPENUF_BACKEND_VERSION OPENSSL_VERSION_TEXT
#else
#  error "define one of OPENUF_CRYPTO_MBEDTLS, OPENUF_CRYPTO_WOLFSSL, OPENUF_CRYPTO_OPENSSL"
#endif

#define AES_BLOCK 16
#define KEY_LEN   16
#define TAG_LEN   16

/* Key material and plaintext copies are wiped before free. A plain memset
 * before free() is dead-store-eliminated by every optimising compiler; a
 * volatile function pointer is the portable way to keep it. */
static void *(*volatile openuf_memset)(void *, int, size_t) = memset;

static void wipe_free(void *p, size_t n)
{
	if (!p) return;
	if (n) openuf_memset(p, 0, n);
	free(p);
}

/* ---- argument helpers ---------------------------------------------------- */

static const unsigned char *check_bytes(lua_State *L, int idx, size_t *len)
{
	return (const unsigned char *)luaL_checklstring(L, idx, len);
}

static const unsigned char *check_fixed(lua_State *L, int idx, size_t want, const char *what)
{
	size_t len;
	const unsigned char *p = check_bytes(L, idx, &len);
	if (len != want)
		luaL_error(L, "openuf_crypto: %s must be %d bytes, got %d", what, (int)want, (int)len);
	return p;
}

/* nil or absent is an empty AAD. */
static const unsigned char *opt_bytes(lua_State *L, int idx, size_t *len)
{
	if (lua_isnoneornil(L, idx)) { *len = 0; return (const unsigned char *)""; }
	return check_bytes(L, idx, len);
}

/* ---- backends ------------------------------------------------------------ */
/* Each returns 0 on success. cbc(): out is len bytes. gcm_encrypt(): out is
 * len bytes, tag is TAG_LEN. gcm_decrypt(): 1 means the tag did not verify. */

#if defined(OPENUF_CRYPTO_MBEDTLS)

static int be_cbc(int encrypt, const unsigned char *key, const unsigned char *iv,
                  const unsigned char *in, size_t len, unsigned char *out)
{
	mbedtls_aes_context ctx;
	unsigned char iv_copy[AES_BLOCK];
	int rc;
	memcpy(iv_copy, iv, AES_BLOCK);           /* mbedtls advances the IV in place */
	mbedtls_aes_init(&ctx);
	rc = encrypt ? mbedtls_aes_setkey_enc(&ctx, key, 128)
	             : mbedtls_aes_setkey_dec(&ctx, key, 128);
	if (rc == 0)
		rc = mbedtls_aes_crypt_cbc(&ctx, encrypt ? MBEDTLS_AES_ENCRYPT : MBEDTLS_AES_DECRYPT,
		                           len, iv_copy, in, out);
	mbedtls_aes_free(&ctx);
	return rc == 0 ? 0 : -1;
}

static int be_gcm_encrypt(const unsigned char *key, const unsigned char *iv, size_t ivlen,
                          const unsigned char *aad, size_t aadlen,
                          const unsigned char *in, size_t len,
                          unsigned char *out, unsigned char *tag)
{
	mbedtls_gcm_context ctx;
	int rc;
	mbedtls_gcm_init(&ctx);
	rc = mbedtls_gcm_setkey(&ctx, MBEDTLS_CIPHER_ID_AES, key, 128);
	if (rc == 0)
		rc = mbedtls_gcm_crypt_and_tag(&ctx, MBEDTLS_GCM_ENCRYPT, len, iv, ivlen,
		                               aad, aadlen, in, out, TAG_LEN, tag);
	mbedtls_gcm_free(&ctx);
	return rc == 0 ? 0 : -1;
}

static int be_gcm_decrypt(const unsigned char *key, const unsigned char *iv, size_t ivlen,
                          const unsigned char *aad, size_t aadlen,
                          const unsigned char *in, size_t len, const unsigned char *tag,
                          unsigned char *out)
{
	mbedtls_gcm_context ctx;
	int rc;
	mbedtls_gcm_init(&ctx);
	rc = mbedtls_gcm_setkey(&ctx, MBEDTLS_CIPHER_ID_AES, key, 128);
	if (rc == 0)
		rc = mbedtls_gcm_auth_decrypt(&ctx, len, iv, ivlen, aad, aadlen,
		                              tag, TAG_LEN, in, out);
	mbedtls_gcm_free(&ctx);
	if (rc == MBEDTLS_ERR_GCM_AUTH_FAILED) return 1;
	return rc == 0 ? 0 : -1;
}

#elif defined(OPENUF_CRYPTO_WOLFSSL)

static int be_cbc(int encrypt, const unsigned char *key, const unsigned char *iv,
                  const unsigned char *in, size_t len, unsigned char *out)
{
	Aes aes;
	int rc;
	if (wc_AesInit(&aes, NULL, INVALID_DEVID) != 0) return -1;
	rc = wc_AesSetKey(&aes, key, KEY_LEN, iv, encrypt ? AES_ENCRYPTION : AES_DECRYPTION);
	if (rc == 0)
		rc = encrypt ? wc_AesCbcEncrypt(&aes, out, in, (word32)len)
		             : wc_AesCbcDecrypt(&aes, out, in, (word32)len);
	wc_AesFree(&aes);
	return rc == 0 ? 0 : -1;
}

static int be_gcm_encrypt(const unsigned char *key, const unsigned char *iv, size_t ivlen,
                          const unsigned char *aad, size_t aadlen,
                          const unsigned char *in, size_t len,
                          unsigned char *out, unsigned char *tag)
{
	Aes aes;
	int rc;
	if (wc_AesInit(&aes, NULL, INVALID_DEVID) != 0) return -1;
	rc = wc_AesGcmSetKey(&aes, key, KEY_LEN);
	if (rc == 0)
		rc = wc_AesGcmEncrypt(&aes, out, in, (word32)len, iv, (word32)ivlen,
		                      tag, TAG_LEN, aad, (word32)aadlen);
	wc_AesFree(&aes);
	return rc == 0 ? 0 : -1;
}

static int be_gcm_decrypt(const unsigned char *key, const unsigned char *iv, size_t ivlen,
                          const unsigned char *aad, size_t aadlen,
                          const unsigned char *in, size_t len, const unsigned char *tag,
                          unsigned char *out)
{
	Aes aes;
	int rc;
	if (wc_AesInit(&aes, NULL, INVALID_DEVID) != 0) return -1;
	rc = wc_AesGcmSetKey(&aes, key, KEY_LEN);
	if (rc == 0)
		rc = wc_AesGcmDecrypt(&aes, out, in, (word32)len, iv, (word32)ivlen,
		                      tag, TAG_LEN, aad, (word32)aadlen);
	wc_AesFree(&aes);
	if (rc == AES_GCM_AUTH_E) return 1;
	return rc == 0 ? 0 : -1;
}

#elif defined(OPENUF_CRYPTO_OPENSSL)

static int be_cbc(int encrypt, const unsigned char *key, const unsigned char *iv,
                  const unsigned char *in, size_t len, unsigned char *out)
{
	EVP_CIPHER_CTX *ctx = EVP_CIPHER_CTX_new();
	int outl = 0, finl = 0, ok;
	if (!ctx) return -1;
	ok = EVP_CipherInit_ex(ctx, EVP_aes_128_cbc(), NULL, key, iv, encrypt)
	  && EVP_CIPHER_CTX_set_padding(ctx, 0)
	  && EVP_CipherUpdate(ctx, out, &outl, in, (int)len)
	  && EVP_CipherFinal_ex(ctx, out + outl, &finl);
	EVP_CIPHER_CTX_free(ctx);
	return (ok && (size_t)(outl + finl) == len) ? 0 : -1;
}

static int be_gcm_encrypt(const unsigned char *key, const unsigned char *iv, size_t ivlen,
                          const unsigned char *aad, size_t aadlen,
                          const unsigned char *in, size_t len,
                          unsigned char *out, unsigned char *tag)
{
	EVP_CIPHER_CTX *ctx = EVP_CIPHER_CTX_new();
	int outl = 0, finl = 0, ok;
	if (!ctx) return -1;
	ok = EVP_EncryptInit_ex(ctx, EVP_aes_128_gcm(), NULL, NULL, NULL)
	  && EVP_CIPHER_CTX_ctrl(ctx, EVP_CTRL_GCM_SET_IVLEN, (int)ivlen, NULL)
	  && EVP_EncryptInit_ex(ctx, NULL, NULL, key, iv)
	  && (aadlen == 0 || EVP_EncryptUpdate(ctx, NULL, &outl, aad, (int)aadlen))
	  && EVP_EncryptUpdate(ctx, out, &outl, in, (int)len)
	  && EVP_EncryptFinal_ex(ctx, out + outl, &finl)
	  && EVP_CIPHER_CTX_ctrl(ctx, EVP_CTRL_GCM_GET_TAG, TAG_LEN, tag);
	EVP_CIPHER_CTX_free(ctx);
	return ok ? 0 : -1;
}

static int be_gcm_decrypt(const unsigned char *key, const unsigned char *iv, size_t ivlen,
                          const unsigned char *aad, size_t aadlen,
                          const unsigned char *in, size_t len, const unsigned char *tag,
                          unsigned char *out)
{
	EVP_CIPHER_CTX *ctx = EVP_CIPHER_CTX_new();
	int outl = 0, finl = 0, ok, verified;
	if (!ctx) return -1;
	ok = EVP_DecryptInit_ex(ctx, EVP_aes_128_gcm(), NULL, NULL, NULL)
	  && EVP_CIPHER_CTX_ctrl(ctx, EVP_CTRL_GCM_SET_IVLEN, (int)ivlen, NULL)
	  && EVP_DecryptInit_ex(ctx, NULL, NULL, key, iv)
	  && (aadlen == 0 || EVP_DecryptUpdate(ctx, NULL, &outl, aad, (int)aadlen))
	  && EVP_DecryptUpdate(ctx, out, &outl, in, (int)len)
	  && EVP_CIPHER_CTX_ctrl(ctx, EVP_CTRL_GCM_SET_TAG, TAG_LEN, (void *)tag);
	if (!ok) { EVP_CIPHER_CTX_free(ctx); return -1; }
	verified = EVP_DecryptFinal_ex(ctx, out + outl, &finl);   /* 0 = tag mismatch */
	EVP_CIPHER_CTX_free(ctx);
	return verified > 0 ? 0 : 1;
}

#endif

/* ---- Lua functions ------------------------------------------------------- */

static int l_backend(lua_State *L)
{
	lua_pushstring(L, OPENUF_BACKEND_NAME);
	lua_pushstring(L, OPENUF_BACKEND_VERSION);
	return 2;
}

/* aes_cbc(encrypt, key, iv, data) -> out */
static int l_aes_cbc(lua_State *L)
{
	int encrypt = lua_toboolean(L, 1);
	const unsigned char *key = check_fixed(L, 2, KEY_LEN, "key");
	const unsigned char *iv  = check_fixed(L, 3, AES_BLOCK, "iv");
	size_t len;
	const unsigned char *in = check_bytes(L, 4, &len);
	unsigned char *out;

	if (len % AES_BLOCK != 0)
		return luaL_error(L, "openuf_crypto: aes_cbc data must be a multiple of 16 bytes, got %d", (int)len);
	if (len == 0) { lua_pushliteral(L, ""); return 1; }
	out = malloc(len);
	if (!out) return luaL_error(L, "openuf_crypto: out of memory");
	if (be_cbc(encrypt, key, iv, in, len, out) != 0) {
		wipe_free(out, len);
		return luaL_error(L, "openuf_crypto: AES-CBC failed in %s", OPENUF_BACKEND_NAME);
	}
	lua_pushlstring(L, (const char *)out, len);
	wipe_free(out, len);
	return 1;
}

/* aes_gcm_encrypt(key, iv, plaintext, aad) -> ciphertext, tag */
static int l_aes_gcm_encrypt(lua_State *L)
{
	const unsigned char *key = check_fixed(L, 1, KEY_LEN, "key");
	size_t ivlen, len, aadlen;
	const unsigned char *iv  = check_bytes(L, 2, &ivlen);
	const unsigned char *in  = check_bytes(L, 3, &len);
	const unsigned char *aad = opt_bytes(L, 4, &aadlen);
	unsigned char tag[TAG_LEN];
	unsigned char *out;

	if (ivlen == 0) return luaL_error(L, "openuf_crypto: GCM iv must not be empty");
	out = malloc(len ? len : 1);
	if (!out) return luaL_error(L, "openuf_crypto: out of memory");
	if (be_gcm_encrypt(key, iv, ivlen, aad, aadlen, in, len, out, tag) != 0) {
		wipe_free(out, len);
		return luaL_error(L, "openuf_crypto: AES-GCM encrypt failed in %s", OPENUF_BACKEND_NAME);
	}
	lua_pushlstring(L, (const char *)out, len);
	lua_pushlstring(L, (const char *)tag, TAG_LEN);
	wipe_free(out, len);
	openuf_memset(tag, 0, sizeof tag);
	return 2;
}

/* aes_gcm_decrypt(key, iv, ciphertext, tag, aad) -> plaintext | nil, "auth" */
static int l_aes_gcm_decrypt(lua_State *L)
{
	const unsigned char *key = check_fixed(L, 1, KEY_LEN, "key");
	size_t ivlen, len, aadlen;
	const unsigned char *iv  = check_bytes(L, 2, &ivlen);
	const unsigned char *in  = check_bytes(L, 3, &len);
	const unsigned char *tag = check_fixed(L, 4, TAG_LEN, "tag");
	const unsigned char *aad = opt_bytes(L, 5, &aadlen);
	unsigned char *out;
	int rc;

	if (ivlen == 0) return luaL_error(L, "openuf_crypto: GCM iv must not be empty");
	out = malloc(len ? len : 1);
	if (!out) return luaL_error(L, "openuf_crypto: out of memory");
	rc = be_gcm_decrypt(key, iv, ivlen, aad, aadlen, in, len, tag, out);
	if (rc == 1) {
		/* Never hand back the unauthenticated bytes, not even by accident. */
		wipe_free(out, len);
		lua_pushnil(L);
		lua_pushliteral(L, "auth");
		return 2;
	}
	if (rc != 0) {
		wipe_free(out, len);
		return luaL_error(L, "openuf_crypto: AES-GCM decrypt failed in %s", OPENUF_BACKEND_NAME);
	}
	lua_pushlstring(L, (const char *)out, len);
	wipe_free(out, len);
	return 1;
}

static const luaL_Reg openuf_crypto_funcs[] = {
	{ "backend",         l_backend },
	{ "aes_cbc",         l_aes_cbc },
	{ "aes_gcm_encrypt", l_aes_gcm_encrypt },
	{ "aes_gcm_decrypt", l_aes_gcm_decrypt },
	{ NULL, NULL }
};

int luaopen_openuf_crypto(lua_State *L)
{
#if LUA_VERSION_NUM >= 502
	luaL_newlib(L, openuf_crypto_funcs);
#else
	luaL_register(L, "openuf_crypto", openuf_crypto_funcs);
#endif
	lua_pushstring(L, OPENUF_BACKEND_NAME);
	lua_setfield(L, -2, "BACKEND");
	lua_pushstring(L, OPENUF_BACKEND_VERSION);
	lua_setfield(L, -2, "VERSION");
	return 1;
}
