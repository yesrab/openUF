-- Tests for openuf/lib/lib.lua (TLV packet helpers).
-- Run from project root: lua tests/run_tests.lua

dofile("openuf/lib/lib.lua")	-- sets global ufpkt, requires "bit"

return {
	{
		name = "lib: gen4 converts 0x12345678 big-endian",
		fn = function()
			local t = ufpkt.gen4(0x12345678)
			assert_eq(#t, 4, "table length")
			assert_eq(t[1], 0x12, "byte 1 (MSB)")
			assert_eq(t[2], 0x34, "byte 2")
			assert_eq(t[3], 0x56, "byte 3")
			assert_eq(t[4], 0x78, "byte 4 (LSB)")
		end
	},
	{
		name = "lib: gen4 converts 256 (0x0100) correctly",
		fn = function()
			local t = ufpkt.gen4(256)
			assert_eq(t[1], 0x00, "byte 1")
			assert_eq(t[2], 0x00, "byte 2")
			assert_eq(t[3], 0x01, "byte 3")
			assert_eq(t[4], 0x00, "byte 4")
		end
	},
	{
		name = "lib: gen4 converts 0 to all-zero bytes",
		fn = function()
			local t = ufpkt.gen4(0)
			assert_eq(t[1], 0, "byte 1")
			assert_eq(t[2], 0, "byte 2")
			assert_eq(t[3], 0, "byte 3")
			assert_eq(t[4], 0, "byte 4")
		end
	},
	{
		name = "lib: gen4 converts 0xFFFFFFFF correctly",
		fn = function()
			local t = ufpkt.gen4(0xFFFFFFFF)
			assert_eq(t[1], 0xFF, "byte 1")
			assert_eq(t[2], 0xFF, "byte 2")
			assert_eq(t[3], 0xFF, "byte 3")
			assert_eq(t[4], 0xFF, "byte 4")
		end
	},
	{
		name = "lib: init creates 3-byte TLV header with correct type",
		fn = function()
			local t = ufpkt.init(0x0b)
			assert_eq(#t, 3, "table length")
			assert_eq(t[1], 0x0b, "type byte")
			assert_eq(t[2], 0x00, "length high byte (always 0)")
			assert_eq(t[3], 0x00, "length low byte (before finish)")
		end
	},
	{
		name = "lib: catstr appends string as individual bytes",
		fn = function()
			local t = {}
			ufpkt.catstr(t, "AB")
			assert_eq(#t, 2, "table length")
			assert_eq(t[1], 65, "byte value of 'A'")
			assert_eq(t[2], 66, "byte value of 'B'")
		end
	},
	{
		name = "lib: catstr appends empty string without error",
		fn = function()
			local t = {1, 2}
			ufpkt.catstr(t, "")
			assert_eq(#t, 2, "table unchanged")
		end
	},
	{
		name = "lib: cattbl appends source bytes to destination",
		fn = function()
			local dst = {0x01, 0x02}
			local src = {0x03, 0x04, 0x05}
			ufpkt.cattbl(dst, src)
			assert_eq(#dst, 5, "table length after append")
			assert_eq(dst[3], 0x03, "first appended byte")
			assert_eq(dst[4], 0x04, "second appended byte")
			assert_eq(dst[5], 0x05, "third appended byte")
		end
	},
	{
		name = "lib: finish sets length byte and appends TLV to outer packet",
		fn = function()
			local outer = {0x02, 0x06, 0x00, 0x00}
			local tlv = ufpkt.init(0x0b)		-- hostname TLV
			ufpkt.catstr(tlv, "test")			-- 4 bytes of value
			-- tlv is now {0x0b, 0x00, 0x00, 116, 101, 115, 116} (7 elements)
			ufpkt.finish(tlv, outer)
			-- finish sets tlv[3] = 7 - 3 = 4, then appends all 7 bytes to outer
			assert_eq(#outer, 4 + 7, "outer packet total length")
			assert_eq(outer[5], 0x0b, "TLV type in outer")
			assert_eq(outer[6], 0x00, "TLV length high byte")
			assert_eq(outer[7], 0x04, "TLV length low byte = 4")
			assert_eq(outer[8], 116, "first value byte 't'")
		end
	},
	{
		name = "lib: finish correctly encodes 6-byte value length",
		fn = function()
			local outer = {}
			local tlv = ufpkt.init(0x01)	-- HW addr TLV
			ufpkt.cattbl(tlv, {0x11, 0x22, 0x33, 0x44, 0x55, 0x66})
			ufpkt.finish(tlv, outer)
			-- value length should be 6
			assert_eq(outer[3], 0x06, "value length = 6")
		end
	},
}
