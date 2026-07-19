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
local firewall  = _require_sibling("firewall")
local usteer    = _require_sibling("usteer")

local M = {}

-- Injectable: expose internal modules so tests can inject fixtures
M._state     = state
M._sysinfo   = sysinfo
M._ucihelper = ucihelper
M._lldp      = lldp
M._led       = led
M._netconfig = netconfig
M._firewall  = firewall
M._usteer    = usteer

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

-- Best-effort proxy for the "WiFi Experience" score a real AP computes
-- on-device (proprietary/undocumented formula -- confirmed via decompiled
-- controller 10.4.57 that the controller itself does no computation: it
-- just reads "satisfaction" straight off the client doc, which is
-- populated verbatim from whatever the AP sent in that sta_table entry).
-- Community reports (community.ui.com) describe it as driven by signal
-- quality and tx-retry ratio -- e.g. a client with great signal but very
-- low PHY rate/high retries still scores low -- so this combines a
-- signal-quality score and a retry-quality score and takes the worse of
-- the two, matching that "worst factor wins" description. Not a measured
-- value; flagged the same way as capacity/throughput above.
-- signal: dBm (nil if iw reported none). retry_pct: 0-100.
-- Returns an integer 0-100, or nil if signal is unavailable.
local function estimate_satisfaction(signal, retry_pct)
	if not signal then return nil end
	local SIGNAL_FLOOR, SIGNAL_CEIL = -85, -50
	local signal_score = (signal - SIGNAL_FLOOR) / (SIGNAL_CEIL - SIGNAL_FLOOR) * 100
	if signal_score < 0 then signal_score = 0 end
	if signal_score > 100 then signal_score = 100 end
	local retry_score = 100 - (retry_pct or 0)
	if retry_score < 0 then retry_score = 0 end
	local score = math.min(signal_score, retry_score)
	return math.floor(score)
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
	local scan_radio_table  = {}

	local mac_str = st.mac or "00:00:00:00:00:00"

	-- Wireless station MACs, collected below while building vap_table --
	-- subtracted from port_table's mac_table entries further down so a
	-- wireless client bridged into br-lan (and thus also visible in the
	-- bridge FDB) is never double-reported as a wired client too.
	local station_macs = {}
	-- The device's own MACs (its netdevs) -- excluded from port_table's
	-- mac_table for the same reason: without this, the AP would report
	-- itself as a wired client of its own switch.
	local self_macs = {[mac_str] = true}
	for _, iface in ipairs(ifaces) do
		if iface.mac and iface.mac ~= "" then self_macs[iface.mac] = true end
	end

	-- ufuci: VAP/radio info (require("uci") calls inside it can legitimately
	-- fail off-target, so individual calls are still pcall-wrapped below)
	local ufuci = M._ucihelper
	if ufuci and ufuci.get_vap_table then
		local ok_v, rv = pcall(ufuci.get_vap_table)
		if ok_v then vap_table = rv end
		local ok_r, rr = pcall(ufuci.get_radio_table)
		if ok_r then radio_table = rr end

		-- Live per-radio channel utilization, parallel to radio_table (matches
		-- real UniFi's split of static config vs. live stats). Also kept in
		-- radio_cu_stats, keyed by radio name, so each vap_table entry on
		-- that radio can carry the same cu_* figures -- confirmed via
		-- decompile (com.ubnt.service.system.XrjNIQhefUEBuL's archived-field
		-- schema registry) that cu_interf/cu_self_tx/cu_self_rx live in the
		-- same per-VAP schema group as avg_client_signal, not solely in
		-- radio_table_stats: live-tested against a real controller, adding
		-- them only to radio_table_stats left the archiver's client_signal_avg
		-- populating every cycle while cu_interf/cu_total never appeared at
		-- all despite being sent correctly.
		local radio_cu_stats = {}
		-- Minimum RSSI enforcement data, keyed by radio name (e.g. "radio0"),
		-- consumed by the per-station loop below -- kept as absolute dBm
		-- thresholds (already converted using this same loop's live noise
		-- reading) so the enforcement check further down is a plain
		-- sta.signal comparison.
		local minrssi_threshold_by_radio = {}
		for _, radio in ipairs(radio_table) do
			local ok_if, ifname = pcall(ufuci.get_ifname_for_radio, radio.name)
			if ok_if and ifname then
				-- Hardware capability fields the controller's radio_table
				-- ingestion expects independently of everything else here
				-- (is_11ac/is_11ax/is_11be/has_dfs/has_fccdfs/has_ht160/
				-- has_eht240/has_eht320/nss) -- see sysinfo.radio_caps()
				-- for the decompile citation. Missing these is why the
				-- Radios tab excluded the device entirely.
				local ok_caps, caps = pcall(M._sysinfo.radio_caps, ifname)
				if ok_caps and caps then
					for k, v in pairs(caps) do radio[k] = v end
					-- radio_caps: a genuine SEPARATE integer field on
					-- radio_table (confirmed via decompile,
					-- com.ubnt.service.devmgr.PGOcbDWlbnYQdFW/
					-- tFhABnrHYJqvjaoEa: `uCthhvfQNZ2.put("radio_caps",
					-- uCthhvfQNZ3.getInt("radio_caps", 0))` -- an int, not the
					-- flattened is_11ac/nss/etc. booleans above, and distinct
					-- from radio_caps2) -- confirmed 2026-07-14 from the
					-- controller's own React bundle (swai chunk) that the
					-- Radios tab's MIMO column/filter computes
					-- `mimo: e7(radio.radio_caps)` from exactly this field.
					-- The controller's Java side only ever passes this int
					-- through verbatim (no server-side bit-decode found in
					-- the decompile); the decode into "1x1".."4x4" happens
					-- client-side only. openUF previously always sent 0 (the
					-- field was never populated), which is why every radio's
					-- MIMO column stayed blank and the 1x1-4x4 filter
					-- checkboxes excluded every radio outright rather than
					-- just filtering incorrectly. The exact bit layout isn't
					-- simply "value == nss" (confirmed live: radio_caps=2
					-- still showed blank/excluded) -- it's a bitmask, reverse
					-- engineered by calling the controller's own live e7()
					-- decoder directly (via its webpack module cache) with a
					-- sweep of single-bit values: bit 3 (0x8) -> "1x1", bit 4
					-- (0x10) -> "2x2", bit 5 (0x20) -> "3x3", bit 26
					-- (0x4000000) -> "4x4", checked in that highest-first
					-- priority order when multiple bits are set (all
					-- confirmed against the live decoder, not guessed).
					local RADIO_CAPS_MIMO_BIT = {
						[1] = 0x8,
						[2] = 0x10,
						[3] = 0x20,
						[4] = 0x4000000,
					}
					radio.radio_caps = RADIO_CAPS_MIMO_BIT[caps.nss or 1] or RADIO_CAPS_MIMO_BIT[1]
				end
				local ok_rs, stats = pcall(M._sysinfo.radio_stats, ifname)
				-- min_rssi (outbound field, confirmed via decompile alongside
				-- radio_caps/tx_power/athstats in the same DTO) needs the
				-- live noise floor to convert rf_config()'s stored raw wire
				-- units back to dBm -- minrssi.rssi is an offset from the
				-- driver's noise floor, NOT plain dBm (confirmed live: UI
				-- "-80 dBm" <-> wire "15", UI "-85 dBm" <-> wire "10", both
				-- consistent with raw = dbm + 95). Falls back to that -95
				-- assumption only when a live noise reading isn't available.
				local noise = (ok_rs and stats[1] and stats[1].noise) or -95
				if radio.min_rssi_enabled then
					radio.min_rssi = radio.min_rssi_raw + noise
					minrssi_threshold_by_radio[radio.name] = radio.min_rssi
				end
				radio.min_rssi_raw = nil
				if ok_rs and stats[1] then
					local s     = stats[1]  -- in-use channel's survey entry
					local total = s.channel_time or 0
					local busy  = s.channel_time_busy or 0
					local cu_total   = total > 0 and math.floor(busy * 100 / total) or 0
					local cu_self_rx = total > 0 and math.floor((s.channel_time_rx or 0) * 100 / total) or 0
					local cu_self_tx = total > 0 and math.floor((s.channel_time_tx or 0) * 100 / total) or 0
					local entry = {
						name        = radio.name,
						channel     = radio.channel,
						cu_total    = cu_total,
						cu_self_rx  = cu_self_rx,
						cu_self_tx  = cu_self_tx,
						-- cu_interf: airtime busy for reasons other than this
						-- radio's own tx/rx (other-BSS/non-WiFi interference).
						-- The stat archiver (com.ubnt.service.system.
						-- QDcGUYAmLvJwylXw, confirmed via decompile) reads
						-- this as a sibling of cu_total/cu_self_rx/cu_self_tx
						-- and silently drops the whole per-band bucket without
						-- it -- this is why "Avg. Interference" stayed blank
						-- even though cu_total was already being sent.
						cu_interf   = math.max(0, cu_total - cu_self_rx - cu_self_tx),
					}
					radio_cu_stats[radio.name] = {
						cu_total   = entry.cu_total,
						cu_self_rx = entry.cu_self_rx,
						cu_self_tx = entry.cu_self_tx,
						cu_interf  = entry.cu_interf,
					}
					-- athstats: the ACTUAL source the stat archiver reads for
					-- these four fields, confirmed via decompiling
					-- com.ubnt.service.system.x.htDMji -- it iterates
					-- radio_table (not radio_table_stats, not vap_table) and
					-- SKIPS a radio entirely if it lacks this nested
					-- "athstats" sub-object (`if
					-- (!uCthhvfQNZ.containsField("athstats")) continue;`),
					-- then reads cu_total/cu_self_rx/cu_self_tx/satisfaction/
					-- cu_interf off it (named after the legacy Atheros ath9k/
					-- ath10k driver stats struct UniFi firmware historically
					-- exposed under this name, kept for newer radios too).
					-- radio_table_stats/vap_table's copies of these same
					-- fields are real and used by other code paths (the live
					-- wifi-stats/radios REST API, per-VAP display) but this
					-- nested copy is what the periodic archiver needs --
					-- omitting it is why "Avg. Interference"/"Avg. Airtime"
					-- stayed blank even with correct data everywhere else.
					radio.athstats = {
						cu_total   = cu_total,
						cu_self_rx = cu_self_rx,
						cu_self_tx = cu_self_tx,
						cu_interf  = entry.cu_interf,
					}
					-- Cached spectrum-scan result, if a "spectrum-scan" cmd
					-- was handled for this radio (see cmd dispatch below).
					-- NOTE: spectrum_scanning/spectrum_scan_timestamp are
					-- device-level (top-level payload) fields, not per-radio
					-- -- confirmed against the real controller's own device
					-- schema, which has them at the top level while
					-- spectrum_table/spectrum_table_time are the per-radio
					-- fields (see PROTOCOL-VALIDATION.md's
					-- radio_table_stats reference).
					local sscan = M._spectrum_cache[radio.name]
					if sscan then
						entry.spectrum_table      = sscan.table
						entry.spectrum_table_time = sscan.table_time
					end
					radio_table_stats[#radio_table_stats + 1] = entry
				end
				-- Neighboring wireless networks visible to this radio --
				-- confirmed real field names via the decompiled controller's
				-- ingestion DTO (com.ubnt.service.aO.bLwwMKkr, literally
				-- named "PeerScan"): a top-level scan_radio_table, one entry
				-- per radio, each carrying that radio's own scan_table list.
				-- Feeds the controller's Insights -> AirView -> Environment
				-- view (backed by stat/rogueap) -- a different, previously
				-- unimplemented feature from the RF/spectrum-scan cmd above,
				-- which only ever reported channel utilization, never which
				-- neighboring SSIDs/BSSIDs were actually detected. See
				-- PROTOCOL-VALIDATION.md for the full derivation.
				local ok_sc, nets = pcall(M._sysinfo.scan_table, ifname)
				if ok_sc and nets then
					local scan_table = {}
					for _, net in ipairs(nets) do
						scan_table[#scan_table + 1] = {
							mac        = net.bssid,
							bssid      = net.bssid,
							radio      = radio.radio,
							radio_name = radio.name,
							-- Confirmed from the controller's own React bundle
							-- (2026-07-14, react-app-wrapper chunk): the
							-- Environment tab's list is fed through an
							-- unconditional filter keyed on `band` (a field
							-- distinct from `radio`, but taking the exact same
							-- enum values -- "ng"/"na"/"6e", confirmed from the
							-- bundle's own enum definition) -- any entry
							-- missing `band` fails that filter silently, with
							-- no error and no visible UI cause, regardless of
							-- every visible sidebar filter's state.
							band       = radio.radio,
							channel    = net.channel,
							freq       = net.freq,
							rssi       = net.signal,
							signal     = net.signal,
							-- The Environment tab's "Ch. Width" column reads
							-- this directly and renders nothing at all when
							-- it's falsy/missing (confirmed live 2026-07-14).
							bw         = net.bw or 20,
							-- NOT last_seen: the controller derives the
							-- absolute last_seen itself from report_time -
							-- age, and its rogue-AP detection silently
							-- drops any entry with age >= 30 as stale
							-- (confirmed live 2026-07-14, see
							-- PROTOCOL-VALIDATION.md) -- age must be
							-- seconds actually elapsed, not omitted.
							age        = net.age or 0,
							security   = net.security,
							essid      = net.essid,
						}
					end
					scan_radio_table[#scan_radio_table + 1] = {
						radio      = radio.radio,
						name       = radio.name,
						scan_table = scan_table,
					}
				end
			end
		end

		-- Live connected-client counts, nested per-vap as sta_table -- matches
		-- the real controller's vap-stats DTO, which nests connected clients
		-- inside each vap_table entry rather than a flat top-level table
		-- (confirmed against unifi-network-application:10.4.57's own
		-- bytecode; see PROTOCOL-VALIDATION.md's outbound payload
		-- field reference).
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
			local signal_sum, signal_count = 0, 0
			local sta_table = {}
			for _, sta in ipairs(stas) do
				station_macs[sta.mac] = true
				vap_rx_bytes    = vap_rx_bytes    + (sta.rx_bytes or 0)
				vap_tx_bytes    = vap_tx_bytes    + (sta.tx_bytes or 0)
				vap_rx_packets  = vap_rx_packets  + (sta.rx_packets or 0)
				vap_tx_packets  = vap_tx_packets  + (sta.tx_packets or 0)
				vap_tx_retries  = vap_tx_retries  + (sta.tx_retries or 0)
				vap_tx_dropped  = vap_tx_dropped  + (sta.tx_failed or 0)
				if sta.signal then
					signal_sum   = signal_sum + sta.signal
					signal_count = signal_count + 1
				end
				-- "Minimum RSSI": a real per-radio (not per-vap) setting --
				-- vap.radio_name is the shared UCI radio device name, so every
				-- vap/SSID broadcasting on this same physical radio enforces
				-- the identical threshold. One-shot deauth only (see
				-- ucihelper.kick_station) -- no block, client can reassociate
				-- immediately.
				local minrssi_threshold = minrssi_threshold_by_radio[vap.radio_name]
				if minrssi_threshold and sta.signal and sta.signal < minrssi_threshold then
					pcall(ufuci.kick_station, ifname, sta.mac)
				end
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

				-- wifi_tx_attempts: total transmission attempts (successful +
				-- retried), i.e. tx_packets + tx_retries -- both already
				-- parsed from iw. wifi_tx_retries_percentage: retries as a
				-- fraction of attempts. Confirmed real field names/semantics
				-- via the decompiled wireless-client model
				-- (com.ubnt.service.l.e.AQODNNoMmBlFpWXX) and unpoller/unifi's
				-- REST client struct.
				local wifi_tx_attempts = (sta.tx_packets or 0) + (sta.tx_retries or 0)
				local wifi_tx_retries_pct = 0
				if wifi_tx_attempts > 0 then
					wifi_tx_retries_pct = (sta.tx_retries or 0) * 100 / wifi_tx_attempts
				end
				local satisfaction_now = estimate_satisfaction(sta.signal, wifi_tx_retries_pct)

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
					-- tx_mcs/rx_mcs: confirmed real field names (not
					-- "tx_mcs_index", which is only the ucore-message wire
					-- name) via the decompiled wireless-client model
					-- (com.ubnt.service.l.e.AQODNNoMmBlFpWXX) and unpoller/
					-- unifi's REST client struct. iw's bitrate lines already
					-- print this ("144.4 MBit/s MCS 15 short GI"); only set
					-- when iw actually reports an MCS-based rate (legacy
					-- pre-11n rates have none).
					tx_mcs     = sta.tx_mcs,
					rx_mcs     = sta.rx_mcs,
					-- radio_proto: still sent for the disconnect-time session
					-- archive (com.ubnt.service.devmgr.TtZhv reads this string
					-- directly when a client disconnects), but it is NOT what
					-- drives the live, still-connected display -- confirmed by
					-- decompiling the actual live-update path
					-- (com.ubnt.service.devmgr.HCKpgcBFPLu, a KrlpWXOulbN
					-- implementation) down to com.ubnt.g.s.jRsSex, whose
					-- generation logic ignores any "radio_proto" string
					-- entirely and instead derives it from boolean per-station
					-- capability flags -- is_11be/is_11ax/is_11ac/is_11n/
					-- is_11b -- falling through to the lowest ("g" on 2.4GHz,
					-- "a" on 5GHz) when none are set. That's why sending only
					-- radio_proto left every live client showing "g"/"a" and
					-- why nss (read directly, no derivation) worked
					-- immediately: these booleans were the missing piece.
					is_11n     = sta.tx_generation == "n",
					is_11ac    = sta.tx_generation == "ac",
					is_11ax    = sta.tx_generation == "ax",
					is_11be    = sta.tx_generation == "be",
					radio_proto = sta.tx_generation or (vap.radio == "na" and "a" or "g"),
					nss         = sta.tx_nss or 1,
					wifi_tx_attempts = wifi_tx_attempts,
					wifi_tx_retries_percentage = wifi_tx_retries_pct,
					-- satisfaction/satisfaction_now: see estimate_satisfaction()
					-- above for the full provenance/caveat. The controller
					-- does no computation of its own -- it only reads
					-- "satisfaction" straight off whatever the AP sent here
					-- (confirmed via decompile) and maintains a running
					-- satisfaction_avg -- so a real device's on-device score
					-- must be approximated here or the client's "WiFi
					-- Experience" stays permanently blank.
					satisfaction     = satisfaction_now,
					satisfaction_now = satisfaction_now,
				}
			end
			vap.sta_table  = sta_table
			vap.rx_bytes   = vap_rx_bytes
			vap.tx_bytes   = vap_tx_bytes
			vap.rx_packets = vap_rx_packets
			vap.tx_packets = vap_tx_packets
			vap.tx_retries = vap_tx_retries
			vap.tx_dropped = vap_tx_dropped
			-- avg_client_signal: mean RSSI (dBm, negative) of currently
			-- associated clients on this VAP. The stat archiver (decompiled
			-- com.ubnt.service.system.QDcGUYAmLvJwylXw) reads this exact
			-- field name directly off each vap_table entry -- alongside the
			-- existing num_sta -- to compute the "Avg. Signal" column; it is
			-- NOT derived server-side from per-client signal the way
			-- "weakest_clients_signal_avg" is, so omitting it left that
			-- column permanently blank regardless of per-client signal
			-- already being sent correctly.
			if signal_count > 0 then
				vap.avg_client_signal = math.floor(signal_sum / signal_count)
			end
			-- cu_total/cu_self_rx/cu_self_tx/cu_interf: same per-radio channel-
			-- utilization figures as radio_table_stats, duplicated onto each
			-- VAP on that radio -- see radio_cu_stats above for why.
			local cu = radio_cu_stats[vap.radio_name]
			if cu then
				vap.cu_total   = cu.cu_total
				vap.cu_self_rx = cu.cu_self_rx
				vap.cu_self_tx = cu.cu_self_tx
				vap.cu_interf  = cu.cu_interf
			end
		end
	end

	-- port_table: the device's own ethernet ports plus, per non-uplink port,
	-- the wired hosts learned behind it. Confirmed via decompiled
	-- controller 10.4.57 (com.ubnt.service.devmgr.PGOcbDWlbnYQdFW /
	-- DyonYyyYJkiyv / TtZhv, see PROTOCOL-VALIDATION.md) that this is only
	-- processed at all when Device.isSwitch() is true for the reported
	-- model -- which it is for U6IW (registered in the controller's model
	-- registry with 5 ports and a switch feature flag), so this is not
	-- optional for that model: an empty/missing port_table means zero
	-- wired clients can ever appear, and the device's Ports view stays
	-- empty, regardless of what's actually bridged into br-lan.
	local ports = (cfg and cfg.net and cfg.net.ports) or {
		{idx = 1, ifname = (cfg and cfg.net and cfg.net.wan_cpueth) or "eth0", uplink = true},
		{idx = 2, ifname = (cfg and cfg.net and cfg.net.lan_cpueth) or "eth1"},
	}
	local iface_by_name = {}
	for _, iface in ipairs(ifaces) do iface_by_name[iface.name] = iface end
	local port_table = {}
	for _, p in ipairs(ports) do
		local iface = iface_by_name[p.ifname]
		local entry = {
			port_idx    = p.idx,
			name        = "Port " .. tostring(p.idx),
			media       = "GE",
			up          = iface ~= nil,
			enable      = true,
			speed       = 1000,
			full_duplex = true,
			is_uplink   = p.uplink or false,
			speed_caps  = 0,
			port_poe    = false,
			poe_caps    = 0,
			rx_bytes    = iface and iface.rx_bytes   or 0,
			tx_bytes    = iface and iface.tx_bytes   or 0,
			rx_packets  = iface and iface.rx_packets or 0,
			tx_packets  = iface and iface.tx_packets or 0,
			rx_errors   = iface and iface.rx_errors  or 0,
			tx_errors   = iface and iface.tx_errors  or 0,
		}
		-- Wired clients are only reported on downstream (non-uplink) ports --
		-- the controller itself skips client creation on ports flagged
		-- is_uplink, since that port faces the controller's own network, not
		-- an end host.
		if not entry.is_uplink then
			local mac_table = {}
			local ok_mt, hosts = pcall(M._sysinfo.mac_table, p.ifname)
			if ok_mt then
				for _, host in ipairs(hosts) do
					if not self_macs[host.mac] and not station_macs[host.mac] then
						mac_table[#mac_table + 1] = {
							mac      = host.mac,
							ip       = host.ip,
							hostname = host.hostname,
							age      = host.age,
							uptime   = host.uptime,
						}
					end
				end
			end
			entry.mac_table = mac_table
		end
		port_table[#port_table + 1] = entry
	end

	-- lldp_table (field names confirmed against the real controller's OXMua
	-- DTO -- see PROTOCOL-VALIDATION.md's outbound payload field
	-- reference)
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
		-- Bit 0x10 (16): Device.hasQCASwitch() in the decompiled controller
		-- is exactly hasFirmwareCapability(16), and PGOcbDWlbnYQdFW gates the
		-- Ports view's projection of port_table into the device DTO on it.
		-- Wired-client ingestion itself is gated only on isSwitch() (a
		-- model-registry property, not this bit), so wired clients can
		-- appear without this -- but the Ports view needs it.
		-- Bit 0x100 (256): Device.hasOWRTSwitch() -- exactly
		-- hasFirmwareCapability(256), literally "OpenWrt switch" as opposed
		-- to a genuine QCA hardware switch ASIC (fitting, since that's
		-- exactly what this is). Without it, the REST API's per-port VLAN
		-- validator (com.ubnt.ace.api.e.VVyiC, only reachable once
		-- hasQCASwitch() above is true) unconditionally rejects any port
		-- whose forward mode resolves to the default "all" -- i.e. every
		-- port that has never had `forward` explicitly set -- with
		-- api.err.VlanTaggingUnsupportedByDevice, before ever touching
		-- vlan_caps or anything port-specific. Confirmed live: assigning a
		-- port's Native VLAN/Network failed with exactly that error at
		-- fw_caps=0x10, and succeeded once this bit was added (0x110) --
		-- reproduced directly against the REST endpoint, bypassing the UI,
		-- to rule out unrelated causes. See PROTOCOL-VALIDATION.md's
		-- "Capability bitmasks" for the full derivation (traced through
		-- an obfuscation-induced macOS case-folding extraction bug along
		-- the way).
		fw_caps          = 0x110,
		-- Bit 0x40 (64): Device.supportAdvertisingDeviceNameInBeacon() in the
		-- decompiled controller is exactly hasWifiCapability2(64) -- i.e. bit
		-- 6 of a SECOND capability bitmask, wifi_caps2, entirely separate
		-- from fw_caps/wifi_caps above. Confirmed by decompiling
		-- com/ubnt/service/config's WLAN-config-generator method: it only
		-- emits wireless.<n>.advertise_ap_name into system_cfg at all when
		-- this bit is set -- otherwise the "Show Access Point Name in
		-- Beacon" WLAN toggle is silently dropped, which is exactly what a
		-- live capture showed (toggling it produced zero system_cfg/mgmt_cfg
		-- diff, and the controller didn't even bother re-pushing config on
		-- the next change) before this bit was added. Only this one bit is
		-- claimed -- wifi_caps2 also gates several other real-hardware-only
		-- features (Mesh MLO parent/child, assisted roaming, etc., see
		-- PROTOCOL-VALIDATION.md) that openUF does not implement and must
		-- not claim.
		wifi_caps2       = 0x40,
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
		scan_radio_table = scan_radio_table,
		port_table       = port_table,
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

-- radio.<n>.ieee_mode: the controller's per-radio 802.11 mode + channel width,
-- as a single madwifi/Ubiquiti-style compound token -- "11" + band ("ng"/"na")
-- + PHY and width ("ht20", "ht40", "vht80", "he80", ...). CONFIRMED live
-- 2026-07-18: a stock dual-band AP sends radio.1.ieee_mode=11nght20 (2.4GHz)
-- and radio.2.ieee_mode=11naht40 (5GHz), and flipping the per-device radio
-- setting Devices -> [AP] -> Settings -> Radios -> "2.4 GHz Channel Width"
-- from 20 to 40 changes exactly this key to 11nght40 (alongside
-- radio.<n>.cwm.mode 0->1, a redundant "channel width management" flag the
-- same width is already encoded in). This is the only channel-width signal on
-- the wire -- an earlier version of openUF parsed no mode key at all, so
-- ucihelper.rf_config()'s htmode mapping was unreachable and channel width
-- silently never applied despite USAGE.md claiming it did.
--
-- Returns an OpenWrt htmode string ("HT20"/"HT40"/"VHT80"/"HE80"/...), or nil
-- for an absent or unrecognized token, which leaves htmode unchanged (same
-- "absent -> nil -> leave alone" convention as channel/txpower above).
-- Longest suffix first: "eht"/"vht" must win over the "ht" they end with.
local _IEEE_MODE_PHY = {
	{ "eht", "EHT" }, { "vht", "VHT" }, { "he", "HE" }, { "ht", "HT" },
}
local _IEEE_MODE_WIDTHS = { ["20"] = true, ["40"] = true, ["80"] = true,
	["160"] = true, ["320"] = true }

local function _htmode_from_ieee_mode(ieee_mode)
	if type(ieee_mode) ~= "string" then return nil end
	-- The band ("ng"/"na"/...) between the "11" and the PHY is deliberately
	-- dropped: OpenWrt derives the band from the channel, and the controller
	-- can send channel=auto (leave as-is) while still naming a band here.
	local head, width = ieee_mode:match("^(11%a+)(%d+)$")
	if not (head and _IEEE_MODE_WIDTHS[width]) then return nil end
	for _, phy in ipairs(_IEEE_MODE_PHY) do
		local kind, prefix = phy[1], phy[2]
		if head:sub(-#kind) == kind then return prefix .. width end
	end
	return nil
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
-- Security derivation reads the akm set from aaa.<n>.wpa.key.<k>.mgmt (not
-- just aaa.<n>.wpa, which is only the WPA protocol version and stays "2"
-- even for a WPA2/WPA3 transition WLAN): SAE present -> sae/sae-mixed,
-- else WPA2-PSK. Confirmed live for the WPA2-PSK case (wpa=2 +
-- wpa.key.1.mgmt=WPA-PSK -> "wpa2"); the SAE branches are correct-by-
-- construction but not yet live-captured -- this environment's controller
-- signals WPA3-mixed via PMF for this madwifi model, never SAE key-mgmt.
local function _wire_bool(v)
	if v == nil then return nil end
	return v == "1" or v == "true" or v == "enabled"
end

function M._parse_wifi_system_cfg(sys_raw)
	local aaa, wireless, radio, stamgr, macacl = {}, {}, {}, {}, {}
	local qos_vap = {}
	for line in (sys_raw .. "\n"):gmatch("([^\n]*)\n") do
		-- qos.vap.<m>: "WiFi Speed Limit". Needs its own pattern rather than
		-- the generic <section>.<idx>.<key> one below, since the index sits a
		-- level down (qos.vap.1.*, alongside qos.if.<n>.* and qos.ebt.<n>.*).
		local qidx, qkey, qv = line:match("^qos%.vap%.(%d+)%.(.+)=(.*)$")
		if qidx then
			qidx = tonumber(qidx)
			qos_vap[qidx] = qos_vap[qidx] or {}
			qos_vap[qidx][qkey] = qv
		end
		local section, idx, key, v = line:match("^(aaa)%.(%d+)%.(.+)=(.*)$")
		if not section then section, idx, key, v = line:match("^(wireless)%.(%d+)%.(.+)=(.*)$") end
		if not section then section, idx, key, v = line:match("^(radio)%.(%d+)%.(.+)=(.*)$") end
		-- stamgr.<n>: per-radio "Station Manager" block, indexed the same as
		-- radio.<n> -- confirmed live 2026-07-14 (Devices -> [AP] -> Radios ->
		-- "Minimum RSSI" checkbox+slider, NOT a WLAN-level setting): toggling
		-- it emits stamgr.<n>.radio (band, "ng"/"na"), stamgr.<n>.minrssi.status
		-- and stamgr.<n>.minrssi.rssi, alongside an unrelated
		-- stamgr.<n>.loadbalance.status sub-feature sharing the same block.
		-- The whole block is simply absent when disabled (no explicit
		-- status=false), same convention as every other optional section here.
		if not section then section, idx, key, v = line:match("^(stamgr)%.(%d+)%.(.+)=(.*)$") end
		-- macacl.<m>: the "MAC Address Filter". CONFIRMED live 2026-07-18 by
		-- enabling the control with one allow-listed MAC and diffing system_cfg
		-- -- this whole top-level section appeared at once, and it is keyed by
		-- devname (ath0/ath2), NOT by the wireless.<n> index: only the two ath
		-- devices belonging to the filtered WLAN got blocks, numbered 1 and 2
		-- while the WLAN is wireless.1/wireless.3. Hence the devname join below.
		--
		-- The obvious-looking wireless.<n>.mac_acl.status/.policy keys are NOT
		-- this feature: they sit at enabled/deny with the control off and did
		-- not move in the diff -- the same decoy shape as
		-- radio.<n>.bcmc_l2_filter.status was for the broadcast blocker.
		-- aaa.<n>.radius.macacl.status is the separate RADIUS MAC
		-- Authentication control.
		if not section then section, idx, key, v = line:match("^(macacl)%.(%d+)%.(.+)=(.*)$") end
		if section then
			local tbl = (section == "aaa" and aaa) or (section == "wireless" and wireless)
				or (section == "radio" and radio) or (section == "macacl" and macacl) or stamgr
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
			local entry = {
				name     = r.phyname,
				channel  = tonumber(r.channel),   -- "auto" -> nil, leaves channel unchanged
				tx_power = tonumber(r.txpower),   -- "auto" -> nil, leaves tx_power unchanged
				-- nil for an absent/unrecognized token, leaving htmode alone.
				htmode   = _htmode_from_ieee_mode(r.ieee_mode),
			}
			local sm = stamgr[idx]
			-- minrssi.rssi is NOT plain dBm -- confirmed live: UI "-80 dBm"
			-- wire-encoded as 15, UI "-85 dBm" as 10 (a madwifi-driver
			-- convention, offset from an assumed -95 dBm noise floor: raw =
			-- dbm + 95). Kept as raw wire units here; converted to dBm only
			-- where a live noise-floor reading is available (apply_config/
			-- enforcement), not at parse time.
			if sm and sm["minrssi.status"] == "true" then
				entry.min_rssi_enabled = true
				entry.min_rssi         = tonumber(sm["minrssi.rssi"])
			end
			radio_table[#radio_table + 1] = entry
		end
	end

	-- MAC Address Filter, keyed by the vap's wire devname (ath0/ath1/...).
	-- Wire shape, all confirmed live 2026-07-18:
	--   macacl.status=enabled            -- global gate
	--   macacl.<m>.devname=ath0          -- join key
	--   macacl.<m>.status=enabled
	--   macacl.<m>.acl.status=enabled
	--   macacl.<m>.acl.policy=allow      -- allow|deny (UI "Filter Type")
	--   macacl.<m>.acl.<k>.mac=02:11:22:33:44:55
	--   macacl.<m>.acl.<k>.status=enabled
	--   macacl.<m>.acl.<k>.type=user
	-- Like bcfilt, <k> is 1-based and carries no meaning beyond grouping, so
	-- the list is sorted for a stable, comparable result. Entries are taken
	-- only when both the block and the entry are enabled; type is "user" for
	-- hand-entered MACs (the only kind this UI produces).
	local mac_filter_by_dev = {}
	for _, e in pairs(macacl) do
		if e.devname and e.status == "enabled" and e["acl.status"] == "enabled" then
			local macs = {}
			for k, val in pairs(e) do
				local ki = k:match("^acl%.(%d+)%.mac$")
				if ki and e["acl." .. ki .. ".status"] == "enabled" then
					macs[#macs + 1] = val
				end
			end
			table.sort(macs)
			mac_filter_by_dev[e.devname] = {
				policy = e["acl.policy"],
				macs   = macs,
			}
		end
	end

	-- "WiFi Speed Limit", keyed by the vap's wire devname -- same join as the
	-- MAC filter above. Wire shape, confirmed live 2026-07-18 by creating a
	-- speed-limit profile (33 Mbps down / 17 Mbps up) and assigning it to a
	-- WLAN:
	--   qos.status=enabled
	--   qos.vap.<m>.devname=ath0
	--   qos.vap.<m>.dwnlink.maxspeed=33000     -- kbps (UI Mbps x 1000)
	--   qos.vap.<m>.dwnlink.minspeed=33000
	--   qos.vap.<m>.uplink.1.maxspeed=17000    -- kbps
	--
	-- The discriminator is the presence of *maxspeed*, not qos.status (which
	-- is global) and not the block itself: an UNLIMITED vap still gets a
	-- qos.vap.<m> block, carrying only minspeed set to that radio's raw
	-- devspeed (570 on 2.4 GHz, 2400 on 5 GHz in the capture). Reading the
	-- block's existence as "limited" would cap every WLAN at its own PHY rate.
	--
	-- This is a per-VAP aggregate cap, not a per-client one: the limit applies
	-- to the whole netdev, which is what makes a single tc qdisc sufficient.
	--
	-- The accompanying qos.ebt.<n>.cmd entries are literal ebtables fragments
	-- the stock firmware would replay to fwmark each VAP. openUF implements
	-- the intent with tc instead (see shaper.lua) rather than replaying them.
	local ratelimit_by_dev = {}
	for _, q in pairs(qos_vap) do
		local down = tonumber(q["dwnlink.maxspeed"])
		local up   = tonumber(q["uplink.1.maxspeed"])
		if q.devname and (down or up) then
			ratelimit_by_dev[q.devname] = {down = down, up = up}
		end
	end

	local vap_table = {}
	for _, idx in ipairs(sorted_indices(wireless)) do
		local w = wireless[idx]
		local a = aaa[idx] or {}

		-- Aggregate every aaa.<n>.wpa.key.<k>.mgmt entry (transition mode can
		-- list WPA-PSK and SAE either space-joined on one key or across
		-- separate keys). Hoisted out of the security branch below because the
		-- WPA-Enterprise check needs it before anything else is decided.
		local akm = ""
		for k, val in pairs(a) do
			if k:match("^wpa%.key%.%d+%.mgmt$") then akm = akm .. " " .. val end
		end

		-- WPA-Enterprise (802.1X, mgmt "WPA-EAP"). openUF cannot provision it:
		-- the wire carries no RADIUS server/port/secret -- aaa.<n>.wpa.psk is
		-- simply absent -- and wlan_add() writes no auth_server/auth_secret.
		-- Left to fall through, an Enterprise WLAN matched neither the SAE nor
		-- the PSK branch and landed on security="wpa2", producing a psk2
		-- section with a nil key: a VAP hostapd refuses to bring up, with
		-- nothing logged anywhere. Skipping it loudly is strictly better -- a
		-- missing WLAN an admin can diagnose beats a broken one that looks
		-- provisioned.
		local is_enterprise = akm:find("EAP", 1, true) ~= nil
		if is_enterprise and w.ssid then
			io.stderr:write(("inform: skipping WLAN %q -- WPA-Enterprise (%s) is not "
				.. "supported; openUF has no RADIUS configuration on this wire protocol\n")
				:format(w.ssid, (akm:gsub("^%s+", ""))))
		end

		if w.ssid and w.parent and not is_enterprise then
			local security = "open"
			if a.wpa == "2" or a.wpa == "3" then
				local has_sae = akm:find("SAE", 1, true) ~= nil
				local has_psk = akm:find("PSK", 1, true) ~= nil
				if has_sae and has_psk then security = "wpa2/wpa3"
				elseif has_sae then security = "wpa3"
				elseif a.wpa == "3" then security = "wpa3"
				else security = "wpa2" end
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

			-- "Multicast and Broadcast Blocker" (REST bc_filter_enabled /
			-- bc_filter_list). CONFIRMED live 2026-07-18 by REST-toggling it
			-- and diffing system_cfg -- the whole block appeared at once:
			--   wireless.<n>.bcfilt.status=enabled
			--   wireless.<n>.bcfilt.<k>.mac=01:00:5e:00:00:fb
			--   wireless.<n>.bcfilt.<k>.status=enabled
			-- on BOTH band entries of the WLAN. <k> is 1-based and does NOT
			-- follow the REST list's order (adding a second MAC renumbered the
			-- first), so the index carries no meaning beyond grouping and the
			-- list is sorted here for a stable, comparable result.
			--
			-- Two candidate keys that were already on the wire turned out NOT
			-- to be this feature -- radio.<n>.bcmc_l2_filter.status (sits at
			-- enabled with the control off) and wireless.<n>.multicast.inspect
			-- -- neither moved in the diff.
			--
			-- bcfilt.status is emitted whenever the control is on, including
			-- with an empty allow-list; the per-entry keys only appear once
			-- the list is non-empty.
			local bcfilt_macs
			for k, val in pairs(w) do
				local idx = k:match("^bcfilt%.(%d+)%.mac$")
				if idx and _wire_bool(w["bcfilt." .. idx .. ".status"]) then
					bcfilt_macs = bcfilt_macs or {}
					bcfilt_macs[#bcfilt_macs + 1] = val
				end
			end
			if bcfilt_macs then table.sort(bcfilt_macs) end

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
				-- aaa.<n>.bss_transition: CONFIRMED live 2026-07-15 (toggled
				-- "BSS Transition (802.11v)" in the Behavior Controls panel,
				-- diffed system_cfg via debug_dump_file) -- present on every
				-- aaa.<n> block for the WLAN, "enabled"/"disabled" string,
				-- flips independently of Fast Roaming/other toggles. Maps
				-- 1:1 onto hostapd/UCI's own current option name -- no
				-- translation needed, unlike the deprecated ieee80211v
				-- alias ucihelper used to (incorrectly) emit.
				bss_transition        = _wire_bool(a.bss_transition),
					-- aaa.<n>.pmf.status / pmf.mode: 802.11w Protected
					-- Management Frames. CONFIRMED live 2026-07-18 (Humans+IoT
					-- validation, diffed system_cfg via debug_dump_file): the
					-- controller always emits these on the aaa.<n> block --
					-- status="enabled"/"disabled", mode=0|1|2 (0=disabled,
					-- 1=optional, 2=required, mapping 1:1 onto hostapd's
					-- ieee80211w). For a "WPA2/WPA3" mixed WLAN on this madwifi
					-- model the WPA3-transition intent is carried entirely by
					-- these fields (wpa stays =2, wpa.key.1.mgmt stays WPA-PSK),
					-- so dropping them silently collapsed mixed-mode to plain
					-- WPA2 -- the reason this WLAN got no PMF at all before.
					-- pmf.cipher (AES-128-CMAC) is not carried through:
					-- hostapd's default BIP group-mgmt cipher already is
					-- AES-128-CMAC, so there is nothing to translate.
					pmf_status            = a["pmf.status"],
					pmf_mode              = tonumber(a["pmf.mode"]),
					-- wireless.<n>.mcast.enhance: "Multicast Enhancement" /
					-- "Multicast to Unicast" -- CONFIRMED live 2026-07-18
					-- (Humans+IoT validation): the controller sends =1 on the
					-- toggled WLAN's wireless.<n> entries and =0 elsewhere;
					-- openUF read wireless.<n> but never this key, so no
					-- multicast_to_unicast reached hostapd. (It rides the same
					-- wireless.<n> block as dtim_period/no2ghz_oui -- an earlier
					-- draft misread the "\nwireless.<n>." dump text as a
					-- separate "nwireless" section; the leading n is just the
					-- escaped newline before the wireless key.) 0|1 on the
					-- wire, so _wire_bool handles it directly.
					mcast_enhance         = _wire_bool(w["mcast.enhance"]),
				-- wireless.<n>.dtim_period: CONFIRMED live 2026-07-15 --
				-- always present as a plain integer regardless of the
				-- WLAN's Auto/Custom DTIM toggle (toggling "Auto 802.11
				-- DTIM Period" off and setting a custom 2.4/5GHz value only
				-- changed this same field's value; there is no separate
				-- dtim_mode/dtim_ng/dtim_na key on the wire at all -- an
				-- earlier version of this parser guessed such a scheme and
				-- was wrong). Maps 1:1 onto hostapd/UCI's own
				-- wifi-iface.dtim_period option.
				dtim_period           = tonumber(w.dtim_period),
				-- wireless.<n>.iot / wireless.<n>.qbssload: "Force WiFi 4
				-- Mode" (Settings -> WiFi -> [WLAN] -> IoT Optimization,
				-- REST field enhanced_iot). CONFIRMED live 2026-07-18 by
				-- diffing system_cfg across the toggle: both keys are
				-- absent entirely when it is off, and appear together as
				-- iot=enabled + qbssload=disabled on the WLAN's 2.4GHz
				-- wireless.<n> entry when it is on.
				--
				-- Most of what this feature *does* is encoded by the
				-- controller in keys openUF already applies -- the same
				-- diff showed the WLAN's 5GHz vap removed outright
				-- (wlan_bands forced to 2.4GHz-only), security pinned to
				-- WPA2, and bss_transition/proxy_arp/no2ghz_oui/PMF/
				-- advertise_ap_name all forced off. Notably the parent
				-- radio is NOT touched: radio.<n>.ieee_mode stayed at the
				-- site's configured width (verified by turning this on
				-- with the 2.4GHz radio at HT40 -- it stayed 11nght40), so
				-- this is a per-BSS flag only and must not be reflected
				-- back onto the shared radio.
				--
				-- That leaves qbssload as its one distinct on-air effect:
				-- suppress the QBSS Load information element in this
				-- BSS's beacons, which some legacy clients mis-parse.
				iot                   = _wire_bool(w.iot),
				qbssload              = _wire_bool(w.qbssload),
				-- wireless.<n>.no2ghz_oui: CONFIRMED live 2026-07-15 --
				-- this, not a per-device mgmt_cfg key, is Band Steering's
				-- real wire representation (toggled "Band Steering" in the
				-- Behavior Controls panel with nothing else changed; only
				-- this field flipped, and only on the WLAN's 2.4GHz/radio0
				-- wireless.<n> entry -- a madwifi/QCA driver convention:
				-- omitting the AP's OUI from 2.4GHz beacons/probe responses
				-- nudges dual-band-capable clients toward 5GHz). An
				-- earlier version of this parser guessed a per-device
				-- Device.BandsteeringMode-style mgmt_cfg field (per
				-- paultyng/go-unifi's REST model) that does not exist on
				-- this wire protocol at all -- see PROTOCOL-VALIDATION.md.
				no2ghz_oui            = _wire_bool(w.no2ghz_oui),
				-- wireless.<n>.advertise_ap_name: "Show Access Point Name
				-- in Beacon". CONFIRMED via decompiling the controller's
				-- WLAN-config-generator method directly (not a live diff
				-- -- a live capture showed zero effect from this toggle
				-- until the wifi_caps2 capability bit above was added,
				-- since the controller only emits this key at all when
				-- Device.supportAdvertisingDeviceNameInBeacon() is true;
				-- see that field's comment in build_json for the full
				-- derivation). "enabled"/"disabled" string, same
				-- convention as bss_transition/no2ghz_oui.
				advertise_ap_name     = _wire_bool(w.advertise_ap_name),
				-- aaa.<n>.sae.anti_clogging / aaa.<n>.sae.sync: "SAE
				-- Anti-clogging"/"SAE Sync Time" (WPA3-SAE tuning).
				-- CONFIRMED via decompiling the controller's WLAN-config-
				-- generator (a small SAE-specific helper class): both are
				-- plain integers, only emitted when > 0 (the controller's
				-- own admin-side default is 5 for each), and -- unlike
				-- every other field on this vap -- gated on the WLAN
				-- actually being in real WPA3/SAE mode (Wlan.isWpa3() --
				-- an admin-facing "wpa3_support" flag, NOT the same thing
				-- as the "WPA2/WPA3" mixed Security Protocol dropdown
				-- option -- or a 6GHz radio, not a device capability like
				-- advertise_ap_name above). Live-tested: a WPA2/WPA3
				-- mixed-mode WLAN never emits either key even with a
				-- non-default admin value saved server-side, confirming
				-- the gate. Could not live-confirm the emitting (pure
				-- WPA3) case end-to-end -- switching this validation
				-- environment's test WLAN to pure WPA3 tripped an
				-- unrelated, already-documented config-sync flakiness
				-- (see PROTOCOL-VALIDATION.md) where the controller
				-- stopped pushing the WLAN's aaa./wireless. blocks
				-- entirely, even across an inform.lua restart. High
				-- confidence from the decompiled method body alone
				-- (a simple getInt(key, -1) > 0 check, no ambiguity).
				sae_anti_clogging     = tonumber(a["sae.anti_clogging"]),
				sae_sync              = tonumber(a["sae.sync"]),
					-- aaa.<n>.proxy_arp: "Proxy ARP". CONFIRMED live
					-- 2026-07-18 by REST-toggling wlanconf.proxy_arp and
					-- diffing system_cfg -- exactly aaa.<n>.proxy_arp flipped
					-- disabled->enabled, on both the 2.4GHz and 5GHz entries
					-- of the WLAN and nothing else. Always present on every
					-- aaa.<n> block (like bss_transition), never absent, so
					-- the "disabled" case is explicit rather than implied.
					-- Maps 1:1 onto hostapd/OpenWrt's own proxy_arp option.
					proxy_arp             = _wire_bool(a.proxy_arp),
					-- wireless.<n>.l2_isolation: "Client Isolation" (blocks
					-- station-to-station traffic within the BSS). CONFIRMED
					-- live 2026-07-18 in the same diff as proxy_arp above --
					-- flipped disabled->enabled on both band entries, nothing
					-- else moved. Always present. Maps onto OpenWrt's
					-- "isolate" (hostapd ap_isolate).
					l2_isolation          = _wire_bool(w.l2_isolation),
					-- wireless.<n>.hide_ssid: "Hide WiFi Name" -- suppress the
					-- SSID from beacons. CONFIRMED live 2026-07-18 by toggling
					-- the control in the UI and diffing system_cfg: exactly
					-- aaa.<n>.hide_ssid and wireless.<n>.hide_ssid flipped
					-- false->true, on both band entries of the WLAN, nothing
					-- else moved. The two keys are redundant duplicates; the
					-- wireless.<n> one is read here to keep this next to the
					-- other wireless.<n> booleans.
					--
					-- Note the value vocabulary is "true"/"false" here, not the
					-- "enabled"/"disabled" most of these keys use -- _wire_bool
					-- accepts both. Always present, so "off" is explicit and
					-- must be written back out as such. Maps onto OpenWrt's
					-- wifi-iface "hidden" (hostapd ignore_broadcast_ssid).
					hide_ssid             = _wire_bool(w.hide_ssid),
					-- "MAC Address Filter", joined from the top-level macacl
					-- section on wireless.<n>.devname (see mac_filter_by_dev
					-- above for the wire shape and why the join is needed).
					-- Both are nil when the control is off for this vap, which
					-- the consumer turns into macfilter=disable.
					mac_filter_policy     = (mac_filter_by_dev[w.devname] or {}).policy,
					mac_filter_list       = (mac_filter_by_dev[w.devname] or {}).macs,
					-- "WiFi Speed Limit", in kbps, nil when unlimited.
					ratelimit_down_kbps   = (ratelimit_by_dev[w.devname] or {}).down,
					ratelimit_up_kbps     = (ratelimit_by_dev[w.devname] or {}).up,
					-- "Minimum Data Rate Control" (Settings -> WiFi -> [WLAN]).
					-- CONFIRMED live 2026-07-18 by REST-setting
					-- minrate_setting_preference=manual + minrate_ng_enabled +
					-- minrate_ng_data_rate_kbps=12000 and diffing system_cfg:
					--   minrate_data     1000 -> 12000   (kbps -- 12 Mbps)
					--   beacon_rate      1000 -> 12000
					--   mgmt_rate        1000 -> 12000
					--   minrate_cck_rates.status  true -> false
					--   pureg            0    -> 1
					-- i.e. beacon_rate/mgmt_rate simply mirror minrate_data, and
					-- the CCK/pureg pair are derived consequences (12 Mbps is an
					-- OFDM rate, so every CCK rate falls below the floor and
					-- 802.11b clients are excluded outright).
					--
					-- Per-band, and NOT band-gated: the 5 GHz entries carried
					-- none of these keys at first only because that band's
					-- minrate was disabled. Enabling minrate_na (24 Mbps) made
					-- minrate_data/beacon_rate/mgmt_rate appear on the radio1
					-- entries too, with no cck/pureg keys (2.4 GHz-only
					-- concepts). So the controller has already done the band
					-- math and this side needs no band awareness.
					--
					-- Nothing is emitted at all when that band's Minimum Data
					-- Rate is off, so absent -> nil -> leave the radio alone.
					minrate_data          = tonumber(w.minrate_data),
					minrate_cck           = _wire_bool(w["minrate_cck_rates.status"]),
					beacon_rate           = tonumber(w.beacon_rate),
					-- wireless.<n>.minrate_below_disable: the "advertising
					-- rates" sub-toggle (REST minrate_<band>_advertising_rates).
					-- CONFIRMED live in its own diff -- turning it on added
					-- exactly this key (=true) to both band entries and changed
					-- nothing else. Distinguishes "make the floor a basic rate"
					-- (association still requires it) from "also stop
					-- advertising every rate below the floor".
					minrate_below_disable = _wire_bool(w.minrate_below_disable),
					-- See the bcfilt derivation above the vap literal.
					bcfilt_enabled        = _wire_bool(w["bcfilt.status"]),
					bcfilt_macs           = bcfilt_macs,
			}
		end
	end

	return radio_table, vap_table
end

-- ─── Dropped-key visibility ──────────────────────────────────────────────────

-- Key shapes some pass in openUF actually reads. Everything else in a config
-- blob is dropped on the floor.
--
-- Until 2026-07-18 that included macacl.* and qos.vap.* -- two whole features
-- sitting in every capture, unnoticed for months, because no tokenizer here
-- has an `else` branch and nothing ever counted what fell through. This list
-- plus _report_dropped_keys() is the missing feedback loop.
--
-- The keys openUF drops ON PURPOSE (switch.*, qos.if.*, qos.ebt.*, vlan.*,
-- bridge.*, mcastrate, cwm.mode, pmf.cipher, mac_acl.* and the other decoys)
-- are deliberately NOT listed here: they show up in the report, which is the
-- honest picture of what is ignored. Each one's reasoning is in
-- PROTOCOL-VALIDATION.md's `system_cfg` section.
local RECOGNIZED_SYSTEM_CFG = {
	"^aaa%.%d+%.",       -- per-SSID security
	"^wireless%.%d+%.",  -- per-SSID radio binding and behavior
	"^radio%.%d+%.",     -- per-radio config
	"^stamgr%.%d+%.",    -- Minimum RSSI
	"^macacl%.%d+%.",    -- MAC Address Filter
	"^qos%.vap%.%d+%.",  -- WiFi Speed Limit
	"^netconf%.1%.",     -- IP Settings
	"^route%.1%.gateway$",
	"^dhcpc%.1%.",
	"^resolv%.nameserver%.%d+%.ip$",
	"^resolv%.host%.1%.name$",
}

local RECOGNIZED_MGMT_CFG = {
	"^inform_url$", "^use_aes_gcm$", "^cfgversion$", "^led_enabled$", "^authkey$",
}

-- Set from handle_response when cfg.config.debug_dump_file is on -- the
-- dropped-key report is a diagnostic for exactly the same workflow (diffing
-- full captures against what openUF acts on), so it shares that gate rather
-- than adding a second knob.
M._debug_dropped_keys = false

-- Summarize the keys in a config blob that no pass recognized.
--
-- Emits key PREFIXES and counts only, never values: these blobs carry
-- aaa.<n>.wpa.psk and mgmt_cfg's authkey, and this goes to the log.
-- Numeric indices are collapsed to <n> so a four-VAP blob reports one line
-- per key shape rather than one per instance.
function M._report_dropped_keys(label, raw, recognized)
	if not M._debug_dropped_keys or type(raw) ~= "string" then return end
	local counts, order, total = {}, {}, 0
	for line in (raw .. "\n"):gmatch("([^\n]*)\n") do
		-- Skip blanks and the literal comment a radio-less blob carries
		-- ("# no wlan provisioned as no radio found").
		if line ~= "" and not line:match("^%s*#") then
			local k = line:match("^([^=]+)=")
			if k then
				local known = false
				for _, pat in ipairs(recognized) do
					if k:match(pat) then known = true break end
				end
				if not known then
					local prefix = k:gsub("%.%d+%.", ".<n>."):gsub("%.%d+$", ".<n>")
					if not counts[prefix] then
						counts[prefix] = 0
						order[#order + 1] = prefix
					end
					counts[prefix] = counts[prefix] + 1
					total = total + 1
				end
			end
		end
	end
	if total == 0 then return end
	table.sort(order)
	local parts = {}
	for _, p in ipairs(order) do parts[#parts + 1] = p .. " x" .. counts[p] end
	io.stderr:write(("inform: %s: %d dropped key(s): %s\n")
		:format(label, total, table.concat(parts, ", ")))
end

-- ─── Response dispatcher ─────────────────────────────────────────────────────

-- Handle a parsed controller response JSON string.
-- st:  current state table
-- cfg: device configuration (from conf.lua; optional -- nil in tests, LED
--      control becomes a no-op without cfg.led)
-- Returns true if config was applied (caller should send follow-up inform).
function M.handle_response(json_str, st, cfg)
	-- Tracks the config rather than latching on: a caller that stops passing
	-- debug_dump_file stops getting dropped-key reports too.
	M._debug_dropped_keys = not not (cfg and cfg.config and cfg.config.debug_dump_file)

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
					if k == "inform_url" then
						-- NOT "mgmt_url" -- confirmed live against a real controller
						-- (2026-07-14) that mgmt_url is the web UI deep link
						-- (https://host:8443/manage/site/default), a completely
						-- different endpoint from the actual inform target.
						-- Aliasing the two here previously made the device
						-- overwrite its own working inform_url with the UI link on
						-- the very next routine setparam cycle after adoption,
						-- breaking the inform loop for good (http-only builds have
						-- no luasec, so switching to that https URL is fatal).
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
		M._report_dropped_keys("mgmt_cfg", mgmt_raw, RECOGNIZED_MGMT_CFG)

		local sys_raw = resp.system_cfg
		if type(sys_raw) == "string" then
			M._report_dropped_keys("system_cfg", sys_raw, RECOGNIZED_SYSTEM_CFG)

			local ip, netmask, gateway
			local dhcp = false
			local device_name
			-- DNS servers, keyed by their wire index so the controller's
			-- ordering (primary/secondary) survives -- resolv.conf's order is
			-- the resolver's preference order, so it is load-bearing. Same
			-- index-keyed-then-sorted treatment as macacl's acl.<k> list.
			local dns_by_idx = {}
			for line in (sys_raw .. "\n"):gmatch("([^\n]*)\n") do
				local k, v = line:match("^([^=]+)=(.*)$")
				if k and v then
					local dns_idx = k:match("^resolv%.nameserver%.(%d+)%.ip$")
					if dns_idx then
						if v ~= "" then dns_by_idx[tonumber(dns_idx)] = v end
					elseif k == "netconf.1.ip" then ip = v
					elseif k == "netconf.1.netmask" then netmask = v
					elseif k == "route.1.gateway" then gateway = v
					elseif k == "dhcpc.1.status" then dhcp = true
					elseif k == "resolv.host.1.name" then
						-- The controller's own idea of this device's name
						-- (its local network hostname) -- already present
						-- in every capture (e.g. "U6IW" when never
						-- renamed). Reused as the WPS Device Name value
						-- when advertise_ap_name is on, since it's the
						-- only controller-assigned "AP name" string
						-- available on this wire protocol.
						if v ~= "" then device_name = v end
					end
				end
			end
			-- Flatten the index-keyed DNS table into controller order.
			local dns = {}
			do
				local idxs = {}
				for i in pairs(dns_by_idx) do idxs[#idxs + 1] = i end
				table.sort(idxs)
				for _, i in ipairs(idxs) do dns[#dns + 1] = dns_by_idx[i] end
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
					-- DNS is deliberately NOT touched here: the lease supplies
					-- it, and rewriting resolv.conf on every steady-state "still
					-- DHCP" push would fight the DHCP client for ownership --
					-- the same hazard as the flush+re-lease guarded above.
					st.static_dns = nil
				else
					st.ip_mode = "static"
					st.static_ip, st.static_netmask, st.static_gateway = ip, netmask, gateway
					st.static_dns = (#dns > 0) and dns or nil
					if M._netconfig.apply_static(iface, ip, netmask, gateway, dns) then
						st.ip = ip  -- known directly, no need to re-read the interface
					end
				end
			end

			local ufuci = M._ucihelper
			if ufuci and ufuci.apply_config then
				local radio_table, vap_table = M._parse_wifi_system_cfg(sys_raw)
				if #radio_table > 0 or #vap_table > 0 then
					-- Band Steering (wireless.<n>.no2ghz_oui) is confirmed
					-- live to be a per-WLAN wire field, not a per-device
					-- one -- but usteer (the daemon that actually
					-- implements steering on OpenWrt) is a single
					-- device-wide config, so band steering is treated as
					-- active for the whole device whenever ANY WLAN has it
					-- enabled.
					local steering_active = false
					for _, vap in ipairs(vap_table) do
						if vap.no2ghz_oui then steering_active = true end
					end
					M._usteer.set_enabled(steering_active, cfg)
					pcall(ufuci.apply_config,
						{radio_table = radio_table, vap_table = vap_table, network_table = {}},
						cfg, {band_steering_active = steering_active, device_name = device_name})
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
		M._firewall.reconcile(st.blocked_stas)
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
		elseif cmd == "block-sta" or cmd == "unblock-sta" then
			-- One-shot command, confirmed live: block/unblock never appears
			-- as a persistent field on any inform response (a candidate
			-- top-level `include_blocks` list stays empty even while a
			-- client is genuinely blocked) -- the device itself is expected
			-- to remember the block, the same way real hardware would.
			-- Persisted in state.blocked_stas and re-applied at M.run()
			-- startup (M._firewall.reconcile), so it survives a restart.
			local mac = resp.mac
			if type(mac) == "string" then
				st.blocked_stas = st.blocked_stas or {}
				if cmd == "block-sta" then
					local already = false
					for _, m in ipairs(st.blocked_stas) do
						if m == mac then already = true break end
					end
					if not already then
						st.blocked_stas[#st.blocked_stas + 1] = mac
					end
				else
					local kept = {}
					for _, m in ipairs(st.blocked_stas) do
						if m ~= mac then kept[#kept + 1] = m end
					end
					st.blocked_stas = kept
				end
				M._state.save(st)
				M._firewall.reconcile(st.blocked_stas)
				if cmd == "block-sta" then
					-- Kick it immediately if it's currently associated --
					-- the nft drop rule alone stops future traffic, but
					-- doesn't tear down an existing association.
					local ufuci = M._ucihelper
					if ufuci and ufuci.get_radio_table then
						local ok_r, radios = pcall(ufuci.get_radio_table)
						if ok_r then
							local ifnames = {}
							for _, radio in ipairs(radios) do
								local ok_if, ifname = pcall(ufuci.get_ifname_for_radio, radio.name)
								if ok_if and ifname then ifnames[#ifnames + 1] = ifname end
							end
							M._firewall.deauth(mac, ifnames)
						end
					end
				end
			end
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
			-- PROTOCOL-VALIDATION.md's radio_table_stats reference), not
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

	-- Config update: check cfgversion. WiFi config itself is applied from
	-- system_cfg above, not here -- a real controller never sends the
	-- resp.vap_table/radio_table/network_table JSON this branch used to gate
	-- on, so all that is left to do is record the version we have caught up to.
	if type(resp.cfgversion) == "string" and resp.cfgversion ~= st.cfgversion then
		st.cfgversion = resp.cfgversion
		M._state.save(st)
		return true  -- signal: send follow-up inform immediately
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
	M._firewall.reconcile(st.blocked_stas)
	return mtime
end

-- Start the inform heartbeat loop (blocks forever).
-- cfg, ufhw: passed through to build_json()
function M.run(cfg, ufhw)
	local st = state.load()
	M._populate_net_info(st, cfg)
	M._sync_bootstrap_account(st.adopted, cfg and cfg.config and cfg.config.bootstrap_adopt_user)
	-- Blocked-client nft rules are live kernel state, not persisted UCI --
	-- reapply from state.json on every fresh start (mirrors the bootstrap
	-- account reconciliation just above).
	M._firewall.reconcile(st.blocked_stas)

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
