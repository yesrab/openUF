--[[
	UniFi inform protocol client.

	Sends encrypted JSON payloads to the controller via HTTP POST every 10
	seconds (the standard UniFi heartbeat interval).  Parses and dispatches
	the controller's response.

	Binary packet format (TNBU, "UBNT" reversed):
	  Offset  Len  Field
	   0       4   Magic: 0x54 0x4E 0x42 0x55 ("TNBU")
	   4       4   Packet version (uint32 BE) — always 0
	   8       6   Device MAC
	  14       2   Flags (uint16 BE):
	               0x01 = payload encrypted (AES-128-CBC or GCM)
	               0x02 = payload zlib-compressed
	               0x08 = use AES-128-GCM instead of CBC (requires 0x01)
	  16      16   AES IV
	  32       4   Data version (uint32 BE) — always 1 (= JSON payload)
	  36       4   Payload length (uint32 BE)
	  40+      *   Payload (may be compressed then encrypted)
]]--

local bit = (function()
	local ok, b = pcall(require, "bit")
	if ok then return b end
	ok, b = pcall(require, "bit32")
	if ok then return b end
	local _l = load or loadstring
	local function _f(e) return _l("return function(a,b) return "..e.." end")() end
	return {
		band   = _f("a&b"),
		bor    = _l("return function(...) local r=0 for i=1,select('#',...)do r=r|select(i,...)end return r end")(),
		bxor   = _f("a~b"),
		lshift = _f("a<<b"),
		rshift = _f("a>>b"),
	}
end)()
-- socket is lazy-loaded inside http_post/run so the module can be required
-- in test environments that do not have luasocket installed.
local cjson  = require("cjson")

-- Load sibling modules (relative paths for when run from openuf/ dir or installed)
local function _require_sibling(name)
	local paths = {name .. ".lua", "openuf/" .. name .. ".lua"}
	for _, p in ipairs(paths) do
		local f = io.open(p, "r")
		if f then f:close(); return dofile(p) end
	end
	error("cannot find module: " .. name)
end

local crypto    = _require_sibling("crypto")
local state     = _require_sibling("state")
local sysinfo   = _require_sibling("sysinfo")
local lldp      = _require_sibling("lldp")
local ucihelper = _require_sibling("ucihelper")
local led       = _require_sibling("led")
local netconfig = _require_sibling("netconfig")

local M = {}

-- Injectable: expose internal modules so tests can inject fixtures
M._state     = state
M._sysinfo   = sysinfo
M._ucihelper = ucihelper
M._lldp      = lldp
M._led       = led
M._netconfig = netconfig

-- In-memory only (not persisted to state.json): per-radio spectrum-scan
-- results, keyed by radio name. Ephemeral live data, same category as
-- radio_stats()/sta_table() which are also recomputed rather than stored.
M._spectrum_cache = {}

-- In-memory only: previous {rx_bytes, tx_bytes, time} sample per client MAC,
-- used to delta-sample a throughput estimate the same way M._sysinfo's
-- cpu_percent() delta-samples /proc/stat between calls (first sample for a
-- given MAC has no prior delta, so throughput is reported as 0 that time).
M._sta_stats_cache = {}

-- Injectable: override in tests to control elapsed time deterministically
-- (used by the sta_table throughput delta-sample below).
M._time = os.time

-- Injectable: override in tests to return fixture command output
M._run_cmd = function(cmd)
	local h = io.popen(cmd .. " 2>/dev/null")
	if not h then return "" end
	local s = h:read("*a")
	h:close()
	return s or ""
end

-- Returns the mtime (seconds since epoch, as a number) of path, or nil if
-- it can't be stat'd (missing, permission denied, stat unavailable, ...).
function M._state_mtime(path)
	local out = M._run_cmd("stat -c %Y '" .. path .. "'")
	local n = tonumber((out:gsub("%s+$", "")))
	return n
end

-- Locks or unlocks the temporary SSH bootstrap account (see conf.lua's
-- bootstrap_adopt_user and USAGE.md's SSH prerequisite section) to match
-- the device's current adopted state. No-op if user is nil/false (feature
-- not enabled). Idempotent -- locking an already-locked account (or
-- unlocking an already-unlocked one) is a harmless no-op on BusyBox/shadow
-- passwd, so callers never need to track prior state themselves.
function M._sync_bootstrap_account(adopted, user)
	if not user then return end
	if adopted then
		M._run_cmd("passwd -l '" .. user .. "'")
	else
		M._run_cmd("passwd -u '" .. user .. "'")
	end
end

-- Packet constants
local MAGIC        = "TNBU"
local PKT_VERSION  = 1   -- confirmed by amd989/unifi-gateway and fxkr reverse-engineering
local DATA_VERSION = 1

-- Inform flags
local FLAG_ENCRYPTED  = 0x01
local FLAG_COMPRESSED = 0x02
local FLAG_SNAPPY     = 0x04  -- Snappy compression (amd989 prefers it; we send zlib only)
local FLAG_GCM        = 0x08

-- Injectable: override in tests to skip real HTTP
M._http_post = nil

-- ─── Binary helpers ───────────────────────────────────────────────────────────

local function uint32_be(n)
	return string.char(
		bit.band(bit.rshift(n, 24), 0xFF),
		bit.band(bit.rshift(n, 16), 0xFF),
		bit.band(bit.rshift(n,  8), 0xFF),
		bit.band(n,                 0xFF)
	)
end

local function uint16_be(n)
	return string.char(
		bit.band(bit.rshift(n, 8), 0xFF),
		bit.band(n,                0xFF)
	)
end

local function parse_uint32_be(s, offset)
	local b1, b2, b3, b4 = string.byte(s, offset, offset + 3)
	return bit.bor(
		bit.lshift(b1 or 0, 24),
		bit.lshift(b2 or 0, 16),
		bit.lshift(b3 or 0,  8),
		          (b4 or 0)
	)
end

local function parse_uint16_be(s, offset)
	local hi, lo = string.byte(s, offset, offset + 1)
	return (hi or 0) * 256 + (lo or 0)
end

local function mac_bytes(mac_str)
	-- "aa:bb:cc:dd:ee:ff" → 6-byte binary string
	local bytes = {}
	for h in mac_str:gmatch("[0-9a-fA-F]+") do
		bytes[#bytes + 1] = string.char(tonumber(h, 16))
	end
	if #bytes ~= 6 then error("mac_bytes: invalid MAC: " .. tostring(mac_str)) end
	return table.concat(bytes)
end

-- 32 hex chars = 16 bytes = a valid AES-128 key (matches syswrapper.lua's check)
local function is_hex32(s)
	return type(s) == "string" and #s == 32 and s:match("^[0-9a-fA-F]+$") ~= nil
end

-- ─── Packet builder ──────────────────────────────────────────────────────────

-- Build a TNBU binary packet from a JSON string.
-- st: state table (authkey, mac, use_gcm)
-- GCM AAD = first 40 bytes of the packet header (per amd989/unifi-gateway encode_inform)
function M.build_packet(json_str, st)
	local use_gcm = st.use_gcm and crypto.gcm_available()
	local payload = json_str

	-- Compress with zlib if available
	local flags = FLAG_ENCRYPTED
	local ok_zlib, zlib = pcall(require, "zlib")
	if ok_zlib and zlib.compress then
		local compressed = zlib.compress(payload)
		if compressed and #compressed < #payload then
			payload = compressed
			flags = bit.bor(flags, FLAG_COMPRESSED)
		end
	end
	if use_gcm then flags = bit.bor(flags, FLAG_GCM) end

	local iv      = crypto.random_iv(16)
	local mac_bin = mac_bytes(st.mac or "00:00:00:00:00:00")

	-- 36-byte fixed prefix (before payload_len field)
	local prefix = MAGIC
		.. uint32_be(PKT_VERSION)
		.. mac_bin
		.. uint16_be(flags)
		.. iv
		.. uint32_be(DATA_VERSION)

	local ciphertext
	if use_gcm then
		-- GCM: payload len = compressed len + 16-byte tag; assemble full 40-byte AAD first
		local aad = prefix .. uint32_be(#payload + 16)
		local ct, tag = crypto.aes_gcm_encrypt(st.authkey, iv, payload, aad)
		ciphertext = ct .. tag
		return aad .. ciphertext
	else
		ciphertext = crypto.aes_cbc_encrypt(st.authkey, iv, payload)
		return prefix .. uint32_be(#ciphertext) .. ciphertext
	end
end

-- ─── Packet parser ───────────────────────────────────────────────────────────

-- Parse and decrypt a TNBU binary packet.
-- Returns json_str, flags.  Raises on magic mismatch or decryption failure.
function M.parse_packet(raw, st)
	if #raw < 40 then
		error("inform: packet too short (" .. #raw .. " bytes)")
	end

	local magic = raw:sub(1, 4)
	if magic ~= MAGIC then
		error("inform: bad magic: " .. magic:gsub(".", function(c)
			return string.format("\\x%02x", string.byte(c))
		end))
	end

	-- pkt_version = parse_uint32_be(raw, 5)  -- currently unused
	-- mac         = raw:sub(9, 14)            -- currently unused
	local flags      = parse_uint16_be(raw, 15)
	local iv         = raw:sub(17, 32)
	-- data_version = parse_uint32_be(raw, 33) -- currently unused
	local payload_len = parse_uint32_be(raw, 37)
	local payload     = raw:sub(41, 40 + payload_len)

	if #payload < payload_len then
		error("inform: truncated payload")
	end

	-- Decrypt
	if bit.band(flags, FLAG_ENCRYPTED) ~= 0 then
		local key = st.authkey
		if bit.band(flags, FLAG_GCM) ~= 0 then
			-- AAD = full 40-byte packet header (per amd989/unifi-gateway decode_inform)
			local aad = raw:sub(1, 40)
			local ct  = payload:sub(1, #payload - 16)
			local tag = payload:sub(#payload - 15)
			payload = crypto.aes_gcm_decrypt(key, iv, ct, tag, aad)
		else
			payload = crypto.aes_cbc_decrypt(key, iv, payload)
		end
	end

	-- Decompress — Snappy (0x04) is not supported; zlib (0x02) is.
	if bit.band(flags, FLAG_SNAPPY) ~= 0 then
		error("inform: controller sent snappy-compressed response; lua-snappy not supported")
	end
	if bit.band(flags, FLAG_COMPRESSED) ~= 0 then
		local done = false
		-- Prefer a native zlib binding if the host happens to have one...
		local ok_zlib, zlib = pcall(require, "zlib")
		if ok_zlib and type(zlib) == "table" and zlib.decompress then
			local ok_d, out = pcall(zlib.decompress, payload)
			if ok_d and out then payload = out; done = true end
		end
		-- ...otherwise fall back to the in-tree pure-Lua inflater (OpenWrt 25.12
		-- ships no Lua zlib binding, so this is the normal path there).
		if not done then
			local inflate = _require_sibling("inflate")
			payload = inflate.zlib_decompress(payload)
		end
	end

	return payload, flags
end

-- ─── JSON payload builder ────────────────────────────────────────────────────

-- Build the inform JSON payload.
-- st: current state table
-- cfg: device configuration (from conf.lua)
-- ufhw: ufmodel table
function M.build_json(st, cfg, ufhw)
	local uap = ufhw and ufhw.uap or {}

	-- Collect sysinfo
	local uptime     = M._sysinfo.uptime()
	local meminfo    = M._sysinfo.meminfo()
	local cpu_pct    = M._sysinfo.cpu_percent()
	local mem_pct    = meminfo.total_kb > 0
	                    and math.floor((meminfo.total_kb - meminfo.free_kb) * 100 / meminfo.total_kb + 0.5)
	                    or 0
	local ifaces    = M._sysinfo.interfaces()
	local lldp_nbrs = M._lldp.neighbors()

	-- Build if_table
	local if_table = {}
	for _, iface in ipairs(ifaces) do
		if_table[#if_table + 1] = {
			name        = iface.name,
			mac         = iface.mac,
			rx_bytes    = iface.rx_bytes,
			tx_bytes    = iface.tx_bytes,
			rx_packets  = iface.rx_packets,
			tx_packets  = iface.tx_packets,
			rx_errors   = iface.rx_errors,
			tx_errors   = iface.tx_errors,
		}
	end

	-- radio_table and vap_table require UCI (not available in test context)
	local radio_table       = {}
	local radio_table_stats = {}
	local vap_table         = {}

	local mac_str = st.mac or "00:00:00:00:00:00"

	-- ufuci: VAP/radio info (require("uci") calls inside it can legitimately
	-- fail off-target, so individual calls are still pcall-wrapped below)
	local ufuci = M._ucihelper
	if ufuci and ufuci.get_vap_table then
		local ok_v, rv = pcall(ufuci.get_vap_table)
		if ok_v then vap_table = rv end
		local ok_r, rr = pcall(ufuci.get_radio_table)
		if ok_r then radio_table = rr end

		-- Live per-radio channel utilization, parallel to radio_table (matches
		-- real UniFi's split of static config vs. live stats).
		for _, radio in ipairs(radio_table) do
			local ok_if, ifname = pcall(ufuci.get_ifname_for_radio, radio.name)
			if ok_if and ifname then
				local ok_rs, stats = pcall(M._sysinfo.radio_stats, ifname)
				if ok_rs and stats[1] then
					local s     = stats[1]  -- in-use channel's survey entry
					local total = s.channel_time or 0
					local busy  = s.channel_time_busy or 0
					local entry = {
						name        = radio.name,
						channel     = radio.channel,
						cu_total    = total > 0 and math.floor(busy * 100 / total) or 0,
						cu_self_rx  = total > 0 and math.floor((s.channel_time_rx or 0) * 100 / total) or 0,
						cu_self_tx  = total > 0 and math.floor((s.channel_time_tx or 0) * 100 / total) or 0,
					}
					-- Cached spectrum-scan result, if a "spectrum-scan" cmd
					-- was handled for this radio (see cmd dispatch below).
					-- NOTE: spectrum_scanning/spectrum_scan_timestamp are
					-- device-level (top-level payload) fields, not per-radio
					-- -- confirmed against the real controller's own device
					-- schema, which has them at the top level while
					-- spectrum_table/spectrum_table_time are the per-radio
					-- fields (see PROTOCOL-VALIDATION.md section 8).
					local sscan = M._spectrum_cache[radio.name]
					if sscan then
						entry.spectrum_table      = sscan.table
						entry.spectrum_table_time = sscan.table_time
					end
					radio_table_stats[#radio_table_stats + 1] = entry
				end
			end
		end

		-- Live connected-client counts, nested per-vap as sta_table -- matches
		-- the real controller's vap-stats DTO, which nests connected clients
		-- inside each vap_table entry rather than a flat top-level table
		-- (confirmed against unifi-network-application:10.4.57's own
		-- bytecode; see PROTOCOL-VALIDATION.md "Stage 2c").
		local now = M._time()
		for _, vap in ipairs(vap_table) do
			-- get_ifname_for_radio() resolves a UCI radio device name
			-- ("radio0"/"radio1"), not the band vap.radio now reports
			-- ("ng"/"na") -- using vap.radio here always missed, silently
			-- leaving sta_table empty on every inform (no fake/real client
			-- ever appeared in a vap's sta_table, regardless of the id/
			-- wlanconf_id fix that lets vap_table itself through at all).
			local ok_if, ifname = pcall(ufuci.get_ifname_for_radio, vap.radio_name)
			local stas = {}
			if ok_if and ifname then
				local ok_sta, rv2 = pcall(M._sysinfo.sta_table, ifname)
				if ok_sta then stas = rv2 end
			end
			vap.num_sta = #stas
			-- Per-VAP traffic/retry counters ("Air Stats" in the controller
			-- UI) -- confirmed real field names via the decompiled vap-stats
			-- DTO (cVbZoFIZsWYaVCquTr$QCtdvLKOBb): rx_bytes/rx_packets/
			-- tx_bytes/tx_packets/tx_retries/tx_dropped, aggregated here by
			-- summing each connected station's own counters (iw(8) doesn't
			-- expose a single already-aggregated per-radio/per-VAP counter,
			-- only per-station ones). rx_dropped/rx_errors/tx_errors/
			-- satisfaction have no source data anywhere in iw's output (ARQ
			-- retry/failure counters are inherently TX-side only) -- left
			-- unset rather than invented, matching sta_table's existing
			-- linkscore/multicast precedent.
			local vap_rx_bytes, vap_tx_bytes = 0, 0
			local vap_rx_packets, vap_tx_packets = 0, 0
			local vap_tx_retries, vap_tx_dropped = 0, 0
			local sta_table = {}
			for _, sta in ipairs(stas) do
				vap_rx_bytes    = vap_rx_bytes    + (sta.rx_bytes or 0)
				vap_tx_bytes    = vap_tx_bytes    + (sta.tx_bytes or 0)
				vap_rx_packets  = vap_rx_packets  + (sta.rx_packets or 0)
				vap_tx_packets  = vap_tx_packets  + (sta.tx_packets or 0)
				vap_tx_retries  = vap_tx_retries  + (sta.tx_retries or 0)
				vap_tx_dropped  = vap_tx_dropped  + (sta.tx_failed or 0)
				-- throughput: delta-sampled byte rate (bytes/sec), same
				-- approach as M._sysinfo.cpu_percent()'s /proc/stat delta
				-- sampling -- 0 on the first sample for a given MAC, since
				-- there's no prior sample to diff against yet.
				local throughput = 0
				local prev = M._sta_stats_cache[sta.mac]
				if prev then
					local dt = now - prev.time
					if dt > 0 then
						throughput = math.floor(
							((sta.rx_bytes or 0) - prev.rx_bytes + (sta.tx_bytes or 0) - prev.tx_bytes) / dt
						)
					end
				end
				M._sta_stats_cache[sta.mac] = {
					rx_bytes = sta.rx_bytes or 0,
					tx_bytes = sta.tx_bytes or 0,
					time     = now,
				}

				sta_table[#sta_table + 1] = {
					active     = true,
					mac        = sta.mac,
					ap_mac     = mac_str,
					channel    = vap.channel,
					radio      = vap.radio,
					signal     = sta.signal,
					rssi       = sta.signal,
					-- capacity: best-effort proxy from the negotiated PHY tx
					-- rate (Mbps). linkscore/multicast: no local source
					-- exists at all (not in iw output, not in any public
					-- reference checked) -- placeholders, not measurements.
					capacity   = sta.tx_bitrate and math.floor(sta.tx_bitrate) or 0,
					throughput = throughput,
					linkscore  = 0,
					multicast  = 0,
					-- Cumulative per-client counters -- confirmed real field
					-- names via the decompiled vapInformProcessor
					-- (com.ubnt.service.devmgr.c.KHUkYjHujLgFBD), which
					-- copies exactly these names off each incoming sta_table
					-- entry ("channel","radio","name","signal","rssi",
					-- "tx_rate","rx_rate","tx_packets","rx_packets",
					-- "tx_bytes","rx_bytes") and computes its own bytes-d/
					-- rate-d deltas between informs -- so unlike throughput
					-- above, these must be sent as raw cumulative counters,
					-- not pre-computed rates.
					rx_bytes   = sta.rx_bytes or 0,
					tx_bytes   = sta.tx_bytes or 0,
					rx_packets = sta.rx_packets or 0,
					tx_packets = sta.tx_packets or 0,
					-- tx_rate/rx_rate: controller's tx_rate/rx_rate are in
					-- Kbps (matches real-device captures, e.g. tx_rate:
					-- 39000 for a 39 Mbps MCS rate); iw reports Mbit/s.
					tx_rate    = sta.tx_bitrate and math.floor(sta.tx_bitrate * 1000) or 0,
					rx_rate    = sta.rx_bitrate and math.floor(sta.rx_bitrate * 1000) or 0,
					-- uptime/idletime: iw's "connected time"/"inactive time"
					-- are the same concepts: seconds associated, seconds
					-- since last activity. Only set uptime when iw actually
					-- reports connected time (older iw builds omit it).
					uptime     = sta.connected_sec,
					idletime   = sta.inactive_ms and math.floor(sta.inactive_ms / 1000) or nil,
					-- tx_mcs_index: confirmed real field, part of the same
					-- controller-side wifi-experience-score input DTO
					-- (com.ubnt.g.q.AQODNNoMmBlFpWXX) as rx_rate/tx_rate/
					-- signal above. iw's tx bitrate line already prints this
					-- ("144.4 MBit/s MCS 15 short GI"); only set when iw
					-- actually reports an MCS-based rate (legacy pre-11n
					-- rates have none).
					tx_mcs_index = sta.tx_mcs_index,
				}
			end
			vap.sta_table  = sta_table
			vap.rx_bytes   = vap_rx_bytes
			vap.tx_bytes   = vap_tx_bytes
			vap.rx_packets = vap_rx_packets
			vap.tx_packets = vap_tx_packets
			vap.tx_retries = vap_tx_retries
			vap.tx_dropped = vap_tx_dropped
		end
	end

	-- lldp_table (field names confirmed against the real controller's OXMua
	-- DTO -- see PROTOCOL-VALIDATION.md "Stage 2c")
	local lldp_table = {}
	for _, nbr in ipairs(lldp_nbrs) do
		lldp_table[#lldp_table + 1] = {
			chassis_descr   = nbr.system_desc,
			chassis_id      = nbr.chassis_id,
			local_port_name = nbr.port,
			local_port_idx  = nbr.local_port_idx,
			is_wired        = true,  -- LLDP is inherently a wired-link protocol
			port_id         = nbr.port_id,
			port_descr      = nbr.port_descr,
		}
	end

	-- Device-level spectrum-scan status, aggregated across all radios'
	-- cached results (see radio_table_stats loop above for the per-radio
	-- spectrum_table/spectrum_table_time fields).
	local spectrum_scan_timestamp = nil
	for _, sscan in pairs(M._spectrum_cache) do
		if sscan.scan_timestamp and
		   (not spectrum_scan_timestamp or sscan.scan_timestamp > spectrum_scan_timestamp) then
			spectrum_scan_timestamp = sscan.scan_timestamp
		end
	end

	local payload = {
		_type            = "state",
		["default"]      = not st.adopted,
		["state"]        = st.adopted and 2 or 0,  -- 2=connected, 0=unadopted (per amd989)
		locating         = st.locating or false,
		mac              = mac_str,
		serial           = mac_str:gsub(":", ""),
		model            = uap.model or "U6IW",
		platform         = uap.platform or "U6IW",
		hostname         = st.hostname or "openUF",
		ip               = st.ip or "0.0.0.0",
		inform_url       = st.inform_url,
		cfgversion       = st.cfgversion,
		uptime           = uptime,
		time             = os.time(),
		-- Bare firmware version string only -- NOT model-prefixed. The
		-- controller compares this against its firmware catalog's own
		-- "version" field (e.g. "6.8.2.15592") with a strict, unnormalized
		-- string equality check; a prefixed value like "U6IW.6.8.2.15592"
		-- never matches even when the numeric version is identical, so the
		-- device is permanently shown as needing an update. `fw.pre` (e.g.
		-- "U6IW.") is a separate, correct field used only by announce.lua's
		-- L2 discovery "firmware version verbose" TLV -- do not reuse it here.
		version          = uap.fw and uap.fw.ver or "6.6.55",
		required_version = uap.required_version or "6.0.0",
		bootrom_version  = uap.bootver or "",
		country_code     = st.country_code or 840,
		mem_total        = meminfo.total_kb * 1024,
		mem_used         = (meminfo.total_kb - meminfo.free_kb) * 1024,
		-- Device-level (not per-radio -- see radio_table_stats above)
		spectrum_scanning       = false,
		spectrum_scan_timestamp = spectrum_scan_timestamp,
		-- Real devices report this under the hyphenated key "system-stats"
		-- with {cpu, mem, uptime} as percentage/uptime strings -- confirmed
		-- against a real captured USG inform payload (stephanlascar/
		-- unifi-gateway, poc/real_inform_payload_exemple.json). Previously
		-- sent as "sys_stats" (underscore) with raw loadavg_1/5/15 fields,
		-- which the controller would not have recognized at all.
		["system-stats"] = {
			cpu    = tostring(cpu_pct),
			mem    = tostring(mem_pct),
			uptime = tostring(uptime),
		},
		if_table         = if_table,
		radio_table      = radio_table,
		radio_table_stats = radio_table_stats,
		vap_table        = vap_table,
		lldp_table       = lldp_table,
	}

	return cjson.encode(payload)
end

-- Maps an OpenWrt htmode ("HT20", "HT40+", "VHT80", "HE160", ...) to a
-- channel width in MHz. Falls back to 20 for unrecognized/missing modes.
local function _width_from_htmode(htmode)
	if type(htmode) ~= "string" then return 20 end
	local n = htmode:match("(%d+)")
	return n and tonumber(n) or 20
end

-- WiFi/radio config (SSID, security, per-radio channel/TX power) arrives via
-- system_cfg as a flat, hostapd/OpenWrt-style key=value blob -- NOT as the
-- resp.vap_table/radio_table/network_table JSON that ucihelper.apply_config()
-- was originally built and unit-tested against. Confirmed live against a
-- real controller (10.4.57): creating a WiFi network produces keys like
-- "aaa.1.ssid", "aaa.1.wpa.psk", "aaa.1.wpa=2", "wireless.1.parent=radio0",
-- "radio.1.phyname=radio0", "radio.1.channel=auto" -- a real controller
-- never sends resp.vap_table/radio_table/network_table at all, which meant
-- apply_config() (gated on resp.network_table) never actually ran against
-- one. This translates the flat blob into the {radio_table, vap_table}
-- shape apply_config() expects, so its already-correct, already-tested
-- VLAN-join/fast-roaming/mobility-domain logic can be reused unchanged
-- rather than reimplemented against the raw wire format.
--
-- Security derivation is confirmed only for the plain WPA2-PSK case seen
-- live (aaa.<n>.wpa=2 + wpa.key.1.mgmt=WPA-PSK -> "wpa2"); WPA3/mixed/
-- enterprise are best-effort guesses pending a live capture of those modes.
function M._parse_wifi_system_cfg(sys_raw)
	local aaa, wireless, radio = {}, {}, {}
	for line in (sys_raw .. "\n"):gmatch("([^\n]*)\n") do
		local section, idx, key, v = line:match("^(aaa)%.(%d+)%.(.+)=(.*)$")
		if not section then section, idx, key, v = line:match("^(wireless)%.(%d+)%.(.+)=(.*)$") end
		if not section then section, idx, key, v = line:match("^(radio)%.(%d+)%.(.+)=(.*)$") end
		if section then
			local tbl = (section == "aaa" and aaa) or (section == "wireless" and wireless) or radio
			idx = tonumber(idx)
			tbl[idx] = tbl[idx] or {}
			tbl[idx][key] = v
		end
	end

	local function sorted_indices(t)
		local keys = {}
		for k in pairs(t) do keys[#keys + 1] = k end
		table.sort(keys)
		return keys
	end

	local radio_table = {}
	for _, idx in ipairs(sorted_indices(radio)) do
		local r = radio[idx]
		if r.phyname then
			radio_table[#radio_table + 1] = {
				name     = r.phyname,
				channel  = tonumber(r.channel),   -- "auto" -> nil, leaves channel unchanged
				tx_power = tonumber(r.txpower),   -- "auto" -> nil, leaves tx_power unchanged
			}
		end
	end

	local vap_table = {}
	for _, idx in ipairs(sorted_indices(wireless)) do
		local w = wireless[idx]
		local a = aaa[idx] or {}
		if w.ssid and w.parent then
			local security = "open"
			if a.wpa == "2" then security = "wpa2"
			elseif a.wpa == "3" then security = "wpa3"
			end
			-- VLAN-tagged SSIDs bridge onto a per-VLAN bridge device named
			-- "br0.<vlan>" (vs. plain "br0" for untagged) -- confirmed live:
			-- assigning a WiFi network to a VLAN-tagged network in the
			-- controller UI changes aaa.<n>.br.devname from "br0" to
			-- "br0.20" and adds companion vlan.*/bridge.*/netconf.* blocks
			-- declaring the VLAN subinterface and its bridge (which
			-- ucihelper.ensure_vlan_network() already creates on its own,
			-- so only the VLAN id itself needs extracting here).
			local vlan_id = tonumber((a["br.devname"] or ""):match("^br0%.(%d+)$"))

			vap_table[#vap_table + 1] = {
				ssid                  = w.ssid,
				radio                 = w.parent,
				security              = security,
				-- aaa.<n>.id is the controller's wlanconf ObjectId; the
				-- controller only accepts a vap_table entry whose "id" echoes
				-- it back (vapInformProcessor drops usage=user vaps without
				-- one, taking the nested sta_table -- and thus every wireless
				-- client -- with them).
				wlanconf_id           = a.id,
				x_passphrase          = a["wpa.psk"],
				fast_roaming_enabled  = (a["ft.status"] == "enabled"),
				vlan_enabled          = vlan_id ~= nil,
				vlan                  = vlan_id,
			}
		end
	end

	return radio_table, vap_table
end

-- ─── Response dispatcher ─────────────────────────────────────────────────────

-- Handle a parsed controller response JSON string.
-- st:  current state table
-- cfg: device configuration (from conf.lua; optional -- nil in tests, LED
--      control becomes a no-op without cfg.led)
-- Returns true if config was applied (caller should send follow-up inform).
function M.handle_response(json_str, st, cfg)
	if cfg and cfg.config and cfg.config.debug_dump_file then
		local f = io.open(cfg.config.debug_dump_file, "a")
		if f then
			f:write(os.date("!%Y-%m-%dT%H:%M:%SZ") .. " " .. json_str .. "\n")
			f:close()
		end
	end

	local ok, resp = pcall(cjson.decode, json_str)
	if not ok or type(resp) ~= "table" then
		return false
	end

	local _type = resp._type

	if _type == "noop" then
		return false
	end

	if _type == "setparam" then
		-- mgmt_cfg is a newline-delimited key=value string (real controller format,
		-- confirmed by amd989/unifi-gateway _parse_mgmt_cfg).
		local mgmt_raw = resp.mgmt_cfg
		local newly_adopted = false
		if type(mgmt_raw) == "string" then
			for line in (mgmt_raw .. "\n"):gmatch("([^\n]*)\n") do
				local k, v = line:match("^([^=]+)=(.*)$")
				if k and v then
					if k == "mgmt_url" or k == "inform_url" then
						if v ~= "" then st.inform_url = v end
					elseif k == "use_aes_gcm" then
						st.use_gcm = (v == "true")
					elseif k == "cfgversion" then
						if v ~= "" then st.cfgversion = v end
					elseif k == "led_enabled" then
						local enabled = (v == "true")
						st.led_enabled = enabled
						M._led.set_enabled(cfg and cfg.led, enabled)
					elseif k == "authkey" then
						-- Only trusted pre-adoption. Real L3 adoption has no SSH
						-- step at all (controller logs "skip SSH adoption" for
						-- L3-discovered devices) and delivers the new key this
						-- way instead -- confirmed against amd989/unifi-gateway's
						-- _parse_mgmt_cfg (which does exactly this, no SSH
						-- anywhere in that codebase) and live testing against a
						-- real controller. See PROTOCOL-VALIDATION.md. Restricted
						-- to the unadopted case: while unadopted the device is
						-- still using the well-known DEFAULT_KEY, so this
						-- exchange carries no less confidentiality than the rest
						-- of L3 provisioning already assumes. Once adopted, only
						-- SSH set-adopt may rotate the key (matches real L2
						-- hardware behavior).
						if not st.adopted and is_hex32(v) then
							st.authkey = v
							st.adopted = true
							newly_adopted = true
						end
					end
				end
			end
		end

		-- IP Settings (DHCP vs Static, in the real controller UI) arrive via
		-- system_cfg, not mgmt_cfg -- a separate flat OpenWrt-UCI-style
		-- key=value blob, confirmed live against a real controller (see
		-- PROTOCOL-VALIDATION.md). Only present when the controller is
		-- actually pushing a network-config change, not on every inform.
		local sys_raw = resp.system_cfg
		if type(sys_raw) == "string" then
			local ip, netmask, gateway
			local dhcp = false
			for line in (sys_raw .. "\n"):gmatch("([^\n]*)\n") do
				local k, v = line:match("^([^=]+)=(.*)$")
				if k and v then
					if k == "netconf.1.ip" then ip = v
					elseif k == "netconf.1.netmask" then netmask = v
					elseif k == "route.1.gateway" then gateway = v
					elseif k == "dhcpc.1.status" then dhcp = true
					end
				end
			end
			if ip then
				local iface = cfg and cfg.net and cfg.net.lan_cpueth
				if dhcp then
					-- Only genuinely ACT when reverting our own prior static
					-- config -- a fresh device's first-ever system_cfg (and
					-- every steady-state reaffirmation) also carries
					-- dhcpc.1.status=enabled, but real hardware already runs
					-- its own DHCP client continuously; flushing+re-leasing
					-- on every "still DHCP" push is needless and, worse,
					-- destructive wherever no DHCP server actually exists to
					-- grant a new lease (confirmed live: this validation
					-- container's Docker bridge has none -- udhcpc timed out
					-- and left the interface with no address at all).
					if st.ip_mode == "static" then
						M._netconfig.apply_dhcp(iface)
						M._populate_net_info(st, cfg)  -- re-read the freshly-leased address
					end
					st.ip_mode = "dhcp"
					st.static_ip, st.static_netmask, st.static_gateway = nil, nil, nil
				else
					st.ip_mode = "static"
					st.static_ip, st.static_netmask, st.static_gateway = ip, netmask, gateway
					if M._netconfig.apply_static(iface, ip, netmask, gateway) then
						st.ip = ip  -- known directly, no need to re-read the interface
					end
				end
			end

			local ufuci = M._ucihelper
			if ufuci and ufuci.apply_config then
				local radio_table, vap_table = M._parse_wifi_system_cfg(sys_raw)
				if #radio_table > 0 or #vap_table > 0 then
					pcall(ufuci.apply_config,
						{radio_table = radio_table, vap_table = vap_table, network_table = {}}, cfg)
				end
			end
		end

		M._state.save(st)
		return newly_adopted  -- re-inform immediately with the new key if adopted
	end

	if _type == "setdefault" then
		-- Controller requested factory reset.  Reset state on disk and in-memory.
		io.stderr:write("inform: controller requested factory reset\n")
		-- mac/ip/hostname are populated once at M.run() startup by
		-- _populate_net_info and never persisted to state.json -- preserve them
		-- across the reset rather than losing the device's identity mid-run.
		local mac, ip, hostname = st.mac, st.ip, st.hostname
		local fresh = M._state.reset()
		for k in pairs(st) do st[k] = nil end
		for k, v in pairs(fresh) do st[k] = v end
		st.mac, st.ip, st.hostname = mac, ip, hostname
		M._sync_bootstrap_account(false, cfg and cfg.config and cfg.config.bootstrap_adopt_user)
		return false
	end

	if _type == "reboot" then
		io.stderr:write("inform: controller requested reboot\n")
		os.execute("reboot")
		os.exit(0)
	end

	if _type == "upgrade" then
		-- Store only -- never download/verify/flash/reboot. A real controller's
		-- upgrade URL targets genuine Ubiquiti firmware; applying it to this
		-- (non-Ubiquiti) hardware would brick it. See amd989/unifi-gateway,
		-- which handles this identically (log + store, no real upgrade path).
		st.upgrade_requested_version = tostring(resp.version or "")
		st.upgrade_requested_url     = tostring(resp.url or "")
		io.stderr:write("inform: upgrade requested (version=" .. st.upgrade_requested_version
			.. ") -- stored only, not applying\n")
		M._state.save(st)
		return false
	end

	if _type == "cmd" then
		local cmd = resp.cmd or ""
		io.stderr:write("inform: cmd: " .. tostring(cmd) .. "\n")

		if cmd == "set-locate" or cmd == "unset-locate" then
			local led_path = cfg and cfg.led
			if cmd == "set-locate" then M._led.locate_start(led_path)
			else M._led.locate_stop(led_path) end
			st.locating = (cmd == "set-locate")
			M._state.save(st)
		elseif cmd == "spectrum-scan" then
			-- Trigger a scan per radio (sweeps every channel), then read back
			-- per-channel survey data and build a spectrum_table entry per
			-- radio, cached for the next build_json() call.
			--
			-- Field names (spectrum_table/spectrum_table_time/
			-- spectrum_scan_timestamp/channel/center_freq/width/utilization/
			-- interference) are confirmed against the real UniFi Network
			-- Application's own Java bytecode (10.4.57's ace.jar/
			-- internal-dependencies.jar constant pool -- see
			-- PROTOCOL-VALIDATION.md section 8 for the full derivation), not
			-- guessed. The exact numeric semantics of `width` and
			-- `interference` are still a best-effort approximation (radio's
			-- configured htmode, and raw noise-floor dBm, respectively) --
			-- verify against a live controller capture before trusting the
			-- values, not just the key names.
			local ufuci = M._ucihelper
			if ufuci and ufuci.get_radio_table then
				local ok_r, radios = pcall(ufuci.get_radio_table)
				if ok_r then
					local now = os.time()
					for _, radio in ipairs(radios) do
						local ok_if, ifname = pcall(ufuci.get_ifname_for_radio, radio.name)
						if ok_if and ifname then
							ufuci._popen("iw dev " .. ifname .. " scan")
							local ok_rs, stats = pcall(M._sysinfo.radio_stats, ifname)
							if ok_rs then
								local width = _width_from_htmode(radio.ht)
								local table_entries = {}
								for _, s in ipairs(stats) do
									local total = s.channel_time or 0
									local busy  = s.channel_time_busy or 0
									table_entries[#table_entries + 1] = {
										channel     = M._sysinfo.channel_from_freq(s.freq),
										center_freq = s.freq,
										width       = width,
										utilization = total > 0 and math.floor(busy * 100 / total) or 0,
										interference = s.noise or 0,
									}
								end
								M._spectrum_cache[radio.name] = {
									table          = table_entries,
									table_time     = now,
									scan_timestamp = now,
								}
							end
						end
					end
				end
			end
		end
		-- other cmd values (e.g. mfi-output, restart): no-op
		--
		-- Per fxkr/unifi-protocol-reverse-engineering's documented inform
		-- semantics: "Upon receiving a command message, an AP will execute a
		-- command and then send another inform immediately" -- regardless of
		-- which cmd it was, including ones we treat as a no-op. Matches the
		-- cfgversion branch below, which already does this correctly.
		return true
	end

	-- Config update: check cfgversion
	if type(resp.cfgversion) == "string" and resp.cfgversion ~= st.cfgversion then
		local ufuci = M._ucihelper
		if ufuci and resp.network_table then
			local ok_apply = pcall(ufuci.apply_config, resp, cfg)
			if ok_apply then
				st.cfgversion = resp.cfgversion
				M._state.save(st)
				return true  -- signal: send follow-up inform immediately
			end
		elseif ufuci and resp.cfgversion then
			st.cfgversion = resp.cfgversion
			M._state.save(st)
			return true
		end
	end

	return false
end

-- ─── HTTP POST ───────────────────────────────────────────────────────────────

-- POST a binary payload to the inform URL.
-- Returns the raw response body or nil, error_msg.
function M.http_post(url, body)
	if M._http_post then
		return M._http_post(url, body)
	end

	-- Parse URL
	local scheme, host, port, path = url:match("^(https?)://([^:/]+):?(%d*)(.*)")
	if not host then return nil, "invalid URL: " .. tostring(url) end
	local is_tls = (scheme == "https")
	port = tonumber(port) or (is_tls and 8443 or 8080)
	if path == "" then path = "/inform" end

	local socket = require("socket")
	local tcp = socket.tcp()
	tcp:settimeout(10)
	local ok, err = tcp:connect(host, port)
	if not ok then
		tcp:close()
		return nil, "connect failed: " .. tostring(err)
	end

	-- For https, wrap the socket in TLS. Previously the scheme was accepted but
	-- ignored, so an https:// URL sent the inform in cleartext to a TLS port and
	-- failed opaquely. Controllers use self-signed certs, so verification is off.
	if is_tls then
		local ok_ssl, ssl = pcall(require, "ssl")
		if not ok_ssl then
			tcp:close()
			return nil, "https inform URL requires luasec (apk add luasec); " ..
				"install it or use an http:// URL"
		end
		local wrapped, werr = ssl.wrap(tcp, {
			mode = "client", protocol = "any", verify = "none", options = "all",
		})
		if not wrapped then
			tcp:close()
			return nil, "TLS wrap failed: " .. tostring(werr)
		end
		tcp = wrapped
		tcp:settimeout(10)
		local ok_h, herr = tcp:dohandshake()
		if not ok_h then
			tcp:close()
			return nil, "TLS handshake failed: " .. tostring(herr)
		end
	end

	local req = table.concat({
		"POST " .. path .. " HTTP/1.0\r\n",
		"Host: " .. host .. ":" .. tostring(port) .. "\r\n",
		"Content-Type: application/x-binary\r\n",
		"Content-Length: " .. #body .. "\r\n",
		"\r\n",
		body
	})

	tcp:send(req)

	-- Read response (HTTP/1.0 — server closes after response). With a numeric
	-- pattern LuaSocket reads *exactly* N bytes and, when the peer closes before
	-- N arrive, returns (nil, "closed", partial). The inform response is almost
	-- always smaller than one read, so the body lives entirely in that `partial`
	-- third value — it must be captured or every response is silently lost
	-- ("HTTP nil") and adoption never completes.
	local response = {}
	while true do
		local chunk, recv_err, partial = tcp:receive(4096)
		if chunk then
			response[#response + 1] = chunk
		else
			if partial and #partial > 0 then
				response[#response + 1] = partial
			end
			if recv_err ~= "closed" then
				tcp:close()
				return nil, "recv error: " .. tostring(recv_err)
			end
			break
		end
	end
	tcp:close()

	local full = table.concat(response)
	-- Extract HTTP status
	local status = tonumber(full:match("HTTP/%S+ (%d+)"))
	if status ~= 200 then
		return nil, "HTTP " .. tostring(status)
	end

	-- Return body (after blank line separating headers)
	local body_start = full:find("\r\n\r\n")
	if body_start then
		return full:sub(body_start + 4)
	end
	return full
end

-- ─── Main loop ───────────────────────────────────────────────────────────────

-- Populate st.mac / st.ip using announce.lua's get_mac/get_ip helpers.
--
-- _require_sibling dofile()s announce.lua fresh every call (dofile, unlike
-- require, never caches), which re-runs its self-executing "script entry
-- point" block at the bottom -- that block is guarded by
-- `if not OPENUF_TEST_MODE`, so outside of tests (where it's already true)
-- this would spawn announce.lua's own *infinite* L2 broadcast loop nested
-- inside inform.lua's own M.run, or -- if the broadcast send errors, as it
-- does e.g. on a docker bridge network that disallows UDP broadcast -- call
-- os.exit(1) and kill the whole inform process before the actual inform loop
-- ever runs. Suppress it for the duration of just this reuse-only dofile.
function M._populate_net_info(st, cfg)
	local prev_test_mode = OPENUF_TEST_MODE
	OPENUF_TEST_MODE = true
	local ok_ann, announce = pcall(_require_sibling, "announce")
	OPENUF_TEST_MODE = prev_test_mode
	if not ok_ann then return end

	local iface = cfg and cfg.net and cfg.net.lan_cpueth or "eth1"
	local mac_tbl = announce.get_mac(iface)
	if mac_tbl then
		-- Format as "xx:xx:xx:xx:xx:xx"
		st.mac = string.format("%02x:%02x:%02x:%02x:%02x:%02x",
			mac_tbl[1], mac_tbl[2], mac_tbl[3],
			mac_tbl[4], mac_tbl[5], mac_tbl[6])
	end
	local ip_tbl = announce.get_ip(iface)
	if ip_tbl then
		st.ip = string.format("%d.%d.%d.%d",
			ip_tbl[1], ip_tbl[2], ip_tbl[3], ip_tbl[4])
	end
end

-- Detects an out-of-process change to the on-disk state file -- written by
-- syswrapper.lua's set-adopt/reset-inform, invoked over SSH as a separate,
-- short-lived process -- and reloads it into the in-memory st table this
-- loop uses. Without this, a long-running inform.lua would never notice a
-- fresh SSH-driven adoption (or a manual reset-inform) and would keep
-- informing with stale credentials until restarted. Also keeps the SSH
-- bootstrap account (if enabled) locked/unlocked to match the reloaded
-- adopted state. Returns the current mtime (unchanged from last_mtime if
-- the file didn't change).
function M._reload_if_changed(st, cfg, last_mtime)
	local mtime = M._state_mtime(M._state._state_file)
	if mtime == nil or mtime == last_mtime then
		return last_mtime
	end
	-- mac/ip/hostname are populated once at M.run() startup and never
	-- persisted to state.json -- preserve them across the reload.
	local mac, ip, hostname = st.mac, st.ip, st.hostname
	local fresh = M._state.load()
	for k in pairs(st) do st[k] = nil end
	for k, v in pairs(fresh) do st[k] = v end
	st.mac, st.ip, st.hostname = mac, ip, hostname
	M._sync_bootstrap_account(st.adopted, cfg and cfg.config and cfg.config.bootstrap_adopt_user)
	return mtime
end

-- Start the inform heartbeat loop (blocks forever).
-- cfg, ufhw: passed through to build_json()
function M.run(cfg, ufhw)
	local st = state.load()
	M._populate_net_info(st, cfg)
	M._sync_bootstrap_account(st.adopted, cfg and cfg.config and cfg.config.bootstrap_adopt_user)

	local socket   = require("socket")
	local interval = 10
	local backoff  = interval
	local last_mtime = M._state_mtime(M._state._state_file)

	while true do
		last_mtime = M._reload_if_changed(st, cfg, last_mtime)
		local json_str = M.build_json(st, cfg, ufhw)
		local pkt      = M.build_packet(json_str, st)  -- use_gcm read from st.use_gcm
		local body, err = M.http_post(st.inform_url, pkt)

		if not body then
			io.stderr:write("inform: POST failed: " .. tostring(err) .. "\n")
			backoff = math.min(backoff * 2, 60)
			socket.select(nil, nil, backoff)
		else
			backoff = interval
			local parse_ok, json_body, resp_flags = pcall(M.parse_packet, body, st)
			if parse_ok then
				local config_applied = M.handle_response(json_body, st, cfg)
				if not config_applied then
					socket.select(nil, nil, interval)
				end
			else
				io.stderr:write("inform: parse error: " .. tostring(json_body) .. "\n")
				socket.select(nil, nil, interval)
			end
		end
	end
end

-- ─── Script entry point ───────────────────────────────────────────────────────

if not OPENUF_TEST_MODE then
	local ok, err = pcall(function()
		if not ufpkt then
			local ok2 = pcall(dofile, "lib/lib.lua")
			if not ok2 then dofile("openuf/lib/lib.lua") end
		end
		dofile("conf.lua")
		local ufhw = {uap = dofile("ufmodel/" .. dev.openuf.uap.ufmodel .. ".lua")}
		-- config (debug_dump_file, state_file, ...) is a separate global set by
		-- conf.lua, not a field of dev.conf -- merge it in under .config so
		-- handle_response's cfg.config.debug_dump_file check can see it.
		dev.conf.config = config
		M.run(dev.conf, ufhw)
	end)
	if not ok then
		io.stderr:write("inform: " .. tostring(err) .. "\n")
		os.exit(1)
	end
end

return M
