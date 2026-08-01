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
			-- Both sources must be stubbed. get_hostname reads
			-- /proc/sys/kernel/hostname first (OpenWrt has no `hostname`
			-- applet), and on any Linux host -- notably CI -- that file
			-- really exists, so stubbing only _popen tests nothing and the
			-- assertion fails against the runner's own hostname.
			local orig_popen, orig_read = announce._popen, announce._read_file
			announce._read_file = function() return nil end
			announce._popen = function() return "myap\n" end
			local got = announce.get_hostname()

			-- /proc wins when present, and is trimmed the same way.
			announce._read_file = function() return "procap\n" end
			local from_proc = announce.get_hostname()

			announce._popen, announce._read_file = orig_popen, orig_read
			assert_eq(got, "myap", "falls back to `hostname` when /proc has none")
			assert_eq(from_proc, "procap", "/proc/sys/kernel/hostname preferred")
		end
	},
	{
		name = "announce: get_hostname returns nil for empty or failed output",
		fn = function()
			-- Same reason as above: /proc must be stubbed away too, or a
			-- Linux host answers before the empty _popen is ever reached.
			local orig_popen, orig_read = announce._popen, announce._read_file
			announce._read_file = function() return nil end
			announce._popen = function() return "" end
			local empty = announce.get_hostname()
			announce._popen = function() return "   \n" end
			local blank = announce.get_hostname()
			announce._read_file = function() return "  \n" end
			announce._popen = function() return "" end
			local blank_proc = announce.get_hostname()
			announce._popen, announce._read_file = orig_popen, orig_read
			assert_nil(blank_proc, "whitespace-only /proc -> nil, not a blank hostname")
			assert_nil(empty, "empty output -> nil (caller falls back to openUF)")
			assert_nil(blank, "whitespace-only output -> nil")
		end
	},
	{
		name = "announce: get_hostname reads /proc, not just the `hostname` command",
		fn = function()
			-- OpenWrt builds do not necessarily ship a `hostname` applet --
			-- confirmed absent on a real Archer C5 running 25.12.5 -- and the
			-- command-only version then reported every such device to the
			-- controller as "openUF" rather than its real hostname.
			local orig_read, orig_popen = announce._read_file, announce._popen
			local popen_called = false
			announce._read_file = function(path)
				if path == "/proc/sys/kernel/hostname" then return "livingroom-ap\n" end
				return nil
			end
			announce._popen = function() popen_called = true; return "" end
			local got = announce.get_hostname()
			announce._read_file, announce._popen = orig_read, orig_popen
			assert_eq(got, "livingroom-ap", "hostname read from /proc and trimmed")
			assert_false(popen_called, "no process spawned when /proc answers")
		end
	},
	{
		name = "announce: get_hostname falls back to the command, then to nil",
		fn = function()
			local orig_read, orig_popen = announce._read_file, announce._popen
			announce._read_file = function() return nil end
			announce._popen = function() return "fallback-name\n" end
			local via_cmd = announce.get_hostname()
			announce._popen = function() return "" end
			local none = announce.get_hostname()
			announce._read_file, announce._popen = orig_read, orig_popen
			assert_eq(via_cmd, "fallback-name", "command used when /proc is unreadable")
			assert_nil(none, "neither source -> nil, caller falls back to openUF")
		end
	},
	{
		name = "announce: get_ip reads the address off the interface itself",
		fn = function()
			local orig, seen = announce._popen, {}
			announce._popen = function(cmd)
				seen[#seen + 1] = cmd
				if cmd:match("addr show dev eth1") then
					return "    inet 192.168.200.3/24 brd 192.168.200.255 scope global eth1\n"
				end
				return ""
			end
			local ip = announce.get_ip("eth1")
			announce._popen = orig
			assert_not_nil(ip, "address found")
			assert_eq(table.concat(ip, "."), "192.168.200.3", "octets parsed")
			assert_eq(#seen, 1, "no bridge lookup when the port has its own address")
		end
	},
	{
		name = "announce: get_ip falls back to the bridge when the port has no address",
		fn = function()
			-- The real target layout: lan_cpueth names eth1, but eth1 is a
			-- br-lan member and carries no address -- without the fallback,
			-- announce broadcasts 192.168.1.1 and inform reports "0.0.0.0".
			local orig = announce._popen
			announce._popen = function(cmd)
				if cmd:match("addr show dev eth1") then return "" end
				if cmd:match("readlink /sys/class/net/eth1/master") then
					return "../../../../../virtual/net/br-lan\n"
				end
				if cmd:match("addr show dev br%-lan") then
					return "    inet 192.168.200.3/24 brd 192.168.200.255 scope global br-lan\n"
				end
				return ""
			end
			local ip = announce.get_ip("eth1")
			announce._popen = orig
			assert_not_nil(ip, "bridge address found via master symlink")
			assert_eq(table.concat(ip, "."), "192.168.200.3", "bridge octets parsed")
		end
	},
	{
		name = "announce: get_ip follows a VLAN trunk through its tagged child to the bridge",
		fn = function()
			-- The normal swconfig layout: eth0 (trunk) -> eth0.1 (tagged) ->
			-- br-lan (address). lan_cpueth has to name the TRUNK so a pushed
			-- VLAN 20 becomes eth0.20 and not eth0.1.20 -- so the trunk itself
			-- is neither addressed nor bridged. Confirmed on a real
			-- TL-WDR3500, where this reported ip 0.0.0.0 on every inform.
			local orig = announce._popen
			announce._popen = function(cmd)
				if cmd:match("addr show dev eth0%.1") or cmd:match("addr show dev eth0 ") then
					return ""   -- neither the trunk nor the tagged child is addressed
				end
				if cmd:match("readlink /sys/class/net/eth0/master") then return "" end
				if cmd:match("ls %-d /sys/class/net/eth0%.") then
					return "/sys/class/net/eth0.1\n"
				end
				if cmd:match("readlink /sys/class/net/eth0%.1/master") then
					return "../../../../../virtual/net/br-lan\n"
				end
				if cmd:match("addr show dev br%-lan") then
					return "    inet 192.168.200.2/24 brd 192.168.200.255 scope global br-lan\n"
				end
				return ""
			end
			local ip = announce.get_ip("eth0")
			announce._popen = orig
			assert_not_nil(ip, "address found two hops away")
			assert_eq(table.concat(ip, "."), "192.168.200.2", "trunk -> tagged child -> bridge")
		end
	},
	{
		name = "announce: get_ip returns nil when neither port nor bridge has an address",
		fn = function()
			local orig = announce._popen
			announce._popen = function() return "" end
			local unbridged = announce.get_ip("eth1")
			announce._popen = function(cmd)
				if cmd:match("readlink") then
					return "../../../../../virtual/net/br-lan\n"
				end
				return ""
			end
			local bridged = announce.get_ip("eth1")
			announce._popen = orig
			assert_nil(unbridged, "no address and no bridge -> nil")
			assert_nil(bridged, "bridge exists but has no address -> nil")
		end
	},
}
