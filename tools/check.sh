#!/bin/sh
# openUF pre-flight check
#
# Run on the OpenWrt device BEFORE install.sh to verify dependencies and
# report any missing packages or mismatched interfaces.
#
# Usage:
#   sh tools/check.sh           — basic check
#   sh tools/check.sh --iface   — also probe interface names

PASS=0
FAIL=0

ok()   { echo "  OK   $1"; PASS=$((PASS+1)); }
fail() { echo "  FAIL $1"; FAIL=$((FAIL+1)); }
info() { echo "  INFO $1"; }

echo "=== openUF pre-flight check ==="
echo ""

# ── Lua runtime ──────────────────────────────────────────────────────────────
echo "[ Lua runtime ]"
if lua -v 2>/dev/null | grep -q "Lua 5"; then
	ok "lua $(lua -v 2>&1 | head -1)"
else
	fail "lua not found or wrong version (need Lua 5.1)"
fi

for pkg in cjson; do
	if lua -e "require('$pkg')" 2>/dev/null; then
		ok "lua require('$pkg')"
	else
		fail "lua require('$pkg') — install: apk add lua-$pkg"
	fi
done

# zlib is optional: OpenWrt 25.12 has no Lua zlib binding. openUF sends
# uncompressed and decompresses controller responses with the in-tree
# pure-Lua inflate (openuf/inflate.lua), so this is informational only.
if lua -e "require('zlib')" 2>/dev/null; then
	ok "lua require('zlib') (optional; enables outbound compression)"
else
	info "lua require('zlib') absent — using in-tree inflate (no package needed)"
fi

if lua -e "require('openssl')" 2>/dev/null; then
	ok "lua require('openssl')"
else
	fail "lua require('openssl') — install: apk add lua-openssl"
fi

if lua -e "require('socket')" 2>/dev/null; then
	ok "lua require('socket')"
else
	fail "lua require('socket') — install: apk add luasocket"
fi

# The binding every wireless read and write goes through (ucihelper.lua,
# switchvlan.lua, usteer.lua). Checked here because its absence is otherwise
# invisible: openUF still adopts and still reports ports and statistics, but
# radio_table goes out empty, the controller has no radio to provision a WLAN
# onto, and not one pushed SSID is ever created. This check did not exist and
# a real device passed the whole preflight while being unable to provision
# anything at all.
if lua -e "require('uci')" 2>/dev/null; then
	ok "lua require('uci')"
else
	fail "lua require('uci') — install: apk add libuci-lua"
	info "     WITHOUT THIS NO SSID CAN EVER BE CREATED. The device will still"
	info "     adopt and report statistics, so nothing else will look wrong."
fi

if lua -e "require('bit')" 2>/dev/null; then
	ok "lua require('bit')"
else
	fail "lua require('bit') — install: apk add luabitop"
fi
echo ""

# ── System tools ─────────────────────────────────────────────────────────────
echo "[ System tools ]"
for cmd in iw ip uci openssl; do
	if command -v "$cmd" > /dev/null 2>&1; then
		ok "$cmd"
	else
		fail "$cmd not found"
	fi
done
echo ""

# ── lldpd ────────────────────────────────────────────────────────────────────
echo "[ LLDP ]"
if command -v lldpd > /dev/null 2>&1; then
	ok "lldpd installed"
	if /etc/init.d/lldpd status 2>/dev/null | grep -qi "running"; then
		ok "lldpd running"
	else
		info "lldpd not running — start with: /etc/init.d/lldpd start"
	fi
	if command -v lldpctl > /dev/null 2>&1; then
		ok "lldpctl available"
	else
		fail "lldpctl not found (usually bundled with lldpd)"
	fi
else
	fail "lldpd not installed — apk add lldpd"
fi
echo ""

# ── Network interfaces ───────────────────────────────────────────────────────
echo "[ Network interfaces ]"
for iface in eth0 eth1; do
	if ip link show "$iface" > /dev/null 2>&1; then
		ADDR=$(cat /sys/class/net/"$iface"/address 2>/dev/null || echo "unknown")
		ok "$iface  MAC=$ADDR"
	else
		info "$iface not found (may be normal depending on your modelmap)"
	fi
done
for radio in radio0 radio1; do
	if iw dev 2>/dev/null | grep -q "$radio"; then
		ok "$radio (wireless)"
	else
		info "$radio not found"
	fi
done
echo ""

# ── OpenSSL AES test ─────────────────────────────────────────────────────────
echo "[ AES-128-CBC smoke test ]"
PT=$(printf "0123456789abcdef")
CT=$(printf "%s" "$PT" | openssl enc -aes-128-cbc \
	-K ba86f2bbe107c7c57eb5f2690775c712 \
	-iv 00000000000000000000000000000000 \
	-nosalt -nopad 2>/dev/null | wc -c)
if [ "$CT" -eq 16 ] 2>/dev/null; then
	ok "openssl AES-128-CBC produces 16-byte output"
else
	fail "openssl AES-128-CBC failed (ct_len=$CT)"
fi
echo ""

# ── /etc/openuf state directory ──────────────────────────────────────────────
echo "[ State directory ]"
if [ -d /etc/openuf ]; then
	ok "/etc/openuf exists"
	if [ -f /etc/openuf/state.json ]; then
		info "state.json present — $(cat /etc/openuf/state.json)"
	else
		info "state.json absent (will be created on first run)"
	fi
else
	info "/etc/openuf absent (install.sh will create it)"
fi
echo ""

# ── Summary ──────────────────────────────────────────────────────────────────
echo "==========================="
echo "Results: $PASS passed, $FAIL failed"
if [ "$FAIL" -gt 0 ]; then
	echo "Fix the failures above before installing openUF."
	exit 1
else
	echo "All checks passed — ready to install."
	exit 0
fi
