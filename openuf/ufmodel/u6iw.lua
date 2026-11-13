--[[
	U6-InWall device identity.

	fw.ver is the version a fresh device reports: the release-channel entry of

	Ubiquiti's catalog for U6IW when this file was last refreshed:

	https://fw-update.ubnt.com/api/firmware-latest?filter=eq~~product~~unifi-firmware&filter=eq~~platform~~U6IW&filter=eq~~channel~~release

	It needs no tuning afterwards: a controller firmware update is accepted

	virtually (inform.lua) and the offered version is reported from then on.
]]--

local uap = {}

uap = {
	platform		= "U6IW",
	model			= "U6IW",
	fw				= {
		pre			= "U6IW.",
		-- Matches the real U6IW release firmware (v6.8.2+15592) as of
		-- 2026-07 -- confirmed directly against a live controller's own
		-- autoupdate-check log ("firmware[U6IW] new version (6.8.2.15592)
		-- is available") during Stage 2c validation. An older ver here
		-- makes the controller show a spurious "device has an update"
		-- offer for a fake AP with no real firmware to install.
		ver			= "8.8.14.20179",	-- bare M.m.p.build; the catalog's v8.8.14+20179 of 2026-11-12
		buildtime	= "260211.2010",	-- format YYMMDD.HHMM
		factoryver	= "6.5.28"
	},
	bootver			= "",
	required_version = "6.0.0",			-- minimum controller version
}

return uap
