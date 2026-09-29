#!/bin/sh
# openuf-deps -- everything openUF needs from the package manager, including
# the one thing the package cannot declare: a FULL wpad (hostapd) build.
#
#   openuf-deps --check
#       JSON, changing nothing:
#         {"wpad":{"installed":"wpad-basic-mbedtls","full":false,
#                  "suggested":"wpad-mbedtls","choices":["wpad-mbedtls",...]},
#          "packages":[{"pkg":"nftables","present":true,"required":false,
#                       "unlocks":"..."},...],
#          "missing":["kmod-nft-bridge"],"ok":false}
#   openuf-deps --install [--wpad mbedtls|openssl|wolfssl] [--only-wpad]
#       Installs the missing packages, then replaces a basic wpad/hostapd
#       with a full build -- the same crypto library the basic one used, so
#       no second TLS library lands on the flash, unless --wpad names
#       another -- brings the radios back up on the new build and restarts
#       openUF so it re-probes what hostapd can do. The radios are down for
#       about ten seconds in between: run this over a cable, not over WiFi.
#       Exit status 0 once the device has everything.
#
# Why the wpad swap is a command and not a package dependency. Any full
# build will do (wpad-openssl, wpad-wolfssl, wpad-mbedtls, wpad-mesh-*), but
# OpenWrt's dependency syntax has no "any of these": every variant PROVIDES
# the same hostapd and wpa-supplicant names, so a virtual package cannot
# tell a full build from a basic one. Naming one variant in DEPENDS would
# make openuf uninstallable on every stock image, since it CONFLICTS with
# the wpad-basic-* already there, and a postinst cannot swap either: the
# package database is locked by the install that is running it. So the swap
# is this command, the LuCI overview offers it as a button, and the init
# script refuses to start until a full build is in place. A wpad-basic-*
# build rejects the bss_transition option every controller-pushed WLAN
# carries and takes the radio down with it: adopted, silent, no WiFi. Not
# starting is the better failure.
set -u

HOSTAPD=${OPENUF_HOSTAPD:-/usr/sbin/hostapd}   # overridable by the tests only
MODDIR=${OPENUF_MODDIR:-/lib/modules}

if command -v apk >/dev/null 2>&1; then
	PKG_ADD="apk add"
	pkg_installed() { apk info -e "$1" >/dev/null 2>&1; }
	pkg_add()       { apk add "$@"; }
	pkg_del()       { apk del "$@"; }
	pkg_update()    { apk update; }
elif command -v opkg >/dev/null 2>&1; then
	PKG_ADD="opkg install"
	pkg_installed() { opkg list-installed "$1" 2>/dev/null | grep -q "^$1 "; }
	pkg_add()       { opkg install "$@"; }
	pkg_del()       { opkg remove "$@"; }
	pkg_update()    { opkg update; }
else
	PKG_ADD="(no package manager: neither apk nor opkg)"
	pkg_installed() { return 1; }
	pkg_add()       { echo "no package manager found (neither apk nor opkg)" >&2; return 1; }
	pkg_del()       { return 1; }
	pkg_update()    { return 1; }
fi

say()  { printf '%s\n' "$*"; }
warn() { printf 'openuf-deps: %s\n' "$*" >&2; }
die()  { warn "$*"; exit 1; }

# One line per package: name|evidence|mandatory|what it unlocks. The
# evidence is a file or a command, never the package database, so a feature
# baked into the image (a module built in, tc from tc-full, a hand-built
# lua-openssl) counts as present whatever the package list says. Mandatory
# means the daemon cannot run or adopt without it; the others each enable
# one feature. The package depends on all of them either way; a tarball
# install may lack any.
PACKAGES='lua|cmd:lua|yes|the Lua the daemon runs on
luabitop|file:/usr/lib/lua/bit.so|yes|bit operations
lua-cjson|file:/usr/lib/lua/cjson.so|yes|JSON
luasocket|file:/usr/lib/lua/socket/core.so|yes|the inform channel to the controller
lua-openssl|file:/usr/lib/lua/openssl.so|yes|AES-GCM, without which adoption never completes
libuci-lua|file:/usr/lib/lua/uci.so|yes|every wireless read and write
iw|cmd:iw|yes|radio and client statistics
lldpd|cmd:lldpd|no|topology: the parent device shown in the controller
ip-bridge|cmd:bridge|no|wired clients behind the sockets, per-port VLANs on DSA boards
hostapd-utils|cmd:hostapd_cli|no|client kick, minimum RSSI, WiFi Experience ceilings
usteer|cmd:usteerd|no|band steering, roaming assistant
nftables|cmd:nft|no|client blocking, multicast/broadcast blocker, L2 hardening
kmod-nft-bridge|kmod:nft_meta_bridge|no|the blocker and L2 hardening rules
tc-tiny|cmd:tc|no|WiFi speed limit
kmod-sched-act-police|kmod:act_police|no|the upload half of the WiFi speed limit'

# rpcd and cgi-io run with a short PATH; look where OpenWrt puts things.
have_cmd() {
	command -v "$1" >/dev/null 2>&1 && return 0
	for d in /usr/sbin /sbin /usr/bin /bin; do [ -x "$d/$1" ] && return 0; done
	return 1
}

present() {   # present <evidence>
	case "$1" in
		cmd:*)  have_cmd "${1#cmd:}" ;;
		file:*) [ -e "${1#file:}" ] ;;
		kmod:*) ls "$MODDIR"/*/"${1#kmod:}".ko >/dev/null 2>&1 ;;
		*)      return 1 ;;
	esac
}

missing_packages() {   # the names, space-separated
	out=""
	while IFS='|' read -r name how req unlocks; do
		[ -n "$name" ] || continue
		present "$how" || out="$out $name"
	done <<PKGS
$PACKAGES
PKGS
	printf '%s' "${out# }"
}

# ── wpad ────────────────────────────────────────────────────────────────────
# What hostapd can do is read off the binary, not the package name: only a
# full build knows the bss_transition option (a basic one rejects it with
# "unknown configuration item"), and a tarball user may have built their own.
hostapd_full() {
	[ -x "$HOSTAPD" ] && grep -q bss_transition "$HOSTAPD" 2>/dev/null
}

WPAD_VARIANTS="wpad-mesh-openssl wpad-mesh-wolfssl wpad-mesh-mbedtls
wpad-openssl wpad-wolfssl wpad-mbedtls wpad
wpad-basic-openssl wpad-basic-wolfssl wpad-basic-mbedtls wpad-basic wpad-mini
hostapd-openssl hostapd-wolfssl hostapd-mbedtls hostapd
hostapd-basic-openssl hostapd-basic-wolfssl hostapd-basic-mbedtls hostapd-basic hostapd-mini"

wpad_installed() {   # the package name, or nothing and status 1
	for p in $WPAD_VARIANTS; do
		if pkg_installed "$p"; then printf '%s' "$p"; return 0; fi
	done
	return 1
}

# The crypto library a build's name says it uses; empty for wpad, wpad-basic
# and wpad-mini (hostapd's internal crypto).
crypto_of() {
	case "$1" in
		*-openssl) printf openssl ;;
		*-wolfssl) printf wolfssl ;;
		*-mbedtls) printf mbedtls ;;
	esac
}

# The full build to put in place of $1 (possibly empty): hostapd-* for a
# device that has hostapd-* rather than wpad-*, the same crypto library as
# the basic build so no second TLS library is installed, and openssl when
# there is none to match -- lua-openssl already needs libopenssl, so it is
# the one library every openUF device has.
full_for() {   # full_for <installed> <requested library or empty>
	lib=$2
	[ -n "$lib" ] || lib=$(crypto_of "$1")
	[ -n "$lib" ] || lib=openssl
	case "$1" in
		hostapd*) printf 'hostapd-%s' "$lib" ;;
		*)        printf 'wpad-%s' "$lib" ;;
	esac
}

# ── --check ─────────────────────────────────────────────────────────────────
json_str() { printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g' | tr -d '\n'; }

check() {
	cur=$(wpad_installed) || cur=""
	if hostapd_full; then full=true; else full=false; fi
	suggested=$(full_for "$cur" "")
	case "$cur" in
		hostapd*) base=hostapd ;;
		*)        base=wpad ;;
	esac
	printf '{"wpad":{"installed":%s,"full":%s,"suggested":"%s","choices":["%s-mbedtls","%s-openssl","%s-wolfssl"]},' \
		"$( [ -n "$cur" ] && printf '"%s"' "$(json_str "$cur")" || printf null )" \
		"$full" "$suggested" "$base" "$base" "$base"
	printf '"packages":['
	first=1
	while IFS='|' read -r name how req unlocks; do
		[ -n "$name" ] || continue
		if present "$how"; then p=true; else p=false; fi
		if [ "$req" = yes ]; then r=true; else r=false; fi
		[ "$first" = 1 ] || printf ','
		first=0
		printf '{"pkg":"%s","present":%s,"required":%s,"unlocks":"%s"}' "$name" "$p" "$r" "$(json_str "$unlocks")"
	done <<PKGS
$PACKAGES
PKGS
	printf '],"missing":['
	first=1
	for m in $(missing_packages); do
		[ "$first" = 1 ] || printf ','
		first=0
		printf '"%s"' "$m"
	done
	printf '],"ok":%s}\n' "$( [ "$full" = true ] && [ -z "$(missing_packages)" ] && printf true || printf false )"
}

# ── --install ───────────────────────────────────────────────────────────────
# One package at a time: apk and opkg stop at the first failure, and one
# package a feed cannot resolve (a kernel module on a snapshot whose kernel
# has moved on) must not cost the others. The manager's own words are shown
# on failure, since they name the reason.
add_one() {   # add_one <package>
	if out=$(pkg_add "$1" 2>&1); then
		say "  $1 installed"
		return 0
	fi
	warn "could not install $1:"
	printf '%s\n' "$out" | tail -n 5 | sed 's/^/    /' >&2
	return 1
}

install() {   # install <only-wpad 0|1> <library or empty>
	only_wpad=$1; lib=$2
	changed=0
	missing=""
	[ "$only_wpad" = 1 ] || missing=$(missing_packages)
	if [ -n "$missing" ] || ! hostapd_full; then
		pkg_update >/dev/null 2>&1 || warn "package index refresh failed; installs below may not resolve"
	fi
	if [ "$only_wpad" != 1 ]; then
		if [ -n "$missing" ]; then
			say "installing: $missing"
			for p in $missing; do add_one "$p" && changed=1; done
		else
			say "every package openUF uses is installed"
		fi
	fi
	if hostapd_full; then
		cur=$(wpad_installed) || cur="a build not from a package"
		say "hostapd is a full build ($cur): nothing to replace"
	else
		cur=$(wpad_installed) || cur=""
		want=$(full_for "$cur" "$lib")
		if [ -n "$cur" ]; then
			# Removed first because the two conflict. The radios are down
			# from here until the new build is up.
			say "replacing $cur with $want (the radios are down until the new build is up)"
			pkg_del "$cur" >/dev/null 2>&1 || warn "could not remove $cur; trying to install $want over it"
		else
			say "installing $want (no hostapd/wpad package is installed)"
		fi
		if add_one "$want"; then
			changed=1
		else
			# Never leave the device without a hostapd: put the basic one back.
			if [ -n "$cur" ] && pkg_add "$cur" >/dev/null 2>&1; then
				die "$cur put back, so the radios work again; openUF will not start until a full build is installed ($PKG_ADD $want)"
			elif [ -n "$cur" ]; then
				die "$cur was removed and nothing could replace it: the radios have NO hostapd. Install one now: $PKG_ADD $cur"
			else
				die "install a full build by hand: $PKG_ADD $want"
			fi
		fi
		# The package scripts stop the old daemon and start the new one, but
		# netifd configured the radios against the old one, and a plain
		# `wifi reload` sees no changed configuration and does nothing.
		[ -x /etc/init.d/wpad ] && /etc/init.d/wpad restart >/dev/null 2>&1
		if wifi up >/dev/null 2>&1; then say "  radios brought up on the new build"; fi
	fi
	if [ "$changed" = 1 ] && [ -x /etc/init.d/openuf ]; then
		# The capability bits openUF claims are probed once, at start.
		if /etc/init.d/openuf restart >/dev/null 2>&1; then say "openUF restarted"; fi
	fi
	if hostapd_full && [ -z "$(missing_packages)" ]; then
		say "openUF has everything it needs"
		return 0
	fi
	warn "openUF is still missing something: openuf deps --check"
	return 1
}

# ── main ────────────────────────────────────────────────────────────────────
MODE=""; LIB=""; ONLY_WPAD=0
while [ $# -gt 0 ]; do
	case "$1" in
		--check)     MODE=check ;;
		--install)   MODE=install ;;
		--only-wpad) ONLY_WPAD=1 ;;
		--wpad)
			shift; [ $# -gt 0 ] || die "--wpad needs a value: mbedtls, openssl or wolfssl"
			case "$1" in
				mbedtls|openssl|wolfssl) LIB=$1 ;;
				wpad-mbedtls|wpad-openssl|wpad-wolfssl|hostapd-mbedtls|hostapd-openssl|hostapd-wolfssl) LIB=${1##*-} ;;
				*) die "--wpad: mbedtls, openssl or wolfssl, not '$1'" ;;
			esac
			;;
		-h|--help) sed -n '2,20p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
		*) die "unknown option: $1" ;;
	esac
	shift
done
case "$MODE" in
	check)   check ;;
	install) [ "$(id -u)" = 0 ] || die "must run as root"; install "$ONLY_WPAD" "$LIB" ;;
	*)       sed -n '2,20p' "$0" | sed 's/^# \{0,1\}//'; exit 2 ;;
esac
