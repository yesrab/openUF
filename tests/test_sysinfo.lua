-- Tests for openuf/sysinfo.lua (/proc and iw parsing).
-- Run from project root: lua tests/run_tests.lua

local sysinfo = dofile("openuf/sysinfo.lua")

-- Fixture file loader
local function fixture(name)
	local f = io.open("tests/fixtures/" .. name, "r")
	if not f then error("fixture not found: " .. name) end
	local s = f:read("*a"); f:close()
	return s
end

-- Inject fixture data for _read_file and _run_cmd
local function with_fixtures(file_map, cmd_map, fn)
	local orig_rf  = sysinfo._read_file
	local orig_cmd = sysinfo._run_cmd
	sysinfo._read_file = function(path)
		for k, v in pairs(file_map) do
			if path == k or path:find(k, 1, true) then return v end
		end
		return nil
	end
	sysinfo._run_cmd = function(cmd)
		for k, v in pairs(cmd_map or {}) do
			if cmd:find(k, 1, true) then return v end
		end
		return ""
	end
	local ok, err = pcall(fn)
	sysinfo._read_file = orig_rf
	sysinfo._run_cmd   = orig_cmd
	if not ok then error(err, 2) end
end

return {
	{
		name = "sysinfo: uptime() parses /proc/uptime correctly",
		fn = function()
			with_fixtures({["/proc/uptime"] = fixture("proc_uptime.txt")}, {}, function()
				local up = sysinfo.uptime()
				assert_eq(up, 12345, "uptime seconds (floor)")
			end)
		end
	},
	{
		name = "sysinfo: uptime() returns 0 when file missing",
		fn = function()
			with_fixtures({}, {}, function()
				assert_eq(sysinfo.uptime(), 0, "0 when missing")
			end)
		end
	},
	{
		name = "sysinfo: loadavg() parses /proc/loadavg correctly",
		fn = function()
			with_fixtures({["/proc/loadavg"] = fixture("proc_loadavg.txt")}, {}, function()
				local la = sysinfo.loadavg()
				assert_eq(la.one,     0.42, "1-min load")
				assert_eq(la.five,    0.31, "5-min load")
				assert_eq(la.fifteen, 0.19, "15-min load")
			end)
		end
	},
	{
		name = "sysinfo: meminfo() parses /proc/meminfo total and free",
		fn = function()
			with_fixtures({["/proc/meminfo"] = fixture("proc_meminfo.txt")}, {}, function()
				local m = sysinfo.meminfo()
				assert_eq(m.total_kb, 131072, "total_kb")
				assert_eq(m.free_kb,   65536, "free_kb")
			end)
		end
	},
	{
		name = "sysinfo: interfaces() parses /proc/net/dev rx_bytes and tx_bytes",
		fn = function()
			with_fixtures(
				{
					["/proc/net/dev"]    = fixture("proc_net_dev.txt"),
					["/sys/class/net/"]  = "",   -- no MAC, returns ""
				},
				{},
				function()
					local ifaces = sysinfo.interfaces()
					-- Should have lo, eth0, eth1
					assert_true(#ifaces >= 3, "at least 3 interfaces")
					local eth0
					for _, i in ipairs(ifaces) do
						if i.name == "eth0" then eth0 = i end
					end
					assert_not_nil(eth0, "eth0 found")
					assert_eq(eth0.rx_bytes,  9876543, "eth0 rx_bytes")
					assert_eq(eth0.tx_bytes,   654321, "eth0 tx_bytes")
					assert_eq(eth0.rx_packets,   5432, "eth0 rx_packets")
					assert_eq(eth0.tx_errors,       1, "eth0 tx_errors")
				end
			)
		end
	},
	{
		name = "sysinfo: sta_table() parses iw station dump output",
		fn = function()
			with_fixtures({}, {["station dump"] = fixture("iw_station_dump.txt")}, function()
				local stas = sysinfo.sta_table("wlan0")
				assert_eq(#stas, 2, "two clients")
				assert_eq(stas[1].mac,      "aa:bb:cc:dd:ee:ff", "first client MAC")
				assert_eq(stas[1].signal,   -62,                 "first client signal")
				assert_eq(stas[1].rx_bytes, 45678,               "first client rx_bytes")
				assert_eq(stas[1].tx_bytes, 98765,               "first client tx_bytes")
				assert_eq(stas[1].tx_retries, 4,                 "first client tx_retries")
				assert_eq(stas[1].tx_failed,  0,                 "first client tx_failed")
				assert_eq(stas[1].connected_sec, 3600,           "first client connected_sec")
				assert_eq(stas[1].tx_mcs, 15,                    "first client tx_mcs from 'MCS 15'")
				assert_eq(stas[1].rx_mcs, 7,                     "first client rx_mcs from 'MCS 7'")
				assert_eq(stas[2].mac,      "11:22:33:44:55:66", "second client MAC")
				assert_eq(stas[2].signal,   -75,                 "second client signal")
				assert_eq(stas[2].connected_sec, 42,              "second client connected_sec")
				assert_eq(stas[2].tx_mcs, 6,                      "second client tx_mcs from 'MCS 6'")
				assert_eq(stas[2].rx_mcs, 5,                      "second client rx_mcs from 'MCS 5'")
			end)
		end
	},
	{
		name = "sysinfo: sta_table() returns empty table for empty command output",
		fn = function()
			with_fixtures({}, {["station dump"] = ""}, function()
				local stas = sysinfo.sta_table("wlan0")
				assert_eq(#stas, 0, "empty when no output")
			end)
		end
	},
	{
		name = "sysinfo: radio_stats() parses survey dump in-use channel",
		fn = function()
			with_fixtures({}, {["survey dump"] = fixture("iw_survey_dump.txt")}, function()
				local stats = sysinfo.radio_stats("wlan0")
				-- Fixture has 2 frequency entries; the first is the in-use channel
				assert_true(#stats >= 1, "at least one entry")
				local active
				for _, s in ipairs(stats) do
					if s.freq == 2437 then active = s end
				end
				assert_not_nil(active, "2437 MHz entry found")
				assert_eq(active.noise,             -95,  "noise dBm")
				assert_eq(active.channel_time,      5000, "channel_time ms")
				assert_eq(active.channel_time_busy, 1850, "channel_time_busy ms")
				assert_eq(active.channel_time_rx,    900, "channel_time_rx ms")
				assert_eq(active.channel_time_tx,    450, "channel_time_tx ms")
			end)
		end
	},
	{
		name = "sysinfo: radio_stats() does not match 'extension channel busy time' as channel_time_busy",
		fn = function()
			-- Real iw(8) emits a separate "extension channel busy time:"
			-- field (secondary 20MHz segment of a wider channel) alongside
			-- "channel busy time:" -- an unanchored pattern match would
			-- wrongly pick up the extension field's value instead of (or as
			-- well as) the primary one, since "channel busy time:" is a
			-- literal substring of "extension channel busy time:".
			local dump = "Survey data from wlan0 (on operating channel):\n"
				.. "\tfrequency:\t\t\t2437 MHz [in use]\n"
				.. "\tchannel busy time:\t\t1850 ms\n"
				.. "\textension channel busy time:\t9999 ms\n"
			with_fixtures({}, {["survey dump"] = dump}, function()
				local stats = sysinfo.radio_stats("wlan0")
				assert_eq(stats[1].channel_time_busy, 1850,
					"picks the primary field, not the extension channel's value")
			end)
		end
	},
	{
		name = "sysinfo: radio_stats() returns empty table for empty output",
		fn = function()
			with_fixtures({}, {["survey dump"] = ""}, function()
				assert_eq(#sysinfo.radio_stats("wlan0"), 0, "empty result")
			end)
		end
	},
	{
		name = "sysinfo: radio_stats() returns empty table for nil ifname",
		fn = function()
			with_fixtures({}, {}, function()
				assert_eq(#sysinfo.radio_stats(nil), 0, "nil ifname safe")
			end)
		end
	},
	{
		name = "sysinfo: cpu_percent() returns 0 on the first call (no prior sample)",
		fn = function()
			local prev = sysinfo._prev_cpu
			sysinfo._prev_cpu = nil
			with_fixtures({["/proc/stat"] = fixture("proc_stat_1.txt")}, {}, function()
				assert_eq(sysinfo.cpu_percent(), 0, "no prior sample to diff against")
			end)
			sysinfo._prev_cpu = prev
		end
	},
	{
		name = "sysinfo: cpu_percent() computes delta-based usage between two samples",
		fn = function()
			local prev = sysinfo._prev_cpu
			sysinfo._prev_cpu = nil
			with_fixtures({["/proc/stat"] = fixture("proc_stat_1.txt")}, {}, function()
				sysinfo.cpu_percent()  -- prime the first sample
			end)
			with_fixtures({["/proc/stat"] = fixture("proc_stat_2.txt")}, {}, function()
				-- total delta = 200, idle delta = 100 -> 50% busy
				assert_eq(sysinfo.cpu_percent(), 50, "delta-based CPU percent")
			end)
			sysinfo._prev_cpu = prev
		end
	},
	{
		name = "sysinfo: cpu_percent() returns 0 when /proc/stat is unavailable",
		fn = function()
			local prev = sysinfo._prev_cpu
			sysinfo._prev_cpu = nil
			with_fixtures({}, {}, function()
				assert_eq(sysinfo.cpu_percent(), 0, "missing /proc/stat is safe")
			end)
			sysinfo._prev_cpu = prev
		end
	},
	{
		name = "sysinfo: mac_table() parses bridge fdb dynamic entries, joined with arp and dhcp leases",
		fn = function()
			sysinfo._mac_first_seen = {}
			with_fixtures(
				{
					["/proc/net/arp"]   = fixture("proc_net_arp.txt"),
					["/tmp/dhcp.leases"] = fixture("dhcp_leases.txt"),
				},
				{["bridge fdb show"] = fixture("bridge_fdb_dump.txt")},
				function()
					local hosts = sysinfo.mac_table("eth1")
					assert_eq(#hosts, 2, "two dynamically-learned hosts")
					assert_eq(hosts[1].mac, "aa:bb:cc:dd:ee:01", "first host mac")
					assert_eq(hosts[1].ip,  "192.168.1.50", "first host ip from arp")
					assert_eq(hosts[1].hostname, "laptop", "first host hostname from dhcp leases")
					assert_eq(hosts[2].mac, "aa:bb:cc:dd:ee:02", "second host mac")
					assert_eq(hosts[2].ip,  "192.168.1.51", "second host ip from arp")
					assert_true(hosts[2].hostname == nil, "second host has no lease entry -- hostname stays nil")
				end
			)
		end
	},
	{
		name = "sysinfo: mac_table() excludes self/permanent and multicast/broadcast fdb entries",
		fn = function()
			-- Fixture's self/permanent lines (the bridge's own MAC, an IPv4
			-- multicast group, and a broadcast address) must never surface as
			-- hosts -- only the two dynamically-learned "master br-lan" lines
			-- should (already asserted above); this pins the exclusion itself.
			sysinfo._mac_first_seen = {}
			with_fixtures({}, {["bridge fdb show"] = fixture("bridge_fdb_dump.txt")}, function()
				local hosts = sysinfo.mac_table("eth1")
				for _, h in ipairs(hosts) do
					assert_true(h.mac ~= "de:ad:be:ef:00:01", "self-permanent entry excluded")
					assert_true(h.mac ~= "33:33:00:00:00:01", "IPv6 multicast entry excluded")
					assert_true(h.mac ~= "01:00:5e:00:00:01", "IPv4 multicast entry excluded")
					assert_true(h.mac ~= "ff:ff:ff:ff:ff:ff", "broadcast entry excluded")
				end
			end)
		end
	},
	{
		name = "sysinfo: mac_table() returns empty table for nil ifname",
		fn = function()
			with_fixtures({}, {}, function()
				assert_eq(#sysinfo.mac_table(nil), 0, "nil ifname safe")
			end)
		end
	},
	{
		name = "sysinfo: mac_table() age is 0 and uptime grows across calls for the same host",
		fn = function()
			sysinfo._mac_first_seen = {}
			local orig_time = sysinfo._time
			sysinfo._time = function() return 1000 end
			with_fixtures({}, {["bridge fdb show"] = fixture("bridge_fdb_dump.txt")}, function()
				local hosts = sysinfo.mac_table("eth1")
				assert_eq(hosts[1].age, 0, "age is 0 -- freshly observed on this fdb dump")
				assert_eq(hosts[1].uptime, 0, "uptime 0 on first observation")
			end)
			sysinfo._time = function() return 1100 end
			with_fixtures({}, {["bridge fdb show"] = fixture("bridge_fdb_dump.txt")}, function()
				local hosts = sysinfo.mac_table("eth1")
				assert_eq(hosts[1].uptime, 100, "uptime grows from the first-seen cache")
			end)
			sysinfo._time = orig_time
			sysinfo._mac_first_seen = {}
		end
	},
	{
		name = "sysinfo: scan_table() parses iw scan dump into neighbor entries",
		fn = function()
			with_fixtures({}, {["scan dump"] = fixture("iw_scan_dump.txt")}, function()
				local nets = sysinfo.scan_table("wlan0")
				assert_eq(#nets, 2, "two neighbor networks")
				assert_eq(nets[1].bssid, "aa:bb:cc:dd:ee:01", "first bssid")
				assert_eq(nets[1].essid, "NeighborNet", "first essid")
				assert_eq(nets[1].freq, 2437, "first freq")
				assert_eq(nets[1].channel, 6, "first channel derived from freq")
				assert_eq(nets[1].signal, -55, "first signal")
				assert_eq(nets[1].security, "wpa2", "first security from RSN IE")
				assert_eq(nets[1].age, 0, "first age from '120 ms ago', floored to 0s")
				assert_eq(nets[1].bw, 40, "first bw parsed from 'BSS operating channel width: 40 MHz'")
				assert_eq(nets[2].bssid, "11:22:33:44:55:66", "second bssid")
				assert_eq(nets[2].essid, "OpenGuestWifi", "second essid")
				assert_eq(nets[2].channel, 11, "second channel derived from freq")
				assert_eq(nets[2].security, "open", "second security -- no Privacy, no RSN/WPA")
				assert_eq(nets[2].age, 0, "second age from '340 ms ago', floored to 0s")
				assert_eq(nets[2].bw, 20, "second bw defaults to 20 -- no width line for this BSS")
			end)
		end
	},
	{
		name = "sysinfo: scan_table() classifies Privacy-only (no RSN/WPA IE) as wep",
		fn = function()
			local dump = "BSS cc:cc:cc:cc:cc:cc(on wlan0)\n"
				.. "\tfreq: 2412\n"
				.. "\tcapability: ESS Privacy (0x0011)\n"
				.. "\tsignal: -60.00 dBm\n"
				.. "\tSSID: OldNetwork\n"
			with_fixtures({}, {["scan dump"] = dump}, function()
				local nets = sysinfo.scan_table("wlan0")
				assert_eq(nets[1].security, "wep", "Privacy bit with no RSN/WPA IE classified as wep")
			end)
		end
	},
	{
		name = "sysinfo: scan_table() converts 'last seen: N ms ago' to whole seconds",
		fn = function()
			local dump = "BSS dd:dd:dd:dd:dd:dd(on wlan0)\n"
				.. "\tfreq: 2412\n"
				.. "\tsignal: -60.00 dBm\n"
				.. "\tlast seen: 45231 ms ago\n"
				.. "\tSSID: StaleNetwork\n"
			with_fixtures({}, {["scan dump"] = dump}, function()
				local nets = sysinfo.scan_table("wlan0")
				assert_eq(nets[1].age, 45, "45231ms floors to 45s")
			end)
		end
	},
	{
		name = "sysinfo: scan_table() defaults age to 0 without a 'last seen' line",
		fn = function()
			local dump = "BSS ee:ee:ee:ee:ee:ee(on wlan0)\n"
				.. "\tfreq: 2412\n"
				.. "\tsignal: -60.00 dBm\n"
				.. "\tSSID: NoLastSeen\n"
			with_fixtures({}, {["scan dump"] = dump}, function()
				local nets = sysinfo.scan_table("wlan0")
				assert_eq(nets[1].age, 0, "age defaults to 0 when 'last seen' is absent")
			end)
		end
	},
	{
		name = "sysinfo: scan_table() returns empty table for empty output",
		fn = function()
			with_fixtures({}, {["scan dump"] = ""}, function()
				assert_eq(#sysinfo.scan_table("wlan0"), 0, "empty result")
			end)
		end
	},
	{
		name = "sysinfo: scan_table() returns empty table for nil ifname",
		fn = function()
			with_fixtures({}, {}, function()
				assert_eq(#sysinfo.scan_table(nil), 0, "nil ifname safe")
			end)
		end
	},
}
