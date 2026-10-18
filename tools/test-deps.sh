#!/bin/sh
# Scenario tests for openuf/hook/openuf-deps.sh's choice of AES module: the
# openuf-crypto variant must follow the TLS library hostapd uses, never add a
# second one, honour --crypto and --wpad, fall back to lua-openssl only when
# the feeds carry no native build, and never remove a working provider for
# one that is not there. A stub apk stands in for the package manager.
#   sh tools/test-deps.sh          (from the repository root; exit 0 = pass)
set -u
ROOT=$(cd "$(dirname "$0")/.." && pwd)
T=$(mktemp -d "${TMPDIR:-/tmp}/openuf-deps-test.XXXXXX")
trap 'rm -rf "$T"' EXIT INT TERM
mkdir -p "$T/bin"
cat > "$T/bin/apk" <<'STUB'
#!/bin/sh
D=$DEPS_STATE
cmd=$1; shift
case "$cmd" in
	info) [ "$1" = -e ] && shift; grep -qx "$1" "$D/installed" ;;
	list) grep -qx "$1" "$D/available" && echo "$1-1.0.0-r1 noarch {x} (MIT)" ;;
	update) exit 0 ;;
	add) for p; do
		grep -qx "$p" "$D/available" || { echo "ERROR: unable to select packages: $p" >&2; exit 1; }
		echo "$p" >> "$D/installed"; echo "add $p" >> "$D/log"
		case $p in
			openuf-crypto-mbedtls|openuf-crypto-wolfssl|openuf-crypto-openssl) : > "$D/lua/openuf_crypto.so" ;;
			lua-openssl) : > "$D/lua/openssl.so" ;;
			wpad-mbedtls|wpad-openssl|wpad-wolfssl) printf wnm_sleep_mode > "$D/hostapd" ;;
		esac
	done ;;
	del) for p; do
		grep -vx "$p" "$D/installed" > "$D/i2"; mv "$D/i2" "$D/installed"; echo "del $p" >> "$D/log"
		case $p in openuf-crypto-mbedtls|openuf-crypto-wolfssl|openuf-crypto-openssl) rm -f "$D/lua/openuf_crypto.so" ;; esac
	done ;;
esac
STUB
printf '#!/bin/sh\necho 0\n' > "$T/bin/id"
printf '#!/bin/sh\nexit 0\n' > "$T/bin/wifi"
chmod +x "$T/bin/"*

FEED="openuf-crypto-mbedtls openuf-crypto-wolfssl openuf-crypto-openssl openuf-crypto-luaossl lua-openssl wpad-mbedtls wpad-openssl wpad-wolfssl wpad-basic-mbedtls"
pass=0; fail=0
# scenario <name> <installed> <available> <expected crypto package> <expected pkg log> -- args
scenario() {
	name=$1 inst=$2 avail=$3 want=$4 wantlog=$5; shift 6
	D=$T/$name; mkdir -p "$D/lua" "$D/libs"
	printf '%s\n' $inst > "$D/installed"; printf '%s\n' $avail > "$D/available"; : > "$D/log"
	printf basic > "$D/hostapd"; chmod +x "$D/hostapd"
	for p in $inst; do case $p in
		openuf-crypto-mbedtls|openuf-crypto-openssl|openuf-crypto-wolfssl) : > "$D/lua/openuf_crypto.so" ;;
		lua-openssl) : > "$D/lua/openssl.so" ;;
		wpad-mbedtls|wpad-openssl|wpad-wolfssl) printf wnm_sleep_mode > "$D/hostapd" ;;
	esac; done
	PATH=$T/bin:/usr/bin:/bin DEPS_STATE=$D OPENUF_HOSTAPD=$D/hostapd OPENUF_LUADIR=$D/lua \
		OPENUF_LIBDIR=$D/libs OPENUF_MODDIR=$D OPENUF_DIR=$ROOT/openuf \
		sh "$ROOT/openuf/hook/openuf-deps.sh" "$@" > "$D/out" 2>&1
	got=$(grep -E '^(openuf-crypto-|lua-openssl$)' "$D/installed" | tr '\n' ' ' | sed 's/ $//')
	log=$(tr '\n' ' ' < "$D/log" | sed 's/ $//')
	if [ "$got" = "$want" ] && [ "$log" = "$wantlog" ]; then
		echo "PASS  deps: $name"; pass=$((pass + 1))
	else
		echo "FAIL  deps: $name"; echo "      crypto: want '$want', got '$got'"
		echo "      log:    want '$wantlog'"; echo "              got  '$log'"; sed 's/^/      | /' "$D/out" | tail -5
		fail=$((fail + 1))
	fi
}
scenario stock-basic-mbedtls-gets-mbedtls-module "wpad-basic-mbedtls" "$FEED" \
	"openuf-crypto-mbedtls" "add openuf-crypto-mbedtls del wpad-basic-mbedtls add wpad-mbedtls" -- --install
scenario openssl-box-is-realigned "wpad-openssl openuf-crypto-mbedtls" "$FEED" \
	"openuf-crypto-openssl" "del openuf-crypto-mbedtls add openuf-crypto-openssl" -- --install
scenario no-native-build-falls-back-to-lua-openssl "wpad-wolfssl" "lua-openssl openuf-crypto-luaossl" \
	"openuf-crypto-luaossl" "add openuf-crypto-luaossl" -- --install
scenario explicit-crypto-wins "wpad-mbedtls openuf-crypto-mbedtls" "$FEED" \
	"openuf-crypto-openssl" "del openuf-crypto-mbedtls add openuf-crypto-openssl" -- --install --crypto openssl
scenario wpad-flag-carries-the-crypto-choice "wpad-basic-mbedtls" "$FEED" \
	"openuf-crypto-wolfssl" "add openuf-crypto-wolfssl del wpad-basic-mbedtls add wpad-wolfssl" -- --install --wpad wolfssl
scenario missing-variant-keeps-the-working-one "wpad-wolfssl openuf-crypto-mbedtls" "openuf-crypto-mbedtls lua-openssl" \
	"openuf-crypto-mbedtls" "" -- --install
scenario lua-openssl-alone-counts-as-present "wpad-mbedtls lua-openssl" "lua-openssl" \
	"lua-openssl" "" -- --install
scenario only-wpad-never-touches-crypto "wpad-basic-mbedtls" "$FEED" \
	"" "del wpad-basic-mbedtls add wpad-mbedtls" -- --install --only-wpad

# --check: valid shape, the crypto object, an unknown --crypto refused.
D=$T/check; mkdir -p "$D/lua" "$D/libs"; echo wpad-basic-mbedtls > "$D/installed"; : > "$D/available"; : > "$D/log"
out=$(PATH=$T/bin:/usr/bin:/bin DEPS_STATE=$D OPENUF_HOSTAPD=$D/none OPENUF_LUADIR=$D/lua OPENUF_LIBDIR=$D/libs \
	OPENUF_MODDIR=$D OPENUF_DIR=$ROOT/openuf sh "$ROOT/openuf/hook/openuf-deps.sh" --check)
case "$out" in
	*'"crypto":{"backend":'*'"suggested":"openuf-crypto-mbedtls"'*'"pkg":"openuf-crypto"'*) echo "PASS  deps: --check reports the crypto choice"; pass=$((pass + 1)) ;;
	*) echo "FAIL  deps: --check reports the crypto choice"; echo "      $out" | cut -c1-300; fail=$((fail + 1)) ;;
esac
if PATH=$T/bin:/usr/bin:/bin sh "$ROOT/openuf/hook/openuf-deps.sh" --install --crypto foo >/dev/null 2>&1; then
	echo "FAIL  deps: an unknown --crypto is refused"; fail=$((fail + 1))
else
	echo "PASS  deps: an unknown --crypto is refused"; pass=$((pass + 1))
fi
echo "tools/test-deps.sh: $pass passed, $fail failed"
[ "$fail" = 0 ]
