--[[
	openUF configuration from UCI: /etc/config/openuf.

	conf.lua is a Lua file a person edits on the device, which is right for a
	tarball install driven by setup.sh and wrong for everything else: an OpenWrt
	package has to ship a config LuCI can edit, `uci` can script and sysupgrade
	keeps, and that is UCI. This module turns /etc/config/openuf into the same
	two tables conf.lua produces -- `dev` (the hardware profile) and `config`
	(the runtime options) -- so nothing downstream knows which one it came from.

	Precedence: when /etc/config/openuf has a `main` section, it wins and
	conf.lua's values are only the defaults for options it leaves out. Without
	that section (a tarball install, the lab, the tests) conf.lua rules as
	before. The package ships the section; install.sh does not create it, so
	an upgraded tarball device keeps behaving exactly as its conf.lua says --
	a config that silently switched modelmaps would change the identity MAC,
	which is HTTP 400 forever on an adopted AP (inform.lua's
	_warn_identity_change).

	The hardware profile comes from one of three places, chosen by
	openuf.main.modelmap:
	  auto      the preset whose dev.openwrt_boards names this board
	            (/tmp/sysinfo/board_name), the same match setup.sh makes; no
	            match is a refusal, not a guess -- the generic maps carry the
	            wrong lan_cpueth for a DSA board, and that field is the identity
	  <name>    that preset, modelmap/<name>.lua
	  custom    the `device`, `port`, `vlan`, `swport` and `radio` sections
	            below, built into the same shape and checked against the
	            invariants tests/test_modelmap.lua enforces on every preset
	The identity likewise, by openuf.main.ufmodel: auto (the modelmap's own
	choice), a preset name, or custom (the `identity` section).

	Sections, mirroring the modelmap fields one to one:

	  config openuf 'main'
	      option modelmap 'auto'          option ufmodel 'auto'
	      option inform_url '...'         option use_only_unifi_wlan '1'
	      list keep_wlan_section 'x'      option l2_announce '1'
	      option neighbour_scan_interval '0'
	      option rrm_enrichment '1'       option rrm_request_interval '600'
	      option roam_assist_diff_db '8'  option country_override ''
	      option bootstrap_adopt_user ''  option debug_dump_file ''
	      option debug_dump_requests '0'  option debug_dump_max_bytes '4194304'
	      (debug_caps and debug_payload_extra stay conf.lua-only: they are
	      research switches, not settings)
	  config device 'custom'
	      option lan_cpueth 'br-lan'      option lan_name 'lan'
	      option lan_vlanid '1'           option wan_cpueth 'wan'
	      option uplink_detect 'fdb'      option led 'green:status'
	      list hwassign 'radio0'          list openwrt_board 'vendor,model'
	      option ufmodel 'u6iw'
	  config port                        one per RJ45 socket
	      option idx '1'                  option ifname 'lan1'  (DSA)
	      option swport 'lan1'            option uplink '0'     (swconfig)
	  config vlan 'custom_vlan'          swconfig boards only
	      option device 'switch0'         option cpu_lan '0'    option cpu_wan '6'
	  config swport                      label -> physical port, swconfig only
	      option label 'lan1'             option num '2'
	  config radio 'na'                  per band: 'na' / 'ng'
	      option acs_exclude_dfs '1'      option htmode_floor 'HE80'
	      option htmode_max 'HE160'       list channel '36'
	  config identity 'custom_identity'
	      option platform 'U6IW'          option model 'U6IW'
	      option fw_pre 'U6IW.'           option fw_ver '6.8.2.15592'
	      option fw_buildtime '260211.2010'  option fw_factoryver '6.5.28'
	      option bootver ''               option required_version '6.0.0'
]]--

local M = {}

M.CONFIG = "openuf"

-- Seams. _uci is the libuci-lua module (tests inject a mock cursor factory);
-- the directories are relative to the daemon's cwd, openuf/, and the tests
-- point them at openuf/modelmap from the repository root.
M._uci             = nil
M._board_name_file = "/tmp/sysinfo/board_name"
M._modelmap_dir    = "modelmap"
M._ufmodel_dir     = "ufmodel"

M._read_file = function(path)
	local f = io.open(path, "r")
	if not f then return nil end
	local s = f:read("*a")
	f:close()
	return s
end

-- Preset names, without ".lua", in name order. `ls` rather than a directory
-- binding: openUF has none, and setup.sh lists the same directory the same
-- way.
M._list_modelmaps = function()
	local names = {}
	local p = io.popen("ls " .. M._modelmap_dir .. " 2>/dev/null")
	if not p then return names end
	for line in p:lines() do
		local name = line:match("^(.+)%.lua$")
		if name then names[#names + 1] = name end
	end
	p:close()
	table.sort(names)
	return names
end

M._load_modelmap = function(name)
	return dofile(M._modelmap_dir .. "/" .. name .. ".lua")
end

M._ufmodel_exists = function(name)
	local f = io.open(M._ufmodel_dir .. "/" .. name .. ".lua", "r")
	if not f then return false end
	f:close()
	return true
end

local function new_cursor()
	local uci = M._uci or require("uci")
	return uci.cursor()
end

-- ─── Value coercion ─────────────────────────────────────────────────────────
-- UCI stores strings. These are the conversions LuCI's own Flag/Value widgets
-- assume, and nothing else: an unrecognised boolean spelling is an error, not
-- a false, so a typo in "ture" is caught rather than switching a feature off.

local TRUE  = {["1"] = true, ["true"] = true, ["on"] = true, ["yes"] = true, ["enabled"] = true}
local FALSE = {["0"] = true, ["false"] = true, ["off"] = true, ["no"] = true, ["disabled"] = true}

local function to_bool(v, what)
	if v == nil then return nil end
	if TRUE[v] then return true end
	if FALSE[v] then return false end
	error(what .. ": not a boolean: " .. tostring(v), 0)
end

local function to_num(v, what)
	if v == nil or v == "" then return nil end
	local n = tonumber(v)
	if not n then error(what .. ": not a number: " .. tostring(v), 0) end
	return n
end

-- An empty string means "unset" for every optional string option: LuCI
-- writes '' when a field is cleared, and conf.lua's nil is what the daemon
-- tests for.
local function to_str(v)
	if v == nil or v == "" then return nil end
	return v
end

-- A UCI list arrives as a table from get_all, but a single value written
-- with `option` instead of `list` arrives as a string. Accept both.
local function to_list(v)
	if v == nil then return {} end
	if type(v) == "table" then return v end
	return {v}
end

-- ─── main: the runtime options ─────────────────────────────────────────────

local BOOL_OPTS = {"use_only_unifi_wlan", "l2_announce", "rrm_enrichment", "debug_dump_requests"}
local NUM_OPTS  = {"neighbour_scan_interval", "rrm_request_interval", "roam_assist_diff_db",
	"debug_dump_max_bytes"}
local STR_OPTS  = {"inform_url", "state_file", "unhandled_file", "debug_dump_file",
	"country_override", "bootstrap_adopt_user"}

local function shallow_copy(t)
	local out = {}
	for k, v in pairs(t or {}) do out[k] = v end
	return out
end

-- The `config` table: conf.lua's defaults, with every option the main
-- section sets on top. Options the section leaves out keep their default,
-- so a package upgrade that adds an option needs no config migration.
local function build_config(main, defaults)
	local cfg = shallow_copy(defaults)
	for _, k in ipairs(BOOL_OPTS) do
		local v = to_bool(main[k], "openuf.main." .. k)
		if v ~= nil then cfg[k] = v end
	end
	for _, k in ipairs(NUM_OPTS) do
		local v = to_num(main[k], "openuf.main." .. k)
		if v ~= nil then cfg[k] = v end
	end
	for _, k in ipairs(STR_OPTS) do
		if main[k] ~= nil then cfg[k] = to_str(main[k]) end
	end
	if main.keep_wlan_section ~= nil then
		cfg.keep_wlan_sections = to_list(main.keep_wlan_section)
	end
	return cfg
end

-- ─── The hardware profile ──────────────────────────────────────────────────

-- The invariants every preset is held to (tests/test_modelmap.lua), applied
-- to a custom map before it is used. A map that fails here is refused with
-- the reason; the daemon then does not start, which beats reporting the
-- wrong socket as the uplink or moving the identity to another MAC.
function M.validate(dev)
	if type(dev) ~= "table" or type(dev.conf) ~= "table" then
		return false, "no dev.conf"
	end
	local net = dev.conf.net
	if type(net) ~= "table" then return false, "no net section" end
	if type(net.lan_cpueth) ~= "string" or net.lan_cpueth == "" then
		return false, "lan_cpueth is required (the netdev whose MAC is the identity)"
	end
	local vlan = dev.conf.vlan
	if vlan ~= nil then
		if type(vlan) ~= "table" then return false, "vlan is not a table" end
		if type(vlan.device) ~= "string" or vlan.device == "" then
			return false, "a swconfig map must name its switch device (vlan.device)"
		end
		if type(vlan.ports) ~= "table" then return false, "vlan.ports missing" end
		if net.uplink_detect then
			return false, "uplink_detect is a DSA setting; a swconfig map (vlan section) cannot use it"
		end
		-- No LAN socket may share a physical port with the WAN socket or a
		-- CPU port: on ar8216-family switches a shared port is one VLAN
		-- bitmask, and the tagged-uplink work would deafen a wired client.
		local wan_num = vlan.ports.wan
		for label, num in pairs(vlan.ports) do
			if type(num) ~= "number" then
				return false, "swport " .. tostring(label) .. " has a non-numeric port number"
			end
			if label ~= "wan" and wan_num ~= nil and num == wan_num then
				return false, "swport " .. label .. " collides with the WAN socket (port " .. num .. ")"
			end
			if num == vlan.cpu_lan or num == vlan.cpu_wan then
				return false, "swport " .. label .. " collides with a CPU port (" .. num .. ")"
			end
		end
	end
	if net.ports ~= nil then
		if type(net.ports) ~= "table" then return false, "ports is not a list" end
		local seen = {}
		for _, p in ipairs(net.ports) do
			if type(p.idx) ~= "number" then return false, "a port has no numeric idx" end
			if seen[p.idx] then return false, "port idx " .. p.idx .. " is used twice" end
			seen[p.idx] = true
			local has_sw = type(p.swport) == "string" or type(p.swport) == "number"
			local has_if = type(p.ifname) == "string" and p.ifname ~= ""
			if not (has_sw or has_if) then
				return false, "port " .. p.idx .. " names neither an ifname nor a swport"
			end
			if p.uplink and has_sw then
				return false, "port " .. p.idx .. " is the uplink and must not carry a swport"
			end
			if has_sw then
				if not vlan then
					return false, "port " .. p.idx .. " has a swport but there is no vlan section"
				end
				if type(p.swport) == "string" and vlan.ports[p.swport] == nil then
					return false, "port " .. p.idx .. ": swport " .. p.swport .. " is not in the swport map"
				end
				if net.uplink_detect then
					return false, "port " .. p.idx .. " has a swport; uplink_detect needs the netdev shape"
				end
			end
		end
	end
	if net.uplink_detect ~= nil and net.uplink_detect ~= "fdb" then
		return false, "uplink_detect must be 'fdb' or unset"
	end
	local led = dev.conf.led
	if led ~= nil and not (type(led) == "string" and led ~= "")
			and not (type(led) == "table" and type(led.sysfs) == "string") then
		return false, "led must be an LED name, a {sysfs=} table, or unset"
	end
	if type(dev.openuf) ~= "table" or type(dev.openuf.uap) ~= "table" then
		return false, "no openuf.uap section"
	end
	local uap = dev.openuf.uap
	if type(uap.ufmodel) ~= "string" or uap.ufmodel == "" then
		return false, "no ufmodel named"
	end
	if uap.hwassign ~= nil then
		if type(uap.hwassign) ~= "table" or #uap.hwassign == 0 then
			return false, "hwassign must be a non-empty list of radio names"
		end
		for _, r in ipairs(uap.hwassign) do
			if type(r) ~= "string" or r == "" then return false, "hwassign has an empty entry" end
		end
	end
	for _, b in ipairs(dev.openwrt_boards or {}) do
		if type(b) ~= "string" or not b:match("^[%w%-%._]+,[%w%-%._]+$") then
			return false, "openwrt_board " .. tostring(b) .. " is not of the form vendor,model"
		end
	end
	return true
end

-- Every section of one type, in file order, as option tables.
local function sections_of(c, stype)
	local out = {}
	c:foreach(M.CONFIG, stype, function(s) out[#out + 1] = s end)
	return out
end

local function build_custom_device(c)
	local d = c:get_all(M.CONFIG, "custom")
	if type(d) ~= "table" or d[".type"] ~= "device" then
		return nil, "modelmap is 'custom' but there is no `config device 'custom'` section"
	end
	local dev = {conf = {}, openuf = {}}
	dev.conf.net = {
		lan_name      = to_str(d.lan_name) or "lan",
		lan_cpueth    = to_str(d.lan_cpueth),
		lan_vlanid    = to_num(d.lan_vlanid, "device.lan_vlanid") or 1,
		wan_cpueth    = to_str(d.wan_cpueth),
		uplink_detect = to_str(d.uplink_detect),
	}
	local ports = {}
	for _, s in ipairs(sections_of(c, "port")) do
		local p = {
			idx    = to_num(s.idx, "port.idx"),
			ifname = to_str(s.ifname),
			swport = to_str(s.swport),
			uplink = to_bool(s.uplink, "port.uplink") or nil,
		}
		if p.swport and tonumber(p.swport) then p.swport = tonumber(p.swport) end
		ports[#ports + 1] = p
	end
	table.sort(ports, function(a, b) return (a.idx or 0) < (b.idx or 0) end)
	if #ports > 0 then dev.conf.net.ports = ports end
	local v = c:get_all(M.CONFIG, "custom_vlan")
	local swports = sections_of(c, "swport")
	if type(v) == "table" and v[".type"] == "vlan" or #swports > 0 then
		v = type(v) == "table" and v or {}
		local map = {}
		for _, s in ipairs(swports) do
			local label, num = to_str(s.label), to_num(s.num, "swport.num")
			if label then map[label] = num end
		end
		dev.conf.vlan = {
			device  = to_str(v.device) or "switch0",
			cpu_lan = to_num(v.cpu_lan, "vlan.cpu_lan"),
			cpu_wan = to_num(v.cpu_wan, "vlan.cpu_wan"),
			ports   = map,
		}
	end
	dev.conf.led = to_str(d.led)
	local radio
	for _, s in ipairs(sections_of(c, "radio")) do
		local band = s[".name"]
		if band == "na" or band == "ng" then
			radio = radio or {}
			local r = {
				acs_exclude_dfs = to_bool(s.acs_exclude_dfs, "radio." .. band .. ".acs_exclude_dfs"),
				htmode_floor    = to_str(s.htmode_floor),
				htmode_max      = to_str(s.htmode_max),
			}
			local channels = to_list(s.channel)
			if #channels > 0 then
				r.channels = {}
				for i, ch in ipairs(channels) do
					r.channels[i] = to_num(ch, "radio." .. band .. ".channel")
				end
			end
			radio[band] = r
		end
	end
	dev.conf.radio = radio
	dev.openuf.uap = {
		ufmodel  = to_str(d.ufmodel) or "u6iw",
		hwassign = to_list(d.hwassign),
	}
	if #dev.openuf.uap.hwassign == 0 then dev.openuf.uap.hwassign = nil end
	local boards = to_list(d.openwrt_board)
	if #boards > 0 then dev.openwrt_boards = boards end
	local ok, err = M.validate(dev)
	if not ok then return nil, "custom device map: " .. err end
	dev.modelmap_name = "custom"
	return dev
end

local function board_name()
	local s = M._read_file(M._board_name_file)
	if not s then return nil end
	return (s:match("^%s*(.-)%s*$"))
end

local function resolve_modelmap(c, choice)
	if choice == "custom" then return build_custom_device(c) end
	local names = M._list_modelmaps()
	if choice == "auto" then
		local board = board_name()
		if not board or board == "" then
			return nil, "modelmap is 'auto' but " .. M._board_name_file .. " is unreadable"
		end
		for _, name in ipairs(names) do
			local ok, dev = pcall(M._load_modelmap, name)
			if ok and type(dev) == "table" then
				for _, b in ipairs(dev.openwrt_boards or {}) do
					if b == board then
						dev.modelmap_name = name
						return dev
					end
				end
			end
		end
		return nil, "no modelmap declares board " .. board
			.. "; set openuf.main.modelmap to a preset or 'custom'"
	end
	local found = false
	for _, name in ipairs(names) do if name == choice then found = true end end
	if not found then
		return nil, "modelmap '" .. tostring(choice) .. "' is not shipped (see "
			.. M._modelmap_dir .. "/)"
	end
	local ok, dev = pcall(M._load_modelmap, choice)
	if not ok or type(dev) ~= "table" then
		return nil, "modelmap '" .. choice .. "' failed to load: " .. tostring(dev)
	end
	dev.modelmap_name = choice
	return dev
end

local function build_identity(c)
	local s = c:get_all(M.CONFIG, "custom_identity")
	if type(s) ~= "table" or s[".type"] ~= "identity" then
		return nil, "ufmodel is 'custom' but there is no `config identity 'custom_identity'` section"
	end
	-- Every cosmetic field is a string, empty when unset: announce.lua packs
	-- buildtime/factoryver/bootver into the discovery TLVs and lib.lua takes
	-- their length, so a nil here crash-looped the announce daemon (seen on
	-- AP2 the first time a custom identity was saved from the web UI).
	local uap = {
		platform         = to_str(s.platform),
		model            = to_str(s.model),
		fw = {
			pre        = to_str(s.fw_pre),
			ver        = to_str(s.fw_ver),
			buildtime  = to_str(s.fw_buildtime) or "",
			factoryver = to_str(s.fw_factoryver) or "",
		},
		bootver          = to_str(s.bootver) or "",
		required_version = to_str(s.required_version) or "6.0.0",
	}
	for _, k in ipairs({"platform", "model"}) do
		if not uap[k] then return nil, "custom identity: " .. k .. " is required" end
	end
	if not uap.fw.ver or not uap.fw.ver:match("^%d+%.%d+%.%d+%.%d+$") then
		return nil, "custom identity: fw_ver must be bare M.m.p.build (the controller compares it verbatim)"
	end
	uap.fw.pre = uap.fw.pre or (uap.model .. ".")
	return uap
end

-- ─── Entry points ──────────────────────────────────────────────────────────

-- True when /etc/config/openuf has a `main` section, i.e. UCI is the
-- configuration on this device.
function M.present(c)
	local ok, main = pcall(function() return c:get_all(M.CONFIG, "main") end)
	return ok and type(main) == "table"
end

-- {dev=, config=, uap=} from UCI, or nil and the reason. `defaults` is the
-- config table conf.lua produced (nil for none). `uap` is set only for a
-- custom identity; otherwise the caller loads ufmodel/<dev.openuf.uap.ufmodel>.
function M.load(c, defaults)
	local main = c:get_all(M.CONFIG, "main")
	if type(main) ~= "table" then return nil, "no 'main' section" end
	local ok, cfg = pcall(build_config, main, defaults)
	if not ok then return nil, tostring(cfg) end
	local dev, err = resolve_modelmap(c, to_str(main.modelmap) or "auto")
	if not dev then return nil, err end
	local uap
	local choice = to_str(main.ufmodel) or "auto"
	if choice == "custom" then
		uap, err = build_identity(c)
		if not uap then return nil, err end
		dev.openuf.uap.ufmodel = "custom"
	elseif choice ~= "auto" then
		if not M._ufmodel_exists(choice) then
			return nil, "ufmodel '" .. choice .. "' is not shipped (see " .. M._ufmodel_dir .. "/)"
		end
		dev.openuf.uap.ufmodel = choice
	end
	return {dev = dev, config = cfg, uap = uap}
end

-- Called by the daemons right after dofile("conf.lua"): replaces the globals
-- `dev` and `config` from UCI when UCI is in charge, and returns the custom
-- identity table if there is one. Returns nil, changing nothing, when there
-- is no libuci-lua or no `main` section. A present but broken config is an
-- error -- the daemon must not start on half a configuration.
function M.apply()
	local ok, c = pcall(new_cursor)
	if not ok or not c then return nil end
	if not M.present(c) then return nil end
	local loaded, err = M.load(c, type(config) == "table" and config or nil)
	if not loaded then
		error("/etc/config/openuf: " .. tostring(err), 0)
	end
	dev    = loaded.dev
	config = loaded.config
	return loaded.uap
end

return M
