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

-- Map a UCI wifi-device's channel number to the controller's band identifier.
-- The real controller's radio_table schema requires this "radio" field
-- ("ng"/"na"/"ad"/"6e") on every entry -- confirmed via decompiling the
-- controller's own radio-band enum (com.ubnt.g.f.e.rYtJfMBbtgWvku), whose
-- string-to-enum parser unconditionally calls .toLowerCase() with no null
-- guard. Omitting "radio" (as this function previously did) means that
-- parser gets a null and throws, which corrupts the controller's adopt/UI
-- state on every single inform -- invisible until now because radio_table
-- was always empty (no target hardware to source it from) prior to the UCI
-- mock. Only "ng"/"na" are handled -- openUF only targets dual-band 2.4/5GHz
-- hardware (see modelmap/generic-dualband-ap.lua's hwassign); 60GHz/6GHz
-- would need channel ranges that overlap 5GHz's numbering and can't be
-- disambiguated by channel number alone.
local function band_for_channel(channel)
	local ch = tonumber(channel)
	if ch and ch >= 1 and ch <= 14 then return "ng" end
	return "na"
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

-- Deterministic 16-bit id from a string, formatted as 4 hex chars (802.11r
-- mobility domain is a 2-octet field). Used as a stopgap mobility_domain
-- when the controller only sends the high-level fast_roaming_enabled toggle
-- and no raw mobility_domain/r0kh/r1kh (UniFi's admin API has no such fields
-- -- it computes and syncs them internally across all APs on a site). Same
-- seed always yields the same domain, so every openUF-emulated AP on the
-- same network computes it identically without needing to coordinate.
function M.derive_mobility_domain(seed)
	local hash = 0
	for i = 1, #seed do
		hash = (hash * 31 + seed:byte(i)) % 65536
	end
	return string.format("%04x", hash)
end

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

-- UCI option marking a wifi-iface that openUF disabled on the user's behalf,
-- so use_only_unifi_wlan can be switched back off without stranding the SSID.
local AUTODISABLED = OPENUF_PREFIX .. "autodisabled"

-- Apply conf.lua's use_only_unifi_wlan to every wifi-iface openUF does not
-- manage (i.e. not "openuf_"-prefixed).
--
-- enabled=true  -> disable those SSIDs, stamping each one openUF turns off.
-- enabled=false -> re-enable only the ones carrying that stamp.
--
-- An SSID the *user* had already disabled is never stamped, so switching the
-- option off later does not silently switch their SSID back on. The option is
-- documented (README/USAGE) and shipped as true in conf.lua, but a missing
-- config is treated as false: openUF should not start disabling a stranger's
-- SSIDs just because a caller failed to thread cfg through.
function M.set_wlan_exclusive(enabled)
	local uci = get_uci()
	local cursor = uci.cursor()
	local targets = {}
	cursor:foreach("wireless", "wifi-iface", function(s)
		local name = s[".name"]
		if name and name:sub(1, #OPENUF_PREFIX) ~= OPENUF_PREFIX then
			targets[#targets + 1] = {name = name, disabled = s.disabled,
				stamped = (s[AUTODISABLED] == "1")}
		end
	end)
	for _, t in ipairs(targets) do
		if enabled then
			if t.disabled ~= "1" then
				cursor:set("wireless", t.name, "disabled", "1")
				cursor:set("wireless", t.name, AUTODISABLED, "1")
			end
		elseif t.stamped then
			cursor:set("wireless", t.name, "disabled", "0")
			cursor:set("wireless", t.name, AUTODISABLED, "0")
		end
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
-- wlanconf_id: optional controller-side wlanconf object id (system_cfg's
--           aaa.<n>.id), stashed the same way so get_vap_table() can echo it
--           back as the vap's "id" -- required for the controller to accept
--           the vap (and its sta_table) at all.
function M.wlan_add(radio, ssid, security, password, extra, network, wlanconf_id)
	local uci = get_uci()
	local cursor = uci.cursor()
	-- Section name includes the radio, not just the SSID: broadcasting the
	-- same SSID on both radios simultaneously is the default, common case
	-- (the controller UI's "Radio Band: 2.4 GHz + 5 GHz" checkboxes) and
	-- produces one wlan_add() call per radio with an identical ssid. Keying
	-- purely by SSID collapsed both calls into the same UCI section, so the
	-- second call's "device" silently overwrote the first -- confirmed live
	-- against a real controller: only the last-processed radio's VAP
	-- survived. name:gsub("[^%w_-]", "_") sanitizes radio the same way ssid
	-- already was, though UCI radio names ("radio0"/"radio1") never need it.
	local section_name = OPENUF_PREFIX .. tostring(radio):gsub("[^%w_-]", "_")
		.. "_" .. ssid:gsub("[^%w_-]", "_")
	local enc = SECURITY_MAP[security] or "psk2"
	cursor:set("wireless", section_name, "wifi-iface")
	cursor:set("wireless", section_name, "device", radio)
	cursor:set("wireless", section_name, "mode", "ap")
	cursor:set("wireless", section_name, "ssid", ssid)
	cursor:set("wireless", section_name, "encryption", enc)
	cursor:set("wireless", section_name, "network", network or "lan")
	if wlanconf_id then
		cursor:set("wireless", section_name, "openuf_wlanconf_id", wlanconf_id)
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
-- htmode: UCI/OpenWrt htmode string ("HT20", "HT40", "VHT80", "HE80", ...), or
-- nil to leave the radio's current width/PHY unchanged. Derived from the
-- controller's radio.<n>.ieee_mode by inform.lua's _htmode_from_ieee_mode --
-- that key is the wire's only channel-width signal (CONFIRMED live
-- 2026-07-18). Until then this argument was a "11n"/"11ac"/"11ax" token that
-- nothing on the parse side ever produced, so htmode was never written at all
-- and the controller's channel-width setting silently did nothing.
-- chan:   channel number or "auto"
-- txpwr: TX power in dBm (or nil to leave unchanged)
-- minrssi_enabled/minrssi_raw: "Minimum RSSI" (Devices -> [AP] -> Radios),
-- a per-radio (not per-SSID) setting -- confirmed live 2026-07-14 via the
-- controller's stamgr.<n>.minrssi.* wire keys, a section separate from and
-- indexed the same as radio.<n>. minrssi_raw is stored as-received (raw wire
-- units, an offset from the driver's noise floor, NOT plain dBm -- see
-- inform.lua's M._parse_wifi_system_cfg for the conversion math), since the
-- dBm conversion needs a live noise-floor reading only available later, at
-- enforcement/readback time.
function M.rf_config(radio, htmode, chan, txpwr, minrssi_enabled, minrssi_raw)
	local uci = get_uci()
	local cursor = uci.cursor()
	if chan then
		cursor:set("wireless", radio, "channel", tostring(chan))
	end
	if htmode then
		cursor:set("wireless", radio, "htmode", htmode)
	end
	if txpwr then
		cursor:set("wireless", radio, "txpower", tostring(txpwr))
	end
	if minrssi_enabled ~= nil then
		cursor:set("wireless", radio, "minrssi_enabled", minrssi_enabled and "1" or "0")
	end
	if minrssi_raw then
		cursor:set("wireless", radio, "minrssi_rssi", tostring(minrssi_raw))
	end
	cursor:commit("wireless")
end

-- ─── Config apply ────────────────────────────────────────────────────────────

-- Apply a full config payload from the controller.
-- resp: decoded JSON table from the controller's inform response.
-- cfg:  device configuration (from conf.lua); used for dev.conf.net.lan_cpueth
--       when a VAP requires a VLAN-tagged network. VLAN tagging is skipped
--       (falls back to "lan") if cfg is nil.
-- opts: optional table; opts.band_steering_active (boolean) forces 802.11k +
--       BSS Transition on for every managed iface regardless of each WLAN's
--       own bss_transition setting, since usteer (Band Steering) needs it
--       network-wide to function at all -- see openuf/usteer.lua. nil/false
--       leaves each vap's own setting in effect. opts.device_name is the
--       controller-assigned device name, used as the WPS Device Name value
--       when a vap has advertise_ap_name enabled ("Show Access Point Name in
--       Beacon"); defaults to "openUF" if nil.
-- Handles vap_table and radio_table from the setparam/config response.
function M.apply_config(resp, cfg, opts)
	local radio_table   = resp.radio_table   or {}
	local vap_table     = resp.vap_table     or {}
	local cpueth = cfg and cfg.net and cfg.net.lan_cpueth

	-- Apply radio parameters
	for _, radio in ipairs(radio_table) do
		if radio.name then
			M.rf_config(radio.name, radio.htmode, radio.channel, radio.tx_power,
				radio.min_rssi_enabled, radio.min_rssi)
		end
	end

	-- Clear existing openuf_ VAPs and re-add from vap_table
	M.wlan_clear()
	for _, vap in ipairs(vap_table) do
		if vap.ssid and vap.radio then
			local extra = {}
			if vap.fast_roaming_enabled then
				extra.ieee80211r = "1"
				extra.mobility_domain = M.derive_mobility_domain(vap.ssid)
				extra.ft_psk_generate_local = "1"
				extra.ft_over_ds = "0"
			end
			if opts and opts.band_steering_active then
				-- usteer requires 802.11k (neighbor reports) + BSS
				-- Transition on every managed iface network-wide to
				-- function at all -- confirmed via the OpenWrt wiki's
				-- usteer setup guide. This overrides each WLAN's own
				-- bss_transition/ieee80211k value while device-wide Band
				-- Steering is on, since usteer can't be scoped to a
				-- single SSID.
				extra.ieee80211k          = "1"
				extra.bss_transition      = "1"
				extra.rrm_neighbor_report = "1"
				extra.rrm_beacon_report   = "1"
				extra.wnm_sleep_mode      = "1"
			else
				if vap.bss_transition ~= nil then
					extra.bss_transition = vap.bss_transition and "1" or "0"
				end
			end
			if vap.dtim_period then extra.dtim_period = vap.dtim_period end
			if vap.qbssload ~= nil then
				-- "Force WiFi 4 Mode" (IoT Optimization) sends
				-- wireless.<n>.qbssload=disabled alongside iot=enabled. The
				-- QBSS Load element is emitted by hostapd whenever
				-- bss_load_update_period is non-zero (it is the element's
				-- refresh interval, in beacon intervals); 0 suppresses the
				-- element entirely, which is what the controller is asking
				-- for. 60 is hostapd's own conventional enabled value.
				extra.bss_load_update_period = vap.qbssload and "60" or "0"
			end
			if vap.iot then
				-- Recorded so the applied WiFi-4-compat state is visible in
				-- UCI (and in tests) rather than being invisible. There is
				-- deliberately no radio-level action here: the controller
				-- keeps the shared radio at its configured width, and the
				-- rest of the mode's behavior arrives as the ordinary keys
				-- handled above and below (2.4GHz-only vap placement, WPA2,
				-- PMF/BSS-transition/proxy-ARP/band-steering off). See
				-- inform.lua's parse-side comment for the live evidence.
				extra.openuf_iot = "1"
			end
			if vap.pmf_status ~= nil then
				-- 802.11w PMF. ieee80211w: 0=disabled, 1=optional, 2=required
				-- (hostapd's own option, madwifi/mac80211 alike). The
				-- controller signals this via aaa.<n>.pmf.status+pmf.mode; a
				-- disabled block is mode 0. Written explicitly for both
				-- enabled and disabled so the applied value always reflects
				-- the controller's intent (a WPA2-only WLAN gets an explicit
				-- ieee80211w=0, a WPA2/WPA3 mixed WLAN gets 1/2).
				local w = 0
				if vap.pmf_status == "enabled" then w = vap.pmf_mode or 1 end
				extra.ieee80211w = tostring(w)
			end
			if vap.mcast_enhance ~= nil then
				-- Multicast Enhancement: multicast_to_unicast is the
				-- OpenWrt/mac80211 wifi-iface option that proxies multicast
				-- frames as unicast at the AP (the mechanism UniFi's
				-- "Multicast Enhancement" / "Multicast to Unicast" provides).
				-- Written explicitly on/off, mirroring bss_transition.
				extra.multicast_to_unicast = vap.mcast_enhance and "1" or "0"
			end
			if vap.proxy_arp ~= nil then
				-- "Proxy ARP": the AP answers ARP (and IPv6 ND) on behalf of
				-- associated stations instead of flooding the request over the
				-- air, so sleeping clients aren't woken by every broadcast ARP.
				-- proxy_arp is hostapd's own option name and OpenWrt exposes it
				-- verbatim as a wifi-iface boolean (confirmed in OpenWrt's
				-- hostapd.sh: declared in hostapd_common_add_bss_config and
				-- emitted as "proxy_arp=1" into the per-BSS config). Like
				-- bss_transition it needs a full wpad build -- hostapd only
				-- compiles proxy_arp support in with CONFIG_PROXYARP, which the
				-- -mini/-basic wpad variants leave out. Written explicitly on
				-- and off, mirroring bss_transition/mcast_enhance.
				extra.proxy_arp = vap.proxy_arp and "1" or "0"
			end
			if vap.l2_isolation ~= nil then
				-- "Client Isolation": drop station-to-station frames inside the
				-- BSS. OpenWrt's wifi-iface option is spelled "isolate" (it maps
				-- to hostapd's ap_isolate) -- confirmed in hostapd.sh's
				-- hostapd_common_add_bss_config declaration list.
				extra.isolate = vap.l2_isolation and "1" or "0"
			end
			if vap.advertise_ap_name then
				-- "Show Access Point Name in Beacon" -- CONFIRMED (via
				-- decompiling the controller) to require a device-reported
				-- wifi_caps2 capability bit before the controller even
				-- pushes this field at all; see inform.lua's build_json
				-- for that side. There's no standalone "put this string in
				-- a beacon IE" hostapd option, but there IS a real,
				-- standard mechanism for broadcasting a human-readable
				-- device name in every beacon: the Wi-Fi Alliance WPS/WSC
				-- information element's Device Name attribute, which
				-- hostapd includes automatically once WPS is active
				-- (confirmed via hostapd's own README-WPS and OpenWrt's
				-- documented wifi-iface options: wps_device_name maps
				-- directly to hostapd's device_name). ap_setup_locked=1 is
				-- a standard hostapd/WPS hardening flag that disables
				-- PIN-based external registrar enrollment -- set
				-- unconditionally here to minimize the WPS surface this
				-- opens to only what's needed for the name broadcast,
				-- since no push-button/PIN config method is ever enabled.
				-- NOT independently confirmed against genuine Ubiquiti
				-- hardware (no real device available to capture from) --
				-- this is the standards-based mechanism for the stated
				-- goal, not a verified replica of Ubiquiti's own
				-- implementation.
				extra.wps_device_name = (opts and opts.device_name) or "openUF"
				extra.ap_setup_locked = "1"
			end
			if vap.sae_anti_clogging then
				-- hostapd's own option name for this exact WPA3-SAE tuning
				-- value (default 5, confirmed via hostapd upstream docs).
				-- Renamed to "anti_clogging_threshold" in newer hostapd
				-- (to also cover PASN, not just SAE) -- using the older
				-- name here since it's the one broadly supported across
				-- the OpenWrt/wpad versions this project targets; revisit
				-- if a target build's hostapd has dropped the old alias.
				extra.sae_anti_clogging_threshold = vap.sae_anti_clogging
			end
			if vap.sae_sync then
				-- hostapd's own option name, unchanged/stable across
				-- versions (confirmed via hostapd upstream docs) -- max
				-- SAE sync errors (dot11RSNASAESync) before disconnecting
				-- the offending peer.
				extra.sae_sync = vap.sae_sync
			end
			-- VLAN comes off the vap itself: the controller derives it from
			-- aaa.<n>.br.devname ("br0.20"), not from a linked network object.
			local vlan_enabled = vap.vlan_enabled
			local vlan_id      = vap.vlan

			local network = "lan"
			if vlan_enabled and vlan_id and cpueth then
				network = M.ensure_vlan_network(cpueth, vlan_id)
			end

			M.wlan_add(vap.radio, vap.ssid, vap.security, vap.x_passphrase, extra,
				network, vap.wlanconf_id)
		end
	end

	-- Hand-configured (non-openuf_) SSIDs: disable or restore them per
	-- conf.lua's use_only_unifi_wlan. Runs after the vap loop so it sees the
	-- final section set, and before the reload so both land in one restart.
	M.set_wlan_exclusive(cfg and cfg.config and cfg.config.use_only_unifi_wlan == true)

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
			radio            = band_for_channel(s.channel),
			channel          = s.channel,
			ht               = s.htmode,
			tx_power         = s.txpower,
			disabled         = (s.disabled == "1"),
			builtin_antenna  = M.RADIO_DEFAULTS.builtin_antenna,
			builtin_ant_gain = M.RADIO_DEFAULTS.builtin_ant_gain,
			max_txpower      = M.RADIO_DEFAULTS.max_txpower,
			-- min_rssi_enabled/min_rssi_raw: raw UCI echo of rf_config()'s
			-- minrssi_enabled/minrssi_rssi options. min_rssi_raw is still
			-- wire-encoded units at this point (not dBm) -- inform.lua's
			-- build_json converts it to the real outbound "min_rssi" dBm
			-- field once a live noise-floor reading is available, then
			-- discards this raw field.
			min_rssi_enabled = (s.minrssi_enabled == "1"),
			min_rssi_raw     = tonumber(s.minrssi_rssi),
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

-- "Minimum RSSI" enforcement: send a single 802.11 deauthentication frame to
-- mac on ifname. Deliberately standalone from firewall.lua's block-sta
-- feature -- confirmed via web research that Minimum RSSI is a roaming aid,
-- not a block: it's a one-shot deauth with no persistent drop rule, and the
-- client is free to reassociate immediately (even back to the same radio).
-- No state.json persistence either, unlike blocked_stas -- there's nothing
-- to reconcile on restart since this is fully re-derived every inform cycle
-- from live UCI config + sta_table.
function M.kick_station(ifname, mac)
	M._run_cmd("hostapd_cli -i " .. ifname .. " deauthenticate " .. mac .. " 2>/dev/null")
	return true
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
			name          = s[".name"],
			essid         = s.ssid,
			-- "radio" must be the band identifier ("ng"/"na"), not the UCI
			-- device name -- confirmed via the controller's own stats
			-- pipeline (com.ubnt.service.system.QDcGUYAmLvJwylXw), which
			-- feeds vap_table's "radio" field through the same band-parsing
			-- enum (com.ubnt.g.f.e.rYtJfMBbtgWvku) already fixed for
			-- radio_table -- sending "radio0" here instead of "ng" logs
			-- "unexpected radio[radio0] while processing stats" on every
			-- inform and silently drops that vap's per-station stats
			-- aggregation. "radio_name" (the UCI device name) is a
			-- separate, real field on the same DTO -- kept here unchanged.
			radio         = radio and radio.radio,
			radio_name    = s.device,
			encryption    = s.encryption,
			disabled      = (s.disabled == "1"),
			bssid         = bssid,
			channel       = radio and radio.channel,
			tx_power      = radio and radio.tx_power,
			usage         = "user",
			-- "id" must echo the controller's wlanconf ObjectId (delivered in
			-- system_cfg as aaa.<n>.id, stashed by wlan_add): the controller's
			-- vapInformProcessor silently drops any usage=user vap whose "id"
			-- is missing -- discarding the nested sta_table with it, which
			-- kept every wireless client out of the Clients list. The
			-- controller derives wlanconf_id itself from "id", but the real
			-- DTO carries both, so send both. (Previously this sent the
			-- *networkconf* id as wlanconf_id -- a different object; that id
			-- stays in its own UCI option for the VLAN/mobility-domain logic.)
			id            = s.openuf_wlanconf_id,
			wlanconf_id   = s.openuf_wlanconf_id,
		}
	end)
	return vaps
end

return M
