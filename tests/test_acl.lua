-- Tests for the LuCI rpcd ACL: a read-only grant must not start, stop or
-- un-adopt the device.
-- Run from project root: lua tests/run_tests.lua

local cjson = require("cjson")

local function acl()
	local f = io.open("package/luci-app-openuf/root/usr/share/rpcd/acl.d/luci-app-openuf.json")
	if not f then return nil end  -- the stripped dist tree has no package/
	local d = cjson.decode(f:read("*a")); f:close()
	return d["luci-app-openuf"]
end

return {
	{
		name = "acl: read cannot restart, start, stop or reset-inform; write can",
		fn = function()
			local a = acl()
			if not a then return end
			for _, cmd in ipairs({"/etc/init.d/openuf restart", "/etc/init.d/openuf start",
				"/etc/init.d/openuf stop", "/usr/bin/openuf reset-inform"}) do
				assert_eq(a.read.file[cmd], nil, "read must not grant: " .. cmd)
				assert_true(a.write.file[cmd] ~= nil, "write grants: " .. cmd)
			end
		end
	},
	{
		-- `openuf ota`: looking is read, installing is write, and the only
		-- form a session may start is the detached one with a tag.
		name = "acl: read can check for an update and follow one; only write can start it",
		fn = function()
			local a = acl()
			if not a then return end
			assert_true(a.read.file["/usr/bin/openuf ota --check"] ~= nil, "read: --check")
			assert_true(a.read.file["/usr/bin/openuf ota --status"] ~= nil, "read: --status")
			for cmd in pairs(a.read.file) do
				assert_nil(cmd:find("ota --start", 1, true), "read must not start an update: " .. cmd)
				assert_nil(cmd:find("ota --install", 1, true), "nor run one: " .. cmd)
			end
			assert_true(a.write.file["/usr/bin/openuf ota --start --tag *"] ~= nil, "write: --start --tag")
		end
	},
}
