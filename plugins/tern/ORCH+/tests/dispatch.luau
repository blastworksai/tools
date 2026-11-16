-- Run in a disposable Tern host callback. No native launch, filesystem mailbox or production KV.
local root, section = ...
local sections = { fixture = true, core = true, control_rebind = true, receipts = true, callbacks = true, oversize = true, retry = true,
	chain = true, late = true, reconcile_chain = true, refused_chain = true, ack = true, ack_uncertain = true, ack_terminal = true, stale_witness = true, scoped_poll = true,
	suspend = true, auto_reconcile = true, auto_reconcile_bounded = true, auto_reconcile_worker = true, sweep_rules = true, sweep_policy = true,
	auto_reconcile_all = true, capacity_resume = true, expired_authorization = true, slot_classes = true, duplicate_claim = true, stale_claim = true, slow_receipt = true,
	retirement_auth = true, retirement_finish = true, retirement_race = true, retirement_uncertain = true, retirement_restore = true, retirement_capability = true, retirement_codec = true, retirement_refused = true,
	rejected_read = true, finish = true, finish_capacity = true, command_retention = true, continuation = true, wake_separation = true, catalog_join = true, policy = true,
	rollover = true, rollover_launch_failure = true, rollover_token = true, rollover_stop_uncertain = true, rollover_reload = true, rollover_policy = true, rollover_context = true, rollover_context_handover = true, rollover_context_roundtrip = true,
	rollover_coordinator = true, rollover_coordinator_ambiguous = true, rollover_coordinator_reload = true, rollover_coordinator_restored = true, rollover_coordinator_policy = true, rollover_coordinator_successor_rejected = true,
	rollover_read_path = true, rollover_reload_continuation = true, recheck_report = true, enrol = true, projects = true, local_v5 = true, project_rollover = true,
	rollover_coordinator_self_release = true, publication_readback = true, accept_after_owner_recovery = true,
	quota_normalize = true, quota_assembly = true, quota_routing = true, quota_gate = true, quota_claim = true,
	quota_rollover = true, quota_coordinator_rollover = true, quota_ledger = true, quota_selector = true, quota_continuation = true, window_bookkeeping = true, intent_buttons = true,
	background_settlement = true, foreground_bootstrap = true, background_launch = true, background_adjacent = true, stale_intent = true,
	assembly_restore = true, assembly_capacity = true, poll_continuation = true,
	withdraw_fenced = true, policy_keys = true, loop_caps_rollover = true, loop_caps_retry = true, loop_caps_reports = true, loop_caps_landing_migration = true, loop_caps_landing_caps = true, loop_caps_landing_transport = true, loop_caps_landing_target_moved = true, worker_fields = true,
	current_retention = true, current_ack_holes = true, current_nonce = true, current_close = true, current_handover = true, consumed_scope = true,
	stale_result = true, stale_result_lost = true, stale_result_unrelated = true, stale_result_kind = true, stale_result_grant = true,
	stale_result_grant_change = true, held_withdrawal = true, capacity_withdrawal = true,
	project_observation = true, project_repository_guards = true, migration_start_guards = true, enrol_route_cancel = true,
	project_history_reuse = true, project_reserve = true, rollover_location = true, project_start_rollover = true,
	legacy_observation = true, legacy_worker_roles = true, current_observation = true, compaction_retry = true }
assert(section == nil or sections[section], "unknown dispatch test section: " .. tostring(section))
local runtime, environment = tern, getfenv()
-- Absence stays absent; explicit JSON null remains available to negative wire tests.
local function clone(v) return if v == nil then nil else runtime.json.decode(runtime.json.encode(v)) end
local function keyed_memory(value, marker)
	local memory = { value = clone(value), marker = clone(marker), writes = 0, marker_writes = 0, fail = false, keys = {} }
	function memory.get(key)
		return clone(if key == "authority_state" then memory.value
			elseif key == "authority_state_initialized" then memory.marker else memory.keys[key])
	end
	function memory.set(key, value)
		if memory.fail then error("injected persistence failure") end
		if key == "authority_state" then memory.value = clone(value); memory.writes += 1
		elseif key == "authority_state_initialized" then memory.marker = clone(value); memory.marker_writes += 1
		else memory.keys[key] = clone(value)
		end
	end
	return memory
end
local fake = table.clone(runtime)
-- Host carrier files are isolated from the native runner and its live plugins.
local channel_files, channel_dirs = {}, {}
fake.plugin = table.clone(runtime.plugin); fake.plugin.data = "/fixture/plugins/orchplus-dispatch"
local function carrier_path(path)
	return path == fake.plugin.data or path:sub(1, #fake.plugin.data + 1) == fake.plugin.data .. "/"
end
fake.fs = table.clone(runtime.fs)
fake.fs.exists = function(path)
	return if carrier_path(path) then channel_files[path] ~= nil or channel_dirs[path] == true else runtime.fs.exists(path)
end
fake.fs.mkdir = function(path)
	if carrier_path(path) then channel_dirs[path] = true else runtime.fs.mkdir(path) end
end
fake.fs.read = function(path, maximum)
	if not carrier_path(path) then return if maximum == nil then runtime.fs.read(path) else runtime.fs.read(path, maximum) end
	local bytes = assert(channel_files[path], "missing fixture carrier file")
	assert(type(maximum) == "number" and #bytes <= maximum, "carrier reads are bounded"); return bytes
end
fake.fs.write = function(path, bytes)
	if carrier_path(path) then channel_files[path] = bytes else runtime.fs.write(path, bytes) end
end
fake.fs.remove = function(path)
	if carrier_path(path) then channel_files[path] = nil; channel_dirs[path] = nil else runtime.fs.remove(path) end
end
fake.fs.list = function(path, ...)
	assert(not carrier_path(path), "carrier must not list directories")
	return runtime.fs.list(path, ...)
end
fake.pane = { list = function() return {
	{ pane = 11, program = "orchplus.orchestrator" }, { pane = 12, program = "orchplus.orchestrator" },
} end }
local definition, ui_value
local ui_memory = keyed_memory()
fake.kv = { get = ui_memory.get, set = function(key, value)
	ui_memory.set(key, value)
	if key == "authority_state" then ui_value = ui_memory.value end
end }
fake.block = { define = function(id, value) if id == "orchestrator" then definition = value end end }; fake.on = function() end
fake.timer = function() return { cancel = function() end } end
local modules = {}
-- `./x` resolves against the requiring module's directory, as Tern's require does (updater/ modules).
local function load(name, base)
	name = (base or "") .. name:gsub("^%./", "")
	if modules[name] then return modules[name] end
	local chunk = assert(loadstring(runtime.fs.read(root .. "/" .. name .. ".luau"), name))
	local dir = name:match("^(.*/)")
	setfenv(chunk, setmetatable({ tern = fake, require = function(n) return load(n, dir) end }, { __index = environment }))
	local value = chunk(); modules[name] = value; return value
end
local host, state, dispatch, codec, quota = load("host"), load("state"), load("dispatch"), load("wire/codec"), load("quota")
local protocol = load("dispatch_protocol")
local checks, serial = 0, 0
local function check(ok, why) assert(ok, why); checks += 1 end
local function must(value, diagnostic)
	assert(value, "fixture refusal: " .. runtime.json.encode(diagnostic))
	return value
end
local function next_id() serial += 1; return "fixture-" .. tostring(serial) end
local function catalog_setup(revision)
	return { schema = 1, state = "completed", config_revision = revision,
		readiness = { state = "not_run", config_revision = revision, summary = "Optional readiness exercise not run" } }
end
local function frame(request, status, payload, problem, category, authority_revision)
	local body = { schema = 2, op = request.op, request_id = request.request_id, action_id = request.action_id,
		authority_namespace = request.authority_namespace, logical_session_id = request.logical_session_id,
		admission_seq = request.admission_seq, request_serial = request.request_serial,
		spawn_namespace = "fixture-spawn", authority_revision = authority_revision or 0,
		origin_binding = clone(request.origin_binding), controller_generation = request.controller_generation,
		control_origin = clone(request.control_origin), close_id = request.close_id,
		category = category or (if status == "already_consumed" then "already_consumed"
			elseif status == "uncertain" or (status == "missing" and request.op == "status") then "unknown_effect" else "current_result"),
		status = status, payload = payload, error = problem }
	if request.setup_origin then body.setup_origin = clone(request.setup_origin); body.spawn_namespace = nil; body.authority_revision = nil end
	-- Keep framing separate from validation: negative cases deliberately submit malformed bodies.
	local bytes = runtime.json.encode(body)
	return "SPAWN_DISPATCH v2 " .. runtime.json.encode({ schema = 2, op = body.op, request_id = body.request_id,
		complete = true, body_bytes = #bytes, body_sha256 = codec.sha256(bytes), body_json = bytes })
end
local function empty_peer()
	local normal = { schema = 1, sessions = runtime.json.array(), workers = runtime.json.array() }
	local source = { version = 2, namespace = "fixture-spawn", revision = 0, sessions = {}, requests = {} }
	return { source_schema = 2, source_revision = 0, source_namespace = "fixture-spawn",
		source_sha256 = codec.sha256(codec.dispatch_source_bytes(source)), candidate_namespace = "fixture-spawn",
		protocol = 2, state = "ready", phase = "stable",
		managed_sha256 = assert(codec.dispatch_managed_digest(runtime.json.encode(normal))), pending_immutable = 0, blockers = 0 },
		{ logical_session_ids = runtime.json.array(), mailbox_handles = runtime.json.array() }
end
local function role_node(node, role, key)
	if type(node) ~= "table" then return nil end
	if node.p and node.p.role == role and (key == nil or node.p.key == key) then return node end
	for _, child in node.c or {} do local found = role_node(child, role, key); if found then return found end end
	return nil
end
local function fixture(clock, options)
	local memory = keyed_memory()
	local authority = host.new_authority(memory, clock or function() return { now_ms = math.floor(os.time() * 1000) } end)
	authority:load(); assert(authority:initialize(true).ok)
	local peer, selection = empty_peer()
	local qualified = authority:qualify({ kind = "qualify_current", request_id = next_id(),
		authority_namespace = authority.registry.authority_namespace, expected_revision = authority.registry.revision }, peer, selection)
	assert(qualified.ok, qualified.message)
	local registered = authority:apply({ kind = "register_session", request_id = next_id(), orch_session_id = next_id(), name = "Dispatch fixture",
		authority_namespace = authority.registry.authority_namespace, expected_revision = authority.registry.revision })
	assert(registered.ok, registered.message)
	local admission = authority:apply({ kind = "admit_controller", request_id = next_id(), orch_session_id = registered.orch_session_id,
		authority_namespace = authority.registry.authority_namespace, expected_revision = authority.registry.revision,
		pane_binding = { host_pane_id = "42", alias_nonce = "fixture-controller-nonce" } })
	assert(admission.ok, admission.message)
	local origin = { logical_session_id = registered.orch_session_id, owner_id = admission.owner_id, owner_generation = admission.generation,
		host_pane_id = "42", alias_nonce = "fixture-controller-nonce", window_key = "", window_epoch = "fixture-window", native_session_id = "7", window_host_id = "local" }
	local f = { authority = authority, memory = memory, origin = origin, passive = options and options.passive == true }
	function f:event(command, fields)
		if command == "queue" and not self.passive and not (fields and fields.orch_project_id)
			and self.authority.registry.sessions[self.origin.logical_session_id].admitted == true then
			local project = ((self.authority.registry.dispatch or {}).projects or {})[self.default_project]
			if not project or project.finished or project.logical_session_id ~= self.origin.logical_session_id then self.default_project = self:project("Explicitly started transport fixture", true) end
		end
		local event = { kind = "dispatch", request_id = next_id(), orch_session_id = self.origin.logical_session_id,
			authority_namespace = self.authority.registry.authority_namespace, expected_revision = self.authority.registry.revision,
			origin = clone(self.origin), controller_pane = self.controller_pane or "9001", command = command }
		if command ~= "claim" and command ~= "spawn_claimed" and command ~= "result" and command ~= "lost" and command ~= "observe_allocation" then
			local cursor = ((self.authority.registry.dispatch or {}).command_cursors or {})[self.origin.logical_session_id]
			self.command_seq = math.max(self.command_seq or 0, if cursor then cursor.seq else 0) + 1
			event.command_seq = self.command_seq
		end
		for k, v in fields or {} do event[k] = v end
		if command == "queue" and event.orch_project_id == nil and not self.passive then event.orch_project_id = self.default_project end
		if table.find({ "answer", "new_project", "project_start", "project_associate", "project_repository", "associate_conversation" }, command)
			and event.expected_revision == self.authority.registry.revision and event.decision_context == nil then
			event.decision_context = dispatch.decision_context(self.authority.registry, event)
		end
		return event
	end
	-- Checkpoint 5 invariant sweep (D8/D9), run after every fixture command in every group: a gate
	-- answered by policy needs a session that enabled auto_approve_kinds, the matching rule and
	-- planned work (manual-source work never auto-approves); every answer source is tagged.
	function f:autonomy_sweep()
		local d = self.authority.registry.dispatch
		for gid, g in (d and d.gates) or {} do
			local src = g.answer and g.answer.source
			if src then
				assert(src.kind == "owner" or src.kind == "policy" or src.kind == "refusal", "gate answer source is untagged: " .. gid)
				assert(src.kind ~= "refusal" or (g.kind == "coordinator_proposal" and g.answer.choice_id == "reject"), "an ORCH+ refusal answered something other than a proposal reject: " .. gid)
				if src.kind == "policy" then
					local w = d.workers[g.worker_id]
					assert(self.autonomous, "a gate was answered by policy while auto_approve_kinds was never enabled: " .. gid)
					assert(g.kind == "coordinator_proposal" or g.kind == "landing_approval", "policy answered a non-autonomy gate: " .. gid)
					local kinds = dispatch.policy(self.authority.registry, w.logical_session_id).auto_approve_kinds
					local kind = if g.kind == "landing_approval" then "landing" else codec.decode_report(g.proposal, w).payload.kind
					assert(src.rule == "auto_approve:" .. kind and table.find(kinds, kind) and type(src.policy_revision) == "string" and #src.policy_revision == 64,
						"policy answer rule/revision does not match an enabled kind: " .. gid)
					local work_id = if g.kind == "landing_approval" then w.work_id else codec.decode_report(g.proposal, w).payload.work_id
					for _, t in d.workers do
						if t.work_id == work_id then assert(t.source and (t.source.kind == "plan" or t.source.kind == "board"), "unplanned work was auto-approved: " .. gid) end
					end
				end
			end
		end
	end
	function f:apply(command, fields)
		if command == "policy" and fields and fields.policy and fields.policy.auto_approve_kinds and #fields.policy.auto_approve_kinds > 0 then self.autonomous = true end
		local r = self.authority:apply(self:event(command, fields))
		self:autonomy_sweep()
		return r
	end
	function f:project(name, started)
		local added = self:apply("new_project", { name = name }); assert(added.ok, added.message)
		if started then
			local p = self.authority.registry.dispatch.projects[added.orch_project_id]
			local start = self:apply("project_start", { orch_project_id = p.orch_project_id, project_revision = p.revision, checks_reviewed = true })
			assert(start.ok, start.message)
		end
		return added.orch_project_id
	end
	function f:action(id) return self.authority.registry.dispatch.actions[id] end
	function f:tick()
		return self.authority:apply({ kind = "workflow_tick", authority_namespace = self.authority.registry.authority_namespace,
			expected_revision = self.authority.registry.revision })
	end
	function f:state_event(kind, fields)
		local event = { kind = kind, request_id = next_id(), orch_session_id = self.origin.logical_session_id,
			authority_namespace = self.authority.registry.authority_namespace, expected_revision = self.authority.registry.revision }
		for key, value in fields or {} do event[key] = value end
		return event
	end
	-- Deterministic peer model: operation facts come from the issued request and configured fixture
	-- record. `frame` above remains the raw boundary for deliberately malformed response tests.
	function f:peer_payload(a, status, facts)
		local request, payload = a.request, {}
		local w = if a.worker_id then self.authority.registry.dispatch.workers[a.worker_id] else nil
		if status == "provisioned" then
			payload.limits = { mailbox_bytes = 1048576, mailbox_files = 256, host_bytes = 67108864, host_files = 16384,
				generations = 16, registry_bytes = 8388608, reserved_bytes = 4096, deadline_ms = 30000, concurrency = 4 }
			payload.identity = { worker = "fixture-user" }
			if request.manifest ~= nil then payload.manifest_sha256 = codec.sha256(request.manifest) end
		elseif (request.op == "launch" or request.op == "adopt" or request.op == "enrol")
			and table.find({ "resolved", "claimed", "launching", "awaiting_acceptance", "accepted" }, status) then
			payload.record_id, payload.record_revision = request.record_id, request.record_revision
			payload.effective_identity = { provider = "omp", identity_status = "configured_not_verified" }
			payload.capabilities = runtime.json.array(clone(w.capabilities))
			payload.prompt_delivery = if request.delivery == "clipboard" then "copied_not_accepted" else "submitted_not_accepted"
		elseif request.op == "accept" and status == "accepted" then
			payload.target_request_id, payload.pane_binding = request.target_request_id, clone(request.pane_binding)
		end
		for key, value in facts or {} do
			if key == "limits" and payload.limits then for field, limit in value do payload.limits[field] = limit end
			else payload[key] = clone(value) end
		end
		if payload.wake_status ~= nil and payload.wake_effect_started == nil then
			payload.wake_effect_started = payload.wake_status ~= "awaiting_window"
		end
		return if next(payload) ~= nil then payload else nil
	end
	function f:finish(id, status, payload, problem)
		local a = assert(self:action(id), "finish requires a live action")
		if a.phase == "ready" then
			local claimed = self:apply("claim", { action_id = id, executor = self.origin.window_epoch })
			must(claimed.ok, claimed)
		end
		a = self:action(id) -- Serial and immutable request bytes are allocated only by claim.
		if table.find({ "launch", "adopt", "enrol", "stop", "native_wake" }, a.request.op) and status ~= "full" and status ~= "rejected" and not a.claim.spawn_claim then
			local witnessed = self:apply("spawn_claimed", { action_id = id, grant_id = a.claim.grant_id, spawn_namespace = "fixture-spawn",
				claim_nonce = "fixture-claim-nonce-" .. next_id() })
			must(witnessed.ok, witnessed)
			a = self:action(id)
		end
		-- Peer revision is independent of ORCH commits; repeating the same peer observation
		-- must retain identical bytes rather than inventing a newer SPAWN result revision.
		return self:apply("result", { action_id = id, executor = self.origin.window_epoch, grant_id = a.claim.grant_id,
			response_bytes = frame(a.request, status, self:peer_payload(a, status, payload), problem) })
	end
	function f:catalog(revision, record_id, cwd, family)
		local r = self:apply("catalog")
		assert(self:finish(r.action_id, "catalog", { catalog_version = 2, setup = catalog_setup(revision), namespace = "fixture-spawn", host_key = "fixture-host", config_revision = revision, revision = revision, records = runtime.json.array({ { id = record_id or "native", revision = revision,
			provider = "omp", provider_family = family, account_label = "configured, not verified", backend = "native-agent", enabled = true, eligible = true,
			capability_evidence = "configured_operator_attestation_not_runtime_proof", effective_identity = { provider = "omp", identity_status = "configured_not_verified" },
			capabilities = runtime.json.array({ "report-files-v1", "native-ask-v1", "coordinator-control-v1", "project-start-v1" }), unsupported = runtime.json.array(), cwd = cwd or "/fixture", placement = "split" } }) }).ok)
	end
	function f:allocation(worker_id, allocation, target_patch)
		local w, sid = self.authority.registry.dispatch.workers[worker_id], self.origin.logical_session_id
		local target = { logical_session_id = w.logical_session_id, worker_id = w.worker_id, worker_generation = w.worker_generation,
			launch_request_id = w.launch_request_id, work_id = w.work_id, enrolment_sha256 = codec.sha256(w.enrolment_token) }
		for key, value in target_patch or {} do target[key] = value end
		local query = { schema = 2, origin = "orchplus", op = "mailbox_allocation", request_id = next_id(), action_id = next_id(),
			authority_namespace = self.authority.registry.authority_namespace, logical_session_id = sid,
			admission_seq = self.authority.registry.sessions[sid].admission_seq, origin_binding = clone(self.origin),
			controller_pane = self.controller_pane or "9001", controller_generation = self.origin.owner_generation, target = target }
		local status = if allocation then "allocation" else "uncertain"
		local payload = if allocation then { target = clone(target), allocation = clone(allocation) } else nil
		return self:apply("observe_allocation", { worker_id = worker_id, query_bytes = runtime.json.encode(query),
			response_bytes = frame(query, status, payload, if allocation then nil else { code = "allocation_pending", message = "The exact provision is still pending." }) })
	end
	-- Transport fixtures intentionally share /fixture. Exercise each explicit owner decision;
	-- collision/refusal tests use raw queue/answer operations instead of this setup helper.
	function f:allow_shared_fixture(queued)
		if not queued.ok or queued.code ~= "task_gated" then return queued end
		local w = self.authority.registry.dispatch.workers[queued.worker_id]
		local gates = clone(w.launch_gates or {})
		for _, gate_id in gates do
			local gate = self.authority.registry.dispatch.gates[gate_id]
			assert(gate and (gate.kind == "shared_checkout" or gate.kind == "file_overlap"), "unexpected fixture launch gate")
			queued = self:apply("answer", { gate_id = gate.id, gate_revision = gate.revision, choice_id = "launch_anyway",
				answer = "The fixture owner intentionally coordinates these shared-checkout workers." })
			assert(queued.ok, queued.message)
		end
		return queued
	end
	function f:queue(coordinator)
		return self:allow_shared_fixture(self:apply("queue", { record_id = "native", record_revision = 0, catalog_revision = 0,
			prompt = "Complete the explicit fixture assignment, preserving literal $HOME and Unicode café.", cwd = "/fixture", placement = "split", coordinator = coordinator == true }))
	end
	function f:launched(coordinator)
		self:catalog(0)
		local queued = self:queue(coordinator); assert(queued.ok)
		assert(self:finish(queued.action_id, "provisioned", { handle = "mailbox-fixture", binding_digest = string.rep("a", 64),
			capabilities = runtime.json.array({ "report-files-v1", "native-ask-v1", "coordinator-control-v1", "project-start-v1" }), limits = {} }).ok)
		local worker = self.authority.registry.dispatch.workers[queued.worker_id]
		local claimed = self:apply("claim", { action_id = worker.launch_action_id, executor = self.origin.window_epoch })
		must(claimed.ok, claimed)
		self.last_launch_request = clone(self:action(worker.launch_action_id).request)
		assert(self:finish(worker.launch_action_id, "awaiting_acceptance", { pane_binding = { pane_id = self.target_pane or "9002",
			window_key = self.origin.window_key, window_epoch = self.origin.window_epoch,
			native_session_id = self.origin.native_session_id, window_host_id = self.origin.window_host_id } }).ok)
		return queued.worker_id
	end
	function f:report(worker_id, seq, kind, payload, extra)
		local w = self.authority.registry.dispatch.workers[worker_id]
		local r = { version = 3, logical_session_id = w.logical_session_id, worker_id = w.worker_id, worker_generation = w.worker_generation,
			launch_request_id = w.launch_request_id, work_id = w.work_id, enrolment_token = w.enrolment_token,
			event_id = codec.sha256(w.mailbox_handle .. ":report:" .. tostring(seq)), seq = seq, kind = kind, payload = payload }
		for k, v in extra or {} do r[k] = v end
		return runtime.json.encode(r)
	end
	function f:accepted(coordinator)
		local id = self:launched(coordinator)
		local w = self.authority.registry.dispatch.workers[id]
		assert(self:apply("intake", { worker_id = id, bytes = self:report(id, 1, "ACCEPTED", { assignment_sha256 = w.assignment_sha256 }) }).ok)
		assert(self:finish(self:apply("poll", { worker_id = id }).action_id, "published", {}).ok)
		assert(self:finish(self:apply("poll", { worker_id = id }).action_id, "accepted", {}).ok)
		return id
	end
	function f:watermark(worker_id)
		local w = self.authority.registry.dispatch.workers[worker_id]
		local mark = { version = 1, type = "receipt_watermark", mailbox_handle = w.mailbox_handle,
			through_seq = w.accepted_seq, receipt_chain_sha256 = w.receipt_chain }
		for _, k in { "logical_session_id", "worker_id", "worker_generation", "launch_request_id", "work_id", "enrolment_token" } do mark[k] = w[k] end
		while true do
			local queued = self:apply("poll", { worker_id = worker_id, bytes = "watermark" }); must(queued.ok, queued)
			local request = self:action(queued.action_id).request
			if request.op == "mailbox_read" and request.selector.stream == "watermark" then
				local page = must(codec.project_page(runtime.json.encode(mark), request.selector))
				return self:finish(queued.action_id, "read", runtime.json.decode(page))
			end
			-- Poll deliberately prioritizes known continuation over periodic discovery. Complete
			-- its real non-native outbox first; never substitute a watermark for another selector.
			local status = if request.op == "mailbox_publish_ack" or request.op == "mailbox_publish_reply" then "published"
				elseif request.op == "accept" then "accepted"
				elseif request.op == "mailbox_retire" and request.mode == "compact" then "compacted" else nil
			must(status, { code = "unexpected_watermark_continuation", request = request })
			local settled = self:finish(queued.action_id, status)
			must(settled.ok, settled)
		end
	end
	function f:read_report(worker_id, bytes)
		local w = self.authority.registry.dispatch.workers[worker_id]
		local framed = assert(codec.frame(bytes, "report", w)); local objects = { framed.manifest }
		for _, chunk in framed.chunks do table.insert(objects, chunk) end
		local outcome
		for _, object in objects do
			local queued = self:apply("poll", { worker_id = worker_id }); assert(queued.ok, queued.message)
			local request = self:action(queued.action_id).request
			assert(request.op == "mailbox_read", request.op)
			local page = must(codec.project_page(object, request.selector))
			outcome = self:finish(queued.action_id, "read", runtime.json.decode(page))
		end
		return outcome
	end
	function f:control(operation, outstanding)
		local queued = self:apply("bridge_control", { operation = operation, compatibility = clone(self.authority.registry.compatibility) })
		assert(queued.ok, "fixture control enqueue refused: " .. runtime.json.encode(queued))
		local session = self.authority.registry.sessions[self.origin.logical_session_id]
		local intent = assert(session.bridge_control)
		local request = intent.request
		local payload = { admission_cursor = request.admission_seq, compatibility = clone(request.compatibility) }
		local category, status = "current_admission", if operation == "admit_session" then "admitted" else "reconciled"
		if operation == "close_session" then category, status = "admission_absent", "closed"
		else
			payload.control = { phase = "open", generation_floor = request.generation_floor, request_floor = request.settled_before,
				next_request_serial = request.next_request_serial, last_authority_revision = request.authority_revision,
				binding = clone(request.control_origin.binding) }
			if operation == "reconcile_session" then payload.outstanding = outstanding or {
				after_serial = 0, through_serial = 0, next_after_serial = 0, complete = true, entries = runtime.json.array() } end
		end
		local response_bytes = frame(request, status, payload, nil, category, request.authority_revision)
		local response, diagnostic = codec.decode_dispatch_response(response_bytes, request)
		assert(response, "fixture control response must satisfy the canonical contract: "
			.. tostring(diagnostic and diagnostic.code):sub(1, 96) .. ": " .. tostring(diagnostic and diagnostic.message):sub(1, 256))
		local outcome = self:apply("bridge_result", { query_bytes = intent.request_bytes, response_bytes = response_bytes })
		assert(outcome.ok, "fixture " .. operation .. " result refused: " .. runtime.json.encode(outcome))
		return outcome
	end
	if not (options and options.defer_admission) then
		local admitted = f:control("admit_session")
		assert(admitted.ok, "fixture admission refused: " .. runtime.json.encode(admitted))
	end
	if not (options and options.default_limits) then assert(f:apply("policy", { policy = { concurrency_limit = 32 } }).ok) end
	return f
end
if section == "fixture" then return { fixture = fixture, clone = clone, codec = codec, state = state, dispatch = dispatch, host = host, quota = quota, frame = frame, load = load } end
if section == nil or section == "compaction_retry" then
	-- Exercise the real paired mailbox reducer: a request-ID-only check misses
	-- the immutable grant key retained after a helper's pre-effect refusal.
	local Mailbox = load("../SPAWN/mailbox")
	local f = fixture(); local id = f:accepted(false)
	assert(f:watermark(id).ok)
	local queued = f:apply("poll", { worker_id = id }); assert(queued.ok)
	assert(f:apply("claim", { action_id = queued.action_id, executor = f.origin.window_epoch }).ok)
	local original = clone(f:action(queued.action_id).request)
	assert(original.op == "mailbox_retire" and original.mode == "compact")
	local provision = clone(original)
	for _, key in { "handle", "expected_generation", "mode", "settlement_revision", "report_floor",
		"report_chain_sha256", "reply_floor", "grant_id" } do provision[key] = nil end
	provision.op = "mailbox_provision"; provision.request_id = "paired-provision"; provision.action_id = "paired-provision-action"
	provision.record_id = "native"; provision.record_revision = 0; provision.capability = "report-files-v1"
	local record = { id = "native", backend = "local-terminal", mailbox = {
		permitted_root = "/private/mailboxes", helper_path = "/private/tools/mailbox_target.sh",
		producer_helper_path = "/private/tools/mailbox_worker.sh", worker_identity = "worker",
		verified = true, evidence_ref = "fixture-only", wake = "worker-poll-v1",
		producer = { read = true, write = true, hash = true, journal = true, poll = true },
		capabilities = { "report-files-v1", "worker-poll-v1", "argv-v1" } } }
	local provision_op, prepared, problem = Mailbox.prepare(Mailbox.empty(), provision, record,
		{ operation_id = "paired-provision-op", handle = original.handle, host_os = "linux", host_shell = "sh" })
	must(provision_op, problem)
	local transport = must(Mailbox.settle(prepared, provision_op, { status = "provisioned" }))
	local first, active, refusal = Mailbox.prepare(transport, original, nil,
		{ operation_id = "paired-first", host_os = "linux", host_shell = "sh", settlement = clone(original) })
	must(first, refusal)
	local refused, outcome = Mailbox.settle(active, first,
		{ status = "full", admission_refused = true, resource = "capacity_admission", current = 1, limit = 1 })
	must(refused, outcome)
	assert(f:finish(queued.action_id, outcome.status, outcome.payload).code == "backpressure")
	local retry = f:apply("retry", { action_id = queued.action_id }); assert(retry.ok)
	assert(f:apply("claim", { action_id = retry.action_id, executor = f.origin.window_epoch }).ok)
	local fresh = clone(f:action(retry.action_id).request)
	local second, executing, rejected = Mailbox.prepare(refused, fresh, nil,
		{ operation_id = "paired-second", host_os = "linux", host_shell = "sh", settlement = clone(fresh) })
	check(second ~= nil, "proven pre-effect compaction retry reaches the real mailbox reducer without content_conflict")
	local compacted = must(Mailbox.settle(executing, second, { status = "compacted" }), rejected)
	assert(f:finish(retry.action_id, "compacted", {}).ok)
	local worker = f.authority.registry.dispatch.workers[id]
	check(worker.phase == "accepted" and worker.compaction_pending == nil
		and compacted.generations[original.handle].report_floor == original.report_floor
		and compacted.generations[original.handle].writes["grant:" .. original.grant_id] == nil,
		"successful fresh compaction settles the worker and reclaims the refused grant without freezing the generation")
end
-- Frozen C2 (9768916) v3 source shape: observe has no namespace/revision, and
-- pre-role workers may omit role. Keep these historical fields explicit rather
-- than relabelling a current registry as legacy or loading private frozen paths.
local function legacy_worker_fixture(coordinator)
	local f = fixture(); local worker_id = f:launched(coordinator)
	local current = f.authority.registry.dispatch.workers[worker_id]
	local observed = f:event("observe", { worker_id = worker_id, pane_binding = clone(current.pane_binding),
		native_state = "idle", observation_seq = 7 })
	local applied = f.authority:apply(observed); must(applied.ok, applied)
	local registry = f.authority.registry
	local worker = clone(registry.dispatch.workers[worker_id])
	worker.orch_project_id, worker.execution_cwd, worker.presentation, worker.project_held, worker.checks_pending = nil, nil, nil, nil, nil
	local sid = "orch-1"
	worker.logical_session_id = sid; worker.origin_binding.logical_session_id = sid
	local event = worker.workflow.observation_cursor.event
	event.orch_session_id = sid; event.origin.logical_session_id = sid
	event.authority_namespace = nil; event.expected_revision = nil
	local session = registry.sessions[f.origin.logical_session_id]
	local legacy = { version = 3, revision = registry.revision, next_session_id = 1, next_owner_id = registry.next_owner_id,
		execution_epoch = registry.execution_epoch, request_outcomes = {}, retired = {},
		setup = clone(registry.setup), installation_defaults = clone(registry.installation_defaults),
		sessions = { [sid] = { orch_session_id = sid, name = session.name, created_at_ms = session.created_at_ms,
			controller_generation = session.controller_generation, orchestrator_generation = session.orchestrator_generation,
			controller = clone(session.controller), orchestrator = clone(session.orchestrator) } },
		dispatch = { serial = registry.dispatch.serial, actions = {}, workers = { [worker_id] = worker },
			catalogs = {}, policies = {}, gates = {}, commands = {},
			command_cursors = { [sid] = { origin = clone(event.origin), controller_pane = event.controller_pane, seq = event.command_seq } } } }
	local selection = dispatch.migration_selection(legacy)
	local normal, problem, pending, blockers = dispatch.migration_identity(legacy, selection)
	must(normal, problem)
	assert(pending == 0 and blockers == 0, "legacy fixture has no unresolved effects or deliveries")
	-- Module-level peer evidence, not a claim of actual native paired qualification.
	local peer = { source_schema = 1, source_revision = 0, source_namespace = "fixture-spawn", source_sha256 = string.rep("a", 64),
		candidate_namespace = "fixture-spawn", protocol = 1, state = "ready", phase = "stable",
		managed_sha256 = must(codec.dispatch_managed_digest(runtime.json.encode(normal))), pending_immutable = 0, blockers = 0 }
	return legacy, worker_id, selection, peer
end
if section == nil or section == "legacy_observation" then
	local legacy, id, selection, peer = legacy_worker_fixture(false)
	for _, sequenced in { false, true } do
		local source = clone(legacy)
		if not sequenced then
			source.dispatch.workers[id].workflow.observation_cursor.event.command_seq = nil
			source.dispatch.workers[id].role = nil
		end
		local before = runtime.json.encode(source)
		check(state.valid_legacy(source) and state.migration_source(source) ~= nil,
			"exact C2 observation cursor enters the legacy boundary with optional command sequence and absent role")
		local prepared, problem = state.prepare_migration(source, "legacy-observation-cutover", peer, selection)
		must(prepared, problem)
		local worker = prepared.dispatch.workers[id]
		check(worker.workflow.observation_cursor == nil and worker.role == "builder"
			and runtime.json.encode(worker.workflow.native) == runtime.json.encode(source.dispatch.workers[id].workflow.native)
			and worker.accepted_seq == source.dispatch.workers[id].accepted_seq
			and worker.enrolment_token == source.dispatch.workers[id].enrolment_token,
			"cutover discards the old delivery cursor without rewriting native evidence, report progress or enrolment")
		check(runtime.json.encode(source) == before and prepared.dispatch.commands == nil and next(prepared.dispatch.actions) == nil,
			"paired preparation leaves source evidence untouched and creates no executable request or command history")
		check(prepared.sessions["orch-1"].admitted == nil and prepared.sessions["orch-1"].controller.phase == "uncertain"
			and state.rehydrate(clone(prepared)) ~= nil, "prepared migration reloads without admitting the old controller")
		local proof, proof_problem = state.migration_proof(prepared, selection); must(proof, proof_problem)
		local stable_peer = clone(peer); stable_peer.source_schema = 2; stable_peer.protocol = 2
		local stable, stable_problem = state.finish_migration(prepared,
			{ schema = 1, kind = "migration", orch = proof, spawn = stable_peer }, selection)
		must(stable, stable_problem)
		check(stable.migration == nil and stable.dispatch.workers[id].workflow.observation_cursor == nil
			and state.rehydrate(clone(stable)) ~= nil, "completed cutover retains no legacy delivery cursor")
		local replay = clone(source.dispatch.workers[id].workflow.observation_cursor.event)
		local stable_before = runtime.json.encode(stable)
		local changed, refused = state.apply(stable, replay)
		check(changed == nil and refused.code == "invalid_event" and runtime.json.encode(stable) == stable_before,
			"completed cutover still rejects the unfenced old observation without changing current state")
	end
	for name, mutate in {
		namespace_only = function(e) e.authority_namespace = "legacy-observation-cutover" end,
		revision_only = function(e) e.expected_revision = 0 end,
		both_current_fields = function(e) e.authority_namespace = "legacy-observation-cutover"; e.expected_revision = 0 end,
		false_namespace = function(e) e.authority_namespace = false end,
		false_revision = function(e) e.expected_revision = false end,
		unknown_field = function(e) e.extra = true end,
		sequence_mismatch = function(e) e.observation_seq += 1 end,
		foreign_worker = function(e) e.worker_id = "other-worker" end,
		foreign_origin = function(e) e.origin.window_epoch = "other-window" end,
		foreign_pane = function(e) e.pane_binding.pane_id = "9999" end,
		future_command = function(e) e.command_seq += 1 end,
	} do
		local broken = clone(legacy); mutate(broken.dispatch.workers[id].workflow.observation_cursor.event)
		local before = runtime.json.encode(broken)
		local prepared, problem = state.prepare_migration(broken, "legacy-observation-cutover", peer, selection)
		check(not state.valid_legacy(broken) and state.migration_source(broken) == nil and prepared == nil and problem.code == "state_corrupt"
			and runtime.json.encode(broken) == before, name .. ": malformed or hybrid legacy cursor is rejected before migration without changing input")
	end
end
if section == nil or section == "legacy_worker_roles" then
	for _, coordinator in { false, true } do
		local legacy, id, selection, peer = legacy_worker_fixture(coordinator)
		local expected = if coordinator then "coordinator" else "builder"
		-- Test missing-role admission independently of the observation-cursor exception.
		legacy.dispatch.workers[id].workflow.observation_cursor = nil
		for _, missing in { false, true } do
			local source = clone(legacy)
			if missing then source.dispatch.workers[id].role = nil end
			local before = runtime.json.encode(source)
			check(state.valid_legacy(source), expected .. ": exact old role form is valid before migration")
			local prepared, problem = state.prepare_migration(source, "legacy-role-cutover", peer, selection)
			must(prepared, problem)
			check(prepared.dispatch.workers[id].role == expected and prepared.dispatch.workers[id].family == source.dispatch.workers[id].family
				and runtime.json.encode(source) == before and state.rehydrate(clone(prepared)) ~= nil,
				expected .. ": cutover infers only an absent legacy role and preserves the source and family")
			local corrupt = clone(prepared); corrupt.dispatch.workers[id].role = nil
			check(not dispatch.valid(corrupt.dispatch, corrupt) and state.rehydrate(corrupt) == nil,
				expected .. ": prepared current state cannot reuse legacy permission to omit role")
		end
		for _, role in { false, "", "admin", 1, runtime.json.null } do
			local broken = clone(legacy); broken.dispatch.workers[id].role = role
			check(not state.valid_legacy(broken) and state.prepare_migration(broken, "legacy-role-cutover", peer, selection) == nil,
				expected .. ": a present malformed legacy role is never defaulted")
		end
	end
end
if section == nil or section == "current_observation" then
	local f = fixture(); local id = f:launched(false)
	local w = f.authority.registry.dispatch.workers[id]
	local observed = f:event("observe", { worker_id = id, pane_binding = clone(w.pane_binding), native_state = "idle", observation_seq = 1 })
	local applied = f.authority:apply(observed); must(applied.ok, applied)
	local saved = clone(f.authority.registry)
	check(dispatch.valid(saved.dispatch, saved) and state.rehydrate(clone(saved)) ~= nil,
		"current fenced observation restores with its original namespace and earlier revision")
	for name, mutate in {
		missing_namespace = function(e) e.authority_namespace = nil end,
		missing_revision = function(e) e.expected_revision = nil end,
		legacy_shape = function(e) e.authority_namespace = nil; e.expected_revision = nil end,
		foreign_namespace = function(e) e.authority_namespace = "other-authority" end,
		negative_revision = function(e) e.expected_revision = -1 end,
		fractional_revision = function(e) e.expected_revision = 0.5 end,
		string_revision = function(e) e.expected_revision = "0" end,
		uncommitted_revision = function(e) e.expected_revision = saved.revision end,
		future_revision = function(e) e.expected_revision = saved.revision + 1 end,
	} do
		local corrupt = clone(saved); mutate(corrupt.dispatch.workers[id].workflow.observation_cursor.event)
		check(not dispatch.valid(corrupt.dispatch, corrupt) and state.rehydrate(corrupt) == nil,
			name .. ": current observation cannot enter through the legacy boundary")
	end
	for _, field in { "authority_namespace", "expected_revision" } do
		local unfenced = f:event("observe", { worker_id = id, pane_binding = clone(w.pane_binding), native_state = "working", observation_seq = 2 })
		unfenced[field] = nil
		local before, writes = runtime.json.encode(f.authority.registry), f.memory.writes
		check(not f.authority:apply(unfenced).ok and f.memory.writes == writes and runtime.json.encode(f.authority.registry) == before,
			field .. ": live observe still requires its captured authority fence and refuses without a write")
	end
end
if section == nil or section == "current_retention" then
	local f = fixture(); local sid = f.origin.logical_session_id
	local first = f.authority.registry.sessions[sid].next_request_serial
	for index = 1, 4097 do
		f:catalog(0)
		local d = f.authority.registry.dispatch
		check(next(d.actions) == nil and d.commands == nil and f.authority.registry.request_outcomes == nil
			and f.authority.registry.retired == nil, "each completed catalog leaves only current state, beyond former history capacity")
	end
	check(f.authority.registry.sessions[sid].next_request_serial == first + 4097, "all 4097 results were actually issued and consumed")
	check(state.rehydrate(clone(f.authority.registry)) ~= nil, "bounded current state restores after former lifetime bound")
end
if section == nil or section == "current_ack_holes" then
	do
		local current = fixture(); local sid = current.origin.logical_session_id
		local confirmed = current.authority.registry.sessions[sid].request_floor
		current:catalog(0)
		local queued = current:apply("bridge_control", { operation = "reconcile_session",
			compatibility = clone(current.authority.registry.compatibility) }); must(queued.ok, queued)
		local projected = dispatch.project(current.authority.registry, sid, current.origin.alias_nonce)
		local request = projected.control.request
		check(request.settled_before > confirmed
			and projected.sessions[sid].control.request_floor == request.settled_before
			and projected.sessions[sid].control.next_request_serial == request.next_request_serial
			and projected.session_control.request_floor == confirmed,
			"native control advertises derived ACK progress matching its exact request, without claiming peer-confirmed coverage")
	end
	local f = fixture(); f:catalog(0)
	local low = f:queue(false); assert(low.ok)
	assert(f:apply("claim", { action_id = low.action_id, executor = f.origin.window_epoch }).ok)
	local low_request = clone(f:action(low.action_id).request)
	local high = f:apply("catalog"); assert(high.ok)
	assert(f:apply("claim", { action_id = high.action_id, executor = f.origin.window_epoch }).ok)
	local high_request = clone(f:action(high.action_id).request)
	assert(f:finish(high.action_id, "catalog", { catalog_version = 2, setup = catalog_setup(0), namespace = "fixture-spawn",
		host_key = "fixture-host", config_revision = 0, revision = 0, records = runtime.json.array() }).ok)
	local page = { after_serial = 0, through_serial = high_request.request_serial, next_after_serial = high_request.request_serial,
		complete = true, entries = runtime.json.array({
			{ request_serial = low_request.request_serial, request_id = low_request.request_id, action_id = low_request.action_id, op = low_request.op, phase = "claimed" },
			{ request_serial = high_request.request_serial, request_id = high_request.request_id, action_id = high_request.action_id, op = high_request.op, phase = "current_result" },
		}) }
	assert(f:control("reconcile_session", page).ok)
	local floor, consumed = dispatch.ack_progress(f.authority.registry, f.origin.logical_session_id)
	check(floor == low_request.request_serial and #consumed == 1 and consumed[1] == high_request.request_serial,
		"lost ACK for a completed hole is reconstructed above a still-live lower serial")
	check(f:action(low.action_id).phase == "claimed" and f:action(high.action_id) == nil, "ACK derivation neither consumes the lower effect nor retains the higher result")
	local saved = clone(f.authority.registry)
	local restored = assert(state.rehydrate(saved))
	local restored_floor, restored_consumed = dispatch.ack_progress(restored, f.origin.logical_session_id)
	check(restored_floor == floor and restored_consumed[1] == high_request.request_serial
		and restored.dispatch.actions[low.action_id].phase == "uncertain", "reload preserves unresolved low effect and reconstructible consumed hole")
end
if section == nil or section == "current_nonce" then
	local function witness_case(f, action_id, op)
		check(f:action(action_id).request.op == op, op .. ": fixture reaches the actual native operation")
		local unissued = assert(state.rehydrate(clone(f.authority.registry)))
		check(unissued.dispatch.actions[action_id].phase == "held_ready" and unissued.dispatch.actions[action_id].request_bytes == nil,
			op .. ": restoring before issue never silently schedules the native operation")
		assert(f:apply("claim", { action_id = action_id, executor = f.origin.window_epoch }).ok)
		local original = clone(f:action(action_id))
		local before_witness = assert(state.rehydrate(clone(f.authority.registry)))
		check(before_witness.dispatch.actions[action_id].phase == "uncertain" and before_witness.dispatch.actions[action_id].claim.spawn_claim == nil,
			op .. ": ORCH-only rollback before peer claim retains uncertainty rather than proving no effect")
		local witness = { action_id = action_id, grant_id = original.claim.grant_id, spawn_namespace = "fixture-spawn",
			claim_nonce = "independent-" .. op .. "-first-claim" }
		assert(f:apply("spawn_claimed", witness).ok)
		local first = clone(f:action(action_id).claim.spawn_claim)
		local writes = f.memory.writes
		check(f:apply("spawn_claimed", witness).ok and f.memory.writes == writes, op .. ": same native claim is a read-only current observation")
		for _, field in { "claim_nonce", "spawn_namespace" } do
			local changed = clone(witness); changed[field] = "different-independent-" .. field
			check(f:apply("spawn_claimed", changed).code == "claim_mismatch" and f:action(action_id).phase == "uncertain"
				and f:action(action_id).claim.spawn_claim.claim_nonce == first.claim_nonce
				and f:action(action_id).claim.spawn_claim.spawn_namespace == first.spawn_namespace,
				op .. ": peer rollback cannot replace the first namespace/nonce witness or authorize a second effect")
		end
		writes = f.memory.writes
		check(f:apply("spawn_claimed", witness).code == "spawn_claim_observed" and f.memory.writes == writes
			and f:action(action_id).phase == "uncertain",
			op .. ": reobserving the first witness cannot clear retained uncertainty or grant execution")
		check(f:action(action_id).request_bytes == original.request_bytes, op .. ": uncertainty preserves original immutable request and serial")
		local restored = assert(state.rehydrate(clone(f.authority.registry)))
		check(restored.dispatch.actions[action_id].phase == "uncertain"
			and restored.dispatch.actions[action_id].claim.spawn_claim.claim_nonce == first.claim_nonce, op .. ": both-side restoration retains uncertainty and first witness")
	end
	for _, op in { "launch", "enrol" } do
		local f = fixture(); f:catalog(0)
		local queued
		if op == "launch" then queued = f:queue(false)
		else
			queued = f:apply("enrol", { record_id = "native", record_revision = 0, catalog_revision = 0,
				orch_project_id = f:project("Nonce-bound existing conversation", false), delivery = "native_ask",
				pane_binding = { pane_id = "9020", window_key = f.origin.window_key, window_epoch = f.origin.window_epoch,
					native_session_id = f.origin.native_session_id, window_host_id = f.origin.window_host_id } })
		end
		assert(queued.ok)
		assert(f:finish(queued.action_id, "provisioned", { handle = "nonce-mailbox", binding_digest = string.rep("a", 64),
			capabilities = runtime.json.array({ "report-files-v1", "native-ask-v1", "coordinator-control-v1", "project-start-v1" }) }).ok)
		witness_case(f, f.authority.registry.dispatch.workers[queued.worker_id].launch_action_id, op)
	end
	do
		local f = fixture(); local id = f:accepted(false)
		assert(f:apply("finish", { worker_id = id }).ok)
		for _ = 1, 16 do
			local publish = false
			for _, receipt in f.authority.registry.dispatch.workers[id].receipts do if receipt.publish then publish = true end end
			if not publish then break end
			local pending = f:apply("poll", { worker_id = id }); assert(pending.ok)
			assert(f:action(pending.action_id).request.op == "mailbox_publish_ack")
			assert(f:finish(pending.action_id, "published").ok)
		end
		assert(f:watermark(id).ok)
		local stop = f:apply("poll", { worker_id = id }); assert(stop.ok)
		witness_case(f, stop.action_id, "stop")
	end
	do
		local f = fixture(function() return { now_ms = 1000, mono_ms = 1000, epoch = "nonce-wake-host" } end)
		local id = f:accepted(false)
		local worker = f.authority.registry.dispatch.workers[id]
		assert(f:apply("observe", { worker_id = id, pane_binding = worker.pane_binding, native_state = "working" }).ok)
		assert(f:apply("intake", { worker_id = id, bytes = f:report(id, 2, "HEARTBEAT", { state = "working" }) }).ok)
		local publication = f:apply("poll", { worker_id = id }); assert(publication.ok)
		local request = f:action(publication.action_id).request
		assert(f:finish(publication.action_id, "published", { wake_status = "awaiting_window", wake_effect_started = false,
			wake_target_request_id = request.request_id, wake_target_action_id = request.action_id }).ok)
		assert(f:apply("observe", { worker_id = id, pane_binding = worker.pane_binding, native_state = "idle" }).ok)
		local wake = f:apply("poll", { worker_id = id }); assert(wake.ok)
		witness_case(f, wake.action_id, "native_wake")
	end
end
if section == nil or section == "current_close" then
	local f = fixture(); f:catalog(0)
	local closing_sid = f.origin.logical_session_id
	local old_origin = clone(f.origin)
	assert(f:apply("policy", { policy = { automatic_reports = false } }).ok)
	local other = f:state_event("register_session", { orch_session_id = next_id(), name = "Unaffected live session" })
	local registered = f.authority:apply(other); assert(registered.ok, registered.message)
	local other_before = runtime.json.encode(f.authority.registry.sessions[registered.orch_session_id])
	local close_id = next_id()
	local begun = f.authority:apply(f:state_event("begin_close", { close_id = close_id,
		control_origin = { kind = "closing", binding = old_origin, controller_pane = "9001", close_id = close_id } }))
	assert(begun.ok, begun.message)
	check(f:apply("catalog").code == "session_closing", "closing fences new enqueue before peer closure")
	check(state.rehydrate(clone(f.authority.registry)) ~= nil, "closing with retained exact control origin restores")
	assert(f.authority:apply(f:state_event("release_controller", { expected_owner_id = old_origin.owner_id,
		expected_generation = old_origin.owner_generation })).ok)
	check(not f.authority:apply(f:state_event("confirm_close", { close_id = close_id })).ok, "owner release alone cannot reclaim an admitted session")
	assert(f:control("close_session").ok)
	local before = f.memory.writes
	local confirm = f:state_event("confirm_close", { close_id = close_id })
	local snapshot = runtime.json.encode(f.authority.registry)
	f.memory.fail = true
	check(f.authority:apply(confirm).code == "persistence_failed" and f.memory.writes == before
		and runtime.json.encode(f.authority.registry) == snapshot and runtime.json.encode(f.memory.value) == snapshot,
		"failed final close commit preserves every live and terminal table atomically")
	f.memory.fail = false
	assert(f.authority:apply(confirm).ok)
	local d = f.authority.registry.dispatch
	check(f.memory.writes == before + 1 and f.authority.registry.sessions[closing_sid] == nil
		and d.catalogs[closing_sid] == nil and d.policies[closing_sid] == nil and d.command_cursors[closing_sid] == nil,
		"one confirmed close commit reclaims session and every populated terminal scoped table")
	check(runtime.json.encode(f.authority.registry.sessions[registered.orch_session_id]) == other_before,
		"atomic close preserves the other live session byte-for-byte")
	check(f.authority:apply(other).code == "already_registered", "a matching still-active registration is observed without reopening a closed session")
	check(state.rehydrate(clone(f.authority.registry)) ~= nil, "closed/absent graph restores with no dangling references")
	-- Exercise the pure graph cut for every scope, separately from the validated authority/store
	-- transaction above. Sentinel rows deliberately test routing keys, not fabricated valid work.
	local graph = { dispatch = { actions = {}, landing = { items = {}, queues = {} } } }
	local other_sid = registered.orch_session_id
	for _, field in { "catalogs", "sweeps", "policies", "command_cursors", "capacity" } do
		graph.dispatch[field] = { [closing_sid] = { token = "remove-" .. field }, [other_sid] = { token = "keep-" .. field } }
	end
	for _, field in { "workers", "gates", "rollovers", "reviews", "deploys", "plans", "intakes", "chains" } do
		graph.dispatch[field] = { gone = { logical_session_id = closing_sid }, kept = { logical_session_id = other_sid, token = field } }
	end
	graph.dispatch.actions = { gone = { request = { origin_binding = { logical_session_id = closing_sid } } },
		kept = { request = { origin_binding = { logical_session_id = other_sid } } } }
	for _, field in { "items", "queues" } do
		graph.dispatch.landing[field] = { gone = { logical_session_id = closing_sid }, kept = { logical_session_id = other_sid, token = field } }
	end
	local original = graph.dispatch
	dispatch.reclaim_session(graph, closing_sid)
	check(graph.dispatch ~= original and original.workers.gone ~= nil, "graph reclaim copies before deleting and leaves the input snapshot untouched")
	for _, field in { "catalogs", "sweeps", "policies", "command_cursors", "capacity" } do
		check(graph.dispatch[field][closing_sid] == nil and graph.dispatch[field][other_sid].token == "keep-" .. field, field .. ": removes only the closing session")
	end
	for _, field in { "actions", "workers", "gates", "rollovers", "reviews", "deploys", "plans", "intakes", "chains" } do
		check(graph.dispatch[field].gone == nil and runtime.json.encode(graph.dispatch[field].kept) == runtime.json.encode(original[field].kept),
			field .. ": terminal scoped graph disappears while other session remains identical")
	end
	for _, field in { "items", "queues" } do
		check(graph.dispatch.landing[field].gone == nil and graph.dispatch.landing[field].kept.token == field, "landing " .. field .. ": reclaims only closing graph")
	end
end
if section == nil or section == "poll_continuation" then
	local clock = { now_ms = 1000, mono_ms = 1000, epoch = "continuation-host" }
	local f = fixture(function() return clone(clock) end); local id = f:launched(false)
	local function worker() return f.authority.registry.dispatch.workers[id] end
	local function projected()
		for _, shown in dispatch.project(f.authority.registry, f.origin.logical_session_id, f.origin.alias_nonce).workflow.workers do
			if shown.worker_id == id then return shown end
		end
		error("missing continuation worker")
	end
	local function due(label)
		local shown = projected()
		check(shown.poll_continuation == true and shown.due_poll and worker().workflow.last_poll.mono_ms == clock.mono_ms,
			label .. " is immediately runnable without advancing the idle poll clock")
		check(worker().workflow.poll_continuation == nil, "continuation readiness is derived, not a persisted workflow field")
	end
	local function poll(op, periodic)
		local queued = f:apply("poll", { worker_id = id, bytes = if periodic then "watermark" else nil })
		assert(queued.ok, queued.message)
		check(f:action(queued.action_id).request.op == op, "poll selects " .. op .. " without adding an operation")
		check(not projected().poll_continuation and not projected().due_poll, "a ready action suppresses duplicate continuation scheduling")
		return queued.action_id
	end
	local logical = f:report(id, 1, "ACCEPTED", { assignment_sha256 = worker().assignment_sha256 }) .. string.rep(" ", 5000)
	local frames = assert(codec.frame(logical, "report", worker()))
	check(#frames.chunks > 1, "continuation fixture exercises a partial multi-chunk report")
	local manifest = poll("mailbox_read", false)
	local page = assert(codec.project_page(frames.manifest, f:action(manifest).request.selector))
	assert(f:finish(manifest, "read", runtime.json.decode(page)).ok)
	for index, chunk in frames.chunks do
		due(if index == 1 then "manifest continuation" else "partial chunk continuation")
		local part = poll("mailbox_read", true)
		local request = f:action(part).request
		check(request.selector.stream == "report" and request.selector.part == "chunk" and request.selector.index == index,
			"periodic watermark yields to the exact next report chunk")
		assert(f:apply("claim", { action_id = part, executor = f.origin.window_epoch }).ok)
		local bytes, grant, writes = f:action(part).request_bytes, f:action(part).claim.grant_id, f.memory.writes
		check(not projected().poll_continuation and not projected().due_poll
			and f:apply("poll", { worker_id = id, bytes = "watermark" }).code == "operation_pending"
			and f.memory.writes == writes and f:action(part).request_bytes == bytes and f:action(part).claim.grant_id == grant,
			"claimed partial read blocks duplicate continuation and preserves its immutable grant")
		page = assert(codec.project_page(chunk, request.selector))
		assert(f:finish(part, "read", runtime.json.decode(page)).ok)
	end
	check(worker().accepted_seq == 1 and worker().assembly == nil and worker().accept_pending, "complete assembly commits acceptance before settlement")
	due("ACK continuation")
	local ack = poll("mailbox_publish_ack", true)
	assert(f:finish(ack, "published", {}).ok)
	due("accept continuation")
	local accepted = poll("accept", true)
	assert(f:finish(accepted, "accepted", {}).ok)
	check(not projected().poll_continuation and not projected().due_poll, "settled acceptance returns to paced discovery")

	assert(f:apply("observe", { worker_id = id, pane_binding = worker().pane_binding, native_state = "idle" }).ok)
	assert(f:apply("reply", { worker_id = id }).ok)
	local reply_bytes = worker().replies["1"].bytes
	due("reply chunk continuation")
	local publication = poll("mailbox_publish_reply", true)
	check(f:action(publication).request.part == "chunk", "reply chunk still precedes its manifest")
	assert(f:finish(publication, "full", { resource = "active_transport", current = 4, limit = 4, retryable = true, effect_started = false }).code == "backpressure")
	local retained, writes = f:action(publication).request_bytes, f.memory.writes
	check(not projected().poll_continuation and not projected().due_poll
		and f:apply("poll", { worker_id = id, bytes = "watermark" }).code == "operation_pending"
		and f.memory.writes == writes and f:action(publication).request_bytes == retained and worker().replies["1"].part == 1,
		"switching a periodic watermark to continuation cannot use the watermark backpressure exception to duplicate publication")
	local retried = f:apply("retry", { action_id = publication }); assert(retried.ok, retried.message)
	assert(f:finish(retried.action_id, "published", {}).ok)
	while worker().replies["1"].part <= #worker().replies["1"].frames.chunks + 1 do
		due("reply part continuation")
		local part = worker().replies["1"].part
		local next_part = poll("mailbox_publish_reply", true)
		local request = f:action(next_part).request
		check(request.part == (if part > #worker().replies["1"].frames.chunks then "manifest" else "chunk")
			and worker().replies["1"].bytes == reply_bytes, "reply parts and final manifest retain the original immutable reply")
		assert(f:finish(next_part, "published", {}).ok)
	end
	check(not projected().poll_continuation, "fully published reply awaiting acknowledgement is not runnable continuation")
	assert(f:watermark(id).ok)
	due("compaction continuation")
	local compact = poll("mailbox_retire", true)
	check(f:action(compact).request.mode == "compact", "periodic watermark yields to already-authorized compaction")
	assert(f:finish(compact, "compacted", {}).ok)
	assert(f:apply("observe", { worker_id = id, pane_binding = worker().pane_binding, native_state = "idle" }).ok)
	check(not projected().poll_continuation and not projected().due_poll, "idle worker without known work is still paced")
	local poll_ms = dispatch.policy(f.authority.registry, f.origin.logical_session_id).poll_ms
	clock.mono_ms += poll_ms - 1; clock.now_ms += poll_ms - 1
	assert(f:tick().ok)
	check(not projected().poll_continuation and not projected().due_poll, "plain discovery waits until the full poll_ms interval")
	clock.mono_ms += 1; clock.now_ms += 1
	assert(f:tick().ok)
	check(not projected().poll_continuation and projected().due_poll, "plain discovery becomes due at poll_ms without becoming continuation")
	local discovery = poll("mailbox_read", false)
	check(f:action(discovery).request.selector.stream == "report" and f:action(discovery).request.selector.part == "manifest",
		"idle discovery still reads the next report manifest")
	assert(f:finish(discovery, "missing", {}).ok)
	check(not projected().poll_continuation and not projected().due_poll, "missing discovery starts another idle interval, not a hot loop")
end
if section == nil or section == "assembly_restore" then
	local f = fixture(); local id = f:accepted(false)
	local function worker() return f.authority.registry.dispatch.workers[id] end
	local bytes = f:report(id, 2, "HEARTBEAT", { state = "idle" }) .. string.rep(" ", 5000)
	local framed = assert(codec.frame(bytes, "report", worker()))
	local function deliver(object)
		local queued = f:apply("poll", { worker_id = id }); assert(queued.ok, queued.message)
		local page = assert(codec.project_page(object, f:action(queued.action_id).request.selector))
		return f:finish(queued.action_id, "read", runtime.json.decode(page))
	end
	assert(deliver(framed.manifest).ok)
	check(state.rehydrate(clone(f.authority.registry)) ~= nil, "manifest-only incremental state restores")
	assert(deliver(framed.chunks[1]).ok)
	local a = worker().assembly
	check(a.version == 1 and a.next_index == 2 and a.bytes == 2048 and #a.slices == 1 and a.chunks == nil
		and worker().accepted_seq == 1 and worker().receipts["2"] == nil, "a persisted prefix is not a receipt or encoded-chunk replay journal")
	local saved = clone(f.authority.registry)
	check(state.rehydrate(clone(saved)) ~= nil, "partial multi-chunk report passes strict restore validation")
	for _, mutate in {
		function(w) w.assembly.extra = true end,
		function(w) w.assembly.version = 2 end,
		function(w) w.assembly.next_index = 3 end,
		function(w) w.assembly.bytes += 1 end,
		function(w) w.assembly.slices[1] ..= "\n" end,
		function(w) w.assembly.slices[1] = runtime.base64.encode("short") end,
		function(w) w.assembly.object_digests[1] = "bad" end,
		function(w) w.assembly.binding.worker_generation += 1 end,
		function(w) w.assembly.manifest.message_sha256 = string.rep("0", 64) end,
		function(w) w.assembly.manifest_sha256 = string.rep("0", 64) end,
		function(w) w.read_selector.index = 3 end,
	} do
		local malformed = clone(saved); mutate(malformed.dispatch.workers[id])
		check(state.rehydrate(malformed) == nil, "corrupt incremental state or selector is refused at restore")
	end
	local legacy = clone(saved)
	legacy.dispatch.workers[id].assembly = { manifest = framed.manifest, sha256 = codec.sha256(framed.manifest),
		chunks = { { bytes = framed.chunks[1], sha256 = codec.sha256(framed.chunks[1]) } } }
	check(not dispatch.valid(legacy.dispatch, legacy) and state.rehydrate(clone(legacy)) == nil,
		"current stores cannot inject an old encoded-chunk assembly and silently invoke legacy migration")
	for _, mutate in {
		function(old) old.chunks[1].sha256 = string.rep("0", 64) end,
		function(old) old.chunks[1] = { bytes = framed.chunks[2], sha256 = codec.sha256(framed.chunks[2]) } end,
		function(old) old.chunks[2] = clone(old.chunks[1]) end,
	} do
		local malformed = clone(legacy); mutate(malformed.dispatch.workers[id].assembly)
		check(state.rehydrate(malformed) == nil, "invalid, skipped or duplicate legacy prefix is never silently migrated")
	end
	-- A real authority reload must preserve the prefix while requiring the same explicit recovery.
	local original = clone(worker())
	f.authority = host.new_authority(f.memory); assert(f.authority:load().ok)
	f.origin.window_epoch = "assembly-replacement-window"; f.controller_pane = "9010"
	check(not f:apply("poll", { worker_id = id }).ok, "reloaded partial report grants no automatic read authority")
	assert(f:apply("continue_controller", { expected_revision = f.authority.registry.revision, operator_verified = true }).ok)
	assert(f:control("reconcile_session").ok) -- Fresh peer observation restores admission, never the old revision fence.
	local pane = { pane_id = "9013", window_key = "", window_epoch = f.origin.window_epoch, native_session_id = "7", window_host_id = "local" }
	local attached = f:apply("continue_worker", { worker_id = id, pane_binding = pane,
		continuation_proof = dispatch.continuation_proof(f.authority.registry, worker()), operator_verified = true })
	assert(attached.ok, attached.message)
	assert(f:finish(attached.action_id, "attached", { pane_binding = pane, previous_origin_binding = original.origin_binding,
		previous_pane_binding = original.pane_binding }).ok)
	check(worker().assembly.next_index == 2 and worker().read_selector.index == 2, "explicit attachment resumes the next slice, not a replay of chunk one")
	for index = 2, #framed.chunks do assert(deliver(framed.chunks[index]).ok) end
	check(worker().accepted_seq == 2 and worker().receipts["2"].publish and worker().receipts["2"].sha256 == codec.sha256(bytes)
		and worker().assembly == nil and worker().read_selector == nil, "final exact bytes commit cursor and owed ACK together after reload")
	local ack = f:apply("poll", { worker_id = id }); assert(ack.ok, ack.message)
	check(f:action(ack.action_id).request.op == "mailbox_publish_ack" and worker().accepted_seq == 2,
		"ACK publication remains strictly after the durable acceptance cursor")
end
if section == nil or section == "assembly_capacity" then
	local f = fixture()
	local ids, frames = {}, {}
	for index = 1, 5 do
		f.target_pane = tostring(9200 + index)
		local id = f:accepted(false); ids[index] = id
		local w = f.authority.registry.dispatch.workers[id]
		frames[index] = assert(codec.frame(f:report(id, 2, "HEARTBEAT", { state = "idle" }) .. string.rep(" ", 3000), "report", w))
	end
	for index, id in ids do
		local queued = f:apply("poll", { worker_id = id }); assert(queued.ok, queued.message)
		local page = assert(codec.project_page(frames[index].manifest, f:action(queued.action_id).request.selector))
		local result = f:finish(queued.action_id, "read", runtime.json.decode(page))
		check(result.ok and (index < 5 or result.code == "intake_backpressure"), "only four active report assemblies are admitted")
		if index < 5 then
			local chunk = f:apply("poll", { worker_id = id }); assert(chunk.ok, chunk.message)
			local part = assert(codec.project_page(frames[index].chunks[1], f:action(chunk.action_id).request.selector))
			assert(f:finish(chunk.action_id, "read", runtime.json.decode(part)).ok)
		end
	end
	local total, active = 0, 0
	for _, w in f.authority.registry.dispatch.workers do
		if w.assembly then active += 1; total += w.assembly.bytes end
	end
	check(active == 4 and total == 4 * 2048 and total <= 262144 and f.authority.registry.dispatch.workers[ids[5]].assembly == nil
		and f.authority.registry.dispatch.workers[ids[5]].receipts["2"] == nil, "fifth report stays unacknowledged without displacing a retained prefix")
	check(state.rehydrate(clone(f.authority.registry)) ~= nil, "four active assemblies restore within the host budget")
	local corrupt = clone(f.authority.registry)
	local fifth = corrupt.dispatch.workers[ids[5]]
	local binding = clone(corrupt.dispatch.workers[ids[1]].assembly.binding)
	for _, key in { "logical_session_id", "worker_id", "worker_generation", "launch_request_id", "work_id", "enrolment_token",
		"mailbox_handle", "assignment_sha256", "capabilities" } do binding[key] = clone(fifth[key]) end
	fifth.assembly = assert(codec.assembly_start(frames[5].manifest, codec.sha256(frames[5].manifest), binding))
	fifth.read_selector = { stream = "report", slot = 2, part = "chunk", index = 1 }
	check(state.rehydrate(corrupt) == nil, "restore cannot bypass the four-active-state limit")
end
if section == nil or section == "control_rebind" then
	for _, scenario in { "previous_window", "repeated_windows", "retained_other_host", "other_owner", "other_host", "other_session", "other_pane", "other_alias",
		"future_serial", "future_generation", "future_revision", "missing_control", "admission_control" } do
		local f = fixture(nil, { defer_admission = scenario == "admission_control" })
		local sid, previous = f.origin.logical_session_id, clone(f.origin)
		local healthy = scenario == "previous_window" or scenario == "repeated_windows"
		local held = if healthy then f:project("Held project", false) else nil
		local repeated = scenario == "repeated_windows" or scenario == "retained_other_host"
		local initial_peer_revision = f.authority.registry.sessions[sid].last_authority_revision
		if repeated then
			f.origin.window_epoch = "intermediate-window"
			if scenario == "retained_other_host" then f.origin.window_host_id = "intermediate-host" end
			assert(f:apply("continue_controller", { operator_verified = true }).ok)
		end
		local retained
		if scenario ~= "missing_control" then
			local operation = if scenario == "admission_control" then "admit_session" else "reconcile_session"
			assert(f:apply("bridge_control", { operation = operation, compatibility = clone(f.authority.registry.compatibility) }).ok)
			retained = clone(f.authority.registry.sessions[sid].bridge_control)
		end
		local session = f.authority.registry.sessions[sid]
		local peer = { phase = "open", generation_floor = session.generation_floor,
			request_floor = session.request_floor, next_request_serial = session.next_request_serial,
			last_authority_revision = if repeated then initial_peer_revision elseif retained then retained.request.authority_revision else f.authority.registry.revision,
			binding = clone(previous) }
		f.origin = clone(previous)
		f.origin.window_epoch = "verified-replacement-window"
		assert(f:apply("continue_controller", { operator_verified = true }).ok)
		if scenario == "other_owner" then peer.binding.owner_id = "other-owner"
		elseif scenario == "other_host" then peer.binding.window_host_id = "other-host"
		elseif scenario == "other_session" then peer.binding.native_session_id = "other-session"
		elseif scenario == "other_pane" then peer.binding.host_pane_id = "other-pane"
		elseif scenario == "other_alias" then peer.binding.alias_nonce = "other-alias"
		elseif scenario == "future_serial" then peer.next_request_serial += 1
		elseif scenario == "future_generation" then peer.generation_floor += 1
		elseif scenario == "future_revision" then peer.last_authority_revision = f.authority.registry.revision + 1 end
		session = f.authority.registry.sessions[sid]
		local query = { schema = 2, origin = "orchplus", op = "owner_status", request_id = next_id(), action_id = next_id(),
			authority_namespace = f.authority.registry.authority_namespace, logical_session_id = sid,
			admission_seq = session.admission_seq, origin_binding = clone(f.origin),
			controller_pane = f.controller_pane or "9001", controller_generation = f.origin.owner_generation }
		local bytes = frame(query, "owner_status", { admission_cursor = session.admission_seq,
			compatibility = clone(f.authority.registry.compatibility), control = peer }, nil, "current_admission",
			math.max(session.last_authority_revision, f.authority.registry.revision))
		local before, writes = runtime.json.encode(f.authority.registry), f.memory.writes
		local observed = f:apply("bridge_observe", { query_bytes = runtime.json.encode(query), response_bytes = bytes })
		if healthy then
			check(observed.ok and f.authority.registry.sessions[sid].bridge_control == nil
				and f.authority.registry.sessions[sid].admitted ~= true,
				"exact old-window reconciliation settles without transferring admission to the replacement")
			check(f:apply("catalog").code == "admission_required" and next(f.authority.registry.dispatch.workers) == nil,
				"settled old route cannot authorize a catalog or agent startup")
			assert(f:control("reconcile_session").ok)
			check(f.authority.registry.sessions[sid].admitted == true and f:apply("catalog").ok
				and not f.authority.registry.dispatch.projects[held].started and next(f.authority.registry.dispatch.workers) == nil,
				"fresh current-route reconciliation restores navigation without starting held project work")
		else
			check(not observed.ok and f.memory.writes == writes and runtime.json.encode(f.authority.registry) == before,
				scenario .. ": observation cannot discard a retained control or grant admission")
		end
	end
end
if section == nil or section == "core" then
do
	local f = fixture(); local sid = f.origin.logical_session_id
	local queued = f:apply("bridge_control", { operation = "reconcile_session", compatibility = clone(f.authority.registry.compatibility) })
	assert(queued.ok, runtime.json.encode(queued))
	local intent = f.authority.registry.sessions[sid].bridge_control
	local control_bytes, request = intent.request_bytes, clone(intent.request)
	assert(f:apply("pause").ok) -- An unrelated real candidate must retain the immutable control.
	local function retained_control(registry, label)
		local retained = registry.sessions[sid].bridge_control
		local decoded, problem = codec.decode_dispatch_request(runtime.json.encode(retained.request))
		check(retained.request_bytes == control_bytes and decoded ~= nil
			and runtime.json.encode(retained.request.consumed) == "[]",
			label .. ": immutable control bytes and empty consumed-array shape survive: " .. runtime.json.encode(problem))
	end
	retained_control(f.authority.registry, "dispatch candidate through state.checked")
	local restored, diagnostic = state.rehydrate(clone(f.memory.value))
	assert(restored, runtime.json.encode(diagnostic))
	retained_control(restored, "state.rehydrate")
	local response = frame(request, "reconciled", { admission_cursor = request.admission_seq,
		compatibility = clone(request.compatibility), control = { phase = "open",
			generation_floor = request.generation_floor, request_floor = request.settled_before,
			next_request_serial = request.next_request_serial, last_authority_revision = request.authority_revision,
			binding = clone(request.control_origin.binding) },
		outstanding = { after_serial = 0, through_serial = 0, next_after_serial = 0, complete = true, entries = runtime.json.array() } },
		nil, "current_admission", request.authority_revision)
	check(codec.decode_dispatch_response(response, restored.sessions[sid].bridge_control.request) ~= nil,
		"restored immutable control remains a canonical response-decoder request")
	local observed = f:apply("bridge_result", { query_bytes = control_bytes, response_bytes = response })
	check(observed.ok and f.authority.registry.sessions[sid].bridge_control == nil,
		"actual candidate consumes the exact retained canonical control response: " .. runtime.json.encode(observed))
	assert(f:apply("resume").ok)
	local catalog = f:apply("catalog"); assert(catalog.ok)
	assert(f:apply("claim", { action_id = catalog.action_id, executor = f.origin.window_epoch }).ok)
	local issued_bytes = f:action(catalog.action_id).request_bytes
	assert(f:apply("pause").ok)
	local reloaded, problem = state.rehydrate(clone(f.memory.value)); assert(reloaded, runtime.json.encode(problem))
	for _, registry in { f.authority.registry, reloaded } do
		local retained = registry.dispatch.actions[catalog.action_id]
		check(retained.request_bytes == issued_bytes
			and codec.decode_dispatch_request(runtime.json.encode(retained.request)) ~= nil
			and runtime.json.encode(retained.request.consumed) == "[]",
			"issued action survives candidate and reload without rewriting canonical request bytes or array shape")
	end
	local settled = f:finish(catalog.action_id, "rejected", nil, { code = "storage_error", message = "Fixture read refusal" })
	check(settled.ok and f:action(catalog.action_id) == nil,
		"actual response settles copied issued request without schema relaxation: " .. runtime.json.encode(settled))
end
do
	local reads = fixture(); reads:catalog(0)
	local captured = reads:event("catalog")
	captured.decision_context = assert(dispatch.decision_context(reads.authority.registry, captured))
	reads:project("Unrelated bookkeeping", false)
	captured.command_seq = reads.command_seq + 1; reads.command_seq = captured.command_seq
	local accepted = reads.authority:apply(captured)
	check(accepted.ok and reads:action(accepted.action_id).request.op == "catalog",
		"the same captured catalog subject survives unrelated project bookkeeping without refreshing or replaying intent")
	local writes = reads.memory.writes
	check(reads.authority:apply(clone(captured)).code == "stale_command" and reads.memory.writes == writes,
		"subject-scoped catalog reads still obey the single-execution command sequence")
	for _, change in { "cursor", "window", "authority", "policy", "missing_context" } do
		local f = fixture(); f:catalog(0)
		local request = f:event("catalog", { bytes = { revision = 0, index = 2 } })
		request.decision_context = assert(dispatch.decision_context(f.authority.registry, request))
		if change == "cursor" then request.bytes.index = 3
		elseif change == "window" then request.origin.window_epoch = "different-window"
		elseif change == "authority" then request.authority_namespace = "different-authority"
		elseif change == "policy" then assert(f:apply("pause").ok)
		else request.decision_context = nil; f:project("Another update", false) end
		request.command_seq = f.command_seq + 1; f.command_seq = request.command_seq
		local before, writes = runtime.json.encode(f.authority.registry), f.memory.writes
		check(not f.authority:apply(request).ok and f.memory.writes == writes
			and runtime.json.encode(f.authority.registry) == before,
			"catalog " .. change .. " cannot borrow a captured context or issue a read")
	end
end
local opaque = fixture()
local configured_id, configured_cwd = "Configured worker / one", "/" .. string.rep("a", 1200)
opaque:catalog(0, configured_id, configured_cwd)
check(opaque:apply("queue", { record_id = configured_id, record_revision = 0, catalog_revision = 0, prompt = "Explicit task",
	cwd = configured_cwd, placement = "split", coordinator = false }).ok, "legacy configured record IDs and cwd up to the public 2048-byte bound are preserved, not narrowed to generated ID syntax")
local f = fixture(); f:catalog(0)
local wrong = f:event("queue", { record_id = "native", record_revision = 0, catalog_revision = 0, prompt = "task", cwd = "/fixture", placement = "split", coordinator = true })
wrong.origin.alias_nonce = "duplicate-panel"
check(f.authority:apply(wrong).code == "controller_mismatch", "inert duplicate cannot dispatch as the admitted controller")
local changed = f:event("queue", { record_id = "native", record_revision = 1, catalog_revision = 0, prompt = "task", cwd = "/fixture", placement = "split", coordinator = false })
check(f.authority:apply(changed).code == "unsupported_capability", "changed selected record revision holds before provision")
changed.record_revision = 0; changed.catalog_revision = 1
check(f.authority:apply(changed).code == "catalog_changed", "catalog revision is pinned")
local queue = f:event("queue", { record_id = "native", record_revision = 0, catalog_revision = 0, prompt = "task", cwd = "/fixture", placement = "split", coordinator = true })
local before = runtime.json.encode(f.authority.registry)
f.memory.fail = true
check(f.authority:apply(queue).code == "persistence_failed", "failed task/owner commit exposes no effect")
check(runtime.json.encode(f.authority.registry) == before and f.memory.value.sessions[f.origin.logical_session_id].orchestrator == nil, "failed queue keeps coordinator unreserved and creates no action")
f.memory.fail = false
local queued = f.authority:apply(queue)
check(queued.ok, "task queues after successful atomic save")
local slot = f.authority.registry.sessions[f.origin.logical_session_id].orchestrator
check(slot ~= nil and slot.pane_binding == nil and slot.work_id == queued.work_id, "startup reservation occupies coordinator before provisioning or pane")
check(f:queue(true).code == "orchestrator_slot_occupied", "distinct concurrent coordinator start refuses even without a pane")
local writes = f.memory.writes
local replay = f.authority:apply(clone(queue))
check(replay.code == "stale_revision" and f.memory.writes == writes, "lost queue response is reconciled from current work, never replayed under a refreshed revision")
local claim = f:event("claim", { action_id = queued.action_id, executor = "fixture-window" })
f.memory.fail = true
check(f.authority:apply(claim).code == "persistence_failed" and f:action(queued.action_id).phase == "ready", "failed claim persistence grants no execution")
f.memory.fail = false
check(f.authority:apply(claim).code == "effect_granted", "one persisted window claim owns provisioning")
check(f:apply("claim", { action_id = queued.action_id, executor = "competitor-window" }).code == "effect_already_claimed", "competing claims never get the same effect")
local next_task = f:queue(false); assert(next_task.ok)
local claimed_view = { pane = 42, alias_nonce = f.origin.alias_nonce, orch_session_id = f.origin.logical_session_id, action_serial = 0, dispatch_action = next_task.action_id }
local claimed_projection = state.project(f.authority.registry)
claimed_projection.dispatch = dispatch.project(f.authority.registry, f.origin.logical_session_id, f.origin.alias_nonce, next_task.action_id)
local claimed_surface = load("views").render(claimed_view, claimed_projection, "ready")
local claimed_text = assert(role_node(claimed_surface, "orchplus.dispatch")).p.spans[1]
local request_text = assert(role_node(claimed_surface, "orchplus.request")).p.spans[1]
local claimed_machine = runtime.json.decode(if type(claimed_text) == "string" then claimed_text else claimed_text.t)
local claimed_request = runtime.json.decode(if type(request_text) == "string" then request_text else request_text.t)
check(claimed_machine.action.action_id == queued.action_id and claimed_machine.action.claim.grant_id == f:action(queued.action_id).claim.grant_id
	and claimed_request.action_id == queued.action_id, "queueing another task cannot hide the live provisioning grant or substitute its immutable request")
check(f:apply("lost", { action_id = queued.action_id, executor = "fixture-window", grant_id = f:action(queued.action_id).claim.grant_id }).ok, "lost native outcome becomes uncertain")
check(f:action(queued.action_id).phase == "uncertain" and dispatch.unresolved(f.authority.registry, f.origin.logical_session_id, slot.owner_id), "uncertain claim occupies actual executor ledger and coordinator")
local late = f:event("result", { action_id = queued.action_id, executor = "fixture-window", grant_id = f:action(queued.action_id).claim.grant_id,
	response_bytes = frame(f:action(queued.action_id).request, "provisioned", f:peer_payload(f:action(queued.action_id), "provisioned", {
		handle = "box", binding_digest = string.rep("a", 64), capabilities = runtime.json.array({ "report-files-v1", "native-ask-v1" }) })) })
check(codec.decode_dispatch_response(late.response_bytes, f:action(queued.action_id).request) ~= nil,
	"late callback carries a valid canonical provision response before testing its captured fence")
local restored = host.new_authority(f.memory)
check(restored:load().ok, "dispatch ledger validates/restores through sole-host store")
check(restored.registry.dispatch.actions[queued.action_id].phase == "uncertain", "restore retains ambiguous operation")
do
	local retained, durable, intent, writes = runtime.json.encode(restored.registry), runtime.json.encode(f.memory.value), runtime.json.encode(late), f.memory.writes
	local refused = restored:apply(late)
	check(refused.ok == false and restored.registry.sessions[f.origin.logical_session_id].orchestrator.owner_id == slot.owner_id
		and runtime.json.encode(restored.registry) == retained and runtime.json.encode(f.memory.value) == durable and f.memory.writes == writes
		and runtime.json.encode(late) == intent, "stale callback preserves its captured fence and cannot bind, clear or mutate a restored coordinator")
end
local codec_request = f:action(queued.action_id).request
do
	check(clone(nil) == nil and runtime.json.encode(clone(runtime.json.null)) == "null",
		"fixture copying distinguishes absent fields from deliberate JSON null")
	check(codec.decode_dispatch_response(frame(codec_request, "pending"), codec_request) ~= nil,
		"fixture framing omits absent control origin and payload without inventing fields")
	local null_request = clone(codec_request); null_request.control_origin = clone(runtime.json.null)
	local decoded, diagnostic = codec.decode_dispatch_response(frame(null_request, "pending"), codec_request)
	check(decoded == nil and diagnostic.code == "invalid_schema", "deliberate null survives fixture framing and remains forbidden")
	decoded, diagnostic = codec.decode_dispatch_response(frame(codec_request, "pending", {}), codec_request)
	check(decoded == nil and diagnostic.code == "invalid_schema", "raw fixture framing preserves deliberately invalid empty payloads")
end
check(protocol.decode_response("SPAWN_DISPATCH v0 {}", codec_request) == nil, "incompatible bridge cannot fall back")
local forged = clone(codec_request); forged.action_id = "another-action"
check(protocol.decode_response(frame(forged, "provisioned", {}), codec_request) == nil, "mismatched exact action response rejects")

local g = fixture(function() return { now_ms = 1000, mono_ms = 1000, epoch = "core-wake-host" } end)
local worker_id = g:launched(false)
local worker = g.authority.registry.dispatch.workers[worker_id]
check(worker.pane_binding.pane_id == "9002" and worker.phase == "awaiting_acceptance", "only correlated SPAWN outcome binds actual window-local pane")
local launch = g.last_launch_request
check(launch.fresh == true and launch.prompt == worker.prompt and launch.enrolment.handover_id == nil and launch.enrolment.handover_token == nil, "initial launch is explicit/fresh and has no fabricated handover")
local accepted = g:report(worker_id, 1, "ACCEPTED", { assignment_sha256 = worker.assignment_sha256 })
check(g:apply("intake", { worker_id = worker_id, bytes = accepted }).code == "report_committed", "initial exact ACCEPTED commits")
worker = g.authority.registry.dispatch.workers[worker_id]
local ack = worker.receipts["1"].bytes
check(worker.accepted_seq == 1 and worker.phase == "accepted" and worker.accept_pending and worker.receipts["1"].publish, "one commit contains semantic state, receipt, cursor, ACK and SPAWN accept outboxes")
check(g:apply("intake", { worker_id = worker_id, bytes = accepted }).code == "report_replayed", "same exact report replays receipt, not acceptance")
check(g.authority.registry.dispatch.workers[worker_id].receipts["1"].bytes == ack, "ACK replay preserves original committed bytes/revision")
local gap = g:report(worker_id, 3, "ACCEPTED", { assignment_sha256 = worker.assignment_sha256 })
check(g:apply("intake", { worker_id = worker_id, bytes = gap }).code == "gap", "sequence gaps never skip")
local unmatched = g:report(worker_id, 2, "HEARTBEAT", { state = "working", request_id = "unissued-request" })
check(g:apply("intake", { worker_id = worker_id, bytes = unmatched }).code == "binding_mismatch", "valid heartbeat cannot fulfill an unissued progress request")
local stale = runtime.json.decode(accepted); stale.worker_generation = 2
check(g:apply("intake", { worker_id = worker_id, bytes = runtime.json.encode(stale) }).code == "binding_mismatch", "wrong generation rejects before receipt")
local publish = g:apply("poll", { worker_id = worker_id })
check(g:action(publish.action_id).request.op == "mailbox_publish_ack", "settlement publishes committed ACK first")
check(runtime.base64.decode(g:action(publish.action_id).request.ack_b64) == ack, "SPAWN receives exact saved ACK bytes")
local ack_request = clone(g:action(publish.action_id).request)
check(g:finish(publish.action_id, "published", { wake_status = "awaiting_window", wake_effect_started = false,
	wake_target_request_id = ack_request.request_id, wake_target_action_id = ack_request.action_id }).ok
	and g:action(publish.action_id) == nil
	and not g.authority.registry.dispatch.workers[worker_id].receipts["1"].publish,
	"known ACK publication releases its action and retains only the separate unstarted native notification")
local ack_reload = host.new_authority(keyed_memory(g.memory.value, g.memory.marker))
check(ack_reload:load().ok and ack_reload.registry.dispatch.actions[publish.action_id] == nil
	and ack_reload.registry.dispatch.workers[worker_id].wakes[ack_request.action_id] ~= nil,
	"reload retains the native notification without reviving a completed publication grant")
check(g.authority.registry.dispatch.workers[worker_id].compacted_floor == 0, "ACK publication does not prove worker receipt")
local accept_op = g:apply("poll", { worker_id = worker_id })
local accept_request = g:action(accept_op.action_id).request
check(accept_request.op == "accept" and accept_request.target_request_id == worker.launch_request_id and accept_request.event_sha256 == codec.sha256(accepted), "SPAWN acceptance is correlated to durably accepted exact report")
check(accept_request.handover_id == nil and accept_request.handover_token == nil and accept_request.pane_binding.pane_id == "9002", "initial accept callback needs no handover fields")
check(g:finish(accept_op.action_id, "accepted", {}).ok and not g.authority.registry.dispatch.workers[worker_id].accept_pending, "accept outbox settles only on SPAWN accepted outcome")
assert(g:apply("observe", { worker_id = worker_id, pane_binding = worker.pane_binding, native_state = "idle" }).ok)
local ack_wake = g:apply("poll", { worker_id = worker_id }); must(ack_wake.ok, ack_wake)
check(g:action(ack_wake.action_id).request.op == "native_wake"
	and g:action(ack_wake.action_id).request.target_action_id == ack_request.action_id,
	"fresh idle observation grants the separate notification of the consumed ACK publication")
assert(g:finish(ack_wake.action_id, "submitted", { wake_status = "submitted", wake_effect_started = true }).ok)
local reply = g:apply("reply", { worker_id = worker_id })
check(reply.ok, "immutable host progress reply commits")
worker = g.authority.registry.dispatch.workers[worker_id]
local message = worker.replies["1"]
local reply_bytes = message.bytes
local reply_part = g:apply("poll", { worker_id = worker_id })
check(g:action(reply_part.action_id).request.op == "mailbox_publish_reply", "reply outbox is schedulable through SPAWN")
check(g:apply("claim", { action_id = reply_part.action_id, executor = "fixture-window" }).ok, "reply publication has an exclusive durable effect claim")
local refused_reply_request = g:action(reply_part.action_id).request_bytes
check(g:finish(reply_part.action_id, "full", { resource = "active_transport", current = 4, limit = 4, retryable = true, effect_started = false }).code == "backpressure", "definitively unexecuted reply publication has explicit retryable backpressure")
check(g.authority.registry.dispatch.workers[worker_id].phase == "accepted", "transport capacity never demotes durable acceptance")
local refused_reply_id = reply_part.action_id
reply_part = g:apply("retry", { action_id = refused_reply_id })
check(reply_part.ok and reply_part.action_id ~= refused_reply_id and g:action(refused_reply_id) == nil
	and g:action(reply_part.action_id).request_bytes == nil, "reply retry consumes old issuance and allocates a fresh unissued action")
check(g:apply("claim", { action_id = reply_part.action_id, executor = "fixture-window" }).ok
	and g:action(reply_part.action_id).request_bytes ~= refused_reply_request, "capacity recheck gets another durable grant and serial without changing reply bytes")
check(g:apply("lost", { action_id = reply_part.action_id, executor = "fixture-window", grant_id = g:action(reply_part.action_id).claim.grant_id }).ok, "lost reply publication remains uncertain")
check(g:apply("claim", { action_id = reply_part.action_id, executor = "fixture-window" }).code == "effect_already_claimed"
	and g.authority.registry.dispatch.workers[worker_id].replies["1"].bytes == reply_bytes, "lost reply cannot obtain another execution grant or lose its immutable bytes")
check(g:finish(reply_part.action_id, "published", {}).ok, "first reply chunk publishes")
local manifest = g:apply("poll", { worker_id = worker_id })
check(g:action(manifest.action_id).request.part == "manifest", "reply manifest is the last immutable part")
local manifest_part = g.authority.registry.dispatch.workers[worker_id].replies["1"].part
local manifest_request = clone(g:action(manifest.action_id).request)
check(g:finish(manifest.action_id, "already_published", { wake_status = "awaiting_window", wake_effect_started = false,
	wake_target_request_id = manifest_request.request_id, wake_target_action_id = manifest_request.action_id }).ok
	and g:action(manifest.action_id) == nil
	and g.authority.registry.dispatch.workers[worker_id].replies["1"].part == manifest_part + 1,
	"confirmed manifest advances publication and retains a separately identified native notification")
local notification = g:apply("poll", { worker_id = worker_id }); must(notification.ok, notification)
check(g:action(notification.action_id).request.op == "native_wake", "notification receives its own immutable native request")
check(g:finish(notification.action_id, "pending").code == "pending"
	and g:action(notification.action_id).phase == "claimed", "pending native response cannot settle its separate grant")
local notification_grant = g:action(notification.action_id).claim.grant_id
local visible_wake = dispatch.project(g.authority.registry, g.origin.logical_session_id, g.origin.alias_nonce).actions[notification.action_id]
check(visible_wake.claim.grant_id == notification_grant and g:action(manifest.action_id) == nil,
	"consumer projection retains only the exact separate native grant")
local other_action = g:apply("catalog")
local wake_view = { pane = 42, alias_nonce = g.origin.alias_nonce, orch_session_id = g.origin.logical_session_id, action_serial = 0, dispatch_action = other_action.action_id }
local wake_projection = state.project(g.authority.registry)
wake_projection.dispatch = dispatch.project(g.authority.registry, g.origin.logical_session_id, g.origin.alias_nonce, other_action.action_id)
local rendered_wake = assert(role_node(load("views").render(wake_view, wake_projection, "ready"), "orchplus.dispatch")).p.spans[1]
local wake_machine = runtime.json.decode(if type(rendered_wake) == "string" then rendered_wake else rendered_wake.t)
check(wake_machine.action.action_id == notification.action_id and wake_machine.action.claim.grant_id == visible_wake.claim.grant_id,
	"another selected queued task cannot hide the separately claimed native notification")
check(g:finish(notification.action_id, "submitted", { wake_status = "submitted", wake_effect_started = true }).ok
	and g:action(notification.action_id) == nil, "only terminal submitted evidence settles native wake, not a worker receipt")
check(g.authority.registry.dispatch.workers[worker_id].replies["1"].bytes == reply_bytes and g.authority.registry.dispatch.workers[worker_id].reply_floor == 0, "transport publication cannot settle or rewrite a reply")
local reply_ack = g:report(worker_id, 2, "reply_ack", { message_id = message.message_id, reply_seq = 1, reply_sha256 = message.sha256, status = "recorded" }, { action_id = message.action_id, action_revision = message.action_revision })
check(g:apply("intake", { worker_id = worker_id, bytes = reply_ack }).ok, "matching worker receipt settles reply atomically with report ACK")
check(g.authority.registry.dispatch.workers[worker_id].reply_floor == 1 and g.authority.registry.dispatch.workers[worker_id].replies["1"] == nil, "contiguous acknowledged reply prefix compacts")
local reply_receipt = g.authority.registry.dispatch.workers[worker_id].receipts["2"].bytes
check(g:apply("intake", { worker_id = worker_id, bytes = reply_ack }).code == "report_replayed" and g.authority.registry.dispatch.workers[worker_id].receipts["2"].bytes == reply_receipt, "reply_ack replay uses saved receipt after reply payload compaction")

local h = fixture(); local failed_worker = h:launched(false)
local w = h.authority.registry.dispatch.workers[failed_worker]
local acceptance = h:report(failed_worker, 1, "ACCEPTED", { assignment_sha256 = w.assignment_sha256 })
local intake = h:event("intake", { worker_id = failed_worker, bytes = acceptance })
before = runtime.json.encode(h.authority.registry); h.memory.fail = true
check(h.authority:apply(intake).code == "persistence_failed", "failed semantic commit returns failure")
check(runtime.json.encode(h.authority.registry) == before and h.memory.value.dispatch.workers[failed_worker].accepted_seq == 0 and next(h.memory.value.dispatch.workers[failed_worker].receipts) == nil, "failed acceptance emits neither receipt nor ACK/accept outbox")
h.memory.fail = false
check(h.authority:apply(intake).ok, "retained report can commit after storage repair when no fresh native observation was discarded")
local conflicting = acceptance .. " "
check(h:apply("intake", { worker_id = failed_worker, bytes = conflicting }).code == "content_conflict_frozen", "same event with changed exact bytes durably freezes generation")
check(h.authority.registry.dispatch.workers[failed_worker].frozen, "conflict evidence survives the host commit")

-- Complete mailbox pages, not direct semantic injection, drive the production intake boundary.
local t = fixture(); local framed_worker = t:launched(true)
local tw = t.authority.registry.dispatch.workers[framed_worker]
local coordinator = t.authority.registry.sessions[t.origin.logical_session_id].orchestrator
check(coordinator.phase == "running" and coordinator.managed_worker_id == framed_worker and coordinator.pane_binding == nil, "coordinator is running through a separately scoped actual worker binding, never a fabricated host-local pane")
local logical = t:report(framed_worker, 1, "ACCEPTED", { assignment_sha256 = tw.assignment_sha256 })
local framed = assert(codec.frame(logical, "report", tw))
local manifest_read = t:apply("poll", { worker_id = framed_worker })
local selector = t:action(manifest_read.action_id).request.selector
local projected = must(codec.project_page(framed.manifest, selector))
check(t:finish(manifest_read.action_id, "read", runtime.json.decode(projected)).ok, "validated manifest page commits bounded assembly but no receipt")
check(t.authority.registry.dispatch.workers[framed_worker].accepted_seq == 0, "manifest alone cannot apply acceptance")
for _, chunk in framed.chunks do
	local part = t:apply("poll", { worker_id = framed_worker })
	local selected = t:action(part.action_id).request.selector
	local page = must(codec.project_page(chunk, selected))
	check(t:finish(part.action_id, "read", runtime.json.decode(page)).ok, "correlated complete chunk flows through host intake")
end
tw = t.authority.registry.dispatch.workers[framed_worker]
check(tw.accepted_seq == 1 and tw.accept_pending and tw.receipts["1"].publish and tw.assembly == nil, "last verified chunk atomically creates receipt and both acceptance outboxes")
local ack_publish = t:apply("poll", { worker_id = framed_worker })
assert(t:finish(ack_publish.action_id, "published", {}).ok)
local accepted_callback = t:apply("poll", { worker_id = framed_worker })
assert(t:finish(accepted_callback.action_id, "accepted", {}).ok)
-- Semantic coordinator acceptance creates a typed activation reply. Publication of that
-- real outbox precedes watermark discovery; publishing it never fabricates its reply_ack.
local watermark_result = t:watermark(framed_worker)
must(watermark_result.ok, watermark_result)
check(t.authority.registry.dispatch.workers[framed_worker].activation.acknowledged == false,
	"watermark reads drain the activation publication without granting coordinator acknowledgment")
tw = t.authority.registry.dispatch.workers[framed_worker]
check(tw.compacted_floor == 1 and tw.receipts["1"] == nil and tw.accepted_seq == 1, "worker-confirmed prefix compacts receipts without forgetting acceptance fence")
local cleanup = t:apply("poll", { worker_id = framed_worker })
check(t:action(cleanup.action_id).request.op == "mailbox_retire" and t:action(cleanup.action_id).request.mode == "compact" and t:action(cleanup.action_id).request.report_floor == 1, "committed watermark alone authorizes bounded SPAWN compaction grant")
assert(t:finish(cleanup.action_id, "compacted", {}).ok)
check(t:apply("intake", { worker_id = framed_worker, bytes = logical }).code == "already_compacted", "below-floor replay cannot fabricate an old receipt")
local reload = host.new_authority(t.memory)
check(reload:load().ok and reload.registry.dispatch.workers[framed_worker].compacted_floor == 1, "accepted mailbox/reply fences survive actual host restoration")

local unavailable = { kind = "observe_owner", request_id = next_id(), orch_session_id = f.origin.logical_session_id,
	authority_namespace = restored.registry.authority_namespace, expected_revision = restored.registry.revision,
	target = "controller", expected_owner_id = f.origin.owner_id, expected_generation = f.origin.owner_generation, status = "unavailable", evidence = "observed" }
check(restored:apply(unavailable).ok, "fresh unavailable observation permits exact executor inspection after reload")
local reset = clone(unavailable); reset.request_id = next_id(); reset.status = "operator checked"; reset.evidence = "operator_attested"
reset.expected_revision = restored.registry.revision
reset.owner_active = false; reset.pending_executors = 0; reset.operator_verified = true; reset.executors_verified = true
check(restored:apply(reset).code == "dispatch_executor_unresolved", "blind inspection-count reset cannot erase a retained actual action claim")
local inert_projection = dispatch.project(restored.registry, f.origin.logical_session_id, "new-inert-panel")
check(inert_projection.actions[queued.action_id] ~= nil, "replacement inert recovery panel can inspect the old exact executor ledger")
local reconcile = { kind = "dispatch_reconcile", request_id = next_id(), orch_session_id = f.origin.logical_session_id, action_id = queued.action_id,
	authority_namespace = restored.registry.authority_namespace,
	executor = "fixture-window", expected_revision = restored.registry.revision - 1, operator_verified = true, reason = "Independently stopped retained native executor and any delayed launch." }
local stale_before, stale_writes = runtime.json.encode(restored.registry), f.memory.writes
check(restored:apply(reconcile).ok == false and runtime.json.encode(restored.registry) == stale_before and f.memory.writes == stale_writes,
	"executor recovery with a changed display revision cannot change authority or release its executor")
reconcile.expected_revision = restored.registry.revision
check(restored:apply(reconcile).ok and restored.registry.dispatch.actions[queued.action_id].phase == "uncertain"
	and restored.registry.dispatch.actions[queued.action_id].executor_stopped == true, "executor-stopped attestation releases occupancy but never settles the unknown effect")
check(restored.registry.sessions[f.origin.logical_session_id].orchestrator ~= nil, "executor reconciliation does not clear coordinator or start a replacement")
local reconcile_writes = f.memory.writes
local replayed_reconcile = restored:apply(reconcile)
check(replayed_reconcile.ok == false and f.memory.writes == reconcile_writes, "old reconciliation intent cannot write again after its captured revision changed")
local reconciled_reload = host.new_authority(f.memory)
check(reconciled_reload:load().ok, "reconciled current authority reloads")
local reloaded_before, reloaded_writes = runtime.json.encode(reconciled_reload.registry), f.memory.writes
check(reconciled_reload:apply(reconcile).ok == false and f.memory.writes == reloaded_writes
	and runtime.json.encode(reconciled_reload.registry) == reloaded_before, "reload does not revive a historical reconciliation intent or change authority")

-- Corrupt accepted state is rejected as data, never a nil-concatenation exception.
local malformed = clone(t.memory.value)
malformed.dispatch.workers[framed_worker].mailbox_handle = nil
local corrupt_memory = keyed_memory(malformed, true); corrupt_memory.fail = true
local corrupt_authority = host.new_authority(corrupt_memory)
local corrupt_ok, corrupt_result = pcall(function() return corrupt_authority:load() end)
check(corrupt_ok and corrupt_result.code == "state_corrupt", "accepted event without mailbox handle fails closed without throwing")

-- A pre-effect provision refusal retains the startup reservation and exact retry identity.
local capacity = fixture(); capacity:catalog(0)
local reserved = capacity:queue(true)
assert(capacity:apply("claim", { action_id = reserved.action_id, executor = capacity.origin.window_epoch }).ok)
local provision_request = capacity:action(reserved.action_id).request_bytes
for _, malformed_full in {
	{ retryable = true, effect_started = false },
	{ resource = "active_transport", current = -1, limit = 4, retryable = true, effect_started = false },
	{ resource = "active_transport", current = 4.5, limit = 4, retryable = true, effect_started = false },
	{ resource = "active_transport", current = 4, limit = 4, retryable = true },
	{ resource = string.rep("r", 97), current = 4, limit = 4, retryable = true, effect_started = false },
	{ resource = "active transport", current = 4, limit = 4, retryable = true, effect_started = false },
	{ resource = "active_transport", current = 0, limit = 0, retryable = true, effect_started = false },
} do
	local body, problem = protocol.decode_response(frame(capacity:action(reserved.action_id).request, "full", malformed_full), capacity:action(reserved.action_id).request)
	check(body == nil and problem.code == "invalid_schema" and capacity:action(reserved.action_id).phase == "claimed", "malformed full accounting/proof cannot create retry permission")
end
local projected_full = protocol.decode_response(frame(capacity:action(reserved.action_id).request, "full",
	{ resource = "mailboxes", current = 0, limit = 32, retryable = true, effect_started = false }), capacity:action(reserved.action_id).request)
check(projected_full ~= nil, "full may account for projected/staging admission cost without requiring current at limit")
check(capacity:finish(reserved.action_id, "full", { resource = "mailboxes", current = 32, limit = 32, retryable = true, effect_started = false }).code == "backpressure", "provision capacity refusal is explicitly recheckable")
local old_grant = capacity:action(reserved.action_id).claim.grant_id
local old_outcome = capacity:action(reserved.action_id).response_bytes
do
	local malformed_backpressure = clone(capacity.memory.value)
	local retained = malformed_backpressure.dispatch.actions[reserved.action_id]
	retained.response.payload.resource = nil
	retained.response_bytes = frame(retained.request, "full", retained.response.payload)
	local malformed_memory = keyed_memory(malformed_backpressure, true); malformed_memory.fail = true
	local malformed_store = host.new_authority(malformed_memory)
	local valid_call, rejected = pcall(function() return malformed_store:load() end)
	check(valid_call and rejected.code == "state_corrupt", "restored backpressure requires full accounting as well as proof flags")
end
check(capacity:queue(true).code == "orchestrator_slot_occupied" and capacity.authority.registry.dispatch.workers[reserved.worker_id].mailbox_handle == nil, "unbound backpressure retains exclusive coordinator reservation")
local refused_provision_id = reserved.action_id
local retry_provision = capacity:apply("retry", { action_id = refused_provision_id })
check(retry_provision.ok and retry_provision.action_id ~= refused_provision_id and capacity:action(refused_provision_id) == nil, "explicit pre-effect recheck consumes the old issued identity")
reserved.action_id = retry_provision.action_id
check(capacity:apply("claim", { action_id = reserved.action_id, executor = "fixture-window" }).ok
	and capacity:action(reserved.action_id).claim.grant_id ~= old_grant and capacity:action(reserved.action_id).request_bytes ~= provision_request, "retry gets a fresh grant, request and serial")
check(capacity:apply("result", { action_id = reserved.action_id, executor = "fixture-window", grant_id = old_grant, response_bytes = old_outcome }).code == "stale_claim", "late old full outcome cannot settle successor retry grant")
check(capacity:finish(reserved.action_id, "provisioned", { handle = "capacity-mailbox", binding_digest = string.rep("a", 64),
	capabilities = runtime.json.array({ "report-files-v1", "native-ask-v1", "coordinator-control-v1", "project-start-v1" }) }).ok, "exact provision recheck can bind after capacity clears")
local provisioned = capacity.authority.registry.dispatch.workers[reserved.worker_id]
check(capacity:finish(provisioned.launch_action_id, "awaiting_acceptance", { pane_binding = {
	pane_id = "9002", window_key = "", window_epoch = "fixture-window", native_session_id = "7", window_host_id = "local" } }).ok, "startup continues to actual correlated launch after provision retry")
do
	local forged_acceptance = clone(capacity.memory.value)
	forged_acceptance.dispatch.workers[reserved.worker_id].phase = "accepted"
	local forged_memory = keyed_memory(forged_acceptance, true); forged_memory.fail = true
	local forged_store = host.new_authority(forged_memory)
	local valid_call, rejected = pcall(function() return forged_store:load() end)
	check(valid_call and rejected.code == "state_corrupt", "phase-only accepted worker without exact ACCEPTED evidence is quarantined")
	local missing_event = clone(t.memory.value)
	missing_event.dispatch.workers[framed_worker].accepted_event = nil
	local missing_memory = keyed_memory(missing_event, true); missing_memory.fail = true
	local missing_store = host.new_authority(missing_memory)
	local event_call, event_rejection = pcall(function() return missing_store:load() end)
	check(event_call and event_rejection.code == "state_corrupt", "positive receipt sequence and valid pane/mailbox cannot replace exact accepted event evidence")
end

local uncertain = fixture(); local uncertain_worker = uncertain:accepted(false)
assert(uncertain:apply("reply", { worker_id = uncertain_worker }).ok)
local uncertain_part = uncertain:apply("poll", { worker_id = uncertain_worker })
check(uncertain:finish(uncertain_part.action_id, "full", { resource = "active_transport", current = 4, limit = 4 }).code == "effect_uncertain"
	and uncertain.authority.registry.dispatch.workers[uncertain_worker].phase == "accepted", "full without pre-effect proof retains ambiguous publication and durable acceptance")
check(uncertain:finish(uncertain_part.action_id, "full", { resource = "active_transport", current = 4, limit = 4, retryable = false, effect_started = true }).code == "effect_uncertain",
	"paired boolean diagnostics without the exact true/false authorization cannot make an ambiguous effect retryable")
check(uncertain:apply("retry", { action_id = uncertain_part.action_id }).code == "retry_refused", "uncertain publication never gets an automatic or explicit blind retry")
assert(uncertain:finish(uncertain_part.action_id, "published", {}).ok)
local uncertain_manifest = uncertain:apply("poll", { worker_id = uncertain_worker })
local uncertain_reply_part = uncertain.authority.registry.dispatch.workers[uncertain_worker].replies["1"].part
check(uncertain:finish(uncertain_manifest.action_id, "published", { wake_status = "uncertain" }).code == "effect_uncertain"
	and uncertain:action(uncertain_manifest.action_id).phase == "uncertain"
	and uncertain.authority.registry.dispatch.workers[uncertain_worker].replies["1"].part == uncertain_reply_part
	and dispatch.unresolved(uncertain.authority.registry, uncertain.origin.logical_session_id, uncertain.origin.owner_id), "ambiguous native wake retains exact manifest grant without advancing reply or clearing occupancy")
do
	local ack_fixture = fixture(); local id = ack_fixture:launched(false)
	local w = ack_fixture.authority.registry.dispatch.workers[id]
	assert(ack_fixture:apply("intake", { worker_id = id, bytes = ack_fixture:report(id, 1, "ACCEPTED", { assignment_sha256 = w.assignment_sha256 }) }).ok)
	local publication = ack_fixture:apply("poll", { worker_id = id }).action_id
	check(ack_fixture:finish(publication, "published", { wake_status = "uncertain" }).code == "effect_uncertain",
		"uncertain ACK wake remains held")
	local grant, writes = ack_fixture:action(publication).claim.grant_id, ack_fixture.memory.writes
	check(ack_fixture:finish(publication, "published", { wake_status = "uncertain" }).code == "effect_uncertain"
		and ack_fixture.memory.writes == writes, "duplicate uncertain ACK does not write or repeat effect")
	check(ack_fixture:apply("retry", { action_id = publication }).code == "retry_refused"
		and ack_fixture:apply("poll", { worker_id = id, bytes = "watermark" }).code == "operation_pending",
		"unresolved ACK wake cannot retry or compact through a watermark")
	local restored_ack = host.new_authority(ack_fixture.memory)
	check(restored_ack:load().ok and restored_ack.registry.dispatch.actions[publication].claim.grant_id == grant
		and restored_ack.registry.dispatch.workers[id].receipts["1"].publish
		and restored_ack.registry.dispatch.workers[id].accept_pending, "uncertain ACK reload preserves grant and both outboxes")
end
end

if section == nil or section == "receipts" then
-- A full semantic receipt lane releases the completed read, not its immutable source.
local lane = fixture(); local lane_worker = lane:accepted(false)
for seq = 2, 8 do
	assert(lane:apply("intake", { worker_id = lane_worker, bytes = lane:report(lane_worker, seq, "REGISTER", { capabilities = runtime.json.array({ "report-files-v1" }) }) }).ok)
	assert(lane:finish(lane:apply("poll", { worker_id = lane_worker }).action_id, "published", {}).ok)
end
local ninth = lane:report(lane_worker, 9, "REGISTER", { capabilities = runtime.json.array({ "report-files-v1" }) })
local function consume_pages(fx, id, logical_bytes)
	local frames = assert(codec.frame(logical_bytes, "report", fx.authority.registry.dispatch.workers[id]))
	local parts = { frames.manifest }; for _, chunk in frames.chunks do table.insert(parts, chunk) end
	local outcome, action_id
	for _, bytes in parts do
		local read = fx:apply("poll", { worker_id = id }); assert(read.ok)
		action_id = read.action_id
		local page = assert(codec.project_page(bytes, fx:action(action_id).request.selector))
		outcome = fx:finish(action_id, "read", runtime.json.decode(page)); assert(outcome.ok)
	end
	return outcome, action_id
end
local blocked_report, completed_read = consume_pages(lane, lane_worker, ninth)
check(blocked_report.code == "intake_backpressure" and lane:action(completed_read) == nil
	and lane.authority.registry.dispatch.workers[lane_worker].accepted_seq == 8 and lane.authority.registry.dispatch.workers[lane_worker].receipts["9"] == nil, "ninth report retains durable read outcome without applying or ACKing past full receipt lane")
local lw = lane.authority.registry.dispatch.workers[lane_worker]
local lane_watermark = { version = 1, type = "receipt_watermark", mailbox_handle = lw.mailbox_handle, through_seq = 8, receipt_chain_sha256 = lw.receipt_chain }
for _, key in { "logical_session_id", "worker_id", "worker_generation", "launch_request_id", "work_id", "enrolment_token" } do lane_watermark[key] = lw[key] end
local drain = lane:apply("poll", { worker_id = lane_worker, bytes = "watermark" })
check(drain.ok and lane:action(drain.action_id).request.selector.stream == "watermark", "independent watermark settlement remains available after receipt lane backpressure")
local drain_page = assert(codec.project_page(runtime.json.encode(lane_watermark), lane:action(drain.action_id).request.selector))
assert(lane:finish(drain.action_id, "read", runtime.json.decode(drain_page)).ok)
assert(lane:finish(lane:apply("poll", { worker_id = lane_worker }).action_id, "compacted", {}).ok)
check(consume_pages(lane, lane_worker, ninth).code == "bridge_committed"
	and lane.authority.registry.dispatch.workers[lane_worker].accepted_seq == 9, "same unacknowledged ninth report commits after worker watermark frees receipt lane")
local priority_ack = lane:apply("poll", { worker_id = lane_worker, bytes = "watermark" })
check(priority_ack.ok and lane:action(priority_ack.action_id).request.op == "mailbox_publish_ack"
	and lane.authority.registry.dispatch.workers[lane_worker].receipts["9"].publish, "periodic watermark yields to the known unpublished data ACK")
assert(lane:finish(priority_ack.action_id, "published", {}).ok)
local short_read = lane:apply("poll", { worker_id = lane_worker })
check(lane:finish(short_read.action_id, "incomplete", {}).code == "transport_backpressure"
	and lane.authority.registry.dispatch.workers[lane_worker].phase == "accepted", "incomplete read remains recoverable without demoting acceptance")
check(lane:apply("reply", { worker_id = lane_worker }).ok, "accepted worker remains eligible for new replies after incomplete read")

do
	local commit = fixture(); local id = commit:launched(false)
	local binding = commit.authority.registry.dispatch.workers[id]
	local logical_bytes = commit:report(id, 1, "ACCEPTED", { assignment_sha256 = binding.assignment_sha256 })
	local frames = assert(codec.frame(logical_bytes, "report", binding))
	local manifest_request = commit:apply("poll", { worker_id = id })
	local manifest_page = assert(codec.project_page(frames.manifest, commit:action(manifest_request.action_id).request.selector))
	assert(commit:finish(manifest_request.action_id, "read", runtime.json.decode(manifest_page)).ok)
	for index, chunk in frames.chunks do
		local part = commit:apply("poll", { worker_id = id })
		assert(commit:apply("claim", { action_id = part.action_id, executor = "fixture-window" }).ok)
		local page = assert(codec.project_page(chunk, commit:action(part.action_id).request.selector))
		if index == #frames.chunks then commit.memory.fail = true end
		local committed = commit:finish(part.action_id, "read", runtime.json.decode(page))
		if index == #frames.chunks then
			local retained = commit.memory.value.dispatch.workers[id]
			check(committed.code == "persistence_failed" and retained.accepted_seq == 0 and next(retained.receipts) == nil
				and retained.accept_pending == nil and commit:action(part.action_id).phase == "claimed",
				"failed actual SPAWN-page acceptance commit exposes no semantic receipt or ACK/accept outbox and retains exact effect claim")
		else assert(committed.ok) end
	end
end
end

if section == nil or section == "callbacks" then
-- Actual duplicate-block callbacks: a losing rendered intent must refuse without recapture.
local views, contexts = {}, {}
for _, pane in { 11, 12 } do
	contexts[pane] = { pane = pane, render = function() if views[pane] then definition.view(views[pane], contexts[pane]) end end }
	views[pane] = definition.init(contexts[pane], {}, nil)
end
local function token(pane, kind)
	definition.view(views[pane], contexts[pane])
	for id, action in views[pane].actions do if action.kind == kind then return id end end
	error("missing callback action " .. kind)
end
local function click(pane, kind)
	definition.event(views[pane], { ev = "action", act = "control", value = token(pane, kind) }, contexts[pane])
end
local function refused_click(pane, old_token, entry, label)
	local view = views[pane]
	local before, captured = runtime.json.encode(ui_value), runtime.json.encode(entry)
	local writes, marker_writes = ui_memory.writes, ui_memory.marker_writes
	local intent, action = runtime.json.encode(view.operator_intent), view.dispatch_action
	definition.event(view, { ev = "action", act = "control", value = old_token }, contexts[pane])
	check(view.refusal ~= nil and view.refusal.ok == false, label .. ": actual host callback refuses")
	check(runtime.json.encode(ui_value) == before and ui_memory.writes == writes and ui_memory.marker_writes == marker_writes
		and runtime.json.encode(view.operator_intent) == intent and view.dispatch_action == action
		and runtime.json.encode(entry) == captured,
		label .. ": no durable mutation, new intent/effect, or refreshed captured authority fence")
end
local function create_orchestration(pane, name)
	local view = views[pane]
	definition.event(view, { ev = "action", act = "orchestration-create", value = runtime.json.encode({
		source_nonce = view.alias_nonce, request_id = next_id(), name = name,
		authority_namespace = if ui_value then ui_value.authority_namespace else nil,
		expected_revision = if ui_value then ui_value.revision else nil }) }, contexts[pane])
	assert(view.orchestration_result.ok, runtime.json.encode(view.orchestration_result))
end
create_orchestration(11, "Native callback authority")
do
	local sid = views[11].orch_session_id
	local owner = ui_value.sessions[sid].controller
	definition.event(views[11], { ev = "action", act = "authority-operator-command", value = runtime.json.encode({
		source_nonce = views[11].alias_nonce,
		origin = { logical_session_id = sid, owner_id = owner.owner_id, owner_generation = owner.generation,
			host_pane_id = "11", alias_nonce = views[11].alias_nonce, window_key = "", window_epoch = "callback-owner",
			native_session_id = "7", window_host_id = "local" },
		event = { kind = "release_controller", request_id = next_id(), orch_session_id = sid,
			authority_namespace = ui_value.authority_namespace, expected_revision = ui_value.revision,
			expected_owner_id = owner.owner_id, expected_generation = owner.generation } }) }, contexts[11])
	assert(ui_value.sessions[sid].controller == nil, "explicit retirement opens the guarded reconnect slot")
end
views[12].orch_session_id = views[11].orch_session_id
click(11, "advanced-toggle"); click(12, "advanced-toggle")
views[12].notice = "old successful registration outcome"
local losing_token = token(12, "admit")
local losing_entry = views[12].actions[losing_token]
local captured_namespace, captured_revision = losing_entry.authority_namespace, losing_entry.expected_revision
local admission_token = token(11, "admit")
local admission_entry = views[11].actions[admission_token]
local admission_revision, admission_writes = ui_value.revision, ui_memory.writes
definition.view(views[11], contexts[11]); definition.view(views[11], contexts[11])
check(views[11].actions[admission_token] ~= nil and admission_entry.expected_revision == admission_revision,
	"identical real host redraws retain the current admission control and its original authority fence")
definition.event(views[11], { ev = "action", act = "control", value = admission_token }, contexts[11])
check(ui_value.revision == admission_revision + 1 and ui_memory.writes == admission_writes + 1
	and ui_value.sessions[views[11].orch_session_id].controller.pane_binding.alias_nonce == views[11].alias_nonce,
	"ONE actual host click after identical redraw admits the controller without recapture or automatic reclick")
local current_owner = ui_value.sessions[views[11].orch_session_id].controller
local revision, committed_store = ui_value.revision, runtime.json.encode(ui_value)
refused_click(12, losing_token, losing_entry, "changed current owner")
check(views[12].refusal ~= nil and views[12].refusal.ok == false
	and losing_entry.authority_namespace == captured_namespace and losing_entry.expected_revision == captured_revision
	and captured_revision < revision, "losing admission visibly refuses without refreshing its captured intent")
check(ui_value.sessions[views[11].orch_session_id].controller.owner_id == current_owner.owner_id, "stale admission never replaces the current owner")
check(views[12].notice ~= "old successful registration outcome" and type(views[12].notice) == "string" and #views[12].notice > 0
	and views[12].operator_intent == nil and views[12].dispatch_action == nil
	and ui_value.revision == revision and runtime.json.encode(ui_value) == committed_store,
	"stale losing click replaces old success without a new intent, effect, durable mutation or retry")
do
	local old_token = token(11, "assist-intent")
	local entry = views[11].actions[old_token]
	create_orchestration(12, "Unrelated native callback orchestration")
	check(ui_value.sessions[views[11].orch_session_id].controller.owner_id == current_owner.owner_id
		and ui_value.revision > entry.expected_revision, "unrelated registration changes only the authority fence of the retained owner control")
	refused_click(11, old_token, entry, "stale revision")
	local alias = views[11].alias_nonce
	old_token = token(11, "assist-intent"); entry = views[11].actions[old_token]
	views[11].alias_nonce = alias .. "-replacement"
	definition.view(views[11], contexts[11])
	refused_click(11, old_token, entry, "changed alias incarnation")
	views[11].alias_nonce = alias
	definition.view(views[11], contexts[11])
	refused_click(11, old_token, entry, "alias ABA cannot resurrect an old control")
	old_token = token(11, "config-open"); entry = views[11].actions[old_token]
	click(11, "config-open"); click(11, "config-close")
	check(token(11, "config-open") ~= old_token, "removed control returning with the same descriptor gets a new token")
	refused_click(11, old_token, entry, "control removal ABA")
end

-- Real host callbacks publish dispatch metadata and receipts only after the matching commit.
do
	local displayed
	contexts[11].render = function()
		local node = assert(role_node(definition.view(views[11], contexts[11]).main, "orchplus.dispatch"))
		local span = node.p.spans[1]; displayed = runtime.json.decode(if type(span) == "string" then span else span.t)
	end
	local origin = { logical_session_id = views[11].orch_session_id, owner_id = current_owner.owner_id, owner_generation = current_owner.generation,
		host_pane_id = "11", alias_nonce = views[11].alias_nonce, window_key = "", window_epoch = "fixture-window", native_session_id = "7", window_host_id = "local" }
	local proof, selection = empty_peer()
	definition.event(views[11], { ev = "action", act = "qualify-current", value = runtime.json.encode({
		source_nonce = views[11].alias_nonce, origin = origin,
		event = { kind = "qualify_current", request_id = next_id(), authority_namespace = ui_value.authority_namespace, expected_revision = ui_value.revision },
		peer = { proof = proof, selection = selection } }) }, contexts[11])
	assert(ui_value.compatibility ~= nil, "native qualification callback must persist current pair: "
		.. runtime.json.encode(views[11].dispatch_command_result or { notice = views[11].notice, refusal = views[11].refusal }))
	local function command(kind, fields, operator)
		local input = { kind = "dispatch", request_id = next_id(), orch_session_id = origin.logical_session_id,
			authority_namespace = ui_value.authority_namespace, expected_revision = ui_value.revision,
			origin = origin, controller_pane = "9001", command = kind }
		if kind ~= "claim" and kind ~= "spawn_claimed" and kind ~= "result" and kind ~= "lost" then
			local cursor = ((ui_value.dispatch or {}).command_cursors or {})[origin.logical_session_id]
			input.command_seq = (if cursor then cursor.seq else 0) + 1
		end
		for key, value in fields or {} do input[key] = value end
		definition.event(views[11], { ev = "action", act = if operator then "dispatch-operator-command" else "dispatch-command", value = runtime.json.encode(input) }, contexts[11])
		return if operator then views[11].dispatch_command_result
			elseif table.find({ "bridge_control", "bridge_result", "bridge_observe" }, kind) then views[11].dispatch_control_result
			elseif kind == "poll" then views[11].dispatch_poll_result
			else views[11].dispatch_result
	end
	local function observed(bytes)
		return runtime.json.encode({ authority_namespace = ui_value.authority_namespace, expected_revision = ui_value.revision, response_bytes = bytes })
	end
	assert(command("bridge_control", { operation = "admit_session", compatibility = clone(ui_value.compatibility) }).ok)
	local admission = ui_value.sessions[origin.logical_session_id].bridge_control
	local control_request = admission.request
	local control_bytes = frame(control_request, "admitted", { admission_cursor = control_request.admission_seq,
		compatibility = clone(ui_value.compatibility), control = { phase = "open", generation_floor = control_request.generation_floor,
			request_floor = control_request.settled_before, next_request_serial = control_request.next_request_serial,
			last_authority_revision = control_request.authority_revision, binding = clone(origin) } }, nil, "current_admission", control_request.authority_revision)
	assert(command("bridge_result", { query_bytes = admission.request_bytes, response_bytes = control_bytes }).ok)
	local queued_catalog = command("catalog")
	check(displayed.result.action_id == queued_catalog.action_id and displayed.action.phase == "ready", "rendered dispatch result and selected action come from the same completed host transition")
	local granted_catalog = command("claim", { action_id = queued_catalog.action_id, executor = "fixture-window" })
	local retained = ui_value.dispatch.actions[queued_catalog.action_id]
	local response_bytes = frame(retained.request, "catalog", { catalog_version = 2, setup = catalog_setup(0), namespace = "fixture-spawn", host_key = "fixture-host", config_revision = 0, revision = 0, records = runtime.json.array() })
	local event = { ev = "action", act = "dispatch-result/" .. granted_catalog.claim.grant_id .. "/" .. origin.window_epoch, value = observed(response_bytes) }
	definition.event(views[11], event, contexts[11])
	check(displayed.receipt.action_id == queued_catalog.action_id and displayed.receipt.grant_id == granted_catalog.claim.grant_id
		and displayed.receipt.response_sha256 == codec.sha256(response_bytes) and ui_value.dispatch.actions[queued_catalog.action_id] == nil, "host receipt names exact committed response and grant without durable completed action")
	local committed_revision = ui_value.revision
	definition.event(views[11], event, contexts[11])
	check(displayed.result.ok and ui_value.revision == committed_revision, "lost host receipt replays the same observation outcome instead of failing stale claim or writing again")
	local catalog_fixture = fixture(); catalog_fixture:catalog(0)
	local configured = catalog_fixture.authority.registry.dispatch.catalogs[catalog_fixture.origin.logical_session_id]
	local configured_action = command("catalog")
	check(ui_value.dispatch.actions[queued_catalog.action_id] == nil, "new catalog compacts the settled read action")
	local scope_key = "dispatch-action-" .. queued_catalog.action_id
	local captured_node = assert(role_node(definition.view(views[11], contexts[11]).main, "orchplus.dispatch", scope_key))
	local captured_span = captured_node.p.spans[1]
	local captured = runtime.json.decode(if type(captured_span) == "string" then captured_span else captured_span.t)
	check(captured.action == nil and captured.receipt.response_sha256 == codec.sha256(response_bytes),
		"ephemeral delivery scope carries the receipt only, never a completed runnable action")
	local release = { source_nonce = origin.alias_nonce, action_id = queued_catalog.action_id,
		grant_id = granted_catalog.claim.grant_id, response_sha256 = string.rep("0", 64) }
	local release_revision = ui_value.revision
	definition.event(views[11], { ev = "action", act = "dispatch-release-scope", value = runtime.json.encode(release) }, contexts[11])
	check(views[11].scoped_results[queued_catalog.action_id] ~= nil, "wrong response hash cannot release another captured delivery scope")
	release.response_sha256 = codec.sha256(response_bytes)
	definition.event(views[11], { ev = "action", act = "dispatch-release-scope", value = runtime.json.encode(release) }, contexts[11])
	check(ui_value.revision == release_revision and views[11].scoped_results[queued_catalog.action_id] == nil
		and role_node(definition.view(views[11], contexts[11]).main, "orchplus.dispatch", scope_key) == nil,
		"exact window consumption releases only ephemeral completed scope without mutating authority or granting an effect")
	local configured_grant = command("claim", { action_id = configured_action.action_id, executor = "fixture-window" }).claim.grant_id
	local configured_bytes = frame(ui_value.dispatch.actions[configured_action.action_id].request, "catalog", configured)
	definition.event(views[11], { ev = "action", act = "dispatch-result/" .. configured_grant .. "/" .. origin.window_epoch, value = observed(configured_bytes) }, contexts[11])
	local queue_fields = { record_id = "native", record_revision = 0, catalog_revision = 0, prompt = "Explicit callback task",
		cwd = "/fixture", placement = "split", coordinator = true }
	local first = command("queue", queue_fields, true)
	local first_grant = command("claim", { action_id = first.action_id, executor = "fixture-window" }).claim.grant_id
	local failed_start = command("queue", queue_fields, true)
	check(failed_start.code == "orchestrator_slot_occupied" and displayed.command_result.request_id == failed_start.request_id
		and displayed.command_result.command == "queue" and displayed.action.action_id == first.action_id,
		"failed second start exposes correlated operator refusal independently of first worker action")
	local stale_ack = token(11, "dispatch-acknowledge")
	local provision_request = ui_value.dispatch.actions[first.action_id].request
	local provision_result = frame(provision_request, "provisioned", catalog_fixture:peer_payload({ request = provision_request }, "provisioned", {
		handle = "callback-mailbox", binding_digest = string.rep("a", 64),
		capabilities = runtime.json.array({ "report-files-v1", "native-ask-v1", "coordinator-control-v1", "project-start-v1" }) }))
	definition.event(views[11], { ev = "action", act = "dispatch-result/" .. first_grant .. "/" .. origin.window_epoch, value = observed(provision_result) }, contexts[11])
	command("poll", { worker_id = first.worker_id })
	check(displayed.command_result.request_id == failed_start.request_id and not displayed.command_result.acknowledged
		and ui_value.dispatch.actions[first.action_id] == nil,
		"background result and poll preserve visible refusal while original worker progresses")
	local newer_failure = command("queue", queue_fields, true)
	definition.event(views[11], { ev = "action", act = "control", value = stale_ack }, contexts[11])
	check(displayed.command_result.request_id == newer_failure.request_id and not displayed.command_result.acknowledged,
		"stale acknowledgement cannot dismiss a newer command refusal")
	click(11, "dispatch-acknowledge")
	check(displayed.command_result.request_id == newer_failure.request_id and displayed.command_result.acknowledged,
		"explicit acknowledgement dismisses only its correlated refusal")
	local superseded_failure = command("queue", queue_fields, true)
	local fresh_command = command("catalog", nil, true)
	check(fresh_command.ok and displayed.command_result.request_id == fresh_command.request_id
		and displayed.command_result.request_id ~= superseded_failure.request_id and displayed.command_result.ok,
		"fresh explicit operator command supersedes prior refusal without changing ownership")
	check(ui_value.sessions[origin.logical_session_id].orchestrator.work_id == first.work_id,
		"refusal acknowledgement and supersession never create a second coordinator")
	do
		local worker = ui_value.dispatch.workers[first.worker_id]
		local launch_id = worker.launch_action_id
		local grant = command("claim", { action_id = launch_id, executor = origin.window_epoch })
		assert(grant.ok, runtime.json.encode(grant))
		local witness = command("spawn_claimed", { action_id = launch_id, grant_id = grant.claim.grant_id,
			spawn_namespace = "fixture-spawn", claim_nonce = "callback-launch-claim" })
		assert(witness.ok, runtime.json.encode(witness))
		local request = ui_value.dispatch.actions[launch_id].request
		local binding = { pane_id = "9002", window_key = origin.window_key, window_epoch = origin.window_epoch,
			native_session_id = origin.native_session_id, window_host_id = origin.window_host_id }
		local bytes = frame(request, "awaiting_acceptance", { record_id = request.record_id, record_revision = request.record_revision,
			effective_identity = { provider = "omp", identity_status = "configured_not_verified" },
			capabilities = runtime.json.array(clone(worker.capabilities)), prompt_delivery = "submitted_not_accepted", pane_binding = binding })
		definition.event(views[11], { ev = "action", act = "dispatch-result/" .. grant.claim.grant_id .. "/" .. origin.window_epoch,
			value = observed(bytes) }, contexts[11])
		assert(ui_value.dispatch.workers[first.worker_id].pane_binding ~= nil, runtime.json.encode(displayed.result))
		local function observe(native_state)
			local before = ui_memory.writes
			command("observe", { worker_id = first.worker_id, pane_binding = binding, native_state = native_state })
			local native = ui_value.dispatch.workers[first.worker_id].workflow.native
			assert(ui_memory.writes == before + 1 and native and native.state == native_state,
				"native gate observation was not committed: " .. tostring(views[11].notice))
		end
		observe("waiting-input")
		local function gate_control()
			definition.view(views[11], contexts[11])
			for id, entry in views[11].actions do
				if entry.kind == "operator-intent" and entry.request.command == "recheck_gate"
					and entry.request.worker_id == first.worker_id then return id, entry end
			end
			error("missing actual native-input gate control")
		end
		local gate_token, entry = gate_control()
		local captured = runtime.json.encode(entry)
		local durable, writes = runtime.json.encode(ui_value), ui_memory.writes
		definition.view(views[11], contexts[11]); definition.view(views[11], contexts[11])
		definition.event(views[11], { ev = "action", act = "control", value = gate_token }, contexts[11])
		local intent = views[11].operator_intent
		check(intent ~= nil and intent.request.gate_id == entry.request.gate_id
			and intent.request.gate_revision == entry.request.gate_revision
			and intent.request.expected_revision == entry.expected_revision and runtime.json.encode(entry) == captured
			and runtime.json.encode(ui_value) == durable and ui_memory.writes == writes,
			"ONE actual gate click after identical redraw publishes only the exact originally fenced window intent")
		definition.event(views[11], { ev = "action", act = "operator-intent-done",
			value = runtime.json.encode({ source_nonce = intent.source_nonce, serial = intent.serial }) }, contexts[11])
		check(views[11].operator_intent == nil, "exact consuming-window acknowledgement clears the one-shot gate intent")
		local rechecked = command("recheck_gate", { gate_id = entry.request.gate_id, gate_revision = entry.request.gate_revision }, true)
		assert(rechecked.ok, runtime.json.encode(rechecked))
		observe("idle")
		refused_click(11, gate_token, entry, "changed native gate revision/removal")
		observe("waiting-input")
		local replacement = gate_control()
		check(replacement ~= gate_token, "reappearing native-input gate allocates a new current control")
		refused_click(11, gate_token, entry, "native gate ABA")
	end
	local previous_receipt = clone(displayed.receipt)
	local pending_catalog = command("catalog")
	local pending_grant = command("claim", { action_id = pending_catalog.action_id, executor = "fixture-window" })
	local failed_bytes = frame(ui_value.dispatch.actions[pending_catalog.action_id].request, "catalog", { catalog_version = 2, setup = catalog_setup(0), namespace = "fixture-spawn", host_key = "fixture-host", config_revision = 0, revision = 0, records = runtime.json.array() })
	local original_set = fake.kv.set
	fake.kv.set = function() error("injected native observation commit failure") end
	definition.event(views[11], { ev = "action", act = "dispatch-result/" .. pending_grant.claim.grant_id .. "/" .. origin.window_epoch, value = observed(failed_bytes) }, contexts[11])
	fake.kv.set = original_set
	check(displayed.result.code == "persistence_failed" and displayed.receipt.response_sha256 == previous_receipt.response_sha256
		and ui_value.dispatch.actions[pending_catalog.action_id].phase == "claimed", "failed host observation persistence exposes no new commit receipt")
end
end

if section == nil or section == "intent_buttons" then
-- Window-side controls are native buttons: a click publishes a one-shot operator intent that the
-- owning window consumes. Isolated real host block plus two real window VMs.
local store_value, idef, now = nil, nil, 1000
local itern = table.clone(fake)
local intent_memory = keyed_memory()
itern.kv = { get = intent_memory.get, set = function(key, value)
	intent_memory.set(key, value)
	if key == "authority_state" then store_value = intent_memory.value end
end }
itern.block = { define = function(id, value) if id == "orchestrator" then idef = value end end }
itern.now = function() return now end
itern.pane = { list = function() return { { pane = 11, program = "orchplus.orchestrator" } } end }
local host_timers = {}
itern.timer = function(_, fn) table.insert(host_timers, fn); return { cancel = function() end } end
local imodules = {}
local function iload(name, base)
	name = (base or "") .. name:gsub("^%./", "")
	if imodules[name] then return imodules[name] end
	local chunk = assert(loadstring(runtime.fs.read(root .. "/" .. name .. ".luau"), "intent-" .. name))
	local dir = name:match("^(.*/)")
	setfenv(chunk, setmetatable({ tern = itern, require = function(n) return iload(n, dir) end }, { __index = environment }))
	local value = chunk(); imodules[name] = value; return value
end
iload("host")
local ctx = { pane = 11, render = function() end }
local view = idef.init(ctx, {}, nil)
local function press(match, label)
	idef.view(view, ctx)
	for token, entry in view.actions do
		if match(entry) then idef.event(view, { ev = "action", act = "control", value = token }, ctx); return entry end
	end
	error("missing rendered control: " .. label)
end
local function kind(name) return function(entry) return entry.kind == name end end
local function operator(command) return function(entry) return entry.kind == "operator-intent" and entry.request.command == command end end
idef.event(view, { ev = "action", act = "orchestration-create", value = runtime.json.encode({
	source_nonce = view.alias_nonce, request_id = "native-intent-orchestration", name = "Native intent fixture" }) }, ctx)
assert(view.orchestration_result.ok, runtime.json.encode(view.orchestration_result))
press(kind("advanced-toggle"), "Advanced owner controls")
local sid = view.orch_session_id
local function saved_policy() return dispatch.policy(store_value, sid) end
local function keyed(node, key)
	if type(node) ~= "table" then return nil end
	if type(node.p) == "table" and node.p.key == key then return node end
	for _, child in node.c or {} do local found = keyed(child, key); if found then return found end end
	return nil
end
local sent, toasts, picks, drop_acks, picker_steps = {}, {}, {}, false, {}
local host_row = { id = "local", state = "connected", panes = { 11 } }
local controller_row = { pane = 11, block = "orchplus.orchestrator", tab = 1 }
local function window_cx(key)
	local session = {}
	function session:pane(id) return if id == 11 then controller_row else nil end
	function session:view(id) return if id == 11 then {} else nil end
	function session:panes() return { controller_row } end
	function session:sessions() return { { id = 7, tabs = { 1 } } } end
	function session:surface(pane, options)
		if pane ~= 11 then return nil end
		local node = keyed(idef.view(view, ctx).main, options.root:sub(6))
		if not node then return nil end
		node = clone(node); node.id = options.root
		return { surface = { role = "plugin.orchplus.orchestrator" }, main = node }
	end
	function session:event(pane, ev)
		assert(pane == 11, "intents act only on their scanned controller pane")
		table.insert(sent, { window = key, act = ev.act, value = ev.value })
		if ev.act == "operator-intent-done" and drop_acks then return end
		idef.event(view, ev, ctx)
	end
	local context
	context = { session = session, sessions = { current = function() return { id = 7, host = "local" } end },
		hosts = { current = function() return host_row end, list = function() return { host_row } end },
		window_key = function() return key end, toast = function(_, _, _, message) table.insert(toasts, { window = key, message = message }) end,
		pick = function(_, options)
			table.insert(picks, { window = key, placeholder = options.placeholder })
			local step = table.remove(picker_steps, 1)
			return { next = function(_, callback)
				if not step then return end
				local choice
				for _, item in options.items do if step(item) then choice = item; break end end
				assert(choice, "native settings picker did not offer the expected operation")
				callback(choice, nil, table.clone(context))
			end }
		end }
	return context
end
local palette = {}
local function window_vm()
	local wtern = table.clone(itern)
	local registered = {}
	wtern.timer = function() return { cancel = function() end } end
	wtern.command = function(def) registered[def.id] = def end; wtern.files = { button = function() end }; wtern.on = function() end
	wtern.chrome = { status = function() end } -- the window registers its status segment at load
	wtern.route = { link = function() end }
	local chunk = assert(loadstring(runtime.fs.read(root .. "/window.luau"), "intent-window"))
	setfenv(chunk, setmetatable({ tern = wtern, require = iload }, { __index = environment }))
	local api = chunk()
	palette[api] = registered
	return api
end
local first_api, second_api = window_vm(), window_vm()
local first, second = window_cx(""), window_cx("second-window")
picker_steps = { function(item) return item.continue_controller == true end }
palette[first_api].continue_controller.run(first)
table.clear(sent); table.clear(picks); table.clear(toasts)
local function commands(window, name)
	local n = 0
	for _, row in sent do
		if row.window == window and row.act == "dispatch-operator-command" and runtime.json.decode(row.value).command == name then n += 1 end
	end
	return n
end
local function sent_by(window) local n = 0; for _, row in sent do if row.window == window then n += 1 end end; return n end

-- A clicked button publishes one bounded intent; the owning window runs it and settles it.
press(operator("pause"), "Pause new work")
local published = assert(view.operator_intent, "a dispatch button publishes an operator intent")
check(published.version == 1 and published.kind == "dispatch" and published.source_nonce == view.alias_nonce
	and type(published.serial) == "string" and published.request.command == "pause"
	and keyed(idef.view(view, ctx).main, "operator-intent").p.role == "orchplus.intent",
	"the intent is keyed, role-tagged and carries the exact stored request")
first_api.intents(first)
check(saved_policy().paused and commands("", "pause") == 1 and view.operator_intent == nil, "the owning window runs the clicked pause once and settles its intent")
local origin
for _, row in sent do if row.act == "dispatch-operator-command" then origin = runtime.json.decode(row.value).origin end end

-- A saved policy whose Save control would have been a >8 KiB URL (formerly dropped silently).
local function ids(prefix, n)
	local list = {}
	for i = 1, n do table.insert(list, prefix .. string.rep("x", 92) .. string.format("%03d", i)) end
	return list
end
local seeded = { initial_dispatch_records = ids("i", 24), worker_rollover_records = ids("w", 24), coordinator_rollover_records = ids("c", 8) }
local cursor = store_value.dispatch.command_cursors[sid]
idef.event(view, { ev = "action", act = "dispatch-operator-command", value = runtime.json.encode({ kind = "dispatch", request_id = "intent-seed-policy",
	authority_namespace = store_value.authority_namespace, expected_revision = store_value.revision,
	orch_session_id = sid, origin = origin, controller_pane = "11", command = "policy", command_seq = cursor.seq + 1, policy = seeded }) }, ctx)
check(#saved_policy().initial_dispatch_records == 24 and #saved_policy().coordinator_rollover_records == 8, "large routing allowlists are saved")

-- A second window showing the same controller, with another origin, leaves the intent silently.
press(operator("resume"), "Resume scheduling")
second_api.intents(second); second_api.intents(second)
check(sent_by("second-window") == 0 and #toasts == 0 and view.operator_intent ~= nil and saved_policy().paused,
	"a window whose origin does not own the controller never acts, settles or toasts")
first_api.intents(first)
check(not saved_policy().paused and commands("", "resume") == 1 and view.operator_intent == nil and sent_by("second-window") == 0,
	"only the owning window runs the intent")

-- A retained, unsettled native control is consumed once, even across repeated scans.
press(operator("pause"), "Pause before retained-intent check"); first_api.intents(first)
check(saved_policy().paused, "the explicit scheduling pause commits")
drop_acks = true -- The host never sees settlement: the intent stays published.
press(operator("resume"), "Resume scheduling")
for _ = 1, 4 do first_api.intents(first); second_api.intents(second); idef.view(view, ctx) end
check(not saved_policy().paused and commands("", "resume") == 2 and sent_by("second-window") == 0 and view.operator_intent ~= nil,
	"the owning native window consumes a retained scheduling intent once without replay")

-- An intent no window settles expires visibly on the host and never runs later.
drop_acks = false
now += 31000
for _, callback in table.clone(host_timers) do callback() end
	check(view.operator_intent == nil, "an unsettled intent expires after its bound")
first_api.intents(first)
check(commands("", "resume") == 2, "an expired intent never runs")

-- Continuation and the recovery guide: a host-block click names no window (clients of one window key
-- also share its shown session and focus), so a window that is not the continued origin leaves these
-- intents silently too; the palette commands run in the window that invoked them.
local function since(window, start) local n = 0; for i = start + 1, #sent do if sent[i].window == window then n += 1 end end; return n end
local start, picked = #sent, #picks
palette[second_api].continue_controller.run(second)
	check(#picks == picked + 1 and picks[#picks].window == "second-window"
		and #sent == start, "ORCH+ Continue controller in this window opens its attested picker only in the invoking window")

-- Assistance after first use: the host names the continued origin's window, so another window showing
-- the same controller leaves Inspect, Recheck, Reveal owner and Stop assistance silently too.
local function settled_by(window, from)
	local n = 0
	for i = from + 1, #sent do if sent[i].window == window and sent[i].act == "operator-intent-done" then n += 1 end end
	return n
end
for _, assist in { "inspect", "recheck", "reveal", "stop" } do
	local from, toasted_before, picked_before = #sent, #toasts, #picks
	press(function(entry) return entry.kind == "assist-intent" and entry.request.kind == assist and entry.request.target == "controller" end, assist)
	second_api.intents(second); second_api.intents(second)
	check(since("second-window", from) == 0 and #toasts == toasted_before and #picks == picked_before and view.operator_intent ~= nil,
		assist .. " assistance: a window that is not the continued origin never takes, settles, prompts or toasts")
	first_api.intents(first); first_api.intents(first)
	check(view.operator_intent == nil and settled_by("", from) == 1 and since("second-window", from) == 0,
		assist .. " assistance: the continued origin's window runs the clicked button once")
end
end

-- Exercise the real WindowCx timer/operator-intent consumer, including a bounded nested-status
-- overflow and the fresh status fence needed after rechecking pre-effect capacity.
local function window_consumer(mode)
	local clock = 1000
	local stale_result_mode = mode:match("^stale_result") ~= nil
	local ack_mode = mode == "ack" or mode == "ack_uncertain" or mode == "ack_terminal" or mode == "stale_witness" or mode == "scoped_poll" or stale_result_mode
	local launch_mode = mode == "background_launch" or mode == "background_adjacent"
	local fresh_mode = mode == "foreground_bootstrap"
	local wf = fixture(if ack_mode then function()
		return { now_ms = clock, mono_ms = clock, epoch = "driver-wake-host" }
	end else nil, { defer_admission = true, default_limits = fresh_mode, passive = launch_mode })
	local timers, events = {}, {}
	local selected, last_result, last_receipt, bridge_bytes, deferred_outcome, command_result, driver_result, control_result, poll_result
	-- Native peer-store revisions are independent of ORCH authority observation fences.
	local peer_revision = 1000000
	-- The controller block's published one-shot operator intent (host.luau publishes it on click).
	local intent, intent_serial = nil, 0
	local intent_completions = {}
	local notice
	local notices, commands_seen = {}, {}
	-- Held modes keep SPAWN's retained outcome pending until the test releases it.
	local held = mode == "suspend" or mode == "auto_reconcile" or mode == "auto_reconcile_bounded" or mode == "auto_reconcile_all" or mode == "window_bookkeeping" or mode == "background_settlement"
	local held_success, dropped_delivery
	-- auto_reconcile_all keeps one retained SPAWN outcome per request, as SPAWN's registry does.
	local retained_outcomes, successes = {}, {}
	local peer_session, peer_requests = nil, {}
	local function session_progress()
		if not peer_session then return nil end
		local entries = {}
		for request_id, entry in peer_requests do
			local request = entry.request
			if request.logical_session_id ~= wf.origin.logical_session_id or request.admission_seq ~= peer_session.admission_seq then continue end
			local outcome = retained_outcomes[request_id]
				or (if deferred_outcome and deferred_outcome.request_id == request_id then deferred_outcome else nil)
			table.insert(entries, string.format("%.0f", request.request_serial) .. ":" .. request_id .. ":"
				.. request.action_id .. ":" .. request.op .. ":" .. (if outcome then outcome.status else entry.status))
		end
		table.sort(entries)
		local control = table.clone(peer_session.control)
		control.last_authority_revision = nil -- Another observation is not delivery progress.
		return codec.sha256(string.format("%.0f", peer_session.admission_seq) .. "\n"
			.. codec.dispatch_source_bytes(control) .. "\n" .. table.concat(entries, "\n"))
	end
	local scoped_results = {}
	-- duplicate_claim queues claims like a lagging host; slow_receipt withholds host commit receipts.
	local lag_claims, lagged, hold_results, held_results = false, {}, false, 0
	local claim_attempts = {}
	local catalog_sends, launch_deliveries = 0, 0
	local provision_bytes, rejected_bytes, queued_worker
	local fresh_launch_read = false
	local status_observations = runtime.json.array()
	local ack_sends, ack_id = 0, nil
	local wake_id, wake_request, wake_sends, native_state = nil, nil, 0, "working"
	local scoped_commit, host_deliveries = nil, 0
	local late_launch_event, pending_poll, refused_poll, poll_projection_fault
	local refused_delivery, delivery_fault, result_deliveries = nil, nil, {}
	local hide_scope = false
	local settlement_fault = mode == "consumed_scope"
	local poll_commands = {}
	local chained = mode == "chain" or mode == "late" or mode == "reconcile_chain" or mode == "refused_chain" or mode == "auto_reconcile_worker" or ack_mode
	local window_tern = table.clone(fake)
	window_tern.now = function() return clock end
	local palette_commands = {}
	window_tern.command = function(def) palette_commands[def.id] = def end; window_tern.files = { button = function() end }
	window_tern.chrome = { status = function() end } -- the window registers its status segment at load
	window_tern.route = { link = function() end }
	window_tern.timer = function(_, fn) table.insert(timers, fn); return {} end
	local local_host = { id = "local", state = "connected", panes = { 9001 } }
	local panes = { [9001] = { pane = 9001, block = "orchplus.orchestrator", tab = 1 } }
	local native_session, native_focus, focus_changes = 7, 9001, 0
	local delayed_pick
	local moves = 0
	if mode == "background_settlement" or launch_mode or fresh_mode then
		table.insert(local_host.panes, 9003)
		panes[9003] = { pane = 9003, kind = "terminal", tab = 3 }
	end
	local control_bytes, control_responses, lane_bytes = {}, {}, {}
	local relay_lanes, relay_frames, relay_releases, relay_serial, bind_serial = {}, {}, {}, 0, 0
	local relay_endpoint, relay_boot, peer_boot = "dispatch-fixture-relay", "dispatch-orch-boot", "dispatch-spawn-boot"
	local bridge_lane, observed_panes
	local function relay_render(lane_id)
		local lane = assert(relay_lanes[lane_id])
		lane.peer_boot = peer_boot
		relay_frames[lane_id] = {
			current = runtime.json.encode({ protocol = 2, phase = "stable", spawn_namespace = "fixture-spawn",
				authority_namespace = wf.authority.registry.authority_namespace, authority_revision = peer_revision,
				compatibility = clone(wf.authority.registry.compatibility), session_progress = session_progress(),
				control_response = control_responses[lane_id] }),
			response = control_bytes[lane_id] or (if bridge_lane == lane_id then bridge_bytes else lane_bytes[lane_id]),
		}
		for kind, bytes in relay_frames[lane_id] do
			local old = lane.messages[kind]
			if not old or old.bytes ~= bytes then
				relay_serial += 1
				lane.messages[kind] = { id = "dispatch-relay-" .. tostring(relay_serial), incarnation = peer_boot,
					route = "spawn." .. kind, binding = relay_endpoint .. ":" .. lane_id, bytes = bytes }
			end
		end
	end
	local function relay_metadata()
		local lanes, releases = {}, {}
		for lane_id, lane in relay_lanes do
			relay_render(lane_id)
			local messages = {}
			for kind, proof in lane.messages do local public = clone(proof); public.bytes = nil; messages[kind] = public end
			table.insert(lanes, { lane_id = lane_id, bind_id = lane.bind_id, peer_boot = lane.peer_boot, messages = messages })
		end
		for _, proof in relay_releases do table.insert(releases, clone(proof)) end
		return { schema = 1, peer = "spawn", host_pane_id = "42", source_nonce = wf.origin.alias_nonce,
			relay_endpoint = relay_endpoint, relay_boot = relay_boot, lanes = lanes, releases = releases }
	end
	local function keyed_surface(node, key)
		if type(node) ~= "table" then return nil end
		if node.p and node.p.key == key then return node end
		for _, child in node.c or {} do local found = keyed_surface(child, key); if found then return found end end
		return nil
	end
	if ack_mode or launch_mode then
		table.insert(local_host.panes, 9002)
		panes[9002] = { pane = 9002, kind = "agent", block = if launch_mode then nil else "agent", tab = if mode == "background_adjacent" then 2 else 1 }
	end
	local session = {}
	function session:pane(id) return panes[id] end
	function session:panes() local rows = {}; for _, pane in panes do table.insert(rows, pane) end; return rows end
	function session:sessions() return { { id = 7, tabs = { 1, 2 } }, { id = 8, tabs = { 3 } } } end
	function session:focused() return native_focus end
	function session:surface(pane, options)
		local block, role, bytes
		if hide_scope and pane == 9001 then return nil end
		if pane == 9001 and options.root == "main.operator-intent" and intent == nil then return nil end
		if pane ~= 9001 then return nil end
		do
			block = "orchplus.orchestrator"
			local projection = state.project(wf.authority.registry)
			local scope = options.root:match("^main%.dispatch%-action%-(.+)$") or options.root:match("^main%.dispatch%-request%-(.+)$")
				or options.root:match("^main%.dispatch%-draft%-(.+)$")
			projection.dispatch = dispatch.project(wf.authority.registry, wf.origin.logical_session_id, wf.origin.alias_nonce, scope or selected, scoped_results)
			local view = { pane = 42, alias_nonce = wf.origin.alias_nonce, orch_session_id = wf.origin.logical_session_id,
				action_serial = 0, dispatch_action = selected, dispatch_result = last_result, dispatch_receipt = last_receipt,
				dispatch_command_result = command_result, dispatch_driver_result = driver_result, dispatch_control_result = control_result,
				dispatch_poll_result = poll_result,
				spawn_relay = relay_metadata(), spawn_relay_frames = relay_frames, session_panes = observed_panes,
				scoped_results = scoped_results, notice = notice,
				operator_intent = intent }
			local rendered = keyed_surface(load("views").render(view, projection, "ready"), options.root:sub(6))
			if not rendered then return nil end
			role = rendered.p.role
			local span = rendered.p.spans[1]; bytes = if type(span) == "string" then span else span.t
			if settlement_fault and scoped_commit and role == "orchplus.dispatch" then
				local projected = runtime.json.decode(bytes)
				projected.authority_namespace = "unrelated-authority"
				if projected.control then
					local request = runtime.json.decode(projected.control.request_bytes)
					request.authority_namespace = "unrelated-authority"
					projected.control.request_bytes = runtime.json.encode(request)
				end
				bytes = runtime.json.encode(projected)
			end
			if delivery_fault and role == "orchplus.dispatch" then
				local projected = runtime.json.decode(bytes)
				if projected.result and projected.result.action_id == ack_id then
					if delivery_fault == "lost" then projected.result = nil
					elseif delivery_fault == "unrelated" then projected.result.request_id = "unrelated-result"
					elseif delivery_fault == "kind" then projected.result.command = "spawn_claimed"
					elseif delivery_fault == "grant" then projected.result.grant_id = "unrelated-grant" end
				end
				if delivery_fault == "grant_change" and projected.action and projected.action.action_id == ack_id then
					projected.action.claim.grant_id = "replacement-grant"
				end
				if delivery_fault == "withdrawal" and projected.receipt and projected.receipt.withdrawal_request_id then
					projected.receipt.worker_id = "unrelated-worker"
				end
				bytes = runtime.json.encode(projected)
			end
			if poll_projection_fault and poll_result and role == "orchplus.dispatch" then
				-- Negative consumer-boundary cases corrupt only this rendered copy; the
				-- reducer's state and genuine single volatile poll receipt remain untouched.
				local projected = runtime.json.decode(bytes)
				if poll_projection_fault == "request" then
					projected.poll_result.request_id = "unrelated-" .. poll_result.request_id
				else projected.poll_result.worker_id = "unrelated-worker" end
				bytes = runtime.json.encode(projected)
			end
		end
		return { surface = { role = "plugin." .. block }, main = { id = options.root, k = "text", p = { role = role, spans = { bytes } } } }
	end
	function session:event(pane, ev)
		if ev.act == "spawn_relay" then
			assert(pane == 9001, "peer traffic uses the actual ORCH pane")
			local outer = runtime.json.decode(ev.value)
			assert(outer.schema == 1 and outer.source_nonce == wf.origin.alias_nonce
				and outer.relay_endpoint == relay_endpoint and outer.relay_boot == relay_boot, "exact relay source binding")
			if outer.act == "bind" then
				assert(relay_lanes[outer.lane_id] == nil, "one bind per logical lane")
				bind_serial += 1
				relay_lanes[outer.lane_id] = { origin = runtime.json.decode(outer.bytes),
					bind_id = "dispatch-bind-" .. tostring(bind_serial), messages = {} }
				relay_render(outer.lane_id); return
			elseif outer.act == "ack" then
				assert(relay_lanes[outer.lane_id] and outer.peer_boot == peer_boot, "read ACK retains its lane incarnation"); return
			elseif outer.act == "release" then
				local lane = assert(relay_lanes[outer.lane_id])
				assert(outer.peer_boot == lane.peer_boot and outer.bytes == "{}", "release targets the exact peer incarnation")
				relay_releases[outer.lane_id] = { lane_id = outer.lane_id, peer_boot = peer_boot }
				relay_lanes[outer.lane_id], relay_frames[outer.lane_id] = nil, nil
				control_bytes[outer.lane_id], control_responses[outer.lane_id], lane_bytes[outer.lane_id] = nil, nil, nil
				return
			elseif outer.act == "release_ack" then
				local proof = assert(relay_releases[outer.lane_id])
				assert(outer.peer_boot == proof.peer_boot and outer.bytes == "{}", "release ACK consumes only positive proof")
				relay_releases[outer.lane_id] = nil; return
			elseif outer.act == "rebind" then
				local lane = assert(relay_lanes[outer.lane_id])
				assert(quota.digest(runtime.json.decode(outer.bytes)) == quota.digest(lane.origin), "rebind retains the original lane origin")
				bind_serial += 1; lane.bind_id = "dispatch-bind-" .. tostring(bind_serial); lane.messages = {}
				control_bytes[outer.lane_id], control_responses[outer.lane_id], lane_bytes[outer.lane_id] = nil, nil, nil
				relay_render(outer.lane_id); return
			end
			assert(relay_lanes[outer.lane_id] and outer.peer_boot == peer_boot, "peer operation retains the live logical lane")
			pane, ev = outer.lane_id, { ev = "action", act = outer.act, value = outer.bytes }
		end
		if pane == 9001 then
			if ev.act == "operator-intent-done" then
				local input = runtime.json.decode(ev.value)
				check(ev.id == "main.operator-intent" and intent ~= nil and input.serial == intent.serial, "window settles exactly the consumed intent")
				local key = input.source_nonce .. "|" .. input.serial
				intent_completions[key] = (intent_completions[key] or 0) + 1
				intent = nil
			elseif ev.act == "dispatch-command" or ev.act == "dispatch-operator-command" then
				local command = runtime.json.decode(ev.value)
				if lag_claims and command.command == "claim" then table.insert(lagged, ev); return end
				if mode == "stale_claim" and command.command == "claim" then
					table.insert(claim_attempts, { request = clone(command), revision = wf.authority.registry.revision })
				end
				table.insert(commands_seen, { command = command.command, action_id = command.action_id })
				wf.origin = clone(command.origin)
				local refuse_poll = mode == "scoped_poll" and command.command == "poll" and refused_poll == nil and late_launch_event ~= nil
				if mode == "scoped_poll" and command.command == "poll" then table.insert(poll_commands, clone(command)) end
				if refuse_poll then
					must(wf:apply("pause").ok)
					must(wf:apply("resume").ok) -- Real owner commits after the immutable background poll was captured.
				end
				local withdrawal_ids = {}
				if command.command == "cancel_work" then
					for id, a in wf.authority.registry.dispatch.actions do
						if a.worker_id == command.worker_id and a.claim == nil then withdrawal_ids[id] = true end
					end
				end
				if mode == "held_withdrawal" and command.command == "claim" then wf.memory.fail = true end
				local writes = wf.memory.writes
				local response = table.clone(wf.authority:apply(command))
				wf.memory.fail = false
				response.request_id = command.request_id; response.command = command.command
				response.action_id = response.action_id or command.action_id
				response.grant_id = command.grant_id or (if response.claim then response.claim.grant_id else nil)
				if command.command == "poll" and ev.act == "dispatch-command" then
					response.worker_id = command.worker_id
					poll_result = response -- One replaceable live-view receipt, including actionless refusals/no-ops.
				end
				if ev.act == "dispatch-command" and response.ok and response.code == "mailbox_idle" and response.action_id == nil then return end
				local workflow_only = table.find({ "observe", "policy", "pause", "resume", "answer", "cancel_gate", "recheck_gate", "sweep" }, command.command) ~= nil
				local control_only = table.find({ "bridge_control", "bridge_result", "bridge_observe" }, command.command) ~= nil
				if control_only then control_result = response end
				if ev.act == "dispatch-operator-command" then
					command_result = response
					if not workflow_only and not control_only then driver_result = response end
				end
				if (ev.act == "dispatch-command" or response.ok) and not workflow_only and not control_only then last_result = response end
				if response.ok and response.action_id then selected = response.action_id end
				if response.worker_id then queued_worker = response.worker_id end
				if response.action_id then
					local retained = scoped_results[response.action_id] or {}
					retained.result = response; scoped_results[response.action_id] = retained
				end
				if response.ok and command.command == "cancel_work" then
					for id in withdrawal_ids do
						if scoped_results[id] and wf:action(id) == nil then
							scoped_results[id] = { result = response, receipt = { action_id = id, worker_id = command.worker_id,
								withdrawal_request_id = command.request_id, authority_namespace = command.authority_namespace,
								logical_session_id = command.orch_session_id } }
						end
					end
				end
				if refuse_poll then
					check(response.code == "stale_revision" and response.action_id == nil and wf.memory.writes == writes,
						"an actually stale background poll is refused without an invented action or registry write")
					refused_poll = response; poll_projection_fault = "request"
					session:event(9001, late_launch_event)
				end
				if mode == "scoped_poll" and command.command == "poll" and response.ok and response.action_id and pending_poll == nil then
					local pending = wf:action(response.action_id)
					if pending and pending.request.op == "mailbox_publish_ack" then
						assert(late_launch_event and pending.worker_id == command.worker_id)
						pending_poll = { action_id = response.action_id, worker_id = command.worker_id,
							request_id = command.request_id, result = response }
						poll_projection_fault = "request"
						-- A real completed launch delivery arrives after the poll queued its next
						-- action, replacing only the shared result before the new driver sees it.
						session:event(9001, late_launch_event)
					end
				end
			elseif ev.act == "dispatch-select" then
				local input = runtime.json.decode(ev.value); selected = input.action_id; last_result = nil; command_result = nil
				if scoped_results[input.action_id] then scoped_results[input.action_id].result = nil end
			elseif ev.act == "dispatch-release-scope" then
				scoped_results[runtime.json.decode(ev.value).action_id] = nil
			elseif ev.act:sub(1, 16) == "dispatch-result/" then
				host_deliveries += 1
				if hold_results then held_results += 1; return end -- The host has not processed it yet.
				local delivery = runtime.json.decode(ev.value)
				local response_bytes = delivery.response_bytes
				assert(delivery.authority_namespace == wf.authority.registry.authority_namespace and type(delivery.expected_revision) == "number",
					"native driver delivers its original captured authority fence alongside exact peer bytes")
				local outer = runtime.json.decode(response_bytes:sub(#codec.DISPATCH.prefix + 1))
				local a
				for _, candidate in wf.authority.registry.dispatch.actions do
					if candidate.request.request_id == outer.request_id and candidate.claim
						and candidate.claim.grant_id == ev.act:match("^dispatch%-result/([^/]+)/")
						and ev.act:match("/([^/]+)$") == wf.origin.window_epoch then a = candidate; break end
				end
				if not a then
					if mode == "consumed_scope" or mode == "auto_reconcile_all" then return end -- Lose ephemeral receipts, never the durable result commit.
					local body = runtime.json.decode(outer.body_json)
					local current = wf.authority.registry.sessions[wf.origin.logical_session_id]
					assert(current and current.admitted and body.authority_namespace == wf.authority.registry.authority_namespace
						and body.logical_session_id == wf.origin.logical_session_id and body.admission_seq == current.admission_seq
						and body.request_serial < current.next_request_serial and wf:action(body.action_id) == nil,
						"absent callback must prove a current consumed issued identity")
					last_result = { ok = true, code = "already_consumed", action_id = body.action_id }
					last_receipt = { action_id = body.action_id, grant_id = ev.act:match("^dispatch%-result/([^/]+)/"),
						response_sha256 = codec.sha256(response_bytes) }
					scoped_results[body.action_id] = { result = last_result, receipt = last_receipt }
					return
				end
				if mode == "suspend" and not dropped_delivery then
					dropped_delivery = true
					return -- Lose the first host event; only the captured observation may replay.
				end
				if chained and a.request.op == "launch" then
					launch_deliveries += 1
					if (mode == "chain" or mode == "refused_chain") and launch_deliveries == 1 then
						rejected_bytes = ev.value; bridge_bytes = provision_bytes
						return -- Lose the first host event, and replace the bridge's visible response.
					end
					if mode == "chain" or mode == "refused_chain" then
						if fresh_launch_read then
							check(response_bytes == runtime.json.decode(rejected_bytes).response_bytes,
								"fresh owner observation retains the exact rejected launch outcome, not a repeated effect")
						else check(ev.value == rejected_bytes, "lost host event replays captured rejection bytes, not a new native request") end
					end
				end
				if stale_result_mode and a.request.op == "mailbox_publish_ack" and refused_delivery == nil then
					assert(wf:apply("pause").ok) -- A real intervening authority commit, not a fabricated refusal.
					refused_delivery = { event = clone(ev), grant_id = a.claim.grant_id, request_bytes = a.request_bytes }
					delivery_fault = mode:match("^stale_result_(.+)$")
				end
				local input = wf:event("result", { action_id = a.request.action_id, executor = a.claim.executor, grant_id = a.claim.grant_id,
					response_bytes = response_bytes, authority_namespace = delivery.authority_namespace, expected_revision = delivery.expected_revision })
				input.request_id = protocol.result_request_id(a.claim.grant_id, wf.origin.window_epoch, delivery)
				local writes = wf.memory.writes
				last_result = table.clone(wf.authority:apply(input))
				if last_result.code == "stale_revision" then
					check(wf.memory.writes == writes and wf:action(a.request.action_id) ~= nil,
						"a stale immutable observation writes nothing and cannot consume its live grant")
				end
				-- As host.luau action(): a committed result carries its deterministic observation request ID.
				last_result.request_id = input.request_id; last_result.action_id = a.request.action_id; last_result.grant_id = a.claim.grant_id; last_result.command = "result"
				if stale_result_mode and a.request.op == "mailbox_publish_ack" then
					table.insert(result_deliveries, { event = clone(ev), result = clone(last_result) })
				end
				if last_result.ok then last_receipt = { action_id = a.request.action_id, grant_id = a.claim.grant_id, response_sha256 = codec.sha256(response_bytes) } end
				local retained = scoped_results[a.request.action_id] or {}
				retained.result = last_result
				if last_result.ok then retained.receipt = last_receipt end
				scoped_results[a.request.action_id] = retained
				if mode == "scoped_poll" and a.request.op == "launch" and last_result.ok then late_launch_event = clone(ev) end
				if (mode == "consumed_scope" or mode == "auto_reconcile_all") and last_result.ok and wf:action(a.request.action_id) == nil then
					scoped_commit = clone(a.request)
					last_result, last_receipt = nil, nil
					scoped_results[a.request.action_id] = nil
				end
				if ack_mode and a.request.op == "launch" and last_result.ok then
					local w = wf.authority.registry.dispatch.workers[queued_worker]
					assert(wf:apply("intake", { worker_id = queued_worker,
						bytes = wf:report(queued_worker, 1, "ACCEPTED", { assignment_sha256 = w.assignment_sha256 }) }).ok)
				end
			elseif ev.act == "recovery-steps" then
				-- Guided reload recovery checklist (display only) after an explicit continuation.
			elseif ev.act == "dispatch-notice" then
				local input = runtime.json.decode(ev.value)
				assert(input.source_nonce == wf.origin.alias_nonce and type(input.message) == "string" and #input.message <= 1024)
				-- The window's own start-up mailbox-inventory probe is answered `uncertain` by this fixture (it owns no mailbox
				-- filesystem) and says so once per window. That is not a dispatch notice; keep it out of the dispatch notice log.
				if input.message:sub(1, 41) ~= "Communication files could not be checked " then
					notice = input.message; table.insert(notices, input.message)
				end
			elseif ev.act == "config-panes" then observed_panes = runtime.json.decode(ev.value)
			elseif ev.act == "upgrade-window-readback" then
				local readback = runtime.json.decode(ev.value)
				assert(readback.version == 5 and readback.source_nonce == wf.origin.alias_nonce, "window observes the actual v5 source")
			else error("Unexpected ORCH+ callback " .. tostring(ev.act)) end
			return
		end
		assert(relay_lanes[pane], "peer commands target a logical lane, never a transport pane")
		if bridge_lane then lane_bytes[bridge_lane] = bridge_bytes end
		local request = runtime.json.decode(ev.value)
		control_responses[pane] = nil
		if ev.act ~= "status" and ev.act ~= "owner_status" then peer_revision += 1 end
		if ev.act == "owner_status" or ev.act == "admit_session" or ev.act == "reconcile_session" then
			local control = wf.authority.registry.sessions[wf.origin.logical_session_id]
			local payload = { admission_cursor = control.admission_seq, compatibility = clone(wf.authority.registry.compatibility),
				control = { phase = "open", generation_floor = request.generation_floor or control.generation_floor,
					request_floor = request.settled_before or control.request_floor,
					next_request_serial = request.next_request_serial or control.next_request_serial,
					last_authority_revision = request.authority_revision or control.last_authority_revision,
					binding = clone(if request.control_origin then request.control_origin.binding else wf.origin) } }
			if ev.act == "reconcile_session" then
				payload.control.request_floor = request.settled_before
				payload.outstanding = { after_serial = 0, through_serial = 0, next_after_serial = 0, complete = true, entries = runtime.json.array() }
			end
			control_bytes[pane] = frame(request, if ev.act == "owner_status" then "owner_status" elseif ev.act == "admit_session" then "admitted" else "reconciled",
				payload, nil, "current_admission", request.authority_revision or control.last_authority_revision)
			if ev.act ~= "owner_status" then
				peer_session = { admission_seq = request.admission_seq, control = clone(payload.control) }
				for request_id, entry in peer_requests do
					if entry.request.request_serial < request.settled_before
						or table.find(request.consumed, entry.request.request_serial) then peer_requests[request_id] = nil end
				end
				control_responses[pane] = { request_id = request.request_id, action_id = request.action_id,
					spawn_namespace = "fixture-spawn", session_progress = session_progress() }
			end
			relay_render(pane)
			return
		end
		control_bytes[pane] = nil
		-- `events` is the ordered log of SPAWN effect requests. The window's read-only mailbox-inventory probe
		-- runs on its own schedule before any effect; it is answered below but is not an effect request.
		if ev.act ~= "mailbox_inventory" then table.insert(events, { op = ev.act, bytes = ev.value }) end
		if ev.act == "catalog" then
			catalog_sends += 1
			local success = frame(request, "catalog", { catalog_version = 2, setup = catalog_setup(0), namespace = "fixture-spawn", host_key = "fixture-host", config_revision = 0, revision = 0, records = runtime.json.array() })
			if held then
				held_success = protocol.decode_response(success, request)
				bridge_bytes = frame(request, "pending")
				deferred_outcome = protocol.decode_response(bridge_bytes, request)
				if mode == "auto_reconcile_all" then retained_outcomes[request.request_id] = deferred_outcome; successes[request.request_id] = held_success end
			elseif mode == "expired_authorization" then
				-- SPAWN stages the first send behind a window challenge; the rechecked send succeeds.
				bridge_bytes = if catalog_sends == 1 then frame(request, "pending", { authorization_required = true }) else success
				deferred_outcome = protocol.decode_response(bridge_bytes, request)
			elseif mode == "capacity_resume" or mode == "duplicate_claim" or mode == "stale_claim" or mode == "slow_receipt" or mode == "consumed_scope" then
				bridge_bytes = success; deferred_outcome = assert(protocol.decode_response(success, request))
			elseif mode == "oversize" then bridge_bytes = if catalog_sends == 1 then frame(request, "pending") else success
			elseif catalog_sends == 1 then bridge_bytes = frame(request, "full", { resource = "catalog_capacity", current = 1, limit = 1, retryable = true, effect_started = false })
			else deferred_outcome = protocol.decode_response(success, request) end -- Leave old full visible until the ordered status fence.
		elseif ev.act == "mailbox_inventory" then
			-- This transport fixture owns framed outcomes, not SPAWN's mailbox filesystem.
			-- An unreadable inventory is uncertainty, never a fabricated zero-file cleanup.
			bridge_bytes = frame(request, "uncertain", nil, { code = "inventory_unavailable",
				message = "The fixture peer has no mailbox-filesystem observation." })
		elseif ev.act == "mailbox_provision" then
			bridge_bytes = frame(request, "provisioned", wf:peer_payload(wf:action(request.action_id), "provisioned", {
				handle = "mailbox-fixture", binding_digest = string.rep("a", 64),
				capabilities = runtime.json.array({ "report-files-v1", if mode == "ack_terminal" or stale_result_mode then "worker-poll-v1" else "native-ask-v1", "coordinator-control-v1", "project-start-v1" }) }))
			provision_bytes = bridge_bytes
			deferred_outcome = assert(protocol.decode_response(provision_bytes, request))
			if mode == "late" then
				deferred_outcome = protocol.decode_response(provision_bytes, request)
				bridge_bytes = frame(request, "pending", { authorization_required = true })
			elseif mode == "auto_reconcile_worker" then
				held_success = protocol.decode_response(provision_bytes, request)
				bridge_bytes = frame(request, "pending", { authorization_required = true })
				deferred_outcome = protocol.decode_response(bridge_bytes, request)
			end
		elseif ev.act == "launch" then
			if mode == "stale_witness" then
				bridge_bytes = frame(request, "pending", { authorization_required = true })
				deferred_outcome = assert(protocol.decode_response(bridge_bytes, request))
			elseif ack_mode or launch_mode then
				local a = wf:action(request.action_id)
				assert(wf:apply("spawn_claimed", { action_id = request.action_id, grant_id = a.claim.grant_id,
					spawn_namespace = "fixture-spawn", claim_nonce = "native-window-claim-" .. next_id() }).ok)
				bridge_bytes = frame(request, "awaiting_acceptance", wf:peer_payload(a, "awaiting_acceptance", { pane_binding = {
					pane_id = "9002", window_key = "", window_epoch = request.origin_binding.window_epoch, native_session_id = "7", window_host_id = "local" } }))
			else bridge_bytes = frame(request, "rejected", nil, { code = "binding_mismatch", message = "Exact fresh SPAWN authorization challenge required" }) end
			retained_outcomes[request.request_id] = assert(protocol.decode_response(bridge_bytes, request))
		elseif ev.act == "mailbox_publish_ack" then
			ack_sends += 1; ack_id = request.action_id
			bridge_bytes = frame(request, "published", if mode == "ack_terminal" or stale_result_mode then nil else { wake_status = "awaiting_window",
				wake_effect_started = false, wake_target_request_id = request.request_id, wake_target_action_id = request.action_id })
			deferred_outcome = protocol.decode_response(bridge_bytes, request)
		elseif ev.act == "accept" then
			bridge_bytes = frame(request, "accepted", wf:peer_payload(wf:action(request.action_id), "accepted"))
		elseif ev.act == "native_wake" then
			wake_sends += 1; wake_id = request.action_id; wake_request = clone(request)
			local action = wf:action(wake_id)
			assert(wf:apply("spawn_claimed", { action_id = wake_id, grant_id = action.claim.grant_id, spawn_namespace = "fixture-spawn",
				claim_nonce = "separate-native-wake-" .. next_id() }).ok)
			bridge_bytes = frame(request, "pending")
			deferred_outcome = assert(protocol.decode_response(bridge_bytes, request))
		elseif ev.act == "status" then
			if mode == "chain" or mode == "refused_chain" then fresh_launch_read = true end
			if ack_mode and wake_request then
				check(request.target_request_id == wake_request.request_id and request.target_request_serial == wake_request.request_serial,
					"notification reconciliation queries the separately issued native-wake identity, never the consumed publication")
			end
			bridge_bytes = if mode == "oversize" then frame(request, "rejected", nil, { code = "oversize" })
				else frame(request, "found", { outcome = retained_outcomes[request.target_request_id] or deferred_outcome })
			local observed = retained_outcomes[request.target_request_id] or deferred_outcome
			table.insert(status_observations, runtime.json.array({ clock, if observed then observed.status else "-" }))
		else error("Unexpected SPAWN operation " .. tostring(ev.act)) end
		if request.request_serial ~= nil then
			local outcome = protocol.decode_response(bridge_bytes, request)
			if not outcome and deferred_outcome and deferred_outcome.request_id == request.request_id then outcome = deferred_outcome end
			peer_requests[request.request_id] = { request = clone(request), status = if outcome then outcome.status else "pending" }
		end
		bridge_lane = pane; lane_bytes[pane] = bridge_bytes
		relay_render(pane)
	end
	local cx = { session = session, sessions = { current = function() return { id = native_session, host = "local" } end,
		switch = function() error("background settlement must never switch sessions") end },
		agents = { list = function() return if ack_mode or launch_mode then { { pane = 9002, state = native_state } } else {} end },
		hosts = { list = function() return { local_host } end, current = function() return local_host end },
		window_key = function() return "" end, toast = function(_cx, _level, _title, detail) notice = detail end,
		new_block = function() error("dispatch carrier must not create a native transport pane") end }
	cx.layout = {
		focus = function() focus_changes += 1; error("background settlement must never change focus") end,
		move = function(_, target, source, direction, reveal)
			assert(launch_mode and target == 9002 and source == 9001 and direction == "left", "only compose the exact returned coordinator")
			moves += 1
			if reveal.focus then focus_changes += 1; native_focus = target end
			panes[target].tab = panes[source].tab
			return true
		end,
		resize = function() end,
	}
	cx.prompt = function() error("effect-pipeline fixture does not invoke the conversation composer") end
	cx.pick = function(_, options)
		local chosen
		for _, item in options.items do
			if item.continue_controller == true
				or ((mode == "held_withdrawal" or mode == "capacity_withdrawal" or mode == "background_settlement") and item.confirm == true) then
				chosen = item; break
			end
		end
		return { next = function(_promise, callback)
			if mode == "background_settlement" and chosen and chosen.confirm then delayed_pick = { callback = callback, choice = chosen }; return end
			callback(chosen, nil, table.clone(cx))
		end }
	end
	local window_chunk = assert(loadstring(runtime.fs.read(root .. "/window.luau"), "dispatch-window-consumer"))
	local native_api
	local function window_require(name)
		local module = load(name)
		if name:gsub("^%./", "") ~= "conversation_window" then return module end
		-- Observe the real creation adapter without mocking control/connect behavior.
		local adapter = table.clone(module)
		adapter.new = function(api) native_api = api; return module.new(api) end
		return adapter
	end
	setfenv(window_chunk, setmetatable({ tern = window_tern, require = window_require }, { __index = environment })); local api = window_chunk()
	-- The owner clicks a dispatch button: its host block publishes the exact request as a one-shot
	-- intent, which this window's observation consumer runs once.
	local function click(command, fields)
		local request = { command = command, source_nonce = wf.origin.alias_nonce, orch_session_id = wf.origin.logical_session_id, action_id = selected }
		request.authority_namespace = wf.authority.registry.authority_namespace; request.expected_revision = wf.authority.registry.revision
		if command == "queue" then
			local event = wf:event("queue", { record_id = "native", record_revision = 0, catalog_revision = 0,
				cwd = "/fixture", placement = "split", prompt = "Explicit native effect-pipeline fixture task",
				coordinator = if fields and fields.coordinator ~= nil then fields.coordinator else not ack_mode,
				presentation = if fields then fields.presentation else nil })
			local queued = table.clone(wf.authority:apply(event))
			queued.request_id, queued.command = event.request_id, event.command
			if not queued.ok then command_result = queued; return end
			assert(queued.action_id and queued.worker_id, runtime.json.encode(queued))
			selected, queued_worker = queued.action_id, queued.worker_id
			last_result, command_result, driver_result = queued, queued, queued
			scoped_results[selected] = { result = queued }
			request.command, request.action_id = "execute", selected
			request.expected_revision = wf.authority.registry.revision
		end
		if command == "poll" then request.worker_id = queued_worker end
		for key, value in fields or {} do request[key] = value end
		intent_serial += 1
		intent = { version = 1, source_nonce = wf.origin.alias_nonce, serial = "fixture-intent-" .. tostring(intent_serial), kind = "dispatch", request = request }
		api.intents(table.clone(cx))
	end
	local function tick(elapsed)
		clock += elapsed or 500; local callback = assert(table.remove(timers, 1), "native timer must remain scheduled")
		callback(table.clone(cx)) -- Fresh callback context, never a captured click context.
	end
	local function count_events(op) local n = 0; for _, e in events do if e.op == op then n += 1 end end; return n end
	local function count_commands(name, action_id)
		local n = 0
		for _, c in commands_seen do if c.command == name and (action_id == nil or c.action_id == action_id) then n += 1 end end
		return n
	end
	local function check_window(ok, why)
		if not ok then
			local action = wf:action(selected)
			local worker = if queued_worker then wf.authority.registry.dispatch.workers[queued_worker] else nil
			local grant = if action and action.claim then action.claim.grant_id elseif last_result then last_result.grant_id else nil
			-- Compact prefix survives the native runner's existing failure-text bound.
			-- a=operation/phase/response; ack=action/grant match; o=operator code/correlation;
			-- r=result code/action match; rev=current/captured; w=worker phase/reason.
			why = "state=" .. runtime.json.encode({
				a = runtime.json.array({ if action then action.request.op else "-", if action then action.phase else "-",
					if action and action.response then action.response.status else "-" }),
				ack = runtime.json.array({ last_receipt ~= nil and last_receipt.action_id == selected,
					last_receipt ~= nil and grant ~= nil and last_receipt.grant_id == grant }),
				d = if deferred_outcome then deferred_outcome.status else "-", ld = launch_deliveries,
				clock = clock, reads = status_observations,
				n = { catalog = catalog_sends, provision = count_events("mailbox_provision"), launch = count_events("launch"), status = count_events("status") },
				o = runtime.json.array({ if command_result then command_result.code else "-",
					command_result ~= nil and driver_result ~= nil and command_result.request_id == driver_result.request_id }),
				r = runtime.json.array({ if last_result then last_result.code else "-", last_result ~= nil and last_result.action_id == selected }),
				rev = runtime.json.array({ wf.authority.registry.revision,
					if rejected_bytes then runtime.json.decode(rejected_bytes).expected_revision else -1 }),
				w = runtime.json.array({ if worker then worker.phase else "-", if worker and worker.reason then worker.reason.code else "-" }),
			}) .. " " .. why
		end
		check(ok, why)
	end
	if fresh_mode then
		check(wf.authority.registry.dispatch.command_cursors[wf.origin.logical_session_id] == nil
			and native_api.snapshot(cx, 9001).command_cursor == nil,
			"fresh host-created controller has no cursor in either durable registry or actual native window projection")
		native_session, native_focus = 8, 9003
		local refused = wf.origin.alias_nonce .. "|fixture-intent-" .. tostring(intent_serial + 1)
		click("bridge_admit")
		check(intent == nil and intent_completions[refused] == 1 and count_commands("bridge_control") == 0
			and wf.authority.registry.dispatch.command_cursors[wf.origin.logical_session_id] == nil,
			"displaced unbound human admission is durably refused exactly once instead of becoming background authority")
		native_session, native_focus = 7, 9001
		api.intents(cx); api.intents(cx)
		check(intent_completions[refused] == 1 and count_commands("bridge_control") == 0
			and native_api.snapshot(cx, 9001).command_cursor == nil,
			"repeated native intent-consumer passes after returning never replay or re-complete the unbound intent")
		local captured = native_api.origin(cx, 9001)
		assert(captured, "fresh creation captures the actual foreground origin")
		native_api.control(cx, 9001, "bridge_admit", captured)
		local cursor = native_api.snapshot(cx, 9001).command_cursor
		check(cursor and cursor.controller_pane == "9001" and quota.digest(cursor.origin) == quota.digest(captured),
			"real creation control adapter commits its first admission cursor with the exact captured source/origin")
		native_session, native_focus = 8, 9003
		for _ = 1, 12 do
			tick()
			if wf.authority.registry.sessions[wf.origin.logical_session_id].admitted then break end
		end
		check_window(count_commands("bridge_control") == 1
			and wf.authority.registry.sessions[wf.origin.logical_session_id].admitted == true
			and api.owned_origin(cx, 9001, captured),
			"first creation admission settles through strict captured background ownership after user selection changes")
		check(focus_changes == 0 and native_session == 8 and native_focus == 9003,
			"fresh creation admission, background settlement and unbound refusal do not mutate native selection or focus")
		return
	end
	assert(palette_commands.continue_controller).run(table.clone(cx))
	assert(command_result and command_result.ok, "initial continuation failed: " .. tostring(notice) .. "; result=" .. runtime.json.encode(command_result))
	-- The continuation guide watches for this exact receipt on its next observation; give it that turn before the
	-- next command replaces the receipt, or it reports "continuation result is not yet confirmed" after 5 s awake.
	tick()
	click("pause")
	assert(command_result and command_result.ok, "initial pause failed: " .. tostring(notice) .. "; result=" .. runtime.json.encode(command_result))
	must(wf:control("admit_session").ok)
	local admitted = wf.authority.registry.sessions[wf.origin.logical_session_id]
	peer_session = { admission_seq = admitted.admission_seq, control = { phase = "open",
		generation_floor = admitted.generation_floor, request_floor = admitted.request_floor,
		next_request_serial = admitted.next_request_serial, last_authority_revision = admitted.last_authority_revision,
		binding = clone(wf.origin) } }
	click("resume")
	assert(command_result and command_result.ok, "initial resume failed: " .. tostring(notice) .. "; result=" .. runtime.json.encode(command_result))
	-- Let the production controller confirm its baseline peer state before the scenario creates
	-- deliberately delayed commands. This is real control I/O, not a refreshed action fence.
	for _ = 1, 8 do tick() end
	assert(wf.authority.registry.sessions[wf.origin.logical_session_id].bridge_control == nil,
		"baseline connection did not settle: " .. tostring(notice) .. "; result=" .. runtime.json.encode(control_result))
	if mode == "stale_intent" then
		local function stamp(origin)
			return { window_key = origin.window_key, window_epoch = origin.window_epoch,
				native_session_id = origin.native_session_id, window_host_id = origin.window_host_id }
		end
		local function publish(window, source_nonce)
			intent_serial += 1
			local nonce = source_nonce or wf.origin.alias_nonce
			intent = { version = 1, source_nonce = nonce, serial = "fixture-intent-" .. tostring(intent_serial), kind = "dispatch",
				window = window, request = { command = "pause", source_nonce = nonce, orch_session_id = wf.origin.logical_session_id,
					authority_namespace = wf.authority.registry.authority_namespace, expected_revision = wf.authority.registry.revision } }
			return nonce .. "|" .. intent.serial
		end
		local pauses = count_commands("pause")
		local refused = publish(stamp(wf.origin))
		-- Recreate the real window VM, preserving the host's exact cursor and intent.
		table.clear(timers); api = window_chunk()
		check(native_api.snapshot(cx, 9001).command_cursor.origin.window_epoch == intent.window.window_epoch,
			"reload fixture preserves the source's actual obsolete cursor/stamped input")
		api.intents(cx); api.intents(cx)
		check(intent == nil and intent_completions[refused] == 1 and count_commands("pause") == pauses,
			"current-session stale-origin input is durably refused exactly once, not just remembered by its VM")
		table.clear(timers); api = window_chunk()
		palette_commands.continue_controller.run(cx)
		must(command_result and command_result.ok, command_result)
		api.intents(cx); api.intents(cx); tick()
		check(intent_completions[refused] == 1 and count_commands("pause") == pauses,
			"another reload and explicit Continue cannot execute a human intent already refused in its old origin")
		for _, fault in { "window", "epoch", "alias" } do
			local window = stamp(wf.origin)
			if fault == "window" then window.window_key = "another-window"
			elseif fault == "epoch" then window.window_epoch = "unrelated-incarnation" end
			local key = publish(window, if fault == "alias" then "different-source-alias" else nil)
			api.intents(cx); api.intents(cx)
			check(intent ~= nil and intent_completions[key] == nil and count_commands("pause") == pauses,
				"refusal cannot consume or execute an input with an unrelated native " .. fault .. " stamp")
		end
		return
	end
	if launch_mode then
		wf:catalog(0)
		click("queue", { coordinator = true, presentation = if mode == "background_adjacent" then "coordinator_adjacent" else "background" })
		assert(queued_worker ~= nil and selected ~= nil and wf:action(selected) ~= nil,
			"native launch fixture did not queue a real worker/action: " .. runtime.json.encode(command_result))
		local launch_id
		for _ = 1, 12 do
			tick()
			local worker = wf.authority.registry.dispatch.workers[queued_worker]
			launch_id = worker and worker.launch_action_id
			if launch_id and wf:action(launch_id) and wf:action(launch_id).phase == "ready" then break end
		end
		check_window(launch_id ~= nil and wf:action(launch_id).phase == "ready" and wf:action(launch_id).claim == nil,
			"provisioning creates a real unissued native-agent launch before its first claim")
		if mode == "background_launch" then
			native_session, native_focus = 8, 9003
			for _ = 1, 10 do tick(5000) end
			check_window(wf:action(launch_id).phase == "ready" and wf:action(launch_id).claim == nil
				and count_commands("claim", launch_id) == 0 and count_commands("lost", launch_id) == 0 and count_events("launch") == 0,
				"unsupported inactive native creation stays truly unissued beyond 30 seconds without claim, relay or manufactured uncertainty")
			check(notice and notice:find("targeted native agent API", 1, true), "unissued launch exposes its genuine targeted-creation prerequisite")
			native_session = 7
		end
		for _ = 1, 12 do tick(); if count_events("launch") == 1 then break end end
		check_window(count_events("launch") == 1 and count_commands("claim", launch_id) == 1,
			"returning to the exact source session starts its original authorization once")
		native_session, native_focus = 8, 9003
		for _ = 1, 12 do tick(); if wf:action(launch_id) == nil then break end end
		check_window(wf:action(launch_id) == nil and count_events("launch") == 1 and count_commands("lost", launch_id) == 0,
			"late foreground launch result settles in the background without replay or an immediately expired deadline")
		check(focus_changes == 0 and native_focus == 9003
			and (mode ~= "background_adjacent" or moves == 1),
			"late coordinator-adjacent composition preserves the selected session's actual focus")
		return
	end
	if mode == "held_withdrawal" or mode == "capacity_withdrawal" then
		wf:catalog(0)
		local occupied = {}
		if mode == "capacity_withdrawal" then
			for _ = 1, 4 do
				local queued = wf:apply("catalog"); assert(queued.ok)
				assert(wf:apply("claim", { action_id = queued.action_id, executor = wf.origin.window_epoch }).ok)
				table.insert(occupied, queued.action_id)
			end
		end
		click("queue", { coordinator = false })
		local worker, waiting = queued_worker, selected
		-- Five seconds is an awake callback interval, not a suspension. Exercise the full
		-- bounded retry policy without ten idle renders for every capacity retry.
		for _ = 1, (if mode == "capacity_withdrawal" then 512 else 8) do
			tick(if mode == "capacity_withdrawal" then 5000 else 500); if api.bookkeeping().held_actions == 1 then break end
		end
		check(api.bookkeeping().held_actions == 1 and api.bookkeeping().watched == 1
			and wf:action(waiting).claim == nil and wf:action(waiting).request_bytes == nil and count_events("mailbox_provision") == 0,
			mode .. ": real refused unissued work is held without native execution")
		if mode == "capacity_withdrawal" then
			check(count_commands("claim", waiting) == 121, "capacity hold follows all bounded real claim refusals, without skipping retries or issuing an effect")
		end
		hide_scope = true
		for _ = 1, 4 do tick() end
		check(api.bookkeeping().held_actions == 1 and api.bookkeeping().watched == 1, mode .. ": unreadable surface never proves withdrawal")
		hide_scope = false
		click("cancel_work", { worker_id = worker })
		check(command_result.ok and wf:action(waiting) == nil and wf.authority.registry.dispatch.workers[worker] == nil,
			mode .. ": the exact explicit cancellation really removes unissued ready work; " .. runtime.json.encode({
				response = command_result, action_present = wf:action(waiting) ~= nil,
				worker_present = wf.authority.registry.dispatch.workers[worker] ~= nil,
				cancel_commands = count_commands("cancel_work"), notices = notices,
			}))
		delivery_fault = "withdrawal"
		for _ = 1, 4 do tick() end
		check(api.bookkeeping().held_actions == 1 and api.bookkeeping().watched == 1,
			mode .. ": another worker's withdrawal receipt cannot reclaim the held action")
		delivery_fault = nil
		for _ = 1, 8 do tick() end
		check(api.bookkeeping().held_actions == 0 and api.bookkeeping().watched == 0 and scoped_results[waiting] == nil
			and count_events("mailbox_provision") == 0, mode .. ": correlated withdrawal reclaims held/watch/receipt bookkeeping without an effect")
		return
	end
	if chained then wf:catalog(0) end
	if chained then
		click("queue")
		local startup_driver_result = runtime.json.encode(driver_result)
		check((ack_mode or wf.authority.registry.sessions[wf.origin.logical_session_id].orchestrator ~= nil) and #events == 0,
			"chained startup commits its worker and any coordinator reservation before native provisioning")
		if stale_result_mode then
			for _ = 1, 30 do tick(); if refused_delivery then break end end
			check_window(refused_delivery ~= nil and result_deliveries[1].result.code == "stale_revision"
				and wf:action(ack_id).phase == "claimed" and ack_sends == 1,
				mode .. ": the actual native ACK publication is refused only at its captured host commit fence")
			local reads = count_events("status")
			if delivery_fault then
				for _ = 1, 8 do tick() end
				check(wf:action(ack_id).phase == "claimed" and ack_sends == 1 and count_events("status") == reads
					and count_commands("lost", ack_id) == 0, mode .. ": lost, unrelated, wrong-kind or changed-grant evidence stays held")
				for _, delivery in result_deliveries do
					check(delivery.event.value == refused_delivery.event.value, mode .. ": no unconfirmed observation refreshes the original envelope")
				end
				delivery_fault = nil
			end
			for _ = 1, 24 do tick(); if wf:action(ack_id) == nil then break end end
			local completed = result_deliveries[#result_deliveries]
			check_window(wf:action(ack_id) == nil and completed.result.ok and ack_sends == 1
				and count_commands("claim", ack_id) == 1 and count_commands("lost", ack_id) == 0
				and count_events("status") > reads and not wf.authority.registry.dispatch.workers[queued_worker].receipts["1"].publish,
				mode .. ": exact stale refusal starts a fresh retained read and drains the original ACK without another native effect")
			check(completed.result.request_id ~= result_deliveries[1].result.request_id
				and runtime.json.decode(completed.event.value).expected_revision > runtime.json.decode(refused_delivery.event.value).expected_revision
				and runtime.json.decode(completed.event.value).response_bytes == runtime.json.decode(refused_delivery.event.value).response_bytes
				and completed.event.act == refused_delivery.event.act,
				mode .. ": fresh read produces a distinct current host observation while preserving outcome, grant and incarnation")
			return
		end
		if mode == "stale_witness" then
			for _ = 1, 12 do
				tick()
				if count_events("launch") == 1 then break end
			end
			local launch_id = selected
			local launch = wf:action(launch_id)
			check_window(launch ~= nil and launch.request.op == "launch" and launch.phase == "claimed"
				and count_events("launch") == 1, "native worker launch waits for its exact SPAWN witness")
			local grant, request = launch.claim.grant_id, clone(launch.request)
			local witness_fields = { action_id = launch_id, grant_id = grant, spawn_namespace = "fixture-spawn",
				claim_nonce = "native-window-stale-witness-" .. next_id() }
			local stale = wf:event("spawn_claimed", witness_fields)
			click("pause"); click("resume") -- Real authority progress after capture, before witness delivery.
			local writes = wf.memory.writes
			session:event(9001, { ev = "action", id = "main.dispatch", act = "dispatch-command", value = runtime.json.encode(stale) })
			check(last_result.command == "spawn_claimed" and last_result.code == "stale_revision"
				and last_result.request_id == stale.request_id and last_result.action_id == launch_id and last_result.grant_id == grant
				and wf.memory.writes == writes and wf:action(launch_id).claim.grant_id == grant,
				"typed exact stale witness is a positive no-write refusal, not result consumption or a replacement grant")
			tick(); tick() -- The original driver observes the refusal before a fresh witness exists.
			check_window(wf:action(launch_id).phase == "claimed" and wf:action(launch_id).claim.grant_id == grant
				and count_events("launch") == 1 and count_commands("claim", launch_id) == 1 and count_commands("lost", launch_id) == 0,
				"stale witness observation does not abandon or reissue the original native worker effect")
			local fresh = wf:event("spawn_claimed", witness_fields)
			check(fresh.request_id ~= stale.request_id and fresh.expected_revision > stale.expected_revision,
				"positive refusal permits a distinct fresh witness observation, never mutation of the stale request")
			session:event(9001, { ev = "action", id = "main.dispatch", act = "dispatch-command", value = runtime.json.encode(fresh) })
			must(last_result.ok, last_result)
			bridge_bytes = frame(request, "awaiting_acceptance", wf:peer_payload(wf:action(launch_id), "awaiting_acceptance", { pane_binding = {
				pane_id = "9002", window_key = "", window_epoch = request.origin_binding.window_epoch, native_session_id = "7", window_host_id = "local" } }))
			retained_outcomes[request.request_id] = assert(protocol.decode_response(bridge_bytes, request))
			peer_revision += 1
			for _ = 1, 12 do
				tick()
				if wf:action(launch_id) == nil then break end
			end
			check_window(wf:action(launch_id) == nil and last_receipt.action_id == launch_id and last_receipt.grant_id == grant
				and launch_deliveries == 1 and count_events("launch") == 1 and count_events("mailbox_provision") == 1
				and count_commands("claim", launch_id) == 1 and count_commands("lost", launch_id) == 0,
				"fresh witness lets the original native launch outcome settle once without another effect, claim or lost command")
			return
		end
		if mode == "scoped_poll" then
			for _ = 1, 20 do tick(); if refused_poll then break end end
			check_window(refused_poll ~= nil and refused_poll.action_id == nil and poll_result == refused_poll
				and last_result.action_id ~= nil and runtime.json.encode(driver_result) == startup_driver_result,
				"actionless refused poll survives a late completed effect in its independent volatile receipt slot")
			for _ = 1, 4 do tick() end
			check(#poll_commands == 1 and pending_poll == nil and ack_sends == 0,
				"wrong request ID cannot release an actionless pending poll")
			poll_projection_fault = "worker"
			for _ = 1, 4 do tick() end
			check(#poll_commands == 1 and pending_poll == nil and ack_sends == 0,
				"wrong worker cannot release an actionless pending poll")
			poll_projection_fault = nil
			for _ = 1, 20 do tick(); if pending_poll then break end end
			check_window(pending_poll ~= nil and #poll_commands == 2
				and pending_poll.request_id ~= refused_poll.request_id and poll_commands[2].expected_revision > poll_commands[1].expected_revision
				and last_result.action_id ~= pending_poll.action_id and poll_result == pending_poll.result
				and runtime.json.encode(driver_result) == startup_driver_result and driver_result.request_id ~= pending_poll.request_id,
				"consuming the exact actionless refusal releases scheduling for a distinct fresh poll, never replaying the old command")
			local action_id, worker_id = pending_poll.action_id, pending_poll.worker_id
			for _ = 1, 4 do tick() end
			check(wf:action(action_id).phase == "ready" and count_commands("claim", action_id) == 0 and ack_sends == 0,
				"wrong request correlation cannot attach the pending worker driver to an action")
			poll_projection_fault = "worker"
			for _ = 1, 4 do tick() end
			check(wf:action(action_id).phase == "ready" and count_commands("claim", action_id) == 0 and ack_sends == 0,
				"a poll receipt projected for another worker cannot attach the pending poll driver")
			poll_projection_fault = nil -- Restore the unmodified production projection, not a new command or receipt.
			for _ = 1, 12 do tick(); if wf:action(action_id) == nil then break end end
			check_window(wf:action(action_id) == nil and ack_id == action_id and ack_sends == 1
				and count_commands("claim", action_id) == 1 and count_commands("lost", action_id) == 0
				and not wf.authority.registry.dispatch.workers[worker_id].receipts["1"].publish
				and count_events("mailbox_provision") == 1 and count_events("launch") == 1 and launch_deliveries == 1,
				"exact independent poll receipt resumes its worker and drains ACK once without repeating the completed launch")
			return
		end
		if ack_mode then
			for _ = 1, 20 do
				tick()
				if ack_id and (wf:action(ack_id) == nil or wf:action(ack_id).response) then break end
			end
			check(wf:action(ack_id) == nil and ack_sends == 1 and wf.authority.registry.sessions[wf.origin.logical_session_id].controller.pending_executors == 0,
				"known ACK publication commits and releases its action before any native notification")
			local worker = wf.authority.registry.dispatch.workers[queued_worker]
			if mode == "ack_terminal" then
				check(next(worker.wakes or {}) == nil and wake_sends == 0 and worker.compacted_floor == 0,
					"terminal publication creates no notification and is never mistaken for producer receipt")
				return
			end
			check(next(worker.wakes) ~= nil and not worker.receipts["1"].publish and wake_sends == 0,
				"awaiting-window notification persists separately while the busy worker consumes no execution slot")
			if worker.accept_pending then
				local accept = wf:apply("poll", { worker_id = queued_worker }); assert(accept.ok)
				assert(wf:action(accept.action_id).request.op == "accept")
				assert(wf:finish(accept.action_id, "accepted").ok)
			end
			native_state = "idle"
			assert(wf:apply("observe", { worker_id = queued_worker, pane_binding = worker.pane_binding, native_state = native_state }).ok)
			click("poll")
			for _ = 1, 20 do tick(); if wake_request then break end end
			assert(wake_request and wake_id ~= ack_id)
			local grant = wf:action(wake_id).claim.grant_id
			check(wake_sends == 1 and ack_sends == 1 and wf:action(ack_id) == nil, "fresh safe idle issues one independent native-wake grant without republishing ACK")
			deferred_outcome = assert(protocol.decode_response(frame(wake_request, if mode == "ack_uncertain" then "uncertain" else "submitted",
				if mode == "ack_uncertain" then nil else { wake_status = "submitted", wake_effect_started = true }), wake_request))
			peer_revision += 1
			for _ = 1, 20 do
				tick()
				local pending = wf:action(wake_id)
				if pending == nil or pending.phase == "uncertain" then break end
			end
			local remaining = wf:action(wake_id)
			check((if mode == "ack_uncertain" then remaining ~= nil and remaining.phase == "uncertain" and remaining.claim.grant_id == grant else remaining == nil)
				and wake_sends == 1 and ack_sends == 1, "notification readback either settles or retains exact uncertainty; neither publication nor native ask repeats")
			worker = wf.authority.registry.dispatch.workers[queued_worker]
			check(worker.compacted_floor == 0 and not worker.receipts["1"].publish, "notification outcome is never forged producer consumption")
			if mode == "ack_uncertain" then
				check(next(worker.wakes) ~= nil and wf:apply("retry", { action_id = wake_id }).code == "retry_refused", "uncertain native wake remains live and cannot blind retry")
			else check(next(worker.wakes) == nil, "submitted native wake removes its completed notification obligation") end
			return
		end
		if mode == "late" then
			tick(); tick(); tick()
			local provision_id = selected
			local provision_grant = wf:action(provision_id).claim.grant_id
			check(events[2].op == "status" and wf:action(provision_id).phase == "claimed", "pending provision has a correlated retained-status response waiting")
			clock += 31000; tick() -- Callback arrives after a long gap (host suspension) with status-found evidence already available.
			check(wf:action(provision_id) == nil and last_receipt.grant_id == provision_grant
				and wf.authority.registry.dispatch.workers[queued_worker].phase == "provisioned", "late timer consumes conclusive status-found provisioning before considering timeout")
			hold_results = true
			local launch_id = wf.authority.registry.dispatch.workers[queued_worker].launch_action_id
			for _ = 1, 24 do
				tick()
				local launch = wf:action(launch_id)
				if launch and launch.claim and count_events("launch") == 1 then break end
			end
			local launch_grant = assert(wf:action(launch_id)).claim.grant_id
			hold_results = false
			clock += 31000; tick(); tick() -- The direct rejection is also retained across a delayed callback after a gap.
			check(last_receipt.grant_id == launch_grant and launch_deliveries == 1, "late direct rejection is committed under its original launch grant")
			check(#events == 3 and events[1].op == "mailbox_provision" and events[2].op == "status" and events[3].op == "launch", "late outcomes never repeat provisioning or launch")
		elseif mode == "reconcile_chain" then
			tick(); tick()
			local provision = wf:action(selected)
			assert(wf:apply("lost", { action_id = selected, executor = provision.claim.executor, grant_id = provision.claim.grant_id }).ok)
			click("reconcile")
			for _ = 1, 12 do
				tick()
				if launch_deliveries == 1 then break end
			end
			check_window(count_events("mailbox_provision") == 1 and count_events("launch") == 1
				and count_events("status") == 1 and launch_deliveries == 1,
				"read-only reconciliation never reexecutes provisioning and does not suppress the separately granted first launch")
		elseif mode == "refused_chain" then
			for _ = 1, 24 do
				tick()
				if launch_deliveries == 1 then break end
			end
			check(launch_deliveries == 1, "first worker has a captured launch outcome awaiting host delivery")
			local first_action, grant = selected, wf:action(selected).claim.grant_id
			click("queue")
			local refusal_id = command_result.request_id
			check(command_result.code == "orchestrator_slot_occupied" and selected == first_action,
				"second operator start refuses without replacing original active action")
			-- A refused start is a pure refusal and no longer advances the registry, so the captured launch delivery
			-- would commit instead of going stale. Make the premise explicit with a real intervening authority commit.
			assert(wf:apply("pause").ok); assert(wf:apply("resume").ok)
			tick(); tick()
			check_window(command_result.request_id == refusal_id and command_result.code == "orchestrator_slot_occupied"
				and wf:action(first_action) ~= nil and wf:action(first_action).claim.grant_id == grant
				and last_result.code == "stale_revision",
				"failed second start preserves its refusal and original grant when the immutable lost observation becomes stale")
			check(count_events("mailbox_provision") == 1 and count_events("launch") == 1 and launch_deliveries == 2,
				"failed second start never resends either original SPAWN effect")
		elseif mode == "auto_reconcile_worker" then
			tick(); tick(); tick()
			local provision_id = selected
			check(events[1].op == "mailbox_provision" and events[2].op == "status" and wf:action(provision_id).phase == "claimed",
				"SPAWN still reports provisioning pending; its exact claim stays live")
			for _ = 1, 7 do clock += 4000; tick() end -- 32 s of awake time without a conclusive outcome.
			check(wf:action(provision_id).phase == "uncertain" and count_commands("lost", provision_id) == 1,
				"awake effect deadline leaves provisioning uncertain and pins its worker")
			deferred_outcome = held_success -- SPAWN's retained registry now holds the definitive outcome.
			peer_revision += 1
			for _ = 1, 8 do
				clock += 1000; tick()
				if wf:action(provision_id) == nil or wf:action(provision_id).phase ~= "uncertain" then break end
			end
			check(wf:action(provision_id) == nil and wf.authority.registry.dispatch.workers[queued_worker].phase == "provisioned",
				"automatic read-only reconciliation settles the worker's definitive outcome without the owner")
			for _ = 1, 8 do
				tick()
				local launch = wf:action(wf.authority.registry.dispatch.workers[queued_worker].launch_action_id)
				if launch_deliveries == 1 and launch == nil then break end
			end
			check(count_events("mailbox_provision") == 1 and count_events("launch") == 1 and count_commands("claim", provision_id) == 1
				and count_commands("lost", provision_id) == 1, "automatic reconciliation never re-claims or re-executes provisioning; the separate launch runs once")
		else
			-- The lost launch delivery is replayed after 1 s of awake backoff (two ticks), not on the next
			-- tick; the extra ticks after settlement also show no SPAWN effect is ever repeated.
			-- The first launch delivery is lost. Nothing else commits to the registry in this mode any more, so the replay
			-- of that captured observation would commit instead of going stale; make the premise explicit with a real
			-- intervening authority commit right after the loss, before the replay is due.
			for _ = 1, 24 do if launch_deliveries >= 1 then break end; tick() end
			assert(wf:apply("pause").ok); assert(wf:apply("resume").ok)
			-- Control is re-admitted between effects, so reaching the replayed delivery takes more ticks than it
			-- once did. The fixture receipt carries the production response hash, so the window recognises settlement;
			-- the extra ticks after the settling delivery must not replace the settled outcome checked below. (The
			-- suite has a 60 s wall bound; about one second per tick, so the extra ticks stay few.)
			for _ = 1, 36 do if launch_deliveries >= 3 then break end; tick() end
			for _ = 1, 3 do tick() end
			check(count_events("mailbox_provision") == 1 and count_events("launch") == 1 and launch_deliveries == 3,
				"provision-to-launch chain performs each effect once and freshly observes the positively refused stale delivery")
		end
		if mode == "chain" or mode == "refused_chain" then
			local launch_id = selected
			local launch = wf:action(launch_id)
			local grant = if launch then launch.claim.grant_id else last_receipt.grant_id
			if launch then
				check_window(launch.phase == "claimed" and last_result.code == "stale_revision",
					"genuine intervening control progress refuses the immutable observation without consuming its launch")
			end
			for _ = 1, 12 do
				tick()
				if wf:action(launch_id) == nil then break end
			end
			check_window(wf:action(launch_id) == nil and last_receipt.grant_id == grant
				and launch_deliveries == 3 and count_events("status") == 1
				and count_events("mailbox_provision") == 1 and count_events("launch") == 1
				and count_commands("claim", launch_id) == 1 and count_commands("lost", launch_id) == 0,
				"fresh retained read settles the same launch grant and rejection without an owner reclick, re-claim, timeout or effect replay")
		end
		local worker = wf.authority.registry.dispatch.workers[queued_worker]
		check_window(wf:action(worker.launch_action_id) == nil and worker.phase == "held" and worker.reason.code == "binding_mismatch"
			and last_result.code == "bridge_rejected", "observed launch rejection commits precise prerequisite instead of timing out as uncertainty")
		check(wf.authority.registry.sessions[wf.origin.logical_session_id].controller.pending_executors == 0
			and wf.authority.registry.sessions[wf.origin.logical_session_id].orchestrator ~= nil, "rejection settles only its executor and retains coordinator reservation")
		if mode == "chain" or mode == "refused_chain" then
			-- Extra ticks after settlement: no SPAWN effect is ever repeated.
			for _ = 1, 12 do tick() end
			check(count_events("mailbox_provision") == 1 and count_events("launch") == 1,
				"ticks after settlement never repeat provisioning or launch")
		end
		return
	end
	if mode == "background_settlement" then
		click("catalog"); tick(); tick(); tick()
		local first = selected
		check(wf:action(first).phase == "claimed" and catalog_sends == 1, "captured catalog owns exactly one issued effect before selection changes")
		native_session, native_focus = 8, 9003
		check(api.owned_origin(cx, 9001, wf.origin), "native ownership survives selecting another same-window session")
		for _, field in { "window_key", "window_epoch", "window_host_id", "native_session_id", "owner_id", "owner_generation", "host_pane_id", "alias_nonce" } do
			local wrong = clone(wf.origin)
			wrong[field] = if field == "owner_generation" then wrong[field] + 1 else "wrong-" .. tostring(wrong[field])
			check(not api.owned_origin(cx, 9001, wrong), "background source rejects exact captured " .. field)
		end
		check(not api.owned_origin(cx, 9003, wf.origin), "another pane in the selected session is not the captured source")
		panes[9001].tab = 3
		check(not api.owned_origin(cx, 9001, wf.origin), "moving the source into another native session refuses background authority")
		panes[9001].tab = 1
		deferred_outcome = held_success; peer_revision += 1
		for _ = 1, 16 do tick(); if wf:action(first) == nil and api.bookkeeping().watched == 0 then break end end
		check_window(wf:action(first) == nil and catalog_sends == 1,
			"retained exact owned effect settles while another same-window session is selected, without effect replay")
		-- No window driver exists for this new host-authorized ready action: schedule
		-- must discover its nonselected owned source itself.
		local queued = wf:apply("catalog"); assert(queued.ok)
		selected = queued.action_id; last_result = queued; scoped_results[selected] = { result = queued }
		for _ = 1, 6 do tick(); if catalog_sends == 2 then break end end
		check(catalog_sends == 2 and wf:action(selected).phase == "claimed",
			"owned-source scheduling discovers an authorized ready action outside the selected session")
		deferred_outcome = held_success; peer_revision += 1
		for _ = 1, 16 do tick(); if wf:action(selected) == nil then break end end
		check_window(wf:action(selected) == nil and catalog_sends == 2, "background-discovered action settles exactly once")
		local pauses = count_commands("pause")
		click("pause")
		check(intent == nil and count_commands("pause") == pauses, "human intent observed after native selection changed is refused and consumed, not deferred")
		native_session = 7; api.intents(cx)
		check(count_commands("pause") == pauses and native_focus == 9003 and focus_changes == 0,
			"returning to the source session never replays its refused human intent or mutates focus")
		click("close_session")
		assert(delayed_pick, "close confirmation is a real captured native picker callback")
		local writes = wf.memory.writes
		local session_before = quota.digest(wf.authority.registry.sessions[wf.origin.logical_session_id])
		native_session = 8
		delayed_pick.callback(delayed_pick.choice, nil, table.clone(cx))
		check(wf.memory.writes == writes and quota.digest(wf.authority.registry.sessions[wf.origin.logical_session_id]) == session_before
			and native_focus == 9003 and focus_changes == 0,
			"fresh native callback after selection changes refuses human confirmation without mutating the source or focus")
		return
	end
	if mode == "window_bookkeeping" then
		-- The set-before-send marker of a live claim survives every prune pass; once the action
		-- settles, its marker and settle watch are released without any SPAWN effect repeating.
		click("catalog"); tick(); tick(); tick()
		local first = selected
		check(wf:action(first).phase == "claimed" and api.bookkeeping().executed == 1 and api.bookkeeping().watched == 1 and catalog_sends == 1,
			"a sent effect's grant marker is retained while its claim is live")
		for _ = 1, 6 do tick() end
		check(wf:action(first).phase == "claimed" and api.bookkeeping().executed == 1 and catalog_sends == 1,
			"pruning never drops the marker of a still-claimed effect and nothing is re-sent")
		deferred_outcome = held_success
		peer_revision += 1
		for _ = 1, 12 do
			tick()
			if wf:action(first) == nil and api.bookkeeping().watched == 0 then break end
		end
		local kept = api.bookkeeping()
		check(wf:action(first) == nil and kept.executed == 0 and kept.watched == 0 and kept.auto_reconcile == 0 and catalog_sends == 1,
			"a settled action releases its window bookkeeping without repeating its effect")
		return
	end
	if mode == "suspend" then
		click("catalog"); tick(); tick(); tick()
		local first = selected
		check(catalog_sends == 1 and events[2].op == "status" and wf:action(first).phase == "claimed", "pending catalog keeps its exact live claim")
		clock += 3600000; tick() -- One hour of host sleep between two observation ticks.
		clock += 600000; tick()
		check(wf:action(first).phase == "claimed" and count_commands("lost") == 0 and #notices == 0,
			"a host suspension between ticks is not awake time and never expires the effect deadline")
		deferred_outcome = held_success
		peer_revision += 1
		-- Pending status is polled every five wall-clock seconds, not every callback after wake.
		for _ = 1, 4 do clock += 1500; tick(); if dropped_delivery then break end end
		check(dropped_delivery and wf:action(first).phase == "claimed", "SPAWN's outcome after wake is captured once; its first host event is lost")
		clock += 3600000; tick() -- Another suspension before the commit receipt is observed.
		tick()
		if last_result.code == "stale_revision" then
			check(wf:action(first).phase == "claimed" and count_commands("lost") == 0 and catalog_sends == 1,
				"a real control commit during suspension keeps the refused immutable observation's grant live")
			for _ = 1, 20 do tick(); if wf:action(first) == nil then break end end
		end
		check(wf:action(first) == nil and last_result.code == "bridge_committed" and count_commands("lost") == 0 and catalog_sends == 1,
			"the retained outcome settles after suspension without deadline expiry or repeated effects; exact stale refusal permits a distinct fresh read")
		-- The replay now lands one tick later (1 s awake backoff), so the window has not yet read its
		-- receipt. Let it do so before the next catalog compacts this settled read: the real host keeps
		-- the scope through retained.completed (see callbacks), but this fixture's surface does not.
		tick()
		click("catalog"); tick(); tick(); tick()
		local second = selected
		for _ = 1, 6 do clock += 4000; tick() end
		check(second ~= first and wf:action(second).phase == "claimed" and count_commands("lost", second) == 0, "awake time below the effect deadline keeps waiting")
		clock += 4000; tick()
		check(wf:action(second).phase == "uncertain" and count_commands("lost", second) == 1 and catalog_sends == 2,
			"awake time still expires the effect deadline into retained uncertainty")
		click("catalog"); tick(); tick(); tick()
		local third = selected
		for _ = 1, 5 do clock += 4000; tick() end
		deferred_outcome = held_success -- SPAWN completes; its status answer becomes visible only on the expiring turn.
		peer_revision += 1
		clock += 4000; tick()
		check(wf:action(third).phase == "claimed" and count_commands("lost", third) == 0, "awake time just below the deadline still waits for the retained outcome")
		clock += 4000; tick() -- The awake deadline elapses on this turn.
		check(wf:action(third) == nil and last_result.code == "bridge_committed" and count_commands("lost", third) == 0 and catalog_sends == 3,
			"a conclusive outcome visible on the expiring turn is consumed before the awake deadline applies; no effect repeats")
		return
	end
	if mode == "auto_reconcile" or mode == "auto_reconcile_bounded" or mode == "auto_reconcile_all" then
		local function uncertain_catalog()
			click("catalog"); tick(); tick(); tick()
			local id = selected
			for _ = 1, 7 do clock += 4000; tick() end -- 32 s of awake time; SPAWN stays pending.
			check(wf:action(id).phase == "uncertain" and count_commands("lost", id) == 1, "awake effect deadline leaves the exact catalog uncertain")
			return id
		end
		local first = uncertain_catalog()
		local reads = count_events("status")
		tick()
		check(count_events("status") == reads, "no automatic read before its awake backoff")
		if mode == "auto_reconcile_all" then
			local second = uncertain_catalog()
			check(selected == second and wf:action(first).phase == "uncertain", "the first uncertain read is neither selected nor any worker's active action")
			for _, id in { first, second } do
				local request_id = wf:action(id).request.request_id
				retained_outcomes[request_id] = successes[request_id] -- SPAWN's registry now holds both definitive outcomes.
				peer_revision += 1
			end
			for _ = 1, 40 do
				clock += 1500; tick()
				if wf:action(first) == nil and wf:action(second) == nil then break end
			end
			check(wf:action(first) == nil and wf:action(second) == nil,
				"every uncertain read-only action is reconciled automatically, independent of selection")
			check(catalog_sends == 2 and count_commands("claim", first) == 1 and count_commands("claim", second) == 1
				and count_commands("lost", first) == 1 and count_commands("lost", second) == 1, "read-only reconciliation never re-claims or re-executes either read")
			assert(wf:control("reconcile_session").ok)
			for _ = 1, 12 do tick() end
			local kept = api.bookkeeping()
			check(kept.executed == 0 and kept.watched == 0 and kept.auto_reconcile == 0 and catalog_sends == 2,
				"simultaneously completed scopes lost before one-watch pruning reclaim through the authenticated settled floor")
			return
		end
		if mode == "auto_reconcile_bounded" then
			for _ = 1, 32 do clock += 4000; tick() end -- 144 s awake; every backoff elapses with SPAWN still pending.
			check(count_events("status") == reads + 4 and wf:action(first).phase == "uncertain", "exactly four bounded automatic reads, each finding SPAWN still pending")
			check(catalog_sends == 1 and count_commands("claim", first) == 1 and count_commands("lost", first) == 1,
				"automatic reads never re-claim, re-execute or re-mark the effect")
			deferred_outcome = held_success
			peer_revision += 1
			click("reconcile")
			for _ = 1, 4 do tick() end
			check(wf:action(first) == nil and catalog_sends == 1 and count_commands("claim", first) == 1,
				"the owner's read-only control still settles the retained outcome without another effect")
			return
		end
		for _ = 1, 4 do clock += 1000; tick() end
		check(count_events("status") == reads + 1 and wf:action(first).phase == "uncertain",
			"one automatic status read finds SPAWN still pending and leaves the action uncertain")
		deferred_outcome = held_success
		peer_revision += 1
		for _ = 1, 10 do
			clock += 1000; tick()
			if wf:action(first) == nil or wf:action(first).phase ~= "uncertain" then break end
		end
		check(wf:action(first) == nil and last_result.code == "bridge_committed", "a later automatic read settles the definitive completed outcome")
		check(catalog_sends == 1 and count_events("status") == reads + 2 and count_commands("claim", first) == 1 and count_commands("lost", first) == 1,
			"automatic reconciliation reads once per attempt and never re-claims or re-executes")
		tick()
		local second = uncertain_catalog()
		local request = wf:action(second).request
		deferred_outcome = protocol.decode_response(frame(request, "rejected", nil, { code = "binding_mismatch", message = "SPAWN refused before any effect" }), request)
		peer_revision += 1
		for _ = 1, 6 do
			clock += 1000; tick()
			if wf:action(second) == nil or wf:action(second).phase ~= "uncertain" then break end
		end
		check(wf:action(second) == nil and last_result.code == "bridge_rejected" and catalog_sends == 2 and count_commands("claim", second) == 1,
			"automatic reconciliation settles a definitive failed outcome exactly as the owner control would")
		return
	end
	if mode == "expired_authorization" then
		click("catalog"); tick(); tick(); tick()
		local id = selected
		local request, request_bytes = wf:action(id).request, wf:action(id).request_bytes
		check(catalog_sends == 1 and wf:action(id).phase == "claimed", "a staged SPAWN challenge keeps the exact live claim while it reports pending")
		for _ = 1, 7 do clock += 4000; tick() end -- 32 s awake: the challenge is never consumed.
		check(wf:action(id).phase == "uncertain" and count_commands("lost", id) == 1, "the awake effect deadline marks the unconsumed challenge lost")
		local reads = count_events("status")
		for _ = 1, 8 do
			clock += 1000; tick()
			if count_events("status") > reads then break end
		end
		tick(); tick()
		check(count_events("status") == reads + 1 and wf:action(id).phase == "uncertain" and count_commands("retry") == 0,
			"a pending automatic read is no pre-effect evidence; the uncertain action is not retried")
		deferred_outcome = protocol.decode_response(frame(request, "uncertain", nil, { code = "target_unavailable", message = "Native effect outcome uncertain; do not retry" }), request)
		peer_revision += 1
		for _ = 1, 20 do
			clock += 1000; tick()
			if wf:action(id).response ~= nil then break end
		end
		for _ = 1, 12 do clock += 1000; tick() end
		check(wf:action(id).phase == "uncertain" and wf:action(id).response.status == "uncertain" and count_commands("retry") == 0 and catalog_sends == 1,
			"a committed uncertain outcome stays uncertain and is never retried automatically")
		-- SPAWN's challenge expired unconsumed: its status read is definitive pre-effect evidence.
		deferred_outcome = protocol.decode_response(frame(request, "full", { resource = "window_authorization", current = 1, limit = 1, retryable = true, effect_started = false }), request)
		peer_revision += 1
		for _ = 1, 40 do
			clock += 1000; tick()
			if wf:action(id) == nil or wf:action(id).phase ~= "uncertain" then break end
		end
		check_window(wf:action(id).phase == "backpressure" and last_result.code == "backpressure" and count_commands("retry") == 0 and catalog_sends == 1,
			"the automatic read commits expired-authorization evidence on the uncertain action as retryable backpressure")
		for _ = 1, 6 do tick() end -- 3 s awake: inside the recheck backoff.
		check(count_commands("retry") == 0 and wf:action(id).phase == "backpressure", "no automatic recheck inside its awake backoff")
		for _ = 1, 24 do
			tick()
			if selected ~= id and wf:action(selected) == nil and last_result.code == "bridge_committed" then break end
		end
		check(selected ~= id and count_commands("retry", id) == 1 and count_commands("claim", id) == 1
			and count_commands("claim", selected) == 1 and catalog_sends == 2 and wf:action(id) == nil and wf:action(selected) == nil
			and last_result.code == "bridge_committed", "backoff retry creates one fresh action/serial, claims once and consumes both completed attempts")
		check(count_commands("lost", id) == 1 and events[1].bytes ~= events[2].bytes,
			"recheck never reuses the old issued catalog request bytes or marks its successor lost")
		return
	end
	if mode == "consumed_scope" then
		click("catalog")
		local waiting = selected
		for _ = 1, 20 do tick(); if scoped_commit then break end end
		assert(scoped_commit and wf:action(waiting) == nil and scoped_results[waiting] == nil)
		for _ = 1, 8 do tick() end
		check(api.bookkeeping().executed == 1 and api.bookkeeping().watched == 1,
			"another authority's settled floor never reclaims this consumed but unacknowledged grant marker")
		settlement_fault = false
		local control = wf.authority.registry.sessions[wf.origin.logical_session_id]
		local covered = control.request_floor > scoped_commit.request_serial or (control.bridge_control and control.bridge_control.request.settled_before > scoped_commit.request_serial)
		check((host_deliveries > 1 or covered) and catalog_sends == 1 and count_commands("lost") == 0,
			"missing scoped receipt either remains pending or settles only with positive current control coverage, never by absence")
		assert(wf:control("reconcile_session").ok)
		check(wf.authority.registry.sessions[wf.origin.logical_session_id].request_floor > scoped_commit.request_serial,
			"real canonical reconcile confirms consumed coverage for the exact namespace/session/admission")
		local deliveries = host_deliveries
		for _ = 1, 12 do tick() end
		check(host_deliveries == deliveries and catalog_sends == 1 and count_commands("claim", waiting) == 1 and count_commands("lost") == 0,
			"root confirmed peer floor settles the missing scoped delivery without another receipt, replay or effect")
		check(scoped_results[waiting] == nil and wf:action(waiting) == nil, "positive coverage needs no completed action or receipt history")
		check(api.bookkeeping().executed == 0 and api.bookkeeping().watched == 0,
			"confirmed settled-before floor reclaims receipt-less grant markers, not only explicit consumed holes")
		return
	end
	if mode == "capacity_resume" then
		click("pause"); click("resume") -- Real window commands bind the fixture to this window's origin.
		local occupied = {}
		for _ = 1, 4 do -- Four running effects owned by this window fill every host effect slot.
			local queued = wf:apply("catalog"); assert(queued.ok)
			assert(wf:apply("claim", { action_id = queued.action_id, executor = wf.origin.window_epoch }).ok)
			table.insert(occupied, queued.action_id)
		end
		click("catalog"); tick(); tick()
		local waiting = selected
		check(wf:action(waiting).phase == "ready" and count_commands("claim", waiting) == 1 and catalog_sends == 0,
			"a full host refuses the claim before any effect; the action stays ready")
		for _ = 1, 6 do tick() end -- 3 s awake: inside the resume backoff.
		check(count_commands("claim", waiting) == 1 and catalog_sends == 0, "no claim storm inside the backoff")
		local grant = wf:action(occupied[1]).claim
		assert(wf:apply("lost", { action_id = occupied[1], executor = grant.executor, grant_id = grant.grant_id }).ok)
		for _ = 1, 20 do
			tick()
			if wf:action(waiting) == nil then break end
		end
		check(wf:action(waiting) == nil and catalog_sends == 1 and count_events("catalog") == 1,
			"an uncertain read-only catalog frees its slot and the refused claim resumes automatically, executing once")
		local relaunched = 0
		for _, id in occupied do relaunched += count_commands("claim", id) end
		check(relaunched == 0 and wf:action(occupied[1]).phase == "uncertain",
			"capacity resume only re-claims never-granted ready work; the uncertain read is never claimed or executed again")
		return
	end
	if mode == "stale_claim" then
		lag_claims = true
		click("catalog")
		local waiting = selected
		for _ = 1, 6 do tick() end
		check(#lagged == 1 and wf:action(waiting).phase == "ready" and catalog_sends == 0,
			"an unanswered background claim creates no grant, effect or replacement claim")
		local captured = lagged[1]
		local original = runtime.json.decode(captured.value)
		click("pause"); click("resume")
		for _ = 1, 6 do tick() end
		check(#lagged == 1 and wf:action(waiting).phase == "ready" and catalog_sends == 0
			and captured.value == lagged[1].value and original.expected_revision < wf.authority.registry.revision,
			"authority progress alone never refreshes an unanswered immutable claim")
		local unrelated = wf:event("claim", { action_id = waiting, executor = original.executor,
			expected_revision = original.expected_revision })
		local writes = wf.memory.writes
		lag_claims = false
		session:event(9001, { ev = "action", id = captured.id, act = captured.act, value = runtime.json.encode(unrelated) })
		lag_claims = true
		check(last_result.code == "stale_revision" and last_result.request_id ~= original.request_id and wf.memory.writes == writes,
			"unrelated stale claim refusal is genuine but cannot acknowledge the pending claim")
		for _ = 1, 4 do tick() end
		check(#lagged == 1 and wf:action(waiting).phase == "ready" and catalog_sends == 0,
			"an unrelated stale receipt does not clear the pending claim or authorize a fresh claim")
		writes = wf.memory.writes
		lag_claims = false
		session:event(9001, captured)
		check(last_result.command == "claim" and last_result.code == "stale_revision" and last_result.grant_id == nil
			and last_result.request_id == original.request_id and last_result.action_id == waiting
			and wf.memory.writes == writes and wf:action(waiting).phase == "ready",
			"exact positively refused background claim creates no grant and preserves its captured bytes")
		local attempts = #claim_attempts
		for _ = 1, 12 do
			tick()
			if wf:action(waiting) == nil then break end
		end
		local fresh = claim_attempts[attempts + 1]
		check_window(#claim_attempts == attempts + 1 and fresh ~= nil and fresh.request.request_id ~= original.request_id
			and fresh.request.authority_namespace == original.authority_namespace
			and fresh.request.expected_revision == fresh.revision and fresh.request.expected_revision > original.expected_revision
			and fresh.request.action_id == waiting and wf:action(waiting) == nil
			and catalog_sends == 1 and host_deliveries == 1 and last_result.code == "bridge_committed"
			and count_commands("lost", waiting) == 0 and captured.value == lagged[1].value,
			"exact stale refusal permits one distinct current-fence claim and one grant/effect/settlement without rewriting the original")
		tick() -- Let the first completed delivery settle before the independent negative case.
		lag_claims = true; lagged = {}
		click("catalog")
		local held_id = selected
		for _ = 1, 6 do tick() end
		check(#lagged == 1 and wf:action(held_id).phase == "ready", "second unanswered claim is captured independently")
		local pending = runtime.json.decode(lagged[1].value)
		click("pause"); click("resume")
		local wrong_command = wf:event("catalog", { request_id = pending.request_id, action_id = held_id,
			expected_revision = pending.expected_revision })
		writes = wf.memory.writes
		session:event(9001, { ev = "action", id = lagged[1].id, act = lagged[1].act, value = runtime.json.encode(wrong_command) })
		check(last_result.command == "catalog" and last_result.code == "stale_revision" and last_result.grant_id == nil
			and last_result.request_id == pending.request_id and wf.memory.writes == writes,
			"same-ID wrong-command stale receipt is a genuine no-write refusal, not a claim answer")
		for _ = 1, 12 do tick() end
		check(#lagged == 1 and wf:action(held_id).phase == "ready" and wf:action(held_id).claim == nil
			and catalog_sends == 1 and count_commands("lost", held_id) == 0,
			"wrong-command correlation never authorizes a replacement claim, grant or native effect")
		return
	end
	if mode == "duplicate_claim" then
		-- A lagging host: the window's claims wait in the host queue while its timer keeps ticking.
		lag_claims = true
		click("catalog")
		local waiting = selected
		for _ = 1, 6 do tick() end -- 3 s awake before the host processes the first claim.
		check(#lagged == 1, "a lost claim response is observed, never resent under a refreshed revision")
		lag_claims = false
		local queued = lagged; lagged = {}
		for _, ev in queued do session:event(9001, ev) end -- The host catches up in order.
		check(#queued == 1 and wf:action(waiting).phase == "claimed" and last_result.code == "effect_granted", "the original delayed claim grants one effect")
		local grant, writes = wf:action(waiting).claim.grant_id, wf.memory.writes
		session:event(9001, queued[1])
		check(last_result.code == "stale_revision" and wf.memory.writes == writes and wf:action(waiting).claim.grant_id == grant,
			"an explicitly replayed old claim keeps its original fence and cannot obtain another grant")
		for _ = 1, 10 do
			tick()
			if wf:action(waiting) == nil then break end
		end
		check_window(wf:action(waiting) == nil and catalog_sends == 1 and count_commands("lost") == 0 and last_result.code == "bridge_committed",
			"a duplicate claim refusal neither holds nor strands the claimed action; the driver executes it once and completes")
		return
	end
	if mode == "slow_receipt" then
		hold_results = true
		click("catalog")
		local waiting = selected
		for _ = 1, 10 do tick(); if held_results > 0 then break end end
		check(held_results == 1 and catalog_sends == 1 and wf:action(waiting).phase == "claimed", "SPAWN's outcome is captured and delivered to the host once")
		click("pause") -- A real intervening owner commit must not refresh the captured result's fence.
		for _ = 1, 120 do tick() end -- 60 s awake with the host commit receipt still pending.
		check(held_results <= 9, "receipt-pending replays back off instead of repeating every tick")
		check(count_commands("lost", waiting) == 0 and #notices == 0 and wf:action(waiting).phase == "claimed",
			"a host receipt slower than the 30 s effect deadline does not turn the delivered outcome into lost")
		hold_results = false
		for _ = 1, 40 do
			tick()
			if last_result.code == "stale_revision" then break end
		end
		check(last_result.code == "stale_revision" and wf:action(waiting).phase == "claimed"
			and catalog_sends == 1 and count_commands("lost", waiting) == 0,
			"the delayed immutable envelope is refused after intervening commits; its grant remains live and no effect repeats")
		for _ = 1, 20 do tick(); if wf:action(waiting) == nil then break end end
		check(wf:action(waiting) == nil and catalog_sends == 1 and count_commands("claim", waiting) == 1
			and count_commands("lost", waiting) == 0 and last_result.code == "bridge_committed",
			"a fresh automatic retained-outcome read settles the original grant without refreshing or replaying its effect")
		tick()
		-- Still bounded: a host that renders no progress at all eventually leaves retained uncertainty.
		hold_results = true
		local delivered = held_results
		click("catalog")
		local stuck = selected
		-- The held log also counts replays of the earlier settled delivery, so wait until the second catalog has
		-- actually been sent and its own outcome is the one that was held.
		local before = delivered
		for _ = 1, 40 do
			if catalog_sends < 2 then before = held_results end
			tick()
			if catalog_sends == 2 and held_results > before then break end
		end
		check(stuck ~= waiting and held_results > delivered and catalog_sends == 2, "a second outcome is captured")
		for _ = 1, 80 do clock += 4000; tick() end -- 360 s awake without any rendered host progress.
		check(count_commands("lost", stuck) == 1 and wf:action(stuck).phase == "uncertain",
			"with no host progress for the bound the delivery ends as lost, never re-executed")
		check(catalog_sends == 2, "abandoning a delivery never repeats the SPAWN effect")
		return
	end
	click("catalog"); tick(); tick(); tick()
	if mode == "oversize" then
		check(events[2].op == "status", "pending direct result requests its retained status")
		tick()
		check(#events == 3 and events[3].op == "catalog" and events[3].bytes == events[1].bytes, "oversized nested status replays exact request without overwriting direct reply in the same turn")
		tick()
	else
		check(last_result.code == "backpressure", "native full response reaches explicit backpressure state")
		local previous_grant = wf:action(selected).claim.grant_id
		click("retry")
		-- The fresh driver re-admits its control channel (bridge_control) before it claims, so the claim and resend land a few
		-- awake ticks after the click; advance until then, bounded, rather than assuming a fixed tick count.
		tick(); tick()
		for _ = 1, 8 do if #events >= 2 then break end; tick() end
		check_window(wf:action(selected).phase == "claimed" and wf:action(selected).claim.grant_id ~= previous_grant
			and #events == 2 and events[2].bytes ~= events[1].bytes, "real window uses a fresh request/action/serial for the proven pre-effect retry")
		tick()
		check(events[3].op == "status" and wf:action(selected).phase == "claimed", "old full surface cannot settle new grant before fresh ordered status")
		tick()
	end
	check(wf:action(selected) == nil and last_result.code == "bridge_committed", "real window consumer commits conclusive catalog without ambiguous occupancy")
end
for _, mode in { "oversize", "retry", "chain", "late", "reconcile_chain", "refused_chain", "ack", "ack_uncertain", "ack_terminal", "stale_witness", "scoped_poll",
	"suspend", "auto_reconcile", "auto_reconcile_bounded", "auto_reconcile_worker", "auto_reconcile_all", "capacity_resume", "expired_authorization",
	"duplicate_claim", "stale_claim", "slow_receipt", "window_bookkeeping", "background_settlement", "foreground_bootstrap", "background_launch", "background_adjacent", "stale_intent", "consumed_scope",
	"stale_result", "stale_result_lost", "stale_result_unrelated", "stale_result_kind", "stale_result_grant", "stale_result_grant_change",
	"held_withdrawal", "capacity_withdrawal" } do
	if section == nil or section == mode then window_consumer(mode) end
end
-- Each retirement section is independently runnable under the existing native callback budget.
local function retirement_fixture(clock, unstarted_project)
	local f = fixture(clock)
	if unstarted_project then f.default_project = f:project("Coordinator only — START withheld", false) end
	local id = f:accepted(true)
	function f:worker() return self.authority.registry.dispatch.workers[id] end
	function f:drain()
		for _ = 1, 24 do
			local w, needed = self:worker(), false
			for _, receipt in w.receipts do if receipt.publish then needed = true end end
			for _, reply in w.replies do if reply.part <= #reply.frames.chunks + 1 then needed = true end end
			needed = needed or w.compaction_pending ~= nil
			if not needed then return end
			local queued = self:apply("poll", { worker_id = id }); assert(queued.ok, queued.message)
			local request = self:action(queued.action_id).request
			assert(request.op == "mailbox_publish_ack" or request.op == "mailbox_publish_reply" or (request.op == "mailbox_retire" and request.mode == "compact"), request.op)
			assert(self:finish(queued.action_id, if request.op == "mailbox_retire" then "compacted" else "published", {}).ok)
		end
		error("bounded retirement outbox did not drain")
	end
	function f:ack(name)
		local w = self:worker(); local grant = w[name]; local reply = w.replies[tostring(grant.reply_seq)]
		local bytes = self:report(id, w.accepted_seq + 1, "reply_ack", { message_id = reply.message_id, reply_seq = reply.reply_seq,
			reply_sha256 = reply.sha256, status = "recorded" }, { action_id = grant.action_id, action_revision = grant.action_revision })
		return self:apply("intake", { worker_id = id, bytes = bytes })
	end
	function f:release(name, change)
		local w = self:worker(); local grant = w[name or "activation"]
		local payload = { owner_id = w.coordinator_owner_id, owner_generation = w.coordinator_generation, activation_token = grant.activation_token, quiescent = true }
		for k, v in change or {} do payload[k] = v end
		local bytes = self:report(id, w.accepted_seq + 1, "COORDINATOR_RELEASE", payload, { action_id = grant.action_id, action_revision = grant.action_revision })
		return self:apply("intake", { worker_id = id, bytes = bytes }), bytes
	end
	local watermark = f.watermark
	function f:watermark() return watermark(self, id) end
	function f:quiesce()
		self:drain(); assert(self:ack("activation").ok); local answer, bytes = self:release(); assert(answer.ok)
		self:drain(); self:watermark(); return bytes
	end
	return f, id
end
if section == nil or section == "retirement_auth" then
	local f, id = retirement_fixture()
	check(f:worker().activation ~= nil and not f:worker().activation.acknowledged, "accept issues one durable activation, not implicit native authority")
	local initial = f:worker().activation.bytes
	check(f:release().code == "release_unauthorized", "release before durable activation reply receipt is rejected")
	f:drain(); assert(f:ack("activation").ok)
	for _, changed in { { owner_id = "other-owner" }, { owner_generation = 999 }, { activation_token = string.rep("0", 64) } } do
		check(f:release(nil, changed).code == "release_unauthorized", "wrong owner/generation/token cannot mutate release")
	end
	local _, candidate = f:release(nil, { owner_id = "wrong-owner" })
	local forged = runtime.json.decode(candidate); forged.payload.owner_id = f:worker().coordinator_owner_id; forged.action_revision += 1
	check(f:apply("intake", { worker_id = id, bytes = runtime.json.encode(forged) }).code == "release_unauthorized", "wrong grant revision rejects")
	forged.action_revision -= 1; forged.worker_id = "other-worker"
	check(f:apply("intake", { worker_id = id, bytes = runtime.json.encode(forged) }).code == "binding_mismatch", "wrong managed worker rejects before mutation")
	f.memory.fail = true
	check(f:release().code == "persistence_failed" and f:worker().release == nil, "failed release commit creates no quiescence/cursor/receipt")
	f.memory.fail = false
	local applied, bytes = f:release(); check(applied.ok, "authenticated self-finish commits")
	local receipt = f:worker().receipts[tostring(f:worker().release.seq)].bytes
	check(f:apply("intake", { worker_id = id, bytes = bytes }).code == "report_replayed"
		and f:worker().receipts[tostring(f:worker().release.seq)].bytes == receipt, "exact release replay retains original receipt without repeat effect")
	check(f:worker().activation.bytes == initial and f:worker().replies["1"] == nil, "activation identity survives reply compaction")
	check(f:apply("reply", { worker_id = id }).code == "coordinator_retiring" and f:queue(true).code == "orchestrator_slot_occupied", "quiescence fences fresh coordinator work while slot remains occupied")
end
if section == nil or section == "retirement_finish" then
	local f, id = retirement_fixture(); local bytes = f:quiesce()
	local stop = f:apply("poll", { worker_id = id }); must(stop.ok, stop)
	assert(f:apply("claim", { action_id = stop.action_id, executor = f.origin.window_epoch }).ok)
	local request = f:action(stop.action_id).request
	check(request.op == "stop" and request.target_request_id == f:worker().launch_request_id and request.pane_binding.pane_id == "9002", "settled final watermark grants exact launched pane stop")
	check(f:apply("poll", { worker_id = id }).code == "operation_pending", "pending stop cannot be duplicated")
	check(protocol.decode_response(frame(request, "stopped", { pane_binding = request.pane_binding, observation = "idle" }), request) == nil, "idle is never stopped proof")
	assert(f:finish(stop.action_id, "stopped", { pane_binding = request.pane_binding, observation = "exited" }).ok)
	check(f.authority.registry.sessions[f.origin.logical_session_id].orchestrator ~= nil, "native stop alone does not free slot")
	local retire = f:apply("poll", { worker_id = id }); local rr = f:action(retire.action_id).request
	check(rr.op == "mailbox_retire" and rr.mode == "retire" and rr.report_floor == f:worker().accepted_seq and rr.reply_floor == f:worker().reply_seq, "mailbox retirement carries exact final floors and grant")
	check(f:finish(retire.action_id, "retired", {}).code == "coordinator_retired", "retirement result atomically uses normal generation-bound owner release")
	local old = f:worker().coordinator_owner_id
	check(f.authority.registry.sessions[f.origin.logical_session_id].orchestrator == nil and f.authority.registry.retired == nil, "owner clears without any retired-owner history")
	local old_generation = f:worker().coordinator_generation
	local successor = f:queue(true)
	check(successor.ok and f.authority.registry.sessions[f.origin.logical_session_id].orchestrator.generation > old_generation
		and f.authority.registry.dispatch.workers[id] == nil, "next reservation reclaims only fully retired unreferenced old generation while retaining owner tombstone")
	local newer = f.authority.registry.sessions[f.origin.logical_session_id].orchestrator.owner_id
	check(f:apply("intake", { worker_id = id, bytes = bytes }).code == "binding_mismatch"
		and f.authority.registry.sessions[f.origin.logical_session_id].orchestrator.owner_id == newer, "stale first-generation release never clears successor")
	check(f:apply("retire", { worker_id = id }).code == "activation_required", "stale UI retirement control cannot address successor")
	local restored = host.new_authority(f.memory); check(restored:load().ok, "retired evidence and successor validate through native host restoration")
end
if section == nil or section == "retirement_race" then
	local f, id = retirement_fixture(); f:drain(); assert(f:ack("activation").ok)
	check(f:apply("retire", { worker_id = id }).code == "retirement_requested", "owner requests one immutable typed retirement")
	local original = f:worker().retirement.bytes
	check(f:apply("retire", { worker_id = id }).code == "retirement_already_requested" and f:worker().retirement.bytes == original, "duplicate owner request is idempotent")
	check(f:release().ok, "self-finish can race an already-committed unconsumed retirement")
	f:drain(); f:watermark()
	local poll = f:apply("poll", { worker_id = id }); local req = f:action(poll.action_id).request
	check(req.op == "mailbox_retire" and req.mode == "compact", "unconsumed retirement prevents stop even after current report watermark")
	assert(f:finish(poll.action_id, "compacted", {}).ok)
	check(f:ack("retirement").ok, "late committed retirement drains after release without fresh work")
	f:drain(); f:watermark()
	local stop = f:apply("poll", { worker_id = id })
	check(f:action(stop.action_id).request.op == "stop", "final reply_ack watermark unlocks stop without deadlock")
end
if section == nil or section == "retirement_uncertain" then
	local f, id = retirement_fixture(); f:quiesce()
	local stop = f:apply("poll", { worker_id = id }); local req = f:action(stop.action_id).request
	check(f:finish(stop.action_id, "uncertain", nil).code == "effect_uncertain", "uncertain stop is retained")
	check(f:apply("poll", { worker_id = id }).code == "operation_pending" and f:apply("retry", { action_id = stop.action_id }).code == "retry_refused", "uncertain stop is never repeated")
	assert(f:finish(stop.action_id, "stopped", { pane_binding = req.pane_binding, observation = "absent" }).ok)
	local retire = f:apply("poll", { worker_id = id })
	check(f:finish(retire.action_id, "uncertain", nil).code == "effect_uncertain", "uncertain mailbox retirement is retained")
	check(f:apply("poll", { worker_id = id }).code == "operation_pending" and f.authority.registry.sessions[f.origin.logical_session_id].orchestrator ~= nil, "uncertain helper cannot clear slot")
	local restored = host.new_authority(f.memory)
	check(restored:load().ok and restored.registry.dispatch.actions[retire.action_id].phase == "uncertain", "restart preserves uncertain retirement and exact evidence")
end
if section == nil or section == "retirement_restore" then
	local f, id = retirement_fixture(); f:quiesce()
	local stop = f:apply("poll", { worker_id = id }); local req = f:action(stop.action_id).request
	assert(f:finish(stop.action_id, "stopped", { pane_binding = req.pane_binding, observation = "exited" }).ok)
	local retire = f:apply("poll", { worker_id = id }); assert(f:apply("claim", { action_id = retire.action_id, executor = "fixture-window" }).ok)
	f.memory.fail = true
	check(f:finish(retire.action_id, "retired", {}).code == "persistence_failed", "lost final commit returns no released owner")
	check(f:worker().mailbox_retired == nil and f.authority.registry.sessions[f.origin.logical_session_id].orchestrator ~= nil, "failed final commit keeps both old authority and retirement claim")
	f.memory.fail = false
	local restored = host.new_authority(f.memory)
	check(restored:load().ok and restored.registry.dispatch.actions[retire.action_id].phase == "uncertain", "reload converts possibly executed retirement into retained uncertainty")
	check(restored.registry.dispatch.workers[id].activation.acknowledged, "durable activation receipt survives restoration without a new token")
end
if section == nil or section == "retirement_capability" then
	local f = fixture(); f:catalog(0)
	f.authority.registry.dispatch.catalogs[f.origin.logical_session_id].records[1].capabilities = runtime.json.array({ "report-files-v1", "native-ask-v1" })
	f.memory.value = clone(f.authority.registry) -- Explicit old configured-catalog fixture.
	check(f:queue(true).code == "unsupported_capability", "old configured record cannot silently acquire coordinator support")
	check(f:queue(false).ok, "old record remains usable for ordinary work")
	local g = fixture(); local id = g:launched(true)
	-- Missing coordinator protocol is not a grant. Completed launch requests are consumed,
	-- so only the retained worker marker can be changed in this explicit negative fixture.
	g.authority.registry.dispatch.workers[id].coordinator_protocol = nil
	local w = g.authority.registry.dispatch.workers[id]
	g.memory.value = clone(g.authority.registry)
	assert(g:apply("intake", { worker_id = id, bytes = g:report(id, 1, "ACCEPTED", { assignment_sha256 = w.assignment_sha256 }) }).ok)
	assert(g:finish(g:apply("poll", { worker_id = id }).action_id, "published", {}).ok)
	assert(g:finish(g:apply("poll", { worker_id = id }).action_id, "accepted", {}).ok)
	check(g.authority.registry.dispatch.workers[id].activation == nil and g:apply("retire", { worker_id = id }).code == "activation_required", "legacy no-grant owner stays occupied; never silently activated")
	local restored = host.new_authority(g.memory)
	check(restored:load().ok and restored.registry.sessions[g.origin.logical_session_id].orchestrator ~= nil, "legacy CP2 shape restores without synthesizing release authority")
end
if section == nil or section == "retirement_codec" then
	local binding = { logical_session_id = "session", worker_id = "worker", worker_generation = 1, launch_request_id = "launch", work_id = "work",
		enrolment_token = "abcdefghijklmnop", mailbox_handle = "mailbox",
		capabilities = runtime.json.array({ "report-files-v1", "native-ask-v1", "worker-poll-v1", "argv-v1", "coordinator-control-v1" }) }
	local reply = { version = 1, message_id = "message", reply_seq = 1, action_id = "activation", action_revision = 1,
		kind = "coordinator_activation", payload = { owner_id = "owner", owner_generation = 1, activation_token = string.rep("a", 64), instructions = "Literal café $HOME stays data." } }
	for _, key in { "logical_session_id", "worker_id", "worker_generation", "launch_request_id", "work_id" } do reply[key] = binding[key] end
	check(codec.decode_reply(runtime.json.encode(reply), binding) ~= nil, "closed activation codec preserves typed grant and literal text")
	local ordinary = clone(binding); ordinary.capabilities = runtime.json.array({ "report-files-v1", "native-ask-v1" })
	local value, err = codec.decode_reply(runtime.json.encode(reply), ordinary)
	check(value == nil and err.code == "unsupported_capability", "report-files alone never authorizes new control replies")
	for _, mutate in {
		function(v) v.payload.activation_token = string.rep("A", 64) end,
		function(v) v.payload.owner_generation = 0 end,
		function(v) v.payload.extra = true end,
		function(v) v.payload.reason = "wrong kind field" end,
	} do local invalid = clone(reply); mutate(invalid); check(codec.decode_reply(runtime.json.encode(invalid), binding) == nil, "activation rejects malformed/unknown payload fields") end
	reply.kind = "coordinator_retirement"; reply.payload.instructions = nil; reply.payload.reason = "Finish safely"
	check(codec.decode_reply(runtime.json.encode(reply), binding) ~= nil, "closed retirement codec accepts exact reason payload")
	local report = clone(reply); report.version = 3; report.message_id = nil; report.reply_seq = nil; report.kind = "COORDINATOR_RELEASE"
	report.seq = 1; report.event_id = codec.sha256("mailbox:report:1"); report.enrolment_token = binding.enrolment_token
	report.payload.reason = nil; report.payload.quiescent = true
	check(codec.decode_report(runtime.json.encode(report), binding) ~= nil, "release codec requires full report binding and action correlation")
	value, err = codec.decode_report(runtime.json.encode(report), ordinary)
	check(value == nil and err.code == "unsupported_capability", "ordinary helper capability cannot grant coordinator release")
	for _, mutate in {
		function(v) v.action_id = nil; v.action_revision = nil end,
		function(v) v.payload.quiescent = false end,
		function(v) v.handover_id = "handover"; v.handover_token = "abcdefghijklmnop" end,
		function(v) v.payload.reason = "extra" end,
	} do local invalid = clone(report); mutate(invalid); check(codec.decode_report(runtime.json.encode(invalid), binding) == nil, "release rejects missing correlation and schema shortcuts") end
	report.kind = "REGISTER"; report.action_id = nil; report.action_revision = nil; report.payload = { capabilities = binding.capabilities }
	check(codec.decode_report(runtime.json.encode(report), binding) ~= nil, "REGISTER supports all five explicitly provisioned capability values")
end
if section == nil or section == "rejected_read" then
	local f = fixture(); local id = f:accepted(false)
	local bytes = f:report(id, 2, "DONE", { checkpoint_id = "absent", artifact_revision = "rev", summary = "Invalid checkpoint reference" })
	local framed = assert(codec.frame(bytes, "report", f.authority.registry.dispatch.workers[id]))
	local manifest = f:apply("poll", { worker_id = id })
	assert(f:finish(manifest.action_id, "read", runtime.json.decode(assert(codec.project_page(framed.manifest, f:action(manifest.action_id).request.selector)))).ok)
	local last
	for _, chunk in framed.chunks do
		local queued = f:apply("poll", { worker_id = id }); assert(queued.ok)
		local page = runtime.json.decode(assert(codec.project_page(chunk, f:action(queued.action_id).request.selector)))
		last = f:finish(queued.action_id, "read", page)
	end
	local w = f.authority.registry.dispatch.workers[id]
	check(last.code == "report_rejected" and last.report_applied == false, "completed semantic rejection is a committed transport result")
	check(w.accepted_seq == 1 and w.receipts["2"] == nil and w.rejected_report.bytes == bytes and w.rejected_report.code == "checkpoint_mismatch", "exact rejected bytes retained without cursor advancement or rejection ACK")
	check(w.assembly == nil and w.read_selector == nil and f.authority.registry.sessions[f.origin.logical_session_id].controller.pending_executors == 0, "completed rejected read releases assembly and global execution slot")
	check(not w.workflow.due_poll, "a held report with nothing outbound is not due for automatic polling")
	check(f:apply("poll", { worker_id = id }).code == "report_held", "hold never silently rereads/skips rejected report")
	check(f:apply("intake", { worker_id = id, bytes = f:report(id, 2, "HEARTBEAT", { state = "idle" }) }).code == "report_held",
		"direct intake cannot replace a held immutable report with different bytes at the same sequence")
	check(f:watermark(id).ok, "independent cumulative receipt settlement remains available")
	check(f.authority.registry.dispatch.workers[id].workflow.due_poll and f.authority.registry.dispatch.workers[id].compaction_pending ~= nil,
		"outbound settlement still makes the held worker due")
	local settle = f:apply("poll", { worker_id = id })
	check(settle.ok and f:action(settle.action_id).request.op == "mailbox_retire" and f:action(settle.action_id).request.mode == "compact",
		"the due poll grants outbound compaction, never a report re-read")
	assert(f:finish(settle.action_id, "compacted", {}).ok)
	check(not f.authority.registry.dispatch.workers[id].workflow.due_poll and f.authority.registry.dispatch.workers[id].rejected_report ~= nil,
		"once outbound settles the retained hold stops automatic polling again")
	local queued = f:queue(false)
	check(queued.ok and f:apply("claim", { action_id = queued.action_id, executor = f.origin.window_epoch }).ok, "another worker remains serviceable after semantic rejection")
	check(state.rehydrate(clone(f.authority.registry)) ~= nil, "rejection diagnostic and exact complete-read response validate on restore")
	-- A failed effect-result save poisons this live authority intentionally; it
	-- must not be reused as the successful settlement fixture.
	local failed = fixture(); local failed_id = failed:accepted(false)
	local failed_bytes = failed:report(failed_id, 2, "DONE", { checkpoint_id = "absent", artifact_revision = "rev", summary = "Invalid checkpoint reference" })
	local failed_frames = assert(codec.frame(failed_bytes, "report", failed.authority.registry.dispatch.workers[failed_id]))
	local objects = { failed_frames.manifest }
	for _, chunk in failed_frames.chunks do table.insert(objects, chunk) end
	for index, object in objects do
		local queued = failed:apply("poll", { worker_id = failed_id }); assert(queued.ok)
		local page = runtime.json.decode(assert(codec.project_page(object, failed:action(queued.action_id).request.selector)))
		if index == #objects then
			assert(failed:apply("claim", { action_id = queued.action_id, executor = failed.origin.window_epoch }).ok)
			failed.memory.fail = true
			check(failed:finish(queued.action_id, "read", page).code == "persistence_failed", "failed rejection save publishes no settlement")
			check(failed:action(queued.action_id).phase == "claimed" and failed.authority.registry.dispatch.workers[failed_id].rejected_report == nil,
				"failed save retains original claimed read and no exposed hold")
			failed.memory.fail = false
			check(failed:finish(queued.action_id, "read", page).code == "uncommitted_observation"
				and failed.authority.registry.sessions[failed.origin.logical_session_id].controller.pending_executors == 1,
				"same-runtime retry cannot bypass failed-result observation fence or release its occupied slot")
		else
			assert(failed:finish(queued.action_id, "read", page).ok)
		end
	end
end
local function stop_ordinary(f, id)
	local requested = f:apply("finish", { worker_id = id }); assert(requested.ok, requested.message)
	for _ = 1, 16 do
		local w = f.authority.registry.dispatch.workers[id]; local publish = false
		for _, receipt in w.receipts do if receipt.publish then publish = true end end
		if not publish then break end
		local queued = f:apply("poll", { worker_id = id }); assert(queued.ok)
		assert(f:action(queued.action_id).request.op == "mailbox_publish_ack")
		assert(f:finish(queued.action_id, "published", {}).ok)
	end
	assert(f:watermark(id).ok)
	local stop = f:apply("poll", { worker_id = id }); assert(stop.ok, stop.message)
	assert(f:action(stop.action_id).request.op == "stop")
	local pane = clone(f:action(stop.action_id).request.pane_binding)
	assert(f:finish(stop.action_id, "stopped", { pane_binding = pane, observation = "exited" }).ok)
	return requested
end
local function finish_ordinary(f, id)
	local requested = stop_ordinary(f, id)
	local retire = f:apply("poll", { worker_id = id }); assert(retire.ok, retire.message)
	assert(f:action(retire.action_id).request.mode == "retire")
	assert(f:finish(retire.action_id, "retired", {}).ok)
	return requested
end
if section == nil or section == "retirement_finish" then
	for _, remote in { false, true } do
		local f = fixture(); local subject = f:accepted(false)
		f.target_pane = "9012"; local writer_id = f:accepted(false)
		local function writer_worker() return f.authority.registry.dispatch.workers[writer_id] end
		assert(f:apply("associate_document", { worker_id = subject, path = "/fixture/another-workers-plan.md",
			evidence = { existing = true } }).ok)
		assert(f:apply("intake", { worker_id = subject, bytes = f:report(subject, 2, "ASK",
			{ question = "Which reviewed path?", options = runtime.json.array({ { id = "safe", label = "Safe path" } }) }) }).ok)
		local gid = next(f.authority.registry.dispatch.gates)
		assert(f:apply("answer", { gate_id = gid, gate_revision = 1, choice_id = "safe", answer = "Use the reviewed path." }).ok)
		local function gate() return f.authority.registry.dispatch.gates[gid] end
		local writer = { kind = "worker", worker_id = writer_id, worker_generation = writer_worker().worker_generation }
		local before = "# Existing plan owned by another worker\n"
		local evidence = { existing = true, quiescent = true, identity_proven = true, buffer_observed = true, disk_bytes = before }
		local prepared = f:apply("ruling_prepare", { gate_id = gid, gate_revision = gate().revision, writer = writer, evidence = evidence })
		must(prepared.ok and prepared.edit, prepared)
		if remote then
			local sent = f:apply("ruling_remote", { gate_id = gid, gate_revision = gate().revision, worker_id = writer_id })
			must(sent.ok, sent)
			local delivery = gate().ruling_delivery
			local reply = clone(writer_worker().replies[tostring(delivery.reply_seq)])
			assert(f:watermark(writer_id).ok) -- Publishes the real outbox before acknowledging receipt.
			assert(f:apply("intake", { worker_id = writer_id, bytes = f:report(writer_id, writer_worker().accepted_seq + 1, "reply_ack",
				{ message_id = reply.message_id, reply_seq = reply.reply_seq, reply_sha256 = reply.sha256, status = "recorded" },
				{ action_id = reply.action_id, action_revision = reply.action_revision }) }).ok)
		end
		finish_ordinary(f, writer_id)
		local ended = clone(writer_worker().stopped)
		local queued = f:queue(false); must(queued.ok, queued)
		check(writer_worker() ~= nil and writer_worker().mailbox_retired
			and runtime.json.encode(writer_worker().stopped) == runtime.json.encode(ended)
			and gate().ruling.intent.writer.worker_generation == writer.worker_generation,
			"another worker's unresolved ruling pins its exact ended writer, without preventing stop or retirement")
		check(state.rehydrate(clone(f.authority.registry)) ~= nil,
			"prepared and remotely acknowledged ruling writers remain valid across unrelated queue and reload")
		local edit = prepared.edit
		evidence.disk_bytes = before:sub(1, edit.offset) .. edit.text .. before:sub(edit.offset + 1)
		local observed = f:apply("ruling_observe", { gate_id = gid, gate_revision = gate().revision, writer = writer, evidence = evidence })
		must(observed.ok and observed.code == "ruling_recorded", observed)
		queued = f:queue(false); must(queued.ok, queued)
		check(writer_worker() == nil and state.rehydrate(clone(f.authority.registry)) ~= nil,
			"settled ruling releases only its writer dependency and leaves no completed writer history")
	end
end
local function last_sweep(f)
	local log = (f.authority.registry.dispatch.sweeps or {})[f.origin.logical_session_id]
	return if log then log.runs[#log.runs] else nil
end
local function sweep_entry(f, worker_id)
	for _, decision in last_sweep(f).decisions do if decision.worker_id == worker_id then return decision end end
	return nil
end
if section == nil or section == "finish" then
	local f = fixture(); local id = f:accepted(false)
	assert(f:apply("intake", { worker_id = id, bytes = f:report(id, 2, "ASK", { question = "Keep this pending?", options = runtime.json.array({ { id = "yes", label = "Yes" } }) }) }).ok)
	check(f:apply("finish", { worker_id = id }).code == "workflow_unsettled", "ordinary finish refuses unresolved owner question")
	local gate_id = next(f.authority.registry.dispatch.gates)
	assert(f:apply("cancel_gate", { gate_id = gate_id, gate_revision = 1 }).ok)
	local finish = f:event("finish", { worker_id = id })
	check(f.authority:apply(finish).code == "finish_requested", "owner explicitly requests ordinary finish without fabricating coordinator release")
	local finish_writes = f.memory.writes
	check(f.authority:apply(clone(finish)).code == "stale_revision" and f.memory.writes == finish_writes,
		"replayed finish retains its captured revision and cannot mutate current state")
	check(f:apply("reply", { worker_id = id }).code == "worker_retiring", "finish fences fresh progress requests")
	check(f:apply("intake", { worker_id = id, bytes = f:report(id, 3, "HEARTBEAT", { state = "idle" }) }).code == "worker_retiring", "finish fences late new reports")
	finish_ordinary(f, id)
	local w = f.authority.registry.dispatch.workers[id]
	check(w.mailbox_retired and w.stopped.observation == "exited" and w.release == nil and w.compacted_floor == w.accepted_seq, "ordinary finish requires exact native stop and settled mailbox retirement")
	check(state.rehydrate(clone(f.authority.registry)) ~= nil, "finished worker and exact retirement proofs pass persistence validation")
	local forged = clone(f.authority.registry); forged.dispatch.workers[id].finish.seq = w.accepted_seq + 1
	check(state.rehydrate(forged) == nil, "finish cannot claim an unaccepted report boundary")
end
-- SPAWN's exact pre-effect refusal (stopped producer journal unsettled) settles the attempt as
-- refused-without-effect; an uncertain retirement is never treated that way.
if section == nil or section == "retirement_refused" then
	local f = fixture(); local id = f:accepted(false)
	stop_ordinary(f, id)
	local retire = f:apply("poll", { worker_id = id }); assert(retire.ok and f:action(retire.action_id).request.mode == "retire")
	assert(f:apply("claim", { action_id = retire.action_id, executor = f.origin.window_epoch }).ok)
	local original_retirement = clone(f:action(retire.action_id).request)
	local refused = f:apply("result", { action_id = retire.action_id, executor = f.origin.window_epoch, grant_id = f:action(retire.action_id).claim.grant_id,
		response_bytes = frame(f:action(retire.action_id).request, "rejected", nil, { code = "producer_unsettled", message = "The stopped producer journal is not settled at the authorized floors; nothing was retired" }) })
	local w = f.authority.registry.dispatch.workers[id]
	check(refused.code == "retirement_refused" and f:action(retire.action_id) == nil and w.phase == "accepted"
		and w.reason.code == "retirement_refused" and not w.mailbox_retired, "exact pre-effect refusal settles the attempt without holding the worker or retiring the mailbox")
	check(not dispatch.unresolved(f.authority.registry, f.origin.logical_session_id, f.origin.owner_id), "a refused retirement releases its effect slot and blocks no owner clearing")
	check(f:apply("poll", { worker_id = id }).code == "retirement_refused", "the driver never re-issues a refused retirement by itself")
	check(state.rehydrate(clone(f.authority.registry)) ~= nil, "a refused retirement marker passes persistence validation")
	check(f:apply("finish", { worker_id = id }).code == "retirement_rearmed", "explicit owner control re-arms one fresh retirement")
	local again = f:apply("poll", { worker_id = id }); local request = f:action(again.action_id).request
	check(again.ok and again.action_id ~= retire.action_id and request.op == "mailbox_retire" and request.mode == "retire"
		and request.grant_id ~= original_retirement.grant_id, "the re-armed retirement carries a fresh grant")
	check(f:finish(again.action_id, "retired", {}).ok and f.authority.registry.dispatch.workers[id].mailbox_retired, "a settled journal then retires normally")
	local g = fixture(); local gid = g:accepted(false); stop_ordinary(g, gid)
	local uncertain = g:apply("poll", { worker_id = gid })
	check(g:finish(uncertain.action_id, "uncertain", nil).code == "effect_uncertain" and g:apply("finish", { worker_id = gid }).code == "finish_already_requested"
		and g:apply("poll", { worker_id = gid }).code == "operation_pending", "a possibly applied retirement stays uncertain and is never re-armed")
end
if section == nil or section == "sweep_rules" then
	local f = fixture()
	local function worker(id) return f.authority.registry.dispatch.workers[id] end
	local function ready(op, mode)
		local n = 0
		for _, a in f.authority.registry.dispatch.actions do
			if a.request.op == op and (mode == nil or a.request.mode == mode) and a.phase == "ready" then n += 1 end
		end
		return n
	end
	-- Every queue reclaims retired workers, so create all generations before settling any of them.
	local ids = {}
	for index, name in { "retired", "orphan", "live", "compacting", "uncertain", "held", "finishing" } do
		f.target_pane = tostring(9100 + index); ids[name] = f:accepted(false)
	end
	local queued = f:queue(false); assert(queued.ok) -- No mailbox yet: not a sweep subject.
	local retired, orphan, live, compacting, uncertain, held, finishing = ids.retired, ids.orphan, ids.live, ids.compacting, ids.uncertain, ids.held, ids.finishing
	finish_ordinary(f, retired)
	stop_ordinary(f, orphan) -- Exact stop observed; retirement never polled.
	assert(f:watermark(compacting).ok)
	local read = f:apply("poll", { worker_id = uncertain }); assert(read.ok)
	assert(f:apply("claim", { action_id = read.action_id, executor = f.origin.window_epoch }).ok)
	local grant = f:action(read.action_id).claim
	assert(f:apply("lost", { action_id = read.action_id, executor = grant.executor, grant_id = grant.grant_id }).ok)
	assert(f:read_report(held, f:report(held, 2, "DONE", { checkpoint_id = "absent", artifact_revision = "rev", summary = "Invalid checkpoint reference" })).code == "report_rejected")
	assert(f:apply("finish", { worker_id = finishing }).ok)
	check(worker(orphan).stopped ~= nil and not worker(orphan).mailbox_retired and worker(compacting).compaction_pending ~= nil, "fixture holds a stopped orphan mailbox and a live pending compaction")
	local stops, retires, compacts = ready("stop"), ready("mailbox_retire", "retire"), ready("mailbox_retire", "compact")
	local swept = f:apply("sweep", { local_date = "2026-11-03", catch_up = false })
	check(swept.ok and swept.code == "sweep_recorded" and swept.retire == 1 and swept.compact == 1, "one sweep run queues exactly one retirement and one compaction")
	local function decided(id, decision, reason)
		local entry = sweep_entry(f, id)
		return entry ~= nil and entry.decision == decision and entry.reason == reason
	end
	check(decided(retired, "none", "retired"), "already retired mailbox needs nothing")
	check(decided(orphan, "retire", "stopped_settled"), "provably stopped and settled orphan is retired")
	check(decided(live, "keep", "live") and decided(finishing, "keep", "finishing"), "live and finishing workers are kept; nothing is stopped")
	check(decided(compacting, "compact", "compaction_pending"), "live worker gets its pending compaction")
	check(decided(uncertain, "keep", "uncertain") and decided(held, "keep", "report_held"), "uncertain and held workers are kept with their reasons")
	check(sweep_entry(f, queued.worker_id) == nil, "a worker without a mailbox is not a sweep subject")
	check(ready("stop") == stops and ready("mailbox_retire", "retire") == retires + 1 and ready("mailbox_retire", "compact") == compacts + 1
		and f:action(read.action_id).phase == "uncertain", "exact effect counts: no stop, one retirement, one compaction; uncertainty untouched")
	local retirement = f:action(sweep_entry(f, orphan).action_id)
	check(retirement.request.op == "mailbox_retire" and retirement.request.mode == "retire" and worker(orphan).mailbox_retire_action_id == retirement.request.action_id
		and retirement.request.report_floor == worker(orphan).compacted_floor, "retirement is the existing exact mailbox_retire request bound to the worker")
	check(f:apply("poll", { worker_id = orphan }).code == "operation_pending", "the normal poll path sees the same queued retirement and issues no second grant")
	assert(f:finish(retirement.request.action_id, "retired", {}).ok)
	check(worker(orphan).mailbox_retired, "the sweep's retirement settles through the existing claim/result path")
	check(f:apply("sweep", { local_date = "2026-11-03" }).code == "sweep_already_ran" and f:apply("sweep", { local_date = "2026-11-02" }).code == "sweep_already_ran",
		"at most one run per scheduled day; earlier dates are refused")
	local next_day = f:apply("sweep", { local_date = "2026-11-04", catch_up = true })
	check(next_day.ok and last_sweep(f).catch_up and decided(orphan, "none", "retired") and decided(compacting, "keep", "effect_pending")
		and ready("mailbox_retire", "compact") == compacts + 1, "a later day re-evaluates without repeating a queued effect")
	for day = 5, 20 do assert(f:apply("sweep", { local_date = string.format("2026-11-%02d", day) }).ok) end
	local log = f.authority.registry.dispatch.sweeps[f.origin.logical_session_id]
	check(#log.runs == 14 and log.runs[1].local_date == "2026-11-07" and log.last_date == "2026-11-20", "the durable run log is a bounded ring of the latest 14 runs")
	check(state.rehydrate(clone(f.authority.registry)) ~= nil, "sweep log and decisions validate on restore")
	local forged = clone(f.authority.registry); forged.dispatch.sweeps[f.origin.logical_session_id].runs[14].decisions[1].reason = "guessed"
	check(state.rehydrate(forged) == nil, "unknown sweep reasons are corrupt state")
	forged = clone(f.authority.registry); forged.dispatch.sweeps[f.origin.logical_session_id].last_date = "2026-11-19"
	check(state.rehydrate(forged) == nil, "the last-run date must match the newest recorded run")
	assert(f:apply("policy", { policy = { sweep_enabled = false } }).ok)
	check(f:apply("sweep", { local_date = "2026-11-21" }).code == "sweep_disabled", "a disabled sweep records nothing")
	assert(f:apply("policy", { policy = { sweep_enabled = true } }).ok)
	check(f:apply("sweep", { local_date = "2026-13-01" }).code == "invalid_command", "the scheduled date must be a real YYYY-MM-DD")
end
if section == nil or section == "sweep_policy" then
	local f = fixture()
	local sid = f.origin.logical_session_id
	local saved = dispatch.policy(f.authority.registry, sid)
	check(saved.sweep_enabled == true and saved.sweep_time == "03:00:00", "the nightly sweep defaults on at 03:00 local time")
	for _, bad in { "3:00", "24:00", "12:60", "noon", "", 300 } do
		check(f:apply("policy", { policy = { sweep_time = bad } }).code == "invalid_policy", "sweep time " .. tostring(bad) .. " is refused")
	end
	check(f:apply("policy", { policy = { sweep_enabled = "yes" } }).code == "invalid_policy", "the sweep switch is a boolean")
	check(f:apply("policy", { policy = { sweep_time = "23:59:59", sweep_enabled = false } }).ok
		and dispatch.policy(f.authority.registry, sid).sweep_time == "23:59:59" and dispatch.policy(f.authority.registry, sid).sweep_enabled == false,
		"valid sweep settings save through the ordinary policy command")
	local legacy = clone(f.authority.registry)
	legacy.dispatch.policies[sid].sweep_enabled = nil; legacy.dispatch.policies[sid].sweep_time = nil
	-- A genuine pre-sweep policy also predates the rollover-routing, concurrency and Config v4 fields.
	for _, key in { "worker_rollover_records", "worker_rollover_provider", "worker_rollover_account", "worker_rollover_model", "coordinator_rollover_records",
		"coordinator_rollover_provider", "coordinator_rollover_account", "coordinator_rollover_model", "concurrency_limit",
		"loop_cap", "review_rounds", "stale_claim_min", "require_code_review", "require_other_family", "family_map", "reviewer_records", "release_manager_record", "checkout_roots",
		"auto_approve_kinds", "glitch_integration", "board_path", "board_lanes", "inbox_folder", "auto_start_projects", "routes",
		"labeller_record", "role_guidance", "templates" } do legacy.dispatch.policies[sid][key] = nil end
	check(not dispatch.valid(legacy.dispatch, legacy) and state.rehydrate(clone(legacy)) == nil,
		"current stores with missing sweep/Config fields fail closed rather than defaulting an apparent historical policy")
	local partial = clone(legacy); partial.dispatch.policies[sid].sweep_time = "03:00:00"
	check(state.rehydrate(partial) == nil, "a partial sweep policy is rejected, not defaulted")
	do
		local observed = fixture(function() return { now_ms = 1000 } end)
		local sid = observed.origin.logical_session_id
		local payload = { local_date = "2026-11-13", observed_at_ms = 1000, mailboxes = 0, time_zone = "UTC", observation_unavailable = true }
		check(observed:apply("cleanup_notice", payload).code == "cleanup_observation_pending" and not (observed.authority.registry.dispatch.cleanup_notices or {})[sid], "pending inventory does not consume the daily marker")
		payload.observation_unavailable = false; payload.open_files = 0; payload.stale_files = 0
		check(observed:apply("cleanup_notice", payload).code == "cleanup_summary", "a completed observed inventory records the daily interaction summary")
		local revision = observed.authority.registry.revision
		check(observed:apply("cleanup_notice", payload).code == "no_progress" and observed.authority.registry.revision == revision, "repeated interaction cannot notify or mutate the completed day again")
		local restored = assert(state.rehydrate(clone(observed.authority.registry)))
		check(restored.dispatch.cleanup_notices[sid] == payload.local_date, "daily communication summary marker survives reload")
	end
end
if section == nil or section == "slot_classes" then
	local function lose(f, action_id)
		assert(f:apply("claim", { action_id = action_id, executor = f.origin.window_epoch }).ok)
		local grant = f:action(action_id).claim
		assert(f:apply("lost", { action_id = action_id, executor = grant.executor, grant_id = grant.grant_id }).ok)
	end
	local reads = fixture(); reads:catalog(0)
	for _ = 1, 4 do local queued = reads:apply("catalog"); assert(queued.ok); lose(reads, queued.action_id) end
	local fifth = reads:apply("catalog"); assert(fifth.ok)
	check(reads:apply("claim", { action_id = fifth.action_id, executor = reads.origin.window_epoch }).ok,
		"four uncertain read-only catalogs leave every effect slot free")
	local effects = fixture(); effects:catalog(0)
	for _ = 1, 4 do local queued = effects:queue(false); assert(queued.ok); lose(effects, queued.action_id) end
	local blocked = effects:queue(false); assert(blocked.ok)
	local refused = effects:apply("claim", { action_id = blocked.action_id, executor = effects.origin.window_epoch })
	check(refused.code == "full" and effects:action(blocked.action_id).phase == "ready" and effects:action(blocked.action_id).claim == nil,
		"four uncertain mutating provisions still occupy every slot; the refusal is pre-effect and leaves the action ready")
	local running = fixture(); running:catalog(0)
	for _ = 1, 4 do local queued = running:apply("catalog"); assert(queued.ok); assert(running:apply("claim", { action_id = queued.action_id, executor = running.origin.window_epoch }).ok) end
	local queued = running:apply("catalog"); assert(queued.ok)
	check(running:apply("claim", { action_id = queued.action_id, executor = running.origin.window_epoch }).code == "full",
		"claimed reads still occupy a slot while they may run")
	local worker_fixture = fixture(); local id = worker_fixture:accepted(false)
	local read = worker_fixture:apply("poll", { worker_id = id }); assert(read.ok); lose(worker_fixture, read.action_id)
	check(worker_fixture:apply("poll", { worker_id = id }).code == "operation_pending",
		"an uncertain read still holds its own generation exclusively until reconciled")
	check(state.rehydrate(clone(reads.authority.registry)) ~= nil and state.rehydrate(clone(effects.authority.registry)) ~= nil, "slot classes need no new durable state")
end
if section == nil or section == "finish_capacity" then
	local f = fixture(); local first_id, first_report; local seen = {}
	for index = 1, 34 do
		local id = f:accepted(false)
		check(not seen[id], "reclaimed worker IDs never repeat"); seen[id] = true
		if index == 1 then first_id = id; first_report = f:report(id, 2, "HEARTBEAT", { state = "idle" }) end
		finish_ordinary(f, id)
	end
	check(f.authority.registry.dispatch.workers[first_id] == nil, "more than32 fully retired workers reclaim occupied generation capacity")
	local before = runtime.json.encode(f.authority.registry)
	check(not f:apply("intake", { worker_id = first_id, bytes = first_report }).ok and runtime.json.encode(f.authority.registry) == before, "late retired generation cannot regain report authority after reclamation")
	check(state.rehydrate(clone(f.authority.registry)) ~= nil, "bounded lifetime-worker reclamation restores with monotonic serial and cursor")
end
if section == nil or section == "command_retention" then
	local f = fixture(); local sid = f.origin.logical_session_id
	local old = f:event("pause"); assert(f.authority:apply(old).ok)
	assert(f:apply("resume").ok)
	local read = f:apply("catalog"); assert(read.ok)
	check(f:action(read.action_id).request.request_serial == nil, "queue identity is not an issued serial")
	assert(f:apply("claim", { action_id = read.action_id, executor = f.origin.window_epoch }).ok)
	local original = clone(f:action(read.action_id).request)
	for index = 1, 270 do assert(f:apply(if index % 2 == 1 then "pause" else "resume").ok) end
	check(f.authority.registry.dispatch.commands == nil and f.authority.registry.request_outcomes == nil
		and f.authority.registry.retired == nil, "ordinary commands retain no completed histories at any scope")
	local before, writes = runtime.json.encode(f.authority.registry), f.memory.writes
	check(f.authority:apply(old).code == "stale_revision" and runtime.json.encode(f.authority.registry) == before
		and f.memory.writes == writes, "captured stale revision cannot execute an old pause")
	assert(f:finish(read.action_id, "catalog", { catalog_version = 2, setup = catalog_setup(0), namespace = "fixture-spawn",
		host_key = "fixture-host", config_revision = 0, revision = 0, records = runtime.json.array() }).ok)
	check(f:action(read.action_id) == nil, "result consequence and action reclamation share one durable commit")
	local floor, consumed = dispatch.ack_progress(f.authority.registry, sid)
	check(floor == original.request_serial + 1 and #consumed == 0, "current issued counter and absent live action advance the floor without historical output")
	local restored = assert(state.rehydrate(clone(f.authority.registry)))
	check(restored.dispatch.command_cursors[sid].seq > old.command_seq and restored.dispatch.commands == nil,
		"current cursor survives reload without completed command records")
	local malformed = clone(f.authority.registry); malformed.dispatch.command_cursors[sid].seq = -1
	check(state.rehydrate(malformed) == nil, "malformed current cursor is refused at restore")
	local unfenced = f:event("pause"); unfenced.expected_revision = nil
	check(not f.authority:apply(unfenced).ok, "live clients cannot omit the captured authority fence")
end
if section == nil or section == "catalog_join" then
	local f = fixture(); local id = f:accepted(false)
	local sid = f.origin.logical_session_id
	local stored = clone(f.authority.registry)
	local restored = assert(state.rehydrate(stored))
	check(restored.dispatch.catalogs[sid].namespace == "fixture-spawn" and restored.dispatch.catalogs[sid].config_revision == 0,
		"current catalog retains its exact source and zero-valued configuration revision across restore")
	for _, field in { "namespace", "host_key", "config_revision" } do
		local broken = clone(stored); broken.dispatch.catalogs[sid][field] = nil
		check(state.rehydrate(broken) == nil, "partial catalog join cannot be mistaken for a legacy cache")
	end
	local legacy = clone(stored)
	legacy.dispatch.catalogs[sid].namespace = nil; legacy.dispatch.catalogs[sid].host_key = nil; legacy.dispatch.catalogs[sid].config_revision = nil
	legacy.dispatch.catalogs[sid].catalog_version = nil; legacy.dispatch.catalogs[sid].setup = nil
	check(state.rehydrate(clone(legacy)) == nil and not dispatch.valid(legacy.dispatch, legacy),
		"current catalog identity cannot be erased by pretending it is a historical cache")
	legacy.dispatch.catalogs[sid].unexpected = true
	check(state.rehydrate(legacy) == nil, "migration cannot hide malformed historical catalogs")
	for _, payload in {
		{ revision = 0, records = runtime.json.array() },
		{ namespace = "fixture-spawn", host_key = "fixture-host", config_revision = 1, revision = 0, records = runtime.json.array() },
	} do
		local rejected = fixture(); local request = rejected:apply("catalog")
		local refused = rejected:finish(request.action_id, "catalog", payload)
		check(not refused.ok and refused.code == "invalid_schema"
			and rejected.authority.registry.dispatch.catalogs[rejected.origin.logical_session_id] == nil
			and rejected:action(request.action_id).phase == "claimed",
			"canonical response validation rejects incomplete live catalog identity before applying any catalog: " .. runtime.json.encode(refused))
	end
end
if section == nil or section == "continuation" then
	local f = fixture(); local id = f:accepted(false)
	assert(f:apply("intake", { worker_id = id, bytes = f:report(id, 2, "ASK", { question = "Survive reload?", options = runtime.json.array({ { id = "yes", label = "Yes" } }) }) }).ok)
	local pending = f:apply("poll", { worker_id = id }); must(pending.ok, pending)
	assert(f:apply("claim", { action_id = pending.action_id, executor = f.origin.window_epoch }).ok)
	local original = clone(f.authority.registry.dispatch.workers[id]); local claim = clone(f:action(pending.action_id).claim)
	local bytes = frame(f:action(pending.action_id).request, "published")
	local old_result = f:event("result", { action_id = pending.action_id, executor = claim.executor, grant_id = claim.grant_id, response_bytes = bytes })
	f.authority = host.new_authority(f.memory); assert(f.authority:load().ok)
	f.origin.window_epoch = "replacement-window"
	f.controller_pane = "9010"
	check(not f:apply("poll", { worker_id = id }).ok, "reload never automatically adopts retained worker aliases")
	check(f:apply("continue_controller", { expected_revision = f.authority.registry.revision, operator_verified = true }).ok, "explicit exact-owner continuation establishes status-only replacement route")
	assert(f:control("reconcile_session").ok) -- Fresh peer observation restores admission, never the old revision fence.
	check(f.authority.registry.sessions[f.origin.logical_session_id].controller.pending_executors == 1, "controller continuation does not clear unknown executor occupancy")
	check(f:apply("continue_worker", { worker_id = id, pane_binding = { pane_id = "9009", window_key = "", window_epoch = f.origin.window_epoch, native_session_id = "7", window_host_id = "local" },
		continuation_proof = dispatch.continuation_proof(f.authority.registry, f.authority.registry.dispatch.workers[id]), operator_verified = true }).code == "settlement_pending", "attachment waits for individual old operation settlement")
	check(not f.authority:apply(old_result).ok, "old window callback is fenced even for its original exact grant")
	local projected = dispatch.project(f.authority.registry, f.origin.logical_session_id, f.origin.alias_nonce, pending.action_id)
	check(projected.actions[pending.action_id].execution_controller_pane == "9010" and projected.actions[pending.action_id].request.controller_pane == "9001"
		and projected.actions[pending.action_id].reconciliation_only, "changed window-local controller alias routes only status settlement without rewriting immutable request")
	check(f:apply("result", { action_id = pending.action_id, executor = claim.executor, grant_id = claim.grant_id, response_bytes = bytes }).ok, "read-only retained outcome settles original claim through explicit continued route")
	local pane = { pane_id = "9009", window_key = "", window_epoch = f.origin.window_epoch, native_session_id = "7", window_host_id = "local" }
	local attached = f:apply("continue_worker", { worker_id = id, pane_binding = pane,
		continuation_proof = dispatch.continuation_proof(f.authority.registry, f.authority.registry.dispatch.workers[id]), operator_verified = true }); assert(attached.ok, attached.message)
	check(f:finish(attached.action_id, "attached", { pane_binding = pane, previous_origin_binding = original.origin_binding, previous_pane_binding = original.pane_binding }).ok, "SPAWN exact selected attachment commits separately from launch identity")
	local w = f.authority.registry.dispatch.workers[id]
	check(w.origin_binding.window_epoch == original.origin_binding.window_epoch and w.pane_binding.pane_id == original.pane_binding.pane_id and w.control_pane_binding.pane_id == "9009", "attachment preserves immutable launch/mailbox identity and records distinct current route")
	local gid = next(f.authority.registry.dispatch.gates)
	check(f:apply("answer", { gate_id = gid, gate_revision = 1, choice_id = "yes", answer = "Same generation, same question." }).ok, "retained pending gate can be answered after explicit attachment")
	check(state.rehydrate(clone(f.authority.registry)) ~= nil, "attached route, original action claim and new-origin gate answer validate on restore")
	local corrupt = clone(f.authority.registry)
	corrupt.dispatch.workers[id].control_pane_binding.window_epoch = "different-native-incarnation"
	check(state.rehydrate(corrupt) == nil, "compact current attachment still rejects a pane from a different native incarnation without a completed action transcript")
	local coordinator = fixture(); local coordinator_id = coordinator:accepted(true)
	local activation = coordinator:apply("poll", { worker_id = coordinator_id }); assert(activation.ok)
	assert(coordinator:apply("claim", { action_id = activation.action_id, executor = coordinator.origin.window_epoch }).ok)
	coordinator.authority = host.new_authority(coordinator.memory); assert(coordinator.authority:load().ok)
	coordinator.origin.window_epoch = "continued-coordinator-window"
	assert(coordinator:apply("continue_controller", { expected_revision = coordinator.authority.registry.revision, operator_verified = true }).ok)
	assert(coordinator:control("reconcile_session").ok) -- Fresh peer observation restores admission, never the old revision fence.
	local owner = coordinator.authority.registry.sessions[coordinator.origin.logical_session_id].orchestrator
	check(owner.phase == "uncertain" and owner.pending_executors == 1 and coordinator:action(activation.action_id).phase == "uncertain",
		"controller continuation cannot reactivate uncertain coordinator authority or clear its old activation executor")
	do
		local automatic = fixture()
		local first, second = automatic:accepted(false), automatic:accepted(false)
		local reading = automatic:apply("poll", { worker_id = second }); assert(reading.ok)
		local function continue_with(proof)
			local worker = automatic.authority.registry.dispatch.workers[first]
			return automatic:apply("continue_worker", { worker_id = first, continuation_proof = proof,
				pane_binding = clone(worker.pane_binding), machine_proof = { previous_pane_binding = clone(worker.pane_binding) } })
		end
		local before = dispatch.continuation_proof(automatic.authority.registry, automatic.authority.registry.dispatch.workers[first])
		check(continue_with(before).code == "settlement_pending", "automatic attachment waits for another worker's outstanding session operation")
		assert(automatic:finish(reading.action_id, "missing", {}).ok)
		check(continue_with(before).code == "stale_recovery", "settling the other worker invalidates the previously refused continuation proof")
		local resumed = continue_with(dispatch.continuation_proof(automatic.authority.registry, automatic.authority.registry.dispatch.workers[first]))
		check(resumed.code == "attachment_queued" and automatic:action(resumed.action_id).worker_id == first,
			"a fresh scoped proof can continue the original worker after session settlement")
	end
end
if section == nil or section == "wake_separation" then
	local clock = { now_ms = 1000, mono_ms = 1000, epoch = "wake-host" }
	local f = fixture(function() return clone(clock) end); local ids = {}
	local function projected(id)
		for _, shown in dispatch.project(f.authority.registry, f.origin.logical_session_id, f.origin.alias_nonce).workflow.workers do
			if shown.worker_id == id then return shown end
		end
		error("missing wake worker")
	end
	for _ = 1, 4 do
		local id = f:accepted(false); table.insert(ids, id)
		local w = f.authority.registry.dispatch.workers[id]
		assert(f:apply("observe", { worker_id = id, pane_binding = w.pane_binding, native_state = "working" }).ok)
		assert(f:apply("intake", { worker_id = id, bytes = f:report(id, 2, "HEARTBEAT", { state = "working" }) }).ok)
		local queued = f:apply("poll", { worker_id = id }); local request = f:action(queued.action_id).request
		check(f:finish(queued.action_id, "published", { wake_status = "awaiting_window", wake_effect_started = false,
			wake_target_request_id = request.request_id, wake_target_action_id = request.action_id }).ok, "known publication commits independently of never-started notification")
		check(f:action(queued.action_id) == nil and f.authority.registry.dispatch.workers[id].wakes[request.action_id] ~= nil, "publication releases slot but retains durable wake obligation")
		check(not projected(id).poll_continuation and not projected(id).due_poll, "a busy native wake is not a runnable continuation")
	end
	check(f.authority.registry.sessions[f.origin.logical_session_id].controller.pending_executors == 0, "four busy workers do not occupy four execution slots merely waiting for idle")
	for _, id in ids do
		local queued = f:apply("poll", { worker_id = id }); assert(queued.ok, queued.message)
		check(f:action(queued.action_id).request.op == "mailbox_read" and f:finish(queued.action_id, "missing", {}).ok, "busy generation continues mailbox/receipt read progress")
	end
	local id = ids[1]; local w = f.authority.registry.dispatch.workers[id]
	assert(f:apply("observe", { worker_id = id, pane_binding = w.pane_binding, native_state = "idle" }).ok)
	check(projected(id).poll_continuation and projected(id).due_poll, "fresh idle wake bypasses the remaining discovery delay")
	-- No workflow tick between the clock change and poll: selection must refresh native health.
	clock.mono_ms += dispatch.policy(f.authority.registry, f.origin.logical_session_id).stale_ms + 1
	local stale = f:apply("poll", { worker_id = id, bytes = "watermark" }); assert(stale.ok, stale.message)
	check(f:action(stale.action_id).request.op == "mailbox_read" and f:action(stale.action_id).request.selector.stream == "watermark",
		"stale idle evidence cannot let a native wake preempt the periodic watermark")
	assert(f:finish(stale.action_id, "missing", {}).ok)
	assert(f:apply("observe", { worker_id = id, pane_binding = w.pane_binding, native_state = "idle" }).ok)
	local wake = f:apply("poll", { worker_id = id, bytes = "watermark" })
	check(f:action(wake.action_id).request.op == "native_wake", "fresh safe idle continuation precedes the periodic watermark")
	assert(f:apply("observe", { worker_id = id, pane_binding = w.pane_binding, native_state = "working" }).ok)
	check(f:action(wake.action_id) == nil and next(f.authority.registry.dispatch.workers[id].wakes) ~= nil, "busy race cancels only unclaimed wake action and retains notification obligation")
	local read = f:apply("poll", { worker_id = id }); check(f:action(read.action_id).request.op == "mailbox_read", "unstarted wake race cannot starve mailbox reads")
	assert(f:finish(read.action_id, "missing", {}).ok)
	assert(f:apply("observe", { worker_id = id, pane_binding = w.pane_binding, native_state = "idle" }).ok)
	wake = f:apply("poll", { worker_id = id }); assert(f:apply("claim", { action_id = wake.action_id, executor = f.origin.window_epoch }).ok)
	local grant = f:action(wake.action_id).claim
	assert(f:apply("lost", { action_id = wake.action_id, executor = grant.executor, grant_id = grant.grant_id }).ok)
	check(f:apply("poll", { worker_id = id }).code == "operation_pending" and f:apply("retry", { action_id = wake.action_id }).code == "retry_refused", "started/uncertain wake retains generation occupancy and cannot replay")
	check(state.rehydrate(clone(f.authority.registry)) ~= nil, "bounded pending and uncertain wake obligations survive strict restore")
end
if section == nil or section == "policy" then
	local clock = { now_ms = 1000, mono_ms = 1000, epoch = "policy-host" }
	local f = fixture(function() return clone(clock) end)
	local sid = f.origin.logical_session_id
	local function saved() return dispatch.project(f.authority.registry, sid, f.origin.alias_nonce).workflow.policy end
	local function projected(id) for _, worker in dispatch.project(f.authority.registry, sid, f.origin.alias_nonce).workflow.workers do if worker.worker_id == id then return worker end end end
	local defaults = saved()
	check(defaults.auto_rollover == true and defaults.rollover_include_coordinator == false
		and defaults.quota_routing == false and #defaults.excluded_workers == 0, "new session policy enables worker rollover without enabling coordinator rollover or quota routing")
	for _, bad in { 100, 80.5, -1, "80", true } do
		local before = runtime.json.encode(f.authority.registry)
		check(f:apply("policy", { policy = { rollover_threshold_pct = bad }, expected_policy_sha256 = quota.digest(saved()) }).code == "invalid_policy"
			and runtime.json.encode(f.authority.registry) == before, "rollover threshold " .. tostring(bad) .. " is refused with nothing changed")
	end
	for _, bad in { { auto_rollover = "yes" }, { rollover_include_coordinator = 1 }, { quota_routing = runtime.json.null }, { paused = true }, { unknown = true }, {} } do
		local before = runtime.json.encode(f.authority.registry)
		check(f:apply("policy", { policy = bad, expected_policy_sha256 = quota.digest(saved()) }).code == "invalid_policy" and runtime.json.encode(f.authority.registry) == before,
			"policy rejects undocumented, non-boolean or empty settings with nothing changed")
	end
	for _, threshold in { 1, 99, 0, 99 } do
		check(f:apply("policy", { policy = { rollover_threshold_pct = threshold }, expected_policy_sha256 = quota.digest(saved()) }).code == "policy_updated"
			and saved().rollover_threshold_pct == threshold, "rollover threshold " .. tostring(threshold) .. " is accepted")
	end
	check(f:apply("policy", { policy = { auto_rollover = true, rollover_include_coordinator = true, quota_routing = true }, expected_policy_sha256 = quota.digest(saved()) }).code == "policy_updated"
		and saved().auto_rollover and saved().rollover_include_coordinator and saved().quota_routing and saved().poll_ms == 300000,
		"partial Config save changes only the named settings")
	local displayed = saved()
	assert(f:apply("pause").ok)
	local before = runtime.json.encode(f.authority.registry)
	check(f:apply("policy", { policy = { auto_rollover = false }, expected_policy_sha256 = quota.digest(displayed) }).code == "policy_conflict"
		and runtime.json.encode(f.authority.registry) == before and saved().auto_rollover, "stale editor is refused after an intervening pause; nothing changes")
	assert(f:apply("resume").ok)
	local restored = assert(state.rehydrate(clone(f.authority.registry)))
	check(restored.dispatch.policies[sid].rollover_threshold_pct == 99 and restored.dispatch.policies[sid].quota_routing, "Config settings persist through strict restore")
	-- quota_routing now has a consumer; the remaining unrouted fixtures need explicit selection.
	assert(f:apply("policy", { policy = { quota_routing = false } }).ok)
	-- Historical-shaped policy bytes inside a current registry are corruption, not migration authority.
	local legacy = clone(f.authority.registry)
	legacy.dispatch.policies[sid] = { paused = true, poll_ms = 2000, heartbeat_ms = 10000, stale_ms = 30000, automatic_reports = true }
	check(not dispatch.valid(legacy.dispatch, legacy) and state.rehydrate(clone(legacy)) == nil,
		"current registry never silently upgrades an injected CP2 policy or invents its missing security settings")
	for _, forged in { { paused = false, poll_ms = 2000 }, { paused = false, poll_ms = 2000, heartbeat_ms = 10000, stale_ms = 30000, automatic_reports = true, unknown = 1 } } do
		local corrupt = clone(legacy); corrupt.dispatch.policies[sid] = forged
		check(state.rehydrate(corrupt) == nil, "partial or unknown-field stored policies are rejected, not defaulted")
	end
	local corrupt = clone(f.authority.registry); corrupt.dispatch.policies[sid].rollover_threshold_pct = 100
	check(state.rehydrate(corrupt) == nil, "stored out-of-range threshold is rejected")
	-- Exclusion is honored by automatic report scheduling and never stops anything.
	local id = f:accepted(false)
	local other = f:accepted(false)
	assert(f:apply("policy", { policy = { automatic_reports = true, report_request_ms = 5000, stale_ms = 600000 }, expected_policy_sha256 = quota.digest(saved()) }).ok)
	for _, worker_id in { id, other } do
		local w = f.authority.registry.dispatch.workers[worker_id]
		assert(f:apply("observe", { worker_id = worker_id, pane_binding = clone(w.pane_binding), native_state = "idle" }).ok)
	end
	clock.mono_ms += 6000
	assert(f:tick().ok)
	check(projected(id).due_report and projected(other).due_report, "fixture makes both safe idle workers due for automatic reports")
	check(f:apply("policy", { policy = { excluded_workers = { "worker-unknown" } }, expected_policy_sha256 = quota.digest(saved()) }).code == "invalid_policy",
		"exclusion must name a managed worker of this session")
	check(f:apply("policy", { policy = { excluded_workers = { id, id } }, expected_policy_sha256 = quota.digest(saved()) }).code == "invalid_policy",
		"duplicate exclusions are refused")
	local function actions_for(worker_id) local n = 0; for _, a in f.authority.registry.dispatch.actions do if a.worker_id == worker_id then n += 1 end end; return n end
	local w_before, actions_before = clone(f.authority.registry.dispatch.workers[id]), actions_for(id)
	check(f:apply("policy", { policy = { excluded_workers = { id } }, expected_policy_sha256 = quota.digest(saved()) }).code == "policy_updated"
		and projected(id).orchestration_excluded and not projected(id).due_report and projected(other).due_report,
		"unticked managed worker is skipped by automatic report scheduling; others remain due")
	local w = f.authority.registry.dispatch.workers[id]
	check(w.phase == w_before.phase and w.stop_action_id == nil and w.finish == nil and w.retirement == nil and w.mailbox_retire_action_id == nil
		and runtime.json.encode(w.pane_binding) == runtime.json.encode(w_before.pane_binding) and actions_for(id) == actions_before,
		"exclusion never stops, finishes, retires or rebinds the worker")
	clock.mono_ms += 6000
	assert(f:tick().ok)
	check(not projected(id).due_report, "later ticks keep the excluded worker out of automatic scheduling")
	check(f:apply("observe", { worker_id = id, pane_binding = clone(w.pane_binding), native_state = "idle" }).ok, "excluded worker health observation continues")
	check(state.rehydrate(clone(f.authority.registry)).dispatch.policies[sid].excluded_workers[1] == id, "exclusion persists by durable worker_id")
	check(f:apply("policy", { policy = { excluded_workers = {} }, expected_policy_sha256 = quota.digest(saved()) }).code == "policy_updated" and projected(id).due_report,
		"re-ticking restores automatic scheduling eligibility")
end
-- Verified worker rollover (CP4). Epoch-bound clocks make native liveness evidence fresh.
local function rollover_fixture()
	local clock = { now_ms = 1000, mono_ms = 1000, epoch = "rollover-host" }
	local f = fixture(function() return clone(clock) end)
	local id = f:accepted(false)
	assert(f:apply("observe", { worker_id = id, pane_binding = clone(f.authority.registry.dispatch.workers[id].pane_binding), native_state = "idle" }).ok)
	return f, id, clock
end
local function worker_of(f, id) return f.authority.registry.dispatch.workers[id] end
local function rollover_of(f, hid) return f.authority.registry.dispatch.rollovers[hid] end
local function send_report(f, id, kind, payload, extra)
	return f:apply("intake", { worker_id = id, bytes = f:report(id, worker_of(f, id).accepted_seq + 1, kind, payload, extra) })
end
local function handover_checkpoint(checkpoint_id, request_id, outcome)
	return { checkpoint_id = checkpoint_id, task_ref = "task:fixture", project_id = "project-one", worktree_ref = "worktree:fixture", artifact_revision = "revision-one",
		completed = runtime.json.array({ "Implemented the first half" }), remaining = runtime.json.array({ "Finish the second half" }), holds = runtime.json.array(),
		checks = runtime.json.array({ { check_id = "unit", artifact_revision = "revision-one", outcome = outcome or "passed", evidence_ref = "unit:fixture" } }), request_id = request_id }
end
local function answer_checkpoint(f, id, checkpoint_id, outcome)
	local request = clone(worker_of(f, id).workflow.report_request)
	assert(send_report(f, id, "reply_ack", { message_id = request.message_id, reply_seq = request.reply_seq, reply_sha256 = codec.sha256(request.bytes), status = "recorded" },
		{ action_id = request.action_id, action_revision = request.action_revision }).ok)
	return send_report(f, id, "CHECKPOINT", handover_checkpoint(checkpoint_id, request.request_id, outcome)), request
end
local function rollover_granted(f, id)
	local requested = f:apply("rollover", { worker_id = id, trigger = "owner" }); assert(requested.ok and requested.code == "rollover_requested", requested.message)
	assert(rollover_of(f, requested.handover_id).phase == "checkpoint_pending")
	assert(answer_checkpoint(f, id, "rollover-cp-1").ok)
	assert(rollover_of(f, requested.handover_id).phase == "successor_granted", rollover_of(f, requested.handover_id).phase)
	return requested.handover_id, rollover_of(f, requested.handover_id).successor_worker_id
end
local function actions_of(f, worker_id, op)
	local found = {}
	for key, a in f.authority.registry.dispatch.actions do if a.worker_id == worker_id and a.request.op == op then table.insert(found, key) end end
	return found
end
local function successor_provisioned(f, succ_id)
	local provision = actions_of(f, succ_id, "mailbox_provision"); assert(#provision == 1)
	assert(f:finish(provision[1], "provisioned", { handle = "mailbox-successor", binding_digest = string.rep("b", 64),
		capabilities = runtime.json.array({ "report-files-v1", "native-ask-v1" }), limits = {} }).ok)
	return worker_of(f, succ_id).launch_action_id
end
local function successor_pane(f) return { pane_id = "9003", window_key = f.origin.window_key, window_epoch = f.origin.window_epoch,
	native_session_id = f.origin.native_session_id, window_host_id = f.origin.window_host_id } end
local function successor_created(f, succ_id)
	local launch = successor_provisioned(f, succ_id)
	assert(f:finish(launch, "awaiting_acceptance", { pane_binding = successor_pane(f) }).ok)
end
local function successor_accepted_report(f, succ_id, extra)
	local succ = worker_of(f, succ_id)
	return f:apply("intake", { worker_id = succ_id, bytes = f:report(succ_id, 1, "ACCEPTED", { assignment_sha256 = succ.assignment_sha256 }, extra) })
end
local function successor_accept_request(f, succ_id)
	local succ = worker_of(f, succ_id)
	assert(successor_accepted_report(f, succ_id, { handover_id = succ.handover_id, handover_token = succ.handover_token }).ok)
	local publish = f:apply("poll", { worker_id = succ_id }); assert(f:action(publish.action_id).request.op == "mailbox_publish_ack")
	assert(f:finish(publish.action_id, "published", {}).ok)
	local accept = f:apply("poll", { worker_id = succ_id }); assert(accept.ok, accept.message)
	return accept.action_id, clone(f:action(accept.action_id).request)
end
local function predecessor_stop_action(f, id)
	for _ = 1, 16 do
		local publish = false
		for _, receipt in worker_of(f, id).receipts do if receipt.publish then publish = true end end
		if not publish then break end
		local queued = f:apply("poll", { worker_id = id }); assert(queued.ok, queued.message)
		assert(f:action(queued.action_id).request.op == "mailbox_publish_ack")
		assert(f:finish(queued.action_id, "published", {}).ok)
	end
	assert(f:watermark(id).ok)
	local stop = f:apply("poll", { worker_id = id }); assert(stop.ok, stop.message)
	assert(f:action(stop.action_id).request.op == "stop")
	return stop.action_id
end
local function rollover_to_stop_requested(f, id)
	local hid, succ_id = rollover_granted(f, id)
	successor_created(f, succ_id)
	local accept_id = successor_accept_request(f, succ_id)
	assert(f:finish(accept_id, "accepted", {}).ok)
	assert(f:apply("observe", { worker_id = succ_id, pane_binding = clone(worker_of(f, succ_id).pane_binding), native_state = "working" }).ok)
	assert(rollover_of(f, hid).phase == "predecessor_stop_requested", rollover_of(f, hid).phase)
	return hid, succ_id
end
if section == nil or section == "rollover" then
	local f, id = rollover_fixture()
	local requested = f:apply("rollover", { worker_id = id, trigger = "owner" })
	check(requested.ok and requested.code == "rollover_requested", "explicit owner control requests worker rollover")
	local hid = requested.handover_id; local r = rollover_of(f, hid)
	check(r.phase == "checkpoint_pending" and r.trigger == "owner" and r.controller_generation == f.origin.owner_generation
		and r.history == nil, "current checkpoint_pending edge is durable and controller-bound without completed phase history")
	local issued = codec.decode_reply(worker_of(f, id).workflow.report_request.bytes, worker_of(f, id))
	check(issued.kind == "report_request" and issued.payload.requested_kind == "CHECKPOINT", "rollover asks through the existing structured progress-request channel")
	check(f:apply("finish", { worker_id = id }).code == "workflow_unsettled", "ordinary finish cannot discard an unfinished rollover")
	local workers_before = 0; for _ in f.authority.registry.dispatch.workers do workers_before += 1 end
	local unverified = answer_checkpoint(f, id, "rollover-cp-0", "not_run")
	check(unverified.ok and rollover_of(f, hid).phase == "checkpoint_pending" and rollover_of(f, hid).hold.code == "verification_missing",
		"a checkpoint without required verification outcomes blocks rather than passes")
	local workers_after = 0; for _ in f.authority.registry.dispatch.workers do workers_after += 1 end
	check(workers_after == workers_before and worker_of(f, id).finish == nil, "blocked checkpoint launches nothing and keeps the predecessor")
	check(f:apply("rollover", { worker_id = id, trigger = "owner" }).code == "checkpoint_rerequested" and rollover_of(f, hid).phase == "checkpoint_pending",
		"owner can request the checkpoint again on the same handover")
	check(answer_checkpoint(f, id, "rollover-cp-1").ok, "fresh verified checkpoint accepted")
	r = rollover_of(f, hid)
	local succ_id = r.successor_worker_id; local succ = worker_of(f, succ_id)
	check(r.phase == "successor_granted" and r.verification.attestation == "worker-attested" and r.verification.checkpoint_id == "rollover-cp-1",
		"verified checkpoint is recorded as worker-attested evidence before the successor grant")
	check(succ.handover_id == hid and succ.handover_token == r.handover_token and succ.work_id == worker_of(f, id).work_id
		and succ.record_id == worker_of(f, id).record_id and succ.prompt:find("CHECKPOINT", 1, true) ~= nil
		and succ.prompt:find(worker_of(f, id).enrolment_token, 1, true) == nil, "successor is a fresh record whose assignment is the checkpoint, never predecessor credentials")
	check(#actions_of(f, succ_id, "mailbox_provision") == 1 and worker_of(f, id).finish == nil, "successor grant reuses provisioning; predecessor untouched")
	check(state.rehydrate(clone(f.authority.registry)) ~= nil, "granted rollover restores")
	local launch = successor_provisioned(f, succ_id)
	local launch_request = f:action(launch).request
	check(launch_request.fresh == true and launch_request.enrolment.handover_id == hid and launch_request.enrolment.handover_token == r.handover_token,
		"immutable fresh launch enrolment carries the handover pair")
	assert(f:finish(launch, "awaiting_acceptance", { pane_binding = successor_pane(f) }).ok)
	check(rollover_of(f, hid).phase == "successor_created" and rollover_of(f, hid).successor_pane_binding.pane_id == "9003", "successor pane binding is a durable edge")
	local accept_id, accept_request = successor_accept_request(f, succ_id)
	check(accept_request.op == "accept" and accept_request.handover_id == hid and accept_request.handover_token == r.handover_token, "SPAWN accept carries the matching handover pair")
	check(rollover_of(f, hid).phase == "successor_created", "ACCEPTED alone waits for SPAWN semantic acceptance")
	assert(f:finish(accept_id, "accepted", {}).ok)
	r = rollover_of(f, hid)
	check(r.phase == "handover_accepted" and r.hold.code == "successor_liveness_unconfirmed" and worker_of(f, id).finish == nil,
		"handover acceptance alone never stops the predecessor without current successor liveness")
	assert(f:apply("observe", { worker_id = succ_id, pane_binding = clone(worker_of(f, succ_id).pane_binding), native_state = "working" }).ok)
	check(rollover_of(f, hid).phase == "predecessor_stop_requested" and worker_of(f, id).finish.request_id == hid, "live accepted successor opens the existing finish/stop path")
	local stop = predecessor_stop_action(f, id)
	check(rollover_of(f, hid).phase == "predecessor_stop_requested", "stop grant is not closure")
	local forged = clone(f.authority.registry); forged.dispatch.rollovers[hid].phase = "predecessor_closed"; forged.dispatch.rollovers[hid].stop_observation = nil
	check(state.rehydrate(forged) == nil, "a claimed stop cannot be promoted to closed without positive exit evidence")
	assert(f:finish(stop, "stopped", { pane_binding = clone(f:action(stop).request.pane_binding), observation = "exited" }).ok)
	check(rollover_of(f, hid) == nil and f:action(stop) == nil
		and worker_of(f, succ_id).phase == "accepted" and worker_of(f, succ_id).finish == nil and worker_of(f, succ_id).stopped == nil,
		"observed predecessor exit settles and reclaims the handover and stop action; successor keeps the work")
	check(state.rehydrate(clone(f.authority.registry)) ~= nil, "completed handover absence restores without a phase history")
end
if section == nil or section == "rollover_launch_failure" then
	local f, id = rollover_fixture()
	local hid, succ_id = rollover_granted(f, id)
	local launch = successor_provisioned(f, succ_id)
	assert(f:apply("claim", { action_id = launch, executor = f.origin.window_epoch }).ok)
	local a = f:action(launch)
	check(f:apply("result", { action_id = launch, executor = f.origin.window_epoch, grant_id = a.claim.grant_id,
		response_bytes = frame(a.request, "rejected", nil, { code = "input_too_large", message = "Successor task exceeds the configured argv bound." }) }).ok, "SPAWN refusal commits")
	local r, pred = rollover_of(f, hid), worker_of(f, id)
	check(r.phase == "successor_granted" and r.hold.code == "successor_launch_failed" and worker_of(f, succ_id).reason.code == "input_too_large",
		"failed successor launch retains phase and evidence")
	check(pred.phase == "accepted" and pred.finish == nil and pred.stop_action_id == nil and #actions_of(f, id, "stop") == 0, "failed successor launch leaves the predecessor alive and unstopped")
	check(f:apply("rollover", { worker_id = id, trigger = "owner" }).code == "rollover_in_progress", "no second successor is granted beside a failed one")
	check(state.rehydrate(clone(f.authority.registry)) ~= nil, "held rollover restores")
	check(f:apply("close_handover", { worker_id = id }).code == "handover_effect_started"
		and rollover_of(f, hid).hold.code == "successor_launch_failed", "a failed launch cannot erase its already provisioned successor")
	check(f:apply("rollover", { worker_id = id, trigger = "owner" }).code == "rollover_in_progress", "no alternate successor is allocated while that effect remains")
	local cancelled = f:apply("cancel_work", { worker_id = succ_id }); assert(cancelled.ok, cancelled.message)
	check(cancelled.code == "withdrawal_retiring" and f:action(cancelled.action_id).request.op == "mailbox_retire"
		and worker_of(f, id).stop_action_id == nil, "owner cancellation retires only the definitively refused unused successor, never the live predecessor")
	check(f:apply("close_handover", { worker_id = id }).code == "handover_effect_started",
		"owner handover close still waits for positive successor retirement")
	assert(f:finish(cancelled.action_id, "retired", {}).ok)
	check(f:apply("close_handover", { worker_id = id }).code == "handover_closed" and worker_of(f, succ_id) == nil
		and worker_of(f, id).phase == "accepted" and worker_of(f, id).finish == nil and #actions_of(f, id, "stop") == 0,
		"separate owner close removes a positively retired refused successor and preserves its untouched predecessor")
	check(state.rehydrate(clone(f.authority.registry)) ~= nil, "explicit failed-successor retirement and owner close restore without a replay")
end
if section == nil or section == "rollover_token" then
	local f, id = rollover_fixture()
	local hid, succ_id = rollover_granted(f, id)
	successor_created(f, succ_id)
	local succ = worker_of(f, succ_id)
	local before = runtime.json.encode(f.authority.registry)
	local missing = successor_accepted_report(f, succ_id)
	check(not missing.ok and missing.code == "binding_mismatch" and runtime.json.encode(f.authority.registry) == before, "successor ACCEPTED without the handover pair is rejected unchanged")
	local wrong = successor_accepted_report(f, succ_id, { handover_id = hid, handover_token = string.rep("0", 64) })
	check(not wrong.ok and wrong.code == "binding_mismatch" and runtime.json.encode(f.authority.registry) == before, "wrong handover token is rejected unchanged")
	local foreign = successor_accepted_report(f, succ_id, { handover_id = "handover-other", handover_token = succ.handover_token })
	check(not foreign.ok and runtime.json.encode(f.authority.registry) == before, "another handover ID is rejected")
	check(rollover_of(f, hid).phase == "successor_created" and worker_of(f, id).finish == nil, "rejected acceptance leaves the predecessor running")
	local accept_id = successor_accept_request(f, succ_id)
	local corrupt = clone(f.authority.registry); local forged = corrupt.dispatch.actions[accept_id]
	forged.request.handover_id = nil; forged.request.handover_token = nil; forged.request_bytes = runtime.json.encode(forged.request)
	check(state.rehydrate(corrupt) == nil, "a retained rollover accept without its handover pair cannot restore")
	assert(f:finish(accept_id, "accepted", {}).ok)
	check(rollover_of(f, hid).phase == "handover_accepted", "exact handover acceptance advances")
end
if section == nil or section == "rollover_stop_uncertain" then
	local f, id = rollover_fixture()
	local hid, succ_id = rollover_to_stop_requested(f, id)
	local stop = predecessor_stop_action(f, id)
	assert(f:apply("claim", { action_id = stop, executor = f.origin.window_epoch }).ok)
	local grant = f:action(stop).claim
	assert(f:apply("lost", { action_id = stop, executor = grant.executor, grant_id = grant.grant_id }).ok)
	local r = rollover_of(f, hid)
	check(r.phase == "predecessor_stop_requested" and r.hold.code == "predecessor_stop_uncertain", "uncertain predecessor stop holds with evidence")
	check(not f:apply("poll", { worker_id = id }).ok and f:apply("retry", { action_id = stop }).code == "retry_refused" and #actions_of(f, id, "stop") == 1,
		"an uncertain stop is never retried or reissued")
	check(worker_of(f, succ_id).phase == "accepted" and worker_of(f, succ_id).finish == nil and rollover_of(f, hid).phase ~= "complete", "successor keeps the work; rollover is not complete")
	f.authority = host.new_authority(f.memory); assert(f.authority:load().ok)
	check(rollover_of(f, hid).phase == "predecessor_stop_requested" and f:action(stop).phase == "uncertain", "reload retains the stop hold")
end
if section == nil or section == "rollover_reload" then
	local f, id = rollover_fixture()
	local hid, succ_id = rollover_granted(f, id)
	f.authority = host.new_authority(f.memory); assert(f.authority:load().ok)
	check(rollover_of(f, hid).phase == "successor_granted" and rollover_of(f, hid).successor_worker_id == succ_id, "reload resumes from the durable granted phase")
	-- Restore makes the controller uncertain: nothing (including rollover progress) advances until
	-- the same owner explicitly continues after verifying old executors.
	local idle = { worker_id = id, pane_binding = clone(worker_of(f, id).pane_binding), native_state = "idle" }
	check(f:apply("observe", idle).code == "controller_mismatch" and rollover_of(f, hid).phase == "successor_granted", "restored uncertain controller cannot advance a rollover")
	assert(f:apply("continue_controller", { expected_revision = f.authority.registry.revision, operator_verified = true }).ok)
	assert(f:control("reconcile_session").ok) -- Fresh peer observation restores admission, never the old revision fence.
	assert(f:apply("observe", idle).ok)
	local successors = 0; for _, w in f.authority.registry.dispatch.workers do if w.handover_id == hid then successors += 1 end end
	check(successors == 1 and #actions_of(f, succ_id, "mailbox_provision") == 1, "post-reload progress creates no duplicate successor or provision")
	local held_provision = actions_of(f, succ_id, "mailbox_provision")[1]
	check(f:action(held_provision).phase == "held_ready"
		and not f:apply("claim", { action_id = held_provision, executor = f.origin.window_epoch }).ok
		and #actions_of(f, succ_id, "launch") == 0, "restored unissued-looking successor remains held; peer absence cannot authorize replay")
	local g, gid = rollover_fixture()
	local ghid, gsucc = rollover_granted(g, gid)
	local launch = successor_provisioned(g, gsucc)
	assert(g:apply("claim", { action_id = launch, executor = g.origin.window_epoch }).ok)
	g.authority = host.new_authority(g.memory); assert(g.authority:load().ok)
	check(g:action(launch).phase == "uncertain", "reload turns the claimed successor launch uncertain")
	assert(g:apply("continue_controller", { expected_revision = g.authority.registry.revision, operator_verified = true }).ok)
	assert(g:control("reconcile_session").ok) -- Fresh peer observation restores admission, never the old revision fence.
	assert(g:apply("observe", { worker_id = gid, pane_binding = clone(worker_of(g, gid).pane_binding), native_state = "idle" }).ok)
	check(rollover_of(g, ghid).phase == "successor_granted" and rollover_of(g, ghid).hold.code == "successor_launch_uncertain", "uncertain launch after reload holds")
	check(g:apply("close_handover", { worker_id = gid }).code == "handover_effect_started" and #actions_of(g, gsucc, "launch") == 1
		and worker_of(g, gid).finish == nil, "uncertain successor launch is neither cancelled, duplicated nor allowed to stop the predecessor")
	assert(g:allocation(gsucc, { state = "none" }).ok)
	local close = g:apply("close_handover", { worker_id = gid })
	local cancel = g:apply("cancel_work", { worker_id = gsucc })
	check(not close.ok and not cancel.ok and g:action(launch).phase == "uncertain" and worker_of(g, gid).finish == nil,
		"allocation absence cannot cancel an unknown native launch or handover: " .. runtime.json.encode({ close = close, cancel = cancel }))
	-- A replacement window incarnation fences the never-claimed successor intent instead of replaying it.
	local h, hid_worker = rollover_fixture()
	local hhid, hsucc = rollover_granted(h, hid_worker)
	h.authority = host.new_authority(h.memory); assert(h.authority:load().ok)
	h.origin.window_epoch = "replacement-window"
	assert(h:apply("continue_controller", { expected_revision = h.authority.registry.revision, operator_verified = true }).ok)
	assert(h:control("reconcile_session").ok) -- Fresh peer observation restores admission, never the old revision fence.
	local provision = h:action(actions_of(h, hsucc, "mailbox_provision")[1])
	check(provision.phase == "held_ready" and provision.request.request_serial == nil
		and #actions_of(h, hsucc, "launch") == 0 and #actions_of(h, hsucc, "mailbox_provision") == 1 and worker_of(h, hid_worker).finish == nil,
		"a changed window preserves an unknown restored intention; no nonexecution claim, duplicate or predecessor stop")
	check(state.rehydrate(clone(h.authority.registry)) ~= nil, "fenced rollover hold restores")
end
if section == nil or section == "rollover_policy" then
	local f, id = rollover_fixture()
	local sid = f.origin.logical_session_id
	local function projected(worker_id) for _, worker in dispatch.project(f.authority.registry, sid, f.origin.alias_nonce).workflow.workers do if worker.worker_id == worker_id then return worker end end end
	local function rollovers() local n = 0; for _ in f.authority.registry.dispatch.rollovers or {} do n += 1 end; return n end
	assert(f:apply("policy", { policy = { auto_rollover = true, rollover_threshold_pct = 50 } }).ok)
	assert(send_report(f, id, "READY", { state = "idle", context_used_pct = 40 }).ok)
	check(not projected(id).due_rollover and f:apply("rollover", { worker_id = id, trigger = "policy" }).code == "rollover_not_due" and rollovers() == 0,
		"context below the threshold never triggers rollover")
	assert(send_report(f, id, "READY", { state = "idle", context_used_pct = 60 }).ok)
	check(not projected(id).due_rollover, "threshold alone cannot roll over mid-work")
	assert(send_report(f, id, "CHECKPOINT", handover_checkpoint("completed-boundary")).ok)
	check(projected(id).due_rollover, "completed-work checkpoint after threshold makes idle worker rollover eligible")
	assert(f:apply("policy", { policy = { excluded_workers = { id } } }).ok)
	check(not projected(id).due_rollover and f:apply("rollover", { worker_id = id, trigger = "policy" }).code == "rollover_not_due" and rollovers() == 0,
		"excluded worker is never rolled over automatically")
	assert(f:apply("policy", { policy = { excluded_workers = {}, auto_rollover = false } }).ok)
	check(not projected(id).due_rollover and f:apply("rollover", { worker_id = id, trigger = "policy" }).code == "rollover_not_due" and rollovers() == 0,
		"auto_rollover=false never triggers rollover")
	assert(f:apply("policy", { policy = { auto_rollover = true } }).ok)
	local coordinator_id = f:accepted(true)
	assert(f:apply("observe", { worker_id = coordinator_id, pane_binding = clone(worker_of(f, coordinator_id).pane_binding), native_state = "idle" }).ok)
	assert(send_report(f, coordinator_id, "READY", { state = "idle", context_used_pct = 95 }).ok)
	check(not projected(coordinator_id).due_rollover and f:apply("rollover", { worker_id = coordinator_id, trigger = "policy" }).code == "coordinator_unavailable" and rollovers() == 0,
		"a coordinator without acknowledged activation (and with coordinator rollover off) is never selected automatically")
	local requested = f:apply("rollover", { worker_id = id, trigger = "policy" })
	check(requested.code == "rollover_requested" and rollover_of(f, requested.handover_id).trigger == "policy"
		and rollover_of(f, requested.handover_id).context.used_pct == 60 and rollover_of(f, requested.handover_id).phase == "checkpoint_pending",
		"policy trigger only requests a checkpoint and records its context evidence")
	check(not projected(id).due_rollover and f:apply("rollover", { worker_id = id, trigger = "policy" }).code == "rollover_in_progress" and rollovers() == 1,
		"an in-progress rollover is never duplicated")
	check(worker_of(f, id).finish == nil and #actions_of(f, id, "stop") == 0, "automatic request never stops anything by itself")
	check(state.rehydrate(clone(f.authority.registry)) ~= nil, "policy-triggered rollover restores")
end
if section == nil or section == "rollover_context" then
	local f, id, clock = rollover_fixture()
	local sid = f.origin.logical_session_id
	local function row()
		for _, w in dispatch.project(f.authority.registry, sid, f.origin.alias_nonce).workflow.workers do if w.worker_id == id then return w end end
	end
	local function snapshot(current, baseline, window, observed)
		return { current_tokens = current, first_turn_tokens = baseline, window_tokens = window or 1000, observed_at_ms = observed or clock.now_ms }
	end
	local function report(sample)
		return send_report(f, id, "READY", { state = "idle", context_snapshot = sample })
	end
	check(dispatch.policy(f.authority.registry, sid).rollover_threshold_pct == 0, "new policy uses calculated headroom")
	assert(send_report(f, id, "READY", { state = "idle", context_used_pct = 100 }).ok)
	check(row().context_rollover.status == "unknown" and not row().due_rollover, "percent alone never fabricates a calculated baseline")
	assert(report(snapshot(1000)).ok)
	check(row().context_rollover.status == "unknown" and not row().due_rollover, "missing first-turn baseline remains unknown even at a full window")
	assert(report(snapshot(639, 200)).ok)
	assert(send_report(f, id, "CHECKPOINT", handover_checkpoint("before-threshold")).ok)
	check(not row().due_rollover and row().context_rollover.threshold_pct == 64, "headroom uses measured first turn, not a flat 55 percent")
	assert(report(snapshot(640, 200)).ok)
	check(not row().due_rollover, "equality reaches threshold but cannot reuse an earlier completed checkpoint")
	assert(report(snapshot(641, 200)).ok)
	local empty = handover_checkpoint("incomplete-boundary"); empty.completed = runtime.json.array()
	assert(send_report(f, id, "CHECKPOINT", empty).ok)
	check(not row().due_rollover, "a checkpoint with no completed work is not a boundary")
	assert(f:watermark(id).ok) -- Settle the eight retained receipts before another report; do not test capacity by accident.
	assert(send_report(f, id, "CHECKPOINT", handover_checkpoint("after-threshold")).ok)
	check(row().due_rollover, "repeated above-threshold reports preserve eligibility for the next actual completed boundary")
	assert(report(snapshot(900, 201)).ok)
	check(row().context_rollover.status == "inconsistent" and not row().due_rollover, "changed first-turn baseline cannot roll a generation")
	assert(report(snapshot(900, 200, 2000)).ok)
	check(row().context_rollover.status == "inconsistent" and not row().due_rollover, "changed runtime window cannot roll a generation")
	assert(report(snapshot(900, 200)).ok)
	check(not row().due_rollover, "a corrected measurement needs a new completed boundary after inconsistency")
	assert(send_report(f, id, "CHECKPOINT", handover_checkpoint("corrected-boundary")).ok)
	check(row().due_rollover, "the original stable baseline remains usable after a corrected measurement")
	assert(f:watermark(id).ok)
	assert(report(snapshot(900)).ok)
	check(row().context_rollover.status == "measured" and worker_of(f, id).workflow.context.snapshot.first_turn_tokens == 200,
		"a fresh current/window sample may reuse only this generation's stable measured first-turn baseline")
	assert(send_report(f, id, "HEARTBEAT", { state = "idle" }).ok)
	check(row().context_used_pct == nil and not row().due_rollover, "missing current measurement is unknown, not cached occupancy")
	assert(report(snapshot(640, 200)).ok)
	assert(send_report(f, id, "CHECKPOINT", handover_checkpoint("fresh-boundary")).ok)
	local original = worker_of(f, id).workflow.context.at_ms
	local replay = f:report(id, worker_of(f, id).accepted_seq + 1, "READY", { state = "idle", context_snapshot = snapshot(640, 200) })
	assert(f:apply("intake", { worker_id = id, bytes = replay }).ok)
	clock.now_ms += dispatch.policy(f.authority.registry, sid).stale_ms
	clock.mono_ms = clock.now_ms
	assert(f:apply("intake", { worker_id = id, bytes = replay }).ok)
	assert(f:apply("observe", { worker_id = id, pane_binding = clone(worker_of(f, id).pane_binding), native_state = "idle" }).ok)
	check(row().context_rollover.status == "stale" and row().context_used_pct == nil and not row().due_rollover
		and worker_of(f, id).workflow.context.at_ms == original, "exact report replay and fresh native idle cannot renew a stale measurement")
	assert(report(snapshot(900, 200, 1000, clock.now_ms - dispatch.policy(f.authority.registry, sid).stale_ms)).ok)
	check(row().context_rollover.status == "stale" and not row().due_rollover, "new sequence carrying an old snapshot remains stale at the exact age boundary")
	assert(report(snapshot(900, 200, 1000, clock.now_ms + 1)).ok)
	check(row().context_rollover.status == "inconsistent" and not row().due_rollover, "future measurement time is not reliable current evidence")
	assert(f:watermark(id).ok)
	assert(f:apply("policy", { policy = { rollover_threshold_pct = 50 } }).ok)
	assert(report(snapshot(499)).ok)
	assert(send_report(f, id, "CHECKPOINT", handover_checkpoint("numeric-below")).ok)
	check(not row().due_rollover and row().context_rollover.mode == "percentage", "numeric override uses actual current occupancy without needing first turn")
	assert(report(snapshot(500)).ok)
	local boundary = handover_checkpoint("numeric-equality"); boundary.context_snapshot = snapshot(500)
	assert(send_report(f, id, "CHECKPOINT", boundary).ok)
	check(row().due_rollover and row().context_used_pct == 50, "numeric override accepts exact threshold on a measured completed checkpoint")
	check(state.rehydrate(clone(f.authority.registry)) ~= nil, "measured generation-local baseline and current snapshot restore strictly")
	for _, bad in { snapshot(-1, 200), snapshot(1001, 200), snapshot(500, 1001), snapshot(500, 200, 0),
		{ current_tokens = 500, window_tokens = 1000 }, snapshot(500.5, 200) } do
		local before = runtime.json.encode(f.authority.registry)
		check(not report(bad).ok and runtime.json.encode(f.authority.registry) == before, "invalid/incomplete runtime snapshot rejects without changing accepted measurements")
	end
	local g, gid = rollover_fixture()
	assert(send_report(g, gid, "READY", { state = "idle", context_snapshot = { current_tokens = 1000, window_tokens = 1000, observed_at_ms = 1000 } }).ok)
	local projected = dispatch.project(g.authority.registry, g.origin.logical_session_id, g.origin.alias_nonce).workflow.workers[1]
	check(projected.context_rollover.status == "unknown" and not projected.due_rollover, "a different worker generation cannot borrow another generation's first-turn baseline")
	for _, edge in {
		{ window = 1000, baseline = 0, at = 550 },
		{ window = 1000, baseline = 1000, at = 1000 },
		{ window = 200000, baseline = 10000, at = 114500 },
		{ window = 9007199254740991, baseline = 0, at = 4953959590107546 },
		{ window = 9007199254740991, baseline = 4503599627370495, at = 6980579422424268 },
		{ window = 9007199254740991, baseline = 9007199254740990, at = 9007199254740991 },
	} do
		local h, hid = rollover_fixture()
		local function due()
			for _, w in dispatch.project(h.authority.registry, h.origin.logical_session_id, h.origin.alias_nonce).workflow.workers do if w.worker_id == hid then return w.due_rollover end end
		end
		local before = handover_checkpoint("headroom-edge-before")
		before.context_snapshot = { current_tokens = edge.at - 1, first_turn_tokens = edge.baseline, window_tokens = edge.window, observed_at_ms = 1000 }
		assert(send_report(h, hid, "CHECKPOINT", before).ok)
		check(not due(), "headroom excludes the integer immediately below threshold, including realistic and maximum-safe windows")
		local reached = handover_checkpoint("headroom-edge-reached")
		reached.context_snapshot = { current_tokens = edge.at, first_turn_tokens = edge.baseline, window_tokens = edge.window, observed_at_ms = 1000 }
		assert(send_report(h, hid, "CHECKPOINT", reached).ok)
		check(due(), "headroom includes exact threshold without floating-point drift or overflowing integer intermediates")
	end
end
if section == nil or section == "rollover_context_roundtrip" then
	for _, current in { 1, 2 } do
		local f, id, clock = rollover_fixture()
		local cp = handover_checkpoint("fractional-context")
		cp.context_snapshot = { current_tokens = current, window_tokens = 3, first_turn_tokens = 0, observed_at_ms = 1000 }
		assert(send_report(f, id, "CHECKPOINT", cp).ok)
		assert(f:watermark(id).ok)
		-- Exercise the actual native JSON persistence boundary, not clone equality or source text.
		local encoded = runtime.json.encode(f.authority.registry)
		local decoded = runtime.json.decode(encoded)
		local restored, problem = state.rehydrate(decoded)
		check(restored ~= nil, "native JSON fractional context survives strict State restore: " .. tostring(problem))
		local projected
		for _, row in dispatch.project(restored, f.origin.logical_session_id, f.origin.alias_nonce).workflow.workers do
			if row.worker_id == id then projected = row end
		end
		check(projected.context_rollover.status == "unknown" and projected.context_used_pct == nil and not projected.due_rollover,
			"restore without a live clock or explicit continuation never promotes persisted occupancy into fresh evidence")
		local retained = restored.dispatch.workers[id].workflow.context
		check(retained.used_pct > (if current == 1 then 33 else 66) and retained.used_pct < (if current == 1 then 34 else 67),
			"strict native JSON restore retains fractional percentage evidence without requiring a serializer workaround")
		local snapshot = restored.dispatch.workers[id].workflow.context.snapshot
		check(snapshot.current_tokens == current and snapshot.window_tokens == 3 and snapshot.first_turn_tokens == 0,
			"native JSON restore retains the exact measured counts underlying fractional percent")
		-- Continue the actual serialized authority through its supported controller/worker
		-- reattachment path, then supply a genuinely fresh measurement and native observation.
		f.memory.value = decoded
		f.authority = host.new_authority(f.memory, function() return clone(clock) end)
		local loaded = f.authority:load(); assert(loaded.ok, runtime.json.encode(loaded))
		assert(f:apply("continue_controller", { expected_revision = f.authority.registry.revision, operator_verified = true }).ok)
		assert(f:control("reconcile_session").ok)
		local original = clone(worker_of(f, id))
		local pane = clone(original.pane_binding)
		local attached = f:apply("continue_worker", { worker_id = id, pane_binding = pane,
			continuation_proof = dispatch.continuation_proof(f.authority.registry, worker_of(f, id)), operator_verified = true })
		assert(attached.ok, runtime.json.encode(attached))
		assert(f:finish(attached.action_id, "attached", { pane_binding = pane,
			previous_origin_binding = original.origin_binding, previous_pane_binding = original.pane_binding }).ok)
		clock.now_ms += 1; clock.mono_ms += 1
		local fresh = handover_checkpoint("fractional-context-fresh")
		fresh.context_snapshot = { current_tokens = current, window_tokens = 3, first_turn_tokens = 0, observed_at_ms = clock.now_ms }
		assert(send_report(f, id, "CHECKPOINT", fresh).ok)
		assert(f:apply("observe", { worker_id = id, pane_binding = pane, native_state = "idle" }).ok)
		for _, row in dispatch.project(f.authority.registry, f.origin.logical_session_id, f.origin.alias_nonce).workflow.workers do
			if row.worker_id == id then projected = row end
		end
		check(projected.context_rollover.status == "measured" and projected.context_rollover.threshold_pct == 55
			and projected.context_used_pct > (if current == 1 then 33 else 66)
			and projected.context_used_pct < (if current == 1 then 34 else 67)
			and projected.due_rollover == (current == 2),
			"supported post-restore continuation and fresh runtime evidence recover the measured checkpoint eligibility on either side of threshold")
	end
end
if section == nil or section == "rollover_context_handover" then
	for _, measurement in {
		{ field = "context_used_pct", value = 95 },
		{ field = "context_snapshot", value = { current_tokens = 114500, first_turn_tokens = 10000, window_tokens = 200000, observed_at_ms = 1000 } },
	} do
		local f, id = rollover_fixture()
		local requested = f:apply("rollover", { worker_id = id, trigger = "owner" }); assert(requested.ok)
		local request = clone(worker_of(f, id).workflow.report_request)
		assert(send_report(f, id, "reply_ack", { message_id = request.message_id, reply_seq = request.reply_seq,
			reply_sha256 = codec.sha256(request.bytes), status = "recorded" },
			{ action_id = request.action_id, action_revision = request.action_revision }).ok)
		local cp = handover_checkpoint("measured-handover", request.request_id)
		cp[measurement.field] = clone(measurement.value)
		assert(send_report(f, id, "CHECKPOINT", cp).ok)
		local r = rollover_of(f, requested.handover_id)
		check(r.phase == "successor_granted", "a measured verified checkpoint grants the real successor")
		local original = r.checkpoint
		local predecessor_receipt = worker_of(f, id).receipts[tostring(worker_of(f, id).accepted_seq)].bytes
		local succ_id = r.successor_worker_id
		local launch = successor_provisioned(f, succ_id)
		local assignment = f:action(launch).request.prompt
		local transferred = runtime.json.decode(assert(assignment:match("\nCHECKPOINT (.+)$")))
		check(transferred.context_used_pct == nil and transferred.context_snapshot == nil and transferred.request_id == nil
			and transferred.checkpoint_id == cp.checkpoint_id and transferred.completed[1] == cp.completed[1]
			and transferred.remaining[1] == cp.remaining[1],
			"actual fresh-launch assignment transfers work and evidence but no predecessor runtime measurement or request correlation")
		assert(f:finish(launch, "awaiting_acceptance", { pane_binding = successor_pane(f) }).ok)
		local successor = worker_of(f, succ_id)
		local before = runtime.json.encode(f.authority.registry)
		local wrong = f:apply("intake", { worker_id = succ_id, bytes = f:report(succ_id, 1, "ACCEPTED",
			{ assignment_sha256 = codec.sha256(original) }, { handover_id = successor.handover_id, handover_token = successor.handover_token }) })
		check(not wrong.ok and wrong.code == "binding_mismatch" and runtime.json.encode(f.authority.registry) == before,
			"predecessor checkpoint bytes cannot substitute for acceptance of the cleaned successor assignment")
		local accept_id, accept_request = successor_accept_request(f, succ_id)
		local receipt = runtime.json.decode(worker_of(f, succ_id).receipts["1"].bytes)
		check(worker_of(f, succ_id).assignment_sha256 == codec.sha256(assignment) and receipt.event_sha256 == accept_request.event_sha256
			and accept_request.handover_id == requested.handover_id, "successor committed receipt and semantic acceptance bind the actual cleaned assignment")
		assert(f:finish(accept_id, "accepted", {}).ok)
		successor = worker_of(f, succ_id)
		local projected
		for _, row in dispatch.project(f.authority.registry, f.origin.logical_session_id, f.origin.alias_nonce).workflow.workers do
			if row.worker_id == succ_id then projected = row end
		end
		check(successor.phase == "accepted" and successor.accepted_seq == 1 and successor.workflow.context == nil
			and successor.workflow.context_basis == nil and projected.context_rollover.status == "unknown" and not projected.due_rollover,
			"accepted fresh generation begins with unknown runtime context, without inherited baseline or rollover eligibility")
		r = rollover_of(f, requested.handover_id)
		check(r.checkpoint == original and codec.decode_report(r.checkpoint, worker_of(f, id)).payload[measurement.field] ~= nil
			and worker_of(f, id).receipts[tostring(worker_of(f, id).accepted_seq)].bytes == predecessor_receipt,
			"cleaning successor input leaves predecessor immutable checkpoint and committed receipt unchanged")
	end
end
-- Coordinator rollover (CP4): never two managed coordinators; successor only after observed closure and release.
local function coordinator_owner(f) return f.authority.registry.sessions[f.origin.logical_session_id].orchestrator end
local function coordinator_ready(clock, unstarted_project)
	local f, id = retirement_fixture(clock, unstarted_project); f:drain(); assert(f:ack("activation").ok)
	return f, id
end
local function coordinator_retirement_requested(f, id)
	local requested = f:apply("rollover", { worker_id = id, trigger = "owner" }); assert(requested.ok and requested.code == "rollover_requested", requested.message)
	assert(rollover_of(f, requested.handover_id).kind == "coordinator" and rollover_of(f, requested.handover_id).phase == "checkpoint_pending")
	local checkpoint = answer_checkpoint(f, id, "coordinator-cp-1"); must(checkpoint.ok, checkpoint)
	assert(rollover_of(f, requested.handover_id).phase == "retirement_requested", rollover_of(f, requested.handover_id).phase)
	return requested.handover_id
end
local function coordinator_stop_action(f, id)
	f:drain(); assert(f:ack("retirement").ok); assert(f:release("retirement").ok)
	f:drain(); f:watermark()
	local stop = f:apply("poll", { worker_id = id }); assert(stop.ok, stop.message)
	assert(f:action(stop.action_id).request.op == "stop")
	return stop.action_id
end
local function handover_successors(f, hid)
	local n = 0; for _, w in f.authority.registry.dispatch.workers do if w.handover_id == hid then n += 1 end end; return n
end
local function coordinator_released(f, id, stop)
	assert(f:finish(stop, "stopped", { pane_binding = clone(f:action(stop).request.pane_binding), observation = "exited" }).ok)
	local retire = f:apply("poll", { worker_id = id }); assert(retire.ok, retire.message)
	assert(f:action(retire.action_id).request.mode == "retire")
	return f:finish(retire.action_id, "retired", {})
end
local function coordinator_successor_accepted(f, hid)
	local succ_id = rollover_of(f, hid).successor_worker_id
	local provision = actions_of(f, succ_id, "mailbox_provision"); assert(#provision == 1)
	assert(f:finish(provision[1], "provisioned", { handle = "mailbox-coordinator-successor", binding_digest = string.rep("c", 64),
		capabilities = runtime.json.array({ "report-files-v1", "native-ask-v1", "coordinator-control-v1", "project-start-v1" }), limits = {} }).ok)
	assert(f:finish(worker_of(f, succ_id).launch_action_id, "awaiting_acceptance", { pane_binding = successor_pane(f) }).ok)
	local accept_id, accept_request = successor_accept_request(f, succ_id)
	assert(f:finish(accept_id, "accepted", {}).ok)
	return succ_id, accept_request
end
local function ack_activation(f, worker_id)
	local w = worker_of(f, worker_id); local grant = w.activation; local reply = w.replies[tostring(grant.reply_seq)]
	return send_report(f, worker_id, "reply_ack", { message_id = reply.message_id, reply_seq = reply.reply_seq, reply_sha256 = reply.sha256, status = "recorded" },
		{ action_id = grant.action_id, action_revision = grant.action_revision })
end
if section == nil or section == "project_start_rollover" then
	local f, predecessor = coordinator_ready()
	local project = f:project("START awaiting its original coordinator", false)
	local p = f.authority.registry.dispatch.projects[project]
	assert(f:apply("project_start", { orch_project_id = project, project_revision = p.revision }).ok)
	f:drain()
	local start = f.authority.registry.dispatch.projects[project].start
	local reply = assert(codec.decode_reply(start.bytes, worker_of(f, predecessor)))
	assert(send_report(f, predecessor, "reply_ack", { message_id = start.message_id, reply_seq = start.reply_seq,
		reply_sha256 = codec.sha256(start.bytes), status = "recorded" }, { action_id = start.action_id, action_revision = start.action_revision }).ok)
	local original = clone(f.authority.registry.dispatch.projects[project].start)
	local handover = coordinator_retirement_requested(f, predecessor)
	assert(coordinator_released(f, predecessor, coordinator_stop_action(f, predecessor)).ok)
	local successor = coordinator_successor_accepted(f, handover); assert(ack_activation(f, successor).ok)
	local current = f.authority.registry.dispatch.projects[project]
	assert(current.start.closed and f:apply("project_start", { orch_project_id = project, project_revision = current.revision }).ok)
	local fresh = clone(f.authority.registry.dispatch.projects[project].start)
	check(fresh.action_id ~= original.action_id and fresh.coordinator.worker_id == successor, "a safely established successor receives only a separately approved fresh START")
	local old = send_report(f, predecessor, "PROJECT_START_CLAIM", reply.payload,
		{ action_id = original.action_id, action_revision = original.action_revision })
	check(old.ok and old.refused == "start_owner_changed" and not f.authority.registry.dispatch.projects[project].started
		and f.authority.registry.dispatch.projects[project].start.action_id == fresh.action_id,
		"a late exact old-owner claim is consumed only as a refused fact, never inherited by the successor's fresh START")
	local inherited = send_report(f, successor, "PROJECT_START_CLAIM", reply.payload,
		{ action_id = original.action_id, action_revision = original.action_revision })
	check(inherited.code == "start_claim_unauthorized" and f.authority.registry.dispatch.projects[project].start.bytes == fresh.bytes
		and f.authority.registry.dispatch.projects[project].start_history[1].bytes == original.bytes
		and not f.authority.registry.dispatch.projects[project].started, "the successor cannot inherit or rebind its predecessor's grant, owner or activation")
	check(state.rehydrate(clone(f.authority.registry)) ~= nil, "old START evidence remains durable across successor ownership")
end
if section == nil or section == "current_handover" then
	-- Closing a handover only ends successor creation. It must preserve every predecessor-side
	-- obligation already issued, including a retirement or uncertain stop.
	for _, phase in { "retirement_requested", "predecessor_stop_requested", "predecessor_closed", "successor_granted" } do
		local f, id = coordinator_ready()
		local hid = coordinator_retirement_requested(f, id)
		local stop
		if phase ~= "retirement_requested" then stop = coordinator_stop_action(f, id) end
		if phase == "predecessor_closed" or phase == "successor_granted" then
			assert(f:finish(stop, "stopped", { pane_binding = clone(f:action(stop).request.pane_binding), observation = "exited" }).ok)
		end
		if phase == "successor_granted" then
			local retirement = f:apply("poll", { worker_id = id }); assert(retirement.ok)
			assert(f:finish(retirement.action_id, "retired").ok)
		end
		local r = assert(rollover_of(f, hid))
		check(r.phase == phase, phase .. ": reaches the real externally visible handover edge")
		local successor = r.successor_worker_id
		local old_stop = if stop then f:action(stop) else nil
		local old_retirement = clone(worker_of(f, id).retirement)
		check(f:apply("close_handover", { worker_id = id }).code == "handover_closed", phase .. ": fresh admission permits explicit close without an issued successor")
		check(successor == nil or worker_of(f, successor) == nil, phase .. ": untouched successor draft is removed rather than left schedulable")
		check(runtime.json.encode(worker_of(f, id).retirement) == runtime.json.encode(old_retirement)
			and (old_stop == nil or f:action(stop) ~= nil), phase .. ": closure does not erase predecessor retirement or stop")
		if phase == "successor_granted" then check(coordinator_owner(f) == nil, "closing untouched reserved successor releases its exact reservation in the same commit") end
		check(state.rehydrate(clone(f.authority.registry)) ~= nil, phase .. ": closed handover with remaining obligations restores")
	end
	-- One worker can end more handovers than the old lifetime capacity. The protocol receives real
	-- checkpoint/reply ACKs; only then does the terminal graph disappear.
	local f, id = rollover_fixture()
	for index = 1, 65 do
		local requested = f:apply("rollover", { worker_id = id, trigger = "owner" }); assert(requested.ok)
		local checkpoint = answer_checkpoint(f, id, "closed-handover-" .. index)
		must(checkpoint.ok, { handover = index, result = checkpoint })
		local r = assert(rollover_of(f, requested.handover_id)); local successor = r.successor_worker_id
		assert(successor and f:action(actions_of(f, successor, "mailbox_provision")[1]).request_bytes == nil)
		check(f:apply("close_handover", { worker_id = id }).code == "handover_closed" and worker_of(f, successor) == nil,
			"handover " .. index .. ": owner exits only before successor issue")
		for _ = 1, 16 do
			local publish = false
			for _, receipt in worker_of(f, id).receipts do if receipt.publish then publish = true end end
			if not publish then break end
			local pending = f:apply("poll", { worker_id = id }); assert(pending.ok)
			assert(f:action(pending.action_id).request.op == "mailbox_publish_ack")
			assert(f:finish(pending.action_id, "published").ok)
		end
		assert(f:watermark(id).ok)
		check(rollover_of(f, requested.handover_id) == nil and next(f.authority.registry.dispatch.rollovers) == nil,
			"handover " .. index .. ": settled phase record is reclaimed rather than evicted at a bound")
		local flow = worker_of(f, id).workflow
		local checkpoints, checkpoint_entries = 0, 0
		for _ in flow.checkpoints do checkpoints += 1 end
		for _, entry in flow.thread do if entry.kind == "CHECKPOINT" then checkpoint_entries += 1 end end
		check(checkpoints == 1 and checkpoint_entries == 1 and flow.checkpoints["closed-handover-" .. index] ~= nil
			and codec.decode_report(flow.evidence.CHECKPOINT, worker_of(f, id)).payload.checkpoint_id == "closed-handover-" .. index,
			"handover " .. index .. ": only current checkpoint evidence and its thread entry remain, with latest proof preserved")
	end
	check(state.rehydrate(clone(f.authority.registry)) ~= nil, "more than64 ended handovers restore without lifetime history")
	-- Two ended handovers before producer settlement retain both real checkpoint reports.
	local pending, predecessor = rollover_fixture()
	for index = 1, 2 do
		local requested = pending:apply("rollover", { worker_id = predecessor, trigger = "owner" }); must(requested.ok, requested)
		local checkpoint = answer_checkpoint(pending, predecessor, "undrained-handover-" .. index); must(checkpoint.ok, checkpoint)
		must(pending:apply("close_handover", { worker_id = predecessor }).ok)
	end
	local unsettled = worker_of(pending, predecessor)
	check(unsettled.workflow.checkpoints["undrained-handover-1"] ~= nil
		and unsettled.workflow.checkpoints["undrained-handover-2"] ~= nil and unsettled.compacted_floor < unsettled.accepted_seq,
		"an older checkpoint remains retained while its real producer receipts are undrained")
	must(pending:watermark(predecessor).ok)
	check(worker_of(pending, predecessor).workflow.checkpoints["undrained-handover-1"] == nil
		and worker_of(pending, predecessor).workflow.checkpoints["undrained-handover-2"] ~= nil,
		"the real cumulative receipt watermark releases only the older unreferenced checkpoint")
end
if section == nil or section == "rollover_coordinator" then
	local f, id = coordinator_ready()
	local old_owner, old_generation = coordinator_owner(f).owner_id, coordinator_owner(f).generation
	local old_token = worker_of(f, id).activation.activation_token
	local hid = coordinator_retirement_requested(f, id)
	check(coordinator_owner(f).owner_id == old_owner and coordinator_owner(f).phase == "retiring" and worker_of(f, id).retirement ~= nil,
		"verified checkpoint quiesces the predecessor through the existing typed retirement; the slot stays occupied")
	check(f:queue(true).code == "rollover_reserved" and handover_successors(f, hid) == 0, "no unrelated start or successor while the predecessor is quiescing")
	do
		local closing, predecessor = coordinator_ready()
		local closing_id = coordinator_retirement_requested(closing, predecessor)
		check(closing:apply("close_handover", { worker_id = predecessor }).code == "handover_closed"
			and handover_successors(closing, closing_id) == 0, "owner may close without successor after retirement requested; predecessor obligations remain")
	end
	local stop = coordinator_stop_action(f, id)
	check(rollover_of(f, hid).phase == "predecessor_stop_requested" and handover_successors(f, hid) == 0 and coordinator_owner(f).owner_id == old_owner,
		"stop grant alone never starts a successor")
	assert(f:finish(stop, "stopped", { pane_binding = clone(f:action(stop).request.pane_binding), observation = "exited" }).ok)
	check(rollover_of(f, hid).phase == "predecessor_closed" and rollover_of(f, hid).closure == "observed" and handover_successors(f, hid) == 0
		and coordinator_owner(f).owner_id == old_owner and f:queue(true).code == "rollover_reserved", "observed closure still waits for exact mailbox retirement and slot release")
	local swept = f:apply("sweep", { local_date = "2026-11-03" })
	local entry = swept.ok and sweep_entry(f, id) or nil
	check(entry ~= nil and entry.decision == "keep" and entry.reason == "referenced" and worker_of(f, id).mailbox_retire_action_id == nil,
		"the nightly sweep keeps a stopped, settled predecessor that its unfinished rollover still references")
	local retire = f:apply("poll", { worker_id = id }); assert(f:action(retire.action_id).request.mode == "retire")
	check(f:finish(retire.action_id, "retired", {}).code == "coordinator_retired", "normal generation-bound release runs through the existing retirement path")
	local r = rollover_of(f, hid); local owner = coordinator_owner(f)
	check(r.phase == "successor_granted" and f.authority.registry.retired == nil and owner.owner_id ~= old_owner and owner.generation > old_generation
		and owner.phase == "reserved" and owner.managed_worker_id == r.successor_worker_id and r.successor_owner_id == owner.owner_id,
		"release and successor reservation commit in the same serialized transition")
	check(handover_successors(f, hid) == 1, "exactly one successor coordinator is granted")
	check(state.rehydrate(clone(f.authority.registry)) ~= nil, "granted coordinator rollover restores")
	local succ_id, accept_request = coordinator_successor_accepted(f, hid)
	local succ = worker_of(f, succ_id)
	check(accept_request.handover_id == hid and accept_request.handover_token == r.handover_token, "SPAWN accept carries the coordinator handover pair")
	check(succ.coordinator_owner_id == owner.owner_id and succ.activation ~= nil
		and succ.activation.activation_token == codec.sha256(succ.enrolment_token .. ":coordinator:" .. owner.owner_id .. ":" .. tostring(owner.generation) .. ":handover:" .. hid .. ":" .. r.handover_token)
		and succ.activation.activation_token ~= old_token, "successor activation is bound to the handover and never reuses the retired token")
	check(rollover_of(f, hid).phase == "handover_accepted", "activation must be acknowledged before the successor counts")
	assert(ack_activation(f, succ_id).ok)
	check(rollover_of(f, hid) == nil and coordinator_owner(f).managed_worker_id == succ_id,
		"successor activation settles the last handover obligation and reclaims its completed phase history")
	check(send_report(f, id, "HEARTBEAT", { state = "idle" }).code == "owner_mismatch", "retired predecessor generation cannot report")
	local proposal = { owner_id = owner.owner_id, owner_generation = owner.generation, activation_token = old_token, proposal_id = "after-rollover", kind = "report",
		work_id = succ.work_id, project_id = "project-one" }
	check(send_report(f, succ_id, "COORDINATOR_PROPOSAL", proposal).code == "proposal_unauthorized", "retired activation token is rejected for the successor")
	check(state.rehydrate(clone(f.authority.registry)) ~= nil, "completed coordinator rollover restores")
end
if section == nil or section == "rollover_coordinator_ambiguous" then
	local f, id = coordinator_ready()
	local old_owner = coordinator_owner(f).owner_id
	local hid = coordinator_retirement_requested(f, id)
	local stop = coordinator_stop_action(f, id)
	assert(f:apply("claim", { action_id = stop, executor = f.origin.window_epoch }).ok)
	local grant = f:action(stop).claim
	assert(f:apply("lost", { action_id = stop, executor = grant.executor, grant_id = grant.grant_id }).ok)
	local r = rollover_of(f, hid)
	check(r.phase == "predecessor_stop_requested" and r.hold.code == "predecessor_stop_uncertain" and r.checkpoint ~= nil, "ambiguous closure holds with the checkpoint retained")
	check(handover_successors(f, hid) == 0 and coordinator_owner(f).owner_id == old_owner and f:queue(true).code == "rollover_reserved", "no successor or unrelated start after ambiguous stop")
	check(not f:apply("poll", { worker_id = id }).ok and #actions_of(f, id, "stop") == 1, "uncertain stop is never reissued")
	f.authority = host.new_authority(f.memory); assert(f.authority:load().ok)
	check(rollover_of(f, hid).phase == "predecessor_stop_requested" and handover_successors(f, hid) == 0, "reload retains the hold without a successor")
end
if section == nil or section == "rollover_coordinator_reload" then
	local f, id = coordinator_ready()
	local old = coordinator_owner(f)
	local hid = coordinator_retirement_requested(f, id)
	f.authority = host.new_authority(f.memory); assert(f.authority:load().ok)
	check(rollover_of(f, hid).phase == "retirement_requested" and coordinator_owner(f).phase == "uncertain", "reload keeps the durable phase and an uncertain occupied slot")
	assert(f:apply("continue_controller", { expected_revision = f.authority.registry.revision, operator_verified = true }).ok)
	assert(f:control("reconcile_session").ok) -- Fresh peer observation restores admission, never the old revision fence.
	check(f:queue(true).code == "rollover_reserved" and handover_successors(f, hid) == 0, "after reload no unrelated start or successor can take the slot")
	-- Ambiguous closure: explicit operator-assisted recovery of the exact orchestrator owner.
	local function owner_event(kind, fields)
		local event = { kind = kind, request_id = "coordinator-recovery-" .. kind .. "-" .. tostring(f.authority.registry.revision), orch_session_id = f.origin.logical_session_id,
			target = "orchestrator", expected_owner_id = old.owner_id, expected_generation = old.generation }
		event.authority_namespace = f.authority.registry.authority_namespace; event.expected_revision = f.authority.registry.revision
		for k, v in fields do event[k] = v end
		return f.authority:apply(event)
	end
	assert(owner_event("observe_owner", { status = "unavailable", evidence = "observed" }).ok)
	assert(owner_event("observe_owner", { status = "operator verified stopped", owner_active = false, pending_executors = 0, evidence = "operator_attested", operator_verified = true }).ok)
	local intent = owner_event("begin_recovery", { expected_revision = f.authority.registry.revision }); assert(intent.ok, intent.message)
	assert(owner_event("confirm_recovery", { expected_revision = intent.revision, intent_id = intent.intent_id, evidence = "operator_attested", operator_verified = true }).ok)
	assert(f:apply("observe", { worker_id = id, pane_binding = clone(worker_of(f, id).pane_binding), native_state = "unknown" }).ok)
	local r = rollover_of(f, hid)
	check(r.phase == "owner_retired" and r.closure == "operator_attested" and handover_successors(f, hid) == 0
		and coordinator_owner(f) == nil and r.prepared.action.phase == "held_ready" and r.hold.code == "restored_preparation",
		"owner-stop attestation retires only that owner; it cannot prove a restored successor draft never executed")
	assert(f:apply("observe", { worker_id = id, pane_binding = clone(worker_of(f, id).pane_binding), native_state = "unknown" }).ok)
	check(handover_successors(f, hid) == 0 and rollover_of(f, hid).prepared.action.phase == "held_ready",
		"later observations never turn restored preparation into replacement execution authority")
	check(state.rehydrate(clone(f.authority.registry)) ~= nil, "operator-attested coordinator rollover restores")
end
if section == nil or section == "rollover_coordinator_restored" then
	local f, id = coordinator_ready()
	local hid = coordinator_retirement_requested(f, id)
	local stop = coordinator_stop_action(f, id)
	assert(f:finish(stop, "stopped", { pane_binding = clone(f:action(stop).request.pane_binding), observation = "exited" }).ok)
	local pane = clone(worker_of(f, id).pane_binding)
	assert(f:apply("observe", { worker_id = id, pane_binding = pane, native_state = "working" }).ok)
	check(worker_of(f, id).restored ~= nil and worker_of(f, id).workflow.health.status == "exited", "restored predecessor is evidence, never a healthy coordinator")
	check(rollover_of(f, hid).hold.code == "predecessor_reappeared" and f:queue(true).code == "rollover_reserved", "reappearance before activation holds the rollover")
	local retire = f:apply("poll", { worker_id = id }); assert(retire.ok)
	check(f:apply("claim", { action_id = retire.action_id, executor = f.origin.window_epoch }).code == "coordinator_restored", "coordinator effects are held while restored")
	assert(f:apply("observe", { worker_id = id, pane_binding = pane, native_state = "exited" }).ok)
	check(worker_of(f, id).restored.reconciled == "observed_exit", "an observed exit reconciles the restored pane")
	check(f:finish(retire.action_id, "retired", {}).code == "coordinator_retired" and rollover_of(f, hid).phase == "successor_granted", "reconciled hold resumes to exactly one successor")
	local succ_id = coordinator_successor_accepted(f, hid); assert(ack_activation(f, succ_id).ok)
	check(rollover_of(f, hid) == nil, "activated successor and settled predecessor leave no terminal handover history")
	assert(f:apply("observe", { worker_id = id, pane_binding = pane, native_state = "idle" }).ok)
	check(worker_of(f, id).restored.reconciled == nil, "a reappearance after activation is recorded again")
	local owner = coordinator_owner(f); local succ = worker_of(f, succ_id)
	local proposal = { owner_id = owner.owner_id, owner_generation = owner.generation, activation_token = succ.activation.activation_token, proposal_id = "held", kind = "report",
		work_id = succ.work_id, project_id = "project-one" }
	check(send_report(f, succ_id, "COORDINATOR_PROPOSAL", proposal).code == "coordinator_restored", "restored predecessor holds the active successor's proposals")
	local publish = f:apply("poll", { worker_id = succ_id }); assert(publish.ok, publish.message)
	check(f:apply("claim", { action_id = publish.action_id, executor = f.origin.window_epoch }).code == "coordinator_restored", "restored predecessor holds successor effects")
	check(f:apply("reconcile_restored", { worker_id = id, operator_verified = true }).code == "restoration_reconciled", "operator attests the restored pane was stopped")
	check(f:apply("claim", { action_id = publish.action_id, executor = f.origin.window_epoch }).ok, "reconciliation releases the held successor effects")
	check(state.rehydrate(clone(f.authority.registry)) ~= nil, "restoration evidence restores")
end
if section == nil or section == "rollover_coordinator_successor_rejected" then
	-- A coordinator successor that mistyped its handover token: the predecessor coordinator was stopped and retired, then SPAWN refused the
	-- successor's ACCEPTED (one mistyped handover-token digit). No coordinator is active.
	local clock = { now_ms = 1000, mono_ms = 1000, epoch = "coordinator-recovery-before" }
	local f, id = coordinator_ready(function() return clone(clock) end)
	check(not f:apply("cancel_work", { worker_id = id }).ok, "an accepted activated coordinator never uses failed-startup cleanup")
	assert(f:apply("observe", { worker_id = id, pane_binding = clone(worker_of(f, id).pane_binding), native_state = "idle" }).ok)
	local hid = coordinator_retirement_requested(f, id)
	assert(coordinator_released(f, id, coordinator_stop_action(f, id)).code == "coordinator_retired")
	local r = rollover_of(f, hid); local succ_id, owner = r.successor_worker_id, coordinator_owner(f)
	assert(r.phase == "successor_granted" and owner.owner_id == r.successor_owner_id)
	local provision = actions_of(f, succ_id, "mailbox_provision"); assert(#provision == 1)
	local provisioned = f:action(provision[1]).request
	check(provisioned.handover_id == hid and provisioned.handover_sha256 == codec.sha256(hid .. ":" .. r.handover_token)
		and not runtime.json.encode(provisioned):find(r.handover_token, 1, true), "the successor mailbox is provisioned with the handover ID and pair digest, never the token")
	assert(f:finish(provision[1], "provisioned", { handle = "mailbox-coordinator-successor", binding_digest = string.rep("c", 64),
		capabilities = runtime.json.array({ "report-files-v1", "native-ask-v1", "coordinator-control-v1", "project-start-v1" }), limits = {} }).ok)
	assert(f:finish(worker_of(f, succ_id).launch_action_id, "awaiting_acceptance", { pane_binding = successor_pane(f) }).ok)
	assert(rollover_of(f, hid).phase == "successor_created")
	local read = f:apply("poll", { worker_id = succ_id }); assert(read.ok, read.message)
	local request = f:action(read.action_id).request
	assert(request.op == "mailbox_read" and request.selector.stream == "report" and request.selector.slot == 1, request.op)
	assert(f:apply("claim", { action_id = read.action_id, executor = f.origin.window_epoch }).ok)
	local problem = { code = "binding_mismatch", message = "Acceptance differs from the issued assignment or handover." }
	local refused = f:apply("result", { action_id = read.action_id, executor = f.origin.window_epoch, grant_id = f:action(read.action_id).claim.grant_id,
		response_bytes = frame(f:action(read.action_id).request, "rejected", nil, problem) })
	r = rollover_of(f, hid)
	check(refused.code == "bridge_rejected" and worker_of(f, succ_id).phase == "held" and r.phase == "successor_created" and r.hold.code == "successor_unaccepted",
		"a refused successor acceptance holds the coordinator handover")
	local text = r.hold.message
	check(text:find(problem.message, 1, true) ~= nil and text:find("already stopped and retired, so no coordinator is active", 1, true) ~= nil
		and text:find("fenced recovery for orchestrator owner " .. owner.owner_id, 1, true) ~= nil and text:find("keeps running", 1, true) == nil,
		"the hold reports the retired predecessor, the SPAWN diagnostic and the recovery path: " .. text)
	check(f:queue(true).code == "rollover_reserved" and handover_successors(f, hid) == 1 and #actions_of(f, succ_id, "launch") == 0,
		"the held handover keeps the slot and confirmed pane identity without retaining or reissuing its completed launch")
	local function owner_event(kind, fields)
		local event = { kind = kind, request_id = "successor-recovery-" .. kind .. "-" .. tostring(f.authority.registry.revision), orch_session_id = f.origin.logical_session_id,
			target = "orchestrator", expected_owner_id = owner.owner_id, expected_generation = owner.generation }
		event.authority_namespace = f.authority.registry.authority_namespace; event.expected_revision = f.authority.registry.revision
		for k, v in fields do event[k] = v end
		return f.authority:apply(event)
	end
	assert(owner_event("observe_owner", { status = "unavailable", evidence = "observed" }).ok)
	assert(owner_event("observe_owner", { status = "operator verified stopped", owner_active = false, pending_executors = 0, evidence = "operator_attested", operator_verified = true }).ok)
	local intent = owner_event("begin_recovery", { expected_revision = f.authority.registry.revision }); assert(intent.ok, intent.message)
	local confirmed = owner_event("confirm_recovery", { expected_revision = intent.revision, intent_id = intent.intent_id, evidence = "operator_attested", operator_verified = true })
	assert(confirmed.ok, confirmed.message)
	local unproved_registry = clone(f.authority.registry)
	local check_startup = f:apply("cancel_work", { worker_id = succ_id })
	check(check_startup.code == "startup_retiring" and worker_of(f, succ_id).mailbox_retired ~= true
		and worker_of(f, succ_id).stopped == nil and #actions_of(f, succ_id, "mailbox_retire") == 1,
		"recovered owner may request only a native-check-gated retirement; unknown core lifecycle never clears its launched successor")
	f.authority.registry = unproved_registry; f.memory.value = clone(unproved_registry)
	assert(f:apply("observe", { worker_id = succ_id, pane_binding = successor_pane(f), native_state = "exited" }).ok)
	r = rollover_of(f, hid)
	check(r == nil and coordinator_owner(f) == nil
		and handover_successors(f, hid) == 1 and #actions_of(f, succ_id, "launch") == 0, "fenced recovery settles and reclaims the handover without relaunching")
	-- Branch from the same real failed successor: zero reports do not prove an empty
	-- producer. Only SPAWN's exact retirement outcome releases this generation.
	local retained_registry = clone(f.authority.registry)
	local before_cleanup = clone(worker_of(f, succ_id))
	local projected = dispatch.project(f.authority.registry, f.origin.logical_session_id, f.origin.alias_nonce).workers[succ_id]
	check(projected.withdrawal.evidence == "failed_startup" and projected.pane_binding.pane_id == successor_pane(f).pane_id,
		"Advanced exposes truthful failed-startup cleanup with the original real pane binding")
	local cleanup = f:apply("cancel_work", { worker_id = succ_id })
	check(cleanup.code == "startup_retiring" and worker_of(f, succ_id).startup_cancelling == true
		and f:action(cleanup.action_id).request.report_floor == 0 and f:action(cleanup.action_id).request.reply_floor == 0,
		"the recovered unaccepted successor uses existing zero-floor mailbox retirement")
	check(f:apply("cancel_work", { worker_id = succ_id }).code == "retirement_unresolved"
		and #actions_of(f, succ_id, "mailbox_retire") == 1, "a pending failed-startup retirement never duplicates its grant")
	check(state.rehydrate(clone(f.authority.registry)) ~= nil, "the exact failed-startup retirement restores")
	assert(f:finish(cleanup.action_id, "rejected", nil, { code = "producer_unsettled", message = "A producer journal claim remains unresolved." }).ok)
	check(worker_of(f, succ_id).retirement_refused == true and worker_of(f, succ_id).mailbox_retired ~= true,
		"nonempty producer proof keeps the original failed generation and its reservation")
	cleanup = f:apply("cancel_work", { worker_id = succ_id }); assert(cleanup.code == "startup_retiring", cleanup.message)
	local retiring = clone(worker_of(f, succ_id))
	check(retiring.stopped == nil and retiring.release == nil and retiring.activation == nil and retiring.accepted_event == nil
		and codec.sha256(runtime.json.encode(retiring.pane_binding)) == codec.sha256(runtime.json.encode(before_cleanup.pane_binding))
		and retiring.enrolment_token == before_cleanup.enrolment_token and retiring.launch_request_id == before_cleanup.launch_request_id
		and retiring.mailbox_handle == before_cleanup.mailbox_handle, "cleanup keeps original launch, pane, token and target without synthetic lifecycle evidence")
	assert(f:finish(cleanup.action_id, "retired", {}).ok)
	check(worker_of(f, succ_id).mailbox_retired == true and coordinator_owner(f) == nil
		and #actions_of(f, succ_id, "mailbox_retire") == 0, "confirmed retirement leaves the owner-unreferenced failed coordinator settled and reclaimable")
	check(state.rehydrate(clone(f.authority.registry)) ~= nil, "confirmed failed-startup retirement restores as reclaimable evidence")
	local replacement = f:queue(true)
	check(replacement.ok and coordinator_owner(f).managed_worker_id == replacement.worker_id
		and worker_of(f, replacement.worker_id).record_id == before_cleanup.record_id and worker_of(f, succ_id) == nil,
		"the next explicit same-record coordinator start reclaims the retired failed worker through the existing admission path")
	-- Continue the existing stale-epoch/restoration branch without cleanup's terminal
	-- outcome; neither branch borrows a native stop, report or replacement identity.
	f.authority.registry = retained_registry; f.memory.value = clone(retained_registry)
	clock.epoch = "coordinator-recovery-current"
	clock.now_ms += 1000; clock.mono_ms = 1000
	local writes = f.memory.writes
	local stale_exit = f:queue(true)
	check(not stale_exit.ok and f.memory.writes == writes and coordinator_owner(f) == nil,
		"a prior-host-epoch exit cannot authorize a new coordinator or write a reservation")
	local stale_registry = clone(f.authority.registry)
	local stale_check = f:apply("cancel_work", { worker_id = succ_id })
	check(stale_check.code == "startup_retiring" and worker_of(f, succ_id).mailbox_retired ~= true and worker_of(f, succ_id).stopped == nil,
		"stale core exit evidence stages only a fresh native window check, never retirement or synthetic stop")
	f.authority.registry = stale_registry; f.memory.value = clone(stale_registry)
	assert(f:apply("observe", { worker_id = succ_id, pane_binding = successor_pane(f), native_state = "idle" }).ok)
	writes = f.memory.writes
	local reappeared = f:queue(true)
	check(not reappeared.ok and f.memory.writes == writes and coordinator_owner(f) == nil,
		"a reappeared latest native observation overrides old exit evidence without starting another coordinator")
	assert(f:apply("observe", { worker_id = succ_id, pane_binding = successor_pane(f), native_state = "exited" }).ok)
	check(worker_of(f, succ_id).stopped == nil and worker_of(f, succ_id).mailbox_retired ~= true,
		"current exact exit observation does not invent a native stop or mailbox retirement")
	local fresh = f:queue(true)
	check(fresh.ok and fresh.code == "task_queued" and coordinator_owner(f).managed_worker_id == fresh.worker_id, "the freed slot accepts an explicit new coordinator start")
	assert(f:apply("observe", { worker_id = succ_id, pane_binding = successor_pane(f), native_state = "idle" }).ok)
	check(worker_of(f, succ_id).restored ~= nil and worker_of(f, succ_id).restored.reconciled == nil
		and worker_of(f, succ_id).stopped == nil,
		"a recovered prior coordinator reappearing after replacement reservation records restoration without inventing a stop")
	check(not f:apply("cancel_work", { worker_id = succ_id }).ok, "a restored prior coordinator is never erased as an unused startup")
	writes = f.memory.writes
	local blocked = f:apply("claim", { action_id = fresh.action_id, executor = f.origin.window_epoch })
	check(not blocked.ok and f.memory.writes == writes and f:action(fresh.action_id).claim == nil,
		"the restored prior coordinator blocks replacement effects without writes or a grant")
	assert(f:apply("observe", { worker_id = succ_id, pane_binding = successor_pane(f), native_state = "exited" }).ok)
	check(worker_of(f, succ_id).restored.reconciled == "observed_exit"
		and f:apply("claim", { action_id = fresh.action_id, executor = f.origin.window_epoch }).ok,
		"only the exact subsequent exit releases the reserved replacement's first claim")
	check(state.rehydrate(clone(f.authority.registry)) ~= nil, "closed coordinator handover restores")
end
if section == nil or section == "rollover_coordinator_policy" then
	local clock = { now_ms = 1000, mono_ms = 1000, epoch = "coordinator-policy-host" }
	local f = fixture(function() return clone(clock) end)
	local id = f:accepted(true)
	assert(ack_activation(f, id).ok)
	assert(f:apply("observe", { worker_id = id, pane_binding = clone(worker_of(f, id).pane_binding), native_state = "idle" }).ok)
	local sid = f.origin.logical_session_id
	local function due() for _, worker in dispatch.project(f.authority.registry, sid, f.origin.alias_nonce).workflow.workers do if worker.worker_id == id then return worker.due_rollover end end end
	local function rollovers() local n = 0; for _ in f.authority.registry.dispatch.rollovers or {} do n += 1 end; return n end
	local function refused() return f:apply("rollover", { worker_id = id, trigger = "policy" }).code == "rollover_not_due" and rollovers() == 0 end
	assert(f:apply("policy", { policy = { auto_rollover = true, rollover_threshold_pct = 50 } }).ok)
	assert(send_report(f, id, "READY", { state = "idle", context_used_pct = 90 }).ok)
	check(not due() and refused(), "coordinator is not selected while rollover_include_coordinator is off")
	assert(f:apply("policy", { policy = { auto_rollover = false, rollover_include_coordinator = true } }).ok)
	check(not due() and refused(), "coordinator is not selected while auto_rollover is off")
	assert(f:apply("policy", { policy = { auto_rollover = true } }).ok)
	assert(send_report(f, id, "READY", { state = "idle", context_used_pct = 40 }).ok)
	check(not due() and refused(), "coordinator context below threshold is not due")
	assert(send_report(f, id, "READY", { state = "idle", context_used_pct = 60 }).ok)
	check(due(), "idle activated coordinator is due at threshold without a completed-work boundary")
	assert(f:apply("policy", { policy = { rollover_threshold_pct = 0 } }).ok)
	check(not due(), "coordinator calculated mode cannot use a percent-only sample")
	assert(send_report(f, id, "READY", { state = "idle",
		context_snapshot = { current_tokens = 640, first_turn_tokens = 200, window_tokens = 1000, observed_at_ms = clock.now_ms } }).ok)
	check(due(), "coordinator calculated mode is due at exact headroom threshold without a completed checkpoint")
	local requested = f:apply("rollover", { worker_id = id, trigger = "policy" })
	check(requested.code == "rollover_requested" and rollover_of(f, requested.handover_id).kind == "coordinator" and rollover_of(f, requested.handover_id).trigger == "policy"
		and rollover_of(f, requested.handover_id).phase == "checkpoint_pending", "policy trigger only requests the coordinator checkpoint")
	check(not due() and f:apply("rollover", { worker_id = id, trigger = "policy" }).code == "rollover_in_progress" and rollovers() == 1, "an in-progress coordinator rollover is never duplicated")
	check(coordinator_owner(f).phase == "running" and worker_of(f, id).retirement == nil, "the request alone neither retires nor stops the coordinator")
end
-- Successor ACCEPTED through the real mailbox_read page path (manifest + chunk from the producer's
-- codec framing), not the direct intake shortcut: reassembly must expect the handover pair.
if section == nil or section == "rollover_read_path" then
	-- The producer frames its own journaled bytes with its launch-preface binding; ORCH+'s view of the
	-- worker never shapes the pages it reads, so a wrong/missing pair reaches reassembly intact.
	local function producer_binding(f, succ_id, token)
		local binding = clone(worker_of(f, succ_id))
		if token == false then binding.handover_id = nil; binding.handover_token = nil elseif token then binding.handover_token = token end
		return binding
	end
	local function accepted_bytes(f, succ_id, token)
		local succ = worker_of(f, succ_id)
		return f:report(succ_id, 1, "ACCEPTED", { assignment_sha256 = succ.assignment_sha256 },
			if token == false then nil else { handover_id = succ.handover_id, handover_token = token or succ.handover_token })
	end
	local function read_pages(f, succ_id, token)
		local framed = assert(codec.frame(accepted_bytes(f, succ_id, token), "report", producer_binding(f, succ_id, token)))
		local objects = { framed.manifest }
		for _, chunk in framed.chunks do table.insert(objects, chunk) end
		check(#objects >= 2, "ACCEPTED travels as manifest plus chunk pages")
		local outcome
		for _, object in objects do
			local queued = f:apply("poll", { worker_id = succ_id }); assert(queued.ok, queued.message)
			local request = f:action(queued.action_id).request
			assert(request.op == "mailbox_read" and request.selector.stream == "report", request.op)
			outcome = f:finish(queued.action_id, "read", runtime.json.decode(assert(codec.project_page(object, request.selector))))
		end
		return outcome
	end
	local function accept_after_read(f, succ_id)
		local publish = f:apply("poll", { worker_id = succ_id }); assert(f:action(publish.action_id).request.op == "mailbox_publish_ack")
		assert(f:finish(publish.action_id, "published", {}).ok)
		local accept = f:apply("poll", { worker_id = succ_id }); assert(accept.ok, accept.message)
		local request = f:action(accept.action_id).request
		assert(request.op == "accept")
		return accept.action_id, request
	end
	-- Worker successor: exact pair is accepted through reassembly.
	local f, id = rollover_fixture()
	local hid, succ_id = rollover_granted(f, id)
	successor_created(f, succ_id)
	local outcome = read_pages(f, succ_id)
	local succ = worker_of(f, succ_id)
	check(outcome.ok and outcome.code ~= "report_rejected" and succ.rejected_report == nil and succ.phase == "accepted" and succ.accepted_seq == 1,
		"successor ACCEPTED with its issued handover pair commits through mailbox_read reassembly: " .. tostring(outcome.code))
	local accept_id, accept_request = accept_after_read(f, succ_id)
	check(accept_request.handover_id == hid and accept_request.handover_token == rollover_of(f, hid).handover_token, "read-path acceptance queues the handover-bound SPAWN accept")
	assert(f:finish(accept_id, "accepted", {}).ok)
	check(rollover_of(f, hid).phase == "handover_accepted" and worker_of(f, id).finish == nil, "read-path acceptance advances to handover_accepted without stopping the predecessor")
	-- Wrong or missing pair through the same path is held, never accepted.
	for _, token in { string.rep("0", 64), false } do
		local g, gid = rollover_fixture()
		local ghid, gsucc = rollover_granted(g, gid)
		successor_created(g, gsucc)
		local held = read_pages(g, gsucc, token)
		local gs = worker_of(g, gsucc)
		check(held.ok and held.code == "report_rejected" and gs.rejected_report ~= nil and gs.rejected_report.code == "binding_mismatch"
			and gs.phase == "awaiting_acceptance" and gs.accepted_seq == 0 and gs.accepted_event == nil,
			"read-path ACCEPTED with " .. (if token then "a wrong" else "no") .. " handover pair is retained as a rejected report, not accepted")
		check(rollover_of(g, ghid).phase == "successor_created" and worker_of(g, gid).finish == nil and #actions_of(g, gsucc, "accept") == 0,
			"rejected read-path acceptance never advances the handover or stops the predecessor")
	end
	-- Coordinator successor: the same reassembly path must expect its handover pair too.
	local c, cid = coordinator_ready()
	local chid = coordinator_retirement_requested(c, cid)
	local stop = coordinator_stop_action(c, cid)
	assert(c:finish(stop, "stopped", { pane_binding = clone(c:action(stop).request.pane_binding), observation = "exited" }).ok)
	local retire = c:apply("poll", { worker_id = cid }); assert(c:finish(retire.action_id, "retired", {}).code == "coordinator_retired")
	local csucc = rollover_of(c, chid).successor_worker_id
	local provision = actions_of(c, csucc, "mailbox_provision"); assert(#provision == 1)
	assert(c:finish(provision[1], "provisioned", { handle = "mailbox-coordinator-successor", binding_digest = string.rep("c", 64),
		capabilities = runtime.json.array({ "report-files-v1", "native-ask-v1", "coordinator-control-v1", "project-start-v1" }), limits = {} }).ok)
	assert(c:finish(worker_of(c, csucc).launch_action_id, "awaiting_acceptance", { pane_binding = successor_pane(c) }).ok)
	local coutcome = read_pages(c, csucc)
	check(coutcome.ok and coutcome.code ~= "report_rejected" and worker_of(c, csucc).rejected_report == nil and worker_of(c, csucc).phase == "accepted",
		"coordinator successor ACCEPTED with its handover pair commits through mailbox_read reassembly: " .. tostring(coutcome.code))
	local caccept = accept_after_read(c, csucc)
	assert(c:finish(caccept, "accepted", {}).ok)
	check(rollover_of(c, chid).phase == "handover_accepted" and worker_of(c, csucc).activation ~= nil, "read-path coordinator acceptance issues the handover-bound activation")
	check(state.rehydrate(clone(c.authority.registry)) ~= nil and state.rehydrate(clone(f.authority.registry)) ~= nil, "read-path acceptance restores")
end
-- Producer-framed manifest + chunk pages fed through real poll → mailbox_read → result.
local function read_report_pages(f, worker_id, bytes, binding)
	local framed = assert(codec.frame(bytes, "report", binding))
	local objects = { framed.manifest }
	for _, chunk in framed.chunks do table.insert(objects, chunk) end
	local outcome
	for _, object in objects do
		local queued = f:apply("poll", { worker_id = worker_id }); assert(queued.ok, queued.message)
		local request = f:action(queued.action_id).request
		assert(request.op == "mailbox_read" and request.selector.stream == "report", request.op)
		outcome = f:finish(queued.action_id, "read", runtime.json.decode(assert(codec.project_page(object, request.selector))))
	end
	return outcome
end
local function successor_acceptance_bytes(f, succ_id, seq, token)
	local succ = worker_of(f, succ_id)
	return f:report(succ_id, seq or 1, "ACCEPTED", { assignment_sha256 = succ.assignment_sha256 }, { handover_id = succ.handover_id, handover_token = token or succ.handover_token })
end
local function accept_after_acceptance(f, succ_id)
	local publish = f:apply("poll", { worker_id = succ_id }); assert(f:action(publish.action_id).request.op == "mailbox_publish_ack")
	assert(f:finish(publish.action_id, "published", {}).ok)
	local accept = f:apply("poll", { worker_id = succ_id }); assert(accept.ok, accept.message)
	assert(f:action(accept.action_id).request.op == "accept")
	return accept.action_id
end
if section == nil or section == "rollover_reload_continuation" then
	local f, id = rollover_fixture()
	local hid, succ_id = rollover_granted(f, id)
	successor_created(f, succ_id)
	local original = clone(worker_of(f, succ_id))
	f.authority = host.new_authority(f.memory); assert(f.authority:load().ok)
	f.origin.window_epoch = "replacement-window"; f.controller_pane = "9010"
	assert(f:apply("continue_controller", { expected_revision = f.authority.registry.revision, operator_verified = true }).ok)
	assert(f:control("reconcile_session").ok) -- Fresh peer observation restores admission, never the old revision fence.
	check(worker_of(f, succ_id).continuation_required and worker_of(f, succ_id).phase == "awaiting_acceptance" and rollover_of(f, hid).phase == "successor_created",
		"reload mid-handover leaves the unaccepted successor without a continued route")
	check(f:apply("poll", { worker_id = succ_id }).code == "worker_unbound", "its mailbox is not read before explicit continuation")
	local projected = dispatch.project(f.authority.registry, f.origin.logical_session_id, f.origin.alias_nonce).workers[succ_id]
	check(projected.continuation_required and projected.pane_binding ~= nil and projected.phase == "awaiting_acceptance",
		"the controller projection exposes the continuation need for the awaiting_acceptance generation")
	local pane = { pane_id = "9013", window_key = "", window_epoch = f.origin.window_epoch, native_session_id = "7", window_host_id = "local" }
	check(f:apply("continue_worker", { worker_id = succ_id, pane_binding = pane, continuation_proof = string.rep("0", 64), operator_verified = true }).code == "stale_recovery",
		"continuation still requires the exact scoped attachment proof")
	local attached = f:apply("continue_worker", { worker_id = succ_id, pane_binding = pane,
		continuation_proof = dispatch.continuation_proof(f.authority.registry, worker_of(f, succ_id)), operator_verified = true })
	check(attached.ok and attached.code == "attachment_queued" and f:action(attached.action_id).request.op == "attach_worker"
		and f:action(attached.action_id).request.attestation == "old_executors_stopped_or_retired", "awaiting_acceptance successor uses the existing attested SPAWN attach_worker path")
	check(f:finish(attached.action_id, "attached", { pane_binding = pane, previous_origin_binding = original.origin_binding, previous_pane_binding = original.pane_binding }).ok,
		"SPAWN-confirmed attachment commits")
	local succ = worker_of(f, succ_id)
	check(not succ.continuation_required and succ.launch_action_id == original.launch_action_id and succ.enrolment_token == original.enrolment_token
		and succ.handover_token == original.handover_token and succ.mailbox_handle == original.mailbox_handle and succ.control_pane_binding.pane_id == "9013",
		"attachment keeps launch, enrolment, mailbox and handover identity and records the current route")
	local outcome = read_report_pages(f, succ_id, successor_acceptance_bytes(f, succ_id), clone(succ))
	check(outcome.ok and worker_of(f, succ_id).phase == "accepted" and worker_of(f, succ_id).rejected_report == nil, "ACCEPTED is read through the continued route after reload")
	assert(f:finish(accept_after_acceptance(f, succ_id), "accepted", {}).ok)
	local successors = 0; for _, w in f.authority.registry.dispatch.workers do if w.handover_id == hid then successors += 1 end end
	check(rollover_of(f, hid).phase == "handover_accepted" and successors == 1 and #actions_of(f, succ_id, "mailbox_provision") == 0
		and #actions_of(f, succ_id, "launch") == 0 and #actions_of(f, succ_id, "attach_worker") == 0 and #actions_of(f, succ_id, "accept") == 0
		and worker_of(f, id).finish == nil, "handover reaches handover_accepted retaining live bindings, not completed provision/launch/attachment/accept records")
	check(state.rehydrate(clone(f.authority.registry)) ~= nil, "continued successor restores")
end
if section == nil or section == "recheck_report" then
	-- A valid ACCEPTED previously held by an ORCH+ defect (simulated durable state) is accepted on re-check.
	local f, id = rollover_fixture()
	local hid, succ_id = rollover_granted(f, id)
	successor_created(f, succ_id)
	local bytes = successor_acceptance_bytes(f, succ_id)
	local w = f.authority.registry.dispatch.workers[succ_id]
	w.rejected_report = { code = "binding_mismatch", message = "Simulated pre-fix rejection of a valid acceptance.", bytes = bytes, sha256 = codec.sha256(bytes), action_id = "action-simulated-read" }
	w.reason = { code = "binding_mismatch", message = "Simulated pre-fix rejection of a valid acceptance." }
	f.memory.value = clone(f.authority.registry)
	check(state.rehydrate(clone(f.authority.registry)) ~= nil, "simulated held acceptance is a valid durable state")
	check(f:apply("intake", { worker_id = succ_id, bytes = bytes }).code == "report_held", "ordinary intake cannot bypass the held report")
	local rechecked = f:apply("recheck_report", { worker_id = succ_id })
	w = worker_of(f, succ_id)
	check(rechecked.ok and rechecked.code == "held_report_accepted" and rechecked.seq == 1 and rechecked.sha256 == codec.sha256(bytes)
		and w.rejected_report == nil and w.phase == "accepted" and w.accepted_seq == 1 and w.receipts["1"].sha256 == codec.sha256(bytes)
		and w.accepted_event.event_id == codec.sha256(w.mailbox_handle .. ":report:1"), "re-check accepts the exact same retained bytes as the next sequence")
	check(f:apply("recheck_report", { worker_id = succ_id }).code == "no_progress", "nothing remains to re-check")
	assert(f:finish(accept_after_acceptance(f, succ_id), "accepted", {}).ok)
	check(rollover_of(f, hid).phase == "handover_accepted", "a re-checked acceptance proceeds exactly like a fresh read")
	-- A genuinely invalid held report stays held with the current reason and identical bytes.
	local g, gid = rollover_fixture()
	local ghid, gsucc = rollover_granted(g, gid)
	successor_created(g, gsucc)
	local wrong = successor_acceptance_bytes(g, gsucc, 1, string.rep("0", 64))
	local binding = clone(worker_of(g, gsucc)); binding.handover_token = string.rep("0", 64)
	check(read_report_pages(g, gsucc, wrong, binding).code == "report_rejected", "wrong-token acceptance is held by the read path")
	local held = clone(worker_of(g, gsucc).rejected_report)
	local still = g:apply("recheck_report", { worker_id = gsucc })
	local gs = worker_of(g, gsucc)
	check(still.ok and still.code == "held_report_still_rejected" and still.reason_code == "binding_mismatch" and gs.rejected_report.bytes == held.bytes
		and gs.rejected_report.sha256 == held.sha256 and gs.accepted_seq == 0 and gs.phase == "awaiting_acceptance" and #actions_of(g, gsucc, "accept") == 0
		and rollover_of(g, ghid).phase == "successor_created", "re-check refuses a genuinely invalid report and keeps the same bytes held")
	-- Identity: a held report that is not the exact next sequence is refused without any change.
	local skipped = successor_acceptance_bytes(g, gsucc, 2)
	gs.rejected_report = { code = "binding_mismatch", message = "Held out-of-sequence bytes.", bytes = skipped, sha256 = codec.sha256(skipped), action_id = held.action_id }
	g.memory.value = clone(g.authority.registry)
	local before = runtime.json.encode(g.authority.registry)
	check(g:apply("recheck_report", { worker_id = gsucc }).code == "held_report_sequence" and runtime.json.encode(g.authority.registry) == before,
		"re-check never skips a sequence")
	local forged = clone(g.authority.registry); forged.dispatch.workers[gsucc].rejected_report.sha256 = codec.sha256(wrong)
	check(state.rehydrate(forged) == nil, "held bytes and their SHA-256 cannot diverge")
	g.authority = host.new_authority(g.memory); assert(g.authority:load().ok)
	assert(g:apply("continue_controller", { expected_revision = g.authority.registry.revision, operator_verified = true }).ok)
	assert(g:control("reconcile_session").ok) -- Fresh peer observation restores admission, never the old revision fence.
	check(g:apply("recheck_report", { worker_id = gsucc }).code == "worker_unbound", "re-check after reload requires explicit worker continuation first")
end
if section == nil or section == "project_rollover" then
	for _, enrolled in { false, true } do
		local f = fixture(function() return { now_ms = 1000, mono_ms = 1000, epoch = "conversation-rollover" } end, { passive = true })
		f:catalog(0)
		local project = f:project("Live conversation, held project", false)
		local pane = { pane_id = "9002", window_key = f.origin.window_key, window_epoch = f.origin.window_epoch,
			native_session_id = f.origin.native_session_id, window_host_id = f.origin.window_host_id }
		local fields = { orch_project_id = project, record_id = "native", record_revision = 0, catalog_revision = 0 }
		if enrolled then fields.pane_binding = pane; fields.delivery = "native_ask"
		else fields.prompt = codec.OPEN_CONVERSATION_ASSIGNMENT; fields.cwd = "/fixture"; fields.placement = "split"
			fields.coordinator = false; fields.presentation = "user_new_tab"; fields.open_conversation = true end
		local queued = f:apply(if enrolled then "enrol" else "queue", fields); assert(queued.ok, queued.message)
		local id = queued.worker_id
		assert(f:finish(queued.action_id, "provisioned", { handle = "mailbox-conversation", binding_digest = string.rep("a", 64),
			capabilities = runtime.json.array({ "report-files-v1", "native-ask-v1" }), limits = {} }).ok)
		assert(f:finish(worker_of(f, id).launch_action_id, "awaiting_acceptance", { pane_binding = pane }).ok)
		assert(send_report(f, id, "ACCEPTED", { assignment_sha256 = worker_of(f, id).assignment_sha256 }).ok)
		assert(f:finish(f:apply("poll", { worker_id = id }).action_id, "published", {}).ok)
		assert(f:finish(f:apply("poll", { worker_id = id }).action_id, "accepted", {}).ok)
		assert(f:apply("observe", { worker_id = id, pane_binding = pane, native_state = "idle" }).ok)
		local hid, successor = rollover_granted(f, id)
		local provision = actions_of(f, successor, "mailbox_provision")[1]
		check(not dispatch.project(f.authority.registry, f.origin.logical_session_id, f.origin.alias_nonce).actions[provision].start_blocked,
			"verified successor lineage can continue an active conversation without starting its project")
		for _, mutation in { "token", "owner", "missing" } do
			local forged = clone(f.authority.registry)
			if mutation == "token" then forged.dispatch.workers[successor].handover_token = string.rep("0", 64)
			elseif mutation == "owner" then forged.dispatch.rollovers[hid].successor_worker_id = id
			else forged.dispatch.rollovers[hid] = nil end
			check(dispatch.project(forged, f.origin.logical_session_id, f.origin.alias_nonce).actions[provision].start_blocked,
				"arbitrary or mismatched handover metadata cannot release held work: " .. mutation)
		end
		successor_created(f, successor)
		check(not f.authority.registry.dispatch.projects[project].started
			and worker_of(f, successor).presentation == "background", "real provision and launch preserve the project's START hold")
		check(state.rehydrate(clone(f.authority.registry)) ~= nil, "unstarted-project conversation handover restores")
	end
end

-- Enrollment never substitutes an old task for fresh protocol instructions.
if section == nil or section == "enrol" then
	local function setup(clipboard)
		local f = fixture(nil, { passive = true }); f:catalog(0)
		local project = f:project("Existing conversation", false)
		if clipboard then
			local row = f.authority.registry.dispatch.catalogs[f.origin.logical_session_id].records[1]
			row.backend = "local-terminal"; row.capabilities = runtime.json.array({ "report-files-v1", "worker-poll-v1" })
			f.memory.value = clone(f.authority.registry)
		end
		local pane = { pane_id = "9020", window_key = f.origin.window_key, window_epoch = f.origin.window_epoch,
			native_session_id = f.origin.native_session_id, window_host_id = f.origin.window_host_id }
		local function enrol(extra)
			local fields = { orch_project_id = project, record_id = "native", record_revision = 0, catalog_revision = 0,
				pane_binding = clone(pane), delivery = if clipboard then "clipboard" else "native_ask" }
			for key, value in extra or {} do fields[key] = value end
			return f:apply("enrol", fields)
		end
		return f, pane, project, enrol
	end
	local function provision(f, queued)
		assert(queued.ok, queued.message)
		assert(f:finish(queued.action_id, "provisioned", { handle = "mailbox-enrolled", binding_digest = string.rep("d", 64),
			capabilities = runtime.json.array({ "report-files-v1", "native-ask-v1", "worker-poll-v1" }), limits = {} }).ok)
		return worker_of(f, queued.worker_id).launch_action_id
	end
	for _, clipboard in { false, true } do
		local f, pane, project, enrol = setup(clipboard)
		local writes = f.memory.writes
		check(not enrol({ prompt = "Replay the existing task" }).ok and f.memory.writes == writes, "enrollment rejects task replay before writing")
		local other = clone(pane); other.native_session_id = "8"
		check(not enrol({ pane_binding = other }).ok, "enrollment refuses a pane of another native session")
		local queued = enrol(); local id = queued.worker_id
		local operation = provision(f, queued); local request = f:action(operation).request
		check(request.op == "enrol" and request.delivery == (if clipboard then "clipboard" else "native_ask")
			and request.preserve_context == true and request.attestation == nil and request.prompt == codec.OPEN_CONVERSATION_ASSIGNMENT
			and request.enrolment.assignment_sha256 == codec.sha256(codec.OPEN_CONVERSATION_ASSIGNMENT)
			and request.fresh == nil and request.cwd == nil, "one canonical enrollment preserves native context without launch or attestation")
		local early = f:apply("intake", { worker_id = id, bytes = f:report(id, 1, "ACCEPTED", { assignment_sha256 = codec.sha256(codec.OPEN_CONVERSATION_ASSIGNMENT) }) })
		check(early.code == "launch_unbound" and worker_of(f, id).accepted_event == nil, "reports cannot activate before the post-composition native result")
		assert(f:finish(operation, "awaiting_acceptance", { pane_binding = pane }).ok)
		check(worker_of(f, id).accepted_event == nil and worker_of(f, id).prompt_delivery == (if clipboard then "copied_not_accepted" else "submitted_not_accepted")
			and f.authority.registry.dispatch.projects[project].started == false, "copy/submission is not acceptance and does not START a project")
		check(enrol().code == "pane_bound", "a pending capability is not issued twice")
		local cancel = f:apply("cancel_work", { worker_id = id }); assert(cancel.ok, cancel.message)
		local retirement = f:action(cancel.action_id).request
		check(retirement.op == "mailbox_retire" and retirement.mode == "retire" and retirement.report_floor == 0 and retirement.reply_floor == 0
			and #actions_of(f, id, "stop") == 0, "pending enrollment cancellation revokes only the untouched capability")
		local held = f:apply("intake", { worker_id = id, bytes = f:report(id, 1, "ACCEPTED", { assignment_sha256 = worker_of(f, id).assignment_sha256 }) })
		check(not held.ok and worker_of(f, id).accepted_event == nil, "acceptance cannot race unresolved revocation")
		assert(f:finish(cancel.action_id, "retired", {}).ok)
		local p = f.authority.registry.dispatch.projects[project]
		check(worker_of(f, id).mailbox_retired == true and worker_of(f, id).stopped == nil and next(p.associations) ~= nil
			and #actions_of(f, id, "stop") == 0, "positive revocation keeps the original native conversation as a passive association")
	end
	for _, phase in { "queued", "provisioned", "refused", "awaiting_acceptance" } do
		local c, binding, project, enroll = setup(false)
		local p = c.authority.registry.dispatch.projects[project]
		local associated = c:apply("associate_conversation", { orch_project_id = project, project_revision = p.revision,
			pane_binding = binding, active = false, provider = "Declared original", account_label = "Not verified" })
		assert(associated.ok, associated.message)
		local original = clone(c.authority.registry.dispatch.projects[project].associations[associated.conversation_id])
		local queued = enroll(); assert(queued.ok, queued.message)
		if phase ~= "queued" then
			local operation = provision(c, queued)
			if phase == "refused" then
				assert(c:finish(operation, "rejected", nil, { code = "unsupported_capability", message = "Agent was not safely idle." }).ok)
				check(enroll().code == "pane_bound", "a refused ask retains its capability until proven cleanup; it cannot mint another token")
			elseif phase == "awaiting_acceptance" then assert(c:finish(operation, "awaiting_acceptance", { pane_binding = binding }).ok) end
		end
		check(state.rehydrate(clone(c.authority.registry)) ~= nil, phase .. ": original passive association survives durable enrollment state")
		local cancelled = c:apply("cancel_work", { worker_id = queued.worker_id }); assert(cancelled.ok, cancelled.message)
		if cancelled.action_id then
			check(c.authority.registry.dispatch.projects[project].associations[associated.conversation_id] == nil,
				phase .. ": pending revocation cannot pretend the capability is already gone")
			assert(c:finish(cancelled.action_id, "retired", {}).ok)
		end
		check(runtime.json.encode(c.authority.registry.dispatch.projects[project].associations[associated.conversation_id]) == runtime.json.encode(original)
			and #actions_of(c, queued.worker_id, "stop") == 0, phase .. ": cancellation restores exact original association identity and labels without native stop")
	end
	local f, pane, _, enrol = setup(true)
	local queued = enrol(); local operation = provision(f, queued)
	assert(f:finish(operation, "awaiting_acceptance", { pane_binding = pane }).ok)
	local cancel = f:apply("cancel_work", { worker_id = queued.worker_id }); assert(cancel.ok)
	assert(f:finish(cancel.action_id, "rejected", nil, { code = "producer_unsettled", message = "Producer consumed the capability first." }).ok)
	local w = worker_of(f, queued.worker_id); local token = w.enrolment_token
	check(w.mailbox_retired ~= true and w.enrol_cancelling and w.retirement_refused and #actions_of(f, w.worker_id, "stop") == 0,
		"producer-won refusal retains the live capability and does not stop the conversation")
	assert(f:apply("intake", { worker_id = w.worker_id, bytes = f:report(w.worker_id, 1, "ACCEPTED", { assignment_sha256 = w.assignment_sha256 }) }).ok)
	check(worker_of(f, w.worker_id).enrol_cancelling == nil and worker_of(f, w.worker_id).enrolment_token == token,
		"only the original exact acceptance settles a consumed capability, without reissue")
	local u, _, _, uncertain_enrol = setup(false)
	local uq = uncertain_enrol(); local aid = provision(u, uq)
	assert(u:apply("claim", { action_id = aid, executor = u.origin.window_epoch }).ok)
	local grant = clone(u:action(aid).claim)
	assert(u:apply("lost", { action_id = aid, executor = grant.executor, grant_id = grant.grant_id }).ok)
	check(u:apply("retry", { action_id = aid }).code == "retry_refused" and not u:apply("cancel_work", { worker_id = uq.worker_id }).ok
		and uncertain_enrol().code == "pane_bound" and #actions_of(u, uq.worker_id, "enrol") == 1, "uncertain enrollment is neither replayed nor deleted")
end
if section == nil or section == "projects" then
	local f = fixture(nil, { passive = true }); f:catalog(0)
	local a, b = f:project("Research", false), f:project("Separate work", false)
	local pane = { pane_id = "9021", window_key = f.origin.window_key, window_epoch = f.origin.window_epoch,
		native_session_id = f.origin.native_session_id, window_host_id = f.origin.window_host_id }
	local p = f.authority.registry.dispatch.projects[a]
	local attach = f:apply("associate_conversation", { orch_project_id = a, project_revision = p.revision, pane_binding = pane, active = true, provider = "Unknown" })
	assert(attach.ok, attach.message)
	local view = dispatch.project(f.authority.registry, f.origin.logical_session_id)
	check(view.projects[a].status == "ACTIVE" and not view.projects[a].started and next(f.authority.registry.dispatch.actions) == nil,
		"unsupported/busy conversation association is display-only and creates no protocol effects")
	local function queue(project, prompt)
		return f:apply("queue", { orch_project_id = project, record_id = "native", record_revision = 0, catalog_revision = 0,
			prompt = prompt, cwd = "/fixture", placement = "split", coordinator = false })
	end
	local qa, qb = queue(a, "Read documentation only."), queue(b, "Unrelated work."); assert(qa.ok and qb.ok)
	check(qa.action_id == nil and qb.action_id == nil and next(f.authority.registry.dispatch.actions) == nil, "association and queue intake cannot bypass START")
	assert(f:apply("pause").ok)
	p = f.authority.registry.dispatch.projects[a]
	local start = f:apply("project_start", { orch_project_id = a, project_revision = p.revision }); assert(start.ok, start.message)
	check(next(f.authority.registry.dispatch.actions) == nil and f.authority.registry.dispatch.projects[a].started
		and not f.authority.registry.dispatch.projects[b].started, "START while paused records only the chosen intent")
	assert(f:apply("resume").ok)
	check(#actions_of(f, qa.worker_id, "mailbox_provision") == 1 and #actions_of(f, qb.worker_id, "mailbox_provision") == 0,
		"resume releases only explicitly started project work")
	p = f.authority.registry.dispatch.projects[a]
	local revision = p.revision
	check(f:apply("project_start", { orch_project_id = a, project_revision = revision }).code == "project_already_started"
		and f.authority.registry.dispatch.projects[a].revision == revision and #actions_of(f, qa.worker_id, "mailbox_provision") == 1, "START is idempotent")
	local unchanged = f:event("project_start", { orch_project_id = b, project_revision = f.authority.registry.dispatch.projects[b].revision })
	local unrelated = f:project("Bookkeeping elsewhere", false)
	unchanged.command_seq = f.command_seq + 1; f.command_seq = unchanged.command_seq
	check(f.authority:apply(unchanged).ok, "subject proof survives unrelated project bookkeeping")
	local bad = f:event("project_start", { orch_project_id = unrelated, project_revision = f.authority.registry.dispatch.projects[unrelated].revision })
	assert(f:apply("pause").ok)
	bad.command_seq = f.command_seq + 1; f.command_seq = bad.command_seq
	local writes = f.memory.writes
	check(not f.authority:apply(bad).ok and f.memory.writes == writes, "pause change invalidates a captured START with no write")
	local missing = f:event("project_start", { orch_project_id = unrelated, project_revision = f.authority.registry.dispatch.projects[unrelated].revision })
	missing.decision_context = nil
	check(not f.authority:apply(missing).ok, "legacy missing-proof decisions never acquire implicit authority")
	-- Association-only finish is presentation, not native stop. Reopen has no old workers or approvals.
	local done = f:project("Read-only conversation", false)
	p = f.authority.registry.dispatch.projects[done]
	pane.pane_id = "9099"
	assert(f:apply("associate_conversation", { orch_project_id = done, project_revision = p.revision, pane_binding = pane, active = true }).ok)
	p = f.authority.registry.dispatch.projects[done]
	assert(f:apply("project_finish", { orch_project_id = done, project_revision = p.revision, result = "Research findings reviewed." }).ok)
	view = dispatch.project(f.authority.registry, f.origin.logical_session_id)
	check(view.projects[done] == nil and #view.finished_projects == 1 and #view.finished_projects[1].links == 1, "finished association keeps a native conversation link without an effect")
	local reopened = f:apply("project_reopen", { summary_index = 1 }); assert(reopened.ok)
	check(not f.authority.registry.dispatch.projects[reopened.orch_project_id].started
		and next(f.authority.registry.dispatch.projects[reopened.orch_project_id].associations) == nil, "reopen creates a new unstarted project, not a replay")
	do
		local moved = fixture(nil, { passive = true }); moved:catalog(0)
		local source, target = moved:project("Held task", false), moved:project("Already started", true)
		local queued = moved:apply("queue", { orch_project_id = source, record_id = "native", record_revision = 0, catalog_revision = 0,
			prompt = "Keep this task held.", cwd = "/fixture", placement = "split", coordinator = false })
		assert(queued.ok)
		local target_row = moved.authority.registry.dispatch.projects[target]
		assert(moved:apply("project_associate", { worker_id = queued.worker_id, orch_project_id = target, project_revision = target_row.revision }).ok)
		check(#actions_of(moved, queued.worker_id, "mailbox_provision") == 0 and worker_of(moved, queued.worker_id).checks_pending,
			"moving held work into an ACTIVE project does not supply START authority")
		target_row = moved.authority.registry.dispatch.projects[target]
		assert(moved:apply("project_start", { orch_project_id = target, project_revision = target_row.revision }).ok)
		check(#actions_of(moved, queued.worker_id, "mailbox_provision") == 1, "explicit destination START releases the moved task once")
	end
	do
		local failed = fixture(nil, { passive = true }); failed:catalog(0)
		local row = failed.authority.registry.dispatch.catalogs[failed.origin.logical_session_id].records[1]
		row.backend = "local-terminal"; row.placement = "replace_if_alone"
		row.capabilities = runtime.json.array({ "report-files-v1", "worker-poll-v1" }); failed.memory.value = clone(failed.authority.registry)
		local project = failed:project("Unsupported background placement", false)
		local queued = failed:apply("queue", { orch_project_id = project, record_id = row.id, record_revision = row.revision, catalog_revision = 0,
			prompt = "Wait for explicit START.", cwd = row.cwd, placement = row.placement, coordinator = false })
		assert(queued.ok and queued.code == "task_held")
		local p = failed.authority.registry.dispatch.projects[project]
		assert(failed:apply("project_start", { orch_project_id = project, project_revision = p.revision }).ok)
		local w = worker_of(failed, queued.worker_id)
		check(w.project_held and w.checks_pending and w.reason.code == "unsupported_placement" and next(failed.authority.registry.dispatch.actions) == nil,
			"failed START remains visible, held and effect-free instead of stranding an unissued worker")
		assert(failed:apply("cancel_work", { worker_id = queued.worker_id }).ok)
		check(worker_of(failed, queued.worker_id) == nil, "a failed unissued launch remains cancellable")
	end
	for _, same_checkout in { false, true } do
		local gated = fixture(nil, { passive = true }); gated:catalog(0)
		local records = gated.authority.registry.dispatch.catalogs[gated.origin.logical_session_id].records
		local other = clone(records[1]); other.id = "other-record"; other.cwd = if same_checkout then "/different-saved-cwd" else records[1].cwd
		table.insert(records, other); gated.memory.value = clone(gated.authority.registry)
		local projects = { gated:project("First checkout", true), gated:project("Second checkout", true) }
		for i, project in projects do
			local cwd = if i == 1 or same_checkout then "/project/one" else "/project/two"
			assert(gated:apply("project_repository", { orch_project_id = project,
				project_revision = gated.authority.registry.dispatch.projects[project].revision,
				repository = { cwd = cwd, repo_root = cwd, common_dir = cwd .. "/.git", target_ref = "main",
					head_revision = string.rep("a", 40), queue_route = "orch_queue" } }).ok)
		end
		local queued
		for i, project in projects do local record = if i == 1 then records[1] else other
			queued = gated:apply("queue", { orch_project_id = project, record_id = record.id, record_revision = record.revision,
				catalog_revision = 0, prompt = "Edit only the declared file.", cwd = record.cwd, placement = record.placement,
				coordinator = false, files = runtime.json.array({ "same.luau" }) })
			assert(queued.ok, queued.message)
		end
		local kinds = {}
		for _, gate in gated.authority.registry.dispatch.gates do if gate.worker_id == queued.worker_id then kinds[gate.kind] = true end end
		check((kinds.shared_checkout == true) == same_checkout and (kinds.file_overlap == true) == same_checkout,
			"collision gates compare execution checkout rather than equal/different saved record defaults")
		if same_checkout then
			local p = gated.authority.registry.dispatch.projects[projects[2]]
			local repository = clone(p.repository); repository.queue_route = "repository_queue"
			local before = runtime.json.encode(gated.authority.registry)
			local changed = gated:apply("project_repository", { orch_project_id = p.orch_project_id, project_revision = p.revision, repository = repository })
			check(changed.code == "repository_route_conflict" and runtime.json.encode(gated.authority.registry) == before,
				"another unfinished project cannot silently change a shared repository target's queue route")
		end
	end
end
if section == nil or section == "local_v5" then
	local f = fixture(); f:catalog(0)
	local ready, issued = f:queue(false), f:queue(false); assert(ready.ok and issued.ok)
	assert(f:apply("claim", { action_id = issued.action_id, executor = f.origin.window_epoch }).ok)
	assert(f:apply("pause").ok)
	local raw = clone(f.authority.registry)
	raw.version = 4; raw.dispatch.projects = nil; raw.dispatch.finished_projects = nil
	raw.installation_defaults.policy.auto_start_projects = nil; raw.installation_defaults.policy.auto_launch_intake = false
	for _, p in raw.dispatch.policies do p.auto_start_projects = nil; p.auto_launch_intake = false end
	for _, w in raw.dispatch.workers do w.orch_project_id = nil; w.presentation = nil; w.selected_record = nil end
	local original = runtime.json.encode(raw)
	local saved_grant = clone(raw.dispatch.actions[issued.action_id].claim)
	local saved_bytes = raw.dispatch.actions[issued.action_id].request_bytes
	local restored, info = state.rehydrate(raw); must(restored, info)
	check(restored.version == 5 and info.upgrade_required and info.backup_key == "authority_state_v4_original"
		and restored.authority_namespace == raw.authority_namespace and restored.execution_epoch == raw.execution_epoch + 1,
		"local v4 conversion changes schema/epoch, never authority namespace")
	check(runtime.json.encode(raw) == original and runtime.json.encode(assert(state.upgrade_backup(raw, nil))) == original,
		"conversion leaves the original byte-equivalent value available for host backup")
	local conflict = clone(raw); conflict.revision += 1
	local backup, problem = state.upgrade_backup(raw, conflict)
	check(backup == nil and problem.code == "upgrade_backup_conflict", "a different preserved original is never overwritten")
	check(restored.dispatch.actions[ready.action_id].phase == "held_ready"
		and restored.dispatch.actions[issued.action_id].phase == "uncertain"
		and restored.dispatch.actions[issued.action_id].request_bytes == saved_bytes
		and restored.dispatch.actions[issued.action_id].claim.grant_id == saved_grant.grant_id,
		"ready work is held while issued immutable bytes/grants remain exact")
	local project = restored.dispatch.workers[ready.worker_id].orch_project_id
	check(project ~= nil and not restored.dispatch.projects[project].started
		and dispatch.policy(restored, f.origin.logical_session_id).paused
		and restored.installation_defaults.policy.auto_launch_intake == nil, "migration preserves pause and never turns old intake into start authority")
	f.authority.registry = restored; f.memory.value = clone(restored)
	assert(f:apply("continue_controller", { operator_verified = true }).ok)
	assert(f:control("reconcile_session").ok)
	f:catalog(0)
	local p = f.authority.registry.dispatch.projects[project]
	assert(f:apply("project_start", { orch_project_id = project, project_revision = p.revision }).ok)
	check(f:action(ready.action_id).phase == "ready" and not f:apply("claim", { action_id = ready.action_id, executor = f.origin.window_epoch }).ok,
		"explicit START may rearm a provably unissued intention but pause still blocks its effect")
	check(f:action(issued.action_id).phase == "uncertain" and f:action(issued.action_id).request_bytes == saved_bytes,
		"START never replays or rewrites a previously issued effect")
	local cancelled = f:apply("cancel_work", { worker_id = ready.worker_id })
	check(cancelled.ok and f.authority.registry.dispatch.workers[ready.worker_id] == nil
		and f:action(issued.action_id).request_bytes == saved_bytes, "Cancel removes only proven unissued work and leaves unrelated uncertainty intact")
end
-- Real macOS defect: a coordinator self-released while its owner-triggered rollover waited at
-- `requested`; the rollover then held `predecessor_unavailable` forever. The next coordinator
-- generation's ACCEPTED ACK publication went uncertain (host sleep), which blocked SPAWN accept,
-- so its activation, and therefore rollover, never came.
if section == nil or section == "rollover_coordinator_self_release" then
	local f, id = coordinator_ready()
	local old_generation = coordinator_owner(f).generation
	local requested = f:apply("rollover", { worker_id = id, trigger = "owner" }); assert(requested.ok, requested.message)
	local hid = requested.handover_id
	assert(rollover_of(f, hid).phase == "checkpoint_pending")
	f:drain()
	local pending_request = clone(worker_of(f, id).workflow.report_request)
	assert(send_report(f, id, "reply_ack", { message_id = pending_request.message_id, reply_seq = pending_request.reply_seq, reply_sha256 = codec.sha256(pending_request.bytes),
		status = "recorded" }, { action_id = pending_request.action_id, action_revision = pending_request.action_revision }).ok)
	-- Release never discards an outstanding progress request, including the rollover's checkpoint request.
	check(f:release().code == "workflow_unsettled" and rollover_of(f, hid).phase == "checkpoint_pending" and worker_of(f, id).release == nil,
		"a release while the rollover's checkpoint request is outstanding is refused, not used to cancel the request")
	-- The coordinator answers the request without a checkpoint (it judged its task done), then releases.
	assert(send_report(f, id, "HEARTBEAT", { state = "idle", summary = "Assigned task complete; releasing.", request_id = pending_request.request_id }).ok)
	check(worker_of(f, id).workflow.report_request == nil and rollover_of(f, hid).phase == "checkpoint_pending" and rollover_of(f, hid).hold.code == "checkpoint_missing",
		"a HEARTBEAT answer settles the request; the rollover holds checkpoint_missing")
	local released = f:release(); assert(released.ok, released.message)
	local r = rollover_of(f, hid)
	check(r.phase == "cancelled" and r.hold ~= nil and r.hold.code == "predecessor_self_released" and r.checkpoint == nil and handover_successors(f, hid) == 0,
		"a coordinator's own release before a verified checkpoint closes its rollover visibly with no successor")
	f:drain(); f:watermark()
	local stop = f:apply("poll", { worker_id = id }); assert(stop.ok, stop.message); assert(f:action(stop.action_id).request.op == "stop")
	check(coordinator_released(f, id, stop.action_id).code == "coordinator_retired" and rollover_of(f, hid) == nil
		and handover_successors(f, hid) == 0 and coordinator_owner(f) == nil, "its normal release, exact stop and mailbox retirement free the slot; nothing is granted")
	check(state.rehydrate(clone(f.authority.registry)) ~= nil, "self-released rollover closure restores")
	-- The live case: the checkpoint request waits at `requested` because the coordinator is not
	-- sendable. Native-state gating needs an epoch-bound host clock (as in rollover_coordinator_policy);
	-- the clockless retirement fixture treats every worker as sendable.
	local gclock = { now_ms = 1000, mono_ms = 1000, epoch = "self-release-host" }
	local g = fixture(function() return clone(gclock) end)
	local gid = g:accepted(true)
	assert(ack_activation(g, gid).ok)
	assert(g:apply("observe", { worker_id = gid, pane_binding = clone(worker_of(g, gid).pane_binding), native_state = "working" }).ok)
	local held = g:apply("rollover", { worker_id = gid, trigger = "owner" }); assert(held.ok, held.message)
	local gr = rollover_of(g, held.handover_id)
	check(gr.phase == "requested" and gr.hold ~= nil and gr.hold.code == "worker_not_sendable" and (worker_of(g, gid).workflow or {}).report_request == nil,
		"a working coordinator holds the rollover at requested; no checkpoint request is issued")
	local activation = worker_of(g, gid).activation
	local released_live = send_report(g, gid, "COORDINATOR_RELEASE", { owner_id = worker_of(g, gid).coordinator_owner_id, owner_generation = worker_of(g, gid).coordinator_generation,
		activation_token = activation.activation_token, quiescent = true }, { action_id = activation.action_id, action_revision = activation.action_revision })
	assert(released_live.ok, released_live.message)
	check(rollover_of(g, held.handover_id).phase == "cancelled" and rollover_of(g, held.handover_id).hold.code == "predecessor_self_released" and worker_of(g, gid).release ~= nil,
		"self-release while the rollover waits at requested is accepted and closes it instead of holding predecessor_unavailable forever")
	-- A new coordinator generation in the same session; its ACCEPTED ACK publication goes uncertain.
	f.target_pane = "9005"
	local new_id = f:launched(true)
	local owner = coordinator_owner(f)
	check(owner.managed_worker_id == new_id and owner.generation > old_generation and owner.phase == "running", "the next coordinator generation runs in the same session")
	assert(f:apply("intake", { worker_id = new_id, bytes = f:report(new_id, 1, "ACCEPTED", { assignment_sha256 = worker_of(f, new_id).assignment_sha256 }) }).ok)
	local ack = f:apply("poll", { worker_id = new_id }); assert(ack.ok, ack.message); assert(f:action(ack.action_id).request.op == "mailbox_publish_ack")
	assert(f:apply("claim", { action_id = ack.action_id, executor = f.origin.window_epoch }).ok)
	local grant = f:action(ack.action_id).claim
	assert(f:apply("lost", { action_id = ack.action_id, executor = grant.executor, grant_id = grant.grant_id }).ok)
	check(f:action(ack.action_id).phase == "uncertain" and f:apply("poll", { worker_id = new_id }).code == "operation_pending" and worker_of(f, new_id).activation == nil
		and not f:apply("rollover", { worker_id = new_id, trigger = "owner" }).ok, "reproduction: an uncertain ACCEPTED ACK blocks SPAWN accept, activation and rollover")
	check(f:apply("retry", { action_id = ack.action_id }).code == "retry_refused", "uncertain publication still never takes the capacity retry path")
	local old_request = clone(f:action(ack.action_id).request)
	local readback = f:apply("readback_publication", { action_id = ack.action_id })
	check(readback.ok and readback.code == "readback_queued" and f:action(ack.action_id) == nil
		and coordinator_owner(f).pending_executors == 0, "publication readback consumes its attempted action while the exact outbox bytes remain live")
	check(f:apply("readback_publication", { action_id = ack.action_id }).code == "readback_refused", "a resolved attempt cannot be read back again")
	local again = f:apply("poll", { worker_id = new_id }); assert(again.ok, again.message)
	local new_request = f:action(again.action_id).request
	check(again.action_id ~= ack.action_id and new_request.op == "mailbox_publish_ack" and new_request.request_id ~= old_request.request_id
		and new_request.ack_b64 == old_request.ack_b64 and new_request.ack_sha256 == old_request.ack_sha256, "the outbox re-issues exactly the same immutable ACK bytes")
	check(state.rehydrate(clone(f.authority.registry)) ~= nil, "resolved readback attempt restores")
	assert(f:finish(again.action_id, "already_published", {}).ok)
	local accept = f:apply("poll", { worker_id = new_id }); assert(accept.ok, accept.message); assert(f:action(accept.action_id).request.op == "accept")
	assert(f:finish(accept.action_id, "accepted", {}).ok)
	check(worker_of(f, new_id).activation ~= nil and #actions_of(f, new_id, "mailbox_publish_ack") == 0,
		"after readback the generation is accepted, activation is issued, and completed ACK attempts are consumed")
	assert(ack_activation(f, new_id).ok)
	check(worker_of(f, new_id).activation.acknowledged, "the second generation's activation is acknowledged")
	local rolled = f:apply("rollover", { worker_id = new_id, trigger = "owner" })
	check(rolled.ok and rolled.code == "rollover_requested", "the activated second generation may roll over")
end
-- Live macOS defect: a launch reloaded between ACCEPTED and SPAWN `accept`. SPAWN owner recovery
-- revoked the staged, never-authorized accept; ORCH+ held the worker forever. The revoked accept is
-- pre-effect: after explicit attested attachment the same immutable acceptance is re-issued on the
-- continued route, and a reloaded coordinator resumes only after that attachment.
if section == nil or section == "accept_after_owner_recovery" then
	local REVOKED = "Controller recovery revoked the unconsumed authorization"
	local function scenario(coordinator, legacy)
		local clock = { now_ms = 1000, mono_ms = 1000, epoch = "accept-recovery-host" }
		local f = fixture(function() return clone(clock) end); local id = f:launched(coordinator)
		assert(f:apply("intake", { worker_id = id, bytes = f:report(id, 1, "ACCEPTED", { assignment_sha256 = worker_of(f, id).assignment_sha256 }) }).ok)
		local publication = f:apply("poll", { worker_id = id }); assert(publication.ok)
		local publication_request = f:action(publication.action_id).request
		assert(f:finish(publication.action_id, "published", if legacy then { wake_status = "awaiting_window",
			wake_effect_started = false, wake_target_request_id = publication_request.request_id,
			wake_target_action_id = publication.action_id } else {}).ok)
		local accept = f:apply("poll", { worker_id = id }); assert(accept.ok, accept.message)
		assert(f:action(accept.action_id).request.op == "accept")
		assert(f:apply("claim", { action_id = accept.action_id, executor = f.origin.window_epoch }).ok)
		local old_request = clone(f:action(accept.action_id).request)
		local claim = clone(f:action(accept.action_id).claim)
		local old_origin = clone(f.origin)
		clock.epoch = "accept-recovery-reloaded"
		f.authority = host.new_authority(f.memory, function() return clone(clock) end); assert(f.authority:load().ok)
		f.origin.window_epoch = "replacement-window"; f.controller_pane = "9010"
		assert(f:apply("continue_controller", { expected_revision = f.authority.registry.revision, operator_verified = true }).ok)
		assert(f:control("reconcile_session").ok) -- Fresh peer observation restores admission, never the old revision fence.
		if coordinator then check(coordinator_owner(f).phase == "uncertain", "controller continuation alone never reactivates the reloaded coordinator") end
		-- SPAWN owner recovery revoked the never-consumed accept; the continued route reads that outcome.
		local problem = { code = if legacy then "binding_mismatch" else "authorization_revoked", message = REVOKED }
		local read = f:apply("result", { action_id = accept.action_id, executor = claim.executor, grant_id = claim.grant_id, response_bytes = frame(old_request, "rejected", nil, problem) })
		if legacy then
			check(read.ok and worker_of(f, id).phase == "held" and worker_of(f, id).reason.code == "binding_mismatch"
				and worker_of(f, id).accept_pending and f:action(accept.action_id) == nil,
				"legacy diagnostic wording cannot turn a generic binding refusal into pre-effect authorization")
		else
			check(read.ok and read.code == "accept_reissue" and worker_of(f, id).phase == "accepted" and worker_of(f, id).accept_pending and f:action(accept.action_id) == nil,
				"a revoked never-consumed acceptance is pre-effect, not a terminal hold")
		end
		check(f:apply("poll", { worker_id = id }).code == "worker_unbound", "nothing is re-issued before explicit worker attachment")
		local pane = { pane_id = "9011", window_key = "", window_epoch = f.origin.window_epoch, native_session_id = "7", window_host_id = "local" }
		local attached = f:apply("continue_worker", { worker_id = id, pane_binding = pane,
			continuation_proof = dispatch.continuation_proof(f.authority.registry, worker_of(f, id)), operator_verified = true }); assert(attached.ok, attached.message)
		local original = worker_of(f, id)
		assert(f:finish(attached.action_id, "attached", { pane_binding = pane, previous_origin_binding = clone(original.origin_binding), previous_pane_binding = clone(original.pane_binding) }).ok)
		if legacy then
			check(worker_of(f, id).phase == "held" and worker_of(f, id).reason.code == "binding_mismatch",
				"explicit attachment changes only the route, never clears a generic acceptance refusal")
			check(next(worker_of(f, id).wakes) ~= nil, "the earlier ACK's deferred wake survives held acceptance and attachment")
			assert(f:apply("observe", { worker_id = id, pane_binding = pane, native_state = "idle" }).ok)
			local notification = f:apply("poll", { worker_id = id }); must(notification.ok, notification)
			check(f:action(notification.action_id).request.op == "native_wake" and #actions_of(f, id, "accept") == 0,
				"held generic acceptance still permits its independent deferred ACK notification")
			assert(f:finish(notification.action_id, "submitted", { wake_status = "submitted", wake_effect_started = true }).ok)
			check(next(worker_of(f, id).wakes) == nil and worker_of(f, id).phase == "held" and worker_of(f, id).accept_pending,
				"settling the real native-wake grant neither accepts the worker nor republishes its ACK")
			must(f:watermark(id).ok)
			local compact = f:apply("poll", { worker_id = id }); must(compact.ok, compact)
			check(f:action(compact.action_id).request.op == "mailbox_retire"
				and f:action(compact.action_id).request.mode == "compact" and #actions_of(f, id, "accept") == 0,
				"held generic acceptance permits real producer watermark and mailbox compaction")
			must(f:finish(compact.action_id, "compacted").ok)
			local settled = worker_of(f, id)
			check(settled.compacted_floor == settled.accepted_seq and next(settled.receipts) == nil
				and settled.compaction_pending == nil and settled.phase == "held" and settled.accept_pending
				and #actions_of(f, id, "accept") == 0,
				"producer settlement drains without clearing the generic hold or authorizing another accept")
			local writes = f.memory.writes
			local refused = f:apply("poll", { worker_id = id })
			check(not refused.ok and f.memory.writes == writes and #actions_of(f, id, "accept") == 0,
				"a held generic refusal cannot reissue acceptance or write on polling")
			check(state.rehydrate(clone(f.authority.registry)) ~= nil, "held legacy refusal restores without invented authorization")
			return
		end
		check(worker_of(f, id).phase == "accepted" and worker_of(f, id).accept_pending and (not coordinator or coordinator_owner(f).phase == "running"),
			"explicit attested attachment resumes the generation")
		local reissued = f:apply("poll", { worker_id = id }); assert(reissued.ok, reissued.message)
		local new_request = f:action(reissued.action_id).request
		check(new_request.op == "accept" and reissued.action_id ~= accept.action_id and new_request.origin_binding.window_epoch == "replacement-window" and new_request.controller_pane == "9010"
			and new_request.pane_binding.pane_id == "9011" and new_request.event_id == old_request.event_id and new_request.seq == old_request.seq and new_request.event_sha256 == old_request.event_sha256
			and new_request.enrolment_token == old_request.enrolment_token and new_request.worker_generation == old_request.worker_generation and new_request.target_request_id == old_request.target_request_id,
			"the same immutable acceptance is re-issued on the attached route only")
		local old_poll = f:event("poll", { worker_id = id }); old_poll.origin = old_origin; old_poll.controller_pane = "9001"
		check(not f.authority:apply(old_poll).ok, "the old controller incarnation stays fenced")
		assert(f:finish(reissued.action_id, "accepted", {}).ok)
		check(not worker_of(f, id).accept_pending and worker_of(f, id).reason == nil, "SPAWN acceptance settles the re-issued accept")
		if coordinator then
			check(worker_of(f, id).activation ~= nil, "the reloaded coordinator receives its activation after recovery and attachment")
			assert(ack_activation(f, id).ok)
			check(worker_of(f, id).activation.acknowledged and coordinator_owner(f).phase == "running", "activation is acknowledged on the resumed generation")
		end
		check(state.rehydrate(clone(f.authority.registry)) ~= nil, "recovered acceptance restores")
	end
	scenario(false, false)
	scenario(true, false)
	scenario(true, true)
end
-- Plan: an uncertain publication "requires readback before retry". Only ACK/reply publications;
-- native effects never take this path.
if section == nil or section == "publication_readback" then
	local f = fixture(); local id = f:accepted(false)
	assert(f:apply("reply", { worker_id = id }).ok)
	local pub = f:apply("poll", { worker_id = id }); assert(pub.ok, pub.message)
	local request = f:action(pub.action_id).request; assert(request.op == "mailbox_publish_reply")
	check(f:apply("readback_publication", { action_id = pub.action_id }).code == "readback_refused", "a ready publication is never read back")
	assert(f:apply("claim", { action_id = pub.action_id, executor = f.origin.window_epoch }).ok)
	local grant = f:action(pub.action_id).claim
	check(f:apply("readback_publication", { action_id = pub.action_id }).code == "readback_refused", "a claimed attempt is still owned by its live grant")
	assert(f:apply("lost", { action_id = pub.action_id, executor = grant.executor, grant_id = grant.grant_id }).ok)
	local executors = f.authority.registry.sessions[f.origin.logical_session_id].controller.pending_executors
	assert(f:apply("readback_publication", { action_id = pub.action_id }).ok)
	check(f.authority.registry.sessions[f.origin.logical_session_id].controller.pending_executors == executors - 1, "the superseded attempt releases its executor count")
	local again = f:apply("poll", { worker_id = id }); assert(again.ok, again.message)
	local repeated = f:action(again.action_id).request
	check(repeated.op == "mailbox_publish_reply" and again.action_id ~= pub.action_id and repeated.object_b64 == request.object_b64 and repeated.object_sha256 == request.object_sha256
		and repeated.part == request.part and repeated.index == request.index and repeated.reply_seq == request.reply_seq and repeated.message_id == request.message_id,
		"the outbox re-issues the exact same immutable reply part")
	assert(f:finish(again.action_id, "published", {}).ok)
	check(f:action(pub.action_id) == nil and f:action(again.action_id) == nil, "readback and settled publication leave no completed action copies")
	-- Native effects never take this path.
	local g = fixture(); g:catalog(0)
	local queued = g:queue(false); assert(queued.ok)
	assert(g:finish(queued.action_id, "provisioned", { handle = "mailbox-native", binding_digest = string.rep("e", 64),
		capabilities = runtime.json.array({ "report-files-v1", "native-ask-v1" }), limits = {} }).ok)
	local launch = worker_of(g, queued.worker_id).launch_action_id
	assert(g:apply("claim", { action_id = launch, executor = g.origin.window_epoch }).ok)
	local lgrant = g:action(launch).claim
	assert(g:apply("lost", { action_id = launch, executor = lgrant.executor, grant_id = lgrant.grant_id }).ok)
	check(g:apply("readback_publication", { action_id = launch }).code == "readback_refused" and g:action(launch).phase == "uncertain", "an uncertain launch is never repeated by readback")
	-- After any reload an uncertain publication that SPAWN never recorded still blocks
	-- reattachment, and readback on the continued controller route is its individual settlement.
	local function readback_reload(name, f, reload)
		local fid = f:accepted(false)
		assert(f:apply("reply", { worker_id = fid }).ok)
		local pub = f:apply("poll", { worker_id = fid }); assert(pub.ok, pub.message)
		local request = f:action(pub.action_id).request
		assert(f:apply("claim", { action_id = pub.action_id, executor = f.origin.window_epoch }).ok)
		local original = clone(f.authority.registry.dispatch.workers[fid])
		reload(f, pub.action_id)
		assert(f:apply("continue_controller", { expected_revision = f.authority.registry.revision, operator_verified = true }).ok)
		assert(f:control("reconcile_session").ok) -- Fresh peer observation restores admission, never the old revision fence.
		check(f:action(pub.action_id).phase == "uncertain", name .. ": continuation keeps the stopped executor's publication uncertain, never resolved")
		local pane = { pane_id = "9009", window_key = "", window_epoch = f.origin.window_epoch, native_session_id = "7", window_host_id = "local" }
		local function attach()
			return f:apply("continue_worker", { worker_id = fid, pane_binding = pane,
				continuation_proof = dispatch.continuation_proof(f.authority.registry, f.authority.registry.dispatch.workers[fid]), operator_verified = true })
		end
		check(attach().code == "settlement_pending", name .. ": the uncertain publication still blocks reattachment")
		local readback = f:apply("readback_publication", { action_id = pub.action_id })
		check(readback.ok and f:action(pub.action_id) == nil, name .. ": readback consumes the attempt on the continued route before reattachment: " .. tostring(readback.message))
		local attached = attach(); check(attached.ok, name .. ": reattachment proceeds after the readback: " .. tostring(attached.message))
		assert(f:finish(attached.action_id, "attached", { pane_binding = pane, previous_origin_binding = original.origin_binding, previous_pane_binding = original.pane_binding }).ok)
		local again = f:apply("poll", { worker_id = fid }); assert(again.ok, again.message)
		local repeated = f:action(again.action_id).request
		check(repeated.op == "mailbox_publish_reply" and again.action_id ~= pub.action_id and repeated.object_sha256 == request.object_sha256,
			name .. ": the reattached route re-issues the exact same reply bytes")
		assert(f:finish(again.action_id, "published", {}).ok)
		check(f:action(again.action_id) == nil and state.rehydrate(clone(f.authority.registry)) ~= nil, name .. ": one settled publication; the state restores")
	end
	readback_reload("host restart", fixture(), function(f, action_id)
		local grant = f:action(action_id).claim
		assert(f:apply("lost", { action_id = action_id, executor = grant.executor, grant_id = grant.grant_id }).ok)
		f.authority = host.new_authority(f.memory); assert(f.authority:load().ok)
	end)
	-- Window-only restart: the host stays alive, so restore never marked the old claim uncertain.
	readback_reload("window-only restart", fixture(), function(f)
		f.origin.window_epoch = "replacement-window"; f.controller_pane = "9010"
	end)
end
-- Startup withdrawal: live unissued intents and exact pre-effect refusals can be
-- cancelled; uncertain requests require retained current SPAWN proof first.
-- Continuation never turns a restored draft into proof of nonexecution.
-- A provisioned unused mailbox retires before its worker/reservations are released.
if section == nil or section == "withdraw_fenced" then
	local AUTH_FULL = { resource = "window_authorization", current = 1, limit = 1, retryable = true, effect_started = false }
	local PROVISIONED_W = { handle = "mailbox-withdraw", binding_digest = string.rep("e", 64),
		capabilities = runtime.json.array({ "report-files-v1", "native-ask-v1", "coordinator-control-v1", "project-start-v1" }), limits = {} }
	local function continue_on_b(fx)
		fx.origin.window_epoch = "replacement-window"; fx.controller_pane = "9010"
		assert(fx:apply("continue_controller", { expected_revision = fx.authority.registry.revision, operator_verified = true }).ok)
		assert(fx:control("reconcile_session").ok) -- Fresh peer observation restores admission, never the old revision fence.
	end
	-- The window's exact SPAWN status read of the fenced request and SPAWN's framed answer.
	local function status_evidence(fx, a, status, outcome_status, outcome_payload, overrides, outcome_error)
		local query = { schema = 2, origin = "orchplus", op = "status", request_id = next_id(), action_id = next_id(), origin_binding = clone(fx.origin),
			controller_pane = fx.controller_pane or "9001", controller_generation = fx.origin.owner_generation, target_request_id = a.request.request_id,
			target_request_serial = a.request.request_serial, authority_namespace = a.request.authority_namespace,
			logical_session_id = a.request.logical_session_id, admission_seq = a.request.admission_seq }
		for k, v in overrides or {} do query[k] = v end
		local payload
		if outcome_status then
			local outcome = frame(a.request, outcome_status, fx:peer_payload(a, outcome_status, outcome_payload), outcome_error, nil, fx.authority.registry.revision)
			-- `found` contains the complete validated response body, never its v2 transport envelope.
			payload = { outcome = assert(codec.decode_dispatch_response(outcome, a.request)) }
		end
		return { query_bytes = runtime.json.encode(query), response_bytes = frame(query, status, payload, nil, nil, fx.authority.registry.revision) }
	end
	local function cancel(fx, worker_id, evidence)
		local fields = { worker_id = worker_id }
		for k, v in evidence or {} do fields[k] = v end
		return fx:apply("cancel_work", fields)
	end
	local function withdrawal(fx, worker_id)
		local w = dispatch.project(fx.authority.registry, fx.origin.logical_session_id, fx.origin.alias_nonce).workers[worker_id]
		return if w then w.withdrawal else nil
	end
	local OCCUPIED = { code = "binding_mismatch", message = "Occupied SPAWN controller binding; inspect Config and recover the prior owner explicitly" }
	local function reject(fx, action_id, problem)
		if fx:action(action_id).phase == "ready" then assert(fx:apply("claim", { action_id = action_id, executor = fx.origin.window_epoch }).ok) end
		local a = fx:action(action_id)
		return fx:apply("result", { action_id = action_id, executor = a.claim.executor, grant_id = a.claim.grant_id, response_bytes = frame(a.request, "rejected", nil, problem) })
	end
	-- This worker's mailbox retirements, optionally only those in `phase`.
	local function retirements(fx, worker_id, phase)
		local n = 0
		for _, key in actions_of(fx, worker_id, "mailbox_retire") do if phase == nil or fx:action(key).phase == phase then n += 1 end end
		return n
	end
	local function same_value(a, b)
		if type(a) ~= type(b) then return false end
		if type(a) ~= "table" then return a == b end
		for k, v in a do if not same_value(v, b[k]) then return false end end
		for k in b do if a[k] == nil then return false end end
		return true
	end
	-- Cancellation eligibility also includes ordinary live startup; it is not fencing evidence.
	do
		local fresh = fixture(); fresh:catalog(0)
		local queued_fresh = fresh:queue(false); assert(queued_fresh.ok)
		local offered = withdrawal(fresh, queued_fresh.worker_id)
		check(offered.pending_startup and offered.evidence == "unissued" and not offered.status_required,
			"fresh unissued provisioning projects pending startup without removing cancellation eligibility")
		assert(fresh:finish(queued_fresh.action_id, "provisioned", PROVISIONED_W).ok)
		offered = withdrawal(fresh, queued_fresh.worker_id)
		check(offered.pending_startup and offered.op == "launch" and offered.evidence == "unissued"
			and offered.mailbox_retire == "not_requested" and not offered.status_required,
			"provisioned but unissued launch remains ordinary pending startup with exact unused-mailbox cancellation")
		local launch = worker_of(fresh, queued_fresh.worker_id).launch_action_id
		assert(fresh:finish(launch, "full", AUTH_FULL).code == "backpressure")
		offered = withdrawal(fresh, queued_fresh.worker_id)
		check(not offered.pending_startup and offered.evidence == "pre_effect_refusal" and not offered.status_required,
			"actual pre-effect refusal is distinct from pending startup without inventing a continuation")
		local cancelled = cancel(fresh, queued_fresh.worker_id)
		check(cancelled.ok and cancelled.code == "withdrawal_retiring" and not withdrawal(fresh, queued_fresh.worker_id).pending_startup,
			"cancelled startup retains its mailbox retirement, never masquerading as normal queued work")
	end
	-- A fresh retry has no issued identity. Continuation holds it without replay; explicit
	-- cancellation may remove that proven-unissued draft, never an uncertain claimed effect.
	do
		local draft = fixture(); draft:catalog(0)
		local queued_draft = draft:queue(false); assert(queued_draft.ok)
		assert(draft:finish(queued_draft.action_id, "full", AUTH_FULL).code == "backpressure")
		local retry = draft:apply("retry", { action_id = queued_draft.action_id }); assert(retry.ok)
		check(retry.action_id ~= queued_draft.action_id and draft:action(queued_draft.action_id) == nil, "retry does not inherit the old refusal as evidence for a new request")
		continue_on_b(draft)
		local offered = withdrawal(draft, queued_draft.worker_id)
		check(draft:action(retry.action_id).phase == "held_ready" and draft:action(retry.action_id).request_bytes == nil
			and draft:action(retry.action_id).claim == nil and offered and offered.evidence == "unissued" and not offered.status_required,
			"continued never-issued draft remains held and exposes only its actual unissued identity")
		check(cancel(draft, queued_draft.worker_id).ok and draft:action(retry.action_id) == nil
			and worker_of(draft, queued_draft.worker_id) == nil, "explicit cancellation removes the unissued draft without inventing a SPAWN outcome")
	end
	-- An issued launch with an unknown outcome stays uncertain across continuation. Withdrawal
	-- requires a fresh exact current peer refusal; missing state or a historical draft is not proof.
	local f = fixture(); f:catalog(0)
	local queued = f:queue(false); assert(queued.ok, queued.message)
	assert(f:finish(queued.action_id, "provisioned", PROVISIONED_W).ok)
	local id = queued.worker_id
	local launch_id = worker_of(f, id).launch_action_id
	assert(f:apply("claim", { action_id = launch_id, executor = f.origin.window_epoch }).ok)
	local issued = f:action(launch_id)
	assert(f:apply("lost", { action_id = launch_id, executor = issued.claim.executor, grant_id = issued.claim.grant_id }).ok)
	local before = clone(f:action(launch_id))
	continue_on_b(f)
	local fenced = f:action(launch_id)
	check(fenced.phase == "uncertain" and fenced.request_bytes == before.request_bytes and fenced.request.request_serial == before.request.request_serial
		and worker_of(f, id).origin_binding.window_epoch == "fixture-window", "continuation preserves the issued old-route uncertainty without replay or invented nonexecution")
	local offered = withdrawal(f, id)
	check(offered ~= nil and offered.action_id == launch_id and offered.op == "launch" and offered.status_required == true
		and offered.evidence == "unconfirmed" and offered.pending_startup == false
		and offered.request_id == fenced.request.request_id and offered.controller_generation == fenced.request.controller_generation
		and offered.mailbox_provisioned == true and offered.mailbox_retire == "not_requested",
		"the controller offers withdrawal of the fenced launch, gated on SPAWN's status of that exact request; its provisioned mailbox is not yet retired")
	local machine = dispatch.project(f.authority.registry, f.origin.logical_session_id, f.origin.alias_nonce).workers[id]
	check(machine.withdrawal.request_id == fenced.request.request_id and machine.withdrawal.origin_binding.window_epoch == "fixture-window",
		"uncertain startup projects its exact status-read identity without claiming nonexecution")
	check(cancel(f, id).code == "status_required" and worker_of(f, id) ~= nil, "SPAWN received the launch, so withdrawal needs its retained SPAWN status")
	check(cancel(f, id, status_evidence(f, fenced, "found", "pending", { authorization_required = true })).code == "authorization_live" and worker_of(f, id) ~= nil,
		"a still-live SPAWN challenge refuses withdrawal until it expires")
	check(cancel(f, id, status_evidence(f, fenced, "found", "resolved", { prompt_delivery = "not_submitted" })).code == "spawn_outcome_open" and worker_of(f, id) ~= nil,
		"an authorized SPAWN launch awaiting its executor is never withdrawn")
	check(cancel(f, id, status_evidence(f, fenced, "found", "uncertain")).code == "spawn_outcome_open" and worker_of(f, id) ~= nil,
		"an uncertain SPAWN outcome is never withdrawn")
	check(cancel(f, id, status_evidence(f, fenced, "found", "full", AUTH_FULL, { target_request_id = "launch-other" })).code == "binding_mismatch" and worker_of(f, id) ~= nil,
		"the status of another request is not evidence")
	-- C2 (ORCH+ side): SPAWN answers this exact expired, never-consumed challenge as a retryable
	-- pre-effect `full`, and then accepts the unused mailbox's `mailbox_retire` without stop evidence.
	-- The SPAWN side of the same shape is SPAWN tests/dispatch.luau section `unused_retirement`.
	local cancelled = cancel(f, id, status_evidence(f, fenced, "found", "full", AUTH_FULL))
	local fw = worker_of(f, id)
	check(cancelled.ok and cancelled.code == "withdrawal_retiring" and fw ~= nil and f:action(launch_id) == nil
		and retirements(f, id) == 1 and fw.mailbox_retire_action_id == cancelled.action_id
		and fw.withdrawn ~= nil and fw.withdrawn.op == "launch" and fw.withdrawn.action_id == launch_id and fw.withdrawn.evidence == "pre_effect_refusal",
		"the exact current pre-effect refusal consumes the uncertain launch into one live mailbox-retirement obligation")
	local retire = f:action(cancelled.action_id).request
	check(retire.op == "mailbox_retire" and retire.mode == "retire" and retire.handle == "mailbox-withdraw" and retire.origin_binding.window_epoch == "replacement-window"
		and fw.origin_binding.window_epoch == "fixture-window", "the retirement is issued on the continued route; the fenced work keeps its old route")
	local retiring_view = withdrawal(f, id)
	check(retiring_view ~= nil and retiring_view.mailbox_retire == "retiring" and retiring_view.status_required == false and retiring_view.evidence == "pre_effect_refusal"
		and retiring_view.action_id == launch_id and retiring_view.request_id == fenced.request.request_id and retiring_view.mailbox_provisioned == true,
		"the withdrawal shows the pending retirement; its consumed status evidence is not asked for again")
	check(cancel(f, id).code == "retirement_unresolved" and retirements(f, id) == 1, "a pending retirement is never issued twice")
	check(cancel(f, id, status_evidence(f, fenced, "found", "full", AUTH_FULL)).code == "invalid_command" and retirements(f, id) == 1,
		"a withdrawn request's status evidence was already consumed; cancelling again with evidence is refused")
	-- Restart while the retirement is pending on the continued route.
	local restored = state.rehydrate(clone(f.authority.registry))
	check(restored ~= nil and same_value(dispatch.project(restored, f.origin.logical_session_id, f.origin.alias_nonce).workers[id].withdrawal, retiring_view)
		and same_value(restored.dispatch.workers[id].withdrawn, fw.withdrawn), "a restart while the withdrawal retires restores the same withdrawal")
	check(f:finish(cancelled.action_id, "retired", nil).ok and worker_of(f, id).mailbox_retired == true and withdrawal(f, id) == nil,
		"SPAWN's confirmed retirement retires the unused mailbox")
	check(state.rehydrate(clone(f.authority.registry)) ~= nil, "the retired withdrawal restores")
	local again = f:queue(false)
	check(again.ok and worker_of(f, id) == nil and f:action(launch_id) == nil and f:action(queued.action_id) == nil
		and again.worker_id ~= id and worker_of(f, again.worker_id).launch_request_id ~= fenced.request.request_id,
		"the retired worker and its settled actions are reclaimed; the assignment can be queued again with a new launch request ID")
	-- A provision SPAWN refused before effects, fenced at continuation; SPAWN has no record of it.
	local g = fixture(); g:catalog(0)
	local gq = g:queue(false); assert(gq.ok)
	check(g:finish(gq.action_id, "full", { resource = "mailbox_allocation", current = 16, limit = 16, retryable = true, effect_started = false }).code == "backpressure",
		"a full mailbox allocation refuses the provision before effects")
	continue_on_b(g)
	local gprov = g:action(gq.action_id)
	check(gprov.phase == "backpressure" and gprov.response.status == "full" and worker_of(g, gq.worker_id).phase == "queued"
		and withdrawal(g, gq.worker_id).op == "mailbox_provision", "continuation retains the exact positive current pre-effect refusal")
	assert(g:allocation(gq.worker_id, { state = "none" }).ok)
	check(cancel(g, gq.worker_id).code == "work_cancelled" and worker_of(g, gq.worker_id) == nil and g:action(gq.action_id) == nil,
		"positive generation allocation-none proof consumes the unused full provision without inventing an absent root")
	local h = fixture(); h:catalog(0)
	local hq = h:queue(false); assert(hq.ok)
	assert(h:apply("claim", { action_id = hq.action_id, executor = h.origin.window_epoch }).ok)
	continue_on_b(h)
	check(cancel(h, hq.worker_id, status_evidence(h, h:action(hq.action_id), "missing")).code == "allocation_required" and worker_of(h, hq.worker_id) ~= nil,
		"a provision outcome cannot stand in for observation of its possibly retained allocation")
	assert(h:allocation(hq.worker_id, { state = "none" }).ok)
	check(cancel(h, hq.worker_id, status_evidence(h, h:action(hq.action_id), "found", "rejected", nil, nil, OCCUPIED)).code == "work_cancelled" and worker_of(h, hq.worker_id) == nil,
		"exact allocation-none and the original terminal startup rejection together permit withdrawal")
	-- Adoption whose native ask was never claimed: never sent, so no SPAWN read is needed.
	local m = fixture(); m:catalog(0)
	local function hand(fx) return { pane_id = "9020", window_key = fx.origin.window_key, window_epoch = fx.origin.window_epoch,
		native_session_id = fx.origin.native_session_id, window_host_id = fx.origin.window_host_id } end
	local function enroll(fx)
		fx.enrol_project = fx.enrol_project or fx:project("Withdrawal conversation", false)
		return fx:apply("enrol", { record_id = "native", record_revision = 0, catalog_revision = 0,
			orch_project_id = fx.enrol_project, pane_binding = hand(fx), delivery = "native_ask" })
	end
	local adopted = enroll(m); assert(adopted.ok, adopted.message)
	assert(m:finish(adopted.action_id, "provisioned", PROVISIONED_W).ok)
	local ask = worker_of(m, adopted.worker_id).launch_action_id
	local mid = adopted.worker_id
	check(m:action(ask).request.op == "enrol" and m:action(ask).phase == "ready" and m:action(ask).request_bytes == nil
		and withdrawal(m, mid).status_required == false and withdrawal(m, mid).mailbox_retire == "not_requested",
		"a live same-incarnation unissued adoption intent needs no fabricated peer outcome")
	local mfirst = cancel(m, mid)
	check(mfirst.code == "withdrawal_retiring" and worker_of(m, mid) ~= nil and worker_of(m, mid).withdrawn.op == "enrol" and retirements(m, mid) == 1,
		"the fenced adoption is withdrawn without a SPAWN read; its unused mailbox retires")
	-- SPAWN revoked the retirement's never-consumed authorization: the marker is released and the
	-- owner's next cancel issues the one retirement again.
	check(reject(m, mfirst.action_id, { code = "authorization_revoked", message = "Controller recovery revoked the unconsumed authorization" }).code == "authorization_reissue"
		and worker_of(m, mid).mailbox_retire_action_id == nil and worker_of(m, mid).withdrawn ~= nil and withdrawal(m, mid).mailbox_retire == "not_requested",
		"a revoked retirement authorization leaves the withdrawal with no retirement issued")
	check(state.rehydrate(clone(m.authority.registry)) ~= nil, "the withdrawal with a revoked retirement restores")
	local msecond = cancel(m, mid)
	check(msecond.code == "withdrawal_retiring" and msecond.action_id ~= mfirst.action_id and retirements(m, mid, "ready") == 1,
		"cancel again with no prior retirement issues exactly one")
	check(reject(m, msecond.action_id, OCCUPIED).code == "bridge_rejected" and worker_of(m, mid).phase == "held" and withdrawal(m, mid).mailbox_retire == "refused"
		and withdrawal(m, mid).status_required == false and worker_of(m, mid).reason.code == "binding_mismatch",
		"SPAWN's definite refusal holds the worker visibly with a refused retirement")
	check(m:action(msecond.action_id) == nil and retirements(m, mid) == 0
		and worker_of(m, mid).retirement_refused == true and worker_of(m, mid).mailbox_retired ~= true,
		"the completed refused grant is consumed, but the unused mailbox's live retirement obligation remains")
	check(state.rehydrate(clone(m.authority.registry)) ~= nil, "a held withdrawn worker restores")
	local mthird = cancel(m, mid)
	check(mthird.code == "withdrawal_retiring" and mthird.action_id ~= msecond.action_id and retirements(m, mid, "ready") == 1,
		"after a definite refusal the owner may cancel again with exactly one fresh retirement")
	check(worker_of(m, mid).retirement_refused == nil and cancel(m, mid).code == "retirement_unresolved"
		and retirements(m, mid, "ready") == 1,
		"explicit retry consumes the refusal marker into one fresh obligation, never a second grant")
	check(m:finish(mthird.action_id, "retired", nil).ok and worker_of(m, mid).mailbox_retired == true and withdrawal(m, mid) == nil,
		"SPAWN confirms the fresh retirement")
	check(enroll(m).code == "enrolment_queued" and worker_of(m, mid) == nil,
		"proven retirement reclaims the old capability; explicit enrollment can bind the same conversation again")
	-- A fenced coordinator start keeps its never-bound orchestrator reservation until the unused
	-- mailbox retires, then releases it.
	local c = fixture(); c:catalog(0)
	local cq = c:queue(true); assert(cq.ok, cq.message)
	assert(c:finish(cq.action_id, "provisioned", PROVISIONED_W).ok)
	local cid = cq.worker_id
	local claunch = worker_of(c, cid).launch_action_id
	check(c:finish(claunch, "full", AUTH_FULL).code == "backpressure", "the coordinator launch is refused before effects")
	continue_on_b(c)
	local reserved = coordinator_owner(c)
	check(c:action(claunch).phase == "backpressure" and c:action(claunch).response.status == "full" and reserved.phase == "reserved" and reserved.managed_worker_id == cid,
		"the current refused coordinator start still holds the session's orchestrator reservation")
	check(c:queue(true).code == "orchestrator_slot_occupied", "no second coordinator can start while the fenced one holds the slot")
	local cretire = cancel(c, cid)
	check(cretire.code == "withdrawal_retiring" and worker_of(c, cid) ~= nil and worker_of(c, cid).withdrawn.evidence == "pre_effect_refusal"
		and coordinator_owner(c) ~= nil and coordinator_owner(c).managed_worker_id == cid and coordinator_owner(c).phase == "reserved",
		"withdrawal keeps the coordinator reservation while the unused mailbox retires")
	check(c:queue(true).code == "orchestrator_slot_occupied" and state.rehydrate(clone(c.authority.registry)) ~= nil,
		"the slot stays held until SPAWN confirms retirement; the state restores")
	check(c:finish(cretire.action_id, "retired", nil).ok and coordinator_owner(c) == nil and c.authority.registry.retired == nil,
		"confirmed retirement releases the never-bound coordinator reservation")
	check(c:queue(true).code == "task_queued" and worker_of(c, cid) == nil and state.rehydrate(clone(c.authority.registry)) ~= nil,
		"the freed slot accepts an explicit new coordinator start; the withdrawn worker is reclaimed")
	-- A launch claimed on the old window may have run: it stays uncertain and is never withdrawn.
	local u = fixture(); u:catalog(0)
	local uq = u:queue(false); assert(uq.ok)
	assert(u:finish(uq.action_id, "provisioned", PROVISIONED_W).ok)
	local ulaunch = worker_of(u, uq.worker_id).launch_action_id
	assert(u:apply("claim", { action_id = ulaunch, executor = u.origin.window_epoch }).ok)
	continue_on_b(u)
	check(u:action(ulaunch).phase == "uncertain" and withdrawal(u, uq.worker_id).status_required == true
		and cancel(u, uq.worker_id, status_evidence(u, u:action(ulaunch), "missing")).code == "unknown_effect" and worker_of(u, uq.worker_id) ~= nil,
		"unknown peer outcome leaves the claimed launch uncertain; only a positive exact current refusal could withdraw it")
	-- A launch (or adoption ask) SPAWN definitively rejected after its mailbox was provisioned: the
	-- owner's cancel retires the never-used mailbox through the exact retirement path; the worker stays
	-- visible until SPAWN confirms `retired`, and a refused or uncertain retirement keeps it.
	local function rejected_launch(fx, coordinator)
		local q = fx:queue(coordinator); assert(q.ok, q.message)
		assert(fx:finish(q.action_id, "provisioned", PROVISIONED_W).ok)
		local launch = worker_of(fx, q.worker_id).launch_action_id
		assert(fx:apply("claim", { action_id = launch, executor = fx.origin.window_epoch }).ok)
		local issued = clone(fx:action(launch))
		check(reject(fx, launch, OCCUPIED).code == "bridge_rejected", "SPAWN's definite launch rejection commits after provisioning")
		return q.worker_id, launch, issued
	end
	local r = fixture(); r:catalog(0)
	local rid, rlaunch, rejected_request = rejected_launch(r, false)
	local rw = worker_of(r, rid)
	check(rw.phase == "held" and rw.mailbox_handle ~= nil and rw.pane_binding == nil and r:action(rlaunch) == nil, "the work is held with a provisioned, never-used mailbox")
	local roffer = withdrawal(r, rid)
	check(roffer ~= nil and roffer.evidence == "spawn_rejected" and roffer.op == "launch" and roffer.status_required == false and roffer.mailbox_retire == "not_requested",
		"the controller offers withdrawal that will retire the unused mailbox")
	check(cancel(r, rid, status_evidence(r, rejected_request, "missing")).code == "invalid_command", "a terminal SPAWN rejection takes no status evidence")
	local retiring = cancel(r, rid)
	local retire = r:action(retiring.action_id)
	check(retiring.code == "withdrawal_retiring" and worker_of(r, rid) ~= nil and retire.request.op == "mailbox_retire" and retire.request.mode == "retire"
		and retire.request.handle == rw.mailbox_handle and worker_of(r, rid).mailbox_retire_action_id == retiring.action_id and withdrawal(r, rid).mailbox_retire == "retiring",
		"cancel queues the exact mailbox retirement and keeps the worker visible")
	check(state.rehydrate(clone(r.authority.registry)) ~= nil, "a withdrawal retirement without native stop restores")
	check(cancel(r, rid).code == "retirement_unresolved", "a pending retirement is never issued twice")
	check(reject(r, retiring.action_id, OCCUPIED).code == "bridge_rejected" and worker_of(r, rid) ~= nil and withdrawal(r, rid).mailbox_retire == "refused"
		and worker_of(r, rid).reason.code == "binding_mismatch", "a refused retirement keeps the worker visible with SPAWN's outcome")
	local again = cancel(r, rid)
	check(again.code == "withdrawal_retiring" and again.action_id ~= retiring.action_id, "after a definite refusal the owner may cancel again with one fresh retirement")
	check(r:finish(again.action_id, "retired", nil).ok and worker_of(r, rid).mailbox_retired == true and withdrawal(r, rid) == nil,
		"SPAWN's confirmed retirement retires the unused mailbox")
	check(state.rehydrate(clone(r.authority.registry)) ~= nil, "the retired withdrawal restores")
	check(r:queue(false).code == "task_queued" and worker_of(r, rid) == nil, "the retired never-launched worker is reclaimed like any retired generation")
	-- An uncertain retirement is never re-issued.
	local s = fixture(); s:catalog(0)
	local sid = rejected_launch(s, false)
	local sretire = cancel(s, sid).action_id
	assert(s:apply("claim", { action_id = sretire, executor = s.origin.window_epoch }).ok)
	local sgrant = s:action(sretire).claim
	assert(s:apply("lost", { action_id = sretire, executor = sgrant.executor, grant_id = sgrant.grant_id }).ok)
	check(s:action(sretire).phase == "uncertain" and cancel(s, sid).code == "retirement_unresolved" and worker_of(s, sid) ~= nil and withdrawal(s, sid).mailbox_retire == "retiring",
		"an uncertain retirement keeps the worker visible and is never repeated")
	-- After continuation the retirement runs on the continued route.
	local k = fixture(); k:catalog(0)
	local kid = rejected_launch(k, false)
	continue_on_b(k)
	local kretire = cancel(k, kid)
	check(kretire.code == "withdrawal_retiring" and k:action(kretire.action_id).request.origin_binding.window_epoch == "replacement-window"
		and state.rehydrate(clone(k.authority.registry)) ~= nil, "the withdrawal retirement is issued on the continued route")
	check(k:finish(kretire.action_id, "retired", nil).ok and worker_of(k, kid).mailbox_retired == true, "the continued route confirms retirement")
	-- A rejected adoption ask is withdrawn the same way.
	local a = fixture(); a:catalog(0)
	local apane = { pane_id = "9020", window_key = a.origin.window_key, window_epoch = a.origin.window_epoch, native_session_id = a.origin.native_session_id, window_host_id = a.origin.window_host_id }
	local aq = a:apply("enrol", { record_id = "native", record_revision = 0, catalog_revision = 0, pane_binding = apane,
		orch_project_id = a:project("Refused enrollment", false), delivery = "native_ask" }); assert(aq.ok, aq.message)
	assert(a:finish(aq.action_id, "provisioned", PROVISIONED_W).ok)
	check(reject(a, worker_of(a, aq.worker_id).launch_action_id, { code = "target_unavailable", message = "Target pane is not an idle native agent in the exact window, session and host; nothing was sent" }).code == "bridge_rejected"
		and withdrawal(a, aq.worker_id).op == "enrol" and cancel(a, aq.worker_id).code == "withdrawal_retiring", "a refused enrollment ask retires its unused mailbox on cancel")
	-- A coordinator start releases its orchestrator slot once the unused mailbox retires.
	local co = fixture(); co:catalog(0)
	local coid = rejected_launch(co, true)
	local coowner = coordinator_owner(co)
	check(coowner.phase == "reserved" and coowner.managed_worker_id == coid, "the rejected coordinator start still holds the reserved slot")
	local coretire = cancel(co, coid)
	check(coretire.code == "withdrawal_retiring" and coordinator_owner(co) ~= nil, "the slot stays reserved until retirement is confirmed")
	check(co:finish(coretire.action_id, "retired", nil).ok and coordinator_owner(co) == nil and co.authority.registry.retired == nil,
		"confirmed retirement releases the never-bound coordinator reservation")
	check(co:queue(true).code == "task_queued" and state.rehydrate(clone(co.authority.registry)) ~= nil, "a new coordinator start takes the freed slot")
end
-- USAGE capacity consumer and quota routing (plan §7): pure normalization/assembly plus the real reducer.
do
	local quota = load("quota")
	local QNOW = 1800000000000
	local QJOIN = { namespace = "fixture-spawn", host_key = "fixture-host", config_revision = 0 }
	local A, B, C = string.rep("a", 64), string.rep("b", 64), string.rep("c", 64)
	local function q_windows(remaining_five, remaining_week, observed, weekly)
		return { { key = "five_hour", pool = "default", used = 100 - remaining_five, remaining = remaining_five, observed_at_ms = observed or QNOW - 60000, resets_at_ms = QNOW + 3600000 },
			{ key = "seven_day", pool = "default", used = 100 - remaining_week, remaining = remaining_week, observed_at_ms = observed or QNOW - 60000, resets_at_ms = weekly or QNOW + 86400000 } }
	end
	local function q_publication(source_id, account_id, opts)
		opts = opts or {}
		local reading_id, canonical = account_id .. "-reading", opts.canonical or ("claude:" .. account_id)
		return { protocol = 1, observer_device_id = source_id, subject_source_id = source_id, publisher = source_id .. ":host", epoch = "epoch-1", sequence = opts.sequence or 1,
			kind = "passive", generation = opts.generation or "gen-1", profile_generation = 3,
			snapshot = { version = 3, publisher = source_id .. ":host", as_of_ms = opts.as_of_ms or QNOW - 60000,
				readings = { { id = reading_id, provider = "claude", provider_label = "Claude", source_label = "Fixture", usage_source = "native-headless",
					canonical_id = canonical, windows = opts.windows or q_windows(70, 60) } },
				roster = { version = 1, scopes = { { id = source_id .. ":host:local", revision = "definition", spawn_join = opts.join or QJOIN, consumers = {},
					accounts = { { id = account_id, provider = "claude", provider_label = "Claude", account_label = "Same label everywhere",
						canonical_ids = { canonical }, reading_ids = { reading_id }, definition_revision = string.rep("d", 64),
						profile_binding = if opts.unbound then nil else { handle = "h-" .. account_id, generation = 2, canonical_ids = { canonical } } } } } } } } }
	end
	local function q_source(id, status, generation)
		return { source_id = id, generation = generation or "gen-1", profile_generation = 3, status = status or "current", last_received_ms = QNOW, clock_skew = false }
	end
	local function q_document(records, sources, extra)
		local doc = { version = 1, complete = true, incomplete = false, auth_revision = "auth-1", records = records, sources = sources, inventory = {},
			stale_after_ms = 900000, window_lease_ms = 900000, quota_unit = "percent", model_mapping = "unknown", current_source_id = "local-source" }
		for k, v in extra or {} do doc[k] = v end
		return doc
	end
	local function q_index(ids)
		local records = {}
		for _, id in ids do table.insert(records, { id = id, revision = 0 }) end
		return { namespace = QJOIN.namespace, host_key = QJOIN.host_key, config_revision = 0, records = records }
	end
	local function q_meta()
		return { revision = A, auth_revision = "auth-1", issued_at_ms = QNOW, expires_at_ms = QNOW + 120000, validation = { validated_at_ms = QNOW, expires_at_ms = QNOW + 120000 } }
	end
	local function q_entry(evidence, id) for _, r in evidence.records do if r.id == id then return r end end; return nil end
	local function q_normalize(doc, ids) return quota.normalize(doc, q_meta(), q_index(ids or { "native" }), QNOW) end
	local function q_reason(doc, id) return q_entry(q_normalize(doc, { id or "native" }), id or "native").reason end
	local function q_policy(extra)
		local p = { quota_routing = true, quota_reserve_pct = 10, quota_max_age_ms = 900000, initial_dispatch_records = {},
			initial_dispatch_provider = false, initial_dispatch_account = false, initial_dispatch_enabled = true }
		for k, v in extra or {} do p[k] = v end
		return p
	end

	if section == nil or section == "quota_normalize" then
		local evidence = q_normalize(q_document({ q_publication("remote-a", "native") }, { q_source("remote-a") }))
		local entry = q_entry(evidence, "native")
		do
			local policy = q_policy({ quota_max_age_ms = 0 })
			check(quota.assess(evidence, "native", 0, policy, QNOW).status == "sufficient", "disabled age override uses valid source freshness")
			local stale = clone(evidence); stale.records[1].observed_at_ms = QNOW - stale.stale_after_ms - 1
			check(quota.assess(stale, "native", 0, policy, QNOW).reason == "stale", "disabled age override still expires at source freshness")
			policy.quota_max_age_ms = 86400000
			check(quota.assess(stale, "native", 0, policy, QNOW).reason == "stale", "positive age override cannot bypass source freshness")
			local reset = clone(evidence); reset.records[1].reset_at_ms = QNOW - 1
			policy.quota_max_age_ms = 0
			check(quota.assess(reset, "native", 0, policy, QNOW).reason == "reset_passed", "disabled age override cannot bypass elapsed source reset")
		end
		check(entry.state == "known" and entry.remaining_pct == 60 and entry.weekly_reset_ms == QNOW + 86400000 and entry.reset_at_ms == QNOW + 3600000
			and entry.observed_at_ms == QNOW - 60000 and entry.windows == 2 and #entry.binding == 16 and #entry.principal == 16,
			"complete identity-bound evidence yields the lowest bound window, earliest weekly reset and binding digests")
		check(quota.valid_evidence(evidence) and evidence.revision == A and evidence.expires_at_ms == QNOW + 120000, "normalized evidence passes the host shape check")
		-- Partial evidence.
		local function with_windows(windows) return q_document({ q_publication("remote-a", "native", { windows = windows }) }, { q_source("remote-a") }) end
		check(q_reason(with_windows({ { key = "five_hour", pool = "default", observed_at_ms = QNOW - 60000, unavailable_reason = "local_login_unavailable" } })) == "unavailable",
			"an unavailable window is unknown, never zero or plenty")
		check(q_reason(with_windows({ { key = "five_hour", pool = "default", used = 10, remaining = 90, observed_at_ms = QNOW - 60000, last_known_reason = "local_login_unavailable" } })) == "unavailable",
			"last-known measurements carry no routing proof")
		check(q_reason(with_windows({})) == "no_windows", "a bound reading without windows is unknown")
		local missing = q_publication("remote-a", "native"); missing.snapshot.readings = {}
		check(q_reason(q_document({ missing }, { q_source("remote-a") })) == "reading_missing", "a missing bound reading is unknown")
		local foreign = q_publication("remote-a", "native"); foreign.snapshot.readings[1].canonical_id = "claude:someone-else"
		check(q_reason(q_document({ foreign }, { q_source("remote-a") })) == "identity_mismatch", "a reading outside the verified binding is unknown")
		-- Stale evidence.
		check(q_reason(with_windows(q_windows(70, 60, QNOW - 1000000))) == "stale", "observations older than USAGE's stale bound are unknown")
		check(q_reason(q_document({ q_publication("remote-a", "native") }, { q_source("remote-a", "stale") })) == "source_stale", "a stale source is unknown")
		check(q_reason(q_document({ q_publication("remote-a", "native") }, { q_source("remote-a", "offline") })) == "source_offline", "an offline source is unknown")
		check(q_reason(with_windows(q_windows(70, 60, QNOW + 120000))) == "future_timestamp", "future observations are unknown")
		check(q_reason(with_windows(q_windows(70, 60, nil, QNOW - 1))) == "reset_passed", "a passed reset needs fresh evidence, not an inferred refill")
		-- Revoked/changed proof.
		check(q_reason(q_document({ q_publication("remote-a", "native", { unbound = true }) }, { q_source("remote-a") })) == "binding_unverified",
			"USAGE dropping the profile binding (failed/revoked proof) is unknown")
		check(q_reason(q_document({ q_publication("remote-a", "native") }, { q_source("remote-a", "current", "gen-2") })) == "source_generation_changed",
			"a changed source/profile generation invalidates the published binding")
		check(q_reason(q_document({ q_publication("remote-a", "native") }, {})) == "source_missing", "a publication without its source status is unknown")
		-- Unbound evidence: exact join or nothing; labels never bind.
		check(q_reason(q_document({ q_publication("remote-a", "native", { join = { namespace = "fixture-spawn", host_key = "fixture-host", config_revision = 1 } }) }, { q_source("remote-a") })) == "unbound",
			"a different SPAWN config revision is not a binding")
		check(q_reason(q_document({ q_publication("remote-a", "other-record") }, { q_source("remote-a") })) == "unbound",
			"an account with the same labels but another record ID is not a binding")
		-- Duplicate publishers.
		check(q_reason(q_document({ q_publication("remote-a", "native"), q_publication("remote-b", "native") }, { q_source("remote-a"), q_source("remote-b") })) == "ambiguous",
			"two distinct bindings for one record are ambiguous")
		local newer = q_publication("remote-a", "native", { sequence = 2, windows = { { key = "five_hour", pool = "default", used = 80, remaining = 20, observed_at_ms = QNOW - 30000, resets_at_ms = QNOW + 3600000 },
			q_windows(70, 60)[2] } })
		local merged = q_entry(q_normalize(q_document({ q_publication("remote-a", "native"), newer }, { q_source("remote-a") })), "native")
		check(merged.state == "known" and merged.remaining_pct == 20, "duplicate views use the newest observation per window/pool, never a sum")
		local disagreeing = q_publication("remote-a", "native", { sequence = 2, windows = q_windows(50, 60) })
		check(q_reason(q_document({ q_publication("remote-a", "native"), disagreeing }, { q_source("remote-a") })) == "conflict", "equally fresh disagreeing observations are a conflict")
		-- Local publications must agree with USAGE's current local roster.
		local roster = { version = 1, scopes = { { id = "local-source:host:local", spawn_join = QJOIN, accounts = { { id = "native", definition_revision = string.rep("d", 64),
			profile_binding = { handle = "h-native", generation = 2, canonical_ids = { "claude:native" } } } } } } }
		check(q_reason(q_document({ q_publication("local-source", "native") }, { q_source("local-source") })) == "local_roster_changed", "local evidence without the current roster is unknown")
		check(q_entry(q_normalize(q_document({ q_publication("local-source", "native") }, { q_source("local-source") }, { current_roster = roster })), "native").state == "known",
			"local evidence matching the current roster is bound")
		roster.scopes[1].accounts[1].profile_binding.generation = 3
		check(q_reason(q_document({ q_publication("local-source", "native") }, { q_source("local-source") }, { current_roster = roster })) == "local_roster_changed",
			"a rebound local profile invalidates the published binding")
		-- OMP consumers route on their single associated account; direct accounts are unchanged.
		local function q_consumer(source_id, account_ids)
			local pub = q_publication(source_id, "native")
			pub.snapshot.roster.scopes[1].consumers = { { id = "omp-worker", label = "OMP worker", reading_ids = {}, definition_revision = string.rep("e", 64), account_ids = account_ids } }
			return pub
		end
		local associated = q_normalize(q_document({ q_consumer("remote-a", { "native" }) }, { q_source("remote-a") }), { "omp-worker", "native" })
		local direct = q_entry(associated, "native")
		check(q_entry(associated, "omp-worker").state == "known" and q_entry(associated, "omp-worker").remaining_pct == 60
			and q_entry(associated, "omp-worker").binding == direct.binding and direct.state == "known" and direct.remaining_pct == 60,
			"an associated OMP consumer routes on its account's quota and the direct account is unchanged")
		check(q_reason(q_document({ q_consumer("remote-a", nil) }, { q_source("remote-a") }), "omp-worker") == "consumer_unassociated"
			and quota.REASONS.consumer_unassociated:find("Associate OMP records", 1, true) ~= nil,
			"an OMP consumer without an account association is unbound and points at USAGE Setup")
		check(q_reason(q_document({ q_consumer("remote-a", { "other-account" }) }, { q_source("remote-a") }), "omp-worker") == "consumer_unassociated",
			"an association to an account outside the scope is not a binding")
		roster.scopes[1].accounts[1].profile_binding.generation = 2
		roster.scopes[1].consumers = { { id = "omp-worker", definition_revision = string.rep("e", 64), account_ids = { "native" } } }
		check(q_entry(q_normalize(q_document({ q_consumer("local-source", { "native" }) }, { q_source("local-source") }, { current_roster = roster }), { "omp-worker" }), "omp-worker").state == "known",
			"a local consumer matching the current roster is bound")
		roster.scopes[1].consumers[1].definition_revision = string.rep("f", 64)
		check(q_reason(q_document({ q_consumer("local-source", { "native" }) }, { q_source("local-source") }, { current_roster = roster }), "omp-worker") == "local_roster_changed",
			"a changed current consumer definition fails closed")
		roster.scopes[1].consumers[1] = { id = "omp-worker", definition_revision = string.rep("e", 64) }
		check(q_reason(q_document({ q_consumer("local-source", { "native" }) }, { q_source("local-source") }, { current_roster = roster }), "omp-worker") == "local_roster_changed",
			"a current roster that dropped the association fails closed")
		roster.scopes[1].consumers = nil; roster.scopes[1].accounts[1].profile_binding.generation = 3
		check(q_reason(q_document({ q_publication("remote-a", "native") }, { q_source("remote-a") }, { quota_unit = "tokens" })) == "unit_unknown", "unknown quota units are unknown")
		-- Host assessment and its exact reserve boundary.
		local p = q_policy()
		check(quota.assess(evidence, "native", 0, p, QNOW).status == "sufficient", "60% remaining is above a 10% reserve")
		check(quota.assess(evidence, "native", 0, q_policy({ quota_reserve_pct = 60 }), QNOW).reason == "below_reserve", "remaining equal to the reserve is not sufficient")
		check(quota.assess(evidence, "native", 0, q_policy({ quota_reserve_pct = 59 }), QNOW).status == "sufficient", "one point above the reserve is sufficient")
		check(quota.assess(evidence, "native", 0, p, QNOW + 120000).reason == "evidence_expired", "an expired USAGE lease is unknown")
		check(quota.assess(evidence, "native", 0, q_policy({ quota_max_age_ms = 60000 }), QNOW + 1).reason == "stale", "Config's maximum evidence age applies")
		check(quota.assess(evidence, "native", 1, p, QNOW).reason == "not_in_evidence" and quota.assess(nil, "native", 0, p, QNOW).reason == "no_evidence",
			"another record revision or no evidence is unknown")
		local forged = clone(evidence); forged.records[1].reason = "unbound"
		check(not quota.valid_evidence(forged), "known evidence cannot also carry an unknown reason")
		forged = clone(evidence); forged.records[1] = { id = "native", revision = 0, state = "unknown", reason = "made_up" }
		check(not quota.valid_evidence(forged), "unknown reasons are typed")
		forged = clone(evidence); forged.records[1].binding = nil
		check(not quota.valid_evidence(forged), "known evidence requires its binding digest")
	end

	if section == nil or section == "quota_assembly" then
		local raw = runtime.json.encode(q_document({ q_publication("remote-a", "native") }, { q_source("remote-a") }))
		local revision = codec.sha256(raw)
		local half = math.floor(#raw / 2) -- ASCII fixture: any split is a UTF-8 boundary.
		local function page(request_id, op, index, data, extra)
			local r = { version = 1, request_id = request_id, op = op, ok = true, status = "ok", revision = revision, auth_revision = "auth-1",
				issued_at_ms = QNOW, expires_at_ms = QNOW + 120000, index = index, count = 2, size = #raw, data = data,
				next_cursor = if index == 0 then "cursor-1" else nil, complete = index == 1, incomplete = false }
			for k, v in extra or {} do r[k] = v end
			return quota.PREFIX .. runtime.json.encode(r)
		end
		local native_frame = page("r1", "snapshot", 0, raw:sub(1, half))
		local raw_body = native_frame:sub(#quota.PREFIX + 1)
		local carrier_page = assert(quota.decode_response_json(raw_body, { request_id = "r1", op = "snapshot" }))
		local native_page = assert(quota.decode_response(native_frame, { request_id = "r1", op = "snapshot" }))
		check(quota.canonical(carrier_page) == quota.canonical(native_page) and carrier_page.data == raw:sub(1, half),
			"pane-free JSON and real native framing consume the same exact capacity evidence")
		local uncorrelated, issue = quota.decode_response_json(raw_body, { request_id = "other", op = "snapshot" })
		check(uncorrelated == nil and issue.code == "uncorrelated", "raw carrier bodies retain the original correlation fence")
		check(quota.decode_response_json(native_frame, { request_id = "r1", op = "snapshot" }) == nil,
			"the JSON carrier never accepts a fabricated native-frame wrapper")
		local function assemble(second_data, extra)
			local first = assert(quota.decode_response(page("r1", "snapshot", 0, raw:sub(1, half), extra), { request_id = "r1", op = "snapshot" }))
			local a = assert(quota.assembly(first))
			local second = assert(quota.decode_response(page("r2", "page", 1, second_data, extra), { request_id = "r2", op = "page", revision = revision }))
			assert(quota.add_page(a, second))
			return a
		end
		-- Hash in bounded steps, as the window does across ticks; returns the number of steps.
		local function hashed(a, blocks)
			local steps = 0
			repeat steps += 1; local done, failure = quota.hash_step(a, blocks); assert(failure == nil, "unexpected hash failure") until done
			return steps
		end
		local unhashed = assemble(raw:sub(half + 1))
		local value, problem = quota.finish(unhashed)
		check(value == nil and problem.code == "hash_pending", "an assembly is never parsed before its bytes are hashed")
		local blocks = math.floor(#raw / 64)
		check(hashed(unhashed, 1) >= blocks and quota.HASH_BLOCKS_PER_STEP * 64 <= 16384, "hashing resumes in bounded steps of at most 16 KiB")
		local document = quota.finish(unhashed)
		check(document and document.records[1].subject_source_id == "remote-a" and document.quota_unit == "percent", "complete in-order pages verify and parse")
		for _, text in { "", "a", string.rep("b", 63), string.rep("c", 64), string.rep("d", 65), string.rep("e", 200) } do
			for _, cut in { 0, 1, 63, 64, 65 } do
				local state = codec.sha256_begin()
				codec.sha256_feed(state, text:sub(1, cut)); codec.sha256_step(state, 1)
				codec.sha256_feed(state, text:sub(cut + 1))
				repeat until codec.sha256_step(state, 1)
				assert(codec.sha256_digest(state) == codec.sha256(text), "incremental SHA-256 differs for " .. #text .. "/" .. cut)
			end
		end
		check(true, "incremental SHA-256 equals the one-shot digest across block and page boundaries")
		local interrupted = assemble(raw:sub(half + 1)); interrupted.hash.busy = true -- A step aborted mid-callback.
		local done, failure = quota.hash_step(interrupted)
		value, problem = quota.finish(interrupted)
		check(not done and failure.code == "hash_interrupted" and value == nil and problem.code == "hash_interrupted", "an interrupted hashing step fails closed instead of yielding evidence")
		local reversed = assemble(raw:sub(half + 1):reverse()); hashed(reversed)
		value, problem = quota.finish(reversed)
		check(value == nil and problem.code == "integrity_mismatch", "pages that do not hash to the revision are rejected before parsing")
		local oversized = assemble(raw:sub(half + 1), { size = #raw + 1 }); hashed(oversized)
		value, problem = quota.finish(oversized)
		check(value == nil and problem.code == "size_mismatch", "a byte length different from the declared size is rejected")
		local first = assert(quota.decode_response(page("r1", "snapshot", 0, raw:sub(1, half)), { request_id = "r1", op = "snapshot" }))
		local a = assert(quota.assembly(first))
		local ok, diagnostic = quota.add_page(a, first)
		check(not ok and diagnostic.code == "page_mismatch", "a repeated or out-of-order page is rejected")
		value, problem = quota.finish(a)
		check(value == nil and problem.code == "incomplete", "an incomplete assembly never yields evidence")
		local foreign = assert(quota.decode_response(page("r3", "page", 1, raw:sub(half + 1), { revision = string.rep("e", 64) }), { request_id = "r3", op = "page" }))
		ok, diagnostic = quota.add_page(a, foreign)
		check(not ok and diagnostic.code == "page_mismatch", "a page of another revision cannot join the assembly")
		value, problem = quota.assembly(assert(quota.decode_response(page("r1", "snapshot", 0, raw:sub(1, half), { size = quota.MAX_DOCUMENT_BYTES + 1 }), { request_id = "r1", op = "snapshot" })))
		check(value == nil and problem.code == "too_large", "documents above the consumer bound are refused, never truncated")
		value, problem = quota.decode_response(page("other", "snapshot", 0, raw:sub(1, half)), { request_id = "r1", op = "snapshot" })
		check(value == nil and problem.code == "uncorrelated", "a response to another request is not consumed")
		value, problem = quota.decode_response(quota.PREFIX .. runtime.json.encode({ version = 1, request_id = "r1", op = "snapshot", ok = false, status = "pending" }), { request_id = "r1", op = "snapshot" })
		check(value == nil and problem.code == "pending", "pending is a wait state")
		value, problem = quota.decode_response(quota.PREFIX .. runtime.json.encode({ version = 1, request_id = "r1", op = "validate", ok = false, status = "export_revoked", message = "revoked" }),
			{ request_id = "r1", op = "validate", revision = revision })
		check(value == nil and problem.code == "export_revoked", "revocation is a typed refusal")
		value, problem = quota.decode_response(page("r1", "snapshot", 0, raw:sub(1, half), { complete = true }), { request_id = "r1", op = "snapshot" })
		check(value == nil and problem.code == "invalid_response", "inconsistent page flags are rejected")
		value, problem = quota.decode_response("SPAWN_DISPATCH v1 {}", { request_id = "r1", op = "snapshot" })
		check(value == nil and problem.code == "incompatible", "only USAGE_CAPACITY v1 framing is read")
		local current = { version = 1, request_id = "r4", op = "validate", ok = true, status = "current", revision = revision, auth_revision = "auth-1", validated_at_ms = QNOW, expires_at_ms = QNOW + 120000 }
		check(quota.decode_response(quota.PREFIX .. runtime.json.encode(current), { request_id = "r4", op = "validate", revision = revision }) ~= nil, "a current validation decodes")
		value, problem = quota.decode_response(quota.PREFIX .. runtime.json.encode(current), { request_id = "r4", op = "validate", revision = string.rep("e", 64) })
		check(value == nil and problem.code == "invalid_response", "a validation of another revision is rejected")
		check(quota.request("configure", "r5") == nil and quota.request("page", "r5", revision, nil) == nil and quota.request("snapshot", "bad id") == nil,
			"only bounded read operations with opaque IDs and cursors are formed")
		check(runtime.json.decode(assert(quota.request("page", "r5", revision, "cursor-1"))).cursor == "cursor-1", "page requests carry the revision-bound cursor")
	end

	local function q_row(id, provider, account, model)
		return { id = id, revision = 0, provider = provider, account_label = account, model_variant = model, backend = "native-agent", enabled = true, eligible = true,
			capabilities = runtime.json.array({ "report-files-v1", "native-ask-v1", "coordinator-control-v1", "project-start-v1" }), unsupported = runtime.json.array(), cwd = "/fixture", placement = "split" }
	end
	local function q_known(id, remaining, weekly, principal)
		return { id = id, revision = 0, state = "known", remaining_pct = remaining, observed_at_ms = QNOW - 60000, reset_at_ms = QNOW + 3600000,
			weekly_reset_ms = weekly or QNOW + 86400000, windows = 2, binding = string.rep("b", 16), principal = principal or string.rep("c", 16) }
	end
	local function q_unknown(id, reason) return { id = id, revision = 0, state = "unknown", reason = reason } end
	local function q_evidence(records, revision)
		return { version = 1, revision = revision or A, auth_revision = "auth-1", issued_at_ms = QNOW, expires_at_ms = QNOW + 120000, validated_at_ms = QNOW,
			namespace = QJOIN.namespace, host_key = QJOIN.host_key, config_revision = 0, stale_after_ms = 900000, records = records }
	end
	local function q_fixture(clock)
		local f = fixture(function() return if clock then clone(clock) else { now_ms = QNOW } end)
		local r = f:apply("catalog")
		assert(f:finish(r.action_id, "catalog", { catalog_version = 2, setup = catalog_setup(0), namespace = QJOIN.namespace, host_key = QJOIN.host_key, config_revision = 0, revision = 0, records = runtime.json.array({
			q_row("native", "omp", "Work", "m1"), q_row("alt-same", "omp", "Work", "m1"), q_row("alt-early", "omp", "Work", "m1"),
			q_row("alt-model", "omp", "Other account", "m2"), q_row("alt-provider", "other", "Work", "m1") }) }).ok)
		assert(f:apply("policy", { policy = { initial_dispatch_enabled = true, worker_rollover_enabled = true, coordinator_rollover_enabled = true } }).ok)
		return f
	end
	local function q_queue(f, preserve_checkout_gate)
		local queued = f:apply("queue", { record_id = "native", record_revision = 0, catalog_revision = 0,
			prompt = "Quota fixture task", cwd = "/fixture", placement = "split", coordinator = false })
		return if preserve_checkout_gate then queued else f:allow_shared_fixture(queued)
	end
	local function q_outcome(answer) return answer.launch or answer.code end
	local function q_worker(f, id) return f.authority.registry.dispatch.workers[id] end
	local function q_actions(f, id) local n = 0; for _, a in f.authority.registry.dispatch.actions do if a.worker_id == id then n += 1 end end; return n end
	local function q_capacity(f, records, revision) return f:apply("capacity", { capacity = q_evidence(records, revision) }) end
	local function q_gate(f, id)
		for _, g in f.authority.registry.dispatch.gates or {} do if g.worker_id == id and g.kind == "quota_fallback" and g.phase == "pending" then return g end end
		return nil
	end
	local PROVISIONED = { handle = "mailbox-fixture", binding_digest = A, capabilities = runtime.json.array({ "report-files-v1", "native-ask-v1", "coordinator-control-v1", "project-start-v1" }), limits = {} }

	if section == nil or section == "quota_routing" then
		do
			local disabled = q_fixture()
			assert(disabled:apply("policy", { policy = { quota_routing = true, initial_dispatch_enabled = false, initial_dispatch_records = { "alt-same" } } }).ok)
			assert(q_capacity(disabled, { q_known("native", 0), q_known("alt-same", 80) }).ok)
			local work = q_queue(disabled)
			check(work.code == "task_held" and q_gate(disabled, work.worker_id) == nil and q_actions(disabled, work.worker_id) == 0, "disabled starting-work allowance cannot select or propose an allowlisted alternative")
		end
		-- Off: exactly today's explicit selection, whatever USAGE says.
		local off = q_fixture()
		check(q_capacity(off, { q_known("native", 0) }).code == "capacity_recorded", "evidence can be recorded while routing is off")
		local queued = q_queue(off)
		check(queued.code == "task_queued" and queued.action_id ~= nil and q_worker(off, queued.worker_id).routing == nil and q_worker(off, queued.worker_id).record_id == "native",
			"quota_routing off keeps the explicit selection even with exhausted evidence")
		-- On: the owner-selected record launches unchanged when sufficient.
		local f = q_fixture()
		assert(f:apply("policy", { policy = { quota_routing = true, initial_dispatch_records = { "alt-same", "alt-early" } } }).ok)
		check(f.authority.registry.dispatch.policies[f.origin.logical_session_id].initial_dispatch_records[1] == "alt-early", "the allowlist is stored canonically")
		check(f:apply("policy", { policy = { initial_dispatch_records = { "*" } } }).code == "invalid_policy", "wildcard allowlist entries are rejected")
		check(f:apply("policy", { policy = { initial_dispatch_records = { "alt-same", "alt-same" } } }).code == "invalid_policy", "duplicate allowlist entries are rejected")
		assert(q_capacity(f, { q_known("native", 11), q_known("alt-same", 90), q_known("alt-early", 90) }).ok)
		queued = q_queue(f)
		local w = q_worker(f, queued.worker_id)
		check(queued.code == "task_queued" and w.record_id == "native" and w.routing.phase == "selected" and w.routing.authority == "requested_sufficient"
			and not w.routing.switched and w.routing.evidence_revision == A and f:action(queued.action_id).request.record_id == "native",
			"a sufficient owner-selected record (11% > 10% reserve) is preferred over alternatives")
		-- At the reserve: allowlisted alternatives ordered by earlier weekly reset, then record ID.
		assert(q_capacity(f, { q_known("native", 10), q_known("alt-same", 90, QNOW + 3600000 * 2), q_known("alt-early", 90, QNOW + 86400000) }, B).ok)
		queued = q_queue(f)
		w = q_worker(f, queued.worker_id)
		check(w.record_id == "alt-same" and w.routing.switched and w.routing.authority == "policy" and w.routing.needs == nil and w.routing.requested.id == "native"
			and w.routing.reason.code == "policy_substitution" and f:action(queued.action_id).request.record_id == "alt-same",
			"at the reserve boundary the alternative with the earlier weekly reset is selected without needing a permission")
		assert(q_capacity(f, { q_known("native", 0), q_known("alt-same", 90), q_known("alt-early", 90) }, C).ok)
		queued = q_queue(f)
		check(q_worker(f, queued.worker_id).record_id == "alt-early", "equal weekly resets fall back to the stable record-ID order")
		-- Removing a record from the allowlist voids its unlaunched policy substitution.
		assert(f:apply("policy", { policy = { initial_dispatch_records = {} } }).ok)
		check(q_worker(f, queued.worker_id).routing.phase == "held" and q_worker(f, queued.worker_id).routing.reason.code == "policy_changed",
			"a provisioned substitution no longer allowed by Config is held, never launched")
		-- Nothing allowed is sufficient: held, never provisioned; fresh evidence re-evaluates it.
		assert(q_capacity(f, { q_unknown("native", "unbound"), q_known("alt-same", 90) }, string.rep("d", 64)).ok)
		queued = q_queue(f)
		w = q_worker(f, queued.worker_id)
		check(q_outcome(queued) == "task_held" and queued.action_id == nil and q_actions(f, queued.worker_id) == 0 and w.routing.phase == "held"
			and w.routing.reason.code == "quota_unknown" and w.phase == "queued", "unbound evidence holds the work without provisioning or substitution")
		assert(q_capacity(f, { q_known("native", 50) }, string.rep("e", 64)).ok)
		w = q_worker(f, queued.worker_id)
		check(w.routing.phase == "selected" and w.routing.evidence_revision == string.rep("e", 64) and q_actions(f, queued.worker_id) == 1 and w.record_id == "native",
			"fresh sufficient evidence releases held work through the normal provisioning path")
		-- Missing or expired evidence holds.
		local clock = { now_ms = QNOW }
		local g = q_fixture(clock)
		assert(g:apply("policy", { policy = { quota_routing = true } }).ok)
		local held = q_queue(g)
		check(held.code == "task_held" and q_worker(g, held.worker_id).routing.candidates[1].reason == "no_evidence", "no USAGE evidence is never plenty")
		assert(q_capacity(g, { q_known("native", 80) }).ok)
		clock.now_ms = QNOW + 120000
		local expired = q_queue(g)
		check(q_outcome(expired) == "task_held" and q_worker(g, expired.worker_id).routing.candidates[1].reason == "evidence_expired", "an expired USAGE lease holds new work")
		-- Owner can withdraw held work; a known unissued provisioned launch retires its unused mailbox.
		check(g:apply("cancel_work", { worker_id = expired.worker_id }).code == "work_cancelled" and q_worker(g, expired.worker_id) == nil, "held unprovisioned work can be cancelled")
		local provision = actions_of(f, queued.worker_id, "mailbox_provision")[1]
		assert(f:finish(provision, "provisioned", PROVISIONED).ok)
		local withdrawn = f:apply("cancel_work", { worker_id = queued.worker_id })
		check(withdrawn.code == "withdrawal_retiring" and q_worker(f, queued.worker_id).mailbox_handle ~= nil
			and f:action(withdrawn.action_id).request.op == "mailbox_retire",
			"withdrawing an unissued routed launch retains and explicitly retires its already-provisioned mailbox")
		-- Restore keeps decisions and drops the evidence lease.
		local restored = assert(state.rehydrate(clone(f.authority.registry)))
		check(restored.dispatch.capacity == nil and restored.dispatch.workers[queued.worker_id].routing.phase == "selected", "restore keeps routing decisions and requires fresh evidence")
		check(dispatch.valid(f.authority.registry.dispatch, f.authority.registry), "routed state passes strict validation")
	end

	if section == nil or section == "quota_gate" then
		-- A sufficient alternative whose account change Config does not permit becomes an owner gate.
		local f = q_fixture()
		assert(f:apply("policy", { policy = { quota_routing = true, initial_dispatch_records = { "alt-model" } } }).ok)
		assert(q_capacity(f, { q_known("native", 0), q_known("alt-model", 80) }).ok)
		local queued = q_queue(f)
		local w = q_worker(f, queued.worker_id)
		local gate = q_gate(f, queued.worker_id)
		check(queued.code == "task_gated" and q_actions(f, queued.worker_id) == 0 and w.routing.phase == "gated" and w.routing.gate.denied == "account"
			and gate ~= nil and w.routing.gate.gate_id == gate.id and w.routing.gate.to.id == "alt-model" and w.routing.gate.from.id == "native" and w.routing.gate.evidence_revision == A,
			"a denied account fallback is a durable gate bound to the exact tuples and evidence, with nothing provisioned")
		local listed = false
		for _, item in gate.evidence do if item == "denied:account" then listed = true end end
		check(listed, "the gate records the denied permission as evidence")
		local pending_state = clone(f.authority.registry)
		check(dispatch.valid(pending_state.dispatch, pending_state), "the pending fallback gate state is valid")
		do
			local raw = clone(pending_state)
			raw.version = 4; raw.dispatch.projects = nil; raw.dispatch.finished_projects = nil
			raw.installation_defaults.policy.auto_start_projects = nil; raw.installation_defaults.policy.auto_launch_intake = false
			for _, p in raw.dispatch.policies do p.auto_start_projects = nil; p.auto_launch_intake = false end
			for _, worker in raw.dispatch.workers do worker.orch_project_id = nil; worker.presentation = nil; worker.selected_record = nil end
			local restored, info = state.rehydrate(raw); must(restored, info)
			local migrated = fixture(function() return { now_ms = QNOW } end)
			migrated.origin = clone(f.origin); migrated.authority.registry = restored; migrated.memory.value = clone(restored)
			assert(migrated:apply("continue_controller", { operator_verified = true }).ok)
			assert(migrated:control("reconcile_session").ok)
			local before = clone(q_worker(migrated, queued.worker_id).routing)
			local project = migrated.authority.registry.dispatch.projects[q_worker(migrated, queued.worker_id).orch_project_id]
			local started = migrated:apply("project_start", { orch_project_id = project.orch_project_id, project_revision = project.revision })
			check(started.ok and q_actions(migrated, queued.worker_id) == 0
				and runtime.json.encode(q_worker(migrated, queued.worker_id).routing) == runtime.json.encode(before)
				and migrated.authority.registry.dispatch.gates[gate.id] ~= nil,
				"v4 START preserves the existing exact model-fallback decision instead of replacing routing and orphaning its owner gate")
			check(state.rehydrate(clone(migrated.authority.registry)) ~= nil, "migrated quota gate and retained routing restore together")
		end
		check(f:apply("answer", { gate_id = gate.id, gate_revision = gate.revision, choice_id = "approve", answer = "Approve alt-model" }).code == "fallback_approved", "owner approval is accepted")
		w = q_worker(f, queued.worker_id)
		check(w.record_id == "alt-model" and w.routing.phase == "selected" and w.routing.authority == "owner_gate" and w.routing.needs == "account"
			and f.authority.registry.dispatch.gates[gate.id] == nil and q_actions(f, queued.worker_id) == 1
			and f.authority.registry.dispatch.policies[f.origin.logical_session_id].initial_dispatch_account == false,
			"approval provisions that work only on the destination and never edits Config")
		check(dispatch.valid(f.authority.registry.dispatch, f.authority.registry), "resolved fallback gate state is valid")
		-- Reject keeps the work held.
		local r = q_fixture()
		assert(r:apply("policy", { policy = { quota_routing = true, initial_dispatch_records = { "alt-model" } } }).ok)
		assert(q_capacity(r, { q_known("native", 0), q_known("alt-model", 80) }).ok)
		queued = q_queue(r); gate = q_gate(r, queued.worker_id)
		check(r:apply("answer", { gate_id = gate.id, gate_revision = gate.revision, choice_id = "reject", answer = "Reject" }).code == "fallback_rejected"
			and q_worker(r, queued.worker_id).routing.phase == "held" and q_actions(r, queued.worker_id) == 0, "rejection holds the work with nothing launched")
		-- Same proposal on newer evidence keeps the gate; a routing-policy edit voids it.
		local s = q_fixture()
		assert(s:apply("policy", { policy = { quota_routing = true, initial_dispatch_records = { "alt-model" } } }).ok)
		assert(q_capacity(s, { q_known("native", 0), q_known("alt-model", 80) }).ok)
		queued = q_queue(s); gate = q_gate(s, queued.worker_id)
		assert(q_capacity(s, { q_known("native", 0), q_known("alt-model", 70) }, B).ok)
		check(q_gate(s, queued.worker_id).id == gate.id and q_worker(s, queued.worker_id).routing.gate.evidence_revision == B, "newer evidence for the same proposal keeps the question stable")
		assert(s:apply("policy", { policy = { quota_reserve_pct = 20 } }).ok)
		local replacement = q_gate(s, queued.worker_id)
		check(replacement ~= nil and replacement.id ~= gate.id and s.authority.registry.dispatch.gates[gate.id] == nil, "a routing-policy edit replaces and reclaims the obsolete gate")
		check(not s:apply("answer", { gate_id = gate.id, gate_revision = gate.revision, choice_id = "approve", answer = "Approve" }).ok, "a superseded fallback cannot be approved")
		assert(s:apply("policy", { policy = { initial_dispatch_account = true } }).ok)
		local w2 = q_worker(s, queued.worker_id)
		check(w2.routing.phase == "selected" and w2.routing.authority == "policy" and w2.record_id == "alt-model" and s.authority.registry.dispatch.gates[replacement.id] == nil,
			"granting the permission selects the alternative by policy and closes the gate")
		-- Unknown requested identity: any alternative is an account change.
		local u = q_fixture()
		assert(u:apply("policy", { policy = { quota_routing = true, initial_dispatch_records = { "alt-same" } } }).ok)
		assert(q_capacity(u, { q_unknown("native", "binding_unverified"), q_known("alt-same", 90) }).ok)
		queued = q_queue(u)
		check(queued.code == "task_gated" and q_worker(u, queued.worker_id).routing.gate.denied == "account", "equal labels never prove the same account when the selected record is unbound")
		local p = q_fixture()
		assert(p:apply("policy", { policy = { quota_routing = true, initial_dispatch_records = { "alt-provider" }, initial_dispatch_account = true } }).ok)
		assert(q_capacity(p, { q_known("native", 0), q_known("alt-provider", 90) }).ok)
		queued = q_queue(p)
		check(queued.code == "task_gated" and q_worker(p, queued.worker_id).routing.gate.denied == "provider", "a provider switch without provider permission is gated")
		-- Approval binds the evidence revision: an expired lease refuses it.
		local clock = { now_ms = QNOW }
		local e = q_fixture(clock)
		assert(e:apply("policy", { policy = { quota_routing = true, initial_dispatch_records = { "alt-model" } } }).ok)
		assert(q_capacity(e, { q_known("native", 0), q_known("alt-model", 80) }).ok)
		queued = q_queue(e); gate = q_gate(e, queued.worker_id)
		clock.now_ms = QNOW + 120000
		check(e:apply("answer", { gate_id = gate.id, gate_revision = gate.revision, choice_id = "approve", answer = "Approve" }).code == "stale_gate"
			and q_actions(e, queued.worker_id) == 0, "approval on expired evidence is refused; nothing is provisioned")
	end

	if section == nil or section == "quota_claim" then
		local f = q_fixture()
		assert(f:apply("policy", { policy = { quota_routing = true } }).ok)
		assert(q_capacity(f, { q_known("native", 60) }).ok)
		local queued = q_queue(f)
		assert(f:finish(queued.action_id, "provisioned", PROVISIONED).ok)
		local w = q_worker(f, queued.worker_id)
		local launch = w.launch_action_id
		local function claim(validation) return f:apply("claim", { action_id = launch, executor = f.origin.window_epoch, capacity_validation = validation }) end
		local function validation(extra)
			local v = { revision = A, auth_revision = "auth-1", status = "current", validated_at_ms = QNOW, expires_at_ms = QNOW + 60000 }
			for k, value in extra or {} do v[k] = value end
			return v
		end
		check(claim(nil).code == "capacity_refresh_required" and f:action(launch).phase == "ready", "a routed launch is never claimed without USAGE re-validation")
		check(claim(validation({ revision = B })).code == "capacity_refresh_required", "validation of another revision cannot authorize the claim")
		check(claim(validation({ validated_at_ms = QNOW - 31000 })).code == "capacity_refresh_required", "a validation older than 30 s is not immediately before the claim")
		check(claim(validation({ expires_at_ms = QNOW })).code == "capacity_refresh_required", "an expired validation cannot authorize the claim")
		check(claim(validation({ auth_revision = "auth-2" })).code == "capacity_refresh_required", "a changed USAGE authorization cannot authorize the claim")
		check(claim(validation({ status = "evidence_changed" })).code == "capacity_refresh_required", "only a current validation authorizes the claim")
		-- Changed evidence: re-evaluate the provisioned record and rebind; the old revision no longer claims.
		assert(q_capacity(f, { q_known("native", 55) }, B).ok)
		w = q_worker(f, queued.worker_id)
		check(w.routing.phase == "selected" and w.routing.evidence_revision == B and claim(validation()).code == "capacity_refresh_required",
			"refreshed evidence rebinds the decision and fences the old revision")
		-- Exhausted after provisioning: held, record unchanged, no claim even with a current validation.
		assert(q_capacity(f, { q_known("native", 0) }, C).ok)
		w = q_worker(f, queued.worker_id)
		check(w.routing.phase == "held" and w.record_id == "native" and claim(validation({ revision = C })).code == "routing_held",
			"a provisioned record that lost quota is held, never switched or launched")
		assert(q_capacity(f, { q_known("native", 55) }, B).ok)
		local claimed = claim(validation({ revision = B }))
		check(claimed.ok and f:action(launch).phase == "claimed" and f:action(launch).claim.capacity.revision == B and f:action(launch).claim.capacity.validated_at_ms == QNOW,
			"a current validation of the bound revision claims and is recorded on the durable claim")
		check(state.rehydrate(clone(f.authority.registry)) ~= nil, "a claim bound to capacity evidence restores")
		-- SPAWN's window authorizes only a scoped action whose claim is exactly the bridge contract
		-- `{executor,epoch,grant_id}`; the bound USAGE validation stays host-side. Live defect: the
		-- projected claim carried `capacity`, so every routed launch's window challenge expired unconsumed.
		local projection = state.project(f.authority.registry)
		projection.dispatch = dispatch.project(f.authority.registry, f.origin.logical_session_id, f.origin.alias_nonce)
		local rendered = load("views").render({ pane = 42, alias_nonce = f.origin.alias_nonce, orch_session_id = f.origin.logical_session_id,
			action_serial = 0, actions = {} }, projection, "ready")
		local scoped_node = assert(role_node(rendered, "orchplus.dispatch", "dispatch-action-" .. launch), "the routed launch has its scoped action node")
		local scoped_span = scoped_node.p.spans[1]
		local scoped = runtime.json.decode(if type(scoped_span) == "string" then scoped_span else scoped_span.t)
		local claim_keys = {}
		for key in scoped.action.claim do table.insert(claim_keys, key) end
		table.sort(claim_keys)
		check(scoped.action.phase == "claimed" and table.concat(claim_keys, ",") == "epoch,executor,grant_id"
			and scoped.action.claim.grant_id == f:action(launch).claim.grant_id and f:action(launch).claim.capacity ~= nil,
			"a routed launch's claim reaches SPAWN as exactly {executor,epoch,grant_id}; capacity evidence stays on the durable claim")
		-- Turning routing off re-evaluates as explicit selection: an unsubstituted record claims without USAGE.
		local o = q_fixture()
		assert(o:apply("policy", { policy = { quota_routing = true } }).ok)
		assert(q_capacity(o, { q_known("native", 60) }).ok)
		queued = q_queue(o)
		assert(o:finish(queued.action_id, "provisioned", PROVISIONED).ok)
		assert(o:apply("policy", { policy = { quota_routing = false } }).ok)
		w = q_worker(o, queued.worker_id)
		check(w.routing.mode == "explicit" and w.routing.phase == "selected"
			and o:apply("claim", { action_id = w.launch_action_id, executor = o.origin.window_epoch }).ok, "with routing off, the owner-selected record launches exactly as before")
	end

	-- Accepted unrouted worker plus the multi-record routing catalog; epoch clock for liveness.
	local function q_catalog(f)
		local r = f:apply("catalog")
		assert(f:finish(r.action_id, "catalog", { catalog_version = 2, setup = catalog_setup(0), namespace = QJOIN.namespace, host_key = QJOIN.host_key, config_revision = 0, revision = 0, records = runtime.json.array({
			q_row("native", "omp", "Work", "m1"), q_row("alt-same", "omp", "Work", "m1"), q_row("alt-early", "omp", "Work", "m1"),
			q_row("alt-model", "omp", "Other account", "m2"), q_row("alt-provider", "other", "Work", "m1") }) }).ok)
	end
	local function q_rollover_fixture()
		local clock = { now_ms = QNOW, mono_ms = 1000, epoch = "quota-rollover" }
		local f = fixture(function() return clone(clock) end)
		local id = f:accepted(false)
		q_catalog(f)
		assert(f:apply("observe", { worker_id = id, pane_binding = clone(worker_of(f, id).pane_binding), native_state = "idle" }).ok)
		return f, id, clock
	end
	local function q_rollover(f, id)
		local requested = f:apply("rollover", { worker_id = id, trigger = "owner" }); assert(requested.ok, requested.message)
		assert(answer_checkpoint(f, id, "quota-cp-1").ok)
		return requested.handover_id
	end
	local function q_gate_on(f, worker_id)
		for _, g in f.authority.registry.dispatch.gates or {} do if g.worker_id == worker_id and g.kind == "quota_fallback" and g.phase == "pending" then return g end end
		return nil
	end

	if section == nil or section == "quota_rollover" then
		-- Off: rollover keeps the predecessor's record exactly as before.
		local off, off_id = q_rollover_fixture()
		assert(q_capacity(off, { q_known("native", 0), q_known("alt-model", 90) }).ok)
		local hid = q_rollover(off, off_id)
		local succ = worker_of(off, rollover_of(off, hid).successor_worker_id)
		check(rollover_of(off, hid).phase == "successor_granted" and succ.record_id == "native" and succ.routing == nil,
			"quota_routing off: the successor uses the predecessor's record with no routing state")
		-- Permitted: the worker_rollover allowlist and account permission select the alternative.
		local f, id = q_rollover_fixture()
		assert(f:apply("policy", { policy = { quota_routing = true, worker_rollover_enabled = true, worker_rollover_records = { "alt-model" }, worker_rollover_account = true } }).ok)
		assert(q_capacity(f, { q_known("native", 0), q_known("alt-model", 80) }).ok)
		hid = q_rollover(f, id)
		local r = rollover_of(f, hid)
		succ = worker_of(f, r.successor_worker_id)
		check(r.phase == "successor_granted" and succ.record_id == "alt-model" and succ.routing.scope == "worker_rollover" and succ.routing.authority == "policy"
			and succ.routing.needs == "account" and succ.routing.requested.id == "native" and succ.routing.reservation.phase == "reserved"
			and worker_of(f, id).record_id == "native" and f:action(actions_of(f, succ.worker_id, "mailbox_provision")[1]).request.record_id == "alt-model",
			"a permitted rollover substitution provisions the successor on the alternative; the running predecessor is unchanged")
		check(dispatch.valid(f.authority.registry.dispatch, f.authority.registry) and state.rehydrate(clone(f.authority.registry)) ~= nil, "routed successor state is valid and restores")
		-- Denied: initial-dispatch permission does not leak into rollover; the gate sits on the predecessor.
		local g, gid = q_rollover_fixture()
		assert(g:apply("policy", { policy = { quota_routing = true, worker_rollover_enabled = true, worker_rollover_records = { "alt-model" }, initial_dispatch_account = true } }).ok)
		assert(q_capacity(g, { q_known("native", 0), q_known("alt-model", 80) }).ok)
		hid = q_rollover(g, gid)
		r = rollover_of(g, hid)
		local gate = q_gate_on(g, gid)
		check(r.phase == "checkpoint_verified" and r.hold.code == "quota_fallback_gate" and r.successor_worker_id == nil and gate ~= nil
			and r.quota.gate.gate_id == gate.id and r.quota.gate.denied == "account" and r.quota.gate.scope == "worker_rollover" and r.quota.gate.to.id == "alt-model",
			"a denied rollover substitution is a durable predecessor-bound gate; no successor exists")
		check(dispatch.valid(g.authority.registry.dispatch, g.authority.registry), "the pending rollover fallback gate is valid")
		check(g:apply("answer", { gate_id = gate.id, gate_revision = gate.revision, choice_id = "approve", answer = "Approve" }).code == "fallback_approved", "owner approves this successor's substitution")
		r = rollover_of(g, hid)
		succ = if r.successor_worker_id then worker_of(g, r.successor_worker_id) else nil
		check(r.phase == "successor_granted" and succ ~= nil and succ.record_id == "alt-model" and succ.routing.authority == "owner_gate" and succ.routing.authorized_digest ~= nil
			and r.quota == nil and g.authority.registry.dispatch.gates[gate.id] == nil and g.authority.registry.dispatch.policies[g.origin.logical_session_id].worker_rollover_account == false,
			"approval grants only this successor on the destination and never edits Config")
		-- Reject holds the rollover; cancelling it closes the decision.
		local x, xid = q_rollover_fixture()
		assert(x:apply("policy", { policy = { quota_routing = true, worker_rollover_enabled = true, worker_rollover_records = { "alt-model" } } }).ok)
		assert(q_capacity(x, { q_known("native", 0), q_known("alt-model", 80) }).ok)
		hid = q_rollover(x, xid)
		gate = q_gate_on(x, xid)
		check(x:apply("answer", { gate_id = gate.id, gate_revision = gate.revision, choice_id = "reject", answer = "Reject" }).code == "fallback_rejected"
			and rollover_of(x, hid).hold.code == "quota_fallback_rejected" and rollover_of(x, hid).successor_worker_id == nil and q_gate_on(x, xid) == nil,
			"rejection holds the rollover without reopening the same question")
		check(x:apply("close_handover", { worker_id = xid }).code == "handover_closed", "owner closes the no-successor handover and discards its fallback decision")
		-- Nothing sufficient: held; fresh evidence grants the successor on the predecessor's record.
		local h, hidw = q_rollover_fixture()
		assert(h:apply("policy", { policy = { quota_routing = true } }).ok)
		assert(q_capacity(h, { q_known("native", 0) }).ok)
		hid = q_rollover(h, hidw)
		check(rollover_of(h, hid).phase == "checkpoint_verified" and rollover_of(h, hid).hold.code == "quota_insufficient" and rollover_of(h, hid).successor_worker_id == nil,
			"an exhausted predecessor record with no allowed alternative holds the rollover; the predecessor keeps running")
		assert(q_capacity(h, { q_known("native", 70) }, B).ok)
		r = rollover_of(h, hid)
		check(r.phase == "successor_granted" and worker_of(h, r.successor_worker_id).record_id == "native"
			and worker_of(h, r.successor_worker_id).routing.authority == "requested_sufficient", "fresh sufficient evidence grants the successor on the same record")
	end
	if section == nil or section == "quota_coordinator_rollover" then
		local clock = { now_ms = QNOW, mono_ms = 1000, epoch = "quota-coordinator-rollover" }
		local f, id = coordinator_ready(function() return clone(clock) end, true)
		local project_id = worker_of(f, id).orch_project_id
		local predecessor = clone(worker_of(f, id)); local previous_owner = clone(coordinator_owner(f))
		q_catalog(f)
		assert(f:apply("policy", { policy = { quota_routing = true, coordinator_rollover_enabled = true,
			coordinator_rollover_records = { "alt-model" }, coordinator_rollover_account = true } }).ok)
		assert(q_capacity(f, { q_known("native", 0), q_known("alt-model", 80) }).ok)
		assert(f:apply("observe", { worker_id = id, pane_binding = clone(predecessor.pane_binding), native_state = "idle" }).ok)
		local hid = coordinator_retirement_requested(f, id)
		check(handover_successors(f, hid) == 0 and coordinator_owner(f).owner_id == previous_owner.owner_id
			and not f.authority.registry.dispatch.projects[project_id].started, "account-switch selection neither overlaps coordinators nor starts the project")
		local prepared = rollover_of(f, hid).prepared
		check(prepared ~= nil and prepared.worker.record_id == "alt-model" and prepared.worker.coordinator_owner_id == nil
			and prepared.worker.routing.reservation == nil and #actions_of(f, prepared.worker.worker_id, "mailbox_provision") == 0
			and state.rehydrate(clone(f.authority.registry)) ~= nil,
			"the selected coordinator successor is a valid immutable draft, not a reserved owner, slot or issued provision")
		local stop = coordinator_stop_action(f, id)
		assert(coordinator_released(f, id, stop).code == "coordinator_retired")
		local r = rollover_of(f, hid); local succ_id = r.successor_worker_id; local successor = worker_of(f, succ_id)
		local provision_id = actions_of(f, succ_id, "mailbox_provision")[1]
		local provision_request = f:action(provision_id).request
		check(r.phase == "successor_granted" and successor.record_id == "alt-model"
			and successor.routing.scope == "coordinator_rollover" and successor.routing.needs == "account"
			and provision_request.record_id == "alt-model" and provision_request.worker_id ~= predecessor.worker_id
			and provision_request.enrolment_token ~= predecessor.enrolment_token
			and provision_request.handover_id == hid and provision_request.handover_sha256 == codec.sha256(hid .. ":" .. r.handover_token),
			"coordinator alternative provisions its own account record, worker, token and handover digest")
		check(coordinator_owner(f).owner_id ~= previous_owner.owner_id and coordinator_owner(f).generation > previous_owner.generation
			and successor.coordinator_owner_id == coordinator_owner(f).owner_id and worker_of(f, id).stopped ~= nil and worker_of(f, id).mailbox_retired,
			"successor gets a new owner only after exact predecessor stop and mailbox retirement")
		assert(f:finish(provision_id, "provisioned", { handle = "mailbox-account-successor", binding_digest = string.rep("c", 64),
			capabilities = runtime.json.array({ "report-files-v1", "native-ask-v1", "coordinator-control-v1", "project-start-v1" }), limits = {} }).ok)
		local launch_id = worker_of(f, succ_id).launch_action_id
		assert(f:apply("claim", { action_id = launch_id, executor = f.origin.window_epoch,
			capacity_validation = { revision = A, auth_revision = "auth-1", status = "current", validated_at_ms = QNOW, expires_at_ms = QNOW + 60000 } }).ok)
		local launch_request = f:action(launch_id).request
		check(launch_request.record_id == "alt-model" and launch_request.enrolment.enrolment_token == provision_request.enrolment_token
			and launch_request.enrolment.handover_id == hid and launch_request.enrolment.handover_token == r.handover_token,
			"account-switch native launch uses the successor's separately provisioned exact transport identity")
		assert(f:finish(launch_id, "awaiting_acceptance", { pane_binding = successor_pane(f) }).ok)
		local accept_id, accepted_request = successor_accept_request(f, succ_id)
		assert(f:finish(accept_id, "accepted", {}).ok)
		check(accepted_request.handover_id == hid and worker_of(f, succ_id).activation.activation_token ~= predecessor.activation.activation_token,
			"account-switch coordinator acceptance and activation retain the exact new handover/owner binding")
		assert(ack_activation(f, succ_id).ok)
		local kept = worker_of(f, id)
		check(kept.record_id == predecessor.record_id and kept.mailbox_handle == predecessor.mailbox_handle
			and kept.enrolment_token == predecessor.enrolment_token and kept.launch_request_id == predecessor.launch_request_id
			and runtime.json.encode(kept.pane_binding) == runtime.json.encode(predecessor.pane_binding)
			and kept.coordinator_owner_id == previous_owner.owner_id and kept.activation.activation_token == predecessor.activation.activation_token,
			"switching accounts preserves every predecessor launch/mailbox/owner identity unchanged")
		check(rollover_of(f, hid) == nil and not f.authority.registry.dispatch.projects[project_id].started
			and state.rehydrate(clone(f.authority.registry)) ~= nil, "completed coordinator account rollover preserves START=false and restores")
	end


	if section == nil or section == "quota_ledger" then
		local f = q_fixture()
		check(f:apply("policy", { policy = { concurrency_limit = 33 } }).code == "invalid_policy", "the concurrency limit is bounded to 32")
		assert(f:apply("policy", { policy = { quota_routing = true, concurrency_limit = 1 } }).ok)
		assert(q_capacity(f, { q_known("native", 60) }).ok)
		local first = q_queue(f)
		local w1 = q_worker(f, first.worker_id)
		check(first.code == "task_queued" and w1.routing.reservation.phase == "reserved" and w1.routing.reservation.decision_digest == w1.routing.decision_digest
			and w1.routing.reservation.evidence_revision == A, "a routed launch reserves a slot bound to its decision and evidence revision")
		local second = q_queue(f)
		check(q_outcome(second) == "task_held" and q_worker(f, second.worker_id).routing.reason.code == "concurrency_limit" and q_actions(f, second.worker_id) == 0,
			"the configured concurrency limit holds the next routed launch")
		local function validation(revision) return { revision = revision or A, auth_revision = "auth-1", status = "current", validated_at_ms = QNOW, expires_at_ms = QNOW + 60000 } end
		assert(f:finish(first.action_id, "provisioned", PROVISIONED).ok)
		local launch = q_worker(f, first.worker_id).launch_action_id
		assert(f:apply("claim", { action_id = launch, executor = f.origin.window_epoch, capacity_validation = validation() }).ok)
		check(q_worker(f, first.worker_id).routing.reservation.phase == "claimed", "the launch claim moves the reservation to claimed")
		assert(f:finish(launch, "rejected", nil, { code = "target_unavailable",
			message = "Target pane is not an idle native agent in the exact window, session and host; nothing was sent" }).ok)
		local history = {}
		for _, edge in q_worker(f, first.worker_id).routing.reservation.history do table.insert(history, edge.phase) end
		check(table.concat(history, ",") == "reserved,claimed,released", "a definitive pre-pane launch failure releases the slot: " .. table.concat(history, ","))
		assert(q_capacity(f, { q_known("native", 60) }, B).ok)
		local w2 = q_worker(f, second.worker_id)
		check(w2.routing.phase == "selected" and w2.routing.reservation.phase == "reserved" and q_actions(f, second.worker_id) == 1, "a released slot lets held work proceed on fresh evidence")
		-- The held queue command returned no action; the reroute created this worker's provision.
		local provision2 = actions_of(f, second.worker_id, "mailbox_provision"); assert(#provision2 == 1)
		assert(f:finish(provision2[1], "provisioned", PROVISIONED).ok)
		local launch2 = q_worker(f, second.worker_id).launch_action_id
		assert(f:apply("claim", { action_id = launch2, executor = f.origin.window_epoch, capacity_validation = validation(B) }).ok)
		local grant = f:action(launch2).claim.grant_id
		assert(f:apply("lost", { action_id = launch2, executor = f.origin.window_epoch, grant_id = grant }).ok)
		check(f:action(launch2).phase == "uncertain" and q_worker(f, second.worker_id).routing.reservation.phase == "uncertain", "an uncertain launch keeps its reservation")
		local third = q_queue(f)
		check(q_outcome(third) == "task_held" and q_worker(f, third.worker_id).routing.reason.code == "concurrency_limit", "an uncertain reservation still occupies the slot")
		check(state.rehydrate(clone(f.authority.registry)) ~= nil, "the ledger restores")
		local forged = clone(f.authority.registry); forged.dispatch.workers[second.worker_id].routing.reservation.phase = "parked"
		check(state.rehydrate(forged) == nil, "an unknown reservation phase is rejected at restore")
		forged = clone(f.authority.registry); forged.dispatch.workers[second.worker_id].routing.reservation.phase = "reserved"
		check(state.rehydrate(forged) == nil, "a reservation phase that disagrees with its last history edge is rejected")
		forged = clone(f.authority.registry); forged.dispatch.workers[third.worker_id].routing.reservation = clone(q_worker(f, second.worker_id).routing.reservation)
		check(state.rehydrate(forged) == nil, "an unprovisioned worker cannot hold a reservation")
		assert(f:apply("policy", { policy = { concurrency_limit = 0 } }).ok)
		check(q_worker(f, third.worker_id).routing.phase == "selected" and q_worker(f, third.worker_id).routing.reservation.phase == "reserved",
			"with no configured limit the held work is re-evaluated and reserved")
	end

	if section == nil or section == "quota_selector" then
		check(quota.selector_state({ selector_evidence = "operator note" }) == "unverified_owner_text" and quota.selector_state({}) == "unverified_absent",
			"SPAWN's free-text selector evidence is never a verified selector state")
		local f = q_fixture()
		assert(f:apply("policy", { policy = { quota_routing = true, initial_dispatch_records = { "alt-model" } } }).ok)
		assert(q_capacity(f, { q_known("native", 0), q_known("alt-model", 80) }).ok)
		local queued = q_queue(f)
		local gate = q_gate(f, queued.worker_id)
		local listed = false
		for _, item in gate.evidence do if item:sub(1, 27) == "selector:unverified_absent " then listed = true end end
		check(listed and q_worker(f, queued.worker_id).routing.selector == "unverified_absent", "fallback evidence and the decision record the unverified selector state")
		local projected = dispatch.project(f.authority.registry, f.origin.logical_session_id, f.origin.alias_nonce)
		check(projected.workers[queued.worker_id].routing.selector == "unverified_absent",
			"the consumer receives unverified selector evidence, not fabricated identity enforcement")
		assert(f:apply("policy", { policy = { initial_dispatch_account = true } }).ok)
		check(q_worker(f, queued.worker_id).record_id == "alt-model", "selector state is evidence only: it neither blocks nor enables a permitted substitution")
		local manual = q_fixture()
		local project = manual:project("Verified project cwd", false)
		local p = manual.authority.registry.dispatch.projects[project]
		assert(manual:apply("project_repository", { orch_project_id = project, project_revision = p.revision,
			repository = { cwd = "/project/checkout", repo_root = "/project/checkout", common_dir = "/project/.git",
				target_ref = "main", head_revision = string.rep("a", 40), queue_route = "orch_queue" } }).ok)
		local rows = manual.authority.registry.dispatch.catalogs[manual.origin.logical_session_id].records
		for _, row in rows do if row.id == "alt-model" then row.cwd = "/alt/default"; row.placement = "replace_if_alone" end end
		manual.memory.value = clone(manual.authority.registry)
		assert(manual:apply("policy", { policy = { quota_routing = true, initial_dispatch_records = { "alt-model" }, initial_dispatch_account = true } }).ok)
		assert(q_capacity(manual, { q_known("native", 0), q_known("alt-model", 80) }).ok)
		local opening = manual:apply("queue", { orch_project_id = project, record_id = "native", record_revision = 0, catalog_revision = 0,
			prompt = codec.OPEN_CONVERSATION_ASSIGNMENT, cwd = "/fixture", placement = "split", coordinator = false,
			presentation = "user_new_tab", open_conversation = true, execution_cwd = "/project/checkout" })
		assert(opening.ok, opening.message)
		local choice = q_gate(manual, opening.worker_id)
		check(choice ~= nil and q_worker(manual, opening.worker_id).record_id == "native" and q_actions(manual, opening.worker_id) == 0,
			"a manual conversation click always asks before substituting, even when automatic model substitution is allowed")
		assert(manual:apply("answer", { gate_id = choice.id, gate_revision = choice.revision, choice_id = "approve", answer = "Use this alternative." }).ok)
		local selected = q_worker(manual, opening.worker_id)
		check(selected.record_id == "alt-model" and selected.cwd == "/alt/default" and selected.placement == "replace_if_alone"
			and selected.execution_cwd == "/project/checkout" and selected.presentation == "user_new_tab",
			"fallback keeps the chosen record defaults separate from effective project cwd and presentation")
		local provision
		for aid, action in manual.authority.registry.dispatch.actions do if action.worker_id == opening.worker_id and action.request.op == "mailbox_provision" then provision = aid end end
		assert(manual:finish(provision, "provisioned", PROVISIONED).ok)
		local launch = manual:action(q_worker(manual, opening.worker_id).launch_action_id).request
		check(launch.placement == "tab" and launch.cwd == "/project/checkout" and launch.execution_cwd == "/project/checkout"
			and launch.prompt == codec.OPEN_CONVERSATION_ASSIGNMENT, "new-tab override works even for a saved replace record without losing canonical enrollment bytes")
	end

	if section == nil or section == "withdraw_fenced" then
		-- SPAWN definitively rejected a routed provision before any effect
		-- ("Occupied SPAWN controller binding"). The selected work is held with no mailbox and no
		-- launch; its retained rejection is terminal, so the owner withdraws it without a status read.
		local f = q_fixture()
		assert(f:apply("policy", { policy = { quota_routing = true } }).ok)
		assert(q_capacity(f, { q_known("native", 60) }).ok)
		local queued = q_queue(f); assert(queued.code == "task_queued", queued.message)
		assert(f:apply("claim", { action_id = queued.action_id, executor = f.origin.window_epoch }).ok)
		local provision = f:action(queued.action_id)
		local occupied = { code = "binding_mismatch", message = "Occupied SPAWN controller binding; inspect Config and recover the prior owner explicitly" }
		check(f:apply("result", { action_id = queued.action_id, executor = provision.claim.executor, grant_id = provision.claim.grant_id,
			response_bytes = frame(provision.request, "rejected", nil, occupied) }).code == "bridge_rejected", "SPAWN's definite provision rejection commits")
		local w = q_worker(f, queued.worker_id)
		check(w.phase == "held" and w.mailbox_handle == nil and w.routing.phase == "selected" and f:action(w.launch_action_id) == nil,
			"the routed work is held: selected, never provisioned and never launched")
		check(f:apply("cancel_work", { worker_id = queued.worker_id }).code == "allocation_required"
			and q_worker(f, queued.worker_id) ~= nil,
			"a provision rejection cannot release a possibly retained allocation without observing its exact generation")
		assert(f:allocation(queued.worker_id, { state = "none" }).ok)
		local cancelled = f:apply("cancel_work", { worker_id = queued.worker_id })
		check(cancelled.code == "work_cancelled" and q_worker(f, queued.worker_id) == nil and q_actions(f, queued.worker_id) == 0,
			"the rejected work and its settled provision are removed, releasing its routing reservation")
		check(state.rehydrate(clone(f.authority.registry)) ~= nil and q_queue(f).code == "task_queued", "the state restores and new routed work is queued")
		-- A provision whose outcome is unknown stays strict: it may have created a mailbox.
		local u = q_fixture()
		assert(u:apply("policy", { policy = { quota_routing = true } }).ok)
		assert(q_capacity(u, { q_known("native", 60) }).ok)
		local uq = q_queue(u); assert(uq.code == "task_queued", uq.message)
		assert(u:apply("claim", { action_id = uq.action_id, executor = u.origin.window_epoch }).ok)
		local grant = u:action(uq.action_id).claim
		assert(u:apply("lost", { action_id = uq.action_id, executor = grant.executor, grant_id = grant.grant_id }).ok)
		local uncertain_before, uncertain_writes = runtime.json.encode(u.authority.registry), u.memory.writes
		local uncertain_cancel = u:apply("cancel_work", { worker_id = uq.worker_id })
		check(uncertain_cancel.ok == false and u:action(uq.action_id).phase == "uncertain"
			and q_worker(u, uq.worker_id) ~= nil and runtime.json.encode(u.authority.registry) == uncertain_before
			and u.memory.writes == uncertain_writes, "an uncertain provision is never withdrawn or changed without current SPAWN evidence")
		-- So does a claimed one still awaiting SPAWN.
		local c = q_fixture()
		assert(c:apply("policy", { policy = { quota_routing = true } }).ok)
		assert(q_capacity(c, { q_known("native", 60) }).ok)
		local cq = q_queue(c); assert(cq.code == "task_queued", cq.message)
		assert(c:apply("claim", { action_id = cq.action_id, executor = c.origin.window_epoch }).ok)
		local claimed_before, claimed_writes = runtime.json.encode(c.authority.registry), c.memory.writes
		check(c:apply("cancel_work", { worker_id = cq.worker_id }).ok == false and q_worker(c, cq.worker_id) ~= nil
			and runtime.json.encode(c.authority.registry) == claimed_before and c.memory.writes == claimed_writes,
			"a claimed provision is never withdrawn or changed while awaiting SPAWN")
		-- Fenced routed launch with a provisioned mailbox: withdrawal keeps the fenced launch, so the
		-- work is never routed again, holds no concurrency reservation and opens no fallback gate
		-- while its unused mailbox retires.
		local AUTH_FULL = { resource = "window_authorization", current = 1, limit = 1, retryable = true, effect_started = false }
		local validation = { revision = A, auth_revision = "auth-1", status = "current", validated_at_ms = QNOW, expires_at_ms = QNOW + 60000 }
		for _, continued in { false, true } do
		local p = q_fixture()
		assert(p:apply("policy", { policy = { quota_routing = true, concurrency_limit = 1 } }).ok)
		assert(q_capacity(p, { q_known("native", 60) }).ok)
		local pq = q_queue(p); assert(pq.code == "task_queued", pq.message)
		local pid = pq.worker_id
		assert(p:finish(pq.action_id, "provisioned", PROVISIONED).ok)
		local plaunch = q_worker(p, pid).launch_action_id
		assert(p:apply("claim", { action_id = plaunch, executor = p.origin.window_epoch, capacity_validation = validation }).ok)
		local pa = p:action(plaunch)
		check(p:apply("result", { action_id = plaunch, executor = pa.claim.executor, grant_id = pa.claim.grant_id, response_bytes = frame(pa.request, "full", AUTH_FULL) }).code == "backpressure",
			"the routed launch is refused before effects by an expired SPAWN window challenge")
		if continued then
			p.origin.window_epoch = "replacement-window"; p.controller_pane = "9010"
			assert(p:apply("continue_controller", { expected_revision = p.authority.registry.revision, operator_verified = true }).ok)
			assert(p:control("reconcile_session").ok) -- Fresh peer observation restores admission, never the old revision fence.
		end
		local pfenced = p:action(plaunch)
		check(pfenced.phase == "backpressure" and pfenced.response.status == "full", "continuation retains the routed launch's exact pre-effect refusal")
		local withdrawn = p:apply("cancel_work", { worker_id = pid })
		local pw = q_worker(p, pid)
		check(withdrawn.code == "withdrawal_retiring" and pw ~= nil and p:action(plaunch) == nil and pw.routing.phase == "selected" and pw.routing.reservation.phase == "released",
			"withdrawal consumes the proven-unexecuted launch and releases concurrency while mailbox retirement remains live")
		local cancelled_questions = true
		for _, question in p.authority.registry.dispatch.gates do
			if question.worker_id == pid and question.delivery == nil and question.ruling == nil and question.execution == nil
				and question.phase ~= "cancelled" and question.phase ~= "resolved" then cancelled_questions = false end
		end
		check(cancelled_questions and pw.launch_gates == nil, "proven withdrawal settles effect-free launch questions instead of pinning a retired mailbox forever")
		local actions_before = q_actions(p, pid)
		assert(q_capacity(p, { q_known("native", 0) }, B).ok)
		check(q_gate(p, pid) == nil and q_actions(p, pid) == actions_before and q_worker(p, pid).routing.phase == "selected",
			"new capacity evidence never re-routes the withdrawn work or opens a fallback gate for it")
		assert(q_capacity(p, { q_known("native", 60) }, C).ok)
		local next_work = q_queue(p, true)
		-- Both fixture tasks deliberately use /fixture. The retained retiring worker
		-- still participates in conservative checkout collision detection; that
		-- independent owner gate precedes quota routing and its reservation check.
		local next_worker = q_worker(p, next_work.worker_id)
		local checkout_gate = if next_worker and next_worker.launch_gates and #next_worker.launch_gates == 1
			then p.authority.registry.dispatch.gates[next_worker.launch_gates[1]] else nil
		check(next_work.code == "task_gated" and checkout_gate ~= nil and checkout_gate.kind == "shared_checkout"
			and table.find(checkout_gate.evidence, "peer:" .. pid .. ":/fixture") ~= nil,
			"shared fixture checkout requires its separate owner decision before testing the released concurrency slot")
		next_work = p:allow_shared_fixture(next_work)
		-- answer_checkout_gate preserves the queue result in `launch`; its own
		-- command receipt is `launch_released`, not a second queue receipt.
		local routed = q_worker(p, next_work.worker_id)
		local provision = if next_work.action_id then p:action(next_work.action_id) else nil
		check(next_work.code == "launch_released" and next_work.launch == "task_queued"
			and routed.routing.reservation.phase == "reserved"
			and provision ~= nil and provision.phase == "ready" and provision.request.op == "mailbox_provision"
			and provision.worker_id == routed.worker_id,
			"the concurrency limit of one admits new routed work while the withdrawal retires: "
				.. runtime.json.encode({ answer = next_work, routing = routed.routing }))
		check(state.rehydrate(clone(p.authority.registry)) ~= nil, "the routed withdrawal restores")
		check(p:finish(withdrawn.action_id, "retired", nil).ok and q_worker(p, pid).mailbox_retired == true, "SPAWN confirms the routed withdrawal's retirement")
		q_queue(p) -- Queueing reclaims settled retired workers first.
		check(q_worker(p, pid) == nil, "the retired routed worker is reclaimed")
		end
	end

	if section == nil or section == "quota_continuation" then
		-- Routed work queued on window A that had not launched when the controller continued on
		-- window B launches on B; a launch already claimed on A stays strict.
		local function validation() return { revision = A, auth_revision = "auth-1", status = "current", validated_at_ms = QNOW, expires_at_ms = QNOW + 60000 } end
		local function routed()
			local f = q_fixture()
			assert(f:apply("policy", { policy = { quota_routing = true } }).ok)
			assert(q_capacity(f, { q_known("native", 60) }).ok)
			local queued = q_queue(f); assert(queued.code == "task_queued", queued.message)
			return f, queued
		end
		local function continue_on_b(f)
			f.origin.window_epoch = "replacement-window"; f.controller_pane = "9010"
			assert(f:apply("continue_controller", { expected_revision = f.authority.registry.revision, operator_verified = true }).ok)
			assert(f:control("reconcile_session").ok) -- Fresh peer observation restores admission, never the old revision fence.
		end
		-- Live defect: provision claimed on A, controller continued on B, provision completes after.
		local f, queued = routed()
		local old_origin = clone(f.origin)
		assert(f:apply("claim", { action_id = queued.action_id, executor = f.origin.window_epoch }).ok)
		local provision = clone(f:action(queued.action_id))
		continue_on_b(f)
		check(f:action(queued.action_id).phase == "uncertain" and f:action(queued.action_id).request_bytes == provision.request_bytes,
			"the provision claimed on the old window stays uncertain with its exact request")
		local settled = f:apply("result", { action_id = queued.action_id, executor = provision.claim.executor, grant_id = provision.claim.grant_id,
			response_bytes = frame(provision.request, "provisioned", f:peer_payload(provision, "provisioned", PROVISIONED)) })
		check(settled.ok, "the old provision settles through the continued route: " .. tostring(settled.message))
		local w = q_worker(f, queued.worker_id)
		local launch = f:action(w.launch_action_id)
		check(launch.phase == "ready" and launch.claim == nil and launch.request_bytes == nil
			and launch.request.origin_binding.window_epoch == old_origin.window_epoch
			and w.origin_binding.window_epoch == old_origin.window_epoch
			and launch.request.request_id == w.launch_request_id and w.routing.reservation.phase == "reserved",
			"late provision settles once without rewriting the immutable worker or issuing its old-route launch")
		check(f:apply("claim", { action_id = w.launch_action_id, executor = f.origin.window_epoch,
			capacity_validation = validation() }).code == "claim_mismatch" and launch.request_bytes == nil,
			"the continued window cannot acquire the old-route launch by changing its executor")
		-- Pre-existing drafts are held at continuation, not rewritten or silently issued.
		local h, hq = routed()
		local before = clone(h:action(hq.action_id).request)
		continue_on_b(h)
		local moved = h:action(hq.action_id)
		check(moved.phase == "held_ready" and moved.request_bytes == nil
			and runtime.json.encode(moved.request) == runtime.json.encode(before),
			"a continued provision draft preserves its exact intent and remains unissued")
		check(not h:apply("claim", { action_id = hq.action_id, executor = h.origin.window_epoch }).ok
			and h:action(hq.action_id).phase == "held_ready", "continuation alone cannot authorize the held provision")
		-- The same fence applies to an already-provisioned launch draft.
		local k, kq = routed()
		assert(k:finish(kq.action_id, "provisioned", PROVISIONED).ok)
		local kw = q_worker(k, kq.worker_id)
		local original_launch = clone(k:action(kw.launch_action_id).request)
		continue_on_b(k)
		check(k:action(kw.launch_action_id).phase == "held_ready" and k:action(kw.launch_action_id).request_bytes == nil
			and runtime.json.encode(k:action(kw.launch_action_id).request) == runtime.json.encode(original_launch),
			"a continued launch draft preserves its exact intent without an execution grant")
		check(not k:apply("claim", { action_id = kw.launch_action_id, executor = k.origin.window_epoch,
			capacity_validation = validation() }).ok, "capacity evidence cannot authorize a different native origin")
		-- A launch already claimed on the old window keeps its route and becomes uncertain.
		local g, gq = routed()
		assert(g:finish(gq.action_id, "provisioned", PROVISIONED).ok)
		local glaunch = q_worker(g, gq.worker_id).launch_action_id
		assert(g:apply("claim", { action_id = glaunch, executor = g.origin.window_epoch, capacity_validation = validation() }).ok)
		continue_on_b(g)
		check(g:action(glaunch).phase == "uncertain" and g:action(glaunch).request.origin_binding.window_epoch == "fixture-window"
			and q_worker(g, gq.worker_id).origin_binding.window_epoch == "fixture-window" and q_worker(g, gq.worker_id).routing.reservation.phase == "uncertain",
			"a launch claimed on the old window keeps its route and becomes uncertain")
		check(g:apply("claim", { action_id = glaunch, executor = g.origin.window_epoch, capacity_validation = validation() }).code == "claim_mismatch"
			and g:action(glaunch).phase == "uncertain", "the continued window never re-runs it")
		check(state.rehydrate(clone(g.authority.registry)) ~= nil, "the strict launch state restores")
	end
end
-- Config v4 (CP1): 47 bounded keys, every historical store migrates, live saves stay strict.
local POLICY_V0 = { "paused", "poll_ms", "heartbeat_ms", "stale_ms", "automatic_reports" }
local POLICY_V1 = { "auto_rollover", "rollover_threshold_pct", "rollover_include_coordinator", "quota_routing", "excluded_workers" }
local POLICY_V2 = { "quota_reserve_pct", "quota_max_age_ms", "initial_dispatch_records", "initial_dispatch_provider", "initial_dispatch_account", "initial_dispatch_model" }
local POLICY_V3 = { "sweep_enabled", "sweep_time" }
local POLICY_V4 = { "worker_rollover_records", "worker_rollover_provider", "worker_rollover_account", "worker_rollover_model",
	"coordinator_rollover_records", "coordinator_rollover_provider", "coordinator_rollover_account", "coordinator_rollover_model", "concurrency_limit" }
local function same_json(a, b)
	local function canon(v)
		if type(v) ~= "table" then return runtime.json.encode(v) end
		local parts = {}
		for k, value in v do table.insert(parts, tostring(k) .. "=" .. canon(value)) end
		table.sort(parts)
		return "{" .. table.concat(parts, ",") .. "}"
	end
	return canon(a) == canon(b)
end
if section == nil or section == "policy_keys" then
	do
		local allocations = fixture(); allocations:catalog(0)
		local queued = allocations:queue(false); assert(queued.ok, queued.message)
		assert(allocations:finish(queued.action_id, "rejected", nil, { code = "helper_declined", message = "Initialization failed after the intent could be recorded." }).ok)
		local id = queued.worker_id
		local held = allocations.authority.registry.dispatch.workers[id]
		check(held.phase == "held" and held.mailbox_allocation == "possible" and held.launch_refused
			and allocations:action(queued.action_id) == nil and allocations:apply("cancel_work", { worker_id = id }).code == "allocation_required",
			"a consumed provision rejection preserves possible allocation and cannot silently delete its generation")
		-- Old stores consumed the original negative action and had no allocation/op marker.
		held.mailbox_allocation = nil; held.launch_refused_op = nil
		local writes = allocations.memory.writes
		check(not allocations:allocation(id, nil).ok and allocations.memory.writes == writes
			and allocations.authority.registry.dispatch.workers[id].phase == "held",
			"pending/unknown observation leaves legacy startup and original refusal intact")
		local provision = allocations:peer_payload({ request = {}, worker_id = id }, "provisioned", {
			handle = "observed-legacy-allocation", binding_digest = string.rep("b", 64),
			capabilities = runtime.json.array({ "report-files-v1", "native-ask-v1" }) })
		check(not allocations:allocation(id, { state = "retained", provision = provision }, { worker_id = "different-worker" }).ok
			and allocations.memory.writes == writes, "another exact generation's allocation proof cannot be applied to this worker")
		assert(allocations:allocation(id, { state = "retained", provision = provision }).ok)
		held = allocations.authority.registry.dispatch.workers[id]
		check(held.mailbox_handle == provision.handle and held.phase == "held" and held.launch_refused
			and held.reason.code == "helper_declined" and allocations:action(held.launch_action_id) == nil
			and dispatch.project(allocations.authority.registry, held.logical_session_id, allocations.origin.alias_nonce).workers[id].allocation_target == nil,
			"legacy allocation observation recovers only metadata: no manufactured successful startup, native launch or replay")
		local cancelled = allocations:apply("cancel_work", { worker_id = id }); assert(cancelled.ok, cancelled.message)
		check(cancelled.code == "withdrawal_retiring" and allocations:action(cancelled.action_id).request.op == "mailbox_retire",
			"the real owner cancellation retires the recovered unused allocation through the existing bound path")
		assert(allocations:finish(cancelled.action_id, "retired", {}).ok)
		check(allocations.authority.registry.dispatch.workers[id].mailbox_retired and state.rehydrate(clone(allocations.authority.registry)) ~= nil,
			"only positive retirement frees the recovered allocation and its evidence restores")
	end
	do
		local space = fixture()
		local first = space:accepted(false)
		for _ = 1, 14 do local queued = space:queue(false); assert(queued.ok and queued.action_id, queued.message) end
		local waiting = space:queue(false); assert(waiting.ok, waiting.message)
		check(waiting.action_id == nil and #actions_of(space, waiting.worker_id, "mailbox_provision") == 0
			and worker_of(space, waiting.worker_id).reason.code == "waiting_for_agent_space",
			"high logical concurrency cannot consume physical review/rollover headroom: " .. runtime.json.encode(waiting))
		local co = space:queue(true)
		check(co.ok and co.action_id == nil and #actions_of(space, co.worker_id, "mailbox_provision") == 0 and coordinator_owner(space) == nil,
			"an initial coordinator allocation cannot consume protected progress space or reserve an owner while held")
		assert(space:apply("cancel_work", { worker_id = co.worker_id }).code == "work_cancelled")
		finish_ordinary(space, first)
		check(#actions_of(space, waiting.worker_id, "mailbox_provision") == 1,
			"ordinary explicit Finish, actual native exit and positive mailbox retirement release the retained waiting task, not a lifetime-task ceiling")
	end
	do
		local space, first = rollover_fixture()
		for _ = 1, 14 do local queued = space:queue(false); assert(queued.ok and queued.action_id, queued.message) end
		local waiting = space:queue(false); assert(waiting.ok and #actions_of(space, waiting.worker_id, "mailbox_provision") == 0, waiting.message)
		local handover, successor = rollover_granted(space, first)
		check(successor ~= nil and #actions_of(space, successor, "mailbox_provision") == 1
			and rollover_of(space, handover).phase == "successor_granted",
			"default-worker rollover can use its reserved physical progress slot even when ordinary admissions wait")
		check(#actions_of(space, waiting.worker_id, "mailbox_provision") == 0 and state.rehydrate(clone(space.authority.registry)) ~= nil,
			"overlap preserves ordinary held work and exact successor/predecessor evidence without extra launches")
	end
	do
		local migrated = fixture(nil, { default_limits = true })
		local migration_sid = migrated.origin.logical_session_id
		migrated.authority.registry.dispatch.family_migrations = { [migration_sid] = { native = "muse" } }
		migrated.authority.registry.installation_defaults.family_migrations = { native = "muse" }
		migrated:catalog(0, "native", nil, "meta")
		check(migrated.authority.registry.dispatch.family_migrations[migration_sid].native == "muse",
			"a derived catalog family cannot discard an explicit legacy declaration without the SPAWN writer")
		local declaration = migrated:apply("migrate_families")
		assert(declaration.ok and declaration.action_id, declaration.message)
		check(migrated:action(declaration.action_id).request.declarations[1].provider_family == "muse",
			"ORCH forwards the saved declaration without duplicating SPAWN aliases")
		local confirmed = migrated:finish(declaration.action_id, "resolved", { config_revision = 1, applied = 1,
			families = runtime.json.array({ { record_id = "native", provider_family = "meta" } }) })
		assert(confirmed.ok, runtime.json.encode(confirmed))
		check(migrated.authority.registry.dispatch.family_migrations[migration_sid].native == "meta"
			and migrated.authority.registry.installation_defaults.family_migrations.native == "meta"
			and migrated:action(declaration.action_id) ~= nil and state.rehydrate(migrated.authority.registry) ~= nil,
			"the exact writer response durably retains its canonical target, not catalog success or an ORCH alias")
		migrated:catalog(2, "native", nil, "other")
		check(migrated.authority.registry.dispatch.family_migrations[migration_sid].native == "meta",
			"a fresh but differing catalog cannot settle a successful saved-family obligation")
		migrated:catalog(3, "native", nil, "meta")
		check(next(migrated.authority.registry.dispatch.family_migrations[migration_sid]) == nil
			and next(migrated.authority.registry.installation_defaults.family_migrations) == nil
			and migrated:action(declaration.action_id) == nil and next(migrated.authority.registry.dispatch.workers) == nil,
			"only the matching fresh canonical catalog settles both scopes and the receipt without launching work")
	end
	local f = fixture(function() return { now_ms = 1000, mono_ms = 1000, epoch = "policy-keys-host" } end, { default_limits = true })
	assert(f:apply("policy", { policy = { concurrency_limit = 4, require_code_review = true, require_other_family = true } }).ok)
	local sid = f.origin.logical_session_id
	local function saved() return dispatch.policy(f.authority.registry, sid) end
	local function save(fields) return f:apply("policy", fields) end
	local defaults = saved()
	do
		local limited = fixture(function() return { now_ms = 1000 } end, { default_limits = true })
		assert(limited:apply("policy", { policy = { concurrency_limit = 4 } }).ok)
		limited:catalog(0)
		local workers = {}
		for index = 1, 4 do
			local work = limited:allow_shared_fixture(limited:queue(false))
			assert(work.ok and work.action_id, work.message)
			table.insert(workers, work.worker_id)
		end
		local fifth = limited:allow_shared_fixture(limited:queue(false))
		check(fifth.ok and #actions_of(limited, fifth.worker_id, "mailbox_provision") == 0, "the configured concurrency limit holds excess managed work even with quota routing off")
		assert(limited:apply("policy", { policy = { concurrency_limit = 5 } }).ok)
		check(#actions_of(limited, fifth.worker_id, "mailbox_provision") == 1, "raising the managed task limit releases the retained fifth assignment without re-adding it")
		for _, worker in workers do check(limited.authority.registry.dispatch.workers[worker] ~= nil, "changing task limit preserves prior admitted work") end
	end
	-- A partial save retains every independent setting.
	check(save({ policy = { loop_cap = 4 } }).code == "policy_updated" and saved().concurrency_limit == 4, "partial policy edits retain unrelated limits")
	for _, old in { true, false } do
		local legacy = clone(f.authority.registry)
		local p = legacy.dispatch.policies[sid]
		p.require_code_review = nil; p.require_other_family = nil; p.enforce_cross_family = old
		check(not dispatch.valid(legacy.dispatch, legacy), "obsolete policy is never a live schema")
		check(state.rehydrate(clone(legacy)) == nil, "obsolete family policy inside a current store requires explicit source migration, never implicit defaults")
	end
	for _, patch in {
		{ enforce_cross_family = false }, { enforce_cross_family = true },
		{ require_code_review = false, require_other_family = true },
		{ require_code_review = "no" }, { require_other_family = "yes" },
	} do
		local before = runtime.json.encode(f.authority.registry)
		check(save({ policy = patch }).code == "invalid_policy" and runtime.json.encode(f.authority.registry) == before,
			"obsolete, contradictory or non-boolean live policy is refused atomically")
	end
	for _, mutate in {
		function(p) p.require_code_review = false; p.require_other_family = true end,
		function(p) p.require_code_review = nil end,
		function(p) p.require_other_family = nil end,
		function(p) p.enforce_cross_family = false end,
	} do
		local invalid = clone(f.authority.registry); mutate(invalid.dispatch.policies[sid])
		check(not dispatch.valid(invalid.dispatch, invalid) and state.rehydrate(invalid) == nil,
			"partial, mixed or contradictory persisted review policy fails closed")
	end
	assert(save({ policy = { require_code_review = false } }).ok)
	check(not saved().require_code_review and not saved().require_other_family, "turning review off also turns the family requirement off")
	check(save({ policy = { require_other_family = true } }).code == "invalid_policy", "another family cannot be required while review is off")
	assert(save({ policy = { require_code_review = true } }).ok)
	check(saved().require_code_review and not saved().require_other_family, "reenabling review does not resurrect the previous family requirement")
	assert(save({ policy = { require_other_family = true } }).ok)
	check(saved().require_other_family, "the owner can explicitly enable another family again")
	-- Every historical-shaped policy is invalid when injected into the current store.
	local shapes, keys = {}, {}
	for _, group in { POLICY_V0, POLICY_V1, POLICY_V2, POLICY_V3, POLICY_V4 } do
		for _, key in group do table.insert(keys, key) end
		table.insert(shapes, table.clone(keys))
	end
	for _, shape in shapes do
		local legacy = clone(f.authority.registry); local stored = {}
		for _, key in shape do stored[key] = clone(defaults[key]) end
		stored.poll_ms = 2000
		legacy.dispatch.policies[sid] = stored
		check(not dispatch.valid(legacy.dispatch, legacy), #shape .. "-key policy is not a live store shape")
		check(state.rehydrate(clone(legacy)) == nil, #shape .. "-key historical policy cannot impersonate current schema provenance")
		local short = clone(legacy); short.dispatch.policies[sid].poll_ms = nil
		check(state.rehydrate(short) == nil, #shape - 1 .. "-key policy (one key missing from the " .. #shape .. "-key form) is rejected, not defaulted")
	end
	local partial = clone(f.authority.registry); partial.dispatch.policies[sid].loop_cap = nil
	check(state.rehydrate(partial) == nil and not dispatch.valid(partial.dispatch, partial), "a 46-key store is rejected at restore and live")
	local extra = clone(f.authority.registry); extra.dispatch.policies[sid].deploy_hold = true
	check(state.rehydrate(extra) == nil, "a 48-key store with an unknown key is rejected")
	check(dispatch.valid(f.authority.registry.dispatch, f.authority.registry) and state.rehydrate(clone(f.authority.registry)) ~= nil, "the 47-key store is valid live and restores")
	-- Bounds: each limit refused one past, accepted at the edge; refusals change nothing.
	local cases = {
		{ "loop_cap", { 0, 11, 2.5, "3", true }, { 1, 10 } },
		{ "review_rounds", { 0, 11, 1.5 }, { 1, 5, 10 } },
		{ "stale_claim_min", { -1, 1441, 0.001, "30" }, { 0, 1/60, 0.5, 1440 } },
		{ "require_code_review", { "yes", 1, runtime.json.null }, { false, true } },
		{ "require_other_family", { "yes", 1, runtime.json.null }, { false, true } },
		{ "glitch_integration", { "no", 0 }, { false, true } },
		{ "auto_start_projects", { "true" }, { true, false } },
		{ "auto_approve_kinds", { { "deploy" }, { "report", "report" }, "landing" },
			{ { "dispatch", "landing" }, { "dispatch", "report", "review", "landing" }, {} } },

		{ "reviewer_records", { { "a", "b", "c", "d", "e", "f", "g", "h", "i" }, { "*" }, { "rec-*" } }, { { "a", "b", "c", "d", "e", "f", "g", "h" }, { "rec-b", "rec-a" }, {} } },
		{ "release_manager_record", { runtime.json.null, 5, "*" }, { "native", "" } },

		{ "checkout_roots", { { "relative/root" }, { "/" .. string.rep("r", 512) }, { "/a", "/b", "/c", "/d", "/e", "/f", "/g", "/h", "/i" } },
			{ { "/" .. string.rep("r", 511) }, { "/a", "/b", "/c", "/d", "/e", "/f", "/g", "/h" }, {} } },
		{ "board_path", { "../escape", runtime.json.null }, { "ORCH+ Board.tern", "/srv/board.md", "" } },
		{ "inbox_folder", { "../escape", runtime.json.null }, { "inbox", "/srv/inbox", "" } },
		{ "board_lanes", { { queued = "Todo", running = "Doing", review = "Review" }, { queued = "Todo", running = "Doing", review = "Review", done = string.rep("d", 65) },
			{ queued = "Todo", running = "Doing", review = "Review", done = "Done", extra = "X" } },
			{ { queued = "Backlog", running = "Doing", review = "Review", done = string.rep("d", 64) }, { queued = "Todo", running = "Doing", review = "Review", done = "Done" } } },
	}
	for _, case in cases do
		local key, bad, good = case[1], case[2], case[3]
		for _, value in bad do
			local before = runtime.json.encode(f.authority.registry)
			local outcome = save({ policy = { [key] = value } })
			check(outcome.code == "invalid_policy" and runtime.json.encode(f.authority.registry) == before,
				key .. " = " .. runtime.json.encode(value) .. " is refused with nothing changed")
		end
		for _, value in good do
			local outcome = save({ policy = { [key] = value } })
			check(outcome.ok and same_json(saved()[key], value), key .. " = " .. runtime.json.encode(value) .. " is accepted, including an already-saved value")
		end
	end
	-- Reviewer records keep the owner's order; a repeated id is dropped on save, refused in a store.
	check(save({ policy = { reviewer_records = { "rec-b", "rec-a", "rec-b" } } }).code == "policy_updated" and same_json(saved().reviewer_records, { "rec-b", "rec-a" }),
		"reviewer records keep the owner's order and drop a repeated id")
	local duplicate = clone(f.authority.registry); duplicate.dispatch.policies[sid].reviewer_records = { "rec-b", "rec-a", "rec-b" }
	check(state.rehydrate(duplicate) == nil, "a stored reviewer list with a duplicate id is refused")
	local unsorted = clone(f.authority.registry); unsorted.dispatch.policies[sid].reviewer_records = { "rec-z", "rec-a" }
	check(state.rehydrate(unsorted) ~= nil, "a stored reviewer list in owner order restores")
	local before_override = runtime.json.encode(f.authority.registry)
	check(save({ role_guidance_put = { role = "builder", text = "Retired override." } }).code == "invalid_command"
		and save({ policy = { role_guidance = {} } }).code == "invalid_policy"
		and runtime.json.encode(f.authority.registry) == before_override,
		"retired role override commands and policy fields have no active edit path")
	-- Retired settings: absent from canonical defaults, refused in new payloads, read only from a previous store.
	check(defaults.glitch_project_discovery == nil and defaults.default_work_source == nil
		and dispatch.default_policy().glitch_project_discovery == nil and dispatch.default_policy().default_work_source == nil,
		"fresh canonical defaults carry neither retired setting")
	for _, retired in { { "glitch_project_discovery", true }, { "default_work_source", "board" }, { "default_work_source", "glitch_plan" } } do
		local before_retired = runtime.json.encode(f.authority.registry)
		check(save({ policy = { [retired[1]] = retired[2] } }).code == "invalid_policy" and runtime.json.encode(f.authority.registry) == before_retired,
			"a new policy payload carrying " .. retired[1] .. " is refused with nothing changed")
		local bad = clone(saved()); bad[retired[1]] = retired[2]
		check(not dispatch.valid_policy(bad), retired[1] .. " is not part of the current policy shape")
	end
	do
		-- A store saved by the previous version still validates, then migrates; unrelated explicit values survive; a second restore is stable.
		assert(save({ policy = { loop_cap = 3, concurrency_limit = 2 } }).ok)
		local previous = clone(f.authority.registry)
		previous.dispatch.policies[sid].glitch_project_discovery = false
		previous.dispatch.policies[sid].default_work_source = "glitch_plan"
		check(dispatch.previous_policy(previous.dispatch.policies[sid]) and dispatch.valid(previous.dispatch, previous),
			"the previous exact keyset is a recognized historical read shape")
		local first = state.rehydrate(clone(previous))
		check(first ~= nil, "a previous-version store restores instead of being rejected before migration")
		local policy = first.dispatch.policies[sid]
		check(policy.glitch_project_discovery == nil and policy.default_work_source == nil and policy.loop_cap == 3 and policy.concurrency_limit == 2,
			"migration drops both retired settings and keeps unrelated explicit values")
		check(dispatch.valid_policy(policy) and not dispatch.previous_policy(policy), "the migrated policy is the current shape")
		local second = state.rehydrate(clone(first))
		check(second ~= nil and runtime.json.encode(second.dispatch.policies[sid]) == runtime.json.encode(policy)
			and second.installation_defaults.policy.default_work_source == nil, "a second restore is stable")
		-- The previous shape with the legacy family flag also migrates.
		local variant = clone(previous.dispatch.policies[sid])
		variant.enforce_cross_family = variant.require_other_family; variant.require_code_review = nil; variant.require_other_family = nil
		check(dispatch.valid_policy(variant, true) and dispatch.migrate_policy(variant).default_work_source == nil,
			"the previous shape's enforce-cross-family variant is still read at the restore boundary")
		-- Both save scopes: the reusable default is a previous-shaped store too.
		local previous_defaults = clone(f.authority.registry)
		previous_defaults.installation_defaults.policy.glitch_project_discovery = true
		previous_defaults.installation_defaults.policy.default_work_source = "board"
		local restored_defaults = state.rehydrate(clone(previous_defaults))
		check(restored_defaults ~= nil and restored_defaults.installation_defaults.policy.glitch_project_discovery == nil
			and restored_defaults.installation_defaults.policy.default_work_source == nil, "a previous-shaped installation default migrates the same way")
		-- Adding the historical shape does not relax the preferred-record consistency check that already held for it.
		local mismatched = clone(previous_defaults)
		mismatched.installation_defaults.policy.preferred_worker_record = "record-a"; mismatched.installation_defaults.builder_record = "record-b"
		check(state.rehydrate(mismatched) == nil, "a previous-shaped default with inconsistent preferred records is still refused")
	end
	local before_two = runtime.json.encode(f.authority.registry)
	check(save({ policy = { loop_cap = 3 }, template_remove = "t01" }).code == "invalid_policy" and runtime.json.encode(f.authority.registry) == before_two,
		"two edits in one save are refused")
	-- Bad templates through the same policy command.
	local function template(id, prompt_len, next_id)
		return { id = id, title = "Template " .. id, prompt = string.rep("x", prompt_len - 7) .. "{input}", output = "out/" .. id .. ".md", next = next_id or "", custom_fields = {} }
	end
	for _, bad in { (function() local t = template("t01", 32); t.prompt = "no placeholder"; return t end)(),
		(function() local t = template("t01", 32); t.prompt = "{input} twice {input}"; return t end)(), template("t01", 4097),
		(function() local t = template("t01", 32); t.title = string.rep("T", 81); return t end)(),
		(function() local t = template("t01", 32); t.output = "/abs/path.md"; return t end)(),
		(function() local t = template("t01", 32); t.output = string.rep("o", 257); return t end)(), template("t01", 32, "t99") } do
		local before = runtime.json.encode(f.authority.registry)
		check(save({ template_put = bad }).code ~= "policy_updated" and runtime.json.encode(f.authority.registry) == before, "an invalid template is refused with nothing changed")
	end
	check(save({ template_put = template("t01", 4096) }).code == "policy_updated" and #saved().templates == 1, "a template at the 4096-byte prompt bound is accepted")
	check(save({ template_put = template("t02", 64, "t01") }).code == "policy_updated", "a template may chain to an existing template")
	check(save({ template_remove = "t01" }).code == "template_referenced" and #saved().templates == 2, "a template another template chains to cannot be removed")
	check(save({ template_remove = "t99" }).code == "template_unknown", "removing an unknown template is refused")
	check(save({ template_remove = "t02" }).code == "policy_updated" and save({ template_remove = "t01" }).code == "policy_updated" and #saved().templates == 0,
		"unreferenced templates remove in order")
	-- Aggregate bound: the canonical policy may be at most 48 KiB. Templates within their own
	-- bounds fill it; editing one template's prompt changes the canonical size byte for byte.
	local LIMIT = 49152
	local function size() return #quota.canonical(saved()) end
	local prompts, order = {}, {}
	local function put(id, length) local outcome = save({ template_put = template(id, length) }); if outcome.code == "policy_updated" then if not prompts[id] then table.insert(order, id) end; prompts[id] = length end; return outcome end
	local index = 0
	while true do
		index += 1; assert(index <= 16, "templates never reached the aggregate bound")
		local before = runtime.json.encode(f.authority.registry)
		local outcome = put(string.format("t%02d", index), 4096)
		if outcome.code ~= "policy_updated" then
			check(outcome.code == "policy_too_large" and runtime.json.encode(f.authority.registry) == before, "a policy over 48 KiB within every per-field bound is refused with nothing changed")
			break
		end
	end
	-- Make room, add the refused template small, then grow prompts until exactly at the bound.
	assert(put(order[#order], 7).ok)
	assert(put(string.format("t%02d", index), 7).ok, "a small template fits after making room")
	for _, id in order do
		local gap = LIMIT - size()
		if gap <= 0 then break end
		assert(put(id, math.min(4096, prompts[id] + gap)).ok)
	end
	check(size() == LIMIT, "a policy of exactly 48 KiB is accepted")
	local grow; for _, id in order do if prompts[id] < 4096 then grow = id end end
	local before = runtime.json.encode(f.authority.registry)
	check(grow ~= nil and put(grow, prompts[grow] + 1).code == "policy_too_large" and runtime.json.encode(f.authority.registry) == before,
		"one byte over 48 KiB is refused with nothing changed")
	assert(put(grow, prompts[grow] - 1).ok)
	check(size() == LIMIT - 1, "one byte under 48 KiB is accepted")
	for index2 = #order, 1, -1 do assert(save({ template_remove = order[index2] }).ok) end
	-- Stale editors stay fenced for the new keys.
	local displayed = saved()
	assert(save({ policy = { loop_cap = 4 } }).code == "policy_updated")
	local before = runtime.json.encode(f.authority.registry)
	check(save({ policy = { loop_cap = 5 }, expected_policy_sha256 = quota.digest(displayed) }).code == "policy_conflict"
		and runtime.json.encode(f.authority.registry) == before, "a stale editor cannot overwrite a new key; nothing changes")
	check(save({ policy = { loop_cap = 5 }, expected_policy_sha256 = quota.digest(saved()) }).code == "policy_updated" and saved().loop_cap == 5,
		"the current editor saves the new key")
	local fence_before = runtime.json.encode(f.authority.registry)
	check(save({ policy = { loop_cap = 6 }, expected_policy = displayed }).code == "invalid_command" and runtime.json.encode(f.authority.registry) == fence_before,
		"the removed full expected_policy fence is refused by the closed event check")
	check(save({ policy = { loop_cap = 6 }, template_put = template("t50", 32) }).code == "invalid_policy" and runtime.json.encode(f.authority.registry) == fence_before,
		"a save carrying both a policy patch and a template edit is refused")
	check(state.rehydrate(clone(f.authority.registry)) ~= nil, "the saved v4 policy restores")
end
-- Contract L loop caps present in 0.3.0: each loop runs exactly loop_cap times, the next attempt
-- opens one loop_cap gate naming the loop; allow_more resets the counter, stop keeps it stopped.
local function loop_gates(f, name)
	local found = {}
	for key, g in f.authority.registry.dispatch.gates or {} do
		if g.kind == "loop_cap" and table.find(g.evidence, "loop:" .. name) then table.insert(found, key) end
	end
	return found
end
local function open_loop_gates(f, name)
	local n = 0
	for _, key in loop_gates(f, name) do if f.authority.registry.dispatch.gates[key].phase == "pending" then n += 1 end end
	return n
end
local function answer_gate(f, gid, choice)
	local g = f.authority.registry.dispatch.gates[gid]
	local label; for _, option in g.options do if option.id == choice then label = option.label end end
	return f:apply("answer", { gate_id = gid, gate_revision = g.revision, choice_id = choice, answer = label or choice })
end
local function starts(text, prefix) return type(text) == "string" and text:sub(1, #prefix) == prefix end
-- A worker retains at most 16 report receipts. Loops that send many reports publish the owed
-- acknowledgements and settle a receipt watermark before each cycle so the bound never trips.
local function settle_receipts(f, id)
	for _ = 1, 16 do
		local owed = false
		for _, receipt in worker_of(f, id).receipts do if receipt.publish then owed = true end end
		if not owed then break end
		local queued = f:apply("poll", { worker_id = id }); assert(queued.ok, queued.message)
		local op = f:action(queued.action_id).request.op
		assert(op == "mailbox_publish_ack" or op == "mailbox_publish_reply", op)
		assert(f:finish(queued.action_id, "published", {}).ok)
	end
	assert(f:watermark(id).ok)
end
-- loop_caps is split into four sections so each stays inside the runner's 60 s per-section wall bound.
if section == nil or section == "loop_caps_rollover" then
	-- Rollover checkpoint re-request, at cap 1 (stop) and cap 10 (allow_more).
	for _, cap in { 1, 10 } do
		local f, id = rollover_fixture()
		assert(f:apply("policy", { policy = { loop_cap = cap } }).ok)
		local requested = f:apply("rollover", { worker_id = id, trigger = "owner" }); assert(requested.code == "rollover_requested")
		local hid = requested.handover_id
		local early = true
		for attempt = 2, cap do
			settle_receipts(f, id)
			assert(answer_checkpoint(f, id, "loop-cp-" .. attempt, "not_run").ok)
			local again = f:apply("rollover", { worker_id = id, trigger = "owner" })
			early = early and again.code == "checkpoint_rerequested" and open_loop_gates(f, "rollover_checkpoint") == 0
		end
		check(early and rollover_of(f, hid).checkpoint_loop.count == cap, "cap " .. cap .. ": the checkpoint is requested " .. cap .. " times without a loop gate")
		settle_receipts(f, id)
		assert(answer_checkpoint(f, id, "loop-cp-over", "not_run").ok)
		local over = f:apply("rollover", { worker_id = id, trigger = "owner" })
		local g = over.gate_id and f.authority.registry.dispatch.gates[over.gate_id]
		check(over.ok and over.code == "loop_capped" and g and g.kind == "loop_cap" and open_loop_gates(f, "rollover_checkpoint") == 1
			and rollover_of(f, hid).checkpoint_loop.count == cap and rollover_of(f, hid).checkpoint_loop.state == "gated",
			"cap " .. cap .. ": the next re-request opens one loop_cap gate instead")
		check(starts(g.question, "Checkpoint requested " .. cap .. " times without a verified checkpoint; last refusal: verification_missing."),
			"the rollover loop gate names the loop, its count and the last refusal")
		check(g.options[1].id == "allow_more" and g.options[1].label == "Allow " .. cap .. " more attempts" and g.options[2].id == "stop", "the loop gate offers allow_more and stop")
		local repeat_over = f:apply("rollover", { worker_id = id, trigger = "owner" })
		check(repeat_over.code == "loop_capped" and repeat_over.gate_id == over.gate_id and #loop_gates(f, "rollover_checkpoint") == 1, "a further re-request reuses the open gate")
		check(state.rehydrate(clone(f.authority.registry)) ~= nil, "a gated rollover loop restores")
		if cap == 10 then
			check(answer_gate(f, over.gate_id, "allow_more").code == "loop_cap_answered" and f.authority.registry.dispatch.gates[over.gate_id] == nil
				and rollover_of(f, hid).checkpoint_loop.count == 0 and rollover_of(f, hid).checkpoint_loop.state == nil, "allow_more resets the rollover loop")
			check(f:apply("rollover", { worker_id = id, trigger = "owner" }).code == "checkpoint_rerequested", "after allow_more the owner may request the checkpoint again")
		else
			check(answer_gate(f, over.gate_id, "stop").code == "loop_cap_answered" and rollover_of(f, hid).checkpoint_loop.state == "stopped", "stop keeps the rollover loop stopped")
			local gates_before = #loop_gates(f, "rollover_checkpoint")
			local stopped = f:apply("rollover", { worker_id = id, trigger = "owner" })
			check(not stopped.ok and stopped.code == "loop_stopped" and open_loop_gates(f, "rollover_checkpoint") == 0 and #loop_gates(f, "rollover_checkpoint") == gates_before
				and rollover_of(f, hid).phase == "checkpoint_pending", "a stopped rollover loop refuses the re-request, opens no new gate and stays held")
		end
	end
end
if section == nil or section == "loop_caps_retry" then
	-- Owner retry of full backpressure, at cap 1 and cap 10.
	local FULL = { resource = "window_authorization", current = 1, limit = 1, retryable = true, effect_started = false }
	for _, cap in { 1, 10 } do
		local f = fixture(); f:catalog(0)
		assert(f:apply("policy", { policy = { loop_cap = cap } }).ok)
		local queued = f:queue(false); assert(queued.ok, queued.message)
		assert(f:finish(queued.action_id, "provisioned", { handle = "mailbox-retry", binding_digest = string.rep("e", 64),
			capabilities = runtime.json.array({ "report-files-v1", "native-ask-v1" }), limits = {} }).ok)
		local launch = f.authority.registry.dispatch.workers[queued.worker_id].launch_action_id
		assert(f:finish(launch, "full", FULL).code == "backpressure")
		local early = true
		for _ = 1, cap do
			local retried = f:apply("retry", { action_id = launch, trigger = "owner" })
			early = early and retried.ok and open_loop_gates(f, "full_retry") == 0
			launch = assert(retried.action_id)
			check(f:apply("claim", { action_id = launch, executor = f.origin.window_epoch }).code == "peer_reconcile_required",
				"worker-bound native retry cannot issue while the old pre-effect result is still unacknowledged by the peer")
			assert(f:control("reconcile_session").ok)
			early = early and f:finish(launch, "full", FULL).code == "backpressure"
		end
		check(early and f:action(launch).retry_loop.count == cap, "cap " .. cap .. ": " .. cap .. " owner retries of full backpressure run without a loop gate")
		local over = f:apply("retry", { action_id = launch, trigger = "owner" })
		local g = over.gate_id and f.authority.registry.dispatch.gates[over.gate_id]
		check(over.code == "loop_capped" and g and g.kind == "loop_cap" and f:action(launch).phase == "backpressure" and f:action(launch).retry_loop.count == cap,
			"cap " .. cap .. ": the next owner retry opens a loop_cap gate and the action stays in backpressure")
		check(starts(g.question, "Owner retry of full backpressure reached " .. cap .. " attempts; last error: full:window_authorization."), "the retry loop gate names the loop and the last error")
		local automatic = f:apply("retry", { action_id = launch }); assert(automatic.ok); launch = automatic.action_id
		check(f:action(launch).retry_loop.count == cap, "automatic recheck uses a fresh identity without counting or bypassing the live owner loop decision")
		assert(f:control("reconcile_session").ok)
		check(state.rehydrate(clone(f.authority.registry)) ~= nil, "a gated retry loop restores")
		if cap == 1 then
			if f:action(launch).phase ~= "backpressure" then assert(f:finish(launch, "full", FULL).code == "backpressure") end
			check(answer_gate(f, over.gate_id, "stop").code == "loop_cap_answered" and f:action(launch).retry_loop.state == "stopped", "stop keeps the retry loop stopped")
			local shown = dispatch.project(f.authority.registry, f.origin.logical_session_id, f.origin.alias_nonce).actions[launch]
			check(shown ~= nil and shown.retry_loop ~= nil and shown.retry_loop.state == "stopped" and shown.retry_loop.count == cap and shown.retry_loop.gate_id == nil,
				"the projected action carries its stopped retry loop")
			local gates_before = #loop_gates(f, "full_retry")
			local stopped = f:apply("retry", { action_id = launch, trigger = "owner" })
			check(not stopped.ok and stopped.code == "loop_stopped" and #loop_gates(f, "full_retry") == gates_before and f:action(launch).phase == "backpressure",
				"a stopped retry loop refuses the owner retry and opens no new gate")
		end
	end
end
if section == nil or section == "loop_caps_retry" then
	-- Automatic capacity rechecks (no owner trigger) neither count toward the owner retry cap nor open its gate.
	local FULL = { resource = "window_authorization", current = 1, limit = 1, retryable = true, effect_started = false }
	local f = fixture(); f:catalog(0)
	assert(f:apply("policy", { policy = { loop_cap = 1 } }).ok)
	local queued = f:queue(false); assert(queued.ok, queued.message)
	assert(f:finish(queued.action_id, "provisioned", { handle = "mailbox-auto", binding_digest = string.rep("e", 64),
		capabilities = runtime.json.array({ "report-files-v1", "native-ask-v1" }), limits = {} }).ok)
	local launch = f.authority.registry.dispatch.workers[queued.worker_id].launch_action_id
	assert(f:finish(launch, "full", FULL).code == "backpressure")
	for round = 1, 2 do
		local automatic = f:apply("retry", { action_id = launch })
		check(automatic.ok and automatic.code ~= "loop_capped" and open_loop_gates(f, "full_retry") == 0,
			"automatic recheck " .. round .. " at loop_cap 1 opens no owner retry gate")
		launch = assert(automatic.action_id)
		check((f:action(launch).retry_loop or { count = 0 }).count == 0, "automatic recheck " .. round .. " leaves the owner retry count at zero")
		assert(f:apply("claim", { action_id = launch, executor = f.origin.window_epoch }).code == "peer_reconcile_required")
		assert(f:control("reconcile_session").ok)
		assert(f:finish(launch, "full", FULL).code == "backpressure")
	end
	local owner = f:apply("retry", { action_id = launch, trigger = "owner" })
	check(owner.ok and open_loop_gates(f, "full_retry") == 0, "the first owner retry still runs after automatic rechecks")
end
if section == nil or section == "loop_caps_reports" then
	-- Automatic report requests without a new report, at cap 1 and cap 10.
	for _, cap in { 1, 10 } do
		local clock = { now_ms = 1000, mono_ms = 1000, epoch = "report-loop-host" }
		local f = fixture(function() return clone(clock) end); local id = f:accepted(false)
		assert(f:apply("policy", { policy = { loop_cap = cap } }).ok)
		-- The automatic scheduler marks this worker due once it is idle and heartbeat_ms has passed.
		local function due_after_heartbeat()
			assert(f:apply("policy", { policy = { automatic_reports = true, report_request_ms = 5000, stale_ms = 600000 } }).ok)
			assert(f:apply("observe", { worker_id = id, pane_binding = clone(worker_of(f, id).pane_binding), native_state = "idle" }).ok)
			clock.mono_ms += 6000; clock.now_ms += 6000
			assert(f:tick().ok)
			for _, shown in dispatch.project(f.authority.registry, f.origin.logical_session_id, f.origin.alias_nonce).workflow.workers do
				if shown.worker_id == id then return shown.due_report end
			end
			error("worker missing from projection")
		end
		local function cycle()
			settle_receipts(f, id)
			assert(f:apply("observe", { worker_id = id, pane_binding = clone(worker_of(f, id).pane_binding), native_state = "idle" }).ok)
			local sent = f:apply("reply", { worker_id = id, trigger = "policy" })
			if sent.code == "loop_capped" or not sent.ok then return sent end
			local request = clone(worker_of(f, id).workflow.report_request)
			assert(send_report(f, id, "reply_ack", { message_id = request.message_id, reply_seq = request.reply_seq, reply_sha256 = codec.sha256(request.bytes), status = "recorded" },
				{ action_id = request.action_id, action_revision = request.action_revision }).ok)
			assert(send_report(f, id, "HEARTBEAT", { state = "working", request_id = request.request_id }).ok)
			return sent
		end
		local early = true
		for _ = 1, cap do early = early and cycle().ok and open_loop_gates(f, "report_request") == 0 end
		check(early and worker_of(f, id).workflow.report_loop.count == cap, "cap " .. cap .. ": " .. cap .. " answered requests without a new report open no gate")
		local over = cycle()
		local g = over.gate_id and f.authority.registry.dispatch.gates[over.gate_id]
		check(over.ok and over.code == "loop_capped" and g and g.kind == "loop_cap", "cap " .. cap .. ": the next automatic request opens a loop_cap gate and issues nothing")
		check(starts(g.question, "Report requested " .. cap .. " times without a new report."), "the report loop gate names the loop")
		check(cycle().gate_id == over.gate_id and #loop_gates(f, "report_request") == 1, "a further automatic request reuses the open gate")
		if cap == 1 then
			-- A new report clears the loop record entirely (no record = count 0, not gated).
			local reset = send_report(f, id, "READY", { state = "idle", summary = "New progress" })
			local loop = worker_of(f, id).workflow.report_loop
			check(reset.ok and (loop == nil or (loop.count == 0 and loop.state == nil)) and f.authority.registry.dispatch.gates[over.gate_id] == nil,
				"a new unsolicited report resets the loop and supersedes its gate")
			check(worker_of(f, id).workflow.report_request == nil and due_after_heartbeat() == true, "after a reset an idle worker past heartbeat_ms is due for an automatic report")
			check(cycle().code ~= "loop_capped", "after a new report the next automatic request is sent")
		else
			check(answer_gate(f, over.gate_id, "stop").code == "loop_cap_answered" and worker_of(f, id).workflow.report_loop.state == "stopped", "stop keeps the report loop stopped")
			check(f:apply("reply", { worker_id = id, trigger = "policy" }).code == "loop_stopped", "a stopped report loop refuses automatic requests")
			check(worker_of(f, id).workflow.report_request == nil and due_after_heartbeat() == false,
				"a stopped report loop is never marked due by the automatic scheduler, even when idle past heartbeat_ms")
			check(f:apply("reply", { worker_id = id }).ok, "an owner request is not an automatic request and still runs")
		end
		check(state.rehydrate(clone(f.authority.registry)) ~= nil, "the report loop restores")
	end
end
if section == nil or (section ~= nil and string.sub(section, 1, 18) == "loop_caps_landing_") then
	-- Landing refresh cycles (stale_target) at cap 1 and cap 3, and the transport bound of 8 grants.
	-- Grants need Rule H proof (review required, other family optional: a passing helper CHECK_RESULT for every
	-- declared check at the source revision plus an approved review from a reviewer worker) and go to
	-- the session's release manager (record "release", provisioned with release-manager-v1), never the
	-- builder. Every cycle requests the same proven revision; a refresh voids the review, so a cycle
	-- after a refresh re-reviews it.
	local LREV = string.rep("c", 40)
	local LCAPS = { "report-files-v1", "native-ask-v1", "coordinator-control-v1", "project-start-v1", "check-runner-v1", "release-manager-v1" }
	local function lcp(cp_id)
		return { checkpoint_id = cp_id, task_ref = "task:fixture", project_id = "project-one", worktree_ref = "/fixture", artifact_revision = LREV,
			completed = runtime.json.array({ "Implemented the assigned change" }), remaining = runtime.json.array(), holds = runtime.json.array(),
			checks = runtime.json.array({ { check_id = "unit", artifact_revision = LREV, outcome = "passed", evidence_ref = "unit:log" } }) }
	end
	local function item(f, lid) return f.authority.registry.dispatch.landing.items[lid] end
	local function lfixture()
		local f = fixture()
		local r = f:apply("catalog"); assert(r.ok, r.message)
		local records = {}
		for _, record_id in { "native", "reviewer", "release" } do
			table.insert(records, { id = record_id, revision = 0, provider = "omp", account_label = "configured, not verified", backend = "native-agent", enabled = true, eligible = true,
				capability_evidence = "configured_operator_attestation_not_runtime_proof", effective_identity = { provider = "omp", identity_status = "configured_not_verified" },
				capabilities = runtime.json.array(LCAPS), unsupported = runtime.json.array(), cwd = "/fixture", placement = "split" })
		end
		assert(f:finish(r.action_id, "catalog", { catalog_version = 2, setup = catalog_setup(0), namespace = "fixture-spawn", host_key = "fixture-host", config_revision = 0, revision = 0, records = runtime.json.array(records) }).ok)
		assert(f:apply("policy", { policy = { require_code_review = true, require_other_family = false, reviewer_records = runtime.json.array({ "reviewer" }), release_manager_record = "release" } }).ok)
		f.default_project = f:project("Landing fixture project", true)
		local project = f.authority.registry.dispatch.projects[f.default_project]
		assert(f:apply("project_repository", { orch_project_id = project.orch_project_id, project_revision = project.revision,
			repository = { cwd = "/fixture", repo_root = "/fixture", common_dir = "/fixture/.git",
				target_ref = "refs/heads/main", head_revision = LREV, queue_route = "orch_queue" } }).ok)
		return f
	end
	local function lstart(f, coordinator, pane)
		local event = { record_id = "native", record_revision = 0, catalog_revision = 0, prompt = "Complete the explicit landing fixture assignment.", cwd = "/fixture",
			placement = "split", coordinator = coordinator }
		if not coordinator then event.checks = runtime.json.array({ { check_id = "unit", argv = runtime.json.array({ "luau", "tests/run.luau" }) } }) end
		local queued = f:allow_shared_fixture(f:apply("queue", event)); assert(queued.ok and queued.action_id, queued.message)
		local id = queued.worker_id
		assert(f:finish(queued.action_id, "provisioned", { handle = "mailbox-landing-" .. pane, binding_digest = string.rep("d", 64),
			capabilities = runtime.json.array(LCAPS), limits = {}, manifest_sha256 = worker_of(f, id).manifest_sha256 }).ok)
		assert(f:finish(worker_of(f, id).launch_action_id, "awaiting_acceptance", { pane_binding = { pane_id = pane, window_key = f.origin.window_key,
			window_epoch = f.origin.window_epoch, native_session_id = f.origin.native_session_id, window_host_id = f.origin.window_host_id } }).ok)
		assert(f:apply("intake", { worker_id = id, bytes = f:report(id, 1, "ACCEPTED", { assignment_sha256 = worker_of(f, id).assignment_sha256 }) }).ok)
		assert(f:finish(f:apply("poll", { worker_id = id }).action_id, "published", {}).ok)
		assert(f:finish(f:apply("poll", { worker_id = id }).action_id, "accepted", {}).ok)
		return id
	end
	local function lack(f, id, delivery)
		return send_report(f, id, "reply_ack", { message_id = delivery.message_id, reply_seq = delivery.reply_seq, reply_sha256 = codec.sha256(delivery.bytes), status = "recorded" },
			{ action_id = delivery.action_id, action_revision = delivery.action_revision })
	end
	-- One approved REVIEW_RESULT at LREV from the fresh reviewer worker ORCH+ queues on the builder's REVIEW_READY.
	local function lreview(f, id, cp_id)
		assert(send_report(f, id, "REVIEW_READY", { checkpoint_id = cp_id, artifact_revision = LREV }).ok)
		local rv
		for _, candidate in f.authority.registry.dispatch.reviews do if candidate.builder_work_id == worker_of(f, id).work_id and candidate.status == "queued" then rv = candidate end end
		assert(rv, "REVIEW_READY queued no review")
		local c, provision = rv.reviewer_worker_id, nil
		if not c then for key, w in f.authority.registry.dispatch.workers do if w.role == "reviewer" and w.review_id == rv.review_id and w.phase == "queued" then c = key end end end
		for key, a in f.authority.registry.dispatch.actions do if a.worker_id == c and a.request.op == "mailbox_provision" and a.phase == "ready" then provision = key end end
		assert(f:finish(assert(provision, "reviewer provision missing"), "provisioned", { handle = "mailbox-reviewer-" .. id, binding_digest = string.rep("d", 64),
			capabilities = runtime.json.array(LCAPS), limits = {}, manifest_sha256 = worker_of(f, c).manifest_sha256 }).ok)
		assert(f:finish(worker_of(f, c).launch_action_id, "awaiting_acceptance", { pane_binding = { pane_id = "99" .. id:match("(%d+)$"), window_key = f.origin.window_key,
			window_epoch = f.origin.window_epoch, native_session_id = f.origin.native_session_id, window_host_id = f.origin.window_host_id } }).ok)
		assert(f:apply("intake", { worker_id = c, bytes = f:report(c, 1, "ACCEPTED", { assignment_sha256 = worker_of(f, c).assignment_sha256 }) }).ok)
		assert(f:finish(f:apply("poll", { worker_id = c }).action_id, "published", {}).ok)
		assert(f:finish(f:apply("poll", { worker_id = c }).action_id, "accepted", {}).ok)
		local request = clone(f.authority.registry.dispatch.reviews[rv.review_id].request); assert(request, "review_request missing")
		local retained = worker_of(f, c).replies[tostring(request.reply_seq)]
		assert(lack(f, c, { message_id = request.message_id, reply_seq = request.reply_seq, bytes = retained.bytes, action_id = request.action_id, action_revision = request.action_revision }).ok)
		assert(send_report(f, c, "REVIEW_RESULT", { review_id = rv.review_id, round = request.round, artifact_revision = LREV, outcome = "approved", findings = runtime.json.array() },
			{ action_id = request.action_id, action_revision = request.action_revision }).ok)
	end
	-- A builder whose LREV already carries the full Rule H proof.
	local function lbuilder(f, pane)
		local id = lstart(f, false, pane)
		assert(send_report(f, id, "CHECKOUT", { worktree_path = "/fixture", common_dir = "/fixture/.git", branch = "refs/heads/work", head = LREV,
			changed_files = runtime.json.array(), changed_overflow = false, changed_total = 0, dirty = false }).ok)
		assert(send_report(f, id, "CHECKPOINT", lcp("cp-0")).ok)
		assert(send_report(f, id, "CHECK_RESULT", { check_id = "unit", argv_sha256 = codec.sha256("argv"), exit_code = 0, output_sha256 = codec.sha256("unit output"),
			head = LREV, ran_at_ms = 1 }).ok)
		lreview(f, id, "cp-0")
		return id
	end
	-- Launch the release manager ORCH+ queued for the first grantable item (once per session).
	local function lrm(f)
		for key, w in f.authority.registry.dispatch.workers do
			if w.role == "release_manager" and w.phase == "queued" then
				for aid, a in f.authority.registry.dispatch.actions do
					if a.worker_id == key and a.request.op == "mailbox_provision" and a.phase == "ready" then
						assert(f:finish(aid, "provisioned", { handle = "mailbox-release-" .. key, binding_digest = string.rep("d", 64),
							capabilities = runtime.json.array(LCAPS), limits = {}, manifest_sha256 = w.manifest_sha256 }).ok)
						assert(f:finish(worker_of(f, key).launch_action_id, "awaiting_acceptance", { pane_binding = { pane_id = "9800", window_key = f.origin.window_key,
							window_epoch = f.origin.window_epoch, native_session_id = f.origin.native_session_id, window_host_id = f.origin.window_host_id } }).ok)
						assert(f:apply("intake", { worker_id = key, bytes = f:report(key, 1, "ACCEPTED", { assignment_sha256 = worker_of(f, key).assignment_sha256 }) }).ok)
						assert(f:finish(f:apply("poll", { worker_id = key }).action_id, "published", {}).ok)
						assert(f:finish(f:apply("poll", { worker_id = key }).action_id, "accepted", {}).ok)
						break
					end
				end
			end
		end
	end
	local function approved(f, id)
		for _, rv in f.authority.registry.dispatch.reviews or {} do
			if rv.builder_work_id == worker_of(f, id).work_id and rv.status == "approved" and rv.void == nil and rv.artifact_revision == LREV then return true end
		end
		return false
	end
	local function landing_cycle(f, id, k, head)
		-- Consume both the exact approval decision and landing refresh; publication alone is not a producer ACK.
		local owed = {}
		for _, retained in worker_of(f, id).replies do
			local reply = not retained.acknowledged and codec.decode_reply(retained.bytes, worker_of(f, id))
			if reply and (reply.kind == "landing_refresh" or reply.kind == "owner_decision") then table.insert(owed, { message_id = reply.message_id, reply_seq = reply.reply_seq, bytes = retained.bytes,
				action_id = reply.action_id, action_revision = reply.action_revision }) end
		end
		for _, delivery in owed do settle_receipts(f, id); assert(lack(f, id, delivery).ok) end
		settle_receipts(f, id)
		assert(send_report(f, id, "CHECKPOINT", lcp("cp-" .. k)).ok)
		if not approved(f, id) then settle_receipts(f, id); lreview(f, id, "cp-" .. k) end
		settle_receipts(f, id)
		assert(send_report(f, id, "LANDING_REQUEST", { checkpoint_id = "cp-" .. k, project_id = "project-one", repo_ref = "repo:fixture", target_ref = "refs/heads/main",
			target_revision = head, source_ref = "refs/heads/cp-" .. k, source_revision = LREV }).ok)
		local lid
		for key, candidate in f.authority.registry.dispatch.landing.items do
			if candidate.work_id == worker_of(f, id).work_id and not table.find({ "landed", "cancelled", "rejected" }, candidate.status) then lid = key end
		end
		assert(lid, "landing item missing")
		local approval = f.authority.registry.dispatch.gates[item(f, lid).gate_id]
		assert(f:apply("answer", { gate_id = approval.id, gate_revision = approval.revision, choice_id = "approve", answer = "Owner approves this exact request." }).ok)
		lrm(f)
		return lid
	end
	-- The release manager holding the item's grant consumes it and reports stale_target.
	local function stale(f, _, lid, observed)
		local it = item(f, lid); local gr = it.grants[#it.grants]; local rm = gr.worker_id
		settle_receipts(f, rm)
		assert(send_report(f, rm, "reply_ack", { message_id = gr.message_id, reply_seq = gr.reply_seq, reply_sha256 = codec.sha256(gr.bytes), status = "recorded" },
			{ action_id = gr.action_id, action_revision = gr.action_revision }).ok)
		return send_report(f, rm, "LANDING_RESULT", { landing_id = lid, grant_id = gr.grant_id, project_id = it.request.project_id, repo_ref = it.request.repo_ref,
			target_ref = it.request.target_ref, target_revision = gr.target_revision, source_revision = gr.source_revision, outcome = "stale_target",
			observed_target_revision = observed, evidence = runtime.json.array({ "log:fixture" }) }, { action_id = gr.action_id, action_revision = gr.action_revision })
	end
	if section == nil or section == "loop_caps_landing_migration" then
	do
		local f = lfixture(); local id = lbuilder(f, "9002")
		local lid = landing_cycle(f, id, "migration", "head-0")
		local grant = item(f, lid).grants[1]
		check(grant ~= nil and state.rehydrate(clone(f.authority.registry)) ~= nil,
			"a current-policy outstanding grant survives ordinary restore")
		local function historical(registry, old)
			local legacy = clone(registry)
			local p = legacy.dispatch.policies[f.origin.logical_session_id]
			p.require_code_review = nil; p.require_other_family = nil; p.enforce_cross_family = old
			return legacy
		end
		for _, old in { true, false } do
			local legacy = historical(f.authority.registry, old)
			local exact = runtime.json.encode(legacy)
			local restored = state.rehydrate(legacy)
			check(restored == nil, "current immutable-grant store rejects historical-shaped policy corruption instead of invoking migration")
			check(runtime.json.encode(legacy) == exact and legacy.dispatch.landing.items[lid].grants[1].bytes == grant.bytes,
				"blocked migration neither rewrites grant bytes nor partially migrates its input")
		end
		local prior = clone(f.authority.registry); prior.version = 2
		check(state.rehydrate(prior) == nil, "changing only the version cannot turn current v2 dispatch envelopes and grant authority into a valid legacy source")
		assert(stale(f, id, lid, "head-1").ok)
		local drained = historical(f.authority.registry, false)
		check(state.rehydrate(drained) == nil and drained.dispatch.landing.items[lid].grants[1].bytes == grant.bytes,
			"settling a grant does not authorize implicit rewriting of an obsolete policy in a current store")
	end
	end
	if section == nil or section == "loop_caps_landing_caps" then
	for _, cap in { 1, 3 } do
		local f = lfixture(); local id = lbuilder(f, "9002")
		assert(f:apply("policy", { policy = { loop_cap = cap } }).ok)
		local head, lid = "head-0", nil
		local early = true
		for k = 1, cap do
			lid = landing_cycle(f, id, k, head); head = "head-" .. k
			early = early and stale(f, id, lid, head).ok and item(f, lid).hold.code == "refresh_required" and open_loop_gates(f, "landing_refresh") == 0
		end
		check(early and item(f, lid).refresh_loop.count == cap, "cap " .. cap .. ": " .. cap .. " stale_target refresh cycles run without a loop gate")
		lid = landing_cycle(f, id, cap + 1, head); head = "head-" .. (cap + 1)
		check(stale(f, id, lid, head).ok and item(f, lid).hold.code == "loop_cap" and item(f, lid).refresh_required and item(f, lid).refresh_loop.state == "gated"
			and item(f, lid).refresh_loop.cause == "stale_target" and open_loop_gates(f, "landing_refresh") == 1, "cap " .. cap .. ": the next stale_target trips the refresh loop")
		local g = f.authority.registry.dispatch.gates[item(f, lid).refresh_loop.gate_id]
		check(starts(g.question, "Landing refresh cycles reached " .. cap .. " for " .. lid .. "; last cause: stale_target."), "the refresh loop gate names the loop, item and cause")
		check(state.rehydrate(clone(f.authority.registry)) ~= nil, "a gated landing refresh loop restores")
		-- allow_more resets the counter and the owed refresh is then issued in the same commit (count 1).
		check(answer_gate(f, g.id, "allow_more").code == "loop_cap_answered" and item(f, lid).refresh_loop.count == 1 and item(f, lid).refresh_loop.state == nil,
			"allow_more resets the refresh loop and the owed refresh is issued, counting once")
	end
	end
	if section == nil or section == "loop_caps_landing_transport" then
	do
		local f = lfixture(); local id = lbuilder(f, "9002")
		assert(f:apply("policy", { policy = { loop_cap = 10 } }).ok)
		local head, lid = "head-0", nil
		local early = true
		for k = 1, 8 do
			lid = landing_cycle(f, id, k, head); head = "head-" .. k
			early = early and #item(f, lid).grants == k and stale(f, id, lid, head).ok and open_loop_gates(f, "landing_grants") == 0
		end
		check(early and item(f, lid).refresh_loop.count == 8, "eight granted cycles stay under loop_cap 10 and open no grant gate")
		lid = landing_cycle(f, id, 9, head)
		local it = item(f, lid)
		check(#it.grants == 8 and it.hold.code == "attempts_exhausted" and it.grant_loop.count == 8 and it.grant_loop.state == "gated" and open_loop_gates(f, "landing_grants") == 1,
			"the ninth grant attempt opens the transport-bound loop gate instead of a grant")
		local g = f.authority.registry.dispatch.gates[it.grant_loop.gate_id]
		check(starts(g.question, "Landing grants reached the transport bound 8 for " .. lid .. ".") and #g.options == 1 and g.options[1].id == "stop",
			"the grants gate names the transport bound and offers only stop")
		check(answer_gate(f, g.id, "stop").code == "loop_cap_answered" and item(f, lid).grant_loop.state == "stopped" and #item(f, lid).grants == 8, "stop keeps the grants stopped")
		check(state.rehydrate(clone(f.authority.registry)) ~= nil, "a stopped grant loop restores")
	end
	end
	-- target_moved notices count on the same refresh counter as stale_target results.
	if section == nil or section == "loop_caps_landing_target_moved" then
	do
		-- Queue order is la, lc, lb: a blocked item keeps its place, so a refreshed lc is granted
		-- ahead of the refreshed lb and its landing moves the head under lb a second time.
		local f = lfixture(); local a = lbuilder(f, "9002")
		local c = lbuilder(f, "9005")
		local b = lbuilder(f, "9004")
		assert(f:apply("policy", { policy = { loop_cap = 1 } }).ok)
		local function land(_, lid, head)
			local it = item(f, lid); local gr = it.grants[#it.grants]
			settle_receipts(f, gr.worker_id)
			return send_report(f, gr.worker_id, "LANDING_RESULT", { landing_id = lid, grant_id = gr.grant_id, project_id = it.request.project_id, repo_ref = it.request.repo_ref,
				target_ref = it.request.target_ref, target_revision = gr.target_revision, source_revision = gr.source_revision, outcome = "landed",
				result_revision = head, evidence = runtime.json.array({ "log:fixture" }) }, { action_id = gr.action_id, action_revision = gr.action_revision })
		end
		local la = landing_cycle(f, a, "a1", "head-0")
		local lc = landing_cycle(f, c, "c1", "head-0")
		local lb = landing_cycle(f, b, "b1", "head-0")
		check(item(f, la).status == "granted" and item(f, lb).status == "ready" and item(f, lb).refresh_loop == nil, "no refresh is counted while the head is unchanged")
		assert(land(a, la, "head-1").ok)
		check(item(f, lb).hold.code == "target_moved" and item(f, lb).refresh_loop.count == 1 and item(f, lb).refresh_loop.cause == "target_moved"
			and open_loop_gates(f, "landing_refresh") == 0, "cap 1: the first target_moved notice counts once and opens no gate")
		check(landing_cycle(f, c, "c2", "head-1") == lc and item(f, lc).status == "granted", "the earlier refreshed request is granted against the new head")
		check(landing_cycle(f, b, "b2", "head-1") == lb and item(f, lb).status == "ready", "the later refreshed request rebinds the same item and waits behind it")
		assert(land(c, lc, "head-2").ok)
		check(item(f, lb).hold.code == "loop_cap" and item(f, lb).refresh_loop.state == "gated" and item(f, lb).refresh_loop.cause == "target_moved"
			and open_loop_gates(f, "landing_refresh") == 1, "cap 1: the second target move trips the refresh loop instead of another notice")
		local g = f.authority.registry.dispatch.gates[item(f, lb).refresh_loop.gate_id]
		check(starts(g.question, "Landing refresh cycles reached 1 for " .. lb .. "; last cause: target_moved."), "the refresh gate names target_moved as the last cause")
		check(state.rehydrate(clone(f.authority.registry)) ~= nil, "a target_moved-gated refresh loop restores")
	end
	end
end
-- Contract A worker fields (CP1 storage): queue-time role/family, strict validators, 0.3.0
-- restore defaults and the rollover successor copy rule.
if section == nil or section == "worker_fields" then
	local A, B = string.rep("a", 64), string.rep("b", 64)
	local valid = {
		class = "docs", template_id = "t01", files = runtime.json.array({ "src/a.luau" }),
		scope = { paths = runtime.json.array({ "src" }), systems = runtime.json.array({ "ci" }) },
		checks = runtime.json.array({ { check_id = "unit", argv = runtime.json.array({ "luau", "tests/run.luau" }) } }),
		source = { kind = "plan", ref = "plan:fixture" }, manifest_sha256 = A,
		checkout = { worktree_path = "/work/tree", common_dir = "/work/.git", branch = "main", head = "abc123", changed_files = runtime.json.array(),
			changed_overflow = false, changed_total = 0, dirty = false },
		check_results = { unit = { check_id = "unit", argv_sha256 = A, exit_code = 0, output_sha256 = B, head = "abc123", ran_at_ms = 1 } },
		usage_before = { account = { canonical_ids = runtime.json.array({ A }), generation = 1 }, windows = runtime.json.array({ { key = "five_hour", remaining = 40, observed_at_ms = 1 } }), observed_at_ms = 1 },
		usage_after = { account = { canonical_ids = runtime.json.array({ A }), generation = 1 }, windows = runtime.json.array(), observed_at_ms = 2 },
	}
	local invalid = {
		role = "admin", family = "Anthropic", class = "Docs", template_id = "T 1", files = runtime.json.array({ string.rep("f", 257) }),
		scope = { paths = runtime.json.array({ "src" }) }, checks = runtime.json.array({ { check_id = "unit", argv = runtime.json.array() } }),
		source = { kind = "jira" }, manifest_sha256 = "xyz",
		checkout = { worktree_path = "relative/tree", common_dir = "/work/.git", branch = "main", head = "abc123", changed_files = runtime.json.array(),
			changed_overflow = false, changed_total = 0, dirty = false },
		check_results = { unit = { check_id = "other", argv_sha256 = A, exit_code = 0, output_sha256 = B, head = "abc123", ran_at_ms = 1 } },
		usage_before = { account = {}, windows = runtime.json.array({ { key = "five_hour", remaining = 101, observed_at_ms = 1 } }), observed_at_ms = 1 },
		usage_after = { account = {}, observed_at_ms = 2 },
	}
	local f = fixture(); local id = f:accepted(false)
	local w = f.authority.registry.dispatch.workers[id]
	check(w.role == "builder" and w.family == nil, "queue sets role builder; an OMP record has no family until the owner maps it")
	for _, name in { "class", "template_id", "files", "scope", "checks", "source", "manifest_sha256", "checkout", "check_results", "usage_before", "usage_after" } do
		check(w[name] == nil, name .. " is absent until a later checkpoint populates it")
	end
	-- A stored manifest digest must match the worker's retained mailbox_provision request (CP2), so a
	-- well-formed digest alone is checked on the seeded rollover predecessor below instead.
	for name, value in valid do
		local good = clone(f.authority.registry); good.dispatch.workers[id][name] = clone(value)
		check(state.rehydrate(good) ~= nil, name .. " accepts its current well-formed value without a retained completed provision transcript")
	end
	for name, value in invalid do
		local bad = clone(f.authority.registry); bad.dispatch.workers[id][name] = clone(value)
		check(state.rehydrate(bad) == nil, name .. " rejects a malformed value")
	end
	local unknown = clone(f.authority.registry); unknown.dispatch.workers[id].reviewer_of = "worker-1"
	check(state.rehydrate(unknown) == nil, "the worker key list stays closed")
	-- Missing roles in a current store are not proof of legacy provenance.
	local legacy = clone(f.authority.registry); legacy.dispatch.workers[id].role = nil; legacy.dispatch.workers[id].family = nil
	local restored = state.rehydrate(clone(legacy))
	check(restored == nil, "a current worker cannot silently acquire a builder role during reload")
	local c = fixture(); local cid = c:accepted(true)
	check(c.authority.registry.dispatch.workers[cid].role == "coordinator", "a queued coordinator gets role coordinator")
	local cl = clone(c.authority.registry); cl.dispatch.workers[cid].role = nil
	local crestored = state.rehydrate(cl)
	check(crestored == nil, "a current worker cannot silently acquire a coordinator role from unrelated markers")
	-- Family comes only from the SPAWN-supplied declaration.
	local m = fixture(); m:catalog(0, "native", nil, "anthropic")
	check(not m:apply("policy", { policy = { family_map = { native = "openai" } } }).ok, "legacy family declarations are not executable policy aliases")
	local mq = m:queue(false); assert(mq.ok, mq.message)
	check(m.authority.registry.dispatch.workers[mq.worker_id].family == "anthropic", "SPAWN declaration binds the queued worker family")
	-- Successor copy: assignment fields copy, family is recomputed, checkout/results/usage never inherit.
	local r, rid = rollover_fixture()
	local pred = r.authority.registry.dispatch.workers[rid]
	for name, value in valid do pred[name] = clone(value) end
	-- Seed the live worker's manifest binding directly: completed provision request bytes are absent.
	local manifest = assert(codec.encode_manifest({ checks = pred.checks, files = pred.files, scope = pred.scope, base_ref = pred.base_ref }))
	pred.manifest_sha256 = codec.sha256(manifest)
	pred.family = "anthropic"
	assert(dispatch.valid(r.authority.registry.dispatch, r.authority.registry), "seeded predecessor fields are valid")
	r:catalog(0, "native", nil, "openai")
	local _, succ_id = rollover_granted(r, rid)
	local succ = r.authority.registry.dispatch.workers[succ_id]
	local copied = succ.role == "builder"
	for _, name in { "class", "template_id", "files", "scope", "checks", "source", "manifest_sha256" } do
		copied = copied and runtime.json.encode(succ[name]) == runtime.json.encode(pred[name])
	end
	check(copied, "the successor copies role, class, template, files, scope, checks, source and manifest")
	check(succ.family == "openai" and pred.family == "anthropic", "the successor's family is recomputed for its record")
	check(succ.checkout == nil and succ.check_results == nil and succ.usage_before == nil and succ.usage_after == nil,
		"the successor reports its own checkout, check results and usage")
	check(state.rehydrate(clone(r.authority.registry)) ~= nil, "predecessor and successor worker fields restore")
end
-- Public reducer boundary regressions: observations are bookkeeping, execution bindings are not.
local function boundary_binding(f, pane)
	return { pane_id = pane or "9020", window_key = f.origin.window_key, window_epoch = f.origin.window_epoch,
		native_session_id = f.origin.native_session_id, window_host_id = f.origin.window_host_id }
end
local function boundary_repository(f, project, cwd, target)
	return f:apply("project_repository", { orch_project_id = project,
		project_revision = f.authority.registry.dispatch.projects[project].revision,
		repository = { cwd = cwd, repo_root = "/fixture/repository", common_dir = "/fixture/repository/.git",
			target_ref = target or "main", head_revision = string.rep("a", 40), queue_route = "orch_queue" } })
end
local function boundary_queue(f, project)
	return f:apply("queue", { orch_project_id = project, record_id = "native", record_revision = 0, catalog_revision = 0,
		prompt = "A bounded independent assignment.", cwd = "/fixture", placement = "split", coordinator = false })
end
local function boundary_v4(f)
	local raw = clone(f.authority.registry)
	raw.version = 4; raw.dispatch.projects = nil; raw.dispatch.finished_projects = nil
	raw.installation_defaults.policy.auto_start_projects = nil; raw.installation_defaults.policy.auto_launch_intake = false
	for _, p in raw.dispatch.policies do p.auto_start_projects = nil; p.auto_launch_intake = false end
	for _, w in raw.dispatch.workers do
		w.orch_project_id = nil; w.presentation = nil; w.selected_record = nil; w.project_held = nil; w.launch_refused = nil
		w.launch_refused_op = nil
	end
	local restored, info = state.rehydrate(raw); must(restored, info)
	f.authority.registry = restored; f.memory.value = clone(restored)
	assert(f:apply("continue_controller", { operator_verified = true }).ok)
	assert(f:control("reconcile_session").ok)
	return restored
end
local function boundary_open(f, project, enrolled)
	local row = f.authority.registry.dispatch.catalogs[f.origin.logical_session_id].records[1]
	local pane = boundary_binding(f)
	local fields = { orch_project_id = project, record_id = row.id, record_revision = row.revision, catalog_revision = 0 }
	if enrolled then fields.pane_binding = pane; fields.delivery = if row.backend == "native-agent" then "native_ask" else "clipboard"
	else fields.prompt = codec.OPEN_CONVERSATION_ASSIGNMENT; fields.cwd = row.cwd; fields.placement = row.placement
		fields.coordinator = false; fields.presentation = "user_new_tab"; fields.open_conversation = true end
	local queued = f:apply(if enrolled then "enrol" else "queue", fields); assert(queued.ok, queued.message)
	assert(f:finish(queued.action_id, "provisioned", { handle = "mailbox-boundary", binding_digest = string.rep("a", 64),
		capabilities = runtime.json.array(clone(row.capabilities)), limits = {} }).ok)
	assert(f:finish(worker_of(f, queued.worker_id).launch_action_id, "awaiting_acceptance", { pane_binding = pane }).ok)
	return queued.worker_id, pane
end
if section == nil or section == "project_observation" then
	local creation = fixture(nil, { passive = true }); creation:catalog(0)
	local other = creation:project("Already running discussion", false)
	local pane = boundary_binding(creation)
	local attached = creation:apply("associate_conversation", { orch_project_id = other,
		project_revision = creation.authority.registry.dispatch.projects[other].revision, pane_binding = pane, active = true })
	assert(attached.ok)
	local selected = creation:event("new_project", { name = "Separate discussion",
		source = { kind = "manual", ref = "/workspace/research", revision = "selected-source" } })
	assert(creation:apply("observe_conversation", { orch_project_id = other,
		project_revision = creation.authority.registry.dispatch.projects[other].revision,
		conversation_id = attached.conversation_id, pane_binding = pane, active = false }).ok)
	selected.command_seq = creation.command_seq + 1; creation.command_seq = selected.command_seq
	local added = creation.authority:apply(selected)
	check(added.ok and creation.authority.registry.dispatch.projects[added.orch_project_id].name == "Separate discussion"
		and not creation.authority.registry.dispatch.projects[added.orch_project_id].started,
		"new project survives unrelated agent observations and remains unstarted")
	creation.authority:apply(selected)
	local matches = 0
	for _, project in creation.authority.registry.dispatch.projects do if project.name == "Separate discussion" then matches += 1 end end
	check(matches == 1, "replaying a project-creation request cannot create another project")
	for _, change in { "name", "source", "policy", "owner", "context" } do
		local f = fixture(nil, { passive = true }); f:catalog(0)
		local event = f:event("new_project", { name = "Selected discussion",
			source = { kind = "manual", ref = "/workspace/research", revision = "selected-source" } })
		if change == "name" then event.name = "Different discussion"
		elseif change == "source" then event.source.ref = "/workspace/different"
		elseif change == "policy" then assert(f:apply("policy", { policy = { quota_reserve_pct = 11 } }).ok)
		elseif change == "owner" then event.origin.owner_generation += 1
		else event.decision_context = nil end
		event.expected_revision = f.authority.registry.revision
		event.command_seq = f.command_seq + 1
		local writes = f.memory.writes
		check(not f.authority:apply(event).ok and f.memory.writes == writes,
			"new project rejects changed " .. change .. " without saving a project")
	end
	for _, command in { "project_start", "answer", "project_associate" } do
		local f = fixture(nil, { passive = true }); f:catalog(0)
		local project = f:project("Stable owner subject", command ~= "project_start")
		local pane = boundary_binding(f)
		local attached = f:apply("associate_conversation", { orch_project_id = project,
			project_revision = f.authority.registry.dispatch.projects[project].revision, pane_binding = pane, active = true })
		assert(attached.ok, attached.message)
		local fields = { orch_project_id = project, project_revision = f.authority.registry.dispatch.projects[project].revision }
		if command == "answer" then
			assert(boundary_queue(f, project).ok)
			local queued = boundary_queue(f, project); assert(queued.ok and queued.code == "task_gated")
			local gate = f.authority.registry.dispatch.gates[worker_of(f, queued.worker_id).launch_gates[1]]
			fields = { gate_id = gate.id, gate_revision = gate.revision, choice_id = "launch_anyway", answer = "Owner coordinates the checkout." }
		elseif command == "project_associate" then
			local held = boundary_queue(f, f:project("Held member", false)); assert(held.ok)
			fields.worker_id = held.worker_id
		end
		local decision = f:event(command, fields)
		local revision = f.authority.registry.dispatch.projects[project].revision
		-- Native idle/working/idle all mean a live association; absence observations also cannot
		-- change the project's task/repository/owner decision subject.
		for _, active in { true, true, true, false, true, false } do
			assert(f:apply("observe_conversation", { orch_project_id = project, project_revision = revision,
				conversation_id = attached.conversation_id, pane_binding = pane, active = active }).ok)
		end
		check(f.authority.registry.dispatch.projects[project].revision == revision
			and dispatch.project(f.authority.registry, f.origin.logical_session_id).projects[project].status == "ACTIVE",
			command .. ": idle/activity observations preserve project identity and ACTIVE display")
		decision.command_seq = f.command_seq + 1; f.command_seq = decision.command_seq
		local applied = f.authority:apply(decision)
		check(applied.ok, command .. ": captured owner decision survives observation-only commits: " .. tostring(applied.code))
		local wrong = clone(pane); wrong.native_session_id = "other-session"
		local before = runtime.json.encode(f.authority.registry)
		check(not f:apply("observe_conversation", { orch_project_id = project,
			project_revision = f.authority.registry.dispatch.projects[project].revision, conversation_id = attached.conversation_id,
			pane_binding = wrong, active = true }).ok and runtime.json.encode(f.authority.registry) == before,
			command .. ": same pane number in another native binding cannot mutate the association")
	end
	local f = fixture(nil, { passive = true }); f:catalog(0)
	local project, pane = f:project("Binding changes are consequential", false), boundary_binding(f)
	local attached = f:apply("associate_conversation", { orch_project_id = project,
		project_revision = f.authority.registry.dispatch.projects[project].revision, pane_binding = pane, active = true }); assert(attached.ok)
	local decision = f:event("project_start", { orch_project_id = project, project_revision = f.authority.registry.dispatch.projects[project].revision })
	assert(f:apply("detach_conversation", { orch_project_id = project, project_revision = f.authority.registry.dispatch.projects[project].revision,
		conversation_id = attached.conversation_id }).ok)
	pane.pane_id = "9021"
	assert(f:apply("associate_conversation", { orch_project_id = project, project_revision = f.authority.registry.dispatch.projects[project].revision,
		pane_binding = pane, active = true }).ok)
	decision.command_seq = f.command_seq + 1; f.command_seq = decision.command_seq
	local writes = f.memory.writes
	check(not f.authority:apply(decision).ok and f.memory.writes == writes, "a changed conversation binding invalidates the old START without writing")
end
if section == nil or section == "project_repository_guards" then
	local function repository_decision()
		local selected = fixture(nil, { passive = true }); selected:catalog(0)
		local project = selected:project("Selected checkout", false)
		local event = selected:event("project_repository", { orch_project_id = project,
			project_revision = selected.authority.registry.dispatch.projects[project].revision,
			repository = { cwd = "/fixture/checkout", repo_root = "/fixture/checkout", common_dir = "/fixture/checkout/.git",
				target_ref = "refs/heads/main", head_revision = string.rep("a", 40), queue_route = "orch_queue" } })
		return selected, project, event
	end
	local progress, selected_project, selected = repository_decision()
	progress:project("Unrelated background bookkeeping", false)
	selected.command_seq = progress.command_seq + 1; progress.command_seq = selected.command_seq
	local saved = progress.authority:apply(selected)
	check(saved.ok and progress.authority.registry.dispatch.projects[selected_project].repository.cwd == "/fixture/checkout",
		"unchanged repository selection survives unrelated authority progress")
	for _, change in { "target", "policy", "project", "owner", "target-policy" } do
		local guarded, project, captured = repository_decision()
		if change == "target" then captured.repository.target_ref = "refs/heads/other"
		elseif change == "policy" then assert(guarded:apply("pause").ok)
		elseif change == "project" then assert(guarded:apply("project_start", { orch_project_id = project, project_revision = captured.project_revision }).ok)
		elseif change == "owner" then captured.origin.window_epoch = "different-window"
		else
			local other = guarded:project("Another target participant", false)
			assert(guarded:apply("project_repository", { orch_project_id = other,
				project_revision = guarded.authority.registry.dispatch.projects[other].revision, repository = clone(captured.repository) }).ok)
		end
		captured.command_seq = guarded.command_seq + 1; guarded.command_seq = captured.command_seq
		local unchanged = runtime.json.encode(guarded.authority.registry)
		check(not guarded.authority:apply(captured).ok and runtime.json.encode(guarded.authority.registry) == unchanged,
			"repository confirmation rejects changed " .. change .. " without changing saved work")
	end
	local f = fixture(nil, { passive = true }); f:catalog(0)
	local project = f:project("Canonical repository subject", true)
	assert(boundary_repository(f, project, "/fixture/worktree", "main").ok)
	local revision = f.authority.registry.dispatch.projects[project].revision
	local decision = f:event("project_start", { orch_project_id = project, project_revision = revision })
	check(boundary_repository(f, project, "/fixture/worktree", "refs/heads/main").code == "no_progress"
		and f.authority.registry.dispatch.projects[project].revision == revision, "canonical target aliases do not retarget or revise a project")
	decision.command_seq = f.command_seq + 1; f.command_seq = decision.command_seq
	check(f.authority:apply(decision).ok, "an equivalent repository refresh preserves the captured START")
	local first = boundary_queue(f, project); assert(first.ok and first.action_id)
	local before = runtime.json.encode(f.authority.registry)
	check(not boundary_repository(f, project, "/fixture/other-tree").ok and runtime.json.encode(f.authority.registry) == before,
		"an unissued retained provision prevents changing its effective execution checkout")
	assert(f:finish(first.action_id, "provisioned", { handle = "mailbox-repository", binding_digest = string.rep("a", 64),
		capabilities = runtime.json.array({ "report-files-v1", "native-ask-v1" }), limits = {} }).ok)
	assert(f:finish(worker_of(f, first.worker_id).launch_action_id, "awaiting_acceptance", { pane_binding = boundary_binding(f) }).ok)
	local gated = boundary_queue(f, project); assert(gated.ok and gated.code == "task_gated")
	before = runtime.json.encode(f.authority.registry)
	check(not boundary_repository(f, project, "/fixture/other-tree").ok and runtime.json.encode(f.authority.registry) == before,
		"open checkout evidence cannot be silently retargeted")
end
if section == nil or section == "migration_start_guards" then
	for _, routed in { false, true } do
		local f = fixture(); f:catalog(0)
		if routed then assert(f:apply("policy", { policy = { quota_routing = true } }).ok) end
		local queued = f:queue(false); assert(queued.ok, queued.message)
		if not routed then assert(f:finish(queued.action_id, "rejected", nil,
			{ code = "unsupported_capability", message = "Provisioning refused before creating a mailbox." }).ok) end
		local old_routing = runtime.json.encode(worker_of(f, queued.worker_id).routing)
		boundary_v4(f); f:catalog(0)
		local w = worker_of(f, queued.worker_id)
		local project = f.authority.registry.dispatch.projects[w.orch_project_id]
		check(not w.project_held, "migration does not recast refused or quota-owned starts as never-issued work")
		assert(f:apply("project_start", { orch_project_id = project.orch_project_id, project_revision = project.revision }).ok)
		check(#actions_of(f, queued.worker_id, "mailbox_provision") == 0
			and (not routed or runtime.json.encode(worker_of(f, queued.worker_id).routing) == old_routing),
			"START neither reissues the refused provision nor overwrites an existing quota decision")
		check(state.rehydrate(clone(f.authority.registry)) ~= nil, "non-replayed migrated decision remains durable")
	end
end
if section == nil or section == "enrol_route_cancel" then
	local f = fixture(nil, { passive = true }); f:catalog(0)
	local project = f:project("Retain the existing conversation", false)
	local id, pane = boundary_open(f, project, true)
	local token = worker_of(f, id).enrolment_token
	f.origin.window_epoch = "continued-controller-window"
	assert(f:apply("continue_controller", { operator_verified = true }).ok)
	assert(f:control("reconcile_session").ok)
	local cancelled = f:apply("cancel_work", { worker_id = id }); assert(cancelled.ok, cancelled.message)
	local request = f:action(cancelled.action_id).request
	check(request.op == "mailbox_retire" and request.origin_binding.window_epoch == f.origin.window_epoch
		and worker_of(f, id).origin_binding.window_epoch == pane.window_epoch and worker_of(f, id).enrolment_token == token,
		"a continued controller revokes only the original exact pending enrollment capability")
	check(state.rehydrate(clone(f.authority.registry)) ~= nil, "new-route enrollment revocation restores before settlement")
	assert(f:finish(cancelled.action_id, "retired", {}).ok)
	local associated
	for _, association in f.authority.registry.dispatch.projects[project].associations do associated = association end
	check(worker_of(f, id).mailbox_retired and associated ~= nil and associated.pane_binding.pane_id == pane.pane_id
		and #actions_of(f, id, "stop") == 0, "positive cleanup preserves the native conversation without native stop or token reissue")
end
if section == nil or section == "project_history_reuse" then
	local f = fixture(nil, { passive = true }); f:catalog(0)
	local project, pane = f:project("A finished research conversation", false), boundary_binding(f)
	assert(f:apply("associate_conversation", { orch_project_id = project,
		project_revision = f.authority.registry.dispatch.projects[project].revision, pane_binding = pane, active = true }).ok)
	assert(f:apply("project_finish", { orch_project_id = project,
		project_revision = f.authority.registry.dispatch.projects[project].revision, result = "Reviewed research result." }).ok)
	local reopened = f:apply("project_reopen", { summary_index = 1 }); assert(reopened.ok)
	check(f:apply("associate_conversation", { orch_project_id = reopened.orch_project_id,
		project_revision = f.authority.registry.dispatch.projects[reopened.orch_project_id].revision, pane_binding = pane, active = true }).ok,
		"finished passive associations do not permanently lock the native pane")
	check(#f.authority.registry.dispatch.finished_projects == 1 and #f.authority.registry.dispatch.finished_projects[1].links == 1,
		"reusing a native conversation preserves its bounded independent finished summary")
	assert(f:apply("detach_conversation", { orch_project_id = reopened.orch_project_id,
		project_revision = f.authority.registry.dispatch.projects[reopened.orch_project_id].revision,
		conversation_id = next(f.authority.registry.dispatch.projects[reopened.orch_project_id].associations) }).ok)
	f:project("Never started, no outcome", false)
	local summary = runtime.json.encode(f.authority.registry.dispatch.finished_projects)
	local close_id = next_id()
	assert(f.authority:apply(f:state_event("begin_close", { close_id = close_id,
		control_origin = { kind = "closing", binding = clone(f.origin), controller_pane = "9001", close_id = close_id } })).ok)
	assert(f.authority:apply(f:state_event("release_controller", { expected_owner_id = f.origin.owner_id, expected_generation = f.origin.owner_generation })).ok)
	assert(f:control("close_session").ok)
	assert(f.authority:apply(f:state_event("confirm_close", { close_id = close_id })).ok)
	check(runtime.json.encode(f.authority.registry.dispatch.finished_projects) == summary,
		"closing empty or never-started projects does not fabricate outcomes or evict real history")
end
if section == nil or section == "project_reserve" then
	local f = fixture(nil, { passive = true }); f:catalog(0)
	local project = f:project("Capacity hold", false)
	local queued = boundary_queue(f, project); assert(queued.ok)
	local function reduce(command, fields, reserved)
		local candidate, result = state.apply(f.authority.registry, f:event(command, fields), { now_ms = 1000, reserved_capacity = reserved })
		if candidate then f.authority.registry = candidate; f.memory.value = clone(candidate) end
		return result
	end
	assert(reduce("project_start", { orch_project_id = project, project_revision = f.authority.registry.dispatch.projects[project].revision }, true).ok)
	check(#actions_of(f, queued.worker_id, "mailbox_provision") == 0, "START records intent without consuming receipt/recovery reserve")
	assert(reduce("pause", nil, true).ok)
	assert(reduce("resume", nil, true).ok)
	check(#actions_of(f, queued.worker_id, "mailbox_provision") == 0, "Resume cannot bypass reserved-capacity admission")
	assert(reduce("pause", nil, true).ok)
	assert(reduce("resume", nil, false).ok)
	local provisions = actions_of(f, queued.worker_id, "mailbox_provision"); assert(#provisions == 1)
	check(not reduce("claim", { action_id = provisions[1], executor = f.origin.window_epoch }, true).ok
		and f:action(provisions[1]).phase == "ready", "a new provision claim cannot consume recovery capacity")
	check(reduce("claim", { action_id = provisions[1], executor = f.origin.window_epoch }, false).ok, "ordinary capacity releases the same single retained provision")
end
if section == nil or section == "rollover_location" then
	for _, terminal in { false, true } do
		local f = fixture(function() return { now_ms = 1000, mono_ms = 1000, epoch = "rollover-location" } end, { passive = true })
		f:catalog(0)
		if terminal then
			local row = f.authority.registry.dispatch.catalogs[f.origin.logical_session_id].records[1]
			row.backend = "local-terminal"; row.placement = "replace_if_alone"
			row.capabilities = runtime.json.array({ "report-files-v1", "worker-poll-v1" }); f.memory.value = clone(f.authority.registry)
		end
		local project = f:project("Conversation execution location", false)
		assert(boundary_repository(f, project, "/fixture/original-worktree").ok)
		local id, pane = boundary_open(f, project, false)
		assert(send_report(f, id, "ACCEPTED", { assignment_sha256 = worker_of(f, id).assignment_sha256 }).ok)
		assert(f:finish(f:apply("poll", { worker_id = id }).action_id, "published", {}).ok)
		assert(f:finish(f:apply("poll", { worker_id = id }).action_id, "accepted", {}).ok)
		assert(f:apply("observe", { worker_id = id, pane_binding = pane, native_state = "idle" }).ok)
		assert(boundary_repository(f, project, "/fixture/new-project-worktree").ok)
		local requested = f:apply("rollover", { worker_id = id, trigger = "owner" }); assert(requested.ok, requested.message)
		check(not boundary_repository(f, project, "/fixture/third-worktree").ok, "a pending handover freezes project execution bindings")
		assert(answer_checkpoint(f, id, "location-checkpoint").ok)
		local handover = rollover_of(f, requested.handover_id)
		local successor = handover.successor_worker_id
		assert(successor, runtime.json.encode({ terminal = terminal, phase = handover.phase, hold = handover.hold }))
		local w = worker_of(f, successor)
		check(w.execution_cwd == "/fixture/original-worktree" and w.cwd == "/fixture" and w.presentation == "background",
			"successor inherits the predecessor execution checkout, not a later project or saved-record default")
		local provision = actions_of(f, successor, "mailbox_provision"); assert(#provision == 1)
		local provisioned = f:finish(provision[1], "provisioned", { handle = "mailbox-location-successor", binding_digest = string.rep("b", 64),
			capabilities = runtime.json.array(clone(worker_of(f, id).capabilities)), limits = {} })
		assert(provisioned.ok, runtime.json.encode(provisioned))
		local request = f:action(worker_of(f, successor).launch_action_id).request
		check(request.cwd == "/fixture/original-worktree" and request.presentation == "background"
			and request.placement == (if terminal then "tab" else "split")
			and worker_of(f, successor).placement == (if terminal then "replace_if_alone" else "split"),
			"background terminal rollover freezes an unfocused tab without rewriting its saved record")
		check(state.rehydrate(clone(f.authority.registry)) ~= nil, "the exact inherited launch and saved record restore together")
	end
end
return "dispatch" .. (if section then "/" .. section else "") .. ": " .. tostring(checks) .. " checks passed"
