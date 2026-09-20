-- Structural tests for every file in openuf/ufmodel/, plus the facts one
-- identity pins. Run from project root: lua tests/run_tests.lua
--
-- announce.lua and inform.lua dofile the selected identity at startup and
-- read a fixed set of fields from it. A missing one is a nil reaching
-- ufpkt.catstr (announce dies on its first packet) or a payload field the
-- controller rejects -- and nothing loaded these files under the suite before
-- a second dual-band identity existed, so a typo shipped silently.

local lfs_ls = function(dir)
	local names = {}
	local h = io.popen("ls " .. dir .. " 2>/dev/null")
	if not h then return names end
	for line in h:lines() do
		if line:match("%.lua$") then names[#names + 1] = line end
	end
	h:close()
	return names
end

local UFMODEL_DIR = "openuf/ufmodel"

local function each_ufmodel(fn)
	local files = lfs_ls(UFMODEL_DIR)
	assert_true(#files > 0, "ufmodel directory is not empty (found " .. #files .. ")")
	for _, name in ipairs(files) do
		local path = UFMODEL_DIR .. "/" .. name
		local ok, uap = pcall(dofile, path)
		assert_true(ok, path .. " loads: " .. tostring(uap))
		assert_true(type(uap) == "table", path .. " returns a table")
		fn(name, uap)
	end
end

return {
	{
		name = "ufmodel: every identity loads and carries what announce and inform read",
		fn = function()
			each_ufmodel(function(name, uap)
				-- announce.lua: platform TLVs 0x0c/0x15, and the four fw.*
				-- strings concatenated into the firmware TLVs.
				assert_true(type(uap.platform) == "string" and uap.platform ~= "",
					name .. ": platform is a non-empty string")
				assert_true(type(uap.fw) == "table", name .. ": has a fw table")
				for _, k in ipairs({"pre", "ver", "buildtime", "factoryver"}) do
					assert_true(type(uap.fw[k]) == "string" and uap.fw[k] ~= "",
						name .. ": fw." .. k .. " is a non-empty string (announce catstr's it)")
				end
				-- inform.lua: model / bootrom_version / required_version. The
				-- older identities predate `model` and `required_version`;
				-- build_json defaults them, so they are optional -- but a
				-- present one has to be a string, not a number someone
				-- typed without quotes.
				if uap.model ~= nil then
					assert_true(type(uap.model) == "string" and uap.model ~= "",
						name .. ": model is a non-empty string when set")
				end
				assert_true(type(uap.bootver) == "string",
					name .. ": bootver is a string (sent as bootrom_version)")
				if uap.required_version ~= nil then
					assert_true(type(uap.required_version) == "string",
						name .. ": required_version is a string when set")
				end
			end)
		end
	},
	{
		name = "ufmodel: uhdiw is the UAP-IW-HD with the catalog's bare firmware version",
		fn = function()
			-- The WiFi 5 in-wall identity. Its model code and firmware version
			-- are read from Ubiquiti's own firmware catalog (URL in the file
			-- header), not guessed, and the version has to stay in the shape
			-- the controller compares against.
			local uap = dofile(UFMODEL_DIR .. "/uhdiw.lua")
			assert_eq(uap.model, "UHDIW", "model is Ubiquiti's code for the UAP-IW-HD")
			assert_eq(uap.platform, "UHDIW", "platform matches model, as u6iw's does")

			-- inform's `version` is compared to the catalog's own entry with a
			-- strict, unnormalized string equality (PROTOCOL-VALIDATION.md,
			-- "Why version must be bare"). A model prefix or a '+' before
			-- the build number never matches, and the device shows a
			-- permanent "Update Available".
			assert_true(uap.fw.ver:match("^%d+%.%d+%.%d+%.%d+$") ~= nil,
				"fw.ver is bare M.m.p.build, got " .. tostring(uap.fw.ver))

			-- The discovery TLV prefix follows the model code, the convention
			-- u6iw set; announce.lua concatenates pre .. ver .. suffix .. "."
			-- .. buildtime, so buildtime has to be the YYMMDD.HHMM it expects.
			assert_eq(uap.fw.pre, "UHDIW.", "discovery prefix is the model code plus a dot")
			assert_true(uap.fw.buildtime:match("^%d%d%d%d%d%d%.%d%d%d%d$") ~= nil,
				"fw.buildtime is YYMMDD.HHMM, got " .. tostring(uap.fw.buildtime))
		end
	},
	{
		name = "ufmodel: uhdiw has every field the validated u6iw identity has",
		fn = function()
			-- u6iw is the identity validated end-to-end and the one
			-- build_json / announce were written against. A second dual-band
			-- identity must be a superset of its keys so that every read
			-- those two files make finds a value, rather than a default that
			-- happens to say "U6IW".
			local ref = dofile(UFMODEL_DIR .. "/u6iw.lua")
			local uap = dofile(UFMODEL_DIR .. "/uhdiw.lua")
			for k, v in pairs(ref) do
				assert_not_nil(uap[k], "uhdiw carries u6iw's field " .. k)
				assert_eq(type(uap[k]), type(v), "uhdiw." .. k .. " has u6iw's type")
			end
			for k in pairs(ref.fw) do
				assert_not_nil(uap.fw[k], "uhdiw.fw carries u6iw's field " .. k)
			end
		end
	},
	{
		name = "ufmodel: uhdiw builds a discovery packet that names the model and firmware",
		fn = function()
			-- announce.lua catstr's five of the identity's strings into TLVs
			-- with no nil check; a field the file forgot is a crash on the
			-- first broadcast, i.e. a device that never appears in UniFi
			-- Discover. Map the shipped file exactly as announce.lua's own
			-- startup does and build one packet.
			OPENUF_TEST_MODE = true
			if not ufpkt then dofile("openuf/lib/lib.lua") end
			local announce = dofile("openuf/announce.lua")
			local uap = dofile(UFMODEL_DIR .. "/uhdiw.lua")
			local pkt = announce.build_packet({
				mac           = {0x24, 0xa4, 0x3c, 0x00, 0xd3, 0xad},
				ip            = {192, 168, 1, 1},
				hostname      = "openUF",
				adopted       = false,
				platform      = uap.platform,
				fw_pre        = uap.fw.pre,
				fw_ver        = uap.fw.ver,
				fw_buildtime  = uap.fw.buildtime,
				fw_factoryver = uap.fw.factoryver,
				uptime        = 100,
				counter       = 1,
			})
			assert_true(type(pkt) == "string" and #pkt > 4, "a packet was built")
			-- Platform TLVs (0x0c / 0x15) carry the bare code; the verbose
			-- firmware TLV (0x03) is pre .. ver .. suffix .. "." .. buildtime,
			-- so both the prefixed version and the build stamp appear.
			assert_true(pkt:find("UHDIW", 1, true) ~= nil, "platform code is in the packet")
			assert_true(pkt:find(uap.fw.pre .. uap.fw.ver, 1, true) ~= nil,
				"verbose firmware string starts with pre .. ver")
			assert_true(pkt:find(uap.fw.buildtime, 1, true) ~= nil, "build stamp is in the packet")
			assert_true(pkt:find(uap.fw.factoryver, 1, true) ~= nil,
				"factory firmware TLV (0x1b) carries factoryver")
		end
	},
}
