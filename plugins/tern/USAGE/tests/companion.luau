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
	local hooks = {}
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
	fake.on = function(name, callback)
		if options.hook_failure ~= nil then error(options.hook_failure, 0) end
		if name ~= "unload" or not options.unload_supported then
			if fake.context == "window" then error('tern.on: unknown window event `' .. name .. '`', 0) end
			error('tern.on: unknown host event "' .. name .. '" (spawn, command_started, command_finished, cwd, title, pane_exited)', 0)
		end
		hooks[name] = callback
	end
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
	local f = { bridge = bridge, processes = processes, timers = timers, logs = logs, hooks = hooks }
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
	assert(body.client_id:match("^window:") and body.client_id ~= "window:one"
		and body.client_kind == "window" and body.install_dependencies == false)
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

test("unavailable native unload events retain lease expiry without hiding other errors", function()
	for _, context in { "host", "window" } do
		local f = fixture({ context = context })
		assert(f.bridge.on_unload(f.bridge.unload) == false)
		assert(f.hooks.unload == nil and #f.logs == 1 and #f.processes == 0)
		f.bridge.set_client(context, context)
		f.bridge.ensure(function() end)
		f.probe()
		assert(f.processes[2].argv[5] == "ensure", "missing optional unload must not prevent the ordinary service path")
	end
	for _, message in { "registration budget exhausted", 'tern.on: unknown host event "pane_exited" (spawn)',
		'tern.on: unknown window event `unload`' } do
		local f = fixture({ context = "host", hook_failure = message })
		local ok, err = pcall(f.bridge.on_unload, f.bridge.unload)
		assert(not ok and tostring(err):find(message, 1, true) ~= nil and #f.logs == 0,
			"only the exact unsupported current-context unload event may fall back")
	end
end)

test("native non-string errors use rendering only for the exact capability rejection", function()
	for _, observed in {
		{ context = "host", message = 'runtime error: tern.on: unknown host event "unload" (spawn, command_started, command_finished, cwd, title, pane_exited)\nstack traceback:\n\t[native registration]' },
		{ context = "window", message = 'runtime error: tern.on: unknown window event `unload`\nstack traceback:\n\t[native registration]' },
	} do
		local unsupported = setmetatable({}, { __tostring = function() return observed.message end })
		local older = fixture({ context = observed.context, hook_failure = unsupported })
		assert(older.bridge.on_unload(older.bridge.unload) == false and #older.logs == 1)
	end
	local unrelated = setmetatable({}, { __tostring = function()
		return "runtime error: registration budget exhausted\nstack traceback:\n\t[native registration]"
	end })
	local broken = fixture({ context = "host", hook_failure = unrelated })
	local ok, err = pcall(broken.bridge.on_unload, broken.bridge.unload)
	assert(not ok and err == unrelated and #broken.logs == 0,
		"an unrelated native error must propagate as its original non-string object")
end)

test("unload releases only its incarnation and rejects late continuations", function()
	local f = fixture({ unload_supported = true })
	assert(f.bridge.on_unload(f.bridge.unload) == true)
	local calls, done = recorder()
	f.bridge.set_client("window:reused", "window")
	f.bridge.ensure(done)
	f.probe()
	local oldId = real.json.decode(f.processes[2].opts.stdin).client_id
	f.hooks.unload()
	assert(#f.processes == 3 and f.processes[3].argv[5] == "rpc")
	local release = real.json.decode(f.processes[3].opts.stdin)
	assert(release.operation == "unregister_client" and release.payload.client_id == oldId)
	assert(f.processes[3].opts.timeout_ms == 30000)
	f.bridge.unload()
	f.resolve(2, ready(), { stale = true })
	f.advance(0)
	oneError(calls, "cancelled")
	local late, lateDone = recorder()
	f.bridge.ensure(lateDone)
	f.bridge.renew(lateDone)
	f.bridge.request("diagnostics", {}, lateDone)
	f.advance(0)
	assert(#f.processes == 3 and #late == 3)
	for _, call in late do assert(call.err.code == "cancelled") end
end)

test("invalidation renews a different lease before an old release finishes", function()
	local f = fixture()
	f.bridge.set_client("host", "host")
	f.bridge.ensure(function() end)
	f.probe()
	local oldId = real.json.decode(f.processes[2].opts.stdin).client_id
	f.bridge.invalidate()
	local oldRelease = real.json.decode(f.processes[3].opts.stdin)
	assert(oldRelease.payload.client_id == oldId)
	f.bridge.renew(function() end)
	f.probe(4)
	local renewed = real.json.decode(f.processes[5].opts.stdin)
	assert(renewed.operation == "register_client" and renewed.payload.kind == "host"
		and renewed.payload.client_id ~= oldId and renewed.payload.ttl_seconds == 90)
	f.resolve(3, { ok = true, unregistered = true })
	f.resolve(5, { ok = true, registered = true })
	f.bridge.unload()
	assert(real.json.decode(f.processes[6].opts.stdin).payload.client_id == renewed.payload.client_id)
end)

test("unload before interpreter discovery cannot start or release a helper", function()
	local f = fixture()
	local calls, done = recorder()
	f.bridge.set_client("host", "host")
	f.bridge.ensure(done)
	f.bridge.unload()
	f.probe()
	f.advance(0)
	oneError(calls, "cancelled")
	assert(#f.processes == 1)
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
	assert(f.processes[1].argv[1] == "/opt/homebrew/bin/python3")
	f.probe(1, 10)
	assert(f.processes[2].argv[1] == "/usr/local/bin/python3")
	f.probe(2, 14)
	f.resolve(3, { ok = true })
	assert(#calls == 1 and calls[1].err == nil and f.processes[3].argv[1] == "/usr/local/bin/python3")
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

test("Windows Store python stubs and missing interpreters end in python_required, not a hang", function()
	local f = fixture({ os = "windows", env = { LOCALAPPDATA = "C:/Local" } })
	local calls, done = recorder()
	f.bridge.request("inventory", {}, done)
	for index = 1, 8 do
		assert(f.processes[index] ~= nil, "candidate " .. index)
		-- The App Execution Alias stub prints "Python was not found" and exits 9009.
		f.raw(index, "Python was not found; run without arguments to install from the Microsoft Store.", 9009)
	end
	f.advance(0)
	oneError(calls, "python_required")
end)

test("macOS also tries the python.org framework install", function()
	local f = fixture({ os = "macos" })
	local calls, done = recorder()
	f.bridge.request("inventory", {}, done)
	f.raw(1, "", 1); f.raw(2, "", 1)
	assert(f.processes[3].argv[1] == "/Library/Frameworks/Python.framework/Versions/Current/bin/python3")
	f.probe(3, 13)
	f.resolve(4, { ok = true })
	assert(#calls == 1 and calls[1].err == nil)
end)

test("macOS never probes bare python3 (Apple's shim opens an installer dialog); none found names the road", function()
	local f = fixture({ os = "macos" })
	local calls, done = recorder()
	f.bridge.request("inventory", {}, done)
	for index = 1, 3 do
		assert(f.processes[index] ~= nil and f.processes[index].argv[1] ~= "python3", "candidate " .. index)
		f.raw(index, "", 1)
	end
	f.advance(0)
	assert(#f.processes == 3)
	oneError(calls, "python_required")
	assert(calls[1].err.message:find("install it", 1, true) and calls[1].err.message:find("USAGE Setup", 1, true))
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

test("the host bootstraps once per load on Linux, Windows and macOS, never for another client", function()
	local f = fixture({ context = "host" })
	local calls, done = recorder()
	f.bridge.set_client("host", "host")
	f.bridge.ensure(done, { auto_install = true })
	f.probe()
	assert(real.json.decode(f.processes[2].opts.stdin).install_dependencies == true, "first host start installs")
	f.resolve(2, ready())
	assert(#calls == 1 and calls[1].err == nil)
	local again, done2 = recorder()
	f.bridge.ensure(done2, { auto_install = true })
	f.advance(0)
	local last = f.processes[#f.processes]
	assert(real.json.decode(last.opts.stdin).install_dependencies == false, "a second start never installs again")
	for _, case in { { context = "window", os = "linux" }, { context = "window", os = "macos" }, { context = "window", os = "windows" } } do
		local g = fixture({ context = case.context, os = case.os })
		local _, cb = recorder()
		g.bridge.set_client("window:1", "window")
		g.bridge.ensure(cb, { auto_install = true })
		g.probe()
		assert(real.json.decode(g.processes[2].opts.stdin).install_dependencies == false, case.os .. "/" .. case.context)
	end
	for _, osName in { "macos", "windows" } do
		local g = fixture({ context = "host", os = osName, env = { LOCALAPPDATA = "C:/Local" } })
		local gCalls, cb = recorder()
		g.bridge.set_client("host", "host")
		g.bridge.ensure(cb, { auto_install = true })
		g.probe()
		assert(real.json.decode(g.processes[2].opts.stdin).install_dependencies == true, osName .. " host installs")
		g.resolve(2, ready())
		assert(#gCalls == 1 and gCalls[1].err == nil, osName)
		local _, cb2 = recorder()
		g.bridge.ensure(cb2, { auto_install = true })
		g.advance(0)
		assert(real.json.decode(g.processes[#g.processes].opts.stdin).install_dependencies == false, osName .. " second start never installs")
	end
	local bad = fixture({ context = "host" })
	local badCalls, badDone = recorder()
	bad.bridge.set_client("host", "host")
	bad.bridge.ensure(badDone, { auto_install = "yes" })
	bad.advance(0)
	oneError(badCalls, "invalid_request")
end)

test("a bootstrap failure names its cause and later requests report it", function()
	local f = fixture({ context = "host" })
	local calls, done = recorder()
	f.bridge.set_client("host", "host")
	f.bridge.ensure(done, { auto_install = true })
	f.probe()
	-- While the install runs, a request says so instead of "unavailable".
	local early, earlyDone = recorder()
	f.bridge.request("diagnostics", {}, earlyDone)
	f.raw(3, real.json.encode({ ok = false, error = { code = "companion_unavailable", message = "SECRET" } }), 1)
	assert(#early == 1 and early[1].err.code == "setup_required" and early[1].err.message:find("installing", 1, true))
	f.raw(2, real.json.encode({ ok = false, error = { code = "setup_required", message = "SECRET" },
		state = "dependency_wheel_unavailable", package = "frozenlist==1.8.0", python = "3.14" }), 1)
	assert(#calls == 1 and calls[1].err.code == "setup_required")
	assert(calls[1].err.message:find("Python 3.14 has no prebuilt wheel for frozenlist==1.8.0", 1, true), calls[1].err.message)
	assert(calls[1].err.message:find("3.12", 1, true) and not calls[1].err.message:find("SECRET", 1, true))
	local later, laterDone = recorder()
	f.bridge.request("diagnostics", {}, laterDone)
	f.raw(4, real.json.encode({ ok = false, error = { code = "companion_unavailable", message = "SECRET" } }), 1)
	assert(#later == 1 and later[1].err.message:find("frozenlist==1.8.0", 1, true), "request keeps the bootstrap cause")
	-- A later success clears it.
	local ok, okDone = recorder()
	f.bridge.ensure(okDone, { auto_install = true })
	f.advance(0)
	f.resolve(5, ready())
	local plain, plainDone = recorder()
	f.bridge.request("diagnostics", {}, plainDone)
	f.raw(6, real.json.encode({ ok = false, error = { code = "companion_unavailable", message = "SECRET" } }), 1)
	assert(plain[1].err.code == "companion_unavailable" and plain[1].err.message == "The local USAGE companion is unavailable.")
end)

test("failure states use fixed text and only a checked package pin", function()
	local f = fixture({ context = "host" })
	local first = true
	local function launched(value)
		local calls, done = recorder()
		f.bridge.ensure(done)
		if first then f.probe(); first = false end
		f.raw(#f.processes, real.json.encode(value), 1)
		return calls
	end
	f.bridge.set_client("host", "host")
	for state in ("dependency_consent_required dependency_install_failed dependency_network_failed dependency_hash_mismatch python_venv_unavailable python_311_required"):gmatch("%S+") do
		local calls = launched({ ok = false, error = { code = "setup_required", message = "SECRET" }, state = state })
		assert(calls[1].err.code == "setup_required" and calls[1].err.message ~= "USAGE setup is required.", state)
		assert(not calls[1].err.message:find("SECRET", 1, true))
	end
	local hostile = launched({ ok = false, error = { code = "setup_required", message = "x" },
		state = "dependency_wheel_unavailable", package = "x; rm -rf /", python = "3.14" })
	assert(not hostile[1].err.message:find("rm -rf", 1, true) and hostile[1].err.message:find("no prebuilt wheel", 1, true))
	local unknown = launched({ ok = false, error = { code = "setup_required", message = "x" }, state = "SECRET weird" })
	assert(unknown[1].err.message == "USAGE setup is required.")
end)

test("a collector poll that does not install keeps the failed install's cause", function()
	local f = fixture({ context = "host" })
	local calls, done = recorder()
	f.bridge.set_client("host", "host")
	f.bridge.ensure(done, { auto_install = true })
	f.probe()
	f.raw(2, real.json.encode({ ok = false, error = { code = "setup_required", message = "SECRET" },
		state = "dependency_network_failed" }), 1)
	local network = calls[1].err.message
	assert(calls[1].err.code == "setup_required" and network ~= "USAGE setup is required.")
	-- The next collector tick checks without installing; the service answers consent required.
	local poll, pollDone = recorder()
	f.bridge.ensure(pollDone, { auto_install = true })
	f.advance(0)
	assert(real.json.decode(f.processes[#f.processes].opts.stdin).install_dependencies == false)
	f.raw(#f.processes, real.json.encode({ ok = false, error = { code = "setup_required", message = "SECRET" },
		state = "dependency_consent_required" }), 1)
	assert(#poll == 1 and poll[1].err.message == network, "the poll must keep the install failure: " .. tostring(poll[1].err.message))
	local later, laterDone = recorder()
	f.bridge.request("diagnostics", {}, laterDone)
	f.raw(#f.processes, real.json.encode({ ok = false, error = { code = "companion_unavailable", message = "SECRET" } }), 1)
	assert(later[1].err.message == network, "later requests keep it too")
	-- An explicit Setup attempt replaces it.
	local setup, setupDone = recorder()
	f.bridge.ensure(setupDone, { install_dependencies = true })
	f.advance(0)
	f.raw(#f.processes, real.json.encode({ ok = false, error = { code = "setup_required", message = "SECRET" },
		state = "dependency_hash_mismatch" }), 1)
	assert(setup[1].err.message ~= network, "a new attempt replaces the cause")
end)

return "PASS " .. tostring(tests) .. " companion asynchronous boundary fixtures"
