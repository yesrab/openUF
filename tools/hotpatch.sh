#!/bin/sh
# Put this working tree's Lua onto an AP's *running* openUF, whatever prefix
# that is -- the package's /usr/lib/openuf or install.sh's /opt/openuf -- and
# restart the daemon. deploy.sh/update.sh only ever update /opt/openuf, which
# on a device that also has the package installed is the dormant copy (the init
# script prefers /usr/lib/openuf), so a deploy there changes nothing that runs.
#
#   sh tools/hotpatch.sh <host>                        # key or blank-password root
#   OPENUF_SSH_PASS='secret' sh tools/hotpatch.sh <host>
#   sh tools/hotpatch.sh --repush <host>               # also forget cfgversion, so the
#                                                      # controller sends a full config
#                                                      # push right after the restart
#
# Every replaced file is kept beside the new one as <file>.pre-hotpatch (first
# patch only, never overwritten), conf.lua and the modelmap/ufmodel profiles are
# left alone, /etc/init.d/openuf is replaced when the tree's copy differs (its
# backup lives inside the tree), and a BUILD stamp names this checkout. A lab tool: it writes into
# a package-managed tree, so `apk fix openuf` (or a reinstall) is the way back.
set -u
cd "$(dirname "$0")/.." || exit 2
[ -f openuf/inform.lua ] || { echo "run from the repository root" >&2; exit 2; }
REPUSH=0
[ "${1:-}" = "--repush" ] && { REPUSH=1; shift; }
HOST=${1:-}; [ -n "$HOST" ] || { echo "usage: sh tools/hotpatch.sh [--repush] <host>" >&2; exit 2; }

SSH_COMMON="-o ConnectTimeout=8 -o StrictHostKeyChecking=accept-new -o LogLevel=ERROR"
ASKPASS=""
cleanup() { [ -n "$ASKPASS" ] && rm -f "$ASKPASS"; return 0; }
trap cleanup EXIT
if [ -n "${OPENUF_SSH_PASS:-}" ]; then
	ASKPASS=$(mktemp "${TMPDIR:-/tmp}/openuf-askpass.XXXXXX") || exit 1
	cat > "$ASKPASS" <<'HELPER'
printf '%s\n' "$OPENUF_SSH_PASS"
HELPER
	chmod 700 "$ASKPASS"
	export OPENUF_SSH_PASS SSH_ASKPASS="$ASKPASS" SSH_ASKPASS_REQUIRE=force DISPLAY="${DISPLAY:-:0}"
	SSH=${OPENUF_SSH:-"ssh $SSH_COMMON -o NumberOfPasswordPrompts=1"}
else
	SSH=${OPENUF_SSH:-"ssh $SSH_COMMON -o BatchMode=yes"}
fi

DIR=$($SSH "root@$HOST" 'for d in /usr/lib/openuf /opt/openuf; do [ -f "$d/inform.lua" ] && { echo "$d"; break; }; done') || exit 1
[ -n "$DIR" ] || { echo "$HOST: openUF is not installed (no inform.lua under /usr/lib/openuf or /opt/openuf)" >&2; exit 1; }
STAMP="hotpatch $(git describe --tags --always --dirty 2>/dev/null || echo unknown) $(date -u +%Y-%m-%dT%H:%MZ)"
echo "$HOST: running tree is $DIR -- patching with: $STAMP"

# Ship the same comment-stripped tree a release ships (tools/dist.sh), so a
# device deploy.sh already updated sees no difference; conf.lua and the
# profiles stay out. Then install with backups.
sh tools/dist.sh >/dev/null 2>&1 || { echo "tools/dist.sh failed" >&2; exit 1; }
[ -f build/openuf/inform.lua ] || { echo "build/openuf is missing after dist.sh" >&2; exit 1; }
COPYFILE_DISABLE=1 tar -C build/openuf -cf - \
	--exclude=conf.lua --exclude=conf.lua.dist --exclude='modelmap' --exclude='ufmodel' \
	--exclude='.DS_Store' --exclude='._*' --exclude=BUILD . \
| $SSH "root@$HOST" "set -e; D='$DIR'; T=\$(mktemp -d /tmp/openuf-hotpatch.XXXXXX); tar -C \"\$T\" -xf -;
	changed=0
	for f in \$(cd \"\$T\" && find . -type f | sed 's|^\./||'); do
		if [ -f \"\$D/\$f\" ] && cmp -s \"\$T/\$f\" \"\$D/\$f\"; then continue; fi
		[ -f \"\$D/\$f\" ] && [ ! -f \"\$D/\$f.pre-hotpatch\" ] && cp \"\$D/\$f\" \"\$D/\$f.pre-hotpatch\"
		mkdir -p \"\$D/\$(dirname \"\$f\")\"; cp \"\$T/\$f\" \"\$D/\$f\"; changed=\$((changed+1)); echo \"  updated \$f\"
	done
	rm -rf \"\$T\"; echo '$STAMP' > \"\$D/BUILD\"
	echo \"  \$changed file(s) changed\"
	# The init script is installed outside the tree (/etc/init.d/openuf, by
	# install.sh or the package); the copy inside the tree is only a source.
	# Ship it too when it differs, or a hotpatched device keeps an init script
	# older than the daemon it starts (AP1, 2026-10-03: the package's 0.0.3
	# script, without the full-wpad refusal). The backup stays INSIDE the tree:
	# a stray file in /etc/init.d/ would be enumerated as a service.
	if [ -f \"\$D/etc/init.d/openuf\" ] && ! cmp -s \"\$D/etc/init.d/openuf\" /etc/init.d/openuf; then
		[ -f /etc/init.d/openuf ] && [ ! -f \"\$D/etc/init.d/openuf.pre-hotpatch\" ] && cp /etc/init.d/openuf \"\$D/etc/init.d/openuf.pre-hotpatch\"
		cp \"\$D/etc/init.d/openuf\" /etc/init.d/openuf && chmod 755 /etc/init.d/openuf && echo '  updated /etc/init.d/openuf'
	fi
	if [ '$REPUSH' = 1 ] && [ -f /etc/openuf/state.json ]; then
		lua -e 'local c=require\"cjson\"; local f=io.open(\"/etc/openuf/state.json\"); local s=c.decode(f:read(\"*a\")); f:close(); s.cfgversion=\"\"; local o=io.open(\"/etc/openuf/state.json\",\"w\"); o:write(c.encode(s)); o:close()' && echo '  cfgversion forgotten: the controller will push the full config'
	fi
	/etc/init.d/openuf restart
	i=0; while [ \$i -lt 20 ]; do sleep 3; ok=\$(grep -m1 last_ok /tmp/openuf-status 2>/dev/null | cut -d= -f2); [ \"\${ok:-0}\" -gt \$(( \$(date +%s) - 25 )) ] && break; i=\$((i+1)); done
	grep -E 'last_ok|last_type|build' /tmp/openuf-status 2>/dev/null || echo '  (no status yet)'" || { echo "$HOST: hotpatch failed" >&2; exit 1; }
echo "$HOST: done"
