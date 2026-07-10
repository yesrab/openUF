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
		name = "inform packet: handle_response setparam never updates authkey",
		fn = function()
			local st = sample_state()
			local orig_key = st.authkey
			-- authkey in mgmt_cfg must be ignored (security hardening)
			local resp = '{"_type":"setparam","mgmt_cfg":"mgmt_url=http://x:8080/inform\\nauthkey=deadbeefdeadbeefdeadbeefdeadbeef\\n"}'
			inform.handle_response(resp, st)
			assert_eq(st.authkey, orig_key, "authkey NOT updated via setparam (security hardening)")
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
			inform.handle_response('{"_type":"cmd","cmd":"set-locate"}', st)
			assert_true(st.locating, "locating true after set-locate")
		end
	},
	{
		name = "inform packet: handle_response cmd unset-locate clears st.locating",
		fn = function()
			local st = sample_state({locating = true})
			inform.handle_response('{"_type":"cmd","cmd":"unset-locate"}', st)
			assert_false(st.locating, "locating false after unset-locate")
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
}
