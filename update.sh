#!/bin/sh
# openUF updater — upgrade an installed openUF in place, on the device, keeping
# its identity, its configuration and its adoption.
#
#   openuf-update                        # latest main from GitHub
#   openuf-update --ref v1.2.0           # a tag or branch instead of main
#   openuf-update --from /tmp/x.tar.gz   # a tarball already on the device
#   openuf-update --from /tmp/openUF     # an unpacked tree already on the device
#   openuf-update --check                # show what is installed; change nothing
#   openuf-update --no-rollback          # keep a failed update in place for debugging
#
# What it does, in this order:
#
#   1. fetch and unpack (or take --from), and refuse a tree with no install.sh
#   2. back up /opt/openuf and /etc/openuf to a tarball in /tmp
#   3. sh install.sh install  -- which KEEPS the device's conf.lua, and with it
#      the modelmap, and with THAT the identity MAC the controller adopted the
#      device under (CLAUDE.md, "lan_cpueth decides IDENTITY"). state.json is
#      never touched. That is what makes this safe on an adopted AP: nothing
#      to re-adopt, nothing to re-provision.
#   4. restart the service and WAIT for the new daemon to complete an inform
#      cycle (it writes /tmp/openuf-status after each one)
#   5. if it does not within the deadline, put the backup back and restart
#      the old version, loudly
#
# Nothing here touches the network config or the radios. A daemon restart
# between two ten-second informs is invisible to the controller and to
# clients: `wifi reload` only ever happens on a config push.
#
# Busybox ash. Check with `bash -n update.sh && dash -n update.sh`.

set -u

OPENUF_REPO=${OPENUF_REPO:-yesrab/openUF}
OPENUF_REF=${OPENUF_REF:-main}
OPENUF_TARBALL_URL=${OPENUF_TARBALL_URL:-}

INSTALL_DIR=/opt/openuf
STATE_DIR=/etc/openuf
STATUS_FILE=/tmp/openuf-status
HEALTH_DEADLINE=75      # seconds to wait for the new daemon's first completed cycle

say()  { printf '%s\n' "$*"; }
ok()   { printf '  ok    %s\n' "$*"; }
info() { printf '  ..    %s\n' "$*"; }
warn() { printf '  warn  %s\n' "$*" >&2; }
die()  { printf '\nerror %s\n' "$*" >&2; exit 1; }

# ─── Options ────────────────────────────────────────────────────────────────
FROM=""
CHECK=0
ROLLBACK=1
RESTART=1
KEEP_WORK=0
while [ $# -gt 0 ]; do
	case "$1" in
		--from)        shift; [ $# -gt 0 ] || die "--from needs a path"; FROM=$1 ;;
		--ref)         shift; [ $# -gt 0 ] || die "--ref needs a tag or branch"; OPENUF_REF=$1 ;;
		--check)       CHECK=1 ;;
		--no-rollback) ROLLBACK=0 ;;
		--no-restart)  RESTART=0 ;;
		--keep-work)   KEEP_WORK=1 ;;
		-h|--help)     sed -n '2,29p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
		*)             die "unknown option: $1 (see --help)" ;;
	esac
	shift
done
[ -n "$OPENUF_TARBALL_URL" ] || OPENUF_TARBALL_URL="https://codeload.github.com/$OPENUF_REPO/tar.gz/$OPENUF_REF"

# ─── What is installed ──────────────────────────────────────────────────────
status_val() { sed -n "s/^$1=//p" "$STATUS_FILE" 2>/dev/null | head -1; }
installed_build() { cat "$INSTALL_DIR/BUILD" 2>/dev/null || echo "unknown (no BUILD stamp)"; }
installed_modelmap() {
	sed -n 's/^dev = dofile("modelmap\/\(.*\)\.lua")$/\1/p' "$INSTALL_DIR/conf.lua" 2>/dev/null | head -1
}

show_installed() {
	say "== installed"
	if [ ! -f "$INSTALL_DIR/conf.lua" ]; then
		say "  openUF is not installed in $INSTALL_DIR (run setup.sh or install.sh first)"
		return 1
	fi
	say "  build       $(installed_build)"
	say "  modelmap    $(installed_modelmap)"
	if [ -f "$STATE_DIR/state.json" ]; then
		say "  adopted     $(grep -q '"adopted":true' "$STATE_DIR/state.json" && echo yes || echo no)"
		say "  identity    $(sed -n 's/.*"mac":"\([^"]*\)".*/\1/p' "$STATE_DIR/state.json")"
	fi
	if [ -f "$STATUS_FILE" ]; then
		_now=$(date +%s); _ok=$(status_val last_ok); _fail=$(status_val last_fail)
		[ -n "$_ok" ] && [ "$_ok" -gt 0 ] 2>/dev/null \
			&& say "  last inform $((_now - _ok))s ago ($(status_val last_type)), cfgversion $(status_val cfgversion)"
		[ -n "$_fail" ] && [ "$_fail" -gt 0 ] 2>/dev/null \
			&& say "  last fail   $((_now - _fail))s ago: $(status_val last_fail_msg)"
	else
		say "  status      no $STATUS_FILE yet (daemon older than this updater, or not running)"
	fi
	_n=$(ps w 2>/dev/null | grep -E 'lua (inform|announce)\.lua' | grep -vc grep)
	say "  daemons     $_n running"
	return 0
}

if [ "$CHECK" = 1 ]; then
	show_installed
	exit $?
fi

[ "$(id -u 2>/dev/null || echo 0)" = 0 ] || die "must run as root."
[ -f "$INSTALL_DIR/conf.lua" ] || die "openUF is not installed in $INSTALL_DIR -- this updates an existing install; use setup.sh for a first install."
command -v lua >/dev/null 2>&1 || die "lua not found; the installed openUF could not have been running either."

show_installed
BUILD_BEFORE=$(installed_build)

# ─── Source ─────────────────────────────────────────────────────────────────
# fetch <url> <dest>: every client an OpenWrt image might have, same as setup.sh.
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

WORK="/tmp/openuf-update-$$"
cleanup() {
	[ "$KEEP_WORK" = 1 ] || rm -rf "$WORK"
	return 0
}
trap cleanup EXIT

say ""
say "== source"
SRC=""
if [ -n "$FROM" ]; then
	if [ -d "$FROM" ]; then
		SRC=$FROM
		ok "tree at $SRC"
	elif [ -f "$FROM" ]; then
		mkdir -p "$WORK" && ( cd "$WORK" && tar xzf "$FROM" ) || die "could not unpack $FROM"
		ok "unpacked $FROM"
	else
		die "$FROM is neither a directory nor a file"
	fi
else
	mkdir -p "$WORK" || die "cannot create $WORK"
	info "$OPENUF_TARBALL_URL"
	fetch "$OPENUF_TARBALL_URL" "$WORK/src.tar.gz" \
		|| die "download failed. Check the device's internet access and DNS, or fetch the
      tarball elsewhere and re-run with --from /tmp/<file>."
	( cd "$WORK" && tar xzf src.tar.gz ) || die "could not unpack the download"
	ok "downloaded $OPENUF_REPO @ $OPENUF_REF"
fi
if [ -z "$SRC" ]; then
	# A codeload tarball unpacks to <repo>-<ref>/; a release tarball (dist.sh)
	# has install.sh at its top level.
	for _c in "$WORK"/install.sh "$WORK"/*/install.sh; do
		[ -f "$_c" ] || continue
		SRC=$(dirname "$_c")
		break
	done
fi
[ -n "$SRC" ] && [ -f "$SRC/install.sh" ] || die "no install.sh in the source -- not an openUF tree"
[ -d "$SRC/openuf" ] || die "$SRC has no openuf/ directory"

# A source tree (not a dist.sh tarball) carries no build stamp; give it one so
# `openuf-update --check` can say what is running afterwards.
if [ ! -f "$SRC/openuf/BUILD" ]; then
	_stamp="$OPENUF_REF $(date -u +%Y-%m-%dT%H:%MZ)"
	[ -n "$FROM" ] && _stamp="local $(date -u +%Y-%m-%dT%H:%MZ)"
	printf '%s\n' "$_stamp" > "$SRC/openuf/BUILD" 2>/dev/null
fi
BUILD_NEW=$(cat "$SRC/openuf/BUILD" 2>/dev/null || echo unknown)
say "  installed   $BUILD_BEFORE"
say "  new         $BUILD_NEW"

# ─── Preflight ──────────────────────────────────────────────────────────────
say ""
say "== preflight"
FREE_KB=$(df -k "$INSTALL_DIR" 2>/dev/null | awk 'NR==2 {print $4}')
NEED_KB=$(du -sk "$SRC/openuf" 2>/dev/null | awk '{print $1}')
NEED_KB=$(( ${NEED_KB:-300} + 256 ))
if [ -n "$FREE_KB" ] && [ "$FREE_KB" -lt "$NEED_KB" ]; then
	die "only ${FREE_KB} KB free on the overlay, the update needs about ${NEED_KB} KB.
      A full overlay breaks state.json writes and the package database;
      free space first (apk/opkg caches, old backups in /tmp do not count)."
fi
ok "${FREE_KB:-?} KB free on the overlay"

# ─── Backup ─────────────────────────────────────────────────────────────────
BACKUP="/tmp/openuf-backup-$(date +%Y%m%d-%H%M%S).tgz"
tar czf "$BACKUP" -C / opt/openuf etc/openuf 2>/dev/null \
	|| die "could not write the backup $BACKUP; not updating without one"
ok "backup $BACKUP ($(wc -c < "$BACKUP" | tr -d ' ') bytes; /tmp is tmpfs, so it is gone at reboot)"

restore_backup() {
	warn "restoring $BACKUP"
	rm -rf "$INSTALL_DIR"
	tar xzf "$BACKUP" -C / && ok "previous openUF restored" || warn "RESTORE FAILED -- $BACKUP is intact, unpack it by hand: tar xzf $BACKUP -C /"
	/etc/init.d/openuf restart >/dev/null 2>&1
}

# ─── Install ────────────────────────────────────────────────────────────────
say ""
say "== install"
# No --replace-conf: the device's conf.lua is the point. install.sh also
# installs any dependency a newer version added (kmods, packages), using the
# package manager it finds.
if ! ( cd "$SRC" && sh install.sh install ); then
	warn "install.sh failed"
	[ "$ROLLBACK" = 1 ] && restore_backup
	die "update aborted$( [ "$ROLLBACK" = 1 ] && echo '; the previous version is back' )"
fi

# New options this version knows about that the kept conf.lua does not name.
# Absent options take their documented default, so this is information, not
# an error -- but it is how an operator learns a knob exists.
if [ -f "$INSTALL_DIR/conf.lua.dist" ]; then
	_new=$(grep -oE '^[[:space:]]*[a-z_]+[[:space:]]*=' "$INSTALL_DIR/conf.lua.dist" | tr -d ' \t=' | sort -u | tr '\n' ' ')
	_have=$(grep -oE '^[[:space:]]*[a-z_]+[[:space:]]*=' "$INSTALL_DIR/conf.lua" | tr -d ' \t=' | sort -u | tr '\n' ' ')
	_missing=""
	for _k in $_new; do
		case " $_have " in *" $_k "*) ;; *) _missing="$_missing $_k" ;; esac
	done
	if [ -n "$_missing" ]; then
		info "options in conf.lua.dist that your conf.lua does not set (defaults apply):$_missing"
	fi
fi

[ "$RESTART" = 1 ] || { say ""; ok "installed; not restarted (--no-restart). Run: /etc/init.d/openuf restart"; exit 0; }

# ─── Restart and health ─────────────────────────────────────────────────────
say ""
say "== restart"
RESTART_AT=$(date +%s)
/etc/init.d/openuf restart >/dev/null 2>&1 || warn "init script returned non-zero"

# The new daemon writes $STATUS_FILE after every completed inform cycle. Wait
# for a stamp newer than the restart. A transport failure counts as "alive":
# the loop ran, and a controller that is down would fail the old version the
# same way -- so that is reported, not rolled back.
HEALTH="none"
_waited=0
while [ "$_waited" -lt "$HEALTH_DEADLINE" ]; do
	sleep 5; _waited=$((_waited + 5))
	_ok=$(status_val last_ok); _fail=$(status_val last_fail)
	if [ -n "$_ok" ] && [ "$_ok" -ge "$RESTART_AT" ] 2>/dev/null; then HEALTH="ok"; break; fi
	if [ -n "$_fail" ] && [ "$_fail" -ge "$RESTART_AT" ] 2>/dev/null; then HEALTH="unanswered"; fi
	# Both instances gone is a crash loop, whatever the file says.
	_n=$(ps w 2>/dev/null | grep -E 'lua inform\.lua' | grep -vc grep)
	if [ "$_n" = 0 ] && [ "$_waited" -ge 20 ]; then HEALTH="dead"; break; fi
done

say ""
case "$HEALTH" in
	ok)
		ok "the new daemon completed an inform ($(status_val last_type)) $(( $(date +%s) - $(status_val last_ok) ))s ago"
		ok "updated: $BUILD_BEFORE -> $BUILD_NEW"
		say "  conf.lua kept (modelmap $(installed_modelmap)); state.json untouched; no re-adoption needed."
		say "  backup: $BACKUP"
		;;
	unanswered)
		warn "the new daemon is running but the controller has not answered yet:"
		warn "  $(status_val last_fail_msg)"
		warn "Kept the update -- the old version would face the same controller. Watch with:"
		warn "  logread -f -e openuf        openuf-update --check"
		say "  backup: $BACKUP  (tar xzf $BACKUP -C / && /etc/init.d/openuf restart  to go back)"
		;;
	*)
		warn "the new daemon did not complete a cycle within ${HEALTH_DEADLINE}s (state: $HEALTH)"
		logread 2>/dev/null | grep -E 'openuf|inform|announce' | tail -8 | sed 's/^/    /' >&2
		if [ "$ROLLBACK" = 1 ]; then
			restore_backup
			die "update rolled back to $BUILD_BEFORE"
		else
			die "left in place (--no-rollback). Backup: $BACKUP"
		fi
		;;
esac
