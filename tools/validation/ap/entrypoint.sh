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

exec "$@"
