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
	mailbox_provision = "logical_session_id worker_id worker_generation launch_request_id work_id enrolment_token record_id record_revision capability handover_id handover_sha256 manifest",
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
	-- attach_worker, stop and accept target this exact launch and generation from a pane on the route.
	local same_target = r.target_request_id == w.launch_request_id and r.target_action_id == w.launch_action_id
		and pane_binding(r.pane_binding, r.origin_binding) and r.worker_id == w.worker_id and r.worker_generation == w.worker_generation
		and r.enrolment_token == w.enrolment_token and r.work_id == w.work_id
	if r.op == "attach_worker" then
		return same_target and equal(r.previous_origin_binding, w.origin_binding) and equal(r.previous_pane_binding, w.pane_binding)
			and r.attestation == "old_executors_stopped_or_retired"
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
	-- A withdrawn rejected launch, or withdrawn fenced work (w.withdrawn, which keeps its old route),
	-- retires its unused mailbox on the route the owner cancelled from (earlier refused or revoked
	-- attempts keep their own exact route).
	if not route_known and r.op == "mailbox_retire" and r.mode == "retire" and (launch_rejected(d, w) or w.withdrawn ~= nil) then
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
	if r.op == "stop" then return same_target and (w.release ~= nil or w.finish ~= nil) end
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
-- initial_dispatch_*, worker_rollover_* and coordinator_rollover_* each carry an explicit record
-- allowlist and independent provider/account/model substitution permissions; missing permission is
-- false. concurrency_limit 0 = not configured. "" means "none" for the optional record/path keys,
-- so every stored policy keeps exactly its 46 keys.
local DEFAULT_POLICY = { paused = false, poll_ms = 5000, heartbeat_ms = 60000, stale_ms = 180000, automatic_reports = false,
	auto_rollover = false, rollover_threshold_pct = 80, rollover_include_coordinator = false, quota_routing = false, excluded_workers = {},
	quota_reserve_pct = 10, quota_max_age_ms = 900000, initial_dispatch_records = {}, initial_dispatch_provider = false,
	initial_dispatch_account = false, initial_dispatch_model = false, sweep_enabled = true, sweep_time = "03:00",
	worker_rollover_records = {}, worker_rollover_provider = false, worker_rollover_account = false, worker_rollover_model = false,
	coordinator_rollover_records = {}, coordinator_rollover_provider = false, coordinator_rollover_account = false, coordinator_rollover_model = false,
	concurrency_limit = 0, loop_cap = 3, review_rounds = 2, stale_claim_min = 30, enforce_cross_family = true, family_map = {},
	reviewer_records = {}, release_manager_record = "", checkout_roots = {}, auto_approve_kinds = {}, glitch_integration = true,
	default_work_source = "glitch_plan", board_path = "", board_lanes = { queued = "Todo", running = "Doing", review = "Review", done = "Done" },
	inbox_folder = "", auto_launch_intake = false, routes = {}, labeller_record = "",
	role_guidance = { builder = "", reviewer = "", release_manager = "", labeller = "", coordinator = "" }, templates = {} }
-- Config key sets, value-shape validators and Contract A worker-field rules share one table: the
-- module's top-level locals sit at Luau's 200-local limit.
local config: any = { keys = {} }
-- The problem table `fail` returns, for callers that answer (problem) instead of (nil, problem).
function config.refusal(code: string, message: string): any return { ok = false, code = code, message = message } end
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
-- Drops every action `drop` selects, then every retained command of a dropped action.
function config.discard_actions(d: any, drop: (string, any) -> boolean)
	local removed = {}
	for key, a in d.actions do
		if drop(key, a) then d.actions[key] = nil; removed[key] = true end
	end
	for key, command in d.commands do
		if removed[command.event.action_id] or removed[command.result.action_id] then d.commands[key] = nil end
	end
end
-- One executor settled: the controller and, for a coordinator's work, its orchestrator owner run one fewer.
function config.release_executor(session: any, w: any?)
	if session.controller then session.controller.pending_executors = math.max(0, session.controller.pending_executors - 1) end
	local owner = session.orchestrator
	if w and owner and owner.owner_id == w.coordinator_owner_id then owner.pending_executors = math.max(0, owner.pending_executors - 1) end
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
config.keys.editable = config.keys.v3 .. " loop_cap review_rounds stale_claim_min enforce_cross_family family_map reviewer_records release_manager_record checkout_roots auto_approve_kinds glitch_integration default_work_source board_path board_lanes inbox_folder auto_launch_intake routes labeller_record role_guidance templates"
local REPORT_KINDS = { "REGISTER", "ACCEPTED", "reply_ack", "COORDINATOR_RELEASE", "READY", "HEARTBEAT", "WAITING", "BLOCKED", "ASK",
	"CHECKPOINT", "REVIEW_READY", "REVIEW_RESULT", "DONE", "ROLLOVER_REQUEST", "LANDING_REQUEST", "LANDING_RESULT", "COORDINATOR_PROPOSAL",
	"CHECK_RESULT", "CHECKOUT", "LABEL", "DEPLOY_RESULT" }
config.ROLES = { "builder", "reviewer", "release_manager", "labeller", "coordinator" }
config.APPROVABLE = { "dispatch", "report", "review", "landing" }
config.MAX_BYTES = 49152 -- Aggregate bound on the canonical encoding (quota.canonical).
local function policy(d: any, session: string): any return (d.policies or {})[session] or DEFAULT_POLICY end
local function migrate_policy(p: any): any
	-- Stored 5/10/16/18/27-key policies predate later Config fields; fill only the documented defaults.
	local out = clone(DEFAULT_POLICY); for k, v in p do out[k] = clone(v) end; return out
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
-- Distinct ascending lists: worker IDs (`ids`) or an explicit record allowlist (no wildcard entries).
local function record_set(v: any, maximum: number, ids: boolean?): boolean
	if not config.list(v, maximum) then return false end
	for i, entry in v do if not (if ids then id(entry) else config.record(entry)) or (i > 1 and v[i - 1] >= entry) then return false end end
	return true
end
-- Local wall-clock "HH:MM" (24-hour) for the nightly mailbox sweep.
local function sweep_clock(v: any): boolean
	if type(v) ~= "string" or #v ~= 5 then return false end
	local hour, minute = v:match("^(%d%d):(%d%d)$")
	return hour ~= nil and (tonumber(hour) or 99) <= 23 and (tonumber(minute) or 99) <= 59
end
-- Config v4 value shapes (Contract B). Slugs are lowercase identifiers (family, class, template id).
function config.slug(v: any, n: number): boolean return type(v) == "string" and #v >= 1 and #v <= n and v:match("^[a-z][a-z0-9%-]*$") ~= nil end
function config.record(v: any): boolean return str(v, 96) and v:find("[%*%?]") == nil end
-- Explicit record list in the owner's order: distinct, no wildcards (order is meaningful, e.g. reviewer preference).
function config.records_ordered(v: any, maximum: number): boolean
	if not config.list(v, maximum) then return false end
	for i, record_id in v do if not config.record(record_id) or table.find(v, record_id) ~= i then return false end end
	return true
end
function config.absolute(v: any, n: number): boolean return str(v, n) and (v:sub(1, 1) == "/" or v:match("^%a:[\\/]") ~= nil) end
function config.relative(v: any, n: number): boolean
	if not str(v, n) or v:sub(1, 1) == "/" or v:sub(1, 1) == "\\" or v:match("^%a:") ~= nil then return false end
	for part in v:gmatch("[^/\\]+") do if part == ".." then return false end end
	return true
end
function config.list(v: any, maximum: number): boolean
	if type(v) ~= "table" or v == tern.json.null or #v > maximum or count(v) ~= #v then return false end
	for k in v do if type(k) ~= "number" or k < 1 or k > #v or k % 1 ~= 0 then return false end end
	return true
end
function config.texts(v: any, maximum: number, n: number, minimum: number?): boolean
	if not config.list(v, maximum) or #v < (minimum or 0) then return false end
	for _, entry in v do if not str(entry, n) then return false end end
	return true
end
function config.template(t: any): boolean
	if not closed(t, "id title prompt output next class") or not config.slug(t.id, 32) or not str(t.title, 80) or not str(t.prompt, 4096)
		or not config.relative(t.output, 256) or not (t.next == "" or (config.slug(t.next, 32) and t.next ~= t.id))
		or (t.class ~= nil and not config.slug(t.class, 32)) then return false end
	local _, inputs = t.prompt:gsub("{input}", "")
	return inputs == 1
end
function config.valid_v4(p: any): boolean
	if not (pos(p.loop_cap) and p.loop_cap <= 10 and pos(p.review_rounds) and p.review_rounds <= 2
		and (p.stale_claim_min == 0 or pos(p.stale_claim_min)) and p.stale_claim_min <= 1440
		and type(p.enforce_cross_family) == "boolean" and type(p.glitch_integration) == "boolean" and type(p.auto_launch_intake) == "boolean"
		and config.records_ordered(p.reviewer_records, 8) and (p.release_manager_record == "" or config.record(p.release_manager_record))
		and (p.labeller_record == "" or config.record(p.labeller_record)) and (p.default_work_source == "glitch_plan" or p.default_work_source == "board")
		and (p.board_path == "" or config.absolute(p.board_path, 512)) and (p.inbox_folder == "" or config.absolute(p.inbox_folder, 512))) then return false end
	local families = p.family_map
	if type(families) ~= "table" or families == tern.json.null or count(families) > 24 then return false end
	for record_id, family in families do if not config.record(record_id) or not config.slug(family, 24) then return false end end
	if not config.list(p.checkout_roots, 8) then return false end
	for i, root in p.checkout_roots do if not config.absolute(root, 512) or table.find(p.checkout_roots, root) ~= i then return false end end
	-- auto_approve_kinds is a distinct subset stored in the canonical dispatch, report, review, landing order.
	if not config.list(p.auto_approve_kinds, #config.APPROVABLE) then return false end
	local last = 0
	for _, kind in p.auto_approve_kinds do
		local index = table.find(config.APPROVABLE, kind)
		if not index or index <= last then return false end
		last = index
	end
	if not closed(p.board_lanes, "queued running review done") then return false end
	for _, lane in { "queued", "running", "review", "done" } do if not str(p.board_lanes[lane], 64) then return false end end
	if not config.list(p.routes, 16) then return false end
	local classes = {}
	for _, route in p.routes do
		if not closed(route, "class record_id") or not config.slug(route.class, 32) or not config.record(route.record_id) or classes[route.class] then return false end
		classes[route.class] = true
	end
	if not closed(p.role_guidance, table.concat(config.ROLES, " ")) then return false end
	for _, role in config.ROLES do if not str(p.role_guidance[role], 1024, true) then return false end end
	if not config.list(p.templates, 16) then return false end
	local templates = {}
	for _, t in p.templates do
		if not config.template(t) or templates[t.id] then return false end
		templates[t.id] = true
	end
	for _, t in p.templates do if t.next ~= "" and not templates[t.next] then return false end end
	return true
end
function config.fits(p: any): boolean return #quota.canonical(p) <= config.MAX_BYTES end
local function valid_policy(p: any, legacy: boolean?): boolean
	-- Exactly-CP2, exactly-CP3, exactly-pre-sweep, exactly-pre-rollover-routing and exactly-0.3.0
	-- (27-key) policies are accepted only at the explicit restore boundary, which migrates them.
	local keys = config.keys
	if legacy and ((closed(p, keys.cp2) and count(p) == 5) or (closed(p, keys.cp3) and count(p) == 10)
		or (closed(p, "paused " .. keys.quota) and count(p) == 16) or (closed(p, "paused " .. keys.sweep) and count(p) == 18)
		or (closed(p, "paused " .. keys.v3) and count(p) == 27)) then p = migrate_policy(p) end
	if type(p) ~= "table" or p == tern.json.null then return false end
	for _, scope in { "initial_dispatch", "worker_rollover", "coordinator_rollover" } do
		if not record_set(p[scope .. "_records"], quota.MAX_RECORDS) or type(p[scope .. "_provider"]) ~= "boolean"
			or type(p[scope .. "_account"]) ~= "boolean" or type(p[scope .. "_model"]) ~= "boolean" then return false end
	end
	if not (p.concurrency_limit == 0 or pos(p.concurrency_limit)) or p.concurrency_limit > quota.MAX_CONCURRENCY then return false end
	return closed(p, "paused " .. keys.editable) and type(p.paused) == "boolean" and type(p.automatic_reports) == "boolean"
		and pos(p.poll_ms) and p.poll_ms >= 1000 and p.poll_ms <= 60000 and pos(p.heartbeat_ms) and p.heartbeat_ms >= 5000
		and p.heartbeat_ms <= 3600000 and pos(p.stale_ms) and p.stale_ms >= p.heartbeat_ms and p.stale_ms <= 86400000
		and type(p.auto_rollover) == "boolean" and type(p.rollover_include_coordinator) == "boolean" and type(p.quota_routing) == "boolean"
		and pos(p.rollover_threshold_pct) and p.rollover_threshold_pct <= 99 and record_set(p.excluded_workers, 32, true)
		and (p.quota_reserve_pct == 0 or pos(p.quota_reserve_pct)) and p.quota_reserve_pct <= 99
		and pos(p.quota_max_age_ms) and p.quota_max_age_ms >= 60000 and p.quota_max_age_ms <= quota.STALE_AFTER_MS
		and type(p.sweep_enabled) == "boolean" and sweep_clock(p.sweep_time) and config.valid_v4(p) and config.fits(p)
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
		and not (f.report_loop and f.report_loop.state == "stopped") -- An owner-stopped report loop (loop_cap) stays stopped until a new report.
end
-- Policy-driven rollover only *requests* a checkpoint; every later edge needs its own evidence.
-- Coordinators are eligible only with rollover_include_coordinator and an active, activated owner.
local function rollover_due(registry: any, w: any, f: any): (boolean, string)
	local d = registry.dispatch
	local p = policy(d, w.logical_session_id)
	if not p.auto_rollover then return false, "Automatic rollover is off in Config." end
	if p.paused then return false, "Session is paused." end
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
	-- Landing evidence is pinned by its open queue item and review evidence by its open review
	-- (the reviews record owns an accepted REVIEW_RESULT), not by the latest report kind.
	return flow(w).evidence.ROLLOVER_REQUEST ~= nil or config.review_pinned(d, w) or config.deploy_pinned(d, w) or config.label_pinned(d, w)
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
-- Effective loop caps (Contract L). A loop record { count, gate_id?, state? } counts engagements
-- that re-engage a model or a worker. `loop_cap` engagements happen; the next attempt trips the
-- loop (state "gated") and opens one host-consumed loop_cap gate instead of engaging. allow_more
-- resets the count; stop (or cancel) keeps it "stopped". Code-only waits are never counted.
-- Host-consumed gates (HOST_GATES): the reducer applies the owner's answer itself ("resolved") and
-- never delivers an owner_decision; e.g. checkout gates release/cancel a held launch or block landing,
-- review gates re-run reviewer selection, label_unknown re-checks routes or retries the labeller.
local loops: any = { HOST_GATES = { quota_fallback = true, loop_cap = true, stale_claim = true, shared_checkout = true, file_overlap = true, scope = true, legacy_grant_outstanding = true,
		reviewer_unavailable = true, family_unknown = true, intake = true, label_unknown = true },
	GATE_KINDS = { "owner_question", "coordinator_proposal", "native_input", "landing_approval", "quota_fallback", "loop_cap", "stale_claim", "legacy_grant_outstanding",
		"shared_checkout", "file_overlap", "scope", "reviewer_unavailable", "family_unknown", "deploy_hold", "intake", "label_unknown" } }
-- The window answers every host-consumed kind with the chosen option alone (no free-text prompt).
-- deploy_hold is relayed (owner_decision to the release manager), so its answer keeps the prompt.
M.HOST_GATES = loops.HOST_GATES
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
-- Declared provider families (Contract A): owner map first, then the built-in provider table.
-- OMP and unknown providers stay unmapped (absent) until the owner maps the record.
config.PROVIDER_FAMILIES = { Claude = "anthropic", Codex = "openai", Kimi = "moonshot", Agy = "google", Grok = "xai", Muse = "muse" }
function config.family_of(d: any, w: any): string?
	local row
	for _, candidate_row in (d.catalogs[w.logical_session_id] or {}).records or {} do
		if candidate_row.id == w.record_id and candidate_row.revision == w.record_revision then row = candidate_row end
	end
	return policy(d, w.logical_session_id).family_map[w.record_id] or (if row then config.PROVIDER_FAMILIES[row.provider] else nil)
end
function config.bind_family(d: any, w: any) w.family = config.family_of(d, w) end
-- Contract A worker fields. Successors copy the assignment-shaped fields; family is recomputed
-- for the successor's record; checkout, check results and usage readings are never inherited.
-- base_ref completes the manifest inputs (Contract G); launch_gates lists the queue-time
-- shared_checkout/file_overlap gates (and a work source's intake gate) that hold a never-provisioned worker before launch.
-- review_id binds a reviewer worker to the review it serves; check_rework is the N-mode helper-check
-- rework loop { count, gate_id?, state?, key? } (key: digest of the last failed set sent).
-- scope_accepted { changed_digest, gate_id, at_ms } is the owner's durable accept of the exact
-- out-of-scope change set (config.scope_problem digest), written in the answer's commit; landing
-- reads it, never gate existence, so gate reclamation cannot re-block an accepted change set.
-- shared_acked lists the "peer:<worker>:<path>" keys of acknowledged post-launch shared_checkout
-- gates, so a reclaimed acknowledgement is never asked again. Restore default: absent; neither
-- is inherited by a successor (its own CHECKOUT is judged and accepted afresh).
config.WORKER_FIELDS = "role family class template_id files scope checks source base_ref manifest_sha256 checkout check_results usage_before usage_after launch_gates review_id check_rework scope_accepted shared_acked"
config.SUCCESSOR_FIELDS = { "role", "class", "template_id", "files", "scope", "checks", "source", "base_ref", "manifest_sha256" }
config.SOURCE_KINDS = { "manual", "plan", "board", "inbox", "template" }
function config.usage(v: any): boolean return v == nil or quota.valid_usage(v) end
function config.worker_fields(w: any): boolean
	if (w.role ~= nil and not table.find(config.ROLES, w.role)) or (w.family ~= nil and not config.slug(w.family, 24))
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
		or (s.ref ~= nil and not wire_text(s.ref, 1024)) or (s.revision ~= nil and not wire_text(s.revision, 1024))) then return false end
	local c = w.checkout
	if c ~= nil then
		-- Bounds follow the CHECKOUT codec (absolute paths ≤4096 including UNC, paths ≤4096 each).
		local absolute_path = function(v: any): boolean return str(v, 4096) and (v:sub(1, 1) == "/" or v:match("^%a:[\\/]") ~= nil or v:sub(1, 2) == "\\\\") end
		if not closed(c, "worktree_path common_dir branch head base changed_files changed_overflow changed_total dirty event_id seq")
			or not absolute_path(c.worktree_path) or not absolute_path(c.common_dir) or not str(c.branch, 1024, true)
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
	if event.role == "release_manager" then
		return { ok = false, code = "invalid_assignment", message = "ORCH+ launches the session's one release manager itself from Config → Release manager record when a landing first becomes grantable; it is never queued by hand." }
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
function config.provision(d: any, w: any, origin: any, pane: string): (any?, any?)
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
	return { worker_id = worker_id, work_id = work_id, worker_generation = 1, logical_session_id = sid,
		origin_binding = clone(event.origin), controller_pane = event.controller_pane, record_id = row.id, record_revision = row.revision,
		prompt = prompt, cwd = row.cwd, placement = row.placement, assignment_sha256 = codec.sha256(prompt),
		launch_request_id = next_id(d, "launch-"), launch_action_id = next_id(d, "action-"),
		enrolment_token = codec.sha256(seed .. event.origin.alias_nonce .. ":" .. work_id), phase = "queued",
		accepted_seq = 0, compacted_floor = 0, receipts = {}, replies = {}, reply_seq = 0, reply_floor = 0, role = role }
end
-- D14: the session's Config role guidance for `role`, prepended to an assignment ORCH+ sends.
-- Guidance only; ORCH+ never restricts tools by role.
function config.guided(d: any, sid: string, role: string, text: string): string
	local guidance = policy(d, sid).role_guidance[role] or ""
	return (if guidance ~= "" then guidance .. "\n\n" else "") .. text
end
-- Provisions a release-manager, reviewer or labeller worker and records its assignment; a hold on failure.
function config.provision_role(d: any, w: any, noun: string, clock: any): any?
	if #tern.json.encode(launch_request(w, string.rep("h", 96))) > 8192 then
		return config.hold("oversize", "The " .. noun .. " assignment plus its immutable launch binding exceeds the 8192-byte bridge; shorten the " .. noun .. " role guidance. Nothing was provisioned.")
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
local function dense(v: any, maximum: number, minimum: number?): boolean
	if type(v) ~= "table" or v == tern.json.null or #v < (minimum or 0) or #v > maximum or count(v) ~= #v then return false end
	for k in v do if not pos(k) or k > #v then return false end end
	return true
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
local function valid_flow(d: any, w: any): boolean
	local f = w.workflow
	if f == nil then return true end -- Explicit additive CP2 migration; no inferred reports.
	if not closed(f, "thread evidence checkpoints native report last_poll health due_poll due_report report_request observation_cursor started exit context empty_read report_loop")
		or not dense(f.thread, 128) or type(f.evidence) ~= "table" or f.evidence == tern.json.null or count(f.evidence) > 16
		or type(f.checkpoints) ~= "table" or f.checkpoints == tern.json.null or count(f.checkpoints) > 16 or type(f.due_poll) ~= "boolean" or type(f.due_report) ~= "boolean" then return false end
	if f.report_loop ~= nil and not loops.valid(f.report_loop) then return false end
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
		for sid, p in d.policies do if not registry.sessions[sid] or not valid_policy(p, legacy) then return false end end
	end
	if d.gates == nil then return true end
	if type(d.gates) ~= "table" or count(d.gates) > 64 then return false end
	for key, g in d.gates do
		if not closed(g, "id revision work_id worker_id worker_generation logical_session_id pane_binding kind phase question options evidence proposal at_ms answer delivery delivery_uncertain recheck result execution")
			or not id(key) or g.id ~= key or not pos(g.revision) or not wire_text(g.question, 32768) or not (g.at_ms == 0 or pos(g.at_ms))
			or not table.find(loops.GATE_KINDS, g.kind)
			or not table.find({ "pending", "answered", "delivery_pending", "delivered", "acknowledged", "cancelled", "superseded", "resolved" }, g.phase)
			or not dense(g.options, 16, 1) or not dense(g.evidence, 256) then return false end
		local w = d.workers[g.worker_id]
		if not w or g.worker_generation ~= w.worker_generation or g.work_id ~= w.work_id or g.logical_session_id ~= w.logical_session_id or not equal(g.pane_binding, w.pane_binding) then return false end
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
local ROLLOVER_KEYS = "id kind phase trigger logical_session_id work_id predecessor_worker_id predecessor_pane_binding origin controller_pane controller_generation handover_token request_id checkpoint verification successor_worker_id successor_pane_binding stop_observation hold history context predecessor_owner_id predecessor_generation successor_owner_id successor_generation closure quota checkpoint_loop"
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
		if r.checkpoint_loop ~= nil and not loops.valid(r.checkpoint_loop) then return false end
		if not config.valid_edges(r.history, "phase", phases, r.phase, registry.revision, "cancelled") then return false end
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
	if r ~= nil and (not closed(r, "outcome target_revision reason source at_ms revision") or (r.outcome ~= "landed" and r.outcome ~= "not_landed")
		or (r.outcome == "landed" and r.target_revision == nil) or (r.target_revision ~= nil and not landing_text(r.target_revision))
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
		if not config.valid_edges(item.history, "status", LANDING_STATUSES, item.status, registry.revision) or (item.gate_id ~= nil and not id(item.gate_id)) then return false end
		if item.approval ~= nil and (not closed(item.approval, "gate_id gate_revision at_ms") or item.approval.gate_id ~= item.gate_id
			or not pos(item.approval.gate_revision) or not (item.approval.at_ms == 0 or pos(item.approval.at_ms))) then return false end
		if item.verification ~= nil and (not legacy or not closed(item.verification, "attestation checkpoint_id artifact_revision") or item.verification.attestation ~= "worker-attested"
			or not id(item.verification.checkpoint_id) or item.verification.artifact_revision ~= r.source_revision) then return false end
		local proof = item.proof
		if proof ~= nil and (not closed(proof, "mode artifact_revision review_id check_refs") or (proof.mode ~= "cross_family_review" and proof.mode ~= "helper_checks")
			or proof.artifact_revision ~= r.source_revision or not id(proof.review_id) or not config.texts(proof.check_refs, 16, 1024)) then return false end
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
				or q.slot ~= key or (item.status == "landing") ~= current.acknowledged then return false end
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
-- Shape and correlation checks protect restored dispatch state; codecs revalidate exact receipts.
function M.valid(d: any, registry: any, legacy_catalog_cache: boolean?): boolean
	if d == nil then return true end
	if not closed(d, "serial actions workers commands catalogs policies gates command_cursors rollovers landing capacity sweeps reviews deploys plans intakes chains") or type(d.serial) ~= "number" or d.serial < 0 or d.serial % 1 ~= 0 or d.serial > MAX then return false end
	if not config.valid_reviews(d, registry) or not config.valid_sources(d, registry) then return false end
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
		if not closed(a, "request request_bytes phase worker_id claim response_bytes response response_grant resolution retry_count retry_loop stale_gate_id") or not id(key) or type(a.request) ~= "table" or a.request.action_id ~= key
			or not M.origin(a.request.origin_binding) or registry.sessions[a.request.origin_binding.logical_session_id] == nil or type(a.request_bytes) ~= "string" or #a.request_bytes > 8192 then return false end
		local decoded = codec.strict_decode(a.request_bytes, 8192); if not equal(decoded, a.request) then return false end
		if not table.find({ "ready", "claimed", "complete", "uncertain", "resolved", "backpressure" }, a.phase) then return false end
		if a.claim ~= nil and (not closed(a.claim, "executor epoch grant_id capacity claimed_at stale_gate_id") or not id(a.claim.executor) or not id(a.claim.grant_id) or not pos(a.claim.epoch) or a.claim.epoch > registry.execution_epoch) then return false end
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
		if not closed(w, "worker_id work_id worker_generation logical_session_id origin_binding controller_pane record_id record_revision prompt cwd placement assignment_sha256 launch_request_id launch_action_id enrolment_token phase accepted_seq compacted_floor receipts replies reply_seq reply_floor coordinator_owner_id coordinator_generation coordinator_protocol activation retirement release stop_action_id stopped mailbox_retired mailbox_retire_action_id mailbox_handle capabilities binding_digest receipt_chain compacted_chain pane_binding effective_identity accepted_event accept_pending registered frozen reason assembly read_selector compaction_pending workflow rejected_report finish control_origin control_pane control_pane_binding attachment_action_id continuation_required wakes handover_id handover_token restored routing adopt_pane_binding withdrawn " .. config.WORKER_FIELDS)
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
			if not closed(reply, "bytes sha256 frames part message_id reply_seq action_id action_revision acknowledged legacy")
				or type(reply.frames) ~= "table" or not pos(reply.part) or type(reply.acknowledged) ~= "boolean" or (reply.legacy ~= nil and reply.legacy ~= true) then return false end
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
			if not (w.release or w.finish) or not action or action.worker_id ~= key or action.request.op ~= "stop" then return false end
		end
		if w.stopped ~= nil then
			local action = d.actions[w.stop_action_id]
			if not action or not action.response or action.response.status ~= "stopped" or not equal(w.stopped, action.response.payload) then return false end
		end
		if w.mailbox_retire_action_id ~= nil then
			local action = d.actions[w.mailbox_retire_action_id]
			if not (w.stopped or launch_rejected(d, w) or w.withdrawn ~= nil) or not action or action.worker_id ~= key or action.request.op ~= "mailbox_retire" or action.request.mode ~= "retire" then return false end
		end
		-- Owner withdrawal of fenced never-launched work whose mailbox was provisioned (cancel_work):
		-- the kept fenced launch/adoption action and its definitive evidence.
		if w.withdrawn ~= nil and (not closed(w.withdrawn, "op action_id evidence") or (w.withdrawn.op ~= "launch" and w.withdrawn.op ~= "adopt")
			or not id(w.withdrawn.action_id) or w.withdrawn.action_id ~= w.launch_action_id
			or (w.withdrawn.evidence ~= "never_claimed" and w.withdrawn.evidence ~= "pre_effect_refusal") or not id(w.mailbox_handle) or (w.phase ~= "provisioned" and w.phase ~= "held")
			or w.pane_binding ~= nil or w.stopped ~= nil) then return false end
		if w.mailbox_retired ~= nil and (w.mailbox_retired ~= true or not w.mailbox_retire_action_id
			or d.actions[w.mailbox_retire_action_id].phase ~= "complete" or not d.actions[w.mailbox_retire_action_id].response
			or d.actions[w.mailbox_retire_action_id].response.status ~= "retired") then return false end
		if w.rejected_report ~= nil then
			local rejected = w.rejected_report
			if not closed(rejected, "code message bytes sha256 action_id") or not str(rejected.code, 96) or not str(rejected.message, 1024)
				or not str(rejected.bytes, 65536) or rejected.sha256 ~= codec.sha256(rejected.bytes) or not id(rejected.action_id)
				or w.assembly ~= nil or w.read_selector ~= nil then return false end
		end
		if not valid_flow(d, w) or not valid_routing(d, w) or not config.worker_fields(w) then return false end
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
	if not valid_rollovers(d, registry) or not valid_landing(d, registry, legacy_catalog_cache) or not config.valid_deploys(d, registry) then return false end
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
	config.legacy_upgrade(d)
	for _, g in d.gates or {} do g.result = nil end -- CP2 coordinator review results carry no Rule H proof any more.
	-- Contract E: untagged (pre-0.4.0 CP5) answers were the owner's. An approved proposal decided under
	-- the old "decision only" rule never executes after the upgrade; a CP3 review proposal already
	-- opened its review when it was answered.
	for _, g in d.gates or {} do
		if g.answer and g.answer.source.kind == nil then
			g.answer.source = config.owner_source(g.answer.source)
			local w = d.workers[g.worker_id]
			local proposal = if g.proposal and w then codec.decode_report(g.proposal, w) else nil
			if proposal and proposal.payload.kind ~= "rollover" and g.answer.choice_id == "approve" and g.execution == nil then
				local review = proposal.payload.kind == "review"
				g.execution = { state = if review then "done" else "refused", gate_revision = g.revision, effect_ref = if review then "legacy_review" else "legacy_decision_only", at_ms = 0 }
			end
		end
	end
	for _, w in d.workers do
		-- Contract A restore defaults: 0.3.0 workers become builders unless they carry coordinator
		-- markers; family resolves lazily, the other new fields stay absent. Claims are never
		-- stamped here (no clock): the first live tick rebases their claimed_at.
		if w.role == nil then w.role = if w.coordinator_owner_id ~= nil or w.coordinator_protocol ~= nil or (w.routing and w.routing.coordinator) then "coordinator" else "builder" end
		w.continuation_required = true; refresh(d, w, nil)
	end
end
local function candidate(registry: any): any
	local n = table.clone(registry); n.dispatch = clone(registry.dispatch or fresh()); n.sessions = clone(registry.sessions); n.revision += 1; return n
end
local function finish_command(n: any, event: any, answer: any): (any, any)
	remember(n.dispatch, event, answer, n.revision)
	return n, answer
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
-- Concurrency ledger: only routed work holds reservations; the limit applies while quota routing is on
-- and Config sets concurrency_limit. It serializes this session's launches, never a provider-side quota.
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
	local request, problem = config.provision(d, w, w.origin_binding, w.controller_pane)
	if not request then return nil, problem end
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
		w.record_id = decision.record.id; w.record_revision = decision.record.revision; config.bind_family(d, w)
		local action_id, err = prepare_launch(registry, n, w, r.coordinator, request_id, clock, reserve)
		if err then
			w.record_id = before_id; w.record_revision = before_revision; config.bind_family(d, w)
			if strict then return nil, err end
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
	return { bytes = bytes, message_id = if kind == "owner_decision" or kind == "report_request" or kind == "landing_grant" or kind == "landing_refresh" or kind == "deploy_grant" then reply.message_id else nil, action_id = reply.action_id, action_revision = reply.action_revision, reply_seq = reply.reply_seq,
		activation_token = payload.activation_token, acknowledged = false }, nil
end
local function settled(w: any): boolean
	local finish = w.release or w.finish
	if not finish or w.compacted_floor ~= w.accepted_seq or w.compacted_floor < finish.seq or w.reply_floor ~= w.reply_seq
		or w.accept_pending or w.assembly or w.rejected_report or next(w.receipts) or next(w.replies) or next(w.wakes or {}) then return false end
	return true
end
-- The existing exact mailbox retirement and compaction grants, shared by poll and the nightly sweep.
local function mailbox_request(n: any, d: any, w: any, mode: string): any
	local request = worker_request(d, w, "mailbox_retire")
	request.mode = mode; request.settlement_revision = if mode == "retire" then n.revision else w.compaction_pending; request.report_floor = w.compacted_floor
	request.report_chain_sha256 = w.compacted_chain; request.reply_floor = w.reply_floor; request.grant_id = next_id(d, mode .. "-")
	if mode == "retire" then w.mailbox_retire_action_id = request.action_id end
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
-- Checkout facts. Paths compare lexically (codec.normalize_path); symlinks and aliases are caught
-- only through the helper's CHECKOUT worktree_path/common_dir (visibility: config.VISIBILITY).
config.VISIBILITY = " Only same-session ORCH+ workers are visible; agents outside this ORCH+ session are not checked."
function config.live_peers(d: any, w: any): any
	local peers = {}
	for key, o in d.workers do
		-- Reviewers only read the change under review and labellers only classify text, so neither counts as a checkout/file peer.
		if key ~= w.worker_id and o.logical_session_id == w.logical_session_id and o.role ~= "coordinator" and o.role ~= "reviewer" and o.role ~= "labeller" and o.coordinator_owner_id == nil
			and not o.stopped and not o.mailbox_retired and not o.finish and not o.release then table.insert(peers, o) end
	end
	table.sort(peers, function(a: any, b: any): boolean return a.worker_id < b.worker_id end)
	return peers
end
function config.rooted(d: any, w: any, path: string): string?
	for _, root in policy(d, w.logical_session_id).checkout_roots do if codec.path_within(root, path) then return codec.normalize_path(root) end end
	return nil
end
-- Exact/ancestor index over literal paths; globs compare pairwise by literal prefix.
function config.path_index(list: any): any
	local index = { exact = {}, ancestors = {}, globs = {} }
	for _, entry in list or {} do
		local p = codec.normalize_path(entry)
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
	local p = codec.normalize_path(entry)
	if not p:find("[%*%?%[{]") then
		if index.exact[p] or index.ancestors[p] then return index.exact[p] or index.ancestors[p] end
		local slash = p:find("/", 2, true)
		while slash do
			if index.exact[p:sub(1, slash - 1)] then return index.exact[p:sub(1, slash - 1)] end
			slash = p:find("/", slash + 1, true)
		end
		for _, g in index.globs do if codec.globs_overlap(g, p) then return g end end
		return nil
	end
	for literal, original in index.exact do if codec.globs_overlap(p, literal) then return original end end
	for _, g in index.globs do if codec.globs_overlap(p, g) then return g end end
	return nil
end
-- Queue-time gates for a never-provisioned worker: one shared_checkout and/or one file_overlap
-- gate (each naming every overlapping peer). Returns the gate ids, or nil when nothing overlaps.
function config.queue_gates(d: any, w: any, clock: any): (any?, any?)
	if w.role == "coordinator" then return nil, nil end
	local peers, cwd, ids = config.live_peers(d, w), codec.normalize_path(w.cwd), {}
	local options = { { id = "launch_anyway", label = "Launch anyway" }, { id = "cancel", label = "Cancel this work" } }
	local root = config.rooted(d, w, cwd)
	if root and #peers > 0 then
		local hits, evidence = {}, { bounded("cwd:" .. cwd, 1024), bounded("root:" .. root, 1024) }
		for _, o in peers do
			for _, other in { o.cwd, if o.checkout then o.checkout.worktree_path else nil } do
				if other and config.rooted(d, w, other) and (codec.path_within(other, cwd) or codec.path_within(cwd, other)) then
					table.insert(hits, o.worker_id .. " (" .. codec.normalize_path(other) .. ")")
					table.insert(evidence, bounded("peer:" .. o.worker_id .. ":" .. codec.normalize_path(other), 1024)); break
				end
			end
		end
		if #hits > 0 then
			local g, err = new_gate(d, w, "shared_checkout", bounded("Work " .. w.work_id .. " would start in " .. cwd .. ", under checkout root " .. root
				.. ", which is the same checkout as (or nested with) " .. table.concat(hits, ", ") .. ". Two workers editing one checkout overwrite each other's changes."
				.. config.VISIBILITY .. " Launch anyway or cancel this work; nothing has been provisioned.", 32768), options, evidence, clock)
			if err then return nil, err end
			table.insert(ids, g.id)
		end
	end
	if w.files and #w.files > 0 and #peers > 0 then
		local repos = {}
		for _, o in peers do
			if o.checkout and (codec.normalize_path(o.cwd) == cwd or codec.path_within(o.checkout.worktree_path, cwd)) then repos[codec.normalize_path(o.checkout.common_dir)] = true end
		end
		local hits, evidence = {}, { bounded("cwd:" .. cwd, 1024) }
		for _, o in peers do
			if codec.normalize_path(o.cwd) == cwd or (o.checkout and repos[codec.normalize_path(o.checkout.common_dir)]) then
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
		if coordinator then
			local reserved, response = reserve(registry, { kind = "reserve_coordinator", request_id = event.request_id .. "-reserve", orch_session_id = sid, work_id = work_id }, clock)
			if reserved == nil then return nil, response end
			n.sessions = clone(reserved.sessions); n.request_outcomes = reserved.request_outcomes; n.next_owner_id = reserved.next_owner_id
			w.coordinator_owner_id = response.owner_id; w.coordinator_generation = response.generation
			w.coordinator_protocol = 1 -- Absent on old CP2 workers: never silently activate them.
			n.sessions[sid].orchestrator.managed_worker_id = worker_id
		end
		if #tern.json.encode(launch_request(w, string.rep("h", 96))) > 8192 then
			return fail("oversize", "Assignment and reserved coordinator identity exceed the immutable launch bridge bound; no reservation or provision was committed.")
		end
		local request, problem = config.provision(d, w, w.origin_binding, w.controller_pane)
		if not request then return nil, problem end
		-- Frozen enrolment is provisioned before any launch grant exists.
		if not add(d, request, worker_id) then return fail("oversize", "Provision request exceeds the bridge bound.") end
		d.workers[worker_id] = w; answer = result("task_queued", { worker_id = worker_id, work_id = work_id, action_id = request.action_id })
		if announce then local _, err = append(d, w, "assignment", w.prompt, clock); if err then return nil, err end end
	end
	return answer, nil
end
-- The settled record of a host-consumed answer: no gate_id, so reclaiming the gate (or dropping a
-- launch gate) removes the question's entries but never this question-and-answer evidence.
function config.record_answer(d: any, w: any, g: any, clock: any): (any?, any?)
	local label = g.answer.choice_id
	for _, option in g.options do if option.id == g.answer.choice_id then label = option.label end end
	return append(d, w, "answer", bounded("Owner answered " .. g.kind .. " gate " .. g.id .. " with " .. label .. ": " .. g.answer.answer
		.. " · Question: " .. g.question, 32768), clock)
end
-- Removes a gate and its thread entries (the reclaim_gates rule for one settled gate).
function config.drop_gate(d: any, w: any, key: string)
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
		for key, other in d.gates do if other.worker_id == w.worker_id then d.gates[key] = nil end end
		for _, p in d.policies or {} do
			for i = #p.excluded_workers, 1, -1 do if p.excluded_workers[i] == w.worker_id then table.remove(p.excluded_workers, i) end end
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
		for _, entry in paths do if codec.path_in_scope(entry, f) then inside = true; break end end
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
	return w.checkout ~= nil and codec.normalize_path(cp.payload.worktree_ref) ~= codec.normalize_path(w.checkout.worktree_path)
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
	w.checkout = c
	local path = codec.normalize_path(c.worktree_path)
	local root = config.rooted(d, w, path)
	if root and w.role ~= "coordinator" then
		for _, o in config.live_peers(d, w) do
			if o.checkout and codec.normalize_path(o.checkout.worktree_path) == path then
				local key = bounded("peer:" .. o.worker_id .. ":" .. path, 1024)
				local seen = table.find(w.shared_acked or {}, key) ~= nil
				for _, g in d.gates or {} do
					if g.worker_id == w.worker_id and g.kind == "shared_checkout" and g.phase ~= "cancelled" and table.find(g.evidence, key) then seen = true end
				end
				if not seen then
					local _, err = new_gate(d, w, "shared_checkout", bounded("Worker " .. w.worker_id .. " reports checkout " .. path .. " (under root " .. root .. "), the same worktree "
						.. o.worker_id .. " already reported. Two workers editing one checkout overwrite each other's changes; stop one of them or confirm you coordinate them."
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
		if r.quota then close_quota_gate(d, r.quota, pred) end
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
	-- Contract A successor copy: assignment-shaped fields carry over; family follows the successor's
	-- record; checkout, check results and usage readings are the successor's own.
	for _, key in config.SUCCESSOR_FIELDS do w[key] = clone(pred[key]) end
	config.bind_family(d, w)
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
	local request, problem = config.provision(d, w, event.origin, event.controller_pane)
	if not request then return rollover_hold(r, problem.code, problem.message) end
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
	for _, key in config.sorted_keys(d.rollovers, function(_, r) return r.logical_session_id == event.orch_session_id and not ROLLOVER_TERMINAL[r.phase] end) do
		for _ = 1, #COORDINATOR_ROLLOVER_PHASES do if not rollover_step(n, n.dispatch.rollovers[key], event, clock, reserve) then break end end
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
local function landing_problem(n: any, item: any, q: any, clock: any): any?
	local d = n.dispatch
	local w, r = d.workers[item.worker_id], item.request
	item.proof = nil
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
	local proof, problem = codec.verify_landing_proof({ enforce_cross_family = policy(d, w.logical_session_id).enforce_cross_family, source_revision = r.source_revision,
		checks = w.checks, check_results = w.check_results, builder_worker_id = w.worker_id, builder_record_id = w.record_id,
		builder_family = w.family or config.family_of(d, w), review = config.review_for(d, w) })
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
-- Contract I: the grant goes to the release-manager generation `rm` (never the builder) and binds
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
	local review = (d.reviews or {})[proof.review_id]
	local payload = { landing_id = item.id, grant_id = grant_id, project_id = r.project_id, checkpoint_id = latest_checkpoint(w).payload.checkpoint_id,
		repo_ref = r.repo_ref, target_ref = r.target_ref, target_revision = r.target_revision, source_ref = r.source_ref, source_revision = r.source_revision,
		builder_work_id = w.work_id, review_id = proof.review_id, reviewer_family = (if review then review.reviewer_family else nil) or "unknown",
		proof = { mode = proof.mode, artifact_revision = proof.artifact_revision, review_id = proof.review_id, check_refs = tern.json.array(clone(proof.check_refs)) } }
	local delivery, err = issue_reply(d, rm, "landing_grant", payload)
	if err then return landing_hold(err.code, err.message .. " No landing grant was issued.") end
	table.insert(item.grants, { grant_id = grant_id, worker_id = rm.worker_id, action_id = delivery.action_id, action_revision = delivery.action_revision,
		reply_seq = delivery.reply_seq, message_id = delivery.message_id, bytes = delivery.bytes, target_revision = r.target_revision,
		source_revision = r.source_revision, checkpoint_id = payload.checkpoint_id, controller_generation = event.origin.owner_generation,
		revision = n.revision, published = false, acknowledged = false })
	item.holder = { worker_id = rm.worker_id, worker_generation = rm.worker_generation }
	q.slot = item.id
	append(d, rm, "landing_grant", bounded("Landing " .. item.id .. " granted (" .. grant_id .. "): merge exactly " .. r.source_ref .. "@"
		.. r.source_revision .. " (builder work " .. w.work_id .. ") onto " .. r.repo_ref .. " " .. r.target_ref .. " expecting head " .. r.target_revision
		.. " following the repository's own rules, then report one exact LANDING_RESULT.", 32768), clock,
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
	local payload = { landing_id = item.id, project_id = r.project_id, repo_ref = r.repo_ref, target_ref = r.target_ref,
		expected_revision = r.target_revision, current_revision = q.head.revision,
		reason = (if cause == "target_moved" then "Target moved (" else "The release manager found the target moved (") .. q.head.source .. " via " .. q.head.landing_id
			.. "). Rebase or rebuild onto current_revision, publish a fresh CHECKPOINT, REVIEW_READY for the new revision (its earlier approval is void) and a fresh LANDING_REQUEST expecting current_revision; it needs new owner approval. Builders never merge: the release manager lands it." }
	local delivery, err = issue_reply(d, w, "landing_refresh", payload)
	if err then return deferred(err.message) end
	item.refresh = { worker_id = w.worker_id, worker_generation = w.worker_generation, expected_revision = r.target_revision, current_revision = q.head.revision, action_id = delivery.action_id,
		action_revision = delivery.action_revision, reply_seq = delivery.reply_seq, message_id = delivery.message_id, bytes = delivery.bytes,
		published = false, acknowledged = false, revision = n.revision }
	append(d, w, "landing_refresh", bounded("Landing " .. item.id .. " needs a refresh: " .. r.target_ref .. " moved from " .. r.target_revision
		.. " to " .. q.head.revision .. ". Rebase, get the new revision reviewed, then publish a fresh CHECKPOINT and LANDING_REQUEST expecting the new head.", 32768), clock,
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
local function advance_landing(n: any, event: any, clock: any)
	local d = n.dispatch
	config.legacy_sweep(d)
	local L = d.landing
	if not L then return end
	local paused = policy(d, event.orch_session_id).paused
	for _, key in config.sorted_keys(L.queues, function(_, q) return q.logical_session_id == event.orch_session_id end) do
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
				local hold = landing_problem(n, item, q, clock)
				if hold and (hold.code == "target_moved" or hold.code == "refresh_required") then hold = landing_refresh(n, q, item, hold, clock) end
				if index == 1 and not q.slot then
					if not hold and paused then hold = landing_hold("session_paused", "Session is paused; no landing grant is issued until resume.") end
					if not hold and type(clock) == "table" and clock.reserved_capacity then
						hold = landing_hold("capacity_reached", "Authority capacity is at its settlement reserve; no landing grant is issued.")
					end
					local rm
					if not hold then rm, hold = config.release_manager_ready(n, item.logical_session_id, event, clock) end
					if not hold then hold = grant_landing(n, q, item, rm, event, clock) end
					if hold then landing_status(item, if hold.code == "approval_pending" then "verifying" else "blocked", hold, n.revision, clock) end
				else
					landing_status(item, if hold then "queued" else "ready", hold, n.revision, clock)
				end
			end
		end
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
	local L = d.landing or { queues = {}, items = {} }
	local qid = landing_queue_id(w.logical_session_id, p)
	local q, existing = L.queues[qid], nil
	for _, landing_id in (if q then q.order else {}) do
		if L.items[landing_id].work_id == w.work_id then existing = L.items[landing_id] end
	end
	if existing and not LANDING_UNGRANTED[existing.status] then
		return fail("landing_in_progress", "This work's landing for this target is granted to the release manager; its exact LANDING_RESULT or owner reconciliation settles before a new request.")
	end
	if not existing then
		if count(L.items) >= 64 or (not q and count(L.queues) >= 32) then reclaim_landing(d, L, not q) end
		if count(L.items) >= 64 or (not q and count(L.queues) >= 32) then return fail("full", "Landing queue capacity is full of open items; nothing was evicted.") end
	end
	local landing_id = if existing then existing.id else next_id(d, "landing-")
	local question = "Approve landing " .. landing_id .. " (request report seq " .. tostring(report.seq) .. ")? Work " .. w.work_id .. " asks to land "
		.. p.source_ref .. "@" .. p.source_revision .. " (checkpoint " .. p.checkpoint_id .. ") onto " .. p.repo_ref .. " " .. p.target_ref
		.. " expecting head " .. p.target_revision .. ". Approval binds only this exact request; a refresh voids it. The grant is issued in queue order once proof rule H holds for this revision (helper-run checks and review, or cross-family review). The session's release manager (never the builder) merges it under the repository's own rules; ORCH+ never runs git or infers a merge."
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
		existing.approval = nil; existing.proof = nil; existing.refresh_required = nil
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
-- Contract I: only the holder — the release-manager generation the exact grant was issued to — may
-- report its LANDING_RESULT (semantic refuses every other role first: builders never merge).
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
		item.deploy_due = true -- Contract J: one deploy_grant follows the merge (advance_deploys).
	elseif p.outcome == "rejected" then
		landing_unqueue(q, item.id)
		landing_status(item, "failed", landing_hold("rejected", p.reason), n.revision, clock); landing_settle(d, item)
	else
		-- Stale target: release the slot; the item keeps its place but needs a fresh request. The
		-- builder's refresh notice (landing_refresh) is the counted refresh cycle (Contract L).
		q.head = { revision = p.observed_target_revision, source = "stale_target", landing_id = item.id }
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
	local live, ended
	for _, w in d.workers do
		if w.role == "release_manager" and w.logical_session_id == sid then
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
config.RM_CONFIG = " Set Config → Release manager record to a record offering release-manager-v1 (on neither the builder's nor the reviewer's record)."
-- D5 signer rule (pure; nothing launches here): a release manager is configured, its record carries
-- release-manager-v1, and it is neither the builder's record nor the approving reviewer's record.
function config.signer_problem(d: any, item: any, w: any): any?
	local sid = item.logical_session_id
	local rm = config.release_manager(d, sid)
	local record = if rm then rm.record_id else policy(d, sid).release_manager_record
	if record == "" then
		return landing_hold("release_manager_missing", "No release manager is configured; only the session's release manager receives landing grants (builders never merge)." .. config.RM_CONFIG)
	end
	if not rm then
		local row = config.rm_row(d, sid, record)
		if not row or not row.eligible or row.enabled ~= true or not table.find(row.capabilities, "release-manager-v1") then
			return landing_hold("release_manager_refused", "Release manager record " .. record .. " is absent from the current catalog, disabled or ineligible, or does not carry release-manager-v1; no release manager is launched and no grant is issued." .. config.RM_CONFIG)
		end
	end
	local review = if item.proof then (d.reviews or {})[item.proof.review_id] else nil
	local problem = codec.verify_signer({ release_manager_record_id = record, builder_record_id = w.record_id, reviewer_record_id = if review then review.reviewer_record_id else nil })
	if problem then return landing_hold(problem.code, problem.message .. config.RM_CONFIG) end
	return nil
end
-- Queues the session's release manager like a reviewer worker (existing provision/launch path).
-- The 32-worker cap holds the landing with backpressure; nothing is dropped.
function config.queue_release_manager(n: any, sid: string, row: any, event: any, clock: any): any?
	local d = n.dispatch
	if count(d.workers) >= 32 then reclaim_workers(n) end
	if count(d.workers) >= 32 then return { code = "full", message = "Managed generation capacity (32 workers) is full; the release manager launches when a slot frees. Nothing was dropped." } end
	if count(d.actions) >= 3072 or count(d.commands) >= 3072 then
		return { code = "full", message = "The durable dispatch ledger is near its bound; the release manager launches once settled actions are discarded. Nothing was dropped." }
	end
	local prompt = config.guided(d, sid, "release_manager", "You are this ORCH+ session's release manager: the only actor that merges and deploys. After ACCEPTED, wait for landing_grant and deploy_grant replies. "
		.. "For a landing_grant, merge exactly source_ref@source_revision into target_ref following the repository's own rules (AGENTS.md/CLAUDE.md, branch protection, PR requirements); never merge another revision; "
		.. "report one exact LANDING_RESULT echoing the grant: landed with the resulting head, rejected with the reason (also when the repository's rules forbid it), stale_target with the observed head, or uncertain. "
		.. "For a deploy_grant, deploy exactly that revision only where the repository's rules define a deploy and its preconditions hold; report one exact DEPLOY_RESULT echoing deploy_id, attempt_id, landing_id and revision: "
		.. "deployed or failed with evidence, not_applicable when no deploy is defined, or held with the reason (migrations, service units, privilege files) and then wait for the owner's decision.")
	local w = config.new_worker(d, event, sid, row, prompt, "release-manager:" .. sid .. ":", "release_manager")
	config.bind_family(d, w)
	return config.provision_role(d, w, "release-manager", clock)
end
-- The release manager that may receive a grant now, launching the session's one release manager
-- when none exists. A generation that ended after acceptance is succeeded by a fresh launch; one
-- that never got accepted (refused launch) holds until the owner cancels it — no launch loop.
function config.release_manager_ready(n: any, sid: string, event: any, clock: any): (any?, any?)
	local d = n.dispatch
	local rm, ended = config.release_manager(d, sid)
	if not rm then
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
	local rm, hold = config.release_manager_ready(n, dp.logical_session_id, event, clock)
	if hold then return config.deploy_hold(dp, item, hold.code, hold.message) end
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
			or (dp.status == "pending") ~= (#dp.attempts == 0) then return false end
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
	return { worker_id = w.worker_id, work_id = w.work_id, worker_generation = w.worker_generation, record_id = w.record_id, phase = w.phase, family = w.family or config.family_of(d, w) }
end
-- Landing row extras (Task 4B): requester builder, reviewer behind the proof (or the latest review),
-- the holder generation, the release manager (holder, else the session's live one) and the deploy.
function config.landing_extras(d: any, item: any, out: any)
	local b = d.workers[item.worker_id]
	out.builder = config.worker_ref(d, item.worker_id)
	local rv = (if item.proof then (d.reviews or {})[item.proof.review_id] else nil) or (if b then config.review_for(d, b) else nil)
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
config.REVIEW_KEYS = "review_id revision logical_session_id builder_worker_id builder_work_id builder_family builder_record_id reviewer_worker_id reviewer_record_id reviewer_family round artifact_revision checkpoint_id task_ref source_ref plan_ref plan_revision scope_paths status result findings refusal gate_id loop hold request rework void trigger at_ms"
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
		if w.work_id == rv.builder_work_id and w.logical_session_id == rv.logical_session_id and not w.stopped and not w.mailbox_retired
			and not w.finish and not w.release and not (w.workflow and w.workflow.exit) then
			local rank = if w.phase == "accepted" then 2 else 1
			local best_rank = if best then (if best.phase == "accepted" then 2 else 1) else 0
			if rank > best_rank or (rank == best_rank and config.review_serial({ review_id = w.worker_id }) > config.review_serial({ review_id = best.worker_id })) then best = w end
		end
	end
	return best
end
function config.review_pinned(d: any, w: any): boolean
	for _, rv in d.reviews or {} do
		if rv.logical_session_id == w.logical_session_id then
			if config.REVIEW_OPEN[rv.status] and rv.builder_work_id == w.work_id then return true end
			if rv.reviewer_worker_id == w.worker_id and (rv.status == "queued" or rv.status == "requested") then return true end
		end
	end
	return false
end
function config.review_room(d: any): boolean
	d.reviews = d.reviews or {}
	return config.make_room(d.reviews, 64, function(rv)
		local needed = config.review_of(d, { work_id = rv.builder_work_id, logical_session_id = rv.logical_session_id }) == rv and config.review_builder(d, rv) ~= nil
		return not config.REVIEW_OPEN[rv.status] and not needed
	end, config.review_serial)
end
-- Binds a review round to the builder generation and checkpoint that asked for it.
function config.review_bind(d: any, rv: any, w: any, cp: any)
	local p = cp.payload
	rv.builder_worker_id = w.worker_id; rv.builder_record_id = w.record_id; rv.builder_family = w.family or config.family_of(d, w)
	rv.artifact_revision = p.artifact_revision; rv.checkpoint_id = p.checkpoint_id; rv.task_ref = p.task_ref
	rv.source_ref = if w.checkout and w.checkout.branch ~= "" then w.checkout.branch else p.worktree_ref
	rv.plan_ref = p.plan_ref; rv.plan_revision = p.plan_revision
	rv.scope_paths = clone(if w.scope and #w.scope.paths > 0 then w.scope.paths else (w.files or {}))
	rv.reviewer_worker_id = nil; rv.reviewer_record_id = nil; rv.reviewer_family = nil
	rv.request = nil; rv.rework = nil; rv.hold = nil; rv.result = nil
end
-- One open review per builder work. Returns the review, a non-fatal note (nothing new opened), or a problem.
function config.open_review(n: any, w: any, cp: any, trigger: string, clock: any): (any?, string?, any?)
	local d = n.dispatch
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
	for _, entry in flow(b).thread do if entry.kind == "REVIEW_READY" then entry.state = "settled" end end
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
	if rv.status ~= "requested" then
		return config.refusal("review_closed", "Review " .. rv.review_id .. " is " .. rv.status .. "; it no longer accepts a result.")
	end
	if p.review_id ~= rv.review_id or p.round ~= rv.round or p.artifact_revision ~= rv.artifact_revision then
		return config.refusal("review_mismatch", "REVIEW_RESULT must name review " .. rv.review_id .. ", round " .. tostring(rv.round) .. " and artifact revision " .. rv.artifact_revision .. " exactly.")
	end
	local enforced = policy(d, w.logical_session_id).enforce_cross_family
	local b = config.review_builder(d, rv)
	if b then rv.builder_family = b.family or config.family_of(d, b) end
	local family = w.family or config.family_of(d, w)
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
	local enforced = p.enforce_cross_family
	if #p.reviewer_records == 0 then
		return nil, nil, "reviewer_unavailable", "No reviewer records are configured; add one under Config → Review & proof."
	end
	if enforced and rv.builder_family == nil then
		return nil, nil, "family_unknown", "The builder's record " .. tostring(rv.builder_record_id) .. " has no declared provider family, so a cross-family reviewer cannot be chosen; set its family under Config → Review & proof."
	end
	local reasons, unknown = {}, false
	for _, record_id in p.reviewer_records do
		local row
		for _, candidate_row in (if c then c.records else {}) do if candidate_row.id == record_id then row = candidate_row end end
		local family = if row then (p.family_map[record_id] or config.PROVIDER_FAMILIES[row.provider]) else nil
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
	if count(d.workers) >= 32 then reclaim_workers(n) end
	if count(d.workers) >= 32 then
		return { code = "full", message = "Managed generation capacity (32 workers, reviewers included) is full; this review waits and launches its reviewer when a slot frees. Nothing was dropped." }
	end
	if count(d.actions) >= 3072 or count(d.commands) >= 3072 then
		return { code = "full", message = "The durable dispatch ledger is near its bound; this review waits and launches its reviewer once settled actions are discarded. Nothing was dropped." }
	end
	local sid = rv.logical_session_id
	local scope = if #rv.scope_paths > 0 then bounded(table.concat(rv.scope_paths, ", "), 2048) else "the declared scope (none declared)"
	local question = string.format(config.JUDGE_QUESTION, rv.source_ref, rv.artifact_revision, rv.task_ref, scope)
	local prompt = config.guided(d, sid, "reviewer", "You are an ORCH+ reviewer worker for review " .. rv.review_id .. ", round " .. tostring(rv.round) .. ", of builder work " .. rv.builder_work_id
		.. ". After ACCEPTED, wait for the review_request reply and answer only its fixed question, once: " .. question
		.. " Report exactly one REVIEW_RESULT echoing the review_request action_id/action_revision, review_id, round and artifact_revision; findings name a file and line; no scores, no confidence. ORCH+ finishes this worker once the result settles.")
	local w = config.new_worker(d, event, sid, row, prompt, rv.review_id .. ":" .. tostring(rv.round) .. ":", "reviewer")
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
	local failed = if policy(d, rv.logical_session_id).enforce_cross_family then {} else config.failed_checks(b, rv.artifact_revision)
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
	rv.builder_family = b.family or config.family_of(d, b)
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
	if not config.finishable(n.dispatch, w) then return end
	w.finish = { request_id = next_id(n.dispatch, "auto-finish-"), seq = w.accepted_seq, revision = n.revision, source = { kind = "policy", rule = "auto_finish:" .. w.role } }
	config.usage_end(n.dispatch, w, clock)
	for _, entry in flow(w).thread do entry.state = "settled" end
	append(n.dispatch, w, "finish", "ORCH+ finishes this " .. w.role .. " automatically: its result is recorded on its " .. (if w.role == "labeller" then "intake" else "review")
		.. " and its receipts and replies are settled.", clock)
end
-- Helper-check rework (cross-family review off, D4): a new set of failed declared checks issues one
-- rework (failed checks only), counted against loop_cap; all checks passing ends the loop.
function config.check_rework(n: any, w: any, clock: any)
	local d = n.dispatch
	local p = policy(d, w.logical_session_id)
	if w.role ~= "builder" or w.coordinator_owner_id or not w.checks or #w.checks == 0 or p.enforce_cross_family then return end
	local failed = config.failed_checks(w, nil)
	if #failed == 0 then
		if w.check_rework then
			local g = loops.gate(d, w.check_rework)
			if g then g.phase = "superseded"; g.revision += 1; settle_entries(w, "gate_id", g.id) end
			w.check_rework = nil
		end
		return
	end
	local parts, ids = {}, {}
	for _, f in failed do
		table.insert(parts, f.check_id .. ":" .. string.format("%.0f", f.exit_code) .. ":" .. w.check_results[f.check_id].head); table.insert(ids, f.check_id)
	end
	local key = codec.sha256(table.concat(parts, "\n"))
	local loop = w.check_rework or { count = 0 }
	if loop.key == key or loop.state == "stopped" or p.paused or (type(clock) == "table" and clock.reserved_capacity)
		or w.phase ~= "accepted" or w.finish or w.release or w.stopped or w.mailbox_retired or w.continuation_required or not w.mailbox_handle then return end
	if loops.trips(loop, p.loop_cap) then
		w.check_rework = loop
		loops.open(d, w, loop, "check_rework", w.work_id, bounded("Work " .. w.work_id .. " already received " .. tostring(loop.count) .. " helper-check rework request(s) (loop cap "
			.. tostring(p.loop_cap) .. ") and declared checks still fail: " .. table.concat(ids, ", ") .. ". Allow more rework rounds or keep it stopped.", 32768), p.loop_cap, clock, true)
		return
	end
	local delivery, err = issue_reply(d, w, "rework", { round = loop.count + 1, artifact_revision = w.check_results[failed[1].check_id].head,
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
-- Lead autonomy inside plan scope (Checkpoint 5, D8/D9). A work's head is its newest generation.
function config.work_head(d: any, sid: string, work_id: string): any?
	local head
	for _, w in d.workers do
		if w.work_id == work_id and w.logical_session_id == sid and (not head or w.worker_generation > head.worker_generation) then head = w end
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
	if count(d.workers) >= 32 or count(d.actions) >= 3072 or count(d.commands) >= 3072 then
		return "pending", "full", "Managed generation or ledger capacity is full; the approved dispatch queues once a slot frees. Nothing was dropped."
	end
	-- The queue tail can fail after partial writes (gates, actions); a failure restores this snapshot.
	local saved = clone(d)
	local function undo(state: string, code: string, message: string): (string, string, string)
		n.dispatch = saved
		return state, code, message
	end
	local nw = config.new_worker(d, event, sid, row, config.guided(d, sid, "builder", p.prompt), g.id .. ":", "builder")
	config.bind_family(d, nw)
	-- Plan Task 5A: the new work inherits the parent work's scope and source (so it stays in plan scope).
	local invalid = config.assign(nw, { source = clone(parent.source), scope = clone(parent.scope) })
	if invalid then return undo("refused", invalid.code, invalid.message) end
	if #tern.json.encode(launch_request(nw, string.rep("h", 96))) > 8192 then
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
	if event.command == "resume" and not sp.paused then
		for _, key in config.sorted_keys(d.gates or {}, function(_, g) return g.logical_session_id == sid and g.kind == "coordinator_proposal" and g.phase == "pending"
			and table.find(g.evidence, "scope:in") ~= nil end, oldest) do
			local g = d.gates[key]; local w = d.workers[g.worker_id]
			local p = codec.decode_report(g.proposal, w).payload
			if p.kind ~= "rollover" and table.find(sp.auto_approve_kinds, p.kind) and config.in_scope(d, sid, p.work_id, p.kind, p) then config.policy_answer(d, w, g, p.kind, clock) end
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
	return { review_id = best.review_id, reviewer_worker_id = best.result.reviewer_worker_id, reviewer_family = best.reviewer_family, reviewer_role = "reviewer",
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
			or (rv.builder_family ~= nil and not config.slug(rv.builder_family, 24)) or (rv.reviewer_family ~= nil and not config.slug(rv.reviewer_family, 24))
			or (rv.reviewer_worker_id ~= nil and not id(rv.reviewer_worker_id)) or (rv.reviewer_record_id ~= nil and not config.record(rv.reviewer_record_id))
			or (rv.reviewer_worker_id ~= nil) ~= (rv.reviewer_record_id ~= nil) or not pos(rv.round) or rv.round > 2
			or not wire_text(rv.artifact_revision, 1024) or not id(rv.checkpoint_id) or not wire_text(rv.task_ref, 1024) or not wire_text(rv.source_ref, 1024)
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
-- `plans` (≤4 per session; an entry is pinned while any of its work is still managed),
-- `intakes` (≤256, keyed by intake_id; oldest settled reclaimed) and `chains` (template
-- chains, ≤64; oldest settled reclaimed). Every source work is an ordinary managed builder
-- with the Contract G normalized source; scheduling runs at the end of every dispatch commit.
config.plan_parser = require("./plan_import")
config.SOURCE = { PLAN_BYTES = 1048576, INBOX_BYTES = 32768, CARD_BYTES = 4096, INPUT_BYTES = 2048, TASK_TEXT = 2048,
	PLANS = 4, INTAKES = 256, CHAINS = 64, CHAIN_BOUND = 8, CHAIN_STEPS = 16, PROJECTED_INTAKES = 64 }
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
	if open or (rv and (config.REVIEW_OPEN[rv.status] or (rv.status == "approved" and rv.void == nil))) then return "review" end
	return "running"
end
-- Routed record (Contract G): routes[class], plan tasks and templates fall back to the "build"
-- route; the record must be in the current catalog, enabled and eligible.
function config.route_row(d: any, sid: string, class: string?, build_fallback: boolean): (any?, any?)
	local p, record_id = policy(d, sid), nil
	for _, r in p.routes do if class ~= nil and r.class == class then record_id = r.record_id end end
	if not record_id and build_fallback then for _, r in p.routes do if r.class == "build" then record_id = r.record_id end end end
	if not record_id then
		return nil, config.hold("route_missing", "No Config route names a record for class " .. (if class then "\"" .. class .. "\"" else "(none)")
			.. (if build_fallback then " and no \"build\" route exists" else "") .. ". Add one in Config → Routes; the work stays held.")
	end
	return config.catalog_row(d, sid, record_id, "Routed", "fix Config → Routes; the work stays held.")
end
-- The worker prompt: role guidance, the assignment text and a machine-readable header. The text
-- is shortened (UTF-8 safe) until the immutable launch request fits the 8192-byte bridge.
function config.source_prompt(w: any, guidance: string, text: string, header: string): string
	local function compose(body: string): string
		return (if guidance ~= "" then guidance .. "\n\n" else "") .. body .. "\n\n" .. header
	end
	local body = text
	for _ = 1, 4 do
		w.prompt = compose(body); w.assignment_sha256 = codec.sha256(w.prompt)
		local over = #tern.json.encode(launch_request(w, string.rep("h", 96))) - 8192
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
function config.source_launch(registry: any, n: any, sid: string, row: any, text: string, fields: any, intake_question: string?, evidence: any, event: any, clock: any, reserve: any): (any?, any?, string?)
	local d = n.dispatch
	if count(d.workers) >= 32 then reclaim_workers(n) end
	d.gates = d.gates or {}
	if count(d.gates) >= 61 then reclaim_gates(d) end
	if count(d.workers) >= 32 or count(d.actions) >= 3072 or count(d.commands) >= 3072 or count(d.gates) >= 61 then
		return nil, config.hold("full", "Managed worker, ledger or gate capacity is full; this work starts once a slot frees. Nothing was dropped.")
	end
	local p = policy(d, sid)
	local w = config.new_worker(d, event, sid, row, "", event.request_id .. ":", "builder")
	config.bind_family(d, w)
	local invalid = config.assign(w, fields)
	if invalid then return nil, config.hold(invalid.code, invalid.message) end
	config.source_prompt(w, p.role_guidance.builder, text, config.source_header(fields))
	if #tern.json.encode(launch_request(w, string.rep("h", 96))) > 8192 then
		return nil, config.hold("oversize", "The assignment plus its immutable launch binding cannot fit the 8192-byte bridge; nothing was provisioned.")
	end
	local saved = { workers = table.clone(d.workers), gates = table.clone(d.gates), actions = table.clone(d.actions) }
	local function undo(problem: any): (nil, any)
		d.workers = saved.workers; d.gates = saved.gates; d.actions = saved.actions
		return nil, config.hold(problem.code, problem.message)
	end
	local gate_ids, gate_err = config.queue_gates(d, w, clock)
	if gate_err then return undo(gate_err) end
	if intake_question then
		local g, err = new_gate(d, w, "intake", bounded(intake_question, 32768),
			{ { id = "launch_anyway", label = "Launch" }, { id = "cancel", label = "Cancel this work" } }, evidence, clock)
		if err then return undo(err) end
		gate_ids = gate_ids or {}
		table.insert(gate_ids, 1, g.id)
	end
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

function config.plan_room(d: any, sid: string): boolean
	d.plans = d.plans or {}
	local mine, oldest = 0, nil
	for _, plan in d.plans do
		if plan.logical_session_id == sid then
			mine += 1
			local settled = plan.status ~= "active"
			for _, cp in plan.checkpoints do
				for _, t in cp.tasks do if t.work_id and config.work_head(d, sid, t.work_id) then settled = false end end
			end
			if settled and (not oldest or config.serial(plan.plan_id) < config.serial(oldest.plan_id)) then oldest = plan end
		end
	end
	if mine < config.SOURCE.PLANS then return true end
	if oldest then d.plans[oldest.plan_id] = nil; return true end
	return false
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
	local row, hold = config.route_row(d, sid, t.class, true)
	if not row then t.state = "held"; t.hold = hold; return end
	local fields = { class = t.class, template_id = t.template_id, files = if #t.files > 0 then clone(t.files) else nil,
		scope = { paths = clone(t.files), systems = clone(t.systems) }, checks = if #t.checks > 0 then clone(t.checks) else nil,
		source = { kind = "plan", ref = plan.path .. "#" .. t.id, revision = plan.plan_revision } }
	local text = "Plan \"" .. plan.title .. "\" (" .. plan.path .. "), checkpoint " .. string.format("%.0f", cp.n) .. " — " .. cp.title .. ".\n"
		.. "Your task is " .. t.id .. " — " .. t.title .. (if #t.flags > 0 then " (plan flags: " .. table.concat(t.flags, ", ") .. "; unparsed checks are never run)" else "") .. ".\n\n" .. t.text
	local w, problem = config.source_launch(registry, n, sid, row, text, fields, nil, nil, event, clock, reserve)
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
	for _, cp in plan.checkpoints do for _, t in cp.tasks do if t.state ~= "done" then all_done = false end end end
	if all_done and plan.status == "active" then plan.status = "done" end
	if plan.status ~= "active" or config.starts_blocked(d, sid, clock) then return end
	local p = policy(d, sid)
	local limit = if p.concurrency_limit > 0 then p.concurrency_limit else 32
	for _, cp in plan.checkpoints do
		local earlier_open, earlier_sequential_open = false, false
		for _, t in cp.tasks do
			local waiting = t.state == "queued_plan" or (t.state == "held" and not config.PERMANENT_HOLDS[t.hold.code])
			local blocked = if t.independent then earlier_sequential_open else earlier_open
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
	d.plans = d.plans or {}
	for _, plan in d.plans do
		if plan.logical_session_id == sid and plan.path == path and plan.plan_revision == parsed.plan_revision and plan.status ~= "superseded" then
			return result("plan_already_imported", { plan_id = plan.plan_id, plan_revision = plan.plan_revision,
				message = "This exact plan revision is already imported; nothing changed." }), nil
		end
	end
	if not config.plan_room(d, sid) then
		return fail("plans_full", "This session already holds " .. tostring(config.SOURCE.PLANS) .. " imported plans whose work is still managed; settle or finish one first. Nothing was imported.")
	end
	-- A new revision of the same file supersedes the older import: its unstarted tasks never start,
	-- running work keeps its own revision, and tasks with the same id carry that work over.
	local carried = {}
	for _, plan in d.plans do
		if plan.logical_session_id == sid and plan.path == path and plan.status ~= "superseded" then
			plan.status = "superseded"
			for _, cp in plan.checkpoints do
				for _, t in cp.tasks do if (t.state == "running" or t.state == "done") and t.work_id then carried[t.id] = t end end
			end
		end
	end
	local plan_id = next_id(d, "plan-")
	local entry = { plan_id = plan_id, logical_session_id = sid, path = path, plan_revision = parsed.plan_revision, title = bounded(parsed.title, 256),
		flags = clone(parsed.flags), status = "active", at_ms = stamp(clock).at_ms, checkpoints = {} }
	local tasks = 0
	for _, cp in parsed.checkpoints do
		local out = { n = cp.n, title = bounded(cp.title, 256), flags = clone(cp.flags), tasks = {} }
		for _, t in cp.tasks do
			tasks += 1
			local task = { id = t.id, title = bounded(t.title, 256), independent = t.independent, sequential_why = if t.sequential_why then bounded(t.sequential_why, 256) else nil,
				class = t.class, template_id = t.template_id, files = clone(t.files), checks = clone(t.checks), systems = clone(t.systems), flags = clone(t.flags),
				text = bounded(t.text, config.SOURCE.TASK_TEXT), state = "queued_plan" }
			-- The manifest bound (Contract G) is checked once here: a task that can never be provisioned
			-- keeps no oversized fields and settles as failed with the reason.
			local _, manifest_problem = codec.encode_manifest({ checks = task.checks, files = task.files, scope = { paths = task.files, systems = task.systems } })
			if manifest_problem then
				task.state = "failed"; task.hold = config.hold(manifest_problem.code, manifest_problem.message); task.checks = {}; task.files = {}
			end
			local prior = carried[t.id]
			if prior and task.state ~= "failed" then task.state = prior.state; task.work_id = prior.work_id; task.worker_id = prior.worker_id end
			table.insert(out.tasks, task)
		end
		table.insert(entry.checkpoints, out)
	end
	d.plans[plan_id] = entry
	config.advance_plan(registry, n, entry, event, clock, reserve)
	local started = {}
	for _, cp in entry.checkpoints do for _, t in cp.tasks do if t.work_id and not carried[t.id] then table.insert(started, t.work_id) end end end
	return result("plan_imported", { plan_id = plan_id, plan_revision = entry.plan_revision, title = entry.title, checkpoints = #entry.checkpoints, tasks = tasks,
		started = tern.json.array(started) }), nil
end

-- Intakes (D12, Contract K). intake_id = quota.digest({kind, path, sha256}) exactly as the window
-- derives it; a duplicate returns the existing record, which serializes racing windows.
function config.intake_id(kind: string, path: string, sha256: string): string return quota.digest({ kind = kind, path = path, sha256 = sha256 }) end
function config.intake_answer(rec: any, code: string, duplicate: boolean?): any
	local out = result(code, { intake_id = rec.intake_id, state = rec.state, work_id = rec.work_id, worker_id = rec.worker_id,
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
	rec.logical_session_id = event.orch_session_id; rec.seq = config.serial(next_id(d, "intake-")); rec.at_ms = stamp(clock).at_ms
	d.intakes[rec.intake_id] = rec
	config.advance_intake(registry, n, rec, event, clock, reserve)
	if rec.text then rec.text = bounded(rec.text, config.SOURCE.CARD_BYTES) end
	return config.intake_answer(rec, "intake_" .. rec.state), nil
end
-- Optional class: a board tag `class-<route class>` (optionally `#`-prefixed) naming a Config route
-- class, or an inbox `**CLASS**: <slug>` line. Ordinary tags never route.
function config.intake_class(d: any, sid: string, tags: any, text: string): string?
	local classes = {}
	for _, r in policy(d, sid).routes do classes[r.class] = true end
	for _, tag in tags or {} do
		local name = tag:match("^#?class%-(.+)$")
		if name and classes[name] then return name end
	end
	for line in (text .. "\n"):gmatch("([^\n]*)\n") do
		local v = line:match("^%s*[%-%*]?%s*%*%*CLASS%*%*:%s*`?([a-z][a-z0-9%-]*)`?%s*$")
		if v and config.slug(v, 32) then return v end
	end
	return nil
end
function config.start_intake(registry: any, n: any, rec: any, event: any, clock: any, reserve: any)
	local d, sid = n.dispatch, rec.logical_session_id
	if not rec.class then
		config.label_intake(n, rec, event, clock)
		if not rec.class then return end
	end
	local row, hold = config.route_row(d, sid, rec.class, false)
	if not row then rec.hold = hold; return end
	local p = policy(d, sid)
	local text, question
	if rec.kind == "board" then
		text = "Board card from " .. rec.path .. (if rec.tags and #rec.tags > 0 then " (tags: " .. table.concat(rec.tags, ", ") .. ")" else "") .. ":\n\n" .. rec.text
		question = "New board card on " .. rec.path .. " (intake " .. rec.intake_id:sub(1, 12) .. ") is ready to launch on " .. row.id .. ". Auto-launch of intake is off in Config. Launch it or cancel this work; nothing has been provisioned."
	else
		local archived = (rec.path:match("^(.*)/[^/]*$") or "") .. "/.orchplus-taken/" .. rec.intake_id .. "-" .. rec.ref
		text = "Inbox task file " .. rec.ref .. " (sha256 " .. rec.revision .. "); once taken it is archived at " .. archived .. ".\n\n" .. (rec.text or "")
		question = "New inbox file " .. rec.ref .. " (intake " .. rec.intake_id:sub(1, 12) .. ") is ready to launch on " .. row.id .. ". Auto-launch of intake is off in Config. Launch it or cancel this work; nothing has been provisioned."
	end
	local fields = { class = rec.class, source = { kind = rec.kind, ref = rec.ref, revision = rec.revision } }
	local w, problem = config.source_launch(registry, n, sid, row, text, fields, if p.auto_launch_intake then nil else question,
		{ "intake:" .. rec.intake_id }, event, clock, reserve)
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
	if not config.starts_blocked(d, sid, clock) then config.start_intake(registry, n, rec, event, clock, reserve) end
end
-- rec.label = { worker_id?, attempts, loop, request?, result?, gate_id?, retry? }.
function config.route_classes(d: any, sid: string): { string }
	local out = {}
	for _, r in policy(d, sid).routes do table.insert(out, r.class) end
	return out
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
-- A fresh labeller worker through the existing provision → launch path (like a reviewer: never
-- quota-routed, counted against the 32-worker cap; a full cap holds the intake, nothing is dropped).
function config.queue_labeller(n: any, rec: any, row: any, event: any, clock: any): any?
	local d, sid, L = n.dispatch, rec.logical_session_id, rec.label
	if count(d.workers) >= 32 then reclaim_workers(n) end
	if count(d.workers) >= 32 or count(d.actions) >= 3072 or count(d.commands) >= 3072 then
		return config.hold("full", "Managed worker or ledger capacity is full; the labeller launches once a slot frees. Nothing was dropped.")
	end
	local prompt = config.guided(d, sid, "labeller", "You are an ORCH+ labeller worker for intake " .. rec.intake_id .. " (" .. rec.kind .. " " .. rec.ref .. "). After ACCEPTED, wait for the label_request reply and answer it once:"
		.. " exactly one LABEL {work_ref, class, reason?} echoing its action_id/action_revision and work_ref, with class copied from its classes list (if none fits, pick the closest and say why in reason; never invent a class)."
		.. " Do no other work. ORCH+ routes the work from your label and finishes this worker once it settles.")
	local attempt = L.attempts + 1
	local w = config.new_worker(d, event, sid, row, prompt, rec.intake_id .. ":" .. tostring(attempt) .. ":", "labeller")
	config.bind_family(d, w)
	local held = config.provision_role(d, w, "labeller", clock); if held then return held end
	L.worker_id = w.worker_id; L.request = nil; L.result = nil; L.retry = nil; L.attempts = attempt
	return nil
end
function config.request_label(d: any, rec: any, lw: any): any
	if lw.phase ~= "accepted" then
		return config.hold("label_running", "Labeller " .. lw.worker_id .. " (" .. lw.record_id .. ") is launching; its label_request is sent after ACCEPTED.")
	end
	if lw.continuation_required or not lw.mailbox_handle then
		return config.hold("labeller_unbound", "Explicitly continue labeller worker " .. lw.worker_id .. " before its label_request is sent.")
	end
	local delivery, err = issue_reply(d, lw, "label_request", { work_ref = rec.intake_id,
		classes = tern.json.array(config.route_classes(d, rec.logical_session_id)), text = rec.text or (rec.kind .. " " .. rec.ref) })
	if err then return config.hold(err.code, "The label_request could not be issued to " .. lw.worker_id .. ": " .. err.message) end
	rec.label.request = { action_id = delivery.action_id, action_revision = delivery.action_revision, reply_seq = delivery.reply_seq }
	return config.hold("label_requested", "Labeller " .. lw.worker_id .. " was asked to classify this intake; the work routes when its LABEL arrives.")
end
function config.label_gate(d: any, rec: any, lw: any, clock: any)
	local L = rec.label
	local classes = config.route_classes(d, rec.logical_session_id)
	local question = bounded("Labeller " .. lw.worker_id .. " labelled intake " .. rec.intake_id:sub(1, 12) .. " (" .. rec.kind .. " " .. rec.ref .. ") as \"" .. L.result.class
		.. "\", which no Config route names (routes: " .. table.concat(classes, ", ") .. ")." .. (if L.result.reason then " Its reason: " .. L.result.reason else "")
		.. " Add a route for that class in Config → Routing and route it, label it again with a fresh labeller (counts against the loop cap), or cancel this intake. Nothing was launched.", 32768)
	local g, err = new_gate(d, lw, "label_unknown", question,
		{ { id = "route_now", label = "Route it (a route for \"" .. L.result.class .. "\" now exists)" }, { id = "relabel", label = "Label again" }, { id = "cancel", label = "Cancel this intake" } },
		{ "intake:" .. rec.intake_id, "class:" .. L.result.class }, clock)
	if err then rec.hold = config.hold(err.code, err.message); return end
	L.gate_id = g.id
	rec.hold = config.hold("label_unknown", question)
end
-- Called from start_intake for an intake without a class; sets rec.class once a routed label exists.
function config.label_intake(n: any, rec: any, event: any, clock: any)
	local d, sid = n.dispatch, rec.logical_session_id
	local p = policy(d, sid)
	if p.labeller_record == "" then
		rec.hold = config.hold("label_pending", "This intake names no class (a board tag or inbox **CLASS**: line matching a Config route) and no labeller record is configured. Choose one in Config → Routing → Choose labeller…, or give the source a route class; the work stays held.")
		return
	end
	if #p.routes == 0 then
		rec.hold = config.hold("route_missing", "Config has no routes, so the labeller has no class to choose from. Add routes in Config → Routing; the intake stays held.")
		return
	end
	rec.label = rec.label or { attempts = 0, loop = { count = 0 } }
	local L = rec.label
	local lw = if L.worker_id then d.workers[L.worker_id] else nil
	local g = if L.gate_id then (d.gates or {})[L.gate_id] else nil
	if g and gate_open(g) then return end -- The label_unknown hold stays until the owner answers.
	L.gate_id = nil
	if L.result then
		if table.find(config.route_classes(d, sid), L.result.class) then rec.class = L.result.class; rec.hold = nil; return end
		if not lw then config.label_refuse(rec, "label_unbound", "The labeller generation that labelled this intake is no longer managed, so its label_unknown gate cannot open."); return end
		config.label_gate(d, rec, lw, clock)
		return
	end
	if lw and not L.retry and not config.rm_ended(d, lw) then
		if L.request then return end -- label_requested: waiting for LABEL.
		rec.hold = config.request_label(d, rec, lw)
		return
	end
	-- A (new) labeller is needed: the first one, or a retry (Contract L: counted against loop_cap).
	local retry = L.attempts > 0
	if retry then
		if L.loop.state == "stopped" then
			config.label_refuse(rec, "label_stopped", "Labeller retries for this intake were stopped at the loop cap; it stays untaken.")
			return
		end
		if loops.trips(L.loop, p.loop_cap) then
			if loops.gate(d, L.loop) then return end
			if not lw then config.label_refuse(rec, "label_unbound", "No labeller generation remains to carry this intake's loop_cap gate; it stays untaken."); return end
			local question = bounded("Labelling intake " .. rec.intake_id:sub(1, 12) .. " (" .. rec.kind .. " " .. rec.ref .. ") needed " .. tostring(L.attempts) .. " labeller launch(es) (retries "
				.. tostring(L.loop.count) .. ", loop cap " .. tostring(p.loop_cap) .. "); the last labeller " .. lw.worker_id .. " ended without a routable LABEL. Allow more retries or keep it stopped.", 32768)
			local _, err = loops.open(d, lw, L.loop, "labeller", rec.intake_id, question, p.loop_cap, clock, true)
			rec.hold = if err then config.hold(err.code, err.message) else config.hold("loop_cap", question)
			return
		end
	end
	local row, problem = config.catalog_row(d, sid, p.labeller_record, "Labeller", "choose another in Config → Routing → Choose labeller…; the intake stays held.")
	if not row then rec.hold = problem; return end
	local held = config.queue_labeller(n, rec, row, event, clock)
	if held then rec.hold = held; return end
	if retry then L.loop.count += 1 end
	rec.hold = config.hold("label_running", "Labeller " .. L.worker_id .. " launched on " .. row.id .. " to classify this intake; the work routes when its LABEL arrives.")
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
	if event.command == "answer" then
		local choice = false; for _, option in g.options do if option.id == event.choice_id then choice = true end end
		if g.phase ~= "pending" or not choice or not str(event.answer, 32768) then return fail("invalid_choice", "Choose an option from this exact question.") end
		g.answer = { choice_id = event.choice_id, answer = event.answer, source = config.owner_source(event.origin), at_ms = stamp(clock).at_ms }
		g.phase = "resolved"
	else g.phase = "cancelled"; g.revision += 1 end
	settle_entries(w, "gate_id", g.id)
	if rec then
		rec.label.gate_id = nil
		if cancel then config.label_refuse(rec, "owner_cancelled", "The owner cancelled this intake at label gate " .. g.id .. "; the source stays untaken.")
		elseif event.choice_id == "relabel" then rec.label.result = nil; rec.label.request = nil; rec.label.retry = true end
	end
	return result(if cancel then "label_cancelled" elseif event.choice_id == "relabel" then "label_retry" else "label_route", { gate_id = g.id, intake_id = if rec then rec.intake_id else nil }), nil
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
		local ids = table.clone(r.account.canonical_ids); table.sort(ids)
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
	if p.board_path == "" or event.board_path ~= p.board_path then
		return fail("board_mismatch", "Board intake names " .. tostring(event.board_path) .. ", not Config's board file; nothing was taken.")
	end
	if not str(event.card_id, 128) or event.card_id:find("%c") or type(event.text) ~= "string" or not config.texts(event.tags, 64, 256) or not digest(event.text_sha256) then
		return fail("intake_invalid", "A board intake carries the card id, its text, its tags (≤64 strings) and the text sha256.")
	end
	local text_sha256 = quota.digest({ text = event.text, tags = event.tags })
	if text_sha256 ~= event.text_sha256 then return fail("intake_invalid", "The card text and tags do not match the sent text_sha256; the card is re-read on the next poll.") end
	local intake_id = config.intake_id("board", p.board_path, text_sha256)
	d.intakes = d.intakes or {}
	local known = d.intakes[intake_id]
	if known then
		-- An id-invalidating board reload re-sends the same intake with the card's new id.
		if known.card_id ~= event.card_id then known.card_id = event.card_id end
		return config.intake_answer(known, "intake_duplicate", true), nil
	end
	local fields = { intake_id = intake_id, kind = "board", ref = p.board_path .. "#" .. intake_id, path = p.board_path, revision = text_sha256,
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
function config.inbox_intake_command(registry: any, n: any, event: any, clock: any, reserve: any): (any?, any?)
	local d, sid = n.dispatch, event.orch_session_id
	local p = policy(d, sid)
	local name = event.name
	if p.inbox_folder == "" then return fail("inbox_unset", "Config sets no inbox folder; nothing was taken.") end
	if not str(name, 255) or name:sub(1, 1) == "." or name:find("[%c/\\]") or not (name:lower():sub(-3) == ".md" or name:lower():sub(-4) == ".txt") or not digest(event.content_sha256) then
		return fail("intake_invalid", "An inbox intake names one *.md or *.txt file directly in the inbox folder and its content sha256.")
	end
	local path = p.inbox_folder .. "/" .. name
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
	local row, hold = config.route_row(d, sid, t.class, true)
	if not row then return nil, hold end
	local input = step.input
	local text = t.prompt:gsub("{input}", function() return input end)
	text ..= "\n\nTemplate " .. t.id .. " (" .. t.title .. "): write your output to " .. t.output .. " and report DONE with output_ref \"" .. t.output .. "\"."
	local fields = { class = t.class, template_id = t.id, source = { kind = "template", ref = t.id, revision = quota.digest(t) } }
	local w, problem, action_id = config.source_launch(registry, n, sid, row, text, fields, nil, nil, event, clock, reserve)
	if not w then return nil, problem end
	step.state = "running"; step.work_id = w.work_id; step.worker_id = w.worker_id; step.hold = nil
	return w, nil, action_id
end
function config.chain_room(d: any): boolean
	d.chains = d.chains or {}
	return config.make_room(d.chains, config.SOURCE.CHAINS, function(c) return c.status == "done" or c.status == "stopped" end, function(c) return config.serial(c.chain_id) end)
end
function config.chain_push(c: any, template_id: string, input: string): any
	local step = { template_id = template_id, input = input, state = "held" }
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
			config.chain_push(c, last.template_id, last.input)
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
			if not t or t.next == "" then
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
				step = config.chain_push(c, t.next, step.output_ref)
			end
		elseif not w or w.finish or w.stopped or w.mailbox_retired then
			step.state = "failed"
		else return end
	end
	if step.state == "failed" then
		if loops.trips(c.loop, cap) then c.status = "gated"; config.chain_gate(d, c, false, clock); return end
		c.loop.count += 1
		step = config.chain_push(c, step.template_id, step.input)
	end
	if step.state == "held" and not config.starts_blocked(d, sid, clock) then
		local _, hold = config.start_step(registry, n, sid, step, event, clock, reserve)
		if hold then
			step.hold = hold
			if config.PERMANENT_HOLDS[hold.code] then step.state = "failed"; c.status = "stopped"; c.hold = hold end
		end
	end
end
function config.template_start_command(registry: any, n: any, event: any, clock: any, reserve: any): (any?, any?)
	local d, sid = n.dispatch, event.orch_session_id
	if policy(d, sid).paused then return fail("session_paused", "Session is paused; no template chain starts.") end
	if not config.slug(event.template_id, 32) or not config.template_of(d, sid, event.template_id) then return fail("template_unknown", "No saved template has this id; nothing was started.") end
	if not str(event.input, config.SOURCE.INPUT_BYTES) or event.input:find("%S") == nil then return fail("invalid_input", "Template input is 1..2048 bytes of UTF-8 text.") end
	if not config.chain_room(d) then return fail("chains_full", "Template chain capacity (" .. tostring(config.SOURCE.CHAINS) .. ") is full of unfinished chains; nothing was started.") end
	local c = { chain_id = next_id(d, "chain-"), logical_session_id = sid, status = "running", successes = 0, steps = {}, loop = { count = 0 }, at_ms = stamp(clock).at_ms }
	local step = config.chain_push(c, event.template_id, event.input)
	local w, hold, action_id = config.start_step(registry, n, sid, step, event, clock, reserve)
	if not w then return fail(hold.code, hold.message .. " Nothing was started.") end
	d.chains[c.chain_id] = c
	return result("template_started", { chain_id = c.chain_id, work_id = w.work_id, worker_id = w.worker_id, action_id = action_id }), nil
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
end
-- Window and card projections (Contract K): newest 64 intakes; desired lane per mapped board card.
function config.sources_view(d: any, sid: string, workflow: any)
	local p = policy(d, sid)
	local recs = config.ordered(d.intakes, sid, nil, function(rec) return -rec.seq end)
	workflow.intakes, workflow.board = {}, { path = p.board_path, cards = {} }
	for i = 1, math.min(#recs, config.SOURCE.PROJECTED_INTAKES) do
		local rec = recs[i]
		table.insert(workflow.intakes, { intake_id = rec.intake_id, kind = rec.kind, ref = rec.ref, state = rec.state, work_id = rec.work_id,
			refusal = rec.refusal, hold = clone(rec.hold), lane = rec.lane,
			label = if rec.label then { worker_id = rec.label.worker_id, attempts = rec.label.attempts, retries = rec.label.loop.count,
				class = if rec.label.result then rec.label.result.class else nil } else nil })
	end
	for i = #recs, 1, -1 do
		local rec = recs[i]
		if rec.kind == "board" and rec.path == p.board_path and rec.card_id and rec.state ~= "refused" and rec.lane then
			table.insert(workflow.board.cards, { card_id = rec.card_id, intake_id = rec.intake_id, lane = rec.lane })
		end
	end
	workflow.plans, workflow.chains = {}, {}
	for _, plan in config.ordered(d.plans, sid, nil, function(plan) return config.serial(plan.plan_id) end) do
		local cps = {}
		for _, cp in plan.checkpoints do
			local tasks = {}
			for _, t in cp.tasks do
				table.insert(tasks, { id = t.id, title = t.title, state = t.state, independent = t.independent, work_id = t.work_id, worker_id = t.worker_id,
					hold = clone(t.hold), flags = clone(t.flags), checks = #t.checks, files = #t.files })
			end
			table.insert(cps, { n = cp.n, title = cp.title, flags = clone(cp.flags), tasks = tasks })
		end
		table.insert(workflow.plans, { plan_id = plan.plan_id, path = plan.path, plan_revision = plan.plan_revision, title = plan.title, status = plan.status,
			flags = clone(plan.flags), checkpoints = cps })
	end
	for _, c in config.ordered(d.chains, sid, nil, function(c) return config.serial(c.chain_id) end) do
		table.insert(workflow.chains, { chain_id = c.chain_id, status = c.status, successes = c.successes, loop = clone(c.loop), hold = clone(c.hold), steps = clone(c.steps) })
	end
end
config.SOURCE_COMMANDS = { plan_import = config.plan_import_command, board_intake = config.board_intake_command,
	inbox_intake = config.inbox_intake_command, template_start = config.template_start_command }
-- Restore boundary validation of the three source collections.
function config.valid_hold(v: any): boolean return v == nil or (closed(v, "code message") and str(v.code, 96) and wire_text(v.message, 1024)) end
function config.valid_sources(d: any, registry: any): boolean
	if d.plans ~= nil then
		if type(d.plans) ~= "table" or d.plans == tern.json.null then return false end
		local per = {}
		for key, plan in d.plans do
			if not closed(plan, "plan_id logical_session_id path plan_revision title flags status at_ms checkpoints") or not id(key) or plan.plan_id ~= key
				or not registry.sessions[plan.logical_session_id] or not config.absolute(plan.path, 512) or not digest(plan.plan_revision) or not str(plan.title, 256)
				or not config.texts(plan.flags, 16, 64) or not table.find(config.PLAN_STATUSES, plan.status) or not (plan.at_ms == 0 or pos(plan.at_ms))
				or not dense(plan.checkpoints, config.plan_parser.MAX_CHECKPOINTS) then return false end
			per[plan.logical_session_id] = (per[plan.logical_session_id] or 0) + 1
			if per[plan.logical_session_id] > config.SOURCE.PLANS then return false end
			local tasks = 0
			for _, cp in plan.checkpoints do
				if not closed(cp, "n title flags tasks") or not (cp.n == 0 or pos(cp.n)) or not str(cp.title, 256) or not config.texts(cp.flags, 16, 64)
					or not dense(cp.tasks, config.plan_parser.MAX_TASKS) then return false end
				for _, t in cp.tasks do
					tasks += 1
					if not closed(t, "id title independent sequential_why class template_id files checks systems flags text state work_id worker_id hold")
						or not str(t.id, 32) or not str(t.title, 256) or type(t.independent) ~= "boolean" or (t.sequential_why ~= nil and not str(t.sequential_why, 256))
						or (t.class ~= nil and not config.slug(t.class, 32)) or (t.template_id ~= nil and not config.slug(t.template_id, 32))
						or not config.texts(t.files, 64, 256) or not config.texts(t.systems, 16, 80) or not config.texts(t.flags, 16, 64) or not str(t.text, config.SOURCE.TASK_TEXT, true)
						or not config.list(t.checks, 16) or not table.find(config.TASK_STATES, t.state) or (t.work_id ~= nil and not id(t.work_id))
						or (t.worker_id ~= nil and not id(t.worker_id)) or (t.work_id == nil) ~= (t.worker_id == nil) or not config.valid_hold(t.hold)
						or ((t.state == "running" or t.state == "done") and t.work_id == nil) or (t.state == "held" and t.hold == nil) then return false end
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
			if not closed(rec, "intake_id logical_session_id kind ref path revision card_id class text tags state refusal work_id worker_id hold lane seq at_ms label")
				or not digest(key) or rec.intake_id ~= key or not registry.sessions[rec.logical_session_id] or (rec.kind ~= "board" and rec.kind ~= "inbox")
				or not wire_text(rec.ref, 1024) or not config.absolute(rec.path, 1024) or not digest(rec.revision) or (rec.card_id ~= nil and (not str(rec.card_id, 128) or rec.card_id:find("%c") ~= nil))
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
			if not closed(c, "chain_id logical_session_id status successes steps loop hold next_template at_ms") or not id(key) or c.chain_id ~= key
				or not registry.sessions[c.logical_session_id] or not table.find(config.CHAIN_STATUSES, c.status)
				or not (c.successes == 0 or pos(c.successes)) or c.successes > config.SOURCE.CHAIN_BOUND or not dense(c.steps, config.SOURCE.CHAIN_STEPS, 1)
				or not loops.valid(c.loop) or not config.valid_hold(c.hold) or (c.next_template ~= nil and not config.slug(c.next_template, 32))
				or (c.status == "capped" and c.next_template == nil) or not (c.at_ms == 0 or pos(c.at_ms)) then return false end
			for _, s in c.steps do
				if not closed(s, "template_id input state work_id worker_id output_ref hold") or not config.slug(s.template_id, 32)
					or not str(s.input, math.max(config.SOURCE.INPUT_BYTES, 256)) or not table.find(config.STEP_STATES, s.state)
					or (s.work_id ~= nil and not id(s.work_id)) or (s.work_id == nil) ~= (s.worker_id == nil) or (s.worker_id ~= nil and not id(s.worker_id))
					or (s.state ~= "held" and s.state ~= "failed" and s.work_id == nil) or (s.output_ref ~= nil and not config.relative(s.output_ref, 256))
					or not config.valid_hold(s.hold) then return false end
			end
		end
	end
	return true
end
-- A delivery record bound to this report's exact action and revision.
function config.same_action(x: any, report: any): any return x and x.action_id == report.action_id and x.action_revision == report.action_revision end
-- Report kinds only one ORCH+-set role may file: { role, refusal code, refusal message }.
config.REPORT_ROLES = { LABEL = { "labeller", "label_unauthorized", "Only an ORCH+ labeller worker reports LABEL, for the label_request it received." },
	LANDING_RESULT = { "release_manager", "landing_unauthorized",
		"Only the session's release manager reports LANDING_RESULT for the landing_grant it holds; builders never merge or report a landing result." },
	DEPLOY_RESULT = { "release_manager", "deploy_unauthorized", "Only the session's release manager reports DEPLOY_RESULT, for a deploy_grant it holds." } }
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
	if only and w.role ~= only[1] then return fail(only[2], only[3]) end
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
		refused = if policy(d, w.logical_session_id).paused then "session_paused" elseif not target_checkpoint then "scope_mismatch" else nil
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
		for _, entry in f.thread do if entry.kind == "WAITING" or entry.kind == "BLOCKED" then entry.state = "settled" end end
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
	-- The codec bounds context_used_pct to an integer 0..100; it is a worker report, never native fact.
	if (kind == "READY" or kind == "HEARTBEAT") and p.context_used_pct ~= nil then f.context = { used_pct = p.context_used_pct, seq = report.seq } end
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
	local refused -- Set when semantic intake refused a coordinator proposal definitely.
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
	local worker = trial.dispatch.workers[w.worker_id]
	local applied, err = intake_mutating(trial, worker, bytes, clock)
	if err then return nil, err end
	for key in w do w[key] = nil end
	for key, value in worker do w[key] = value end
	trial.dispatch.workers[w.worker_id] = w; n.dispatch.workers = trial.dispatch.workers
	n.dispatch.serial = trial.dispatch.serial; n.dispatch.gates = trial.dispatch.gates; n.dispatch.landing = trial.dispatch.landing; n.sessions = trial.sessions
	n.dispatch.reviews = trial.dispatch.reviews; n.dispatch.deploys = trial.dispatch.deploys; n.dispatch.intakes = trial.dispatch.intakes
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
	config.release_lanes(w, revoked)
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
	-- A completed effect that leaves the worker's lanes intact: note why, answer ok.
	local function noted(code: string, message: string): (any, nil)
		a.phase = "complete"; note_reason(w, { code = code, message = message })
		return { ok = true, code = code, message = message }, nil
	end
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
		-- SPAWN's exact pre-effect refusal of a stopped generation's retirement: nothing was removed, so
		-- the effect slot is released and the mailbox stays provisioned. The refused action stays the
		-- retirement marker, so the poll driver never loops; the sweep or the owner re-arms one attempt.
		if request.op == "mailbox_retire" and request.mode == "retire" and body.status == "rejected" and w and w.stopped
			and w.mailbox_retire_action_id == request.action_id and problem.code == "producer_unsettled" then
			return noted("retirement_refused", "SPAWN refused this stopped generation's mailbox retirement before any effect: its helper journal still holds pending reports or unacknowledged/unresolved control messages. Nothing was retired or retried; the mailbox stays provisioned. The nightly sweep or Retry mailbox retirement once… issues one fresh attempt.")
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
		-- SPAWN names the manifest digest it bound into this provision; it must be exactly the one this
		-- work stored at queue (or rebuilt for a successor), else the helpers would verify another manifest.
		if payload.manifest_sha256 ~= w.manifest_sha256 then
			return fail("manifest_mismatch", "SPAWN provisioned assignment manifest " .. tostring(payload.manifest_sha256) .. " but this work's stored manifest is "
				.. tostring(w.manifest_sha256) .. "; no launch is authorized.")
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
		config.usage_start(d, w, clock)
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
					.. "Coordinator authority covers only this assignment, not OS/account isolation. Use the launch-preface producer_helper/root/handle/enrolment_token. consume durably records the grant and reply_ack; claim before work. Retain owner_id, owner_generation, activation_token and action_id/action_revision outside the execution journal. Do not independently orchestrate Tern or start agents. ORCH+ accepts explicit READY/HEARTBEAT/WAITING/BLOCKED/ASK and structured CHECKPOINT evidence. Echo each report_request.payload.request_id in one HEARTBEAT or CHECKPOINT; reply_ack alone is not fulfillment. ASK payload is question, options [{id,label}], optional evidence [string]. Only after this activation ACK is accepted, COORDINATOR_PROPOSAL payload may contain owner_id, owner_generation, activation_token, proposal_id, kind, work_id, project_id. kind is dispatch/report/review/rollover/landing. Scope must already exist as registered session work and a retained CHECKPOINT project. dispatch additionally requires current configured record_id, record_revision, prompt and forbids checkpoint_id; report has no extra fields; review/rollover/landing require checkpoint_id. Every proposal becomes an owner gate, never a direct native/merge/account action. owner_decision must be consumed once with its exact gate/action revisions; approval is proposal data, not permission to run Tern or landing commands. An approved landing proposal is a decision record only: the project worker itself sends LANDING_REQUEST and lands only under its own landing_grant. An approved review proposal makes ORCH+ open a review by a fresh reviewer worker; coordinators never file REVIEW_RESULT. Pause/retirement forbids fresh proposals. Fulfill outstanding progress requests and settle owner decisions before release. When the assigned task finishes or typed retirement requests stop, quiesce and resolve genuinely completed control messages; never resolve unfinished or uncertain work. Report a JSON object with kind=COORDINATOR_RELEASE, issued action_id/action_revision, and payload containing exactly owner_id, owner_generation, activation_token, quiescent=true. Retirement forbids fresh work; if it races self-finish, claim and resolve it without a second release. Drain final receipts and available replies. With native-ask-v1, end the turn idle while awaiting notifications; never hold the turn open polling or waiting for control. Only worker-poll-v1 uses bounded wait. Unresolved executions block mailbox retirement. ORCH+/SPAWN own exact native stop and mailbox cleanup. DONE, idle and absence are never release." })
			if err then return nil, err end
			w.activation = grant
		end
	elseif request.op == "stop" then
		if body.status ~= "stopped" or not settled(w) or (w.coordinator_owner_id and not coordinator(n, w)) then return fail("stop_pending", "Exact stopped outcome and settled generation are required.") end
		w.stopped = clone(payload); w.reason = nil
		local exited = stamp(clock); exited.state = "exited"; flow(w).exit = exited
	elseif request.op == "mailbox_retire" then
		if request.mode == "retire" then
			-- A withdrawn rejected launch, or withdrawn fenced work, never had a producer: its unused
			-- mailbox retires without a stop.
			local withdrawn = (launch_rejected(d, w) or w.withdrawn ~= nil) and w.mailbox_retire_action_id == request.action_id
			if body.status ~= "retired" or not (withdrawn or (w.stopped and settled(w))) or (w.coordinator_owner_id and not withdrawn and not coordinator(n, w)) then
				return fail("transport_pending", "Exact stopped mailbox retirement is not confirmed.")
			end
			w.mailbox_retired = true; w.reason = nil
		elseif body.status ~= "compacted" and body.status ~= "already_compacted" then return fail("transport_pending", "Mailbox compaction is not confirmed.") end
		if request.report_floor == w.compacted_floor and request.reply_floor == w.reply_floor then w.compaction_pending = nil end
		config.discard_actions(d, function(id, previous)
			if not (previous.worker_id == w.worker_id and (previous.phase == "complete"
				or (previous.phase == "resolved" and previous.resolution and previous.resolution.evidence == "publication_readback"))) then return false end
			local operation = previous.request
			local settled = operation.op == "mailbox_publish_reply" and operation.reply_seq <= request.reply_floor
			if operation.op == "mailbox_publish_ack" then
				local ack = codec.strict_decode(tern.base64.decode(operation.ack_b64), 2048)
				settled = ack.seq <= request.report_floor
			elseif operation.op == "mailbox_retire" then
				settled = operation.mode == "compact" and operation.settlement_revision <= request.settlement_revision
			end
			return settled and not (w.wakes or {})[id]
		end)
		config.discard_actions(d, function(_, previous)
			return previous.worker_id == w.worker_id and (previous.phase == "complete" or (previous.phase == "resolved" and previous.resolution
				and previous.resolution.evidence ~= "operator_attested")) and previous.request.op == "native_wake"
				and not (w.wakes or {})[previous.request.target_action_id] and not d.actions[previous.request.target_action_id]
		end)
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
	config.discard_actions(d, function(_, a)
		return (a.phase == "complete" or (a.phase == "resolved" and a.resolution and a.resolution.evidence ~= "operator_attested"))
			and a.request.origin_binding.logical_session_id == session_id
			and (a.request.op == "mailbox_read" or a.request.op == "catalog")
	end)
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
	if a.claim.stale_gate_id == nil and a.worker_id and d.workers[a.worker_id] and minutes > 0 and age ~= nil and age >= minutes * 60000 then return "stale" end
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
	if not closed(event, "kind") or event.kind ~= "workflow_tick" or type(clock) ~= "table" or not valid_stamp(stamp(clock))
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
			if w then config.release_lanes(w, function(action_id) return action_id == action.request.action_id end) end
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
	if w.pane_binding or w.control_origin or w.accepted_event or w.handover_id or w.stopped or w.mailbox_retired or w.withdrawn
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
-- C1: `mailbox_retire` is nil only when no mailbox exists; otherwise `not_requested` before the
-- first cancel, then `retiring`, then `refused` after SPAWN's definite rejection (cancel again).
-- Once the cancel recorded `w.withdrawn`, its status evidence was consumed: no further read.
local function withdrawal_view(d: any, w: any): any?
	local key, a = fenced_unlaunched(d, w)
	local retire: string? = if a and w.mailbox_handle ~= nil then "not_requested" else nil
	local retiring = (w.withdrawn ~= nil or (not a and launch_rejected(d, w))) and not w.mailbox_retired
	if retiring then
		key = if w.withdrawn then w.withdrawn.action_id else w.launch_action_id
		a = d.actions[key]
		local prior = if w.mailbox_retire_action_id then d.actions[w.mailbox_retire_action_id] else nil
		-- `retiring` blocks another cancel; a definitely refused retirement may be cancelled again.
		retire = if not prior then "not_requested" elseif prior.phase == "complete" and prior.response and prior.response.status == "rejected" then "refused" else "retiring"
	end
	if not a then return nil end
	return { action_id = key, op = a.request.op, evidence = if w.withdrawn then w.withdrawn.evidence elseif a.resolution then a.resolution.evidence else "spawn_rejected",
		status_required = w.withdrawn == nil and status_required(a),
		request_id = a.request.request_id, origin_binding = clone(a.request.origin_binding), controller_generation = a.request.controller_generation,
		mailbox_retire = retire, mailbox_provisioned = w.mailbox_handle ~= nil }
end
-- SPAWN's read-only `status` of a fenced request, read by the window just before withdrawal. Only a
-- definitively unexecutable retained outcome qualifies: no record (`missing`), a terminal
-- `rejected`, or a retryable pre-effect `full` (also how SPAWN reports an unconsumed challenge past
-- its deadline or from an earlier host VM, which M.authorize refuses). A still-live challenge, an
-- operation in progress or any other outcome refuses. A later exact re-stage of the old request is
-- never authorized: SPAWN's window authorizes only an ORCH+ action it observes claimed on its exact
-- current route, and withdrawal removes the action or (with a provisioned mailbox) keeps it
-- resolved, never claimed again; SPAWN fences that launch entry when it retires the mailbox.
local function unexecutable_in_spawn(a: any, event: any): any?
	local refuse = config.refusal
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
	if not closed(event, "kind request_id orch_session_id origin controller_pane command command_seq record_id record_revision catalog_revision prompt cwd placement coordinator role class template_id files scope checks source base_ref action_id executor grant_id response_bytes query_bytes worker_id bytes expected_revision continuation_proof operator_verified reason policy expected_policy_sha256 template_put template_remove role_guidance_put pane_binding native_state delivery_error gate_id gate_revision choice_id answer observation_seq trigger landing_id landing_revision direction outcome target_revision capacity capacity_validation local_date catch_up attestation path board_path card_id text tags text_sha256 name content_sha256 input")
		or event.kind ~= "dispatch" or not id(event.request_id) or not authorized(registry, event.origin, event.controller_pane, event.command == "continue_controller")
		or event.orch_session_id ~= event.origin.logical_session_id then return fail("controller_mismatch", "Only the admitted active controller binding may dispatch in this origin.") end
	local specific = {
		catalog = "bytes", queue = "record_id record_revision catalog_revision prompt cwd placement coordinator role class template_id files scope checks source base_ref",
		adopt = "record_id record_revision catalog_revision prompt pane_binding attestation",
		claim = "action_id executor capacity_validation", result = "action_id executor grant_id response_bytes", lost = "action_id executor grant_id",
		read_missing = "action_id executor grant_id query_bytes response_bytes",
		capacity = "capacity", cancel_work = "worker_id query_bytes response_bytes",
		poll = "worker_id bytes", reply = "worker_id trigger", retire = "worker_id", finish = "worker_id", intake = "worker_id bytes", retry = "action_id trigger", readback_publication = "action_id",
		policy = "policy expected_policy_sha256 template_put template_remove role_guidance_put", pause = "", resume = "", observe = "worker_id pane_binding native_state delivery_error observation_seq",
		answer = "gate_id gate_revision choice_id answer", cancel_gate = "gate_id gate_revision", recheck_gate = "gate_id gate_revision",
		continue_controller = "expected_revision operator_verified", continue_worker = "worker_id pane_binding continuation_proof operator_verified",
		rollover = "worker_id trigger", cancel_rollover = "worker_id", reconcile_restored = "worker_id operator_verified", recheck_report = "worker_id",
		cancel_landing = "landing_id landing_revision", move_landing = "landing_id landing_revision direction",
		landing_lost = "landing_id landing_revision reason", reconcile_landing = "landing_id landing_revision outcome target_revision reason operator_verified",
		sweep = "local_date catch_up",
		plan_import = "path", board_intake = "board_path card_id text tags text_sha256", inbox_intake = "name content_sha256", template_start = "template_id input",
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
	if type(clock) == "table" and clock.reserved_capacity and (event.command == "catalog" or event.command == "queue" or event.command == "adopt" or event.command == "reply" or event.command == "rollover" or event.command == "capacity" or event.command == "sweep" or config.SOURCE_COMMANDS[event.command]) then
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
	local ordinary = event.command == "queue" or event.command == "adopt" or event.command == "catalog" or event.command == "reply" or event.command == "rollover" or event.command == "capacity" or event.command == "sweep" or config.SOURCE_COMMANDS[event.command] ~= nil
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
			-- The displayed policy's digest (projected as workflow.policy_sha256) fences stale editors.
			local forms = (if event.policy ~= nil then 1 else 0) + (if event.template_put ~= nil then 1 else 0) + (if event.template_remove ~= nil then 1 else 0)
				+ (if event.role_guidance_put ~= nil then 1 else 0)
			if forms ~= 1 then return fail("invalid_policy", "A policy edit carries exactly one of policy, template_put, template_remove or role_guidance_put.") end
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
			elseif event.role_guidance_put ~= nil then
				-- One role's guidance per edit, so a single edit never resends the whole map over the bridge.
				local entry = event.role_guidance_put
				if not closed(entry, "role text") or not table.find(config.ROLES, entry.role) or not str(entry.text, 1024, true) then
					return fail("invalid_policy", "Role guidance names one of builder, reviewer, release_manager, labeller or coordinator and at most 1024 bytes of UTF-8 text.")
				end
				p.role_guidance[entry.role] = entry.text
			end
		end
		if event.command == "policy" and event.policy ~= nil then
			if not closed(event.policy, config.keys.editable) or next(event.policy) == nil then return fail("invalid_policy", "Policy accepts only the documented session settings.") end
			for key, value in event.policy do p[key] = clone(value) end
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
			if not config.fits(p) then return fail("policy_too_large", "The saved session policy would exceed " .. tostring(config.MAX_BYTES) .. " bytes in canonical form; shorten templates or guidance. Nothing was saved.") end
			if not valid_policy(p) then return fail("invalid_policy", "Poll 1000..60000ms; heartbeat 5000..3600000ms; stale >= heartbeat and <=86400000ms; rollover threshold integer 1..99; quota reserve integer 0..99; evidence age 60000..900000ms; concurrency limit integer 0..32; each routing scope has at most 24 distinct explicit alternative record IDs (no wildcards); reports, rollover, coordinator rollover, quota routing, mailbox sweep and provider/account/model substitution are booleans; sweep time is local HH:MM (00:00–23:59); excluded workers are distinct; loop cap 1..10; review rounds 1..2; stale-claim minutes 0..1440; family map, reviewer/release/labeller records, checkout roots, approval kinds, work sources, lanes, routes, guidance and templates follow the Config v4 bounds.") end
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
						or e.revision ~= binding.evidence_revision or not row or not row.eligible or row.enabled ~= true or row.cwd ~= w.cwd or row.placement ~= w.placement
						or ((if rollover then rollover.kind == "coordinator" else q.coordinator) and not table.find(row.capabilities, "coordinator-control-v1")) or not assessed or assessed.status ~= "sufficient" then
						return fail("stale_gate", "Routing policy, catalog or USAGE evidence changed since this fallback was proposed, or the destination is no longer sufficient. Refresh capacity; nothing was approved.")
					end
					if rollover then
						q.approval = { policy_digest = binding.policy_digest, to = clone(binding.to), needs = binding.denied, gate_id = g.id }; q.rejected = nil
						answer = result("fallback_approved", { handover_id = rollover.id, worker_id = w.worker_id })
					else
						local busy = concurrency_problem(d, w.logical_session_id, p, { [w.worker_id] = true })
						if busy then return fail(busy.code, busy.message .. " Approve again once a reservation is released; nothing was approved.") end
						w.record_id = row.id; w.record_revision = row.revision; config.bind_family(d, w)
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
		-- A host-consumed answer resolved this gate just now (every branch refuses a non-pending one):
		-- record the question and choice as settled thread evidence that outlives gate reclamation.
		if event.command == "answer" and g.phase == "resolved" and g.answer and d.workers[w.worker_id] == w then
			local _, err = config.record_answer(d, w, g, clock); if err then return nil, err end
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
		-- (fenced_unlaunched). Nothing native ran; nothing is stopped, retried or re-sent. A mailbox
		-- provisioned for it is retired, never left in use (w.withdrawn records the fenced evidence).
		local w = d.workers[event.worker_id]
		if not w or w.logical_session_id ~= event.orch_session_id
			or w.origin_binding.owner_id ~= event.origin.owner_id or w.origin_binding.owner_generation ~= event.origin.owner_generation then
			return fail("worker_unbound", "Only this controller owner's never-launched work can be cancelled: held or gated routed work, work whose provision, launch or adoption continuation fenced as unexecuted, or work whose provision SPAWN rejected.")
		end
		local fenced_key, fenced = fenced_unlaunched(d, w)
		local evidence = event.query_bytes ~= nil or event.response_bytes ~= nil
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
			w.reason = { code = "withdrawal_retiring", message = "Owner cancelled this never-launched work. Its unused mailbox is being retired; the worker is removed once SPAWN confirms retirement." }
			answer = result("withdrawal_retiring", { worker_id = w.worker_id, work_id = w.work_id, action_id = request.action_id })
			return nil
		end
		-- A retirement already issued for this withdrawal: a pending or uncertain one never re-issues;
		-- none (a revoked authorization or continuation released its marker) or a definite refusal
		-- issues exactly one fresh retirement.
		local function retire_again(): any?
			local prior = if w.mailbox_retire_action_id then d.actions[w.mailbox_retire_action_id] else nil
			if prior and not (prior.phase == "complete" and prior.response and prior.response.status == "rejected") then
				local _, problem = fail("retirement_unresolved", "This work's mailbox retirement is " .. prior.phase .. "; inspect its exact retained outcome. No second retirement is issued.")
				return problem
			end
			return retire_unused()
		end
		if w.withdrawn ~= nil then
			-- Withdrawn fenced work: its fenced request was already proven unexecuted when the owner
			-- first cancelled, and that evidence was consumed.
			if evidence then return fail("invalid_command", "This work's fenced request was already proven unexecuted; cancelling again needs no status evidence.") end
			if w.mailbox_retired then return finish_command(n, event, result("worker_retired", { worker_id = w.worker_id })) end
			local problem = retire_again(); if problem then return nil, problem end
		elseif not fenced and launch_rejected(d, w) then
			-- SPAWN definitively rejected the launch/adoption ask after provisioning; a refused
			-- retirement keeps its outcome and may be cancelled again.
			if evidence then return fail("invalid_command", "SPAWN's retained launch rejection is terminal; withdrawal needs no status evidence.") end
			if w.mailbox_retired then return finish_command(n, event, result("worker_retired", { worker_id = w.worker_id })) end
			local problem = retire_again(); if problem then return nil, problem end
		elseif fenced and w.mailbox_handle ~= nil then
			-- Fenced provisioned work (launch or adoption ask proven unexecuted): its mailbox was
			-- provisioned but never used, so it is retired, never left counting against SPAWN's
			-- generations. The fenced action is kept (it is resolved): routing and the concurrency
			-- reservation keep treating the work as settled, and its exact request stays visible.
			if status_required(fenced) or evidence then
				if not evidence then return fail("status_required", "SPAWN received this fenced " .. fenced.request.op .. " request; its retained SPAWN status must be read first. Nothing was cancelled.") end
				local problem = unexecutable_in_spawn(fenced, event); if problem then return nil, problem end
			end
			for key, a in d.actions do
				if a.worker_id == w.worker_id and key ~= fenced_key and a.phase == "ready" and a.claim == nil then d.actions[key] = nil end
			end
			local problem = retire_unused(); if problem then return nil, problem end
			w.withdrawn = { op = fenced.request.op, action_id = fenced_key, evidence = fenced.resolution.evidence }
		else
			if fenced then
				if status_required(fenced) or evidence then
					if not evidence then return fail("status_required", "SPAWN received this fenced " .. fenced.request.op .. " request; its retained SPAWN status must be read first. Nothing was cancelled.") end
					local problem = unexecutable_in_spawn(fenced, event); if problem then return nil, problem end
				end
				-- A fenced coordinator start releases its never-bound orchestrator reservation in this commit.
				if bound then
					if unresolved then return fail("coordinator_unresolved", unresolved) end
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
	elseif config.SOURCE_COMMANDS[event.command] then
		-- Work sources (Checkpoint 6): non-operator intake commands; the host reads files itself.
		local handled, err = config.SOURCE_COMMANDS[event.command](registry, n, event, clock, reserve)
		if err then return nil, err end
		answer = handled
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
		local w = config.new_worker(d, event, event.orch_session_id, selected, event.prompt, event.request_id .. ":", if event.coordinator then "coordinator" else "builder")
		config.bind_family(d, w) -- Declared family of the requested record; recomputed if routing selects another.
		local assignment = config.assign(w, event); if assignment then return nil, assignment end
		-- D14: the typed task (ordinary work or coordinator start) carries its role's guidance too.
		w.prompt = config.guided(d, event.orch_session_id, w.role, event.prompt); w.assignment_sha256 = codec.sha256(w.prompt)
		if #tern.json.encode(launch_request(w, string.rep("h", 96))) > 8192 then
			return fail("oversize", "Assignment plus immutable launch binding cannot fit the 8192-byte bridge (including a maximum-length mailbox handle); no provisioning was queued.")
		end
		-- Queue-time checkout gates hold a never-provisioned worker until the owner answers them.
		local gate_ids, gate_err = config.queue_gates(d, w, clock); if gate_err then return nil, gate_err end
		if gate_ids then
			w.launch_gates = gate_ids; d.workers[w.worker_id] = w
			local _, problem = append(d, w, "assignment", w.prompt, clock); if problem then return nil, problem end
			answer = result("task_gated", { worker_id = w.worker_id, work_id = w.work_id, gate_ids = gate_ids,
				message = "Held before launch: answer the checkout gate(s) to launch anyway or cancel. Nothing was provisioned." })
		else
			local launched, err = config.launch(registry, n, w, event, clock, reserve, true); if err then return nil, err end
			answer = launched
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
		local w = config.new_worker(d, event, event.orch_session_id, selected, config.guided(d, event.orch_session_id, "builder", event.prompt), event.request_id .. ":", "builder")
		w.adopt_pane_binding = clone(event.pane_binding); config.bind_family(d, w)
		if #tern.json.encode(launch_request(w, string.rep("h", 96))) > 8192 then
			return fail("oversize", "Assignment plus immutable adoption binding cannot fit the 8192-byte bridge; nothing was provisioned.")
		end
		local request = common(d, event.origin, event.controller_pane, "mailbox_provision"); be(w, request)
		request.record_id = w.record_id; request.record_revision = w.record_revision; request.capability = "report-files-v1"
		if not add(d, request, w.worker_id) then return fail("oversize", "Provision request exceeds the bridge bound.") end
		d.workers[w.worker_id] = w
		answer = result("adoption_queued", { worker_id = w.worker_id, work_id = w.work_id, action_id = request.action_id })
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
		-- A capacity recheck's claim continues the action's stale-claim lineage: one gate per action.
		a.phase = "claimed"; a.claim = { executor = event.executor, epoch = registry.execution_epoch, grant_id = next_id(d, "grant-"), capacity = capacity_claim, claimed_at = stamp(clock),
			stale_gate_id = a.stale_gate_id }
		a.stale_gate_id = nil
		n.sessions[event.orch_session_id].controller.pending_executors += 1
		if target and target.coordinator_owner_id then
			local owner = n.sessions[event.orch_session_id].orchestrator
			if owner == nil or owner.owner_id ~= target.coordinator_owner_id or owner.generation ~= target.coordinator_generation
				or (owner.phase ~= "reserved" and owner.phase ~= "running" and owner.phase ~= "retiring"
					and not (owner.phase == "uncertain" and a.request.op == "attach_worker")) then return fail("owner_mismatch", "Coordinator reservation is no longer executable.") end
			if owner.phase == "retiring" and not table.find({ "accept", "mailbox_read", "mailbox_publish_ack", "mailbox_publish_reply", "mailbox_retire", "stop", "native_wake", "attach_worker" }, a.request.op) then
				return fail("coordinator_retiring", "Retirement permits settlement only, never fresh launch effects.")
			end
			if a.request.op == "stop" and (not settled(target) or owner.pending_executors ~= 0 or M.unresolved(registry, target.logical_session_id, owner.owner_id)) then
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
				local w = if a.worker_id then d.workers[a.worker_id] else nil
				local owner = n.sessions[event.orch_session_id].orchestrator
				config.release_executor(n.sessions[event.orch_session_id], w)
				if w and w.mailbox_retired and owner and owner.owner_id == w.coordinator_owner_id then
					owner.owner_active = false
					-- A withdrawn never-launched coordinator start was never bound: its retired mailbox ends the reservation.
					if (launch_rejected(d, w) or w.withdrawn ~= nil) and owner.phase == "reserved" and owner.managed_worker_id == w.worker_id then owner.managed_worker_id = nil end
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
		if event.trigger ~= nil and event.trigger ~= "owner" then return fail("invalid_command", "Retry trigger is the owner control; automatic capacity rechecks carry none.") end
		if not a or a.phase ~= "backpressure" or not equal(a.request.origin_binding, event.origin)
			or a.request.controller_pane ~= event.controller_pane or not a.response or a.response.status ~= "full"
			or not retryable_full(a.response.payload) then
			return fail("retry_refused", "Only the exact retained, definitively unexecuted full outcome may be rechecked. Uncertain effects cannot retry.")
		end
		-- Owner retries of a worker-bound action are a capped loop (Contract L); automatic capacity
		-- rechecks stay the window's time-bounded code-only wait. Worker-less reads have no gate owner.
		local w = if event.trigger == "owner" and a.worker_id then d.workers[a.worker_id] else nil
		local cap = if w then policy(d, w.logical_session_id).loop_cap else 0
		-- An owner "stop" answer is final for this loop: no resubmission and no new gate.
		if w and a.retry_loop and a.retry_loop.state == "stopped" then
			return fail("loop_stopped", "The owner stopped retries of this action at the loop cap; it stays unexecuted. Cancel the work to end it.")
		end
		if w and loops.trips(a.retry_loop, cap) then
			local loop = a.retry_loop
			local g, err = loops.open(d, w, loop, "full_retry", event.action_id, "Owner retry of full backpressure reached " .. tostring(loop.count)
				.. " attempts; last error: full:" .. a.response.payload.resource .. ". Action " .. event.action_id .. " (" .. a.request.op
				.. ") stays unexecuted and is not resubmitted. Allow more owner retries or keep it stopped.", cap, clock, true)
			if err then return nil, err end
			answer = result("loop_capped", { gate_id = g.id, action_id = event.action_id })
		else
			if w then a.retry_loop = a.retry_loop or { count = 0 }; a.retry_loop.count += 1 end
			a.stale_gate_id = a.claim.stale_gate_id
			a.phase = "ready"; a.claim = nil; a.response_grant = nil; a.retry_count = (a.retry_count or 0) + 1
			-- Keep the full response as evidence, but require a fresh status fence after resubmission.
			answer = result("retry_queued", { action_id = event.action_id })
		end
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
		config.release_executor(n.sessions[event.orch_session_id], w)
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
			advance_rollovers(n, event, clock, reserve); config.advance_proposals(registry, n, event, clock, reserve); config.advance_reviews(n, event, clock); advance_landing(n, event, clock); config.advance_deploys(n, event, clock); config.advance_sources(registry, n, event, clock, reserve)
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
			w.mailbox_retire_action_id = nil
			answer = result("retirement_rearmed", { worker_id = w.worker_id })
		elseif w.finish then return finish_command(n, event, result("finish_already_requested", { worker_id = w.worker_id }))
		else
			-- A labeller's intake pin never blocks finishing it: an unlabelled intake then retries (Contract L).
			if pending(d, w) or w.accept_pending or w.assembly or w.rejected_report or next(w.replies) or next(w.wakes or {}) or flow(w).report_request
				or (w.role ~= "labeller" and work_referenced(d, w)) then
				return fail("workflow_unsettled", "Finish cannot discard unresolved effects, decisions, deliveries, rejected reports or referenced review/rollover/landing evidence.")
			end
			w.finish = { request_id = event.request_id, seq = w.accepted_seq, revision = n.revision, source = clone(event.origin) }
			config.usage_end(d, w, clock)
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
			config.evict_terminal(d.rollovers, function(old) return ROLLOVER_TERMINAL[old.phase] end, 31)
			if count(d.rollovers) >= 32 then return fail("full", "Rollover capacity is full of unfinished handovers; none was discarded.") end
			local handover_id = next_id(d, "handover-")
			d.rollovers[handover_id] = { id = handover_id, kind = if w.coordinator_owner_id then "coordinator" else "worker", phase = "requested", trigger = event.trigger, logical_session_id = w.logical_session_id,
				work_id = w.work_id, predecessor_worker_id = w.worker_id, predecessor_pane_binding = clone(control_binding(w)),
				origin = clone(event.origin), controller_pane = event.controller_pane, controller_generation = event.origin.owner_generation,
				handover_token = codec.sha256(event.request_id .. ":" .. event.origin.alias_nonce .. ":" .. handover_id),
				history = { { phase = "requested", revision = n.revision, at_ms = stamp(clock).at_ms } }, context = clone(flow(w).context),
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
		if r.quota then close_quota_gate(d, r.quota, w); r.quota = nil end
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
					or (event.outcome ~= "deployed" and event.outcome ~= "not_deployed") or event.target_revision ~= nil then
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
				or (event.target_revision ~= nil and not landing_text(event.target_revision)) then
				return fail("reconciliation_required", "Reconcile only an uncertain granted landing: state the observed outcome (landed with the resulting target head, or not landed), a reason, and confirm the read-only target inspection.")
			end
			grant.reconciliation = { outcome = event.outcome, target_revision = event.target_revision, reason = event.reason,
				source = clone(event.origin), at_ms = stamp(clock).at_ms, revision = n.revision }
			q.slot = nil
			if event.target_revision ~= nil then q.head = { revision = event.target_revision, source = "owner", landing_id = item.id } end
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
	advance_rollovers(n, event, clock, reserve)
	config.advance_proposals(registry, n, event, clock, reserve)
	config.advance_reviews(n, event, clock)
	advance_landing(n, event, clock)
	config.advance_deploys(n, event, clock)
	config.advance_sources(registry, n, event, clock, reserve)
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
	local w = if a.worker_id then n.dispatch.workers[a.worker_id] else nil
	config.release_executor(n.sessions[event.orch_session_id], w)
	if w then
		w.phase = "held"; w.reason = { code = "executor_resolved", message = "Operator stopped/reconciled the retained executor; this does not retry or retire its worker." }
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
				retry_count = a.retry_count, retry_loop = clone(a.retry_loop), wake_status = wake_status, wake_pending = a.phase == "claimed" and wake_status ~= nil,
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
	-- policy_sha256 is the stale-editor fence the policy command expects (quota.digest of the saved policy).
	local workflow = { policy = clone(policy(d, session_id)), policy_sha256 = quota.digest(policy(d, session_id)), workers = {}, threads = {}, gates = {}, rollovers = {}, landing = {},
		capacity = clone(current_evidence(d, session_id)), sweep = clone((d.sweeps or {})[session_id]), reviews = {} }
	config.sources_view(d, session_id, workflow)
	for _, rv in d.reviews or {} do if rv.logical_session_id == session_id then table.insert(workflow.reviews, config.review_view(rv)) end end
	table.sort(workflow.reviews, function(a, b) return config.review_serial(a) < config.review_serial(b) end)
	workflow.release_manager = config.worker_ref(d, (config.release_manager(d, session_id) or {}).worker_id)
	-- Landing queues: open items in FIFO order, then the four most recent terminal items.
	local L = d.landing or { queues = {}, items = {} }
	for key, q in L.queues do
		if q.logical_session_id == session_id then
			local function view(item: any, position: number?): any
				local grant = item.grants[#item.grants]
				local current = landing_current(item)
				local before = if position and position > 1 then L.items[q.order[position - 1]] else nil
				local after = if position then L.items[q.order[position + 1]] else nil
				local out = { id = item.id, revision = item.revision, status = item.status, position = position, work_id = item.work_id, worker_id = item.worker_id,
					request = clone(item.request), gate_id = item.gate_id, approved = item.approval ~= nil, proof = clone(item.proof),
					hold = clone(item.hold), refresh_required = item.refresh_required == true, attempts = #item.grants,
					refresh_loop = clone(item.refresh_loop), grant_loop = clone(item.grant_loop),
					grant = if grant then { grant_id = grant.grant_id, target_revision = grant.target_revision, published = grant.published,
						acknowledged = grant.acknowledged, result = clone(grant.result), late_result = clone(grant.late_result),
						uncertain = clone(grant.uncertain), reconciliation = clone(grant.reconciliation), current = grant == current } else nil,
					uncertain = current ~= nil and current.uncertain ~= nil,
					cancellable = LANDING_UNGRANTED[item.status] == true,
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
				stop_observation = r.stop_observation, context = clone(r.context), checkpoint_loop = clone(r.checkpoint_loop),
				checkpoint = if cp then { checkpoint_id = cp.payload.checkpoint_id, artifact_revision = cp.payload.artifact_revision, task_ref = cp.payload.task_ref,
					completed = clone(cp.payload.completed), remaining = clone(cp.payload.remaining), holds = clone(cp.payload.holds), checks = clone(cp.payload.checks) } else nil,
				cancellable = not ROLLOVER_TERMINAL[r.phase] and rollover_cancellable(d, r), rerequestable = not ROLLOVER_TERMINAL[r.phase] and rollover_rerequestable(d, r) })
			local revision = r.history[#r.history].revision
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
				due_rollover = (rollover_due(registry, w, f)), rollover = (latest_rollover[w.worker_id] or {}).view,
				wake_pending_count = count(w.wakes or {}), wake_unstarted_count = wake_unstarted, wake_uncertain_count = wake_uncertain,
				orchestration_excluded = table.find(workflow.policy.excluded_workers, w.worker_id) ~= nil,
				context_used_pct = if f.context then f.context.used_pct else nil, context_seq = if f.context then f.context.seq else nil,
				restored = clone(w.restored), routing = clone(w.routing), launch_action_id = w.launch_action_id, adopt_pane_binding = clone(w.adopt_pane_binding),
				rejected_report = if w.rejected_report then { code = w.rejected_report.code, message = w.rejected_report.message } else nil,
				withdrawal = withdrawal_view(d, w),
				-- Contract A: role and declared (never verified) family; assignment fields as counts; usage
				-- readings are shown only as a delta (CP7), never raw.
				role = w.role, family = w.family or config.family_of(d, w), class = w.class, template_id = w.template_id,
				files_count = if w.files then #w.files else 0, checks_count = if w.checks then #w.checks else 0,
				scope = if w.scope then { paths = #w.scope.paths, systems = #w.scope.systems } else nil, source = clone(w.source),
				checkout = clone(w.checkout), check_results = clone(w.check_results), report_loop = clone(f.report_loop),
				-- Latest review of a builder's work (Task 3B card); a reviewer names the review it serves.
				review = if w.role == "builder" and config.review_of(d, w) then config.review_view(config.review_of(d, w) :: any) else nil,
				review_id = w.review_id, check_rework = clone(w.check_rework),
				-- D17: raw account readings for the views' quota.usage_delta (after is nil while running).
				usage_before = clone(w.usage_before), usage_after = clone(w.usage_after), usage_shared_with = config.usage_shared_with(d, w) })
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
