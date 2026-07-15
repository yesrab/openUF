-- Pure Lua 5.1 test runner. Run from project root: lua tests/run_tests.lua
-- No external deps. Exit code 0 = all pass, 1 = any failure.
-- Each test file must return a list of {name=..., fn=...} tables.

local passed = 0
local failed = 0

-- Global assert helpers available to all test files

function assert_eq(got, expected, label)
	if got ~= expected then
		error(string.format("%s\n  expected: %s\n  got:      %s",
			label or "(no label)", tostring(expected), tostring(got)), 2)
	end
end

function assert_neq(got, notexpected, label)
	if got == notexpected then
		error(string.format("%s: expected a different value, both are %s",
			label or "(no label)", tostring(got)), 2)
	end
end

function assert_true(val, label)
	if not val then
		error(string.format("%s: expected true, got %s",
			label or "(no label)", tostring(val)), 2)
	end
end

function assert_false(val, label)
	if val then
		error(string.format("%s: expected false, got %s",
			label or "(no label)", tostring(val)), 2)
	end
end

function assert_nil(val, label)
	if val ~= nil then
		error(string.format("%s: expected nil, got %s",
			label or "(no label)", tostring(val)), 2)
	end
end

function assert_not_nil(val, label)
	if val == nil then
		error(string.format("%s: expected non-nil", label or "(no label)"), 2)
	end
end

function assert_error(fn, label)
	local ok = pcall(fn)
	if ok then
		error(string.format("%s: expected an error but none was raised",
			label or "(no label)"), 2)
	end
end

function assert_contains(str, sub, label)
	if type(str) ~= "string" or not str:find(sub, 1, true) then
		error(string.format("%s: expected %q to contain %q",
			label or "(no label)", tostring(str), tostring(sub)), 2)
	end
end

function assert_bytes_eq(got, expected, label)
	-- Compare two binary strings; show hex diff on failure
	if got ~= expected then
		local function to_hex(s)
			return s:gsub(".", function(c)
				return string.format("%02x ", string.byte(c))
			end)
		end
		error(string.format("%s\n  expected (%d bytes): %s\n  got      (%d bytes): %s",
			label or "(no label)", #expected, to_hex(expected), #got, to_hex(got)), 2)
	end
end

-- Run a list of {name, fn} test entries
local function run_suite(tests)
	for _, t in ipairs(tests) do
		local ok, err = pcall(t.fn)
		if ok then
			passed = passed + 1
			print("PASS  " .. t.name)
		else
			failed = failed + 1
			print("FAIL  " .. t.name)
			print("      " .. tostring(err):gsub("\n", "\n      "))
		end
	end
end

-- Test files to run in order.
-- Files that don't exist yet are silently skipped so the runner
-- remains useful during incremental development.
local test_files = {
	"tests/test_lib.lua",
	"tests/test_announce.lua",
	"tests/test_state.lua",
	"tests/test_crypto.lua",
	"tests/test_inform_packet.lua",
	"tests/test_sysinfo.lua",
	"tests/test_lldp.lua",
	"tests/test_syswrapper.lua",
	"tests/test_inform_json.lua",
	"tests/test_led.lua",
	"tests/test_ucihelper.lua",
	"tests/test_usteer.lua",
	"tests/test_netconfig.lua",
	"tests/test_firewall.lua",
}

for _, filepath in ipairs(test_files) do
	local fn, err = loadfile(filepath)
	if not fn then
		-- Missing file during incremental development — skip silently
		if err and not err:find("No such file") and not err:find("cannot open") then
			print("ERROR loading " .. filepath .. ": " .. tostring(err))
			failed = failed + 1
		end
	else
		local ok, result = pcall(fn)
		if not ok then
			print("ERROR running " .. filepath .. ": " .. tostring(result))
			failed = failed + 1
		elseif type(result) == "table" then
			run_suite(result)
		end
	end
end

print(string.format("\nResults: %d passed, %d failed", passed, failed))
os.exit(failed == 0 and 0 or 1)
