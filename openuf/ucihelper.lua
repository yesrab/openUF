--[[
	UCI helper for WiFi provisioning.

	Manages SSID sections named with the "openuf_" prefix so that user-created
	SSIDs are never touched.  The controller pushes config via the inform
	response dispatcher (inform.handle_response → apply_config).

	Requires: uci (Lua UCI bindings, standard on OpenWrt)
]]--

local M = {}

-- Injectable seams for tests
M._uci        = nil  -- override with a mock UCI table; nil = require("uci")
M._run_cmd    = function(cmd) return os.execute(cmd) end

-- Injectable: command execution that captures stdout (for read-only introspection,
-- as opposed to M._run_cmd which only reports success/failure for mutating commands).
M._popen = function(cmd)
	local h = io.popen(cmd .. " 2>/dev/null")
	if not h then return "" end
	local s = h:read("*a")
	h:close()
	return s or ""
end

-- Injectable: file reader, for sysfs lookups (e.g. interface MAC address).
M._read_file = function(path)
	local f = io.open(path, "r")
	if not f then return nil end
	local s = f:read("*a")
	f:close()
	return s
end

-- Static radio capability defaults, used when UCI/driver introspection can't
-- supply a real value. Tune per target hardware (see u6iw.lua's fw.ver note
-- for the same caveat pattern).
M.RADIO_DEFAULTS = {
	builtin_antenna  = true,
	builtin_ant_gain = 3,   -- dBi
	max_txpower      = 20,  -- dBm
}

local function get_uci()
	if M._uci then return M._uci end
	return require("uci")
end

-- The UCI prefix applied to all openuf-managed wireless sections
local OPENUF_PREFIX = "openuf_"

-- Map from UniFi security type strings to UCI encryption values
local SECURITY_MAP = {
	["open"]       = "none",
	["wpa2"]       = "psk2",
	["wpa3"]       = "sae",
	["wpa2/wpa3"]  = "sae-mixed",
	["wpa-enterprise"] = "wpa2+ccmp",
}

-- ─── VAP management ──────────────────────────────────────────────────────────

-- Delete all openuf_* wifi-iface sections on the given radio (or all radios).
-- radio: optional UCI radio name (e.g. "radio0"); nil removes from all radios.
function M.wlan_clear(radio)
	local uci = get_uci()
	local cursor = uci.cursor()
	local to_delete = {}
	cursor:foreach("wireless", "wifi-iface", function(s)
		local name = s[".name"]
		if name and name:sub(1, #OPENUF_PREFIX) == OPENUF_PREFIX then
			if radio == nil or s.device == radio then
				to_delete[#to_delete + 1] = name
			end
		end
	end)
	for _, name in ipairs(to_delete) do
		cursor:delete("wireless", name)
	end
	cursor:commit("wireless")
end

-- Create a new wifi-iface section named openuf_<ssid> on the given radio.
-- radio:    UCI radio name, e.g. "radio0" or "radio1"
-- ssid:     SSID string
-- security: "open" | "wpa2" | "wpa3" | "wpa2/wpa3" | "wpa-enterprise"
-- password: WPA pre-shared key (ignored when security == "open")
-- extra:    optional table of additional UCI key/value pairs (802.11r/k/v etc.)
-- network:  UCI network/interface name to bridge this SSID onto (defaults to
--           "lan"); pass a VLAN-tagged interface from ensure_vlan_network() to
--           put the SSID on that VLAN.
-- networkconf_id: optional controller-side network object id, stashed as a
--           custom option so get_vap_table() can report it back unchanged.
function M.wlan_add(radio, ssid, security, password, extra, network, networkconf_id)
	local uci = get_uci()
	local cursor = uci.cursor()
	local section_name = OPENUF_PREFIX .. ssid:gsub("[^%w_-]", "_")
	local enc = SECURITY_MAP[security] or "psk2"
	cursor:set("wireless", section_name, "wifi-iface")
	cursor:set("wireless", section_name, "device", radio)
	cursor:set("wireless", section_name, "mode", "ap")
	cursor:set("wireless", section_name, "ssid", ssid)
	cursor:set("wireless", section_name, "encryption", enc)
	cursor:set("wireless", section_name, "network", network or "lan")
	if networkconf_id then
		cursor:set("wireless", section_name, "openuf_networkconf_id", networkconf_id)
	end
	if password and enc ~= "none" then
		cursor:set("wireless", section_name, "key", password)
	end
	-- 802.11r/k/v
	if extra then
		for k, v in pairs(extra) do
			cursor:set("wireless", section_name, k, tostring(v))
		end
	end
	cursor:commit("wireless")
end

-- Idempotently create (or reuse) a UCI network interface for a VLAN-tagged
-- sub-device, e.g. "eth1.20" for VLAN 20 on cpueth "eth1". Mirrors how
-- dev.conf.net.wan_vlanid is already handled for the WAN/LAN split in the
-- modelmap. Returns the UCI network/interface section name.
function M.ensure_vlan_network(cpueth, vlan_id)
	local uci = get_uci()
	local cursor = uci.cursor()
	local section_name = OPENUF_PREFIX .. "vlan" .. tostring(vlan_id)
	local ifname = cpueth .. "." .. tostring(vlan_id)

	local exists = false
	cursor:foreach("network", "interface", function(s)
		if s[".name"] == section_name then exists = true end
	end)

	if not exists then
		cursor:set("network", section_name, "interface")
		cursor:set("network", section_name, "ifname", ifname)
		cursor:set("network", section_name, "proto", "none")
		cursor:commit("network")
	end

	return section_name
end

-- ─── Radio configuration ─────────────────────────────────────────────────────

-- Configure a radio's channel, mode, and TX power.
-- radio:  UCI radio name, e.g. "radio0"
-- mode:   "11n" | "11ac" | "11ax" (mapped to UCI htmode)
-- chan:   channel number or "auto"
-- txpwr: TX power in dBm (or nil to leave unchanged)
function M.rf_config(radio, mode, chan, txpwr)
	local uci = get_uci()
	local cursor = uci.cursor()
	local htmode_map = {
		["11n"]  = "HT20",
		["11ac"] = "VHT80",
		["11ax"] = "HE80",
	}
	if chan then
		cursor:set("wireless", radio, "channel", tostring(chan))
	end
	if mode and htmode_map[mode] then
		cursor:set("wireless", radio, "htmode", htmode_map[mode])
	end
	if txpwr then
		cursor:set("wireless", radio, "txpower", tostring(txpwr))
	end
	cursor:commit("wireless")
end

-- ─── Config apply ────────────────────────────────────────────────────────────

-- Apply a full config payload from the controller.
-- resp: decoded JSON table from the controller's inform response.
-- cfg:  device configuration (from conf.lua); used for dev.conf.net.lan_cpueth
--       when a VAP requires a VLAN-tagged network. VLAN tagging is skipped
--       (falls back to "lan") if cfg is nil.
-- Handles vap_table, radio_table, and network_table (VLAN join) from the
-- setparam/config response.
function M.apply_config(resp, cfg)
	local radio_table   = resp.radio_table   or {}
	local vap_table     = resp.vap_table     or {}
	local network_table = resp.network_table or {}
	local cpueth = cfg and cfg.net and cfg.net.lan_cpueth

	-- Apply radio parameters
	for _, radio in ipairs(radio_table) do
		if radio.name then
			M.rf_config(radio.name, radio.mode, radio.channel, radio.tx_power)
		end
	end

	-- Index network_table by id for the vap_table.networkconf_id join
	-- (field shapes per paultyng/go-unifi's WLAN/NetworkConf structs --
	-- verify against a live controller capture).
	local network_by_id = {}
	for _, net in ipairs(network_table) do
		local id = net._id or net.id
		if id then network_by_id[id] = net end
	end

	-- Clear existing openuf_ VAPs and re-add from vap_table
	M.wlan_clear()
	for _, vap in ipairs(vap_table) do
		if vap.ssid and vap.radio then
			local extra = {}
			if vap.ieee80211r then extra.ieee80211r = vap.ieee80211r end
			if vap.ieee80211k then extra.ieee80211k = vap.ieee80211k end
			if vap.ieee80211v then extra.ieee80211v = vap.ieee80211v end
			if vap.ft_psk_generate_local then
				extra.ft_psk_generate_local = vap.ft_psk_generate_local
			end

			-- Resolve VLAN: prefer the linked network_table entry, fall back
			-- to a vlan/vlan_enabled set directly on the vap itself.
			local net = vap.networkconf_id and network_by_id[vap.networkconf_id]
			local vlan_enabled = (net and net.vlan_enabled) or vap.vlan_enabled
			local vlan_id      = (net and net.vlan) or vap.vlan

			local network = "lan"
			if vlan_enabled and vlan_id and cpueth then
				network = M.ensure_vlan_network(cpueth, vlan_id)
			end

			M.wlan_add(vap.radio, vap.ssid, vap.security, vap.x_passphrase, extra,
				network, vap.networkconf_id)
		end
	end

	-- Reload wireless
	M._run_cmd("wifi reload")
end

-- ─── Read helpers (for inform payload builder) ───────────────────────────────

-- Return a table of radio info for the inform payload.
function M.get_radio_table()
	local uci = get_uci()
	local cursor = uci.cursor()
	local radios = {}
	cursor:foreach("wireless", "wifi-device", function(s)
		radios[#radios + 1] = {
			name             = s[".name"],
			channel          = s.channel,
			htmode           = s.htmode,
			txpower          = s.txpower,
			disabled         = (s.disabled == "1"),
			builtin_antenna  = M.RADIO_DEFAULTS.builtin_antenna,
			builtin_ant_gain = M.RADIO_DEFAULTS.builtin_ant_gain,
			max_txpower      = M.RADIO_DEFAULTS.max_txpower,
		}
	end)
	return radios
end

-- Resolve a UCI radio name (e.g. "radio0") to its live wireless netdev name
-- (e.g. "wlan0"), as assigned at runtime by netifd. Needed because sta_table()/
-- radio_stats() operate on the live `iw`-visible interface, not the UCI config
-- name. Returns nil if unresolvable (e.g. off-target, radio disabled).
function M.get_ifname_for_radio(radio)
	if not radio then return nil end
	local output = M._popen("ubus call network.wireless status")
	if output == "" then return nil end
	local ok_j, cjson = pcall(require, "cjson")
	if not ok_j then return nil end
	local ok_d, status = pcall(cjson.decode, output)
	if not ok_d or type(status) ~= "table" then return nil end
	local dev = status[radio]
	if type(dev) == "table" and type(dev.interfaces) == "table" then
		for _, iface in ipairs(dev.interfaces) do
			if type(iface) == "table" and iface.ifname then
				return iface.ifname
			end
		end
	end
	return nil
end

-- Return a table of VAP (virtual AP) info for the inform payload.
function M.get_vap_table()
	local uci = get_uci()
	local cursor = uci.cursor()

	local radio_by_name = {}
	for _, r in ipairs(M.get_radio_table()) do radio_by_name[r.name] = r end

	local vaps = {}
	cursor:foreach("wireless", "wifi-iface", function(s)
		local radio = radio_by_name[s.device]
		local bssid = ""
		local ok_if, ifname = pcall(M.get_ifname_for_radio, s.device)
		if ok_if and ifname then
			local mac_raw = M._read_file("/sys/class/net/" .. ifname .. "/address")
			if mac_raw then bssid = mac_raw:match("^([%x:]+)") or "" end
		end
		vaps[#vaps + 1] = {
			name           = s[".name"],
			ssid           = s.ssid,
			radio          = s.device,
			encryption     = s.encryption,
			disabled       = (s.disabled == "1"),
			bssid          = bssid,
			channel        = radio and radio.channel,
			tx_power       = radio and radio.txpower,
			usage          = "user",
			networkconf_id = s.openuf_networkconf_id,
		}
	end)
	return vaps
end

-- Legacy global API (backwards compat with original stub callers)
ufuci = M

return M
