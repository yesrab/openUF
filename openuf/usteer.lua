--[[
	Band Steering support via OpenWrt's usteer daemon.

	CONFIRMED live 2026-07-15 (toggled "Band Steering" in the controller's
	Behavior Controls panel, diffed system_cfg via debug_dump_file): real UniFi
	sends this as a per-WLAN wire field, wireless.<n>.no2ghz_oui ("enabled"/
	"disabled", only present on the WLAN's 2.4GHz/radio0 wireless.<n> entry --
	see inform.lua's _parse_wifi_system_cfg). It is a plain on/off toggle, not
	the 3-state Device.BandsteeringMode (off/equal/prefer_5g) enum an earlier
	version of this module assumed from paultyng/go-unifi's REST model --
	that enum belongs to the controller's admin API, not this wire protocol,
	and this controller version's UI only ever exposes a single checkbox.

	OpenWrt/hostapd has no band-steering concept at all -- there is no UCI
	wireless option for it (no2ghz_oui is a madwifi/QCA driver-specific
	convention: omitting the AP's own OUI from 2.4GHz beacons/probe responses
	nudges dual-band-capable clients toward 5GHz -- mainline mac80211/hostapd
	on OpenWrt has no equivalent). Real steering on OpenWrt requires the
	separate ubus-based `usteer` daemon (/etc/config/usteer), which itself
	depends on 802.11k (neighbor reports) + BSS Transition being enabled on
	every wifi-iface -- see ucihelper.apply_config's opts.band_steering_active
	handling, which forces those on network-wide whenever steering is enabled.

	usteer's only band-preference-specific knob (per the OpenWrt wiki's usteer
	setup guide) is band_steering_threshold. The exact option names and this
	module's USTEER_DEFAULTS value are BEST-EFFORT/UNCONFIRMED (this repo does
	not vendor usteer's source): verify against the real installed package's
	own shipped /etc/config/usteer default file (or `uci show usteer` on
	target/validation hardware) before trusting this on first real deploy. The
	/etc/init.d/usteer service name itself is a standard OpenWrt convention
	(package name == init script name) and is NOT flagged as uncertain.
]]--

local M = {}

-- Injectable: UCI module and command runner, for tests.
M._uci     = nil
M._run_cmd = function(cmd) return os.execute(cmd) end

M.USTEER_DEFAULTS = {
	band_steering_threshold = 5,  -- dB; best-effort, see file header comment
}

local function get_uci()
	if M._uci then return M._uci end
	return require("uci")
end

-- Enable or disable band steering.
-- enabled: boolean
-- cfg:     device configuration (from conf.lua); cfg.net.lan_name selects the
--          usteer network to bind to, defaulting to "lan" when absent.
function M.set_enabled(enabled, cfg)
	local uci = get_uci()
	local cursor = uci.cursor()
	local network = (cfg and cfg.net and cfg.net.lan_name) or "lan"
	local desired = enabled and tostring(M.USTEER_DEFAULTS.band_steering_threshold) or "0"

	-- No-op discipline (same hazard class as switchvlan's reload guard):
	-- this runs on EVERY WiFi setparam, and unconditionally committing +
	-- restarting bounced the steering daemon -- dropping its learned station
	-- table -- on every steady-state inform. Skip when UCI already matches;
	-- the first-ever call (get -> nil) still writes.
	if cursor:get("usteer", "local", "band_steering_threshold") == desired
		and cursor:get("usteer", "local", "network") == network then
		return true
	end

	cursor:set("usteer", "local", "usteer")
	cursor:set("usteer", "local", "network", network)
	cursor:set("usteer", "local", "band_steering_threshold", desired)
	cursor:commit("usteer")

	if enabled then
		M._run_cmd("/etc/init.d/usteer enable 2>/dev/null")
		M._run_cmd("/etc/init.d/usteer restart 2>/dev/null")
	else
		M._run_cmd("/etc/init.d/usteer stop 2>/dev/null")
		M._run_cmd("/etc/init.d/usteer disable 2>/dev/null")
	end

	return true
end

return M
