-- Tests for openuf/backhaul.lua: the mesh backhaul plan, the wired-first
-- uplink policy and the wireless `uplink` report. No device access: every seam
-- is replaced.

local backhaul = dofile("openuf/backhaul.lua")

local MESH = {status = true, version = 3, essid = "vwire-5f3369181f7fbab5",
	psk = "0123456789abcdef0123456789abcdef", serial1 = "78:bb:c1:fe:3f:c9",
	connectivity = {status = true, uplink_eth = "eth0", uplink_wds = "ath4", uplink_bridge = "br0"}}
local ENTRIES = {
	{role = "downlink", radio = "radio1", ssid = "vwire-5f3369181f7fbab5",
		psk = "0123456789abcdef0123456789abcdef", devname = "vwire3", hidden = true},
	{role = "uplink", radio = "radio1", ssid = "vport-ac10076fc670", devname = "ath4", hidden = true},
}

-- A fake ucihelper: the two functions tick()/uplink_report() call.
local function fake_ufuci(sections, ifname, dl_sections)
	local f = {calls = {}}
	function f.backhaul_uplink_sections() return sections end
	function f.backhaul_downlink_sections() return dl_sections or {} end
	function f.ifname_for_section(name) return ifname end
	function f.backhaul_set_uplink_enabled(enabled)
		f.calls[#f.calls + 1] = enabled
		for _, s in ipairs(sections) do s.disabled = not enabled end
		return true
	end
	return f
end

local function fake_sysinfo(port)
	return {
		lan_bridge = function() return "br-lan" end,
		uplink_bridge_port = function() return port end,
	}
end

local function with_seams(carrier_by_port, popen_out, fn)
	local orig_read, orig_popen, orig_log = backhaul._read_file, backhaul._popen, backhaul._log
	backhaul._read_file = function(path)
		local port, what = path:match("^/sys/class/net/([^/]+)/(%w+)$")
		if port and (what == "carrier" or what == "operstate") then
			local c = carrier_by_port[port]
			if c == nil then return nil end
			if what == "operstate" then return c and "up\n" or "lowerlayerdown\n" end
			return c and "1\n" or "0\n"
		end
		local stat = path:match("/statistics/([a-z_]+)$")
		if stat then return ({tx_bytes = "1000", rx_bytes = "2000", tx_packets = "10", rx_packets = "20"})[stat] end
		return nil
	end
	backhaul._popen = function() return popen_out or "" end
	backhaul._log = function() end
	backhaul._down_ticks = 0
	backhaul._dirty = false
	local ok, err = pcall(fn)
	backhaul._read_file, backhaul._popen, backhaul._log = orig_read, orig_popen, orig_log
	if not ok then error(err, 0) end
end

return {
	{
		name = "backhaul: plan() turns the captured entries into a downlink AP and a disabled uplink station",
		fn = function()
			local plan = backhaul.plan(MESH, ENTRIES, {}, {backhaul_mode = ""})
			assert_true(plan ~= nil, "a plan")
			assert_eq(plan.downlink.radio, "radio1", "downlink radio")
			assert_eq(plan.downlink.ssid, MESH.essid, "downlink ssid is the mesh essid")
			assert_eq(plan.downlink.key, MESH.psk, "downlink key is the site PSK")
			assert_eq(plan.uplink.radio, "radio1", "uplink radio")
			assert_eq(plan.uplink.ssid, MESH.essid, "the station joins the mesh essid, not its own vport name")
			assert_eq(plan.uplink.key, MESH.psk, "same PSK")
			assert_false(plan.uplink.enabled, "wired by default: the station is written disabled")
			assert_nil(plan.uplink.bssid, "no BSSID pin from the push")
			assert_eq(plan.uplink.vport, "vport-ac10076fc670", "the station's own name is kept for reporting")
			assert_eq(plan.uplink.devname, "ath4", "the controller's devname for the station")
			assert_eq(plan.downlink.devname, "vwire3", "and for the downlink")
		end
	},
	{
		name = "backhaul: plan() keeps the station enabled while the device is already on its wireless uplink",
		fn = function()
			local plan = backhaul.plan(MESH, ENTRIES, {}, {backhaul_mode = "wireless"})
			assert_true(plan.uplink.enabled, "stays enabled across a push")
		end
	},
	{
		name = "backhaul: plan() is nil without an enabled mesh block, a usable PSK, or any entry",
		fn = function()
			assert_nil(backhaul.plan(nil, ENTRIES), "no mesh block")
			local off = {status = false, essid = MESH.essid, psk = MESH.psk}
			assert_nil(backhaul.plan(off, ENTRIES), "mesh.status=disabled")
			local short = {status = true, essid = MESH.essid, psk = "short"}
			assert_nil(backhaul.plan(short, ENTRIES), "a PSK under 8 chars is not WPA2")
			assert_nil(backhaul.plan(MESH, {}), "no entries")
			local only_dl = backhaul.plan(MESH, {ENTRIES[1]})
			assert_true(only_dl.downlink ~= nil and only_dl.uplink == nil, "a parent-only push")
		end
	},
	{
		name = "backhaul: decide() is wired-first with hysteresis on loss and none on return",
		fn = function()
			local mode, ticks = backhaul.decide(true, "wired", 0)
			assert_eq(mode, "wired", "carrier: wired")
			mode, ticks = backhaul.decide(false, "wired", 0)
			assert_eq(mode, "wired", "one tick without carrier: still wired")
			assert_eq(ticks, 1, "counted")
			mode, ticks = backhaul.decide(false, "wired", 1)
			assert_eq(mode, "wireless", "second tick: wireless")
			mode, ticks = backhaul.decide(true, "wireless", 5)
			assert_eq(mode, "wired", "carrier back: wired at once")
			assert_eq(ticks, 0, "counter reset")
			mode, ticks = backhaul.decide(nil, "wireless", 3)
			assert_eq(mode, "wireless", "unknown carrier: hold")
			assert_eq(ticks, 0, "and do not accumulate")
			mode = backhaul.decide(nil, nil, nil)
			assert_eq(mode, "wired", "nothing known: wired")
		end
	},
	{
		name = "backhaul: tick() learns the wired socket, enables the station after two carrier-less ticks and disables it when the wire is back",
		fn = function()
			local carrier = {wan = true}
			with_seams(carrier, "", function()
				local st = {backhaul_mode = "", backhaul_wired_port = ""}
				local secs = {{name = "openuf_bh_ul_radio1", radio = "radio1", ssid = MESH.essid, disabled = true}}
				local uf = fake_ufuci(secs, "phy1-sta0")
				local saves = 0
				local state_mod = {save = function() saves = saves + 1 end}
				assert_eq(backhaul.tick(st, {}, uf, fake_sysinfo("wan"), state_mod), "wired", "wired with carrier")
				assert_eq(st.backhaul_wired_port, "wan", "remembered the socket the gateway is behind")
				assert_eq(saves, 1, "persisted once")
				-- the cable goes: the gateway is no longer behind any port, carrier 0
				carrier.wan = false
				local si = fake_sysinfo(nil)
				assert_eq(backhaul.tick(st, {}, uf, si, state_mod), "wired", "first tick: patience")
				assert_eq(#uf.calls, 0, "station untouched")
				assert_eq(backhaul.tick(st, {}, uf, si, state_mod), "wireless", "second tick: wireless")
				assert_eq(uf.calls[1], true, "station enabled")
				assert_eq(st.backhaul_mode, "wireless", "mode persisted")
				-- the gateway is now behind the station netdev: that must not be taken as a wired socket
				assert_eq(backhaul.tick(st, {}, uf, fake_sysinfo("phy1-sta0"), state_mod), "wireless", "stays wireless")
				assert_eq(st.backhaul_wired_port, "wan", "the station is not a wired socket")
				-- cable back
				carrier.wan = true
				assert_eq(backhaul.tick(st, {}, uf, fake_sysinfo("wan"), state_mod), "wired", "wired again at once")
				assert_eq(uf.calls[#uf.calls], false, "station disabled")
			end)
		end
	},
	{
		name = "backhaul: tick() is a no-op on a device with no uplink station section",
		fn = function()
			with_seams({wan = false}, "", function()
				local st = {backhaul_mode = ""}
				assert_nil(backhaul.tick(st, {}, fake_ufuci({}, nil), fake_sysinfo("wan"), nil), "nothing to do")
				assert_true(st.backhaul_mode == "", "state untouched")
			end)
		end
	},
	{
		name = "backhaul: uplink_report() describes the hop only while wireless and associated",
		fn = function()
			local link = "Connected to 78:bb:c1:fe:3f:cb (on phy1-sta0)\n\tSSID: vwire-5f3369181f7fbab5\n"
				.. "\tfreq: 5500\n\tRX: 1000 bytes (10 packets)\n\tTX: 2000 bytes (20 packets)\n"
				.. "\tsignal: -47 dBm\n\trx bitrate: 866.7 MBit/s\n\ttx bitrate: 780.0 MBit/s\n"
			with_seams({}, link, function()
				local secs = {{name = "openuf_bh_ul_radio1", radio = "radio1", ssid = MESH.essid, disabled = false}}
				local uf = fake_ufuci(secs, "phy1-sta0")
				local st = {backhaul_mode = "wireless", backhaul_parent = "78:bb:c1:fe:3f:c9"}
				local up = backhaul.uplink_report(st, {}, uf)
				assert_eq(up.type, "wireless", "type")
				assert_eq(up.name, "phy1-sta0", "netdev name when the section has no controller devname")
				secs[1].devname = "ath4"
				assert_eq(backhaul.uplink_report(st, {}, uf).name, "ath4", "the controller's devname when known")
				secs[1].devname = nil
				assert_eq(up.bssid, "78:bb:c1:fe:3f:cb", "the BSS it joined")
				assert_eq(up.uplink_mac, "78:bb:c1:fe:3f:c9", "the parent the controller named")
				assert_eq(up.channel, 100, "freq 5500 -> channel 100")
				assert_eq(up.radio, "na", "5 GHz")
				assert_eq(up.signal, -47, "signal")
				assert_eq(up.tx_rate, 780000, "kbps")
				assert_eq(up.tx_bytes, 1000, "counters from sysfs")
				assert_eq(up.essid, MESH.essid, "essid")
				assert_nil(backhaul.uplink_report({backhaul_mode = "wired"}, {}, uf), "wired: nothing")
				-- no priority-1 parent from the controller: resolve it from the sibling element
				local si = {scan_table = function() return {
					{bssid = "aa:bb:cc:dd:ee:ff", is_unifi = false},
					{bssid = "78:BB:C1:FE:3F:CB", is_unifi = true, serialno = "78:bb:c1:fe:3f:c9"},
				} end}
				local up2 = backhaul.uplink_report({backhaul_mode = "wireless", backhaul_parent = ""}, {}, uf, si)
				assert_eq(up2.uplink_mac, "78:bb:c1:fe:3f:c9", "parent from the scan table's serialno")
				local up3 = backhaul.uplink_report({backhaul_mode = "wireless", backhaul_parent = ""}, {}, uf,
					{scan_table = function() return {} end})
				assert_nil(up3.uplink_mac, "unknown parent stays absent, never guessed")
			end)
			with_seams({}, "Not connected.\n", function()
				local secs = {{name = "openuf_bh_ul_radio1", radio = "radio1", ssid = MESH.essid, disabled = false}}
				assert_nil(backhaul.uplink_report({backhaul_mode = "wireless"}, {}, fake_ufuci(secs, "phy1-sta0")),
					"not associated: nothing")
			end)
		end
	},
	{
		name = "backhaul: parent_for_bssid() prefers the controller's parent, then the sibling element, never a guess",
		fn = function()
			local si = {scan_table = function() return {
				{bssid = "aa:bb:cc:dd:ee:ff", is_unifi = false},
				{bssid = "7A:BB:C1:FE:3F:CB", is_unifi = true, serialno = "78:bb:c1:fe:3f:c9"},
			} end}
			assert_eq(backhaul.parent_for_bssid({backhaul_parent = "11:22:33:44:55:66"}, "7a:bb:c1:fe:3f:cb", "phy1-sta0", si),
				"11:22:33:44:55:66", "the controller's priority-1 parent wins")
			assert_eq(backhaul.parent_for_bssid({backhaul_parent = ""}, "7a:bb:c1:fe:3f:cb", "phy1-sta0", si),
				"78:bb:c1:fe:3f:c9", "else the sibling element's serialno, case-insensitively")
			assert_nil(backhaul.parent_for_bssid({backhaul_parent = ""}, "aa:bb:cc:dd:ee:ff", "phy1-sta0", si), "a non-sibling BSS: unknown")
			assert_nil(backhaul.parent_for_bssid({backhaul_parent = ""}, "7a:bb:c1:fe:3f:cb", nil, si), "no interface to scan from: unknown")
		end
	},
	{
		name = "backhaul: child_serialno() names the one sibling AP learnt behind a downlink station's netdev",
		fn = function()
			local scans = {{name = "radio1", scan_table = {
				{bssid = "aa:bb:cc:dd:ee:01", is_unifi = false},
				{bssid = "ac:10:07:6f:c6:71", is_unifi = true, serialno = "AC:10:07:6F:C6:70"},
				{bssid = "11:22:33:44:55:66", is_unifi = true, serialno = "11:22:33:44:55:60"},
			}}}
			local fdb = {["ac:10:07:6f:c6:70"] = "phy1-ap1.sta1", ["20:f1:b2:c5:c6:de"] = "phy1-ap1.sta1",
				["aa:10:07:6f:c6:72"] = "phy1-ap1.sta1", ["66:76:5b:ed:8c:a2"] = "phy1-ap0"}
			local si = {lan_bridge = function() return "br-lan" end, bridge_fdb_ports = function() return fdb end}
			assert_eq(backhaul.child_serialno("phy1-ap1.sta1", scans, {}, si), "ac:10:07:6f:c6:70",
				"the sibling whose identity MAC sits behind the station's netdev, lower-cased")
			assert_nil(backhaul.child_serialno("phy1-ap0", scans, {}, si), "a user VAP netdev: no sibling behind it")
			assert_nil(backhaul.child_serialno("phy1-ap1.sta1", {}, {}, si), "no siblings known: nothing")
			fdb["11:22:33:44:55:60"] = "phy1-ap1.sta1"
			assert_nil(backhaul.child_serialno("phy1-ap1.sta1", scans, {}, si), "two siblings behind one netdev (multi-hop): refuse to guess")
		end
	},
}
