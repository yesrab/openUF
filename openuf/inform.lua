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
	return {
		band   = function(a, b) return a & b  end,
		bor    = function(...) local r = 0; for i = 1, select('#', ...) do r = r | select(i, ...) end; return r end,
		bxor   = function(a, b) return a ~ b  end,
		lshift = function(a, b) return a << b end,
		rshift = function(a, b) return a >> b end,
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

local crypto  = _require_sibling("crypto")
local state   = _require_sibling("state")
local sysinfo = _require_sibling("sysinfo")
local lldp    = _require_sibling("lldp")

local M = {}

-- Injectable: expose internal state module so tests can redirect state._state_file
M._state = state

-- Packet constants
local MAGIC        = "TNBU"
local PKT_VERSION  = 0
local DATA_VERSION = 1

-- Inform flags
local FLAG_ENCRYPTED  = 0x01
local FLAG_COMPRESSED = 0x02
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

-- ─── Packet builder ──────────────────────────────────────────────────────────

-- Build a TNBU binary packet from a JSON string.
-- st: state table (for authkey, adopted)
-- use_gcm: force GCM instead of CBC (auto-detected from controller hint otherwise)
function M.build_packet(json_str, st, use_gcm)
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

	-- Choose encryption mode
	local iv = crypto.random_iv(16)
	local ciphertext
	if use_gcm and crypto.gcm_available() then
		local ct, tag = crypto.aes_gcm_encrypt(st.authkey, iv, payload)
		-- Append 16-byte GCM auth tag to ciphertext
		ciphertext = ct .. tag
		flags = bit.bor(flags, FLAG_GCM)
	else
		ciphertext = crypto.aes_cbc_encrypt(st.authkey, iv, payload)
	end

	-- Get MAC from state or fall back to all-zeros
	local mac_bin = mac_bytes(st.mac or "00:00:00:00:00:00")

	-- Assemble header + payload
	return MAGIC
		.. uint32_be(PKT_VERSION)
		.. mac_bin
		.. uint16_be(flags)
		.. iv
		.. uint32_be(DATA_VERSION)
		.. uint32_be(#ciphertext)
		.. ciphertext
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
			-- Last 16 bytes of payload are the GCM auth tag
			local ct  = payload:sub(1, #payload - 16)
			local tag = payload:sub(#payload - 15)
			payload = crypto.aes_gcm_decrypt(key, iv, ct, tag)
		else
			payload = crypto.aes_cbc_decrypt(key, iv, payload)
		end
	end

	-- Decompress
	if bit.band(flags, FLAG_COMPRESSED) ~= 0 then
		local ok_zlib, zlib = pcall(require, "zlib")
		if ok_zlib and zlib.decompress then
			payload = zlib.decompress(payload)
		else
			error("inform: controller sent compressed response but lua-lzlib not installed")
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
	local uptime   = sysinfo.uptime()
	local meminfo  = sysinfo.meminfo()
	local ifaces   = sysinfo.interfaces()
	local lldp_nbrs = lldp.neighbors()

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
	local radio_table = {}
	local vap_table   = {}

	-- Try to load ufuci if available for VAP/radio info
	local ok_uci, ufuci = pcall(_require_sibling, "ucihelper")
	if ok_uci and ufuci.get_vap_table then
		vap_table   = ufuci.get_vap_table()
		radio_table = ufuci.get_radio_table()
	end

	-- lldp_table
	local lldp_table = {}
	for _, nbr in ipairs(lldp_nbrs) do
		lldp_table[#lldp_table + 1] = {
			chassis_id  = nbr.chassis_id,
			port_id     = nbr.port_id,
			system_name = nbr.system_name,
			port        = nbr.port,
		}
	end

	local mac_str = st.mac or "00:00:00:00:00:00"

	local payload = {
		_type            = "state",
		["default"]      = not st.adopted,
		["state"]        = st.adopted and 1 or 0,
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
		version          = (uap.fw and uap.fw.pre or "U6IW.")
		                   .. (uap.fw and uap.fw.ver or "6.6.55"),
		required_version = uap.required_version or "6.0.0",
		bootrom_version  = uap.bootver or "",
		country_code     = st.country_code or 840,
		mem_total        = meminfo.total_kb * 1024,
		mem_free         = meminfo.free_kb  * 1024,
		if_table         = if_table,
		radio_table      = radio_table,
		vap_table        = vap_table,
		lldp_table       = lldp_table,
	}

	return cjson.encode(payload)
end

-- ─── Response dispatcher ─────────────────────────────────────────────────────

-- Handle a parsed controller response JSON string.
-- Returns true if config was applied (caller should send follow-up inform).
function M.handle_response(json_str, st)
	local ok, resp = pcall(cjson.decode, json_str)
	if not ok or type(resp) ~= "table" then
		return false
	end

	local _type = resp._type

	if _type == "noop" then
		return false
	end

	if _type == "setparam" then
		-- Handle mgmt sub-parameters from setparam response
		local mgmt = resp.mgmt_cfg
		if type(mgmt) == "table" then
			-- Update inform_url if provided
			if type(mgmt.server) == "string" and mgmt.server ~= "" then
				local port = mgmt.port or "8080"
				st.inform_url = "http://" .. mgmt.server .. ":" .. tostring(port) .. "/inform"
			elseif type(mgmt.inform_url) == "string" and mgmt.inform_url ~= "" then
				st.inform_url = mgmt.inform_url
			end
			-- NOTE: authkey is NEVER updated from setparam (Fix #1 from findings doc).
			-- The only legitimate path for authkey is via the set-adopt shell command.
		end
		M._state.save(st)
		return false
	end

	if _type == "cmd" then
		local cmd = resp.cmd
		if cmd == "reboot" then
			os.execute("reboot")
		end
		return false
	end

	-- Config update: check cfgversion
	if type(resp.cfgversion) == "string" and resp.cfgversion ~= st.cfgversion then
		local ok_uci, ufuci = pcall(_require_sibling, "ucihelper")
		if ok_uci and resp.network_table then
			local ok_apply = pcall(ufuci.apply_config, resp)
			if ok_apply then
				st.cfgversion = resp.cfgversion
				M._state.save(st)
				return true  -- signal: send follow-up inform immediately
			end
		elseif ok_uci and resp.cfgversion then
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
	local host, port, path = url:match("^https?://([^:/]+):?(%d*)(.*)")
	if not host then return nil, "invalid URL: " .. tostring(url) end
	port = tonumber(port) or 8080
	if path == "" then path = "/inform" end

	local socket = require("socket")
	local tcp = socket.tcp()
	tcp:settimeout(10)
	local ok, err = tcp:connect(host, port)
	if not ok then
		tcp:close()
		return nil, "connect failed: " .. tostring(err)
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

	-- Read response (HTTP/1.0 — server closes after response)
	local response = {}
	while true do
		local chunk, recv_err = tcp:receive(4096)
		if chunk then
			response[#response + 1] = chunk
		else
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

-- Start the inform heartbeat loop (blocks forever).
-- cfg, ufhw: passed through to build_json()
function M.run(cfg, ufhw)
	local st = state.load()

	-- Populate MAC and IP into state for JSON builder
	local ok_ann, announce = pcall(_require_sibling, "announce")
	if ok_ann then
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

	local socket   = require("socket")
	local interval = 10
	local backoff  = interval
	local use_gcm  = false  -- updated based on controller response flags

	while true do
		local json_str = M.build_json(st, cfg, ufhw)
		local pkt      = M.build_packet(json_str, st, use_gcm)
		local body, err = M.http_post(st.inform_url, pkt)

		if not body then
			io.stderr:write("inform: POST failed: " .. tostring(err) .. "\n")
			backoff = math.min(backoff * 2, 60)
			socket.select(nil, nil, backoff)
		else
			backoff = interval
			local resp_json, resp_flags = pcall(M.parse_packet, body, st)
			if resp_flags then
				-- Auto-detect GCM from controller response flags
				if bit.band(resp_flags, FLAG_GCM) ~= 0 then
					use_gcm = true
				end
			end
			local json_ok, json_body
			if type(resp_json) == "string" then
				json_ok  = true
				json_body = resp_json
			end
			if json_ok then
				local need_followup = M.handle_response(json_body, st)
				if need_followup then
					-- Send another inform immediately after config apply
				else
					socket.select(nil, nil, interval)
				end
			else
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
		M.run(dev.conf, ufhw)
	end)
	if not ok then
		io.stderr:write("inform: " .. tostring(err) .. "\n")
		os.exit(1)
	end
end

return M
