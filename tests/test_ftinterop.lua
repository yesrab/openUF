-- Tests for openuf/ftinterop.lua (802.11r interop with genuine UniFi APs),
-- its use in ucihelper.apply_config (the veth pair, the key holders, the
-- translator restart) and inform's learned-peer heartbeat. Ported from
-- d-malinowski/openUF (pr/unifi-ft-interop, 2026-10-22) and extended for the
-- translator vendored into openuf/rrb/; the "corp" -> 5de5 pin is their check
-- against a live U7 Lite's hostapd config.
-- Run from project root: lua tests/run_tests.lua

local ftinterop = dofile("openuf/ftinterop.lua")
local ucihelper = dofile("openuf/ucihelper.lua")
-- The rrb plugin resolves ftinterop through package.loaded first (as the
-- daemon registers its modules), so the plugin and these tests share one
-- instance and one set of seams.
package.loaded["openuf.ftinterop"] = ftinterop

local KEY   = "00112233445566778899aabbccddeeff"
local PEER1 = "00:00:5e:00:53:21"
local PEER2 = "00:00:5e:00:53:22"
local HEARD = "00:00:5e:00:53:31"   -- learned by the daemon, on this WLAN
local OTHER = "00:00:5e:00:53:32"   -- learned, another WLAN's mobility domain
local OWN   = "00:00:5e:00:53:2b"
local INSTALLED = "/etc/init.d/openuf-rrb"

-- Minimal read-only cursor over {config = {section = {option = value}}}.
local function ro_cursor(db)
	return {get = function(_, config, section, option)
		local s = db[config] and db[config][section]
		local v = s and s[option]
		if v == nil then return nil, "Entry not found" end
		return v
	end}
end

-- The translator's settings: the rrb section of /etc/config/openuf.
local function rrb_cfg(peers, ft_iface, enabled)
	return {openuf = {rrb = {peer = peers, ft_iface = ft_iface, enabled = enabled}}}
end

-- The daemon's peers file as it writes it.
local PEERS_JSON = '{"' .. HEARD .. '":{"md":"5de5","seen":1000,"via":"roam"},'
	.. '"' .. OTHER .. '":{"md":"aaaa","seen":990,"via":"roam"},'
	.. '"00:00:5e:00:53:33":{"md":null,"seen":980,"via":"rrb"},'
	.. '"not-a-mac":{"md":"5de5","seen":1,"via":"roam"}}'

-- Run fn with ftinterop's seams stubbed: sysfs answers for the netdevs named
-- in `present`, the translator's files exist when `present` names their
-- paths, the peers file holds `present.peers` (a JSON string) when set, and
-- log lines are collected instead of printed. Restored even when fn raises,
-- so a failing test cannot leak its stubs.
local function with_ftinterop(present, fn)
	local orig_read, orig_exists, orig_log = ftinterop._read_file, ftinterop._exists, ftinterop._log
	local logged = {}
	ftinterop._read_file = function(path)
		local ifn = path:match("^/sys/class/net/([^/]+)/ifindex$")
		if ifn then return present[ifn] and "9\n" or nil end
		if path == ftinterop.PEERS_FILE then return present.peers end
		return nil
	end
	ftinterop._exists = function(path) return present[path] == true end
	ftinterop._log = function(msg) logged[#logged + 1] = msg end
	local ok, err = pcall(fn, logged)
	ftinterop._read_file, ftinterop._exists, ftinterop._log = orig_read, orig_exists, orig_log
	if not ok then error(err, 0) end
end

local DELETE = setmetatable({}, {__tostring = function() return "<delete>" end})

local function has_log(logged, text)
	for _, l in ipairs(logged) do
		if l:find(text, 1, true) then return true end
	end
	return false
end

-- A recording UCI cursor over {config = {section = {option = value, [".type"] = t}}},
-- shared by ucihelper (wireless, network) and ftinterop (openuf), as the
-- real libuci binding is.
local function rw_cursor(db)
	local cursor = {}
	function cursor:set(config, section, a, b)
		db[config] = db[config] or {}
		db[config][section] = db[config][section] or {[".name"] = section}
		if b == nil then db[config][section][".type"] = a
		else db[config][section][a] = b end
	end
	function cursor:get(config, section, option)
		local s = db[config] and db[config][section]
		local v = s and s[option]
		if v == nil then return nil, "Entry not found" end
		return v
	end
	function cursor:delete(config, section, option)
		if option then
			if db[config] and db[config][section] then db[config][section][option] = nil end
		elseif db[config] then db[config][section] = nil end
	end
	function cursor:foreach(config, stype, fn)
		for _, s in pairs(db[config] or {}) do
			if s[".type"] == stype then fn(s) end
		end
	end
	function cursor:commit() end
	return cursor
end

return {
	{
		name = "ftinterop: sha1 matches the FIPS 180 test vectors",
		fn = function()
			assert_eq(ftinterop.sha1(""), "da39a3ee5e6b4b0d3255bfef95601890afd80709", "empty")
			assert_eq(ftinterop.sha1("abc"), "a9993e364706816aba3e25717850c26c9cd0d89d", "abc")
			-- 56 bytes: the padding spills into a second block.
			assert_eq(ftinterop.sha1("abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq"),
				"84983e441c3bd26ebaae4aa1f95129e5e54670f1", "two-block message")
			assert_eq(ftinterop.sha1(string.rep("a", 1000)),
				"291e9a6c66994949b57ba5e650361e98fc36b1ba", "1000 x a")
		end
	},
	{
		name = "ftinterop: the mobility domain is UniFi firmware's, not openUF's",
		fn = function()
			-- The derivation was checked (by d-malinowski) against a live U7
			-- Lite's (UniFi 8.7.11) hostapd config; "corp" -> 5de5 is the
			-- same formula.
			assert_eq(ftinterop.mobility_domain("corp"), "5de5", "UniFi's derivation")
			assert_neq(ftinterop.mobility_domain("corp"),
				ucihelper.derive_mobility_domain("corp"), "and differs from openUF's own")
			-- 32 bytes is the pad width; a 32-byte SSID gets no padding.
			assert_eq(#ftinterop.mobility_domain(string.rep("x", 32)), 4, "four hex chars")
			assert_eq(ftinterop.r0kh_id_of(OWN:upper()), "00005e00532b", "UniFi's R0KH-ID is the BSSID without colons")
		end
	},
	{
		name = "ftinterop: hand-listed peers come from openuf.rrb, malformed ones dropped",
		fn = function()
			with_ftinterop({}, function(logged)
				local p = ftinterop.peers(ro_cursor(rrb_cfg({
					PEER1:upper() .. ",00005e005321",
					"not-a-mac,00005e005399",
					PEER2 .. ", 00005e005322",
					PEER2 .. ",bad id;rm",
				})))
				assert_eq(#p, 2, "two valid peers")
				assert_eq(p[1].bssid, PEER1, "lowercased BSSID")
				assert_eq(p[1].r0kh_id, "00005e005321", "R0KH-ID")
				assert_eq(p[2].r0kh_id, "00005e005322", "spaces around the comma are fine")
				assert_true(has_log(logged, "not-a-mac"), "a malformed entry is logged")
			end)
			-- A single entry comes back from UCI as a string, not a list.
			local p = ftinterop.peers(ro_cursor(rrb_cfg(PEER1 .. ",00005e005321")))
			assert_eq(#p, 1, "single string entry")
			assert_eq(#ftinterop.peers(ro_cursor({})), 0, "no rrb section -> no peers")
			assert_eq(#ftinterop.peers(nil), 0, "no cursor -> no peers")
		end
	},
	{
		name = "ftinterop: the daemon's peers file is read tolerantly and filtered by mobility domain",
		fn = function()
			with_ftinterop({peers = PEERS_JSON}, function()
				local l = ftinterop.learned()
				assert_eq(#l, 3, "three valid BSSIDs (the non-MAC key dropped)")
				assert_eq(l[1].bssid, HEARD, "sorted")
				assert_eq(l[1].md, "5de5", "domain from a verified announcement")
				assert_eq(l[1].via, "roam", "how it was heard")
				assert_eq(l[2].md, "aaaa", "another WLAN's domain")
				assert_nil(l[3].md, "an RRB-only sighting has no domain yet")
			end)
			with_ftinterop({peers = "not json"}, function()
				assert_eq(#ftinterop.learned(), 0, "garbage -> nothing, no error")
			end)
			with_ftinterop({}, function()
				assert_eq(#ftinterop.learned(), 0, "no file -> nothing")
			end)
			-- The key holders for one WLAN: the learned peers on its domain
			-- (R0KH-ID = BSSID without colons) plus every hand entry, which
			-- wins for the R0KH-ID; sorted.
			local learned = {[HEARD] = "5de5", [OTHER] = "aaaa", [PEER1] = "5de5"}
			local p = ftinterop.peers_for(ro_cursor(rrb_cfg({PEER1 .. ",r0custom"})), learned, "5de5")
			assert_eq(#p, 2, "the other WLAN's peer is left out")
			assert_eq(p[1].bssid, PEER1, "sorted by BSSID")
			assert_eq(p[1].r0kh_id, "r0custom", "the hand entry's R0KH-ID wins")
			assert_eq(p[2].bssid, HEARD, "the learned peer")
			assert_eq(p[2].r0kh_id, "00005e005331", "its R0KH-ID by UniFi's convention")
			assert_eq(#ftinterop.peers_for(ro_cursor({}), nil, "5de5"), 0, "nothing known -> none")
		end
	},
	{
		name = "ftinterop: ft_iface only with the translator installed, enabled, and its veth up",
		fn = function()
			with_ftinterop({vft0 = true, [INSTALLED] = true}, function()
				assert_eq(ftinterop.ft_iface(ro_cursor({})), "vft0", "default name, present")
				assert_nil(ftinterop.ft_iface(ro_cursor(rrb_cfg(nil, "vft7"))), "configured name, absent")
				assert_nil(ftinterop.ft_iface(ro_cursor(rrb_cfg(nil, "x;reboot"))), "unsafe name refused")
				assert_nil(ftinterop.ft_iface(ro_cursor(rrb_cfg(nil, nil, "0"))), "switched off in openuf.rrb")
				assert_true(ftinterop.translator_active(ro_cursor({})), "installed and not switched off")
				assert_false(ftinterop.translator_active(ro_cursor(rrb_cfg(nil, nil, "0"))), "switched off")
			end)
			with_ftinterop({[INSTALLED] = true}, function()
				assert_nil(ftinterop.ft_iface(ro_cursor({})), "no veth -> nil")
			end)
			with_ftinterop({vft0 = true}, function()
				assert_nil(ftinterop.ft_iface(ro_cursor({})), "veth but no service -> nil (nobody would forward)")
				assert_false(ftinterop.translator_installed(), "no init script -> not installed")
			end)
		end
	},
	{
		name = "ftinterop: apply reproduces the working U7 interop config",
		fn = function()
			with_ftinterop({vft0 = true, [INSTALLED] = true}, function()
				local extra = {ieee80211r = "1", reassociation_deadline = "3000",
					pmk_r1_push = "1", ft_over_ds = "0"}
				ftinterop.apply(extra, {ssid = "corp", radio = "radio0", iapp_key = KEY},
					OWN:upper(), ro_cursor(rrb_cfg({
						PEER2 .. ",00005e005322", PEER1 .. ",00005e005321"})), DELETE,
					{[HEARD] = "5de5", [OTHER] = "aaaa"})
				assert_eq(extra.mobility_domain, "5de5", "UniFi mobility domain")
				assert_eq(extra.ft_psk_generate_local, "0", "key holders, not local derivation")
				assert_eq(extra.reassociation_deadline, DELETE, "OpenWrt's default deadline")
				assert_eq(extra.nasid, "00005e00532b", "R0KH-ID = own BSSID")
				assert_eq(extra.pmk_r1_push, "1", "push untouched")
				assert_eq(#extra.r0kh, 4, "two hand peers + one learned + wildcard")
				assert_eq(extra.r0kh[1], PEER1 .. ",00005e005321," .. KEY, "sorted: first hand peer")
				assert_eq(extra.r0kh[2], PEER2 .. ",00005e005322," .. KEY, "second hand peer")
				assert_eq(extra.r0kh[3], HEARD .. ",00005e005331," .. KEY, "the learned peer on this WLAN")
				assert_eq(extra.r0kh[4], "ff:ff:ff:ff:ff:ff,*," .. KEY, "wildcard last")
				assert_eq(extra.r1kh[3], HEARD .. "," .. HEARD .. "," .. KEY, "r1kh learned peer")
				assert_eq(extra.r1kh[4], "00:00:00:00:00:00,00:00:00:00:00:00," .. KEY,
					"r1kh wildcard")
				assert_eq(type(extra.hostapd_bss_options), "table", "list option")
				assert_eq(extra.hostapd_bss_options[1], "ft_iface=vft0", "hostapd on the veth")
			end)
		end
	},
	{
		name = "ftinterop: apply degrades without key, peers, BSSID or veth",
		fn = function()
			with_ftinterop({[INSTALLED] = true}, function(logged)
				local extra = {}
				ftinterop.apply(extra, {ssid = "corp", radio = "radio0"}, nil,
					ro_cursor({}), DELETE)
				assert_eq(extra.mobility_domain, "5de5", "mobility domain still set")
				assert_nil(extra.nasid, "no BSSID -> no nasid option (hostapd's default is the BSSID)")
				assert_nil(extra.r0kh, "no key -> no key holders")
				assert_eq(extra.hostapd_bss_options, DELETE, "no veth -> option removed")
				assert_true(has_log(logged, "iapp_key"), "missing key logged")
				assert_true(has_log(logged, "BSSID not known"), "missing BSSID logged")
				assert_true(has_log(logged, "ft_iface not present"), "missing veth logged")
			end)
			with_ftinterop({vft0 = true, [INSTALLED] = true}, function(logged)
				local extra = {}
				ftinterop.apply(extra, {ssid = "corp", radio = "radio0", iapp_key = KEY},
					OWN, ro_cursor({}), DELETE)
				assert_eq(#extra.r0kh, 1, "wildcard only")
				assert_true(has_log(logged, "no UniFi peer known"), "missing peers logged")
			end)
		end
	},
	{
		name = "ftinterop: without the translator service, one line per WLAN and a config openUF APs roam on",
		fn = function()
			-- The service ships with openUF, so this is an install that lost
			-- it: the options that keep openUF APs roaming among themselves
			-- are written, nothing names a missing veth, and the log says
			-- the one thing that matters instead of diagnosing each piece.
			with_ftinterop({}, function(logged)
				local extra = {}
				ftinterop.apply(extra, {ssid = "corp", radio = "radio0", iapp_key = KEY},
					OWN, ro_cursor({}), DELETE)
				assert_eq(extra.mobility_domain, "5de5", "UniFi's mobility domain, the same on every openUF AP")
				assert_eq(extra.ft_psk_generate_local, "0", "key holders")
				assert_eq(#extra.r0kh, 1, "the wildcard key holder every openUF AP accepts")
				assert_eq(extra.nasid, "00005e00532b", "nasid")
				assert_eq(extra.hostapd_bss_options, DELETE, "no ft_iface: hostapd stays on the bridge")
				assert_true(has_log(logged, "not installed"), "the one line")
				assert_false(has_log(logged, "ft_iface not present"), "no veth diagnosis")
				assert_false(has_log(logged, "no UniFi peer"), "no peer diagnosis")
				assert_eq(#logged, 1, "exactly one line")
			end)
		end
	},
	{
		name = "rrb plugin: a push creates the veth, writes the key holders from the store and restarts the service",
		fn = function()
			local plugins = dofile("openuf/plugins.lua")
			local db = {openuf = {rrb = {[".type"] = "rrb", peer = {PEER1 .. ",00005e005321"}}}}
			local cursor = rw_cursor(db)
			local orig = {uci = ucihelper._uci, popen = ucihelper._popen,
				read = ucihelper._read_file, run = ucihelper._run_cmd,
				bcf = ucihelper._bcfilter, shaper = ucihelper._shaper,
				pl = ucihelper._plugins, vap = ucihelper.get_ifname_for_vap,
				plog = plugins._log}
			local function restore()
				ucihelper._uci, ucihelper._popen = orig.uci, orig.popen
				ucihelper._read_file, ucihelper._run_cmd = orig.read, orig.run
				ucihelper._bcfilter, ucihelper._shaper = orig.bcf, orig.shaper
				ucihelper._plugins, ucihelper.get_ifname_for_vap = orig.pl, orig.vap
				plugins._log = orig.plog
				plugins._reset()
				ucihelper._phy_caps_cache = nil
				ucihelper._phy_caps_unstable_until = nil
				ucihelper._phy_caps_read_at = nil
				ucihelper._network_dirty = false
				ucihelper.end_pass()
			end
			ucihelper.end_pass()
			ucihelper._phy_caps_cache = nil
			ucihelper._uci = {cursor = function() return cursor end}
			ucihelper._popen = function() return "" end
			plugins._log = function() end
			plugins._reset()
			-- The veth exists only once the network has been reloaded with
			-- the sections the plugin wrote.
			local veth_up = false
			local cmds = {}
			ucihelper._read_file = function(path)
				if path == "/sys/class/net/phy0-ap0/address" then return OWN .. "\n" end
				if path == "/sys/class/net/vft0/ifindex" then return veth_up and "9\n" or nil end
				if path == "/etc/init.d/openuf-rrb" then return "#!/bin/sh /etc/rc.common\n" end
				return nil
			end
			ucihelper._run_cmd = function(cmd)
				cmds[#cmds + 1] = cmd
				if cmd:find("network reload", 1, true) and db.network and db.network.openuf_ftveth then
					veth_up = true
				end
				return true
			end
			ucihelper._bcfilter = {reconcile = function() end}
			ucihelper._shaper = {reconcile = function() end}
			ucihelper._plugins = plugins
			ucihelper.get_ifname_for_vap = function(radio)
				return radio == "radio0" and "phy0-ap0" or nil
			end
			local resp = {radio_table = {}, vap_table = {
				{ssid = "corp", radio = "radio0", security = "wpa2",
				 x_passphrase = "hunter22", fast_roaming_enabled = true, iapp_key = KEY},
			}}
			local function index_of(text)
				for i, c in ipairs(cmds) do if c == text then return i end end
				return nil
			end
			-- inform's store: the plugin's table in state.json
			local st = {plugins = {rrb = {peers = {[HEARD] = "5de5", [OTHER] = "aaaa"}}}}
			local function store(name) st.plugins[name] = st.plugins[name] or {}; return st.plugins[name] end
			local on = {config = {unifi_ft_interop = true}}
			local ok, err = pcall(function()
				with_ftinterop({vft0 = true, [INSTALLED] = true}, function()
					ucihelper.apply_config(resp, on, {plugin_store = store})
					-- the veth pair, as netifd sections, before the VAPs
					local dev = db.network and db.network.openuf_ftveth
					assert_not_nil(dev, "veth device section written by before_push")
					assert_eq(dev[".type"], "device", "a config device")
					assert_eq(dev.type, "veth", "of type veth")
					assert_eq(dev.name, "vft0", "hostapd's end")
					assert_eq(dev.peer_name, "vft1", "the daemon's end")
					assert_eq(db.network.openuf_ftlink.device, "vft0", "proto-none interface for vft0")
					assert_eq(db.network.openuf_ftpeer.proto, "none", "and for vft1")
					local reload = index_of("/etc/init.d/network reload 2>/dev/null")
					local wifi = index_of("wifi reload")
					assert_true(reload and wifi and reload < wifi, "network reloaded before the wifi reload")
					-- the section, through vap_options
					local s = db.wireless.openuf_radio0_corp
					assert_eq(s.ieee80211r, "1", "FT on")
					assert_eq(s.mobility_domain, "5de5", "UniFi mobility domain")
					assert_eq(s.ft_psk_generate_local, "0", "key holders")
					assert_eq(s.nasid, "00005e00532b", "nasid from the live netdev")
					assert_nil(s.reassociation_deadline, "OpenWrt's default deadline")
					assert_eq(#s.r0kh, 3, "hand peer + learned peer on this WLAN + wildcard")
					assert_eq(s.r0kh[1], PEER1 .. ",00005e005321," .. KEY, "the hand peer")
					assert_eq(s.r0kh[2], HEARD .. ",00005e005331," .. KEY, "the learned peer, from the store")
					assert_eq(s.hostapd_bss_options[1], "ft_iface=vft0", "veth")
					-- after_push: the daemon derives its BSSes at start
					local restart = index_of("/etc/init.d/openuf-rrb restart")
					assert_not_nil(restart, "openuf-rrb restarted")
					assert_true(restart > wifi, "after the wifi reload")

					-- a second push: the veth exists, no network reload needed
					cmds = {}
					ucihelper.apply_config(resp, on, {plugin_store = store})
					assert_nil(index_of("/etc/init.d/network reload 2>/dev/null"), "veth present: no reload")

					-- forget: ucihelper's own, then the plugin's on_forget takes the veth
					cmds = {}
					ucihelper.forget()
					assert_not_nil(db.network.openuf_ftveth, "forget alone leaves the veth (the hook does it)")
					plugins.run_hook("on_forget", on, ucihelper.plugin_env({plugin_store = store}))
					assert_nil(db.network.openuf_ftveth, "veth device section removed")
					assert_nil(db.network.openuf_ftlink, "and its interfaces")
					assert_nil(db.network.openuf_ftpeer, "both")
					assert_not_nil(index_of("/etc/init.d/network reload 2>/dev/null"), "network reloaded for it")
					assert_nil(st.plugins.rrb.peers, "the learned peers are forgotten with the controller")

					-- off: nothing of this
					db.wireless = nil
					veth_up = false
					cmds = {}
					ucihelper.apply_config(resp, {config = {}}, {plugin_store = store})
					s = db.wireless.openuf_radio0_corp
					assert_eq(s.mobility_domain, ucihelper.derive_mobility_domain("corp"),
						"off: openUF's own mobility domain")
					assert_eq(s.reassociation_deadline, "3000", "off: UniFi's deadline")
					assert_nil(s.ft_psk_generate_local, "off: left to OpenWrt")
					assert_nil(s.nasid, "off: no nasid")
					assert_nil(s.hostapd_bss_options, "off: no ft_iface")
					assert_eq(#s.r0kh, 1, "off: wildcard only")
					assert_nil(db.network.openuf_ftveth, "off: no veth")
					for _, c in ipairs(cmds) do
						assert_neq(c, "/etc/init.d/openuf-rrb restart", "off: the translator is left alone")
					end
				end)
			end)
			restore()
			if not ok then error(err, 0) end
		end
	},
	{
		name = "rrb plugin: the tick keeps the peers the daemon heard in its store and asks for one re-push",
		fn = function()
			local rrb = dofile("openuf/plugins/rrb.lua")
			local peers_json = PEERS_JSON
			local logged, asked, answer = {}, 0, true
			local ctx = {
				store = {},
				read_file = function(path) if path == ftinterop.PEERS_FILE then return peers_json end end,
				log = function(msg) logged[#logged + 1] = msg end,
				repush = function() asked = asked + 1; return answer end,
			}
			assert_eq(rrb.tick(ctx), "repush", "new peers: a re-push is asked for")
			assert_eq(ctx.store.peers[HEARD], "5de5", "kept with its domain")
			assert_eq(ctx.store.peers[OTHER], "aaaa", "every domain is kept; the push filters per WLAN")
			assert_nil(ctx.store.peers["00:00:5e:00:53:33"], "a sighting without a domain is not a peer yet")
			assert_eq(asked, 1, "asked once")
			assert_nil(rrb.tick(ctx), "the same file brings nothing new")
			assert_eq(asked, 1, "not asked again")
			-- openUF refuses the re-push inside its gap: the peer is still kept
			peers_json = PEERS_JSON:gsub("}}$", '},"00:00:5e:00:53:34":{"md":"5de5","seen":1100,"via":"roam"}}')
			answer = false
			assert_eq(rrb.tick(ctx), "learned", "kept, no re-push granted")
			assert_eq(ctx.store.peers["00:00:5e:00:53:34"], "5de5", "but kept")
			assert_true(#logged >= 2, "each learning is logged")
			-- no store (a caller without state): nothing happens
			assert_nil(rrb.tick({read_file = ctx.read_file, log = ctx.log}), "no store -> nil")
			-- status for the UI
			with_ftinterop({vft0 = true, [INSTALLED] = true, peers = PEERS_JSON}, function()
				local st = rrb.status({store = ctx.store, read_file = ftinterop._read_file,
					cursor = function() return ro_cursor({}) end, util = dofile("openuf/util.lua")})
				assert_true(st.installed and st.active and st.veth, "installed, active, veth up")
				assert_eq(st.ft_iface, "vft0", "names")
				assert_eq(st.peers, 3, "peers in the store")
				assert_eq(st.heard, 3, "sightings in the daemon's file")
			end)
		end
	},

}
