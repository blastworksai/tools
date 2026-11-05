-- Run in a disposable Tern host callback. No native launch, filesystem mailbox or production KV.
local root, section = ...
local sections = { fixture = true, core = true, receipts = true, callbacks = true, oversize = true, retry = true,
	chain = true, late = true, reconcile_chain = true, refused_chain = true, ack = true, ack_uncertain = true, ack_terminal = true,
	suspend = true, auto_reconcile = true, auto_reconcile_bounded = true, auto_reconcile_worker = true, sweep_rules = true, sweep_policy = true,
	auto_reconcile_all = true, capacity_resume = true, expired_authorization = true, slot_classes = true, duplicate_claim = true, slow_receipt = true,
	retirement_auth = true, retirement_finish = true, retirement_race = true, retirement_uncertain = true, retirement_restore = true, retirement_capability = true, retirement_codec = true, retirement_refused = true,
	rejected_read = true, finish = true, finish_capacity = true, command_retention = true, continuation = true, wake_separation = true, catalog_join = true, policy = true,
	rollover = true, rollover_launch_failure = true, rollover_token = true, rollover_stop_uncertain = true, rollover_reload = true, rollover_policy = true,
	rollover_coordinator = true, rollover_coordinator_ambiguous = true, rollover_coordinator_reload = true, rollover_coordinator_restored = true, rollover_coordinator_policy = true, rollover_coordinator_successor_rejected = true,
	rollover_read_path = true, rollover_reload_continuation = true, recheck_report = true, adopt = true,
	rollover_coordinator_self_release = true, publication_readback = true, accept_after_owner_recovery = true,
	quota_normalize = true, quota_assembly = true, quota_routing = true, quota_gate = true, quota_claim = true,
	quota_rollover = true, quota_ledger = true, quota_selector = true, quota_continuation = true, window_bookkeeping = true, intent_buttons = true,
	withdraw_fenced = true }
assert(section == nil or sections[section], "unknown dispatch test section: " .. tostring(section))
local runtime, environment = tern, getfenv()
local function clone(v) return runtime.json.decode(runtime.json.encode(v)) end
local fake = table.clone(runtime)
local definition, ui_value
fake.kv = { get = function() return if ui_value then clone(ui_value) else nil end, set = function(_, value) ui_value = clone(value) end }
fake.block = { define = function(_, value) definition = value end }; fake.on = function() end
fake.timer = function() return { cancel = function() end } end
local modules = {}
local function load(name)
	name = name:gsub("^%./", "")
	if modules[name] then return modules[name] end
	local chunk = assert(loadstring(runtime.fs.read(root .. "/" .. name .. ".luau"), name))
	setfenv(chunk, setmetatable({ tern = fake, require = load }, { __index = environment }))
	local value = chunk(); modules[name] = value; return value
end
local host, state, dispatch, codec = load("host"), load("state"), load("dispatch"), load("transport")
local checks, serial = 0, 0
local function check(ok, why) assert(ok, why); checks += 1 end
local function next_id() serial += 1; return "fixture-" .. tostring(serial) end
local function frame(request, status, payload, problem)
	local body = { schema = 1, op = request.op, request_id = request.request_id, action_id = request.action_id,
		origin_binding = clone(request.origin_binding), controller_generation = request.controller_generation, status = status, payload = payload, error = problem }
	local bytes = runtime.json.encode(body)
	return "SPAWN_DISPATCH v1 " .. runtime.json.encode({ schema = 1, op = body.op, request_id = body.request_id,
		complete = true, body_bytes = #bytes, body_sha256 = codec.sha256(bytes), body_json = bytes })
end
local function role_node(node, role, key)
	if type(node) ~= "table" then return nil end
	if node.p and node.p.role == role and (key == nil or node.p.key == key) then return node end
	for _, child in node.c or {} do local found = role_node(child, role, key); if found then return found end end
	return nil
end
local function fixture(clock)
	local memory = { value = nil, writes = 0, fail = false }
	memory.get = function() return if memory.value then clone(memory.value) else nil end
	memory.set = function(_, value) if memory.fail then error("injected persistence failure") end; memory.value = clone(value); memory.writes += 1 end
	local authority = host.new_authority(memory, clock or function() return { now_ms = math.floor(os.time() * 1000) } end)
	authority:load(); assert(authority:initialize(true).ok)
	local registered = authority:apply({ kind = "register_session", request_id = next_id(), name = "Dispatch fixture" })
	local admission = authority:apply({ kind = "admit_controller", request_id = next_id(), orch_session_id = registered.orch_session_id,
		pane_binding = { host_pane_id = "42", alias_nonce = "fixture-controller-nonce" } })
	local origin = { logical_session_id = registered.orch_session_id, owner_id = admission.owner_id, owner_generation = admission.generation,
		host_pane_id = "42", alias_nonce = "fixture-controller-nonce", window_key = "", window_epoch = "fixture-window", native_session_id = "7", window_host_id = "local" }
	local f = { authority = authority, memory = memory, origin = origin }
	function f:event(command, fields)
		local event = { kind = "dispatch", request_id = next_id(), orch_session_id = self.origin.logical_session_id,
			origin = clone(self.origin), controller_pane = self.controller_pane or "9001", command = command }
		if command ~= "claim" and command ~= "result" and command ~= "lost" then
			local cursor = ((self.authority.registry.dispatch or {}).command_cursors or {})[self.origin.logical_session_id]
			self.command_seq = math.max(self.command_seq or 0, if cursor then cursor.seq else 0) + 1
			event.command_seq = self.command_seq
		end
		for k, v in fields or {} do event[k] = v end; return event
	end
	function f:apply(command, fields) return self.authority:apply(self:event(command, fields)) end
	function f:action(id) return self.authority.registry.dispatch.actions[id] end
	function f:finish(id, status, payload)
		local a = self:action(id)
		if a.phase == "ready" then assert(self:apply("claim", { action_id = id, executor = self.origin.window_epoch }).ok) end
		return self:apply("result", { action_id = id, executor = self.origin.window_epoch, grant_id = self:action(id).claim.grant_id, response_bytes = frame(a.request, status, payload) })
	end
	function f:catalog(revision, record_id, cwd)
		local r = self:apply("catalog")
		assert(self:finish(r.action_id, "catalog", { namespace = "fixture-spawn", host_key = "fixture-host", config_revision = revision, revision = revision, records = runtime.json.array({ { id = record_id or "native", revision = revision,
			provider = "omp", account_label = "configured, not verified", backend = "native-agent", enabled = true, eligible = true,
			capability_evidence = "configured_operator_attestation_not_runtime_proof", effective_identity = { provider = "omp", evidence = "configured" },
			capabilities = runtime.json.array({ "report-files-v1", "native-ask-v1", "coordinator-control-v1" }), unsupported = runtime.json.array(), cwd = cwd or "/fixture", placement = "split" } }) }).ok)
	end
	function f:queue(coordinator)
		return self:apply("queue", { record_id = "native", record_revision = 0, catalog_revision = 0,
			prompt = "Complete the explicit fixture assignment, preserving literal $HOME and Unicode café.", cwd = "/fixture", placement = "split", coordinator = coordinator == true })
	end
	function f:launched(coordinator)
		self:catalog(0)
		local queued = self:queue(coordinator); assert(queued.ok)
		assert(self:finish(queued.action_id, "provisioned", { handle = "mailbox-fixture", binding_digest = string.rep("a", 64),
			capabilities = runtime.json.array({ "report-files-v1", "native-ask-v1", "coordinator-control-v1" }), limits = {} }).ok)
		local worker = self.authority.registry.dispatch.workers[queued.worker_id]
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
		local queued = self:apply("poll", { worker_id = worker_id, bytes = "watermark" }); assert(queued.ok, queued.message)
		local page = assert(codec.project_page(runtime.json.encode(mark), self:action(queued.action_id).request.selector))
		return self:finish(queued.action_id, "complete", runtime.json.decode(page))
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
			local page = assert(codec.project_page(object, request.selector))
			outcome = self:finish(queued.action_id, "complete", runtime.json.decode(page))
		end
		return outcome
	end
	return f
end
if section == "fixture" then return { fixture = fixture, clone = clone, codec = codec, state = state, dispatch = dispatch, host = host, frame = frame, load = load } end
if section == nil or section == "core" then
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
check(replay.work_id == queued.work_id and f.memory.writes == writes, "same queue request replays same work without another reservation")
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
local late = f:event("result", { action_id = queued.action_id, executor = "fixture-window", grant_id = f:action(queued.action_id).claim.grant_id, response_bytes = frame(f:action(queued.action_id).request, "provisioned", {
	handle = "box", binding_digest = string.rep("a", 64), capabilities = runtime.json.array({ "report-files-v1", "native-ask-v1" }) }) })
local restored = host.new_authority(f.memory)
check(restored:load().ok, "dispatch ledger validates/restores through sole-host store")
check(restored.registry.dispatch.actions[queued.action_id].phase == "uncertain", "restore retains ambiguous operation")
check(not restored:apply(late).ok and restored.registry.sessions[f.origin.logical_session_id].orchestrator ~= nil, "stale callback cannot bind or clear a restored coordinator")
local codec_request = f:action(queued.action_id).request
check(dispatch.decode_response("SPAWN_DISPATCH v0 {}", codec_request) == nil, "incompatible bridge cannot fall back")
local forged = clone(codec_request); forged.action_id = "another-action"
check(dispatch.decode_response(frame(forged, "provisioned", {}), codec_request) == nil, "mismatched exact action response rejects")

local g = fixture(); local worker_id = g:launched(false)
local worker = g.authority.registry.dispatch.workers[worker_id]
check(worker.pane_binding.pane_id == "9002" and worker.phase == "awaiting_acceptance", "only correlated SPAWN outcome binds actual window-local pane")
local launch = g:action(worker.launch_action_id).request
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
for _, wake in { "awaiting_window", "claimed", "launching" } do
	check(g:finish(publish.action_id, "published", { wake_status = wake }).code == "wake_pending", "ACK retains native wake: " .. wake)
	local action = g:action(publish.action_id)
	local pending_worker = g.authority.registry.dispatch.workers[worker_id]
	check(action.phase == "claimed" and pending_worker.receipts["1"].publish and pending_worker.accept_pending
		and pending_worker.compacted_floor == 0, "ACK wake precedes separate SPAWN accept without clearing outbox or receipt")
	local prior_writes, grant = g.memory.writes, action.claim.grant_id
	check(g:finish(publish.action_id, "published", { wake_status = wake }).code == "wake_pending"
		and g.memory.writes == prior_writes, "duplicate ACK wake result is read-only")
	check(g:apply("poll", { worker_id = worker_id }).code == "operation_pending"
		and g:apply("retry", { action_id = publish.action_id }).code == "retry_refused"
		and g:action(publish.action_id).claim.grant_id == grant, "pending ACK cannot allocate another effect or retry grant")
	local reload_value = clone(g.memory.value)
	local retained = host.new_authority({
		get = function() return clone(reload_value) end,
		set = function(_, value) reload_value = clone(value) end,
	})
	check(retained:load().ok and retained.registry.dispatch.actions[publish.action_id].claim.grant_id == grant
		and retained.registry.dispatch.actions[publish.action_id].phase == "uncertain"
		and retained.registry.dispatch.workers[worker_id].receipts["1"].publish, "reload retains ACK bytes and original unresolved grant without replay permission")
end
check(g:finish(publish.action_id, "published", { wake_status = "submitted" }).ok
	and g:action(publish.action_id).phase == "complete"
	and not g.authority.registry.dispatch.workers[worker_id].receipts["1"].publish, "queued ACK notification settles publication, not consumption")
check(g.authority.registry.dispatch.workers[worker_id].compacted_floor == 0, "ACK publication does not prove worker receipt")
local accept_op = g:apply("poll", { worker_id = worker_id })
local accept_request = g:action(accept_op.action_id).request
check(accept_request.op == "accept" and accept_request.target_request_id == worker.launch_request_id and accept_request.event_sha256 == codec.sha256(accepted), "SPAWN acceptance is correlated to durably accepted exact report")
check(accept_request.handover_id == nil and accept_request.handover_token == nil and accept_request.pane_binding.pane_id == "9002", "initial accept callback needs no handover fields")
check(g:finish(accept_op.action_id, "accepted", {}).ok and not g.authority.registry.dispatch.workers[worker_id].accept_pending, "accept outbox settles only on SPAWN accepted outcome")
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
check(g:apply("retry", { action_id = reply_part.action_id }).ok and g:action(reply_part.action_id).request_bytes == refused_reply_request, "reply retry preserves exact immutable request/action")
check(g:apply("claim", { action_id = reply_part.action_id, executor = "fixture-window" }).ok, "capacity recheck requires another durable grant")
check(g:apply("lost", { action_id = reply_part.action_id, executor = "fixture-window", grant_id = g:action(reply_part.action_id).claim.grant_id }).ok, "lost reply publication remains uncertain")
check(g:apply("claim", { action_id = reply_part.action_id, executor = "fixture-window" }).code == "effect_already_claimed"
	and g.authority.registry.dispatch.workers[worker_id].replies["1"].bytes == reply_bytes, "lost reply cannot obtain another execution grant or lose its immutable bytes")
check(g:finish(reply_part.action_id, "published", {}).ok, "first reply chunk publishes")
local manifest = g:apply("poll", { worker_id = worker_id })
check(g:action(manifest.action_id).request.part == "manifest", "reply manifest is the last immutable part")
local manifest_part = g.authority.registry.dispatch.workers[worker_id].replies["1"].part
for _, wake in { "awaiting_window", "claimed", "launching" } do
	check(g:finish(manifest.action_id, "already_published", { wake_status = wake }).code == "wake_pending", "publication retains the original pending native wake grant: " .. wake)
	check(g:action(manifest.action_id).phase == "claimed" and g.authority.registry.dispatch.workers[worker_id].replies["1"].part == manifest_part
		and dispatch.unresolved(g.authority.registry, g.origin.logical_session_id, g.origin.owner_id), "pending wake cannot clear executor occupancy or advance publication")
	local prior_writes = g.memory.writes
	check(g:finish(manifest.action_id, "already_published", { wake_status = wake }).code == "wake_pending" and g.memory.writes == prior_writes, "identical pending wake status is a read-only replay")
end
local visible_wake = dispatch.project(g.authority.registry, g.origin.logical_session_id, g.origin.alias_nonce).actions[manifest.action_id]
check(visible_wake.wake_pending and visible_wake.claim.grant_id == g:action(manifest.action_id).claim.grant_id, "consumer projection retains exact original wake authorization")
local other_action = g:apply("catalog")
local wake_view = { pane = 42, alias_nonce = g.origin.alias_nonce, orch_session_id = g.origin.logical_session_id, action_serial = 0, dispatch_action = other_action.action_id }
local wake_projection = state.project(g.authority.registry)
wake_projection.dispatch = dispatch.project(g.authority.registry, g.origin.logical_session_id, g.origin.alias_nonce, other_action.action_id)
local rendered_wake = assert(role_node(load("views").render(wake_view, wake_projection, "ready"), "orchplus.dispatch")).p.spans[1]
local wake_machine = runtime.json.decode(if type(rendered_wake) == "string" then rendered_wake else rendered_wake.t)
check(wake_machine.action.action_id == manifest.action_id and wake_machine.action.claim.grant_id == visible_wake.claim.grant_id, "another selected queued task cannot hide the still-pending original native wake grant")
check(g:finish(manifest.action_id, "already_published", { wake_status = "submitted" }).ok and g:action(manifest.action_id).phase == "complete", "only terminal queued-ask evidence settles native wake, not a worker receipt")
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
local projected = assert(codec.project_page(framed.manifest, selector))
check(t:finish(manifest_read.action_id, "complete", runtime.json.decode(projected)).ok, "validated manifest page commits bounded assembly but no receipt")
check(t.authority.registry.dispatch.workers[framed_worker].accepted_seq == 0, "manifest alone cannot apply acceptance")
for _, chunk in framed.chunks do
	local part = t:apply("poll", { worker_id = framed_worker })
	local selected = t:action(part.action_id).request.selector
	local page = assert(codec.project_page(chunk, selected))
	check(t:finish(part.action_id, "complete", runtime.json.decode(page)).ok, "correlated complete chunk flows through host intake")
end
tw = t.authority.registry.dispatch.workers[framed_worker]
check(tw.accepted_seq == 1 and tw.accept_pending and tw.receipts["1"].publish and tw.assembly == nil, "last verified chunk atomically creates receipt and both acceptance outboxes")
local ack_publish = t:apply("poll", { worker_id = framed_worker })
assert(t:finish(ack_publish.action_id, "published", {}).ok)
local accepted_callback = t:apply("poll", { worker_id = framed_worker })
assert(t:finish(accepted_callback.action_id, "accepted", {}).ok)
local watermark = { version = 1, type = "receipt_watermark", mailbox_handle = tw.mailbox_handle, through_seq = 1, receipt_chain_sha256 = tw.receipt_chain }
for _, key in { "logical_session_id", "worker_id", "worker_generation", "launch_request_id", "work_id", "enrolment_token" } do watermark[key] = tw[key] end
local watermark_read = t:apply("poll", { worker_id = framed_worker, bytes = "watermark" })
local watermark_page = assert(codec.project_page(runtime.json.encode(watermark), t:action(watermark_read.action_id).request.selector))
check(t:finish(watermark_read.action_id, "complete", runtime.json.decode(watermark_page)).ok, "independent cumulative watermark commits through SPAWN read boundary")
tw = t.authority.registry.dispatch.workers[framed_worker]
check(tw.compacted_floor == 1 and tw.receipts["1"] == nil and tw.accepted_seq == 1, "worker-confirmed prefix compacts receipts without forgetting acceptance fence")
local cleanup = t:apply("poll", { worker_id = framed_worker })
check(t:action(cleanup.action_id).request.op == "mailbox_retire" and t:action(cleanup.action_id).request.mode == "compact" and t:action(cleanup.action_id).request.report_floor == 1, "committed watermark alone authorizes bounded SPAWN compaction grant")
assert(t:finish(cleanup.action_id, "compacted", {}).ok)
check(t:apply("intake", { worker_id = framed_worker, bytes = logical }).code == "already_compacted", "below-floor replay cannot fabricate an old receipt")
local reload = host.new_authority(t.memory)
check(reload:load().ok and reload.registry.dispatch.workers[framed_worker].compacted_floor == 1, "accepted mailbox/reply fences survive actual host restoration")

local unavailable = { kind = "observe_owner", request_id = next_id(), orch_session_id = f.origin.logical_session_id,
	target = "controller", expected_owner_id = f.origin.owner_id, expected_generation = f.origin.owner_generation, status = "unavailable", evidence = "observed" }
check(restored:apply(unavailable).ok, "fresh unavailable observation permits exact executor inspection after reload")
local reset = clone(unavailable); reset.request_id = next_id(); reset.status = "operator checked"; reset.evidence = "operator_attested"
reset.owner_active = false; reset.pending_executors = 0; reset.operator_verified = true; reset.executors_verified = true
check(restored:apply(reset).code == "dispatch_executor_unresolved", "blind inspection-count reset cannot erase a retained actual action claim")
local inert_projection = dispatch.project(restored.registry, f.origin.logical_session_id, "new-inert-panel")
check(inert_projection.actions[queued.action_id] ~= nil, "replacement inert recovery panel can inspect the old exact executor ledger")
local reconcile = { kind = "dispatch_reconcile", request_id = next_id(), orch_session_id = f.origin.logical_session_id, action_id = queued.action_id,
	executor = "fixture-window", expected_revision = restored.registry.revision - 1, operator_verified = true, reason = "Independently stopped retained native executor and any delayed launch." }
check(restored:apply(reconcile).code == "stale_recovery", "executor recovery rejects changed display revision")
reconcile.expected_revision = restored.registry.revision
check(restored:apply(reconcile).ok and restored.registry.dispatch.actions[queued.action_id].phase == "resolved", "exact explicit executor reconciliation is durable")
check(restored.registry.sessions[f.origin.logical_session_id].orchestrator ~= nil, "executor reconciliation does not clear coordinator or start a replacement")
local reconcile_writes = f.memory.writes
local replayed_reconcile = restored:apply(reconcile)
check(replayed_reconcile.ok and replayed_reconcile.replayed and f.memory.writes == reconcile_writes, "lost reconciliation response replays exact saved outcome before stale revision guards")
local changed_reconcile = clone(reconcile); changed_reconcile.reason = "Different claimed evidence"
check(restored:apply(changed_reconcile).code == "request_conflict", "reconciliation request ID cannot silently name changed operator evidence")
local reconciled_reload = host.new_authority(f.memory)
check(reconciled_reload:load().ok and reconciled_reload:apply(reconcile).replayed, "exact reconciliation replay survives host restoration")

-- Corrupt accepted state is rejected as data, never a nil-concatenation exception.
local malformed = clone(t.memory.value)
malformed.dispatch.workers[framed_worker].mailbox_handle = nil
local corrupt_authority = host.new_authority({ get = function() return malformed end, set = function() error("must not write corrupt input") end })
local corrupt_ok, corrupt_result = pcall(function() return corrupt_authority:load() end)
check(corrupt_ok and corrupt_result.code == "state_corrupt", "accepted event without mailbox handle fails closed without throwing")

-- A pre-effect provision refusal retains the startup reservation and exact retry identity.
local capacity = fixture(); capacity:catalog(0)
local reserved = capacity:queue(true)
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
	local body, problem = dispatch.decode_response(frame(capacity:action(reserved.action_id).request, "full", malformed_full), capacity:action(reserved.action_id).request)
	check(body == nil and problem.code == "invalid_schema" and capacity:action(reserved.action_id).phase == "ready", "malformed full accounting/proof cannot create retry permission")
end
local projected_full = dispatch.decode_response(frame(capacity:action(reserved.action_id).request, "full",
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
	local malformed_store = host.new_authority({ get = function() return malformed_backpressure end, set = function() error("must quarantine malformed capacity proof") end })
	local valid_call, rejected = pcall(function() return malformed_store:load() end)
	check(valid_call and rejected.code == "state_corrupt", "restored backpressure requires full accounting as well as proof flags")
end
check(capacity:queue(true).code == "orchestrator_slot_occupied" and capacity.authority.registry.dispatch.workers[reserved.worker_id].mailbox_handle == nil, "unbound backpressure retains exclusive coordinator reservation")
check(capacity:apply("retry", { action_id = reserved.action_id }).ok, "operator explicitly rechecks unexecuted provision")
check(capacity:apply("claim", { action_id = reserved.action_id, executor = "fixture-window" }).ok
	and capacity:action(reserved.action_id).claim.grant_id ~= old_grant and capacity:action(reserved.action_id).request_bytes == provision_request, "retry gets fresh durable grant without new native request/action")
check(capacity:apply("result", { action_id = reserved.action_id, executor = "fixture-window", grant_id = old_grant, response_bytes = old_outcome }).code == "stale_claim", "late old full outcome cannot settle successor retry grant")
check(capacity:finish(reserved.action_id, "provisioned", { handle = "capacity-mailbox", binding_digest = string.rep("a", 64),
	capabilities = runtime.json.array({ "report-files-v1", "native-ask-v1", "coordinator-control-v1" }) }).ok, "exact provision recheck can bind after capacity clears")
local provisioned = capacity.authority.registry.dispatch.workers[reserved.worker_id]
check(capacity:finish(provisioned.launch_action_id, "awaiting_acceptance", { pane_binding = {
	pane_id = "9002", window_key = "", window_epoch = "fixture-window", native_session_id = "7", window_host_id = "local" } }).ok, "startup continues to actual correlated launch after provision retry")
do
	local forged_acceptance = clone(capacity.memory.value)
	forged_acceptance.dispatch.workers[reserved.worker_id].phase = "accepted"
	local forged_store = host.new_authority({ get = function() return forged_acceptance end, set = function() error("must quarantine forged acceptance") end })
	local valid_call, rejected = pcall(function() return forged_store:load() end)
	check(valid_call and rejected.code == "state_corrupt", "phase-only accepted worker without exact ACCEPTED evidence is quarantined")
	local missing_event = clone(t.memory.value)
	missing_event.dispatch.workers[framed_worker].accepted_event = nil
	local missing_store = host.new_authority({ get = function() return missing_event end, set = function() error("must quarantine missing acceptance") end })
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
		outcome = fx:finish(action_id, "complete", runtime.json.decode(page)); assert(outcome.ok)
	end
	return outcome, action_id
end
local blocked_report, completed_read = consume_pages(lane, lane_worker, ninth)
check(blocked_report.code == "intake_backpressure" and lane:action(completed_read).phase == "complete"
	and lane.authority.registry.dispatch.workers[lane_worker].accepted_seq == 8 and lane.authority.registry.dispatch.workers[lane_worker].receipts["9"] == nil, "ninth report retains durable read outcome without applying or ACKing past full receipt lane")
local lw = lane.authority.registry.dispatch.workers[lane_worker]
local lane_watermark = { version = 1, type = "receipt_watermark", mailbox_handle = lw.mailbox_handle, through_seq = 8, receipt_chain_sha256 = lw.receipt_chain }
for _, key in { "logical_session_id", "worker_id", "worker_generation", "launch_request_id", "work_id", "enrolment_token" } do lane_watermark[key] = lw[key] end
local drain = lane:apply("poll", { worker_id = lane_worker, bytes = "watermark" })
check(drain.ok and lane:action(drain.action_id).request.selector.stream == "watermark", "independent watermark settlement remains available after receipt lane backpressure")
local drain_page = assert(codec.project_page(runtime.json.encode(lane_watermark), lane:action(drain.action_id).request.selector))
assert(lane:finish(drain.action_id, "complete", runtime.json.decode(drain_page)).ok)
assert(lane:finish(lane:apply("poll", { worker_id = lane_worker }).action_id, "compacted", {}).ok)
check(consume_pages(lane, lane_worker, ninth).code == "bridge_committed"
	and lane.authority.registry.dispatch.workers[lane_worker].accepted_seq == 9, "same unacknowledged ninth report commits after worker watermark frees receipt lane")
local priority_watermark = lane:apply("poll", { worker_id = lane_worker, bytes = "watermark" })
check(priority_watermark.ok and lane:action(priority_watermark.action_id).request.selector.stream == "watermark"
	and lane.authority.registry.dispatch.workers[lane_worker].receipts["9"].publish, "watermark control lane is not blocked by an unpublished data ACK")
assert(lane:finish(priority_watermark.action_id, "missing", {}).ok)
assert(lane:finish(lane:apply("poll", { worker_id = lane_worker }).action_id, "published", {}).ok)
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
	assert(commit:finish(manifest_request.action_id, "complete", runtime.json.decode(manifest_page)).ok)
	for index, chunk in frames.chunks do
		local part = commit:apply("poll", { worker_id = id })
		assert(commit:apply("claim", { action_id = part.action_id, executor = "fixture-window" }).ok)
		local page = assert(codec.project_page(chunk, commit:action(part.action_id).request.selector))
		if index == #frames.chunks then commit.memory.fail = true end
		local committed = commit:finish(part.action_id, "complete", runtime.json.decode(page))
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
-- Actual duplicate-block callbacks: preserve the losing rendered token across the winner's rerender.
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
click(11, "initialize-arm"); click(11, "initialize-confirm")
click(11, "register-arm"); click(11, "register-confirm")
views[12].orch_session_id = views[11].orch_session_id
views[12].notice = "old successful registration outcome"
local losing_token = token(12, "admit")
click(11, "admit") -- render_all replaces both action maps.
local current_owner = ui_value.sessions[views[11].orch_session_id].controller
local revision = ui_value.revision
definition.event(views[12], { ev = "action", act = "control", value = losing_token }, contexts[12])
check(views[12].refusal ~= nil and views[12].refusal.ok == false and views[12].refusal.code == "controller_slot_occupied", "stale losing admission visibly reports semantic occupied refusal")
check(views[12].refusal.owner_id == current_owner.owner_id and views[12].refusal.generation == current_owner.generation, "stale refusal identifies the actual current owner")
check(views[12].notice ~= "old successful registration outcome" and ui_value.revision == revision, "stale losing click replaces old success without mutation or retry")

-- Real host callbacks publish dispatch metadata and receipts only after the matching commit.
do
	local displayed
	contexts[11].render = function()
		local node = assert(role_node(definition.view(views[11], contexts[11]).main, "orchplus.dispatch"))
		local span = node.p.spans[1]; displayed = runtime.json.decode(if type(span) == "string" then span else span.t)
	end
	local origin = { logical_session_id = views[11].orch_session_id, owner_id = current_owner.owner_id, owner_generation = current_owner.generation,
		host_pane_id = "11", alias_nonce = views[11].alias_nonce, window_key = "", window_epoch = "fixture-window", native_session_id = "7", window_host_id = "local" }
	local function command(kind, fields, operator)
		local input = { kind = "dispatch", request_id = next_id(), orch_session_id = origin.logical_session_id, origin = origin, controller_pane = "9001", command = kind }
		if kind ~= "claim" and kind ~= "result" and kind ~= "lost" then
			local cursor = ((ui_value.dispatch or {}).command_cursors or {})[origin.logical_session_id]
			input.command_seq = (if cursor then cursor.seq else 0) + 1
		end
		for key, value in fields or {} do input[key] = value end
		definition.event(views[11], { ev = "action", act = if operator then "dispatch-operator-command" else "dispatch-command", value = runtime.json.encode(input) }, contexts[11])
		return if operator then views[11].dispatch_command_result else views[11].dispatch_result
	end
	local queued_catalog = command("catalog")
	check(displayed.result.action_id == queued_catalog.action_id and displayed.action.phase == "ready", "rendered dispatch result and selected action come from the same completed host transition")
	local granted_catalog = command("claim", { action_id = queued_catalog.action_id, executor = "fixture-window" })
	local retained = ui_value.dispatch.actions[queued_catalog.action_id]
	local response_bytes = frame(retained.request, "catalog", { namespace = "fixture-spawn", host_key = "fixture-host", config_revision = 0, revision = 0, records = runtime.json.array() })
	local event = { ev = "action", act = "dispatch-result/" .. granted_catalog.claim.grant_id .. "/" .. origin.window_epoch, value = response_bytes }
	definition.event(views[11], event, contexts[11])
	check(displayed.receipt.action_id == queued_catalog.action_id and displayed.receipt.grant_id == granted_catalog.claim.grant_id
		and displayed.receipt.response_sha256 == codec.sha256(response_bytes) and ui_value.dispatch.actions[queued_catalog.action_id].phase == "complete", "host receipt names exact committed response and grant")
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
	check(captured.action.phase == "complete" and captured.receipt.response_sha256 == codec.sha256(response_bytes),
		"exact completed scope keeps captured commit receipt available after another action compacts its durable read")
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
	definition.event(views[11], { ev = "action", act = "dispatch-result/" .. configured_grant .. "/" .. origin.window_epoch, value = configured_bytes }, contexts[11])
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
	local provision_result = frame(provision_request, "provisioned", { handle = "callback-mailbox", binding_digest = string.rep("a", 64),
		capabilities = runtime.json.array({ "report-files-v1", "native-ask-v1", "coordinator-control-v1" }) })
	definition.event(views[11], { ev = "action", act = "dispatch-result/" .. first_grant .. "/" .. origin.window_epoch, value = provision_result }, contexts[11])
	command("poll", { worker_id = first.worker_id })
	check(displayed.command_result.request_id == failed_start.request_id and not displayed.command_result.acknowledged
		and ui_value.dispatch.actions[first.action_id].phase == "complete",
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
	local previous_receipt = clone(displayed.receipt)
	local pending_catalog = command("catalog")
	local pending_grant = command("claim", { action_id = pending_catalog.action_id, executor = "fixture-window" })
	local failed_bytes = frame(ui_value.dispatch.actions[pending_catalog.action_id].request, "catalog", { namespace = "fixture-spawn", host_key = "fixture-host", config_revision = 0, revision = 0, records = runtime.json.array() })
	local original_set = fake.kv.set
	fake.kv.set = function() error("injected native observation commit failure") end
	definition.event(views[11], { ev = "action", act = "dispatch-result/" .. pending_grant.claim.grant_id .. "/" .. origin.window_epoch, value = failed_bytes }, contexts[11])
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
itern.kv = { get = function() return if store_value then clone(store_value) else nil end, set = function(_, value) store_value = clone(value) end }
itern.block = { define = function(_, value) idef = value end }
itern.now = function() return now end
itern.pane = { list = function() return { { pane = 11 } } end }
local host_timers = {}
itern.timer = function(_, fn) table.insert(host_timers, fn); return { cancel = function() end } end
local imodules = {}
local function iload(name)
	name = name:gsub("^%./", "")
	if imodules[name] then return imodules[name] end
	local chunk = assert(loadstring(runtime.fs.read(root .. "/" .. name .. ".luau"), "intent-" .. name))
	setfenv(chunk, setmetatable({ tern = itern, require = iload }, { __index = environment }))
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
press(kind("initialize-arm"), "initialize"); press(kind("initialize-confirm"), "confirm initialize")
press(kind("register-arm"), "register"); press(kind("register-confirm"), "confirm register")
press(kind("admit"), "claim controller")
local sid = view.orch_session_id
local function saved_policy() return dispatch.policy(store_value, sid) end
local function keyed(node, key)
	if type(node) ~= "table" then return nil end
	if type(node.p) == "table" and node.p.key == key then return node end
	for _, child in node.c or {} do local found = keyed(child, key); if found then return found end end
	return nil
end
local sent, toasts, picks, drop_acks = {}, {}, {}, false
local host_row = { id = "local", state = "connected", panes = { 11 } }
local controller_row = { pane = 11, block = "orchplus.orchestrator", tab = 1 }
local function window_cx(key)
	local session = {}
	function session:pane(id) return if id == 11 then controller_row else nil end
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
	return { session = session, sessions = { current = function() return { id = 7, host = "local" } end },
		hosts = { current = function() return host_row end, list = function() return { host_row } end },
		window_key = function() return key end, toast = function(_, _, _, message) table.insert(toasts, { window = key, message = message }) end,
		pick = function(_, options) table.insert(picks, { window = key, placeholder = options.placeholder }); return { next = function() end } end }
end
local palette = {}
local function window_vm()
	local wtern = table.clone(itern)
	local registered = {}
	wtern.timer = function() return { cancel = function() end } end
	wtern.command = function(def) registered[def.id] = def end; wtern.files = { button = function() end }; wtern.on = function() end
	wtern.route = { link = function() error("ORCH+ must not claim links; controls are native buttons") end }
	local chunk = assert(loadstring(runtime.fs.read(root .. "/window.luau"), "intent-window"))
	setfenv(chunk, setmetatable({ tern = wtern, require = iload }, { __index = environment }))
	local api = chunk()
	palette[api] = registered
	return api
end
local first_api, second_api = window_vm(), window_vm()
local first, second = window_cx(""), window_cx("second-window")
local function commands(window, name)
	local n = 0
	for _, row in sent do
		if row.window == window and row.act == "dispatch-operator-command" and runtime.json.decode(row.value).command == name then n += 1 end
	end
	return n
end
local function sent_by(window) local n = 0; for _, row in sent do if row.window == window then n += 1 end end; return n end
local function no_links()
	local encoded = runtime.json.encode(idef.view(view, ctx).main)
	return encoded:find("orchplus://", 1, true) == nil
end
check(no_links(), "the controller view renders no orchplus:// link")

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

-- Save session settings: the exact >8 KiB expected policy runs once across ticks and re-renders.
press(kind("config-open"), "Config")
idef.event(view, { ev = "change", name = "auto_rollover", checked = true }, ctx)
check(no_links(), "Config renders no orchplus:// link")
drop_acks = true -- The host never sees the settlement: the intent stays published.
local save = press(function(entry) return entry.kind == "operator-intent" and entry.request.command == "policy" and entry.request.field == nil end, "Save session settings")
local legacy = "orchplus://dispatch/" .. runtime.base64.encode(runtime.json.encode(save.request), { url = true })
check(#legacy > 8192, "the Save control's request exceeds the former 8192-byte link limit")
for _ = 1, 4 do first_api.intents(first); second_api.intents(second); idef.view(view, ctx) end
local after = saved_policy()
check(after.auto_rollover == true and #after.initial_dispatch_records == 24 and #after.worker_rollover_records == 24
	and commands("", "policy") == 1 and sent_by("second-window") == 0 and view.operator_intent ~= nil,
	"the large policy save commits exactly once although its unsettled intent stays rendered across ticks")

-- An intent no window settles expires visibly on the host and never runs later.
drop_acks = false
now += 31000
host_timers[#host_timers]()
check(view.operator_intent == nil and type(view.notice) == "string" and view.notice:find("will not run later", 1, true) ~= nil,
	"an unsettled intent expires after its bound with a visible notice")
first_api.intents(first)
check(commands("", "policy") == 1, "an expired intent never runs")

-- Continuation and the recovery guide: a host-block click names no window (clients of one window key
-- also share its shown session and focus), so a window that is not the continued origin leaves these
-- intents silently too; the palette commands run in the window that invoked them.
local function since(window, start) local n = 0; for i = start + 1, #sent do if sent[i].window == window then n += 1 end end; return n end
press(kind("config-close"), "Open ORCH+ controller")
for _, command in { "continue_controller", "recovery_guide" } do
	local start, picked, toasted = #sent, #picks, #toasts
	press(operator(command), command)
	second_api.intents(second); second_api.intents(second)
	check(since("second-window", start) == 0 and #picks == picked and #toasts == toasted and view.operator_intent ~= nil,
		command .. ": a window that is not the continued origin never takes, settles, prompts or toasts")
	first_api.intents(first)
	check(view.operator_intent == nil and since("", start) == 1 and since("second-window", start) == 0
		and #picks == picked + (if command == "continue_controller" then 1 else 0) and (picks[#picks] == nil or picks[#picks].window == ""),
		command .. ": the window that already is the continued origin runs the clicked button once")
end
local start, picked = #sent, #picks
palette[second_api].continue_controller.run(second)
check(#picks == picked + 1 and picks[#picks].window == "second-window" and picks[#picks].placeholder:find("Continue controller", 1, true) == 1
	and #sent == start, "ORCH+ Continue controller in this window opens its attested picker only in the invoking window")
local toasted = #toasts
palette[second_api].recovery_guide.run(second)
check(#toasts == toasted and #sent == start and #picks == picked + 1, "ORCH+ Reload recovery guide starts in the invoking window without acting elsewhere")

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
	local wf = fixture()
	local timers, events = {}, {}
	local selected, last_result, last_receipt, bridge_bytes, deferred_outcome, command_result, driver_result
	-- The controller block's published one-shot operator intent (host.luau publishes it on click).
	local intent, intent_serial = nil, 0
	local notice
	local notices, commands_seen = {}, {}
	-- Held modes keep SPAWN's retained outcome pending until the test releases it.
	local held = mode == "suspend" or mode == "auto_reconcile" or mode == "auto_reconcile_bounded" or mode == "auto_reconcile_all" or mode == "window_bookkeeping"
	local held_success, dropped_delivery
	-- auto_reconcile_all keeps one retained SPAWN outcome per request, as SPAWN's registry does.
	local retained_outcomes, successes = {}, {}
	local scoped_results = {}
	-- duplicate_claim queues claims like a lagging host; slow_receipt withholds host commit receipts.
	local lag_claims, lagged, hold_results, held_results = false, {}, false, 0
	local clock, catalog_sends, launch_deliveries = 1000, 0, 0
	local provision_bytes, rejected_bytes, queued_worker
	local ack_mode = mode == "ack" or mode == "ack_uncertain" or mode == "ack_terminal"
	local ack_sends, ack_id = 0, nil
	local chained = mode == "chain" or mode == "late" or mode == "reconcile_chain" or mode == "refused_chain" or mode == "auto_reconcile_worker" or ack_mode
	if chained then wf:catalog(0) end
	local window_tern = table.clone(fake)
	window_tern.now = function() return clock end
	local palette_commands = {}
	window_tern.command = function(def) palette_commands[def.id] = def end; window_tern.files = { button = function() end }
	window_tern.route = { link = function() error("ORCH+ must not claim links; controls are native buttons") end }
	window_tern.timer = function(_, fn) table.insert(timers, fn); return {} end
	local local_host = { id = "local", state = "connected", panes = { 9001, 9003 } }
	local panes = { [9001] = { pane = 9001, block = "orchplus.orchestrator", tab = 1 }, [9003] = { pane = 9003, block = "spawn.dispatch", tab = 1 } }
	local session = {}
	function session:pane(id) return panes[id] end
	function session:panes() local rows = {}; for _, pane in panes do table.insert(rows, pane) end; return rows end
	function session:sessions() return { { id = 7, tabs = { 1 } } } end
	function session:surface(pane, options)
		local block, role, bytes
		if pane == 9001 and options.root == "main.operator-intent" and intent == nil then return nil end
		if pane == 9003 then block = "spawn.dispatch"; role = "spawn.dispatch.response"; bytes = bridge_bytes or ""
		else
			block = "orchplus.orchestrator"
			role = if options.root:match("^main%.dispatch%-request") then "orchplus.request"
				elseif options.root == "main.workflow-index" then "orchplus.workflow"
				elseif options.root:sub(1, 21) == "main.workflow-worker-" then "orchplus.worker"
				elseif options.root == "main.operator-intent" then "orchplus.intent"
				else "orchplus.dispatch"
			local projection = state.project(wf.authority.registry)
			local scope = options.root:match("^main%.dispatch%-action%-(.+)$") or options.root:match("^main%.dispatch%-request%-(.+)$")
			projection.dispatch = dispatch.project(wf.authority.registry, wf.origin.logical_session_id, wf.origin.alias_nonce, scope or selected, scoped_results)
			local view = { pane = 42, alias_nonce = wf.origin.alias_nonce, orch_session_id = wf.origin.logical_session_id,
				action_serial = 0, dispatch_action = selected, dispatch_result = last_result, dispatch_receipt = last_receipt,
				dispatch_command_result = command_result, dispatch_driver_result = driver_result, scoped_results = scoped_results, notice = notice,
				operator_intent = intent }
			local rendered = assert(role_node(load("views").render(view, projection, "ready"), role, options.root:sub(6)))
			local span = rendered.p.spans[1]; bytes = if type(span) == "string" then span else span.t
		end
		return { surface = { role = "plugin." .. block }, main = { id = options.root, k = "text", p = { role = role, spans = { bytes } } } }
	end
	function session:event(pane, ev)
		if pane == 9001 then
			if ev.act == "operator-intent-done" then
				local input = runtime.json.decode(ev.value)
				check(ev.id == "main.operator-intent" and intent ~= nil and input.serial == intent.serial, "window settles exactly the consumed intent")
				intent = nil
			elseif ev.act == "dispatch-command" or ev.act == "dispatch-operator-command" then
				local command = runtime.json.decode(ev.value)
				if lag_claims and command.command == "claim" then table.insert(lagged, ev); return end
				table.insert(commands_seen, { command = command.command, action_id = command.action_id })
				wf.origin = clone(command.origin)
				local response = table.clone(wf.authority:apply(command))
				response.request_id = command.request_id; response.command = command.command
				response.action_id = response.action_id or command.action_id
				response.grant_id = command.grant_id or (if response.claim then response.claim.grant_id else nil)
				local workflow_only = table.find({ "observe", "policy", "pause", "resume", "answer", "cancel_gate", "recheck_gate", "sweep" }, command.command) ~= nil
				if ev.act == "dispatch-operator-command" then
					command_result = response
					if not workflow_only then driver_result = response end
				end
				if (ev.act == "dispatch-command" or response.ok) and not workflow_only then last_result = response end
				if response.ok and response.action_id then selected = response.action_id end
				if response.worker_id then queued_worker = response.worker_id end
				if response.action_id then
					local retained = scoped_results[response.action_id] or {}
					retained.result = response; scoped_results[response.action_id] = retained
				end
			elseif ev.act == "dispatch-select" then
				local input = runtime.json.decode(ev.value); selected = input.action_id; last_result = nil; command_result = nil
				if scoped_results[input.action_id] then scoped_results[input.action_id].result = nil end
			elseif ev.act == "dispatch-release-scope" then
				scoped_results[runtime.json.decode(ev.value).action_id] = nil
			elseif ev.act:sub(1, 16) == "dispatch-result/" then
				if hold_results then held_results += 1; return end -- The host has not processed it yet.
				local outer = runtime.json.decode(ev.value:sub(#"SPAWN_DISPATCH v1 " + 1))
				local a
				for _, candidate in wf.authority.registry.dispatch.actions do
					if candidate.request.request_id == outer.request_id and candidate.claim
						and candidate.claim.grant_id == ev.act:match("^dispatch%-result/([^/]+)/")
						and ev.act:match("/([^/]+)$") == wf.origin.window_epoch then a = candidate; break end
				end
				assert(a, "result must identify its original action and exact grant")
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
					if mode == "chain" or mode == "refused_chain" then check(ev.value == rejected_bytes, "lost host event replays captured rejection bytes, not a new native request") end
				end
				local response_hash = codec.sha256(ev.value)
				local input = wf:event("result", { action_id = a.request.action_id, executor = a.claim.executor, grant_id = a.claim.grant_id, response_bytes = ev.value })
				input.request_id = "result-" .. codec.sha256(a.claim.grant_id .. ":" .. wf.origin.window_epoch .. ":" .. response_hash)
				last_result = table.clone(wf.authority:apply(input))
				-- As host.luau action(): a committed result carries its deterministic observation request ID.
				last_result.request_id = input.request_id; last_result.action_id = a.request.action_id; last_result.grant_id = a.claim.grant_id
				if last_result.ok then last_receipt = { action_id = a.request.action_id, grant_id = a.claim.grant_id, response_sha256 = response_hash } end
				local retained = scoped_results[a.request.action_id] or {}
				retained.result = last_result
				if last_result.ok then retained.receipt = last_receipt end
				scoped_results[a.request.action_id] = retained
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
				notice = input.message; table.insert(notices, input.message)
			else error("Unexpected ORCH+ callback " .. tostring(ev.act)) end
			return
		end
		check(pane == 9003 and ev.id == "main.spawn-dispatch-response", "window targets current role-keyed SPAWN response node")
		local request = runtime.json.decode(ev.value)
		-- The guided-recovery owner probe is read-only; this fixture leaves it unanswered (state unknown).
		if ev.act == "owner_status" then return end
		table.insert(events, { op = ev.act, bytes = ev.value })
		if ev.act == "catalog" then
			catalog_sends += 1
			local success = frame(request, "catalog", { namespace = "fixture-spawn", host_key = "fixture-host", config_revision = 0, revision = 0, records = runtime.json.array() })
			if held then
				held_success = dispatch.decode_response(success, request)
				bridge_bytes = frame(request, "pending", {})
				deferred_outcome = dispatch.decode_response(bridge_bytes, request)
				if mode == "auto_reconcile_all" then retained_outcomes[request.request_id] = deferred_outcome; successes[request.request_id] = held_success end
			elseif mode == "expired_authorization" then
				-- SPAWN stages the first send behind a window challenge; the rechecked send succeeds.
				bridge_bytes = if catalog_sends == 1 then frame(request, "pending", { authorization_required = true }) else success
				deferred_outcome = dispatch.decode_response(bridge_bytes, request)
			elseif mode == "capacity_resume" or mode == "duplicate_claim" or mode == "slow_receipt" then bridge_bytes = success
			elseif mode == "oversize" then bridge_bytes = if catalog_sends == 1 then frame(request, "pending", {}) else success
			elseif catalog_sends == 1 then bridge_bytes = frame(request, "full", { resource = "catalog_capacity", current = 1, limit = 1, retryable = true, effect_started = false })
			else deferred_outcome = dispatch.decode_response(success, request) end -- Leave old full visible until the ordered status fence.
		elseif ev.act == "mailbox_provision" then
			bridge_bytes = frame(request, "provisioned", { handle = "mailbox-fixture", binding_digest = string.rep("a", 64),
				capabilities = runtime.json.array({ "report-files-v1", if mode == "ack_terminal" then "worker-poll-v1" else "native-ask-v1", "coordinator-control-v1" }) })
			provision_bytes = bridge_bytes
			if mode == "late" then
				deferred_outcome = dispatch.decode_response(provision_bytes, request)
				bridge_bytes = frame(request, "pending", { authorization_required = true })
			elseif mode == "auto_reconcile_worker" then
				held_success = dispatch.decode_response(provision_bytes, request)
				bridge_bytes = frame(request, "pending", { authorization_required = true })
				deferred_outcome = dispatch.decode_response(bridge_bytes, request)
			end
		elseif ev.act == "launch" then
			bridge_bytes = if ack_mode then frame(request, "awaiting_acceptance", { pane_binding = {
				pane_id = "9002", window_key = "", window_epoch = request.origin_binding.window_epoch, native_session_id = "7", window_host_id = "local" } })
				else frame(request, "rejected", nil, { code = "binding_mismatch", message = "Exact fresh SPAWN authorization challenge required" })
		elseif ev.act == "mailbox_publish_ack" then
			ack_sends += 1; ack_id = request.action_id
			bridge_bytes = frame(request, "published", if mode == "ack_terminal" then {} else { wake_status = "awaiting_window" })
			deferred_outcome = dispatch.decode_response(bridge_bytes, request)
		elseif ev.act == "status" then
			if ack_mode then
				check(request.target_request_id == wf:action(ack_id).request.request_id, "ACK wake status queries original publication identity")
			end
			bridge_bytes = if mode == "oversize" then frame(request, "rejected", nil, { code = "oversize" })
				else frame(request, "found", { outcome = retained_outcomes[request.target_request_id] or deferred_outcome })
		else error("Unexpected SPAWN operation " .. tostring(ev.act)) end
	end
	local cx = { session = session, sessions = { current = function() return { id = 7, host = "local" } end },
		agents = { list = function() return {} end },
		hosts = { list = function() return { local_host } end, current = function() return local_host end },
		window_key = function() return "" end, toast = function(_cx, _level, _title, detail) notice = detail end,
		new_block = function(_cx, block, _config, placement, options)
			-- The controller shares tab 1 with 9003, so no bridge-only tab exists: the bridge opens its own tab.
			check(block == "spawn.dispatch" and placement == "tab" and options.focus == false and options.target == nil,
				"native bridge creation opens the bridge tab, never splits the controller and never steals focus")
			return 9003
		end }
	cx.prompt = function()
		return { next = function(_promise, callback) callback("Explicit chained fixture task", nil, table.clone(cx)) end }
	end
	cx.pick = function()
		return { next = function(_promise, callback) callback({ continue_controller = true }, nil, table.clone(cx)) end }
	end
	local window_chunk = assert(loadstring(runtime.fs.read(root .. "/window.luau"), "dispatch-window-consumer"))
	setfenv(window_chunk, setmetatable({ tern = window_tern, require = load }, { __index = environment })); local api = window_chunk()
	-- The owner clicks a dispatch button: its host block publishes the exact request as a one-shot
	-- intent, which this window's observation consumer runs once.
	local function click(command)
		local request = { command = command, source_nonce = wf.origin.alias_nonce, orch_session_id = wf.origin.logical_session_id, action_id = selected }
		if command == "queue" then
			request.record_id = "native"; request.record_revision = 0; request.catalog_revision = 0
			request.cwd = "/fixture"; request.placement = "split"; request.coordinator = true
		end
		intent_serial += 1
		intent = { version = 1, source_nonce = wf.origin.alias_nonce, serial = "fixture-intent-" .. tostring(intent_serial), kind = "dispatch", request = request }
		api.intents(table.clone(cx))
	end
	local function tick()
		clock += 500; local callback = assert(table.remove(timers, 1), "native timer must remain scheduled")
		callback(table.clone(cx)) -- Fresh callback context, never a captured click context.
	end
	local function count_events(op) local n = 0; for _, e in events do if e.op == op then n += 1 end end; return n end
	local function count_commands(name, action_id)
		local n = 0
		for _, c in commands_seen do if c.command == name and (action_id == nil or c.action_id == action_id) then n += 1 end end
		return n
	end
	if chained then
		palette_commands.continue_controller.run(table.clone(cx)) -- A fresh incarnation continues from its own palette.
		click("queue")
		check(wf.authority.registry.sessions[wf.origin.logical_session_id].orchestrator ~= nil and #events == 0, "chained startup reserves coordinator before native provisioning")
		if ack_mode then
			for _ = 1, 20 do
				tick()
				if ack_id and wf:action(ack_id).response then break end
			end
			local a = assert(wf:action(ack_id))
			local grant, request_bytes = a.claim.grant_id, a.request_bytes
			if mode == "ack_terminal" then
				check(a.phase == "complete" and ack_sends == 1 and #events == 3
					and wf.authority.registry.dispatch.workers[queued_worker].compacted_floor == 0,
					"terminal ACK completes once without native wake or status request and without receipt")
				return
			end
			check(a.phase == "claimed" and wf.authority.registry.dispatch.workers[queued_worker].accept_pending,
				"driver retains ACK1 wake before separate semantic accept")
			clock += 31000
			for _ = 1, 4 do tick() end
			check(wf:action(ack_id).phase == "claimed" and wf:action(ack_id).claim.grant_id == grant
				and wf:action(ack_id).request_bytes == request_bytes and ack_sends == 1,
				"busy ACK wake survives deadline using original grant without another publication")
			deferred_outcome.payload.wake_status = if mode == "ack_uncertain" then "uncertain" else "submitted"
			for _ = 1, 20 do
				tick()
				if wf:action(ack_id).phase ~= "claimed" then break end
			end
			check(wf:action(ack_id).phase == (if mode == "ack_uncertain" then "uncertain" else "complete")
				and wf:action(ack_id).claim.grant_id == grant and ack_sends == 1,
				"ACK status settles or retains uncertainty under original grant without repeat effect")
			if mode == "ack_uncertain" then
				tick() -- Observe the committed uncertain receipt and stop automatic continuation.
				click("reconcile")
				for _ = 1, 2 do tick() end
				check(ack_sends == 1 and wf:action(ack_id).phase == "uncertain"
					and wf.authority.registry.dispatch.workers[queued_worker].receipts["1"].publish,
					"read-only uncertain ACK reconciliation never resends publication or clears outbox")
			else
				check(wf.authority.registry.dispatch.workers[queued_worker].compacted_floor == 0
					and not wf.authority.registry.dispatch.workers[queued_worker].receipts["1"].publish,
					"submitted ACK ask is queued evidence only, never producer consumption")
			end
			return
		end
		if mode == "late" then
			tick(); tick(); tick()
			local provision_id = selected
			local provision_grant = wf:action(provision_id).claim.grant_id
			check(events[2].op == "status" and wf:action(provision_id).phase == "claimed", "pending provision has a correlated retained-status response waiting")
			clock += 31000; tick() -- Callback arrives after a long gap (host suspension) with status-found evidence already available.
			check(wf:action(provision_id).phase == "complete" and last_receipt.grant_id == provision_grant
				and wf.authority.registry.dispatch.workers[queued_worker].phase == "provisioned", "late timer consumes conclusive status-found provisioning before considering timeout")
			tick(); tick()
			local launch_grant = wf:action(selected).claim.grant_id
			clock += 31000; tick(); tick() -- The direct rejection is also retained across a delayed callback after a gap.
			check(last_receipt.grant_id == launch_grant and launch_deliveries == 1, "late direct rejection is committed under its original launch grant")
			check(#events == 3 and events[1].op == "mailbox_provision" and events[2].op == "status" and events[3].op == "launch", "late outcomes never repeat provisioning or launch")
		elseif mode == "reconcile_chain" then
			tick(); tick()
			local provision = wf:action(selected)
			assert(wf:apply("lost", { action_id = selected, executor = provision.claim.executor, grant_id = provision.claim.grant_id }).ok)
			click("reconcile")
			for _ = 1, 5 do tick() end
			check(#events == 2 and events[1].op == "mailbox_provision" and events[2].op == "launch" and launch_deliveries == 1,
				"read-only reconciliation never reexecutes provisioning and does not suppress the separately granted first launch")
		elseif mode == "refused_chain" then
			for _ = 1, 10 do
				tick()
				if launch_deliveries == 1 then break end
			end
			check(launch_deliveries == 1, "first worker has a captured launch outcome awaiting host delivery")
			local first_action, grant = selected, wf:action(selected).claim.grant_id
			click("queue")
			local refusal_id = command_result.request_id
			check(command_result.code == "orchestrator_slot_occupied" and selected == first_action,
				"second operator start refuses without replacing original active action")
			tick(); tick()
			check(command_result.request_id == refusal_id and command_result.code == "orchestrator_slot_occupied"
				and wf:action(first_action).phase == "complete" and last_receipt.grant_id == grant,
				"failed second start preserves captured delivery and refusal while original grant settles")
			check(#events == 2 and launch_deliveries == 2, "failed second start never resends either original SPAWN effect")
		elseif mode == "auto_reconcile_worker" then
			tick(); tick(); tick()
			local provision_id = selected
			check(events[1].op == "mailbox_provision" and events[2].op == "status" and wf:action(provision_id).phase == "claimed",
				"SPAWN still reports provisioning pending; its exact claim stays live")
			for _ = 1, 7 do clock += 4000; tick() end -- 32 s of awake time without a conclusive outcome.
			check(wf:action(provision_id).phase == "uncertain" and count_commands("lost", provision_id) == 1,
				"awake effect deadline leaves provisioning uncertain and pins its worker")
			deferred_outcome = held_success -- SPAWN's retained registry now holds the definitive outcome.
			for _ = 1, 8 do
				clock += 1000; tick()
				if wf:action(provision_id).phase ~= "uncertain" then break end
			end
			check(wf:action(provision_id).phase == "complete" and wf.authority.registry.dispatch.workers[queued_worker].phase == "provisioned",
				"automatic read-only reconciliation settles the worker's definitive outcome without the owner")
			for _ = 1, 8 do
				tick()
				local launch = wf:action(wf.authority.registry.dispatch.workers[queued_worker].launch_action_id)
				if launch_deliveries == 1 and launch and launch.phase == "complete" then break end
			end
			check(count_events("mailbox_provision") == 1 and count_events("launch") == 1 and count_commands("claim", provision_id) == 1
				and count_commands("lost", provision_id) == 1, "automatic reconciliation never re-claims or re-executes provisioning; the separate launch runs once")
		else
			-- The lost launch delivery is replayed after 1 s of awake backoff (two ticks), not on the next
			-- tick; the extra ticks after settlement also show no SPAWN effect is ever repeated.
			for _ = 1, 12 do tick() end
			check(#events == 2 and events[1].op == "mailbox_provision" and events[2].op == "launch" and launch_deliveries == 2, "provision-to-launch chain performs each SPAWN effect once despite a lost host result")
		end
		local worker = wf.authority.registry.dispatch.workers[queued_worker]
		check(wf:action(worker.launch_action_id).phase == "complete" and worker.phase == "held" and worker.reason.code == "binding_mismatch"
			and last_result.code == "bridge_rejected", "observed launch rejection commits precise prerequisite instead of timing out as uncertainty")
		check(wf.authority.registry.sessions[wf.origin.logical_session_id].controller.pending_executors == 0
			and wf.authority.registry.sessions[wf.origin.logical_session_id].orchestrator ~= nil, "rejection settles only its executor and retains coordinator reservation")
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
		for _ = 1, 12 do
			tick()
			if wf:action(first).phase == "complete" and api.bookkeeping().watched == 0 then break end
		end
		local kept = api.bookkeeping()
		check(wf:action(first).phase == "complete" and kept.executed == 0 and kept.watched == 0 and kept.auto_reconcile == 0 and catalog_sends == 1,
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
		for _ = 1, 4 do tick(); if dropped_delivery then break end end
		check(dropped_delivery and wf:action(first).phase == "claimed", "SPAWN's outcome after wake is captured once; its first host event is lost")
		clock += 3600000; tick() -- Another suspension before the commit receipt is observed.
		tick()
		check(wf:action(first).phase == "complete" and last_result.code == "bridge_committed" and count_commands("lost") == 0 and catalog_sends == 1,
			"the captured observation replays across a suspension instead of expiring its receipt deadline; no effect repeats")
		-- The replay now lands one tick later (1 s awake backoff), so the window has not yet read its
		-- receipt. Let it do so before the next catalog compacts this settled read: the real host keeps
		-- the scope through retained.completed (see callbacks), but this fixture's surface does not.
		tick()
		click("catalog"); tick(); tick(); tick()
		local second = selected
		for _ = 1, 6 do clock += 4000; tick() end
		check(second ~= first and wf:action(second).phase == "claimed" and count_commands("lost", second) == 0, "awake time below the effect deadline keeps waiting")
		clock += 4000; tick()
		check(wf:action(second).phase == "uncertain" and count_commands("lost", second) == 1 and catalog_sends == 2
			and notice:find("after the effect deadline", 1, true) ~= nil, "awake time still expires the effect deadline into retained uncertainty")
		click("catalog"); tick(); tick(); tick()
		local third = selected
		for _ = 1, 5 do clock += 4000; tick() end
		deferred_outcome = held_success -- SPAWN completes; its status answer becomes visible only on the expiring turn.
		clock += 4000; tick()
		check(wf:action(third).phase == "claimed" and count_commands("lost", third) == 0, "awake time just below the deadline still waits for the retained outcome")
		clock += 4000; tick() -- The awake deadline elapses on this turn.
		check(wf:action(third).phase == "complete" and last_result.code == "bridge_committed" and count_commands("lost", third) == 0 and catalog_sends == 3,
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
			end
			for _ = 1, 40 do
				clock += 1500; tick()
				if wf:action(first).phase == "complete" and wf:action(second).phase == "complete" then break end
			end
			check(wf:action(first).phase == "complete" and wf:action(second).phase == "complete",
				"every uncertain read-only action is reconciled automatically, independent of selection")
			check(catalog_sends == 2 and count_commands("claim", first) == 1 and count_commands("claim", second) == 1
				and count_commands("lost", first) == 1 and count_commands("lost", second) == 1, "read-only reconciliation never re-claims or re-executes either read")
			return
		end
		if mode == "auto_reconcile_bounded" then
			for _ = 1, 32 do clock += 4000; tick() end -- 144 s awake; every backoff elapses with SPAWN still pending.
			check(count_events("status") == reads + 4 and wf:action(first).phase == "uncertain", "exactly four bounded automatic reads, each finding SPAWN still pending")
			check(catalog_sends == 1 and count_commands("claim", first) == 1 and count_commands("lost", first) == 1,
				"automatic reads never re-claim, re-execute or re-mark the effect")
			local exhausted = false
			for _, message in notices do
				if message:find("Automatic read-only reconciliation found no definitive", 1, true) then exhausted = true end
			end
			check(exhausted, "exhausted automatic reads tell the owner and leave the owner control")
			deferred_outcome = held_success
			click("reconcile")
			for _ = 1, 4 do tick() end
			check(wf:action(first).phase == "complete" and catalog_sends == 1 and count_commands("claim", first) == 1,
				"the owner's read-only control still settles the retained outcome without another effect")
			return
		end
		for _ = 1, 4 do clock += 1000; tick() end
		check(count_events("status") == reads + 1 and wf:action(first).phase == "uncertain",
			"one automatic status read finds SPAWN still pending and leaves the action uncertain")
		deferred_outcome = held_success
		for _ = 1, 10 do
			clock += 1000; tick()
			if wf:action(first).phase ~= "uncertain" then break end
		end
		check(wf:action(first).phase == "complete" and last_result.code == "bridge_committed", "a later automatic read settles the definitive completed outcome")
		check(catalog_sends == 1 and count_events("status") == reads + 2 and count_commands("claim", first) == 1 and count_commands("lost", first) == 1,
			"automatic reconciliation reads once per attempt and never re-claims or re-executes")
		tick()
		local second = uncertain_catalog()
		local request = wf:action(second).request
		deferred_outcome = dispatch.decode_response(frame(request, "rejected", nil, { code = "binding_mismatch", message = "SPAWN refused before any effect" }), request)
		for _ = 1, 6 do
			clock += 1000; tick()
			if wf:action(second).phase ~= "uncertain" then break end
		end
		check(wf:action(second).phase == "complete" and last_result.code == "bridge_rejected" and catalog_sends == 2 and count_commands("claim", second) == 1,
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
		deferred_outcome = dispatch.decode_response(frame(request, "uncertain", nil, { code = "target_unavailable", message = "Native effect outcome uncertain; do not retry" }), request)
		for _ = 1, 20 do
			clock += 1000; tick()
			if wf:action(id).response ~= nil then break end
		end
		for _ = 1, 12 do clock += 1000; tick() end
		check(wf:action(id).phase == "uncertain" and wf:action(id).response.status == "uncertain" and count_commands("retry") == 0 and catalog_sends == 1,
			"a committed uncertain outcome stays uncertain and is never retried automatically")
		-- SPAWN's challenge expired unconsumed: its status read is definitive pre-effect evidence.
		deferred_outcome = dispatch.decode_response(frame(request, "full", { resource = "window_authorization", current = 1, limit = 1, retryable = true, effect_started = false }), request)
		for _ = 1, 40 do
			clock += 1000; tick()
			if wf:action(id).phase ~= "uncertain" then break end
		end
		check(wf:action(id).phase == "backpressure" and last_result.code == "backpressure" and count_commands("retry") == 0 and catalog_sends == 1,
			"the automatic read commits expired-authorization evidence on the uncertain action as retryable backpressure")
		for _ = 1, 6 do tick() end -- 3 s awake: inside the recheck backoff.
		check(count_commands("retry") == 0 and wf:action(id).phase == "backpressure", "no automatic recheck inside its awake backoff")
		for _ = 1, 24 do
			tick()
			if wf:action(id).phase == "complete" then break end
		end
		check(count_commands("retry", id) == 1 and count_commands("claim", id) == 2 and catalog_sends == 2 and wf:action(id).phase == "complete"
			and last_result.code == "bridge_committed", "after its backoff the exact request is rechecked once under a fresh grant and settles")
		check(count_commands("lost", id) == 1 and wf:action(id).request_bytes == request_bytes and wf:action(id).retry_count == 1,
			"the recheck reuses the same immutable action and is not marked lost again")
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
			if wf:action(waiting).phase == "complete" then break end
		end
		check(wf:action(waiting).phase == "complete" and catalog_sends == 1 and count_events("catalog") == 1,
			"an uncertain read-only catalog frees its slot and the refused claim resumes automatically, executing once")
		local relaunched = 0
		for _, id in occupied do relaunched += count_commands("claim", id) end
		check(relaunched == 0 and wf:action(occupied[1]).phase == "uncertain",
			"capacity resume only re-claims never-granted ready work; the uncertain read is never claimed or executed again")
		return
	end
	if mode == "duplicate_claim" then
		-- A lagging host: the window's claims wait in the host queue while its timer keeps ticking.
		lag_claims = true
		click("catalog")
		local waiting = selected
		for _ = 1, 6 do tick() end -- 3 s awake before the host processes the first claim.
		check(#lagged >= 1 and #lagged <= 3, "a claim in flight is re-sent only with backoff, not on every tick")
		lag_claims = false
		local queued = lagged; lagged = {}
		for _, ev in queued do session:event(9001, ev) end -- The host catches up in order.
		check(#queued >= 2 and wf:action(waiting).phase == "claimed" and last_result.code == "effect_already_claimed" and not last_result.ok,
			"the first claim is granted and the visible result is the duplicate's refusal")
		for _ = 1, 10 do
			tick()
			if wf:action(waiting).phase == "complete" then break end
		end
		check(wf:action(waiting).phase == "complete" and catalog_sends == 1 and count_commands("lost") == 0 and last_result.code == "bridge_committed",
			"a duplicate claim refusal neither holds nor strands the claimed action; the driver executes it once and completes")
		return
	end
	if mode == "slow_receipt" then
		hold_results = true
		click("catalog")
		local waiting = selected
		for _ = 1, 10 do tick(); if held_results > 0 then break end end
		check(held_results == 1 and catalog_sends == 1 and wf:action(waiting).phase == "claimed", "SPAWN's outcome is captured and delivered to the host once")
		for _ = 1, 120 do tick() end -- 60 s awake with the host commit receipt still pending.
		check(held_results <= 9, "receipt-pending replays back off instead of repeating every tick")
		check(count_commands("lost", waiting) == 0 and #notices == 0 and wf:action(waiting).phase == "claimed",
			"a host receipt slower than the 30 s effect deadline does not turn the delivered outcome into lost")
		hold_results = false
		for _ = 1, 40 do
			tick()
			if wf:action(waiting).phase == "complete" then break end
		end
		check(wf:action(waiting).phase == "complete" and catalog_sends == 1 and count_commands("lost", waiting) == 0 and last_result.code == "bridge_committed",
			"the next backed-off replay commits the captured outcome once the host catches up; no effect repeats")
		tick() -- The window reads its receipt before the next catalog compacts this settled read (see suspend).
		-- Still bounded: a host that renders no progress at all eventually leaves retained uncertainty.
		hold_results = true
		local delivered = held_results
		click("catalog")
		local stuck = selected
		for _ = 1, 10 do tick(); if held_results > delivered then break end end
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
		click("retry"); tick(); tick()
		check(wf:action(selected).phase == "claimed" and wf:action(selected).claim.grant_id ~= previous_grant
			and #events == 2 and events[2].bytes == events[1].bytes, "real window resubmits exact request once for a fresh grant")
		tick()
		check(events[3].op == "status" and wf:action(selected).phase == "claimed", "old full surface cannot settle new grant before fresh ordered status")
		tick()
	end
	check(wf:action(selected).phase == "complete" and last_result.code == "bridge_committed", "real window consumer commits conclusive catalog without ambiguous occupancy")
end
for _, mode in { "oversize", "retry", "chain", "late", "reconcile_chain", "refused_chain", "ack", "ack_uncertain", "ack_terminal",
	"suspend", "auto_reconcile", "auto_reconcile_bounded", "auto_reconcile_worker", "auto_reconcile_all", "capacity_resume", "expired_authorization",
	"duplicate_claim", "slow_receipt", "window_bookkeeping" } do
	if section == nil or section == mode then window_consumer(mode) end
end
-- Each retirement section is independently runnable under the existing native callback budget.
local function retirement_fixture()
	local f = fixture(); local id = f:accepted(true)
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
	function f:watermark()
		local w = self:worker()
		local mark = { version = 1, type = "receipt_watermark", mailbox_handle = w.mailbox_handle,
			through_seq = w.accepted_seq, receipt_chain_sha256 = w.receipt_chain }
		for _, k in { "logical_session_id", "worker_id", "worker_generation", "launch_request_id", "work_id", "enrolment_token" } do mark[k] = w[k] end
		local queued = self:apply("poll", { worker_id = id, bytes = "watermark" }); assert(queued.ok)
		local page = assert(codec.project_page(runtime.json.encode(mark), self:action(queued.action_id).request.selector))
		assert(self:finish(queued.action_id, "complete", runtime.json.decode(page)).ok)
	end
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
	local stop = f:apply("poll", { worker_id = id }); local request = f:action(stop.action_id).request
	check(request.op == "stop" and request.target_request_id == f:worker().launch_request_id and request.pane_binding.pane_id == "9002", "settled final watermark grants exact launched pane stop")
	check(f:apply("poll", { worker_id = id }).code == "operation_pending", "pending stop cannot be duplicated")
	check(dispatch.decode_response(frame(request, "stopped", { pane_binding = request.pane_binding, observation = "idle" }), request) == nil, "idle is never stopped proof")
	assert(f:finish(stop.action_id, "stopped", { pane_binding = request.pane_binding, observation = "exited" }).ok)
	check(f.authority.registry.sessions[f.origin.logical_session_id].orchestrator ~= nil, "native stop alone does not free slot")
	local retire = f:apply("poll", { worker_id = id }); local rr = f:action(retire.action_id).request
	check(rr.op == "mailbox_retire" and rr.mode == "retire" and rr.report_floor == f:worker().accepted_seq and rr.reply_floor == f:worker().reply_seq, "mailbox retirement carries exact final floors and grant")
	check(f:finish(retire.action_id, "retired", {}).code == "coordinator_retired", "retirement result atomically uses normal generation-bound owner release")
	local old = f:worker().coordinator_owner_id
	check(f.authority.registry.sessions[f.origin.logical_session_id].orchestrator == nil and f.authority.registry.retired[old] ~= nil, "owner blank retains owner tombstone and worker history")
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
	-- Explicit pre-extension persisted shape: no grant and no protocol marker.
	g.authority.registry.dispatch.workers[id].coordinator_protocol = nil
	local w = g.authority.registry.dispatch.workers[id]
	local launch = g:action(w.launch_action_id)
	launch.request.enrolment.coordinator_owner_id = nil; launch.request.enrolment.coordinator_generation = nil
	launch.request_bytes = runtime.json.encode(launch.request)
	g.memory.value = clone(g.authority.registry) -- Explicit compatible old persisted launch shape.
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
	assert(f:finish(manifest.action_id, "complete", runtime.json.decode(assert(codec.project_page(framed.manifest, f:action(manifest.action_id).request.selector)))).ok)
	local last
	for _, chunk in framed.chunks do
		local queued = f:apply("poll", { worker_id = id }); assert(queued.ok)
		local page = runtime.json.decode(assert(codec.project_page(chunk, f:action(queued.action_id).request.selector)))
		last = f:finish(queued.action_id, "complete", page)
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
			check(failed:finish(queued.action_id, "complete", page).code == "persistence_failed", "failed rejection save publishes no settlement")
			check(failed:action(queued.action_id).phase == "claimed" and failed.authority.registry.dispatch.workers[failed_id].rejected_report == nil,
				"failed save retains original claimed read and no exposed hold")
			failed.memory.fail = false
			check(failed:finish(queued.action_id, "complete", page).code == "uncommitted_observation"
				and failed.authority.registry.sessions[failed.origin.logical_session_id].controller.pending_executors == 1,
				"same-runtime retry cannot bypass failed-result observation fence or release its occupied slot")
		else
			assert(failed:finish(queued.action_id, "complete", page).ok)
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
	check(f.authority:apply(clone(finish)).code == "finish_requested", "exact finish command is idempotent")
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
	local refused = f:apply("result", { action_id = retire.action_id, executor = f.origin.window_epoch, grant_id = f:action(retire.action_id).claim.grant_id,
		response_bytes = frame(f:action(retire.action_id).request, "rejected", nil, { code = "producer_unsettled", message = "The stopped producer journal is not settled at the authorized floors; nothing was retired" }) })
	local w = f.authority.registry.dispatch.workers[id]
	check(refused.code == "retirement_refused" and f:action(retire.action_id).phase == "complete" and w.phase == "accepted"
		and w.reason.code == "retirement_refused" and not w.mailbox_retired, "exact pre-effect refusal settles the attempt without holding the worker or retiring the mailbox")
	check(not dispatch.unresolved(f.authority.registry, f.origin.logical_session_id, f.origin.owner_id), "a refused retirement releases its effect slot and blocks no owner clearing")
	check(f:apply("poll", { worker_id = id }).code == "retirement_refused", "the driver never re-issues a refused retirement by itself")
	check(state.rehydrate(clone(f.authority.registry)) ~= nil, "a refused retirement marker passes persistence validation")
	check(f:apply("finish", { worker_id = id }).code == "retirement_rearmed", "explicit owner control re-arms one fresh retirement")
	local again = f:apply("poll", { worker_id = id }); local request = f:action(again.action_id).request
	check(again.ok and again.action_id ~= retire.action_id and request.op == "mailbox_retire" and request.mode == "retire"
		and request.grant_id ~= f:action(retire.action_id).request.grant_id, "the re-armed retirement carries a fresh grant")
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
	check(saved.sweep_enabled == true and saved.sweep_time == "03:00", "the nightly sweep defaults on at 03:00 local time")
	for _, bad in { "3:00", "24:00", "12:60", "noon", "", 300 } do
		check(f:apply("policy", { policy = { sweep_time = bad } }).code == "invalid_policy", "sweep time " .. tostring(bad) .. " is refused")
	end
	check(f:apply("policy", { policy = { sweep_enabled = "yes" } }).code == "invalid_policy", "the sweep switch is a boolean")
	check(f:apply("policy", { policy = { sweep_time = "23:59", sweep_enabled = false } }).ok
		and dispatch.policy(f.authority.registry, sid).sweep_time == "23:59" and dispatch.policy(f.authority.registry, sid).sweep_enabled == false,
		"valid sweep settings save through the ordinary policy command")
	local legacy = clone(f.authority.registry)
	legacy.dispatch.policies[sid].sweep_enabled = nil; legacy.dispatch.policies[sid].sweep_time = nil
	-- A genuine pre-sweep policy also predates the rollover-routing and concurrency fields.
	for _, key in { "worker_rollover_records", "worker_rollover_provider", "worker_rollover_account", "worker_rollover_model", "coordinator_rollover_records",
		"coordinator_rollover_provider", "coordinator_rollover_account", "coordinator_rollover_model", "concurrency_limit" } do legacy.dispatch.policies[sid][key] = nil end
	check(not dispatch.valid(legacy.dispatch, legacy), "a pre-sweep stored policy is accepted only at the restore boundary")
	local migrated = assert(state.rehydrate(clone(legacy))).dispatch.policies[sid]
	check(migrated.sweep_enabled == true and migrated.sweep_time == "03:00" and migrated.poll_ms == saved.poll_ms, "pre-sweep policies migrate with the sweep defaults")
	local partial = clone(legacy); partial.dispatch.policies[sid].sweep_time = "03:00"
	check(state.rehydrate(partial) == nil, "a partial sweep policy is rejected, not defaulted")
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
	local f = fixture(); local id = f:accepted(false)
	local progress = f:event("reply", { worker_id = id }); assert(f.authority:apply(progress).ok)
	local delivery = clone(f.authority.registry.dispatch.workers[id].workflow.report_request)
	local noop = f:event("reply", { worker_id = id }); assert(f.authority:apply(noop).code == "report_request_pending")
	assert(f:apply("intake", { worker_id = id, bytes = f:report(id, 2, "reply_ack", { message_id = delivery.message_id, reply_seq = delivery.reply_seq,
		reply_sha256 = codec.sha256(delivery.bytes), status = "recorded" }, { action_id = delivery.action_id, action_revision = delivery.action_revision }) }).ok)
	assert(f:apply("intake", { worker_id = id, bytes = f:report(id, 3, "HEARTBEAT", { state = "idle", request_id = delivery.request_id }) }).ok)
	local old = f:event("pause"); assert(f.authority:apply(old).ok)
	local read = f:apply("catalog"); assert(read.ok)
	local claim = f:apply("claim", { action_id = read.action_id, executor = f.origin.window_epoch }); assert(claim.ok)
	for index = 1, 270 do assert(f:apply(if index % 2 == 1 then "resume" else "pause").ok) end
	assert(f:apply("resume").ok)
	check(f.authority.registry.dispatch.commands[old.request_id] == nil, "settled actionless command history is actually reclaimed")
	local before = runtime.json.encode(f.authority.registry)
	check(f.authority:apply(old).code == "stale_command" and runtime.json.encode(f.authority.registry) == before, "compacted old pause cannot restore stale owner intent")
	check(f.authority:apply(progress).code == "stale_command" and f.authority:apply(noop).code == "stale_command"
		and f.authority.registry.dispatch.workers[id].workflow.report_request == nil, "compacted old issued and no-effect progress intents cannot create another request cycle")
	check(f:finish(read.action_id, "catalog", { namespace = "fixture-spawn", host_key = "fixture-host", config_revision = 0, revision = 0, records = runtime.json.array() }).ok, "newer control commands cannot make the original delayed effect result uncommittable")
	local restored = state.rehydrate(clone(f.authority.registry))
	check(restored ~= nil and restored.dispatch.command_cursors[f.origin.logical_session_id].seq > old.command_seq, "durable stale-command barrier survives restore independently of history")
	local corrupt = clone(f.authority.registry); corrupt.dispatch.command_cursors = nil
	check(state.rehydrate(corrupt) == nil, "retained sequenced commands cannot restore without their durable replay barrier")
	corrupt = clone(f.authority.registry); corrupt.dispatch.command_cursors[f.origin.logical_session_id].seq = 1
	check(state.rehydrate(corrupt) == nil, "restored replay barrier cannot move behind retained command evidence")
	local legacy = f:event("pause"); legacy.command_seq = nil
	check(f.authority:apply(legacy).code == "invalid_command", "live clients cannot bypass the monotonic intent contract")
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
	restored = assert(state.rehydrate(legacy))
	check(restored.dispatch.catalogs[sid] == nil and restored.dispatch.workers[id].worker_id == id
		and restored.dispatch.workers[id].enrolment_token == stored.dispatch.workers[id].enrolment_token
		and restored.dispatch.command_cursors[sid].seq == stored.dispatch.command_cursors[sid].seq,
		"one-way legacy cache invalidation preserves exact workers and replay barriers")
	check(not dispatch.valid(legacy.dispatch, legacy), "legacy cache is accepted only at the explicit restore boundary")
	legacy.dispatch.catalogs[sid].unexpected = true
	check(state.rehydrate(legacy) == nil, "migration cannot hide malformed historical catalogs")
	for _, payload in {
		{ revision = 0, records = runtime.json.array() },
		{ namespace = "fixture-spawn", host_key = "fixture-host", config_revision = 1, revision = 0, records = runtime.json.array() },
	} do
		local rejected = fixture(); local request = rejected:apply("catalog")
		check(rejected:finish(request.action_id, "catalog", payload).code == "invalid_catalog",
			"live catalogs require a complete matching source join, never the historical cache format")
	end
end
if section == nil or section == "continuation" then
	local f = fixture(); local id = f:accepted(false)
	assert(f:apply("intake", { worker_id = id, bytes = f:report(id, 2, "ASK", { question = "Survive reload?", options = runtime.json.array({ { id = "yes", label = "Yes" } }) }) }).ok)
	local pending = f:apply("poll", { worker_id = id }); local action = f:action(pending.action_id)
	assert(f:apply("claim", { action_id = pending.action_id, executor = f.origin.window_epoch }).ok)
	local original = clone(f.authority.registry.dispatch.workers[id]); local claim = clone(f:action(pending.action_id).claim)
	local bytes = frame(action.request, "published", {})
	local old_result = f:event("result", { action_id = pending.action_id, executor = claim.executor, grant_id = claim.grant_id, response_bytes = bytes })
	f.authority = host.new_authority(f.memory); assert(f.authority:load().ok)
	f.origin.window_epoch = "replacement-window"
	f.controller_pane = "9010"
	check(not f:apply("poll", { worker_id = id }).ok, "reload never automatically adopts retained worker aliases")
	check(f:apply("continue_controller", { expected_revision = f.authority.registry.revision, operator_verified = true }).ok, "explicit exact-owner continuation establishes status-only replacement route")
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
	local altered = corrupt.dispatch.actions[attached.action_id]
	altered.response.payload.pane_binding.pane_id = "9999"
	altered.response_bytes = frame(altered.request, "attached", altered.response.payload)
	check(state.rehydrate(corrupt) == nil, "self-consistent response bytes still cannot forge a different selected attachment on restore")
	local coordinator = fixture(); local coordinator_id = coordinator:accepted(true)
	local activation = coordinator:apply("poll", { worker_id = coordinator_id }); assert(activation.ok)
	assert(coordinator:apply("claim", { action_id = activation.action_id, executor = coordinator.origin.window_epoch }).ok)
	coordinator.authority = host.new_authority(coordinator.memory); assert(coordinator.authority:load().ok)
	coordinator.origin.window_epoch = "continued-coordinator-window"
	assert(coordinator:apply("continue_controller", { expected_revision = coordinator.authority.registry.revision, operator_verified = true }).ok)
	local owner = coordinator.authority.registry.sessions[coordinator.origin.logical_session_id].orchestrator
	check(owner.phase == "uncertain" and owner.pending_executors == 1 and coordinator:action(activation.action_id).phase == "uncertain",
		"controller continuation cannot reactivate uncertain coordinator authority or clear its old activation executor")
end
if section == nil or section == "wake_separation" then
	local clock = { now_ms = 1000, mono_ms = 1000, epoch = "wake-host" }
	local f = fixture(function() return clone(clock) end); local ids = {}
	for _ = 1, 4 do
		local id = f:accepted(false); table.insert(ids, id)
		local w = f.authority.registry.dispatch.workers[id]
		assert(f:apply("observe", { worker_id = id, pane_binding = w.pane_binding, native_state = "working" }).ok)
		assert(f:apply("intake", { worker_id = id, bytes = f:report(id, 2, "HEARTBEAT", { state = "working" }) }).ok)
		local queued = f:apply("poll", { worker_id = id }); local request = f:action(queued.action_id).request
		check(f:finish(queued.action_id, "published", { wake_status = "awaiting_window", wake_effect_started = false,
			wake_target_request_id = request.request_id, wake_target_action_id = request.action_id }).ok, "known publication commits independently of never-started notification")
		check(f:action(queued.action_id).phase == "complete" and f.authority.registry.dispatch.workers[id].wakes[request.action_id] ~= nil, "publication releases slot but retains durable wake obligation")
	end
	check(f.authority.registry.sessions[f.origin.logical_session_id].controller.pending_executors == 0, "four busy workers do not occupy four execution slots merely waiting for idle")
	for _, id in ids do
		local queued = f:apply("poll", { worker_id = id }); assert(queued.ok, queued.message)
		check(f:action(queued.action_id).request.op == "mailbox_read" and f:finish(queued.action_id, "missing", {}).ok, "busy generation continues mailbox/receipt read progress")
	end
	local id = ids[1]; local w = f.authority.registry.dispatch.workers[id]
	assert(f:apply("observe", { worker_id = id, pane_binding = w.pane_binding, native_state = "idle" }).ok)
	local wake = f:apply("poll", { worker_id = id }); check(f:action(wake.action_id).request.op == "native_wake", "fresh safe idle creates explicit bounded notification operation")
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
	check(defaults.auto_rollover == false and defaults.rollover_threshold_pct == 80 and defaults.rollover_include_coordinator == false
		and defaults.quota_routing == false and #defaults.excluded_workers == 0, "CP3 Config defaults extend the existing session policy")
	for _, bad in { 0, 100, 80.5, -1, "80", true } do
		local before = runtime.json.encode(f.authority.registry)
		check(f:apply("policy", { policy = { rollover_threshold_pct = bad }, expected_policy = saved() }).code == "invalid_policy"
			and runtime.json.encode(f.authority.registry) == before, "rollover threshold " .. tostring(bad) .. " is refused with nothing changed")
	end
	for _, bad in { { auto_rollover = "yes" }, { rollover_include_coordinator = 1 }, { quota_routing = runtime.json.null }, { paused = true }, { unknown = true }, {} } do
		local before = runtime.json.encode(f.authority.registry)
		check(f:apply("policy", { policy = bad, expected_policy = saved() }).code == "invalid_policy" and runtime.json.encode(f.authority.registry) == before,
			"policy rejects undocumented, non-boolean or empty settings with nothing changed")
	end
	for _, threshold in { 1, 99 } do
		check(f:apply("policy", { policy = { rollover_threshold_pct = threshold }, expected_policy = saved() }).code == "policy_updated"
			and saved().rollover_threshold_pct == threshold, "rollover threshold " .. tostring(threshold) .. " is accepted")
	end
	check(f:apply("policy", { policy = { auto_rollover = true, rollover_include_coordinator = true, quota_routing = true }, expected_policy = saved() }).code == "policy_updated"
		and saved().auto_rollover and saved().rollover_include_coordinator and saved().quota_routing and saved().poll_ms == 5000,
		"partial Config save changes only the named settings")
	local displayed = saved()
	assert(f:apply("pause").ok)
	local before = runtime.json.encode(f.authority.registry)
	check(f:apply("policy", { policy = { auto_rollover = false }, expected_policy = displayed }).code == "policy_conflict"
		and runtime.json.encode(f.authority.registry) == before and saved().auto_rollover, "stale editor is refused after an intervening pause; nothing changes")
	assert(f:apply("resume").ok)
	local restored = assert(state.rehydrate(clone(f.authority.registry)))
	check(restored.dispatch.policies[sid].rollover_threshold_pct == 99 and restored.dispatch.policies[sid].quota_routing, "Config settings persist through strict restore")
	-- quota_routing now has a consumer; the remaining unrouted fixtures need explicit selection.
	assert(f:apply("policy", { policy = { quota_routing = false } }).ok)
	-- Exactly-CP2 stored policies migrate only at the explicit restore boundary.
	local legacy = clone(f.authority.registry)
	legacy.dispatch.policies[sid] = { paused = true, poll_ms = 2000, heartbeat_ms = 10000, stale_ms = 30000, automatic_reports = true }
	check(not dispatch.valid(legacy.dispatch, legacy), "CP2 policy shape is accepted only at the restore boundary")
	local migrated = assert(state.rehydrate(clone(legacy))).dispatch.policies[sid]
	check(migrated.paused and migrated.poll_ms == 2000 and migrated.automatic_reports and not migrated.auto_rollover and migrated.rollover_threshold_pct == 80
		and not migrated.rollover_include_coordinator and not migrated.quota_routing and #migrated.excluded_workers == 0, "old stored policy loads with CP3 defaults")
	for _, forged in { { paused = false, poll_ms = 2000 }, { paused = false, poll_ms = 2000, heartbeat_ms = 10000, stale_ms = 30000, automatic_reports = true, unknown = 1 } } do
		local corrupt = clone(legacy); corrupt.dispatch.policies[sid] = forged
		check(state.rehydrate(corrupt) == nil, "partial or unknown-field stored policies are rejected, not defaulted")
	end
	local corrupt = clone(f.authority.registry); corrupt.dispatch.policies[sid].rollover_threshold_pct = 100
	check(state.rehydrate(corrupt) == nil, "stored out-of-range threshold is rejected")
	-- Exclusion is honored by automatic report scheduling and never stops anything.
	local id = f:accepted(false)
	local other = f:accepted(false)
	assert(f:apply("policy", { policy = { automatic_reports = true, heartbeat_ms = 5000, stale_ms = 600000 }, expected_policy = saved() }).ok)
	for _, worker_id in { id, other } do
		local w = f.authority.registry.dispatch.workers[worker_id]
		assert(f:apply("observe", { worker_id = worker_id, pane_binding = clone(w.pane_binding), native_state = "idle" }).ok)
	end
	clock.mono_ms += 6000
	assert(f.authority:apply({ kind = "workflow_tick" }).ok)
	check(projected(id).due_report and projected(other).due_report, "fixture makes both safe idle workers due for automatic reports")
	check(f:apply("policy", { policy = { excluded_workers = { "worker-unknown" } }, expected_policy = saved() }).code == "invalid_policy",
		"exclusion must name a managed worker of this session")
	check(f:apply("policy", { policy = { excluded_workers = { id, id } }, expected_policy = saved() }).code == "invalid_policy",
		"duplicate exclusions are refused")
	local function actions_for(worker_id) local n = 0; for _, a in f.authority.registry.dispatch.actions do if a.worker_id == worker_id then n += 1 end end; return n end
	local w_before, actions_before = clone(f.authority.registry.dispatch.workers[id]), actions_for(id)
	check(f:apply("policy", { policy = { excluded_workers = { id } }, expected_policy = saved() }).code == "policy_updated"
		and projected(id).orchestration_excluded and not projected(id).due_report and projected(other).due_report,
		"unticked managed worker is skipped by automatic report scheduling; others remain due")
	local w = f.authority.registry.dispatch.workers[id]
	check(w.phase == w_before.phase and w.stop_action_id == nil and w.finish == nil and w.retirement == nil and w.mailbox_retire_action_id == nil
		and runtime.json.encode(w.pane_binding) == runtime.json.encode(w_before.pane_binding) and actions_for(id) == actions_before,
		"exclusion never stops, finishes, retires or rebinds the worker")
	clock.mono_ms += 6000
	assert(f.authority:apply({ kind = "workflow_tick" }).ok)
	check(not projected(id).due_report, "later ticks keep the excluded worker out of automatic scheduling")
	check(f:apply("observe", { worker_id = id, pane_binding = clone(w.pane_binding), native_state = "idle" }).ok, "excluded worker health observation continues")
	check(state.rehydrate(clone(f.authority.registry)).dispatch.policies[sid].excluded_workers[1] == id, "exclusion persists by durable worker_id")
	check(f:apply("policy", { policy = { excluded_workers = {} }, expected_policy = saved() }).code == "policy_updated" and projected(id).due_report,
		"re-ticking restores automatic scheduling eligibility")
end
-- Verified worker rollover (CP4). Epoch-bound clocks make native liveness evidence fresh.
local function rollover_fixture()
	local clock = { now_ms = 1000, mono_ms = 1000, epoch = "rollover-host" }
	local f = fixture(function() return clone(clock) end)
	local id = f:accepted(false)
	assert(f:apply("observe", { worker_id = id, pane_binding = clone(f.authority.registry.dispatch.workers[id].pane_binding), native_state = "idle" }).ok)
	return f, id
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
		and r.history[1].phase == "requested" and r.history[2].phase == "checkpoint_pending", "requested and checkpoint_pending edges are durable and controller-bound")
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
	assert(f:finish(stop, "stopped", { pane_binding = clone(f:action(stop).request.pane_binding), observation = "exited" }).ok)
	r = rollover_of(f, hid)
	local phases = {}; for _, edge in r.history do table.insert(phases, edge.phase) end
	check(table.concat(phases, ",") == "requested,checkpoint_pending,requested,checkpoint_pending,checkpoint_verified,successor_granted,successor_created,handover_accepted,predecessor_stop_requested,predecessor_closed,complete",
		"every edge is recorded in order: " .. table.concat(phases, ","))
	check(r.stop_observation == "exited" and worker_of(f, succ_id).phase == "accepted" and worker_of(f, succ_id).finish == nil and worker_of(f, succ_id).stopped == nil,
		"observed predecessor exit completes; successor keeps the work")
	check(state.rehydrate(clone(f.authority.registry)) ~= nil, "completed rollover restores")
	local forged = clone(f.authority.registry); forged.dispatch.rollovers[hid].stop_observation = nil
	check(state.rehydrate(forged) == nil, "a closed/complete phase cannot restore without its exit evidence")
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
	check(r.phase == "successor_granted" and r.hold.code == "successor_launch_failed" and r.hold.message:find("input_too_large", 1, true) ~= nil,
		"failed successor launch retains phase and evidence")
	check(pred.phase == "accepted" and pred.finish == nil and pred.stop_action_id == nil and #actions_of(f, id, "stop") == 0, "failed successor launch leaves the predecessor alive and unstopped")
	check(f:apply("rollover", { worker_id = id, trigger = "owner" }).code == "rollover_in_progress", "no second successor is granted beside a failed one")
	check(state.rehydrate(clone(f.authority.registry)) ~= nil, "held rollover restores")
	check(f:apply("cancel_rollover", { worker_id = id }).code == "rollover_cancelled" and rollover_of(f, hid).phase == "cancelled"
		and rollover_of(f, hid).hold.code == "successor_launch_failed", "definitively failed launch can be cancelled with evidence retained")
	local again = f:apply("rollover", { worker_id = id, trigger = "owner" })
	check(again.ok and again.code == "rollover_requested" and again.handover_id ~= hid, "a new rollover uses a new handover identity")
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
	assert(f:apply("observe", idle).ok)
	local successors = 0; for _, w in f.authority.registry.dispatch.workers do if w.handover_id == hid then successors += 1 end end
	check(successors == 1 and #actions_of(f, succ_id, "mailbox_provision") == 1, "post-reload progress creates no duplicate successor or provision")
	successor_created(f, succ_id)
	check(rollover_of(f, hid).phase == "successor_created" and #actions_of(f, succ_id, "launch") == 1, "retained provision continues to exactly one launch")
	local g, gid = rollover_fixture()
	local ghid, gsucc = rollover_granted(g, gid)
	local launch = successor_provisioned(g, gsucc)
	assert(g:apply("claim", { action_id = launch, executor = g.origin.window_epoch }).ok)
	g.authority = host.new_authority(g.memory); assert(g.authority:load().ok)
	check(g:action(launch).phase == "uncertain", "reload turns the claimed successor launch uncertain")
	assert(g:apply("continue_controller", { expected_revision = g.authority.registry.revision, operator_verified = true }).ok)
	assert(g:apply("observe", { worker_id = gid, pane_binding = clone(worker_of(g, gid).pane_binding), native_state = "idle" }).ok)
	check(rollover_of(g, ghid).phase == "successor_granted" and rollover_of(g, ghid).hold.code == "successor_launch_uncertain", "uncertain launch after reload holds")
	check(g:apply("cancel_rollover", { worker_id = gid }).code == "rollover_effect_started" and #actions_of(g, gsucc, "launch") == 1
		and worker_of(g, gid).finish == nil, "uncertain successor launch is neither cancelled, duplicated nor allowed to stop the predecessor")
	-- A replacement window incarnation fences the never-claimed successor intent instead of replaying it.
	local h, hid_worker = rollover_fixture()
	local hhid, hsucc = rollover_granted(h, hid_worker)
	h.authority = host.new_authority(h.memory); assert(h.authority:load().ok)
	h.origin.window_epoch = "replacement-window"
	assert(h:apply("continue_controller", { expected_revision = h.authority.registry.revision, operator_verified = true }).ok)
	local provision = h:action(actions_of(h, hsucc, "mailbox_provision")[1])
	check(provision.phase == "resolved" and provision.resolution.evidence == "never_claimed" and rollover_of(h, hhid).hold.code == "successor_launch_fenced"
		and #actions_of(h, hsucc, "launch") == 0 and #actions_of(h, hsucc, "mailbox_provision") == 1 and worker_of(h, hid_worker).finish == nil,
		"a changed window fences the unexecuted successor grant with evidence; no replay, duplicate or predecessor stop")
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
	check(projected(id).due_rollover, "idle accepted worker at the threshold is due")
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
-- Coordinator rollover (CP4): never two managed coordinators; successor only after observed closure and release.
local function coordinator_owner(f) return f.authority.registry.sessions[f.origin.logical_session_id].orchestrator end
local function coordinator_ready()
	local f, id = retirement_fixture(); f:drain(); assert(f:ack("activation").ok)
	return f, id
end
local function coordinator_retirement_requested(f, id)
	local requested = f:apply("rollover", { worker_id = id, trigger = "owner" }); assert(requested.ok and requested.code == "rollover_requested", requested.message)
	assert(rollover_of(f, requested.handover_id).kind == "coordinator" and rollover_of(f, requested.handover_id).phase == "checkpoint_pending")
	assert(answer_checkpoint(f, id, "coordinator-cp-1").ok)
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
		capabilities = runtime.json.array({ "report-files-v1", "native-ask-v1", "coordinator-control-v1" }), limits = {} }).ok)
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
if section == nil or section == "rollover_coordinator" then
	local f, id = coordinator_ready()
	local old_owner, old_generation = coordinator_owner(f).owner_id, coordinator_owner(f).generation
	local old_token = worker_of(f, id).activation.activation_token
	local hid = coordinator_retirement_requested(f, id)
	check(coordinator_owner(f).owner_id == old_owner and coordinator_owner(f).phase == "retiring" and worker_of(f, id).retirement ~= nil,
		"verified checkpoint quiesces the predecessor through the existing typed retirement; the slot stays occupied")
	check(f:queue(true).code == "rollover_reserved" and handover_successors(f, hid) == 0, "no unrelated start or successor while the predecessor is quiescing")
	check(f:apply("cancel_rollover", { worker_id = id }).code == "rollover_effect_started", "coordinator rollover cannot be cancelled after retirement was requested")
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
	check(r.phase == "successor_granted" and f.authority.registry.retired[old_owner] ~= nil and owner.owner_id ~= old_owner and owner.generation > old_generation
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
	r = rollover_of(f, hid)
	local phases = {}; for _, edge in r.history do table.insert(phases, edge.phase) end
	check(table.concat(phases, ",") == "requested,checkpoint_pending,checkpoint_verified,retirement_requested,predecessor_released,predecessor_stop_requested,predecessor_closed,owner_retired,successor_granted,successor_created,handover_accepted,complete",
		"every coordinator edge is recorded in order: " .. table.concat(phases, ","))
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
	check(f:queue(true).code == "rollover_reserved" and handover_successors(f, hid) == 0, "after reload no unrelated start or successor can take the slot")
	-- Ambiguous closure: explicit operator-assisted recovery of the exact orchestrator owner.
	local function owner_event(kind, fields)
		local event = { kind = kind, request_id = "coordinator-recovery-" .. kind .. "-" .. tostring(f.authority.registry.revision), orch_session_id = f.origin.logical_session_id,
			target = "orchestrator", expected_owner_id = old.owner_id, expected_generation = old.generation }
		for k, v in fields do event[k] = v end
		return f.authority:apply(event)
	end
	assert(owner_event("observe_owner", { status = "unavailable", evidence = "observed" }).ok)
	assert(owner_event("observe_owner", { status = "operator verified stopped", owner_active = false, pending_executors = 0, evidence = "operator_attested", operator_verified = true }).ok)
	local intent = owner_event("begin_recovery", { expected_revision = f.authority.registry.revision }); assert(intent.ok, intent.message)
	assert(owner_event("confirm_recovery", { expected_revision = intent.revision, intent_id = intent.intent_id, evidence = "operator_attested", operator_verified = true }).ok)
	assert(f:apply("observe", { worker_id = id, pane_binding = clone(worker_of(f, id).pane_binding), native_state = "unknown" }).ok)
	local r = rollover_of(f, hid)
	check(r.phase == "successor_granted" and r.closure == "operator_attested" and handover_successors(f, hid) == 1
		and coordinator_owner(f).managed_worker_id == r.successor_worker_id and coordinator_owner(f).owner_id ~= old.owner_id,
		"operator-attested recovery lets the retained handover reserve exactly one successor")
	assert(f:apply("observe", { worker_id = id, pane_binding = clone(worker_of(f, id).pane_binding), native_state = "unknown" }).ok)
	check(handover_successors(f, hid) == 1 and #actions_of(f, r.successor_worker_id, "mailbox_provision") == 1, "later progress never duplicates the successor")
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
	check(rollover_of(f, hid).phase == "complete", "successor activated")
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
	local f, id = coordinator_ready()
	local hid = coordinator_retirement_requested(f, id)
	assert(coordinator_released(f, id, coordinator_stop_action(f, id)).code == "coordinator_retired")
	local r = rollover_of(f, hid); local succ_id, owner = r.successor_worker_id, coordinator_owner(f)
	assert(r.phase == "successor_granted" and owner.owner_id == r.successor_owner_id)
	local provision = actions_of(f, succ_id, "mailbox_provision"); assert(#provision == 1)
	local provisioned = f:action(provision[1]).request
	check(provisioned.handover_id == hid and provisioned.handover_sha256 == codec.sha256(hid .. ":" .. r.handover_token)
		and not runtime.json.encode(provisioned):find(r.handover_token, 1, true), "the successor mailbox is provisioned with the handover ID and pair digest, never the token")
	assert(f:finish(provision[1], "provisioned", { handle = "mailbox-coordinator-successor", binding_digest = string.rep("c", 64),
		capabilities = runtime.json.array({ "report-files-v1", "native-ask-v1", "coordinator-control-v1" }), limits = {} }).ok)
	assert(f:finish(worker_of(f, succ_id).launch_action_id, "awaiting_acceptance", { pane_binding = successor_pane(f) }).ok)
	assert(rollover_of(f, hid).phase == "successor_created")
	local read = f:apply("poll", { worker_id = succ_id }); assert(read.ok, read.message)
	local request = f:action(read.action_id).request
	assert(request.op == "mailbox_read" and request.selector.stream == "report" and request.selector.slot == 1, request.op)
	assert(f:apply("claim", { action_id = read.action_id, executor = f.origin.window_epoch }).ok)
	local problem = { code = "binding_mismatch", message = "Acceptance differs from the issued assignment or handover." }
	local refused = f:apply("result", { action_id = read.action_id, executor = f.origin.window_epoch, grant_id = f:action(read.action_id).claim.grant_id,
		response_bytes = frame(request, "rejected", nil, problem) })
	r = rollover_of(f, hid)
	check(refused.code == "bridge_rejected" and worker_of(f, succ_id).phase == "held" and r.phase == "successor_created" and r.hold.code == "successor_unaccepted",
		"a refused successor acceptance holds the coordinator handover")
	local text = r.hold.message
	check(text:find(problem.message, 1, true) ~= nil and text:find("already stopped and retired, so no coordinator is active", 1, true) ~= nil
		and text:find("fenced recovery for orchestrator owner " .. owner.owner_id, 1, true) ~= nil and text:find("keeps running", 1, true) == nil,
		"the hold reports the retired predecessor, the SPAWN diagnostic and the recovery path: " .. text)
	check(f:queue(true).code == "rollover_reserved" and handover_successors(f, hid) == 1 and #actions_of(f, succ_id, "launch") == 1,
		"the held handover keeps the slot; nothing is relaunched")
	local function owner_event(kind, fields)
		local event = { kind = kind, request_id = "successor-recovery-" .. kind .. "-" .. tostring(f.authority.registry.revision), orch_session_id = f.origin.logical_session_id,
			target = "orchestrator", expected_owner_id = owner.owner_id, expected_generation = owner.generation }
		for k, v in fields do event[k] = v end
		return f.authority:apply(event)
	end
	assert(owner_event("observe_owner", { status = "unavailable", evidence = "observed" }).ok)
	assert(owner_event("observe_owner", { status = "operator verified stopped", owner_active = false, pending_executors = 0, evidence = "operator_attested", operator_verified = true }).ok)
	local intent = owner_event("begin_recovery", { expected_revision = f.authority.registry.revision }); assert(intent.ok, intent.message)
	local confirmed = owner_event("confirm_recovery", { expected_revision = intent.revision, intent_id = intent.intent_id, evidence = "operator_attested", operator_verified = true })
	assert(confirmed.ok, confirmed.message)
	assert(f:apply("observe", { worker_id = succ_id, pane_binding = successor_pane(f), native_state = "exited" }).ok)
	r = rollover_of(f, hid)
	check(r.phase == "cancelled" and r.hold.code == "successor_owner_recovered" and coordinator_owner(f) == nil
		and handover_successors(f, hid) == 1 and #actions_of(f, succ_id, "launch") == 1, "fenced recovery of the successor's owner closes the rollover without relaunching")
	local fresh = f:queue(true)
	check(fresh.ok and fresh.code == "task_queued" and coordinator_owner(f).managed_worker_id == fresh.worker_id, "the freed slot accepts an explicit new coordinator start")
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
	check(due(), "idle activated coordinator at threshold with both flags is due")
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
			outcome = f:finish(queued.action_id, "complete", runtime.json.decode(assert(codec.project_page(object, request.selector))))
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
		capabilities = runtime.json.array({ "report-files-v1", "native-ask-v1", "coordinator-control-v1" }), limits = {} }).ok)
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
		outcome = f:finish(queued.action_id, "complete", runtime.json.decode(assert(codec.project_page(object, request.selector))))
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
	check(rollover_of(f, hid).phase == "handover_accepted" and successors == 1 and #actions_of(f, succ_id, "mailbox_provision") == 1
		and #actions_of(f, succ_id, "launch") == 1 and #actions_of(f, succ_id, "attach_worker") == 1 and #actions_of(f, succ_id, "accept") == 1
		and worker_of(f, id).finish == nil, "handover reaches handover_accepted with exactly one provision, launch, attachment and accept")
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
	check(g:apply("recheck_report", { worker_id = gsucc }).code == "worker_unbound", "re-check after reload requires explicit worker continuation first")
end
-- Explicit verified attach of a hand-opened native agent pane (never automatic, never a terminal).
if section == nil or section == "adopt" then
	local ADOPT = "operator_verified_exact_agent_pane"
	local function same_pane(a, b)
		return type(a) == "table" and type(b) == "table" and a.pane_id == b.pane_id and a.window_epoch == b.window_epoch and a.window_key == b.window_key
			and a.native_session_id == b.native_session_id and a.window_host_id == b.window_host_id
	end
	local function hand_pane(fx, id, changes)
		local p = { pane_id = id or "9020", window_key = fx.origin.window_key, window_epoch = fx.origin.window_epoch, native_session_id = fx.origin.native_session_id, window_host_id = fx.origin.window_host_id }
		for k, v in changes or {} do p[k] = v end
		return p
	end
	local function attach(fx, pane, fields)
		local event = { record_id = "native", record_revision = 0, catalog_revision = 0, prompt = "Adopted fixture task.", pane_binding = pane, attestation = ADOPT }
		for k, v in fields or {} do event[k] = v end
		return fx:apply("adopt", event)
	end
	local function provisioned(fx, queued)
		assert(fx:finish(queued.action_id, "provisioned", { handle = "mailbox-adopted", binding_digest = string.rep("d", 64),
			capabilities = runtime.json.array({ "report-files-v1", "native-ask-v1" }), limits = {} }).ok)
		return worker_of(fx, queued.worker_id).launch_action_id
	end
	local f = fixture(); f:catalog(0)
	local pane = hand_pane(f)
	check(attach(f, hand_pane(f, nil, { native_session_id = "8" })).code == "invalid_task", "a pane of another native session or host is refused")
	check(attach(f, hand_pane(f, nil, { window_epoch = "old-window" })).code == "invalid_task", "a stale window-scoped attestation is refused")
	check(attach(f, pane, { attestation = "assumed" }).code == "invalid_task", "adoption requires the exact operator attestation")
	check(attach(f, pane, { catalog_revision = 1 }).code == "catalog_changed", "a stale catalog selection is refused")
	local queued = attach(f, pane)
	check(queued.ok and queued.code == "adoption_queued", "explicit verified attach queues a normal worker generation")
	local id = queued.worker_id
	check(same_pane(worker_of(f, id).adopt_pane_binding, pane) and worker_of(f, id).pane_binding == nil and #actions_of(f, id, "mailbox_provision") == 1,
		"adoption provisions through the existing mailbox path before any native effect")
	check(attach(f, pane).code == "pane_bound", "a pane with a pending adoption is never adopted twice")
	local adopt_id = provisioned(f, queued)
	local adopt = f:action(adopt_id).request
	check(adopt.op == "adopt" and adopt.attestation == ADOPT and same_pane(adopt.pane_binding, pane) and adopt.cwd == nil and adopt.fresh == nil
		and adopt.enrolment.handover_id == nil and adopt.enrolment.enrolment_token == worker_of(f, id).enrolment_token, "SPAWN receives an adopt request bound to the exact pane, not a launch")
	check(f:finish(adopt_id, "awaiting_acceptance", { pane_binding = hand_pane(f, "9021") }).code == "binding_mismatch", "a different pane outcome can never bind the adopted worker")
	assert(f:finish(adopt_id, "awaiting_acceptance", { pane_binding = pane }).ok)
	local w = worker_of(f, id)
	check(w.phase == "awaiting_acceptance" and same_pane(w.pane_binding, pane), "the attested pane becomes the worker's launch pane binding")
	assert(f:apply("intake", { worker_id = id, bytes = f:report(id, 1, "ACCEPTED", { assignment_sha256 = w.assignment_sha256 }) }).ok)
	assert(f:finish(f:apply("poll", { worker_id = id }).action_id, "published", {}).ok)
	local accept = f:apply("poll", { worker_id = id }); assert(f:action(accept.action_id).request.op == "accept")
	assert(f:finish(accept.action_id, "accepted", {}).ok)
	check(worker_of(f, id).phase == "accepted" and #actions_of(f, id, "mailbox_provision") == 1 and #actions_of(f, id, "adopt") == 1
		and #actions_of(f, id, "launch") == 0 and #actions_of(f, id, "accept") == 1, "adopted worker reaches accepted with exactly one provision, one adopt ask and no launch")
	check(f:apply("reply", { worker_id = id }).ok, "after acceptance the adopted worker uses the ordinary workflow")
	check(attach(f, pane).code == "pane_bound", "an accepted adopted pane is never adopted again")
	local launched = f:accepted(false)
	check(attach(f, clone(worker_of(f, launched).pane_binding)).code == "pane_bound", "a launched worker's pane cannot be adopted")
	check(state.rehydrate(clone(f.authority.registry)) ~= nil, "adopted worker restores")
	local forged = clone(f.authority.registry); forged.dispatch.workers[id].adopt_pane_binding.pane_id = "9099"
	check(state.rehydrate(forged) == nil, "an adopted worker's pane binding cannot diverge from its attested pane")
	local native_only = fixture(); native_only:catalog(0)
	native_only.authority.registry.dispatch.catalogs[native_only.origin.logical_session_id].records[1].backend = "local-terminal"
	native_only.memory.value = clone(native_only.authority.registry)
	check(attach(native_only, hand_pane(native_only)).code == "unsupported_capability", "terminal/shell records can never adopt a pane")
	-- Busy, non-agent or out-of-scope panes are refused by SPAWN before any native ask.
	local g = fixture(); g:catalog(0)
	local gq = attach(g, hand_pane(g)); local gadopt = provisioned(g, gq)
	assert(g:apply("claim", { action_id = gadopt, executor = g.origin.window_epoch }).ok)
	local ga = g:action(gadopt)
	check(g:apply("result", { action_id = gadopt, executor = g.origin.window_epoch, grant_id = ga.claim.grant_id, response_bytes = frame(ga.request, "rejected", nil,
		{ code = "target_unavailable", message = "Target pane is not an idle native agent in the exact window, session and host; nothing was sent" }) }).ok, "SPAWN pre-effect refusal commits")
	check(worker_of(g, gq.worker_id).phase == "held" and worker_of(g, gq.worker_id).pane_binding == nil and g:action(gadopt).phase == "complete"
		and g:apply("claim", { action_id = gadopt, executor = g.origin.window_epoch }).code == "effect_already_claimed", "a refused adoption holds the worker and is never retried")
	check(attach(g, hand_pane(g)).code == "adoption_queued", "a refused pane may be attached again only by a new explicit owner action")
	-- An uncertain native ask is never repeated and keeps the pane bound.
	local u = fixture(); u:catalog(0)
	local uq = attach(u, hand_pane(u)); local uadopt = provisioned(u, uq)
	assert(u:apply("claim", { action_id = uadopt, executor = u.origin.window_epoch }).ok)
	local grant = u:action(uadopt).claim
	assert(u:apply("lost", { action_id = uadopt, executor = grant.executor, grant_id = grant.grant_id }).ok)
	check(u:action(uadopt).phase == "uncertain" and u:apply("retry", { action_id = uadopt }).code == "retry_refused"
		and u:apply("claim", { action_id = uadopt, executor = u.origin.window_epoch }).code == "effect_already_claimed" and #actions_of(u, uq.worker_id, "adopt") == 1,
		"an uncertain adoption is never repeated")
	check(attach(u, hand_pane(u)).code == "pane_bound", "an uncertain adoption keeps the pane bound")
	-- Reload mid-adopt holds the claimed ask as uncertain.
	local m = fixture(); m:catalog(0)
	local mq = attach(m, hand_pane(m)); local madopt = provisioned(m, mq)
	assert(m:apply("claim", { action_id = madopt, executor = m.origin.window_epoch }).ok)
	m.authority = host.new_authority(m.memory); assert(m.authority:load().ok)
	check(m:action(madopt).phase == "uncertain" and worker_of(m, mq.worker_id).pane_binding == nil, "reload mid-adopt holds the claimed ask as uncertain")
	assert(m:apply("continue_controller", { expected_revision = m.authority.registry.revision, operator_verified = true }).ok)
	check(attach(m, hand_pane(m)).code == "pane_bound" and #actions_of(m, mq.worker_id, "adopt") == 1, "reload never re-adopts or repeats the ask")
	local p = fixture(); p:catalog(0); assert(p:apply("pause").ok)
	check(attach(p, hand_pane(p)).code == "session_paused", "pause holds new adoptions")
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
	check(coordinator_released(f, id, stop.action_id).code == "coordinator_retired" and rollover_of(f, hid).phase == "cancelled"
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
	local readback = f:apply("readback_publication", { action_id = ack.action_id })
	check(readback.ok and readback.code == "readback_queued" and f:action(ack.action_id).phase == "resolved" and f:action(ack.action_id).resolution.evidence == "publication_readback"
		and coordinator_owner(f).pending_executors == 0, "readback resolves the uncertain attempt with explicit evidence and releases its executor count")
	check(f:apply("readback_publication", { action_id = ack.action_id }).code == "readback_refused", "a resolved attempt cannot be read back again")
	local again = f:apply("poll", { worker_id = new_id }); assert(again.ok, again.message)
	local old_request, new_request = f:action(ack.action_id).request, f:action(again.action_id).request
	check(again.action_id ~= ack.action_id and new_request.op == "mailbox_publish_ack" and new_request.request_id ~= old_request.request_id
		and new_request.ack_b64 == old_request.ack_b64 and new_request.ack_sha256 == old_request.ack_sha256, "the outbox re-issues exactly the same immutable ACK bytes")
	check(state.rehydrate(clone(f.authority.registry)) ~= nil, "resolved readback attempt restores")
	assert(f:finish(again.action_id, "already_published", {}).ok)
	local accept = f:apply("poll", { worker_id = new_id }); assert(accept.ok, accept.message); assert(f:action(accept.action_id).request.op == "accept")
	assert(f:finish(accept.action_id, "accepted", {}).ok)
	check(worker_of(f, new_id).activation ~= nil and #actions_of(f, new_id, "mailbox_publish_ack") == 2, "after readback the generation is accepted and its activation is issued")
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
		local f = fixture(); local id = f:launched(coordinator)
		assert(f:apply("intake", { worker_id = id, bytes = f:report(id, 1, "ACCEPTED", { assignment_sha256 = worker_of(f, id).assignment_sha256 }) }).ok)
		assert(f:finish(f:apply("poll", { worker_id = id }).action_id, "published", {}).ok)
		local accept = f:apply("poll", { worker_id = id }); assert(accept.ok, accept.message)
		local old_request = clone(f:action(accept.action_id).request); assert(old_request.op == "accept")
		assert(f:apply("claim", { action_id = accept.action_id, executor = f.origin.window_epoch }).ok)
		local claim = clone(f:action(accept.action_id).claim)
		local old_origin = clone(f.origin)
		f.authority = host.new_authority(f.memory); assert(f.authority:load().ok)
		f.origin.window_epoch = "replacement-window"; f.controller_pane = "9010"
		assert(f:apply("continue_controller", { expected_revision = f.authority.registry.revision, operator_verified = true }).ok)
		if coordinator then check(coordinator_owner(f).phase == "uncertain", "controller continuation alone never reactivates the reloaded coordinator") end
		-- SPAWN owner recovery revoked the never-consumed accept; the continued route reads that outcome.
		local problem = { code = if legacy then "binding_mismatch" else "authorization_revoked", message = REVOKED }
		local read = f:apply("result", { action_id = accept.action_id, executor = claim.executor, grant_id = claim.grant_id, response_bytes = frame(old_request, "rejected", nil, problem) })
		check(read.ok and read.code == "accept_reissue" and worker_of(f, id).phase == "accepted" and worker_of(f, id).accept_pending and f:action(accept.action_id).phase == "complete",
			"a revoked never-consumed acceptance is pre-effect, not a terminal hold")
		if legacy then
			-- Durable state written before this fix: the worker was already held with the revocation.
			local stored = f.authority.registry.dispatch.workers[id]; stored.phase = "held"; stored.reason = clone(problem)
			f.memory.value = clone(f.authority.registry)
		end
		check(f:apply("poll", { worker_id = id }).code == "worker_unbound", "nothing is re-issued before explicit worker attachment")
		local pane = { pane_id = "9011", window_key = "", window_epoch = f.origin.window_epoch, native_session_id = "7", window_host_id = "local" }
		local attached = f:apply("continue_worker", { worker_id = id, pane_binding = pane,
			continuation_proof = dispatch.continuation_proof(f.authority.registry, worker_of(f, id)), operator_verified = true }); assert(attached.ok, attached.message)
		local original = worker_of(f, id)
		assert(f:finish(attached.action_id, "attached", { pane_binding = pane, previous_origin_binding = clone(original.origin_binding), previous_pane_binding = clone(original.pane_binding) }).ok)
		check(worker_of(f, id).phase == "accepted" and worker_of(f, id).accept_pending and (not coordinator or coordinator_owner(f).phase == "running"),
			"explicit attested attachment resumes the generation" .. (if legacy then " from its pre-fix hold" else ""))
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
	check(f:action(pub.action_id).phase == "resolved" and f:action(again.action_id).phase == "complete", "one resolved readback attempt and one settled publication")
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
		check(f:action(pub.action_id).phase == "uncertain", name .. ": continuation keeps the stopped executor's publication uncertain, never resolved")
		local pane = { pane_id = "9009", window_key = "", window_epoch = f.origin.window_epoch, native_session_id = "7", window_host_id = "local" }
		local function attach()
			return f:apply("continue_worker", { worker_id = fid, pane_binding = pane,
				continuation_proof = dispatch.continuation_proof(f.authority.registry, f.authority.registry.dispatch.workers[fid]), operator_verified = true })
		end
		check(attach().code == "settlement_pending", name .. ": the uncertain publication still blocks reattachment")
		local readback = f:apply("readback_publication", { action_id = pub.action_id })
		check(readback.ok and f:action(pub.action_id).phase == "resolved", name .. ": readback settles it on the continued controller route before reattachment: " .. tostring(readback.message))
		local attached = attach(); check(attached.ok, name .. ": reattachment proceeds after the readback: " .. tostring(attached.message))
		assert(f:finish(attached.action_id, "attached", { pane_binding = pane, previous_origin_binding = original.origin_binding, previous_pane_binding = original.pane_binding }).ok)
		local again = f:apply("poll", { worker_id = fid }); assert(again.ok, again.message)
		local repeated = f:action(again.action_id).request
		check(repeated.op == "mailbox_publish_reply" and again.action_id ~= pub.action_id and repeated.object_sha256 == request.object_sha256,
			name .. ": the reattached route re-issues the exact same reply bytes")
		assert(f:finish(again.action_id, "published", {}).ok)
		check(f:action(again.action_id).phase == "complete" and state.rehydrate(clone(f.authority.registry)) ~= nil, name .. ": one settled publication; the state restores")
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
-- Never-launched work whose provision, launch or adoption explicit continuation fenced as unexecuted
-- has an owner withdrawal (cancel_work), gated on SPAWN's retained status when SPAWN received the
-- request. Regression: a retried launch was fenced never_claimed while SPAWN still
-- held its expired window challenge; neither cancel_work nor rebind_unlaunched applied, so the work
-- and its reservations were wedged.
if section == nil or section == "withdraw_fenced" then
	local AUTH_FULL = { resource = "window_authorization", current = 1, limit = 1, retryable = true, effect_started = false }
	local PROVISIONED_W = { handle = "mailbox-withdraw", binding_digest = string.rep("e", 64),
		capabilities = runtime.json.array({ "report-files-v1", "native-ask-v1", "coordinator-control-v1" }), limits = {} }
	local function continue_on_b(fx)
		fx.origin.window_epoch = "replacement-window"; fx.controller_pane = "9010"
		assert(fx:apply("continue_controller", { expected_revision = fx.authority.registry.revision, operator_verified = true }).ok)
	end
	-- The window's exact SPAWN status read of the fenced request and SPAWN's framed answer.
	local function status_evidence(fx, a, status, outcome_status, outcome_payload, overrides)
		local query = { schema = 1, origin = "orchplus", op = "status", request_id = next_id(), action_id = next_id(), origin_binding = clone(a.request.origin_binding),
			controller_pane = fx.controller_pane or "9001", controller_generation = a.request.controller_generation, target_request_id = a.request.request_id }
		for k, v in overrides or {} do query[k] = v end
		local payload = if outcome_status then { outcome = { schema = 1, op = a.request.op, request_id = a.request.request_id, action_id = a.request.action_id,
			origin_binding = clone(a.request.origin_binding), controller_generation = a.request.controller_generation, status = outcome_status, payload = outcome_payload } } else nil
		return { query_bytes = runtime.json.encode(query), response_bytes = frame(query, status, payload) }
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
	-- The live defect: an expired challenge backpressured the launch, the automatic recheck made it
	-- ready again (keeping SPAWN's answer), and continuation fenced it before any new claim.
	local f = fixture(); f:catalog(0)
	local queued = f:queue(false); assert(queued.ok, queued.message)
	assert(f:finish(queued.action_id, "provisioned", PROVISIONED_W).ok)
	local id = queued.worker_id
	local launch_id = worker_of(f, id).launch_action_id
	check(f:finish(launch_id, "full", AUTH_FULL).code == "backpressure", "an expired SPAWN window challenge settles the launch as pre-effect backpressure")
	assert(f:apply("retry", { action_id = launch_id }).ok)
	local before = clone(f:action(launch_id))
	continue_on_b(f)
	local fenced = f:action(launch_id)
	check(fenced.phase == "resolved" and fenced.resolution.evidence == "never_claimed" and fenced.request_bytes == before.request_bytes
		and worker_of(f, id).origin_binding.window_epoch == "fixture-window", "continuation fences the retried old-route launch; it is neither moved nor re-sent")
	local offered = withdrawal(f, id)
	check(offered ~= nil and offered.action_id == launch_id and offered.op == "launch" and offered.status_required == true
		and offered.request_id == fenced.request.request_id and offered.controller_generation == fenced.request.controller_generation,
		"the controller offers withdrawal of the fenced launch, gated on SPAWN's status of that exact request")
	local projection = state.project(f.authority.registry)
	projection.dispatch = dispatch.project(f.authority.registry, f.origin.logical_session_id, f.origin.alias_nonce)
	local rendered = load("views").render({ pane = 42, alias_nonce = f.origin.alias_nonce, orch_session_id = f.origin.logical_session_id,
		action_serial = 0, actions = {} }, projection, "ready")
	local worker_node = assert(role_node(rendered, "orchplus.worker", "workflow-worker-" .. id), "the fenced worker keeps its machine node")
	local worker_span = worker_node.p.spans[1]
	local machine = runtime.json.decode(if type(worker_span) == "string" then worker_span else worker_span.t)
	check(runtime.json.encode(rendered):find("Cancel never-launched work", 1, true) ~= nil and machine.withdrawal.request_id == fenced.request.request_id
		and machine.withdrawal.origin_binding.window_epoch == "fixture-window", "the controller renders the withdrawal control and the exact request the window reads status for")
	check(cancel(f, id).code == "status_required" and worker_of(f, id) ~= nil, "SPAWN received the launch, so withdrawal needs its retained SPAWN status")
	check(cancel(f, id, status_evidence(f, fenced, "found", "pending", { authorization_required = true })).code == "authorization_live" and worker_of(f, id) ~= nil,
		"a still-live SPAWN challenge refuses withdrawal until it expires")
	check(cancel(f, id, status_evidence(f, fenced, "found", "resolved", { prompt_delivery = "not_submitted" })).code == "spawn_outcome_open" and worker_of(f, id) ~= nil,
		"an authorized SPAWN launch awaiting its executor is never withdrawn")
	check(cancel(f, id, status_evidence(f, fenced, "found", "uncertain")).code == "spawn_outcome_open" and worker_of(f, id) ~= nil,
		"an uncertain SPAWN outcome is never withdrawn")
	check(cancel(f, id, status_evidence(f, fenced, "found", "full", AUTH_FULL, { target_request_id = "launch-other" })).code == "binding_mismatch" and worker_of(f, id) ~= nil,
		"the status of another request is not evidence")
	local cancelled = cancel(f, id, status_evidence(f, fenced, "found", "full", AUTH_FULL))
	check(cancelled.ok and cancelled.code == "work_cancelled" and worker_of(f, id) == nil and f:action(launch_id) == nil and f:action(queued.action_id) == nil,
		"SPAWN's expired challenge proves the launch can never run: the work and its settled actions are removed")
	check(state.rehydrate(clone(f.authority.registry)) ~= nil, "the withdrawn state restores")
	local again = f:queue(false)
	check(again.ok and again.worker_id ~= id and worker_of(f, again.worker_id).launch_request_id ~= fenced.request.request_id,
		"the assignment can be queued again; it gets a new launch request ID")
	-- A provision SPAWN refused before effects, fenced at continuation; SPAWN has no record of it.
	local g = fixture(); g:catalog(0)
	local gq = g:queue(false); assert(gq.ok)
	check(g:finish(gq.action_id, "full", { resource = "mailbox_allocation", current = 16, limit = 16, retryable = true, effect_started = false }).code == "backpressure",
		"a full mailbox allocation refuses the provision before effects")
	continue_on_b(g)
	local gprov = g:action(gq.action_id)
	check(gprov.phase == "resolved" and gprov.resolution.evidence == "pre_effect_refusal" and worker_of(g, gq.worker_id).phase == "queued"
		and withdrawal(g, gq.worker_id).op == "mailbox_provision", "continuation fences the refused provision and offers withdrawal")
	check(cancel(g, gq.worker_id, status_evidence(g, gprov, "found", "rejected")).code == "work_cancelled" and worker_of(g, gq.worker_id) == nil,
		"a terminal SPAWN rejection proves the provision can never run")
	local h = fixture(); h:catalog(0)
	local hq = h:queue(false); assert(hq.ok)
	assert(h:finish(hq.action_id, "full", { resource = "mailbox_allocation", current = 16, limit = 16, retryable = true, effect_started = false }).ok)
	continue_on_b(h)
	check(cancel(h, hq.worker_id, status_evidence(h, h:action(hq.action_id), "missing")).code == "work_cancelled" and worker_of(h, hq.worker_id) == nil,
		"no SPAWN record of the fenced provision: the work is withdrawn")
	-- Adoption whose native ask was never claimed: never sent, so no SPAWN read is needed.
	local m = fixture(); m:catalog(0)
	local function hand(fx) return { pane_id = "9020", window_key = fx.origin.window_key, window_epoch = fx.origin.window_epoch,
		native_session_id = fx.origin.native_session_id, window_host_id = fx.origin.window_host_id } end
	local function adopt(fx)
		return fx:apply("adopt", { record_id = "native", record_revision = 0, catalog_revision = 0, prompt = "Adopted fixture task.", pane_binding = hand(fx),
			attestation = "operator_verified_exact_agent_pane" })
	end
	local adopted = adopt(m); assert(adopted.ok, adopted.message)
	assert(m:finish(adopted.action_id, "provisioned", PROVISIONED_W).ok)
	local ask = worker_of(m, adopted.worker_id).launch_action_id
	continue_on_b(m)
	check(m:action(ask).request.op == "adopt" and m:action(ask).phase == "resolved" and m:action(ask).resolution.evidence == "never_claimed"
		and withdrawal(m, adopted.worker_id).status_required == false, "continuation fences the never-claimed adoption ask; SPAWN never received it")
	check(cancel(m, adopted.worker_id).code == "work_cancelled" and worker_of(m, adopted.worker_id) == nil, "the fenced adoption is withdrawn without a SPAWN read")
	check(adopt(m).code == "adoption_queued", "the owner may explicitly adopt the pane again in the continued window")
	-- A fenced coordinator start releases its never-bound orchestrator reservation.
	local c = fixture(); c:catalog(0)
	local cq = c:queue(true); assert(cq.ok, cq.message)
	assert(c:finish(cq.action_id, "provisioned", PROVISIONED_W).ok)
	local cid = cq.worker_id
	local claunch = worker_of(c, cid).launch_action_id
	check(c:finish(claunch, "full", AUTH_FULL).code == "backpressure", "the coordinator launch is refused before effects")
	continue_on_b(c)
	local reserved = coordinator_owner(c)
	check(c:action(claunch).resolution.evidence == "pre_effect_refusal" and reserved.phase == "reserved" and reserved.managed_worker_id == cid,
		"the fenced coordinator start still holds the session's orchestrator reservation")
	check(c:queue(true).code == "orchestrator_slot_occupied", "no second coordinator can start while the fenced one holds the slot")
	check(cancel(c, cid, status_evidence(c, c:action(claunch), "found", "full", AUTH_FULL)).code == "work_cancelled" and worker_of(c, cid) == nil
		and coordinator_owner(c) == nil and c.authority.registry.retired[reserved.owner_id] ~= nil, "withdrawal releases the never-bound coordinator reservation")
	check(c:queue(true).code == "task_queued" and state.rehydrate(clone(c.authority.registry)) ~= nil, "the freed slot accepts an explicit new coordinator start")
	-- A launch claimed on the old window may have run: it stays uncertain and is never withdrawn.
	local u = fixture(); u:catalog(0)
	local uq = u:queue(false); assert(uq.ok)
	assert(u:finish(uq.action_id, "provisioned", PROVISIONED_W).ok)
	local ulaunch = worker_of(u, uq.worker_id).launch_action_id
	assert(u:apply("claim", { action_id = ulaunch, executor = u.origin.window_epoch }).ok)
	continue_on_b(u)
	check(u:action(ulaunch).phase == "uncertain" and withdrawal(u, uq.worker_id) == nil
		and cancel(u, uq.worker_id, status_evidence(u, u:action(ulaunch), "missing")).code == "worker_unbound" and worker_of(u, uq.worker_id) ~= nil,
		"an uncertain claimed launch is never withdrawn, even when SPAWN reports no record")
	-- A launch (or adoption ask) SPAWN definitively rejected after its mailbox was provisioned: the
	-- owner's cancel retires the never-used mailbox through the exact retirement path; the worker stays
	-- visible until SPAWN confirms `retired`, and a refused or uncertain retirement keeps it.
	local OCCUPIED = { code = "binding_mismatch", message = "Occupied SPAWN controller binding; inspect Config and recover the prior owner explicitly" }
	local function reject(fx, action_id, problem)
		if fx:action(action_id).phase == "ready" then assert(fx:apply("claim", { action_id = action_id, executor = fx.origin.window_epoch }).ok) end
		local a = fx:action(action_id)
		return fx:apply("result", { action_id = action_id, executor = a.claim.executor, grant_id = a.claim.grant_id, response_bytes = frame(a.request, "rejected", nil, problem) })
	end
	local function rejected_launch(fx, coordinator)
		local q = fx:queue(coordinator); assert(q.ok, q.message)
		assert(fx:finish(q.action_id, "provisioned", PROVISIONED_W).ok)
		local launch = worker_of(fx, q.worker_id).launch_action_id
		check(reject(fx, launch, OCCUPIED).code == "bridge_rejected", "SPAWN's definite launch rejection commits after provisioning")
		return q.worker_id, launch
	end
	local r = fixture(); r:catalog(0)
	local rid, rlaunch = rejected_launch(r, false)
	local rw = worker_of(r, rid)
	check(rw.phase == "held" and rw.mailbox_handle ~= nil and rw.pane_binding == nil and r:action(rlaunch).phase == "complete", "the work is held with a provisioned, never-used mailbox")
	local roffer = withdrawal(r, rid)
	check(roffer ~= nil and roffer.evidence == "spawn_rejected" and roffer.op == "launch" and roffer.status_required == false and roffer.mailbox_retire == "not_requested",
		"the controller offers withdrawal that will retire the unused mailbox")
	check(cancel(r, rid, status_evidence(r, r:action(rlaunch), "missing")).code == "invalid_command", "a terminal SPAWN rejection takes no status evidence")
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
	local aq = a:apply("adopt", { record_id = "native", record_revision = 0, catalog_revision = 0, prompt = "Adopted fixture task.", pane_binding = apane,
		attestation = "operator_verified_exact_agent_pane" }); assert(aq.ok, aq.message)
	assert(a:finish(aq.action_id, "provisioned", PROVISIONED_W).ok)
	check(reject(a, worker_of(a, aq.worker_id).launch_action_id, { code = "target_unavailable", message = "Target pane is not an idle native agent in the exact window, session and host; nothing was sent" }).code == "bridge_rejected"
		and withdrawal(a, aq.worker_id).op == "adopt" and cancel(a, aq.worker_id).code == "withdrawal_retiring", "a refused adoption ask retires its unused mailbox on cancel")
	-- A coordinator start releases its orchestrator slot once the unused mailbox retires.
	local co = fixture(); co:catalog(0)
	local coid = rejected_launch(co, true)
	local coowner = coordinator_owner(co)
	check(coowner.phase == "reserved" and coowner.managed_worker_id == coid, "the rejected coordinator start still holds the reserved slot")
	local coretire = cancel(co, coid)
	check(coretire.code == "withdrawal_retiring" and coordinator_owner(co) ~= nil, "the slot stays reserved until retirement is confirmed")
	check(co:finish(coretire.action_id, "retired", nil).ok and coordinator_owner(co) == nil and co.authority.registry.retired[coowner.owner_id] ~= nil,
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
			initial_dispatch_provider = false, initial_dispatch_account = false, initial_dispatch_model = false }
		for k, v in extra or {} do p[k] = v end
		return p
	end

	if section == nil or section == "quota_normalize" then
		local evidence = q_normalize(q_document({ q_publication("remote-a", "native") }, { q_source("remote-a") }))
		local entry = q_entry(evidence, "native")
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
			capabilities = runtime.json.array({ "report-files-v1", "native-ask-v1", "coordinator-control-v1" }), unsupported = runtime.json.array(), cwd = "/fixture", placement = "split" }
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
		assert(f:finish(r.action_id, "catalog", { namespace = QJOIN.namespace, host_key = QJOIN.host_key, config_revision = 0, revision = 0, records = runtime.json.array({
			q_row("native", "omp", "Work", "m1"), q_row("alt-same", "omp", "Work", "m1"), q_row("alt-early", "omp", "Work", "m1"),
			q_row("alt-model", "omp", "Work", "m2"), q_row("alt-provider", "other", "Work", "m1") }) }).ok)
		return f
	end
	local function q_queue(f) return f:apply("queue", { record_id = "native", record_revision = 0, catalog_revision = 0, prompt = "Quota fixture task", cwd = "/fixture", placement = "split", coordinator = false }) end
	local function q_worker(f, id) return f.authority.registry.dispatch.workers[id] end
	local function q_actions(f, id) local n = 0; for _, a in f.authority.registry.dispatch.actions do if a.worker_id == id then n += 1 end end; return n end
	local function q_capacity(f, records, revision) return f:apply("capacity", { capacity = q_evidence(records, revision) }) end
	local function q_gate(f, id)
		for _, g in f.authority.registry.dispatch.gates or {} do if g.worker_id == id and g.kind == "quota_fallback" and g.phase == "pending" then return g end end
		return nil
	end
	local PROVISIONED = { handle = "mailbox-fixture", binding_digest = A, capabilities = runtime.json.array({ "report-files-v1", "native-ask-v1", "coordinator-control-v1" }), limits = {} }

	if section == nil or section == "quota_routing" then
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
		check(queued.code == "task_held" and queued.action_id == nil and q_actions(f, queued.worker_id) == 0 and w.routing.phase == "held"
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
		check(expired.code == "task_held" and q_worker(g, expired.worker_id).routing.candidates[1].reason == "evidence_expired", "an expired USAGE lease holds new work")
		-- Owner can withdraw never-provisioned held work; provisioned work cannot be cancelled here.
		check(g:apply("cancel_work", { worker_id = expired.worker_id }).code == "work_cancelled" and q_worker(g, expired.worker_id) == nil, "held unprovisioned work can be cancelled")
		check(f:apply("cancel_work", { worker_id = queued.worker_id }).code == "worker_unbound", "provisioned routed work is not cancellable through cancel_work")
		-- Restore keeps decisions and drops the evidence lease.
		local restored = assert(state.rehydrate(clone(f.authority.registry)))
		check(restored.dispatch.capacity == nil and restored.dispatch.workers[queued.worker_id].routing.phase == "selected", "restore keeps routing decisions and requires fresh evidence")
		check(dispatch.valid(f.authority.registry.dispatch, f.authority.registry), "routed state passes strict validation")
	end

	if section == nil or section == "quota_gate" then
		-- A sufficient alternative whose model change Config does not permit becomes an owner gate.
		local f = q_fixture()
		assert(f:apply("policy", { policy = { quota_routing = true, initial_dispatch_records = { "alt-model" } } }).ok)
		assert(q_capacity(f, { q_known("native", 0), q_known("alt-model", 80) }).ok)
		local queued = q_queue(f)
		local w = q_worker(f, queued.worker_id)
		local gate = q_gate(f, queued.worker_id)
		check(queued.code == "task_gated" and q_actions(f, queued.worker_id) == 0 and w.routing.phase == "gated" and w.routing.gate.denied == "model"
			and gate ~= nil and w.routing.gate.gate_id == gate.id and w.routing.gate.to.id == "alt-model" and w.routing.gate.from.id == "native" and w.routing.gate.evidence_revision == A,
			"a denied model fallback is a durable gate bound to the exact tuples and evidence, with nothing provisioned")
		local listed = false
		for _, item in gate.evidence do if item == "denied:model" then listed = true end end
		check(listed, "the gate records the denied permission as evidence")
		local pending_state = clone(f.authority.registry)
		check(dispatch.valid(pending_state.dispatch, pending_state), "the pending fallback gate state is valid")
		check(f:apply("answer", { gate_id = gate.id, gate_revision = gate.revision, choice_id = "approve", answer = "Approve alt-model" }).code == "fallback_approved", "owner approval is accepted")
		w = q_worker(f, queued.worker_id)
		check(w.record_id == "alt-model" and w.routing.phase == "selected" and w.routing.authority == "owner_gate" and w.routing.needs == "model"
			and f.authority.registry.dispatch.gates[gate.id].phase == "resolved" and q_actions(f, queued.worker_id) == 1
			and f.authority.registry.dispatch.policies[f.origin.logical_session_id].initial_dispatch_model == false,
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
		check(replacement ~= nil and replacement.id ~= gate.id and s.authority.registry.dispatch.gates[gate.id].phase == "superseded", "a routing-policy edit supersedes the old gate")
		check(s:apply("answer", { gate_id = gate.id, gate_revision = gate.revision, choice_id = "approve", answer = "Approve" }).code == "stale_gate", "a superseded fallback cannot be approved")
		assert(s:apply("policy", { policy = { initial_dispatch_model = true } }).ok)
		local w2 = q_worker(s, queued.worker_id)
		check(w2.routing.phase == "selected" and w2.routing.authority == "policy" and w2.record_id == "alt-model" and s.authority.registry.dispatch.gates[replacement.id].phase == "superseded",
			"granting the permission selects the alternative by policy and closes the gate")
		-- Unknown requested identity: any alternative is an account change.
		local u = q_fixture()
		assert(u:apply("policy", { policy = { quota_routing = true, initial_dispatch_records = { "alt-same" } } }).ok)
		assert(q_capacity(u, { q_unknown("native", "binding_unverified"), q_known("alt-same", 90) }).ok)
		queued = q_queue(u)
		check(queued.code == "task_gated" and q_worker(u, queued.worker_id).routing.gate.denied == "account", "equal labels never prove the same account when the selected record is unbound")
		local p = q_fixture()
		assert(p:apply("policy", { policy = { quota_routing = true, initial_dispatch_records = { "alt-provider" }, initial_dispatch_account = true, initial_dispatch_model = true } }).ok)
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
		assert(f:finish(r.action_id, "catalog", { namespace = QJOIN.namespace, host_key = QJOIN.host_key, config_revision = 0, revision = 0, records = runtime.json.array({
			q_row("native", "omp", "Work", "m1"), q_row("alt-same", "omp", "Work", "m1"), q_row("alt-early", "omp", "Work", "m1"),
			q_row("alt-model", "omp", "Work", "m2"), q_row("alt-provider", "other", "Work", "m1") }) }).ok)
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
		-- Permitted: the worker_rollover allowlist and model permission select the alternative.
		local f, id = q_rollover_fixture()
		assert(f:apply("policy", { policy = { quota_routing = true, worker_rollover_records = { "alt-model" }, worker_rollover_model = true } }).ok)
		assert(q_capacity(f, { q_known("native", 0), q_known("alt-model", 80) }).ok)
		hid = q_rollover(f, id)
		local r = rollover_of(f, hid)
		succ = worker_of(f, r.successor_worker_id)
		check(r.phase == "successor_granted" and succ.record_id == "alt-model" and succ.routing.scope == "worker_rollover" and succ.routing.authority == "policy"
			and succ.routing.needs == "model" and succ.routing.requested.id == "native" and succ.routing.reservation.phase == "reserved"
			and worker_of(f, id).record_id == "native" and f:action(actions_of(f, succ.worker_id, "mailbox_provision")[1]).request.record_id == "alt-model",
			"a permitted rollover substitution provisions the successor on the alternative; the running predecessor is unchanged")
		check(dispatch.valid(f.authority.registry.dispatch, f.authority.registry) and state.rehydrate(clone(f.authority.registry)) ~= nil, "routed successor state is valid and restores")
		-- Denied: initial-dispatch permission does not leak into rollover; the gate sits on the predecessor.
		local g, gid = q_rollover_fixture()
		assert(g:apply("policy", { policy = { quota_routing = true, worker_rollover_records = { "alt-model" }, initial_dispatch_model = true } }).ok)
		assert(q_capacity(g, { q_known("native", 0), q_known("alt-model", 80) }).ok)
		hid = q_rollover(g, gid)
		r = rollover_of(g, hid)
		local gate = q_gate_on(g, gid)
		check(r.phase == "checkpoint_verified" and r.hold.code == "quota_fallback_gate" and r.successor_worker_id == nil and gate ~= nil
			and r.quota.gate.gate_id == gate.id and r.quota.gate.denied == "model" and r.quota.gate.scope == "worker_rollover" and r.quota.gate.to.id == "alt-model",
			"a denied rollover substitution is a durable predecessor-bound gate; no successor exists")
		check(dispatch.valid(g.authority.registry.dispatch, g.authority.registry), "the pending rollover fallback gate is valid")
		check(g:apply("answer", { gate_id = gate.id, gate_revision = gate.revision, choice_id = "approve", answer = "Approve" }).code == "fallback_approved", "owner approves this successor's substitution")
		r = rollover_of(g, hid)
		succ = if r.successor_worker_id then worker_of(g, r.successor_worker_id) else nil
		check(r.phase == "successor_granted" and succ ~= nil and succ.record_id == "alt-model" and succ.routing.authority == "owner_gate" and succ.routing.authorized_digest ~= nil
			and r.quota == nil and g.authority.registry.dispatch.gates[gate.id].phase == "resolved" and g.authority.registry.dispatch.policies[g.origin.logical_session_id].worker_rollover_model == false,
			"approval grants only this successor on the destination and never edits Config")
		-- Reject holds the rollover; cancelling it closes the decision.
		local x, xid = q_rollover_fixture()
		assert(x:apply("policy", { policy = { quota_routing = true, worker_rollover_records = { "alt-model" } } }).ok)
		assert(q_capacity(x, { q_known("native", 0), q_known("alt-model", 80) }).ok)
		hid = q_rollover(x, xid)
		gate = q_gate_on(x, xid)
		check(x:apply("answer", { gate_id = gate.id, gate_revision = gate.revision, choice_id = "reject", answer = "Reject" }).code == "fallback_rejected"
			and rollover_of(x, hid).hold.code == "quota_fallback_rejected" and rollover_of(x, hid).successor_worker_id == nil and q_gate_on(x, xid) == nil,
			"rejection holds the rollover without reopening the same question")
		check(x:apply("cancel_rollover", { worker_id = xid }).code == "rollover_cancelled" and rollover_of(x, hid).quota == nil, "cancelling the rollover discards its fallback decision")
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
		check(second.code == "task_held" and q_worker(f, second.worker_id).routing.reason.code == "concurrency_limit" and q_actions(f, second.worker_id) == 0,
			"the configured concurrency limit holds the next routed launch")
		local function validation(revision) return { revision = revision or A, auth_revision = "auth-1", status = "current", validated_at_ms = QNOW, expires_at_ms = QNOW + 60000 } end
		assert(f:finish(first.action_id, "provisioned", PROVISIONED).ok)
		local launch = q_worker(f, first.worker_id).launch_action_id
		assert(f:apply("claim", { action_id = launch, executor = f.origin.window_epoch, capacity_validation = validation() }).ok)
		check(q_worker(f, first.worker_id).routing.reservation.phase == "claimed", "the launch claim moves the reservation to claimed")
		assert(f:finish(launch, "rejected", nil).ok)
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
		check(third.code == "task_held" and q_worker(f, third.worker_id).routing.reason.code == "concurrency_limit", "an uncertain reservation still occupies the slot")
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
		local projection = state.project(f.authority.registry)
		projection.dispatch = dispatch.project(f.authority.registry, f.origin.logical_session_id, f.origin.alias_nonce)
		local rendered = runtime.json.encode(load("views").render({ pane = 42, alias_nonce = f.origin.alias_nonce, orch_session_id = f.origin.logical_session_id,
			action_serial = 0, actions = {} }, projection, "ready"))
		check(rendered:find("Model/profile selector: unverified", 1, true) ~= nil and rendered:find("selector unverified (none recorded)", 1, true) ~= nil,
			"the controller shows the selector as unverified, never enforced")
		assert(f:apply("policy", { policy = { initial_dispatch_model = true } }).ok)
		check(q_worker(f, queued.worker_id).record_id == "alt-model", "selector state is evidence only: it neither blocks nor enables a permitted substitution")
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
		local offered = dispatch.project(f.authority.registry, f.origin.logical_session_id, f.origin.alias_nonce).workers[queued.worker_id].withdrawal
		check(offered ~= nil and offered.evidence == "spawn_rejected" and offered.op == "mailbox_provision" and offered.status_required == false,
			"the controller offers withdrawal on SPAWN's retained rejection, with no further status read")
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
		check(u:action(uq.action_id).phase == "uncertain" and u:apply("cancel_work", { worker_id = uq.worker_id }).code == "worker_unbound"
			and q_worker(u, uq.worker_id) ~= nil, "an uncertain provision is never withdrawn")
		-- So does a claimed one still awaiting SPAWN.
		local c = q_fixture()
		assert(c:apply("policy", { policy = { quota_routing = true } }).ok)
		assert(q_capacity(c, { q_known("native", 60) }).ok)
		local cq = q_queue(c); assert(cq.code == "task_queued", cq.message)
		assert(c:apply("claim", { action_id = cq.action_id, executor = c.origin.window_epoch }).ok)
		check(c:apply("cancel_work", { worker_id = cq.worker_id }).code == "worker_unbound" and q_worker(c, cq.worker_id) ~= nil, "a claimed provision is never withdrawn")
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
		end
		local function on_b(request) return request.origin_binding.window_epoch == "replacement-window" and request.controller_pane == "9010" end
		local function launch_on_b(f, worker_id, name)
			local w = q_worker(f, worker_id)
			local claimed = f:apply("claim", { action_id = w.launch_action_id, executor = f.origin.window_epoch, capacity_validation = validation() })
			check(claimed.ok and f:action(w.launch_action_id).phase == "claimed", name .. ": the continued window claims the launch: " .. tostring(claimed.message))
			check(state.rehydrate(clone(f.authority.registry)) ~= nil, name .. ": the moved worker and its retained provision restore")
			local pane = { pane_id = "9003", window_key = f.origin.window_key, window_epoch = f.origin.window_epoch, native_session_id = f.origin.native_session_id, window_host_id = f.origin.window_host_id }
			local launched = f:finish(w.launch_action_id, "awaiting_acceptance", { pane_binding = pane })
			check(launched.ok and q_worker(f, worker_id).pane_binding.pane_id == "9003" and q_worker(f, worker_id).routing.reservation.phase == "launching",
				name .. ": it launches in the continued window and keeps its reservation: " .. tostring(launched.message))
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
			response_bytes = frame(provision.request, "provisioned", PROVISIONED) })
		check(settled.ok, "the old provision settles through the continued route: " .. tostring(settled.message))
		local w = q_worker(f, queued.worker_id)
		local launch = f:action(w.launch_action_id)
		check(launch.phase == "ready" and launch.claim == nil and on_b(launch.request) and w.origin_binding.window_epoch == "replacement-window"
			and launch.request.request_id == w.launch_request_id and w.routing.reservation.phase == "reserved",
			"the launch released after continuation is bound to the continued route, with its reserved IDs and reservation")
		local stale = f:event("claim", { action_id = w.launch_action_id, executor = old_origin.window_epoch, capacity_validation = validation() })
		stale.origin = clone(old_origin); stale.controller_pane = "9001"
		check(not f.authority:apply(stale).ok and f:action(w.launch_action_id).phase == "ready", "the old window cannot run it")
		launch_on_b(f, queued.worker_id, "late provision")
		-- Never-claimed provision at continuation: rewritten in place on the continued route.
		local h, hq = routed()
		local before = clone(h:action(hq.action_id).request)
		continue_on_b(h)
		local moved = h:action(hq.action_id)
		check(moved.phase == "ready" and moved.resolution == nil and on_b(moved.request) and moved.request.request_id == before.request_id
			and on_b(runtime.json.decode(moved.request_bytes)), "a never-claimed provision moves to the continued route under the same IDs")
		assert(h:finish(hq.action_id, "provisioned", PROVISIONED).ok)
		check(on_b(h:action(q_worker(h, hq.worker_id).launch_action_id).request), "its launch is built on the continued route")
		launch_on_b(h, hq.worker_id, "ready provision")
		-- Never-claimed launch at continuation: rewritten in place on the continued route.
		local k, kq = routed()
		assert(k:finish(kq.action_id, "provisioned", PROVISIONED).ok)
		local kw = q_worker(k, kq.worker_id)
		continue_on_b(k)
		check(k:action(kw.launch_action_id).phase == "ready" and on_b(k:action(kw.launch_action_id).request), "a ready, never-claimed launch moves to the continued route")
		launch_on_b(k, kq.worker_id, "ready launch")
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
return "dispatch" .. (if section then "/" .. section else "") .. ": " .. tostring(checks) .. " checks passed"
