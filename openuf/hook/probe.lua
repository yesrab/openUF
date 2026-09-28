--[[
	`openuf probe status|presets|discover|export`: what the web UI
	(luci-app-openuf) and any other front end read, as one JSON document on
	stdout.

	The daemon is the only thing that knows how the configuration resolves --
	which preset `modelmap 'auto'` picks, what a custom map came out as, which
	identity file is in play -- so the UI must not re-derive any of it. This
	script loads the configuration exactly as the daemons do (conf.lua, then
	/etc/config/openuf on top when it has a main section, see uciconf.lua)
	and describes the result, together with the state file (authkey never),
	the health file _tick rewrites after every cycle, the unhandled ledger's
	size and the provisioned WLANs. A configuration that does not load is
	reported as `config_error`, not as an exit: the overview page has to be
	able to say WHY the service is not running.

	Runs from the install directory, which is how `openuf probe` invokes it;
	the module functions take everything through seams so the tests need no
	device.
]]--

local M = {}

M._read_file = function(path)
	local f = io.open(path, "r")
	if not f then return nil end
	local s = f:read("*a")
	f:close()
	return s
end

M._list_dir = function(dir)
	local names = {}
	local p = io.popen("ls " .. dir .. " 2>/dev/null")
	if not p then return names end
	for line in p:lines() do
		local name = line:match("^(.+)%.lua$")
		if name then names[#names + 1] = name end
	end
	p:close()
	table.sort(names)
	return names
end

M._modelmap_dir    = "modelmap"
M._ufmodel_dir     = "ufmodel"
M._status_file     = "/tmp/openuf-status"
M._board_name_file = "/tmp/sysinfo/board_name"
M._version_file    = "VERSION"
M._build_file      = "BUILD"
M._time            = os.time

-- The provisioned WLANs, through ucihelper on a device; stubbed in tests.
M._vaps = function()
	local ok, uh = pcall(dofile, "ucihelper.lua")
	if not ok then return {} end
	local ok2, vaps = pcall(uh.get_vap_table)
	return ok2 and type(vaps) == "table" and vaps or {}
end

local WARN = string.char(226, 154, 160)   -- U+26A0, the ⚠ the map headers carry

local function trim(s) return (s:gsub("^%s+", ""):gsub("%s+$", "")) end

-- Line 2 of a preset's header comment is its title, the way setup.sh's menu
-- shows it: "JioRouter AX6000 JIDU6101 hardware profile." / "U6-InWall
-- device identity." The suffix is dropped, the ⚠ anywhere in the header
-- means "not verified on real hardware".
local function header_of(src)
	local title, unverified = nil, false
	if type(src) ~= "string" then return nil, false end
	local header = src:match("^%-%-%[%[(.-)%]%]") or ""
	local second = header:match("^[^\n]*\n([^\n]*)")
	if second then
		title = trim(second):gsub("%s+hardware profile%.$", ""):gsub("%s+device identity%.$", "")
		if title == "" then title = nil end
	end
	if header:find(WARN, 1, true) then unverified = true end
	return title, unverified
end

local function board_name()
	local s = M._read_file(M._board_name_file)
	return s and trim(s) or nil
end

local function load_preset(dir, name)
	local ok, t = pcall(dofile, dir .. "/" .. name .. ".lua")
	if ok and type(t) == "table" then return t end
	return nil
end

-- ─── presets ────────────────────────────────────────────────────────────────

function M.presets()
	local board = board_name()
	local out = {board = board, auto = nil, modelmaps = {}, ufmodels = {}}
	for _, name in ipairs(M._list_dir(M._modelmap_dir)) do
		local src = M._read_file(M._modelmap_dir .. "/" .. name .. ".lua")
		local title, unverified = header_of(src)
		local dev = load_preset(M._modelmap_dir, name)
		local entry = {name = name, title = title or name, unverified = unverified,
			boards = dev and dev.openwrt_boards or {}}
		if dev then
			entry.ufmodel = dev.openuf and dev.openuf.uap and dev.openuf.uap.ufmodel
			entry.dsa = dev.conf and dev.conf.net and dev.conf.net.uplink_detect ~= nil
			entry.lan_cpueth = dev.conf and dev.conf.net and dev.conf.net.lan_cpueth
			entry.hwassign = dev.openuf and dev.openuf.uap and dev.openuf.uap.hwassign
			entry.led = type(dev.conf and dev.conf.led) == "table" and dev.conf.led.sysfs or (dev.conf and dev.conf.led)
			entry.ports = {}
			for _, p in ipairs(dev.conf and dev.conf.net and dev.conf.net.ports or {}) do
				entry.ports[#entry.ports + 1] = {idx = p.idx, ifname = p.ifname, swport = p.swport, uplink = p.uplink or nil}
			end
			local vl = dev.conf and dev.conf.vlan
			entry.vlan = vl and {device = vl.device, cpu_lan = vl.cpu_lan, cpu_wan = vl.cpu_wan, ports = vl.ports} or nil
			for _, b in ipairs(entry.boards) do
				if board and b == board and not out.auto then out.auto = name end
			end
		end
		out.modelmaps[#out.modelmaps + 1] = entry
	end
	for _, name in ipairs(M._list_dir(M._ufmodel_dir)) do
		local src = M._read_file(M._ufmodel_dir .. "/" .. name .. ".lua")
		local title, unverified = header_of(src)
		local uap = load_preset(M._ufmodel_dir, name)
		out.ufmodels[#out.ufmodels + 1] = {
			name = name, title = title or name, unverified = unverified,
			platform = uap and uap.platform, model = uap and uap.model,
			fw_ver = uap and uap.fw and uap.fw.ver,
		}
	end
	return out
end

-- ─── status ─────────────────────────────────────────────────────────────────

-- /tmp/openuf-status is flat key=value, one per line (busybox sed parses it
-- in update.sh; keep that shape). Numbers come back as numbers.
local function parse_health(s)
	local h = {}
	for line in (s or ""):gmatch("[^\n]+") do
		local k, v = line:match("^([%w_]+)=(.*)$")
		if k then h[k] = tonumber(v) or v end
	end
	return h
end

local function json_decode(s)
	if type(s) ~= "string" or s == "" then return nil end
	local ok, cjson = pcall(require, "cjson")
	if not ok then return nil end
	local ok2, t = pcall(cjson.decode, s)
	return ok2 and type(t) == "table" and t or nil
end

-- state.json, minus the one secret. Everything else in it is what the
-- overview page is for.
local function read_state(path)
	local st = json_decode(M._read_file(path))
	if not st then return nil end
	st.authkey = nil
	if type(st.l2guard) == "table" then
		st.l2guard = {bpdu = st.l2guard.bpdu, tagdrop = st.l2guard.tagdrop,
			vaps = type(st.l2guard.ifnames) == "table" and #st.l2guard.ifnames or 0}
	end
	return st
end

local function ledger_size(path)
	local doc = json_decode(M._read_file(path))
	if not doc then return 0 end
	local n = 0
	local entries = doc.entries or doc
	if type(entries) == "table" then
		for _ in pairs(entries) do n = n + 1 end
	end
	return n
end

-- The description of one loaded configuration: dev and config as the daemons
-- see them, plus how they were resolved. uci_managed says whether
-- /etc/config/openuf was in charge; config_error is the reason it did not
-- load, in which case dev/config are conf.lua's.
function M.describe(dev, config, opts)
	opts = opts or {}
	local out = {
		uci_managed  = opts.uci_managed and true or false,
		config_error = opts.config_error,
		board        = board_name(),
		-- The device's clock: the health file's timestamps are in it, and a
		-- board whose clock is days off (AP2 was) would otherwise show every
		-- inform as ancient against the browser's.
		now          = M._time(),
		version      = trim(M._read_file(M._version_file) or ""),
		build        = trim(M._read_file(M._build_file) or ""),
	}
	if out.version == "" then out.version = nil end
	if out.build == "" then out.build = nil end

	local net = dev and dev.conf and dev.conf.net or {}
	local uap = dev and dev.openuf and dev.openuf.uap or {}
	local mm_name = dev and dev.modelmap_name
	if not mm_name and opts.conf_lua then
		mm_name = opts.conf_lua:match('dev%s*=%s*dofile%("modelmap/([^"]+)%.lua"%)')
	end
	local title
	if mm_name and mm_name ~= "custom" then
		title = header_of(M._read_file(M._modelmap_dir .. "/" .. mm_name .. ".lua"))
	end
	local ports = {}
	for _, p in ipairs(net.ports or {}) do
		ports[#ports + 1] = {idx = p.idx, ifname = p.ifname, swport = p.swport, uplink = p.uplink or nil}
	end
	local vlan = dev and dev.conf and dev.conf.vlan
	out.modelmap = {
		name = mm_name, title = title, lan_cpueth = net.lan_cpueth,
		lan_name = net.lan_name, lan_vlanid = net.lan_vlanid, wan_cpueth = net.wan_cpueth,
		uplink_detect = net.uplink_detect, dsa = net.uplink_detect ~= nil,
		led = type(dev and dev.conf and dev.conf.led) == "table" and dev.conf.led.sysfs or (dev and dev.conf and dev.conf.led),
		hwassign = uap.hwassign, ports = ports,
		boards = dev and dev.openwrt_boards or {},
		-- The switch geometry openuf-convert needs to move the WAN socket
		-- inside the switch on a swconfig board (cpu_lan/cpu_wan/lan_vlanid).
		vlan = vlan and {device = vlan.device, cpu_lan = vlan.cpu_lan, cpu_wan = vlan.cpu_wan,
			ports = vlan.ports} or nil,
	}

	local id = opts.uap
	local id_name = uap.ufmodel
	if not id and id_name then id = load_preset(M._ufmodel_dir, id_name) end
	out.identity = {
		name = id_name, platform = id and id.platform, model = id and id.model,
		fw_ver = id and id.fw and id.fw.ver, custom = opts.uap ~= nil,
		title = id_name and id_name ~= "custom" and header_of(M._read_file(M._ufmodel_dir .. "/" .. id_name .. ".lua")) or nil,
	}

	local c = config or {}
	out.config = {
		inform_url = c.inform_url, use_only_unifi_wlan = c.use_only_unifi_wlan,
		keep_wlan_sections = c.keep_wlan_sections, l2_announce = c.l2_announce,
		neighbour_scan_interval = c.neighbour_scan_interval,
		rrm_enrichment = c.rrm_enrichment, rrm_request_interval = c.rrm_request_interval,
		roam_assist_diff_db = c.roam_assist_diff_db, country_override = c.country_override,
		bootstrap_adopt_user = c.bootstrap_adopt_user, debug_dump_file = c.debug_dump_file,
		debug_dump_requests = c.debug_dump_requests, debug_dump_max_bytes = c.debug_dump_max_bytes,
		state_file = c.state_file, unhandled_file = c.unhandled_file,
		debug_overrides = (c.debug_caps ~= nil or c.debug_payload_extra ~= nil) or nil,
	}

	local state_file = c.state_file or "/etc/openuf/state.json"
	out.state  = read_state(state_file)
	out.health = parse_health(M._read_file(M._status_file))
	out.ledger = {file = c.unhandled_file or "/etc/openuf/unhandled.json",
		entries = ledger_size(c.unhandled_file or "/etc/openuf/unhandled.json")}

	local wlans = {}
	for _, v in ipairs(M._vaps()) do
		wlans[#wlans + 1] = {name = v.name, ssid = v.essid, radio = v.radio_name or v.radio,
			encryption = v.encryption, disabled = v.disabled and true or false, bssid = v.bssid}
	end
	out.wlans = wlans
	return out
end

-- Load the configuration the daemons' way and describe it. Only ever called
-- from the install directory (openuf-cli.sh cds there).
function M.status()
	local opts = {conf_lua = M._read_file("conf.lua")}
	local ok, err = pcall(dofile, "conf.lua")
	if not ok then
		return M.describe(nil, nil, {config_error = "conf.lua: " .. tostring(err)})
	end
	local ok_u, uap = pcall(function() return dofile("uciconf.lua").apply() end)
	if ok_u then
		opts.uap = uap
		-- apply() returns nil both for "UCI not in charge" and for "UCI in
		-- charge, preset identity"; the marker is the modelmap_name it sets.
		opts.uci_managed = type(dev) == "table" and dev.modelmap_name ~= nil
	else
		opts.config_error = tostring(uap)
	end
	return M.describe(dev, config, opts)
end

-- ─── discover ───────────────────────────────────────────────────────────────
--
-- What the running board says about itself, for the custom-profile forms:
-- the facts a hand-written modelmap would otherwise be read off the OpenWrt
-- source tree. /etc/board.json is the same file config_generate builds the
-- stock network layout from, so its port roles, switch geometry and radio
-- bands ARE the stock layout; sysfs and the device tree add the LEDs; the
-- wireless config adds the UCI radio names. The result carries a `draft`: a
-- custom profile in the shape uciconf.lua's sections take, with two things
-- deliberately marked unverified, since board.json cannot know them: which
-- physical switch port carries which case label on a swconfig board (they are
-- listed in board.d order, which is usually the case order), and which LED to
-- drive (the first one nothing else drives).

M._board_json_file = "/etc/board.json"
M._leds_dir        = "/sys/class/leds"
M._dt_aliases_dir  = "/proc/device-tree/aliases"
M._dt_root         = "/proc/device-tree"
M._net_dir         = "/sys/class/net"
M._uci             = nil   -- libuci-lua, injectable

M._run_cmd = function(cmd)
	local p = io.popen(cmd .. " 2>/dev/null")
	if not p then return "" end
	local s = p:read("*a")
	p:close()
	return s or ""
end

M._exists = function(path)
	local f = io.open(path, "r")
	if not f then return false end
	f:close()
	return true
end

-- The device tree encodes an LED's colour as a big-endian u32 from the
-- LED_COLOR_ID_* list and its function as a string; the sysfs name is
-- "<colour>:<function>[-<enumerator>]". Older trees carry a `label` that IS
-- the sysfs name.
local DT_COLOURS = {[0] = "white", "red", "green", "blue", "amber", "violet", "yellow", "ir",
	"multicolor", "rgb", "purple", "orange", "pink", "cyan", "lime"}

local function dt_string(path)
	local s = M._read_file(path)
	if not s then return nil end
	s = s:gsub("%z.*$", "")
	if s == "" then return nil end
	return s
end

local function dt_led_name(node)
	local label = dt_string(node .. "/label")
	if label then return label end
	local fn = dt_string(node .. "/function")
	local raw = M._read_file(node .. "/color")
	if not fn or not raw or #raw < 4 then return nil end
	local a, b, c, d = raw:byte(1, 4)
	local colour = DT_COLOURS[((a * 256 + b) * 256 + c) * 256 + d]
	local name = (colour or "?") .. ":" .. fn
	local enum = M._read_file(node .. "/function-enumerator")
	if enum and #enum >= 4 then
		local e1, e2, e3, e4 = enum:byte(1, 4)
		name = name .. "-" .. tostring(((e1 * 256 + e2) * 256 + e3) * 256 + e4)
	end
	return name
end

local function discover_leds(board)
	local leds, by_name = {}, {}
	for _, name in ipairs(M._list_dir_plain(M._leds_dir)) do
		local trig = M._read_file(M._leds_dir .. "/" .. name .. "/trigger") or ""
		local entry = {name = name, trigger = trig:match("%[([^%]]+)%]") or "none", used_by = {}}
		leds[#leds + 1] = entry
		by_name[name] = entry
	end
	-- LEDs procd drives at boot (led-boot/failsafe/running/upgrade): the
	-- alias points at a device-tree node, whose name is resolved above.
	for _, alias in ipairs(M._list_dir_plain(M._dt_aliases_dir)) do
		if alias:match("^led%-") then
			local target = dt_string(M._dt_aliases_dir .. "/" .. alias)
			local name = target and dt_led_name(M._dt_root .. target)
			if name and by_name[name] then
				local u = by_name[name].used_by
				u[#u + 1] = alias
			end
		end
	end
	-- LEDs OpenWrt's own board.d configured (board.json "led"): driven by a
	-- trigger from /etc/config/system.
	for key, led in pairs(board.led or {}) do
		if type(led) == "table" and led.sysfs and by_name[led.sysfs] then
			local u = by_name[led.sysfs].used_by
			u[#u + 1] = "openwrt:" .. tostring(led.name or key)
		end
	end
	table.sort(leds, function(a, b) return a.name < b.name end)
	return leds
end

-- Plain directory listing (names, not just *.lua).
M._list_dir_plain = function(dir)
	local names = {}
	local p = io.popen("ls " .. dir .. " 2>/dev/null")
	if not p then return names end
	for line in p:lines() do names[#names + 1] = line end
	p:close()
	table.sort(names)
	return names
end

local function uci_radios()
	local ok, uci = pcall(function() return M._uci or require("uci") end)
	if not ok or type(uci) ~= "table" then return {} end
	local out = {}
	pcall(function()
		local c = uci.cursor()
		c:foreach("wireless", "wifi-device", function(s)
			out[#out + 1] = {name = s[".name"], path = s.path, band = s.band, hwmode = s.hwmode,
				channel = s.channel, disabled = s.disabled == "1"}
		end)
	end)
	return out
end

local function discover_radios(board)
	local radios, by_path = {}, {}
	local phys = {}
	for phy in pairs(board.wlan or {}) do phys[#phys + 1] = phy end
	table.sort(phys)
	local uradios = uci_radios()
	for _, phy in ipairs(phys) do
		local w = board.wlan[phy]
		local info = type(w) == "table" and w.info or {}
		local bands = type(info) == "table" and info.bands or {}
		for band, b in pairs(bands) do
			local r = {phy = phy, path = w.path, band = band, ht = b.ht or false, vht = b.vht or false,
				he = b.he or false, max_width = b.max_width, modes = b.modes or {},
				default_channel = b.default_channel}
			r.openuf_band = (band == "2G") and "ng" or "na"
			for _, u in ipairs(uradios) do
				if u.path == w.path then r.uci = u.name; r.disabled = u.disabled end
			end
			if band ~= "2G" then
				local dump = M._run_cmd("iw phy " .. phy .. " info")
				r.dfs = dump:find("radar detection", 1, true) ~= nil or dump:find("DFS", 1, true) ~= nil
			end
			radios[#radios + 1] = r
			by_path[w.path] = r
		end
	end
	table.sort(radios, function(a, b) return a.phy < b.phy end)
	return radios
end

local function discover_netdevs()
	local out = {}
	for _, name in ipairs(M._list_dir_plain(M._net_dir)) do
		if name ~= "lo" then
			local base = M._net_dir .. "/" .. name
			local mac = trim(M._read_file(base .. "/address") or "")
			if mac ~= "" then
				out[#out + 1] = {name = name, mac = mac,
					state = trim(M._read_file(base .. "/operstate") or "unknown"),
					dsa = M._exists(base .. "/dsa/tagging"), bridge = M._exists(base .. "/bridge/bridge_id")}
			end
		end
	end
	return out
end

function M.discover()
	local board = json_decode(M._read_file(M._board_json_file)) or {}
	local net = board.network or {}
	local out = {board = {id = board.model and board.model.id, name = board.model and board.model.name}}
	out.netdevs = discover_netdevs()
	local dsa = false
	for _, n in ipairs(out.netdevs) do if n.dsa then dsa = true end end
	local swname, sw
	for name, s in pairs(board.switch or {}) do
		if type(s) == "table" and type(s.ports) == "table" then swname, sw = name, s end
	end
	out.layout = dsa and "dsa" or (sw and "swconfig") or "unknown"

	-- Sockets and CPU ports.
	out.sockets, out.cpu = {}, {}
	local lan_dev = net.lan and (net.lan.device or (type(net.lan.ports) == "table" and "br-lan"))
	local wan_dev = net.wan and net.wan.device
	if out.layout == "dsa" then
		for i, p in ipairs(net.lan and net.lan.ports or {}) do
			out.sockets[#out.sockets + 1] = {label = p, role = "lan", netdev = p, index = i}
		end
		if wan_dev then
			out.sockets[#out.sockets + 1] = {label = wan_dev, role = "wan", netdev = wan_dev, index = #out.sockets + 1}
		end
		out.cpu = {lan_cpueth = "br-lan", lan_vlanid = 1, wan_cpueth = wan_dev}
	elseif sw then
		local lan_i = 0
		for _, p in ipairs(sw.ports) do
			if p.device then
				out.cpu[#out.cpu + 1] = {num = p.num, netdev = p.device, tagged = p.need_tag or false}
			elseif p.role then
				local label
				if p.role == "lan" then lan_i = lan_i + 1; label = "lan" .. lan_i else label = p.role end
				out.sockets[#out.sockets + 1] = {label = label, role = p.role, swport = p.num,
					index = #out.sockets + 1, label_unverified = true}
			end
		end
		local lan_base, lan_vid = tostring(lan_dev or ""):match("^(.-)%.(%d+)$")
		local cpu = {switch = swname, lan_cpueth = lan_base or lan_dev, lan_vlanid = tonumber(lan_vid) or 1,
			wan_cpueth = wan_dev and (wan_dev:match("^(.-)%.%d+$") or wan_dev)}
		for _, c in ipairs(out.cpu) do
			if c.netdev == cpu.lan_cpueth then cpu.cpu_lan = c.num end
			if c.netdev == cpu.wan_cpueth then cpu.cpu_wan = c.num end
		end
		-- One tagged trunk serving both roles: the same CPU port is LAN's
		-- and WAN's (the Archer A7/C7 shape), so cpu_wan is that port too.
		if cpu.cpu_wan == nil and cpu.cpu_lan ~= nil and cpu.wan_cpueth == cpu.lan_cpueth then
			cpu.cpu_wan = cpu.cpu_lan
		end
		out.cpu_ports = out.cpu
		out.cpu = cpu
	else
		out.cpu = {lan_cpueth = lan_dev, lan_vlanid = 1, wan_cpueth = wan_dev}
	end

	out.radios = discover_radios(board)
	out.leds   = discover_leds(board)

	-- The draft custom profile, in the shape of uciconf.lua's sections.
	local draft = {
		lan_cpueth = out.cpu.lan_cpueth, lan_vlanid = out.cpu.lan_vlanid, wan_cpueth = out.cpu.wan_cpueth,
		uplink_detect = (out.layout == "dsa") and "fdb" or nil,
		openwrt_board = out.board.id, ports = {}, hwassign = {}, radio = {},
	}
	for _, s in ipairs(out.sockets) do
		draft.ports[#draft.ports + 1] = {idx = s.index, ifname = s.netdev, swport = s.swport and s.label or nil}
	end
	if out.layout == "swconfig" then
		draft.vlan = {device = out.cpu.switch, cpu_lan = out.cpu.cpu_lan, cpu_wan = out.cpu.cpu_wan, ports = {}}
		for _, s in ipairs(out.sockets) do draft.vlan.ports[s.label] = s.swport end
	end
	for _, r in ipairs(out.radios) do
		if r.uci then draft.hwassign[#draft.hwassign + 1] = r.uci end
		local pol = {}
		if r.band ~= "2G" and r.dfs then pol.acs_exclude_dfs = true end
		if r.he then pol.htmode_floor = (r.band == "2G") and "HE20" or "HE80"
		elseif r.vht then pol.htmode_floor = "VHT80" end
		if r.max_width then
			-- %d, not tostring: cjson hands a newer Lua 80.0, and "VHT80.0"
			-- is not an htmode.
			pol.htmode_max = string.format("%s%d", r.he and "HE" or r.vht and "VHT" or "HT", r.max_width)
		end
		if next(pol) then draft.radio[r.openuf_band] = pol end
	end
	for _, l in ipairs(out.leds) do
		if #l.used_by == 0 and l.trigger == "none" and not l.name:match("^mt76") and not l.name:match("phy") then
			draft.led = l.name
			break
		end
	end
	draft.led_unverified = true
	out.draft = draft
	local ok, presets = pcall(M.presets)
	if ok then out.auto = presets.auto end
	return out
end

-- ─── export ─────────────────────────────────────────────────────────────────

-- A custom profile from /etc/config/openuf as a modelmap file: what a user
-- contributes back so the next owner of the same board gets a preset. The
-- header says where it came from and that nothing in it has been checked by
-- the maintainers.
local function lua_str(s) return string.format("%q", tostring(s)) end
-- Integers print as integers whatever Lua (5.3+ would print a float 1.0).
local function int(n) return string.format("%d", n) end

function M.export_modelmap(dev, opts)
	opts = opts or {}
	local net = dev.conf.net
	local lines = {}
	local function add(l) lines[#lines + 1] = l end
	local board = dev.openwrt_boards and dev.openwrt_boards[1] or "vendor,model"
	local name = board:gsub("[^%w]+", "-")
	add("--[[")
	add("\t" .. (opts.title or (board .. " hardware profile")) .. ".")
	add("\tExported from a device's /etc/config/openuf custom profile by openUF on "
		.. os.date("!%Y-%m-%d") .. ".")
	add("\t" .. WARN .. " NOT verified by the openUF maintainers: the socket order, the LED and the")
	add("\tradio policy are what the exporting device's owner configured. Check them against")
	add("\tthe board before relying on per-port VLANs or Locate.")
	add("]]--")
	add("")
	add("local dev = {}")
	add("dev.conf = {}")
	add("dev.openwrt_boards = {" .. lua_str(board) .. "}")
	add("dev.conf.net = {")
	add("\tlan_name\t= " .. lua_str(net.lan_name or "lan") .. ",")
	add("\tlan_cpueth\t= " .. lua_str(net.lan_cpueth) .. ",")
	add("\tlan_vlanid\t= " .. int(net.lan_vlanid or 1) .. ",")
	if net.wan_cpueth then add("\twan_cpueth\t= " .. lua_str(net.wan_cpueth) .. ",") end
	add("\tports = {")
	for _, p in ipairs(net.ports or {}) do
		local f = "{idx = " .. int(p.idx)
		if p.ifname then f = f .. ", ifname = " .. lua_str(p.ifname) end
		if p.swport then f = f .. ", swport = " .. (type(p.swport) == "number" and int(p.swport) or lua_str(p.swport)) end
		if p.uplink then f = f .. ", uplink = true" end
		add("\t\t" .. f .. "},")
	end
	add("\t},")
	if net.uplink_detect then add("\tuplink_detect = " .. lua_str(net.uplink_detect) .. ",") end
	add("}")
	if dev.conf.led then add("dev.conf.led = " .. lua_str(dev.conf.led)) else add("dev.conf.led = nil") end
	if dev.conf.vlan then
		local v = dev.conf.vlan
		add("dev.conf.vlan = {")
		add("\tdevice\t= " .. lua_str(v.device or "switch0") .. ",")
		if v.cpu_lan ~= nil then add("\tcpu_lan\t= " .. int(v.cpu_lan) .. ",") end
		if v.cpu_wan ~= nil then add("\tcpu_wan\t= " .. int(v.cpu_wan) .. ",") end
		add("\tports\t= {")
		local labels = {}
		for l in pairs(v.ports or {}) do labels[#labels + 1] = l end
		table.sort(labels)
		for _, l in ipairs(labels) do add("\t\t" .. l .. "\t= " .. int(v.ports[l]) .. ",") end
		add("\t}")
		add("}")
	end
	if dev.conf.radio then
		add("dev.conf.radio = {")
		for _, band in ipairs({"na", "ng"}) do
			local r = dev.conf.radio[band]
			if r then
				add("\t" .. band .. " = {")
				if r.acs_exclude_dfs ~= nil then add("\t\tacs_exclude_dfs = " .. tostring(r.acs_exclude_dfs) .. ",") end
				if r.htmode_floor then add("\t\thtmode_floor = " .. lua_str(r.htmode_floor) .. ",") end
				if r.htmode_max then add("\t\thtmode_max = " .. lua_str(r.htmode_max) .. ",") end
				if r.channels then
					local cs = {}
					for i, c in ipairs(r.channels) do cs[i] = int(c) end
					add("\t\tchannels = {" .. table.concat(cs, ", ") .. "},")
				end
				add("\t},")
			end
		end
		add("}")
	end
	add("dev.openuf = {}")
	add("dev.openuf.uap = {")
	-- A custom identity lives in UCI sections on the exporting device, not in a
	-- shipped file, so a profile cannot name it: the first export did, and the
	-- file failed test_modelmap's "ufmodel file exists" the moment it was
	-- shipped. The profile's own choice (the device section's ufmodel, passed
	-- in opts) is what a shipped copy would run under, and the file says so.
	local uf = dev.openuf.uap.ufmodel
	if uf == "custom" then uf = opts.ufmodel end
	if not uf or uf == "custom" then uf = "u6iw" end
	if dev.openuf.uap.ufmodel == "custom" then
		add("\t-- The exporting device presented a custom identity"
			.. (opts.identity_platform and (" (" .. opts.identity_platform .. ")") or "")
			.. "; a shipped profile")
		add("\t-- must name a shipped one, so this is the profile's own choice.")
	end
	add("\tufmodel\t\t= " .. lua_str(uf) .. ",")
	if dev.openuf.uap.hwassign then
		local hs = {}
		for i, h in ipairs(dev.openuf.uap.hwassign) do hs[i] = lua_str(h) end
		add("\thwassign\t= {" .. table.concat(hs, ", ") .. "},")
	end
	add("}")
	add("return dev")
	return table.concat(lines, "\n") .. "\n", name .. ".lua"
end

-- `openuf probe export`: the custom profile of /etc/config/openuf as a
-- modelmap file. Refused, with the reason, when the file holds no valid
-- custom profile -- the same checks the daemon applies.
function M.export()
	local ok, uciconf = pcall(dofile, "uciconf.lua")
	if not ok then return {error = "uciconf.lua: " .. tostring(uciconf)} end
	local uci = M._uci or require("uci")
	local c = uci.cursor()
	local main = c:get_all("openuf", "main")
	if type(main) ~= "table" then return {error = "no openuf.main section"} end
	if main.modelmap ~= "custom" then
		return {error = "the hardware profile is '" .. tostring(main.modelmap or "auto")
			.. "', not custom; only a custom profile is exported"}
	end
	local loaded, err = uciconf.load(c, {})
	if not loaded then return {error = err} end
	local text, filename = M.export_modelmap(loaded.dev, {
		ufmodel = c:get(uciconf.CONFIG or "openuf", "custom", "ufmodel"),
		identity_platform = loaded.uap and loaded.uap.platform,
	})
	return {text = text, filename = filename}
end

if not OPENUF_TEST_MODE and arg and arg[0] and arg[0]:match("probe%.lua$") then
	local what = arg[1]
	local fn = (what == "status" and M.status) or (what == "presets" and M.presets)
		or (what == "discover" and M.discover) or (what == "export" and M.export)
	if not fn then
		io.stderr:write("usage: openuf probe status|presets|discover|export\n")
		os.exit(2)
	end
	local ok, cjson = pcall(require, "cjson")
	if not ok then
		io.stderr:write("probe: lua-cjson is required\n")
		os.exit(1)
	end
	local ok2, result = pcall(fn)
	if not ok2 then
		io.stderr:write("probe: " .. tostring(result) .. "\n")
		os.exit(1)
	end
	print(cjson.encode(result))
end

return M
