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
				assert_eq(db.wireless.openuf_myssid.network, "lan", "defaults to lan")
			end)
		end
	},
	{
		name = "ucihelper: wlan_add sets explicit network and networkconf_id",
		fn = function()
			with_ucihelper(function(db)
				ucihelper.wlan_add("radio0", "guest", "open", nil, nil,
					"openuf_vlan20", "net-abc123")
				local s = db.wireless.openuf_guest
				assert_eq(s.network, "openuf_vlan20", "network set")
				assert_eq(s.openuf_networkconf_id, "net-abc123", "networkconf_id stashed")
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
				local s = db.wireless.openuf_corp
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
				assert_eq(db.wireless.openuf_corp.network, "lan", "falls back to lan")
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
				assert_eq(db.wireless.openuf_corp.network, "lan",
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
				local s = db.wireless.openuf_corp
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
				local first = db.wireless.openuf_corp.mobility_domain

				local resp2 = {
					radio_table = {}, network_table = {},
					vap_table = {{ssid = "corp", radio = "radio1", security = "wpa2",
						x_passphrase = "hunter22", networkconf_id = "net-1",
						fast_roaming_enabled = true}},
				}
				ucihelper.apply_config(resp2, nil)
				local second = db.wireless.openuf_corp.mobility_domain

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
				local s = db.wireless.openuf_corp
				assert_eq(s.mobility_domain, "abcd", "explicit mobility_domain wins")
				assert_eq(s.ft_over_ds, "1", "explicit ft_over_ds wins")
			end)
		end
	},
	{
		name = "ucihelper: get_vap_table round-trips wlanconf_id",
		fn = function()
			with_ucihelper(function(db)
				ucihelper.wlan_add("radio0", "corp", "wpa2", "hunter22", nil,
					"openuf_vlan20", "net-1")
				local vaps = ucihelper.get_vap_table()
				assert_eq(#vaps, 1, "one vap")
				assert_eq(vaps[1].wlanconf_id, "net-1", "wlanconf_id read back")
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
}
