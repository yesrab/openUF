-- Tests for openuf/ucihelper.lua (UCI-backed WiFi provisioning, VLAN join).
-- Run from project root: lua tests/run_tests.lua
--
-- Uses an in-memory mock UCI cursor (mirrors the subset of the real `uci`
-- Lua binding's API that ucihelper.lua relies on: cursor:foreach/set/delete/commit).

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

	function cursor:delete(config, section)
		if db[config] then db[config][section] = nil end
		if section_order[config] then
			for i, name in ipairs(section_order[config]) do
				if name == section then table.remove(section_order[config], i); break end
			end
		end
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
		name = "ucihelper: wlan_add sets explicit network, networkconf_id and wlanconf_id",
		fn = function()
			with_ucihelper(function(db)
				ucihelper.wlan_add("radio0", "guest", "open", nil, nil,
					"openuf_vlan20", "net-abc123", "6a540dd2ffb26b8537ec967d")
				local s = db.wireless.openuf_radio0_guest
				assert_eq(s.network, "openuf_vlan20", "network set")
				assert_eq(s.openuf_networkconf_id, "net-abc123", "networkconf_id stashed")
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
		name = "ucihelper: apply_config tags a VAP via network_table join",
		fn = function()
			with_ucihelper(function(db)
				local resp = {
					cfgversion = "2",
					radio_table = {},
					network_table = {
						{_id = "net-1", vlan = 20, vlan_enabled = true, purpose = "corporate"},
					},
					vap_table = {
						{ssid = "corp", radio = "radio0", security = "wpa2",
						 x_passphrase = "hunter22", networkconf_id = "net-1"},
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
					network_table = {
						{_id = "net-1", vlan = 20, vlan_enabled = false},
					},
					vap_table = {
						{ssid = "corp", radio = "radio0", security = "open",
						 networkconf_id = "net-1"},
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
					network_table = {
						{_id = "net-1", vlan = 20, vlan_enabled = true},
					},
					vap_table = {
						{ssid = "corp", radio = "radio0", security = "open",
						 networkconf_id = "net-1"},
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
					network_table = {},
					vap_table = {
						{ssid = "corp", radio = "radio0", security = "wpa2",
						 x_passphrase = "hunter22", networkconf_id = "net-1",
						 fast_roaming_enabled = true},
					},
				}
				ucihelper.apply_config(resp, nil)
				local s = db.wireless.openuf_radio0_corp
				assert_eq(s.ieee80211r, "1", "FT enabled")
				assert_eq(s.mobility_domain, ucihelper.derive_mobility_domain("net-1"),
					"mobility_domain derived from networkconf_id")
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
					radio_table = {}, network_table = {},
					vap_table = {{ssid = "corp", radio = "radio0", security = "wpa2",
						x_passphrase = "hunter22", networkconf_id = "net-1",
						fast_roaming_enabled = true}},
				}
				ucihelper.apply_config(resp1, nil)
				local first = db.wireless.openuf_radio0_corp.mobility_domain

				local resp2 = {
					radio_table = {}, network_table = {},
					vap_table = {{ssid = "corp", radio = "radio1", security = "wpa2",
						x_passphrase = "hunter22", networkconf_id = "net-1",
						fast_roaming_enabled = true}},
				}
				ucihelper.apply_config(resp2, nil)
				local second = db.wireless.openuf_radio1_corp.mobility_domain

				assert_eq(first, second,
					"same networkconf_id yields same mobility_domain regardless of radio")
			end)
		end
	},
	{
		name = "ucihelper: apply_config lets controller-sent FT fields override derived defaults",
		fn = function()
			with_ucihelper(function(db)
				local resp = {
					radio_table = {},
					network_table = {},
					vap_table = {
						{ssid = "corp", radio = "radio0", security = "wpa2",
						 x_passphrase = "hunter22", networkconf_id = "net-1",
						 fast_roaming_enabled = true,
						 mobility_domain = "abcd", ft_over_ds = "1"},
					},
				}
				ucihelper.apply_config(resp, nil)
				local s = db.wireless.openuf_radio0_corp
				assert_eq(s.mobility_domain, "abcd", "explicit mobility_domain wins")
				assert_eq(s.ft_over_ds, "1", "explicit ft_over_ds wins")
			end)
		end
	},
	{
		name = "ucihelper: apply_config writes bss_transition from vap.bss_transition",
		fn = function()
			with_ucihelper(function(db)
				local resp = {
					radio_table = {}, network_table = {},
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
					radio_table = {}, network_table = {},
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
					radio_table = {}, network_table = {},
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
					radio_table = {}, network_table = {},
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
					radio_table = {}, network_table = {},
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
					radio_table = {}, network_table = {},
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
					radio_table = {}, network_table = {},
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
					radio_table = {}, network_table = {},
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
					radio_table = {}, network_table = {},
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
		name = "ucihelper: apply_config forces 802.11k/BSS-Transition on when band steering is active",
		fn = function()
			with_ucihelper(function(db)
				local resp = {
					radio_table = {}, network_table = {},
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
					radio_table = {}, network_table = {},
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
					radio_table = {}, network_table = {},
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
					radio_table = {}, network_table = {},
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
					radio_table = {}, network_table = {},
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
					radio_table = {}, network_table = {},
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
					radio_table = {}, network_table = {},
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
					radio_table = {}, network_table = {},
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
					"openuf_vlan20", "net-1", "wlan-1")
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
					vap_table = {}, network_table = {},
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
					vap_table = {}, network_table = {},
					radio_table = {{name = "radio0", channel = 6}},
				}
				ucihelper.apply_config(resp, nil)
				local s = db.wireless.radio0
				assert_eq(s.minrssi_rssi, nil, "no minrssi_rssi written when absent from radio_table")
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
