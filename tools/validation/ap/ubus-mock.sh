#!/bin/sh
# Fake `ubus` CLI for the disposable validation AP container ONLY.
#
# This is not part of openUF -- it exists purely so
# openuf/ucihelper.lua's get_ifname_for_radio() (which shells out to
# `ubus call network.wireless status` to resolve a UCI radio name like
# "radio0" to its live wireless netdev name like "wlan0") resolves to
# something real inside this hardware-less Alpine container, instead of
# always failing (no real ubus/netifd here) and leaving
# radio_table_stats/sta_table permanently empty -- which is why the real
# controller's AirView showed no "Air Stats" for this device at all.
#
# Only handles the one subcommand ucihelper.lua actually calls. Static
# radio0->wlan0/radio1->wlan1 mapping matches
# openuf/modelmap/generic-dualband-ap.lua's hwassign (radio0=2.4GHz,
# radio1=5GHz) -- real hardware's phy->netdev mapping is likewise static
# per device, independent of which SSIDs are currently configured.
if [ "$1" = "call" ] && [ "$2" = "network.wireless" ] && [ "$3" = "status" ]; then
	cat <<'EOF'
{"radio0":{"up":true,"pending":false,"autostart":true,"disabled":false,"interfaces":[{"ifname":"wlan0"}]},"radio1":{"up":true,"pending":false,"autostart":true,"disabled":false,"interfaces":[{"ifname":"wlan1"}]}}
EOF
	exit 0
fi
exit 1
