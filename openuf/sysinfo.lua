--[[
	System metrics reader for the inform JSON payload.

	All I/O functions are injectable via M._read_file and M._run_cmd so that
	unit tests can substitute fixture data without touching the real filesystem.
]]--

local M = {}

-- Injectable: override in tests to return fixture file contents
M._read_file = function(path)
	local f = io.open(path, "r")
	if not f then return nil end
	local s = f:read("*a")
	f:close()
	return s
end

-- Injectable: override in tests to return fixture command output
M._run_cmd = function(cmd)
	local h = io.popen(cmd .. " 2>/dev/null")
	if not h then return "" end
	local s = h:read("*a")
	h:close()
	return s or ""
end

-- Returns uptime in seconds (as a number) by parsing /proc/uptime.
function M.uptime()
	local s = M._read_file("/proc/uptime")
	if not s then return 0 end
	local secs = tonumber(s:match("^(%S+)"))
	return secs and math.floor(secs) or 0
end

-- Returns load averages as {one, five, fifteen} by parsing /proc/loadavg.
function M.loadavg()
	local s = M._read_file("/proc/loadavg")
	if not s then return {one = 0, five = 0, fifteen = 0} end
	local one, five, fifteen = s:match("^(%S+)%s+(%S+)%s+(%S+)")
	return {
		one     = tonumber(one)     or 0,
		five    = tonumber(five)    or 0,
		fifteen = tonumber(fifteen) or 0,
	}
end

-- Returns {total_kb, free_kb} by parsing /proc/meminfo.
function M.meminfo()
	local s = M._read_file("/proc/meminfo")
	if not s then return {total_kb = 0, free_kb = 0} end
	local total = tonumber(s:match("MemTotal:%s+(%d+)"))
	local free  = tonumber(s:match("MemFree:%s+(%d+)"))
	return {
		total_kb = total or 0,
		free_kb  = free  or 0,
	}
end

-- Previous /proc/stat sample for delta-based CPU% (see M.cpu_percent).
-- Exposed for tests to reset/inspect between calls.
M._prev_cpu = nil

-- Returns CPU usage percent (0-100) since the previous call, by delta-
-- sampling the aggregate "cpu" line in /proc/stat (matches the real
-- inform payload's system-stats.cpu, which is a live percentage -- not to
-- be confused with M.loadavg(), a different metric real devices don't
-- report under this field). Returns 0 on the first call, since there's no
-- prior sample to diff against yet.
function M.cpu_percent()
	local s = M._read_file("/proc/stat")
	if not s then return 0 end
	local cpu_line = s:match("^cpu%s+([^\n]+)")
	if not cpu_line then return 0 end

	local fields = {}
	for n in cpu_line:gmatch("%d+") do
		fields[#fields + 1] = tonumber(n)
	end
	if #fields < 4 then return 0 end

	-- Fields: user nice system idle iowait irq softirq [steal guest guest_nice]
	local idle = fields[4] + (fields[5] or 0)
	local total = 0
	for _, v in ipairs(fields) do total = total + v end

	local pct = 0
	if M._prev_cpu then
		local total_delta = total - M._prev_cpu.total
		local idle_delta  = idle  - M._prev_cpu.idle
		if total_delta > 0 then
			pct = math.floor((total_delta - idle_delta) * 100 / total_delta + 0.5)
		end
	end
	M._prev_cpu = {total = total, idle = idle}
	return pct
end

-- Returns a table of interface stats from /proc/net/dev.
-- Each entry: {name, rx_bytes, tx_bytes, rx_packets, tx_packets, rx_errors, tx_errors}
function M.interfaces()
	local s = M._read_file("/proc/net/dev")
	if not s then return {} end
	local ifaces = {}
	for line in s:gmatch("[^\n]+") do
		-- Skip header lines
		if line:find(":") then
			local name = line:match("^%s*(%S-):")
			local rx_bytes, rx_packets, rx_errors,
			      tx_bytes, tx_packets, tx_errors =
				line:match(":%s*(%d+)%s+(%d+)%s+(%d+)%s+%d+%s+%d+%s+%d+%s+%d+%s+%d+%s+"
				         .. "(%d+)%s+(%d+)%s+(%d+)")
			if name then
				local mac = ""
				local mac_raw = M._read_file("/sys/class/net/" .. name .. "/address")
				if mac_raw then mac = mac_raw:match("^([%x:]+)") or "" end
				ifaces[#ifaces + 1] = {
					name       = name,
					mac        = mac,
					rx_bytes   = tonumber(rx_bytes)   or 0,
					rx_packets = tonumber(rx_packets) or 0,
					rx_errors  = tonumber(rx_errors)  or 0,
					tx_bytes   = tonumber(tx_bytes)   or 0,
					tx_packets = tonumber(tx_packets) or 0,
					tx_errors  = tonumber(tx_errors)  or 0,
				}
			end
		end
	end
	return ifaces
end

-- Converts a WiFi frequency in MHz to its channel number (2.4/5/6GHz bands).
-- Returns nil for frequencies outside all three ranges.
function M.channel_from_freq(freq)
	freq = tonumber(freq)
	if not freq then return nil end
	if freq == 2484 then return 14 end
	if freq >= 2412 and freq <= 2472 then return math.floor((freq - 2407) / 5) end
	if freq >= 5955 and freq <= 7115 then return math.floor((freq - 5950) / 5) end
	if freq >= 5000 and freq <= 5895 then return math.floor((freq - 5000) / 5) end
	return nil
end

-- Returns per-radio channel utilisation from `iw dev <ifname> survey dump`.
-- Returns a table: {freq, noise, channel_time, channel_time_busy, channel_time_rx, channel_time_tx}
function M.radio_stats(ifname)
	if not ifname then return {} end
	local output = M._run_cmd("iw dev " .. ifname .. " survey dump")
	local result = {}
	local current = nil
	for line in output:gmatch("[^\n]+") do
		local freq = line:match("frequency:%s+(%d+)")
		if freq then
			if current then result[#result + 1] = current end
			current = {freq = tonumber(freq)}
		elseif current then
			-- Field names matched against the real iw(8) binary's own format
			-- strings ("channel active/busy/receive/transmit time:", not
			-- "channel time[/busy/rx/tx]:") -- confirmed via `strings
			-- /usr/sbin/iw`; the previous patterns never matched any real
			-- iw output on any hardware, so channel utilisation always
			-- silently reported 0%/absent regardless of actual airtime.
			-- Anchored to (whitespace-then-)start of line so "channel busy
			-- time:" doesn't also match inside the separate "extension
			-- channel busy time:" field iw emits on wider channels.
			local noise   = line:match("noise:%s+(-?%d+)")
			local ct      = line:match("^%s*channel active time:%s+(%d+)")
			local ct_busy = line:match("^%s*channel busy time:%s+(%d+)")
			local ct_rx   = line:match("^%s*channel receive time:%s+(%d+)")
			local ct_tx   = line:match("^%s*channel transmit time:%s+(%d+)")
			if noise   then current.noise              = tonumber(noise)   end
			if ct      then current.channel_time       = tonumber(ct)      end
			if ct_busy then current.channel_time_busy  = tonumber(ct_busy) end
			if ct_rx   then current.channel_time_rx    = tonumber(ct_rx)   end
			if ct_tx   then current.channel_time_tx    = tonumber(ct_tx)   end
		end
	end
	if current then result[#result + 1] = current end
	return result
end

-- Returns a table of connected stations from `iw dev <ifname> station dump`.
-- Each entry: {mac, signal, tx_bitrate, rx_bitrate, tx_mcs_index, tx_bytes,
--              rx_bytes, tx_packets, rx_packets, tx_retries, tx_failed,
--              inactive_ms, connected_sec}
-- tx_retries/tx_failed: iw(8) only exposes TX-side retry/failure counters
-- (802.11 ARQ is TX-side by nature) -- there is no rx-side equivalent in
-- `station dump` output, confirmed via `strings /usr/sbin/iw`.
function M.sta_table(ifname)
	if not ifname then return {} end
	local output = M._run_cmd("iw dev " .. ifname .. " station dump")
	local clients = {}
	local cur = nil
	for line in output:gmatch("[^\n]+") do
		local mac = line:match("^Station (%x%x:%x%x:%x%x:%x%x:%x%x:%x%x)")
		if mac then
			if cur then clients[#clients + 1] = cur end
			cur = {mac = mac}
		elseif cur then
			local signal     = line:match("signal:%s+(-?%d+)")
			local tx_rate    = line:match("tx bitrate:%s+(%S+)")
			local rx_rate    = line:match("rx bitrate:%s+(%S+)")
			-- tx_mcs: only present on the "tx bitrate" line itself, and only
			-- for 11n/ac/ax rates -- legacy (pre-MCS) rates have no "MCS N"
			-- suffix, so this stays nil for those, same as other optional
			-- fields below.
			local tx_mcs     = line:match("tx bitrate:.*MCS%s+(%d+)")
			local tx_bytes   = line:match("tx bytes:%s+(%d+)")
			local rx_bytes   = line:match("rx bytes:%s+(%d+)")
			local tx_pkts    = line:match("tx packets:%s+(%d+)")
			local rx_pkts    = line:match("rx packets:%s+(%d+)")
			local tx_retries = line:match("tx retries:%s+(%d+)")
			local tx_failed  = line:match("tx failed:%s+(%d+)")
			local inactive   = line:match("inactive time:%s+(%d+)")
			local connected  = line:match("connected time:%s+(%d+)")
			if signal    then cur.signal      = tonumber(signal)     end
			if tx_rate   then cur.tx_bitrate  = tonumber(tx_rate)    end
			if rx_rate   then cur.rx_bitrate  = tonumber(rx_rate)    end
			if tx_mcs    then cur.tx_mcs_index = tonumber(tx_mcs)    end
			if tx_bytes  then cur.tx_bytes    = tonumber(tx_bytes)   end
			if rx_bytes  then cur.rx_bytes    = tonumber(rx_bytes)   end
			if tx_pkts   then cur.tx_packets  = tonumber(tx_pkts)    end
			if rx_pkts   then cur.rx_packets  = tonumber(rx_pkts)    end
			if tx_retries then cur.tx_retries = tonumber(tx_retries) end
			if tx_failed  then cur.tx_failed  = tonumber(tx_failed)  end
			if inactive  then cur.inactive_ms = tonumber(inactive)   end
			if connected then cur.connected_sec = tonumber(connected) end
		end
	end
	if cur then clients[#clients + 1] = cur end
	return clients
end

return M
