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
#          "missing":["kmod-nft-bridge"],"ok":false,
#          "services":[{"name":"openuf-rrb","plugin":"rrb","enabled":true,
#                       "running":true}],
#          "theme":{"package":"luci-theme-halo","installed":false,"luci":true,
#                   "free_kb":5120,"min_free_kb":4096,"wanted":true}}
#   openuf-deps --install [--wpad mbedtls|openssl|wolfssl] [--only-wpad] [--no-theme]
#       Installs the missing packages, then replaces a basic wpad/hostapd
#       with a full build -- the same crypto library the basic one used, so
#       no second TLS library lands on the flash, unless --wpad names
#       another -- brings the radios back up on the new build and restarts
#       openUF so it re-probes what hostapd can do. The radios are down for
#       about ten seconds in between: run this over a cable, not over WiFi.
#       Plugins (plugins.lua) declare packages and services: the packages
#       join the table above (`openuf probe plugin-deps` lists them), and
#       the services are enabled and started here. The 802.11r translator
#       (plugins/rrb.lua) declares ucode-mod-socket, kmod-veth and
#       openuf-rrb that way.
#       Exit status 0 once the device has everything. The Halo LuCI theme
#       (luci-theme-halo, the look openUF's device page shares) comes along
#       only where LuCI is installed and the flash has room to spare; it is
#       cosmetic, never counts as missing, and --no-theme skips it.
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
LUCIDIR=${OPENUF_LUCIDIR:-/usr/share/ucode/luci}
OVERLAY=${OPENUF_OVERLAY:-/overlay}

if command -v apk >/dev/null 2>&1; then
	PKG_ADD="apk add"
	# exact name: `apk info -e` is also true for a package that PROVIDES it
	pkg_installed() { apk list -I "$1" 2>/dev/null | grep -q "^$1-[0-9]"; }
	pkg_available() { apk list "$1" 2>/dev/null | grep -q "^$1-[0-9]"; }
	pkg_add()       { apk add "$@"; }
	pkg_del()       { apk del "$@"; }
	pkg_update()    { apk update; }
elif command -v opkg >/dev/null 2>&1; then
	PKG_ADD="opkg install"
	pkg_installed() { opkg list-installed "$1" 2>/dev/null | grep -q "^$1 "; }
	pkg_available() { opkg list "$1" 2>/dev/null | grep -q "^$1 "; }
	pkg_add()       { opkg install "$@"; }
	pkg_del()       { opkg remove "$@"; }
	pkg_update()    { opkg update; }
else
	PKG_ADD="(no package manager: neither apk nor opkg)"
	pkg_installed() { return 1; }
	pkg_available() { return 1; }
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
kmod-ifb|kmod:ifb|no|the upload half of the WiFi speed limit, queued
kmod-sched-act-police|kmod:act_police|no|the upload half of the WiFi speed limit, policed when there is no IFB'

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
	# wnm_sleep_mode, not bss_transition: a basic binary carries the
	# bss_transition_* event names too, so that grep passed on it.
	[ -x "$HOSTAPD" ] && grep -q wnm_sleep_mode "$HOSTAPD" 2>/dev/null
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

# ── the Halo theme ──────────────────────────────────────────────────────────
# luci-theme-halo is the LuCI theme openUF's device page is styled after. It
# is cosmetic, so it goes where it costs nothing that matters: a box with
# LuCI on it and the flash to spare (THEME_MIN_FREE_KB on the overlay before
# installing, many times the theme's own size, so the room openUF's state and
# a later upgrade need is never what it eats). Elsewhere it is skipped, with
# the reason, and never reported as missing.
THEME_PKG=luci-theme-halo
THEME_MIN_FREE_KB=${OPENUF_THEME_MIN_FREE_KB:-4096}

overlay_free_kb() {
	for d in "$OVERLAY" /; do
		kb=$(df -k "$d" 2>/dev/null | awk 'NR==2 {print $4}')
		[ -n "$kb" ] && { printf '%s' "$kb"; return 0; }
	done
	printf 0
}

luci_present() { [ -d "$LUCIDIR/template" ]; }
theme_present() { pkg_installed "$THEME_PKG" || [ -d "${OPENUF_WWW:-/www}/luci-static/halo" ]; }

# Prints nothing; status 0 when the theme should be installed now.
theme_wanted() {
	luci_present || return 1
	theme_present && return 1
	[ "$(overlay_free_kb)" -ge "$THEME_MIN_FREE_KB" ]
}

install_theme() {
	luci_present || return 0
	if theme_present; then
		say "  the Halo theme is installed"
		return 0
	fi
	free=$(overlay_free_kb)
	if [ "$free" -lt "$THEME_MIN_FREE_KB" ]; then
		say "  skipping the Halo theme: ${free} KB free on the flash, it is only installed with ${THEME_MIN_FREE_KB} KB to spare"
		return 0
	fi
	if ! pkg_available "$THEME_PKG"; then
		say "  the Halo theme is not in this device's package feeds"
		return 0
	fi
	add_one "$THEME_PKG"
}

# ── plugins ─────────────────────────────────────────────────────────────────
# A plugin (plugins.lua; the built-in rrb is the 802.11r translator for
# genuine UniFi APs) declares the packages it needs and the procd services it
# runs. `openuf probe plugin-deps` prints them, one per line, in this table's
# own format for packages (name|evidence|no|what it unlocks (plugin X)) and
# as service|NAME|PLUGIN for services. The packages are appended to PACKAGES
# once, so `--check` and `--install` treat them like every other optional
# one; the services are enabled and started by install.
openuf_dir() {
	for d in /usr/lib/openuf /opt/openuf; do
		[ -f "$d/inform.lua" ] && { printf '%s' "$d"; return 0; }
	done
	return 1
}

PLUGIN_DEPS=""
if d=$(openuf_dir) && have_cmd lua; then
	PLUGIN_DEPS=$(cd "$d" && lua hook/probe.lua plugin-deps 2>/dev/null)
fi
while IFS='|' read -r name how req unlocks; do
	[ -n "$name" ] || continue
	[ "$name" = service ] && continue
	case "$PACKAGES" in
		*"$name|"*) ;;   # already in the table
		*) PACKAGES="$PACKAGES
$name|$how|$req|$unlocks" ;;
	esac
done <<PD
$PLUGIN_DEPS
PD

plugin_services() {   # lines: NAME PLUGIN
	printf '%s\n' "$PLUGIN_DEPS" | sed -n 's/^service|\([^|]*\)|\(.*\)$/\1 \2/p'
}

service_running() { [ -x "/etc/init.d/$1" ] && "/etc/init.d/$1" running >/dev/null 2>&1; }
service_enabled() { [ -x "/etc/init.d/$1" ] && "/etc/init.d/$1" enabled >/dev/null 2>&1; }

# Enable and start every service a plugin declares. Never fatal to a caller.
start_plugin_services() {
	plugin_services | while read -r svc plug; do
		[ -n "$svc" ] || continue
		if [ ! -x "/etc/init.d/$svc" ]; then
			warn "plugin $plug: its service /etc/init.d/$svc is not installed"
			continue
		fi
		"/etc/init.d/$svc" enable >/dev/null 2>&1
		if service_running "$svc"; then
			say "  $svc (plugin $plug) is running"
		elif "/etc/init.d/$svc" start >/dev/null 2>&1; then
			say "  $svc (plugin $plug) started"
		else
			warn "$svc (plugin $plug) did not start: /etc/init.d/$svc start"
		fi
	done
	return 0
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
	printf '],"ok":%s,' "$( [ "$full" = true ] && [ -z "$(missing_packages)" ] && printf true || printf false )"
	printf '"services":['
	first=1
	plugin_services | while read -r svc plug; do
		[ -n "$svc" ] || continue
		if service_enabled "$svc"; then e=true; else e=false; fi
		if service_running "$svc"; then r=true; else r=false; fi
		[ "$first" = 1 ] || printf ','
		first=0
		printf '{"name":"%s","plugin":"%s","enabled":%s,"running":%s}' "$(json_str "$svc")" "$(json_str "$plug")" "$e" "$r"
	done
	printf '],'
	if luci_present; then l=true; else l=false; fi
	if theme_present; then t=true; else t=false; fi
	if theme_wanted; then w=true; else w=false; fi
	printf '"theme":{"package":"%s","installed":%s,"luci":%s,"free_kb":%s,"min_free_kb":%s,"wanted":%s}}\n' \
		"$THEME_PKG" "$t" "$l" "$(overlay_free_kb)" "$THEME_MIN_FREE_KB" "$w"
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

install() {   # install <only-wpad 0|1> <library or empty> <theme 0|1>
	only_wpad=$1; lib=$2; theme=${3:-1}
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
		# Cosmetic, after everything openUF needs, so a full flash costs the
		# theme and never a feature.
		[ "$theme" = 1 ] && install_theme
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
	# The services the plugins declare, once their packages are in.
	[ "$only_wpad" = 1 ] || start_plugin_services
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
MODE=""; LIB=""; ONLY_WPAD=0; THEME=1
while [ $# -gt 0 ]; do
	case "$1" in
		--check)     MODE=check ;;
		--install)   MODE=install ;;
		--only-wpad) ONLY_WPAD=1 ;;
		--no-theme)  THEME=0 ;;
		--wpad)
			shift; [ $# -gt 0 ] || die "--wpad needs a value: mbedtls, openssl or wolfssl"
			case "$1" in
				mbedtls|openssl|wolfssl) LIB=$1 ;;
				wpad-mbedtls|wpad-openssl|wpad-wolfssl|hostapd-mbedtls|hostapd-openssl|hostapd-wolfssl) LIB=${1##*-} ;;
				*) die "--wpad: mbedtls, openssl or wolfssl, not '$1'" ;;
			esac
			;;
		-h|--help) sed -n '2,31p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
		*) die "unknown option: $1" ;;
	esac
	shift
done
case "$MODE" in
	check)   check ;;
	install) [ "$(id -u)" = 0 ] || die "must run as root"; install "$ONLY_WPAD" "$LIB" "$THEME" ;;
	*)       sed -n '2,31p' "$0" | sed 's/^# \{0,1\}//'; exit 2 ;;
esac
