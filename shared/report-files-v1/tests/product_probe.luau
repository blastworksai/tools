--!strict
-- Test-package loader. Product source bytes remain unchanged. By default effects
-- and callbacks are forwarded; optional exact-event/carrier faults never fake results.
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
	-- Observation persistence must not abort a product callback. Rearm before
	-- writing so an independent trace-flush budget failure retains later capture.
	native.timer(250, flush_later)
	if dirty then flush() end
end
native.timer(250, flush_later)
local function record(kind, data)
	assert(#trace.events < 10000, "product probe observation bound reached")
	table.insert(trace.events, { kind = kind, data = data, at_ms = native.now(), boot = trace.boot })
	dirty = true
end
-- Opt-in assignment diagnostics retain only correlation/fence facts, never task
-- bodies or credentials. Original callbacks and reducer results pass unchanged.
local function assignment_record(kind, data)
	if not config.assignment_trace then return end
	trace.assignment_count = (trace.assignment_count or 0) + 1
	assert(trace.assignment_count <= 64, "assignment diagnostic observation bound reached")
	record("assignment_" .. kind, data)
end
local runtime = table.clone(native)
-- A private pre-effect crash boundary: never invoke the selected native edit and
-- never settle its callback. No successful write/result is synthesized.
if realm == "window" and (config.docs_edit_hold_path or config.assignment_trace or config.toast_trace) then
	local contexts, held = setmetatable({}, { __mode = "kv" }), {}
	local wrap_context
	wrap_context = function(real)
		if real == nil then return nil end
		if contexts[real] then return contexts[real] end
		local proxy, docs = {}, {}
		contexts[real] = proxy
		setmetatable(docs, { __index = function(_, name)
			local method = real.docs[name]
			return function(_, ...)
				local args = table.pack(...)
				if name == "edit" and config.docs_edit_hold_path then
					local control = native.json.decode(native.fs.read(config.docs_edit_hold_path, 8192))
					if control.enabled == true and args[1] == control.path and type(control.marker) == "string"
						and type(args[2]) == "table" and type(args[2].insert) == "string"
						and args[2].insert:find(control.marker, 1, true) then
						assert(type(control.id) == "string" and #control.id > 0, "missing private Docs fault id")
						local bytes = native.json.encode({ path = args[1], edit = args[2] })
						local item = held[control.id]
						if not item then
							item = { path = args[1], edit = args[2], bytes = bytes, count = 0, boot = trace.boot,
								window_key = real:window_key(), session = real.sessions:current(), host = real.hosts:current(),
								disposition = "suppressed before native Docs edit; callback remains unsettled" }
							held[control.id] = item
						elseif item.bytes ~= bytes then item.conflict = true end
						item.count += 1
						native.fs.write(native.plugin.data .. "/product-held-docs-window.json", native.json.encode(held))
						return { next = function(_self, _callback) return nil end }
					end
				end
				local pending = method(real.docs, table.unpack(args, 1, args.n))
				return { next = function(_self, callback)
					return pending:next(function(value, failure, fresh)
						return callback(value, failure, wrap_context(fresh))
					end)
				end }
			end
		end })
		setmetatable(proxy, { __index = function(_, key)
			if key == "docs" then return docs end
			if key == "toast" and config.toast_trace then
				return function(_self, severity, title, message)
					local result = real:toast(severity, title, message)
					record("native_toast", { severity = severity, title = title, message = message,
						window_key = real:window_key() })
					return result
				end
			end
			if key == "prompt" and config.assignment_trace then
				return function(_self, options)
					local label = options.placeholder or ""
					local tracked = label:find("Explicit assignment", 1, true) == 1
						or label:find("Declared files", 1, true) == 1
						or label:find("Checks (one per line", 1, true) == 1
						or label:find("Base ref", 1, true) == 1
					local pending = real:prompt(options)
					return { next = function(_pending, callback)
						return pending:next(function(text, failure, fresh)
							if tracked then assignment_record("prompt", { label = label, text_present = text ~= nil,
								error_present = failure ~= nil, fresh_context = fresh ~= nil }) end
							return callback(text, failure, wrap_context(fresh))
						end)
					end }
				end
			end
			local value = real[key]
			if type(value) == "function" then return function(_self, ...) return value(real, ...) end end
			return value
		end })
		return proxy
	end
	runtime.timer = function(delay, callback)
		return native.timer(delay, function(cx, ...) return callback(wrap_context(cx), ...) end)
	end
	runtime.command = function(definition)
		local copied, run = table.clone(definition), definition.run
		copied.run = function(cx, ...) return run(wrap_context(cx), ...) end
		return native.command(copied)
	end
	if config.assignment_trace or config.toast_trace then
		runtime.on = function(name, callback)
			if name == "window_start" then
				return native.on(name, function(cx) return callback(wrap_context(cx)) end)
			end
			return native.on(name, function(ev, cx) return callback(ev, wrap_context(cx)) end)
		end
	end
end
if config.recovery_trace then
	runtime.fs = table.clone(native.fs)
	local function journal(path)
		return type(path) == "string" and (path:sub(1, 16) == "window-observer/"
			or path:sub(1, #native.plugin.data + 17) == native.plugin.data .. "/window-observer/")
	end
	runtime.fs.write = function(path, bytes, ...)
		local result = native.fs.write(path, bytes, ...)
		if journal(path) then record("journal_write", { path = path, bytes = bytes }) end
		return result
	end
	runtime.fs.read = function(path, ...)
		local bytes = native.fs.read(path, ...)
		if journal(path) then record("journal_read", { path = path, bytes = bytes }) end
		return bytes
	end
end
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
-- Explicitly armed, bounded PRIVATE full-commit evidence for close-phase tests.
-- This observes successful native writes; it never substitutes a stored value.
local authority_capture
local function capture_authority(value)
	if not config.authority_capture_path then return end
	local control = native.json.decode(native.fs.read(config.authority_capture_path, 8192))
	if control.enabled ~= true then return end
	assert(type(control.id) == "string" and #control.id <= 64 and control.id:match("^[A-Za-z0-9_-]+$")
		and type(control.logical_session_id) == "string", "invalid private authority capture")
	local base = native.plugin.data .. "/product-authority-" .. control.id
	if not authority_capture or authority_capture.id ~= control.id then
		local exists, bytes = pcall(native.fs.read, base .. "-index.json", 65536)
		authority_capture = if exists then native.json.decode(bytes)
			else { schema = 1, id = control.id, logical_session_id = control.logical_session_id,
				limit = 64, entries = native.json.array(), truncated = false }
		assert(authority_capture.id == control.id and authority_capture.limit == 64
			and type(authority_capture.entries) == "table" and #authority_capture.entries <= 64, "invalid retained private capture index")
	end
	assert(authority_capture.logical_session_id == control.logical_session_id, "capture identity changed under the same arm")
	if #authority_capture.entries >= authority_capture.limit then
		authority_capture.truncated = true
	else
		local index = #authority_capture.entries + 1
		local path = base .. "-" .. tostring(index) .. ".json"
		native.fs.write(path, native.json.encode(value))
		local session = value.sessions and value.sessions[control.logical_session_id]
		table.insert(authority_capture.entries, { index = index, path = path, revision = value.revision,
			authority_namespace = value.authority_namespace, at_ms = native.now(), boot = trace.boot,
			phase = if session then session.phase else "absent",
			peer_closed = if session and session.close then session.close.peer_closed else nil })
	end
	native.fs.write(base .. "-index.json", native.json.encode(authority_capture))
end
runtime.kv = table.clone(native.kv)
runtime.kv.set = function(key, value)
	local result = native.kv.set(key, value)
	trace.metrics.kv_writes += 1
	dirty = true
	if config.recovery_trace and value == nil then record("legacy_kv_delete", { key = key }) end
	if value == nil then return result end
	if key == "authority_state" then
		capture_authority(value)
		local workers = native.json.array()
		for _, worker in (value.dispatch and value.dispatch.workers) or {} do
			local observation = { id = worker.worker_id, handle = worker.mailbox_handle, accepted_seq = worker.accepted_seq,
				assembly = worker.assembly, phase = worker.phase }
			if config.recovery_trace then
				observation.coordinator_owner_id = worker.coordinator_owner_id
				observation.coordinator_generation = worker.coordinator_generation
				observation.stopped = if worker.stopped then worker.stopped.observation else nil
				local workflow = worker.workflow or {}
				observation.native = workflow.native
				observation.last_poll = workflow.last_poll
				observation.due_poll = workflow.due_poll
			end
			table.insert(workers, observation)
		end
		local committed = { revision = value.revision, workers = workers }
		if config.recovery_trace then
			local dispatch = value.dispatch or {}
			committed.sessions, committed.rollovers, committed.actions = native.json.array(), native.json.array(), native.json.array()
			for id, session in value.sessions or {} do
				local cursor = (dispatch.command_cursors or {})[id] or {}
				local owner = session.orchestrator
				table.insert(committed.sessions, { id = id, admission_seq = session.admission_seq, command_seq = cursor.seq,
					next_request_serial = session.next_request_serial or cursor.next_request_serial,
					phase = session.phase, close = session.close,
					orchestrator = if owner then { owner_id = owner.owner_id, generation = owner.generation,
						phase = owner.phase, managed_worker_id = owner.managed_worker_id } else nil })
			end
			for id, rollover in dispatch.rollovers or {} do
				table.insert(committed.rollovers, { id = id, kind = rollover.kind, phase = rollover.phase,
					revision = rollover.revision, at_ms = rollover.at_ms,
					predecessor_worker_id = rollover.predecessor_worker_id, successor_worker_id = rollover.successor_worker_id,
					prepare_count = rollover.prepare_count, prepared = rollover.prepared ~= nil,
					hold = if type(rollover.hold) == "table" then { code = rollover.hold.code } else nil })
			end
			for id, action in dispatch.actions or {} do
				table.insert(committed.actions, { id = id, op = if action.request then action.request.op else nil,
					phase = action.phase, request_serial = action.request_serial, worker_id = action.worker_id,
					response_status = if action.response then action.response.status else nil,
					response_resource = if action.response and action.response.payload then action.response.payload.resource else nil })
			end
		end
		record("orch_commit", committed)
	elseif key == "dispatch-v1" then
		record("spawn_commit", { revision = value.revision })
	end
	return result
end
local held_events = {}
local held_path = native.plugin.data .. "/product-held-" .. realm .. ".json"
if config.held_events_path then
	local exists, bytes = pcall(native.fs.read, held_path, 67108864)
	if exists then held_events = native.json.decode(bytes) end
end
local function save_held()
	local count = 0
	for _ in held_events do count += 1 end
	assert(count <= 64, "private event-loss evidence bound reached")
	native.fs.write(held_path, native.json.encode(held_events))
end
local function hold_control()
	local control = native.json.decode(native.fs.read(config.held_events_path, 32768))
	assert(type(control.holds) == "table" and #control.holds <= 4, "invalid private event-loss control")
	assert(control.releases == nil or (type(control.releases) == "table" and #control.releases <= 64),
		"invalid private carrier releases")
	assert(control.retained == nil or (type(control.retained) == "table" and #control.retained <= 64),
		"invalid private retained carriers")
	for _, id in control.retained or {} do
		assert(type(id) == "string" and #id > 0 and #id <= 64, "invalid private retained carrier id")
	end
	return control
end
local function scalar_match(value, fields)
	if fields == nil then return true end
	assert(type(fields) == "table", "invalid private event field selector")
	if type(value) ~= "table" then return false end
	local count = 0
	for key, expected in fields do
		count += 1
		assert(count <= 8 and type(key) == "string"
			and table.find({ "string", "number", "boolean" }, type(expected)), "invalid private event field")
		if value[key] ~= expected then return false end
	end
	return true
end
local function hold_event(kind, input, cx)
	if not config.held_events_path then return false end
	local control = hold_control()
	for _, hold in ipairs(control.holds) do
		assert(type(hold.id) == "string" and #hold.id > 0 and #hold.id <= 64
			and type(hold.block) == "string" and type(hold.act) == "string", "invalid private event-loss selector")
		if kind ~= hold.block or input.ev ~= "action" or input.act ~= hold.act then continue end
		if hold.match ~= nil or hold.request ~= nil or hold.exclude_match ~= nil or hold.authority_event ~= nil then
			local decoded, value = pcall(native.json.decode, input.value)
			if not decoded or not scalar_match(value, hold.match) then continue end
			if hold.exclude_match ~= nil and scalar_match(value, hold.exclude_match) then continue end
			if hold.authority_event ~= nil and not scalar_match(type(value) == "table" and value.event or nil, hold.authority_event) then continue end
			if hold.request ~= nil then
				local parsed, request = pcall(native.json.decode, if type(value) == "table" then value.request_json else nil)
				if not parsed or not scalar_match(request, hold.request) then continue end
			end
		end
		local bytes = native.json.encode(input)
		local observed = held_events[hold.id]
		if not observed then
			observed = { kind = "block_event", block = kind, pane = cx.pane, input = input, bytes = bytes, count = 0,
				first_at_ms = native.now(), boot = trace.boot, disposition = "suppressed before original native handler" }
			held_events[hold.id] = observed
			record("held_native_event", { id = hold.id, block = kind, pane = cx.pane, input = input })
		elseif observed.bytes ~= bytes or observed.pane ~= cx.pane then
			observed.conflict = true
		end
		observed.count += 1
		observed.last_at_ms = native.now()
		save_held()
		return true
	end
	return false
end
-- Current pane-free hosts consume Channel.receive directly. Suppress only its
-- validated return value: the real producer file and Channel's immutable receipt
-- remain untouched, with no ACK and no product handler call. Legacy dispatch
-- selectors are logical aliases here, NOT evidence of a native block event.
-- Control: holds=[{id,block="carrier"|"dispatch",act,request?,match?,carrier?}],
-- releases=[id], retained=[id] (each at most 64). act is the binding action or
-- carrier route; request selects the decoded direct request or request_json.
-- Legacy act="request" selects a direct request whose op equals its binding act.
-- Removing a hold releases unless retained names its already captured exact raw
-- bytes. Explicit releases override retained; retained never selects new input.
-- Release returns the ORIGINAL Channel object through its ordinary receive path;
-- original deadlines and product retry/ACK semantics are never extended/replaced.
-- Evidence survives reload, but this probe exposes no replay/injection API.
-- After native drain, a separately authorized owned-filesystem rollback may
-- restore ONLY the exact captured producer bytes at an empty original slot,
-- with the owned host stopped and no conflicting ACK/current obligation.
-- Channel must then receive/validate that file normally; evidence is never
-- passed to a handler or substituted for Channel's original receipt object.
-- Up to 64 distinct, actually forwarded SPAWN status frames are retained across
-- reload for explicit old-input storage faults. This is observation only: no
-- request is created and neither status handling nor ACK is performed here.
local function instrument_channel(channel)
	local open = channel.open
	channel.open = function(options)
		local copied, fs = table.clone(options), table.clone(options.fs)
		local reads
		fs.read = function(path, ...)
			local bytes = options.fs.read(path, ...)
			if reads then reads[path] = bytes end
			return bytes
		end
		copied.fs = fs
		local endpoint, failure = open(copied)
		if not endpoint then return endpoint, failure end
		local sources, source_order = {}, {}
		local observed_status, status_count = {}, 0
		for _, event in trace.events do
			if event.kind == "carrier_receive" and event.data.act == "status" and not observed_status[event.data.bytes] then
				observed_status[event.data.bytes] = true
				status_count += 1
			end
		end
		local function decoded(bytes)
			if type(bytes) ~= "string" then return nil end
			local ok, value = pcall(native.json.decode, bytes)
			return if ok and type(value) == "table" then value else nil
		end
		local function facts(message)
			local ep, lane, act, target = message.binding:match("^([^:]+):([^:]+):([^:]+):([^:]+)$")
			if not ep then ep, lane, act = message.binding:match("^([^:]+):([^:]+):([^:]+)$") end
			local key = if ep then ep .. ":" .. lane else message.binding
			local body = decoded(message.body)
			local request = if body and body.request_json then decoded(body.request_json) else body
			local origin = if request then request.setup_origin or request.origin_binding
				or (request.control_origin and request.control_origin.binding) or request.origin else nil
			local source = if body and body.host_pane_id then body elseif origin then origin else sources[key]
			if source and source.host_pane_id then
				if not sources[key] then
					if #source_order >= 128 then sources[table.remove(source_order, 1)] = nil end
					table.insert(source_order, key)
				end
				sources[key] = source
			end
			return { peer = message.peer, recipient = message.recipient, route = message.route,
				binding = message.binding, incarnation = message.incarnation, id = message.id, slot = message.slot,
				act = act or message.route, relay_endpoint = ep, lane_id = lane, target_boot = target,
				host_pane_id = if source then source.host_pane_id else nil }, body, request, source
		end
		local carrier_seen, carrier_count = {}, 0
		local function observe_carrier(phase, message, problem)
			if not config.recovery_trace then return end
			local key = phase .. ":" .. tostring(message.incarnation or options.incarnation) .. ":" .. message.id
			if carrier_seen[key] then return end
			if carrier_count >= 2048 then trace.carrier_observation_truncated = true; dirty = true; return end
			carrier_seen[key] = true; carrier_count += 1
			local metadata = facts(message)
			local projection = if message.body:sub(1, 19) == "SPAWN_EXECUTION v2 " then decoded(message.body:sub(20)) else nil
			record("carrier_observation", { phase = phase, carrier = metadata, error = problem,
				body_bytes = #message.body, execution_kind = if projection then projection.kind else nil,
				execution_request_id = if projection and projection.request then projection.request.request_id else nil })
		end
		local send = endpoint.send
		endpoint.send = function(request)
			local receipt, err = send(request)
			if receipt then facts(request); observe_carrier("send", request) end
			return receipt, err
		end
		local receive, ack = endpoint.receive, endpoint.ack
		endpoint.receive = function(...)
			reads = {}
			local messages, err = receive(...)
			local observed_reads = reads
			reads = nil
			local control, forwarded = hold_control(), {}
			for _, message in ipairs(messages) do
				local metadata, body, request, source = facts(message)
				local parent = options.plugin_data:match("^(.*)/[^/]+$")
				local path = parent .. "/" .. message.peer .. string.format("/plugin-channel-v1/m-%03d.json", message.slot)
				local raw = observed_reads[path]
				-- Bytes are those read by Channel in this receive, not re-encoded
				-- JSON or a later filesystem observation with a different identity.
				assert(type(raw) == "string", "missing original carrier read")
				local selected
				for _, id in ipairs(control.retained or {}) do
					local item = held_events[id]
					if item and item.kind == "carrier_receive" and item.bytes == raw
						and not table.find(control.releases or {}, id) then
						selected = { id = id }; break
					end
				end
				for _, hold in ipairs(control.holds) do
					if selected then break end
					if hold.block ~= "carrier" and not (options.plugin_id == "spawn" and hold.block == "dispatch") then continue end
					assert(type(hold.id) == "string" and #hold.id > 0 and #hold.id <= 64
						and type(hold.act) == "string", "invalid private carrier selector")
					if table.find(control.releases or {}, hold.id) then continue end
					local direct_request = hold.act == "request" and message.route == "spawn.request"
						and body ~= nil and body.request_json == nil and body.op == metadata.act
					if hold.act ~= metadata.act and hold.act ~= message.route and not direct_request then continue end
					if not scalar_match(metadata, hold.carrier) or not scalar_match(body, hold.match)
						or not scalar_match(request, hold.request) then continue end
					if hold.exclude_match and scalar_match(body, hold.exclude_match) then continue end
					if hold.authority_event and not scalar_match(if body then body.event else nil, hold.authority_event) then continue end
					selected = hold; break
				end
				if selected then
					local item = held_events[selected.id]
					if not item then
						item = { kind = "carrier_receive", selector_block = selected.block, act = metadata.act,
							carrier = metadata, source = source, pane = metadata.host_pane_id,
							frame = table.clone(message), body = message.body, bytes = raw, producer_bytes = raw,
							producer_path = path, count = 0, first_at_ms = native.now(), boot = trace.boot,
							disposition = "suppressed after carrier receive, before original host handling; no ACK",
							probe_replay_api = false,
							replay_limitation = "after native drain, replay requires separately authorized exact producer-file rollback; probe cannot inject receipts" }
						held_events[selected.id] = item
						record("held_carrier_receive", { id = selected.id, carrier = metadata })
					elseif item.kind ~= "carrier_receive" or item.bytes ~= raw then
						item.conflict = true
					end
					item.count += 1
					item.last_at_ms = native.now()
					save_held()
				else
					if options.plugin_id == "spawn" and message.route == "spawn.request" and metadata.act == "status"
						and body and body.op == "status" and body.request_json == nil and not observed_status[raw] then
						if status_count < 64 then
							observed_status[raw] = true
							status_count += 1
							record("carrier_receive", { kind = "carrier_receive", act = metadata.act,
								carrier = metadata, source = source, pane = metadata.host_pane_id,
								frame = table.clone(message), body = message.body, bytes = raw, producer_bytes = raw,
								producer_path = path, boot = trace.boot, forwarded_at_ms = native.now(),
								disposition = "original read-only status carrier forwarded; native handling and ACK unchanged",
								probe_replay_api = false })
						elseif not trace.carrier_status_truncated then
							trace.carrier_status_truncated = true
							dirty = true
						end
					end
					for id, item in held_events do
						if item.kind == "carrier_receive" and item.bytes == raw and not item.forwarded_at_ms then
							item.forwarded_at_ms, item.forwarded_boot = native.now(), trace.boot
							item.disposition = "original carrier object forwarded; native retry and ACK semantics preserved"
							record("released_carrier_receive", { id = id, carrier = metadata })
							save_held()
						end
					end
					table.insert(forwarded, message)
					observe_carrier("receive", message)
				end
			end
			return forwarded, err
		end
		endpoint.ack = function(message)
			local ok, err = ack(message)
			if ok then observe_carrier("ack", message) end
			if ok then
				for id, item in held_events do
					local frame = item.frame
					if item.kind == "carrier_receive" and frame.peer == message.peer and frame.id == message.id
						and frame.incarnation == message.incarnation and frame.binding == message.binding
						and frame.route == message.route and frame.slot == message.slot and frame.body == message.body
						and not item.acknowledged_at_ms then
						item.acknowledged_at_ms = native.now()
						item.disposition = "original host acknowledged original carrier frame"
						record("acknowledged_carrier_receive", { id = id, carrier = item.carrier })
						save_held()
					end
				end
			end
			return ok, err
		end
		return endpoint, failure
	end
end
if native.block then
runtime.block = table.clone(native.block)
runtime.block.define = function(kind, definition)
	if definition.event then
		local event = definition.event
		definition.event = function(state, input, cx)
			local assignment_input
			local recovery_input
			if config.assignment_trace and kind == "orchestrator" and input.ev == "action" then
				local control = if input.act == "control" and type(state.actions) == "table" then state.actions[input.value] else nil
				if control and control.request and control.request.command == "queue" then
					assignment_record("intent", { pane = cx.pane, control_token = input.value, expected_revision = control.expected_revision,
						namespace_matches = control.authority_namespace == state.authority_namespace,
						record_id = control.request.record_id, record_revision = control.request.record_revision,
						catalog_revision = control.request.catalog_revision })
				elseif input.act == "dispatch-operator-command" then
					local ok, decoded = pcall(native.json.decode, input.value)
					if ok and type(decoded) == "table" and decoded.command == "queue" then
						assignment_input = decoded
						assignment_record("submission", { pane = cx.pane, record_id = decoded.record_id, request_id = decoded.request_id,
							expected_revision = decoded.expected_revision, command_seq = decoded.command_seq,
							namespace_matches = decoded.authority_namespace == state.authority_namespace,
							origin_pane_matches = decoded.origin and decoded.origin.host_pane_id == tostring(cx.pane),
							origin_alias_matches = decoded.origin and decoded.origin.alias_nonce == state.alias_nonce })
					end
				end
			end
			if config.recovery_trace and input.ev == "action" then
				local token = if input.act == "control" and type(input.value) == "string" then input.value else nil
				local control = if token and type(state.actions) == "table" then state.actions[token] else nil
				local decoded
				if kind == "orchestrator" and type(input.value) == "string"
					and (input.act == "dispatch-command" or input.act == "dispatch-operator-command"
						or input.act == "authority-command" or input.act == "authority-operator-command"
						or input.act == "ruling-command" or input.act == "ruling-clear") then
					local ok, value = pcall(native.json.decode, input.value)
					if ok and type(value) == "table" then decoded = value.event or value end
				end
				local command = if decoded then decoded.command or decoded.kind elseif control and control.request then control.request.command else nil
				recovery_input = { block = kind, pane = cx.pane, act = input.act, id = input.id,
					control_token = token,
					known_control = if token and type(state.actions) == "table" then control ~= nil else nil,
					control_kind = if control then control.kind else nil,
					expected_revision = if decoded then decoded.expected_revision elseif control then control.expected_revision else nil,
					request_id = if decoded then decoded.request_id else nil,
					source_nonce = if decoded then decoded.source_nonce else nil,
					gate_id = if decoded then decoded.gate_id else nil,
					ruling_response = if input.act == "ruling-clear" and state.ruling_result then {
						request_id = state.ruling_result.request_id, ok = state.ruling_result.ok, code = state.ruling_result.code,
					} else nil,
					command_seq = if decoded then decoded.command_seq else nil,
					current_revision = state.authority_revision, command = command, trace_index = #trace.events + 1 }
				record("native_input", recovery_input)
			end
			if kind == "dispatch" and input.ev == "action" then
				trace.metrics.bridge_events += 1
				record("bridge_event", { pane = cx.pane, act = input.act, value = input.value, input = input })
			end
			if hold_event(kind, input, cx) then return nil end
			local result = event(state, input, cx)
			if config.recovery_trace and kind == "orchestrator" and input.act == "spawn_relay" then
				record("relay_input_outcome", { pane = cx.pane,
					relay = if state.spawn_relay then native.json.decode(native.json.encode(state.spawn_relay)) else nil,
					notice = state.relay_notice })
			end
			if recovery_input and kind == "orchestrator"
				and (input.act == "control" or input.act == "dispatch-operator-command"
					or input.act == "authority-command" or input.act == "authority-operator-command") then
				record("native_owner_outcome", { input_trace_index = recovery_input.trace_index,
					pane = cx.pane, act = input.act, request_id = recovery_input.request_id,
					before_revision = recovery_input.current_revision, after_revision = state.authority_revision,
					command_result = state.dispatch_command_result, refusal = state.refusal,
					notice = state.notice, operator_intent = state.operator_intent })
			end
			if config.migration_trace and kind == "dispatch" and input.ev == "action"
				and type(state.error) == "string" then
				record("native_bridge_refusal", { pane = cx.pane, act = input.act,
					value = input.value, error = state.error })
			end
			if assignment_input then
				local response = state.dispatch_command_result
				assignment_record("host_result", { request_id = assignment_input.request_id,
					response_request_id = if response then response.request_id else nil,
					ok = if response then response.ok else nil, code = if response then response.code else nil })
			end
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
	if name == "channel/channel" and realm == "host" and config.held_events_path then instrument_channel(value) end
	if name == "state" and realm == "host" and config.assignment_trace then
		local apply = value.apply
		value.apply = function(registry, input, ...)
			local tracked = type(input) == "table" and input.kind == "dispatch" and input.command == "queue"
			if tracked then assignment_record("reducer_input", { request_id = input.request_id,
				expected_revision = input.expected_revision, current_revision = registry.revision,
				namespace_matches = input.authority_namespace == registry.authority_namespace }) end
			local candidate, response = apply(registry, input, ...)
			if tracked then assignment_record("reducer_result", { request_id = input.request_id,
				candidate_present = candidate ~= nil, ok = if response then response.ok else nil,
				code = if response then response.code else nil }) end
			return candidate, response
		end
	end
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
