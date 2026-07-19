-- Tests for openuf/ucihelper.lua (UCI-backed WiFi provisioning, VLAN tagging).
-- Run from project root: lua tests/run_tests.lua
--
-- Uses an in-memory mock UCI cursor (mirrors the subset of the real `uci`
-- Lua binding's API that ucihelper.lua relies on: cursor:foreach/set/get/delete/commit,
-- including option-level delete(config, section, option)).

local ucihelper = dofile("openuf/ucihelper.lua")

local function new_mock_uci()
	local db           = {}  -- db[config][section] = { [".name"]=.., [".type"]=.., key=val, ... }
	local section_order = {} -- section_order[config] = {name, ...} (foreach iteration order)

	local cursor = {}

	function cursor:set(config, section, a, b)
		db[config] = db[config] or {}
		if not db[config][section] then
			db[config][section] = {[".name"] = section}
			section_order[config] = section_order[config] or {}
			section_order[config][#section_order[config] + 1] = section
		end
		if b == nil then
			db[config][section][".type"] = a
		else
			db[config][section][a] = b
		end
	end

	function cursor:foreach(config, stype, fn)
		for _, name in ipairs(section_order[config] or {}) do
			local s = db[config][name]
			if s and s[".type"] == stype then fn(s) end
		end
	end

	function cursor:delete(config, section, option)
		if option ~= nil then
			if db[config] and db[config][section] then
				db[config][section][option] = nil
			end
			return
		end
		if db[config] then db[config][section] = nil end
		if section_order[config] then
			for i, name in ipairs(section_order[config]) do
				if name == section then table.remove(section_order[config], i); break end
			end
		end
	end

	function cursor:get(config, section, option)
		local s = db[config] and db[config][section]
		return s and s[option]
	end

	function cursor:commit(config) end

	return {mock = {cursor = function() return cursor end}, db = db}
end

-- Fresh mock UCI + neutral injectable seams for each test.
local function with_ucihelper(fn)
	local m = new_mock_uci()
	local orig_uci, orig_popen, orig_read, orig_run =
		ucihelper._uci, ucihelper._popen, ucihelper._read_file, ucihelper._run_cmd
	ucihelper._uci = m.mock
	ucihelper._popen = function() return "" end       -- no live ifname resolution in tests
	ucihelper._read_file = function() return nil end
	ucihelper._run_cmd = function() return true end
	local ok, err = pcall(fn, m.db)
	ucihelper._uci, ucihelper._popen, ucihelper._read_file, ucihelper._run_cmd =
		orig_uci, orig_popen, orig_read, orig_run
	if not ok then error(err, 2) end
end

return {
	{
		name = "ucihelper: wlan_add defaults network to lan",
		fn = function()
			with_ucihelper(function(db)
				ucihelper.wlan_add("radio0", "myssid", "wpa2", "hunter22")
				assert_eq(db.wireless.openuf_radio0_myssid.network, "lan", "defaults to lan")
			end)
		end
	},
	{
		name = "ucihelper: wlan_add sets explicit network and wlanconf_id",
		fn = function()
			with_ucihelper(function(db)
				ucihelper.wlan_add("radio0", "guest", "open", nil, nil,
					"openuf_vlan20", "6a540dd2ffb26b8537ec967d")
				local s = db.wireless.openuf_radio0_guest
				assert_eq(s.network, "openuf_vlan20", "network set")
				assert_eq(s.openuf_wlanconf_id, "6a540dd2ffb26b8537ec967d", "wlanconf_id stashed")
			end)
		end
	},
	{
		name = "ucihelper: wlan_add keeps the same SSID on two radios as separate sections",
		fn = function()
			-- Regression test: broadcasting one SSID on both 2.4GHz and 5GHz
			-- simultaneously (the controller UI's default "Radio Band: 2.4 GHz
			-- + 5 GHz") calls wlan_add() once per radio with an identical
			-- ssid. Section names keyed purely by SSID collapsed both calls
			-- into the same UCI section, so the second call's "device"
			-- silently overwrote the first -- confirmed live against a real
			-- controller: only the last-processed radio's VAP survived.
			with_ucihelper(function(db)
				ucihelper.wlan_add("radio0", "dualband", "wpa2", "hunter22")
				ucihelper.wlan_add("radio1", "dualband", "wpa2", "hunter22")
				local s0 = db.wireless.openuf_radio0_dualband
				local s1 = db.wireless.openuf_radio1_dualband
				assert_true(s0 ~= nil, "radio0 section survives")
				assert_true(s1 ~= nil, "radio1 section survives")
				assert_eq(s0.device, "radio0", "radio0 section bound to radio0")
				assert_eq(s1.device, "radio1", "radio1 section bound to radio1")
			end)
		end
	},
	{
		name = "ucihelper: ensure_vlan_network creates a tagged interface",
		fn = function()
			with_ucihelper(function(db)
				local name = ucihelper.ensure_vlan_network("eth1", 20)
				assert_eq(name, "openuf_vlan20", "section name")
				assert_eq(db.network.openuf_vlan20.ifname, "eth1.20", "tagged ifname")
				assert_eq(db.network.openuf_vlan20.proto, "none", "proto none")
			end)
		end
	},
	{
		name = "ucihelper: ensure_vlan_network is idempotent",
		fn = function()
			with_ucihelper(function(db)
				local a = ucihelper.ensure_vlan_network("eth1", 20)
				local b = ucihelper.ensure_vlan_network("eth1", 20)
				assert_eq(a, b, "same section name returned")
				local count = 0
				for _ in pairs(db.network) do count = count + 1 end
				assert_eq(count, 1, "only one network section created")
			end)
		end
	},
	{
		name = "ucihelper: apply_config tags a VAP from the vlan set on the vap itself",
		fn = function()
			-- The controller derives the VLAN from aaa.<n>.br.devname
			-- ("br0.20") onto the vap; there is no separate network object on
			-- the wire. (This test used to feed a resp.network_table that a
			-- real controller never sends, so it pinned a join that could
			-- never run in production.)
			with_ucihelper(function(db)
				local resp = {
					cfgversion = "2",
					radio_table = {},
					vap_table = {
						{ssid = "corp", radio = "radio0", security = "wpa2",
						 x_passphrase = "hunter22", vlan = 20, vlan_enabled = true},
					},
				}
				ucihelper.apply_config(resp, {net = {lan_cpueth = "eth1"}})
				local s = db.wireless.openuf_radio0_corp
				assert_eq(s.network, "openuf_vlan20", "VAP bound to VLAN network")
				assert_eq(db.network.openuf_vlan20.ifname, "eth1.20", "VLAN interface created")
			end)
		end
	},
	{
		name = "ucihelper: apply_config falls back to lan when vlan_enabled is false",
		fn = function()
			with_ucihelper(function(db)
				local resp = {
					radio_table = {},
					vap_table = {
						{ssid = "corp", radio = "radio0", security = "open",
						 vlan = 20, vlan_enabled = false},
					},
				}
				ucihelper.apply_config(resp, {net = {lan_cpueth = "eth1"}})
				assert_eq(db.wireless.openuf_radio0_corp.network, "lan", "falls back to lan")
			end)
		end
	},
	{
		name = "ucihelper: apply_config falls back to lan without cfg (no cpueth)",
		fn = function()
			with_ucihelper(function(db)
				local resp = {
					radio_table = {},
					vap_table = {
						{ssid = "corp", radio = "radio0", security = "open",
						 vlan = 20, vlan_enabled = true},
					},
				}
				ucihelper.apply_config(resp, nil)
				assert_eq(db.wireless.openuf_radio0_corp.network, "lan",
					"no cpueth available -- can't tag, falls back to lan")
			end)
		end
	},
	{
		name = "ucihelper: apply_config derives mobility_domain from fast_roaming_enabled",
		fn = function()
			with_ucihelper(function(db)
				local resp = {
					radio_table = {},
					vap_table = {
						{ssid = "corp", radio = "radio0", security = "wpa2",
						 x_passphrase = "hunter22", fast_roaming_enabled = true},
					},
				}
				ucihelper.apply_config(resp, nil)
				local s = db.wireless.openuf_radio0_corp
				assert_eq(s.ieee80211r, "1", "FT enabled")
				assert_eq(s.mobility_domain, ucihelper.derive_mobility_domain("corp"),
					"mobility_domain derived from the ssid")
				assert_eq(#s.mobility_domain, 4, "mobility_domain is 4 hex chars")
				assert_eq(s.ft_psk_generate_local, "1", "local PMK generation enabled")
				assert_eq(s.ft_over_ds, "0", "over-DS disabled by default")
			end)
		end
	},
	{
		name = "ucihelper: derive_mobility_domain is stable across independent APs",
		fn = function()
			with_ucihelper(function(db)
				local resp1 = {
					radio_table = {},
					vap_table = {{ssid = "corp", radio = "radio0", security = "wpa2",
						x_passphrase = "hunter22", fast_roaming_enabled = true}},
				}
				ucihelper.apply_config(resp1, nil)
				local first = db.wireless.openuf_radio0_corp.mobility_domain

				local resp2 = {
					radio_table = {},
					vap_table = {{ssid = "corp", radio = "radio1", security = "wpa2",
						x_passphrase = "hunter22", fast_roaming_enabled = true}},
				}
				ucihelper.apply_config(resp2, nil)
				local second = db.wireless.openuf_radio1_corp.mobility_domain

				assert_eq(first, second,
					"same ssid yields same mobility_domain regardless of radio")
			end)
		end
	},
	{
		name = "ucihelper: apply_config writes bss_transition from vap.bss_transition",
		fn = function()
			with_ucihelper(function(db)
				local resp = {
					radio_table = {},
					vap_table = {
						{ssid = "corp", radio = "radio0", security = "wpa2",
						 x_passphrase = "hunter22", bss_transition = true},
					},
				}
				ucihelper.apply_config(resp, nil)
				local s = db.wireless.openuf_radio0_corp
				assert_eq(s.bss_transition, "1", "bss_transition enabled")
				assert_eq(s.ieee80211v, nil, "deprecated ieee80211v option never written")
			end)
		end
	},
	{
		name = "ucihelper: apply_config writes bss_transition=0 (explicit off), not omitted",
		fn = function()
			with_ucihelper(function(db)
				local resp = {
					radio_table = {},
					vap_table = {
						{ssid = "corp", radio = "radio0", security = "wpa2",
						 x_passphrase = "hunter22", bss_transition = false},
					},
				}
				ucihelper.apply_config(resp, nil)
				local s = db.wireless.openuf_radio0_corp
				assert_eq(s.bss_transition, "0", "bss_transition explicitly disabled")
			end)
		end
	},
	{
		name = "ucihelper: apply_config omits bss_transition when absent from the vap",
		fn = function()
			with_ucihelper(function(db)
				local resp = {
					radio_table = {},
					vap_table = {
						{ssid = "corp", radio = "radio0", security = "wpa2",
						 x_passphrase = "hunter22"},
					},
				}
				ucihelper.apply_config(resp, nil)
				local s = db.wireless.openuf_radio0_corp
				assert_eq(s.bss_transition, nil, "no bss_transition option written")
			end)
		end
	},
	{
		name = "ucihelper: apply_config writes dtim_period from vap.dtim_period",
		fn = function()
			with_ucihelper(function(db)
				local resp = {
					radio_table = {},
					vap_table = {
						{ssid = "corp", radio = "radio0", security = "wpa2",
						 x_passphrase = "hunter22", dtim_period = 3},
					},
				}
				ucihelper.apply_config(resp, nil)
				local s = db.wireless.openuf_radio0_corp
				assert_eq(s.dtim_period, "3", "custom dtim_period written")
			end)
		end
	},
	{
		name = "ucihelper: apply_config omits dtim_period when absent (Auto DTIM)",
		fn = function()
			with_ucihelper(function(db)
				local resp = {
					radio_table = {},
					vap_table = {
						{ssid = "corp", radio = "radio0", security = "wpa2",
						 x_passphrase = "hunter22"},
					},
				}
				ucihelper.apply_config(resp, nil)
				local s = db.wireless.openuf_radio0_corp
				assert_eq(s.dtim_period, nil, "no dtim_period option written -- leaves hostapd default")
			end)
		end
	},
	{
		name = "ucihelper: apply_config writes ieee80211w from vap.pmf (enabled/optional)",
		fn = function()
			with_ucihelper(function(db)
				local resp = {
					radio_table = {},
					vap_table = {
						{ssid = "corp", radio = "radio0", security = "wpa2",
						 x_passphrase = "hunter22", pmf_status = "enabled", pmf_mode = 1},
					},
				}
				ucihelper.apply_config(resp, nil)
				local s = db.wireless.openuf_radio0_corp
				assert_eq(s.ieee80211w, "1", "PMF optional -> ieee80211w=1")
			end)
		end
	},
	{
		name = "ucihelper: apply_config writes ieee80211w=2 for PMF required",
		fn = function()
			with_ucihelper(function(db)
				local resp = {
					radio_table = {},
					vap_table = {
						{ssid = "corp", radio = "radio0", security = "wpa3",
						 x_passphrase = "hunter22", pmf_status = "enabled", pmf_mode = 2},
					},
				}
				ucihelper.apply_config(resp, nil)
				local s = db.wireless.openuf_radio0_corp
				assert_eq(s.ieee80211w, "2", "PMF required -> ieee80211w=2")
			end)
		end
	},
	{
		name = "ucihelper: apply_config writes explicit ieee80211w=0 when PMF disabled",
		fn = function()
			with_ucihelper(function(db)
				local resp = {
					radio_table = {},
					vap_table = {
						{ssid = "corp", radio = "radio0", security = "wpa2",
						 x_passphrase = "hunter22", pmf_status = "disabled", pmf_mode = 0},
					},
				}
				ucihelper.apply_config(resp, nil)
				local s = db.wireless.openuf_radio0_corp
				assert_eq(s.ieee80211w, "0", "PMF disabled -> explicit ieee80211w=0")
			end)
		end
	},
	{
		name = "ucihelper: apply_config omits ieee80211w when no pmf block present",
		fn = function()
			with_ucihelper(function(db)
				local resp = {
					radio_table = {},
					vap_table = {
						{ssid = "corp", radio = "radio0", security = "wpa2",
						 x_passphrase = "hunter22"},
					},
				}
				ucihelper.apply_config(resp, nil)
				local s = db.wireless.openuf_radio0_corp
				assert_eq(s.ieee80211w, nil, "no pmf -> ieee80211w unset")
			end)
		end
	},
	{
		name = "ucihelper: get_ifname_for_vap matches the VAP by SSID, not radio position",
		fn = function()
			local orig = ucihelper._popen
			ucihelper._popen = function()
				return '{"radio0":{"interfaces":['
					.. '{"ifname":"wlan0","config":{"ssid":"corp"}},'
					.. '{"ifname":"wlan0-1","config":{"ssid":"guest"}}]}}'
			end
			local corp  = ucihelper.get_ifname_for_vap("radio0", "corp")
			local guest = ucihelper.get_ifname_for_vap("radio0", "guest")
			local miss  = ucihelper.get_ifname_for_vap("radio0", "nosuch")
			ucihelper._popen = orig
			assert_eq(corp, "wlan0", "first VAP resolved by its SSID")
			assert_eq(guest, "wlan0-1", "second VAP resolved by its SSID")
			-- Ambiguous: two interfaces, neither matching. Guessing would apply
			-- one SSID's filter to another.
			assert_eq(miss, nil, "no guess when the SSID is absent and >1 candidate")
		end
	},
	{
		name = "ucihelper: get_ifname_for_vap falls back to a radio's only interface",
		fn = function()
			local orig = ucihelper._popen
			-- No config.ssid reported at all -- but with a single VAP on the
			-- radio there is no other interface it could be.
			ucihelper._popen = function()
				return '{"radio0":{"interfaces":[{"ifname":"wlan0"}]}}'
			end
			local got = ucihelper.get_ifname_for_vap("radio0", "corp")
			ucihelper._popen = orig
			assert_eq(got, "wlan0", "unambiguous single interface is used")
		end
	},
	{
		name = "ucihelper: apply_config records the blocker on the section and reconciles nft",
		fn = function()
			with_ucihelper(function(db)
				local got
				ucihelper._bcfilter = {reconcile = function(rules) got = rules end}
				-- get_ifname_for_vap goes through _popen, stubbed to "" by the
				-- harness, so resolve it directly here instead.
				local orig = ucihelper.get_ifname_for_vap
				ucihelper.get_ifname_for_vap = function(radio, ssid)
					if radio == "radio0" and ssid == "corp" then return "wlan0" end
				end
				local resp = {
					radio_table = {},
					vap_table = {
						{ssid = "corp", radio = "radio0", security = "wpa2",
						 x_passphrase = "hunter22", bcfilt_enabled = true,
						 bcfilt_macs = {"01:00:5e:00:00:fb", "aa:bb:cc:dd:ee:ff"}},
					},
				}
				ucihelper.apply_config(resp, nil)
				ucihelper.get_ifname_for_vap = orig
				ucihelper._bcfilter = nil

				local s = db.wireless.openuf_radio0_corp
				assert_eq(s.openuf_bcfilt, "1", "blocker state recorded in UCI")
				assert_eq(s.openuf_bcfilt_macs, "01:00:5e:00:00:fb aa:bb:cc:dd:ee:ff",
					"allow-list recorded in UCI")
				assert_eq(#got, 1, "one nft rule reconciled")
				assert_eq(got[1].ifname, "wlan0", "rule targets the vap's own netdev")
				assert_eq(#got[1].macs, 2, "both allow-listed MACs carried through")
			end)
		end
	},
	{
		name = "ucihelper: apply_config reconciles an empty ruleset when the blocker is off",
		fn = function()
			with_ucihelper(function(db)
				-- Must still reconcile: turning the control off has to tear the
				-- previous ruleset down, not leave it silently in force.
				local got
				ucihelper._bcfilter = {reconcile = function(rules) got = rules end}
				local resp = {
					radio_table = {},
					vap_table = {
						{ssid = "corp", radio = "radio0", security = "wpa2",
						 x_passphrase = "hunter22", bcfilt_enabled = false},
					},
				}
				ucihelper.apply_config(resp, nil)
				ucihelper._bcfilter = nil
				assert_eq(db.wireless.openuf_radio0_corp.openuf_bcfilt, "0", "recorded off")
				assert_true(got ~= nil, "reconcile still called")
				assert_eq(#got, 0, "no rules")
			end)
		end
	},
	{
		name = "ucihelper: derive_rates makes the floor the sole basic rate",
		fn = function()
			local r = ucihelper.derive_rates(12000, false, false)
			assert_eq(#r.basic_rate, 1, "exactly one basic rate")
			assert_eq(r.basic_rate[1], 12000, "the floor itself is the basic rate")
			assert_eq(r.legacy_rates, "0", "CCK excluded -> legacy_rates off")
			assert_eq(r.supported_rates, nil, "supported_rates untouched without drop_below")
		end
	},
	{
		name = "ucihelper: derive_rates drops rates below the floor when asked",
		fn = function()
			local r = ucihelper.derive_rates(12000, false, true)
			assert_eq(r.supported_rates[1], 12000, "advertised set starts at the floor")
			assert_eq(r.supported_rates[#r.supported_rates], 54000, "and runs to the top")
			for _, rate in ipairs(r.supported_rates) do
				assert_true(rate >= 12000, "no advertised rate below the floor")
			end
		end
	},
	{
		name = "ucihelper: derive_rates keeps CCK rates on the ladder when allowed",
		fn = function()
			local r = ucihelper.derive_rates(1000, true, true)
			assert_eq(r.supported_rates[1], 1000, "1 Mbps CCK retained")
			assert_eq(r.legacy_rates, "1", "legacy rates allowed")
		end
	},
	{
		name = "ucihelper: derive_rates returns nil rather than an empty rate list",
		fn = function()
			-- A floor above every rate on the ladder would otherwise produce an
			-- empty basic_rate and leave hostapd unable to start the BSS.
			assert_eq(ucihelper.derive_rates(99000, true, true), nil, "no rates -> nil")
			assert_eq(ucihelper.derive_rates(nil, true, true), nil, "no floor -> nil")
		end
	},
	{
		name = "ucihelper: apply_config writes radio-level rates from a vap's minrate_data",
		fn = function()
			with_ucihelper(function(db)
				local resp = {
					radio_table = {{name = "radio0"}},
					vap_table = {
						{ssid = "corp", radio = "radio0", security = "wpa2",
						 x_passphrase = "hunter22", minrate_data = 12000,
						 minrate_cck = false, beacon_rate = 12000,
						 minrate_below_disable = true},
					},
				}
				ucihelper.apply_config(resp, nil)
				local r = db.wireless.radio0
				assert_eq(r.basic_rate[1], 12000, "floor written as the basic rate")
				assert_eq(r.legacy_rates, "0", "CCK off")
				-- beacon_rate is the one option OpenWrt does NOT divide by 100.
				assert_eq(r.beacon_rate, "120", "12000 kb/s -> 120 (100-kbps units)")
			end)
		end
	},
	{
		name = "ucihelper: apply_config takes the lowest floor across VAPs on one radio",
		fn = function()
			with_ucihelper(function(db)
				-- Two WLANs share radio0 with different floors. Applying the
				-- stricter 12 Mbps would lock out clients the 1 Mbps WLAN is
				-- meant to admit, so the permissive floor has to win.
				local resp = {
					radio_table = {{name = "radio0"}},
					vap_table = {
						{ssid = "fast", radio = "radio0", security = "wpa2",
						 x_passphrase = "hunter22", minrate_data = 12000,
						 minrate_cck = false, minrate_below_disable = true},
						{ssid = "iot", radio = "radio0", security = "wpa2",
						 x_passphrase = "hunter22", minrate_data = 1000,
						 minrate_cck = true, minrate_below_disable = false},
					},
				}
				ucihelper.apply_config(resp, nil)
				local r = db.wireless.radio0
				assert_eq(r.basic_rate[1], 1000, "lowest floor wins")
				assert_eq(r.legacy_rates, "1", "CCK allowed because one WLAN allows it")
				assert_eq(r.supported_rates, nil, "not all WLANs asked to drop lower rates")
			end)
		end
	},
	{
		name = "ucihelper: apply_config leaves radio rates alone when no VAP has a floor",
		fn = function()
			with_ucihelper(function(db)
				local resp = {
					radio_table = {{name = "radio0"}},
					vap_table = {
						{ssid = "corp", radio = "radio0", security = "wpa2",
						 x_passphrase = "hunter22"},
					},
				}
				ucihelper.apply_config(resp, nil)
				local r = db.wireless.radio0 or {}
				assert_eq(r.basic_rate, nil, "no basic_rate written")
				assert_eq(r.legacy_rates, nil, "no legacy_rates written")
				assert_eq(r.beacon_rate, nil, "no beacon_rate written")
			end)
		end
	},
	{
		name = "ucihelper: apply_config keeps each radio's floor separate",
		fn = function()
			with_ucihelper(function(db)
				local resp = {
					radio_table = {{name = "radio0"}, {name = "radio1"}},
					vap_table = {
						{ssid = "corp", radio = "radio0", security = "wpa2",
						 x_passphrase = "hunter22", minrate_data = 1000,
						 minrate_cck = true},
						{ssid = "corp", radio = "radio1", security = "wpa2",
						 x_passphrase = "hunter22", minrate_data = 24000,
						 minrate_cck = nil},
					},
				}
				ucihelper.apply_config(resp, nil)
				assert_eq(db.wireless.radio0.basic_rate[1], 1000, "2.4GHz floor")
				assert_eq(db.wireless.radio1.basic_rate[1], 24000, "5GHz floor")
			end)
		end
	},
	{
		name = "ucihelper: apply_config writes proxy_arp from vap.proxy_arp",
		fn = function()
			with_ucihelper(function(db)
				local resp = {
					radio_table = {},
					vap_table = {
						{ssid = "corp", radio = "radio0", security = "wpa2",
						 x_passphrase = "hunter22", proxy_arp = true},
					},
				}
				ucihelper.apply_config(resp, nil)
				assert_eq(db.wireless.openuf_radio0_corp.proxy_arp, "1", "proxy ARP enabled")
			end)
		end
	},
	{
		name = "ucihelper: apply_config writes proxy_arp=0 (explicit off)",
		fn = function()
			with_ucihelper(function(db)
				local resp = {
					radio_table = {},
					vap_table = {
						{ssid = "corp", radio = "radio0", security = "wpa2",
						 x_passphrase = "hunter22", proxy_arp = false},
					},
				}
				ucihelper.apply_config(resp, nil)
				assert_eq(db.wireless.openuf_radio0_corp.proxy_arp, "0", "proxy ARP explicitly off")
			end)
		end
	},
	{
		name = "ucihelper: apply_config leaves proxy_arp unset when the vap has none",
		fn = function()
			with_ucihelper(function(db)
				local resp = {
					radio_table = {},
					vap_table = {
						{ssid = "corp", radio = "radio0", security = "wpa2",
						 x_passphrase = "hunter22"},
					},
				}
				ucihelper.apply_config(resp, nil)
				assert_eq(db.wireless.openuf_radio0_corp.proxy_arp, nil, "no proxy_arp written")
			end)
		end
	},
	{
		name = "ucihelper: apply_config writes isolate from vap.l2_isolation",
		fn = function()
			with_ucihelper(function(db)
				local resp = {
					radio_table = {},
					vap_table = {
						{ssid = "corp", radio = "radio0", security = "wpa2",
						 x_passphrase = "hunter22", l2_isolation = true},
					},
				}
				ucihelper.apply_config(resp, nil)
				assert_eq(db.wireless.openuf_radio0_corp.isolate, "1", "client isolation enabled")
			end)
		end
	},
	{
		name = "ucihelper: apply_config writes isolate=0 (explicit off)",
		fn = function()
			with_ucihelper(function(db)
				local resp = {
					radio_table = {},
					vap_table = {
						{ssid = "corp", radio = "radio0", security = "wpa2",
						 x_passphrase = "hunter22", l2_isolation = false},
					},
				}
				ucihelper.apply_config(resp, nil)
				assert_eq(db.wireless.openuf_radio0_corp.isolate, "0", "client isolation explicitly off")
			end)
		end
	},
	{
		name = "ucihelper: apply_config writes hidden from vap.hide_ssid",
		fn = function()
			with_ucihelper(function(db)
				local resp = {
					radio_table = {},
					vap_table = {
						{ssid = "corp", radio = "radio0", security = "wpa2",
						 x_passphrase = "hunter22", hide_ssid = true},
					},
				}
				ucihelper.apply_config(resp, nil)
				assert_eq(db.wireless.openuf_radio0_corp.hidden, "1", "SSID hidden")
			end)
		end
	},
	{
		name = "ucihelper: apply_config writes hidden=0 (explicit off)",
		fn = function()
			with_ucihelper(function(db)
				local resp = {
					radio_table = {},
					vap_table = {
						{ssid = "corp", radio = "radio0", security = "wpa2",
						 x_passphrase = "hunter22", hide_ssid = false},
					},
				}
				ucihelper.apply_config(resp, nil)
				assert_eq(db.wireless.openuf_radio0_corp.hidden, "0", "SSID explicitly broadcast")
			end)
		end
	},
	{
		name = "ucihelper: apply_config writes macfilter/maclist from the MAC filter",
		fn = function()
			with_ucihelper(function(db)
				local resp = {
					radio_table = {},
					vap_table = {
						{ssid = "corp", radio = "radio0", security = "wpa2",
						 x_passphrase = "hunter22",
						 mac_filter_policy = "allow",
						 mac_filter_list = {"00:11:22:33:44:55", "66:77:88:99:aa:bb"}},
					},
				}
				ucihelper.apply_config(resp, nil)
				local s = db.wireless.openuf_radio0_corp
				assert_eq(s.macfilter, "allow", "policy written")
				-- Asserted by index: maclist must reach UCI as a real list, not
				-- a stringified table.
				assert_eq(s.maclist[1], "00:11:22:33:44:55", "first MAC in the list")
				assert_eq(s.maclist[2], "66:77:88:99:aa:bb", "second MAC in the list")
			end)
		end
	},
	{
		name = "ucihelper: apply_config writes macfilter=disable when the filter is off",
		fn = function()
			with_ucihelper(function(db)
				local resp = {
					radio_table = {},
					vap_table = {
						{ssid = "corp", radio = "radio0", security = "wpa2",
						 x_passphrase = "hunter22"},
					},
				}
				ucihelper.apply_config(resp, nil)
				assert_eq(db.wireless.openuf_radio0_corp.macfilter, "disable",
					"no filter -> explicitly disabled")
			end)
		end
	},
	{
		name = "ucihelper: apply_config stamps the speed limit on the section",
		fn = function()
			with_ucihelper(function(db)
				local resp = {
					radio_table = {},
					vap_table = {
						{ssid = "corp", radio = "radio0", security = "wpa2",
						 x_passphrase = "hunter22",
						 ratelimit_down_kbps = 33000, ratelimit_up_kbps = 17000},
					},
				}
				ucihelper.apply_config(resp, nil)
				local s = db.wireless.openuf_radio0_corp
				assert_eq(s.openuf_ratelimit_down, "33000", "downlink kbps recorded")
				assert_eq(s.openuf_ratelimit_up, "17000", "uplink kbps recorded")
			end)
		end
	},
	{
		name = "ucihelper: apply_config leaves no speed-limit stamp when uncapped",
		fn = function()
			with_ucihelper(function(db)
				local resp = {
					radio_table = {},
					vap_table = {
						{ssid = "corp", radio = "radio0", security = "wpa2",
						 x_passphrase = "hunter22"},
					},
				}
				ucihelper.apply_config(resp, nil)
				local s = db.wireless.openuf_radio0_corp
				assert_eq(s.openuf_ratelimit_down, nil, "no downlink stamp")
				assert_eq(s.openuf_ratelimit_up, nil, "no uplink stamp")
			end)
		end
	},
	{
		name = "ucihelper: apply_config writes multicast_to_unicast from vap.mcast_enhance",
		fn = function()
			with_ucihelper(function(db)
				local resp = {
					radio_table = {},
					vap_table = {
						{ssid = "corp", radio = "radio0", security = "wpa2",
						 x_passphrase = "hunter22", mcast_enhance = true},
					},
				}
				ucihelper.apply_config(resp, nil)
				local s = db.wireless.openuf_radio0_corp
				assert_eq(s.multicast_to_unicast, "1", "mcast enhancement enabled")
			end)
		end
	},
	{
		name = "ucihelper: apply_config writes multicast_to_unicast=0 (explicit off)",
		fn = function()
			with_ucihelper(function(db)
				local resp = {
					radio_table = {},
					vap_table = {
						{ssid = "corp", radio = "radio0", security = "wpa2",
						 x_passphrase = "hunter22", mcast_enhance = false},
					},
				}
				ucihelper.apply_config(resp, nil)
				local s = db.wireless.openuf_radio0_corp
				assert_eq(s.multicast_to_unicast, "0", "mcast enhancement explicitly off")
			end)
		end
	},
	{
		name = "ucihelper: apply_config omits multicast_to_unicast when absent",
		fn = function()
			with_ucihelper(function(db)
				local resp = {
					radio_table = {},
					vap_table = {
						{ssid = "corp", radio = "radio0", security = "wpa2",
						 x_passphrase = "hunter22"},
					},
				}
				ucihelper.apply_config(resp, nil)
				local s = db.wireless.openuf_radio0_corp
				assert_eq(s.multicast_to_unicast, nil, "no mcast field -> option unset")
			end)
		end
	},
	{
		name = "ucihelper: apply_config maps security=wpa2/wpa3 to encryption sae-mixed",
		fn = function()
			with_ucihelper(function(db)
				local resp = {
					radio_table = {},
					vap_table = {
						{ssid = "corp", radio = "radio0", security = "wpa2/wpa3",
						 x_passphrase = "hunter22"},
					},
				}
				ucihelper.apply_config(resp, nil)
				local s = db.wireless.openuf_radio0_corp
				assert_eq(s.encryption, "sae-mixed", "mixed -> sae-mixed")
				assert_eq(s.key, "hunter22", "passphrase still written for sae-mixed")
			end)
		end
	},
	{
		name = "ucihelper: apply_config maps security=wpa3 to encryption sae",
		fn = function()
			with_ucihelper(function(db)
				local resp = {
					radio_table = {},
					vap_table = {
						{ssid = "corp", radio = "radio0", security = "wpa3",
						 x_passphrase = "hunter22"},
					},
				}
				ucihelper.apply_config(resp, nil)
				local s = db.wireless.openuf_radio0_corp
				assert_eq(s.encryption, "sae", "wpa3 -> sae")
			end)
		end
	},
	{
		name = "ucihelper: apply_config forces 802.11k/BSS-Transition on when band steering is active",
		fn = function()
			with_ucihelper(function(db)
				local resp = {
					radio_table = {},
					vap_table = {
						{ssid = "corp", radio = "radio0", security = "wpa2",
						 x_passphrase = "hunter22", bss_transition = false},
					},
				}
				ucihelper.apply_config(resp, nil, {band_steering_active = true})
				local s = db.wireless.openuf_radio0_corp
				assert_eq(s.bss_transition, "1", "forced on despite vap.bss_transition=false")
				assert_eq(s.ieee80211k, "1", "802.11k forced on")
				assert_eq(s.rrm_neighbor_report, "1", "rrm_neighbor_report forced on")
				assert_eq(s.rrm_beacon_report, "1", "rrm_beacon_report forced on")
				assert_eq(s.wnm_sleep_mode, "1", "wnm_sleep_mode forced on")
			end)
		end
	},
	{
		name = "ucihelper: apply_config respects per-vap bss_transition when band steering is off",
		fn = function()
			with_ucihelper(function(db)
				local resp = {
					radio_table = {},
					vap_table = {
						{ssid = "corp", radio = "radio0", security = "wpa2",
						 x_passphrase = "hunter22", bss_transition = false},
					},
				}
				ucihelper.apply_config(resp, nil, {band_steering_active = false})
				local s = db.wireless.openuf_radio0_corp
				assert_eq(s.bss_transition, "0", "per-vap setting respected, not forced")
				assert_eq(s.ieee80211k, nil, "802.11k not forced on")
			end)
		end
	},
	{
		name = "ucihelper: apply_config respects per-vap bss_transition when opts is nil",
		fn = function()
			with_ucihelper(function(db)
				local resp = {
					radio_table = {},
					vap_table = {
						{ssid = "corp", radio = "radio0", security = "wpa2",
						 x_passphrase = "hunter22", bss_transition = false},
					},
				}
				ucihelper.apply_config(resp, nil)
				local s = db.wireless.openuf_radio0_corp
				assert_eq(s.bss_transition, "0", "per-vap setting respected without opts")
			end)
		end
	},
	{
		name = "ucihelper: apply_config sets wps_device_name/ap_setup_locked when advertise_ap_name is on",
		fn = function()
			with_ucihelper(function(db)
				local resp = {
					radio_table = {},
					vap_table = {
						{ssid = "corp", radio = "radio0", security = "wpa2",
						 x_passphrase = "hunter22", advertise_ap_name = true},
					},
				}
				ucihelper.apply_config(resp, nil, {device_name = "Living-Room-AP"})
				local s = db.wireless.openuf_radio0_corp
				assert_eq(s.wps_device_name, "Living-Room-AP", "WPS device name from opts.device_name")
				assert_eq(s.ap_setup_locked, "1", "PIN-based WPS enrollment locked out")
			end)
		end
	},
	{
		name = "ucihelper: apply_config defaults wps_device_name to 'openUF' without opts.device_name",
		fn = function()
			with_ucihelper(function(db)
				local resp = {
					radio_table = {},
					vap_table = {
						{ssid = "corp", radio = "radio0", security = "wpa2",
						 x_passphrase = "hunter22", advertise_ap_name = true},
					},
				}
				ucihelper.apply_config(resp, nil)
				local s = db.wireless.openuf_radio0_corp
				assert_eq(s.wps_device_name, "openUF", "falls back to 'openUF'")
			end)
		end
	},
	{
		name = "ucihelper: apply_config omits wps_device_name/ap_setup_locked when advertise_ap_name is off",
		fn = function()
			with_ucihelper(function(db)
				local resp = {
					radio_table = {},
					vap_table = {
						{ssid = "corp", radio = "radio0", security = "wpa2",
						 x_passphrase = "hunter22"},
					},
				}
				ucihelper.apply_config(resp, nil, {device_name = "Living-Room-AP"})
				local s = db.wireless.openuf_radio0_corp
				assert_eq(s.wps_device_name, nil, "no WPS device name written")
				assert_eq(s.ap_setup_locked, nil, "no ap_setup_locked written")
			end)
		end
	},
	{
		name = "ucihelper: apply_config writes sae_anti_clogging_threshold/sae_sync from vap fields",
		fn = function()
			with_ucihelper(function(db)
				local resp = {
					radio_table = {},
					vap_table = {
						{ssid = "corp", radio = "radio0", security = "wpa3",
						 x_passphrase = "hunter22", sae_anti_clogging = 12, sae_sync = 20},
					},
				}
				ucihelper.apply_config(resp, nil)
				local s = db.wireless.openuf_radio0_corp
				assert_eq(s.sae_anti_clogging_threshold, "12", "sae_anti_clogging_threshold written")
				assert_eq(s.sae_sync, "20", "sae_sync written")
			end)
		end
	},
	{
		name = "ucihelper: apply_config omits sae_anti_clogging_threshold/sae_sync when absent",
		fn = function()
			with_ucihelper(function(db)
				local resp = {
					radio_table = {},
					vap_table = {
						{ssid = "corp", radio = "radio0", security = "wpa2",
						 x_passphrase = "hunter22"},
					},
				}
				ucihelper.apply_config(resp, nil)
				local s = db.wireless.openuf_radio0_corp
				assert_eq(s.sae_anti_clogging_threshold, nil, "no sae_anti_clogging_threshold written")
				assert_eq(s.sae_sync, nil, "no sae_sync written")
			end)
		end
	},
	{
		name = "ucihelper: get_vap_table echoes the wlanconf id as both id and wlanconf_id",
		fn = function()
			-- Regression test: the controller's vapInformProcessor silently
			-- drops any usage=user vap whose "id" (the wlanconf ObjectId,
			-- pushed in system_cfg as aaa.<n>.id) is missing -- and the
			-- nested sta_table goes with it, so no wireless client ever
			-- reached the Clients list. Note "id" must be the *wlanconf* id,
			-- not the networkconf id this field used to (mis)carry.
			with_ucihelper(function(db)
				ucihelper.wlan_add("radio0", "corp", "wpa2", "hunter22", nil,
					"openuf_vlan20", "wlan-1")
				local vaps = ucihelper.get_vap_table()
				assert_eq(#vaps, 1, "one vap")
				assert_eq(vaps[1].id, "wlan-1", "id echoes the wlanconf id")
				assert_eq(vaps[1].wlanconf_id, "wlan-1", "wlanconf_id matches id")
			end)
		end
	},
	{
		name = "ucihelper: get_vap_table reports radio as the band, not the UCI device name",
		fn = function()
			-- Regression test: the controller's stats pipeline
			-- (com.ubnt.service.system.QDcGUYAmLvJwylXw) parses vap_table's
			-- "radio" field through the same band-parsing enum as
			-- radio_table's "radio" field (com.ubnt.g.f.e.rYtJfMBbtgWvku:
			-- "ng"/"na"/"ad"/"6e") -- sending the raw UCI device name
			-- ("radio0") there instead logs "unexpected radio[radio0]
			-- while processing stats" on every inform. "radio_name" is the
			-- separate field that legitimately holds the UCI device name.
			with_ucihelper(function(db)
				local uci = ucihelper._uci
				local cursor = uci.cursor()
				cursor:set("wireless", "radio0", "wifi-device")
				cursor:set("wireless", "radio0", "channel", "6")
				cursor:set("wireless", "radio1", "wifi-device")
				cursor:set("wireless", "radio1", "channel", "36")
				ucihelper.wlan_add("radio0", "corp24", "wpa2", "hunter22")
				ucihelper.wlan_add("radio1", "corp5", "wpa2", "hunter22")
				local vaps = ucihelper.get_vap_table()
				table.sort(vaps, function(a, b) return a.essid < b.essid end)
				assert_eq(vaps[1].radio, "ng", "2.4GHz vap reports band ng")
				assert_eq(vaps[1].radio_name, "radio0", "2.4GHz vap keeps UCI device name separately")
				assert_eq(vaps[2].radio, "na", "5GHz vap reports band na")
				assert_eq(vaps[2].radio_name, "radio1", "5GHz vap keeps UCI device name separately")
			end)
		end
	},
	{
		name = "ucihelper: get_radio_table includes capability defaults",
		fn = function()
			with_ucihelper(function(db)
				local uci = ucihelper._uci
				local cursor = uci.cursor()
				cursor:set("wireless", "radio0", "wifi-device")
				cursor:set("wireless", "radio0", "channel", "6")
				local radios = ucihelper.get_radio_table()
				assert_eq(#radios, 1, "one radio")
				assert_eq(radios[1].builtin_ant_gain, ucihelper.RADIO_DEFAULTS.builtin_ant_gain,
					"builtin_ant_gain default")
				assert_eq(radios[1].max_txpower, ucihelper.RADIO_DEFAULTS.max_txpower,
					"max_txpower default")
			end)
		end
	},
	{
		name = "ucihelper: get_radio_table derives radio band from channel",
		fn = function()
			with_ucihelper(function(db)
				local uci = ucihelper._uci
				local cursor = uci.cursor()
				cursor:set("wireless", "radio0", "wifi-device")
				cursor:set("wireless", "radio0", "channel", "6")
				cursor:set("wireless", "radio1", "wifi-device")
				cursor:set("wireless", "radio1", "channel", "36")
				local radios = ucihelper.get_radio_table()
				assert_eq(radios[1].radio, "ng", "channel 6 is 2.4GHz")
				assert_eq(radios[2].radio, "na", "channel 36 is 5GHz")
			end)
		end
	},
	{
		-- "Minimum RSSI" (Devices -> [AP] -> Radios) is per-radio, not
		-- per-SSID -- confirmed live 2026-07-14 via the controller's
		-- stamgr.<n>.minrssi.* wire keys, a section indexed the same as
		-- radio.<n> (separate from vap_table/aaa.<n>/wireless.<n>).
		name = "ucihelper: apply_config writes minrssi UCI options from radio_table",
		fn = function()
			with_ucihelper(function(db)
				local resp = {
					vap_table = {},
					radio_table = {
						{name = "radio0", min_rssi_enabled = true, min_rssi = 15},
					},
				}
				ucihelper.apply_config(resp, nil)
				local s = db.wireless.radio0
				assert_eq(s.minrssi_enabled, "1", "minrssi_enabled written")
				assert_eq(s.minrssi_rssi, "15", "minrssi_rssi written as raw wire units")
			end)
		end
	},
	{
		name = "ucihelper: apply_config omits minrssi UCI options when disabled/absent",
		fn = function()
			with_ucihelper(function(db)
				local resp = {
					vap_table = {},
					radio_table = {{name = "radio0", channel = 6}},
				}
				ucihelper.apply_config(resp, nil)
				local s = db.wireless.radio0
				assert_eq(s.minrssi_rssi, nil, "no minrssi_rssi written when absent from radio_table")
			end)
		end
	},
	{
		name = "ucihelper: apply_config writes htmode from radio.htmode (channel width)",
		fn = function()
			with_ucihelper(function(db)
				local resp = {
					vap_table = {},
					radio_table = {
						{name = "radio0", htmode = "HT40", channel = 6},
						{name = "radio1", htmode = "VHT80", channel = 36},
					},
				}
				ucihelper.apply_config(resp, nil)
				assert_eq(db.wireless.radio0.htmode, "HT40", "2.4GHz htmode written")
				assert_eq(db.wireless.radio1.htmode, "VHT80", "5GHz htmode written")
			end)
		end
	},
	{
		name = "ucihelper: apply_config leaves htmode untouched when radio.htmode is absent",
		fn = function()
			with_ucihelper(function(db)
				local cursor = ucihelper._uci.cursor()
				cursor:set("wireless", "radio0", "wifi-device")
				cursor:set("wireless", "radio0", "htmode", "VHT80")
				local resp = {
					vap_table = {},
					radio_table = {{name = "radio0", channel = 6}},
				}
				ucihelper.apply_config(resp, nil)
				assert_eq(db.wireless.radio0.htmode, "VHT80",
					"pre-existing htmode preserved when the controller sends no ieee_mode")
			end)
		end
	},
	{
		name = "ucihelper: apply_config writes channel 6 from the IoT channel lock",
		fn = function()
			-- "Lock 2.4 GHz to Channel 6 (All APs)" reaches the device as
			-- radio.<n>.channel=6 (CONFIRMED live 2026-07-18) -- no dedicated
			-- key, so this regression-locks the plain channel path it rides.
			with_ucihelper(function(db)
				local resp = {
					vap_table = {},
					radio_table = {{name = "radio0", channel = 6}},
				}
				ucihelper.apply_config(resp, nil)
				assert_eq(db.wireless.radio0.channel, "6", "channel 6 written")
			end)
		end
	},
	{
		name = "ucihelper: apply_config writes the literal channel=auto (ACS) over a stale fixed channel",
		fn = function()
			-- The controller sends radio.<n>.channel=auto for the Auto
			-- setting; the parser passes it through verbatim so this write
			-- replaces any previously pushed fixed channel -- skipping the
			-- write here would leave the old number silently overriding the
			-- user's switch back to Auto.
			with_ucihelper(function(db)
				local cursor = ucihelper._uci.cursor()
				cursor:set("wireless", "radio0", "wifi-device")
				cursor:set("wireless", "radio0", "channel", "11")
				local resp = {
					vap_table = {},
					radio_table = {{name = "radio0", channel = "auto"}},
				}
				ucihelper.apply_config(resp, nil)
				assert_eq(db.wireless.radio0.channel, "auto",
					"stale fixed channel replaced by auto (hostapd ACS)")
			end)
		end
	},
	{
		name = "ucihelper: apply_config writes bss_load_update_period/openuf_iot (Force WiFi 4)",
		fn = function()
			with_ucihelper(function(db)
				local resp = {
					radio_table = {},
					vap_table = {
						{ssid = "corp", radio = "radio0", security = "wpa2",
						 x_passphrase = "hunter22", iot = true, qbssload = false},
					},
				}
				ucihelper.apply_config(resp, nil)
				local s = db.wireless.openuf_radio0_corp
				assert_eq(s.bss_load_update_period, "0", "QBSS Load element suppressed")
				assert_eq(s.openuf_iot, "1", "WiFi-4-compat state recorded")
			end)
		end
	},
	{
		name = "ucihelper: apply_config omits the Force WiFi 4 options when the vap has neither",
		fn = function()
			with_ucihelper(function(db)
				local resp = {
					radio_table = {},
					vap_table = {
						{ssid = "corp", radio = "radio0", security = "wpa2",
						 x_passphrase = "hunter22"},
					},
				}
				ucihelper.apply_config(resp, nil)
				local s = db.wireless.openuf_radio0_corp
				assert_eq(s.bss_load_update_period, nil, "no bss_load_update_period written")
				assert_eq(s.openuf_iot, nil, "no openuf_iot marker written")
			end)
		end
	},
	{
		name = "ucihelper: apply_config disables a radio and its VAP, and round-trips it back",
		fn = function()
			with_ucihelper(function(db)
				ucihelper._uci.cursor():set("wireless", "radio0", "wifi-device")
				ucihelper.apply_config({
					radio_table = {{name = "radio0", disabled = true}},
					vap_table   = {{ssid = "net", radio = "radio0",
						security = "wpa2", x_passphrase = "hunter22", disabled = true}},
				}, nil)
				assert_eq(db.wireless.radio0.disabled, "1", "wifi-device disabled")
				assert_eq(db.wireless.openuf_radio0_net.disabled, "1", "wifi-iface disabled")
				-- The outbound radio_table/vap_table already read `disabled`
				-- off UCI, so the controller sees its own push reflected back.
				assert_true(ucihelper.get_radio_table()[1].disabled, "reported back as disabled")
			end)
		end
	},
	{
		name = "ucihelper: apply_config re-enables explicitly, but leaves UCI alone when unset",
		fn = function()
			with_ucihelper(function(db)
				local cursor = ucihelper._uci.cursor()
				cursor:set("wireless", "radio0", "wifi-device")
				cursor:set("wireless", "radio0", "disabled", "1")

				-- nil means "the wire did not say" -- a radio the user disabled
				-- by hand must survive a push that never mentions status.
				ucihelper.apply_config({radio_table = {{name = "radio0", channel = 6}},
					vap_table = {}}, nil)
				assert_eq(db.wireless.radio0.disabled, "1", "untouched when disabled is nil")

				-- An explicit enabled must clear it, or a radio could never be
				-- switched back on from the controller.
				ucihelper.apply_config({radio_table = {{name = "radio0", disabled = false}},
					vap_table = {}}, nil)
				assert_eq(db.wireless.radio0.disabled, "0", "explicit enable clears it")
			end)
		end
	},
	{
		name = "ucihelper: an applied htmode round-trips back out via get_radio_table().ht",
		fn = function()
			-- radio_table[].ht is what build_json turns into the outbound
			-- spectrum_table width. Before ieee_mode was parsed, openUF only
			-- ever echoed a width it had never applied.
			with_ucihelper(function()
				-- The wifi-device section already exists on a real device;
				-- rf_config only mutates it.
				ucihelper._uci.cursor():set("wireless", "radio0", "wifi-device")
				local resp = {
					vap_table = {},
					radio_table = {{name = "radio0", htmode = "HT40", channel = 6}},
				}
				ucihelper.apply_config(resp, nil)
				local radios = ucihelper.get_radio_table()
				assert_eq(radios[1].ht, "HT40", "applied htmode reported back as ht")
			end)
		end
	},
	{
		name = "ucihelper: use_only_unifi_wlan disables hand-configured SSIDs, not openuf_ ones",
		fn = function()
			with_ucihelper(function(db)
				local cursor = ucihelper._uci.cursor()
				cursor:set("wireless", "default_radio0", "wifi-iface")
				cursor:set("wireless", "default_radio0", "ssid", "MyOwnWiFi")
				local resp = {
					radio_table = {},
					vap_table = {
						{ssid = "corp", radio = "radio0", security = "wpa2",
						 x_passphrase = "hunter22"},
					},
				}
				ucihelper.apply_config(resp, {config = {use_only_unifi_wlan = true}})
				assert_eq(db.wireless.default_radio0.disabled, "1", "user SSID disabled")
				assert_eq(db.wireless.default_radio0.openuf_autodisabled, "1", "and stamped")
				assert_eq(db.wireless.openuf_radio0_corp.disabled, nil,
					"openUF's own vap is never disabled")
			end)
		end
	},
	{
		name = "ucihelper: use_only_unifi_wlan=false leaves hand-configured SSIDs alone",
		fn = function()
			with_ucihelper(function(db)
				local cursor = ucihelper._uci.cursor()
				cursor:set("wireless", "default_radio0", "wifi-iface")
				cursor:set("wireless", "default_radio0", "ssid", "MyOwnWiFi")
				ucihelper.apply_config({radio_table = {}, vap_table = {}},
					{config = {use_only_unifi_wlan = false}})
				assert_eq(db.wireless.default_radio0.disabled, nil, "left untouched")
			end)
		end
	},
	{
		name = "ucihelper: turning use_only_unifi_wlan off re-enables only what openUF disabled",
		fn = function()
			with_ucihelper(function(db)
				local cursor = ucihelper._uci.cursor()
				cursor:set("wireless", "mine", "wifi-iface")
				cursor:set("wireless", "theirs", "wifi-iface")
				-- An SSID the user disabled themselves: never stamped, so it
				-- must not be switched back on behind their back.
				cursor:set("wireless", "theirs", "disabled", "1")

				ucihelper.set_wlan_exclusive(true)
				assert_eq(db.wireless.mine.disabled, "1", "ours disabled")
				assert_eq(db.wireless.theirs.openuf_autodisabled, nil,
					"already-disabled SSID not stamped")

				ucihelper.set_wlan_exclusive(false)
				assert_eq(db.wireless.mine.disabled, "0", "re-enabled")
				assert_eq(db.wireless.theirs.disabled, "1",
					"user's own disabled SSID stays disabled")
			end)
		end
	},
	{
		name = "ucihelper: a missing cfg is treated as use_only_unifi_wlan=false",
		fn = function()
			with_ucihelper(function(db)
				local cursor = ucihelper._uci.cursor()
				cursor:set("wireless", "default_radio0", "wifi-iface")
				ucihelper.apply_config({radio_table = {}, vap_table = {}}, nil)
				assert_eq(db.wireless.default_radio0.disabled, nil,
					"no cfg threaded through -- must not disable a stranger's SSID")
			end)
		end
	},
	{
		name = "ucihelper: get_radio_table echoes minrssi_enabled/minrssi_rssi as raw UCI values",
		fn = function()
			with_ucihelper(function(db)
				local uci = ucihelper._uci
				local cursor = uci.cursor()
				cursor:set("wireless", "radio0", "wifi-device")
				cursor:set("wireless", "radio0", "channel", "6")
				cursor:set("wireless", "radio0", "minrssi_enabled", "1")
				cursor:set("wireless", "radio0", "minrssi_rssi", "15")
				cursor:set("wireless", "radio1", "wifi-device")
				cursor:set("wireless", "radio1", "channel", "36")
				local radios = ucihelper.get_radio_table()
				assert_eq(radios[1].min_rssi_enabled, true, "radio0 minrssi enabled")
				assert_eq(radios[1].min_rssi_raw, 15, "radio0 minrssi raw wire value")
				assert_eq(radios[2].min_rssi_enabled, false, "radio1 minrssi not enabled")
				assert_eq(radios[2].min_rssi_raw, nil, "radio1 has no minrssi_rssi set")
			end)
		end
	},
	{
		name = "ucihelper: kick_station issues a single hostapd_cli deauthenticate",
		fn = function()
			with_ucihelper(function(db)
				local calls = {}
				ucihelper._run_cmd = function(cmd) calls[#calls + 1] = cmd; return true end
				ucihelper.kick_station("wlan0", "aa:bb:cc:dd:ee:ff")
				assert_eq(#calls, 1, "exactly one command run")
				assert_true(calls[1]:find("hostapd_cli", 1, true) ~= nil, "uses hostapd_cli")
				assert_true(calls[1]:find("-i wlan0", 1, true) ~= nil, "targets the given interface")
				assert_true(calls[1]:find("deauthenticate aa:bb:cc:dd:ee:ff", 1, true) ~= nil,
					"deauthenticates the given mac")
			end)
		end
	},
}
