-- Tests for openuf/nrlist.lua (the 802.11k neighbour list) and its wiring in
-- inform.lua.
-- Run from project root: lua tests/run_tests.lua

OPENUF_TEST_MODE = true
local nrlist = dofile("openuf/nrlist.lua")
local inform = dofile("openuf/inform.lua")
local cjson  = require("cjson")

-- hostapd over ubus, in a table: per interface its own entry (nil = 802.11k
-- off, or the BSS not up) and the list it holds beside it.
local function fresh(bss)
	local rec = {bss = bss or {}, sets = {}}
	nrlist._seen = {}
	nrlist._popen = function(cmd)
		local ifname, verb = cmd:match("ubus call hostapd%.(%S+) (rrm_nr_%S+)")
		local b = ifname and rec.bss[ifname]
		if not b then return "" end
		if verb == "rrm_nr_get_own" then return b.own and cjson.encode({value = b.own}) or "{}" end
		if verb == "rrm_nr_list" then return cjson.encode({list = b.list or {}}) end
		return ""
	end
	nrlist._exec = function(cmd)
		local ifname, json = cmd:match("ubus call hostapd%.(%S+) rrm_nr_set '(.-)' >")
		if not ifname then return 1 end
		if rec.fail then return 1 end
		local list = cjson.decode(json).list
		rec.sets[#rec.sets + 1] = {ifname = ifname, list = list}
		local others = {}
		for i = 2, #list do others[#others + 1] = list[i] end
		rec.bss[ifname].list = others
		return 0
	end
	return rec
end

local function with_stderr(fn)
	local buf, real = {}, io.stderr
	io.stderr = {write = function(_, ...) for _, s in ipairs({...}) do buf[#buf + 1] = s end end}
	local ok, err = pcall(fn)
	io.stderr = real
	if not ok then error(err, 0) end
	return table.concat(buf)
end

local OWN_2G = {"00:00:5e:00:53:01", "corp", "00005e005301af0800005106070603000000"}

return {
	-- ── the element ───────────────────────────────────────────────────────
	{
		name = "nrlist: the operating class is the 20 MHz one for the channel, and nothing for a channel that has none",
		fn = function()
			assert_eq(nrlist.op_class(2437, 6), 81, "2.4 GHz")
			assert_eq(nrlist.op_class(5180, 36), 115, "36-48")
			assert_eq(nrlist.op_class(5300, 60), 118, "52-64")
			assert_eq(nrlist.op_class(5500, 100), 121, "100-144")
			assert_eq(nrlist.op_class(5745, 149), 125, "149-177")
			assert_nil(nrlist.op_class(2484, 14), "channel 14")
			assert_nil(nrlist.op_class(5955, 1), "6 GHz: the class depends on a width the scan does not give")
			assert_nil(nrlist.op_class(5250, 50), "a 5 GHz number that is not a 20 MHz channel")
		end
	},
	{
		name = "nrlist: a neighbour element is BSSID, information, class, channel, PHY type",
		fn = function()
			assert_eq(nrlist.element("00:00:5E:00:53:10", 2437, 6), "00005e005310" .. "af080000" .. "51" .. "06" .. "07",
				"2.4 GHz: information 0x08af, class 81, HT")
			assert_eq(nrlist.element("00:00:5e:00:53:11", 5180, 36), "00005e005311" .. "af180000" .. "73" .. "24" .. "09",
				"5 GHz: the VHT bit, class 115, VHT")
			assert_nil(nrlist.element("00:00:5e:00:53:11", 5955, 1), "no class, no element")
			assert_nil(nrlist.element("not-a-mac", 2437, 6), "no BSSID, no element")
		end
	},
	{
		name = "nrlist: this AP's own channel becomes a frequency only when it is a number on a known band",
		fn = function()
			assert_eq(nrlist.freq_of("ng", 6), 2437, "2.4 GHz")
			assert_eq(nrlist.freq_of("na", "36"), 5180, "5 GHz, as UCI's string")
			assert_nil(nrlist.freq_of("na", "auto"), "auto before ACS settles: not guessed")
			assert_nil(nrlist.freq_of("6e", 1), "6 GHz")
		end
	},
	-- ── what is known ─────────────────────────────────────────────────────
	{
		name = "nrlist: only a sibling BSS is remembered, and only for an hour",
		fn = function()
			fresh()
			assert_true(nrlist.observe({bssid = "00:00:5E:00:53:20", essid = "corp", channel = 36, freq = 5180,
				peer_mac = "00:00:5e:00:53:02"}, 1000), "a sibling")
			assert_false(nrlist.observe({bssid = "00:00:5e:00:53:30", essid = "corp", channel = 1, freq = 2412}, 1000),
				"a stranger carrying the site's SSID is not a neighbour to send clients to")
			assert_false(nrlist.observe({bssid = "00:00:5e:00:53:31", essid = "", channel = 1, freq = 2412,
				peer_mac = "00:00:5e:00:53:02"}, 1000), "a hidden SSID cannot be matched to a WLAN")
			local n = nrlist.neighbours_for("corp", {}, {}, 1000 + nrlist.REMEMBER)
			assert_eq(#n, 1, "still listed at the hour")
			assert_eq(n[1][1], "00:00:5e:00:53:20", "lower-cased")
			assert_eq(#nrlist.neighbours_for("corp", {}, {}, 1001 + nrlist.REMEMBER), 0, "not after it")
			nrlist.expire(1001 + nrlist.REMEMBER)
			assert_nil(nrlist._seen["00:00:5e:00:53:20"], "and forgotten")
		end
	},
	{
		name = "nrlist: a BSS's neighbours are the siblings on ITS ssid plus this AP's other band, sorted, never itself",
		fn = function()
			fresh()
			local function sib(bssid, ssid, ch, freq)
				nrlist.observe({bssid = bssid, essid = ssid, channel = ch, freq = freq, peer_mac = "00:00:5e:00:53:02"}, 10)
			end
			sib("00:00:5e:00:53:22", "corp", 36, 5180)
			sib("00:00:5e:00:53:21", "corp", 11, 2462)
			sib("00:00:5e:00:53:23", "guest", 11, 2462)
			sib("00:00:5e:00:53:01", "corp", 6, 2437)      -- this AP's own BSS, seen by its other radio
			local own = {["00:00:5e:00:53:01"] = true, ["00:00:5e:00:53:05"] = true}
			local n = nrlist.neighbours_for("corp", own,
				{{bssid = "00:00:5E:00:53:05", freq = 5745, channel = 149}}, 20)
			assert_eq(#n, 3, "two siblings and the other band")
			assert_eq(n[1][1], "00:00:5e:00:53:05", "sorted by BSSID")
			assert_eq(n[2][1], "00:00:5e:00:53:21", "sorted by BSSID")
			assert_eq(n[3][1], "00:00:5e:00:53:22", "sorted by BSSID")
			assert_eq(n[1][2], "corp", "with the SSID")
			assert_eq(n[1][3], "00005e005305" .. "af180000" .. "7d" .. "95" .. "09", "and the element")
		end
	},
	-- ── hostapd ───────────────────────────────────────────────────────────
	{
		name = "nrlist: sync writes the own entry first, then the neighbours, and nothing when it is already so",
		fn = function()
			local rec = fresh({["phy0-ap0"] = {own = OWN_2G}})
			local nbrs = {{"00:00:5e:00:53:21", "corp", nrlist.element("00:00:5e:00:53:21", 2462, 11)}}
			assert_eq(nrlist.sync("phy0-ap0", nbrs), true, "written")
			assert_eq(rec.sets[1].list[1][1], OWN_2G[1], "own entry first")
			assert_eq(rec.sets[1].list[2][1], "00:00:5e:00:53:21", "then the neighbour")
			assert_eq(nrlist.sync("phy0-ap0", nbrs), false, "same again: not written")
			assert_eq(#rec.sets, 1, "one rrm_nr_set")
			assert_eq(nrlist.sync("phy0-ap0", {}), true, "the neighbour gone: written")
			assert_eq(#rec.sets[2].list, 1, "own entry only")
		end
	},
	{
		name = "nrlist: a BSS with no own entry is left alone (802.11k off, or not up yet)",
		fn = function()
			local rec = fresh({["phy0-ap0"] = {}})
			local res, why = nrlist.sync("phy0-ap0", {{"00:00:5e:00:53:21", "corp", "00"}})
			assert_nil(res, "not written")
			assert_eq(why, "no own neighbour entry", "why")
			assert_eq(#rec.sets, 0, "no rrm_nr_set")
		end
	},
	{
		name = "nrlist: an interface name or an SSID that cannot go through a shell word is refused",
		fn = function()
			local rec = fresh({["phy0-ap0"] = {own = {"00:00:5e:00:53:01", "it's", "00"}}})
			local res, why = nrlist.sync("phy0-ap0;reboot", {})
			assert_nil(res, "bad ifname")
			assert_eq(why, "bad interface name", "why")
			res, why = nrlist.sync("phy0-ap0", {{"00:00:5e:00:53:21", "it's", "00"}})
			assert_nil(res, "an SSID with a quote")
			assert_contains(why, "quote", "why")
			assert_eq(#rec.sets, 0, "nothing ran")
		end
	},
	{
		name = "nrlist: a failed rrm_nr_set is reported, not counted as written",
		fn = function()
			local rec = fresh({["phy0-ap0"] = {own = OWN_2G}})
			rec.fail = true
			local res, why = nrlist.sync("phy0-ap0", {{"00:00:5e:00:53:21", "corp", "00"}})
			assert_nil(res, "not written")
			assert_eq(why, "rrm_nr_set failed", "why")
		end
	},
	-- ── inform.lua ────────────────────────────────────────────────────────
	{
		name = "inform: _nrlist_tick gives each 802.11k BSS its siblings and the other band, every five minutes",
		fn = function()
			local rec = fresh({
				["phy0-ap0"] = {own = OWN_2G},
				["phy1-ap0"] = {own = {"00:00:5e:00:53:05", "corp", "00"}},
				["phy0-ap1"] = {},                               -- 802.11k off on this WLAN
			})
			local o = {inform._nrlist, inform._ucihelper, inform._usteer, inform._time, inform._nrlist_next}
			local now = 5000
			inform._nrlist = nrlist
			inform._time = function() return now end
			inform._nrlist_next = 0
			inform._usteer = {filter_wanted = function() return false end}
			inform._ucihelper = {
				get_vap_table = function() return {
					{usage = "user", essid = "corp", bssid = "00:00:5e:00:53:01", radio = "ng", radio_name = "radio0", channel = 6},
					{usage = "user", essid = "corp", bssid = "00:00:5e:00:53:05", radio = "na", radio_name = "radio1", channel = "149"},
					{usage = "user", essid = "iot", bssid = "00:00:5e:00:53:02", radio = "ng", radio_name = "radio0", channel = 6},
					{usage = "downlink", essid = "mesh", bssid = "00:00:5e:00:53:09", radio = "na", radio_name = "radio1"},
					{usage = "user", essid = "off", bssid = "00:00:5e:00:53:0a", radio = "ng", radio_name = "radio0", disabled = true},
				} end,
				get_ifname_for_vap = function(radio, ssid)
					return ({radio0 = {corp = "phy0-ap0", iot = "phy0-ap1"}, radio1 = {corp = "phy1-ap0"}})[radio][ssid]
				end,
			}
			local ok, err = pcall(function()
				nrlist.observe({bssid = "00:00:5e:00:53:21", essid = "corp", channel = 11, freq = 2462,
					peer_mac = "00:00:5e:00:53:99"}, now)
				local n
				local out = with_stderr(function() n = inform._nrlist_tick({}, {config = {}}) end)
				assert_eq(n, 2, "the two corp BSSes; iot has 802.11k off, the mesh link and the disabled WLAN are not asked")
				local by = {}
				for _, s in ipairs(rec.sets) do by[s.ifname] = s.list end
				assert_eq(#by["phy0-ap0"], 3, "2.4 GHz BSS: itself, its 5 GHz twin, the sibling")
				assert_eq(by["phy0-ap0"][2][1], "00:00:5e:00:53:05", "the other band")
				assert_eq(by["phy0-ap0"][3][1], "00:00:5e:00:53:21", "the sibling AP")
				assert_eq(by["phy1-ap0"][2][1], "00:00:5e:00:53:01", "5 GHz BSS: its 2.4 GHz twin")
				assert_nil(by["phy0-ap1"], "no list for a WLAN without 802.11k")
				assert_contains(out, "neighbour list of phy0-ap0 (corp): 2 neighbour(s)", "said")
				now = now + inform.NRLIST_INTERVAL - 1
				assert_eq(inform._nrlist_tick({}, {config = {}}), 0, "not before the interval")
				now = now + 1
				with_stderr(function()
					assert_eq(inform._nrlist_tick({}, {config = {}}), 0, "after it: asked, nothing changed, nothing written")
				end)
				assert_eq(#rec.sets, 2, "no further rrm_nr_set")
			end)
			inform._nrlist, inform._ucihelper, inform._usteer, inform._time, inform._nrlist_next =
				o[1], o[2], o[3], o[4], o[5]
			if not ok then error(err, 0) end
		end
	},
	{
		name = "inform: _nrlist_tick leaves the list to usteer where openUF runs it, and to hostapd when switched off",
		fn = function()
			local rec = fresh({["phy0-ap0"] = {own = OWN_2G}})
			local o = {inform._nrlist, inform._ucihelper, inform._usteer, inform._time, inform._nrlist_next}
			local asked = 0
			inform._nrlist = nrlist
			inform._time = function() return 5000 end
			inform._ucihelper = {get_vap_table = function() asked = asked + 1; return {} end,
				get_ifname_for_vap = function() return "phy0-ap0" end}
			local ok, err = pcall(function()
				inform._nrlist_next = 0
				inform._usteer = {filter_wanted = function() return true end}
				assert_eq(inform._nrlist_tick({}, {config = {}}), 0, "usteer runs: its list")
				inform._nrlist_next = 0
				inform._usteer = {filter_wanted = function() return false end}
				assert_eq(inform._nrlist_tick({}, {config = {neighbour_list = false}}), 0, "conf.lua says no")
				assert_eq(asked, 0, "neither even reads the VAPs")
				assert_eq(#rec.sets, 0, "and nothing is written")
			end)
			inform._nrlist, inform._ucihelper, inform._usteer, inform._time, inform._nrlist_next =
				o[1], o[2], o[3], o[4], o[5]
			if not ok then error(err, 0) end
		end
	},
	{
		name = "inform: after a wifi reload the list is set again once the BSS is back, retrying while it is not",
		fn = function()
			local rec = fresh({["phy0-ap0"] = {}})                 -- the BSS is not up yet
			local o = {inform._nrlist, inform._ucihelper, inform._usteer, inform._time, inform._nrlist_next,
				inform._nrlist_reload_at, inform._deny_settle}
			local now = 9000
			inform._nrlist = nrlist
			inform._time = function() return now end
			inform._usteer = {filter_wanted = function() return false end}
			inform._ucihelper = {
				get_vap_table = function() return {
					{usage = "user", essid = "corp", bssid = "00:00:5e:00:53:01", radio = "ng", radio_name = "radio0", channel = 6},
				} end,
				get_ifname_for_vap = function() return "phy0-ap0" end,
			}
			local ok, err = pcall(function()
				inform._nrlist_next = now + 250                    -- mid-interval
				inform._deny_reloaded()
				assert_eq(inform._nrlist_next, now + inform.NRLIST_SETTLE, "a reload brings the next look forward")
				now = now + inform.NRLIST_SETTLE
				assert_eq(inform._nrlist_tick({}, {config = {}}), 0, "no own entry yet")
				assert_eq(inform._nrlist_next, now + inform.NRLIST_RETRY, "asked again soon, not in five minutes")
				rec.bss["phy0-ap0"].own = OWN_2G                   -- back on the air
				now = now + inform.NRLIST_RETRY
				with_stderr(function()
					assert_eq(inform._nrlist_tick({}, {config = {}}), 0, "no neighbours known: the own entry is the whole list")
				end)
				assert_eq(inform._nrlist_next, now + inform.NRLIST_INTERVAL, "and back to the slow timer")
			end)
			inform._nrlist, inform._ucihelper, inform._usteer, inform._time, inform._nrlist_next,
				inform._nrlist_reload_at, inform._deny_settle = o[1], o[2], o[3], o[4], o[5], o[6], o[7]
			if not ok then error(err, 0) end
		end
	},
}
