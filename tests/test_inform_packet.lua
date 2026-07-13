-- Tests for openuf/inform.lua (TNBU binary packet framing).
-- Run from project root: lua tests/run_tests.lua

OPENUF_TEST_MODE = true
dofile("openuf/lib/lib.lua")	-- needed by announce (loaded by inform)

local crypto = dofile("openuf/crypto.lua")
local state  = dofile("openuf/state.lua")
local inform = dofile("openuf/inform.lua")

-- Redirect state file to /tmp so handle_response tests don't need /etc/openuf
inform._state._state_file = "/tmp/openuf_test_inform.json"

-- Deterministic IV for reproducible packets
local FIXED_IV = string.rep("\0", 16)
crypto._random_bytes = function(n) return string.rep("\0", n) end

-- Minimal state for packet building
local function sample_state(overrides)
	local st = {
		authkey    = state.DEFAULT_KEY,
		adopted    = false,
		cfgversion = "",
		inform_url = "http://10.0.0.1:8080/inform",
		mac        = "aa:bb:cc:dd:ee:ff",
		ip         = "192.168.1.100",
		hostname   = "testap",
	}
	if overrides then
		for k, v in pairs(overrides) do st[k] = v end
	end
	return st
end

local MAGIC = "TNBU"

-- Parse header fields from a raw TNBU packet for assertions
local function parse_header(raw)
	local function u32(s, off)
		local b1,b2,b3,b4 = string.byte(s, off, off+3)
		return ((b1 or 0)*16777216) + ((b2 or 0)*65536) + ((b3 or 0)*256) + (b4 or 0)
	end
	local function u16(s, off)
		local hi, lo = string.byte(s, off, off+1)
		return (hi or 0)*256 + (lo or 0)
	end
	return {
		magic        = raw:sub(1, 4),
		pkt_version  = u32(raw, 5),
		mac          = raw:sub(9, 14),
		flags        = u16(raw, 15),
		iv           = raw:sub(17, 32),
		data_version = u32(raw, 33),
		payload_len  = u32(raw, 37),
		payload      = raw:sub(41),
	}
end

return {
	{
		name = "inform packet: magic is TNBU",
		fn = function()
			local st = sample_state()
			local pkt = inform.build_packet('{"_type":"state"}', st)
			local h = parse_header(pkt)
			assert_eq(h.magic, MAGIC, "magic bytes")
		end
	},
	{
		name = "inform packet: packet version is 1",
		fn = function()
			local pkt = inform.build_packet('{"_type":"state"}', sample_state())
			local h = parse_header(pkt)
			assert_eq(h.pkt_version, 1, "packet version")
		end
	},
	{
		name = "inform packet: data version is 1",
		fn = function()
			local pkt = inform.build_packet('{"_type":"state"}', sample_state())
			local h = parse_header(pkt)
			assert_eq(h.data_version, 1, "data version")
		end
	},
	{
		name = "inform packet: MAC bytes match state.mac",
		fn = function()
			local st = sample_state({mac = "aa:bb:cc:dd:ee:ff"})
			local pkt = inform.build_packet('{"_type":"state"}', st)
			local h = parse_header(pkt)
			assert_eq(string.byte(h.mac, 1), 0xaa, "MAC byte 1")
			assert_eq(string.byte(h.mac, 2), 0xbb, "MAC byte 2")
			assert_eq(string.byte(h.mac, 3), 0xcc, "MAC byte 3")
			assert_eq(string.byte(h.mac, 4), 0xdd, "MAC byte 4")
			assert_eq(string.byte(h.mac, 5), 0xee, "MAC byte 5")
			assert_eq(string.byte(h.mac, 6), 0xff, "MAC byte 6")
		end
	},
	{
		name = "inform packet: CBC flag 0x01 is set",
		fn = function()
			local pkt = inform.build_packet('{"_type":"state"}', sample_state())
			local h = parse_header(pkt)
			assert_true(h.flags % 2 ~= 0, "encrypted flag set")
		end
	},
	{
		name = "inform packet: IV field is 16 bytes in packet",
		fn = function()
			local pkt = inform.build_packet('{"_type":"state"}', sample_state())
			local h = parse_header(pkt)
			assert_eq(#h.iv, 16, "IV length in packet")
		end
	},
	{
		name = "inform packet: payload length field matches actual payload bytes",
		fn = function()
			local pkt = inform.build_packet('{"_type":"state"}', sample_state())
			local h = parse_header(pkt)
			assert_eq(h.payload_len, #h.payload, "payload_len matches actual payload")
		end
	},
	{
		name = "inform packet: total packet length is header (40) + payload",
		fn = function()
			local json = '{"_type":"state"}'
			local pkt = inform.build_packet(json, sample_state())
			local h = parse_header(pkt)
			assert_eq(#pkt, 40 + h.payload_len, "total length = 40 + payload_len")
		end
	},
	{
		name = "inform packet: round-trip build + parse returns original JSON",
		fn = function()
			local json = '{"_type":"state","x":42}'
			local st = sample_state()
			local pkt = inform.build_packet(json, st)
			local recovered, _ = inform.parse_packet(pkt, st)
			-- recovered may be the JSON directly (no compression on dev machine)
			-- or may differ slightly due to PKCS7 padding; check it contains key data
			assert_contains(recovered, '"_type"', "recovered contains _type")
			assert_contains(recovered, '"state"', "recovered contains state value")
		end
	},
	{
		name = "inform packet: parse raises error on wrong magic",
		fn = function()
			local st = sample_state()
			local pkt = inform.build_packet('{"_type":"state"}', st)
			-- Corrupt the magic
			local corrupted = "XXXX" .. pkt:sub(5)
			assert_error(function()
				inform.parse_packet(corrupted, st)
			end, "bad magic raises error")
		end
	},
	{
		name = "inform packet: parse raises error on short packet",
		fn = function()
			assert_error(function()
				inform.parse_packet("TNBU\0\0\0", sample_state())
			end, "short packet raises error")
		end
	},
	{
		name = "inform packet: different authkeys produce different ciphertext",
		fn = function()
			local json = '{"_type":"state"}'
			local st1 = sample_state({authkey = state.DEFAULT_KEY})
			local st2 = sample_state({authkey = "ffffffffffffffffffffffffffffffff"})
			local pkt1 = inform.build_packet(json, st1)
			local pkt2 = inform.build_packet(json, st2)
			-- Headers are the same; payloads differ
			assert_neq(pkt1:sub(41), pkt2:sub(41), "ciphertexts differ with different keys")
		end
	},
	{
		name = "inform packet: handle_response noop returns false",
		fn = function()
			local st = sample_state()
			local result = inform.handle_response('{"_type":"noop"}', st)
			assert_false(result, "noop returns false")
		end
	},
	{
		name = "inform packet: handle_response setparam updates inform_url from key=value string",
		fn = function()
			local st = sample_state()
			-- Real controller sends mgmt_cfg as newline-delimited key=value string.
			-- Use \\n so the Lua literal contains \n (JSON newline escape).
			local resp = '{"_type":"setparam","mgmt_cfg":"mgmt_url=http://1.2.3.4:8080/inform\\nuse_aes_gcm=false\\ncfgversion=2\\n"}'
			inform.handle_response(resp, st)
			assert_contains(st.inform_url, "1.2.3.4", "inform_url updated from mgmt_url")
		end
	},
	{
		name = "inform packet: handle_response setparam applies authkey and adopts when not yet adopted",
		fn = function()
			-- Real L3 adoption has no SSH step at all -- the controller delivers
			-- the new key via mgmt_cfg.authkey instead (confirmed against
			-- amd989/unifi-gateway and live testing; see PROTOCOL-VALIDATION.md).
			local st = sample_state({adopted = false})
			local resp = '{"_type":"setparam","mgmt_cfg":"mgmt_url=http://x:8080/inform\\nauthkey=deadbeefdeadbeefdeadbeefdeadbeef\\n"}'
			local result = inform.handle_response(resp, st)
			assert_eq(st.authkey, "deadbeefdeadbeefdeadbeefdeadbeef", "authkey updated from mgmt_cfg")
			assert_true(st.adopted, "adopted set to true")
			assert_true(result, "re-inform triggered immediately with the new key")
		end
	},
	{
		name = "inform packet: handle_response setparam ignores authkey once already adopted",
		fn = function()
			-- Once adopted, only SSH set-adopt may rotate the key -- matches
			-- real L2 hardware behavior and preserves the original security
			-- invariant for already-adopted devices.
			local st = sample_state({adopted = true})
			local orig_key = st.authkey
			local resp = '{"_type":"setparam","mgmt_cfg":"mgmt_url=http://x:8080/inform\\nauthkey=deadbeefdeadbeefdeadbeefdeadbeef\\n"}'
			inform.handle_response(resp, st)
			assert_eq(st.authkey, orig_key, "authkey NOT updated via setparam once adopted")
		end
	},
	{
		name = "inform packet: handle_response setparam ignores malformed authkey",
		fn = function()
			local st = sample_state({adopted = false})
			local orig_key = st.authkey
			local resp = '{"_type":"setparam","mgmt_cfg":"mgmt_url=http://x:8080/inform\\nauthkey=not-32-hex-chars\\n"}'
			inform.handle_response(resp, st)
			assert_eq(st.authkey, orig_key, "malformed authkey rejected, key unchanged")
			assert_false(st.adopted, "not marked adopted on malformed authkey")
		end
	},
	{
		name = "inform packet: handle_response setparam sets use_gcm from mgmt_cfg",
		fn = function()
			local st = sample_state()
			assert_false(st.use_gcm or false, "use_gcm starts false")
			local resp = '{"_type":"setparam","mgmt_cfg":"mgmt_url=http://x:8080/inform\\nuse_aes_gcm=true\\n"}'
			inform.handle_response(resp, st)
			assert_true(st.use_gcm, "use_gcm set to true from mgmt_cfg")
		end
	},
	{
		name = "inform packet: handle_response setparam sets st.led_enabled from mgmt_cfg",
		fn = function()
			local st = sample_state()
			local resp = '{"_type":"setparam","mgmt_cfg":"mgmt_url=http://x:8080/inform\\nled_enabled=false\\n"}'
			inform.handle_response(resp, st)
			assert_false(st.led_enabled, "led_enabled set to false from mgmt_cfg")
		end
	},
	{
		name = "inform packet: handle_response setparam led_enabled drives led.set_enabled",
		fn = function()
			local st = sample_state()
			local writes = {}
			local orig = inform._led._write_file
			inform._led._write_file = function(path, contents)
				writes[#writes + 1] = {path = path, contents = contents}
				return true
			end
			local cfg = {led = "/sys/class/leds/test"}
			local resp = '{"_type":"setparam","mgmt_cfg":"mgmt_url=http://x:8080/inform\\nled_enabled=false\\n"}'
			inform.handle_response(resp, st, cfg)
			inform._led._write_file = orig
			assert_eq(#writes, 2, "two sysfs writes")
			assert_eq(writes[2].path, "/sys/class/leds/test/brightness", "brightness path")
			assert_eq(writes[2].contents, "0", "brightness off for led_enabled=false")
		end
	},
	{
		name = "inform packet: handle_response setparam applies static IP from system_cfg",
		fn = function()
			local st = sample_state()
			local cmds = {}
			local orig = inform._netconfig._exec
			inform._netconfig._exec = function(cmd)
				cmds[#cmds + 1] = cmd
				return true
			end
			local cfg = {net = {lan_cpueth = "eth0"}}
			-- Real captured shape (PROTOCOL-VALIDATION.md): system_cfg is a
			-- flat OpenWrt-UCI-style blob, separate from mgmt_cfg. Static is
			-- signalled by the ABSENCE of dhcpc.1.* keys, not an explicit flag.
			local resp = '{"_type":"setparam","system_cfg":"netconf.1.ip=172.19.0.50\\n'
				.. 'netconf.1.netmask=255.255.255.0\\nroute.1.gateway=172.19.0.1\\n"}'
			inform.handle_response(resp, st, cfg)
			inform._netconfig._exec = orig
			assert_eq(st.ip_mode, "static", "ip_mode recorded as static")
			assert_eq(st.static_ip, "172.19.0.50", "static_ip recorded")
			assert_eq(st.static_gateway, "172.19.0.1", "static_gateway recorded")
			assert_eq(st.ip, "172.19.0.50", "st.ip synced to the new static address")
			assert_eq(#cmds, 3, "three shell commands (flush, add, route)")
			assert_contains(cmds[2], "172.19.0.50/24 dev eth0", "correct interface and address")
		end
	},
	{
		name = "inform packet: handle_response setparam applies dhcp from system_cfg",
		fn = function()
			local st = sample_state({ip_mode = "static", static_ip = "172.19.0.50"})
			local cmds = {}
			local orig = inform._netconfig._exec
			inform._netconfig._exec = function(cmd)
				cmds[#cmds + 1] = cmd
				return true
			end
			local cfg = {net = {lan_cpueth = "eth0"}}
			local resp = '{"_type":"setparam","system_cfg":"netconf.1.ip=172.19.0.2\\n'
				.. 'dhcpc.1.status=enabled\\ndhcpc.1.devname=br0\\n"}'
			inform.handle_response(resp, st, cfg)
			inform._netconfig._exec = orig
			assert_eq(st.ip_mode, "dhcp", "ip_mode recorded as dhcp")
			assert_eq(st.static_ip, nil, "static_ip cleared on dhcp")
			assert_contains(cmds[2], "udhcpc -i eth0", "udhcpc invoked on the right interface")
		end
	},
	{
		name = "inform packet: handle_response setparam does NOT flush dhcp on first contact",
		fn = function()
			-- A fresh device's very first system_cfg (and every steady-state
			-- reaffirmation) also carries dhcpc.1.status=enabled, but there's
			-- no prior static config to revert -- calling apply_dhcp here
			-- would needlessly (and, without a real DHCP server to grant a
			-- new lease, destructively) flush a working address. Confirmed
			-- live: this exact scenario stranded the validation container.
			local st = sample_state()  -- ip_mode starts nil, never "static"
			local cmds = {}
			local orig = inform._netconfig._exec
			inform._netconfig._exec = function(cmd)
				cmds[#cmds + 1] = cmd
				return true
			end
			local cfg = {net = {lan_cpueth = "eth0"}}
			local resp = '{"_type":"setparam","system_cfg":"netconf.1.ip=172.19.0.2\\n'
				.. 'dhcpc.1.status=enabled\\ndhcpc.1.devname=br0\\n"}'
			inform.handle_response(resp, st, cfg)
			inform._netconfig._exec = orig
			assert_eq(st.ip_mode, "dhcp", "ip_mode still recorded as dhcp")
			assert_eq(#cmds, 0, "apply_dhcp NOT called -- nothing to revert")
		end
	},
	{
		name = "inform packet: handle_response setparam ignores system_cfg without cfg.net",
		fn = function()
			-- Same nil-safety convention as cfg.led -- absent per-model
			-- interface config means a safe no-op, not an error.
			local st = sample_state()
			local resp = '{"_type":"setparam","system_cfg":"netconf.1.ip=172.19.0.50\\n"}'
			local ok = pcall(inform.handle_response, resp, st, nil)
			assert_true(ok, "no error without cfg")
		end
	},
	{
		name = "inform packet: _parse_wifi_system_cfg extracts vap_table and radio_table from a real captured blob",
		fn = function()
			-- Real captured shape (PROTOCOL-VALIDATION.md section 3): WiFi
			-- config arrives as flat aaa.<n>.*/wireless.<n>.*/radio.<n>.*
			-- keys, not resp.vap_table/radio_table JSON.
			local sys_cfg = "radio.1.phyname=radio0\nradio.1.channel=auto\nradio.1.txpower=auto\n"
				.. "radio.2.phyname=radio1\nradio.2.channel=36\nradio.2.txpower=17\n"
				.. "aaa.1.ssid=openuf-test\naaa.1.wpa=2\naaa.1.wpa.psk=TestPass123\n"
				.. "aaa.1.wpa.key.1.mgmt=WPA-PSK\naaa.1.ft.status=disabled\n"
				.. "aaa.1.id=6a540dd2ffb26b8537ec967d\n"
				.. "wireless.1.ssid=openuf-test\nwireless.1.parent=radio0\nwireless.1.security=none\n"
			local radio_table, vap_table = inform._parse_wifi_system_cfg(sys_cfg)

			assert_eq(#radio_table, 2, "two radios parsed")
			assert_eq(radio_table[1].name, "radio0", "radio 1 name from phyname")
			assert_eq(radio_table[1].channel, nil, "auto channel left unset")
			assert_eq(radio_table[2].name, "radio1", "radio 2 name from phyname")
			assert_eq(radio_table[2].channel, 36, "explicit channel parsed as a number")
			assert_eq(radio_table[2].tx_power, 17, "explicit tx_power parsed as a number")

			assert_eq(#vap_table, 1, "one vap parsed (only wireless.1.* present)")
			assert_eq(vap_table[1].ssid, "openuf-test", "ssid from wireless.1.ssid")
			assert_eq(vap_table[1].radio, "radio0", "radio from wireless.1.parent")
			assert_eq(vap_table[1].security, "wpa2", "security derived from aaa.1.wpa=2")
			assert_eq(vap_table[1].x_passphrase, "TestPass123", "passphrase from aaa.1.wpa.psk")
			assert_eq(vap_table[1].wlanconf_id, "6a540dd2ffb26b8537ec967d",
				"wlanconf id from aaa.1.id (echoed back as vap_table[].id; without it the controller drops the vap)")
			assert_eq(vap_table[1].fast_roaming_enabled, false, "ft.status=disabled -> fast roaming off")
			assert_eq(vap_table[1].vlan_enabled, false, "no br.devname suffix -> vlan not enabled")
			assert_eq(vap_table[1].vlan, nil, "no vlan id without a tagged br.devname")
		end
	},
	{
		name = "inform packet: _parse_wifi_system_cfg extracts VLAN id from a tagged br.devname",
		fn = function()
			-- Real captured shape (PROTOCOL-VALIDATION.md section 4): assigning
			-- a WiFi network to a VLAN-tagged network changes aaa.<n>.br.devname
			-- from "br0" to "br0.<vlan>" -- the only field that carries the
			-- VLAN id in this wire format (no separate vap->network join).
			local sys_cfg = "aaa.1.ssid=openuf-test\naaa.1.wpa=2\naaa.1.wpa.psk=TestPass123\n"
				.. "aaa.1.br.devname=br0.20\n"
				.. "wireless.1.ssid=openuf-test\nwireless.1.parent=radio0\n"
			local _, vap_table = inform._parse_wifi_system_cfg(sys_cfg)
			assert_eq(#vap_table, 1, "one vap parsed")
			assert_eq(vap_table[1].vlan_enabled, true, "tagged br.devname enables vlan")
			assert_eq(vap_table[1].vlan, 20, "vlan id parsed from br0.20")
		end
	},
	{
		name = "inform packet: handle_response setparam applies WiFi config from system_cfg via ucihelper",
		fn = function()
			local st = sample_state()
			local applied_resp, applied_cfg
			inform._ucihelper = {
				apply_config = function(resp, cfg)
					applied_resp, applied_cfg = resp, cfg
				end,
			}
			local cfg = {net = {lan_cpueth = "eth0"}}
			local sys_cfg = "radio.1.phyname=radio0\nradio.1.channel=6\nradio.1.txpower=20\n"
				.. "aaa.1.ssid=openuf-test\naaa.1.wpa=2\naaa.1.wpa.psk=TestPass123\n"
				.. "wireless.1.ssid=openuf-test\nwireless.1.parent=radio0\n"
			local resp = ('{"_type":"setparam","system_cfg":"%s"}'):format(sys_cfg:gsub("\n", "\\n"))
			inform.handle_response(resp, st, cfg)
			inform._ucihelper = nil
			assert_true(applied_resp ~= nil, "ucihelper.apply_config was called")
			assert_eq(#applied_resp.vap_table, 1, "one vap passed through")
			assert_eq(applied_resp.vap_table[1].ssid, "openuf-test", "ssid passed through")
			assert_eq(applied_cfg, cfg, "cfg passed through unchanged")
		end
	},
	{
		name = "inform packet: handle_response setparam skips ucihelper.apply_config when system_cfg has no WiFi keys",
		fn = function()
			local st = sample_state()
			local called = false
			inform._ucihelper = {
				apply_config = function() called = true end,
			}
			local cfg = {net = {lan_cpueth = "eth0"}}
			local resp = '{"_type":"setparam","system_cfg":"netconf.1.ip=172.19.0.2\\ndhcpc.1.status=enabled\\n"}'
			inform.handle_response(resp, st, cfg)
			inform._ucihelper = nil
			assert_false(called, "apply_config not called without any aaa./wireless./radio. keys")
		end
	},
	{
		name = "inform packet: handle_response setdefault resets state",
		fn = function()
			local st = sample_state({
				authkey  = "aabbccddeeff00112233445566778899",
				adopted  = true,
				use_gcm  = true,
			})
			inform.handle_response('{"_type":"setdefault"}', st)
			assert_false(st.adopted,  "adopted reset to false")
			assert_false(st.use_gcm, "use_gcm reset to false")
			assert_eq(st.authkey, state.DEFAULT_KEY, "authkey reset to default")
		end
	},
	{
		name = "inform packet: handle_response setdefault preserves mac/ip/hostname",
		fn = function()
			-- mac/ip/hostname are populated once at M.run() startup and never
			-- persisted to state.json -- a factory reset must not wipe the
			-- device's live-detected identity mid-run.
			local st = sample_state({adopted = true})
			inform.handle_response('{"_type":"setdefault"}', st)
			assert_eq(st.mac,      "aa:bb:cc:dd:ee:ff", "mac preserved across reset")
			assert_eq(st.ip,       "192.168.1.100",     "ip preserved across reset")
			assert_eq(st.hostname, "testap",            "hostname preserved across reset")
		end
	},
	{
		name = "inform packet: handle_response setdefault unlocks bootstrap account when configured",
		fn = function()
			local st = sample_state({adopted = true})
			local calls = {}
			local orig = inform._run_cmd
			inform._run_cmd = function(cmd) calls[#calls + 1] = cmd; return "" end
			inform.handle_response('{"_type":"setdefault"}', st, {config = {bootstrap_adopt_user = "ubnt"}})
			inform._run_cmd = orig
			assert_eq(#calls, 1, "exactly one passwd command issued")
			assert_contains(calls[1], "passwd -u", "unlock command issued")
			assert_contains(calls[1], "ubnt", "unlock command targets ubnt")
		end
	},
	{
		name = "inform packet: handle_response setdefault does nothing when bootstrap account not configured",
		fn = function()
			local st = sample_state({adopted = true})
			local calls = {}
			local orig = inform._run_cmd
			inform._run_cmd = function(cmd) calls[#calls + 1] = cmd; return "" end
			inform.handle_response('{"_type":"setdefault"}', st, {config = {}})
			inform._run_cmd = orig
			assert_eq(#calls, 0, "no passwd command issued when bootstrap_adopt_user unset")
		end
	},
	{
		name = "inform packet: handle_response upgrade stores version/url only",
		fn = function()
			local st = sample_state()
			local resp = '{"_type":"upgrade","version":"6.6.99","url":"http://unifi/fw.bin"}'
			local result = inform.handle_response(resp, st)
			assert_eq(st.upgrade_requested_version, "6.6.99", "version stored")
			assert_eq(st.upgrade_requested_url, "http://unifi/fw.bin", "url stored")
			assert_false(result, "upgrade does not trigger a follow-up inform")
		end
	},
	{
		name = "inform packet: handle_response upgrade never flashes/reboots",
		fn = function()
			-- state.save() legitimately calls os.execute("mkdir -p ...") --
			-- what must NEVER happen is a sysupgrade/reboot/download command.
			local st = sample_state()
			local orig_execute = os.execute
			local commands = {}
			os.execute = function(cmd, ...)
				commands[#commands + 1] = cmd
				return orig_execute(cmd, ...)
			end
			local ok = pcall(inform.handle_response,
				'{"_type":"upgrade","version":"6.6.99","url":"http://unifi/fw.bin"}', st)
			os.execute = orig_execute
			assert_true(ok, "handle_response did not error")
			for _, cmd in ipairs(commands) do
				assert_true(type(cmd) == "string", "command is a string")
				assert_false(cmd:find("sysupgrade") ~= nil, "no sysupgrade: " .. cmd)
				assert_false(cmd:find("reboot") ~= nil, "no reboot: " .. cmd)
				assert_false(cmd:find("wget") ~= nil or cmd:find("curl") ~= nil,
					"no download command: " .. cmd)
			end
		end
	},
	{
		name = "inform packet: handle_response cmd set-locate sets st.locating",
		fn = function()
			local st = sample_state()
			local result = inform.handle_response('{"_type":"cmd","cmd":"set-locate"}', st)
			assert_true(st.locating, "locating true after set-locate")
			assert_true(result, "re-inform immediately after executing a command (fxkr protocol notes)")
		end
	},
	{
		name = "inform packet: handle_response cmd unset-locate clears st.locating",
		fn = function()
			local st = sample_state({locating = true})
			local result = inform.handle_response('{"_type":"cmd","cmd":"unset-locate"}', st)
			assert_false(st.locating, "locating false after unset-locate")
			assert_true(result, "re-inform immediately after executing a command")
		end
	},
	{
		name = "inform packet: handle_response cmd re-informs immediately even for unhandled commands",
		fn = function()
			local st = sample_state()
			local result = inform.handle_response('{"_type":"cmd","cmd":"mfi-output"}', st)
			assert_true(result, "re-inform immediately regardless of which command was received")
		end
	},
	{
		name = "inform packet: handle_response cmd spectrum-scan builds spectrum_table from survey dump",
		fn = function()
			local st = sample_state()
			inform._spectrum_cache = {}
			inform._ucihelper = {
				get_radio_table = function()
					return { { name = "radio0", channel = "6", ht = "HT40" } }
				end,
				get_ifname_for_radio = function() return "wlan0" end,
				_popen = function() return "" end,
			}
			inform._sysinfo.radio_stats = function()
				return {
					{ freq = 2437, noise = -95, channel_time = 5000, channel_time_busy = 1850 },
					{ freq = 2412, noise = -90, channel_time = 100,  channel_time_busy = 12 },
				}
			end

			local result = inform.handle_response('{"_type":"cmd","cmd":"spectrum-scan"}', st)
			assert_true(result, "re-inform immediately after executing a command")

			local cached = inform._spectrum_cache.radio0
			assert_true(cached ~= nil, "spectrum-scan cmd populates _spectrum_cache for the radio")
			assert_true(#cached.table == 2, "one spectrum_table entry per survey-dump frequency")
			assert_true(cached.table[1].channel == 6, "channel derived from 2437MHz")
			assert_true(cached.table[1].center_freq == 2437, "center_freq passed through from survey dump")
			assert_true(cached.table[1].width == 40, "width derived from radio's HT40 htmode")
			assert_true(cached.table[1].utilization == 37, "utilization = channel_time_busy/channel_time * 100")
			assert_true(cached.table[1].interference == -95, "interference is best-effort noise-floor passthrough")
		end
	},
	{
		name = "inform: _populate_net_info does not trigger announce.lua's self-executing entry point outside test mode",
		fn = function()
			-- Regression test: _populate_net_info dofile()s announce.lua to
			-- reuse get_mac/get_ip. Outside of test mode, announce.lua's own
			-- bottom "script entry point" block would otherwise fire (it's
			-- only guarded by `if not OPENUF_TEST_MODE`), spawning an
			-- infinite broadcast loop nested inside the caller, or calling
			-- os.exit(1) on this test process if the broadcast send errors --
			-- either way this test would visibly hang or the whole suite
			-- would abort if the suppression regresses.
			local prev = OPENUF_TEST_MODE
			OPENUF_TEST_MODE = nil  -- simulate real (non-test) execution
			local st = {}
			local ok = pcall(inform._populate_net_info, st, nil)
			local restored = OPENUF_TEST_MODE
			OPENUF_TEST_MODE = prev
			assert_true(ok, "_populate_net_info did not error/exit with OPENUF_TEST_MODE unset")
			assert_true(restored == nil, "OPENUF_TEST_MODE restored to its prior (unset) value after the call")
		end
	},
	{
		name = "inform packet: handle_response dumps raw JSON when debug_dump_file set",
		fn = function()
			local st = sample_state()
			local path = "/tmp/openuf_test_dump.log"
			os.remove(path)
			local cfg = { config = { debug_dump_file = path } }
			inform.handle_response('{"_type":"noop"}', st, cfg)
			local f = io.open(path, "r")
			assert_true(f ~= nil, "dump file was created")
			local contents = f:read("*a")
			f:close()
			os.remove(path)
			assert_true(contents:find('{"_type":"noop"}', 1, true) ~= nil,
				"dump file contains the raw response JSON")
		end
	},
	{
		name = "inform packet: handle_response does not dump when debug_dump_file unset",
		fn = function()
			local st = sample_state()
			local path = "/tmp/openuf_test_dump_unset.log"
			os.remove(path)
			inform.handle_response('{"_type":"noop"}', st, { config = {} })
			local f = io.open(path, "r")
			assert_true(f == nil, "no dump file created when flag is unset")
		end
	},
	{
		name = "inform packet: parse_packet inflates a zlib-compressed response",
		fn = function()
			-- OpenWrt 25.12 has no Lua zlib binding, so this exercises the in-tree
			-- pure-Lua inflater on the parse path. The fixture is a real zlib stream
			-- (tests/fixtures/zlib_response.bin) whose plaintext is asserted below.
			-- The mgmt_cfg newlines are JSON-escaped (\n), so the decompressed bytes
			-- contain literal backslash-n, written here as \\n.
			local expected = '{"_type":"setparam","mgmt_cfg":"mgmt_url=http://unifi:8080/inform\\n'
				.. 'use_aes_gcm=false\\ncfgversion=7\\n","note":"padding to ensure zlib actually '
				.. 'shrinks this payload below its original size aaaaaaaaaaaaaaaaaaaa"}'
			local ff = io.open("tests/fixtures/zlib_response.bin", "rb")
			assert_not_nil(ff, "fixture present")
			local compressed = ff:read("*a"); ff:close()

			local st = sample_state()
			-- Encrypt the compressed bytes exactly as a controller would, then frame.
			local iv = FIXED_IV
			local ct = crypto.aes_cbc_encrypt(st.authkey, iv, compressed)
			local FLAG_ENCRYPTED, FLAG_COMPRESSED = 0x01, 0x02
			local flags = FLAG_ENCRYPTED + FLAG_COMPRESSED
			local function u32(n)
				return string.char(math.floor(n/16777216)%256, math.floor(n/65536)%256,
					math.floor(n/256)%256, n%256)
			end
			local pkt = MAGIC .. u32(1) .. "\170\187\204\221\238\255"
				.. string.char(math.floor(flags/256), flags%256)
				.. iv .. u32(1) .. u32(#ct) .. ct
			local recovered = inform.parse_packet(pkt, st)
			assert_eq(recovered, expected, "compressed response inflated to original JSON")
		end
	},
	{
		name = "inform packet: parse_packet errors on snappy-compressed response",
		fn = function()
			-- Build a raw packet with FLAG_SNAPPY (0x04) set
			local FLAG_SNAPPY = 0x04
			local st = sample_state()
			local pkt = inform.build_packet('{"_type":"state"}', st)
			-- Patch byte 15-16 (flags, big-endian) to set FLAG_SNAPPY
			local flags_byte = string.byte(pkt, 15) * 256 + string.byte(pkt, 16)
			flags_byte = flags_byte + FLAG_SNAPPY
			local patched = pkt:sub(1, 14)
				.. string.char(math.floor(flags_byte / 256))
				.. string.char(flags_byte % 256)
				.. pkt:sub(17)
			assert_error(function()
				inform.parse_packet(patched, st)
			end, "snappy flag raises error")
		end
	},
	{
		name = "inform: _state_mtime parses stat output as a number",
		fn = function()
			local orig = inform._run_cmd
			inform._run_cmd = function(cmd) return "1700000000\n" end
			local mtime = inform._state_mtime("/tmp/whatever")
			inform._run_cmd = orig
			assert_eq(mtime, 1700000000, "mtime parsed as number")
		end
	},
	{
		name = "inform: _state_mtime returns nil when stat yields no output",
		fn = function()
			local orig = inform._run_cmd
			inform._run_cmd = function(cmd) return "" end
			local mtime = inform._state_mtime("/nonexistent")
			inform._run_cmd = orig
			assert_true(mtime == nil, "nil when file missing")
		end
	},
	{
		name = "inform: _sync_bootstrap_account is a no-op without a configured user",
		fn = function()
			local calls = {}
			local orig = inform._run_cmd
			inform._run_cmd = function(cmd) calls[#calls + 1] = cmd; return "" end
			inform._sync_bootstrap_account(true, nil)
			inform._run_cmd = orig
			assert_eq(#calls, 0, "no shell-out without a configured user")
		end
	},
	{
		name = "inform: _sync_bootstrap_account locks the account when adopted",
		fn = function()
			local calls = {}
			local orig = inform._run_cmd
			inform._run_cmd = function(cmd) calls[#calls + 1] = cmd; return "" end
			inform._sync_bootstrap_account(true, "ubnt")
			inform._run_cmd = orig
			assert_eq(#calls, 1, "one command issued")
			assert_contains(calls[1], "passwd -l", "lock command issued")
			assert_contains(calls[1], "ubnt", "targets ubnt")
		end
	},
	{
		name = "inform: _sync_bootstrap_account unlocks the account when not adopted",
		fn = function()
			local calls = {}
			local orig = inform._run_cmd
			inform._run_cmd = function(cmd) calls[#calls + 1] = cmd; return "" end
			inform._sync_bootstrap_account(false, "ubnt")
			inform._run_cmd = orig
			assert_eq(#calls, 1, "one command issued")
			assert_contains(calls[1], "passwd -u", "unlock command issued")
		end
	},
	{
		name = "inform: _reload_if_changed is a no-op when mtime is unchanged",
		fn = function()
			local orig_mtime = inform._state_mtime
			inform._state_mtime = function(path) return 42 end
			local st = sample_state({adopted = false})
			local last = inform._reload_if_changed(st, {config = {}}, 42)
			inform._state_mtime = orig_mtime
			assert_eq(last, 42, "mtime unchanged")
			assert_eq(st.mac, "aa:bb:cc:dd:ee:ff", "st left untouched")
		end
	},
	{
		name = "inform: _reload_if_changed reloads state and preserves mac/ip/hostname when mtime changes",
		fn = function()
			-- Write a real fixture to the redirected state file, distinct
			-- from sample_state()'s in-memory values, so a genuine
			-- state.load() picks it up -- exercises the real disk round-trip
			-- rather than mocking state.load itself. Must go through
			-- inform._state (not the test file's own `state` local) --
			-- dofile never caches, so those are separate module instances
			-- and only inform._state._state_file was redirected above.
			inform._state.save({
				authkey    = "11112222333344445555666677778888",
				adopted    = true,
				cfgversion = "abc123",
				inform_url = "http://controller/inform",
				use_gcm    = true,
				upgrade_requested_version = "",
				upgrade_requested_url     = "",
			})

			local orig_mtime = inform._state_mtime
			inform._state_mtime = function(path) return 100 end

			local calls = {}
			local orig_run = inform._run_cmd
			inform._run_cmd = function(cmd) calls[#calls + 1] = cmd; return "" end

			local st = sample_state({adopted = false})
			local last = inform._reload_if_changed(
				st, {config = {bootstrap_adopt_user = "ubnt"}}, 1)

			inform._state_mtime = orig_mtime
			inform._run_cmd = orig_run

			assert_eq(last, 100, "returns new mtime")
			assert_true(st.adopted, "adopted reloaded from disk")
			assert_eq(st.authkey, "11112222333344445555666677778888",
				"authkey reloaded from disk")
			assert_eq(st.cfgversion, "abc123", "cfgversion reloaded from disk")
			assert_eq(st.mac,      "aa:bb:cc:dd:ee:ff", "mac preserved across reload")
			assert_eq(st.ip,       "192.168.1.100",     "ip preserved across reload")
			assert_eq(st.hostname, "testap",            "hostname preserved across reload")
			assert_eq(#calls, 1, "bootstrap account synced")
			assert_contains(calls[1], "passwd -l",
				"locked since reloaded state is adopted")
		end
	},
}
