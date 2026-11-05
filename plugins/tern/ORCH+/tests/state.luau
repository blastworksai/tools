-- Run in Tern's Lua runtime with the plugin directory as the only argument.
local root = ...
assert(type(root) == "string", "pass the plugin directory")
local runtime, environment = tern, getfenv()
local fake = table.clone(runtime)
fake.json = runtime.json
local modules = {}
local function load(name)
	name = name:gsub("^%./", "")
	if modules[name] ~= nil then return modules[name] end
	local chunk = assert(loadstring(runtime.fs.read(root .. "/" .. name .. ".luau"), name))
	setfenv(chunk, setmetatable({ require = load, tern = fake }, { __index = environment }))
	local module = chunk()
	modules[name] = module
	return module
end
local state = load("state")
local checks = 0
local function check(condition, message)
	assert(condition, message)
	checks += 1
end
local function clone(value) return runtime.json.decode(runtime.json.encode(value)) end
local binding = { host_pane_id = "42", alias_nonce = "host-issued-nonce" }
local current = state.new_registry()
local function accept(event, message)
	local before = runtime.json.encode(current)
	local next_state, result = state.apply(current, event, 1000)
	check(next_state ~= nil and result.ok == true, message .. ": " .. tostring(result.code))
	check(runtime.json.encode(current) == before, message .. " leaves old authoritative input unchanged")
	current = next_state
	return result
end
local function reject(event, code, message)
	local before = runtime.json.encode(current)
	local next_state, result = state.apply(current, event, 1000)
	check(next_state == nil and result.ok == false and result.code == code, message .. ": " .. tostring(result.code))
	check(runtime.json.encode(current) == before, message .. " has no mutation")
end
local function owned(kind, request_id, session_id, owner, extra)
	local event = { kind = kind, request_id = request_id, orch_session_id = session_id,
		expected_owner_id = owner.owner_id, expected_generation = owner.generation }
	if extra ~= nil then for key, value in extra do event[key] = value end end
	return event
end

for _, missing in { runtime.json.null, false, "broken" } do
	local result, diagnostic = state.rehydrate(missing)
	check(result == nil and diagnostic.ok == false, "missing/corrupt input never becomes empty authority")
end
local result, diagnostic = state.rehydrate(nil)
check(result == nil and diagnostic.code == "state_missing", "nil store requires explicit initialization")
for _, legacy in { { version = 1, actions = {} }, { version = 3 }, {} } do
	result, diagnostic = state.rehydrate(legacy)
	check(result == nil and diagnostic.code == "migration_required", "unsupported state quarantines for migration")
end
local corrupt = clone(current)
corrupt.next_owner_id = 0 / 0
check(state.rehydrate(corrupt) == nil, "nonfinite stored counters rejected")
corrupt = clone(current)
corrupt.retired = runtime.json.null
check(state.rehydrate(corrupt) == nil, "null required map rejected")
reject({ kind = "result", request_id = "old-result", action_id = "old" }, "invalid_event", "legacy unbound results are not authority")
reject({ kind = "register_session", request_id = "bad", name = "bad\nname" }, "invalid_event", "control characters rejected")
reject({ kind = "register_session", request_id = "bad", name = string.rep("a", 257) }, "invalid_event", "registration length bounded")
reject({ kind = "register_session", request_id = "bad", name = "normal", command = "injected" }, "invalid_event", "unknown operation fields rejected")
local registration = { kind = "register_session", request_id = "register-1", name = "Project", binding = binding }
local registered = accept(registration, "explicit registration")
local session_id = registered.orch_session_id
local revision = current.revision
local replay = accept(clone(registration), "registration replay")
check(replay.replayed == true and replay.orch_session_id == session_id and current.revision == revision, "replay returns original committed result without another registration")
local changed = clone(registration)
changed.name = "Changed"
reject(changed, "request_conflict", "same request with changed body conflicts")
local second = accept({ kind = "register_session", request_id = "register-2", name = "Other session" }, "second independent session")
local controller = accept({ kind = "admit_controller", request_id = "controller-1", orch_session_id = session_id, pane_binding = binding }, "first controller").owner
reject({ kind = "admit_controller", request_id = "controller-2", orch_session_id = session_id, pane_binding = { host_pane_id = "99", alias_nonce = "other" } }, "controller_slot_occupied", "second controller remains inert")
local other_controller = accept({ kind = "admit_controller", request_id = "other-controller", orch_session_id = second.orch_session_id,
	pane_binding = { host_pane_id = "43", alias_nonce = "other-session" } }, "other session controller").owner
check(other_controller.owner_id ~= controller.owner_id, "owner identities are host-issued, not native aliases")

local reservation_request = { kind = "reserve_coordinator", request_id = "start-1", orch_session_id = session_id, work_id = "WORK-1" }
local coordinator = accept(reservation_request, "reserve before native pane exists").owner
check(coordinator.pane_binding == nil and coordinator.phase == "reserved", "pane-less reservation is occupied")
for index = 2, 16 do
	reject({ kind = "reserve_coordinator", request_id = "start-" .. tostring(index), orch_session_id = session_id },
		"orchestrator_slot_occupied", "serialized competing start " .. tostring(index))
end
local before_failure = runtime.json.encode(current)
local saved_revision = current.revision
local candidate = state.apply(current, owned("bind_coordinator", "bind-failed-save", session_id, coordinator, { pane_binding = binding }), 1100)
check(candidate ~= nil and candidate.sessions[session_id].orchestrator.phase == "active", "bind produces a persistable candidate")
check(runtime.json.encode(current) == before_failure and current.revision == saved_revision, "discarding failed-write candidate preserves authoritative reservation")
coordinator = accept(owned("bind_coordinator", "bind", session_id, coordinator, { pane_binding = binding }), "bind exact reservation").owner
reject(owned("bind_coordinator", "bind-again", session_id, coordinator, { pane_binding = binding }), "not_reserved", "fresh request cannot bind twice")
reject(owned("release_coordinator", "generic-done", session_id, coordinator, {}), "invalid_event", "completion without explicit quiescence is not release")
accept(owned("mark_uncertain", "missing", session_id, coordinator, { target = "orchestrator", reason = "parked or disconnected" }), "missing native evidence")
check(current.sessions[session_id].orchestrator.owner_id == coordinator.owner_id, "missing observation does not clear slot")
reject({ kind = "reserve_coordinator", request_id = "missing-restart", orch_session_id = session_id }, "orchestrator_slot_occupied", "uncertainty never grants replacement")
accept(owned("release_controller", "release-controller", session_id, controller), "controller release")
check(current.sessions[session_id].controller == nil and current.sessions[session_id].orchestrator.owner_id == coordinator.owner_id, "controller release leaves coordinator intact")
local successor_controller = accept({ kind = "admit_controller", request_id = "controller-successor", orch_session_id = session_id, pane_binding = binding }, "new controller generation").owner
check(successor_controller.generation > controller.generation and current.sessions[session_id].orchestrator_generation == coordinator.generation, "controller generation independent of coordinator")
accept(owned("release_controller", "late-controller-release", session_id, controller), "late exact retired controller release")
check(current.sessions[session_id].controller.owner_id == successor_controller.owner_id, "late controller release cannot clear successor")

accept(owned("request_retirement", "retire-intent", session_id, coordinator), "request coordinator retirement")
reject(owned("release_coordinator", "release-active", session_id, coordinator, { quiescent = true }), "owner_active", "known active coordinator cannot release")
reject(owned("observe_owner", "attest-active", session_id, coordinator, { target = "orchestrator", status = "checkbox", evidence = "operator_attested", operator_verified = true, owner_active = false, pending_executors = 0 }), "owner_active", "attestation cannot erase known live owner")
accept(owned("observe_owner", "pending", session_id, coordinator, { target = "orchestrator", status = "launch executor unresolved", evidence = "observed", owner_active = false, pending_executors = 1 }), "record pending executor")
reject(owned("release_coordinator", "release-pending", session_id, coordinator, { quiescent = true }), "pending_executors", "pending executor blocks release")
local recovery = accept(owned("begin_recovery", "recover-pending", session_id, coordinator, { target = "orchestrator", expected_revision = current.revision }), "begin recovery with unresolved executor")
local confirmation = owned("confirm_recovery", "confirm-pending", session_id, coordinator, { target = "orchestrator", expected_revision = current.revision,
	intent_id = recovery.intent_id, operator_verified = true, evidence = "operator_attested" })
reject(confirmation, "pending_executors", "operator confirmation cannot hide known pending executor")
reject(owned("release_coordinator", "release-fenced", session_id, coordinator, { quiescent = true }), "recovery_fenced", "recovery fences normal release")
reject(owned("observe_owner", "unverified-observation", session_id, coordinator, { target = "orchestrator", status = "stopped", evidence = "operator_attested", owner_active = false, pending_executors = 0 }), "invalid_event", "operator evidence requires explicit verification")
reject(owned("observe_owner", "attest-pending", session_id, coordinator, { target = "orchestrator", status = "checkbox", evidence = "operator_attested", operator_verified = true, owner_active = false, pending_executors = 0 }), "pending_executors", "attestation cannot erase known pending executor")
accept(owned("observe_owner", "settled", session_id, coordinator, { target = "orchestrator", status = "native executor reconciliation confirmed stop", evidence = "observed", owner_active = false, pending_executors = 0 }), "observed executor reconciliation")
reject(confirmation, "stale_revision", "changed evidence invalidates earlier confirmation")
recovery = accept(owned("begin_recovery", "recover-current", session_id, coordinator, { target = "orchestrator", expected_revision = current.revision }), "refresh recovery intent")
confirmation = owned("confirm_recovery", "confirm-current", session_id, coordinator, { target = "orchestrator", expected_revision = current.revision,
	intent_id = recovery.intent_id, operator_verified = true, evidence = "operator_attested" })
local wrong_intent = clone(confirmation)
wrong_intent.intent_id = "other-intent"
reject(wrong_intent, "stale_recovery", "wrong recovery intent rejected")
local unverified = clone(confirmation)
unverified.operator_verified = nil
reject(unverified, "invalid_event", "unverified recovery rejected")
local before_recovery = runtime.json.encode(current)
local recovered_candidate = state.apply(current, confirmation, 1200)
check(recovered_candidate ~= nil and recovered_candidate.sessions[session_id].orchestrator == nil, "recovery creates clear candidate")
check(runtime.json.encode(current) == before_recovery, "failed recovery save leaves occupied authority unchanged")
local old_generation = current.sessions[session_id].orchestrator_generation
accept(confirmation, "confirmed revision-bound recovery")
check(current.sessions[session_id].orchestrator == nil and current.sessions[session_id].orchestrator_generation > old_generation, "recovery tombstones and advances generation, never starts replacement")
check(current.retired[coordinator.owner_id].evidence == "operator_attested", "recovery provenance remains operator-attested")
local replacement = accept({ kind = "reserve_coordinator", request_id = "intentional-new-start", orch_session_id = session_id }, "separate replacement request").owner
check(replacement.generation > coordinator.generation, "new reservation uses a later generation")
accept(owned("release_coordinator", "late-old-release", session_id, coordinator, { quiescent = true }), "late exact retired coordinator release")
check(current.sessions[session_id].orchestrator.owner_id == replacement.owner_id, "old release does not clear successor")
local wrong_generation = owned("release_coordinator", "old-wrong-gen", session_id, coordinator, { quiescent = true })
wrong_generation.expected_generation += 1
reject(wrong_generation, "owner_mismatch", "retired owner with wrong generation rejected")
local old_replay = accept(reservation_request, "original grant replay after replacement")
check(old_replay.owner.owner_id == coordinator.owner_id and current.sessions[session_id].orchestrator.owner_id == replacement.owner_id, "durable old outcome never reactivates old owner")
accept(owned("release_coordinator", "cancel-before-launch", session_id, replacement, { quiescent = true }), "definitively unlaunched reservation cancellation")
check(current.sessions[session_id].orchestrator == nil, "unused reservation can retire without inventing a pane")

local null_request = { kind = "reserve_coordinator", request_id = "null-optional", orch_session_id = session_id, work_id = runtime.json.null }
local null_owner = accept(null_request, "native JSON null normalized at boundary").owner
null_request.work_id = nil
check(accept(null_request, "nil optional replay").replayed == true, "null and absent optional fields share identity")
local stale_controller_recovery = accept(owned("begin_recovery", "controller-recovery", session_id, successor_controller, { target = "controller", expected_revision = current.revision }), "controller recovery intent")
reject(owned("confirm_recovery", "controller-still-active", session_id, successor_controller, { target = "controller", expected_revision = current.revision,
	intent_id = stale_controller_recovery.intent_id, operator_verified = true, evidence = "operator_attested" }), "owner_active", "known-active controller cannot be confirmed away")
local persisted = clone(current)
local restored, restore_diagnostic = state.rehydrate(persisted)
check(restored ~= nil and restore_diagnostic.code == "restored_uncertain", "valid schema restores")
check(restored.sessions[session_id].orchestrator.owner_id == null_owner.owner_id and restored.sessions[session_id].orchestrator.phase == "uncertain", "reload retains pane-less occupied reservation")
check(restored.sessions[session_id].controller.recovery == nil and restored.execution_epoch > persisted.execution_epoch, "restart invalidates recovery intent and runtime epoch")
check(persisted.sessions[session_id].controller.recovery ~= nil, "rehydration does not mutate stored input")
current = restored
reject({ kind = "reserve_coordinator", request_id = "restore-auto-start", orch_session_id = session_id }, "orchestrator_slot_occupied", "restored missing pane is not empty")
reject(owned("confirm_recovery", "restore-old-confirm", session_id, successor_controller, { target = "controller", expected_revision = persisted.revision,
	intent_id = stale_controller_recovery.intent_id, operator_verified = true, evidence = "operator_attested" }), "stale_revision", "old confirmation cannot cross restart")
check(accept(registration, "registration replay after durable restore").orch_session_id == session_id, "dedup identity survives restart")

local projection = state.project(current, { orch_session_id = session_id })
check(#projection.sessions == 2 and projection.session.orch_session_id == session_id, "projection contains bounded registrations and selected session")
projection.session.controller.owner_id = "modified-view"
projection.sessions[1].name = "modified-view"
check(current.sessions[session_id].controller.owner_id == successor_controller.owner_id and current.sessions[session_id].name == "Project", "view cannot mutate authority")
local invalid = clone(current)
invalid.sessions[session_id].orchestrator.generation += 1
check(state.rehydrate(invalid) == nil, "stored owner generation mismatch quarantined")
invalid = clone(current)
invalid.sessions[session_id].orchestrator.pending_executors = 1025
check(state.rehydrate(invalid) == nil, "stored executor bound validated")
invalid = clone(current)
invalid.request_outcomes["register-1"].response.orch_session_id = "missing"
check(state.rehydrate(invalid) == nil, "stored outcome cannot point at missing session")
invalid = clone(current)
invalid.retired[coordinator.owner_id].generation = 99999
check(state.rehydrate(invalid) == nil, "retired generation cannot exceed session history")
local wrong_clock, clock_error = state.apply(current, { kind = "register_session", request_id = "clock", name = "Clock" }, math.huge)
check(wrong_clock == nil and clock_error.code == "invalid_clock", "infinite audit timestamp rejected")
accept(owned("observe_owner", "unavailable-controller", session_id, successor_controller, { target = "controller", status = "unavailable", evidence = "observed" }), "native unavailable observation")
check(current.sessions[session_id].controller.owner_active == nil and current.sessions[session_id].controller.owner_id == successor_controller.owner_id, "unavailable owner is unknown, not cleared")
accept(owned("observe_owner", "verified-unavailable", session_id, successor_controller, { target = "controller", status = "operator verified externally", evidence = "operator_attested", operator_verified = true, owner_active = false, pending_executors = 0 }), "external verification of unavailable owner")
reject(owned("observe_owner", "unavailable-is-not-settlement", session_id, successor_controller, { target = "controller", status = "unavailable", evidence = "observed", pending_executors = 0 }), "invalid_event", "unavailability cannot claim executor settlement")
for index = 1, 129 do
	accept(owned("mark_uncertain", "history-" .. tostring(index), session_id, null_owner, { target = "orchestrator", reason = "still unconfirmed" }), "retain ownership history " .. tostring(index))
end
check(accept(registration, "old request beyond UI history").orch_session_id == session_id, "display history size never erases durable request identity")
accept(owned("observe_owner", "known-executor", session_id, successor_controller, { target = "controller", status = "executor observed", evidence = "observed", pending_executors = 1 }), "record current executor evidence")
accept(owned("observe_owner", "unavailable-with-live-executor", session_id, successor_controller, { target = "controller", status = "unavailable", evidence = "observed" }), "owner unavailability retains separate executor evidence")
reject(owned("observe_owner", "cannot-attest-live-executor", session_id, successor_controller, { target = "controller", status = "operator verification", evidence = "operator_attested", operator_verified = true, executors_verified = true, owner_active = false, pending_executors = 0 }), "pending_executors", "explicit checkbox still cannot override current known executor")
local stale_executor = state.rehydrate(current)
check(stale_executor ~= nil and stale_executor.sessions[session_id].controller.pending_executors == 1 and stale_executor.sessions[session_id].controller.pending_executor_evidence == "unconfirmed", "restored unresolved count is retained, not mislabelled current liveness")
current = stale_executor
accept(owned("observe_owner", "recheck-stale-executor-owner", session_id, successor_controller, { target = "controller", status = "unavailable", evidence = "observed" }), "recheck owner unavailable after restore")
reject(owned("observe_owner", "missing-executor-verification", session_id, successor_controller, { target = "controller", status = "operator verified owner", evidence = "operator_attested", operator_verified = true, owner_active = false, pending_executors = 0 }), "pending_executors", "stale count requires separate explicit executor verification")
accept(owned("observe_owner", "settle-stale-executor", session_id, successor_controller, { target = "controller", status = "operator verified old executor retired", evidence = "operator_attested", operator_verified = true, executors_verified = true, owner_active = false, pending_executors = 0 }), "operator can explicitly reconcile unavailable stale executor evidence")
check(current.sessions[session_id].controller.pending_executor_evidence == "operator_attested" and current.sessions[session_id].controller.owner_id == successor_controller.owner_id, "stale evidence settlement does not itself clear ownership")
local controller_intent = accept(owned("begin_recovery", "final-controller-intent", session_id, successor_controller, { target = "controller", expected_revision = current.revision }), "controller recovery after explicit settlement")
accept(owned("confirm_recovery", "final-controller-confirm", session_id, successor_controller, { target = "controller", expected_revision = current.revision, intent_id = controller_intent.intent_id, operator_verified = true, evidence = "operator_attested" }), "generation-bound controller recovery")
check(current.sessions[session_id].controller == nil and current.sessions[session_id].orchestrator.owner_id == null_owner.owner_id, "controller recovery cannot clear coordinator")
local bounded = state.new_registry()
for index = 1, state.LIMITS.sessions do
	local candidate = state.apply(bounded, { kind = "register_session", request_id = "bounded-" .. tostring(index), name = "Session " .. tostring(index) })
	assert(candidate ~= nil)
	bounded = candidate
end
local before_full = runtime.json.encode(bounded)
local full_candidate, full_result = state.apply(bounded, { kind = "register_session", request_id = "over-session-bound", name = "Too many" })
check(full_candidate == nil and full_result.code == "capacity_reached" and runtime.json.encode(bounded) == before_full, "registration capacity rejects without evicting ownership history")

local function quarantine(mutator, message)
	local damaged = clone(current)
	mutator(damaged.request_outcomes)
	local before = runtime.json.encode(damaged)
	local restored_state, err = state.rehydrate(damaged)
	check(restored_state == nil and err.code == "state_corrupt", message)
	check(runtime.json.encode(damaged) == before, message .. " preserves quarantined bytes")
end
quarantine(function(outcomes) outcomes["controller-1"].response.owner = nil end, "admission success missing required owner quarantined")
quarantine(function(outcomes) outcomes["controller-1"].response.generation = nil end, "admission success missing generation quarantined")
quarantine(function(outcomes) outcomes["controller-1"].response.code = "accepted" end, "generic success code cannot impersonate admission")
quarantine(function(outcomes)
	local forged = outcomes["start-1"].response
	local controller_result = outcomes["controller-1"].response
	forged.owner, forged.owner_id, forged.generation = clone(controller_result.owner), controller_result.owner_id, controller_result.generation
	forged.owner.phase, forged.owner.pane_binding, forged.owner.owner_active, forged.owner.work_id = "reserved", nil, false, "WORK-1"
end, "coordinator outcome cannot borrow same-session controller identity even with matching reservation shape")
quarantine(function(outcomes) outcomes.bind.response.owner.pane_binding.alias_nonce = "changed-binding" end, "bind outcome must retain requested pane binding")
quarantine(function(outcomes) outcomes["late-old-release"].response.generation += 1 end, "release outcome must match exact requested generation")
quarantine(function(outcomes) outcomes["recover-current"].response.intent_id = "changed-intent" end, "recovery result must match its stored intent")
quarantine(function(outcomes) outcomes["recover-current"].request.expected_revision += 1 end, "recovery result revision must follow its exact request revision")
quarantine(function(outcomes) outcomes["confirm-current"].request.intent_id = "unknown-intent" end, "confirmation must reference matching durable begin-recovery outcome")
quarantine(function(outcomes) outcomes["register-1"].response.owner_id = controller.owner_id end, "registration cannot fabricate ownership fields")
local replay_registry = state.rehydrate(current)
check(replay_registry ~= nil, "operation-specific outcome checks accept complete valid history")
local same_registry, historical_grant = state.apply(replay_registry, reservation_request)
check(same_registry == replay_registry and historical_grant.replayed == true and historical_grant.owner.owner_id == coordinator.owner_id
	and replay_registry.sessions[session_id].orchestrator.owner_id == null_owner.owner_id, "validated retired grant replays its original outcome without replacing current owner")

-- Construct an equivalent sequence of repeated successful uncertainty observations
-- in linear time: only request identity and committed revision differ per event.
local capacity = state.new_registry()
capacity = assert(state.apply(capacity, { kind = "register_session", request_id = "capacity-register", name = "Capacity" }))
local capacity_session = "orch-1"
local capacity_result
capacity, capacity_result = state.apply(capacity, { kind = "reserve_coordinator", request_id = "capacity-reserve", orch_session_id = capacity_session })
local capacity_owner = capacity_result.owner
capacity = assert(state.apply(capacity, owned("bind_coordinator", "capacity-bind", capacity_session, capacity_owner, { pane_binding = binding })))
capacity = assert(state.apply(capacity, owned("mark_uncertain", "capacity-observation", capacity_session, capacity_owner, { target = "orchestrator", reason = "unconfirmed" })))
local byte_limited = clone(capacity)
local reserve_clock = { now_ms = 2000, reserved_capacity = true }
local byte_before = runtime.json.encode(byte_limited)
local speculative = state.apply(byte_limited, { kind = "register_session", request_id = "byte-admission", name = "Speculative" }, 2000)
local byte_admission, byte_admission_error = state.apply(byte_limited, { kind = "register_session", request_id = "byte-admission", name = "Speculative" }, reserve_clock)
check(speculative ~= nil and byte_admission == nil and byte_admission_error.code == "capacity_reached" and runtime.json.encode(byte_limited) == byte_before, "host may discard speculative byte-overflow candidate and reapply the shared reserve gate without mutation")
local byte_repeat, byte_repeat_error = state.apply(byte_limited, owned("observe_owner", "byte-repeat-live", capacity_session, capacity_owner, { target = "orchestrator", status = "still live", evidence = "observed", owner_active = true }), reserve_clock)
check(byte_repeat == nil and byte_repeat_error.code == "no_progress", "byte reserve uses the same no-progress observation policy before outcome count fills")
local byte_active, byte_active_error = state.apply(byte_limited, owned("begin_recovery", "byte-active-recovery", capacity_session, capacity_owner, { target = "orchestrator", expected_revision = byte_limited.revision }), reserve_clock)
check(byte_active == nil and byte_active_error.code == "owner_active", "byte-reserved recovery preparation requires current active facts resolved")
byte_limited = assert(state.apply(byte_limited, owned("observe_owner", "byte-unavailable", capacity_session, capacity_owner, { target = "orchestrator", status = "unavailable", evidence = "observed" }), reserve_clock))
byte_limited = assert(state.apply(byte_limited, owned("observe_owner", "byte-verified", capacity_session, capacity_owner, { target = "orchestrator", status = "operator verified stop", evidence = "operator_attested", operator_verified = true, owner_active = false, pending_executors = 0 }), reserve_clock))
local no_downgrade, no_downgrade_error = state.apply(byte_limited, owned("observe_owner", "byte-repeat-absence", capacity_session, capacity_owner, { target = "orchestrator", status = "unavailable", evidence = "observed" }), reserve_clock)
check(no_downgrade == nil and no_downgrade_error.code == "no_progress" and byte_limited.sessions[capacity_session].orchestrator.owner_active == false, "rechecking the same absence cannot cycle verified inactivity back to unknown and consume reserve")
local byte_intent
byte_limited, byte_intent = state.apply(byte_limited, owned("begin_recovery", "byte-ready-recovery", capacity_session, capacity_owner, { target = "orchestrator", expected_revision = byte_limited.revision }), reserve_clock)
byte_limited = assert(state.apply(byte_limited, owned("confirm_recovery", "byte-confirm", capacity_session, capacity_owner, { target = "orchestrator", expected_revision = byte_limited.revision, intent_id = byte_intent.intent_id, operator_verified = true, evidence = "operator_attested" }), reserve_clock))
check(byte_limited.sessions[capacity_session].orchestrator == nil and state.rehydrate(byte_limited) ~= nil, "byte-reserved fact reconciliation and final clear remain durable")
local function fill_outcomes(registry, target)
	local template = registry.request_outcomes["capacity-observation"]
	local existing = 0
	for _ in registry.request_outcomes do existing += 1 end
	for index = existing + 1, target do
		local request_id = "capacity-history-" .. tostring(index)
		local outcome = clone(template)
		registry.revision += 1
		outcome.request.request_id, outcome.response.request_id = request_id, request_id
		outcome.response.revision = registry.revision
		registry.request_outcomes[request_id] = outcome
	end
end
local ordinary_limit = state.LIMITS.requests - state.LIMITS.settlement_reserve
fill_outcomes(capacity, ordinary_limit - 1)
check(state.rehydrate(capacity) ~= nil, "linear capacity fixture is a valid durable history")
capacity, capacity_result = state.apply(capacity, { kind = "admit_controller", request_id = "capacity-last-admission", orch_session_id = capacity_session, pane_binding = binding })
check(capacity ~= nil and capacity_result.code == "controller_granted", "last ordinary outcome slot can grant ownership")
local capacity_controller = capacity_result.owner
local at_ordinary_limit = runtime.json.encode(capacity)
local no_admission, capacity_error = state.apply(capacity, { kind = "register_session", request_id = "capacity-refused-registration", name = "Do not consume settlement reserve" })
check(no_admission == nil and capacity_error.code == "capacity_reached" and runtime.json.encode(capacity) == at_ordinary_limit, "next admission leaves settlement reserve untouched")
check(capacity.request_outcomes["capacity-refused-registration"] == nil, "capacity rejection does not consume request identity")
local no_observation, no_observation_result = state.apply(capacity, owned("observe_owner", "capacity-repeat-active", capacity_session, capacity_controller,
	{ target = "controller", status = "still active", evidence = "observed", owner_active = true, pending_executors = 0 }))
check(no_observation == nil and no_observation_result.code == "no_progress" and runtime.json.encode(capacity) == at_ordinary_limit, "repeated current facts cannot consume settlement reserve")
local crash_path = assert(state.rehydrate(capacity))
crash_path = assert(state.apply(crash_path, owned("observe_owner", "last-admission-unavailable", capacity_session, capacity_controller, { target = "controller", status = "unavailable", evidence = "observed" })))
local unavailable_revision = crash_path.revision
local repeat_unavailable, repeat_unavailable_result = state.apply(crash_path, owned("observe_owner", "last-admission-repeat-unavailable", capacity_session, capacity_controller, { target = "controller", status = "unavailable", evidence = "observed" }))
check(repeat_unavailable == nil and repeat_unavailable_result.code == "no_progress" and crash_path.revision == unavailable_revision, "first unavailable fact persists but repeated unavailable checks use no reserve")
crash_path = assert(state.apply(crash_path, owned("observe_owner", "last-admission-verified", capacity_session, capacity_controller, { target = "controller", status = "operator verified stopped", evidence = "operator_attested", operator_verified = true, owner_active = false, pending_executors = 0 })))
local crash_intent
crash_path, crash_intent = state.apply(crash_path, owned("begin_recovery", "last-admission-recover", capacity_session, capacity_controller, { target = "controller", expected_revision = crash_path.revision }))
local same_intent_revision = crash_path.revision
local superseded, superseded_result = state.apply(crash_path, owned("begin_recovery", "last-admission-repeat-begin", capacity_session, capacity_controller, { target = "controller", expected_revision = crash_path.revision }))
check(superseded == nil and superseded_result.code == "settlement_pending" and crash_path.revision == same_intent_revision, "new request IDs cannot repeatedly supersede current reserved recovery")
local other_intent, other_intent_result = state.apply(crash_path, owned("begin_recovery", "last-admission-competing-begin", capacity_session, capacity_owner, { target = "orchestrator", expected_revision = crash_path.revision }))
check(other_intent == nil and other_intent_result.code == "settlement_pending", "alternating owners cannot invalidate each other's reserved intents")
check(other_intent_result.orch_session_id == capacity_session and other_intent_result.target == "controller"
	and other_intent_result.intent_id == crash_intent.intent_id and other_intent_result.owner.owner_id == capacity_controller.owner_id
	and string.find(other_intent_result.message, crash_intent.intent_id, 1, true) ~= nil and string.find(other_intent_result.message, capacity_session, 1, true) ~= nil,
	"serialization refusal names the blocking session, slot, owner and intent")
local blocked_retirement, blocked_retirement_result = state.apply(crash_path, owned("request_retirement", "last-admission-blocked-retirement", capacity_session, capacity_owner))
check(blocked_retirement == nil and blocked_retirement_result.code == "settlement_pending" and blocked_retirement_result.intent_id == crash_intent.intent_id,
	"another owner's reserved retirement waits behind the named intent")
local reloaded = assert(state.rehydrate(clone(crash_path)))
local lifted, lifted_result = state.apply(reloaded, owned("request_retirement", "last-admission-reloaded-retirement", capacity_session, capacity_owner))
local function outcome_count(registry) local n = 0; for _ in registry.request_outcomes do n += 1 end; return n end
check(lifted ~= nil and lifted_result.ok and reloaded.sessions[capacity_session].controller.recovery == nil
	and outcome_count(reloaded) == outcome_count(crash_path), "host reload withdraws the pending intent without consuming reserve")
local crash_confirmation = owned("confirm_recovery", "last-admission-confirm", capacity_session, capacity_controller, { target = "controller", expected_revision = crash_path.revision,
	intent_id = crash_intent.intent_id, operator_verified = true, evidence = "operator_attested" })
local live_branch = assert(state.apply(crash_path, owned("observe_owner", "last-admission-new-live-fact", capacity_session, capacity_controller, { target = "controller", status = "native owner became active", evidence = "observed", owner_active = true })))
local cannot_clear, cannot_clear_result = state.apply(live_branch, crash_confirmation)
check(cannot_clear == nil and cannot_clear_result.code == "stale_revision" and live_branch.sessions[capacity_session].controller.owner_active == true, "fresh live evidence bypasses settlement serialization and invalidates earlier confirmation")
crash_path = assert(state.apply(crash_path, crash_confirmation))
check(crash_path.sessions[capacity_session].controller == nil and crash_path.sessions[capacity_session].orchestrator ~= nil, "last ordinary admission can crash, be externally verified, and recover using reserved capacity")
check(state.rehydrate(crash_path) ~= nil, "last-admission recovery history validates after reload")
capacity, capacity_result = state.apply(capacity, owned("release_controller", "capacity-controller-release", capacity_session, capacity_controller))
check(capacity ~= nil and capacity_result.code == "owner_retired" and capacity.sessions[capacity_session].controller == nil, "controller release succeeds after ordinary history fills")
local hard_full_seed = clone(capacity)
capacity = assert(state.apply(capacity, owned("request_retirement", "capacity-retirement", capacity_session, capacity_owner)))
local retirement_revision = capacity.revision
local repeat_retirement, repeat_retirement_result = state.apply(capacity, owned("request_retirement", "capacity-repeat-retirement", capacity_session, capacity_owner))
check(repeat_retirement == nil and repeat_retirement_result.code == "no_progress" and capacity.revision == retirement_revision, "repeated retirement requests cannot consume reserve")
capacity = assert(state.apply(capacity, owned("observe_owner", "capacity-unavailable", capacity_session, capacity_owner, { target = "orchestrator", status = "unavailable", evidence = "observed" })))
capacity = assert(state.apply(capacity, owned("observe_owner", "capacity-verified", capacity_session, capacity_owner, { target = "orchestrator", status = "operator verified stopped", evidence = "operator_attested", operator_verified = true, owner_active = false, pending_executors = 0 })))
capacity, capacity_result = state.apply(capacity, owned("begin_recovery", "capacity-recovery-intent", capacity_session, capacity_owner, { target = "orchestrator", expected_revision = capacity.revision }))
check(capacity ~= nil and capacity_result.intent_id ~= nil, "recovery intent can consume reserved settlement capacity")
local capacity_confirmation = owned("confirm_recovery", "capacity-recovery-confirm", capacity_session, capacity_owner, { target = "orchestrator", expected_revision = capacity.revision,
	intent_id = capacity_result.intent_id, operator_verified = true, evidence = "operator_attested" })
capacity, capacity_result = state.apply(capacity, capacity_confirmation)
check(capacity ~= nil and capacity_result.code == "owner_retired" and capacity.sessions[capacity_session].orchestrator == nil, "reserved capacity completes recovery without automatic replacement")
check(state.rehydrate(capacity) ~= nil, "settlement history survives strict restoration")
local retired_revision = capacity.revision
local redundant_release, redundant_release_result = state.apply(capacity, owned("release_coordinator", "capacity-redundant-release", capacity_session, capacity_owner, { quiescent = true }))
check(redundant_release == nil and redundant_release_result.code == "owner_already_retired" and capacity.revision == retired_revision, "new IDs for settled releases cannot exhaust remaining capacity")

-- Finite storage can still fill with genuinely changing external safety facts.
-- Construct that valid alternating history in linear time, never repeated no-ops.
local full = hard_full_seed
full = assert(state.apply(full, owned("observe_owner", "full-inactive-template", capacity_session, capacity_owner, { target = "orchestrator", status = "observed stopped", evidence = "observed", owner_active = false })))
full = assert(state.apply(full, owned("observe_owner", "full-active-template", capacity_session, capacity_owner, { target = "orchestrator", status = "observed active", evidence = "observed", owner_active = true })))
local used = 0
for _ in full.request_outcomes do used += 1 end
for index = used + 1, state.LIMITS.requests do
	local active = full.sessions[capacity_session].orchestrator.owner_active ~= true
	local outcome = clone(full.request_outcomes[if active then "full-active-template" else "full-inactive-template"])
	local request_id = "full-changing-fact-" .. tostring(index)
	full.revision += 1
	outcome.request.request_id, outcome.response.request_id, outcome.response.revision = request_id, request_id, full.revision
	full.request_outcomes[request_id] = outcome
	full.sessions[capacity_session].orchestrator = clone(outcome.response.owner)
end
check(state.rehydrate(full) ~= nil, "hard-full fixture retains a valid ordered history")
local full_before = runtime.json.encode(full)
local no_settlement, full_error = state.apply(full, owned("request_retirement", "hard-full-new-retirement", capacity_session, capacity_owner))
check(no_settlement == nil and full_error.code == "capacity_reached" and runtime.json.encode(full) == full_before, "hard-full history is not evicted or mutated for a new settlement identity")
local replay_full, full_replay = state.apply(full, owned("release_controller", "capacity-controller-release", capacity_session, capacity_controller))
check(replay_full == full and full_replay.replayed == true and full_replay.code == "owner_retired", "lost committed settlement response remains replayable even at hard full")

-- The last ordinary coordinator reservation must still complete its existing
-- binding; neither count reserve nor byte reserve is permission to launch again.
do
	local binding_capacity = assert(state.apply(state.new_registry(), { kind = "register_session", request_id = "binding-register", name = "Binding capacity" }))
	local binding_result
	binding_capacity, binding_result = state.apply(binding_capacity, { kind = "admit_controller", request_id = "binding-controller", orch_session_id = "orch-1", pane_binding = binding })
	local binding_controller = binding_result.owner
	binding_capacity = assert(state.apply(binding_capacity, owned("mark_uncertain", "capacity-observation", "orch-1", binding_controller, { target = "controller", reason = "unconfirmed" })))
	local byte_binding = clone(binding_capacity)
	fill_outcomes(binding_capacity, ordinary_limit - 1)
	binding_capacity, binding_result = state.apply(binding_capacity, { kind = "reserve_coordinator", request_id = "binding-last-reservation", orch_session_id = "orch-1" })
	check(binding_capacity ~= nil and binding_result.owner.phase == "reserved" and binding_result.owner.pane_binding == nil, "last ordinary slot durably reserves a pane-less coordinator")
	local reserved_owner = binding_result.owner
	binding_capacity, binding_result = state.apply(binding_capacity, owned("bind_coordinator", "binding-after-threshold", "orch-1", reserved_owner, { pane_binding = binding }))
	check(binding_capacity ~= nil and binding_result.owner.phase == "active" and binding_result.owner.owner_id == reserved_owner.owner_id, "reserved outcome capacity completes the same coordinator binding")
	local bound_revision = binding_capacity.revision
	local duplicate, duplicate_result = state.apply(binding_capacity, owned("bind_coordinator", "binding-new-id-repeat", "orch-1", reserved_owner, { pane_binding = binding }))
	check(duplicate == nil and duplicate_result.code == "not_reserved" and binding_capacity.revision == bound_revision, "unchanged fresh-ID bind cannot spend another reserved outcome")
	check(state.rehydrate(binding_capacity) ~= nil, "last-slot coordinator reservation and binding survive strict restoration")

	byte_binding, binding_result = state.apply(byte_binding, { kind = "reserve_coordinator", request_id = "byte-binding-reservation", orch_session_id = "orch-1" })
	reserved_owner = binding_result.owner
	byte_binding = assert(state.apply(byte_binding, owned("observe_owner", "byte-binding-controller-stopped", "orch-1", binding_controller, { target = "controller", status = "observed stopped", evidence = "observed", owner_active = false, pending_executors = 0 }), reserve_clock))
	local pending_intent
	byte_binding, pending_intent = state.apply(byte_binding, owned("begin_recovery", "byte-binding-controller-recovery", "orch-1", binding_controller, { target = "controller", expected_revision = byte_binding.revision }), reserve_clock)
	local earlier_confirmation = owned("confirm_recovery", "byte-binding-old-confirm", "orch-1", binding_controller, { target = "controller", expected_revision = byte_binding.revision, intent_id = pending_intent.intent_id, operator_verified = true, evidence = "operator_attested" })
	byte_binding, binding_result = state.apply(byte_binding, owned("bind_coordinator", "byte-binding-completion", "orch-1", reserved_owner, { pane_binding = binding }), reserve_clock)
	check(byte_binding ~= nil and binding_result.owner.phase == "active", "forced byte reserve permits one binding completion even while another owner's recovery is pending")
	local stale_clear, stale_clear_result = state.apply(byte_binding, earlier_confirmation, reserve_clock)
	check(stale_clear == nil and stale_clear_result.code == "stale_revision", "binding completion is retained as new evidence and invalidates older recovery confirmation")
	bound_revision = byte_binding.revision
	duplicate, duplicate_result = state.apply(byte_binding, owned("bind_coordinator", "byte-binding-repeat", "orch-1", reserved_owner, { pane_binding = binding }), reserve_clock)
	check(duplicate == nil and duplicate_result.code == "not_reserved" and byte_binding.revision == bound_revision, "byte-reserved binding completion remains one-shot")
	check(state.rehydrate(byte_binding) ~= nil, "byte-reserved binding outcome remains valid durable history")
end
return "PASS " .. tostring(checks) .. " ownership state checks"
