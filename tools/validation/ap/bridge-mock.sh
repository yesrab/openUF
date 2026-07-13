#!/bin/sh
# Fake `bridge` wrapper for the disposable validation AP container ONLY.
#
# This is not part of openUF -- the real `bridge` binary (iproute2) is still
# installed (see the Dockerfile) and this script falls through to it for
# anything it doesn't specifically handle. It only intercepts
# `fdb show dev eth0` -- this container has no real bridge/switch hardware
# (single-NIC, no br-lan) for the real `bridge` to introspect, so that
# command would otherwise always return nothing.
#
# Two fake wired hosts on the single downstream port (eth0, after the
# Dockerfile's lan_cpueth/ports override to this container's only NIC),
# same purpose as iw-mock.sh's fake wireless stations: realistic synthetic
# data so the full live pipeline (this -> sysinfo.mac_table() ->
# build_json's port_table -> controller -> client list / Ports view) can be
# verified end-to-end instead of only via unit tests. One host has no
# corresponding /tmp/dhcp.leases entry (see Dockerfile), to prove hostname
# stays correctly optional rather than being invented.
#
# Unlike iw-mock.sh's station counters, no monotonically-increasing state
# is needed here: openuf/sysinfo.lua's mac_table() derives `age`/`uptime`
# itself (age=0, uptime from a first-seen cache) rather than parsing them
# out of `bridge fdb show` output, so static fdb content is sufficient.
#
# Self/permanent/multicast lines are included deliberately, not just the
# two real hosts -- they exercise sysinfo.mac_table()'s exclusion filters
# against genuine `bridge fdb show` output shape, not just the unit tests'
# fixture text.
REAL_BRIDGE=/sbin/bridge

case "$1 $2 $3 $4" in
	"fdb show dev eth0")
		cat <<EOF
33:33:00:00:00:01 dev eth0 self permanent
01:00:5e:00:00:01 dev eth0 self permanent
ca:fe:be:ef:00:01 dev eth0 master br-lan
ca:fe:be:ef:00:02 dev eth0 master br-lan
EOF
		exit 0
		;;
esac

exec "$REAL_BRIDGE" "$@"
