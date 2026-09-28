#!/bin/sh
# Entrypoint for the disposable validation AP container ONLY -- not part of
# openUF.
#
# Seeds /proc/net/arp with static entries for bridge-mock.sh's two fake
# wired hosts, so openuf/sysinfo.lua's mac_table() resolves a real IP for
# each fake MAC exactly like it would from a genuine kernel ARP table --
# `ip neigh` entries are runtime state, not something an image layer can
# bake in, so this must run at container start, not build time.
ip neigh replace 192.168.1.101 lladdr ca:fe:be:ef:00:01 dev eth0 nud permanent 2>/dev/null
ip neigh replace 192.168.1.102 lladdr ca:fe:be:ef:00:02 dev eth0 nud permanent 2>/dev/null

# Stub mac80211 debugfs for openuf/airtime.lua (Airtime Fairness, wifi_caps
# 0x20). docker-compose.yml mounts a tmpfs here; without the files the claim
# stays clear and the controller never sends atf.*. Plain files: a write
# lands, but reads back the number rather than the kernel's flag names, so
# turning fairness on logs "0 of 2 phys read back as requested". That is this
# stub, not openUF.
if mkdir -p /sys/kernel/debug/ieee80211/phy0 /sys/kernel/debug/ieee80211/phy1 2>/dev/null; then
	for p in phy0 phy1; do echo 3 > /sys/kernel/debug/ieee80211/$p/airtime_flags; done
fi

exec "$@"
