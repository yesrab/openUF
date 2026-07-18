#!/bin/sh
# Fake `ubus` CLI for the disposable validation AP container ONLY.
#
# This is not part of openUF -- it exists purely so openuf/ucihelper.lua's
# get_ifname_for_radio()/get_ifname_for_vap() (which shell out to `ubus call
# network.wireless status` to resolve a UCI radio name like "radio0" to its
# live wireless netdev name like "wlan0") resolve to something real inside this
# hardware-less Alpine container, instead of always failing (no real
# ubus/netifd here) and leaving radio_table_stats/sta_table permanently empty --
# which is why the real controller's AirView showed no "Air Stats" for this
# device at all.
#
# Only handles the one subcommand ucihelper.lua actually calls.
#
# The radio->netdev base mapping is static (radio0=wlan0, radio1=wlan1),
# matching openuf/modelmap/generic-dualband-ap.lua's hwassign -- real hardware's
# phy->netdev mapping is likewise static per device. But the *interfaces* list
# is built from whatever VAPs are currently provisioned, with the per-interface
# "config": {"ssid": ...} that real netifd reports, because per-WLAN features
# (the Multicast and Broadcast Blocker) resolve a specific VAP's netdev by SSID.
# An earlier version of this mock hardcoded exactly one bare {"ifname": ...} per
# radio with no config at all, so that lookup could never match and the
# multi-SSID-per-radio case -- the normal case here, two WLANs on both bands --
# went untested.
#
# Secondary VAPs follow OpenWrt's naming (wlan0, wlan0-1, wlan0-2, ...).
if [ "$1" = "call" ] && [ "$2" = "network.wireless" ] && [ "$3" = "status" ]; then
	lua - <<'EOF'
local cjson_ok, cjson = pcall(require, "cjson")
local db = {}
if cjson_ok then
	local f = io.open("/var/log/openuf-uci-mock-wireless.json", "r")
	if f then
		local raw = f:read("*a")
		f:close()
		local ok, parsed = pcall(cjson.decode, raw)
		if ok and type(parsed) == "table" then db = parsed end
	end
end

-- Collect provisioned VAPs per radio, in a stable order.
local by_radio = {}
local names = {}
for name in pairs(db) do names[#names + 1] = name end
table.sort(names)
for _, name in ipairs(names) do
	local s = db[name]
	if type(s) == "table" and s[".type"] == "wifi-iface" and s.device and s.ssid then
		by_radio[s.device] = by_radio[s.device] or {}
		local list = by_radio[s.device]
		list[#list + 1] = s.ssid
	end
end

local out = {}
for _, radio in ipairs({"radio0", "radio1"}) do
	local base = radio == "radio0" and "wlan0" or "wlan1"
	local ifaces = {}
	for i, ssid in ipairs(by_radio[radio] or {}) do
		local ifname = (i == 1) and base or (base .. "-" .. (i - 1))
		ifaces[#ifaces + 1] = string.format(
			'{"ifname":"%s","config":{"ssid":%s}}', ifname,
			cjson_ok and cjson.encode(ssid) or ('"' .. ssid .. '"'))
	end
	-- Keep the radio present with its base netdev even before anything is
	-- provisioned, so get_ifname_for_radio() still resolves for stats.
	if #ifaces == 0 then
		ifaces[1] = string.format('{"ifname":"%s"}', base)
	end
	out[#out + 1] = string.format(
		'"%s":{"up":true,"pending":false,"autostart":true,"disabled":false,"interfaces":[%s]}',
		radio, table.concat(ifaces, ","))
end
io.write("{" .. table.concat(out, ",") .. "}\n")
EOF
	exit 0
fi
exit 1
