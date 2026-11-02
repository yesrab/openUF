#!/bin/sh
# SPDX-License-Identifier: GPL-3.0-or-later
# rrb-unifi-compat.sh -- is d-malinowski's LATEST rrb-unifi release still
# compatible with this openUF, and if so, bump the pin setup.sh installs.
#
#   sh tools/rrb-unifi-compat.sh            check: pinned vs latest, both test
#                                           suites against each other
#   sh tools/rrb-unifi-compat.sh --bump     ...and on success move the pin to
#                                           the latest (fixture, setup.sh)
#   sh tools/rrb-unifi-compat.sh --tag vX.Y check (or bump) that tag instead
#
# Why: the plugin (openuf-plugin/rrb-unifi.lua in his repository) rewrites
# every 802.11r WLAN this openUF provisions, through the plugin hook
# (openuf/plugins.lua, api 1). setup.sh therefore installs a PINNED release,
# the one tests/fixtures/rrb-unifi/ holds and the suite runs on every
# `lua tests/run_tests.lua`. His releases can change what the plugin expects
# of openUF (a ctx field, an extra.* option, the hook's detection path) and
# this tree can change what it hands him; this script is the check in both
# directions, meant to be run by whoever (or whatever agent) touches
# plugins.lua, ucihelper's FT block, or hears of a new rrb-unifi release:
#
#   1. his tests/run.lua --openuf, from this tree's root: HIS contract tests
#      through OUR plugins.lua and apply_config (what he asserts of openUF);
#   2. our tests/test_rrb_unifi_compat.lua with RRB_UNIFI_PLUGIN pointing at
#      HIS latest plugin (what we assert of the plugin);
#   3. a diff of his plugin and setup tool between the pinned and the latest
#      tag, filtered to the lines that touch the contract surface, printed
#      for a human read: a passing test is not the same as an unchanged
#      contract.
#
# Exit status: 0 latest == pinned, or latest compatible (and bumped, with
# --bump); 1 latest is newer and something failed; 2 the check could not run.
#
# Needs: curl, tar, sha256sum (or shasum), lua with lua-cjson (the suite's
# luarocks environment) and a `bit` library or a 5.3+ Lua (a LuaBitOp-shaped
# shim is written for the latter: the device's Lua 5.1 has luabitop).
set -u

REPO=${RRB_UNIFI_REPO:-d-malinowski/unifi-openwrt-roaming}
ROOT=$(cd "$(dirname "$0")/.." && pwd)
FIXTURE="$ROOT/tests/fixtures/rrb-unifi"
SETUP="$ROOT/setup.sh"
BUMP=0; TAG=""
while [ $# -gt 0 ]; do
	case "$1" in
		--bump) BUMP=1 ;;
		--tag) shift; TAG=${1:-}; [ -n "$TAG" ] || { echo "--tag needs a value" >&2; exit 2; } ;;
		-h|--help) sed -n '2,40p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
		*) echo "unknown option: $1" >&2; exit 2 ;;
	esac
	shift
done

say()  { printf '%s\n' "$*"; }
fail() { printf 'FAIL  %s\n' "$*" >&2; }
ok()   { printf 'ok    %s\n' "$*"; }
die()  { printf 'error %s\n' "$*" >&2; exit 2; }

sha256() {
	if command -v sha256sum >/dev/null 2>&1; then sha256sum "$1" | cut -d' ' -f1
	else shasum -a 256 "$1" | cut -d' ' -f1; fi
}

PINNED=$(sed -n 's/^\(v[0-9.]*\)$/\1/p' "$FIXTURE/VERSION" | head -1)
PINNED_SHA=$(sed -n 's/^\([0-9a-f]\{64\}\)  openuf-plugin\/rrb-unifi\.lua$/\1/p' "$FIXTURE/VERSION" | head -1)
[ -n "$PINNED" ] && [ -n "$PINNED_SHA" ] || die "cannot read the pin from $FIXTURE/VERSION"
SETUP_TAG=$(sed -n 's/^RRB_UNIFI_PINNED_TAG=\(v[0-9.]*\)$/\1/p' "$SETUP")
SETUP_SHA=$(sed -n 's/^RRB_UNIFI_PLUGIN_SHA256=\([0-9a-f]*\)$/\1/p' "$SETUP")
[ "$SETUP_TAG" = "$PINNED" ] && [ "$SETUP_SHA" = "$PINNED_SHA" ] \
	|| die "setup.sh's pin ($SETUP_TAG, $SETUP_SHA) differs from the fixture's ($PINNED, $PINNED_SHA); fix that first"
[ "$(sha256 "$FIXTURE/rrb-unifi.lua")" = "$PINNED_SHA" ] \
	|| die "the fixture's rrb-unifi.lua does not match the sha256 in VERSION"
say "pinned: rrb-unifi $PINNED (plugin sha256 ${PINNED_SHA})"

WORK=$(mktemp -d "${TMPDIR:-/tmp}/rrb-unifi-compat.XXXXXX") || die "mktemp failed"
trap 'rm -rf "$WORK"' EXIT

if [ -z "$TAG" ]; then
	curl -fsSL -H 'Accept: application/vnd.github+json' \
		"https://api.github.com/repos/$REPO/releases/latest" -o "$WORK/latest.json" \
		|| die "cannot read $REPO's latest release (network, or the API rate limit)"
	TAG=$(tr ',' '\n' < "$WORK/latest.json" | sed -n 's/.*"tag_name"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -1)
	[ -n "$TAG" ] || die "no tag_name in the release answer"
fi
say "latest: rrb-unifi $TAG"

curl -fsSL "https://github.com/$REPO/archive/refs/tags/$TAG.tar.gz" -o "$WORK/latest.tgz" \
	|| die "cannot download the $TAG archive"
mkdir -p "$WORK/latest" && tar -xzf "$WORK/latest.tgz" -C "$WORK/latest" || die "cannot unpack the archive"
LATEST=$(dirname "$(find "$WORK/latest" -name rrb-unifi-setup -type f | head -1)")
[ -f "$LATEST/openuf-plugin/rrb-unifi.lua" ] || die "the $TAG archive has no openuf-plugin/rrb-unifi.lua"
LATEST_SHA=$(sha256 "$LATEST/openuf-plugin/rrb-unifi.lua")

if [ "$TAG" = "$PINNED" ]; then
	if [ "$LATEST_SHA" = "$PINNED_SHA" ]; then
		ok "$TAG is the pinned release and its plugin matches the fixture byte for byte"
		exit 0
	fi
	fail "$TAG is the pinned tag but its plugin's sha256 ($LATEST_SHA) is not the fixture's: the tag moved"
	exit 1
fi

# A bit library for his runner on a dev box whose Lua is 5.3+ (CI and the
# device run 5.1 with luabitop).
mkdir -p "$WORK/shim"
if ! lua -e 'require("bit")' >/dev/null 2>&1 && ! lua -e 'require("bit32")' >/dev/null 2>&1; then
	cat > "$WORK/shim/bit.lua" <<'LUA'
local f = load([[return {
  band = function(a, b) return a & b end, bor = function(a, b) return a | b end,
  bxor = function(a, b) return a ~ b end, bnot = function(a) return ~a end,
  lshift = function(a, n) return (a << n) & 0xffffffff end,
  rshift = function(a, n) return (a & 0xffffffff) >> n end }]])
return f()
LUA
fi
export LUA_PATH="$WORK/shim/?.lua;${LUA_PATH:-;}"

status=0
say ""
say "== 1. his contract tests ($TAG) against this tree"
if ( cd "$ROOT" && lua "$LATEST/tests/run.lua" --openuf ) > "$WORK/his.log" 2>&1; then
	ok "$(tail -1 "$WORK/his.log")"
else
	fail "his suite: $(tail -1 "$WORK/his.log")"; grep -a "^FAIL\|^ERROR" "$WORK/his.log" | head -10 >&2; status=1
fi

say "== 2. our contract test against his $TAG plugin"
if ( cd "$ROOT" && RRB_UNIFI_PLUGIN="$LATEST/openuf-plugin/rrb-unifi.lua" lua tests/run_tests.lua ) > "$WORK/ours.log" 2>&1; then
	ok "$(grep -a '^Results:' "$WORK/ours.log")"
else
	fail "our suite with his plugin: $(grep -a '^Results:' "$WORK/ours.log")"
	grep -a -A6 "^FAIL  rrb-unifi" "$WORK/ours.log" | head -30 >&2; status=1
fi

say "== 3. what changed on the contract surface, $PINNED -> $TAG (read this, a green test is not an unchanged contract)"
mkdir -p "$WORK/pinned" && curl -fsSL "https://github.com/$REPO/archive/refs/tags/$PINNED.tar.gz" -o "$WORK/pinned.tgz" \
	&& tar -xzf "$WORK/pinned.tgz" -C "$WORK/pinned" 2>/dev/null
PINNED_DIR=$(dirname "$(find "$WORK/pinned" -name rrb-unifi-setup -type f 2>/dev/null | head -1)")
SURFACE='ctx\.|extra\.|vap\.|api *=|/opt/openuf|/usr/lib/openuf|plugins\.lua|plugins\.enabled|M\.API|/etc/openuf|rrb-unifi\.(main|config)|ft_iface|peer_iface|ft_peer|network\.(vft|ftlink|ftpeer)|init\.d/(openuf|rrb-unifi)|sysupgrade|--yes|confirm|WATCHDOG|hostapd_bss_options|ieee80211r|mobility_domain|r0kh|r1kh|nasid|ft_psk_generate_local|reassociation_deadline'
if [ -n "$PINNED_DIR" ]; then
	for f in openuf-plugin/rrb-unifi.lua rrb-unifi-setup rrb-unifi.init rrb-unifi.config; do
		if ! cmp -s "$PINNED_DIR/$f" "$LATEST/$f"; then
			n=$(diff -u "$PINNED_DIR/$f" "$LATEST/$f" | grep -E '^[-+][^-+]' | grep -cE "$SURFACE")
			say "  $f: changed, $n contract-surface line(s):"
			diff -u "$PINNED_DIR/$f" "$LATEST/$f" | grep -E '^[-+][^-+]' | grep -E "$SURFACE" | head -40 | sed 's/^/    /'
		else
			say "  $f: unchanged"
		fi
	done
	say "  (the translator rrb-unifi.uc and the README are not contract; read their changelog)"
else
	say "  (could not fetch the pinned archive for the diff)"
fi

say ""
if [ $status -ne 0 ]; then
	fail "rrb-unifi $TAG is NOT compatible with this tree as it stands: fix what the suites name, then re-run (with --bump)"
	exit 1
fi
ok "rrb-unifi $TAG passes both suites against this tree"
[ "$BUMP" = 1 ] || { say "run with --bump to move the pin from $PINNED to $TAG"; exit 0; }

cp "$LATEST/openuf-plugin/rrb-unifi.lua" "$FIXTURE/rrb-unifi.lua"
printf '%s\n%s  openuf-plugin/rrb-unifi.lua\n' "$TAG" "$LATEST_SHA" > "$FIXTURE/VERSION"
# busybox/GNU sed -i with no suffix; on macOS use gnu-sed (CLAUDE.md, "Shell code").
sed -i "s/^RRB_UNIFI_TAG=\${RRB_UNIFI_TAG:-$PINNED}/RRB_UNIFI_TAG=\${RRB_UNIFI_TAG:-$TAG}/; \
	s/^RRB_UNIFI_PINNED_TAG=$PINNED\$/RRB_UNIFI_PINNED_TAG=$TAG/; \
	s/^RRB_UNIFI_PLUGIN_SHA256=$PINNED_SHA\$/RRB_UNIFI_PLUGIN_SHA256=$LATEST_SHA/" "$SETUP"
grep -q "^RRB_UNIFI_PINNED_TAG=$TAG\$" "$SETUP" && grep -q "^RRB_UNIFI_PLUGIN_SHA256=$LATEST_SHA\$" "$SETUP" \
	|| die "setup.sh was not updated (macOS sed? put gnu-sed first in PATH)"
ok "pin moved to $TAG: tests/fixtures/rrb-unifi/, setup.sh"
say "left to you: the version named in USAGE.md section 6 and CLAUDE.md, a REVERSE-ENGINEERING.md"
say "session-log row with what changed in the diff above, and 'lua tests/run_tests.lua' once more."
