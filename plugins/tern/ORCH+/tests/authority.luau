-- Run in Tern's Lua runtime; uses the real reducer and host commit boundary.
local root = ...
assert(type(root) == "string", "pass the plugin directory")
local runtime, environment = tern, getfenv()
local function clone(value)
	return if value == nil then nil else runtime.json.decode(runtime.json.encode(value))
end
local function store()
	local memory = { value = nil, fail_read = false, fail_write = false, writes = 0 }
	memory.get = function(key)
		assert(key == "authority_state")
		if memory.fail_read then error("injected read failure") end
		return clone(memory.value)
	end
	memory.set = function(key, value)
		assert(key == "authority_state")
		if memory.fail_write then error("injected durable write failure") end
		memory.value = clone(value)
		memory.writes += 1
		-- Native kv.set returns no value, not true.
	end
	return memory
end
local fake = table.clone(runtime)
fake.json = table.clone(runtime.json)
local ui_store = store()
fake.kv = ui_store
local definition
fake.block = { define = function(id, value) assert(id == "orchestrator"); definition = value end }
fake.on = function() end
-- Host and window modules rearm on load; this fixture owns no native timer.
fake.timer = function() return { cancel = function() end } end
local modules = {}
-- `./x` resolves against the requiring module's directory, as Tern's require does (updater/ modules).
local function load(name, base)
	name = (base or "") .. name:gsub("^%./", "")
	if modules[name] ~= nil then return modules[name] end
	local chunk = assert(loadstring(runtime.fs.read(root .. "/" .. name .. ".luau"), name))
	local dir = name:match("^(.*/)")
	setfenv(chunk, setmetatable({ require = function(n) return load(n, dir) end, tern = fake }, { __index = environment }))
	local value = chunk()
	modules[name] = value
	return value
end
local host = load("host")
local state = load("state")
local checks = 0
local function check(condition, message)
	assert(condition, message)
	checks += 1
end
local memory = store()
local authority = host.new_authority(memory)
check(authority:load().code == "store_missing" and authority.registry == nil and memory.writes == 0, "missing store does not initialize")
check(not authority:initialize(false).ok, "first-use confirmation is required")
memory.fail_write = true
check(authority:initialize(true).code == "persistence_failed" and authority.registry == nil and memory.value == nil, "failed initialization publishes no authority")
memory.fail_write = false
check(authority:initialize(true).ok and authority.registry.version == 2, "explicit initialization commits")
local registration = { kind = "register_session", request_id = "register", name = "Authority fixture" }
local response = authority:apply(registration)
check(response.ok, "registration commits")
local session = response.orch_session_id
local binding = { host_pane_id = "42", alias_nonce = "authority-fixture-alias" }
local admission = { kind = "admit_controller", request_id = "admit", orch_session_id = session, pane_binding = binding }
local prior = runtime.json.encode(authority.registry)
local writes = memory.writes
memory.fail_write = true
response = authority:apply(admission)
check(response.code == "persistence_failed" and response.owner == nil, "failed grant exposes no owner result")
check(runtime.json.encode(authority.registry) == prior and memory.writes == writes, "failed grant preserves exact old authority")
check(memory.value.sessions[session].controller == nil and memory.value.request_outcomes.admit == nil, "failed grant persists neither owner nor outcome")
memory.fail_write = false
response = authority:apply(admission)
check(response.ok and response.owner ~= nil, "retry of uncommitted request grants after successful persistence")
local owner = response.owner
writes = memory.writes
memory.fail_write = true
response = authority:apply(clone(admission))
check(response.ok and response.replayed and response.owner.owner_id == owner.owner_id and memory.writes == writes, "committed replay returns original outcome without another write")
memory.fail_write = false
local restarted = host.new_authority(memory)
check(restarted:load().ok, "restore commits before exposing authority")
check(restarted.registry.sessions[session].controller.phase == "uncertain", "restored owner stays occupied and uncertain")
response = restarted:apply(admission)
check(response.ok and response.replayed and response.owner.owner_id == owner.owner_id, "lost outcome replay survives restart")
check(not restarted:apply({ kind = "admit_controller", request_id = "competitor", orch_session_id = session, pane_binding = { host_pane_id = "43", alias_nonce = "competitor" } }).ok, "duplicate block cannot take occupied slot")
authority = restarted
local function owned(kind, request_id, extra)
	local event = { kind = kind, request_id = request_id, orch_session_id = session, expected_owner_id = owner.owner_id, expected_generation = owner.generation }
	for key, value in extra or {} do event[key] = value end
	return event
end
check(authority:apply(owned("mark_uncertain", "absent", { target = "controller", reason = "window snapshot absent" })).ok, "missing observation records uncertainty")
check(authority.registry.sessions[session].controller.owner_id == owner.owner_id, "absence never clears owner")
local release = owned("release_controller", "release-failure")
prior = runtime.json.encode(authority.registry)
memory.fail_write = true
check(authority:apply(release).code == "persistence_failed", "release persistence failure is visible")
check(runtime.json.encode(authority.registry) == prior and memory.value.sessions[session].controller.owner_id == owner.owner_id, "failed release retains owner and generation")
memory.fail_write = false
check(not authority:apply(owned("observe_owner", "cannot-override-active", { target = "controller", status = "unsupported operator assertion",
	owner_active = false, pending_executors = 0, evidence = "operator_attested", operator_verified = true })).ok,
	"operator attestation cannot erase known active evidence")
check(authority:apply(owned("observe_owner", "observed-unavailable", { target = "controller", status = "unavailable", evidence = "observed" })).ok,
	"actual unavailable observation allows independent verification without clearing ownership")
check(authority:apply(owned("observe_owner", "verified", { target = "controller", status = "operator verified stopped and reconciled", owner_active = false,
	pending_executors = 0, evidence = "operator_attested", operator_verified = true })).ok, "explicit recovery evidence commits")
response = authority:apply(owned("begin_recovery", "begin", { target = "controller", expected_revision = authority.registry.revision }))
check(response.ok, "generation/revision bound recovery begins")
local confirmation = owned("confirm_recovery", "confirm", { target = "controller", expected_revision = response.revision, intent_id = response.intent_id,
	evidence = "operator_attested", operator_verified = true })
prior = runtime.json.encode(authority.registry)
memory.fail_write = true
check(authority:apply(confirmation).code == "persistence_failed", "recovery persistence failure is visible")
check(runtime.json.encode(authority.registry) == prior and memory.value.sessions[session].controller.owner_id == owner.owner_id, "failed recovery preserves owner and intent")
memory.fail_write = false
check(authority:apply(confirmation).ok, "recovery commits only when saved")
check(authority.registry.sessions[session].controller == nil and authority.registry.sessions[session].orchestrator == nil, "recovery never starts an AI")
response = authority:apply({ kind = "admit_controller", request_id = "new-owner", orch_session_id = session, pane_binding = binding })
check(response.ok and response.owner.generation > owner.generation, "separate explicit admission creates successor generation")
local successor = response.owner
response = authority:apply(confirmation)
check(response.ok and response.replayed and authority.registry.sessions[session].controller.owner_id == successor.owner_id, "replayed old recovery never clears successor")
local stale = clone(confirmation)
stale.request_id = "stale-confirm"
check(not authority:apply(stale).ok and authority.registry.sessions[session].controller.owner_id == successor.owner_id, "stale confirmation refused")
local committed = clone(memory.value)
memory.value.sessions = {}
check(authority:apply({ kind = "register_session", request_id = "corrupt-write", name = "No" }).code == "store_changed", "same-revision corrupt store is not overwritten")
check(authority.registry.sessions[session].controller.owner_id == successor.owner_id, "corruption preserves in-memory owner")
memory.value = nil
check(authority:load().code == "store_missing" and authority.status == "missing_established", "established missing store locks initialization")
check(not authority:initialize(true).ok and memory.value == nil, "operator cannot silently initialize lost established authority")
memory.value = committed
memory.fail_write = true
local failed_restore = host.new_authority(memory)
check(failed_restore:load().code == "persistence_failed" and failed_restore.registry == nil, "failed restored epoch save exposes no restored grant")
memory.fail_write = false
memory.value = { version = 1, workers = {} }
local legacy = host.new_authority(memory)
check(legacy:load().code == "migration_required" and legacy.registry == nil and memory.value.version == 1, "legacy store quarantined unchanged")
check(not legacy:initialize(true).ok, "legacy data cannot be reset by first-use initialization")
memory.fail_read = true
local unreadable = host.new_authority(memory)
check(unreadable:load().code == "store_unreadable" and unreadable.registry == nil, "unreadable store never grants")

-- Committing writes match an unchanged store against the saved JSON text natively instead of
-- walking the persisted registry in Lua; other text still gets the exact deep compare.
local walks = 0
local walked = { __iter = function(value) walks += 1; return next, value end }
local text_store = store()
local read_text_store = text_store.get
text_store.get = function(key)
	local value = read_text_store(key)
	if type(value) == "table" then setmetatable(value, walked) end
	return value
end
fake.json.encode = function(value, pretty)
	if type(value) == "table" and getmetatable(value) == walked then
		setmetatable(value, nil)
		local ok, text = pcall(runtime.json.encode, value, pretty)
		setmetatable(value, walked)
		if not ok then error(text, 0) end
		return text
	end
	return runtime.json.encode(value, pretty)
end
local text_authority = host.new_authority(text_store)
text_authority:load()
assert(text_authority:initialize(true).ok)
walks = 0
local text_session = text_authority:apply({ kind = "register_session", request_id = "text-session", name = "Text check" })
local text_owner = text_authority:apply({ kind = "admit_controller", request_id = "text-owner", orch_session_id = text_session.orch_session_id, pane_binding = binding })
check(text_session.ok and text_owner.ok and text_store.writes == 3 and walks == 0,
	"unchanged-store commits are verified natively, without a Lua walk of the persisted registry")
text_authority.registry = clone(text_authority.registry)
check(text_authority:apply({ kind = "register_session", request_id = "text-fallback", name = "Fallback" }).ok and walks > 0 and text_store.writes == 4,
	"a registry without saved text falls back to the exact deep compare")
text_store.value.next_session_id += 1
check(text_authority:apply({ kind = "register_session", request_id = "text-external", name = "No" }).code == "store_changed" and text_store.writes == 4,
	"an external store change is still refused after a text mismatch")
fake.json.encode = runtime.json.encode

-- Inject serialized size at the host boundary without manufacturing thousands of owners.
local capacity_store = store()
local capacity_authority = host.new_authority(capacity_store)
capacity_authority:load()
assert(capacity_authority:initialize(true).ok)
local encoded_size = 8 * 1024 * 1024 - 512 * 1024 + 1
fake.json.encode = function(value, pretty)
	if type(value) == "table" and value.version == 2 then return string.rep("x", encoded_size) end
	return runtime.json.encode(value, pretty)
end
local capacity_revision = capacity_authority.registry.revision
check(capacity_authority:apply({ kind = "register_session", request_id = "full", name = "Refused" }).code == "capacity_reached",
	"ordinary admission cannot consume settlement reserve")
check(capacity_authority.registry.revision == capacity_revision and capacity_store.writes == 1,
	"capacity refusal neither publishes nor persists candidate")
fake.json.encode = runtime.json.encode
local capacity_session = capacity_authority:apply({ kind = "register_session", request_id = "capacity-session", name = "Capacity" }).orch_session_id
local capacity_owner = capacity_authority:apply({ kind = "admit_controller", request_id = "capacity-owner", orch_session_id = capacity_session, pane_binding = binding }).owner
assert(capacity_authority:apply({ kind = "observe_owner", request_id = "capacity-evidence", orch_session_id = capacity_session, target = "controller",
	expected_owner_id = capacity_owner.owner_id, expected_generation = capacity_owner.generation,
	status = "observed stopped before capacity threshold", owner_active = false, pending_executors = 0, evidence = "observed" }).ok)
local capacity_reservation = capacity_authority:apply({ kind = "reserve_coordinator", request_id = "capacity-reservation", orch_session_id = capacity_session }).owner
fake.json.encode = function(value, pretty)
	if type(value) == "table" and value.version == 2 then return string.rep("x", encoded_size) end
	return runtime.json.encode(value, pretty)
end
local bound = capacity_authority:apply({ kind = "bind_coordinator", request_id = "capacity-bind", orch_session_id = capacity_session,
	expected_owner_id = capacity_reservation.owner_id, expected_generation = capacity_reservation.generation, pane_binding = binding })
check(bound.ok and capacity_authority.registry.sessions[capacity_session].orchestrator.phase == "active",
	"existing reserved coordinator can finish binding inside byte settlement reserve")
local no_progress = capacity_authority:apply({ kind = "observe_owner", request_id = "no-progress-byte-reserve",
	orch_session_id = capacity_session, target = "controller", expected_owner_id = capacity_owner.owner_id,
	expected_generation = capacity_owner.generation, status = "same stopped fact", owner_active = false,
	pending_executors = 0, evidence = "observed" })
check(no_progress.code == "no_progress" and not capacity_authority.uncommitted_observation,
	"repeated byte-reserve observation consumes no outcome and is not a lost fresh safety fact")
local settlement = { kind = "begin_recovery", request_id = "settlement", orch_session_id = capacity_session, target = "controller",
	expected_owner_id = capacity_owner.owner_id, expected_generation = capacity_owner.generation, expected_revision = capacity_authority.registry.revision }
local capacity_intent = capacity_authority:apply(settlement)
check(capacity_intent.ok, "fenced recovery may use reserved bytes after evidence was already committed")
local repeated_preparation = clone(settlement)
repeated_preparation.request_id = "repeated-byte-reserve-preparation"
repeated_preparation.expected_revision = capacity_authority.registry.revision
local before_repeated = capacity_store.writes
check(not capacity_authority:apply(repeated_preparation).ok and capacity_store.writes == before_repeated,
	"byte reserve applies reducer recovery serialization even below outcome threshold")
encoded_size = 8 * 1024 * 1024 + 1
local capacity_confirmation = { kind = "confirm_recovery", request_id = "settlement-overflow", orch_session_id = capacity_session, target = "controller",
	expected_owner_id = capacity_owner.owner_id, expected_generation = capacity_owner.generation, expected_revision = capacity_intent.revision,
	intent_id = capacity_intent.intent_id, operator_verified = true, evidence = "operator_attested" }
capacity_revision = capacity_authority.registry.revision
check(capacity_authority:apply(capacity_confirmation).code == "capacity_reached" and capacity_authority.registry.revision == capacity_revision,
	"even settlement cannot exceed absolute encoded authority bound")
local fresh_observation = { kind = "observe_owner", request_id = "safety-overflow", orch_session_id = capacity_session, target = "controller",
	expected_owner_id = capacity_owner.owner_id, expected_generation = capacity_owner.generation,
	status = "fresh native active observation cannot persist", owner_active = true, evidence = "observed" }
check(capacity_authority:apply(fresh_observation).code == "capacity_reached" and capacity_authority.uncommitted_observation,
	"capacity-rejected fresh observation fences settlement instead of retaining permission from stale inactive facts")
fake.json.encode = runtime.json.encode
check(capacity_authority:apply(capacity_confirmation).code == "uncommitted_observation"
	and capacity_authority.registry.sessions[capacity_session].controller.owner_id == capacity_owner.owner_id,
	"recovery stays blocked even when encoding capacity becomes available after a lost observation")
local settlement_replay = capacity_authority:apply(settlement)
check(settlement_replay.ok and settlement_replay.replayed, "observation safety fence still allows exact committed outcome replay")
check(capacity_authority:load().ok and capacity_authority.uncommitted_observation, "store recheck cannot silently clear runtime safety fence")
settlement.request_id = "after-recheck"
settlement.expected_revision = capacity_authority.registry.revision
check(capacity_authority:apply(settlement).code == "uncommitted_observation", "recovery remains fenced after store recheck")
local fresh_runtime = host.new_authority(capacity_store)
assert(fresh_runtime:load().ok)
capacity_store.fail_write = true
fresh_observation.request_id = "safety-save-failure"
check(fresh_runtime:apply(fresh_observation).code == "persistence_failed" and fresh_runtime.uncommitted_observation,
	"failed safety-observation write also blocks stale-fact settlement")
capacity_store.fail_write = false

-- Exercise the actual block callbacks: duplicate views share the single host registry,
-- while each saved block value contains only its display binding.
local renders = { [11] = 0, [12] = 0 }
local function context(pane)
	return { pane = pane, render = function() renders[pane] += 1 end }
end
local cx1, cx2 = context(11), context(12)
local view1 = definition.init(cx1, {}, nil)
local view2 = definition.init(cx2, {}, nil)
local function click(view, cx, kind)
	definition.view(view, cx)
	local token
	for id, entry in view.actions do if entry.kind == kind then token = id; break end end
	assert(token ~= nil, "missing actual UI action: " .. kind)
	definition.event(view, { ev = "action", act = "control", value = token }, cx)
end
click(view1, cx1, "initialize-arm")
click(view1, cx1, "initialize-confirm")
click(view1, cx1, "register-arm")
click(view1, cx1, "register-confirm")
click(view2, cx2, "select")
check(view1.orch_session_id == view2.orch_session_id, "duplicate views explicitly select same logical registration")
click(view1, cx1, "admit")
local ui_owner = ui_store.value.sessions[view1.orch_session_id].controller
check(ui_owner.pane_binding.host_pane_id == "11" and ui_owner.pane_binding.alias_nonce == view1.alias_nonce, "native host pane and nonce binding used")
local tick_revision, tick_writes = ui_store.value.revision, ui_store.writes
definition.event(view1, { ev = "action", act = "dispatch-command", value = runtime.json.encode({
	kind = "workflow_tick", request_id = "forged-host-clock", orch_session_id = view1.orch_session_id,
	now_ms = 9999999999999, mono_ms = 9999999999999, epoch = "forged-window",
}) }, cx1)
check(ui_store.value.revision == tick_revision and ui_store.writes == tick_writes, "external block event cannot invoke host-only tick or supply clock authority")
definition.view(view2, cx2)
local admit_available = false
for _, entry in view2.actions do if entry.kind == "admit" then admit_available = true end end
check(not admit_available and renders[11] > 0 and renders[12] > 0, "occupied registry is consistent across duplicate blocks")
local saved = definition.save(view1)
check(saved.orch_session_id == view1.orch_session_id and saved.registry == nil and saved.sessions == nil and saved.established == true, "block save cannot overwrite authority")
check(state.project(ui_store.value).sessions[1].controller.owner_id == ui_owner.owner_id, "consumer projection exposes only committed owner")
local config_before, config_writes = runtime.json.encode(ui_store.value), ui_store.writes
view1.dispatch_receipt = { action_id = "captured-action", grant_id = "captured-grant", response_sha256 = string.rep("a", 64) }
view1.scoped_results = { ["captured-action"] = { receipt = clone(view1.dispatch_receipt) } }
click(view1, cx1, "config-open")
check(view1.config_open == true, "visible Config button opens the existing session policy flow")
definition.view(view1, cx1)
local stale_config
for token, entry in view1.actions do if entry.kind == "config-close" then stale_config = token end end
check(stale_config ~= nil and view1.dispatch_receipt.grant_id == "captured-grant"
	and view1.scoped_results["captured-action"].receipt.action_id == "captured-action",
	"Config does not discard captured result receipts")
click(view1, cx1, "config-close")
check(not view1.config_open and ui_store.writes == config_writes and runtime.json.encode(ui_store.value) == config_before,
	"opening and closing Config changes no durable authority or policy")
definition.event(view1, { ev = "action", act = "control", value = stale_config }, cx1)
check(not view1.config_open and ui_store.writes == config_writes and view1.refusal ~= nil,
	"stale Config control cannot mutate the view or authority")
renders[13] = 0
local cx3 = context(13)
local files_view = definition.init(cx3, { "config" }, nil)
definition.view(files_view, cx3)
local controller_link = false
for _, entry in files_view.actions do if entry.kind == "config-close" then controller_link = true end end
check(files_view.config_open == true and controller_link, "Files-button views open in Config with an Open ORCH+ controller button")
click(view2, cx2, "config-open")
local config_store = runtime.json.encode(ui_store.value)
definition.event(view2, { ev = "change", name = "auto_rollover", checked = true }, cx2)
check(view2.policy_draft == nil and tostring(view2.notice):find("read%-only") ~= nil and runtime.json.encode(ui_store.value) == config_store,
	"duplicate non-controller Config is read-only with its reason")
click(view1, cx1, "config-open")
definition.event(view1, { ev = "change", name = "auto_rollover", checked = true }, cx1)
check(view1.policy_draft ~= nil and view1.policy_draft.values.auto_rollover == true and runtime.json.encode(ui_store.value) == config_store,
	"controller checkbox edits only a view-local draft; saving requires the window policy command")
local function step(delta)
	definition.view(view1, cx1)
	local token
	for id, entry in view1.actions do if entry.kind == "config-step" and entry.field == "rollover_threshold_pct" and entry.delta == delta then token = id end end
	definition.event(view1, { ev = "action", act = "control", value = assert(token, "missing threshold step control") }, cx1)
end
for _ = 1, 3 do step(10) end
check(view1.policy_draft.values.rollover_threshold_pct == 99, "threshold step buttons clamp at 99")
click(view1, cx1, "config-discard")
check(view1.policy_draft == nil and runtime.json.encode(ui_store.value) == config_store, "discarding the draft changes no saved policy")
click(view1, cx1, "config-close"); click(view2, cx2, "config-close")
view1.dispatch_receipt = nil; view1.scoped_results = nil
local callback_origin = { logical_session_id = view1.orch_session_id, owner_id = ui_owner.owner_id, owner_generation = ui_owner.generation,
	host_pane_id = "11", alias_nonce = view1.alias_nonce, window_key = "callback-window", window_epoch = "callback-old",
	native_session_id = "7", window_host_id = "local" }
local callback_controller_alias = "11"
local function callback_command(command, fields)
	local input = { kind = "dispatch", request_id = "ui-callback-" .. command, orch_session_id = view1.orch_session_id,
		origin = clone(callback_origin), controller_pane = callback_controller_alias, command = command }
	for key, value in fields do input[key] = value end
	definition.event(view1, { ev = "action", act = "dispatch-command", value = runtime.json.encode(input) }, cx1)
end
callback_command("catalog", { command_seq = 1 })
local callback_action = assert(view1.dispatch_action)
callback_command("claim", { action_id = callback_action, executor = callback_origin.window_epoch })
local retained_action = clone(ui_store.value.dispatch.actions[callback_action])
assert(retained_action.claim)
local callback_pending = ui_store.value.sessions[view1.orch_session_id].controller.pending_executors
callback_origin.window_epoch = "callback-new"
callback_controller_alias = "9011" -- Same host pane/owner, different window-local numeric alias after reload.
callback_command("continue_controller", { command_seq = 2, expected_revision = ui_store.value.revision, operator_verified = true })
check(ui_store.value.sessions[view1.orch_session_id].controller.pending_executors == callback_pending,
	"explicit controller continuation retains every original pending executor")
local continued_phase = ui_store.value.dispatch.actions[callback_action].phase
check(continued_phase == "uncertain", "continuation marks the stopped old executor's claim uncertain, never resolved")
local transport = load("transport")
local body = { schema = 1, op = "catalog", request_id = retained_action.request.request_id, action_id = callback_action,
	origin_binding = retained_action.request.origin_binding, controller_generation = retained_action.request.controller_generation,
	status = "catalog", payload = { namespace = "fixture-spawn", host_key = "fixture-host", config_revision = 0, revision = 0, records = runtime.json.array() } }
local body_bytes = runtime.json.encode(body)
local callback_frame = "SPAWN_DISPATCH v1 " .. runtime.json.encode({ schema = 1, op = body.op, request_id = body.request_id,
	complete = true, body_bytes = #body_bytes, body_sha256 = transport.sha256(body_bytes), body_json = body_bytes })
local callback_writes = ui_store.writes
definition.event(view1, { ev = "action", act = "dispatch-result/" .. retained_action.claim.grant_id .. "/callback-old", value = callback_frame }, cx1)
check(ui_store.writes == callback_writes and ui_store.value.dispatch.actions[callback_action].phase == continued_phase,
	"real host rejects the old-incarnation result callback after explicit continuation")
definition.event(view1, { ev = "action", act = "dispatch-result/" .. retained_action.claim.grant_id .. "/callback-new", value = callback_frame }, cx1)
check(ui_store.value.dispatch.actions[callback_action].phase == "complete" and view1.dispatch_receipt.grant_id == retained_action.claim.grant_id,
	"current-origin readback commits the immutable original outcome and exact original grant receipt")
local routed_result = ui_store.value.dispatch.commands[view1.dispatch_result.request_id]
check(routed_result.event.controller_pane == "9011" and retained_action.request.controller_pane == "11",
	"real host settlement uses the continued controller alias while preserving the original request alias")
click(view1, cx1, "config-open"); click(view1, cx1, "config-close")
check(view1.dispatch_receipt.grant_id == retained_action.claim.grant_id and view1.scoped_results[callback_action].receipt ~= nil,
	"independent visible Config controls preserve the real captured settlement receipt")

local pending_candidate = state.apply(ui_store.value, {
	kind = "observe_owner", request_id = "ui-pending", orch_session_id = view1.orch_session_id, target = "controller",
	expected_owner_id = ui_owner.owner_id, expected_generation = ui_owner.generation,
	status = "currently observed executors", owner_active = true, pending_executors = 2, evidence = "observed",
}, 2000)
assert(pending_candidate ~= nil)
load("views").render(view1, state.project(pending_candidate), "ready", nil)
local override_available = false
for _, entry in view1.actions do
	if entry.kind == "attest" or entry.kind == "attest-executors" then override_available = true end
end
check(not override_available, "UI cannot override currently observed active owner or executors")
ui_store.set("authority_state", pending_candidate)
modules.host = nil
load("host")
local restored_view = definition.init(cx2, {}, { orch_session_id = view1.orch_session_id, established = true })
local retained = ui_store.value.sessions[view1.orch_session_id].controller
check(retained.pending_executors == 2 and retained.pending_executor_evidence == "unconfirmed",
	"reload retains executor count as unconfirmed, without manufacturing native reconciliation")
definition.event(restored_view, { ev = "action", act = "assistance-result", value = runtime.json.encode({
	source_nonce = restored_view.alias_nonce, target = "controller", owner_id = retained.owner_id, generation = retained.generation,
	revision = ui_store.value.revision, message = "Actual alias unavailable in this native snapshot", observation = "unavailable",
}) }, cx2)
check(ui_store.value.sessions[view1.orch_session_id].controller.pending_executors == 2,
	"unavailable observation alone never clears retained executors")
click(restored_view, cx2, "attest-executors")
check(ui_store.value.sessions[view1.orch_session_id].controller.pending_executors == 2,
	"arming separate executor verification has no durable clearing effect")
click(restored_view, cx2, "attest-executors-confirm")
local reconciled = ui_store.value.sessions[view1.orch_session_id].controller
check(reconciled.owner_id == retained.owner_id and reconciled.pending_executors == 0 and reconciled.owner_active == false
	and reconciled.pending_executor_evidence == "operator_attested",
	"separate confirmation supplies explicit executor verification, preserving ownership until fenced recovery")

-- Current-window tab membership routes views only; it never allocates logical owners.
local open_command, files_button
fake.command = function(command) if command.id == "open" then open_command = command.run end end
fake.files = { button = function(button) files_button = button.run end }
fake.route = { link = function() error("ORCH+ must not claim links; controls are native buttons") end }
local window_api = load("window")
local native_session = { id = 2, host = 1, name = "B", current = true }
local host_row = { id = 1, state = "connected", panes = { 101, 202, 303 }, current = true }
local other = { pane = 101, tab = 10, block = "orchplus.orchestrator", title = "Session A" }
local here = { pane = 202, tab = 20, block = "orchplus.orchestrator", title = "Session B" }
local unknown = { pane = 303, parked = true, block = "orchplus.orchestrator", title = "Unknown" }
local native_panes = { other }
local focused, picker, selection_callback, config_requested
local opened = 0
local routing_cx = {
	sessions = { current = function() return native_session end },
	hosts = { current = function() return host_row end, list = function() return { host_row } end },
	session = {
		sessions = function() return { { id = 1, tabs = { 10 } }, { id = 2, tabs = { 20 } } } end,
		panes = function() return native_panes end,
		pane = function(_, id) for _, pane in native_panes do if pane.pane == id then return pane end end; return nil end,
		surface = function() return nil end,
		event = function(_, pane, event) if event.act == "config-open-request" then config_requested = pane end end,
	},
	layout = { focus = function(_, pane) focused = pane end, unpark = function() return true end },
	new_block = function(_, kind, args, how)
		assert(kind == "orchplus.orchestrator" and #args == 0 and how == "beside")
		opened += 1
		return 400 + opened
	end,
	pick = function(_, options)
		picker = options
		return { next = function(_, callback) selection_callback = callback end }
	end,
	toast = function() end,
}
local authority_writes = ui_store.writes
open_command(routing_cx)
check(opened == 1 and focused == nil and picker == nil, "session B open never silently focuses sole session A view")
native_panes = { other, here }
files_button({}, routing_cx)
check(opened == 1 and focused == 202 and config_requested == 202, "Files entry reveals only known current-session view in Config mode")
native_panes = { other, unknown }
focused = nil
open_command(routing_cx)
check(picker ~= nil and #picker.items == 2 and picker.items[1].new_view == true and picker.items[2].pane == 303,
	"ambiguous parked membership offers explicit chooser and inert current-session view, excluding known other session")
selection_callback(picker.items[1], nil, routing_cx)
check(opened == 2 and focused == nil, "explicit inert view opens without switching sessions")
open_command(routing_cx)
unknown.tab = 10
unknown.parked = false
selection_callback(picker.items[2], nil, routing_cx)
check(focused == nil, "chooser refuses target now known to belong to another session")
check(ui_store.writes == authority_writes, "window routing never writes authority or invents registration")

-- Oversized UTF-8 native titles must not make successful observation disappear at the host boundary.
host_row.panes = { 11, 12 }
native_panes = {
	{ pane = 11, tab = 20, block = "orchplus.orchestrator", title = string.rep("界", 1024) },
	{ pane = 12, tab = 20, block = "orchplus.orchestrator", title = "Recovery view" },
}
local owner_view = { pane = 11, alias_nonce = reconciled.pane_binding.alias_nonce, orch_session_id = restored_view.orch_session_id,
	actions = {}, action_serial = 0 }
-- The real host block renders the inert view; its window-side assistance buttons publish a
-- one-shot operator intent (main.operator-intent) this window consumes and settles.
local function keyed(node, key)
	if type(node) ~= "table" then return nil end
	if type(node.p) == "table" and node.p.key == key then return node end
	for _, child in node.c or {} do local found = keyed(child, key); if found then return found end end
	return nil
end
routing_cx.session.surface = function(_, pane, options)
	if pane ~= 12 then return { main = load("views").render(owner_view, state.project(ui_store.value), "ready", nil) } end
	local main = definition.view(restored_view, cx2).main
	if options.root == "main.ownership-alias" then return { main = main } end
	local node = keyed(main, options.root:sub(6))
	if not node then return nil end
	node = clone(node); node.id = options.root
	return { surface = { role = "plugin.orchplus.orchestrator" }, main = node }
end
local delivered, settled = nil, 0
routing_cx.session.event = function(_, pane, event)
	assert(pane == 12)
	if event.act == "operator-intent-done" then settled += 1
	elseif event.act == "assistance-result" then delivered = runtime.json.decode(event.value) end
	definition.event(restored_view, event, cx2)
end
local function press_assist(kind)
	definition.view(restored_view, cx2)
	for token, entry in restored_view.actions do
		if entry.kind == "assist-intent" and entry.request.kind == kind and entry.request.target == "controller" then
			definition.event(restored_view, { ev = "action", act = "control", value = token }, cx2)
			return entry.request
		end
	end
	error("missing rendered assistance button: " .. kind)
end
for _, kind in { "inspect", "recheck", "reveal" } do
	local current_owner = ui_store.value.sessions[restored_view.orch_session_id].controller
	local request = press_assist(kind)
	check(request.owner_id == current_owner.owner_id and request.generation == current_owner.generation and request.revision == ui_store.value.revision
		and request.owner_alias == current_owner.pane_binding.alias_nonce and restored_view.operator_intent ~= nil
		and restored_view.operator_intent.kind == "assist", kind .. " button publishes the exact assistance request as an operator intent")
	delivered = nil
	local before = settled
	window_api.intents(routing_cx)
	window_api.intents(routing_cx) -- A repeated observation tick never runs the same intent twice.
	check(delivered ~= nil and settled == before + 1 and restored_view.operator_intent == nil, kind .. " intent runs once and is settled")
	check(#delivered.message <= 2048 and delivered.observation == "active"
		and string.find(delivered.message, "Window pane 11", 1, true) ~= nil,
		kind .. " retains native pane identity and bounded observation despite oversized UTF-8 title")
	local observed = ui_store.value.sessions[restored_view.orch_session_id].controller
	check(observed.owner_active == true and observed.last_observation.evidence == "observed" and ui_store.value.revision >= request.revision
		and (kind ~= "inspect" or ui_store.value.revision > request.revision),
		kind .. " reaches the real host: first active fact commits and repeated facts remain authoritative")
end
return "PASS " .. tostring(checks) .. " authority assertions"
