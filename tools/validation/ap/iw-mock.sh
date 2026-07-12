#!/bin/sh
# Fake `iw` wrapper for the disposable validation AP container ONLY.
#
# This is not part of openUF -- the real `iw` binary is still installed
# (see the Dockerfile) and this script falls through to it for anything
# it doesn't specifically handle. It only intercepts `survey dump` and
# `station dump` against the synthetic wlan0/wlan1 netdevs ubus-mock.sh
# invents (this container has no real wireless hardware for the real
# `iw` to introspect, so those commands would otherwise always fail).
# Field names deliberately match the real iw(8) binary's own format
# strings (confirmed via `strings /usr/sbin/iw`) -- see the accompanying
# openuf/sysinfo.lua fix, which found the *parser* previously expected
# names iw never actually prints.
REAL_IW=/usr/sbin/iw

case "$2 $3" in
	"wlan0 survey" | "wlan1 survey")
		cat <<EOF
Survey data from $2 (on operating channel):
	frequency:			$([ "$2" = "wlan0" ] && echo 2437 || echo 5180) MHz [in use]
	noise:				-91 dBm
	channel active time:		56000 ms
	channel busy time:		4200 ms
	extension channel busy time:	300 ms
	channel receive time:		2100 ms
	channel transmit time:		600 ms
EOF
		exit 0
		;;
	"wlan0 station" | "wlan1 station")
		# No real clients ever associate to this synthetic AP -- empty
		# output is the correct, real `iw station dump` shape for a radio
		# with zero connected stations.
		exit 0
		;;
esac

exec "$REAL_IW" "$@"
