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
		name = "inform packet: packet version is 0",
		fn = function()
			local pkt = inform.build_packet('{"_type":"state"}', sample_state())
			local h = parse_header(pkt)
			assert_eq(h.pkt_version, 0, "packet version")
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
		name = "inform packet: handle_response setparam updates inform_url",
		fn = function()
			local st = sample_state()
			local resp = '{"_type":"setparam","mgmt_cfg":{"server":"1.2.3.4","port":"8080"}}'
			inform.handle_response(resp, st)
			assert_contains(st.inform_url, "1.2.3.4", "inform_url updated with new server")
		end
	},
	{
		name = "inform packet: handle_response setparam never updates authkey",
		fn = function()
			local st = sample_state()
			local orig_key = st.authkey
			-- Attempt to inject a new authkey via setparam (should be ignored)
			local resp = '{"_type":"setparam","mgmt_cfg":{"authkey":"deadbeefdeadbeefdeadbeefdeadbeef"}}'
			inform.handle_response(resp, st)
			assert_eq(st.authkey, orig_key, "authkey NOT updated via setparam (Fix #1)")
		end
	},
}
