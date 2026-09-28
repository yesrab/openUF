#!/bin/sh
# openuf -- the command-line front door to an installed openUF.
#
#   openuf --version            the installed version (and build stamp)
#   openuf status               the daemon's health file and adoption state
#   openuf set-inform <url>     point the device at a controller
#   openuf reset-inform         forget the controller and start over
#   openuf 11k-scan             ask the daemon to sweep every radio next heartbeat
#   openuf start|stop|restart   the procd service
#   openuf probe status|presets|discover|export
#                               JSON for the web UI (hook/probe.lua)
#
# The set-*/reset-*/11k-scan verbs are syswrapper.sh's, the hook the
# controller itself drives over SSH; this wrapper only saves typing its name.
# --version prints the version the package was built from (VERSION, written by
# the package Makefile) and the git stamp (BUILD, written by tools/dist.sh):
# the OpenWrt feed's CI runs every executable with --version and expects the
# package version in the output.
DIR=""
for d in /usr/lib/openuf /opt/openuf; do
	if [ -f "$d/inform.lua" ]; then DIR=$d; break; fi
done

usage() {
	sed -n '2,11p' "$0" | sed 's/^# \{0,1\}//'
}

case "$1" in
	--version|-v|version)
		# VERSION is the package's; a tarball install has only the git stamp.
		v=$(cat "$DIR/VERSION" 2>/dev/null)
		b=$(cat "$DIR/BUILD" 2>/dev/null)
		if [ -n "$v" ]; then echo "openuf $v${b:+ ($b)}"; else echo "openuf ${b:-unknown}"; fi
		;;
	status)
		[ -n "$DIR" ] || { echo "openuf: not installed" >&2; exit 1; }
		echo "install   $DIR"
		if [ -f /tmp/openuf-status ]; then
			# The health file _tick rewrites after every cycle: flat key=value.
			sed 's/^/  /' /tmp/openuf-status
		else
			echo "  (no /tmp/openuf-status yet: the inform daemon has not completed a cycle)"
		fi
		sf=/etc/openuf/state.json
		if [ -f "$sf" ]; then
			if grep -q '"adopted":true' "$sf"; then echo "adopted   yes"; else echo "adopted   no"; fi
		fi
		if /etc/init.d/openuf running 2>/dev/null; then echo "service   running"; else echo "service   stopped"; fi
		;;
	set-inform|set-adopt|reset-inform|11k-scan)
		[ -n "$DIR" ] || { echo "openuf: not installed" >&2; exit 1; }
		exec "$DIR/hook/syswrapper.sh" "$@"
		;;
	probe)
		# JSON for the web UI: `openuf probe status` / `openuf probe presets`
		# (hook/probe.lua, which loads the configuration the daemons' way, so
		# it has to run from the install directory).
		[ -n "$DIR" ] || { echo "openuf: not installed" >&2; exit 1; }
		cd "$DIR" && exec lua hook/probe.lua "$2"
		;;
	start|stop|restart|reload|enable|disable|running)
		exec /etc/init.d/openuf "$1"
		;;
	""|-h|--help|help)
		usage
		;;
	*)
		echo "openuf: unknown command: $1" >&2
		usage >&2
		exit 2
		;;
esac
