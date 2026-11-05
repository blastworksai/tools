--!strict

-- The host owns persistence. A candidate is never authority until its KV write succeeds.
local M = {}
local dispatch = require("./dispatch")
local MAX_INTEGER = 9007199254740991
local LIMITS = { sessions = 64, requests = 4096, settlement_reserve = 1024, retired = 2048, pending_executors = 1024 }
M.LIMITS = table.freeze(LIMITS)

local function absent(value: any): boolean
	return value == nil or value == tern.json.null
end

local function integer(value: any, minimum: number, maximum: number?): boolean
	return type(value) == "number" and value == value and value >= minimum
		and value <= (maximum or MAX_INTEGER) and value % 1 == 0
end

local function text(value: any, maximum: number): boolean
	return type(value) == "string" and #value > 0 and #value <= maximum and value:find("%c") == nil
end

local function copy(value: any): any
	if absent(value) then return nil end
	if type(value) ~= "table" then return value end
	local result = {}
	for key, child in value do result[key] = copy(child) end
	return result
end

local function equal(left: any, right: any): boolean
	if type(left) ~= type(right) then return false end
	if type(left) ~= "table" then return left == right end
	for key, value in left do if not equal(value, right[key]) then return false end end
	for key in right do if left[key] == nil then return false end end
	return true
end

local function count(value: any): number
	local n = 0
	for _ in value do n += 1 end
	return n
end

local function fields(raw: any, allowed: any): boolean
	if type(raw) ~= "table" or raw == tern.json.null then return false end
	for key in raw do if type(key) ~= "string" or not allowed[key] then return false end end
	return true
end

local function binding(raw: any): boolean
	if not fields(raw, { host_pane_id = true, alias_nonce = true, host_session_id = true, session_name = true, host_name = true }) then return false end
	if not text(raw.host_pane_id, 128) or not text(raw.alias_nonce, 128) then return false end
	for _, key in { "host_session_id", "session_name", "host_name" } do
		if not absent(raw[key]) and not text(raw[key], if key == "host_session_id" then 128 else 256) then return false end
	end
	return true
end

local validators: any = {
	request_id = function(v: any): boolean return text(v, 128) end,
	orch_session_id = function(v: any): boolean return text(v, 128) end,
	name = function(v: any): boolean return text(v, 256) end,
	binding = binding,
	pane_binding = binding,
	work_id = function(v: any): boolean return text(v, 128) end,
	target = function(v: any): boolean return v == "controller" or v == "orchestrator" end,
	expected_owner_id = function(v: any): boolean return text(v, 128) end,
	expected_generation = function(v: any): boolean return integer(v, 1) end,
	expected_revision = function(v: any): boolean return integer(v, 0) end,
	intent_id = function(v: any): boolean return text(v, 128) end,
	reason = function(v: any): boolean return text(v, 1000) end,
	status = function(v: any): boolean return text(v, 256) end,
	evidence = function(v: any): boolean return v == "observed" or v == "operator_attested" end,
	owner_active = function(v: any): boolean return type(v) == "boolean" end,
	pending_executors = function(v: any): boolean return integer(v, 0, LIMITS.pending_executors) end,
	operator_verified = function(v: any): boolean return v == true end,
	executors_verified = function(v: any): boolean return v == true end,
	quiescent = function(v: any): boolean return v == true end,
}

-- true = required; false = optional. Unknown fields are never part of a request identity.
local operations: any = {
	register_session = { name = true, binding = false },
	admit_controller = { pane_binding = true },
	reserve_coordinator = { work_id = false },
	bind_coordinator = { expected_owner_id = true, expected_generation = true, pane_binding = true },
	request_retirement = { expected_owner_id = true, expected_generation = true },
	release_coordinator = { expected_owner_id = true, expected_generation = true, quiescent = true },
	release_controller = { expected_owner_id = true, expected_generation = true },
	mark_uncertain = { target = true, expected_owner_id = true, expected_generation = true, reason = true },
	observe_owner = { target = true, expected_owner_id = true, expected_generation = true, status = true, evidence = true, owner_active = false, pending_executors = false, operator_verified = false, executors_verified = false },
	begin_recovery = { target = true, expected_owner_id = true, expected_generation = true, expected_revision = true },
	confirm_recovery = { target = true, expected_owner_id = true, expected_generation = true, expected_revision = true, intent_id = true, operator_verified = true, evidence = true },
}

local function decode_event(raw: any): any?
	if type(raw) ~= "table" or type(raw.kind) ~= "string" then return nil end
	local schema = operations[raw.kind]
	if schema == nil then return nil end
	local allowed: any = { kind = true, request_id = true }
	if raw.kind ~= "register_session" then allowed.orch_session_id = true end
	for key in schema do allowed[key] = true end
	if not fields(raw, allowed) or not validators.request_id(raw.request_id) then return nil end
	if raw.kind ~= "register_session" and not validators.orch_session_id(raw.orch_session_id) then return nil end
	for key, required in schema do
		if absent(raw[key]) then
			if required then return nil end
		elseif not validators[key](raw[key]) then return nil end
	end
	if raw.kind == "observe_owner" and raw.evidence == "operator_attested" and raw.operator_verified ~= true then return nil end
	if not absent(raw.executors_verified) and raw.evidence ~= "operator_attested" then return nil end
	return copy(raw)
end

local function response(ok: boolean, code: string, message: string, extra: any?): any
	local result: any = { ok = ok, code = code, message = message }
	if extra ~= nil then for key, value in extra do result[key] = copy(value) end end
	return result
end

function M.new_registry(): any
	return { version = 2, revision = 0, next_session_id = 0, next_owner_id = 0,
		execution_epoch = 1, sessions = {}, request_outcomes = {}, retired = {} }
end

function M.new_session(input: any): any
	return { orch_session_id = input.orch_session_id, name = input.name, binding = copy(input.binding),
		created_at_ms = input.created_at_ms, controller_generation = 0, orchestrator_generation = 0 }
end

local function valid_observation(raw: any): boolean
	return fields(raw, { status = true, evidence = true, at_ms = true, execution_epoch = true, reason = true })
		and text(raw.status, 256) and (raw.evidence == "observed" or raw.evidence == "operator_attested" or raw.evidence == "unavailable")
		and integer(raw.at_ms, 0) and integer(raw.execution_epoch, 1)
		and (absent(raw.reason) or text(raw.reason, 1000))
end

local function valid_recovery(raw: any, owner: any, registry: any): boolean
	return fields(raw, { intent_id = true, owner_id = true, generation = true, expected_revision = true, execution_epoch = true, at_ms = true })
		and text(raw.intent_id, 128) and raw.owner_id == owner.owner_id and raw.generation == owner.generation
		and integer(raw.expected_revision, 1, registry.revision) and integer(raw.execution_epoch, 1, registry.execution_epoch)
		and integer(raw.at_ms, 0)
end

local function valid_owner(raw: any, generation: number, registry: any): boolean
	if not fields(raw, { owner_id = true, generation = true, phase = true, pane_binding = true, work_id = true,
		created_at_ms = true, last_observation = true, owner_active = true, pending_executors = true, pending_executor_evidence = true, recovery = true, managed_worker_id = true }) then return false end
	if not text(raw.owner_id, 128) or not integer(raw.generation, 1) or raw.generation ~= generation then return false end
	if raw.phase ~= "reserved" and raw.phase ~= "active" and raw.phase ~= "running" and raw.phase ~= "retiring" and raw.phase ~= "uncertain" and raw.phase ~= "recovering" then return false end
	if not absent(raw.pane_binding) and not binding(raw.pane_binding) then return false end
	if raw.phase == "active" and absent(raw.pane_binding) then return false end
	if not absent(raw.managed_worker_id) and not text(raw.managed_worker_id, 96) then return false end
	if raw.phase == "running" and absent(raw.managed_worker_id) then return false end
	if not absent(raw.work_id) and not text(raw.work_id, 128) then return false end
	if not integer(raw.created_at_ms, 0) or not integer(raw.pending_executors, 0, LIMITS.pending_executors) then return false end
	if raw.pending_executor_evidence ~= "observed" and raw.pending_executor_evidence ~= "unconfirmed" and raw.pending_executor_evidence ~= "operator_attested" then return false end
	if not absent(raw.owner_active) and type(raw.owner_active) ~= "boolean" then return false end
	if not absent(raw.last_observation) and not valid_observation(raw.last_observation) then return false end
	if not absent(raw.recovery) and not valid_recovery(raw.recovery, raw, registry) then return false end
	return (raw.phase == "recovering") == (not absent(raw.recovery))
end

local function serial(value: any, prefix: string, maximum: number): boolean
	if type(value) ~= "string" then return false end
	local suffix = value:match("^" .. prefix .. "([1-9]%d*)$")
	return suffix ~= nil and integer(tonumber(suffix), 1, maximum)
end

local function target_for(event: any): string
	if event.kind == "admit_controller" or event.kind == "release_controller" then return "controller" end
	return event.target or "orchestrator"
end

local function valid_outcome(event: any, result: any, registry: any, owners: any): boolean
	local kind = event.kind
	if kind == "register_session" then
		local session = registry.sessions[result.orch_session_id]
		return result.code == "session_registered" and absent(result.owner) and absent(result.owner_id)
			and absent(result.generation) and absent(result.intent_id)
			and session.name == event.name and equal(copy(session.binding), event.binding)
	end
	local identity = owners[result.owner_id]
	if identity == nil or identity.orch_session_id ~= event.orch_session_id
		or identity.target ~= target_for(event) or identity.generation ~= result.generation then return false end
	if event.expected_owner_id ~= nil and (result.owner_id ~= event.expected_owner_id or result.generation ~= event.expected_generation) then return false end
	if event.expected_revision ~= nil and result.revision ~= event.expected_revision + 1 then return false end
	if kind == "release_controller" or kind == "release_coordinator" or kind == "confirm_recovery" then
		if not absent(result.owner) or not absent(result.intent_id) then return false end
		local retired = registry.retired[result.owner_id]
		if retired == nil then return false end
		if result.code == "already_retired" then
			return kind ~= "confirm_recovery" and result.revision > retired.revision
		end
		return result.code == "owner_retired" and retired.reason == kind and retired.revision == result.revision
			and copy(retired.evidence) == event.evidence
	end
	local owner = result.owner
	if not valid_owner(owner, result.generation, { revision = result.revision, execution_epoch = result.execution_epoch })
		or owner.owner_id ~= result.owner_id then return false end
	if absent(owner.recovery) then
		if not absent(result.intent_id) then return false end
	elseif result.intent_id ~= owner.recovery.intent_id then return false end
	if kind == "admit_controller" or kind == "reserve_coordinator" then
		local controller = kind == "admit_controller"
		return result.code == (if controller then "controller_granted" else "orchestrator_granted")
			and owner.phase == (if controller then "active" else "reserved")
			and equal(copy(owner.pane_binding), event.pane_binding) and copy(owner.work_id) == event.work_id
			and owner.owner_active == controller and owner.pending_executors == 0 and owner.pending_executor_evidence == "observed"
			and absent(owner.last_observation) and absent(owner.recovery)
	end
	if result.code ~= "accepted" then return false end
	if kind == "bind_coordinator" then
		return owner.phase == "active" and owner.owner_active == true and equal(copy(owner.pane_binding), event.pane_binding) and absent(owner.recovery)
	elseif kind == "request_retirement" then
		return owner.phase == "retiring" and absent(owner.recovery)
	elseif kind == "begin_recovery" then
		return owner.phase == "recovering" and owner.recovery.intent_id == "recovery-" .. string.format("%.0f", result.revision)
			and owner.recovery.expected_revision == result.revision and owner.recovery.execution_epoch == result.execution_epoch
	elseif kind == "mark_uncertain" or kind == "observe_owner" then
		local observation = owner.last_observation
		if absent(observation) or observation.execution_epoch ~= result.execution_epoch then return false end
		if kind == "mark_uncertain" then
			return owner.phase == "uncertain" and absent(owner.recovery) and observation.status == "uncertain"
				and observation.reason == event.reason and observation.evidence == "unavailable"
		end
		if observation.status ~= event.status or observation.evidence ~= event.evidence or not absent(observation.reason) then return false end
		if event.status == "unavailable" then
			if owner.phase ~= "uncertain" or not absent(owner.owner_active) or not absent(owner.recovery) then return false end
		elseif event.owner_active ~= nil and owner.owner_active ~= event.owner_active then return false end
		if event.pending_executors ~= nil and (owner.pending_executors ~= event.pending_executors or owner.pending_executor_evidence ~= event.evidence) then return false end
		return true
	end
	return false
end

local function valid_registry(raw: any, legacy_catalog_cache: boolean?): boolean
	if not fields(raw, { version = true, revision = true, next_session_id = true, next_owner_id = true,
		execution_epoch = true, sessions = true, request_outcomes = true, retired = true, dispatch = true }) then return false end
	if raw.version ~= 2 or not integer(raw.revision, 0) or not integer(raw.next_session_id, 0)
		or not integer(raw.next_owner_id, 0) or not integer(raw.execution_epoch, 1) then return false end
	for key, maximum in { sessions = LIMITS.sessions, request_outcomes = LIMITS.requests, retired = LIMITS.retired } do
		if type(raw[key]) ~= "table" or count(raw[key]) > maximum then return false end
	end
	local owners = {}
	for key, session in raw.sessions do
		if not serial(key, "orch%-", raw.next_session_id) or not fields(session, { orch_session_id = true, name = true, binding = true,
			created_at_ms = true, controller_generation = true, orchestrator_generation = true, controller = true, orchestrator = true }) then return false end
		if session.orch_session_id ~= key or not text(session.name, 256) or not integer(session.created_at_ms, 0)
			or not integer(session.controller_generation, 0) or not integer(session.orchestrator_generation, 0) then return false end
		if not absent(session.binding) and not binding(session.binding) then return false end
		for _, target in { "controller", "orchestrator" } do
			local owner = session[target]
			if absent(owner) then continue end
			if not valid_owner(owner, session[target .. "_generation"], raw) or not serial(owner.owner_id, "owner%-", raw.next_owner_id)
				or owners[owner.owner_id] then return false end
			owners[owner.owner_id] = { orch_session_id = key, target = target, generation = owner.generation }
		end
	end
	for key, retired in raw.retired do
		if not serial(key, "owner%-", raw.next_owner_id) or owners[key] or not fields(retired, { owner_id = true, orch_session_id = true,
			target = true, generation = true, pane_binding = true, work_id = true, retired_at_ms = true, reason = true, revision = true, evidence = true }) then return false end
		local session = raw.sessions[retired.orch_session_id]
		if retired.owner_id ~= key or session == nil or not validators.target(retired.target)
			or not integer(retired.generation, 1, session[retired.target .. "_generation"])
			or not integer(retired.retired_at_ms, 0) or not integer(retired.revision, 1, raw.revision)
			or not text(retired.reason, 128) then return false end
		if not absent(retired.pane_binding) and not binding(retired.pane_binding) then return false end
		if not absent(retired.work_id) and not text(retired.work_id, 128) then return false end
		if not absent(retired.evidence) and not validators.evidence(retired.evidence) then return false end
		owners[key] = { orch_session_id = retired.orch_session_id, target = retired.target, generation = retired.generation }
	end
	local recovery_intents, confirmations = {}, {}
	for key, outcome in raw.request_outcomes do
		if not text(key, 128) or not fields(outcome, { request = true, response = true }) then return false end
		local event = decode_event(outcome.request)
		local result = outcome.response
		if event == nil or event.request_id ~= key or not fields(result, { ok = true, code = true, message = true, request_id = true,
			orch_session_id = true, owner = true, owner_id = true, generation = true, revision = true, intent_id = true, execution_epoch = true }) then return false end
		if result.ok ~= true or not text(result.code, 128) or not text(result.message, 1000) or result.request_id ~= key
			or not integer(result.revision, 1, raw.revision) or not integer(result.execution_epoch, 1, raw.execution_epoch)
			or raw.sessions[result.orch_session_id] == nil then return false end
		if event.kind ~= "register_session" and event.orch_session_id ~= result.orch_session_id then return false end
		if not absent(result.owner_id) and not serial(result.owner_id, "owner%-", raw.next_owner_id) then return false end
		if not absent(result.generation) and not integer(result.generation, 1) then return false end
		if not absent(result.intent_id) and not text(result.intent_id, 128) then return false end
		if not valid_outcome(event, result, raw, owners) then return false end
		if event.kind == "begin_recovery" then
			if recovery_intents[result.intent_id] ~= nil then return false end
			recovery_intents[result.intent_id] = outcome
		elseif event.kind == "confirm_recovery" then table.insert(confirmations, outcome) end
	end
	for _, confirmation in confirmations do
		local event, result = confirmation.request, confirmation.response
		local intent = recovery_intents[event.intent_id]
		if intent == nil or intent.request.orch_session_id ~= event.orch_session_id or intent.request.target ~= event.target
			or intent.response.owner_id ~= result.owner_id or intent.response.generation ~= result.generation
			or intent.response.revision ~= event.expected_revision or intent.response.execution_epoch + 1 ~= result.execution_epoch then return false end
	end
	return dispatch.valid(raw.dispatch, raw, legacy_catalog_cache)
end

function M.rehydrate(raw: any): (any?, any?)
	if absent(raw) then return nil, response(false, "state_missing", "Authority state is missing; explicit initialization or recovery is required.") end
	if type(raw) == "table" and raw.version ~= 2 then
		return nil, response(false, "migration_required", "Stored schema is unsupported; retain it for explicit migration.")
	end
	if not valid_registry(raw, true) then return nil, response(false, "state_corrupt", "Authority state is invalid; no empty registry was substituted.") end
	if raw.execution_epoch == MAX_INTEGER or raw.revision == MAX_INTEGER then
		return nil, response(false, "capacity_reached", "Authority counters are exhausted; explicit migration is required.")
	end
	local restored = copy(raw)
	restored.execution_epoch += 1
	restored.revision += 1
	dispatch.restore(restored.dispatch)
	for _, session in restored.sessions do
		for _, target in { "controller", "orchestrator" } do
			local owner = session[target]
			if owner == nil then continue end
			owner.phase = "uncertain"
			owner.recovery = nil
			owner.pending_executor_evidence = "unconfirmed"
			if owner.owner_active == false then owner.owner_active = nil end
			-- Keep the last observation and known active/executor evidence, but never treat
			-- pre-restart evidence as permission to resume or relinquish this slot.
		end
	end
	return restored, response(true, "restored_uncertain", "Restored ownership remains occupied; persist the new epoch before publishing.")
end


function M.apply(registry: any, raw: any, clock: any?): (any?, any)
	if type(raw) == "table" and raw.kind == "dispatch" then return dispatch.apply(registry, raw, clock, M.apply) end
	if type(raw) == "table" and raw.kind == "dispatch_reconcile" then return dispatch.reconcile(registry, raw) end
	if type(raw) == "table" and raw.kind == "workflow_tick" then return dispatch.tick(registry, raw, clock) end
	local event = decode_event(raw)
	if event == nil then return nil, response(false, "invalid_event", "Invalid operation fields or bounds.") end
	local prior = registry.request_outcomes[event.request_id]
	if prior ~= nil then
		if not equal(prior.request, event) then return nil, response(false, "request_conflict", "This request ID already names different committed input.") end
		local replay = copy(prior.response)
		replay.replayed = true
		return registry, replay
	end
	local now = if type(clock) == "table" then clock.now_ms else clock
	if now == nil then now = 0 end
	if not integer(now, 0) then return nil, response(false, "invalid_clock", "The audit clock must be a nonnegative integer.") end
	local kind = event.kind
	local request_count = count(registry.request_outcomes)
	local ordinary_limit = LIMITS.requests - LIMITS.settlement_reserve
	local in_reserve = request_count >= ordinary_limit or (type(clock) == "table" and clock.reserved_capacity == true)
	if request_count >= LIMITS.requests or registry.revision == MAX_INTEGER then
		return nil, response(false, "capacity_reached", "Durable settlement capacity is full; no history was evicted.")
	end
	local session = if kind == "register_session" then nil else registry.sessions[event.orch_session_id]
	if kind ~= "register_session" and session == nil then return nil, response(false, "session_not_found", "Choose an existing logical session registration.") end
	local target = target_for(event)
	local owner = if session ~= nil then session[target] else nil
	local retired = if event.expected_owner_id ~= nil then registry.retired[event.expected_owner_id] else nil
	local already_retired = (kind == "release_coordinator" or kind == "release_controller") and retired ~= nil
		and retired.orch_session_id == event.orch_session_id and retired.target == target and retired.generation == event.expected_generation
	if event.expected_owner_id ~= nil and not already_retired then
		if owner == nil or owner.owner_id ~= event.expected_owner_id or owner.generation ~= event.expected_generation then
			return nil, response(false, "owner_mismatch", "The recorded owner or generation changed; inspect the current owner.", { owner = owner, revision = registry.revision })
		end
	end
	if event.expected_revision ~= nil and event.expected_revision ~= registry.revision then
		return nil, response(false, "stale_revision", "Authority changed after inspection; inspect and confirm again.", { revision = registry.revision })
	end
	if in_reserve then
		local settlement = kind == "request_retirement" or kind == "begin_recovery" or kind == "confirm_recovery"
			or kind == "release_controller" or kind == "release_coordinator" or kind == "bind_coordinator"
		if kind == "observe_owner" then
			local observation = owner.last_observation
			local unavailable = event.status == "unavailable" and owner.owner_active ~= false
				and (owner.owner_active ~= nil or owner.phase ~= "uncertain" or owner.recovery ~= nil
					or observation == nil or observation.status ~= "unavailable" or observation.execution_epoch ~= registry.execution_epoch)
			local activity_changed = event.owner_active ~= nil and event.owner_active ~= owner.owner_active
			local executors_changed = event.pending_executors ~= nil and (event.pending_executors ~= owner.pending_executors
				or owner.pending_executor_evidence == "unconfirmed")
			if not unavailable and not activity_changed and not executors_changed then
				return nil, response(false, "no_progress", "Repeated observation cannot consume reserved settlement capacity.")
			end
		elseif not settlement then
			return nil, response(false, "capacity_reached", "Ordinary request capacity is full; settlement space remains reserved.")
		end
		if already_retired then
			return nil, response(false, "owner_already_retired", "This exact owner is already retired; replay its committed release request instead of consuming settlement space.")
		end
		if kind == "request_retirement" and owner.phase == "retiring" then
			return nil, response(false, "no_progress", "Retirement is already requested; no additional outcome is needed.")
		end
		-- Serialize reserved recovery preparation/confirmation so alternating windows
		-- cannot burn the reserve by continually superseding each other's intents.
		-- The scope is the whole authority, not one session: an intent is bound to the global
		-- revision, so any other session's settlement would invalidate it and force another
		-- reserved begin. Genuine safety evidence and one-shot reservation completions are never
		-- blocked by this serialization; either may invalidate an older intent.
		if kind ~= "observe_owner" and kind ~= "bind_coordinator" then
			for id, registered in registry.sessions do
				for _, slot in { "controller", "orchestrator" } do
					local held = registered[slot]
					local intent = if held ~= nil then held.recovery else nil
					if intent ~= nil and intent.expected_revision == registry.revision and intent.execution_epoch == registry.execution_epoch
						and not (kind == "confirm_recovery" and event.orch_session_id == id and target == slot and event.expected_owner_id == held.owner_id) then
						return nil, response(false, "settlement_pending", string.format("Settlement reserve is in use: session %s %s owner %s holds pending recovery intent %s, and reserved settlements run one at a time. "
							.. "Confirm it in the view that began it, or reload the ORCH+ host, which withdraws every pending intent without using the reserve; a fresh safety observation also supersedes it.",
							id, slot, held.owner_id, intent.intent_id), { owner = held, orch_session_id = id, target = slot, intent_id = intent.intent_id, revision = registry.revision })
					end
				end
			end
		end
	end
	if kind == "begin_recovery" and (in_reserve or request_count >= ordinary_limit - 1) then
		if owner.pending_executors > 0 then return nil, response(false, "pending_executors", "Reconcile executor evidence before consuming reserved recovery preparation.") end
		if owner.owner_active == true then return nil, response(false, "owner_active", "Resolve current active-owner evidence before consuming reserved recovery preparation.") end
	end
	if kind == "admit_controller" or kind == "reserve_coordinator" then
		target = if kind == "admit_controller" then "controller" else "orchestrator"
		owner = session[target]
		if owner ~= nil then return nil, response(false, target .. "_slot_occupied", "The durable slot is occupied; reveal or inspect its recorded owner.", { owner = owner, orch_session_id = session.orch_session_id, revision = registry.revision }) end
		if registry.next_owner_id == MAX_INTEGER or session[target .. "_generation"] == MAX_INTEGER then
			return nil, response(false, "capacity_reached", "Owner counters are exhausted.")
		end
	end
	if kind == "register_session" and (count(registry.sessions) >= LIMITS.sessions or registry.next_session_id == MAX_INTEGER) then
		return nil, response(false, "capacity_reached", "Session registration capacity is full.")
	end
	if not already_retired and owner ~= nil then
		if kind == "observe_owner" then
			if event.pending_executors ~= nil and event.pending_executors < owner.pending_executors
				and dispatch.unresolved(registry, event.orch_session_id, event.expected_owner_id) then
				return nil, response(false, "dispatch_executor_unresolved", "Resolve each exact retained dispatch action/executor before reducing its inspection count.")
			end
			if event.status == "unavailable" and (event.evidence ~= "observed" or event.owner_active ~= nil or event.pending_executors ~= nil) then
				return nil, response(false, "invalid_event", "Unavailable observation cannot assert stop or executor settlement.")
			end
			if event.evidence == "operator_attested" then
				if event.pending_executors ~= nil and event.pending_executors < owner.pending_executors then
					local unavailable = owner.last_observation ~= nil and owner.last_observation.status == "unavailable" and owner.owner_active == nil
					if owner.pending_executor_evidence ~= "unconfirmed" or not unavailable or event.executors_verified ~= true then
						return nil, response(false, "pending_executors", "Current executor evidence blocks recovery; stale unavailable evidence requires explicit executor reconciliation.")
					end
				end
				if owner.owner_active == true and event.owner_active == false then
					return nil, response(false, "owner_active", "A known-active owner requires an observed stop or genuinely unavailable evidence before external verification.")
				end
			end
		end
		if (kind == "bind_coordinator" or kind == "request_retirement" or kind == "release_coordinator" or kind == "release_controller") and owner.phase == "recovering" then
			return nil, response(false, "recovery_fenced", "A recovery intent fences this owner; finish explicit recovery.")
		end
		if kind == "bind_coordinator" and (owner.phase ~= "reserved" or owner.pane_binding ~= nil) then
			return nil, response(false, "not_reserved", "Only an unchanged pane-less reservation can bind a coordinator.")
		end
		if kind == "release_coordinator" then
			if owner.managed_worker_id then
				local worker = if registry.dispatch then registry.dispatch.workers[owner.managed_worker_id] else nil
				if not worker or worker.coordinator_owner_id ~= owner.owner_id or worker.coordinator_generation ~= owner.generation
					or not worker.release or not worker.stopped or worker.mailbox_retired ~= true then
					return nil, response(false, "managed_retirement_incomplete", "Managed coordinator release requires its authenticated release, exact native stop and committed mailbox retirement.")
				end
			end
			if owner.pending_executors > 0 then return nil, response(false, "pending_executors", "Outstanding executors must be reconciled before release.") end
			if owner.owner_active ~= false then return nil, response(false, "owner_active", "Release requires observed or operator-attested quiescence.") end
			if owner.phase ~= "retiring" and owner.phase ~= "reserved" then return nil, response(false, "not_retiring", "Request retirement before releasing this coordinator.") end
		elseif kind == "release_controller" and owner.pending_executors > 0 then
			return nil, response(false, "pending_executors", "Outstanding controller executors prevent release.")
		elseif kind == "confirm_recovery" then
			local intent = owner.recovery
			if intent == nil or intent.intent_id ~= event.intent_id or intent.expected_revision ~= registry.revision
				or intent.execution_epoch ~= registry.execution_epoch then return nil, response(false, "stale_recovery", "The recovery intent is absent or changed; begin a fresh inspection.") end
			if owner.pending_executors > 0 then return nil, response(false, "pending_executors", "Known pending executors cannot be overridden by confirmation.") end
			if owner.owner_active == true then return nil, response(false, "owner_active", "The known-active owner must stop or retire before confirmation.") end
			if owner.owner_active == nil and event.evidence ~= "operator_attested" then return nil, response(false, "verification_required", "Unavailable owner evidence requires explicit external operator verification.") end
			if session[target .. "_generation"] == MAX_INTEGER or registry.execution_epoch == MAX_INTEGER then
				return nil, response(false, "capacity_reached", "Recovery counters are exhausted.")
			end
		end
	end
	local clearing = not already_retired and (kind == "release_coordinator" or kind == "release_controller" or kind == "confirm_recovery")
	if clearing and dispatch.unresolved(registry, event.orch_session_id, event.expected_owner_id) then
		return nil, response(false, "dispatch_executor_unresolved", "Reconcile each retained dispatch action/grant before clearing this owner; an inspection count is not its executor ledger.")
	end
	if clearing and count(registry.retired) >= LIMITS.retired then
		return nil, response(false, "capacity_reached", "Retired-owner history is full; no fencing history was evicted.")
	end

	-- Validation is complete. Copy only the changed registry branches; old authority and
	-- all returned projections remain independent of the candidate's mutable records.
	local next_state = table.clone(registry)
	next_state.sessions = table.clone(registry.sessions)
	next_state.request_outcomes = table.clone(registry.request_outcomes)
	next_state.revision += 1
	local changed = if session ~= nil then copy(session) else nil
	if changed ~= nil then next_state.sessions[changed.orch_session_id] = changed end
	local code, message = "accepted", "Operation committed."
	if kind == "register_session" then
		next_state.next_session_id += 1
		changed = M.new_session({ orch_session_id = "orch-" .. string.format("%.0f", next_state.next_session_id), name = event.name,
			binding = event.binding, created_at_ms = now })
		next_state.sessions[changed.orch_session_id] = changed
		code, message = "session_registered", "Logical session registered; no agent was started."
	elseif kind == "admit_controller" or kind == "reserve_coordinator" then
		next_state.next_owner_id += 1
		changed[target .. "_generation"] += 1
		changed[target] = { owner_id = "owner-" .. string.format("%.0f", next_state.next_owner_id), generation = changed[target .. "_generation"],
			phase = if target == "controller" then "active" else "reserved", pane_binding = copy(event.pane_binding), work_id = event.work_id,
			created_at_ms = now, owner_active = target == "controller", pending_executors = 0, pending_executor_evidence = "observed" }
		code, message = target .. "_granted", "Durable ownership granted; no native launch was performed."
	elseif already_retired then
		code, message = "already_retired", "This exact owner is already retired; any successor is unchanged."
	elseif clearing then
		next_state.retired = table.clone(registry.retired)
		next_state.retired[owner.owner_id] = { owner_id = owner.owner_id, orch_session_id = session.orch_session_id, target = target,
			generation = owner.generation, pane_binding = copy(owner.pane_binding), work_id = owner.work_id,
			retired_at_ms = now, reason = kind, revision = next_state.revision, evidence = event.evidence }
		changed[target] = nil
		if kind == "confirm_recovery" then
			changed[target .. "_generation"] += 1
			next_state.execution_epoch += 1
		end
		code, message = "owner_retired", "Exact ownership retired; replacement requires a separate guarded request."
	else
		local updated = changed[target]
		if kind == "bind_coordinator" then
			updated.pane_binding = copy(event.pane_binding)
			updated.phase = "active"
			updated.owner_active = true
		elseif kind == "request_retirement" then
			updated.phase = "retiring"
		elseif kind == "mark_uncertain" then
			updated.phase = "uncertain"
			updated.recovery = nil
			updated.last_observation = { status = "uncertain", reason = event.reason, evidence = "unavailable", at_ms = now, execution_epoch = registry.execution_epoch }
		elseif kind == "observe_owner" then
			if event.status == "unavailable" then
				updated.owner_active = nil
				updated.phase = "uncertain"
				updated.recovery = nil
			elseif event.owner_active ~= nil then updated.owner_active = event.owner_active end
			if event.pending_executors ~= nil then
				updated.pending_executors = event.pending_executors
				updated.pending_executor_evidence = event.evidence
			end
			updated.last_observation = { status = event.status, evidence = event.evidence, at_ms = now, execution_epoch = registry.execution_epoch }
		elseif kind == "begin_recovery" then
			updated.phase = "recovering"
			updated.recovery = { intent_id = "recovery-" .. string.format("%.0f", next_state.revision), owner_id = owner.owner_id, generation = owner.generation,
				expected_revision = next_state.revision, execution_epoch = registry.execution_epoch, at_ms = now }
		end
	end
	local result_owner = if kind == "register_session" or clearing or already_retired then nil else changed[target]
	local result = response(true, code, message, { request_id = event.request_id, orch_session_id = changed.orch_session_id,
		owner = result_owner, owner_id = if result_owner ~= nil then result_owner.owner_id else event.expected_owner_id,
		generation = if result_owner ~= nil then result_owner.generation else event.expected_generation,
		revision = next_state.revision, execution_epoch = next_state.execution_epoch,
		intent_id = if result_owner ~= nil and result_owner.recovery ~= nil then result_owner.recovery.intent_id else nil })
	next_state.request_outcomes[event.request_id] = { request = event, response = copy(result) }
	return next_state, result
end

function M.project(registry: any, request: any?): any
	local result: any = { version = 2, revision = registry.revision, execution_epoch = registry.execution_epoch,
		sessions = tern.json.array(), retired_count = count(registry.retired), request_count = count(registry.request_outcomes) }
	local ids = {}
	for id in registry.sessions do table.insert(ids, id) end
	table.sort(ids)
	for _, id in ids do table.insert(result.sessions, copy(registry.sessions[id])) end
	if type(request) == "table" and text(request.orch_session_id, 128) then result.session = copy(registry.sessions[request.orch_session_id]) end
	return result
end

return M
