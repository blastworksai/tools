--!nonstrict
-- Deterministic tests of the real status_prompt.luau with a fake `tern` (shared kv, manual clock and timers),
-- fake window contexts and a fake picker. Chunk contract: `loadstring(source)(plugin_dir)` returns "PASS n checks".
-- Every "window" and the "host" loads its own copy of the module, as separate VMs do, over one shared kv.
local root = ...
local source = tern.fs.read(root .. "/status_prompt.luau")
local checks = 0
local function check(value, label)
	assert(value, label)
	checks += 1
end

local function world(preset)
	local w = { kv = {}, now = 0, seconds = 1000, timers = {}, picks = {}, refreshes = 0, flag_reads_stale = {}, request_reads_nil = {} }
	for key, value in preset or {} do w.kv[key] = value end
	w.timer_count = 0
	function w.native_for(name)
		return {
			now = function() return w.now end,
			timer = function(ms, fn)
				w.timer_count += 1
				table.insert(w.timers, { at = w.now + ms, fn = fn, vm = name })
			end,
			kv = {
				get = function(key)
					if key == "status_prompt.v1.request" and w.request_reads_nil[name] then return nil end
					return w.kv[key]
				end,
				set = function(key, value) w.kv[key] = value end,
			},
			chrome = { refresh = function() w.refreshes += 1 end },
		}
	end
	function w.load(name)
		local environment = { tern = w.native_for(name), os = { time = function() return w.seconds end }, math = math, tostring = tostring, type = type }
		local chunk = assert(loadstring(source, "status_prompt"))
		setfenv(chunk, setmetatable(environment, { __index = getfenv() }))
		return chunk()
	end
	-- Runs due timers in time order; a window timer receives a fresh cx like the native one does.
	function w.run(ms)
		local stop = w.now + ms
		while true do
			local best
			for index, timer in w.timers do
				if timer.at <= stop and (best == nil or timer.at < w.timers[best].at) then best = index end
			end
			if best == nil then break end
			local timer = table.remove(w.timers, best)
			w.now = math.max(w.now, timer.at)
			w.seconds = 1000 + w.now // 1000
			timer.fn(if timer.vm == "host" then nil else w.cxs[timer.vm])
		end
		w.now = stop
	end
	w.cxs = {}
	function w.window(name, bar_on)
		local settings_values = { status_bar = bar_on }
		local cx
		cx = {
			settings = {
				get = function(_self, key) return settings_values[key] end,
				set = function(_self, key, value) settings_values[key] = value; return value end,
			},
			window_key = function() return name end,
			pick = function(_self, opts)
				local record = { opts = opts, window = name }
				table.insert(w.picks, record)
				record.awaitable = { next = function(_a, fn) record.callback = fn end }
				return record.awaitable
			end,
		}
		cx.values = settings_values
		w.cxs[name] = cx
		return cx
	end
	return w
end

local function serve_host(w)
	local host = w.load("host")
	host.host_serve()
	return host
end

-- 1. Fresh install, bar off: exactly one prompt, Yes recommended and listed first.
do
	local w = world()
	serve_host(w)
	local cx = w.window("w1", false)
	w.load("w1").ensure(cx, "spawn")
	w.run(2000)
	check(#w.picks == 1, "fresh install asks exactly once")
	check(w.picks[1].opts.placeholder == "Would you like to turn on the status bar?", "the question is the specified one")
	check(w.picks[1].opts.items[1].answer == true and w.picks[1].opts.items[1].label:find("^Yes") ~= nil, "Yes is first (recommended)")
	check(w.picks[1].opts.items[2].answer == false, "No is second")
	check(w.kv["status_prompt.v1"] ~= nil, "the flag is claimed before the answer")
	check(cx.values.status_bar == false and w.refreshes == 0, "asking changes nothing by itself")
	-- 4. Yes: sets the setting through the FRESH cx and refreshes once, from the callback.
	local fresh = w.window("w1-fresh", false)
	w.picks[1].callback(w.picks[1].opts.items[1], nil, fresh)
	check(fresh.values.status_bar == true, "Yes sets status_bar true on the fresh cx")
	check(cx.values.status_bar == false, "the stale cx is left alone")
	check(w.refreshes == 1, "Yes refreshes the chrome exactly once")
	-- 12. A second window of the same install after the claim never asks, though its bar is off.
	local second = w.window("w2", false)
	w.load("w2").ensure(second, "spawn")
	w.run(2000)
	check(#w.picks == 1, "a later window of a claimed install does not ask")
end

-- 2. Bar already on: no prompt, flag still set.
do
	local w = world()
	serve_host(w)
	w.load("w1").ensure(w.window("w1", true), "spawn")
	w.run(2000)
	check(#w.picks == 0, "bar on asks nothing")
	check(w.kv["status_prompt.v1"] ~= nil, "bar on still sets the flag")
	check(w.refreshes == 0, "bar on never refreshes")
end

-- 3. Retained install (flag set): no prompt, no request, no host timer.
do
	local w = world({ ["status_prompt.v1"] = { state = "granted", token = "old", at = 1 } })
	serve_host(w)
	check(w.timer_count == 0, "a retained install starts no host timer")
	w.load("w1").ensure(w.window("w1", false), "spawn")
	w.run(2000)
	check(#w.picks == 0, "retained install does not ask")
	check(w.kv["status_prompt.v1.request"] == nil, "retained install writes no request")
	check(w.timer_count == 0, "retained install starts no timers at all")
end

-- 5/6. No and dismiss change nothing and are never re-asked.
for _, outcome in { "no", "dismiss" } do
	local w = world()
	serve_host(w)
	local cx = w.window("w1", false)
	w.load("w1").ensure(cx, "spawn")
	w.run(2000)
	check(#w.picks == 1, outcome .. ": asked once")
	local fresh = w.window("w1-fresh", false)
	w.picks[1].callback(if outcome == "no" then w.picks[1].opts.items[2] else nil, nil, fresh)
	check(fresh.values.status_bar == false and cx.values.status_bar == false, outcome .. ": status_bar untouched")
	check(w.refreshes == 0, outcome .. ": no refresh")
	local again = w.window("w1b", false)
	w.load("w1b").ensure(again, "spawn")
	w.run(2000)
	check(#w.picks == 1, outcome .. ": never asked again")
end

-- An error answer (item nil, err set) is the same as dismiss.
do
	local w = world()
	serve_host(w)
	local cx = w.window("w1", false)
	w.load("w1").ensure(cx, "spawn")
	w.run(2000)
	w.picks[1].callback(nil, "picker failed", cx)
	check(cx.values.status_bar == false and w.refreshes == 0, "a picker error changes nothing")
end

-- 7. Two windows that both read "no request" before either writes: one prompt in total.
do
	local w = world()
	local host = w.load("host")
	local a, b = w.window("wa", false), w.window("wb", false)
	w.request_reads_nil.wb = true -- B's read happened before A's write landed
	w.load("wa").ensure(a, "spawn")
	w.load("wb").ensure(b, "spawn")
	w.request_reads_nil.wb = nil
	check(w.kv["status_prompt.v1.request"].token:find("wb", 1, true) ~= nil, "last write won the request slot (the lost-update case)")
	host.host_serve()
	w.run(3000)
	check(#w.picks == 1, "two racing windows produce one prompt")
	check(w.picks[1].window == "wb", "the window the host granted is the one that asks")
end

-- 7b. Same race, other interleaving (A's write is the survivor).
do
	local w = world()
	local host = w.load("host")
	local a, b = w.window("wa", false), w.window("wb", false)
	w.request_reads_nil.wa = true
	w.load("wb").ensure(b, "spawn")
	w.load("wa").ensure(a, "spawn")
	w.request_reads_nil.wa = nil
	host.host_serve()
	w.run(3000)
	check(#w.picks == 1 and w.picks[1].window == "wa", "the other interleaving also yields exactly one prompt")
end

-- 8. No host answer: fail closed, no prompt, no flag; a later window start can retry.
do
	local w = world()
	local cx = w.window("w1", false)
	w.load("w1").ensure(cx, "spawn")
	w.run(20000)
	check(#w.picks == 0, "no host means no prompt")
	check(w.kv["status_prompt.v1"] == nil, "no host means no flag")
	serve_host(w)
	local later = w.window("w2", false)
	w.load("w2").ensure(later, "spawn")
	w.run(2000)
	check(#w.picks == 1, "a later start with a host asks")
end

-- 9. A stale request (its window is gone) is cleared, never granted.
do
	local w = world({ ["status_prompt.v1.request"] = { token = "ghost", at = 1 } })
	local host = w.load("host")
	check(host.host_claim() == nil, "a stale request is not granted")
	check(w.kv["status_prompt.v1.request"] == nil and w.kv["status_prompt.v1"] == nil, "a stale request is cleared, no flag")
	check(host.host_claim() == nil, "an empty slot grants nothing")
end

-- 10. ensure runs once per VM.
do
	local w = world()
	serve_host(w)
	local cx = w.window("w1", false)
	local module = w.load("w1")
	module.ensure(cx, "spawn")
	module.ensure(cx, "spawn")
	w.run(2000)
	check(#w.picks == 1, "a repeated ensure in one VM asks once")
end

-- 11. A flag clobbered by another VM's concurrent kv.json write is re-asserted by the host.
do
	local w = world()
	serve_host(w)
	w.load("w1").ensure(w.window("w1", true), "spawn")
	w.run(500)
	local flag = w.kv["status_prompt.v1"]
	check(flag ~= nil, "flag granted")
	w.kv["status_prompt.v1"] = nil
	w.run(1000)
	check(w.kv["status_prompt.v1"] ~= nil and w.kv["status_prompt.v1"].token == flag.token, "host re-asserts a clobbered flag")
	w.run(20000)
	check(#w.timers == 0, "the host stops polling after its grace period")
end

-- Each plugin keeps its own flag: two plugins (separate kv stores) each ask once.
do
	local one, two = world(), world()
	serve_host(one)
	serve_host(two)
	one.load("w1").ensure(one.window("w1", false), "spawn")
	two.load("w1").ensure(two.window("w1", false), "usage")
	one.run(2000)
	two.run(2000)
	check(#one.picks == 1 and #two.picks == 1, "each plugin install asks once on its own flag")
end

return "PASS " .. checks .. " checks"
