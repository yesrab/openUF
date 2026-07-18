-- Tests for openuf/led.lua (locate LED sysfs control).
-- Run from project root: lua tests/run_tests.lua

local led = dofile("openuf/led.lua")

local function with_capture(fn)
	local writes = {}
	local orig = led._write_file
	led._write_file = function(path, contents)
		writes[#writes + 1] = {path = path, contents = contents}
		return true
	end
	fn(writes)
	led._write_file = orig
end

return {
	{
		name = "led: locate_start returns false with nil led_path (no-op)",
		fn = function()
			assert_false(led.locate_start(nil), "no-op without led_path")
		end
	},
	{
		name = "led: locate_stop returns false with nil led_path (no-op)",
		fn = function()
			assert_false(led.locate_stop(nil), "no-op without led_path")
		end
	},
	{
		name = "led: locate_start writes timer trigger and blink delays",
		fn = function()
			with_capture(function(writes)
				local ok = led.locate_start("/sys/class/leds/test")
				assert_true(ok, "locate_start returns true")
				assert_eq(#writes, 3, "three sysfs writes")
				assert_eq(writes[1].path, "/sys/class/leds/test/trigger", "trigger path")
				assert_eq(writes[1].contents, "timer", "trigger set to timer")
				assert_eq(writes[2].path, "/sys/class/leds/test/delay_on", "delay_on path")
				assert_eq(writes[3].path, "/sys/class/leds/test/delay_off", "delay_off path")
			end)
		end
	},
	{
		name = "led: locate_stop writes trigger=none",
		fn = function()
			with_capture(function(writes)
				local ok = led.locate_stop("/sys/class/leds/test")
				assert_true(ok, "locate_stop returns true")
				assert_eq(#writes, 1, "one sysfs write")
				assert_eq(writes[1].path, "/sys/class/leds/test/trigger", "trigger path")
				assert_eq(writes[1].contents, "none", "trigger cleared")
			end)
		end
	},
	{
		name = "led: set_enabled returns false with nil led_path (no-op)",
		fn = function()
			assert_false(led.set_enabled(nil, true), "no-op without led_path")
		end
	},
	{
		name = "led: set_enabled(true) writes trigger=none and brightness=1",
		fn = function()
			with_capture(function(writes)
				local ok = led.set_enabled("/sys/class/leds/test", true)
				assert_true(ok, "set_enabled returns true")
				assert_eq(#writes, 2, "two sysfs writes")
				assert_eq(writes[1].path, "/sys/class/leds/test/trigger", "trigger path")
				assert_eq(writes[1].contents, "none", "trigger cleared")
				assert_eq(writes[2].path, "/sys/class/leds/test/brightness", "brightness path")
				assert_eq(writes[2].contents, "1", "brightness on")
			end)
		end
	},
	{
		name = "led: set_enabled(false) writes brightness=0",
		fn = function()
			with_capture(function(writes)
				led.set_enabled("/sys/class/leds/test", false)
				assert_eq(writes[2].contents, "0", "brightness off")
			end)
		end
	},

	-- dev.conf.led shapes. The modelmaps disagreed historically (one nil, one
	-- a {name, desc, sysfs} table) while led.lua concatenated the value
	-- directly, so a Locate click threw "attempt to concatenate a table
	-- value" out of handle_response -- which inform.lua does not pcall, so it
	-- killed the daemon. All shapes now resolve, and an unusable one no-ops.
	{
		name = "led: bare LED name resolves under /sys/class/leds",
		fn = function()
			with_capture(function(writes)
				assert_true(led.locate_start("tp-link:green:system"), "resolves")
				assert_eq(writes[1].path,
					"/sys/class/leds/tp-link:green:system/trigger",
					"bare name gets the sysfs root prefix")
			end)
		end
	},
	{
		name = "led: full sysfs path is used as-is",
		fn = function()
			with_capture(function(writes)
				led.locate_start("/sys/class/leds/x:green:y")
				assert_eq(writes[1].path, "/sys/class/leds/x:green:y/trigger",
					"path passed through unchanged")
			end)
		end
	},
	{
		name = "led: legacy {sysfs=...} modelmap table is accepted",
		fn = function()
			with_capture(function(writes)
				local t = {name = "uf_status", desc = "UF Status LED",
					sysfs = "tp-link:green:system"}
				assert_true(led.set_enabled(t, true), "table resolves")
				assert_eq(writes[1].path,
					"/sys/class/leds/tp-link:green:system/trigger",
					"sysfs field extracted and prefixed")
			end)
		end
	},
	{
		name = "led: unusable led config no-ops instead of throwing",
		fn = function()
			for _, bad in ipairs({42, true, "", {}, {sysfs = 7}}) do
				assert_false(led.locate_start(bad), "locate_start no-op")
				assert_false(led.locate_stop(bad), "locate_stop no-op")
				assert_false(led.set_enabled(bad, true), "set_enabled no-op")
			end
		end
	},
}
