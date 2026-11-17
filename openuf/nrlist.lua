--[[
	802.11k neighbour reports that name the site's other access points.

	With a WLAN's 802.11k on, `ucihelper` writes ieee80211k / rrm_neighbor_report
	and hostapd answers a client's Neighbor Report Request -- with a list that
	holds this BSS and nothing else, because nothing fills it. usteer fills it
	where openUF runs usteer (Band Steering or Roaming Assistant), and then
	only with the OpenWrt APs that run usteer themselves: a genuine UniFi AP
	never appears, since it does not speak usteer's sync.

	A UniFi AP lists its siblings there, so a client asking "where else can I
	go" gets the other APs' channels before its link is bad enough to scan for
	them. This module does the same from what openUF already knows:

	  - sibling BSSes: every scanned BSS that beacons the site's own vendor
	    IE (sysinfo.scan_table's `peer_mac` -- the openUF IE, or a UniFi AP's
	    own) and carries the same SSID. Remembered for REMEMBER seconds: the
	    passive scan cache only holds the radio's own channel between sweeps,
	    and a neighbour two channels away is seen a few times a night;
	  - this AP's own BSS of the same SSID on its other radio(s).

	and hands hostapd the list with `ubus call hostapd.<if> rrm_nr_set`, its
	own entry (rrm_nr_get_own) first. hostapd forgets the list whenever the BSS
	restarts, so it is set again after every `wifi reload` and on a slow
	timer.

	Where usteer runs, this module does nothing: usteer writes the same list
	on its own schedule and the two would overwrite each other for ever. That
	means a site with Band Steering or Roaming Assistant on keeps usteer's
	list (OpenWrt siblings only). Stated, not papered over.

	A BSS whose 802.11k is off has no own entry (hostapd creates it only with
	rrm_neighbor_report), and that is the gate: no own entry, no list.

	The element is the one antoniocosta/unifi-openwrt builds (GPL-2.0-or-later,
	internal/openwrt/rrm.go, read 2026-11-17; run by them on an OnHub beside
	UniFi APs): BSSID, BSSID information 0x08af (+0x1000 VHT on 5 GHz), the
	20 MHz global operating class, channel, PHY type 7 / 9. Finding the
	siblings by their beacon IE instead of by matching BSSID bytes to LAN
	hosts is this tree's. ⚠️ Run on the hwsim test VM only: no genuine UniFi
	AP is on this site, and no client's Neighbor Report has been captured.
]]--

local M = {}
local util = package.loaded["openuf.util"]
	or assert(loadfile("util.lua") or loadfile("openuf/util.lua"))()

M._popen = util.popen
M._exec  = os.execute
M._decode = function(s)
	local ok, cjson = pcall(require, "cjson")
	if not ok then return nil end
	local ok2, t = pcall(cjson.decode, s)
	return ok2 and type(t) == "table" and t or nil
end
M._encode = function(t) return require("cjson").encode(t) end

-- How long a sibling stays in the list after it was last scanned.
M.REMEMBER = 3600
-- bssid -> {ssid, freq, channel, at}
M._seen = {}

-- ─── What is known ───────────────────────────────────────────────────────────

-- One scan_table entry. Only a sibling (peer_mac set) with an SSID, a BSSID
-- and a channel is remembered.
function M.observe(net, now)
	if type(net) ~= "table" or not net.peer_mac then return false end
	local bssid = type(net.bssid) == "string" and net.bssid:lower() or nil
	if not (util.is_mac(bssid) and type(net.essid) == "string" and net.essid ~= ""
	   and tonumber(net.channel) and tonumber(net.freq)) then
		return false
	end
	M._seen[bssid] = {ssid = net.essid, freq = tonumber(net.freq),
		channel = tonumber(net.channel), at = now}
	return true
end

function M.expire(now)
	for bssid, e in pairs(M._seen) do
		if now - (e.at or 0) > M.REMEMBER then M._seen[bssid] = nil end
	end
end

-- ─── The element ─────────────────────────────────────────────────────────────

-- The global operating class of a 20 MHz channel (IEEE 802.11 Annex E, table
-- E-4). nil for anything else -- 6 GHz included: its classes depend on the
-- width, which a scan entry does not reliably carry, and a wrong class sends
-- a client to scan a channel that is not there.
function M.op_class(freq, ch)
	if freq < 3000 then
		if ch >= 1 and ch <= 13 then return 81 end
		return nil
	end
	if freq > 5900 then return nil end
	if ch >= 36 and ch <= 48 then return 115 end
	if ch >= 52 and ch <= 64 then return 118 end
	if ch >= 100 and ch <= 144 then return 121 end
	if ch >= 149 and ch <= 177 then return 125 end
	return nil
end

-- A channel's centre frequency, for this AP's own BSSes (UCI knows the
-- channel and the band, not the frequency).
function M.freq_of(band, ch)
	ch = tonumber(ch)
	if not ch then return nil end
	if band == "ng" then
		if ch >= 1 and ch <= 13 then return 2407 + 5 * ch end
		return nil
	elseif band == "na" then
		return 5000 + 5 * ch
	end
	return nil
end

-- The body of a Neighbor Report element as the hex hostapd takes, nil when
-- the BSS cannot be described (no operating class for its channel).
function M.element(bssid, freq, channel)
	if not util.is_mac(bssid) then return nil end
	freq, channel = tonumber(freq), tonumber(channel)
	if not (freq and channel and channel > 0 and channel <= 255) then return nil end
	local oc = M.op_class(freq, channel)
	if not oc then return nil end
	-- reachable (3), security (4), key scope (8), QoS (0x20), RRM (0x80), HT (0x800)
	local info, phy = 0x08af, 7
	if freq > 5000 then info, phy = info + 0x1000, 9 end
	-- BSSID, then the 32-bit information field least significant byte first.
	return ("%s%02x%02x0000%02x%02x%02x"):format(bssid:lower():gsub(":", ""),
		info % 256, math.floor(info / 256), oc, channel, phy)
end

-- The neighbours of one BSS: remembered siblings on `ssid`, plus `own_other`
-- (this AP's other-radio BSSes of the same SSID: {bssid, freq, channel}),
-- minus anything in `own` (a set of this AP's BSSIDs: a sibling entry that is
-- really us, seen by our other radio). Sorted by BSSID, so an unchanged
-- neighbourhood produces an identical list. Each is {bssid, ssid, element}.
function M.neighbours_for(ssid, own, own_other, now)
	local by_bssid = {}
	for bssid, e in pairs(M._seen) do
		if e.ssid == ssid and not (own and own[bssid]) and now - (e.at or 0) <= M.REMEMBER then
			local el = M.element(bssid, e.freq, e.channel)
			if el then by_bssid[bssid] = {bssid, ssid, el} end
		end
	end
	for _, o in ipairs(own_other or {}) do
		local bssid = type(o.bssid) == "string" and o.bssid:lower() or nil
		local el = bssid and M.element(bssid, o.freq, o.channel)
		if el then by_bssid[bssid] = {bssid, ssid, el} end
	end
	local out = {}
	for _, e in pairs(by_bssid) do out[#out + 1] = e end
	table.sort(out, function(a, b) return a[1] < b[1] end)
	return out
end

-- ─── hostapd ─────────────────────────────────────────────────────────────────

local function same_lists(a, b)
	if #a ~= #b then return false end
	local key = function(l)
		local k = {}
		for i, e in ipairs(l) do
			k[i] = (tostring(e[1]) .. "|" .. tostring(e[2]) .. "|" .. tostring(e[3])):lower()
		end
		table.sort(k)
		return k
	end
	local ka, kb = key(a), key(b)
	for i = 1, #ka do if ka[i] ~= kb[i] then return false end end
	return true
end

-- Make hostapd's neighbour list for `ifname` its own entry plus `nbrs`.
-- Returns
--   true   written
--   false  already so
--   nil, why   could not (no own entry: 802.11k off, or the BSS not up yet)
function M.sync(ifname, nbrs)
	if not util.valid_ifname(ifname) then return nil, "bad interface name" end
	local own = M._decode(M._popen("ubus call hostapd." .. ifname .. " rrm_nr_get_own 2>/dev/null") or "")
	local value = own and own.value
	if not (type(value) == "table" and #value == 3 and type(value[1]) == "string") then
		return nil, "no own neighbour entry"
	end
	local cur = M._decode(M._popen("ubus call hostapd." .. ifname .. " rrm_nr_list 2>/dev/null") or "")
	local others = {}
	for _, e in ipairs(cur and type(cur.list) == "table" and cur.list or {}) do
		-- rrm_nr_list leaves the own entry out; compared anyway, in case a
		-- build does not.
		if type(e) == "table" and tostring(e[1]):lower() ~= value[1]:lower() then
			others[#others + 1] = e
		end
	end
	if same_lists(others, nbrs) then return false end
	local list = {value}
	for _, n in ipairs(nbrs) do list[#list + 1] = n end
	-- Every string in the list is a BSSID, hex, or an SSID. The SSID is the
	-- one free-form field, and it goes through a single-quoted shell word:
	-- one that carries a quote cannot be passed safely this way, and is
	-- refused rather than escaped by hand.
	local json = M._encode({list = list})
	if json:find("'", 1, true) then return nil, "an SSID with a quote in it" end
	local st = M._exec("ubus call hostapd." .. ifname .. " rrm_nr_set '" .. json .. "' >/dev/null 2>&1")
	if not util.exec_ok(st) then return nil, "rrm_nr_set failed" end
	return true
end

return M
