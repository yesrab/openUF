-- Tests for openuf/plugins.lua: upstream's api-1 contract (jonasevcik/openUF
-- feature/plugin-hooks, 26ad689; their seven tests, kept) and this tree's
-- additions: built-in plugins with their own switch, the optional hooks, the
-- declarations, the fingerprint, and inform's store and rate-limited re-push.
-- Run from project root: lua tests/run_tests.lua

local plugins   = dofile("openuf/plugins.lua")
local ucihelper = dofile("openuf/ucihelper.lua")
local util      = dofile("openuf/util.lua")

local DELETE = setmetatable({}, {__tostring = function() return "<delete>" end})
local ENV = {DELETE = DELETE, bssid = function() return "00:00:5e:00:53:2b" end,
	cursor = function() return {} end}

-- Run fn with plugins' seams stubbed: `files` maps a third-party plugin name
-- -> Lua source; built-in plugins still come off the tree, so they load (and
-- stay off unless the cfg switches them on). Log lines are collected, and
-- the load cache starts and ends empty.
local function with_plugins(files, fn)
	local orig_read, orig_log = plugins._read_file, plugins._log
	local logged = {}
	plugins._read_file = function(path)
		local name = path:match("^" .. plugins.DIR:gsub("%p", "%%%0") .. "/(.+)%.lua$")
		if name then return files[name] end
		return util.read_file(path)
	end
	plugins._log = function(msg) logged[#logged + 1] = msg end
	plugins._reset()
	local ok, err = pcall(fn, logged)
	plugins._read_file, plugins._log = orig_read, orig_log
	plugins._reset()
	if not ok then error(err, 0) end
end

local function has_log(logged, text)
	for _, l in ipairs(logged) do
		if l:find(text, 1, true) then return true end
	end
	return false
end

local function cfg_of(...) return {config = {plugins = {...}}} end

local function plugin_src(body)
	return "return {name = 'p', api = 1, vap_options = function(extra, vap, ctx)\n"
		.. body .. "\nend}"
end

local VAP = {ssid = "corp", radio = "radio0", x_passphrase = "hunter22",
	iapp_key = "00112233445566778899aabbccddeeff"}

-- A minimal in-memory cursor (set/get/delete/foreach/commit), strict about
-- section names like the real libuci is silent.
local function mock_cursor()
	local db, order = {}, {}
	local c = {}
	function c:set(config, section, a, b)
		assert(tostring(section):match("^[%w_]+$"), "invalid section " .. tostring(section))
		db[config] = db[config] or {}
		if not db[config][section] then
			db[config][section] = {[".name"] = section}
			order[config] = order[config] or {}
			order[config][#order[config] + 1] = section
		end
		if b == nil then db[config][section][".type"] = a
		elseif type(b) == "table" then
			local l = {}
			for i, v in ipairs(b) do l[i] = tostring(v) end
			db[config][section][a] = l
		else db[config][section][a] = b end
	end
	function c:foreach(config, stype, fn)
		for _, n in ipairs(order[config] or {}) do
			local s = db[config][n]
			if s and s[".type"] == stype then fn(s) end
		end
	end
	function c:delete(config, section, option)
		if option ~= nil then
			if db[config] and db[config][section] then db[config][section][option] = nil end
			return
		end
		if db[config] then db[config][section] = nil end
		for i, n in ipairs(order[config] or {}) do
			if n == section then table.remove(order[config], i); break end
		end
	end
	function c:get(config, section, option)
		local s = db[config] and db[config][section]
		local v = s and s[option]
		if v == nil then return nil, "Entry not found" end
		return v
	end
	function c:commit() end
	return c, db
end

-- apply_config with the plugins module in place and every other seam quiet.
local function run_apply(cfg, opts)
	local c, db = mock_cursor()
	local orig = {ucihelper._uci, ucihelper._popen, ucihelper._read_file,
		ucihelper._run_cmd, ucihelper._plugins, ucihelper._bcfilter, ucihelper._shaper}
	ucihelper.end_pass()
	ucihelper._uci = {cursor = function() return c end}
	ucihelper._popen = function() return "" end
	ucihelper._read_file = function() return nil end
	ucihelper._run_cmd = function() return true end
	ucihelper._plugins = plugins
	-- The real bcfilter and shaper would rebuild nft/tc state: never from a test.
	ucihelper._bcfilter = {reconcile = function() end}
	ucihelper._shaper = {reconcile = function() end}
	c:set("wireless", "radio0", "wifi-device")
	local real = io.stderr
	io.stderr = {write = function() end}
	local ok, err = pcall(ucihelper.apply_config, {radio_table = {{name = "radio0", channel = 6}}, vap_table = {
		{ssid = "corp", radio = "radio0", security = "wpa2",
		 x_passphrase = "hunter22", fast_roaming_enabled = true,
		 iapp_key = VAP.iapp_key},
	}}, cfg, opts)
	io.stderr = real
	ucihelper._uci, ucihelper._popen, ucihelper._read_file,
		ucihelper._run_cmd, ucihelper._plugins, ucihelper._bcfilter, ucihelper._shaper =
		orig[1], orig[2], orig[3], orig[4], orig[5], orig[6], orig[7]
	ucihelper.end_pass()
	if not ok then error(err, 0) end
	return db.wireless.openuf_radio0_corp, db
end

return {
	{
		name = "plugins: nothing is loaded unless conf.lua names it",
		fn = function()
			with_plugins({p = plugin_src("extra.touched = '1'")}, function(logged)
				local extra = {a = "1"}
				plugins.vap_options(extra, VAP, nil, ENV)
				plugins.vap_options(extra, VAP, {config = {}}, ENV)
				plugins.vap_options(extra, VAP, cfg_of(), ENV)
				assert_nil(extra.touched, "a file in the directory is not enough")
				assert_eq(#logged, 0, "and nothing is logged")
			end)
		end
	},
	{
		name = "plugins: a listed plugin edits extra, sees the vap and ctx, never the passphrase",
		fn = function()
			local src = plugin_src([[
				extra.mobility_domain = 'abcd'
				extra.r0kh = {'ff:ff:ff:ff:ff:ff,*,' .. vap.iapp_key}
				extra.reassociation_deadline = ctx.DELETE
				extra.nasid = (ctx.bssid(vap.radio, vap.ssid):gsub(':', ''))
				extra.leak = tostring(vap.x_passphrase)
				ctx.log('hello')]])
			with_plugins({p = src}, function(logged)
				local extra = {mobility_domain = "ffff", reassociation_deadline = "3000"}
				plugins.vap_options(extra, VAP, cfg_of("p"), ENV)
				assert_eq(extra.mobility_domain, "abcd", "may override a built-in option")
				assert_eq(extra.r0kh[1], "ff:ff:ff:ff:ff:ff,*," .. VAP.iapp_key, "list option")
				assert_true(extra.reassociation_deadline == DELETE, "the DELETE sentinel survives")
				assert_eq(extra.nasid, "00005e00532b", "ctx.bssid")
				assert_eq(extra.leak, "nil", "the passphrase is not handed over")
				assert_true(has_log(logged, "p: hello"), "ctx.log carries the plugin name")
				assert_eq(VAP.x_passphrase, "hunter22", "and the caller's vap is untouched")
				local e2 = {vendor_elements = DELETE}
				plugins.vap_options(e2, VAP, cfg_of("p"), ENV)
				assert_true(e2.vendor_elements == DELETE, "a built-in DELETE keeps its identity")
			end)
		end
	},
	{
		name = "plugins: a plugin that is missing, broken, or on another api is skipped, the rest still run",
		fn = function()
			with_plugins({
				bad_syntax = "return {",
				wrong_api  = "return {api = 99, vap_options = function() end}",
				no_hook    = "return {api = 1}",
				not_table  = "return 5",
				good       = plugin_src("extra.ok = '1'"),
			}, function(logged)
				local extra = {}
				plugins.vap_options(extra, VAP,
					cfg_of("missing", "bad_syntax", "wrong_api", "no_hook", "not_table",
						"../etc/passwd", "good"), ENV)
				assert_eq(extra.ok, "1", "the good plugin ran")
				assert_true(has_log(logged, "missing: not loaded"), "missing")
				assert_true(has_log(logged, "bad_syntax: not loaded"), "syntax error")
				assert_true(has_log(logged, "api 99"), "api mismatch names both versions")
				assert_true(has_log(logged, "no vap_options"), "no hook")
				assert_true(has_log(logged, "did not return a table"), "wrong type")
				assert_true(has_log(logged, "invalid plugin name"), "no path traversal")
			end)
		end
	},
	{
		name = "plugins: a hook that raises changes nothing and the push goes on",
		fn = function()
			with_plugins({
				boom = plugin_src("extra.half = '1'; error('kaboom')"),
				good = plugin_src("extra.ok = '1'"),
			}, function(logged)
				local extra = {keep = "1"}
				plugins.vap_options(extra, VAP, cfg_of("boom", "good"), ENV)
				assert_nil(extra.half, "the partial edit is discarded")
				assert_eq(extra.keep, "1", "existing options stay")
				assert_eq(extra.ok, "1", "the next plugin still runs")
				assert_true(has_log(logged, "kaboom"), "the error is logged")
				assert_true(has_log(logged, "corp"), "with the WLAN it concerned")
			end)
		end
	},
	{
		name = "plugins: an invalid edit is refused whole (names, reserved options, value types)",
		fn = function()
			local cases = {
				{"extra['bad-name'] = '1'", "bad-name"},
				{"extra['a b'] = '1'", "a b"},
				{"extra.ssid = 'evil'", "reserved"},
				{"extra.key = 'evil'", "reserved"},
				{"extra.network = 'wan'", "reserved"},
				{"extra.openuf_ratelimit_down = '1'", "reserved"},
				{"extra.fn = function() end", "function"},
				{"extra.lst = {{}}", "list element"},
			}
			for _, c in ipairs(cases) do
				with_plugins({p = plugin_src("extra.fine = '1'; " .. c[1])}, function(logged)
					local extra = {ssid_stays = "1"}
					plugins.vap_options(extra, VAP, cfg_of("p"), ENV)
					assert_nil(extra.fine, c[2] .. ": the valid part is not applied either")
					assert_true(has_log(logged, c[2]), c[2] .. ": says why")
				end)
			end
			with_plugins({p = plugin_src("extra.fine = '1'")}, function()
				local extra = {openuf_bcfilt = "1", ssid = "x", lst = {"a", "b"}}
				plugins.vap_options(extra, VAP, cfg_of("p"), ENV)
				assert_eq(extra.fine, "1", "untouched reserved and list options do not trip the check")
			end)
		end
	},
	{
		name = "plugins: a name listed twice runs once; a non-list config is ignored with a log line",
		fn = function()
			with_plugins({p = plugin_src("extra.n = tostring(tonumber(extra.n or 0) + 1)")},
				function(logged)
					local extra = {}
					plugins.vap_options(extra, VAP, cfg_of("p", "p"), ENV)
					assert_eq(extra.n, "1", "ran once")
					plugins.vap_options(extra, VAP, {config = {plugins = "p"}}, ENV)
					assert_true(has_log(logged, "must be a list"), "string config refused")
				end)
		end
	},
	{
		name = "plugins: apply_config writes a plugin's options, and nothing changes with plugins off",
		fn = function()
			local base = run_apply(nil)
			local off  = run_apply({config = {plugins = {}}})
			for k, v in pairs(base) do
				if type(v) == "table" then
					assert_eq(table.concat(off[k], ","), table.concat(v, ","), "plugins={}: " .. k)
				else
					assert_eq(off[k], v, "plugins={}: " .. k)
				end
			end
			for k in pairs(off) do assert_true(base[k] ~= nil, "plugins={}: no extra option " .. k) end

			with_plugins({p = plugin_src([[
				extra.mobility_domain = 'abcd'
				extra.ft_psk_generate_local = '0'
				extra.hostapd_bss_options = {'ft_iface=vft0'}
				extra.reassociation_deadline = ctx.DELETE]])}, function()
				local s = run_apply({config = {plugins = {"p"}}})
				assert_eq(s.mobility_domain, "abcd", "overrides openUF's value")
				assert_eq(s.ft_psk_generate_local, "0", "adds an option")
				assert_eq(s.hostapd_bss_options[1], "ft_iface=vft0", "list option reaches UCI")
				assert_nil(s.reassociation_deadline, "DELETE removes openUF's 3000")
				assert_eq(s.ssid, "corp", "identity untouched")
				local gone = run_apply({config = {plugins = {}}})
				assert_nil(gone.ft_psk_generate_local, "unlisted -> its option is gone")
				assert_eq(gone.mobility_domain, base.mobility_domain, "and openUF's value is back")
			end)
		end
	},
	-- ── this tree's additions ──────────────────────────────────────────────
	{
		name = "plugins: a built-in loads from the tree only while its own switch is on",
		fn = function()
			with_plugins({}, function(logged)
				local off = plugins.enabled({config = {}})
				assert_eq(#off, 0, "rrb off: nothing enabled")
				local rows = plugins.list({config = {}})
				assert_eq(rows[1].name, "rrb", "listed all the same")
				assert_true(rows[1].builtin, "as a built-in")
				assert_false(rows[1].loaded, "not loaded")
				assert_eq(rows[1].reason, "off", "because its switch is off")
				local on = plugins.enabled({config = {unifi_ft_interop = true}})
				assert_eq(#on, 1, "rrb on")
				assert_eq(on[1].name, "rrb", "the translator plugin")
				assert_true(on[1].builtin, "built in")
				assert_eq(type(on[1].mod.before_push), "function", "with its hooks")
				assert_eq(#logged, 0, "nothing to complain about")
				-- a built-in and a third-party plugin together, built-in first
				with_plugins({p = plugin_src("extra.p = '1'")}, function()
					local both = plugins.enabled({config = {unifi_ft_interop = true, plugins = {"p"}}})
					assert_eq(#both, 2, "both")
					assert_eq(both[1].name, "rrb", "built-ins first")
					assert_eq(both[2].name, "p", "then the list")
				end)
			end)
		end
	},
	{
		name = "plugins: optional hooks run through run_hook, a raise is logged, results come back by name",
		fn = function()
			with_plugins({
				a = "return {name = 'a', api = 1, tick = function(ctx) return 'ticked' end, "
					.. "before_push = function(ctx, push) return #push.vaps end, "
					.. "services = {'svc-a'}, packages = {{pkg = 'foo', evidence = 'cmd:foo', unlocks = 'x'}}}",
				b = "return {name = 'b', api = 1, tick = function() error('tock') end, "
					.. "on_forget = function(ctx) return 'gone' end}",
				c = "return {name = 'c', api = 1, vap_options = function() end}",
			}, function(logged)
				local cfg = cfg_of("a", "b", "c")
				local r = plugins.run_hook("tick", cfg, ENV)
				assert_eq(r.a, "ticked", "a's result by name")
				assert_nil(r.b, "b raised: no result")
				assert_nil(r.c, "c has no tick")
				assert_true(has_log(logged, "b: tick raised: ") and has_log(logged, "tock"), "the raise is logged with the plugin's name")
				local bp = plugins.run_hook("before_push", cfg, ENV, {vaps = {{}, {}}})
				assert_eq(bp.a, 2, "extra arguments reach the hook")
				assert_eq(plugins.run_hook("on_forget", cfg, ENV).b, "gone", "on_forget")
				local pk = plugins.declared(cfg, "packages")
				assert_eq(#pk, 1, "a declares one package")
				assert_eq(pk[1].pkg, "foo", "the package")
				assert_eq(pk[1].plugin, "a", "tagged with its plugin")
				local sv = plugins.declared(cfg, "services")
				assert_eq(sv[1].name, "svc-a", "a string entry becomes {name=}")
				-- a plugin with hooks but no vap_options loads (upstream requires
				-- vap_options; here any hook will do)
				assert_eq(#plugins.enabled(cfg_of("a")), 1, "hook-only plugin loads")
				local st = plugins.status(cfg, ENV)
				assert_eq(st[2].name, "a", "status lists it (after the built-in row)")
				assert_true(st[2].loaded, "loaded")
				assert_eq(st[2].hooks[1], "before_push", "hooks named in HOOKS order")
				assert_eq(st[2].services[1], "svc-a", "declarations echoed")
			end)
		end
	},
	{
		name = "plugins: the ctx carries util, exists, store and repush from the env",
		fn = function()
			with_plugins({
				p = "return {name = 'p', api = 1, tick = function(ctx) return {"
					.. "bit = type(ctx.util.bit) == 'function', mac = ctx.util.is_mac('00:00:5e:00:53:01'), "
					.. "sha = ctx.util.sha1('abc'), store = ctx.store, pushed = ctx.repush(), "
					.. "ex = ctx.exists('/such/file'), name = ctx.name} end}",
			}, function()
				local stores, pushes = {}, {}
				local env = {
					store = function(name) stores[name] = stores[name] or {n = 0}; return stores[name] end,
					repush = function(name) pushes[#pushes + 1] = name; return true end,
					exists = function(path) return path == "/such/file" end,
				}
				local r = plugins.run_hook("tick", cfg_of("p"), env).p
				assert_true(r.bit and r.mac, "util subset")
				assert_eq(r.sha, "a9993e364706816aba3e25717850c26c9cd0d89d", "sha1 through util")
				assert_true(r.store == stores.p, "the plugin's own store table")
				assert_true(r.pushed, "repush answers")
				assert_eq(pushes[1], "p", "and is asked in the plugin's name")
				assert_true(r.ex, "exists comes from the env")
				assert_eq(r.name, "p", "ctx.name")
			end)
		end
	},
	{
		name = "plugins: radio_options edits a wifi-device but never what the controller drives",
		fn = function()
			with_plugins({
				ok = "return {name = 'ok', api = 1, radio_options = function(extra, radio, ctx) extra.beacon_int = '200'; extra.seen = radio.name end}",
				bad = "return {name = 'bad', api = 1, radio_options = function(extra, radio, ctx) extra.fine = '1'; extra.channel = '1' end}",
			}, function(logged)
				local extra = plugins.radio_options({}, {name = "radio0", channel = 6}, cfg_of("ok", "bad"), ENV)
				assert_eq(extra.beacon_int, "200", "a plugin's radio option")
				assert_eq(extra.seen, "radio0", "sees the radio row")
				assert_nil(extra.fine, "bad's edit refused whole")
				assert_true(has_log(logged, "'channel' is reserved"), "channel is the controller's")
				-- through apply_config: written on the wifi-device section
				local _, db = run_apply(cfg_of("ok"))
				assert_eq(db.wireless.radio0.beacon_int, "200", "reaches the radio section")
			end)
		end
	},
	{
		name = "plugins: the fingerprint follows the set of plugins that would run",
		fn = function()
			with_plugins({p = plugin_src("extra.x = '1'"), q = "return {name = 'q', api = 1, tick = function() end}"}, function()
				local none = plugins.fingerprint({config = {}})
				local p = plugins.fingerprint(cfg_of("p"))
				local pq = plugins.fingerprint(cfg_of("p", "q"))
				local rrb = plugins.fingerprint({config = {unifi_ft_interop = true}})
				assert_eq(none, "", "nothing enabled")
				assert_neq(p, pq, "one more plugin")
				assert_eq(p, plugins.fingerprint(cfg_of("p")), "stable")
				assert_true(rrb:find("rrb:1:", 1, true) ~= nil, "a built-in counts too")
				assert_true(pq:find("q:1:tick", 1, true) ~= nil, "names, api and hooks")
			end)
		end
	},
	{
		name = "plugins: inform's re-push is rate-limited and adopted-only, and a changed set triggers it",
		fn = function()
			dofile("openuf/lib/lib.lua")
			local inform = dofile("openuf/inform.lua")
			local pl = inform._plugins
			assert_not_nil(pl, "inform loads plugins.lua")
			local saved = 0
			local orig_state, orig_time, orig_read, orig_log = inform._state, inform._time, pl._read_file, pl._log
			inform._state = {save = function() saved = saved + 1 end}
			local now = 1000
			inform._time = function() return now end
			local files = {}
			pl._read_file = function(path)
				local name = path:match("^" .. pl.DIR:gsub("%p", "%%%0") .. "/(.+)%.lua$")
				if name then return files[name] end
				return util.read_file(path)
			end
			pl._log = function() end
			pl._reset()
			inform._plugin_next_repush = 0
			local ok, err = pcall(function()
				-- the re-push
				local st = {adopted = true, cfgversion = "abc"}
				local repush = inform._plugin_repush(st)
				assert_true(repush("x"), "first ask: done")
				assert_eq(st.cfgversion, "", "cfgversion forgotten")
				assert_eq(saved, 1, "saved")
				st.cfgversion = "def"
				assert_false(repush("x"), "inside the gap: refused")
				assert_eq(st.cfgversion, "def", "untouched")
				now = 1000 + inform.PLUGIN_REPUSH_GAP
				assert_true(repush("y"), "after the gap: done")
				assert_false(inform._plugin_repush({adopted = false})("x"), "unadopted: never")
				-- the store
				local store = inform._plugin_store(st)
				store("p").n = 5
				assert_eq(st.plugins.p.n, 5, "lives in state.json's plugins table")
				assert_true(store("p") == st.plugins.p, "the same table each time")
				-- the tick: a changed set of plugins asks for a re-push
				now = now + inform.PLUGIN_REPUSH_GAP
				local cfg = {config = {}}
				st.cfgversion = "ghi"
				inform._plugins_tick(st, cfg)
				assert_eq(st.plugins_fp, "", "fingerprint remembered (nothing enabled)")
				assert_eq(st.cfgversion, "ghi", "the first fingerprint is not a change")
				files.p = "return {name = 'p', api = 1, tick = function(ctx) ctx.store.ticks = (ctx.store.ticks or 0) + 1 end}"
				cfg = {config = {plugins = {"p"}}}
				pl._reset()
				local r = inform._plugins_tick(st, cfg)
				assert_true(st.plugins_fp:find("p:1:tick", 1, true) ~= nil, "new fingerprint")
				assert_eq(st.cfgversion, "", "a changed set: the controller is asked again")
				assert_eq(st.plugins.p.ticks, 1, "and the plugin's tick ran with its store")
				assert_true(r.p == true, "a nil-returning hook reports true")
			end)
			inform._state, inform._time, pl._read_file, pl._log = orig_state, orig_time, orig_read, orig_log
			pl._reset()
			if not ok then error(err, 0) end
		end
	},
}
