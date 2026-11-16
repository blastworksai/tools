--!strict
-- Component integration only. This deliberately does NOT impersonate the ORCH
-- controller or claim that a fixture-owned surface proves SPAWN origin authorization.
local native, environment = tern, getfenv()
local config = native.json.decode(native.fs.read(native.plugin.dir .. "/report.json"))
local metrics = { helper_processes = 0, codec_hashed_bytes = 0, codec_hash_calls = 0, bridge_events = 0, kv_writes = 0 }
local runtime = table.clone(native)
runtime.process = table.clone(native.process)
runtime.process.run = function(argv, options, callback)
	metrics.helper_processes += 1
	return native.process.run(argv, options, callback)
end
local modules = {}
local function load(name, base)
	name = (base or "") .. name:gsub("^%./", "")
	if modules[name] then return modules[name] end
	local chunk = assert(loadstring(native.fs.read(native.plugin.dir .. "/" .. name .. ".luau"), name))
	local dir = name:match("^(.*/)")
	setfenv(chunk, setmetatable({ tern = runtime, require = function(n) return load(n, dir) end }, { __index = environment }))
	local value = chunk(); modules[name] = value
	if type(value) == "table" and type(value.sha256) == "function" then
		local original = value.sha256
		value.sha256 = function(bytes)
			metrics.codec_hashed_bytes += #bytes; metrics.codec_hash_calls += 1
			return original(bytes)
		end
	end
	return value
end
local modern = pcall(native.fs.read, native.plugin.dir .. "/orch/wire/codec.luau")
local codec = load(if modern then "orch/wire/codec" else "orch/transport")
local adapter = load("spawn/mailbox_adapter")
local binding = { logical_session_id = "native-report-session", worker_id = "native-worker", worker_generation = 1,
	launch_request_id = "native-launch", work_id = "native-work", enrolment_token = "native_enrolment_aaaaaaaa", mailbox_handle = "native-report" }
local target = { root = config.root, helper = native.plugin.dir .. "/spawn/mailbox_target.sh", producer_helper = native.plugin.dir .. "/spawn/mailbox_worker.sh",
	worker_identity = config.identity, os = "linux", shell = "/bin/sh", kind = "posix", backend = "local-terminal", host_os = "linux", host_shell = "/bin/sh" }
local state, cx, serial, started, assembly, pool
local function write(key, value)
	native.kv.set(key, value); metrics.kv_writes += 1
end
local function finish(ok, problem)
	state.phase = if ok then "complete" else "failed"
	state.problem = problem
	native.fs.write(native.plugin.data .. "/report-result.json", native.json.encode({ done = true, ok = ok, error = problem, metrics = metrics,
		proof = "real native report transport component; staged product authorization and ORCH dispatch are NOT exercised" }))
	cx:render()
end
local function guarded(fn)
	return function(...)
		local ok, problem = pcall(fn, ...)
		if not ok then finish(false, tostring(problem)) end
	end
end
local function producer(mode, input, after)
	runtime.process.run({ "sh", target.producer_helper, config.root, binding.mailbox_handle, binding.enrolment_token, mode, "", "1", "2" },
		{ stdin = input or "", timeout_ms = 30000 }, guarded(function(result)
			assert(result.status == 0 and not result.timed_out, "producer " .. mode .. ": " .. result.stderr)
			after(result)
		end))
end
local function execute(mode, path, bytes, selector, after)
	serial += 1
	adapter.execute({ id = "component-" .. serial, mode = mode, path = path, bytes = bytes, target = target, handle = binding.mailbox_handle,
		binding = binding, request = { selector = selector }, report_floor = 0, reply_floor = 0 }, guarded(after))
end
local function request(index)
	state.phase = "request"
	state.selector = { stream = "report", slot = 1, part = if index then "chunk" else "manifest", index = index }
	state.serial += 1
	state.page = nil
	cx:render()
end
local function acknowledge(completed)
	local report = assert(codec.decode_report(completed.bytes, binding))
	local receipt = { seq = report.seq, event_id = report.event_id, event_sha256 = codec.sha256(completed.bytes), committed_revision = 1 }
	local chain = assert(codec.receipt_chain(binding.mailbox_handle))
	receipt.receipt_chain_sha256 = assert(codec.receipt_chain(binding.mailbox_handle, chain, receipt))
	-- This proves ONLY the component's durability ordering, not ORCH's dispatch path.
	write("component-cursor", receipt)
	assert(native.kv.get("component-cursor").seq == 1, "cursor did not persist before ACK")
	local ack = table.clone(receipt)
	ack.version = 1; ack.disposition = "accepted"
	for _, key in { "logical_session_id", "worker_id", "worker_generation", "launch_request_id", "work_id" } do ack[key] = binding[key] end
	local bytes = native.json.encode(ack)
	local expected = table.clone(binding)
	for key, value in receipt do expected[key] = value end
	assert(codec.decode_ack(bytes, expected))
	execute("publish", "acks/1.json", bytes, nil, function(result)
		assert(result.status == "published", "ACK not published: " .. tostring(result.status))
		metrics.report_to_ack_ms = native.now() - started
		producer("receipts", "", function()
			local journal = native.json.decode(native.fs.read(config.root .. "/" .. binding.mailbox_handle .. "/producer/journal.json"))
			assert(#journal.pending == 0, "producer did not consume ACK")
			finish(true)
		end)
	end)
end
local function receive(page)
	local decoded, why = codec.decode_page(page, state.selector)
	assert(decoded, why and why.code)
	local object = assert(codec.decode_object(decoded.bytes))
	if object.type == "manifest" then
		metrics.logical_report_bytes = object.message_bytes; metrics.chunks = object.count
		if modern then
			assembly = assert(codec.assembly_start(decoded.bytes, codec.sha256(decoded.bytes), binding))
			write("component-assembly", assembly)
		else
			pool = codec.new_reassembler()
			assert(codec.begin_assembly(pool, decoded.bytes, binding, codec.sha256(decoded.bytes)))
		end
		request(1)
	else
		local value, problem
		if modern then
			assembly = native.kv.get("component-assembly")
			value, problem = codec.assembly_push(assembly, decoded.bytes, codec.sha256(decoded.bytes), binding)
			if value then write("component-assembly", assembly) end
		else value, problem = codec.push_chunk(pool, decoded.bytes, binding, codec.sha256(decoded.bytes)) end
		assert(value, problem and problem.code)
		if value.complete then acknowledge(value) else request(object.index + 1) end
	end
end
pcall(native.fs.mkdir, native.plugin.data)
native.block.define("reports", {
	init = function(context)
		cx = context; serial = 0
		state = { phase = "starting", serial = 0 }
		native.timer(1, guarded(function()
			local provision = { version = 1, handle = binding.mailbox_handle, binding_digest = codec.sha256(native.json.encode(binding)), binding = binding }
			execute("provision", "provision.json", native.json.encode(provision), nil, function(result)
				assert(result.status == "provisioned", "provision failed " .. tostring(result.status))
				producer("init", "", function()
					local refs = native.json.array()
					for i = 1, 24 do table.insert(refs, tostring(i) .. ":" .. string.rep("x", 450) .. "é") end
					started = native.now()
					producer("report", native.json.encode({ kind = "BLOCKED", payload = { reason = "Native report measurement", evidence = refs } }), function() request(nil) end)
				end)
			end)
		end))
		return state
	end,
	view = function(value)
		local node = native.ui.text(native.json.encode(value))
		node.p = node.p or {}; node.p.role = "report-component"
		return { main = native.ui.col({ native.ui.text("Report transport component (not managed workflow)"), node }) }
	end,
	event = function(_, event)
		if event.ev ~= "action" then return end
		metrics.bridge_events += 1
		guarded(function()
			local input = native.json.decode(event.value)
			assert(input.serial == state.serial, "stale native surface event")
			if event.act == "read" and state.phase == "request" then
				state.phase = "reading"
				local selector = state.selector
				local path = "reports/1/" .. (if selector.part == "manifest" then "manifest.json" else "chunk-" .. selector.index .. ".json")
				execute("read", path, nil, selector, function(result)
					assert(result.status == "read", "read failed " .. tostring(result.status))
					state.page = native.json.encode(result.payload); state.phase = "page"; cx:render()
				end)
			elseif event.act == "receive" and state.phase == "page" then
				assert(input.page == state.page, "native surface page changed")
				state.phase = "assembling"; receive(input.page)
			else error("unexpected native bridge phase") end
		end)()
	end,
})
