-- Tests for openuf/hook/openuf-ota.sh (`openuf ota`): what it reports about
-- the installed version and a release, and what an update would install.
-- The script is run for real under sh, against a release fixture
-- (OPENUF_OTA_RELEASE_JSON, so nothing is fetched) and a made-up install
-- prefix; the package manager is a stub on PATH. Nothing is installed.
-- Run from project root: lua tests/run_tests.lua

local cjson = require("cjson")

local SCRIPT = "openuf/hook/openuf-ota.sh"
local FIX = "tests/fixtures/ota/"

local function sh(cmd)
	local p = io.popen(cmd .. " 2>&1")
	local out = p:read("*a")
	p:close()
	return out
end

local function write(path, text)
	local f = assert(io.open(path, "w"))
	f:write(text)
	f:close()
end

-- A scratch root with an install of `kind` ("apk", "opkg", "tarball" or
-- "none") at `version`, and the stub package manager that lists `pkgs`
-- ({name = version}). Returns a function that runs the script there.
local function device(kind, version, build, pkgs)
	local root = os.tmpname()
	os.remove(root)
	sh("mkdir -p " .. root .. "/bin " .. root .. "/pkg " .. root .. "/tar " .. root .. "/run")
	if kind == "apk" or kind == "opkg" then
		write(root .. "/pkg/inform.lua", "")
		if version then write(root .. "/pkg/VERSION", version .. "\n") end
		if build then write(root .. "/pkg/BUILD", build .. "\n") end
		local lines = {"#!/bin/sh"}
		if kind == "apk" then
			lines[#lines + 1] = '[ "$1" = list ] && [ "$2" = -I ] || exit 0'
			lines[#lines + 1] = 'case "$3" in'
			for name, v in pairs(pkgs or {}) do
				lines[#lines + 1] = name .. ') echo "' .. name .. "-" .. v .. ' noarch {feed} (GPL) [installed]" ;;'
			end
		else
			lines[#lines + 1] = '[ "$1" = list-installed ] || exit 0'
			lines[#lines + 1] = 'case "$2" in'
			for name, v in pairs(pkgs or {}) do
				lines[#lines + 1] = name .. ') echo "' .. name .. " - " .. v .. '" ;;'
			end
		end
		lines[#lines + 1] = "esac"
		write(root .. "/bin/" .. kind, table.concat(lines, "\n") .. "\n")
		sh("chmod +x " .. root .. "/bin/" .. kind)
	elseif kind == "tarball" then
		write(root .. "/tar/inform.lua", "")
		if build then write(root .. "/tar/BUILD", build .. "\n") end
	end
	local function run(args, release)
		-- PATH: the stub first; no real apk/opkg exists on a dev machine or CI.
		return sh("PATH=" .. root .. "/bin:$PATH OPENUF_OTA_PKG_DIR=" .. root .. "/pkg"
			.. " OPENUF_OTA_TAR_DIR=" .. root .. "/tar OPENUF_OTA_RUN=" .. root .. "/run"
			.. " OPENUF_OTA_RELEASE_JSON=" .. FIX .. (release or "release.json")
			.. " sh " .. SCRIPT .. " " .. args)
	end
	return run, root, function() sh("rm -rf " .. root) end
end

local function have_script()
	local f = io.open(SCRIPT)
	if f then f:close() end
	return f ~= nil
end

return {
	{
		name = "ota: --check on a package install names the release and the installed packages it would replace",
		fn = function()
			if not have_script() then return end
			local run, _, done = device("apk", "0.4.1", "v0.4.1 2026-11-18T17:05Z",
				{openuf = "0.4.1-r1", ["luci-app-openuf"] = "0.4.1-r1", ["luci-theme-halo"] = "1.1.0-r1"})
			local d = cjson.decode(run("--check"))
			done()
			assert_eq(d.kind, "apk", "an apk package install")
			assert_eq(d.installed, "0.4.1", "installed, from VERSION")
			assert_eq(d.latest, "0.5.0", "the release's number")
			assert_eq(d.tag, "v0.5.0", "and its tag")
			assert_true(d.newer, "0.5.0 is newer than 0.4.1")
			assert_eq(d.url, "https://github.com/yesrab/openUF/releases/tag/v0.5.0", "release notes")
			assert_eq(table.concat(d.packages, ","), "openuf,luci-app-openuf",
				"the theme is at the release's version already and is left out")
			assert_eq(d.error, cjson.null, "no error")
		end
	},
	{
		name = "ota: --check compares release numbers, not strings, and claims nothing for a version it cannot read",
		fn = function()
			if not have_script() then return end
			local run, _, done = device("opkg", "0.10.0", nil, {openuf = "0.10.0-r1"})
			local d = cjson.decode(run("--check"))
			done()
			assert_eq(d.kind, "opkg", "an opkg package install")
			assert_false(d.newer, "0.5.0 is older than 0.10.0")
			assert_eq(table.concat(d.packages, ","), "openuf", "only what is installed here")

			run, _, done = device("tarball", nil, "v0.5.0-3-gabc1234-dirty 2026-11-22T09:00Z")
			d = cjson.decode(run("--check"))
			done()
			assert_eq(d.kind, "tarball", "an install.sh install")
			assert_eq(d.installed, "0.5.0", "a build stamp past a tag reads as that release")
			assert_false(d.newer, "so 0.5.0 is not offered again")

			run, _, done = device("tarball", nil, "hotpatch abc1234 2026-11-22T09:00Z")
			d = cjson.decode(run("--check"))
			done()
			assert_eq(d.installed, cjson.null, "no release number in the stamp")
			assert_eq(d.newer, cjson.null, "so newer is unknown, not guessed")
			assert_eq(d.latest, "0.5.0", "the release is still named")
		end
	},
	{
		name = "ota: --check reports no install, a refused release list and a release with no package for this device",
		fn = function()
			if not have_script() then return end
			local run, _, done = device("none")
			local d = cjson.decode(run("--check"))
			done()
			assert_eq(d.kind, "none", "nothing installed")
			assert_eq(d.error, "openUF is not installed", "said so")

			run, _, done = device("apk", "0.4.1", nil, {openuf = "0.4.1-r1"})
			d = cjson.decode(run("--check", "ratelimit.json"))
			done()
			assert_eq(d.latest, cjson.null, "no release read")
			assert_true(d.error:find("no release found", 1, true) ~= nil, "GitHub's refusal is reported")
			assert_nil(d.error:find("`", 1, true), "with its text reduced to plain characters")

			-- VERSION says a package, the database has none: nothing to upgrade as a package.
			run, _, done = device("apk", "0.4.1", nil, {})
			d = cjson.decode(run("--check"))
			done()
			assert_true(d.error:find("package database", 1, true) ~= nil, "no openuf package to replace")
		end
	},
	{
		-- Everything in the release came off the network and ends up on a
		-- command line: only this repository's own download URLs and plain
		-- file names get through.
		name = "ota: the plan holds only this repository's files, each with its checksum",
		fn = function()
			if not have_script() then return end
			-- --plan-of is the way back's plan, so it lists every installed
			-- package the release has, the theme at an unchanged version too.
			local run, root, done = device("apk", "0.4.1", nil,
				{openuf = "0.4.1-r1", ["luci-app-openuf"] = "0.4.1-r1", ["luci-theme-halo"] = "1.1.0-r1"})
			run("--plan-of " .. FIX .. "release.json " .. root .. "/plan")
			local f = io.open(root .. "/plan")
			local plan = f and f:read("*a") or ""
			if f then f:close() end
			done()
			local base = "https://github.com/yesrab/openUF/releases/download/v0.5.0/"
			local sha = string.rep("ab", 32)
			-- The fifth field is the API's address of the same file, the one
			-- uclient-fetch can actually download from; one that is not under
			-- this repository's API is replaced by "-", the file itself kept.
			assert_eq(plan, "openuf openuf-0.5.0-r1.apk " .. base .. "openuf-0.5.0-r1.apk " .. sha
					.. " https://api.github.com/repos/yesrab/openUF/releases/assets/7000\n"
				.. "luci-app-openuf luci-app-openuf-0.5.0-r1.apk " .. base .. "luci-app-openuf-0.5.0-r1.apk " .. sha .. " -\n"
				.. "luci-theme-halo luci-theme-halo-1.1.0-r1.apk " .. base .. "luci-theme-halo-1.1.0-r1.apk " .. sha
					.. " https://api.github.com/repos/yesrab/openUF/releases/assets/7004\n",
				"three packages, the release's own URLs, sha256 each; not openuf-crypto, not another host's 9.9.9")
		end
	},
	{
		name = "ota: --status is idle before any update and calls a vanished updater failed",
		fn = function()
			if not have_script() then return end
			local run, root, done = device("apk", "0.4.1", nil, {openuf = "0.4.1-r1"})
			local d = cjson.decode(run("--status"))
			assert_eq(d.state, "idle", "nothing has run")
			write(root .. "/run/openuf-ota.status",
				"state=running\nstep=install\nmessage=installing v0.5.0\nfrom=0.4.1\nto=0.5.0\npid=999999\nat=1\n")
			write(root .. "/run/openuf-ota.log", 'line "one"\nline\ttwo\n')
			d = cjson.decode(run("--status"))
			done()
			assert_eq(d.state, "failed", "running, but its process is gone")
			assert_true(d.message:find("install", 1, true) ~= nil, "says during which step")
			assert_eq(d.from, "0.4.1", "from")
			assert_eq(d.to, "0.5.0", "to")
			assert_eq(d.log, 'line "one"\nline\ttwo', "the log survives as JSON, quotes, tabs and lines")
		end
	},
	{
		name = "ota: an unknown option and a tag that is not one are refused",
		fn = function()
			if not have_script() then return end
			local run, _, done = device("apk", "0.4.1", nil, {openuf = "0.4.1-r1"})
			local bad = run("--frobnicate")
			local tag = run("--install --tag 'v1;reboot'")
			done()
			assert_true(bad:find("unknown option", 1, true) ~= nil, "unknown option")
			assert_true(tag:find("not a release tag", 1, true) ~= nil, "a tag is letters, digits, dot, dash, underscore")
		end
	},
}
