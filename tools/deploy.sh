#!/bin/sh
# Push this working tree to one or more openUF access points and run the
# on-device updater (update.sh) there. The lab's "propagate to every adopted
# AP" command -- what setup.sh is to a first install, this is to every version
# after it.
#
#   sh tools/deploy.sh 192.168.1.149 192.168.1.22       # build, push, update, verify
#   sh tools/deploy.sh --check 192.168.1.149            # reachability and what is installed
#   sh tools/deploy.sh --no-verify <host>...            # skip the test suite in dist.sh
#   OPENUF_SSH_PASS='secret' sh tools/deploy.sh <host>  # APs with a root password
#   OPENUF_SSH='ssh -i ~/.ssh/aps' sh tools/deploy.sh <host>...
#
# Each AP gets the same tarball dist.sh builds for a release (comment-stripped,
# with a BUILD stamp naming this checkout), so what runs in the lab is what a
# release would ship. The updater on the device backs up, installs with the
# device's own conf.lua kept, restarts, waits for a completed inform, and
# rolls back on failure -- see update.sh. Hosts are processed one at a time,
# so a bad build stops at the first AP rather than taking the site down.
#
# Authentication: by default ssh runs in BatchMode (keys, or a blank root
# password -- dropbear lets root in with no password until one is set). For an
# AP with a password, set OPENUF_SSH_PASS: ssh is then pointed at a throwaway
# askpass helper that echoes the variable, so the password is typed once, on
# the command line, and is never written anywhere. The environment variable
# is still visible to `ps` on this machine while the script runs; a key in
# /etc/dropbear/authorized_keys on the AP is the better long-term answer.
#
# Runs from the repository root on the dev machine (POSIX sh; macOS and Linux).

set -u

SSH_COMMON="-o ConnectTimeout=8 -o StrictHostKeyChecking=accept-new -o LogLevel=ERROR"
ASKPASS=""
cleanup() { [ -n "$ASKPASS" ] && rm -f "$ASKPASS"; return 0; }
trap cleanup EXIT

if [ -n "${OPENUF_SSH_PASS:-}" ]; then
	# SSH_ASKPASS_REQUIRE=force (OpenSSH >= 8.4) makes ssh ask the helper even
	# with a tty present; the helper reads the password from the environment.
	ASKPASS=$(mktemp "${TMPDIR:-/tmp}/openuf-askpass.XXXXXX") || exit 1
	cat > "$ASKPASS" <<'HELPER'
#!/bin/sh
printf '%s\n' "$OPENUF_SSH_PASS"
HELPER
	chmod 700 "$ASKPASS"
	export OPENUF_SSH_PASS SSH_ASKPASS="$ASKPASS" SSH_ASKPASS_REQUIRE=force DISPLAY="${DISPLAY:-:0}"
	SSH=${OPENUF_SSH:-"ssh $SSH_COMMON -o NumberOfPasswordPrompts=1"}
else
	SSH=${OPENUF_SSH:-"ssh $SSH_COMMON -o BatchMode=yes"}
fi

CHECK=0
VERIFY=1
HOSTS=""
while [ $# -gt 0 ]; do
	case "$1" in
		--check)     CHECK=1 ;;
		--no-verify) VERIFY=0 ;;
		-h|--help)   sed -n '2,28p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
		-*)          echo "unknown option: $1" >&2; exit 2 ;;
		*)           HOSTS="$HOSTS $1" ;;
	esac
	shift
done
[ -n "$HOSTS" ] || { echo "usage: sh tools/deploy.sh [--check] [--no-verify] <host> [host...]" >&2; exit 2; }
[ -f tools/dist.sh ] && [ -f update.sh ] || { echo "run from the repository root" >&2; exit 2; }

remote() { # remote <host> <command...>
	_h=$1; shift
	# shellcheck disable=SC2086
	$SSH "root@$_h" "$@"
}

if [ "$CHECK" = 1 ]; then
	rc=0
	for h in $HOSTS; do
		echo "=== $h"
		if remote "$h" 'test -x /usr/bin/openuf-update' 2>/dev/null; then
			remote "$h" 'openuf-update --check' || rc=1
		else
			# An AP installed before the updater existed: read what we can.
			remote "$h" 'echo "  (no openuf-update on this AP yet)"; echo "  build       $(cat /opt/openuf/BUILD 2>/dev/null || echo unknown)"; echo "  modelmap    $(sed -n "s/^dev = dofile(\"modelmap\/\(.*\)\.lua\")$/\1/p" /opt/openuf/conf.lua 2>/dev/null)"; echo "  adopted     $(grep -q "\"adopted\":true" /etc/openuf/state.json 2>/dev/null && echo yes || echo no)"; echo "  daemons     $(ps w | grep -E "lua (inform|announce)\.lua" | grep -vc grep) running"' \
				|| { echo "  unreachable"; rc=1; }
		fi
	done
	exit $rc
fi

echo "=== build"
# Never ship a tarball from an earlier run: a failed build must leave nothing
# to deploy.
rm -f openuf.tar.gz
# dist.sh --verify runs the suite, which needs lua-cjson. On a dev machine
# that comes from luarocks and is not on a bare shell's LUA_PATH.
if command -v luarocks >/dev/null 2>&1; then
	eval "$(luarocks path --local 2>/dev/null)"
fi
DIST_LOG=$(mktemp "${TMPDIR:-/tmp}/openuf-dist.XXXXXX") || exit 1
if [ "$VERIFY" = 1 ]; then DIST_ARGS="--verify"; else DIST_ARGS=""; fi
# shellcheck disable=SC2086
if ! sh tools/dist.sh $DIST_ARGS > "$DIST_LOG" 2>&1 || [ ! -f openuf.tar.gz ]; then
	tail -12 "$DIST_LOG"
	rm -f "$DIST_LOG"
	echo "dist.sh failed; nothing deployed" >&2
	exit 1
fi
tail -2 "$DIST_LOG"
rm -f "$DIST_LOG"

failed=""
for h in $HOSTS; do
	echo ""
	echo "=== $h"
	if ! remote "$h" 'cat > /tmp/openuf-update.tgz' < openuf.tar.gz; then
		echo "  could not copy the tarball (ssh failed)"; failed="$failed $h"; continue
	fi
	# The updater ships inside the tarball; unpack it and hand it the tree.
	if remote "$h" 'rm -rf /tmp/openuf-upd && mkdir -p /tmp/openuf-upd && cd /tmp/openuf-upd && tar xzf /tmp/openuf-update.tgz && sh /tmp/openuf-upd/update.sh --from /tmp/openuf-upd'; then
		echo "  $h: updated"
	else
		echo "  $h: FAILED (the updater rolls back on its own; see its output above)"
		failed="$failed $h"
		echo "  stopping here -- the remaining hosts were not touched"
		break
	fi
done

echo ""
if [ -n "$failed" ]; then
	echo "failed:$failed"
	exit 1
fi
echo "all hosts updated"
