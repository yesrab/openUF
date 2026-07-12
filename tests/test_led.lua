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
}
