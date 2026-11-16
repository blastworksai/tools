-- Run in Tern's Lua runtime with the plugin directory as the only argument.
local root = ...
assert(type(root) == "string", "pass the plugin directory")
local runtime, environment = tern, getfenv()
local modules = {}
local function load(name, base)
	name = (base or "") .. name:gsub("^%./", "")
	if modules[name] ~= nil then return modules[name] end
	local chunk = assert(loadstring(runtime.fs.read(root .. "/" .. name .. ".luau"), name))
	local dir = name:match("^(.*/)")
	setfenv(chunk, setmetatable({ require = function(n) return load(n, dir) end, tern = runtime }, { __index = environment }))
	local value = chunk(); modules[name] = value; return value
end
local state, dispatch, codec = load("state"), load("dispatch"), load("wire/codec")
local checks = 0
local function check(condition, message) assert(condition, message); checks += 1 end
local function clone(value) return runtime.json.decode(runtime.json.encode(value)) end
local binding = { host_pane_id = "42", alias_nonce = "host-issued-nonce" }
local current = state.new_registry("state-fixture-authority")
local sequence = 0
-- Capture once when the test creates the intent. Replays pass the original table.
local function intent(kind, sid, extra, registry)
	registry = registry or current
	sequence += 1
	local event = { kind = kind, request_id = "intent-" .. sequence, orch_session_id = sid,
		authority_namespace = registry.authority_namespace, expected_revision = registry.revision }
	for key, value in extra or {} do event[key] = value end
	return event
end
local function owned(kind, sid, owner, extra, registry)
	local event = intent(kind, sid, extra, registry)
	event.expected_owner_id, event.expected_generation = owner.owner_id, owner.generation
	return event
end
local function accept(event, code, clock)
	local before = runtime.json.encode(current)
	local candidate, result = state.apply(current, event, clock or 1000)
	check(candidate ~= nil and result.ok and (code == nil or result.code == code), tostring(code) .. ": " .. tostring(result.code))
	check(runtime.json.encode(current) == before, "candidate leaves previous authority unchanged")
	current = candidate
	return result
end
local function reject(event, code, clock)
	local before = runtime.json.encode(current)
	local candidate, result = state.apply(current, event, clock or 1000)
	check(candidate == nil and not result.ok and result.code == code, code .. ": " .. tostring(result.code))
	check(runtime.json.encode(current) == before, "refusal changes no authority")
end
for _, raw in { false, true, 17, "broken", runtime.json.null } do
	local restored, problem = state.rehydrate(raw)
	check(restored == nil and problem ~= nil and problem.ok == false, "corrupt scalar input returns a refusal, never fresh authority or an indexing exception")
end
local missing, diagnostic = state.rehydrate(nil)
check(missing == nil and diagnostic.code == "state_missing", "missing established store requires recovery")
check(current.version == 5 and current.request_outcomes == nil and current.retired == nil and current.next_session_id == nil,
	"fresh authority contains current state only")
for _, kind in { "register_session", "installation_defaults", "setup_lifecycle", "workflow_tick", "dispatch", "dispatch_reconcile" } do
	reject({ kind = kind, request_id = "unfenced" }, "invalid_event")
	local wrong = intent(kind, "session-a"); wrong.authority_namespace = "another-authority"
	reject(wrong, "stale_authority")
	local stale = intent(kind, "session-a"); stale.expected_revision += 1
	if kind ~= "register_session" then reject(stale, "stale_revision") end
end
reject(intent("register_session", "bad identity", { name = "Invalid" }), "invalid_event")
reject(intent("register_session", "session-a", { name = "bad\nname" }), "invalid_event")
reject(intent("register_session", "session-a", { name = "Name", injected = true }), "invalid_event")
local registration = intent("register_session", "session-a", { name = "Project", binding = binding })
accept(registration, "session_registered")
local revision = current.revision
accept(registration, "already_registered")
check(current.revision == revision, "current registration observation has no write")
local conflict = clone(registration); conflict.name = "Different"
reject(conflict, "session_conflict")
accept(intent("register_session", "session-b", { name = "Independent" }), "session_registered")
local admission = intent("admit_controller", "session-a", { pane_binding = binding })
local controller = accept(admission, "controller_granted").owner
accept(admission, "current_owner")
reject(intent("admit_controller", "session-a", { pane_binding = { host_pane_id = "99", alias_nonce = "other" } }), "controller_slot_occupied")
local reservation = intent("reserve_coordinator", "session-a", { work_id = "work-a" })
local coordinator = accept(reservation, "orchestrator_granted").owner
check(coordinator.phase == "reserved" and coordinator.pane_binding == nil, "reservation is occupied before native launch")
accept(reservation, "current_owner")
reject(intent("reserve_coordinator", "session-a", { work_id = "other-work" }), "orchestrator_slot_occupied")
local discarded = owned("bind_coordinator", "session-a", coordinator, { pane_binding = binding })
local before = runtime.json.encode(current)
local candidate = state.apply(current, discarded, 1100)
check(candidate ~= nil and candidate.sessions["session-a"].orchestrator.phase == "active", "binding produces candidate")
check(runtime.json.encode(current) == before, "discarded failed-write candidate preserves reservation")
coordinator = accept(discarded, "accepted").owner
reject(owned("bind_coordinator", "session-a", coordinator, { pane_binding = binding }), "not_reserved")
reject(owned("release_coordinator", "session-a", coordinator), "invalid_event")
accept(owned("request_retirement", "session-a", coordinator), "accepted")
reject(owned("release_coordinator", "session-a", coordinator, { quiescent = true }), "owner_active")
reject(owned("observe_owner", "session-a", coordinator, { target = "orchestrator", status = "checkbox", evidence = "operator_attested",
	operator_verified = true, owner_active = false, pending_executors = 0 }), "owner_active")
accept(owned("observe_owner", "session-a", coordinator, { target = "orchestrator", status = "native stopped; executor unresolved",
	evidence = "observed", owner_active = false, pending_executors = 1 }))
reject(owned("release_coordinator", "session-a", coordinator, { quiescent = true }), "pending_executors")
local begin = owned("begin_recovery", "session-a", coordinator, { target = "orchestrator" })
local recovery = accept(begin, "accepted")
accept(begin, "recovery_pending")
local confirmation = owned("confirm_recovery", "session-a", coordinator, { target = "orchestrator", intent_id = recovery.intent_id,
	operator_verified = true, evidence = "operator_attested" })
reject(confirmation, "pending_executors")
reject(owned("release_coordinator", "session-a", coordinator, { quiescent = true }), "recovery_fenced")
accept(owned("observe_owner", "session-a", coordinator, { target = "orchestrator", status = "native executor stopped", evidence = "observed", pending_executors = 0 }))
reject(confirmation, "stale_revision")
recovery = accept(owned("begin_recovery", "session-a", coordinator, { target = "orchestrator" }))
confirmation = owned("confirm_recovery", "session-a", coordinator, { target = "orchestrator", intent_id = recovery.intent_id,
	operator_verified = true, evidence = "operator_attested" })
local wrong = clone(confirmation); wrong.intent_id = "wrong"
reject(wrong, "stale_recovery")
accept(confirmation, "owner_retired")
check(current.sessions["session-a"].orchestrator == nil and current.sessions["session-a"].orchestrator_generation > coordinator.generation,
	"recovery removes binding and advances generation without an old-owner record")
local replacement = accept(intent("reserve_coordinator", "session-a", { work_id = "replacement" })).owner
accept(confirmation, "not_held")
reject(reservation, "stale_revision")
check(current.sessions["session-a"].orchestrator.owner_id == replacement.owner_id, "stale recovery cannot clear successor")
accept(owned("release_coordinator", "session-a", replacement, { quiescent = true }), "owner_retired")
do
	local admitted = clone(current)
	admitted.next_admission_seq = 2
	admitted.sessions["session-a"].admission_seq = 1
	admitted.sessions["session-a"].spawn_namespace = "spawn-fixture"
	admitted.sessions["session-a"].admitted = true
	local retired, outcome = state.apply(admitted, owned("release_controller", "session-a", controller, nil, admitted), 1000)
	check(retired ~= nil and outcome.ok and retired.sessions["session-a"].admitted == nil
		and retired.sessions["session-a"].admission_seq == 1
		and admitted.sessions["session-a"].admitted == true,
		"controller retirement withdraws executable admission without replacing its identity or mutating prior authority")
	local claimed, granted = state.apply(retired, intent("admit_controller", "session-a", { pane_binding = binding }, retired), 1000)
	check(claimed ~= nil and granted.ok and claimed.sessions["session-a"].admitted == nil
		and claimed.sessions["session-a"].admission_seq == 1
		and granted.owner.generation > claimed.sessions["session-a"].generation_floor,
		"a replacement controller cannot inherit its predecessor's admission permission")
end
local release = owned("release_controller", "session-a", controller)
accept(release, "owner_retired")
local successor = accept(intent("admit_controller", "session-a", { pane_binding = binding })).owner
accept(release, "not_held")
check(current.sessions["session-a"].controller.owner_id == successor.owner_id
	and successor.generation > current.sessions["session-a"].generation_floor, "old release never clears newer generation")
local pending = accept(owned("begin_recovery", "session-a", successor, { target = "controller" }))
local old_confirmation = owned("confirm_recovery", "session-a", successor, { target = "controller", intent_id = pending.intent_id,
	operator_verified = true, evidence = "operator_attested" })
local persisted = clone(current)
current = assert(state.rehydrate(persisted))
check(current.authority_namespace == persisted.authority_namespace and current.execution_epoch > persisted.execution_epoch,
	"reload preserves immutable namespace and advances runtime fence")
check(current.sessions["session-a"].controller.phase == "uncertain" and current.sessions["session-a"].controller.recovery == nil,
	"reload retains ownership but invalidates recovery intent")
reject(old_confirmation, "stale_revision")
accept(admission, "current_owner")
accept(registration, "already_registered")
accept(owned("observe_owner", "session-a", successor, { target = "controller", status = "unavailable", evidence = "observed" }))
check(current.sessions["session-a"].controller.owner_active == nil, "unavailability is not absence")
accept(owned("observe_owner", "session-a", successor, { target = "controller", status = "externally verified stopped", evidence = "operator_attested",
	operator_verified = true, owner_active = false, pending_executors = 0 }))
local projected = state.project(current, { orch_session_id = "session-a" })
projected.session.controller.owner_id = "view-edit"
check(current.sessions["session-a"].controller.owner_id == successor.owner_id and projected.authority_namespace == current.authority_namespace,
	"current metadata projection does not expose mutable authority")
for _, damage in {
	function(r) r.request_outcomes = {} end,
	function(r) r.retired = {} end,
	function(r) r.sessions["session-a"].controller.generation += 1 end,
	function(r) r.sessions["session-a"].controller.pending_executors = 1025 end,
	function(r) r.sessions["session-a"].generation_floor = r.sessions["session-a"].controller.generation end,
	function(r) r.sessions["session-a"].phase = "closed" end,
	function(r) r.sessions["session-a"].next_request_serial = 0 end,
	function(r) r.sessions["session-a"].close = { close_id = "wrong", peer_closed = true } end,
	function(r) r.setup = nil end,
	function(r) r.authority_namespace = "" end,
} do
	local damaged = clone(current); damage(damaged)
	check(state.rehydrate(damaged) == nil, "strict current schema quarantines invalid source")
end
-- Actual accepted transitions exceed both former historical limits, not manufactured rows.
for index = 1, 4100 do
	accept(owned("mark_uncertain", "session-a", successor, { target = "controller", reason = "observation-" .. index }))
end
accept(owned("release_controller", "session-a", successor))
for _ = 1, 2050 do
	local owner = accept(intent("admit_controller", "session-a", { pane_binding = binding })).owner
	accept(owned("release_controller", "session-a", owner))
end
check(current.request_outcomes == nil and current.retired == nil and current.sessions["session-a"].controller == nil,
	"more than 4096 commands and 2048 releases retain no completed histories")
local other = runtime.json.encode(current.sessions["session-b"])
local policy = runtime.json.encode(current.dispatch.policies["session-b"])
for index = 1, 70 do
	local sid = "lifetime-" .. index
	local captured = intent("register_session", sid, { name = "Lifetime " .. index })
	accept(captured)
	accept(intent("begin_close", sid, { close_id = "close-" .. index }), "session_closing")
	reject(intent("admit_controller", sid, { pane_binding = binding }), "session_closing")
	local closing = clone(current)
	check(state.rehydrate(closing) ~= nil, "closing phase restores")
	accept(intent("confirm_close", sid, { close_id = "close-" .. index }), "session_closed")
	check(current.sessions[sid] == nil and current.dispatch.policies[sid] == nil, "session and scoped policy reclaimed atomically")
	reject(captured, "stale_revision")
end
check(runtime.json.encode(current.sessions["session-b"]) == other and runtime.json.encode(current.dispatch.policies["session-b"]) == policy,
	"more than 64 lifetime sessions preserves the other live session")
-- Closing admitted session captures a current origin, never fabricates an active owner after release.
local close_owner = accept(intent("admit_controller", "session-a", { pane_binding = binding })).owner
local origin = { logical_session_id = "session-a", owner_id = close_owner.owner_id, owner_generation = close_owner.generation,
	host_pane_id = binding.host_pane_id, alias_nonce = binding.alias_nonce, window_key = "", window_epoch = "close-window",
	native_session_id = "native-session", window_host_id = "native-host" }
accept(owned("observe_owner", "session-a", close_owner, { target = "controller", status = "native executor remains", evidence = "observed", pending_executors = 1 }))
reject(intent("begin_close", "session-a", { close_id = "close-main", control_origin = { kind = "closing", binding = origin, controller_pane = "42", close_id = "close-main" } }), "session_busy")
accept(owned("observe_owner", "session-a", close_owner, { target = "controller", status = "native executors settled", evidence = "observed", pending_executors = 0 }))
local unconfirmed = assert(state.rehydrate(clone(current)))
local refused_close, close_problem = state.apply(unconfirmed, intent("begin_close", "session-a", { close_id = "close-main",
	control_origin = { kind = "closing", binding = origin, controller_pane = "42", close_id = "close-main" } }, unconfirmed))
check(refused_close == nil and close_problem.code == "session_busy", "restored zero executor counts remain unconfirmed and cannot authorize closure")
accept(intent("begin_close", "session-a", { close_id = "close-main", control_origin = { kind = "closing", binding = origin, controller_pane = "42", close_id = "close-main" } }))
reject(intent("confirm_close", "session-a", { close_id = "close-main" }), "session_busy")
accept(owned("release_controller", "session-a", close_owner))
accept(intent("confirm_close", "session-a", { close_id = "close-main" }), "session_closed")
reject(registration, "stale_revision")
check(state.rehydrate(current) ~= nil, "absent close phase restores without a retained identity")
-- Setup uses BOTH the authority revision and its independent config revision.
local fresh = state.new_registry("setup-fixture")
local function defaults_event(registry)
	local defaults = clone(registry.installation_defaults); defaults.revision = nil; defaults.defined = nil; defaults.family_migrations = nil
	return intent("installation_defaults", nil, { expected_config_revision = registry.installation_defaults.revision, defaults = defaults }, registry)
end
local defined_defaults, defined_reply = state.apply(fresh, defaults_event(fresh))
check(defined_defaults ~= nil and defined_defaults ~= fresh and defined_reply.ok
	and fresh.installation_defaults.defined == false and defined_defaults.installation_defaults.defined == true
	and defined_defaults.setup.state == fresh.setup.state,
	"the first explicit unchanged default save defines defaults without completing setup")
local unchanged_defaults, defaults_reply = state.apply(defined_defaults, defaults_event(defined_defaults))
check(unchanged_defaults == defined_defaults and defaults_reply.code == "no_progress"
	and defaults_reply.revision == defined_defaults.revision and defaults_reply.config_revision == defined_defaults.installation_defaults.revision,
	"subsequent unchanged default saves retain both authoritative fences")
local forged_definition = defaults_event(fresh); forged_definition.defaults.defined = true
local refused_definition, forged_reply = state.apply(fresh, forged_definition)
check(refused_definition == nil and forged_reply.code == "invalid_defaults" and fresh.installation_defaults.defined == false,
	"clients cannot supply the authoritative definition marker")
do
	local retired_defaults = defaults_event(fresh)
	retired_defaults.defaults.policy.role_guidance = { builder = "Retired override.", reviewer = "", release_manager = "", labeller = "", coordinator = "" }
	local refused_override, retired_reply = state.apply(fresh, retired_defaults)
	check(refused_override == nil and retired_reply.code == "invalid_defaults" and fresh.installation_defaults.policy.role_guidance == nil,
		"live defaults cannot reintroduce a retired custom role override through historical-shape migration")
end
local started = assert(state.apply(fresh, intent("setup_lifecycle", nil,
	{ expected_config_revision = fresh.installation_defaults.revision, state = "in_progress" }, fresh)))
check(started.installation_defaults.defined == false, "setup lifecycle revisions do not define default settings")
local legacy_definition = clone(started); legacy_definition.installation_defaults.defined = nil
local restored_definition = assert(state.rehydrate(legacy_definition))
check(restored_definition.installation_defaults.defined == nil
	and assert(state.rehydrate(defined_defaults)).installation_defaults.defined == true,
	"restore retains ambiguous legacy save evidence rather than turning it into a never-saved marker")
local unchanged_setup, setup_reply = state.apply(started, intent("setup_lifecycle", nil,
	{ expected_config_revision = started.installation_defaults.revision, state = "in_progress" }, started))
check(unchanged_setup == started and setup_reply.code == "no_progress"
	and setup_reply.revision == started.revision and setup_reply.config_revision == started.installation_defaults.revision,
	"unchanged setup returns both current fences for the next explicit intent")
local first = assert(state.apply(fresh, intent("register_session", "first", { name = "First" }, fresh)))
local settings = defaults_event(first); settings.defaults.policy.require_code_review = false
local configured = assert(state.apply(first, settings))
check(not configured.installation_defaults.policy.require_other_family and dispatch.policy(configured, "first").require_code_review,
	"precontroller defaults normalize review-off without changing existing session")
local stale, failure = state.apply(configured, settings)
check(stale == nil and failure.code == "stale_revision", "two settings windows cannot refresh their creation fence")
local second = assert(state.apply(configured, intent("register_session", "second", { name = "Second" }, configured)))
check(not dispatch.policy(second, "second").require_code_review and dispatch.policy(second, "first").require_code_review,
	"new sessions capture defaults without rewriting live session policy")
settings = defaults_event(second)
settings.defaults.builder_record = "builder"; settings.defaults.policy.preferred_worker_record = "builder"
settings.defaults.policy.release_manager_record = "release"; settings.defaults.policy.merge_actor_mode = "selected_record"
local obsolete = clone(settings)
obsolete.defaults.repository = { cwd = "/repo", repo_root = "/repo", common_dir = "/repo/.git", target_ref = "refs/heads/main", head_revision = string.rep("a", 40), queue_route = "orch_queue" }
local rejected = state.apply(second, obsolete)
check(rejected == nil and second.installation_defaults.repository == nil, "reusable defaults cannot restore a global execution repository")
local applied, configuration_problem = state.apply(second, settings)
assert(applied, runtime.json.encode(configuration_problem)); configured = applied
local completion = intent("setup_lifecycle", nil, { expected_config_revision = configured.installation_defaults.revision, state = "completed", catalog_version = 2,
	spawn_setup = { schema = 1, state = "completed", config_revision = 2, readiness = { state = "not_run", config_revision = 0, summary = "" } },
	records = { { id = "builder", revision = 1, enabled = true, eligible = true, capabilities = { "report-files-v1", "check-runner-v1" } },
		{ id = "release", revision = 1, enabled = true, eligible = true, capabilities = { "report-files-v1", "release-manager-v1" } } } }, configured)
local conversation = clone(completion); conversation.records[1].capabilities = { "report-files-v1" }
local conversation_ready, conversation_problem = state.apply(configured, conversation)
check(conversation_ready ~= nil, "conversation setup needs no check-runner capability: " .. runtime.json.encode(conversation_problem or {}))
local incomplete = clone(completion); incomplete.records[1].capabilities = { "check-runner-v1" }
local not_ready, problem = state.apply(configured, incomplete)
check(not_ready == nil and problem.code == "setup_incomplete", "the selected conversation record must still provide report-files-v1")
for _, case in {
	{ name = "review off still separates signer from builder", review = false, family = false, signer = "builder", reviewers = {}, allowed = false },
	{ name = "review on separates signer from builder", review = true, family = false, signer = "builder", reviewers = { "reviewer" }, allowed = false },
	{ name = "signer cannot be the only reviewer", review = true, family = false, signer = "release", reviewers = { "release" }, allowed = false },
	{ name = "builder cannot be the only reviewer", review = true, family = false, signer = "release", reviewers = { "builder" }, allowed = false },
	{ name = "different-family policy needs compatible reviewer", review = true, family = true, signer = "release", reviewers = { "reviewer" }, provider = "Claude", allowed = false },
	{ name = "ineligible independent reviewer does not complete setup", review = true, family = false, signer = "release", reviewers = { "reviewer" }, ineligible = true, allowed = false },
	{ name = "signer cannot precede otherwise compatible reviewer", review = true, family = true, signer = "release", reviewers = { "release", "reviewer" }, allowed = false },
	{ name = "one compatible independent reviewer suffices", review = true, family = true, signer = "release", reviewers = { "missing", "reviewer" }, allowed = true },
	{ name = "review off ignores unused conflicting reviewers", review = false, family = false, signer = "release", reviewers = { "builder", "release", "missing" }, allowed = true },
} do
	local setup_settings = defaults_event(configured)
	setup_settings.defaults.policy.require_code_review = case.review
	setup_settings.defaults.policy.require_other_family = case.family
	setup_settings.defaults.policy.release_manager_record = case.signer
	setup_settings.defaults.policy.reviewer_records = runtime.json.array(clone(case.reviewers))
	local candidate = assert(state.apply(configured, setup_settings))
	local attempt = clone(completion)
	attempt.expected_revision, attempt.expected_config_revision = candidate.revision, candidate.installation_defaults.revision
	attempt.records[1].provider = "Claude"
	attempt.records[1].provider_family = "anthropic"
	table.insert(attempt.records[1].capabilities, "release-manager-v1")
	attempt.records[2].provider = "Codex"
	attempt.records[2].provider_family = "openai"
	table.insert(attempt.records, { id = "reviewer", revision = 1, provider = case.provider or "Codex",
		provider_family = if case.provider == "Claude" then "anthropic" else "openai", enabled = true,
		eligible = not case.ineligible, capabilities = { "report-files-v1" } })
	local before = runtime.json.encode(candidate)
	local finished, result = state.apply(candidate, attempt)
	check((finished ~= nil) == case.allowed and result.code == (if case.allowed then "setup_saved" else "setup_incomplete"), case.name)
	check(runtime.json.encode(candidate) == before, case.name .. " preserves prior authority")
end
local exercise_registry, exercise_session = state.apply(configured, intent("register_session", "exercise", { name = "Readiness" }, configured))
assert(exercise_registry and exercise_session.ok)
local exercised = intent("setup_lifecycle", nil, { expected_config_revision = exercise_registry.installation_defaults.revision,
	readiness = { state = "passed", config_revision = exercise_registry.installation_defaults.revision, summary = "Observed exercise." } }, exercise_registry)
local unfenced, unfenced_result = state.apply(exercise_registry, exercised)
check(unfenced == nil and unfenced_result.code == "stale_policy", "passed readiness requires the exercised session policy revision")
exercised.readiness_policy = { logical_session_id = "first", revision = 0 }
local overridden, override_result = state.apply(exercise_registry, exercised)
check(overridden == nil and override_result.code == "stale_policy", "different session override cannot qualify installation defaults")
exercised.readiness_policy = { logical_session_id = exercise_session.orch_session_id, revision = 0 }
local readiness_only = assert(state.apply(exercise_registry, exercised))
check(readiness_only.setup.state == configured.setup.state and readiness_only.setup.config_revision == configured.setup.config_revision,
	"even passed readiness does not manufacture required setup completion")
for _, invalid in { { logical_session_id = exercise_session.orch_session_id, revision = -1 },
	{ logical_session_id = exercise_session.orch_session_id, revision = 0, extra = true } } do
	local invalid_intent = clone(exercised); invalid_intent.readiness_policy = invalid
	local refused, refusal = state.apply(exercise_registry, invalid_intent)
	check(refused == nil and refusal.code == "invalid_readiness", "readiness policy fence keeps closed fields and revision bounds")
end
local completed = assert(state.apply(configured, completion))
check(completed.setup.state == "completed" and completed.setup.readiness.state == "not_run", "required setup does not fabricate optional readiness")
local readiness = intent("setup_lifecycle", nil, { expected_config_revision = completed.installation_defaults.revision,
	readiness = { state = "unavailable", config_revision = completed.installation_defaults.revision, summary = "Declined exercise." } }, completed)
local ready = assert(state.apply(completed, readiness))
settings = defaults_event(ready); settings.defaults.policy.require_code_review = true
local edited = assert(state.apply(ready, settings))
check(state.project(edited).setup.readiness_stale and edited.setup.state == "completed", "manual config changes stale readiness without reopening setup")
check(state.rehydrate(edited) ~= nil, "setup/default metadata validates on reload")
-- Paired migration is an explicit native-evidence boundary, never automatic reload.
local empty = state.new_registry("discarded-fixture-namespace")
local legacy = { version = 3, revision = 0, next_session_id = 0, next_owner_id = 0, execution_epoch = 1,
	sessions = {}, request_outcomes = {}, retired = {}, setup = clone(empty.setup), installation_defaults = clone(empty.installation_defaults) }
local normal = { schema = 1, sessions = runtime.json.array(), workers = runtime.json.array() }
local selection = { logical_session_ids = runtime.json.array(), mailbox_handles = runtime.json.array() }
local peer = { source_schema = 1, source_revision = 0, source_namespace = "spawn-fixture", source_sha256 = string.rep("a", 64),
	candidate_namespace = "spawn-fixture", protocol = 1, state = "ready", phase = "stable",
	managed_sha256 = assert(codec.dispatch_managed_digest(runtime.json.encode(normal))), pending_immutable = 0, blockers = 0 }
local migrated, migration_error = state.rehydrate(legacy)
check(migrated == nil and migration_error.code == "migration_blocked", "legacy runtime cannot activate before paired validation")
local blocked = clone(peer); blocked.pending_immutable = 1; blocked.state = "blocked"
check(state.prepare_migration(legacy, "migration-fixture", blocked, selection) == nil, "old issued grants block paired migration")
blocked = clone(peer); blocked.managed_sha256 = string.rep("b", 64)
check(state.prepare_migration(legacy, "migration-fixture", blocked, selection) == nil, "mismatched independently derived identities block migration")
check(state.prepare_migration(legacy, "migration-fixture", peer, normal) == nil, "full managed rows are not accepted as transport selection")
local duplicate_selection = { logical_session_ids = runtime.json.array({ "orch-1", "orch-1" }), mailbox_handles = runtime.json.array() }
check(state.prepare_migration(legacy, "migration-fixture", peer, duplicate_selection) == nil, "ambiguous duplicate selection cannot qualify either source")
local prepared = assert(state.prepare_migration(legacy, "migration-fixture", peer, selection))
check(prepared.version == 5 and prepared.migration ~= nil and prepared.request_outcomes == nil and prepared.retired == nil,
	"prepared migration retains only live source proof, never completed histories")
check(prepared.dispatch == nil and legacy.dispatch == nil,
	"migrating a source without dispatch work succeeds without inventing a dispatch graph or mutating its source")
local mutation, mutation_error = state.apply(prepared, intent("register_session", "blocked", { name = "Blocked" }, prepared))
check(mutation == nil and mutation_error.code == "migration_blocked", "prepared candidate cannot execute new authority intents")
check(state.rehydrate(prepared) ~= nil, "interrupted prepared candidate restores visibly blocked")
local local_proof = assert(state.migration_proof(prepared, selection))
local stable_peer = clone(peer); stable_peer.source_schema = 2; stable_peer.protocol = 2
local pair = { schema = 1, kind = "migration", orch = local_proof, spawn = stable_peer }
local stale_pair = clone(pair); stale_pair.orch.source_revision += 1
check(state.finish_migration(prepared, stale_pair, selection) == nil, "migration rejects a different exact local candidate identity")
local stable = assert(state.finish_migration(prepared, pair, selection))
check(stable.migration == nil and stable.compatibility.kind == "current" and stable.compatibility.spawn_namespace == "spawn-fixture",
	"validated paired candidates settle to compact current metadata")
check(state.finish_migration(prepared, stable.compatibility, selection) == nil, "compact current metadata cannot settle prepared migration")
local active_legacy = clone(legacy)
active_legacy.next_session_id = 1
active_legacy.sessions["orch-1"] = { orch_session_id = "orch-1", name = "Current fenced admission", created_at_ms = 0,
	controller_generation = 7, orchestrator_generation = 0 }
local active_normal = { schema = 1, sessions = runtime.json.array({ { logical_session_id = "orch-1" } }), workers = runtime.json.array() }
local active_selection = { logical_session_ids = runtime.json.array({ "orch-1" }), mailbox_handles = runtime.json.array() }
local active_peer = clone(peer)
active_peer.managed_sha256 = assert(codec.dispatch_managed_digest(runtime.json.encode(active_normal)))
local active_prepared = assert(state.prepare_migration(active_legacy, "active-migration", active_peer, active_selection))
check(active_prepared.sessions["orch-1"].admission_seq == 1 and active_prepared.next_admission_seq == 2
	and active_prepared.sessions["orch-1"].generation_floor == 7 and active_prepared.sessions["orch-1"].admitted == nil,
	"paired migration preserves a current ownerless session and its generation floor, without inventing retired bindings or admission permission")
do
	-- Historical v2 shape: no installation metadata, retained owner, paused policy and imported task.
	local origin = { logical_session_id = "orch-1", owner_id = "owner-1", owner_generation = 1,
		host_pane_id = "42", alias_nonce = "v2-alias", window_key = "v2-window", window_epoch = "v2-epoch",
		native_session_id = "3", window_host_id = "local" }
	local policy = dispatch.default_policy()
	policy.paused, policy.poll_ms, policy.release_manager_record = true, 7000, "saved-release-manager"
	policy.enforce_cross_family, policy.require_code_review, policy.require_other_family = false, nil, nil
	local source = { version = 2, revision = 13, next_session_id = 1, next_owner_id = 1, execution_epoch = 3,
		sessions = { ["orch-1"] = { orch_session_id = "orch-1", name = "Saved walkthrough", created_at_ms = 100,
			controller_generation = 1, orchestrator_generation = 0,
			controller = { owner_id = "owner-1", generation = 1, phase = "uncertain", created_at_ms = 101,
				pane_binding = { host_pane_id = "42", alias_nonce = "v2-alias" },
				pending_executors = 0, pending_executor_evidence = "unconfirmed" } } },
		request_outcomes = {}, retired = {},
		dispatch = { serial = 1, actions = {}, workers = {}, catalogs = {}, commands = {}, gates = {}, policies = { ["orch-1"] = policy },
			command_cursors = { ["orch-1"] = { origin = origin, controller_pane = "42", seq = 3, policy_revision = 12 } },
			plans = { ["plan-1"] = { plan_id = "plan-1", logical_session_id = "orch-1", path = "/plans/saved.md",
				plan_revision = string.rep("c", 64), title = "Saved plan", flags = {}, status = "active", at_ms = 102,
				checkpoints = { { n = 1, title = "Saved checkpoint", flags = {}, tasks = {
					{ id = "1a", title = "Saved task", independent = false, sequential_why = "Owner review",
						files = { "src/saved.luau" }, checks = { { check_id = "saved-check", argv = { "make", "check" } } },
						systems = {}, flags = {}, text = "Keep the saved task.", state = "queued_plan" },
				} } } } } } }
	source.dispatch.catalogs["orch-1"] = { revision = 55, config_revision = 55, namespace = "saved-spawn",
		host_key = "host:fixture", next_cursor = { revision = 55, index = 2 },
		records = { { id = "saved-builder", revision = 55, eligible = false,
			capabilities = {}, unsupported = { "Setup has not been reviewed." } } } }
	local before = codec.dispatch_source_bytes(source)
	local source_hash = codec.sha256(before)
	local selected = { logical_session_ids = runtime.json.array({ "orch-1" }), mailbox_handles = runtime.json.array() }
	local managed = { schema = 1, sessions = runtime.json.array({
		{ logical_session_id = "orch-1", binding = clone(origin), controller_pane = "42" },
	}), workers = runtime.json.array() }
	local source_peer = clone(peer)
	source_peer.managed_sha256 = assert(codec.dispatch_managed_digest(runtime.json.encode(managed)))
	check(state.valid_legacy(source), "complete original v2 source validates without installation metadata")
	local visible = assert(state.migration_source(source))
	check(visible.version == 2 and visible.revision == 13 and visible.sessions["orch-1"].name == "Saved walkthrough",
		"v2 exposes saved sessions at the explicit migration boundary instead of quarantine")
	local proof = assert(state.legacy_migration_proof(source, "v2-migration", selected))
	check(proof.source_schema == 2 and proof.source_revision == 13 and proof.source_sha256 == source_hash
		and proof.source_namespace == nil and proof.protocol == 1 and proof.state == "ready",
		"v2 qualification proves the exact original source, not a synthetic v3 store")
	local candidate = assert(state.prepare_migration(source, "v2-migration", source_peer, selected))
	check(candidate.migration.orch.source_schema == 2 and candidate.migration.orch.source_sha256 == source_hash
		and candidate.version == 5 and candidate.revision == 14 and candidate.execution_epoch == 4,
		"v2 prepares directly into current authority while retaining original source proof")
	local projected = state.project(candidate)
	check(projected.setup.state == "in_progress" and projected.setup.review_existing
		and projected.setup.config_revision == 0 and projected.setup.readiness.state == "not_run"
		and projected.installation_defaults.revision == 0 and projected.installation_defaults.builder_record == ""
		and projected.installation_defaults.repository == nil,
		"v2 candidate requests existing-installation review without inventing setup completion, roles, repository or readiness")
	check(candidate.dispatch.catalogs["orch-1"] == nil and source.dispatch.catalogs["orch-1"].revision == 55,
		"v2 preparation discards only obsolete catalog observations from the candidate, requiring fresh native setup evidence")
	local stale_cache_candidate = clone(candidate)
	stale_cache_candidate.dispatch.catalogs = clone(source.dispatch.catalogs)
	check(not state.valid(stale_cache_candidate), "current authority still rejects a pre-setup catalog cache without fresh native evidence")
	local migrated_plan = candidate.dispatch.plans["plan-1"]
	local original_plan_fields = clone(migrated_plan)
	original_plan_fields.orch_project_id, original_plan_fields.held = nil, nil
	check(codec.dispatch_source_bytes(original_plan_fields) == codec.dispatch_source_bytes(source.dispatch.plans["plan-1"])
		and codec.dispatch_source_bytes(candidate.sessions["orch-1"].controller) == codec.dispatch_source_bytes(source.sessions["orch-1"].controller)
		and candidate.sessions["orch-1"].name == source.sessions["orch-1"].name
		and candidate.next_owner_id == source.next_owner_id,
		"v2 preparation preserves imported plan tasks and exact uncertain current owner identity")
	local migrated_project = candidate.dispatch.projects[migrated_plan.orch_project_id]
	check(migrated_plan.held == true and migrated_project ~= nil and migrated_project.started == false
		and migrated_project.logical_session_id == "orch-1" and candidate.dispatch.policies["orch-1"].paused,
		"v2 plan conversion adds a held source in an unstarted project without resuming its saved pause")
	local expected_policy = clone(policy)
	expected_policy.enforce_cross_family, expected_policy.require_code_review, expected_policy.require_other_family = nil, true, false
	check(codec.dispatch_source_bytes(candidate.dispatch.policies["orch-1"]) == codec.dispatch_source_bytes(expected_policy)
		and candidate.dispatch.command_cursors["orch-1"].policy_revision == 12
		and candidate.installation_defaults.policy.paused == false,
		"v2 keeps every session policy choice and revision through the existing review-policy migration, independently of new defaults")
	local held, refusal = state.apply(candidate, intent("register_session", "no-launch", { name = "No launch" }, candidate))
	check(held == nil and refusal.code == "migration_blocked", "v2 prepared authority cannot mutate before paired completion")
	local immutable_peer = clone(source_peer); immutable_peer.pending_immutable, immutable_peer.state = 1, "blocked"
	check(state.prepare_migration(source, "v2-migration", immutable_peer, selected) == nil,
		"v2 compatibility never accepts a peer's unresolved immutable operation")
	local pending_source = clone(source); pending_source.sessions["orch-1"].controller.pending_executors = 1
	check(state.valid_legacy(pending_source) and state.prepare_migration(pending_source, "v2-migration", source_peer, selected) == nil,
		"valid v2 owners with unresolved executors remain blocked")
	for label, mutate in {
		v2_setup = function(v) v.setup = clone(empty.setup) end,
		v2_defaults = function(v) v.installation_defaults = clone(empty.installation_defaults) end,
		v2_both = function(v) v.setup = clone(empty.setup); v.installation_defaults = clone(empty.installation_defaults) end,
		v2_null = function(v) v.setup = runtime.json.null end,
		v3_missing_both = function(v) v.version = 3 end,
		v3_missing_defaults = function(v) v.version = 3; v.setup = clone(empty.setup) end,
		v3_missing_setup = function(v) v.version = 3; v.installation_defaults = clone(empty.installation_defaults) end,
		current_namespace = function(v) v.authority_namespace = "injected" end,
		malformed_owner = function(v) v.sessions["orch-1"].controller.generation = 2 end,
		malformed_plan = function(v) v.dispatch.plans["plan-1"].checkpoints[1].tasks[1].state = "invented" end,
		hybrid_catalog = function(v) v.dispatch.catalogs["orch-1"].catalog_version = 2 end,
	} do
		local invalid = clone(source); mutate(invalid)
		local exact = runtime.json.encode(invalid)
		check(not state.valid_legacy(invalid) and state.migration_source(invalid) == nil
			and state.legacy_migration_proof(invalid, "v2-migration", selected) == nil
			and state.prepare_migration(invalid, "v2-migration", source_peer, selected) == nil
			and runtime.json.encode(invalid) == exact, label .. " remains invalid and unchanged across every migration entrypoint")
	end
	check(codec.dispatch_source_bytes(source) == before and source.version == 2 and source.setup == nil
		and source.installation_defaults == nil, "validation, proof, preparation and refusal never modify original v2 bytes")
	local configured_v3 = clone(legacy)
	configured_v3.setup.state = "dismissed"; configured_v3.installation_defaults.builder_record = "saved-builder"
	local prepared_v3 = assert(state.prepare_migration(configured_v3, "configured-v3", peer, selection))
	check(codec.dispatch_source_bytes(prepared_v3.setup) == codec.dispatch_source_bytes(configured_v3.setup)
		and prepared_v3.installation_defaults.builder_record == "saved-builder"
		and prepared_v3.installation_defaults.policy.preferred_worker_record == "saved-builder"
		and prepared_v3.installation_defaults.policy.loop_cap == configured_v3.installation_defaults.policy.loop_cap,
		"v3 retains installation choices and migrates the real preferred-worker scope instead of reseeding adoption defaults")
	local modern_catalog_source = clone(source)
	modern_catalog_source.version = 3
	modern_catalog_source.setup, modern_catalog_source.installation_defaults = clone(empty.setup), clone(empty.installation_defaults)
	local observed = modern_catalog_source.dispatch.catalogs["orch-1"]
	observed.catalog_version = 2
	observed.setup = { schema = 1, state = "in_progress", config_revision = 55,
		readiness = { state = "not_run", config_revision = 0, summary = "" } }
	local modern_catalog_candidate = assert(state.prepare_migration(modern_catalog_source, "v3-catalog-migration", source_peer, selected))
	check(codec.dispatch_source_bytes(modern_catalog_candidate.dispatch.catalogs) == codec.dispatch_source_bytes(modern_catalog_source.dispatch.catalogs),
		"paired preparation preserves already-current validated catalog observations without upgrading their setup claim")
end
local admitted_snapshot = clone(active_prepared)
admitted_snapshot.sessions["orch-1"].admitted = true
admitted_snapshot.sessions["orch-1"].spawn_namespace = "spawn-fixture"
local admission_reload = assert(state.rehydrate(admitted_snapshot))
check(admission_reload.sessions["orch-1"].admitted == nil and admission_reload.sessions["orch-1"].admission_seq == 1
	and admission_reload.sessions["orch-1"].spawn_namespace == "spawn-fixture"
	and admission_reload.sessions["orch-1"].next_request_serial == admitted_snapshot.sessions["orch-1"].next_request_serial,
	"reload removes admission permission while preserving exact identities and counters for fresh peer reconciliation")
local fresh_pair = state.new_registry("fresh-pair")
local qualify = intent("qualify_current", nil, nil, fresh_pair)
check(state.apply(fresh_pair, qualify) == nil, "generic mutation events cannot impersonate native peer qualification")
check(state.qualify_current(fresh_pair, qualify, peer, selection) == nil, "legacy peer cannot qualify as a stable current runtime")
local qualified = assert(state.qualify_current(fresh_pair, qualify, stable_peer, selection))
check(qualified.compatibility.spawn_namespace == "spawn-fixture" and fresh_pair.compatibility == nil,
	"explicit native qualification produces an isolated current-pair candidate")
check(state.qualify_current(qualified, qualify, stable_peer, selection) == nil, "delayed qualification cannot refresh captured authority revision")
local replacement_peer = clone(stable_peer)
replacement_peer.source_namespace, replacement_peer.candidate_namespace = "replacement-spawn", "replacement-spawn"
check(state.qualify_current(qualified, intent("qualify_current", nil, nil, qualified), replacement_peer, selection) == nil,
	"qualification cannot replace an established authority namespace")
local bounded = state.new_registry("active-session-bound")
for index = 1, state.LIMITS.sessions do
	bounded = assert(state.apply(bounded, intent("register_session", "active-" .. index, { name = "Active " .. index }, bounded)))
end
local overflow, overflow_error = state.apply(bounded, intent("register_session", "overflow", { name = "Too many active" }, bounded))
check(overflow == nil and overflow_error.code == "capacity_reached", "bound applies to active sessions, not lifetime registrations")
do
	local original = state.new_registry("local-v4-empty")
	original.version = 4
	original.installation_defaults.policy.auto_launch_intake = false
	original.installation_defaults.policy.auto_start_projects = nil
	original.installation_defaults.policy.paused = true
	original.installation_defaults.policy.excluded_workers = { "old-live-worker" }
	local copy, info = state.rehydrate(original)
	check(copy ~= nil and copy.version == 5 and info.upgrade_required and copy.authority_namespace == original.authority_namespace,
		"empty v4 locally converts without paired namespace migration")
	check(copy.installation_defaults.policy.paused == false and #copy.installation_defaults.policy.excluded_workers == 0
		and copy.installation_defaults.policy.auto_launch_intake == nil and copy.installation_defaults.policy.auto_start_projects == false,
		"live pauses/exclusions and obsolete intake switches are not future-installation defaults")
	local defaults = clone(copy.installation_defaults)
	defaults.repository = { cwd = "/tmp/repo", target_ref = "main" }
	local refused = clone(copy); refused.installation_defaults = defaults
	check(state.rehydrate(refused) == nil, "v5 rejects repository identity in installation defaults")
	local paused_defaults = clone(copy); paused_defaults.installation_defaults.policy.paused = true
	check(state.rehydrate(paused_defaults) == nil, "v5 defaults cannot persist a live-session pause")
	local excluded_defaults = clone(copy); excluded_defaults.installation_defaults.policy.excluded_workers = { "worker-live" }
	check(state.rehydrate(excluded_defaults) == nil, "v5 defaults cannot persist live worker exclusions")
	local proof = assert(state.migration_proof(copy, { logical_session_ids = runtime.json.array(), mailbox_handles = runtime.json.array() }))
	check(proof.source_schema == 5, "the actual source-proof producer advertises current ORCH v5")
end
do
	local p = dispatch.default_policy()
	for _, key in { "initial_dispatch_model", "worker_rollover_model", "coordinator_rollover_model", "routes", "labeller_record", "family_map", "heartbeat_ms", "role_guidance" } do
		local bad = clone(p); bad[key] = if key == "routes" or key == "family_map" then {} else true
		check(not dispatch.valid_policy(bad), "removed executable policy field is refused: " .. key)
	end
	local explicit = clone(p)
	explicit.paused = true; explicit.poll_ms = 7000; explicit.concurrency_limit = 1; explicit.auto_approve_kinds = {}
	explicit.role_guidance = { builder = "Retired saved guidance.", reviewer = "", release_manager = "", labeller = "", coordinator = "" }
	local moved = dispatch.migrate_policy(explicit)
	check(moved.paused and moved.poll_ms == 7000 and moved.concurrency_limit == 1 and #moved.auto_approve_kinds == 0 and moved.role_guidance == nil,
		"migration preserves explicit pause, limits and approval choices while retiring custom role overrides")
	local base = state.new_registry("c5-policy-restore")
	base = assert(state.apply(base, intent("register_session", "c5-existing", { name = "Existing work" }, base)))
	local old = dispatch.default_policy()
	for _, key in { "report_request_ms", "initial_dispatch_enabled", "worker_rollover_enabled", "coordinator_rollover_enabled", "merge_actor_mode",
		"preferred_worker_record", "preferred_orchestrator_record", "track_checkout_roots", "merge_coordination", "work_on_enabled" } do old[key] = nil end
	old.heartbeat_ms = 10000; old.poll_ms = 2000; old.stale_ms = 30000; old.paused = true; old.concurrency_limit = 1
	old.initial_dispatch_model = true; old.worker_rollover_model = false; old.coordinator_rollover_model = false
	old.family_map = { native = "claude" }; old.routes = { { class = "build", record_id = "native" } }; old.labeller_record = ""
	old.sweep_time = "04:05"; old.auto_approve_kinds = {}; old.stale_claim_min = 30; old.quota_max_age_ms = 900000
	old.rollover_threshold_pct = 80; old.release_manager_record = "saved-release"
	old.glitch_integration = true; old.default_work_source = "glitch_plan"; old.role_guidance = clone(explicit.role_guidance)
	base.dispatch.policies["c5-existing"] = clone(old)
	base.installation_defaults.policy = clone(old); base.installation_defaults.policy.paused = false; base.installation_defaults.builder_record = "native"; base.installation_defaults.defined = true
	local restored = assert(state.rehydrate(base))
	local saved = restored.dispatch.policies["c5-existing"]
	check(saved.paused and saved.poll_ms == 2000 and saved.report_request_ms == 10000 and saved.concurrency_limit == 1 and #saved.auto_approve_kinds == 0,
		"full saved legacy policy converts without overwriting explicit scheduling, limits or paused work")
	check(saved.sweep_time == "04:05:00" and saved.stale_claim_min == 30 and saved.quota_max_age_ms == 900000 and saved.glitch_integration and saved.default_work_source == nil
		and saved.glitch_project_discovery == nil and restored.installation_defaults.policy.default_work_source == nil,
		"legacy clock choices retain their actual values while the retired source settings are dropped")
	check(saved.rollover_threshold_pct == 80 and saved.merge_actor_mode == "selected_record" and saved.release_manager_record == "saved-release",
		"existing sessions preserve explicit percentage and saved manager rather than adopting new defaults")
	check(saved.preferred_worker_record == "native" and saved.family_map == nil and saved.routes == nil and saved.initial_dispatch_model == nil,
		"legacy primary build preference becomes a real preferred worker, not an executable route/model alias")
	check(restored.dispatch.family_migrations["c5-existing"].native == "claude" and restored.installation_defaults.family_migrations.native == "claude"
		and saved.role_guidance == nil and restored.installation_defaults.policy.role_guidance == nil and next(restored.dispatch.actions) == nil,
		"instance and reusable family declarations remain migration obligations while overrides retire and no work is launched")
end
do
	local canonical = dispatch.default_policy()
	check(canonical.concurrency_limit == 4 and canonical.quota_max_age_ms == 0 and canonical.auto_rollover
		and canonical.poll_ms == 300000 and canonical.report_request_ms == 900000 and not canonical.automatic_reports
		and canonical.loop_cap == 5 and canonical.review_rounds == 5 and canonical.stale_claim_min == 120
		and canonical.track_checkout_roots and canonical.merge_coordination and canonical.sweep_enabled and canonical.sweep_time == "03:00:00"
		and table.concat(canonical.auto_approve_kinds, " ") == "dispatch report review landing",
		"canonical defaults implement the explicit requested scheduling, limits, approvals, cleanup and rollover choices")
	for _, choice in { "unsaved", "saved", "ambiguous", "legacy_zero" } do
		local raw = state.new_registry("defaults-" .. choice)
		raw.revision = 3; raw.installation_defaults.revision = if choice == "legacy_zero" then 0 else 3
		raw.setup.config_revision = raw.installation_defaults.revision
		raw.installation_defaults.defined = if choice == "saved" then true elseif choice == "unsaved" then false else nil
		local p = raw.installation_defaults.policy
		p.concurrency_limit = 0; p.quota_max_age_ms = 900000; p.auto_rollover = false; p.rollover_threshold_pct = 80
		p.merge_actor_mode = "selected_record"
		p.role_guidance = { builder = "Retired override.", reviewer = "", release_manager = "", labeller = "", coordinator = "" }
		p.glitch_project_discovery = true; p.default_work_source = "board" -- previous-version store: both retired keys present
		local restored = assert(state.rehydrate(raw))
		local expected = choice == "unsaved" or choice == "legacy_zero"
		for _ = 1, 2 do
			local policy = restored.installation_defaults.policy
			check(policy.concurrency_limit == (if expected then 4 else 0) and policy.quota_max_age_ms == (if expected then 0 else 900000)
				and policy.auto_rollover == expected and policy.rollover_threshold_pct == (if expected then 0 else 80)
				and policy.merge_actor_mode == (if expected then "worker" else "selected_record") and policy.role_guidance == nil,
				choice .. ": restore distinguishes unsaved built-ins from explicit/ambiguous legacy preferences without retaining overrides")
			restored = assert(state.rehydrate(restored))
		end
	end
	local empty = dispatch.default_policy(); empty.merge_actor_mode = nil
	check(dispatch.migrate_policy(empty).merge_actor_mode == "worker", "an empty legacy manager choice does not create a selected-manager hold")
	local selected = dispatch.default_policy(); selected.merge_actor_mode = nil; selected.release_manager_record = "chosen-manager"
	check(dispatch.migrate_policy(selected).merge_actor_mode == "selected_record", "an actual saved manager remains selected")
	selected.merge_actor_mode = "worker"
	check(dispatch.migrate_policy(selected).merge_actor_mode == "worker", "explicit same-worker mode wins over an unrelated retained manager record")
	local raw = state.new_registry("new-policy-session")
	raw = assert(state.apply(raw, intent("register_session", "new-headroom", { name = "New policy session" }, raw)))
	check(dispatch.policy(raw, "new-headroom").rollover_threshold_pct == 0 and dispatch.policy(raw, "new-headroom").merge_actor_mode == "worker",
		"new session consumes calculated rollover and existing-worker merge defaults without a separate release session")
end
return "PASS " .. tostring(checks) .. " current ownership state assertions"
