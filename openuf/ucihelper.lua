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
function M.wlan_add(radio, ssid, security, password, extra)
	local uci = get_uci()
	local cursor = uci.cursor()
	local section_name = OPENUF_PREFIX .. ssid:gsub("[^%w_-]", "_")
	local enc = SECURITY_MAP[security] or "psk2"
	cursor:set("wireless", section_name, "wifi-iface")
	cursor:set("wireless", section_name, "device", radio)
	cursor:set("wireless", section_name, "mode", "ap")
	cursor:set("wireless", section_name, "ssid", ssid)
	cursor:set("wireless", section_name, "encryption", enc)
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
-- Handles vap_table, radio_table from the setparam/config response.
function M.apply_config(resp)
	local radio_table = resp.radio_table or {}
	local vap_table   = resp.vap_table   or {}

	-- Apply radio parameters
	for _, radio in ipairs(radio_table) do
		if radio.name then
			M.rf_config(radio.name, radio.mode, radio.channel, radio.tx_power)
		end
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
			M.wlan_add(vap.radio, vap.ssid, vap.security, vap.x_passphrase, extra)
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
			name       = s[".name"],
			channel    = s.channel,
			htmode     = s.htmode,
			txpower    = s.txpower,
			disabled   = (s.disabled == "1"),
		}
	end)
	return radios
end

-- Return a table of VAP (virtual AP) info for the inform payload.
function M.get_vap_table()
	local uci = get_uci()
	local cursor = uci.cursor()
	local vaps = {}
	cursor:foreach("wireless", "wifi-iface", function(s)
		vaps[#vaps + 1] = {
			name       = s[".name"],
			ssid       = s.ssid,
			radio      = s.device,
			encryption = s.encryption,
			disabled   = (s.disabled == "1"),
		}
	end)
	return vaps
end

-- Legacy global API (backwards compat with original stub callers)
ufuci = M

return M
