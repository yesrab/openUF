--[[
	"Multicast and Broadcast Blocker" enforcement (Settings -> WiFi -> [WLAN]).

	The controller pushes this per WLAN as wireless.<n>.bcfilt.status plus a
	bcfilt.<k>.mac allow-list -- see inform.lua's parser for the live wire
	evidence. Unlike every other WLAN setting openUF carries, there is no
	hostapd or OpenWrt option for it: hostapd can suppress group-addressed
	frames wholesale (ap_isolate, disable_dgaf) but has no notion of an
	allow-list, so this is enforced with nftables instead.

	WHAT IT DOES, and why that is deliberately destructive:

	Per Ubiquiti's own documentation this blocks LAN->WLAN multicast and
	broadcast traffic except from the listed source MACs. That genuinely breaks
	DHCP for wireless clients unless the DHCP server's MAC is on the list --
	Ubiquiti documents exactly that, and instructs admins to add it. So the
	filter here is faithful to the controller's intent and deliberately does
	NOT carve out DHCP/ARP exemptions of its own: an admin who enabled this
	control and curated an allow-list would find a silent "helpful" exemption
	harder to debug than the documented behavior.

	The match is on SOURCE MAC in the to-wireless direction: a group-addressed
	frame heading out a managed VAP is dropped unless its sender is
	allow-listed. (Group destinations are not per-station addresses, so a
	destination match could not express an allow-list at all.)

	Mechanism mirrors firewall.lua: a dedicated `bridge` table rebuilt from
	scratch on every reconcile rather than diffed, so it is idempotent and
	self-healing. It uses its OWN table, separate from firewall.lua's `bridge
	openuf` -- that module deletes and recreates its whole table on each
	block/unblock, which would otherwise wipe these rules.

	NOT verified against real hardware or real radios: the validation
	environment has neither, so what is confirmed here is the wire format and
	the generated ruleset, not its on-air effect.
]]--

local M = {}

-- Injectable: shell command runner, for real `nft` invocations.
M._exec = function(cmd) return os.execute(cmd) end

local NFT_TABLE = "bridge openuf_bcfilt"

-- Rebuild the filter to exactly match rules, a list of
-- {ifname = "wlan0", macs = {"aa:bb:..", ...}} entries -- one per VAP that has
-- the control enabled. A VAP with an empty allow-list still belongs here: that
-- is "block all group-addressed traffic to this SSID", which is a meaningful
-- (if aggressive) setting rather than a no-op.
--
-- Safe with an empty/nil list (leaves an empty table in place, blocking
-- nothing) and safe to call repeatedly.
function M.reconcile(rules)
	M._exec("nft delete table " .. NFT_TABLE .. " 2>/dev/null")
	M._exec("nft add table " .. NFT_TABLE)
	M._exec("nft add chain " .. NFT_TABLE ..
		" bcfilt '{ type filter hook forward priority 0; }'")

	for _, rule in ipairs(rules or {}) do
		if rule.ifname then
			-- One set per interface, so each SSID keeps its own allow-list.
			local set = "allow_" .. rule.ifname:gsub("[^%w]", "_")
			M._exec("nft add set " .. NFT_TABLE .. " " .. set ..
				" '{ type ether_addr; }'")
			for _, mac in ipairs(rule.macs or {}) do
				M._exec("nft add element " .. NFT_TABLE .. " " .. set ..
					" '{ " .. mac .. " }' 2>/dev/null")
			end
			-- Matches frames leaving via this VAP (the LAN->WLAN direction)
			-- that are group-addressed and not from an allow-listed sender.
			--
			-- oifname, not oif: `oif` resolves the interface to an index when
			-- the rule is added and so fails outright if it does not exist
			-- yet -- fatal here, since these rules are (re)built around a
			-- `wifi reload` that tears the wireless netdevs down and back up.
			-- oifname matches on the name and tolerates its absence. Both were
			-- checked against nftables 1.0.9: `oif wlan0` errors with
			-- "Interface does not exist", `oifname "wlan0"` accepts.
			--
			-- meta pkttype names broadcast and multicast explicitly; an
			-- earlier draft used `ether daddr type multicast`, which is not
			-- valid nft syntax at all (it parses as far as `type` and stops).
			M._exec("nft add rule " .. NFT_TABLE .. " bcfilt oifname '\"" ..
				rule.ifname .. "\"' meta pkttype '{ broadcast, multicast }'" ..
				" ether saddr != @" .. set .. " drop")
		end
	end
	return true
end

return M
