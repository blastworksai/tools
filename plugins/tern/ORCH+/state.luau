--!strict

-- The host owns persistence. A candidate is never authority until its KV write succeeds.
local M = {}
local dispatch = require("./dispatch")
local codec = require("./wire/codec")
local MAX_INTEGER = 9007199254740991
local LIMITS = { sessions = 64, pending_executors = 1024 }
M.LIMITS = table.freeze(LIMITS)
local ISSUED_OPS = { catalog = true, launch = true, adopt = true, enrol = true, accept = true, stop = true, native_wake = true,
	attach_worker = true, mailbox_provision = true, mailbox_read = true, mailbox_publish_ack = true,
	mailbox_publish_reply = true, mailbox_retire = true }
local OUTSTANDING_PHASES = { pending = true, claimed = true, launching = true, current_result = true, uncertain = true }

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
	local length, count = #value, 0
	local array = length > 0
	for key in value do
		count += 1
		if type(key) ~= "number" or key % 1 ~= 0 or key < 1 or key > length then array = false end
	end
	if count == 0 then array = tern.json.encode(value) == "[]" else array = array and count == length end
	-- Preserve protected native array shape and the existing absent-value normalization.
	local result = if array then tern.json.array() else {}
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
	orch_session_id = function(v: any): boolean return text(v, 96) and v:match("^[A-Za-z0-9_-]+$") ~= nil end,
	authority_namespace = function(v: any): boolean return text(v, 128) end,
	close_id = function(v: any): boolean return text(v, 96) and v:match("^[%w_-]+$") ~= nil end,
	control_origin = function(v: any): boolean return codec.validate_dispatch_control_origin(v) and v.kind == "closing" end,
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
	attempt_id = function(v: any): boolean return text(v, 96) and v:match("^[%w_-]+$") ~= nil end,
	request_bytes = function(v: any): boolean return text(v, codec.FORGET.limit) end,
	response_bytes = function(v: any): boolean return text(v, codec.FORGET.limit + 64) end,
	preview = function(v: any): boolean
		return type(v) == "table" and fields(v, { spawn_boot = true, dispatch_revision = true }) and text(v.spawn_boot, 96)
			and integer(v.dispatch_revision, 0)
	end,
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
	begin_close = { close_id = true, control_origin = false },
	confirm_close = { close_id = true },
	-- Explicit forget (SKILLS-205). Never a cancel: once persisted, only supersede (recovery) or complete exist.
	begin_forget = { attempt_id = true, control_origin = true, request_bytes = false, preview = false },
	supersede_forget = { attempt_id = true, control_origin = true, request_bytes = true, preview = true },
	complete_forget = { attempt_id = true, response_bytes = true },
}

local function decode_event(raw: any): any?
	if type(raw) ~= "table" or type(raw.kind) ~= "string" then return nil end
	local schema = operations[raw.kind]
	if schema == nil then return nil end
	local allowed: any = { kind = true, request_id = true, orch_session_id = true, authority_namespace = true, expected_revision = true }
	for key in schema do allowed[key] = true end
	if not fields(raw, allowed) or not validators.request_id(raw.request_id)
		or not validators.authority_namespace(raw.authority_namespace) or not validators.expected_revision(raw.expected_revision)
		or not validators.orch_session_id(raw.orch_session_id) then return nil end
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

local SETUP_STATES = { not_started = true, in_progress = true, completed = true, dismissed = true, adopted_existing = true }
local function new_setup(existing: boolean): any
	return { schema = 1, state = if existing then "in_progress" else "not_started", config_revision = 0,
		review_existing = existing, readiness = { state = "not_run", config_revision = 0, summary = "" } }
end

local function new_defaults(): any
	return { revision = 0, defined = false, policy = dispatch.default_policy(), builder_record = "", coordinator_record = "" }
end

local function absolute(value: any): boolean
	return text(value, 512) and (value:sub(1, 1) == "/" or value:match("^%a:[\\/]") ~= nil)
end

local function valid_repository(value: any): boolean
	return fields(value, { cwd = true, repo_root = true, common_dir = true, target_ref = true, head_revision = true, queue_route = true })
		and absolute(value.cwd) and absolute(value.repo_root) and absolute(value.common_dir)
		and text(value.target_ref, 256) and value.target_ref:sub(1, 1) ~= "-"
		and type(value.head_revision) == "string" and (#value.head_revision == 40 or #value.head_revision == 64)
		and value.head_revision:match("^[a-f0-9]+$") ~= nil
		and (value.queue_route == "repository_queue" or value.queue_route == "orch_queue")
end

local function valid_defaults(value: any, legacy: boolean?): boolean
	return fields(value, { revision = true, defined = true, policy = true, builder_record = true, coordinator_record = true, family_migrations = true, repository = legacy == true })
		and integer(value.revision, 0) and dispatch.valid_policy(value.policy, legacy or dispatch.upgradable_policy(value.policy) or dispatch.previous_policy(value.policy))
		and (value.defined == nil or type(value.defined) == "boolean")
		and (value.family_migrations == nil or dispatch.valid_family_declarations(value.family_migrations))
		and (legacy == true or (value.policy.paused == false and next(value.policy.excluded_workers or {}) == nil))
		and (value.builder_record == "" or text(value.builder_record, 96))
		and (value.coordinator_record == "" or text(value.coordinator_record, 96))
		and (legacy == true or dispatch.upgradable_policy(value.policy)
			or (value.builder_record == value.policy.preferred_worker_record and value.coordinator_record == value.policy.preferred_orchestrator_record))
		and (absent(value.repository) or (legacy == true and valid_repository(value.repository)))
end

local function valid_readiness(value: any, revision: number): boolean
	return fields(value, { state = true, config_revision = true, summary = true })
		and (value.state == "not_run" or value.state == "passed" or value.state == "failed" or value.state == "unavailable")
		and integer(value.config_revision, 0, revision) and type(value.summary) == "string" and #value.summary <= 1024
		and value.summary:find("%c") == nil
end

local function valid_setup(value: any, revision: number, spawn: boolean?): boolean
	local allowed = { schema = true, state = true, config_revision = true, readiness = true }
	if not spawn then allowed.review_existing = true end
	return fields(value, allowed) and value.schema == 1 and SETUP_STATES[value.state] == true
		and value.config_revision == revision and valid_readiness(value.readiness, revision)
		and (spawn or type(value.review_existing) == "boolean")
end

-- Catalog observations are consumed, never copied into ORCH's settings authority.
local function setup_requirements(defaults: any, event: any): boolean
	local p, setup = defaults.policy, event.spawn_setup
	if defaults.builder_record == ""
		or event.catalog_version ~= 2 or type(setup) ~= "table" or not integer(setup.config_revision, 0)
		or not valid_setup(setup, setup.config_revision, true)
		or (setup.state ~= "completed" and setup.state ~= "adopted_existing") then return false end
	if type(event.records) ~= "table" or #event.records > 32 or count(event.records) ~= #event.records then return false end
	local rows = {}
	for _, row in event.records do
		if type(row) ~= "table" or not text(row.id, 96) or (rows[row.id] ~= nil and not equal(rows[row.id], row)) or not integer(row.revision, 0)
			or type(row.capabilities) ~= "table" or #row.capabilities > 32 or count(row.capabilities) ~= #row.capabilities then return false end
		for _, capability in row.capabilities do if not text(capability, 96) then return false end end
		rows[row.id] = row
	end
	local function eligible(id: string, capability: string?): boolean
		local row = rows[id]
		return row ~= nil and row.enabled == true and row.eligible == true
			and table.find(row.capabilities, "report-files-v1") ~= nil
			and (capability == nil or table.find(row.capabilities, capability) ~= nil)
	end
	if not eligible(defaults.builder_record)
		or (p.merge_actor_mode == "selected_record" and p.release_manager_record ~= "" and (p.release_manager_record == defaults.builder_record or not eligible(p.release_manager_record, "release-manager-v1")))
		or (defaults.coordinator_record ~= "" and not eligible(defaults.coordinator_record, "coordinator-control-v1")) then return false end
	if p.require_code_review then
		if #p.reviewer_records == 0 then return false end
		local builder_family = rows[defaults.builder_record].provider_family
		local available = false
		for _, id in p.reviewer_records do
			if id == defaults.builder_record or (p.merge_actor_mode == "selected_record" and id == p.release_manager_record) then return false end
			local row = rows[id]
			local family = if row then row.provider_family else nil
			if eligible(id)
				and (not p.require_other_family or (text(builder_family, 96) and text(family, 96) and family ~= builder_family)) then available = true end
		end
		if not available then return false end
	end
	return true
end

local function apply_setup(registry: any, event: any, clock: any?): (any?, any)
	local defaults, setup = registry.installation_defaults, registry.setup
	local allowed = { kind = true, request_id = true, authority_namespace = true, expected_revision = true, expected_config_revision = true }
	if event.kind == "installation_defaults" then allowed.defaults = true
	else
		allowed.state = true; allowed.readiness = true; allowed.catalog_version = true
		allowed.spawn_setup = true; allowed.records = true; allowed.readiness_policy = true
	end
	if not fields(event, allowed) or not text(event.request_id, 128) or not integer(event.expected_config_revision, 0) then
		return nil, response(false, "invalid_event", "Setup requires a closed revision-fenced operation.")
	end
	if event.expected_config_revision ~= defaults.revision then
		return nil, response(false, "stale_revision", "Installation defaults changed. Reload them before saving.", { config_revision = defaults.revision })
	end
	if defaults.revision == MAX_INTEGER or registry.revision == MAX_INTEGER or (type(clock) == "table" and clock.reserved_capacity == true) then
		return nil, response(false, "capacity_reached", "Installation settings cannot consume reserved authority capacity.")
	end
	local next_defaults, next_setup = defaults, copy(setup)
	if event.kind == "installation_defaults" then
		if not fields(event.defaults, { policy = true, builder_record = true, coordinator_record = true }) then
			return nil, response(false, "invalid_defaults", "Defaults contain reusable policy and agent selections only; repositories belong to projects.")
		end
		next_defaults = copy(event.defaults)
		next_defaults.revision = defaults.revision
		next_defaults.defined = true
		next_defaults.family_migrations = copy(defaults.family_migrations)
		if type(next_defaults.policy) == "table" and next_defaults.policy.require_code_review == false then next_defaults.policy.require_other_family = false end
		if type(next_defaults.policy) == "table" then
			next_defaults.policy.excluded_workers = {}; next_defaults.policy.paused = false
			next_defaults.policy.checkout_roots = {}
			if next_defaults.policy.preferred_worker_record ~= next_defaults.builder_record
				or next_defaults.policy.preferred_orchestrator_record ~= next_defaults.coordinator_record then
				return nil, response(false, "invalid_defaults", "Preferred agent selections conflict with the reusable agent references. Reload settings and save one consistent choice.")
			end
		end
		if not dispatch.valid_policy(next_defaults.policy, nil, defaults.policy) or not valid_defaults(next_defaults) then return nil, response(false, "invalid_defaults", "Installation defaults have invalid fields or bounds.") end
		if equal(next_defaults, defaults) then return registry, response(true, "no_progress", "Installation defaults are unchanged.", { config_revision = defaults.revision, revision = registry.revision }) end
	else
		if (event.state == nil) == (event.readiness == nil) then
			return nil, response(false, "invalid_event", "Choose a lifecycle transition or an independent readiness result.")
		end
		if event.state ~= nil then
			if event.readiness_policy ~= nil then return nil, response(false, "invalid_event", "Policy fences apply only to readiness results.") end
			if not SETUP_STATES[event.state] or event.state == "not_started" then return nil, response(false, "invalid_setup", "Setup cannot be reset to first use.") end
			if event.state == "completed" or event.state == "adopted_existing" then
				if (event.state == "adopted_existing") ~= setup.review_existing or not setup_requirements(defaults, event) then
					return nil, response(false, "setup_incomplete", "Choose eligible agents and complete SPAWN setup. Repository and release-manager requirements apply only to landing work.")
				end
				next_setup.review_existing = false
			elseif event.catalog_version ~= nil or event.spawn_setup ~= nil or event.records ~= nil then
				return nil, response(false, "invalid_event", "Only completion consumes SPAWN catalog observations.")
			end
			next_setup.state = event.state
		else
			if event.catalog_version ~= nil or event.spawn_setup ~= nil or event.records ~= nil or not valid_readiness(event.readiness, defaults.revision)
				or event.readiness.config_revision ~= defaults.revision then
				return nil, response(false, "invalid_readiness", "Readiness must describe an exercise of the current configuration.")
			end
			local fence = event.readiness_policy
			if fence ~= nil and (not fields(fence, { logical_session_id = true, revision = true })
				or not text(fence.logical_session_id, 96) or not integer(fence.revision, 0)) then
				return nil, response(false, "invalid_readiness", "Readiness requires a closed session policy revision fence.")
			end
			if event.readiness.state == "passed" or fence ~= nil then
				if not fence or not registry.sessions[fence.logical_session_id]
					or dispatch.policy_revision(registry, fence.logical_session_id) ~= fence.revision
					or not equal(dispatch.policy(registry, fence.logical_session_id), defaults.policy) then
					return nil, response(false, "stale_policy", "Session policy changed during readiness; the original policy was not qualified.")
				end
			end
			next_setup.readiness = copy(event.readiness)
		end
		if equal(next_setup, setup) then return registry, response(true, "no_progress", "Setup is unchanged.", { config_revision = defaults.revision, revision = registry.revision }) end
		next_defaults = if event.readiness ~= nil then defaults else table.clone(defaults)
	end
	if event.readiness == nil then
		next_defaults.revision += 1
		next_setup.config_revision = next_defaults.revision
	end
	local candidate = table.clone(registry)
	candidate.revision += 1
	candidate.setup, candidate.installation_defaults = next_setup, next_defaults
	return candidate, response(true, "setup_saved", "Installation settings saved. Live session policy is unchanged; checkout, target and queue choices belong to each project.",
		{ config_revision = next_defaults.revision, revision = candidate.revision })
end

function M.new_namespace(): string
	return string.format("orch-%d-%08x-%08x-%08x", os.time(), math.random(1, 2147483647), math.random(1, 2147483647), math.random(1, 2147483647))
end

function M.new_registry(namespace: string?): any
	return { version = 5, authority_namespace = namespace or M.new_namespace(), revision = 0, next_admission_seq = 1, next_owner_id = 0,
		execution_epoch = 1, sessions = {}, setup = new_setup(false), installation_defaults = new_defaults() }
end

function M.new_session(input: any): any
	return { orch_session_id = input.orch_session_id, name = input.name, binding = copy(input.binding), phase = "open",
		created_at_ms = input.created_at_ms, controller_generation = 0, orchestrator_generation = 0,
		generation_floor = 0, request_floor = 1, next_request_serial = 1, last_authority_revision = 0 }
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


local function valid_registry(raw: any, local_v4: boolean?): boolean
	if not fields(raw, { version = true, authority_namespace = true, revision = true, next_admission_seq = true, next_owner_id = true,
		execution_epoch = true, sessions = true, dispatch = true, setup = true, installation_defaults = true, compatibility = true, migration = true,
		forgotten = true })
		or raw.version ~= (if local_v4 then 4 else 5) or not validators.authority_namespace(raw.authority_namespace)
		or not integer(raw.revision, 0) or not integer(raw.next_admission_seq, 1) or not integer(raw.next_owner_id, 0)
		or not integer(raw.execution_epoch, 1) or not valid_defaults(raw.installation_defaults, local_v4)
		or raw.installation_defaults.revision > raw.revision or not valid_setup(raw.setup, raw.installation_defaults.revision)
		or type(raw.sessions) ~= "table" or raw.sessions == tern.json.null or count(raw.sessions) > LIMITS.sessions then return false end
	-- Installation-level, bounded completion notice of the last forgotten orchestration.
	if raw.forgotten ~= nil and (not fields(raw.forgotten, { name = true, revision = true, orch_session_id = true }) or not text(raw.forgotten.name, 256)
		or not validators.orch_session_id(raw.forgotten.orch_session_id)
		or not integer(raw.forgotten.revision, 1, raw.revision)) then return false end
	if raw.compatibility ~= nil and (not codec.validate_dispatch_compatibility(raw.compatibility)
		or raw.compatibility.kind ~= "current" or raw.compatibility.authority_namespace ~= raw.authority_namespace) then return false end
	if raw.migration ~= nil and (raw.compatibility ~= nil or not codec.validate_dispatch_compatibility(raw.migration)
		or raw.migration.kind ~= "migration" or raw.migration.orch.candidate_namespace ~= raw.authority_namespace) then return false end
	local owners, admissions = {}, {}
	for key, session in raw.sessions do
		if not text(key, 96) or key:match("^[%w_-]+$") == nil or not fields(session, { orch_session_id = true, name = true, binding = true,
			created_at_ms = true, controller_generation = true, orchestrator_generation = true, controller = true, orchestrator = true,
			phase = true, generation_floor = true, request_floor = true, next_request_serial = true, last_authority_revision = true,
			admission_seq = true, admitted = true, spawn_namespace = true, close = true, bridge_control = true, peer_outstanding = true, outstanding_cursor = true }) then return false end
		if session.orch_session_id ~= key or not text(session.name, 256) or not integer(session.created_at_ms, 0)
			or not integer(session.controller_generation, 0) or not integer(session.orchestrator_generation, 0)
			or not integer(session.generation_floor, 0, session.controller_generation)
			or not integer(session.next_request_serial, 1) or not integer(session.request_floor, 1, session.next_request_serial)
			or not integer(session.last_authority_revision, 0, raw.revision)
			or (session.phase ~= "open" and session.phase ~= "closing") then return false end
		if session.binding ~= nil and not binding(session.binding) then return false end
		if session.admission_seq ~= nil then
			if not integer(session.admission_seq, 1, raw.next_admission_seq - 1) or admissions[session.admission_seq] then return false end
			admissions[session.admission_seq] = true
		end
		if session.admitted ~= nil and (session.admitted ~= true or session.admission_seq == nil or not text(session.spawn_namespace, 128)) then return false end
		if session.spawn_namespace ~= nil and not text(session.spawn_namespace, 128) then return false end
		if (session.phase == "closing") ~= (session.close ~= nil) then return false end
		if session.close ~= nil then
			local close = session.close
			if not fields(close, { close_id = true, control_origin = true, peer_closed = true, forget = true }) or not validators.close_id(close.close_id)
				or type(close.peer_closed) ~= "boolean" then return false end
			if close.forget ~= nil then
				local forget = close.forget
				if not fields(forget, { attempt_id = true, request_bytes = true, preview = true }) or not validators.attempt_id(forget.attempt_id)
					or forget.attempt_id ~= close.close_id or close.control_origin == nil or close.peer_closed ~= false
					or not validators.request_bytes(forget.request_bytes) or not validators.preview(forget.preview) then return false end
				local request = codec.decode_forget_request(forget.request_bytes)
				if request == nil or request.op ~= "discard_session" or request.attempt_id ~= forget.attempt_id
					or request.logical_session_id ~= key or request.admission_seq ~= session.admission_seq
					or request.dispatch_revision ~= forget.preview.dispatch_revision or request.spawn_boot ~= forget.preview.spawn_boot then return false end
			end
			if close.control_origin ~= nil and (not validators.control_origin(close.control_origin)
				or close.control_origin.close_id ~= close.close_id or close.control_origin.binding.logical_session_id ~= key) then return false end
			if session.admission_seq ~= nil and close.control_origin == nil then return false end
		end
		if session.bridge_control ~= nil then
			local control = session.bridge_control
			if not fields(control, { request = true, request_bytes = true }) or type(control.request_bytes) ~= "string" then return false end
			local request = codec.decode_dispatch_request(control.request_bytes)
			if not request or not equal(request, control.request) or request.authority_namespace ~= raw.authority_namespace
				or request.logical_session_id ~= key or request.admission_seq ~= session.admission_seq
				or (request.op ~= "admit_session" and request.op ~= "reconcile_session" and request.op ~= "close_session") then return false end
		end
		local cursor = session.outstanding_cursor
		if cursor ~= nil and (not fields(cursor, { after_serial = true, through_serial = true })
			or not integer(cursor.after_serial, 0) or not integer(cursor.through_serial, cursor.after_serial)) then return false end
		local page = session.peer_outstanding
		if page ~= nil then
			if not fields(page, { after_serial = true, through_serial = true, next_after_serial = true, complete = true, entries = true })
				or not integer(page.after_serial, 0) or not integer(page.through_serial, page.after_serial)
				or not integer(page.next_after_serial, page.after_serial, page.through_serial) or type(page.complete) ~= "boolean"
				or type(page.entries) ~= "table" or #page.entries > 32 or count(page.entries) ~= #page.entries then return false end
			local previous = page.after_serial
			for _, entry in page.entries do
				if not fields(entry, { request_serial = true, request_id = true, action_id = true, op = true, phase = true })
					or not integer(entry.request_serial, previous + 1, page.through_serial)
					or not validators.orch_session_id(entry.request_id) or not validators.orch_session_id(entry.action_id) or not ISSUED_OPS[entry.op]
					or not OUTSTANDING_PHASES[entry.phase] then return false end
				previous = entry.request_serial
			end
			if page.complete then
				if page.next_after_serial ~= page.through_serial then return false end
			elseif #page.entries == 0 or page.next_after_serial ~= previous or previous >= page.through_serial then return false end
		end
		for _, target in { "controller", "orchestrator" } do
			local owner = session[target]
			if owner == nil then continue end
			if not valid_owner(owner, session[target .. "_generation"], raw) or not serial(owner.owner_id, "owner%-", raw.next_owner_id)
				or owners[owner.owner_id] or (target == "controller" and owner.generation <= session.generation_floor) then return false end
			owners[owner.owner_id] = true
		end
	end
	return dispatch.valid(raw.dispatch, raw)
end
M.valid = valid_registry

-- Legacy v2 has no installation metadata; v3 requires both setup and defaults.
-- Validate the original source without upgrading it or changing its proof identity.
-- Completed records are inspected here but never copied into the current authority.
local function valid_legacy(raw: any): boolean
	if not fields(raw, { version = true, revision = true, next_session_id = true, next_owner_id = true,
		execution_epoch = true, sessions = true, request_outcomes = true, retired = true, dispatch = true,
		setup = true, installation_defaults = true }) or (raw.version ~= 2 and raw.version ~= 3)
		or not integer(raw.revision, 0) or not integer(raw.next_session_id, 0) or not integer(raw.next_owner_id, 0)
		or not integer(raw.execution_epoch, 1) then return false end
	if raw.version == 2 then
		if raw.setup ~= nil or raw.installation_defaults ~= nil then return false end
	elseif not valid_defaults(raw.installation_defaults, true) or raw.installation_defaults.revision > raw.revision
		or not valid_setup(raw.setup, raw.installation_defaults.revision) then return false end
	for key, maximum in { sessions = 64, request_outcomes = 4096, retired = 2048 } do
		if type(raw[key]) ~= "table" or raw[key] == tern.json.null or count(raw[key]) > maximum then return false end
	end
	local owners = {}
	for key, session in raw.sessions do
		if not serial(key, "orch%-", raw.next_session_id) or not fields(session, { orch_session_id = true, name = true, binding = true,
			created_at_ms = true, controller_generation = true, orchestrator_generation = true, controller = true, orchestrator = true })
			or session.orch_session_id ~= key or not text(session.name, 256) or not integer(session.created_at_ms, 0)
			or not integer(session.controller_generation, 0) or not integer(session.orchestrator_generation, 0)
			or (session.binding ~= nil and not binding(session.binding)) then return false end
		for _, target in { "controller", "orchestrator" } do
			local owner = session[target]
			if owner == nil then continue end
			if not valid_owner(owner, session[target .. "_generation"], raw) or not serial(owner.owner_id, "owner%-", raw.next_owner_id)
				or owners[owner.owner_id] then return false end
			owners[owner.owner_id] = { session = key, target = target, generation = owner.generation }
		end
	end
	for key, retired in raw.retired do
		if not serial(key, "owner%-", raw.next_owner_id) or owners[key] or not fields(retired, { owner_id = true, orch_session_id = true,
			target = true, generation = true, pane_binding = true, work_id = true, retired_at_ms = true, reason = true, revision = true, evidence = true }) then return false end
		local session = raw.sessions[retired.orch_session_id]
		if retired.owner_id ~= key or session == nil or not validators.target(retired.target)
			or not integer(retired.generation, 1, session[retired.target .. "_generation"])
			or not integer(retired.retired_at_ms, 0) or not integer(retired.revision, 1, raw.revision)
			or not text(retired.reason, 128) or (retired.pane_binding ~= nil and not binding(retired.pane_binding))
			or (retired.work_id ~= nil and not text(retired.work_id, 128))
			or (retired.evidence ~= nil and not validators.evidence(retired.evidence)) then return false end
		owners[key] = { session = retired.orch_session_id, target = retired.target, generation = retired.generation }
	end
	local intents = {}
	for key, outcome in raw.request_outcomes do
		if not text(key, 128) or not fields(outcome, { request = true, response = true }) then return false end
		local event, result = outcome.request, outcome.response
		if type(event) ~= "table" or event.kind == "begin_close" or event.kind == "confirm_close" then return false end
		local schema = operations[event.kind]
		if schema == nil then return false end
		local allowed = { kind = true, request_id = true }
		if event.kind ~= "register_session" then allowed.orch_session_id = true end
		for field in schema do allowed[field] = true end
		if not fields(event, allowed) or event.request_id ~= key then return false end
		for field, required in schema do
			if event[field] == nil then if required then return false end
			elseif not validators[field](event[field]) then return false end
		end
		if event.kind == "observe_owner" and event.evidence == "operator_attested" and event.operator_verified ~= true then return false end
		if event.executors_verified ~= nil and event.evidence ~= "operator_attested" then return false end
		if not fields(result, { ok = true, code = true, message = true, request_id = true, orch_session_id = true,
			owner = true, owner_id = true, generation = true, revision = true, intent_id = true, execution_epoch = true })
			or result.ok ~= true or result.request_id ~= key or not text(result.code, 128) or not text(result.message, 1000)
			or not integer(result.revision, 1, raw.revision) or not integer(result.execution_epoch, 1, raw.execution_epoch)
			or raw.sessions[result.orch_session_id] == nil then return false end
		if event.kind == "register_session" then
			local session = raw.sessions[result.orch_session_id]
			if result.code ~= "session_registered" or session.name ~= event.name or not equal(session.binding, event.binding)
				or result.owner ~= nil or result.owner_id ~= nil or result.generation ~= nil or result.intent_id ~= nil then return false end
		else
			local identity = owners[result.owner_id]
			if event.orch_session_id ~= result.orch_session_id or identity == nil or identity.session ~= event.orch_session_id
				or identity.target ~= target_for(event) or identity.generation ~= result.generation
				or (event.expected_owner_id ~= nil and (event.expected_owner_id ~= result.owner_id or event.expected_generation ~= result.generation))
				or (event.expected_revision ~= nil and result.revision ~= event.expected_revision + 1) then return false end
			local clearing = event.kind == "release_controller" or event.kind == "release_coordinator" or event.kind == "confirm_recovery"
			if clearing then
				local retired = raw.retired[result.owner_id]
				if retired == nil or result.owner ~= nil or result.intent_id ~= nil
					or (result.code ~= "owner_retired" and result.code ~= "already_retired") then return false end
				if result.code == "owner_retired" and (retired.reason ~= event.kind or retired.revision ~= result.revision or retired.evidence ~= event.evidence) then return false end
				if result.code == "already_retired" and (event.kind == "confirm_recovery" or result.revision <= retired.revision) then return false end
			else
				if not valid_owner(result.owner, result.generation, { revision = result.revision, execution_epoch = result.execution_epoch })
					or result.owner.owner_id ~= result.owner_id then return false end
				local expected_code = if event.kind == "admit_controller" then "controller_granted"
					elseif event.kind == "reserve_coordinator" then "orchestrator_granted" else "accepted"
				if result.code ~= expected_code then return false end
				if result.owner.recovery then
					if result.intent_id ~= result.owner.recovery.intent_id then return false end
				elseif result.intent_id ~= nil then return false end
				local owner = result.owner
				if event.kind == "admit_controller" or event.kind == "reserve_coordinator" then
					local controller = event.kind == "admit_controller"
					if owner.phase ~= (if controller then "active" else "reserved") or not equal(owner.pane_binding, event.pane_binding)
						or owner.work_id ~= event.work_id or owner.owner_active ~= controller or owner.pending_executors ~= 0
						or owner.pending_executor_evidence ~= "observed" or owner.last_observation ~= nil or owner.recovery ~= nil then return false end
				elseif event.kind == "bind_coordinator" then
					if owner.phase ~= "active" or owner.owner_active ~= true or not equal(owner.pane_binding, event.pane_binding) or owner.recovery ~= nil then return false end
				elseif event.kind == "request_retirement" then
					if owner.phase ~= "retiring" or owner.recovery ~= nil then return false end
				elseif event.kind == "begin_recovery" then
					if owner.phase ~= "recovering" or owner.recovery == nil
						or owner.recovery.intent_id ~= "recovery-" .. string.format("%.0f", result.revision)
						or owner.recovery.expected_revision ~= result.revision or owner.recovery.execution_epoch ~= result.execution_epoch then return false end
				elseif event.kind == "mark_uncertain" or event.kind == "observe_owner" then
					local observed = owner.last_observation
					if observed == nil or observed.execution_epoch ~= result.execution_epoch then return false end
					if event.kind == "mark_uncertain" then
						if owner.phase ~= "uncertain" or owner.recovery ~= nil or observed.status ~= "uncertain"
							or observed.reason ~= event.reason or observed.evidence ~= "unavailable" then return false end
					else
						if observed.status ~= event.status or observed.evidence ~= event.evidence or observed.reason ~= nil then return false end
						if event.status == "unavailable" then
							if owner.phase ~= "uncertain" or owner.owner_active ~= nil or owner.recovery ~= nil then return false end
						elseif event.owner_active ~= nil and owner.owner_active ~= event.owner_active then return false end
						if event.pending_executors ~= nil and (owner.pending_executors ~= event.pending_executors
							or owner.pending_executor_evidence ~= event.evidence) then return false end
					end
				end
			end
		end
		if event.kind == "begin_recovery" then
			if result.intent_id == nil or intents[result.intent_id] ~= nil then return false end
			intents[result.intent_id] = outcome
		end
	end
	for _, outcome in raw.request_outcomes do
		local event, result = outcome.request, outcome.response
		if event.kind ~= "confirm_recovery" then continue end
		local intent = intents[event.intent_id]
		if intent == nil or intent.request.orch_session_id ~= event.orch_session_id or intent.request.target ~= event.target
			or intent.response.owner_id ~= result.owner_id or intent.response.generation ~= result.generation
			or intent.response.revision ~= event.expected_revision or intent.response.execution_epoch + 1 ~= result.execution_epoch then return false end
	end
	return dispatch.valid(raw.dispatch, raw, true)
end
M.valid_legacy = valid_legacy

local function source_proof(registry: any, namespace: string, selection: any, legacy: boolean): (any?, any?)
	local normal, problem, pending, blockers = dispatch.migration_identity(registry, selection)
	if normal == nil then return nil, problem or response(false, "migration_blocked", "Current managed identities do not agree.") end
	local digest, diagnostic = codec.dispatch_managed_digest(tern.json.encode(normal))
	if digest == nil then return nil, diagnostic end
	local proof = { source_schema = registry.version, source_revision = registry.revision,
		source_sha256 = codec.sha256(codec.dispatch_source_bytes(registry)), candidate_namespace = namespace,
		protocol = if legacy then 1 else 2, state = if pending == 0 and blockers == 0 then "ready" else "blocked",
		phase = if legacy then "prepared" else "stable", managed_sha256 = digest, pending_immutable = pending, blockers = blockers }
	if not legacy then proof.source_namespace = registry.authority_namespace end
	return proof, nil
end

function M.migration_source(raw: any): (any?, any?)
	if not valid_legacy(raw) then return nil, response(false, "state_corrupt", "Legacy source failed complete validation.") end
	return { version = raw.version, revision = raw.revision, sessions = copy(raw.sessions) }, nil
end

function M.legacy_migration_proof(raw: any, namespace: string, selection: any): (any?, any?)
	if not valid_legacy(raw) or not validators.authority_namespace(namespace) then
		return nil, response(false, "state_corrupt", "Legacy source or candidate identity is invalid.")
	end
	return source_proof(raw, namespace, selection, true)
end

-- Host callers supply authenticated native peer evidence, never an arbitrary bridge
-- request's claimed proof. Both source and candidate are validated before persistence.
function M.prepare_migration(raw: any, namespace: string, peer_proof: any, selection: any): (any?, any?)
	if not valid_legacy(raw) then return nil, response(false, "state_corrupt", "The complete legacy source failed validation.") end
	if not validators.authority_namespace(namespace) or raw.revision == MAX_INTEGER or raw.execution_epoch == MAX_INTEGER then
		return nil, response(false, "migration_blocked", "Migration identity or counters are unavailable.")
	end
	local own, problem = source_proof(raw, namespace, selection, true)
	if own == nil then return nil, problem end
	local evidence = { schema = 1, kind = "migration", orch = own, spawn = copy(peer_proof) }
	if not codec.validate_dispatch_compatibility(evidence) or peer_proof.source_namespace ~= peer_proof.candidate_namespace
		or own.state ~= "ready" or peer_proof.state ~= "ready" or peer_proof.pending_immutable ~= 0 or peer_proof.blockers ~= 0
		or own.managed_sha256 ~= peer_proof.managed_sha256 then
		return nil, response(false, "migration_blocked", "Both validated native sources must agree without immutable grants or unresolved obligations.")
	end
	local candidate = copy(raw)
	if raw.version == 2 then
		candidate.setup, candidate.installation_defaults = new_setup(true), new_defaults()
	end
	candidate.version, candidate.authority_namespace = 4, namespace
	candidate.next_session_id, candidate.request_outcomes, candidate.retired = nil, nil, nil
	candidate.next_admission_seq = 1
	candidate.revision += 1
	candidate.execution_epoch += 1
	candidate.migration = evidence
	for _, session in candidate.sessions do
		session.phase = "open"
		session.generation_floor = if session.controller then session.controller.generation - 1 else session.controller_generation
		session.request_floor, session.next_request_serial, session.last_authority_revision = 1, 1, 0
		for _, target in { "controller", "orchestrator" } do
			local owner = session[target]
			if owner then owner.phase = "uncertain"; owner.recovery = nil; owner.pending_executor_evidence = "unconfirmed" end
		end
	end
	local migrated, diagnostic = dispatch.migrate(candidate, selection)
	if migrated == false then return nil, diagnostic or response(false, "migration_blocked", "Dispatch migration is blocked.") end
	dispatch.upgrade_projects(candidate)
	candidate.installation_defaults.repository = nil
	candidate.installation_defaults.family_migrations = candidate.installation_defaults.family_migrations or copy(candidate.installation_defaults.policy.family_map)
	candidate.installation_defaults.policy = dispatch.migrate_default_policy(candidate.installation_defaults.policy,
		candidate.installation_defaults.defined == false or (candidate.installation_defaults.defined == nil and candidate.installation_defaults.revision == 0))
	if candidate.installation_defaults.policy.preferred_worker_record == "" then candidate.installation_defaults.policy.preferred_worker_record = candidate.installation_defaults.builder_record end
	if candidate.installation_defaults.policy.preferred_orchestrator_record == "" then candidate.installation_defaults.policy.preferred_orchestrator_record = candidate.installation_defaults.coordinator_record end
	if candidate.installation_defaults.policy then candidate.installation_defaults.policy.excluded_workers = {}; candidate.installation_defaults.policy.paused = false; candidate.installation_defaults.policy.auto_start_projects = false; candidate.installation_defaults.policy.auto_launch_intake = nil end
	for sid, p in (candidate.dispatch or {}).policies or {} do
		local previous = ((raw.dispatch or {}).policies or {})[sid] or {}
		if previous.preferred_worker_record == nil and p.preferred_worker_record == "" then p.preferred_worker_record = candidate.installation_defaults.builder_record end
		if previous.preferred_orchestrator_record == nil and p.preferred_orchestrator_record == "" then p.preferred_orchestrator_record = candidate.installation_defaults.coordinator_record end
	end
	candidate.version = 5
	if not valid_registry(candidate) then return nil, response(false, "invalid_candidate", "The prepared migration candidate failed validation.") end
	return candidate, response(true, "migration_prepared", "Prepared candidate is durable only after the host commit; managed mutation remains blocked.")
end

function M.migration_proof(registry: any, selection: any): (any?, any?)
	if not valid_registry(registry) then return nil, response(false, "state_corrupt", "Candidate source failed validation.") end
	return source_proof(registry, registry.authority_namespace, selection, false)
end

function M.finish_migration(registry: any, peer_compatibility: any, selection: any): (any?, any?)
	if registry.migration == nil or not codec.dispatch_compatibility_ready(peer_compatibility)
		or peer_compatibility.kind ~= "migration" then return nil, response(false, "migration_blocked", "Both exact prepared candidates require fresh native proof.") end
	local own, problem = M.migration_proof(registry, selection)
	if own == nil then return nil, problem end
	if not equal(own, peer_compatibility.orch)
		or peer_compatibility.spawn.candidate_namespace ~= registry.migration.spawn.candidate_namespace
		or registry.revision == MAX_INTEGER then return nil, response(false, "migration_blocked", "Prepared source identity changed or the peer candidate does not match.") end
	local candidate = table.clone(registry)
	candidate.migration = nil
	candidate.compatibility = { schema = 1, kind = "current", protocol = 2, authority_namespace = registry.authority_namespace,
		spawn_namespace = peer_compatibility.spawn.candidate_namespace }
	candidate.revision += 1
	if not valid_registry(candidate) then return nil, response(false, "invalid_candidate", "Migration completion failed candidate validation.") end
	return candidate, response(true, "migration_completed", "Both prepared native candidates were validated.")
end

function M.rehydrate(raw: any): (any?, any?)
	if absent(raw) then return nil, response(false, "state_missing", "Authority state is missing; explicit initialization or recovery is required.") end
	if type(raw) == "table" and (raw.version == 2 or raw.version == 3) then
		return nil, response(false, "migration_blocked", "Legacy authority requires paired native source validation and a validated prepared candidate; old immutable grants cannot be reissued.")
	end
	if type(raw) == "table" and raw.version ~= 4 and raw.version ~= 5 then
		return nil, response(false, "migration_required", "Stored schema is unsupported; retain it for explicit migration.")
	end
	local upgrading = type(raw) == "table" and raw.version == 4
	if not valid_registry(raw, upgrading) then return nil, response(false, "state_corrupt", "Authority state is invalid; no empty registry was substituted.") end
	if raw.execution_epoch == MAX_INTEGER or raw.revision == MAX_INTEGER then
		return nil, response(false, "capacity_reached", "Authority counters are exhausted; explicit migration is required.")
	end
	local restored = copy(raw)
	-- Lifecycle changes also increment revision. Only the explicit unsaved marker or a
	-- zero legacy revision proves old built-ins were never saved as user preferences.
	restored.installation_defaults.family_migrations = restored.installation_defaults.family_migrations or copy(restored.installation_defaults.policy.family_map)
	restored.installation_defaults.policy = dispatch.migrate_default_policy(restored.installation_defaults.policy,
		restored.installation_defaults.defined == false or (restored.installation_defaults.defined == nil and restored.installation_defaults.revision == 0))
	if restored.installation_defaults.policy.preferred_worker_record == "" then restored.installation_defaults.policy.preferred_worker_record = restored.installation_defaults.builder_record end
	if restored.installation_defaults.policy.preferred_orchestrator_record == "" then restored.installation_defaults.policy.preferred_orchestrator_record = restored.installation_defaults.coordinator_record end
	if upgrading then
		dispatch.upgrade_projects(restored)
		restored.installation_defaults.repository = nil
		if restored.installation_defaults.policy then restored.installation_defaults.policy.excluded_workers = {}; restored.installation_defaults.policy.paused = false; restored.installation_defaults.policy.auto_start_projects = false; restored.installation_defaults.policy.auto_launch_intake = nil end
		restored.version = 5
	end
	restored.execution_epoch += 1
	restored.revision += 1
	dispatch.restore(restored.dispatch)
	for sid, p in (restored.dispatch or {}).policies or {} do
		local previous = ((raw.dispatch or {}).policies or {})[sid] or {}
		if previous.preferred_worker_record == nil and p.preferred_worker_record == "" then p.preferred_worker_record = restored.installation_defaults.builder_record end
		if previous.preferred_orchestrator_record == nil and p.preferred_orchestrator_record == "" then p.preferred_orchestrator_record = restored.installation_defaults.coordinator_record end
	end
	for _, session in restored.sessions do
		-- Reload may be a one-sided restore. The old admission identity remains an
		-- obligation, but only fresh peer reconciliation can make it executable.
		session.admitted = nil
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
	if not valid_registry(restored) then return nil, response(false, "state_corrupt", "Restored candidate failed validation; no authority was published.") end
	return restored, response(true, "restored_uncertain", "Restored ownership remains occupied; preserve any v4 original before persisting the new epoch.",
		{ upgrade_required = upgrading, backup_key = if upgrading then "authority_state_v4_original" else nil })
end

-- Host compare-or-set seam: this pure check never persists or restores executable state.
function M.upgrade_backup(original: any, existing: any): (any?, any?)
	if not valid_registry(original, true) then return nil, response(false, "state_corrupt", "The original v4 authority is invalid.") end
	if not absent(existing) and not equal(original, existing) then
		return nil, response(false, "upgrade_backup_conflict", "A different v4 original is already preserved; authority was not changed.")
	end
	return copy(original), nil
end


-- All mutation routes use the same captured authority fence. Current observations below
-- may answer stale intents, but never replace their revision or execute them again.
function M.fence(registry: any, event: any): any?
	if type(event) ~= "table" or not validators.authority_namespace(event.authority_namespace)
		or not integer(event.expected_revision, 0) then return response(false, "invalid_event", "An authority namespace and captured revision are required.") end
	if event.authority_namespace ~= registry.authority_namespace then return response(false, "stale_authority", "This intent belongs to another authority.") end
	if event.expected_revision ~= registry.revision and not dispatch.subject_decision(registry, event) then return response(false, "stale_revision", "The authority or this decision's subject changed; review the current question without replaying the old answer.", { revision = registry.revision }) end
	return nil
end

-- Dedicated native-authenticated host door, deliberately not a generic apply event:
-- the host must prove the peer observation belongs to the selected live bridge.
function M.qualify_current(registry: any, event: any, peer_proof: any, selection: any): (any?, any)
	local failure = M.fence(registry, event)
	if failure then return nil, failure end
	if not fields(event, { kind = true, request_id = true, authority_namespace = true, expected_revision = true })
		or event.kind ~= "qualify_current" or not validators.request_id(event.request_id) then
		return nil, response(false, "invalid_event", "Qualification requires a captured closed host intent.")
	end
	if registry.migration ~= nil then return nil, response(false, "migration_blocked", "A prepared migration cannot be replaced by current qualification.") end
	local own, problem = M.migration_proof(registry, selection)
	if own == nil then return nil, problem end
	local pair = { schema = 1, kind = "migration", orch = own, spawn = peer_proof }
	if not codec.dispatch_compatibility_ready(pair) then
		return nil, response(false, "migration_blocked", "Both native current sources must be validated, stable and free of unresolved migration obligations.")
	end
	if registry.compatibility ~= nil then
		if registry.compatibility.spawn_namespace ~= peer_proof.candidate_namespace then
			return nil, response(false, "stale_authority", "The established SPAWN authority cannot be replaced by qualification.")
		end
		return registry, response(true, "already_qualified", "The exact current peer remains qualified.", { revision = registry.revision })
	end
	if registry.revision == MAX_INTEGER then return nil, response(false, "capacity_reached", "The authority revision is exhausted.") end
	local candidate = table.clone(registry)
	candidate.revision += 1
	candidate.compatibility = { schema = 1, kind = "current", protocol = 2, authority_namespace = registry.authority_namespace,
		spawn_namespace = peer_proof.candidate_namespace }
	if not valid_registry(candidate) then return nil, response(false, "invalid_candidate", "Peer qualification would leave invalid authority.") end
	return candidate, response(true, "peer_qualified", "The independently observed current native stores are qualified.", { revision = candidate.revision })
end

local function checked(previous: any, candidate: any, result: any): (any?, any)
	if candidate ~= nil and candidate ~= previous and not valid_registry(candidate) then
		return nil, response(false, "invalid_candidate", "The transition would leave invalid current authority; nothing was committed.")
	end
	return candidate, result
end

function M.apply(registry: any, raw: any, clock: any?): (any?, any)
	if type(raw) ~= "table" or not validators.authority_namespace(raw.authority_namespace)
		or not integer(raw.expected_revision, 0) then return nil, response(false, "invalid_event", "Every intent requires its captured authority namespace and revision.") end
	if raw.authority_namespace ~= registry.authority_namespace then return nil, response(false, "stale_authority", "This intent belongs to another authority.") end
	if raw.kind == "installation_defaults" or raw.kind == "setup_lifecycle" or raw.kind == "dispatch"
		or raw.kind == "dispatch_reconcile" or raw.kind == "workflow_tick" then
		local failure = M.fence(registry, raw)
		if failure then return nil, failure end
		if registry.migration ~= nil then return nil, response(false, "migration_blocked", "Paired migration must settle before authority mutation.") end
		if raw.kind == "installation_defaults" or raw.kind == "setup_lifecycle" then return checked(registry, apply_setup(registry, raw, clock)) end
		if raw.kind == "dispatch" then return checked(registry, dispatch.apply(registry, raw, clock, M.apply)) end
		if raw.kind == "dispatch_reconcile" then return checked(registry, dispatch.reconcile(registry, raw)) end
		return checked(registry, dispatch.tick(registry, raw, clock))
	end
	local event = decode_event(raw)
	if event == nil then return nil, response(false, "invalid_event", "Invalid operation fields or bounds.") end
	local now = if type(clock) == "table" then clock.now_ms else clock
	if now == nil then now = 0 end
	if not integer(now, 0) then return nil, response(false, "invalid_clock", "The audit clock must be a nonnegative integer.") end
	local kind = event.kind
	local session = registry.sessions[event.orch_session_id]
	local target = target_for(event)
	local owner = if session ~= nil then session[target] else nil
	local function observation(code: string, message: string, held: any?): (any, any)
		return registry, response(true, code, message, { orch_session_id = event.orch_session_id, revision = registry.revision,
			authority_namespace = registry.authority_namespace, execution_epoch = registry.execution_epoch, owner = held,
			intent_id = if held and held.recovery then held.recovery.intent_id else nil })
	end
	if kind == "register_session" and session ~= nil then
		if session.name ~= event.name or not equal(session.binding, event.binding) then
			return nil, response(false, "session_conflict", "This active session identity has a different definition.")
		end
		return observation("already_registered", "This session is currently registered.", nil)
	end
	if (kind == "release_controller" or kind == "release_coordinator" or kind == "confirm_recovery")
		and (owner == nil or owner.owner_id ~= event.expected_owner_id or owner.generation ~= event.expected_generation) then
		return observation("not_held", "That generation is not currently held; this is not a historical execution result.", nil)
	end
	if session ~= nil and session.phase == "open" and owner ~= nil
		and ((kind == "admit_controller" and equal(owner.pane_binding, event.pane_binding))
			or (kind == "reserve_coordinator" and owner.work_id == event.work_id)) then
		return observation("current_owner", "The identical binding currently holds this slot.", owner)
	end
	if kind == "begin_recovery" and owner and owner.owner_id == event.expected_owner_id and owner.generation == event.expected_generation
		and owner.recovery and owner.recovery.expected_revision == registry.revision and owner.recovery.execution_epoch == registry.execution_epoch then
		return observation("recovery_pending", "This exact owner has a current recovery intent.", owner)
	end
	if kind == "begin_close" and session and session.close and session.close.close_id == event.close_id
		and equal(session.close.control_origin, event.control_origin) then return observation("already_closing", "This closure is currently pending.", nil) end
	local failure = M.fence(registry, event)
	if failure then return nil, failure end
	if registry.migration ~= nil then return nil, response(false, "migration_blocked", "Paired migration must settle before authority mutation.") end
	if registry.revision == MAX_INTEGER then return nil, response(false, "capacity_reached", "The authority revision is exhausted.") end
	if kind ~= "register_session" and session == nil then return nil, response(false, "session_not_found", "Choose an active logical session.") end
	if event.expected_owner_id ~= nil and (owner == nil or owner.owner_id ~= event.expected_owner_id or owner.generation ~= event.expected_generation) then
		return nil, response(false, "owner_mismatch", "The current owner does not match this intent.")
	end
	if session and session.phase ~= "open" and (kind == "admit_controller" or kind == "reserve_coordinator" or kind == "bind_coordinator") then
		return nil, response(false, "session_closing", "Closing sessions cannot admit new ownership.")
	end
	if kind == "begin_forget" or kind == "supersede_forget" or kind == "complete_forget" then
		local pending = if session.close then session.close.forget else nil
		local function checked_clone(): any
			local candidate = table.clone(registry)
			candidate.sessions = table.clone(registry.sessions)
			candidate.revision += 1
			return candidate
		end
		local function forgotten(candidate: any, cursor: number): (any?, any)
			dispatch.reclaim_session(candidate, event.orch_session_id)
			candidate.sessions[event.orch_session_id] = nil
			-- A forgotten admission must never be reissued: stay above SPAWN's own watermark.
			candidate.next_admission_seq = math.max(registry.next_admission_seq, cursor + 1)
			candidate.forgotten = { name = session.name, revision = candidate.revision, orch_session_id = event.orch_session_id }
			return checked(registry, candidate, response(true, "session_forgotten", "Orchestration forgotten.", { revision = candidate.revision, orch_session_id = event.orch_session_id }))
		end
		if kind == "complete_forget" then
			if pending == nil or pending.attempt_id ~= event.attempt_id then
				return nil, response(false, "forget_superseded", "This forget attempt is no longer the pending one; it cannot complete.")
			end
			local request = codec.decode_forget_request(pending.request_bytes)
			local body = if request then codec.decode_forget_response(event.response_bytes, request) else nil
			if body == nil or body.op ~= "discard_session" or body.status ~= "closed" then
				return nil, response(false, "forget_unproven", "Only SPAWN's exact closed result for the pending request completes forgetting.")
			end
			return forgotten(checked_clone(), body.payload.admission_cursor)
		end
		-- begin / supersede: the exact current controller proves ownership, restored or reloaded included.
		local binding = event.control_origin.binding
		local controller = session.controller
		if event.control_origin.close_id ~= event.attempt_id or binding.logical_session_id ~= event.orch_session_id or controller == nil
			or controller.owner_id ~= binding.owner_id or controller.generation ~= binding.owner_generation
			or controller.pane_binding == nil or controller.pane_binding.host_pane_id ~= binding.host_pane_id
			or controller.pane_binding.alias_nonce ~= binding.alias_nonce then
			return nil, response(false, "owner_mismatch", "Forget must be issued by the orchestration's exact current controller.")
		end
		if kind == "begin_forget" and pending ~= nil then return nil, response(false, "forget_pending", "Forgetting is already pending; recover it instead of starting another.") end
		if kind == "supersede_forget" and (pending == nil or pending.attempt_id == event.attempt_id) then
			return nil, response(false, "forget_not_pending", "Only a different attempt supersedes a pending forget.")
		end
		if session.admission_seq == nil then
			-- Never admitted to SPAWN: it holds nothing there, so the local discard is one commit.
			if event.request_bytes ~= nil then return nil, response(false, "invalid_event", "A session SPAWN never admitted has nothing to ask SPAWN.") end
			return forgotten(checked_clone(), 0)
		end
		local request = if event.request_bytes then codec.decode_forget_request(event.request_bytes) else nil
		local preview = event.preview
		if request == nil or preview == nil or request.op ~= "discard_session" or request.attempt_id ~= event.attempt_id
			or request.logical_session_id ~= event.orch_session_id or request.admission_seq ~= session.admission_seq
			or request.authority_namespace ~= registry.authority_namespace
			or (session.spawn_namespace ~= nil and request.spawn_namespace ~= session.spawn_namespace)
			or request.dispatch_revision ~= preview.dispatch_revision or request.spawn_boot ~= preview.spawn_boot
			or request.owner.owner_id ~= binding.owner_id or request.owner.owner_generation ~= binding.owner_generation
			or request.owner.host_pane_id ~= binding.host_pane_id or request.owner.alias_nonce ~= binding.alias_nonce
			or request.owner.window_key ~= binding.window_key or request.owner.native_session_id ~= binding.native_session_id
			or request.owner.window_host_id ~= binding.window_host_id or request.controller_pane ~= event.control_origin.controller_pane then
			return nil, response(false, "invalid_event", "The persisted request must be the exact discard for this session, admission and owner.")
		end
		local candidate = checked_clone()
		local closing = copy(session)
		closing.phase = "closing"
		-- Promotion of an ordinary close happens only through this explicit transition; any older control is superseded.
		closing.bridge_control = nil
		closing.close = { close_id = event.attempt_id, control_origin = copy(event.control_origin), peer_closed = false,
			forget = { attempt_id = event.attempt_id, request_bytes = event.request_bytes, preview = copy(event.preview) } }
		candidate.sessions[event.orch_session_id] = closing
		-- Recovery supersedes the older window's cursor: closing controls must follow the re-verified controller.
		local cursors = if registry.dispatch then registry.dispatch.command_cursors else nil
		if cursors and cursors[event.orch_session_id] then
			candidate.dispatch = table.clone(registry.dispatch)
			candidate.dispatch.command_cursors = table.clone(cursors)
			local cursor = table.clone(cursors[event.orch_session_id])
			cursor.origin = copy(binding)
			cursor.controller_pane = event.control_origin.controller_pane
			candidate.dispatch.command_cursors[event.orch_session_id] = cursor
		end
		return checked(registry, candidate, response(true, if kind == "begin_forget" then "forget_fenced" else "forget_superseded_fenced", "Forgetting is persisted and the orchestration is fenced.",
			{ revision = candidate.revision, orch_session_id = event.orch_session_id }))
	end
	if kind == "begin_close" or kind == "confirm_close" then
		if kind == "begin_close" then
			if session.phase ~= "open" then return nil, response(false, "session_closing", "Another closure is pending.") end
			if session.bridge_control ~= nil then return nil, response(false, "session_busy", "A current bridge control must settle before closing.") end
			for _, slot in { "controller", "orchestrator" } do
				local held = session[slot]
				if held and (held.pending_executors > 0 or held.pending_executor_evidence == "unconfirmed") then
					return nil, response(false, "session_busy", "Reconcile current executor evidence before beginning closure.")
				end
			end
			local problem = dispatch.close_problem(registry, event.orch_session_id)
			if problem then return nil, response(false, "session_busy", problem) end
			if session.admission_seq ~= nil and (event.control_origin == nil or event.control_origin.close_id ~= event.close_id
				or event.control_origin.binding.logical_session_id ~= event.orch_session_id) then
				return nil, response(false, "invalid_event", "Admitted closure requires its exact retained native closing origin.")
			end
			local controller = session.controller
			if event.control_origin ~= nil and (controller == nil or controller.owner_id ~= event.control_origin.binding.owner_id
				or controller.generation ~= event.control_origin.binding.owner_generation
				or controller.pane_binding == nil or controller.pane_binding.host_pane_id ~= event.control_origin.binding.host_pane_id
				or controller.pane_binding.alias_nonce ~= event.control_origin.binding.alias_nonce) then
				return nil, response(false, "owner_mismatch", "Closure must capture the current controller's exact origin before release.")
			end
		else
			if session.close == nil or session.close.close_id ~= event.close_id or not session.close.peer_closed then
				return nil, response(false, "closure_pending", "A positive matching SPAWN closure observation is required.")
			end
			if session.controller ~= nil or session.orchestrator ~= nil or session.bridge_control ~= nil then
				return nil, response(false, "session_busy", "Current ownership or bridge delivery still blocks closure.")
			end
			local problem = dispatch.close_problem(registry, event.orch_session_id)
			if problem then return nil, response(false, "session_busy", problem) end
		end
		local candidate = table.clone(registry)
		candidate.sessions = table.clone(registry.sessions)
		candidate.revision += 1
		if kind == "begin_close" then
			local closing = copy(session)
			closing.phase = "closing"
			closing.close = { close_id = event.close_id, control_origin = copy(event.control_origin),
				peer_closed = session.admission_seq == nil and session.bridge_control == nil and session.next_request_serial == 1 }
			candidate.sessions[event.orch_session_id] = closing
		else
			dispatch.reclaim_session(candidate, event.orch_session_id)
			candidate.sessions[event.orch_session_id] = nil
		end
		return checked(registry, candidate, response(true, if kind == "begin_close" then "session_closing" else "session_closed",
			"Session lifecycle advanced.", { revision = candidate.revision, orch_session_id = event.orch_session_id }))
	end
	local in_reserve = type(clock) == "table" and clock.reserved_capacity == true
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
	if kind == "begin_recovery" and in_reserve then
		if owner.pending_executors > 0 then return nil, response(false, "pending_executors", "Reconcile executor evidence before consuming reserved recovery preparation.") end
		if owner.owner_active == true then return nil, response(false, "owner_active", "Resolve current active-owner evidence before consuming reserved recovery preparation.") end
	end
	if kind == "admit_controller" or kind == "reserve_coordinator" then
		target = if kind == "admit_controller" then "controller" else "orchestrator"
		owner = session[target]
		if owner ~= nil then return nil, response(false, target .. "_slot_occupied", "The durable slot is occupied; reveal or inspect its recorded owner.", { owner = owner, orch_session_id = session.orch_session_id, revision = registry.revision }) end
		if kind == "reserve_coordinator" then
			local problem = dispatch.coordinator_blocker(registry, event.orch_session_id, clock)
			if problem then return nil, response(false, "coordinator_unresolved", problem) end
		end
		if registry.next_owner_id == MAX_INTEGER or session[target .. "_generation"] == MAX_INTEGER then
			return nil, response(false, "capacity_reached", "Owner counters are exhausted.")
		end
	end
	if kind == "register_session" and count(registry.sessions) >= LIMITS.sessions then
		return nil, response(false, "capacity_reached", "Session registration capacity is full.")
	end
	if owner ~= nil then
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
					or not (worker.release or dispatch.start_retirement_complete(registry, worker)) or not worker.stopped or worker.mailbox_retired ~= true then
					return nil, response(false, "managed_retirement_incomplete", "Managed coordinator release requires authenticated self-release or exact owner-withdrawn START retirement, positive native stop and committed mailbox retirement.")
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
	local clearing = kind == "release_coordinator" or kind == "release_controller" or kind == "confirm_recovery"
	if clearing and dispatch.unresolved(registry, event.orch_session_id, event.expected_owner_id) then
		return nil, response(false, "dispatch_executor_unresolved", "Reconcile each retained dispatch action/grant before clearing this owner; an inspection count is not its executor ledger.")
	end
	if clearing and session[target .. "_generation"] == MAX_INTEGER then
		return nil, response(false, "capacity_reached", "The ownership generation is exhausted.")
	end

	-- Validation is complete. Copy only the changed registry branches; old authority and
	-- all returned projections remain independent of the candidate's mutable records.
	local next_state = table.clone(registry)
	next_state.sessions = table.clone(registry.sessions)
	next_state.revision += 1
	local changed = if session ~= nil then copy(session) else nil
	if changed ~= nil then next_state.sessions[changed.orch_session_id] = changed end
	local code, message = "accepted", "Operation committed."
	if kind == "register_session" then
		changed = M.new_session({ orch_session_id = event.orch_session_id, name = event.name,
			binding = event.binding, created_at_ms = now })
		next_state.sessions[changed.orch_session_id] = changed
		dispatch.seed_policy(next_state, changed.orch_session_id, registry.installation_defaults.policy)
		if registry.installation_defaults.family_migrations then
			next_state.dispatch.family_migrations = copy(next_state.dispatch.family_migrations or {})
			next_state.dispatch.family_migrations[changed.orch_session_id] = copy(registry.installation_defaults.family_migrations)
		end
		code, message = "session_registered", "Orchestration created. No agent has started."
	elseif kind == "admit_controller" or kind == "reserve_coordinator" then
		next_state.next_owner_id += 1
		changed[target .. "_generation"] += 1
		changed[target] = { owner_id = "owner-" .. string.format("%.0f", next_state.next_owner_id), generation = changed[target .. "_generation"],
			phase = if target == "controller" then "active" else "reserved", pane_binding = copy(event.pane_binding), work_id = event.work_id,
			created_at_ms = now, owner_active = target == "controller", pending_executors = 0, pending_executor_evidence = "observed" }
		code, message = target .. "_granted", if target == "controller" then "This pane now controls the orchestration." else "Ready to start the orchestrator."
	elseif clearing then
		changed[target] = nil
		changed[target .. "_generation"] += 1
		if target == "controller" then
			changed.generation_floor = changed.controller_generation
			changed.admitted = nil -- A replacement owner must reconcile the retained admission itself.
		end
		if kind == "confirm_recovery" then next_state.execution_epoch += 1 end
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
	local result_owner = if kind == "register_session" or clearing then nil else changed[target]
	local result = response(true, code, message, { request_id = event.request_id, orch_session_id = changed.orch_session_id,
		owner = result_owner, owner_id = if result_owner ~= nil then result_owner.owner_id else event.expected_owner_id,
		generation = if result_owner ~= nil then result_owner.generation else event.expected_generation,
		revision = next_state.revision, execution_epoch = next_state.execution_epoch,
		intent_id = if result_owner ~= nil and result_owner.recovery ~= nil then result_owner.recovery.intent_id else nil })
	return checked(registry, next_state, result)
end

function M.project(registry: any, request: any?): any
	local result: any = { version = 5, authority_namespace = registry.authority_namespace, revision = registry.revision, execution_epoch = registry.execution_epoch,
		sessions = tern.json.array(), compatibility = copy(registry.compatibility), migration = copy(registry.migration),
		setup = copy(registry.setup), installation_defaults = copy(registry.installation_defaults),
		finished_projects = copy((registry.dispatch or {}).finished_projects or tern.json.array()) }
	result.setup.readiness_stale = result.setup.readiness.state ~= "not_run" and result.setup.readiness.config_revision ~= result.setup.config_revision
	local ids = {}
	for id in registry.sessions do table.insert(ids, id) end
	table.sort(ids)
	for _, id in ids do table.insert(result.sessions, copy(registry.sessions[id])) end
	if type(request) == "table" and text(request.orch_session_id, 128) then result.session = copy(registry.sessions[request.orch_session_id]) end
	return result
end

return M
