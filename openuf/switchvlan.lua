--[[
	Per-port VLAN assignment, driven by the controller's `switch.*` push.

	Wire format mapped live 2026-07-19 (see PROTOCOL-VALIDATION.md's `switch.*`
	section) and parsed by inform.lua's M._parse_switch_system_cfg(), which
	hands this module:

	    {enabled = true,
	     vlans = {[1] = {...}, [20] = {...}},
	     ports = {[2] = {pvid = 20, vlans = {[1]="exclude", [20]="untagged"}}}}

	keyed by UniFi port_idx. The controller's untagged|tagged|exclude vocabulary
	maps 1:1 onto swconfig's port membership syntax ("3", "3t", absent).

	=== SCOPE AND LIMITS -- read before extending ===

	**swconfig boards only.** All three boards this project targets (TP-Link
	WDR3500, Archer C5 v1, WR1043ND v2) are ath79/swconfig, and both modelmaps
	already carry the swconfig physical-port map this needs. Modern OpenWrt
	(21.02+) is DSA, where per-port VLAN is `config bridge-vlan` instead --
	detect_backend() recognizes DSA and refuses, rather than emitting
	unverifiable config. There is no DSA board here to verify against.

	**Not verified against real switch hardware.** The validation container has
	no switch, no swconfig binary, and only a mock UCI. What is verified: the
	wire format (live, against a real controller), the parse layer, and the
	UCI state this module produces (unit tests with a mock cursor). What is
	NOT: that the generated `switch_vlan` sections actually program a switch
	ASIC, that traffic lands on the right VLAN, or that the reload command
	behaves on real ath79. Same honesty as bcfilter.lua's nftables caveat.

	**Reversibility.** Assigning a port to a VLAN requires removing it from the
	stock VLAN's port list, so unlike the wireless side this module cannot stay
	entirely inside openuf_-prefixed sections. It therefore snapshots any
	pre-existing section's original `ports` string into openUF's state before
	the first mutation, and restore() puts them back.

	All operations are safe no-ops without dev.conf.vlan (an unknown board's
	switch port map must never be guessed -- that is how you strand a device).
]]--

local M = {}

-- Injectable, matching netconfig.lua/shaper.lua's convention.
M._exec = function(cmd) return os.execute(cmd) end
M._uci  = nil   -- set by callers/tests; falls back to require("uci")

local OPENUF_VLAN_PREFIX = "openuf_swvlan"

local function get_uci()
	if M._uci then return M._uci end
	return require("uci")
end

-- Which switch backend this board uses. Only "swconfig" is actionable.
-- cursor: an open UCI cursor (so tests can drive this without a real system).
function M.detect_backend(cursor)
	local has_switch, has_bridge_vlan = false, false
	cursor:foreach("network", "switch", function() has_switch = true end)
	cursor:foreach("network", "bridge-vlan", function() has_bridge_vlan = true end)
	if has_switch then return "swconfig" end
	if has_bridge_vlan then return "dsa" end
	return "unknown"
end

-- Map a UniFi port_idx to this board's physical switch port number.
-- The chain is deliberately explicit and never guessed:
--   controller port_idx -> dev.conf.net.ports[].swport -> dev.conf.vlan.ports[]
-- Returns nil when any link is missing, which callers treat as "skip this port".
function M.physical_port(cfg, port_idx)
	local net  = cfg and cfg.net
	local vlan = cfg and cfg.vlan
	if not (net and net.ports and vlan and vlan.ports) then return nil end
	for _, p in ipairs(net.ports) do
		if p.idx == port_idx then
			if p.uplink then return nil, "uplink" end
			if not p.swport then return nil, "no swport in modelmap" end
			-- swport may name a key in dev.conf.vlan.ports ("lan1") or be the
			-- physical number outright.
			local phys = vlan.ports[p.swport] or tonumber(p.swport)
			if not phys then return nil, "swport not in dev.conf.vlan.ports" end
			return phys
		end
	end
	return nil, "no such port_idx"
end

-- Build the desired swconfig port string for one VLAN.
-- members: {[port_idx] = "untagged"|"tagged"|"exclude"}
-- Returns nil when the VLAN ends up with no member beyond the CPU port, so the
-- caller can skip writing an empty section.
function M.build_ports(cfg, vlan_id, members)
	local cpu = cfg and cfg.vlan and cfg.vlan.cpu_lan
	if not cpu then return nil end
	local parts, any = {}, false
	-- The CPU port is always tagged: it carries every VLAN up to the SoC.
	parts[#parts + 1] = tostring(cpu) .. "t"
	local idxs = {}
	for idx in pairs(members) do idxs[#idxs + 1] = idx end
	table.sort(idxs)   -- stable, comparable output
	for _, idx in ipairs(idxs) do
		local mode = members[idx]
		local phys = M.physical_port(cfg, idx)
		if phys and mode ~= "exclude" then
			parts[#parts + 1] = tostring(phys) .. (mode == "tagged" and "t" or "")
			any = true
		end
	end
	if not any then return nil end
	return table.concat(parts, " ")
end

-- Apply a parsed switch table.
-- sw:  output of inform.M._parse_switch_system_cfg (may be nil)
-- cfg: device configuration (dev.conf)
-- st:  openUF state table, used as the reversibility ledger
-- Returns true when UCI was changed and a reload was issued.
function M.apply(sw, cfg, st)
	if not sw or not sw.enabled then return false end
	if not (cfg and cfg.vlan and cfg.vlan.ports and cfg.vlan.cpu_lan) then
		io.stderr:write("switchvlan: no dev.conf.vlan for this board -- "
			.. "per-port VLAN not applied (a guessed switch port map strands the device)\n")
		return false
	end
	-- No early return on empty sw.ports: an enabled push whose last per-port
	-- override was removed must still reach the reconcile below, or the
	-- now-orphaned openuf_swvlan* sections would keep programming VLANs the
	-- controller no longer defines.

	local uci = get_uci()
	local cursor = uci.cursor()

	local backend = M.detect_backend(cursor)
	if backend ~= "swconfig" then
		io.stderr:write(("switchvlan: %s board -- per-port VLAN not applied "
			.. "(only swconfig is implemented and verifiable here)\n"):format(backend))
		return false
	end

	-- Invert the per-port matrix into per-VLAN membership.
	local members_by_vlan = {}
	for port_idx, p in pairs(sw.ports) do
		local phys, why = M.physical_port(cfg, port_idx)
		if not phys then
			io.stderr:write(("switchvlan: skipping port_idx %d (%s)\n")
				:format(port_idx, why or "unmappable"))
		else
			for vlan_id, mode in pairs(p.vlans) do
				members_by_vlan[vlan_id] = members_by_vlan[vlan_id] or {}
				members_by_vlan[vlan_id][port_idx] = mode
			end
		end
	end
	-- Refuse to strand management: the CPU port must keep the management VLAN.
	local mgmt_vlan = (cfg.net and cfg.net.lan_vlanid) or 1
	local mgmt = members_by_vlan[mgmt_vlan]
	if mgmt then
		local survives = false
		for _, mode in pairs(mgmt) do
			if mode ~= "exclude" then survives = true end
		end
		-- The CPU port is always tagged into every VLAN we write, so the
		-- management VLAN itself survives; this guards the case where the
		-- controller excludes every port from it, leaving a VLAN with no
		-- downstream member at all.
		if not survives then
			members_by_vlan[mgmt_vlan] = nil
		end
	end

	-- The sections this push wants to exist. Keyed on the rendered result,
	-- not on members_by_vlan: a VLAN that shrank to exclusions-only renders
	-- to nil and must lose its section just like a VLAN that left the wire.
	local desired = {}
	for vlan_id, members in pairs(members_by_vlan) do
		desired[vlan_id] = M.build_ports(cfg, vlan_id, members)
	end

	-- Stock-section strips: moving a port onto an openuf VLAN means it must
	-- LEAVE the stock VLAN's port list too -- swconfig allows one untagged
	-- VLAN per port, and a port left untagged in stock VLAN 1 while also
	-- untagged in openuf_swvlan20 is an invalid config the ASIC cannot
	-- honor. (This forward mutation is what st.swvlan_backup/restore() were
	-- always documented for; until now it was never actually performed, so
	-- the restore machinery was dead code and port moves could not work.)
	--
	-- Rules, per managed physical port P and stock VLAN section V:
	--   * exclude(P, V) on the wire  -> drop P's tokens from V, but drop an
	--     UNTAGGED membership only when P gains an untagged home elsewhere
	--     in this push (never strand a port with no untagged VLAN at all);
	--     a tagged membership is always safe to drop.
	--   * P untagged in some pushed VLAN W -> drop P's untagged token from
	--     every OTHER stock section (the one-untagged-VLAN rule).
	--   * CPU ports are never touched; the uplink cannot appear (its
	--     port_idx is unmappable by design).
	--   * The management VLAN is never stripped of its last downstream
	--     port (same survival principle as the members_by_vlan guard).
	local untagged_home = {}  -- phys -> vlan_id it becomes untagged in
	local excluded      = {}  -- vlan_id -> { [phys] = true }
	for port_idx, p in pairs(sw.ports) do
		local phys = M.physical_port(cfg, port_idx)
		if phys then
			for vlan_id, mode in pairs(p.vlans) do
				if mode == "untagged" and desired[vlan_id] then
					untagged_home[phys] = vlan_id
				elseif mode == "exclude" then
					excluded[vlan_id] = excluded[vlan_id] or {}
					excluded[vlan_id][phys] = true
				end
			end
		end
	end

	local cpu_ports = {[tostring(cfg.vlan.cpu_lan)] = true}
	if cfg.vlan.cpu_wan then cpu_ports[tostring(cfg.vlan.cpu_wan)] = true end

	local stock_edits = {}  -- section name -> new ports string
	cursor:foreach("network", "switch_vlan", function(s)
		local name = s[".name"]
		if not name or name:match("^" .. OPENUF_VLAN_PREFIX) then return end
		local vid = tonumber(s.vlan)
		if not vid or not s.ports then return end
		local out, changed_here, non_cpu_left = {}, false, false
		for tok in tostring(s.ports):gmatch("%S+") do
			local num, tag = tok:match("^(%d+)(t?)$")
			local keep = true
			if num and not cpu_ports[num] then
				local phys = tonumber(num)
				local home = untagged_home[phys]
				if excluded[vid] and excluded[vid][phys] then
					if tag == "t" or (home and home ~= vid) then
						keep = false
					end
				elseif tag == "" and home and home ~= vid then
					keep = false
				end
			end
			if keep then
				out[#out + 1] = tok
				if num and not cpu_ports[num] then non_cpu_left = true end
			else
				changed_here = true
			end
		end
		if changed_here then
			if vid == mgmt_vlan and not non_cpu_left then
				io.stderr:write(("switchvlan: not stripping %s (management "
					.. "VLAN %d) -- it would lose its last downstream port\n")
					:format(name, vid))
			else
				stock_edits[name] = table.concat(out, " ")
			end
		end
	end)

	-- Reconcile: drop every openuf_swvlan* section this push no longer
	-- wants. Without this, removing a VLAN in the controller left its
	-- orphan section programming the switch forever.
	local changed = false
	local doomed = {}
	cursor:foreach("network", "switch_vlan", function(s)
		local vid = s[".name"] and s[".name"]:match("^" .. OPENUF_VLAN_PREFIX .. "(%d+)$")
		if vid and desired[tonumber(vid)] == nil then
			doomed[#doomed + 1] = s[".name"]
		end
	end)
	for _, name in ipairs(doomed) do
		cursor:delete("network", name)
		changed = true
	end

	if next(desired) or next(stock_edits) then
		-- Snapshot the stock sections' port strings once, before the first
		-- mutation, so restore() can put them back. Only taken when we are
		-- about to write or strip sections -- a reconcile-only pass has no
		-- new mutation to ledger.
		st.swvlan_backup = st.swvlan_backup or (function()
			local snap = {}
			cursor:foreach("network", "switch_vlan", function(s)
				if s.vlan and s.ports then snap[tostring(s.vlan)] = s.ports end
			end)
			return snap
		end)()

		for name, ports in pairs(stock_edits) do
			cursor:set("network", name, "ports", ports)
			changed = true
		end

		for vlan_id, ports in pairs(desired) do
			local section = OPENUF_VLAN_PREFIX .. tostring(vlan_id)
			if cursor:get("network", section, "ports") ~= ports then
				cursor:set("network", section, "switch_vlan")
				cursor:set("network", section, "device",
					(cfg.vlan.device) or "switch0")
				cursor:set("network", section, "vlan", tostring(vlan_id))
				cursor:set("network", section, "ports", ports)
				changed = true
			end
		end
	end

	-- No-op discipline: every steady-state setparam re-carries this block, and
	-- reloading the network on each one would bounce the uplink every inform.
	-- Same class of hazard as the DHCP flush guarded in inform.lua.
	if not changed then return false end

	cursor:commit("network")
	M._exec("/etc/init.d/network reload 2>/dev/null")
	return true
end

-- Undo everything apply() wrote: drop openUF's sections and put the stock
-- sections' port strings back.
function M.restore(st)
	local uci = get_uci()
	local cursor = uci.cursor()
	local removed = false
	local doomed = {}
	cursor:foreach("network", "switch_vlan", function(s)
		if s[".name"] and s[".name"]:match("^" .. OPENUF_VLAN_PREFIX) then
			doomed[#doomed + 1] = s[".name"]
		end
	end)
	for _, name in ipairs(doomed) do
		cursor:delete("network", name)
		removed = true
	end
	if st and st.swvlan_backup then
		cursor:foreach("network", "switch_vlan", function(s)
			local orig = s.vlan and st.swvlan_backup[tostring(s.vlan)]
			if orig and s.ports ~= orig then
				cursor:set("network", s[".name"], "ports", orig)
				removed = true
			end
		end)
		st.swvlan_backup = nil
	end
	if removed then
		cursor:commit("network")
		M._exec("/etc/init.d/network reload 2>/dev/null")
	end
	return removed
end

return M
