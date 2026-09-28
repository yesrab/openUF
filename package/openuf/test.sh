#!/bin/sh
# openwrt/packages CI runtime check: $1 is the package name, $2 the version.
# `openuf --version` prints the version the package was built from; grep
# without -q so the value is visible in the build log.
case "$1" in
openuf)
	openuf --version | grep "${2%-*}"
	;;
esac
