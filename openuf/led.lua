--[[
	LED control for the controller-triggered "locate" identify action.

	Drives a Linux LED-class sysfs directory, configured as dev.conf.led in the
	modelmap. All operations are safe no-ops when that is unset (hardware whose
	LED name we don't know) or the sysfs path doesn't exist -- callers don't
	need to check availability themselves.

	Accepted dev.conf.led shapes, normalised by _resolve below:
	  "/sys/class/leds/tp-link:green:system"  full sysfs path
	  "tp-link:green:system"                  bare LED name
	  {sysfs = "tp-link:green:system", ...}   legacy modelmap table
	  nil                                     no LED (no-op)

	Anything else is treated as absent rather than raising: these functions are
	called from inform.lua's response dispatch, which is not wrapped in pcall,
	so throwing here would take down the inform daemon over a cosmetic setting.
]]--

local M = {}

local LED_ROOT = "/sys/class/leds/"

-- Injectable: file writer, for sysfs LED control.
M._write_file = function(path, contents)
	local f = io.open(path, "w")
	if not f then return false end
	f:write(contents)
	f:close()
	return true
end

-- Normalise dev.conf.led into a sysfs directory path, or nil if unusable.
local function _resolve(led)
	if type(led) == "table" then led = led.sysfs end
	if type(led) ~= "string" or led == "" then return nil end
	-- A bare LED name (no path separator) is relative to /sys/class/leds.
	if not led:find("/", 1, true) then return LED_ROOT .. led end
	return led
end

-- Start the "locate" identify blink pattern (fast timer blink).
function M.locate_start(led)
	local led_path = _resolve(led)
	if not led_path then return false end
	M._write_file(led_path .. "/trigger", "timer")
	M._write_file(led_path .. "/delay_on", "250")
	M._write_file(led_path .. "/delay_off", "250")
	return true
end

-- Stop the "locate" identify blink pattern, returning the LED trigger to none
-- (the status-LED logic, if any, is responsible for restoring its own state).
function M.locate_stop(led)
	local led_path = _resolve(led)
	if not led_path then return false end
	M._write_file(led_path .. "/trigger", "none")
	return true
end

-- Set the steady-state LED on/off, per the controller's "Manage > LED"
-- toggle (mgmt_cfg's led_enabled key). Distinct from the locate blink above
-- -- this is the device's normal/idle LED state, not a transient identify
-- pattern.
function M.set_enabled(led, enabled)
	local led_path = _resolve(led)
	if not led_path then return false end
	M._write_file(led_path .. "/trigger", "none")
	M._write_file(led_path .. "/brightness", enabled and "1" or "0")
	return true
end

return M
