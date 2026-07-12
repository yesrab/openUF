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
		# No real client can ever associate to this synthetic AP (no real
		# wireless hardware in this container at all), which means the
		# vap_table traffic/retry counters (openuf/inform.lua) can never be
		# proven against real non-zero data without this: one fake
		# connected station, same purpose as uci-mock.lua's seeded
		# radio0/radio1 -- realistic synthetic data so the full live
		# pipeline (this -> sysinfo.sta_table() -> build_json's per-VAP
		# aggregation -> controller -> "Air Stats" UI) can be verified
		# end-to-end instead of only via unit tests.
		#
		# Counters monotonically increase (persisted in a state file, one
		# per radio) rather than staying static -- a real client's byte/
		# packet counts only ever grow while associated, and the
		# controller's own "Air Stats" widget reads as a rate/delta between
		# informs, so static counters would always show 0 traffic there
		# despite the raw per-inform counter value being genuinely non-zero.
		COUNTER_FILE="/tmp/iw-mock-counter-$2"
		N=$(cat "$COUNTER_FILE" 2>/dev/null || echo 0)
		N=$((N + 1))
		echo "$N" > "$COUNTER_FILE"
		cat <<EOF
Station de:ad:be:ef:00:01 (on $2)
	inactive time:	50 ms
	rx bytes:	$((123456 + N * 4096))
	rx packets:	$((890 + N * 6))
	tx bytes:	$((654321 + N * 8192))
	tx packets:	$((432 + N * 9))
	tx retries:	$((7 + N))
	tx failed:	1
	signal:  	-58 dBm
	signal avg:	-59 dBm
	tx bitrate:	144.4 MBit/s MCS 15 short GI
	rx bitrate:	72.2 MBit/s MCS 7 short GI
	authorized:	yes
	authenticated:	yes
	associated:	yes
EOF
		exit 0
		;;
esac

exec "$REAL_IW" "$@"
