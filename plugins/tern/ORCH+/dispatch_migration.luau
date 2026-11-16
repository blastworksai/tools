--!strict
-- Read-only legacy/source comparison. Callers validate the complete owning store first.
local codec = require("./wire/codec")
local M = {}
local function same(a: any, b: any): boolean
	if type(a) ~= type(b) then return false end
	if type(a) ~= "table" then return a == b end
	for k, v in a do if not same(v, b[k]) then return false end end
	for k in b do if a[k] == nil then return false end end
	return true
end
local function copy(v: any): any
	if type(v) ~= "table" then return v end
	local out = {}; for k, child in v do out[k] = copy(child) end; return out
end
local function issue(message: string): any return { ok = false, code = "migration_blocked", message = message } end
local function closed(v: any, keys: string): boolean
	if type(v) ~= "table" or v == tern.json.null then return false end
	for key in v do if not (" " .. keys .. " "):find(" " .. tostring(key) .. " ", 1, true) then return false end end
	return true
end
local function text(v: any, maximum: number, empty: boolean?): boolean
	return type(v) == "string" and #v <= maximum and (empty == true or #v > 0) and utf8.len(v) ~= nil and not v:find("%z")
end
local function id(v: any): boolean return text(v, 96) and v:match("^[A-Za-z0-9_-]+$") ~= nil end
local function positive(v: any): boolean return type(v) == "number" and v >= 1 and v <= 9007199254740991 and v % 1 == 0 end
function M.selection(registry: any): any
	local sessions, handles = {}, {}
	for sid, session in registry.sessions do if session.admission_seq then sessions[sid] = true end end
	for _, worker in (registry.dispatch or {}).workers or {} do
		if worker.mailbox_handle and not worker.mailbox_retired then
			sessions[worker.logical_session_id] = true; handles[worker.mailbox_handle] = true
		end
	end
	local selected = { logical_session_ids = tern.json.array(), mailbox_handles = tern.json.array() }
	for sid in sessions do table.insert(selected.logical_session_ids, sid) end
	for handle in handles do table.insert(selected.mailbox_handles, handle) end
	table.sort(selected.logical_session_ids); table.sort(selected.mailbox_handles)
	return selected
end
function M.identity(registry: any, selection: any): (any?, any?, number, number)
	local normal = { schema = 1, sessions = tern.json.array(), workers = tern.json.array() }
	local d = registry.dispatch or { actions = {}, workers = {} }
	local pending, blockers = 0, 0
	for _, a in d.actions do
		if a.phase ~= "complete" then
			if a.claim or a.request_bytes then pending += 1 else blockers += 1 end
		end
	end
	for _, w in d.workers do
		if w.assembly or w.rejected_report or w.accept_pending or w.compaction_pending or next(w.receipts or {})
			or next(w.replies or {}) or next(w.wakes or {}) or w.restored or (w.workflow and w.workflow.report_request) then blockers += 1 end
		if not w.mailbox_handle and not w.mailbox_retired then blockers += 1 end
	end
	for _, g in d.gates or {} do
		if g.ruling or g.ruling_delivery or g.delivery_uncertain or g.phase == "answered" or (g.delivery and not g.delivery.acknowledged)
			or (g.execution and g.execution.state == "pending") then blockers += 1 end
	end
	for _, r in d.rollovers or {} do if r.phase ~= "complete" and r.phase ~= "cancelled" then blockers += 1 end end
	for _, item in (d.landing or {}).items or {} do
		for _, grant in item.grants or {} do
			if grant.uncertain or (not grant.result and not grant.reconciliation) then pending += 1 end
		end
	end
	for _, dp in d.deploys or {} do
		if dp.status == "granted" or dp.status == "held" or dp.status == "uncertain" then pending += 1 end
	end
	for _, s in registry.sessions do
		if s.close or s.bridge_control then blockers += 1 end
		for _, slot in { "controller", "orchestrator" } do
			local owner = s[slot]
			if owner and (owner.pending_executors > 0 or owner.recovery) then blockers += 1 end
		end
	end
	if not codec.validate_dispatch_migration_selection(selection) then
		return nil, issue("A fresh complete native peer identity selection is required."), pending, blockers + 1
	end
	local compared = {}
	for _, sid in selection.logical_session_ids do
		local s = registry.sessions[sid]
		if not s then return nil, issue("Peer session has no matching local current registration."), pending, blockers + 1 end
		local current = { logical_session_id = sid }
		if s.controller then
			local cursor = (d.command_cursors or {})[sid]
			local origin, pane = if cursor then cursor.origin else nil, if cursor then cursor.controller_pane else nil
			if not origin then
				for _, w in d.workers do
					if w.logical_session_id == sid then origin = w.control_origin or w.origin_binding; pane = w.control_pane or w.controller_pane; break end
				end
			end
			if not origin or origin.owner_id ~= s.controller.owner_id or origin.owner_generation ~= s.controller.generation
				or not s.controller.pane_binding or origin.host_pane_id ~= s.controller.pane_binding.host_pane_id
				or origin.alias_nonce ~= s.controller.pane_binding.alias_nonce then
				return nil, issue("Current native controller route is not independently proved by local state."), pending, blockers + 1
			end
			current.binding = copy(origin); current.controller_pane = pane
		end
		compared[sid] = true; table.insert(normal.sessions, current)
	end
	local by_handle = {}
	for _, w in d.workers do
		if w.mailbox_handle then
			if by_handle[w.mailbox_handle] then return nil, issue("Local mailbox identity is duplicated."), pending, blockers + 1 end
			by_handle[w.mailbox_handle] = w
		end
	end
	local found = {}
	for _, handle in selection.mailbox_handles do
		local w = by_handle[handle]
		if not w or not compared[w.logical_session_id] then return nil, issue("Peer mailbox has no matching local current worker."), pending, blockers + 1 end
		local current = { logical_session_id = w.logical_session_id, worker_id = w.worker_id, worker_generation = w.worker_generation,
			launch_request_id = w.launch_request_id, work_id = w.work_id, enrolment_sha256 = codec.sha256("orchplus-enrolment-v1\n" .. w.enrolment_token),
			mailbox_handle = w.mailbox_handle, record_id = w.record_id, record_revision = w.record_revision,
			binding_digest = w.binding_digest, mailbox_live = w.mailbox_retired ~= true }
		current.manifest_sha256 = w.manifest_sha256
		if w.handover_id then current.handover_id = w.handover_id; current.handover_sha256 = codec.sha256(w.handover_id .. ":" .. w.handover_token) end
		if w.capabilities then current.capabilities = tern.json.array(copy(w.capabilities)); table.sort(current.capabilities) end
		if w.pane_binding then
			current.execution_origin = copy(w.control_origin or w.origin_binding)
			current.execution_controller_pane = w.control_pane or w.controller_pane
			current.pane_binding = copy(w.control_pane_binding or w.pane_binding)
		end
		if w.stopped then current.stopped = w.stopped.observation end
		found[w.mailbox_handle] = true; table.insert(normal.workers, current)
	end
	for handle, w in by_handle do if not found[handle] and not w.mailbox_retired then blockers += 1 end end
	for sid, session in registry.sessions do if session.admission_seq and not compared[sid] then blockers += 1 end end
	table.sort(normal.sessions, function(a, b) return a.logical_session_id < b.logical_session_id end)
	table.sort(normal.workers, function(a, b) return a.mailbox_handle < b.mailbox_handle end)
	local digest, diagnostic = codec.dispatch_managed_digest(tern.json.encode(normal))
	if not digest then return nil, diagnostic, pending, blockers + 1 end
	return normal, nil, pending, blockers
end
function M.legacy_response(bytes: any, request: any): any?
	local prefix = "SPAWN_DISPATCH v1 "
	if type(bytes) ~= "string" or #bytes > 8192 or bytes:sub(1, #prefix) ~= prefix then return nil end
	local frame = codec.strict_decode(bytes:sub(#prefix + 1), 8192)
	if not frame or frame.schema ~= 1 or frame.complete ~= true or frame.op ~= request.op or frame.request_id ~= request.request_id
		or type(frame.body_json) ~= "string" or frame.body_bytes ~= #frame.body_json or frame.body_sha256 ~= codec.sha256(frame.body_json) then return nil end
	for k in frame do if not table.find({ "schema", "op", "request_id", "complete", "body_bytes", "body_sha256", "body_json" }, k) then return nil end end
	local body = codec.strict_decode(frame.body_json, 8192)
	if not body or body.schema ~= 1 or body.op ~= request.op or body.request_id ~= request.request_id or body.action_id ~= request.action_id
		or not same(body.origin_binding, request.origin_binding) or body.controller_generation ~= request.controller_generation then return nil end
	for k in body do if not table.find({ "schema", "op", "request_id", "action_id", "origin_binding", "controller_generation", "status", "payload", "error" }, k) then return nil end end
	-- This is the frozen C2 decoder contract, used only while validating the complete source.
	-- It does not emit v1 bytes or authorize a current request.
	if not text(body.status, 96) then return nil end
	if body.error ~= nil and (not closed(body.error, "code message detail") or not text(body.error.code, 96)
		or (body.error.message ~= nil and not text(body.error.message, 512, true))
		or (body.error.detail ~= nil and not text(body.error.detail, 512, true))) then return nil end
	if body.status == "full" then
		local p = body.payload
		if not closed(p, "resource current limit retryable effect_started") or not id(p.resource)
			or not (p.current == 0 or positive(p.current)) or not positive(p.limit)
			or not ((p.retryable == nil and p.effect_started == nil) or (type(p.retryable) == "boolean" and type(p.effect_started) == "boolean")) then return nil end
	end
	if body.status == "stopped" and (request.op ~= "stop" or not closed(body.payload, "pane_binding observation")
		or not same(body.payload.pane_binding, request.pane_binding) or not table.find({ "absent", "exited" }, body.payload.observation)) then return nil end
	if body.status == "attached" and (request.op ~= "attach_worker" or not closed(body.payload, "pane_binding previous_origin_binding previous_pane_binding")
		or not same(body.payload.pane_binding, request.pane_binding) or not same(body.payload.previous_origin_binding, request.previous_origin_binding)
		or not same(body.payload.previous_pane_binding, request.previous_pane_binding)) then return nil end
	if type(body.payload) == "table" and body.payload.wake_status == "awaiting_window" and body.payload.wake_effect_started == false
		and (not table.find({ "mailbox_publish_ack", "mailbox_publish_reply" }, request.op)
			or not id(body.payload.wake_target_request_id) or not id(body.payload.wake_target_action_id)) then return nil end
	return body
end
return M
