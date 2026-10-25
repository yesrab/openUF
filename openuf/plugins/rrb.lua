--[[
	plugins/rrb.lua -- the first built-in plugin: 802.11r fast roaming with
	genuine UniFi APs through the translator in rrb/ (the openuf-rrb service).

	Everything the integration needs beyond per-WLAN options is a hook here,
	which is how the hooks in plugins.lua were arrived at:

	  before_push    create the veth pair (netifd sections + a network reload)
	                 before the WLANs are written, so ftinterop sees it on the
	                 same push; only while the translator is active
	  vap_options    ftinterop.apply: UniFi's mobility domain, the key holders
	                 (learned peers from this plugin's store, hand-listed ones
	                 from openuf.rrb), nasid, ft_iface on the veth
	  after_push     restart the daemon when a BSS went onto the veth: it
	                 derives the served BSSes and the LAN bridge at start
	  tick           read what the daemon heard on the LAN into the store and
	                 ask for a re-push when a new peer has a mobility domain
	  on_forget      remove the veth pair (after the WLANs are gone) and the
	                 learned peers
	  status         for the LuCI pages
	  packages       ucode-mod-socket, kmod-veth (openuf deps)
	  services       openuf-rrb

	Enabled by conf.lua / openuf.main unifi_ft_interop (ftinterop.lua says
	what the switch means). The daemon's own settings are the rrb section of
	/etc/config/openuf (the init script documents them).
]]--

local fti = package.loaded["openuf.ftinterop"]
	or (loadfile("ftinterop.lua") or loadfile("openuf/ftinterop.lua"))()

local P = {name = "rrb", api = 1}

P.packages = {
	{pkg = "ucode-mod-socket", evidence = "file:/usr/lib/ucode/socket.so",
	 unlocks = "802.11r roaming with genuine UniFi APs: raw packet sockets for the translator"},
	{pkg = "kmod-veth", evidence = "kmod:veth",
	 unlocks = "802.11r roaming with genuine UniFi APs: the veth pair that carries the key exchange to the translator"},
}
P.services = {"openuf-rrb"}

-- The netifd sections of the veth pair (ensure_veth writes, on_forget removes).
P.VETH_SECTIONS = {"openuf_ftveth", "openuf_ftlink", "openuf_ftpeer"}
P.INIT = "/etc/init.d/openuf-rrb"

function P.enabled(cfg)
	return cfg and cfg.config and cfg.config.unifi_ft_interop == true or false
end

local function veth_names(cursor, util)
	local ft = cursor and cursor:get(fti.RRB_CONFIG, fti.RRB_SECTION, "ft_iface")
	local peer = cursor and cursor:get(fti.RRB_CONFIG, fti.RRB_SECTION, "peer_iface")
	if type(ft) ~= "string" or not util.valid_ifname(ft) then ft = fti.DEFAULT_FT_IFACE end
	if type(peer) ~= "string" or not util.valid_ifname(peer) then peer = "vft1" end
	return ft, peer
end

-- True when hostapd's end of the pair exists afterwards. Writes the sections
-- only when missing or naming other interfaces, reloads the network at once
-- (this push is about to write the WLANs that use the veth; ftinterop decides
-- per WLAN on whether the netdev exists) and gives netifd a few seconds. The
-- pair is a netifd `config device` of type veth plus two proto-none
-- interfaces, so netifd creates it at boot before the radios come up: a BSS
-- whose ft_iface is missing fails to start.
function P.ensure_veth(ctx)
	local cursor = ctx.cursor()
	local ft, peer = veth_names(cursor, ctx.util)
	local function present() return ctx.read_file("/sys/class/net/" .. ft .. "/ifindex") ~= nil end
	if present() then return true end
	local dev, link, peerif = P.VETH_SECTIONS[1], P.VETH_SECTIONS[2], P.VETH_SECTIONS[3]
	if cursor:get("network", dev, "name") ~= ft or cursor:get("network", dev, "peer_name") ~= peer then
		cursor:set("network", dev, "device")
		cursor:set("network", dev, "type", "veth")
		cursor:set("network", dev, "name", ft)
		cursor:set("network", dev, "peer_name", peer)
		cursor:set("network", link, "interface")
		cursor:set("network", link, "proto", "none")
		cursor:set("network", link, "device", ft)
		cursor:set("network", peerif, "interface")
		cursor:set("network", peerif, "proto", "none")
		cursor:set("network", peerif, "device", peer)
		cursor:commit("network")
	end
	ctx.reload_network()
	for _ = 1, 5 do
		if present() then return true end
		ctx.run("sleep 1")
	end
	ctx.log("the veth " .. ft .. " did not appear after the network reload; hostapd stays on the bridge this push")
	return false
end

-- Removes the pair's sections when present; true when something was removed.
function P.remove_veth(ctx)
	local cursor = ctx.cursor()
	local present = {}
	for _, t in ipairs({"device", "interface"}) do
		cursor:foreach("network", t, function(s) present[s[".name"]] = true end)
	end
	local removed = false
	for _, s in ipairs(P.VETH_SECTIONS) do
		if present[s] then
			cursor:delete("network", s)
			removed = true
		end
	end
	if removed then
		cursor:commit("network")
		ctx.reload_network()
	end
	return removed
end

-- Per push: whether a BSS went onto the veth (after_push restarts the daemon).
local on_veth = false

function P.before_push(ctx, push)
	on_veth = false
	if not fti.translator_active(ctx.cursor()) then return end
	local any_ft = false
	for _, vap in ipairs(push.vaps or {}) do
		if vap.fast_roaming_enabled or vap.wpa3_fast_roaming_enabled then any_ft = true end
	end
	if any_ft then P.ensure_veth(ctx) end
end

function P.vap_options(extra, vap, ctx)
	-- Only an FT WLAN: the built-in block put ieee80211r there when the
	-- controller asked for fast roaming.
	if extra.ieee80211r ~= "1" then return end
	local learned = ctx.store and ctx.store.peers or nil
	fti.apply(extra, vap, ctx.bssid(vap.radio, vap.ssid), ctx.cursor(), ctx.DELETE, learned)
	if type(extra.hostapd_bss_options) == "table" then on_veth = true end
end

-- The daemon derives the served BSSes and the LAN bridge from the running
-- hostapd configs at start, and its own reload trigger fires on LuCI's
-- reload_config, never on openUF's `wifi reload`: restart it after the
-- reload that wrote the configs it will read. A push is a rare event, and
-- the daemon keeps what it learned in its peers file.
function P.after_push(ctx)
	if on_veth and ctx.exists(P.INIT) then
		ctx.run(P.INIT .. " restart")
	end
	on_veth = false
end

-- The daemon records every UniFi BSSID it hears on the LAN, with the WLAN's
-- mobility domain once a roam announcement verified with that WLAN's key
-- names it. A BSSID with a domain is a key holder for that WLAN: it goes
-- into the store (state.json, so a reboot keeps it) and, on an adopted AP,
-- the controller is asked for the full config again so apply_config writes
-- the new r0kh/r1kh lines (openUF rate-limits that). Returns nil, "learned"
-- or "repush".
function P.tick(ctx)
	if not ctx.store then return nil end
	local learned = fti.learned(ctx.read_file)
	if #learned == 0 then return nil end
	ctx.store.peers = ctx.store.peers or {}
	local new = {}
	for _, p in ipairs(learned) do
		if p.md and ctx.store.peers[p.bssid] ~= p.md then
			ctx.store.peers[p.bssid] = p.md
			new[#new + 1] = p.bssid .. " (" .. p.md .. ")"
		end
	end
	if #new == 0 then return nil end
	ctx.log("UniFi peer(s) learned: " .. table.concat(new, ", "))
	if ctx.repush and ctx.repush() then
		ctx.log("the controller is asked for the full config again; the new peer(s) become key holders then")
		return "repush"
	end
	return "learned"
end

-- After ucihelper.forget has rebuilt the WLANs without ft_iface: the veth may
-- go. The learned peers were a site's; a forgotten AP starts over.
function P.on_forget(ctx)
	P.remove_veth(ctx)
	if ctx.store then ctx.store.peers = nil end
end

function P.status(ctx)
	local cursor = ctx.cursor and ctx.cursor() or nil
	local ft, peer = veth_names(cursor, ctx.util)
	local n = 0
	for _ in pairs(ctx.store and ctx.store.peers or {}) do n = n + 1 end
	local heard = 0
	for _ in ipairs(fti.learned(ctx.read_file)) do heard = heard + 1 end
	return {
		installed = fti.translator_installed(),
		active = fti.translator_active(cursor),
		ft_iface = ft, peer_iface = peer,
		veth = ctx.read_file("/sys/class/net/" .. ft .. "/ifindex") ~= nil,
		peers = n, heard = heard,
		listed = #fti.peers(cursor),
	}
end

return P
