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
}
