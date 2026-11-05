--!strict
-- Pure authority/workflow reducer, embedded in state.authority; never a second KV writer.
local codec = require("./transport")
local quota = require("./quota")
local M = {}
local MAX = 9007199254740991
local PREFIX = "SPAWN_DISPATCH v1 "
local function clone(v: any): any
	if type(v) ~= "table" then return v end
	local out = {}; for k, child in v do out[k] = clone(child) end; return out
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
local function fresh(): any return { serial = 0, actions = {}, workers = {}, commands = {}, catalogs = {}, command_cursors = {} } end
local function next_id(d: any, prefix: string): string d.serial += 1; return prefix .. string.format("%.0f", d.serial) end
-- Read-only operations: no native or mailbox-file effect; SPAWN only records their own outcome.
local READ_ONLY_OPS: any = { catalog = true, mailbox_read = true }
M.READ_ONLY_OPS = READ_ONLY_OPS
local function control_origin(w: any): any return w.control_origin or w.origin_binding end
local function control_pane(w: any): string return w.control_pane or w.controller_pane end
local function control_binding(w: any): any return w.control_pane_binding or w.pane_binding end
-- The claim windows and SPAWN inspect is exactly SPAWN_DISPATCH's `{executor,epoch,grant_id}`.
-- A routed launch's bound USAGE validation (`claim.capacity`) is host-only evidence: SPAWN's window
-- refuses a projected claim with any other field, so exposing it left every quota-routed launch's
-- window authorization unconsumed until it expired (`full`, resource window_authorization).
local function public_claim(c: any): any
	return if c == nil then nil else { executor = c.executor, epoch = c.epoch, grant_id = c.grant_id }
end
M.public_claim = public_claim
-- A sequenced window observation (observe with observation_seq) keeps no command outcome.
-- Replay safety comes from the durable command_seq barrier instead: its commit advances the
-- session cursor to its command_seq, so any replay of it (same request ID, same or older
-- command_seq) is refused as stale_command before it can touch evidence, and the per-worker
-- observation_cursor refuses older observation_seq. The window never consumes observe
-- results (workflow-only), so losing the "replayed success" answer is not observable to it.
local function bounded_observation(event: any): boolean
	return type(event) == "table" and event.kind == "dispatch" and event.command == "observe" and event.observation_seq ~= nil
end
-- A poll (always sequenced) keeps no command outcome either, on the same barrier: it only
-- schedules the next mailbox operation, and the action it queued is itself retained. The window
-- sends every poll with a fresh request ID and reads only the live answer, so an exact replay
-- (refused stale_command) is a duplicate delivery, never a client waiting on its outcome.
local function unretained(event: any): boolean
	return bounded_observation(event) or (type(event) == "table" and event.kind == "dispatch" and event.command == "poll" and event.command_seq ~= nil)
end
-- Effect commands (claim/result/lost) carry no command_seq; the action itself fences their
-- replays: a claim needs phase "ready", a result or lost needs the action's current claim grant,
-- and an exact duplicate result short-circuits on a.response_grant/a.response_bytes before any
-- clone. A retained effect outcome is therefore kept only while it is its action's current
-- evidence, and never repeats bytes the action already holds:
-- - claim: until a result settles its grant (the answer omits the request; the action holds it);
-- - lost: while its grant is still the action's claim;
-- - result: the newest one per action, while its grant is a.response_grant. Its event omits
--   response_bytes: only a result commit writes a.response_bytes, so they are exactly these.
-- Any other replay is answered by those fences: a refusal, never a second grant or effect.
local EFFECT_COMMANDS: any = { claim = true, result = true, lost = true }
local function effect_command(event: any): boolean
	return type(event) == "table" and event.kind == "dispatch" and EFFECT_COMMANDS[event.command] == true
end
local function effect_current(d: any, key: string, command: any, newest: any): boolean
	local e = command.event
	local a = if type(e.action_id) == "string" then d.actions[e.action_id] else nil
	if a == nil or a.claim == nil then return false end
	if e.command == "claim" then
		local claim = command.result.claim
		return type(claim) == "table" and claim.grant_id == a.claim.grant_id and a.response_grant ~= claim.grant_id
	elseif e.command == "lost" then return e.grant_id == a.claim.grant_id end
	return newest[e.action_id] == key and a.response_grant == e.grant_id and a.response_bytes ~= nil
		and (e.response_bytes == nil or e.response_bytes == a.response_bytes)
end
-- Applied after every remembered commit and once at restore (legacy full records are compacted
-- or dropped there). O(commands); it never touches sequenced or reconciliation outcomes.
local function prune_effects(d: any)
	local newest, at = {}, {}
	for key, command in d.commands do
		local e = command.event
		if effect_command(e) and e.command == "result" and type(e.action_id) == "string" then
			local revision, best = command.revision or 0, newest[e.action_id]
			if best == nil or revision > at[e.action_id] or (revision == at[e.action_id] and key > best) then newest[e.action_id] = key; at[e.action_id] = revision end
		end
	end
	for key, command in d.commands do
		if effect_command(command.event) then
			if not effect_current(d, key, command, newest) then d.commands[key] = nil
			elseif command.event.command == "result" then command.event.response_bytes = nil
			elseif command.event.command == "claim" then command.result.request = nil end
		end
	end
end
-- The retained form of an incoming duplicate: a kept result outcome stands for its action's
-- exact response bytes (see effect_current), so identical bytes compare without them.
local function retained_input(d: any, retained: any, event: any): any
	if retained.command ~= "result" or retained.response_bytes ~= nil or event.command ~= "result" or event.action_id ~= retained.action_id then return event end
	local a = d.actions[retained.action_id]
	if a == nil or a.response_bytes ~= event.response_bytes then return event end
	local stripped = table.clone(event); stripped.response_bytes = nil; return stripped
end
-- A compacted result outcome whose action no longer holds its grant's bytes proves nothing; the
-- reducer's own fences answer that replay instead (stale_claim), exactly as after pruning.
local function verifiable(d: any, retained: any): boolean
	if retained.command ~= "result" or retained.response_bytes ~= nil then return true end
	local a = d.actions[retained.action_id]
	return a ~= nil and a.response_grant == retained.grant_id and a.response_bytes ~= nil
end
local function remember(d: any, event: any, answer: any, revision: number)
	if not unretained(event) then d.commands[event.request_id] = { event = clone(event), result = clone(answer), revision = revision } end
	if event.command_seq then
		d.command_cursors = d.command_cursors or {}
		local prior = d.command_cursors[event.orch_session_id]
		d.command_cursors[event.orch_session_id] = { origin = clone(event.origin), controller_pane = event.controller_pane, seq = event.command_seq,
			continued_epoch = if prior and equal(prior.origin, event.origin) then prior.continued_epoch else nil }
	end
	prune_effects(d)
	local settled = {}
	for key, command in d.commands do
		if unretained(command.event) then
			-- One-time cleanup of outcomes retained before this rule; every one is already behind
			-- the cursor (restore validation requires command_seq <= cursor.seq).
			d.commands[key] = nil
			continue
		end
		local action = d.actions[command.event.action_id or command.result.action_id]
		if command.event.kind == "dispatch" and (not action or action.phase == "complete" or action.phase == "resolved") then
			table.insert(settled, { key = key, revision = command.revision or 0 })
		end
	end
	table.sort(settled, function(a, b) return a.revision < b.revision or (a.revision == b.revision and a.key < b.key) end)
	for i = 1, #settled - 256 do d.commands[settled[i].key] = nil end
end
local function execution_origin(d: any, a: any): any
	local cursor = (d.command_cursors or {})[a.request.origin_binding.logical_session_id]
	if cursor and cursor.continued_epoch and cursor.origin.owner_id == a.request.origin_binding.owner_id
		and cursor.origin.owner_generation == a.request.origin_binding.owner_generation then return cursor.origin end
	return a.request.origin_binding
end
local function common(d: any, origin: any, pane: string, op: string): any
	return { schema = 1, origin = "orchplus", op = op, request_id = next_id(d, "request-"), action_id = next_id(d, "action-"),
		origin_binding = clone(origin), controller_pane = pane, controller_generation = origin.owner_generation }
end
local function add(d: any, request: any, worker_id: string?): any
	local encoded = tern.json.encode(request)
	if #encoded > 8192 then return nil end
	local action = { request = request, request_bytes = encoded, phase = "ready", worker_id = worker_id }
	d.actions[request.action_id] = action; return action
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
	-- Explicit verified attach of a hand-opened native agent: same enrolment, delivered by SPAWN
	-- native ask to the exact attested pane instead of a fresh launch.
	if w.adopt_pane_binding then
		return { schema = 1, origin = "orchplus", op = "adopt", request_id = w.launch_request_id, action_id = w.launch_action_id,
			origin_binding = clone(w.origin_binding), controller_pane = w.controller_pane, controller_generation = w.origin_binding.owner_generation,
			record_id = w.record_id, record_revision = w.record_revision, work_id = w.work_id, prompt = w.prompt, mailbox_handle = handle,
			enrolment = { worker_id = w.worker_id, worker_generation = w.worker_generation, enrolment_token = w.enrolment_token, assignment_sha256 = w.assignment_sha256 },
			pane_binding = clone(w.adopt_pane_binding), attestation = ADOPT_ATTESTATION }
	end
	return { schema = 1, origin = "orchplus", op = "launch", request_id = w.launch_request_id, action_id = w.launch_action_id,
		origin_binding = clone(w.origin_binding), controller_pane = w.controller_pane, controller_generation = w.origin_binding.owner_generation,
		record_id = w.record_id, record_revision = w.record_revision, work_id = w.work_id, prompt = w.prompt, cwd = w.cwd, placement = w.placement,
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
		if a.worker_id == w.worker_id and (a.phase == "ready" or a.phase == "claimed" or (a.phase == "backpressure" and not watermark)
			or (a.phase == "uncertain" and not (retained_reads and READ_ONLY_OPS[a.request.op]))) then return true end
	end
	return false
end
function M.unresolved(registry: any, session_id: string, owner_id: string): boolean
	for _, a in (registry.dispatch or fresh()).actions do
		local w = if a.worker_id then registry.dispatch.workers[a.worker_id] else nil
		if a.request.origin_binding.logical_session_id == session_id and (a.request.origin_binding.owner_id == owner_id or (w and w.coordinator_owner_id == owner_id))
			and (a.phase == "claimed" or a.phase == "uncertain") then return true end
	end
	return false
end
function M.decode_response(bytes: any, request: any): (any?, any?)
	if type(bytes) ~= "string" or #bytes > 8192 or bytes:sub(1, #PREFIX) ~= PREFIX then return fail("bridge_incompatible", "Install a compatible SPAWN dispatch bridge; complete SPAWN_DISPATCH v1 data is required.") end
	local frame, err = codec.strict_decode(bytes:sub(#PREFIX + 1), 8192)
	if err then return nil, err end
	if not closed(frame, "schema op request_id complete body_bytes body_sha256 body_json") or frame.schema ~= 1 or frame.complete ~= true
		or frame.op ~= request.op or frame.request_id ~= request.request_id or not str(frame.body_json, 8192)
		or frame.body_bytes ~= #frame.body_json or frame.body_sha256 ~= codec.sha256(frame.body_json) then return fail("bridge_incomplete", "SPAWN response framing/hash/correlation mismatch; no effect accepted.") end
	local body, diagnostic = codec.strict_decode(frame.body_json, 8192)
	if diagnostic then return nil, diagnostic end
	if not closed(body, "schema op request_id action_id origin_binding controller_generation status payload error") or body.schema ~= 1
		or body.op ~= request.op or body.request_id ~= request.request_id or body.action_id ~= request.action_id
		or body.controller_generation ~= request.controller_generation or not equal(body.origin_binding, request.origin_binding)
		or not str(body.status, 96) then return fail("binding_mismatch", "SPAWN response belongs to a different immutable request.") end
	if body.error ~= nil and (not closed(body.error, "code message detail") or not str(body.error.code, 96)
		or (body.error.message ~= nil and not str(body.error.message, 512, true))
		or (body.error.detail ~= nil and not str(body.error.detail, 512, true))) then return fail("invalid_schema", "SPAWN error detail is not a bounded public prerequisite.") end
	if body.status == "full" and not full_payload(body.payload) then
		return fail("invalid_schema", "SPAWN full requires bounded resource/current/limit and, if present, paired boolean retry/effect diagnostics.")
	end
	if body.status == "stopped" and (request.op ~= "stop" or not closed(body.payload, "pane_binding observation")
		or not equal(body.payload.pane_binding, request.pane_binding) or not table.find({ "absent", "exited" }, body.payload.observation)) then
		return fail("binding_mismatch", "Stopped outcome must bind the exact issued pane and fresh native absence/exit observation.")
	end
	if body.status == "attached" and (request.op ~= "attach_worker" or not closed(body.payload, "pane_binding previous_origin_binding previous_pane_binding")
		or not equal(body.payload.pane_binding, request.pane_binding) or not equal(body.payload.previous_origin_binding, request.previous_origin_binding)
		or not equal(body.payload.previous_pane_binding, request.previous_pane_binding)) then
		return fail("binding_mismatch", "Attachment outcome must preserve the original launch binding and confirm the exact selected current pane.")
	end
	if type(body.payload) == "table" and body.payload.wake_status == "awaiting_window" and body.payload.wake_effect_started == false
		and (not table.find({ "mailbox_publish_ack", "mailbox_publish_reply" }, request.op)
			or not id(body.payload.wake_target_request_id) or not id(body.payload.wake_target_action_id)) then
		return fail("binding_mismatch", "Unstarted deferred wake must identify its canonical immutable publication.")
	end
	return body, nil
end
local function pane_binding(v: any, origin: any): boolean
	return closed(v, "pane_id window_epoch window_key native_session_id window_host_id") and str(v.pane_id, 96) and v.pane_id:match("^%d+$") ~= nil
		and v.window_epoch == origin.window_epoch and v.window_key == origin.window_key and v.native_session_id == origin.native_session_id and v.window_host_id == origin.window_host_id
end
local function catalog(v: any, legacy_cache: boolean?): boolean
	if not closed(v, "revision records next_cursor namespace host_key config_revision") or not (v.revision == 0 or pos(v.revision)) or type(v.records) ~= "table" or #v.records > 256 then return false end
	local legacy = legacy_cache == true and v.namespace == nil and v.host_key == nil and v.config_revision == nil
	if not legacy and (not str(v.namespace, 256) or not str(v.host_key, 256) or v.config_revision ~= v.revision) then return false end
	if v.next_cursor ~= nil and (not closed(v.next_cursor, "revision index") or v.next_cursor.revision ~= v.revision or not pos(v.next_cursor.index)) then return false end
	for _, r in v.records do
		if not closed(r, "id revision provider account_label backend enabled eligible capabilities unsupported model_variant profile_variant selector_evidence capacity_binding cwd placement capability_evidence effective_identity")
			or not str(r.id, 96) or not (r.revision == 0 or pos(r.revision)) or type(r.eligible) ~= "boolean" or type(r.capabilities) ~= "table" or type(r.unsupported) ~= "table" then return false end
	end
	return true
end
local request_fields = {
	catalog = "cursor",
	launch = "record_id record_revision work_id prompt cwd placement fresh mailbox_handle enrolment",
	adopt = "record_id record_revision work_id prompt mailbox_handle enrolment pane_binding attestation",
	stop = "target_request_id target_action_id pane_binding worker_id worker_generation enrolment_token work_id",
	accept = "target_request_id target_action_id pane_binding worker_id worker_generation enrolment_token work_id event_id seq event_sha256 handover_id handover_token",
	attach_worker = "target_request_id target_action_id previous_origin_binding previous_pane_binding pane_binding worker_id worker_generation enrolment_token work_id attestation",
	native_wake = "target_request_id target_action_id",
	mailbox_provision = "logical_session_id worker_id worker_generation launch_request_id work_id enrolment_token record_id record_revision capability handover_id handover_sha256",
	mailbox_read = "logical_session_id worker_id worker_generation launch_request_id work_id enrolment_token handle expected_generation selector",
	mailbox_publish_ack = "logical_session_id worker_id worker_generation launch_request_id work_id enrolment_token handle expected_generation receipt_revision ack_b64 ack_sha256",
	mailbox_publish_reply = "logical_session_id worker_id worker_generation launch_request_id work_id enrolment_token handle expected_generation message_id reply_seq action_revision reply_sha256 part index object_b64 object_sha256",
	mailbox_retire = "logical_session_id worker_id worker_generation launch_request_id work_id enrolment_token handle expected_generation mode settlement_revision report_floor report_chain_sha256 reply_floor grant_id",
}
-- Held, never-launched work whose launch or adoption ask SPAWN definitively rejected after its
-- mailbox was provisioned. SPAWN stores a launch/adopt rejection only before any native call (an
-- adoption `refused` result is reported before the ask), so no pane exists and no producer ever
-- ran: its mailbox retires without a native stop when the owner cancels the work (cancel_work).
local function launch_rejected(d: any, w: any): boolean
	local launch = d.actions[w.launch_action_id]
	return w.phase == "held" and w.mailbox_handle ~= nil and w.pane_binding == nil and w.control_origin == nil and w.accepted_event == nil
		and w.handover_id == nil and w.stopped == nil and launch ~= nil and launch.phase == "complete" and launch.response ~= nil
		and launch.response.status == "rejected" and (launch.request.op == "launch" or launch.request.op == "adopt")
end
local function valid_request(r: any, w: any, d: any): boolean
	local extra = request_fields[r.op]
	if extra == nil or not closed(r, "schema origin op request_id action_id origin_binding controller_pane controller_generation " .. extra)
		or r.schema ~= 1 or r.origin ~= "orchplus" or not id(r.request_id) or not id(r.action_id)
		or not str(r.controller_pane, 96) or r.controller_pane:match("^%d+$") == nil or r.controller_generation ~= r.origin_binding.owner_generation then return false end
	if r.op == "catalog" then return w == nil end
	if type(w) ~= "table" or r.origin_binding.logical_session_id ~= w.logical_session_id
		or r.origin_binding.owner_id ~= w.origin_binding.owner_id or r.origin_binding.owner_generation ~= w.origin_binding.owner_generation
		or r.origin_binding.host_pane_id ~= w.origin_binding.host_pane_id or r.origin_binding.alias_nonce ~= w.origin_binding.alias_nonce then return false end
	if r.op == "attach_worker" then
		return r.target_request_id == w.launch_request_id and r.target_action_id == w.launch_action_id
			and equal(r.previous_origin_binding, w.origin_binding) and equal(r.previous_pane_binding, w.pane_binding)
			and pane_binding(r.pane_binding, r.origin_binding) and r.worker_id == w.worker_id and r.worker_generation == w.worker_generation
			and r.enrolment_token == w.enrolment_token and r.work_id == w.work_id and r.attestation == "old_executors_stopped_or_retired"
	end
	local route_known = equal(r.origin_binding, w.origin_binding) and r.controller_pane == w.controller_pane
	if not route_known then
		for _, attachment in d.actions do
			local request = if type(attachment) == "table" then attachment.request else nil
			local response = if type(attachment) == "table" then attachment.response else nil
			if type(request) == "table" and request.op == "attach_worker" and attachment.worker_id == w.worker_id
				and attachment.phase == "complete" and type(response) == "table" and response.status == "attached"
				and equal(request.origin_binding, r.origin_binding) and request.controller_pane == r.controller_pane
				and closed(response.payload, "pane_binding previous_origin_binding previous_pane_binding")
				and equal(response.payload.pane_binding, request.pane_binding) and equal(response.payload.previous_origin_binding, w.origin_binding)
				and equal(response.payload.previous_pane_binding, w.pane_binding) then route_known = true; break end
		end
	end
	-- A provision that is no longer ready keeps its exact request after explicit continuation
	-- moved its never-launched worker to the continued route (rebind_unlaunched). Its SPAWN
	-- mailbox binding carries no window route; owner incarnation and alias are checked above.
	if not route_known and r.op == "mailbox_provision" then
		local a = d.actions[r.action_id]; route_known = a ~= nil and a.phase ~= "ready"
	end
	-- A withdrawn rejected launch retires its unused mailbox on the route the owner cancelled from
	-- (earlier refused or revoked attempts keep their own exact route).
	if not route_known and r.op == "mailbox_retire" and r.mode == "retire" and launch_rejected(d, w) then
		route_known = true
	end
	if not route_known then return false end
	if r.op == "native_wake" then
		local target = d.actions[r.target_action_id]
		return id(r.target_request_id) and type(target) == "table" and type(target.request) == "table" and target.worker_id == w.worker_id
			and target.request.request_id == r.target_request_id and (target.request.op == "mailbox_publish_ack"
				or (target.request.op == "mailbox_publish_reply" and target.request.part == "manifest"))
	end
	if r.op == "launch" or r.op == "adopt" then return equal(r, launch_request(w, w.mailbox_handle)) end
	if r.op == "stop" then
		return r.target_request_id == w.launch_request_id and r.target_action_id == w.launch_action_id
			and pane_binding(r.pane_binding, r.origin_binding) and r.worker_id == w.worker_id and r.worker_generation == w.worker_generation
			and r.enrolment_token == w.enrolment_token and r.work_id == w.work_id and (w.release ~= nil or w.finish ~= nil)
	end
	if r.op == "accept" then
		return r.target_request_id == w.launch_request_id and r.target_action_id == w.launch_action_id
			and pane_binding(r.pane_binding, r.origin_binding) and r.worker_id == w.worker_id and r.worker_generation == w.worker_generation
			and r.enrolment_token == w.enrolment_token and r.work_id == w.work_id and w.accepted_event ~= nil
			and r.event_id == w.accepted_event.event_id and r.seq == w.accepted_event.seq and r.event_sha256 == w.accepted_event.event_sha256
			and r.handover_id == w.handover_id and r.handover_token == w.handover_token
	end
	for _, k in B do if r[k] ~= w[k] then return false end end
	if r.enrolment_token ~= w.enrolment_token then return false end
	if r.op == "mailbox_provision" then
		-- Provisions retained from builds before the handover digest carry neither field.
		return r.record_id == w.record_id and r.record_revision == w.record_revision and r.capability == "report-files-v1"
			and (r.handover_id == nil and r.handover_sha256 == nil or r.handover_id == w.handover_id and r.handover_sha256 == handover_sha256(w))
	end
	if r.handle ~= w.mailbox_handle or r.expected_generation ~= w.worker_generation then return false end
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
-- auto_rollover/rollover_threshold_pct/rollover_include_coordinator drive the automatic rollover
-- request and excluded_workers gates automatic scheduling. quota_routing plus the quota_* settings
-- and the plan §7 strict schema drive USAGE quota routing (quota.luau): initial_dispatch_*,
-- worker_rollover_* and coordinator_rollover_* each carry an explicit record allowlist and
-- independent provider/account/model substitution permissions; missing permission is false.
-- concurrency_limit (0 = not configured) bounds this session's routed launch reservations.
local DEFAULT_POLICY = { paused = false, poll_ms = 5000, heartbeat_ms = 60000, stale_ms = 180000, automatic_reports = false,
	auto_rollover = false, rollover_threshold_pct = 80, rollover_include_coordinator = false, quota_routing = false, excluded_workers = {},
	quota_reserve_pct = 10, quota_max_age_ms = 900000, initial_dispatch_records = {}, initial_dispatch_provider = false,
	initial_dispatch_account = false, initial_dispatch_model = false, sweep_enabled = true, sweep_time = "03:00",
	worker_rollover_records = {}, worker_rollover_provider = false, worker_rollover_account = false, worker_rollover_model = false,
	coordinator_rollover_records = {}, coordinator_rollover_provider = false, coordinator_rollover_account = false, coordinator_rollover_model = false,
	concurrency_limit = 0 }
local LEGACY_POLICY_KEYS = "paused poll_ms heartbeat_ms stale_ms automatic_reports"
local CP3_POLICY_KEYS = LEGACY_POLICY_KEYS .. " auto_rollover rollover_threshold_pct rollover_include_coordinator quota_routing excluded_workers"
local QUOTA_EDITABLE_KEYS = "poll_ms heartbeat_ms stale_ms automatic_reports auto_rollover rollover_threshold_pct rollover_include_coordinator quota_routing excluded_workers quota_reserve_pct quota_max_age_ms initial_dispatch_records initial_dispatch_provider initial_dispatch_account initial_dispatch_model"
local SWEEP_EDITABLE_KEYS = QUOTA_EDITABLE_KEYS .. " sweep_enabled sweep_time"
local EDITABLE_POLICY_KEYS = SWEEP_EDITABLE_KEYS .. " worker_rollover_records worker_rollover_provider worker_rollover_account worker_rollover_model coordinator_rollover_records coordinator_rollover_provider coordinator_rollover_account coordinator_rollover_model concurrency_limit"
local REPORT_KINDS = { "REGISTER", "ACCEPTED", "reply_ack", "COORDINATOR_RELEASE", "READY", "HEARTBEAT", "WAITING", "BLOCKED", "ASK",
	"CHECKPOINT", "REVIEW_READY", "REVIEW_RESULT", "DONE", "ROLLOVER_REQUEST", "LANDING_REQUEST", "LANDING_RESULT", "COORDINATOR_PROPOSAL" }
local function policy(d: any, session: string): any return (d.policies or {})[session] or DEFAULT_POLICY end
local function migrate_policy(p: any): any
	-- CP2/CP3 stored policies predate later Config fields; fill only the documented defaults.
	local out = clone(DEFAULT_POLICY); for k, v in p do out[k] = clone(v) end; return out
end
local function sorted_ids(v: any, maximum: number): boolean
	if type(v) ~= "table" or v == tern.json.null or #v > maximum or count(v) ~= #v then return false end
	for k in v do if type(k) ~= "number" or k < 1 or k > #v or k % 1 ~= 0 then return false end end
	for i, worker_id in v do if not id(worker_id) or (i > 1 and v[i - 1] >= worker_id) then return false end end
	return true
end
-- Explicit record allowlist: distinct, canonical order, no wildcard entries.
local function record_set(v: any, maximum: number): boolean
	if type(v) ~= "table" or v == tern.json.null or #v > maximum or count(v) ~= #v then return false end
	for k in v do if type(k) ~= "number" or k < 1 or k > #v or k % 1 ~= 0 then return false end end
	for i, record_id in v do if not str(record_id, 96) or record_id:find("[%*%?]") or (i > 1 and v[i - 1] >= record_id) then return false end end
	return true
end
-- Local wall-clock "HH:MM" (24-hour) for the nightly mailbox sweep.
local function sweep_clock(v: any): boolean
	if type(v) ~= "string" or #v ~= 5 then return false end
	local hour, minute = v:match("^(%d%d):(%d%d)$")
	return hour ~= nil and (tonumber(hour) or 99) <= 23 and (tonumber(minute) or 99) <= 59
end
local function valid_policy(p: any, legacy: boolean?): boolean
	-- Exactly-CP2, exactly-CP3, exactly-pre-sweep and exactly-pre-rollover-routing policies are
	-- accepted only at the explicit restore boundary, which migrates them.
	if legacy and ((closed(p, LEGACY_POLICY_KEYS) and count(p) == 5) or (closed(p, CP3_POLICY_KEYS) and count(p) == 10)
		or (closed(p, "paused " .. QUOTA_EDITABLE_KEYS) and count(p) == 16) or (closed(p, "paused " .. SWEEP_EDITABLE_KEYS) and count(p) == 18)) then p = migrate_policy(p) end
	if type(p) ~= "table" or p == tern.json.null then return false end
	for _, scope in { "worker_rollover", "coordinator_rollover" } do
		if not record_set(p[scope .. "_records"], quota.MAX_RECORDS) or type(p[scope .. "_provider"]) ~= "boolean"
			or type(p[scope .. "_account"]) ~= "boolean" or type(p[scope .. "_model"]) ~= "boolean" then return false end
	end
	if not (p.concurrency_limit == 0 or pos(p.concurrency_limit)) or p.concurrency_limit > quota.MAX_CONCURRENCY then return false end
	return closed(p, "paused " .. EDITABLE_POLICY_KEYS) and type(p.paused) == "boolean" and type(p.automatic_reports) == "boolean"
		and pos(p.poll_ms) and p.poll_ms >= 1000 and p.poll_ms <= 60000 and pos(p.heartbeat_ms) and p.heartbeat_ms >= 5000
		and p.heartbeat_ms <= 3600000 and pos(p.stale_ms) and p.stale_ms >= p.heartbeat_ms and p.stale_ms <= 86400000
		and type(p.auto_rollover) == "boolean" and type(p.rollover_include_coordinator) == "boolean" and type(p.quota_routing) == "boolean"
		and pos(p.rollover_threshold_pct) and p.rollover_threshold_pct <= 99 and sorted_ids(p.excluded_workers, 32)
		and (p.quota_reserve_pct == 0 or pos(p.quota_reserve_pct)) and p.quota_reserve_pct <= 99
		and pos(p.quota_max_age_ms) and p.quota_max_age_ms >= 60000 and p.quota_max_age_ms <= quota.STALE_AFTER_MS
		and record_set(p.initial_dispatch_records, quota.MAX_RECORDS) and type(p.initial_dispatch_provider) == "boolean"
		and type(p.initial_dispatch_account) == "boolean" and type(p.initial_dispatch_model) == "boolean"
		and type(p.sweep_enabled) == "boolean" and sweep_clock(p.sweep_time)
end
function M.policy(registry: any, session_id: string): any return clone(policy(registry.dispatch or fresh(), session_id)) end
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
-- Verified rollover (Checkpoint 4): durable phases, each edge bound to work, both panes, the
-- handover ID and the requesting controller generation. Worker rollover overlaps predecessor and
-- successor until handover acceptance; coordinator rollover never overlaps two managed coordinators.
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
-- Landing queue (Checkpoint 4): open items are queued|verifying|ready|blocked (ungranted) or
-- granted|landing (holding their target's single slot). Terminal items are retained evidence.
local LANDING_STATUSES = { "queued", "verifying", "ready", "granted", "landing", "landed", "failed", "blocked", "cancelled" }
local LANDING_TERMINAL = { landed = true, failed = true, cancelled = true }
local LANDING_UNGRANTED = { queued = true, verifying = true, ready = true, blocked = true }
local function landing_open(d: any, worker_id: string, in_flight: boolean?): any?
	local selected
	for key, item in (d.landing or {}).items or {} do
		if item.worker_id == worker_id and not LANDING_TERMINAL[item.status] and (not in_flight or not LANDING_UNGRANTED[item.status])
			and (not selected or key < selected.id) then selected = item end
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
-- A retired coordinator pane observed alive again (native restoration) holds every coordinator
-- effect in its session until reconciled; it is never counted as a healthy coordinator.
local function restored_coordinator(d: any, session_id: string): any?
	for _, w in d.workers do
		if w.logical_session_id == session_id and w.restored and not w.restored.reconciled then return w end
	end
	return nil
end
-- Outbound settlement a poll would grant without reading the report lane: ACK/reply
-- publication, acceptance, compaction, an answered decision or a startable native wake.
local function outbound_due(d: any, w: any, wake_ready: boolean): boolean
	local wakes = count(w.wakes or {})
	if w.accept_pending or w.compaction_pending then return true end
	for _, receipt in w.receipts do if receipt.publish and wakes < 32 then return true end end
	for _, g in d.gates or {} do if g.worker_id == w.worker_id and g.phase == "answered" then return true end end
	for _, reply in w.replies do if not reply.acknowledged and reply.part <= #reply.frames.chunks + 1 and wakes < 32 then return true end end
	if wake_ready then for _, wake in w.wakes or {} do if not wake.action_id then return true end end end
	return false
end
local function refresh(d: any, w: any, clock: any)
	local f, p = flow(w), policy(d, w.logical_session_id)
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
	f.due_poll = w.pane_binding ~= nil and not w.mailbox_retired and (since == nil or since >= p.poll_ms) and not pending(d, w)
		and (not held or outbound_due(d, w, native == "idle" and not (f.native and f.native.delivery_error)))
	local safe = not (f.native and f.native.delivery_error) and (native == "idle" or (native == "unknown" and table.find(w.capabilities or {}, "worker-poll-v1") ~= nil))
	-- Owner-excluded workers are never chosen for automatic report requests; observation and
	-- mailbox settlement continue, and exclusion never stops or retires anything.
	f.due_report = not p.paused and p.automatic_reports and w.phase == "accepted" and not w.release and not w.retirement and not w.finish
		and not held and not g and safe and f.report_request == nil and required_age ~= nil and required_age >= p.heartbeat_ms
		and table.find(p.excluded_workers, w.worker_id) == nil and active_rollover(d, w) == nil
end
-- Policy-driven rollover only *requests* a checkpoint; every later edge needs its own evidence.
-- Coordinators are eligible only with rollover_include_coordinator and an active, activated owner.
local function rollover_due(registry: any, w: any, f: any): (boolean, string)
	local d = registry.dispatch
	local p = policy(d, w.logical_session_id)
	if not p.auto_rollover then return false, "Automatic rollover is off in Config." end
	if p.paused then return false, "Session is paused." end
	if table.find(p.excluded_workers, w.worker_id) ~= nil then return false, "Worker is excluded from automatic orchestration in Config." end
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
	if not f.context or f.context.used_pct < p.rollover_threshold_pct then return false, "Latest worker-reported context is below the rollover threshold." end
	if not f.health or f.health.status ~= "idle" or f.report_request ~= nil or gate_for(d, w) then
		return false, "Worker is not idle at a clean point (no outstanding request, gate or busy native state)."
	end
	return true, "Worker-reported context reached the rollover threshold."
end
local function append(d: any, w: any, kind: string, summary: string, clock: any, refs: any?): (any?, any?)
	local entries = flow(w).thread
	if #entries >= 128 then
		local remove
		for i, entry in entries do if entry.state == "settled" then remove = i; break end end
		if not remove then return fail("full", "Durable work thread is full of unresolved items; no evidence was evicted.") end
		table.remove(entries, remove)
	end
	local entry = { id = next_id(d, "entry-"), kind = kind, summary = summary:sub(1, 32768), at_ms = stamp(clock).at_ms, state = "settled" }
	for k, v in refs or {} do entry[k] = clone(v) end
	table.insert(entries, entry); return entry, nil
end
local function settle_entries(w: any, key: string, value: any)
	for _, entry in flow(w).thread do if entry[key] == value then entry.state = "settled" end end
end
local function reclaim_gates(d: any)
	for key, g in d.gates or {} do
		-- Typed proposals/results remain CP4 evidence, even after delivery ACK.
		if not g.proposal and not gate_open(g) and (not g.delivery or g.delivery.acknowledged) and not g.delivery_uncertain then
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
local function work_referenced(d: any, w: any): boolean
	if active_rollover(d, w) or landing_open(d, w.worker_id) then return true end -- Unfinished handovers and open landing items pin generations.
	for _, g in d.gates or {} do
		if g.proposal then
			local source = d.workers[g.worker_id]
			local proposal = if source then codec.decode_report(g.proposal, source) else nil
			if g.worker_id == w.worker_id or (proposal and proposal.payload.work_id == w.work_id) then return true end
		elseif g.worker_id == w.worker_id and (gate_open(g) or (g.delivery and not g.delivery.acknowledged)) then return true end
	end
	-- Landing evidence is pinned by its open queue item, not by the latest report kind.
	local evidence = flow(w).evidence
	return evidence.ROLLOVER_REQUEST ~= nil or evidence.REVIEW_READY ~= nil or evidence.REVIEW_RESULT ~= nil
end
local function reclaim_workers(registry: any)
	local d = registry.dispatch
	reclaim_gates(d)
	for key, w in d.workers do
		local owner = registry.sessions[w.logical_session_id].orchestrator
		if w.mailbox_retired and not (owner and owner.managed_worker_id == key) and not pending(d, w) and not work_referenced(d, w) then
			for action_id, action in d.actions do
				if action.worker_id == key then d.actions[action_id] = nil end
			end
			-- Monotonic IDs and command_cursors survive settled-record reclamation.
			d.workers[key] = nil
		end
	end
	-- Exclusions name durable workers only; drop entries whose settled worker was reclaimed.
	for _, p in d.policies or {} do
		for i = #p.excluded_workers, 1, -1 do if not d.workers[p.excluded_workers[i]] then table.remove(p.excluded_workers, i) end end
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
local function dense(v: any, maximum: number, minimum: number?): boolean
	if type(v) ~= "table" or v == tern.json.null or #v < (minimum or 0) or #v > maximum or count(v) ~= #v then return false end
	for k in v do if not pos(k) or k > #v then return false end end
	return true
end
local function valid_delivery(r: any, w: any): boolean
	if r.reply_seq > w.reply_seq then return false end
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
local function valid_flow(d: any, w: any): boolean
	local f = w.workflow
	if f == nil then return true end -- Explicit additive CP2 migration; no inferred reports.
	if not closed(f, "thread evidence checkpoints native report last_poll health due_poll due_report report_request observation_cursor started exit context empty_read")
		or not dense(f.thread, 128) or type(f.evidence) ~= "table" or f.evidence == tern.json.null or count(f.evidence) > 16
		or type(f.checkpoints) ~= "table" or f.checkpoints == tern.json.null or count(f.checkpoints) > 16 or type(f.due_poll) ~= "boolean" or type(f.due_report) ~= "boolean" then return false end
	if f.started ~= nil and (not closed(f.started, "at_ms mono_ms epoch") or not valid_stamp(f.started)) then return false end
	if f.exit ~= nil and (not closed(f.exit, "at_ms mono_ms epoch state") or not valid_stamp(f.exit)
		or f.exit.state ~= "exited" or (f.exit.epoch == nil and not w.stopped)) then return false end
	-- Latest worker-reported context usage, bound to the accepted report sequence that carried it.
	if f.context ~= nil and (not closed(f.context, "used_pct seq") or type(f.context.used_pct) ~= "number" or f.context.used_pct < 0
		or f.context.used_pct > 100 or f.context.used_pct % 1 ~= 0 or not pos(f.context.seq) or f.context.seq > w.accepted_seq) then return false end
	-- The poll that issued this generation's last report read of `slot` that found nothing (see poll_idle).
	if f.empty_read ~= nil and (not closed(f.empty_read, "at_ms mono_ms epoch slot") or not valid_stamp(f.empty_read) or not id(f.empty_read.epoch)
		or not pos(f.empty_read.slot) or f.empty_read.slot > w.accepted_seq + 1) then return false end
	if f.observation_cursor then
		local cursor = f.observation_cursor
		if not closed(cursor, "seq event") then return false end
		local e = cursor.event
		if not pos(cursor.seq)
			or not closed(e, "kind request_id orch_session_id origin controller_pane command command_seq worker_id pane_binding native_state delivery_error observation_seq")
			or e.kind ~= "dispatch" or e.command ~= "observe" or not id(e.request_id) or e.observation_seq ~= cursor.seq or e.worker_id ~= w.worker_id
			or e.orch_session_id ~= w.logical_session_id or not equal(e.origin, control_origin(w)) or not equal(e.pane_binding, control_binding(w))
			or not str(e.controller_pane, 96) or not table.find({ "working", "idle", "waiting-input", "exited", "unknown" }, e.native_state)
			or (e.delivery_error ~= nil and not str(e.delivery_error, 1024)) then return false end
		local commands = (d.command_cursors or {})[w.logical_session_id]
		if e.command_seq ~= nil and (not pos(e.command_seq) or not commands or e.command_seq > commands.seq) then return false end
	end
	for _, entry in f.thread do
		if not closed(entry, "id kind summary at_ms state gate_id action_id request_id event_id report_bytes") or not id(entry.id) or not str(entry.kind, 96)
			or not wire_text(entry.summary, 32768) or not (entry.at_ms == 0 or pos(entry.at_ms)) or not table.find({ "pending", "settled" }, entry.state) then return false end
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
		if not reply or reply.kind ~= "report_request" or reply.payload.request_id ~= r.request_id or reply.message_id ~= r.message_id
			or reply.reply_seq ~= r.reply_seq or reply.action_id ~= r.action_id or reply.action_revision ~= r.action_revision or r.reply_seq > w.reply_seq then return false end
		if not valid_delivery(r, w) then return false end
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
		for sid, p in d.policies do if not registry.sessions[sid] or not valid_policy(p, legacy) then return false end end
	end
	if d.gates == nil then return true end
	if type(d.gates) ~= "table" or count(d.gates) > 64 then return false end
	for key, g in d.gates do
		if not closed(g, "id revision work_id worker_id worker_generation logical_session_id pane_binding kind phase question options evidence proposal at_ms answer delivery delivery_uncertain recheck result")
			or not id(key) or g.id ~= key or not pos(g.revision) or not wire_text(g.question, 32768) or not (g.at_ms == 0 or pos(g.at_ms))
			or not table.find({ "owner_question", "coordinator_proposal", "native_input", "landing_approval", "quota_fallback" }, g.kind)
			or not table.find({ "pending", "answered", "delivery_pending", "delivered", "acknowledged", "cancelled", "superseded", "resolved" }, g.phase)
			or not dense(g.options, 16, 1) or not dense(g.evidence, 256) then return false end
		local w = d.workers[g.worker_id]
		if not w or g.worker_generation ~= w.worker_generation or g.work_id ~= w.work_id or g.logical_session_id ~= w.logical_session_id or not equal(g.pane_binding, w.pane_binding) then return false end
		local seen = {}
		for _, option in g.options do if not closed(option, "id label") or not id(option.id) or not wire_text(option.label, 1024) or seen[option.id] then return false end; seen[option.id] = true end
		for _, evidence in g.evidence do if not wire_text(evidence, 1024) then return false end end
		if g.answer and (not closed(g.answer, "choice_id answer source at_ms") or not seen[g.answer.choice_id] or not str(g.answer.answer, 32768)
			or not M.origin(g.answer.source) or g.answer.source.logical_session_id ~= w.logical_session_id
			or g.answer.source.owner_id ~= w.origin_binding.owner_id or g.answer.source.owner_generation ~= w.origin_binding.owner_generation
			or not (g.answer.at_ms == 0 or pos(g.answer.at_ms))) then return false end
		if g.delivery then
			local r = g.delivery
			if not closed(r, "message_id reply_seq action_id action_revision acknowledged published bytes ack_seq ack_sha256") or type(r.acknowledged) ~= "boolean" or type(r.published) ~= "boolean" then return false end
			local reply = codec.decode_reply(r.bytes, w)
			if not reply or reply.kind ~= "owner_decision" or reply.gate_id ~= key or reply.gate_revision > g.revision or not g.answer
				or reply.message_id ~= r.message_id or reply.reply_seq ~= r.reply_seq or reply.action_id ~= r.action_id or reply.action_revision ~= r.action_revision
				or reply.payload.choice_id ~= g.answer.choice_id or reply.payload.answer ~= g.answer.answer then return false end
			if not valid_delivery(r, w) then return false end
		end
		if g.phase == "pending" and (g.answer or g.delivery) then return false end
		-- Quota fallback decisions are consumed by the host reducer, never delivered to a worker.
		if g.kind == "quota_fallback" and (g.delivery or g.proposal or g.result or g.phase == "answered" or (g.phase == "resolved") ~= (g.answer ~= nil)) then return false end
		if g.phase == "resolved" and g.kind ~= "quota_fallback" then return false end
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
		if g.result ~= nil then
			local report = codec.decode_report(g.result, w)
			local proposal = if g.proposal then codec.decode_report(g.proposal, w) else nil
			if not report or not proposal or not g.delivery or not g.delivery.acknowledged or report.seq > w.accepted_seq
				or report.action_id ~= g.delivery.action_id or report.action_revision ~= g.delivery.action_revision
				or report.kind ~= "REVIEW_RESULT" or proposal.payload.kind ~= "review" then return false end
		end
	end
	return true
end
local function pane_shape(v: any): boolean
	return closed(v, "pane_id window_epoch window_key native_session_id window_host_id") and str(v.pane_id, 96) and v.pane_id:match("^%d+$") ~= nil
		and id(v.window_epoch) and str(v.window_key, 256, true) and str(v.native_session_id, 256) and str(v.window_host_id, 256)
end
local ROLLOVER_KEYS = "id kind phase trigger logical_session_id work_id predecessor_worker_id predecessor_pane_binding origin controller_pane controller_generation handover_token request_id checkpoint verification successor_worker_id successor_pane_binding stop_observation hold history context predecessor_owner_id predecessor_generation successor_owner_id successor_generation closure quota"
local function valid_rollovers(d: any, registry: any): boolean
	if d.rollovers == nil then return true end
	if count(d.rollovers) > 32 then return false end
	local active, coordinators = {}, {}
	for key, r in d.rollovers do
		local coordinator_kind = type(r) == "table" and r.kind == "coordinator"
		local phases = if coordinator_kind then COORDINATOR_ROLLOVER_PHASES else ROLLOVER_PHASES
		local index = if type(r) == "table" then table.find(phases, r.phase) else nil
		if not closed(r, ROLLOVER_KEYS) or not id(key) or r.id ~= key or (r.kind ~= "worker" and r.kind ~= "coordinator") or (index == nil and r.phase ~= "cancelled")
			or (r.trigger ~= "owner" and r.trigger ~= "policy") or not registry.sessions[r.logical_session_id] or not id(r.work_id)
			or not id(r.predecessor_worker_id) or not pane_shape(r.predecessor_pane_binding) or not M.origin(r.origin)
			or r.origin.logical_session_id ~= r.logical_session_id or r.controller_generation ~= r.origin.owner_generation
			or not str(r.controller_pane, 96) or r.controller_pane:match("^%d+$") == nil or not digest(r.handover_token)
			or not dense(r.history, 32, 1) then return false end
		for _, edge in r.history do
			if not closed(edge, "phase revision at_ms") or not (table.find(phases, edge.phase) or edge.phase == "cancelled")
				or not pos(edge.revision) or edge.revision > registry.revision or not (edge.at_ms == 0 or pos(edge.at_ms)) then return false end
		end
		if r.history[#r.history].phase ~= r.phase then return false end
		if r.hold ~= nil and (not closed(r.hold, "code message") or not str(r.hold.code, 96) or not wire_text(r.hold.message, 1024)) then return false end
		if r.request_id ~= nil and not id(r.request_id) then return false end
		if r.successor_worker_id ~= nil and not id(r.successor_worker_id) then return false end
		if r.successor_pane_binding ~= nil and not pane_shape(r.successor_pane_binding) then return false end
		if r.stop_observation ~= nil and r.stop_observation ~= "absent" and r.stop_observation ~= "exited" then return false end
		if r.checkpoint ~= nil and not wire_text(r.checkpoint, 65536) then return false end
		if r.verification ~= nil and (not closed(r.verification, "attestation checkpoint_id artifact_revision")
			or r.verification.attestation ~= "worker-attested" or not id(r.verification.checkpoint_id) or not wire_text(r.verification.artifact_revision, 1024)) then return false end
		if r.context ~= nil and (not closed(r.context, "used_pct seq") or type(r.context.used_pct) ~= "number" or r.context.used_pct < 0
			or r.context.used_pct > 100 or r.context.used_pct % 1 ~= 0 or not pos(r.context.seq)) then return false end
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
				local retired = registry.retired[r.predecessor_owner_id]
				if not retired or retired.orch_session_id ~= r.logical_session_id or retired.target ~= "orchestrator" or retired.generation ~= r.predecessor_generation then return false end
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
-- Queue key: explicit session + project + repository + target ref (length-framed), never cwd.
local function landing_queue_id(session_id: string, p: any): string
	local parts = {}
	for _, value in { session_id, p.project_id, p.repo_ref, p.target_ref } do table.insert(parts, string.format("%d:%s", #value, value)) end
	return "landing-queue-" .. codec.sha256(table.concat(parts)):sub(1, 40)
end
local LANDING_ITEM_KEYS = "id revision queue_id logical_session_id work_id worker_id status at_ms request gate_id approval verification hold refresh_required refresh grants history"
local LANDING_GRANT_KEYS = "grant_id worker_id action_id action_revision reply_seq message_id bytes target_revision source_revision checkpoint_id controller_generation revision published acknowledged ack_seq ack_sha256 result late_result uncertain reconciliation"
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
local function valid_landing_grant(g: any, d: any, registry: any): boolean
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
	if r ~= nil and (not closed(r, "outcome target_revision reason source at_ms revision") or (r.outcome ~= "landed" and r.outcome ~= "not_landed")
		or (r.outcome == "landed" and r.target_revision == nil) or (r.target_revision ~= nil and not landing_text(r.target_revision))
		or not wire_text(r.reason, 1024) or not M.origin(r.source) or not (r.at_ms == 0 or pos(r.at_ms)) or not pos(r.revision)
		or r.revision > registry.revision or g.uncertain == nil) then return false end
	local w = d.workers[g.worker_id]
	if w then
		local reply = codec.decode_reply(g.bytes, w)
		if not reply or reply.kind ~= "landing_grant" or reply.action_id ~= g.action_id or reply.action_revision ~= g.action_revision
			or reply.reply_seq ~= g.reply_seq or reply.message_id ~= g.message_id or reply.payload.grant_id ~= g.grant_id
			or reply.payload.target_revision ~= g.target_revision or reply.payload.source_revision ~= g.source_revision
			or reply.payload.checkpoint_id ~= g.checkpoint_id or not valid_delivery(g, w) then return false end
		for _, result in { g.result, g.late_result } do if result.seq > w.accepted_seq then return false end end
	end
	return true
end
-- The last landing_refresh issued for an item: its exact immutable reply and delivery evidence.
local function valid_landing_refresh(v: any, item: any, q: any, d: any, registry: any): boolean
	if not closed(v, "worker_id expected_revision current_revision action_id action_revision reply_seq message_id bytes published acknowledged ack_seq ack_sha256 revision")
		or not id(v.worker_id) or not landing_text(v.expected_revision) or not landing_text(v.current_revision) or v.expected_revision == v.current_revision
		or not id(v.action_id) or not pos(v.action_revision) or not pos(v.reply_seq) or not id(v.message_id) or type(v.bytes) ~= "string"
		or type(v.published) ~= "boolean" or type(v.acknowledged) ~= "boolean" or not pos(v.revision) or v.revision > registry.revision then return false end
	local w = d.workers[v.worker_id]
	if w then
		local reply = codec.decode_reply(v.bytes, w)
		if not reply or reply.kind ~= "landing_refresh" or reply.action_id ~= v.action_id or reply.action_revision ~= v.action_revision
			or reply.reply_seq ~= v.reply_seq or reply.message_id ~= v.message_id or reply.payload.landing_id ~= item.id
			or reply.payload.project_id ~= q.project_id or reply.payload.repo_ref ~= q.repo_ref or reply.payload.target_ref ~= q.target_ref
			or reply.payload.expected_revision ~= v.expected_revision or reply.payload.current_revision ~= v.current_revision
			or not valid_delivery(v, w) then return false end
	end
	return true
end
local function valid_landing(d: any, registry: any): boolean
	local L = d.landing
	if L == nil then return true end
	if not closed(L, "queues items") or type(L.queues) ~= "table" or L.queues == tern.json.null or type(L.items) ~= "table"
		or L.items == tern.json.null or count(L.queues) > 32 or count(L.items) > 64 then return false end
	local placed = {}
	for key, q in L.queues do
		if not closed(q, "id logical_session_id project_id repo_ref target_ref order slot head") or not id(key) or q.id ~= key
			or not registry.sessions[q.logical_session_id] or not id(q.project_id) or not landing_text(q.repo_ref) or not landing_text(q.target_ref)
			or landing_queue_id(q.logical_session_id, q) ~= key or not dense(q.order, 64) or (q.slot ~= nil and q.order[1] ~= q.slot) then return false end
		if q.head ~= nil and (not closed(q.head, "revision source landing_id") or not landing_text(q.head.revision)
			or not table.find({ "landed", "stale_target", "owner" }, q.head.source) or not id(q.head.landing_id)) then return false end
		for index, landing_id in q.order do
			local item = if id(landing_id) then L.items[landing_id] else nil
			if type(item) ~= "table" or item.queue_id ~= key or placed[landing_id] or LANDING_TERMINAL[item.status]
				or (not LANDING_UNGRANTED[item.status] and (index ~= 1 or q.slot ~= landing_id)) then return false end
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
		for _, edge in item.history do
			if not closed(edge, "status revision at_ms") or not table.find(LANDING_STATUSES, edge.status) or not pos(edge.revision)
				or edge.revision > registry.revision or not (edge.at_ms == 0 or pos(edge.at_ms)) then return false end
		end
		if item.history[#item.history].status ~= item.status or (item.gate_id ~= nil and not id(item.gate_id)) then return false end
		if item.approval ~= nil and (not closed(item.approval, "gate_id gate_revision at_ms") or item.approval.gate_id ~= item.gate_id
			or not pos(item.approval.gate_revision) or not (item.approval.at_ms == 0 or pos(item.approval.at_ms))) then return false end
		if item.verification ~= nil and (not closed(item.verification, "attestation checkpoint_id artifact_revision") or item.verification.attestation ~= "worker-attested"
			or not id(item.verification.checkpoint_id) or item.verification.artifact_revision ~= r.source_revision) then return false end
		if item.hold ~= nil and (not closed(item.hold, "code message") or not str(item.hold.code, 96) or not wire_text(item.hold.message, 1024)) then return false end
		if item.refresh_required ~= nil and item.refresh_required ~= true then return false end
		if item.refresh ~= nil and not valid_landing_refresh(item.refresh, item, q, d, registry) then return false end
		for index, g in item.grants do
			if not valid_landing_grant(g, d, registry) or (index < #item.grants and not landing_released(g)) then return false end
		end
		local current = item.grants[#item.grants]
		if LANDING_UNGRANTED[item.status] or item.status == "cancelled" then
			if (current and not landing_released(current)) or q.slot == key then return false end
		elseif item.status == "granted" or item.status == "landing" then
			if not current or current.reconciliation ~= nil or (current.result ~= nil and current.result.outcome ~= "uncertain")
				or q.slot ~= key or (item.status == "landing") ~= current.acknowledged then return false end
		elseif item.status == "landed" then
			if not current or not ((current.result and current.result.outcome == "landed" and not current.uncertain)
				or (current.reconciliation and current.reconciliation.outcome == "landed")) then return false end
		elseif not current or not current.result or current.result.outcome ~= "rejected" or current.uncertain then return false end
		local w = d.workers[item.worker_id]
		if not LANDING_TERMINAL[item.status] and not w then return false end
		if w and (w.logical_session_id ~= item.logical_session_id or w.work_id ~= item.work_id or r.seq > w.accepted_seq) then return false end
	end
	return true
end
-- Session-local concurrency ledger entry (plan §7 line 319): reserved -> claimed -> launching ->
-- active -> released, with uncertain retaining occupancy. Bound to the routing decision/evidence.
local RESERVATION_PHASES = { "reserved", "claimed", "launching", "active", "uncertain", "released" }
local RESERVATION_HELD = { reserved = true, claimed = true, launching = true, active = true, uncertain = true }
local function valid_reservation(v: any): boolean
	if v == nil then return true end
	if not closed(v, "id phase decision_digest evidence_revision history") or not id(v.id) or not table.find(RESERVATION_PHASES, v.phase)
		or not digest(v.decision_digest) or (v.evidence_revision ~= nil and not digest(v.evidence_revision)) or not dense(v.history, 8, 1) then return false end
	for _, edge in v.history do
		if not closed(edge, "phase revision at_ms") or not table.find(RESERVATION_PHASES, edge.phase) or not pos(edge.revision)
			or not (edge.at_ms == 0 or pos(edge.at_ms)) then return false end
	end
	return v.history[#v.history].phase == v.phase
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
	if r.gate ~= nil then
		local g = r.gate
		local gate = (d.gates or {})[if type(g) == "table" then g.gate_id else nil]
		if not closed(g, "gate_id policy_digest evidence_revision catalog_revision from to denied") or not id(g.gate_id) or not digest(g.policy_digest)
			or not digest(g.evidence_revision) or not (g.catalog_revision == 0 or pos(g.catalog_revision)) or not record_tuple(g.from) or not record_tuple(g.to)
			or not needs_text(g.denied) or r.bound or not gate or gate.kind ~= "quota_fallback" or gate.worker_id ~= w.worker_id or not gate_open(gate) then return false end
	end
	return true
end
-- Rollover-time quota routing state (plan §7 lines 305, 321): an open predecessor-bound fallback
-- gate, or the owner's one-action approval/rejection, kept only until the successor is granted.
local function valid_rollover_quota(d: any, r: any): boolean
	local q = r.quota
	if q == nil then return true end
	local waiting = if r.kind == "coordinator" then "owner_retired" else "checkpoint_verified"
	if not closed(q, "gate approval rejected") or (r.phase ~= waiting and r.phase ~= "cancelled") then return false end
	if q.gate ~= nil then
		local g = q.gate
		local gate = (d.gates or {})[if type(g) == "table" then g.gate_id else nil]
		if not closed(g, "gate_id policy_digest evidence_revision catalog_revision from to denied scope") or not id(g.gate_id) or not digest(g.policy_digest)
			or not digest(g.evidence_revision) or not (g.catalog_revision == 0 or pos(g.catalog_revision)) or not record_tuple(g.from) or not record_tuple(g.to)
			or not needs_text(g.denied) or not table.find(quota.SCOPES, g.scope) or not gate or gate.kind ~= "quota_fallback"
			or gate.worker_id ~= r.predecessor_worker_id or not gate_open(gate) then return false end
	end
	for _, key in { "approval", "rejected" } do
		local v = q[key]
		if v ~= nil and (not closed(v, "policy_digest to needs gate_id") or not digest(v.policy_digest) or not record_tuple(v.to)
			or not id(v.gate_id) or (v.needs ~= nil and not needs_text(v.needs))) then return false end
	end
	return true
end
-- Shape and correlation checks protect restored dispatch state; codecs revalidate exact receipts.
function M.valid(d: any, registry: any, legacy_catalog_cache: boolean?): boolean
	if d == nil then return true end
	if not closed(d, "serial actions workers commands catalogs policies gates command_cursors rollovers landing capacity sweeps") or type(d.serial) ~= "number" or d.serial < 0 or d.serial % 1 ~= 0 or d.serial > MAX then return false end
	if not valid_sweeps(d, registry) then return false end
	if d.capacity ~= nil then
		if type(d.capacity) ~= "table" or d.capacity == tern.json.null or count(d.capacity) > 64 then return false end
		for sid, e in d.capacity do if not registry.sessions[sid] or not quota.valid_evidence(e) then return false end end
	end
	for _, key in { "actions", "workers", "commands", "catalogs" } do if type(d[key]) ~= "table" then return false end end
	for _, key in { "policies", "gates", "rollovers", "landing" } do if d[key] ~= nil and (type(d[key]) ~= "table" or d[key] == tern.json.null) then return false end end
	if count(d.actions) > 4096 or count(d.workers) > 32 or count(d.commands) > 4096 then return false end
	if d.command_cursors ~= nil then
		if type(d.command_cursors) ~= "table" or d.command_cursors == tern.json.null or count(d.command_cursors) > 64 then return false end
		for sid, cursor in d.command_cursors do
			if not registry.sessions[sid] or not closed(cursor, "origin controller_pane seq continued_epoch") or not M.origin(cursor.origin)
				or cursor.origin.logical_session_id ~= sid or not pos(cursor.seq) or not str(cursor.controller_pane, 96) or not cursor.controller_pane:match("^%d+$")
				or (cursor.continued_epoch ~= nil and (not pos(cursor.continued_epoch) or cursor.continued_epoch > registry.execution_epoch)) then return false end
		end
	end
	for key, a in d.actions do
		if not closed(a, "request request_bytes phase worker_id claim response_bytes response response_grant resolution retry_count") or not id(key) or type(a.request) ~= "table" or a.request.action_id ~= key
			or not M.origin(a.request.origin_binding) or registry.sessions[a.request.origin_binding.logical_session_id] == nil or type(a.request_bytes) ~= "string" or #a.request_bytes > 8192 then return false end
		local decoded = codec.strict_decode(a.request_bytes, 8192); if not equal(decoded, a.request) then return false end
		if not table.find({ "ready", "claimed", "complete", "uncertain", "resolved", "backpressure" }, a.phase) then return false end
		if a.claim ~= nil and (not closed(a.claim, "executor epoch grant_id capacity") or not id(a.claim.executor) or not id(a.claim.grant_id) or not pos(a.claim.epoch) or a.claim.epoch > registry.execution_epoch) then return false end
		-- A routed launch claim binds the exact USAGE revision that USAGE confirmed current immediately before it.
		if a.claim ~= nil and a.claim.capacity ~= nil and (a.request.op ~= "launch" or not closed(a.claim.capacity, "revision validated_at_ms expires_at_ms")
			or not digest(a.claim.capacity.revision) or not (a.claim.capacity.validated_at_ms == 0 or pos(a.claim.capacity.validated_at_ms))
			or not pos(a.claim.capacity.expires_at_ms)) then return false end
		if a.retry_count ~= nil and not pos(a.retry_count) then return false end
		if a.response_grant ~= nil and not id(a.response_grant) then return false end
		if (a.phase == "claimed" or a.phase == "uncertain") and not (type(a.claim) == "table" and id(a.claim.executor) and pos(a.claim.epoch)) then return false end
		if a.worker_id ~= nil and d.workers[a.worker_id] == nil then return false end
		if not valid_request(a.request, if a.worker_id then d.workers[a.worker_id] else nil, d) then return false end
		if a.response_bytes ~= nil then local body = M.decode_response(a.response_bytes, a.request); if body == nil or not equal(body, a.response) then return false end end
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
	for key, w in d.workers do
		if not closed(w, "worker_id work_id worker_generation logical_session_id origin_binding controller_pane record_id record_revision prompt cwd placement assignment_sha256 launch_request_id launch_action_id enrolment_token phase accepted_seq compacted_floor receipts replies reply_seq reply_floor coordinator_owner_id coordinator_generation coordinator_protocol activation retirement release stop_action_id stopped mailbox_retired mailbox_retire_action_id mailbox_handle capabilities binding_digest receipt_chain compacted_chain pane_binding effective_identity accepted_event accept_pending registered frozen reason assembly read_selector compaction_pending workflow rejected_report finish control_origin control_pane control_pane_binding attachment_action_id continuation_required wakes handover_id handover_token restored routing adopt_pane_binding")
			or not id(key) or w.worker_id ~= key or not M.origin(w.origin_binding) or w.logical_session_id ~= w.origin_binding.logical_session_id
			or not id(w.launch_request_id) or not id(w.launch_action_id) or not id(w.work_id) or w.worker_generation ~= 1
			or not str(w.enrolment_token, 128) or #w.enrolment_token < 16 or w.enrolment_token:match("^[A-Za-z0-9_-]+$") == nil
			or not str(w.prompt, 32768) or not digest(w.assignment_sha256) or codec.sha256(w.prompt) ~= w.assignment_sha256
			or type(w.receipts) ~= "table" or count(w.receipts) > 16 or type(w.replies) ~= "table" or count(w.replies) > 8
			or not (w.accepted_seq == 0 or pos(w.accepted_seq)) or not (w.compacted_floor == 0 or pos(w.compacted_floor)) or w.compacted_floor > w.accepted_seq
			or not (w.reply_seq == 0 or pos(w.reply_seq)) or not (w.reply_floor == 0 or pos(w.reply_floor)) or w.reply_floor > w.reply_seq then return false end
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
			if not closed(reply, "bytes sha256 frames part message_id reply_seq action_id action_revision acknowledged")
				or type(reply.frames) ~= "table" or not pos(reply.part) or type(reply.acknowledged) ~= "boolean" then return false end
			local decoded = codec.decode_reply(reply.bytes, w)
			if not decoded or tostring(decoded.reply_seq) ~= seq or decoded.reply_seq <= w.reply_floor or decoded.reply_seq > w.reply_seq
				or codec.sha256(reply.bytes) ~= reply.sha256 or decoded.message_id ~= reply.message_id
				or decoded.action_id ~= reply.action_id or decoded.action_revision ~= reply.action_revision then return false end
			local frames = codec.frame(reply.bytes, "reply", w)
			if not frames or not equal(frames, reply.frames) or reply.part > #frames.chunks + 2 then return false end
		end
		if w.coordinator_protocol ~= nil and (w.coordinator_protocol ~= 1 or not id(w.coordinator_owner_id) or not pos(w.coordinator_generation)) then return false end
		-- An adopted hand-opened agent is an ordinary first generation bound to its exact attested pane.
		if w.adopt_pane_binding ~= nil and (not pane_binding(w.adopt_pane_binding, w.origin_binding) or w.coordinator_owner_id ~= nil
			or w.handover_id ~= nil or w.routing ~= nil or (w.pane_binding ~= nil and not equal(w.pane_binding, w.adopt_pane_binding))) then return false end
		-- Rollover successors carry the paired immutable handover enrolment; initial launches never do.
		if (w.handover_id == nil) ~= (w.handover_token == nil) or (w.handover_id ~= nil
			and (not id(w.handover_id) or not digest(w.handover_token) or (w.coordinator_owner_id ~= nil and w.coordinator_protocol ~= 1))) then return false end
		-- A stopped coordinator pane observed alive again is retained native-restoration evidence.
		if w.restored ~= nil and (not closed(w.restored, "at_ms state reconciled") or not w.coordinator_owner_id or not w.stopped
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
		if w.finish ~= nil and (w.coordinator_owner_id ~= nil or not closed(w.finish, "request_id seq revision source")
			or not id(w.finish.request_id) or not pos(w.finish.seq) or w.finish.seq > w.accepted_seq
			or not pos(w.finish.revision) or w.finish.revision > registry.revision or not M.origin(w.finish.source)
			or w.finish.source.logical_session_id ~= w.logical_session_id or w.finish.source.owner_id ~= w.origin_binding.owner_id
			or w.finish.source.owner_generation ~= w.origin_binding.owner_generation or w.finish.source.host_pane_id ~= w.origin_binding.host_pane_id
			or w.finish.source.alias_nonce ~= w.origin_binding.alias_nonce) then return false end
		if w.stop_action_id ~= nil then
			local action = d.actions[w.stop_action_id]
			if not (w.release or w.finish) or not action or action.worker_id ~= key or action.request.op ~= "stop" then return false end
		end
		if w.stopped ~= nil then
			local action = d.actions[w.stop_action_id]
			if not action or not action.response or action.response.status ~= "stopped" or not equal(w.stopped, action.response.payload) then return false end
		end
		if w.mailbox_retire_action_id ~= nil then
			local action = d.actions[w.mailbox_retire_action_id]
			if not (w.stopped or launch_rejected(d, w)) or not action or action.worker_id ~= key or action.request.op ~= "mailbox_retire" or action.request.mode ~= "retire" then return false end
		end
		if w.mailbox_retired ~= nil and (w.mailbox_retired ~= true or not w.mailbox_retire_action_id
			or d.actions[w.mailbox_retire_action_id].phase ~= "complete" or not d.actions[w.mailbox_retire_action_id].response
			or d.actions[w.mailbox_retire_action_id].response.status ~= "retired") then return false end
		if w.rejected_report ~= nil then
			local rejected = w.rejected_report
			if not closed(rejected, "code message bytes sha256 action_id") or not str(rejected.code, 96) or not str(rejected.message, 1024)
				or not str(rejected.bytes, 65536) or rejected.sha256 ~= codec.sha256(rejected.bytes) or not id(rejected.action_id)
				or w.assembly ~= nil or w.read_selector ~= nil then return false end
		end
		if not valid_flow(d, w) or not valid_routing(d, w) then return false end
		if w.continuation_required ~= nil and type(w.continuation_required) ~= "boolean" then return false end
		if w.control_origin ~= nil then
			local attachment = d.actions[w.attachment_action_id]
			if not M.origin(w.control_origin) or not pane_binding(w.control_pane_binding, w.control_origin)
				or not str(w.control_pane, 96) or not attachment or attachment.phase ~= "complete"
				or attachment.request.op ~= "attach_worker" or not equal(attachment.request.origin_binding, w.control_origin)
				or attachment.request.controller_pane ~= w.control_pane or not equal(attachment.request.pane_binding, w.control_pane_binding)
				or not attachment.response or attachment.response.status ~= "attached" then return false end
		elseif w.control_pane ~= nil or w.control_pane_binding ~= nil or w.attachment_action_id ~= nil then return false end
		if w.wakes ~= nil then
			if type(w.wakes) ~= "table" or w.wakes == tern.json.null or count(w.wakes) > 32 then return false end
			for key, wake in w.wakes do
				local publication = d.actions[key]
				if not closed(wake, "target_request_id target_action_id action_id") or wake.target_action_id ~= key or not id(wake.target_request_id)
					or not publication or publication.worker_id ~= w.worker_id or publication.request.request_id ~= wake.target_request_id
					or not (publication.request.op == "mailbox_publish_ack" or (publication.request.op == "mailbox_publish_reply" and publication.request.part == "manifest"))
					or publication.phase ~= "complete" or not publication.response or type(publication.response.payload) ~= "table"
					or publication.response.payload.wake_status ~= "awaiting_window" or publication.response.payload.wake_effect_started ~= false
					or publication.response.payload.wake_target_action_id ~= key or publication.response.payload.wake_target_request_id ~= wake.target_request_id then return false end
				if wake.action_id ~= nil then
					local action = d.actions[wake.action_id]
					if not action or action.worker_id ~= w.worker_id or action.request.op ~= "native_wake"
						or action.request.target_action_id ~= key or action.request.target_request_id ~= wake.target_request_id then return false end
				end
			end
		end
	end
	for key, command in d.commands do
		if not id(key) or not closed(command, "event result revision") or type(command.event) ~= "table" or command.event.request_id ~= key
			or (command.revision ~= nil and (not pos(command.revision) or command.revision > registry.revision))
			or (command.event.command_seq ~= nil and not pos(command.event.command_seq))
			or (command.event.kind ~= "dispatch" and command.event.kind ~= "dispatch_reconcile") or type(command.result) ~= "table" or command.result.ok ~= true or not str(command.result.code, 96) then return false end
		if command.event.command_seq ~= nil then
			local event = command.event
			local cursor = (d.command_cursors or {})[event.orch_session_id]
			if event.kind ~= "dispatch" or table.find({ "claim", "result", "lost" }, event.command) or not M.origin(event.origin)
				or event.origin.logical_session_id ~= event.orch_session_id or not cursor or event.command_seq > cursor.seq then return false end
		end
	end
	for _, c in d.catalogs do if not catalog(c, legacy_catalog_cache) then return false end end
	-- The same explicit restore-boundary flag admits exactly-CP2 policies; M.restore migrates them.
	if not valid_rollovers(d, registry) or not valid_landing(d, registry) then return false end
	for _, r in d.rollovers or {} do if not valid_rollover_quota(d, r) then return false end end
	return valid_workflow(d, registry, legacy_catalog_cache)
end
function M.restore(d: any)
	if d == nil then return end
	-- Retained sequenced observations and polls (pre-retention-rule stores) are behind the
	-- validated command cursor; drop them with the restore write (see unretained).
	for key, command in d.commands do if unretained(command.event) then d.commands[key] = nil end end
	-- Legacy full claim/result outcomes are compacted or dropped once, with the same write
	-- (see prune_effects); a live remember keeps them bounded from then on.
	prune_effects(d)
	-- Pre-join catalogs are validated at restore, then invalidated once. They
	-- cannot authorize new work; exact retained actions and workers survive.
	for sid, c in d.catalogs do if c.namespace == nil then d.catalogs[sid] = nil end end
	-- USAGE evidence leases are at most minutes long; a restart always needs a fresh snapshot.
	d.capacity = nil
	for _, a in d.actions do if a.phase == "claimed" then a.phase = "uncertain" end end
	for sid, p in d.policies or {} do d.policies[sid] = migrate_policy(p) end
	for _, w in d.workers do w.continuation_required = true; refresh(d, w, nil) end
end
local function candidate(registry: any): any
	local n = table.clone(registry); n.dispatch = clone(registry.dispatch or fresh()); n.sessions = clone(registry.sessions); n.revision += 1; return n
end
local function finish_command(n: any, event: any, answer: any): (any, any)
	remember(n.dispatch, event, answer, n.revision)
	return n, answer
end
-------------------------------------------------------------------------------
-- Quota routing of initial dispatch (plan §7; pure rule in quota.luau).
-------------------------------------------------------------------------------
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
-- Concurrency ledger (plan §7 lines 317-319). Only routed work holds reservations; the limit applies
-- while quota routing is on and Config sets concurrency_limit. It serializes this session's launches
-- and is never a provider-side quota reservation.
local function concurrency_problem(d: any, sid: string, p: any, except: any): any?
	if not p.quota_routing or p.concurrency_limit == 0 then return nil end
	local used = 0
	for key, w in d.workers do
		local held = if w.routing then w.routing.reservation else nil
		if w.logical_session_id == sid and not except[key] and held and RESERVATION_HELD[held.phase] then used += 1 end
	end
	if used < p.concurrency_limit then return nil end
	return { code = "concurrency_limit", message = "This session's routed launch reservations are at Config's concurrency limit (" .. tostring(used) .. "/"
		.. tostring(p.concurrency_limit) .. "). The work stays held until a reserved worker stops, retires or definitively fails to launch. This serializes this session only, not other sessions' quota use." }
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
	if w.stopped or w.mailbox_retired then return "released" end
	if launch and launch.phase == "uncertain" then return "uncertain" end
	if w.pane_binding then return if w.phase == "accepted" then "active" else "launching" end
	if w.phase == "held" then return "released" end
	if launch and launch.phase == "claimed" then return "claimed" end
	if launch and (launch.phase == "complete" or launch.phase == "resolved") then return "released" end
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
local function close_fallback_gate(d: any, w: any)
	local r = w.routing
	local g = if r.gate then (d.gates or {})[r.gate.gate_id] else nil
	if g and gate_open(g) then g.phase = "superseded"; g.revision += 1; settle_entries(w, "gate_id", g.id) end
	r.gate = nil
end
local function tuple_text(t: any): string
	return t.id .. " rev " .. tostring(t.revision) .. " (provider " .. tostring(t.provider or "unset") .. ", account " .. tostring(t.account or "unset")
		.. (if t.profile then ", profile " .. t.profile else "") .. ", model " .. tostring(t.model or "unset") .. ")"
end
-- A denied fallback becomes a durable one-action owner gate bound to the work, routing policy
-- revision, USAGE evidence revision, catalog revision and exact source/destination tuples.
local function open_fallback_gate(d: any, w: any, decision: any, p: any, clock: any): any?
	local r = w.routing
	local e = current_evidence(d, w.logical_session_id)
	local binding = { policy_digest = quota.policy_digest(p), evidence_revision = e.revision, catalog_revision = d.catalogs[w.logical_session_id].revision,
		from = clone(decision.from), to = clone(decision.to), denied = decision.denied }
	local existing = if r.gate then (d.gates or {})[r.gate.gate_id] else nil
	if existing and gate_open(existing) and r.gate.policy_digest == binding.policy_digest and r.gate.catalog_revision == binding.catalog_revision
		and r.gate.denied == binding.denied and equal(r.gate.from, binding.from) and equal(r.gate.to, binding.to) then
		r.gate.evidence_revision = binding.evidence_revision -- Same proposal; newer evidence keeps the question stable.
		return nil
	end
	close_fallback_gate(d, w)
	local to = decision.to
	local question = "Quota fallback for " .. w.work_id .. " (initial dispatch): " .. decision.reason.message .. " Approve " .. tuple_text(to)
		.. " instead of " .. tuple_text(decision.from) .. " for this work only? Approval is bound to routing policy " .. binding.policy_digest:sub(1, 12)
		.. " and USAGE evidence " .. binding.evidence_revision:sub(1, 12) .. "; it never edits Config or authorizes later work. Reject keeps the work held."
	local evidence = { "operation:" .. (r.scope or "initial_dispatch"), "work:" .. w.work_id, "denied:" .. binding.denied, "policy:" .. binding.policy_digest,
		"usage_revision:" .. binding.evidence_revision, ("from:" .. tuple_text(decision.from)):sub(1, 1024), ("to:" .. tuple_text(to)):sub(1, 1024),
		"selector:" .. quota.selector_state(decision.record) .. " (SPAWN exposes no typed selector status; not enforced)" }
	for _, c in decision.candidates do
		table.insert(evidence, ("candidate:" .. c.id .. " " .. c.status .. (if c.reason then " " .. c.reason else "")
			.. (if c.remaining_pct then " remaining " .. tostring(c.remaining_pct) .. "%" else "")
			.. (if c.weekly_reset_ms then " weekly_reset_ms " .. string.format("%.0f", c.weekly_reset_ms) else "")):sub(1, 1024))
	end
	local g, err = new_gate(d, w, "quota_fallback", question, { { id = "approve", label = "Approve " .. to.id .. " for this work only" },
		{ id = "reject", label = "Reject — keep the work held" } }, evidence, clock)
	if err then return err end
	binding.gate_id = g.id; r.gate = binding
	return nil
end
-- Coordinator/oversize checks and the provisioning action; the coordinator slot is reserved last,
-- after every check that could fail, so a refused reroute leaves no partial reservation.
local function prepare_launch(registry: any, n: any, w: any, coordinator: boolean, request_id: string, clock: any, reserve: any): (string?, any?)
	local d = n.dispatch
	if coordinator and (coordinator_rollover(d, w.logical_session_id) or restored_coordinator(d, w.logical_session_id)) then
		return fail("rollover_reserved", "A coordinator rollover owns this session's orchestrator slot, or a restored coordinator is unreconciled; an unrelated start cannot take the reservation.")
	end
	if #tern.json.encode(launch_request(w, string.rep("h", 96))) > 8192 then
		return fail("oversize", "Assignment plus immutable launch binding cannot fit the 8192-byte bridge (including a maximum-length mailbox handle); no provisioning was queued.")
	end
	if coordinator then
		w.coordinator_protocol = 1; w.coordinator_owner_id = string.rep("o", 96); w.coordinator_generation = MAX
		local fits = #tern.json.encode(launch_request(w, string.rep("h", 96))) <= 8192
		w.coordinator_protocol = nil; w.coordinator_owner_id = nil; w.coordinator_generation = nil
		if not fits then return fail("oversize", "Assignment and reserved coordinator identity exceed the immutable launch bridge bound; no reservation or provision was committed.") end
	end
	local request = common(d, w.origin_binding, w.controller_pane, "mailbox_provision"); be(w, request)
	request.record_id = w.record_id; request.record_revision = w.record_revision; request.capability = "report-files-v1"
	if #tern.json.encode(request) > 8192 then return fail("oversize", "Provision request exceeds the bridge bound.") end
	if coordinator then
		local base = table.clone(n); base.revision = registry.revision
		local reserved, response = reserve(base, { kind = "reserve_coordinator", request_id = request_id .. "-reserve", orch_session_id = w.logical_session_id, work_id = w.work_id }, clock)
		if reserved == nil then return nil, response end
		n.sessions = clone(reserved.sessions); n.request_outcomes = reserved.request_outcomes; n.next_owner_id = reserved.next_owner_id
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
		cwd = w.cwd, placement = w.placement, now_ms = now, bound = r.bound })
	if r.bound and r.switched and decision.outcome == "selected" then
		local still = if r.authority == "owner_gate" then p.quota_routing and r.authorized_digest == quota.policy_digest(p)
			else routing_permitted(p, r.needs, scope) and table.find(p[scope .. "_records"], w.record_id) ~= nil
		if not still then
			decision = { outcome = "held", candidates = decision.candidates, reason = { code = "policy_changed", message = "Config no longer authorizes the substituted record this work was provisioned for (quota routing off, permission removed, or the owner's fallback decision voided by a routing-policy edit). It stays held; nothing launches on another record." } }
		end
	end
	-- Configured concurrency comes after quota constraints (plan §7 line 317); a live reservation is kept.
	if decision.outcome == "selected" and not (r.reservation and RESERVATION_HELD[r.reservation.phase]) then
		local problem = concurrency_problem(d, w.logical_session_id, p, { [w.worker_id] = true })
		if problem then decision = { outcome = "held", candidates = decision.candidates, reason = problem } end
	end
	if decision.outcome == "selected" and not r.bound then
		local before_id, before_revision = w.record_id, w.record_revision
		w.record_id = decision.record.id; w.record_revision = decision.record.revision
		local action_id, err = prepare_launch(registry, n, w, r.coordinator, request_id, clock, reserve)
		if err then
			w.record_id = before_id; w.record_revision = before_revision
			if strict then return nil, err end
			decision = { outcome = "held", candidates = decision.candidates, reason = { code = err.code, message = err.message } }
		else
			close_fallback_gate(d, w)
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
	close_fallback_gate(d, w)
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
		if (launch and launch.phase ~= "ready") or (w.phase ~= "queued" and w.phase ~= "provisioned") then continue end
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
	return { bytes = bytes, message_id = if kind == "owner_decision" or kind == "report_request" or kind == "landing_grant" or kind == "landing_refresh" then reply.message_id else nil, action_id = reply.action_id, action_revision = reply.action_revision, reply_seq = reply.reply_seq,
		activation_token = payload.activation_token, acknowledged = false }, nil
end
local function settled(w: any): boolean
	local finish = w.release or w.finish
	if not finish or w.compacted_floor ~= w.accepted_seq or w.compacted_floor < finish.seq or w.reply_floor ~= w.reply_seq
		or w.accept_pending or w.assembly or w.rejected_report or next(w.receipts) or next(w.replies) or next(w.wakes or {}) then return false end
	return true
end
-- The existing exact mailbox retirement and compaction grants, shared by poll and the nightly sweep.
local function retire_request(n: any, d: any, w: any): any
	local request = worker_request(d, w, "mailbox_retire")
	request.mode = "retire"; request.settlement_revision = n.revision; request.report_floor = w.compacted_floor
	request.report_chain_sha256 = w.compacted_chain; request.reply_floor = w.reply_floor; request.grant_id = next_id(d, "retire-")
	w.mailbox_retire_action_id = request.action_id
	return request
end
local function compact_request(d: any, w: any): any
	local request = worker_request(d, w, "mailbox_retire")
	request.mode = "compact"; request.settlement_revision = w.compaction_pending; request.report_floor = w.compacted_floor
	request.report_chain_sha256 = w.compacted_chain; request.reply_floor = w.reply_floor; request.grant_id = next_id(d, "compact-")
	return request
end
-- SPAWN's exact pre-effect refusal of a stopped generation's retirement: its producer journal was
-- not settled at the authorized floors, so the helper removed nothing. Only this definite code
-- counts; an uncertain or otherwise failed retirement is never treated as refused.
local function retirement_refused(d: any, w: any): boolean
	local a = if w.mailbox_retire_action_id then d.actions[w.mailbox_retire_action_id] else nil
	return a ~= nil and a.phase == "complete" and a.response ~= nil and a.response.status == "rejected"
		and a.response.error ~= nil and a.response.error.code == "producer_unsettled"
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
	local ids = {}
	for key, w in d.workers do if w.logical_session_id == sid and w.mailbox_handle then table.insert(ids, key) end end
	table.sort(ids)
	local run: any = { local_date = event.local_date, revision = n.revision, at_ms = stamp(clock).at_ms, catch_up = event.catch_up == true,
		decisions = {}, more = 0, retire = 0, compact = 0, keep = 0, none = 0 }
	for _, key in ids do
		local w = d.workers[key]
		local decision, reason = sweep_decision(n, d, w, event.origin)
		local action_id: string? = nil
		if decision == "retire" or decision == "compact" then
			local request = if decision == "retire" then retire_request(n, d, w) else compact_request(d, w)
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
	for _, entry in entries do if entry.state == "settled" then return true end end
	return false
end
local function reason_text(w: any): string
	return if w.reason then tostring(w.reason.code or "unknown") .. ": " .. tostring(w.reason.message or "no detail") else "no SPAWN diagnostic retained"
end
local function rollover_edge(r: any, phase: string, revision: number, clock: any)
	r.phase = phase; r.hold = nil
	table.insert(r.history, { phase = phase, revision = revision, at_ms = stamp(clock).at_ms })
end
local function rollover_hold(r: any, code: string, message: string): boolean
	r.hold = { code = code, message = bounded(message, 1024) }; return false
end
-- Cancellation is only safe before any successor pane can exist or while its launch is unresolved.
local function rollover_cancellable(d: any, r: any): boolean
	local index = table.find(rollover_phases(r), r.phase) or 99
	if index <= 3 then return true end
	-- Coordinator rollover cannot be cancelled once retirement was requested (slot quiescing).
	if r.kind == "coordinator" or r.phase ~= "successor_granted" then return false end
	local succ = d.workers[r.successor_worker_id]
	return succ ~= nil and succ.pane_binding == nil and not pending(d, succ)
end
-- A blocked checkpoint (missing, unverified or too large) may be requested again by the owner.
local function rollover_rerequestable(d: any, r: any): boolean
	local pred = d.workers[r.predecessor_worker_id]
	return r.hold ~= nil and (r.phase == "checkpoint_pending" or (r.phase == "checkpoint_verified" and r.hold.code == "input_too_large"))
		and pred ~= nil and flow(pred).report_request == nil and #r.history <= 29
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
	return true
end
-- Rollover-time fallback gate (plan §7 lines 305, 321): bound to the running predecessor, the
-- rollover, its scope, routing-policy/evidence/catalog revisions and the exact tuples.
local function close_rollover_gate(d: any, r: any, pred: any)
	local q = r.quota
	local g = if q and q.gate then (d.gates or {})[q.gate.gate_id] else nil
	if g and gate_open(g) then g.phase = "superseded"; g.revision += 1; settle_entries(pred, "gate_id", g.id) end
	if q then q.gate = nil end
end
local function open_rollover_gate(d: any, r: any, pred: any, decision: any, p: any, scope: string, clock: any): any?
	local e = current_evidence(d, r.logical_session_id)
	r.quota = r.quota or {}
	local q = r.quota
	local binding = { policy_digest = quota.policy_digest(p), evidence_revision = e.revision, catalog_revision = d.catalogs[r.logical_session_id].revision,
		from = clone(decision.from), to = clone(decision.to), denied = decision.denied, scope = scope }
	local existing = if q.gate then (d.gates or {})[q.gate.gate_id] else nil
	if existing and gate_open(existing) and q.gate.policy_digest == binding.policy_digest and q.gate.catalog_revision == binding.catalog_revision
		and q.gate.denied == binding.denied and equal(q.gate.from, binding.from) and equal(q.gate.to, binding.to) then
		q.gate.evidence_revision = binding.evidence_revision
		return nil
	end
	close_rollover_gate(d, r, pred)
	local question = "Quota fallback for " .. (if scope == "coordinator_rollover" then "coordinator" else "worker") .. " rollover " .. r.id .. " of " .. r.work_id .. ": "
		.. decision.reason.message .. " Start the fresh successor on " .. tuple_text(decision.to) .. " instead of " .. tuple_text(decision.from)
		.. "? This applies to this rollover's successor only, never edits Config and never changes the running predecessor. Reject keeps the rollover held; cancel the rollover to stop it."
	local evidence = { "operation:" .. scope, "rollover:" .. r.id, "work:" .. r.work_id, "denied:" .. binding.denied, "policy:" .. binding.policy_digest,
		"usage_revision:" .. binding.evidence_revision, ("from:" .. tuple_text(decision.from)):sub(1, 1024), ("to:" .. tuple_text(decision.to)):sub(1, 1024),
		"selector:" .. quota.selector_state(decision.record) .. " (SPAWN exposes no typed selector status; not enforced)" }
	for _, c in decision.candidates do
		table.insert(evidence, ("candidate:" .. c.id .. " " .. c.status .. (if c.reason then " " .. c.reason else "")
			.. (if c.remaining_pct then " remaining " .. tostring(c.remaining_pct) .. "%" else "")):sub(1, 1024))
	end
	local g, err = new_gate(d, pred, "quota_fallback", question, { { id = "approve", label = "Approve " .. decision.to.id .. " for this successor only" },
		{ id = "reject", label = "Reject — keep the rollover held" } }, evidence, clock)
	if err then return err end
	binding.gate_id = g.id; q.gate = binding
	return nil
end
local function grant_successor(n: any, r: any, pred: any, event: any, clock: any, reserve: any): boolean
	local d = n.dispatch
	if policy(d, r.logical_session_id).paused then return rollover_hold(r, "session_paused", "Session is paused; no successor launch is granted until resume. The predecessor keeps running.") end
	if type(clock) == "table" and clock.reserved_capacity then
		return rollover_hold(r, "capacity_reached", "Authority capacity is at its settlement reserve; no successor launch is granted. The predecessor keeps running.")
	end
	local c, selected = d.catalogs[r.logical_session_id], nil
	for _, row in (if c then c.records else {}) do if row.id == pred.record_id and row.revision == pred.record_revision then selected = row end end
	local coordinator_kind = r.kind == "coordinator"
	local p, now = policy(d, r.logical_session_id), stamp(clock).at_ms
	local routing, decision = nil, nil
	if p.quota_routing then
		-- Quota routing of the successor: the predecessor's record first, then this rollover kind's
		-- explicit allowlist with its own substitution permissions; otherwise an owner gate or a hold.
		local scope = if coordinator_kind then "coordinator_rollover" else "worker_rollover"
		local digest_now = quota.policy_digest(p)
		decision = quota.decide({ policy = p, scope = scope, catalog = c, evidence = current_evidence(d, r.logical_session_id),
			requested = { id = pred.record_id, revision = pred.record_revision }, coordinator = coordinator_kind, cwd = pred.cwd,
			placement = pred.placement, now_ms = now, bound = false })
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
		if r.quota then close_rollover_gate(d, r, pred) end
		if decision.outcome ~= "selected" then
			local reason = decision.reason or { code = "quota_held", message = "No allowed record has sufficient fresh quota." }
			return rollover_hold(r, reason.code, reason.message .. " No successor is launched; the predecessor keeps running and fresh USAGE evidence re-evaluates this.")
		end
		-- A successor may overlap only its own predecessor's reservation.
		local busy = concurrency_problem(d, r.logical_session_id, p, { [pred.worker_id] = true })
		if busy then return rollover_hold(r, busy.code, busy.message) end
		selected = decision.record
		routing = { mode = "quota", phase = "selected", scope = scope, requested = { id = pred.record_id, revision = pred.record_revision },
			coordinator = coordinator_kind, policy_digest = digest_now, decided_at_ms = 0, decision_digest = string.rep("0", 64),
			switched = decision.switched == true, needs = if decision.switched then decision.needs else nil, authority = decision.authority,
			authorized_digest = if decision.authority == "owner_gate" then approval.policy_digest else nil,
			selected = { id = selected.id, revision = selected.revision }, bound = false, candidates = {}, history = {} }
	end
	if not selected or not selected.eligible or selected.enabled ~= true or selected.cwd ~= pred.cwd or selected.placement ~= pred.placement then
		return rollover_hold(r, "catalog_changed", "The predecessor's SPAWN record/revision, cwd and placement must be present and eligible in the current catalog. Refresh the catalog; no other record is substituted.")
	end
	if count(d.workers) >= 32 then return rollover_hold(r, "full", "Managed generation capacity is full; no unresolved worker was removed.") end
	if coordinator_kind then
		if not table.find(selected.capabilities or {}, "coordinator-control-v1") then
			return rollover_hold(r, "unsupported_capability", "The predecessor coordinator's record no longer offers coordinator-control-v1; no successor is reserved.")
		end
		if n.sessions[r.logical_session_id].orchestrator ~= nil then
			return rollover_hold(r, "orchestrator_slot_occupied", "The orchestrator slot is occupied; a successor coordinator is never started beside another owner.")
		end
	end
	-- The successor's assignment is the verified checkpoint itself: no transcript, no predecessor command.
	local payload = clone(codec.decode_report(r.checkpoint, pred).payload); payload.request_id = nil
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
		prompt = prompt, cwd = pred.cwd, placement = pred.placement, assignment_sha256 = codec.sha256(prompt),
		launch_request_id = next_id(d, "launch-"), launch_action_id = next_id(d, "action-"),
		enrolment_token = codec.sha256(r.id .. ":enrolment:" .. event.origin.alias_nonce .. ":" .. worker_id), phase = "queued",
		accepted_seq = 0, compacted_floor = 0, receipts = {}, replies = {}, reply_seq = 0, reply_floor = 0,
		handover_id = r.id, handover_token = r.handover_token }
	-- Bound the immutable launch with a maximal provisional coordinator identity before reserving the slot.
	if coordinator_kind then w.coordinator_protocol = 1; w.coordinator_owner_id = string.rep("o", 96); w.coordinator_generation = MAX end
	if not str(prompt, 32768) or #tern.json.encode(launch_request(w, string.rep("h", 96))) > 8192 then
		return rollover_hold(r, "input_too_large", "The verified checkpoint handover exceeds the 8192-byte immutable launch bridge. It is never truncated: request a more concise checkpoint again or cancel. The predecessor keeps running.")
	end
	if coordinator_kind then
		-- Serialized host transition in the same commit that observed the predecessor's release.
		local reserved, response = reserve(n, { kind = "reserve_coordinator", request_id = r.id .. "-reserve", orch_session_id = r.logical_session_id, work_id = r.work_id }, clock)
		if reserved == nil then return rollover_hold(r, response.code, response.message) end
		for key, value in reserved do n[key] = value end
		w.coordinator_owner_id = response.owner_id; w.coordinator_generation = response.generation
		n.sessions[r.logical_session_id].orchestrator.managed_worker_id = worker_id
		r.successor_owner_id = response.owner_id; r.successor_generation = response.generation
	end
	local request = common(d, event.origin, event.controller_pane, "mailbox_provision"); be(w, request)
	request.record_id = w.record_id; request.record_revision = w.record_revision; request.capability = "report-files-v1"
	request.handover_id = w.handover_id; request.handover_sha256 = handover_sha256(w)
	if not add(d, request, worker_id) then return rollover_hold(r, "oversize", "Successor provision request exceeds the bridge bound; nothing was granted.") end
	d.workers[worker_id] = w
	append(d, w, "assignment", prompt, clock)
	if routing then
		w.routing = routing; routing.bound = true
		remember_decision(d, w, "selected", decision, p, now)
		reserve_slot(d, w, n.revision, now)
		r.quota = nil
		append(d, w, "routing", "Rollover successor routed to " .. w.record_id .. (if routing.switched then " instead of " .. pred.record_id .. " (" .. tostring(routing.authority) .. ")" else ""), clock)
	end
	r.successor_worker_id = worker_id; rollover_edge(r, "successor_granted", n.revision, clock)
	return true
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
	local retired = if coordinator_kind then n.retired[r.predecessor_owner_id] else nil
	if retired and (retired.orch_session_id ~= r.logical_session_id or retired.target ~= "orchestrator" or retired.generation ~= r.predecessor_generation) then retired = nil end
	-- A coordinator that self-finishes with an authenticated COORDINATOR_RELEASE before this rollover
	-- holds a verified checkpoint leaves nothing to hand over and can never publish one (only reply
	-- ACKs may follow a release). Its own release → exact stop → mailbox retirement continues, and the
	-- rollover closes visibly as cancelled with this evidence: no successor, and the slot is free for
	-- an explicit new start. After a verified checkpoint, the release is exactly the quiescence the
	-- rollover waits for and it continues normally.
	local function self_released(): boolean
		if r.quota then close_rollover_gate(d, r, pred); r.quota = nil end
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
		if found then verified, problem = codec.verify_checkpoint(found, r.request_id) end
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
		if retired and retired.reason == "confirm_recovery" then
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
		if stop and (stop.phase == "uncertain" or stop.phase == "complete" or stop.phase == "resolved") then
			return rollover_hold(r, "predecessor_stop_uncertain", "Predecessor coordinator closure is not proven (" .. stop.phase .. "; " .. reason_text(pred) .. "). The stop is never retried and no successor starts: use the recorded orchestrator's explicit recovery (inspect, verify stopped, fenced recovery). The checkpoint is retained.")
		end
		return false
	elseif r.phase == "predecessor_closed" and coordinator_kind then
		if retired then rollover_edge(r, "owner_retired", n.revision, clock); return true end
		return false -- Exact mailbox retirement and normal generation-bound release still settle.
	elseif r.phase == "owner_retired" then return grant_successor(n, r, pred, event, clock, reserve)
	elseif coordinator_kind and (r.phase == "successor_granted" or r.phase == "successor_created") and n.retired[r.successor_owner_id] ~= nil
		and n.retired[r.successor_owner_id].generation == r.successor_generation then
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
		for _, entry in f.thread do entry.state = "settled" end
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
		if stop and (stop.phase == "complete" or stop.phase == "resolved") then
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
	local keys = {}
	for key, r in d.rollovers do
		if r.logical_session_id == event.orch_session_id and not ROLLOVER_TERMINAL[r.phase] then table.insert(keys, key) end
	end
	table.sort(keys)
	for _, key in keys do
		for _ = 1, #COORDINATOR_ROLLOVER_PHASES do if not rollover_step(n, n.dispatch.rollovers[key], event, clock, reserve) then break end end
	end
end
-- Landing queue engine. One FIFO queue per session/project/repository/target and one granted
-- slot per queue. ORCH+ only issues an exact landing_grant reply and records the worker's exact
-- structured result; the project worker runs its own approved merge workflow. Every grant needs
-- the owner's approval gate for that exact request revision: the plan's Config defines no
-- automatic landing policy. Uncertainty holds the slot until explicit owner reconciliation.
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
-- Readiness of an ungranted item, recomputed from durable evidence. A missing or stale fact
-- blocks with its reason; nothing passes by default.
local function landing_problem(n: any, item: any, q: any): any?
	local d = n.dispatch
	local w, r = d.workers[item.worker_id], item.request
	item.verification = nil
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
	local verified, problem = codec.verify_landing(cp, r.source_revision)
	if not verified then return landing_hold(problem.code, problem.message) end
	item.verification = verified
	if not item.approval then
		return landing_hold("approval_pending", "Owner gate " .. tostring(item.gate_id) .. " must approve this exact request revision. ORCH+ has no automatic landing policy.")
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
local function grant_landing(n: any, q: any, item: any, event: any, clock: any): any?
	local d = n.dispatch
	local w, r = d.workers[item.worker_id], item.request
	if #item.grants >= 8 then return landing_hold("attempts_exhausted", "This item used its eight bounded grants; cancel it and request landing again.") end
	if not thread_room(w) then return landing_hold("full", "The worker's durable thread is full of unresolved items; no grant was issued.") end
	local grant_id = next_id(d, "landing-grant-")
	local payload = { landing_id = item.id, grant_id = grant_id, project_id = r.project_id, checkpoint_id = item.verification.checkpoint_id,
		repo_ref = r.repo_ref, target_ref = r.target_ref, target_revision = r.target_revision, source_ref = r.source_ref, source_revision = r.source_revision }
	local delivery, err = issue_reply(d, w, "landing_grant", payload)
	if err then return landing_hold(err.code, err.message .. " No landing grant was issued.") end
	table.insert(item.grants, { grant_id = grant_id, worker_id = w.worker_id, action_id = delivery.action_id, action_revision = delivery.action_revision,
		reply_seq = delivery.reply_seq, message_id = delivery.message_id, bytes = delivery.bytes, target_revision = r.target_revision,
		source_revision = r.source_revision, checkpoint_id = payload.checkpoint_id, controller_generation = event.origin.owner_generation,
		revision = n.revision, published = false, acknowledged = false })
	q.slot = item.id
	append(d, w, "landing_grant", bounded("Landing " .. item.id .. " granted (" .. grant_id .. "): run the approved project workflow for " .. r.source_ref .. "@"
		.. r.source_revision .. " onto " .. r.repo_ref .. " " .. r.target_ref .. " expecting head " .. r.target_revision .. ", then report one exact LANDING_RESULT.", 32768), clock,
		{ state = "pending", action_id = delivery.action_id })
	landing_status(item, "granted", nil, n.revision, clock)
	return nil
end
-- A request blocked as target_moved owes its bound worker generation exactly one immutable
-- landing_refresh per (generation, expected head, current head). The obligation is derived from
-- the item each commit, so items blocked before this reply existed are notified too, and a
-- deferred notice (full outbox, thread or reserve) is retried on a later commit without loss.
local function landing_refresh(n: any, q: any, item: any, hold: any, clock: any): any
	local d, r = n.dispatch, item.request
	local w, sent = d.workers[item.worker_id], item.refresh
	if sent and sent.worker_id == item.worker_id and sent.expected_revision == r.target_revision and sent.current_revision == q.head.revision then return hold end
	local function deferred(why: string): any
		return landing_hold(hold.code, hold.message .. " Refresh notice deferred: " .. why .. " It is issued on a later commit.")
	end
	if not w or w.phase ~= "accepted" or not w.mailbox_handle or w.finish or w.release or w.stopped or w.mailbox_retired or w.frozen
		or flow(w).exit or active_rollover(d, w) then
		return deferred("the requesting generation cannot receive replies now.")
	end
	if type(clock) == "table" and clock.reserved_capacity then return deferred("authority capacity is at its settlement reserve.") end
	if not thread_room(w) then return deferred("the worker's durable thread is full of unresolved items.") end
	local payload = { landing_id = item.id, project_id = r.project_id, repo_ref = r.repo_ref, target_ref = r.target_ref,
		expected_revision = r.target_revision, current_revision = q.head.revision,
		reason = "Target moved (" .. q.head.source .. " via " .. q.head.landing_id .. "). Rebase or rebuild onto current_revision, publish a fresh CHECKPOINT and a fresh LANDING_REQUEST expecting current_revision; it needs new owner approval. Never push without a landing_grant." }
	local delivery, err = issue_reply(d, w, "landing_refresh", payload)
	if err then return deferred(err.message) end
	item.refresh = { worker_id = w.worker_id, expected_revision = r.target_revision, current_revision = q.head.revision, action_id = delivery.action_id,
		action_revision = delivery.action_revision, reply_seq = delivery.reply_seq, message_id = delivery.message_id, bytes = delivery.bytes,
		published = false, acknowledged = false, revision = n.revision }
	append(d, w, "landing_refresh", bounded("Landing " .. item.id .. " needs a refresh: " .. r.target_ref .. " moved from " .. r.target_revision
		.. " to " .. q.head.revision .. ". Publish a fresh CHECKPOINT and LANDING_REQUEST expecting the new head.", 32768), clock,
		{ action_id = delivery.action_id })
	return hold
end
local function advance_landing(n: any, event: any, clock: any)
	local d = n.dispatch
	local L = d.landing
	if not L then return end
	local keys = {}
	for key, q in L.queues do if q.logical_session_id == event.orch_session_id then table.insert(keys, key) end end
	table.sort(keys)
	local paused = policy(d, event.orch_session_id).paused
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
			end
		end
		local held = if q.slot then L.items[q.slot] else nil
		local grant = if held then landing_current(held) else nil
		if grant and not grant.uncertain then
			local lost = landing_lost(d.workers[grant.worker_id])
			if lost then
				grant.uncertain = { code = "result_lost", at_ms = stamp(clock).at_ms, message = bounded("No exact LANDING_RESULT can arrive: " .. lost
					.. ". The slot stays held; reconcile the observed target state. Nothing is retried.", 1024) }
				held.revision += 1
			end
		end
		for index, landing_id in q.order do
			local item = L.items[landing_id]
			if LANDING_UNGRANTED[item.status] then
				local hold = landing_problem(n, item, q)
				if hold and hold.code == "target_moved" then hold = landing_refresh(n, q, item, hold, clock) end
				if index == 1 and not q.slot then
					if not hold and paused then hold = landing_hold("session_paused", "Session is paused; no landing grant is issued until resume.") end
					if not hold and type(clock) == "table" and clock.reserved_capacity then
						hold = landing_hold("capacity_reached", "Authority capacity is at its settlement reserve; no landing grant is issued.")
					end
					if not hold then hold = grant_landing(n, q, item, event, clock) end
					if hold then landing_status(item, if hold.code == "approval_pending" then "verifying" else "blocked", hold, n.revision, clock) end
				else
					landing_status(item, if hold then "queued" else "ready", hold, n.revision, clock)
				end
			end
		end
	end
end
-- Bounded retention: oldest terminal items, then empty unreferenced queues (with their history).
local function reclaim_landing(L: any, queue_needed: boolean)
	local terminal = {}
	for key, item in L.items do
		if LANDING_TERMINAL[item.status] then table.insert(terminal, { key = key, revision = item.history[#item.history].revision }) end
	end
	table.sort(terminal, function(a, b) return a.revision < b.revision or (a.revision == b.revision and a.key < b.key) end)
	for i = 1, math.min(#terminal, count(L.items) - 63) do L.items[terminal[i].key] = nil end
	if not queue_needed or count(L.queues) < 32 then return end
	local empty = {}
	for key, q in L.queues do if #q.order == 0 and not q.slot then table.insert(empty, key) end end
	table.sort(empty)
	for _, key in empty do
		if count(L.queues) < 32 then break end
		for item_key, item in L.items do if item.queue_id == key then L.items[item_key] = nil end end
		L.queues[key] = nil
	end
end
local function landing_request(n: any, w: any, report: any, clock: any): (any?, any?)
	local d, p = n.dispatch, report.payload
	if w.coordinator_owner_id then return fail("landing_unauthorized", "Coordinators may propose landing only; the project worker that owns the work requests and performs it.") end
	local L = d.landing or { queues = {}, items = {} }
	local qid = landing_queue_id(w.logical_session_id, p)
	local q, existing = L.queues[qid], nil
	for _, landing_id in (if q then q.order else {}) do
		if L.items[landing_id].work_id == w.work_id then existing = L.items[landing_id] end
	end
	if existing and not LANDING_UNGRANTED[existing.status] then
		return fail("landing_in_progress", "This work holds the landing grant for this target; report that grant's exact LANDING_RESULT before requesting again.")
	end
	if not existing then
		if count(L.items) >= 64 or (not q and count(L.queues) >= 32) then reclaim_landing(L, not q) end
		if count(L.items) >= 64 or (not q and count(L.queues) >= 32) then return fail("full", "Landing queue capacity is full of open items; nothing was evicted.") end
	end
	local landing_id = if existing then existing.id else next_id(d, "landing-")
	local question = "Approve landing " .. landing_id .. " (request report seq " .. tostring(report.seq) .. ")? Work " .. w.work_id .. " asks to land "
		.. p.source_ref .. "@" .. p.source_revision .. " (checkpoint " .. p.checkpoint_id .. ") onto " .. p.repo_ref .. " " .. p.target_ref
		.. " expecting head " .. p.target_revision .. ". Approval binds only this exact request; a refresh voids it. The grant is issued in queue order once the worker's latest checkpoint checks are fresh. The project worker runs its own approved merge workflow; ORCH+ never runs git or infers a merge."
	local gate, err = new_gate(d, w, "landing_approval", question, { { id = "approve", label = "Approve this exact landing" }, { id = "reject", label = "Reject" } },
		{ "landing:" .. landing_id, "request_event:" .. report.event_id, "checkpoint:" .. p.checkpoint_id,
			bounded("source:" .. p.source_ref .. "@" .. p.source_revision, 1024), bounded("target:" .. p.repo_ref .. " " .. p.target_ref .. "@" .. p.target_revision, 1024) }, clock)
	if err then return nil, err end
	local request = { project_id = p.project_id, repo_ref = p.repo_ref, target_ref = p.target_ref, target_revision = p.target_revision,
		source_ref = p.source_ref, source_revision = p.source_revision, checkpoint_id = p.checkpoint_id, summary = p.summary,
		event_id = report.event_id, seq = report.seq }
	if existing then
		-- Refresh in place: same queue position, new evidence; prior approval and checks are void.
		landing_withdraw_gate(d, existing, "superseded")
		landing_settle(d, existing)
		existing.request = request; existing.worker_id = w.worker_id; existing.gate_id = gate.id
		existing.approval = nil; existing.verification = nil; existing.refresh_required = nil
		existing.revision += 1
		landing_status(existing, "queued", landing_hold("refreshed", "Request refreshed by report seq " .. tostring(report.seq) .. "; awaiting verification and owner approval."), n.revision, clock)
	else
		d.landing = L
		if not q then
			q = { id = qid, logical_session_id = w.logical_session_id, project_id = p.project_id, repo_ref = p.repo_ref, target_ref = p.target_ref, order = {} }
			L.queues[qid] = q
		end
		L.items[landing_id] = { id = landing_id, revision = 1, queue_id = qid, logical_session_id = w.logical_session_id, work_id = w.work_id,
			worker_id = w.worker_id, status = "queued", at_ms = stamp(clock).at_ms, request = request, gate_id = gate.id, grants = {},
			history = { { status = "queued", revision = n.revision, at_ms = stamp(clock).at_ms } } }
		table.insert(q.order, landing_id)
	end
	return result("landing_requested", { landing_id = landing_id }), nil
end
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
	grant.result = summary
	local q = d.landing.queues[item.queue_id]
	if p.outcome == "uncertain" then
		grant.uncertain = { code = "worker_reported_uncertain", at_ms = summary.at_ms, message = bounded("The worker could not determine whether it landed: "
			.. p.reason .. ". The slot stays held until the owner reconciles the observed target state.", 1024) }
		item.revision += 1
	elseif p.outcome == "landed" then
		q.head = { revision = p.result_revision, source = "landed", landing_id = item.id }
		landing_unqueue(q, item.id)
		landing_status(item, "landed", nil, n.revision, clock); landing_settle(d, item)
	elseif p.outcome == "rejected" then
		landing_unqueue(q, item.id)
		landing_status(item, "failed", landing_hold("rejected", p.reason), n.revision, clock); landing_settle(d, item)
	else
		-- Stale target: release the slot; the item keeps its place but needs a fresh request.
		q.head = { revision = p.observed_target_revision, source = "stale_target", landing_id = item.id }
		q.slot = nil; item.refresh_required = true; item.approval = nil
		landing_status(item, "blocked", landing_hold("refresh_required", "Target head moved to " .. p.observed_target_revision
			.. "; the grant was released. Publish a fresh LANDING_REQUEST (new artifact and evidence) against the new head."), n.revision, clock)
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
local function correlated(d: any, w: any, report: any): any?
	for _, g in d.gates or {} do
		if g.worker_id == w.worker_id and g.delivery and g.delivery.action_id == report.action_id and g.delivery.action_revision == report.action_revision then return g end
	end
	for _, item in (d.landing or {}).items or {} do
		for _, g in item.grants do
			if g.worker_id == w.worker_id and g.action_id == report.action_id and g.action_revision == report.action_revision then return g end
		end
	end
	for _, r in w.replies do if r.action_id == report.action_id and r.action_revision == report.action_revision then return r end end
	local r = flow(w).report_request
	if r and r.action_id == report.action_id and r.action_revision == report.action_revision then return r end
	return nil
end
local function semantic(n: any, w: any, report: any, bytes: string, clock: any): (any?, any?)
	local d, p, kind, f = n.dispatch, report.payload, report.kind, flow(w)
	if w.phase ~= "accepted" then return fail("acceptance_required", "Progress requires this generation's accepted assignment.") end
	local correlation
	if report.action_id then
		correlation = correlated(d, w, report)
		if not correlation or correlation.phase == "cancelled" or correlation.phase == "superseded" then return fail("binding_mismatch", "Report action/revision was not issued or is no longer current for this recipient.") end
	end
	if p.request_id then
		local request = f.report_request
		if not request or request.request_id ~= p.request_id then return fail("binding_mismatch", "Progress request does not match this worker's outstanding request.") end
		if request.response_received then return fail("request_already_answered", "Replay the original immutable response; a new event cannot replace it while its reply ACK is pending.") end
		if kind ~= "WAITING" and kind ~= "HEARTBEAT" and kind ~= "CHECKPOINT" then return fail("invalid_schema", "Unexpected report request correlation.") end
	end
	local checkpoint = if p.checkpoint_id and f.checkpoints[p.checkpoint_id] then codec.decode_report(f.checkpoints[p.checkpoint_id], w) else nil
	if table.find({ "REVIEW_READY", "DONE", "ROLLOVER_REQUEST" }, kind) and (not checkpoint
		or (p.artifact_revision and p.artifact_revision ~= checkpoint.payload.artifact_revision)) then
		return fail("checkpoint_mismatch", "Report must reference a retained checkpoint and its exact artifact revision.")
	end
	if kind == "CHECKPOINT" then
		if checkpoint and not equal(checkpoint.payload, p) then return fail("checkpoint_conflict", "Checkpoint IDs are immutable; publish a new checkpoint ID for changed evidence.") end
		if not checkpoint and count(f.checkpoints) >= 16 then return fail("full", "Checkpoint evidence is full; unresolved handover/review evidence was retained.") end
		f.checkpoints[p.checkpoint_id] = bytes
	elseif kind == "ASK" then
		local _, err = new_gate(d, w, "owner_question", p.question, p.options, p.evidence, clock); if err then return nil, err end
	elseif kind == "COORDINATOR_PROPOSAL" then
		local owner, activation = coordinator(n, w), w.activation
		if not owner or owner.phase ~= "running" or not activation or not activation.acknowledged or w.retirement
			or p.owner_id ~= owner.owner_id or p.owner_generation ~= owner.generation or p.activation_token ~= activation.activation_token then
			return fail("proposal_unauthorized", "Proposal requires the active owner/generation and durably acknowledged activation token.")
		end
		if policy(d, w.logical_session_id).paused then return fail("session_paused", "Paused sessions retain proposals at their producer without granting new work.") end
		if restored_coordinator(d, w.logical_session_id) then return fail("coordinator_restored", "A retired coordinator pane was observed alive again; coordinator effects are held until it is reconciled.") end
		local target
		for _, worker in d.workers do if worker.work_id == p.work_id and worker.logical_session_id == w.logical_session_id then target = worker end end
		local target_checkpoint
		if target then
			for _, cpbytes in (if target.workflow then target.workflow.checkpoints else {}) do
				local cp = codec.decode_report(cpbytes, target)
				if cp.payload.project_id == p.project_id and (p.checkpoint_id == nil or cp.payload.checkpoint_id == p.checkpoint_id) then target_checkpoint = cp end
			end
		end
		if not target_checkpoint then return fail("scope_mismatch", "Proposal requires registered session work and its exact checkpoint project scope.") end
		for _, g in d.gates or {} do
			if g.worker_id == w.worker_id and g.proposal then
				local prior = codec.decode_report(g.proposal, w)
				if prior.payload.proposal_id == p.proposal_id then return fail("proposal_conflict", "Proposal ID already exists; replay its exact original report instead.") end
			end
		end
		if p.kind == "dispatch" then
			local found = false
			for _, record in ((d.catalogs[w.logical_session_id] or {}).records or {}) do
				if record.id == p.record_id and record.revision == p.record_revision and record.eligible and record.enabled then found = true end
			end
			if not found then return fail("catalog_changed", "Dispatch proposal must name a current eligible configured record/revision.") end
		end
		local _, err = new_gate(d, w, "coordinator_proposal", "Coordinator proposes " .. p.kind .. " for " .. p.work_id .. " in " .. p.project_id .. ". This decision does not execute a native or landing effect.",
			{ { id = "approve", label = "Approve proposal only" }, { id = "reject", label = "Reject" } }, { "checkpoint:" .. target_checkpoint.payload.checkpoint_id }, clock, bytes)
		if err then return nil, err end
	elseif kind == "REVIEW_RESULT" then
		local proposal = if correlation and correlation.proposal then codec.decode_report(correlation.proposal, w) else nil
		if not proposal or proposal.payload.kind ~= "review" or not correlation.answer or correlation.answer.choice_id ~= "approve"
			or correlation.phase ~= "acknowledged" then
			return fail("action_mismatch", "Result requires this recipient's exact approved typed proposal decision; an arbitrary reply cannot authorize a result.")
		end
		if correlation.result then return fail("result_already_recorded", "This exact proposal decision already has an immutable result; replay its original report.") end
		local target, cp
		for _, worker in d.workers do if worker.work_id == proposal.payload.work_id and worker.logical_session_id == w.logical_session_id then target = worker end end
		if target and target.workflow and target.workflow.checkpoints[proposal.payload.checkpoint_id] then cp = codec.decode_report(target.workflow.checkpoints[proposal.payload.checkpoint_id], target) end
		if not cp or p.artifact_revision ~= cp.payload.artifact_revision then
			return fail("revision_mismatch", "Result does not match the proposal's retained artifact/project revision.")
		end
		correlation.result = bytes
	elseif kind == "LANDING_REQUEST" then
		if not checkpoint or checkpoint.payload.project_id ~= p.project_id or checkpoint.payload.artifact_revision ~= p.source_revision then
			return fail("checkpoint_mismatch", "LANDING_REQUEST must reference a retained checkpoint of this project for the exact source revision.")
		end
		local _, problem = landing_request(n, w, report, clock); if problem then return nil, problem end
	elseif kind == "LANDING_RESULT" then
		local _, problem = landing_result(n, w, report, clock); if problem then return nil, problem end
	elseif kind == "DONE" then
		landing_done(d, w, clock)
	end
	local summary = p.summary or p.reason or p.question or (kind .. (if p.checkpoint_id then " " .. p.checkpoint_id else ""))
	local retained = table.find({ "WAITING", "BLOCKED", "CHECKPOINT", "REVIEW_READY", "REVIEW_RESULT", "DONE", "ROLLOVER_REQUEST", "LANDING_REQUEST", "LANDING_RESULT" }, kind) ~= nil
	if kind == "READY" or kind == "DONE" or (kind == "HEARTBEAT" and (p.state == "working" or p.state == "idle")) then
		for _, entry in f.thread do if entry.kind == "WAITING" or entry.kind == "BLOCKED" then entry.state = "settled" end end
	end
	-- A landing result's unresolved state lives on its queue item, so its thread entry is settled history.
	local _, err = append(d, w, kind, summary, clock, { event_id = report.event_id, action_id = report.action_id,
		state = if retained and kind ~= "LANDING_RESULT" then "pending" else "settled", report_bytes = if retained then bytes else nil }); if err then return nil, err end
	f.evidence[kind] = bytes
	local observation = stamp(clock); observation.kind = kind; observation.event_id = report.event_id
	observation.state = if kind == "READY" then "idle" elseif kind == "HEARTBEAT" then p.state elseif kind == "WAITING" or kind == "ASK" then "waiting"
		elseif kind == "BLOCKED" then "blocked" elseif kind == "DONE" then "done" else (if f.report then f.report.state else "working")
	f.report = observation
	-- The codec bounds context_used_pct to an integer 0..100; it is a worker report, never native fact.
	if (kind == "READY" or kind == "HEARTBEAT") and p.context_used_pct ~= nil then f.context = { used_pct = p.context_used_pct, seq = report.seq } end
	if p.request_id and (kind == "HEARTBEAT" or kind == "CHECKPOINT") then
		f.report_request.response_received = true; f.report_request.response_bytes = bytes
		if f.report_request.acknowledged then settle_entries(w, "request_id", p.request_id); f.report_request = nil end
	end
	return result("semantic_applied"), nil
end
local function intake_mutating(n: any, w: any, bytes: string, clock: any): (any?, any?)
	if w.frozen then return fail("content_conflict", "This generation is frozen; recover its conflicting immutable report.") end
	if w.rejected_report then return fail("report_held", "A rejected immutable report remains held; intake cannot overwrite or skip it.") end
	if w.pane_binding == nil then return fail("launch_unbound", "Only a correlated SPAWN launch outcome may bind report intake.") end
	local report, err = codec.decode_report(bytes, w); if err then return nil, err end
	local hash = codec.sha256(bytes)
	if report.seq <= w.compacted_floor then return fail("already_compacted", "Worker confirmed this retired receipt prefix; repair its journal rather than replaying it.") end
	if report.seq <= w.accepted_seq then
		local prior = w.receipts[tostring(report.seq)]
		if prior == nil or prior.sha256 ~= hash or prior.event_id ~= report.event_id then w.frozen = true; return result("content_conflict_frozen"), nil end
		prior.publish = true; return result("report_replayed"), nil
	end
	if report.seq ~= w.accepted_seq + 1 then return fail("gap", "Expected report sequence " .. tostring(w.accepted_seq + 1)) end
	if w.coordinator_owner_id and (not coordinator(n, w) or w.mailbox_retired) then return fail("owner_mismatch", "Retired, recovering or stale coordinator cannot submit new reports.") end
	if (w.release or w.finish or w.mailbox_retired) and report.kind ~= "reply_ack" then return fail("worker_retiring", "Only already-committed reply acknowledgements may follow explicit finish/release.") end
	local outstanding = 0
	for _, receipt in w.receipts do if (receipt.kind == "reply_ack") == (report.kind == "reply_ack") then outstanding += 1 end end
	if outstanding >= 8 then return fail("full", "This generation's report lane is full; publish the worker's cumulative watermark.") end
	if report.kind == "ACCEPTED" then
		if w.accepted_event ~= nil then return fail("already_accepted", "Initial assignment was already accepted by another event.") end
		w.phase = "accepted"; w.accepted_event = { event_id = report.event_id, seq = report.seq, event_sha256 = hash }
		w.accept_pending = true
		local observation = stamp(clock); observation.kind = "ACCEPTED"; observation.event_id = report.event_id; observation.state = "working"; flow(w).report = observation
	elseif report.kind == "reply_ack" then
		local reply = w.replies[tostring(report.payload.reply_seq)]
		if reply == nil or report.payload.message_id ~= reply.message_id or report.payload.reply_sha256 ~= reply.sha256
			or report.action_id ~= reply.action_id or report.action_revision ~= reply.action_revision then return fail("binding_mismatch", "Reply ACK does not match a committed immutable reply/action.") end
		reply.acknowledged = true
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
		-- Grant consumption is acknowledgement only; the slot settles on the exact LANDING_RESULT.
		for _, item in (n.dispatch.landing or {}).items or {} do
			for _, g in item.grants do
				if g.worker_id == w.worker_id and g.action_id == reply.action_id and g.action_revision == reply.action_revision then
					g.acknowledged = true; g.ack_seq = report.seq; g.ack_sha256 = hash
					if landing_current(item) == g and item.status == "granted" then landing_status(item, "landing", item.hold, n.revision, clock) end
				end
			end
			-- Refresh consumption is acknowledgement only; the item rebinds on a fresh LANDING_REQUEST.
			local refresh = item.refresh
			if refresh and refresh.worker_id == w.worker_id and refresh.action_id == reply.action_id and refresh.action_revision == reply.action_revision then
				refresh.acknowledged = true; refresh.ack_seq = report.seq; refresh.ack_sha256 = hash
			end
		end
		for _, name in { "activation", "retirement" } do
			local grant = w[name]
			if grant and grant.action_id == reply.action_id and grant.action_revision == reply.action_revision then
				grant.acknowledged = true; grant.ack_seq = report.seq; grant.ack_sha256 = hash
			end
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
		local _, problem = semantic(n, w, report, bytes, clock); if problem then return nil, problem end
	end
	local ack = { version = 1, event_id = report.event_id, seq = report.seq, event_sha256 = hash, committed_revision = n.revision, disposition = "accepted" }
	for _, k in B do ack[k] = w[k] end
	ack.receipt_chain_sha256 = codec.receipt_chain(w.mailbox_handle, w.receipt_chain, ack)
	local encoded = tern.json.encode(ack)
	w.receipts[tostring(report.seq)] = { bytes = encoded, sha256 = hash, event_id = report.event_id, chain = ack.receipt_chain_sha256, publish = true, kind = report.kind }
	w.accepted_seq = report.seq; w.receipt_chain = ack.receipt_chain_sha256
	while w.replies[tostring(w.reply_floor + 1)] and w.replies[tostring(w.reply_floor + 1)].acknowledged do
		w.reply_floor += 1; w.replies[tostring(w.reply_floor)] = nil; w.compaction_pending = n.revision
	end
	refresh(n.dispatch, w, clock)
	return result("report_committed"), nil
end
local function intake(n: any, w: any, bytes: string, clock: any): (any?, any?)
	-- Semantic failure leaves even the caller's candidate untouched, including full-lane recovery.
	local trial = table.clone(n); trial.dispatch = table.clone(n.dispatch); trial.sessions = clone(n.sessions)
	trial.dispatch.gates = clone(n.dispatch.gates); trial.dispatch.workers = clone(n.dispatch.workers); trial.dispatch.landing = clone(n.dispatch.landing)
	local worker = trial.dispatch.workers[w.worker_id]
	local applied, err = intake_mutating(trial, worker, bytes, clock)
	if err then return nil, err end
	for key in w do w[key] = nil end
	for key, value in worker do w[key] = value end
	trial.dispatch.workers[w.worker_id] = w; n.dispatch.workers = trial.dispatch.workers
	n.dispatch.serial = trial.dispatch.serial; n.dispatch.gates = trial.dispatch.gates; n.dispatch.landing = trial.dispatch.landing; n.sessions = trial.sessions
	return applied, nil
end
M.intake = intake
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
-- SPAWN refuses a staged request whose window authorization was never consumed when explicit owner
-- recovery or attachment fences the old controller. That refusal is definitively unexecuted for
-- every operation. `accept` is idempotent for the same immutable enrolment and ACCEPTED event and
-- is re-issued on the explicitly continued route; wakes, publications, reads, compaction, stop and
-- retirement return to their normal lanes; attachment still needs the owner's explicit reattach.
-- Older SPAWN builds report these as binding_mismatch with the exact messages below.
local REVOKED_AUTHORIZATION = { ["Controller recovery revoked the unconsumed authorization"] = true, ["Explicit attachment fenced the old window challenge"] = true }
local function revoked_authorization(problem: any): boolean
	return type(problem) == "table" and (problem.code == "authorization_revoked" or (problem.code == "binding_mismatch" and REVOKED_AUTHORIZATION[problem.message] == true))
end
-- A worker held only because a never-consumed authorization was revoked (state written before
-- revocation stopped holding) resumes as accepted once its current route is explicitly continued;
-- nothing else about the held generation changes. Lane markers still pointing at such a retained,
-- definitively unexecuted action are released so the same obligation is re-issued.
local function resume_revoked(d: any, w: any)
	if w.phase == "held" and w.accepted_event ~= nil and not w.continuation_required and revoked_authorization(w.reason) then
		w.phase = "accepted"; w.reason = nil
	end
	local function revoked(action_id: any): boolean
		local a = if action_id then d.actions[action_id] else nil
		return a ~= nil and a.phase == "complete" and a.response ~= nil and a.response.status == "rejected" and revoked_authorization(a.response.error)
	end
	if revoked(w.stop_action_id) then w.stop_action_id = nil end
	if revoked(w.mailbox_retire_action_id) then w.mailbox_retire_action_id = nil end
	for _, wake in w.wakes or {} do if revoked(wake.action_id) then wake.action_id = nil end end
end
-- Reload restores an occupied coordinator owner as `uncertain`; controller continuation alone never
-- reactivates it. After the owner's explicit attested attachment of this exact generation commits
-- and no executor of that owner/generation remains claimed, uncertain or counted, the same
-- generation resumes with its unchanged enrolment and activation (or retirement) evidence. A
-- pending recovery intent, retirement record or restored-pane hold keeps it uncertain.
local function resume_attached_coordinator(n: any, d: any, w: any, owner: any)
	if owner.phase ~= "uncertain" or owner.recovery ~= nil or owner.owner_id ~= w.coordinator_owner_id or owner.generation ~= w.coordinator_generation
		or owner.managed_worker_id ~= w.worker_id or owner.pending_executors ~= 0 or n.retired[owner.owner_id] ~= nil or w.coordinator_protocol ~= 1
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
	a.phase = "resolved"
	a.resolution = { revision = n.revision, executor = a.claim.executor, evidence = evidence, reason = reason, status_sha256 = status_sha256 }
	local session = n.sessions[a.request.origin_binding.logical_session_id]
	if session.controller then session.controller.pending_executors = math.max(0, session.controller.pending_executors - 1) end
	local w = if a.worker_id then n.dispatch.workers[a.worker_id] else nil
	if not w then return end
	local owner = session.orchestrator
	if owner and owner.owner_id == w.coordinator_owner_id then owner.pending_executors = math.max(0, owner.pending_executors - 1) end
	if a.request.op == "mailbox_read" then w.read_selector = nil; w.assembly = nil end
	note_reason(w, { code = "read_resolved", message = "Retained uncertain read " .. a.request.action_id .. " resolved (" .. evidence .. "); nothing it read was applied, so the worker re-reads from its durable cursor." })
end
local function complete(n: any, a: any, body: any, clock: any): (any?, any?)
	local d, payload = n.dispatch, body.payload
	local request = a.request
	local w = if a.worker_id then d.workers[a.worker_id] else nil
	if body.status == "uncertain" then
		a.phase = "uncertain"
		if w then note_reason(w, body.error or { code = "effect_uncertain", message = "Exact " .. request.op .. " may have executed. Read its retained SPAWN outcome; never repeat the effect or infer closure." }) end
		return result("effect_uncertain"), nil
	end
	if table.find({ "resolved", "claimed", "launching", "pending" }, body.status) then return fail("pending", "SPAWN has not completed this operation.") end
	if body.status == "full" or body.status == "incomplete" then
		if w then note_reason(w, body.error or { code = body.status, message = "Transport backpressure; retained work and acceptance are unchanged." }) end
		if body.status == "full" and retryable_full(payload) then
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
		if request.op == "accept" and body.status == "rejected" and w and w.accept_pending and revoked_authorization(problem) then
			a.phase = "complete"
			local message = "SPAWN revoked this acceptance's never-consumed authorization during owner recovery or attachment; nothing was accepted. The same acceptance is re-issued on the explicitly continued route."
			note_reason(w, { code = "accept_reissue", message = message })
			return { ok = true, code = "accept_reissue", message = message }, nil
		end
		-- Launch, adoption and provisioning have no automatic re-issue lane and keep the explicit hold.
		if body.status == "rejected" and w and revoked_authorization(problem) and table.find({ "native_wake", "mailbox_publish_ack", "mailbox_publish_reply",
			"mailbox_read", "mailbox_retire", "stop", "attach_worker" }, request.op) then
			a.phase = "complete"
			if request.op == "attach_worker" then
				local message = "SPAWN revoked this attachment's never-consumed authorization; nothing was attached. The worker still needs explicit reattachment."
				note_reason(w, { code = "reattach_required", message = message })
				return { ok = true, code = "reattach_required", message = message }, nil
			end
			-- Release this action's lane marker so the same obligation is re-issued on the current route.
			if w.stop_action_id == request.action_id then w.stop_action_id = nil end
			if w.mailbox_retire_action_id == request.action_id then w.mailbox_retire_action_id = nil end
			for _, wake in w.wakes or {} do if wake.action_id == request.action_id then wake.action_id = nil end end
			local message = "SPAWN revoked this " .. request.op .. "'s never-consumed authorization during owner recovery or attachment; nothing ran. The same obligation is re-issued on the explicitly continued route."
			note_reason(w, { code = "authorization_reissue", message = message })
			return { ok = true, code = "authorization_reissue", message = message }, nil
		end
		-- SPAWN's exact pre-effect refusal of a stopped generation's retirement: nothing was removed, so
		-- the effect slot is released and the mailbox stays provisioned. The refused action stays the
		-- retirement marker, so the poll driver never loops; the sweep or the owner re-arms one attempt.
		if request.op == "mailbox_retire" and request.mode == "retire" and body.status == "rejected" and w and w.stopped
			and w.mailbox_retire_action_id == request.action_id and problem.code == "producer_unsettled" then
			a.phase = "complete"
			local message = "SPAWN refused this stopped generation's mailbox retirement before any effect: its helper journal still holds pending reports or unacknowledged/unresolved control messages. Nothing was retired or retried; the mailbox stays provisioned. The nightly sweep or Retry mailbox retirement once… issues one fresh attempt."
			note_reason(w, { code = "retirement_refused", message = message })
			return { ok = true, code = "retirement_refused", message = message }, nil
		end
		if w then w.phase = "held"; w.reason = problem end
		a.phase = "complete"
		return { ok = true, code = "bridge_rejected", message = "SPAWN prerequisite/outcome: " .. tostring(problem.code or body.status)
			.. " · " .. tostring(problem.message or problem.detail or "Inspect the selected record and retained operation; no fallback was used.") }, nil
	elseif request.op == "catalog" then
		if body.status ~= "catalog" or not catalog(payload) then return fail("invalid_catalog", "SPAWN returned an incompatible catalog; configure the compatible bridge.") end
		d.catalogs[request.origin_binding.logical_session_id] = clone(payload)
	elseif request.op == "mailbox_provision" then
		if body.status ~= "provisioned" or type(payload) ~= "table" or not id(payload.handle) or not digest(payload.binding_digest) or type(payload.capabilities) ~= "table"
			or not table.find(payload.capabilities, "report-files-v1") or not (table.find(payload.capabilities, "native-ask-v1") or table.find(payload.capabilities, "worker-poll-v1")) then return fail("unsupported_capability", "Provisioning must prove report-files-v1 and a configured native wake or worker polling route before launch.") end
		if w.coordinator_protocol == 1 and not table.find(payload.capabilities, "coordinator-control-v1") then
			return fail("unsupported_capability", "Selected coordinator mailbox did not provision coordinator-control-v1; no launch is authorized.")
		end
		w.mailbox_handle = payload.handle; w.capabilities = clone(payload.capabilities); w.binding_digest = payload.binding_digest
		w.receipt_chain = codec.receipt_chain(payload.handle); w.compacted_chain = w.receipt_chain
		local launch = launch_request(w, w.mailbox_handle)
		if not add(d, launch, w.worker_id) then return fail("oversize", "Immutable launch request exceeds the bridge bound; no launch was granted.") end
		w.phase = "provisioned"
	elseif request.op == "launch" or request.op == "adopt" then
		if (body.status ~= "awaiting_acceptance" and body.status ~= "launched" and body.status ~= "accepted") or type(payload) ~= "table" or not pane_binding(payload.pane_binding, w.origin_binding)
			or (request.op == "adopt" and not equal(payload.pane_binding, w.adopt_pane_binding)) then return fail("binding_mismatch", "Launch/adoption lacks its exact origin-scoped native pane outcome.") end
		w.pane_binding = clone(payload.pane_binding); w.phase = "awaiting_acceptance"; w.effective_identity = clone(payload.effective_identity)
		if w.coordinator_owner_id then
			local owner = n.sessions[w.logical_session_id].orchestrator
			if owner == nil or owner.owner_id ~= w.coordinator_owner_id or owner.generation ~= w.coordinator_generation or owner.phase ~= "reserved" then return fail("owner_mismatch", "Coordinator reservation changed; retained outcome cannot bind a successor.") end
			-- Window pane aliases are never copied into the host-local pane binding.
			owner.owner_active = true; owner.phase = "running"
		end
	elseif request.op == "attach_worker" then
		if body.status ~= "attached" or not closed(payload, "pane_binding previous_origin_binding previous_pane_binding")
			or not equal(payload.pane_binding, request.pane_binding) or not equal(payload.previous_origin_binding, w.origin_binding)
			or not equal(payload.previous_pane_binding, w.pane_binding) then return fail("attachment_mismatch", "SPAWN must confirm this exact operator-selected attachment without changing launch identity.") end
		w.control_origin = clone(request.origin_binding); w.control_pane = request.controller_pane
		w.control_pane_binding = clone(request.pane_binding); w.attachment_action_id = request.action_id; w.continuation_required = false
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
		if (request.op == "mailbox_publish_ack" or request.part == "manifest") and type(payload) == "table" and payload.wake_status ~= nil then
			if payload.wake_status == "awaiting_window" and payload.wake_effect_started == false then
				local target_id, target_request = payload.wake_target_action_id, payload.wake_target_request_id
				local target = if id(target_id) then d.actions[target_id] else nil
				if not target or target.worker_id ~= w.worker_id or target.request.request_id ~= target_request or target.request.op ~= request.op
					or (request.op == "mailbox_publish_ack" and target.request.ack_sha256 ~= request.ack_sha256)
					or (request.op == "mailbox_publish_reply" and (target.request.part ~= "manifest" or target.request.message_id ~= request.message_id
						or target.request.reply_sha256 ~= request.reply_sha256)) then
					return fail("wake_target_mismatch", "Deferred wake must identify the retained canonical publication.")
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
					.. "Coordinator authority covers only this assignment, not OS/account isolation. Use the launch-preface producer_helper/root/handle/enrolment_token. consume durably records the grant and reply_ack; claim before work. Retain owner_id, owner_generation, activation_token and action_id/action_revision outside the execution journal. Do not independently orchestrate Tern or start agents. ORCH+ accepts explicit READY/HEARTBEAT/WAITING/BLOCKED/ASK and structured CHECKPOINT evidence. Echo each report_request.payload.request_id in one HEARTBEAT or CHECKPOINT; reply_ack alone is not fulfillment. ASK payload is question, options [{id,label}], optional evidence [string]. Only after this activation ACK is accepted, COORDINATOR_PROPOSAL payload may contain owner_id, owner_generation, activation_token, proposal_id, kind, work_id, project_id. kind is dispatch/report/review/rollover/landing. Scope must already exist as registered session work and a retained CHECKPOINT project. dispatch additionally requires current configured record_id, record_revision, prompt and forbids checkpoint_id; report has no extra fields; review/rollover/landing require checkpoint_id. Every proposal becomes an owner gate, never a direct native/merge/account action. owner_decision must be consumed once with its exact gate/action revisions; approval is proposal data, not permission to run Tern or landing commands. An approved landing proposal is a decision record only: the project worker itself sends LANDING_REQUEST and lands only under its own landing_grant. Pause/retirement forbids fresh proposals. Fulfill outstanding progress requests and settle owner decisions before release. When the assigned task finishes or typed retirement requests stop, quiesce and resolve genuinely completed control messages; never resolve unfinished or uncertain work. Report a JSON object with kind=COORDINATOR_RELEASE, issued action_id/action_revision, and payload containing exactly owner_id, owner_generation, activation_token, quiescent=true. Retirement forbids fresh work; if it races self-finish, claim and resolve it without a second release. Drain final receipts and available replies. With native-ask-v1, end the turn idle while awaiting notifications; never hold the turn open polling or waiting for control. Only worker-poll-v1 uses bounded wait. Unresolved executions block mailbox retirement. ORCH+/SPAWN own exact native stop and mailbox cleanup. DONE, idle and absence are never release." })
			if err then return nil, err end
			w.activation = grant
		end
	elseif request.op == "stop" then
		if body.status ~= "stopped" or not settled(w) or (w.coordinator_owner_id and not coordinator(n, w)) then return fail("stop_pending", "Exact stopped outcome and settled generation are required.") end
		w.stopped = clone(payload); w.reason = nil
		local exited = stamp(clock); exited.state = "exited"; flow(w).exit = exited
	elseif request.op == "mailbox_retire" then
		if request.mode == "retire" then
			-- A withdrawn rejected launch never had a producer: its unused mailbox retires without a stop.
			local withdrawn = launch_rejected(d, w) and w.mailbox_retire_action_id == request.action_id
			if body.status ~= "retired" or not (withdrawn or (w.stopped and settled(w))) or (w.coordinator_owner_id and not withdrawn and not coordinator(n, w)) then
				return fail("transport_pending", "Exact stopped mailbox retirement is not confirmed.")
			end
			w.mailbox_retired = true; w.reason = nil
		elseif body.status ~= "compacted" and body.status ~= "already_compacted" then return fail("transport_pending", "Mailbox compaction is not confirmed.") end
		if request.report_floor == w.compacted_floor and request.reply_floor == w.reply_floor then w.compaction_pending = nil end
		local removed = {}
		for id, previous in d.actions do
			if previous.worker_id == w.worker_id and (previous.phase == "complete"
				or (previous.phase == "resolved" and previous.resolution and previous.resolution.evidence == "publication_readback")) then
				local operation = previous.request
				local settled = operation.op == "mailbox_publish_reply" and operation.reply_seq <= request.reply_floor
				if operation.op == "mailbox_publish_ack" then
					local ack = codec.strict_decode(tern.base64.decode(operation.ack_b64), 2048)
					settled = ack.seq <= request.report_floor
				elseif operation.op == "mailbox_retire" then
					settled = operation.mode == "compact" and operation.settlement_revision <= request.settlement_revision
				end
				if settled and not (w.wakes or {})[id] then d.actions[id] = nil; removed[id] = true end
			end
		end
		for id, previous in d.actions do
			if previous.worker_id == w.worker_id and (previous.phase == "complete" or (previous.phase == "resolved" and previous.resolution
				and previous.resolution.evidence ~= "operator_attested")) and previous.request.op == "native_wake"
				and not (w.wakes or {})[previous.request.target_action_id] and not d.actions[previous.request.target_action_id] then
				d.actions[id] = nil; removed[id] = true
			end
		end
		for id, command in d.commands do
			if removed[command.event.action_id] or removed[command.result.action_id] then d.commands[id] = nil end
		end
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
				if active >= 4 and not w.assembly then
					a.phase = "complete"; w.read_selector = nil
					local message = "Host reassembly slots are full; immutable source remains unacknowledged and watermark settlement is available."
					note_reason(w, { code = "full", message = message })
					return { ok = true, code = "intake_backpressure", report_applied = false, message = message }, nil
				end
				local pool = codec.new_reassembler(); local _, problem = codec.begin_assembly(pool, page.bytes, report_binding(w), page.sha256); if problem then return nil, problem end
				w.assembly = { manifest = page.bytes, sha256 = page.sha256, chunks = {} }
				w.read_selector = { stream = "report", slot = page.object.slot, part = "chunk", index = 1 }
			else
				if not w.assembly then return fail("incomplete", "No retained manifest for this chunk.") end
				local pool = codec.new_reassembler()
				local _, begin_error = codec.begin_assembly(pool, w.assembly.manifest, report_binding(w), w.assembly.sha256)
				if begin_error then return nil, begin_error end
				for _, part in w.assembly.chunks do
					local _, problem = codec.push_chunk(pool, part.bytes, report_binding(w), part.sha256)
					if problem then return nil, problem end
				end
				local assembled, problem = codec.push_chunk(pool, page.bytes, report_binding(w), page.sha256)
				if problem then
					if problem.completed_bytes then return reject_read(a, w, problem.completed_bytes, problem) end
					return nil, problem
				end
				table.insert(w.assembly.chunks, { bytes = page.bytes, sha256 = page.sha256 })
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
				else w.read_selector = { stream = "report", slot = page.object.slot, part = "chunk", index = page.object.index + 1 } end
			end
		end
	end
	a.phase = "complete"
	return result("bridge_committed"), nil
end
local function discard_settled_reads(d: any, session_id: string)
	local removed = {}
	for key, a in d.actions do
		if (a.phase == "complete" or (a.phase == "resolved" and a.resolution and a.resolution.evidence ~= "operator_attested"))
			and a.request.origin_binding.logical_session_id == session_id
			and (a.request.op == "mailbox_read" or a.request.op == "catalog") then d.actions[key] = nil; removed[key] = true end
	end
	for key, command in d.commands do
		if removed[command.event.action_id] or removed[command.result.action_id] then d.commands[key] = nil end
	end
end
function M.tick(registry: any, event: any, clock: any): (any?, any)
	if not closed(event, "kind") or event.kind ~= "workflow_tick" or type(clock) ~= "table" or not valid_stamp(stamp(clock))
		or not id(clock.epoch) or type(clock.mono_ms) ~= "number" or clock.mono_ms < 0 or clock.mono_ms > MAX then
		return fail("invalid_clock", "Workflow ticks require the host's current monotonic incarnation and audit clock.")
	end
	if not registry.dispatch then return nil, result("no_progress") end
	-- Probe on shallow copies first: refresh writes only a worker's top-level workflow fields and
	-- reads no other worker, so an idle tick clones no registry subtree. Due work then takes the
	-- original full candidate path, committing exactly the same outcome.
	local due = false
	for _, w in registry.dispatch.workers do
		local probe = table.clone(w)
		if w.workflow then probe.workflow = table.clone(w.workflow) end
		refresh(registry.dispatch, probe, clock)
		if not equal(probe.workflow, w.workflow) then due = true; break end
	end
	if not due then return nil, result("no_progress") end
	local n = candidate(registry)
	for _, w in n.dispatch.workers do refresh(n.dispatch, w, clock) end
	if equal(n.dispatch, registry.dispatch) then return nil, result("no_progress") end
	if registry.revision == MAX then return fail("full", "Authority revision exhausted.") end
	return n, result("workflow_updated")
end
-- Explicit continuation moves never-launched work onto the continued route: its launch is absent
-- or ready and never claimed, so no native effect of it can have started. Its never-claimed
-- provision/launch requests were never sent (a host claim precedes every send) and are rewritten
-- in place under the same request and action IDs. A claimed provision keeps its exact request and
-- settles through the continued route (execution_origin); the launch it releases is then built on
-- that route. A claimed launch keeps its original route and stays strict. Adoption (a pane
-- attested in the original window) and rollover successors (their own fenced hold) stay fenced.
local function rebind_unlaunched(d: any, event: any)
	local function unsent(a: any): boolean return a.phase == "ready" and a.claim == nil and a.response == nil end
	for _, w in d.workers do
		local o, launch = w.origin_binding, d.actions[w.launch_action_id]
		if w.logical_session_id ~= event.orch_session_id or w.pane_binding or w.adopt_pane_binding or w.handover_id
			or (w.phase ~= "queued" and w.phase ~= "provisioned") or (launch and not unsent(launch))
			or o.owner_id ~= event.origin.owner_id or o.owner_generation ~= event.origin.owner_generation
			or o.host_pane_id ~= event.origin.host_pane_id or o.alias_nonce ~= event.origin.alias_nonce
			or (equal(o, event.origin) and w.controller_pane == event.controller_pane) then continue end
		local rebound = table.clone(w); rebound.origin_binding = clone(event.origin); rebound.controller_pane = event.controller_pane
		local rewrites, movable = {}, true
		for key, a in d.actions do
			if a.worker_id ~= w.worker_id then continue end
			if a.request.op ~= "mailbox_provision" and a.request.op ~= "launch" then movable = false; break end
			if unsent(a) then
				local request
				if a.request.op == "launch" then request = launch_request(rebound, w.mailbox_handle)
				else request = clone(a.request); request.origin_binding = clone(event.origin); request.controller_pane = event.controller_pane end
				local bytes = tern.json.encode(request)
				if #bytes > 8192 then movable = false; break end
				rewrites[key] = { request = request, bytes = bytes }
			end
		end
		if movable then
			w.origin_binding = rebound.origin_binding; w.controller_pane = rebound.controller_pane
			for key, rewrite in rewrites do d.actions[key].request = rewrite.request; d.actions[key].request_bytes = rewrite.bytes end
		end
	end
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
		elseif old_route and ((action.phase == "ready" and action.claim == nil) or (action.phase == "backpressure" and action.response and retryable_full(action.response.payload))) then
			local evidence = if action.phase == "ready" then "never_claimed" else "pre_effect_refusal"
			action.phase = "resolved"; action.resolution = { revision = revision, evidence = evidence, executor = event.origin.window_epoch,
				reason = "Explicit continuation fenced a conclusively unexecuted old-route intent." }
			local w = if action.worker_id then d.workers[action.worker_id] else nil
			if w then
				if w.stop_action_id == action.request.action_id then w.stop_action_id = nil end
				if w.mailbox_retire_action_id == action.request.action_id then w.mailbox_retire_action_id = nil end
				for _, wake in w.wakes or {} do if wake.action_id == action.request.action_id then wake.action_id = nil end end
			end
		end
	end
end
-- Never-launched work with no lane left, returning its one unexecuted provision/launch/adoption
-- action; the owner may withdraw the work (cancel_work):
-- - queued/provisioned work whose action explicit continuation fenced as conclusively unexecuted
--   (never claimed, or SPAWN's retryable pre-effect `full`): rebind_unlaunched moves only never-sent
--   requests, and SPAWN never accepts a request ID reused with a changed route;
-- - held work whose provision SPAWN definitively rejected before any effect (no mailbox exists, no
--   launch was built). A rejected request is terminal in SPAWN, and nothing re-issues it here.
local FENCED_EVIDENCE: any = { never_claimed = true, pre_effect_refusal = true }
local function fenced_unlaunched(d: any, w: any): (string?, any?)
	if w.pane_binding or w.control_origin or w.accepted_event or w.handover_id or w.stopped or w.mailbox_retired
		or (w.phase ~= "queued" and w.phase ~= "provisioned" and w.phase ~= "held") or (w.phase == "held" and w.mailbox_handle) then return nil, nil end
	local key: string?, fenced: any = nil, nil
	for k, a in d.actions do
		if a.worker_id ~= w.worker_id or (w.phase == "provisioned" and a.request.op == "mailbox_provision" and a.phase == "complete") then continue end
		local unexecuted = if w.phase == "held"
			then a.request.op == "mailbox_provision" and a.phase == "complete" and a.response ~= nil and a.response.status == "rejected"
			else (if w.phase == "queued" then a.request.op == "mailbox_provision" else k == w.launch_action_id)
				and a.phase == "resolved" and a.resolution ~= nil and FENCED_EVIDENCE[a.resolution.evidence] == true
		if fenced or not unexecuted then return nil, nil end
		key, fenced = k, a
	end
	return key, fenced
end
-- SPAWN can retain a fenced request only if a claim ever sent it: the host claim precedes every
-- send, and `retry` (the only path that clears a claim) keeps the SPAWN response it answered. A
-- retained rejection is itself SPAWN's terminal outcome, so it needs no further status read.
local function status_required(a: any): boolean return a.phase == "resolved" and (a.response ~= nil or a.retry_count ~= nil) end
local function withdrawal_view(d: any, w: any): any?
	local key, a = fenced_unlaunched(d, w)
	local retire: string? = nil
	if not a and launch_rejected(d, w) and not w.mailbox_retired then
		key, a = w.launch_action_id, d.actions[w.launch_action_id]
		local prior = if w.mailbox_retire_action_id then d.actions[w.mailbox_retire_action_id] else nil
		-- `retiring` blocks another cancel; a definitely refused retirement may be cancelled again.
		retire = if not prior then "not_requested" elseif prior.phase == "complete" and prior.response and prior.response.status == "rejected" then "refused" else "retiring"
	end
	if not a then return nil end
	return { action_id = key, op = a.request.op, evidence = if a.resolution then a.resolution.evidence else "spawn_rejected", status_required = status_required(a),
		request_id = a.request.request_id, origin_binding = clone(a.request.origin_binding), controller_generation = a.request.controller_generation,
		mailbox_retire = retire }
end
-- SPAWN's read-only `status` of a fenced request, read by the window just before withdrawal. Only a
-- definitively unexecutable retained outcome qualifies: no record (`missing`), a terminal
-- `rejected`, or a retryable pre-effect `full` (also how SPAWN reports an unconsumed challenge past
-- its deadline or from an earlier host VM, which M.authorize refuses). A still-live challenge, an
-- operation in progress or any other outcome refuses. A later exact re-stage of the old request is
-- never authorized: SPAWN's window authorizes only an ORCH+ action it observes claimed on its exact
-- current route, and withdrawal removes the action.
local function unexecutable_in_spawn(a: any, event: any): any?
	local function refuse(code: string, message: string): any local _, problem = fail(code, message); return problem end
	local query = if str(event.query_bytes, 4096) then codec.strict_decode(event.query_bytes, 4096) else nil
	if not closed(query, "schema origin op request_id action_id origin_binding controller_pane controller_generation target_request_id")
		or query.schema ~= 1 or query.origin ~= "orchplus" or query.op ~= "status" or not id(query.request_id) or not id(query.action_id)
		or query.target_request_id ~= a.request.request_id or query.controller_generation ~= a.request.controller_generation
		or not equal(query.origin_binding, a.request.origin_binding) then
		return refuse("binding_mismatch", "SPAWN status evidence must name this exact fenced request; nothing was cancelled.")
	end
	local body, err = M.decode_response(event.response_bytes, query); if err then return err end
	if body.status == "missing" then return nil end
	local outcome = if body.status == "found" and closed(body.payload, "outcome") then body.payload.outcome else nil
	if not closed(outcome, "schema op request_id action_id origin_binding controller_generation status payload error") or outcome.schema ~= 1
		or outcome.op ~= a.request.op or outcome.request_id ~= a.request.request_id or outcome.action_id ~= a.request.action_id
		or outcome.controller_generation ~= a.request.controller_generation or not equal(outcome.origin_binding, a.request.origin_binding) then
		return refuse("status_unavailable", "SPAWN did not report this exact request's retained outcome; nothing was cancelled. Read its status again.")
	end
	if outcome.status == "rejected" or (outcome.status == "full" and retryable_full(outcome.payload)) then return nil end
	if outcome.status == "pending" and closed(outcome.payload, "authorization_required") and outcome.payload.authorization_required == true then
		return refuse("authorization_live", "SPAWN still holds a live window challenge for this request. It expires within 30 s; cancel again after that. Nothing was cancelled.")
	end
	return refuse("spawn_outcome_open", "SPAWN's retained outcome for this request is " .. tostring(outcome.status):sub(1, 96)
		.. ", not definitively unexecuted; nothing was cancelled. Inspect it in SPAWN: Running agents.")
end
local function continuation_proof(registry: any, w: any): string
	-- Fixed field order and length framing avoid JSON map-order or delimiter ambiguity.
	-- Only this worker's authority/effects matter, not another worker's health tick.
	local parts = {}
	local function include(record: any, keys: string)
		for key in keys:gmatch("%S+") do
			local value = tostring(if record then record[key] else nil)
			table.insert(parts, tostring(#value) .. ":" .. value)
		end
	end
	local origin_keys = "logical_session_id owner_id owner_generation host_pane_id alias_nonce window_key window_epoch native_session_id window_host_id"
	include(registry, "execution_epoch")
	include(w, "worker_id work_id worker_generation launch_request_id launch_action_id enrolment_token mailbox_handle phase accepted_seq compacted_floor reply_seq reply_floor attachment_action_id stop_action_id mailbox_retire_action_id mailbox_retired continuation_required")
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
	local keys = {}
	for key, action in registry.dispatch.actions do
		if action.worker_id == w.worker_id and (action.phase ~= "complete" or (w.wakes or {})[key]) then table.insert(keys, key) end
	end
	table.sort(keys)
	for _, key in keys do
		local action = registry.dispatch.actions[key]
		include(action, "request_bytes phase response_bytes response_grant")
		include(action.claim, "executor epoch grant_id"); include(action.resolution, "revision executor evidence")
	end
	keys = {}
	for key, gate in registry.dispatch.gates or {} do
		if gate.worker_id == w.worker_id and (gate_open(gate) or gate.proposal or (gate.delivery and not gate.delivery.acknowledged)) then table.insert(keys, key) end
	end
	table.sort(keys)
	for _, key in keys do
		local gate = registry.dispatch.gates[key]
		include(gate, "id revision phase delivery_uncertain")
		include(gate.delivery, "action_id action_revision reply_seq acknowledged")
	end
	-- Granted/uncertain landing slots bound to this worker are retained effects of its route.
	keys = {}
	for key, item in (registry.dispatch.landing or {}).items or {} do
		if item.worker_id == w.worker_id and (item.status == "granted" or item.status == "landing") then table.insert(keys, key) end
	end
	table.sort(keys)
	for _, key in keys do
		local item = registry.dispatch.landing.items[key]; local grant = item.grants[#item.grants]
		include(item, "id status"); include(grant, "grant_id action_id acknowledged")
		include(grant.uncertain, "code")
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
local function observation_unchanged(d: any, w: any, event: any, clock: any): boolean
	local f = w.workflow
	local last = if f then f.native else nil
	if last == nil or w.pane_binding == nil or not equal(control_origin(w), event.origin) or not equal(control_binding(w), event.pane_binding)
		or last.state ~= event.native_state or last.delivery_error ~= event.delivery_error
		or (next(w.wakes or {}) ~= nil and (event.native_state ~= "idle" or event.delivery_error ~= nil))
		or (w.coordinator_owner_id and w.stopped) or (w.restored and not w.restored.reconciled)
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
local function poll_idle(registry: any, d: any, w: any, event: any, clock: any): boolean
	local f = if w then w.workflow else nil
	if not f or w.phase ~= "accepted" or not equal(control_origin(w), event.origin) or not w.mailbox_handle or not w.pane_binding
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
function M.apply(registry: any, event: any, clock: any, reserve: any): (any?, any)
	if not closed(event, "kind request_id orch_session_id origin controller_pane command command_seq record_id record_revision catalog_revision prompt cwd placement coordinator action_id executor grant_id response_bytes query_bytes worker_id bytes expected_revision continuation_proof operator_verified reason policy expected_policy pane_binding native_state delivery_error gate_id gate_revision choice_id answer observation_seq trigger landing_id landing_revision direction outcome target_revision capacity capacity_validation local_date catch_up attestation")
		or event.kind ~= "dispatch" or not id(event.request_id) or not authorized(registry, event.origin, event.controller_pane, event.command == "continue_controller")
		or event.orch_session_id ~= event.origin.logical_session_id then return fail("controller_mismatch", "Only the admitted active controller binding may dispatch in this origin.") end
	local specific = {
		catalog = "bytes", queue = "record_id record_revision catalog_revision prompt cwd placement coordinator",
		adopt = "record_id record_revision catalog_revision prompt pane_binding attestation",
		claim = "action_id executor capacity_validation", result = "action_id executor grant_id response_bytes", lost = "action_id executor grant_id",
		read_missing = "action_id executor grant_id query_bytes response_bytes",
		capacity = "capacity", cancel_work = "worker_id query_bytes response_bytes",
		poll = "worker_id bytes", reply = "worker_id", retire = "worker_id", finish = "worker_id", intake = "worker_id bytes", retry = "action_id", readback_publication = "action_id",
		policy = "policy expected_policy", pause = "", resume = "", observe = "worker_id pane_binding native_state delivery_error observation_seq",
		answer = "gate_id gate_revision choice_id answer", cancel_gate = "gate_id gate_revision", recheck_gate = "gate_id gate_revision",
		continue_controller = "expected_revision operator_verified", continue_worker = "worker_id pane_binding continuation_proof operator_verified",
		rollover = "worker_id trigger", cancel_rollover = "worker_id", reconcile_restored = "worker_id operator_verified", recheck_report = "worker_id",
		cancel_landing = "landing_id landing_revision", move_landing = "landing_id landing_revision direction",
		landing_lost = "landing_id landing_revision reason", reconcile_landing = "landing_id landing_revision outcome target_revision reason operator_verified",
		sweep = "local_date catch_up",
	}
	local sequenced = event.command ~= "claim" and event.command ~= "result" and event.command ~= "lost"
	if not specific[event.command] or not closed(event, "kind request_id orch_session_id origin controller_pane command " .. (if sequenced then "command_seq " else "") .. specific[event.command])
		or (sequenced and not pos(event.command_seq)) then
		return fail("invalid_command", "Unexpected operation-specific dispatch fields.")
	end
	local d = registry.dispatch or fresh()
	local cursor = (d.command_cursors or {})[event.orch_session_id]
	if cursor and not equal(cursor.origin, event.origin) and cursor.origin.owner_id == event.origin.owner_id
		and cursor.origin.owner_generation == event.origin.owner_generation and event.command ~= "continue_controller" then
		return fail("continuation_required", "This controller incarnation must explicitly continue before issuing intent or settling retained claims.")
	end
	local prior = d.commands[event.request_id]
	if prior and not verifiable(d, prior.event) then prior = nil end
	if prior then
		if not equal(prior.event, retained_input(d, prior.event, event)) then return fail("request_conflict", "Command ID already names different input.") end
		return registry, clone(prior.result)
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
	if type(clock) == "table" and clock.reserved_capacity and (event.command == "catalog" or event.command == "queue" or event.command == "adopt" or event.command == "reply" or event.command == "rollover" or event.command == "capacity" or event.command == "sweep") then
		return fail("capacity_reached", "New dispatch cannot consume reserved receipt/recovery capacity.")
	end
	if registry.revision == MAX or d.serial > MAX - 20 then return fail("full", "Durable dispatch counters are exhausted.") end
	if not valid_stamp(stamp(clock)) then return fail("invalid_clock", "Host audit clock is invalid.") end
	if policy(d, event.orch_session_id).paused and (event.command == "queue" or event.command == "adopt" or event.command == "reply" or event.command == "rollover") then return fail("session_paused", "Session is paused; intake and existing settlement continue.") end
	-- Read-only refusals, exact duplicates and unchanged observations answer before the full
	-- candidate clone. They read only fields no earlier step of this transition modifies
	-- (discard_settled_reads/reclaim_workers run for poll/catalog/queue/adopt only).
	if event.command == "claim" then
		local a = d.actions[event.action_id]
		if a == nil or not equal(a.request.origin_binding, event.origin) or a.request.controller_pane ~= event.controller_pane or not id(event.executor) then return fail("claim_mismatch", "Claim differs from its immutable origin/action.") end
		if policy(d, event.orch_session_id).paused and (a.request.op == "launch" or a.request.op == "adopt" or a.request.op == "mailbox_provision") then return fail("session_paused", "Pause blocks unclaimed new launch work, not existing effect settlement.") end
		if a.phase ~= "ready" then return fail("effect_already_claimed", "This effect is already claimed, settled or uncertain; inspect its retained outcome.") end
		if event.executor ~= event.origin.window_epoch then return fail("claim_mismatch", "Executor incarnation must match the frozen origin window epoch.") end
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
		if w and observation_unchanged(d, w, event, clock) then return registry, result("observation_recorded") end
	elseif event.command == "poll" then
		if poll_idle(registry, d, d.workers[event.worker_id], event, clock) then
			return registry, result("mailbox_idle", { worker_id = event.worker_id,
				message = "Nothing to read: the worker stayed idle since its last read of the next report found nothing. It is read again after its next native change, or within a quarter of the stale window." })
		end
	end
	local n = candidate(registry); d = n.dispatch
	if event.command == "poll" or event.command == "catalog" then discard_settled_reads(d, event.orch_session_id) end
	if event.command == "queue" or event.command == "adopt" then reclaim_workers(n) end
	local ordinary = event.command == "queue" or event.command == "adopt" or event.command == "catalog" or event.command == "reply" or event.command == "rollover" or event.command == "capacity" or event.command == "sweep"
	local limit = if ordinary then 3072 else 4096
	local observation_only = unretained(event)
	if (not observation_only and count(d.commands) >= limit)
		or ((event.command == "queue" or event.command == "catalog" or event.command == "poll") and count(d.actions) >= limit) then
		return fail("full", "Durable dispatch ledger is full; unresolved work and settlement reserve are retained.")
	end
	local answer
	if event.command == "continue_controller" then
		if event.expected_revision ~= registry.revision or event.operator_verified ~= true then return fail("stale_recovery", "Verify the exact owner, revision and stopped/retired old executors before continuation.") end
		-- This is a route fence, not owner replacement or effect resolution.
		local owner = n.sessions[event.orch_session_id].controller
		owner.phase = "active"; owner.owner_active = true
		d.command_cursors = d.command_cursors or {}
		d.command_cursors[event.orch_session_id] = { origin = clone(event.origin), controller_pane = event.controller_pane, seq = event.command_seq, continued_epoch = registry.execution_epoch }
		rebind_unlaunched(d, event)
		fence_unexecuted(d, event, n.revision)
		answer = result("controller_continued")
	elseif event.command == "continue_worker" then
		local w = d.workers[event.worker_id]
		if event.operator_verified ~= true or not w or not digest(event.continuation_proof) or event.continuation_proof ~= continuation_proof(registry, registry.dispatch.workers[event.worker_id])
			or w.logical_session_id ~= event.orch_session_id
			or not w.mailbox_handle or not w.pane_binding or w.stopped or w.mailbox_retired or not pane_binding(event.pane_binding, event.origin)
			or w.origin_binding.owner_id ~= event.origin.owner_id or w.origin_binding.owner_generation ~= event.origin.owner_generation then
			return fail("stale_recovery", "Worker/owner identity or retained effects changed; re-inspect this exact scoped attachment proof.")
		end
		fence_unexecuted(d, event, n.revision, w.worker_id)
		-- Uncertain reads are retained evidence, not effects: the committed attachment supersedes them.
		if pending(d, w, false, true) then return fail("settlement_pending", "Inspect and individually reconcile original effects before attaching; no old execution is replayed or forgotten.") end
		local request = common(d, event.origin, event.controller_pane, "attach_worker")
		request.target_request_id = w.launch_request_id; request.target_action_id = w.launch_action_id
		request.previous_origin_binding = clone(w.origin_binding); request.previous_pane_binding = clone(w.pane_binding)
		request.pane_binding = clone(event.pane_binding); request.attestation = "old_executors_stopped_or_retired"
		for _, key in { "worker_id", "worker_generation", "enrolment_token", "work_id" } do request[key] = w[key] end
		if not add(d, request, w.worker_id) then return fail("oversize", "Attachment request exceeds bridge bound.") end
		answer = result("attachment_queued", { action_id = request.action_id, worker_id = w.worker_id })
	elseif event.command == "policy" or event.command == "pause" or event.command == "resume" then
		local p = clone(policy(d, event.orch_session_id))
		if event.command == "policy" then
			-- Partial edits name only documented settings; the displayed policy fences stale editors.
			if not closed(event.policy, EDITABLE_POLICY_KEYS) or next(event.policy) == nil then return fail("invalid_policy", "Policy accepts only the documented session settings.") end
			if event.expected_policy ~= nil and not equal(event.expected_policy, policy(d, event.orch_session_id)) then
				return fail("policy_conflict", "Config changed since this editor was displayed. Reopen Config; the newer policy was not overwritten.")
			end
			for key, value in event.policy do p[key] = clone(value) end
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
			if not valid_policy(p) then return fail("invalid_policy", "Poll 1000..60000ms; heartbeat 5000..3600000ms; stale >= heartbeat and <=86400000ms; rollover threshold integer 1..99; quota reserve integer 0..99; evidence age 60000..900000ms; concurrency limit integer 0..32; each routing scope has at most 24 distinct explicit alternative record IDs (no wildcards); reports, rollover, coordinator rollover, quota routing, mailbox sweep and provider/account/model substitution are booleans; sweep time is local HH:MM (00:00–23:59); excluded workers are distinct.") end
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
					local removed = wake.action_id; wake.action_id = nil; d.actions[removed] = nil
					for key, command in d.commands do
						if command.event.action_id == removed or command.result.action_id == removed then d.commands[key] = nil end
					end
				end
			end
		end
		if observation.state == "exited" and observation.epoch ~= nil and not f.exit then
			f.exit = { at_ms = observation.at_ms, mono_ms = observation.mono_ms, epoch = observation.epoch, state = "exited" }
		end
		-- A stopped coordinator seen alive again is native restoration, never a healthy coordinator.
		if w.coordinator_owner_id and w.stopped and table.find({ "working", "idle", "waiting-input" }, event.native_state) then
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
		local fallback_rollover = nil
		if g.kind == "quota_fallback" then
			for _, candidate_rollover in d.rollovers or {} do
				if candidate_rollover.quota and candidate_rollover.quota.gate and candidate_rollover.quota.gate.gate_id == g.id then fallback_rollover = candidate_rollover end
			end
		end
		if fallback_rollover and event.command ~= "recheck_gate" then
			-- Rollover-time fallback (plan §7 line 321): the gate sits on the running predecessor; the
			-- one-action decision applies to this rollover's successor only and never edits Config.
			local q = fallback_rollover.quota
			local binding = q.gate
			if not gate_open(g) then return fail("stale_gate", "This fallback proposal is no longer current.") end
			if event.command == "cancel_gate" then
				g.phase = "cancelled"; g.revision += 1; settle_entries(w, "gate_id", g.id); q.gate = nil
				q.rejected = { policy_digest = binding.policy_digest, to = clone(binding.to), needs = binding.denied, gate_id = g.id }; q.approval = nil
				answer = result("gate_cancelled")
			else
				local choice = false; for _, option in g.options do if option.id == event.choice_id then choice = true end end
				if g.phase ~= "pending" or not choice or not str(event.answer, 32768) then return fail("invalid_choice", "Choose approve or reject for this exact fallback proposal.") end
				local p, now = policy(d, w.logical_session_id), stamp(clock).at_ms
				g.answer = { choice_id = event.choice_id, answer = event.answer, source = clone(event.origin), at_ms = now }
				g.phase = "resolved"; settle_entries(w, "gate_id", g.id); q.gate = nil
				if event.choice_id == "approve" then
					local e, c = current_evidence(d, w.logical_session_id), d.catalogs[w.logical_session_id]
					local row
					for _, candidate_row in (if c then c.records else {}) do if candidate_row.id == binding.to.id and candidate_row.revision == binding.to.revision then row = candidate_row end end
					local assessed = if e then quota.assess(e, binding.to.id, binding.to.revision, p, now) else nil
					if not p.quota_routing or quota.policy_digest(p) ~= binding.policy_digest or not c or c.revision ~= binding.catalog_revision or not e
						or e.revision ~= binding.evidence_revision or not row or not row.eligible or row.enabled ~= true or row.cwd ~= w.cwd or row.placement ~= w.placement
						or (fallback_rollover.kind == "coordinator" and not table.find(row.capabilities, "coordinator-control-v1")) or not assessed or assessed.status ~= "sufficient" then
						return fail("stale_gate", "Routing policy, catalog or USAGE evidence changed since this fallback was proposed, or the destination is no longer sufficient. Refresh capacity; nothing was approved.")
					end
					q.approval = { policy_digest = binding.policy_digest, to = clone(binding.to), needs = binding.denied, gate_id = g.id }; q.rejected = nil
					answer = result("fallback_approved", { handover_id = fallback_rollover.id, worker_id = w.worker_id })
				else
					q.rejected = { policy_digest = binding.policy_digest, to = clone(binding.to), needs = binding.denied, gate_id = g.id }; q.approval = nil
					answer = result("fallback_rejected", { handover_id = fallback_rollover.id, worker_id = w.worker_id })
				end
			end
		elseif g.kind == "quota_fallback" and event.command ~= "recheck_gate" then
			-- Host-consumed one-action decision: never delivered to a worker, never edits Config.
			local r = w.routing
			if not r or r.phase ~= "gated" or not r.gate or r.gate.gate_id ~= g.id or not gate_open(g) then return fail("stale_gate", "This fallback proposal is no longer current.") end
			if event.command == "cancel_gate" then
				g.phase = "cancelled"; g.revision += 1; settle_entries(w, "gate_id", g.id); r.gate = nil
				remember_decision(d, w, "held", { candidates = r.candidates, reason = { code = "fallback_cancelled", message = "Owner cancelled the fallback proposal; the work stays held. Refresh capacity or cancel the work." } },
					policy(d, w.logical_session_id), stamp(clock).at_ms)
				answer = result("gate_cancelled")
			else
				local choice = false; for _, option in g.options do if option.id == event.choice_id then choice = true end end
				if g.phase ~= "pending" or not choice or not str(event.answer, 32768) then return fail("invalid_choice", "Choose approve or reject for this exact fallback proposal.") end
				local p, now = policy(d, w.logical_session_id), stamp(clock).at_ms
				local binding = r.gate
				g.answer = { choice_id = event.choice_id, answer = event.answer, source = clone(event.origin), at_ms = now }
				g.phase = "resolved"; settle_entries(w, "gate_id", g.id); r.gate = nil
				if event.choice_id == "approve" then
					local e, c = current_evidence(d, w.logical_session_id), d.catalogs[w.logical_session_id]
					local row
					for _, candidate_row in (if c then c.records else {}) do if candidate_row.id == binding.to.id and candidate_row.revision == binding.to.revision then row = candidate_row end end
					local assessed = if e then quota.assess(e, binding.to.id, binding.to.revision, p, now) else nil
					if not p.quota_routing or quota.policy_digest(p) ~= binding.policy_digest or not c or c.revision ~= binding.catalog_revision or not e
						or e.revision ~= binding.evidence_revision or not row or not row.eligible or row.enabled ~= true or row.cwd ~= w.cwd or row.placement ~= w.placement
						or (r.coordinator and not table.find(row.capabilities, "coordinator-control-v1")) or not assessed or assessed.status ~= "sufficient" then
						return fail("stale_gate", "Routing policy, catalog or USAGE evidence changed since this fallback was proposed, or the destination is no longer sufficient. Refresh capacity; nothing was approved.")
					end
					local busy = concurrency_problem(d, w.logical_session_id, p, { [w.worker_id] = true })
					if busy then return fail(busy.code, busy.message .. " Approve again once a reservation is released; nothing was approved.") end
					w.record_id = row.id; w.record_revision = row.revision
					local action_id, err = prepare_launch(registry, n, w, r.coordinator, event.request_id, clock, reserve)
					if err then return nil, err end
					r.switched = true; r.needs = binding.denied; r.authority = "owner_gate"; r.authorized_digest = binding.policy_digest; r.selected = { id = row.id, revision = row.revision }
					remember_decision(d, w, "selected", { record = row, candidates = r.candidates, reason = { code = "owner_fallback", message = "Owner approved " .. row.id .. " for this work only (gate " .. g.id .. ")." } }, p, now)
					reserve_slot(d, w, n.revision, now)
					local _, problem = append(d, w, "routing", "Owner approved quota fallback to " .. row.id .. " for " .. w.work_id .. " only.", clock); if problem then return nil, problem end
					answer = result("fallback_approved", { worker_id = w.worker_id, action_id = action_id })
				else
					remember_decision(d, w, "held", { candidates = r.candidates, reason = { code = "fallback_rejected", message = "Owner rejected the proposed fallback; the work stays held. Refresh capacity or cancel the work." } }, p, now)
					local _, problem = append(d, w, "routing", "Owner rejected quota fallback for " .. w.work_id .. "; work held.", clock); if problem then return nil, problem end
					answer = result("fallback_rejected", { worker_id = w.worker_id })
				end
			end
		elseif event.command == "answer" then
			if g.kind == "native_input" then return fail("recheck_only", "Native input/authentication requires owner action in its exact pane, then observation-only recheck.") end
			if g.phase ~= "pending" or not id(event.choice_id) or not str(event.answer, 32768) then return fail("stale_gate", "Only an unanswered exact gate revision accepts one bounded decision.") end
			local choice = false; for _, option in g.options do if option.id == event.choice_id then choice = true end end
			if not choice then return fail("invalid_choice", "Choose an option from this exact question.") end
			g.answer = { choice_id = event.choice_id, answer = event.answer, source = clone(event.origin), at_ms = stamp(clock).at_ms }; g.phase = "answered"
			local _, err = append(d, w, "answer", event.answer, clock, { state = "pending", gate_id = g.id }); if err then return nil, err end
			answer = result("gate_answered", { gate_id = g.id })
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
		-- Owner withdrawal of work that never launched: held or gated routed work that was never
		-- provisioned, work whose provision, launch or adoption explicit continuation fenced as
		-- unexecuted, or work whose provision SPAWN definitively rejected before any effect
		-- (fenced_unlaunched). Nothing native ran; nothing is stopped, retried or re-sent.
		local w = d.workers[event.worker_id]
		if not w or w.logical_session_id ~= event.orch_session_id
			or w.origin_binding.owner_id ~= event.origin.owner_id or w.origin_binding.owner_generation ~= event.origin.owner_generation then
			return fail("worker_unbound", "Only this controller owner's never-launched work can be cancelled: held or gated routed work, work whose provision, launch or adoption continuation fenced as unexecuted, or work whose provision SPAWN rejected.")
		end
		local _, fenced = fenced_unlaunched(d, w)
		local evidence = event.query_bytes ~= nil or event.response_bytes ~= nil
		if not fenced and launch_rejected(d, w) then
			-- SPAWN definitively rejected the launch/adoption ask after provisioning: the unused mailbox is
			-- retired through the exact retirement path on this route. The worker stays visible until SPAWN
			-- confirms `retired` (then it is reclaimed like any retired generation); a refused retirement
			-- keeps its outcome and may be cancelled again, an uncertain or pending one never re-issues.
			if evidence then return fail("invalid_command", "SPAWN's retained launch rejection is terminal; withdrawal needs no status evidence.") end
			if w.mailbox_retired then return finish_command(n, event, result("worker_retired", { worker_id = w.worker_id })) end
			local prior = if w.mailbox_retire_action_id then d.actions[w.mailbox_retire_action_id] else nil
			if prior and not (prior.phase == "complete" and prior.response and prior.response.status == "rejected") then
				return fail("retirement_unresolved", "This work's mailbox retirement is " .. prior.phase .. "; inspect its exact retained outcome. No second retirement is issued.")
			end
			local owner = if w.coordinator_owner_id then n.sessions[event.orch_session_id].orchestrator else nil
			if owner and owner.owner_id == w.coordinator_owner_id and owner.generation == w.coordinator_generation and (owner.phase ~= "reserved" or owner.pending_executors ~= 0) then
				return fail("coordinator_unresolved", "This work's coordinator reservation is " .. owner.phase .. "; recover that orchestrator owner first. Nothing was cancelled.")
			end
			local request = common(d, event.origin, event.controller_pane, "mailbox_retire"); be(w, request)
			request.handle = w.mailbox_handle; request.expected_generation = w.worker_generation
			request.mode = "retire"; request.settlement_revision = n.revision; request.report_floor = w.compacted_floor
			request.report_chain_sha256 = w.compacted_chain; request.reply_floor = w.reply_floor; request.grant_id = next_id(d, "withdraw-")
			if not add(d, request, w.worker_id) then return fail("oversize", "Mailbox retirement request exceeds the bridge bound; nothing was cancelled.") end
			w.mailbox_retire_action_id = request.action_id
			w.reason = { code = "withdrawal_retiring", message = "Owner cancelled this never-launched work. Its unused mailbox is being retired; the worker is removed once SPAWN confirms retirement." }
			answer = result("withdrawal_retiring", { worker_id = w.worker_id, work_id = w.work_id, action_id = request.action_id })
		else
			if fenced then
				if status_required(fenced) or evidence then
					if not evidence then return fail("status_required", "SPAWN received this fenced " .. fenced.request.op .. " request; its retained SPAWN status must be read first. Nothing was cancelled.") end
					local problem = unexecutable_in_spawn(fenced, event); if problem then return nil, problem end
				end
				-- A fenced coordinator start releases its never-bound orchestrator reservation in this commit.
				local owner = if w.coordinator_owner_id then n.sessions[event.orch_session_id].orchestrator else nil
				if owner and owner.owner_id == w.coordinator_owner_id and owner.generation == w.coordinator_generation then
					if owner.phase ~= "reserved" or owner.pending_executors ~= 0 then
						return fail("coordinator_unresolved", "This work's coordinator reservation is " .. owner.phase .. "; recover that orchestrator owner first. Nothing was cancelled.")
					end
					owner.managed_worker_id = nil
					local released, response = reserve(n, { kind = "release_coordinator", request_id = "withdraw-release-" .. w.worker_id, orch_session_id = w.logical_session_id,
						expected_owner_id = w.coordinator_owner_id, expected_generation = w.coordinator_generation, quiescent = true }, clock)
					if not released then return nil, response end
					n = released; d = n.dispatch
				end
				for key, a in d.actions do if a.worker_id == w.worker_id then d.actions[key] = nil end end
			else
				if not w.routing or w.routing.bound or w.routing.phase == "selected" or evidence then
					return fail("worker_unbound", "Only held or gated routed work that was never provisioned, or work whose provision, launch or adoption continuation fenced as unexecuted, can be cancelled.")
				end
				for _, a in d.actions do if a.worker_id == w.worker_id then return fail("settlement_pending", "This work has retained effects; it cannot be cancelled here.") end end
			end
			for key, g in d.gates or {} do if g.worker_id == w.worker_id then d.gates[key] = nil end end
			for _, p in d.policies or {} do
				for i = #p.excluded_workers, 1, -1 do if p.excluded_workers[i] == w.worker_id then table.remove(p.excluded_workers, i) end end
			end
			d.workers[w.worker_id] = nil
			answer = result("work_cancelled", { worker_id = event.worker_id, work_id = w.work_id })
		end
	elseif event.command == "catalog" then
		local request = common(d, event.origin, event.controller_pane, "catalog")
		if event.bytes ~= nil then request.cursor = event.bytes end
		local a = add(d, request); if not a then return fail("oversize", "Catalog request exceeds bridge bound.") end
		answer = result("catalog_queued", { action_id = request.action_id })
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
		if event.coordinator and not table.find(selected.capabilities, "coordinator-control-v1") then
			return fail("unsupported_capability", "Coordinator start requires explicitly configured coordinator-control-v1. Existing records remain available for ordinary work; do not infer helper support.")
		end
		if event.cwd ~= selected.cwd or event.placement ~= selected.placement then return fail("config_changed", "Task cwd/placement must match the selected configured record; refresh its catalog.") end
		if count(d.workers) >= 32 then return fail("full", "Managed generation capacity is full; no unresolved worker was removed.") end
		local worker_id, work_id = next_id(d, "worker-"), next_id(d, "work-")
		local w: any = { worker_id = worker_id, work_id = work_id, worker_generation = 1, logical_session_id = event.orch_session_id,
			origin_binding = clone(event.origin), controller_pane = event.controller_pane, record_id = event.record_id, record_revision = event.record_revision,
			prompt = event.prompt, cwd = event.cwd, placement = event.placement, assignment_sha256 = codec.sha256(event.prompt),
			launch_request_id = next_id(d, "launch-"), launch_action_id = next_id(d, "action-"),
			enrolment_token = codec.sha256(event.request_id .. ":" .. event.origin.alias_nonce .. ":" .. work_id), phase = "queued",
			accepted_seq = 0, compacted_floor = 0, receipts = {}, replies = {}, reply_seq = 0, reply_floor = 0 }
		if #tern.json.encode(launch_request(w, string.rep("h", 96))) > 8192 then
			return fail("oversize", "Assignment plus immutable launch binding cannot fit the 8192-byte bridge (including a maximum-length mailbox handle); no provisioning was queued.")
		end
		local p = policy(d, event.orch_session_id)
		if p.quota_routing then
			-- Quota routing (plan §7): the owner-selected record first, then Config's explicit allowlist.
			if event.coordinator then
				for _, other in d.workers do
					if other.logical_session_id == event.orch_session_id and other.routing and other.routing.coordinator and not other.routing.bound then
						return fail("coordinator_pending", "A coordinator start for this session is already awaiting capacity or an owner decision; resolve or cancel it first.")
					end
				end
			end
			w.routing = { mode = "quota", phase = "held", scope = "initial_dispatch", requested = { id = event.record_id, revision = event.record_revision }, coordinator = event.coordinator,
				policy_digest = quota.policy_digest(p), decided_at_ms = 0, decision_digest = string.rep("0", 64), switched = false, bound = false, candidates = {}, history = {} }
			d.workers[worker_id] = w
			local _, problem = append(d, w, "assignment", w.prompt, clock); if problem then return nil, problem end
			local action_id, err = route(registry, n, w, clock, reserve, event.request_id, true)
			if err then return nil, err end
			local r = w.routing
			answer = result(if r.phase == "selected" then "task_queued" elseif r.phase == "gated" then "task_gated" else "task_held",
				{ worker_id = worker_id, work_id = work_id, action_id = action_id, message = if r.reason then r.reason.message else nil })
		else
			if event.coordinator then
				local reserved, response = reserve(registry, { kind = "reserve_coordinator", request_id = event.request_id .. "-reserve", orch_session_id = event.orch_session_id, work_id = work_id }, clock)
				if reserved == nil then return nil, response end
				n.sessions = clone(reserved.sessions); n.request_outcomes = reserved.request_outcomes; n.next_owner_id = reserved.next_owner_id
				w.coordinator_owner_id = response.owner_id; w.coordinator_generation = response.generation
				w.coordinator_protocol = 1 -- Absent on old CP2 workers: never silently activate them.
				n.sessions[event.orch_session_id].orchestrator.managed_worker_id = worker_id
			end
			if #tern.json.encode(launch_request(w, string.rep("h", 96))) > 8192 then
				return fail("oversize", "Assignment and reserved coordinator identity exceed the immutable launch bridge bound; no reservation or provision was committed.")
			end
			local request = common(d, event.origin, event.controller_pane, "mailbox_provision"); be(w, request)
			request.record_id = w.record_id; request.record_revision = w.record_revision; request.capability = "report-files-v1"
			-- Frozen enrolment is provisioned before any launch grant exists.
			if not add(d, request, worker_id) then return fail("oversize", "Provision request exceeds the bridge bound.") end
			d.workers[worker_id] = w; answer = result("task_queued", { worker_id = worker_id, work_id = work_id, action_id = request.action_id })
			local _, problem = append(d, w, "assignment", w.prompt, clock); if problem then return nil, problem end
		end
	elseif event.command == "adopt" then
		-- Explicit verified attach of an owner-attested hand-opened native agent pane. Never automatic.
		if not str(event.record_id, 96) or not str(event.prompt, 32768) or event.prompt:find("%S") == nil or event.attestation ~= ADOPT_ATTESTATION
			or not pane_binding(event.pane_binding, event.origin) then
			return fail("invalid_task", "Attach needs a configured record, a nonblank task and the owner-attested exact agent pane of this controller's window, native session and host.")
		end
		local c = d.catalogs[event.orch_session_id]; local selected
		if c == nil or c.revision ~= event.catalog_revision then return fail("catalog_changed", "Refresh and select the current catalog revision.") end
		for _, row in c.records do if row.id == event.record_id and row.revision == event.record_revision then selected = row end end
		if not selected or not selected.eligible or selected.enabled ~= true or selected.backend ~= "native-agent" or not table.find(selected.capabilities, "report-files-v1") then
			return fail("unsupported_capability", "Attach requires an eligible, enabled native-agent record with report-files-v1; terminal or shell panes are never typed into.")
		end
		for _, other in d.workers do
			local unbound = other.stopped ~= nil or (other.phase == "held" and other.pane_binding == nil)
			if other.logical_session_id == event.orch_session_id and not unbound and (equal(other.pane_binding, event.pane_binding)
				or equal(other.control_pane_binding, event.pane_binding) or equal(other.adopt_pane_binding, event.pane_binding)) then
				return fail("pane_bound", "This exact pane is already bound to managed worker " .. other.worker_id .. "; it is never adopted twice.")
			end
		end
		if count(d.workers) >= 32 then return fail("full", "Managed generation capacity is full; no unresolved worker was removed.") end
		local worker_id, work_id = next_id(d, "worker-"), next_id(d, "work-")
		local w: any = { worker_id = worker_id, work_id = work_id, worker_generation = 1, logical_session_id = event.orch_session_id,
			origin_binding = clone(event.origin), controller_pane = event.controller_pane, record_id = event.record_id, record_revision = event.record_revision,
			prompt = event.prompt, cwd = selected.cwd, placement = selected.placement, assignment_sha256 = codec.sha256(event.prompt),
			launch_request_id = next_id(d, "launch-"), launch_action_id = next_id(d, "action-"),
			enrolment_token = codec.sha256(event.request_id .. ":" .. event.origin.alias_nonce .. ":" .. work_id), phase = "queued",
			accepted_seq = 0, compacted_floor = 0, receipts = {}, replies = {}, reply_seq = 0, reply_floor = 0,
			adopt_pane_binding = clone(event.pane_binding) }
		if #tern.json.encode(launch_request(w, string.rep("h", 96))) > 8192 then
			return fail("oversize", "Assignment plus immutable adoption binding cannot fit the 8192-byte bridge; nothing was provisioned.")
		end
		local request = common(d, event.origin, event.controller_pane, "mailbox_provision"); be(w, request)
		request.record_id = w.record_id; request.record_revision = w.record_revision; request.capability = "report-files-v1"
		if not add(d, request, worker_id) then return fail("oversize", "Provision request exceeds the bridge bound.") end
		d.workers[worker_id] = w
		answer = result("adoption_queued", { worker_id = worker_id, work_id = work_id, action_id = request.action_id })
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
		if a.request.op == "stop" and target and not settled(target) then return fail("settlement_pending", "Exact receipt and reply settlement is required before stopping this generation.") end
		if target and target.coordinator_owner_id and restored_coordinator(d, event.orch_session_id) then
			return fail("coordinator_restored", "A retired coordinator pane was observed alive again; coordinator effects are held until it is reconciled.")
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
		a.phase = "claimed"; a.claim = { executor = event.executor, epoch = registry.execution_epoch, grant_id = next_id(d, "grant-"), capacity = capacity_claim }
		n.sessions[event.orch_session_id].controller.pending_executors += 1
		local w = if a.worker_id then d.workers[a.worker_id] else nil
		if w and w.coordinator_owner_id then
			local owner = n.sessions[event.orch_session_id].orchestrator
			if owner == nil or owner.owner_id ~= w.coordinator_owner_id or owner.generation ~= w.coordinator_generation
				or (owner.phase ~= "reserved" and owner.phase ~= "running" and owner.phase ~= "retiring"
					and not (owner.phase == "uncertain" and a.request.op == "attach_worker")) then return fail("owner_mismatch", "Coordinator reservation is no longer executable.") end
			if owner.phase == "retiring" and not table.find({ "accept", "mailbox_read", "mailbox_publish_ack", "mailbox_publish_reply", "mailbox_retire", "stop", "native_wake", "attach_worker" }, a.request.op) then
				return fail("coordinator_retiring", "Retirement permits settlement only, never fresh launch effects.")
			end
			if a.request.op == "stop" and (not settled(w) or owner.pending_executors ~= 0 or M.unresolved(registry, w.logical_session_id, owner.owner_id)) then
				return fail("settlement_pending", "Final watermark, replies and unresolved executors must settle before native stop.")
			end
			owner.pending_executors += 1
		end
		answer = result("effect_granted", { action_id = event.action_id, claim = a.claim })
	elseif event.command == "result" or event.command == "lost" then
		local a = d.actions[event.action_id] -- Stale grants and exact duplicates answered before the candidate clone.
		if event.command == "lost" then a.phase = "uncertain"; answer = result("effect_uncertain")
		else
			local body, err = M.decode_response(event.response_bytes, a.request); if err then return nil, err end
			local applied, problem = complete(n, a, body, clock); if problem then return nil, problem end
			a.response_bytes = event.response_bytes; a.response = body; a.response_grant = a.claim.grant_id; answer = applied
			if a.phase == "complete" or a.phase == "backpressure" then
				local controller = n.sessions[event.orch_session_id].controller; controller.pending_executors = math.max(0, controller.pending_executors - 1)
				local w = if a.worker_id then d.workers[a.worker_id] else nil
				local owner = n.sessions[event.orch_session_id].orchestrator
				if w and owner and owner.owner_id == w.coordinator_owner_id then owner.pending_executors = math.max(0, owner.pending_executors - 1) end
				if w and w.mailbox_retired and owner and owner.owner_id == w.coordinator_owner_id then
					owner.owner_active = false
					-- A withdrawn never-launched coordinator start was never bound: its retired mailbox ends the reservation.
					if launch_rejected(d, w) and owner.phase == "reserved" and owner.managed_worker_id == w.worker_id then owner.managed_worker_id = nil end
					local released, response = reserve(n, { kind = "release_coordinator", request_id = "normal-release-" .. w.worker_id,
						orch_session_id = w.logical_session_id, expected_owner_id = w.coordinator_owner_id, expected_generation = w.coordinator_generation, quiescent = true }, clock)
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
		local query = if str(event.query_bytes, 4096) then codec.strict_decode(event.query_bytes, 4096) else nil
		if not closed(query, "schema origin op request_id action_id origin_binding controller_pane controller_generation target_request_id")
			or query.schema ~= 1 or query.origin ~= "orchplus" or query.op ~= "status" or not id(query.request_id) or not id(query.action_id)
			or query.target_request_id ~= a.request.request_id or query.controller_generation ~= a.request.controller_generation
			or not equal(query.origin_binding, a.request.origin_binding) then
			return fail("binding_mismatch", "SPAWN status evidence must name this exact retained read.")
		end
		local body, err = M.decode_response(event.response_bytes, query); if err then return nil, err end
		if body.status ~= "missing" then return fail("status_not_missing", "SPAWN's status does not report this read missing; only its retained outcome or attachment settles it.") end
		resolve_read(n, a, "read_lost_no_effect", "SPAWN has no record of this read (never staged, refused before staging, or compacted); nothing it read was applied, so the worker re-reads from its durable cursor.",
			codec.sha256(event.response_bytes))
		answer = result("read_resolved", { action_id = event.action_id, worker_id = a.worker_id })
	elseif event.command == "retry" then
		local a = d.actions[event.action_id]
		if not a or a.phase ~= "backpressure" or not equal(a.request.origin_binding, event.origin)
			or a.request.controller_pane ~= event.controller_pane or not a.response or a.response.status ~= "full"
			or not retryable_full(a.response.payload) then
			return fail("retry_refused", "Only the exact retained, definitively unexecuted full outcome may be rechecked. Uncertain effects cannot retry.")
		end
		a.phase = "ready"; a.claim = nil; a.response_grant = nil; a.retry_count = (a.retry_count or 0) + 1
		-- Keep the full response as evidence, but require a fresh status fence after resubmission.
		answer = result("retry_queued", { action_id = event.action_id })
	elseif event.command == "readback_publication" then
		-- Plan §mailbox: an uncertain publication "requires readback before retry". ACK and reply
		-- objects are immutable, deterministic bytes, so the retained attempt is resolved and the
		-- outbox re-issues the exact same bytes on the current route. SPAWN's journal still holds the
		-- uncertain write: it reads back first and republishes those bytes only if absent; equal bytes
		-- are idempotent and a late earlier child can only publish the same bytes. Native effects
		-- (launch, ask, wake, stop) never take this path.
		local a = d.actions[event.action_id]
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
		a.phase = "resolved"
		a.resolution = { revision = n.revision, executor = a.claim.executor, evidence = "publication_readback",
			reason = "Uncertain immutable publication superseded by readback: the outbox re-issues the exact same bytes; SPAWN reads them back and republishes only if absent." }
		local controller = n.sessions[event.orch_session_id].controller; controller.pending_executors = math.max(0, controller.pending_executors - 1)
		local owner = n.sessions[event.orch_session_id].orchestrator
		if owner and owner.owner_id == w.coordinator_owner_id then owner.pending_executors = math.max(0, owner.pending_executors - 1) end
		if w.reason and (w.reason.code == "effect_uncertain" or w.reason.code == "target_unavailable") then w.reason = nil end
		answer = result("readback_queued", { action_id = event.action_id, worker_id = w.worker_id })
	elseif event.command == "poll" then
		local w = d.workers[event.worker_id]
		if w == nil or not equal(control_origin(w), event.origin) or not w.mailbox_handle or not w.pane_binding or w.continuation_required then return fail("worker_unbound", "Worker requires its explicitly continued current mailbox/native route.") end
		if w.coordinator_owner_id and not coordinator(n, w) then return fail("owner_mismatch", "Only the current coordinator generation may settle; restored owners require inspected recovery.") end
		resume_revoked(d, w)
		if w.mailbox_retired then
			if not w.coordinator_owner_id then return finish_command(n, event, result("worker_retired", { worker_id = w.worker_id })) end
			local owner = coordinator(n, w)
			if not owner or pending(d, w) then return fail("settlement_pending", "Retired mailbox still has unresolved authority effects.") end
			owner.owner_active = false
			local released, response = reserve(n, { kind = "release_coordinator", request_id = "normal-release-" .. w.worker_id,
				orch_session_id = w.logical_session_id, expected_owner_id = w.coordinator_owner_id, expected_generation = w.coordinator_generation, quiescent = true }, clock)
			if not released then return nil, response end
			n = released; d = n.dispatch
			answer = result("coordinator_retired", { worker_id = w.worker_id })
			advance_rollovers(n, event, clock, reserve); advance_landing(n, event, clock)
			sync_reservations(n, clock)
			remember(n.dispatch, event, answer, n.revision)
			return n, answer
		end
		if pending(d, w, event.bytes == "watermark") then return fail("operation_pending", "A retained operation owns this generation; recheck unexecuted backpressure or reconcile uncertain effects first.") end
		local request
		if event.bytes == "watermark" then request = worker_request(d, w, "mailbox_read"); request.selector = { stream = "watermark" } end
		for _, receipt in w.receipts do
			if not request and receipt.publish and count(w.wakes or {}) < 32 then
				request = worker_request(d, w, "mailbox_publish_ack")
				local committed_ack = codec.strict_decode(receipt.bytes, 2048)
				request.receipt_revision = committed_ack.committed_revision
				request.ack_b64 = tern.base64.encode(receipt.bytes); request.ack_sha256 = codec.sha256(receipt.bytes); break
			end
		end
		if not request and w.accept_pending then
			request = common(d, control_origin(w), control_pane(w), "accept")
			request.target_request_id = w.launch_request_id; request.target_action_id = w.launch_action_id; request.pane_binding = clone(control_binding(w))
			for _, key in { "worker_id", "worker_generation", "enrolment_token", "work_id" } do request[key] = w[key] end
			for k, v in w.accepted_event do request[k] = v end
			-- Rollover successors must present the matching handover pair; initial dispatch has none.
			request.handover_id = w.handover_id; request.handover_token = w.handover_token
		end
		if not request and settled(w) then
			local owner = coordinator(n, w)
			if w.coordinator_owner_id and (not owner or owner.pending_executors ~= 0 or M.unresolved(n, w.logical_session_id, owner.owner_id)) then return fail("settlement_pending", "Coordinator executors remain unresolved.") end
			if not w.stopped then
				if w.stop_action_id then return fail("stop_unresolved", "Inspect the retained native stop outcome; no second stop is issued.") end
				request = common(d, control_origin(w), control_pane(w), "stop")
				request.target_request_id = w.launch_request_id; request.target_action_id = w.launch_action_id; request.pane_binding = clone(control_binding(w))
				for _, key in { "worker_id", "worker_generation", "enrolment_token", "work_id" } do request[key] = w[key] end
				w.stop_action_id = request.action_id
			else
				if retirement_refused(d, w) then
					return fail("retirement_refused", "SPAWN refused this stopped generation's retirement before any effect (producer journal unsettled); the mailbox stays provisioned. The nightly sweep or Retry mailbox retirement once… re-arms one attempt.")
				end
				if w.mailbox_retire_action_id then return fail("retirement_unresolved", "Inspect the retained mailbox retirement; no replacement grant is issued.") end
				request = retire_request(n, d, w)
			end
		end
		if not request and w.compaction_pending then
			request = compact_request(d, w)
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
				if not reply.acknowledged and reply.part <= #reply.frames.chunks + 1 and count(w.wakes or {}) < 32 then
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
			if w.rejected_report and event.bytes ~= "watermark" then
				return fail("report_held", "The completed report was rejected and retained unchanged; inspect its diagnostic. No report is skipped or acknowledged.")
			end
			request = worker_request(d, w, "mailbox_read")
			if event.bytes == "watermark" then request.selector = { stream = "watermark" }
			else request.selector = w.read_selector or { stream = "report", slot = w.accepted_seq + 1, part = "manifest" } end
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
			w.mailbox_retire_action_id = nil
			answer = result("retirement_rearmed", { worker_id = w.worker_id })
		elseif w.finish then return finish_command(n, event, result("finish_already_requested", { worker_id = w.worker_id }))
		else
			if pending(d, w) or w.accept_pending or w.assembly or w.rejected_report or next(w.replies) or next(w.wakes or {}) or flow(w).report_request or work_referenced(d, w) then
				return fail("workflow_unsettled", "Finish cannot discard unresolved effects, decisions, deliveries, rejected reports or referenced review/rollover/landing evidence.")
			end
			w.finish = { request_id = event.request_id, seq = w.accepted_seq, revision = n.revision, source = clone(event.origin) }
			for _, entry in flow(w).thread do entry.state = "settled" end
			answer = result("finish_requested", { worker_id = w.worker_id })
		end
	elseif event.command == "retire" then
		local w = d.workers[event.worker_id]
		local owner = if w then coordinator(n, w) else nil
		if not w or not equal(control_origin(w), event.origin) or not owner or not w.activation then
			return fail("activation_required", "Graceful retirement requires the current managed coordinator's issued activation. Old CP2 owners remain occupied for inspected recovery.")
		end
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
		if w.coordinator_owner_id and (not coordinator(n, w) or w.release or w.retirement) then return fail("coordinator_retiring", "No fresh progress requests may be granted to a retiring or stale coordinator.") end
		local f = flow(w)
		if f.report_request then return finish_command(n, event, result("report_request_pending", { request_id = f.report_request.request_id, message_id = f.report_request.message_id })) end
		if not sendable(d, w, clock) then
			return fail("worker_not_sendable", "Observe safely: working, waiting-input, exited or unconfirmed native workers are never interrupted.")
		end
		local request_id = next_id(d, "report-request-")
		local delivery, err = issue_reply(d, w, "report_request", { request_id = request_id, requested_kind = "HEARTBEAT", reason = "Owner/session policy requested a structured progress report; echo request_id in HEARTBEAT or CHECKPOINT." })
		if err then return nil, err end
		delivery.request_id = request_id; delivery.published = false; delivery.response_received = false; f.report_request = delivery
		local _, problem = append(d, w, "report_request", "Requested structured progress; delivery ACK is not a progress response.", clock, { state = "pending", request_id = request_id, action_id = delivery.action_id })
		if problem then return nil, problem end
		answer = result("reply_committed", { message_id = delivery.message_id, request_id = request_id })
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
			-- Owner-only re-request of a blocked checkpoint; no effect has started beyond the old request.
			r.request_id = nil; r.checkpoint = nil; r.verification = nil; rollover_edge(r, "requested", n.revision, clock)
			answer = result("checkpoint_rerequested", { handover_id = r.id, worker_id = w.worker_id })
		else
			local landing = landing_open(d, w.worker_id, true)
			if landing then
				return fail("landing_in_progress", "This worker holds landing grant " .. landing.id .. "; its exact LANDING_RESULT or owner reconciliation must settle before rollover.")
			end
			refresh(d, w, clock)
			if event.trigger == "policy" then
				local due, why = rollover_due(n, w, flow(w))
				if not due then return fail("rollover_not_due", why) end
			end
			d.rollovers = d.rollovers or {}
			if count(d.rollovers) >= 32 then
				local terminal = {}
				for key, old in d.rollovers do if ROLLOVER_TERMINAL[old.phase] then table.insert(terminal, { key = key, revision = old.history[#old.history].revision }) end end
				table.sort(terminal, function(a, b) return a.revision < b.revision or (a.revision == b.revision and a.key < b.key) end)
				for i = 1, math.min(#terminal, count(d.rollovers) - 31) do d.rollovers[terminal[i].key] = nil end
			end
			if count(d.rollovers) >= 32 then return fail("full", "Rollover capacity is full of unfinished handovers; none was discarded.") end
			local handover_id = next_id(d, "handover-")
			local f = flow(w)
			d.rollovers[handover_id] = { id = handover_id, kind = if w.coordinator_owner_id then "coordinator" else "worker", phase = "requested", trigger = event.trigger, logical_session_id = w.logical_session_id,
				work_id = w.work_id, predecessor_worker_id = w.worker_id, predecessor_pane_binding = clone(control_binding(w)),
				origin = clone(event.origin), controller_pane = event.controller_pane, controller_generation = event.origin.owner_generation,
				handover_token = codec.sha256(event.request_id .. ":" .. event.origin.alias_nonce .. ":" .. handover_id),
				history = { { phase = "requested", revision = n.revision, at_ms = stamp(clock).at_ms } }, context = clone(f.context),
				predecessor_owner_id = w.coordinator_owner_id, predecessor_generation = w.coordinator_generation }
			answer = result("rollover_requested", { handover_id = handover_id, worker_id = w.worker_id })
		end
	elseif event.command == "cancel_rollover" then
		local w = d.workers[event.worker_id]
		if not w or not equal(control_origin(w), event.origin) then return fail("worker_unbound", "Cancellation requires this worker's exact control binding.") end
		local r = active_rollover(d, w)
		if not r or r.predecessor_worker_id ~= w.worker_id then return finish_command(n, event, result("no_progress")) end
		if not rollover_cancellable(d, r) then
			return fail("rollover_effect_started", "A successor pane exists or its launch is unresolved; cancellation cannot undo it. Reconcile the exact retained effect; the predecessor keeps running.")
		end
		if r.quota then close_rollover_gate(d, r, w); r.quota = nil end
		local evidence = r.hold
		rollover_edge(r, "cancelled", n.revision, clock); r.hold = evidence -- Retain the blocking evidence with the terminal phase.
		answer = result("rollover_cancelled", { handover_id = r.id, worker_id = w.worker_id })
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
			if not LANDING_UNGRANTED[item.status] then
				return fail("landing_not_cancellable", "Only ungranted items can be cancelled. A granted landing settles only by its exact LANDING_RESULT or owner reconciliation.")
			end
			landing_unqueue(q, item.id); landing_withdraw_gate(d, item, "cancelled")
			landing_status(item, "cancelled", landing_hold("owner_cancelled", "The owner cancelled this ungranted landing request; nothing was granted."), n.revision, clock)
			landing_settle(d, item)
			answer = result("landing_cancelled", { landing_id = item.id })
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
				or (event.target_revision ~= nil and not landing_text(event.target_revision)) then
				return fail("reconciliation_required", "Reconcile only an uncertain granted landing: state the observed outcome (landed with the resulting target head, or not landed), a reason, and confirm the read-only target inspection.")
			end
			grant.reconciliation = { outcome = event.outcome, target_revision = event.target_revision, reason = event.reason,
				source = clone(event.origin), at_ms = stamp(clock).at_ms, revision = n.revision }
			q.slot = nil
			if event.outcome == "landed" then
				q.head = { revision = event.target_revision, source = "owner", landing_id = item.id }
				landing_unqueue(q, item.id)
				landing_status(item, "landed", landing_hold("owner_reconciled", "Owner reconciled the observed target: landed at " .. event.target_revision .. "."), n.revision, clock)
				landing_settle(d, item)
			else
				if event.target_revision ~= nil then q.head = { revision = event.target_revision, source = "owner", landing_id = item.id } end
				item.refresh_required = true; item.approval = nil
				landing_status(item, "blocked", landing_hold("refresh_required", "Owner reconciled the observed target: not landed. The worker must publish a fresh LANDING_REQUEST before another grant; nothing is retried."), n.revision, clock)
			end
			answer = result("landing_reconciled", { landing_id = item.id, outcome = event.outcome })
		end
	else return fail("invalid_command", "Unknown dispatch command.") end
	advance_rollovers(n, event, clock, reserve)
	advance_landing(n, event, clock)
	for _, w in n.dispatch.workers do if w.logical_session_id == event.orch_session_id then refresh(n.dispatch, w, clock) end end
	-- Concurrency ledger phases follow the committed worker/action evidence of this transition.
	sync_reservations(n, clock)
	remember(n.dispatch, event, answer, n.revision)
	return n, answer
end
function M.reconcile(registry: any, event: any): (any?, any)
	if not closed(event, "kind request_id orch_session_id action_id expected_revision executor operator_verified reason")
		or event.kind ~= "dispatch_reconcile" or not id(event.request_id) or not id(event.action_id) or not id(event.executor)
		or event.operator_verified ~= true or not str(event.reason, 512) then return fail("stale_recovery", "Confirm this exact displayed action and revision after independently stopping its executor.") end
	local d = registry.dispatch
	local prior = if d then d.commands[event.request_id] else nil
	if prior then
		if not equal(prior.event, event) then return fail("request_conflict", "This reconciliation request ID already names different committed input.") end
		local replay = clone(prior.result); replay.replayed = true
		return registry, replay
	end
	if event.expected_revision ~= registry.revision then return fail("stale_recovery", "Authority changed; inspect and confirm this exact executor again.") end
	if registry.revision == MAX or (d and count(d.commands) >= 4096) then return fail("full", "Reconciliation outcome capacity is full; no fencing evidence was discarded.") end
	local a = if d then d.actions[event.action_id] else nil
	local session = registry.sessions[event.orch_session_id]
	local owner = if session then session.controller else nil
	if not a or a.phase ~= "uncertain" or not a.claim or a.claim.executor ~= event.executor or a.request.origin_binding.logical_session_id ~= event.orch_session_id
		or not owner or owner.owner_id ~= a.request.origin_binding.owner_id or owner.pending_executor_evidence ~= "unconfirmed"
		or owner.owner_active ~= nil or not owner.last_observation or owner.last_observation.status ~= "unavailable" then
		return fail("executor_verification_required", "Only an uncertain retained claim with unavailable owner evidence can be explicitly reconciled. A known live executor cannot be overridden.")
	end
	local n = candidate(registry); local changed = n.dispatch.actions[event.action_id]
	changed.phase = "resolved"; changed.resolution = { revision = n.revision, executor = event.executor, evidence = "operator_attested", reason = event.reason }
	n.sessions[event.orch_session_id].controller.pending_executors = math.max(0, owner.pending_executors - 1)
	local w = if a.worker_id then n.dispatch.workers[a.worker_id] else nil
	local coordinator = n.sessions[event.orch_session_id].orchestrator
	if w then
		w.phase = "held"; w.reason = { code = "executor_resolved", message = "Operator stopped/reconciled the retained executor; this does not retry or retire its worker." }
		if coordinator and coordinator.owner_id == w.coordinator_owner_id then coordinator.pending_executors = math.max(0, coordinator.pending_executors - 1) end
	end
	sync_reservations(n, nil)
	local answer = result("executor_reconciled", { action_id = event.action_id, committed_revision = n.revision })
	n.dispatch.commands[event.request_id] = { event = clone(event), result = clone(answer) }
	return n, answer
end
function M.project(registry: any, session_id: string, origin_nonce: string, current_action_id: string?, retained_action_ids: any?): any
	local d = registry.dispatch or fresh(); local actions, workers = {}, {}
	for key, a in d.actions do
		if a.request.origin_binding.logical_session_id == session_id and (a.phase == "claimed" or a.phase == "uncertain" or a.phase == "backpressure"
			or (a.phase == "ready" and a.request.origin_binding.alias_nonce == origin_nonce) or key == current_action_id
			or (type(retained_action_ids) == "table" and retained_action_ids[key] ~= nil)) then
			local wake_status = if a.response and type(a.response.payload) == "table" then a.response.payload.wake_status else nil
			local route = execution_origin(d, a)
			local cursor = (d.command_cursors or {})[session_id]
			actions[key] = { request = clone(a.request), request_bytes = a.request_bytes, phase = a.phase, claim = public_claim(a.claim), worker_id = a.worker_id,
				retry_count = a.retry_count, wake_status = wake_status, wake_pending = a.phase == "claimed" and wake_status ~= nil,
				execution_origin = clone(route), execution_controller_pane = if cursor and cursor.continued_epoch and equal(cursor.origin, route) then cursor.controller_pane else a.request.controller_pane,
				reconciliation_only = not equal(route, a.request.origin_binding) or (a.claim ~= nil and a.claim.epoch ~= registry.execution_epoch) }
		end
	end
	for key, w in d.workers do if w.logical_session_id == session_id then workers[key] = { worker_id = key, work_id = w.work_id, phase = w.phase, record_id = w.record_id,
		accepted_seq = w.accepted_seq, compacted_floor = w.compacted_floor, reason = clone(w.reason),
		rejected_report = if w.rejected_report then { code = w.rejected_report.code, message = w.rejected_report.message } else nil,
		pane_binding = clone(control_binding(w)), reply_floor = w.reply_floor,
		coordinator_owner_id = w.coordinator_owner_id, coordinator_generation = w.coordinator_generation,
		activation_received = w.activation ~= nil and w.activation.acknowledged, activation_issued = w.activation ~= nil,
		retirement_requested = w.retirement ~= nil, finish_requested = w.finish ~= nil, release_seq = if w.release then w.release.seq else nil,
		stop_status = if w.stopped then w.stopped.observation elseif w.stop_action_id then d.actions[w.stop_action_id].phase else "not_requested",
		mailbox_status = if w.mailbox_retired then "retired" elseif retirement_refused(d, w) then "refused"
			elseif w.mailbox_retire_action_id then d.actions[w.mailbox_retire_action_id].phase else "not_requested",
		reply_seq = w.reply_seq, owner_released = w.coordinator_owner_id ~= nil and registry.retired[w.coordinator_owner_id] ~= nil,
		effective_identity = clone(w.effective_identity), capabilities = clone(w.capabilities), handover_id = w.handover_id, routing = clone(w.routing),
		continuation_required = w.continuation_required == true, adopt_pane_binding = clone(w.adopt_pane_binding), withdrawal = withdrawal_view(d, w) } end end
	-- Stored USAGE evidence is projected only while it matches the current catalog join.
	local workflow = { policy = clone(policy(d, session_id)), workers = {}, threads = {}, gates = {}, rollovers = {}, landing = {},
		capacity = clone(current_evidence(d, session_id)), sweep = clone((d.sweeps or {})[session_id]) }
	-- Landing queues: open items in FIFO order, then the four most recent terminal items.
	local L = d.landing or { queues = {}, items = {} }
	for key, q in L.queues do
		if q.logical_session_id == session_id then
			local function view(item: any, position: number?): any
				local grant = item.grants[#item.grants]
				local current = landing_current(item)
				local before = if position and position > 1 then L.items[q.order[position - 1]] else nil
				local after = if position then L.items[q.order[position + 1]] else nil
				return { id = item.id, revision = item.revision, status = item.status, position = position, work_id = item.work_id, worker_id = item.worker_id,
					request = clone(item.request), gate_id = item.gate_id, approved = item.approval ~= nil, verification = clone(item.verification),
					hold = clone(item.hold), refresh_required = item.refresh_required == true, attempts = #item.grants,
					grant = if grant then { grant_id = grant.grant_id, target_revision = grant.target_revision, published = grant.published,
						acknowledged = grant.acknowledged, result = clone(grant.result), late_result = clone(grant.late_result),
						uncertain = clone(grant.uncertain), reconciliation = clone(grant.reconciliation), current = grant == current } else nil,
					uncertain = current ~= nil and current.uncertain ~= nil,
					cancellable = LANDING_UNGRANTED[item.status] == true,
					move_up = LANDING_UNGRANTED[item.status] == true and before ~= nil and LANDING_UNGRANTED[before.status] == true,
					move_down = LANDING_UNGRANTED[item.status] == true and after ~= nil and LANDING_UNGRANTED[after.status] == true,
					markable_lost = current ~= nil and current.uncertain == nil, reconcilable = current ~= nil and current.uncertain ~= nil }
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
				head = clone(q.head), slot = q.slot, items = items })
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
				controller_generation = r.controller_generation, hold = clone(r.hold), history = clone(r.history), verification = clone(r.verification),
				stop_observation = r.stop_observation, context = clone(r.context),
				checkpoint = if cp then { checkpoint_id = cp.payload.checkpoint_id, artifact_revision = cp.payload.artifact_revision, task_ref = cp.payload.task_ref,
					completed = clone(cp.payload.completed), remaining = clone(cp.payload.remaining), holds = clone(cp.payload.holds), checks = clone(cp.payload.checks) } else nil,
				cancellable = not ROLLOVER_TERMINAL[r.phase] and rollover_cancellable(d, r), rerequestable = not ROLLOVER_TERMINAL[r.phase] and rollover_rerequestable(d, r) })
			local revision = r.history[#r.history].revision
			for _, worker_id in { r.predecessor_worker_id, r.successor_worker_id } do
				local prior = latest_rollover[worker_id]
				-- An unfinished rollover always outranks history for the worker's surface.
				local rank = if ROLLOVER_TERMINAL[r.phase] then 0 else 1
				if worker_id and (not prior or rank > prior.rank or (rank == prior.rank and revision > prior.revision)) then
					latest_rollover[worker_id] = { rank = rank, revision = revision, id = key, phase = r.phase,
						role = if worker_id == r.predecessor_worker_id then "predecessor" else "successor", hold_code = if r.hold then r.hold.code else nil }
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
					local rank = if action.phase == "claimed" or action.phase == "uncertain" then 1 else 2
					if not priority or rank < priority or (rank == priority and key < active_action_id) then active_action_id = key; priority = rank end
				end
			end
			local wake_unstarted, wake_uncertain = 0, 0
			for _, wake in w.wakes or {} do
				local action = d.actions[wake.action_id]
				if not action or (action.phase == "ready" and not action.claim) then wake_unstarted += 1
				elseif action.phase == "claimed" or action.phase == "uncertain" then wake_uncertain += 1 end
			end
			table.insert(workflow.workers, { worker_id = w.worker_id, work_id = w.work_id, worker_generation = w.worker_generation,
				origin_binding = clone(control_origin(w)), pane_binding = clone(control_binding(w)),
				launch_origin_binding = clone(w.origin_binding), launch_pane_binding = clone(w.pane_binding),
				continuation_required = w.continuation_required == true, continuation_proof = continuation_proof(registry, w), health = clone(f.health), due_poll = f.due_poll,
				-- Guided reload recovery: a live mailbox worker whose control route is not the
				-- controller's current continued route must be explicitly reattached.
				reattach_needed = w.mailbox_handle ~= nil and w.pane_binding ~= nil and not w.stopped and not w.mailbox_retired
					and (w.continuation_required == true or ((d.command_cursors or {})[session_id] ~= nil
						and not equal(control_origin(w), d.command_cursors[session_id].origin))),
				due_report = f.due_report, report_request_pending = f.report_request ~= nil, active_action_id = active_action_id,
				finish_requested = w.finish ~= nil, coordinator_owner_id = w.coordinator_owner_id, phase = w.phase,
				due_rollover = (rollover_due(registry, w, f)), rollover = if latest_rollover[w.worker_id] then { id = latest_rollover[w.worker_id].id,
					phase = latest_rollover[w.worker_id].phase, role = latest_rollover[w.worker_id].role, hold_code = latest_rollover[w.worker_id].hold_code } else nil,
				wake_pending_count = count(w.wakes or {}), wake_unstarted_count = wake_unstarted, wake_uncertain_count = wake_uncertain,
				orchestration_excluded = table.find(workflow.policy.excluded_workers, w.worker_id) ~= nil,
				context_used_pct = if f.context then f.context.used_pct else nil, context_seq = if f.context then f.context.seq else nil,
				restored = clone(w.restored), routing = clone(w.routing), launch_action_id = w.launch_action_id, adopt_pane_binding = clone(w.adopt_pane_binding),
				rejected_report = if w.rejected_report then { code = w.rejected_report.code, message = w.rejected_report.message } else nil,
				withdrawal = withdrawal_view(d, w) })
			table.insert(workflow.threads, { work_id = w.work_id, entries = clone(f.thread) })
		end
	end
	for _, g in d.gates or {} do if g.logical_session_id == session_id then table.insert(workflow.gates, clone(g)) end end
	table.sort(workflow.workers, function(a, b) return a.worker_id < b.worker_id end)
	table.sort(workflow.threads, function(a, b) return a.work_id < b.work_id end)
	table.sort(workflow.gates, function(a, b) return a.id < b.id end)
	return { catalog = clone(d.catalogs[session_id]), command_cursor = clone((d.command_cursors or {})[session_id]), actions = actions, workers = workers, workflow = workflow }
end
return M
