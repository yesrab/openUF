#!/bin/sh
# Build openuf_crypto.so on a development machine or a CI runner, against the
# host's own copy of mbedtls, wolfssl or openssl, so the module can be tested
# under a real Lua 5.1 without an OpenWrt SDK:
#
#   sh package/openuf-crypto/host-build.sh mbedtls          # one backend
#   sh package/openuf-crypto/host-build.sh all              # every backend found
#   LUA_CPATH="build/host/mbedtls/?.so;;" lua5.1 tests/run_tests.lua
#
# Output: build/host/<backend>/openuf_crypto.so. The suite's native-module
# test picks it up from LUA_CPATH (OPENUF_REQUIRE_NATIVE=1 makes its absence a
# failure; OPENUF_REQUIRE_GCM=1 does the same for the GCM coverage).
#
# Where things are found, and the environment variables that override it:
#   CC, CFLAGS                 the compiler (default cc)
#   LUA_INCDIR                 the directory holding lua.h for Lua 5.1
#                              (pkg-config lua5.1 / lua-5.1, /usr/include/lua5.1,
#                              or a Lua 5.1 source tree's src/)
#   MBEDTLS_DIR, WOLFSSL_DIR,  a prefix (or source tree) for each library,
#   OPENSSL_DIR                when pkg-config and the system paths do not
#                              have it
# On macOS the module is linked with -undefined dynamic_lookup, as every Lua
# C module is there: the interpreter provides the Lua API at load time.
set -eu

ROOT=$(cd "$(dirname "$0")/../.." && pwd)
SRC=$ROOT/package/openuf-crypto/src/openuf_crypto.c
OUT=${2:-$ROOT/build/host}
CC=${CC:-cc}
CFLAGS=${CFLAGS:--O2}
WHAT=${1:-all}

say() { printf '%s\n' "$*"; }
die() { printf 'host-build: %s\n' "$*" >&2; exit 1; }

# ── Lua 5.1 headers ──────────────────────────────────────────────────────────
lua_inc=${LUA_INCDIR:-}
if [ -z "$lua_inc" ]; then
	for pc in lua5.1 lua-5.1 lua51; do
		if pkg-config --exists "$pc" 2>/dev/null; then
			lua_inc=$(pkg-config --variable=includedir "$pc" 2>/dev/null || true)
			[ -n "$lua_inc" ] && [ -f "$lua_inc/lua.h" ] && break
			lua_inc=$(pkg-config --cflags-only-I "$pc" | sed 's/^-I//; s/ .*//')
			[ -n "$lua_inc" ] && [ -f "$lua_inc/lua.h" ] && break
			lua_inc=""
		fi
	done
fi
if [ -z "$lua_inc" ]; then
	for d in /usr/include/lua5.1 /usr/local/include/lua5.1 /usr/include/lua51 \
	         /opt/homebrew/include/lua5.1 /opt/homebrew/opt/lua@5.1/include/lua5.1; do
		[ -f "$d/lua.h" ] && { lua_inc=$d; break; }
	done
fi
[ -n "$lua_inc" ] && [ -f "$lua_inc/lua.h" ] \
	|| die "no Lua 5.1 headers found; set LUA_INCDIR=<dir with lua.h> (apt: liblua5.1-dev)"
grep -q 'LUA_VERSION_NUM.*501' "$lua_inc/lua.h" 2>/dev/null \
	|| say "host-build: warning: $lua_inc/lua.h is not Lua 5.1; the device runs 5.1"

# ── per-library flags ────────────────────────────────────────────────────────
# Prints "<cppflags>|<ldflags>" for a backend, or nothing when it is absent.
flags_for() {
	case "$1" in
		mbedtls)
			if [ -n "${MBEDTLS_DIR:-}" ]; then
				if [ -f "$MBEDTLS_DIR/library/libmbedcrypto.a" ]; then      # a source tree
					printf '%s|%s' "-I$MBEDTLS_DIR/include" "$MBEDTLS_DIR/library/libmbedcrypto.a"
				else
					printf '%s|%s' "-I$MBEDTLS_DIR/include" "-L$MBEDTLS_DIR/lib -lmbedcrypto"
				fi
			elif pkg-config --exists mbedcrypto 2>/dev/null; then
				printf '%s|%s' "$(pkg-config --cflags mbedcrypto)" "$(pkg-config --libs mbedcrypto)"
			elif [ -f /usr/include/mbedtls/gcm.h ] || [ -f /usr/local/include/mbedtls/gcm.h ]; then
				printf '%s|%s' "" "-lmbedcrypto"
			elif [ -f /opt/homebrew/opt/mbedtls/include/mbedtls/gcm.h ]; then
				printf '%s|%s' "-I/opt/homebrew/opt/mbedtls/include" "-L/opt/homebrew/opt/mbedtls/lib -lmbedcrypto"
			fi ;;
		wolfssl)
			if [ -n "${WOLFSSL_DIR:-}" ]; then
				if [ -f "$WOLFSSL_DIR/src/.libs/libwolfssl.a" ]; then        # a built source tree
					printf '%s|%s' "-I$WOLFSSL_DIR" "$WOLFSSL_DIR/src/.libs/libwolfssl.a"
				else
					printf '%s|%s' "-I$WOLFSSL_DIR/include" "-L$WOLFSSL_DIR/lib -lwolfssl"
				fi
			elif pkg-config --exists wolfssl 2>/dev/null; then
				printf '%s|%s' "$(pkg-config --cflags wolfssl)" "$(pkg-config --libs wolfssl)"
			elif [ -f /usr/include/wolfssl/options.h ] || [ -f /usr/local/include/wolfssl/options.h ]; then
				printf '%s|%s' "" "-lwolfssl"
			elif [ -f /opt/homebrew/opt/wolfssl/include/wolfssl/options.h ]; then
				printf '%s|%s' "-I/opt/homebrew/opt/wolfssl/include" "-L/opt/homebrew/opt/wolfssl/lib -lwolfssl"
			fi ;;
		openssl)
			if [ -n "${OPENSSL_DIR:-}" ]; then
				printf '%s|%s' "-I$OPENSSL_DIR/include" "-L$OPENSSL_DIR/lib -lcrypto"
			elif pkg-config --exists libcrypto 2>/dev/null; then
				printf '%s|%s' "$(pkg-config --cflags libcrypto)" "$(pkg-config --libs libcrypto)"
			elif [ -f /usr/include/openssl/evp.h ]; then
				printf '%s|%s' "" "-lcrypto"
			elif [ -f /opt/homebrew/opt/openssl@3/include/openssl/evp.h ]; then
				printf '%s|%s' "-I/opt/homebrew/opt/openssl@3/include" "-L/opt/homebrew/opt/openssl@3/lib -lcrypto"
			fi ;;
		*) die "unknown backend '$1': mbedtls, wolfssl, openssl or all" ;;
	esac
}

shared="-shared -fPIC"
case "$(uname -s)" in Darwin) shared="$shared -undefined dynamic_lookup" ;; esac

build_one() {
	be=$1
	f=$(flags_for "$be")
	if [ -z "$f" ]; then
		if [ "$WHAT" = all ]; then say "host-build: $be: library not found, skipped"; return 0; fi
		die "$be: library not found (set ${be}_DIR, or install the dev package)" | tr '[:lower:]' '[:upper:]'
	fi
	cpp=${f%%|*}; ld=${f#*|}
	def=$(printf 'OPENUF_CRYPTO_%s' "$be" | tr '[:lower:]' '[:upper:]')
	mkdir -p "$OUT/$be"
	# shellcheck disable=SC2086
	$CC $CFLAGS -std=gnu99 -Wall -Wextra $shared "-D$def" "-I$lua_inc" $cpp \
		-o "$OUT/$be/openuf_crypto.so" "$SRC" $ld
	say "built $OUT/$be/openuf_crypto.so ($be)"
	built=$((built + 1))
}

built=0
case "$WHAT" in
	all) for be in mbedtls wolfssl openssl; do build_one "$be"; done ;;
	*)   build_one "$WHAT" ;;
esac
[ "$built" -gt 0 ] || die "nothing built"
say "run the suite with one of them: LUA_CPATH=\"$OUT/<backend>/?.so;;\" OPENUF_REQUIRE_NATIVE=1 lua5.1 tests/run_tests.lua"
