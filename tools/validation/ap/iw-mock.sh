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
		# proven against real non-zero data without this: fake connected
		# stations, same purpose as uci-mock.lua's seeded radio0/radio1 --
		# realistic synthetic data so the full live pipeline (this ->
		# sysinfo.sta_table() -> build_json's per-VAP aggregation ->
		# controller -> "Air Stats" UI) can be verified end-to-end instead
		# of only via unit tests.
		#
		# Multiple stations per radio (two on wlan0, one on wlan1) so
		# multi-client behavior is covered too, not just a single station --
		# per-MAC caches (e.g. inform.lua's M._sta_stats_cache throughput
		# delta cache) and per-VAP aggregation (summing every station's
		# counters) can't be proven correct against just one client. One of
		# the wlan0 stations also uses a legacy (pre-11n) bitrate string
		# with no "MCS" suffix, to confirm tx_mcs/rx_mcs correctly stay nil
		# for that client while still populated for its neighbor in the
		# same dump.
		#
		# Counters monotonically increase (persisted in a state file, one
		# per station) rather than staying static -- a real client's byte/
		# packet counts only ever grow while associated, and the
		# controller's own "Air Stats" widget reads as a rate/delta between
		# informs, so static counters would always show 0 traffic there
		# despite the raw per-inform counter value being genuinely non-zero.
		# Keyed by ifname+mac (not just ifname) so each station's counters
		# grow independently instead of all stations on a radio reporting
		# identical values.
		emit_station() {
			ifname="$1" mac="$2" signal="$3" sig_avg="$4"
			rx_base="$5" tx_base="$6" rx_pkt_base="$7" tx_pkt_base="$8"
			retry_base="$9" tx_rate="${10}" rx_rate="${11}" conn_base="${12}"
			rx_step="${13}" tx_step="${14}"

			counter_file="/tmp/iw-mock-counter-${ifname}-$(echo "$mac" | tr -d ':')"
			n=$(cat "$counter_file" 2>/dev/null || echo 0)
			n=$((n + 1))
			echo "$n" > "$counter_file"

			cat <<EOF
Station $mac (on $ifname)
	connected time:	$((conn_base + n * 10)) sec
	inactive time:	50 ms
	rx bytes:	$((rx_base + n * rx_step))
	rx packets:	$((rx_pkt_base + n * 6))
	tx bytes:	$((tx_base + n * tx_step))
	tx packets:	$((tx_pkt_base + n * 9))
	tx retries:	$((retry_base + n))
	tx failed:	1
	signal:  	$signal dBm
	signal avg:	$sig_avg dBm
	tx bitrate:	$tx_rate
	rx bitrate:	$rx_rate
	authorized:	yes
	authenticated:	yes
	associated:	yes
EOF
		}

		# rx_step/tx_step (bytes added per poll) deliberately differ per
		# station -- besides the base offsets, this also makes each
		# station's *throughput* (inform.lua's delta-sampled rate, not the
		# cumulative counter) visibly distinct in the controller UI, not
		# just its cumulative byte count. Using the same step for every
		# station would still prove per-MAC counters don't collide, but
		# throughput would coincidentally come out identical across
		# stations, which is misleading to eyeball-verify against.
		if [ "$2" = "wlan0" ]; then
			emit_station wlan0 de:ad:be:ef:00:01 -58 -59 \
				123456 654321 890 432 7 \
				"144.4 MBit/s MCS 15 short GI" "72.2 MBit/s MCS 7 short GI" 100 \
				262144 524288
			emit_station wlan0 de:ad:be:ef:00:02 -70 -71 \
				55000 210000 340 150 3 \
				"54.0 MBit/s" "54.0 MBit/s" 40 \
				16384 32768
		else
			emit_station wlan1 de:ad:be:ef:00:03 -50 -51 \
				980000 2100000 5200 3100 12 \
				"866.7 MBit/s MCS 9 short GI" "780.0 MBit/s MCS 8 short GI" 300 \
				786432 1572864
		fi
		exit 0
		;;
esac

exec "$REAL_IW" "$@"
