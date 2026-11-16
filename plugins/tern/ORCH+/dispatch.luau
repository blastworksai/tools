--!strict
-- Pure authority/workflow reducer, embedded in state.authority; never a second KV writer.
local codec = require("./wire/codec")
local rules = require("./workflow_rules")
local quota = require("./quota")
local rulings = require("./document_rulings")
local protocol = require("./dispatch_protocol")
local M = {}
local MAX = 9007199254740991
local function clone(v: any): any
	if type(v) ~= "table" or v == tern.json.null then return v end
	local length, count = #v, 0
	local array = length > 0
	for key in v do
		count += 1
		if type(key) ~= "number" or key % 1 ~= 0 or key < 1 or key > length then array = false end
	end
	if count == 0 then array = tern.json.encode(v) == "[]" else array = array and count == length end
	-- Native JSON arrays have protected metatables; preserve shape without table.clone.
	local out = if array then tern.json.array() else {}
	for key, child in v do out[key] = clone(child) end
	return out
end
local function equal(a: any, b: any): boolean
	if rawequal(a, b) then return true end -- Shared subtrees (e.g. a probe's shallow copies) are equal without a walk.
	if type(a) ~= type(b) then return false end
	if type(a) ~= "table" then return a == b end
	for k, v in a do if not equal(v, b[k]) then return false end end
	for k in b do if a[k] == nil then return false end end
	return true
end
local function closed(v: any, keys: string): boolean
	if type(v) ~= "table" or v == tern.json.null then return false end
	local allowed = {}; for k in keys:gmatch("%S+") do allowed[k] = true end
	for k in v do if not allowed[k] then return false end end; return true
end
local function id(v: any): boolean return type(v) == "string" and #v > 0 and #v <= 96 and v:match("^[A-Za-z0-9_-]+$") ~= nil end
local function str(v: any, n: number, empty: boolean?): boolean return type(v) == "string" and (empty or #v > 0) and #v <= n and utf8.len(v) ~= nil and not v:find("%z") end
-- Report text follows the codec's UTF-8 byte contract, not executable-argument rules.
local function wire_text(v: any, n: number): boolean return type(v) == "string" and #v > 0 and #v <= n and utf8.len(v) ~= nil end
local function pos(v: any): boolean return type(v) == "number" and v >= 1 and v <= MAX and v % 1 == 0 end
local function digest(v: any): boolean return type(v) == "string" and #v == 64 and v:match("^[a-f0-9]+$") ~= nil end
local function count(v: any): number local n = 0; for _ in v do n += 1 end; return n end
local function dense(v: any, maximum: number, minimum: number?): boolean
	if type(v) ~= "table" or v == tern.json.null or #v < (minimum or 0) or #v > maximum or count(v) ~= #v then return false end
	for k in v do if not pos(k) or k > #v then return false end end
	return true
end
local function full_payload(v: any): boolean
	return closed(v, "resource current limit retryable effect_started") and id(v.resource)
		and (v.current == 0 or pos(v.current)) and pos(v.limit)
		and ((v.retryable == nil and v.effect_started == nil) or (type(v.retryable) == "boolean" and type(v.effect_started) == "boolean"))
end
local function retryable_full(v: any): boolean
	return full_payload(v) and v.retryable == true and v.effect_started == false
end
local function fail(code: string, message: string): (nil, any) return nil, { ok = false, code = code, message = message } end
local function result(code: string, extra: any?): any
	local r = { ok = true, code = code, message = code }; for k, v in extra or {} do r[k] = clone(v) end; return r
end
function M.origin(v: any): boolean
	return closed(v, "logical_session_id owner_id owner_generation host_pane_id alias_nonce window_key window_epoch native_session_id window_host_id")
		and id(v.logical_session_id) and id(v.owner_id) and pos(v.owner_generation) and str(v.host_pane_id, 256)
		and str(v.alias_nonce, 256) and str(v.window_key, 256, true) and id(v.window_epoch)
		and str(v.native_session_id, 256) and str(v.window_host_id, 256)
end
local function authorized(registry: any, origin: any, pane: any, continuing: boolean?): boolean
	if not M.origin(origin) or not str(pane, 96) or pane:match("^%d+$") == nil then return false end
	local session = registry.sessions[origin.logical_session_id]
	local owner = if session then session.controller else nil
	return owner ~= nil and (owner.phase == "active" or (continuing and owner.phase == "uncertain")) and owner.owner_id == origin.owner_id and owner.generation == origin.owner_generation
		and owner.pane_binding ~= nil and owner.pane_binding.host_pane_id == origin.host_pane_id and owner.pane_binding.alias_nonce == origin.alias_nonce
end
local function fresh(): any return { serial = 0, actions = {}, workers = {}, catalogs = {}, command_cursors = {}, gates = {}, policies = {}, projects = {}, finished_projects = {} } end
local function next_id(d: any, prefix: string): string d.serial += 1; return prefix .. string.format("%.0f", d.serial) end
local READ_ONLY_OPS = protocol.READ_ONLY_OPS
local function control_origin(w: any): any return w.control_origin or w.origin_binding end
local function control_pane(w: any): string return w.control_pane or w.controller_pane end
local function control_binding(w: any): any return w.control_pane_binding or w.pane_binding end
-- Only the canonical grant and committed peer witness cross the native bridge.
local function public_claim(c: any): any
	return if c == nil then nil else { executor = c.executor, epoch = c.epoch, grant_id = c.grant_id, spawn_claim = clone(c.spawn_claim) }
end
M.public_claim = public_claim
local function bounded_observation(event: any): boolean
	return type(event) == "table" and event.kind == "dispatch" and event.command == "observe" and event.observation_seq ~= nil
end
local EFFECT_COMMANDS: any = { claim = true, spawn_claimed = true, result = true, lost = true, observe_allocation = true }
-- The current cursor fences delivery; no completed command or response is retained.
local function remember(d: any, event: any, answer: any, revision: number)
	if event.command_seq then
		d.command_cursors = d.command_cursors or {}
		local prior = d.command_cursors[event.orch_session_id]
		d.command_cursors[event.orch_session_id] = { origin = clone(event.origin), controller_pane = event.controller_pane, seq = event.command_seq,
			continued_epoch = if prior and equal(prior.origin, event.origin) then prior.continued_epoch else nil,
			policy_revision = if answer.code == "policy_updated" then revision else (if prior then prior.policy_revision else nil) }
	end
end
local function execution_origin(d: any, a: any): any
	local cursor = (d.command_cursors or {})[a.request.origin_binding.logical_session_id]
	if cursor and cursor.continued_epoch then return cursor.origin end
	return a.request.origin_binding
end
local function common(d: any, origin: any, pane: string, op: string): any
	return { schema = 2, origin = "orchplus", op = op, request_id = next_id(d, "request-"), action_id = next_id(d, "action-"),
		origin_binding = clone(origin), controller_pane = pane, controller_generation = origin.owner_generation }
end
function M.request_size(request: any): number
	local sized = table.clone(request)
	sized.authority_namespace = string.rep("n", 128); sized.logical_session_id = request.origin_binding.logical_session_id
	sized.admission_seq = MAX; sized.request_serial = MAX - 1; sized.next_request_serial = MAX; sized.settled_before = MAX - 1
	sized.consumed = tern.json.array()
	for i = 1, codec.DISPATCH.consumed do table.insert(sized.consumed, MAX - 34 + i) end
	return #tern.json.encode(sized)
end
local function add(d: any, request: any, worker_id: string?): any
	-- Queued intent is not an issued request. Only claim allocates its immutable serial/bytes.
	if M.request_size(request) > codec.DISPATCH.limit then return nil end
	local action = { request = request, phase = "ready", worker_id = worker_id }
	d.actions[request.action_id] = action; return action
end
-- Reconstructed delivery acknowledgement: only current issued identities, never a completed set.
function M.ack_progress(registry: any, sid: string): (number, any)
	local session = registry.sessions[sid]
	local floor, live = session.next_request_serial, {}
	for _, action in (registry.dispatch or fresh()).actions do
		local r = action.request
		if r.origin_binding.logical_session_id == sid and r.request_serial ~= nil then
			live[r.request_serial] = true
			floor = math.min(floor, r.request_serial)
		end
	end
	local consumed = tern.json.array()
	for _, peer in (session.peer_outstanding or {}).entries or {} do
		if peer.request_serial < session.next_request_serial and not live[peer.request_serial] then
			table.insert(consumed, peer.request_serial)
		end
	end
	for _, action in (registry.dispatch or fresh()).actions do
		local serial = action.retry_after_serial
		if action.request.origin_binding.logical_session_id == sid and serial and serial >= floor and not table.find(consumed, serial) then
			table.insert(consumed, serial)
		end
	end
	table.sort(consumed)
	while #consumed > codec.DISPATCH.consumed do table.remove(consumed) end
	return floor, consumed
end

local function issue_action(n: any, action: any): any?
	local sid = action.request.origin_binding.logical_session_id
	local session = n.sessions[sid]
	if not session or session.phase ~= "open" or session.admitted ~= true or not pos(session.admission_seq)
		or not codec.dispatch_compatibility_ready(n.compatibility) then
		return { ok = false, code = "admission_required", message = "Explicit current paired admission is required before issuing work." }
	end
	if action.retry_after_serial then return { ok = false, code = "peer_reconcile_required",
		message = "Reconcile the peer to acknowledge the prior pre-effect result before issuing this worker-bound retry." } end
	if action.request_bytes ~= nil or action.request.request_serial ~= nil then
		return { ok = false, code = "immutable_request", message = "An issued request cannot be re-issued or assigned another admission." }
	end
	if session.next_request_serial == MAX then return { ok = false, code = "full", message = "Issued serial is exhausted." } end
	local floor, consumed = M.ack_progress(n, sid)
	local r = action.request
	r.authority_namespace = n.authority_namespace; r.logical_session_id = sid
	r.admission_seq = session.admission_seq; r.request_serial = session.next_request_serial
	session.next_request_serial += 1
	r.next_request_serial = session.next_request_serial; r.settled_before = floor; r.consumed = consumed
	local bytes = tern.json.encode(r)
	local _, problem = codec.decode_dispatch_request(bytes)
	if problem then return problem end
	action.request_bytes = bytes
	return nil
end

function M.action_proof(registry: any, action: any): any?
	local r, claim = action.request, action.claim
	if not r.request_serial or not action.request_bytes or not claim then return nil end
	local route = execution_origin(registry.dispatch, action)
	local cursor = (registry.dispatch.command_cursors or {})[r.logical_session_id]
	return { authority_namespace = registry.authority_namespace, authority_revision = registry.revision,
		logical_session_id = r.logical_session_id, admission_seq = r.admission_seq, request_serial = r.request_serial,
		action_id = r.action_id, request_sha256 = codec.sha256(action.request_bytes), phase = action.phase,
		execution_origin = clone(route), execution_controller_pane = if cursor and cursor.continued_epoch and equal(cursor.origin, route) then cursor.controller_pane else r.controller_pane,
		claim = public_claim(claim), reconciliation_only = action.phase ~= "claimed" or claim.epoch ~= registry.execution_epoch
			or not equal(route, r.origin_binding) or registry.sessions[r.logical_session_id].admitted ~= true }
end
local B = { "logical_session_id", "worker_id", "worker_generation", "launch_request_id", "work_id" }
local function be(w: any, request: any)
	for _, k in B do request[k] = w[k] end; request.enrolment_token = w.enrolment_token
end
-- A rollover successor's mailbox is provisioned with its handover ID and this pair digest (never
-- the token), so SPAWN's producer refuses a mistyped pair before publishing ACCEPTED.
local function handover_sha256(w: any): string?
	return if w.handover_id then codec.sha256(w.handover_id .. ":" .. w.handover_token) else nil
end
local function report_binding(w: any): any
	local out = {}; be(w, out)
	out.mailbox_handle = w.mailbox_handle; out.assignment_sha256 = w.assignment_sha256; out.capabilities = clone(w.capabilities)
	-- Rollover successors' ACCEPTED must match the issued handover pair; initial launches carry none.
	out.handover_id = w.handover_id; out.handover_token = w.handover_token
	return out
end
local function worker_request(d: any, w: any, op: string): any
	local r = common(d, control_origin(w), control_pane(w), op); be(w, r)
	r.handle = w.mailbox_handle; r.expected_generation = w.worker_generation; return r
end
local ADOPT_ATTESTATION = "operator_verified_exact_agent_pane"
local function launch_request(w: any, handle: string): any
	if w.enrol_delivery then
		return { schema = 2, origin = "orchplus", op = "enrol", request_id = w.launch_request_id, action_id = w.launch_action_id,
			origin_binding = clone(w.origin_binding), controller_pane = w.controller_pane, controller_generation = w.origin_binding.owner_generation,
			record_id = w.record_id, record_revision = w.record_revision, work_id = w.work_id, prompt = w.prompt, mailbox_handle = handle,
			enrolment = { worker_id = w.worker_id, worker_generation = w.worker_generation, enrolment_token = w.enrolment_token, assignment_sha256 = w.assignment_sha256 },
			pane_binding = clone(w.adopt_pane_binding), delivery = w.enrol_delivery, preserve_context = true }
	end
	-- Explicit verified attach of a hand-opened native agent: same enrolment, delivered by SPAWN
	-- native ask to the exact attested pane instead of a fresh launch.
	if w.adopt_pane_binding then
		return { schema = 2, origin = "orchplus", op = "adopt", request_id = w.launch_request_id, action_id = w.launch_action_id,
			origin_binding = clone(w.origin_binding), controller_pane = w.controller_pane, controller_generation = w.origin_binding.owner_generation,
			record_id = w.record_id, record_revision = w.record_revision, work_id = w.work_id, prompt = w.prompt, mailbox_handle = handle,
			enrolment = { worker_id = w.worker_id, worker_generation = w.worker_generation, enrolment_token = w.enrolment_token, assignment_sha256 = w.assignment_sha256 },
			pane_binding = clone(w.adopt_pane_binding), attestation = ADOPT_ATTESTATION }
	end
	return { schema = 2, origin = "orchplus", op = "launch", request_id = w.launch_request_id, action_id = w.launch_action_id,
		origin_binding = clone(w.origin_binding), controller_pane = w.controller_pane, controller_generation = w.origin_binding.owner_generation,
		record_id = w.record_id, record_revision = w.record_revision, work_id = w.work_id, prompt = w.prompt,
		cwd = w.execution_cwd or w.cwd, placement = if w.presentation == "user_new_tab" or w.presentation == "coordinator_adjacent"
			or (w.presentation == "background" and w.handover_id ~= nil and w.placement == "replace_if_alone"
				and w.selected_record and w.selected_record.backend ~= "native-agent") then "tab" else w.placement,
		presentation = w.presentation, execution_cwd = w.execution_cwd,
		fresh = true, mailbox_handle = handle, enrolment = { worker_id = w.worker_id, worker_generation = w.worker_generation,
			enrolment_token = w.enrolment_token, assignment_sha256 = w.assignment_sha256,
			-- Rollover successors only: the immutable host-issued handover pair (absent on initial dispatch).
			handover_id = w.handover_id, handover_token = w.handover_token,
			coordinator_owner_id = if w.coordinator_protocol == 1 then w.coordinator_owner_id else nil,
			coordinator_generation = if w.coordinator_protocol == 1 then w.coordinator_generation else nil } }
end
-- `retained_reads`: an uncertain read-only action is retained evidence, not a pending effect
-- (explicit attachment supersedes it on the attached route; see resolve_read).
local function pending(d: any, w: any, watermark: boolean?, retained_reads: boolean?): boolean
	for _, a in d.actions do
		if a.worker_id == w.worker_id and (a.phase == "ready" or a.phase == "held_ready" or a.phase == "claimed" or (a.phase == "backpressure" and not watermark)
			or (a.phase == "uncertain" and not (retained_reads and READ_ONLY_OPS[a.request.op]))) then return true end
	end
	return false
end
function M.unresolved(registry: any, session_id: string, owner_id: string): boolean
	for _, a in (registry.dispatch or fresh()).actions do
		local w = if a.worker_id then registry.dispatch.workers[a.worker_id] else nil
		if a.request.origin_binding.logical_session_id == session_id and (a.request.origin_binding.owner_id == owner_id or (w and w.coordinator_owner_id == owner_id))
			and (a.phase == "claimed" or a.phase == "uncertain") and not a.executor_stopped then return true end
	end
	return false
end
function M.coordinator_blocker(registry: any, sid: string, clock: any): string?
	local session, d = registry.sessions[sid], registry.dispatch
	if not d then return nil end
	for _, worker in d.workers do
		if worker.logical_session_id ~= sid or not worker.coordinator_owner_id or worker.mailbox_retired or worker.stopped
			or (session.orchestrator and session.orchestrator.owner_id == worker.coordinator_owner_id) then continue end
		local observed = if worker.workflow then worker.workflow.native else nil
		local exited = observed and observed.state == "exited" and observed.delivery_error == nil
			and type(clock) == "table" and clock.epoch ~= nil and observed.epoch == clock.epoch
		if (worker.pane_binding or worker.accepted_event) and not exited then return "A previous coordinator pane remains unproved; observe its exact stop before starting another coordinator." end
		for _, action in d.actions do
			if action.worker_id == worker.worker_id and action.request_bytes and (action.request.op == "launch" or action.request.op == "adopt")
				and action.phase ~= "backpressure" then return "A previous coordinator launch remains unknown; stopping its executor does not prove the launch never happened." end
		end
	end
	return nil
end
local function pane_binding(v: any, origin: any): boolean
	return closed(v, "pane_id window_epoch window_key native_session_id window_host_id") and str(v.pane_id, 96) and v.pane_id:match("^%d+$") ~= nil
		and v.window_epoch == origin.window_epoch and v.window_key == origin.window_key and v.native_session_id == origin.native_session_id and v.window_host_id == origin.window_host_id
end
local function catalog(v: any, legacy_cache: boolean?): boolean
	if not closed(v, "catalog_version setup revision records next_cursor namespace host_key config_revision")
		or not (v.revision == 0 or pos(v.revision)) or type(v.records) ~= "table" or #v.records > 256 then return false end
	local legacy = legacy_cache == true and v.catalog_version == nil and v.setup == nil
	if not legacy then
		local setup = v.setup
		if v.catalog_version ~= 2 or not closed(setup, "schema state config_revision readiness") or setup.schema ~= 1
			or not table.find({ "not_started", "in_progress", "completed", "dismissed", "adopted_existing" }, setup.state)
			or setup.config_revision ~= v.config_revision then return false end
		local readiness = setup.readiness
		if not closed(readiness, "state config_revision summary")
			or not table.find({ "not_run", "passed", "failed", "unavailable" }, readiness.state)
			or not (readiness.config_revision == 0 or pos(readiness.config_revision))
			or not str(readiness.summary, 1024, true) then return false end
	end
	if not (legacy and v.namespace == nil and v.host_key == nil and v.config_revision == nil)
		and (not str(v.namespace, 256) or not str(v.host_key, 256) or v.config_revision ~= v.revision) then return false end
	if v.next_cursor ~= nil and (not closed(v.next_cursor, "revision index") or v.next_cursor.revision ~= v.revision or not pos(v.next_cursor.index)) then return false end
	for _, r in v.records do
		if not closed(r, "id revision provider provider_family account_label backend enabled eligible capabilities unsupported model_variant profile_variant selector_evidence capacity_binding cwd placement capability_evidence effective_identity")
			or not str(r.id, 96) or not (r.revision == 0 or pos(r.revision)) or type(r.eligible) ~= "boolean" or type(r.capabilities) ~= "table" or type(r.unsupported) ~= "table"
			or (r.provider_family ~= nil and (not str(r.provider_family, 96) or r.provider_family:find("%c") ~= nil or r.provider_family:find("%S") == nil or r.provider_family ~= r.provider_family:lower())) then return false end
	end
	return true
end
local request_fields = {
	catalog = "cursor",
	declare_provider_families = "record_revision declarations",
	launch = "record_id record_revision work_id prompt cwd placement fresh mailbox_handle enrolment presentation execution_cwd",
	adopt = "record_id record_revision work_id prompt mailbox_handle enrolment pane_binding attestation",
	enrol = "record_id record_revision work_id prompt mailbox_handle enrolment pane_binding delivery preserve_context",
	stop = "target_request_id target_action_id pane_binding worker_id worker_generation enrolment_token work_id",
	accept = "target_request_id target_action_id pane_binding worker_id worker_generation enrolment_token work_id event_id seq event_sha256 handover_id handover_token",
	attach_worker = "target_request_id target_action_id previous_origin_binding previous_pane_binding pane_binding worker_id worker_generation enrolment_token work_id attestation",
	native_wake = "target_request_id target_action_id",
	mailbox_provision = "logical_session_id worker_id worker_generation launch_request_id work_id enrolment_token record_id record_revision capability handover_id handover_sha256 manifest",
	mailbox_read = "logical_session_id worker_id worker_generation launch_request_id work_id enrolment_token handle expected_generation selector",
	mailbox_publish_ack = "logical_session_id worker_id worker_generation launch_request_id work_id enrolment_token handle expected_generation receipt_revision ack_b64 ack_sha256",
	mailbox_publish_reply = "logical_session_id worker_id worker_generation launch_request_id work_id enrolment_token handle expected_generation message_id reply_seq action_revision reply_sha256 part index object_b64 object_sha256",
	mailbox_retire = "logical_session_id worker_id worker_generation launch_request_id work_id enrolment_token handle expected_generation mode settlement_revision report_floor report_chain_sha256 reply_floor grant_id withdrawn_starts",
}
-- Held, never-launched work whose launch or adoption ask SPAWN definitively rejected after its
-- mailbox was provisioned. SPAWN stores a launch/adopt rejection only before any native call (an
-- adoption `refused` result is reported before the ask), so no pane exists and no producer ever
-- ran: its mailbox retires without a native stop when the owner cancels the work (cancel_work).
local config: any = require("./policy_validation")
local function launch_rejected(d: any, w: any, legacy: boolean?): boolean
	local action = if legacy then d.actions[w.launch_action_id] else nil
	local refused = w.launch_refused == true or (legacy and action and action.phase == "complete" and action.response and action.response.status == "rejected")
	return w.phase == "held" and w.mailbox_handle ~= nil and w.pane_binding == nil and w.control_origin == nil and w.accepted_event == nil
		and w.stopped == nil and refused == true
		and (w.handover_id == nil or config.refused_handover_clear(d, w))
end
local function valid_request(r: any, w: any, d: any, legacy: boolean?): boolean
	local extra = request_fields[r.op]
	if extra == nil or not closed(r, "schema origin op request_id action_id origin_binding controller_pane controller_generation "
		.. (if legacy then "" else "authority_namespace logical_session_id admission_seq request_serial next_request_serial settled_before consumed ") .. extra)
		or r.schema ~= (if legacy then 1 else 2) or r.origin ~= "orchplus" or not id(r.request_id) or not id(r.action_id)
		or not str(r.controller_pane, 96) or r.controller_pane:match("^%d+$") == nil or r.controller_generation ~= r.origin_binding.owner_generation then return false end
	if r.op == "catalog" then return w == nil end
	if r.op == "declare_provider_families" then
		if w ~= nil or not (r.record_revision == 0 or pos(r.record_revision)) or not dense(r.declarations, 32, 1) then return false end
		local seen = {}
		for _, value in r.declarations do
			if not closed(value, "record_id provider_family") or not str(value.record_id, 96) or seen[value.record_id]
				or not str(value.provider_family, 96) or value.provider_family:find("%c") ~= nil or value.provider_family:find("%S") == nil
				or value.provider_family ~= value.provider_family:lower() then return false end
			seen[value.record_id] = true
		end
		return true
	end
	if type(w) ~= "table" or r.origin_binding.logical_session_id ~= w.logical_session_id then return false end
	if legacy and (r.origin_binding.owner_id ~= w.origin_binding.owner_id or r.origin_binding.owner_generation ~= w.origin_binding.owner_generation
		or r.origin_binding.host_pane_id ~= w.origin_binding.host_pane_id or r.origin_binding.alias_nonce ~= w.origin_binding.alias_nonce) then return false end
	-- attach_worker, stop and accept target this exact launch and generation from a pane on the route.
	local same_target = r.target_request_id == w.launch_request_id and r.target_action_id == w.launch_action_id
		and pane_binding(r.pane_binding, r.origin_binding) and r.worker_id == w.worker_id and r.worker_generation == w.worker_generation
		and r.enrolment_token == w.enrolment_token and r.work_id == w.work_id
	if r.op == "attach_worker" then
		return same_target and equal(r.previous_origin_binding, if legacy then w.origin_binding else control_origin(w))
			and equal(r.previous_pane_binding, if legacy then w.pane_binding else control_binding(w))
			and (r.attestation == "old_executors_stopped_or_retired" or r.attestation == "same_native_conversation_no_pending_effects" or r.attestation == "same_terminal_process_no_pending_effects")
	end
	local route_known = (equal(r.origin_binding, w.origin_binding) and r.controller_pane == w.controller_pane)
		or (w.control_origin ~= nil and equal(r.origin_binding, w.control_origin) and r.controller_pane == w.control_pane)
	if legacy and not route_known then
		for _, attachment in d.actions do
			local request, response = attachment.request, attachment.response
			if type(request) == "table" and request.op == "attach_worker" and attachment.worker_id == w.worker_id
				and attachment.phase == "complete" and type(response) == "table" and response.status == "attached"
				and equal(request.origin_binding, r.origin_binding) and request.controller_pane == r.controller_pane
				and closed(response.payload, "pane_binding previous_origin_binding previous_pane_binding")
				and equal(response.payload.pane_binding, request.pane_binding) and equal(response.payload.previous_origin_binding, w.origin_binding)
				and equal(response.payload.previous_pane_binding, w.pane_binding) then route_known = true; break end
		end
		if not route_known and r.op == "mailbox_provision" then local a = d.actions[r.action_id]; route_known = a ~= nil and a.phase ~= "ready" end
	end
	-- A withdrawn rejected launch, or withdrawn fenced work (w.withdrawn, which keeps its old route),
	-- retires its unused mailbox on the route the owner cancelled from (earlier refused or revoked
	-- attempts keep their own exact route).
	if not route_known and r.op == "mailbox_retire" and r.mode == "retire" and (w.stopped or launch_rejected(d, w, legacy) or w.withdrawn ~= nil or w.enrol_cancelling or w.startup_cancelling) then
		local cursor = (d.command_cursors or {})[w.logical_session_id]
		route_known = legacy == true or (cursor ~= nil and equal(r.origin_binding, cursor.origin) and r.controller_pane == cursor.controller_pane)
	end
	if not route_known then return false end
	if r.op == "native_wake" then
		if legacy then
			local target = d.actions[r.target_action_id]
			return id(r.target_request_id) and type(target) == "table" and type(target.request) == "table" and target.worker_id == w.worker_id
				and target.request.request_id == r.target_request_id and (target.request.op == "mailbox_publish_ack"
					or (target.request.op == "mailbox_publish_reply" and target.request.part == "manifest"))
		end
		local target = (w.wakes or {})[r.target_action_id]
		return target ~= nil and target.target_request_id == r.target_request_id
	end
	if r.op == "launch" or r.op == "adopt" or r.op == "enrol" then
		local expected = launch_request(w, w.mailbox_handle)
		if legacy then expected.schema = 1; return equal(r, expected) end
		for key, value in expected do if not equal(r[key], value) then return false end end
		return true
	end
	if r.op == "stop" then return same_target and (w.release ~= nil or w.finish ~= nil or (w.start_retirement ~= nil and config.valid_start_retirement(w))) end
	if r.op == "accept" then
		return same_target and w.accepted_event ~= nil
			and r.event_id == w.accepted_event.event_id and r.seq == w.accepted_event.seq and r.event_sha256 == w.accepted_event.event_sha256
			and r.handover_id == w.handover_id and r.handover_token == w.handover_token
	end
	for _, k in B do if r[k] ~= w[k] then return false end end
	if r.enrolment_token ~= w.enrolment_token then return false end
	if r.op == "mailbox_provision" then
		-- Provisions retained from builds before the handover digest carry neither field; the optional
		-- assignment manifest (Contract G) is exactly the bytes whose digest the worker stores.
		return r.record_id == w.record_id and r.record_revision == w.record_revision and r.capability == "report-files-v1"
			and (r.handover_id == nil and r.handover_sha256 == nil or r.handover_id == w.handover_id and r.handover_sha256 == handover_sha256(w))
			and (if r.manifest == nil then w.manifest_sha256 == nil else type(r.manifest) == "string" and codec.sha256(r.manifest) == w.manifest_sha256)
	end
	if r.handle ~= w.mailbox_handle or r.expected_generation ~= w.worker_generation then return false end
	if r.withdrawn_starts ~= nil then
		if r.op ~= "mailbox_retire" or r.mode ~= "retire" or not w.start_retirement or not config.valid_start_retirement(w)
			or not equal(r.withdrawn_starts, config.start_retirement_tail(d, w)) then return false end
	end
	if r.op == "mailbox_publish_ack" then
		if type(r.ack_b64) ~= "string" then return false end
		local ok, bytes = pcall(tern.base64.decode, r.ack_b64)
		if not ok or tern.base64.encode(bytes) ~= r.ack_b64 or codec.sha256(bytes) ~= r.ack_sha256 then return false end
		local ack = codec.strict_decode(bytes, 2048)
		if not ack then return false end
		local expected = report_binding(w); expected.event_id = ack.event_id; expected.seq = ack.seq; expected.event_sha256 = ack.event_sha256
		return codec.decode_ack(bytes, expected) ~= nil and ack.committed_revision == r.receipt_revision
	end
	return true
end
-- Reusable settings contain no live identity, repository target or one-off grant.
local DEFAULT_POLICY = config.defaults
-- Config key sets, value-shape validators and Contract A worker-field rules share one table: the
-- module's top-level locals sit at Luau's 200-local limit.
config.migration = require("./dispatch_migration")
-- The problem table `fail` returns, for callers that answer (problem) instead of (nil, problem).
function config.refusal(code: string, message: string): any return { ok = false, code = code, message = message } end
function config.consume_action(d: any, a: any)
	local w, r = if a.worker_id then d.workers[a.worker_id] else nil, a.request
	-- Family declaration outcomes remain until a matching fresh catalog settles every exact
	-- declaration. This reuses the durable action ledger; result acceptance alone is not catalog proof.
	if r.op == "declare_provider_families" and a.family_migration_confirmed ~= true then return end
	if w then
		if w.stop_action_id == r.action_id then w.stop_action_id = nil end
		if w.mailbox_retire_action_id == r.action_id then w.mailbox_retire_action_id = nil end
		for _, wake in w.wakes or {} do if wake.action_id == r.action_id then wake.action_id = nil end end
	end
	d.actions[r.action_id] = nil
end
-- Keys of `map` whose entry `keep` selects, sorted (by `less` when given) for deterministic iteration.
function config.sorted_keys(map: any, keep: (any, any) -> any, less: any?): { any }
	local keys = {}
	for key, value in map do if keep(key, value) then table.insert(keys, key) end end
	table.sort(keys, less)
	return keys
end
-- Releases the worker's stop, retirement and wake lane markers that `held` names, so the same
-- obligation is re-issued on the current route.
function config.release_lanes(w: any, held: (any) -> boolean)
	if held(w.stop_action_id) then w.stop_action_id = nil end
	if held(w.mailbox_retire_action_id) then w.mailbox_retire_action_id = nil end
	for _, wake in w.wakes or {} do if held(wake.action_id) then wake.action_id = nil end end
end
function config.discard_actions(d: any, drop: (string, any) -> boolean)
	for key, a in d.actions do if drop(key, a) then d.actions[key] = nil end end
end
-- One executor settled: the controller and, for a coordinator's work, its orchestrator owner run one fewer.
function config.release_executor(session: any, w: any?, a: any)
	if not a.claim or a.executor_stopped or a.executor_released then return end
	if session.controller and session.controller.owner_id == a.request.origin_binding.owner_id then
		session.controller.pending_executors = math.max(0, session.controller.pending_executors - 1)
	end
	local owner = session.orchestrator
	if w and owner and owner.owner_id == w.coordinator_owner_id then owner.pending_executors = math.max(0, owner.pending_executors - 1) end
	a.executor_released = true
end
-- Records the owner's answer to a pending gate: one of its offered options and a bounded answer text.
function config.take_answer(g: any, event: any, at_ms: number): boolean
	local offered = false
	for _, option in g.options do if option.id == event.choice_id then offered = true end end
	if g.phase ~= "pending" or not offered or not str(event.answer, 32768) then return false end
	g.answer = { choice_id = event.choice_id, answer = event.answer, source = config.owner_source(event.origin), at_ms = at_ms }
	return true
end
config.keys.cp2 = "paused poll_ms heartbeat_ms stale_ms automatic_reports"
config.keys.cp3 = config.keys.cp2 .. " auto_rollover rollover_threshold_pct rollover_include_coordinator quota_routing excluded_workers"
config.keys.quota = "poll_ms heartbeat_ms stale_ms automatic_reports auto_rollover rollover_threshold_pct rollover_include_coordinator quota_routing excluded_workers quota_reserve_pct quota_max_age_ms initial_dispatch_records initial_dispatch_provider initial_dispatch_account initial_dispatch_model"
config.keys.sweep = config.keys.quota .. " sweep_enabled sweep_time"
config.keys.v3 = config.keys.sweep .. " worker_rollover_records worker_rollover_provider worker_rollover_account worker_rollover_model coordinator_rollover_records coordinator_rollover_provider coordinator_rollover_account coordinator_rollover_model concurrency_limit"
config.keys.old_editable = config.keys.v3 .. " loop_cap review_rounds stale_claim_min require_code_review require_other_family family_map reviewer_records release_manager_record checkout_roots auto_approve_kinds glitch_integration default_work_source board_path board_lanes inbox_folder auto_start_projects routes labeller_record role_guidance templates"
-- Previous current shape (before glitch_project_discovery and default_work_source were retired): a HISTORICAL read shape only, migrated away on restore.
config.keys.previous_editable = "poll_ms report_request_ms stale_ms automatic_reports auto_rollover rollover_threshold_pct rollover_include_coordinator quota_routing excluded_workers quota_reserve_pct quota_max_age_ms initial_dispatch_enabled initial_dispatch_records initial_dispatch_provider initial_dispatch_account sweep_enabled sweep_time worker_rollover_enabled worker_rollover_records worker_rollover_provider worker_rollover_account coordinator_rollover_enabled coordinator_rollover_records coordinator_rollover_provider coordinator_rollover_account concurrency_limit loop_cap review_rounds stale_claim_min require_code_review require_other_family reviewer_records merge_actor_mode release_manager_record preferred_worker_record preferred_orchestrator_record checkout_roots track_checkout_roots auto_approve_kinds merge_coordination glitch_integration glitch_project_discovery work_on_enabled default_work_source board_path board_lanes inbox_folder auto_start_projects templates"
config.keys.editable = "poll_ms report_request_ms stale_ms automatic_reports auto_rollover rollover_threshold_pct rollover_include_coordinator quota_routing excluded_workers quota_reserve_pct quota_max_age_ms initial_dispatch_enabled initial_dispatch_records initial_dispatch_provider initial_dispatch_account sweep_enabled sweep_time worker_rollover_enabled worker_rollover_records worker_rollover_provider worker_rollover_account coordinator_rollover_enabled coordinator_rollover_records coordinator_rollover_provider coordinator_rollover_account concurrency_limit loop_cap review_rounds stale_claim_min require_code_review require_other_family reviewer_records merge_actor_mode release_manager_record preferred_worker_record preferred_orchestrator_record checkout_roots track_checkout_roots auto_approve_kinds merge_coordination glitch_integration work_on_enabled board_path board_lanes inbox_folder auto_start_projects templates"
local REPORT_KINDS = { "REGISTER", "ACCEPTED", "reply_ack", "COORDINATOR_RELEASE", "PROJECT_START_CLAIM", "READY", "HEARTBEAT", "WAITING", "BLOCKED", "ASK",
	"CHECKPOINT", "REVIEW_READY", "REVIEW_RESULT", "DONE", "ROLLOVER_REQUEST", "LANDING_REQUEST", "LANDING_RESULT", "COORDINATOR_PROPOSAL",
	"CHECK_RESULT", "CHECKOUT", "LABEL", "DEPLOY_RESULT" }
config.ROLES = { "builder", "reviewer", "release_manager", "labeller", "coordinator" }
M.POLICY_BYTES = protocol.POLICY_BYTES
M.NATIVE_COMMAND_BYTES = protocol.NATIVE_COMMAND_BYTES
local function policy(d: any, session: string): any return (d.policies or {})[session] or DEFAULT_POLICY end
local function migrate_policy(p: any): any
	local out = clone(DEFAULT_POLICY)
	for k, v in p do if DEFAULT_POLICY[k] ~= nil then out[k] = clone(v) end end
	if p.report_request_ms == nil and p.heartbeat_ms ~= nil then out.report_request_ms = p.heartbeat_ms end
	if p.preferred_worker_record == nil then
		for _, route in (if type(p.routes) == "table" then p.routes else {}) do if type(route) == "table" and route.class == "build" then out.preferred_worker_record = route.record_id; break end end
	end
	if p.merge_actor_mode == nil and p.release_manager_record ~= nil and p.release_manager_record ~= "" then out.merge_actor_mode = "selected_record" end
	for _, scope in quota.SCOPES do
		if p[scope .. "_enabled"] == nil and p[scope .. "_records"] ~= nil then out[scope .. "_enabled"] = #p[scope .. "_records"] > 0 end
	end
	if type(out.sweep_time) == "string" and #out.sweep_time == 5 then out.sweep_time ..= ":00" end
	if type(out.templates) == "table" then for _, t in out.templates do if type(t) == "table" then t.custom_fields = t.custom_fields or {} end end end
	if p.enforce_cross_family ~= nil then
		out.require_code_review = true; out.require_other_family = p.enforce_cross_family
	end
	return out
end
-- Tagged gate-answer sources: policy answers exist only on coordinator proposals (rule = the
-- proposal's kind) and landing approvals; ORCH+'s own refusals only as a coordinator proposal's
-- `reject`; untagged pre-0.4.0 owner sources pass only at restore.
function config.owner_source(origin: any): any
	local out = clone(origin); out.kind = "owner"; return out
end
function config.policy_source(d: any, sid: string, kind: string): any
	return { kind = "policy", policy_revision = quota.digest(policy(d, sid)), rule = "auto_approve:" .. kind }
end
function config.valid_source(src: any, g: any, w: any, legacy: boolean?): boolean
	if type(src) ~= "table" or src == tern.json.null then return false end
	if src.kind == "policy" then
		local rule = if type(src.rule) == "string" then src.rule:match("^auto_approve:(%a+)$") else nil
		if not closed(src, "kind policy_revision rule") or not digest(src.policy_revision) or not rule or not table.find(config.APPROVABLE, rule) then return false end
		if g.kind == "landing_approval" then return rule == "landing" end
		local proposal = if g.kind == "coordinator_proposal" and g.proposal then codec.decode_report(g.proposal, w) else nil
		return proposal ~= nil and proposal.payload.kind == rule
	end
	if src.kind == "refusal" then
		return closed(src, "kind code") and config.REFUSALS[src.code] ~= nil and g.kind == "coordinator_proposal" and g.answer ~= nil and g.answer.choice_id == "reject"
	end
	local origin = src
	if src.kind == "owner" then origin = table.clone(src); origin.kind = nil
	elseif src.kind ~= nil or not legacy then return false end
	return M.origin(origin) and origin.logical_session_id == w.logical_session_id
		and origin.owner_id == w.origin_binding.owner_id and origin.owner_generation == w.origin_binding.owner_generation
end
function config.exact(value: any, keys: string): boolean
	if not closed(value, keys) then return false end
	for key in keys:gmatch("%S+") do if value[key] == nil then return false end end
	return true
end
function M.upgradable_policy(value: any): boolean
	local old = "paused " .. config.keys.old_editable
	return config.exact(value, old) or config.exact(value, (old:gsub("require_code_review require_other_family", "enforce_cross_family")))
		or config.exact(value, ((old:gsub("auto_start_projects", "")):gsub("require_code_review require_other_family", "enforce_cross_family")))
		or config.exact(value, "paused " .. config.keys.previous_editable .. " role_guidance")
end
-- The previous current exact shape (both retired settings present, no role_guidance). Historical read shape only: accepted at restore, never a save payload.
-- Kept apart from upgradable_policy so the preferred-record consistency check in state.luau still applies to it.
function M.previous_policy(value: any): boolean
	return config.exact(value, "paused " .. config.keys.previous_editable)
end
local function valid_policy(p: any, legacy: boolean?): boolean
	-- Exactly-CP2, exactly-CP3, exactly-pre-sweep, exactly-pre-rollover-routing and exactly-0.3.0
	-- (27-key) policies are accepted only at the explicit restore boundary, which migrates them.
	local keys = config.keys
	if type(p) ~= "table" or p == tern.json.null then return false end
	if legacy then
		if type(p.auto_launch_intake) == "boolean" and p.auto_start_projects == nil then
			p = clone(p); p.auto_launch_intake = nil; p.auto_start_projects = false
		end
		local shape = M.upgradable_policy(p) or M.previous_policy(p) or config.exact(p, "paused " .. keys.editable)
			or config.exact(p, ("paused " .. keys.previous_editable):gsub("require_code_review require_other_family", "enforce_cross_family"))
			or config.exact(p, ("paused " .. keys.editable):gsub("require_code_review require_other_family", "enforce_cross_family"))
			or config.exact(p, keys.cp2) or config.exact(p, keys.cp3)
			or config.exact(p, "paused " .. keys.quota) or config.exact(p, "paused " .. keys.sweep) or config.exact(p, "paused " .. keys.v3)
		if not shape then return false end
		if p.family_map ~= nil and not M.valid_family_declarations(p.family_map) then return false end
		if p.role_guidance ~= nil then
			if not closed(p.role_guidance, table.concat(config.ROLES, " ")) then return false end
			for _, role in config.ROLES do if not str(p.role_guidance[role], 1024, true) then return false end end
		end
		if p.labeller_record ~= nil and p.labeller_record ~= "" and not config.record(p.labeller_record) then return false end
		for _, scope in quota.SCOPES do if p[scope .. "_model"] ~= nil and type(p[scope .. "_model"]) ~= "boolean" then return false end end
		if p.routes ~= nil then
			if not config.list(p.routes, 16) then return false end
			local classes = {}
			for _, route in p.routes do
				if not closed(route, "class record_id") or not config.slug(route.class, 32) or not config.record(route.record_id) or classes[route.class] then return false end
				classes[route.class] = true
			end
		end
		p = migrate_policy(p)
	end
	return next(config.policy_errors(p)) == nil
end
function M.policy(registry: any, session_id: string): any return clone(policy(registry.dispatch or fresh(), session_id)) end
function M.policy_revision(registry: any, session_id: string): number
	local cursor = ((registry.dispatch or {}).command_cursors or {})[session_id]
	return if cursor then cursor.policy_revision or 0 else 0
end
function M.default_policy(): any return clone(DEFAULT_POLICY) end
function M.migrate_policy(value: any): any return migrate_policy(value) end
function M.migrate_default_policy(value: any, never_saved: boolean): any
	local out = migrate_policy(value)
	if never_saved then
		-- These old built-ins were never committed as reusable user preferences.
		for _, key in { "concurrency_limit", "quota_max_age_ms", "auto_rollover", "rollover_threshold_pct" } do out[key] = DEFAULT_POLICY[key] end
		if out.release_manager_record == "" then out.merge_actor_mode = DEFAULT_POLICY.merge_actor_mode end
	end
	return out
end
function config.upgrade_policies(d: any)
	d.family_migrations = d.family_migrations or {}
	for sid, p in d.policies or {} do
		if p.family_map and next(p.family_map) ~= nil then
			local obligations = d.family_migrations[sid] or {}
			for record, family in p.family_map do if obligations[record] == nil then obligations[record] = family end end
			d.family_migrations[sid] = obligations
		end
		d.policies[sid] = migrate_policy(p)
	end
	for _, gate in d.gates or {} do
		if gate.kind == "label_unknown" and gate.phase == "pending" then
			local question = "Legacy classification no longer selects an agent. Use the Preferred Worker for this retained intake, or cancel it without taking the source."
			if gate.question ~= question then
				gate.question = question; gate.revision += 1
				gate.options = { { id = "route_now", label = "Use preferred worker" }, { id = "cancel", label = "Cancel this intake" } }
			end
		end
	end
end
function config.family_obligations(registry: any, sid: string): any
	local own = ((registry.dispatch or {}).family_migrations or {})[sid]
	return if own and next(own) ~= nil then own else (registry.installation_defaults or {}).family_migrations
end
function config.family(value: any): boolean
	return str(value, 96) and value:find("%c") == nil and value:find("%S") ~= nil and value == value:lower()
end
function M.valid_family_declarations(value: any): boolean
	if type(value) ~= "table" or value == tern.json.null or count(value) > 32 then return false end
	for record, family in value do if not config.record(record) or not config.family(family) then return false end end
	return true
end
function M.valid_policy(p: any, legacy: boolean?): boolean return valid_policy(p, legacy) end
function M.seed_policy(registry: any, session_id: string, p: any)
	assert(valid_policy(p), "invalid installation policy")
	registry.dispatch = if registry.dispatch then table.clone(registry.dispatch) else fresh()
	registry.dispatch.policies = table.clone(registry.dispatch.policies or {})
	registry.dispatch.policies[session_id] = clone(p)
end

-- Project identity is host-generated metadata, never a worker-reported landing project_id.
config.AUTHORITY_BYTES = 8 * 1024 * 1024
config.RETIREMENT_RESERVE = 512 * 1024
config.PRESENTATION_BYTES = 512 * 1024
local function bounded(text: string, maximum: number): string
	if #text <= maximum then return text end
	local stop = 0
	for position, code in utf8.codes(text) do
		local last = position + #utf8.char(code) - 1
		if last > maximum then break end
		stop = last
	end
	return text:sub(1, stop)
end
function config.project_ref(d: any, sid: string, key: any): any?
	local p = if type(key) == "string" then (d.projects or {})[key] else nil
	return if p and p.logical_session_id == sid and not p.finished then p else nil
end
function config.project_source(v: any): boolean
	return closed(v, "kind ref revision") and table.find({ "plan", "board", "inbox", "template", "manual" }, v.kind) ~= nil
		and str(v.ref, 8192) and (v.revision == nil or str(v.revision, 1024))
end
function config.project_folder(paths: any, path: any)
	if #paths == 16 or not str(path, 4096) or not (config.absolute(path, 4096) or path:sub(1, 2) == "\\\\") then return end
	if not table.find(paths, path) then table.insert(paths, path) end
end
function config.new_project(d: any, sid: string, name: string, source: any?): any
	d.projects = d.projects or {}
	local key = next_id(d, "project-")
	local p = { orch_project_id = key, logical_session_id = sid, name = name, revision = 1, started = false, sources = {}, associations = {} }
	if source then table.insert(p.sources, clone(source)) end
	d.projects[key] = p
	return p
end
function config.source_project(d: any, event: any, name: string, source: any?): (any?, any?)
	local p
	if event.orch_project_id ~= nil then
		p = config.project_ref(d, event.orch_session_id, event.orch_project_id)
		if not p then return fail("project_changed", "Choose an unfinished project in this orchestration.") end
	else p = config.new_project(d, event.orch_session_id, bounded(name, 160), source) end
	if source and not table.find(p.sources, source) then
		local found = false
		for _, prior in p.sources do if equal(prior, source) then found = true end end
		if not found then
			if #p.sources >= 256 then return fail("project_full", "This project's source references are full; add a separate project.") end
			table.insert(p.sources, clone(source)); p.revision += 1
		end
	end
	return p, nil
end
function config.project_started(d: any, value: any): boolean
	local p = config.project_ref(d, value.logical_session_id, value.orch_project_id)
	return p ~= nil and p.started == true
end
function config.standalone_start(n: any, p: any): boolean
	local d = n.dispatch
	if n.sessions[p.logical_session_id].orchestrator or (p.start and not p.start.claim
		and not (p.start.closed and config.start_owner_closed(n, p, p.start))) then return false end
	for _, r in d.rollovers or {} do if r.logical_session_id == p.logical_session_id and r.kind == "coordinator"
		and r.phase ~= "complete" and r.phase ~= "cancelled" then return false end end
	for _, w in d.workers do if w.logical_session_id == p.logical_session_id and w.coordinator_owner_id
		and (not w.mailbox_retired or (w.restored and not w.restored.reconciled)) then return false end end
	return true
end
function config.source_autostart(n: any, p: any, event: any): boolean
	return policy(n.dispatch, p.logical_session_id).auto_start_projects and not event.force_held
end
function config.auto_start_source(n: any, p: any, event: any, collection: string, key: string)
	local d, source = n.dispatch, (n.dispatch[collection] or {})[key]
	if not source or not source.start_policy or not policy(d, p.logical_session_id).auto_start_projects then return end
	-- A new policy-admitted source is independent authority, not reapproval of any revoked
	-- snapshot member. Changing an old member's content cannot make that member new.
	if p.start and p.start.closed and p.start.snapshot[collection][key] then return end
	for _, prior in p.start_history or {} do if prior.closed and prior.snapshot[collection][key] then return end end
	if not config.standalone_start(n, p) then
		if p.start and not p.start.claim and not config.start_replaceable(n, p, p.start) then return end
		local owner = n.sessions[p.logical_session_id].orchestrator
		local w = if owner then d.workers[owner.managed_worker_id] else nil
		if not owner or owner.phase ~= "running" or not w or w.phase ~= "accepted" or not w.accepted_event or w.accept_pending
			or w.coordinator_owner_id ~= owner.owner_id or w.coordinator_generation ~= owner.generation
			or w.logical_session_id ~= p.logical_session_id
			or not w.activation or not w.activation.acknowledged or w.retirement or w.release or w.continuation_required
			or not table.find(w.capabilities or {}, "coordinator-control-v1") or not table.find(w.capabilities or {}, "project-start-v1") then return end
		local snapshot = { workers = {}, plans = {}, intakes = {}, chains = {}, repository = quota.digest(p.repository or {}) }
		snapshot[collection][key] = config.start_source_digest(d, collection, source)
		local approved_policy = policy(d, p.logical_session_id)
		local context = quota.digest({ authority_namespace = n.authority_namespace, execution_epoch = n.execution_epoch,
			project = p.orch_project_id, project_revision = p.revision, snapshot = snapshot, policy = approved_policy,
			owner_id = owner.owner_id, owner_generation = owner.generation, worker_id = w.worker_id,
			activation_sha256 = codec.sha256(w.activation.bytes), origin = event.origin, controller_pane = event.controller_pane })
		config.issue_project_start(n, p, w, snapshot, context, event,
			{ kind = "policy", rule = "auto_start_projects", policy_revision = quota.digest(approved_policy) })
		return
	end
	source.held = nil
	-- Standalone source policy cannot release an older manually held member.
	if not p.started then
		for _, w in d.workers do if w.orch_project_id == p.orch_project_id
			and (w.project_held or (not w.accepted_event and not w.pane_binding and not w.open_conversation and not w.enrol_delivery and w.role ~= "coordinator")) then
			w.checks_pending = true
		end end
		p.started = true; p.revision += 1
	end
end
function config.successor_start_allowed(d: any, w: any): boolean
	local r = if w.handover_id then (d.rollovers or {})[w.handover_id] else nil
	local predecessor = if r then d.workers[r.predecessor_worker_id] else nil
	return r ~= nil and predecessor ~= nil and r.successor_worker_id == w.worker_id and r.handover_token == w.handover_token
		and r.logical_session_id == w.logical_session_id and r.work_id == w.work_id
		and predecessor.logical_session_id == w.logical_session_id and predecessor.work_id == w.work_id
		and predecessor.orch_project_id == w.orch_project_id and r.checkpoint ~= nil and r.verification ~= nil
		and (r.phase == "successor_granted" or r.phase == "successor_created")
end
function config.worker_start_allowed(d: any, w: any): boolean
	return config.project_ref(d, w.logical_session_id, w.orch_project_id) ~= nil and not policy(d, w.logical_session_id).paused
		and (w.role == "coordinator" or w.open_conversation == true or w.enrol_delivery ~= nil or config.successor_start_allowed(d, w) or config.project_started(d, w))
end
function config.valid_project_repository(v: any): boolean
	return closed(v, "cwd repo_root common_dir target_ref head_revision queue_route") and rulings.absolute(v.cwd)
		and rulings.absolute(v.repo_root) and rulings.absolute(v.common_dir) and str(v.target_ref, 256)
		and type(v.head_revision) == "string" and (#v.head_revision == 40 or #v.head_revision == 64)
		and v.head_revision:match("^[a-f0-9]+$") ~= nil and table.find({ "repository_queue", "orch_queue" }, v.queue_route) ~= nil
end
function config.same_conversation(a: any, b: any): boolean
	return a ~= nil and b ~= nil and a.pane_id == b.pane_id and a.native_session_id == b.native_session_id and a.window_host_id == b.window_host_id
end
function config.valid_association(conversation: any, key: any): boolean
	if not id(key) or not closed(conversation, "conversation_id pane_binding provider account_label active") then return false end
	local b = conversation.pane_binding
	return conversation.conversation_id == key and type(b) == "table" and pane_binding(b, b)
		and id(b.window_epoch) and str(b.window_key, 256, true) and str(b.native_session_id, 256) and str(b.window_host_id, 256)
		and type(conversation.active) == "boolean" and (conversation.provider == nil or str(conversation.provider, 80))
		and (conversation.account_label == nil or str(conversation.account_label, 160))
end
function config.restore_enrol_association(d: any, w: any)
	if not w.enrol_delivery or w.accepted_event then return end
	local project = config.project_ref(d, w.logical_session_id, w.orch_project_id)
	local binding = control_binding(w) or w.adopt_pane_binding
	if not project or not binding then return end
	project.associations = project.associations or {}
	for _, prior in project.associations do if config.same_conversation(prior.pane_binding, binding) then return end end
	local original = w.enrol_association
	local key = if original then original.conversation_id else next_id(d, "conversation-")
	project.associations[key] = if original then clone(original) else { conversation_id = key, pane_binding = clone(binding),
		provider = if w.selected_record then bounded(w.selected_record.provider, 80) else nil,
		account_label = if w.selected_record then w.selected_record.account_label else nil,
		active = not (w.workflow and w.workflow.exit ~= nil) }
	project.revision += 1; w.enrol_association = nil
end
function config.valid_projects(d: any, registry: any): boolean
	if (registry.version or 4) < 5 then return (d.projects == nil or next(d.projects) == nil) and (d.finished_projects == nil or next(d.finished_projects) == nil) end
	if type(d.projects) ~= "table" or d.projects == tern.json.null or type(d.finished_projects) ~= "table"
		or d.finished_projects == tern.json.null or #d.finished_projects > 100 or count(d.finished_projects) ~= #d.finished_projects then return false end
	for key, p in d.projects do
		if not id(key) or not closed(p, "orch_project_id logical_session_id name revision started sources associations repository finished checks_pending start start_history")
			or p.orch_project_id ~= key or not registry.sessions[p.logical_session_id] or not str(p.name, 160) or not p.name:find("%S")
			or not pos(p.revision) or type(p.started) ~= "boolean" or type(p.sources) ~= "table" or #p.sources > 256 or count(p.sources) ~= #p.sources
			or (p.finished ~= nil and p.finished ~= true) or (p.checks_pending ~= nil and p.checks_pending ~= true)
			or (p.repository ~= nil and not config.valid_project_repository(p.repository)) then return false end
		if p.start ~= nil and not config.valid_project_start(d, p, nil, registry) then return false end
		if p.start_history ~= nil then
			if not dense(p.start_history, 32) then return false end
			for _, prior in p.start_history do if not prior.closed or not config.valid_project_start(d, p, prior, registry) then return false end end
		end
		for _, source in p.sources do if not config.project_source(source) then return false end end
		if p.associations ~= nil then
			if type(p.associations) ~= "table" or p.associations == tern.json.null then return false end
			for key, conversation in p.associations do
				if not config.valid_association(conversation, key) then return false end
			end
		end
	end
	for _, s in d.finished_projects do
		if not closed(s, "name source result links finished_at_ms") or not str(s.name, 160) or not str(s.result, 2048)
			or (s.source ~= nil and not config.project_source(s.source)) or not (s.finished_at_ms == 0 or pos(s.finished_at_ms))
			or type(s.links) ~= "table" or #s.links > 8 or count(s.links) ~= #s.links or #tern.json.encode(s) > 4096 then return false end
		for _, link in s.links do
			if not closed(link, "kind ref label") or not table.find({ "conversation", "result" }, link.kind)
				or not str(link.ref, 512) or not str(link.label, 160) then return false end
		end
	end
	if #tern.json.encode(d.finished_projects) > config.PRESENTATION_BYTES then return false end
	for _, collection in { d.workers, d.plans or {}, d.intakes or {}, d.chains or {} } do
		for _, value in collection do
			local p = (d.projects or {})[value.orch_project_id]
			if not p or p.logical_session_id ~= value.logical_session_id then return false end
		end
	end
	return true
end
function M.trim_summaries(n: any, max_bytes: number?)
	local summaries = if n.dispatch then n.dispatch.finished_projects else nil
	if not summaries then return end
	local bound = max_bytes or config.AUTHORITY_BYTES - config.RETIREMENT_RESERVE
	while #summaries > 0 and (#summaries > 100 or #tern.json.encode(summaries) > config.PRESENTATION_BYTES or #tern.json.encode(n) > bound) do
		table.remove(summaries, 1)
	end
end
function M.upgrade_projects(n: any)
	local d = n.dispatch
	if not d then return end
	d.projects, d.finished_projects = {}, {}
	local fallback = {}
	local function existing(sid: string): any
		if not fallback[sid] then fallback[sid] = config.new_project(d, sid, "Existing work", nil) end
		return fallback[sid]
	end
	for _, key in config.sorted_keys(d.plans or {}, function() return true end) do
		local plan = d.plans[key]
		local p = config.new_project(d, plan.logical_session_id, bounded(plan.title, 160), { kind = "plan", ref = plan.path, revision = plan.plan_revision })
		plan.orch_project_id = p.orch_project_id; plan.held = true
		for _, cp in plan.checkpoints do for _, task in cp.tasks do
			for _, w in d.workers do if task.work_id == w.work_id and w.logical_session_id == plan.logical_session_id then w.orch_project_id = p.orch_project_id end end
		end end
	end
	for _, collection in { d.workers, d.intakes or {}, d.chains or {} } do
		for _, value in collection do
			value.orch_project_id = value.orch_project_id or existing(value.logical_session_id).orch_project_id
		end
	end
	for _, collection in { d.intakes or {}, d.chains or {} } do for _, value in collection do value.held = true end end
	for _, w in d.workers do
		if w.phase == "queued" and not w.launch_refused and not w.routing and not w.mailbox_handle and not w.pane_binding and not w.accepted_event then w.project_held = true end
	end
	for _, p in d.policies or {} do p.auto_start_projects = false; p.auto_launch_intake = nil end
	for _, rollover in d.rollovers or {} do
		if rollover.prepared then rollover.prepared.worker.orch_project_id = d.workers[rollover.predecessor_worker_id].orch_project_id end
	end
	local old = (n.installation_defaults or {}).repository
	if old then
		d.repository_policies = d.repository_policies or {}
		d.repository_policies[config.repository_policy_key(old.common_dir, old.target_ref)] = config.repository_choice(old)
		for _, p in d.projects do
			local matched, conflict = false, false
			for _, w in d.workers do if w.orch_project_id == p.orch_project_id and w.checkout then
				if rules.normalize_path(w.checkout.common_dir) == rules.normalize_path(old.common_dir) then matched = true else conflict = true end
			end end
			if matched and not conflict then p.repository = clone(old) end
		end
	end
	-- Explicit START is required even for old ready/unissued manual work. Issued bytes stay exact.
	for _, a in d.actions do if a.phase == "ready" and a.request_bytes == nil then a.phase = "held_ready" end end
end

-- Activity is an observation, not project membership or execution consent.
function config.project_decision(p: any): any
	if not p then return nil end
	local out = table.clone(p)
	if p.associations then
		out.associations = {}
		for key, conversation in p.associations do
			local member = table.clone(conversation); member.active = nil; out.associations[key] = member
		end
	end
	return out
end
-- Hash the captured subject, never unrelated global bookkeeping.
function M.decision_context(n: any, event: any): string?
	if type(event) ~= "table" or not table.find({ "answer", "new_project", "project_start", "project_start_retry", "project_associate", "project_repository", "associate_conversation", "catalog" }, event.command)
		or not M.origin(event.origin) or event.authority_namespace ~= n.authority_namespace then return nil end
	local d, sid = n.dispatch or fresh(), event.orch_session_id
	local session = n.sessions[sid]
	if not session or session.phase ~= "open" or n.migration or not authorized(n, event.origin, event.controller_pane) then return nil end
	local subject = { command = event.command, namespace = n.authority_namespace, epoch = n.execution_epoch,
		origin = event.origin, controller_pane = event.controller_pane, admission_seq = session.admission_seq, admitted = session.admitted,
		spawn_namespace = session.spawn_namespace, policy = policy(d, sid), controller = { owner_id = session.controller.owner_id,
			generation = session.controller.generation, phase = session.controller.phase }, compatibility = n.compatibility }
	if event.command == "catalog" then
		subject.cursor = event.bytes
		return quota.digest(subject)
	end
	if event.command == "new_project" then
		if not str(event.name, 160) or not event.name:find("%S")
			or (event.source ~= nil and not config.project_source(event.source)) then return nil end
		subject.project_selection = { name = event.name, source = event.source }
		return quota.digest(subject)
	end
	local workers = {}
	local p
	if event.command == "answer" then
		local g = (d.gates or {})[event.gate_id]
		if not g or g.logical_session_id ~= sid or g.revision ~= event.gate_revision or g.phase ~= "pending" then return nil end
		subject.gate = g
		if g.kind == "quota_fallback" then subject.capacity = (d.capacity or {})[sid] end
		local w = d.workers[g.worker_id]
		if not w then return nil end
		workers[w.worker_id] = w
		p = (d.projects or {})[w.orch_project_id]
		if g.proposal then
			local proposal = codec.decode_report(g.proposal, w)
			if proposal then
				for _, other in d.workers do if other.logical_session_id == sid and other.work_id == proposal.payload.work_id then workers[other.worker_id] = other end end
				if proposal.payload.orch_project_id then subject.proposal_project = config.project_decision((d.projects or {})[proposal.payload.orch_project_id]) end
				for _, row in (d.catalogs[sid] or {}).records or {} do if row.id == proposal.payload.record_id then subject.proposal_record = row end end
			end
		end
	else
		p = config.project_ref(d, sid, event.orch_project_id)
		if event.command == "project_start_retry" then
			local start = if p then p.start else nil
			return if start and start.start_id == event.start_id and start.project_revision == event.project_revision
				and start.decision_context == event.decision_context then start.decision_context else nil
		end
		if not p or p.revision ~= event.project_revision then return nil end
		if event.command == "project_repository" then
			if not config.valid_project_repository(event.repository) then return nil end
			subject.repository_selection = event.repository
			subject.target_repository_policy = (d.repository_policies or {})[config.repository_policy_key(event.repository.common_dir, event.repository.target_ref)]
		end
		if event.command == "associate_conversation" then
			if not pane_binding(event.pane_binding, event.origin) or type(event.active) ~= "boolean" then return nil end
			subject.selection = { pane_binding = event.pane_binding, provider = event.provider, account_label = event.account_label, active = event.active }
			subject.associations = {}
			for key, project in d.projects or {} do
				for cid, conversation in project.associations or {} do if config.same_conversation(conversation.pane_binding, event.pane_binding) then
					subject.associations[cid] = { project = key, revision = project.revision, conversation = conversation }
				end end
			end
			for key, worker in d.workers do if config.same_conversation(control_binding(worker) or worker.adopt_pane_binding, event.pane_binding) then workers[key] = worker end end
		elseif event.command == "project_associate" then
			local w = d.workers[event.worker_id]
			if not w or w.logical_session_id ~= sid then return nil end
			workers[w.worker_id] = w; subject.previous_project = config.project_decision((d.projects or {})[w.orch_project_id])
		else
			subject.sources = {}
			for _, collection in { d.plans or {}, d.intakes or {}, d.chains or {} } do
				for key, source in collection do if source.orch_project_id == p.orch_project_id then subject.sources[key] = source end end
			end
			for _, w in d.workers do if w.orch_project_id == p.orch_project_id then workers[w.worker_id] = w end end
		end
		if event.command == "project_start" then
			local owner = session.orchestrator
			subject.orchestrator = if owner then { owner_id = owner.owner_id, generation = owner.generation,
				phase = owner.phase, worker_id = owner.managed_worker_id } else false
			local w = if owner then d.workers[owner.managed_worker_id] else nil
			if w then workers[w.worker_id] = w end
		end
	end
	subject.project = config.project_decision(p); subject.workers = {}; subject.landings = {}; subject.routes = {}; subject.launch_gates = {}
	if p and p.repository then subject.repository_policy = (d.repository_policies or {})[config.repository_policy_key(p.repository.common_dir, p.repository.target_ref)] end
	for key, w in workers do
		local value = {}
		for field in ("worker_id worker_generation work_id orch_project_id origin_binding control_origin pane_binding control_pane_binding record_id record_revision selected_record effective_identity cwd placement execution_cwd presentation assignment_sha256 launch_request_id launch_action_id enrolment_token mailbox_handle phase accepted_event enrol_association project_held checks_pending role scope source files checks base_ref checkout check_results routing launch_gates continuation_required finish stopped withdrawn release activation retirement"):gmatch("%S+") do value[field] = w[field] end
		if w.workflow then value.checkpoints = w.workflow.checkpoints end
		subject.workers[key] = value
		for _, row in (d.catalogs[sid] or {}).records or {} do if row.id == w.record_id then subject.routes[row.id] = row end end
		if event.command == "project_start" then
			for _, gid in w.launch_gates or {} do subject.launch_gates[gid] = d.gates[gid] end
		end
		if w.coordinator_owner_id then
			local owner = session.orchestrator
			subject.orchestrator = if owner then { owner_id = owner.owner_id, generation = owner.generation, phase = owner.phase } else false
		end
		for lid, item in (d.landing or {}).items or {} do if item.work_id == w.work_id then
			subject.landings[lid] = item
			for qid, q in (d.landing or {}).queues or {} do if table.find(q.order, lid) then
				subject.landings[qid] = { repository = q.repository, head = q.head, slot = q.slot }
			end end
		end end
	end
	return quota.digest(subject)
end
function M.subject_decision(n: any, event: any): boolean
	return type(event) == "table" and event.kind == "dispatch" and type(event.expected_revision) == "number"
		and event.expected_revision <= n.revision and event.expected_revision >= 0 and digest(event.decision_context)
		and M.decision_context(n, event) == event.decision_context
end
local function stamp(clock: any): any
	local out = { at_ms = if type(clock) == "table" then clock.now_ms or 0 elseif type(clock) == "number" then clock else 0 }
	if type(clock) == "table" and id(clock.epoch) and type(clock.mono_ms) == "number" and clock.mono_ms >= 0 and clock.mono_ms <= MAX then
		out.epoch = clock.epoch; out.mono_ms = clock.mono_ms
	end
	return out
end
local function valid_stamp(v: any): boolean
	return type(v) == "table" and (v.at_ms == 0 or pos(v.at_ms)) and ((v.epoch == nil and v.mono_ms == nil)
		or (id(v.epoch) and type(v.mono_ms) == "number" and v.mono_ms >= 0 and v.mono_ms <= MAX))
end
local function elapsed(v: any, clock: any): number?
	if v and type(clock) == "table" and v.epoch ~= nil and v.epoch == clock.epoch and type(clock.mono_ms) == "number"
		and clock.mono_ms >= v.mono_ms then return clock.mono_ms - v.mono_ms end
	return nil
end
local function flow(w: any): any
	if not w.workflow then w.workflow = { thread = {}, evidence = {}, checkpoints = {}, due_poll = true, due_report = false } end
	if not w.workflow.report_request then
		local oldest
		for _, retained in w.replies do
			local reply = codec.decode_reply(retained.bytes, w)
			if reply and reply.kind == "report_request" and not retained.acknowledged and (not oldest or reply.reply_seq < oldest.reply_seq) then
				oldest = { request_id = reply.payload.request_id, message_id = reply.message_id, reply_seq = reply.reply_seq,
					action_id = reply.action_id, action_revision = reply.action_revision, bytes = retained.bytes,
					acknowledged = false, published = retained.part > #retained.frames.chunks + 1, response_received = false }
			end
		end
		w.workflow.report_request = oldest -- Bounded CP2 outbox migration; never drops older immutable replies.
	end
	return w.workflow
end
local function gate_open(g: any): boolean
	-- A quota_fallback gate is host-consumed: "resolved" closes it without any worker delivery.
	return not table.find({ "acknowledged", "cancelled", "superseded", "resolved" }, g.phase)
end
local function gate_for(d: any, w: any): any?
	local selected
	for _, g in d.gates or {} do
		if g.worker_id == w.worker_id and gate_open(g) and (not selected or g.id < selected.id) then selected = g end
	end
	return selected
end
-- Worker rollover overlaps predecessor and successor until handover acceptance; coordinator rollover
-- never overlaps two managed coordinators, hence its retire-before-grant phase order.
local ROLLOVER_PHASES = { "requested", "checkpoint_pending", "checkpoint_verified", "successor_granted", "successor_created",
	"handover_accepted", "predecessor_stop_requested", "predecessor_closed", "complete" }
local COORDINATOR_ROLLOVER_PHASES = { "requested", "checkpoint_pending", "checkpoint_verified", "retirement_requested", "predecessor_released",
	"predecessor_stop_requested", "predecessor_closed", "owner_retired", "successor_granted", "successor_created", "handover_accepted", "complete" }
local ROLLOVER_TERMINAL = { complete = true, cancelled = true }
local function rollover_phases(r: any): any return if r.kind == "coordinator" then COORDINATOR_ROLLOVER_PHASES else ROLLOVER_PHASES end
local function active_rollover(d: any, w: any): any?
	for _, r in d.rollovers or {} do
		if not ROLLOVER_TERMINAL[r.phase] and (r.predecessor_worker_id == w.worker_id or r.successor_worker_id == w.worker_id) then return r end
	end
	return nil
end
-- Landing queue: granted|landing items hold their target's single slot; terminal items are retained evidence.
local LANDING_STATUSES = { "queued", "verifying", "ready", "granted", "landing", "landed", "failed", "blocked", "cancelled" }
local LANDING_TERMINAL = { landed = true, failed = true, cancelled = true }
local LANDING_UNGRANTED = { queued = true, verifying = true, ready = true, blocked = true }
-- Contract I: an item's `worker_id` is its requester (the builder); `holder` is the release-manager
-- generation its current grant was issued to. Open items pin their requester and, while granted,
-- their holder. `in_flight` asks for a live (not uncertain) grant held by this generation: only
-- that blocks the holder's rollover — an uncertain grant stays with the generation that claimed it.
local function landing_open(d: any, worker_id: string, in_flight: boolean?): any?
	local selected
	for key, item in (d.landing or {}).items or {} do
		local granted = not LANDING_UNGRANTED[item.status] and not LANDING_TERMINAL[item.status]
		local holds = granted and item.holder ~= nil and item.holder.worker_id == worker_id
		local bound = if in_flight then holds and not (item.grants[#item.grants] or {}).uncertain
			else holds or (item.worker_id == worker_id and not LANDING_TERMINAL[item.status])
		if bound and (not selected or key < selected.id) then selected = item end
	end
	return selected
end
-- One coordinator rollover per session; it also reserves the slot against unrelated starts.
local function coordinator_rollover(d: any, session_id: string): any?
	for _, r in d.rollovers or {} do
		if r.kind == "coordinator" and r.logical_session_id == session_id and not ROLLOVER_TERMINAL[r.phase] then return r end
	end
	return nil
end
local function retired_coordinator(registry: any, w: any): boolean
	if not w.coordinator_owner_id then return false end
	local session = registry.sessions[w.logical_session_id]
	local owner = if session then session.orchestrator else nil
	return w.stopped ~= nil or owner == nil or owner.owner_id ~= w.coordinator_owner_id
		or owner.generation ~= w.coordinator_generation
end
-- Failed fresh coordinator startup retains its real pane and launch identity. Ownership
-- recovery is not exit or nonconsumption proof; SPAWN must prove both before retirement.
function config.failed_startup(n: any, w: any): boolean
	return w ~= nil and retired_coordinator(n, w) and w.role == "coordinator" and w.mailbox_handle ~= nil
		and w.pane_binding ~= nil and w.adopt_pane_binding == nil and w.enrol_delivery == nil
		and (w.phase == "awaiting_acceptance" or w.phase == "held") and w.accepted_event == nil
		and w.accepted_seq == 0 and w.compacted_floor == 0 and w.reply_seq == 0 and w.reply_floor == 0
		and w.activation == nil and w.retirement == nil and w.release == nil and w.stopped == nil
		and w.stop_action_id == nil and w.accept_pending == nil and w.rejected_report == nil
		and w.assembly == nil and not w.frozen and w.finish == nil
		and next(w.receipts) == nil and next(w.replies) == nil and next(w.wakes or {}) == nil
end
function config.failed_startup_cleanup(n: any, w: any): boolean
	local current, original = if w then control_binding(w) else nil, if w then w.pane_binding else nil
	return config.failed_startup(n, w) and w.restored == nil and current ~= nil and original ~= nil
		and current.pane_id == original.pane_id and current.window_key == original.window_key
		and current.native_session_id == original.native_session_id and current.window_host_id == original.window_host_id
end
-- A retired coordinator pane observed alive again (native restoration) holds every coordinator
-- effect in its session until reconciled; it is never counted as a healthy coordinator.
local function restored_coordinator(d: any, session_id: string): any?
	for _, w in d.workers do
		if w.logical_session_id == session_id and w.restored and not w.restored.reconciled then return w end
	end
	return nil
end
-- An explicit terminal revocation is a pre-effect refusal; expiry or missing state is not.
local function revoked_authorization(problem: any): boolean
	return type(problem) == "table" and problem.code == "authorization_revoked"
end
-- Outbound settlement a poll would grant without reading the report lane: ACK/reply
-- publication, acceptance, compaction, an answered decision or a startable native wake.
local function outbound_due(d: any, w: any, wake_ready: boolean): boolean
	local wakes = count(w.wakes or {})
	if (w.accept_pending and (w.phase ~= "held" or revoked_authorization(w.reason))) or w.compaction_pending then return true end
	for _, receipt in w.receipts do if receipt.publish and wakes < 32 then return true end end
	for _, g in d.gates or {} do if g.worker_id == w.worker_id and g.phase == "answered" then return true end end
	for _, reply in w.replies do if not reply.acknowledged and reply.part <= #reply.frames.chunks + 1 and wakes < 32 then return true end end
	if wake_ready then for _, wake in w.wakes or {} do if not wake.action_id then return true end end end
	return false
end
-- Known protocol work runs without the idle discovery delay. A rejected report holds only
-- its read lane; outbound settlement and proven-idle native wakes retain their own gates.
local function continuation_due(d: any, w: any, wake_ready: boolean): boolean
	return outbound_due(d, w, wake_ready) or (w.rejected_report == nil and (w.assembly ~= nil or w.read_selector ~= nil))
end
-- Measurements stay generation-local. Neither billing totals nor a percentage can
-- manufacture the first-turn baseline or context window.
function config.context_view(p: any, f: any): any
	local mode = if p.rollover_threshold_pct == 0 then "headroom" else "percentage"
	local c = f.context
	local status = if c then c.status or "unknown" else "unknown"
	local threshold = if mode == "percentage" then p.rollover_threshold_pct else nil
	if status == "measured" and mode == "headroom" then
		local s = c.snapshot
		if not s or s.first_turn_tokens == nil then status = "unknown"
		else threshold = 55 + 45 * s.first_turn_tokens / s.window_tokens end
	end
	return { mode = mode, status = status, threshold_pct = threshold }
end
function config.context_reached(p: any, f: any): boolean
	local view = config.context_view(p, f)
	if view.status ~= "measured" then return false end
	if view.mode == "percentage" then return f.context.used_pct >= p.rollover_threshold_pct end
	local s = f.context.snapshot
	-- Split before multiplication: every integer intermediate stays <= window even
	-- at MAX_SAFE_INTEGER, and an exact threshold never rounds upward as 0.55 can.
	local gap = s.window_tokens - s.first_turn_tokens
	local threshold = s.first_turn_tokens + 55 * math.floor(gap / 100) + math.ceil(55 * (gap % 100) / 100)
	return s.current_tokens >= threshold
end
function config.refresh_context(p: any, f: any, clock: any)
	local c = f.context
	if c then
		local now = stamp(clock).at_ms
		if c.status == nil or c.at_ms == nil then c = nil; f.context = nil -- Unmeasured legacy display history is not fresh runtime evidence.
		elseif c.status ~= "inconsistent" then
			local observed = if c.snapshot then c.snapshot.observed_at_ms else c.at_ms
			if now == 0 or c.at_ms == 0 then c.status = "unknown"
			elseif now < c.at_ms or now < observed then c.status = "inconsistent"
			elseif (c.epoch ~= nil and elapsed(c, clock) == nil) then c.status = "unknown"
			elseif now - observed >= p.stale_ms or now - c.at_ms >= p.stale_ms
				or (elapsed(c, clock) or 0) >= p.stale_ms then c.status = "stale" end
		end
	end
	if config.context_reached(p, f) then
		if not f.rollover_due_seq then f.rollover_due_seq = f.context.seq end
	else f.rollover_due_seq = nil end
end
function config.valid_context(c: any): boolean
	if not closed(c, "used_pct seq snapshot at_ms epoch mono_ms status") or not pos(c.seq)
		or type(c.used_pct) ~= "number" or c.used_pct < 0 or c.used_pct > 100 or c.used_pct ~= c.used_pct then return false end
	if c.status == nil then return closed(c, "used_pct seq") and c.used_pct % 1 == 0 end -- Immutable historical rollover evidence.
	if not table.find({ "measured", "unknown", "stale", "inconsistent" }, c.status) or not valid_stamp(c) then return false end
	return if c.snapshot ~= nil then codec.valid_context_snapshot(c.snapshot) and c.used_pct == 100 * c.snapshot.current_tokens / c.snapshot.window_tokens
		else c.used_pct % 1 == 0
end

local function refresh(d: any, w: any, clock: any)
	local f, p = flow(w), policy(d, w.logical_session_id)
	config.refresh_context(p, f, clock)
	if type(clock) == "table" and id(clock.epoch) and type(clock.mono_ms) == "number" and w.phase == "accepted"
		and (not f.started or f.started.epoch ~= clock.epoch) then f.started = stamp(clock) end
	local nr, rr = elapsed(f.native, clock), elapsed(f.report, clock)
	local native = if f.exit or w.stopped then "exited" elseif f.native and nr ~= nil and nr <= p.stale_ms then f.native.state else "unknown"
	local reported = if f.report then f.report.state else "unknown"
	local fresh = if rr == nil then "unconfirmed" elseif rr >= p.stale_ms then "stale" else "fresh"
	local required_age = rr or elapsed(f.started, clock)
	local g = gate_for(d, w)
	local status = if native == "exited" then "exited" elseif g then "owner_gate" elseif reported == "blocked" then "blocked"
		elseif native == "waiting-input" or reported == "waiting" then "waiting_input" elseif fresh == "stale" or (required_age ~= nil and required_age >= p.stale_ms) then "stale_report"
		elseif native == "working" or native == "idle" then native
		elseif fresh == "fresh" and (reported == "working" or reported == "idle") then reported else "unknown"
	f.health = { status = status, reason = if g then g.question elseif status == "stale_report" then "Required progress report is stale."
		elseif status == "unknown" then "Fresh native/report evidence is unavailable." else status,
		native_state = native, reported_state = reported, latest_native = clone(f.native), latest_report = clone(f.report), latest_exit = clone(f.exit),
		gate_id = if g then g.id else nil, freshness = fresh, awaiting_window = nr == nil or nr >= p.stale_ms or native == "unknown" }
	local since = elapsed(f.last_poll, clock)
	-- A held (rejected) report blocks this generation's report lane until the owner acts: no read
	-- can pass it, so automatic polling continues only for outbound settlement a poll would grant,
	-- and no automatic progress request is issued that could never be answered.
	local held = w.rejected_report ~= nil
	local continuation = continuation_due(d, w, native == "idle" and not (f.native and f.native.delivery_error))
	f.due_poll = w.pane_binding ~= nil and not w.mailbox_retired and (continuation or since == nil or since >= p.poll_ms) and not pending(d, w)
		and (not held or continuation)
	local safe = not (f.native and f.native.delivery_error) and (native == "idle" or (native == "unknown" and table.find(w.capabilities or {}, "worker-poll-v1") ~= nil))
	-- Owner-excluded workers are never chosen for automatic report requests; observation and
	-- mailbox settlement continue, and exclusion never stops or retires anything.
	f.due_report = not p.paused and p.automatic_reports and w.phase == "accepted" and not w.release and not w.retirement and not w.start_retirement and not w.finish
		and not held and not g and safe and f.report_request == nil and required_age ~= nil and required_age >= p.report_request_ms
		and table.find(p.excluded_workers, w.worker_id) == nil and active_rollover(d, w) == nil
		and not (f.report_loop and f.report_loop.state == "stopped") -- An owner-stopped report loop (loop_cap) stays stopped until a new report.
end
-- Policy-driven rollover only *requests* a checkpoint; every later edge needs its own evidence.
-- Coordinators are eligible only with rollover_include_coordinator and an active, activated owner.
local function rollover_due(registry: any, w: any, f: any): (boolean, string)
	local d = registry.dispatch
	local p = policy(d, w.logical_session_id)
	if not p.auto_rollover then return false, "Automatic rollover is off in Config." end
	if p.paused then return false, "Session is paused." end
	if not config.project_ref(d, w.logical_session_id, w.orch_project_id) then return false, "The project is finished; explicitly move this conversation to unfinished work before requesting rollover." end
	if table.find(p.excluded_workers, w.worker_id) ~= nil then return false, "Worker is excluded from automatic orchestration in Config." end
	if w.role == "reviewer" or w.role == "labeller" then return false, "Reviewer and labeller workers finish automatically after their one result; they are never rolled over." end
	if w.phase ~= "accepted" or w.finish or w.stopped or w.mailbox_retired or w.continuation_required then
		return false, "Automatic rollover requires an accepted, explicitly continued generation that is not finishing."
	end
	if w.coordinator_owner_id then
		if not p.rollover_include_coordinator then return false, "Coordinator rollover is not included in Config." end
		local owner = registry.sessions[w.logical_session_id].orchestrator
		if not owner or owner.owner_id ~= w.coordinator_owner_id or owner.generation ~= w.coordinator_generation or owner.managed_worker_id ~= w.worker_id
			or owner.phase ~= "running" or not w.activation or not w.activation.acknowledged or w.retirement or w.release then
			return false, "Coordinator rollover requires the current running, activated coordinator that is not retiring."
		end
		if coordinator_rollover(d, w.logical_session_id) or restored_coordinator(d, w.logical_session_id) then
			return false, "A coordinator rollover or restored-coordinator hold is already in progress in this session."
		end
	end
	if active_rollover(d, w) then return false, "A rollover for this worker is already in progress." end
	if landing_open(d, w.worker_id, true) then return false, "This worker holds a landing grant; its exact result or owner reconciliation settles first." end
	if config.deploy_in_flight(d, w.worker_id) then return false, "This worker holds a deploy grant; its exact DEPLOY_RESULT or owner reconciliation settles first." end
	if not config.context_reached(p, f) then return false, "Reliable current runtime context is unavailable or below the rollover threshold." end
	if not w.coordinator_owner_id and (not f.rollover_due_seq or not f.boundary_seq or f.boundary_seq < f.rollover_due_seq) then
		return false, "Context threshold reached; rollover waits for this worker's next completed-work CHECKPOINT boundary."
	end
	if not f.health or f.health.status ~= "idle" or f.report_request ~= nil or gate_for(d, w) then
		return false, "Worker is not idle at a clean point (no outstanding request, gate or busy native state)."
	end
	return true, "Worker-reported context reached the rollover threshold."
end
local function append(d: any, w: any, kind: string, summary: string, clock: any, refs: any?): (any?, any?)
	local entries = flow(w).thread
	if not refs or refs.state ~= "pending" then return nil, nil end
	if #entries >= 128 then return fail("full", "Durable work thread is full of unresolved items; no evidence was evicted.") end
	local entry = { id = next_id(d, "entry-"), kind = kind, summary = summary:sub(1, 32768), at_ms = stamp(clock).at_ms, state = "pending" }
	for k, v in refs or {} do entry[k] = clone(v) end
	table.insert(entries, entry); return entry, nil
end
local function settle_entries(w: any, key: string, value: any)
	local entries = flow(w).thread
	for i = #entries, 1, -1 do
		local entry = entries[i]
		if entry[key] == value then
			table.remove(entries, i)
		end
	end
end
local function reclaim_gates(d: any)
	for key, g in d.gates or {} do
		local dependent = false
		for _, action in d.actions do if action.stale_gate_id == key or (action.claim and action.claim.stale_gate_id == key) then dependent = true end end
		for _, rv in d.reviews or {} do if rv.gate_id == key then dependent = true end end
		for _, item in (d.landing or {}).items or {} do if item.gate_id == key and not LANDING_TERMINAL[item.status] then dependent = true end end
		for _, rec in d.intakes or {} do if rec.label and rec.label.gate_id == key then dependent = true end end
		if not dependent and not g.ruling and not gate_open(g) and (not g.delivery or g.delivery.acknowledged)
			and not g.delivery_uncertain and (not g.execution or g.execution.state ~= "pending") then
			local w = d.workers[g.worker_id]
			if w then
				local entries = flow(w).thread
				for i = #entries, 1, -1 do if entries[i].gate_id == key then table.remove(entries, i) end end
				if flow(w).health and flow(w).health.gate_id == key then flow(w).health = nil end
			end
			d.gates[key] = nil
		end
	end
end
local function work_referenced(d: any, w: any, stopping_writer: boolean?): boolean
	if active_rollover(d, w) or landing_open(d, w.worker_id) then return true end -- Unfinished handovers and open landing items pin generations.
	for _, item in (d.landing or {}).items or {} do
		if item.work_id == w.work_id and config.deploy_pins_item(d, item) then return true end
	end
	for _, g in d.gates or {} do
		-- A gate's subject and its document writer may be different workers. The exact
		-- writer may stop/retire normally, but its ended-generation evidence stays live
		-- until the document obligation is observed or explicitly reissued.
		local writer = if g.ruling and g.ruling.intent then g.ruling.intent.writer else nil
		if not stopping_writer and writer and writer.kind == "worker" and writer.worker_id == w.worker_id
			and writer.worker_generation == w.worker_generation then return true end
		if g.proposal and (gate_open(g) or (g.ruling and not stopping_writer) or (g.execution and g.execution.state == "pending") or (g.delivery and not g.delivery.acknowledged)) then
			local source = d.workers[g.worker_id]
			local proposal = if source then codec.decode_report(g.proposal, source) else nil
			if g.worker_id == w.worker_id or (proposal and proposal.payload.work_id == w.work_id) then return true end
		elseif g.worker_id == w.worker_id and (gate_open(g) or (g.ruling and not stopping_writer) or (g.delivery and not g.delivery.acknowledged)) then return true end
	end
	-- Landing evidence is pinned by its open queue item and review evidence by its open review
	-- (the reviews record owns an accepted REVIEW_RESULT), not by the latest report kind.
	return flow(w).evidence.ROLLOVER_REQUEST ~= nil or config.review_pinned(d, w) or config.deploy_pinned(d, w) or config.label_pinned(d, w)
end
function config.refused_handover_clear(d: any, w: any): boolean
	for _, a in d.actions do if a.worker_id == w.worker_id then
		local op = a.request.op
		if (op == "mailbox_provision" or op == "launch" or op == "adopt" or op == "enrol") and a.phase ~= "complete" then return false end
		if (op == "launch" or op == "adopt" or op == "enrol") and (not a.response
			or (a.response.status ~= "rejected" and not (a.response.status == "full" and retryable_full(a.response.payload)))) then return false end
	end end
	for _, g in d.gates do
		if g.worker_id == w.worker_id and (gate_open(g) or g.ruling or g.ruling_delivery) then return false end
	end
	return true
end
-- Retain first-page provenance across the exact official cursor chain. A last page alone is not a roster.
function config.observe_catalog(d: any, sid: string, request: any, payload: any): (any?, boolean)
	local previous = d.catalogs[sid]
	if previous and payload.config_revision < previous.config_revision then return previous, false end
	local contiguous = request.cursor ~= nil and (d.catalog_scans or {})[sid] == true and previous ~= nil
		and previous.namespace == payload.namespace and previous.host_key == payload.host_key
		and previous.config_revision == payload.config_revision and equal(previous.next_cursor, request.cursor)
	local from_start = request.cursor == nil or contiguous
	local records
	if contiguous then
		if #previous.records + #payload.records > 256 then return nil, false end
		local seen = {}
		for _, row in previous.records do seen[row.id] = true end
		for _, row in payload.records do
			if seen[row.id] then return nil, false end
			seen[row.id] = true
		end
		records = previous.records
		for _, row in payload.records do table.insert(records, clone(row)) end
	else
		records = clone(payload.records)
	end
	local observed = {}
	for key, value in payload do if key ~= "records" then observed[key] = clone(value) end end
	observed.records = records
	d.catalogs[sid] = observed
	d.catalog_pages = d.catalog_pages or {}
	d.catalog_pages[sid] = clone(payload)
	d.catalog_scans = d.catalog_scans or {}
	d.catalog_scans[sid] = if from_start then payload.next_cursor ~= nil else nil
	return observed, from_start and payload.next_cursor == nil and (previous == nil or payload.config_revision >= previous.config_revision)
end
function config.prune_family_orphans(n: any, roster: any)
	local d = n.dispatch
	local needed = n.installation_defaults.family_migrations ~= nil and next(n.installation_defaults.family_migrations) ~= nil
	if not needed and d.family_migrations then for _, values in d.family_migrations do if next(values) ~= nil then needed = true; break end end end
	if not needed then return end
	local present, protected = {}, {}
	for _, row in roster.records do present[row.id] = true end
	for _, w in d.workers do
		if not w.mailbox_retired or pending(d, w) or work_referenced(d, w) then protected[w.record_id] = true end
	end
	for _, rollover in d.rollovers or {} do
		local w = if rollover.prepared then rollover.prepared.worker else nil
		if w and not w.mailbox_retired then protected[w.record_id] = true end
	end
	for _, action in d.actions do
		if action.request.op == "declare_provider_families"
			and (action.phase ~= "complete" or not action.response
				or (action.response.status ~= "resolved" and action.response.status ~= "rejected")) then
			for _, value in action.request.declarations do protected[value.record_id] = true end
		end
	end
	for _, declarations in d.family_migrations or {} do
		for record in declarations do if not present[record] and not protected[record] then declarations[record] = nil end end
	end
	local declarations = n.installation_defaults.family_migrations
	local copied = false
	for record in declarations or {} do
		if not present[record] and not protected[record] then
			if not copied then n.installation_defaults = clone(n.installation_defaults); declarations = n.installation_defaults.family_migrations; copied = true end
			declarations[record] = nil
		end
	end
	for _, action in d.actions do
		if action.request.op == "declare_provider_families" and action.phase == "complete" and action.response
			and (action.response.status == "resolved" or action.response.status == "rejected") then
			local own = (d.family_migrations or {})[action.request.origin_binding.logical_session_id]
			local defaults, remaining = n.installation_defaults.family_migrations, false
			for _, value in action.request.declarations do
				if (own and own[value.record_id] ~= nil) or (defaults and defaults[value.record_id] ~= nil) then remaining = true end
			end
			if not remaining then action.family_migration_confirmed = true; config.consume_action(d, action) end
		end
	end
end
local function reclaim_workers(registry: any)
	local d = registry.dispatch
	reclaim_gates(d)
	for key, w in d.workers do
		local owner = registry.sessions[w.logical_session_id].orchestrator
		local start_evidence = false
		for _, p in d.projects or {} do
			if p.start and p.start.coordinator.worker_id == key then start_evidence = true end
			for _, prior in p.start_history or {} do if prior.coordinator.worker_id == key then start_evidence = true end end
		end
		if w.mailbox_retired and not start_evidence and not (owner and owner.managed_worker_id == key) and not pending(d, w) and not work_referenced(d, w) then
			for action_id, action in d.actions do
				if action.worker_id == key then d.actions[action_id] = nil end
			end
			-- Cancelled reviews have no approval to preserve. Reclaim their settled obligation
			-- with its evidence-bearing worker, before removing the only settlement evidence.
			for review_id, rv in d.reviews or {} do
				if rv.reviewer_worker_id == key and rv.status == "cancelled" and rv.result == nil
					and not config.cancelled_review_pending(d, rv) then d.reviews[review_id] = nil end
			end
			-- Monotonic IDs and command_cursors survive settled-record reclamation.
			d.workers[key] = nil
		end
	end
	-- Exclusions name durable workers only; drop entries whose settled worker was reclaimed.
	for sid, p in d.policies or {} do
		for i = #p.excluded_workers, 1, -1 do
			if not d.workers[p.excluded_workers[i]] then
				table.remove(p.excluded_workers, i)
				local cursor = (d.command_cursors or {})[sid]
				if cursor then cursor.policy_revision = registry.revision end
			end
		end
	end
end
local function new_gate(d: any, w: any, kind: string, question: string, options: any, evidence: any, clock: any, proposal: any?): (any?, any?)
	d.gates = d.gates or {}
	if count(d.gates) >= 64 then reclaim_gates(d) end
	if count(d.gates) >= 64 then return fail("full", "Durable gate capacity is full; unresolved decisions are retained.") end
	local g = { id = next_id(d, "gate-"), revision = 1, work_id = w.work_id, worker_id = w.worker_id, worker_generation = w.worker_generation,
		logical_session_id = w.logical_session_id, pane_binding = clone(w.pane_binding), kind = kind, phase = "pending", question = question,
		options = clone(options), evidence = clone(evidence or {}), proposal = clone(proposal), at_ms = stamp(clock).at_ms }
	local _, err = append(d, w, "question", question, clock, { state = "pending", gate_id = g.id }); if err then return nil, err end
	d.gates[g.id] = g; return g, nil
end
-- Effective loop caps (Contract L). A loop record { count, gate_id?, state? } counts engagements
-- that re-engage a model or a worker. `loop_cap` engagements happen; the next attempt trips the
-- loop (state "gated") and opens one host-consumed loop_cap gate instead of engaging. allow_more
-- resets the count; stop (or cancel) keeps it "stopped". Code-only waits are never counted.
-- Host-consumed gates (HOST_GATES): the reducer applies the owner's answer itself ("resolved") and
-- never delivers an owner_decision; e.g. checkout gates release/cancel a held launch or block landing,
-- review gates re-run reviewer selection, label_unknown re-checks routes or retries the labeller.
local loops: any = { HOST_GATES = protocol.HOST_GATES,
	GATE_KINDS = { "owner_question", "coordinator_proposal", "native_input", "landing_approval", "quota_fallback", "loop_cap", "stale_claim", "legacy_grant_outstanding",
		"shared_checkout", "file_overlap", "scope", "reviewer_unavailable", "family_unknown", "deploy_hold", "intake", "label_unknown" } }
function loops.gate(d: any, loop: any?): any?
	local g = if loop and loop.gate_id then (d.gates or {})[loop.gate_id] else nil
	return if g and g.kind == "loop_cap" and gate_open(g) then g else nil
end
function loops.trips(loop: any?, cap: number): boolean return loop ~= nil and (loop.state ~= nil or loop.count >= cap) end
function loops.open(d: any, w: any, loop: any, name: string, target: string, question: string, cap: number, clock: any, allow: boolean): (any?, any?)
	loop.state = "gated"
	local open = loops.gate(d, loop)
	if open then return open, nil end
	loop.gate_id = nil
	if type(clock) == "table" and clock.reserved_capacity then
		return fail("capacity_reached", "Authority capacity is at its settlement reserve; the loop stays stopped and its owner gate opens on a later commit.")
	end
	local options = { { id = "stop", label = "Keep it stopped" } }
	if allow then table.insert(options, 1, { id = "allow_more", label = "Allow " .. tostring(cap) .. " more attempts" }) end
	local g, err = new_gate(d, w, "loop_cap", question, options,
		{ "loop:" .. name, "target:" .. target, "count:" .. tostring(loop.count), "cap:" .. tostring(cap) }, clock)
	if err then return nil, err end
	loop.gate_id = g.id
	return g, nil
end
function loops.for_gate(d: any, gate_id: string): any?
	for _, r in d.rollovers or {} do if r.checkpoint_loop and r.checkpoint_loop.gate_id == gate_id then return r.checkpoint_loop end end
	for _, a in d.actions do if a.retry_loop and a.retry_loop.gate_id == gate_id then return a.retry_loop end end
	for _, w in d.workers do
		local f = w.workflow
		if f and f.report_loop and f.report_loop.gate_id == gate_id then return f.report_loop end
		if w.check_rework and w.check_rework.gate_id == gate_id then return w.check_rework end
	end
	for _, item in (d.landing or {}).items or {} do
		for _, key in { "refresh_loop", "grant_loop" } do if item[key] and item[key].gate_id == gate_id then return item[key] end end
	end
	for _, rv in d.reviews or {} do if rv.loop and rv.loop.gate_id == gate_id then return rv.loop end end
	for _, dp in d.deploys or {} do if dp.loop and dp.loop.gate_id == gate_id then return dp.loop end end
	for _, c in d.chains or {} do if c.loop and c.loop.gate_id == gate_id then return c.loop end end
	for _, rec in d.intakes or {} do if rec.label and rec.label.loop.gate_id == gate_id then return rec.label.loop end end
	return nil
end
function loops.valid(v: any, causes: any?, keyed: boolean?): boolean
	return closed(v, (if causes then "count gate_id state cause" else "count gate_id state") .. (if keyed then " key" else "")) and (v.count == 0 or pos(v.count))
		and (v.gate_id == nil or id(v.gate_id)) and (v.state == nil or v.state == "gated" or v.state == "stopped")
		and (v.cause == nil or table.find(causes or {}, v.cause) ~= nil) and (v.key == nil or digest(v.key))
end
function config.family_of(d: any, w: any): string?
	local row
	for _, candidate_row in (d.catalogs[w.logical_session_id] or {}).records or {} do
		if candidate_row.id == w.record_id and (w.selected_record == nil or (candidate_row.provider == w.selected_record.provider
			and candidate_row.account_label == w.selected_record.account_label and candidate_row.model_variant == w.selected_record.model)) then row = candidate_row end
	end
	return if row then row.provider_family else nil
end
function config.bind_family(d: any, w: any)
	w.family = config.family_of(d, w)
	for _, row in (d.catalogs[w.logical_session_id] or {}).records or {} do if row.id == w.record_id and row.revision == w.record_revision then
		w.selected_record = { id = row.id, revision = row.revision, provider = row.provider, account_label = row.account_label, model = row.model_variant, backend = row.backend }
		break
	end end
end
-- Contract A worker fields. Successors copy the assignment-shaped fields; family is recomputed
-- for the successor's record; checkout, check results and usage readings are never inherited.
-- base_ref completes the manifest inputs (Contract G); launch_gates lists the queue-time
-- shared_checkout/file_overlap gates (and a work source's intake gate) that hold a never-provisioned worker before launch.
-- review_id binds a reviewer worker to the review it serves; check_rework independently tracks
-- repair in every mode { count, gate_id?, state?, key? } (key: digest of the last repaired revision).
-- scope_accepted { changed_digest, gate_id, at_ms } is the owner's durable accept of the exact
-- out-of-scope change set (config.scope_problem digest), written in the answer's commit; landing
-- reads it, never gate existence, so gate reclamation cannot re-block an accepted change set.
-- shared_acked lists the "peer:<worker>:<path>" keys of acknowledged post-launch shared_checkout
-- gates, so a reclaimed acknowledgement is never asked again. Restore default: absent; neither
-- is inherited by a successor (its own CHECKOUT is judged and accepted afresh).
config.WORKER_FIELDS = "role family class template_id files scope checks source base_ref manifest_sha256 checkout check_results usage_before usage_after launch_gates review_id check_rework scope_accepted shared_acked mailbox_allocation launch_refused_op"
config.SUCCESSOR_FIELDS = { "role", "class", "template_id", "files", "scope", "checks", "source", "base_ref", "manifest_sha256", "ruling_document" }
config.SOURCE_KINDS = { "manual", "plan", "board", "inbox", "template" }
function config.usage(v: any): boolean return v == nil or quota.valid_usage(v) end
function config.worker_fields(w: any, legacy: boolean?): boolean
	if (not (legacy == true and w.role == nil) and not table.find(config.ROLES, w.role)) or (w.family ~= nil and not config.family(w.family))
		or (w.class ~= nil and not config.slug(w.class, 32)) or (w.template_id ~= nil and not config.slug(w.template_id, 32))
		or (w.files ~= nil and not config.texts(w.files, 64, 256)) or (w.manifest_sha256 ~= nil and not digest(w.manifest_sha256))
		or (w.base_ref ~= nil and not str(w.base_ref, 256)) or not config.usage(w.usage_before) or not config.usage(w.usage_after)
		or (w.review_id ~= nil and (not id(w.review_id) or w.role ~= "reviewer")) then return false end
	if w.check_rework ~= nil and not loops.valid(w.check_rework, nil, true) then return false end
	local sa = w.scope_accepted
	if sa ~= nil and (not closed(sa, "changed_digest gate_id at_ms") or not digest(sa.changed_digest) or not id(sa.gate_id) or not (sa.at_ms == 0 or pos(sa.at_ms))) then return false end
	if w.shared_acked ~= nil and not config.texts(w.shared_acked, 32, 1024, 1) then return false end
	if w.launch_gates ~= nil then
		if not config.texts(w.launch_gates, 3, 96, 1) or w.phase ~= "queued" or w.mailbox_handle ~= nil or w.routing ~= nil then return false end
		for _, gate_id in w.launch_gates do if not id(gate_id) then return false end end
	end
	if w.scope ~= nil and (not closed(w.scope, "paths systems") or not config.texts(w.scope.paths, 64, 256) or not config.texts(w.scope.systems, 16, 80)) then return false end
	if w.checks ~= nil then
		if not config.list(w.checks, 16) then return false end
		local seen = {}
		for _, check in w.checks do
			if not closed(check, "check_id argv") or not id(check.check_id) or seen[check.check_id] or not config.texts(check.argv, 16, 512, 1) then return false end
			seen[check.check_id] = true
		end
	end
	local s = w.source
	if s ~= nil and (not closed(s, "kind ref revision") or not table.find(config.SOURCE_KINDS, s.kind)
		or (s.ref ~= nil and not wire_text(s.ref, 8192)) or (s.revision ~= nil and not wire_text(s.revision, 1024))) then return false end
	local c = w.checkout
	if c ~= nil then
		-- Bounds follow the CHECKOUT codec (absolute paths ≤4096 including UNC, paths ≤4096 each).
		local absolute_path = function(v: any): boolean return str(v, 4096) and (v:sub(1, 1) == "/" or v:match("^%a:[\\/]") ~= nil or v:sub(1, 2) == "\\\\") end
		if not closed(c, "worktree_path common_dir branch head base changed_files changed_overflow changed_total dirty event_id seq host_key")
			or not absolute_path(c.worktree_path) or not absolute_path(c.common_dir) or not str(c.branch, 1024, true)
			or (c.host_key ~= nil and not str(c.host_key, 256))
			or not wire_text(c.head, 1024) or (c.base ~= nil and not wire_text(c.base, 1024)) or not config.texts(c.changed_files, 512, 4096)
			or type(c.changed_overflow) ~= "boolean" or not (c.changed_total == 0 or pos(c.changed_total)) or c.changed_total < #c.changed_files
			or type(c.dirty) ~= "boolean" or (c.event_id ~= nil and not id(c.event_id)) or (c.seq ~= nil and (not pos(c.seq) or c.seq > w.accepted_seq)) then return false end
	end
	if w.check_results ~= nil then
		if type(w.check_results) ~= "table" or w.check_results == tern.json.null or count(w.check_results) > 16 then return false end
		for key, r in w.check_results do
			if not id(key) or not closed(r, "check_id argv_sha256 exit_code output_sha256 head ran_at_ms event_id seq") or r.check_id ~= key
				or not digest(r.argv_sha256) or type(r.exit_code) ~= "number" or r.exit_code % 1 ~= 0 or r.exit_code < -2147483648 or r.exit_code > 4294967295
				or not digest(r.output_sha256) or not wire_text(r.head, 1024) or not (r.ran_at_ms == 0 or pos(r.ran_at_ms))
				or (r.event_id ~= nil and not id(r.event_id)) or (r.seq ~= nil and (not pos(r.seq) or r.seq > w.accepted_seq)) then return false end
		end
	end
	return true
end
-- Contract G assignment fields from a queue intent. Role is ORCH+'s (never the worker's);
-- scope.paths defaults to files; checks argv are stored and forwarded, never interpreted.
config.ASSIGNMENT_FIELDS = { "role", "class", "template_id", "files", "scope", "checks", "source", "base_ref" }
function config.assign(w: any, event: any): any?
	if event.role ~= nil and (not table.find(config.ROLES, event.role) or (event.role == "coordinator") ~= (event.coordinator == true)) then
		return { ok = false, code = "invalid_assignment", message = "Role is one of builder, reviewer, release_manager or labeller; coordinators start through the coordinator switch." }
	end
	if event.role == "release_manager" or event.role == "labeller" then
		return { ok = false, code = "invalid_assignment", message = "Use the preferred worker or explicitly selected reviewer. Release actors are granted by merge policy; classifier-only workers are no longer launched." }
	end
	for _, key in config.ASSIGNMENT_FIELDS do if event[key] ~= nil then w[key] = clone(event[key]) end end
	if w.scope == nil and w.files ~= nil then w.scope = { paths = clone(w.files), systems = {} } end
	if not config.worker_fields(w) then
		return { ok = false, code = "invalid_assignment", message = "Assignment fields are bounded: class/template id lowercase slugs; files ≤64 paths of ≤256 bytes; scope {paths ≤64×256, systems ≤16×80}; checks ≤16 distinct {check_id, argv 1..16 × ≤512}; source {kind manual|plan|board|inbox|template, ref?, revision?}; base_ref ≤256." }
	end
	local bytes, problem = config.manifest(w)
	if problem then return { ok = false, code = problem.code, message = problem.message .. " Nothing was queued." } end
	w.manifest_sha256 = if bytes then codec.sha256(bytes) else nil
	return nil
end
-- The authenticated assignment manifest (Contract G) is rebuilt from the stored fields; its exact
-- canonical bytes are what SPAWN binds, so the worker keeps only their digest.
function config.manifest(w: any): (string?, any?)
	if w.checks == nil and w.files == nil and w.scope == nil and w.base_ref == nil then return nil, nil end
	return codec.encode_manifest({ checks = w.checks or {}, files = w.files or {}, scope = w.scope or { paths = {}, systems = {} }, base_ref = w.base_ref })
end
-- Conservative admission over the existing physical allocation domain. No second allocator:
-- queued/uncertain intents reserve space; only positive retirement frees a known allocation.
function config.agent_space(d: any, candidate: any): any?
	local slots = {}
	for key, w in d.workers do
		if not w.mailbox_retired and (w.mailbox_handle or w.mailbox_allocation == "possible" or (w.launch_refused and w.mailbox_allocation ~= "none")) then slots[key] = w end
	end
	for _, a in d.actions do
		local w = if a.worker_id then d.workers[a.worker_id] else nil
		if a.request.op == "mailbox_provision" and w and not w.mailbox_retired then slots[w.worker_id] = w end
	end
	for _, r in d.rollovers or {} do
		local w = if r.prepared then r.prepared.worker else nil
		if w and not w.mailbox_retired then slots[w.worker_id] = w end
	end
	if slots[candidate.worker_id] then return nil end -- Continuing this exact reserved generation consumes no new slot.
	slots[candidate.worker_id] = candidate
	local code_sessions, managers, transient = {}, {}, false
	for _, w in slots do
		local sid, p = w.logical_session_id, policy(d, w.logical_session_id)
		if w.role == "release_manager" and w.record_id == p.release_manager_record then managers[sid] = true end
		if w.role == "reviewer" and w.review_id ~= nil then transient = true end
		local handover = if w.handover_id then (d.rollovers or {})[w.handover_id] else nil
		if handover and slots[handover.predecessor_worker_id] and handover.predecessor_worker_id ~= w.worker_id then transient = true end
		local project = if w.orch_project_id then (d.projects or {})[w.orch_project_id] else nil
		local code = w.checkout ~= nil or w.base_ref ~= nil or (w.checks ~= nil and #w.checks > 0)
			or (w.files ~= nil and #w.files > 0) or (project ~= nil and project.repository ~= nil)
		if (w.role == nil or w.role == "builder") and code and not w.stopped and not w.finish and not w.release and not w.launch_refused
			and not (w.workflow and w.workflow.exit) then code_sessions[sid] = true end
	end
	for _, item in (d.landing or {}).items or {} do
		if not LANDING_TERMINAL[item.status] or config.deploy_pins_item(d, item) then code_sessions[item.logical_session_id] = true end
	end
	local future_managers = 0
	for sid in code_sessions do
		if policy(d, sid).merge_actor_mode == "selected_record" and not managers[sid] then future_managers += 1 end
	end
	local progress = if transient then 0 else 1
	local used = count(slots)
	if used + future_managers + progress <= protocol.MANAGED_GENERATION_BUDGET then return nil end
	return config.hold("waiting_for_agent_space", "Waiting for agent space in the shared " .. tostring(protocol.MANAGED_GENERATION_BUDGET)
		.. "-generation mailbox allocation domain: " .. tostring(used - 1) .. " tracked/reserved generations, "
		.. tostring(future_managers) .. " future selected release actor(s), and " .. tostring(progress)
		.. " transient review/rollover slot(s) protected. Finish and positively retire unused managed generations; DONE alone keeps the conversation open. Actual SPAWN byte/file or foreign-use limits may hold earlier; no work or uncertainty was discarded.")
end
function config.provision(d: any, w: any, origin: any, pane: string): (any?, any?)
	local space = config.agent_space(d, w)
	if space then return fail(space.code, space.message) end
	local handover = if w.handover_id then (d.rollovers or {})[w.handover_id] else nil
	local rollover_tab = w.presentation == "background" and handover ~= nil and handover.handover_token == w.handover_token
		and handover.work_id == w.work_id and handover.logical_session_id == w.logical_session_id
	if w.selected_record and w.selected_record.backend ~= "native-agent" and w.placement == "replace_if_alone"
		and w.presentation ~= "user_new_tab" and w.presentation ~= "coordinator_adjacent" and not rollover_tab then
		return fail("unsupported_placement", "This terminal record can be opened in a new tab, but background work cannot safely replace the controller. Select a tab or split record.")
	end
	local request = common(d, origin, pane, "mailbox_provision"); be(w, request)
	request.record_id = w.record_id; request.record_revision = w.record_revision; request.capability = "report-files-v1"
	if w.manifest_sha256 ~= nil then
		local bytes, problem = config.manifest(w)
		if not bytes or codec.sha256(bytes) ~= w.manifest_sha256 then
			return fail("manifest_mismatch", "The stored assignment fields no longer reproduce this work's manifest digest" .. (if problem then " (" .. problem.code .. ")" else "") .. "; nothing was provisioned.")
		end
		request.manifest = bytes
	end
	return request, nil
end
-- A first-generation queued worker on catalog `row` (id, revision, cwd, placement); `seed`
-- prefixes its enrolment token. The ids are drawn worker, work, launch, action.
function config.new_worker(d: any, event: any, sid: string, row: any, prompt: string, seed: string, role: string): any
	local worker_id, work_id = next_id(d, "worker-"), next_id(d, "work-")
	local project = config.project_ref(d, sid, event.orch_project_id)
	if not project then project = config.new_project(d, sid, if role == "coordinator" then "Orchestrator" else "Conversation", nil) end
	return { worker_id = worker_id, work_id = work_id, worker_generation = 1, logical_session_id = sid, orch_project_id = project.orch_project_id,
		origin_binding = clone(event.origin), controller_pane = event.controller_pane, record_id = row.id, record_revision = row.revision,
		prompt = prompt, cwd = row.cwd, placement = row.placement, assignment_sha256 = codec.sha256(prompt),
		execution_cwd = if project.repository then project.repository.cwd else nil, presentation = event.presentation or "background",
		launch_request_id = next_id(d, "launch-"), launch_action_id = next_id(d, "action-"),
		enrolment_token = codec.sha256(seed .. event.origin.alias_nonce .. ":" .. work_id), phase = "queued",
		accepted_seq = 0, compacted_floor = 0, receipts = {}, replies = {}, reply_seq = 0, reply_floor = 0, role = role }
end
-- Built-in review/merge instructions remain part of each builder/coordinator assignment.
function config.review_guidance(p: any): string
	return "ORCH+ review policy at assignment: require_code_review=" .. tostring(p.require_code_review)
		.. "; require_other_family=" .. tostring(p.require_other_family)
		.. ". Every declared check requires successful helper CHECK_RESULT at the submitted revision in every mode. "
		.. (if p.require_code_review then "Submit CHECKPOINT then REVIEW_READY for independent review before landing."
			else "Code review is disabled: submit CHECKPOINT then LANDING_REQUEST without waiting for a reviewer; do not propose review.")
		.. (if p.merge_actor_mode == "worker" then " The existing accepted builder is the merge/deploy actor; execute only its exact grants with real release-manager-v1 capability, never an ungranted merge."
			else " A separately selected release actor receives merge/deploy grants; the builder does not merge.")
		.. " The host rechecks current policy and all evidence before every grant. Role text is guidance, not permission isolation."
end
function config.assignment_prompt(d: any, sid: string, role: string, text: string): string
	return text .. (if role == "builder" or role == "coordinator" then "\n\n" .. config.review_guidance(policy(d, sid)) else "")
end
-- Provisions a release-manager, reviewer or labeller worker and records its assignment; a hold on failure.
function config.provision_role(d: any, w: any, noun: string, clock: any): any?
	if not config.worker_start_allowed(d, w) then return config.hold("project_held", "This project's START and an unpaused orchestration are required.") end
	if w.role ~= "release_manager" then
		local except = { [w.worker_id] = true }
		local review = if w.review_id then (d.reviews or {})[w.review_id] else nil
		if review then except[review.builder_worker_id] = true end
		local busy = config.concurrency_problem(d, w.logical_session_id, policy(d, w.logical_session_id), except)
		if busy then return busy end
	end
	if M.request_size(launch_request(w, string.rep("h", 96))) > codec.DISPATCH.limit then
		return config.hold("oversize", "The " .. noun .. " assignment plus its immutable launch binding exceeds the 8192-byte bridge. Nothing was provisioned.")
	end
	local request, problem = config.provision(d, w, w.origin_binding, w.controller_pane)
	if not request then return config.hold(problem.code, problem.message) end
	if not add(d, request, w.worker_id) then return config.hold("oversize", "The " .. noun .. " provision request exceeds the bridge bound; nothing was provisioned.") end
	d.workers[w.worker_id] = w
	local _, err = append(d, w, "assignment", w.prompt, clock); if err then return config.hold(err.code, err.message) end
	return nil
end
-- The closed 0.3.0 landing_grant reply (no builder/review/proof fields, no release-manager-v1
-- capability). Retained only as immutable evidence of an outstanding legacy grant (Contract B).
config.LEGACY_GRANT_KEYS = "landing_id grant_id project_id checkpoint_id repo_ref target_ref target_revision source_ref source_revision"
function config.legacy_grant(bytes: any, w: any): any?
	local raw = codec.strict_decode(bytes)
	if type(raw) ~= "table" or raw.version ~= 1 or raw.kind ~= "landing_grant" or type(raw.payload) ~= "table"
		or not closed(raw, "version logical_session_id worker_id worker_generation launch_request_id work_id message_id reply_seq action_id action_revision kind payload")
		or not closed(raw.payload, config.LEGACY_GRANT_KEYS) or not id(raw.message_id) or not pos(raw.reply_seq) or not id(raw.action_id) or not pos(raw.action_revision) then return nil end
	for _, k in B do if raw[k] ~= w[k] then return nil end end
	for k in config.LEGACY_GRANT_KEYS:gmatch("%S+") do if not wire_text(raw.payload[k], 1024) then return nil end end
	return raw
end
-- Contract B fail-closed 0.3.0 → 0.4.0 landing upgrade (restore only, no clock). Legacy grant bytes
-- are marked `legacy` and kept as evidence; a granted/landing item whose current grant is legacy
-- becomes an uncertain hold `legacy_grant_outstanding` (only Result lost / Reconcile settle it; a
-- builder LANDING_RESULT is refused, the grant is never re-addressed) with one owner gate. Contract I:
-- the legacy grant's holder is the builder generation it was addressed to, so that generation (not
-- a release manager) stays pinned and bound to the uncertain grant.
-- Approved-but-ungranted items keep their approval and re-verify under Rule H (review_required).
function config.legacy_upgrade(d: any)
	for _, w in d.workers do
		for _, reply in w.replies do
			if not reply.legacy and codec.decode_reply(reply.bytes, w) == nil and config.legacy_grant(reply.bytes, w) then reply.legacy = true end
		end
	end
	for _, item in (d.landing or {}).items or {} do
		item.verification = nil
		for _, g in item.grants do
			local w = d.workers[g.worker_id]
			if not g.legacy and w and codec.decode_reply(g.bytes, w) == nil and config.legacy_grant(g.bytes, w) then g.legacy = true end
		end
		local current, w = item.grants[#item.grants], d.workers[item.worker_id]
		local addressed = if current then d.workers[current.worker_id] else nil
		if item.holder == nil and addressed then item.holder = { worker_id = addressed.worker_id, worker_generation = addressed.worker_generation } end
		if current and current.legacy and (item.status == "granted" or item.status == "landing")
			and not (current.uncertain and current.uncertain.code == "legacy_grant_outstanding") then
			local message = "Landing grant " .. current.grant_id .. " was issued to the builder by ORCH+ 0.3.0. 0.4.0 never re-addresses it and accepts no builder LANDING_RESULT for it; use Result lost — hold slot… or Reconcile observed outcome… on this landing item."
			current.uncertain = { code = "legacy_grant_outstanding", at_ms = 0, message = message }
			item.hold = { code = "legacy_grant_outstanding", message = message }; item.revision += 1
			d.gates = d.gates or {}
			if w and count(d.gates) < 64 then
				local g = { id = next_id(d, "gate-"), revision = 1, work_id = w.work_id, worker_id = w.worker_id, worker_generation = w.worker_generation,
					logical_session_id = w.logical_session_id, pane_binding = clone(w.pane_binding), kind = "legacy_grant_outstanding", phase = "pending",
					question = message, options = { { id = "acknowledge", label = "Understood — settle it with Result lost or Reconcile" } },
					evidence = { "landing:" .. item.id, "grant:" .. current.grant_id }, at_ms = 0 }
				d.gates[g.id] = g
			end
		end
	end
end
-- A legacy_grant_outstanding gate stays open only while its item's legacy grant is unreconciled.
function config.legacy_sweep(d: any)
	for _, g in d.gates or {} do
		if g.kind == "legacy_grant_outstanding" and g.phase == "pending" then
			local item = ((d.landing or {}).items or {})[tostring(g.evidence[1] or ""):match("^landing:(.+)$") or ""]
			local current = if item then item.grants[#item.grants] else nil
			if not current or not current.legacy or current.reconciliation ~= nil or (item.status ~= "granted" and item.status ~= "landing") then
				g.phase = "superseded"; g.revision += 1
			end
		end
	end
end
-- A delivery record and its decoded immutable reply of `kind`: same message, sequence and action.
local function valid_delivery(r: any, w: any, reply: any, kind: string): boolean
	if not reply or reply.kind ~= kind or reply.message_id ~= r.message_id or reply.reply_seq ~= r.reply_seq or reply.action_id ~= r.action_id
		or reply.action_revision ~= r.action_revision or r.reply_seq > w.reply_seq then return false end
	if r.acknowledged then
		if not pos(r.ack_seq) or r.ack_seq > w.accepted_seq or not digest(r.ack_sha256) then return false end
		local receipt = w.receipts[tostring(r.ack_seq)]
		if r.ack_seq > w.compacted_floor and (not receipt or receipt.kind ~= "reply_ack" or receipt.sha256 ~= r.ack_sha256) then return false end
	else
		if r.ack_seq ~= nil or r.ack_sha256 ~= nil then return false end
		local retained = w.replies[tostring(r.reply_seq)]
		if not retained or retained.bytes ~= r.bytes then return false end
	end
	return true
end
local function valid_flow(d: any, w: any, registry: any, legacy: boolean?): boolean
	local f = w.workflow
	if f == nil then return legacy == true end
	if not closed(f, "thread evidence checkpoints native report last_poll health due_poll due_report report_request observation_cursor started exit context context_basis rollover_due_seq boundary_seq empty_read report_loop")
		or not dense(f.thread, 128) or type(f.evidence) ~= "table" or f.evidence == tern.json.null or count(f.evidence) > 16
		or type(f.checkpoints) ~= "table" or f.checkpoints == tern.json.null or count(f.checkpoints) > 16 or type(f.due_poll) ~= "boolean" or type(f.due_report) ~= "boolean" then return false end
	if f.report_loop ~= nil and not loops.valid(f.report_loop) then return false end
	if f.started ~= nil and (not closed(f.started, "at_ms mono_ms epoch") or not valid_stamp(f.started)) then return false end
	if f.exit ~= nil and (not closed(f.exit, "at_ms mono_ms epoch state") or not valid_stamp(f.exit)
		or f.exit.state ~= "exited" or (f.exit.epoch == nil and not w.stopped)) then return false end
	if f.context ~= nil and (not config.valid_context(f.context) or f.context.seq > w.accepted_seq) then return false end
	if f.context_basis ~= nil then
		local b = f.context_basis
		if not closed(b, "window_tokens first_turn_tokens") or not pos(b.window_tokens)
			or (b.first_turn_tokens ~= nil and (type(b.first_turn_tokens) ~= "number" or b.first_turn_tokens < 0
				or b.first_turn_tokens > b.window_tokens or b.first_turn_tokens % 1 ~= 0)) then return false end
		if f.context and f.context.snapshot and f.context.status == "measured" then
			local s = f.context.snapshot
			if s.window_tokens ~= b.window_tokens or (s.first_turn_tokens ~= nil and s.first_turn_tokens ~= b.first_turn_tokens) then return false end
		end
	end
	if f.rollover_due_seq ~= nil and (not pos(f.rollover_due_seq) or f.rollover_due_seq > w.accepted_seq) then return false end
	if f.boundary_seq ~= nil and (not pos(f.boundary_seq) or f.boundary_seq > w.accepted_seq) then return false end
	-- The poll that issued this generation's last report read of `slot` that found nothing (see poll_idle).
	if f.empty_read ~= nil and (not closed(f.empty_read, "at_ms mono_ms epoch slot") or not valid_stamp(f.empty_read) or not id(f.empty_read.epoch)
		or not pos(f.empty_read.slot) or f.empty_read.slot > w.accepted_seq + 1) then return false end
	if f.observation_cursor then
		local cursor = f.observation_cursor
		if not closed(cursor, "seq event") then return false end
		local e = cursor.event
		if not pos(cursor.seq)
			or not closed(e, if legacy == true
				then "kind request_id orch_session_id origin controller_pane command command_seq worker_id pane_binding native_state delivery_error observation_seq"
				else "kind request_id orch_session_id origin controller_pane command command_seq worker_id pane_binding native_state delivery_error observation_seq authority_namespace expected_revision")
			or (legacy ~= true and (e.authority_namespace ~= registry.authority_namespace or not (e.expected_revision == 0 or pos(e.expected_revision))
				or e.expected_revision >= registry.revision))
			or e.kind ~= "dispatch" or e.command ~= "observe" or not id(e.request_id) or e.observation_seq ~= cursor.seq or e.worker_id ~= w.worker_id
			or e.orch_session_id ~= w.logical_session_id or not equal(e.origin, control_origin(w)) or not equal(e.pane_binding, control_binding(w))
			or not str(e.controller_pane, 96) or not table.find({ "working", "idle", "waiting-input", "exited", "unknown" }, e.native_state)
			or (e.delivery_error ~= nil and not str(e.delivery_error, 1024)) then return false end
		local commands = (d.command_cursors or {})[w.logical_session_id]
		if e.command_seq ~= nil and (not pos(e.command_seq) or not commands or e.command_seq > commands.seq) then return false end
	end
	for _, entry in f.thread do
		if not closed(entry, "id kind summary at_ms state gate_id action_id request_id event_id report_bytes") or not id(entry.id) or not str(entry.kind, 96)
			or not wire_text(entry.summary, 32768) or not (entry.at_ms == 0 or pos(entry.at_ms))
			or (entry.state ~= "pending" and not (legacy and entry.state == "settled")) then return false end
		for _, key in { "gate_id", "action_id", "request_id", "event_id" } do if entry[key] ~= nil and not id(entry[key]) then return false end end
		if entry.gate_id and not (d.gates or {})[entry.gate_id] then return false end
		if entry.report_bytes then
			local report = codec.decode_report(entry.report_bytes, w)
			if not report or report.event_id ~= entry.event_id or report.seq > w.accepted_seq then return false end
		end
	end
	for _, name in { "native", "report", "last_poll" } do
		local v = f[name]
		if v and (not closed(v, "at_ms mono_ms epoch state kind event_id delivery_error") or not valid_stamp(v)) then return false end
		if v and name ~= "last_poll" and not str(v.state, 32) then return false end
		if v and v.delivery_error ~= nil and (name ~= "native" or not str(v.delivery_error, 1024)) then return false end
		if v and name == "native" and not table.find({ "working", "idle", "waiting-input", "exited", "unknown" }, v.state) then return false end
		if v and name == "report" and (not table.find(REPORT_KINDS, v.kind) or not id(v.event_id)
			or not table.find({ "working", "idle", "waiting", "blocked", "done" }, v.state)) then return false end
	end
	for _, collection in { f.evidence, f.checkpoints } do
		for key, bytes in collection do
			local report = codec.decode_report(bytes, w)
			if not id(key) or not report or report.seq > w.accepted_seq then return false end
			if collection == f.checkpoints and (report.kind ~= "CHECKPOINT" or report.payload.checkpoint_id ~= key) then return false end
			if collection == f.evidence and report.kind ~= key then return false end
		end
	end
	if f.report then
		local latest = f.report
		if latest.kind == "ACCEPTED" then
			if not w.accepted_event or latest.event_id ~= w.accepted_event.event_id or latest.state ~= "working" then return false end
		else
			local report = codec.decode_report(f.evidence[latest.kind], w)
			if not report or report.event_id ~= latest.event_id then return false end
			local expected = if report.kind == "READY" then "idle" elseif report.kind == "HEARTBEAT" then report.payload.state
				elseif report.kind == "WAITING" or report.kind == "ASK" then "waiting" elseif report.kind == "BLOCKED" then "blocked"
				elseif report.kind == "DONE" then "done" else latest.state
			if latest.state ~= expected then return false end
		end
	end
	local r = f.report_request
	if r then
		if not closed(r, "request_id message_id reply_seq action_id action_revision acknowledged published response_received bytes ack_seq ack_sha256 response_bytes")
			or not id(r.request_id) or type(r.acknowledged) ~= "boolean" or type(r.published) ~= "boolean" or type(r.response_received) ~= "boolean" then return false end
		local reply = codec.decode_reply(r.bytes, w)
		if not valid_delivery(r, w, reply, "report_request") or reply.payload.request_id ~= r.request_id then return false end
		if r.response_received then
			local response = codec.decode_report(r.response_bytes, w)
			if not response or response.seq > w.accepted_seq or response.payload.request_id ~= r.request_id
				or not table.find({ "HEARTBEAT", "CHECKPOINT" }, response.kind) then return false end
		end
	end
	-- Derived health is recomputed on every restore/tick; persisted facts above remain authoritative.
	if f.health ~= nil then
		local h = f.health
		if not closed(h, "status reason native_state reported_state latest_native latest_report latest_exit gate_id freshness awaiting_window")
			or not table.find({ "exited", "owner_gate", "blocked", "waiting_input", "stale_report", "working", "idle", "unknown" }, h.status)
			or not wire_text(h.reason, 32768) or not str(h.native_state, 32) or not str(h.reported_state, 32)
			or not equal(h.latest_native, f.native) or not equal(h.latest_report, f.report) or not equal(h.latest_exit, f.exit)
			or not table.find({ "fresh", "stale", "unconfirmed" }, h.freshness) or type(h.awaiting_window) ~= "boolean"
			or (h.gate_id ~= nil and not (d.gates or {})[h.gate_id]) then return false end
	end
	return true
end
-- Nightly orphan mailbox sweep: one durable run per session and scheduled local day, a bounded
-- ring of the latest runs, and one owner-auditable decision per mailbox-bearing worker.
local SWEEP_RUNS = 14
local SWEEP_DECISIONS = 64
local SWEEP_REASONS = { "retired", "stopped_settled", "compaction_pending", "continuation_required", "uncertain", "retirement_pending",
	"effect_pending", "owner_unresolved", "report_held", "held", "unlaunched", "live", "finishing", "unsettled", "referenced", "oversize" }
local function sweep_date(v: any): boolean
	if type(v) ~= "string" or #v ~= 10 then return false end
	local year, month, day = v:match("^(%d%d%d%d)%-(%d%d)%-(%d%d)$")
	return year ~= nil and (tonumber(month) or 0) >= 1 and (tonumber(month) or 13) <= 12 and (tonumber(day) or 0) >= 1 and (tonumber(day) or 32) <= 31
end
local function count_or_zero(v: any): boolean return v == 0 or pos(v) end
local function valid_sweeps(d: any, registry: any): boolean
	if d.sweeps == nil then return true end
	if type(d.sweeps) ~= "table" or d.sweeps == tern.json.null or count(d.sweeps) > 64 then return false end
	for sid, log in d.sweeps do
		if not registry.sessions[sid] or not closed(log, "last_date runs") or not sweep_date(log.last_date) or not dense(log.runs, SWEEP_RUNS) or #log.runs == 0 then return false end
		for index, run in log.runs do
			if not closed(run, "local_date revision at_ms catch_up decisions more retire compact keep none") or not sweep_date(run.local_date)
				or not pos(run.revision) or run.revision > registry.revision or not (run.at_ms == 0 or pos(run.at_ms)) or type(run.catch_up) ~= "boolean"
				or not dense(run.decisions, SWEEP_DECISIONS) or not count_or_zero(run.more) or not count_or_zero(run.retire)
				or not count_or_zero(run.compact) or not count_or_zero(run.keep) or not count_or_zero(run.none)
				or (index > 1 and log.runs[index - 1].local_date >= run.local_date) then return false end
			for _, decision in run.decisions do
				if not closed(decision, "worker_id work_id decision reason action_id") or not id(decision.worker_id) or not id(decision.work_id)
					or not table.find({ "retire", "compact", "keep", "none" }, decision.decision) or not table.find(SWEEP_REASONS, decision.reason)
					or (decision.action_id ~= nil and not id(decision.action_id)) or ((decision.action_id ~= nil) ~= (decision.decision == "retire" or decision.decision == "compact")) then return false end
			end
		end
		if log.runs[#log.runs].local_date ~= log.last_date then return false end
	end
	return true
end
local function valid_workflow(d: any, registry: any, legacy: boolean?): boolean
	if d.policies ~= nil then
		if type(d.policies) ~= "table" or count(d.policies) > 64 then return false end
		for sid, p in d.policies do if not registry.sessions[sid] or not valid_policy(p, legacy or registry.version == 4 or M.upgradable_policy(p) or M.previous_policy(p)) then return false end end
	end
	if d.gates == nil then return true end
	if type(d.gates) ~= "table" or count(d.gates) > 64 then return false end
	for key, g in d.gates do
		if not closed(g, "id revision work_id worker_id worker_generation logical_session_id pane_binding kind phase question options evidence proposal at_ms answer delivery delivery_uncertain recheck result execution ruling ruling_delivery")
			or not id(key) or g.id ~= key or not pos(g.revision) or not wire_text(g.question, 32768) or not (g.at_ms == 0 or pos(g.at_ms))
			or not table.find(loops.GATE_KINDS, g.kind)
			or not table.find({ "pending", "answered", "delivery_pending", "delivered", "acknowledged", "cancelled", "superseded", "resolved" }, g.phase)
			or not dense(g.options, 16, 1) or not dense(g.evidence, 256) then return false end
		local w = d.workers[g.worker_id]
		-- A settled prelaunch decision can retain its document obligation after its
		-- never-provisioned gate is released. Preserve that original nil pane binding;
		-- only the subsequent exact launch outcome binds the worker's first native pane.
		local prelaunch_ruling = g.pane_binding == nil and type(g.ruling) == "table" and g.ruling.work_id == g.work_id and g.phase == "resolved"
			and (g.kind == "shared_checkout" or g.kind == "file_overlap")
			and type(g.answer) == "table" and g.answer.choice_id == "launch_anyway" and g.delivery == nil
			and type(g.answer.source) == "table" and g.answer.source.kind == "owner"
			and g.delivery_uncertain ~= true and g.execution == nil
		if not w or g.worker_generation ~= w.worker_generation or g.work_id ~= w.work_id or g.logical_session_id ~= w.logical_session_id
			or (not equal(g.pane_binding, w.pane_binding) and not prelaunch_ruling) then return false end
		if g.ruling and (not rulings.valid(g.ruling) or g.ruling.gate_id ~= key or g.ruling.logical_session_id ~= g.logical_session_id
			or g.ruling.gate_revision > g.revision or g.ruling.marker ~= "orchplus-ruling:" .. registry.authority_namespace .. ":" .. key) then return false end
		if g.ruling_delivery then
			if not closed(g.ruling_delivery, "worker_id reply_seq action_id") then return false end
			local writer = d.workers[g.ruling_delivery.worker_id]
			local intent = if g.ruling then g.ruling.intent else nil
			if not writer or not intent
				or intent.writer.kind ~= "worker" or intent.writer.worker_id ~= writer.worker_id
				or intent.writer.worker_generation ~= writer.worker_generation
				or not pos(g.ruling_delivery.reply_seq) or not id(g.ruling_delivery.action_id) then return false end
		end
		local seen = {}
		for _, option in g.options do if not closed(option, "id label") or not id(option.id) or not wire_text(option.label, 1024) or seen[option.id] then return false end; seen[option.id] = true end
		for _, evidence in g.evidence do if not wire_text(evidence, 1024) then return false end end
		if g.answer and (not closed(g.answer, "choice_id answer source at_ms") or not seen[g.answer.choice_id] or not str(g.answer.answer, 32768)
			or not config.valid_source(g.answer.source, g, w, legacy) or not (g.answer.at_ms == 0 or pos(g.answer.at_ms))) then return false end
		if g.execution ~= nil then
			local e = g.execution
			local proposal = if g.proposal then codec.decode_report(g.proposal, w) else nil
			if not closed(e, "state gate_revision effect_ref at_ms") or not table.find({ "pending", "done", "refused" }, e.state) or not pos(e.gate_revision)
				or e.gate_revision > g.revision or not wire_text(e.effect_ref, 1024) or not (e.at_ms == 0 or pos(e.at_ms))
				or not g.answer or g.answer.choice_id ~= "approve" or not proposal or proposal.payload.kind == "rollover" then return false end
		end
		if g.delivery then
			local r = g.delivery
			if not closed(r, "message_id reply_seq action_id action_revision acknowledged published bytes ack_seq ack_sha256") or type(r.acknowledged) ~= "boolean" or type(r.published) ~= "boolean" then return false end
			local reply = codec.decode_reply(r.bytes, w)
			if not g.answer or not valid_delivery(r, w, reply, "owner_decision") or reply.gate_id ~= key or reply.gate_revision > g.revision
				or reply.payload.choice_id ~= g.answer.choice_id or reply.payload.answer ~= g.answer.answer then return false end
		end
		if g.phase == "pending" and (g.answer or g.delivery) then return false end
		-- Quota fallback, loop-cap and stale-claim decisions are consumed by the host reducer, never delivered to a worker.
		if loops.HOST_GATES[g.kind] and (g.delivery or g.proposal or g.result or g.phase == "answered" or (g.phase == "resolved") ~= (g.answer ~= nil)) then return false end
		if g.phase == "resolved" and not loops.HOST_GATES[g.kind] then return false end
		if table.find({ "answered", "delivery_pending", "delivered", "acknowledged" }, g.phase) and not g.answer then return false end
		if table.find({ "delivery_pending", "delivered", "acknowledged" }, g.phase) and not g.delivery then return false end
		if g.phase == "acknowledged" and not g.delivery.acknowledged then return false end
		if g.phase == "delivered" and not g.delivery.published then return false end
		if (g.kind == "coordinator_proposal") ~= (g.proposal ~= nil) then return false end
		if g.delivery_uncertain ~= nil and type(g.delivery_uncertain) ~= "boolean" then return false end
		if g.recheck ~= nil and not valid_stamp(g.recheck) then return false end
		if g.proposal ~= nil then
			local proposal = codec.decode_report(g.proposal, w)
			if not proposal or proposal.kind ~= "COORDINATOR_PROPOSAL" or proposal.seq > w.accepted_seq then return false end
			if not w.activation or proposal.payload.owner_id ~= w.coordinator_owner_id or proposal.payload.owner_generation ~= w.coordinator_generation
				or proposal.payload.activation_token ~= w.activation.activation_token then return false end
		end
		-- A legacy coordinator review result is admitted only at the restore boundary, which drops it (M.restore).
		if g.result ~= nil and (not legacy or type(g.result) ~= "string" or g.kind ~= "coordinator_proposal") then return false end
	end
	return true
end
local function pane_shape(v: any): boolean
	return closed(v, "pane_id window_epoch window_key native_session_id window_host_id") and str(v.pane_id, 96) and v.pane_id:match("^%d+$") ~= nil
		and id(v.window_epoch) and str(v.window_key, 256, true) and str(v.native_session_id, 256) and str(v.window_host_id, 256)
end
local ROLLOVER_KEYS = "id kind phase trigger logical_session_id work_id predecessor_worker_id predecessor_pane_binding origin controller_pane controller_generation handover_token request_id checkpoint verification successor_worker_id successor_pane_binding stop_observation hold revision at_ms context predecessor_owner_id predecessor_generation successor_owner_id successor_generation closure quota checkpoint_loop prepared prepare_count"
local function valid_rollovers(d: any, registry: any, legacy: boolean?): boolean
	if d.rollovers == nil then return true end
	if count(d.rollovers) > 32 then return false end
	local active, coordinators = {}, {}
	for key, r in d.rollovers do
		local coordinator_kind = type(r) == "table" and r.kind == "coordinator"
		local phases = if coordinator_kind then COORDINATOR_ROLLOVER_PHASES else ROLLOVER_PHASES
		local index = if type(r) == "table" then table.find(phases, r.phase) else nil
		if not closed(r, ROLLOVER_KEYS .. (if legacy then " history" else "")) or not id(key) or r.id ~= key or (r.kind ~= "worker" and r.kind ~= "coordinator") or (index == nil and r.phase ~= "cancelled")
			or (r.trigger ~= "owner" and r.trigger ~= "policy") or not registry.sessions[r.logical_session_id] or not id(r.work_id)
			or not id(r.predecessor_worker_id) or not pane_shape(r.predecessor_pane_binding) or not M.origin(r.origin)
			or r.origin.logical_session_id ~= r.logical_session_id or r.controller_generation ~= r.origin.owner_generation
			or not str(r.controller_pane, 96) or r.controller_pane:match("^%d+$") == nil or not digest(r.handover_token) then return false end
		if legacy then
			if not dense(r.history, 100) or #r.history == 0 then return false end
			local prior = 0
			for _, edge in r.history do
				if not closed(edge, "phase revision at_ms") or (not table.find(phases, edge.phase) and edge.phase ~= "cancelled")
					or not pos(edge.revision) or edge.revision < prior or edge.revision > registry.revision
					or not (edge.at_ms == 0 or pos(edge.at_ms)) then return false end
				prior = edge.revision
			end
			if r.history[#r.history].phase ~= r.phase then return false end
		elseif not pos(r.revision) or r.revision > registry.revision or not (r.at_ms == 0 or pos(r.at_ms)) then return false end
		if r.checkpoint_loop ~= nil and not loops.valid(r.checkpoint_loop) then return false end
		if r.prepare_count ~= nil and (not pos(r.prepare_count) or r.prepare_count > 100) then return false end
		if r.prepared ~= nil then
			local p = r.prepared
			if not closed(p, "worker action") or type(p.worker) ~= "table" or not closed(p.action, "request phase worker_id")
				or p.worker.logical_session_id ~= r.logical_session_id or p.worker.handover_id ~= key
				or p.worker.handover_token ~= r.handover_token or p.action.worker_id ~= p.worker.worker_id
				or (p.action.phase ~= "ready" and p.action.phase ~= "held_ready") or p.worker.phase ~= "queued"
				or p.worker.mailbox_handle ~= nil or p.worker.pane_binding ~= nil or p.worker.coordinator_owner_id ~= nil
				or p.worker.accepted_seq ~= 0 or p.worker.reply_seq ~= 0
				or not config.valid_worker(d, p.worker, p.worker.worker_id, registry, false, 0, 0)
				or not valid_request(p.action.request, p.worker, { actions = {} }) then return false end
		end
		if r.hold ~= nil and (not closed(r.hold, "code message") or not str(r.hold.code, 96) or not wire_text(r.hold.message, 1024)) then return false end
		if r.request_id ~= nil and not id(r.request_id) then return false end
		if r.successor_worker_id ~= nil and not id(r.successor_worker_id) then return false end
		if r.successor_pane_binding ~= nil and not pane_shape(r.successor_pane_binding) then return false end
		if r.stop_observation ~= nil and r.stop_observation ~= "absent" and r.stop_observation ~= "exited" then return false end
		if r.checkpoint ~= nil and not wire_text(r.checkpoint, 65536) then return false end
		if r.verification ~= nil and (not closed(r.verification, "attestation checkpoint_id artifact_revision")
			or r.verification.attestation ~= "worker-attested" or not id(r.verification.checkpoint_id) or not wire_text(r.verification.artifact_revision, 1024)) then return false end
		if r.context ~= nil and not config.valid_context(r.context) then return false end
		if coordinator_kind then
			if not id(r.predecessor_owner_id) or not pos(r.predecessor_generation) or (r.successor_owner_id == nil) ~= (r.successor_generation == nil)
				or (r.successor_owner_id ~= nil and (not id(r.successor_owner_id) or not pos(r.successor_generation)))
				or (r.closure ~= nil and r.closure ~= "observed" and r.closure ~= "operator_attested")
				or (r.closure == "observed") ~= (r.stop_observation ~= nil) then return false end
		elseif r.predecessor_owner_id ~= nil or r.predecessor_generation ~= nil or r.successor_owner_id ~= nil or r.successor_generation ~= nil or r.closure ~= nil then
			return false
		end
		-- Each durable phase carries exactly the evidence its edge required.
		if index and not coordinator_kind then
			if (index >= 2) ~= (r.request_id ~= nil) or (index >= 3) ~= (r.checkpoint ~= nil) or (index >= 3) ~= (r.verification ~= nil)
				or (index >= 4) ~= (r.successor_worker_id ~= nil) or (index >= 5) ~= (r.successor_pane_binding ~= nil)
				or (index >= 8) ~= (r.stop_observation ~= nil) then return false end
		elseif index then
			if (index >= 2) ~= (r.request_id ~= nil) or (index >= 3) ~= (r.checkpoint ~= nil) or (index >= 3) ~= (r.verification ~= nil)
				or (index >= 7) ~= (r.closure ~= nil) or (index == 7 and r.closure ~= "observed")
				or (index >= 9) ~= (r.successor_worker_id ~= nil) or (index >= 9) ~= (r.successor_owner_id ~= nil)
				or (index >= 10) ~= (r.successor_pane_binding ~= nil) then return false end
			if index >= 8 then
				local session = registry.sessions[r.logical_session_id]
				local old = if legacy then (registry.retired or {})[r.predecessor_owner_id] else nil
				if (if legacy then not old or old.orch_session_id ~= r.logical_session_id or old.generation ~= r.predecessor_generation or old.target ~= "orchestrator"
					else session.orchestrator_generation <= r.predecessor_generation)
					or (session.orchestrator and session.orchestrator.owner_id == r.predecessor_owner_id) then return false end
			end
		end
		local terminal = ROLLOVER_TERMINAL[r.phase] == true
		local pred = d.workers[r.predecessor_worker_id]
		local succ = if r.successor_worker_id then d.workers[r.successor_worker_id] else nil
		if not terminal then
			if not pred or (r.successor_worker_id and not succ) or active[r.predecessor_worker_id] then return false end
			active[r.predecessor_worker_id] = true
			if coordinator_kind then
				if coordinators[r.logical_session_id] then return false end
				coordinators[r.logical_session_id] = true
				if (index or 0) >= 4 and not (pred.retirement or pred.release) then return false end
				if (index or 0) >= 5 and r.closure ~= "operator_attested" and not pred.release then return false end
			elseif (index or 0) >= 7 and (not pred.finish or pred.finish.request_id ~= key) then return false end
		end
		if pred and (pred.work_id ~= r.work_id or pred.logical_session_id ~= r.logical_session_id) then return false end
		if pred and (if coordinator_kind then pred.coordinator_owner_id ~= r.predecessor_owner_id or pred.coordinator_generation ~= r.predecessor_generation
			else pred.coordinator_owner_id ~= nil) then return false end
		if pred and r.checkpoint then
			local cp = codec.decode_report(r.checkpoint, pred)
			if not cp or cp.kind ~= "CHECKPOINT" or cp.payload.request_id ~= r.request_id or cp.seq > pred.accepted_seq
				or cp.payload.checkpoint_id ~= r.verification.checkpoint_id or cp.payload.artifact_revision ~= r.verification.artifact_revision then return false end
		end
		if succ and (succ.handover_id ~= key or succ.handover_token ~= r.handover_token or succ.work_id ~= r.work_id
			or succ.logical_session_id ~= r.logical_session_id or (r.successor_pane_binding and not equal(succ.pane_binding, r.successor_pane_binding))
			or (if coordinator_kind then succ.coordinator_owner_id ~= r.successor_owner_id or succ.coordinator_generation ~= r.successor_generation
				else succ.coordinator_owner_id ~= nil)) then return false end
	end
	return true
end
function config.repository_target(value: string): string
	return if value:sub(1, 5) == "refs/" then value else "refs/heads/" .. value
end
function config.repository_policy_key(common_dir: string, target: string): string
	return codec.sha256(codec.dispatch_source_bytes({ common_dir = rules.normalize_path(common_dir), target_ref = config.repository_target(target) }))
end
function config.repository_key(host: string, common_dir: string, target: string): string
	return codec.sha256(codec.dispatch_source_bytes({ host_key = host, common_dir = rules.normalize_path(common_dir), target_ref = config.repository_target(target) }))
end
function config.repository_choice(repository: any): any
	return { common_dir = rules.normalize_path(repository.common_dir), target_ref = config.repository_target(repository.target_ref), queue_route = repository.queue_route }
end
function config.valid_repository_choice(value: any): boolean
	return closed(value, "common_dir target_ref queue_route") and rulings.absolute(value.common_dir)
		and value.common_dir == rules.normalize_path(value.common_dir) and str(value.target_ref, 1024)
		and value.target_ref:sub(1, 5) == "refs/" and (value.queue_route == "orch_queue" or value.queue_route == "repository_queue")
end
function config.valid_repository_identity(value: any): boolean
	if not closed(value, "key host_key common_dir target_ref queue_route") or not str(value.host_key, 256) then return false end
	return config.valid_repository_choice({ common_dir = value.common_dir, target_ref = value.target_ref, queue_route = value.queue_route })
		and value.key == config.repository_key(value.host_key, value.common_dir, value.target_ref)
end
function config.repository_policy(n: any, common_dir: string, target: string): any?
	local key = config.repository_policy_key(common_dir, target)
	local saved = ((n.dispatch or {}).repository_policies or {})[key]
	if saved then return saved end
	return nil
end
-- Called only by the existing host-verified, revision-fenced settings transaction.
-- Choices are current configuration, not a history of completed landing outcomes.
function M.set_repository_policy(n: any, repository: any): any?
	if repository == nil then return nil end
	local choice = config.repository_choice(repository)
	local key = config.repository_policy_key(choice.common_dir, choice.target_ref)
	local previous = config.repository_policy(n, choice.common_dir, choice.target_ref)
	if previous and previous.queue_route ~= choice.queue_route then
		for _, q in ((n.dispatch or {}).landing or {}).queues or {} do
			if #q.order > 0 and (q.repository == nil or config.repository_policy_key(q.repository.common_dir, q.repository.target_ref) == key) then
				return { ok = false, code = "repository_busy", message = "Settle or cancel this repository/target's outstanding landing requests before changing its queue route. Existing grants and approvals were not changed." }
			end
		end
	end
	local d = table.clone(n.dispatch or fresh())
	d.repository_policies = table.clone(d.repository_policies or {})
	d.repository_policies[key] = choice
	n.dispatch = d
	return nil
end
function config.repository_identity(n: any, w: any, request: any): (any?, any?)
	local checkout, catalog = w.checkout, n.dispatch.catalogs[w.logical_session_id]
	if not checkout or not checkout.event_id or not checkout.seq or not catalog or not str(catalog.host_key, 256)
		or checkout.host_key ~= catalog.host_key then
		return fail("repository_unverified", "Publish a fresh helper CHECKOUT and refresh the native SPAWN catalog before requesting landing; repository labels and cwd are not identity.")
	end
	if checkout.head ~= request.source_revision then
		return fail("checkout_stale", "The helper CHECKOUT names another source revision; publish current checkout evidence before requesting landing.")
	end
	local project = config.project_ref(n.dispatch, w.logical_session_id, w.orch_project_id)
	local repository = if project then project.repository else nil
	if not repository or rules.normalize_path(repository.common_dir) ~= rules.normalize_path(checkout.common_dir)
		or config.repository_target(repository.target_ref) ~= config.repository_target(request.target_ref) then
		return fail("repository_route_required", "Associate this project's verified checkout and target before requesting landing. Another project's repository policy is never a fallback.")
	end
	local choice = config.repository_policy(n, checkout.common_dir, request.target_ref)
	if not choice or choice.queue_route ~= repository.queue_route then
		return fail("repository_route_required", "Review this project's canonical repository queue route; the retained route and current repository policy differ.")
	end
	return { key = config.repository_key(catalog.host_key, checkout.common_dir, request.target_ref), host_key = catalog.host_key,
		common_dir = rules.normalize_path(checkout.common_dir), target_ref = config.repository_target(request.target_ref), queue_route = choice.queue_route }, nil
end
-- These records partition display and owner controls. They are not independent locks:
-- the scheduler derives one canonical repository/target FIFO across all such partitions.
-- A pre-cutover partition without verified identity is retained only to settle old obligations.
local function landing_queue_id(session_id: string, p: any, repository: any?): string
	local parts = {}
	for _, value in { session_id, p.project_id, p.repo_ref, p.target_ref } do table.insert(parts, string.format("%d:%s", #value, value)) end
	if repository then table.insert(parts, repository.key .. ":" .. repository.queue_route) end
	return "landing-queue-" .. codec.sha256(table.concat(parts)):sub(1, 40)
end
-- `verification` is the 0.3.0 worker-attested record: admitted only at the restore boundary, where
-- M.restore drops it (Rule H `proof` is recomputed every commit). A grant or retained reply marked
-- `legacy` carries 0.3.0 landing_grant bytes (Contract B upgrade): kept as immutable evidence only.
local LANDING_ITEM_KEYS = "id revision queue_id logical_session_id work_id worker_id holder status at_ms request gate_id approval proof verification hold refresh_required refresh grants history refresh_loop grant_loop deploy_due deploy_id"
local LANDING_GRANT_KEYS = "grant_id worker_id action_id action_revision reply_seq message_id bytes target_revision source_revision checkpoint_id controller_generation revision published acknowledged ack_seq ack_sha256 result late_result uncertain reconciliation legacy"
local function landing_text(v: any): boolean return wire_text(v, 1024) end
local function valid_landing_result(v: any): boolean
	if not closed(v, "outcome result_revision observed_target_revision reason pr_ref summary evidence event_id seq at_ms")
		or not table.find({ "landed", "rejected", "stale_target", "uncertain" }, v.outcome) or not dense(v.evidence, 8) or not id(v.event_id)
		or not pos(v.seq) or not (v.at_ms == 0 or pos(v.at_ms)) then return false end
	for _, key in { "result_revision", "observed_target_revision", "reason", "pr_ref", "summary" } do
		if v[key] ~= nil and not landing_text(v[key]) then return false end
	end
	for _, entry in v.evidence do if not landing_text(entry) then return false end end
	return (v.outcome == "landed") == (v.result_revision ~= nil) and (v.outcome == "stale_target") == (v.observed_target_revision ~= nil)
end
-- A released grant left its slot without landing: an applied stale_target result, or owner
-- reconciliation that observed nothing landed.
local function landing_released(g: any): boolean
	return (g.result ~= nil and g.result.outcome == "stale_target" and g.uncertain == nil)
		or (g.reconciliation ~= nil and g.reconciliation.outcome == "not_landed")
end
local function valid_landing_grant(g: any, d: any, registry: any, legacy: boolean?): boolean
	if type(g) ~= "table" or (g.legacy ~= nil and g.legacy ~= true) then return false end
	if not closed(g, LANDING_GRANT_KEYS) or not id(g.grant_id) or not id(g.worker_id) or not id(g.action_id) or not pos(g.action_revision)
		or not pos(g.reply_seq) or not id(g.message_id) or type(g.bytes) ~= "string" or not landing_text(g.target_revision)
		or not landing_text(g.source_revision) or not id(g.checkpoint_id) or not pos(g.controller_generation) or not pos(g.revision)
		or g.revision > registry.revision or type(g.published) ~= "boolean" or type(g.acknowledged) ~= "boolean" then return false end
	if (g.result ~= nil and not valid_landing_result(g.result)) or (g.late_result ~= nil and not valid_landing_result(g.late_result)) then return false end
	if g.uncertain ~= nil and (not closed(g.uncertain, "code message at_ms") or not str(g.uncertain.code, 96)
		or not wire_text(g.uncertain.message, 1024) or not (g.uncertain.at_ms == 0 or pos(g.uncertain.at_ms))) then return false end
	if g.result ~= nil and g.result.outcome == "uncertain" and g.uncertain == nil then return false end
	if g.late_result ~= nil and g.uncertain == nil and g.reconciliation == nil then return false end
	local r = g.reconciliation
	if r ~= nil and (not closed(r, "outcome target_revision current_target_revision reason source at_ms revision") or (r.outcome ~= "landed" and r.outcome ~= "not_landed")
		or (r.outcome == "landed" and r.target_revision == nil) or (r.target_revision ~= nil and not landing_text(r.target_revision))
		or (r.current_target_revision ~= nil and (r.outcome ~= "landed" or not landing_text(r.current_target_revision)))
		or (g.uncertain and g.uncertain.code == "repository_head_unordered"
			and (if r.outcome == "landed" then r.current_target_revision == nil else r.target_revision == nil))
		or not wire_text(r.reason, 1024) or not M.origin(r.source) or not (r.at_ms == 0 or pos(r.at_ms)) or not pos(r.revision)
		or r.revision > registry.revision or g.uncertain == nil) then return false end
	local w = d.workers[g.worker_id]
	if w then
		local reply = if g.legacy then nil else codec.decode_reply(g.bytes, w)
		if reply == nil and (g.legacy or legacy) then reply = config.legacy_grant(g.bytes, w) end
		if not valid_delivery(g, w, reply, "landing_grant") or reply.payload.grant_id ~= g.grant_id or reply.payload.target_revision ~= g.target_revision
			or reply.payload.source_revision ~= g.source_revision or reply.payload.checkpoint_id ~= g.checkpoint_id then return false end
		for _, result in { g.result, g.late_result } do if result.seq > w.accepted_seq then return false end end
	end
	return true
end
-- The last landing_refresh issued for an item: its exact immutable reply and delivery evidence.
local function valid_landing_refresh(v: any, item: any, q: any, d: any, registry: any): boolean
	-- worker_generation names the builder generation the notice went to (absent on 0.3.0 records).
	if not closed(v, "worker_id worker_generation expected_revision current_revision action_id action_revision reply_seq message_id bytes published acknowledged ack_seq ack_sha256 revision")
		or (v.worker_generation ~= nil and not pos(v.worker_generation))
		or not id(v.worker_id) or not landing_text(v.expected_revision) or not landing_text(v.current_revision) or v.expected_revision == v.current_revision
		or not id(v.action_id) or not pos(v.action_revision) or not pos(v.reply_seq) or not id(v.message_id) or type(v.bytes) ~= "string"
		or type(v.published) ~= "boolean" or type(v.acknowledged) ~= "boolean" or not pos(v.revision) or v.revision > registry.revision then return false end
	local w = d.workers[v.worker_id]
	if w then
		local reply = codec.decode_reply(v.bytes, w)
		if not valid_delivery(v, w, reply, "landing_refresh") or reply.payload.landing_id ~= item.id or reply.payload.project_id ~= q.project_id
			or reply.payload.repo_ref ~= q.repo_ref or reply.payload.target_ref ~= q.target_ref or reply.payload.expected_revision ~= v.expected_revision
			or reply.payload.current_revision ~= v.current_revision or (v.worker_generation ~= nil and v.worker_generation ~= w.worker_generation) then return false end
	end
	return true
end
local function valid_landing(d: any, registry: any, legacy: boolean?): boolean
	local L = d.landing
	if L == nil then return true end
	if not closed(L, "queues items") or type(L.queues) ~= "table" or L.queues == tern.json.null or type(L.items) ~= "table"
		or L.items == tern.json.null or count(L.queues) > 32 or count(L.items) > 64 then return false end
	local placed, occupied, modes = {}, {}, {}
	for key, q in L.queues do
		if not closed(q, "id logical_session_id project_id repo_ref target_ref repository order slot head") or not id(key) or q.id ~= key
			or not registry.sessions[q.logical_session_id] or not id(q.project_id) or not landing_text(q.repo_ref) or not landing_text(q.target_ref)
			or (q.repository ~= nil and (not config.valid_repository_identity(q.repository) or q.repository.target_ref ~= config.repository_target(q.target_ref)))
			or landing_queue_id(q.logical_session_id, q, q.repository) ~= key or not dense(q.order, 64) or (q.slot ~= nil and q.order[1] ~= q.slot) then return false end
		local external = q.repository ~= nil and q.repository.queue_route == "repository_queue"
		if external and q.slot ~= nil then return false end
		if q.repository and #q.order > 0 then
			local mode = modes[q.repository.key]
			if mode and mode ~= q.repository.queue_route then return false end
			modes[q.repository.key] = q.repository.queue_route
		end
		if q.slot and q.repository then
			if occupied[q.repository.key] then return false end
			occupied[q.repository.key] = q.slot
		end
		if q.head ~= nil and (not closed(q.head, "revision source landing_id") or not landing_text(q.head.revision)
			or not table.find({ "landed", "stale_target", "owner" }, q.head.source) or not id(q.head.landing_id)) then return false end
		for index, landing_id in q.order do
			local item = if id(landing_id) then L.items[landing_id] else nil
			if type(item) ~= "table" or item.queue_id ~= key or placed[landing_id] or LANDING_TERMINAL[item.status]
				or (not LANDING_UNGRANTED[item.status] and not external and (index ~= 1 or q.slot ~= landing_id)) then return false end
			placed[landing_id] = true
		end
	end
	for key, item in L.items do
		local q = if type(item) == "table" and id(item.queue_id) then L.queues[item.queue_id] else nil
		if not closed(item, LANDING_ITEM_KEYS) or not id(key) or item.id ~= key or not pos(item.revision) or not q
			or item.logical_session_id ~= q.logical_session_id or not id(item.work_id) or not id(item.worker_id)
			or not table.find(LANDING_STATUSES, item.status) or (not LANDING_TERMINAL[item.status]) ~= (placed[key] == true)
			or not (item.at_ms == 0 or pos(item.at_ms)) or not dense(item.grants, 8) or not dense(item.history, 32, 1) then return false end
		local r = item.request
		if not closed(r, "project_id repo_ref target_ref target_revision source_ref source_revision checkpoint_id summary event_id seq")
			or r.project_id ~= q.project_id or r.repo_ref ~= q.repo_ref or r.target_ref ~= q.target_ref or not landing_text(r.target_revision)
			or not landing_text(r.source_ref) or not landing_text(r.source_revision) or not id(r.checkpoint_id)
			or (r.summary ~= nil and not landing_text(r.summary)) or not id(r.event_id) or not pos(r.seq) then return false end
		if not config.valid_edges(item.history, "status", LANDING_STATUSES, item.status, registry.revision) or (item.gate_id ~= nil and not id(item.gate_id)) then return false end
		if item.approval ~= nil and (not closed(item.approval, "gate_id gate_revision at_ms") or item.approval.gate_id ~= item.gate_id
			or not pos(item.approval.gate_revision) or not (item.approval.at_ms == 0 or pos(item.approval.at_ms))) then return false end
		if item.verification ~= nil and (not legacy or not closed(item.verification, "attestation checkpoint_id artifact_revision") or item.verification.attestation ~= "worker-attested"
			or not id(item.verification.checkpoint_id) or item.verification.artifact_revision ~= r.source_revision) then return false end
		local proof = item.proof
		if proof ~= nil and (not closed(proof, "mode artifact_revision review_id check_refs")
			or not table.find({ "cross_family_review", "helper_checks", "review_disabled" }, proof.mode)
			or proof.artifact_revision ~= r.source_revision
			or (if proof.mode == "review_disabled" then proof.review_id ~= nil else not id(proof.review_id))
			or not config.texts(proof.check_refs, 16, 1024)) then return false end
		if item.hold ~= nil and (not closed(item.hold, "code message") or not str(item.hold.code, 96) or not wire_text(item.hold.message, 1024)) then return false end
		if item.refresh_required ~= nil and item.refresh_required ~= true then return false end
		if (item.refresh_loop ~= nil and not loops.valid(item.refresh_loop, { "target_moved", "stale_target" }))
			or (item.grant_loop ~= nil and not loops.valid(item.grant_loop)) then return false end
		if item.refresh ~= nil and not valid_landing_refresh(item.refresh, item, q, d, registry) then return false end
		for index, g in item.grants do
			if not valid_landing_grant(g, d, registry, legacy) or (index < #item.grants and not landing_released(g)) then return false end
		end
		local current = item.grants[#item.grants]
		if LANDING_UNGRANTED[item.status] or item.status == "cancelled" then
			if (current and not landing_released(current)) or q.slot == key then return false end
		elseif item.status == "granted" or item.status == "landing" then
			if not current or current.reconciliation ~= nil or (current.result ~= nil and current.result.outcome ~= "uncertain")
				or (not (q.repository and q.repository.queue_route == "repository_queue") and q.slot ~= key)
				or (item.status == "landing") ~= current.acknowledged then return false end
		elseif item.status == "landed" then
			if not current or not ((current.result and current.result.outcome == "landed" and not current.uncertain)
				or (current.reconciliation and current.reconciliation.outcome == "landed")) then return false end
		elseif not current or not current.result or current.result.outcome ~= "rejected" or current.uncertain then return false end
		-- Contract I holder: the generation the current grant is addressed to (restore-boundary 0.3.0
		-- items gain it in M.restore). Deploy bookkeeping exists only on landed items.
		local h = item.holder
		if h ~= nil and (not closed(h, "worker_id worker_generation") or not id(h.worker_id) or not pos(h.worker_generation)
			or (current ~= nil and current.worker_id ~= h.worker_id)) then return false end
		if h == nil and not legacy and current ~= nil and not LANDING_TERMINAL[item.status] then return false end
		local hw = if h then d.workers[h.worker_id] else nil
		if hw and (hw.worker_generation ~= h.worker_generation or hw.logical_session_id ~= item.logical_session_id) then return false end
		if (item.deploy_due ~= nil and item.deploy_due ~= true) or (item.deploy_id ~= nil and not id(item.deploy_id))
			or ((item.deploy_due ~= nil or item.deploy_id ~= nil) and item.status ~= "landed") then return false end
		local w = d.workers[item.worker_id]
		if not LANDING_TERMINAL[item.status] and not w then return false end
		if w and (w.logical_session_id ~= item.logical_session_id or w.work_id ~= item.work_id or r.seq > w.accepted_seq) then return false end
	end
	return true
end
-- Session-local concurrency ledger entry, bound to the routing decision/evidence; uncertain retains occupancy.
local RESERVATION_PHASES = { "reserved", "claimed", "launching", "active", "uncertain", "released" }
local RESERVATION_HELD = { reserved = true, claimed = true, launching = true, active = true, uncertain = true }
local function valid_reservation(v: any): boolean
	if v == nil then return true end
	if not closed(v, "id phase decision_digest evidence_revision history") or not id(v.id) or not table.find(RESERVATION_PHASES, v.phase)
		or not digest(v.decision_digest) or (v.evidence_revision ~= nil and not digest(v.evidence_revision)) or not dense(v.history, 8, 1) then return false end
	return config.valid_edges(v.history, "phase", RESERVATION_PHASES, v.phase)
end
-- Durable quota-routing decision on a worker (plan §7): requested vs selected record, exact policy
-- and USAGE evidence revisions, candidate reasons, and the one-action fallback gate binding.
local ROUTING_PHASES = { selected = true, held = true, gated = true }
local ROUTING_AUTHORITY = { "explicit", "requested_sufficient", "policy", "owner_gate" }
local function record_ref(v: any): boolean return closed(v, "id revision") and str(v.id, 96) and (v.revision == 0 or pos(v.revision)) end
local function record_tuple(v: any): boolean
	if not record_ref({ id = if type(v) == "table" then v.id else nil, revision = if type(v) == "table" then v.revision else nil })
		or not closed(v, "id revision provider account profile model principal") then return false end
	for _, key in { "provider", "account", "profile", "model" } do if v[key] ~= nil and not str(v[key], 1024) then return false end end
	return v.principal == nil or (type(v.principal) == "string" and v.principal:match("^[0-9a-f]+$") ~= nil and #v.principal == 16)
end
local function needs_text(v: any): boolean
	if not str(v, 64) then return false end
	for part in v:gmatch("[^,]+") do if part ~= "provider" and part ~= "account" and part ~= "model" then return false end end
	return true
end
-- History edges {<key>, revision, at_ms} naming `allowed` values (or `extra`), none past `ceiling`;
-- the last edge names the record's `current` value.
function config.valid_edges(edges: any, key: string, allowed: any, current: any, ceiling: number?, extra: string?): boolean
	for _, edge in edges do
		if not closed(edge, key .. " revision at_ms") or not (table.find(allowed, edge[key]) or (extra ~= nil and edge[key] == extra))
			or not pos(edge.revision) or (ceiling ~= nil and edge.revision > ceiling) or not (edge.at_ms == 0 or pos(edge.at_ms)) then return false end
	end
	return edges[#edges][key] == current
end
-- A quota_fallback binding: its open host gate bound to `worker_id`; a rollover's also names its quota scope.
function config.valid_quota_gate(d: any, g: any, worker_id: string, scoped: boolean): boolean
	local gate = (d.gates or {})[if type(g) == "table" then g.gate_id else nil]
	return closed(g, "gate_id policy_digest evidence_revision catalog_revision from to denied" .. (if scoped then " scope" else "")) and id(g.gate_id)
		and digest(g.policy_digest) and digest(g.evidence_revision) and (g.catalog_revision == 0 or pos(g.catalog_revision)) and record_tuple(g.from)
		and record_tuple(g.to) and needs_text(g.denied) and (not scoped or table.find(quota.SCOPES, g.scope) ~= nil) and gate ~= nil
		and gate.kind == "quota_fallback" and gate.worker_id == worker_id and gate_open(gate)
end
local function valid_routing(d: any, w: any): boolean
	local r = w.routing
	if r == nil then return true end
	if not closed(r, "mode phase requested coordinator policy_digest decided_at_ms evidence_revision auth_revision evidence_expires_at_ms reason authority authorized_digest switched needs selected candidates decision_digest gate bound history scope selector reservation")
		or (r.scope ~= nil and not table.find(quota.SCOPES, r.scope)) or (r.selector ~= nil and r.selector ~= "unverified_owner_text" and r.selector ~= "unverified_absent")
		or not valid_reservation(r.reservation) or (r.reservation ~= nil and not r.bound)
		or (r.authorized_digest ~= nil and (not digest(r.authorized_digest) or r.authority ~= "owner_gate"))
		or (r.mode ~= "quota" and r.mode ~= "explicit") or not ROUTING_PHASES[r.phase] or not record_ref(r.requested) or type(r.coordinator) ~= "boolean"
		or not digest(r.policy_digest) or not (r.decided_at_ms == 0 or pos(r.decided_at_ms)) or not digest(r.decision_digest)
		or type(r.switched) ~= "boolean" or type(r.bound) ~= "boolean" or not dense(r.candidates, quota.MAX_RECORDS + 1) or not dense(r.history, 8, 1) then return false end
	if (r.evidence_revision ~= nil and not digest(r.evidence_revision)) or (r.auth_revision ~= nil and not str(r.auth_revision, 256))
		or (r.evidence_expires_at_ms ~= nil and not pos(r.evidence_expires_at_ms)) or (r.needs ~= nil and not needs_text(r.needs))
		or (r.authority ~= nil and not table.find(ROUTING_AUTHORITY, r.authority)) or (r.selected ~= nil and not record_ref(r.selected)) then return false end
	if r.reason ~= nil and (not closed(r.reason, "code message") or not str(r.reason.code, 96) or not wire_text(r.reason.message, 4096)) then return false end
	if r.phase == "selected" and (not r.bound or not r.selected or r.selected.id ~= w.record_id or r.selected.revision ~= w.record_revision or not r.authority) then return false end
	if r.mode == "quota" and r.phase == "selected" and (not r.evidence_revision or not r.auth_revision) then return false end
	if r.switched and (not r.bound or (r.authority ~= "policy" and r.authority ~= "owner_gate")) then return false end
	if not r.switched and r.needs ~= nil then return false end
	if not r.bound then
		-- Unbound (held/gated before any provisioning): no mailbox, effect or launch exists yet.
		if w.phase ~= "queued" or w.mailbox_handle ~= nil or w.coordinator_owner_id ~= nil then return false end
		for _, a in d.actions do if a.worker_id == w.worker_id then return false end end
	end
	for _, c in r.candidates do
		if not closed(c, "id revision rank status reason remaining_pct weekly_reset_ms needs rejection") or not str(c.id, 96)
			or (c.revision ~= nil and not (c.revision == 0 or pos(c.revision))) or (c.rank ~= 0 and c.rank ~= 1)
			or not table.find({ "explicit", "sufficient", "insufficient", "unknown" }, c.status) or (c.reason ~= nil and not quota.REASONS[c.reason])
			or (c.remaining_pct ~= nil and (type(c.remaining_pct) ~= "number" or c.remaining_pct < 0 or c.remaining_pct > 100))
			or (c.weekly_reset_ms ~= nil and not pos(c.weekly_reset_ms)) or (c.needs ~= nil and not needs_text(c.needs))
			or (c.rejection ~= nil and not wire_text(c.rejection, 1024)) then return false end
	end
	for _, h in r.history do
		if not closed(h, "at_ms outcome decision_digest evidence_revision") or not (h.at_ms == 0 or pos(h.at_ms)) or not ROUTING_PHASES[h.outcome]
			or not digest(h.decision_digest) or (h.evidence_revision ~= nil and not digest(h.evidence_revision)) then return false end
	end
	if (r.phase == "gated") ~= (r.gate ~= nil) then return false end
	if r.gate ~= nil and (r.bound or not config.valid_quota_gate(d, r.gate, w.worker_id, false)) then return false end
	return true
end
-- Rollover-time quota routing state (plan §7 lines 305, 321): an open predecessor-bound fallback
-- gate, or the owner's one-action approval/rejection, kept only until the successor is granted.
local function valid_rollover_quota(d: any, r: any): boolean
	local q = r.quota
	if q == nil then return true end
	local waiting = if r.kind == "coordinator" then "owner_retired" else "checkpoint_verified"
	if not closed(q, "gate approval rejected") or (r.phase ~= waiting and r.phase ~= "cancelled") then return false end
	if q.gate ~= nil and not config.valid_quota_gate(d, q.gate, r.predecessor_worker_id, true) then return false end
	for _, key in { "approval", "rejected" } do
		local v = q[key]
		if v ~= nil and (not closed(v, "policy_digest to needs gate_id") or not digest(v.policy_digest) or not record_tuple(v.to)
			or not id(v.gate_id) or (v.needs ~= nil and not needs_text(v.needs))) then return false end
	end
	return true
end
-- Only the restore boundary accepts the former encoded-chunk prefix. Revalidate it there,
-- then retain the shared JSON-safe incremental state; no live push replays earlier chunks.
function config.restore_assembly(w: any): any?
	local old = w.assembly
	if not closed(old, "manifest sha256 chunks") or not dense(old.chunks, codec.LIMITS.chunks)
		or not digest(old.sha256) or not str(old.manifest, codec.LIMITS.control) then return nil end
	local binding = report_binding(w)
	local a = codec.assembly_start(old.manifest, old.sha256, binding)
	if not a then return nil end
	for _, part in old.chunks do
		if not closed(part, "bytes sha256") or not str(part.bytes, codec.LIMITS.chunk) or not digest(part.sha256) then return nil end
		local pushed = codec.assembly_push(a, part.bytes, part.sha256, binding)
		if not pushed or pushed.complete or pushed.code ~= "incomplete" then return nil end
	end
	if a.next_index ~= #old.chunks + 1 then return nil end
	return a
end
function config.valid_assembly(w: any, legacy: boolean?): any?
	local a = w.assembly
	if legacy and type(a) == "table" and a.version == nil then a = config.restore_assembly(w) end
	if not closed(a, "version manifest manifest_bytes manifest_sha256 binding next_index slices object_digests bytes")
		or a.version ~= 1 or not digest(a.manifest_sha256) or not str(a.manifest_bytes, codec.LIMITS.control)
		or not equal(a.binding, report_binding(w)) then return nil end
	local started = codec.assembly_start(a.manifest_bytes, a.manifest_sha256, a.binding)
	if not started or not equal(started.manifest, a.manifest) or a.manifest.direction ~= "report"
		or a.manifest.slot ~= w.accepted_seq + 1 or not pos(a.next_index) or a.next_index > a.manifest.count
		or not dense(a.slices, codec.LIMITS.chunks) or not dense(a.object_digests, codec.LIMITS.chunks)
		or #a.slices ~= a.next_index - 1 or #a.object_digests ~= #a.slices then return nil end
	local bytes = 0
	for index, slice in a.slices do
		if not str(slice, math.ceil(codec.LIMITS.slice / 3) * 4) or not digest(a.object_digests[index]) then return nil end
		local ok, raw = pcall(tern.base64.decode, slice)
		if not ok or type(raw) ~= "string" or #raw ~= codec.LIMITS.slice or tern.base64.encode(raw) ~= slice then return nil end
		bytes += #raw
	end
	if a.bytes ~= bytes or bytes >= a.manifest.message_bytes or bytes > codec.LIMITS.logical then return nil end
	if w.read_selector ~= nil and not equal(w.read_selector, { stream = "report", slot = a.manifest.slot, part = "chunk", index = a.next_index }) then return nil end
	return a
end
-- The same worker validator covers live workers and a pre-effect handover candidate.
function config.valid_worker(d: any, w: any, key: any, registry: any, legacy_catalog_cache: boolean?, assembly_count: number, assembly_bytes: number)
		if not closed(w, "start_retirement project_start_protocol enrol_association selected_record worker_id work_id worker_generation logical_session_id orch_project_id execution_cwd presentation open_conversation enrol_delivery enrol_cancelling startup_cancelling prompt_delivery project_held checks_pending origin_binding controller_pane record_id record_revision prompt cwd placement assignment_sha256 launch_request_id launch_action_id enrolment_token phase accepted_seq compacted_floor receipts replies reply_seq reply_floor coordinator_owner_id coordinator_generation coordinator_protocol activation retirement release stop_action_id stop_refused stopped mailbox_retired mailbox_retire_action_id mailbox_handle capabilities binding_digest receipt_chain compacted_chain pane_binding effective_identity accepted_event accept_pending registered frozen reason assembly read_selector compaction_pending workflow rejected_report finish control_origin control_pane control_pane_binding continuation_required wakes handover_id handover_token restored routing adopt_pane_binding withdrawn launch_refused retirement_refused ruling_document " .. config.WORKER_FIELDS .. (if legacy_catalog_cache then " attachment_action_id" else ""))
			or not id(key) or w.worker_id ~= key or not M.origin(w.origin_binding) or w.logical_session_id ~= w.origin_binding.logical_session_id
			or not id(w.launch_request_id) or not id(w.launch_action_id) or not id(w.work_id) or w.worker_generation ~= 1
			or not str(w.enrolment_token, 128) or #w.enrolment_token < 16 or w.enrolment_token:match("^[A-Za-z0-9_-]+$") == nil
			or not str(w.prompt, 32768) or not digest(w.assignment_sha256) or codec.sha256(w.prompt) ~= w.assignment_sha256
			or type(w.receipts) ~= "table" or count(w.receipts) > 16 or type(w.replies) ~= "table" or count(w.replies) > 8
			or not (w.accepted_seq == 0 or pos(w.accepted_seq)) or not (w.compacted_floor == 0 or pos(w.compacted_floor)) or w.compacted_floor > w.accepted_seq
			or not (w.reply_seq == 0 or pos(w.reply_seq)) or not (w.reply_floor == 0 or pos(w.reply_floor)) or w.reply_floor > w.reply_seq then return false end
		if w.selected_record ~= nil then
			local row = w.selected_record
			if not closed(row, "id revision provider account_label model backend") or row.id ~= w.record_id or row.revision ~= w.record_revision
				or not str(row.provider, 96) or not str(row.backend, 96) or (row.account_label ~= nil and not str(row.account_label, 160, true))
				or (row.model ~= nil and not str(row.model, 160, true)) then return false end
		end
		if (w.orch_project_id ~= nil and not id(w.orch_project_id)) or (registry.version == 5 and not id(w.orch_project_id))
			or (w.execution_cwd ~= nil and not rulings.absolute(w.execution_cwd))
			or (w.presentation ~= nil and not table.find({ "user_new_tab", "coordinator_adjacent", "background" }, w.presentation))
			or (w.open_conversation ~= nil and w.open_conversation ~= true) or (w.project_held ~= nil and w.project_held ~= true)
			or (w.checks_pending ~= nil and w.checks_pending ~= true)
			or (w.enrol_delivery ~= nil and (not table.find({ "native_ask", "clipboard" }, w.enrol_delivery) or not w.adopt_pane_binding
				or w.prompt ~= codec.OPEN_CONVERSATION_ASSIGNMENT or w.presentation ~= nil or w.execution_cwd ~= nil)) then return false end
		if w.enrol_association ~= nil and (not w.enrol_delivery or w.accepted_event ~= nil or type(w.enrol_association) ~= "table"
			or not config.valid_association(w.enrol_association, w.enrol_association.conversation_id)
			or not config.same_conversation(w.enrol_association.pane_binding, w.adopt_pane_binding)) then return false end
		if w.enrol_cancelling ~= nil and (w.enrol_cancelling ~= true or not w.enrol_delivery or not w.mailbox_handle
			or w.accepted_event or w.accepted_seq ~= 0 or w.reply_seq ~= 0 or w.stopped) then return false end
		if w.startup_cancelling ~= nil and (w.startup_cancelling ~= true or not config.failed_startup(registry, w)) then return false end
		if w.prompt_delivery ~= nil and not table.find({ "submitted_not_accepted", "copied_not_accepted", "not_submitted" }, w.prompt_delivery) then return false end
		if not table.find({ "queued", "provisioned", "awaiting_acceptance", "accepted", "held" }, w.phase) then return false end
		if w.phase == "accepted" and (not id(w.mailbox_handle) or w.pane_binding == nil or w.accepted_event == nil or not pos(w.accepted_seq)) then return false end
		if w.mailbox_handle ~= nil and (not id(w.mailbox_handle) or not digest(w.receipt_chain) or not digest(w.compacted_chain) or not digest(w.binding_digest)) then return false end
		if w.accepted_event ~= nil and (not id(w.mailbox_handle) or not closed(w.accepted_event, "event_id seq event_sha256") or not pos(w.accepted_event.seq)
			or w.accepted_event.seq > w.accepted_seq or not digest(w.accepted_event.event_sha256)
			or w.accepted_event.event_id ~= codec.sha256(w.mailbox_handle .. ":report:" .. string.format("%.0f", w.accepted_event.seq))) then return false end
		if w.pane_binding ~= nil and not pane_binding(w.pane_binding, w.origin_binding) then return false end
		for seq, receipt in w.receipts do
			if not closed(receipt, "bytes sha256 event_id chain publish kind") or not digest(receipt.sha256) or not digest(receipt.chain) or type(receipt.publish) ~= "boolean" or not table.find(REPORT_KINDS, receipt.kind) then return false end
			local expected = clone(w); expected.seq = tonumber(seq); expected.event_id = receipt.event_id; expected.event_sha256 = receipt.sha256
			local ack = codec.decode_ack(receipt.bytes, expected); if ack == nil or ack.seq > w.accepted_seq or ack.seq <= w.compacted_floor or ack.receipt_chain_sha256 ~= receipt.chain or ack.committed_revision > registry.revision then return false end
		end
		for seq, reply in w.replies do
			if not closed(reply, "bytes sha256 frames part message_id reply_seq action_id action_revision acknowledged legacy")
				or type(reply.frames) ~= "table" or not pos(reply.part) or type(reply.acknowledged) ~= "boolean"
				or (reply.legacy ~= nil and (not legacy_catalog_cache or reply.legacy ~= true)) then return false end
			-- A retained 0.3.0 landing_grant (Contract B upgrade) is immutable evidence under its legacy schema.
			local decoded = if reply.legacy then nil else codec.decode_reply(reply.bytes, w)
			local old = decoded == nil and (reply.legacy or legacy_catalog_cache) and config.legacy_grant(reply.bytes, w) or nil
			decoded = decoded or old
			if not decoded or tostring(decoded.reply_seq) ~= seq or decoded.reply_seq <= w.reply_floor or decoded.reply_seq > w.reply_seq
				or codec.sha256(reply.bytes) ~= reply.sha256 or decoded.message_id ~= reply.message_id
				or decoded.action_id ~= reply.action_id or decoded.action_revision ~= reply.action_revision then return false end
			if old then
				local f = reply.frames
				if f.message_sha256 ~= reply.sha256 or f.message_bytes ~= #reply.bytes or type(f.chunks) ~= "table" or #f.chunks ~= math.ceil(#reply.bytes / 2048)
					or reply.part > #f.chunks + 2 then return false end
			else
				local frames = codec.frame(reply.bytes, "reply", w)
				if not frames or not equal(frames, reply.frames) or reply.part > #frames.chunks + 2 then return false end
			end
		end
		if w.coordinator_protocol ~= nil and (w.coordinator_protocol ~= 1 or not id(w.coordinator_owner_id) or not pos(w.coordinator_generation)) then return false end
		if w.project_start_protocol ~= nil and (w.project_start_protocol ~= 1 or w.role ~= "coordinator"
			or (w.mailbox_handle ~= nil and not table.find(w.capabilities or {}, "project-start-v1"))) then return false end
		-- An adopted hand-opened agent is an ordinary first generation bound to its exact attested pane.
		if w.adopt_pane_binding ~= nil and (not pane_binding(w.adopt_pane_binding, w.origin_binding) or w.coordinator_owner_id ~= nil
			or w.handover_id ~= nil or w.routing ~= nil or (w.pane_binding ~= nil and not equal(w.pane_binding, w.adopt_pane_binding))) then return false end
		-- Rollover successors carry the paired immutable handover enrolment; initial launches never do.
		if (w.handover_id == nil) ~= (w.handover_token == nil) or (w.handover_id ~= nil
			and (not id(w.handover_id) or not digest(w.handover_token) or (w.coordinator_owner_id ~= nil and w.coordinator_protocol ~= 1))) then return false end
		-- Reappearance after native stop or explicit owner recovery is current restoration evidence.
		if w.restored ~= nil and (not closed(w.restored, "at_ms state reconciled") or not retired_coordinator(registry, w)
			or not (w.restored.at_ms == 0 or pos(w.restored.at_ms)) or not table.find({ "working", "idle", "waiting-input" }, w.restored.state)
			or (w.restored.reconciled ~= nil and w.restored.reconciled ~= "observed_exit" and w.restored.reconciled ~= "operator_attested")) then return false end
		for _, name in { "activation", "retirement" } do
			local grant = w[name]
			if grant ~= nil then
				if w.coordinator_protocol ~= 1 or not closed(grant, "action_id action_revision reply_seq activation_token acknowledged bytes ack_seq ack_sha256")
					or not id(grant.action_id) or not pos(grant.action_revision) or not pos(grant.reply_seq) or grant.reply_seq > w.reply_seq
					or not digest(grant.activation_token) or type(grant.acknowledged) ~= "boolean" then return false end
				local reply = codec.decode_reply(grant.bytes, w)
				if not reply or reply.kind ~= "coordinator_" .. name or reply.action_id ~= grant.action_id or reply.action_revision ~= grant.action_revision
					or reply.reply_seq ~= grant.reply_seq or reply.payload.owner_id ~= w.coordinator_owner_id
					or reply.payload.owner_generation ~= w.coordinator_generation or reply.payload.activation_token ~= grant.activation_token then return false end
				if grant.acknowledged and grant.reply_seq > w.reply_floor and not (w.replies[tostring(grant.reply_seq)] and w.replies[tostring(grant.reply_seq)].acknowledged) then return false end
				if grant.acknowledged then
					if not pos(grant.ack_seq) or grant.ack_seq > w.accepted_seq or not digest(grant.ack_sha256) then return false end
					local receipt = w.receipts[tostring(grant.ack_seq)]
					if grant.ack_seq > w.compacted_floor and (not receipt or receipt.kind ~= "reply_ack" or receipt.sha256 ~= grant.ack_sha256) then return false end
				elseif grant.ack_seq ~= nil or grant.ack_sha256 ~= nil then return false end
			end
		end
		if w.retirement and (not w.activation or w.retirement.activation_token ~= w.activation.activation_token) then return false end
		if w.release ~= nil then
			if not closed(w.release, "seq event_sha256 action_id action_revision") or not pos(w.release.seq) or w.release.seq > w.accepted_seq
				or not digest(w.release.event_sha256) or not w.activation or not w.activation.acknowledged then return false end
			local grant = if w.release.action_id == w.activation.action_id then w.activation else w.retirement
			if not grant or grant.action_id ~= w.release.action_id or grant.action_revision ~= w.release.action_revision then return false end
		end
		-- Finish source: the owner's origin, or ORCH+'s own auto-finish of a reviewer/labeller (Task 3A).
		local source = if w.finish then w.finish.source else nil
		local auto = closed(source, "kind rule") and source.kind == "policy" and (w.role == "reviewer" or w.role == "labeller") and source.rule == "auto_finish:" .. w.role
		if w.finish ~= nil and (w.coordinator_owner_id ~= nil or not closed(w.finish, "request_id seq revision source")
			or not id(w.finish.request_id) or not pos(w.finish.seq) or w.finish.seq > w.accepted_seq
			or not pos(w.finish.revision) or w.finish.revision > registry.revision or (not auto and (not M.origin(source)
			or source.logical_session_id ~= w.logical_session_id or source.owner_id ~= w.origin_binding.owner_id
			or source.owner_generation ~= w.origin_binding.owner_generation or source.host_pane_id ~= w.origin_binding.host_pane_id
			or source.alias_nonce ~= w.origin_binding.alias_nonce))) then return false end
		if w.stop_action_id ~= nil then
			local action = d.actions[w.stop_action_id]
			if not (w.release or w.finish or (w.start_retirement and config.valid_start_retirement(w))) or not action or action.worker_id ~= key or action.request.op ~= "stop" then return false end
		end
		if w.stopped ~= nil and (not closed(w.stopped, "pane_binding observation") or not pane_shape(w.stopped.pane_binding)
			or not equal(w.stopped.pane_binding, control_binding(w)) or not table.find({ "absent", "exited" }, w.stopped.observation)) then return false end
		if legacy_catalog_cache and w.stopped then
			local action = if w.stop_action_id then d.actions[w.stop_action_id] else nil
			if not action or not action.response or action.response.status ~= "stopped" or not equal(w.stopped, action.response.payload) then return false end
		end
		if w.mailbox_retire_action_id ~= nil then
			local action = d.actions[w.mailbox_retire_action_id]
			if not (w.stopped or launch_rejected(d, w, legacy_catalog_cache) or w.withdrawn ~= nil or w.enrol_cancelling or w.startup_cancelling) or not action or action.worker_id ~= key or action.request.op ~= "mailbox_retire" or action.request.mode ~= "retire" then return false end
		end
		-- Owner withdrawal of fenced never-launched work whose mailbox was provisioned (cancel_work):
		-- the kept fenced launch/adoption action and its definitive evidence.
		if w.withdrawn ~= nil and (not closed(w.withdrawn, "op action_id evidence")
			or (w.withdrawn.op ~= "mailbox_provision" and w.withdrawn.op ~= "launch" and w.withdrawn.op ~= "adopt" and w.withdrawn.op ~= "enrol")
			or not id(w.withdrawn.action_id) or (w.withdrawn.op ~= "mailbox_provision" and w.withdrawn.action_id ~= w.launch_action_id)
			or (w.withdrawn.evidence ~= "unissued" and w.withdrawn.evidence ~= "pre_effect_refusal"
				and not (legacy_catalog_cache and w.withdrawn.evidence == "never_claimed")) or not id(w.mailbox_handle) or (w.phase ~= "provisioned" and w.phase ~= "held")
			or w.pane_binding ~= nil or w.stopped ~= nil) then return false end
		if w.mailbox_retired ~= nil and (w.mailbox_retired ~= true or not w.mailbox_handle) then return false end
		if w.start_retirement ~= nil and (not config.valid_start_retirement(w) or w.start_retirement.revision > registry.revision) then return false end
		if w.mailbox_allocation ~= nil and w.mailbox_allocation ~= "possible" and w.mailbox_allocation ~= "none" then return false end
		if w.mailbox_allocation == "none" and w.mailbox_handle and not w.mailbox_retired then return false end
		if legacy_catalog_cache and w.mailbox_retired then
			local action = if w.mailbox_retire_action_id then d.actions[w.mailbox_retire_action_id] else nil
			if not action or action.phase ~= "complete" or not action.response or action.response.status ~= "retired" then return false end
		end
		if w.launch_refused ~= nil and (w.launch_refused ~= true or w.pane_binding ~= nil) then return false end
		if w.retirement_refused ~= nil and w.retirement_refused ~= true then return false end
		if w.launch_refused_op ~= nil and (w.launch_refused ~= true or (w.launch_refused_op ~= "mailbox_provision"
			and w.launch_refused_op ~= "launch" and w.launch_refused_op ~= "adopt" and w.launch_refused_op ~= "enrol")) then return false end
		if w.stop_refused ~= nil and (w.stop_refused ~= true or w.stopped ~= nil) then return false end
		if w.ruling_document ~= nil and (not closed(w.ruling_document, "path selected_by existing") or not rulings.absolute(w.ruling_document.path)
			or w.ruling_document.selected_by ~= "owner" or w.ruling_document.existing ~= true) then return false end
		if w.assembly ~= nil then
			local assembly = config.valid_assembly(w, legacy_catalog_cache)
			if not assembly then return false end
			assembly_count += 1; assembly_bytes += assembly.bytes
			if assembly_count > codec.LIMITS.assemblies or assembly_bytes > codec.LIMITS.reassembly_bytes then return false end
		elseif w.read_selector ~= nil then return false end
		if w.rejected_report ~= nil then
			local rejected = w.rejected_report
			if not closed(rejected, "code message bytes sha256 action_id") or not str(rejected.code, 96) or not str(rejected.message, 1024)
				or not str(rejected.bytes, 65536) or rejected.sha256 ~= codec.sha256(rejected.bytes) or not id(rejected.action_id)
				or w.assembly ~= nil or w.read_selector ~= nil then return false end
		end
		if not valid_flow(d, w, registry, legacy_catalog_cache) or not valid_routing(d, w) or not config.worker_fields(w, legacy_catalog_cache) then return false end
		if w.continuation_required ~= nil and type(w.continuation_required) ~= "boolean" then return false end
		if w.control_origin ~= nil then
			if not M.origin(w.control_origin) or not pane_binding(w.control_pane_binding, w.control_origin)
				or not str(w.control_pane, 96) or not w.control_pane:match("^%d+$") then return false end
			if legacy_catalog_cache then
				local attachment = if w.attachment_action_id then d.actions[w.attachment_action_id] else nil
				if not attachment or attachment.phase ~= "complete" or attachment.request.op ~= "attach_worker"
					or not equal(attachment.request.origin_binding, w.control_origin) or not equal(attachment.request.pane_binding, w.control_pane_binding)
					or attachment.request.controller_pane ~= w.control_pane or not attachment.response or attachment.response.status ~= "attached" then return false end
			end
		elseif w.control_pane ~= nil or w.control_pane_binding ~= nil then return false end
		if w.wakes ~= nil then
			if type(w.wakes) ~= "table" or w.wakes == tern.json.null or count(w.wakes) > 32 then return false end
			for key, wake in w.wakes do
				if not closed(wake, "target_request_id target_action_id action_id") or wake.target_action_id ~= key or not id(key)
					or not id(wake.target_request_id) then return false end
				if wake.action_id ~= nil then
					local action = d.actions[wake.action_id]
					if not action or action.worker_id ~= w.worker_id or action.request.op ~= "native_wake"
						or action.request.target_action_id ~= key or action.request.target_request_id ~= wake.target_request_id then return false end
				end
			end
		end
	return true, assembly_count, assembly_bytes
end
-- Shape and correlation checks protect restored dispatch state; codecs revalidate exact receipts.
function M.valid(d: any, registry: any, legacy_catalog_cache: boolean?): boolean
	if d == nil then return true end
	if not closed(d, "serial actions workers catalogs catalog_pages catalog_scans policies family_migrations cleanup_notices repository_policies gates command_cursors rollovers landing capacity sweeps reviews deploys plans intakes chains projects finished_projects" .. (if legacy_catalog_cache then " commands" else "")) or type(d.serial) ~= "number" or d.serial < 0 or d.serial % 1 ~= 0 or d.serial > MAX then return false end
	for _, field in { "family_migrations", "cleanup_notices" } do
		if d[field] ~= nil then
			if type(d[field]) ~= "table" or d[field] == tern.json.null or count(d[field]) > 64 then return false end
			for sid, value in d[field] do
				if not registry.sessions[sid] then return false end
				if field == "cleanup_notices" then
					if not sweep_date(value) then return false end
				else
					if type(value) ~= "table" or count(value) > 32 then return false end
					for record, family in value do if not config.record(record) or not config.family(family) then return false end end
				end
			end
		end
	end
	if d.catalog_scans ~= nil then
		if type(d.catalog_scans) ~= "table" or d.catalog_scans == tern.json.null or count(d.catalog_scans) > 64 or type(d.catalogs) ~= "table" then return false end
		for sid, assembling in d.catalog_scans do
			local cached = d.catalogs[sid]
			if not registry.sessions[sid] or type(assembling) ~= "boolean" or type(cached) ~= "table"
				or assembling ~= (cached.next_cursor ~= nil) then return false end
		end
	end
	if d.catalog_pages ~= nil then
		if type(d.catalog_pages) ~= "table" or d.catalog_pages == tern.json.null or count(d.catalog_pages) > 64 or type(d.catalogs) ~= "table" then return false end
		for sid, page in d.catalog_pages do
			local cached = d.catalogs[sid]
			if not registry.sessions[sid] or not catalog(page) or type(cached) ~= "table"
				or page.namespace ~= cached.namespace or page.host_key ~= cached.host_key or page.config_revision ~= cached.config_revision
				or not equal(page.next_cursor, cached.next_cursor) then return false end
		end
	end
	if d.repository_policies ~= nil then
		if type(d.repository_policies) ~= "table" or d.repository_policies == tern.json.null then return false end
		for key, choice in d.repository_policies do
			if not config.valid_repository_choice(choice) or key ~= config.repository_policy_key(choice.common_dir, choice.target_ref) then return false end
		end
	end
	if not config.valid_projects(d, registry) or not config.valid_reviews(d, registry) or not config.valid_sources(d, registry) then return false end
	if not valid_sweeps(d, registry) then return false end
	if d.capacity ~= nil then
		if type(d.capacity) ~= "table" or d.capacity == tern.json.null or count(d.capacity) > 64 then return false end
		for sid, e in d.capacity do if not registry.sessions[sid] or not quota.valid_evidence(e) then return false end end
	end
	for _, key in { "actions", "workers", "catalogs" } do if type(d[key]) ~= "table" then return false end end
	if not legacy_catalog_cache and (type(d.gates) ~= "table" or type(d.policies) ~= "table" or type(d.command_cursors) ~= "table") then return false end
	for _, key in { "policies", "gates", "rollovers", "landing" } do if d[key] ~= nil and (type(d[key]) ~= "table" or d[key] == tern.json.null) then return false end end
	if count(d.actions) > 4096 or count(d.workers) > 32 then return false end
	if d.command_cursors ~= nil then
		if type(d.command_cursors) ~= "table" or d.command_cursors == tern.json.null or count(d.command_cursors) > 64 then return false end
		for sid, cursor in d.command_cursors do
			if not registry.sessions[sid] or not closed(cursor, "origin controller_pane seq continued_epoch policy_revision") or not M.origin(cursor.origin)
				or cursor.origin.logical_session_id ~= sid or not pos(cursor.seq) or not str(cursor.controller_pane, 96) or not cursor.controller_pane:match("^%d+$")
				or (cursor.policy_revision ~= nil and (not pos(cursor.policy_revision) or cursor.policy_revision > registry.revision))
				or (cursor.continued_epoch ~= nil and (not pos(cursor.continued_epoch) or cursor.continued_epoch > registry.execution_epoch)) then return false end
		end
	end
	for key, a in d.actions do
		local family_receipt = not legacy_catalog_cache and type(a) == "table" and type(a.request) == "table"
			and a.request.op == "declare_provider_families" and a.phase == "complete"
		if not closed(a, "request request_bytes phase worker_id claim response_bytes response response_grant executor_stopped executor_released retry_after_serial retry_count retry_loop stale_gate_id" .. (if legacy_catalog_cache then " resolution" else "")) or not id(key) or type(a.request) ~= "table" or a.request.action_id ~= key
			or not M.origin(a.request.origin_binding) or registry.sessions[a.request.origin_binding.logical_session_id] == nil then return false end
		if not legacy_catalog_cache and a.request.schema ~= 2 then return false end
		if legacy_catalog_cache and type(a.request_bytes) ~= "string" then return false end
		if a.request_bytes ~= nil then
			local decoded = if legacy_catalog_cache and a.request.schema == 1 then codec.strict_decode(a.request_bytes, 8192) else codec.decode_dispatch_request(a.request_bytes)
			if not decoded or not equal(decoded, a.request) then return false end
			if not legacy_catalog_cache and (a.request.authority_namespace ~= registry.authority_namespace
				or a.request.admission_seq ~= registry.sessions[a.request.logical_session_id].admission_seq
				or a.request.request_serial >= registry.sessions[a.request.logical_session_id].next_request_serial) then return false end
		elseif a.request.request_serial ~= nil or a.claim ~= nil or (a.phase ~= "ready" and a.phase ~= "held_ready") then return false end
		if not table.find(if legacy_catalog_cache then { "ready", "held_ready", "claimed", "complete", "uncertain", "resolved", "backpressure" }
			else { "ready", "held_ready", "claimed", "uncertain", "backpressure" }, a.phase) and not family_receipt then return false end
		if a.executor_stopped ~= nil and (a.executor_stopped ~= true or a.phase ~= "uncertain" or not a.claim) then return false end
		if a.executor_released ~= nil and (a.executor_released ~= true or (a.phase ~= "backpressure" and a.phase ~= "uncertain" and not family_receipt) or not a.claim) then return false end
		if a.retry_after_serial ~= nil and (not pos(a.retry_after_serial) or a.request_bytes ~= nil
			or a.retry_after_serial >= registry.sessions[a.request.origin_binding.logical_session_id].next_request_serial
			or (a.request.op ~= "launch" and a.request.op ~= "adopt" and a.request.op ~= "enrol")) then return false end
		if a.claim ~= nil and (not closed(a.claim, "executor epoch grant_id spawn_claim capacity claimed_at stale_gate_id") or not id(a.claim.executor) or not id(a.claim.grant_id) or not pos(a.claim.epoch) or a.claim.epoch > registry.execution_epoch
			or (a.claim.spawn_claim ~= nil and not codec.validate_spawn_claim(a.claim.spawn_claim, false))) then return false end
		-- Host-only claim aging (never projected to SPAWN): the claim's stamp and its one stale_claim gate.
		if a.claim ~= nil and ((a.claim.claimed_at ~= nil and (not closed(a.claim.claimed_at, "at_ms mono_ms epoch") or not valid_stamp(a.claim.claimed_at)))
			or (a.claim.stale_gate_id ~= nil and not id(a.claim.stale_gate_id))) then return false end
		-- A rechecked action waiting for its next claim carries its previous claim's stale_claim gate.
		if a.stale_gate_id ~= nil and (not id(a.stale_gate_id) or a.claim ~= nil) then return false end
		-- A routed launch claim binds the exact USAGE revision that USAGE confirmed current immediately before it.
		if a.claim ~= nil and a.claim.capacity ~= nil and (a.request.op ~= "launch" or not closed(a.claim.capacity, "revision validated_at_ms expires_at_ms")
			or not digest(a.claim.capacity.revision) or not (a.claim.capacity.validated_at_ms == 0 or pos(a.claim.capacity.validated_at_ms))
			or not pos(a.claim.capacity.expires_at_ms)) then return false end
		if a.retry_count ~= nil and not pos(a.retry_count) then return false end
		if a.retry_loop ~= nil and not loops.valid(a.retry_loop) then return false end
		if a.response_grant ~= nil and not id(a.response_grant) then return false end
		if (a.phase == "claimed" or a.phase == "uncertain" or family_receipt) and not (type(a.claim) == "table" and id(a.claim.executor) and pos(a.claim.epoch)) then return false end
		if a.worker_id ~= nil and d.workers[a.worker_id] == nil then return false end
		if not valid_request(a.request, if a.worker_id then d.workers[a.worker_id] else nil, d, legacy_catalog_cache) then return false end
		if a.response_bytes ~= nil then
			local body = if legacy_catalog_cache and a.request.schema == 1 then config.migration.legacy_response(a.response_bytes, a.request) else protocol.decode_response(a.response_bytes, a.request)
			if body == nil or not equal(body, a.response) then return false end
		end
		-- Only this exact terminal configuration receipt survives until its fresh
		-- catalog confirms the saved families; it carries no live executor.
		if family_receipt and (a.executor_released ~= true or type(a.response_bytes) ~= "string" or not a.response
			or a.response.category ~= "current_result" or a.response_grant ~= a.claim.grant_id
			or (a.response.status ~= "resolved" and a.response.status ~= "rejected")) then return false end
		if a.phase == "backpressure" and (not a.claim or a.response_grant ~= a.claim.grant_id or not a.response
			or a.response.status ~= "full" or not retryable_full(a.response.payload)) then return false end
		if a.resolution ~= nil then
			local resolution = a.resolution
			if not closed(resolution, "revision executor evidence reason status_sha256") or not pos(resolution.revision) or resolution.revision > registry.revision
				or not id(resolution.executor) or not str(resolution.reason, 512)
				or not table.find({ "operator_attested", "never_claimed", "pre_effect_refusal", "publication_readback", "read_lost_no_effect", "read_superseded" }, resolution.evidence)
				or a.phase ~= "resolved" then return false end
			if resolution.evidence == "publication_readback" and (a.claim == nil or (a.request.op ~= "mailbox_publish_ack" and a.request.op ~= "mailbox_publish_reply")) then return false end
			if resolution.evidence == "never_claimed" and a.claim ~= nil then return false end
			if resolution.evidence == "pre_effect_refusal" and (not a.response or a.response.status ~= "full" or not retryable_full(a.response.payload)) then return false end
			-- Read resolutions only ever settle a claimed read-only operation; only SPAWN's `missing`
			-- status evidence carries (and requires) the digest of its exact status response.
			if (resolution.evidence == "read_lost_no_effect" or resolution.evidence == "read_superseded")
				and (a.claim == nil or not READ_ONLY_OPS[a.request.op] or resolution.executor ~= a.claim.executor) then return false end
			if (resolution.evidence == "read_lost_no_effect") ~= (resolution.status_sha256 ~= nil)
				or (resolution.status_sha256 ~= nil and not digest(resolution.status_sha256)) then return false end
		elseif a.phase == "resolved" then return false end
	end
	local assembly_count, assembly_bytes = 0, 0
	for key, w in d.workers do
		local valid, next_count, next_bytes = config.valid_worker(d, w, key, registry, legacy_catalog_cache, assembly_count, assembly_bytes)
		if not valid then return false end
		assembly_count = next_count :: number; assembly_bytes = next_bytes :: number
	end
	if legacy_catalog_cache then
		if type(d.commands) ~= "table" or d.commands == tern.json.null or count(d.commands) > 4096 then return false end
		for key, command in d.commands do
			if not id(key) or not closed(command, "event result revision") or type(command.event) ~= "table" or command.event.request_id ~= key
				or (command.revision ~= nil and (not pos(command.revision) or command.revision > registry.revision))
				or (command.event.command_seq ~= nil and not pos(command.event.command_seq))
				or (command.event.kind ~= "dispatch" and command.event.kind ~= "dispatch_reconcile") or type(command.result) ~= "table"
				or command.result.ok ~= true or not str(command.result.code, 96) then return false end
			if command.event.command_seq ~= nil then
				local event = command.event
				local cursor = (d.command_cursors or {})[event.orch_session_id]
				if event.kind ~= "dispatch" or table.find({ "claim", "result", "lost" }, event.command) or not M.origin(event.origin)
					or event.origin.logical_session_id ~= event.orch_session_id or not cursor or event.command_seq > cursor.seq then return false end
			end
		end
	end
	for _, c in d.catalogs do if not catalog(c, legacy_catalog_cache) then return false end end
	-- The same explicit restore-boundary flag admits exactly-CP2 policies; M.restore migrates them.
	if not valid_rollovers(d, registry, legacy_catalog_cache) or not valid_landing(d, registry, legacy_catalog_cache) or not config.valid_deploys(d, registry) then return false end
	for _, r in d.rollovers or {} do if not valid_rollover_quota(d, r) then return false end end
	return valid_workflow(d, registry, legacy_catalog_cache)
end
-- Pre-cutover immutable grants must settle under their original policy interpretation.
-- This runs before restore validation and never changes a published byte.
function M.migration_problem(d: any, legacy_registry: boolean?): string?
	if type(d) ~= "table" then return nil end
	for _, a in d.actions or {} do
		if type(a) == "table" and type(a.request) == "table" and a.request.schema ~= 2 and a.phase ~= "complete" then
			return "Outstanding immutable managed request " .. tostring(a.request.request_id) .. " must drain under its original compatible pair; its bytes are never rewritten."
		end
	end
	local old = legacy_registry == true
	if type(d.policies) == "table" then
		for _, p in d.policies do if type(p) == "table" and p.enforce_cross_family ~= nil then old = true end end
	end
	if type(d.landing) ~= "table" or type(d.landing.items) ~= "table" then return nil end
	for _, item in d.landing.items do
		if type(item) ~= "table" or type(item.grants) ~= "table" then continue end
		for _, grant in item.grants do
			if type(grant) ~= "table" then continue end
			if (grant.result ~= nil and type(grant.result) ~= "table")
				or (grant.reconciliation ~= nil and type(grant.reconciliation) ~= "table") then continue end
			if landing_released(grant) or grant.reconciliation ~= nil
				or (grant.result ~= nil and grant.result.outcome ~= "uncertain" and grant.uncertain == nil) then continue end
			local incompatible = old
			if not incompatible and type(grant.bytes) == "string" then
				local raw = codec.strict_decode(grant.bytes, codec.LIMITS.logical)
				local payload = if type(raw) == "table" then raw.payload else nil
				if type(payload) == "table" and type(payload.proof) == "table"
					and payload.proof.mode ~= "review_disabled" and payload.proof.review_id ~= payload.review_id then incompatible = true end
			end
			if incompatible then
				return "Drain or reconcile outstanding immutable landing grant " .. tostring(grant.grant_id)
					.. " under the previous compatible ORCH+/SPAWN pair before upgrading. Its bytes were not rewritten."
			end
		end
	end
	return nil
end
function M.restore(d: any)
	if d == nil then return end
	config.upgrade_policies(d)
	-- A restored ready intention may have issued after this snapshot. It is not fresh work.
	-- Pre-join catalogs are validated at restore, then invalidated once. They
	-- cannot authorize new work; exact retained actions and workers survive.
	for sid, c in d.catalogs do if c.catalog_version ~= 2 then d.catalogs[sid] = nil end end
	-- USAGE evidence leases are at most minutes long; a restart always needs a fresh snapshot.
	d.capacity = nil
	for _, a in d.actions do
		if a.phase == "claimed" then a.phase = "uncertain"
		elseif a.phase == "ready" then a.phase = "held_ready" end
	end
	for _, r in d.rollovers or {} do if r.prepared then r.prepared.action.phase = "held_ready" end end
	for _, w in d.workers do
		w.continuation_required = true; refresh(d, w, nil)
	end
end
local function candidate(registry: any): any
	local n = table.clone(registry); n.dispatch = clone(registry.dispatch or fresh()); n.sessions = clone(registry.sessions); n.revision += 1; return n
end
local function finish_command(n: any, event: any, answer: any): (any, any)
	remember(n.dispatch, event, answer, n.revision)
	for _, worker in n.dispatch.workers do
		local entries = flow(worker).thread
		for i = #entries, 1, -1 do if entries[i].state == "settled" then table.remove(entries, i) end end
	end
	reclaim_gates(n.dispatch)
	if config.reclaim_rollovers then config.reclaim_rollovers(n.dispatch) end
	M.trim_summaries(n)
	local admitting = table.find({ "new_project", "project_reopen", "associate_conversation", "queue", "enrol", "source_request", "plan_import", "board_intake", "inbox_intake", "template_start" }, event.command) ~= nil
	if event.command == "answer" then
		local gate = n.dispatch.gates[event.gate_id]
		local worker = if gate then n.dispatch.workers[gate.worker_id] else nil
		local proposal = if gate and worker and gate.proposal then codec.decode_report(gate.proposal, worker) else nil
		admitting = proposal ~= nil and (proposal.payload.kind == "new_work" or proposal.payload.kind == "add_source")
	end
	local ceiling = config.AUTHORITY_BYTES - (if admitting then config.RETIREMENT_RESERVE else 0)
	if #tern.json.encode(n) > ceiling then return fail("capacity_reached", "Authority storage is full; existing work and retirement/recovery obligations were preserved.") end
	if not M.valid(n.dispatch, n) then return fail("invalid_candidate", "Dispatch transition did not produce a valid current-state candidate.") end
	return n, answer
end

local function bridge_control(n: any, event: any): (any?, any?)
	local session = n.sessions[event.orch_session_id]
	if not table.find({ "admit_session", "reconcile_session", "close_session" }, event.operation)
		or not codec.dispatch_compatibility_ready(event.compatibility)
		or not equal(event.compatibility, n.compatibility) then return fail("migration_blocked", "Both native stores must independently qualify the exact current pair.") end
	if session.bridge_control then return fail("control_pending", "Reconcile the current immutable control; do not replace an uncertain admission.") end
	if event.operation ~= "close_session" and session.phase ~= "open" then return fail("session_closing", "Closing fences admission and ordinary reconciliation.") end
	if event.operation == "admit_session" then
		if session.admitted then return result("already_admitted"), nil end
		if session.admission_seq ~= nil then return fail("admission_uncertain", "A previously issued admission must be observed, never silently replaced.") end
		session.admission_seq = n.next_admission_seq; n.next_admission_seq += 1
	elseif not session.admission_seq then return fail("admission_required", "No current admission exists to observe.") end
	if event.operation == "close_session" and (session.phase ~= "closing" or not session.close) then
		return fail("session_not_closing", "Begin the explicit close fence before contacting SPAWN.")
	end
	if event.operation == "close_session" then
		local problem = M.close_problem(n, event.orch_session_id)
		if problem or session.controller or session.orchestrator then return fail("close_pending", problem or "Release current owners before final peer closure.") end
	end
	local floor, consumed = M.ack_progress(n, event.orch_session_id)
	local control = if event.operation == "close_session" then clone(session.close.control_origin)
		else { kind = "active", binding = clone(event.origin), controller_pane = event.controller_pane }
	local request = { schema = 2, origin = "orchplus", op = event.operation,
		request_id = next_id(n.dispatch, "control-"), action_id = next_id(n.dispatch, "control-action-"),
		authority_namespace = n.authority_namespace, authority_revision = n.revision,
		logical_session_id = event.orch_session_id, admission_seq = session.admission_seq, control_origin = control,
		compatibility = clone(event.compatibility), generation_floor = session.generation_floor,
		next_request_serial = session.next_request_serial, settled_before = floor, consumed = consumed }
	if event.operation == "close_session" then request.close_id = session.close.close_id end
	if event.operation == "reconcile_session" then
		request.page_limit = 16; request.outstanding_cursor = clone(session.outstanding_cursor)
	end
	local bytes = tern.json.encode(request)
	local _, problem = codec.decode_dispatch_request(bytes)
	if problem then return nil, problem end
	session.bridge_control = { request = request, request_bytes = bytes }
	return result("control_queued", { operation = event.operation }), nil
end

local function bridge_result(n: any, event: any): (any?, any?)
	local session = n.sessions[event.orch_session_id]
	local intent = session.bridge_control
	if not intent or intent.request_bytes ~= event.query_bytes then return fail("stale_control", "Only the exact live control result can update admission.") end
	local body, problem = codec.decode_dispatch_response(event.response_bytes, intent.request)
	if problem then return nil, problem end
	if body.authority_revision < session.last_authority_revision then return fail("stale_revision", "Peer authority observation regressed.") end
	if body.category == "current_admission" then
		if not equal(body.payload.compatibility, n.compatibility) or body.spawn_namespace ~= n.compatibility.spawn_namespace then
			return fail("stale_authority", "A different peer cannot admit or reconcile this session.")
		end
		local peer = body.payload.control
		if session.phase == "open" and peer.phase ~= "open" then
			return fail("unknown_effect", "The peer has already fenced this admission for closure; an older open session cannot resume it.")
		end
		if peer.next_request_serial > session.next_request_serial or peer.request_floor > session.next_request_serial
			or peer.generation_floor > session.generation_floor or peer.last_authority_revision > intent.request.authority_revision then
			return fail("unknown_effect", "Peer remembers issued work absent from this restored authority; retain the current control for explicit recovery.")
		end
		for _, entry in (body.payload.outstanding or {}).entries or {} do
			if entry.request_serial >= session.next_request_serial then
				return fail("unknown_effect", "A peer outstanding serial is absent from the restored issue range; nothing was acknowledged or reissued.")
			end
		end
		session.admitted = true; session.spawn_namespace = body.spawn_namespace
		session.last_authority_revision = body.authority_revision
		session.request_floor = peer.request_floor
		for _, action in n.dispatch.actions do
			if action.request.origin_binding.logical_session_id == event.orch_session_id and action.retry_after_serial
				and (action.retry_after_serial < peer.request_floor or table.find(intent.request.consumed, action.retry_after_serial)) then
				action.retry_after_serial = nil
			end
		end
		if body.payload.outstanding then
			local page = body.payload.outstanding
			session.peer_outstanding = clone(page)
			session.outstanding_cursor = if page.complete then nil else { after_serial = page.next_after_serial, through_serial = page.through_serial }
		end
	elseif body.category == "admission_absent" and intent.request.op == "close_session" then
		if M.close_problem(n, event.orch_session_id) then return fail("close_pending", "Local obligations still prevent final close.") end
		session.close.peer_closed = true; session.admitted = nil
		session.peer_outstanding = nil; session.outstanding_cursor = nil
	elseif body.category == "admission_refused" and intent.request.op == "admit_session" then
		-- Definite pre-effect refusal is the only observation permitting a new admission sequence.
		session.admission_seq = nil; session.admitted = nil
	else
		return fail(body.category, (body.error or {}).message or "Current peer observation does not prove this control complete; reconcile without reissuing effects.")
	end
	session.bridge_control = nil
	return result("control_observed", { category = body.category, operation = intent.request.op }), nil
end
local function bridge_observe(n: any, event: any): (any?, any?)
	local session = n.sessions[event.orch_session_id]
	local query, invalid = codec.decode_dispatch_request(event.query_bytes)
	if invalid then return nil, invalid end
	if query.op ~= "owner_status" or query.authority_namespace ~= n.authority_namespace
		or query.logical_session_id ~= event.orch_session_id or query.admission_seq ~= session.admission_seq
		or not equal(query.origin_binding, event.origin) or query.controller_pane ~= event.controller_pane then
		return fail("binding_mismatch", "Observe this exact current admission through its native origin.")
	end
	local body, problem = codec.decode_dispatch_response(event.response_bytes, query)
	if problem then return nil, problem end
	if body.spawn_namespace ~= (n.compatibility or {}).spawn_namespace or body.authority_revision < session.last_authority_revision
		or not body.payload or not equal(body.payload.compatibility, n.compatibility) then
		return fail("stale_authority", "The fresh peer observation does not belong to this exact qualified pair.")
	end
	if body.category == "current_admission" then
		local peer = body.payload.control
		if session.phase == "open" and peer.phase ~= "open" then
			return fail("unknown_effect", "The peer has already fenced this admission for closure; an older open session cannot resume it.")
		end
		if peer.next_request_serial > session.next_request_serial or peer.request_floor > session.next_request_serial
			or peer.generation_floor > session.generation_floor or peer.last_authority_revision > event.expected_revision then
			return fail("unknown_effect", "The peer remembers state beyond this authority. No control, action or admission was replaced.")
		end
		local rebind = false
		if peer.binding and not equal(peer.binding, event.origin) then
			local retained = session.bridge_control and session.bridge_control.request
			local previous = retained and retained.control_origin
			local route = clone(peer.binding); route.window_epoch = event.origin.window_epoch
			local retained_route = if previous and previous.binding then clone(previous.binding) else nil
			if retained_route then retained_route.window_epoch = event.origin.window_epoch end
			if session.phase ~= "open" or not retained or retained.op ~= "reconcile_session"
				or not previous or previous.kind ~= "active" or previous.controller_pane ~= event.controller_pane
				or not equal(retained_route, event.origin) or not equal(route, event.origin)
				or peer.next_request_serial > retained.next_request_serial or peer.request_floor > retained.next_request_serial
				or peer.generation_floor > retained.generation_floor or peer.last_authority_revision > retained.authority_revision then
				return fail("unknown_effect", "The peer belongs to a different or unproven controller route. Its retained control was not replaced.")
			end
			-- A verified continuation may settle its exact old reconciliation, not inherit
			-- that window's admission. The current route still needs its own peer control.
			rebind = true
		end
		if session.phase == "closing" and (peer.phase ~= "closing" or peer.close_id ~= session.close.close_id) then
			return fail("close_pending", "The peer has not observed this exact close fence.")
		end
		session.admitted = if rebind then nil else true; session.spawn_namespace = body.spawn_namespace
		session.last_authority_revision = body.authority_revision
	elseif body.category == "admission_absent" and session.phase == "closing"
		and body.payload.admission_cursor >= session.admission_seq then
		if M.close_problem(n, event.orch_session_id) or session.controller or session.orchestrator then
			return fail("close_pending", "Local ownership and obligations must finish before consuming the absent peer admission.")
		end
		session.close.peer_closed = true; session.admitted = nil; session.peer_outstanding = nil; session.outstanding_cursor = nil
	else
		return fail("unknown_effect", "Missing admission is not first use and cannot authorize a replacement.")
	end
	session.bridge_control = nil
	return result("control_observed", { category = body.category, operation = "owner_status" }), nil
end
-- Quota routing of initial dispatch (plan §7; pure rule in quota.luau).
-- Stored USAGE evidence counts only when normalized against the current catalog join.
local function current_evidence(d: any, sid: string): any?
	local e, c = (d.capacity or {})[sid], d.catalogs[sid]
	if not e or not c or e.namespace ~= c.namespace or e.host_key ~= c.host_key or e.config_revision ~= c.config_revision then return nil end
	return e
end
local function routing_permitted(p: any, needs: string?, scope: string?): boolean
	if not p.quota_routing then return false end
	for part in (needs or ""):gmatch("[^,]+") do if p[(scope or "initial_dispatch") .. "_" .. part] ~= true then return false end end
	return true
end
local function remember_decision(d: any, w: any, phase: string, decision: any, p: any, now: number)
	local r, e = w.routing, current_evidence(d, w.logical_session_id)
	r.phase = phase; r.mode = if p.quota_routing then "quota" else "explicit"
	r.policy_digest = quota.policy_digest(p); r.decided_at_ms = now
	r.evidence_revision = if p.quota_routing and e then e.revision else nil
	r.auth_revision = if p.quota_routing and e then e.auth_revision else nil
	r.evidence_expires_at_ms = if p.quota_routing and e then e.expires_at_ms else nil
	r.reason = clone(decision.reason)
	local candidates = {}
	for index, c in decision.candidates do
		if index > quota.MAX_RECORDS + 1 then break end
		table.insert(candidates, { id = c.id, revision = c.revision, rank = c.rank, status = c.status, reason = c.reason,
			remaining_pct = c.remaining_pct, weekly_reset_ms = c.weekly_reset_ms, needs = c.needs, rejection = c.rejection })
	end
	r.candidates = candidates
	r.decision_digest = quota.digest({ policy = r.policy_digest, evidence = r.evidence_revision or "", requested = r.requested, bound = r.bound,
		outcome = phase, record = if decision.record then { id = decision.record.id, revision = decision.record.revision } else "", candidates = candidates })
	if decision.record then r.selector = quota.selector_state(decision.record) end
	table.insert(r.history, { at_ms = now, outcome = phase, decision_digest = r.decision_digest, evidence_revision = r.evidence_revision })
	while #r.history > 8 do table.remove(r.history, 1) end
end
-- One logical task slot across the orchestration, independent of quota routing. A reviewer uses
-- its builder's slot, and rollover generations share their work ID; neither can deadlock a full
-- four-task orchestration. Idle orchestrator/enrollment infrastructure is not an extra task.
function config.slot_id(d: any, w: any): string
	local review = if w.review_id then (d.reviews or {})[w.review_id] else nil
	return if review then review.builder_work_id else w.work_id
end
function config.concurrency_problem(d: any, sid: string, p: any, except: any): any?
	if p.concurrency_limit == 0 then return nil end
	local skip, eligible, occupied = {}, {}, {}
	for key in except do local w = d.workers[key]; if w then skip[config.slot_id(d, w)] = true end end
	for key, w in d.workers do
		if w.logical_session_id ~= sid or except[key] or w.role == "coordinator" or w.role == "release_manager"
			or w.open_conversation or w.enrol_delivery or w.stopped or w.mailbox_retired or w.finish or w.release or (w.workflow and w.workflow.exit) then continue end
		local slot = config.slot_id(d, w)
		if skip[slot] then continue end
		eligible[key] = slot
		local held = if w.routing then w.routing.reservation else nil
		if (held and RESERVATION_HELD[held.phase]) or w.pane_binding or w.phase == "provisioned" or w.phase == "awaiting_acceptance" then occupied[slot] = true end
	end
	for _, action in d.actions do
		local slot = if action.worker_id then eligible[action.worker_id] else nil
		if slot and action.phase ~= "complete" and action.phase ~= "resolved"
			and table.find({ "mailbox_provision", "launch", "adopt" }, action.request.op) then occupied[slot] = true end
	end
	local used = count(occupied)
	if used < p.concurrency_limit then return nil end
	return { code = "concurrency_limit", message = "This orchestration has " .. tostring(used) .. "/" .. tostring(p.concurrency_limit)
		.. " managed tasks. Added work remains held until a task reaches a completed safe boundary; held or uncertain launches keep their slot." }
end
local function reserve_slot(d: any, w: any, revision: number, now: number)
	local r = w.routing
	local held = r.reservation
	if held and RESERVATION_HELD[held.phase] then
		-- Rebinding before the claim keeps the ledger on the decision that will actually launch.
		if held.phase == "reserved" then held.decision_digest = r.decision_digest; held.evidence_revision = r.evidence_revision end
		return
	end
	r.reservation = { id = next_id(d, "reservation-"), phase = "reserved", decision_digest = r.decision_digest, evidence_revision = r.evidence_revision,
		history = { { phase = "reserved", revision = revision, at_ms = now } } }
end
-- Phase derived from durable worker/action evidence. Active occupancy ends only on verified stop or
-- mailbox retirement; an uncertain launch keeps occupancy; a definitive pre-pane failure releases.
local function reservation_phase(d: any, w: any): string
	local launch = d.actions[w.launch_action_id]
	if w.stopped or w.mailbox_retired or w.withdrawn then return "released" end
	if launch and launch.phase == "uncertain" then return "uncertain" end
	if w.pane_binding then return if w.phase == "accepted" then "active" else "launching" end
	if w.phase == "held" then return "released" end
	if launch and launch.phase == "claimed" then return "claimed" end
	if w.routing.phase ~= "selected" then return "released" end
	return "reserved"
end
local function sync_reservations(n: any, clock: any)
	local d, now = n.dispatch, stamp(clock).at_ms
	for _, w in d.workers do
		local held = if w.routing then w.routing.reservation else nil
		if held and held.phase ~= "released" then
			local phase = reservation_phase(d, w)
			if phase ~= held.phase then
				held.phase = phase
				table.insert(held.history, { phase = phase, revision = n.revision, at_ms = now })
				while #held.history > 8 do table.remove(held.history, 1) end
			end
		end
	end
end
-- Supersedes the open quota_fallback gate bound on `holder` (a worker's routing or a rollover's
-- quota state); `w` is the worker the gate sits on.
local function close_quota_gate(d: any, holder: any?, w: any)
	local g = if holder and holder.gate then (d.gates or {})[holder.gate.gate_id] else nil
	if g and gate_open(g) then g.phase = "superseded"; g.revision += 1; settle_entries(w, "gate_id", g.id) end
	if holder then holder.gate = nil end
end
local function tuple_text(t: any): string
	return t.id .. " rev " .. tostring(t.revision) .. " (provider " .. tostring(t.provider or "unset") .. ", account " .. tostring(t.account or "unset")
		.. (if t.profile then ", profile " .. t.profile else "") .. ", model " .. tostring(t.model or "unset") .. ")"
end
-- A denied fallback becomes a durable one-action owner gate on `w`, bound through `holder.gate` to
-- the routing policy revision, USAGE evidence revision, catalog revision and exact source/destination
-- tuples. An open gate for the same proposal stays; newer evidence keeps its question stable.
local function open_quota_gate(d: any, holder: any, w: any, binding: any, decision: any, question: string, evidence: { string }, weekly: boolean,
	approve: string, reject: string, clock: any): any?
	local existing = if holder.gate then (d.gates or {})[holder.gate.gate_id] else nil
	if existing and gate_open(existing) and holder.gate.policy_digest == binding.policy_digest and holder.gate.catalog_revision == binding.catalog_revision
		and holder.gate.denied == binding.denied and equal(holder.gate.from, binding.from) and equal(holder.gate.to, binding.to) then
		holder.gate.evidence_revision = binding.evidence_revision
		return nil
	end
	close_quota_gate(d, holder, w)
	for _, line in { "denied:" .. binding.denied, "policy:" .. binding.policy_digest, "usage_revision:" .. binding.evidence_revision,
		("from:" .. tuple_text(decision.from)):sub(1, 1024), ("to:" .. tuple_text(decision.to)):sub(1, 1024),
		"selector:" .. quota.selector_state(decision.record) .. " (SPAWN exposes no typed selector status; not enforced)" } do table.insert(evidence, line) end
	for _, c in decision.candidates do
		table.insert(evidence, ("candidate:" .. c.id .. " " .. c.status .. (if c.reason then " " .. c.reason else "")
			.. (if c.remaining_pct then " remaining " .. tostring(c.remaining_pct) .. "%" else "")
			.. (if weekly and c.weekly_reset_ms then " weekly_reset_ms " .. string.format("%.0f", c.weekly_reset_ms) else "")):sub(1, 1024))
	end
	local g, err = new_gate(d, w, "quota_fallback", question, { { id = "approve", label = approve }, { id = "reject", label = reject } }, evidence, clock)
	if err then return err end
	binding.gate_id = g.id; holder.gate = binding
	return nil
end
local function open_fallback_gate(d: any, w: any, decision: any, p: any, clock: any): any?
	local r = w.routing
	local e = current_evidence(d, w.logical_session_id)
	local binding = { policy_digest = quota.policy_digest(p), evidence_revision = e.revision, catalog_revision = d.catalogs[w.logical_session_id].revision,
		from = clone(decision.from), to = clone(decision.to), denied = decision.denied }
	local question = "Quota fallback for " .. w.work_id .. " (initial dispatch): " .. decision.reason.message .. " Approve " .. tuple_text(decision.to)
		.. " instead of " .. tuple_text(decision.from) .. " for this work only? Approval is bound to routing policy " .. binding.policy_digest:sub(1, 12)
		.. " and USAGE evidence " .. binding.evidence_revision:sub(1, 12) .. "; it never edits Config or authorizes later work. Reject keeps the work held."
	return open_quota_gate(d, r, w, binding, decision, question, { "operation:" .. (r.scope or "initial_dispatch"), "work:" .. w.work_id }, true,
		"Approve " .. decision.to.id .. " for this work only", "Reject — keep the work held", clock)
end
-- Coordinator/oversize checks and the provisioning action; the coordinator slot is reserved last,
-- after every check that could fail, so a refused reroute leaves no partial reservation.
local function prepare_launch(registry: any, n: any, w: any, coordinator: boolean, request_id: string, clock: any, reserve: any): (string?, any?)
	local d = n.dispatch
	if not config.worker_start_allowed(d, w) or w.checks_pending then return fail("project_held", "Project START and an unpaused orchestration are required before provisioning.") end
	if coordinator and (coordinator_rollover(d, w.logical_session_id) or restored_coordinator(d, w.logical_session_id)) then
		return fail("rollover_reserved", "A coordinator rollover owns this session's orchestrator slot, or a restored coordinator is unreconciled; an unrelated start cannot take the reservation.")
	end
	if M.request_size(launch_request(w, string.rep("h", 96))) > codec.DISPATCH.limit then
		return fail("oversize", "Assignment plus immutable launch binding cannot fit the 8192-byte bridge (including a maximum-length mailbox handle); no provisioning was queued.")
	end
	if coordinator then
		w.coordinator_protocol = 1; w.coordinator_owner_id = string.rep("o", 96); w.coordinator_generation = MAX
		local fits = M.request_size(launch_request(w, string.rep("h", 96))) <= codec.DISPATCH.limit
		w.coordinator_protocol = nil; w.coordinator_owner_id = nil; w.coordinator_generation = nil
		if not fits then return fail("oversize", "Assignment and reserved coordinator identity exceed the immutable launch bridge bound; no reservation or provision was committed.") end
	end
	local request, problem = config.provision(d, w, w.origin_binding, w.controller_pane)
	if not request then return nil, problem end
	if #tern.json.encode(request) > 8192 then return fail("oversize", "Provision request exceeds the bridge bound.") end
	if coordinator then
		local base = table.clone(n); base.revision = registry.revision
		local reserved, response = reserve(base, { kind = "reserve_coordinator", request_id = request_id .. "-reserve", orch_session_id = w.logical_session_id, work_id = w.work_id,
			authority_namespace = base.authority_namespace, expected_revision = base.revision }, clock)
		if reserved == nil then return nil, response end
		n.sessions = clone(reserved.sessions); n.next_owner_id = reserved.next_owner_id
		w.coordinator_owner_id = response.owner_id; w.coordinator_generation = response.generation
		w.coordinator_protocol = 1 -- Absent on old CP2 workers: never silently activate them.
		n.sessions[w.logical_session_id].orchestrator.managed_worker_id = w.worker_id
	end
	-- Frozen enrolment is provisioned before any launch grant exists.
	add(d, request, w.worker_id)
	if w.routing then w.routing.bound = true end
	return request.action_id, nil
end
-- Decide or re-decide one routed worker. Strict callers (queue, owner answer) surface errors;
-- background re-evaluation holds the work with the reason instead.
local function route(registry: any, n: any, w: any, clock: any, reserve: any, request_id: string, strict: boolean): (string?, any?)
	local d = n.dispatch
	local r, p, now = w.routing, policy(d, w.logical_session_id), stamp(clock).at_ms
	local scope = r.scope or "initial_dispatch"
	local decision = quota.decide({ policy = p, scope = scope, catalog = d.catalogs[w.logical_session_id], evidence = current_evidence(d, w.logical_session_id),
		requested = if r.bound then { id = w.record_id, revision = w.record_revision } else r.requested, coordinator = r.coordinator,
		cwd = w.cwd, placement = w.placement, execution_cwd = w.execution_cwd, presentation = w.presentation,
		manual = w.presentation == "user_new_tab" or w.presentation == "coordinator_adjacent", now_ms = now, bound = r.bound })
	if r.bound and r.switched and decision.outcome == "selected" then
		local still = if r.authority == "owner_gate" then p.quota_routing and r.authorized_digest == quota.policy_digest(p)
			else routing_permitted(p, r.needs, scope) and table.find(p[scope .. "_records"], w.record_id) ~= nil
		if not still then
			decision = { outcome = "held", candidates = decision.candidates, reason = { code = "policy_changed", message = "Config no longer authorizes the substituted record this work was provisioned for (quota routing off, permission removed, or the owner's fallback decision voided by a routing-policy edit). It stays held; nothing launches on another record." } }
		end
	end
	-- Configured concurrency comes after quota constraints (plan §7 line 317); a live reservation is kept.
	if decision.outcome == "selected" and not r.coordinator and not (r.reservation and RESERVATION_HELD[r.reservation.phase]) then
		local problem = config.concurrency_problem(d, w.logical_session_id, p, { [w.worker_id] = true })
		if problem then decision = { outcome = "held", candidates = decision.candidates, reason = problem } end
	end
	if decision.outcome == "selected" and not r.bound then
		local before_id, before_revision, before_cwd, before_placement = w.record_id, w.record_revision, w.cwd, w.placement
		w.record_id = decision.record.id; w.record_revision = decision.record.revision
		w.cwd = decision.record.cwd; w.placement = decision.record.placement; config.bind_family(d, w)
		local action_id, err = prepare_launch(registry, n, w, r.coordinator, request_id, clock, reserve)
		if err then
			w.record_id = before_id; w.record_revision = before_revision; w.cwd = before_cwd; w.placement = before_placement; config.bind_family(d, w)
			if strict and err.code ~= "waiting_for_agent_space" then return nil, err end
			decision = { outcome = "held", candidates = decision.candidates, reason = { code = err.code, message = err.message } }
		else
			close_quota_gate(d, r, w)
			r.switched = decision.switched == true; r.needs = if decision.switched then decision.needs else nil
			r.authority = decision.authority; r.selected = { id = w.record_id, revision = w.record_revision }
			remember_decision(d, w, "selected", decision, p, now)
			reserve_slot(d, w, n.revision, now)
			append(d, w, "routing", "Routing selected " .. w.record_id .. (if r.switched then " instead of " .. r.requested.id .. " (" .. tostring(r.authority) .. ")" else "")
				.. (if r.reason then ": " .. r.reason.message else ""), clock)
			return action_id, nil
		end
	end
	if decision.outcome == "selected" then
		-- Bound record still allowed and sufficient: rebind the decision to the newer evidence.
		if not r.switched then r.authority = decision.authority end
		r.selected = { id = w.record_id, revision = w.record_revision }
		remember_decision(d, w, "selected", decision, p, now)
		reserve_slot(d, w, n.revision, now)
		return nil, nil
	end
	if decision.outcome == "owner_gate" then
		remember_decision(d, w, "gated", decision, p, now)
		local err = open_fallback_gate(d, w, decision, p, clock)
		if not err then return nil, nil end
		if strict then return nil, err end
		decision = { outcome = "held", candidates = decision.candidates, reason = { code = err.code, message = err.message } }
	end
	close_quota_gate(d, r, w)
	if not r.bound then r.selected = nil; r.authority = nil end
	local previously_held = r.phase == "held" and #r.history > 0
	remember_decision(d, w, "held", decision, p, now)
	if not previously_held then
		append(d, w, "routing", "Routing held: " .. (if r.reason then r.reason.message else "no allowed record has sufficient fresh quota."), clock)
	end
	return nil, nil
end
-- Re-evaluate this controller's routed, not-yet-launched work after new evidence or a routing
-- policy edit. A claimed/settled launch is never re-decided; at most one coordinator start
-- reserves per command.
local function reroute(registry: any, n: any, event: any, clock: any, reserve: any): any?
	local d = n.dispatch
	local sid = event.orch_session_id
	local p = policy(d, sid)
	local digest_now, e = quota.policy_digest(p), current_evidence(d, sid)
	local ids = {}
	for key, w in d.workers do if w.routing and w.logical_session_id == sid then table.insert(ids, key) end end
	table.sort(ids)
	local coordinator_started = false
	for _, key in ids do
		local w = d.workers[key]; local r = w.routing
		local launch = d.actions[w.launch_action_id]
		if w.withdrawn or (launch and launch.phase ~= "ready") or (w.phase ~= "queued" and w.phase ~= "provisioned") then continue end
		if not equal(w.origin_binding, event.origin) or w.controller_pane ~= event.controller_pane then continue end
		if r.phase == "selected" and r.policy_digest == digest_now and (r.mode == "explicit" or (e ~= nil and r.evidence_revision == e.revision)) then continue end
		if r.coordinator and not r.bound and coordinator_started then continue end
		local was_bound = r.bound
		local _, err = route(registry, n, w, clock, reserve, event.request_id .. "-" .. key, false)
		if err then return err end
		if r.coordinator and not was_bound and r.bound then coordinator_started = true end
	end
	return nil
end
-- Claim-time recheck: routing policy unchanged and, for a quota-routed launch, USAGE confirmed the
-- exact decision revision current immediately before this claim. Stale evidence refreshes; it never launches.
local function routing_claim(d: any, w: any, event: any, op: string, clock: any): (any?, any?)
	local r, p = w.routing, policy(d, w.logical_session_id)
	if r.phase ~= "selected" then return fail("routing_held", if r.reason then r.reason.message else "Quota routing holds this work.") end
	if r.reservation and not RESERVATION_HELD[r.reservation.phase] then return fail("reservation_released", "This work's concurrency reservation was released; it is re-evaluated before any launch.") end
	if r.policy_digest ~= quota.policy_digest(p) then return fail("routing_stale", "Routing policy changed after this decision; refresh capacity so it is re-evaluated. Nothing was claimed.") end
	if op ~= "launch" or r.mode ~= "quota" then
		if event.capacity_validation ~= nil then return fail("invalid_command", "Capacity validation applies only to a quota-routed launch claim.") end
		return true, nil
	end
	local v, now = event.capacity_validation, stamp(clock).at_ms
	if not closed(v, "revision auth_revision status validated_at_ms expires_at_ms") or v.status ~= "current" or v.revision ~= r.evidence_revision
		or v.auth_revision ~= r.auth_revision or not pos(v.validated_at_ms) or not pos(v.expires_at_ms) or v.expires_at_ms <= now
		or v.validated_at_ms > now + quota.CLOCK_SKEW_MS or now - v.validated_at_ms > quota.VALIDATION_WINDOW_MS then
		return fail("capacity_refresh_required", "Launch needs USAGE to confirm, immediately before the claim, that evidence revision "
			.. tostring(r.evidence_revision):sub(1, 12) .. " used for this decision is still current. Refresh capacity; nothing launches on stale evidence.")
	end
	return { revision = v.revision, validated_at_ms = v.validated_at_ms, expires_at_ms = v.expires_at_ms }, nil
end
local function coordinator(n: any, w: any): any?
	local owner = n.sessions[w.logical_session_id].orchestrator
	if owner and owner.owner_id == w.coordinator_owner_id and owner.generation == w.coordinator_generation
		and owner.managed_worker_id == w.worker_id and (owner.phase == "running" or owner.phase == "retiring") then return owner end
	return nil
end
function config.cleanup_request(n: any, w: any, request: any): boolean
	if not w or not (w.stopped or (w.startup_cancelling and config.failed_startup(n, w))) or not w.mailbox_handle or w.mailbox_retired
		or request.op ~= "mailbox_retire" or request.mode ~= "retire" then return false end
	local session = n.sessions[w.logical_session_id]
	return session and session.admitted == true and (w.startup_cancelling or session.generation_floor >= control_origin(w).owner_generation)
		and session.controller and request.origin_binding.owner_id == session.controller.owner_id
		and request.origin_binding.owner_generation == session.controller.generation
		and (not w.coordinator_owner_id or not session.orchestrator or session.orchestrator.owner_id ~= w.coordinator_owner_id)
end
local function issue_reply(d: any, w: any, kind: string, payload: any, gate: any?): (any?, any?)
	if count(w.replies) >= 8 or w.reply_seq == MAX then return fail("full", "Unacknowledged reply capacity is full.") end
	local reply = { version = 1, message_id = next_id(d, "message-"), reply_seq = w.reply_seq + 1,
		action_id = next_id(d, "reply-action-"), action_revision = 1, kind = kind, payload = payload }
	for _, k in B do reply[k] = w[k] end
	if gate then reply.gate_id = gate.id; reply.gate_revision = gate.revision end
	local bytes = tern.json.encode(reply); local frames, err = codec.frame(bytes, "reply", w); if err then return nil, err end
	w.reply_seq = reply.reply_seq
	w.replies[tostring(reply.reply_seq)] = { bytes = bytes, sha256 = frames.message_sha256, frames = frames, part = 1,
		message_id = reply.message_id, reply_seq = reply.reply_seq, action_id = reply.action_id, action_revision = reply.action_revision, acknowledged = false }
	return { bytes = bytes, message_id = if kind == "owner_decision" or kind == "report_request" or kind == "landing_grant" or kind == "landing_refresh" or kind == "deploy_grant" or kind == "project_start" then reply.message_id else nil, action_id = reply.action_id, action_revision = reply.action_revision, reply_seq = reply.reply_seq,
		activation_token = payload.activation_token, acknowledged = false }, nil
end
-- START is an immutable owner decision, not a boolean launch shortcut. Only the exact
-- coordinator's accepted claim releases this captured membership; later additions stay held.
function config.start_worker_digest(w: any): string
	local value = {}
	for field in ("worker_id worker_generation work_id orch_project_id assignment_sha256 record_id record_revision prompt checks scope source files base_ref project_held checks_pending"):gmatch("%S+") do value[field] = w[field] end
	return quota.digest(value)
end
function config.start_source_digest(d: any, name: string, source: any): string
	local value = { logical_session_id = source.logical_session_id, orch_project_id = source.orch_project_id }
	if name == "plans" then
		value.plan_id = source.plan_id; value.path = source.path; value.plan_revision = source.plan_revision
		value.superseded = source.status == "superseded"
	elseif name == "intakes" then
		for field in ("intake_id kind ref path revision card_id text tags class"):gmatch("%S+") do value[field] = source[field] end
	else
		value.chain_id = source.chain_id; value.steps = {}
		for _, step in source.steps do table.insert(value.steps, { template_id = step.template_id, input = step.input,
			custom_fields = step.custom_fields, template = config.template_of(d, source.logical_session_id, step.template_id) }) end
	end
	return quota.digest(value)
end
function config.start_snapshot(d: any, p: any): any
	local snapshot = { workers = {}, plans = {}, intakes = {}, chains = {}, repository = quota.digest(p.repository or {}) }
	for _, name in { "plans", "intakes", "chains" } do
		for key, source in d[name] or {} do if source.orch_project_id == p.orch_project_id and source.held then snapshot[name][key] = config.start_source_digest(d, name, source) end end
	end
	for key, w in d.workers do if w.orch_project_id == p.orch_project_id and (w.checks_pending or (not p.started and w.project_held)) then snapshot.workers[key] = config.start_worker_digest(w) end end
	return snapshot
end
function config.start_snapshot_current(d: any, p: any, snapshot: any): boolean
	if snapshot.repository ~= quota.digest(p.repository or {}) then return false end
	for _, name in { "plans", "intakes", "chains" } do
		for key, proof in snapshot[name] do
			local source = (d[name] or {})[key]
			if not source or not source.held or source.orch_project_id ~= p.orch_project_id or config.start_source_digest(d, name, source) ~= proof then return false end
		end
	end
	for key, proof in snapshot.workers do
		local w = d.workers[key]
		if not w or w.orch_project_id ~= p.orch_project_id or config.start_worker_digest(w) ~= proof then return false end
	end
	return true
end
function config.find_start(d: any, w: any, report: any): (any?, any?)
	local p = (d.projects or {})[report.payload.orch_project_id]
	if not p or p.logical_session_id ~= w.logical_session_id then return nil, nil end
	local function matches(s: any): boolean
		if not s or s.coordinator.worker_id ~= w.worker_id or s.action_id ~= report.action_id or s.action_revision ~= report.action_revision then return false end
		local reply = codec.decode_reply(s.bytes, w)
		return reply ~= nil and equal(reply.payload, report.payload)
	end
	if matches(p.start) then return p, p.start end
	for _, prior in p.start_history or {} do if matches(prior) then return p, prior end end
	return nil, nil
end
function config.start_permanent_failure(n: any, p: any, s: any): any?
	if s.closed then return { code = s.closed.code, message = s.closed.message, retryable = false } end
	local session, w = n.sessions[p.logical_session_id], n.dispatch.workers[s.coordinator.worker_id]
	local owner, controller = session.orchestrator, session.controller
	if not owner or owner.owner_id ~= s.coordinator.owner_id or owner.generation ~= s.coordinator.owner_generation
		or owner.managed_worker_id ~= s.coordinator.worker_id or not controller or controller.owner_id ~= s.origin.owner_id
		or controller.generation ~= s.origin.owner_generation or not w or w.retirement or w.start_retirement or w.release or w.mailbox_retired
		or (w.activation and w.activation.activation_token ~= s.activation_token) then
		return { code = "start_owner_changed", message = "The original orchestrator or controller no longer owns this START.", retryable = false }
	end
	if p.finished or not config.start_snapshot_current(n.dispatch, p, s.snapshot) then
		return { code = "start_subject_changed", message = "The approved project or source changed. This START cannot release changed work.", retryable = false }
	end
	return nil
end
function config.start_in_flight(d: any, s: any): boolean
	local publication = if s.publication then codec.decode_dispatch_request(s.publication.request_bytes) else nil
	for _, a in d.actions do
		if a.worker_id == s.coordinator.worker_id and ((a.request.op == "mailbox_publish_reply" and a.request.reply_seq == s.reply_seq and a.request.message_id == s.message_id)
			or (publication and a.request.op == "native_wake" and a.request.target_action_id == publication.action_id)) then return true end
	end
	return false
end
function config.start_owner_closed(n: any, p: any, s: any): boolean
	local session, w = n.sessions[p.logical_session_id], n.dispatch.workers[s.coordinator.worker_id]
	local owner = session.orchestrator
	return s.published and w ~= nil and w.stopped ~= nil and w.mailbox_retired == true
		and session.orchestrator_generation >= s.coordinator.owner_generation
		and (not owner or owner.owner_id ~= s.coordinator.owner_id or owner.generation ~= s.coordinator.owner_generation)
		and not config.start_in_flight(n.dispatch, s)
end
function config.close_start(n: any, p: any, s: any, failure: any, report_bytes: string?)
	if not s.closed then s.closed = { code = failure.code, message = failure.message, revision = n.revision } end
	if config.start_owner_closed(n, p, s) then s.closed.retired = true end
	if report_bytes then s.closed.report_bytes = report_bytes end
	s.failure = { code = s.closed.code, message = s.closed.message, retryable = false }
end
function config.start_replaceable(n: any, p: any, s: any): boolean
	return s.closed ~= nil and ((s.published and s.acknowledged) or (s.closed.retired and config.start_owner_closed(n, p, s)))
		and not config.start_in_flight(n.dispatch, s)
end
function config.close_stale_starts(n: any)
	for _, p in n.dispatch.projects or {} do
		for _, prior in p.start_history or {} do
			if prior.closed and not prior.closed.retired and config.start_owner_closed(n, p, prior) then prior.closed.retired = true end
		end
		local s = p.start
		if s and s.closed and not s.closed.retired and config.start_owner_closed(n, p, s) then s.closed.retired = true end
		if s and not s.claim and not s.closed and s.published and (s.acknowledged or config.start_owner_closed(n, p, s)) and not config.start_in_flight(n.dispatch, s) then
			local failure = config.start_permanent_failure(n, p, s)
			if failure then config.close_start(n, p, s, failure, nil) end
		end
	end
end
function config.start_for_action(d: any, a: any): any?
	if not a or a.request.op ~= "mailbox_publish_reply" then return nil end
	for _, p in d.projects or {} do
		local s = p.start
		if s and not s.claim and s.coordinator.worker_id == a.worker_id and s.reply_seq == a.request.reply_seq
			and s.message_id == a.request.message_id then return s end
	end
	return nil
end
function config.start_projection(d: any, p: any, registry: any): any?
	local s = p.start
	if not s then return nil end
	local out = { start_id = s.start_id, project_revision = s.project_revision, coordinator = clone(s.coordinator),
		action_id = s.action_id, action_revision = s.action_revision, decision_context = s.decision_context, source = clone(s.source),
		state = if s.claim then "claimed" elseif s.acknowledged then "delivered" elseif s.published then "queued" else "publishing" }
	if s.claim then return out end
	out.closed = s.closed ~= nil; out.restartable = config.start_replaceable(registry, p, s)
	local owner = registry.sessions[p.logical_session_id].orchestrator
	local w = d.workers[s.coordinator.worker_id]
	local controller = registry.sessions[p.logical_session_id].controller
	local code, message, retryable
	if not owner or owner.owner_id ~= s.coordinator.owner_id or owner.generation ~= s.coordinator.owner_generation
		or owner.managed_worker_id ~= s.coordinator.worker_id or owner.phase ~= "running"
		or not w or w.retirement or w.release or not w.activation or w.activation.activation_token ~= s.activation_token
		or not controller or controller.owner_id ~= s.origin.owner_id or controller.generation ~= s.origin.owner_generation then
		code, message, retryable = "start_owner_unavailable", "The original coordinator is not running. START remains held; inspect its retained ownership.", false
	elseif not config.start_snapshot_current(d, p, s.snapshot) then
		code, message, retryable = "start_subject_changed", "Approved source or member content changed. The original START cannot release changed work.", false
	elseif s.failure then
		code, message, retryable = s.failure.code, s.failure.message, s.failure.retryable
	end
	for _, a in d.actions do if config.start_for_action(d, a) == s then
		out.delivery_action_id = a.request.action_id; out.delivery_state = a.phase
		if not code then
			if a.phase == "uncertain" then code, message, retryable = "start_publication_uncertain", "Inspect the original delivery status. Uncertainty never authorizes another publication or native wake.", false
			elseif a.phase == "backpressure" then code, message, retryable = "start_delivery_refused", "Delivery was refused before effects. Retry delivery keeps the original START action and bytes.", true end
		end
	end end
	if code then out.state = "failed"; out.failure = { code = code, message = message, retryable = retryable } end
	return out
end
function config.valid_project_start(d: any, p: any, prior: any?, registry: any): boolean
	local s = prior or p.start
	if not closed(s, "start_id project_revision decision_context coordinator origin controller_pane snapshot bytes message_id action_id action_revision reply_seq activation_token acknowledged ack_seq ack_sha256 published publication claim failure source closed")
		or not id(s.start_id) or not pos(s.project_revision) or s.project_revision > p.revision or not digest(s.decision_context)
		or not closed(s.coordinator, "owner_id owner_generation worker_id") or not id(s.coordinator.owner_id)
		or not pos(s.coordinator.owner_generation) or not id(s.coordinator.worker_id) or not M.origin(s.origin)
		or s.origin.logical_session_id ~= p.logical_session_id or not str(s.controller_pane, 96)
		or type(s.published) ~= "boolean" or type(s.acknowledged) ~= "boolean"
		or not closed(s.snapshot, "workers plans intakes chains repository") or not digest(s.snapshot.repository) then return false end
	if not closed(s.source, "kind rule policy_revision") or (s.source.kind ~= "owner" and s.source.kind ~= "policy")
		or (s.source.kind == "owner" and (s.source.rule ~= nil or s.source.policy_revision ~= nil))
		or (s.source.kind == "policy" and (s.source.rule ~= "auto_start_projects" or not digest(s.source.policy_revision))) then return false end
	for _, name in { "workers", "plans", "intakes", "chains" } do
		if type(s.snapshot[name]) ~= "table" or s.snapshot[name] == tern.json.null then return false end
		for key, proof in s.snapshot[name] do if not id(key) or not digest(proof) then return false end end
	end
	local w = d.workers[s.coordinator.worker_id]
	local reply = if w then codec.decode_reply(s.bytes, w) else nil
	local retired = s.closed and s.closed.retired and registry and config.start_owner_closed(registry, p, s)
	local delivery = w and reply and (valid_delivery(s, w, reply, "project_start") or (retired and reply.message_id == s.message_id
		and reply.reply_seq == s.reply_seq and reply.action_id == s.action_id and reply.action_revision == s.action_revision and s.reply_seq <= w.reply_seq))
	if not delivery or reply.payload.owner_id ~= s.coordinator.owner_id
		or reply.payload.owner_generation ~= s.coordinator.owner_generation or reply.payload.activation_token ~= s.activation_token
		or reply.payload.orch_project_id ~= p.orch_project_id or reply.payload.project_revision ~= s.project_revision
		or reply.payload.decision_context ~= s.decision_context then return false end
	if s.published ~= (s.publication ~= nil) then return false end
	if s.publication then
		if not closed(s.publication, "request_bytes response_bytes") then return false end
		local request = codec.decode_dispatch_request(s.publication.request_bytes)
		local response = if request then protocol.decode_response(s.publication.response_bytes, request) else nil
		local frames = codec.frame(s.bytes, "reply", w)
		if not request or not response or not frames or request.op ~= "mailbox_publish_reply" or request.part ~= "manifest"
			or request.worker_id ~= w.worker_id or request.worker_generation ~= w.worker_generation or request.handle ~= w.mailbox_handle
			or request.message_id ~= s.message_id or request.reply_seq ~= s.reply_seq or request.action_revision ~= s.action_revision
			or request.reply_sha256 ~= codec.sha256(s.bytes) or request.object_sha256 ~= codec.sha256(frames.manifest)
			or request.object_b64 ~= tern.base64.encode(frames.manifest) or response.category ~= "current_result"
			or (response.status ~= "published" and response.status ~= "already_published") then return false end
	end
	if s.failure ~= nil and (not closed(s.failure, "code message retryable") or not id(s.failure.code)
		or not str(s.failure.message, 1024) or type(s.failure.retryable) ~= "boolean") then return false end
	if s.closed then
		if s.claim or not closed(s.closed, "code message revision report_bytes retired") or not id(s.closed.code) or not str(s.closed.message, 1024)
			or not pos(s.closed.revision) or (s.closed.retired ~= nil and (s.closed.retired ~= true or not retired)) then return false end
		if s.closed.report_bytes then
			local report = codec.decode_report(s.closed.report_bytes, w)
			if not report or report.kind ~= "PROJECT_START_CLAIM" or report.seq > w.accepted_seq or report.action_id ~= s.action_id
				or report.action_revision ~= s.action_revision or not equal(report.payload, reply.payload) then return false end
		end
	end
	if s.claim then
		local report = codec.decode_report(s.claim, w)
		if not s.published or not s.acknowledged or not report or report.kind ~= "PROJECT_START_CLAIM" or report.seq > w.accepted_seq
			or report.action_id ~= s.action_id or report.action_revision ~= s.action_revision or not equal(report.payload, reply.payload) then return false end
	end
	return true
end
function config.release_start(d: any, p: any, snapshot: any, event: any, clock: any): (any?, any?)
	for key in snapshot.workers do
		local w = d.workers[key]
		if w.checks_pending then
			if not w.launch_gates and not w.open_conversation and not w.enrol_delivery then
				local gates, problem = config.queue_gates(d, w, clock)
				if problem then return nil, problem end
				if gates then w.launch_gates = gates end
			end
			w.checks_pending = nil
		end
		config.start_unissued(d, w, event)
	end
	for _, name in { "plans", "intakes", "chains" } do
		for key in snapshot[name] do d[name][key].held = nil end
	end
	p.started = true; p.checks_pending = nil; p.revision += 1
	-- New held additions are deliberately not part of this approval.
	for _, w in d.workers do if w.orch_project_id == p.orch_project_id and w.checks_pending then p.checks_pending = true end end
	for _, plan in d.plans or {} do if plan.orch_project_id == p.orch_project_id and plan.held then
		for _, cp in plan.checkpoints do for _, task in cp.tasks do if #task.checks > 0 then p.checks_pending = true end end end
	end end
	return true, nil
end
function config.issue_project_start(n: any, p: any, w: any, snapshot: any, context: string, event: any, source: any): (any?, any?)
	local owner = n.sessions[p.logical_session_id].orchestrator
	if p.start and p.start.closed and not config.start_replaceable(n, p, p.start) then return fail("start_pending", "The previous START still has an unsettled delivery.") end
	if p.start and p.start.closed and #(p.start_history or {}) >= 32 then return fail("full", "Retained START history is full; finish this project before adding more START decisions.") end
	local start, problem = issue_reply(n.dispatch, w, "project_start", { owner_id = owner.owner_id, owner_generation = owner.generation,
		activation_token = w.activation.activation_token, orch_project_id = p.orch_project_id,
		project_revision = p.revision, decision_context = context })
	if not start then return nil, problem end
	start.start_id = next_id(n.dispatch, "project-start-"); start.project_revision = p.revision; start.decision_context = context
	start.coordinator = { owner_id = owner.owner_id, owner_generation = owner.generation, worker_id = w.worker_id }
	start.origin = clone(event.origin); start.controller_pane = event.controller_pane; start.snapshot = snapshot; start.published = false
	start.source = clone(source)
	if p.start and p.start.closed then
		p.start_history = p.start_history or {}; table.insert(p.start_history, p.start)
	end
	p.start = start
	if not p.started then
		for key, other in n.dispatch.workers do if other.orch_project_id == p.orch_project_id and other.project_held and not snapshot.workers[key] then
			other.checks_pending = true -- Unapproved held members stay outside this narrower source decision.
		end end
	end
	return start, nil
end
function config.ruling_command(n: any, event: any): (any?, any?)
	local d = n.dispatch
	if event.command == "associate_document" then
		local w = d.workers[event.worker_id]
		if not w or w.logical_session_id ~= event.orch_session_id or not rulings.absolute(event.path)
			or type(event.evidence) ~= "table" or event.evidence.existing ~= true then
			return fail("document_missing", "Select an existing document verified by this authority; no document is created.")
		end
		for _, g in d.gates or {} do if g.worker_id == w.worker_id and g.ruling then return fail("ruling_pending", "Finish the current document obligation before changing its association.") end end
		w.ruling_document = { path = event.path, selected_by = "owner", existing = true }
		return result("document_associated"), nil
	end
	local g = (d.gates or {})[event.gate_id]
	if not g or g.logical_session_id ~= event.orch_session_id or g.revision ~= event.gate_revision or not g.ruling then
		return fail("stale_gate", "This exact current document obligation is required.")
	end
	if event.command == "ruling_remote" then
		if g.ruling_delivery then return fail("write_in_flight", "The exact remote writer already holds this one-shot intent; receipt is not completion.") end
		local w = d.workers[event.worker_id]
		if not w or w.phase ~= "accepted" or w.continuation_required or w.mailbox_retired then return fail("writer_unproved", "An existing currently authorized writer is required.") end
		local payload, problem = rulings.remote_payload(g.ruling, w)
		if problem then return nil, problem end
		local delivery, err = issue_reply(d, w, "record_ruling", payload, g)
		if err then return nil, err end
		g.ruling_delivery = { worker_id = w.worker_id, reply_seq = delivery.reply_seq, action_id = delivery.action_id }
		return result("ruling_queued"), nil
	end
	if type(event.evidence) ~= "table" or not rulings.valid_writer(event.writer) then return fail("writer_unproved", "Fresh native buffer and authority disk observations are required.") end
	if g.ruling.intent and not rulings.same_writer(g.ruling.intent.writer, event.writer)
		and event.command ~= "ruling_reissue" then
		if event.command ~= "ruling_observe" or not rulings.same_writer(g.ruling.intent.writer, event.evidence.previous_writer)
			or event.evidence.writer_ended ~= true or event.evidence.no_write_can_complete ~= true then
			return fail("writer_unproved", "Only the original writer, or a fresh observer proving that exact writer ended with no possible late write, may settle this intent.")
		end
	end
	local outcome, problem
	if event.command == "ruling_prepare" then
		local obligations = {}
		for _, gate in d.gates do if gate.ruling then table.insert(obligations, gate.ruling) end end
		outcome, problem = rulings.prepare(g.ruling, obligations, event.writer, event.evidence)
	elseif event.command == "ruling_observe" then
		outcome, problem = rulings.observe(g.ruling, event.evidence)
		if outcome then
			-- The outbox remains the live transport obligation until its normal reply ACK settles.
			g.ruling = nil; g.ruling_delivery = nil
			return result("ruling_recorded"), nil
		end
	elseif event.command == "ruling_reissue" then
		outcome, problem = rulings.reissue(g.ruling, event.evidence)
		if outcome then g.ruling_delivery = nil end
	else return fail("invalid_command", "Unknown document obligation operation.") end
	return result(if problem then problem.code else "ruling_pending", { gate_id = g.id, state = g.ruling.state,
		edit = if event.command == "ruling_prepare" then outcome else nil, message = if problem then problem.message else nil }), nil
end
local function deliveries_settled(w: any): boolean
	return w.compacted_floor == w.accepted_seq and w.reply_floor == w.reply_seq
		and not w.accept_pending and not w.assembly and not w.rejected_report
		and not next(w.receipts) and not next(w.replies) and not next(w.wakes or {})
end
local function settled(w: any): boolean
	local finish = w.release or w.finish
	return finish ~= nil and w.compacted_floor >= finish.seq and deliveries_settled(w)
end
-- Explicitly withdrawn STARTs are not consumed replies. This separate retirement seam never
-- weakens ordinary settlement or advances either producer/consumer floor.
function config.valid_start_retirement(w: any): boolean
	local intent = w.start_retirement
	if not closed(intent, "owner_id owner_generation revision origin pane_binding starts originals retirement")
		or intent.owner_id ~= w.coordinator_owner_id or intent.owner_generation ~= w.coordinator_generation
		or not pos(intent.revision) or not equal(intent.origin, control_origin(w)) or not equal(intent.pane_binding, control_binding(w))
		or not dense(intent.starts, 8, 1) or not dense(intent.originals, 8, #intent.starts)
		or #intent.originals ~= #intent.starts or not w.activation
		or not table.find(w.capabilities or {}, "coordinator-control-v1") or not table.find(w.capabilities or {}, "project-start-v1") then return false end
	local previous = 0
	for index, entry in intent.starts do
		local bytes = intent.originals[index]
		local reply = if type(bytes) == "string" then codec.decode_reply(bytes, w) else nil
		if not closed(entry, "reply_seq message_id message_sha256") or not pos(entry.reply_seq) or not reply or reply.kind ~= "project_start"
			or entry.reply_seq <= previous or entry.reply_seq ~= reply.reply_seq or entry.message_id ~= reply.message_id
			or entry.message_sha256 ~= codec.sha256(bytes) or reply.payload.owner_id ~= intent.owner_id
			or reply.payload.owner_generation ~= intent.owner_generation or reply.payload.activation_token ~= w.activation.activation_token then return false end
		previous = entry.reply_seq
	end
	if intent.retirement ~= nil then
		local proof = intent.retirement
		if not closed(proof, "request_bytes response_bytes") or type(proof.request_bytes) ~= "string" or type(proof.response_bytes) ~= "string" then return false end
		local request = codec.decode_dispatch_request(proof.request_bytes)
		local response = if request then protocol.decode_response(proof.response_bytes, request) else nil
		if not request or not response or request.op ~= "mailbox_retire" or request.mode ~= "retire" or response.status ~= "retired"
			or request.handle ~= w.mailbox_handle or request.worker_id ~= w.worker_id or request.worker_generation ~= w.worker_generation
			or request.launch_request_id ~= w.launch_request_id or request.work_id ~= w.work_id or request.expected_generation ~= w.worker_generation
			or request.enrolment_token ~= w.enrolment_token or not w.stopped or w.mailbox_retired ~= true
			or request.reply_floor > w.reply_floor or request.report_floor > w.compacted_floor then return false end
		local expected = {}
		for _, original in intent.starts do if original.reply_seq > request.reply_floor then table.insert(expected, original) end end
		if not equal(request.withdrawn_starts or {}, expected) then return false end
	end
	return true
end
function config.start_retirement_tail(d: any, w: any, candidate: boolean?): (any?, any?)
	if not w.coordinator_owner_id or not w.activation or not w.activation.acknowledged or w.phase ~= "accepted"
		or not table.find(w.capabilities or {}, "coordinator-control-v1") or not table.find(w.capabilities or {}, "project-start-v1")
		or w.compacted_floor ~= w.accepted_seq or w.accept_pending or w.assembly or w.rejected_report or w.read_selector
		or next(w.receipts) or next(w.wakes or {}) or flow(w).report_request or work_referenced(d, w, true) then return nil, nil end
	local entries, originals = {}, {}
	for seq = w.reply_floor + 1, w.reply_seq do
		local retained = w.replies[tostring(seq)]
		local reply = if retained then codec.decode_reply(retained.bytes, w) else nil
		if not retained or retained.part ~= #retained.frames.chunks + 2 or retained.acknowledged or not reply or reply.kind ~= "project_start" then return nil, nil end
		local entry = { reply_seq = seq, message_id = reply.message_id, message_sha256 = codec.sha256(retained.bytes) }
		if candidate then
			local project = d.projects[reply.payload.orch_project_id]
			local start = if project then project.start else nil
			if not start or start.bytes ~= retained.bytes or not start.published or start.claim or config.start_in_flight(d, start) then return nil, nil end
		else
			local found = false
			for index, original in w.start_retirement.starts do
				if equal(original, entry) and w.start_retirement.originals[index] == retained.bytes then found = true end
			end
			if not found then return nil, nil end
		end
		table.insert(entries, entry); table.insert(originals, retained.bytes)
	end
	if #entries > 8 or (candidate and #entries == 0) then return nil, nil end
	return entries, originals
end
function config.start_retirement_settled(d: any, w: any, ignore_action: string?): boolean
	if not w.start_retirement or not config.valid_start_retirement(w) then return false end
	for key, action in d.actions do
		if action.worker_id == w.worker_id and key ~= ignore_action and action.phase ~= "complete" then return false end
	end
	return config.start_retirement_tail(d, w) ~= nil
end
function config.start_retirement_ready(n: any, w: any, clock: any): boolean
	if w.start_retirement or w.retirement or w.release or w.continuation_required or w.stopped or w.mailbox_retired then return false end
	local owner = coordinator(n, w)
	if not owner or owner.phase ~= "running" or owner.pending_executors ~= 0 or M.unresolved(n, w.logical_session_id, owner.owner_id)
		or restored_coordinator(n.dispatch, w.logical_session_id) then return false end
	for _, action in n.dispatch.actions do if action.worker_id == w.worker_id and action.phase ~= "complete" then return false end end
	-- Projection is only an affordance; the command refreshes against the real host clock.
	if clock ~= nil then refresh(n.dispatch, w, clock) end
	local f = w.workflow
	if not f or not f.health or (f.health.native_state ~= "idle" and f.health.native_state ~= "exited") then return false end
	if not f.native or f.native.delivery_error or (f.native.state ~= "idle" and f.native.state ~= "exited") then return false end
	return config.start_retirement_tail(n.dispatch, w, true) ~= nil
end
function M.start_retirement_complete(registry: any, w: any): boolean
	return w.start_retirement ~= nil and w.start_retirement.retirement ~= nil and config.valid_start_retirement(w)
end
-- The existing exact mailbox retirement and compaction grants, shared by poll and the nightly sweep.
local function mailbox_request(n: any, d: any, w: any, mode: string): any
	local request = worker_request(d, w, "mailbox_retire")
	request.mode = mode; request.settlement_revision = if mode == "retire" then n.revision else w.compaction_pending; request.report_floor = w.compacted_floor
	request.report_chain_sha256 = w.compacted_chain; request.reply_floor = w.reply_floor; request.grant_id = next_id(d, mode .. "-")
	if mode == "retire" and w.start_retirement then
		local tail = config.start_retirement_tail(d, w)
		if tail and #tail > 0 then request.withdrawn_starts = clone(tail) end
	end
	if mode == "retire" then w.mailbox_retire_action_id = request.action_id; w.retirement_refused = nil end
	return request
end
-- A live mailbox obligation after a definite SPAWN refusal: either a stopped generation's
-- producer_unsettled result or an unused mailbox's rejected withdrawal retirement. The grant
-- is consumed; uncertainty or a failed mutation never establishes this retryable refusal.
local function retirement_refused(d: any, w: any): boolean
	return w.retirement_refused == true
end
-- Deterministic sweep rule. Retire only a provably stopped, settled, unreferenced generation
-- through its current control route; compact a live one with pending compaction; keep the rest
-- with a reason. It never stops a worker or infers a stop.
local function sweep_decision(n: any, d: any, w: any, origin: any): (string, string)
	if w.mailbox_retired then return "none", "retired" end
	if w.continuation_required or not equal(control_origin(w), origin) then return "keep", "continuation_required" end
	for _, a in d.actions do if a.worker_id == w.worker_id and a.phase == "uncertain" then return "keep", "uncertain" end end
	if w.mailbox_retire_action_id and not retirement_refused(d, w) then return "keep", "retirement_pending" end
	if pending(d, w) then return "keep", "effect_pending" end
	if w.coordinator_owner_id and not coordinator(n, w) then return "keep", "owner_unresolved" end
	if w.rejected_report then return "keep", "report_held" end
	if w.phase == "held" then return "keep", "held" end
	if not w.pane_binding then return "keep", "unlaunched" end
	if not w.stopped then
		if w.compaction_pending then return "compact", "compaction_pending" end
		return "keep", if w.finish or w.release then "finishing" else "live"
	end
	if not settled(w) then return "keep", "unsettled" end
	if work_referenced(d, w) then return "keep", "referenced" end
	local owner = if w.coordinator_owner_id then coordinator(n, w) else nil
	if owner and (owner.pending_executors ~= 0 or M.unresolved(n, w.logical_session_id, owner.owner_id)) then return "keep", "owner_unresolved" end
	return "retire", "stopped_settled"
end
-- One durable run per session and scheduled local day; decisions queue only the existing actions.
local function run_sweep(n: any, event: any, clock: any): (any?, any?)
	local d, sid = n.dispatch, event.orch_session_id
	if not policy(d, sid).sweep_enabled then return fail("sweep_disabled", "The nightly mailbox sweep is turned off in Config.") end
	if not sweep_date(event.local_date) or (event.catch_up ~= nil and type(event.catch_up) ~= "boolean") then
		return fail("invalid_command", "A sweep names its scheduled local date (YYYY-MM-DD).")
	end
	local log = (d.sweeps or {})[sid]
	if log and log.last_date >= event.local_date then
		return fail("sweep_already_ran", "The sweep for " .. log.last_date .. " already ran; at most one run per scheduled local day.")
	end
	local ids = config.sorted_keys(d.workers, function(_, w) return w.logical_session_id == sid and w.mailbox_handle end)
	local run: any = { local_date = event.local_date, revision = n.revision, at_ms = stamp(clock).at_ms, catch_up = event.catch_up == true,
		decisions = {}, more = 0, retire = 0, compact = 0, keep = 0, none = 0 }
	for _, key in ids do
		local w = d.workers[key]
		local decision, reason = sweep_decision(n, d, w, event.origin)
		local action_id: string? = nil
		if decision == "retire" or decision == "compact" then
			local request = mailbox_request(n, d, w, decision)
			if add(d, request, w.worker_id) then action_id = request.action_id
			else
				if decision == "retire" then w.mailbox_retire_action_id = nil end
				decision, reason = "keep", "oversize"
			end
		end
		run[decision] += 1
		if #run.decisions < SWEEP_DECISIONS then
			table.insert(run.decisions, { worker_id = key, work_id = w.work_id, decision = decision, reason = reason, action_id = action_id })
		else run.more += 1 end
	end
	local runs = if log then clone(log.runs) else {}
	table.insert(runs, run)
	while #runs > SWEEP_RUNS do table.remove(runs, 1) end
	d.sweeps = d.sweeps or {}
	d.sweeps[sid] = { last_date = event.local_date, runs = runs }
	return result("sweep_recorded", { local_date = event.local_date, retire = run.retire, compact = run.compact, keep = run.keep }), nil
end
local function sendable(d: any, w: any, clock: any): boolean
	refresh(d, w, clock)
	if type(clock) == "table" and clock.epoch then
		local f = flow(w); local native = f.health.native_state
		if (f.native and f.native.delivery_error) or (native ~= "idle" and not (native == "unknown" and table.find(w.capabilities or {}, "worker-poll-v1"))) then return false end
	end
	return true
end
local function thread_room(w: any): boolean
	local entries = flow(w).thread
	if #entries < 128 then return true end
	return false
end
-- Compare every local session in this authority, not just the requesting session.
-- Git CHECKOUT facts identify aliases; literal cwd overlap remains a conservative pre-launch warning.
config.VISIBILITY = " All local ORCH+ sessions in this authority are checked; other machines/data directories and unmanaged agents are not."
function config.live_peers(d: any, w: any): any
	local peers = {}
	local host = (w.checkout or {}).host_key or (d.catalogs[w.logical_session_id] or {}).host_key
	for key, o in d.workers do
		local other_host = (o.checkout or {}).host_key or (d.catalogs[o.logical_session_id] or {}).host_key
		-- A stop request is not proof of exit. Missing host evidence cannot prove independent checkouts.
		if key ~= w.worker_id and (host == nil or other_host == nil or host == other_host)
			and o.role ~= "coordinator" and o.role ~= "reviewer" and o.role ~= "labeller" and o.coordinator_owner_id == nil
			and not o.stopped and not o.mailbox_retired and not (o.workflow and o.workflow.exit) then table.insert(peers, o) end
	end
	table.sort(peers, function(a: any, b: any): boolean return a.worker_id < b.worker_id end)
	return peers
end
function config.rooted(d: any, w: any, path: string): string?
	local p = policy(d, w.logical_session_id)
	if p.track_checkout_roots and w.checkout and rules.path_within(w.checkout.worktree_path, path) then return rules.normalize_path(w.checkout.worktree_path) end
	for _, root in p.checkout_roots do if rules.path_within(root, path) then return rules.normalize_path(root) end end
	return nil
end
-- Exact/ancestor index over literal paths; globs compare pairwise by literal prefix.
function config.path_index(list: any): any
	local index = { exact = {}, ancestors = {}, globs = {} }
	for _, entry in list or {} do
		local p = rules.normalize_path(entry)
		if p:find("[%*%?%[{]") then table.insert(index.globs, p)
		else
			index.exact[p] = entry
			local slash = p:find("/", 2, true)
			while slash do index.ancestors[p:sub(1, slash - 1)] = entry; slash = p:find("/", slash + 1, true) end
		end
	end
	return index
end
function config.index_overlap(index: any, entry: string): string?
	local p = rules.normalize_path(entry)
	if not p:find("[%*%?%[{]") then
		if index.exact[p] or index.ancestors[p] then return index.exact[p] or index.ancestors[p] end
		local slash = p:find("/", 2, true)
		while slash do
			if index.exact[p:sub(1, slash - 1)] then return index.exact[p:sub(1, slash - 1)] end
			slash = p:find("/", slash + 1, true)
		end
		for _, g in index.globs do if rules.globs_overlap(g, p) then return g end end
		return nil
	end
	for literal, original in index.exact do if rules.globs_overlap(p, literal) then return original end end
	for _, g in index.globs do if rules.globs_overlap(p, g) then return g end end
	return nil
end
-- Queue-time gates for a never-provisioned worker: one shared_checkout and/or one file_overlap
-- gate (each naming every overlapping peer). Returns the gate ids, or nil when nothing overlaps.
function config.execution_directory(w: any): string?
	if w.enrol_delivery or w.adopt_pane_binding then return if w.checkout then w.checkout.worktree_path else nil end
	return w.execution_cwd or w.cwd
end
function config.queue_gates(d: any, w: any, clock: any): (any?, any?)
	if w.role == "coordinator" then return nil, nil end
	local peers, cwd, ids = config.live_peers(d, w), rules.normalize_path(w.execution_cwd or w.cwd), {}
	local options = { { id = "launch_anyway", label = "Launch anyway" }, { id = "cancel", label = "Cancel this work" } }
	local root = config.rooted(d, w, cwd)
	if #peers > 0 then
		local hits, evidence = {}, { bounded("cwd:" .. cwd, 1024) }
		if root then table.insert(evidence, bounded("root:" .. root, 1024)) end
		for _, o in peers do
			for _, other in { config.execution_directory(o), if o.checkout then o.checkout.worktree_path else nil } do
				if other and (rules.path_within(other, cwd) or rules.path_within(cwd, other)) then
					table.insert(hits, o.worker_id .. " (" .. rules.normalize_path(other) .. ")")
					table.insert(evidence, bounded("peer:" .. o.worker_id .. ":" .. rules.normalize_path(other), 1024)); break
				end
			end
		end
		if #hits > 0 then
			local g, err = new_gate(d, w, "shared_checkout", bounded("Work " .. w.work_id .. " would start in " .. cwd
				.. (if root then ", under checkout root " .. root else "") .. ", which is the same checkout as (or nested with) " .. table.concat(hits, ", ")
				.. ". Prefer separate Git worktrees: two workers editing one checkout overwrite each other's changes."
				.. config.VISIBILITY .. " Launch anyway confirms intentional sharing, not independent landing queues. Nothing has been provisioned.", 32768), options, evidence, clock)
			if err then return nil, err end
			table.insert(ids, g.id)
		end
	end
	if w.files and #w.files > 0 and #peers > 0 then
		local repos = {}
		for _, o in peers do
			if o.checkout and ((config.execution_directory(o) and rules.normalize_path(config.execution_directory(o)) == cwd) or rules.path_within(o.checkout.worktree_path, cwd)) then repos[rules.normalize_path(o.checkout.common_dir)] = true end
		end
		local hits, evidence = {}, { bounded("cwd:" .. cwd, 1024) }
		for _, o in peers do
			if (config.execution_directory(o) and rules.normalize_path(config.execution_directory(o)) == cwd) or (o.checkout and repos[rules.normalize_path(o.checkout.common_dir)]) then
				local theirs = {}
				for _, f in o.files or {} do table.insert(theirs, f) end
				for _, f in (if o.checkout then o.checkout.changed_files else {}) do table.insert(theirs, f) end
				local index = config.path_index(theirs)
				for _, mine in w.files do
					local other = config.index_overlap(index, mine)
					if other then
						table.insert(hits, o.worker_id .. " (" .. mine .. " ~ " .. other .. ")")
						table.insert(evidence, bounded("peer:" .. o.worker_id .. ":" .. mine .. "~" .. other, 1024)); break
					end
				end
			end
		end
		if #hits > 0 then
			local g, err = new_gate(d, w, "file_overlap", bounded("Work " .. w.work_id .. " declares files that intersect files declared or changed by "
				.. table.concat(hits, ", ") .. " in the same repository. Parallel edits of the same files conflict at landing."
				.. config.VISIBILITY .. " Launch anyway or cancel this work; nothing has been provisioned.", 32768), options, evidence, clock)
			if err then return nil, err end
			table.insert(ids, g.id)
		end
	end
	if #ids == 0 then return nil, nil end
	return ids, nil
end
-- The queue tail shared by an ungated queue and a launch released from its queue-time gates.
function config.launch(registry: any, n: any, w: any, event: any, clock: any, reserve: any, announce: boolean): (any?, any?)
	local d, sid, worker_id, work_id = n.dispatch, w.logical_session_id, w.worker_id, w.work_id
	local coordinator = w.role == "coordinator"
	local p, answer = policy(d, sid), nil
	if not config.worker_start_allowed(d, w) or w.checks_pending or config.starts_blocked(d, sid, clock) then
		w.project_held = true; d.workers[worker_id] = w
		local project = config.project_ref(d, sid, w.orch_project_id)
		if project and not project.started and project.start and not project.start.claim and not project.start.snapshot.workers[worker_id] then w.checks_pending = true end
		if announce then local _, problem = append(d, w, "assignment", w.prompt, clock); if problem then return nil, problem end end
		return result("task_held", { worker_id = worker_id, work_id = work_id, orch_project_id = w.orch_project_id,
			message = if p.paused then "Added without starting. Waiting for orchestration to resume and this project's START." else "Added without starting. Choose START for this project." }), nil
	end
	if not p.quota_routing and not coordinator and not w.open_conversation and not w.enrol_delivery then
		local busy = config.concurrency_problem(d, sid, p, { [worker_id] = true })
		if busy then
			w.project_held = true; w.reason = busy; d.workers[worker_id] = w
			if announce then local _, problem = append(d, w, "assignment", w.prompt, clock); if problem then return nil, problem end end
			return result("task_held", { worker_id = worker_id, work_id = work_id, orch_project_id = w.orch_project_id, message = busy.message }), nil
		end
	end
	if p.quota_routing then
		-- Quota routing (plan §7): the owner-selected record first, then Config's explicit allowlist.
		if coordinator then
			for key, other in d.workers do
				if key ~= worker_id and other.logical_session_id == sid and other.routing and other.routing.coordinator and not other.routing.bound then
					return fail("coordinator_pending", "A coordinator start for this session is already awaiting capacity or an owner decision; resolve or cancel it first.")
				end
			end
		end
		w.routing = { mode = "quota", phase = "held", scope = "initial_dispatch", requested = { id = w.record_id, revision = w.record_revision }, coordinator = coordinator,
			policy_digest = quota.policy_digest(p), decided_at_ms = 0, decision_digest = string.rep("0", 64), switched = false, bound = false, candidates = {}, history = {} }
		d.workers[worker_id] = w
		if announce then local _, problem = append(d, w, "assignment", w.prompt, clock); if problem then return nil, problem end end
		local action_id, err = route(registry, n, w, clock, reserve, event.request_id, true)
		if err then return nil, err end
		local r = w.routing
		answer = result(if r.phase == "selected" then "task_queued" elseif r.phase == "gated" then "task_gated" else "task_held",
			{ worker_id = worker_id, work_id = work_id, action_id = action_id, message = if r.reason then r.reason.message else nil })
	else
		local request, problem = config.provision(d, w, w.origin_binding, w.controller_pane)
		if not request then
			if problem.code ~= "waiting_for_agent_space" then return nil, problem end
			w.project_held = true; w.reason = config.hold(problem.code, problem.message); d.workers[worker_id] = w
			if announce then local _, err = append(d, w, "assignment", w.prompt, clock); if err then return nil, err end end
			return result("task_held", { worker_id = worker_id, work_id = work_id, orch_project_id = w.orch_project_id, message = problem.message }), nil
		end
		if coordinator then
			local reserved, response = reserve(registry, { kind = "reserve_coordinator", request_id = event.request_id .. "-reserve", orch_session_id = sid, work_id = work_id,
				authority_namespace = registry.authority_namespace, expected_revision = registry.revision }, clock)
			if reserved == nil then return nil, response end
			n.sessions = clone(reserved.sessions); n.next_owner_id = reserved.next_owner_id
			w.coordinator_owner_id = response.owner_id; w.coordinator_generation = response.generation
			w.coordinator_protocol = 1 -- Absent on old CP2 workers: never silently activate them.
			n.sessions[sid].orchestrator.managed_worker_id = worker_id
		end
		if M.request_size(launch_request(w, string.rep("h", 96))) > codec.DISPATCH.limit then
			return fail("oversize", "Assignment and reserved coordinator identity exceed the immutable launch bridge bound; no reservation or provision was committed.")
		end
		-- Frozen enrolment is provisioned before any launch grant exists.
		if not add(d, request, worker_id) then return fail("oversize", "Provision request exceeds the bridge bound.") end
		d.workers[worker_id] = w; answer = result("task_queued", { worker_id = worker_id, work_id = work_id, action_id = request.action_id })
		if announce then local _, err = append(d, w, "assignment", w.prompt, clock); if err then return nil, err end end
	end
	w.project_held = nil
	return answer, nil
end
-- Removes a gate and its thread entries (the reclaim_gates rule for one settled gate).
function config.drop_gate(d: any, w: any, key: string)
	if (d.gates or {})[key] and d.gates[key].ruling then return end
	local entries = flow(w).thread
	for i = #entries, 1, -1 do if entries[i].gate_id == key then table.remove(entries, i) end end
	if flow(w).health and flow(w).health.gate_id == key then flow(w).health = nil end
	d.gates[key] = nil
end
-- Owner answer of a host-consumed checkout gate. Launch gates release the held launch once every
-- one of them says launch_anyway; cancel withdraws the never-provisioned work (no effect exists).
function config.answer_checkout_gate(registry: any, n: any, w: any, g: any, event: any, clock: any, reserve: any): (any?, any?)
	local d = n.dispatch
	if not gate_open(g) then return fail("stale_gate", "This gate is no longer current.") end
	local held = w.launch_gates ~= nil and table.find(w.launch_gates, g.id) ~= nil
	local withdraw = event.command == "cancel_gate" and held
	if event.command == "cancel_gate" and not held then
		g.phase = "cancelled"; g.revision += 1; settle_entries(w, "gate_id", g.id)
		return result("gate_cancelled"), nil
	end
	if not withdraw then
		local choice = false; for _, option in g.options do if option.id == event.choice_id then choice = true end end
		if g.phase ~= "pending" or not choice or not str(event.answer, 32768) then return fail("invalid_choice", "Choose an option from this exact question.") end
		g.answer = { choice_id = event.choice_id, answer = event.answer, source = config.owner_source(event.origin), at_ms = stamp(clock).at_ms }
		g.phase = "resolved"; settle_entries(w, "gate_id", g.id)
		-- The decision itself lives on the worker from this commit on; the gate is only its question.
		if g.kind == "scope" and event.choice_id == "accept" then
			w.scope_accepted = { changed_digest = g.evidence[1]:sub(7), gate_id = g.id, at_ms = g.answer.at_ms }
		elseif g.kind == "shared_checkout" and not held then
			for _, e in g.evidence do
				if e:sub(1, 5) == "peer:" and not table.find(w.shared_acked or {}, e) then
					w.shared_acked = w.shared_acked or {}
					if #w.shared_acked >= 32 then table.remove(w.shared_acked, 1) end
					table.insert(w.shared_acked, e)
				end
			end
		end
		if not held then return result(g.kind .. "_answered", { gate_id = g.id, choice_id = event.choice_id }), nil end
		withdraw = event.choice_id == "cancel"
	end
	if withdraw then
		if w.mailbox_handle or w.pane_binding or w.accepted_event then return fail("withdrawal_required", "Settle the provisioned conversation through its exact cancellation path before removing it.") end
		for _, action in d.actions do if action.worker_id == w.worker_id then
			if action.request.op ~= "mailbox_provision" or action.request_bytes ~= nil or action.claim ~= nil
				or (action.phase ~= "ready" and action.phase ~= "held_ready") then return fail("operation_pending", "A retained effect must settle before cancelling this launch gate.") end
		end end
		for _, action in d.actions do if action.worker_id == w.worker_id then config.consume_action(d, action) end end
		for key, other in d.gates do if other.worker_id == w.worker_id then d.gates[key] = nil end end
		for sid, p in d.policies or {} do
			for i = #p.excluded_workers, 1, -1 do
				if p.excluded_workers[i] == w.worker_id then
					table.remove(p.excluded_workers, i)
					local cursor = (d.command_cursors or {})[sid]
					if cursor then cursor.policy_revision = n.revision end
				end
			end
		end
		d.workers[w.worker_id] = nil
		return result("work_cancelled", { worker_id = w.worker_id, work_id = w.work_id }), nil
	end
	for _, key in w.launch_gates do
		local other = d.gates[key]
		if other and gate_open(other) then return result("launch_gate_answered", { gate_id = g.id, worker_id = w.worker_id }), nil end
	end
	for _, key in w.launch_gates do if d.gates[key] then config.drop_gate(d, w, key) end end
	w.launch_gates = nil
	local _, retained = config.start_unissued(d, w, event)
	if retained then return result("launch_released", { worker_id = w.worker_id, work_id = w.work_id,
		action_id = retained.request.action_id, launch = "task_queued" }), nil end
	local launched, err = config.launch(registry, n, w, event, clock, reserve, false)
	if err then return nil, err end
	return result("launch_released", { worker_id = w.worker_id, work_id = w.work_id, action_id = launched.action_id, launch = launched.code }), nil
end
-- Out-of-scope changed files of the latest CHECKOUT (or an overflowed list) and their digest;
-- nil when the work declares no scope or the checkout is inside it.
function config.scope_problem(w: any): (string?, any?)
	local c, paths = w.checkout, if w.scope and #w.scope.paths > 0 then w.scope.paths else w.files
	if not c or not paths or #paths == 0 then return nil, nil end
	local out = {}
	for _, f in c.changed_files do
		local inside = false
		for _, entry in paths do if rules.path_in_scope(entry, f) then inside = true; break end end
		if not inside then table.insert(out, f) end
	end
	if #out == 0 and not c.changed_overflow then return nil, nil end
	return codec.sha256(table.concat(out, "\n") .. "\n" .. tostring(c.changed_overflow)), out
end
-- Landing stays blocked while the current out-of-scope change set lacks the owner's durable accept
-- (w.scope_accepted, written with the answer); a reclaimed or missing gate never re-blocks it.
function config.scope_blocked(w: any): boolean
	local digest_now = config.scope_problem(w)
	return digest_now ~= nil and not (w.scope_accepted ~= nil and w.scope_accepted.changed_digest == digest_now)
end
function config.checkout_mismatch(w: any, cp: any): boolean
	return w.checkout ~= nil and rules.normalize_path(cp.payload.worktree_ref) ~= rules.normalize_path(w.checkout.worktree_path)
end
-- Helper-only facts (CHECK_RESULT, CHECKOUT). The codec already required check-runner-v1.
function config.helper_fact(d: any, w: any, report: any, clock: any): (string?, any?)
	local p = report.payload
	if report.kind == "CHECK_RESULT" then
		local declared = false
		for _, check in w.checks or {} do if check.check_id == p.check_id then declared = true end end
		if not declared then return "CHECK_RESULT " .. p.check_id .. " ignored: the check is not declared for this work.", nil end
		local r = clone(p); r.event_id = report.event_id; r.seq = report.seq
		w.check_results = w.check_results or {}; w.check_results[p.check_id] = r
		return "CHECK_RESULT " .. p.check_id .. " exited " .. string.format("%.0f", p.exit_code) .. " at " .. p.head, nil
	end
	local c = clone(p); c.event_id = report.event_id; c.seq = report.seq
	c.host_key = (d.catalogs[w.logical_session_id] or {}).host_key
	w.checkout = c
	local path = rules.normalize_path(c.worktree_path)
	local root = config.rooted(d, w, path)
	if w.role ~= "coordinator" then
		for _, o in config.live_peers(d, w) do
			if o.checkout and rules.normalize_path(o.checkout.worktree_path) == path then
				local key = bounded("peer:" .. o.worker_id .. ":" .. path, 1024)
				local seen = table.find(w.shared_acked or {}, key) ~= nil
				for _, g in d.gates or {} do
					if g.worker_id == w.worker_id and g.kind == "shared_checkout" and g.phase ~= "cancelled" and table.find(g.evidence, key) then seen = true end
				end
				if not seen then
					local _, err = new_gate(d, w, "shared_checkout", bounded("Worker " .. w.worker_id .. " reports checkout " .. path
						.. (if root then " (under root " .. root .. ")" else "") .. ", the same worktree " .. o.worker_id .. " already reported."
						.. " Prefer separate Git worktrees; stop one worker or confirm you coordinate their edits. Acknowledging sharing does not disable landing coordination."
						.. config.VISIBILITY, 32768), { { id = "acknowledge", label = "Understood — keep both running" } },
						{ bounded("worktree:" .. path, 1024), bounded("peer:" .. o.worker_id .. ":" .. path, 1024), "checkout:" .. report.event_id }, clock)
					if err then return nil, err end
				end
			end
		end
	end
	local digest_now, out = config.scope_problem(w)
	for _, g in d.gates or {} do
		if g.worker_id == w.worker_id and g.kind == "scope" and gate_open(g) and g.evidence[1] ~= "scope:" .. tostring(digest_now) then
			g.phase = "superseded"; g.revision += 1; settle_entries(w, "gate_id", g.id)
		end
	end
	if digest_now then
		local current = w.scope_accepted ~= nil and w.scope_accepted.changed_digest == digest_now
		for _, g in d.gates or {} do
			if g.worker_id == w.worker_id and g.kind == "scope" and g.evidence[1] == "scope:" .. digest_now and (gate_open(g) or g.phase == "resolved") then current = true end
		end
		if not current then
			local listed = {}
			for index = 1, math.min(#out, 8) do listed[index] = out[index] end
			local evidence = { "scope:" .. digest_now, "checkout:" .. report.event_id, bounded("worktree:" .. path, 1024) }
			for index = 1, math.min(#out, 64) do table.insert(evidence, bounded("out:" .. out[index], 1024)) end
			local _, err = new_gate(d, w, "scope", bounded("Worker " .. w.worker_id .. "'s CHECKOUT at " .. path .. (if #out > 0 then " changes " .. tostring(#out)
				.. " file(s) outside the declared scope: " .. table.concat(listed, ", ") .. (if #out > 8 then ", …" else "") .. "." else "")
				.. (if c.changed_overflow then " The helper listed only " .. tostring(#c.changed_files) .. " of " .. string.format("%.0f", c.changed_total) .. " changed paths, so the scope cannot be proven." else "")
				.. " Landing for this work stays blocked until you accept these changes." .. config.VISIBILITY, 32768),
				{ { id = "accept", label = "Accept these changes for landing" }, { id = "keep_blocked", label = "Keep landing blocked" } }, evidence, clock)
			if err then return nil, err end
		end
	end
	return "CHECKOUT " .. path .. " at " .. c.head .. " (" .. string.format("%.0f", c.changed_total) .. " changed" .. (if c.dirty then ", dirty" else "") .. ")", nil
end
local function reason_text(w: any): string
	return if w.reason then tostring(w.reason.code or "unknown") .. ": " .. tostring(w.reason.message or "no detail") else "no SPAWN diagnostic retained"
end
local function rollover_edge(r: any, phase: string, revision: number, clock: any)
	r.phase = phase; r.hold = nil; r.revision = revision; r.at_ms = stamp(clock).at_ms
end
local function rollover_hold(r: any, code: string, message: string): boolean
	r.hold = { code = code, message = bounded(message, 1024) }; return false
end
-- A no-successor exit never cancels an issued effect or assumes a restored draft stayed unissued.
local function rollover_cancellable(d: any, r: any): boolean
	if ROLLOVER_TERMINAL[r.phase] or (r.prepared and r.prepared.action.phase ~= "ready") then return false end
	if not r.successor_worker_id then return true end
	local succ = d.workers[r.successor_worker_id]
	if not succ or succ.pane_binding or succ.accepted_event or succ.accepted_seq ~= 0 then return false end
	for _, gate in d.gates do if gate.worker_id == succ.worker_id and (gate_open(gate) or gate.ruling or gate.ruling_delivery) then return false end end
	local unused = succ.launch_refused == true or (succ.withdrawn and (succ.withdrawn.evidence == "unissued" or succ.withdrawn.evidence == "pre_effect_refusal"))
	if unused and (succ.mailbox_retired or succ.mailbox_allocation == "none") and not pending(d, succ)
		and config.refused_handover_clear(d, succ) then return true end
	if succ.mailbox_handle or succ.mailbox_allocation == "possible" or (succ.launch_refused and succ.mailbox_allocation ~= "none") then return false end
	local found = false
	for _, action in d.actions do
		if action.worker_id == succ.worker_id then
			if action.phase ~= "ready" or action.request_bytes ~= nil or action.claim ~= nil then return false end
			found = true
		end
	end
	return found
end
-- A blocked checkpoint (missing, unverified or too large) may be requested again by the owner.
local function rollover_rerequestable(d: any, r: any): boolean
	local pred = d.workers[r.predecessor_worker_id]
	return r.hold ~= nil and (r.phase == "checkpoint_pending" or (r.phase == "checkpoint_verified" and r.hold.code == "input_too_large"))
		and pred ~= nil and flow(pred).report_request == nil
end
local function request_checkpoint(n: any, r: any, w: any, clock: any): boolean
	local d, f = n.dispatch, flow(w)
	if w.phase ~= "accepted" or w.finish or w.stopped or w.mailbox_retired or w.continuation_required then
		return rollover_hold(r, "predecessor_unavailable", "The predecessor is not an accepted, explicitly continued worker; nothing was requested or launched.")
	end
	if r.kind == "coordinator" and (not coordinator(n, w) or w.release or w.retirement) then
		return rollover_hold(r, "owner_mismatch", "The predecessor is no longer the current, non-retiring coordinator; nothing was requested or launched.")
	end
	if f.report_request then return rollover_hold(r, "request_pending", "One progress request is already outstanding; the checkpoint request waits for it to settle.") end
	if policy(d, w.logical_session_id).paused then return rollover_hold(r, "session_paused", "Session is paused; the checkpoint request waits for resume.") end
	if not sendable(d, w, clock) then
		return rollover_hold(r, "worker_not_sendable", "The predecessor is working, waiting for input or unconfirmed and is never interrupted; the checkpoint request waits for safe idle.")
	end
	if not thread_room(w) then return rollover_hold(r, "full", "The predecessor's durable thread is full of unresolved items; nothing was evicted.") end
	local request_id = next_id(d, "report-request-")
	local delivery, err = issue_reply(d, w, "report_request", { request_id = request_id, requested_kind = "CHECKPOINT",
		reason = "Rollover " .. r.id .. ": claim this request, publish one CHECKPOINT echoing request_id with fresh passed checks for the current artifact revision (a failed check blocks the rollover), then resolve this claim in the helper journal and drain receipts. Start no new work, send no further progress and stay idle. ORCH+ stops this pane only after a fresh successor accepts; an unresolved claim keeps your stopped mailbox unretired." })
	if err then return rollover_hold(r, err.code, err.message) end
	delivery.request_id = request_id; delivery.published = false; delivery.response_received = false; f.report_request = delivery
	append(d, w, "report_request", "Rollover " .. r.id .. " requested a verified checkpoint; delivery ACK is not a checkpoint.", clock,
		{ state = "pending", request_id = request_id, action_id = delivery.action_id })
	r.request_id = request_id; rollover_edge(r, "checkpoint_pending", n.revision, clock)
	-- Each issued checkpoint request is one engagement of the capped re-request loop (Contract L).
	r.checkpoint_loop = r.checkpoint_loop or { count = 0 }; r.checkpoint_loop.count += 1
	return true
end
-- Rollover-time fallback gate (plan §7 lines 305, 321): bound to the running predecessor, the
-- rollover, its scope, routing-policy/evidence/catalog revisions and the exact tuples.
local function open_rollover_gate(d: any, r: any, pred: any, decision: any, p: any, scope: string, clock: any): any?
	local e = current_evidence(d, r.logical_session_id)
	r.quota = r.quota or {}
	local binding = { policy_digest = quota.policy_digest(p), evidence_revision = e.revision, catalog_revision = d.catalogs[r.logical_session_id].revision,
		from = clone(decision.from), to = clone(decision.to), denied = decision.denied, scope = scope }
	local question = "Quota fallback for " .. (if scope == "coordinator_rollover" then "coordinator" else "worker") .. " rollover " .. r.id .. " of " .. r.work_id .. ": "
		.. decision.reason.message .. " Start the fresh successor on " .. tuple_text(decision.to) .. " instead of " .. tuple_text(decision.from)
		.. "? This applies to this rollover's successor only, never edits Config and never changes the running predecessor. Reject keeps the rollover held; cancel the rollover to stop it."
	return open_quota_gate(d, r.quota, pred, binding, decision, question, { "operation:" .. scope, "rollover:" .. r.id, "work:" .. r.work_id }, false,
		"Approve " .. decision.to.id .. " for this successor only", "Reject — keep the rollover held", clock)
end
function config.activate_successor(n: any, r: any, clock: any, reserve: any): boolean
	local d, prepared = n.dispatch, r.prepared
	if not prepared then return rollover_hold(r, "preflight_required", "A fully prepared successor is required before reserving ownership.") end
	if prepared.action.phase ~= "ready" then return rollover_hold(r, "restored_preparation", "This prepared snapshot may predate an issued successor. Reconcile the peer; absence is not permission to reserve again.") end
	if policy(d, r.logical_session_id).paused or (type(clock) == "table" and clock.reserved_capacity) then
		return rollover_hold(r, "session_paused", "The prepared successor waits without reserving an owner; resume or close without a successor.")
	end
	if count(d.workers) >= 32 or count(d.actions) >= 3072 then return rollover_hold(r, "full", "Prepared successor waits for live capacity; no ownership was reserved.") end
	local w, action = prepared.worker, prepared.action
	local selected
	for _, row in (d.catalogs[r.logical_session_id] or {}).records or {} do
		if row.id == w.record_id and row.revision == w.record_revision then selected = row end
	end
	if not selected or not selected.eligible or selected.enabled ~= true or selected.cwd ~= w.cwd or selected.placement ~= w.placement
		or not table.find(selected.capabilities or {}, "report-files-v1")
		or (r.kind == "coordinator" and (not table.find(selected.capabilities or {}, "coordinator-control-v1")
			or not table.find(selected.capabilities or {}, "project-start-v1"))) then
		return rollover_hold(r, "catalog_changed", "Prepared successor prerequisites changed; no owner was reserved.")
	end
	if r.kind == "coordinator" then
		if n.sessions[r.logical_session_id].orchestrator then return rollover_hold(r, "orchestrator_slot_occupied", "Exactly one coordinator is permitted.") end
		local reserved, response = reserve(n, { kind = "reserve_coordinator", request_id = r.id .. "-reserve",
			orch_session_id = r.logical_session_id, work_id = r.work_id, authority_namespace = n.authority_namespace, expected_revision = n.revision }, clock)
		if not reserved then return rollover_hold(r, response.code, response.message) end
		for key, value in reserved do n[key] = value end
		w.coordinator_protocol = 1; w.coordinator_owner_id = response.owner_id; w.coordinator_generation = response.generation
		n.sessions[r.logical_session_id].orchestrator.managed_worker_id = w.worker_id
		r.successor_owner_id = response.owner_id; r.successor_generation = response.generation
	end
	d.workers[w.worker_id] = w; d.actions[action.request.action_id] = action; r.prepared = nil
	if w.routing then w.routing.bound = true; reserve_slot(d, w, n.revision, stamp(clock).at_ms); r.quota = nil end
	r.successor_worker_id = w.worker_id; rollover_edge(r, "successor_granted", n.revision, clock)
	return true
end
local function grant_successor(n: any, r: any, pred: any, event: any, clock: any, reserve: any, prepare_only: boolean?): boolean
	local d = n.dispatch
	if r.prepared then return if prepare_only then true else config.activate_successor(n, r, clock, reserve) end
	if (r.prepare_count or 0) >= math.min(100, policy(d, r.logical_session_id).loop_cap) then return rollover_hold(r, "loop_capped", "Successor preparation reached its bounded live retry count; close this handover without a successor.") end
	r.prepare_count = (r.prepare_count or 0) + 1
	if policy(d, r.logical_session_id).paused then return rollover_hold(r, "session_paused", "Session is paused; no successor launch is granted until resume. The predecessor keeps running.") end
	if type(clock) == "table" and clock.reserved_capacity then
		return rollover_hold(r, "capacity_reached", "Authority capacity is at its settlement reserve; no successor launch is granted. The predecessor keeps running.")
	end
	local c, selected = d.catalogs[r.logical_session_id], nil
	for _, row in (if c then c.records else {}) do if row.id == pred.record_id and row.revision == pred.record_revision then selected = row end end
	local coordinator_kind = r.kind == "coordinator"
	local p, now = policy(d, r.logical_session_id), stamp(clock).at_ms
	local project = config.project_ref(d, r.logical_session_id, pred.orch_project_id)
	if not project then return rollover_hold(r, "project_changed", "The successor needs the predecessor's unfinished project.") end
	local execution_cwd = pred.execution_cwd
	local routing, decision = nil, nil
	if p.quota_routing then
		-- Quota routing of the successor: the predecessor's record first, then this rollover kind's
		-- explicit allowlist with its own substitution permissions; otherwise an owner gate or a hold.
		local scope = if coordinator_kind then "coordinator_rollover" else "worker_rollover"
		local digest_now = quota.policy_digest(p)
		decision = quota.decide({ policy = p, scope = scope, catalog = c, evidence = current_evidence(d, r.logical_session_id),
			requested = { id = pred.record_id, revision = pred.record_revision }, coordinator = coordinator_kind, cwd = pred.cwd,
			placement = pred.placement, execution_cwd = execution_cwd, presentation = "background", now_ms = now, bound = false })
		local q = r.quota
		local approval = if q then q.approval else nil
		if decision.outcome == "owner_gate" and approval and approval.policy_digest == digest_now and equal(approval.to, decision.to) then
			decision.outcome = "selected"; decision.authority = "owner_gate"; decision.needs = decision.denied
		end
		if decision.outcome == "owner_gate" then
			local rejected = if q then q.rejected else nil
			if rejected and rejected.policy_digest == digest_now and equal(rejected.to, decision.to) then
				return rollover_hold(r, "quota_fallback_rejected", "The owner rejected starting the successor on " .. decision.to.id .. ". The predecessor keeps running; cancel this rollover, change Config, or wait for different evidence.")
			end
			local err = open_rollover_gate(d, r, pred, decision, p, scope, clock)
			if err then return rollover_hold(r, err.code, err.message) end
			return rollover_hold(r, "quota_fallback_gate", decision.reason.message .. " Answer the quota fallback gate on the predecessor; it keeps running meanwhile.")
		end
		if r.quota then close_quota_gate(d, r.quota, pred) end
		if decision.outcome ~= "selected" then
			local reason = decision.reason or { code = "quota_held", message = "No allowed record has sufficient fresh quota." }
			return rollover_hold(r, reason.code, reason.message .. " No successor is launched; the predecessor keeps running and fresh USAGE evidence re-evaluates this.")
		end
		-- A successor may overlap only its own predecessor's reservation.
		local busy = if coordinator_kind then nil else config.concurrency_problem(d, r.logical_session_id, p, { [pred.worker_id] = true })
		if busy then return rollover_hold(r, busy.code, busy.message) end
		selected = decision.record
		routing = { mode = "quota", phase = "selected", scope = scope, requested = { id = pred.record_id, revision = pred.record_revision },
			coordinator = coordinator_kind, policy_digest = digest_now, decided_at_ms = 0, decision_digest = string.rep("0", 64),
			switched = decision.switched == true, needs = if decision.switched then decision.needs else nil, authority = decision.authority,
			authorized_digest = if decision.authority == "owner_gate" then approval.policy_digest else nil,
			selected = { id = selected.id, revision = selected.revision }, bound = false, candidates = {}, history = {} }
	end
	if not selected or not selected.eligible or selected.enabled ~= true or not quota.location_matches(selected, { requested = { id = pred.record_id },
		cwd = pred.cwd, placement = pred.placement, execution_cwd = execution_cwd, presentation = "background",
		scope = if coordinator_kind then "coordinator_rollover" else "worker_rollover" }) then
		return rollover_hold(r, "catalog_changed", "The predecessor's SPAWN record/revision, cwd and placement must be present and eligible in the current catalog. Refresh the catalog; no other record is substituted.")
	end
	if count(d.workers) >= 32 or count(d.actions) >= 3072 then return rollover_hold(r, "full", "Managed live capacity is full; no predecessor was retired or successor reserved.") end
	if coordinator_kind then
		if not table.find(selected.capabilities or {}, "coordinator-control-v1") or not table.find(selected.capabilities or {}, "project-start-v1") then
			return rollover_hold(r, "unsupported_capability", "A fresh successor coordinator requires coordinator-control-v1 and project-start-v1; no successor is reserved.")
		end
		if n.sessions[r.logical_session_id].orchestrator ~= nil and not prepare_only then
			return rollover_hold(r, "orchestrator_slot_occupied", "The orchestrator slot is occupied; a successor coordinator is never started beside another owner.")
		end
	end
	-- The successor's assignment is the verified checkpoint itself: no transcript, no predecessor command.
	local payload = clone(codec.decode_report(r.checkpoint, pred).payload); payload.request_id = nil
	payload.context_used_pct = nil; payload.context_snapshot = nil
	local prompt = "ORCH+ verified " .. (if coordinator_kind then "coordinator" else "worker") .. " rollover " .. r.id .. " for work " .. r.work_id .. ".\n"
		.. "You are a FRESH successor context. No transcript was transferred: the predecessor's checkpoint below is your complete assignment. "
		.. "Its verification outcomes are worker-attested by the predecessor, not independent verification. "
		.. "First report ACCEPTED with this assignment's assignment_sha256 and the exact handover_id and handover_token from your launch preface (never on any other report). "
		.. (if coordinator_kind then "Then wait for and claim this generation's typed coordinator activation before any coordinator work; the predecessor coordinator is already stopped and retired, and its activation token is invalid. "
			else "Then continue only the remaining work in the same project/worktree, respecting every hold. ORCH+ stops the predecessor after your acceptance; do not contact or control it. ")
		.. "\nCHECKPOINT " .. tern.json.encode(payload)
	local worker_id = next_id(d, "worker-")
	local w: any = { worker_id = worker_id, work_id = r.work_id, worker_generation = 1, logical_session_id = r.logical_session_id,
		origin_binding = clone(event.origin), controller_pane = event.controller_pane, record_id = selected.id, record_revision = selected.revision,
		prompt = prompt, cwd = selected.cwd, placement = selected.placement, execution_cwd = execution_cwd, presentation = "background",
		orch_project_id = pred.orch_project_id, assignment_sha256 = codec.sha256(prompt),
		launch_request_id = next_id(d, "launch-"), launch_action_id = next_id(d, "action-"),
		enrolment_token = codec.sha256(r.id .. ":enrolment:" .. event.origin.alias_nonce .. ":" .. worker_id), phase = "queued",
		accepted_seq = 0, compacted_floor = 0, receipts = {}, replies = {}, reply_seq = 0, reply_floor = 0,
		handover_id = r.id, handover_token = r.handover_token }
	-- Contract A successor copy: assignment-shaped fields carry over; family follows the successor's
	-- record; checkout, check results and usage readings are the successor's own.
	for _, key in config.SUCCESSOR_FIELDS do w[key] = clone(pred[key]) end
	if coordinator_kind then w.project_start_protocol = 1 end
	config.bind_family(d, w)
	-- Bound the immutable launch with a maximal provisional coordinator identity before reserving the slot.
	if coordinator_kind then w.coordinator_protocol = 1; w.coordinator_owner_id = string.rep("o", 96); w.coordinator_generation = MAX end
	if not str(prompt, 32768) or M.request_size(launch_request(w, string.rep("h", 96))) > codec.DISPATCH.limit then
		return rollover_hold(r, "input_too_large", "The verified checkpoint handover exceeds the 8192-byte immutable launch bridge. It is never truncated: request a more concise checkpoint again or cancel. The predecessor keeps running.")
	end
	-- Sizing used a maximal identity, not an allocated owner. No fabricated owner is persisted.
	w.coordinator_owner_id = nil; w.coordinator_generation = nil; w.coordinator_protocol = nil
	local request, problem = config.provision(d, w, event.origin, event.controller_pane)
	if not request then return rollover_hold(r, problem.code, problem.message) end
	request.handover_id = w.handover_id; request.handover_sha256 = handover_sha256(w)
	local staged = { actions = {} }
	local action = add(staged, request, worker_id)
	if not action then return rollover_hold(r, "oversize", "Successor provision request exceeds the bridge bound; nothing was granted.") end
	local _, entry_problem = append(d, w, "assignment", prompt, clock)
	if entry_problem then return rollover_hold(r, entry_problem.code, entry_problem.message) end
	-- The prepared immutable provision already fixes its quota-selected record, just
	-- like an unissued ordinary provision. Binding is not an owner or slot grant:
	-- coordinator activation still waits for predecessor retirement before reserving either.
	if routing then w.routing = routing; routing.bound = true; remember_decision(d, w, "selected", decision, p, now) end
	r.prepared = { worker = w, action = action }
	return if prepare_only then true else config.activate_successor(n, r, clock, reserve)
end
-- One pass from the current durable phase. Holds are recomputed from durable evidence; no
-- timeout or missing pane starts a successor or stops a predecessor.
local function rollover_step(n: any, r: any, event: any, clock: any, reserve: any): boolean
	local d = n.dispatch
	r.hold = nil
	local coordinator_kind = r.kind == "coordinator"
	local pred = d.workers[r.predecessor_worker_id]
	local succ = if r.successor_worker_id then d.workers[r.successor_worker_id] else nil
	if not pred or (r.successor_worker_id and not succ) then return rollover_hold(r, "generation_missing", "A bound rollover generation is missing; nothing is launched or stopped.") end
	if event.origin.owner_id ~= r.origin.owner_id or event.origin.owner_generation ~= r.controller_generation then
		return rollover_hold(r, "controller_changed", "This rollover belongs to controller generation " .. tostring(r.controller_generation)
			.. "; a different controller cannot advance it. Retained effects still settle; nothing is launched or stopped.")
	end
	local restored = if coordinator_kind then restored_coordinator(d, r.logical_session_id) else nil
	if restored then
		return rollover_hold(r, "predecessor_reappeared", "Retired coordinator " .. restored.worker_id .. " was observed alive again (native restoration). Every coordinator effect is held; stop or inspect that pane, then observe its exit or confirm reconciliation. It is never counted as a healthy coordinator.")
	end
	local session = n.sessions[r.logical_session_id]
	local retired = coordinator_kind and session.orchestrator_generation > r.predecessor_generation
		and (not session.orchestrator or session.orchestrator.owner_id ~= r.predecessor_owner_id)
	-- A coordinator that self-finishes with an authenticated COORDINATOR_RELEASE before this rollover
	-- holds a verified checkpoint leaves nothing to hand over and can never publish one (only reply
	-- ACKs may follow a release). Its own release → exact stop → mailbox retirement continues, and the
	-- rollover closes visibly as cancelled with this evidence: no successor, and the slot is free for
	-- an explicit new start. After a verified checkpoint, the release is exactly the quiescence the
	-- rollover waits for and it continues normally.
	local function self_released(): boolean
		if r.quota then close_quota_gate(d, r.quota, pred); r.quota = nil end
		rollover_edge(r, "cancelled", n.revision, clock)
		return rollover_hold(r, "predecessor_self_released", "Coordinator " .. pred.worker_id .. " published its own COORDINATOR_RELEASE before a verified rollover checkpoint. "
			.. "The rollover closed with no successor; the normal release, exact stop and mailbox retirement continue. Start a new coordinator explicitly if more work remains.")
	end
	-- From owner_retired on, a coordinator rollover has no running predecessor and cannot be
	-- cancelled. A successor that cannot accept leaves no active coordinator: say so and name the
	-- one explicit way forward (fenced recovery of the successor's owner, which closes the rollover).
	local function no_coordinator(code: string, what: string): boolean
		return rollover_hold(r, code, what .. " Predecessor coordinator " .. pred.worker_id .. " is already stopped and retired, so no coordinator is active."
			.. " Nothing is retried, relaunched or skipped, and this rollover cannot be cancelled. To continue: stop successor " .. succ.worker_id
			.. " if its pane exists and reconcile any retained effect, then run fenced recovery for orchestrator owner " .. tostring(r.successor_owner_id)
			.. " on its owner card (Stop assistance…, Recheck, Begin fenced recovery, verify it stopped). That closes this rollover and frees the slot to start a new coordinator from the retained verified checkpoint.")
	end
	if r.phase == "requested" then
		if coordinator_kind and pred.release then return self_released() end
		return request_checkpoint(n, r, pred, clock)
	elseif r.phase == "checkpoint_pending" then
		local f, found, bytes = flow(pred), nil, nil
		for _, kept in f.checkpoints do
			local cp = codec.decode_report(kept, pred)
			if cp and cp.payload.request_id == r.request_id then found = cp; bytes = kept end
		end
		local verified, problem = nil, nil
		if found then verified, problem = rules.verify_checkpoint(found, r.request_id) end
		if not verified and coordinator_kind and pred.release then return self_released() end
		if not found then
			local outstanding = f.report_request
			if not outstanding or outstanding.request_id ~= r.request_id or outstanding.response_received then
				return rollover_hold(r, "checkpoint_missing", "The worker settled this rollover's checkpoint request without a CHECKPOINT. Request the checkpoint again or cancel; the predecessor keeps running.")
			end
			return false
		end
		if not verified then return rollover_hold(r, problem.code, problem.message .. " Request the checkpoint again or cancel; no successor was launched.") end
		r.checkpoint = bytes; r.verification = verified; rollover_edge(r, "checkpoint_verified", n.revision, clock)
		return true
	elseif r.phase == "checkpoint_verified" and not coordinator_kind then return grant_successor(n, r, pred, event, clock, reserve)
	elseif r.phase == "checkpoint_verified" then
		if not grant_successor(n, r, pred, event, clock, reserve, true) then return false end
		-- Quiesce through the existing typed retirement: proposals and fresh coordinator effects stop.
		if not pred.release and not pred.retirement then
			local owner = coordinator(n, pred)
			if not owner or owner.phase ~= "running" or not pred.activation then
				return rollover_hold(r, "owner_mismatch", "Only the current running, activated coordinator can be retired for rollover; nothing was started.")
			end
			local grant, err = issue_reply(d, pred, "coordinator_retirement", { owner_id = pred.coordinator_owner_id, owner_generation = pred.coordinator_generation,
				activation_token = pred.activation.activation_token, reason = "Rollover " .. r.id .. ": quiesce, report COORDINATOR_RELEASE and drain receipts/replies. A fresh successor starts only after this pane is stopped and retired." })
			if err then return rollover_hold(r, err.code, err.message) end
			pred.retirement = grant; owner.phase = "retiring"
		end
		rollover_edge(r, "retirement_requested", n.revision, clock)
		return true
	elseif r.phase == "retirement_requested" or r.phase == "predecessor_released" or (coordinator_kind and r.phase == "predecessor_stop_requested") then
		-- Ambiguous closure: only the explicit operator-assisted owner recovery may retire this owner.
		if retired and not pred.stopped then
			r.closure = "operator_attested"; rollover_edge(r, "owner_retired", n.revision, clock)
			return true
		end
		if r.phase == "retirement_requested" then
			if pred.release then rollover_edge(r, "predecessor_released", n.revision, clock); return true end
			return false
		elseif r.phase == "predecessor_released" then
			if pred.stop_action_id or pred.stopped then rollover_edge(r, "predecessor_stop_requested", n.revision, clock); return true end
			return false
		end
		if pred.stopped then
			r.stop_observation = pred.stopped.observation; r.closure = "observed"; rollover_edge(r, "predecessor_closed", n.revision, clock)
			return true
		end
		local stop = if pred.stop_action_id then d.actions[pred.stop_action_id] else nil
		if pred.stop_refused or (stop and stop.phase == "uncertain") then
			return rollover_hold(r, "predecessor_stop_uncertain", "Predecessor coordinator closure is not proven (" .. reason_text(pred) .. "). The stop is never retried and no successor starts: use the recorded orchestrator's explicit recovery (inspect, verify stopped, fenced recovery). The checkpoint is retained.")
		end
		return false
	elseif r.phase == "predecessor_closed" and coordinator_kind then
		if retired then rollover_edge(r, "owner_retired", n.revision, clock); return true end
		return false -- Exact mailbox retirement and normal generation-bound release still settle.
	elseif r.phase == "owner_retired" then return grant_successor(n, r, pred, event, clock, reserve)
	elseif coordinator_kind and (r.phase == "successor_granted" or r.phase == "successor_created")
		and session.orchestrator_generation > r.successor_generation and (not session.orchestrator or session.orchestrator.owner_id ~= r.successor_owner_id) then
		-- Explicit fenced recovery retired the unaccepted successor's owner: that generation can never
		-- activate. The handover closes visibly with no successor and the orchestrator slot is free.
		rollover_edge(r, "cancelled", n.revision, clock)
		return rollover_hold(r, "successor_owner_recovered", "Fenced recovery retired successor coordinator owner " .. r.successor_owner_id
			.. " before " .. succ.worker_id .. " accepted this handover. The rollover closed without a successor; nothing was relaunched. Start a new coordinator explicitly from the retained verified checkpoint if work remains.")
	elseif r.phase == "successor_granted" then
		if succ.pane_binding then
			r.successor_pane_binding = clone(succ.pane_binding); rollover_edge(r, "successor_created", n.revision, clock)
			return true
		end
		if succ.phase == "held" then
			if coordinator_kind then return no_coordinator("successor_launch_failed", "Successor launch did not start (" .. reason_text(succ) .. ").") end
			return rollover_hold(r, "successor_launch_failed", "Successor launch did not start (" .. reason_text(succ) .. "). The predecessor is untouched; cancel this rollover before requesting another.")
		end
		for _, a in d.actions do
			if a.worker_id == succ.worker_id and a.phase == "uncertain" then
				if coordinator_kind then return no_coordinator("successor_launch_uncertain", "The successor's exact " .. a.request.op .. " may have executed; it is never retried.") end
				return rollover_hold(r, "successor_launch_uncertain", "The successor's exact " .. a.request.op .. " may have executed. Reconcile that retained effect; it is never retried and the predecessor keeps running.")
			end
		end
		if not pending(d, succ) then
			if coordinator_kind then return no_coordinator("successor_launch_fenced", "The successor's launch intent was fenced before execution.") end
			return rollover_hold(r, "successor_launch_fenced", "The successor's launch intent was fenced before execution. Cancel this rollover and request a new one; the predecessor keeps running.")
		end
		return false
	elseif r.phase == "successor_created" then
		if succ.phase == "accepted" and succ.accepted_event ~= nil and succ.accept_pending == false then
			rollover_edge(r, "handover_accepted", n.revision, clock)
			return true
		end
		if succ.phase == "held" or succ.stopped or flow(succ).exit then
			if coordinator_kind then
				return no_coordinator("successor_unaccepted", "Successor coordinator " .. succ.worker_id .. " exited or was held before accepting this handover (" .. reason_text(succ) .. ").")
			end
			return rollover_hold(r, "successor_unaccepted", "The successor exited or was held before accepting this handover (" .. reason_text(succ) .. "). The predecessor keeps running; nothing is stopped.")
		end
		if coordinator_kind and succ.rejected_report then
			return no_coordinator("successor_report_held", "Successor coordinator " .. succ.worker_id .. "'s report is held (" .. reason_text(succ) .. "); Re-check held report re-validates the same retained bytes.")
		end
		return false
	elseif r.phase == "handover_accepted" and coordinator_kind then
		-- The handover-bound activation must be durably acknowledged before the successor counts.
		if succ.activation and succ.activation.acknowledged then rollover_edge(r, "complete", n.revision, clock); return true end
		return false
	elseif r.phase == "handover_accepted" then
		refresh(d, succ, clock)
		if not table.find({ "working", "idle", "waiting-input" }, flow(succ).health.native_state) then
			return rollover_hold(r, "successor_liveness_unconfirmed", "Successor acceptance is recorded; a fresh native observation of the live successor is required before the predecessor is stopped.")
		end
		local landing = landing_open(d, pred.worker_id, true)
		if landing then
			return rollover_hold(r, "landing_in_progress", "The predecessor holds landing grant " .. landing.id .. "; it is never stopped mid-landing. Its exact LANDING_RESULT or owner reconciliation must settle first.")
		end
		local deploy = config.deploy_in_flight(d, pred.worker_id)
		if deploy then
			return rollover_hold(r, "deploy_in_progress", "The predecessor holds deploy grant " .. deploy.deploy_id .. "; it is never stopped mid-deploy. Its exact DEPLOY_RESULT, the owner's answer or reconciliation must settle first.")
		end
		local f = flow(pred)
		if pending(d, pred) or pred.accept_pending or pred.assembly or pred.rejected_report or f.report_request or next(pred.replies) or next(pred.wakes or {}) then
			return rollover_hold(r, "predecessor_unsettled", "The predecessor still has a retained effect, outstanding request, unacknowledged reply or held report; it is stopped only after they settle.")
		end
		for _, g in d.gates or {} do
			if g.worker_id == pred.worker_id and (gate_open(g) or (g.delivery and not g.delivery.acknowledged)) then
				return rollover_hold(r, "predecessor_unsettled", "Owner decisions for the predecessor remain open or unacknowledged; answer or cancel them before it is stopped.")
			end
		end
		-- The existing finish path issues the one exact native stop once receipts/replies settle.
		pred.finish = { request_id = r.id, seq = pred.accepted_seq, revision = n.revision, source = clone(pred.origin_binding) }
		f.thread = {}
		rollover_edge(r, "predecessor_stop_requested", n.revision, clock)
		return true
	elseif r.phase == "predecessor_stop_requested" then
		if pred.stopped then
			r.stop_observation = pred.stopped.observation; rollover_edge(r, "predecessor_closed", n.revision, clock)
			return true
		end
		local stop = if pred.stop_action_id then d.actions[pred.stop_action_id] else nil
		if stop and stop.phase == "uncertain" then
			return rollover_hold(r, "predecessor_stop_uncertain", "The exact predecessor stop may have executed. It is never retried; reconcile that retained effect. The successor keeps the work.")
		end
		if pred.stop_refused then
			return rollover_hold(r, "predecessor_stop_failed", "SPAWN did not confirm the exact predecessor stop (" .. reason_text(pred) .. "). It is not retried; inspect the predecessor pane. The successor keeps the work.")
		end
		if pred.rejected_report then
			return rollover_hold(r, "predecessor_report_held", "The predecessor sent a report after its stop was requested; it is retained unacknowledged and blocks settlement. Inspect it; nothing is skipped.")
		end
		return false
	elseif r.phase == "predecessor_closed" then
		if pred.stopped and (pred.stopped.observation == "absent" or pred.stopped.observation == "exited") and flow(pred).exit then
			rollover_edge(r, "complete", n.revision, clock)
			return true
		end
		return rollover_hold(r, "exit_unobserved", "Predecessor exit/absence has not been observed; the rollover is not complete.")
	end
	return false
end
local function advance_rollovers(n: any, event: any, clock: any, reserve: any)
	local d = n.dispatch
	if not d.rollovers then return end
	for _, key in config.sorted_keys(d.rollovers, function(_, r) return r.logical_session_id == event.orch_session_id and not ROLLOVER_TERMINAL[r.phase] end) do
		for _ = 1, #COORDINATOR_ROLLOVER_PHASES do if not rollover_step(n, n.dispatch.rollovers[key], event, clock, reserve) then break end end
	end
end
local function reclaim_handover_checkpoints(d: any, w: any)
	if work_referenced(d, w) then return end
	local f = flow(w)
	local current = if f.evidence.CHECKPOINT then codec.decode_report(f.evidence.CHECKPOINT, w) else nil
	if not current then return end
	for checkpoint_id, bytes in f.checkpoints do
		if checkpoint_id == current.payload.checkpoint_id then continue end
		local cp = codec.decode_report(bytes, w)
		if not cp or not cp.payload.request_id or cp.seq > w.compacted_floor
			or (f.report_request and f.report_request.request_id == cp.payload.request_id) then continue end
		local pinned = false
		for _, review in d.reviews or {} do
			if review.logical_session_id == w.logical_session_id and review.builder_work_id == w.work_id
				and review.checkpoint_id == checkpoint_id then pinned = true; break end
		end
		for _, item in (d.landing or {}).items or {} do
			if item.logical_session_id == w.logical_session_id and item.work_id == w.work_id then
				if item.request.checkpoint_id == checkpoint_id then pinned = true; break end
				for _, grant in item.grants do
					if grant.checkpoint_id == checkpoint_id then pinned = true; break end
				end
			end
			if pinned then break end
		end
		for kind, retained in f.evidence do
			if pinned then break end
			if kind ~= "CHECKPOINT" then
				local report = codec.decode_report(retained, w)
				if report and report.payload.checkpoint_id == checkpoint_id then pinned = true end
			end
		end
		for _, entry in f.thread do
			if pinned then break end
			if entry.kind ~= "CHECKPOINT" and entry.state ~= "settled" and entry.report_bytes then
				local report = codec.decode_report(entry.report_bytes, w)
				if report and report.payload.checkpoint_id == checkpoint_id then pinned = true end
			end
		end
		if not pinned then
			f.checkpoints[checkpoint_id] = nil
			for index = #f.thread, 1, -1 do
				if f.thread[index].kind == "CHECKPOINT" and f.thread[index].event_id == cp.event_id then table.remove(f.thread, index) end
			end
		end
	end
end
function config.reclaim_rollovers(d: any)
	for key, r in d.rollovers or {} do
		if not ROLLOVER_TERMINAL[r.phase] then continue end
		local pred = d.workers[r.predecessor_worker_id]
		local succ = if r.successor_worker_id then d.workers[r.successor_worker_id] else nil
		if pred and (not deliveries_settled(pred) or (flow(pred).report_request and flow(pred).report_request.request_id == r.request_id)) then continue end
		if succ and pending(d, succ) then continue end
		if r.quota and r.quota.gate then continue end
		d.rollovers[key] = nil
		if pred then reclaim_handover_checkpoints(d, pred) end
	end
end
-- Landing queue engine: one FIFO queue and one granted slot per session/project/repository/target.
-- Grants go only to the release manager (Contract I); uncertainty holds the slot until owner reconciliation.
local function landing_hold(code: string, message: string): any return { code = code, message = bounded(message, 1024) } end
local function landing_status(item: any, status: string, hold: any?, revision: number, clock: any)
	local same = (item.hold == nil and hold == nil)
		or (item.hold ~= nil and hold ~= nil and item.hold.code == hold.code and item.hold.message == hold.message)
	if item.status == status and same then return end
	item.hold = hold
	if item.status ~= status then
		item.status = status
		table.insert(item.history, { status = status, revision = revision, at_ms = stamp(clock).at_ms })
		if #item.history > 32 then table.remove(item.history, 1) end
	end
	item.revision += 1
end
local function landing_current(item: any): any?
	if item.status == "granted" or item.status == "landing" then return item.grants[#item.grants] end
	return nil
end
local function landing_unqueue(q: any, landing_id: string)
	local index = table.find(q.order, landing_id)
	if index then table.remove(q.order, index) end
	if q.slot == landing_id then q.slot = nil end
end
local function landing_settle(d: any, item: any)
	local w = d.workers[item.worker_id]
	if w then settle_entries(w, "event_id", item.request.event_id) end
	for _, g in item.grants do
		local holder = d.workers[g.worker_id]
		if holder then settle_entries(holder, "action_id", g.action_id) end
	end
end
local function landing_withdraw_gate(d: any, item: any, phase: string)
	local g = if item.gate_id then (d.gates or {})[item.gate_id] else nil
	if g and gate_open(g) then
		g.phase = phase; g.revision += 1
		g.delivery_uncertain = g.delivery ~= nil and not g.delivery.acknowledged
		local w = d.workers[g.worker_id]
		if w and not g.delivery_uncertain then settle_entries(w, "gate_id", g.id) end
	end
end
local function latest_checkpoint(w: any): any?
	local latest
	for _, bytes in flow(w).checkpoints do
		local cp = codec.decode_report(bytes, w)
		if cp and (not latest or cp.seq > latest.seq) then latest = cp end
	end
	return latest
end
-- The owner's answer on the item's exact approval gate. Reject or cancel withdraws the item.
local function landing_decision(d: any, item: any): string?
	if item.approval or not item.gate_id then return nil end
	local g = (d.gates or {})[item.gate_id]
	if not g then return nil end
	if g.answer and g.phase ~= "cancelled" and g.phase ~= "superseded" then
		if g.answer.choice_id == "approve" then
			item.approval = { gate_id = g.id, gate_revision = g.revision, at_ms = g.answer.at_ms }
			return nil
		end
		return "owner_rejected"
	end
	return if g.phase == "cancelled" then "approval_cancelled" else nil
end
-- A tripped refresh loop (Contract L) holds the item. Its owner gate is (re)opened here when the
-- trip could not open it (settlement reserve or full gate capacity), so the stop is never silent.
function loops.landing_hold(d: any, item: any, clock: any): any
	local loop, cap = item.refresh_loop, policy(d, item.logical_session_id).loop_cap
	local w = d.workers[item.worker_id]
	if loop.state == "gated" and not loops.gate(d, loop) and w then
		local _, err = loops.open(d, w, loop, "landing_refresh", item.id, "Landing refresh cycles reached " .. tostring(loop.count) .. " for " .. item.id
			.. "; last cause: " .. tostring(loop.cause or "target_moved") .. ". No further refresh notice or grant is issued for this item. Allow more refresh cycles, keep it stopped, or cancel the item.", cap, clock, true)
		if err then return landing_hold("loop_cap", "Landing refresh cycles reached the loop cap; the owner gate is deferred: " .. err.message) end
	end
	if loop.state == "stopped" then return landing_hold("loop_cap", "The owner stopped refresh cycles for this item at the loop cap; cancel it and request landing again. Nothing is retried.") end
	return landing_hold("loop_cap", "Landing refresh cycles reached the loop cap; answer loop gate " .. tostring(loop.gate_id) .. " to allow more cycles or keep it stopped.")
end
-- Readiness of an ungranted item, recomputed from durable evidence. A missing or stale fact
-- blocks with its reason; nothing passes by default.
local function landing_problem(n: any, item: any, q: any, clock: any, unordered_head: string?): any?
	local d = n.dispatch
	local w, r = d.workers[item.worker_id], item.request
	item.proof = nil
	if unordered_head then
		return landing_hold("repository_head_unordered", "A delayed result for " .. unordered_head
			.. " cannot be ordered against this repository's retained target head. Reconcile that exact attempt with a fresh read-only target observation before new grants or refresh notices.")
	end
	if q.repository == nil then
		return landing_hold("repository_unverified", "This pre-cutover request has no verified repository identity. Cancel it and publish a fresh helper CHECKOUT and LANDING_REQUEST; its old approvals and effects are not replayed.")
	end
	if item.refresh_loop and item.refresh_loop.state then return loops.landing_hold(d, item, clock) end
	if item.refresh_required then
		return landing_hold("refresh_required", "The previous grant was released without landing. The worker must publish a fresh LANDING_REQUEST (new artifact/evidence) against the current target head; nothing is retried automatically.")
	end
	if q.head and q.head.revision ~= r.target_revision then
		return landing_hold("target_moved", "Target head is now " .. q.head.revision .. " (" .. q.head.source .. " via " .. q.head.landing_id .. "); this request expects "
			.. r.target_revision .. ". The worker must refresh its artifact and evidence against the new head.")
	end
	if not w or w.phase ~= "accepted" or w.finish or w.release or w.stopped or w.mailbox_retired or flow(w).exit or w.frozen then
		return landing_hold("worker_unavailable", "The requesting generation is not an accepted, running worker. A continuing generation of this work must refresh the request.")
	end
	local identity, identity_error = config.repository_identity(n, w, r)
	if not identity then return landing_hold(identity_error.code, identity_error.message) end
	if not equal(identity, q.repository) then
		return landing_hold("repository_changed", "The current checkout, execution host or declared queue route differs from this request. Cancel it and request landing again with fresh evidence; no independent queue was granted.")
	end
	if w.continuation_required then return landing_hold("continuation_required", "Explicitly continue/reattach this worker after reload before any landing grant.") end
	if w.rejected_report then return landing_hold("report_held", "A rejected report from this worker is held; inspect it before any landing grant.") end
	if active_rollover(d, w) then return landing_hold("rollover_in_progress", "This worker is part of an unfinished rollover; the successor must refresh the request.") end
	if flow(w).report and flow(w).report.state == "blocked" then
		return landing_hold("worker_blocked", "The worker's latest report is BLOCKED; a new hold invalidates landing readiness until it reports progress again.")
	end
	local cp = latest_checkpoint(w)
	if cp and cp.payload.project_id ~= r.project_id then
		return landing_hold("scope_mismatch", "The worker's latest checkpoint names project " .. cp.payload.project_id .. ", not " .. r.project_id .. ".")
	end
	if not cp then return landing_hold("checkpoint_missing", "A structured CHECKPOINT for the exact source revision is required before a landing grant.") end
	if cp.payload.artifact_revision ~= r.source_revision then
		return landing_hold("verification_stale", "The worker's latest checkpoint is for another artifact revision; publish a fresh CHECKPOINT for the requested source revision.")
	end
	if #cp.payload.holds > 0 then
		return landing_hold("hold_present", "The latest checkpoint lists holds/blockers; landing waits for a fresh checkpoint without them.")
	end
	if config.checkout_mismatch(w, cp) then
		return landing_hold("checkout_mismatch", "Checkpoint " .. cp.payload.checkpoint_id .. " names worktree_ref " .. cp.payload.worktree_ref .. " but the latest helper CHECKOUT reported "
			.. w.checkout.worktree_path .. "; publish a CHECKPOINT from the reported checkout (or run the helper checkout again).")
	end
	if config.scope_blocked(w) then
		return landing_hold("scope_open", "The latest CHECKOUT changes files outside the declared scope (or the helper's changed-file list overflowed); answer its scope gate to accept the changes, or bring the checkout back in scope.")
	end
	if not d.catalogs[w.logical_session_id] or d.catalogs[w.logical_session_id].catalog_version ~= 2 then
		return landing_hold("catalog_incompatible", "Refresh a compatible SPAWN catalog version 2 before authorizing a new landing grant.")
	end
	local current_policy = policy(d, w.logical_session_id)
	local proof, problem = rules.verify_landing_proof({ require_code_review = current_policy.require_code_review,
		require_other_family = current_policy.require_other_family, source_revision = r.source_revision,
		checks = w.checks, check_results = w.check_results, builder_worker_id = w.worker_id, builder_record_id = w.record_id,
		builder_family = config.family_of(d, w), review = config.review_for(d, w) })
	if not proof then return landing_hold(problem.code, problem.message) end
	item.proof = proof
	local signer = config.signer_problem(d, item, w)
	if signer then return signer end
	if not item.approval then
		-- D8: with proof and signer complete, an in-scope item's own approval gate is answered by the
		-- session policy when `landing` is an auto_approve kind (never while paused).
		local g = if item.gate_id then (d.gates or {})[item.gate_id] else nil
		local p = policy(d, item.logical_session_id)
		if g and g.phase == "pending" and not p.paused and table.find(p.auto_approve_kinds, "landing")
			and config.in_scope(d, item.logical_session_id, item.work_id, "landing") and config.policy_answer(d, d.workers[g.worker_id], g, "landing", clock) then
			item.approval = { gate_id = g.id, gate_revision = g.revision, at_ms = g.answer.at_ms }
			return nil
		end
		return landing_hold("approval_pending", "Owner gate " .. tostring(item.gate_id) .. " must approve this exact request revision"
			.. (if table.find(p.auto_approve_kinds, "landing") then "; the session policy approves landing only for in-scope work (plan or board source, declared scope, no open scope/file_overlap/shared_checkout gate)." else "; landing is not an auto_approve kind in Config."))
	end
	return nil
end
local function landing_lost(w: any?): string?
	if not w then return "the granted worker generation record is missing" end
	if w.stopped or (w.workflow and w.workflow.exit) then return "the granted worker exited or was stopped" end
	if w.phase == "held" then return "the granted worker generation is held (" .. reason_text(w) .. ")" end
	if w.frozen then return "the granted worker's report stream is frozen on conflicting content" end
	if w.rejected_report then return "a report from the granted worker was rejected and is held (" .. w.rejected_report.code .. ")" end
	return nil
end
-- Contract I: the grant goes to the release-manager generation `rm` (the existing builder by default) and binds
-- the item's holder to it; the checkpoint and Contract D extras come from the requesting builder.
local function grant_landing(n: any, q: any, item: any, rm: any, event: any, clock: any): any?
	local d = n.dispatch
	local w, r = d.workers[item.worker_id], item.request
	if #item.grants >= 8 then
		-- The transport bound is structural: the loop_cap gate can only confirm the stop.
		local loop = item.grant_loop or { count = #item.grants, state = "gated" }
		item.grant_loop = loop
		local deferred = ""
		if loop.state == "gated" and not loops.gate(d, loop) then
			local _, err = loops.open(d, w, loop, "landing_grants", item.id, "Landing grants reached the transport bound 8 for " .. item.id
				.. ". No further grant can be issued for this item; cancel it and request landing again.", policy(d, item.logical_session_id).loop_cap, clock, false)
			if err then deferred = " The owner gate is deferred: " .. err.message end
		end
		return landing_hold("attempts_exhausted", "This item used its eight bounded grants (transport bound 8); cancel it and request landing again." .. deferred)
	end
	if not thread_room(rm) then return landing_hold("full", "The release manager's durable thread is full of unresolved items; no grant was issued.") end
	local grant_id = next_id(d, "landing-grant-")
	local proof = item.proof
	local review = if proof.review_id then (d.reviews or {})[proof.review_id] else nil
	local payload = { landing_id = item.id, grant_id = grant_id, project_id = r.project_id, checkpoint_id = latest_checkpoint(w).payload.checkpoint_id,
		repo_ref = r.repo_ref, target_ref = r.target_ref, target_revision = r.target_revision, source_ref = r.source_ref, source_revision = r.source_revision,
		builder_work_id = w.work_id, proof = { mode = proof.mode, artifact_revision = proof.artifact_revision,
			review_id = proof.review_id, check_refs = tern.json.array(clone(proof.check_refs)) } }
	if proof.mode ~= "review_disabled" then
		payload.review_id = proof.review_id; payload.reviewer_family = (if review then review.reviewer_family else nil) or "unknown"
	end
	local delivery, err = issue_reply(d, rm, "landing_grant", payload)
	if err then return landing_hold(err.code, err.message .. " No landing grant was issued.") end
	table.insert(item.grants, { grant_id = grant_id, worker_id = rm.worker_id, action_id = delivery.action_id, action_revision = delivery.action_revision,
		reply_seq = delivery.reply_seq, message_id = delivery.message_id, bytes = delivery.bytes, target_revision = r.target_revision,
		source_revision = r.source_revision, checkpoint_id = payload.checkpoint_id, controller_generation = event.origin.owner_generation,
		revision = n.revision, published = false, acknowledged = false })
	item.holder = { worker_id = rm.worker_id, worker_generation = rm.worker_generation }
	if q.repository.queue_route == "orch_queue" then q.slot = item.id end
	append(d, rm, "landing_grant", bounded("Landing " .. item.id .. " granted (" .. grant_id .. "): merge exactly " .. r.source_ref .. "@"
		.. r.source_revision .. " (builder work " .. w.work_id .. ") onto " .. r.repo_ref .. " " .. r.target_ref .. " expecting head " .. r.target_revision
		.. (if q.repository.queue_route == "repository_queue" then " through the owner-declared protected repository queue; do not bypass it"
			else " through the shared local ORCH repository/target queue")
		.. ", following the repository's own rules, then report one exact LANDING_RESULT.", 32768), clock,
		{ state = "pending", action_id = delivery.action_id })
	landing_status(item, "granted", nil, n.revision, clock)
	return nil
end
-- One durable builder refresh obligation (Contract L) covers target_moved and refresh_required (a
-- stale_target result or a not-landed reconciliation that moved the head): exactly one immutable
-- landing_refresh per (builder generation, expected head, current head), sent to the live
-- generation of the requesting work. Issuing it voids the work's review approval (behind-branch
-- rule: the rebased revision needs a fresh review). The obligation is derived from the item each
-- commit, so a deferred notice (full outbox, thread or reserve) is retried later without loss.
local function landing_refresh(n: any, q: any, item: any, hold: any, clock: any): any
	local d, r = n.dispatch, item.request
	if not q.head or q.head.revision == r.target_revision then return hold end -- No observed head to rebase onto.
	local w = config.review_builder(d, { builder_work_id = item.work_id, logical_session_id = item.logical_session_id }) or d.workers[item.worker_id]
	local sent = item.refresh
	if sent and w and sent.worker_id == w.worker_id and sent.expected_revision == r.target_revision and sent.current_revision == q.head.revision then return hold end
	local cause = if hold.code == "target_moved" then "target_moved" else "stale_target"
	-- Each new refresh notice is one engagement of the item's capped refresh loop (Contract L).
	if loops.trips(item.refresh_loop, policy(d, item.logical_session_id).loop_cap) then
		item.refresh_loop.state = item.refresh_loop.state or "gated"; item.refresh_loop.cause = cause
		return loops.landing_hold(d, item, clock)
	end
	local function deferred(why: string): any
		return landing_hold(hold.code, hold.message .. " Refresh notice deferred: " .. why .. " It is issued on a later commit.")
	end
	if not w or w.phase ~= "accepted" or not w.mailbox_handle or w.finish or w.release or w.stopped or w.mailbox_retired or w.frozen
		or flow(w).exit or active_rollover(d, w) then
		return deferred("the requesting work has no generation that can receive replies now.")
	end
	if type(clock) == "table" and clock.reserved_capacity then return deferred("authority capacity is at its settlement reserve.") end
	if not thread_room(w) then return deferred("the worker's durable thread is full of unresolved items.") end
	local next_steps = "Rebase or rebuild onto current_revision, publish a fresh CHECKPOINT and rerun every declared helper check for the new revision"
		.. (if policy(d, item.logical_session_id).require_code_review then ", publish REVIEW_READY for a fresh review (the earlier approval is void)"
			else "; code review is disabled, so do not request a reviewer")
		.. ", then publish a fresh LANDING_REQUEST expecting current_revision; it needs new owner approval. "
		.. (if policy(d, item.logical_session_id).merge_actor_mode == "worker" then
			"You may merge only after the exact new landing_grant is addressed to your accepted generation; a refresh or approval is not a merge grant."
			else "The selected release actor lands it only after its exact new landing_grant; builders do not merge in selected-actor mode.")
	local payload = { landing_id = item.id, project_id = r.project_id, repo_ref = r.repo_ref, target_ref = r.target_ref,
		expected_revision = r.target_revision, current_revision = q.head.revision,
		reason = (if cause == "target_moved" then "Target moved (" else "The release manager found the target moved (") .. q.head.source .. " via " .. q.head.landing_id
			.. "). " .. next_steps }
	local delivery, err = issue_reply(d, w, "landing_refresh", payload)
	if err then return deferred(err.message) end
	item.refresh = { worker_id = w.worker_id, worker_generation = w.worker_generation, expected_revision = r.target_revision, current_revision = q.head.revision, action_id = delivery.action_id,
		action_revision = delivery.action_revision, reply_seq = delivery.reply_seq, message_id = delivery.message_id, bytes = delivery.bytes,
		published = false, acknowledged = false, revision = n.revision }
	append(d, w, "landing_refresh", bounded("Landing " .. item.id .. " needs a refresh: " .. r.target_ref .. " moved from " .. r.target_revision
		.. " to " .. q.head.revision .. ". " .. next_steps, 32768), clock,
		{ action_id = delivery.action_id })
	-- The refresh voids on the moved target head (void.target_revision); a newer checkpoint voids on
	-- the builder's new artifact revision (void.artifact_revision, also every pre-8C record).
	for _, rv in d.reviews or {} do
		if rv.builder_work_id == item.work_id and rv.logical_session_id == item.logical_session_id and rv.status == "approved" and rv.void == nil then
			rv.void = { target_revision = q.head.revision, at_ms = stamp(clock).at_ms }; rv.revision += 1
		end
	end
	item.refresh_loop = item.refresh_loop or { count = 0 }
	item.refresh_loop.count += 1; item.refresh_loop.cause = cause
	return hold
end
-- One derived FIFO for each verified execution-host/common-directory/target identity.
-- Persistent partitions retain their own session's controls and immutable reply correlations.
function config.repository_groups(L: any): (any, boolean)
	local groups, unidentified, ranks = {}, false, {}
	for key, q in L.queues do
		if q.repository then
			local group = groups[q.repository.key]
			if not group then group = { partitions = {}, order = {}, positions = {} }; groups[q.repository.key] = group end
			group.partitions[key] = q
			if q.slot then group.slot = q.slot end
			for _, item_id in q.order do
				ranks[item_id] = config.serial(item_id)
				local grant = landing_current(L.items[item_id])
				if grant and grant.uncertain and grant.uncertain.code == "repository_head_unordered"
					and (group.unordered_head == nil or item_id < group.unordered_head) then group.unordered_head = item_id end
			end
		else
			for _, item_id in q.order do
				if landing_current(L.items[item_id]) then unidentified = true end
			end
		end
	end
	for _, group in groups do
		local cursors = {}
		while true do
			local selected, selected_queue
			for key, q in group.partitions do
				local item_id = q.order[cursors[key] or 1]
				if item_id and (selected == nil or item_id == group.slot
					or (selected ~= group.slot and (ranks[item_id] < ranks[selected] or (ranks[item_id] == ranks[selected] and item_id < selected)))) then
					selected, selected_queue = item_id, key
				end
			end
			if selected == nil then break end
			table.insert(group.order, selected)
			group.positions[selected] = #group.order
			cursors[selected_queue] = (cursors[selected_queue] or 1) + 1
		end
		group.first = group.order[1]
	end
	return groups, unidentified
end
function config.landing_owner_event(n: any, sid: string, triggering: any): any?
	local session = n.sessions[sid]
	if not session or session.phase ~= "open" or session.admitted ~= true or session.bridge_control then return nil end
	local current = if triggering.orch_session_id == sid then triggering else (n.dispatch.command_cursors or {})[sid]
	if not current or not authorized(n, current.origin, current.controller_pane) then return nil end
	-- This is automatic progression of an already approved item, not replay of another pane's input.
	return { orch_session_id = sid, origin = current.origin, controller_pane = current.controller_pane }
end
function config.landing_head(d: any, q: any, observation: any, expected_revision: string?): boolean
	local repository_key = if q.repository then q.repository.key else nil
	-- Arrival order is not repository order. Only a matching expected head can
	-- advance retained evidence automatically; owner observation passes no expectation.
	if expected_revision ~= nil then
		for _, other in d.landing.queues do
			if (other == q or (repository_key ~= nil and other.repository ~= nil and other.repository.key == repository_key))
				and other.head and other.head.revision ~= observation.revision and other.head.revision ~= expected_revision then return false end
		end
	end
	for _, other in d.landing.queues do
		if (other == q or (repository_key ~= nil and other.repository ~= nil and other.repository.key == repository_key))
			and (other.head == nil or other.head.revision ~= observation.revision) then
			other.head = clone(observation)
		end
	end
	return true
end
local function advance_landing(n: any, event: any, clock: any)
	local d = n.dispatch
	config.legacy_sweep(d)
	local L = d.landing
	if not L then return end
	local keys = config.sorted_keys(L.queues, function() return true end)
	local changed_sessions = {}
	for _, key in keys do
		local q = L.queues[key]
		for index = #q.order, 1, -1 do
			local item = L.items[q.order[index]]
			local decision = if LANDING_UNGRANTED[item.status] then landing_decision(d, item) else nil
			if decision then
				table.remove(q.order, index)
				landing_status(item, "cancelled", landing_hold(decision, if decision == "owner_rejected" then "The owner rejected this exact landing request; nothing was granted."
					else "The owner cancelled this landing approval gate; nothing was granted."), n.revision, clock)
				landing_settle(d, item)
				changed_sessions[item.logical_session_id] = true
			end
		end
		for _, item_id in q.order do
			local item = L.items[item_id]
			local grant = landing_current(item)
			if grant and not grant.uncertain then
				local lost = landing_lost(d.workers[grant.worker_id])
				if lost then
					grant.uncertain = { code = "result_lost", at_ms = stamp(clock).at_ms, message = bounded("No exact LANDING_RESULT can arrive: " .. lost
						.. ". The grant remains unresolved; reconcile the observed target state. Nothing is retried.", 1024) }
					item.revision += 1
					changed_sessions[item.logical_session_id] = true
				end
			end
		end
	end
	local groups, unidentified = config.repository_groups(L)
	for _, key in keys do
		local q = L.queues[key]
		local group = if q.repository then groups[q.repository.key] else nil
		local external = q.repository ~= nil and q.repository.queue_route == "repository_queue"
		for _, landing_id in q.order do
			local item = L.items[landing_id]
			if LANDING_UNGRANTED[item.status] then
				local before_revision = item.revision
				local hold = landing_problem(n, item, q, clock, if group then group.unordered_head else nil)
				if hold and (hold.code == "target_moved" or hold.code == "refresh_required") then hold = landing_refresh(n, q, item, hold, clock) end
				local eligible = external or (group ~= nil and group.first == landing_id and group.slot == nil)
				if eligible then
					if not hold and unidentified then hold = landing_hold("repository_unverified", "An outstanding pre-cutover landing grant has no verified repository identity. Settle or reconcile that grant before issuing another; nothing is replayed.") end
					if not hold and policy(d, item.logical_session_id).paused then hold = landing_hold("session_paused", "This item's session is paused; its approval cannot grant work until resume.") end
					if not hold and type(clock) == "table" and clock.reserved_capacity then
						hold = landing_hold("capacity_reached", "Authority capacity is at its settlement reserve; no landing grant is issued.")
					end
					local owner_event = config.landing_owner_event(n, item.logical_session_id, event)
					if not hold and not owner_event then hold = landing_hold("controller_unavailable", "This item's own session needs an active bound controller and reconciled native admission before automatic landing progression.") end
					local rm
					if not hold then rm, hold = config.release_manager_ready(n, item.logical_session_id, owner_event, clock, item, "landing") end
					if not hold then
						hold = grant_landing(n, q, item, rm, owner_event, clock)
						if not hold and not external then group.slot = item.id end
					end
					if hold then landing_status(item, if hold.code == "approval_pending" then "verifying" else "blocked", hold, n.revision, clock) end
				else
					local ready = hold == nil
					if not hold and group then
						hold = landing_hold("repository_wait", "Shared local repository/target queue is waiting for " .. tostring(group.slot or group.first)
							.. ". Other sessions use the same slot; acknowledging a shared checkout does not bypass it.")
					end
					landing_status(item, if ready then "ready" else "queued", hold, n.revision, clock)
				end
				if item.revision ~= before_revision then changed_sessions[item.logical_session_id] = true end
			end
		end
	end
	for _, w in d.workers do
		if w.logical_session_id ~= event.orch_session_id and changed_sessions[w.logical_session_id] then refresh(d, w, clock) end
	end
end
-- Evicts the oldest terminal entries (`done`, by last history revision, then key) until `map`
-- holds at most `keep`.
function config.evict_terminal(map: any, done: (any) -> any, keep: number)
	local terminal = {}
	for key, v in map do if done(v) then table.insert(terminal, { key = key, revision = v.history[#v.history].revision }) end end
	table.sort(terminal, function(a, b) return a.revision < b.revision or (a.revision == b.revision and a.key < b.key) end)
	for i = 1, math.min(#terminal, count(map) - keep) do map[terminal[i].key] = nil end
end
-- Bounded retention: oldest terminal items, then empty unreferenced queues (with their history).
-- A landed item whose deploy is still due or open stays: its deploy is addressed through it.
local function reclaim_landing(d: any, L: any, queue_needed: boolean)
	config.evict_terminal(L.items, function(item) return LANDING_TERMINAL[item.status] and not config.deploy_pins_item(d, item) end, 63)
	if not queue_needed or count(L.queues) < 32 then return end
	local empty = {}
	for key, q in L.queues do
		local pinned = false
		for _, item in L.items do if item.queue_id == key and config.deploy_pins_item(d, item) then pinned = true end end
		if #q.order == 0 and not q.slot and not pinned then table.insert(empty, key) end
	end
	table.sort(empty)
	for _, key in empty do
		if count(L.queues) < 32 then break end
		for item_key, item in L.items do if item.queue_id == key then L.items[item_key] = nil end end
		L.queues[key] = nil
	end
end
local function landing_request(n: any, w: any, report: any, clock: any): (any?, any?)
	local d, p = n.dispatch, report.payload
	if w.coordinator_owner_id or w.role ~= "builder" then return fail("landing_unauthorized", "Only the builder worker that owns the work requests landing; coordinators propose it and the release manager performs it.") end
	local repository, identity_error = config.repository_identity(n, w, p)
	if not repository then return nil, identity_error end
	local L = d.landing or { queues = {}, items = {} }
	local qid = landing_queue_id(w.logical_session_id, p, repository)
	local q, existing = L.queues[qid], nil
	for _, item in L.items do
		if item.logical_session_id == w.logical_session_id and item.work_id == w.work_id and not LANDING_TERMINAL[item.status]
			and config.repository_target(item.request.target_ref) == repository.target_ref then
			if existing then return fail("landing_ambiguous", "Multiple outstanding requests name this work and target. Settle them explicitly; no new grant was issued.") end
			existing = item
		end
	end
	if existing and not LANDING_UNGRANTED[existing.status] then
		return fail("landing_in_progress", "This work's landing for this target is granted to the release manager; its exact LANDING_RESULT or owner reconciliation settles before a new request.")
	end
	if existing and existing.queue_id ~= qid then
		return fail("landing_identity_changed", "Cancel the existing ungranted request before changing its repository identity or labels. Its approval, refresh replies and retained evidence were not rewritten.")
	end
	if not existing then
		if count(L.items) >= 64 or (not q and count(L.queues) >= 32) then reclaim_landing(d, L, not q) end
		if count(L.items) >= 64 or (not q and count(L.queues) >= 32) then return fail("full", "Landing queue capacity is full of open items; nothing was evicted.") end
	end
	local shared_head
	if not q then
		for _, other in L.queues do
			if other.repository and other.repository.key == repository.key and other.head then
				if shared_head and shared_head.revision ~= other.head.revision then
					return fail("repository_head_ambiguous", "Local partitions retain contradictory target observations. Reconcile the outstanding landing state before creating another request.")
				end
				shared_head = other.head
			end
		end
	end
	local landing_id = if existing then existing.id else next_id(d, "landing-")
	local question = "Approve landing " .. landing_id .. " (request report seq " .. tostring(report.seq) .. ")? Work " .. w.work_id .. " asks to land "
		.. p.source_ref .. "@" .. p.source_revision .. " (checkpoint " .. p.checkpoint_id .. ") onto " .. p.repo_ref .. " " .. p.target_ref
		.. " expecting head " .. p.target_revision .. ". Verified repository: " .. repository.common_dir .. "; route: " .. repository.queue_route
		.. ". Approval binds only this exact request; a refresh voids it. Every declared helper check must pass at this revision; code review and a different declared family are additionally required only when enabled in Config. The session's release manager (never the builder) follows the repository's rules. Local coordination covers this authority/data directory, not other machines."
	local gate, err = new_gate(d, w, "landing_approval", question, { { id = "approve", label = "Approve this exact landing" }, { id = "reject", label = "Reject" } },
		{ "landing:" .. landing_id, "request_event:" .. report.event_id, "checkpoint:" .. p.checkpoint_id,
			bounded("source:" .. p.source_ref .. "@" .. p.source_revision, 1024), bounded("target:" .. p.repo_ref .. " " .. p.target_ref .. "@" .. p.target_revision, 1024),
			"repository:" .. repository.key, "queue_route:" .. repository.queue_route }, clock)
	if err then return nil, err end
	local request = { project_id = p.project_id, repo_ref = p.repo_ref, target_ref = p.target_ref, target_revision = p.target_revision,
		source_ref = p.source_ref, source_revision = p.source_revision, checkpoint_id = p.checkpoint_id, summary = p.summary,
		event_id = report.event_id, seq = report.seq }
	if existing then
		landing_withdraw_gate(d, existing, "superseded")
		landing_settle(d, existing)
		existing.request = request; existing.worker_id = w.worker_id; existing.gate_id = gate.id
		existing.approval = nil; existing.proof = nil; existing.refresh_required = nil
		existing.revision += 1
		landing_status(existing, "queued", landing_hold("refreshed", "Request refreshed by report seq " .. tostring(report.seq) .. "; awaiting verification and owner approval."), n.revision, clock)
	else
		d.landing = L
		if not q then
			q = { id = qid, logical_session_id = w.logical_session_id, project_id = p.project_id, repo_ref = p.repo_ref,
				target_ref = p.target_ref, repository = repository, head = clone(shared_head), order = {} }
			L.queues[qid] = q
		end
		L.items[landing_id] = { id = landing_id, revision = 1, queue_id = qid, logical_session_id = w.logical_session_id, work_id = w.work_id,
			worker_id = w.worker_id, status = "queued", at_ms = stamp(clock).at_ms, request = request, gate_id = gate.id, grants = {},
			history = { { status = "queued", revision = n.revision, at_ms = stamp(clock).at_ms } } }
		table.insert(q.order, landing_id)
	end
	return result("landing_requested", { landing_id = landing_id }), nil
end
-- Contract I: only the holder — the release-manager generation the exact grant was issued to — may
-- report its LANDING_RESULT (semantic refuses every other role first: only exact grant holders report results).
local function landing_result(n: any, w: any, report: any, clock: any): (any?, any?)
	local d, p = n.dispatch, report.payload
	local item, grant
	for _, candidate in (d.landing or {}).items or {} do
		for _, g in candidate.grants do
			if g.worker_id == w.worker_id and g.action_id == report.action_id and g.action_revision == report.action_revision then item = candidate; grant = g end
		end
	end
	if not item then
		return fail("action_mismatch", "LANDING_RESULT must correlate to this worker's exact issued landing_grant action/revision; approvals, proposals and other replies cannot authorize a result.")
	end
	local r = item.request
	if p.landing_id ~= item.id or p.grant_id ~= grant.grant_id or p.project_id ~= r.project_id or p.repo_ref ~= r.repo_ref or p.target_ref ~= r.target_ref
		or p.target_revision ~= grant.target_revision or p.source_revision ~= grant.source_revision then
		return fail("revision_mismatch", "LANDING_RESULT must echo its exact grant: landing, grant, project, repository, target ref, expected head and source revision.")
	end
	if grant.result or grant.late_result then return fail("result_already_recorded", "This grant already has an immutable result; replay its original report bytes instead.") end
	local evidence = {}
	for i = 1, math.min(8, #p.evidence) do evidence[i] = p.evidence[i] end
	local summary = { outcome = p.outcome, result_revision = p.result_revision, observed_target_revision = p.observed_target_revision, reason = p.reason,
		pr_ref = p.pr_ref, summary = p.summary, evidence = evidence, event_id = report.event_id, seq = report.seq, at_ms = stamp(clock).at_ms }
	if landing_current(item) ~= grant or grant.uncertain then
		-- Late or post-uncertainty evidence never settles the slot; only owner reconciliation does.
		grant.late_result = summary; item.revision += 1
		return result("landing_result_recorded", { landing_id = item.id }), nil
	end
	local q = d.landing.queues[item.queue_id]
	local observed_head = if p.outcome == "landed" then p.result_revision elseif p.outcome == "stale_target" then p.observed_target_revision else nil
	if observed_head ~= nil and not config.landing_head(d, q, { revision = observed_head, source = p.outcome, landing_id = item.id }, grant.target_revision) then
		grant.late_result = summary
		grant.uncertain = { code = "repository_head_unordered", at_ms = summary.at_ms,
			message = "This exact result cannot establish ordering against the retained repository head. Inspect this attempt and the current target separately; no merge, grant or deploy is replayed." }
		item.revision += 1
		return result("landing_result_recorded", { landing_id = item.id }), nil
	end
	grant.result = summary
	if p.outcome == "uncertain" then
		grant.uncertain = { code = "worker_reported_uncertain", at_ms = summary.at_ms, message = bounded("The worker could not determine whether it landed: "
			.. p.reason .. ". The slot stays held until the owner reconciles the observed target state.", 1024) }
		item.revision += 1
	elseif p.outcome == "landed" then
		landing_unqueue(q, item.id)
		landing_status(item, "landed", nil, n.revision, clock); landing_settle(d, item)
		item.deploy_due = true -- Contract J: one deploy_grant follows the merge (advance_deploys).
	elseif p.outcome == "rejected" then
		landing_unqueue(q, item.id)
		landing_status(item, "failed", landing_hold("rejected", p.reason), n.revision, clock); landing_settle(d, item)
	else
		-- Stale target: release the slot; the item keeps its place but needs a fresh request. The
		-- builder's refresh notice (landing_refresh) is the counted refresh cycle (Contract L).
		q.slot = nil; item.refresh_required = true; item.approval = nil
		landing_status(item, "blocked", landing_hold("refresh_required", "Target head moved to " .. p.observed_target_revision
			.. "; the grant was released. The builder rebases, gets the new revision reviewed and publishes a fresh LANDING_REQUEST against the new head."), n.revision, clock)
	end
	return result("landing_result_recorded", { landing_id = item.id, outcome = p.outcome }), nil
end
-- DONE never means landed: a worker reporting DONE while holding a grant leaves it uncertain.
local function landing_done(d: any, w: any, clock: any)
	for _, item in (d.landing or {}).items or {} do
		local g = landing_current(item)
		if g and g.worker_id == w.worker_id and not g.uncertain then
			g.uncertain = { code = "result_missing", at_ms = stamp(clock).at_ms, message = "The worker reported DONE while holding this landing grant without its exact LANDING_RESULT. DONE never means landed; the slot stays held until the owner reconciles." }
			item.revision += 1
		end
	end
end
-- Release manager and deploys (Checkpoint 4: D5, Contracts I and J).
-- The release manager is one managed worker (role "release_manager", set by ORCH+) launched from
-- policy.release_manager_record; it alone receives landing/deploy grants and reports their results.
function config.serial(worker_id: string): number return tonumber(worker_id:match("(%d+)$") or "0") or 0 end
function config.rm_ended(d: any, w: any): boolean
	return w.stopped ~= nil or w.mailbox_retired == true or w.finish ~= nil or w.release ~= nil or (w.workflow ~= nil and w.workflow.exit ~= nil) or launch_rejected(d, w) or w.withdrawn ~= nil
end
-- The session's release manager: its newest generation that has not ended (accepted first, so a
-- rollover predecessor serves until its successor is accepted), and its newest ended generation.
function config.release_manager(d: any, sid: string): (any?, any?)
	local p = policy(d, sid)
	if p.merge_actor_mode ~= "selected_record" then return nil, nil end
	local live, ended
	for _, w in d.workers do
		if w.role == "release_manager" and w.logical_session_id == sid and w.record_id == p.release_manager_record then
			if config.rm_ended(d, w) then
				if not ended or config.serial(w.worker_id) > config.serial(ended.worker_id) then ended = w end
			else
				local rank = if w.phase == "accepted" then 2 else 1
				local best = if live then (if live.phase == "accepted" then 2 else 1) else 0
				if rank > best or (rank == best and config.serial(w.worker_id) > config.serial(live.worker_id)) then live = w end
			end
		end
	end
	return live, ended
end
function config.rm_row(d: any, sid: string, record: string): any?
	for _, row in (d.catalogs[sid] or {}).records or {} do if row.id == record then return row end end
	return nil
end
config.RM_CONFIG = " Choose a SPAWN agent with verified release-manager-v1 capability, or select a separate release agent in Settings."
function config.signer_problem(d: any, item: any, w: any): any?
	local sid, p = item.logical_session_id, policy(d, item.logical_session_id)
	local rm = if p.merge_actor_mode == "worker" then w else config.release_manager(d, sid)
	local record = if rm then rm.record_id else p.release_manager_record
	if record == "" then return landing_hold("release_manager_missing", "No merge actor is configured." .. config.RM_CONFIG) end
	local row = config.rm_row(d, sid, record)
	if not row or not row.eligible or row.enabled ~= true or not table.find(row.capabilities, "release-manager-v1") then
		return landing_hold("release_manager_refused", "Merge actor " .. record .. " is absent, disabled, ineligible or lacks release-manager-v1." .. config.RM_CONFIG)
	end
	local review = if item.proof and item.proof.review_id then (d.reviews or {})[item.proof.review_id] else nil
	local problem = rules.verify_signer({ mode = p.merge_actor_mode, release_manager_record_id = record, builder_record_id = w.record_id,
		reviewer_record_id = if review then review.reviewer_record_id else nil })
	if problem then return landing_hold(problem.code, problem.message .. config.RM_CONFIG) end
	return nil
end
-- Queues the session's release manager like a reviewer worker (existing provision/launch path).
-- The 32-worker cap holds the landing with backpressure; nothing is dropped.
function config.queue_release_manager(n: any, sid: string, row: any, event: any, clock: any): any?
	local d = n.dispatch
	if count(d.workers) >= 32 then reclaim_workers(n) end
	if count(d.workers) >= 32 then return { code = "full", message = "Managed generation capacity (32 workers) is full; the release manager launches when a slot frees. Nothing was dropped." } end
	if count(d.actions) >= 3072 then
		return { code = "full", message = "The durable dispatch ledger is near its bound; the release manager launches once settled actions are discarded. Nothing was dropped." }
	end
	local prompt = "You are the explicitly selected ORCH+ merge/deploy actor. Act only on the exact typed grants addressed to your own generation. After ACCEPTED, wait for landing_grant and deploy_grant replies. "
		.. "For a landing_grant, merge exactly source_ref@source_revision into target_ref following the repository's own rules (AGENTS.md/CLAUDE.md, branch protection, PR requirements); never merge another revision; "
		.. "An ORCH grant never authorizes bypassing an existing protected repository merge queue; use that route where the repository requires it. Local ORCH coordination is not cross-machine protection. "
		.. "report one exact LANDING_RESULT echoing the grant: landed with the resulting head, rejected with the reason (also when the repository's rules forbid it), stale_target with the observed head, or uncertain. "
		.. "For a deploy_grant, deploy exactly that revision only where the repository's rules define a deploy and its preconditions hold; report one exact DEPLOY_RESULT echoing deploy_id, attempt_id, landing_id and revision: "
		.. "deployed or failed with evidence, not_applicable when no deploy is defined, or held with the reason (migrations, service units, privilege files) and then wait for the owner's decision."
	local role_event = table.clone(event)
	for _, item in (d.landing or {}).items or {} do
		local builder = d.workers[item.worker_id]
		if item.logical_session_id == sid and not LANDING_TERMINAL[item.status] and builder and config.project_started(d, builder) then role_event.orch_project_id = builder.orch_project_id; break end
	end
	if not role_event.orch_project_id then return config.hold("project_held", "No started landing project needs a release manager.") end
	local w = config.new_worker(d, role_event, sid, row, prompt, "release-manager:" .. sid .. ":", "release_manager")
	config.bind_family(d, w)
	return config.provision_role(d, w, "release-manager", clock)
end
-- The release manager that may receive a grant now, launching the session's one release manager
-- when none exists. A generation that ended after acceptance is succeeded by a fresh launch; one
-- that never got accepted (refused launch) holds until the owner cancels it — no launch loop.
function config.release_manager_ready(n: any, sid: string, event: any, clock: any, item: any?, purpose: string): (any?, any?)
	local d = n.dispatch
	if policy(d, sid).merge_actor_mode == "worker" then
		local current = if item then config.review_builder(d, item) else nil
		local w = if purpose == "deploy" then current elseif item then d.workers[item.worker_id] else nil
		if not w or current ~= w then
			if purpose == "deploy" then
				return nil, landing_hold("deploy_actor_unavailable", "No current accepted builder generation can deploy this exact landed revision. Continue its retained session or use Stop pending deployment; the completed merge is not undone and no replacement agent is launched.")
			end
			return nil, landing_hold("merge_actor_changed", "The exact builder generation is no longer current. A successor needs its own artifact, checks and review; no replacement is launched.")
		end
		if w.phase ~= "accepted" or w.stopped or w.mailbox_retired or w.finish or w.release or w.continuation_required
			or not w.mailbox_handle or not w.pane_binding or active_rollover(d, w) or w.frozen or w.rejected_report then
			return nil, landing_hold("merge_actor_unavailable", "The existing builder must be accepted, current and continued, with no held report or rollover. Settle retained obligations; no new agent is launched.")
		end
		local row = config.rm_row(d, sid, w.record_id)
		if not row or not row.eligible or row.enabled ~= true
			or not table.find(row.capabilities or {}, "release-manager-v1") or not table.find(w.capabilities or {}, "release-manager-v1") then
			return nil, landing_hold("capability_missing", "This builder lacks current managed release-manager-v1 capability. Configure SPAWN or select a separate release agent; no grant or extra launch was issued.")
		end
		local signer = config.signer_problem(d, item, w)
		if signer then return nil, signer end
		if purpose == "deploy" and item.status ~= "landed" then
			return nil, landing_hold("deploy_not_landed", "Deploy only the exact retained landed revision; no new merge or deploy was granted.")
		end
		return w, nil
	end
	local rm, ended = config.release_manager(d, sid)
	if not rm then
		for _, prior in d.workers do
			if prior.logical_session_id == sid and prior.role == "release_manager"
				and (landing_open(d, prior.worker_id, true) or config.deploy_pinned(d, prior) or pending(d, prior)) then
				return nil, landing_hold("release_actor_obligations", "The previous selected release actor still owns an issued or uncertain effect. Settle that exact grant before another actor can be started; nothing is replayed.")
			end
		end
		if ended and ended.accepted_event == nil then
			return nil, landing_hold("release_manager_unavailable", "Release manager " .. ended.worker_id .. " never started (" .. reason_text(ended) .. "); cancel that work to let ORCH+ launch a fresh one." .. config.RM_CONFIG)
		end
		local record = policy(d, sid).release_manager_record
		local row = if record ~= "" then config.rm_row(d, sid, record) else nil
		if not row or not row.eligible or row.enabled ~= true or not table.find(row.capabilities, "release-manager-v1") then
			return nil, landing_hold(if record == "" then "release_manager_missing" else "release_manager_refused", "No release manager can be launched from Config." .. config.RM_CONFIG)
		end
		local problem = config.queue_release_manager(n, sid, row, event, clock)
		if problem then return nil, landing_hold(problem.code, "The release manager could not be launched: " .. problem.message) end
		return nil, landing_hold("release_manager_starting", "Release manager launched from record " .. row.id .. "; the grant is issued once it is accepted.")
	end
	if rm.phase ~= "accepted" then
		if rm.phase == "held" then return nil, landing_hold("release_manager_unavailable", "Release manager " .. rm.worker_id .. " is held (" .. reason_text(rm) .. ").") end
		return nil, landing_hold("release_manager_starting", "Release manager " .. rm.worker_id .. " is " .. rm.phase .. "; the grant is issued once it is accepted.")
	end
	if rm.continuation_required or not rm.mailbox_handle then
		return nil, landing_hold("release_manager_unavailable", "Explicitly continue/reattach release manager " .. rm.worker_id .. " before any grant.")
	end
	if rm.frozen or rm.rejected_report then
		return nil, landing_hold("release_manager_unavailable", "A report from release manager " .. rm.worker_id .. " is held or conflicting; inspect it before any grant.")
	end
	if active_rollover(d, rm) then
		return nil, landing_hold("release_manager_unavailable", "Release manager " .. rm.worker_id .. " is rolling over; new grants go to its accepted successor.")
	end
	if not table.find(rm.capabilities or {}, "release-manager-v1") then
		return nil, landing_hold("capability_missing", "Release manager " .. rm.worker_id .. " was not provisioned with release-manager-v1; SPAWN refuses grants to any other mailbox. No grant was issued.")
	end
	return rm, nil
end
-- Durable `deploys` (≤64, Contract J): one record per landed item, pinned while open. Each attempt
-- is exactly one deploy_grant for exactly the landed revision; a lost result is never re-granted.
config.DEPLOY_STATUSES = { "pending", "granted", "held", "deployed", "not_applicable", "failed", "uncertain", "stopped" }
config.DEPLOY_DONE = { deployed = true, not_applicable = true, stopped = true }
config.ATTEMPT_STATUSES = { "granted", "held", "deployed", "not_applicable", "failed", "uncertain" }
config.DEPLOY_KEYS = "deploy_id logical_session_id landing_id queue_id target_ref revision holder status attempts gate_id loop hold retry at_ms"
config.ATTEMPT_KEYS = "attempt_id worker_id worker_generation action_id action_revision reply_seq message_id bytes status published acknowledged ack_seq ack_sha256 result held late_result uncertain reconciliation revision"
config.ATTEMPT_BOUND = 16
function config.deploy_pinned(d: any, w: any): boolean
	for _, dp in d.deploys or {} do
		if not config.DEPLOY_DONE[dp.status] then
			for _, a in dp.attempts do if a.worker_id == w.worker_id then return true end end
		end
	end
	return false
end
-- A live (granted or held, not uncertain) deploy attempt blocks its holder's rollover.
function config.deploy_in_flight(d: any, worker_id: string): any?
	for _, dp in d.deploys or {} do
		local a = dp.attempts[#dp.attempts]
		if a and a.worker_id == worker_id and (dp.status == "granted" or dp.status == "held") and a.uncertain == nil then return dp end
	end
	return nil
end
function config.deploy_pins_item(d: any, item: any): boolean
	local dp = if item.deploy_id then (d.deploys or {})[item.deploy_id] else nil
	return item.deploy_due == true or (dp ~= nil and not config.DEPLOY_DONE[dp.status])
end
function config.deploy_of(d: any, item: any): any?
	return if item.deploy_id then (d.deploys or {})[item.deploy_id] else nil
end
function config.pending_deploy(d: any, item: any): any?
	local dp = config.deploy_of(d, item)
	return if item.status == "landed" and dp and dp.status == "pending" and #dp.attempts == 0 then dp else nil
end
-- Room for one more entry in a capped map: when full, evicts the oldest (lowest `rank`) entry
-- that `settled` selects.
function config.make_room(map: any, cap: number, settled: (any) -> any, rank: (any) -> number): boolean
	if count(map) < cap then return true end
	local oldest_key, oldest
	for key, v in map do
		if settled(v) and (not oldest or rank(v) < rank(oldest)) then oldest_key, oldest = key, v end
	end
	if oldest then map[oldest_key] = nil; return true end
	return false
end
function config.deploy_room(d: any): boolean
	d.deploys = d.deploys or {}
	return config.make_room(d.deploys, 64, function(dp) return config.DEPLOY_DONE[dp.status] end, function(dp) return config.serial(dp.deploy_id) end)
end
-- The landed head: the release manager's exact landed result, or the owner's landed reconciliation.
function config.landed_revision(item: any): string
	local g = item.grants[#item.grants]
	if g.reconciliation and g.reconciliation.outcome == "landed" then return g.reconciliation.target_revision end
	return g.result.result_revision
end
function config.deploy_hold(dp: any, item: any?, code: string, message: string)
	local hold = landing_hold(code, message)
	if not (dp.hold and dp.hold.code == hold.code and dp.hold.message == hold.message) then
		dp.hold = hold
		if item then item.revision += 1 end
	end
end
function config.deploy_status(dp: any, item: any?, status: string)
	if dp.status ~= status then dp.status = status; if item then item.revision += 1 end end
end
-- Issues one deploy attempt (one deploy_grant) to the session's ready release manager.
function config.issue_deploy(n: any, dp: any, item: any?, event: any, clock: any)
	local d = n.dispatch
	if policy(d, dp.logical_session_id).paused then return config.deploy_hold(dp, item, "session_paused", "Session is paused; no deploy grant is issued until resume.") end
	if type(clock) == "table" and clock.reserved_capacity then return config.deploy_hold(dp, item, "capacity_reached", "Authority capacity is at its settlement reserve; the deploy grant is issued on a later commit.") end
	local rm, hold = config.release_manager_ready(n, dp.logical_session_id, event, clock, item or (d.landing.items or {})[dp.landing_id], "deploy")
	if hold then return config.deploy_hold(dp, item, hold.code, hold.message .. " Stop the unissued deployment with “Stop pending deployment”, or repair the existing actor and recheck; nothing is relaunched.") end
	if not thread_room(rm) then return config.deploy_hold(dp, item, "full", "The release manager's durable thread is full of unresolved items; no deploy grant was issued.") end
	local attempt_id = next_id(d, "deploy-attempt-")
	local delivery, err = issue_reply(d, rm, "deploy_grant", { deploy_id = dp.deploy_id, attempt_id = attempt_id, landing_id = dp.landing_id, revision = dp.revision, target_ref = dp.target_ref })
	if err then return config.deploy_hold(dp, item, err.code, err.message .. " No deploy grant was issued.") end
	table.insert(dp.attempts, { attempt_id = attempt_id, worker_id = rm.worker_id, worker_generation = rm.worker_generation, action_id = delivery.action_id,
		action_revision = delivery.action_revision, reply_seq = delivery.reply_seq, message_id = delivery.message_id, bytes = delivery.bytes,
		status = "granted", published = false, acknowledged = false, revision = n.revision })
	dp.holder = { worker_id = rm.worker_id, worker_generation = rm.worker_generation }
	dp.loop = dp.loop or { count = 0 }
	dp.loop.count += 1
	dp.retry = nil; dp.hold = nil; dp.status = "granted"
	if item then item.revision += 1 end
	append(d, rm, "deploy_grant", bounded("Deploy " .. dp.deploy_id .. " attempt " .. attempt_id .. " granted for landing " .. dp.landing_id .. ": deploy exactly "
		.. dp.revision .. " of " .. dp.target_ref .. " only where the repository's rules define a deploy, then report one exact DEPLOY_RESULT.", 32768), clock,
		{ state = "pending", action_id = delivery.action_id })
end
-- The owner gate of a held or failed deploy. Held: on the attempt's own generation (it waits for the
-- relayed owner_decision). Failed: on the live release manager when there is one.
function config.deploy_gate(d: any, dp: any, item: any?, cause: string, clock: any)
	local a = dp.attempts[#dp.attempts]
	local w = d.workers[a.worker_id]
	if cause == "failed" then w = config.release_manager(d, dp.logical_session_id) or w end
	if not w then return config.deploy_hold(dp, item, "gate_deferred", "No release-manager generation remains to carry this deploy's owner gate.") end
	local options, question
	if cause == "held" then
		options = { { id = "deploy", label = "Proceed with the deploy" }, { id = "stop", label = "Do not deploy this revision" } }
		question = "Release manager held deploy " .. dp.deploy_id .. " (attempt " .. a.attempt_id .. ") of " .. dp.revision .. " on " .. dp.target_ref .. ": "
			.. tostring((a.held or {}).reason or "no reason given") .. ". Proceed (the release manager then deploys and reports the final DEPLOY_RESULT) or stop."
	else
		local why = if a.result then tostring(a.result.reason or "no reason given") else "reconciled not deployed"
		options = { { id = "retry", label = "Start a new deploy attempt" }, { id = "stop", label = "Stop — do not deploy" } }
		question = "Deploy " .. dp.deploy_id .. " of " .. dp.revision .. " on " .. dp.target_ref .. " failed (attempt " .. a.attempt_id .. ", " .. tostring(dp.loop and dp.loop.count or #dp.attempts)
			.. " of the loop cap " .. tostring(policy(d, dp.logical_session_id).loop_cap) .. "): " .. why .. ". A new attempt is issued only on your answer."
	end
	local g, err = new_gate(d, w, "deploy_hold", bounded(question, 32768), options,
		{ "deploy:" .. dp.deploy_id, "attempt:" .. a.attempt_id, "landing:" .. dp.landing_id, "cause:" .. cause }, clock)
	if err then return config.deploy_hold(dp, item, err.code, "The deploy's owner gate is deferred: " .. err.message) end
	dp.gate_id = g.id; dp.hold = nil
	if item then item.revision += 1 end
end
function config.deploy_ungate(d: any, dp: any)
	local g = if dp.gate_id then (d.gates or {})[dp.gate_id] else nil
	if g and gate_open(g) and g.phase == "pending" then
		g.phase = "superseded"; g.revision += 1
		local w = d.workers[g.worker_id]
		if w then settle_entries(w, "gate_id", g.id) end
	end
	dp.gate_id = nil
end
function config.deploy_settle(d: any, dp: any)
	for _, a in dp.attempts do
		local w = d.workers[a.worker_id]
		if w then settle_entries(w, "action_id", a.action_id) end
	end
end
function config.advance_deploy(n: any, dp: any, event: any, clock: any)
	local d = n.dispatch
	local item = ((d.landing or {}).items or {})[dp.landing_id]
	local a = dp.attempts[#dp.attempts]
	-- Recovery: a live attempt whose holder generation can no longer report is uncertain, never re-granted.
	if a and (dp.status == "granted" or dp.status == "held") and a.uncertain == nil then
		local lost = landing_lost(d.workers[a.worker_id])
		if lost then
			a.uncertain = { code = "result_lost", at_ms = stamp(clock).at_ms, message = bounded("No exact DEPLOY_RESULT can arrive: " .. lost
				.. ". Reconcile the observed deploy state; nothing is re-granted.", 1024) }
			a.status = "uncertain"; config.deploy_ungate(d, dp); config.deploy_status(dp, item, "uncertain")
		end
	end
	-- The owner's answer on the deploy's gate (relayed to the release manager as owner_decision).
	local g = if dp.gate_id then (d.gates or {})[dp.gate_id] else nil
	if dp.gate_id and not g then dp.gate_id = nil end
	if g and g.answer and g.phase ~= "cancelled" and g.phase ~= "superseded" then
		dp.gate_id = nil
		if dp.status == "held" and g.answer.choice_id == "deploy" then a.status = "granted"; config.deploy_status(dp, item, "granted")
		elseif dp.status == "failed" and g.answer.choice_id == "retry" then dp.retry = true; if item then item.revision += 1 end
		else config.deploy_status(dp, item, "stopped"); config.deploy_settle(d, dp) end
	elseif g and (g.phase == "cancelled" or g.phase == "superseded") then
		dp.gate_id = nil
		if g.phase == "cancelled" then config.deploy_status(dp, item, "stopped"); config.deploy_settle(d, dp) end
	end
	if config.DEPLOY_DONE[dp.status] then return end
	if dp.loop and dp.loop.state == "stopped" then config.deploy_status(dp, item, "stopped"); config.deploy_settle(d, dp); return end
	if dp.status == "pending" then config.issue_deploy(n, dp, item, event, clock); return end
	if dp.status == "held" then
		if not dp.gate_id then config.deploy_gate(d, dp, item, "held", clock) end
		return
	end
	if dp.status ~= "failed" then return end
	local cap = policy(d, dp.logical_session_id).loop_cap
	if #dp.attempts >= config.ATTEMPT_BOUND or loops.trips(dp.loop, cap) then
		-- Contract L: deploy attempts stop at loop_cap behind one owner loop_cap gate.
		local structural = #dp.attempts >= config.ATTEMPT_BOUND
		local w = config.release_manager(d, dp.logical_session_id) or d.workers[a.worker_id]
		if dp.loop.state == "gated" and loops.gate(d, dp.loop) then return end
		if not w then return config.deploy_hold(dp, item, "loop_cap", "Deploy attempts reached the loop cap; no release-manager generation remains to carry the owner gate.") end
		local _, err = loops.open(d, w, dp.loop, "deploy_attempts", dp.deploy_id, bounded("Deploy " .. dp.deploy_id .. " of " .. dp.revision .. " failed after "
			.. tostring(#dp.attempts) .. " attempt(s)" .. (if structural then ", the structural bound " .. tostring(config.ATTEMPT_BOUND) else ", the loop cap " .. tostring(cap))
			.. ". No further deploy grant is issued unless you allow more attempts.", 32768), cap, clock, not structural)
		config.deploy_hold(dp, item, "loop_cap", if err then "Deploy attempts reached the loop cap; the owner gate is deferred: " .. err.message
			else "Deploy attempts reached the loop cap; answer loop gate " .. tostring(dp.loop.gate_id) .. " to allow more attempts or keep it stopped.")
		return
	end
	if dp.retry then config.issue_deploy(n, dp, item, event, clock)
	elseif not dp.gate_id then config.deploy_gate(d, dp, item, "failed", clock) end
end
-- Runs at the end of every dispatch commit for the event's session, after advance_landing.
function config.advance_deploys(n: any, event: any, clock: any)
	local d, sid = n.dispatch, event.orch_session_id
	for _, key in config.sorted_keys((d.landing or {}).items or {}, function(_, item) return item.logical_session_id == sid and item.deploy_due end) do
		local item = d.landing.items[key]
		if not config.deploy_room(d) then break end
		local dp = { deploy_id = next_id(d, "deploy-"), logical_session_id = sid, landing_id = item.id, queue_id = item.queue_id, target_ref = item.request.target_ref,
			revision = config.landed_revision(item), status = "pending", attempts = {}, at_ms = stamp(clock).at_ms }
		d.deploys[dp.deploy_id] = dp; item.deploy_id = dp.deploy_id; item.deploy_due = nil; item.revision += 1
	end
	for _, key in config.sorted_keys(d.deploys or {}, function(_, dp) return dp.logical_session_id == sid and not config.DEPLOY_DONE[dp.status] end,
		function(a, b) return config.serial(a) < config.serial(b) end) do config.advance_deploy(n, d.deploys[key], event, clock) end
end
-- The release manager's DEPLOY_RESULT for exactly one deploy_grant attempt (its action/revision, or
-- the owner_decision of that attempt's deploy_hold gate after a hold).
function config.deploy_result(n: any, w: any, report: any, correlation: any, clock: any): any?
	local d, p = n.dispatch, report.payload
	local dp = (d.deploys or {})[p.deploy_id]
	local a
	for _, attempt in (if dp then dp.attempts else {}) do if attempt.attempt_id == p.attempt_id then a = attempt end end
	local gated = type(correlation) == "table" and correlation.kind == "deploy_hold" and a ~= nil and correlation.evidence[2] == "attempt:" .. a.attempt_id
	if not a or a.worker_id ~= w.worker_id or (correlation ~= a and not gated) then
		return config.refusal("action_mismatch", "DEPLOY_RESULT must correlate to this worker's exact deploy_grant action/revision (or that attempt's deploy_hold decision).")
	end
	if p.landing_id ~= dp.landing_id or p.revision ~= dp.revision then
		return config.refusal("revision_mismatch", "DEPLOY_RESULT must echo its exact grant: deploy, attempt, landing and revision.")
	end
	local item = ((d.landing or {}).items or {})[dp.landing_id]
	local evidence = {}
	for i = 1, math.min(16, #p.evidence) do evidence[i] = p.evidence[i] end
	local summary = { outcome = p.outcome, revision = p.revision, evidence = evidence, reason = p.reason, event_id = report.event_id, seq = report.seq, at_ms = stamp(clock).at_ms }
	if a ~= dp.attempts[#dp.attempts] or a.uncertain or config.DEPLOY_DONE[dp.status] or dp.status == "failed" then
		-- Late or post-uncertainty evidence never settles a deploy; only owner reconciliation does.
		if a.result or a.late_result then return config.refusal("result_already_recorded", "This deploy attempt already has an immutable result; replay its original report bytes instead.") end
		a.late_result = summary; if item then item.revision += 1 end
		return nil
	end
	config.deploy_ungate(d, dp)
	if p.outcome == "held" then
		a.held = summary; a.status = "held"; config.deploy_status(dp, item, "held")
		return nil
	end
	a.result = summary; a.status = p.outcome; config.deploy_status(dp, item, if p.outcome == "failed" then "failed" else p.outcome)
	if p.outcome ~= "failed" then config.deploy_settle(d, dp) end
	return nil
end
-- DONE never means deployed: DONE while holding a live deploy attempt leaves it uncertain.
function config.deploy_done(d: any, w: any, clock: any)
	for _, dp in d.deploys or {} do
		local a = dp.attempts[#dp.attempts]
		if a and a.worker_id == w.worker_id and (dp.status == "granted" or dp.status == "held") and a.uncertain == nil then
			a.uncertain = { code = "result_missing", at_ms = stamp(clock).at_ms, message = "The release manager reported DONE while holding this deploy grant without its exact DEPLOY_RESULT. DONE never means deployed; reconcile the observed deploy state." }
			a.status = "uncertain"; config.deploy_ungate(d, dp); dp.status = "uncertain"
			local item = ((d.landing or {}).items or {})[dp.landing_id]
			if item then item.revision += 1 end
		end
	end
end
function config.valid_deploy_result(v: any): boolean
	if not closed(v, "outcome revision evidence reason event_id seq at_ms") or not table.find({ "deployed", "held", "not_applicable", "failed" }, v.outcome)
		or not wire_text(v.revision, 1024) or not dense(v.evidence, 16) or (v.reason ~= nil and not wire_text(v.reason, 1024)) or not id(v.event_id)
		or not pos(v.seq) or not (v.at_ms == 0 or pos(v.at_ms)) then return false end
	for _, entry in v.evidence do if not wire_text(entry, 1024) then return false end end
	return true
end
function config.valid_deploys(d: any, registry: any): boolean
	if d.deploys == nil then return true end
	if type(d.deploys) ~= "table" or d.deploys == tern.json.null or count(d.deploys) > 64 then return false end
	local items = (d.landing or {}).items or {}
	for key, dp in d.deploys do
		if not closed(dp, config.DEPLOY_KEYS) or not id(key) or dp.deploy_id ~= key or not registry.sessions[dp.logical_session_id] or not id(dp.landing_id)
			or not id(dp.queue_id) or not wire_text(dp.target_ref, 1024) or not wire_text(dp.revision, 1024) or not table.find(config.DEPLOY_STATUSES, dp.status)
			or not dense(dp.attempts, config.ATTEMPT_BOUND) or (dp.gate_id ~= nil and not id(dp.gate_id)) or (dp.loop ~= nil and not loops.valid(dp.loop))
			or (dp.retry ~= nil and (dp.retry ~= true or dp.status ~= "failed")) or not (dp.at_ms == 0 or pos(dp.at_ms))
			or (dp.status == "pending" and #dp.attempts ~= 0)
			or (#dp.attempts == 0 and dp.status ~= "pending" and dp.status ~= "stopped") then return false end
		if dp.hold ~= nil and (not closed(dp.hold, "code message") or not str(dp.hold.code, 96) or not wire_text(dp.hold.message, 1024)) then return false end
		local h, last = dp.holder, dp.attempts[#dp.attempts]
		if (h == nil) ~= (last == nil) or (h ~= nil and (not closed(h, "worker_id worker_generation") or h.worker_id ~= last.worker_id or h.worker_generation ~= last.worker_generation)) then return false end
		local item = items[dp.landing_id]
		if not config.DEPLOY_DONE[dp.status] and (not item or item.status ~= "landed" or item.deploy_id ~= key or item.logical_session_id ~= dp.logical_session_id) then return false end
		for index, a in dp.attempts do
			if not closed(a, config.ATTEMPT_KEYS) or not id(a.attempt_id) or not id(a.worker_id) or not pos(a.worker_generation) or not id(a.action_id)
				or not pos(a.action_revision) or not pos(a.reply_seq) or not id(a.message_id) or type(a.bytes) ~= "string" or not table.find(config.ATTEMPT_STATUSES, a.status)
				or type(a.published) ~= "boolean" or type(a.acknowledged) ~= "boolean" or not pos(a.revision) or a.revision > registry.revision then return false end
			for _, name in { "result", "held", "late_result" } do if a[name] ~= nil and not config.valid_deploy_result(a[name]) then return false end end
			if (a.result ~= nil and (a.result.outcome == "held" or a.result.outcome ~= a.status and a.uncertain == nil)) or (a.held ~= nil and a.held.outcome ~= "held")
				or (a.late_result ~= nil and a.uncertain == nil and a.result == nil and a.held == nil) or (a.status == "held" and a.held == nil) then return false end
			if (a.uncertain ~= nil) ~= (a.status == "uncertain") or (a.uncertain ~= nil and (not closed(a.uncertain, "code message at_ms") or not str(a.uncertain.code, 96)
				or not wire_text(a.uncertain.message, 1024) or not (a.uncertain.at_ms == 0 or pos(a.uncertain.at_ms)))) then return false end
			local r = a.reconciliation
			if r ~= nil and (not closed(r, "outcome reason source at_ms revision") or (r.outcome ~= "deployed" and r.outcome ~= "not_deployed") or a.uncertain == nil
				or not wire_text(r.reason, 1024) or not M.origin(r.source) or not (r.at_ms == 0 or pos(r.at_ms)) or not pos(r.revision) or r.revision > registry.revision) then return false end
			-- Earlier attempts ended without deploying (failed, or reconciled not deployed).
			if index < #dp.attempts and not (a.status == "failed" or (r ~= nil and r.outcome == "not_deployed")) then return false end
			local w = d.workers[a.worker_id]
			if w then
				local reply = codec.decode_reply(a.bytes, w)
				if not valid_delivery(a, w, reply, "deploy_grant") or reply.payload.deploy_id ~= key or reply.payload.attempt_id ~= a.attempt_id
					or reply.payload.landing_id ~= dp.landing_id or reply.payload.revision ~= dp.revision or w.worker_generation ~= a.worker_generation then return false end
				for _, name in { "result", "held", "late_result" } do if a[name] ~= nil and a[name].seq > w.accepted_seq then return false end end
			end
		end
		if last then
			local r = last.reconciliation
			local ok = (dp.status == "granted" and last.status == "granted") or (dp.status == "held" and last.status == "held")
				or (dp.status == "uncertain" and last.status == "uncertain" and r == nil)
				or ((dp.status == "deployed" or dp.status == "not_applicable") and (last.status == dp.status or (r ~= nil and r.outcome == "deployed" and dp.status == "deployed")))
				or (dp.status == "failed" and (last.status == "failed" or (r ~= nil and r.outcome == "not_deployed"))) or dp.status == "stopped"
			if not ok then return false end
		end
	end
	return true
end
function config.deploy_view(d: any, dp: any?): any?
	if not dp then return nil end
	local a = dp.attempts[#dp.attempts]
	return { deploy_id = dp.deploy_id, status = dp.status, revision = dp.revision, target_ref = dp.target_ref, holder = clone(dp.holder), attempts = #dp.attempts,
		hold = clone(dp.hold), gate_id = dp.gate_id, loop = clone(dp.loop), retry = dp.retry == true,
		current = if a then { attempt_id = a.attempt_id, worker_id = a.worker_id, status = a.status, published = a.published, acknowledged = a.acknowledged,
			result = clone(a.result), held = clone(a.held), late_result = clone(a.late_result), uncertain = clone(a.uncertain), reconciliation = clone(a.reconciliation) } else nil,
		markable_lost = a ~= nil and (dp.status == "granted" or dp.status == "held") and a.uncertain == nil,
		reconcilable = a ~= nil and dp.status == "uncertain" }
end
function config.worker_ref(d: any, worker_id: string?): any?
	local w = if worker_id then d.workers[worker_id] else nil
	if not w then return if worker_id then { worker_id = worker_id } else nil end
	return { worker_id = w.worker_id, work_id = w.work_id, worker_generation = w.worker_generation, record_id = w.record_id, phase = w.phase, family = config.family_of(d, w) }
end
-- Landing row extras (Task 4B): requester builder, reviewer behind the proof (or the latest review),
-- the holder generation, the release manager (holder, else the session's live one) and the deploy.
function config.landing_extras(d: any, item: any, out: any)
	local b = d.workers[item.worker_id]
	out.builder = config.worker_ref(d, item.worker_id)
	local rv = if item.proof and item.proof.review_id then (d.reviews or {})[item.proof.review_id]
		else (if b and policy(d, item.logical_session_id).require_code_review then config.review_for(d, b) else nil)
	out.reviewer = if rv then { review_id = rv.review_id, worker_id = rv.reviewer_worker_id, record_id = rv.reviewer_record_id, family = rv.reviewer_family } else nil
	local h = item.holder
	local hw = if h then d.workers[h.worker_id] else nil
	out.holder = if h then { worker_id = h.worker_id, worker_generation = h.worker_generation, record_id = if hw then hw.record_id else nil } else nil
	out.release_manager = config.worker_ref(d, if h and not LANDING_TERMINAL[item.status] then h.worker_id else (config.release_manager(d, item.logical_session_id) or {}).worker_id)
	out.deploy_due = item.deploy_due == true
	out.deploy = config.deploy_view(d, config.deploy_of(d, item))
end
-- Cross-family judge and targeted rework (Checkpoint 3: D1-Y proof, D3 rounds, D4 rework).
-- Durable `reviews` (≤64): one record per review of a builder work, spanning its rounds. A
-- fresh reviewer worker (role "reviewer", set by ORCH+) answers each round's fixed question with
-- one REVIEW_RESULT; the record then owns that evidence, so the reviewer is never pinned by it.
-- Open records pin the builder work and the awaited reviewer; a terminal record is reclaimed
-- oldest first unless it is still its work's latest review while the work is alive.
config.REVIEW_STATUSES = { "queued", "requested", "approved", "changes_required", "capped", "cancelled" }
config.REVIEW_OPEN = { queued = true, requested = true, changes_required = true }
config.REVIEW_KEYS = "review_id revision logical_session_id builder_worker_id builder_work_id builder_family builder_record_id reviewer_worker_id reviewer_record_id reviewer_family round artifact_revision checkpoint_id task_ref source_ref worktree_path plan_ref plan_revision scope_paths status result findings refusal gate_id loop hold request rework void trigger at_ms"
-- The fixed judge question (Contract D): one question, no score, no confidence.
config.JUDGE_QUESTION = "Does the change at %s@%s implement %s as specified, without changes outside %s? Answer approved, or changes_required with findings tied to file and line."
function config.review_serial(rv: any): number return tonumber(tostring(rv.review_id):match("(%d+)$") or "0") or 0 end
function config.review_of(d: any, w: any): any?
	local best
	for _, rv in d.reviews or {} do
		if rv.builder_work_id == w.work_id and rv.logical_session_id == w.logical_session_id
			and (not best or config.review_serial(rv) > config.review_serial(best)) then best = rv end
	end
	return best
end
-- A generation of the reviewed work that has not ended (rollover successors count); accepted first.
function config.review_builder(d: any, rv: any): any?
	local best
	for _, w in d.workers do
		if w.work_id == (rv.builder_work_id or rv.work_id) and w.logical_session_id == rv.logical_session_id and not w.stopped and not w.mailbox_retired
			and not w.finish and not w.release and not (w.workflow and w.workflow.exit) then
			local rank = if w.phase == "accepted" then 2 else 1
			local best_rank = if best then (if best.phase == "accepted" then 2 else 1) else 0
			if rank > best_rank or (rank == best_rank and config.serial(w.worker_id) > config.serial(best.worker_id)) then best = w end
		end
	end
	return best
end
-- Disabling review cancels its authority, not an already-issued reviewer's settlement obligation.
-- The existing report evidence settles it; it never becomes an approved/completed review result.
function config.cancelled_review_pending(d: any, rv: any): boolean
	if rv.status ~= "cancelled" or not rv.hold or rv.hold.code ~= "review_disabled" or not rv.request or rv.result then return false end
	local w = d.workers[rv.reviewer_worker_id]
	local bytes = w and w.workflow and w.workflow.evidence.REVIEW_RESULT
	local report = if bytes then codec.decode_report(bytes, w) else nil
	return not report or report.action_id ~= rv.request.action_id or report.action_revision ~= rv.request.action_revision
		or report.payload.review_id ~= rv.review_id or report.payload.round ~= rv.round or report.payload.artifact_revision ~= rv.artifact_revision
end
function config.review_pinned(d: any, w: any): boolean
	for _, rv in d.reviews or {} do
		if rv.logical_session_id == w.logical_session_id then
			if config.REVIEW_OPEN[rv.status] and rv.builder_work_id == w.work_id then return true end
			if rv.reviewer_worker_id == w.worker_id and (rv.status == "queued" or rv.status == "requested" or config.cancelled_review_pending(d, rv)) then return true end
		end
	end
	return false
end
function config.review_room(d: any): boolean
	d.reviews = d.reviews or {}
	return config.make_room(d.reviews, 64, function(rv)
		local needed = config.review_of(d, { work_id = rv.builder_work_id, logical_session_id = rv.logical_session_id }) == rv and config.review_builder(d, rv) ~= nil
		return not config.REVIEW_OPEN[rv.status] and not needed and not config.cancelled_review_pending(d, rv)
	end, config.review_serial)
end
-- Binds a review round to the builder generation and checkpoint that asked for it.
function config.review_bind(d: any, rv: any, w: any, cp: any)
	local p = cp.payload
	rv.builder_worker_id = w.worker_id; rv.builder_record_id = w.record_id; rv.builder_family = config.family_of(d, w)
	rv.artifact_revision = p.artifact_revision; rv.checkpoint_id = p.checkpoint_id; rv.task_ref = p.task_ref
	rv.source_ref = if w.checkout and w.checkout.branch ~= "" then w.checkout.branch else p.worktree_ref
	rv.worktree_path = if w.checkout and w.checkout.head == p.artifact_revision and not config.checkout_mismatch(w, cp) then w.checkout.worktree_path else nil
	rv.plan_ref = p.plan_ref; rv.plan_revision = p.plan_revision
	rv.scope_paths = clone(if w.scope and #w.scope.paths > 0 then w.scope.paths else (w.files or {}))
	rv.reviewer_worker_id = nil; rv.reviewer_record_id = nil; rv.reviewer_family = nil
	rv.request = nil; rv.rework = nil; rv.hold = nil; rv.result = nil
end
-- One open review per builder work. Returns the review, a non-fatal note (nothing new opened), or a problem.
function config.open_review(n: any, w: any, cp: any, trigger: string, clock: any): (any?, string?, any?)
	local d = n.dispatch
	if not policy(d, w.logical_session_id).require_code_review then
		return nil, "Code review is disabled in this session; enable Require code review in Config to request review.", nil
	end
	local p = cp.payload
	local latest = config.review_of(d, w)
	if latest and config.REVIEW_OPEN[latest.status] then
		if latest.status == "changes_required" and latest.artifact_revision ~= p.artifact_revision then
			-- Next round (the round cap is applied when a round's result arrives): fresh reviewer, prior findings kept as findings_prev.
			latest.round += 1; config.review_bind(d, latest, w, cp); latest.status = "queued"; latest.refusal = nil; latest.revision += 1
			return latest, nil, nil
		elseif latest.status == "queued" and latest.reviewer_worker_id == nil then
			config.review_bind(d, latest, w, cp); latest.revision += 1 -- No reviewer engaged yet: the newest revision is reviewed.
			return latest, nil, nil
		end
		return nil, bounded("Review " .. latest.review_id .. " of " .. w.work_id .. " is already " .. latest.status .. " (round " .. tostring(latest.round) .. ", revision "
			.. latest.artifact_revision .. "); one review per work is open at a time" .. (if latest.status == "changes_required" then " and its next round needs a new artifact revision" else "")
			.. ". Nothing new was requested.", 1024), nil
	end
	if latest and latest.status == "approved" and latest.void == nil and latest.artifact_revision == p.artifact_revision then
		return nil, "Review " .. latest.review_id .. " already approved revision " .. latest.artifact_revision .. "; nothing new was requested.", nil
	end
	if latest and latest.status == "capped" then
		return nil, bounded("Review " .. latest.review_id .. " of " .. w.work_id .. " reached the review-round cap (" .. tostring(latest.round)
			.. " rounds) without approval; no further review is requested for this work.", 1024), nil
	end
	if not config.review_room(d) then
		return nil, nil, config.refusal("full", "Durable review capacity (64) is full of open or still-needed reviews; nothing was evicted.")
	end
	local rv: any = { review_id = next_id(d, "review-"), revision = 1, logical_session_id = w.logical_session_id, builder_work_id = w.work_id,
		round = 1, status = "queued", findings = {}, trigger = trigger, at_ms = stamp(clock).at_ms }
	config.review_bind(d, rv, w, cp)
	d.reviews[rv.review_id] = rv
	return rv, nil, nil
end
-- Builder REVIEW_READY: opens (or advances) this work's review. Other roles only record evidence.
function config.review_ready(n: any, w: any, checkpoint: any, clock: any): any?
	if w.role ~= "builder" then return nil end
	if not policy(n.dispatch, w.logical_session_id).require_code_review then config.settle_review_ready(w); return nil end
	local rv, note, problem = config.open_review(n, w, checkpoint, "review_ready", clock)
	if problem then return problem end
	if note then local _, err = append(n.dispatch, w, "attention", note, clock); if err then return err end end
	if rv then local _, err = append(n.dispatch, w, "review", "Review " .. rv.review_id .. " round " .. tostring(rv.round) .. " queued for " .. rv.artifact_revision .. ".", clock); if err then return err end end
	return nil
end
function config.review_void(d: any, w: any, cp: any, clock: any)
	for _, rv in d.reviews or {} do
		if rv.builder_work_id == w.work_id and rv.logical_session_id == w.logical_session_id and rv.status == "approved" and rv.void == nil
			and rv.artifact_revision ~= cp.payload.artifact_revision then
			rv.void = { artifact_revision = cp.payload.artifact_revision, at_ms = stamp(clock).at_ms }; rv.revision += 1
		end
	end
end
function config.review_refusal(d: any, w: any): (string, string)
	if w.role == "coordinator" or w.coordinator_owner_id then
		return "review_unauthorized", "Coordinators no longer file REVIEW_RESULT; propose review and an owner-approved proposal opens a reviewer-worker review."
	end
	for _, rv in d.reviews or {} do
		if rv.builder_work_id == w.work_id and rv.logical_session_id == w.logical_session_id then
			return "reviewer_is_builder", "The builder cannot review its own work; only the reviewer worker ORCH+ launched for this review files its REVIEW_RESULT."
		end
	end
	return "reviewer_role_required", "REVIEW_RESULT is accepted only from a reviewer worker ORCH+ launched for a review, echoing its review_request."
end
function config.settle_review_ready(b: any)
	local entries = flow(b).thread
	for i = #entries, 1, -1 do if entries[i].kind == "REVIEW_READY" then table.remove(entries, i) end end
end
-- The reviewer's REVIEW_RESULT for exactly its review_request (review_id, round, artifact_revision).
-- Policy refusals (record or family) are recorded on the review, which returns to queued for a
-- fresh reviewer; the refused report itself is accepted so the reviewer's lane never jams.
function config.review_result(n: any, w: any, report: any, correlation: any, clock: any): any?
	local d, p = n.dispatch, report.payload
	local rv = if type(correlation) == "table" and correlation.review_id ~= nil and (d.reviews or {})[correlation.review_id] == correlation then correlation else nil
	if not rv or rv.reviewer_worker_id ~= w.worker_id or not rv.request or rv.request.action_id ~= report.action_id or rv.request.action_revision ~= report.action_revision then
		return config.refusal("action_mismatch", "REVIEW_RESULT must echo the exact review_request this reviewer worker received.")
	end
	if rv.status ~= "requested" and not (rv.status == "cancelled" and rv.hold and rv.hold.code == "review_disabled") then
		return config.refusal("review_closed", "Review " .. rv.review_id .. " is " .. rv.status .. "; it no longer accepts a result.")
	end
	if p.review_id ~= rv.review_id or p.round ~= rv.round or p.artifact_revision ~= rv.artifact_revision then
		return config.refusal("review_mismatch", "REVIEW_RESULT must name review " .. rv.review_id .. ", round " .. tostring(rv.round) .. " and artifact revision " .. rv.artifact_revision .. " exactly.")
	end
	-- Consume a correctly correlated late result without reopening a policy-disabled review.
	if rv.status == "cancelled" then return nil end
	local enforced = policy(d, w.logical_session_id).require_other_family
	local b = config.review_builder(d, rv)
	if b then rv.builder_family = config.family_of(d, b) end
	local family = config.family_of(d, w)
	local code, message
	if w.worker_id == rv.builder_worker_id then code, message = "reviewer_is_builder", "The reviewer worker is the builder itself."
	elseif w.record_id == rv.builder_record_id then code, message = "reviewer_record_is_builder", "The reviewer runs the builder's own record " .. w.record_id .. "."
	elseif enforced and (family == nil or rv.builder_family == nil) then code, message = "family_unknown", "The builder's or reviewer's provider family is not declared, so cross-family review cannot hold."
	elseif enforced and family == rv.builder_family then code, message = "family_same", "The reviewer's declared family " .. family .. " equals the builder's; cross-family review needs a different provider family." end
	if code then
		rv.refusal = { code = code, message = bounded("REVIEW_RESULT from " .. w.worker_id .. " refused: " .. message .. " A fresh reviewer is selected.", 1024) }
		rv.status = "queued"; rv.reviewer_worker_id = nil; rv.reviewer_record_id = nil; rv.reviewer_family = nil; rv.request = nil; rv.revision += 1
		if b then local _, err = append(d, b, "attention", rv.refusal.message, clock); if err then return err end end
		return nil
	end
	rv.result = { outcome = p.outcome, summary = p.summary, reviewer_worker_id = w.worker_id, event_id = report.event_id, seq = report.seq, round = p.round, artifact_revision = p.artifact_revision }
	rv.findings = clone(p.findings); rv.refusal = nil; rv.hold = nil; rv.revision += 1
	local rounds = policy(d, w.logical_session_id).review_rounds
	if p.outcome == "approved" then rv.status = "approved"
	elseif rv.round >= rounds then rv.status = "capped"; rv.loop = { count = rv.round, state = "gated" } -- Its loop_cap gate opens in config.advance_review.
	else rv.status = "changes_required"; rv.rework = nil end
	if b then
		if rv.status ~= "changes_required" then config.settle_review_ready(b) end
		local _, err = append(d, b, "review", bounded("Review " .. rv.review_id .. " round " .. tostring(rv.round) .. ": " .. p.outcome .. " by " .. w.worker_id .. " (" .. tostring(rv.reviewer_family or "family unknown")
			.. ", declared) with " .. tostring(#p.findings) .. " finding(s)" .. (if rv.status == "capped" then "; the " .. tostring(rounds) .. "-round cap is reached." else ".") , 32768), clock)
		if err then return err end
	end
	return nil
end
function config.review_acked(d: any, reply: any)
	for _, rv in d.reviews or {} do
		for _, key in { "request", "rework" } do
			local s = rv[key]
			if s and s.action_id == reply.action_id and s.action_revision == reply.action_revision and s.reply_seq == reply.reply_seq then s.acknowledged = true end
		end
	end
end
function config.select_reviewer(d: any, rv: any): (any?, string?, string?, string?)
	local p, c = policy(d, rv.logical_session_id), d.catalogs[rv.logical_session_id]
	local enforced = p.require_other_family
	if #p.reviewer_records == 0 then
		return nil, nil, "reviewer_unavailable", "No reviewer records are configured; add one under Config → Review & proof."
	end
	if enforced and rv.builder_family == nil then
		return nil, nil, "family_unknown", "The builder record has no current underlying provider declaration. Set its Provider family in SPAWN; ORCH+ does not infer a wrapper's provider."
	end
	local reasons, unknown = {}, false
	for _, record_id in p.reviewer_records do
		local row
		for _, candidate_row in (if c then c.records else {}) do if candidate_row.id == record_id then row = candidate_row end end
		local family = if row then row.provider_family else nil
		local why
		if record_id == rv.builder_record_id then why = "is the builder's own record"
		elseif not row or not row.eligible or row.enabled ~= true then why = "is absent from the current catalog, disabled or ineligible"
		elseif enforced and family == nil then why = "has no declared family"; unknown = true
		elseif enforced and family == rv.builder_family then why = "shares the builder's family " .. family end
		if not why then return row, family, nil, nil end
		table.insert(reasons, record_id .. " " .. why)
	end
	return nil, nil, if unknown then "family_unknown" else "reviewer_unavailable", "No configured reviewer record can review this work"
		.. (if enforced then " under enforced cross-family review (builder family " .. tostring(rv.builder_family) .. ")" else "") .. ": " .. table.concat(reasons, "; ") .. "."
end
function config.review_ungate(d: any, rv: any)
	local g = if rv.gate_id then (d.gates or {})[rv.gate_id] else nil
	if g and gate_open(g) then
		g.phase = "superseded"; g.revision += 1
		local w = d.workers[g.worker_id]; if w then settle_entries(w, "gate_id", g.id) end
	end
	rv.gate_id = nil
end
-- One host-consumed reviewer_unavailable/family_unknown gate per review, on the builder.
function config.review_gate(d: any, rv: any, b: any, kind: string, code: string, reason: string, clock: any)
	rv.hold = { code = code, message = bounded(reason, 1024) }
	local g = if rv.gate_id then (d.gates or {})[rv.gate_id] else nil
	if g and gate_open(g) and g.kind == kind and g.worker_id == b.worker_id and g.worker_generation == b.worker_generation then return end
	config.review_ungate(d, rv)
	if (type(clock) == "table" and clock.reserved_capacity) or b.phase ~= "accepted" then return end
	local opened = new_gate(d, b, kind, bounded("Review " .. rv.review_id .. " (round " .. tostring(rv.round) .. ") of work " .. rv.builder_work_id .. " at " .. rv.artifact_revision
		.. " is waiting: " .. reason .. " Families are owner-declared, not verified. Fix Config, then try selection again, or cancel this review.", 32768),
		{ { id = "retry", label = "Try reviewer selection again" }, { id = "cancel", label = "Cancel this review" } },
		{ "review:" .. rv.review_id, "round:" .. tostring(rv.round) }, clock)
	if opened then rv.gate_id = opened.id end
end
function config.review_cancel(d: any, rv: any, code: string, message: string)
	rv.status = "cancelled"; rv.hold = { code = code, message = bounded(message, 1024) }; rv.revision += 1
	config.review_ungate(d, rv)
	local gate = if rv.loop then loops.gate(d, rv.loop) else nil
	if gate then
		gate.phase = "superseded"; gate.revision += 1
		local builder = d.workers[gate.worker_id]
		if builder then settle_entries(builder, "gate_id", gate.id) end
	end
	rv.loop = nil
end
function config.answer_review_gate(_: any, n: any, w: any, g: any, event: any, clock: any): (any?, any?)
	local d = n.dispatch
	if not gate_open(g) then return fail("stale_gate", "This gate is no longer current.") end
	local rv
	for _, candidate_review in d.reviews or {} do if candidate_review.gate_id == g.id then rv = candidate_review end end
	local cancel = event.command == "cancel_gate" or event.choice_id == "cancel"
	if event.command == "answer" then
		local choice = false; for _, option in g.options do if option.id == event.choice_id then choice = true end end
		if g.phase ~= "pending" or not choice or not str(event.answer, 32768) then return fail("invalid_choice", "Choose an option from this exact question.") end
		g.answer = { choice_id = event.choice_id, answer = event.answer, source = config.owner_source(event.origin), at_ms = stamp(clock).at_ms }
		g.phase = "resolved"
	else g.phase = "cancelled"; g.revision += 1 end
	settle_entries(w, "gate_id", g.id)
	if rv then
		rv.gate_id = nil
		if cancel then config.review_cancel(d, rv, "owner_cancelled", "Owner cancelled this review at gate " .. g.id .. ".")
		else
			-- Retry: a lost reviewer is replaced by a fresh one; selection re-runs on this commit.
			if rv.hold and rv.hold.code == "reviewer_lost" then
				rv.reviewer_worker_id = nil; rv.reviewer_record_id = nil; rv.reviewer_family = nil; rv.request = nil; rv.status = "queued"; rv.revision += 1
			end
			rv.hold = nil
		end
	end
	return result(if cancel then "review_cancelled" else "review_retry", { gate_id = g.id, review_id = if rv then rv.review_id else nil }), nil
end
function config.reviewer_lost(d: any, rv: any): boolean
	if rv.reviewer_worker_id == nil then return false end
	local r = d.workers[rv.reviewer_worker_id]
	return r == nil or r.stopped ~= nil or r.mailbox_retired == true or r.finish ~= nil or (r.workflow ~= nil and r.workflow.exit ~= nil) or launch_rejected(d, r) or r.withdrawn ~= nil
end
-- Declared helper checks that failed (optionally at one head), in declaration order.
function config.failed_checks(w: any, head: string?): any
	local out = {}
	for _, check in w.checks or {} do
		local r = (w.check_results or {})[check.check_id]
		if r and r.exit_code ~= 0 and (head == nil or r.head == head) then table.insert(out, { check_id = check.check_id, exit_code = r.exit_code }) end
	end
	return out
end
-- A fresh reviewer worker for this round through the existing provision → launch path. Reviewers
-- never quota-route (the record is the owner's family-constrained choice) and count against the
-- 32-worker cap: a full cap holds the review with backpressure; it is never dropped.
function config.queue_reviewer(n: any, rv: any, row: any, family: string?, event: any, clock: any): any?
	local d = n.dispatch
	if not rv.worktree_path then
		return { code = "review_location_unverified", message = "Review needs a helper CHECKOUT at the checkpoint's artifact revision and matching worktree_ref. Publish those facts and REVIEW_READY again; the configured launch cwd is not a substitute." }
	end
	if count(d.workers) >= 32 then reclaim_workers(n) end
	if count(d.workers) >= 32 then
		return { code = "full", message = "Managed generation capacity (32 workers, reviewers included) is full; this review waits and launches its reviewer when a slot frees. Nothing was dropped." }
	end
	if count(d.actions) >= 3072 then
		return { code = "full", message = "The durable dispatch ledger is near its bound; this review waits and launches its reviewer once settled actions are discarded. Nothing was dropped." }
	end
	local sid = rv.logical_session_id
	local scope = if #rv.scope_paths > 0 then bounded(table.concat(rv.scope_paths, ", "), 2048) else "the declared scope (none declared)"
	local question = string.format(config.JUDGE_QUESTION, rv.source_ref, rv.artifact_revision, rv.task_ref, scope)
	local prompt = "You are an ORCH+ reviewer worker for review " .. rv.review_id .. ", round " .. tostring(rv.round) .. ", of builder work " .. rv.builder_work_id
		.. ". Review only in the verified repository/worktree " .. rv.worktree_path .. "; your configured launch cwd is not the task repository. Keep this location distinct from source_ref " .. rv.source_ref .. " and artifact_revision " .. rv.artifact_revision
		.. ". After ACCEPTED, wait for the review_request reply and answer only its fixed question, once: " .. question
		.. " Report exactly one REVIEW_RESULT echoing the review_request action_id/action_revision, review_id, round and artifact_revision; findings name a file and line; no scores, no confidence. ORCH+ finishes this worker once the result settles."
	local role_event = table.clone(event)
	local builder = config.work_head(d, sid, rv.builder_work_id)
	if not builder or not config.project_started(d, builder) then return config.hold("project_held", "Start the builder's project before creating its reviewer.") end
	role_event.orch_project_id = builder.orch_project_id
	local w = config.new_worker(d, role_event, sid, row, prompt, rv.review_id .. ":" .. tostring(rv.round) .. ":", "reviewer")
	w.review_id = rv.review_id; w.family = family
	local held = config.provision_role(d, w, "reviewer", clock); if held then return held end
	rv.reviewer_worker_id = w.worker_id; rv.reviewer_record_id = row.id; rv.reviewer_family = family; rv.revision += 1
	return nil
end
function config.request_review(d: any, rv: any, r: any): any?
	local payload = { review_id = rv.review_id, round = rv.round, question_id = "implements_task_v1", builder_work_id = rv.builder_work_id, task_ref = rv.task_ref,
		source_ref = rv.source_ref, artifact_revision = rv.artifact_revision, scope_paths = tern.json.array(clone(rv.scope_paths)),
		findings_prev = tern.json.array(clone(rv.findings)), plan_ref = rv.plan_ref, plan_revision = rv.plan_revision }
	local delivery, err = issue_reply(d, r, "review_request", payload)
	if err then return { code = err.code, message = bounded("The review_request could not be issued to " .. r.worker_id .. ": " .. err.message, 1024) } end
	rv.request = { action_id = delivery.action_id, action_revision = delivery.action_revision, message_id = r.replies[tostring(delivery.reply_seq)].message_id,
		reply_seq = delivery.reply_seq, acknowledged = false, round = rv.round }
	return nil
end
function config.send_rework(d: any, rv: any, b: any, clock: any): any?
	local failed = config.failed_checks(b, rv.artifact_revision)
	local delivery, err = issue_reply(d, b, "rework", { review_id = rv.review_id, round = rv.round, artifact_revision = rv.artifact_revision,
		failed_checks = tern.json.array(failed), findings = tern.json.array(clone(rv.findings)) })
	if err then return { code = err.code, message = bounded("The rework reply could not be issued to " .. b.worker_id .. ": " .. err.message, 1024) } end
	rv.rework = { action_id = delivery.action_id, action_revision = delivery.action_revision, message_id = b.replies[tostring(delivery.reply_seq)].message_id,
		reply_seq = delivery.reply_seq, acknowledged = false, round = rv.round }
	config.settle_review_ready(b)
	append(d, b, "rework", bounded("Rework for review " .. rv.review_id .. " round " .. tostring(rv.round) .. ": " .. tostring(#rv.findings) .. " finding(s)"
		.. (if #failed > 0 then ", " .. tostring(#failed) .. " failed check(s)" else "") .. ". Fix only these and publish a new revision with REVIEW_READY.", 32768), clock, { action_id = delivery.action_id })
	return nil
end
function config.reviews_held(d: any, sid: string, clock: any): any?
	if policy(d, sid).paused then return { code = "session_paused", message = "Session is paused; the review continues after resume." } end
	if type(clock) == "table" and clock.reserved_capacity then return { code = "capacity_reached", message = "Authority capacity is at its settlement reserve; the review continues on a later commit." } end
	return nil
end
function config.advance_review(n: any, rv: any, event: any, clock: any)
	local d = n.dispatch
	if not policy(d, rv.logical_session_id).require_code_review then
		config.review_cancel(d, rv, "review_disabled", "Code review is disabled in this session; no reviewer or review rework is requested.")
		return
	end
	local b = config.review_builder(d, rv)
	if rv.status == "capped" then
		local loop = rv.loop
		if loop and loop.state == "gated" and not loops.gate(d, loop) and b and b.phase == "accepted" then
			local cap = policy(d, rv.logical_session_id).review_rounds
			local question = bounded("Review " .. rv.review_id .. " of work " .. rv.builder_work_id .. " still requires changes after " .. tostring(rv.round) .. " review round(s), the configured review-round cap ("
				.. tostring(cap) .. "). No further reviewer is launched and no rework is sent; landing for this work stays held without an approved review.", 32768)
			local _, err = loops.open(d, b, loop, "review_rounds", rv.review_id, question, cap, clock, false)
			rv.hold = if err then { code = err.code, message = bounded(err.message, 1024) } else { code = "loop_cap", message = bounded(question, 1024) }
		end
		return
	end
	if not b then
		config.review_cancel(d, rv, "builder_ended", "No live generation of builder work " .. rv.builder_work_id .. " remains; the review was cancelled.")
		return
	end
	if rv.status == "changes_required" then
		if rv.rework == nil then
			local held = config.reviews_held(d, rv.logical_session_id, clock)
			if not held and (b.phase ~= "accepted" or b.continuation_required or not b.mailbox_handle or active_rollover(d, b)) then
				held = { code = "builder_unavailable", message = "The builder generation cannot receive the rework reply now; it is sent once it can." }
			end
			rv.hold = held or config.send_rework(d, rv, b, clock)
		end
		return
	end
	if config.reviewer_lost(d, rv) then
		config.review_gate(d, rv, b, "reviewer_unavailable", "reviewer_lost", "Reviewer worker " .. rv.reviewer_worker_id .. " ended before its REVIEW_RESULT; ORCH+ never relaunches a reviewer on its own.", clock)
		return
	end
	if rv.status == "requested" then return end
	if rv.reviewer_worker_id then
		local r = d.workers[rv.reviewer_worker_id]
		if r.phase ~= "accepted" then return end
		local held = config.reviews_held(d, rv.logical_session_id, clock)
		if not held and (r.continuation_required or not r.mailbox_handle) then held = { code = "reviewer_unbound", message = "Explicitly continue the reviewer worker before its review_request is sent." } end
		rv.hold = held or config.request_review(d, rv, r)
		if not rv.hold then rv.status = "requested"; rv.revision += 1 end
		return
	end
	rv.builder_family = config.family_of(d, b)
	local row, family, kind, reason = config.select_reviewer(d, rv)
	if not row then config.review_gate(d, rv, b, kind :: string, kind :: string, reason :: string, clock); return end
	config.review_ungate(d, rv)
	rv.hold = config.reviews_held(d, rv.logical_session_id, clock) or config.queue_reviewer(n, rv, row, family, event, clock)
end
-- Reviewer auto-finish (finding 13): the result lives on its review, so only the existing finish
-- preconditions remain — no retained effect, every receipt published, every reply acknowledged and
-- compacted, nothing pending or referenced. Any unsettled state defers to a later commit or tick.
function config.finishable(d: any, w: any): boolean
	local done = (w.role == "reviewer" and w.review_id ~= nil) or (w.role == "labeller" and not config.label_needed(d, w))
	if not done or w.coordinator_owner_id or w.phase ~= "accepted" or w.finish or w.release or w.continuation_required or w.stopped or w.mailbox_retired
		or not w.workflow or next(w.replies) or next(w.wakes or {}) or w.accept_pending or w.assembly or w.rejected_report or w.workflow.report_request then return false end
	for _, receipt in w.receipts do if receipt.publish then return false end end
	-- A labeller's own intake pin and label gates never hold it alive: its label lives on the intake.
	return not pending(d, w) and (w.role == "labeller" or not work_referenced(d, w))
end
function config.auto_finish(n: any, w: any, clock: any)
	if w.open_conversation or w.enrol_delivery then return end
	if not config.finishable(n.dispatch, w) then return end
	w.finish = { request_id = next_id(n.dispatch, "auto-finish-"), seq = w.accepted_seq, revision = n.revision, source = { kind = "policy", rule = "auto_finish:" .. w.role } }
	config.usage_end(n.dispatch, w, clock)
	flow(w).thread = {}
	append(n.dispatch, w, "finish", "ORCH+ finishes this " .. w.role .. " automatically: its result evidence is recorded and its receipts and replies are settled.", clock)
end
-- Failed declared checks request check-only repair in every review mode, once per revision.
function config.check_rework(n: any, w: any, clock: any)
	local d = n.dispatch
	local p = policy(d, w.logical_session_id)
	if w.role ~= "builder" or w.coordinator_owner_id or not w.checks or #w.checks == 0 then return end
	local cp = latest_checkpoint(w)
	local revision = if cp then cp.payload.artifact_revision else (if w.checkout then w.checkout.head else nil)
	if revision == nil then return end
	local failed = config.failed_checks(w, revision)
	if #failed == 0 then
		for _, check in w.checks do
			local evidence = (w.check_results or {})[check.check_id]
			if not evidence or evidence.head ~= revision or evidence.exit_code ~= 0 then return end
		end
		if w.check_rework then
			local g = loops.gate(d, w.check_rework)
			if g then g.phase = "superseded"; g.revision += 1; settle_entries(w, "gate_id", g.id) end
			w.check_rework.state = nil; w.check_rework.gate_id = nil; w.check_rework.count = 0
		end
		return
	end
	local ids = {}
	for _, f in failed do table.insert(ids, f.check_id) end
	local key = codec.sha256(revision)
	local loop = w.check_rework or { count = 0 }
	if loop.key == key or loop.state == "stopped" or p.paused or (type(clock) == "table" and clock.reserved_capacity)
		or w.phase ~= "accepted" or w.finish or w.release or w.stopped or w.mailbox_retired or w.continuation_required or not w.mailbox_handle then return end
	if loops.trips(loop, p.loop_cap) then
		w.check_rework = loop
		loops.open(d, w, loop, "check_rework", w.work_id, bounded("Work " .. w.work_id .. " already received " .. tostring(loop.count) .. " helper-check rework request(s) (loop cap "
			.. tostring(p.loop_cap) .. ") and declared checks still fail: " .. table.concat(ids, ", ") .. ". Allow more rework rounds or keep it stopped.", 32768), p.loop_cap, clock, true)
		return
	end
	local delivery, err = issue_reply(d, w, "rework", { round = loop.count + 1, artifact_revision = revision,
		failed_checks = tern.json.array(failed), findings = tern.json.array() })
	if err then return end
	loop.count += 1; loop.key = key; w.check_rework = loop
	append(d, w, "rework", bounded("Rework: helper-run checks failed (" .. table.concat(ids, ", ") .. "); fix only these and run the checks again.", 32768), clock, { action_id = delivery.action_id })
end
-- Runs at the end of every dispatch commit for the event's session (after the command's own effect).
function config.advance_reviews(n: any, event: any, clock: any)
	local d, sid = n.dispatch, event.orch_session_id
	for _, key in config.sorted_keys(d.reviews or {}, function(_, rv) return rv.logical_session_id == sid and (config.REVIEW_OPEN[rv.status] or rv.status == "capped") end,
		function(a: string, b: string): boolean return config.review_serial(d.reviews[a]) < config.review_serial(d.reviews[b]) end) do config.advance_review(n, d.reviews[key], event, clock) end
	for _, w in d.workers do if w.logical_session_id == sid then config.check_rework(n, w, clock) end end
	for _, w in d.workers do if w.logical_session_id == sid then config.auto_finish(n, w, clock) end end
end
-- A rollover uses a fresh worker ID with generation 1; its monotonic ID breaks generation ties.
function config.work_head(d: any, sid: string, work_id: string): any?
	local head
	for _, w in d.workers do
		if w.work_id == work_id and w.logical_session_id == sid and (not head or w.worker_generation > head.worker_generation
			or (w.worker_generation == head.worker_generation and config.serial(w.worker_id) > config.serial(head.worker_id))) then head = w end
	end
	return head
end
-- Returns (in_scope, code?, reason?); manual, inbox and template work is never in scope.
function config.in_scope(d: any, sid: string, work_id: string, kind: string, p: any?): (boolean, string?, string?)
	local w = config.work_head(d, sid, work_id)
	if not w then return false, "work_missing", "work " .. work_id .. " is not managed in this session" end
	local source = w.source
	if not source or (source.kind ~= "plan" and source.kind ~= "board") then
		return false, "source_not_planned", "work " .. work_id .. " did not come from an imported plan or the board (source " .. (if source then source.kind else "manual") .. ")"
	end
	if not w.scope or #w.scope.paths == 0 then return false, "scope_undeclared", "work " .. work_id .. " declares no scope.paths" end
	for _, g in d.gates or {} do
		if g.work_id == work_id and g.logical_session_id == sid and (g.kind == "scope" or g.kind == "file_overlap" or g.kind == "shared_checkout") and gate_open(g) then
			return false, "scope_gate_open", g.kind .. " gate " .. g.id .. " is open on work " .. work_id
		end
	end
	if kind == "dispatch" then
		local current = false
		for _, row in ((d.catalogs[sid] or {}).records or {}) do
			if p and row.id == p.record_id and row.revision == p.record_revision and row.eligible and row.enabled == true then current = true end
		end
		if not current then return false, "record_not_current", "the proposed record is not current and eligible in the catalog" end
	end
	return true, nil, nil
end
config.PROPOSAL_EFFECT = {
	dispatch = "Approving queues the proposed record and prompt once as new work inheriting this work's scope and source.",
	report = "Approving sends this work's current worker one report_request.",
	review = "Approving opens one review of that checkpoint by a separate ORCH+ reviewer worker; it grants no landing.",
	landing = "Approving approves this work's landing request for that checkpoint, once; proof rule H and a live release manager are still required before any grant.",
	rollover = "This decision is recorded only and never executed: rollover runs only through the owner's Roll over… buttons or the automatic-rollover session policy.",
}
function config.proposal_question(p: any, scoped: boolean, why: string?): string
	if p.kind == "new_work" or p.kind == "add_source" then
		local target = p.orch_project_id or ("new project “" .. p.new_project_name .. "”")
		return bounded("Add " .. p.kind .. " to " .. target .. " without starting it. "
			.. (if p.kind == "new_work" then "Agent " .. p.record_id .. " revision " .. tostring(p.record_revision) .. ". Task: " .. p.prompt
				.. "\nScope: " .. tern.json.encode(p.scope) .. "\nDeclared commands (review before START): " .. tern.json.encode(p.checks)
				.. "\nRepository/base/target: " .. tern.json.encode({ repository_id = p.repository_id, base_ref = p.base_ref, target_ref = p.target_ref, target_revision = p.target_revision })
				else "Source: " .. tern.json.encode(p.source))
			.. "\nApproval adds held work only, including while paused. It never resumes or releases other work.", 32768)
	end
	local text = "Coordinator proposes " .. p.kind .. " for " .. p.work_id .. " in " .. p.project_id .. ". "
		.. (if p.kind == "dispatch" then "Record " .. p.record_id .. " revision " .. string.format("%.0f", p.record_revision) .. ". " else "") .. config.PROPOSAL_EFFECT[p.kind]
	if p.kind ~= "rollover" then
		text ..= (if scoped then " In plan scope." else " Outside plan scope (" .. tostring(why) .. "); only the owner can approve it.")
			.. " Approval (owner or session policy) never bypasses loop caps, proof, capacity or pause."
	end
	return bounded(text, 32768)
end
-- A proposal naming registered session work and a retained CHECKPOINT of its project opens one
-- coordinator_proposal gate. D8/D9: an in-scope proposal of an auto_approve kind is answered by the
-- session policy (tagged source); out-of-scope ones always wait for the owner. Rollover never executes.
function config.open_proposal(d: any, w: any, p: any, bytes: string, cp: any, clock: any): (nil, any?)
	if p.kind == "new_work" or p.kind == "add_source" then
		if p.orch_project_id and not config.project_ref(d, w.logical_session_id, p.orch_project_id) then return fail("project_changed", "The proposed project is no longer available.") end
		local _, problem = new_gate(d, w, "coordinator_proposal", config.proposal_question(p, false, nil),
			{ { id = "approve", label = "Add held work" }, { id = "reject", label = "Reject" } }, { "scope:passive" }, clock, bytes)
		return nil, problem
	end
	local found = p.kind ~= "dispatch"
	for _, record in (if found then {} else (d.catalogs[w.logical_session_id] or {}).records or {}) do
		if record.id == p.record_id and record.revision == p.record_revision and record.eligible and record.enabled then found = true end
	end
	if not found then return fail("catalog_changed", "Dispatch proposal must name a current eligible configured record/revision.") end
	local scoped, scope_code, scope_reason = config.in_scope(d, w.logical_session_id, p.work_id, p.kind, p)
	local g, err = new_gate(d, w, "coordinator_proposal", config.proposal_question(p, scoped, scope_reason),
		{ { id = "approve", label = if p.kind == "rollover" then "Approve proposal only" else "Approve proposal" }, { id = "reject", label = "Reject" } },
		{ "checkpoint:" .. cp.payload.checkpoint_id, "scope:" .. (if scoped then "in" else scope_code :: string) }, clock, bytes)
	if err then return nil, err end
	if scoped and p.kind ~= "rollover" and table.find(policy(d, w.logical_session_id).auto_approve_kinds, p.kind) then config.policy_answer(d, w, g, p.kind, clock) end
	return nil, nil
end
-- Definite refusals (codes REFUSALS): a proposal sent while the session is paused, or naming no
-- registered session work with a retained CHECKPOINT of its project (e.g. sent before that
-- checkpoint), is never held. Its gate is settled `reject` by ORCH+ (source kind "refusal") and
-- delivered as one owner_decision, so the coordinator's report lane keeps moving and nothing waits
-- for the owner. The coordinator may propose again, even with the same proposal id.
config.REFUSALS = {
	review_disabled = "code review is disabled in this session; enable Require code review in Config before proposing review. Nothing was asked of the owner or executed.",
	session_paused = "the session is paused; nothing was asked of the owner or executed. Propose again after the owner resumes the session.",
	scope_mismatch = "the named work retains no CHECKPOINT of that project (and checkpoint_id) in this session; nothing was asked of the owner or executed. Propose again after that checkpoint is registered.",
}
function config.refuse_proposal(d: any, w: any, p: any, bytes: string, code: string, clock: any): (nil, any?)
	local text = "ORCH+ refused proposal " .. p.proposal_id .. " (" .. code .. ", " .. p.kind .. " for " .. p.work_id .. " in " .. p.project_id
		.. (if p.checkpoint_id then ", checkpoint " .. p.checkpoint_id else "") .. "): " .. config.REFUSALS[code]
	local g, err = new_gate(d, w, "coordinator_proposal", bounded(text, 32768), { { id = "approve", label = "Approve proposal" }, { id = "reject", label = "Reject" } },
		{ "refused:" .. code }, clock, bytes)
	if err then return nil, err end
	local _, problem = append(d, w, "answer", text, clock, { state = "pending", gate_id = g.id }); if problem then return nil, problem end
	g.answer = { choice_id = "reject", answer = text, source = { kind = "refusal", code = code }, at_ms = stamp(clock).at_ms }; g.phase = "answered"
	return nil, nil
end
function config.refused_proposal(g: any): boolean
	return g.answer ~= nil and type(g.answer.source) == "table" and g.answer.source.kind == "refusal"
end
-- Policy answer (Contract E): recorded on the gate and the thread with its tagged source, then
-- delivered like any decision. Nothing is answered when the thread has no room.
function config.policy_answer(d: any, w: any, g: any, kind: string, clock: any): boolean
	local source = config.policy_source(d, w.logical_session_id, kind)
	local text = "Approved by session policy " .. source.rule .. " (policy " .. source.policy_revision:sub(1, 12) .. "), not by the owner."
	local _, err = append(d, w, "answer", text, clock, { state = "pending", gate_id = g.id })
	if err then return false end
	g.answer = { choice_id = "approve", answer = text, source = source, at_ms = stamp(clock).at_ms }; g.phase = "answered"
	return true
end
function config.execute_dispatch(registry: any, n: any, w: any, g: any, p: any, event: any, clock: any, reserve: any): (string, string, string)
	local d, sid = n.dispatch, w.logical_session_id
	local parent = config.work_head(d, sid, p.work_id)
	if not parent then return "refused", "work_missing", "Work " .. p.work_id .. " is no longer managed; nothing was queued." end
	local row
	for _, candidate_row in ((d.catalogs[sid] or {}).records or {}) do if candidate_row.id == p.record_id and candidate_row.revision == p.record_revision then row = candidate_row end end
	if not row or not row.eligible or row.enabled ~= true then
		return "refused", "catalog_changed", "Record " .. p.record_id .. " revision " .. string.format("%.0f", p.record_revision) .. " is no longer current and eligible; nothing was queued."
	end
	if count(d.workers) >= 32 then reclaim_workers(n) end
	if count(d.workers) >= 32 or count(d.actions) >= 3072 then
		return "pending", "full", "Managed generation or ledger capacity is full; the approved dispatch queues once a slot frees. Nothing was dropped."
	end
	-- The queue tail can fail after partial writes (gates, actions); a failure restores this snapshot.
	local saved = clone(d)
	local function undo(state: string, code: string, message: string): (string, string, string)
		n.dispatch = saved
		return state, code, message
	end
	local work_event = table.clone(event); work_event.orch_project_id = parent.orch_project_id; work_event.presentation = "background"
	local nw = config.new_worker(d, work_event, sid, row, config.assignment_prompt(d, sid, "builder", p.prompt), g.id .. ":", "builder")
	config.bind_family(d, nw)
	-- Plan Task 5A: the new work inherits the parent work's scope and source (so it stays in plan scope).
	local invalid = config.assign(nw, { source = clone(parent.source), scope = clone(parent.scope) })
	if invalid then return undo("refused", invalid.code, invalid.message) end
	if M.request_size(launch_request(nw, string.rep("h", 96))) > codec.DISPATCH.limit then
		return undo("refused", "oversize", "The proposed prompt plus its immutable launch binding exceeds the 8192-byte bridge; nothing was queued.")
	end
	local gate_ids, gate_err = config.queue_gates(d, nw, clock)
	if gate_err then return undo("pending", gate_err.code, gate_err.message) end
	if gate_ids then
		nw.launch_gates = gate_ids; d.workers[nw.worker_id] = nw
		local _, problem = append(d, nw, "assignment", nw.prompt, clock)
		if problem then return undo("pending", problem.code, problem.message) end
	else
		local _, err = config.launch(registry, n, nw, { request_id = g.id .. "-dispatch", origin = event.origin, controller_pane = event.controller_pane }, clock, reserve, true)
		if err then return undo(if err.code == "full" then "pending" else "refused", err.code, err.message) end
	end
	return "done", "worker:" .. nw.worker_id, "Approved dispatch queued work " .. nw.work_id .. " (" .. nw.worker_id .. ") on " .. row.id .. ", inheriting " .. p.work_id .. "'s scope and source."
end
-- One report_request to the work's current generation, counted against its report loop (Contract L).
function config.execute_report(n: any, p: any, sid: string, clock: any): (string, string, string)
	local d = n.dispatch
	local t = config.work_head(d, sid, p.work_id)
	if not t or t.finish or t.release or t.stopped or t.mailbox_retired or (t.workflow and t.workflow.exit) then
		return "refused", "worker_unavailable", "Work " .. p.work_id .. " has no running generation to ask; no report_request was sent."
	end
	if t.phase ~= "accepted" or t.continuation_required or not t.mailbox_handle then
		return "pending", "worker_unavailable", "Work " .. p.work_id .. "'s current generation is not accepted and continued yet; the report_request is sent once it is."
	end
	local f = flow(t)
	if f.report_request then
		return "done", "report_request:" .. f.report_request.request_id, "Work " .. p.work_id .. " already has report_request " .. f.report_request.request_id .. " outstanding; no second request was sent."
	end
	local cap, loop = policy(d, sid).loop_cap, f.report_loop
	if loop and loop.state == "stopped" then
		return "refused", "loop_stopped", "The owner stopped report requests for " .. t.worker_id .. " at the loop cap; no report_request was sent."
	end
	if loops.trips(loop, cap) then
		loops.open(d, t, loop, "report_request", t.worker_id, "Report requested " .. tostring(loop.count) .. " times without a new report from " .. t.worker_id
			.. ". An approved coordinator report proposal is waiting; allow more requests or keep them stopped (any new report from the worker resumes them).", cap, clock, true)
		return "pending", "loop_cap", "Report requests for " .. t.worker_id .. " reached the loop cap; answer its loop_cap gate."
	end
	if not sendable(d, t, clock) then
		return "pending", "worker_not_sendable", "Worker " .. t.worker_id .. " is not safely idle; the report_request is sent once it is. No agent is interrupted."
	end
	local request_id = next_id(d, "report-request-")
	local delivery, err = issue_reply(d, t, "report_request", { request_id = request_id, requested_kind = "HEARTBEAT", reason = "An approved coordinator proposal requested a structured progress report; echo request_id in HEARTBEAT or CHECKPOINT." })
	if err then return "pending", err.code, err.message end
	delivery.request_id = request_id; delivery.published = false; delivery.response_received = false; f.report_request = delivery
	append(d, t, "report_request", "Approved proposal requested structured progress; delivery ACK is not a progress response.", clock, { state = "pending", request_id = request_id, action_id = delivery.action_id })
	f.report_loop = loop or { count = 0 }; f.report_loop.count += 1
	return "done", "report_request:" .. request_id, "Report request " .. request_id .. " sent to " .. t.worker_id .. "."
end
-- Approves the matching ungranted landing item of (work, checkpoint) by answering its own landing
-- approval gate with the proposal's answer source; advance_landing records the approval.
function config.execute_landing(n: any, g: any, p: any, sid: string, clock: any): (string, string, string)
	local d = n.dispatch
	local open_item, moving, closed_item
	for _, item in ((d.landing or {}).items or {}) do
		if item.work_id == p.work_id and item.logical_session_id == sid and item.request.checkpoint_id == p.checkpoint_id then
			if LANDING_UNGRANTED[item.status] then open_item = item
			elseif item.status == "granted" or item.status == "landing" or item.status == "landed" then moving = item
			else closed_item = item end
		end
	end
	if open_item then
		local lg = if open_item.gate_id then (d.gates or {})[open_item.gate_id] else nil
		if open_item.approval or (lg and lg.answer and lg.answer.choice_id == "approve" and lg.phase ~= "cancelled" and lg.phase ~= "superseded") then
			return "done", "landing:" .. open_item.id, "Landing " .. open_item.id .. " is already approved."
		end
		if not lg or lg.phase ~= "pending" then return "refused", "landing_closed", "Landing " .. open_item.id .. "'s approval gate is no longer open; nothing was approved." end
		local b = d.workers[lg.worker_id]
		local source = clone(g.answer.source)
		if source.kind == "owner" and (source.logical_session_id ~= b.logical_session_id or source.owner_id ~= b.origin_binding.owner_id
			or source.owner_generation ~= b.origin_binding.owner_generation) then
			return "refused", "binding_mismatch", "Landing " .. open_item.id .. " belongs to another controller owner binding; answer its approval gate directly."
		end
		local text = "Approved through coordinator proposal gate " .. g.id .. " (" .. (if source.kind == "policy" then "session policy " .. source.rule else "owner") .. ")."
		local _, err = append(d, b, "answer", text, clock, { state = "pending", gate_id = lg.id })
		if err then return "pending", err.code, err.message end
		lg.answer = { choice_id = "approve", answer = text, source = source, at_ms = stamp(clock).at_ms }; lg.phase = "answered"
		return "done", "landing:" .. open_item.id, "Landing " .. open_item.id .. " approved; it is granted only once proof rule H and a live release manager hold."
	end
	if moving then return "done", "landing:" .. moving.id, "Landing " .. moving.id .. " is already " .. moving.status .. "." end
	if closed_item then return "refused", "landing_closed", "Landing " .. closed_item.id .. " for this checkpoint is " .. closed_item.status .. "; nothing was approved." end
	return "pending", "landing_not_requested", "Work " .. p.work_id .. " has not requested landing for checkpoint " .. tostring(p.checkpoint_id) .. "; the approval applies once it does."
end
function config.proposal_effect(registry: any, n: any, w: any, g: any, p: any, event: any, clock: any, reserve: any): (string, string, string)
	local d, sid = n.dispatch, w.logical_session_id
	if p.kind == "new_work" or p.kind == "add_source" then return config.passive_proposal(registry, n, w, g, p, event, clock, reserve) end
	if p.kind == "review" and not policy(d, sid).require_code_review then
		return "refused", "review_disabled", "Code review is disabled in this session; enable Require code review in Config before proposing review."
	end
	if policy(d, sid).paused then return "pending", "session_paused", "Session is paused; the approved " .. p.kind .. " runs after resume." end
	if type(clock) == "table" and clock.reserved_capacity then
		return "pending", "capacity_reached", "Authority capacity is at its settlement reserve; the approved " .. p.kind .. " runs on a later commit."
	end
	if p.kind == "dispatch" then return config.execute_dispatch(registry, n, w, g, p, event, clock, reserve) end
	if p.kind == "report" then return config.execute_report(n, p, sid, clock) end
	if p.kind == "landing" then return config.execute_landing(n, g, p, sid, clock) end
	-- An approved coordinator `review` proposal opens a review of the proposed checkpoint.
	local target
	for _, b in d.workers do
		if b.work_id == p.work_id and b.logical_session_id == sid and b.role == "builder" and b.phase == "accepted"
			and b.workflow and b.workflow.checkpoints[p.checkpoint_id] then target = b end
	end
	local cp = if target then codec.decode_report(target.workflow.checkpoints[p.checkpoint_id], target) else nil
	if not cp then return "refused", "review_not_opened", "Work " .. p.work_id .. " has no accepted builder generation retaining checkpoint " .. tostring(p.checkpoint_id) .. "; no review was opened." end
	local rv, note, problem = config.open_review(n, target, cp, "proposal", clock)
	if note then append(d, target, "attention", note, clock) end
	if problem then return "pending", problem.code, problem.message end
	if rv then return "done", "review:" .. rv.review_id, "Review " .. rv.review_id .. " round " .. tostring(rv.round) .. " queued for " .. p.work_id .. "." end
	return "refused", "review_not_opened", note or "No review was opened."
end
-- Contract E: executes one approved proposal and writes its execution record in this same commit.
-- A settled record (done/refused) is never revisited, so a tick, restore or replay never executes
-- twice; a pending one is retried by the next commit. Returns the outcome message.
function config.execute_proposal(registry: any, n: any, gate_id: string, event: any, clock: any, reserve: any): string?
	local g = n.dispatch.gates[gate_id]
	if g.kind ~= "coordinator_proposal" or not g.answer or g.answer.choice_id ~= "approve" or (g.execution and g.execution.state ~= "pending") then return nil end
	local w = n.dispatch.workers[g.worker_id]
	local proposal = if w then codec.decode_report(g.proposal, w) else nil
	if not proposal or proposal.payload.kind == "rollover" then return nil end
	local state, ref, message
	if g.phase == "cancelled" or g.phase == "superseded" then
		state, ref, message = "refused", "gate_cancelled", "The approved proposal's gate was cancelled before its effect ran; nothing was executed."
	else
		state, ref, message = config.proposal_effect(registry, n, w, g, proposal.payload, event, clock, reserve)
	end
	local d = n.dispatch -- A failed dispatch tail restored its snapshot.
	g = d.gates[gate_id]; w = d.workers[g.worker_id]
	local prior = g.execution
	if prior and prior.state == state and prior.effect_ref == ref then return message end
	g.execution = { state = state, gate_revision = g.revision, effect_ref = bounded(ref, 1024), at_ms = stamp(clock).at_ms }
	append(d, w, "execution", bounded("Proposal " .. proposal.payload.proposal_id .. " (" .. proposal.payload.kind .. ", gate " .. g.id .. ") " .. state .. ": " .. message, 32768), clock)
	return message
end
-- Runs at the end of every dispatch commit for the event's session. Pause answers nothing by policy:
-- a proposal gate still pending is evaluated once, on the resume commit (in scope when opened and now,
-- kind auto-approved now); otherwise it stays with the owner. Then approved proposals without a
-- settled execution record run, oldest first.
function config.advance_proposals(registry: any, n: any, event: any, clock: any, reserve: any)
	local d, sid = n.dispatch, event.orch_session_id
	local function oldest(a: string, b: string): boolean return (tonumber(a:match("%d+$")) or 0) < (tonumber(b:match("%d+$")) or 0) end
	local sp = policy(d, sid)
	if not sp.require_code_review then
		for _, g in d.gates or {} do
			if g.logical_session_id == sid and g.kind == "coordinator_proposal" and g.phase == "pending" then
				local worker = d.workers[g.worker_id]
				local proposal = if worker then codec.decode_report(g.proposal, worker) else nil
				if proposal and proposal.payload.kind == "review" then
					local message = "ORCH+ refused review proposal: " .. config.REFUSALS.review_disabled
					local _, problem = append(d, worker, "answer", message, clock, { state = "pending", gate_id = g.id })
					if not problem then
						g.answer = { choice_id = "reject", answer = message, source = { kind = "refusal", code = "review_disabled" }, at_ms = stamp(clock).at_ms }
						g.phase = "answered"
					end
				end
			end
		end
	end
	if event.command == "resume" and not sp.paused then
		for _, key in config.sorted_keys(d.gates or {}, function(_, g) return g.logical_session_id == sid and g.kind == "coordinator_proposal" and g.phase == "pending"
			and table.find(g.evidence, "scope:in") ~= nil end, oldest) do
			local g = d.gates[key]; local w = d.workers[g.worker_id]
			local p = codec.decode_report(g.proposal, w).payload
			if p.kind ~= "rollover" and (p.kind ~= "review" or sp.require_code_review) and table.find(sp.auto_approve_kinds, p.kind)
				and config.in_scope(d, sid, p.work_id, p.kind, p) then config.policy_answer(d, w, g, p.kind, clock) end
		end
	end
	for _, key in config.sorted_keys(d.gates or {}, function(_, g) return g.logical_session_id == sid and g.kind == "coordinator_proposal" and g.answer
		and g.answer.choice_id == "approve" and (g.execution == nil or g.execution.state == "pending") end, oldest) do
		config.execute_proposal(registry, n, key, event, clock, reserve)
	end
end
-- Rule H review evidence: the latest unvoided review of this work with a reviewer-worker result
-- (approved, changes_required or capped), so a landing hold names why the review does not prove it.
function config.review_for(d: any, w: any): any?
	local best
	for _, rv in d.reviews or {} do
		if rv.builder_work_id == w.work_id and rv.logical_session_id == w.logical_session_id and rv.void == nil and rv.result
			and (rv.status == "approved" or rv.status == "changes_required" or rv.status == "capped")
			and (not best or config.review_serial(rv) > config.review_serial(best)) then best = rv end
	end
	if not best then return nil end
	local reviewer = d.workers[best.reviewer_worker_id]
	return { review_id = best.review_id, reviewer_worker_id = best.result.reviewer_worker_id,
		reviewer_family = if reviewer then config.family_of(d, reviewer) else nil, reviewer_role = "reviewer",
		reviewer_record_id = best.reviewer_record_id, artifact_revision = best.artifact_revision, outcome = best.result.outcome }
end
function config.review_view(rv: any): any
	return { review_id = rv.review_id, revision = rv.revision, status = rv.status, round = rv.round, artifact_revision = rv.artifact_revision, checkpoint_id = rv.checkpoint_id,
		builder_work_id = rv.builder_work_id, builder_worker_id = rv.builder_worker_id, builder_family = rv.builder_family, reviewer_worker_id = rv.reviewer_worker_id,
		reviewer_record_id = rv.reviewer_record_id, reviewer_family = rv.reviewer_family, findings_count = #rv.findings, findings = clone(rv.findings),
		result = clone(rv.result), refusal = clone(rv.refusal), hold = clone(rv.hold), gate_id = rv.gate_id, voided = rv.void ~= nil,
		request_issued = rv.request ~= nil, rework_issued = rv.rework ~= nil, trigger = rv.trigger }
end
function config.valid_reviews(d: any, registry: any): boolean
	if d.reviews == nil then return true end
	if type(d.reviews) ~= "table" or d.reviews == tern.json.null or count(d.reviews) > 64 then return false end
	local open = {}
	for key, rv in d.reviews do
		if not closed(rv, config.REVIEW_KEYS) or not id(key) or rv.review_id ~= key or not registry.sessions[rv.logical_session_id] or not pos(rv.revision)
			or not id(rv.builder_worker_id) or not id(rv.builder_work_id) or not config.record(rv.builder_record_id)
			or (rv.builder_family ~= nil and not config.family(rv.builder_family)) or (rv.reviewer_family ~= nil and not config.family(rv.reviewer_family))
			or (rv.reviewer_worker_id ~= nil and not id(rv.reviewer_worker_id)) or (rv.reviewer_record_id ~= nil and not config.record(rv.reviewer_record_id))
			or (rv.reviewer_worker_id ~= nil) ~= (rv.reviewer_record_id ~= nil) or not pos(rv.round) or rv.round > 10
			or not wire_text(rv.artifact_revision, 1024) or not id(rv.checkpoint_id) or not wire_text(rv.task_ref, 1024) or not wire_text(rv.source_ref, 1024)
			or (rv.worktree_path ~= nil and (not str(rv.worktree_path, 4096) or not (rv.worktree_path:sub(1, 1) == "/" or rv.worktree_path:match("^%a:[\\/]") or rv.worktree_path:sub(1, 2) == "\\\\")))
			or (rv.plan_ref == nil) ~= (rv.plan_revision == nil) or (rv.plan_ref ~= nil and (not wire_text(rv.plan_ref, 1024) or not wire_text(rv.plan_revision, 1024)))
			or not config.texts(rv.scope_paths, 64, 256) or not table.find(config.REVIEW_STATUSES, rv.status)
			or not config.list(rv.findings, 32) or (rv.trigger ~= "review_ready" and rv.trigger ~= "proposal") or not (rv.at_ms == 0 or pos(rv.at_ms))
			or (rv.gate_id ~= nil and not id(rv.gate_id)) or (rv.loop ~= nil and not loops.valid(rv.loop)) then return false end
		for _, f in rv.findings do
			if not closed(f, "finding_id path line summary") or not id(f.finding_id) or not wire_text(f.path, 1024) or not wire_text(f.summary, 400)
				or (f.line ~= nil and not pos(f.line)) then return false end
		end
		for _, name in { "refusal", "hold" } do
			local v = rv[name]
			if v ~= nil and (not closed(v, "code message") or not str(v.code, 96) or not wire_text(v.message, 1024)) then return false end
		end
		for _, name in { "request", "rework" } do
			local v = rv[name]
			if v ~= nil and (not closed(v, "action_id action_revision message_id reply_seq acknowledged round") or not id(v.action_id) or not pos(v.action_revision)
				or not id(v.message_id) or not pos(v.reply_seq) or type(v.acknowledged) ~= "boolean" or not pos(v.round) or v.round ~= rv.round) then return false end
		end
		local r = rv.result
		if r ~= nil and (not closed(r, "outcome summary reviewer_worker_id event_id seq round artifact_revision") or (r.outcome ~= "approved" and r.outcome ~= "changes_required")
			or (r.summary ~= nil and not wire_text(r.summary, 1024)) or not id(r.reviewer_worker_id) or not id(r.event_id) or not pos(r.seq) or not pos(r.round)) then return false end
		if rv.void ~= nil and (not (closed(rv.void, "artifact_revision at_ms") and wire_text(rv.void.artifact_revision, 1024)
			or closed(rv.void, "target_revision at_ms") and wire_text(rv.void.target_revision, 1024)) or not (rv.void.at_ms == 0 or pos(rv.void.at_ms)) or rv.status ~= "approved") then return false end
		if rv.status == "requested" and (rv.request == nil or rv.reviewer_worker_id == nil) then return false end
		if (rv.status == "approved" or rv.status == "changes_required" or rv.status == "capped") and r == nil then return false end
		if rv.status == "capped" and rv.loop == nil then return false end
		if config.REVIEW_OPEN[rv.status] then
			local slot = rv.logical_session_id .. "\n" .. rv.builder_work_id
			if open[slot] then return false end -- One open review per builder work.
			open[slot] = true
		end
	end
	return true
end
-- Work sources (Checkpoint 6: D10, D12, D16; Contracts G, K, L).
-- The host reads plan and inbox files itself (the 8192-byte bridge carries no file bytes) and
-- keeps three durable collections, each registered with M.valid and bounded:
-- `plans` (storage-admitted; unfinished work is never evicted),
-- `intakes` (≤256, keyed by intake_id; oldest settled reclaimed) and `chains` (template
-- chains, ≤64; oldest settled reclaimed). Every source work is an ordinary managed builder
-- with the Contract G normalized source; scheduling runs at the end of every dispatch commit.
config.plan_parser = require("./plan_import")
config.source_adapter = require("./source_adapter")
config.SOURCE = { PLAN_BYTES = 1048576, INBOX_BYTES = 32768, CARD_BYTES = 4096, INPUT_BYTES = protocol.SOURCE_INPUT_BYTES, TASK_TEXT = 2048,
	INTAKES = 256, CHAINS = 64, CHAIN_BOUND = 8, CHAIN_STEPS = 16, PROJECTED_INTAKES = 64 }
config.TASK_STATES = { "queued_plan", "held", "running", "done", "failed", "cancelled" }
config.PLAN_STATUSES = { "active", "done", "superseded" }
config.INTAKE_STATES = { "received", "accepted", "refused" }
config.LANES = { "queued", "running", "review", "done" }
config.CHAIN_STATUSES = { "running", "gated", "capped", "done", "stopped" }
config.STEP_STATES = { "held", "running", "done", "failed" }
-- Deterministic assignment problems never clear by retrying; the source settles as failed/refused.
config.PERMANENT_HOLDS = { invalid_assignment = true, manifest_too_large = true, oversize = true, template_unknown = true }
-- Host file access (tern.fs on the execution host); a bound rejects non-regular files and oversize.
function config.read_file(path: string, maximum: number): string return tern.fs.read(path, maximum) end
function config.hold(code: string, message: string): any return { code = code, message = bounded(message, 1024) } end
-- Desired board lane of a work from its committed state; nil once it ended without landing or
-- finishing (stopped, retired or withdrawn before launch).
function config.work_lane(d: any, sid: string, work_id: string): string?
	local open = false
	for _, item in (d.landing or {}).items or {} do
		if item.work_id == work_id and item.logical_session_id == sid then
			if item.status == "landed" then return "done" end
			if not LANDING_TERMINAL[item.status] then open = true end
		end
	end
	local w = config.work_head(d, sid, work_id)
	if not w then return nil end
	if w.finish then return "done" end
	if w.stopped or w.mailbox_retired then return nil end
	if w.phase ~= "accepted" then return "queued" end
	local rv = config.review_of(d, w)
	if open or (policy(d, sid).require_code_review and rv and (config.REVIEW_OPEN[rv.status] or (rv.status == "approved" and rv.void == nil))) then return "review" end
	return "running"
end
-- Source work always uses the preferred worker. Task class is metadata only.
function config.preferred_row(d: any, sid: string): (any?, any?)
	local record_id = policy(d, sid).preferred_worker_record
	if record_id == "" then return nil, config.hold("preferred_worker_missing", "Choose a Preferred Worker in Settings; the work remains held.") end
	return config.catalog_row(d, sid, record_id, "Preferred worker", "choose an available Preferred Worker in Settings; the work remains held.")
end
-- The worker prompt contains assignment text and its machine-readable header. The text
-- is shortened (UTF-8 safe) until the immutable launch request fits the 8192-byte bridge.
function config.source_prompt(w: any, text: string, header: string): string
	local function compose(body: string): string
		return body .. "\n\n" .. header
	end
	local body = text
	for _ = 1, 4 do
		w.prompt = compose(body); w.assignment_sha256 = codec.sha256(w.prompt)
		local over = M.request_size(launch_request(w, string.rep("h", 96))) - codec.DISPATCH.limit
		if over <= 0 then return w.prompt end
		body = bounded(body, math.max(0, #body - over - 64)) .. "\n[… shortened to fit the launch bridge; read the source for the rest.]"
	end
	return w.prompt
end
function config.source_header(fields: any): string
	local checks = {}
	for _, c in fields.checks or {} do table.insert(checks, c.check_id) end
	return "ORCH+ assignment header: source=" .. fields.source.kind .. ":" .. tostring(fields.source.ref)
		.. (if fields.source.revision then "@" .. fields.source.revision else "")
		.. "; files=" .. tern.json.encode(tern.json.array(clone(fields.files or {})))
		.. "; scope.systems=" .. tern.json.encode(tern.json.array(clone(if fields.scope then fields.scope.systems else {})))
		.. "; checks=" .. tern.json.encode(tern.json.array(checks))
end
-- Creates one source work and launches it, or holds it behind its launch gates (the intake gate
-- first when `intake_question` is given). Returns (worker, nil) or (nil, hold). Partial writes of a
-- failed launch are undone (shallow map snapshot: launch only inserts entries into these maps).
-- The third result is the queued provision action of an ungated, unrouted launch.
function config.source_launch(registry: any, n: any, sid: string, row: any, text: string, fields: any, event: any, clock: any, reserve: any): (any?, any?, string?)
	local d = n.dispatch
	if count(d.workers) >= 32 then reclaim_workers(n) end
	d.gates = d.gates or {}
	if count(d.gates) >= 61 then reclaim_gates(d) end
	if count(d.workers) >= 32 or count(d.actions) >= 3072 or count(d.gates) >= 61 then
		return nil, config.hold("full", "Managed worker, ledger or gate capacity is full; this work starts once a slot frees. Nothing was dropped.")
	end
	local p = policy(d, sid)
	local launch_event = table.clone(event); launch_event.orch_project_id = fields.orch_project_id
	local w = config.new_worker(d, launch_event, sid, row, "", event.request_id .. ":", "builder")
	config.bind_family(d, w)
	local invalid = config.assign(w, fields)
	if invalid then return nil, config.hold(invalid.code, invalid.message) end
	config.source_prompt(w, text, config.source_header(fields) .. "\n" .. config.review_guidance(p))
	if M.request_size(launch_request(w, string.rep("h", 96))) > codec.DISPATCH.limit then
		return nil, config.hold("oversize", "The assignment plus its immutable launch binding cannot fit the 8192-byte bridge; nothing was provisioned.")
	end
	local saved = { workers = table.clone(d.workers), gates = table.clone(d.gates), actions = table.clone(d.actions) }
	local function undo(problem: any): (nil, any)
		d.workers = saved.workers; d.gates = saved.gates; d.actions = saved.actions
		return nil, config.hold(problem.code, problem.message)
	end
	local gate_ids, gate_err = config.queue_gates(d, w, clock)
	if gate_err then return undo(gate_err) end
	if gate_ids then
		w.launch_gates = gate_ids; d.workers[w.worker_id] = w
		local _, problem = append(d, w, "assignment", w.prompt, clock); if problem then return undo(problem) end
	else
		local launched, err = config.launch(registry, n, w, { request_id = w.work_id .. "-source", origin = w.origin_binding, controller_pane = w.controller_pane }, clock, reserve, true)
		if err then return undo(err) end
		return w, nil, launched.action_id
	end
	return w, nil, nil
end
function config.starts_blocked(d: any, sid: string, clock: any): boolean
	return policy(d, sid).paused or (type(clock) == "table" and clock.reserved_capacity == true)
end

function config.plan_running(d: any, sid: string): number
	local running = 0
	for _, plan in d.plans or {} do
		if plan.logical_session_id == sid and plan.status == "active" then
			for _, cp in plan.checkpoints do for _, t in cp.tasks do if t.state == "running" then running += 1 end end end
		end
	end
	return running
end
function config.start_task(registry: any, n: any, plan: any, cp: any, t: any, event: any, clock: any, reserve: any)
	local d, sid = n.dispatch, plan.logical_session_id
	local row, hold = config.preferred_row(d, sid)
	if not row then t.state = "held"; t.hold = hold; return end
	local fields = { orch_project_id = plan.orch_project_id, class = t.class, template_id = t.template_id, files = if #t.files > 0 then clone(t.files) else nil,
		scope = { paths = clone(t.files), systems = clone(t.systems) }, checks = if #t.checks > 0 then clone(t.checks) else nil,
		source = { kind = "plan", ref = plan.path .. "#" .. t.id, revision = plan.plan_revision } }
	local text = "Plan \"" .. plan.title .. "\" (" .. plan.path .. "), checkpoint " .. string.format("%.0f", cp.n) .. " — " .. cp.title .. ".\n"
		.. "Your task is " .. t.id .. " — " .. t.title .. (if #t.flags > 0 then " (plan flags: " .. table.concat(t.flags, ", ") .. "; unparsed checks are never run)" else "") .. ".\n\n" .. t.text
	local w, problem = config.source_launch(registry, n, sid, row, text, fields, event, clock, reserve)
	if not w then
		t.state = if config.PERMANENT_HOLDS[problem.code] then "failed" else "held"; t.hold = problem
		return
	end
	t.state = "running"; t.work_id = w.work_id; t.worker_id = w.worker_id; t.hold = nil
end
function config.advance_plan(registry: any, n: any, plan: any, event: any, clock: any, reserve: any)
	local d, sid = n.dispatch, plan.logical_session_id
	for _, cp in plan.checkpoints do
		for _, t in cp.tasks do
			if t.state == "running" and t.work_id then
				local lane = config.work_lane(d, sid, t.work_id)
				if lane == "done" then t.state = "done"
				elseif lane == nil then t.state = if config.work_head(d, sid, t.work_id) then "failed" else "cancelled" end
			end
		end
	end
	local all_done = true
	for _, cp in plan.checkpoints do for _, t in cp.tasks do
		if t.state == "running" or (cp.source_state ~= "done" and t.state ~= "done") then all_done = false end
	end end
	if all_done and plan.status == "active" then plan.status = "done" end
	if plan.status ~= "active" or plan.held or not config.project_started(d, plan) or config.starts_blocked(d, sid, clock) then return end
	local p = policy(d, sid)
	local tasks_by_id = {}
	for _, cp in plan.checkpoints do for _, t in cp.tasks do tasks_by_id[t.id] = t end end
	local limit = if p.concurrency_limit > 0 then p.concurrency_limit else 32
	for _, cp in plan.checkpoints do
		if cp.source_state == "done" then
			for _, t in cp.tasks do if t.state == "running" then return end end
			continue
		end
		if cp.source_state == "blocked" or cp.source_state == "paused" then return end
		local earlier_open, earlier_sequential_open = false, false
		for _, t in cp.tasks do
			local waiting = t.state == "queued_plan" or (t.state == "held" and not config.PERMANENT_HOLDS[t.hold.code])
			local blocked = if t.independent then earlier_sequential_open else earlier_open
			if t.source_state == "blocked" or t.source_state == "paused" then blocked = true end
			for _, dependency in t.depends_on or {} do
				if not tasks_by_id[dependency] or tasks_by_id[dependency].state ~= "done" then blocked = true end
			end
			if waiting and not blocked and config.plan_running(n.dispatch, sid) < limit then
				config.start_task(registry, n, plan, cp, t, event, clock, reserve)
			end
			if t.state ~= "done" then
				earlier_open = true
				if not t.independent then earlier_sequential_open = true end
			end
		end
		if earlier_open then return end -- Join: the next checkpoint waits for this one.
	end
end
config.PERMANENT_HOLDS.plan_identity_ambiguous = true
-- A source node can acquire a new generated id without acquiring a new execution. Never rewrite
-- the retained worker's source/check/report identities to manufacture an association.
function config.reconcile_plan(d: any, sid: string, path: string, parsed: any): (any?, string?, any?)
	local by_id, by_semantic, old_counts, managed, identities = {}, {}, {}, {}, {}
	local existing_project
	for _, plan in d.plans do
		if plan.logical_session_id == sid and plan.path == path and plan.status ~= "superseded" and config.project_ref(d, sid, plan.orch_project_id) then
			if existing_project and existing_project ~= plan.orch_project_id then
				return nil, nil, config.hold("plan_identity_ambiguous", "Existing imports bind this source to different projects; reconcile those imports before adding work.")
			end
			existing_project = plan.orch_project_id
			for _, cp in plan.checkpoints do for _, t in cp.tasks do
				local identity = config.plan_parser.task_identity(cp, t)
				old_counts[identity] = (old_counts[identity] or 0) + 1
				if (t.state == "running" or t.state == "done") and t.work_id then
					table.insert(managed, t); identities[t] = identity
					by_id[t.id] = if by_id[t.id] == nil then t else false
					by_semantic[identity] = if by_semantic[identity] == nil then t else false
				end
			end end
		end
	end
	local new_counts, new_identities = {}, {}
	for _, cp in parsed.checkpoints do for _, t in cp.tasks do
		local identity = config.plan_parser.task_identity(cp, t)
		new_identities[t] = identity; new_counts[identity] = (new_counts[identity] or 0) + 1
	end end
	local carried, matched, additions = {}, {}, 0
	for _, cp in parsed.checkpoints do for _, t in cp.tasks do
		local identity = new_identities[t]
		local prior = by_id[t.id]
		if prior == false then return nil, nil, config.hold("plan_identity_ambiguous", "A managed source ID is not unique; no work was rebound or rerun.") end
		if prior then
			if t.identity_ambiguous or prior.identity_ambiguous or identities[prior] ~= identity then
				return nil, nil, config.hold("plan_identity_changed", "An existing managed task's instructions or identity became ambiguous. Preserve its source identity or use a new plan source for intentional replacement; no work was rebound or rerun.")
			end
		else
			prior = by_semantic[identity]
			if prior ~= nil and (prior == false or t.identity_ambiguous or prior.identity_ambiguous or old_counts[identity] ~= 1 or new_counts[identity] ~= 1) then
				return nil, nil, config.hold("plan_identity_ambiguous", "Repeated task content cannot uniquely identify existing managed work. Give the source tasks distinct stable identities; no receipt was rebound or task rerun.")
			end
		end
		if prior then
			if matched[prior] then return nil, nil, config.hold("plan_identity_ambiguous", "Two source nodes would reuse one managed execution; no work was rebound or rerun.") end
			matched[prior] = true; carried[t.id] = prior
		else additions += 1 end
	end end
	if additions > 0 then for _, prior in managed do if not matched[prior] then
		return nil, nil, config.hold("plan_identity_changed", "Managed tasks disappeared while new unmatched tasks appeared. Restore their stable identities or use a separate source for intentional new work; existing executions and proofs were preserved.")
	end end end
	return carried, existing_project, nil
end
function config.plan_import_command(registry: any, n: any, event: any, clock: any, reserve: any): (any?, any?)
	local d, sid, path = n.dispatch, event.orch_session_id, event.path
	if not config.absolute(path, 512) or path:find("%c") then return fail("invalid_path", "Plan import needs one absolute file path of at most 512 bytes on the execution host.") end
	local ok, bytes = pcall(config.read_file, path, config.SOURCE.PLAN_BYTES)
	if not ok or type(bytes) ~= "string" then
		local reason = tostring(bytes)
		if tern.fs.exists(path) and (reason:find("[Ll]arge") or reason:find("[Ee]xceed") or reason:find("max_bytes") or reason:find("[Ss]ize")) then
			return fail("too_large", "Plan file " .. path .. " exceeds 1 MiB; nothing was imported.")
		end
		return fail("plan_unreadable", bounded("Plan file " .. path .. " cannot be read on the execution host (missing, not a regular file or larger than 1 MiB): " .. reason, 1024))
	end
	local parsed, problem = config.plan_parser.parse(bytes)
	if not parsed then return fail(problem.code, bounded("Plan import refused: " .. problem.message, 1024)) end
	if event.source_revision ~= nil and event.source_revision ~= parsed.plan_revision then return fail("source_changed", "The selected plan revision changed; inspect it before adding.") end
	d.plans = d.plans or {}
	for _, plan in d.plans do
		if plan.logical_session_id == sid and plan.path == path and plan.plan_revision == parsed.plan_revision and plan.status ~= "superseded"
			and config.project_ref(d, sid, plan.orch_project_id) then
			return result("plan_already_imported", { plan_id = plan.plan_id, orch_project_id = plan.orch_project_id, plan_revision = plan.plan_revision,
				message = "This exact plan revision is already imported; nothing changed." }), nil
		end
	end
	-- Reconcile before superseding anything; numeric checkpoint/task ordinals are not execution proof.
	local carried, existing_project, identity_problem = config.reconcile_plan(d, sid, path, parsed)
	if identity_problem then return fail(identity_problem.code, identity_problem.message) end
	local plan_id = next_id(d, "plan-")
	local source_event = table.clone(event)
	if source_event.orch_project_id == nil and config.project_ref(d, sid, existing_project) then source_event.orch_project_id = existing_project end
	if existing_project and source_event.orch_project_id ~= existing_project and next(carried) ~= nil then return fail("project_bound", "This plan revision retains running or completed work in its existing project; it cannot move that authority implicitly.") end
	local project, project_problem = config.source_project(d, source_event, parsed.title, { kind = "plan", ref = path, revision = parsed.plan_revision })
	if not project then return nil, project_problem end
	for _, plan in d.plans do
		if plan.logical_session_id == sid and plan.path == path and plan.status ~= "superseded" and config.project_ref(d, sid, plan.orch_project_id) then plan.status = "superseded" end
	end
	local entry = { plan_id = plan_id, logical_session_id = sid, orch_project_id = project.orch_project_id,
		held = if config.source_autostart(n, project, event) and config.standalone_start(n, project) then nil else true,
		start_policy = if config.source_autostart(n, project, event) then quota.digest(policy(d, sid)) else nil,
		path = path, plan_revision = parsed.plan_revision, title = bounded(parsed.title, 256),
		flags = clone(parsed.flags), status = "active", at_ms = stamp(clock).at_ms, checkpoints = {} }
	local tasks = 0
	for _, cp in parsed.checkpoints do
		local out = { id = cp.id or ("cp" .. tostring(cp.n)), source_state = cp.state, n = cp.n, title = bounded(cp.title, 256), flags = clone(cp.flags), tasks = {} }
		for _, t in cp.tasks do
			tasks += 1
			local task = { id = t.id, title = bounded(t.title, 256), independent = t.independent, sequential_why = if t.sequential_why then bounded(t.sequential_why, 256) else nil,
				source_identity = t.source_identity or config.plan_parser.task_identity(cp, t), identity_ambiguous = t.identity_ambiguous,
				class = t.class, template_id = t.template_id, files = clone(t.files), checks = clone(t.checks), systems = clone(t.systems), flags = clone(t.flags),
				text = bounded(t.text, config.SOURCE.TASK_TEXT), source_state = t.state, steps = clone(t.steps or {}), filechanges = clone(t.filechanges or {}),
				validationchecks = clone(t.validationchecks or {}), depends_on = clone(t.depends_on or {}), state = if t.state == "done" then "done" else "queued_plan" }
			local prior = carried[t.id]
			if prior then
				task.state = prior.state; task.work_id = prior.work_id; task.worker_id = prior.worker_id
				task.checks = clone(prior.checks); task.files = clone(prior.files); task.systems = clone(prior.systems)
			elseif t.identity_ambiguous then
				task.state = "held"; task.hold = config.hold("plan_identity_ambiguous", "Identical source tasks need distinct stable identities before execution; no duplicate work was queued.")
			end
			-- The manifest bound (Contract G) is checked once here: a task that can never be provisioned
			-- keeps no oversized fields and settles as failed with the reason.
			local _, manifest_problem = codec.encode_manifest({ checks = task.checks, files = task.files, scope = { paths = task.files, systems = task.systems } })
			if manifest_problem then
				task.state = "failed"; task.hold = config.hold(manifest_problem.code, manifest_problem.message); task.checks = {}; task.files = {}
			end
			if event.force_held and #task.checks > 0 then project.checks_pending = true end
			table.insert(out.tasks, task)
		end
		table.insert(entry.checkpoints, out)
	end
	d.plans[plan_id] = entry
	if not entry.held then config.auto_start_source(n, project, event, "plans", plan_id) end
	M.trim_summaries(n)
	if #tern.json.encode(n) > config.AUTHORITY_BYTES - config.RETIREMENT_RESERVE then
		return fail("plans_full", "This plan would consume the authority's retirement reserve. Existing work was preserved; finish work or delete finished history before adding more.")
	end
	if not entry.held then config.advance_plan(registry, n, entry, event, clock, reserve) end
	local started = {}
	for _, cp in entry.checkpoints do for _, t in cp.tasks do if t.work_id and not carried[t.id] then table.insert(started, t.work_id) end end end
	return result("plan_imported", { plan_id = plan_id, orch_project_id = project.orch_project_id, plan_revision = entry.plan_revision, title = entry.title, checkpoints = #entry.checkpoints, tasks = tasks,
		started = tern.json.array(started) }), nil
end

-- Intakes (D12, Contract K). intake_id = quota.digest({kind, path, sha256}) exactly as the window
-- derives it; a duplicate returns the existing record, which serializes racing windows.
function config.intake_id(kind: string, path: string, sha256: string): string return quota.digest({ kind = kind, path = path, sha256 = sha256 }) end
function config.intake_answer(rec: any, code: string, duplicate: boolean?): any
	local out = result(code, { intake_id = rec.intake_id, orch_project_id = rec.orch_project_id, state = rec.state, work_id = rec.work_id, worker_id = rec.worker_id,
		refusal = rec.refusal, hold = clone(rec.hold), duplicate = duplicate == true })
	-- A durably recorded refusal is a committed outcome (the ledger keeps only ok answers): code
	-- "intake_refused" with the reason in `refusal`; uncommitted refusals are ordinary failures.
	if rec.state == "refused" and not duplicate then out.code = "intake_refused" end
	return out
end
function config.intake_room(d: any): boolean
	d.intakes = d.intakes or {}
	return config.make_room(d.intakes, config.SOURCE.INTAKES, function(rec) return rec.state == "refused" or (rec.state == "accepted" and (rec.lane == "done" or rec.lane == nil)) end,
		function(rec) return rec.seq end)
end
-- Records a new intake and advances it on this commit. An unlaunched inbox intake keeps at most
-- 4 KiB of text for a later launch; the archived file has the rest.
function config.new_intake(registry: any, n: any, event: any, clock: any, reserve: any, fields: any): (any?, any?)
	local d = n.dispatch
	if not config.intake_room(d) then return nil, { ok = false, code = "intakes_full", message = "Durable intake capacity (" .. tostring(config.SOURCE.INTAKES) .. ") is full of unsettled intakes; nothing was taken." } end
	local rec = clone(fields)
	local project, problem = config.source_project(d, event, if rec.kind == "board" then "Board work" else "Inbox work",
		{ kind = rec.kind, ref = rec.ref, revision = rec.revision })
	if not project then return nil, problem end
	rec.orch_project_id = project.orch_project_id
	rec.held = if config.source_autostart(n, project, event) and config.standalone_start(n, project) then nil else true
	rec.start_policy = if config.source_autostart(n, project, event) then quota.digest(policy(d, event.orch_session_id)) else nil
	rec.logical_session_id = event.orch_session_id; rec.seq = config.serial(next_id(d, "intake-")); rec.at_ms = stamp(clock).at_ms
	d.intakes[rec.intake_id] = rec
	if rec.text then rec.text = bounded(rec.text, config.SOURCE.CARD_BYTES) end
	if not rec.held then config.auto_start_source(n, project, event, "intakes", rec.intake_id) end
	if not rec.held then config.advance_intake(registry, n, rec, event, clock, reserve) end
	return config.intake_answer(rec, "intake_" .. rec.state), nil
end
-- Optional task-type metadata never selects an agent.
function config.intake_class(d: any, sid: string, tags: any, text: string): string?
	for _, tag in tags or {} do
		local name = tag:match("^#?class%-(.+)$")
		if name and config.slug(name, 32) then return name end
	end
	for line in (text .. "\n"):gmatch("([^\n]*)\n") do
		local v = line:match("^%s*[%-%*]?%s*%*%*CLASS%*%*:%s*`?([a-z][a-z0-9%-]*)`?%s*$")
		if v and config.slug(v, 32) then return v end
	end
	return nil
end
function config.start_intake(registry: any, n: any, rec: any, event: any, clock: any, reserve: any)
	local d, sid = n.dispatch, rec.logical_session_id
	-- A pre-cutover classifier is a retained communication obligation, not a new routing dependency.
	-- Settle its already-issued result/decision or explicitly finish it; never replace/replay it.
	if rec.label then
		local gate = if rec.label.gate_id then (d.gates or {})[rec.label.gate_id] else nil
		local previous = if rec.label.worker_id then d.workers[rec.label.worker_id] else nil
		if gate and gate_open(gate) then rec.hold = config.hold("legacy_classification_decision", "Choose the Preferred Worker or cancel this retained classification decision."); return end
		if previous and not rec.label.result and not previous.finish and not previous.stopped and not previous.mailbox_retired then
			rec.hold = config.hold("legacy_classification_pending", "Settle the existing classifier's issued result or explicitly finish it. No replacement classifier is launched.")
			return
		end
		if rec.label.result then rec.class = rec.label.result.class end
	end
	local row, hold = config.preferred_row(d, sid)
	if not row then rec.hold = hold; return end
	local text
	if rec.kind == "board" then
		text = "Board card from " .. rec.path .. (if rec.tags and #rec.tags > 0 then " (tags: " .. table.concat(rec.tags, ", ") .. ")" else "") .. ":\n\n" .. rec.text
	else
		local archived = (rec.path:match("^(.*)/[^/]*$") or "") .. "/.orchplus-taken/" .. rec.intake_id .. "-" .. rec.ref
		text = "Inbox task file " .. rec.ref .. " (sha256 " .. rec.revision .. "); once taken it is archived at " .. archived .. ".\n\n" .. (rec.text or "")
	end
	local fields = { orch_project_id = rec.orch_project_id, class = rec.class, source = { kind = rec.kind, ref = rec.ref, revision = rec.revision } }
	local w, problem = config.source_launch(registry, n, sid, row, text, fields, event, clock, reserve)
	if not w then
		if config.PERMANENT_HOLDS[problem.code] then rec.state = "refused"; rec.refusal = problem.code; rec.text = nil; rec.tags = nil end
		rec.hold = problem
		return
	end
	rec.work_id = w.work_id; rec.worker_id = w.worker_id; rec.hold = nil
	rec.state = if w.launch_gates then "received" else "accepted"
	rec.text = nil; rec.tags = nil -- The work carries the text now; the record keeps only identity and state.
end
function config.advance_intake(registry: any, n: any, rec: any, event: any, clock: any, reserve: any)
	local d, sid = n.dispatch, rec.logical_session_id
	if rec.state == "refused" then return end
	if rec.work_id then
		local w = config.work_head(d, sid, rec.work_id)
		if not w then
			if rec.state == "received" then
				rec.state = "refused"; rec.refusal = "owner_cancelled"; rec.lane = nil
				rec.hold = config.hold("owner_cancelled", "The owner cancelled this intake's work before launch; the source stays untaken.")
				return
			end
		elseif rec.state == "received" and w.launch_gates == nil then rec.state = "accepted" end
		local lane = config.work_lane(d, sid, rec.work_id)
		if rec.lane ~= "done" then rec.lane = lane end
		return
	end
	rec.lane = "queued"
	if not rec.held and config.project_started(d, rec) and not config.starts_blocked(d, sid, clock) then config.start_intake(registry, n, rec, event, clock, reserve) end
end
-- The intake whose current labeller is `w`, if any.
function config.label_of(d: any, w: any): any?
	if w.role ~= "labeller" then return nil end
	for _, rec in d.intakes or {} do
		if rec.label and rec.label.worker_id == w.worker_id and rec.logical_session_id == w.logical_session_id then return rec end
	end
	return nil
end
-- Still waiting on this labeller: its intake is unrouted and has no label from it yet.
function config.label_needed(d: any, w: any): boolean
	local rec = config.label_of(d, w)
	return rec ~= nil and rec.state == "received" and rec.work_id == nil and rec.label.result == nil and not rec.label.retry
end
-- An unrouted intake pins its current labeller generation (it carries the intake's label gates).
function config.label_pinned(d: any, w: any): boolean
	local rec = config.label_of(d, w)
	return rec ~= nil and rec.state == "received" and rec.work_id == nil
end
function config.label_refuse(rec: any, code: string, message: string)
	rec.state = "refused"; rec.refusal = code; rec.lane = nil; rec.text = nil; rec.tags = nil
	rec.hold = config.hold(code, message)
end
-- The current catalog's enabled, eligible row for `record_id`, else a record_unavailable hold.
function config.catalog_row(d: any, sid: string, record_id: string, what: string, remedy: string): (any?, any?)
	for _, row in ((d.catalogs[sid] or {}).records or {}) do
		if row.id == record_id and row.eligible and row.enabled == true then return row, nil end
	end
	return nil, config.hold("record_unavailable", what .. " record " .. record_id .. " is not in the current catalog, or is disabled or ineligible. Refresh the catalog or " .. remedy)
end
-- The labeller's LABEL for exactly its label_request; the commit tail routes or gates it.
function config.label_result(n: any, w: any, report: any, correlation: any): any?
	local d, p = n.dispatch, report.payload
	local rec = if type(correlation) == "table" and correlation.intake_id ~= nil and (d.intakes or {})[correlation.intake_id] == correlation then correlation else nil
	local L = if rec then rec.label else nil
	if not L or L.worker_id ~= w.worker_id or not L.request or L.request.action_id ~= report.action_id or L.request.action_revision ~= report.action_revision then
		return config.refusal("action_mismatch", "LABEL must echo the exact label_request this labeller worker received.")
	end
	if L.result or L.retry or rec.state ~= "received" or rec.work_id then
		return config.refusal("label_closed", "Intake " .. rec.intake_id:sub(1, 12) .. " no longer accepts a label from " .. w.worker_id .. ".")
	end
	if p.work_ref ~= rec.intake_id then
		return config.refusal("label_mismatch", "LABEL must name work_ref " .. rec.intake_id .. " exactly.")
	end
	L.result = { class = p.class, reason = p.reason, worker_id = w.worker_id, event_id = report.event_id }
	return nil
end
-- Host-consumed label_unknown answer: route_now re-checks Config routes on this commit, relabel
-- starts a fresh labeller (a counted retry), cancel refuses the intake.
function config.answer_label_gate(_: any, n: any, w: any, g: any, event: any, clock: any): (any?, any?)
	local d = n.dispatch
	if not gate_open(g) then return fail("stale_gate", "This gate is no longer current.") end
	local rec
	for _, candidate in d.intakes or {} do if candidate.label and candidate.label.gate_id == g.id then rec = candidate end end
	local cancel = event.command == "cancel_gate" or event.choice_id == "cancel"
	if event.choice_id == "relabel" then return fail("classifier_removed", "Classifier-only routing was removed. Inspect the refreshed decision; use the Preferred Worker or cancel the retained intake.") end
	if event.command == "answer" then
		local choice = false; for _, option in g.options do if option.id == event.choice_id then choice = true end end
		if g.phase ~= "pending" or not choice or not str(event.answer, 32768) then return fail("invalid_choice", "Choose an option from this exact question.") end
		g.answer = { choice_id = event.choice_id, answer = event.answer, source = config.owner_source(event.origin), at_ms = stamp(clock).at_ms }
		g.phase = "resolved"
	else g.phase = "cancelled"; g.revision += 1 end
	settle_entries(w, "gate_id", g.id)
	if rec then
		rec.label.gate_id = nil
		if cancel then config.label_refuse(rec, "owner_cancelled", "The owner cancelled this intake at its retained classification gate; the source stays untaken.") end
	end
	return result(if cancel then "label_cancelled" else "label_route", { gate_id = g.id, intake_id = if rec then rec.intake_id else nil }), nil
end
-- Host-consumed owner answers handled outside M.apply, by gate kind.
config.GATE_ANSWERS = { label_unknown = config.answer_label_gate, reviewer_unavailable = config.answer_review_gate, family_unknown = config.answer_review_gate,
	shared_checkout = config.answer_checkout_gate, file_overlap = config.answer_checkout_gate, scope = config.answer_checkout_gate,
	legacy_grant_outstanding = config.answer_checkout_gate, intake = config.answer_checkout_gate }
function config.valid_label(v: any): boolean
	if v == nil then return true end
	if not closed(v, "worker_id attempts loop request result gate_id retry") or (v.worker_id ~= nil and not id(v.worker_id)) or not (v.attempts == 0 or pos(v.attempts))
		or (v.attempts == 0) ~= (v.worker_id == nil) or not loops.valid(v.loop) or (v.gate_id ~= nil and not id(v.gate_id)) or (v.retry ~= nil and v.retry ~= true) then return false end
	local q, r = v.request, v.result
	if q ~= nil and (not closed(q, "action_id action_revision reply_seq") or not id(q.action_id) or not pos(q.action_revision) or not pos(q.reply_seq)) then return false end
	return r == nil or (closed(r, "class reason worker_id event_id") and config.slug(r.class, 32) and (r.reason == nil or wire_text(r.reason, 1024))
		and id(r.worker_id) and (r.event_id == nil or id(r.event_id)))
end

-- The reading for the worker's exact record, from current, unexpired USAGE evidence (quota.normalize
-- `usage`), never claim.capacity (which holds no readings). Account-wide and percent-only.
function config.usage_now(d: any, w: any, clock: any): any?
	local e = current_evidence(d, w.logical_session_id)
	if not e or e.expires_at_ms <= stamp(clock).at_ms then return nil end
	for _, r in e.records do
		if r.id == w.record_id and r.revision == w.record_revision and r.state == "known" and r.usage ~= nil then return clone(r.usage) end
	end
	return nil
end
-- At launch/adopt outcome: the reading before this worker ran.
function config.usage_start(d: any, w: any, clock: any)
	if w.usage_before == nil then w.usage_before = config.usage_now(d, w, clock) end
end
-- At DONE and at finish: the reading after; a later finish keeps a newer observation only.
function config.usage_end(d: any, w: any, clock: any)
	if w.usage_before == nil then return end
	local now = config.usage_now(d, w, clock)
	if now and (w.usage_after == nil or now.observed_at_ms > w.usage_after.observed_at_ms) then w.usage_after = now end
end
-- Other workers with readings on the same account identity whose measured run overlaps this
-- worker's: half-open [before, after) by observation time, open-ended while running; an ended
-- worker without an after reading spans nothing.
function config.usage_shared_with(d: any, w: any): number?
	local b = w.usage_before
	if not b then return nil end
	local function account(r: any): string
		local ids = table.move(r.account.canonical_ids, 1, #r.account.canonical_ids, 1, {}); table.sort(ids)
		return string.format("%.0f", r.account.generation) .. "\n" .. table.concat(ids, "\n")
	end
	local function span(o: any): (number, number)
		local from = o.usage_before.observed_at_ms
		if o.usage_after then return from, o.usage_after.observed_at_ms end
		return from, if config.rm_ended(d, o) then from else math.huge
	end
	local mine, n = account(b), 0
	local from, to = span(w)
	for key, o in d.workers do
		if key ~= w.worker_id and o.usage_before and account(o.usage_before) == mine then
			local o_from, o_to = span(o)
			if o_from < to and from < o_to then n += 1 end
		end
	end
	return n
end
function config.board_intake_command(registry: any, n: any, event: any, clock: any, reserve: any): (any?, any?)
	local d, sid = n.dispatch, event.orch_session_id
	local p = policy(d, sid)
	if not config.absolute(event.board_path, protocol.DESKTOP_BOARD_PATH_BYTES) then return fail("board_mismatch", "Choose the board's actual absolute desktop path.") end
	if config.source_adapter.is_plan_mirror(event.tags) then return fail("plan_mirror", "Mirrored plan tasks execute from their plan only; board presentation never dispatches them again.") end
	if not str(event.card_id, protocol.NATIVE_BOARD_ID_BYTES) or event.card_id:find("%c") or type(event.text) ~= "string" or not config.texts(event.tags, 64, 256) or not digest(event.text_sha256) then
		return fail("intake_invalid", "A board intake carries the card id, its text, its tags (≤64 strings) and the text sha256.")
	end
	local text_sha256 = quota.digest({ text = event.text, tags = event.tags })
	if text_sha256 ~= event.text_sha256 then return fail("intake_invalid", "The card text and tags do not match the sent text_sha256; the card is re-read on the next poll.") end
	local intake_id = config.intake_id("board", event.board_path, text_sha256)
	d.intakes = d.intakes or {}
	local known = d.intakes[intake_id]
	if known then
		-- An id-invalidating board reload re-sends the same intake with the card's new id.
		if known.card_id ~= event.card_id then known.card_id = event.card_id end
		return config.intake_answer(known, "intake_duplicate", true), nil
	end
	-- Native IDs include the full path/model generation and may change on reload. Keep them
	-- intact in card_id; the bounded semantic intake reference is independent of that UI identity.
	local fields = { intake_id = intake_id, kind = "board", ref = event.board_path .. "#" .. intake_id, path = event.board_path, revision = text_sha256,
		card_id = event.card_id, state = "received" }
	if #event.text > config.SOURCE.CARD_BYTES then
		config.label_refuse(fields, "card_too_large", "Board card text is longer than 4096 bytes; it is not taken. Shorten the card or split it.")
	elseif not str(event.text, config.SOURCE.CARD_BYTES) or event.text:find("%S") == nil then
		config.label_refuse(fields, "intake_invalid", "Board card text is empty or not UTF-8; it is not taken.")
	else
		fields.text = event.text; fields.tags = clone(event.tags); fields.class = config.intake_class(d, sid, event.tags, event.text)
	end
	return config.new_intake(registry, n, event, clock, reserve, fields)
end
-- Host-side resolution only: never resolve an execution-host inbox against desktop or SPAWN cwd.
function M.inbox_location(registry: any, sid: string, project_id: string?): (any?, any?)
	local d = registry.dispatch or fresh()
	local folder = policy(d, sid).inbox_folder
	if folder == "" then return fail("inbox_unset", "No optional inbox location is configured.") end
	if config.absolute(folder, 512) then return { path = folder, orch_project_id = project_id }, nil end
	local project = if project_id then config.project_ref(d, sid, project_id) else nil
	if project_id and not project then return fail("project_changed", "Choose the current unfinished inbox project.") end
	if not project_id then
		for _, candidate in d.projects or {} do
			if candidate.logical_session_id == sid and not candidate.finished and candidate.repository then
				if project ~= nil then return fail("inbox_base_required", "Choose the project whose working folder contains this relative inbox, or save an absolute host inbox path.") end
				project = candidate
			end
		end
	end
	if not project or not project.repository then
		return fail("inbox_base_required", "This project has no verified working folder for a relative inbox. Configure its folder or use an absolute execution-host inbox location.")
	end
	local path = rules.normalize_path(project.repository.cwd .. "/" .. folder)
	if not config.absolute(path, 1024) or not rules.path_within(project.repository.cwd, path) then return fail("invalid_path", "The inbox must remain within its verified project working folder.") end
	return { path = path, orch_project_id = project.orch_project_id }, nil
end
function config.inbox_intake_command(registry: any, n: any, event: any, clock: any, reserve: any): (any?, any?)
	local d, sid = n.dispatch, event.orch_session_id
	local location, location_problem = M.inbox_location(n, sid, event.orch_project_id)
	if not location then return nil, location_problem end
	if location.orch_project_id and not event.orch_project_id then event = table.clone(event); event.orch_project_id = location.orch_project_id end
	local name = event.name
	if not str(name, 255) or name:sub(1, 1) == "." or name:find("[%c/\\]") or not (name:lower():sub(-3) == ".md" or name:lower():sub(-4) == ".txt") or not digest(event.content_sha256) then
		return fail("intake_invalid", "An inbox intake names one *.md or *.txt file directly in the inbox folder and its content sha256.")
	end
	local path = location.path .. "/" .. name
	local claimed_id = config.intake_id("inbox", path, event.content_sha256)
	d.intakes = d.intakes or {}
	local known = d.intakes[claimed_id]
	if known then return config.intake_answer(known, "intake_duplicate", true), nil end
	local ok, bytes = pcall(config.read_file, path, config.SOURCE.INBOX_BYTES)
	if not ok or type(bytes) ~= "string" then
		if not tern.fs.exists(path) then return fail("inbox_missing", "Inbox file " .. name .. " is no longer in the inbox; nothing was taken.") end
		-- Larger than 32 KiB (or not a regular file): refused durably for this content; the file stays untaken.
		return config.new_intake(registry, n, event, clock, reserve, { intake_id = claimed_id, kind = "inbox", ref = name, path = path, revision = event.content_sha256,
			state = "refused", refusal = "too_large", hold = config.hold("too_large", "Inbox file " .. name .. " is larger than 32 KiB or not a regular file; it stays in the inbox untaken.") })
	end
	local sha256 = codec.sha256(bytes)
	if sha256 ~= event.content_sha256 then
		return nil, { ok = false, code = "content_changed", state = "refused", intake_id = claimed_id,
			message = "Inbox file " .. name .. " changed since the window hashed it; it is retried on the next poll. Nothing was taken." }
	end
	local fields = { intake_id = claimed_id, kind = "inbox", ref = name, path = path, revision = sha256, state = "received" }
	if utf8.len(bytes) == nil or bytes:find("%z") or bytes:find("%S") == nil then
		config.label_refuse(fields, "intake_invalid", "Inbox file " .. name .. " is empty or not UTF-8 text; it stays in the inbox untaken.")
	else
		fields.text = bytes; fields.class = config.intake_class(d, sid, nil, bytes)
	end
	return config.new_intake(registry, n, event, clock, reserve, fields)
end

function config.template_of(d: any, sid: string, template_id: string): any?
	for _, t in policy(d, sid).templates do if t.id == template_id then return t end end
	return nil
end
function config.start_step(registry: any, n: any, sid: string, step: any, event: any, clock: any, reserve: any): (any?, any?, string?)
	local d = n.dispatch
	local t = config.template_of(d, sid, step.template_id)
	if not t then return nil, config.hold("template_unknown", "Template " .. step.template_id .. " is no longer saved in Config; the chain cannot continue.") end
	local row, hold = config.preferred_row(d, sid)
	if not row then return nil, hold end
	local input = step.input
	local values = clone(t.custom_fields)
	if step.custom_fields then
		for name, value in step.custom_fields do if values[name] ~= nil then values[name] = value end end
	end
	local function expand(value: string): string return (value:gsub("{([^{}]+)}", function(name) return if name == "input" then input else values[name] end)) end
	local output = expand(t.output)
	if not config.relative(output, 256) then return nil, config.hold("invalid_input", "Expanded template output must stay a bounded relative path without parent traversal.") end
	local text = expand(t.prompt)
	if #text > 32768 then return nil, config.hold("invalid_input", "Expanded template prompt exceeds the assignment bound.") end
	step.output_path = output
	text ..= "\n\nTemplate " .. t.id .. " (" .. t.title .. "): write your output to " .. output .. " and report DONE with output_ref \"" .. output .. "\"."
	local fields = { orch_project_id = event.orch_project_id, class = t.class, template_id = t.id, source = { kind = "template", ref = t.id, revision = quota.digest(t) } }
	local w, problem, action_id = config.source_launch(registry, n, sid, row, text, fields, event, clock, reserve)
	if not w then return nil, problem end
	step.state = "running"; step.work_id = w.work_id; step.worker_id = w.worker_id; step.hold = nil
	return w, nil, action_id
end
function config.chain_room(d: any): boolean
	d.chains = d.chains or {}
	return config.make_room(d.chains, config.SOURCE.CHAINS, function(c) return c.status == "done" or c.status == "stopped" end, function(c) return config.serial(c.chain_id) end)
end
function config.chain_push(c: any, template_id: string, input: string, custom_fields: any?): any
	local step = { template_id = template_id, input = input, custom_fields = clone(custom_fields), state = "held" }
	table.insert(c.steps, step)
	while #c.steps > config.SOURCE.CHAIN_STEPS do table.remove(c.steps, 1) end
	return step
end
-- The newest still-managed step worker carries the chain's loop_cap gate.
function config.chain_worker(d: any, c: any): any?
	for i = #c.steps, 1, -1 do
		local s = c.steps[i]
		local w = if s.work_id then config.work_head(d, c.logical_session_id, s.work_id) else nil
		if w then return w end
	end
	return nil
end
function config.chain_gate(d: any, c: any, bound: boolean, clock: any)
	local w = config.chain_worker(d, c)
	if not w then c.status = "stopped"; c.hold = config.hold("chain_unbound", "No managed step worker remains to carry the chain's loop_cap gate; the chain stopped."); return end
	local cap = policy(d, c.logical_session_id).loop_cap
	local question = if bound then "Template chain " .. c.chain_id .. " completed " .. tostring(c.successes) .. " steps and reached the chain bound 8 (structural); its next step "
			.. c.next_template .. " does not start. Keep it stopped, then start a new chain from the last output if more steps are needed."
		else "Template chain " .. c.chain_id .. " step " .. c.steps[#c.steps].template_id .. " failed " .. tostring(c.loop.count + 1) .. " time(s) (retries " .. tostring(c.loop.count)
			.. ", loop cap " .. tostring(cap) .. "): it ended without DONE or without the output_ref its next step needs. Allow more retries or keep the chain stopped."
	loops.open(d, w, c.loop, "template_chain", c.chain_id, bounded(question, 32768), if bound then config.SOURCE.CHAIN_BOUND else cap, clock, not bound)
end
function config.advance_chain(registry: any, n: any, c: any, event: any, clock: any, reserve: any)
	local d, sid = n.dispatch, c.logical_session_id
	local cap = policy(d, sid).loop_cap
	if c.status == "capped" or c.status == "gated" then
		if c.loop.state == "stopped" then c.status = "stopped"; return end
		if c.status == "gated" and c.loop.state == nil then
			-- allow_more reset the loop: retry the failed step.
			c.status = "running"
			local last = c.steps[#c.steps]
			config.chain_push(c, last.template_id, last.input, last.custom_fields)
		elseif not loops.gate(d, c.loop) then
			config.chain_gate(d, c, c.status == "capped", clock) -- A gate the reserve deferred opens now.
			return
		else return end
	end
	if c.status ~= "running" then return end
	local step = c.steps[#c.steps]
	if step.state == "running" then
		local w = config.work_head(d, sid, step.work_id)
		local evidence = if w and w.workflow then w.workflow.evidence.DONE else nil
		local report = if evidence then codec.decode_report(evidence, w) else nil
		if report then
			local t = config.template_of(d, sid, step.template_id)
			step.output_ref = report.payload.output_ref
			if step.output_path and step.output_ref ~= step.output_path then
				step.state = "failed"
			elseif not t or t.next == "" then
				step.state = "done"; c.successes += 1; c.status = "done"; return
			elseif not step.output_ref then
				step.state = "failed"
			else
				step.state = "done"; c.successes += 1
				if c.successes >= config.SOURCE.CHAIN_BOUND then
					c.status = "capped"; c.next_template = t.next
					config.chain_gate(d, c, true, clock)
					return
				end
				step = config.chain_push(c, t.next, step.output_ref, step.custom_fields)
			end
		elseif not w or w.finish or w.stopped or w.mailbox_retired then
			step.state = "failed"
		else return end
	end
	if step.state == "failed" then
		if loops.trips(c.loop, cap) then c.status = "gated"; config.chain_gate(d, c, false, clock); return end
		c.loop.count += 1
		step = config.chain_push(c, step.template_id, step.input, step.custom_fields)
	end
	if step.state == "held" and not c.held and config.project_started(d, c) and not config.starts_blocked(d, sid, clock) then
		local launch_event = table.clone(event); launch_event.orch_project_id = c.orch_project_id
		local _, hold = config.start_step(registry, n, sid, step, launch_event, clock, reserve)
		if hold then
			step.hold = hold
			if config.PERMANENT_HOLDS[hold.code] then step.state = "failed"; c.status = "stopped"; c.hold = hold end
		end
	end
end
function config.template_start_command(registry: any, n: any, event: any, clock: any, reserve: any): (any?, any?)
	local d, sid = n.dispatch, event.orch_session_id
	if not config.slug(event.template_id, 32) or not config.template_of(d, sid, event.template_id) then return fail("template_unknown", "No saved template has this id; nothing was started.") end
	local template = config.template_of(d, sid, event.template_id)
	if event.source_revision ~= nil and event.source_revision ~= quota.digest(template) then return fail("source_changed", "The selected template changed; inspect it before adding.") end
	if not str(event.input, config.SOURCE.INPUT_BYTES) or event.input:find("%S") == nil then return fail("invalid_input", "Template input is 1..2048 bytes of UTF-8 text.") end
	if event.custom_fields ~= nil and not config.custom_fields(event.custom_fields) then return fail("invalid_input", "Template custom fields must be bounded named text values.") end
	for name in event.custom_fields or {} do if template.custom_fields[name] == nil then return fail("invalid_input", "Unknown template field: " .. name) end end
	if not config.chain_room(d) then return fail("chains_full", "Template chain capacity (" .. tostring(config.SOURCE.CHAINS) .. ") is full of unfinished chains; nothing was started.") end
	local project, problem = config.source_project(d, event, template.title, { kind = "template", ref = template.id, revision = quota.digest(template) })
	if not project then return nil, problem end
	local c = { chain_id = next_id(d, "chain-"), logical_session_id = sid, orch_project_id = project.orch_project_id,
		held = if config.source_autostart(n, project, event) and config.standalone_start(n, project) then nil else true,
		start_policy = if config.source_autostart(n, project, event) then quota.digest(policy(d, sid)) else nil,
		status = "running", successes = 0, steps = {}, loop = { count = 0 }, at_ms = stamp(clock).at_ms }
	config.chain_push(c, event.template_id, event.input, event.custom_fields)
	d.chains[c.chain_id] = c
	if not c.held then config.auto_start_source(n, project, event, "chains", c.chain_id) end
	if not c.held then config.advance_chain(registry, n, c, event, clock, reserve) end
	local first = c.steps[1]
	return result("template_added", { chain_id = c.chain_id, orch_project_id = project.orch_project_id,
		worker_id = first.worker_id, work_id = first.work_id }), nil
end
-- This session's entries of `map` that `keep` selects (all when nil), ascending by `serial`.
function config.ordered(map: any, sid: string, keep: ((any) -> boolean)?, serial: (any) -> number): any
	local list = {}
	for _, v in map or {} do if v.logical_session_id == sid and (keep == nil or keep(v)) then table.insert(list, v) end end
	table.sort(list, function(a, b) return serial(a) < serial(b) end)
	return list
end
-- Runs at the end of every dispatch commit for the event's session (after the command's effect).
function config.advance_sources(registry: any, n: any, event: any, clock: any, reserve: any)
	local d, sid = n.dispatch, event.orch_session_id
	if not n.sessions[sid] or n.sessions[sid].admitted ~= true then return end
	for _, w in d.workers do
		if w.logical_session_id == sid and w.project_held and w.phase == "queued" and not w.launch_refused and not w.routing
			and not w.mailbox_handle and not w.pane_binding and not w.accepted_event and not w.checks_pending
			and config.worker_start_allowed(d, w) and not config.starts_blocked(d, sid, clock)
			and not w.continuation_required and not w.launch_gates and not pending(d, w) then
			local _, problem = config.launch(registry, n, w, event, clock, reserve, false)
			if problem then
				w.project_held = true; w.checks_pending = true
				w.reason = { code = problem.code, message = problem.message }
			end
		end
	end
	for _, plan in config.ordered(d.plans, sid, function(p) return p.status ~= "done" end, function(p) return config.serial(p.plan_id) end) do
		config.advance_plan(registry, n, plan, event, clock, reserve)
	end
	for _, rec in config.ordered(n.dispatch.intakes, sid, function(r) return r.state ~= "refused" and r.lane ~= "done" end, function(r) return r.seq end) do
		config.advance_intake(registry, n, rec, event, clock, reserve)
	end
	for _, c in config.ordered(n.dispatch.chains, sid, function(c) return c.status ~= "done" and c.status ~= "stopped" end,
		function(c) return config.serial(c.chain_id) end) do
		config.advance_chain(registry, n, c, event, clock, reserve)
	end
	for _, name in { "plans", "intakes", "chains" } do
		for key, source in d[name] or {} do if source.logical_session_id == sid and source.held and source.start_policy then
			local p = config.project_ref(d, sid, source.orch_project_id)
			if p then config.auto_start_source(n, p, event, name, key) end
		end end
	end
	config.complete_projects(n, sid, stamp(clock).at_ms)
end
-- Window and card projections (Contract K): newest 64 intakes; desired lane per mapped board card.
function config.sources_view(d: any, sid: string, workflow: any)
	local p = policy(d, sid)
	local recs = config.ordered(d.intakes, sid, nil, function(rec) return -rec.seq end)
	workflow.intakes, workflow.board = {}, { path = p.board_path, cards = {} }
	for i = 1, math.min(#recs, config.SOURCE.PROJECTED_INTAKES) do
		local rec = recs[i]
		table.insert(workflow.intakes, { intake_id = rec.intake_id, orch_project_id = rec.orch_project_id, held = rec.held, kind = rec.kind, ref = rec.ref, state = rec.state, work_id = rec.work_id,
			path = rec.path, refusal = rec.refusal, hold = clone(rec.hold), lane = rec.lane,
			label = if rec.label then { worker_id = rec.label.worker_id, attempts = rec.label.attempts, retries = rec.label.loop.count,
				class = if rec.label.result then rec.label.result.class else nil } else nil })
	end
	for i = #recs, 1, -1 do
		local rec = recs[i]
		if rec.kind == "board" and rec.card_id and rec.state ~= "refused" and rec.lane then
			table.insert(workflow.board.cards, { path = rec.path, card_id = rec.card_id, intake_id = rec.intake_id, lane = rec.lane })
		end
	end
	workflow.plans, workflow.chains = {}, {}
	for _, plan in config.ordered(d.plans, sid, nil, function(plan) return config.serial(plan.plan_id) end) do
		local cps = {}
		for _, cp in plan.checkpoints do
			local tasks = {}
			for _, t in cp.tasks do
				table.insert(tasks, { id = t.id, title = t.title, state = t.state, independent = t.independent, work_id = t.work_id, worker_id = t.worker_id,
					hold = clone(t.hold), flags = clone(t.flags), checks = #t.checks, files = #t.files, source_state = t.source_state,
					source_identity = t.source_identity, identity_ambiguous = t.identity_ambiguous,
					steps = clone(t.steps or {}), filechanges = clone(t.filechanges or {}), validationchecks = clone(t.validationchecks or {}), depends_on = clone(t.depends_on or {}) })
			end
			table.insert(cps, { id = cp.id or ("cp" .. tostring(cp.n)), source_state = cp.source_state, n = cp.n, title = cp.title, flags = clone(cp.flags), tasks = tasks })
		end
		table.insert(workflow.plans, { plan_id = plan.plan_id, orch_project_id = plan.orch_project_id, held = plan.held, path = plan.path, plan_revision = plan.plan_revision, title = plan.title, status = plan.status,
			flags = clone(plan.flags), checkpoints = cps })
	end
	for _, c in config.ordered(d.chains, sid, nil, function(c) return config.serial(c.chain_id) end) do
		table.insert(workflow.chains, { chain_id = c.chain_id, orch_project_id = c.orch_project_id, held = c.held, status = c.status, successes = c.successes, loop = clone(c.loop), hold = clone(c.hold), steps = clone(c.steps) })
	end
end
config.SOURCE_COMMANDS = { plan_import = config.plan_import_command, board_intake = config.board_intake_command,
	inbox_intake = config.inbox_intake_command, template_start = config.template_start_command }
-- Restore boundary validation of the three source collections.
function config.valid_hold(v: any): boolean return v == nil or (closed(v, "code message") and str(v.code, 96) and wire_text(v.message, 1024)) end
function config.passive_proposal(registry: any, n: any, coordinator_worker: any, g: any, p: any, event: any, clock: any, reserve: any): (string, string, string)
	local d, sid = n.dispatch, coordinator_worker.logical_session_id
	if type(clock) == "table" and clock.reserved_capacity then return "pending", "capacity_reached", "Held intake waits for ordinary storage capacity." end
	if p.kind == "add_source" and g.execution and g.execution.state == "pending" and g.execution.effect_ref:sub(1, 8) == "project:" then
		return "pending", g.execution.effect_ref, "Observe the proposed board's exact revision in its desktop window before adding its cards."
	end
	local project = if p.orch_project_id then config.project_ref(d, sid, p.orch_project_id) else nil
	if p.orch_project_id and not project then return "refused", "project_changed", "The chosen project is no longer available." end
	local row
	if p.kind == "new_work" then
		row = config.catalog_row(d, sid, p.record_id, "Proposed", "choose a current agent.")
		if not row or row.revision ~= p.record_revision then return "refused", "catalog_changed", "The proposed record/revision is no longer eligible." end
		if count(d.workers) >= 32 then return "pending", "workers_full", "Held work waits for a free managed worker slot." end
		if p.repository_id then
			local repo, catalog = if project then project.repository else nil, d.catalogs[sid]
			if not repo or not catalog or config.repository_key(catalog.host_key, repo.common_dir, repo.target_ref) ~= p.repository_id
				or (p.target_ref and (config.repository_target(p.target_ref) ~= config.repository_target(repo.target_ref) or p.target_revision ~= repo.head_revision)) then
				return "refused", "repository_unverified", "The proposal's repository/target does not match this project's retained canonical association."
			end
		end
	end
	if not project then project = config.new_project(d, sid, p.new_project_name, nil) end
	local add_event = table.clone(event); add_event.orch_project_id = project.orch_project_id; add_event.force_held = true
	add_event.presentation = "background"
	if p.kind == "new_work" then
		local worker = config.new_worker(d, add_event, sid, row, p.prompt, g.id .. ":", "builder")
		local problem = config.assign(worker, { scope = p.scope, files = p.scope.paths, checks = p.checks, base_ref = p.base_ref,
			source = { kind = "manual", ref = "coordinator-proposal" } })
		if problem then return "refused", problem.code, problem.message end
		if M.request_size(launch_request(worker, string.rep("h", 96))) > codec.DISPATCH.limit then return "refused", "oversize", "Proposed work exceeds the immutable launch bound." end
		worker.project_held = true; worker.checks_pending = true
		project.checks_pending = if #p.checks > 0 then true else project.checks_pending
		project.revision += 1; d.workers[worker.worker_id] = worker
		append(d, worker, "assignment", worker.prompt, clock)
		return "done", "worker:" .. worker.worker_id, "Work added held. Review its commands and choose project START; no launch or resume occurred."
	end
	local source = p.source
	if source.kind == "board" then
		local _, problem = config.source_project(d, add_event, project.name, { kind = "board", ref = source.path, revision = source.revision })
		if problem then return "refused", problem.code, problem.message end
		return "pending", "project:" .. project.orch_project_id, "Board selected; waiting for its exact desktop-window observation. No board file was read on the host."
	end
	local answer, problem
	add_event.source_revision = source.revision
	if source.kind == "plan_file" then
		add_event.path = source.path
		answer, problem = config.plan_import_command(registry, n, add_event, clock, reserve)
	else
		add_event.template_id = source.template_id; add_event.input = source.input; add_event.custom_fields = source.custom_fields
		answer, problem = config.template_start_command(registry, n, add_event, clock, reserve)
	end
	if problem then return "refused", problem.code, problem.message end
	return "done", "project:" .. project.orch_project_id, "Source added held. Project START remains a separate owner decision."
end
function config.consume_source_request(registry: any, n: any, event: any, clock: any, reserve: any): (any?, any?)
	local d = n.dispatch
	local gate = if id(event.gate_id) then d.gates[event.gate_id] else nil
	local worker = if gate then d.workers[gate.worker_id] else nil
	local report = if worker and gate.proposal then codec.decode_report(gate.proposal, worker) else nil
	local p = if report then report.payload else nil
	if not gate or gate.logical_session_id ~= event.orch_session_id or gate.revision ~= event.gate_revision or gate.phase == "cancelled" or gate.phase == "superseded"
		or not gate.answer or gate.answer.choice_id ~= "approve" or not gate.execution or gate.execution.state ~= "pending"
		or not p or p.kind ~= "add_source" or p.source.kind ~= "board" or event.source_revision ~= p.source.revision
		or not dense(event.cards, 256) or quota.digest(event.cards) ~= event.source_revision then return fail("source_changed", "This approved board proposal or its observed source revision changed; nothing was imported.") end
	local project_id = gate.execution.effect_ref:match("^project:(.+)$")
	if not config.project_ref(d, event.orch_session_id, project_id) then return fail("project_changed", "The proposed board's project is no longer available.") end
	for _, card in event.cards do
		if not closed(card, "card_id text tags text_sha256") then return fail("intake_invalid", "Board observation contains unexpected card fields.") end
		local intake = table.clone(event)
		intake.board_path = p.source.path; intake.orch_project_id = project_id; intake.force_held = true
		intake.card_id = card.card_id; intake.text = card.text; intake.tags = card.tags; intake.text_sha256 = card.text_sha256
		local _, problem = config.board_intake_command(registry, n, intake, clock, reserve)
		if problem then return nil, problem end
	end
	gate.execution = { state = "done", effect_ref = "project:" .. project_id, gate_revision = gate.revision, at_ms = stamp(clock).at_ms }
	return result("source_added", { orch_project_id = project_id, message = "Observed board cards added held. Nothing was started." }), nil
end

function config.valid_sources(d: any, registry: any): boolean
	if d.plans ~= nil then
		if type(d.plans) ~= "table" or d.plans == tern.json.null then return false end
		for key, plan in d.plans do
			if not closed(plan, "plan_id logical_session_id orch_project_id held start_policy path plan_revision title flags status at_ms checkpoints") or not id(key) or plan.plan_id ~= key or (plan.held ~= nil and plan.held ~= true)
				or (plan.start_policy ~= nil and not digest(plan.start_policy))
				or not registry.sessions[plan.logical_session_id] or not config.absolute(plan.path, 512) or not digest(plan.plan_revision) or not str(plan.title, 256)
				or not config.texts(plan.flags, 16, 64) or not table.find(config.PLAN_STATUSES, plan.status) or not (plan.at_ms == 0 or pos(plan.at_ms))
				or not dense(plan.checkpoints, config.plan_parser.MAX_CHECKPOINTS) then return false end
			local tasks = 0
			for _, cp in plan.checkpoints do
				if not closed(cp, "id source_state n title flags tasks") or (cp.id ~= nil and not str(cp.id, 96)) or not config.source_state(cp.source_state)
					or not (cp.n == 0 or pos(cp.n)) or not str(cp.title, 256) or not config.texts(cp.flags, 16, 64)
					or not dense(cp.tasks, config.plan_parser.MAX_TASKS) then return false end
				for _, t in cp.tasks do
					tasks += 1
					if not closed(t, "id title independent sequential_why class template_id files checks systems flags text source_identity identity_ambiguous source_state steps filechanges validationchecks depends_on state work_id worker_id hold")
						or not config.source_state(t.source_state) or not config.hierarchy(t)
						or (t.source_identity ~= nil and (not str(t.source_identity, 96) or #t.source_identity ~= 71 or t.source_identity:match("^source%-[a-f0-9]+$") == nil))
						or (t.identity_ambiguous ~= nil and t.identity_ambiguous ~= true)
						or (t.depends_on ~= nil and not config.texts(t.depends_on, 64, 32))
						or not str(t.id, 32) or not str(t.title, 256) or type(t.independent) ~= "boolean" or (t.sequential_why ~= nil and not str(t.sequential_why, 256))
						or (t.class ~= nil and not config.slug(t.class, 32)) or (t.template_id ~= nil and not config.slug(t.template_id, 32))
						or not config.texts(t.files, 64, 256) or not config.texts(t.systems, 16, 80) or not config.texts(t.flags, 16, 64) or not str(t.text, config.SOURCE.TASK_TEXT, true)
						or not config.list(t.checks, 16) or not table.find(config.TASK_STATES, t.state) or (t.work_id ~= nil and not id(t.work_id))
						or (t.worker_id ~= nil and not id(t.worker_id)) or (t.work_id == nil) ~= (t.worker_id == nil) or not config.valid_hold(t.hold)
						or ((t.state == "running" or (t.state == "done" and t.source_state ~= "done")) and t.work_id == nil) or (t.state == "held" and t.hold == nil) then return false end
					for _, check in t.checks do
						if not closed(check, "check_id argv") or not id(check.check_id) or not config.texts(check.argv, 16, 512, 1) then return false end
					end
				end
			end
			if tasks > config.plan_parser.MAX_TASKS then return false end
		end
	end
	if d.intakes ~= nil then
		if type(d.intakes) ~= "table" or d.intakes == tern.json.null or count(d.intakes) > config.SOURCE.INTAKES then return false end
		for key, rec in d.intakes do
			if not closed(rec, "intake_id logical_session_id orch_project_id held start_policy kind ref path revision card_id class text tags state refusal work_id worker_id hold lane seq at_ms label") or (rec.held ~= nil and rec.held ~= true)
				or (rec.start_policy ~= nil and not digest(rec.start_policy))
				or not digest(key) or rec.intake_id ~= key or not registry.sessions[rec.logical_session_id] or (rec.kind ~= "board" and rec.kind ~= "inbox")
				or not wire_text(rec.ref, 8192) or not config.absolute(rec.path, 4096) or not digest(rec.revision)
				or (rec.card_id ~= nil and (not str(rec.card_id, protocol.NATIVE_BOARD_ID_BYTES) or rec.card_id:find("%c") ~= nil))
				or (rec.class ~= nil and not config.slug(rec.class, 32)) or (rec.text ~= nil and not str(rec.text, config.SOURCE.CARD_BYTES))
				or (rec.tags ~= nil and not config.texts(rec.tags, 64, 256)) or not table.find(config.INTAKE_STATES, rec.state)
				or (rec.state == "refused") ~= (rec.refusal ~= nil) or (rec.refusal ~= nil and not str(rec.refusal, 96))
				or (rec.work_id ~= nil and not id(rec.work_id)) or (rec.work_id == nil) ~= (rec.worker_id == nil) or (rec.worker_id ~= nil and not id(rec.worker_id))
				or (rec.state == "accepted" and rec.work_id == nil) or not config.valid_hold(rec.hold) or not config.valid_label(rec.label)
				or (rec.lane ~= nil and not table.find(config.LANES, rec.lane)) or not pos(rec.seq) or not (rec.at_ms == 0 or pos(rec.at_ms)) then return false end
		end
	end
	if d.chains ~= nil then
		if type(d.chains) ~= "table" or d.chains == tern.json.null or count(d.chains) > config.SOURCE.CHAINS then return false end
		for key, c in d.chains do
			if not closed(c, "chain_id logical_session_id orch_project_id held start_policy status successes steps loop hold next_template at_ms") or not id(key) or c.chain_id ~= key or (c.held ~= nil and c.held ~= true)
				or (c.start_policy ~= nil and not digest(c.start_policy))
				or not registry.sessions[c.logical_session_id] or not table.find(config.CHAIN_STATUSES, c.status)
				or not (c.successes == 0 or pos(c.successes)) or c.successes > config.SOURCE.CHAIN_BOUND or not dense(c.steps, config.SOURCE.CHAIN_STEPS, 1)
				or not loops.valid(c.loop) or not config.valid_hold(c.hold) or (c.next_template ~= nil and not config.slug(c.next_template, 32))
				or (c.status == "capped" and c.next_template == nil) or not (c.at_ms == 0 or pos(c.at_ms)) then return false end
			for _, s in c.steps do
				if not closed(s, "template_id input custom_fields output_path state work_id worker_id output_ref hold") or not config.slug(s.template_id, 32)
					or (s.custom_fields ~= nil and not config.custom_fields(s.custom_fields))
					or (s.output_path ~= nil and not config.relative(s.output_path, 256))
					or not str(s.input, math.max(config.SOURCE.INPUT_BYTES, 256)) or not table.find(config.STEP_STATES, s.state)
					or (s.work_id ~= nil and not id(s.work_id)) or (s.work_id == nil) ~= (s.worker_id == nil) or (s.worker_id ~= nil and not id(s.worker_id))
					or (s.state ~= "held" and s.state ~= "failed" and s.work_id == nil) or (s.output_ref ~= nil and not config.relative(s.output_ref, 256))
					or not config.valid_hold(s.hold) then return false end
			end
		end
	end
	return true
end
function config.source_state(value: any): boolean return value == nil or table.find({ "pending", "active", "done", "blocked", "paused" }, value) ~= nil end
function config.hierarchy(t: any): boolean
	for _, field in { "steps", "filechanges", "validationchecks" } do
		local values = t[field]
		if values == nil then continue end
		if not config.list(values, if field == "steps" then 256 elseif field == "filechanges" then 64 else 16) then return false end
		local seen = {}
		for _, node in values do
			if not closed(node, if field == "filechanges" then "id path action state" elseif field == "validationchecks" then "id text argv state" else "id text state")
				or not str(node.id, 96) or seen[node.id] or not config.source_state(node.state) then return false end
			seen[node.id] = true
			if field == "filechanges" then
				if not str(node.path, 256) or not str(node.action, 64) then return false end
			elseif not str(node.text, 4096) or (node.argv ~= nil and not config.texts(node.argv, 16, 512, 1)) then return false end
		end
	end
	return true
end
-- A delivery record bound to this report's exact action and revision.
function config.same_action(x: any, report: any): any return x and x.action_id == report.action_id and x.action_revision == report.action_revision end
-- Report kinds only one ORCH+-set role may file: { role, refusal code, refusal message }.
config.REPORT_ROLES = { LABEL = { "labeller", "label_unauthorized", "Only an ORCH+ labeller worker reports LABEL, for the label_request it received." },
	LANDING_RESULT = { "release_manager", "landing_unauthorized",
		"Only the exact accepted merge actor reports LANDING_RESULT for the landing_grant it holds." },
	DEPLOY_RESULT = { "release_manager", "deploy_unauthorized", "Only the exact accepted merge actor reports DEPLOY_RESULT for the deploy_grant it holds." } }
local function correlated(d: any, w: any, report: any, f: any): any?
	for _, g in d.gates or {} do
		if g.worker_id == w.worker_id and config.same_action(g.delivery, report) then return g end
	end
	for _, item in (d.landing or {}).items or {} do
		for _, g in item.grants do
			if g.worker_id == w.worker_id and config.same_action(g, report) then return g end
		end
	end
	for _, dp in d.deploys or {} do
		for _, a in dp.attempts do
			if a.worker_id == w.worker_id and config.same_action(a, report) then return a end
		end
	end
	-- A label_request (labeller) stays correlatable after its ACK compacts the reply.
	for _, rec in d.intakes or {} do
		if rec.label and rec.label.worker_id == w.worker_id and config.same_action(rec.label.request, report) then return rec end
	end
	-- A review_request (reviewer) or review rework (builder) stays correlatable after its ACK compacts the reply.
	for _, rv in d.reviews or {} do
		if rv.reviewer_worker_id == w.worker_id and config.same_action(rv.request, report) then return rv end
		if rv.builder_work_id == w.work_id and rv.logical_session_id == w.logical_session_id and config.same_action(rv.rework, report) then return rv end
	end
	for _, r in w.replies do if config.same_action(r, report) then return r end end
	if config.same_action(f.report_request, report) then return f.report_request end
	return nil
end
local function semantic(n: any, w: any, report: any, bytes: string, clock: any): (any?, any?)
	local d, p, kind, f, only = n.dispatch, report.payload, report.kind, flow(w), config.REPORT_ROLES[report.kind]
	if w.phase ~= "accepted" then return fail("acceptance_required", "Progress requires this generation's accepted assignment.") end
	if kind == "REVIEW_RESULT" and w.role ~= "reviewer" then return fail(config.review_refusal(d, w)) end
	if only and w.role ~= only[1] and not (w.role == "builder" and (kind == "LANDING_RESULT" or kind == "DEPLOY_RESULT")) then return fail(only[2], only[3]) end
	local correlation, helper_summary
	if report.action_id then
		correlation = correlated(d, w, report, f)
		if not correlation or correlation.phase == "cancelled" or correlation.phase == "superseded" then return fail("binding_mismatch", "Report action/revision was not issued or is no longer current for this recipient.") end
	end
	if p.request_id then
		local request = f.report_request
		if not request or request.request_id ~= p.request_id then return fail("binding_mismatch", "Progress request does not match this worker's outstanding request.") end
		if request.response_received then return fail("request_already_answered", "Replay the original immutable response; a new event cannot replace it while its reply ACK is pending.") end
		if kind ~= "WAITING" and kind ~= "HEARTBEAT" and kind ~= "CHECKPOINT" then return fail("invalid_schema", "Unexpected report request correlation.") end
	end
	local checkpoint = if p.checkpoint_id and f.checkpoints[p.checkpoint_id] then codec.decode_report(f.checkpoints[p.checkpoint_id], w) else nil
	local refused -- A coordinator proposal ORCH+ refused definitely (committed, never held).
	if table.find({ "REVIEW_READY", "DONE", "ROLLOVER_REQUEST" }, kind) and (not checkpoint
		or (p.artifact_revision and p.artifact_revision ~= checkpoint.payload.artifact_revision)) then
		return fail("checkpoint_mismatch", "Report must reference a retained checkpoint and its exact artifact revision.")
	end
	if kind == "CHECKPOINT" then
		if checkpoint and not equal(checkpoint.payload, p) then return fail("checkpoint_conflict", "Checkpoint IDs are immutable; publish a new checkpoint ID for changed evidence.") end
		if not checkpoint and count(f.checkpoints) >= 16 then return fail("full", "Checkpoint evidence is full; unresolved handover/review evidence was retained.") end
		f.checkpoints[p.checkpoint_id] = bytes
		if #p.completed > 0 then f.boundary_seq = report.seq end
		config.review_void(d, w, report, clock)
		if config.checkout_mismatch(w, report) then
			local _, err = append(d, w, "attention", bounded("Checkpoint " .. p.checkpoint_id .. " names worktree_ref " .. p.worktree_ref .. " but the latest helper CHECKOUT reported "
				.. w.checkout.worktree_path .. "; landing holds checkout_mismatch until a CHECKPOINT names the reported checkout.", 32768), clock)
			if err then return nil, err end
		end
	elseif kind == "ASK" then
		local _, err = new_gate(d, w, "owner_question", p.question, p.options, p.evidence, clock); if err then return nil, err end
	elseif kind == "COORDINATOR_PROPOSAL" then
		local owner, activation = coordinator(n, w), w.activation
		if not owner or owner.phase ~= "running" or not activation or not activation.acknowledged or w.retirement
			or p.owner_id ~= owner.owner_id or p.owner_generation ~= owner.generation or p.activation_token ~= activation.activation_token then
			return fail("proposal_unauthorized", "Proposal requires the active owner/generation and durably acknowledged activation token.")
		end
		if restored_coordinator(d, w.logical_session_id) then return fail("coordinator_restored", "A retired coordinator pane was observed alive again; coordinator effects are held until it is reconciled.") end
		for _, g in d.gates or {} do
			if g.worker_id == w.worker_id and g.proposal and not config.refused_proposal(g) then
				local prior = codec.decode_report(g.proposal, w)
				if prior.payload.proposal_id == p.proposal_id then return fail("proposal_conflict", "Proposal ID already exists; replay its exact original report instead.") end
			end
		end
		local target, target_checkpoint
		for _, worker in d.workers do if worker.work_id == p.work_id and worker.logical_session_id == w.logical_session_id then target = worker end end
		for _, cpbytes in (if target and target.workflow then target.workflow.checkpoints else {}) do
			local cp = codec.decode_report(cpbytes, target)
			if cp.payload.project_id == p.project_id and (p.checkpoint_id == nil or cp.payload.checkpoint_id == p.checkpoint_id) then target_checkpoint = cp end
		end
		-- Paused sessions and proposals naming no retained checkpoint scope are refused definitely.
		refused = if p.kind == "new_work" or p.kind == "add_source" then nil
			elseif p.kind == "review" and not policy(d, w.logical_session_id).require_code_review then "review_disabled"
			elseif policy(d, w.logical_session_id).paused then "session_paused" elseif not target_checkpoint then "scope_mismatch" else nil
		local _, problem
		if refused then _, problem = config.refuse_proposal(d, w, p, bytes, refused, clock)
		else _, problem = config.open_proposal(d, w, p, bytes, target_checkpoint, clock) end
		if problem then return nil, problem end
	elseif kind == "REVIEW_READY" then
		local problem = config.review_ready(n, w, checkpoint, clock); if problem then return nil, problem end
	elseif kind == "REVIEW_RESULT" then
		local problem = config.review_result(n, w, report, correlation, clock); if problem then return nil, problem end
	elseif kind == "LANDING_REQUEST" then
		if not checkpoint or checkpoint.payload.project_id ~= p.project_id or checkpoint.payload.artifact_revision ~= p.source_revision then
			return fail("checkpoint_mismatch", "LANDING_REQUEST must reference a retained checkpoint of this project for the exact source revision.")
		end
		local _, problem = landing_request(n, w, report, clock); if problem then return nil, problem end
	elseif kind == "LANDING_RESULT" then
		local _, problem = landing_result(n, w, report, clock); if problem then return nil, problem end
	elseif kind == "DEPLOY_RESULT" then
		local problem = config.deploy_result(n, w, report, correlation, clock); if problem then return nil, problem end
	elseif kind == "DONE" then
		landing_done(d, w, clock); config.deploy_done(d, w, clock); config.usage_end(d, w, clock)
	elseif kind == "LABEL" then
		local problem = config.label_result(n, w, report, correlation); if problem then return nil, problem end
	elseif kind == "CHECK_RESULT" or kind == "CHECKOUT" then
		-- Helper-only facts live on the worker (checkout, check_results), never in report evidence.
		local err; helper_summary, err = config.helper_fact(d, w, report, clock); if err then return nil, err end
	end
	local summary = helper_summary or p.summary or p.reason or p.question or (kind .. (if p.checkpoint_id then " " .. p.checkpoint_id else ""))
	local retained = table.find({ "WAITING", "BLOCKED", "CHECKPOINT", "REVIEW_READY", "REVIEW_RESULT", "DONE", "ROLLOVER_REQUEST", "LANDING_REQUEST", "LANDING_RESULT" }, kind) ~= nil
	if kind == "READY" or kind == "DONE" or (kind == "HEARTBEAT" and (p.state == "working" or p.state == "idle")) then
		for i = #f.thread, 1, -1 do
			if f.thread[i].kind == "WAITING" or f.thread[i].kind == "BLOCKED" then table.remove(f.thread, i) end
		end
	end
	-- A landing result's unresolved state lives on its queue item, so its thread entry is settled history.
	local _, err = append(d, w, kind, summary, clock, { event_id = report.event_id, action_id = report.action_id,
		state = if retained and kind ~= "LANDING_RESULT" then "pending" else "settled", report_bytes = if retained then bytes else nil }); if err then return nil, err end
	if helper_summary == nil then
		f.evidence[kind] = bytes
		local observation = stamp(clock); observation.kind = kind; observation.event_id = report.event_id
		observation.state = if kind == "READY" then "idle" elseif kind == "HEARTBEAT" then p.state elseif kind == "WAITING" or kind == "ASK" then "waiting"
			elseif kind == "BLOCKED" then "blocked" elseif kind == "DONE" then "done" else (if f.report then f.report.state else "working")
		f.report = observation
	end
	if kind == "READY" or kind == "HEARTBEAT" or (kind == "CHECKPOINT" and (p.context_snapshot ~= nil or p.context_used_pct ~= nil)) then
		f.context = nil
		if p.context_snapshot ~= nil or p.context_used_pct ~= nil then
			local c = stamp(clock); c.seq = report.seq; c.status = "measured"
			c.snapshot = clone(p.context_snapshot)
			c.used_pct = if c.snapshot then 100 * c.snapshot.current_tokens / c.snapshot.window_tokens else p.context_used_pct
			if c.snapshot then
				local s, b = c.snapshot, f.context_basis
				if b and (s.window_tokens ~= b.window_tokens or (b.first_turn_tokens ~= nil and s.first_turn_tokens ~= nil and s.first_turn_tokens ~= b.first_turn_tokens)) then
					c.status = "inconsistent"
				elseif c.at_ms > 0 and s.observed_at_ms <= c.at_ms and c.at_ms - s.observed_at_ms < policy(d, w.logical_session_id).stale_ms then
					-- Reuse only this generation's already measured baseline, never a percentage-derived estimate.
					if s.first_turn_tokens == nil and b then s.first_turn_tokens = b.first_turn_tokens end
					f.context_basis = { window_tokens = s.window_tokens,
						first_turn_tokens = if b and b.first_turn_tokens ~= nil then b.first_turn_tokens else s.first_turn_tokens }
				end
			end
			f.context = c
		end
	end
	config.refresh_context(policy(d, w.logical_session_id), f, clock)
	if p.request_id and (kind == "HEARTBEAT" or kind == "CHECKPOINT") then
		f.report_request.response_received = true; f.report_request.response_bytes = bytes
		if f.report_request.acknowledged then settle_entries(w, "request_id", p.request_id); f.report_request = nil end
	end
	-- Any report the worker sends unprompted is the "new report" that ends the automatic request loop.
	if p.request_id == nil and f.report_loop then
		local g = loops.gate(d, f.report_loop)
		if g then g.phase = "superseded"; g.revision += 1; settle_entries(w, "gate_id", g.id) end
		f.report_loop = nil
	end
	return result("semantic_applied", { refused = refused }), nil
end
local function intake_mutating(n: any, w: any, bytes: string, clock: any): (any?, any?)
	if w.frozen then return fail("content_conflict", "This generation is frozen; recover its conflicting immutable report.") end
	if w.rejected_report then return fail("report_held", "A rejected immutable report remains held; intake cannot overwrite or skip it.") end
	if w.pane_binding == nil then return fail("launch_unbound", "Only a correlated SPAWN launch outcome may bind report intake.") end
	local report, err = codec.decode_report(bytes, w); if err then return nil, err end
	if w.startup_cancelling then return fail("startup_cancelling", "Settle the exact failed-startup retirement; no acceptance or activation is synthesized.") end
	if w.enrol_cancelling and (w.mailbox_retire_action_id ~= nil or not w.retirement_refused or report.kind ~= "ACCEPTED") then
		return fail("enrolment_revoking", "Settle the exact revocation first. An uncertain enrollment is never replayed or silently activated.")
	end
	local hash = codec.sha256(bytes)
	if report.seq <= w.compacted_floor then return fail("already_compacted", "Worker confirmed this retired receipt prefix; repair its journal rather than replaying it.") end
	if report.seq <= w.accepted_seq then
		local prior = w.receipts[tostring(report.seq)]
		if prior == nil or prior.sha256 ~= hash or prior.event_id ~= report.event_id then w.frozen = true; return result("content_conflict_frozen"), nil end
		prior.publish = true; return result("report_replayed"), nil
	end
	if report.seq ~= w.accepted_seq + 1 then return fail("gap", "Expected report sequence " .. tostring(w.accepted_seq + 1)) end
	local start_project, issued_start
	if report.kind == "PROJECT_START_CLAIM" then start_project, issued_start = config.find_start(n.dispatch, w, report) end
	if w.coordinator_owner_id and (not coordinator(n, w) or w.mailbox_retired) and not issued_start then return fail("owner_mismatch", "Retired, recovering or stale coordinator cannot submit new reports.") end
	if (w.release or w.finish or w.mailbox_retired) and report.kind ~= "reply_ack" and not issued_start then return fail("worker_retiring", "Only already-committed reply acknowledgements may follow explicit finish/release.") end
	local outstanding = 0
	for _, receipt in w.receipts do if (receipt.kind == "reply_ack") == (report.kind == "reply_ack") then outstanding += 1 end end
	if outstanding >= 8 then return fail("full", "This generation's report lane is full; publish the worker's cumulative watermark.") end
	local refused -- Definitive refusal consumes only an authentic issued proposal/START fact, never its requested effect.
	if report.kind == "ACCEPTED" then
		if w.accepted_event ~= nil then return fail("already_accepted", "Initial assignment was already accepted by another event.") end
		if w.enrol_cancelling then w.enrol_cancelling = nil; w.retirement_refused = nil end
		w.phase = "accepted"; w.accepted_event = { event_id = report.event_id, seq = report.seq, event_sha256 = hash }
		w.enrol_association = nil
		w.accept_pending = true
		local observation = stamp(clock); observation.kind = "ACCEPTED"; observation.event_id = report.event_id; observation.state = "working"; flow(w).report = observation
	elseif report.kind == "reply_ack" then
		local reply = w.replies[tostring(report.payload.reply_seq)]
		if reply == nil or report.payload.message_id ~= reply.message_id or report.payload.reply_sha256 ~= reply.sha256
			or report.action_id ~= reply.action_id or report.action_revision ~= reply.action_revision then return fail("binding_mismatch", "Reply ACK does not match a committed immutable reply/action.") end
		reply.acknowledged = true
		-- Marks a delivery record bound to this exact reply action/revision acknowledged.
		local function ack(x: any): boolean
			if not x or x.action_id ~= reply.action_id or x.action_revision ~= reply.action_revision then return false end
			x.acknowledged = true; x.ack_seq = report.seq; x.ack_sha256 = hash
			return true
		end
		local f = flow(w)
		if f.report_request and f.report_request.action_id == reply.action_id then
			f.report_request.acknowledged = true; f.report_request.ack_seq = report.seq; f.report_request.ack_sha256 = hash
			if f.report_request.response_received then settle_entries(w, "request_id", f.report_request.request_id); f.report_request = nil end
		end
		for _, g in n.dispatch.gates or {} do
			if g.worker_id == w.worker_id and g.delivery and g.delivery.action_id == reply.action_id then
				g.delivery.acknowledged = true; g.delivery.ack_seq = report.seq; g.delivery.ack_sha256 = hash; g.delivery_uncertain = false
				if g.phase ~= "cancelled" and g.phase ~= "superseded" then g.phase = "acknowledged" end
				settle_entries(w, "gate_id", g.id)
				for _, entry in flow(w).thread do if entry.gate_id == g.id and entry.kind:sub(1, 6) == "answer" then entry.kind = "answer_acknowledged" end end
			end
		end
		config.review_acked(n.dispatch, reply)
		for _, dp in n.dispatch.deploys or {} do
			for _, a in dp.attempts do if a.worker_id == w.worker_id then ack(a) end end
		end
		-- Grant consumption is acknowledgement only; the slot settles on the exact LANDING_RESULT.
		for _, item in (n.dispatch.landing or {}).items or {} do
			for _, g in item.grants do
				if g.worker_id == w.worker_id and ack(g) and landing_current(item) == g and item.status == "granted" then landing_status(item, "landing", item.hold, n.revision, clock) end
			end
			-- Refresh consumption is acknowledgement only; the item rebinds on a fresh LANDING_REQUEST.
			if item.refresh and item.refresh.worker_id == w.worker_id then ack(item.refresh) end
		end
		for _, name in { "activation", "retirement" } do ack(w[name]) end
		for _, project in n.dispatch.projects or {} do
			local start = project.start
			if start and start.coordinator.worker_id == w.worker_id then ack(start) end
		end
	elseif report.kind == "PROJECT_START_CLAIM" then
		local project, start = start_project, issued_start
		if not start or start.claim or (start.closed and start.closed.report_bytes) then
			return fail("start_claim_unauthorized", "This exact START action, revision and payload must have been issued once to this authenticated worker.")
		end
		if (not start.published or not start.acknowledged) and not (start.closed and start.closed.retired and config.start_owner_closed(n, project, start)) then
			return fail("start_claim_pending", "Waiting for your orchestrator to finish getting ready. New work is still on hold.")
		end
		local failure = config.start_permanent_failure(n, project, start)
		if failure then
			config.close_start(n, project, start, failure, bytes); refused = failure.code
		else
			local owner, activation = coordinator(n, w), w.activation
			if not owner or owner.phase ~= "running" or not w.accepted_event or w.accept_pending or not activation or not activation.acknowledged
				or w.continuation_required then return fail("start_claim_pending", "The original coordinator must finish its authenticated recovery before START can be applied.") end
			local released, problem = config.release_start(n.dispatch, project, start.snapshot,
				{ origin = control_origin(w), controller_pane = control_pane(w) }, clock)
			if not released then return nil, problem end
			start.claim = bytes; start.failure = nil
		end
	elseif report.kind == "COORDINATOR_RELEASE" then
		local owner, activation, p = coordinator(n, w), w.activation, report.payload
		local grant = if activation and report.action_id == activation.action_id then activation else w.retirement
		if not owner or not activation or not activation.acknowledged or not grant or report.action_id ~= grant.action_id
			or report.action_revision ~= grant.action_revision or p.owner_id ~= owner.owner_id or p.owner_generation ~= owner.generation
			or p.activation_token ~= activation.activation_token then return fail("release_unauthorized", "Release requires this worker's exact issued activation, durable activation receipt and current owner/generation/token.") end
		if flow(w).report_request then return fail("workflow_unsettled", "Respond to the outstanding progress request before cooperative release.") end
		for _, g in n.dispatch.gates or {} do
			if g.worker_id == w.worker_id and (gate_open(g) or (g.delivery and not g.delivery.acknowledged)) then
				return fail("workflow_unsettled", "Owner decision work remains pending or unacknowledged; release cannot discard it.")
			end
		end
		w.release = { seq = report.seq, event_sha256 = hash, action_id = report.action_id, action_revision = report.action_revision }
		owner.phase = "retiring"
	elseif report.kind == "REGISTER" then
		w.registered = true -- Codec checks declared capabilities against provisioned facts; not proof.
	else
		local applied, problem = semantic(n, w, report, bytes, clock); if problem then return nil, problem end
		refused = applied.refused
	end
	local ack = { version = 1, event_id = report.event_id, seq = report.seq, event_sha256 = hash, committed_revision = n.revision, disposition = "accepted" }
	for _, k in B do ack[k] = w[k] end
	ack.receipt_chain_sha256 = codec.receipt_chain(w.mailbox_handle, w.receipt_chain, ack)
	local encoded = tern.json.encode(ack)
	w.receipts[tostring(report.seq)] = { bytes = encoded, sha256 = hash, event_id = report.event_id, chain = ack.receipt_chain_sha256, publish = true, kind = report.kind }
	w.accepted_seq = report.seq; w.receipt_chain = ack.receipt_chain_sha256
	while w.replies[tostring(w.reply_floor + 1)] and w.replies[tostring(w.reply_floor + 1)].acknowledged do
		local held_publication = false
		for _, project in n.dispatch.projects or {} do
			local start = project.start
			if start and start.coordinator.worker_id == w.worker_id and start.reply_seq == w.reply_floor + 1 and not start.published then held_publication = true end
		end
		if held_publication then break end -- Consumption cannot discard the bytes needed to prove a still-uncertain original publication.
		w.reply_floor += 1; w.replies[tostring(w.reply_floor)] = nil; w.compaction_pending = n.revision
	end
	refresh(n.dispatch, w, clock)
	-- A definitely refused proposal is committed (its lane moves on); the answer names the refusal.
	return result(refused or "report_committed", { refused = refused }), nil
end
local function intake(n: any, w: any, bytes: string, clock: any): (any?, any?)
	-- Semantic failure leaves even the caller's candidate untouched, including full-lane recovery.
	local trial = table.clone(n); trial.dispatch = table.clone(n.dispatch); trial.sessions = clone(n.sessions)
	trial.dispatch.gates = clone(n.dispatch.gates); trial.dispatch.workers = clone(n.dispatch.workers); trial.dispatch.landing = clone(n.dispatch.landing)
	trial.dispatch.reviews = clone(n.dispatch.reviews); trial.dispatch.deploys = clone(n.dispatch.deploys); trial.dispatch.intakes = clone(n.dispatch.intakes)
	local decoded = codec.decode_report(bytes, w)
	if decoded and (decoded.kind == "PROJECT_START_CLAIM" or decoded.kind == "reply_ack") then trial.dispatch.projects = clone(n.dispatch.projects) end
	if decoded and decoded.kind == "PROJECT_START_CLAIM" then
		trial.dispatch.plans = clone(n.dispatch.plans); trial.dispatch.chains = clone(n.dispatch.chains); trial.dispatch.actions = clone(n.dispatch.actions)
	end
	local worker = trial.dispatch.workers[w.worker_id]
	local applied, err = intake_mutating(trial, worker, bytes, clock)
	if err then return nil, err end
	for key in w do w[key] = nil end
	for key, value in worker do w[key] = value end
	trial.dispatch.workers[w.worker_id] = w; n.dispatch.workers = trial.dispatch.workers
	n.dispatch.serial = trial.dispatch.serial; n.dispatch.gates = trial.dispatch.gates; n.dispatch.landing = trial.dispatch.landing; n.sessions = trial.sessions
	n.dispatch.reviews = trial.dispatch.reviews; n.dispatch.deploys = trial.dispatch.deploys; n.dispatch.intakes = trial.dispatch.intakes
	n.dispatch.projects = trial.dispatch.projects; n.dispatch.plans = trial.dispatch.plans; n.dispatch.chains = trial.dispatch.chains
	n.dispatch.actions = trial.dispatch.actions
	return applied, nil
end
M.intake = intake
function config.recheck_start_reports(n: any, clock: any)
	for key in n.dispatch.workers do
		local w = n.dispatch.workers[key]
		local held = w.rejected_report
		if not held or held.code ~= "start_claim_pending" or w.frozen then continue end
		local report = codec.decode_report(held.bytes, w)
		local p, s
		if report and report.kind == "PROJECT_START_CLAIM" then p, s = config.find_start(n.dispatch, w, report) end
		if not s or ((not s.published or not s.acknowledged) and not (s.closed and s.closed.retired and config.start_owner_closed(n, p, s))) then continue end
		local owner = coordinator(n, w)
		if not config.start_permanent_failure(n, p, s) and (not owner or owner.phase ~= "running" or w.continuation_required) then continue end
		w.rejected_report = nil
		local applied, problem = intake(n, w, held.bytes, clock)
		if problem then w.rejected_report = held
		elseif applied then w.reason = nil end
	end
end
-- Non-holding diagnostics (transport capacity, uncertainty, re-issue notes) never replace the
-- recorded cause of a worker that is already held.
local function note_reason(w: any, reason: any)
	if w.phase ~= "held" then w.reason = reason end
end
local function reject_read(a: any, w: any, bytes: string, diagnostic: any): (any, nil)
	w.rejected_report = { code = diagnostic.code, message = diagnostic.message, bytes = bytes,
		sha256 = codec.sha256(bytes), action_id = a.request.action_id }
	w.assembly = nil; w.read_selector = nil
	note_reason(w, { code = diagnostic.code, message = diagnostic.message }); a.phase = "complete"
	return { ok = true, code = "report_rejected", report_applied = false, message = diagnostic.message }, nil
end
-- Current refusal consequences live on the worker; completed action copies are not needed.
local function resume_revoked(d: any, w: any)
	if w.phase == "held" and w.accepted_event ~= nil and not w.continuation_required and revoked_authorization(w.reason) then
		w.phase = "accepted"; w.reason = nil
	end
end
-- Reload restores an occupied coordinator owner as `uncertain`; controller continuation alone never
-- reactivates it. After the owner's explicit attested attachment of this exact generation commits
-- and no executor of that owner/generation remains claimed, uncertain or counted, the same
-- generation resumes with its unchanged enrolment and activation (or retirement) evidence. A
-- pending recovery intent, retirement record or restored-pane hold keeps it uncertain.
local function resume_attached_coordinator(n: any, d: any, w: any, owner: any)
	if owner.phase ~= "uncertain" or owner.recovery ~= nil or owner.owner_id ~= w.coordinator_owner_id or owner.generation ~= w.coordinator_generation
		or owner.managed_worker_id ~= w.worker_id or owner.pending_executors ~= 0 or w.coordinator_protocol ~= 1
		or w.continuation_required or w.stopped or w.mailbox_retired or M.unresolved(n, w.logical_session_id, owner.owner_id)
		or restored_coordinator(d, w.logical_session_id) then return end
	owner.phase = if w.retirement or w.release then "retiring" else "running"; owner.owner_active = true
end
-- A retained uncertain read (catalog, mailbox_read) changed nothing: a read mutates no worker,
-- mailbox or ORCH+ state until its correlated outcome commits here, and intake is idempotent
-- through receipts and cursors. Resolving it releases its executor counts and drops any partial
-- selector/reassembly, so the normal poll lane re-reads from the durable cursor. A late outcome
-- for its grant is then stale and refused. Mutating effects never take this path.
local function resolve_read(n: any, a: any, evidence: string, reason: string, status_sha256: string?)
	config.consume_action(n.dispatch, a)
	local session = n.sessions[a.request.origin_binding.logical_session_id]
	local w = if a.worker_id then n.dispatch.workers[a.worker_id] else nil
	config.release_executor(session, w, a)
	if not w then return end
	if a.request.op == "mailbox_read" then w.read_selector = nil; w.assembly = nil end
	note_reason(w, { code = "read_resolved", message = "Retained uncertain read " .. a.request.action_id .. " resolved (" .. evidence .. "); nothing it read was applied, so the worker re-reads from its durable cursor." })
end
local function complete(n: any, a: any, body: any, clock: any, response_bytes: string): (any?, any?)
	local d, payload = n.dispatch, body.payload
	local request = a.request
	local w = if a.worker_id then d.workers[a.worker_id] else nil
	-- A completed effect that leaves the worker's lanes intact: note why, answer ok.
	local function noted(code: string, message: string): (any, nil)
		a.phase = "complete"; note_reason(w, { code = code, message = message })
		return { ok = true, code = code, message = message }, nil
	end
	if body.category ~= "current_result" or body.status == "uncertain" then
		a.phase = "uncertain"
		if w then note_reason(w, body.error or { code = "effect_uncertain", message = "Exact " .. request.op .. " may have executed. Read its retained SPAWN outcome; never repeat the effect or infer closure." }) end
		return result("effect_uncertain"), nil
	end
	if body.status == "failed" and not READ_ONLY_OPS[request.op] then
		a.phase = "uncertain"
		if w then note_reason(w, body.error or { code = "effect_uncertain", message = "A failed native mutation does not prove it had no effect; reconcile the exact retained claim." }) end
		return result("effect_uncertain"), nil
	end
	-- "resolved" completes a configuration declaration; for launch it is only
	-- route resolution. Preserve the latter's existing pending-effect fence.
	if body.status == "resolved" and request.op ~= "declare_provider_families"
		or table.find({ "claimed", "launching", "pending" }, body.status) then return fail("pending", "SPAWN has not completed this operation.") end
	if body.status == "full" or body.status == "incomplete" then
		if w then note_reason(w, body.error or { code = body.status, message = "Transport backpressure; retained work and acceptance are unchanged." }) end
		if body.status == "full" and retryable_full(payload) then
			if request.op == "native_wake" and payload.resource == "native_wake_idle" and w then
				local wake = (w.wakes or {})[request.target_action_id]
				if not wake or wake.action_id ~= request.action_id or wake.target_request_id ~= request.target_request_id then
					return fail("wake_target_mismatch", "Deferred notification differs from its retained publication obligation.")
				end
				-- SPAWN proves it did not send this notification. Retaining a busy wake as
				-- backpressure would block the reports needed to finish the current turn.
				wake.action_id = nil
				-- Do not immediately reserve another wake using the idle observation that
				-- raced this refusal. A later native observation must establish idle again.
				local native = flow(w).native
				if native and native.state == "idle" then flow(w).native = nil end
				return noted("wake_deferred", "The agent became busy before notification. Reports continue; the notification remains due when the agent is idle.")
			end
			a.phase = "backpressure"
			return { ok = true, code = "backpressure", message = "SPAWN refused before effects because capacity is full. Recheck this exact retained operation after capacity clears." }, nil
		end
		if request.op == "mailbox_read" or request.op == "catalog" then
			if w then w.read_selector = nil; w.assembly = nil end
			a.phase = "complete"
			return { ok = true, code = "transport_backpressure", message = "Read transport is " .. body.status .. "; source bytes and worker acceptance are retained. Watermark settlement remains available." }, nil
		end
		a.phase = "uncertain"
		return { ok = true, code = "effect_uncertain", message = "SPAWN reported " .. body.status .. " without proof that no effect started; retain and reconcile this exact operation, never retry blindly." }, nil
	end
	if body.status == "rejected" or body.status == "failed" then
		local problem = body.error or { code = body.status }
		local start = config.start_for_action(d, a)
		if start then
			if body.status ~= "rejected" then
				start.failure = { code = "start_publication_uncertain", message = "Original START delivery failed without proof of nonexecution. Inspect its retained publication; no retry or replacement is authorized.", retryable = false }
				a.phase = "uncertain"
				return result("effect_uncertain", { start_id = start.start_id, message = start.failure.message }), nil
			end
			start.failure = { code = "start_delivery_refused", message = "Original START delivery refused before effects: " .. tostring(problem.code or body.status)
				.. ". Repair its prerequisites, then retry only this original delivery. Work remains held.", retryable = true }
			a.phase = "complete"
			return result("project_start_delivery_failed", { start_id = start.start_id, message = start.failure.message }), nil
		end
		if w and body.status == "rejected" and (request.op == "mailbox_provision" or request.op == "launch" or request.op == "adopt" or request.op == "enrol") then w.launch_refused = true; w.launch_refused_op = request.op end
		if w and request.op == "mailbox_provision" and body.status == "rejected" then w.mailbox_allocation = "possible" end
		if request.op == "accept" and body.status == "rejected" and w and w.accept_pending and revoked_authorization(problem) then
			return noted("accept_reissue", "SPAWN revoked this acceptance's never-consumed authorization during owner recovery or attachment; nothing was accepted. The same acceptance is re-issued on the explicitly continued route.")
		end
		-- Launch, adoption and provisioning have no automatic re-issue lane and keep the explicit hold.
		if body.status == "rejected" and w and revoked_authorization(problem) and table.find({ "native_wake", "mailbox_publish_ack", "mailbox_publish_reply",
			"mailbox_read", "mailbox_retire", "stop", "attach_worker" }, request.op) then
			if request.op == "attach_worker" then
				return noted("reattach_required", "SPAWN revoked this attachment's never-consumed authorization; nothing was attached. The worker still needs explicit reattachment.")
			end
			-- Release this action's lane marker so the same obligation is re-issued on the current route.
			config.release_lanes(w, function(action_id) return action_id == request.action_id end)
			return noted("authorization_reissue", "SPAWN revoked this " .. request.op .. "'s never-consumed authorization during owner recovery or attachment; nothing ran. The same obligation is re-issued on the explicitly continued route.")
		end
		-- A stopped generation's exact producer-unsettled refusal leaves a live retirement
		-- obligation, not a completed action. Consume the grant but retain the refused marker
		-- so polling cannot loop; the sweep or owner explicitly re-arms one attempt.
		if request.op == "mailbox_retire" and request.mode == "retire" and body.status == "rejected" and w and w.stopped
			and w.mailbox_retire_action_id == request.action_id and problem.code == "producer_unsettled" then
			w.retirement_refused = true
			return noted("retirement_refused", "SPAWN refused this stopped generation's mailbox retirement before any effect: its helper journal still holds pending reports or unacknowledged/unresolved control messages. Nothing was retired or retried; the mailbox stays provisioned. The nightly sweep or Retry mailbox retirement once… issues one fresh attempt.")
		end
		if request.op == "mailbox_retire" and request.mode == "retire" and body.status == "rejected" and w
			and w.mailbox_retire_action_id == request.action_id and (w.withdrawn ~= nil or w.launch_refused or w.enrol_cancelling or w.startup_cancelling) then
			-- No mailbox was removed. Preserve the unused-mailbox obligation after consuming
			-- this exact refusal; only a fresh explicit cancellation can issue another grant.
			w.retirement_refused = true
		end
		if w and request.op == "stop" then w.stop_refused = true end
		if w then w.phase = "held"; w.reason = problem end
		a.phase = "complete"
		return { ok = true, code = "bridge_rejected", message = "SPAWN prerequisite/outcome: " .. tostring(problem.code or body.status)
			.. " · " .. tostring(problem.message or problem.detail or "Inspect the selected record and retained operation; no fallback was used.") }, nil
	elseif request.op == "catalog" then
		if body.status ~= "catalog" or not catalog(payload) then return fail("invalid_catalog", "SPAWN returned an incompatible catalog; configure the compatible bridge.") end
		local sid = request.origin_binding.logical_session_id
		local observed, complete_roster = config.observe_catalog(d, sid, request, payload)
		if not observed then return fail("invalid_catalog", "Catalog cursor chain duplicated record identities or exceeded its complete-roster bound; reload the roster from its first page.") end
		local obligations = (d.family_migrations or {})[sid]
		local defaults, defaults_cloned = n.installation_defaults.family_migrations, false
		-- Only the exact fill-only writer receipt proves that a family is saved, not a derived catalog default.
		for _, action in d.actions do
			local response = action.response
			if action.request.op == "declare_provider_families" and action.request.origin_binding.logical_session_id == sid
				and action.phase == "complete" and response and response.status == "resolved"
				and payload.config_revision >= response.payload.config_revision then
				for _, family in response.payload.families do
					for _, row in payload.records do
						if row.id == family.record_id and row.provider_family == family.provider_family then
							if obligations and obligations[row.id] == family.provider_family then obligations[row.id] = nil end
							if defaults and defaults[row.id] == family.provider_family then
								if not defaults_cloned then n.installation_defaults = clone(n.installation_defaults); defaults_cloned = true end
								defaults = n.installation_defaults.family_migrations
								defaults[row.id] = nil
							end
						end
					end
				end
			end
		end
		if complete_roster then config.prune_family_orphans(n, observed); defaults = n.installation_defaults.family_migrations end
		for _, action in d.actions do
			if action.request.op == "declare_provider_families" and action.phase == "complete"
				and (complete_roster or action.request.origin_binding.logical_session_id == sid) then
				local action_obligations = (d.family_migrations or {})[action.request.origin_binding.logical_session_id]
				local remaining = false
				for _, declaration in action.request.declarations do
					if (action_obligations and action_obligations[declaration.record_id] ~= nil)
						or (defaults and defaults[declaration.record_id] ~= nil) then remaining = true end
				end
				if not remaining then action.family_migration_confirmed = true; config.consume_action(d, action) end
			end
		end
	elseif request.op == "declare_provider_families" then
		if body.status ~= "resolved" or not closed(payload, "config_revision applied families") or not (payload.config_revision == 0 or pos(payload.config_revision))
			or payload.config_revision < request.record_revision or not (payload.applied == 0 or pos(payload.applied)) or payload.applied > #request.declarations
			or not dense(payload.families, 32, #request.declarations) or #payload.families ~= #request.declarations then
			return fail("invalid_response", "SPAWN must return the exact canonical saved family for every declaration; refresh its catalog before settling migration obligations.")
		end
		local families = {}
		for _, family in payload.families do
			if not closed(family, "record_id provider_family") or not str(family.record_id, 96) or not config.family(family.provider_family)
				or families[family.record_id] ~= nil then return fail("invalid_response", "SPAWN returned duplicate or invalid canonical families.") end
			families[family.record_id] = family.provider_family
		end
		for _, declaration in request.declarations do
			if families[declaration.record_id] == nil then return fail("invalid_response", "SPAWN did not confirm this exact requested record.") end
		end
		local obligations = (d.family_migrations or {})[request.origin_binding.logical_session_id]
		local defaults_cloned = false
		for _, declaration in request.declarations do
			local family = families[declaration.record_id]
			if obligations and obligations[declaration.record_id] == declaration.provider_family then obligations[declaration.record_id] = family end
			if n.installation_defaults.family_migrations and n.installation_defaults.family_migrations[declaration.record_id] == declaration.provider_family then
				if not defaults_cloned then n.installation_defaults = clone(n.installation_defaults); defaults_cloned = true end
				n.installation_defaults.family_migrations[declaration.record_id] = family
			end
		end
	elseif request.op == "mailbox_provision" then
		if body.status ~= "provisioned" or type(payload) ~= "table" or not id(payload.handle) or not digest(payload.binding_digest) or type(payload.capabilities) ~= "table"
			or not table.find(payload.capabilities, "report-files-v1") or not (table.find(payload.capabilities, "native-ask-v1") or table.find(payload.capabilities, "worker-poll-v1")) then return fail("unsupported_capability", "Provisioning must prove report-files-v1 and a configured native wake or worker polling route before launch.") end
		if w.coordinator_protocol == 1 and not table.find(payload.capabilities, "coordinator-control-v1") then
			return fail("unsupported_capability", "Selected coordinator mailbox did not provision coordinator-control-v1; no launch is authorized.")
		end
		if w.project_start_protocol == 1 and not table.find(payload.capabilities, "project-start-v1") then
			return fail("unsupported_capability", "The fresh coordinator's prepared mailbox must prove project-start-v1 before launch.")
		end
		-- SPAWN names the manifest digest it bound into this provision; it must be exactly the one this
		-- work stored at queue (or rebuilt for a successor), else the helpers would verify another manifest.
		if payload.manifest_sha256 ~= w.manifest_sha256 then
			return fail("manifest_mismatch", "SPAWN provisioned assignment manifest " .. tostring(payload.manifest_sha256) .. " but this work's stored manifest is "
				.. tostring(w.manifest_sha256) .. "; no launch is authorized.")
		end
		w.mailbox_handle = payload.handle; w.capabilities = clone(payload.capabilities); w.binding_digest = payload.binding_digest; w.mailbox_allocation = nil
		w.receipt_chain = codec.receipt_chain(payload.handle); w.compacted_chain = w.receipt_chain
		local launch = launch_request(w, w.mailbox_handle)
		if not add(d, launch, w.worker_id) then return fail("oversize", "Immutable launch request exceeds the bridge bound; no launch was granted.") end
		w.phase = "provisioned"
	elseif request.op == "launch" or request.op == "adopt" or request.op == "enrol" then
		if (body.status ~= "awaiting_acceptance" and body.status ~= "launched" and body.status ~= "accepted") or type(payload) ~= "table" or not pane_binding(payload.pane_binding, w.origin_binding)
			or ((request.op == "adopt" or request.op == "enrol") and not equal(payload.pane_binding, w.adopt_pane_binding)) then return fail("binding_mismatch", "Launch/enrolment lacks its exact origin-scoped native pane outcome.") end
		w.pane_binding = clone(payload.pane_binding); w.phase = "awaiting_acceptance"; w.effective_identity = clone(payload.effective_identity)
		w.prompt_delivery = payload.prompt_delivery
		config.usage_start(d, w, clock)
		if w.coordinator_owner_id then
			local owner = n.sessions[w.logical_session_id].orchestrator
			if owner == nil or owner.owner_id ~= w.coordinator_owner_id or owner.generation ~= w.coordinator_generation or owner.phase ~= "reserved" then return fail("owner_mismatch", "Coordinator reservation changed; retained outcome cannot bind a successor.") end
			-- Window pane aliases are never copied into the host-local pane binding.
			owner.owner_active = true; owner.phase = "running"
		end
	elseif request.op == "attach_worker" then
		if body.status ~= "attached" or not closed(payload, "pane_binding previous_origin_binding previous_pane_binding")
			or not equal(payload.pane_binding, request.pane_binding) or not equal(payload.previous_origin_binding, request.previous_origin_binding)
			or not equal(payload.previous_pane_binding, request.previous_pane_binding) then return fail("attachment_mismatch", "SPAWN must confirm this exact operator-selected attachment without changing launch identity.") end
		w.control_origin = clone(request.origin_binding); w.control_pane = request.controller_pane
		w.control_pane_binding = clone(request.pane_binding); w.continuation_required = false
		local f = flow(w); f.observation_cursor = nil; f.native = nil; f.last_poll = nil; f.empty_read = nil
		resume_revoked(d, w)
		-- The attached route supersedes this generation's retained uncertain reads.
		for _, retained in d.actions do
			if retained.worker_id == w.worker_id and retained.phase == "uncertain" and READ_ONLY_OPS[retained.request.op] then
				resolve_read(n, retained, "read_superseded", "Explicit attested attachment superseded this uncertain read; nothing it read was applied, and the attached route re-reads from the durable cursor.")
			end
		end
	elseif request.op == "mailbox_publish_ack" or request.op == "mailbox_publish_reply" then
		if body.status ~= "published" and body.status ~= "already_published" then return fail("transport_pending", "Mailbox publication has not been confirmed.") end
		local start = config.start_for_action(d, a)
		if start then
			local reply = w.replies[tostring(request.reply_seq)]
			local expected = if reply then (if request.part == "manifest" then reply.frames.manifest else reply.frames.chunks[request.index]) else nil
			if not reply or reply.bytes ~= start.bytes or reply.sha256 ~= request.reply_sha256 or not expected
				or tern.base64.encode(expected) ~= request.object_b64 or codec.sha256(expected) ~= request.object_sha256
				or reply.part ~= (if request.part == "manifest" then #reply.frames.chunks + 1 else request.index) then
				return fail("start_publication_mismatch", "START publication must prove the original complete immutable object in manifest-last order.")
			end
			if request.part == "manifest" then
				start.published = true; start.failure = nil
				start.publication = { request_bytes = a.request_bytes, response_bytes = response_bytes }
			end
		end
		if (request.op == "mailbox_publish_ack" or request.part == "manifest") and type(payload) == "table" and payload.wake_status ~= nil then
			if payload.wake_status == "awaiting_window" and payload.wake_effect_started == false then
				local target_id, target_request = payload.wake_target_action_id, payload.wake_target_request_id
				local current = if id(target_id) then (w.wakes or {})[target_id] else nil
				if not id(target_id) or not id(target_request) or (current and current.target_request_id ~= target_request) then
					return fail("wake_target_mismatch", "Deferred wake conflicts with this worker's current publication obligation.")
				end
				w.wakes = w.wakes or {}
				if not w.wakes[target_id] then
					if count(w.wakes) >= 32 then return fail("full", "Deferred wake obligations are full; retain publication evidence without discarding a notification.") end
					w.wakes[target_id] = { target_request_id = target_request, target_action_id = target_id }
				end
			elseif table.find({ "awaiting_window", "claimed", "launching" }, payload.wake_status) then
				a.phase = "claimed"
				return { ok = true, code = "wake_pending", wake_status = payload.wake_status,
					message = "Mailbox publication is known; its durable native wake grant remains occupied until SPAWN records the wake outcome. Publication is not receipt." }, nil
			elseif payload.wake_status == "uncertain" then
				a.phase = "uncertain"
				return { ok = true, code = "effect_uncertain", message = "Mailbox publication is known; native wake is uncertain. Retain its grant and immutable outbox without repeating ask." }, nil
			elseif payload.wake_status ~= "submitted" then
				return fail("invalid_wake_status", "Unknown SPAWN wake status cannot settle a native effect grant.")
			end
		end
		if request.op == "mailbox_publish_ack" then
			local ack = codec.strict_decode(tern.base64.decode(request.ack_b64), 2048)
			local receipt = w.receipts[tostring(ack.seq)]; if receipt then receipt.publish = false end
		else
			local reply = w.replies[tostring(request.reply_seq)]
			if reply then reply.part += 1 end -- Publication is not worker consumption.
			if request.part == "manifest" then
				local f = flow(w)
				if f.report_request and f.report_request.reply_seq == request.reply_seq then f.report_request.published = true end
				for _, item in (d.landing or {}).items or {} do
					for _, g in item.grants do if g.worker_id == w.worker_id and g.reply_seq == request.reply_seq then g.published = true end end
					if item.refresh and item.refresh.worker_id == w.worker_id and item.refresh.reply_seq == request.reply_seq then item.refresh.published = true end
				end
				for _, dp in d.deploys or {} do
					for _, a in dp.attempts do if a.worker_id == w.worker_id and a.reply_seq == request.reply_seq then a.published = true end end
				end
				for _, g in d.gates or {} do
					if g.worker_id == w.worker_id and g.delivery and g.delivery.reply_seq == request.reply_seq then
						g.delivery.published = true
						if g.phase == "delivery_pending" then g.phase = "delivered" end
						for _, entry in flow(w).thread do if entry.gate_id == g.id and entry.kind:sub(1, 6) == "answer" then entry.kind = "answer_delivered" end end
					end
				end
			end
		end
	elseif request.op == "native_wake" then
		if body.status ~= "submitted" then return fail("wake_pending", "Native notification requires its exact confirmed submission outcome.") end
		local wake = (w.wakes or {})[request.target_action_id]
		if not wake or wake.action_id ~= request.action_id or wake.target_request_id ~= request.target_request_id then
			return fail("wake_target_mismatch", "Native notification outcome differs from its retained publication obligation.")
		end
		w.wakes[request.target_action_id] = nil
	elseif request.op == "accept" then
		if body.status ~= "accepted" then return fail("accept_pending", "SPAWN has not recorded semantic acceptance.") end
		w.accept_pending = false
		if w.reason and w.reason.code == "accept_reissue" then w.reason = nil end
		if w.coordinator_protocol == 1 and not w.activation then
			if not coordinator(n, w) then return fail("owner_mismatch", "Activation belongs only to the exact reserved managed coordinator.") end
			local grant, err = issue_reply(d, w, "coordinator_activation", {
				owner_id = w.coordinator_owner_id, owner_generation = w.coordinator_generation,
				-- Rollover successors bind activation to their exact handover; retired tokens never recur.
				activation_token = codec.sha256(w.enrolment_token .. ":coordinator:" .. w.coordinator_owner_id .. ":" .. tostring(w.coordinator_generation)
					.. (if w.handover_id then ":handover:" .. w.handover_id .. ":" .. w.handover_token else "")),
				instructions = (if w.handover_id then "Verified rollover handover " .. w.handover_id .. ": you succeed a stopped and retired coordinator generation; its activation token and proposals are invalid. " else "")
					.. "Coordinator authority covers only this assignment, not OS/account isolation. Use the issued producer_helper/root/handle/enrolment_token. consume durably records this grant and reply_ack; claim before work. Retain the exact owner_id, owner_generation, activation_token and action_id/action_revision. Never independently orchestrate Tern, start agents or alter accounts. Echo each report_request.request_id once in HEARTBEAT or CHECKPOINT; reply_ack alone is not fulfillment. After activation ACK is accepted, COORDINATOR_PROPOSAL always carries owner_id, owner_generation, activation_token, proposal_id and kind. Existing dispatch/report/review/rollover/landing kinds also require work_id and checkpoint project_id; review/rollover/landing require checkpoint_id; dispatch requires current record_id, record_revision and literal prompt. New passive new_work/add_source variants instead require exactly one of orch_project_id or new_project_name, without work_id/project_id/checkpoint_id. new_work also carries record_id, record_revision, literal prompt, scope {paths,systems}, checks [{check_id,argv}], optional verified repository_id/base_ref and paired target_ref/target_revision. add_source carries source {kind=plan_file|board,path,revision} or {kind=template,template_id,revision,input,custom_fields?}. Derive these from the user's task and observed source; never guess revisions. Both passive variants require owner approval and only add held project work, including during pause. START separately releases that addition after command review. Existing effectful proposals obey pause and checkpoint scope. No proposal is permission for you to perform a native, merge or account action. Only the builder sends LANDING_REQUEST; only the exact eligible merge actor lands (existing builder by default; optional selected release agent). Coordinators never send REVIEW_RESULT or LANDING_RESULT. Retirement/recovery forbids all fresh proposals. Fulfill progress requests and settle owner decisions before release. When finished or retired, quiesce and resolve genuinely completed helper claims; retain uncertainty. Report COORDINATOR_RELEASE with the exact issued action_id/action_revision and payload {owner_id,owner_generation,activation_token,quiescent=true}. A racing retirement is consumed without a second release. Drain final receipts/replies. Native-ask workers return idle for notifications; only worker-poll workers use bounded wait. Unresolved execution blocks retirement. ORCH+/SPAWN alone own exact native stop and mailbox cleanup. DONE, idle and absence are never release." })
			if err then return nil, err end
			w.activation = grant
		end
	elseif request.op == "stop" then
		if body.status ~= "stopped" or not (settled(w) or config.start_retirement_settled(d, w, request.action_id)) or (w.coordinator_owner_id and not coordinator(n, w)) then return fail("stop_pending", "Exact stopped outcome and settled generation are required.") end
		w.stopped = clone(payload); w.reason = nil
		local exited = stamp(clock); exited.state = "exited"; flow(w).exit = exited
	elseif request.op == "mailbox_retire" then
		if request.mode == "retire" then
			-- Failed startup also keeps its real launch/pane; SPAWN separately proves fresh native
			-- exit and an unused producer journal before granting this same retirement outcome.
			local withdrawn = (launch_rejected(d, w) or w.withdrawn ~= nil or w.enrol_cancelling == true or w.startup_cancelling == true) and w.mailbox_retire_action_id == request.action_id
			local revoked = w.start_retirement and w.stopped and config.start_retirement_settled(d, w, request.action_id)
			local tail = if revoked then config.start_retirement_tail(d, w) else nil
			if revoked and not equal(request.withdrawn_starts or {}, tail) then return fail("transport_pending", "The exact withdrawn START tail changed; no floor was advanced.") end
			if body.status ~= "retired" or not (withdrawn or (w.stopped and settled(w)) or revoked) or (w.coordinator_owner_id and not withdrawn and not coordinator(n, w) and not config.cleanup_request(n, w, request)) then
				return fail("transport_pending", "Exact stopped mailbox retirement is not confirmed.")
			end
			w.mailbox_retired = true; w.mailbox_allocation = "none"; w.reason = nil
			if revoked then w.start_retirement.retirement = { request_bytes = a.request_bytes, response_bytes = response_bytes } end
			config.restore_enrol_association(d, w)
			local roster = d.catalogs[w.logical_session_id]
			if (d.catalog_scans or {})[w.logical_session_id] == false and roster and roster.namespace == (n.compatibility or {}).spawn_namespace then config.prune_family_orphans(n, roster) end
		elseif body.status ~= "compacted" and body.status ~= "already_compacted" then return fail("transport_pending", "Mailbox compaction is not confirmed.") end
		if request.report_floor == w.compacted_floor and request.reply_floor == w.reply_floor then w.compaction_pending = nil end
	elseif request.op == "mailbox_read" then
		-- Only an empty read of the very next slot is idle evidence (see poll_idle); any other report
		-- read outcome, including a found report that could not be assembled yet, clears it.
		local f, selector = flow(w), request.selector
		if selector.stream == "report" then f.empty_read = nil end
		if body.status == "missing" or body.status == "gap" or body.status == "compacted" then
			w.read_selector = nil
			-- A pending read blocks this generation's polls, so last_poll is the poll that issued it.
			local issued = f.last_poll
			if body.status == "missing" and selector.stream == "report" and selector.part == "manifest" and selector.slot == w.accepted_seq + 1
				and issued and id(issued.epoch) then
				f.empty_read = { at_ms = issued.at_ms, mono_ms = issued.mono_ms, epoch = issued.epoch, slot = selector.slot }
			end
		else
			local page, err = codec.decode_page(tern.json.encode(payload), request.selector); if err then return nil, err end
			if request.selector.stream == "watermark" then
				local watermark, problem = codec.decode_watermark(page.bytes, w); if problem then return nil, problem end
				if watermark.through_seq > w.accepted_seq then return fail("binding_mismatch", "Watermark exceeds committed receipts.") end
				if watermark.through_seq == w.compacted_floor and watermark.receipt_chain_sha256 ~= w.compacted_chain then return fail("binding_mismatch", "Repeated watermark changed its confirmed chain.") end
				if watermark.through_seq > w.compacted_floor then
					local receipt = w.receipts[tostring(watermark.through_seq)]
					if receipt == nil or receipt.chain ~= watermark.receipt_chain_sha256 then return fail("binding_mismatch", "Watermark chain differs from retained receipts.") end
					w.compacted_floor = watermark.through_seq; w.compacted_chain = watermark.receipt_chain_sha256
					w.compaction_pending = n.revision
					for seq in w.receipts do if tonumber(seq) <= w.compacted_floor then w.receipts[seq] = nil end end
				end
			elseif page.object.type == "manifest" then
				local active = 0
				for _, worker in d.workers do if worker.assembly then active += 1 end end
				if active >= codec.LIMITS.assemblies and not w.assembly then
					a.phase = "complete"; w.read_selector = nil
					local message = "Host reassembly slots are full; immutable source remains unacknowledged and watermark settlement is available."
					note_reason(w, { code = "full", message = message })
					return { ok = true, code = "intake_backpressure", report_applied = false, message = message }, nil
				end
				local binding = report_binding(w)
				if w.assembly then
					if w.assembly.manifest_bytes ~= page.bytes or w.assembly.manifest_sha256 ~= page.sha256
						or not equal(w.assembly.binding, binding) then return fail("content_conflict", "A different manifest cannot replace the retained report prefix.") end
				else
					local assembly, problem = codec.assembly_start(page.bytes, page.sha256, binding)
					if problem then return nil, problem end
					w.assembly = assembly
				end
				w.read_selector = { stream = "report", slot = page.object.slot, part = "chunk", index = w.assembly.next_index }
			else
				if not w.assembly then return fail("incomplete", "No retained manifest for this chunk.") end
				local total = 0
				for _, worker in d.workers do if worker.assembly then total += worker.assembly.bytes end end
				local added = if page.object.index == w.assembly.next_index then math.min(codec.LIMITS.slice,
					w.assembly.manifest.message_bytes - w.assembly.bytes) else 0
				if total + added > codec.LIMITS.reassembly_bytes then
					a.phase = "complete"; w.assembly = nil; w.read_selector = nil
					local message = "Host reassembly bytes are full; immutable source remains unacknowledged and watermark settlement is available."
					note_reason(w, { code = "full", message = message })
					return { ok = true, code = "intake_backpressure", report_applied = false, message = message }, nil
				end
				local assembled, problem = codec.assembly_push(w.assembly, page.bytes, page.sha256, report_binding(w))
				if problem then
					if problem.completed_bytes then return reject_read(a, w, problem.completed_bytes, problem) end
					return nil, problem
				end
				if assembled.complete then
					local applied, semantic = intake(n, w, assembled.bytes, clock)
					if semantic and semantic.code == "full" then
						-- The bounded read completed, but semantic intake did not. Leave the
						-- immutable source unacknowledged and free the independent watermark lane.
						w.assembly = nil; w.read_selector = nil; note_reason(w, clone(semantic)); a.phase = "complete"
						return { ok = true, code = "intake_backpressure", report_applied = false, message = semantic.message }, nil
					end
					if semantic then
						-- Transport completed even though its immutable report was rejected.
						-- Keep exact evidence, not an ACK or an advanced acceptance cursor.
						return reject_read(a, w, assembled.bytes, semantic)
					end
					if not applied then return fail("semantic_handler_required", "Report was not applied.") end
					w.assembly = nil; w.read_selector = nil
				else w.read_selector = { stream = "report", slot = page.object.slot, part = "chunk", index = w.assembly.next_index } end
			end
		end
	end
	a.phase = "complete"
	return result("bridge_committed"), nil
end
-- Stale claims (D11). Aging runs only on live ticks: a claim without a stamp from this host
-- incarnation (restored, or written before claimed_at existed) is rebased first, so aging restarts
-- after a host restart. Once stale_claim_min minutes (0 = off) pass, exactly one stale_claim gate
-- opens per claim. ORCH+ never takes over, re-sends or settles a claim because of its age.
-- A backpressured action is SPAWN's definitive pre-effect refusal, not a stuck claim: it never
-- ages and its open gate is superseded. Its capacity recheck re-claims the same exact request under
-- a fresh grant; that claim inherits the action's stale_gate_id (see retry), so automatic rechecks
-- never raise a second gate for one action.
local claims: any = {}
function claims.aging(d: any, a: any, clock: any): string?
	if (a.phase ~= "claimed" and a.phase ~= "uncertain") or type(a.claim) ~= "table" then return nil end
	local at = a.claim.claimed_at
	if not at or at.epoch == nil or at.epoch ~= clock.epoch then return "rebase" end
	local minutes = policy(d, a.request.origin_binding.logical_session_id).stale_claim_min
	local age = elapsed(at, clock)
	if a.claim.stale_gate_id == nil and a.worker_id and d.workers[a.worker_id] and minutes > 0 and age ~= nil and age >= math.floor(minutes * 60 + 0.5) * 1000 then return "stale" end
	return nil
end
-- An open stale_claim gate whose claim settled, was re-granted or vanished no longer asks anything.
function claims.obsolete(d: any, g: any): boolean
	if g.kind ~= "stale_claim" or not gate_open(g) then return false end
	local a = d.actions[tostring(g.evidence[1] or ""):match("^action:(.+)$") or ""]
	return not a or (a.phase ~= "claimed" and a.phase ~= "uncertain") or type(a.claim) ~= "table" or a.claim.stale_gate_id ~= g.id
end
function claims.due(d: any, clock: any): boolean
	for _, a in d.actions do if claims.aging(d, a, clock) then return true end end
	for _, g in d.gates or {} do if claims.obsolete(d, g) then return true end end
	return false
end
function claims.age(d: any, clock: any)
	for _, g in d.gates or {} do
		if claims.obsolete(d, g) then
			g.phase = "superseded"; g.revision += 1
			local w = d.workers[g.worker_id]
			if w then settle_entries(w, "gate_id", g.id) end
		end
	end
	for _, key in config.sorted_keys(d.actions, function(_, a) return claims.aging(d, a, clock) end) do
		local a = d.actions[key]
		local due = claims.aging(d, a, clock)
		if due == "rebase" then
			a.claim.claimed_at = stamp(clock)
		elseif due == "stale" and not clock.reserved_capacity then
			local minutes = math.floor((elapsed(a.claim.claimed_at, clock) or 0) / 60000)
			-- Full gate capacity or a full thread defers the gate to a later tick; nothing else changes.
			local g = new_gate(d, d.workers[a.worker_id], "stale_claim", "Action " .. key .. " has been claimed for " .. tostring(minutes)
				.. " minutes without a result. ORCH+ never takes over a claim; open the recovery guide to reconcile it by hand.",
				{ { id = "keep_waiting", label = "Keep waiting" }, { id = "open_recovery", label = "Open recovery guide" } },
				{ "action:" .. key, "op:" .. a.request.op, "claimed_minutes:" .. tostring(minutes) }, clock)
			if g then a.claim.stale_gate_id = g.id end
		end
	end
end
function M.tick(registry: any, event: any, clock: any): (any?, any)
	if not closed(event, "kind authority_namespace expected_revision") or event.kind ~= "workflow_tick" or event.authority_namespace ~= registry.authority_namespace
		or event.expected_revision ~= registry.revision or type(clock) ~= "table" or not valid_stamp(stamp(clock))
		or not id(clock.epoch) or type(clock.mono_ms) ~= "number" or clock.mono_ms < 0 or clock.mono_ms > MAX then
		return fail("invalid_clock", "Workflow ticks require the host's current monotonic incarnation and audit clock.")
	end
	if not registry.dispatch then return nil, result("no_progress") end
	-- Probe on shallow copies first: refresh writes only a worker's top-level workflow fields and
	-- reads no other worker, so an idle tick clones no registry subtree. Due work then takes the
	-- original full candidate path, committing exactly the same outcome.
	-- Claim aging is probed read-only first as well (claims.due mutates nothing).
	local due = claims.due(registry.dispatch, clock)
	-- A reviewer whose result and settlement completed finishes on the next commit or tick (read-only probe).
	for _, w in registry.dispatch.workers do if not due and config.finishable(registry.dispatch, w) then due = true end end
	for _, w in registry.dispatch.workers do
		if due then break end
		local probe = table.clone(w)
		if w.workflow then probe.workflow = table.clone(w.workflow) end
		refresh(registry.dispatch, probe, clock)
		if not equal(probe.workflow, w.workflow) then due = true; break end
	end
	if not due then return nil, result("no_progress") end
	local n = candidate(registry)
	claims.age(n.dispatch, clock) -- Before refresh, so a new stale_claim gate is reflected in worker health.
	for _, w in n.dispatch.workers do config.auto_finish(n, w, clock) end
	for _, w in n.dispatch.workers do refresh(n.dispatch, w, clock) end
	if equal(n.dispatch, registry.dispatch) then return nil, result("no_progress") end
	if registry.revision == MAX then return fail("full", "Authority revision exhausted.") end
	return n, result("workflow_updated")
end
local function fence_unexecuted(d: any, event: any, revision: number, worker_id: string?)
	for _, action in d.actions do
		local old_route = (not worker_id or action.worker_id == worker_id) and action.request.origin_binding.logical_session_id == event.orch_session_id
			and action.request.origin_binding.owner_id == event.origin.owner_id and not equal(action.request.origin_binding, event.origin)
		-- A window-only restart keeps the host alive, so restore never marked the superseded
		-- executor's claims uncertain. The operator attested that executor stopped: its claim is
		-- exactly as uncertain as after a host restart, never resolved or repeated.
		if old_route and action.phase == "claimed" and action.claim and action.claim.executor ~= event.origin.window_epoch then
			action.phase = "uncertain"
		elseif old_route and action.phase == "ready" then
			action.phase = "held_ready"
		end
	end
end
-- Candidate for withdrawal, not proof of continuation fencing or nonexecution.
-- Uncertain requests still require a current exact pre-effect refusal from SPAWN.
-- A local ready intention without immutable request bytes or a grant was never issued.
function config.generation_target(w: any): any?
	if not id(w.logical_session_id) or not id(w.worker_id) or not pos(w.worker_generation)
		or not id(w.launch_request_id) or not id(w.work_id) or not str(w.enrolment_token, 128) then return nil end
	return { logical_session_id = w.logical_session_id, worker_id = w.worker_id, worker_generation = w.worker_generation,
		launch_request_id = w.launch_request_id, work_id = w.work_id, enrolment_sha256 = codec.sha256(w.enrolment_token) }
end
function config.allocation_target(d: any, w: any): any?
	if w.mailbox_handle or w.mailbox_retired or w.mailbox_allocation == "none" then return nil end
	local unknown = w.mailbox_allocation == "possible" or w.launch_refused == true
	if not unknown then for _, a in d.actions do
		if a.worker_id == w.worker_id and a.request.op == "mailbox_provision" and (a.request_bytes ~= nil or a.claim ~= nil) then unknown = true; break end
	end end
	return if unknown then config.generation_target(w) else nil
end
function config.observe_allocation(n: any, w: any, event: any): (any?, boolean)
	local target = config.generation_target(w)
	if not target then return config.refusal("allocation_identity_missing", "The complete retained generation tuple is unavailable; keep this allocation held for exact journal reconciliation."), false end
	local query = codec.decode_dispatch_request(event.query_bytes)
	local session = n.sessions[w.logical_session_id]
	if not query or query.op ~= "mailbox_allocation" or query.authority_namespace ~= n.authority_namespace
		or query.logical_session_id ~= w.logical_session_id or not session or session.admitted ~= true or query.admission_seq ~= session.admission_seq
		or not equal(query.origin_binding, event.origin) or query.controller_pane ~= event.controller_pane
		or query.controller_generation ~= event.origin.owner_generation or not equal(query.target, target) then
		return config.refusal("binding_mismatch", "Observe this exact generation through its current admitted controller; no allocation was changed."), false
	end
	local body, problem = protocol.decode_response(event.response_bytes, query)
	if problem then return problem, false end
	if body.spawn_namespace ~= (n.compatibility or {}).spawn_namespace then
		return config.refusal("stale_authority", "The allocation observation does not belong to this current paired SPAWN authority."), false
	end
	if body.category ~= "current_result" or body.status ~= "allocation" or not equal(body.payload.target, target) then
		return config.refusal("allocation_unconfirmed", (body.error or {}).message or "The exact allocation remains unknown or pending; re-observe without replaying startup."), false
	end
	local allocation = body.payload.allocation
	if allocation.state == "none" then
		local changed = w.mailbox_allocation ~= "none" or (w.mailbox_handle ~= nil and w.mailbox_retired ~= true)
		w.mailbox_allocation = "none"
		if w.mailbox_handle then w.mailbox_retired = true end
		return nil, changed
	end
	local provision = allocation.provision
	if w.mailbox_retired or provision.manifest_sha256 ~= w.manifest_sha256
		or (w.mailbox_handle ~= nil and (w.mailbox_handle ~= provision.handle or w.binding_digest ~= provision.binding_digest
			or not equal(w.capabilities, provision.capabilities))) then
		return config.refusal("binding_mismatch", "The retained allocation conflicts with this generation's existing handle, manifest, capabilities or positive retirement; no launch or cancellation was inferred."), false
	end
	if w.mailbox_handle then return nil, false end
	if w.accepted_event or w.accepted_seq ~= 0 or w.compacted_floor ~= 0 or w.reply_seq ~= 0 or w.reply_floor ~= 0 then
		return config.refusal("allocation_unconfirmed", "Provision metadata cannot reconstruct missing report/receipt history; retain the original execution evidence."), false
	end
	w.mailbox_handle = provision.handle; w.binding_digest = provision.binding_digest; w.capabilities = clone(provision.capabilities)
	w.receipt_chain = codec.receipt_chain(provision.handle); w.compacted_chain = w.receipt_chain; w.mailbox_allocation = nil
	-- This is metadata, not a successful provision/launch result. Preserve phase, refusal and every existing action.
	return nil, true
end
local function withdrawal_candidate(d: any, w: any): (string?, any?)
	if w.pane_binding or w.control_origin or w.accepted_event or w.handover_id or w.stopped or w.mailbox_retired or w.withdrawn
		or (w.phase ~= "queued" and w.phase ~= "provisioned" and w.phase ~= "held") then return nil, nil end
	local key, selected
	for k, a in d.actions do
		if a.worker_id ~= w.worker_id then continue end
		if selected or not (a.request.op == "mailbox_provision" or a.request.op == "launch" or a.request.op == "adopt" or a.request.op == "enrol")
			or not (((a.phase == "ready" or a.phase == "held_ready") and a.request_bytes == nil and a.claim == nil) or a.phase == "backpressure" or a.phase == "uncertain") then return nil, nil end
		key, selected = k, a
	end
	return key, selected
end
local function status_required(a: any): boolean return a.phase == "uncertain" end
-- C1: `mailbox_retire` is nil only when no mailbox exists; otherwise `not_requested` before the
-- first cancel, then `retiring`, then `refused` after SPAWN's definite rejection (cancel again).
-- Once the cancel recorded `w.withdrawn`, its status evidence was consumed: no further read.
local function withdrawal_view(n: any, d: any, w: any): any?
	local key, a = withdrawal_candidate(d, w)
	local allocation_target = config.allocation_target(d, w)
	local failed_startup = config.failed_startup(n, w) and w.restored == nil
	local retiring = (w.withdrawn ~= nil or w.launch_refused or w.enrol_cancelling or failed_startup or (w.enrol_delivery and w.phase == "awaiting_acceptance")) and not w.mailbox_retired
	if not a and not retiring then return nil end
	local retire = if w.mailbox_handle then (if w.mailbox_retire_action_id then "retiring" elseif w.retirement_refused then "refused" else "not_requested") else nil
	return { action_id = if a then key elseif w.withdrawn then w.withdrawn.action_id elseif w.mailbox_handle then w.launch_action_id else nil,
		op = if a then a.request.op elseif w.withdrawn then w.withdrawn.op elseif w.launch_refused then (w.launch_refused_op or "startup") elseif not w.mailbox_handle then "startup"
			else (if w.enrol_delivery then "enrol" elseif w.adopt_pane_binding then "adopt" else "launch"),
		evidence = if failed_startup then "failed_startup" elseif w.withdrawn then w.withdrawn.evidence elseif a then (if status_required(a) then "unconfirmed"
			elseif a.request_bytes then "pre_effect_refusal" else "unissued") elseif w.enrol_delivery then "enrolment_revocation_required" else "spawn_rejected",
		allocation_target = allocation_target,
		pending_startup = a ~= nil and a.phase == "ready" and a.request_bytes == nil,
		status_required = (a ~= nil and status_required(a)) or allocation_target ~= nil,
		request_id = if a then a.request.request_id elseif w.mailbox_handle then w.launch_request_id else nil,
		origin_binding = clone(if a then a.request.origin_binding else w.origin_binding), controller_generation = w.origin_binding.owner_generation,
		mailbox_retire = retire, mailbox_provisioned = w.mailbox_handle ~= nil }
end
-- Missing/consumed peer state is not evidence of nonexecution. Only an exact current pre-effect refusal qualifies.
local function unexecutable_in_spawn(n: any, a: any, event: any): any?
	local refuse = config.refusal
	local query = codec.decode_dispatch_request(event.query_bytes)
	if not query or query.op ~= "status" or query.target_request_id ~= a.request.request_id
		or query.target_request_serial ~= a.request.request_serial or query.authority_namespace ~= a.request.authority_namespace
		or query.admission_seq ~= a.request.admission_seq or not equal(query.origin_binding, event.origin) then
		return refuse("binding_mismatch", "SPAWN status evidence must name this exact fenced request; nothing was cancelled.")
	end
	local body, err = protocol.decode_response(event.response_bytes, query); if err then return err end
	if body.spawn_namespace ~= (n.compatibility or {}).spawn_namespace then
		return refuse("stale_authority", "The observed refusal belongs to another SPAWN namespace; nothing was cancelled.")
	end
	if body.category ~= "current_result" or body.status ~= "found" then return refuse("unknown_effect", "Missing or reclaimed peer evidence cannot prove this mutation never executed.") end
	local outcome = body.payload.outcome
	if outcome.op ~= a.request.op or outcome.action_id ~= a.request.action_id then return refuse("binding_mismatch", "Retained outcome names another action.") end
	if outcome.status == "rejected" or (outcome.status == "full" and retryable_full(outcome.payload)) then
		local worker = n.dispatch.workers[a.worker_id]
		if a.request.op == "mailbox_provision" and (not worker or (not worker.mailbox_handle and worker.mailbox_allocation ~= "none")) then
			return refuse("allocation_required", "A terminal provision refusal does not prove its allocation absent. Observe this exact generation before cancellation.")
		end
		if worker and outcome.status == "rejected" then worker.launch_refused = true; worker.launch_refused_op = outcome.op; worker.phase = "held" end
		return nil
	end
	if outcome.status == "pending" and closed(outcome.payload, "authorization_required") and outcome.payload.authorization_required == true then
		return refuse("authorization_live", "SPAWN still holds a live window challenge for this request. It expires within 30 s; cancel again after that. Nothing was cancelled.")
	end
	return refuse("spawn_outcome_open", "SPAWN's retained outcome for this request is " .. tostring(outcome.status):sub(1, 96)
		.. ", not definitively unexecuted; nothing was cancelled. Inspect it in SPAWN: Running agents.")
end
function config.session_effects_pending(d: any, logical_session_id: string): boolean
	for _, action in d.actions do
		if action.request.origin_binding.logical_session_id == logical_session_id
			and action.phase ~= "complete" and action.phase ~= "resolved" and action.phase ~= "held_ready" then
			return true
		end
	end
	return false
end
local function continuation_proof(registry: any, w: any): string
	-- Fixed field order and length framing avoid JSON map-order or delimiter ambiguity.
	-- Bind worker authority/effects and session quiescence, not another worker's health tick.
	local parts = {}
	local function include(record: any, keys: string)
		for key in keys:gmatch("%S+") do
			local value = tostring(if record then record[key] else nil)
			table.insert(parts, tostring(#value) .. ":" .. value)
		end
	end
	local origin_keys = "logical_session_id owner_id owner_generation host_pane_id alias_nonce window_key window_epoch native_session_id window_host_id"
	include(registry, "execution_epoch")
	include(w, "worker_id work_id worker_generation launch_request_id launch_action_id enrolment_token mailbox_handle phase accepted_seq compacted_floor reply_seq reply_floor stop_action_id mailbox_retire_action_id mailbox_retired continuation_required")
	include(w.origin_binding, origin_keys); include(control_origin(w), origin_keys)
	include(w.pane_binding, "pane_id window_epoch window_key native_session_id window_host_id")
	include(control_binding(w), "pane_id window_epoch window_key native_session_id window_host_id")
	include(w.finish, "request_id seq revision"); include(w.release, "seq event_sha256 action_id action_revision")
	local session = registry.sessions[w.logical_session_id]
	for _, owner in { session.controller or {}, session.orchestrator or {} } do
		include(owner, "owner_id generation phase owner_active pending_executor_evidence")
		include(owner.last_observation, "status evidence execution_epoch")
	end
	local cursor = (registry.dispatch.command_cursors or {})[w.logical_session_id]
	include(if cursor then cursor.origin else nil, origin_keys)
	include(cursor, "controller_pane continued_epoch")
	table.insert(parts, if config.session_effects_pending(registry.dispatch, w.logical_session_id) then "1:1" else "1:0")
	for _, key in config.sorted_keys(registry.dispatch.actions, function(key, action) return action.worker_id == w.worker_id and (action.phase ~= "complete" or (w.wakes or {})[key]) end) do
		local action = registry.dispatch.actions[key]
		include(action, "request_bytes phase response_bytes response_grant")
		include(action.claim, "executor epoch grant_id"); include(action.resolution, "revision executor evidence")
	end
	for _, key in config.sorted_keys(registry.dispatch.gates or {}, function(_, gate) return gate.worker_id == w.worker_id and (gate_open(gate) or gate.proposal or (gate.delivery and not gate.delivery.acknowledged)) end) do
		local gate = registry.dispatch.gates[key]
		include(gate, "id revision phase delivery_uncertain")
		include(gate.delivery, "action_id action_revision reply_seq acknowledged")
	end
	-- Granted/uncertain landing slots held by this worker (Contract I holder) and its live or uncertain
	-- deploy attempts are retained effects of its route.
	for _, key in config.sorted_keys((registry.dispatch.landing or {}).items or {}, function(_, item) return item.holder and item.holder.worker_id == w.worker_id and (item.status == "granted" or item.status == "landing") end) do
		local item = registry.dispatch.landing.items[key]; local grant = item.grants[#item.grants]
		include(item, "id status"); include(grant, "grant_id action_id acknowledged")
		include(grant.uncertain, "code")
	end
	for _, key in config.sorted_keys(registry.dispatch.deploys or {}, function(_, dp) return dp.attempts[#dp.attempts] and dp.attempts[#dp.attempts].worker_id == w.worker_id and not config.DEPLOY_DONE[dp.status] end) do
		local dp = registry.dispatch.deploys[key]; local a = dp.attempts[#dp.attempts]
		include(dp, "deploy_id status"); include(a, "attempt_id action_id acknowledged status")
	end
	return codec.sha256(table.concat(parts))
end
M.continuation_proof = continuation_proof
-- A sequenced window observation that repeats the persisted native evidence of the same host
-- incarnation commits nothing while that evidence is still well inside its staleness window:
-- the host stamp is refreshed (committed) at least every stale_ms/4, so native freshness keeps
-- its meaning. Anything an observation can change — state or delivery error, a wake it would
-- defer (busy/erroring evidence), a recheckable native-input gate, exit or restored-coordinator
-- evidence — still commits. Idle evidence without a delivery error never touches wakes.
-- Valid only after the stale_command and observation_cursor checks; reads, never mutates.
local function observation_unchanged(registry: any, d: any, w: any, event: any, clock: any): boolean
	local f = w.workflow
	local last = if f then f.native else nil
	if last == nil or w.pane_binding == nil or not equal(control_origin(w), event.origin) or not equal(control_binding(w), event.pane_binding)
		or last.state ~= event.native_state or last.delivery_error ~= event.delivery_error
		or (next(w.wakes or {}) ~= nil and (event.native_state ~= "idle" or event.delivery_error ~= nil))
		or retired_coordinator(registry, w) or (w.restored and not w.restored.reconciled)
		or (event.native_state == "exited" and not f.exit) then return false end
	for _, g in d.gates or {} do
		if g.worker_id == w.worker_id and g.kind == "native_input" and gate_open(g) and g.recheck then return false end
	end
	local age = elapsed(last, clock)
	return age ~= nil and age < policy(d, w.logical_session_id).stale_ms / 4
end
-- A poll for an idle generation commits nothing when the only effect it would grant is a read
-- that cannot find anything (the bench's idle churn: poll, claim and result commits per worker
-- every poll_ms, plus the tick's due_poll edge). It applies only when no other poll effect is due
-- (outbound publication, acceptance, compaction, an answered decision, a wake, stop/retirement,
-- a requested report, an active rollover, a partial assembly or a held report) and when:
-- - the last report read of the very next slot found nothing (`empty_read`), and its poll came
--   after the persisted native evidence, which is still idle, error-free, of this host incarnation
--   and younger than stale_ms/4. An idle native agent writes no report, and observe commits every
--   state change, so a working edge since that read re-stamps f.native after it and the next poll
--   reads again. Unchanged idle evidence is re-stamped every stale_ms/4 (observation_unchanged),
--   so an unobserved working blip delays its report by at most about stale_ms/4 + poll_ms;
-- - a watermark poll additionally finds every committed receipt already compacted, so a
--   worker-confirmed prefix cannot advance anything.
-- last_poll is not stamped, so due_poll stays set and the window keeps its poll_ms cadence; report
-- requests (due_report), wakes and staleness use their own evidence and are unchanged. The
-- command_seq barrier is not advanced: the window's next sequence is still strictly greater, and
-- an exact replay re-evaluates this same read-only rule. Reads, never mutates.
-- Polling workers can publish through their helper while the terminal still looks idle.
-- Native idle evidence cannot suppress their configured report discovery.
local function poll_idle(registry: any, d: any, w: any, event: any, clock: any): boolean
	local f = if w then w.workflow else nil
	if not f or w.phase ~= "accepted" or not equal(control_origin(w), event.origin) or not w.mailbox_handle or not w.pane_binding
		or table.find(w.capabilities or {}, "worker-poll-v1") ~= nil
		or w.continuation_required or w.mailbox_retired or w.rejected_report or w.assembly or w.read_selector or w.finish or w.release
		or w.retirement or w.stop_action_id or w.mailbox_retire_action_id or w.restored or next(w.wakes or {}) ~= nil
		or f.report_request ~= nil or active_rollover(d, w) or outbound_due(d, w, false) or pending(d, w)
		or (w.coordinator_owner_id and not coordinator(registry, w)) then return false end
	if event.bytes ~= nil and (event.bytes ~= "watermark" or w.compacted_floor ~= w.accepted_seq) then return false end
	local native, read = f.native, f.empty_read
	if not native or native.state ~= "idle" or native.delivery_error ~= nil or not read or read.slot ~= w.accepted_seq + 1
		or read.epoch ~= native.epoch or read.mono_ms < native.mono_ms then return false end
	local age = elapsed(native, clock)
	return age ~= nil and age < policy(d, w.logical_session_id).stale_ms / 4
end
function config.project_finish_problem(d: any, p: any): string?
	if p.start and not p.start.claim and (not p.start.closed or not p.start.published
		or not (p.start.closed.retired or (p.start.acknowledged and p.start.closed.report_bytes)) or config.start_in_flight(d, p.start)) then
		return "The original START delivery or claim is still unsettled; finishing cannot discard it."
	end
	for _, prior in p.start_history or {} do
		if not prior.closed or not prior.published or not (prior.closed.retired or (prior.acknowledged and prior.closed.report_bytes))
			or config.start_in_flight(d, prior) then return "An earlier START claim is still unsettled; finishing cannot discard its exact correlation." end
	end
	for _, w in d.workers do if w.orch_project_id == p.orch_project_id then
		if (w.open_conversation or w.enrol_delivery) and not w.accepted_event and not w.mailbox_retired then return "Enrollment is still awaiting acceptance or capability revocation; settle it before finishing the project." end
		local conversation_only = (w.role == "release_manager" and w.accepted_event ~= nil) or w.open_conversation or w.enrol_delivery
		if pending(d, w) or not (if w.mailbox_retired or conversation_only then deliveries_settled(w) else settled(w)) or work_referenced(d, w) then return "This project still has a managed effect, delivery or decision to settle." end
		if not w.mailbox_retired and not conversation_only then
			return "A managed task is unfinished. Finish or cancel that task first; Finish project does not stop its conversation."
		end
	end end
	for _, plan in d.plans or {} do if plan.orch_project_id == p.orch_project_id and plan.status == "active" then return "The imported plan still has unfinished tasks." end end
	for _, rec in d.intakes or {} do if rec.orch_project_id == p.orch_project_id and rec.state ~= "refused" and rec.lane ~= "done" then return "A source intake is unfinished." end end
	for _, c in d.chains or {} do if c.orch_project_id == p.orch_project_id and c.status ~= "done" and c.status ~= "stopped" then return "A template chain is unfinished." end end
	return nil
end
function config.summarize_project(n: any, p: any, text: string, now: number)
	local d, links = n.dispatch, {}
	for _, conversation in p.associations or {} do if conversation.active and #links < 8 then
		local b = conversation.pane_binding
		table.insert(links, { kind = "conversation", ref = tern.json.encode({ pane_id = b.pane_id, window_key = b.window_key,
			native_session_id = b.native_session_id, window_host_id = b.window_host_id }), label = conversation.provider or "Conversation" })
	end end
	for _, key in config.sorted_keys(d.workers, function(_, w) return w.orch_project_id == p.orch_project_id end) do
		local w = d.workers[key]
		local binding = control_binding(w)
		if binding and not w.mailbox_retired and not w.stopped and not (w.workflow and w.workflow.exit) and #links < 8 then
			table.insert(links, { kind = "conversation", ref = tern.json.encode({ pane_id = binding.pane_id, window_key = binding.window_key,
				native_session_id = binding.native_session_id, window_host_id = binding.window_host_id }), label = w.record_id })
		end
	end
	local summary = { name = p.name, source = clone(p.sources[1]), result = text, links = links, finished_at_ms = now }
	while #tern.json.encode(summary) > 4096 and #links > 0 do table.remove(links) end
	d.finished_projects = d.finished_projects or {}
	table.insert(d.finished_projects, summary)
	p.finished = true; p.associations = {}; p.start = nil; p.start_history = nil; p.revision += 1
	M.trim_summaries(n)
end
function config.start_unissued(d: any, w: any, event: any): (boolean, any?)
	if not w.project_held or w.phase ~= "queued" or w.launch_refused or w.routing or w.launch_gates or w.checks_pending
		or w.mailbox_handle or w.pane_binding or w.accepted_event or w.coordinator_owner_id then return false, nil end
	local action
	for _, candidate in d.actions do if candidate.worker_id == w.worker_id then
		if action or candidate.request.op ~= "mailbox_provision" or candidate.request_bytes ~= nil or candidate.claim ~= nil
			or (candidate.phase ~= "held_ready" and candidate.phase ~= "ready") then return false end
		action = candidate
	end end
	local current
	for _, row in (d.catalogs[w.logical_session_id] or {}).records or {} do if row.id == w.record_id and row.revision == w.record_revision then current = row end end
	if not current or not current.eligible or not current.enabled or current.cwd ~= w.cwd or current.placement ~= w.placement then return false end
	local changed = w.continuation_required == true or not equal(w.origin_binding, event.origin) or w.controller_pane ~= event.controller_pane
		or (action ~= nil and action.phase == "held_ready")
	if not changed then return false end
	w.origin_binding = clone(event.origin); w.controller_pane = event.controller_pane
	w.continuation_required = nil; w.restored = nil
	if action then
		action.request.origin_binding = clone(event.origin); action.request.controller_pane = event.controller_pane
		action.request.controller_generation = event.origin.owner_generation; action.phase = "ready"; w.project_held = nil
	end
	config.bind_family(d, w)
	return true, action
end
function config.complete_projects(n: any, sid: string, now: number)
	local d = n.dispatch
	for _, p in d.projects or {} do if p.logical_session_id == sid and p.started and not p.finished then
		local outcomes, failed = 0, 0
		for _, plan in d.plans or {} do if plan.orch_project_id == p.orch_project_id and plan.status ~= "superseded" then
			for _, cp in plan.checkpoints do for _, task in cp.tasks do
				if task.state == "done" then outcomes += 1 elseif task.state == "failed" then outcomes += 1; failed += 1 end
			end end
		end end
		for _, rec in d.intakes or {} do if rec.orch_project_id == p.orch_project_id and (rec.state == "refused" or rec.lane == "done") then
			outcomes += 1; if rec.state == "refused" then failed += 1 end
		end end
		for _, c in d.chains or {} do if c.orch_project_id == p.orch_project_id and (c.status == "done" or c.status == "stopped") then
			outcomes += 1; if c.status == "stopped" then failed += 1 end
		end end
		for _, w in d.workers do if w.orch_project_id == p.orch_project_id and w.role == "builder" and not w.open_conversation and not w.enrol_delivery
			and (w.mailbox_retired or w.finish) then outcomes += 1 end end
		local conversation_open = next(p.associations or {}) ~= nil
		for _, w in d.workers do
			if w.orch_project_id == p.orch_project_id and (w.open_conversation or w.enrol_delivery)
				and not w.mailbox_retired and not w.stopped and not (w.workflow and w.workflow.exit) then conversation_open = true; break end
		end
		if outcomes > 0 and not conversation_open and not config.project_finish_problem(d, p) then
			config.summarize_project(n, p, if failed > 0 then "Work settled with " .. tostring(failed) .. " failed or refused source outcomes." else "Project work completed and managed decisions settled.", now)
		end
	end end
end
config.PROJECT_COMMANDS = { new_project = true, project_start = true, project_start_retry = true, project_associate = true, project_repository = true,
	project_finish = true, project_reopen = true, delete_history = true, associate_conversation = true, detach_conversation = true, observe_conversation = true }
function config.project_command(registry: any, n: any, event: any, clock: any): (any?, any?)
	local d, sid, command = n.dispatch, event.orch_session_id, event.command
	if command == "delete_history" then d.finished_projects = {}; return result("history_deleted", { message = "Finished-project summaries deleted. Live work and native conversations are unchanged." }), nil end
	if command == "new_project" or command == "project_reopen" then
		local name, source = event.name, event.source
		if command == "project_reopen" then
			local summary = if pos(event.summary_index) then (d.finished_projects or {})[event.summary_index] else nil
			if not summary then return fail("summary_changed", "This finished summary is no longer available.") end
			name, source = name or summary.name, summary.source
		end
		if not str(name, 160) or not name:find("%S") or (source ~= nil and not config.project_source(source)) then return fail("invalid_project", "Give this project a nonblank name of at most 160 bytes and a supported source reference.") end
		local p = config.new_project(d, sid, name, source)
		return result(if command == "project_reopen" then "project_reopened" else "project_created", { orch_project_id = p.orch_project_id,
			message = if command == "project_reopen" then "New unstarted project created from the source reference. No old tasks or approvals were replayed." else "Project added. Work stays held until START." }), nil
	end
	local p = config.project_ref(d, sid, event.orch_project_id)
	if command == "project_start_retry" then
		local start = if p then p.start else nil
		if not start or start.start_id ~= event.start_id or start.project_revision ~= event.project_revision
			or start.decision_context ~= event.decision_context then return fail("start_changed", "Retry names only the original START grant, project revision and decision proof.") end
		if start.origin.owner_id ~= event.origin.owner_id or start.origin.owner_generation ~= event.origin.owner_generation then
			return fail("start_owner_changed", "The original controller owner must inspect this retained START; another owner cannot retry it.")
		end
		local view = config.start_projection(d, p, n)
		if start.claim then return result("project_start_claimed", { start = view }), nil end
		if view.failure and not view.failure.retryable then
			return result("project_start_inspection", { start = view, message = view.failure.message }), nil
		end
		if n.sessions[sid].admitted ~= true then return fail("admission_required", "Fresh explicit paired admission is required before re-arming the original START delivery. Its uncertainty may still be inspected.") end
		for _, a in d.actions do if config.start_for_action(d, a) == start then
			if a.phase == "backpressure" and a.response and retryable_full(a.response.payload) then
				config.release_executor(n.sessions[sid], d.workers[a.worker_id], a); config.consume_action(d, a)
				start.failure = nil
				return result("project_start_retry_queued", { start_id = start.start_id, action_id = start.action_id,
					message = "Original START delivery re-armed. Its typed action and immutable bytes are unchanged; no work was released." }), nil
			end
			return result("project_start_inspection", { start = view, message = "Original START delivery remains retained; no replacement grant or effect was issued." }), nil
		end end
		start.failure = nil
		return result("project_start_retry_queued", { start_id = start.start_id, action_id = start.action_id,
			message = "Original START remains in the durable outbox. No new grant or approval was created." }), nil
	end
	if not p or p.revision ~= event.project_revision then return fail("project_changed", "This project's membership or source changed; review the selected project again.") end
	if command == "project_start" then
		if p.start and not p.start.claim then
			local failure = config.start_permanent_failure(n, p, p.start)
			if failure and p.start.published and (p.start.acknowledged or config.start_owner_closed(n, p, p.start)) and not config.start_in_flight(d, p.start) then config.close_start(n, p, p.start, failure, nil) end
			if not config.start_replaceable(n, p, p.start) then
				return result("project_start_pending", { orch_project_id = p.orch_project_id, start = config.start_projection(d, p, n),
					message = "Waiting for your orchestrator. Your work is still on hold." }), nil
			end
		end
		if p.checks_pending and event.checks_reviewed ~= true then return fail("checks_review_required", "Review the proposed command arguments before starting this project.") end
		if event.checks_reviewed ~= nil and event.checks_reviewed ~= true then return fail("invalid_command", "Check review is an explicit owner approval.") end
		local snapshot = config.start_snapshot(d, p)
		local held = next(snapshot.workers) ~= nil or next(snapshot.plans) ~= nil or next(snapshot.intakes) ~= nil or next(snapshot.chains) ~= nil
		if p.started and not held then return result("project_already_started", { orch_project_id = p.orch_project_id }), nil end
		local owner = n.sessions[sid].orchestrator
		if not owner then
			if p.start and config.start_replaceable(n, p, p.start) then
				if #(p.start_history or {}) >= 32 then return fail("full", "Retained START history is full.") end
				p.start_history = p.start_history or {}; table.insert(p.start_history, p.start); p.start = nil
			end
			if not config.standalone_start(n, p) then return fail("start_coordinator_unavailable", "An unresolved coordinator generation still owns this orchestration. Standalone START is not a recovery fallback.") end
			-- Standalone START is a distinct host-owned mode, never a coordinator fallback.
			local released, problem = config.release_start(d, p, snapshot, event, clock)
			if not released then return nil, problem end
			return result("project_started", { orch_project_id = p.orch_project_id, message = "Standalone START recorded for this project's captured work." }), nil
		end
		local w = d.workers[owner.managed_worker_id]
		if owner.phase ~= "running" or not w or not coordinator(n, w) or w.phase ~= "accepted" or not w.accepted_event or w.accept_pending
			or not w.activation or not w.activation.acknowledged or w.retirement or w.release or w.continuation_required then
			return fail("start_coordinator_unavailable", "START requires this session's running, accepted and activated coordinator. Work remains held.")
		end
		if not table.find(w.capabilities or {}, "coordinator-control-v1") or not table.find(w.capabilities or {}, "project-start-v1") then
			return fail("unsupported_capability", "This coordinator cannot consume project-start-v1. Work stays held; an old coordinator cannot receive a new START grant.")
		end
		local start, problem = config.issue_project_start(n, p, w, snapshot, event.decision_context, event, { kind = "owner" })
		if not start then return nil, problem end
		return result("project_start_pending", { orch_project_id = p.orch_project_id, start = config.start_projection(d, p, n),
			message = "START delivery recorded durably. Work stays held until the exact coordinator claim is accepted." }), nil
	elseif command == "associate_conversation" then
		if not pane_binding(event.pane_binding, event.origin) or type(event.active) ~= "boolean"
			or (event.provider ~= nil and not str(event.provider, 80)) or (event.account_label ~= nil and not str(event.account_label, 160)) then return fail("invalid_conversation", "Choose an exact native conversation; optional account labels are user-declared only.") end
		for _, w in d.workers do if not w.mailbox_retired and config.same_conversation(control_binding(w) or w.adopt_pane_binding, event.pane_binding) then
			return fail("pane_bound", "This pane already has a managed association. Move that existing member explicitly instead of enrolling it again.")
		end end
		for _, project in d.projects do for _, c in project.associations or {} do
			if config.same_conversation(c.pane_binding, event.pane_binding) then
				if project.orch_project_id == p.orch_project_id then return result("conversation_already_associated", { conversation_id = c.conversation_id, orch_project_id = p.orch_project_id }), nil end
				return fail("pane_bound", "This conversation belongs to another project. Detach its existing association before moving it.")
			end
		end end
		p.associations = p.associations or {}
		local key = next_id(d, "conversation-")
		p.associations[key] = { conversation_id = key, pane_binding = clone(event.pane_binding), provider = event.provider, account_label = event.account_label, active = event.active }
		p.revision += 1
		return result("conversation_associated", { conversation_id = key, orch_project_id = p.orch_project_id, message = "Conversation associated only. Its task and context are unchanged; held project work was not started." }), nil
	elseif command == "detach_conversation" or command == "observe_conversation" then
		local conversation = if id(event.conversation_id) then (p.associations or {})[event.conversation_id] else nil
		if not conversation then return fail("conversation_changed", "This conversation association is no longer current.") end
		if command == "detach_conversation" then p.associations[event.conversation_id] = nil; p.revision += 1
		else
			if not pane_binding(event.pane_binding, event.origin) or not config.same_conversation(conversation.pane_binding, event.pane_binding) or type(event.active) ~= "boolean" then return fail("observation_mismatch", "Observe only this association's exact native pane.") end
			if conversation.active == event.active then return result("no_progress"), nil end
			conversation.active = event.active
		end
		return result(if command == "detach_conversation" then "conversation_detached" else "conversation_observed",
			{ orch_project_id = p.orch_project_id, message = "Association updated. The native conversation was not stopped or changed." }), nil
	elseif command == "project_associate" then
		local w = d.workers[event.worker_id]
		if not w or w.logical_session_id ~= sid or not equal(control_origin(w), event.origin) then return fail("worker_unbound", "Choose this orchestration's exact current conversation.") end
		if w.orch_project_id == p.orch_project_id then return result("project_already_associated", { orch_project_id = p.orch_project_id }), nil end
		if pending(d, w) or work_referenced(d, w) then return fail("association_busy", "Settle this conversation's effects and decisions before changing its project.") end
		for _, plan in d.plans or {} do if plan.status == "active" then for _, cp in plan.checkpoints do for _, task in cp.tasks do
			if task.work_id == w.work_id then return fail("association_busy", "This conversation is executing an imported plan member; its source association cannot be moved independently.") end
		end end end end
		for _, rec in d.intakes or {} do if rec.work_id == w.work_id and rec.state ~= "refused" and rec.lane ~= "done" then return fail("association_busy", "This conversation still belongs to an unfinished source intake.") end end
		for _, chain in d.chains or {} do if chain.status ~= "done" and chain.status ~= "stopped" then for _, step in chain.steps do
			if step.work_id == w.work_id then return fail("association_busy", "This conversation still belongs to an unfinished template chain.") end
		end end end
		local previous = d.projects[w.orch_project_id]
		if previous then previous.revision += 1 end
		w.orch_project_id = p.orch_project_id; p.revision += 1
		if w.project_held then w.checks_pending = true end
		if w.checks_pending and w.checks and #w.checks > 0 then p.checks_pending = true end
		if not w.mailbox_handle and not w.enrol_delivery and not w.pane_binding then w.execution_cwd = if p.repository then p.repository.cwd else nil end
		return result("project_associated", { orch_project_id = p.orch_project_id, worker_id = w.worker_id,
			message = "Conversation associated. Its existing task is unchanged; held project work was not started." }), nil
	elseif command == "project_repository" then
		if not config.valid_project_repository(event.repository) then return fail("repository_unverified", "A host-verified canonical checkout and target are required.") end
		local function canonical(value: any): any
			if not value then return nil end
			local out = table.clone(value)
			out.cwd, out.repo_root, out.common_dir = rules.normalize_path(value.cwd), rules.normalize_path(value.repo_root), rules.normalize_path(value.common_dir)
			out.target_ref = config.repository_target(value.target_ref)
			return out
		end
		local repository, old = canonical(event.repository), canonical(p.repository)
		if equal(old, repository) then return result("no_progress", { orch_project_id = p.orch_project_id }), nil end
		local same_binding = old ~= nil and old.queue_route == repository.queue_route and old.target_ref == repository.target_ref
			and old.cwd == repository.cwd and old.repo_root == repository.repo_root and old.common_dir == repository.common_dir
		for _, other in d.projects do
			if other.orch_project_id ~= p.orch_project_id and not other.finished and other.repository
				and rules.normalize_path(other.repository.common_dir) == repository.common_dir
				and config.repository_target(other.repository.target_ref) == repository.target_ref
				and other.repository.queue_route ~= repository.queue_route then
				return fail("repository_route_conflict", "Another unfinished project retains this canonical repository/target queue route. Settle it before changing the shared route.")
			end
		end
		if not same_binding then
			for _, queue in (d.landing or {}).queues or {} do for _, lid in queue.order do
				local item = d.landing.items[lid]
				local worker = if item then d.workers[item.worker_id] else nil
				if worker and worker.orch_project_id == p.orch_project_id then return fail("repository_busy", "Settle this project's queued landings before changing its checkout, target or queue route.") end
			end end
			for _, w in d.workers do if w.orch_project_id == p.orch_project_id and not w.mailbox_retired then
				if active_rollover(d, w) or w.launch_gates then return fail("repository_busy", "Settle this project's handover or checkout decisions before changing its execution location.") end
				if w.checkout and rules.normalize_path(w.checkout.common_dir) ~= repository.common_dir then return fail("repository_busy", "A live member proves another canonical repository; finish or explicitly reassociate that work first.") end
				for _, action in d.actions do if action.worker_id == w.worker_id and (action.request.op == "launch" or action.request.op == "mailbox_provision") then
					return fail("repository_busy", "Settle the retained provision or launch before changing this project's execution location.")
				end end
			end end
		end
		local problem = M.set_repository_policy(n, repository)
		if problem then return nil, problem end
		p = n.dispatch.projects[p.orch_project_id]; p.repository = repository; p.revision += 1
		for _, w in n.dispatch.workers do if w.orch_project_id == p.orch_project_id and not w.mailbox_handle and not w.enrol_delivery and not w.pane_binding then w.execution_cwd = p.repository.cwd end end
		return result("project_repository_updated", { orch_project_id = p.orch_project_id }), nil
	elseif command == "project_finish" then
		if not str(event.result, 2048) or not event.result:find("%S") then return fail("invalid_summary", "Write a concise result of at most 2048 bytes.") end
		local problem = config.project_finish_problem(d, p)
		if problem then return fail("project_unfinished", problem) end
		config.summarize_project(n, p, event.result, stamp(clock).at_ms)
		return result("project_finished", { orch_project_id = p.orch_project_id, message = "Project moved to Finished projects. Associated conversations were not stopped." }), nil
	end
	return fail("invalid_command", "Unknown project operation.")
end

function M.apply(registry: any, event: any, clock: any, reserve: any): (any?, any)
	if type(event) ~= "table" or event.kind ~= "dispatch" or not id(event.request_id) or not M.origin(event.origin)
		or event.orch_session_id ~= event.origin.logical_session_id then return fail("controller_mismatch", "Exact native controller origin is required.") end
	local session = registry.sessions[event.orch_session_id]
	local closing = session and session.phase == "closing" and session.close and session.close.control_origin
	local closure_control = closing and (event.command == "bridge_result" or event.command == "bridge_observe" or (event.command == "bridge_control" and event.operation == "close_session"))
		and equal(closing.binding, event.origin) and closing.controller_pane == event.controller_pane
	if not closure_control and not authorized(registry, event.origin, event.controller_pane, event.command == "continue_controller") then
		return fail("controller_mismatch", "Only the admitted active native controller binding may dispatch.")
	end
	if event.authority_namespace ~= registry.authority_namespace then return fail("stale_authority", "Authority namespace changed; old intent cannot execute.") end
	if event.expected_revision ~= registry.revision and not M.subject_decision(registry, event) then return fail("stale_revision", "The authority or this decision's subject changed. Review it again; the old decision was not replayed.") end
	if session.phase == "closing" and not closure_control then return fail("session_closing", "Closing fences all new enqueue and effects.") end
	local specific = {
		bridge_control = "operation compatibility", bridge_result = "query_bytes response_bytes", bridge_observe = "query_bytes response_bytes",
		spawn_claimed = "action_id grant_id spawn_namespace claim_nonce",
		observe_allocation = "worker_id query_bytes response_bytes",
		ruling_prepare = "gate_id gate_revision writer evidence", ruling_observe = "gate_id gate_revision writer evidence",
		ruling_reissue = "gate_id gate_revision writer evidence", ruling_remote = "gate_id gate_revision worker_id",
		associate_document = "worker_id path evidence", close_handover = "worker_id",
		catalog = "bytes decision_context", queue = "record_id record_revision catalog_revision prompt cwd placement coordinator role class template_id files scope checks source base_ref orch_project_id presentation execution_cwd open_conversation",
		enrol = "record_id record_revision catalog_revision orch_project_id pane_binding delivery",
		new_project = "name source decision_context", project_start = "orch_project_id project_revision decision_context checks_reviewed",
		project_start_retry = "orch_project_id start_id project_revision decision_context",
		project_associate = "worker_id orch_project_id project_revision decision_context", project_repository = "orch_project_id project_revision repository decision_context",
		project_finish = "orch_project_id project_revision result", project_reopen = "summary_index name", delete_history = "",
		associate_conversation = "orch_project_id project_revision pane_binding provider account_label active decision_context",
		detach_conversation = "orch_project_id project_revision conversation_id", observe_conversation = "orch_project_id project_revision conversation_id pane_binding active",
		source_request = "gate_id gate_revision source_revision cards",
		claim = "action_id executor capacity_validation", result = "action_id executor grant_id response_bytes", lost = "action_id executor grant_id",
		read_missing = "action_id executor grant_id query_bytes response_bytes",
		capacity = "capacity", cancel_work = "worker_id query_bytes response_bytes",
		poll = "worker_id bytes", reply = "worker_id trigger", retire = "worker_id withdraw_starts", finish = "worker_id", intake = "worker_id bytes", retry = "action_id trigger", readback_publication = "action_id",
		policy = "policy expected_policy_sha256 template_put template_remove", pause = "", resume = "", observe = "worker_id pane_binding native_state delivery_error observation_seq",
		answer = "gate_id gate_revision choice_id answer decision_context", cancel_gate = "gate_id gate_revision", recheck_gate = "gate_id gate_revision",
		continue_controller = "expected_revision operator_verified machine_proof", continue_worker = "worker_id pane_binding continuation_proof operator_verified machine_proof",
		rollover = "worker_id trigger", reconcile_restored = "worker_id operator_verified", recheck_report = "worker_id",
		cancel_landing = "landing_id landing_revision", move_landing = "landing_id landing_revision direction",
		landing_lost = "landing_id landing_revision reason", reconcile_landing = "landing_id landing_revision outcome target_revision current_target_revision reason operator_verified",
		sweep = "local_date catch_up",
		cleanup_notice = "local_date observed_at_ms mailboxes time_zone open_files stale_files observation_unavailable",
		migrate_families = "",
		plan_import = "path orch_project_id source_revision", board_intake = "board_path card_id text tags text_sha256 orch_project_id",
		inbox_intake = "name content_sha256 orch_project_id", template_start = "template_id input custom_fields orch_project_id source_revision",
	}
	local sequenced = not EFFECT_COMMANDS[event.command]
	if not specific[event.command] or not closed(event, "kind request_id orch_session_id authority_namespace expected_revision origin controller_pane command " .. (if sequenced then "command_seq " else "") .. specific[event.command])
		or (sequenced and not pos(event.command_seq)) then
		return fail("invalid_command", "Unexpected operation-specific dispatch fields.")
	end
	if (table.find({ "answer", "new_project", "project_start", "project_associate", "project_repository", "associate_conversation" }, event.command)
		or (event.command == "catalog" and event.decision_context ~= nil)) and not M.subject_decision(registry, event) then
		return fail("decision_changed", "The exact question, project, recipient, policy or proof changed. Your draft is preserved; review the current decision.")
	end
	local d = registry.dispatch or fresh()
	local cursor = (d.command_cursors or {})[event.orch_session_id]
	if cursor and not equal(cursor.origin, event.origin) and cursor.origin.owner_id == event.origin.owner_id
		and cursor.origin.owner_generation == event.origin.owner_generation and event.command ~= "continue_controller" then
		return fail("continuation_required", "This controller incarnation must explicitly continue before issuing intent or settling retained claims.")
	end
	if event.command == "observe" and event.observation_seq ~= nil then
		if not pos(event.observation_seq) then return fail("invalid_observation", "Observation sequence must be a positive integer.") end
		local w = d.workers[event.worker_id]
		if not w or not equal(control_origin(w), event.origin) then return fail("observation_mismatch", "Observation incarnation requires the explicit current worker control route.") end
		local cursor = if w.workflow then w.workflow.observation_cursor else nil
		if cursor and event.observation_seq <= cursor.seq then
			if event.observation_seq < cursor.seq then return fail("stale_observation", "Older observation cannot refresh host-clock evidence.") end
			if not equal(cursor.event, event) then return fail("request_conflict", "Observation sequence already names different input.") end
			return registry, result("observation_recorded")
		end
	end
	-- Sequenced observations and polls keep no command outcome (see unretained): the exact latest
	-- observation replay is answered idempotently by the observation cursor above, an older one is
	-- refused there, and every other replay (polls included) falls behind this durable barrier.
	if sequenced and cursor and event.command_seq <= cursor.seq then
		return fail("stale_command", "This owner intent is behind the durable command sequence barrier; it cannot execute again.")
	end
	if type(clock) == "table" and clock.reserved_capacity and (event.command == "catalog" or event.command == "migrate_families" or event.command == "queue" or event.command == "enrol" or event.command == "reply" or event.command == "rollover" or event.command == "capacity" or event.command == "sweep" or config.SOURCE_COMMANDS[event.command] or event.command == "new_project" or event.command == "project_reopen" or event.command == "source_request") then
		return fail("capacity_reached", "New dispatch cannot consume reserved receipt/recovery capacity.")
	end
	if registry.revision == MAX or d.serial > MAX - 20 then return fail("full", "Durable dispatch counters are exhausted.") end
	if not valid_stamp(stamp(clock)) then return fail("invalid_clock", "Host audit clock is invalid.") end
	if policy(d, event.orch_session_id).paused and (event.command == "enrol" or event.command == "reply" or event.command == "rollover" or (event.command == "queue" and (event.open_conversation or event.coordinator))) then return fail("session_paused", "Orchestration is paused. You may add held work, but new conversation effects wait for Resume.") end
	-- Read-only refusals, exact duplicates and unchanged observations answer before the full
	-- candidate clone. They read only fields no earlier step of this transition modifies
	-- (worker reclamation runs for queue/adopt only).
	if event.command == "claim" then
		local a = d.actions[event.action_id]
		if a == nil or not equal(a.request.origin_binding, event.origin) or a.request.controller_pane ~= event.controller_pane or not id(event.executor) then return fail("claim_mismatch", "Claim differs from its immutable origin/action.") end
		if a.request.op == "launch" or a.request.op == "adopt" or a.request.op == "enrol" or a.request.op == "mailbox_provision" then
			local w = if a.worker_id then d.workers[a.worker_id] else nil
			if type(clock) == "table" and clock.reserved_capacity then return fail("capacity_reached", "New launch claims cannot consume reserved receipt/recovery capacity.") end
			if not w or not config.worker_start_allowed(d, w) or w.checks_pending or w.launch_gates then return fail("project_held", "START this project and settle its checkout decisions before issuing new work.") end
		end
		if a.phase ~= "ready" then return fail("effect_already_claimed", "This effect is already claimed, settled or uncertain; inspect its retained outcome.") end
		if a.retry_loop and a.retry_loop.state ~= nil then
			return fail("loop_gated", "This action's retry loop is gated or stopped by the owner's loop cap; it cannot be claimed until the owner allows more.")
		end
		if event.executor ~= event.origin.window_epoch then return fail("claim_mismatch", "Executor incarnation must match the frozen origin window epoch.") end
	elseif event.command == "spawn_claimed" then
		local a = d.actions[event.action_id]
		local witness = { spawn_namespace = event.spawn_namespace, claim_nonce = event.claim_nonce }
		if not a or not a.claim or a.claim.grant_id ~= event.grant_id or a.claim.epoch ~= registry.execution_epoch
			or (a.phase ~= "claimed" and not (a.phase == "uncertain" and a.claim.spawn_claim ~= nil))
			or not equal(a.request.origin_binding, event.origin) or a.request.controller_pane ~= event.controller_pane
			or not codec.validate_spawn_claim(witness, false) or not session.admitted
			or (a.claim.spawn_claim == nil and event.spawn_namespace ~= session.spawn_namespace) then return fail("stale_claim", "Peer claim must name the exact live admitted native grant.") end
		if equal(a.claim.spawn_claim, witness) then return registry, result("spawn_claim_observed") end
		if a.phase == "uncertain" then return registry, result("claim_mismatch") end
	elseif event.command == "result" or event.command == "lost" then
		local a = d.actions[event.action_id]
		local continued = cursor and cursor.continued_epoch == registry.execution_epoch and equal(cursor.origin, event.origin)
		if a == nil or not equal(execution_origin(d, a), event.origin) or a.claim == nil or a.claim.executor ~= event.executor
			or a.claim.grant_id ~= event.grant_id or (a.claim.epoch ~= registry.execution_epoch and not continued)
			or (a.phase ~= "claimed" and a.phase ~= "uncertain") then return fail("stale_claim", "Late result cannot change another owner, action or runtime grant.") end
		if event.command == "result" and a.response_grant == a.claim.grant_id and a.response_bytes == event.response_bytes and a.response ~= nil then
			return registry, result(if a.phase == "claimed" then "wake_pending" else "effect_uncertain",
				{ wake_status = if type(a.response.payload) == "table" then a.response.payload.wake_status else nil })
		end
	elseif bounded_observation(event) then
		local w = d.workers[event.worker_id]
		if w and observation_unchanged(registry, d, w, event, clock) then return registry, result("observation_recorded") end
	elseif event.command == "poll" then
		if poll_idle(registry, d, d.workers[event.worker_id], event, clock) then
			return registry, result("mailbox_idle", { worker_id = event.worker_id,
				message = "Nothing to read: the worker stayed idle since its last read of the next report found nothing. It is read again after its next native change, or within a quarter of the stale window." })
		end
	end
	local n = candidate(registry); d = n.dispatch
	if event.command == "queue" or event.command == "enrol" then reclaim_workers(n) end
	local ordinary = event.command == "queue" or event.command == "enrol" or event.command == "project_start" or event.command == "catalog" or event.command == "migrate_families" or event.command == "reply" or event.command == "rollover" or event.command == "capacity" or event.command == "sweep" or config.SOURCE_COMMANDS[event.command] ~= nil
	if ordinary and session.admitted ~= true then return fail("admission_required", "Fresh explicit paired admission is required before enqueueing new work.") end
	if event.command == "continue_worker" and session.admitted ~= true then
		return fail("admission_required", "Explicitly reconcile the retained admission before approving worker reattachment.")
	end
	local limit = if ordinary then 3072 else 4096
	if (event.command == "queue" or event.command == "catalog" or event.command == "migrate_families" or event.command == "poll") and count(d.actions) >= limit then
		return fail("full", "Durable dispatch ledger is full; unresolved work and settlement reserve are retained.")
	end
	local answer
	if config.PROJECT_COMMANDS[event.command] then
		local problem
		answer, problem = config.project_command(registry, n, event, clock)
		if problem then return nil, problem end
		d = n.dispatch
	elseif event.command == "source_request" then
		local problem
		answer, problem = config.consume_source_request(registry, n, event, clock, reserve)
		if problem then return nil, problem end
	elseif event.command == "bridge_control" or event.command == "bridge_result" or event.command == "bridge_observe" then
		local handled, problem
		if event.command == "bridge_control" then handled, problem = bridge_control(n, event)
		elseif event.command == "bridge_observe" then handled, problem = bridge_observe(n, event)
		else handled, problem = bridge_result(n, event) end
		if problem then return nil, problem end
		return finish_command(n, event, handled)
	elseif event.command == "associate_document" or event.command:sub(1, 7) == "ruling_" then
		local handled, problem = config.ruling_command(n, event)
		if problem then return nil, problem end
		return finish_command(n, event, handled)
	elseif event.command == "observe_allocation" then
		local w = d.workers[event.worker_id]
		if not w or w.logical_session_id ~= event.orch_session_id or session.admitted ~= true then
			return fail("worker_unbound", "Observe a retained generation through this session's current admitted controller.")
		end
		local problem, changed = config.observe_allocation(n, w, event)
		if problem then return nil, problem end
		if not changed then return registry, result("no_progress") end
		answer = result(if w.mailbox_allocation == "none" then "allocation_none" else "allocation_retained", { worker_id = w.worker_id })
	elseif event.command == "migrate_families" then
		local sid = event.orch_session_id
		local c, obligations = d.catalogs[sid], config.family_obligations(n, sid)
		if not c then return fail("catalog_missing", "Load the current SPAWN catalog before migrating family declarations.") end
		if (d.catalog_scans or {})[sid] ~= false then return fail("catalog_incomplete", "Load the complete official SPAWN roster before migrating family declarations; a final page alone is not proof.") end
		if not obligations or next(obligations) == nil then return finish_command(n, event, result("no_progress")) end
		for _, a in d.actions do if a.request.op == "declare_provider_families" and a.request.origin_binding.logical_session_id == sid then
			local repeated = a.phase ~= "complete" and a.phase ~= "resolved"
			if a.request.record_revision == c.config_revision then
				for _, value in a.request.declarations do if obligations[value.record_id] == value.provider_family then repeated = true end end
				if a.response and a.response.status == "resolved" then
					for _, value in a.response.payload.families do if obligations[value.record_id] == value.provider_family then repeated = true end end
				end
			end
			if repeated then return fail("family_migration_pending", "Settle the retained SPAWN declaration outcome and refresh its catalog before another write of the same target. No request is replayed.") end
		end end
		local declarations = {}
		-- Leave room for the bounded canonical response as well as the request's authority envelope.
		for _, row in c.records do
			if #declarations == 16 then break end
			if obligations[row.id] then table.insert(declarations, { record_id = row.id, provider_family = obligations[row.id] }) end
		end
		if #declarations == 0 then return fail("family_migration_missing", "Legacy declarations name records absent from the current SPAWN catalog. Restore or review those records in SPAWN; migration obligations were retained.") end
		local request = common(d, event.origin, event.controller_pane, "declare_provider_families")
		request.record_revision = c.config_revision; request.declarations = tern.json.array(declarations)
		if not add(d, request) then return fail("oversize", "Family migration exceeds the bridge bound; declarations were retained.") end
		answer = result("family_migration_queued", { action_id = request.action_id })
	elseif event.command == "continue_controller" then
		local previous = (d.command_cursors or {})[event.orch_session_id]
		local proof = event.machine_proof
		local machine = proof ~= nil and closed(proof, "previous_origin") and previous ~= nil and equal(proof.previous_origin, previous.origin)
			and M.origin(proof.previous_origin) and previous.controller_pane == event.controller_pane
			and previous.origin.owner_id == event.origin.owner_id and previous.origin.owner_generation == event.origin.owner_generation
			and previous.origin.host_pane_id == event.origin.host_pane_id and previous.origin.native_session_id == event.origin.native_session_id
			and previous.origin.window_key == event.origin.window_key and previous.origin.window_host_id == event.origin.window_host_id
		if event.expected_revision ~= registry.revision or (event.operator_verified ~= true and not machine) then return fail("stale_recovery", "Continuation needs the exact same native controller or an explicit inspected recovery.") end
		-- This is a route fence, not owner replacement or effect resolution.
		fence_unexecuted(d, event, n.revision)
		local owner = n.sessions[event.orch_session_id].controller
		owner.phase = "active"; owner.owner_active = true
		d.command_cursors = d.command_cursors or {}
		d.command_cursors[event.orch_session_id] = { origin = clone(event.origin), controller_pane = event.controller_pane, seq = event.command_seq, continued_epoch = registry.execution_epoch,
			policy_revision = M.policy_revision(registry, event.orch_session_id) ~= 0 and M.policy_revision(registry, event.orch_session_id) or nil }
		answer = result("controller_continued")
	elseif event.command == "continue_worker" then
		local w = d.workers[event.worker_id]
		local proof = event.machine_proof
		local machine = w ~= nil and proof ~= nil and closed(proof, "previous_pane_binding") and equal(proof.previous_pane_binding, control_binding(w))
			and config.same_conversation(control_binding(w), event.pane_binding) and control_binding(w).window_key == event.pane_binding.window_key
			and w.accepted_event ~= nil
		if machine and config.session_effects_pending(d, event.orch_session_id) then
			return fail("settlement_pending", "Automatic attachment cannot replay or abandon outstanding session effects; settle the retained operation first.")
		end
		if (event.operator_verified ~= true and not machine) or not w or not digest(event.continuation_proof) or event.continuation_proof ~= continuation_proof(registry, registry.dispatch.workers[event.worker_id])
			or w.logical_session_id ~= event.orch_session_id
			or not w.mailbox_handle or not w.pane_binding or w.stopped or w.mailbox_retired or not pane_binding(event.pane_binding, event.origin)
			then
			return fail("stale_recovery", "Worker/owner identity or retained effects changed; re-inspect this exact scoped attachment proof.")
		end
		fence_unexecuted(d, event, n.revision, w.worker_id)
		-- Uncertain reads are retained evidence, not effects: the committed attachment supersedes them.
		if pending(d, w, false, true) then return fail("settlement_pending", "Inspect and individually reconcile original effects before attaching; no old execution is replayed or forgotten.") end
		local request = common(d, event.origin, event.controller_pane, "attach_worker")
		request.target_request_id = w.launch_request_id; request.target_action_id = w.launch_action_id
		request.previous_origin_binding = clone(control_origin(w)); request.previous_pane_binding = clone(control_binding(w))
		request.pane_binding = clone(event.pane_binding)
		request.attestation = if not machine then "old_executors_stopped_or_retired" elseif w.selected_record and w.selected_record.backend == "native-agent" then "same_native_conversation_no_pending_effects" else "same_terminal_process_no_pending_effects"
		for _, key in { "worker_id", "worker_generation", "enrolment_token", "work_id" } do request[key] = w[key] end
		if not add(d, request, w.worker_id) then return fail("oversize", "Attachment request exceeds bridge bound.") end
		answer = result("attachment_queued", { action_id = request.action_id, worker_id = w.worker_id })
	elseif event.command == "policy" or event.command == "pause" or event.command == "resume" then
		local p = clone(policy(d, event.orch_session_id))
		if event.command == "policy" then
			-- The displayed policy's digest (projected as workflow.policy_sha256) fences stale editors.
			local forms = (if event.policy ~= nil then 1 else 0) + (if event.template_put ~= nil then 1 else 0) + (if event.template_remove ~= nil then 1 else 0)
			if forms ~= 1 then return fail("invalid_policy", "A policy edit carries exactly one of policy, template_put or template_remove.") end
			if event.expected_policy_sha256 ~= nil and (not digest(event.expected_policy_sha256) or event.expected_policy_sha256 ~= quota.digest(policy(d, event.orch_session_id))) then
				return fail("policy_conflict", "Config changed since this editor was displayed. Reopen Config; the newer policy was not overwritten.")
			end
			if event.template_put ~= nil then
				local entry = event.template_put
				if not config.template(entry) then return fail("invalid_policy", "A template needs an id and optional class matching [a-z][a-z0-9-]{0,31}, a title of 1..80 bytes, a prompt of at most 4096 bytes with exactly one {input}, a relative output path of at most 256 bytes without .. and a next template id or \"\".") end
				local index = #p.templates + 1
				for i, t in p.templates do if t.id == entry.id then index = i end end
				p.templates[index] = clone(entry)
			elseif event.template_remove ~= nil then
				local index
				for i, t in p.templates do if t.id == event.template_remove then index = i end end
				if not index then return fail("template_unknown", "No saved template has this id; nothing was removed.") end
				for _, t in p.templates do
					if t.next == event.template_remove then return fail("template_referenced", "Template " .. t.id .. " continues into this template; change its next step first. Nothing was removed.") end
				end
				table.remove(p.templates, index)
			end
		end
		if event.command == "policy" and event.policy ~= nil then
			if not closed(event.policy, config.keys.editable) or next(event.policy) == nil then return fail("invalid_policy", "Policy accepts only the documented session settings.") end
			for key, value in event.policy do p[key] = clone(value) end
			if p.require_code_review == false and event.policy.require_other_family == true then
				return fail("invalid_policy", "Enable Require code review before requiring another provider family.")
			end
			if p.require_code_review == false then p.require_other_family = false end
			-- Canonical storage for set-valued settings; duplicates and unknown entries still fail validation.
			local function strings(list: any): boolean
				if type(list) ~= "table" or list == tern.json.null then return false end
				for _, entry in list do if type(entry) ~= "string" then return false end end
				return true
			end
			-- Reviewer records keep the owner's order (the first eligible entry is chosen); only repeats are dropped.
			if event.policy.reviewer_records ~= nil and strings(p.reviewer_records) then
				local seen, ordered = {}, {}
				for _, record_id in p.reviewer_records do if not seen[record_id] then seen[record_id] = true; table.insert(ordered, record_id) end end
				p.reviewer_records = ordered
			end
			if event.policy.auto_approve_kinds ~= nil and strings(p.auto_approve_kinds) then
				table.sort(p.auto_approve_kinds, function(a, b) return (table.find(config.APPROVABLE, a) or 99) < (table.find(config.APPROVABLE, b) or 99) end)
			end
			if event.policy.excluded_workers ~= nil then
				local list = p.excluded_workers
				if type(list) ~= "table" or list == tern.json.null or #list > 32 or count(list) ~= #list then return fail("invalid_policy", "Excluded workers must be a bounded list of worker IDs.") end
				for _, worker_id in list do
					local target = if id(worker_id) then d.workers[worker_id] else nil
					if not target or target.logical_session_id ~= event.orch_session_id then return fail("invalid_policy", "Excluded workers must name managed workers of this session.") end
				end
				table.sort(list) -- Canonical storage; duplicates still fail the strictly ascending check.
			end
			for _, scope in quota.SCOPES do
				if event.policy[scope .. "_records"] ~= nil then
					local list = p[scope .. "_records"]
					if type(list) ~= "table" or list == tern.json.null or #list > quota.MAX_RECORDS or count(list) ~= #list then return fail("invalid_policy", "Routing alternatives must be a bounded list of record IDs.") end
					for _, record_id in list do if not str(record_id, 96) then return fail("invalid_policy", "Routing alternatives must be explicit record IDs.") end end
					table.sort(list) -- Canonical storage; duplicates and wildcards still fail validation.
				end
			end
		end
		if event.command == "policy" then
			if not config.fits(p) then return fail("policy_too_large", "The saved session policy would exceed " .. tostring(config.MAX_BYTES) .. " bytes in canonical form; shorten templates. Nothing was saved.") end
			if not valid_policy(p) then return fail("invalid_policy", "Settings have invalid fields or bounds. Durations must be consistent, cleanup uses hh:mm:ss, concurrency is at most 32 and loop/review limits are 1..10.") end
		else p.paused = event.command == "pause" end
		local previous = policy(d, event.orch_session_id)
		if equal(p, previous) then return finish_command(n, event, result("no_progress")) end
		d.policies = d.policies or {}; d.policies[event.orch_session_id] = p
		-- A routing-policy edit re-evaluates unlaunched routed work and voids stale fallback gates.
		if quota.policy_digest(p) ~= quota.policy_digest(previous) then
			local err = reroute(registry, n, event, clock, reserve); if err then return nil, err end
		end
		answer = result("policy_updated")
	elseif event.command == "observe" then
		local w = d.workers[event.worker_id]
		if not w or not equal(control_origin(w), event.origin) or not w.pane_binding or not equal(control_binding(w), event.pane_binding)
			or not table.find({ "working", "idle", "waiting-input", "exited", "unknown" }, event.native_state)
			or (event.delivery_error ~= nil and not str(event.delivery_error, 1024)) then return fail("observation_mismatch", "Observation requires the exact current worker pane, origin and native lifecycle state.") end
		local f = flow(w); local observation = stamp(clock); observation.state = event.native_state; observation.delivery_error = event.delivery_error
		if equal(f.native, observation) and event.observation_seq == nil and not next(w.wakes or {}) then return finish_command(n, event, result("no_progress")) end
		local previous = f.native; f.native = observation
		if observation.state ~= "idle" or observation.delivery_error ~= nil then
			for _, wake in w.wakes or {} do
				local action = d.actions[wake.action_id]
				if action and action.phase == "ready" and action.claim == nil then
					local removed = wake.action_id; wake.action_id = nil
					config.discard_actions(d, function(key) return key == removed end)
				end
			end
		end
		if observation.state == "exited" and observation.epoch ~= nil and not f.exit then
			f.exit = { at_ms = observation.at_ms, mono_ms = observation.mono_ms, epoch = observation.epoch, state = "exited" }
		end
		-- Recovery can retire ownership without a native-stop record; reappearance still fences successors.
		if retired_coordinator(n, w) and table.find({ "working", "idle", "waiting-input" }, event.native_state) then
			if not w.restored or w.restored.reconciled then w.restored = { at_ms = observation.at_ms, state = event.native_state } end
		elseif w.restored and not w.restored.reconciled and event.native_state == "exited" then
			w.restored.reconciled = "observed_exit"
		end
		local native_gate
		for _, g in d.gates or {} do if g.worker_id == w.worker_id and g.kind == "native_input" and gate_open(g) then native_gate = g end end
		if (event.native_state == "waiting-input" or event.delivery_error ~= nil) and not native_gate
			and (not previous or previous.state ~= observation.state or previous.delivery_error ~= observation.delivery_error) then
			local _, err = new_gate(d, w, "native_input", "This exact pane needs native input or authentication. Open it and act there, then recheck; ORCH+ never answers its prompt.",
				{ { id = "recheck", label = "I resolved this — recheck" } }, {}, clock)
			if err then return nil, err end
		elseif native_gate and native_gate.recheck and event.native_state ~= "unknown" and event.native_state ~= "waiting-input" and event.delivery_error == nil then
			native_gate.phase = "superseded"; native_gate.revision += 1; settle_entries(w, "gate_id", native_gate.id)
		end
		answer = result("observation_recorded")
		if event.observation_seq then f.observation_cursor = { seq = event.observation_seq, event = clone(event) } end
	elseif event.command == "answer" or event.command == "cancel_gate" or event.command == "recheck_gate" then
		local g = if id(event.gate_id) then (d.gates or {})[event.gate_id] else nil
		local w = if g then d.workers[g.worker_id] else nil
		if not g or not w or g.logical_session_id ~= event.orch_session_id or g.revision ~= event.gate_revision or not pos(event.gate_revision)
			or w.worker_generation ~= g.worker_generation or not equal(control_origin(w), event.origin) or not equal(w.pane_binding, g.pane_binding) then
			return fail("stale_gate", "Gate revision, recipient generation or admitted owner binding changed.")
		end
		if g.kind == "quota_fallback" and event.command ~= "recheck_gate" then
			-- Host-consumed one-action decision: never delivered to a worker, never edits Config. A
			-- rollover-time fallback sits on the running predecessor and applies to this rollover's successor only.
			local rollover = nil
			for _, candidate_rollover in d.rollovers or {} do
				if candidate_rollover.quota and candidate_rollover.quota.gate and candidate_rollover.quota.gate.gate_id == g.id then rollover = candidate_rollover end
			end
			local q = if rollover then rollover.quota else w.routing
			local binding = if q then q.gate else nil
			if not binding or binding.gate_id ~= g.id or (not rollover and q.phase ~= "gated") or not gate_open(g) then return fail("stale_gate", "This fallback proposal is no longer current.") end
			if event.command == "cancel_gate" then
				g.phase = "cancelled"; g.revision += 1; settle_entries(w, "gate_id", g.id); q.gate = nil
				if rollover then
					q.rejected = { policy_digest = binding.policy_digest, to = clone(binding.to), needs = binding.denied, gate_id = g.id }; q.approval = nil
				else
					remember_decision(d, w, "held", { candidates = q.candidates, reason = { code = "fallback_cancelled", message = "Owner cancelled the fallback proposal; the work stays held. Refresh capacity or cancel the work." } },
						policy(d, w.logical_session_id), stamp(clock).at_ms)
				end
				answer = result("gate_cancelled")
			else
				local p, now = policy(d, w.logical_session_id), stamp(clock).at_ms
				if not config.take_answer(g, event, now) then return fail("invalid_choice", "Choose approve or reject for this exact fallback proposal.") end
				g.phase = "resolved"; settle_entries(w, "gate_id", g.id); q.gate = nil
				if event.choice_id == "approve" then
					local e, c = current_evidence(d, w.logical_session_id), d.catalogs[w.logical_session_id]
					local row
					for _, candidate_row in (if c then c.records else {}) do if candidate_row.id == binding.to.id and candidate_row.revision == binding.to.revision then row = candidate_row end end
					local assessed = if e then quota.assess(e, binding.to.id, binding.to.revision, p, now) else nil
					if not p.quota_routing or quota.policy_digest(p) ~= binding.policy_digest or not c or c.revision ~= binding.catalog_revision or not e
						or e.revision ~= binding.evidence_revision or not row or not row.eligible or row.enabled ~= true
						or not quota.location_matches(row, { requested = { id = w.record_id }, cwd = w.cwd, placement = w.placement,
							execution_cwd = w.execution_cwd, presentation = if rollover then "background" else w.presentation,
							scope = if rollover then (if rollover.kind == "coordinator" then "coordinator_rollover" else "worker_rollover") else "initial_dispatch" })
						or ((if rollover then rollover.kind == "coordinator" else q.coordinator) and not table.find(row.capabilities, "coordinator-control-v1")) or not assessed or assessed.status ~= "sufficient" then
						return fail("stale_gate", "Routing policy, catalog or USAGE evidence changed since this fallback was proposed, or the destination is no longer sufficient. Refresh capacity; nothing was approved.")
					end
					if rollover then
						q.approval = { policy_digest = binding.policy_digest, to = clone(binding.to), needs = binding.denied, gate_id = g.id }; q.rejected = nil
						answer = result("fallback_approved", { handover_id = rollover.id, worker_id = w.worker_id })
					else
						local busy = config.concurrency_problem(d, w.logical_session_id, p, { [w.worker_id] = true })
						if busy then return fail(busy.code, busy.message .. " Approve again once a reservation is released; nothing was approved.") end
						w.record_id = row.id; w.record_revision = row.revision; w.cwd = row.cwd; w.placement = row.placement; config.bind_family(d, w)
						local action_id, err = prepare_launch(registry, n, w, q.coordinator, event.request_id, clock, reserve)
						if err then return nil, err end
						q.switched = true; q.needs = binding.denied; q.authority = "owner_gate"; q.authorized_digest = binding.policy_digest; q.selected = { id = row.id, revision = row.revision }
						remember_decision(d, w, "selected", { record = row, candidates = q.candidates, reason = { code = "owner_fallback", message = "Owner approved " .. row.id .. " for this work only (gate " .. g.id .. ")." } }, p, now)
						reserve_slot(d, w, n.revision, now)
						local _, problem = append(d, w, "routing", "Owner approved quota fallback to " .. row.id .. " for " .. w.work_id .. " only.", clock); if problem then return nil, problem end
						answer = result("fallback_approved", { worker_id = w.worker_id, action_id = action_id })
					end
				elseif rollover then
					q.rejected = { policy_digest = binding.policy_digest, to = clone(binding.to), needs = binding.denied, gate_id = g.id }; q.approval = nil
					answer = result("fallback_rejected", { handover_id = rollover.id, worker_id = w.worker_id })
				else
					remember_decision(d, w, "held", { candidates = q.candidates, reason = { code = "fallback_rejected", message = "Owner rejected the proposed fallback; the work stays held. Refresh capacity or cancel the work." } }, p, now)
					local _, problem = append(d, w, "routing", "Owner rejected quota fallback for " .. w.work_id .. "; work held.", clock); if problem then return nil, problem end
					answer = result("fallback_rejected", { worker_id = w.worker_id })
				end
			end
		elseif config.GATE_ANSWERS[g.kind] and event.command ~= "recheck_gate" then
			local answered, err = config.GATE_ANSWERS[g.kind](registry, n, w, g, event, clock, reserve)
			if err then return nil, err end
			answer = answered
		elseif (g.kind == "loop_cap" or g.kind == "stale_claim") and event.command ~= "recheck_gate" then
			-- Host-consumed: a loop_cap answer resets (allow_more) or keeps stopping (stop) exactly the
			-- loop that opened it; a stale_claim answer only records the owner's choice and never
			-- changes the claim (open_recovery reveals the window's existing recovery guide).
			if not gate_open(g) then return fail("stale_gate", "This gate is no longer current.") end
			local loop = if g.kind == "loop_cap" then loops.for_gate(d, g.id) else nil
			if event.command == "cancel_gate" then
				g.phase = "cancelled"; g.revision += 1; settle_entries(w, "gate_id", g.id)
				if loop then loop.state = "stopped"; loop.gate_id = nil end
				answer = result("gate_cancelled")
			else
				if not config.take_answer(g, event, stamp(clock).at_ms) then return fail("invalid_choice", "Choose an option from this exact question.") end
				g.phase = "resolved"; settle_entries(w, "gate_id", g.id)
				if loop then
					if event.choice_id == "allow_more" then loop.count = 0; loop.state = nil else loop.state = "stopped" end
					loop.gate_id = nil
				end
				answer = result(g.kind .. "_answered", { gate_id = g.id, choice_id = event.choice_id })
			end
		elseif event.command == "answer" then
			if g.kind == "native_input" then return fail("recheck_only", "Native input/authentication requires owner action in its exact pane, then observation-only recheck.") end
			if g.phase ~= "pending" or not id(event.choice_id) or not str(event.answer, 32768) then return fail("stale_gate", "Only an unanswered exact gate revision accepts one bounded decision.") end
			if not config.take_answer(g, event, stamp(clock).at_ms) then return fail("invalid_choice", "Choose an option from this exact question.") end
			g.phase = "answered"
			local _, err = append(d, w, "answer", event.answer, clock, { state = "pending", gate_id = g.id }); if err then return nil, err end
			-- An approved coordinator proposal executes once in this same commit through its
			-- Contract E execution record (Task 5A); a deferred effect stays pending for a later commit.
			local extra: any = { gate_id = g.id }
			if g.kind == "coordinator_proposal" and event.choice_id == "approve" then
				local message = config.execute_proposal(registry, n, g.id, event, clock, reserve)
				local executed = n.dispatch.gates[g.id].execution
				extra.execution = clone(executed)
				if executed then
					extra.review_id = executed.effect_ref:match("^review:(.+)$")
					if executed.state ~= "done" then extra.review_note = message end
				end
			end
			answer = result("gate_answered", extra)
		elseif event.command == "cancel_gate" then
			if not gate_open(g) then return finish_command(n, event, result("no_progress")) end
			g.phase = "cancelled"; g.revision += 1
			g.delivery_uncertain = g.delivery ~= nil and not g.delivery.acknowledged
			if not g.delivery_uncertain then settle_entries(w, "gate_id", g.id) end
			answer = { ok = true, code = "gate_cancelled", message = if g.delivery_uncertain then "Cancelled locally; the committed immutable decision may still arrive. Its outbox/ACK remain retained." else "Gate cancelled before a decision outbox was issued." }
		else
			if not gate_open(g) then return finish_command(n, event, result("no_progress")) end
			g.recheck = stamp(clock); flow(w).last_poll = nil; flow(w).empty_read = nil
			answer = result("gate_recheck_requested")
		end
		if event.command == "answer" and g.answer and d.workers[w.worker_id] == w then
			local question = table.clone(g); question.revision = event.gate_revision
			local obligation, err = rulings.create(n.authority_namespace, w, question, d.plans or {})
			if err then return nil, err end
			g.ruling = obligation
			if obligation then d.gates[g.id] = g end
		end
	elseif event.command == "capacity" then
		-- Window-normalized USAGE evidence (quota.normalize), bound to the current catalog join.
		local e, c, now = event.capacity, d.catalogs[event.orch_session_id], stamp(clock).at_ms
		if not quota.valid_evidence(e) then return fail("invalid_capacity", "Capacity evidence must be the bounded normalized USAGE v1 projection.") end
		if not c or e.namespace ~= c.namespace or e.host_key ~= c.host_key or e.config_revision ~= c.config_revision then
			return fail("catalog_changed", "Capacity evidence was normalized against a different SPAWN catalog join; refresh the catalog and capacity.")
		end
		for _, r in e.records do
			local known = false
			for _, row in c.records do if row.id == r.id and row.revision == r.revision then known = true end end
			if not known then return fail("catalog_changed", "Capacity evidence names a record/revision absent from the current catalog page.") end
		end
		if e.expires_at_ms <= now or e.validated_at_ms > now + quota.CLOCK_SKEW_MS or now - e.validated_at_ms > 120000 then
			return fail("capacity_expired", "USAGE evidence must be validated current and unexpired when recorded. Refresh capacity.")
		end
		d.capacity = d.capacity or {}; d.capacity[event.orch_session_id] = clone(e)
		local err = reroute(registry, n, event, clock, reserve); if err then return nil, err end
		answer = result("capacity_recorded", { revision = e.revision })
	elseif event.command == "cancel_work" then
		-- Owner withdrawal of unissued, held/gated or positively refused startup work.
		-- An uncertain candidate first needs exact current SPAWN proof of nonexecution.
		-- Nothing native is stopped, retried or re-sent; a provisioned unused mailbox
		-- retires through its existing path (w.withdrawn retains the consumed evidence).
		local w = d.workers[event.worker_id]
		if not w or w.logical_session_id ~= event.orch_session_id or n.sessions[event.orch_session_id].admitted ~= true then
			return fail("worker_unbound", "Current paired admission is required before withdrawing this session's pre-effect work.")
		end
		for _, gate in d.gates do if gate.worker_id == w.worker_id and (gate.ruling or gate.ruling_delivery) then return fail("ruling_pending", "Finish the existing document obligation before withdrawing its worker.") end end
		local fenced_key, fenced = withdrawal_candidate(d, w)
		local evidence = event.query_bytes ~= nil or event.response_bytes ~= nil
		local allocation_verified = false
		if not w.mailbox_handle and w.mailbox_allocation ~= "none" and (w.mailbox_allocation == "possible" or w.launch_refused
			or (fenced and fenced.request.op == "mailbox_provision" and fenced.request_bytes ~= nil)) then
			if fenced and status_required(fenced) and not w.launch_refused then
				return fail("allocation_required", "Automatic exact allocation observation must finish before settling this uncertain startup outcome. Allocation metadata does not itself cancel an unknown effect.")
			end
			if not evidence then return fail("allocation_required", "Read this exact generation's retained SPAWN allocation before cancelling; a rejected provision may still own an intent.") end
			local problem = config.observe_allocation(n, w, event)
			if problem then return nil, problem end
			allocation_verified = true
		end
		local owner = if w.coordinator_owner_id then n.sessions[event.orch_session_id].orchestrator else nil
		local bound = owner and owner.owner_id == w.coordinator_owner_id and owner.generation == w.coordinator_generation
		local unresolved = if bound and (owner.phase ~= "reserved" or owner.pending_executors ~= 0)
			then "This work's coordinator reservation is " .. owner.phase .. "; recover that orchestrator owner first. Nothing was cancelled." else nil
		-- Retires the provisioned, never-used mailbox through the exact retirement path on this route.
		-- The worker stays visible until SPAWN confirms `retired` (then it is reclaimed like any retired
		-- generation); a coordinator start keeps its reservation until then. Returns a refusal or nil.
		local function retire_unused(): any?
			if unresolved then
				local _, problem = fail("coordinator_unresolved", unresolved)
				return problem
			end
			local request = common(d, event.origin, event.controller_pane, "mailbox_retire"); be(w, request)
			request.handle = w.mailbox_handle; request.expected_generation = w.worker_generation
			request.mode = "retire"; request.settlement_revision = n.revision; request.report_floor = w.compacted_floor
			request.report_chain_sha256 = w.compacted_chain; request.reply_floor = w.reply_floor; request.grant_id = next_id(d, "withdraw-")
			if not add(d, request, w.worker_id) then
				local _, problem = fail("oversize", "Mailbox retirement request exceeds the bridge bound; nothing was cancelled.")
				return problem
			end
			w.mailbox_retire_action_id = request.action_id
			w.retirement_refused = nil
			-- These decisions concern work proved unissued/rejected, not a running native task.
			-- Retain delivery/ruling obligations; only undecided, effect-free launch gates can close.
			for _, gate in d.gates or {} do if gate.worker_id == w.worker_id and gate_open(gate)
				and gate.delivery == nil and gate.ruling == nil and gate.execution == nil then
				gate.phase = "cancelled"; gate.revision += 1; settle_entries(w, "gate_id", gate.id)
			end end
			w.launch_gates = nil
			w.reason = { code = "withdrawal_retiring", message = "Owner cancelled this never-launched work. Its unused mailbox is being retired; the worker is removed once SPAWN confirms retirement." }
			answer = result("withdrawal_retiring", { worker_id = w.worker_id, work_id = w.work_id, action_id = request.action_id })
			return nil
		end
		-- A retirement already issued for this withdrawal: a pending or uncertain one never re-issues;
		-- none (a revoked authorization or continuation released its marker) or a definite refusal
		-- issues exactly one fresh retirement.
		local function retire_again(): any?
			local prior = if w.mailbox_retire_action_id then d.actions[w.mailbox_retire_action_id] else nil
			if prior then
				local _, problem = fail("retirement_unresolved", "This work's mailbox retirement is " .. prior.phase .. "; inspect its exact retained outcome. No second retirement is issued.")
				return problem
			end
			return retire_unused()
		end
		if w.startup_cancelling or config.failed_startup(n, w) then
			if evidence or not config.failed_startup_cleanup(n, w) then
				return fail("startup_unproved", "Failed startup cleanup requires a retired, never-activated coordinator and its original pane identity; restored or consumed generations stay retained.")
			end
			for _, a in d.actions do if a.worker_id == w.worker_id then return fail("retirement_unresolved", "Settle this startup's exact pending operation before cleanup; no launch, stop or token is replaced.") end end
			w.startup_cancelling = true
			local problem = retire_again(); if problem then return nil, problem end
			w.reason = { code = "startup_retiring", message = "Checking this failed startup before removal. SPAWN must freshly prove its exact original native pane absent or exited and its producer journal unused before any retirement; unknown or live evidence grants nothing." }
			answer.code = "startup_retiring"
		elseif w.enrol_delivery and (w.enrol_cancelling or w.phase == "awaiting_acceptance") then
			if evidence or w.accepted_event or w.accepted_seq ~= 0 or w.reply_seq ~= 0 or w.stop_action_id then return fail("enrolment_consumed", "Enrollment may have been consumed; settle its exact reports without stopping the existing conversation.") end
			if w.mailbox_retired then return finish_command(n, event, result("worker_retired", { worker_id = w.worker_id })) end
			for _, a in d.actions do if a.worker_id == w.worker_id then return fail("retirement_unresolved", "Settle this enrollment's exact pending operation before cancellation. No token was replaced.") end end
			w.enrol_cancelling = true
			local problem = retire_again(); if problem then return nil, problem end
			w.reason = { code = "enrolment_revoking", message = "Revoking only this enrollment capability. The existing conversation is not stopped; a consumed or uncertain capability remains fenced." }
		elseif w.withdrawn ~= nil then
			-- Withdrawn fenced work: its fenced request was already proven unexecuted when the owner
			-- first cancelled, and that evidence was consumed.
			if evidence then return fail("invalid_command", "This work's fenced request was already proven unexecuted; cancelling again needs no status evidence.") end
			if w.mailbox_retired then return finish_command(n, event, result("worker_retired", { worker_id = w.worker_id })) end
			local problem = retire_again(); if problem then return nil, problem end
		elseif not fenced and launch_rejected(d, w) then
			-- SPAWN definitively rejected the launch/adoption ask after provisioning; a refused
			-- retirement keeps its outcome and may be cancelled again.
			if evidence and not allocation_verified then return fail("invalid_command", "SPAWN's retained launch rejection is terminal; withdrawal needs no status evidence.") end
			if w.mailbox_retired then return finish_command(n, event, result("worker_retired", { worker_id = w.worker_id })) end
			local problem = retire_again(); if problem then return nil, problem end
		elseif fenced and w.mailbox_handle ~= nil then
			-- The exact current refusal is consumed into the worker's live mailbox-retirement obligation.
			if not allocation_verified and (status_required(fenced) or evidence) then
				if not evidence then return fail("status_required", "SPAWN received this fenced " .. fenced.request.op .. " request; its retained SPAWN status must be read first. Nothing was cancelled.") end
				local problem = unexecutable_in_spawn(n, fenced, event); if problem then return nil, problem end
			end
			for key, a in d.actions do
				if a.worker_id == w.worker_id and key ~= fenced_key and a.phase == "ready" and a.claim == nil then d.actions[key] = nil end
			end
			local problem = retire_unused(); if problem then return nil, problem end
			w.phase = "held"
			w.withdrawn = { op = fenced.request.op, action_id = fenced_key, evidence = if fenced.request_bytes then "pre_effect_refusal" else "unissued" }
			config.release_executor(n.sessions[event.orch_session_id], w, fenced); config.consume_action(d, fenced)
		else
			if fenced or (w.launch_refused and not w.mailbox_handle) then
				if fenced and not allocation_verified and (status_required(fenced) or evidence) then
					if not evidence then return fail("status_required", "SPAWN received this fenced " .. fenced.request.op .. " request; its retained SPAWN status must be read first. Nothing was cancelled.") end
					local problem = unexecutable_in_spawn(n, fenced, event); if problem then return nil, problem end
				end
				-- A fenced coordinator start releases its never-bound orchestrator reservation in this commit.
				if bound then
					if unresolved then return fail("coordinator_unresolved", unresolved) end
					owner.managed_worker_id = nil
					local released, response = reserve(n, { kind = "release_coordinator", request_id = "withdraw-release-" .. w.worker_id, orch_session_id = w.logical_session_id,
						expected_owner_id = w.coordinator_owner_id, expected_generation = w.coordinator_generation, quiescent = true,
						authority_namespace = n.authority_namespace, expected_revision = n.revision }, clock)
					if not released then return nil, response end
					n = released; d = n.dispatch
				end
				for key, a in d.actions do if a.worker_id == w.worker_id then d.actions[key] = nil end end
			else
				if (not w.project_held and (not w.routing or w.routing.bound or w.routing.phase == "selected")) or w.mailbox_handle ~= nil or evidence then
					return fail("worker_unbound", "Only held or gated routed work that was never provisioned, or work whose provision, launch or adoption continuation fenced as unexecuted, can be cancelled.")
				end
				for _, a in d.actions do if a.worker_id == w.worker_id then return fail("settlement_pending", "This work has retained effects; it cannot be cancelled here.") end end
			end
			for key, g in d.gates or {} do if g.worker_id == w.worker_id then d.gates[key] = nil end end
			for sid, p in d.policies or {} do
				for i = #p.excluded_workers, 1, -1 do
					if p.excluded_workers[i] == w.worker_id then
						table.remove(p.excluded_workers, i)
						local cursor = (d.command_cursors or {})[sid]
						if cursor then cursor.policy_revision = n.revision end
					end
				end
			end
			config.restore_enrol_association(d, w)
			d.workers[w.worker_id] = nil
			local roster = d.catalogs[event.orch_session_id]
			if (d.catalog_scans or {})[event.orch_session_id] == false and roster and roster.namespace == (n.compatibility or {}).spawn_namespace then config.prune_family_orphans(n, roster) end
			answer = result("work_cancelled", { worker_id = event.worker_id, work_id = w.work_id })
		end
	elseif config.SOURCE_COMMANDS[event.command] then
		-- Work sources (Checkpoint 6): non-operator intake commands; the host reads files itself.
		local handled, err = config.SOURCE_COMMANDS[event.command](registry, n, event, clock, reserve)
		if err then return nil, err end
		answer = handled
	elseif event.command == "catalog" then
		local request = common(d, event.origin, event.controller_pane, "catalog")
		if event.bytes ~= nil then request.cursor = event.bytes end
		local a = add(d, request); if not a then return fail("oversize", "Catalog request exceeds bridge bound.") end
		answer = result("catalog_queued", { action_id = request.action_id, message = "Agent list requested." })
	elseif event.command == "queue" then
		if not str(event.record_id, 96) or not str(event.prompt, 32768) or event.prompt:find("%S") == nil or not str(event.cwd, 2048)
			or not table.find({ "tab", "split", "replace_if_alone" }, event.placement) or type(event.coordinator) ~= "boolean" then return fail("invalid_task", "Choose a configured record, nonblank task, configured cwd (at most 2048 UTF-8 bytes) and supported placement.") end
		local c = d.catalogs[event.orch_session_id]; local selected
		if c == nil or c.revision ~= event.catalog_revision then return fail("catalog_changed", "Refresh and select the current catalog revision.") end
		for _, row in c.records do if row.id == event.record_id and row.revision == event.record_revision then selected = row end end
		if not selected or not selected.eligible or selected.enabled ~= true then return fail("unsupported_capability", "Selected record is absent, changed, disabled or lacks managed dispatch prerequisites; inspect its capability reasons.") end
		if event.coordinator and (coordinator_rollover(d, event.orch_session_id) or restored_coordinator(d, event.orch_session_id)) then
			return fail("rollover_reserved", "A coordinator rollover owns this session's orchestrator slot, or a restored coordinator is unreconciled; an unrelated start cannot take the reservation.")
		end
		if event.coordinator and (not table.find(selected.capabilities, "coordinator-control-v1") or not table.find(selected.capabilities, "project-start-v1")) then
			return fail("unsupported_capability", "A new coordinator requires prepared coordinator-control-v1 and project-start-v1 helpers. Existing saved preferences and ordinary workers remain valid; prepare the selected bundle before launching it.")
		end
		if event.cwd ~= selected.cwd or event.placement ~= selected.placement then return fail("config_changed", "Task cwd/placement must match the selected configured record; refresh its catalog.") end
		if event.orch_project_id ~= nil and not config.project_ref(d, event.orch_session_id, event.orch_project_id) then return fail("project_changed", "Choose an unfinished project in this orchestration.") end
		if event.presentation ~= nil and not table.find({ "user_new_tab", "coordinator_adjacent", "background" }, event.presentation) then return fail("invalid_task", "Unsupported conversation presentation.") end
		if event.open_conversation ~= nil and (event.open_conversation ~= true or event.coordinator or event.prompt ~= codec.OPEN_CONVERSATION_ASSIGNMENT
			or event.presentation ~= "user_new_tab") then return fail("invalid_task", "Opening a conversation uses only the canonical enrollment assignment in a new tab.") end
		if count(d.workers) >= 32 then return fail("full", "Managed generation capacity is full; no unresolved worker was removed.") end
		local w = config.new_worker(d, event, event.orch_session_id, selected, event.prompt, event.request_id .. ":", if event.coordinator then "coordinator" else "builder")
		if event.coordinator then w.project_start_protocol = 1 end
		if event.execution_cwd ~= nil and (not w.execution_cwd or event.execution_cwd ~= w.execution_cwd) then return fail("repository_unverified", "Execution cwd must equal this project's host-verified checkout.") end
		w.open_conversation = event.open_conversation
		config.bind_family(d, w) -- Declared family of the requested record; recomputed if routing selects another.
		local assignment = config.assign(w, event); if assignment then return nil, assignment end
		-- Typed tasks retain their task text and the applicable built-in review policy.
		w.prompt = if event.open_conversation then codec.OPEN_CONVERSATION_ASSIGNMENT else config.assignment_prompt(d, event.orch_session_id, w.role, event.prompt)
		w.assignment_sha256 = codec.sha256(w.prompt)
		if M.request_size(launch_request(w, string.rep("h", 96))) > codec.DISPATCH.limit then
			return fail("oversize", "Assignment plus immutable launch binding cannot fit the 8192-byte bridge (including a maximum-length mailbox handle); no provisioning was queued.")
		end
		-- Queue-time checkout gates hold a never-provisioned worker until the owner answers them.
		local gate_ids, gate_err
		if not w.open_conversation then gate_ids, gate_err = config.queue_gates(d, w, clock) end
		if gate_err then return nil, gate_err end
		if gate_ids then
			w.launch_gates = gate_ids; d.workers[w.worker_id] = w
			local _, problem = append(d, w, "assignment", w.prompt, clock); if problem then return nil, problem end
			answer = result("task_gated", { worker_id = w.worker_id, work_id = w.work_id, gate_ids = gate_ids,
				message = "Held before launch: answer the checkout gate(s) to launch anyway or cancel. Nothing was provisioned." })
		else
			local launched, err = config.launch(registry, n, w, event, clock, reserve, true); if err then return nil, err end
			answer = launched
		end
	elseif event.command == "enrol" then
		if not str(event.record_id, 96) or not table.find({ "native_ask", "clipboard" }, event.delivery)
			or not pane_binding(event.pane_binding, event.origin) or not config.project_ref(d, event.orch_session_id, event.orch_project_id) then
			return fail("invalid_task", "Enrollment requires the chosen project, current record and exact native pane; delivery adds instructions only, never its old task.")
		end
		local c = d.catalogs[event.orch_session_id]; local selected
		if c == nil or c.revision ~= event.catalog_revision then return fail("catalog_changed", "Refresh and select the current catalog revision.") end
		for _, row in c.records do if row.id == event.record_id and row.revision == event.record_revision then selected = row end end
		if not selected or not selected.eligible or selected.enabled ~= true or not table.find(selected.capabilities, "report-files-v1")
			or (event.delivery == "native_ask" and selected.backend ~= "native-agent") or (event.delivery == "clipboard" and selected.backend == "native-agent") then
			return fail("unsupported_capability", "Native agents receive enrollment only while idle. Terminal providers require one explicitly requested clipboard paste; no PTY typing occurs.")
		end
		for _, other in d.workers do
			local unbound = other.stopped ~= nil or other.mailbox_retired == true
				or (not other.enrol_delivery and other.phase == "held" and other.pane_binding == nil)
			if not unbound and (equal(other.pane_binding, event.pane_binding)
				or equal(other.control_pane_binding, event.pane_binding) or equal(other.adopt_pane_binding, event.pane_binding)) then
				return fail("pane_bound", "This exact pane is already bound to managed worker " .. other.worker_id .. "; it is never adopted twice.")
			end
		end
		local association
		for _, project in d.projects do for key, conversation in project.associations or {} do
			if config.same_conversation(conversation.pane_binding, event.pane_binding) then
				if project.orch_project_id ~= event.orch_project_id then return fail("pane_bound", "Detach this conversation's other project association before enabling coordination here.") end
				association = clone(conversation); project.associations[key] = nil; project.revision += 1
			end
		end end
		if count(d.workers) >= 32 then return fail("full", "Managed generation capacity is full; no unresolved worker was removed.") end
		local w = config.new_worker(d, event, event.orch_session_id, selected, codec.OPEN_CONVERSATION_ASSIGNMENT, event.request_id .. ":", "builder")
		w.adopt_pane_binding = clone(event.pane_binding); w.enrol_delivery = event.delivery; w.execution_cwd = nil; w.presentation = nil; config.bind_family(d, w)
		w.enrol_association = association
		if M.request_size(launch_request(w, string.rep("h", 96))) > codec.DISPATCH.limit then
			return fail("oversize", "Assignment plus immutable adoption binding cannot fit the 8192-byte bridge; nothing was provisioned.")
		end
		local request = common(d, event.origin, event.controller_pane, "mailbox_provision"); be(w, request)
		request.record_id = w.record_id; request.record_revision = w.record_revision; request.capability = "report-files-v1"
		if not add(d, request, w.worker_id) then return fail("oversize", "Provision request exceeds the bridge bound.") end
		d.workers[w.worker_id] = w
		answer = result("enrolment_queued", { worker_id = w.worker_id, work_id = w.work_id, orch_project_id = w.orch_project_id, action_id = request.action_id })
		local _, problem = append(d, w, "assignment", w.prompt, clock); if problem then return nil, problem end
	elseif event.command == "claim" then
		local a = d.actions[event.action_id] -- Mismatch, pause and phase refusals ran before the candidate clone.
		local target = if a.worker_id then d.workers[a.worker_id] else nil
		if a.request.op == "native_wake" then
			if not target or not equal(control_origin(target), event.origin) then return fail("worker_unbound", "Wake requires the current explicit worker route.") end
			refresh(d, target, clock)
			if flow(target).health.native_state ~= "idle" or (flow(target).native and flow(target).native.delivery_error) then
				return fail("worker_not_sendable", "Native wake requires fresh safe-idle evidence; no working/input-waiting agent is interrupted.")
			end
		end
		if a.request.op == "stop" and target and not (settled(target) or config.start_retirement_settled(d, target, a.request.action_id)) then return fail("settlement_pending", "Exact receipt and reply settlement is required before stopping this generation.") end
		if target and target.coordinator_owner_id and restored_coordinator(d, event.orch_session_id) then
			return fail("coordinator_restored", "A retired coordinator pane was observed alive again; coordinator effects are held until it is reconciled.")
		end
		if target and target.startup_cancelling and not config.failed_startup_cleanup(n, target) then
			return fail("startup_unproved", "The original failed startup is restored, consumed or rebound; nothing is retired.")
		end
		-- Quota-routed work: held/stale decisions never claim; a routed launch carries USAGE's
		-- immediately preceding `validate` result for the exact evidence revision it was decided on.
		local capacity_claim: any = nil
		if target and target.routing and (a.request.op == "launch" or a.request.op == "mailbox_provision") then
			local checked, err = routing_claim(d, target, event, a.request.op, clock)
			if err then return nil, err end
			if type(checked) == "table" then capacity_claim = checked end
		elseif event.capacity_validation ~= nil then
			return fail("invalid_command", "Capacity validation applies only to a quota-routed launch claim.")
		end
		-- Effect slots bound concurrently possible effects. A claimed operation of any kind holds
		-- one while it may run, and an uncertain mutating effect keeps holding it. An uncertain
		-- read-only operation (catalog, mailbox_read) has no native, mailbox or registry effect
		-- that a new effect could conflict with; a still-running read is bounded by SPAWN's own
		-- per-host and per-generation executor limits, which refuse before any effect. Its
		-- per-generation exclusivity below is unchanged.
		local active = 0
		for _, held in d.actions do
			if held.phase == "claimed" or (held.phase == "uncertain" and not READ_ONLY_OPS[held.request.op]) then active += 1 end
		end
		if active >= 4 then return fail("full", "Four host effect slots are occupied by running or uncertain effects. Reconcile or settle them before another claim.") end
		if a.worker_id then
			for id, held in d.actions do
				-- An uncertain read never blocks the attachment that supersedes it.
				if id ~= event.action_id and held.worker_id == a.worker_id and (held.phase == "claimed"
					or (held.phase == "uncertain" and not (a.request.op == "attach_worker" and READ_ONLY_OPS[held.request.op]))) then
					return fail("operation_pending", "Another retained effect owns this generation; settle it before claiming this action.")
				end
			end
		end
		-- A capacity recheck's claim continues the action's stale-claim lineage: one gate per action.
		local issue_problem = issue_action(n, a)
		if issue_problem then return nil, issue_problem end
		a.phase = "claimed"; a.claim = { executor = event.executor, epoch = registry.execution_epoch, grant_id = next_id(d, "grant-"), capacity = capacity_claim, claimed_at = stamp(clock),
			stale_gate_id = a.stale_gate_id }
		a.stale_gate_id = nil
		n.sessions[event.orch_session_id].controller.pending_executors += 1
		if target and target.coordinator_owner_id and not config.cleanup_request(n, target, a.request) then
			local owner = n.sessions[event.orch_session_id].orchestrator
			if owner == nil or owner.owner_id ~= target.coordinator_owner_id or owner.generation ~= target.coordinator_generation
				or (owner.phase ~= "reserved" and owner.phase ~= "running" and owner.phase ~= "retiring"
					and not (owner.phase == "uncertain" and a.request.op == "attach_worker")) then return fail("owner_mismatch", "Coordinator reservation is no longer executable.") end
			if owner.phase == "retiring" and not table.find({ "accept", "mailbox_read", "mailbox_publish_ack", "mailbox_publish_reply", "mailbox_retire", "stop", "native_wake", "attach_worker" }, a.request.op) then
				return fail("coordinator_retiring", "Retirement permits settlement only, never fresh launch effects.")
			end
			if a.request.op == "stop" and (not (settled(target) or config.start_retirement_settled(d, target, a.request.action_id)) or owner.pending_executors ~= 0 or M.unresolved(registry, target.logical_session_id, owner.owner_id)) then
				return fail("settlement_pending", "Final watermark, replies and unresolved executors must settle before native stop.")
			end
			owner.pending_executors += 1
		end
		answer = result("effect_granted", { action_id = event.action_id, claim = a.claim })
	elseif event.command == "spawn_claimed" then
		local a = d.actions[event.action_id]
		local witness = { spawn_namespace = event.spawn_namespace, claim_nonce = event.claim_nonce }
		if a.claim.spawn_claim ~= nil then
			a.phase = "uncertain"
			local w = if a.worker_id then d.workers[a.worker_id] else nil
			if w then note_reason(w, { code = "claim_mismatch", message = "SPAWN restored or changed its irreversible claim; the first witness remains authoritative. No second effect is permitted." }) end
			answer = result("claim_mismatch")
		else
			a.claim.spawn_claim = witness
			answer = result("spawn_claim_committed")
		end
	elseif event.command == "result" or event.command == "lost" then
		local a = d.actions[event.action_id] -- Stale grants and exact duplicates answered before the candidate clone.
		if event.command == "lost" then a.phase = "uncertain"; answer = result("effect_uncertain")
		else
			local body, err = protocol.decode_response(event.response_bytes, a.request); if err then return nil, err end
			if body.spawn_namespace ~= (n.compatibility or {}).spawn_namespace then return fail("stale_authority", "The response belongs to another SPAWN namespace.") end
			local applied, problem = complete(n, a, body, clock, event.response_bytes); if problem then return nil, problem end
			a.response_bytes = event.response_bytes; a.response = body; a.response_grant = a.claim.grant_id; answer = applied
			if a.phase == "complete" or a.phase == "backpressure" then
				local w = if a.worker_id then d.workers[a.worker_id] else nil
				local owner = n.sessions[event.orch_session_id].orchestrator
				config.release_executor(n.sessions[event.orch_session_id], w, a)
				if a.phase == "complete" then config.consume_action(d, a) end
				if w and w.mailbox_retired and owner and owner.owner_id == w.coordinator_owner_id then
					owner.owner_active = false
					-- A withdrawn never-launched coordinator start was never bound: its retired mailbox ends the reservation.
					if (launch_rejected(d, w) or w.withdrawn ~= nil) and owner.phase == "reserved" and owner.managed_worker_id == w.worker_id then owner.managed_worker_id = nil end
					local released, response = reserve(n, { kind = "release_coordinator", request_id = "normal-release-" .. w.worker_id,
						orch_session_id = w.logical_session_id, expected_owner_id = w.coordinator_owner_id, expected_generation = w.coordinator_generation, quiescent = true,
						authority_namespace = n.authority_namespace, expected_revision = n.revision }, clock)
					if released then n = released; d = n.dispatch; answer = result("coordinator_retired", { worker_id = w.worker_id })
					else w.reason = { code = response.code, message = response.message } end
				end
				if w and owner and a.request.op == "attach_worker" and a.phase == "complete" then resume_attached_coordinator(n, d, w, owner) end
			end
		end
	elseif event.command == "read_missing" then
		-- SPAWN's registry answered `missing` for this exact retained read: never staged, refused
		-- before staging, or completed and compacted. Either way nothing it read was applied here
		-- (see resolve_read). Mutating effects keep their strict reconciliation.
		local a = d.actions[event.action_id]
		if not a or a.phase ~= "uncertain" or not READ_ONLY_OPS[a.request.op] or not a.claim or a.claim.executor ~= event.executor
			or a.claim.grant_id ~= event.grant_id or not equal(execution_origin(d, a), event.origin) then
			return fail("stale_claim", "Only an uncertain retained read on this continued route can be resolved from SPAWN's missing status.")
		end
		local query = codec.decode_dispatch_request(event.query_bytes)
		if not query or query.op ~= "status" or query.target_request_id ~= a.request.request_id
			or query.target_request_serial ~= a.request.request_serial or query.authority_namespace ~= a.request.authority_namespace
			or query.admission_seq ~= a.request.admission_seq or not equal(query.origin_binding, event.origin) then
			return fail("binding_mismatch", "SPAWN status evidence must name this exact retained read.")
		end
		local body, err = protocol.decode_response(event.response_bytes, query); if err then return nil, err end
		if body.spawn_namespace ~= (n.compatibility or {}).spawn_namespace then return fail("stale_authority", "The read observation belongs to another SPAWN namespace.") end
		if body.status ~= "missing" then return fail("status_not_missing", "SPAWN's status does not report this read missing; only its retained outcome or attachment settles it.") end
		resolve_read(n, a, "read_lost_no_effect", "SPAWN has no record of this read (never staged, refused before staging, or compacted); nothing it read was applied, so the worker re-reads from its durable cursor.",
			codec.sha256(event.response_bytes))
		answer = result("read_resolved", { action_id = event.action_id, worker_id = a.worker_id })
	elseif event.command == "retry" then
		local a = d.actions[event.action_id]
		if config.start_for_action(d, a) then return fail("retry_refused", "START delivery uses only its scoped project_start_retry command; generic retry cannot create another grant.") end
		if event.trigger ~= nil and event.trigger ~= "owner" then return fail("invalid_command", "Retry trigger is the owner control; automatic capacity rechecks carry none.") end
		if not a or a.phase ~= "backpressure" or not equal(a.request.origin_binding, event.origin)
			or a.request.controller_pane ~= event.controller_pane or not a.response or a.response.status ~= "full"
			or not retryable_full(a.response.payload) then
			return fail("retry_refused", "Only the exact retained, definitively unexecuted full outcome may be rechecked. Uncertain effects cannot retry.")
		end
		-- Owner retries of a worker-bound action are a capped loop (Contract L); automatic capacity
		-- rechecks stay the window's time-bounded code-only wait. Worker-less reads have no gate owner.
		local w = if a.worker_id then d.workers[a.worker_id] else nil
		local cap = if w then policy(d, w.logical_session_id).loop_cap else 0
		-- An owner "stop" answer is final for this loop: no resubmission and no new gate.
		if w and a.retry_loop and a.retry_loop.state == "stopped" then
			return fail("loop_stopped", "The owner stopped retries of this action at the loop cap; it stays unexecuted. Cancel the work to end it.")
		end
		-- Only the owner's own retry counts toward or trips the cap; automatic rechecks neither consume it nor open its gate.
		local owner_retry = event.trigger == "owner"
		-- An open owner gate holds every resubmission: only the owner's answer (allow more) clears it.
		if w and not owner_retry and a.retry_loop and a.retry_loop.state ~= nil then
			return fail("loop_gated", "This action's retry loop is waiting for the owner's answer; it is not resubmitted automatically.")
		end
		if w and owner_retry and loops.trips(a.retry_loop, cap) then
			local loop = a.retry_loop
			local g, err = loops.open(d, w, loop, "full_retry", event.action_id, "Owner retry of full backpressure reached " .. tostring(loop.count)
				.. " attempts; last error: full:" .. a.response.payload.resource .. ". Action " .. event.action_id .. " (" .. a.request.op
				.. ") stays unexecuted and is not resubmitted. Allow more owner retries or keep it stopped.", cap, clock, true)
			if err then return nil, err end
			answer = result("loop_capped", { gate_id = g.id, action_id = event.action_id })
		else
			if w then a.retry_loop = a.retry_loop or { count = 0 }; if owner_retry then a.retry_loop.count += 1 end end
			local request = clone(a.request)
			for _, key in { "authority_namespace", "admission_seq", "request_serial", "next_request_serial", "settled_before", "consumed" } do request[key] = nil end
			if request.op ~= "launch" and request.op ~= "adopt" and request.op ~= "enrol" then request.request_id = next_id(d, "request-") end
			request.action_id = next_id(d, "action-")
			-- Mailbox settlement grants bind the complete immutable request.
			-- A fresh pre-effect retry cannot reuse the refused request's grant.
			if request.op == "mailbox_retire" then request.grant_id = next_id(d, request.mode .. "-") end
			local retry = add(d, request, a.worker_id)
			if not retry then return fail("oversize", "The fresh pre-effect retry cannot fit the canonical bridge.") end
			retry.stale_gate_id = a.claim.stale_gate_id; retry.retry_loop = clone(a.retry_loop); retry.retry_count = (a.retry_count or 0) + 1
			if request.op == "launch" or request.op == "adopt" or request.op == "enrol" then retry.retry_after_serial = a.request.request_serial end
			if retry.stale_gate_id and d.gates[retry.stale_gate_id] then
				d.gates[retry.stale_gate_id].evidence[1] = "action:" .. request.action_id
			end
			local worker = if a.worker_id then d.workers[a.worker_id] else nil
			if worker then
				if worker.launch_action_id == a.request.action_id then worker.launch_action_id = request.action_id end
				if worker.stop_action_id == a.request.action_id then worker.stop_action_id = request.action_id end
				if worker.mailbox_retire_action_id == a.request.action_id then worker.mailbox_retire_action_id = request.action_id end
				for _, wake in worker.wakes or {} do if wake.action_id == a.request.action_id then wake.action_id = request.action_id end end
			end
			config.consume_action(d, a)
			answer = result("retry_queued", { action_id = request.action_id })
		end
	elseif event.command == "readback_publication" then
		-- Plan §mailbox: an uncertain publication "requires readback before retry". ACK and reply
		-- objects are immutable, deterministic bytes, so the retained attempt is resolved and the
		-- outbox re-issues the exact same bytes on the current route. SPAWN's journal still holds the
		-- uncertain write: it reads back first and republishes those bytes only if absent; equal bytes
		-- are idempotent and a late earlier child can only publish the same bytes. Native effects
		-- (launch, ask, wake, stop) never take this path.
		local a = d.actions[event.action_id]
		if config.start_for_action(d, a) then return fail("readback_refused", "Uncertain START publication permits status inspection only; it is never republished through generic recovery.") end
		local w = if a and a.worker_id then d.workers[a.worker_id] else nil
		if not a or a.phase ~= "uncertain" or (a.request.op ~= "mailbox_publish_ack" and a.request.op ~= "mailbox_publish_reply") or not w then
			return fail("readback_refused", "Only an uncertain ACK or reply publication may be read back and re-published; native and other effects are never repeated.")
		end
		-- Readback only resolves the attempt; the outbox re-issue still needs the worker's bound
		-- route (poll). On the continued controller route it is therefore the individual
		-- settlement reattachment waits for, so an unrecorded publication never deadlocks reload.
		if w.frozen or w.mailbox_retired then return fail("readback_refused", "A frozen or retired generation keeps its retained publication uncertainty.") end
		if a.response and type(a.response.payload) == "table" and a.response.payload.wake_status ~= nil then
			return fail("readback_refused", "SPAWN already confirmed this publication; only its native wake is uncertain, and a native ask is never repeated.")
		end
		local obligation = false
		if a.request.op == "mailbox_publish_ack" then
			for _, receipt in w.receipts do if receipt.publish and receipt.bytes and codec.sha256(receipt.bytes) == a.request.ack_sha256 then obligation = true end end
		else
			local reply = w.replies[tostring(a.request.reply_seq)]
			obligation = reply ~= nil and not reply.acknowledged and reply.message_id == a.request.message_id and reply.part == (if a.request.part == "manifest" then #reply.frames.chunks + 1 else a.request.index)
		end
		if not obligation then return fail("readback_refused", "The publication obligation for these exact bytes is no longer outstanding.") end
		config.release_executor(n.sessions[event.orch_session_id], w, a)
		config.consume_action(d, a)
		if w.reason and (w.reason.code == "effect_uncertain" or w.reason.code == "target_unavailable") then w.reason = nil end
		answer = result("readback_queued", { action_id = event.action_id, worker_id = w.worker_id })
	elseif event.command == "poll" then
		local w = d.workers[event.worker_id]
		if w and w.startup_cancelling then return fail("retirement_unresolved", "Settle the exact failed-startup retirement before reading further reports.") end
		if w and w.enrol_cancelling and (w.mailbox_retire_action_id ~= nil or not w.retirement_refused) then return fail("retirement_unresolved", "Settle the exact enrollment revocation before reading further reports; the existing conversation is unchanged.") end
		if config.cleanup_request(n, w, { op = "mailbox_retire", mode = "retire", origin_binding = event.origin }) then
			if pending(d, w) or not (settled(w) or config.start_retirement_settled(d, w)) then return fail("settlement_pending", "The stopped prior generation still has current obligations; none is discarded.") end
			local request = mailbox_request(n, d, w, "retire")
			request.origin_binding = clone(event.origin); request.controller_pane = event.controller_pane; request.controller_generation = event.origin.owner_generation
			if not add(d, request, w.worker_id) then return fail("oversize", "The exact stopped-worker cleanup request cannot fit the bridge.") end
			return finish_command(n, event, result("mailbox_retirement_queued", { action_id = request.action_id, worker_id = w.worker_id }))
		end
		if w == nil or not equal(control_origin(w), event.origin) or not w.mailbox_handle or not w.pane_binding or w.continuation_required then return fail("worker_unbound", "Worker requires its explicitly continued current mailbox/native route.") end
		if w.coordinator_owner_id and not coordinator(n, w) then return fail("owner_mismatch", "Only the current coordinator generation may settle; restored owners require inspected recovery.") end
		resume_revoked(d, w)
		if w.mailbox_retired then
			if not w.coordinator_owner_id then return finish_command(n, event, result("worker_retired", { worker_id = w.worker_id })) end
			local owner = coordinator(n, w)
			if not owner or pending(d, w) then return fail("settlement_pending", "Retired mailbox still has unresolved authority effects.") end
			owner.owner_active = false
			local released, response = reserve(n, { kind = "release_coordinator", request_id = "normal-release-" .. w.worker_id,
				orch_session_id = w.logical_session_id, expected_owner_id = w.coordinator_owner_id, expected_generation = w.coordinator_generation, quiescent = true,
				authority_namespace = n.authority_namespace, expected_revision = n.revision }, clock)
			if not released then return nil, response end
			n = released; d = n.dispatch
			answer = result("coordinator_retired", { worker_id = w.worker_id })
			advance_rollovers(n, event, clock, reserve); config.advance_proposals(registry, n, event, clock, reserve); config.advance_reviews(n, event, clock); advance_landing(n, event, clock); config.advance_deploys(n, event, clock); config.advance_sources(registry, n, event, clock, reserve)
			config.close_stale_starts(n)
			sync_reservations(n, clock)
			remember(n.dispatch, event, answer, n.revision)
			return n, answer
		end
		refresh(d, w, clock)
		local f = flow(w)
		local continuation = continuation_due(d, w, f.health.native_state == "idle" and not (f.native and f.native.delivery_error))
		local watermark = event.bytes == "watermark" and not continuation
		if pending(d, w, watermark) then return fail("operation_pending", "A retained operation owns this generation; recheck unexecuted backpressure or reconcile uncertain effects first.") end
		local request
		local accept_held = w.accept_pending and w.phase == "held" and not revoked_authorization(w.reason)
		if watermark then request = worker_request(d, w, "mailbox_read"); request.selector = { stream = "watermark" } end
		for _, receipt in w.receipts do
			if not request and receipt.publish and count(w.wakes or {}) < 32 then
				request = worker_request(d, w, "mailbox_publish_ack")
				local committed_ack = codec.strict_decode(receipt.bytes, 2048)
				request.receipt_revision = committed_ack.committed_revision
				request.ack_b64 = tern.base64.encode(receipt.bytes); request.ack_sha256 = codec.sha256(receipt.bytes); break
			end
		end
		if not request and w.accept_pending and not accept_held then
			request = common(d, control_origin(w), control_pane(w), "accept")
			request.target_request_id = w.launch_request_id; request.target_action_id = w.launch_action_id; request.pane_binding = clone(control_binding(w))
			for _, key in { "worker_id", "worker_generation", "enrolment_token", "work_id" } do request[key] = w[key] end
			for k, v in w.accepted_event do request[k] = v end
			-- Rollover successors must present the matching handover pair; initial dispatch has none.
			request.handover_id = w.handover_id; request.handover_token = w.handover_token
		end
		if not request and (settled(w) or config.start_retirement_settled(d, w)) then
			local owner = coordinator(n, w)
			if w.coordinator_owner_id and (not owner or owner.pending_executors ~= 0 or M.unresolved(n, w.logical_session_id, owner.owner_id)) then return fail("settlement_pending", "Coordinator executors remain unresolved.") end
			if not w.stopped then
				if w.stop_action_id or w.stop_refused then return fail("stop_unresolved", "Inspect the retained native stop obligation or refusal; no second stop is issued.") end
				request = common(d, control_origin(w), control_pane(w), "stop")
				request.target_request_id = w.launch_request_id; request.target_action_id = w.launch_action_id; request.pane_binding = clone(control_binding(w))
				for _, key in { "worker_id", "worker_generation", "enrolment_token", "work_id" } do request[key] = w[key] end
				w.stop_action_id = request.action_id
			else
				if retirement_refused(d, w) then
					return fail("retirement_refused", "SPAWN refused this stopped generation's retirement before any effect (producer journal unsettled); the mailbox stays provisioned. The nightly sweep or Retry mailbox retirement once… re-arms one attempt.")
				end
				if w.mailbox_retire_action_id then return fail("retirement_unresolved", "Inspect the retained mailbox retirement; no replacement grant is issued.") end
				request = mailbox_request(n, d, w, "retire")
			end
		end
		if not request and w.compaction_pending then
			request = mailbox_request(n, d, w, "compact")
		end
		if not request then
			for _, g in d.gates or {} do
				if g.worker_id == w.worker_id and g.phase == "answered" then
					local delivery, err = issue_reply(d, w, "owner_decision", { choice_id = g.answer.choice_id, answer = g.answer.answer }, g)
					if err then return nil, err end
					delivery.published = false; g.delivery = delivery; g.phase = "delivery_pending"
					for _, entry in flow(w).thread do
						if entry.gate_id == g.id and entry.kind == "answer" then entry.kind = "answer_delivery_pending"; entry.action_id = delivery.action_id end
					end
					break
				end
			end
		end
		if not request then
			for _, reply in w.replies do
				local blocked = false
				for _, p in d.projects or {} do if p.start and not p.start.claim and p.start.coordinator.worker_id == w.worker_id
					and p.start.reply_seq == reply.reply_seq and p.start.failure then blocked = true end end
				if not blocked and not reply.acknowledged and reply.part <= #reply.frames.chunks + 1 and count(w.wakes or {}) < 32 then
					local manifest = reply.part > #reply.frames.chunks
					local bytes = if manifest then reply.frames.manifest else reply.frames.chunks[reply.part]
					request = worker_request(d, w, "mailbox_publish_reply")
					request.message_id = reply.message_id; request.reply_seq = reply.reply_seq; request.action_revision = reply.action_revision; request.reply_sha256 = reply.sha256
					request.part = if manifest then "manifest" else "chunk"; request.index = if manifest then nil else reply.part
					request.object_b64 = tern.base64.encode(bytes); request.object_sha256 = codec.sha256(bytes); break
				end
			end
		end
		if not request and next(w.wakes or {}) then
			refresh(d, w, clock)
			if flow(w).health.native_state == "idle" and not (flow(w).native and flow(w).native.delivery_error) then
				local selected
				for key, wake in w.wakes do if not wake.action_id and (not selected or key < selected) then selected = key end end
				if selected then
					local wake = w.wakes[selected]
					request = common(d, control_origin(w), control_pane(w), "native_wake")
					request.target_request_id = wake.target_request_id; request.target_action_id = wake.target_action_id
					wake.action_id = request.action_id
				end
			end
		end
		if not request then
			if accept_held then
				return fail("accept_held", "Acceptance remains held by " .. tostring(if w.reason then w.reason.code else "unknown refusal")
					.. "; attachment does not prove that the refused acceptance may be re-issued.")
			end
			if w.rejected_report then
				return fail("report_held", "The completed report was rejected and retained unchanged; inspect its diagnostic. No report is skipped or acknowledged.")
			end
			request = worker_request(d, w, "mailbox_read")
			request.selector = w.read_selector or { stream = "report", slot = w.accepted_seq + 1, part = "manifest" }
		end
		if not add(d, request, w.worker_id) then return fail("oversize", "Mailbox request exceeds the bridge bound; no effect was granted.") end
		answer = result("mailbox_queued", { action_id = request.action_id })
		flow(w).last_poll = stamp(clock)
	elseif event.command == "finish" then
		local w = d.workers[event.worker_id]
		if not w or not equal(control_origin(w), event.origin) or w.coordinator_owner_id or w.phase ~= "accepted" or w.continuation_required then
			return fail("worker_unbound", "Finish requires an accepted ordinary worker in this exact control binding; coordinators use retirement.")
		end
		if w.finish and w.stopped and retirement_refused(d, w) then
			-- Explicit owner retry after SPAWN's exact pre-effect refusal: release the refused marker so the
			-- next poll issues exactly one fresh retirement grant; a second refusal re-arms the marker.
			w.mailbox_retire_action_id = nil; w.retirement_refused = nil
			answer = result("retirement_rearmed", { worker_id = w.worker_id })
		elseif w.finish then return finish_command(n, event, result("finish_already_requested", { worker_id = w.worker_id }))
		else
			-- A labeller's intake pin never blocks finishing it: an unlabelled intake then retries (Contract L).
			if pending(d, w) or w.accept_pending or w.assembly or w.rejected_report or next(w.replies) or next(w.wakes or {}) or flow(w).report_request
				or (w.role ~= "labeller" and work_referenced(d, w, true)) then
				return fail("workflow_unsettled", "Finish cannot discard unresolved effects, decisions, deliveries, rejected reports or referenced review/rollover/landing evidence.")
			end
			-- Pending document obligations pin the worker and gate for reclamation, not the native
			-- writer incarnation. Ending that writer safely permits the existing native Docs handoff.
			w.finish = { request_id = event.request_id, seq = w.accepted_seq, revision = n.revision, source = clone(event.origin) }
			config.usage_end(d, w, clock)
			flow(w).thread = {}
			answer = result("finish_requested", { worker_id = w.worker_id })
		end
	elseif event.command == "retire" then
		local w = d.workers[event.worker_id]
		local owner = if w then coordinator(n, w) else nil
		if not w or not equal(control_origin(w), event.origin) or not owner or not w.activation then
			return fail("activation_required", "Graceful retirement requires the current managed coordinator's issued activation. Old CP2 owners remain occupied for inspected recovery.")
		end
		if event.withdraw_starts ~= nil and event.withdraw_starts ~= true then return fail("invalid_command", "START withdrawal requires explicit owner confirmation.") end
		if event.withdraw_starts then
			if w.start_retirement then return finish_command(n, event, result("retirement_already_requested", { worker_id = w.worker_id })) end
			if not config.start_retirement_ready(n, w, clock) then return fail("start_retirement_pending", "Only an idle or positively exited orchestrator with a fully published unclaimed START tail and no other unsettled obligations can be withdrawn.") end
			local entries, originals = config.start_retirement_tail(d, w, true)
			w.start_retirement = { owner_id = owner.owner_id, owner_generation = owner.generation, revision = n.revision,
				origin = clone(control_origin(w)), pane_binding = clone(control_binding(w)), starts = entries, originals = originals }
			for _, project in d.projects do
				local start = project.start
				if start and start.coordinator.worker_id == w.worker_id and not start.claim then
					for _, entry in entries do if start.reply_seq == entry.reply_seq then
						config.close_start(n, project, start, { code = "start_owner_revoked", message = "The owner withdrew this START while retiring its original orchestrator.", retryable = false })
					end end
				end
			end
			owner.phase = "retiring"
			return finish_command(n, event, result("start_retirement_requested", { worker_id = w.worker_id }))
		end
		if w.start_retirement then return finish_command(n, event, result("retirement_already_requested", { worker_id = w.worker_id })) end
		if w.retirement or w.release then return finish_command(n, event, result("retirement_already_requested", { worker_id = w.worker_id })) end
		local grant, err = issue_reply(d, w, "coordinator_retirement", { owner_id = w.coordinator_owner_id,
			owner_generation = w.coordinator_generation, activation_token = w.activation.activation_token, reason = "Owner requested graceful retirement; finish quiescing, release and drain committed control replies. Do not start fresh work." })
		if err then return nil, err end
		w.retirement = grant; owner.phase = "retiring"
		answer = result("retirement_requested", { worker_id = w.worker_id })
	elseif event.command == "reply" then
		local w = d.workers[event.worker_id]
		if not w or not equal(control_origin(w), event.origin) or not w.mailbox_handle or w.phase ~= "accepted" or w.continuation_required then return fail("worker_unbound", "Replies require this accepted and explicitly continued generation.") end
		if w.finish or w.mailbox_retired then return fail("worker_retiring", "Finished workers cannot receive fresh progress requests.") end
		if w.coordinator_owner_id and (not coordinator(n, w) or w.release or w.retirement or w.start_retirement) then return fail("coordinator_retiring", "No fresh progress requests may be granted to a retiring or stale coordinator.") end
		local f = flow(w)
		if f.report_request then return finish_command(n, event, result("report_request_pending", { request_id = f.report_request.request_id, message_id = f.report_request.message_id })) end
		if event.trigger ~= nil and event.trigger ~= "policy" then return fail("invalid_command", "Reply trigger is the session policy; owner requests carry none.") end
		-- Automatic (policy) report requests without a new report are a capped loop (Contract L).
		local cap = policy(d, w.logical_session_id).loop_cap
		local loop = f.report_loop
		if event.trigger == "policy" and loop and loop.state == "stopped" then
			return fail("loop_stopped", "The owner stopped automatic report requests for this worker; a new report from the worker resumes them.")
		end
		if event.trigger == "policy" and loops.trips(loop, cap) then
			local g, err = loops.open(d, w, loop, "report_request", w.worker_id, "Report requested " .. tostring(loop.count)
				.. " times without a new report. Worker " .. w.worker_id .. " answers only ORCH+'s automatic progress requests; no further automatic request is sent. Allow more requests or keep them stopped (any new report from the worker resumes them).", cap, clock, true)
			if err then return nil, err end
			answer = result("loop_capped", { gate_id = g.id, worker_id = w.worker_id })
		else
			if not sendable(d, w, clock) then
				return fail("worker_not_sendable", "Observe safely: working, waiting-input, exited or unconfirmed native workers are never interrupted.")
			end
			local request_id = next_id(d, "report-request-")
			local delivery, err = issue_reply(d, w, "report_request", { request_id = request_id, requested_kind = "HEARTBEAT", reason = "Owner/session policy requested a structured progress report; echo request_id in HEARTBEAT or CHECKPOINT." })
			if err then return nil, err end
			delivery.request_id = request_id; delivery.published = false; delivery.response_received = false; f.report_request = delivery
			local _, problem = append(d, w, "report_request", "Requested structured progress; delivery ACK is not a progress response.", clock, { state = "pending", request_id = request_id, action_id = delivery.action_id })
			if problem then return nil, problem end
			if event.trigger == "policy" then f.report_loop = loop or { count = 0 }; f.report_loop.count += 1 end
			answer = result("reply_committed", { message_id = delivery.message_id, request_id = request_id })
		end
	elseif event.command == "intake" then
		-- Production-unreachable: host.luau refuses a direct `intake` command from every UI entry
		-- (reports arrive through mailbox pages). It drives exact reports in the test groups.
		local w = d.workers[event.worker_id]
		if not w or not equal(control_origin(w), event.origin) or w.continuation_required then return fail("binding_mismatch", "Unknown or not explicitly continued generation.") end
		local applied, err = intake(n, w, event.bytes, clock); if err then return nil, err end; answer = applied
	elseif event.command == "rollover" then
		local w = d.workers[event.worker_id]
		if not w or not equal(control_origin(w), event.origin) or w.phase ~= "accepted" or w.continuation_required
			or w.finish or w.stopped or w.mailbox_retired or not w.mailbox_handle then
			return fail("worker_unbound", "Rollover requires an accepted, explicitly continued generation in this exact control binding.")
		end
		if not config.project_ref(d, w.logical_session_id, w.orch_project_id) then return fail("project_changed", "Move this conversation to an unfinished project before requesting rollover; no handover was created.") end
		if w.coordinator_owner_id and not active_rollover(d, w) then
			local owner = coordinator(n, w)
			if not owner or owner.phase ~= "running" or not w.activation or not w.activation.acknowledged or w.retirement or w.release then
				return fail("coordinator_unavailable", "Coordinator rollover requires the current running coordinator with an acknowledged activation that is not already retiring.")
			end
			if coordinator_rollover(d, w.logical_session_id) or restored_coordinator(d, w.logical_session_id) then
				return fail("rollover_in_progress", "Another coordinator rollover or an unreconciled restored coordinator holds this session's orchestrator slot.")
			end
		end
		if event.trigger ~= "owner" and event.trigger ~= "policy" then return fail("invalid_command", "Rollover trigger must be the owner control or the session policy.") end
		local r = active_rollover(d, w)
		if r and r.predecessor_worker_id ~= w.worker_id then return fail("rollover_in_progress", "This worker is the successor of an unfinished rollover.") end
		if r then
			if event.trigger ~= "owner" or not rollover_rerequestable(d, r) then
				return finish_command(n, event, result("rollover_in_progress", { handover_id = r.id, worker_id = w.worker_id }))
			end
			local cap = policy(d, w.logical_session_id).loop_cap
			if r.checkpoint_loop and r.checkpoint_loop.state == "stopped" then
				return fail("loop_stopped", "The owner stopped checkpoint re-requests for rollover " .. r.id .. " at the loop cap; cancel the rollover to end it.")
			end
			if loops.trips(r.checkpoint_loop, cap) then
				local loop = r.checkpoint_loop
				local g, err = loops.open(d, w, loop, "rollover_checkpoint", r.id, "Checkpoint requested " .. tostring(loop.count)
					.. " times without a verified checkpoint; last refusal: " .. r.hold.code .. ". Rollover " .. r.id .. " of " .. r.work_id
					.. " stays held and no further checkpoint is requested; the predecessor keeps running. Allow more re-requests, keep it stopped, or cancel the rollover.", cap, clock, true)
				if err then return nil, err end
				answer = result("loop_capped", { gate_id = g.id, handover_id = r.id, worker_id = w.worker_id })
			else
				-- Owner-only re-request of a blocked checkpoint; no effect has started beyond the old request.
				r.request_id = nil; r.checkpoint = nil; r.verification = nil; rollover_edge(r, "requested", n.revision, clock)
				answer = result("checkpoint_rerequested", { handover_id = r.id, worker_id = w.worker_id })
			end
		else
			local landing = landing_open(d, w.worker_id, true)
			if landing then
				return fail("landing_in_progress", "This worker holds landing grant " .. landing.id .. "; its exact LANDING_RESULT or owner reconciliation must settle before rollover.")
			end
			local deploy = config.deploy_in_flight(d, w.worker_id)
			if deploy then
				return fail("deploy_in_progress", "This worker holds deploy grant " .. deploy.deploy_id .. "; its exact DEPLOY_RESULT, the owner's answer or reconciliation must settle before rollover.")
			end
			refresh(d, w, clock)
			if event.trigger == "policy" then
				local due, why = rollover_due(n, w, flow(w))
				if not due then return fail("rollover_not_due", why) end
			end
			d.rollovers = d.rollovers or {}
			config.reclaim_rollovers(d)
			if count(d.rollovers) >= 32 then return fail("full", "Rollover capacity is full of unfinished handovers; none was discarded.") end
			local handover_id = next_id(d, "handover-")
			d.rollovers[handover_id] = { id = handover_id, kind = if w.coordinator_owner_id then "coordinator" else "worker", phase = "requested", trigger = event.trigger, logical_session_id = w.logical_session_id,
				work_id = w.work_id, predecessor_worker_id = w.worker_id, predecessor_pane_binding = clone(control_binding(w)),
				origin = clone(event.origin), controller_pane = event.controller_pane, controller_generation = event.origin.owner_generation,
				handover_token = codec.sha256(event.request_id .. ":" .. event.origin.alias_nonce .. ":" .. handover_id),
				revision = n.revision, at_ms = stamp(clock).at_ms, context = clone(flow(w).context),
				predecessor_owner_id = w.coordinator_owner_id, predecessor_generation = w.coordinator_generation }
			answer = result("rollover_requested", { handover_id = handover_id, worker_id = w.worker_id })
		end
	elseif event.command == "close_handover" then
		local w = d.workers[event.worker_id]
		if not w or w.logical_session_id ~= event.orch_session_id then return fail("worker_unbound", "Choose this session's exact predecessor.") end
		local r = active_rollover(d, w)
		if not r or r.predecessor_worker_id ~= w.worker_id then return finish_command(n, event, result("no_progress")) end
		if n.sessions[event.orch_session_id].admitted ~= true or not rollover_cancellable(d, r) then
			return fail("handover_effect_started", "An issued or restored successor may exist. Keep its obligation and reconcile; missing peer state is not a safe exit.")
		end
		local succ = if r.successor_worker_id then d.workers[r.successor_worker_id] else nil
		if r.quota then close_quota_gate(d, r.quota, w); r.quota = nil end
		r.prepared = nil; rollover_edge(r, "cancelled", n.revision, clock)
		if succ and succ.coordinator_owner_id then
			local owner = n.sessions[event.orch_session_id].orchestrator
			if not owner or owner.owner_id ~= succ.coordinator_owner_id or owner.phase ~= "reserved" or owner.pending_executors ~= 0 then
				return fail("coordinator_unresolved", "Only the exact untouched coordinator reservation can be released without a successor.")
			end
			owner.managed_worker_id = nil; owner.owner_active = false
			local released, response = reserve(n, { kind = "release_coordinator", request_id = r.id .. "-no-successor",
				orch_session_id = event.orch_session_id, expected_owner_id = owner.owner_id, expected_generation = owner.generation,
				quiescent = true, authority_namespace = n.authority_namespace, expected_revision = n.revision }, clock)
			if not released then return nil, response end
			n = released; d = n.dispatch
		end
		if succ then
			for key, action in d.actions do if action.worker_id == succ.worker_id then d.actions[key] = nil end end
			for key, gate in d.gates do if gate.worker_id == succ.worker_id then d.gates[key] = nil end end
			d.workers[succ.worker_id] = nil
			r.successor_worker_id = nil; r.successor_owner_id = nil; r.successor_generation = nil
		end
		answer = result("handover_closed", { handover_id = r.id, worker_id = w.worker_id })
	elseif event.command == "cleanup_notice" then
		if not sweep_date(event.local_date) or not pos(event.observed_at_ms) or math.abs(event.observed_at_ms - stamp(clock).at_ms) > 60000
			or not count_or_zero(event.mailboxes) or event.mailboxes > 32 or not str(event.time_zone, 96)
			or (event.open_files ~= nil and (not count_or_zero(event.open_files) or event.open_files > 1000000))
			or (event.stale_files ~= nil and (not count_or_zero(event.stale_files) or event.open_files == nil or event.stale_files > event.open_files))
			or (event.observation_unavailable ~= nil and type(event.observation_unavailable) ~= "boolean")
			or ((event.open_files == nil or event.stale_files == nil) and event.observation_unavailable ~= true) then
			return fail("invalid_observation", "Cleanup communication summary needs a current observed inventory, explicit unavailable counts and desktop time zone.")
		end
		local sid, actual = event.orch_session_id, 0
		for _, w in d.workers do if w.logical_session_id == sid and w.mailbox_handle and not w.mailbox_retired then actual += 1 end end
		if actual ~= event.mailboxes then return fail("source_changed", "Retained mailbox inventory changed before the summary; observe it again.") end
		if event.observation_unavailable == true then return finish_command(n, event, result("cleanup_observation_pending", { message = "Communication inventory is not yet verified; the daily summary remains due." })) end
		if ((d.cleanup_notices or {})[sid] or "") >= event.local_date then return registry, result("no_progress") end
		d.cleanup_notices = d.cleanup_notices or {}; d.cleanup_notices[sid] = event.local_date
		local message = tostring(actual) .. " agent communication mailboxes retained. "
			.. (if event.open_files ~= nil then tostring(event.open_files) .. " communication files remain open. " else "Communication file count is unavailable. ")
			.. (if event.stale_files ~= nil then tostring(event.stale_files) .. " files look stale." else "Communication file age is unavailable; no stale-file claim was made.")
		answer = result("cleanup_summary", { local_date = event.local_date, observed_at_ms = event.observed_at_ms, mailboxes = actual,
			time_zone = event.time_zone, open_files = event.open_files, stale_files = event.stale_files, observation_unavailable = event.observation_unavailable, message = message })
	elseif event.command == "sweep" then
		local swept, problem = run_sweep(n, event, clock)
		if not swept then return nil, problem end
		answer = swept
	elseif event.command == "recheck_report" then
		-- Explicit owner re-check of the SAME retained immutable bytes under current validation.
		-- It never skips a sequence, accepts different bytes or runs automatically.
		local w = d.workers[event.worker_id]
		if not w or not equal(control_origin(w), event.origin) or w.continuation_required then
			return fail("worker_unbound", "Re-check requires this generation's explicitly continued current control route.")
		end
		local held = w.rejected_report
		if not held then return finish_command(n, event, result("no_progress")) end
		if w.frozen or w.assembly or pending(d, w) then return fail("operation_pending", "A retained operation or frozen conflict owns this generation; settle it before re-checking.") end
		local raw = codec.strict_decode(held.bytes)
		local next_seq = w.accepted_seq + 1
		if type(raw) ~= "table" or raw.seq ~= next_seq or codec.sha256(held.bytes) ~= held.sha256
			or raw.event_id ~= codec.sha256(w.mailbox_handle .. ":report:" .. string.format("%.0f", next_seq)) then
			return fail("held_report_sequence", "The held bytes are not this generation's exact next report; nothing is skipped or replaced.")
		end
		w.rejected_report = nil
		-- Same semantic intake a freshly reassembled read uses; failure leaves the candidate untouched.
		local _, problem = intake(n, w, held.bytes, clock)
		if problem then
			local message = bounded(tostring(problem.message or problem.code), 1024)
			w.rejected_report = { code = problem.code, message = message, bytes = held.bytes, sha256 = held.sha256, action_id = held.action_id }
			w.reason = { code = problem.code, message = message }
			answer = result("held_report_still_rejected", { worker_id = w.worker_id, seq = next_seq, reason_code = problem.code })
		else
			w.reason = nil
			answer = result("held_report_accepted", { worker_id = w.worker_id, seq = next_seq, event_id = raw.event_id, sha256 = held.sha256 })
		end
	elseif event.command == "reconcile_restored" then
		local w = d.workers[event.worker_id]
		if not w or not equal(control_origin(w), event.origin) or not w.restored or w.restored.reconciled or event.operator_verified ~= true then
			return fail("stale_recovery", "Confirm only an unreconciled restored coordinator pane after independently stopping it.")
		end
		-- Operator attestation only; this neither stops a pane nor counts the old generation healthy.
		w.restored.reconciled = "operator_attested"
		answer = result("restoration_reconciled", { worker_id = w.worker_id })
	elseif event.command == "cancel_landing" or event.command == "move_landing" or event.command == "landing_lost" or event.command == "reconcile_landing" then
		local L = d.landing
		local item = if L and id(event.landing_id) then L.items[event.landing_id] else nil
		if not item or item.logical_session_id ~= event.orch_session_id or not pos(event.landing_revision) or item.revision ~= event.landing_revision then
			return fail("stale_landing", "Landing item or its revision changed; reopen its current controls. Nothing was changed.")
		end
		local q = L.queues[item.queue_id]
		local grant = landing_current(item)
		if event.command == "cancel_landing" then
			local deploy = config.pending_deploy(d, item)
			if deploy then
				config.deploy_status(deploy, item, "stopped"); deploy.hold = nil
				config.deploy_settle(d, deploy)
				answer = result("deploy_stopped", { landing_id = item.id, deploy_id = deploy.deploy_id })
			elseif not LANDING_UNGRANTED[item.status] then
				return fail("landing_not_cancellable", "Only ungranted requests or unissued pending deployments can be stopped. A granted effect settles only by its exact result or owner reconciliation.")
			else
				landing_unqueue(q, item.id); landing_withdraw_gate(d, item, "cancelled")
				landing_status(item, "cancelled", landing_hold("owner_cancelled", "The owner cancelled this ungranted landing request; nothing was granted."), n.revision, clock)
				landing_settle(d, item)
				answer = result("landing_cancelled", { landing_id = item.id })
			end
		elseif event.command == "move_landing" then
			local index = table.find(q.order, item.id)
			local other = if not index then nil elseif event.direction == "up" then index - 1 elseif event.direction == "down" then index + 1 else nil
			local neighbour = if other and other >= 1 then L.items[q.order[other]] else nil
			if not LANDING_UNGRANTED[item.status] or not neighbour or not LANDING_UNGRANTED[neighbour.status] then
				return fail("landing_not_movable", "Only ungranted items move, one place up or down, and never past the granted slot.")
			end
			q.order[index], q.order[other] = q.order[other], q.order[index]
			item.revision += 1; neighbour.revision += 1
			answer = result("landing_moved", { landing_id = item.id })
		elseif (event.command == "landing_lost" or event.command == "reconcile_landing") and item.status == "landed" then
			-- Contract J: the landed item's deploy takes the same read-only lost/reconcile path; a lost
			-- deploy result is never re-granted, and only the owner's reconciliation settles it.
			local dp = config.deploy_of(d, item)
			local a = if dp then dp.attempts[#dp.attempts] else nil
			if event.command == "landing_lost" then
				if not a or a.uncertain or (dp.status ~= "granted" and dp.status ~= "held") or not str(event.reason, 1024) then
					return fail("deploy_not_granted", "Only a granted or held deploy attempt without recorded uncertainty can be marked lost, with a reason.")
				end
				a.uncertain = { code = "owner_marked_lost", at_ms = stamp(clock).at_ms,
					message = bounded("Owner marked the deploy result lost: " .. event.reason .. ". Reconcile the observed deploy state; nothing is re-granted.", 1024) }
				a.status = "uncertain"; config.deploy_ungate(d, dp); dp.status = "uncertain"; item.revision += 1
				answer = result("deploy_held", { landing_id = item.id, deploy_id = dp.deploy_id })
			else
				if not a or dp.status ~= "uncertain" or event.operator_verified ~= true or not str(event.reason, 1024)
					or (event.outcome ~= "deployed" and event.outcome ~= "not_deployed") or event.target_revision ~= nil or event.current_target_revision ~= nil then
					return fail("reconciliation_required", "Reconcile only an uncertain deploy attempt: state the observed outcome (deployed or not_deployed), a reason, and confirm the read-only inspection.")
				end
				a.reconciliation = { outcome = event.outcome, reason = event.reason, source = clone(event.origin), at_ms = stamp(clock).at_ms, revision = n.revision }
				dp.status = if event.outcome == "deployed" then "deployed" else "failed"; item.revision += 1
				if event.outcome == "deployed" then config.deploy_settle(d, dp) end
				answer = result("deploy_reconciled", { landing_id = item.id, deploy_id = dp.deploy_id, outcome = event.outcome })
			end
		elseif event.command == "landing_lost" then
			if not grant or grant.uncertain or not str(event.reason, 1024) then
				return fail("landing_not_granted", "Only a granted landing without recorded uncertainty can be marked lost, with a reason.")
			end
			grant.uncertain = { code = "owner_marked_lost", at_ms = stamp(clock).at_ms,
				message = bounded("Owner marked the result lost: " .. event.reason .. ". The slot stays held until reconciliation; nothing is retried.", 1024) }
			item.revision += 1
			answer = result("landing_held", { landing_id = item.id })
		else
			if not grant or not grant.uncertain or event.operator_verified ~= true or not str(event.reason, 1024)
				or (event.outcome ~= "landed" and event.outcome ~= "not_landed") or (event.outcome == "landed" and event.target_revision == nil)
				or (event.target_revision ~= nil and not landing_text(event.target_revision))
				or (event.current_target_revision ~= nil and (event.outcome ~= "landed" or not landing_text(event.current_target_revision)))
				or (grant.uncertain.code == "repository_head_unordered"
					and (if event.outcome == "landed" then event.current_target_revision == nil else event.target_revision == nil)) then
				return fail("reconciliation_required", "Reconcile only an uncertain grant from read-only inspection: state its outcome, landing revision when landed, reason, and current target head. Unordered results require a separate current_target_revision when landed, or target_revision when not landed.")
			end
			local observed_head = if event.outcome == "landed" then event.current_target_revision else event.target_revision
			if observed_head ~= nil then
				config.landing_head(d, q, { revision = observed_head, source = "owner", landing_id = item.id })
			elseif event.outcome == "landed" and not config.landing_head(d, q,
				{ revision = event.target_revision, source = "owner", landing_id = item.id }, grant.target_revision) then
				return fail("reconciliation_required", "This landing's resulting revision does not establish the current repository head. Inspect and supply current_target_revision separately; nothing was settled.")
			end
			grant.reconciliation = { outcome = event.outcome, target_revision = event.target_revision, current_target_revision = event.current_target_revision, reason = event.reason,
				source = clone(event.origin), at_ms = stamp(clock).at_ms, revision = n.revision }
			q.slot = nil
			if event.outcome == "landed" then
				landing_unqueue(q, item.id)
				landing_status(item, "landed", landing_hold("owner_reconciled", "Owner reconciled the observed target: landed at " .. event.target_revision .. "."), n.revision, clock)
				landing_settle(d, item)
				item.deploy_due = true -- Contract J: the owner-observed merge is deployed like any other.
			else
				item.refresh_required = true; item.approval = nil
				landing_status(item, "blocked", landing_hold("refresh_required", "Owner reconciled the observed target: not landed. The worker must publish a fresh LANDING_REQUEST before another grant; nothing is retried."), n.revision, clock)
			end
			answer = result("landing_reconciled", { landing_id = item.id, outcome = event.outcome })
		end
	else return fail("invalid_command", "Unknown dispatch command.") end
	config.recheck_start_reports(n, clock)
	advance_rollovers(n, event, clock, reserve)
	config.advance_proposals(registry, n, event, clock, reserve)
	config.advance_reviews(n, event, clock)
	advance_landing(n, event, clock)
	config.advance_deploys(n, event, clock)
	config.advance_sources(registry, n, event, clock, reserve)
	config.close_stale_starts(n)
	for _, w in n.dispatch.workers do if w.logical_session_id == event.orch_session_id then refresh(n.dispatch, w, clock) end end
	-- Concurrency ledger phases follow the committed worker/action evidence of this transition.
	sync_reservations(n, clock)
	return finish_command(n, event, answer)
end
function M.reconcile(registry: any, event: any): (any?, any)
	if not closed(event, "kind request_id orch_session_id authority_namespace action_id expected_revision executor operator_verified reason")
		or event.kind ~= "dispatch_reconcile" or not id(event.request_id) or not id(event.action_id) or not id(event.executor)
		or event.operator_verified ~= true or not str(event.reason, 512) then return fail("stale_recovery", "Confirm this exact displayed action and revision after independently stopping its executor.") end
	local d = registry.dispatch
	if event.authority_namespace ~= registry.authority_namespace then return fail("stale_authority", "Authority namespace changed.") end
	if event.expected_revision ~= registry.revision then return fail("stale_recovery", "Authority changed; inspect and confirm this exact executor again.") end
	if registry.revision == MAX then return fail("full", "Authority revision is exhausted.") end
	local a = if d then d.actions[event.action_id] else nil
	if not a then return registry, result("already_resolved") end
	local session = registry.sessions[event.orch_session_id]
	local owner = if session then session.controller else nil
	if not a or a.phase ~= "uncertain" or not a.claim or a.claim.executor ~= event.executor or a.request.origin_binding.logical_session_id ~= event.orch_session_id
		or not owner or owner.owner_id ~= a.request.origin_binding.owner_id or owner.pending_executor_evidence ~= "unconfirmed"
		or owner.owner_active ~= nil or not owner.last_observation or owner.last_observation.status ~= "unavailable" then
		return fail("executor_verification_required", "Only an uncertain retained claim with unavailable owner evidence can be explicitly reconciled. A known live executor cannot be overridden.")
	end
	local n = candidate(registry); local changed = n.dispatch.actions[event.action_id]
	config.release_executor(n.sessions[event.orch_session_id], if a.worker_id then n.dispatch.workers[a.worker_id] else nil, changed)
	changed.executor_stopped = true
	local w = if a.worker_id then n.dispatch.workers[a.worker_id] else nil
	if w then
		w.phase = "held"; w.reason = { code = "executor_resolved", message = "Operator stopped/reconciled the retained executor; this does not retry or retire its worker." }
	end
	sync_reservations(n, nil)
	local answer = result("executor_reconciled", { action_id = event.action_id, committed_revision = n.revision })
	return n, answer
end
function M.project(registry: any, session_id: string, origin_nonce: string, current_action_id: string?, retained_action_ids: any?): any
	local d = registry.dispatch or fresh(); local actions, workers = {}, {}
	for key, a in d.actions do
		if a.request.origin_binding.logical_session_id == session_id and (a.phase == "claimed" or a.phase == "uncertain" or a.phase == "backpressure"
			or ((a.phase == "ready" or a.phase == "held_ready") and a.request.origin_binding.alias_nonce == origin_nonce) or key == current_action_id
			or (type(retained_action_ids) == "table" and retained_action_ids[key] ~= nil)) then
			local wake_status = if a.response and type(a.response.payload) == "table" then a.response.payload.wake_status else nil
			local route = execution_origin(d, a)
			local cursor = (d.command_cursors or {})[session_id]
			actions[key] = { request = clone(a.request), request_bytes = a.request_bytes, phase = a.phase, claim = public_claim(a.claim), worker_id = a.worker_id,
				start_blocked = a.worker_id ~= nil and d.workers[a.worker_id] ~= nil and (a.request.op == "launch" or a.request.op == "adopt" or a.request.op == "enrol" or a.request.op == "mailbox_provision")
					and (not config.worker_start_allowed(d, d.workers[a.worker_id]) or d.workers[a.worker_id].checks_pending == true or d.workers[a.worker_id].launch_gates ~= nil),
				retry_count = a.retry_count, retry_loop = clone(a.retry_loop), retry_after_serial = a.retry_after_serial,
				executor_stopped = a.executor_stopped, wake_status = wake_status, wake_pending = a.phase == "claimed" and wake_status ~= nil,
				execution_origin = clone(route), execution_controller_pane = if cursor and cursor.continued_epoch and equal(cursor.origin, route) then cursor.controller_pane else a.request.controller_pane,
				reconciliation_only = not equal(route, a.request.origin_binding) or (a.claim ~= nil and a.claim.epoch ~= registry.execution_epoch) }
			local proof = M.action_proof(registry, a)
			for field, value in proof or {} do actions[key][field] = value end
		end
	end
	for key, w in d.workers do if w.logical_session_id == session_id then workers[key] = { worker_id = key, work_id = w.work_id, phase = w.phase, record_id = w.record_id,
		orch_project_id = w.orch_project_id, record_revision = w.record_revision, cwd = w.cwd, placement = w.placement,
		execution_cwd = w.execution_cwd, presentation = w.presentation, open_conversation = w.open_conversation, enrol_delivery = w.enrol_delivery,
		enrol_cancelling = w.enrol_cancelling, prompt_delivery = w.prompt_delivery, checks_pending = w.checks_pending, checks = clone(w.checks),
		selected_record = clone(w.selected_record), provider = if w.selected_record then w.selected_record.provider else nil,
		account_label = if w.selected_record then w.selected_record.account_label else nil,
		model = if w.selected_record then w.selected_record.model else nil, backend = if w.selected_record then w.selected_record.backend else nil,
		accepted_seq = w.accepted_seq, compacted_floor = w.compacted_floor, reason = clone(w.reason),
		rejected_report = if w.rejected_report then { code = w.rejected_report.code, message = w.rejected_report.message } else nil,
		pane_binding = clone(control_binding(w)), reply_floor = w.reply_floor,
		coordinator_owner_id = w.coordinator_owner_id, coordinator_generation = w.coordinator_generation,
		activation_received = w.activation ~= nil and w.activation.acknowledged, activation_issued = w.activation ~= nil,
		retirement_requested = w.retirement ~= nil or w.start_retirement ~= nil, start_retirement_requested = w.start_retirement ~= nil,
		start_retirement_ready = config.start_retirement_ready(registry, w, nil), finish_requested = w.finish ~= nil, release_seq = if w.release then w.release.seq else nil,
		stop_status = if w.stopped then w.stopped.observation elseif w.stop_refused then "refused" elseif w.stop_action_id and d.actions[w.stop_action_id] then d.actions[w.stop_action_id].phase else "not_requested",
		mailbox_status = if w.mailbox_retired then "retired" elseif retirement_refused(d, w) then "refused"
			elseif w.mailbox_retire_action_id and d.actions[w.mailbox_retire_action_id] then d.actions[w.mailbox_retire_action_id].phase else "not_requested",
		reply_seq = w.reply_seq, owner_released = w.coordinator_owner_id ~= nil
			and (registry.sessions[session_id].orchestrator == nil or registry.sessions[session_id].orchestrator.owner_id ~= w.coordinator_owner_id)
			and registry.sessions[session_id].orchestrator_generation >= w.coordinator_generation,
		effective_identity = clone(w.effective_identity), capabilities = clone(w.capabilities), handover_id = w.handover_id, routing = clone(w.routing),
		allocation_target = config.allocation_target(d, w),
		continuation_required = w.continuation_required == true, adopt_pane_binding = clone(w.adopt_pane_binding), withdrawal = withdrawal_view(registry, d, w) } end end
	-- Stored USAGE evidence is projected only while it matches the current catalog join.
	-- policy_sha256 is the stale-editor fence the policy command expects (quota.digest of the saved policy).
	local workflow = { policy = clone(policy(d, session_id)), policy_sha256 = quota.digest(policy(d, session_id)), workers = {}, threads = {}, gates = {}, rollovers = {}, landing = {},
		policy_revision = M.policy_revision(registry, session_id),
		capacity = clone(current_evidence(d, session_id)), sweep = clone((d.sweeps or {})[session_id]), reviews = {},
		family_migrations = clone(config.family_obligations(registry, session_id)),
		family_migration_scope = if next((d.family_migrations or {})[session_id] or {}) ~= nil then "instance" else "defaults",
		cleanup_notice_date = (d.cleanup_notices or {})[session_id] }
	config.sources_view(d, session_id, workflow)
	local decisions = (d.command_cursors or {})[session_id]
	workflow.projects = {}
	for key, p in d.projects or {} do if p.logical_session_id == session_id and not p.finished then
		local view = clone(p)
		view.start = config.start_projection(d, p, registry)
		view.start_history = nil
		view.members, view.association_contexts, view.checks = {}, {}, {}
		view.folder_candidates = {}
		if p.repository then config.project_folder(view.folder_candidates, p.repository.cwd) end
		for _, source in p.sources do
			if source.kind == "manual" then config.project_folder(view.folder_candidates, source.ref) end
		end
		view.paused = workflow.policy.paused; view.held_work = false
		local active = p.started or next(p.associations or {}) ~= nil
		local decision = if decisions then { command = "project_start", orch_session_id = session_id, authority_namespace = registry.authority_namespace,
			origin = decisions.origin, controller_pane = decisions.controller_pane, orch_project_id = key, project_revision = p.revision } else nil
		view.decision_context = if decision then M.decision_context(registry, decision) else nil
		for _, w in d.workers do
			if w.logical_session_id == session_id and decision then
				local association = table.clone(decision); association.command = "project_associate"; association.worker_id = w.worker_id
				view.association_contexts[w.worker_id] = M.decision_context(registry, association)
			end
			if w.orch_project_id == key then
				table.insert(view.members, w.worker_id)
				if w.accepted_event then
					if w.checkout then config.project_folder(view.folder_candidates, w.checkout.worktree_path) end
					config.project_folder(view.folder_candidates, w.execution_cwd)
				end
				if w.checks_pending or w.project_held then view.held_work = true end
				if w.checks_pending and w.checks then table.insert(view.checks, { worker_id = w.worker_id, checks = clone(w.checks) }) end
				if (w.pane_binding or w.adopt_pane_binding) and not w.stopped and not w.mailbox_retired and not (w.workflow and w.workflow.exit) then active = true end
			end
		end
		for _, plan in d.plans or {} do if plan.orch_project_id == key and plan.held then
			for _, cp in plan.checkpoints do for _, task in cp.tasks do if #task.checks > 0 then
				table.insert(view.checks, { source_ref = plan.path .. "#" .. task.id, checks = clone(task.checks) })
			end end end
		end end
		for _, collection in { d.plans or {}, d.intakes or {}, d.chains or {} } do
			for _, source in collection do if source.orch_project_id == key and source.held then view.held_work = true end end
		end
		table.sort(view.members); view.status = if active then "ACTIVE" else "START"
		view.explanation = if view.paused and active then "Waiting for orchestration to resume." elseif view.held_work then "New work is held until project START." else nil
		workflow.projects[key] = view
	end end
	workflow.finished_projects = clone(d.finished_projects or {})
	for _, rv in d.reviews or {} do if rv.logical_session_id == session_id then table.insert(workflow.reviews, config.review_view(rv)) end end
	table.sort(workflow.reviews, function(a, b) return config.review_serial(a) < config.review_serial(b) end)
	workflow.release_manager = config.worker_ref(d, (config.release_manager(d, session_id) or {}).worker_id)
	-- Landing queues: open items in FIFO order, then the four most recent terminal items.
	local L = d.landing or { queues = {}, items = {} }
	local repository_groups = config.repository_groups(L)
	for key, q in L.queues do
		if q.logical_session_id == session_id then
			local repository_group = if q.repository then repository_groups[q.repository.key] else nil
			local function view(item: any, position: number?): any
				local grant = item.grants[#item.grants]
				local current = landing_current(item)
				local before = if position and position > 1 then L.items[q.order[position - 1]] else nil
				local after = if position then L.items[q.order[position + 1]] else nil
				local out = { id = item.id, revision = item.revision, status = item.status, position = position, work_id = item.work_id, worker_id = item.worker_id,
					repository_position = if position and repository_group then repository_group.positions[item.id] else nil,
					request = clone(item.request), gate_id = item.gate_id, approved = item.approval ~= nil, proof = clone(item.proof),
					hold = clone(item.hold), refresh_required = item.refresh_required == true, attempts = #item.grants,
					refresh_loop = clone(item.refresh_loop), grant_loop = clone(item.grant_loop),
					grant = if grant then { grant_id = grant.grant_id, target_revision = grant.target_revision, published = grant.published,
						acknowledged = grant.acknowledged, result = clone(grant.result), late_result = clone(grant.late_result),
						uncertain = clone(grant.uncertain), reconciliation = clone(grant.reconciliation), current = grant == current } else nil,
					uncertain = current ~= nil and current.uncertain ~= nil,
					cancellable = LANDING_UNGRANTED[item.status] == true or config.pending_deploy(d, item) ~= nil,
					move_up = LANDING_UNGRANTED[item.status] == true and before ~= nil and LANDING_UNGRANTED[before.status] == true,
					move_down = LANDING_UNGRANTED[item.status] == true and after ~= nil and LANDING_UNGRANTED[after.status] == true,
					markable_lost = current ~= nil and current.uncertain == nil, reconcilable = current ~= nil and current.uncertain ~= nil }
				config.landing_extras(d, item, out)
				return out
			end
			local items = {}
			for position, landing_id in q.order do table.insert(items, view(L.items[landing_id], position)) end
			local terminal = {}
			for _, item in L.items do if item.queue_id == key and LANDING_TERMINAL[item.status] then table.insert(terminal, item) end end
			table.sort(terminal, function(a, b)
				local ra, rb = a.history[#a.history].revision, b.history[#b.history].revision
				return ra > rb or (ra == rb and a.id > b.id)
			end)
			for index = 1, math.min(4, #terminal) do table.insert(items, view(terminal[index], nil)) end
			table.insert(workflow.landing, { id = key, project_id = q.project_id, repo_ref = q.repo_ref, target_ref = q.target_ref,
				head = clone(q.head), slot = q.slot, items = items, repository = clone(q.repository),
				repository_slot = if repository_group then repository_group.slot else nil,
				repository_first = if repository_group then repository_group.first else nil,
				repository_count = if repository_group then #repository_group.order else #q.order })
		end
	end
	table.sort(workflow.landing, function(a, b) return a.id < b.id end)
	local latest_rollover = {}
	for key, r in d.rollovers or {} do
		if r.logical_session_id == session_id then
			local pred = d.workers[r.predecessor_worker_id]
			local cp = if r.checkpoint and pred then codec.decode_report(r.checkpoint, pred) else nil
			table.insert(workflow.rollovers, { id = key, kind = r.kind, phase = r.phase, trigger = r.trigger, work_id = r.work_id,
				predecessor_owner_id = r.predecessor_owner_id, predecessor_generation = r.predecessor_generation,
				successor_owner_id = r.successor_owner_id, successor_generation = r.successor_generation, closure = r.closure,
				predecessor_worker_id = r.predecessor_worker_id, successor_worker_id = r.successor_worker_id,
				predecessor_pane_binding = clone(r.predecessor_pane_binding), successor_pane_binding = clone(r.successor_pane_binding),
				controller_generation = r.controller_generation, hold = clone(r.hold), revision = r.revision, at_ms = r.at_ms, verification = clone(r.verification),
				stop_observation = r.stop_observation, context = clone(r.context), checkpoint_loop = clone(r.checkpoint_loop),
				checkpoint = if cp then { checkpoint_id = cp.payload.checkpoint_id, artifact_revision = cp.payload.artifact_revision, task_ref = cp.payload.task_ref,
					completed = clone(cp.payload.completed), remaining = clone(cp.payload.remaining), holds = clone(cp.payload.holds), checks = clone(cp.payload.checks) } else nil,
				cancellable = rollover_cancellable(d, r), close_without_successor = rollover_cancellable(d, r),
				rerequestable = not ROLLOVER_TERMINAL[r.phase] and rollover_rerequestable(d, r) })
			local revision = r.revision
			for _, worker_id in { r.predecessor_worker_id, r.successor_worker_id } do
				local prior = latest_rollover[worker_id]
				-- An unfinished rollover always outranks history for the worker's surface.
				local rank = if ROLLOVER_TERMINAL[r.phase] then 0 else 1
				if worker_id and (not prior or rank > prior.rank or (rank == prior.rank and revision > prior.revision)) then
					latest_rollover[worker_id] = { rank = rank, revision = revision, view = { id = key, phase = r.phase,
						role = if worker_id == r.predecessor_worker_id then "predecessor" else "successor", hold_code = if r.hold then r.hold.code else nil } }
				end
			end
		end
	end
	table.sort(workflow.rollovers, function(a, b) return a.id < b.id end)
	for _, w in d.workers do
		if w.logical_session_id == session_id then
			local f = w.workflow
			if not f or not f.health then local temporary = clone(w); refresh(d, temporary, nil); f = temporary.workflow end
			local active_action_id, priority
			for key, action in d.actions do
				if action.worker_id == w.worker_id and table.find({ "ready", "claimed", "uncertain", "backpressure" }, action.phase) then
					-- A runnable (ready) action outranks one waiting out its capacity recheck backoff.
					local rank = if action.phase == "claimed" or action.phase == "uncertain" then 1 elseif action.phase == "ready" then 2 else 3
					if not priority or rank < priority or (rank == priority and key < active_action_id) then active_action_id = key; priority = rank end
				end
			end
			local wake_unstarted, wake_uncertain = 0, 0
			for _, wake in w.wakes or {} do
				local action = d.actions[wake.action_id]
				if not action or (action.phase == "ready" and not action.claim) then wake_unstarted += 1
				elseif action.phase == "claimed" or action.phase == "uncertain" then wake_uncertain += 1 end
			end
			local checkpoint = latest_checkpoint(w)
			table.insert(workflow.workers, { worker_id = w.worker_id, work_id = w.work_id, worker_generation = w.worker_generation,
				orch_project_id = w.orch_project_id, open_conversation = w.open_conversation, enrol_delivery = w.enrol_delivery,
				enrol_cancelling = w.enrol_cancelling, prompt_delivery = w.prompt_delivery, checks_pending = w.checks_pending,
				selected_record = clone(w.selected_record), provider = if w.selected_record then w.selected_record.provider else nil,
				account_label = if w.selected_record then w.selected_record.account_label else nil,
				model = if w.selected_record then w.selected_record.model else nil, backend = if w.selected_record then w.selected_record.backend else nil,
				cwd = w.cwd, placement = w.placement, execution_cwd = w.execution_cwd, presentation = w.presentation,
				origin_binding = clone(control_origin(w)), pane_binding = clone(control_binding(w)),
				launch_origin_binding = clone(w.origin_binding), launch_pane_binding = clone(w.pane_binding),
				continuation_required = w.continuation_required == true, continuation_proof = continuation_proof(registry, w), health = clone(f.health), due_poll = f.due_poll,
				poll_continuation = w.pane_binding ~= nil and not w.mailbox_retired and not pending(d, w)
					and continuation_due(d, w, f.health.native_state == "idle" and not (f.native and f.native.delivery_error)),
				cleanup_ready = w.stopped ~= nil and not w.mailbox_retired and registry.sessions[session_id].generation_floor >= control_origin(w).owner_generation
					and (settled(w) or config.start_retirement_settled(d, w)) and not pending(d, w),
				-- Guided reload recovery: a live mailbox worker whose control route is not the
				-- controller's current continued route must be explicitly reattached.
				reattach_needed = w.mailbox_handle ~= nil and w.pane_binding ~= nil and not w.stopped and not w.mailbox_retired
					and (w.continuation_required == true or ((d.command_cursors or {})[session_id] ~= nil
						and not equal(control_origin(w), d.command_cursors[session_id].origin))),
				due_report = f.due_report, report_request_pending = f.report_request ~= nil, active_action_id = active_action_id,
				finish_requested = w.finish ~= nil, coordinator_owner_id = w.coordinator_owner_id, phase = w.phase,
				activation_received = w.activation ~= nil and w.activation.acknowledged,
				due_rollover = (rollover_due(registry, w, f)), rollover = (latest_rollover[w.worker_id] or {}).view,
				wake_pending_count = count(w.wakes or {}), wake_unstarted_count = wake_unstarted, wake_uncertain_count = wake_uncertain,
				orchestration_excluded = table.find(workflow.policy.excluded_workers, w.worker_id) ~= nil,
				context_used_pct = if f.context and f.context.status == "measured" then f.context.used_pct else nil,
				context_seq = if f.context then f.context.seq else nil, context_rollover = config.context_view(workflow.policy, f),
				restored = clone(w.restored), routing = clone(w.routing), launch_action_id = w.launch_action_id, adopt_pane_binding = clone(w.adopt_pane_binding),
				rejected_report = if w.rejected_report then { code = w.rejected_report.code, message = w.rejected_report.message } else nil,
				withdrawal = withdrawal_view(registry, d, w),
				-- Contract A: role and declared (never verified) family; assignment fields as counts; usage
				-- readings are shown only as a delta (CP7), never raw.
				role = w.role, family = config.family_of(d, w), class = w.class, template_id = w.template_id,
				files_count = if w.files then #w.files else 0, checks_count = if w.checks then #w.checks else 0,
				scope = if w.scope then { paths = #w.scope.paths, systems = #w.scope.systems } else nil, source = clone(w.source),
				artifact_revision = if checkpoint then checkpoint.payload.artifact_revision else nil,
				checkout = clone(w.checkout), check_results = clone(w.check_results), report_loop = clone(f.report_loop),
				-- Latest review of a builder's work (Task 3B card); a reviewer names the review it serves.
				review = if w.role == "builder" and config.review_of(d, w) then config.review_view(config.review_of(d, w) :: any) else nil,
				review_id = w.review_id, check_rework = clone(w.check_rework),
				-- D17: raw account readings for the views' quota.usage_delta (after is nil while running).
				usage_before = clone(w.usage_before), usage_after = clone(w.usage_after), usage_shared_with = config.usage_shared_with(d, w) })
			table.insert(workflow.threads, { work_id = w.work_id, entries = clone(f.thread) })
		end
	end
	for _, g in d.gates or {} do if g.logical_session_id == session_id then
		local view = clone(g)
		if decisions then view.decision_context = M.decision_context(registry, { command = "answer", orch_session_id = session_id,
			authority_namespace = registry.authority_namespace, origin = decisions.origin, controller_pane = decisions.controller_pane, gate_id = g.id, gate_revision = g.revision }) end
		local worker = d.workers[g.worker_id]
		local proposal = if worker and g.proposal then codec.decode_report(g.proposal, worker) else nil
		if proposal and proposal.payload.kind == "add_source" and proposal.payload.source.kind == "board"
			and g.answer and g.answer.choice_id == "approve" and g.execution and g.execution.state == "pending" then
			local project_id = g.execution.effect_ref:match("^project:(.+)$")
			if project_id then view.source_request = clone(proposal.payload.source); view.source_request.orch_project_id = project_id end
		end
		table.insert(workflow.gates, view)
	end end
	table.sort(workflow.workers, function(a, b) return a.worker_id < b.worker_id end)
	table.sort(workflow.threads, function(a, b) return a.work_id < b.work_id end)
	table.sort(workflow.gates, function(a, b) return a.id < b.id end)
	local session = registry.sessions[session_id]
	local sessions = {}
	local reconcile_progress
	for sid, current in registry.sessions do
		if sid == session_id and current.admission_seq then
			local cursor = (d.command_cursors or {})[sid]
			local binding = if current.close then current.close.control_origin.binding else (if cursor then cursor.origin else nil)
			if binding and binding.owner_generation <= current.generation_floor then binding = nil end
			local floor, consumed = M.ack_progress(registry, sid)
			if binding then
				reconcile_progress = { authority_namespace = registry.authority_namespace, admission_seq = current.admission_seq,
					generation_floor = current.generation_floor, next_request_serial = current.next_request_serial,
					settled_before = floor, consumed = consumed, outstanding_cursor = clone(current.outstanding_cursor),
					control_origin = if current.close then clone(current.close.control_origin)
						else { kind = "active", binding = clone(binding), controller_pane = cursor.controller_pane } }
			end
			sessions[sid] = { admission_seq = current.admission_seq, control = { phase = current.phase,
				generation_floor = current.generation_floor, request_floor = floor, next_request_serial = current.next_request_serial,
				last_authority_revision = current.last_authority_revision, binding = clone(binding),
				close_id = if current.close then current.close.close_id else nil } }
		end
	end
	return { catalog = clone((d.catalog_pages or {})[session_id] or d.catalogs[session_id]), catalog_complete = (d.catalog_scans or {})[session_id] == false,
		command_cursor = clone((d.command_cursors or {})[session_id]), actions = actions, workers = workers, workflow = workflow,
		projects = workflow.projects, finished_projects = workflow.finished_projects,
		protocol = 2, phase = if registry.compatibility then "stable" else "prepared", authority_namespace = registry.authority_namespace,
		authority_revision = registry.revision, spawn_namespace = if registry.compatibility then registry.compatibility.spawn_namespace else nil,
		compatibility = clone(registry.compatibility or registry.migration), session_control = clone(session),
		sessions = sessions, next_admission_seq = registry.next_admission_seq, reconcile_progress = reconcile_progress,
		control = if session then clone(session.bridge_control) else nil }
end
function M.close_problem(registry: any, sid: string): string?
	local d = registry.dispatch
	if not d then return nil end
	if next((d.family_migrations or {})[sid] or {}) ~= nil then return "Legacy provider declarations still need SPAWN review before this orchestration can be removed." end
	for _, a in d.actions do if a.request.origin_binding.logical_session_id == sid then return "An unresolved action or restored intention remains." end end
	for _, w in d.workers do
		if w.logical_session_id == sid and (not w.mailbox_retired or next(w.receipts or {}) or next(w.replies or {})
			or next(w.wakes or {}) or w.assembly or w.rejected_report or w.accept_pending or w.compaction_pending) then
			return "Worker, mailbox, result or delivery obligations remain."
		end
	end
	for _, g in d.gates or {} do
		if g.logical_session_id == sid and (gate_open(g) or g.ruling or g.ruling_delivery or g.delivery_uncertain
			or (g.delivery and not g.delivery.acknowledged) or (g.execution and g.execution.state == "pending")) then
			return "An operator, document or proposal obligation remains."
		end
	end
	for _, r in d.rollovers or {} do if r.logical_session_id == sid and not ROLLOVER_TERMINAL[r.phase] then return "A handover remains open." end end
	for _, item in (d.landing or {}).items or {} do if item.logical_session_id == sid and not LANDING_TERMINAL[item.status] then return "A landing remains open." end end
	for _, rv in d.reviews or {} do if rv.logical_session_id == sid and config.REVIEW_OPEN[rv.status] then return "Dependent review work remains." end end
	for _, dp in d.deploys or {} do if dp.logical_session_id == sid and not config.DEPLOY_DONE[dp.status] then return "Deployment work remains." end end
	for _, plan in d.plans or {} do if plan.logical_session_id == sid and plan.status == "active" then return "The imported plan still has dependent work." end end
	for _, intake in d.intakes or {} do if intake.logical_session_id == sid and (intake.state == "received" or (intake.state == "accepted" and intake.lane ~= "done")) then return "Intake work remains unfinished." end end
	for _, chain in d.chains or {} do if chain.logical_session_id == sid and chain.status ~= "done" and chain.status ~= "stopped" then return "A work chain remains open." end end
	return nil
end

function M.reclaim_session(candidate: any, sid: string)
	local existing = candidate.dispatch
	if not existing then return end
	-- One copy at the existing transaction seam; remove only the closing session's graph.
	local d = clone(existing); candidate.dispatch = d
	for _, field in { "catalogs", "catalog_pages", "catalog_scans", "sweeps", "policies", "family_migrations", "cleanup_notices", "command_cursors", "capacity" } do if d[field] then d[field][sid] = nil end end
	for key, a in d.actions do if a.request.origin_binding.logical_session_id == sid then d.actions[key] = nil end end
	for _, field in { "workers", "gates", "rollovers", "reviews", "deploys", "plans", "intakes", "chains", "projects" } do
		for key, value in d[field] or {} do if value.logical_session_id == sid then d[field][key] = nil end end
	end
	if d.landing then
		for key, item in d.landing.items do if item.logical_session_id == sid then d.landing.items[key] = nil end end
		for key, queue in d.landing.queues do if queue.logical_session_id == sid then d.landing.queues[key] = nil end end
	end
end

function M.migration_selection(registry: any): any return config.migration.selection(registry) end
function M.migration_identity(registry: any, selection: any): (any?, any?, number, number)
	return config.migration.identity(registry, selection)
end

function M.migrate(candidate: any, selection: any): (boolean, any?)
	local normal, problem, pending_count, blockers = config.migration.identity(candidate, selection)
	if problem then return false, problem end
	if pending_count ~= 0 or blockers ~= 0 then return false, config.refusal("migration_blocked", "Unresolved source obligations prevent paired cutover.") end
	local d = candidate.dispatch
	if d then
		d.gates = d.gates or {}; d.policies = d.policies or {}; d.command_cursors = d.command_cursors or {}
		-- Pre-setup catalog pages are observations, not installation authority.
		-- Drop only that obsolete cache; require a fresh native read, never invent setup.
		for sid, cached in d.catalogs do
			if cached.catalog_version == nil and cached.setup == nil then d.catalogs[sid] = nil end
		end
		config.legacy_upgrade(d)
		config.upgrade_policies(d)
		for _, worker in d.workers do
			if worker.role == nil then worker.role = if worker.coordinator_owner_id then "coordinator" else "builder" end
			-- Old observe intents have no authority fence. Never manufacture a current fence
			-- for them: cutover invalidates only their delivery cursor, not worker evidence.
			flow(worker).observation_cursor = nil
		end
		for _, w in d.workers do
			local launch = d.actions[w.launch_action_id]
			if launch and launch.response and launch.response.status == "rejected" and not w.pane_binding then w.launch_refused = true end
			local retire = if w.mailbox_retire_action_id then d.actions[w.mailbox_retire_action_id] else nil
			if retire and retire.response and retire.response.error and retire.response.error.code == "producer_unsettled" then w.retirement_refused = true end
			w.stop_action_id = nil; w.mailbox_retire_action_id = nil; w.attachment_action_id = nil
			for i = #(w.workflow and w.workflow.thread or {}), 1, -1 do
				local entry = w.workflow.thread[i]
				if entry.state == "settled" then table.remove(w.workflow.thread, i) end
			end
		end
		d.actions = {}; d.commands = nil
		for key, r in d.rollovers or {} do
			if ROLLOVER_TERMINAL[r.phase] then d.rollovers[key] = nil
			else return false, config.refusal("migration_blocked", "A live legacy handover must finish under its original pair.") end
		end
		for _, g in d.gates or {} do
			g.result = nil
			if g.answer and g.answer.source.kind == nil then g.answer.source = config.owner_source(g.answer.source) end
		end
		reclaim_gates(d)
	end
	local seq = 1
	for _, identity in normal.sessions do
		local s = candidate.sessions[identity.logical_session_id]
		s.admission_seq = seq; seq += 1
		-- Admission is re-established only by the validated prepared pair's explicit control.
		s.admitted = nil; s.next_request_serial = 1; s.request_floor = 1
	end
	candidate.next_admission_seq = seq
	return true, nil
end

return M
