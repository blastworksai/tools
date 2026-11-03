-- Behavioral boundary fixtures, run by the real Tern Lua driver with plugin root.
-- The process/timer doubles expose callbacks separately from launch: no synchronous
-- happy-path stub can hide a duplicate, timeout race or stale WindowCx here.
local root = ...
assert(type(root) == "string", "pass the plugin directory")
local real, environment = tern, getfenv()
local source = real.fs.read(root .. "/companion.luau")
local tests = 0
local function fixture(options)
	options = options or {}
	local clock, serial = 0, 0
	local processes, timers, logs = {}, {}, {}
	local fake = {
		context = options.context or "window", runtime = { os = options.os or "linux" },
		plugin = { dir = "/installed package/USAGE", data = "/private data/USAGE" },
		json = real.json, now = function() return clock end,
		getenv = function(key) return (options.env or {})[key] end,
		kv = { get = function(key)
			assert(key == "usage_python", "interpreter must use USAGE's own key")
			if options.kv_failure then error("SECRET KV error") end
			return options.python
		end },
		log = { warn = function(value) table.insert(logs, value) end },
	}
	fake.timer = function(ms, callback)
		local timer = { at = clock + ms, callback = callback, cancelled = false }
		function timer:cancel() self.cancelled = true end
		table.insert(timers, timer)
		return timer
	end
	fake.process = { run = function(argv, opts, callback)
		local process = { argv = table.clone(argv), opts = opts, callback = callback }
		table.insert(processes, process)
		if options.spawn_failure and options.spawn_failure(#processes, argv) then error("SECRET spawn path") end
	end }
	local chunk = assert(loadstring(source, "companion"))
	setfenv(chunk, setmetatable({ tern = fake }, { __index = environment }))
	local bridge = chunk()
	local f = { bridge = bridge, processes = processes, timers = timers, logs = logs }
	function f.advance(ms)
		local target = clock + ms
		while true do
			local nextTimer
			for _, timer in timers do
				if not timer.cancelled and timer.at <= target and (nextTimer == nil or timer.at < nextTimer.at) then nextTimer = timer end
			end
			if nextTimer == nil then break end
			clock = nextTimer.at
			nextTimer.cancelled = true
			serial += 1
			nextTimer.callback({ fresh_timer = serial })
		end
		clock = target
	end
	function f.resolve(index, value, cx, status, timedOut)
		processes[index].callback({ status = status or 0, stdout = real.json.encode(value) .. "\n",
			stderr = "SECRET stderr", timed_out = timedOut == true }, cx)
	end
	function f.raw(index, raw, status, cx)
		processes[index].callback({ status = status or 0, stdout = raw, stderr = "SECRET stderr", timed_out = false }, cx)
	end
	function f.probe(index, minor)
		f.resolve(index or 1, { major = 3, minor = minor or 11 }, { probe = true })
	end
	return f
end
local function recorder()
	local calls = {}
	return calls, function(value, err, cx) table.insert(calls, { value = value, err = err, cx = cx }) end
end
local function oneError(calls, code)
	assert(#calls == 1, "expected exactly one completion: " .. code)
	assert(calls[1].value == nil and calls[1].err.code == code, "wrong failure: " .. code)
	assert(not calls[1].err.message:find("SECRET", 1, true), "raw error leaked")
end
local function ready()
	return { ok = true, protocol = 1, schema = 1, build = "2.0.0-dev",
		device_id = "11111111-1111-4111-8111-111111111111", endpoint = "private endpoint", token = "SECRET authority" }
end
local function test(name, body)
	local ok, err = pcall(body)
	assert(ok, name .. ": " .. tostring(err))
	tests += 1
	-- Yield between cases so no Tern driver slice accumulates several of them.
	if type(await) == "function" then await(real.sleep(0)) end
end

test("ensure uses isolated validated Python and explicit default denial", function()
	local f = fixture()
	local calls, done = recorder()
	f.bridge.set_client("window:one", "window")
	f.bridge.ensure(done)
	assert(#calls == 0 and #f.processes == 1)
	assert(f.processes[1].argv[1] == "python3" and f.processes[1].argv[2] == "-I" and f.processes[1].argv[3] == "-B")
	assert(f.processes[1].opts.timeout_ms == 3000)
	f.advance(12)
	f.probe()
	assert(#calls == 0 and #f.processes == 2)
	local launch = f.processes[2]
	assert(launch.argv[4] == "/installed package/USAGE/usage_service.py" and launch.argv[5] == "ensure")
	assert(launch.argv[6] == "--data-root" and launch.argv[7] == "/private data/USAGE/companion")
	local body = real.json.decode(launch.opts.stdin)
	assert(body.client_id == "window:one" and body.client_kind == "window" and body.install_dependencies == false)
	assert(launch.opts.timeout_ms == 390000 - 12)
	local cx = { completion = true }
	f.resolve(2, ready(), cx)
	assert(#calls == 1 and calls[1].err == nil and calls[1].cx == cx)
	assert(calls[1].value.token == nil and calls[1].value.endpoint == nil)
	local _, again = recorder()
	f.bridge.request("diagnostics", {}, again)
	assert(#f.processes == 3 and f.processes[3].argv[1] == "python3" and f.processes[3].argv[4] == launch.argv[4]
		and #f.processes[3].argv == #launch.argv, "validated interpreter prefix is reused without leaking argv state")
	f.advance(390000)
	assert(#calls == 1)
end)

test("explicit dependency consent only", function()
	for _, consent in { true, false } do
		local f = fixture()
		local calls, done = recorder()
		f.bridge.set_client("setup", "setup")
		f.bridge.ensure(done, { install_dependencies = consent })
		f.probe()
		assert(real.json.decode(f.processes[2].opts.stdin).install_dependencies == consent)
		f.resolve(2, ready())
		assert(#calls == 1 and calls[1].err == nil)
	end
	for _, options in { { install_dependencies = "yes" }, { install_dependencies = true, hidden = true }, "yes" } do
		local f = fixture()
		local calls, done = recorder()
		f.bridge.set_client("setup", "setup")
		f.bridge.ensure(done, options)
		assert(#calls == 0 and #f.processes == 0)
		f.advance(0)
		oneError(calls, "invalid_request")
	end
end)

test("duplicate probe and request callbacks cannot advance twice", function()
	local f = fixture()
	local calls, done = recorder()
	f.bridge.request("aggregate", { cursor = "one" }, done)
	f.probe(); f.probe()
	assert(#f.processes == 2)
	local body = real.json.decode(f.processes[2].opts.stdin)
	assert(body.operation == "aggregate" and body.payload.cursor == "one")
	assert(f.processes[2].opts.timeout_ms <= 30000)
	local cx = {}
	f.resolve(2, { ok = true, records = {} }, cx)
	f.resolve(2, { ok = false, error = { code = "unauthorized" } }, {})
	assert(#calls == 1 and calls[1].value.ok == true and calls[1].cx == cx)
end)

test("launcher spawn exception is deferred and sanitized", function()
	local f = fixture({ spawn_failure = function(index) return index == 2 end })
	local calls, done = recorder()
	f.bridge.request("diagnostics", {}, done)
	f.probe()
	assert(#calls == 0)
	f.advance(0)
	oneError(calls, "spawn_failed")
	assert(calls[1].cx.fresh_timer ~= nil)
	f.resolve(2, { ok = true })
	f.advance(30000)
	assert(#calls == 1)
end)

test("process timeout beats late success", function()
	local f = fixture()
	local calls, done = recorder()
	f.bridge.request("inventory", {}, done)
	f.probe()
	local cx = {}
	f.resolve(2, {}, cx, -1, true)
	oneError(calls, "timeout")
	assert(calls[1].cx == cx)
	f.resolve(2, { ok = true })
	f.advance(30000)
	assert(#calls == 1)
end)

test("whole request watchdog covers absent process callbacks", function()
	local f = fixture()
	local calls, done = recorder()
	f.bridge.request("inventory", {}, done)
	f.advance(29999)
	assert(#calls == 0)
	f.advance(1)
	oneError(calls, "timeout")
	assert(calls[1].cx.fresh_timer ~= nil)
	f.probe()
	f.bridge.request("diagnostics", {}, function() end)
	assert(#f.processes == 2 and f.processes[2].argv[4] == "-c", "a late probe cannot select an interpreter")
end)

test("whole ensure watchdog has a bounded lifetime", function()
	local f = fixture()
	local calls, done = recorder()
	f.bridge.set_client("host", "host")
	f.bridge.ensure(done)
	f.probe()
	f.advance(390000)
	oneError(calls, "timeout")
	f.resolve(2, ready())
	assert(#calls == 1)
end)

test("decode status and fixed service errors", function()
	local cases = {
		{ raw = "SECRET invalid json", status = 0, code = "decode_failed" },
		{ raw = "SECRET invalid json", status = 9, code = "companion_unavailable" },
		{ raw = "[]", code = "decode_failed" },
		{ raw = '{"ok":"true"}', code = "decode_failed" },
		{ raw = '{"ok":true}', status = 2, code = "companion_unavailable" },
		{ raw = '{"ok":false,"error":{"code":"setup_required","message":"SECRET body"}}', status = 1, code = "setup_required" },
		{ raw = '{"ok":false,"error":{"code":"source_roster_invalid","message":"SECRET body"}}', status = 1, code = "source_roster_invalid" },
		{ raw = '{"ok":false,"error":{"code":"SECRET code","message":"SECRET body"}}', code = "internal_error" },
		{ raw = '{"ok":false}', code = "internal_error" },
		{ raw = string.rep("x", 1048578), code = "response_too_large" },
		{ raw = string.rep("x", 1048577), code = "response_too_large" },
	}
	for _, case in cases do
		local f = fixture()
		local calls, done = recorder()
		f.bridge.request("diagnostics", {}, done)
		f.probe()
		local cx = {}
		f.raw(2, case.raw, case.status, cx)
		oneError(calls, case.code)
		assert(calls[1].cx == cx)
		f.raw(2, case.raw, case.status)
		assert(#calls == 1)
	end
end)

test("one MiB JSON plus launcher newline is accepted", function()
	local f = fixture()
	local calls, done = recorder()
	f.bridge.request("aggregate", {}, done)
	f.probe()
	local prefix, suffix = '{"ok":true,"data":"', '"}'
	local raw = prefix .. string.rep("x", 1048576 - #prefix - #suffix) .. suffix
	f.raw(2, raw .. "\n")
	assert(#calls == 1 and calls[1].err == nil)
end)

test("incompatible ensure never accepts an old service", function()
	for _, field in { "protocol", "schema" } do
		local f = fixture()
		local calls, done = recorder()
		f.bridge.set_client("host", "host")
		f.bridge.ensure(done)
		f.probe()
		local response = ready(); response[field] = 99
		f.resolve(2, response)
		oneError(calls, "incompatible_version")
	end
end)

test("invalidate cancels all generations with fresh timer contexts", function()
	local f = fixture()
	local a, doneA = recorder()
	local b, doneB = recorder()
	f.bridge.request("inventory", {}, doneA)
	f.probe()
	f.bridge.request("diagnostics", {}, doneB)
	assert(#f.processes == 3)
	f.bridge.invalidate()
	assert(#a == 0 and #b == 0)
	f.resolve(2, { ok = true }, { stale = true })
	f.resolve(3, { ok = true }, { stale = true })
	f.advance(0)
	oneError(a, "cancelled"); oneError(b, "cancelled")
	assert(a[1].cx.fresh_timer ~= nil and b[1].cx.fresh_timer ~= nil)
	local c, doneC = recorder()
	f.bridge.request("inventory", {}, doneC)
	assert(#f.processes == 4)
	f.probe(1)
	assert(#f.processes == 4)
	f.probe(4)
	f.resolve(5, { ok = true }, { current = true })
	assert(#c == 1 and c[1].cx.current == true)
	f.advance(390000)
	assert(#a == 1 and #b == 1 and #c == 1)
end)

test("invalidation before spawn-error dispatch remains exactly once", function()
	local f = fixture({ spawn_failure = function() return true end })
	local calls, done = recorder()
	f.bridge.request("inventory", {}, done)
	f.bridge.invalidate(); f.bridge.invalidate()
	f.advance(0)
	oneError(calls, "cancelled")
	assert(#f.processes == 1)
end)

test("changing client invalidates in-flight registration", function()
	local f = fixture()
	local calls, done = recorder()
	f.bridge.set_client("window:old", "window")
	f.bridge.ensure(done)
	f.probe()
	f.bridge.set_client("window:new", "window")
	f.resolve(2, ready(), { stale = true })
	f.advance(0)
	oneError(calls, "cancelled")
end)

test("host never receives a window context", function()
	local f = fixture({ context = "host" })
	local calls, done = recorder()
	f.bridge.request("inventory", {}, done)
	f.probe()
	f.resolve(2, { ok = true }, { should_not_escape = true })
	assert(#calls == 1 and calls[1].cx == nil)
	local cancelled, cancelDone = recorder()
	f.bridge.request("inventory", {}, cancelDone)
	f.bridge.invalidate(); f.advance(0)
	oneError(cancelled, "cancelled")
	assert(cancelled[1].cx == nil)
end)

test("consumer exception never leaks or completes twice", function()
	local f, count = fixture(), 0
	f.bridge.request("inventory", {}, function()
		count += 1
		error("SECRET consumer exception")
	end)
	f.probe()
	f.resolve(2, { ok = true })
	f.resolve(2, { ok = true })
	f.advance(30000)
	assert(count == 1 and #f.logs == 1 and f.logs[1] == "USAGE callback_failed")
end)

test("GUI macOS falls back from old PATH interpreter", function()
	local f = fixture({ os = "macos" })
	local calls, done = recorder()
	f.bridge.request("inventory", {}, done)
	f.probe(1, 10)
	assert(f.processes[2].argv[1] == "/opt/homebrew/bin/python3")
	f.raw(2, "not Python", 1)
	assert(f.processes[3].argv[1] == "/usr/local/bin/python3")
	f.probe(3, 14)
	f.resolve(4, { ok = true })
	assert(#calls == 1 and calls[1].err == nil and f.processes[4].argv[1] == "/usr/local/bin/python3")
end)

test("Windows launcher and GUI installation paths are argv not shell", function()
	local f = fixture({ os = "windows", env = { LOCALAPPDATA = "C:/User Space/Local" } })
	local calls, done = recorder()
	f.bridge.request("inventory", {}, done)
	assert(f.processes[1].argv[1] == "py" and f.processes[1].argv[2] == "-3" and f.processes[1].argv[3] == "-I")
	f.raw(1, "", 1); f.raw(2, "", 1); f.raw(3, "", 1)
	assert(f.processes[4].argv[1] == "C:/User Space/Local/Programs/Python/Python315/python.exe")
	f.probe(4, 15)
	assert(f.processes[5].argv[1] == f.processes[4].argv[1])
	f.resolve(5, { ok = true })
	assert(#calls == 1 and calls[1].err == nil)
end)

test("configured executable is validated without default fallback", function()
	for _, configured in { "/Python With Spaces/python3", { "py", "-3" } } do
		local f = fixture({ python = configured })
		local calls, done = recorder()
		f.bridge.request("inventory", {}, done)
		assert(f.processes[1].argv[1] == (if type(configured) == "string" then configured else "py"))
		f.probe(1, 10)
		f.advance(0)
		oneError(calls, "python_required")
		assert(#f.processes == 1)
	end
	local f = fixture({ python = { "python3", "-c", "SECRET command" } })
	local calls, done = recorder()
	f.bridge.request("inventory", {}, done); f.advance(0)
	oneError(calls, "invalid_request")
	assert(#f.processes == 0)
end)

test("probe spawn timeout and malformed versions end explicitly", function()
	for _, outcome in { "spawn", "timeout", "malformed", "major", "oversized" } do
		local f = fixture({ spawn_failure = function() return outcome == "spawn" end })
		local calls, done = recorder()
		f.bridge.request("inventory", {}, done)
		if outcome == "timeout" then f.resolve(1, {}, nil, -1, true)
		elseif outcome == "malformed" then f.raw(1, "SECRET non JSON")
		elseif outcome == "major" then f.resolve(1, { major = 2, minor = 99 })
		elseif outcome == "oversized" then f.raw(1, string.rep("x", 257)) end
		f.advance(0)
		oneError(calls, "python_required")
	end
end)

test("unsupported platforms and unreadable configuration are explicit", function()
	for _, item in { { os = "ios", code = "unsupported_platform" }, { os = "web", code = "unsupported_platform" },
		{ kv_failure = true, code = "configuration_unavailable" } } do
		local f = fixture(item)
		local calls, done = recorder()
		f.bridge.request("inventory", {}, done)
		assert(#calls == 0 and #f.processes == 0)
		f.advance(0)
		oneError(calls, item.code)
	end
end)

test("input validation and encoding failures do not start processes", function()
	local invalid = { { operation = "bad operation", payload = {} }, { operation = "inventory", payload = "bad" },
		{ operation = "publish", payload = { body = string.rep("x", 1048576) }, code = "snapshot_too_large" },
		{ operation = "publish", payload = { unsupported = function() end } } }
	for _, item in invalid do
		local f = fixture()
		local calls, done = recorder()
		f.bridge.request(item.operation, item.payload, done)
		assert(#calls == 0 and #f.processes == 0)
		f.advance(0)
		oneError(calls, item.code or "invalid_request")
	end
	local f = fixture()
	local calls, done = recorder()
	f.bridge.ensure(done); f.advance(0)
	oneError(calls, "invalid_request")
	assert(#f.processes == 0)
end)

test("every companion service code keeps its own fixed message", function()
	local protocol = real.fs.read(root .. "/usage_service/protocol.py")
	local block = assert(protocol:match("\nMESSAGES = (%b{})"), "protocol.py MESSAGES table")
	local f = fixture()
	local launched, codes = 1, 0
	for code in block:gmatch('"([a-z_]+)"%s*:') do
		local calls, done = recorder()
		f.bridge.request("diagnostics", {}, done)
		if launched == 1 then f.probe() end
		launched = #f.processes
		f.raw(launched, real.json.encode({ ok = false, error = { code = code, message = "SECRET body" } }), 1)
		assert(#calls == 1 and calls[1].err.code == code, "unmapped companion code: " .. code)
		assert(not calls[1].err.message:find("SECRET", 1, true))
		codes += 1
	end
	assert(codes >= 30, "protocol MESSAGES parsed")
end)

return "PASS " .. tostring(tests) .. " companion asynchronous boundary fixtures"
