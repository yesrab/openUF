--[[
	U6-InWall device identity.

	fw.ver may need adjustment to match the firmware versions accepted by your
	controller version. Identify a compatible range by checking the controller's
	device firmware list or by capturing announce packets from a real U6-InWall.
]]--

local uap = {}

uap = {
	platform		= "U6IW",
	model			= "U6IW",
	fw				= {
		pre			= "U6IW.",
		ver			= "6.6.55",			-- format M.m.p — tune for your controller
		buildtime	= "230801.1200",	-- format YYMMDD.HHMM
		factoryver	= "6.5.28"
	},
	bootver			= "",
	required_version = "6.0.0",			-- minimum controller version
	field			= {},
}

return uap
