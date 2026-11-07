--!strict
-- Test-package loader. Product source bytes remain unchanged; effects, native
-- callbacks and authority decisions are forwarded, never replaced with fixtures.
return { run = function(entry, realm)
local native, environment = tern, getfenv()
local config = native.json.decode(native.fs.read(native.plugin.dir .. "/product-probe.json"))
local trace_path = native.plugin.data .. (if realm == "window" then "/product-window-trace.json" else "/product-trace.json")
pcall(native.fs.mkdir, native.plugin.data)
local prior_ok, prior = pcall(native.fs.read, trace_path)
local trace = if prior_ok then native.json.decode(prior) else { events = native.json.array(), boot = 0 }
trace.boot += 1
trace.metrics = trace.metrics or { helper_processes = 0, codec_hashed_bytes = 0, codec_hash_calls = 0, bridge_events = 0, kv_writes = 0 }
trace.codec_modules = trace.codec_modules or {}
local dirty = false
local function flush()
	native.fs.write(trace_path, native.json.encode(trace))
	dirty = false
end
local function flush_later()
	if dirty then flush() end
	native.timer(250, flush_later)
end
native.timer(250, flush_later)
local function record(kind, data)
	assert(#trace.events < 10000, "product probe observation bound reached")
	table.insert(trace.events, { kind = kind, data = data, at_ms = native.now(), boot = trace.boot })
	flush()
end
local runtime = table.clone(native)
runtime.process = table.clone(native.process)
runtime.process.run = function(argv, ...)
	local helper
	for _, argument in argv do
		if argument:match("mailbox_target%.sh$") or argument:match("mailbox_worker%.sh$") then helper = argument; break end
	end
	local result = native.process.run(argv, ...)
	if helper then
		trace.metrics.helper_processes += 1
		record("helper_process", { argv = argv, helper = helper })
	end
	return result
end
runtime.kv = table.clone(native.kv)
runtime.kv.set = function(key, value)
	local result = native.kv.set(key, value)
	trace.metrics.kv_writes += 1
	dirty = true
	if key == "authority_state" then
		local workers = native.json.array()
		for _, worker in (value.dispatch and value.dispatch.workers) or {} do
			table.insert(workers, { id = worker.worker_id, handle = worker.mailbox_handle, accepted_seq = worker.accepted_seq,
				assembly = worker.assembly, phase = worker.phase })
		end
		record("orch_commit", { revision = value.revision, workers = workers })
	elseif key == "dispatch-v1" then
		record("spawn_commit", { revision = value.revision })
	end
	return result
end
if native.block then
runtime.block = table.clone(native.block)
runtime.block.define = function(kind, definition)
	if definition.event then
		local event = definition.event
		definition.event = function(state, input, cx)
			if kind == "dispatch" and input.ev == "action" then
				trace.metrics.bridge_events += 1
				record("bridge_event", { pane = cx.pane, act = input.act, value = input.value })
			end
			local result = event(state, input, cx)
			if kind == "dispatch" and input.ev == "action" and input.act == "spawn.authorize" then
				record("authorize_result", { pane = cx.pane, input = input.value, body = state.body })
			end
			return result
		end
	end
	return native.block.define(kind, definition)
end
end
local modules = {}
local function normalize(name)
	local parts = {}
	for part in name:gmatch("[^/]+") do
		if part == ".." then assert(#parts > 0, "module escapes package"); table.remove(parts)
		elseif part ~= "." then table.insert(parts, part) end
	end
	return table.concat(parts, "/")
end
local function load(name, base)
	name = normalize((base or "") .. name)
	if modules[name] ~= nil then return modules[name] end
	local chunk = assert(loadstring(native.fs.read(native.plugin.dir .. "/" .. name .. ".luau"), name))
	local directory = name:match("^(.*/)")
	setfenv(chunk, setmetatable({ tern = runtime, require = function(child) return load(child, directory) end }, { __index = environment }))
	local value = chunk()
	modules[name] = if value == nil then true else value
	if type(value) == "table" and type(value.sha256) == "function" then
		trace.codec_modules[name] = true
		local hash = value.sha256
		value.sha256 = function(bytes)
			trace.metrics.codec_hashed_bytes += #bytes
			trace.metrics.codec_hash_calls += 1
			dirty = true
			return hash(bytes)
		end
	end
	if name == "authority" and config.record and realm == "host" then
		local open = value.open
		value.open = function(...)
			local binding, why = open(...)
			if binding then
				local snapshot = assert(value.snapshot(binding))
				if #snapshot.records == 0 then
					assert(snapshot.config_revision == 0, "fixture refuses to replace existing configuration")
					local saved, failure = value.edit(binding, 0, "replace-records", { records = { config.record } })
					assert(saved, failure)
					record("configured_fixture_record", { binding = binding, id = config.record.id })
				end
			end
			return binding, why
		end
	elseif name == "mailbox_adapter" then
		local execute = value.execute
		value.execute = function(operation, callback)
			local observation = { id = operation.id, mode = operation.mode, path = operation.path,
				request_id = operation.request and operation.request.request_id, handle = operation.handle }
			if operation.mode == "publish" and operation.path and operation.path:match("^acks/") then
				local ack = native.json.decode(operation.bytes)
				local persisted = native.json.decode(native.fs.read(config.orch_kv)).authority_state
				local matched
				for _, worker in persisted.dispatch.workers do if worker.mailbox_handle == operation.handle then matched = worker end end
				observation.ack = ack
				observation.durable_revision = persisted.revision
				observation.durable_accepted_seq = matched and matched.accepted_seq
				observation.cursor_before_ack = matched ~= nil and matched.accepted_seq >= ack.seq and persisted.revision >= ack.committed_revision
			end
			record("adapter_execute", observation)
			return execute(operation, function(result)
				record("adapter_result", { id = operation.id, request_id = observation.request_id, status = result.status })
				return callback(result)
			end)
		end
	end
	return value
end
record(realm .. "_loaded", { plugin = native.plugin.id })
return load(entry)
end }
