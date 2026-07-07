--[[
	LED control for the controller-triggered "locate" identify action.

	Drives a Linux LED-class sysfs directory (dev.conf.led in conf.lua, e.g.
	"/sys/class/leds/tp-link:green:wlan"). All operations are safe no-ops when
	led_path is nil (unconfigured hardware) or the sysfs path doesn't exist --
	callers don't need to check availability themselves.
]]--

local M = {}

-- Injectable: file writer, for sysfs LED control.
M._write_file = function(path, contents)
	local f = io.open(path, "w")
	if not f then return false end
	f:write(contents)
	f:close()
	return true
end

-- Start the "locate" identify blink pattern (fast timer blink).
function M.locate_start(led_path)
	if not led_path then return false end
	M._write_file(led_path .. "/trigger", "timer")
	M._write_file(led_path .. "/delay_on", "250")
	M._write_file(led_path .. "/delay_off", "250")
	return true
end

-- Stop the "locate" identify blink pattern, returning the LED trigger to none
-- (the status-LED logic, if any, is responsible for restoring its own state).
function M.locate_stop(led_path)
	if not led_path then return false end
	M._write_file(led_path .. "/trigger", "none")
	return true
end

return M
