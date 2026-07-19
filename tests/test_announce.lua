-- Tests for openuf/announce.lua (packet building and length-field fix).
-- Run from project root: lua tests/run_tests.lua

OPENUF_TEST_MODE = true				-- suppress main loop
dofile("openuf/lib/lib.lua")		-- sets global ufpkt
local announce = dofile("openuf/announce.lua")

-- Minimal config for packet building (fixed values for deterministic tests)
local function sample_cfg(overrides)
	local cfg = {
		mac           = {0x24, 0xa4, 0x3c, 0x00, 0xd3, 0xad},
		ip            = {192, 168, 1, 1},
		hostname      = "openUF",
		platform      = "U6IW",
		fw_pre        = "U6IW.",
		fw_ver        = "6.6.55",
		fw_buildtime  = "230801.1200",
		fw_factoryver = "6.5.28",
		version_suffix = "-openUF-0.1",
		uptime        = 100,
		counter       = 1,
	}
	if overrides then
		for k, v in pairs(overrides) do cfg[k] = v end
	end
	return cfg
end

-- Parse a TLV from a binary string at the given byte offset (1-based).
-- Returns type (number), value (binary string), next_offset.
local function parse_tlv(pkt, offset)
	local tlv_type = string.byte(pkt, offset)
	local len_hi   = string.byte(pkt, offset + 1)
	local len_lo   = string.byte(pkt, offset + 2)
	local len      = len_hi * 256 + len_lo
	local value    = pkt:sub(offset + 3, offset + 3 + len - 1)
	return tlv_type, value, offset + 3 + len
end

-- Find a TLV of a given type in the packet body (starting at offset 5)
local function find_tlv(pkt, want_type)
	local offset = 5  -- skip 4-byte outer header
	while offset <= #pkt do
		local tlv_type, value, next = parse_tlv(pkt, offset)
		if tlv_type == want_type then return value end
		if next <= offset then break end  -- guard against infinite loop
		offset = next
	end
	return nil
end

return {
	{
		name = "announce: packet starts with 0x02 0x06 header",
		fn = function()
			local pkt = announce.build_packet(sample_cfg())
			assert_eq(string.byte(pkt, 1), 0x02, "byte 1 = 0x02")
			assert_eq(string.byte(pkt, 2), 0x06, "byte 2 = 0x06")
		end
	},
	{
		name = "announce: length field (bytes 3-4) encodes full 16-bit big-endian length",
		fn = function()
			local pkt = announce.build_packet(sample_cfg())
			local len_hi = string.byte(pkt, 3)
			local len_lo = string.byte(pkt, 4)
			local encoded_len = len_hi * 256 + len_lo
			-- Payload length is total minus the 4-byte header
			assert_eq(encoded_len, #pkt - 4, "encoded length matches actual payload")
		end
	},
	{
		name = "announce: length field high byte is actually used for a >= 256-byte payload",
		fn = function()
			-- The one test that genuinely guards the historical 2-byte-length
			-- regression. The default sample packet is ~154 bytes, so its high
			-- byte is legitimately 0 and the identity `hi*256+lo == #pkt-4`
			-- held even under the original low-byte-only bug -- the previous
			-- version of this test could never catch it. Force the payload
			-- past 256 with a long hostname and pin a NON-ZERO high byte.
			local pkt = announce.build_packet(sample_cfg({
				hostname = string.rep("a", 210),
			}))
			local payload_len = #pkt - 4
			assert_true(payload_len >= 256,
				"fixture sanity: payload crosses the 8-bit boundary (got " .. payload_len .. ")")
			local len_hi = string.byte(pkt, 3)
			local len_lo = string.byte(pkt, 4)
			assert_true(len_hi ~= 0, "high byte non-zero (the original bug zeroed it)")
			assert_eq(len_hi * 256 + len_lo, payload_len,
				"full 16-bit length correctly encoded")
		end
	},
	{
		name = "announce: TLV 0x02 (IP_ADDR) contains MAC then IP bytes",
		fn = function()
			local cfg = sample_cfg()
			local pkt = announce.build_packet(cfg)
			local val = find_tlv(pkt, 0x02)
			assert_not_nil(val, "TLV 0x02 present")
			assert_eq(#val, 10, "TLV 0x02 value = 6 MAC + 4 IP bytes")
			for i = 1, 6 do
				assert_eq(string.byte(val, i), cfg.mac[i], "MAC byte " .. i)
			end
			for i = 1, 4 do
				assert_eq(string.byte(val, 6 + i), cfg.ip[i], "IP byte " .. i)
			end
		end
	},
	{
		name = "announce: TLV 0x01 (HW_ADDR) contains the MAC",
		fn = function()
			local cfg = sample_cfg()
			local pkt = announce.build_packet(cfg)
			local val = find_tlv(pkt, 0x01)
			assert_not_nil(val, "TLV 0x01 present")
			assert_eq(#val, 6, "6-byte MAC")
			for i = 1, 6 do
				assert_eq(string.byte(val, i), cfg.mac[i], "MAC byte " .. i)
			end
		end
	},
	{
		name = "announce: TLV 0x0c (PLATFORM) contains the platform string",
		fn = function()
			local cfg = sample_cfg()
			local pkt = announce.build_packet(cfg)
			local val = find_tlv(pkt, 0x0c)
			assert_not_nil(val, "TLV 0x0c present")
			assert_eq(val, "U6IW", "platform string")
		end
	},
	{
		name = "announce: TLV 0x0b (HOSTNAME) contains the hostname",
		fn = function()
			local pkt = announce.build_packet(sample_cfg())
			local val = find_tlv(pkt, 0x0b)
			assert_not_nil(val, "TLV 0x0b present")
			assert_eq(val, "openUF", "hostname")
		end
	},
	{
		name = "announce: TLV 0x0a (UPTIME) is 4-byte big-endian",
		fn = function()
			local cfg = sample_cfg({uptime = 0x00012345})
			local pkt = announce.build_packet(cfg)
			local val = find_tlv(pkt, 0x0a)
			assert_not_nil(val, "TLV 0x0a present")
			assert_eq(#val, 4, "uptime is 4 bytes")
			assert_eq(string.byte(val, 1), 0x00, "uptime byte 1")
			assert_eq(string.byte(val, 2), 0x01, "uptime byte 2")
			assert_eq(string.byte(val, 3), 0x23, "uptime byte 3")
			assert_eq(string.byte(val, 4), 0x45, "uptime byte 4")
		end
	},
	{
		name = "announce: TLV 0x12 (counter) reflects the counter value",
		fn = function()
			local cfg = sample_cfg({counter = 7})
			local pkt = announce.build_packet(cfg)
			local val = find_tlv(pkt, 0x12)
			assert_not_nil(val, "TLV 0x12 present")
			assert_eq(#val, 4, "counter is 4 bytes")
			assert_eq(string.byte(val, 4), 7, "counter low byte = 7")
		end
	},
	{
		name = "announce: TLV 0x03 (FWVER_VERBOSE) contains platform prefix and version",
		fn = function()
			local pkt = announce.build_packet(sample_cfg())
			local val = find_tlv(pkt, 0x03)
			assert_not_nil(val, "TLV 0x03 present")
			assert_contains(val, "U6IW.", "fw prefix in verbose ver")
			assert_contains(val, "6.6.55", "fw version in verbose ver")
		end
	},
	{
		name = "announce: TLV 0x1b (FWVER_FACTORY) contains factory version string",
		fn = function()
			local pkt = announce.build_packet(sample_cfg())
			local val = find_tlv(pkt, 0x1b)
			assert_not_nil(val, "TLV 0x1b present")
			assert_eq(val, "6.5.28", "factory version string")
		end
	},
	{
		name = "announce: TLV 0x17 (IsDefault) is 1 when not adopted",
		fn = function()
			local pkt = announce.build_packet(sample_cfg({adopted = false}))
			local val = find_tlv(pkt, 0x17)
			assert_not_nil(val, "TLV 0x17 present")
			assert_eq(string.byte(val, 1), 0x01, "IsDefault=1 when not adopted")
		end
	},
	{
		name = "announce: TLV 0x17 (IsDefault) is 0 when adopted",
		fn = function()
			local pkt = announce.build_packet(sample_cfg({adopted = true}))
			local val = find_tlv(pkt, 0x17)
			assert_not_nil(val, "TLV 0x17 present")
			assert_eq(string.byte(val, 1), 0x00, "IsDefault=0 when adopted")
		end
	},
	{
		name = "announce: get_hostname returns the trimmed first line of `hostname`",
		fn = function()
			local orig = announce._popen
			announce._popen = function() return "myap\n" end
			local got = announce.get_hostname()
			announce._popen = orig
			assert_eq(got, "myap", "hostname read and trimmed")
		end
	},
	{
		name = "announce: get_hostname returns nil for empty or failed output",
		fn = function()
			local orig = announce._popen
			announce._popen = function() return "" end
			local empty = announce.get_hostname()
			announce._popen = function() return "   \n" end
			local blank = announce.get_hostname()
			announce._popen = orig
			assert_nil(empty, "empty output -> nil (caller falls back to openUF)")
			assert_nil(blank, "whitespace-only output -> nil")
		end
	},
}
