-- SPDX-License-Identifier: GPL-3.0-or-later
-- The contract between this openUF and d-malinowski's rrb-unifi plugin
-- (https://github.com/d-malinowski/unifi-openwrt-roaming, openuf-plugin/
-- rrb-unifi.lua), which setup.sh installs: his plugin, run through THIS tree's
-- plugins.lua and ucihelper.apply_config, must produce the 802.11r options a
-- UniFi peer needs. His own tests/test_openuf_contract.lua asserts the same
-- from his side; this is the mirror that runs on every suite run here, so a
-- change to plugins.lua, ucihelper's FT block or ctx cannot silently break the
-- plugin a fresh install gets.
--
-- The plugin under test is the pinned copy in tests/fixtures/rrb-unifi/ (the
-- release setup.sh installs; VERSION there names the tag and the sha256 that
-- setup.sh checks), or whatever RRB_UNIFI_PLUGIN names -- that is how
-- tools/rrb-unifi-compat.sh runs the suite against his LATEST release before
-- the pin is bumped.
-- Run from project root: lua tests/run_tests.lua

local plugins   = dofile("openuf/plugins.lua")
local ucihelper = dofile("openuf/ucihelper.lua")

local FIXTURE_DIR = "tests/fixtures/rrb-unifi"
local PLUGIN_FILE = os.getenv("RRB_UNIFI_PLUGIN") or (FIXTURE_DIR .. "/rrb-unifi.lua")

local function slurp(path)
	local f = io.open(path, "r")
	if not f then return nil end
	local s = f:read("*a"); f:close()
	return s
end

local SRC = slurp(PLUGIN_FILE)
local PLUGIN_PATH = plugins.DIR .. "/rrb-unifi.lua"

local KEY   = "00112233445566778899aabbccddeeff"
local PEER1 = "00:00:5e:00:53:21"
local OWN   = "00:00:5e:00:53:2b"

-- fn(logged) with plugins.lua reading the plugin under test, `enabled` as the
-- plugins.enabled file, and the veth present when `veth` is true.
local function with_plugin(enabled, veth, fn)
	local orig_read, orig_log = plugins._read_file, plugins._log
	local logged = {}
	plugins._read_file = function(path)
		if path == PLUGIN_PATH then return SRC end
		if path == plugins.LIST then return enabled end
		if veth and path == "/sys/class/net/vft0/ifindex" then return "9\n" end
		return nil
	end
	plugins._log = function(msg) logged[#logged + 1] = msg end
	plugins._reset()
	local ok, err = pcall(fn, logged)
	plugins._read_file, plugins._log = orig_read, orig_log
	plugins._reset()
	if not ok then error(err, 0) end
end

local function has_log(logged, text)
	for _, l in ipairs(logged) do
		if l:find(text, 1, true) then return true end
	end
	return false
end

-- One apply_config run with an in-memory cursor that also holds
-- /etc/config/rrb-unifi (the plugin's own config, with the optional ft_peer
-- pre-seed `peers`). Returns the wireless sections.
local function run(vaps, cfg, peers)
	local db = {["rrb-unifi"] = {main = {[".name"] = "main", [".type"] = "rrb",
		ft_peer = peers}}}
	local order = {}
	local c = {}
	function c:set(config, section, a, b)
		assert(tostring(section):match("^[%w_]+$"), "invalid section " .. tostring(section))
		db[config] = db[config] or {}
		if not db[config][section] then
			db[config][section] = {[".name"] = section}
			order[config] = order[config] or {}
			order[config][#order[config] + 1] = section
		end
		if b == nil then db[config][section][".type"] = a
		elseif type(b) == "table" then
			local l = {}
			for i, v in ipairs(b) do l[i] = tostring(v) end
			db[config][section][a] = l
		else db[config][section][a] = b end
	end
	function c:foreach(config, stype, fn)
		for _, n in ipairs(order[config] or {}) do
			local s = db[config][n]
			if s and s[".type"] == stype then fn(s) end
		end
	end
	function c:delete(config, section, option)
		if option ~= nil then
			if db[config] and db[config][section] then db[config][section][option] = nil end
			return
		end
		if db[config] then db[config][section] = nil end
		for i, n in ipairs(order[config] or {}) do
			if n == section then table.remove(order[config], i); break end
		end
	end
	function c:get(config, section, option)
		local s = db[config] and db[config][section]
		local v = s and s[option]
		if v == nil then return nil, "Entry not found" end
		return v
	end
	function c:commit() end

	local orig = {ucihelper._uci, ucihelper._popen, ucihelper._read_file, ucihelper._run_cmd,
		ucihelper._plugins, ucihelper._bcfilter, ucihelper._shaper, ucihelper.get_ifname_for_vap}
	ucihelper._uci = {cursor = function() return c end}
	ucihelper._popen = function() return "" end
	ucihelper._read_file = function(path)
		if path == "/sys/class/net/phy0-ap0/address" then return OWN .. "\n" end
		return nil
	end
	ucihelper._run_cmd = function() return true end
	ucihelper._plugins = plugins
	ucihelper._bcfilter = {reconcile = function() end}
	ucihelper._shaper   = {reconcile = function() end}
	ucihelper.get_ifname_for_vap = function(radio, ssid)
		return (radio == "radio0" and ssid == "corp") and "phy0-ap0" or nil
	end
	c:set("wireless", "radio0", "wifi-device")
	local real = io.stderr
	io.stderr = {write = function() end}
	local ok, err = pcall(ucihelper.apply_config, {radio_table = {}, vap_table = vaps}, cfg)
	io.stderr = real
	ucihelper._uci, ucihelper._popen, ucihelper._read_file, ucihelper._run_cmd,
		ucihelper._plugins, ucihelper._bcfilter, ucihelper._shaper, ucihelper.get_ifname_for_vap =
		orig[1], orig[2], orig[3], orig[4], orig[5], orig[6], orig[7], orig[8]
	if not ok then error(err, 0) end
	return db.wireless
end

local FT_VAP = {ssid = "corp", radio = "radio0", security = "wpa2",
	x_passphrase = "hunter22", fast_roaming_enabled = true, iapp_key = KEY}
local PLAIN_VAP = {ssid = "guest", radio = "radio0", security = "wpa2",
	x_passphrase = "hunter22", iapp_key = KEY}

return {
	{
		name = "rrb-unifi: the plugin under test is readable and is the pinned release when no override is given",
		fn = function()
			assert_true(SRC ~= nil, "plugin file readable: " .. PLUGIN_FILE)
			assert_true(SRC:find("api%s*=%s*1[^%d]") ~= nil, "declares api 1, which this openUF speaks")
			if os.getenv("RRB_UNIFI_PLUGIN") then return end
			-- The pin lives in three places that must agree: the fixture's
			-- VERSION file, setup.sh's default tag and its sha256. A bump that
			-- updates one and not the others is what this catches.
			local ver = slurp(FIXTURE_DIR .. "/VERSION") or ""
			local tag = ver:match("^(v[%d%.]+)")
			local sha = ver:match("\n(%x+)%s+openuf%-plugin/rrb%-unifi%.lua")
			assert_true(tag ~= nil and sha ~= nil, "VERSION names the tag and the plugin's sha256")
			local setup = slurp("setup.sh") or ""
			assert_eq(setup:match('RRB_UNIFI_PINNED_TAG=(v[%d%.]+)'), tag,
				"setup.sh's pinned tag is the fixture's")
			assert_eq(setup:match('RRB_UNIFI_TAG=%${RRB_UNIFI_TAG:%-(v[%d%.]+)}'), tag,
				"setup.sh installs the pinned tag by default")
			assert_eq(setup:match('RRB_UNIFI_PLUGIN_SHA256=(%x+)'), sha,
				"setup.sh's plugin sha256 is the fixture's")
			-- And the fixture's bytes are what the sha says (sha256 in pure
			-- Lua is not worth carrying: the size and a header check, plus
			-- tools/rrb-unifi-compat.sh's real sha256sum, cover a stale copy).
			assert_true(#SRC > 4000 and SRC:find("rrb%-unifi%.lua %-%- openUF plugin") ~= nil,
				"the fixture is d-malinowski's plugin file")
		end
	},
	{
		name = "rrb-unifi: this openUF's loader accepts the plugin from plugins.enabled",
		fn = function()
			assert_eq(plugins.API, 1, "this openUF speaks api 1")
			with_plugin("# rrb-unifi-setup\nrrb-unifi\n", true, function(logged)
				local list = plugins.enabled({config = {}})
				assert_eq(#list, 1, "loaded")
				assert_eq(list[1].name, "rrb-unifi", "by its name")
				assert_eq(#logged, 0, "no load error: " .. tostring(logged[1]))
				assert_true(plugins.fingerprint({config = {}}):find("^rrb%-unifi:%d+$") ~= nil,
					"in the fingerprint, so enabling it makes the controller push again")
			end)
		end
	},
	{
		name = "rrb-unifi: every ctx field the plugin reads is one this openUF hands it",
		fn = function()
			-- The plugin's own source names what it needs of ctx; a renamed
			-- field here would be a plugin that logs "no ctx.util" and changes
			-- nothing. Read off the fixture rather than hard-coded, so a newer
			-- release that starts using a field we lack fails this test.
			local wanted = {}
			for f in SRC:gmatch("ctx%.([%w_]+)") do wanted[f] = true end
			for f in SRC:gmatch("ctx%.util%.([%w_]+)") do wanted["util." .. f] = true end
			local seen = {}
			local probe = "return {name = 'p', api = 1, vap_options = function(extra, vap, ctx)\n"
				.. "for k, v in pairs(ctx) do PROBE[k] = type(v) end\n"
				.. "for k, v in pairs(ctx.util) do PROBE['util.' .. k] = type(v) end\nend}"
			PROBE = seen
			local orig_read, orig_log = plugins._read_file, plugins._log
			plugins._read_file = function(path)
				if path == plugins.DIR .. "/p.lua" then return probe end
				return nil
			end
			plugins._log = function() end
			plugins._reset()
			local ok, err = pcall(plugins.vap_options, {}, {ssid = "x", radio = "radio0"},
				{config = {plugins = {"p"}}},
				{DELETE = ucihelper.DELETE, bssid = function() return OWN end, cursor = function() return {} end})
			plugins._read_file, plugins._log = orig_read, orig_log
			plugins._reset(); PROBE = nil
			assert_true(ok, tostring(err))
			for f in pairs(wanted) do
				assert_true(seen[f] ~= nil, "ctx." .. f .. " exists for the plugin")
			end
		end
	},
	{
		name = "rrb-unifi: apply_config writes the interop options a UniFi peer needs, none refused",
		fn = function()
			with_plugin("rrb-unifi\n", true, function(logged)
				local w = run({FT_VAP}, {config = {}})
				local s = w.openuf_radio0_corp
				assert_eq(#logged, 0, "not skipped: " .. tostring(logged[1]))
				assert_eq(s.ieee80211r, "1", "FT on")
				assert_eq(s.mobility_domain, "5de5", "UniFi mobility domain (SHA1 of salt+SSID)")
				assert_eq(s.ft_psk_generate_local, "0", "key holders written")
				assert_eq(s.nasid, "00005e00532b", "nasid from ctx.bssid")
				assert_nil(s.reassociation_deadline, "DELETE removed openUF's 3000")
				assert_eq(s.pmk_r1_push, "1", "openUF's push kept")
				assert_eq(#s.r0kh, 1, "r0kh wildcard only")
				assert_eq(s.r0kh[1], "ff:ff:ff:ff:ff:ff,*," .. KEY, "r0kh wildcard")
				assert_eq(#s.r1kh, 1, "r1kh wildcard only")
				assert_eq(s.r1kh[1], "00:00:00:00:00:00,00:00:00:00:00:00," .. KEY, "r1kh wildcard")
				assert_eq(#s.hostapd_bss_options, 1, "one raw line")
				assert_eq(s.hostapd_bss_options[1], "ft_iface=vft0", "veth via ctx.read_file")
				assert_eq(s.ssid, "corp", "identity untouched")
				assert_eq(s.key, "hunter22", "passphrase untouched")

				s = run({FT_VAP}, {config = {}}, {PEER1 .. ",00005e005321"}).openuf_radio0_corp
				assert_eq(#logged, 0, "pre-seed: not skipped: " .. tostring(logged[1]))
				assert_eq(#s.r0kh, 2, "pre-seed: peer + wildcard")
				assert_eq(s.r0kh[1], PEER1 .. ",00005e005321," .. KEY, "peer from ctx.cursor()")
				assert_eq(s.r1kh[2], "00:00:00:00:00:00,00:00:00:00:00:00," .. KEY, "r1kh wildcard last")
			end)
		end
	},
	{
		name = "rrb-unifi: a WLAN without FT is pushed exactly as without the plugin",
		fn = function()
			local base = run({PLAIN_VAP}, {config = {}}).openuf_radio0_guest
			with_plugin("rrb-unifi\n", true, function(logged)
				local s = run({PLAIN_VAP}, {config = {}}).openuf_radio0_guest
				for k, v in pairs(base) do
					if type(v) == "table" then
						assert_eq(table.concat(s[k], ","), table.concat(v, ","), k)
					else
						assert_eq(s[k], v, k)
					end
				end
				for k in pairs(s) do assert_true(base[k] ~= nil, "no extra option " .. k) end
				assert_eq(#logged, 0, "nothing logged")
			end)
		end
	},
	{
		name = "rrb-unifi: without the veth the WLAN is still pushed, without ft_iface, and says so",
		fn = function()
			with_plugin("rrb-unifi\n", false, function(logged)
				local s = run({FT_VAP}, {config = {}}).openuf_radio0_corp
				assert_eq(s.mobility_domain, "5de5", "interop options still set")
				assert_nil(s.hostapd_bss_options, "no ft_iface")
				assert_true(has_log(logged, "rrb-unifi: ft_iface not present"), "logged with the plugin name")
				assert_true(not has_log(logged, "skipped"), "not skipped")
			end)
		end
	},
	{
		name = "rrb-unifi: the SAE tuning lines openUF writes survive the plugin's ft_iface line",
		fn = function()
			-- Both producers append to hostapd_bss_options; the plugin keeps
			-- lines it did not write (its 1.4 note), and openUF appends rather
			-- than assigns (the WPA-Enterprise commit's rule).
			with_plugin("rrb-unifi\n", true, function(logged)
				local vap = {ssid = "corp", radio = "radio0", security = "wpa3",
					x_passphrase = "hunter22", fast_roaming_enabled = true, iapp_key = KEY,
					sae_anti_clogging = "7", sae_sync = "9"}
				local s = run({vap}, {config = {}}).openuf_radio0_corp
				assert_eq(#logged, 0, "not skipped: " .. tostring(logged[1]))
				assert_eq(table.concat(s.hostapd_bss_options, " "),
					"sae_anti_clogging_threshold=7 sae_sync=9 ft_iface=vft0",
					"openUF's lines first, the plugin's appended")
			end)
		end
	},
	{
		name = "rrb-unifi: removing the line gives openUF's own values on the next push",
		fn = function()
			local own = run({FT_VAP}, {config = {}}).openuf_radio0_corp
			with_plugin("", true, function(logged)
				local s = run({FT_VAP}, {config = {}}).openuf_radio0_corp
				assert_eq(s.mobility_domain, own.mobility_domain, "openUF's mobility domain is back")
				assert_nil(s.ft_psk_generate_local, "ft_psk_generate_local left to OpenWrt again")
				assert_nil(s.hostapd_bss_options, "no ft_iface")
				assert_eq(#logged, 0, "nothing logged")
			end)
		end
	},
}
