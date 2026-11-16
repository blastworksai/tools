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
	local w = { files = {}, kv = {}, now = 0, seconds = 1000, timers = {}, picks = {}, refreshes = 0, flag_reads_stale = {}, request_reads_nil = {} }
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
					if key == "status_prompt.v2.request" and w.request_reads_nil[name] then return nil end
					return w.kv[key]
				end,
				set = function(key, value) w.kv[key] = value end,
			},
			chrome = { refresh = function() w.refreshes += 1 end },
			plugin = { data = "/data" },
			fs = {
				exists = function(path) return w.files[path] ~= nil end,
				remove = function(path) w.files[path] = nil end,
				write = function(path, text) w.files[path] = text end,
				read = function(path) return assert(w.files[path], "no such file") end,
				mkdir = function() end,
			},
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
	w.reads = {}
	-- bar_on: true = Plugin segments widget placed, false = absent, "raise" = reading `widgets` raises.
	function w.window(name, bar_on)
		w.reads[name] = 0
		local widgets = { { id = "cwd" }, { id = "git" } }
		if bar_on == true then table.insert(widgets, { id = "status" }) end
		local settings_values = { widgets = widgets }
		local cx
		cx = {
			settings = {
				get = function(_self, key)
					w.reads[name] += 1
					if bar_on == "raise" or (type(bar_on) == "table" and bar_on.fail_after ~= nil and w.reads[name] > bar_on.fail_after) then error("runtime error: Unknown preference '" .. key .. "'") end
					return settings_values[key]
				end,
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
	check(w.picks[1].opts.placeholder == "Would you like to show plugin buttons in the status bar?", "the question is the specified one")
	check(w.picks[1].opts.items[1].answer == true and w.picks[1].opts.items[1].label:find("^Yes") ~= nil, "Yes is first (recommended)")
	check(w.picks[1].opts.items[2].answer == false, "No is second")
	check(w.kv["status_prompt.v2"] ~= nil, "the flag is claimed before the answer")
	check(#cx.values.widgets == 2 and w.refreshes == 0, "asking changes nothing by itself")
	-- 4. Yes: sets the setting through the FRESH cx and refreshes once, from the callback.
	local fresh = w.window("w1-fresh", false)
	w.picks[1].callback(w.picks[1].opts.items[1], nil, fresh)
	check(#fresh.values.widgets == 3 and fresh.values.widgets[1].id == "cwd" and fresh.values.widgets[2].id == "git" and fresh.values.widgets[3].id == "status",
		"Yes appends {id=status} to the fresh cx's list, keeping every entry and its order")
	check(#cx.values.widgets == 2, "the stale cx is left alone")
	check(w.refreshes == 1, "Yes refreshes the chrome exactly once")
	-- 12. A second window of the same install after the claim never asks, though its bar is off.
	local second = w.window("w2", false)
	w.load("w2").ensure(second, "spawn")
	w.run(2000)
	check(#w.picks == 1, "a later window of a claimed install does not ask")
end

-- 2. Widget already placed: no prompt, flag still set.
do
	local w = world()
	serve_host(w)
	w.load("w1").ensure(w.window("w1", true), "spawn")
	w.run(2000)
	check(#w.picks == 0, "widget placed asks nothing")
	check(w.kv["status_prompt.v2"] ~= nil, "widget placed still sets the flag (a later removal is respected)")
	check(w.refreshes == 0, "bar on never refreshes")
end

-- 3. Retained install (flag set): no prompt, no request, no host timer.
do
	local w = world({ ["status_prompt.v2"] = { state = "granted", token = "old", at = 1 } })
	serve_host(w)
	check(w.timer_count == 0, "a retained install starts no host timer")
	w.load("w1").ensure(w.window("w1", false), "spawn")
	w.run(2000)
	check(#w.picks == 0, "retained install does not ask")
	check(w.kv["status_prompt.v2.request"] == nil, "retained install writes no request")
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
	check(#fresh.values.widgets == 2 and #cx.values.widgets == 2, outcome .. ": widgets untouched")
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
	check(#cx.values.widgets == 2 and w.refreshes == 0, "a picker error changes nothing")
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
	check(w.kv["status_prompt.v2.request"].token:find("wb", 1, true) ~= nil, "last write won the request slot (the lost-update case)")
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
	check(w.kv["status_prompt.v2"] == nil, "no host means no flag")
	serve_host(w)
	local later = w.window("w2", false)
	w.load("w2").ensure(later, "spawn")
	w.run(2000)
	check(#w.picks == 1, "a later start with a host asks")
end

-- 9. A stale request (its window is gone) is cleared, never granted.
do
	local w = world({ ["status_prompt.v2.request"] = { token = "ghost", at = 1 } })
	local host = w.load("host")
	check(host.host_claim() == nil, "a stale request is not granted")
	check(w.kv["status_prompt.v2.request"] == nil and w.kv["status_prompt.v2"] == nil, "a stale request is cleared, no flag")
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
	local flag = w.kv["status_prompt.v2"]
	check(flag ~= nil, "flag granted")
	w.kv["status_prompt.v2"] = nil
	w.run(1000)
	check(w.kv["status_prompt.v2"] ~= nil and w.kv["status_prompt.v2"].token == flag.token, "host re-asserts a clobbered flag")
	w.run(20000)
	check(#w.timers == 1 and w.timers[1].vm == "host" and w.timers[1].at - w.now > 0, "after its grace period the host only idles on one slow tick")
end

-- 13. A flag lost to a whole-store kv.json write after the host's grace period, then a host restart, never re-asks.
do
	local w = world()
	serve_host(w)
	local first = w.window("w1", false)
	w.load("w1").ensure(first, "spawn")
	w.run(30000)
	check(#w.picks == 1, "first window asked once")
	w.kv["status_prompt.v2"] = nil
	w.kv["status_prompt.v2.request"] = nil
	w.load("host2").host_serve()
	w.load("w2").ensure(w.window("w2", false), "spawn")
	w.run(30000)
	check(#w.picks == 1 and w.kv["status_prompt.v2"] == nil, "a lost kv flag plus a host restart does not ask again")
end

-- 14. The host grants and writes the marker, a stale kv write drops the flag AND the request before the winning
-- window polls: that window still gets its prompt once, and later windows never prompt.
do
	local w = world()
	local host = w.load("host")
	local winner = w.window("w1", false)
	w.load("w1").ensure(winner, "spawn")
	check(host.host_claim() ~= nil, "host grants the pending request")
	w.kv["status_prompt.v2"] = nil
	w.kv["status_prompt.v2.request"] = nil
	w.run(500)
	check(#w.picks == 1 and w.picks[1].window == "w1", "the winner still gets its prompt after a stale kv write")
	w.run(5000)
	check(#w.picks == 1, "the winner is asked exactly once")
	w.load("w2").ensure(w.window("w2", false), "spawn")
	w.load("w3").ensure(w.window("w3", false), "spawn")
	w.run(20000)
	check(#w.picks == 1, "later windows do not prompt")
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

-- 15. Reading `widgets` raises: no prompt, no error, no request, no flag, no marker; a later healthy start asks once.
do
	local w = world()
	serve_host(w)
	w.load("w1").ensure(w.window("w1", "raise"), "spawn")
	w.run(3000)
	check(#w.picks == 0, "a failed settings read asks nothing")
	check(w.kv["status_prompt.v2"] == nil and w.kv["status_prompt.v2.request"] == nil, "a failed settings read leaves no flag and no request")
	check(next(w.files) == nil, "a failed settings read writes no marker")
	w.load("w2").ensure(w.window("w2", false), "spawn")
	w.run(3000)
	check(#w.picks == 1, "the next healthy start asks once")
end

-- 16. A pick answered Yes whose fresh cx cannot read `widgets` changes nothing and does not raise.
do
	local w = world()
	serve_host(w)
	w.load("w1").ensure(w.window("w1", false), "spawn")
	w.run(2000)
	local broken = w.window("w1-broken", "raise")
	w.picks[1].callback(w.picks[1].opts.items[1], nil, broken)
	check(w.refreshes == 0, "a failed widgets read on Yes does not refresh")
end

-- 17. An install that asked under v1 (v1 flag + marker, never really asked) is asked once under v2.
do
	local w = world({ ["status_prompt.v1"] = { state = "granted", token = "old", at = 1 } })
	w.files["/data/status_prompt.v1.done"] = "old\n"
	serve_host(w)
	check(w.timer_count > 0, "a v1-marked install starts the v2 host")
	w.load("w1").ensure(w.window("w1", false), "spawn")
	w.run(2000)
	check(#w.picks == 1, "a v1-marked install is asked once under v2")
	w.load("w2").ensure(w.window("w2", false), "spawn")
	w.run(2000)
	check(#w.picks == 1, "and never twice")
end

-- 18. Yes when the widget was placed meanwhile: not appended twice, no refresh.
do
	local w = world()
	serve_host(w)
	w.load("w1").ensure(w.window("w1", false), "spawn")
	w.run(2000)
	local fresh = w.window("w1-fresh", true)
	w.picks[1].callback(w.picks[1].opts.items[1], nil, fresh)
	check(#fresh.values.widgets == 3 and w.refreshes == 0, "an already placed widget is not appended twice")
end

-- 19. The preflight read succeeds but the read inside ask() fails: no picker, the grant is handed back through the
-- host, and a later healthy start (even after a host restart) asks exactly once; no other window asks twice.
do
	local w = world()
	serve_host(w)
	local first = w.window("w1", { fail_after = 1 }) -- read 1 (preflight) ok, read 2 (inside ask) raises
	w.load("w1").ensure(first, "spawn")
	w.run(3000)
	check(#w.picks == 0, "a read failing inside ask opens no picker")
	check(w.kv["status_prompt.v2"] == nil, "the released grant clears the v2 flag")
	check(w.files["/data/status_prompt.v2.done"] == nil, "the released grant clears the v2 marker")
	check(w.kv["status_prompt.v2.release"] == nil, "the release request is consumed")
	w.run(30000)
	w.load("host2").host_serve() -- a host restart does not resurrect the grant
	local second = w.window("w2", false)
	w.load("w2").ensure(second, "spawn")
	w.run(3000)
	check(#w.picks == 1 and w.picks[1].window == "w2", "a later healthy start asks exactly once")
	w.load("w3").ensure(w.window("w3", false), "spawn")
	w.load("host3").host_serve()
	w.run(20000)
	check(#w.picks == 1, "no other window asks a second time")
end

-- 20. A release for a grant that moved on (another token) leaves the current grant alone.
do
	local w = world()
	serve_host(w)
	w.load("w1").ensure(w.window("w1", false), "spawn")
	w.run(2000)
	check(#w.picks == 1, "the first window holds the grant")
	local host = w.load("hostx")
	w.kv["status_prompt.v2.release"] = { token = "someone-else", at = 1 }
	check(host.host_release() == false, "a foreign token releases nothing")
	check(w.kv["status_prompt.v2"] ~= nil and w.files["/data/status_prompt.v2.done"] ~= nil, "the current grant stands")
end

-- Detaches (and returns) every pending timer of one VM, so a test can hold it back like a delayed callback.
local function hold(w, vm)
	local held = {}
	for index = #w.timers, 1, -1 do
		if w.timers[index].vm == vm then table.insert(held, table.remove(w.timers, index)) end
	end
	return held
end

local function give_back(w, held)
	for _, timer in held do table.insert(w.timers, timer) end
end

-- 21. SKILLS-185 (1): the window released its grant; a stale whole-store kv write then brings the request back (and
-- drops the release). The host must not grant the released token again: a later healthy start asks exactly once.
do
	local w = world()
	serve_host(w)
	local first = w.window("w1", { fail_after = 1 })
	w.load("w1").ensure(first, "spawn")
	w.run(0) -- the host grants the request
	local flag = w.kv["status_prompt.v2"]
	check(flag ~= nil, "the host granted the first window")
	local token = flag.token
	w.run(300) -- the window releases and the host (still polling) consumes it
	check(#w.picks == 0 and w.kv["status_prompt.v2"] == nil, "the release cleared the flag")
	-- the stale VM's whole-store write: its older copy still holds the request, and has no release in it
	w.kv["status_prompt.v2.request"] = { token = token, at = w.seconds }
	w.kv["status_prompt.v2.release"] = nil
	w.run(3000)
	check(w.kv["status_prompt.v2"] == nil or w.kv["status_prompt.v2"].token ~= token, "a released token is never granted again")
	check(w.files["/data/status_prompt.v2.done"] == nil or w.files["/data/status_prompt.v2.done"] ~= token .. "\n", "no marker for the released token")
	w.load("w2").ensure(w.window("w2", false), "spawn")
	w.run(3000)
	check(#w.picks == 1 and w.picks[1].window == "w2", "a later healthy start asks exactly once")
	w.load("w3").ensure(w.window("w3", false), "spawn")
	w.run(20000)
	check(#w.picks == 1, "and nobody asks twice")
end

-- 21b. The stale write also brings back the released FLAG: it must not count as "asked".
do
	local w = world()
	serve_host(w)
	w.load("w1").ensure(w.window("w1", { fail_after = 1 }), "spawn")
	w.run(0)
	local flag = w.kv["status_prompt.v2"]
	w.run(3000)
	w.kv["status_prompt.v2"] = flag -- resurrected by a stale write; no host restart follows
	w.load("w2").ensure(w.window("w2", false), "spawn")
	w.run(3000)
	check(#w.picks == 1 and w.picks[1].window == "w2", "a resurrected flag of a released token does not suppress the question")
end

-- 22. SKILLS-185 (2): the window's callback runs after the host stopped polling (a delayed timer). The release must
-- still take effect with no host consumer, and a restarted host serves the next window.
do
	local w = world()
	serve_host(w)
	w.load("w1").ensure(w.window("w1", { fail_after = 1 }), "spawn")
	w.run(0)
	check(w.kv["status_prompt.v2"] ~= nil, "granted")
	local late = hold(w, "w1")
	w.run(30000)
	check(#w.timers == 1 and w.timers[1].vm == "host", "the host is only idling on its slow tick")
	give_back(w, late)
	w.run(1000)
	check(#w.picks == 0, "the delayed window opened no picker")
	check(w.kv["status_prompt.v2"] == nil and w.files["/data/status_prompt.v2.done"] == nil, "a release after the host stopped still clears the grant")
	w.load("w2").ensure(w.window("w2", false), "spawn") -- no host restart: the host still serves
	w.run(3000)
	check(#w.picks == 1 and w.picks[1].window == "w2", "the next healthy start asks once with no host restart")
end

-- 22b. A release left in kv that no running host consumed: a host start processes it.
do
	local w = world()
	serve_host(w)
	w.load("w1").ensure(w.window("w1", false), "spawn")
	w.run(2000)
	local token = w.kv["status_prompt.v2"].token
	w.run(30000)
	w.kv["status_prompt.v2.release"] = { token = token, at = w.seconds }
	w.load("host2").host_serve()
	check(w.kv["status_prompt.v2"] == nil and w.files["/data/status_prompt.v2.done"] == nil, "a host start processes a release left behind")
end

return "PASS " .. checks .. " checks"
