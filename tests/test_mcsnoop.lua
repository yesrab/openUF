-- Tests for openuf/mcsnoop.lua (IGMP/MLD snooping on the bridges, sysfs only).
-- Run from project root: lua tests/run_tests.lua

local mcsnoop = dofile("openuf/mcsnoop.lua")

local function p(bridge, name) return "/sys/class/net/" .. bridge .. "/bridge/" .. name end

-- A fake sysfs: `fs` maps path -> value, the ledger file included. `reject`
-- makes a write to that path fail. Returns the list of writes.
local function with_sysfs(fs, fn, reject)
	local o_cmd, o_w, o_r, o_rm = mcsnoop._run_cmd, mcsnoop._write_file, mcsnoop._read_file, os.remove
	local writes = {}
	mcsnoop._run_cmd = function()
		local out = {}
		for path in pairs(fs) do
			local br = path:match("^/sys/class/net/(br%-openuf[^/]*)/bridge/multicast_snooping$")
			if br then out[#out + 1] = "/sys/class/net/" .. br .. "/bridge" end
		end
		return table.concat(out, "\n") .. (#out > 0 and "\n" or "")
	end
	mcsnoop._write_file = function(path, v)
		if reject and reject[path] then return false end
		if path ~= mcsnoop.LEDGER then writes[#writes + 1] = {path = path, v = v} end
		fs[path] = v
		return true
	end
	mcsnoop._read_file = function(path) return fs[path] end
	os.remove = function(path) fs[path] = nil; return true end
	local ok, err = pcall(fn, writes)
	mcsnoop._run_cmd, mcsnoop._write_file, mcsnoop._read_file, os.remove = o_cmd, o_w, o_r, o_rm
	if not ok then error(err, 0) end
end

local function bridge(fs, name, snooping, querier, hash)
	fs[p(name, "multicast_snooping")] = snooping .. "\n"
	fs[p(name, "multicast_querier")] = (querier or "0") .. "\n"
	fs[p(name, "hash_max")] = (hash or "4096") .. "\n"
end

return {
	{
		-- A U6 Pro's bridge.conf / mcsd.conf: multicast_snooping 1,
		-- multicast_querier 0, hash_max 2048 on br0 and every br0.<vlan>.
		name = "mcsnoop: on writes the U6 Pro's three values to the LAN bridge and every openUF VLAN bridge",
		fn = function()
			local fs = {}
			bridge(fs, "br-lan", "0", "1")
			bridge(fs, "br-openuf10", "0")
			bridge(fs, "br-guest", "0")   -- somebody else's bridge
			with_sysfs(fs, function(writes)
				local n = mcsnoop.resync(true, "br-lan")
				assert_eq(n, 5, "three values on br-lan, two on the VLAN bridge whose querier is already off")
				assert_eq(writes[1].path, p("br-lan", "hash_max"), "the table size first")
				assert_eq(fs[p("br-lan", "hash_max")], "2048", "hash_max")
				assert_eq(fs[p("br-lan", "multicast_querier")], "0", "the bridge never queries")
				assert_eq(fs[p("br-lan", "multicast_snooping")], "1", "snooping on")
				assert_eq(fs[p("br-openuf10", "multicast_snooping")], "1", "the VLAN bridge too")
				assert_eq(fs[p("br-guest", "multicast_snooping")], "0\n", "a bridge openUF does not serve is left alone")
				assert_eq(fs[mcsnoop.LEDGER], "br-lan\nbr-openuf10\n", "what was switched is remembered")
				assert_eq(mcsnoop.resync(true, "br-lan"), 0, "a second pass writes nothing")
			end)
		end
	},
	{
		name = "mcsnoop: a bridge netifd re-created is switched again, one value at a time",
		fn = function()
			local fs = {}
			bridge(fs, "br-lan", "0")
			with_sysfs(fs, function()
				mcsnoop.resync(true, "br-lan")
				fs[p("br-lan", "multicast_snooping")] = "0\n"   -- re-created
				assert_eq(mcsnoop.resync(true, "br-lan"), 1, "only the value that drifted")
				assert_eq(fs[p("br-lan", "multicast_snooping")], "1", "back on")
			end)
		end
	},
	{
		name = "mcsnoop: off puts back only the bridges openUF switched",
		fn = function()
			local fs = {}
			bridge(fs, "br-lan", "0")
			bridge(fs, "br-openuf10", "1", "1", "512")   -- the operator's own snooping bridge
			with_sysfs(fs, function(writes)
				assert_eq(mcsnoop.resync(true, "br-lan"), 2, "br-lan only: table size and snooping")
				assert_eq(fs[p("br-openuf10", "multicast_querier")], "1\n", "the operator's querier is kept")
				assert_eq(fs[p("br-openuf10", "hash_max")], "512\n", "and their table size")
				assert_eq(fs[mcsnoop.LEDGER], "br-lan\n", "theirs is not in the ledger")
				local before = #writes
				assert_eq(mcsnoop.resync(false, "br-lan"), 1, "one bridge to put back")
				assert_eq(writes[before + 1].path, p("br-lan", "multicast_snooping"), "snooping only")
				assert_eq(fs[p("br-lan", "multicast_snooping")], "0", "off again")
				assert_eq(fs[p("br-openuf10", "multicast_snooping")], "1\n", "theirs still snoops")
				assert_nil(fs[mcsnoop.LEDGER], "nothing left to remember")
				assert_eq(mcsnoop.resync(false, "br-lan"), 0, "and off stays quiet")
			end)
		end
	},
	{
		name = "mcsnoop: no LAN bridge named, a kernel without snooping, a refused write",
		fn = function()
			local fs = {}
			bridge(fs, "br-openuf20", "0")
			with_sysfs(fs, function()
				assert_eq(mcsnoop.resync(true, nil), 2, "the VLAN bridge alone: the LAN bridge is never guessed")
				assert_eq(mcsnoop.resync(true, "br-lan"), 0, "a name with no bridge/multicast_snooping is skipped")
				assert_eq(mcsnoop.resync(true, "../etc"), 0, "nor anything that is not an interface name")
			end)
			fs = {}
			bridge(fs, "br-lan", "0")
			with_sysfs(fs, function()
				assert_eq(mcsnoop.resync(true, "br-lan"), 1, "the table size took, snooping was refused")
				assert_nil(fs[mcsnoop.LEDGER], "a bridge that did not start snooping is not ours")
			end, {[p("br-lan", "multicast_snooping")] = true})
		end
	},
}
