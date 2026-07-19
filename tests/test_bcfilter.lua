-- Tests for openuf/bcfilter.lua ("Multicast and Broadcast Blocker" nftables
-- enforcement). Run from project root: lua tests/run_tests.lua
--
-- The generated nft syntax was checked against a real nftables 1.0.9 while
-- writing this (see the module's comments on oifname vs oif, and on meta
-- pkttype vs the invalid `ether daddr type multicast`); these tests pin the
-- command shape so a regression in it is visible.

local bcfilter = dofile("openuf/bcfilter.lua")

-- Capture nft invocations instead of running them.
local function with_bcfilter(fn)
	local orig = bcfilter._exec
	local cmds = {}
	bcfilter._exec = function(cmd) cmds[#cmds + 1] = cmd; return true end
	local ok, err = pcall(fn, cmds)
	bcfilter._exec = orig
	if not ok then error(err, 0) end
end

local function joined(cmds) return table.concat(cmds, "\n") end

local function contains(cmds, needle)
	return joined(cmds):find(needle, 1, true) ~= nil
end

return {
	{
		name = "bcfilter: reconcile rebuilds its own table from scratch",
		fn = function()
			with_bcfilter(function(cmds)
				bcfilter.reconcile({})
				assert_true(contains(cmds, "nft delete table bridge openuf_bcfilt"),
					"deletes before recreating (idempotent)")
				assert_true(contains(cmds, "nft add table bridge openuf_bcfilt"),
					"recreates the table")
				assert_true(contains(cmds, "nft add chain bridge openuf_bcfilt bcfilt"),
					"creates the filter chain")
				-- The hook spec is what makes the chain filter anything at
				-- all -- a chain with a corrupted hook/priority passes every
				-- other assertion while filtering nothing.
				assert_true(contains(cmds, "'{ type filter hook forward priority 0; }'"),
					"chain is hooked into forward at priority 0")
			end)
		end
	},
	{
		name = "bcfilter: reconcile uses a table separate from firewall.lua's",
		fn = function()
			with_bcfilter(function(cmds)
				bcfilter.reconcile({})
				-- firewall.lua deletes and recreates `bridge openuf` wholesale on
				-- every block/unblock; sharing that table would wipe these rules.
				assert_false(joined(cmds):find("bridge openuf ", 1, true) ~= nil,
					"never touches firewall.lua's `bridge openuf` table")
			end)
		end
	},
	{
		name = "bcfilter: reconcile emits a per-interface allow set and drop rule",
		fn = function()
			with_bcfilter(function(cmds)
				bcfilter.reconcile({
					{ifname = "wlan0", macs = {"aa:bb:cc:dd:ee:ff"}},
				})
				assert_true(contains(cmds, "add set bridge openuf_bcfilt allow_wlan0"),
					"per-interface set")
				assert_true(contains(cmds, "allow_wlan0 '{ aa:bb:cc:dd:ee:ff }'"),
					"allow-listed MAC added as an element")
				assert_true(contains(cmds, 'oifname \'"wlan0"\''),
					"matches by interface NAME, so a not-yet-created netdev is fine")
				assert_true(contains(cmds, "meta pkttype '{ broadcast, multicast }'"),
					"matches group-addressed traffic")
				assert_true(contains(cmds, "ether saddr != @allow_wlan0 drop"),
					"drops unless the SENDER is allow-listed")
			end)
		end
	},
	{
		name = "bcfilter: reconcile keeps each VAP's allow-list in its own set",
		fn = function()
			with_bcfilter(function(cmds)
				bcfilter.reconcile({
					{ifname = "wlan0", macs = {"aa:aa:aa:aa:aa:aa"}},
					{ifname = "wlan1", macs = {"bb:bb:bb:bb:bb:bb"}},
				})
				assert_true(contains(cmds, "allow_wlan0 '{ aa:aa:aa:aa:aa:aa }'"),
					"wlan0 keeps its own MAC")
				assert_true(contains(cmds, "allow_wlan1 '{ bb:bb:bb:bb:bb:bb }'"),
					"wlan1 keeps its own MAC")
				assert_false(contains(cmds, "allow_wlan0 '{ bb:bb:bb:bb:bb:bb }'"),
					"lists are not merged across VAPs")
			end)
		end
	},
	{
		name = "bcfilter: an empty allow-list still installs the drop rule",
		fn = function()
			with_bcfilter(function(cmds)
				-- "Blocker on, nothing excepted" is a real (aggressive) setting,
				-- not a no-op -- it must not silently degrade to allowing all.
				bcfilter.reconcile({{ifname = "wlan0", macs = {}}})
				assert_true(contains(cmds, "ether saddr != @allow_wlan0 drop"),
					"drop rule present with an empty set")
			end)
		end
	},
	{
		name = "bcfilter: reconcile is a safe no-op with nil rules",
		fn = function()
			with_bcfilter(function(cmds)
				bcfilter.reconcile(nil)
				assert_false(contains(cmds, "add rule"), "no drop rules emitted")
			end)
		end
	},
	{
		name = "bcfilter: reconcile skips entries with no resolved ifname",
		fn = function()
			with_bcfilter(function(cmds)
				-- get_ifname_for_vap returns nil off-target or for a downed
				-- radio; a rule with no interface would apply network-wide.
				bcfilter.reconcile({{ifname = nil, macs = {"aa:bb:cc:dd:ee:ff"}}})
				assert_false(contains(cmds, "add rule"), "no unscoped rule emitted")
			end)
		end
	},
}
