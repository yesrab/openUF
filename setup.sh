#!/bin/sh
# openUF setup — turn an OpenWrt router into a UniFi U6-InWall
#
# One command, run over SSH on the device itself:
#
#   wget -qO- https://raw.githubusercontent.com/yesrab/openUF/main/setup.sh | sh
#
# It interviews you, converts the router into a pure access point, installs
# every dependency openUF needs, installs openUF with a hardware profile that
# matches the board, and reboots.
#
# Everything it asks can also be answered up front -- see --help -- so the same
# script drives an unattended install.
#
# ── Why the phases run in this order ────────────────────────────────────────
#
#   1. interview     every question, before anything is changed
#   2. packages      needs working internet, so it MUST precede step 4
#   3. openUF        files, service, conf.lua, adoption account
#   4. AP conversion tears down WAN/DHCP/firewall -- the internet may go with
#                    it (this device stops being the router), which is exactly
#                    why no download is left to do by now
#   5. reboot        the only safe way to apply a network teardown you are
#                    currently SSHed in over
#
# A failure in 1-3 leaves a working router. A failure in 4 leaves a working
# router with openUF installed but idle. Neither leaves an unreachable brick,
# and OpenWrt's failsafe mode (hold Reset during boot, then 192.168.1.1) is
# the backstop for the reboot.

set -u

VERSION="1.0"

# ── Where to get openUF from ────────────────────────────────────────────────
# Overridable so a fork, a branch or a local checkout can be installed without
# editing this file:
#   OPENUF_REPO=owner/repo  OPENUF_REF=branch-or-tag  sh setup.sh
#   OPENUF_SRC=/root/openUF sh setup.sh          # a tree already on the device
OPENUF_REPO=${OPENUF_REPO:-yesrab/openUF}
OPENUF_REF=${OPENUF_REF:-main}
OPENUF_SRC=${OPENUF_SRC:-}
OPENUF_TARBALL_URL=${OPENUF_TARBALL_URL:-"https://codeload.github.com/$OPENUF_REPO/tar.gz/$OPENUF_REF"}
OPENUF_SELF_URL=${OPENUF_SELF_URL:-"https://raw.githubusercontent.com/$OPENUF_REPO/$OPENUF_REF/setup.sh"}
export OPENUF_REPO OPENUF_REF OPENUF_TARBALL_URL OPENUF_SELF_URL

INSTALL_DIR=/opt/openuf
STATE_DIR=/etc/openuf

# ─── Output ─────────────────────────────────────────────────────────────────

if [ -t 1 ] && [ -z "${NO_COLOR:-}" ]; then
	C_B='\033[1m'; C_R='\033[31m'; C_Y='\033[33m'; C_G='\033[32m'; C_0='\033[0m'
else
	C_B=''; C_R=''; C_Y=''; C_G=''; C_0=''
fi

say()  { printf '%s\n' "$*"; }
# say() with backslash escapes interpreted, for a line carrying colour --
# printf '%s' would emit a literal \033[1m and clutter the menu.
sayb() { printf '%b\n' "$*"; }
head1() { printf "\n${C_B}== %s${C_0}\n" "$*"; }
ok()   { printf "  ${C_G}ok${C_0}    %s\n" "$*"; }
info() { printf "  ..    %s\n" "$*"; }
warn() { printf "  ${C_Y}warn${C_0}  %s\n" "$*" >&2; }
die()  { printf "\n${C_R}error${C_0} %s\n" "$*" >&2; exit 1; }

# ─── Download ───────────────────────────────────────────────────────────────

# fetch <url> <dest>. Tries every client an OpenWrt image might have.
#
# The retry without certificate validation is for an image built without
# ca-bundle, which is common on space-tight builds and fails every https fetch
# with nothing but an exit code. It is announced rather than silent, because it
# is a real (if small) downgrade -- and the first failure may equally have been
# DNS or a 404, which the retry will not fix either.
fetch() {
	_url=$1; _dst=$2
	if command -v uclient-fetch >/dev/null 2>&1; then
		uclient-fetch -q -O "$_dst" "$_url" 2>/dev/null && return 0
		warn "download failed; retrying without TLS verification"
		uclient-fetch -q --no-check-certificate -O "$_dst" "$_url" 2>/dev/null && return 0
	fi
	if command -v curl >/dev/null 2>&1; then
		curl -fsSL -o "$_dst" "$_url" 2>/dev/null && return 0
	fi
	if command -v wget >/dev/null 2>&1; then
		wget -q -O "$_dst" "$_url" 2>/dev/null && return 0
		wget -q --no-check-certificate -O "$_dst" "$_url" 2>/dev/null && return 0
	fi
	return 1
}

# Can /dev/tty actually be OPENED? `[ -r /dev/tty ]` is not the same question:
# it answers yes in plenty of places where the open then fails with "Device not
# configured" (a detached session, some CI runners), and the re-exec below
# redirects stdin from it -- a failed redirect there killed the script with a
# bare shell error instead of falling back to the non-interactive path. The
# subshell is what keeps a failed open from taking this shell with it.
have_tty() { ( exec < /dev/tty ) >/dev/null 2>&1; }

# ─── Re-exec when piped ─────────────────────────────────────────────────────
#
# `wget -qO- ... | sh` hands the SCRIPT to the shell on stdin, so every `read`
# in the interview would consume the script's own remaining bytes instead of
# the user's answer -- the classic curl-pipe-shell prompt failure: questions
# scroll past unanswered and the install proceeds on garbage.
#
# The fix has to be an exec, not a redirect: `exec < /dev/tty` mid-script would
# take the rest of the script away from the shell that is still reading it.
# Re-fetching a copy to a file and exec'ing that abandons the pipe cleanly.
#
# Skipped when stdin is already a terminal (a normal `sh setup.sh`), when there
# is no controlling terminal (cron, a provisioning system -- and then there is
# nobody to answer anyway), and when the caller passed --yes and has no
# questions coming.
if [ -z "${OPENUF_REEXEC:-}" ] && [ ! -t 0 ]; then
	_want_tty=1
	for _a in "$@"; do
		case "$_a" in
			-y|--yes|--help|-h) _want_tty=0 ;;
		esac
	done
	if [ "$_want_tty" = 1 ] && have_tty; then
		# Already a file on disk (`sh setup.sh` with stdin redirected, or
		# `ssh host 'sh setup.sh'`): re-exec THAT, and no download is needed.
		# The header grep is the guard -- when the script really did arrive on
		# a pipe, $0 is "sh", and a stray file called `sh` in the working
		# directory must not be exec'd in its place.
		if [ -f "$0" ] && head -2 "$0" 2>/dev/null | grep -q 'openUF setup'; then
			OPENUF_REEXEC=1 exec sh "$0" "$@" < /dev/tty
		fi
		_self="/tmp/openuf-setup.$$.sh"
		if fetch "$OPENUF_SELF_URL" "$_self"; then
			OPENUF_REEXEC=1 OPENUF_SELF_TMP="$_self" \
				exec sh "$_self" "$@" < /dev/tty
		fi
		printf "${C_Y}warn${C_0}  could not re-fetch %s to attach a terminal;\n" \
			"$OPENUF_SELF_URL" >&2
		printf "      running with defaults for every question (as if --yes).\n" >&2
		set -- --yes "$@"
	else
		[ "$_want_tty" = 1 ] && {
			printf "${C_Y}warn${C_0}  no controlling terminal, so no question can be asked:\n" >&2
			printf "      using the default answer for every one (as if --yes).\n" >&2
			printf "      To answer them, use an interactive shell (ssh -t), or pass\n" >&2
			printf "      the answers as options -- see --help.\n" >&2
			set -- --yes "$@"
		}
	fi
fi
[ -n "${OPENUF_SELF_TMP:-}" ] && trap 'rm -f "$OPENUF_SELF_TMP"' EXIT

# ─── Options ────────────────────────────────────────────────────────────────

ASSUME_YES=0
DO_AP_MODE=""          # ""=ask 1=yes 0=no
AP_ABSORB_WAN=""       # ""=ask 1=yes 0=no
AP_ADDR=""             # ""=ask | dhcp | <ip>[/<cidr>|,<netmask>]
AP_GATEWAY=""
AP_DNS=""
OPT_MODELMAP=""
OPT_CONTROLLER=""
OPT_BOOTSTRAP=""       # ""=ask 1=yes 0=no
OPT_EXCLUSIVE=""       # ""=ask 1=yes 0=no  (conf.use_only_unifi_wlan)
OPT_L2=""              # ""=derive 1=on 0=off
DO_REBOOT=""           # ""=ask 1=yes 0=no
KEEP_WORK=0

usage() {
	cat <<EOF
openUF setup $VERSION — OpenWrt router -> UniFi U6-InWall

Usage: sh setup.sh [options]

Every option below answers one interview question up front; anything left out
is asked interactively (or takes its default under --yes).

  -y, --yes                 answer every question with its default
      --ap-mode / --no-ap-mode
                            convert the device to a pure AP (default: yes)
      --absorb-wan / --no-absorb-wan
                            put the WAN socket into the LAN bridge, so every
                            socket is a LAN port (default: yes)
      --lan-address ADDR    dhcp (default), or a static address:
                              192.168.1.20/24  |  192.168.1.20,255.255.255.0
      --lan-gateway IP      default route for a static address
      --lan-dns "IP [IP]"   resolvers for a static address
      --modelmap NAME       hardware profile, e.g. jiorouter-ax6000-jidu6101,
                            generic-dualband-ap, or "auto" to generate one
      --controller HOST     controller IP/hostname, or a full inform URL
                            (default: none — rely on L2 auto-discovery)
      --bootstrap / --no-bootstrap
                            create the temporary ubnt/ubnt adoption account
                            (default: yes)
      --exclusive-wlan / --shared-wlan
                            let the controller's WLANs be the only SSIDs on
                            the radios, or keep hand-configured ones too
                            (default: exclusive)
      --l2-announce / --no-l2-announce
                            L2 discovery broadcasts (default: derived — see
                            the "Adoption path" note during the run)
      --reboot / --no-reboot
                            reboot when done (default: yes)
      --keep-work           leave the downloaded tree in /tmp for inspection
  -h, --help                this text

Environment: OPENUF_REPO, OPENUF_REF, OPENUF_SRC, OPENUF_TARBALL_URL
EOF
}

# A value-taking option whose value is missing used to shift off the end of
# the argument list and silently configure the empty string -- so
# "--controller" with a forgotten address became "no controller".
need_val() { [ "$2" -gt 0 ] || die "$1 needs a value"; }

while [ $# -gt 0 ]; do
	case "$1" in
		-y|--yes)            ASSUME_YES=1 ;;
		--ap-mode)           DO_AP_MODE=1 ;;
		--no-ap-mode)        DO_AP_MODE=0 ;;
		--absorb-wan)        AP_ABSORB_WAN=1 ;;
		--no-absorb-wan)     AP_ABSORB_WAN=0 ;;
		--lan-address)       shift; need_val --lan-address "$#"; AP_ADDR=$1 ;;
		--lan-gateway)       shift; need_val --lan-gateway "$#"; AP_GATEWAY=$1 ;;
		--lan-dns)           shift; need_val --lan-dns "$#"; AP_DNS=$1 ;;
		--modelmap)          shift; need_val --modelmap "$#"; OPT_MODELMAP=$1 ;;
		--controller)        shift; need_val --controller "$#"; OPT_CONTROLLER=$1 ;;
		--bootstrap)         OPT_BOOTSTRAP=1 ;;
		--no-bootstrap)      OPT_BOOTSTRAP=0 ;;
		--exclusive-wlan)    OPT_EXCLUSIVE=1 ;;
		--shared-wlan)       OPT_EXCLUSIVE=0 ;;
		--l2-announce)       OPT_L2=1 ;;
		--no-l2-announce)    OPT_L2=0 ;;
		--reboot)            DO_REBOOT=1 ;;
		--no-reboot)         DO_REBOOT=0 ;;
		--keep-work)         KEEP_WORK=1 ;;
		-h|--help)           usage; exit 0 ;;
		*)                   usage >&2; die "unknown option: $1" ;;
	esac
	shift
done

# ─── Prompts ────────────────────────────────────────────────────────────────
#
# The prompt goes to stderr so a caller can capture the answer with `$(...)`
# without the question landing in the variable.

ask() {   # ask <question> <default> -> prints the answer
	_q=$1; _def=${2:-}; _ans=""
	if [ "$ASSUME_YES" = 1 ]; then printf '%s\n' "$_def"; return 0; fi
	if [ -n "$_def" ]; then printf '%s [%s]: ' "$_q" "$_def" >&2
	else                    printf '%s: ' "$_q" >&2
	fi
	IFS= read -r _ans || _ans=""
	[ -n "$_ans" ] || _ans=$_def
	printf '%s\n' "$_ans"
}

ask_yn() {   # ask_yn <question> <Y|N>  -> exit status
	_def=$2
	if [ "$_def" = Y ]; then _hint="Y/n"; else _hint="y/N"; fi
	_ans=$(ask "$1 ($_hint)" "$_def")
	case "$_ans" in
		[Yy]*) return 0 ;;
		[Nn]*) return 1 ;;
		*)     [ "$_def" = Y ] ;;
	esac
}

# Dotted-quad netmask for a CIDR prefix length. Computed rather than looked up
# from a table of the three common ones: a /22 or /26 LAN is entirely ordinary
# and a table miss used to fall through to writing no netmask at all.
prefix_to_netmask() {
	_p=$1
	case "$_p" in ''|*[!0-9]*) return 1 ;; esac
	[ "$_p" -le 32 ] || return 1
	_out=""
	for _i in 1 2 3 4; do
		if [ "$_p" -ge 8 ]; then
			_v=255; _p=$((_p - 8))
		elif [ "$_p" -le 0 ]; then
			_v=0
		else
			_v=$(( 256 - (1 << (8 - _p)) )); _p=0
		fi
		_out="${_out:+$_out.}$_v"
	done
	printf '%s\n' "$_out"
}

# ═══════════════════════════════════════════════════════════════════════════
# Phase 0 — preflight
# ═══════════════════════════════════════════════════════════════════════════

printf "${C_B}openUF setup %s${C_0}  —  OpenWrt router -> UniFi U6-InWall\n" "$VERSION"

[ "$(id -u 2>/dev/null || echo 0)" = 0 ] || die "must run as root."

[ -f /etc/openwrt_release ] || [ -x /sbin/uci ] \
	|| die "this does not look like OpenWrt (no /etc/openwrt_release, no uci)."

command -v uci >/dev/null 2>&1 || die "uci not found; cannot configure this device."

# Package manager. Same reasoning as install.sh's: 25.12 moved to apk, and
# everything before it uses opkg, with identical package names either way.
if command -v apk >/dev/null 2>&1; then
	PKG=apk
	PKG_ADD="apk add"
	pkg_installed() { apk info -e "$1" >/dev/null 2>&1; }
	pkg_add()       { apk add "$@" >/dev/null 2>&1; }
	# Same install, output left on screen: for the REQUIRED set the manager's
	# own error ("unable to select packages", a 404 on the feed) is the only
	# thing that explains a failure this script can otherwise only report as
	# "still missing".
	pkg_add_v()     { apk add "$@"; }
	pkg_del()       { apk del "$@" >/dev/null 2>&1; }
	pkg_update()    { apk update >/dev/null 2>&1; }
elif command -v opkg >/dev/null 2>&1; then
	PKG=opkg
	PKG_ADD="opkg install"
	pkg_installed() { opkg list-installed "$1" 2>/dev/null | grep -q "^$1 "; }
	pkg_add()       { opkg install "$@" >/dev/null 2>&1; }
	pkg_add_v()     { opkg install "$@"; }
	pkg_del()       { opkg remove "$@" >/dev/null 2>&1; }
	pkg_update()    { opkg update >/dev/null 2>&1; }
else
	die "neither apk nor opkg found; cannot install dependencies."
fi

# ═══════════════════════════════════════════════════════════════════════════
# Phase 0b — probe the device
# ═══════════════════════════════════════════════════════════════════════════

head1 "This device"

# /tmp/sysinfo holds exactly these two facts as plain text, written by
# OpenWrt's own boot, and is read first for that reason -- `ubus call system
# board` returns the same values wrapped in JSON that has to be sed'd apart.
# ubus is the fallback for an image that does not populate /tmp/sysinfo.
BOARD=$(cat /tmp/sysinfo/board_name 2>/dev/null || true)
MODEL=$(cat /tmp/sysinfo/model 2>/dev/null || true)
if [ -z "$BOARD" ] && command -v ubus >/dev/null 2>&1; then
	_b=$(ubus call system board 2>/dev/null || true)
	BOARD=$(printf '%s\n' "$_b" \
		| sed -n 's/.*"board_name"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -1)
	[ -n "$MODEL" ] || MODEL=$(printf '%s\n' "$_b" \
		| sed -n 's/.*"model"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -1)
fi
OWRT_VER=$(sed -n "s/^DISTRIB_RELEASE='\(.*\)'/\1/p" /etc/openwrt_release 2>/dev/null | head -1)
TARGET=$(sed -n "s/^DISTRIB_TARGET='\(.*\)'/\1/p" /etc/openwrt_release 2>/dev/null | head -1)

say "  model      ${MODEL:-unknown}"
say "  board      ${BOARD:-unknown}"
say "  openwrt    ${OWRT_VER:-unknown}  ${TARGET:+($TARGET)}  pkg: $PKG"

# Radios. `wifi config` is run when there is no wireless config at all, which
# is the state of a freshly flashed device -- without it there are no radio
# names to profile against and nothing for the controller to provision.
if [ ! -s /etc/config/wireless ]; then
	info "no wireless config yet; generating one (wifi config)"
	wifi config >/dev/null 2>&1 || warn "wifi config failed; radios may be missing"
fi

RADIOS=$(uci show wireless 2>/dev/null \
	| sed -n "s/^wireless\.\([^.=]*\)=wifi-device$/\1/p")
NRADIOS=0
BANDS=""
for r in $RADIOS; do
	NRADIOS=$((NRADIOS + 1))
	b=$(uci -q get "wireless.$r.band" || true)
	# Pre-21.02 boards describe the band as hwmode (11g / 11a / 11na / ...).
	if [ -z "$b" ]; then
		case "$(uci -q get "wireless.$r.hwmode" || true)" in
			*a*) b=5g ;;
			*g*) b=2g ;;
			*)   b=unknown ;;
		esac
	fi
	case " $BANDS " in *" $b "*) ;; *) BANDS="$BANDS $b" ;; esac
done
NBANDS=0
for b in $BANDS; do NBANDS=$((NBANDS + 1)); done
say "  radios     ${NRADIOS} ($(echo "$RADIOS" | tr '\n' ' '))${BANDS:+ bands:$BANDS}"

# Switch generation. It decides which of openUF's two port-reporting shapes a
# profile must use, so it also decides whether a generic profile is usable at
# all: the generics assume eth0/eth1 CPU netdevs, which do not exist on DSA.
IS_DSA=0
for _d in /sys/class/net/*/dsa; do
	[ -d "$_d" ] && IS_DSA=1
done
HAS_SWCONFIG=0
if command -v swconfig >/dev/null 2>&1 && swconfig list 2>/dev/null | grep -q "^Found:"; then
	HAS_SWCONFIG=1
fi
if [ "$IS_DSA" = 0 ] && [ "$HAS_SWCONFIG" = 0 ] && [ -d /sys/class/net/lan1 ]; then
	IS_DSA=1   # kernel-driven switch with per-socket netdevs and no swconfig
fi
if [ "$HAS_SWCONFIG" = 1 ]; then SWITCH_KIND=swconfig
elif [ "$IS_DSA" = 1 ];    then SWITCH_KIND=DSA
else                             SWITCH_KIND="none/unknown"
fi
say "  switch     $SWITCH_KIND"

# Overlay space. openUF is ~130 KB; the optional feature packages together are
# larger than it, and nftables alone is ~490 KB with its kernel modules.
FREE_KB=$(df -k /overlay 2>/dev/null | awk 'NR==2 {print $4}')
[ -n "$FREE_KB" ] || FREE_KB=$(df -k / 2>/dev/null | awk 'NR==2 {print $4}')
say "  free space ${FREE_KB:-?} KB on /overlay"
if [ -n "$FREE_KB" ] && [ "$FREE_KB" -lt 2000 ]; then
	warn "under 2 MB free. lua-openssl alone pulls in libopenssl3 (~4.35 MB"
	warn "installed) and adoption cannot complete without AES-GCM. Expect the"
	warn "package step to fail; bake the crypto into a custom image instead."
fi

ALREADY_INSTALLED=0
[ -d "$INSTALL_DIR" ] && ALREADY_INSTALLED=1
ADOPTED=0
if [ -f "$STATE_DIR/state.json" ] && grep -q '"adopted":true' "$STATE_DIR/state.json" 2>/dev/null; then
	ADOPTED=1
fi
[ "$ALREADY_INSTALLED" = 1 ] && say "  openUF     already installed$([ "$ADOPTED" = 1 ] && echo ' and ADOPTED')"

# ═══════════════════════════════════════════════════════════════════════════
# Phase 1a — get the openUF source, so the interview can read the real
#            modelmap list rather than a hardcoded copy of it
# ═══════════════════════════════════════════════════════════════════════════

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" 2>/dev/null && pwd)
WORK=""
SRC=""

if [ -n "$OPENUF_SRC" ] && [ -f "$OPENUF_SRC/openuf/conf.lua" ]; then
	SRC=$OPENUF_SRC
elif [ -n "${SCRIPT_DIR:-}" ] && [ -f "$SCRIPT_DIR/openuf/conf.lua" ]; then
	SRC=$SCRIPT_DIR
fi

if [ -n "$SRC" ]; then
	head1 "openUF source"
	ok "using the tree at $SRC"
else
	head1 "Downloading openUF"
	WORK="/tmp/openuf-setup-$$"
	mkdir -p "$WORK" || die "cannot create $WORK"
	info "$OPENUF_TARBALL_URL"
	fetch "$OPENUF_TARBALL_URL" "$WORK/openuf-src.tar.gz" \
		|| die "download failed. Check the device's internet access and DNS,
       or place a checkout on the device and re-run with
       OPENUF_SRC=/path/to/openUF sh setup.sh"
	( cd "$WORK" && tar xzf openuf-src.tar.gz ) \
		|| die "could not extract the downloaded archive"
	for _c in "$WORK"/*/openuf/conf.lua "$WORK"/openuf/conf.lua; do
		[ -f "$_c" ] || continue
		SRC=$(dirname "$(dirname "$_c")")
		break
	done
	[ -n "$SRC" ] || die "the archive contains no openuf/conf.lua"
	ok "unpacked to $SRC"
fi

[ -f "$SRC/install.sh" ] || die "$SRC has no install.sh"
MAPDIR="$SRC/openuf/modelmap"
[ -d "$MAPDIR" ] || die "$SRC has no openuf/modelmap directory"

cleanup() {
	if [ -n "$WORK" ] && [ "$KEEP_WORK" = 0 ]; then rm -rf "$WORK"; fi
	[ -n "${OPENUF_SELF_TMP:-}" ] && rm -f "$OPENUF_SELF_TMP"
	return 0
}
trap cleanup EXIT

# ─── Modelmap inventory ─────────────────────────────────────────────────────

# The OpenWrt board names a profile declares (dev.openwrt_boards). Read from
# the profile itself so this script never carries a second, drifting copy of
# the board -> profile table.
map_boards() {
	# A board name CONTAINS a comma ("tplink,archer-c5-v1") and the Lua list
	# separator IS a comma, so the two cannot both be split on. The list
	# separator is the only comma that sits between two quotes: turn exactly
	# that into a placeholder first, then strip the quotes. Splitting on the
	# comma outright yielded "tplink" and "archer-c5-v1" as two board names,
	# so detection matched nothing and every known board fell through to a
	# generic profile.
	sed -n 's/^dev\.openwrt_boards[[:space:]]*=[[:space:]]*{\(.*\)}.*/\1/p' \
		"$MAPDIR/$1.lua" 2>/dev/null \
		| sed 's/"[[:space:]]*,[[:space:]]*"/@/g' | tr -d '"' | tr '@' ' '
}

# A one-line human title, from the profile's header comment -- and ONLY from
# there: the scan quits at the block's closing delimiter rather than skipping
# it, so a profile with an empty --[[ ]]-- header falls back to its file name
# instead of advertising itself in the menu as "]]--" or "local dev = {}".
map_title() {
	# No header block at all (a hand-dropped profile) means there is no title
	# to read, and reading on regardless printed the file's first line of CODE.
	head -1 "$MAPDIR/$1.lua" 2>/dev/null | grep -q '^[[:space:]]*--\[\[' || {
		printf '%s\n' "$1"; return 0
	}
	_t=$(sed -n '2,20{/^[[:space:]]*\]\]/q;s/^[[:space:]]*//;s/[[:space:]]*$//;/^$/d;/^--/d;p;q;}' \
		"$MAPDIR/$1.lua" 2>/dev/null)
	_t=${_t% hardware profile.}
	[ -n "$_t" ] && printf '%s\n' "$_t" || printf '%s\n' "$1"
}

MAPS_BOARD=""
MAPS_GENERIC=""
for f in "$MAPDIR"/*.lua; do
	[ -f "$f" ] || continue
	n=$(basename "$f" .lua)
	case "$n" in
		generic-*|autodetected) MAPS_GENERIC="$MAPS_GENERIC $n" ;;
		*)                      MAPS_BOARD="$MAPS_BOARD $n" ;;
	esac
done

DETECTED_MAP=""
if [ -n "$BOARD" ]; then
	for m in $MAPS_BOARD; do
		for b in $(map_boards "$m"); do
			[ "$b" = "$BOARD" ] && DETECTED_MAP=$m
		done
	done
fi

# The default when the board has no profile of its own. A generic profile is
# the documented fallback and is chosen by radio count -- but only where its
# assumptions can hold: the generics describe a swconfig-era board with two
# CPU netdevs (eth0 = WAN, eth1 = LAN), and on DSA neither netdev exists and
# every socket is its own. Generating a profile from the live device is then
# strictly better than shipping it a port map that names nothing real.
if [ -n "$DETECTED_MAP" ]; then
	DEFAULT_MAP=$DETECTED_MAP
	DEFAULT_WHY="board-specific profile for $BOARD"
elif [ "$IS_DSA" = 1 ]; then
	DEFAULT_MAP=auto
	DEFAULT_WHY="no profile for $BOARD, and the generics assume a swconfig board"
elif [ "$NBANDS" -ge 2 ] || [ "$NRADIOS" -ge 2 ]; then
	DEFAULT_MAP=generic-dualband-ap
	DEFAULT_WHY="no profile for ${BOARD:-this board}; $NRADIOS radios detected"
else
	DEFAULT_MAP=generic-singleband-ap
	DEFAULT_WHY="no profile for ${BOARD:-this board}; single radio detected"
fi

# ═══════════════════════════════════════════════════════════════════════════
# Phase 1b — the interview
# ═══════════════════════════════════════════════════════════════════════════

head1 "1/6  Access-point conversion"
say "  openUF emulates a UniFi ACCESS POINT. A device still acting as a router"
say "  fights the real gateway for DHCP and NAT, so this step strips the router"
say "  role: no WAN interface, no DHCP server, no firewall, everything bridged."

if [ -z "$DO_AP_MODE" ]; then
	if ask_yn "  Convert this device to a pure access point?" Y; then
		DO_AP_MODE=1
	else
		DO_AP_MODE=0
	fi
fi

if [ "$DO_AP_MODE" = 1 ]; then
	if [ -z "$AP_ABSORB_WAN" ]; then
		say ""
		say "  With the router role gone the WAN socket has no job. Adding it to the"
		say "  LAN bridge turns it into one more LAN port, so the uplink cable works"
		say "  in any socket on the case."
		if ask_yn "  Add the WAN socket to the LAN bridge?" Y; then
			AP_ABSORB_WAN=1
		else
			AP_ABSORB_WAN=0
		fi
	fi
	if [ -z "$AP_ADDR" ]; then
		say ""
		say "  Management address. DHCP is right for almost every AP -- the gateway"
		say "  you are adopting into already hands out addresses. A static address"
		say "  is the safer answer if this LAN has no DHCP server."
		AP_ADDR=$(ask "  LAN address ('dhcp', or e.g. 192.168.1.20/24)" dhcp)
	fi
	case "$AP_ADDR" in
		dhcp|DHCP) AP_ADDR=dhcp ;;
		*)
			if [ -z "$AP_GATEWAY" ]; then
				AP_GATEWAY=$(ask "  Default gateway for $AP_ADDR" "")
			fi
			if [ -z "$AP_DNS" ]; then
				AP_DNS=$(ask "  DNS servers (space separated)" "${AP_GATEWAY:-}")
			fi
			;;
	esac
fi

head1 "2/6  Hardware profile (modelmap)"
say "  The profile describes YOUR board: radio names, ethernet sockets, status"
say "  LED. The UniFi identity presented to the controller is separate and"
say "  stays U6-InWall."
say ""
sayb "  ${C_B}Board-specific${C_0}"
MENU=""
i=0
for m in $MAPS_BOARD; do
	i=$((i + 1)); MENU="$MENU $m"
	_mark=""
	[ "$m" = "$DETECTED_MAP" ] && _mark="  ${C_G}<- detected${C_0}"
	printf "   %2d) %-34s %s%b\n" "$i" "$m" "$(map_title "$m")" "$_mark"
done
sayb "  ${C_B}Generic${C_0}"
for m in $MAPS_GENERIC; do
	i=$((i + 1)); MENU="$MENU $m"
	printf "   %2d) %-34s %s\n" "$i" "$m" "$(map_title "$m")"
done
i=$((i + 1)); MENU="$MENU auto"
AUTO_IDX=$i
printf "   %2d) %-34s %s\n" "$i" "auto" \
	"generate one from this device ($SWITCH_KIND)"
say ""
say "  Default: $DEFAULT_MAP  ($DEFAULT_WHY)"

MODELMAP=""
if [ -n "$OPT_MODELMAP" ]; then
	MODELMAP=$OPT_MODELMAP
else
	_defidx=""
	_n=0
	for m in $MENU; do
		_n=$((_n + 1))
		[ "$m" = "$DEFAULT_MAP" ] && _defidx=$_n
	done
	_ans=$(ask "  Profile (number or name)" "${_defidx:-$AUTO_IDX}")
	case "$_ans" in
		''|*[!0-9]*) MODELMAP=$_ans ;;
		*)
			_n=0
			for m in $MENU; do
				_n=$((_n + 1))
				[ "$_n" = "$_ans" ] && MODELMAP=$m
			done
			[ -n "$MODELMAP" ] || die "no such menu entry: $_ans"
			;;
	esac
fi
MODELMAP=${MODELMAP%.lua}
if [ "$MODELMAP" != auto ] && [ ! -f "$MAPDIR/$MODELMAP.lua" ]; then
	die "no such profile: $MODELMAP (looked for $MAPDIR/$MODELMAP.lua)"
fi
if [ "$MODELMAP" = auto ] && [ "$IS_DSA" != 1 ]; then
	die "profile generation is only supported on a DSA board (this one is
       $SWITCH_KIND). On a swconfig board the physical port numbering is
       board truth that cannot be probed -- pick a generic profile and
       correct dev.conf.vlan by hand, per openuf/modelmap/*.lua."
fi

head1 "3/6  Controller"
say "  Leave blank to be discovered on this LAN (the controller's Devices page"
say "  shows the AP by itself). Give an address when the controller is on"
say "  another subnet, or to skip discovery entirely."
if [ -z "$OPT_CONTROLLER" ]; then
	OPT_CONTROLLER=$(ask "  Controller IP / hostname / inform URL" "")
fi
INFORM_URL=""
case "$OPT_CONTROLLER" in
	"")            INFORM_URL="" ;;
	http://*|https://*) INFORM_URL=$OPT_CONTROLLER ;;
	*:*)           INFORM_URL="http://$OPT_CONTROLLER/inform" ;;
	*)             INFORM_URL="http://$OPT_CONTROLLER:8080/inform" ;;
esac
[ -n "$INFORM_URL" ] && ok "inform URL: $INFORM_URL"

head1 "4/6  Adoption account"
say "  L2 adoption works by the controller SSHing in and running"
say "  'syswrapper.sh set-adopt'. Real Ubiquiti hardware ships an ubnt/ubnt"
say "  login for exactly this; openUF can create a locked-down copy of it --"
say "  non-root, allowed to run that one command, auto-disabled once adopted."
say "  Without it (and without a root password) the controller cannot log in"
say "  and adoption fails at 'Connection Interrupted'."
if [ -z "$OPT_BOOTSTRAP" ]; then
	if ask_yn "  Create the bootstrap adoption account?" Y; then
		OPT_BOOTSTRAP=1
	else
		OPT_BOOTSTRAP=0
	fi
fi

head1 "5/6  SSIDs"
say "  openUF only ever creates, edits or deletes wireless sections it named"
say "  'openuf_*' -- your hand-made SSIDs are never rewritten. The question is"
say "  whether they keep BROADCASTING alongside the controller's."
say ""
say "  Note: the openuf_ prefix is a UCI section name, not an SSID filter."
say "  Every WLAN the controller pushes is created whatever it is called."
say ""
say "  Exclusive (recommended): hand-configured SSIDs are switched off, so the"
say "  radios carry only what the controller pushed. Reversible -- openUF"
say "  stamps each SSID it disabled and re-enables exactly those if you flip"
say "  use_only_unifi_wlan back to false."
if [ -z "$OPT_EXCLUSIVE" ]; then
	if ask_yn "  Controller WLANs only?" Y; then
		OPT_EXCLUSIVE=1
	else
		OPT_EXCLUSIVE=0
	fi
fi

# Adoption path. L2 discovery is the shipped default and is what makes the AP
# appear in the controller by itself -- but a controller that discovered a
# device over L2 insists on adopting it over SSH, and fails outright if it
# cannot log in. With no bootstrap account and no root password, broadcasting
# is actively harmful: switching it off makes the controller treat the device
# as L3-discovered and deliver the adoption key over the inform channel
# instead, needing no login at all.
root_has_password() {
	_h=$(grep '^root:' /etc/shadow 2>/dev/null | cut -d: -f2)
	case "$_h" in ""|"!"|"*"|"!!"|"!*") return 1 ;; *) return 0 ;; esac
}
if [ -z "$OPT_L2" ]; then
	if [ "$OPT_BOOTSTRAP" = 1 ] || root_has_password; then
		OPT_L2=1
	else
		OPT_L2=0
	fi
fi

head1 "6/6  Summary"
say "  AP conversion     $([ "$DO_AP_MODE" = 1 ] && echo yes || echo 'no (left as a router)')"
if [ "$DO_AP_MODE" = 1 ]; then
	say "    WAN -> LAN      $([ "$AP_ABSORB_WAN" = 1 ] && echo yes || echo no)"
	say "    LAN address     $AP_ADDR${AP_GATEWAY:+  gw $AP_GATEWAY}${AP_DNS:+  dns $AP_DNS}"
	say "    disabled        firewall, dnsmasq (DHCP/DNS), odhcpd"
fi
say "  Hardware profile  $MODELMAP"
say "  Controller        ${INFORM_URL:-L2 auto-discovery}"
say "  Bootstrap account $([ "$OPT_BOOTSTRAP" = 1 ] && echo 'yes (ubnt/ubnt, self-locking)' || echo no)"
say "  Controller WLANs  $([ "$OPT_EXCLUSIVE" = 1 ] && echo 'exclusive' || echo 'alongside existing SSIDs')"
say "  L2 discovery      $([ "$OPT_L2" = 1 ] && echo on || echo 'off (L3 adoption)')"
if [ "$OPT_L2" = 0 ] && [ -z "$INFORM_URL" ]; then
	warn "L2 discovery is off and no controller address was given, so nothing"
	warn "will reach a controller. Set one later with:"
	warn "  syswrapper.sh set-inform http://<controller>:8080/inform"
fi
if [ "$ADOPTED" = 1 ]; then
	warn "this device is already adopted. Its identity MAC must not change --"
	warn "a different modelmap can move it, and the controller then rejects"
	warn "every inform with HTTP 400 while the old record goes Offline."
fi

if [ -z "$DO_REBOOT" ]; then
	if ask_yn "  Reboot when finished?" Y; then DO_REBOOT=1; else DO_REBOOT=0; fi
fi

say ""
ask_yn "  Proceed?" Y || die "aborted; nothing has been changed."

# ═══════════════════════════════════════════════════════════════════════════
# Phase 2 — packages (while the device is still a working router)
# ═══════════════════════════════════════════════════════════════════════════

head1 "Packages"

info "refreshing the package index ($PKG update)"
pkg_update || warn "index refresh failed; installs below may not resolve"

# REQUIRED. lua-openssl is the one that decides whether adoption can complete
# at all: UniFi 10.4.57 will not finish provisioning a device that has never
# sent a genuine AES-128-GCM inform, and the openssl CLI fallback is CBC-only.
REQUIRED="lua lua-cjson luasocket lua-openssl luabitop iw"
# OPTIONAL. Each absence silently disables exactly one feature -- provisioning
# still reports success while the feature does nothing -- so they go in when
# they fit rather than being merely mentioned.
OPTIONAL="lldpd hostapd-utils usteer ip-bridge nftables tc-tiny"
command -v stat >/dev/null 2>&1 || OPTIONAL="$OPTIONAL coreutils-stat"
case "$INFORM_URL" in https*) OPTIONAL="$OPTIONAL luasec" ;; esac

MISSING=""
for p in $REQUIRED; do pkg_installed "$p" || MISSING="$MISSING $p"; done
if [ -n "$MISSING" ]; then
	info "required:$MISSING"
	pkg_add_v $MISSING || warn "could not install all of:$MISSING"
	STILL=""
	for p in $MISSING; do pkg_installed "$p" || STILL="$STILL $p"; done
	if [ -n "$STILL" ]; then
		die "these are required and could not be installed:$STILL
       Fix the package feeds (or free up flash) and re-run. Without
       lua-openssl in particular the controller will never finish adoption."
	fi
	ok "required packages installed"
else
	ok "required packages already present"
fi

for p in $OPTIONAL; do
	pkg_installed "$p" && continue
	if pkg_add "$p"; then
		ok "$p"
	else
		warn "$p could not be installed; the feature it backs will not work"
	fi
done

# ── wpad ────────────────────────────────────────────────────────────────────
# BSS Transition (802.11v) and Band Steering need a FULL hostapd. A
# wpad-basic-* build has no bss_transition option at all and errors with
# "unknown configuration item 'bss_transition'", taking the radio down with
# it. install.sh notices a missing full build but cannot swap out a basic one:
# the two conflict, so `add` alone fails. Swapping is this script's job.
#
# The replacement keeps the SAME crypto library the device already has
# (mbedtls stays mbedtls), so the swap costs no extra flash and does not drag
# a second TLS stack onto an 8 MB board.
WPAD_FULL="wpad wpad-wolfssl wpad-openssl wpad-mbedtls hostapd hostapd-wolfssl hostapd-openssl hostapd-mbedtls"
wpad_have_full() {
	for p in $WPAD_FULL; do pkg_installed "$p" && return 0; done
	return 1
}
if wpad_have_full; then
	ok "a full wpad/hostapd build is already installed"
else
	CUR=""
	for p in wpad-basic-mbedtls wpad-basic-wolfssl wpad-basic-openssl wpad-basic \
	         wpad-mini hostapd-basic-mbedtls hostapd-basic-wolfssl \
	         hostapd-basic-openssl hostapd-basic; do
		pkg_installed "$p" && { CUR=$p; break; }
	done
	case "$CUR" in
		wpad-basic-mbedtls)    WANT="wpad-mbedtls" ;;
		wpad-basic-wolfssl)    WANT="wpad-wolfssl" ;;
		wpad-basic-openssl)    WANT="wpad-openssl" ;;
		wpad-basic|wpad-mini)  WANT="wpad-mbedtls wpad-wolfssl wpad-openssl wpad" ;;
		hostapd-basic-mbedtls) WANT="hostapd-mbedtls" ;;
		hostapd-basic-wolfssl) WANT="hostapd-wolfssl" ;;
		hostapd-basic-openssl) WANT="hostapd-openssl" ;;
		hostapd-basic)         WANT="hostapd-mbedtls hostapd-wolfssl hostapd-openssl hostapd" ;;
		*)                     WANT="wpad-mbedtls wpad-wolfssl wpad-openssl wpad" ;;
	esac
	if [ -n "$CUR" ]; then
		info "replacing $CUR with a full build (802.11v / Band Steering)"
		# Removed first because the packages conflict. All radios are down
		# between the two steps, which is why this runs before the reboot and
		# why a failed add is rolled back rather than left as no hostapd at all.
		pkg_del "$CUR" || warn "could not remove $CUR"
	else
		info "installing a full wpad build (802.11v / Band Steering)"
	fi
	SWAPPED=""
	for w in $WANT; do
		if pkg_add "$w"; then SWAPPED=$w; break; fi
	done
	if [ -n "$SWAPPED" ]; then
		ok "$SWAPPED installed"
	else
		warn "no full wpad/hostapd build could be installed"
		if [ -n "$CUR" ]; then
			if pkg_add "$CUR"; then
				warn "$CUR put back, so the radios still work. BSS Transition"
				warn "and Band Steering will not."
			else
				die "$CUR was removed and nothing could replace it -- the radios
       have no hostapd. Install one before rebooting:
         $PKG_ADD $CUR"
			fi
		fi
	fi
fi

# ═══════════════════════════════════════════════════════════════════════════
# Phase 3 — generate a profile, if that is what was chosen
# ═══════════════════════════════════════════════════════════════════════════

if [ "$MODELMAP" = auto ]; then
	head1 "Generating a hardware profile"

	# The LAN bridge netdev: the identity MAC, the management address and the
	# VLAN trunk all hang off it. See the jidu6101 profile's header for why a
	# bridge and not a socket.
	LAN_UCI_DEV=$(uci -q get network.lan.device || uci -q get network.lan.ifname || true)
	case "$LAN_UCI_DEV" in
		br-*) GEN_CPUETH=$LAN_UCI_DEV ;;
		*)    GEN_CPUETH=br-lan ;;
	esac

	# One entry per socket. Sourced from the board's own network config -- which
	# is what OpenWrt's board.d generated from the DTS port labels -- rather
	# than from a guess about netdev naming.
	BR_SECTION=$(uci show network 2>/dev/null \
		| sed -n "s/^network\.\([^.=]*\)\.name='${GEN_CPUETH}'$/\1/p" | head -1)
	GEN_PORTS=""
	[ -n "$BR_SECTION" ] && GEN_PORTS=$(uci -q get "network.$BR_SECTION.ports" || true)
	[ -n "$GEN_PORTS" ] || GEN_PORTS=$(uci -q get network.lan.ifname || true)
	GEN_WAN=$(uci -q get network.wan.device || uci -q get network.wan.ifname || true)
	for w in $GEN_WAN; do
		case " $GEN_PORTS " in *" $w "*) ;; *) GEN_PORTS="$GEN_PORTS $w" ;; esac
	done
	[ -n "$GEN_PORTS" ] || die "could not work out this board's ethernet sockets;
       pick a generic profile and edit dev.conf.net.ports by hand."

	# Status LED. Preferring green over the boot/upgrade colours is not
	# cosmetic: OpenWrt's DTS aliases claim specific LEDs for led-boot,
	# led-failsafe, led-running and led-upgrade, and openUF driving one of
	# those means the boot indicator and the controller's Locate action fight
	# over the same GPIO.
	GEN_LED=""
	for pat in '*green*status*' '*green*system*' '*status*' '*system*' '*'; do
		for l in /sys/class/leds/$pat; do
			[ -d "$l" ] || continue
			_n=$(basename "$l")
			case "$_n" in
				*red*|*blue*|*wan*|*internet*) continue ;;
			esac
			GEN_LED=$_n; break
		done
		[ -n "$GEN_LED" ] && break
	done

	GEN_HWASSIGN=""
	for r in $RADIOS; do
		[ -n "$GEN_HWASSIGN" ] && GEN_HWASSIGN="$GEN_HWASSIGN, "
		GEN_HWASSIGN="$GEN_HWASSIGN\"$r\""
	done
	[ -n "$GEN_HWASSIGN" ] || die "no wifi-device radios found in UCI; nothing to profile."

	GEN_FILE="$MAPDIR/autodetected.lua"
	{
		cat <<EOF
--[[
	GENERATED hardware profile — not hand-verified.

	Written by setup.sh $VERSION on first install, by probing this device:
	  board   ${BOARD:-unknown}  (${MODEL:-unknown})
	  openwrt ${OWRT_VER:-unknown} ${TARGET:+/ $TARGET}
	  switch  $SWITCH_KIND

	Generation is only attempted on a DSA board, where every ethernet socket is
	its own netdev with its own carrier, link speed and slice of the bridge FDB
	-- so a correct profile really is derivable from the running kernel. On a
	swconfig board the physical port numbering is board truth that cannot be
	probed, and setup.sh refuses rather than inventing one.

	Two things worth confirming by hand, since a probe cannot:
	  • dev.conf.led — 'ls /sys/class/leds' and pick the LED no OpenWrt alias
	    already drives (led-boot / led-failsafe / led-running / led-upgrade).
	  • the port order below follows this board's UCI bridge membership, which
	    is DTS label order, not necessarily the order printed on the case.

	If your board deserves a permanent profile, copy this file to
	modelmap/<vendor>-<model>.lua, add
	    dev.openwrt_boards = {"${BOARD:-vendor,model}"}
	and setup.sh will preselect it on every device like this one.
]]--

local dev = {}
dev.conf = {}

dev.conf.net = {
	lan_name	= "lan",
	-- The BRIDGE, not a socket: its MAC is the device's identity to the
	-- controller, it carries the management address, and a tagged SSID's
	-- sub-device (br-lan.<vid>) has to hang off it -- one on a bridge PORT
	-- never sees a frame.
	lan_cpueth	= "$GEN_CPUETH",
	lan_vlanid	= 1,
	wan_name	= "wan",
	wan_cpueth	= "${GEN_WAN:-wan}",
	wan_vlanid	= 4090,

	-- One entry per physical socket, from this board's UCI bridge membership.
	-- No 'uplink' flag: the cable's socket is measured at runtime, below.
	ports = {
EOF
		_i=0
		for p in $GEN_PORTS; do
			_i=$((_i + 1))
			printf '\t\t{idx = %d, ifname = "%s"},\n' "$_i" "$p"
		done
		cat <<EOF
	},

	-- Find the uplink socket from the bridge FDB: the port the default
	-- gateway's MAC was learned on. Required, not cosmetic -- without it every
	-- host on the far side of the uplink is reported as a wired client of this
	-- AP, which on a per-socket FDB is the whole LAN segment.
	uplink_detect = "fdb",
}

EOF
		if [ -n "$GEN_LED" ]; then
			printf 'dev.conf.led = "%s"\n' "$GEN_LED"
		else
			cat <<'EOF'
-- No LED could be picked out of /sys/class/leds. Locate and the controller's
-- Manage > LED toggle stay silent no-ops until this is set.
dev.conf.led = nil
EOF
		fi
		cat <<EOF

-- dev.conf.vlan is deliberately absent: it is the swconfig physical-port map
-- and this is a DSA board. Setting it would send inform.lua down the switch
-- path, shelling out to a swconfig that is not installed.

dev.openuf = {}

dev.openuf.uap = {
	ufmodel		= "u6iw",
	hwassign	= {$GEN_HWASSIGN},
}

return dev
EOF
	} > "$GEN_FILE" || die "could not write $GEN_FILE"

	MODELMAP=autodetected
	ok "wrote $GEN_FILE"
	say "     lan_cpueth   $GEN_CPUETH"
	say "     ports        $GEN_PORTS"
	say "     radios       $(echo "$RADIOS" | tr '\n' ' ')"
	say "     led          ${GEN_LED:-none found}"

	# A generated profile is exactly the class of thing that is wrong in a way
	# no test can see, so prove it at least parses and holds the invariants
	# before it is installed as the device's only hardware description.
	if command -v lua >/dev/null 2>&1; then
		if ( cd "$SRC/openuf" && lua -e 'local d = dofile("modelmap/autodetected.lua")
			assert(type(d) == "table" and type(d.conf) == "table", "shape")
			assert(type(d.conf.net.lan_cpueth) == "string", "lan_cpueth")
			assert(#d.conf.net.ports > 0, "ports")
			assert(#d.openuf.uap.hwassign > 0, "hwassign")' >/dev/null 2>&1 ); then
			ok "the generated profile loads and is well-formed"
		else
			die "the generated profile does not load. Re-run and pick a shipped
       profile instead; $GEN_FILE is left in place for inspection."
		fi
	fi
fi

# ═══════════════════════════════════════════════════════════════════════════
# Phase 4 — configure and install openUF
# ═══════════════════════════════════════════════════════════════════════════

head1 "Configuring openUF"

CONF="$SRC/openuf/conf.lua"
[ -f "$CONF" ] || die "$CONF is missing"

# conf.lua is edited in the SOURCE tree, before install.sh copies it: it is one
# of the two files install.sh deliberately does not comment-strip, and doing it
# here means a re-run of setup.sh reproduces the whole configuration rather
# than layering edits onto whatever is already on the device.
conf_set() {   # conf_set <key> <lua value>
	sed -i "s|^\([[:space:]]*\)$1[[:space:]]*=[[:space:]]*.*|\1$1 = $2,|" "$CONF"
	grep -q "^[[:space:]]*$1[[:space:]]*=[[:space:]]*$(
		printf '%s' "$2" | sed 's/[].[^$*\\/]/\\&/g')," "$CONF" \
		|| die "could not set $1 in $CONF (unexpected file layout)"
}

sed -i "s|^dev = dofile(\"modelmap/.*\")|dev = dofile(\"modelmap/$MODELMAP.lua\")|" "$CONF"
grep -q "^dev = dofile(\"modelmap/$MODELMAP.lua\")" "$CONF" \
	|| die "could not select the modelmap in $CONF"
ok "modelmap        $MODELMAP"

if [ "$OPT_EXCLUSIVE" = 1 ]; then
	conf_set use_only_unifi_wlan true
	ok "controller WLANs are exclusive"
else
	conf_set use_only_unifi_wlan false
	ok "hand-configured SSIDs keep broadcasting"
fi

if [ "$OPT_L2" = 1 ]; then
	conf_set l2_announce true
	ok "L2 discovery broadcasts on"
else
	conf_set l2_announce false
	ok "L2 discovery broadcasts off (adopt over L3)"
fi

if [ -n "$INFORM_URL" ]; then
	conf_set inform_url "\"$INFORM_URL\""
	ok "inform_url      $INFORM_URL"
fi

head1 "Installing openUF"

BOOTSTRAP_ARG=""
[ "$OPT_BOOTSTRAP" = 1 ] && BOOTSTRAP_ARG="--bootstrap-adopt"
# install.sh reads openuf/, tools/strip.lua and install.sh by relative path.
( cd "$SRC" && sh install.sh install $BOOTSTRAP_ARG ) \
	|| die "install.sh failed. Nothing about the network has been touched yet,
       so this device is still a working router. Some files may have been
       copied into $INSTALL_DIR -- 'sh install.sh uninstall' clears them."

# conf.lua is the marker, not the shell hook: it is copied unconditionally,
# while the hook's executable bit comes from git and is not guaranteed in
# every checkout. install.sh reports its own copy failure, but an overlay
# that filled up mid-copy has been seen to leave a "successful" install with
# no /opt/openuf at all.
[ -f "$INSTALL_DIR/conf.lua" ] \
	|| die "install.sh reported success but $INSTALL_DIR/conf.lua is missing
       (out of space on /overlay?)"
ok "installed to $INSTALL_DIR"

# state.json wins over conf.lua for the inform URL once it exists, so a device
# that has run openUF before would keep pointing at the old controller. Write
# it through the documented hook rather than editing the file.
if [ -n "$INFORM_URL" ]; then
	if syswrapper.sh set-inform "$INFORM_URL" >/dev/null 2>&1; then
		ok "state.json inform_url set to $INFORM_URL"
	else
		warn "could not set the inform URL in state.json. Run by hand:"
		warn "  syswrapper.sh set-inform $INFORM_URL"
	fi
fi

# ── lldpd chassis id ────────────────────────────────────────────────────────
# Without this the controller cannot place the AP on its topology map and shows
# some unrelated device as its Parent Device: lldpd picks its chassis ID from
# whichever interface it likes (in practice the lowest-numbered one), and the
# gateway then learns this AP under an ID matching no adopted device. Pointing
# it at the same network as dev.conf.net.lan_cpueth makes the two agree.
if [ -f /etc/config/lldpd ]; then
	LAN_NET=$(sed -n 's/.*lan_name[[:space:]]*=[[:space:]]*"\([^"]*\)".*/\1/p' \
		"$MAPDIR/$MODELMAP.lua" 2>/dev/null | head -1)
	[ -n "$LAN_NET" ] || LAN_NET=lan
	uci set "lldpd.config.cid_interface=$LAN_NET"
	uci commit lldpd
	ok "lldpd chassis id follows the '$LAN_NET' network"
elif pkg_installed lldpd; then
	warn "lldpd has no /etc/config/lldpd; set cid_interface by hand or the"
	warn "controller will show the wrong Parent Device (see USAGE.md sec 7)."
fi

# ── Radios ──────────────────────────────────────────────────────────────────
# A freshly flashed OpenWrt ships every radio disabled='1'. openUF writes that
# option only when the controller explicitly pushes a radio status, so a push
# that omits it leaves the radio off -- provisioning "succeeds" and not one
# SSID is ever on the air.
RADIOS_ENABLED=""
for r in $RADIOS; do
	if [ "$(uci -q get "wireless.$r.disabled" || echo 0)" = 1 ]; then
		uci -q delete "wireless.$r.disabled"
		RADIOS_ENABLED="$RADIOS_ENABLED $r"
	fi
done
if [ -n "$RADIOS_ENABLED" ]; then
	uci commit wireless
	ok "enabled radios:$RADIOS_ENABLED (they shipped disabled)"
fi

# ═══════════════════════════════════════════════════════════════════════════
# Phase 5 — the access-point conversion
# ═══════════════════════════════════════════════════════════════════════════

if [ "$DO_AP_MODE" = 1 ]; then
	head1 "Converting to an access point"

	# ── Router interfaces ───────────────────────────────────────────────────
	# The WAN interfaces go first, before the socket is moved into the bridge:
	# a netdev claimed by network.wan and listed as a bridge port at the same
	# time is a conflict netifd resolves by leaving one of them broken.
	WAN_DEV=$(uci -q get network.wan.device || uci -q get network.wan.ifname || true)
	for s in wan wan6; do
		if uci -q get "network.$s" >/dev/null 2>&1; then
			uci -q delete "network.$s"
			ok "removed network.$s"
		fi
	done
	# Any leftover interface with proto pppoe/dhcpv6/wwan etc. is a router
	# uplink too, but deleting sections this script did not recognise is worse
	# than leaving them: they may be a management VLAN. Named, not removed.
	for s in $(uci show network 2>/dev/null | sed -n "s/^network\.\([^.=]*\)=interface$/\1/p"); do
		case "$s" in lan|loopback|globals) continue ;; esac
		_p=$(uci -q get "network.$s.proto" || true)
		case "$_p" in
			pppoe|pppoa|3g|qmi|ncm|wwan|dhcpv6|modemmanager)
				warn "network.$s (proto $_p) looks like another router uplink;"
				warn "left alone -- remove it by hand if it is not a management link."
				;;
		esac
	done

	# ── The WAN socket joins the LAN bridge ─────────────────────────────────
	if [ "$AP_ABSORB_WAN" = 1 ] && [ -n "$WAN_DEV" ]; then
		LAN_DEV=$(uci -q get network.lan.device || true)
		BR_SECTION=""
		if [ -n "$LAN_DEV" ]; then
			BR_SECTION=$(uci show network 2>/dev/null \
				| sed -n "s/^network\.\([^.=]*\)\.name='${LAN_DEV}'$/\1/p" | head -1)
		fi
		if [ -n "$BR_SECTION" ]; then
			# 21.02+ layout: a named `config device` bridge with a ports list.
			CURPORTS=$(uci -q get "network.$BR_SECTION.ports" || true)
			case " $CURPORTS " in
				*" $WAN_DEV "*) ok "$WAN_DEV is already in $LAN_DEV" ;;
				*)
					uci add_list "network.$BR_SECTION.ports=$WAN_DEV"
					ok "$WAN_DEV added to the $LAN_DEV bridge"
					;;
			esac
		else
			# Pre-21.02 layout: the lan interface IS the bridge.
			CURIF=$(uci -q get network.lan.ifname || true)
			if [ "$(uci -q get network.lan.type || true)" = bridge ]; then
				case " $CURIF " in
					*" $WAN_DEV "*) ok "$WAN_DEV is already bridged into lan" ;;
					*)
						uci set "network.lan.ifname=$CURIF $WAN_DEV"
						ok "$WAN_DEV added to the lan bridge"
						;;
				esac
			else
				warn "could not find the LAN bridge; $WAN_DEV left out of it."
				warn "Add it by hand, or that socket stays dead."
			fi
		fi
	elif [ "$AP_ABSORB_WAN" = 1 ]; then
		info "no WAN device to absorb (this board may have no WAN socket)"
	fi

	# ── Management address ──────────────────────────────────────────────────
	if [ "$AP_ADDR" = dhcp ]; then
		uci set network.lan.proto=dhcp
		for o in ipaddr netmask gateway dns ip6assign ip6addr; do
			uci -q delete "network.lan.$o"
		done
		ok "lan takes its address by DHCP"
	else
		case "$AP_ADDR" in
			*/*)  _ip=${AP_ADDR%%/*};  _mask=${AP_ADDR##*/} ;;
			*,*)  _ip=${AP_ADDR%%,*};  _mask=${AP_ADDR##*,} ;;
			*)    _ip=$AP_ADDR;        _mask=24 ;;
		esac
		case "$_mask" in
			*.*) _nm=$_mask ;;
			*)   _nm=$(prefix_to_netmask "$_mask" || true) ;;
		esac
		uci set network.lan.proto=static
		if [ -n "$_nm" ]; then
			uci set "network.lan.ipaddr=$_ip"
			uci set "network.lan.netmask=$_nm"
		else
			# An unparseable prefix. netifd accepts CIDR in ipaddr, which is
			# both shorter and exact, so hand it through rather than guessing
			# a mask -- a wrong /24 would silently strand the AP off-subnet.
			uci -q delete network.lan.netmask
			uci set "network.lan.ipaddr=$_ip/$_mask"
		fi
		[ -n "$AP_GATEWAY" ] && uci set "network.lan.gateway=$AP_GATEWAY"
		if [ -n "$AP_DNS" ]; then
			uci -q delete network.lan.dns
			for d in $AP_DNS; do uci add_list "network.lan.dns=$d"; done
		fi
		uci -q delete network.lan.ip6assign
		ok "lan is static: $AP_ADDR${AP_GATEWAY:+ via $AP_GATEWAY}"
	fi

	uci commit network

	# ── DHCP server off ─────────────────────────────────────────────────────
	# ignore=1 rather than deleting the section: it is the canonical dumb-AP
	# setting, it survives a dnsmasq reinstall, and it is one uci line to undo.
	if [ -f /etc/config/dhcp ]; then
		uci -q set dhcp.lan.ignore=1 2>/dev/null || true
		uci -q delete dhcp.wan
		uci commit dhcp
		ok "DHCP server disabled on lan"
	fi

	# ── Services out of the boot sequence ───────────────────────────────────
	# Disabled AND stopped: disable alone leaves them running until the reboot,
	# and dnsmasq in particular keeps answering DHCP on a LAN that already has
	# a server -- the exact conflict this conversion exists to remove.
	for svc in firewall dnsmasq odhcpd; do
		if [ -x "/etc/init.d/$svc" ]; then
			"/etc/init.d/$svc" disable >/dev/null 2>&1
			"/etc/init.d/$svc" stop    >/dev/null 2>&1
			ok "$svc stopped and removed from startup"
		fi
	done

	# With dnsmasq gone, /tmp/resolv.conf still points at 127.0.0.1 where
	# nothing is listening, so the device cannot resolve a hostname -- which
	# matters when the inform URL is one. /etc/init.d/boot restores this
	# symlink on every boot; do it now so a --no-reboot run also has DNS.
	mkdir -p /tmp/resolv.conf.d
	touch /tmp/resolv.conf.d/resolv.conf.auto
	ln -sf /tmp/resolv.conf.d/resolv.conf.auto /tmp/resolv.conf
	ok "resolver points at the DHCP/static nameservers, not dnsmasq"

	# openUF's own nftables tables live in `bridge openuf` and `bridge
	# openuf_bcfilt`, deliberately outside fw4's `inet fw4`, so stopping the
	# firewall neither removes them nor stops client Block/Unblock working.
	say ""
	say "  Note: the firewall and dnsmasq packages are left installed, only"
	say "  disabled -- re-enabling them is one command if this device ever has"
	say "  to be a router again. openUF's own nft tables are separate from"
	say "  fw4's and keep working with the firewall off."
fi

# ═══════════════════════════════════════════════════════════════════════════
# Phase 6 — done
# ═══════════════════════════════════════════════════════════════════════════

head1 "Done"
say "  Check the daemon:        logread -e openuf"
say "  Hardware profile:       $INSTALL_DIR/modelmap/$MODELMAP.lua"
say "  Configuration:          $INSTALL_DIR/conf.lua"
say "  State (authkey etc):    $STATE_DIR/state.json"
say ""
if [ -n "$INFORM_URL" ]; then
	say "  In the controller: the AP appears as Pending under Devices -> click Adopt."
else
	say "  In the controller: the AP appears in UniFi Discover / Devices by itself"
	say "  (L2 broadcast) -> click Adopt."
fi
if [ "$OPT_BOOTSTRAP" = 1 ]; then
	say "  Adoption logs in as ubnt/ubnt over SSH; the account locks itself"
	say "  once the device is adopted and comes back on a factory reset."
fi
say ""
say "  To undo: sh install.sh uninstall  (state dir is preserved)"

if [ "$DO_AP_MODE" = 1 ]; then
	say ""
	printf "${C_Y}  The network changes above are committed but NOT applied yet.${C_0}\n"
	if [ "$AP_ADDR" = dhcp ]; then
		say "  After the reboot this device takes a DHCP address, so its IP will"
		say "  probably change. Find it in the gateway's lease list, or by the"
		say "  MAC the controller adopts it under."
	else
		# Strip whichever separator was used, so "192.168.1.20,255.255.255.0"
		# does not print the netmask as part of the ssh target.
		_disp=${AP_ADDR%%/*}; _disp=${_disp%%,*}
		say "  After the reboot, SSH to $_disp."
	fi
	say "  If it does not come back: OpenWrt failsafe -- power on, hold Reset"
	say "  until the status LED flashes fast, then 'telnet 192.168.1.1' (or ssh"
	say "  root@192.168.1.1) and run 'firstboot' or fix /etc/config/network."
fi

if [ "$DO_REBOOT" = 1 ]; then
	say ""
	say "  Rebooting in 5 seconds (Ctrl-C to stay up)."
	sleep 5
	reboot
else
	say ""
	if [ "$DO_AP_MODE" = 1 ]; then
		warn "not rebooting. The AP conversion takes effect on the next boot,"
		warn "or immediately with '/etc/init.d/network restart' -- which will"
		warn "drop this SSH session."
	else
		info "not rebooting. Restart openUF with: /etc/init.d/openuf restart"
	fi
fi
