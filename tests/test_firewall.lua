-- Tests for openuf/firewall.lua (client block/unblock enforcement).
-- Run from project root: lua tests/run_tests.lua

local firewall = dofile("openuf/firewall.lua")

local function with_capture(fn)
	local cmds = {}
	local orig = firewall._exec
	firewall._exec = function(cmd)
		cmds[#cmds + 1] = cmd
		return true
	end
	fn(cmds)
	firewall._exec = orig
end

return {
	{
		name = "firewall: reconcile with an empty list still (re)creates the table/set/chain",
		fn = function()
			with_capture(function(cmds)
				firewall.reconcile({})
				assert_true(#cmds >= 5, "at least delete+table+set+chain+2 rules")
				assert_contains(cmds[1], "nft delete table bridge openuf", "clears any prior table first")
				assert_contains(cmds[2], "nft add table bridge openuf", "recreates the table")
				assert_contains(cmds[3], "nft add set bridge openuf blocked_macs", "recreates the set")
				local joined = table.concat(cmds, "\n")
				assert_contains(joined, "type filter hook forward priority 0", "chain hooked into bridge forward")
				assert_contains(joined, "ether saddr @blocked_macs drop", "drops traffic from a blocked MAC")
				assert_contains(joined, "ether daddr @blocked_macs drop", "drops traffic to a blocked MAC")
			end)
		end
	},
	{
		name = "firewall: reconcile adds an element per blocked MAC",
		fn = function()
			with_capture(function(cmds)
				firewall.reconcile({"aa:bb:cc:dd:ee:01", "aa:bb:cc:dd:ee:02"})
				local joined = table.concat(cmds, "\n")
				assert_contains(joined, "nft add element bridge openuf blocked_macs '{ aa:bb:cc:dd:ee:01 }'",
					"first MAC added as a set element")
				assert_contains(joined, "nft add element bridge openuf blocked_macs '{ aa:bb:cc:dd:ee:02 }'",
					"second MAC added as a set element")
			end)
		end
	},
	{
		name = "firewall: reconcile rebuilds from scratch rather than diffing (idempotent across repeat calls)",
		fn = function()
			with_capture(function(cmds)
				firewall.reconcile({"aa:bb:cc:dd:ee:01"})
				local first_count = #cmds
				firewall.reconcile({"aa:bb:cc:dd:ee:01"})
				assert_eq(#cmds, first_count * 2, "second call issues the exact same command sequence again")
			end)
		end
	},
	{
		name = "firewall: deauth issues hostapd_cli per interface",
		fn = function()
			with_capture(function(cmds)
				firewall.deauth("aa:bb:cc:dd:ee:01", {"wlan0", "wlan1"})
				assert_eq(#cmds, 2, "one hostapd_cli call per interface")
				assert_contains(cmds[1], "hostapd_cli -i wlan0 deauthenticate aa:bb:cc:dd:ee:01",
					"deauth on the first radio")
				assert_contains(cmds[2], "hostapd_cli -i wlan1 deauthenticate aa:bb:cc:dd:ee:01",
					"deauth on the second radio")
			end)
		end
	},
	{
		name = "firewall: deauth is a safe no-op with no interfaces",
		fn = function()
			with_capture(function(cmds)
				firewall.deauth("aa:bb:cc:dd:ee:01", {})
				assert_eq(#cmds, 0, "no commands issued")
			end)
			with_capture(function(cmds)
				firewall.deauth("aa:bb:cc:dd:ee:01", nil)
				assert_eq(#cmds, 0, "no commands issued for nil ifnames")
			end)
		end
	},
	{
		name = "firewall: reconcile skips a malformed MAC and deauth refuses one",
		fn = function()
			-- The list comes from the controller by way of state.json, which is
			-- also hand-editable; every entry is spliced into a command line.
			local real = io.stderr
			io.stderr = {write = function() end}
			local ok, err = pcall(with_capture, function(cmds)
				firewall.reconcile({"aa:bb:cc:dd:ee:01", "aa }' ; reboot ; '{"})
				local joined = table.concat(cmds, "\n")
				assert_contains(joined, "'{ aa:bb:cc:dd:ee:01 }'", "the well-formed MAC is added")
				assert_true(joined:find("reboot", 1, true) == nil, "the malformed one never reaches nft")
				local n = #cmds
				assert_false(firewall.deauth("aa }' ; reboot", {"wlan0"}), "deauth refuses it")
				assert_eq(#cmds, n, "and runs nothing")
				assert_true(firewall.deauth("aa:bb:cc:dd:ee:01", {"wlan0"}), "a real MAC still works")
				assert_eq(#cmds, n + 1, "one hostapd_cli call")
			end)
			io.stderr = real
			if not ok then error(err, 0) end
		end
	},
}
