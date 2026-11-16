-- Deterministic real reducer/host/window coverage. Run bounded sections in native host callbacks.
local root, section = ...
assert(section == nil or table.find({ "clock", "native", "controls", "status_launcher", "timer", "epoch_window", "epoch_host", "finish", "continuation", "alias_recovery", "held_report", "sweep_schedule", "readable_views", "cp2_controls", "guided_recovery", "guided_recovery_empty", "guided_recovery_host_restart", "stopped_worker_view", "expired_wake", "revoked_authorization", "observe_retention", "uncertain_read", "quota_reader", "bridge_lifecycle", "withdraw_fenced", "config_cards", "work_picker", "inbox_window", "usage_row",
	"reconnect_stale", "reconnect_missing", "reconnect_unknown", "reconnect_unrelated", "worker_attachment", "worker_attachment_form",
	"driver_admission_noop", "driver_admission_refused", "driver_retry_original", "driver_retry_unrelated", "driver_retry_absent",
	"driver_deadline_absent", "driver_deadline_unrelated", "driver_missing", "driver_suspension", "driver_fence_origin", "driver_fence_claim",
	"driver_pause_poll", "driver_pause_catalog", "driver_reply_pause", "driver_wake_busy_before", "driver_wake_busy_after",
	"template_start", "role_pickers", "landing_row", "plans_view", "idle_wake", "gate_refusal", "finish_refusal", "close_refusal", "control_scheduling", "control_observation", "receipt_polling", "startup_polling", "work_input_priority", "startup_recovery", "status_envelope", "connection_inspection", "bridge_retirement", "bridge_retirement_held", "bridge_rebind", "bridge_paging", "bridge_paging_roster", "bridge_paging_late_sweep", "bridge_paging_late_response", "bridge_paging_drain", "bridge_paging_lower", "bridge_paging_generation", "bridge_paging_prompt", "bridge_authorization", "bridge_refusal" }, section), "unknown health section")
local runtime, environment = tern, getfenv()
-- The fixture runs in this group's environment (as tests/run.luau loads groups), so its tern.json calls are
-- the stepped runner's yield points and a long section spans many native slices.
local fixture_chunk = assert(loadstring(runtime.fs.read(root .. "/tests/dispatch.luau"), "health-fixture"))
setfenv(fixture_chunk, setmetatable({}, { __index = environment }))
local shared = fixture_chunk(root, "fixture")
local clone, state, dispatch = shared.clone, shared.state, shared.dispatch
local protocol = shared.load("dispatch_protocol")
local checks = 0
local function check(ok, message) assert(ok, message); checks += 1 end
local function flow(f) return dispatch.project(f.authority.registry, f.origin.logical_session_id, f.origin.alias_nonce).workflow end
local function health(f, id)
	for _, worker in flow(f).workers do if worker.worker_id == id then return worker.health end end
	error("worker missing from bounded projection")
end
local function observed(f, id, native, problem)
	return f:apply("observe", { worker_id = id, pane_binding = clone(f.authority.registry.dispatch.workers[id].pane_binding), native_state = native, delivery_error = problem })
end
local function peer_body(request, status, payload, problem)
	return assert(shared.codec.decode_dispatch_response(shared.frame(request, status, payload, problem), request))
end
if section == nil or section == "clock" then
	local now, epoch = 1000.125, "health-epoch-one"
	local clock = function() return { now_ms = 1700000000000, mono_ms = now, epoch = epoch } end
	local f = shared.fixture(clock)
	local id = f:accepted(false)
	assert(f:apply("intake", { worker_id = id, bytes = f:report(id, 2, "HEARTBEAT", { state = "idle" }) }).ok)
	check(observed(f, id, "idle").ok, "exact pane observation commits with fractional host monotonic time")
	check(health(f, id).native_state == "idle" and health(f, id).freshness == "fresh", "fresh epoch evidence is derived, not window supplied")
	local writes = f.memory.writes
	assert(f:tick().ok)
	local settled = f.memory.writes
	assert(f:tick().ok)
	check(f.memory.writes == settled and settled >= writes, "idle host ticks do not burn durable writes or request IDs")
	-- An idle tick decides nothing is due without replacing the current dispatch tree.
	local tick_now = 1000
	local t = shared.fixture(function() return { now_ms = 1700000000000, mono_ms = tick_now, epoch = "health-epoch-tick" } end)
	assert(t:apply("policy", { policy = { report_request_ms = 60000, stale_ms = 180000 } }).ok)
	local tid = t:accepted(false)
	assert(t:apply("intake", { worker_id = tid, bytes = t:report(tid, 2, "HEARTBEAT", { state = "idle" }) }).ok)
	assert(observed(t, tid, "idle").ok)
	assert(t:tick().ok)
	assert(t:tick().ok)
	local tick_writes = t.memory.writes
	local current_tree = t.authority.registry.dispatch
	local idle = t:tick()
	check(idle.ok and idle.code == "no_progress" and t.authority.registry.dispatch == current_tree and t.memory.writes == tick_writes,
		"idle host tick preserves the exact current tree without a durable write")
	tick_now += 600000
	local due = t:tick()
	check(due.ok and due.code == "workflow_updated" and t.memory.writes == tick_writes + 1 and health(t, tid).freshness == "stale",
		"elapsed staleness is still committed by the next tick")
	check(t:tick().code == "no_progress" and t.memory.writes == tick_writes + 1, "the committed tick leaves nothing due")
	assert(f:apply("intake", { worker_id = id, bytes = f:report(id, 3, "READY", { state = "idle" }) }).ok)
	assert(observed(f, id, "waiting-input").ok)
	check(health(f, id).native_state == "waiting-input" and health(f, id).reported_state == "idle", "READY preserves conflicting native permission evidence")
	for _, gate in flow(f).gates do
		if gate.kind == "native_input" then assert(f:apply("cancel_gate", { gate_id = gate.id, gate_revision = gate.revision }).ok) end
	end
	assert(f:apply("intake", { worker_id = id, bytes = f:report(id, 4, "BLOCKED", { reason = "Waiting for artifact" }) }).ok)
	check(health(f, id).status == "blocked", "explicit blocked outranks native waiting input")
	assert(f:apply("intake", { worker_id = id, bytes = f:report(id, 5, "ASK", { question = "Which artifact?", options = runtime.json.array({ { id = "one", label = "Artifact one" } }) }) }).ok)
	check(health(f, id).status == "owner_gate", "unresolved owner question outranks blocked evidence")
	assert(observed(f, id, "exited").ok)
	check(health(f, id).status == "exited" and health(f, id).reported_state ~= nil, "native exit wins without erasing report or gate evidence")
	assert(observed(f, id, "unknown").ok)
	assert(f:apply("intake", { worker_id = id, bytes = f:report(id, 6, "READY", { state = "idle" }) }).ok)
	check(health(f, id).status == "exited" and health(f, id).latest_exit ~= nil and health(f, id).latest_native.state == "unknown"
		and health(f, id).reported_state == "idle", "later unknown observation and READY preserve exact terminal fact and conflicting evidence")
	local exit_restore = assert(state.rehydrate(clone(f.authority.registry)))
	local restored_health = dispatch.project(exit_restore, f.origin.logical_session_id, f.origin.alias_nonce).workflow.workers[1].health
	check(restored_health.status == "exited" and restored_health.latest_exit ~= nil and restored_health.freshness == "unconfirmed",
		"restore retains durable exit proof but never restores old-runtime report freshness")
	local unconfirmed = shared.fixture()
	local unconfirmed_id = unconfirmed:accepted(false)
	assert(observed(unconfirmed, unconfirmed_id, "exited").ok)
	check(health(unconfirmed, unconfirmed_id).latest_exit == nil and health(unconfirmed, unconfirmed_id).status ~= "exited",
		"pure clocks without host incarnation cannot establish new native exit authority")
	local before = runtime.json.encode(f.authority.registry)
	local wrong = clone(f.authority.registry.dispatch.workers[id].pane_binding); wrong.pane_id = "9999"
	check(not f:apply("observe", { worker_id = id, pane_binding = wrong, native_state = "idle" }).ok and runtime.json.encode(f.authority.registry) == before,
		"moved/wrong pane cannot establish freshness")
	local g = shared.fixture(clock)
	assert(g:apply("policy", { policy = { report_request_ms = 60000, stale_ms = 180000, automatic_reports = true } }).ok)
	local other = g:accepted(false)
	assert(g:apply("intake", { worker_id = other, bytes = g:report(other, 2, "HEARTBEAT", { state = "working" }) }).ok)
	assert(observed(g, other, "working").ok)
	now += 180001
	assert(g:tick().ok)
	check(health(g, other).freshness == "stale" and health(g, other).status == "stale_report", "required report expiry outranks working")
	epoch = "health-epoch-two"; now = 0.5
	assert(g:tick().ok)
	check(health(g, other).freshness == "unconfirmed" and health(g, other).awaiting_window, "old epoch is never fresh even when monotonic time resets")
	local restored = shared.host.new_authority(g.memory, clock)
	assert(restored:load().ok)
	g.authority = restored
	check(health(g, other).freshness == "unconfirmed", "restore cannot manufacture heartbeat freshness")
	check(observed(g, other, "idle").code == "controller_mismatch", "restored uncertain ownership cannot silently resume worker observations")
	local atomic = shared.fixture(clock); local atomic_id = atomic:accepted(false)
	local prior = runtime.json.encode(atomic.authority.registry)
	atomic.memory.fail = true
	check(observed(atomic, atomic_id, "exited").code == "persistence_failed" and runtime.json.encode(atomic.authority.registry) == prior,
		"failed observation save publishes neither new health nor revision")
	check(atomic.authority.uncommitted_observation, "failed native safety evidence fences further effects")
end

local function window_fixture(options: any?)
	local initializing = true
	local now = 1000
	local f = shared.fixture(function() return { now_ms = 1700000000000, mono_ms = now, epoch = "health-host" } end, { defer_admission = true })
	local id
	local controller_alias = 9001
	local bridge_outcome, bridge_missing
	local bridge_bytes = {} -- Exact SPAWN response bytes, keyed by logical relay lane.
	local peer_revision, peer_state_reads = 1000000, 0 -- SPAWN store revision is not the wire's observed ORCH revision.
	local control_responses, after_control_response = {}, nil
	local bridge_states = {}
	local relay_lanes, relay_frames, relay_serial = {}, {}, 0
	local relay_responses = {}
	local relay_releases, release_requests, release_acks, rebind_requests = {}, {}, {}, {}
	local bind_serial = 0
	local relay_held, relay_error
	local relay_boot, peer_boot = "fixture-orch-boot", "fixture-spawn-boot"
	local relay_endpoint = "fixture-relay"
	local relay_acks, observed_panes, decision_result = {}, nil, nil
	local inbox_observation
	local allocation_result
	local decision_requests = {}
	local control_authorizations = {}
	local peer_session
	local peer_requests = if options and options.peer_entries then options.peer_entries else {}
	local function peer_progress()
		if not peer_session then return nil end
		local entries = {}
		for _, entry in peer_requests do
			table.insert(entries, string.format("%.0f", entry.request_serial) .. ":" .. entry.request_id .. ":"
				.. entry.action_id .. ":" .. entry.op .. ":" .. entry.body_status)
		end
		table.sort(entries)
		local control = table.clone(peer_session.control)
		control.last_authority_revision = nil -- Observing another page is not delivery progress.
		return shared.codec.sha256(string.format("%.0f", peer_session.admission_seq) .. "\n"
			.. shared.codec.dispatch_source_bytes(control) .. "\n" .. table.concat(entries, "\n"))
	end
	local function render_bridge(pane)
		bridge_states[pane] = { protocol = 2, phase = "stable", spawn_namespace = "fixture-spawn",
			authority_namespace = f.authority.registry.authority_namespace, authority_revision = peer_revision,
			compatibility = clone(f.authority.registry.compatibility), session_progress = peer_progress(),
			control_response = clone(control_responses[pane]) }
		local lane = relay_lanes[pane]
		if lane then
			lane.peer_boot = peer_boot
			relay_frames[pane] = { current = runtime.json.encode(bridge_states[pane]), response = bridge_bytes[pane] }
			-- A missing response has neither a frame nor a carrier proof. Leaving the
			-- previous proof here would model a torn host projection, not a lost reply.
			for kind in lane.messages do
				if relay_frames[pane][kind] == nil then lane.messages[kind] = nil end
			end
			for kind, bytes in relay_frames[pane] do
				local previous = lane.messages[kind]
				if not previous or previous.bytes ~= bytes or previous.incarnation ~= peer_boot then
					relay_serial += 1
					lane.messages[kind] = { id = "r-" .. tostring(relay_serial), incarnation = peer_boot,
						route = "spawn." .. kind, binding = relay_endpoint .. ":" .. pane, bytes = bytes }
					if kind == "response" then relay_responses[lane.messages[kind].id] = bytes end
				end
			end
		end
	end
	local function confirm_release(lane_id)
		local lane = assert(relay_lanes[lane_id], "positive release requires the exact retained lane")
		relay_releases[lane_id] = { lane_id = lane_id, peer_boot = assert(lane.peer_boot) }
		relay_lanes[lane_id], relay_frames[lane_id], bridge_states[lane_id], bridge_bytes[lane_id] = nil, nil, nil, nil
	end
	local function confirm_rebind(lane_id)
		local lane = assert(relay_lanes[lane_id], "reconnect keeps its original lane")
		local bind = assert(lane.pending_bind, "a fresh bind receipt must answer this lane's actual rebind request")
		assert(lane.sent.bind == bind, "the receipt cannot adopt another bind request")
		lane.bind_id, lane.pending_bind, lane.held, lane.error = bind, nil, nil, nil
		local held = false
		for _, sibling in relay_lanes do if sibling.held then held = true; break end end
		if not held then relay_held, relay_error = nil, nil end
		render_bridge(lane_id)
	end
	-- Legacy native transport views are preservation fixtures only, never a production path.
	local leases, bridge_panes, bridge_placements, bridges_closed, moved, tab_names, usage_placements = {}, {}, {}, {}, {}, {}, {}
	local composition_moves, composition_resizes = {}, {}
	local session_tabs = { [7] = { 1 }, [8] = { 2 } }
	local bridge_events, bridge_routes, result_events = {}, {}, {}
	local timers, hooks, events, notices, toasts = {}, {}, {}, {}, {}
	local notice_events = {}
	local pick_callback, prompt_callback, picked, picker_spec, prompt_spec
	-- The controller block's published one-shot operator intent (host.luau publishes it on click).
	local intent, intent_serial = nil, 0
	local selected, selected_worker, result, command_result, driver_result, poll_result, control_result, receipt
	-- Completed results remain readable by exact action until their driver releases
	-- the host receipt; the current dispatch result is not that scoped surface.
	local scoped_results = {}
	local held_poll_receipt, held_control_receipt, held_conversation_receipt
	local deferred_continuation
	-- Guided recovery: SPAWN's read-only owner_status answer, published checklist and palette runs.
	local owner_answer, recovery_steps, ran_actions = "current", nil, {}
	local retired_owner_generation
	-- USAGE capacity export: a fixture server answering the reader's correlated requests.
	local usage = nil
	local display_requests = {}
	local board_opened, managed_opened, hidden_views = {}, {}, {}
	local host = { id = "local", state = "connected", panes = { 9001, 9002, 9004 } }
	local panes = { [9001] = { pane = 9001, block = "orchplus.orchestrator", tab = 1 }, [9002] = { pane = 9002, tab = 1 }, [9004] = { pane = 9004, tab = 1 } }
	local agents = { { pane = 9002, state = "idle" }, { pane = 9004, state = "working" } }
	local current = { id = 7, host = "local" }
	local ftern = table.clone(runtime)
	if options and options.forbid_desktop_inbox then
		ftern.fs = table.clone(runtime.fs)
		ftern.fs.list = function() error("Inbox enumeration must execute in the host VM, not the desktop VM.") end
	end
	ftern.now = function() return now end
	ftern.timer = function(_, callback) local token = { callback = callback }; function token:cancel() self.cancelled = true end; table.insert(timers, token); return token end
	ftern.on = function(name, callback) hooks[name] = callback end
	-- A window VM by default: the idle-wake helper runs against this recorded stub, never a real child.
	local processes, wake_events, idle_wake = {}, {}, nil
	ftern.context = if options and options.context then options.context else "window"
	if options and options.os then ftern.runtime = { os = options.os, jit = false } end
	ftern.process = { run = function(argv, callback)
		if options and options.process_error then error(options.process_error) end
		table.insert(processes, { argv = clone(argv), callback = callback })
	end }
	local palette = {}
	local files_buttons, status_formatters, prompt_calls = {}, {}, {}
	ftern.command = function(def) palette[def.id] = def end; ftern.files = { button = function(def) table.insert(files_buttons, def) end }
	ftern.chrome = table.clone(runtime.chrome or {})
	ftern.chrome.status = function(formatter) table.insert(status_formatters, formatter) end
	ftern.route = { link = function(callback) hooks.source_link = callback end }
	local function find(node, key)
		if node.p and node.p.key == key then return node end
		for _, child in node.c or {} do local match = find(child, key); if match then return match end end
		return nil
	end
	local function tree(advanced)
		local projection = state.project(f.authority.registry)
		projection.dispatch = dispatch.project(f.authority.registry, f.origin.logical_session_id, f.origin.alias_nonce, selected, scoped_results)
		local lanes = {}
		for lane_id, retained in relay_lanes do
			local messages = {}
			for kind, proof in retained.messages do local public = clone(proof); public.bytes = nil; messages[kind] = public end
			table.insert(lanes, { lane_id = lane_id, peer_boot = retained.peer_boot, bind_id = retained.bind_id,
				held = retained.held, error = retained.error, release_held = retained.release_held, messages = messages })
		end
		local releases = {}
		for _, proof in relay_releases do table.insert(releases, clone(proof)) end
		local usage_meta, usage_frames
		if usage and usage.request_id then
			local boot = usage.peer_boot or "fixture-usage-boot"
			local request_id = usage.response_request_id or usage.request_id
			usage_meta = { request_id = request_id, peer_boot = boot,
				message = { id = request_id, incarnation = boot, route = "usage.capacity.response", binding = request_id } }
			usage_frames = { capacity = usage.text }
		end
		return shared.load("views").render({ pane = 42, alias_nonce = f.origin.alias_nonce, orch_session_id = f.origin.logical_session_id,
			advanced_open = advanced == true, session_panes = observed_panes, decision_context_result = decision_result, inbox_observation = inbox_observation, dispatch_allocation_result = allocation_result,
			spawn_relay = { schema = 1, peer = "spawn", host_pane_id = "42", source_nonce = f.origin.alias_nonce,
				relay_endpoint = relay_endpoint, relay_boot = relay_boot, held = relay_held, error = relay_error,
				lanes = lanes, releases = releases }, spawn_relay_frames = relay_frames,
			usage_relay = { schema = 1, peer = "usage", host_pane_id = "42", source_nonce = f.origin.alias_nonce,
				relay_endpoint = relay_endpoint, relay_boot = relay_boot, capacity = usage_meta }, usage_relay_frames = usage_frames,
			action_serial = 0, dispatch_action = selected, dispatch_result = result, dispatch_command_result = command_result,
			dispatch_driver_result = driver_result, dispatch_poll_result = poll_result, dispatch_control_result = control_result,
			dispatch_receipt = receipt, scoped_results = scoped_results, workflow_worker = selected_worker,
			operator_intent = intent, idle_wake = idle_wake }, projection, "ready")
	end
	local cx = { hosts = { current = function() return host end, list = function() return { host } end },
		sessions = { current = function() return current end }, window_key = function() return "" end,
		agents = { list = function() return agents end, ask = function() error("ORCH+ must not ask agents directly") end },
		layout = { focus = function(_, pane) picked = pane end, unpark = function() return true end,
			move = function(_, pane, target, side, placement)
				table.insert(composition_moves, { pane = pane, target = target, side = side, options = clone(placement) })
				if options and options.compose_refused then return false end
				assert(panes[pane] and panes[target], "composition requires two existing native panes")
				panes[pane].tab = panes[target].tab
				if placement and placement.focus then picked = pane end
				return true
			end,
			resize = function(_, pane, side, delta)
				table.insert(composition_resizes, { pane = pane, side = side, delta = delta })
			end,
			close = function(_, pane)
				table.insert(bridges_closed, pane); panes[pane] = nil; leases[pane] = nil
				for index, value in host.panes do if value == pane then table.remove(host.panes, index); break end end
			end,
			move_to_new_tab = function(_, pane, session)
				local tab = 100 + #session_tabs[session]; table.insert(session_tabs[session], tab); panes[pane].tab = tab; moved[pane] = true; return tab
			end,
			move_to_tab = function(_, pane, tab) panes[pane].tab = tab; moved[pane] = true; return true end,
			name_tab = function(_, tab, name) tab_names[tab] = name end },
		toast = function(_, level, _, message) table.insert(notices, message); table.insert(toasts, { level = level, text = message }) end,
		new_block = function(_, block, _args, how, options)
			if block == "spawn.spawner" then
				table.insert(managed_opened, { args = clone(_args), how = how, options = clone(options) })
				return 9801
			end
			if block == "usage.capacity" then
				table.insert(usage_placements, { how = how, options = clone(options) })
			elseif block == "spawn.dispatch" then
				table.insert(bridge_placements, { how = how, options = clone(options) })
			end
			error("unexpected native block creation: " .. tostring(block) .. "; helpers must stay pane-free")
		end,
		pick = function(_, spec) picker_spec = clone(spec); return { next = function(_, callback) pick_callback = callback end } end,
		prompt = function(_, spec) prompt_spec = spec; return { next = function(_, callback) prompt_callback = callback end } end,
		actions = { run = function(_, label) table.insert(ran_actions, label); return label end, list = function() return {} end },
		-- Desktop board cx: opens are recorded; reads never answer (no board fixture is polled).
		board = { open = function(_, path) table.insert(board_opened, path) end,
			read = function() return { next = function() end } end, move = function() return { next = function() end } end },
		session = {} }
	function cx.session:pane(pane) return panes[pane] end
	-- Match setup_ui's native-view contract: an existing pane can still have no visible view.
	function cx.session:view(pane)
		return if panes[pane] and not hidden_views[pane] and not moved[pane] then { id = "main" } else nil
	end
	function cx.session:panes() local rows = {}; for _, pane in panes do table.insert(rows, pane) end; return rows end
	function cx.session:sessions() return { { id = 7, tabs = session_tabs[7] }, { id = 8, tabs = session_tabs[8] } } end
	function cx.session:block_types() return { { kind = "orchplus.orchestrator" }, { kind = "orchplus.form" } } end
	function cx.session:layout() return { root = { pane = controller_alias }, zoomed = false } end
	local options_fixture = options or {}
	function cx.session:surface(pane, options)
		if panes[pane] and panes[pane].block == "usage.capacity" and usage then
			return { surface = { role = "plugin.usage.capacity" }, main = { k = "text", id = options.root, p = { role = "usage-capacity-response", spans = { usage.text } } } }
		end
		local row = panes[pane]
		if row and moved[pane] then return nil end
		if row and row.block == "spawn.dispatch" then
			if options.root == "main.spawn-dispatch-lease" then
				if not leases[pane] then return nil end -- A legacy SPAWN bridge renders no lease.
				return { surface = { role = "plugin.spawn.dispatch" }, main = { k = "text", id = options.root,
					p = { role = "spawn.dispatch.lease", spans = { "SPAWN_BRIDGE v1 " .. runtime.json.encode(leases[pane]) } } } }
			end
			if not bridge_outcome then return nil end
			if options.root == "main.spawn-dispatch-state" then
				peer_state_reads += 1
				local current = bridge_states[pane]
				if not current then return nil end
				return { surface = { role = "plugin.spawn.dispatch" }, main = { k = "text", id = options.root,
					p = { role = "spawn.dispatch.state", spans = { runtime.json.encode(current) } } } }
			end
			return { surface = { role = "plugin.spawn.dispatch" }, main = { k = "text", id = "main.spawn-dispatch-response",
				p = { role = "spawn.dispatch.response", spans = { bridge_bytes[pane] or "SPAWN_DISPATCH v2 {}" } } } }
		end
		if pane ~= controller_alias then return nil end
		if options.root:match("^main%.spawn%-relay%-.+%-current$") then peer_state_reads += 1 end
		if options.root == "main.catalog-index" and options_fixture.catalog_index == "missing" then return nil end
		if options.root == "main.catalog-index" and options_fixture.catalog_index == "unreadable" then
			return { surface = { role = "plugin.orchplus.orchestrator" }, main = { k = "text", id = options.root,
				p = { role = "orchplus.catalog", spans = { "not-json" } } } }
		end
		local node = find(tree(), options.root:sub(6)); if not node then return nil end
		node = clone(node); node.id = options.root
		return { surface = { role = "plugin.orchplus.orchestrator" }, main = node }
	end
	local function publish_command(input, act, response)
		response.request_id = input.request_id; response.command = input.command
		if act == "authority-command" or act == "authority-operator-command" then command_result = response; return end
		response.action_id = response.action_id or input.action_id
		if input.command == "observe_allocation" then allocation_result = response end
		if act ~= "dispatch-operator-command" and input.command == "poll" then
			response.worker_id = input.worker_id
			poll_result = response
			if response.ok and response.code == "mailbox_idle" and response.action_id == nil then return end
		end
		local workflow_only = table.find({ "observe", "observe_allocation", "pause", "resume", "policy", "answer", "cancel_gate", "recheck_gate", "continue_controller", "sweep",
			"cancel_landing", "move_landing", "landing_lost", "reconcile_landing", "capacity", "plan_import", "board_intake", "inbox_intake", "template_start",
			"bridge_control", "bridge_result", "bridge_observe" }, input.command) ~= nil
		if table.find({ "bridge_control", "bridge_result", "bridge_observe" }, input.command) then control_result = response end
		if act == "dispatch-operator-command" then
			command_result = response
			if not workflow_only then driver_result = response end
		end
		if (act ~= "dispatch-operator-command" or response.ok) and not workflow_only then result = response end
		if response.ok and response.action_id then selected = response.action_id end
	end
	function cx.session:event(pane, event)
		local native_pane, native_event = pane, event
		if event.act == "inbox-observe" or event.act == "inbox-archive" then
			inbox_observation = shared.host.inbox_observation(f.authority.registry, f.origin.logical_session_id, runtime.json.decode(event.value), event.act == "inbox-archive")
			return
		end
		if panes[pane] and panes[pane].block == "usage.capacity" then usage.handle(runtime.json.decode(event.value)); return end
		if event.act == "spawn_relay" then
			assert(pane == controller_alias, "peer traffic uses the real ORCH source pane, never a fabricated SPAWN pane")
			local outer = runtime.json.decode(event.value)
			assert(outer.schema == 1 and outer.source_nonce == f.origin.alias_nonce and outer.relay_endpoint == relay_endpoint and outer.relay_boot == relay_boot,
				"relay endpoint and native source incarnation must match")
			if outer.act == "bind" then
				assert(not relay_lanes[outer.lane_id], "bind is one-shot per logical lane")
				bind_serial += 1
				relay_lanes[outer.lane_id] = { origin = runtime.json.decode(outer.bytes), bind_id = "bind-" .. tostring(bind_serial),
					sent = { bind = "bind-" .. tostring(bind_serial) }, messages = {} }
				if bridge_outcome then render_bridge(outer.lane_id) end
				return
			elseif outer.act == "ack" then table.insert(relay_acks, runtime.json.decode(outer.bytes)); return
			elseif outer.act == "release_ack" then
				local proof = assert(relay_releases[outer.lane_id], "release ACK follows positive host proof only")
				assert(proof.peer_boot == outer.peer_boot and outer.bytes == "{}", "release ACK preserves the retired incarnation")
				table.insert(release_acks, clone(outer))
				if options and (options.lose_release_acks or 0) > 0
					and (options.lose_release_ack_lane == nil or options.lose_release_ack_lane == outer.lane_id) then options.lose_release_acks -= 1
				else relay_releases[outer.lane_id] = nil end
				return
			elseif outer.act == "release" then
				local lane = assert(relay_lanes[outer.lane_id])
				assert(outer.peer_boot == lane.peer_boot and outer.peer_boot == peer_boot and outer.bytes == "{}",
					"idle release targets only the exact current peer incarnation")
				table.insert(release_requests, clone(outer))
				if options and options.release_held then lane.release_held = true
				elseif not (options and options.defer_release) then lane.release_held = nil; confirm_release(outer.lane_id) end
				return
			elseif outer.act == "rebind" then
				local lane = assert(relay_lanes[outer.lane_id], "explicit reconnect must retain its original lane")
				assert(shared.quota.digest(runtime.json.decode(outer.bytes)) == shared.quota.digest(lane.origin),
					"explicit reconnect carries the exact original native origin, never new effect authority")
				table.insert(rebind_requests, clone(outer))
				lane.peer_boot, lane.bind_id, lane.sent.bind, lane.messages = nil, nil, nil, {}
				relay_frames[outer.lane_id], bridge_bytes[outer.lane_id], control_responses[outer.lane_id] = nil, nil, nil
				bind_serial += 1
				lane.sent.bind = "bind-" .. tostring(bind_serial)
				lane.pending_bind = lane.sent.bind
				if not (options and options.defer_rebind) then confirm_rebind(outer.lane_id) end
				return
			end
			assert(outer.peer_boot == peer_boot and relay_lanes[outer.lane_id], "effect/read callback requires exact current peer boot")
			pane, event = outer.lane_id, { ev = "action", act = outer.act, value = outer.bytes }
		elseif event.act == "usage_relay" then
			assert(pane == controller_alias, "usage reads use the actual ORCH panel")
			local outer = runtime.json.decode(event.value)
			assert(outer.source_nonce == f.origin.alias_nonce and outer.relay_boot == relay_boot and outer.relay_endpoint == relay_endpoint)
			if outer.act == "ack" then table.insert(relay_acks, runtime.json.decode(outer.bytes)); return end
			if outer.kind == "display" then
				-- Optional USAGE is absent: retain the real request, fabricate no response or ACK.
				table.insert(display_requests, runtime.json.decode(outer.bytes))
				return
			end
			assert(outer.kind == "capacity" and usage, "only the configured read-only fixture adapter answers")
			local request = runtime.json.decode(outer.bytes); usage.request_id = request.request_id; usage.handle(request); return
		end
		if relay_lanes[pane] or (panes[pane] and panes[pane].block == "spawn.dispatch") then
			table.insert(bridge_panes, pane)
			local input = runtime.json.decode(event.value)
			control_responses[pane] = nil -- Metadata belongs only to the response currently on this pane.
			table.insert(bridge_events, input)
			table.insert(bridge_routes, { pane = pane, event = clone(event), native_pane = native_pane, native_event = clone(native_event), at = now })
			if options and options.bridge_handler and (input.op == "status" or input.op == "mailbox_read") then
				assert(shared.codec.decode_dispatch_request(event.value), "delivery fixture accepts canonical v2 requests")
				bridge_bytes[pane] = options.bridge_handler(input, event, now)
				render_bridge(pane)
				return
			end
			if options and options.catalog_handler and input.op == "catalog" then
				assert(shared.codec.decode_dispatch_request(event.value), "catalog fixture accepts canonical v2 requests")
				bridge_bytes[pane] = options.catalog_handler(input)
				render_bridge(pane)
				return
			end
			if options and options.attachment_handler and input.op == "attach_worker" then
				assert(shared.codec.decode_dispatch_request(event.value), "attachment fixture accepts the exact canonical request")
				bridge_bytes[pane] = options.attachment_handler(f, input)
				render_bridge(pane)
				return
			end
			if options and options.startup_handler and (input.op == "mailbox_provision" or input.op == "launch") then
				assert(shared.codec.decode_dispatch_request(event.value), "startup fixture accepts canonical v2 requests")
				bridge_bytes[pane] = options.startup_handler(f, input)
				render_bridge(pane)
				return
			end
			if input.op == "admit_session" or input.op == "reconcile_session" or input.op == "close_session" then
				assert(shared.codec.decode_dispatch_request(event.value), "native control fixture accepts only canonical v2 requests")
				local refusal = if options and options.control_refusal then options.control_refusal(input) else nil
				if refusal then
					bridge_bytes[pane] = shared.frame(input, "rejected", nil, refusal, refusal.code, input.authority_revision)
					assert(shared.codec.decode_dispatch_response(bridge_bytes[pane], input), "control refusal must be canonical V2")
					render_bridge(pane)
					return
				end
				if options and options.before_control_authorization then
					options.before_control_authorization(f, clone(input))
					local current = f.authority.registry.sessions[input.logical_session_id].bridge_control
					local authorized = current ~= nil and current.request_bytes == event.value
						and f.authority.registry.revision == input.authority_revision
					table.insert(control_authorizations, { request_id = input.request_id, authorized = authorized,
						captured_revision = input.authority_revision, observed_revision = f.authority.registry.revision })
					if not authorized then
						-- The existing native control_peer gate withholds authorization; it does not invent a refusal response.
						bridge_bytes[pane] = nil; render_bridge(pane); return
					end
				end
				peer_revision += 1
				local payload = { admission_cursor = input.admission_seq, compatibility = clone(input.compatibility) }
				if input.op == "close_session" then
					bridge_bytes[pane] = shared.frame(input, "closed", payload, nil, "admission_absent", input.authority_revision)
				else
					payload.control = { phase = "open", generation_floor = input.generation_floor, request_floor = input.settled_before,
						next_request_serial = input.next_request_serial, last_authority_revision = input.authority_revision,
						binding = clone(input.control_origin.binding) }
					if input.op == "reconcile_session" then
						payload.outstanding = if options and options.control_outstanding then options.control_outstanding(input)
							else { after_serial = 0, through_serial = 0, next_after_serial = 0, complete = true, entries = runtime.json.array() }
					end
					bridge_bytes[pane] = shared.frame(input, if input.op == "admit_session" then "admitted" else "reconciled",
						payload, nil, "current_admission", input.authority_revision)
				end
				peer_session = if payload.control then { admission_seq = input.admission_seq, control = clone(payload.control) } else nil
				control_responses[pane] = { request_id = input.request_id, action_id = input.action_id,
					spawn_namespace = "fixture-spawn", session_progress = peer_progress() }
				render_bridge(pane)
				local decoded_control, control_problem = shared.codec.decode_dispatch_response(bridge_bytes[pane], input)
				assert(decoded_control, "native control fixture must publish a canonical response: " .. runtime.json.encode(control_problem))
				if after_control_response then
					local callback = after_control_response; after_control_response = nil
					callback(input, clone(control_responses[pane]), decoded_control)
				end
				return
			end
			if input.op == "owner_status" then
				assert(shared.codec.decode_dispatch_request(event.value), "owner inspection requires a valid read-only request before and after admission")
				local session = f.authority.registry.sessions[input.logical_session_id]
				if owner_answer == "unreadable" then bridge_bytes[pane] = nil; render_bridge(pane); return end
				if owner_answer == "unknown" then
					bridge_bytes[pane] = shared.frame(input, "uncertain", nil, nil, "unknown_effect", session.last_authority_revision)
					assert(shared.codec.decode_dispatch_response(bridge_bytes[pane], input), "unknown admission must be canonical V2")
					render_bridge(pane)
					return
				end
				if owner_answer == "absent" then
					bridge_bytes[pane] = shared.frame(input, "absent", { admission_cursor = session.admission_seq or 0,
						compatibility = clone(f.authority.registry.compatibility) }, nil, "admission_absent", session.last_authority_revision)
					assert(shared.codec.decode_dispatch_response(bridge_bytes[pane], input), "absent admission must be canonical V2")
					render_bridge(pane)
					return
				end
				local observed_binding = if owner_answer == "none" or owner_answer == "retired" then nil else clone(input.origin_binding)
				if observed_binding and owner_answer == "previous_incarnation" then observed_binding.window_epoch = "previous-window" end
				if observed_binding and owner_answer == "other_binding" then observed_binding.native_session_id ..= "-other" end
				local control = { phase = "open", generation_floor = if observed_binding then 0 else input.controller_generation,
					request_floor = session.request_floor, next_request_serial = session.next_request_serial,
					last_authority_revision = session.last_authority_revision, binding = observed_binding }
				if owner_answer == "retired" then
					control.generation_floor = retired_owner_generation
					control.recovery = { recovery_id = "fixture-confirmed-recovery", phase = "confirmed",
						generation_floor = retired_owner_generation }
				end
				bridge_bytes[pane] = shared.frame(input, "owner_status", { admission_cursor = session.admission_seq,
					compatibility = clone(f.authority.registry.compatibility), control = control }, nil, "current_admission", session.last_authority_revision)
				render_bridge(pane)
				return
			end
			if input.op == "mailbox_inventory" then
				local inventory = options and options.inventory
				bridge_bytes[pane] = if inventory then shared.frame(input, "inventory", {
					observed_at_ms = 1700000000000, open_files = inventory.open_files, stale_files = inventory.stale_files,
					mailboxes = inventory.mailboxes })
					else shared.frame(input, "uncertain", nil, { code = "inventory_unavailable",
						message = "This fixture peer has no mailbox-filesystem observation." })
				render_bridge(pane); return
			end
			-- A withdrawal's exact unused-mailbox retirement (never the original effect): SPAWN confirms it.
			if input.op == "mailbox_retire" and input.mode == "retire" then
				bridge_bytes[pane] = shared.frame(input, "retired", nil); render_bridge(pane); return
			end
			assert(input.op == "status", "replacement window must never resubmit the original effect")
			bridge_bytes[pane] = if bridge_missing then shared.frame(input, "missing") else shared.frame(input, "found", { outcome = bridge_outcome })
			render_bridge(pane)
			return
		end
		assert(pane == controller_alias)
		if event.act:sub(1, 16) == "dispatch-result/" then
			table.insert(result_events, clone(event))
			if options and options.commit_results then
				local grant, executor = event.act:match("^dispatch%-result/([^/]+)/(.+)$")
				local envelope = runtime.json.decode(event.value)
				local action
				for _, candidate in f.authority.registry.dispatch.actions do
					if candidate.claim and candidate.claim.grant_id == grant then action = candidate; break end
				end
				assert(action, "result route must retain its exact live claim")
				local body = assert(shared.codec.decode_dispatch_response(envelope.response_bytes, action.request))
				local projected = dispatch.project(f.authority.registry, f.origin.logical_session_id, f.origin.alias_nonce, body.action_id).actions[body.action_id]
				local execution_origin = projected.execution_origin or action.request.origin_binding
				assert(executor == execution_origin.window_epoch, "result route must name the current execution epoch, not replace its retained claim executor")
				local response = f:apply("result", { action_id = body.action_id, executor = action.claim.executor, grant_id = grant,
					authority_namespace = envelope.authority_namespace, expected_revision = envelope.expected_revision,
					origin = execution_origin, controller_pane = projected.execution_controller_pane or action.request.controller_pane,
					response_bytes = envelope.response_bytes })
				assert(response.ok, response.message)
				response.action_id, response.grant_id, response.command = body.action_id, grant, "result"
				result = response
				receipt = { action_id = body.action_id, grant_id = grant, response_sha256 = shared.codec.sha256(envelope.response_bytes) }
				scoped_results[body.action_id] = { result = response, receipt = receipt }
			end
			return
		end
		if event.act == "dispatch-release-scope" then
			local input = runtime.json.decode(event.value)
			local retained = scoped_results[input.action_id]
			local proof = if retained then retained.receipt else nil
			local delivery = proof and proof.grant_id ~= nil and proof.grant_id == input.grant_id
				and proof.response_sha256 == input.response_sha256
			local withdrawal = proof and proof.withdrawal_request_id ~= nil and proof.withdrawal_request_id == input.withdrawal_request_id
				and proof.worker_id == input.worker_id
			if input.source_nonce == f.origin.alias_nonce and (delivery or withdrawal) then scoped_results[input.action_id] = nil end
			return
		end
		if event.act == "operator-intent-done" then
			local input = runtime.json.decode(event.value)
			if intent and input.serial == intent.serial then intent = nil end
			return
		end
		if event.act == "idle-wake" then
			-- As host.luau: display-only helper state for this exact controller alias.
			local input = runtime.json.decode(event.value)
			assert(input.source_nonce == f.origin.alias_nonce, "idle-wake state names this controller's alias")
			table.insert(wake_events, input)
			idle_wake = if input.state == "idle" then nil else { state = input.state, detail = input.detail }
			return
		end
		if event.act == "dispatch-notice" then table.insert(notice_events, runtime.json.decode(event.value)); return end
		if event.act == "config-open-request" then return end
		if event.act == "config-panes" then observed_panes = runtime.json.decode(event.value); return end
		if event.act == "upgrade-window-readback" then return end
		if event.act == "decision-context" then
			local input = runtime.json.decode(event.value)
			table.insert(decision_requests, clone(input))
			decision_result = { request_id = input.request_id, decision_context = dispatch.decision_context(f.authority.registry, input.event) }
			return
		end
		if event.act == "recovery-steps" then
			recovery_steps = runtime.json.decode(event.value)
			return
		end
		local input = runtime.json.decode(event.value)
		if event.act == "authority-command" or event.act == "authority-operator-command" then
			assert(input.source_nonce == f.origin.alias_nonce and dispatch.origin(input.origin)
				and input.origin.host_pane_id == f.origin.host_pane_id
				and input.event.orch_session_id == f.origin.logical_session_id,
				"authority lifecycle input must retain the genuine current controller envelope")
			input = input.event
		end
		table.insert(events, input)
		if options and options.hold_poll and input.command == "poll" then return end
		if event.act == "dispatch-select" then selected = input.action_id; return end
		if not initializing and options and options.defer_continuation and input.command == "continue_controller" then
			assert(deferred_continuation == nil, "only one exact continuation may await native HOST delivery")
			deferred_continuation = { input = input, act = event.act }
			return
		end
		if options and options.before_control and input.command == "bridge_control" then options.before_control(f, input) end
		if options and options.before_authority then options.before_authority(f, input) end
		local response = f.authority:apply(input)
		if options and options.hold_conversation_receipt ~= nil and input.command == options.hold_conversation_receipt then
			assert(held_conversation_receipt == nil, "only one exact conversation command receipt may be retained")
			held_conversation_receipt = { input = input, act = event.act, response = response }
			return
		end
		if options and ((options.hold_control_receipt and input.command == "bridge_control")
			or (options.hold_control_result_receipt and input.command == "bridge_result")) then
			assert(held_control_receipt == nil, "only one current control command receipt may be outstanding")
			held_control_receipt = { input = input, act = event.act, response = response }
			return
		end
		if options and options.hold_poll_receipt and input.command == "poll" then
			assert(held_poll_receipt == nil, "only one host poll receipt may be outstanding")
			held_poll_receipt = { input = input, act = event.act, response = response }
			return
		end
		publish_command(input, event.act, response)
	end
	local module = assert(loadstring(runtime.fs.read(root .. "/window.luau"), "health-window"))
	-- Injected local wall clock: the nightly sweep schedule reads os.time/os.date; tables still convert.
	local wall = os.time({ year = 2026, month = 11, day = 3, hour = 2, min = 0, sec = 0 })
	local fixed_os = table.clone(os); fixed_os.time = function(spec: any?) if spec ~= nil then return os.time(spec) end return wall end
	local local_modules = {}
	local function window_require(name)
		local key = name:gsub("^%./", "")
		-- The health fixture owns native interaction completion; the form_ui group exercises
		-- the real host/window form transport, edits and stale-result protection separately.
		-- The status-bar prompt is the shared module's own concern; this fixture records only that the window half asks.
		if key == "status/status_prompt" then return { ensure = function(prompt_cx, id) table.insert(prompt_calls, { cx = prompt_cx, id = id }) end } end
		if key == "form_window" then return { new = function()
			local forms = {}
			return {
				choose = function(context, source, _, spec, done)
					local form = { spec = spec }; forms[source] = form
					context:pick(spec):next(function(value, err, fresh)
						if fresh and not err then done(fresh, value) end
						if forms[source] == form and (value == nil or not spec.retain) then forms[source] = nil end
					end)
				end,
				input = function(context, source, _, spec, done)
					local form = { spec = spec }; forms[source] = form
					context:prompt(spec):next(function(value, err, fresh)
						if fresh and not err and (value == nil or not spec.validate or not spec.validate(value)) then
							done(fresh, value)
							if forms[source] == form then forms[source] = nil end
						end
					end)
				end,
				open = function(_, source, _, spec, done) forms[source] = { spec = spec, done = done } end,
				cancel = function(_, source) forms[source] = nil end,
				active = function(source, tag) return forms[source] ~= nil and (tag == nil or forms[source].spec.tag == tag) end,
				update = function() return true end, focus = function() return true end, tick = function() end,
			}
		end } end
		if not table.find({ "picker_window", "source_window", "conversation_window", "setup_window", "readiness_window" }, key) then return shared.load(name) end
		if local_modules[key] then return local_modules[key] end
		local chunk = assert(loadstring(runtime.fs.read(root .. "/" .. key .. ".luau"), key))
		setfenv(chunk, setmetatable({ tern = ftern, require = window_require, os = fixed_os }, { __index = environment }))
		local_modules[key] = chunk(); return local_modules[key]
	end
	setfenv(module, setmetatable({ tern = ftern, require = window_require, os = fixed_os }, { __index = environment }))
	local api = module()
	local w = { f = f, id = id, cx = cx, api = api, timers = timers, hooks = hooks, events = events, agents = agents, panes = panes, current = current, notices = notices, board_opened = board_opened,
		processes = processes, commands = palette, files_buttons = files_buttons, status_formatters = status_formatters, prompt_calls = prompt_calls, wake_events = wake_events, toasts = toasts, notice_events = notice_events, managed_opened = managed_opened, hidden_views = hidden_views }
	function w:rendered(advanced) return runtime.json.encode(tree(advanced)) end
	function w:visible_text(advanced)
		local out = {}
		local function walk(node)
			if type(node) ~= "table" then return end
			if type(node.p) == "table" and type(node.p.role) == "string" and node.p.role:sub(1, 9) == "orchplus." then return end
			for key, value in node do
				if type(value) == "string" then
					if key == "t" or key == "text" or key == "label" or type(key) == "number" then table.insert(out, value) end
				elseif key ~= "actions" then walk(value) end
			end
		end
		walk(tree(advanced)); return table.concat(out, "\n")
	end
	function w:observed_panes() return clone(observed_panes) end
	function w:decision_requests() return clone(decision_requests) end
	function w:composition_moves() return composition_moves end
	function w:composition_resizes() return composition_resizes end
	function w:native_tab(pane, tab)
		assert(panes[pane]); panes[pane].tab = tab
		if not table.find(session_tabs[current.id], tab) then table.insert(session_tabs[current.id], tab) end
	end
	function w:catalog_index()
		local span = find(tree(), "catalog-index").p.spans[1]
		return runtime.json.decode(if type(span) == "string" then span else span.t)
	end
	function w:deliver_continuation()
		local held = assert(deferred_continuation, "fixture requires the exact pending native continuation")
		deferred_continuation = nil
		local response = f.authority:apply(held.input)
		publish_command(held.input, held.act, response)
		return response
	end
	function w:release_poll_receipt()
		local held = assert(held_poll_receipt, "fixture requires a real retained host poll receipt")
		assert(held.response.ok, held.response.message)
		options.hold_poll_receipt = false
		held_poll_receipt = nil
		publish_command(held.input, held.act, held.response)
		return held.response
	end
	function w:release_control_receipt()
		local held = assert(held_control_receipt, "fixture requires a real retained host control receipt")
		options.hold_control_receipt = false
		options.hold_control_result_receipt = false
		held_control_receipt = nil
		publish_command(held.input, held.act, held.response)
		return held.response
	end
	function w:release_conversation_receipt()
		local held = assert(held_conversation_receipt, "fixture requires a genuine pending conversation command receipt")
		assert(held.response.ok, runtime.json.encode(held.response))
		options.hold_conversation_receipt = nil
		held_conversation_receipt = nil
		publish_command(held.input, held.act, held.response)
		return held.response
	end
	-- The owner clicks a dispatch button: its host block publishes the exact request as a one-shot
	-- intent, which the window's observation consumer runs at most once.
	function w:click(command, fields)
		local request = { command = command, source_nonce = f.origin.alias_nonce, orch_session_id = f.origin.logical_session_id,
			authority_namespace = f.authority.registry.authority_namespace, expected_revision = f.authority.registry.revision }
		for key, value in fields or {} do request[key] = value end
		intent_serial += 1
		intent = { version = 1, source_nonce = f.origin.alias_nonce, serial = "fixture-intent-" .. tostring(intent_serial), kind = "dispatch", request = request }
		api.intents(table.clone(cx))
	end
	-- The owner runs an ORCH+ palette command in this window (the latest loaded VM's registration).
	function w:palette(id) assert(palette[id], id).run(table.clone(cx)) end
	function w:tick(elapsed)
		now += elapsed or 500
		local token = assert(table.remove(timers, 1)); assert(not token.cancelled); token.callback(table.clone(cx))
	end
	function w:elapse(ms) now += ms; assert(f:tick().ok) end
	function w:now() return now end
	function w:set_wall(t) wall = t end
	function w:pick(choice)
		local callback = assert(pick_callback)
		picker_spec, pick_callback = nil, nil
		callback(choice, nil, table.clone(cx))
	end
	function w:picker() return picker_spec end
	function w:editor() return prompt_spec end
	function w:answer(value) assert(prompt_callback)(value, nil, table.clone(cx)) end
	function w:focused() return picked end
	function w:outcome() return command_result end
	function w:worker() for _, worker in flow(f).workers do if worker.worker_id == id then return worker end end end
	function w:diagnostic()
		local commands, queries, actions = {}, {}, {}
		for index = math.max(1, #events - 7), #events do
			local event = events[index]
			table.insert(commands, { command = event.command, request_id = event.request_id, action_id = event.action_id,
				worker_id = event.worker_id, expected_revision = event.expected_revision })
		end
		for index = math.max(1, #bridge_events - 5), #bridge_events do
			local query = bridge_events[index]
			table.insert(queries, { op = query.op, request_id = query.request_id, action_id = query.action_id,
				target_request_id = query.target_request_id, target_request_serial = query.target_request_serial })
		end
		for action_id, action in f.authority.registry.dispatch.actions do
			table.insert(actions, { action_id = action_id, op = action.request.op, phase = action.phase,
				request_serial = action.request.request_serial, grant_id = if action.claim then action.claim.grant_id else nil })
		end
		local worker = self:worker()
		local session = f.authority.registry.sessions[f.origin.logical_session_id]
		return { now = now, revision = f.authority.registry.revision, selected = selected,
			result = clone(result), driver_result = clone(driver_result), poll_result = clone(poll_result), command_result = clone(command_result),
			control_result = clone(control_result), receipt = clone(receipt), commands = commands, queries = queries, actions = actions,
			control = if session.bridge_control then { op = session.bridge_control.request.op,
				request_id = session.bridge_control.request.request_id, authority_revision = session.bridge_control.request.authority_revision } else nil,
			worker = if worker then { worker_id = worker.worker_id, active_action_id = worker.active_action_id,
				poll_continuation = worker.poll_continuation, due_poll = worker.due_poll, wake_pending_count = worker.wake_pending_count } else nil }
	end
	function w:poll_diagnostic(seq, initial, sent)
		local last = sent[#sent]
		local worker = self:worker()
		local action = if worker and worker.active_action_id then f:action(worker.active_action_id) else nil
		local commands = {}
		for index = math.max(1, #events - 2), #events do table.insert(commands, tostring(events[index].command):sub(1, 24)) end
		local function matched(response) return if response and last and response.request_id == last.request_id then "1" else "0" end
		return string.format("seq=%d init=%d sent=%d bytes=%s cont=%s a=%s/%s r=%s,m%s,live%s d=%s,m%s p=%s,m%s,w%s c=%s last=%s",
			seq, initial, #sent, if last and last.bytes ~= nil then "1" else "0", if worker and worker.poll_continuation then "1" else "0",
			tostring(if action then action.phase else nil):sub(1, 16), tostring(if action then action.request.op else nil):sub(1, 24),
			tostring(if result then result.code else nil):sub(1, 24), matched(result),
			if result and result.action_id and f:action(result.action_id) then "1" else "0",
			tostring(if driver_result then driver_result.code else nil):sub(1, 24), matched(driver_result),
			tostring(if poll_result then poll_result.code else nil):sub(1, 24), matched(poll_result),
			if poll_result and worker and poll_result.worker_id == worker.worker_id then "1" else "0",
			tostring(if control_result then control_result.code else nil):sub(1, 24), table.concat(commands, ","))
	end
	function w:select_worker(worker_id) selected_worker = worker_id end
	function w:move_controller(alias)
		local pane = panes[controller_alias]; panes[controller_alias] = nil
		for index, value in host.panes do if value == controller_alias then host.panes[index] = alias end end
		controller_alias = alias; pane.pane = alias; panes[alias] = pane
	end
	function w:bridge(outcome)
		bridge_outcome = clone(outcome)
		for lane in relay_lanes do render_bridge(lane) end
	end
	function w:add_bridge(pane, lease, tab)
		tab = tab or 1
		if not table.find(session_tabs[7], tab) then table.insert(session_tabs[7], tab) end
		panes[pane] = { pane = pane, block = "spawn.dispatch", tab = tab }
		table.insert(host.panes, pane); leases[pane] = lease
	end
	function w:lease(pane, lease) leases[pane] = lease end
	function w:moved_earlier(pane) moved[pane] = true end -- An earlier build moved it: unreadable now.
	function w:bridge_panes() return bridge_panes end
	function w:bridge_placements() return bridge_placements end
	function w:bridges_closed() return bridges_closed end
	function w:tab_names() return tab_names end
	function w:moves() local n = 0; for _ in moved do n += 1 end; return n end
	-- SPAWN's registry has no record of the status target (never staged, or compacted).
	function w:bridge_missing(flag) bridge_missing = flag end
	function w:bridge_events() return bridge_events end
	function w:bridge_routes() return bridge_routes end
	function w:control_authorizations() return control_authorizations end
	function w:peer_changed() peer_revision += 1 end
	function w:peer_revision() return peer_revision end
	function w:peer_progress() return peer_progress() end
	function w:after_control_response(callback) after_control_response = callback end
	function w:peer_state_reads() return peer_state_reads end
	function w:bridge_state(pane) return clone(bridge_states[pane]) end
	function w:result_events() return result_events end
	function w:display_requests() return display_requests end
	function w:owner_answer(state)
		owner_answer = state
		if state == "retired" then retired_owner_generation = f.origin.owner_generation end
	end
	function w:recovery_steps() return recovery_steps end
	function w:ran_actions() return ran_actions end
	function w:usage(server) usage = server end
	function w:usage_placements() return usage_placements end
	function w:relay_lanes() return relay_lanes end
	function w:relay_metadata()
		local span = assert(find(tree(), "orchplus-spawn-relay")).p.spans[1]
		return runtime.json.decode(if type(span) == "string" then span else span.t)
	end
	function w:relay_acks() return relay_acks end
	function w:relay_response(receipt, request) return shared.codec.decode_dispatch_response(relay_responses[receipt.id], request) end
	function w:release_requests() return clone(release_requests) end
	function w:release_acks() return clone(release_acks) end
	function w:release_proofs() return clone(relay_releases) end
	function w:rebind_requests() return clone(rebind_requests) end
	function w:confirm_release(lane) confirm_release(lane) end
	function w:confirm_rebind(lane) confirm_rebind(lane) end
	function w:publish_peer(lane)
		-- Adversarial observation: an old bind ID is not a fresh causal receipt.
		local retained = assert(relay_lanes[lane])
		retained.bind_id = retained.bind_id or retained.previous_bind_id
		render_bridge(lane)
	end
	function w:publish_response(lane, bytes) bridge_bytes[lane] = bytes; render_bridge(lane) end
	function w:change_peer_boot()
		-- Model a validated host_boot announcement, not permission from an arbitrary boot flip.
		peer_boot ..= "-new"
		for lane_id, lane in relay_lanes do
			if lane.peer_boot and lane.peer_boot ~= peer_boot then
				lane.previous_bind_id, lane.previous_boot = lane.bind_id, lane.peer_boot
				lane.peer_boot, lane.bind_id, lane.sent.bind, lane.messages = nil, nil, nil, {}
				relay_frames[lane_id] = {}
				lane.held, lane.error, relay_held, relay_error = true, "peer_reloaded", true, "peer_reloaded"
			end
		end
	end
	-- A `usage.capacity` pane an earlier incarnation left (tab 1 = beside the controller).
	function w:add_usage(pane, tab) panes[pane] = { pane = pane, block = "usage.capacity", tab = tab }; table.insert(host.panes, pane) end
	function w:reload()
		table.clear(timers) -- A real VM reload drops its callbacks before loading the new entry.
		table.clear(local_modules)
		api = module(); self.api = api
	end
	w:palette("continue_controller")
	local continuation_choice
	for _, choice in assert(w:picker()).items do
		if choice.continue_controller then continuation_choice = choice; break end
	end
	w:pick(assert(continuation_choice, "native continuation must offer explicit executor-retirement attestation"))
	assert(#events == 1 and events[1].command == "continue_controller", "fixture obtains its origin from an explicit native window continuation")
	f.origin = clone(events[1].origin)
	assert(w:outcome().ok, "native continuation must establish this incarnation's current command origin")
	-- Observe the exact bootstrap continuation ACK before Pause replaces that slot.
	-- Idle-only fixtures also finish this real owner read before measuring idle behavior.
	if options and options.idle_baseline then
		assert(options.no_worker and options.sweep_enabled == false, "idle baseline must explicitly exclude workers and housekeeping")
		assert(f:apply("policy", { policy = { sweep_enabled = false } }).ok)
	end
	if options and (options.no_admission or options.idle_baseline) then w:tick() end
	table.clear(events)
	w:click("pause")
	assert(w:outcome().ok, "the current native pause control must use the continued origin")
	local policy = { poll_ms = 5000 }
	if options and options.sweep_enabled ~= nil then policy.sweep_enabled = options.sweep_enabled end
	assert(f:apply("policy", { policy = policy }).ok)
	initializing = false
	if options and options.no_admission then table.clear(events); return w end
	assert(f:control("admit_session").ok, "worker setup requires the exact window origin's current admission receipt")
	local admitted_session = f.authority.registry.sessions[f.origin.logical_session_id]
	peer_session = { admission_seq = admitted_session.admission_seq, control = { phase = "open",
		generation_floor = admitted_session.generation_floor, request_floor = admitted_session.request_floor,
		next_request_serial = admitted_session.next_request_serial, last_authority_revision = admitted_session.last_authority_revision,
		binding = clone(f.origin) } }
	w:click("resume")
	table.clear(events)
	if not (options and options.no_worker) then id = f:accepted(false); w.id = id end
	if options and options.idle_baseline then
		-- Like the recovery cases, expose an actual current mock peer before
		-- expecting a read: a bound lane without its current frame cannot send.
		w:bridge({ placeholder = true }); w:owner_answer("current")
		local observed = false
		for _ = 1, 12 do
			w:tick()
			for _, query in bridge_events do if query.op == "owner_status" then observed = true end end
			local last = wake_events[#wake_events]
			if observed and recovery_steps and #recovery_steps.steps == 0 and last and last.state == "idle" then break end
		end
		local last = wake_events[#wake_events]
		assert(observed and recovery_steps and #recovery_steps.steps == 0 and last and last.state == "idle",
			"bootstrap owner_status must settle through its actual peer response before an idle baseline: " .. runtime.json.encode(w:diagnostic()))
		-- Complete any wait child used by that read, at a valid elapsed age. The
		-- following assertions measure new children after bootstrap, not its history.
		w:tick(2000)
		local before = #processes
		if before > 0 then processes[before].callback({ status = 0, stdout = "", stderr = "", timed_out = false }, table.clone(cx)) end
		assert(#processes == before and wake_events[#wake_events].state == "idle", "settled bootstrap must not restart a wait child")
		w.idle_process_floor = #processes -- Retain the actual bootstrap trace; count later work separately.
	end
	return w
end
-- A refused background reconciliation must not wedge a later approved close.
-- Only a positively committed NEW close can supersede that refusal.
if section == nil or section == "close_refusal" then
	for _, scenario in { { settled = false }, { settled = true }, { settled = true, reject_close = true } } do
		local refused_control, refused_close = false, false
		local w = window_fixture({ no_worker = true,
			before_control = function(f, input)
				if input.operation == "reconcile_session" and not refused_control then
					refused_control = true
					assert(f:apply("pause").ok)
				end
			end,
			before_authority = function(f, input)
				if scenario.reject_close and input.kind == "begin_close" and not refused_close then
					refused_close = true
					assert(f:apply("resume").ok)
				end
			end })
		local f, sid = w.f, w.f.origin.logical_session_id
		assert(f:apply("policy", { policy = { sweep_enabled = false } }).ok)
		w:bridge({ placeholder = true })
		w:click("bridge_reconcile")
		check(w:diagnostic().control_result.code == "stale_revision"
			and f.authority.registry.sessions[sid].bridge_control == nil,
			"the real intervening commit refuses reconciliation before any immutable control exists")
		local function reconciliations()
			local count = 0
			for _, event in w.events do
				if event.command == "bridge_control" and event.operation == "reconcile_session" then count += 1 end
			end
			return count
		end
		if scenario.settled then
			for _ = 1, 4 do w:tick() end
			check(reconciliations() == 1, "a background refusal is not retried automatically")
		end
		w:click("close_session"); w:pick({ confirm = true })
		if scenario.reject_close then
			check(refused_close and f.authority.registry.sessions[sid].phase == "open",
				"an intervening commit refuses the new close without changing session lifecycle")
			for _ = 1, 4 do w:tick() end
			check(reconciliations() == 1 and f.authority.registry.sessions[sid].controller ~= nil,
				"a refused close cannot clear the earlier hold, replay reconciliation or release the owner")
			w:click("close_session"); w:pick({ confirm = true })
		end
		check(f.authority.registry.sessions[sid].phase == "closing",
			"a separate current explicit close starts its durable lifecycle")
		for _ = 1, 24 do
			w:tick()
			if f.authority.registry.sessions[sid] == nil then break end
		end
		check(f.authority.registry.sessions[sid] == nil and reconciliations() == 1,
			"the approved close releases its owner and confirms peer closure without replaying the refused reconciliation")
	end
end

if section == nil or section == "epoch_window" then
	local w = window_fixture()
	local original = w.f.origin.window_epoch
	check(w.api.native_observation(w.cx, 9001, w:worker()) == "idle", "original window can observe its exact issued worker")
	w:reload(); w:click("pause")
	check(#w.events == 0, "replacement VM cannot issue ordinary commands before explicit continuation")
	check(w.api.native_observation(w.cx, 9001, w:worker()) == "unknown", "new VM cannot adopt old worker aliases by a clock collision")
	w:palette("continue_controller"); w:pick({ continue_controller = true })
	local current = w.events[#w.events].origin.window_epoch
	check(current ~= original and w:outcome().ok, "explicit continuation uses a fresh VM identity even when both clocks repeat")
	check(w.api.native_observation(w.cx, 9001, w:worker()) == "unknown", "controller continuation alone never adopts the worker's old pane alias")
end
if section == nil or section == "epoch_host" then
	local f = shared.fixture(); local id = f:accepted(false)
	local fake = table.clone(runtime)
	fake.now = function() return 1000 end
	fake.kv = f.memory
	fake.timer = function() return { cancel = function() end } end
	fake.on = function() end
	fake.block = { define = function() end }
	local fixed_os = table.clone(os); fixed_os.time = function() return 1700000000 end
	local function host_epoch()
		local module = assert(loadstring(runtime.fs.read(root .. "/host.luau"), "health-host-epoch"))
		setfenv(module, setmetatable({ tern = fake, require = shared.load, os = fixed_os }, { __index = environment }))
		f.authority = module().new_authority(f.memory)
		assert(f.authority:load().ok)
		assert(f:tick().ok)
		return f.authority.registry.dispatch.workers[id].workflow.started.epoch
	end
	local previous = host_epoch()
	check(host_epoch() ~= previous, "fresh host VM stamps a distinct health epoch even when both clocks repeat")
end
if section == nil or section == "native" then
	local w = window_fixture()
	for _, pair in { { "working", "working" }, { "waiting_input", "waiting-input" }, { "idle", "idle" }, { "exited", "exited" } } do
		w.agents[1].state = pair[1]
		local native = w.api.native_observation(w.cx, 9001, w:worker())
		check(native == pair[2], "native lifecycle maps " .. pair[1])
	end
	w.agents[1].state = "idle"; w.agents[1].delivery_error = "Permission requires owner action"
	local native, problem = w.api.native_observation(w.cx, 9001, w:worker())
	check(native == "idle" and problem == w.agents[1].delivery_error, "delivery hold is not discarded when native agent is idle")
	w.agents[1].pane = 123
	check(w.api.native_observation(w.cx, 9001, w:worker()) == "unknown", "unsupported terminal is not invented idle/sendable")
	w.panes[9002].exited = 0
	check(w.api.native_observation(w.cx, 9001, w:worker()) == "exited", "generic terminal native exit metadata is retained")
	w.panes[9002] = nil
	check(w.api.native_observation(w.cx, 9001, w:worker()) == "unknown", "missing pane is not exit proof")
	w.panes[9002] = { pane = 9002, tab = 2 }
	check(w.api.native_observation(w.cx, 9001, w:worker()) == "unknown", "worker moved to another session cannot be observed as this worker")
	w:click("open_worker", { worker_id = w.id })
	check(w:focused() == nil, "explicit relevant-pane action still refuses cross-session focus")
	w.panes[9002].tab = 1
	w:click("open_worker", { worker_id = w.id })
	check(w:focused() == 9002, "explicit owner open uses exact relevant pane without terminal input")
	local old = w:worker(); old.pane_binding.window_epoch = "retired-window"
	check(w.api.native_observation(w.cx, 9001, old) == "unknown", "VM reload does not authenticate old numeric pane aliases")
end
-- Initial enrollment must not inherit a multi-minute progress-report interval.
if section == nil or section == "startup_polling" then
	local w = window_fixture({ no_worker = true })
	assert(w.f:apply("policy", { policy = { poll_ms = 300000 } }).ok)
	local id = w.f:launched(true)
	local function active()
		for _, worker in flow(w.f).workers do
			if worker.worker_id == id then return worker.active_action_id end
		end
	end
	local function poll_count()
		local count = 0
		for _, event in w.events do if event.command == "poll" and event.worker_id == id then count += 1 end end
		return count
	end
	w:bridge({ placeholder = true })
	w:owner_answer("current")
	for _ = 1, 12 do
		w.api.schedule(w.cx)
		if active() then break end
		w:tick(0)
	end
	local first = assert(active(), runtime.json.encode(w:diagnostic()))
	check(w.f:action(first).request.op == "mailbox_read", "startup observes its original report lane")
	assert(w.f:finish(first, "missing", {}).ok)
	w:tick(0)
	w:elapse(2000)
	w.api.schedule(w.cx)
	local second = assert(active())
	check(second ~= first and w.f:action(second).request.selector.slot == 1,
		"a later enrollment report is sought after two seconds without reissuing the original read")
	assert(w.f:finish(second, "missing", {}).ok)
	local last_read_at = w:now()
	w:tick(0)
	check(w.f.authority.registry.dispatch.workers[id].accepted_seq == 0,
		"missing startup reports never fabricate enrollment")
	w:elapse(120000)
	local before = poll_count()
	w.api.schedule(w.cx)
	check(poll_count() == before, "fast discovery expires instead of polling an unsigned-in pane forever")
	w:elapse(last_read_at + 300000 - w:now())
	for _ = 1, 12 do
		w.api.schedule(w.cx)
		if poll_count() > before then break end
		w:tick(0)
	end
	check(poll_count() == before + 1 and active() ~= nil,
		"an idle scheduling turn cannot postpone the next due report read by another full interval")
end
-- Real launch results compose the existing coordinator, never a second native conversation.
if section == nil or section == "native" then
	for _, refused in { false, true } do
		local launches = {}
		local w = window_fixture({ no_worker = true, commit_results = true, compose_refused = refused,
			bridge_handler = function(request) return shared.frame(request, "pending") end,
			startup_handler = function(f, request)
				assert(request.op == "launch" and request.presentation == "coordinator_adjacent")
				table.insert(launches, clone(request))
				local action = assert(f:action(request.action_id))
				assert(f:apply("spawn_claimed", { action_id = request.action_id, grant_id = action.claim.grant_id,
					spawn_namespace = "fixture-spawn", claim_nonce = "composition-native-claim" }).ok)
				return shared.frame(request, "awaiting_acceptance", f:peer_payload(action, "awaiting_acceptance", {
					pane_binding = { pane_id = "9002", window_key = f.origin.window_key, window_epoch = f.origin.window_epoch,
						native_session_id = f.origin.native_session_id, window_host_id = f.origin.window_host_id },
				}))
			end })
		local f = w.f
		f:catalog(0)
		local queued = f:apply("queue", { record_id = "native", record_revision = 0, catalog_revision = 0,
			prompt = "Coordinate the explicit fixture project.", cwd = "/fixture", placement = "split",
			coordinator = true, presentation = "coordinator_adjacent" })
		assert(queued.ok, queued.message)
		assert(f:finish(queued.action_id, "provisioned", { handle = "mailbox-compose", binding_digest = string.rep("a", 64),
			capabilities = runtime.json.array({ "report-files-v1", "native-ask-v1", "coordinator-control-v1", "project-start-v1" }) }).ok)
		local worker = f.authority.registry.dispatch.workers[queued.worker_id]
		local launch_id = worker.launch_action_id
		w:native_tab(9002, 3) -- A genuine conversation created in another tab of this same native session.
		w:bridge({ placeholder = true })
		for _ = 1, 24 do w:tick(); if #w:composition_moves() > 0 then break end end
		local move = w:composition_moves()[1]
		check(#launches == 1 and #w:composition_moves() == 1 and move.pane == 9002 and move.target == 9001
			and move.side == "left" and move.options.focus == true, "the actual launch result moves its exact existing coordinator left of the ORCH panel")
		if refused then
			check(w.panes[9002].tab == 3 and #w:composition_resizes() == 0 and #w:result_events() == 0
				and f:action(launch_id).phase == "uncertain",
				"failed native composition retains the real launch as uncertain without publishing acceptance or resizing")
		else
			local resize = w:composition_resizes()[1]
			worker = f.authority.registry.dispatch.workers[queued.worker_id]
			check(w.panes[9002].tab == w.panes[9001].tab and #w:composition_resizes() == 1 and resize.pane == 9001
				and resize.side == "left" and resize.delta == -20 and w:focused() == 9002,
				"the composed coordinator is focused and the existing right-side panel is narrowed once")
			check(worker.pane_binding and worker.pane_binding.pane_id == "9002" and worker.phase == "awaiting_acceptance",
				"successful composition commits the genuine binding but does not fabricate ACCEPTED")
			local before, effects = runtime.json.encode(f.authority.registry), #w:bridge_events()
			w.panes[9002].title = "Reviewing the launch contract"
			w.panes[9004].tab = 2; w.panes[9004].title = "Different session private title"
			w.hooks.title({ pane = 9002 }, table.clone(w.cx))
			local observed = w:observed_panes()
			check(observed and #observed.panes == 1 and observed.panes[1].pane == 9002
				and observed.panes[1].worker_id == queued.worker_id and observed.panes[1].title == w.panes[9002].title,
				"the real native title event refreshes only this session's exact managed conversation")
			local normal = w:visible_text()
			check(normal:find("Reviewing the launch contract", 1, true) ~= nil
				and normal:find("Different session private title", 1, true) == nil
				and normal:find("Health, owner inbox and durable threads", 1, true) == nil,
				"normal conversation rows follow live titles without exposing foreign-session or Advanced diagnostics")
			w.panes[9002].title = string.rep("é", 40)
			w.hooks.title({ pane = 9002 }, table.clone(w.cx))
			local title = w:observed_panes().panes[1].title
			check(#title <= 64 and utf8.len(title) ~= nil and title:sub(-3) == "…",
				"native title-event truncation stays bounded and preserves UTF-8")
			check(runtime.json.encode(f.authority.registry) == before and #w:bridge_events() == effects,
				"title changes are display-only: no durable decision, launch, send or replacement identity")
			w.panes[9002].program = "sudo"; w.panes[9002].title = "sudo"
			w.hooks.title({ pane = 9002 }, table.clone(w.cx))
			check(w:observed_panes().panes[1].title == "", "a wrapper executable is not presented as an intentional conversation name")
			w.panes[9002].title = "User chosen pane"
			w.hooks.title({ pane = 9002 }, table.clone(w.cx))
			check(w:observed_panes().panes[1].title == "User chosen pane", "an actual user pane name remains visible over a wrapper executable")
			w.agents[1].state = "working"; w.panes[9002].exited = 2
			w.hooks.title({ pane = 9002 }, table.clone(w.cx))
			observed = w:observed_panes().panes[1]
			check(observed.state == "exited" and observed.exit_code == 2, "positive bound-pane exit wins over a stale working agent entry")
			normal = w:visible_text()
			check(normal:find("Agent pane ended (exit 2)", 1, true) ~= nil and normal:find("Check agent status", 1, true) ~= nil
				and normal:find("Waiting for the agent to join", 1, true) == nil
				and normal:find("The pane opened, but the agent has not joined yet.", 1, true) == nil
				and normal:find("Agent startup is pending.", 1, true) == nil,
				"known exited startup is actionable instead of reporting that the agent is still joining")
			w:click("inspect_worker", { worker_id = queued.worker_id })
			worker = f.authority.registry.dispatch.workers[queued.worker_id]
			check(worker.workflow.health.latest_exit ~= nil and worker.phase == "awaiting_acceptance"
				and worker.stopped == nil and worker.finish == nil, "positive exit is retained health evidence, not fabricated acceptance or lifecycle retirement")
			w.panes[9002].exited = 0
			w.hooks.title({ pane = 9002 }, table.clone(w.cx))
			normal = w:visible_text()
			check(normal:find("Agent pane ended (exit 0)", 1, true) ~= nil and normal:find("Agent task completed", 1, true) == nil,
				"zero native exit describes the pane outcome without declaring the user's task complete")
			w.panes[9002] = nil
			for _ = 1, 4 do w:tick() end
			check(f.authority.registry.dispatch.workers[queued.worker_id].workflow.health.latest_exit ~= nil
				and f.authority.registry.dispatch.workers[queued.worker_id].stopped == nil and #launches == 1,
				"later pane absence preserves the retained exit and startup outcome without replay or invented retirement")
		end
		for _ = 1, 4 do w:tick() end
		check(#launches == 1 and #w:composition_moves() == 1 and #w:bridge_placements() == 0 and #w:usage_placements() == 0,
			"subsequent observations never replay the coordinator launch or composition and never create transport views")
	end
end
if section == nil or section == "native" then
	for _, stale in { false, true } do
		local w = window_fixture({ no_worker = true })
		local project_id = w.f:project("Attach without starting work", false)
		w:click("attach_conversation", { orch_project_id = project_id })
		local selected
		for _, choice in w:picker().items do if choice.pane == 9004 then selected = choice end end
		assert(selected, "the busy native conversation is attachable without sending")
		w:pick(selected); w:pick({ project_id = project_id })
		local requested = w:decision_requests()[1]
		check(requested and requested.source_nonce == w.f.origin.alias_nonce and requested.event.command == "associate_conversation"
			and requested.event.orch_project_id == project_id and requested.event.pane_binding.pane_id == "9004"
			and requested.event.active == true,
			"native attachment requests an exact project/pane/current-busy-state decision context from the host")
		local context = dispatch.decision_context(w.f.authority.registry, requested.event)
		assert(context, "current association context must be available")
		if stale then assert(w.f:apply("pause").ok) end
		for _ = 1, 3 do w:tick() end
		local sent
		for _, event in w.events do if event.command == "associate_conversation" then sent = event end end
		local project = w.f.authority.registry.dispatch.projects[project_id]
		if stale then
			check(next(project.associations or {}) == nil and not project.started,
				"an intervening policy decision invalidates the captured attachment instead of refreshing its authority")
		else
			check(sent and sent.decision_context == context and sent.expected_revision == requested.event.expected_revision
				and next(project.associations or {}) ~= nil and not project.started,
				"the exact host-provided association context commits attachment only; busy never STARTs work")
		end
		check(next(w.f.authority.registry.dispatch.workers) == nil and #w:bridge_events() == 0 and #w.managed_opened == 0,
			"association alone preserves the native context without launching, enrolling, sending or inventing a worker")
	end
end
if section == nil or section == "controls" then
	local w = window_fixture()
	w:click("pause")
	check(flow(w.f).policy.paused, "actual pause button invokes concrete admitted reducer command")
	w:click("resume")
	check(not flow(w.f).policy.paused, "actual resume button preserves session policy")
	local displayed = flow(w.f).policy
	w:click("policy", { policy = { poll_ms = 300000 }, expected_sha256 = shared.quota.digest(displayed) })
	check(flow(w.f).policy.poll_ms == 300000, "five-minute report polling saves through the instance writer")
	local policy_before = runtime.json.encode(flow(w.f).policy)
	w:click("policy", { policy = { poll_ms = 0 }, expected_sha256 = shared.quota.digest(flow(w.f).policy) })
	check(runtime.json.encode(flow(w.f).policy) == policy_before, "invalid polling cannot overwrite instance policy")
	local displayed = flow(w.f).policy
	w:click("policy", { policy = { auto_rollover = true, quota_routing = true }, expected_sha256 = shared.quota.digest(displayed) })
	check(flow(w.f).policy.auto_rollover and flow(w.f).policy.quota_routing and flow(w.f).policy.poll_ms == 300000, "instance save preserves unrelated report cadence")
	w:click("policy", { policy = { auto_rollover = false }, expected_sha256 = shared.quota.digest(displayed) })
	check(flow(w.f).policy.auto_rollover, "draft displayed before a newer save cannot overwrite it")
	w:click("pause")
	check(flow(w.f).policy.paused and flow(w.f).policy.poll_ms == 300000, "pause responds immediately independently of report cadence")
	w:click("resume")
	local previous_seq = 0
	for _, event in w.events do
		if event.command ~= "claim" and event.command ~= "result" and event.command ~= "lost" then
			check(type(event.command_seq) == "number" and event.command_seq > previous_seq, "real owner callers emit strictly increasing intent sequences")
			previous_seq = event.command_seq
		end
	end
	local options = { { id = "safe", label = "Safe option" } }
	for index = 2, 16 do table.insert(options, { id = "choice-" .. tostring(index), label = string.rep("Detailed option ", 60) }) end
	assert(w.f:apply("intake", { worker_id = w.id, bytes = w.f:report(w.id, 2, "ASK", { question = string.rep("Full question evidence. ", 400), options = runtime.json.array(options) }) }).ok)
	local gate
	for _, candidate in flow(w.f).gates do if candidate.kind == "owner_question" then gate = candidate end end
	assert(gate)
	local fields = { gate_id = gate.id, gate_revision = gate.revision, worker_id = w.id }
	w:click("answer", fields)
	local picker = assert(w:picker())
	check(picker.placeholder == gate.question, "native answer picker presents the complete exact question, including content beyond one control frame")
	local exact_choices = #picker.items == #gate.options
	for index, option in gate.options do
		local item = picker.items[index]
		exact_choices = exact_choices and item ~= nil and item.choice_id == option.id and item.label == option.label
	end
	check(exact_choices, "native answer picker preserves every human-facing choice label rather than substituting opaque IDs")
	w:pick({ choice_id = "safe", label = "Safe option" }); w:answer("Proceed with the explicit safe option")
	local answered
	for _, candidate in flow(w.f).gates do if candidate.id == gate.id then answered = candidate end end
	check(answered.answer and answered.answer.choice_id == "safe" and answered.phase == "answered", "actual answer route commits one exact recipient-bound decision before publication")
	local preserved
	for _, candidate in flow(w.f).gates do if candidate.id == gate.id then preserved = candidate end end
	check(preserved.answer and preserved.answer.choice_id == "safe" and preserved.phase == "answered",
		"independent Config cancellation preserves the pending immutable gate decision")
	local ack = w.f:apply("poll", { worker_id = w.id })
	assert(w.f:finish(ack.action_id, "published", {}).ok)
	local publication = w.f:apply("poll", { worker_id = w.id })
	check(publication.ok and w.f:action(publication.action_id).request.op == "mailbox_publish_reply", "answer drains through the existing immutable mailbox path")
	for _, candidate in flow(w.f).gates do if candidate.id == gate.id then answered = candidate end end
	check(answered.delivery ~= nil and not answered.delivery.acknowledged, "publication intent is not worker acknowledgement")
	local count = #w.events
	w:click("answer", fields)
	check(#w.events == count, "answered/stale question cannot prompt another owner decision")
	local cancel_fields = { gate_id = answered.id, gate_revision = answered.revision, worker_id = w.id }
	w:click("cancel_gate", cancel_fields); w:pick({ cancel_gate = true })
	local cancelled
	for _, candidate in flow(w.f).gates do if candidate.id == gate.id then cancelled = candidate end end
	check(cancelled.phase == "cancelled" and cancelled.answer ~= nil, "gate cancellation retains immutable answer evidence")
	w:click("recheck_gate", { gate_id = cancelled.id, gate_revision = cancelled.revision, worker_id = w.id })
	local seen = false
	for _, event in w.events do if event.command == "recheck_gate" then seen = true end end
	check(seen, "recheck routes only an explicit gate command and native observation, never login or prompt input")
	for _, boundary in { "picker", "prompt" } do
		local owner = window_fixture()
		owner:select_worker(owner.id)
		owner.f.target_pane = "9004"
		local other = owner.f:accepted(false)
		assert(owner.f:apply("intake", { worker_id = owner.id, bytes = owner.f:report(owner.id, 2, "ASK", {
			question = "Approve this exact recipient?", options = runtime.json.array({ { id = "yes", label = "Yes" } }),
		}) }).ok)
		local pending
		for _, candidate in flow(owner.f).gates do if candidate.worker_id == owner.id and candidate.kind == "owner_question" then pending = candidate end end
		assert(pending)
		local target = { gate_id = pending.id, gate_revision = pending.revision, worker_id = owner.id }
		local captured = owner.f.authority.registry.revision
		owner:click("answer", target)
		if boundary == "prompt" then owner:pick({ choice_id = "yes", label = "Yes" }) end
		assert(observed(owner.f, other, "working").ok)
		check(owner.f.authority.registry.revision > captured, boundary .. ": unrelated worker observation commits while the owner dialog is open")
		if boundary == "picker" then owner:pick({ choice_id = "yes", label = "Yes" }) end
		owner:answer("This answer belongs to the captured question")
		local submitted = owner.events[#owner.events]
		local outcome = owner:outcome()
		local current
		for _, candidate in flow(owner.f).gates do if candidate.id == pending.id then current = candidate end end
		check(submitted.command == "answer" and submitted.expected_revision == captured
			and submitted.gate_id == pending.id and submitted.gate_revision == pending.revision
			and submitted.decision_context == pending.decision_context
			and outcome.request_id == submitted.request_id and outcome.command == "answer"
			and outcome.ok and outcome.code == "gate_answered",
			boundary .. ": unrelated bookkeeping preserves the captured subject decision and exact correlated receipt")
		check(current.phase == "answered" and current.answer.choice_id == "yes"
			and current.answer.answer == "This answer belongs to the captured question",
			boundary .. ": the original explicit decision commits without a fresh dialog or rebased request")
		if boundary == "prompt" then
			local committed, committed_writes = runtime.json.encode(owner.f.authority.registry), owner.f.memory.writes
			owner:answer("Delayed duplicate callback")
			check(owner.f.memory.writes == committed_writes and runtime.json.encode(owner.f.authority.registry) == committed,
				"a delayed callback cannot replace the committed owner decision or queue another effect")
		end
	end
	for _, boundary in { "picker", "prompt" } do
		local owner = window_fixture()
		assert(owner.f:apply("intake", { worker_id = owner.id, bytes = owner.f:report(owner.id, 2, "ASK", {
			question = "Approve this exact revision?", options = runtime.json.array({ { id = "yes", label = "Yes" } }),
		}) }).ok)
		local pending
		for _, candidate in flow(owner.f).gates do if candidate.worker_id == owner.id and candidate.kind == "owner_question" then pending = candidate end end
		assert(pending)
		local target = { gate_id = pending.id, gate_revision = pending.revision, worker_id = owner.id }
		owner:click("answer", target)
		if boundary == "prompt" then owner:pick({ choice_id = "yes", label = "Yes" }) end
		local cancelled = owner.f:apply("cancel_gate", { gate_id = pending.id, gate_revision = pending.revision })
		check(cancelled.ok and cancelled.code == "gate_cancelled" and owner.f.authority.registry.dispatch.gates[pending.id] == nil,
			boundary .. ": cancellation consumes the unreferenced question while its old dialog is open")
		local before, writes, events = runtime.json.encode(owner.f.authority.registry), owner.f.memory.writes, #owner.events
		if boundary == "picker" then owner:pick({ choice_id = "yes", label = "Yes" })
		else owner:answer("Stale answer must never be submitted") end
		check(#owner.events == events and owner.f.memory.writes == writes
			and runtime.json.encode(owner.f.authority.registry) == before and owner.f.authority.registry.dispatch.gates[pending.id] == nil,
			boundary .. ": a stale same-question callback refuses locally without an answer, effect or authority write")
	end
end
-- Admission may complete as a host no-op: no current wire control will ever appear for that command.
	local function controls(w)
		local out = {}
		for _, event in w.events do if event.command == "bridge_control" then table.insert(out, event) end end
		return out
	end
if section == nil or section == "driver_admission_noop" then
	local w = window_fixture({ no_worker = true, hold_control_receipt = true })
	w:click("bridge_admit")
	check(#controls(w) == 1 and w.f.authority.registry.sessions[w.f.origin.logical_session_id].bridge_control == nil,
		"already-admitted native control commits no new immutable admission request")
	w:click("pause") -- A real unrelated receipt is not evidence for the held admission command.
	w:tick(); w:tick()
	check(#controls(w) == 1 and #w:bridge_events() == 0,
		"an unrelated current receipt neither clears admission creation nor resends admission")
	local receipt = w:release_control_receipt()
	check(receipt.ok and receipt.code == "already_admitted", "fixture retains the exact successful native no-op receipt")
	w:tick()
	w:elapse(4999); w.api.schedule(w.cx)
	check(#controls(w) == 1, "a settled admission no-op preserves the ordinary five-second reconciliation interval")
	w:elapse(1); w.api.schedule(w.cx)
	check(#controls(w) == 1 and w.f.authority.registry.sessions[w.f.origin.logical_session_id].bridge_control == nil,
		"an unavailable native receiver cannot occupy the automatic control lane")
	w:bridge({ placeholder = true })
	w.api.schedule(w.cx)
	local commands = controls(w)
	check(#commands == 2 and commands[2].operation == "reconcile_session" and #w:bridge_events() == 0,
		"the exact no-op receipt releases creation for ordinary current reconciliation, never admission replay")
end
if section == nil or section == "driver_admission_refused" then

	local raced = false
	local refused = window_fixture({ no_worker = true, before_control = function(f)
		if not raced then
			raced = true
			local changed = f:apply("pause")
			assert(changed.ok, changed.message) -- Independent authority change after the window captured its fence.
		end
	end })
	refused:click("bridge_admit")
	check(refused:outcome().ok == false and refused.f.authority.registry.sessions[refused.f.origin.logical_session_id].bridge_control == nil,
		"an intervening native authority change refuses the captured control without persisting a request")
	refused:tick()
	refused:elapse(10000); refused.api.schedule(refused.cx)
	check(#controls(refused) == 1 and #refused:bridge_events() == 0 and refused:outcome().ok == false,
		"a definite current refusal remains visible and does not silently retry with a refreshed fence")
	refused:click("bridge_reconcile")
	local current = refused.f.authority.registry.sessions[refused.f.origin.logical_session_id].bridge_control
	check(#controls(refused) == 2 and current ~= nil and current.request.op == "reconcile_session",
		"an explicit existing reconcile action replaces the refusal hold with its own fresh captured command")
end

-- Drive the actual window timer against SPAWN's single response surface. The first status
-- answer exists but is replaced before the next window read, exactly as a late authorization
-- completion or another bridge query can replace it in the native host.
if section == nil or table.find({ "driver_retry_original", "driver_retry_unrelated", "driver_retry_absent",
	"driver_deadline_absent", "driver_deadline_unrelated", "driver_missing", "driver_suspension", "driver_fence_origin", "driver_fence_claim" }, section) then
	local function retry_fixture(replacement)
		local probe = { effects = {}, queries = {}, recover = false }
		local w
		w = window_fixture({ commit_results = true, bridge_handler = function(input, event, at)
			if input.op == "mailbox_read" then
				table.insert(probe.effects, { request = clone(input), bytes = event.value, at = at })
				probe.request = clone(input)
				local frames = assert(shared.codec.frame(w.f:report(w.id, 2, "HEARTBEAT", { state = "idle" }),
					"report", w.f.authority.registry.dispatch.workers[w.id]))
				probe.payload = runtime.json.decode(assert(shared.codec.project_page(frames.manifest, input.selector)))
				probe.outcome = peer_body(input, "read", probe.payload)
				return shared.frame(input, "read", probe.payload)
			end
			assert(input.op == "status")
			table.insert(probe.queries, { request = clone(input), bytes = event.value, at = at })
			local found = shared.frame(input, "found", { outcome = probe.outcome })
			assert(shared.codec.decode_dispatch_response(found, input), "fresh status must be correctly correlated")
			if probe.recover then return found end
			if replacement == "missing" then return shared.frame(input, "missing") end
			if replacement == "original" then return shared.frame(probe.request, "read", probe.payload) end
			if replacement == "unrelated" then
				local other = clone(input); other.request_id ..= "-other"; other.action_id ..= "-other"
				return shared.frame(other, "found", { outcome = probe.outcome })
			end
			return nil -- A readable response node without any conclusive response bytes.
		end })
		w:bridge({ placeholder = true })
		local read = w.f:apply("poll", { worker_id = w.id }); assert(read.ok, read.message)
		assert(w.f:action(read.action_id).request.op == "mailbox_read")
		assert(w.f:finish(read.action_id, "full", { resource = "capacity_admission", current = 1, limit = 1,
			retryable = true, effect_started = false }).code == "backpressure")
		local retry = w.f:apply("retry", { action_id = read.action_id }); assert(retry.ok, retry.message)
		probe.action_id = retry.action_id
		assert(w.f:action(probe.action_id).retry_count == 1)
		w:click("execute", { action_id = probe.action_id })
		for _ = 1, 8 do w:tick(); if #probe.queries > 0 then break end end
		assert(#probe.effects == 1 and #probe.queries == 1, "retried read must send once and require one initial status")
		probe.claim = clone(w.f:action(probe.action_id).claim)
		probe.request_bytes = w.f:action(probe.action_id).request_bytes
		return w, probe
	end
	for _, replacement in { "original", "unrelated", "absent" } do
		if section == nil or section == "driver_retry_" .. replacement then
		local w, probe = retry_fixture(replacement)
		local first = probe.queries[1]
		w:tick()
		check(#probe.queries == 1 and #w:result_events() == 0 and w.f:action(probe.action_id).phase == "claimed",
			replacement .. ": replacement cannot satisfy fresh retry status or trigger a hot replay")
		probe.recover = true
		w:tick()
		assert(#probe.queries == 2, replacement .. ": lost status must be re-observed at the first existing retry delay: " .. runtime.json.encode(w:diagnostic()))
		local replay = probe.queries[2]
		check(replay.at - first.at == 1000 and replay.bytes == first.bytes,
			replacement .. ": outstanding status retransmits byte-for-byte after 1000ms")
		w:tick()
		check(w.f:action(probe.action_id) == nil and #w:result_events() == 1,
			replacement .. ": fresh found status commits the real read without declaring it lost")
		check(#probe.effects == 1 and probe.effects[1].bytes == probe.request_bytes,
			replacement .. ": status observation never submits a second effect or changes its immutable bytes")
		local delivered = w:result_events()[1]
		check(delivered.act == "dispatch-result/" .. probe.claim.grant_id .. "/" .. w.f.origin.window_epoch,
			replacement .. ": recovered result retains the original claim and executor route")
		local status_routes = 0
		for _, route in w:bridge_routes() do
			if route.event.act == "status" then
				status_routes += 1
				local outer = runtime.json.decode(route.native_event.value)
				check(route.native_pane == 9001 and route.native_event.ev == "action" and route.native_event.act == "spawn_relay"
					and outer.act == "status" and outer.lane_id == route.pane and outer.bytes == first.bytes
					and route.event.value == outer.bytes,
					replacement .. ": the real ORCH relay carries the unchanged outstanding status, never a SPAWN pane event")
			end
		end
		check(status_routes == #probe.queries and #w:bridge_placements() == 0,
			replacement .. ": every status uses the pane-free relay without provisioning a transport view")
		for _, event in w.events do check(event.command ~= "lost", replacement .. ": recovered observation never emits lost") end
		end
	end
	for _, replacement in { "absent", "unrelated" } do
		if section == nil or section == "driver_deadline_" .. replacement then
		local w, probe = retry_fixture(replacement)
		local first = probe.queries[1]
		local delays = { 1000, 2000, 4000, 8000, 15000 }
		local lost_at
		for _ = 1, 20 do
			local before = #probe.queries
			local next_retry = probe.queries[before].at + delays[math.min(before, #delays)]
			local target = math.min(next_retry, probe.effects[1].at + 30500, w:now() + 5000)
			w:tick(target - w:now())
			if #probe.queries > before then
				local latest, previous = probe.queries[#probe.queries], probe.queries[#probe.queries - 1]
				check(#probe.queries == before + 1 and latest.bytes == first.bytes
					and latest.at - previous.at == delays[math.min(before, #delays)],
					replacement .. ": unanswered status uses bounded existing backoff, never new IDs or per-tick polling")
			end
			for _, event in w.events do
				if event.command == "lost" and event.action_id == probe.action_id then lost_at = w:now(); break end
			end
			if lost_at then break end
		end
		assert(lost_at, "unanswered read must reach its existing effect deadline")
		check(lost_at - probe.effects[1].at > 30000 and lost_at - probe.effects[1].at <= 30500
			and #probe.queries == 5 and probe.queries[5].at - first.at == 15000,
			replacement .. ": +1/+3/+7/+15s replays stop before the capped +30s retry exceeds the 30s effect deadline")
		check(#probe.effects == 1 and #w:result_events() == 0 and w.f:action(probe.action_id).phase == "uncertain"
			and w.f:action(probe.action_id).claim.grant_id == probe.claim.grant_id,
			replacement .. ": deadline retains exactly the original uncertain claim without a second effect")
		end
	end
	if section == nil or section == "driver_missing" then
		local w, probe = retry_fixture("missing")
		local first = probe.queries[1]
		w:tick(4999)
		check(#probe.queries == 1 and #probe.effects == 1 and #w:result_events() == 0,
			"correlated missing is not permission to resubmit the effect or generate a status every tick")
		w:tick(1)
		check(#probe.queries == 2 and probe.queries[2].at - first.at == 5000
			and probe.queries[2].request.request_id ~= first.request.request_id,
			"an answered missing query permits a new identity only at the existing 5s status cadence")
		local lost_at
		for _ = 1, 7 do
			local target = math.min(w:now() + 5000, probe.effects[1].at + 30500)
			w:tick(target - w:now())
			for _, event in w.events do if event.command == "lost" then lost_at = w:now(); break end end
			if lost_at then break end
		end
		check(lost_at ~= nil and lost_at - probe.effects[1].at > 30000 and lost_at - probe.effects[1].at <= 30500
			and #probe.effects == 1 and #probe.queries == 6 and w.f:action(probe.action_id).phase == "uncertain",
			"repeated missing answers cannot extend the original effect deadline or release its occupied claim")
		for index = 2, #probe.queries do
			check(probe.queries[index].at - probe.queries[index - 1].at == 5000,
				"each conclusive missing observation retains bounded new-query pacing")
		end
	end
	if section == nil or section == "driver_suspension" then
		local w, probe = retry_fixture("absent")
		w:elapse(60000); w:tick()
		check(#probe.queries == 1 and w.f:action(probe.action_id).phase == "claimed",
			"suspension wall time neither expires the awake effect deadline nor bursts queued status retries")
		probe.recover = true
		w:tick(); w:tick()
		check(#probe.queries == 2 and #probe.effects == 1 and w.f:action(probe.action_id) == nil,
			"the resumed awake retry observes fresh status without replaying the effect")
	end
	for _, fence in { "origin", "claim" } do
		if section == nil or section == "driver_fence_" .. fence then
		local w, probe = retry_fixture("original")
		local bytes = probe.queries[1].bytes
		if fence == "origin" then
			-- A different native window explicitly takes the durable controller route.
			-- An epoch-only mutation in this same window is eligible for native-proof recovery.
			w.f.origin.window_key = "other-native-window"
			w.f.origin.window_epoch = "continued-window"
			assert(w.f:apply("continue_controller", { operator_verified = true }).ok)
		else
			-- A new claim observed in the same action scope must not inherit an old query.
			w.f:action(probe.action_id).claim.grant_id = "replacement-grant"
		end
		for _ = 1, 6 do w:tick() end
		local repeats = 0
		for _, query in probe.queries do if query.bytes == bytes then repeats += 1 end end
		check(repeats == 1 and #probe.effects == 1 and #w:result_events() == 0,
			fence .. ": changed authorization cannot resend a stale outstanding query or original effect; "
				.. runtime.json.encode({ repeats = repeats, effects = #probe.effects, results = #w:result_events(), current = w:diagnostic() }))
		end
	end
end
do
	for _, command in { "poll", "catalog" } do
		if section == nil or section == "driver_pause_" .. command then
		local w = window_fixture()
		w:click(command, if command == "poll" then { worker_id = w.id } else nil)
		local action_id
		for id, action in w.f.authority.registry.dispatch.actions do
			if action.phase == "ready" then action_id = id end
		end
		assert(action_id, "fixture must queue an actual read action")
		w:click("pause"); w:tick()
		check(flow(w.f).policy.paused and w.f:action(action_id).phase == "claimed",
			"pause before the first driver turn cannot strand the already queued " .. command)
		end
	end
end
if section == nil or section == "driver_reply_pause" then
	local w = window_fixture()
	w:click("inspect_worker", { worker_id = w.id })
	w:click("reply", { worker_id = w.id })
	assert(w:worker().report_request_pending, "fixture must commit a sendable worker's report request")
	w:click("pause")
	w:elapse(6000); w:tick(); w:tick()
	local active = w:worker().active_action_id
	check(flow(w.f).policy.paused and active ~= nil and w.f:action(active).phase == "claimed"
		and w.f:action(active).request.op == "mailbox_publish_reply",
		"an actionless reply command superseded by pause releases its driver so the durable reply still drains")
end
if section == nil or section == "driver_wake_busy_before" then
	local race = window_fixture()
	assert(race.f:apply("intake", { worker_id = race.id, bytes = race.f:report(race.id, 2, "HEARTBEAT", { state = "idle" }) }).ok)
	local publication = race.f:apply("poll", { worker_id = race.id })
	local publication_request = race.f:action(publication.action_id).request
	assert(race.f:finish(publication.action_id, "published", { wake_status = "awaiting_window", wake_effect_started = false,
		wake_target_request_id = publication_request.request_id, wake_target_action_id = publication_request.action_id }).ok)
	race:click("inspect_worker", { worker_id = race.id })
	local wake = race.f:apply("poll", { worker_id = race.id }); assert(wake.ok)
	check(race.f:action(wake.action_id).request.op == "native_wake", "fresh idle evidence schedules a separate retained notification effect")
	race:click("execute", { action_id = wake.action_id })
	race.api.schedule(race.cx) -- Establish the idle observation deadline before native state changes.
	race.agents[1].state = "working"
	race:tick(); race:elapse(6000); race:tick()
	local following = race:worker().active_action_id
	check(following ~= nil and race.f:action(following).request.op == "mailbox_read"
		and race:worker().wake_pending_count > 0,
		"busy-before-claim defers the unstarted notification, releases its inert driver and preserves mailbox progress")
end
if section == nil or section == "driver_wake_busy_after" then
	-- The worker can also become busy after ORCH+ claimed the wake but before SPAWN sends it.
	local claimed = window_fixture()
	local cf, cid = claimed.f, claimed.id
	assert(cf:apply("intake", { worker_id = cid, bytes = cf:report(cid, 2, "HEARTBEAT", { state = "idle" }) }).ok)
	local cp = cf:apply("poll", { worker_id = cid })
	local cr = cf:action(cp.action_id).request
	assert(cf:finish(cp.action_id, "published", { wake_status = "awaiting_window", wake_effect_started = false,
		wake_target_request_id = cr.request_id, wake_target_action_id = cr.action_id }).ok)
	claimed:click("inspect_worker", { worker_id = cid })
	local cw = cf:apply("poll", { worker_id = cid }); assert(cw.ok)
	assert(cf:action(cw.action_id).request.op == "native_wake")
	assert(cf:apply("claim", { action_id = cw.action_id, executor = cf.origin.window_epoch }).ok)
	claimed.agents[1].state = "working"
	-- Keep ORCH+'s earlier idle observation: SPAWN saw the change first.
	assert(cf:finish(cw.action_id, "full", { resource = "native_wake_idle", current = 1, limit = 1,
		retryable = true, effect_started = false }).ok)
	check(cf:action(cw.action_id) == nil and claimed:worker().wake_pending_count > 0,
		"a proven never-sent busy wake releases its action, retaining the notification obligation")
	local read = cf:apply("poll", { worker_id = cid }); assert(read.ok, read.message)
	check(cf:action(read.action_id).request.op == "mailbox_read",
		"busy-after-claim does not block reading the worker's reports behind its deferred notification")
	assert(cf:finish(read.action_id, "missing", {}).ok)
	claimed.agents[1].state = "idle"
	claimed:click("inspect_worker", { worker_id = cid })
	local fresh = cf:apply("poll", { worker_id = cid }); assert(fresh.ok, fresh.message)
	local fresh_request = cf:action(fresh.action_id).request
	check(fresh.action_id ~= cw.action_id and fresh_request.op == "native_wake"
		and fresh_request.target_action_id == cr.action_id and fresh_request.target_request_id == cr.request_id,
		"fresh idle evidence grants a new notification for the same publication, without replaying the refused request")
	assert(cf:finish(fresh.action_id, "full", { resource = "native_wake_idle", current = 1, limit = 1 }).ok)
	check(cf:action(fresh.action_id).phase == "uncertain",
		"a busy-wake response without definitive no-effect proof stays uncertain and is never automatically reissued")
end
-- Discovery serves real receipt debt without starving reports or reading debt-free watermarks.
if section == nil or section == "receipt_polling" then
	local w = window_fixture()
	w:elapse(6000); w.api.schedule(w.cx)
	local first = assert(w:worker().active_action_id)
	check(w.f:action(first).request.selector.stream == "watermark",
		"a published unconfirmed receipt gets the first discovery turn, not the fourth")
	assert(w.f:finish(first, "missing", {}).ok)
	w:tick(); w:elapse(5000); w.api.schedule(w.cx)
	local second = assert(w:worker().active_action_id)
	check(w.f:action(second).request.selector.stream == "report",
		"an unavailable receipt watermark cannot starve report discovery")
	assert(w.f:finish(second, "missing", {}).ok)
	w:tick(); w:elapse(5000); w.api.schedule(w.cx)
	local third = assert(w:worker().active_action_id)
	check(w.f:action(third).request.selector.stream == "watermark",
		"retained receipt debt gets another normal discovery turn after the report read")

	local settled = window_fixture()
	assert(settled.f:watermark(settled.id).ok)
	local compact = settled.f:apply("poll", { worker_id = settled.id })
	assert(settled.f:action(compact.action_id).request.mode == "compact")
	assert(settled.f:finish(compact.action_id, "compacted", {}).ok)
	settled.agents[1].state = "working"
	for _ = 1, 4 do
		settled:elapse(6000); settled.api.schedule(settled.cx)
		local active = assert(settled:worker().active_action_id)
		check(settled.f:action(active).request.selector.stream == "report",
			"fully confirmed receipts spend discovery on reports, never a watermark that cannot advance")
		assert(settled.f:finish(active, "missing", {}).ok)
		settled:tick()
	end
end
-- Continuation is a projection of concrete reducer work, not a persisted scheduling flag.
if section == nil or section == "timer" then
	local function polls(w)
		local out = {}
		for _, event in w.events do if event.command == "poll" then table.insert(out, event) end end
		return out
	end
	local w = window_fixture()
	w:elapse(6000)
	local discovery_at = w:now()
	assert(not w:worker().poll_continuation, "accepted fixture must begin with only idle discovery")
	w.api.schedule(w.cx)
	local first = assert(w:worker().active_action_id)
	assert(w.f:finish(first, "missing", {}).ok)
	w:tick() -- Drop the completed action's driver, without advancing the discovery deadline.
	local initial = #polls(w)
	for seq = 2, 7 do
		assert(w.f:apply("intake", { worker_id = w.id, bytes = w.f:report(w.id, seq, "HEARTBEAT", { state = "idle" }) }).ok)
		check(w:worker().poll_continuation == true
			and w.f.authority.registry.dispatch.workers[w.id].workflow.poll_continuation == nil,
			"pending ACK projects continuation without adding persisted workflow schema")
		w.api.schedule(w.cx)
		local sent = polls(w)
		local progressed = #sent == initial + seq - 1 and sent[#sent].bytes == nil
		check(progressed, (if progressed then "" else w:poll_diagnostic(seq, initial, sent) .. " · ")
			.. "known ACK bypasses the still-future discovery deadline without a fourth-poll watermark")
		local active = assert(w:worker().active_action_id)
		assert(w.f:action(active).request.op == "mailbox_publish_ack")
		for _ = 1, 3 do w.api.schedule(w.cx) end
		check(#polls(w) == #sent and w:worker().active_action_id == active,
			"active continuation action cannot acquire duplicate poll commands")
		assert(w.f:finish(active, "published", {}).ok)
		w.api.schedule(w.cx)
		check(#polls(w) == #sent, "settled action with an outstanding driver cannot duplicate continuation")
		w:tick()
	end
	check(w:now() < discovery_at + 5000, "all six continuations complete inside the original discovery interval")
	local before = #polls(w)
	w:elapse(5000); w.api.schedule(w.cx)
	check(#polls(w) == before + 1 and polls(w)[#polls(w)].bytes == nil,
		"six continuations do not turn the second idle discovery into the eighth-poll watermark")

	local idle = window_fixture()
	idle:elapse(6000)
	local idle_at = idle:now()
	idle.api.schedule(idle.cx)
	assert(idle.f:finish(assert(idle:worker().active_action_id), "missing", {}).ok)
	idle:tick()
	while idle:now() < idle_at + 4500 do idle:tick() end
	check(#polls(idle) == 1, "empty idle discovery never becomes a hot continuation poll")
	idle:elapse(500); idle.api.schedule(idle.cx)
	check(#polls(idle) == 2, "idle discovery still runs at the configured 5000ms poll cadence")

	for _, rollover in { false, true } do
		local pending = window_fixture({ hold_poll = true })
		assert(pending.f:apply("policy", { policy = { automatic_reports = true, report_request_ms = 5000,
			stale_ms = 600000, auto_rollover = rollover, rollover_threshold_pct = 50 } }).ok)
		assert(pending.f:apply("intake", { worker_id = pending.id,
			bytes = pending.f:report(pending.id, 2, "READY", { state = "idle", context_used_pct = 90 }) }).ok)
		assert(observed(pending.f, pending.id, "idle").ok)
		pending:elapse(6000)
		local due = pending:worker()
		assert(due.poll_continuation and due.due_report and (not rollover or due.due_rollover),
			"fixture must expose real continuation and policy work simultaneously")
		pending.api.schedule(pending.cx)
		check(#polls(pending) == 1 and polls(pending)[1].bytes == nil,
			"continuation takes precedence over " .. (if rollover then "due_rollover" else "due_report"))
		for _ = 1, 14 do pending:tick() end
		check(#polls(pending) == 1 and pending:worker().active_action_id == nil,
			"unanswered host poll remains one in-flight command beyond poll_ms, with no duplicate action")
		for _, event in pending.events do
			check(event.command ~= "reply" and event.command ~= "rollover",
				"pending continuation cannot be superseded by automatic policy work")
		end
	end

	local fair = window_fixture({ hold_poll_receipt = true })
	fair.f.target_pane = "9004"
	local other = fair.f:accepted(false)
	for _, id in { fair.id, other } do
		assert(fair.f:apply("intake", { worker_id = id, bytes = fair.f:report(id, 2, "HEARTBEAT", { state = "idle" }) }).ok)
	end
	fair.api.schedule(fair.cx)
	check(#polls(fair) == 1, "one scan turn selects at most one worker's continuation")
	fair.api.schedule(fair.cx)
	check(#polls(fair) == 1, "another worker cannot overwrite an unanswered controller poll observation")
	local observed_ids = {}
	for _, event in fair.events do if event.command == "observe" then observed_ids[event.worker_id] = true end end
	check(observed_ids[fair.id] and observed_ids[other], "in-flight poll does not stop fair one-worker observation rotation")
	local first_id = polls(fair)[1].worker_id
	local second_id = if first_id == fair.id then other else fair.id
	local released = fair:release_poll_receipt()
	local first_action = assert(released.action_id)
	fair:tick() -- Consume the exact delayed command receipt and claim only its existing action.
	check(#polls(fair) == 1 and fair.f:action(first_action).phase == "claimed",
		"receipt consumption keeps the first worker's live action and driver without repeating its poll")
	fair.api.schedule(fair.cx)
	local progressed = polls(fair)
	check(#progressed == 2 and progressed[2].worker_id == second_id
		and fair.f:action(first_action).phase == "claimed",
		"after the receipt, another worker's fair turn progresses while the first effect remains active")
	local second_action
	for _, worker in flow(fair.f).workers do
		if worker.worker_id == second_id then second_action = worker.active_action_id end
	end
	assert(second_action and fair.f:action(second_action).request.op == "mailbox_publish_ack")
	assert(fair.f:finish(first_action, "published", {}).ok)
	assert(fair.f:finish(second_action, "published", {}).ok)
	fair:tick() -- Consume both completed scopes before introducing their next protocol step.
	for _, id in { first_id, second_id } do
		assert(fair.f:apply("intake", { worker_id = id, bytes = fair.f:report(id, 3, "HEARTBEAT", { state = "idle" }) }).ok)
	end
	local next_round = {}
	for _ = 1, 4 do
		local count = #polls(fair)
		fair.api.schedule(fair.cx)
		local sent = polls(fair)
		check(#sent <= count + 1, "a fair continuation scan never selects more than one worker")
		if #sent > count then
			local id = sent[#sent].worker_id
			check(not next_round[id], "a worker's next protocol step is not duplicated during rotation")
			next_round[id] = true
			local action
			for _, worker in flow(fair.f).workers do if worker.worker_id == id then action = worker.active_action_id end end
			assert(action and fair.f:finish(action, "published", {}).ok)
			fair:tick()
		end
		if next_round[first_id] and next_round[second_id] then break end
	end
	check(next_round[first_id] and next_round[second_id],
		"both workers rotate into their next protocol step after delayed receipt recovery without starvation")
end
if section == nil or section == "status_launcher" then
	local w = window_fixture()
	check(#w.files_buttons == 0, "ORCH+ registers no Files-pane button: its launcher lives in the status bar")
	check(#w.status_formatters == 1, "ORCH+ registers exactly one status formatter")
	local segments = w.status_formatters[1]({ pane = 9001, program = "shell", busy = false })
	check(#segments == 1 and segments[1].icon == "flow" and segments[1].text == "ORCH+" and segments[1].command == "plugin.orchplus.status_open",
		"the status segment carries the unchanged ORCH+ flow icon and the status_open command")
	local command = w.commands[string.match(segments[1].command, "^plugin%.orchplus%.(.+)$")]
	check(command ~= nil and command.icon == "flow", "the segment's command is a registered ORCH+ palette command with the flow icon")
	check(w.commands.open ~= nil and w.commands.orch_setup ~= nil, "palette access to ORCH+ remains")
	check(#w.prompt_calls == 0, "the status-bar prompt never runs while the window module initializes")
	w.hooks.window_start(w.cx)
	check(#w.prompt_calls == 1 and w.prompt_calls[1].id == "orchplus" and w.prompt_calls[1].cx == w.cx, "window_start asks the shared status-bar prompt once for plugin orchplus")
	-- The click is inert: it opens Config only and starts no controller, admission, continuation or dispatch.
	local before_events, before_writes, before_processes = #w.events, w.f.memory.writes, #w.processes
	local registry_before = runtime.json.encode(w.f.authority.registry)
	command.run(w.cx)
	check(#w.events == before_events and w.f.memory.writes == before_writes and #w.processes == before_processes,
		"clicking the launcher dispatches nothing: no host event, no authority write, no child process")
	check(runtime.json.encode(w.f.authority.registry) == registry_before, "clicking the launcher leaves authority state untouched")
end
if section == nil or section == "timer" then
	local w = window_fixture()
	check(#w.timers == 1, "module initialization rearms exactly one window timer without window_start")
	w.hooks.window_start(w.cx); w.hooks.window_start(w.cx)
	check(#w.timers == 1, "repeated startup never duplicates observation/dispatch loop")
	w.f.target_pane = "9004"
	local other = w.f:accepted(false)
	for _ = 1, 4 do w:tick(); check(#w.timers == 1, "fresh callback rearms one singleton timer") end
	local observed_ids = {}
	for _, event in w.events do if event.command == "observe" then observed_ids[event.worker_id] = true end end
	check(observed_ids[w.id] and observed_ids[other], "scheduling observes every registered worker, not only last selected worker")
	assert(w.f:apply("intake", { worker_id = w.id, bytes = w.f:report(w.id, 2, "HEARTBEAT", { state = "working" }) }).ok)
	local wake = w.f:apply("poll", { worker_id = w.id })
	local wake_request = w.f:action(wake.action_id).request
	assert(w.f:finish(wake.action_id, "published", { wake_status = "awaiting_window", wake_effect_started = false,
		wake_target_request_id = wake_request.request_id, wake_target_action_id = wake_request.action_id }).ok)
	w.agents[1].state = "working"
	w:elapse(6000)
	w.api.schedule(w.cx); w.api.schedule(w.cx)
	local other_action
	for _, worker in flow(w.f).workers do if worker.worker_id == other then other_action = worker.active_action_id end end
	check(other_action ~= nil and w.f:action(other_action).request.op == "mailbox_read", "busy worker wake does not starve another worker's due mailbox read")
	local publication = w.f:action(wake.action_id)
	check(publication == nil, "consumed publication is removed while the current worker retains its outstanding wake obligation")
	for _, action in w.f.authority.registry.dispatch.actions do
		check(action.request.op ~= "native_wake" or action.phase ~= "claimed", "busy native worker receives no wake claim or interruption")
	end
	local tree = assert(w.cx.session:surface(9001, { root = "main.dispatch-action-" .. other_action }))
	local span = tree.main.p.spans[1]
	local scoped = runtime.json.decode(if type(span) == "string" then span else span.t)
	check(scoped.action.action_id == other_action, "other worker's exact per-action scope remains independently addressable")
	w.current.id = 8
	local count = #w.events
	w:tick()
	check(#w.events == count and w:focused() == nil, "background scheduling never switches session or steals focus")
	local next_callback
	local fake = table.clone(runtime)
	fake.timer = function(_, callback) next_callback = callback; return {} end
	fake.on = function() end; fake.pane = { list = function() return {} end }
	fake.kv = { get = function() return nil end, set = function() error("timer must not initialize storage") end }
	fake.block = { define = function() end }
	local chunk = assert(loadstring(runtime.fs.read(root .. "/host.luau"), "health-host-timer"))
	setfenv(chunk, setmetatable({ tern = fake, require = shared.load }, { __index = environment })); chunk()
	local initial_callback = assert(next_callback, "host module must arm without any block or window")
	next_callback = nil
	initial_callback()
	check(type(next_callback) == "function",
		"host timer remains live without a store, block or window and never invents authority")
end
-- An owner's Finish choice is either sent (the reducer would accept it) or refused with a notice
-- naming the reason: by the window's pre-check, or by the host refusal the driver reads.
local function press_finish(w)
	local before = w:picker()
	w:click("finish", { worker_id = w.id })
	if w:picker() ~= before then w:pick({ finish = true }) end
	for _ = 1, 3 do w:tick() end
end
local function noticed(w, text) for _, message in w.notices do if message:find(text, 1, true) then return true end end return false end
if section == nil or section == "finish" then
	local held = window_fixture()
	assert(held.f:apply("intake", { worker_id = held.id, bytes = held.f:report(held.id, 2, "ASK", {
		question = "Do not abandon this gate", options = runtime.json.array({ { id = "hold", label = "Hold" } }),
	}) }).ok)
	press_finish(held)
	check(not held:worker().finish_requested and #flow(held.f).gates == 1 and noticed(held, "inish"),
		"actual Finish confirmation refuses pending gates visibly without dropping their evidence")
	local w = window_fixture()
	w:click("finish", { worker_id = w.id }); w:pick({ finish = false })
	check(not w:worker().finish_requested, "cancelled Finish never requests a native stop")
	w:click("finish", { worker_id = w.id }); w:pick({ finish = true })
	check(w:outcome().ok and w:worker().finish_requested, "actual Finish control commits explicit ordinary-worker retirement intent")
	local worker = w.f.authority.registry.dispatch.workers[w.id]
	local mark = { version = 1, type = "receipt_watermark", mailbox_handle = worker.mailbox_handle,
		through_seq = worker.accepted_seq, receipt_chain_sha256 = worker.receipt_chain }
	for _, key in { "logical_session_id", "worker_id", "worker_generation", "launch_request_id", "work_id", "enrolment_token" } do mark[key] = worker[key] end
	local read = w.f:apply("poll", { worker_id = w.id, bytes = "watermark" }); assert(read.ok)
	local page = assert(shared.codec.project_page(runtime.json.encode(mark), w.f:action(read.action_id).request.selector))
	assert(w.f:finish(read.action_id, "read", runtime.json.decode(page)).ok)
	local stop = w.f:apply("poll", { worker_id = w.id })
	local request = w.f:action(stop.action_id).request
	check(request.op == "stop", "settled Finish schedules the original exact worker stop")
	assert(w.f:finish(stop.action_id, "stopped", { pane_binding = request.pane_binding, observation = "exited" }).ok)
	local retire = w.f:apply("poll", { worker_id = w.id })
	check(w.f:action(retire.action_id).request.op == "mailbox_retire", "verified stop precedes mailbox retirement")
	assert(w.f:finish(retire.action_id, "retired", {}).ok)
	assert(w.f:queue(false).ok)
	check(w.f.authority.registry.dispatch.workers[w.id] == nil, "settled ordinary worker capacity is reclaimed only after retirement")
end
-- Final smoke finish-defect: Finish on reattached workers held target_unavailable, or holding
-- uncertain old effects, sent nothing visible — the refusal was dropped without a notice.
if section == nil or section == "finish_refusal" then
	local function uncertain_read(w)
		local read = w.f:apply("poll", { worker_id = w.id, bytes = "watermark" }); assert(read.ok and read.action_id, read.message)
		assert(w.f:apply("claim", { action_id = read.action_id, executor = w.f.origin.window_epoch }).ok)
		local grant = w.f:action(read.action_id).claim
		assert(w.f:apply("lost", { action_id = read.action_id, executor = grant.executor, grant_id = grant.grant_id }).ok)
		assert(w.f:action(read.action_id).phase == "uncertain")
		return read.action_id
	end
	local held = window_fixture()
	uncertain_read(held)
	local stored = held.f.authority.registry.dispatch.workers[held.id]
	stored.phase = "held"; stored.reason = { code = "target_unavailable", message = "Native effect outcome uncertain; do not retry" }
	press_finish(held)
	check(noticed(held, "target_unavailable") and noticed(held, "Nothing was stopped") and not held:worker().finish_requested,
		"Finish of a held target_unavailable worker is refused with a notice naming its hold")
	local busy = window_fixture()
	local action_id = uncertain_read(busy)
	press_finish(busy)
	check(noticed(busy, "unsettled effect " .. action_id) and not busy:worker().finish_requested,
		"Finish of an accepted worker with an uncertain old effect is refused with a notice naming the effect")
	-- A refusal only the reducer sees (not in the projection): the driver notices the host's reason.
	local pending = window_fixture()
	pending.f.authority.registry.dispatch.workers[pending.id].accept_pending = true
	local sent = 0
	press_finish(pending)
	for _, e in pending.events do if e.command == "finish" then sent += 1 end end
	check(sent == 1 and not pending:outcome().ok and pending:outcome().code == "workflow_unsettled"
		and noticed(pending, "Refused finish: Finish cannot discard unresolved effects"),
		"a host Finish refusal is noticed with the reducer's reason")
	-- The reducer accepts Finish again after SPAWN's pre-effect retirement refusal: the window sends it.
	local w = window_fixture()
	w:click("finish", { worker_id = w.id }); w:pick({ finish = true })
	assert(w:outcome().ok and w:worker().finish_requested)
	local worker = w.f.authority.registry.dispatch.workers[w.id]
	local mark = { version = 1, type = "receipt_watermark", mailbox_handle = worker.mailbox_handle,
		through_seq = worker.accepted_seq, receipt_chain_sha256 = worker.receipt_chain }
	for _, key in { "logical_session_id", "worker_id", "worker_generation", "launch_request_id", "work_id", "enrolment_token" } do mark[key] = worker[key] end
	local read = w.f:apply("poll", { worker_id = w.id, bytes = "watermark" }); assert(read.ok)
	local page = assert(shared.codec.project_page(runtime.json.encode(mark), w.f:action(read.action_id).request.selector))
	assert(w.f:finish(read.action_id, "read", runtime.json.decode(page)).ok)
	local stop = w.f:apply("poll", { worker_id = w.id }); local request = w.f:action(stop.action_id).request
	assert(w.f:finish(stop.action_id, "stopped", { pane_binding = request.pane_binding, observation = "exited" }).ok)
	local retire = w.f:apply("poll", { worker_id = w.id }); assert(w.f:action(retire.action_id).request.op == "mailbox_retire")
	assert(w.f:apply("claim", { action_id = retire.action_id, executor = w.f.origin.window_epoch }).ok)
	assert(w.f:apply("result", { action_id = retire.action_id, executor = w.f.origin.window_epoch, grant_id = w.f:action(retire.action_id).claim.grant_id,
		response_bytes = shared.frame(w.f:action(retire.action_id).request, "rejected", nil, { code = "producer_unsettled", message = "The stopped producer journal is not settled; nothing was retired" }) }).code == "retirement_refused")
	w:click("finish", { worker_id = w.id })
	local picker = w:picker()
	check(picker and picker.items[2].label == "Retry mailbox retirement once", "a refused retirement offers the owner one Finish retry")
	w:pick({ finish = true })
	check(w:outcome().ok and w:outcome().code == "retirement_rearmed", "the window sends the Finish retry the reducer accepts")
end
if section == nil or section == "continuation" then
	local w = window_fixture()
	w:select_worker(w.id) -- Keep the original recipient selected when another worker is added.
	assert(w.f:apply("intake", { worker_id = w.id, bytes = w.f:report(w.id, 2, "ASK", {
		question = "Preserve this pending question over reload", options = runtime.json.array({ { id = "yes", label = "Yes" } }),
	}) }).ok)
	local old_api, old_origin = w.api, clone(w.f.origin)
	local old_worker = clone(w:worker())
	w:reload()
	w:palette("continue_controller"); w:pick({ continue_controller = false })
	check(#w.events == 0, "cancelled controller continuation changes no origin")
	w:palette("continue_controller"); w:pick({ continue_controller = true })
	assert(w:outcome().ok)
	w.f.origin = clone(w.events[#w.events].origin)
	w.f.target_pane = "9004"
	local unrelated = w.f:accepted(false)
	check(old_api.native_observation(w.cx, 9001, old_worker) == "unknown",
		"durable continued origin fences callbacks from the still-retained old VM")
	w:click("continue_worker", { worker_id = w.id })
	w:pick({ pane = 9002 }); w:pick({ attach = false })
	check(w:worker().origin_binding.window_epoch == old_origin.window_epoch, "candidate selection plus cancellation never adopts a worker")
	w:click("continue_worker", { worker_id = w.id })
	w:pick({ pane = 9002 })
	local attachment_revision = w.f.authority.registry.revision
	assert(observed(w.f, unrelated, "working").ok)
	check(w.f.authority.registry.revision > attachment_revision, "unrelated worker observation advances the global registry during attachment confirmation")
	local attachment_before, attachment_writes = runtime.json.encode(w.f.authority.registry), w.f.memory.writes
	w:pick({ attach = true })
	check(not w:outcome().ok and w:outcome().code == "stale_revision"
		and w:worker().origin_binding.window_epoch == old_origin.window_epoch and w:worker().active_action_id == nil
		and w.f.memory.writes == attachment_writes and runtime.json.encode(w.f.authority.registry) == attachment_before,
		"an unrelated revision change refuses the captured attachment without adopting a pane or queuing an effect")
	w:click("continue_worker", { worker_id = w.id })
	w:pick({ pane = 9002 }); w:pick({ attach = true })
	assert(w:outcome().ok, w:outcome().message)
	local attach = w.f:action(w:outcome().action_id)
	check(attach.request.op == "attach_worker" and attach.request.previous_origin_binding.window_epoch == old_origin.window_epoch,
		"confirmed continuation uses immutable previous launch identity and a separate attachment request")
	assert(w.f:finish(attach.request.action_id, "attached", { pane_binding = attach.request.pane_binding,
		previous_origin_binding = attach.request.previous_origin_binding, previous_pane_binding = attach.request.previous_pane_binding }).ok)
	check(w.api.native_observation(w.cx, 9001, w:worker()) == "idle" and #flow(w.f).gates == 1,
		"only committed explicit attachment restores native observation and preserves the pending gate")
	local gate = flow(w.f).gates[1]
	local fields = { gate_id = gate.id, gate_revision = gate.revision, worker_id = w.id }
	check(w.cx.session:surface(9001, { root = "main.workflow-gate-" .. gate.id }) ~= nil,
		"continued selected worker exposes the retained pending ASK through the actual gate projection")
	w:click("answer", fields)
	check(w:picker().placeholder == gate.question, "continued gate opens its actual current question rather than a stale attachment picker")
	w:pick({ choice_id = "yes", label = "Yes" }); w:answer("Continue the same exact worker")
	local answered = flow(w.f).gates[1]
	check(w:outcome().ok and answered.answer ~= nil and answered.answer.choice_id == "yes",
		"continued same-generation gate accepts its explicit owner answer")
	local count = #w.events
	w:click("answer", fields)
	check(#w.events == count, "old gate control cannot emit a duplicate decision after continuation")
end
if section == nil or section == "alias_recovery" then
	local w = window_fixture()
	local pending = w.f:apply("catalog"); assert(pending.ok)
	assert(w.f:apply("claim", { action_id = pending.action_id, executor = w.f.origin.window_epoch }).ok)
	local action = clone(w.f:action(pending.action_id))
	w:reload(); w:move_controller(9010)
	w:palette("continue_controller"); w:pick({ continue_controller = true }); assert(w:outcome().ok)
	w.f.origin = clone(w.events[#w.events].origin)
	w:bridge(peer_body(action.request, "catalog", { catalog_version = 2, namespace = "fixture-spawn", host_key = "fixture-host", config_revision = 0, revision = 0,
		setup = { schema = 1, state = "completed", config_revision = 0, readiness = { state = "not_run", config_revision = 0, summary = "" } }, records = runtime.json.array() }))
	w:click("reconcile", { action_id = action.request.action_id })
	w:tick(); w:tick()
	local query
	for _, event in w:bridge_events() do if event.op == "status" then assert(query == nil, "retained outcome is queried once"); query = event end end
	check(query ~= nil and query.controller_pane == "9010" and query.origin_binding.window_epoch == w.f.origin.window_epoch
		and query.target_request_id == action.request.request_id and query.target_request_serial == action.request.request_serial,
		"replacement window inspects immutable original outcome through the new window-local controller alias")
	local delivered = assert(w:result_events()[1])
	check(delivered.act == "dispatch-result/" .. action.claim.grant_id .. "/" .. w.f.origin.window_epoch,
		"changed-alias result callback retains original grant and carries the continued execution epoch")
	local envelope = runtime.json.decode(delivered.value)
	local original = assert(protocol.decode_response(envelope.response_bytes, action.request))
	check(original.request_id == action.request.request_id and original.origin_binding.window_epoch == action.request.origin_binding.window_epoch,
		"changed-alias recovery preserves original outcome identity without submitting another effect")
end
if section == nil or section == "held_report" then
	local w = window_fixture()
	local f, id = w.f, w.id
	local outcome = f:read_report(id, f:report(id, 2, "DONE", { checkpoint_id = "absent", artifact_revision = "rev", summary = "Invalid checkpoint reference" }))
	assert(outcome.code == "report_rejected" and f.authority.registry.dispatch.workers[id].rejected_report ~= nil, "fixture must hold a rejected report")
	w:click("policy", { policy = { automatic_reports = true }, expected_sha256 = shared.quota.digest(flow(f).policy) })
	assert(flow(f).policy.automatic_reports, "fixture must enable automatic progress requests")
	local function sent(command) local n = 0; for _, event in w.events do if event.command == command then n += 1 end end; return n end
	local actions = 0
	for _ in f.authority.registry.dispatch.actions do actions += 1 end
	for _ = 1, 24 do w:elapse(4000); w:tick() end -- 108 s awake: past poll_ms and heartbeat_ms many times.
	local after = 0
	for _ in f.authority.registry.dispatch.actions do after += 1 end
	check(sent("poll") == 0 and sent("reply") == 0 and after <= actions,
		"a held report with nothing outbound gets no automatic report/watermark read or progress request in a loop")
	check(not w:worker().due_poll and not w:worker().due_report and w.f.authority.registry.dispatch.workers[id].rejected_report ~= nil,
		"the hold and its retained evidence stay; only automatic re-reads stop")
	assert(f:apply("reply", { worker_id = id }).ok) -- Owner action on fresh idle evidence creates an outbound reply publication.
	for _ = 1, 3 do
		w:elapse(4000); w:tick()
		if sent("poll") > 0 then break end
	end
	local active = w:worker().active_action_id
	check(sent("poll") == 1 and active ~= nil and f:action(active).request.op == "mailbox_publish_reply",
		"outbound settlement still drains: the one automatic poll grants publication, never a report re-read")
end
if section == nil or section == "sweep_schedule" then
	local w = window_fixture({ inventory = { open_files = 12, stale_files = 2, mailboxes = 1 } })
	local function at(day, hour, minute) return os.time({ year = 2026, month = 11, day = day, hour = hour, min = minute, sec = 0 }) end
	local function sweeps()
		local out = {}
		for _, event in w.events do if event.command == "sweep" then table.insert(out, event) end end
		return out
	end
	local function log() return (w.f.authority.registry.dispatch.sweeps or {})[w.f.origin.logical_session_id] end
	w:set_wall(at(3, 2, 0)); w:tick()
	local sent = sweeps()
	check(#sent == 1 and sent[1].local_date == "2026-11-02" and sent[1].catch_up == true and log().last_date == "2026-11-02",
		"first attach before today's sweep time runs exactly one catch-up for the missed previous slot")
	w:set_wall(at(3, 2, 30)); for _ = 1, 4 do w:tick() end
	check(#sweeps() == 1, "nothing more runs before today's sweep time")
	w:set_wall(at(3, 3, 5)); w:tick()
	sent = sweeps()
	check(#sent == 2 and sent[2].local_date == "2026-11-03" and sent[2].catch_up == false and log().last_date == "2026-11-03", "the scheduled time runs once, on time")
	for _, t in { at(3, 3, 6), at(3, 12, 0), at(3, 23, 59) } do w:set_wall(t); w:tick(); w:tick() end
	check(#sweeps() == 2 and #log().runs == 2, "never more than one run per scheduled day")
	w:reload()
	w:palette("continue_controller"); w:pick({ continue_controller = true }); assert(w:outcome().ok)
	w.f.origin = clone(w.events[#w.events].origin)
	for _ = 1, 4 do w:tick() end
	check(#sweeps() == 2 and #log().runs == 2, "a reloaded and continued window does not run the same day again")
	check(w.f:apply("sweep", { local_date = "2026-11-03" }).code == "sweep_already_ran", "the durable host record refuses a second run for the day even when asked directly")
	w:set_wall(at(6, 10, 0)); w:tick() -- No window ran on 4 and 5 November (detached or asleep).
	sent = sweeps()
	check(#sent == 3 and sent[3].local_date == "2026-11-06" and sent[3].catch_up == true, "after missed days exactly one catch-up runs on the next attach or wake")
	for _ = 1, 4 do w:tick() end
	check(#sweeps() == 3 and #log().runs == 3 and log().runs[3].catch_up, "the catch-up run is recorded durably and never repeated")
	assert(w.f:apply("policy", { policy = { sweep_enabled = false } }).ok)
	w:set_wall(at(7, 4, 0)); for _ = 1, 3 do w:tick() end
	check(#sweeps() == 3, "a disabled sweep sends nothing")
	local inventory = {}
	local user = window_fixture({ no_worker = true, bridge_handler = function(request)
		if request.op == "mailbox_inventory" then table.insert(inventory, request) end
		return shared.frame(request, "pending")
	end })
	user:bridge({ placeholder = true })
	user:set_wall(at(3, 3, 5)); user:tick()
	user.agents[1].state = "working"
	for _ = 1, 3 do user:tick() end
	check(#inventory == 0, "timer ticks and model working state do not count as a human panel interaction")
	user:click("pause")
	for _ = 1, 3 do user:tick() end
	check(#inventory == 1 and inventory[1].request_serial == nil, "a real ORCH panel user intent starts one read-only execution-host inventory")
	for _ = 1, 3 do user:tick() end
	check(#inventory == 1, "later timer ticks cannot duplicate the in-flight daily notification")
end
if section == nil or section == "readable_views" then
	local f = shared.fixture(function() return { now_ms = 1700000000000, mono_ms = 1000, epoch = "views-host" } end)
	local id = f:accepted(false)
	local queued = f:queue(false); assert(queued.ok)
	local views = shared.load("views")
	local function render(config, worker_id, advanced)
		local projection = state.project(f.authority.registry)
		projection.dispatch = dispatch.project(f.authority.registry, f.origin.logical_session_id, f.origin.alias_nonce)
		return views.render({ pane = 42, alias_nonce = f.origin.alias_nonce, orch_session_id = f.origin.logical_session_id, action_serial = 0,
			workflow_worker = worker_id, config_open = config, advanced_open = advanced == true }, projection, "ready")
	end
	-- Human-visible text only: machine contract nodes (roles orchplus.*) and link targets are skipped.
	local function texts(node, out)
		if type(node) ~= "table" then return out end
		if type(node.p) == "table" and type(node.p.role) == "string" and node.p.role:sub(1, 9) == "orchplus." then return out end
		for key, value in node do
			if type(value) == "string" then
				if key == "t" or key == "text" or key == "label" or type(key) == "number" then table.insert(out, value) end
			elseif key ~= "actions" then texts(value, out) end
		end
		return out
	end
	for _, case in { { false, id, "fresh worker" }, { false, queued.worker_id, "unprovisioned work" }, { true, id, "Settings" } } do
		for _, advanced in { false, true } do
			local all = table.concat(texts(render(case[1], case[2], advanced), {}), "\n")
			check(all ~= "" and all:find("%f[%a]null%f[%A]") == nil and all:find("%f[%a]nil%f[%A]") == nil,
				case[3] .. " never renders raw null/nil in either mode")
			check((all:find("Last sweep: none yet.", 1, true) ~= nil) == advanced,
				"sweep diagnostics are readable in Advanced and absent from the normal conversation/Settings surface")
			check((all:find("Health, owner inbox and durable threads", 1, true) ~= nil) == advanced,
				"technical Health details require explicit Advanced disclosure")
		end
	end
end
-- CP2 live smoke: host-consumed gates are answered by the chosen option alone; the worker gate list
-- shows open questions first in numeric order; continuation is offered only where it is needed.
if section == nil or section == "cp2_controls" then
	local w = window_fixture()
	assert(w.f:apply("policy", { policy = { checkout_roots = runtime.json.array({ "/fixture" }) } }).ok)
	local gated = w.f:apply("queue", { record_id = "native", record_revision = 0, catalog_revision = 0,
		prompt = "Exercise the explicit shared-checkout owner decision.", cwd = "/fixture", placement = "split", coordinator = false })
	assert(gated.ok and gated.code == "task_gated", gated.message)
	local gate
	for _, candidate in flow(w.f).gates do if candidate.worker_id == gated.worker_id and candidate.kind == "shared_checkout" then gate = candidate end end
	assert(gate, "queue-time shared_checkout gate")
	w:select_worker(gated.worker_id)
	w:click("answer", { gate_id = gate.id, gate_revision = gate.revision, worker_id = gate.worker_id })
	local picker = assert(w:picker())
	check(picker.placeholder == gate.question, "the shared_checkout answer picker presents the exact question")
	w:pick({ choice_id = "launch_anyway", label = "Launch anyway" })
	check(w:editor() == nil, "a host-consumed shared_checkout answer opens no free-text prompt")
	local sent = w.events[#w.events]
	check(sent.command == "answer" and sent.choice_id == "launch_anyway" and sent.answer == "Launch anyway" and w:outcome().code == "launch_released",
		"the chosen option alone is the committed answer and releases the held launch")
	local views = shared.load("views")
	local function texts(node, out)
		if type(node) ~= "table" then return out end
		if type(node.p) == "table" and type(node.p.role) == "string" and node.p.role:sub(1, 9) == "orchplus." then return out end
		for key, value in node do
			if type(value) == "string" then
				if key == "t" or key == "text" or key == "label" or type(key) == "number" then table.insert(out, value) end
			elseif key ~= "actions" then texts(value, out) end
		end
		return out
	end
	local function render(f, worker_id, mutate)
		local projection = state.project(f.authority.registry)
		projection.dispatch = dispatch.project(f.authority.registry, f.origin.logical_session_id, f.origin.alias_nonce)
		if mutate then mutate(projection.dispatch.workflow) end
		-- Inspect Advanced alone: the normal conversation panel also presents open
		-- questions, but its separate presentation does not define diagnostic ordering.
		return table.concat(texts(views.render({ pane = 42, alias_nonce = f.origin.alias_nonce, orch_session_id = f.origin.logical_session_id, action_serial = 0,
			workflow_worker = worker_id, advanced_open = true, config_open = true }, projection, "ready"), {}), "\n")
	end
	-- Open questions precede settled evidence in numeric creation order; neither
	-- diagnostic wording nor an obsolete two-item page defines that contract.
	local owner = w:worker()
	local all = render(w.f, w.id, function(workflow)
		for index = #workflow.gates, 1, -1 do if workflow.gates[index].worker_id == w.id then table.remove(workflow.gates, index) end end
		for _, row in { { 7, "resolved" }, { 8, "superseded" }, { 9, "pending" }, { 10, "pending" } } do
			table.insert(workflow.gates, { id = "gate-" .. row[1], revision = 1, worker_id = w.id, worker_generation = owner.worker_generation, work_id = owner.work_id,
				kind = "shared_checkout", phase = row[2], question = "Fixture question " .. row[1], options = { { id = "acknowledge", label = "Understood" } }, evidence = {} })
		end
		table.sort(workflow.gates, function(a, b) return a.id < b.id end)
	end)
	local nine, ten = all:find("Fixture question 9", 1, true), all:find("Fixture question 10", 1, true)
	local seven, eight = all:find("Fixture question 7", 1, true), all:find("Fixture question 8", 1, true)
	check(nine ~= nil and ten ~= nil and seven ~= nil and eight ~= nil and nine < ten and ten < seven and seven < eight,
		"open questions precede settled evidence, with numeric creation order within each group")
	-- Continuation is offered only for a generation launched before a reload.
	local CONTINUE = "Continue after reload / reattach explicitly…"
	check(render(w.f, w.id):find(CONTINUE, 1, true) == nil, "a freshly launched worker offers no continuation")
	check(render(w.f, gated.worker_id):find(CONTINUE, 1, true) == nil, "never-launched work offers no continuation")
	w:reload(); w:palette("continue_controller"); w:pick({ continue_controller = true }); assert(w:outcome().ok)
	w.f.origin = clone(w.events[#w.events].origin)
	check(render(w.f, w.id):find(CONTINUE, 1, true) ~= nil, "a worker launched before the reload offers explicit continuation")
	-- CP2 live smoke stall: a worker's backpressured action waited ~10 min while the source's command
	-- driver held another lane. Its code-only recheck needs only its own lane free.
	local r = window_fixture()
	local read = r.f:apply("poll", { worker_id = r.id }); assert(read.ok and read.action_id, read.message)
	check(r.f:finish(read.action_id, "full", { resource = "capacity_admission", current = 1, limit = 1, retryable = true, effect_started = false }).code == "backpressure",
		"SPAWN's capacity_admission refusal backpressures the worker's read")
	local cat = r.f:apply("catalog"); assert(cat.ok and cat.action_id, cat.message)
	assert(r.f:apply("claim", { action_id = cat.action_id, executor = r.f.origin.window_epoch }).ok)
	local held = r.f:action(cat.action_id)
	assert(r.f:apply("lost", { action_id = cat.action_id, executor = held.claim.executor, grant_id = held.claim.grant_id }).ok)
	r:bridge(peer_body(held.request, "pending", nil))
	r:click("reconcile", { action_id = cat.action_id }) -- The owner's read holds the source's command driver (catalog lane).
	local retried = nil
	for tick = 1, 30 do
		r:tick()
		for _, e in r.events do if e.command == "retry" and e.action_id == read.action_id then retried = retried or tick end end
		if retried then break end
	end
	check(retried ~= nil and r.f:action(cat.action_id).phase == "uncertain",
		"the worker's capacity recheck is sent after its backoff while the command driver still holds the catalog read")
end
-- Checkpoint 7 (D17): the selected worker's health card shows the account USAGE delta row from the
-- projected usage_before/usage_after/usage_shared_with — pending, a delta, or "not comparable".
if section == nil or section == "usage_row" then
	local f = shared.fixture(function() return { now_ms = 1700000000000, mono_ms = 1000, epoch = "usage-host" } end)
	local id = f:accepted(false)
	local views = shared.load("views")
	local NOW = 1700000000000
	local function reading(at, five, opts)
		opts = opts or {}
		return { account = { canonical_ids = opts.ids or { "claude:native" }, generation = opts.generation or 2 }, observed_at_ms = at,
			windows = { { key = "five_hour", pool = "default", remaining = five, observed_at_ms = at, resets_at_ms = opts.reset or NOW + 3600000 } } }
	end
	local function card(patch, advanced)
		local w = f.authority.registry.dispatch.workers[id]
		w.usage_before, w.usage_after = patch.before, patch.after
		local projection = state.project(f.authority.registry)
		projection.dispatch = dispatch.project(f.authority.registry, f.origin.logical_session_id, f.origin.alias_nonce)
		if patch.shared ~= nil then for _, pw in projection.dispatch.workflow.workers do if pw.worker_id == id then pw.usage_shared_with = patch.shared end end end
		local out = {}
		local function walk(node)
			if type(node) ~= "table" then return end
			if type(node.p) == "table" and type(node.p.role) == "string" and node.p.role:sub(1, 9) == "orchplus." then return end
			for key, value in node do
				if type(value) == "string" and (key == "t" or key == "text" or type(key) == "number") then table.insert(out, value) elseif key ~= "actions" then walk(value) end
			end
		end
		walk(views.render({ pane = 42, alias_nonce = f.origin.alias_nonce, orch_session_id = f.origin.logical_session_id, action_serial = 0,
			workflow_worker = id, config_open = false, advanced_open = advanced ~= false },
			projection, "ready"))
		return table.concat(out, "\n")
	end
	local function has(all, text) return all:find(text, 1, true) ~= nil end
	local projected
	card({ before = reading(NOW, 70) })
	for _, pw in dispatch.project(f.authority.registry, f.origin.logical_session_id, f.origin.alias_nonce).workflow.workers do if pw.worker_id == id then projected = pw end end
	check(projected and projected.usage_before and projected.usage_before.observed_at_ms == NOW and projected.usage_after == nil and type(projected.usage_shared_with) == "number",
		"the projection carries usage_before, no usage_after while running, and an integer usage_shared_with")
	local none = card({})
	check(not has(none, "Account delta while this worker ran"), "no usage_before → no usage row")
	local pending = card({ before = reading(NOW, 70), shared = 0 })
	check(has(pending, "Account delta while this worker ran") and has(pending, "pending until the worker finishes") and has(pending, "account-wide, not this worker's exact use"),
		"running worker: the row says pending and account-wide")
	check(not has(card({ before = reading(NOW, 70), shared = 0 }, false), "Account delta while this worker ran"),
		"normal conversation UI does not expose the selected worker's technical account-delta diagnostic")
	local delta = card({ before = reading(NOW, 70), after = reading(NOW + 60000, 55), shared = 2 })
	check(has(delta, "five_hour|default: +15 pts used") and has(delta, "shared with 2 other workers on this account"), "comparable: delta in points, shared with N others")
	local one = card({ before = reading(NOW, 70), after = reading(NOW + 60000, 55), shared = 1 })
	check(has(one, "shared with 1 other worker on this account"), "one other worker is singular")
	local crossed = card({ before = reading(NOW, 70), after = reading(NOW + 60000, 95, { reset = NOW + 7200000 }), shared = 0 })
	check(has(crossed, "not comparable (a quota reset happened in between)") and not has(crossed, "pts used"), "reset crossed: not comparable with the reason")
	local other = card({ before = reading(NOW, 70), after = reading(NOW + 60000, 55, { ids = { "claude:other" } }) })
	check(has(other, "not comparable (the readings are from different accounts)"), "different account: not comparable with the reason")
	local stale = card({ before = reading(NOW, 70), after = reading(NOW, 55) })
	check(has(stale, "not comparable (a reading is stale or missing)"), "stale after-reading: not comparable with the reason")
	for _, all in { pending, delta, crossed } do check(all:find("%f[%a]nil%f[%A]") == nil and all:find("%f[%a]null%f[%A]") == nil, "the usage row never renders raw nil/null") end
end
if section == nil or section == "guided_recovery" then
	local w = window_fixture({ no_admission = true })
	assert(w.f:apply("policy", { policy = { sweep_enabled = false } }).ok)
	w:bridge({ placeholder = true }); w:owner_answer("absent")
	local next_admission = w.f.authority.registry.next_admission_seq
	local owner = clone(w.f.authority.registry.sessions[w.f.origin.logical_session_id].controller)
	for _ = 1, 12 do
		w:tick()
		local session = w.f.authority.registry.sessions[w.f.origin.logical_session_id]
		if session.admitted and not session.bridge_control then break end
	end
	local session, admissions = w.f.authority.registry.sessions[w.f.origin.logical_session_id], 0
	local query = w:bridge_events()[1]
	check(query.op == "owner_status" and query.admission_seq == next_admission,
		"first-admission inspection uses the current next sequence without reserving another admission")
	for _, event in w:bridge_events() do
		if event.op == "admit_session" then admissions += 1
		else check(event.op == "owner_status", "routine first reconnect performs only owner inspection and its normal admission") end
	end
	check(admissions == 1 and session.admitted and session.admission_seq == next_admission and w:picker() == nil,
		"automatic current-owner inspection admits once without a navigation wizard")
	check(shared.quota.digest(session.controller) == shared.quota.digest(owner) and flow(w.f).policy.paused
		and next(w.f.authority.registry.dispatch.workers) == nil,
		"routine connection preserves ownership, pause and existing work permissions; it launches nothing")
end
if section == nil or section == "guided_recovery" then
	local w = window_fixture({ defer_continuation = true })
	w:bridge({ placeholder = true }); w:owner_answer("previous_incarnation")
	local sid, id = w.f.origin.logical_session_id, w.id
	local previous = clone(w.f.authority.registry.dispatch.command_cursors[sid].origin)
	local mailbox = w.f.authority.registry.dispatch.workers[id].mailbox_handle
	w:reload(); w:tick()
	local continuation
	for _, event in w.events do if event.command == "continue_controller" then continuation = event end end
	check(continuation and continuation.machine_proof and not continuation.operator_verified
		and shared.quota.digest(continuation.machine_proof.previous_origin) == shared.quota.digest(previous),
		"reload submits only the exact retained native route proof, never a fabricated stop attestation")
	check(w.f.authority.registry.dispatch.command_cursors[sid].origin.window_epoch == previous.window_epoch,
		"unacknowledged continuation does not replace the durable route")
	assert(w:deliver_continuation().ok)
	for _ = 1, 12 do w:tick() end
	local continued = w.f.authority.registry.dispatch.command_cursors[sid].origin
	check(continued.window_epoch ~= previous.window_epoch and w.f.authority.registry.dispatch.workers[id].mailbox_handle == mailbox,
		"confirmed route replacement preserves the existing worker and its communication identity")
	for _, event in w:bridge_events() do check(event.op ~= "launch" and event.op ~= "enrol" and event.op ~= "adopt", "routine reload never replays conversation creation") end
end
if section == nil or table.find({ "reconnect_stale", "reconnect_missing", "reconnect_unknown", "reconnect_unrelated" }, section) then
	-- Fault the native receipt boundary after a real concurrent authority commit,
	-- not the continuation reducer: only its exact positive stale refusal permits
	-- a newly fenced attempt. Lost, unknown and unrelated receipts stay held.
	for _, delivery in { "matched", "missing", "unknown", "unrelated" } do
		local selector = if delivery == "matched" then "reconnect_stale" else "reconnect_" .. delivery
		if section ~= nil and section ~= selector then continue end
		local armed, raced = false, false
		local recovered = window_fixture({ hold_poll = true, before_authority = function(fixture, input)
			if armed and not raced and input.command == "continue_controller" then
				raced = true
				assert(fixture.authority:apply(fixture:state_event("register_session", {
					orch_session_id = "concurrent-registration", name = "Concurrent registration" })).ok)
			end
		end })
		local fixture, worker_id = recovered.f, recovered.id
		local session_id = fixture.origin.logical_session_id
		local before = fixture.authority.registry.sessions[session_id]
		local owner_id, generation, admission = before.controller.owner_id, before.controller.generation, before.admission_seq
		local retained_mailbox = fixture.authority.registry.dispatch.workers[worker_id].mailbox_handle
		fixture.authority = shared.host.new_authority(fixture.memory, function()
			return { now_ms = 1700000000000, mono_ms = 5000, epoch = "health-continuation-" .. delivery }
		end)
		assert(fixture.authority:load().ok)
		recovered:bridge({ placeholder = true }); recovered:owner_answer("previous_incarnation")
		recovered:reload(); armed = true; recovered:tick()
		local refused = assert(recovered:outcome())
		assert(raced and refused.command == "continue_controller" and refused.ok == false and refused.code == "stale_revision",
			"fixture must deliver a real stale refusal caused by the intervening registration")
		local original_request = refused.request_id
		if delivery == "missing" then for key in refused do refused[key] = nil end
		elseif delivery == "unknown" then refused.code = "effect_uncertain"
		elseif delivery == "unrelated" then refused.request_id = "another-continuation-request" end
		for _ = 1, 20 do recovered:tick() end
		local attempts = {}
		for _, event in recovered.events do if event.command == "continue_controller" then table.insert(attempts, event) end end
		local current = fixture.authority.registry.sessions[session_id]
		if delivery == "matched" then
			local projected = dispatch.project(fixture.authority.registry, session_id, fixture.origin.alias_nonce)
			check(#attempts == 2 and attempts[1].request_id == original_request
				and attempts[2].request_id ~= original_request and attempts[2].expected_revision > attempts[1].expected_revision
				and current.controller.phase == "active" and projected.session_control.admitted == true,
				"an exact stale refusal progresses through one fresh same-owner continuation and verified admission")
		else
			check(#attempts == 1 and attempts[1].request_id == original_request and current.controller.phase == "uncertain",
				"missing, unknown and unrelated stale receipts cannot reissue the pending controller continuation")
		end
		check(current.controller.owner_id == owner_id and current.controller.generation == generation and current.admission_seq == admission
			and fixture.authority.registry.dispatch.workers[worker_id].mailbox_handle == retained_mailbox,
			"continuation receipt recovery preserves owner identity, admission and accepted worker membership")
		for _, event in recovered:bridge_events() do
			check(event.op ~= "mailbox_provision" and event.op ~= "launch" and event.op ~= "enrol" and event.op ~= "adopt",
				"continuation receipt recovery cannot duplicate a provider or conversation effect")
		end
	end
end
if section == nil or section == "worker_attachment" or section == "worker_attachment_form" then
	-- Exercise the queued attachment itself, both without UI and with ordinary
	-- navigation opened before the authorized queue commits.
	for _, navigation in { false, true } do
		if section ~= nil and section ~= (if navigation then "worker_attachment_form" else "worker_attachment") then continue end
		local subject, armed, opened = nil, false, false
		subject = window_fixture({ hold_poll = true, commit_results = true,
			before_authority = function(_, input)
				if armed and navigation and not opened and input.command == "continue_worker" then
					opened = true
					subject:click("orchestration_menu")
				end
			end,
			attachment_handler = function(_, request)
				return shared.frame(request, "attached", { pane_binding = request.pane_binding,
					previous_origin_binding = request.previous_origin_binding, previous_pane_binding = request.previous_pane_binding })
			end })
		local fixture, worker_id = subject.f, subject.id
		local original = subject:worker()
		local original_pane = original.pane_binding.pane_id
		local retained_mailbox = fixture.authority.registry.dispatch.workers[worker_id].mailbox_handle
		subject:bridge({ placeholder = true }); subject:owner_answer("previous_incarnation")
		subject:reload(); armed = true
		for _ = 1, 20 do subject:tick() end
		local continued = subject:worker()
		local decisions, attachments = 0, 0
		for _, event in subject.events do if event.command == "continue_worker" then decisions += 1 end end
		for _, request in subject:bridge_events() do
			if request.op == "attach_worker" then attachments += 1 end
			check(request.op ~= "mailbox_provision" and request.op ~= "launch" and request.op ~= "enrol" and request.op ~= "adopt",
				"worker route recovery never recreates its accepted conversation")
		end
		check(decisions == 1 and attachments == 1 and continued.phase == "accepted"
			and continued.continuation_required ~= true and continued.reattach_needed ~= true
			and continued.pane_binding.pane_id == original_pane
			and fixture.authority.registry.dispatch.workers[worker_id].mailbox_handle == retained_mailbox,
			"one automatic continuation drives its own exact attachment once and preserves the live accepted worker")
		check(not navigation or (opened and subject:picker() ~= nil),
			"already-authorized route attachment completes while ordinary navigation remains open")
	end
end
-- The owner finishes the fixture's ordinary worker up to its verified native stop (as `finish` does).
local function stop_worker(w, observation)
	w:click("finish", { worker_id = w.id }); w:pick({ finish = true }); assert(w:outcome().ok)
	local worker = w.f.authority.registry.dispatch.workers[w.id]
	local mark = { version = 1, type = "receipt_watermark", mailbox_handle = worker.mailbox_handle,
		through_seq = worker.accepted_seq, receipt_chain_sha256 = worker.receipt_chain }
	for _, key in { "logical_session_id", "worker_id", "worker_generation", "launch_request_id", "work_id", "enrolment_token" } do mark[key] = worker[key] end
	local read = w.f:apply("poll", { worker_id = w.id, bytes = "watermark" }); assert(read.ok)
	local page = assert(shared.codec.project_page(runtime.json.encode(mark), w.f:action(read.action_id).request.selector))
	assert(w.f:finish(read.action_id, "read", runtime.json.decode(page)).ok)
	local stop = w.f:apply("poll", { worker_id = w.id })
	local request = w.f:action(stop.action_id).request
	assert(request.op == "stop", request.op)
	assert(w.f:finish(stop.action_id, "stopped", { pane_binding = request.pane_binding, observation = observation }).ok)
end
if section == nil or section == "guided_recovery_empty" then
	local w = window_fixture({ no_worker = true })
	w:bridge({ placeholder = true }); w:owner_answer("current")
	local sid = w.f.origin.logical_session_id
	local admission = w.f.authority.registry.sessions[sid].admission_seq
	for _ = 1, 8 do w:tick() end
	check(w:picker() == nil and w.f.authority.registry.sessions[sid].admission_seq == admission,
		"a healthy connection needs no routine choice or replacement admission")
	for _, event in w:bridge_events() do check(event.op ~= "launch" and event.op ~= "admit_session", "healthy observation cannot create work or duplicate admission") end
end
if section == nil or section == "guided_recovery_host_restart" then
	local w = window_fixture(); w:bridge({ placeholder = true }); w:owner_answer("current")
	local sid, id = w.f.origin.logical_session_id, w.id
	local before = w.f.authority.registry.sessions[sid]
	local owner, generation, admission = before.controller.owner_id, before.controller.generation, before.admission_seq
	local mailbox = w.f.authority.registry.dispatch.workers[id].mailbox_handle
	w.f.authority = shared.host.new_authority(w.f.memory, function() return { now_ms = 1700000000000, mono_ms = 5000, epoch = "health-host-restarted" } end)
	assert(w.f.authority:load().ok)
	for _ = 1, 16 do w:tick() end
	local current = w.f.authority.registry.sessions[sid]
	check(current.controller.owner_id == owner and current.controller.generation == generation and current.admission_seq == admission,
		"host restart reconnects the existing owner and admission rather than creating replacements")
	check(current.controller.phase == "active" and w.f.authority.registry.dispatch.workers[id].mailbox_handle == mailbox,
		"machine-verifiable host restart preserves worker membership and reaches a current controller")
	for _, event in w.events do if event.command == "continue_controller" then check(event.machine_proof and not event.operator_verified, "automatic controller recovery never invents human consent") end end
	for _, event in w:bridge_events() do check(event.op ~= "launch" and event.op ~= "enrol" and event.op ~= "adopt", "host restart never relaunches a retained conversation") end
end
-- A stopped or retired worker reads as such after a host restart; a live worker keeps its phase.
if section == nil or section == "stopped_worker_view" then
	local views = shared.load("views")
	local function texts(node, out)
		if type(node) ~= "table" then return out end
		if type(node.p) == "table" and type(node.p.role) == "string" and node.p.role:sub(1, 9) == "orchplus." then return out end
		for key, value in node do
			if type(value) == "string" then
				if key == "t" or key == "text" or key == "label" or type(key) == "number" then table.insert(out, value) end
			elseif key ~= "actions" then texts(value, out) end
		end
		return out
	end
	local function render(f, advanced)
		local projection = state.project(f.authority.registry)
		projection.dispatch = dispatch.project(f.authority.registry, f.origin.logical_session_id, f.origin.alias_nonce)
		return texts(views.render({ pane = 42, alias_nonce = f.origin.alias_nonce, orch_session_id = f.origin.logical_session_id,
			action_serial = 0, advanced_open = advanced ~= false }, projection, "ready"), {})
	end
	local function count(lines, needle) local n = 0; for _, line in lines do if line:find(needle, 1, true) then n += 1 end end; return n end
	-- The worker's own row (other rows, e.g. actions, may also print phases).
	local function row_of(lines, prefix) for _, line in lines do if line:find(prefix, 1, true) == 1 then return line end end; return nil end
	local function exported(f, worker_id)
		local row = dispatch.project(f.authority.registry, f.origin.logical_session_id, f.origin.alias_nonce).workers[worker_id]
		return if row then "phase=" .. tostring(row.phase) .. " stop_status=" .. tostring(row.stop_status) .. " mailbox_status=" .. tostring(row.mailbox_status) else "no projected worker"
	end
	local function work_id_of(fw) return fw.f.authority.registry.dispatch.workers[fw.id].work_id end
	local function restart(w)
		w.f.authority = shared.host.new_authority(w.f.memory, function() return { now_ms = 1700000000000, mono_ms = 5000, epoch = "stopped-view-restarted" } end)
		assert(w.f.authority:load().ok)
	end
	local w = window_fixture()
	local work_id = w.f.authority.registry.dispatch.workers[w.id].work_id
	local row = work_id .. " / " .. w.id .. " · "
	stop_worker(w, "absent")
	local settled = tostring(w.f.authority.registry.dispatch.workers[w.id].stopped and w.f.authority.registry.dispatch.workers[w.id].stopped.observation)
	restart(w)
	local lines = render(w.f)
	local shown_row = row_of(lines, row)
	check(shown_row ~= nil and shown_row:find(" · stopped · ", 1, true) ~= nil and shown_row:find(" · accepted · ", 1, true) == nil,
		"after restore a stopped worker shows stopped, not its recorded accepted phase; row=" .. tostring(shown_row)
			.. " | before restore stopped.observation=" .. settled .. " | projected " .. exported(w.f, w.id))
	check(count(lines, "Native stop: absent · mailbox: ") + count(lines, "native stop absent") == 1,
		"the native stop line is shown once for an ordinary worker; lines=" .. table.concat(lines, " ¦ "))
	check(row_of(render(w.f, false), row) == nil and count(render(w.f, false), "Native stop:") == 0,
		"normal conversation UI hides technical worker identity and native-stop evidence; Advanced preserves it")
	local done = window_fixture()
	stop_worker(done, "absent")
	local retire = done.f:apply("poll", { worker_id = done.id }); assert(retire.ok, retire.message)
	assert(done.f:action(retire.action_id).request.op == "mailbox_retire")
	assert(done.f:finish(retire.action_id, "retired", {}).ok)
	local retired_row = row_of(render(done.f), work_id_of(done) .. " / " .. done.id .. " · ")
	check(done.f.authority.registry.dispatch.workers[done.id].mailbox_retired == true and retired_row ~= nil and retired_row:find(" · retired · ", 1, true) ~= nil,
		"a retired worker shows retired; row=" .. tostring(retired_row) .. " | projected " .. exported(done.f, done.id))
	local live = window_fixture()
	local live_row = row_of(render(live.f), work_id_of(live) .. " / " .. live.id .. " · ")
	check(live_row ~= nil and live_row:find(" · accepted · ", 1, true) ~= nil and count(render(live.f), "Native stop:") == 0,
		"a live accepted worker still shows accepted, with no native stop line; row=" .. tostring(live_row) .. " | projected " .. exported(live.f, live.id))
end
-- SPAWN reports an unconsumed window challenge past its deadline (or from an earlier host VM) as
-- definitive pre-effect `full`; that evidence turns a lost/uncertain native wake into recheckable
-- backpressure, while uncertainty without it is never retryable.
if section == nil or section == "expired_wake" then
	local w = window_fixture()
	local f, id = w.f, w.id
	assert(f:apply("intake", { worker_id = id, bytes = f:report(id, 2, "HEARTBEAT", { state = "idle" }) }).ok)
	local publication = f:apply("poll", { worker_id = id })
	local publication_request = f:action(publication.action_id).request
	assert(f:finish(publication.action_id, "published", { wake_status = "awaiting_window", wake_effect_started = false,
		wake_target_request_id = publication_request.request_id, wake_target_action_id = publication_request.action_id }).ok)
	w:click("inspect_worker", { worker_id = id })
	local wake = f:apply("poll", { worker_id = id }); assert(wake.ok)
	local wake_id = wake.action_id
	assert(f:action(wake_id).request.op == "native_wake", "fixture must queue the retained native wake")
	assert(f:apply("claim", { action_id = wake_id, executor = f.origin.window_epoch }).ok)
	local request, request_bytes = clone(f:action(wake_id).request), f:action(wake_id).request_bytes
	local grant = clone(f:action(wake_id).claim)
	local function settle(status, payload, problem)
		return f:apply("result", { action_id = wake_id, executor = grant.executor, grant_id = grant.grant_id, response_bytes = shared.frame(request, status, payload, problem) })
	end
	check(f:apply("lost", { action_id = wake_id, executor = grant.executor, grant_id = grant.grant_id }).ok and f:action(wake_id).phase == "uncertain",
		"a wake whose SPAWN challenge was never consumed before the ORCH+ deadline is retained as uncertain")
	check(f:apply("retry", { action_id = wake_id }).code == "retry_refused", "an uncertain native wake without pre-effect evidence is never retryable")
	check(settle("pending", { authorization_required = true }).code == "pending" and f:action(wake_id).phase == "uncertain",
		"a still-live SPAWN challenge is not evidence; the wake stays uncertain")
	check(settle("uncertain", nil, { code = "target_unavailable", message = "Native effect outcome uncertain; do not retry" }).code == "effect_uncertain"
		and f:action(wake_id).phase == "uncertain" and f:apply("retry", { action_id = wake_id }).code == "retry_refused",
		"a retained uncertain SPAWN outcome keeps the wake uncertain and unretryable")
	local refused = settle("full", { resource = "window_authorization", current = 1, limit = 1, retryable = true, effect_started = false })
	check(refused.ok and refused.code == "backpressure" and f:action(wake_id).phase == "backpressure" and f:action(wake_id).response_grant == grant.grant_id,
		"SPAWN's expired-authorization status on the uncertain wake commits retryable pre-effect backpressure")
	local retried = f:apply("retry", { action_id = wake_id })
	local fresh = retried.ok and f:action(retried.action_id)
	check(fresh and retried.action_id ~= wake_id and f:action(wake_id) == nil and fresh.phase == "ready"
		and fresh.claim == nil and fresh.request_bytes == nil and fresh.request.request_id ~= request.request_id,
		"a definite pre-effect refusal settles the old issued request and queues a distinct unissued intent")
	check(f:apply("claim", { action_id = retried.action_id, executor = f.origin.window_epoch }).ok
		and f:action(retried.action_id).claim.grant_id ~= grant.grant_id
		and f:action(retried.action_id).request.request_serial > request.request_serial,
		"the fresh attempt allocates a later serial only at its new claim")
end
-- SPAWN owner recovery revokes a never-consumed authorization: definitively pre-effect, so the
-- worker is not held and the same obligation is re-issued; semantic rejections still hold, and a
-- held worker's recorded cause survives later non-holding transport diagnostics.
if section == nil or section == "revoked_authorization" then
	local REVOKED = "Controller recovery revoked the unconsumed authorization"
	local function worker(f, id) return f.authority.registry.dispatch.workers[id] end
	local function reject(f, action_id, problem)
		local a = f:action(action_id)
		return f:apply("result", { action_id = action_id, executor = a.claim.executor, grant_id = a.claim.grant_id, response_bytes = shared.frame(a.request, "rejected", nil, problem) })
	end
	local function wake_fixture()
		local w = window_fixture()
		local f, id = w.f, w.id
		assert(f:apply("intake", { worker_id = id, bytes = f:report(id, 2, "HEARTBEAT", { state = "idle" }) }).ok)
		local publication = f:apply("poll", { worker_id = id })
		local publication_request = f:action(publication.action_id).request
		assert(f:finish(publication.action_id, "published", { wake_status = "awaiting_window", wake_effect_started = false,
			wake_target_request_id = publication_request.request_id, wake_target_action_id = publication_request.action_id }).ok)
		w:click("inspect_worker", { worker_id = id })
		local wake = f:apply("poll", { worker_id = id }); assert(wake.ok, wake.message)
		assert(f:action(wake.action_id).request.op == "native_wake", "fixture must queue the retained native wake")
		assert(f:apply("claim", { action_id = wake.action_id, executor = f.origin.window_epoch }).ok)
		return f, id, wake.action_id, publication_request.action_id
	end
	local f, id, wake_id, target_id = wake_fixture()
	local revoked = reject(f, wake_id, { code = "authorization_revoked", message = REVOKED })
	check(revoked.ok and revoked.code == "authorization_reissue" and worker(f, id).phase == "accepted" and f:action(wake_id) == nil,
		"a revoked never-consumed native wake authorization completes its action without holding the worker")
	local obligation = (worker(f, id).wakes or {})[target_id]
	check(obligation ~= nil and obligation.action_id == nil, "the wake obligation is retained and released for re-issue")
	local fresh = f:apply("poll", { worker_id = id }); assert(fresh.ok, fresh.message)
	local reissued = f:action(fresh.action_id).request
	check(fresh.action_id ~= wake_id and reissued.op == "native_wake" and reissued.target_action_id == target_id
		and worker(f, id).wakes[target_id].action_id == fresh.action_id, "a later poll grants a fresh native wake for the same obligation")
	check(state.rehydrate(clone(f.authority.registry)) ~= nil, "the re-issued wake obligation restores")
	-- A stale wake reference is corruption, not a request to reconstruct historical execution.
	local lf, lid, lwake, ltarget = wake_fixture()
	assert(reject(lf, lwake, { code = "authorization_revoked", message = REVOKED }).ok)
	local invalid = clone(lf.authority.registry)
	invalid.dispatch.workers[lid].wakes[ltarget].action_id = lwake
	check(state.rehydrate(invalid) == nil, "a consumed action cannot be resurrected through an old wake marker")
	local sf, sid, swake = wake_fixture()
	local semantic = reject(sf, swake, { code = "binding_mismatch", message = "Wake publication no longer matches its explicitly attached worker" })
	check(semantic.code == "bridge_rejected" and worker(sf, sid).phase == "held" and worker(sf, sid).reason.code == "binding_mismatch",
		"a semantic (non-revoked) native wake rejection still holds the worker")
	local hold = window_fixture()
	local hf, hid = hold.f, hold.id
	local read = hf:apply("poll", { worker_id = hid, bytes = "watermark" }); assert(read.ok, read.message)
	assert(hf:apply("claim", { action_id = read.action_id, executor = hf.origin.window_epoch }).ok)
	local cause = { code = "binding_mismatch", message = "Mailbox generation differs from the issued enrolment" }
	check(reject(hf, read.action_id, cause).code == "bridge_rejected" and worker(hf, hid).phase == "held", "a semantic read rejection holds the worker")
	local again = hf:apply("poll", { worker_id = hid, bytes = "watermark" }); assert(again.ok, again.message)
	check(hf:finish(again.action_id, "full", { resource = "mailbox_read", current = 1, limit = 1 }).code == "transport_backpressure"
		and worker(hf, hid).phase == "held" and worker(hf, hid).reason.code == cause.code and worker(hf, hid).reason.message == cause.message,
		"a later transport full never overwrites the held worker's recorded cause")
end
-- Sequenced window observations: unchanged evidence commits nothing, changed evidence commits,
-- no observation outcome is retained, and no replay (live or after pruning) regresses evidence.
if section == nil or section == "observe_retention" then
	local now = 1000
	local f = shared.fixture(function() return { now_ms = 1700000000000, mono_ms = now, epoch = "retention-host" } end)
	assert(f:apply("policy", { policy = { report_request_ms = 60000, stale_ms = 180000 } }).ok)
	local id = f:accepted(false)
	local binding = clone(f.authority.registry.dispatch.workers[id].pane_binding)
	local seq = 0
	local function observation(native)
		seq += 1
		return f:event("observe", { worker_id = id, pane_binding = clone(binding), native_state = native, observation_seq = seq })
	end
	local function no_history() return f.authority.registry.dispatch.commands == nil end
	local first = observation("idle")
	check(f.authority:apply(first).ok and no_history() and health(f, id).native_state == "idle",
		"a sequenced observation commits its evidence without retaining a command outcome")
	local retained = f.authority.registry.dispatch.workers[id].workflow.observation_cursor.event
	check(retained.authority_namespace == first.authority_namespace and retained.expected_revision == first.expected_revision
		and retained.expected_revision < f.authority.registry.revision,
		"sequenced observation retains its exact captured authority fence, never a refreshed revision")
	check(state.rehydrate(clone(f.authority.registry)) ~= nil, "committed sequenced observation restores with its captured authority fence")
	for _, corruption in { "namespace", "missing_namespace", "missing_revision", "current_revision", "future_revision" } do
		local invalid = clone(f.authority.registry)
		local event = invalid.dispatch.workers[id].workflow.observation_cursor.event
		if corruption == "namespace" then event.authority_namespace = "foreign-authority"
		elseif corruption == "missing_namespace" then event.authority_namespace = nil
		elseif corruption == "missing_revision" then event.expected_revision = nil
		elseif corruption == "current_revision" then event.expected_revision = invalid.revision
		else event.expected_revision = invalid.revision + 1 end
		check(state.rehydrate(invalid) == nil, corruption .. ": persisted observation cannot invent or discard its captured authority")
	end
	local revision, writes = f.authority.registry.revision, f.memory.writes
	now += 5000
	local unchanged = observation("idle")
	local answer = f.authority:apply(unchanged)
	check(answer.ok and answer.code == "observation_recorded" and no_history() and f.authority.registry.revision == revision
		and f.memory.writes == writes, "an unchanged observation grows no command history, bumps no revision and writes nothing")
	now += 1000
	local changed = observation("working")
	check(f.authority:apply(changed).ok and f.authority.registry.revision == revision + 1 and health(f, id).native_state == "working"
		and no_history(), "a changed observation still commits its new evidence")
	revision = f.authority.registry.revision
	now += 180000 / 4 + 1000 -- Past the default stale_ms/4 refresh bound.
	check(f.authority:apply(observation("working")).ok and f.authority.registry.revision == revision + 1,
		"unchanged evidence is still re-stamped before it could go stale")
	revision = f.authority.registry.revision
	local before = runtime.json.encode(f.authority.registry)
	check(f.authority:apply(clone(first)).code == "stale_revision" and runtime.json.encode(f.authority.registry) == before
		and health(f, id).native_state == "working", "replaying an older observation cannot regress newer evidence")
	check(f.authority:apply(clone(unchanged)).code == "stale_revision" and runtime.json.encode(f.authority.registry) == before,
		"replaying an older unchanged observation is refused too")
	local invalid = clone(f.authority.registry)
	invalid.dispatch.commands = { [first.request_id] = { event = clone(first), result = { ok = true, code = "observation_recorded" }, revision = revision } }
	check(state.rehydrate(invalid) == nil, "current schema rejects resurrected completed command history")
	local clock = { now_ms = 1700000000000, mono_ms = now + 1000, epoch = "retention-host" }
	local next_change = observation("idle")
	local updated = assert(state.apply(f.authority.registry, next_change, clock))
	check(updated.dispatch.commands == nil, "current evidence needs no command history")
	local replayed, refusal = state.apply(updated, clone(first), clock)
	check(replayed == nil and refusal.code == "stale_revision" and updated.dispatch.workers[id].workflow.native.state == "idle",
		"an old captured observation cannot rewrite current evidence")
	local again, replay_result = state.apply(updated, clone(next_change), clock)
	check(again == nil and replay_result.code == "stale_revision", "lost observation response is reconciled read-only, never re-executed with a new fence")
end
-- Live reload defect: a mailbox_read claimed by the previous window incarnation, never staged in
-- SPAWN, stayed uncertain forever and refused the coordinator's explicit reattachment. A read
-- changes nothing until its outcome commits: SPAWN's `missing` status resolves it, an attested
-- attachment supersedes it while SPAWN stays ambiguous, and mutating effects keep their holds.
if section == nil or section == "uncertain_read" then
	local function worker(f, id) return f.authority.registry.dispatch.workers[id] end
	local function controller(f) return f.authority.registry.sessions[f.origin.logical_session_id].controller end
	local function continued_reload(f)
		f.authority = shared.host.new_authority(f.memory); assert(f.authority:load().ok)
		f.origin.window_epoch = "replacement-window"; f.controller_pane = "9010"
		assert(f:apply("continue_controller", { expected_revision = f.authority.registry.revision, operator_verified = true }).ok)
		assert(f:control("reconcile_session").ok)
	end
	local function attach(f, id, pane_id)
		local pane = { pane_id = pane_id, window_key = f.origin.window_key, window_epoch = f.origin.window_epoch,
			native_session_id = f.origin.native_session_id, window_host_id = f.origin.window_host_id }
		local attached = f:apply("continue_worker", { worker_id = id, pane_binding = pane,
			continuation_proof = dispatch.continuation_proof(f.authority.registry, worker(f, id)), operator_verified = true })
		if not attached.ok then return attached end
		local original = worker(f, id)
		return f:finish(attached.action_id, "attached", { pane_binding = pane,
			previous_origin_binding = clone(original.origin_binding), previous_pane_binding = clone(original.pane_binding) })
	end
	local function status_query(f, request, controller_pane)
		return { schema = 2, origin = "orchplus", op = "status", request_id = "status-probe", action_id = "status-probe-action",
			authority_namespace = request.authority_namespace, logical_session_id = request.logical_session_id, admission_seq = request.admission_seq,
			origin_binding = clone(f.origin), controller_pane = controller_pane, controller_generation = f.origin.owner_generation,
			target_request_id = request.request_id, target_request_serial = request.request_serial }
	end
	-- Plugin reload (host and window) with a report read claimed by the previous incarnation.
	local w = window_fixture()
	local f, id = w.f, w.id
	local read = f:apply("poll", { worker_id = id }); assert(read.ok, read.message)
	assert(f:action(read.action_id).request.op == "mailbox_read")
	assert(f:apply("claim", { action_id = read.action_id, executor = f.origin.window_epoch }).ok)
	local request, claim = clone(f:action(read.action_id).request), clone(f:action(read.action_id).claim)
	f.authority = shared.host.new_authority(f.memory, function() return { now_ms = 1700000000000, mono_ms = 5000, epoch = "uncertain-read-host" } end)
	assert(f.authority:load().ok)
	w:reload()
	w:bridge({ placeholder = true }); w:bridge_missing(true)
	w:palette("continue_controller"); w:pick({ continue_controller = true }); assert(w:outcome().ok)
	f.origin = clone(w.events[#w.events].origin)
	assert(f:control("reconcile_session").ok)
	local executors = controller(f).pending_executors
	check(f:action(read.action_id).phase == "uncertain" and executors >= 1 and worker(f, id).continuation_required,
		"reload retains the previous incarnation's claimed read as uncertain executor occupancy")
	local query = status_query(f, request, f.controller_pane or "9001")
	check(f:apply("read_missing", { action_id = read.action_id, executor = claim.executor, grant_id = claim.grant_id, query_bytes = runtime.json.encode(query),
		response_bytes = shared.frame(query, "found", { outcome = peer_body(request, "pending", nil) }) }).code == "status_not_missing" and f:action(read.action_id).phase == "uncertain",
		"only SPAWN's missing status resolves a retained read")
	for _ = 1, 16 do
		local current = f:action(read.action_id)
		if not current or current.phase ~= "uncertain" then break end
		w:tick()
	end
	local statuses = 0
	for _, e in w:bridge_events() do if e.op == "status" then statuses += 1; assert(e.target_request_id == request.request_id) end end
	local resolved = f:action(read.action_id)
	check(resolved == nil and statuses == 1,
		"one automatic missing status resolves and removes the read without resubmitting it")
	check(controller(f).pending_executors == executors - 1 and worker(f, id).read_selector == nil and worker(f, id).assembly == nil,
		"the resolved read releases its executor count and its read selector/reassembly state")
	check(state.rehydrate(clone(f.authority.registry)) ~= nil, "missing-status read evidence restores")
	local attached = attach(f, id, "9002")
	check(attached.ok and not worker(f, id).continuation_required, "explicit reattachment proceeds after the read resolved: " .. tostring(attached.message))
	-- The normal poll lane re-reads from the durable cursor; intake applies the report exactly once.
	local bytes = f:report(id, 2, "HEARTBEAT", { state = "idle" })
	local framed = assert(shared.codec.frame(bytes, "report", worker(f, id)))
	local objects = { framed.manifest }
	for _, chunk in framed.chunks do table.insert(objects, chunk) end
	local first
	for index, object in objects do
		local queued = f:apply("poll", { worker_id = id }); assert(queued.ok, queued.message)
		local next_read = f:action(queued.action_id).request; assert(next_read.op == "mailbox_read", next_read.op)
		if index == 1 then first = clone(next_read.selector) end
		assert(f:finish(queued.action_id, "read", runtime.json.decode(assert(shared.codec.project_page(object, next_read.selector)))).ok)
	end
	check(f:action(read.action_id) == nil and first.stream == "report" and first.slot == 2 and first.part == "manifest" and worker(f, id).accepted_seq == 2,
		"the worker re-reads the next report from its durable cursor and accepts it")
	check(f:apply("intake", { worker_id = id, bytes = bytes }).code == "report_replayed" and worker(f, id).accepted_seq == 2 and worker(f, id).receipts["3"] == nil,
		"an intake replay after the resolution never double-applies")
	check(not f:apply("result", { action_id = read.action_id, executor = claim.executor, grant_id = claim.grant_id,
		response_bytes = shared.frame(request, "missing", {}) }).ok and worker(f, id).accepted_seq == 2, "a late outcome for the resolved read's grant is refused")

	-- Coordinator: SPAWN's own outcome for the read stays ambiguous (`uncertain`), yet the owner's
	-- explicit attested attachment proceeds, supersedes the read and resumes the coordinator.
	local c = shared.fixture(); local cid = c:accepted(true)
	local cread_id
	for _ = 1, 16 do
		local queued = c:apply("poll", { worker_id = cid }); assert(queued.ok, queued.message)
		local op = c:action(queued.action_id).request.op
		if op == "mailbox_read" then cread_id = queued.action_id; break end
		assert(op == "mailbox_publish_reply" or op == "mailbox_publish_ack", "the coordinator outbox drains publications first: " .. op)
		assert(c:finish(queued.action_id, "published", {}).ok)
	end
	assert(cread_id, "the coordinator fixture must reach its report read")
	assert(c:apply("claim", { action_id = cread_id, executor = c.origin.window_epoch }).ok)
	local cread, cclaim = clone(c:action(cread_id).request), clone(c:action(cread_id).claim)
	continued_reload(c)
	local function coordinator_owner() return c.authority.registry.sessions[c.origin.logical_session_id].orchestrator end
	check(c:apply("result", { action_id = cread_id, executor = cclaim.executor, grant_id = cclaim.grant_id,
		response_bytes = shared.frame(cread, "uncertain", nil, { code = "target_unavailable", message = "Outcome uncertain" }) }).code == "effect_uncertain"
		and c:action(cread_id).phase == "uncertain" and coordinator_owner().phase == "uncertain", "SPAWN's ambiguous outcome keeps the coordinator's read uncertain")
	local cattached = attach(c, cid, "9011")
	check(cattached.ok, "explicit coordinator reattachment is not refused by its uncertain read: " .. tostring(cattached.message))
	check(c:action(cread_id) == nil, "the attached current route supersedes and removes the ambiguous read")
	check(coordinator_owner().phase == "running" and coordinator_owner().pending_executors == 0 and controller(c).pending_executors == 0,
		"the coordinator resumes with no executor of its owner left counted")
	check(state.rehydrate(clone(c.authority.registry)) ~= nil, "superseded read evidence restores")
	local creread = c:apply("poll", { worker_id = cid }); assert(creread.ok, creread.message)
	local cnext = c:action(creread.action_id).request
	check(cnext.op == "mailbox_read" and cnext.selector.slot == worker(c, cid).accepted_seq + 1 and cnext.selector.part == "manifest" and c:action(cread_id) == nil,
		"the resumed coordinator re-reads from its durable cursor")

	-- Mutating effects keep their strict behaviour.
	local m = shared.fixture(); local mid = m:accepted(false)
	assert(m:apply("reply", { worker_id = mid }).ok)
	local pub = m:apply("poll", { worker_id = mid }); assert(pub.ok, pub.message)
	assert(m:action(pub.action_id).request.op == "mailbox_publish_reply")
	assert(m:apply("claim", { action_id = pub.action_id, executor = m.origin.window_epoch }).ok)
	local mrequest, mclaim = clone(m:action(pub.action_id).request), clone(m:action(pub.action_id).claim)
	continued_reload(m)
	check(attach(m, mid, "9011").code == "settlement_pending" and m:action(pub.action_id).phase == "uncertain" and worker(m, mid).continuation_required,
		"an uncertain mailbox_publish_reply still blocks attachment")
	local mquery = status_query(m, mrequest, "9010")
	check(m:apply("read_missing", { action_id = pub.action_id, executor = mclaim.executor, grant_id = mclaim.grant_id, query_bytes = runtime.json.encode(mquery),
		response_bytes = shared.frame(mquery, "missing") }).code == "stale_claim" and m:action(pub.action_id).phase == "uncertain",
		"SPAWN's missing status never resolves a mutating effect")
	local mforged = clone(m.authority.registry); local fa = mforged.dispatch.actions[pub.action_id]
	fa.phase = "resolved"; fa.resolution = { revision = mforged.revision, executor = mclaim.executor, evidence = "publication_readback", reason = "control" }
	check(state.rehydrate(clone(mforged)) == nil, "completed mutation records cannot be manufactured in the strict current store")
	fa.resolution.evidence = "read_superseded"
	check(state.rehydrate(mforged) == nil, "restore quarantines read resolution evidence on a mutating effect")
end
-- USAGE capacity reader: the document hash is stepped incrementally across window ticks (never
-- one monolithic hash in a 50 ms callback), and an interrupted step fails closed and is retryable.
if section == nil or section == "quota_reader" then
	local w = window_fixture()
	local codec, quota = shared.codec, shared.load("quota")
	local PAGE, NOW = 32768, 1700000000000
	local raw = runtime.json.encode({ version = 1, complete = true, incomplete = false, auth_revision = "auth-1", records = runtime.json.array(),
		sources = runtime.json.array(), quota_unit = "percent", padding = string.rep("usage-capacity ", 5400) })
	local revision, count = codec.sha256(raw), math.ceil(#raw / PAGE)
	assert(count == 3, "fixture document spans three USAGE pages")
	local server = { text = "", requests = {} }
	function server.handle(req)
		table.insert(server.requests, req.op)
		local r
		if req.op == "validate" then
			r = { version = 1, request_id = req.request_id, op = "validate", ok = true, status = "current", revision = revision, auth_revision = "auth-1",
				validated_at_ms = NOW, expires_at_ms = NOW + 600000 }
		else
			local index = if req.op == "snapshot" then 0 else assert(tonumber(req.cursor:match("^page%-(%d+)$")))
			local last = index + 1 == count
			r = { version = 1, request_id = req.request_id, op = req.op, ok = true, status = "ok", revision = revision, auth_revision = "auth-1",
				issued_at_ms = NOW, expires_at_ms = NOW + 600000, index = index, count = count, size = #raw, data = raw:sub(index * PAGE + 1, (index + 1) * PAGE),
				next_cursor = if last then runtime.json.null else "page-" .. tostring(index + 1), complete = last, incomplete = false }
		end
		server.text = runtime.json.encode(r) -- Host-only USAGE helper publishes raw JSON, not a pane marker.
	end
	w:usage(server)
	local original_step, original_sha256 = codec.sha256_step, codec.sha256
	local steps, largest, monolithic, interrupt = 0, 0, 0, false
	codec.sha256_step = function(state, max_blocks)
		steps += 1; largest = math.max(largest, max_blocks)
		if interrupt then interrupt = false; state.busy = true; return false end -- A step whose callback was aborted.
		return original_step(state, max_blocks)
	end
	codec.sha256 = function(bytes) if bytes == raw then monolithic += 1 end; return original_sha256(bytes) end
	local function capacity_commands() local n = 0; for _, e in w.events do if e.command == "capacity" then n += 1 end end; return n end
	local function successes() local n = 0; for _, m in w.notices do if m == "USAGE capacity evidence refreshed and validated." then n += 1 end end; return n end
	local function refresh(until_fn)
		local busiest = 0
		w:click("capacity_refresh")
		for _ = 1, 60 do
			local before = steps
			w:tick()
			busiest = math.max(busiest, steps - before)
			if until_fn() then break end
		end
		return busiest
	end
	local busiest = refresh(function() return successes() == 1 end)
	local full_blocks = math.floor(#raw / 64)
	check(successes() == 1 and capacity_commands() == 1, "a three-page USAGE document is verified, validated and recorded")
	check(monolithic == 0 and largest <= quota.HASH_BLOCKS_PER_STEP and busiest <= 1 and steps >= math.ceil(full_blocks / quota.HASH_BLOCKS_PER_STEP),
		"the document SHA-256 runs in at most one bounded step per window tick, never in one callback")
	check(table.concat(server.requests, ",") == "snapshot,page,page,validate", "validate is requested only after every page is hashed and verified")
	check(#w:usage_placements() == 0 and #w:bridge_placements() == 0 and w:moves() == 0 and next(w:tab_names()) == nil
		and #w.cx.hosts:current().panes == 3,
		"USAGE reads use the existing ORCH host relay with zero extra native pane, tab, move or parked chip")
	-- An aborted hashing step leaves its state interrupted: the reader fails closed (no evidence,
	-- no capacity command), and an explicit refresh starts over and succeeds.
	server.requests = {}; interrupt = true
	refresh(function() for _, m in w.notices do if m:find("hash_interrupted", 1, true) then return true end end; return false end)
	local interrupted = false
	for _, m in w.notices do if m:find("hash_interrupted", 1, true) then interrupted = true end end
	check(interrupted and capacity_commands() == 1 and successes() == 1 and table.find(server.requests, "validate") == nil,
		"an interrupted hashing step fails closed: no validation, no evidence")
	server.requests = {}
	refresh(function() return successes() == 2 end)
	check(successes() == 2 and capacity_commands() == 2 and table.concat(server.requests, ",") == "snapshot,page,page,validate", "an explicit refresh after the failure verifies a fresh assembly")
	-- Reload creates no reader pane and preserves legacy closed/unreadable views rather than
	-- adopting or deleting them as transport. Only the actual ORCH host relay is read.
	w:add_usage(9650, 1); w.hidden_views[9650] = true
	w:reload()
	w:palette("continue_controller"); w:pick({ continue_controller = true }); assert(w:outcome().ok)
	w.f.origin = clone(w.events[#w.events].origin)
	server.requests = {}
	refresh(function() return successes() == 3 end)
	check(successes() == 3 and #w:usage_placements() == 0 and #w:bridge_placements() == 0,
		"after a window reload capacity refresh still uses the native ORCH relay without new_block")
	for _ = 1, 4 do w:tick() end
	check(w.panes[9650] ~= nil and #w:bridges_closed() == 0,
		"a legacy closed-view USAGE pane is preserved, never adopted or silently closed")
	-- A retained response from the previous request is neither a page nor an ACK for this read.
	server.requests = {}; server.response_request_id = "retained-older-request"
	local before_acks = #w:relay_acks()
	w:click("capacity_refresh")
	for _ = 1, 4 do w:tick() end
	check(capacity_commands() == 3 and successes() == 3 and table.concat(server.requests, ",") == "snapshot",
		"a response for an older request cannot advance or validate the new capacity assembly")
	local capacity_acks = 0
	for index = before_acks + 1, #w:relay_acks() do
		if w:relay_acks()[index].route == "usage.capacity.response" then capacity_acks += 1 end
	end
	check(capacity_acks == 0, "the unrelated capacity response is not acknowledged as consumed")
	server.response_request_id = nil
	for _ = 1, 60 do w:tick(); if successes() == 4 then break end end
	check(successes() == 4 and capacity_commands() == 4 and table.concat(server.requests, ",") == "snapshot,page,page,validate",
		"the same in-flight read completes only when the exact current response becomes available")
	-- A peer restart mid-document must discard the earlier boot's pages, even for identical JSON.
	local answer, restarted = server.handle, false
	server.handle = function(req)
		answer(req)
		if req.op == "page" and not restarted then restarted = true; server.peer_boot = "fixture-usage-boot-new" end
	end
	server.requests = {}
	refresh(function() return successes() == 5 end)
	check(restarted and successes() == 5 and capacity_commands() == 5
		and table.concat(server.requests, ",") == "snapshot,page,snapshot,page,page,validate",
		"a changed USAGE boot restarts with a causal snapshot and validates only the new complete assembly")
	check(#w:usage_placements() == 0 and #w:bridge_placements() == 0 and #w:bridges_closed() == 0,
		"request correlation and peer restart never create or destroy a native transport view")
	codec.sha256_step, codec.sha256 = original_step, original_sha256
end
-- Native authorization runs after another window turn, not synchronously with request submission.
if section == nil or section == "control_scheduling" then
	local w
	w = window_fixture({ before_control_authorization = function()
		w:tick()
	end })
	w:bridge({ placeholder = true })
	w:click("poll", { worker_id = w.id, bytes = "watermark" })
	local action_id = assert(w:worker().active_action_id)
	assert(w.f:action(action_id).phase == "ready")
	w:click("bridge_reconcile")
	local sid = w.f.origin.logical_session_id
	local control = clone(assert(w.f.authority.registry.sessions[sid].bridge_control))
	w:tick()
	check(w.f.authority.registry.revision == control.request.authority_revision,
		"starting the native control lane preserves its authorization revision instead of issuing background mutations")
	for _ = 1, 4 do
		if #w:control_authorizations() > 0 then break end
		w:tick()
	end
	local authorization = w:control_authorizations()[1]
	check(authorization ~= nil and authorization.authorized and authorization.observed_revision == control.request.authority_revision,
		"background observation and unissued claims cannot invalidate a pending native control before authorization")
	check(w.f:action(action_id).phase == "ready" and w.f:action(action_id).claim == nil,
		"a queued effect stays unissued while the native control consumes its captured revision")
	w:tick(); w:tick()
	check(w.f.authority.registry.sessions[sid].bridge_control == nil,
		"the exact native control response settles without replacement by a recovery query")
	for _ = 1, 4 do w:tick() end
	local claimed = false
	for _, event in w.events do
		if event.command == "claim" and event.action_id == action_id then claimed = true end
	end
	check(claimed, "the queued effect resumes through its normal claim door after control settlement")
end
if section == nil or section == "work_input_priority" then
	local w = window_fixture()
	w:bridge({ placeholder = true })
	w:click("new_conversation")
	local revision = w.f.authority.registry.revision
	local sid = w.f.origin.logical_session_id
	w:tick(); w:tick()
	check(w.f.authority.registry.revision == revision and w.f.authority.registry.sessions[sid].bridge_control == nil,
		"an open source picker keeps new automatic reconciliation from invalidating its captured input")
	w:pick({ new = true })
	w:tick(); w:tick()
	check(w.f.authority.registry.revision == revision and w.f.authority.registry.sessions[sid].bridge_control == nil,
		"the nested plan-path prompt retains the original fence across window turns")
	w:answer(nil)
	w:tick()
	check(w.f.authority.registry.sessions[sid].bridge_control ~= nil,
		"cancelling the path prompt releases priority and normal background reconciliation resumes")
	local cancelled = window_fixture()
	cancelled:bridge({ placeholder = true })
	cancelled:click("new_conversation")
	cancelled:pick(nil)
	cancelled:tick()
	check(cancelled.f.authority.registry.sessions[cancelled.f.origin.logical_session_id].bridge_control ~= nil,
		"cancelling the source picker also releases background work")
	local stale = window_fixture()
	assert(stale.f:apply("policy", { policy = {
		routes = runtime.json.array({ { class = "build", record_id = "native" } }),
		templates = runtime.json.array({ { id = "draft", title = "Draft notes", prompt = "Draft from {input}.",
			output = "out/draft.md", next = "", class = "build" } }) } }).ok)
	stale:bridge({ placeholder = true })
	stale:click("start_work", { template_id = "draft" })
	local template_choice
	for _, item in stale:picker().items do if item.template then template_choice = item end end
	assert(template_choice); stale:pick(template_choice); stale:tick()
	local captured_revision = stale.f.authority.registry.revision
	assert(stale.f:apply("pause").ok)
	stale:tick()
	check(stale.f.authority.registry.sessions[stale.f.origin.logical_session_id].bridge_control ~= nil,
		"a genuinely invalidated input cannot keep blocking background reconciliation")
	local before_answer, before_events = runtime.json.encode(stale.f.authority.registry), #stale.events
	check(stale.f.authority.registry.revision > captured_revision, "the intervening policy change invalidates the captured template intent")
	stale:answer("notes/brief.md")
	check(runtime.json.encode(stale.f.authority.registry) == before_answer and #stale.events == before_events,
		"an obsolete template callback refuses locally without refreshing its captured fence or writing authority")
	stale:tick()
	check(next(stale.f.authority.registry.dispatch.chains or {}) == nil and flow(stale.f).policy.paused,
		"resumed background bookkeeping cannot start the invalidated template or undo the owner's pause")
	for index = before_events + 1, #stale.events do
		check(stale.events[index].command ~= "template_start", "background work never replays the obsolete template intent")
	end
	local finishing = window_fixture()
	finishing:bridge({ placeholder = true })
	finishing:click("finish", { worker_id = finishing.id })
	local finish_revision = finishing.f.authority.registry.revision
	finishing:tick(); finishing:tick()
	check(finishing.f.authority.registry.revision == finish_revision,
		"new background reconciliation cannot invalidate an already captured Finish confirmation")
	finishing:pick({ finish = true })
	check(finishing:outcome().ok and finishing:worker().finish_requested,
		"the original Finish confirmation commits once without refreshing or repeating its attestation")
	local cancelled_finish = window_fixture()
	cancelled_finish:bridge({ placeholder = true })
	cancelled_finish:click("finish", { worker_id = cancelled_finish.id })
	cancelled_finish:pick({ finish = false }); cancelled_finish:tick()
	check(not cancelled_finish:worker().finish_requested
		and cancelled_finish.f.authority.registry.sessions[cancelled_finish.f.origin.logical_session_id].bridge_control ~= nil,
		"cancelling Finish releases background reconciliation without requesting a stop")
	local stale_finish = window_fixture()
	stale_finish:bridge({ placeholder = true })
	stale_finish:click("finish", { worker_id = stale_finish.id })
	assert(stale_finish.f:apply("pause").ok)
	stale_finish:tick()
	stale_finish:pick({ finish = true })
	check(not stale_finish:worker().finish_requested and stale_finish:outcome().code == "stale_revision",
		"a genuine intervening commit still refuses the captured Finish confirmation")
	local lost_origin = window_fixture()
	lost_origin:click("finish", { worker_id = lost_origin.id })
	-- A durable continuation has replaced the origin while the old callback remains.
	lost_origin.f.authority.registry.dispatch.command_cursors[lost_origin.f.origin.logical_session_id].origin.window_epoch = "continued-window"
	lost_origin:tick()
	lost_origin:pick({ finish = true })
	check(not lost_origin:worker().finish_requested and noticed(lost_origin, "no longer the controller"),
		"losing input priority preserves the confirmation's explicit origin-loss notice")
end

-- Status inspection has its own envelope budget, never a larger original-result budget.
if section == nil or section == "status_envelope" then
	for _, mode in { "explicit", "automatic", "inspection" } do
		local retained, original, status_bytes
		local queries = {}
		local w = window_fixture({ no_worker = true, sweep_enabled = false, idle_baseline = true, commit_results = true,
			bridge_handler = function(query)
				assert(query.op == "status" and query.target_request_id == retained.request.request_id
					and query.target_request_serial == retained.request.request_serial,
					"the wide inspection must target the immutable retained request")
				table.insert(queries, clone(query))
				status_bytes = shared.frame(query, "found", { outcome = shared.codec.decode_dispatch_response(original, retained.request) })
				assert(#status_bytes > shared.codec.LIMITS.bridge and #status_bytes <= shared.codec.LIMITS.bridge_status
					and shared.codec.decode_dispatch_response(status_bytes, query), "fixture publishes a genuine bounded wide status frame")
				return status_bytes
			end })
		local queued = w.f:apply("catalog"); assert(queued.ok)
		assert(w.f:apply("claim", { action_id = queued.action_id, executor = w.f.origin.window_epoch }).ok)
		retained = clone(w.f:action(queued.action_id))
		local records = runtime.json.array()
		for index = 1, 10 do
			table.insert(records, { id = "native-" .. index, revision = 27, eligible = true, enabled = true, provider = "omp",
				backend = "native-agent", provider_family = "openai", account_label = string.rep("a", 360),
				capabilities = runtime.json.array({ "report-files-v1" }), unsupported = runtime.json.array() })
		end
		local payload = { catalog_version = 2, namespace = "fixture-spawn", host_key = "fixture-host", config_revision = 27, revision = 27,
			setup = { schema = 1, state = "completed", config_revision = 27,
				readiness = { state = "not_run", config_revision = 27, summary = "" } }, records = records }
		records[1].selector_evidence = "x"
		local base = shared.frame(retained.request, "catalog", payload)
		records[1].selector_evidence ..= string.rep("x", 7647 - #base)
		original = shared.frame(retained.request, "catalog", payload)
		assert(#original == 7647 and shared.codec.decode_dispatch_response(original, retained.request),
			"the original ten-record result remains valid under the ordinary bridge bound")
		assert(w.f:apply("lost", { action_id = queued.action_id, executor = retained.claim.executor, grant_id = retained.claim.grant_id }).ok)
		local commands, peer_events, notices = #w.events, #w:bridge_events(), #w.notice_events
		if mode == "explicit" then w:click("reconcile", { action_id = queued.action_id })
		elseif mode == "inspection" then w:click("check_connection", { action_id = queued.action_id }) end
		local acknowledged = false
		for _ = 1, (if mode == "inspection" then 3 else 20) do
			w:tick()
			for _, receipt in w:relay_acks() do
				for _, query in queries do
					if w:relay_response(receipt, query) then acknowledged = true end
				end
			end
			if acknowledged then break end
		end
		check(#queries == 1 and acknowledged and #w:bridge_placements() == 0 and next(w.f.authority.registry.dispatch.workers) == nil,
			mode .. ": the wide retained status reaches its exact ACK without a pane or agent")
		if mode == "inspection" then
			check(#w:result_events() == 0 and w.f:action(queued.action_id).phase == "uncertain"
				and w.f:action(queued.action_id).claim.grant_id == retained.claim.grant_id
				and #w.events == commands and #w.notice_events == notices + 2 and w.notice_events[#w.notice_events].level == "info",
				"ordinary connection inspection can read the wide catalog status but cannot commit or release its held claim")
		else
			local delivered = w:result_events()
			local result = if delivered[1] then runtime.json.decode(delivered[1].value) else nil
			check(#delivered == 1 and result.response_bytes == original and #result.response_bytes <= shared.codec.LIMITS.bridge
				and delivered[1].act == "dispatch-result/" .. retained.claim.grant_id .. "/" .. retained.claim.executor,
				mode .. ": normal result delivery commits only the exact ordinary original through its retained grant and executor")
		end
		for index = peer_events + 1, #w:bridge_events() do
			check(w:bridge_events()[index].op == "status" or w:bridge_events()[index].op == "owner_status",
				mode .. ": recovering a wide status never resubmits the original catalog")
		end
	end
end

if section == nil or section == "connection_inspection" then
	local w = window_fixture({ no_worker = true, sweep_enabled = false,
		catalog_handler = function() return nil end, bridge_handler = function() return nil end })
	w:bridge({ placeholder = true })
	w:click("catalog")
	local id = assert(w:outcome().action_id)
	for _ = 1, 68 do
		w:tick()
		if w.f:action(id).phase == "uncertain" then break end
	end
	local action = w.f:action(id)
	local notice = w.notice_events[#w.notice_events]
	local toast = w.toasts[#w.toasts]
	check(action.phase == "uncertain" and action.claim ~= nil and notice
		and notice.level == "error" and notice.context == "catalog" and notice.code == "catalog_unconfirmed"
		and notice.detail ~= nil and notice.message ~= notice.detail
		and toast.level == notice.level and toast.text == notice.message,
		"an unconfirmed catalog preserves its exact claim while both user surfaces receive the same human failure, not the raw diagnostic")
	local submissions = 0
	for _, request in w:bridge_events() do if request.op == "catalog" then submissions += 1 end end
	check(submissions == 1 and #w:result_events() == 0 and #w:bridge_placements() == 0
		and next(w.f.authority.registry.dispatch.workers) == nil,
		"an unknown catalog outcome is neither reported as loaded nor repeated as a new native effect")
end

-- The catalog's ordinary connection check is observation only, including an
-- absent/old/unreadable peer; it must not borrow the recovery guide's admission.
if section == nil or section == "connection_inspection" then
	for _, answer in { "current", "absent", "previous_incarnation", "unknown", "unreadable" } do
		local w = window_fixture({ no_worker = true, sweep_enabled = false, idle_baseline = true })
		w:bridge({ placeholder = true })
		w:owner_answer(answer)
		local before = runtime.json.encode(w.f.authority.registry)
		local commands, queries = #w.events, #w:bridge_events()
		local notices_before = #w.notice_events
		w:click("check_connection")
		for _ = 1, 14 do
			w:tick()
			-- Scope the injected reply to this explicit observation. A persistent
			-- global outage would independently trigger the five-second control probe.
			if #w.notice_events >= notices_before + 2 then w:owner_answer("current") end
		end
		local last = w.notice_events[#w.notice_events]
		check(last and last.context == "catalog" and last.source_nonce == w.f.origin.alias_nonce
			and last.level == (if answer == "current" then "info" else "error")
			and last.message == w.toasts[#w.toasts].text and last.level == w.toasts[#w.toasts].level,
			"connection check publishes the same source-bound human outcome and severity to inline and toast")
		local new_commands = {}
		for index = commands + 1, #w.events do table.insert(new_commands, w.events[index].command .. ":" .. tostring(w.events[index].operation)) end
		check(runtime.json.encode(w.f.authority.registry) == before and #w.events == commands
			and #w:rebind_requests() == 0 and #w.managed_opened == 0 and #w:bridge_placements() == 0 and w:picker() == nil,
			"connection checking preserves admission, executor ownership and held work without a recovery prompt or launch: " ..
				runtime.json.encode({ answer = answer, registry_unchanged = runtime.json.encode(w.f.authority.registry) == before,
					before_commands = commands, commands = new_commands, rebinds = #w:rebind_requests(),
					managed = #w.managed_opened, placements = #w:bridge_placements(), picker = w:picker() ~= nil }))
		for index = queries + 1, #w:bridge_events() do
			check(w:bridge_events()[index].op == "owner_status",
				"connection checking sends only the exact source-scoped owner observation")
		end
	end
end

if section == nil or section == "connection_inspection" then
	local probes = {}
	local w = window_fixture({ no_worker = true, sweep_enabled = false, idle_baseline = true,
		bridge_handler = function(request)
			table.insert(probes, clone(request))
			return shared.frame(request, "missing", nil, nil, "unknown_effect")
		end })
	local queued = w.f:apply("catalog"); assert(queued.ok)
	assert(w.f:apply("claim", { action_id = queued.action_id, executor = w.f.origin.window_epoch }).ok)
	local action = clone(w.f:action(queued.action_id))
	assert(w.f:apply("lost", { action_id = queued.action_id, executor = action.claim.executor, grant_id = action.claim.grant_id }).ok)
	w:click("check_connection", { action_id = queued.action_id })
	for _ = 1, 3 do w:tick() end
	local notice = w.notice_events[#w.notice_events]
	check(#probes == 1 and probes[1].op == "status" and probes[1].target_request_id == action.request.request_id
		and probes[1].target_request_serial == action.request.request_serial and notice.level == "error"
		and notice.context == "catalog" and notice.code == "catalog_unconfirmed",
		"checking a held catalog observes its immutable request instead of reporting only healthy owner admission")
	check(w.f:action(queued.action_id).phase == "uncertain"
		and w.f:action(queued.action_id).claim.grant_id == action.claim.grant_id and w:picker() == nil,
		"connection inspection alone neither releases the held claim nor opens executor recovery")
	for _, request in w:bridge_events() do check(request.op ~= "catalog", "connection inspection never resends the held catalog") end
end

-- The actual window uses logical host-local endpoints, without any transport pane creation/adoption.
if section == nil or section == "bridge_lifecycle" then
	local w = window_fixture({ no_worker = true })
	local pending = w.f:apply("catalog"); assert(pending.ok)
	assert(w.f:apply("claim", { action_id = pending.action_id, executor = w.f.origin.window_epoch }).ok)
	local action = clone(w.f:action(pending.action_id))
	w:bridge(peer_body(action.request, "catalog", { catalog_version = 2, namespace = "fixture-spawn", host_key = "fixture-host", config_revision = 0, revision = 0,
		setup = { schema = 1, state = "completed", config_revision = 0, readiness = { state = "not_run", config_revision = 0, summary = "" } }, records = runtime.json.array() }))
	w:add_bridge(8990, { schema = 1, held = true, live = true, busy = false,
		owner = { controller_pane = "9001", alias_nonce = w.f.origin.alias_nonce, window_key = "", window_epoch = w.f.origin.window_epoch } })
	w:reload()
	w:palette("continue_controller"); w:pick({ continue_controller = true }); assert(w:outcome().ok)
	w.f.origin = clone(w.events[#w.events].origin)
	w:click("reconcile", { action_id = action.request.action_id })
	for _ = 1, 6 do w:tick() end
	local query
	for _, candidate in w:bridge_events() do if candidate.op == "status" then query = candidate end end
	check(query and query.target_request_id == action.request.request_id, "retained work is reconciled by exact original request rather than reissued")
	check(#w:bridge_placements() == 0 and #w:usage_placements() == 0 and #w:bridges_closed() == 0 and w:moves() == 0,
		"connection, reconciliation and reload create no native transport tab, split or parked chip")
	check(w.panes[8990] ~= nil, "uncertain old native bridge is preserved, never adopted or silently closed")
	for _, route in w:bridge_routes() do check(type(route.pane) == "string" and route.pane:sub(1, 1) == "l", "peer requests use a logical lane behind the real ORCH native event endpoint") end
	local sent = #w:bridge_events()
	w:change_peer_boot()
	for _ = 1, 4 do w:tick() end
	check(#w:rebind_requests() > 0 and #w:bridge_placements() == 0,
		"a changed peer incarnation automatically obtains a verified causal route without a fallback pane")
	local retained_grant = w.f:action(action.request.action_id).claim.grant_id
	for _ = 1, 6 do w:tick(); if w:picker() then break end end
	check(#w:rebind_requests() > 0 and #w:bridge_placements() == 0,
		"automatic recovery retains the original transport lane while inspecting its retained outcome")
	check(w.f:action(action.request.action_id).claim.grant_id == retained_grant,
		"explicit read-only reconnect preserves the uncertain effect's original grant")
	for index = sent + 1, #w:bridge_events() do
		local request = w:bridge_events()[index]
		check(request.op == "status" or request.op == "owner_status" or request.op == "reconcile_session",
			"reconnecting a retained result permits inspection/reconciliation only, never its original catalog effect")
	end
	local other = window_fixture(); other:bridge({ placeholder = true }); other.current.id = 8
	other:click("recovery_guide"); for _ = 1, 3 do other:tick() end
	check(#other:bridge_events() == 0 and #other:bridge_placements() == 0, "a different native session cannot use the source panel as a relay")
end
-- Retirement requires positive peer proof; reconnect requires a new causal bind, not a new boot alone.
if section == nil or section == "bridge_retirement" or section == "bridge_retirement_held" then
	local function quiet_worker(options)
		options.commit_results = true
		options.bridge_handler = function(request)
			local bytes = shared.frame(request, "missing")
			assert(shared.codec.decode_dispatch_response(bytes, request), "idle mailbox fixture publishes a canonical payloadless missing response")
			return bytes
		end
		local w = window_fixture(options)
		-- Drain the accepted report's real receipt/compaction debt before measuring idle
		-- mailbox discovery; otherwise the driver correctly continues that protocol first.
		assert(w.f:watermark(w.id).ok)
		local compact = w.f:apply("poll", { worker_id = w.id })
		assert(compact.ok and w.f:action(compact.action_id).request.mode == "compact")
		assert(w.f:finish(compact.action_id, "compacted", {}).ok)
		assert(w.f:apply("policy", { policy = { poll_ms = 60000, sweep_enabled = false } }).ok)
		w:bridge({ placeholder = true }); w:click("poll", { worker_id = w.id })
		for _ = 1, 12 do w:tick(); if #w:result_events() > 0 and not w:worker().active_action_id then break end end
		assert(#w:result_events() == 1 and not w:worker().active_action_id,
			"the worker's exact mailbox read settles before idle release: " .. runtime.json.encode(w:diagnostic()))
		local lane
		for _, route in w:bridge_routes() do if route.event.act == "mailbox_read" then lane = route.pane end end
		assert(lane and w:relay_lanes()[lane], "settled worker read retains its real logical endpoint")
		return w, lane
	end
	local function lane_receipts(receipts, lane)
		local found = {}
		for _, receipt in receipts do if receipt.lane_id == lane then table.insert(found, receipt) end end
		return found
	end
	if section == nil or section == "bridge_retirement" then
	local deferred_options = { defer_release = true, lose_release_acks = 1 }
	local deferred, old_lane = quiet_worker(deferred_options)
	deferred_options.lose_release_ack_lane = old_lane
	local function requests() return lane_receipts(deferred:release_requests(), old_lane) end
	local function acks() return lane_receipts(deferred:release_acks(), old_lane) end
	for _ = 1, 32 do deferred:tick(); if #requests() > 0 then break end end
	check(#requests() == 1 and deferred:relay_lanes()[old_lane] ~= nil and #acks() == 0,
		"idle release requests permission but retains its endpoint until positive host proof")
	for _ = 1, 4 do deferred:tick() end
	check(#requests() == 1 and deferred:relay_lanes()[old_lane] ~= nil,
		"an unconfirmed release neither repeats nor silently evicts the old endpoint")
	deferred:confirm_release(old_lane)
	for _ = 1, 3 do deferred:tick(); if #acks() > 0 then break end end
	check(#acks() == 1 and acks()[1].peer_boot == requests()[1].peer_boot
		and deferred:relay_lanes()[old_lane] == nil and deferred:release_proofs()[old_lane] ~= nil,
		"a lost release ACK retains the positive receipt rather than pretending retirement is fully consumed")
	local first_ack = acks()[1]
	local first_ack_at = deferred:now()
	deferred:click("poll", { worker_id = deferred.id })
	deferred:tick()
	local reads = 0
	for _, route in deferred:bridge_routes() do if route.event.act == "mailbox_read" then reads += 1 end end
	check(#acks() == 1 and reads == 1 and deferred:release_proofs()[old_lane] ~= nil,
		"before the one-second ACK retry, the next read cannot replace the still-unacknowledged endpoint")
	for _ = 1, 4 do deferred:tick(); if #acks() == 2 then break end end
	check(#acks() == 2 and shared.quota.digest(acks()[2]) == shared.quota.digest(first_ack)
		and deferred:now() - first_ack_at >= 1000 and deferred:release_proofs()[old_lane] == nil,
		"lost release ACK retries the exact same receipt after one second and consumes only its positive proof")
	for _ = 1, 8 do deferred:tick(); if #deferred:result_events() == 2 then break end end
	local next_lane
	for _, route in deferred:bridge_routes() do if route.event.act == "mailbox_read" then next_lane = route.pane end end
	check(#deferred:result_events() == 2 and next_lane ~= old_lane and deferred:relay_lanes()[next_lane] ~= nil,
		"the same worker's next explicit read allocates a fresh logical lane only after positive retirement")
	check(#deferred:bridge_placements() == 0 and #deferred:usage_placements() == 0 and #deferred:bridges_closed() == 0,
		"positive logical retirement creates, adopts and closes no native transport view")
	end

	if section == nil or section == "bridge_retirement_held" then
	local held_options = { release_held = true }
	local held, held_lane = quiet_worker(held_options)
	local function requests() return lane_receipts(held:release_requests(), held_lane) end
	local function acks() return lane_receipts(held:release_acks(), held_lane) end
	for _ = 1, 32 do held:tick(); if #requests() > 0 then break end end
	check(#requests() == 1 and held:relay_lanes()[held_lane].release_held == true,
		"a peer's nonfatal idle-release refusal keeps the exact lane and boot")
	for _ = 1, 6 do held:tick() end
	check(#requests() == 1 and #acks() == 0 and held:relay_lanes()[held_lane] ~= nil,
		"release-held retries are paced rather than spinning or treating refusal as retirement")
	held_options.release_held = false
	for _ = 1, 28 do held:tick(); if #acks() > 0 then break end end
	check(#requests() == 2 and #acks() == 1 and acks()[1].peer_boot == requests()[2].peer_boot,
		"after the idle delay the same endpoint can obtain positive release without a replacement transport")
	end
end

if section == nil or section == "bridge_rebind" then
	local function connection_ready(w)
		local publication = w:recovery_steps()
		return publication and publication.source_nonce == w.f.origin.alias_nonce and #publication.steps == 0
	end
	local function inspected(options)
		options.no_worker = true
		local w = window_fixture(options)
		w:bridge({ placeholder = true }); w:owner_answer("current"); w:click("recovery_guide")
		for _ = 1, 8 do if connection_ready(w) then break end; w:tick() end
		assert(connection_ready(w) and w:picker() == nil, "healthy read-only inspection settles without a no-op picker")
		local lane
		for _, route in w:bridge_routes() do if route.event.act == "owner_status" then lane = route.pane end end
		assert(lane and w:relay_lanes()[lane], "inspection uses a real retained logical route")
		return w, lane
	end

	local reconnect, lane = inspected({ defer_rebind = true })
	local bind = reconnect:relay_lanes()[lane].bind_id
	reconnect:change_peer_boot()
	check(reconnect:relay_metadata().held == true and reconnect:relay_metadata().error == "peer_reloaded"
		and reconnect:relay_lanes()[lane].held == true and reconnect:relay_lanes()[lane].error == "peer_reloaded"
		and reconnect:relay_lanes()[lane].peer_boot == nil and reconnect:relay_lanes()[lane].bind_id == nil
		and reconnect:relay_lanes()[lane].sent.bind == nil and next(reconnect:relay_lanes()[lane].messages) == nil,
		"a validated host boot withdraws old frames and bind authority and holds both the lane and published root")
	local sent = #reconnect:bridge_routes()
	for _ = 1, 3 do reconnect:tick() end
	local requested = false
	for _, request in reconnect:rebind_requests() do if request.lane_id == lane then requested = true end end
	check(requested and reconnect:relay_lanes()[lane].peer_boot == nil and reconnect:relay_lanes()[lane].bind_id == nil,
		"automatic reconnect requests a fresh causal bind while withdrawing the original lane's peer identity")
	reconnect:publish_peer(lane) -- New observed boot, but no new causal bind receipt yet.
	for _ = 1, 3 do reconnect:tick() end
	check(reconnect:relay_lanes()[lane].bind_id == bind and reconnect:relay_metadata().held == true
		and reconnect:relay_lanes()[lane].held == true,
		"a different observed peer boot cannot satisfy reconnect while bind_id is unchanged")
	for index = sent + 1, #reconnect:bridge_routes() do
		check(reconnect:bridge_routes()[index].pane ~= lane,
			"neither a boot observation nor a stale bind permits a request on the awaiting lane")
	end
	reconnect:confirm_rebind(lane)
	check(not reconnect:relay_lanes()[lane].held and reconnect:relay_lanes()[lane].bind_id ~= bind,
		"only the actual fresh bind receipt restores this exact lane's authority")
	local sibling_held = false
	for sibling, retained in reconnect:relay_lanes() do
		if sibling ~= lane and retained.held then sibling_held = true end
	end
	check((reconnect:relay_metadata().held == true) == sibling_held,
		"a fresh receipt for one lane cannot clear a sibling lane's host-boot hold")
	for sibling, retained in reconnect:relay_lanes() do
		if sibling ~= lane and retained.held then reconnect:confirm_rebind(sibling) end
	end
	check(not reconnect:relay_metadata().held, "the root hold clears only after every invalidated lane obtains its fresh receipt")
	local fresh_query = false
	for _ = 1, 8 do
		reconnect:tick()
		for index = sent + 1, #reconnect:bridge_routes() do
			local route = reconnect:bridge_routes()[index]
			if route.pane == lane and route.event.act == "owner_status" then
				local query = runtime.json.decode(route.event.value)
				check(shared.quota.digest(query.origin_binding) == shared.quota.digest(reconnect.f.origin)
					and query.controller_pane == "9001", "the fresh owner query retains its exact native source and current origin")
				fresh_query = true
			end
		end
		if fresh_query then break end
	end
	check(fresh_query and reconnect:picker() == nil, "a fresh causal receipt permits an owner observation on the original lane")
	for _, request in reconnect:bridge_events() do
		check(request.op == "owner_status" or request.op == "reconcile_session",
			"reconnect performs owner/control reconciliation only, never launches or claims a new effect")
	end
	check(#reconnect:bridge_placements() == 0 and #reconnect:usage_placements() == 0,
		"explicit reconnect remains pane-free")

	local unissued = window_fixture({ no_worker = true })
	unissued.f:catalog(0); unissued:bridge({ placeholder = true }); unissued:click("recovery_guide")
	for _ = 1, 8 do unissued:tick(); if connection_ready(unissued) then break end end
	assert(connection_ready(unissued) and unissued:picker() == nil,
		"the admitted source has an ordinary settled connection confirmation before queuing")
	local queued = unissued.f:queue(false); assert(queued.ok, queued.message)
	local original = clone(unissued.f:action(queued.action_id))
	assert(original.phase == "ready" and original.claim == nil and original.request_bytes == nil
		and not flow(unissued.f).policy.paused, "fixture retains an eligible, unpaused, never-issued mutating action")
	unissued:change_peer_boot(); unissued:click("recovery_guide")
	for _ = 1, 12 do unissued:tick() end
	local retained = unissued.f:action(queued.action_id)
	check(#unissued:rebind_requests() > 0 and retained and retained.phase == "ready"
		and retained.claim == nil and retained.request_bytes == nil and retained.request.request_id == original.request.request_id,
		"explicit Reconnect preserves unissued mutating work without automatic grant allocation or launch")
	for _, event in unissued.events do
		check(not (event.command == "claim" and event.action_id == queued.action_id),
			"reconnect's successful read-only binding does not claim the previously unissued effect")
	end
	for _, request in unissued:bridge_events() do
		check(request.op ~= "mailbox_provision" and request.op ~= "launch",
			"unissued provisioning and launch remain held after explicit reconnect")
	end
end
-- Native reconciliation tracks current delivery progress, never every unrelated registry revision.
if section == nil or table.find({ "bridge_paging", "bridge_paging_roster", "bridge_paging_late_sweep", "bridge_paging_late_response",
	"bridge_paging_drain", "bridge_paging_lower", "bridge_paging_generation", "bridge_paging_prompt" }, section) then
	local peer_entries, page_size = {}, 16
	local w = window_fixture({ no_worker = true, peer_entries = peer_entries, control_outstanding = function(request)
		for serial in peer_entries do
			if serial < request.settled_before or table.find(request.consumed, serial) then peer_entries[serial] = nil end
		end
		local cursor = request.outstanding_cursor
		local after = if cursor then cursor.after_serial else 0
		local through = if cursor then cursor.through_serial else 0
		local entries = {}
		for serial, entry in peer_entries do
			if not cursor then through = math.max(through, serial) end
			if serial > after and (not cursor or serial <= through) then
				table.insert(entries, { request_serial = entry.request_serial, request_id = entry.request_id,
					action_id = entry.action_id, op = entry.op, phase = entry.phase })
			end
		end
		table.sort(entries, function(a, b) return a.request_serial < b.request_serial end)
		local complete = #entries <= page_size
		while #entries > page_size do table.remove(entries) end
		return { after_serial = after, through_serial = through,
			next_after_serial = if complete then through else entries[#entries].request_serial,
			complete = complete, entries = runtime.json.array(entries) }
	end })
	local f, sid = w.f, w.f.origin.logical_session_id
	assert(f:apply("policy", { policy = { sweep_enabled = false } }).ok)
	w:bridge({ placeholder = true })
	local function controls()
		local out = {}
		for _, event in w:bridge_events() do
			if table.find({ "admit_session", "reconcile_session", "close_session" }, event.op) then table.insert(out, event) end
		end
		return out
	end
	local function owner_reads()
		local count = 0
		for _, event in w:bridge_events() do if event.op == "owner_status" then count += 1 end end
		return count
	end
	local function control_pane()
		local routes = w:bridge_routes()
		for index = #routes, 1, -1 do
			if routes[index].event.act == "reconcile_session" then return routes[index].pane end
		end
		error("fixture requires an actual native control route")
	end
	local function progress()
		return assert(dispatch.project(f.authority.registry, sid, f.origin.alias_nonce).reconcile_progress)
	end
	local settlement_step = 0
	local function settle()
		settlement_step += 1
		for _ = 1, 4 do w:tick() end
		local current = f.authority.registry.sessions[sid].bridge_control
		if current then
			local lane, routes = nil, w:bridge_routes()
			for index = #routes, 1, -1 do
				if routes[index].event.act == "reconcile_session" then lane = routes[index].pane; break end
			end
			local retained = if lane then w:relay_lanes()[lane] else nil
			local proof = if retained then retained.messages.response else nil
			local response, problem
			if proof then response, problem = w:relay_response(proof, current.request) end
			local diagnostic = w:diagnostic()
			error("native control response must commit and clear its exact request: " .. runtime.json.encode({
				step = settlement_step, request = current.request, progress = progress(), revision = diagnostic.revision,
				control_result = diagnostic.control_result, last_command = diagnostic.commands[#diagnostic.commands],
				peer = if lane then w:bridge_state(lane) else nil,
				response = if response then { request_id = response.request_id, action_id = response.action_id,
					category = response.category, status = response.status, authority_revision = response.authority_revision } else nil,
				response_problem = problem, response_present = proof ~= nil,
			}))
		end
	end
	local function reconcile()
		local count = #controls()
		w:elapse(5000); w.api.schedule(w.cx); settle()
		local sent = controls()
		check(#sent == count + 1 and sent[#sent].op == "reconcile_session",
			"changed current progress emits exactly one paced reconciliation: " .. runtime.json.encode({
				before = count, after = #sent, progress = progress(),
				admitted = f.authority.registry.sessions[sid].admitted,
				phase = f.authority.registry.sessions[sid].phase }))
		return sent[#sent]
	end
	local issued_grants, retained_full = {}, {}
	local function claim_catalog(delayed)
		local queued = f:apply("catalog"); assert(queued.ok, queued.message)
		local claimed = f:apply("claim", { action_id = queued.action_id, executor = f.origin.window_epoch })
		assert(claimed.ok, "catalog claim refused: " .. runtime.json.encode({ response = claimed, state = w:diagnostic() }))
		issued_grants[queued.action_id] = f:action(queued.action_id).claim.grant_id
		local request = clone(f:action(queued.action_id).request)
		if not delayed then
			peer_entries[request.request_serial] = { request_serial = request.request_serial, request_id = request.request_id,
				action_id = request.action_id, op = request.op, phase = "claimed", body_status = "claimed" }
			w:peer_changed()
		end
		return request
	end
	local function hold_catalog()
		local request = claim_catalog()
		local full = f:finish(request.action_id, "full", { resource = "catalog", current = 1, limit = 1,
			retryable = true, effect_started = false })
		assert(full.ok and full.code == "backpressure", "retained catalog refusal failed: " .. runtime.json.encode(full))
		retained_full[request.action_id] = true
		peer_entries[request.request_serial].phase = "current_result"
		peer_entries[request.request_serial].body_status = "full"
		w:peer_changed()
		return request
	end
	local function check_retained(request)
		local action, peer = f:action(request.action_id), peer_entries[request.request_serial]
		local refused = retained_full[request.action_id] == true
		check(action ~= nil and action.request.request_id == request.request_id and action.request.request_serial == request.request_serial
			and action.claim.grant_id == issued_grants[request.action_id] and peer ~= nil and peer.request_id == request.request_id
			and (if refused then action.phase == "backpressure" and action.response.status == "full"
				and action.response.payload.effect_started == false and peer.body_status == "full"
				else action.phase == "claimed" and peer.phase == "claimed"),
			"reconciliation preserves each exact current claim or definite pre-effect refusal without completing or replaying it")
	end
	local function finish_catalog(request)
		assert(f:finish(request.action_id, "catalog", { catalog_version = 2, namespace = "fixture-spawn", host_key = "fixture-host",
			config_revision = 0, revision = 0, setup = { schema = 1, state = "completed", config_revision = 0,
				readiness = { state = "not_run", config_revision = 0, summary = "" } }, records = runtime.json.array() }).ok)
		peer_entries[request.request_serial] = { request_serial = request.request_serial, request_id = request.request_id,
			action_id = request.action_id, op = request.op, phase = "current_result", body_status = "catalog" }
		w:peer_changed()
	end
	local function complete_retained(request)
		if not retained_full[request.action_id] then finish_catalog(request); return end
		local retried = f:apply("retry", { action_id = request.action_id, trigger = "owner" })
		assert(retried.ok, "explicit catalog retry refused: " .. runtime.json.encode(retried))
		assert(f:action(request.action_id) == nil and f:action(retried.action_id).request_bytes == nil,
			"explicit retry consumes the exact pre-effect refusal and creates a new unissued intent")
		local claimed = f:apply("claim", { action_id = retried.action_id, executor = f.origin.window_epoch })
		assert(claimed.ok, "fresh cleanup catalog claim refused: " .. runtime.json.encode({ response = claimed, state = w:diagnostic() }))
		local fresh = clone(f:action(retried.action_id).request)
		check(fresh.request_serial > request.request_serial and fresh.request_id ~= request.request_id
			and f:action(retried.action_id).claim.grant_id ~= issued_grants[request.action_id],
			"explicit cleanup issues a distinct catalog request/grant, never changes or replays the retained full outcome")
		finish_catalog(fresh)
	end
	w.api.schedule(w.cx); settle()
	check(#controls() == 1, "a newly observed source reconciles its current admission once")
	local writes, revision, count, reads, probes, peer_before
	if section == nil or section == "bridge_paging" then
	writes, revision, count = f.memory.writes, f.authority.registry.revision, #controls()
	for _ = 1, 24 do w:tick() end
	check(#controls() == count and f.memory.writes == writes and f.authority.registry.revision == revision,
		"unchanged acknowledged progress emits no mutating control, no authority write and no revision churn")
	local low = claim_catalog()
	local low_progress = progress()
	local issued = reconcile()
	check(issued.next_request_serial == low.request_serial + 1 and issued.settled_before == low.request_serial,
		"an issued horizon change reconciles even while the oldest live serial pins the floor")
	local high = claim_catalog()
	reconcile()
	finish_catalog(high)
	local hole = progress()
	check(hole.settled_before == low_progress.settled_before and #hole.consumed == 1 and hole.consumed[1] == high.request_serial,
		"real out-of-order result consumption reconstructs its hole above the retained lower effect")
	local consumed = reconcile()
	check(#consumed.consumed == 1 and consumed.consumed[1] == high.request_serial
		and f:action(low.action_id).phase == "claimed" and f:action(high.action_id) == nil,
		"changed consumed holes reconcile without replaying or retiring the lower effect")
	reconcile() -- The peer acknowledged the hole and no longer lists it.
	finish_catalog(low)
	local advanced = reconcile()
	check(advanced.settled_before > low.request_serial and f:action(low.action_id) == nil and peer_entries[low.request_serial] == nil,
		"settling the oldest live serial advances the advertised floor")
	local page_low, page_high = claim_catalog(), claim_catalog()
	page_size = 1
	reconcile()
	local cursor = clone(progress().outstanding_cursor)
	assert(cursor and cursor.after_serial == page_low.request_serial and cursor.through_serial == page_high.request_serial,
		"the peer's bounded first page must expose a real remaining page")
	local next_page = reconcile()
	check(next_page.outstanding_cursor.after_serial == cursor.after_serial
		and next_page.outstanding_cursor.through_serial == cursor.through_serial and progress().outstanding_cursor == nil,
		"a changed page cursor reconciles the exact next page and consumes its completion")
	finish_catalog(page_low); finish_catalog(page_high); page_size = 16
	reconcile()
	end
	if section == nil or table.find({ "bridge_paging_roster", "bridge_paging_late_sweep", "bridge_paging_late_response", "bridge_paging_drain" }, section) then
	local retained = { claim_catalog() } -- One occupied effect slot; each following FULL releases its own slot.
	for _ = 1, 16 do table.insert(retained, hold_catalog()) end
	reconcile()
	local first_page = clone(progress().outstanding_cursor)
	check(first_page ~= nil and first_page.after_serial == retained[16].request_serial
		and first_page.through_serial == retained[17].request_serial,
		"seventeen genuinely issued retained entries require a bounded second page at the native sixteen-entry limit")
	reconcile()
	check(progress().outstanding_cursor == nil, "the finite unchanged seventeen-entry sweep reaches its last page")
	if section == nil or section == "bridge_paging_roster" then
	writes, revision, count = f.memory.writes, f.authority.registry.revision, #controls()
	reads = w:peer_state_reads()
	probes, peer_before = owner_reads(), w:peer_revision()
	for _ = 1, 36 do w:tick() end
	check(#controls() == count and f.memory.writes == writes and f.authority.registry.revision == revision
		and w:peer_state_reads() > reads and owner_reads() > probes and w:peer_revision() == peer_before,
		"completed multipage progress stays quiescent while read-only owner probes refresh cached surfaces without ORCH or peer writes")
	for _, request in retained do check_retained(request) end
	local own_progress = w:peer_progress()
	probes, count = owner_reads(), #controls()
	w:peer_changed() -- Only another admission changed the global SPAWN store.
	peer_before = w:peer_revision()
	writes, revision = f.memory.writes, f.authority.registry.revision
	for _ = 1, 24 do w:tick() end
	local other_refreshed = w:bridge_state(control_pane())
	check(owner_reads() > probes and other_refreshed.authority_revision == peer_before
		and other_refreshed.session_progress == own_progress and w:peer_progress() == own_progress
		and #controls() == count and f.memory.writes == writes and f.authority.registry.revision == revision
		and w:peer_revision() == peer_before,
		"another session's store change refreshes idle observation but neither reconciles nor writes this unchanged admission")
	end
	for _, timing in { "after_sweep", "after_response" } do
	if section == nil or section == "bridge_paging_late_" .. (if timing == "after_sweep" then "sweep" else "response") then
		local late = claim_catalog(true) -- Issued locally, but its request has not reached the peer yet.
		reconcile()
		if timing == "after_response" then
			w:after_control_response(function(request, metadata, response)
				assert(request.outstanding_cursor ~= nil, "the raced response must finish the already-started finite sweep")
				local before_late = shared.quota.digest(progress())
				finish_catalog(late) -- After this exact response, before the window reads its current-state projection.
				check(shared.quota.digest(progress()) == before_late,
					"the response/projection race changes no local progress field before the old page commits")
				check(metadata.request_id == request.request_id and metadata.action_id == request.action_id
					and metadata.spawn_namespace == response.spawn_namespace and metadata.session_progress ~= w:peer_progress()
					and metadata.session_progress == w:bridge_state(control_pane()).session_progress
					and response.authority_revision == request.authority_revision and response.authority_revision ~= w:peer_revision(),
					"exact response metadata retains its earlier scoped session progress, not unrelated revision counters or the later arrival")
			end)
		end
		reconcile()
		if timing == "after_sweep" then
			local before_late = shared.quota.digest(progress())
			check(peer_entries[late.request_serial] == nil and progress().outstanding_cursor == nil,
				"the initial finite sweep cannot advertise an issued request that has not arrived")
			finish_catalog(late)
			check(shared.quota.digest(progress()) == before_late,
				"a late above-floor result can be consumed locally with no change to the last reconstructed progress tuple")
		end
		check(f:action(late.action_id) == nil and progress().outstanding_cursor == nil and #progress().consumed == 0,
			timing .. ": the completed old sweep still has no knowledge of the late consumed result")
		check(w:bridge_state(control_pane()).authority_revision < w:peer_revision()
			and w:bridge_state(control_pane()).session_progress ~= w:peer_progress(),
			timing .. ": another bridge's late arrival leaves the control pane's rendered projection stale")
		reads = w:peer_state_reads()
		probes, peer_before = owner_reads(), w:peer_revision()
		count = #controls()
		w:elapse(5000)
		writes, revision = f.memory.writes, f.authority.registry.revision
		w.api.schedule(w.cx)
		local refreshed = w:bridge_state(control_pane())
		check(owner_reads() == probes + 1 and #controls() == count and refreshed.authority_revision == peer_before
			and refreshed.session_progress == w:peer_progress() and refreshed.control_response == nil and w:peer_revision() == peer_before
			and f.memory.writes == writes and f.authority.registry.revision == revision,
			timing .. ": an existing read-only owner_status refreshes the stale control surface and replaces response metadata without writing either authority")
		settle()
		check(#controls() == count + 1, timing .. ": only the correlated fresh owner response enables reconciliation")
		reconcile()
		local discovered = progress()
		check(w:peer_state_reads() > reads and owner_reads() > probes and #discovered.consumed == 1 and discovered.consumed[1] == late.request_serial,
			timing .. ": changed native session progress discovers the late consumed hole despite unchanged local progress")
		local late_ack = reconcile()
		check(table.find(late_ack.consumed, late.request_serial) ~= nil and peer_entries[late.request_serial] == nil,
			timing .. ": the discovered late result is explicitly acknowledged without replaying its reclaimed effect")
		reconcile()
		writes, revision, count = f.memory.writes, f.authority.registry.revision, #controls()
		peer_before = w:peer_revision()
		for _ = 1, 24 do w:tick() end
		check(#controls() == count and f.memory.writes == writes and f.authority.registry.revision == revision and w:peer_revision() == peer_before,
			timing .. ": the completed acknowledgement sweep returns to quiescence with all seventeen lower outcomes retained")
	end
	end
	if section == nil or section == "bridge_paging_drain" then
	for _, request in retained do
		check_retained(request)
		complete_retained(request)
	end
	local drained = reconcile()
	check(drained.settled_before > retained[#retained].request_serial and next(peer_entries) == nil,
		"actual completion of the remaining effects advances the floor and drains peer retention")
	end
	end
	if section == nil or section == "bridge_paging_lower" then
	-- Relative serials 1,3..18 are already present; serial 2 arrives behind the first page's cursor.
	local lower_live = { claim_catalog() }
	local late_lower = claim_catalog(true)
	for _ = 1, 16 do table.insert(lower_live, hold_catalog()) end
	reconcile()
	local lower_cursor = clone(progress().outstanding_cursor)
	check(lower_cursor ~= nil and late_lower.request_serial == lower_live[1].request_serial + 1
		and lower_cursor.after_serial == lower_live[16].request_serial
		and lower_cursor.through_serial == lower_live[17].request_serial,
		"the first bounded page visits relative serials 1,3..17 while serial 2 is absent and serial 18 remains")
	local before_lower = shared.quota.digest(progress())
	finish_catalog(late_lower)
	check(shared.quota.digest(progress()) == before_lower and f:action(late_lower.action_id) == nil,
		"the lower late arrival is consumed locally without appearing in the already-read page")
	reconcile() -- The final page only visits serial 18, but its whole-session digest sees serial 2.
	check(progress().outstanding_cursor == nil and #progress().consumed == 0 and peer_entries[late_lower.request_serial] ~= nil,
		"finishing the old sweep neither discovers nor silently acknowledges the arrival behind its cursor")
	probes = owner_reads()
	local restarted = reconcile()
	check(restarted.outstanding_cursor == nil and owner_reads() > probes
		and table.find(progress().consumed, late_lower.request_serial) ~= nil,
		"the first-page baseline forces a new finite sweep that discovers the lower serial instead of absorbing the final-page digest")
	local lower_ack = reconcile()
	check(table.find(lower_ack.consumed, late_lower.request_serial) ~= nil and peer_entries[late_lower.request_serial] == nil
		and f:action(lower_live[1].action_id).phase == "claimed",
		"the next page explicitly acknowledges the discovered lower result while retaining the oldest live effect")
	reconcile(); reconcile() -- The ACK changed this sweep's peer set; confirm its now-stable finite pages.
	writes, revision, count, peer_before = f.memory.writes, f.authority.registry.revision, #controls(), w:peer_revision()
	for _ = 1, 36 do w:tick() end
	check(progress().outstanding_cursor == nil and #controls() == count and f.memory.writes == writes
		and f.authority.registry.revision == revision and w:peer_revision() == peer_before,
		"lower-between-pages discovery and acknowledgement reach quiescence rather than perpetual rescanning")
	for _, request in lower_live do
		check_retained(request)
		complete_retained(request)
	end
	reconcile()
	check(next(peer_entries) == nil, "only actual completion drains the remaining lower-arrival fixture effects")
	end
	if section == nil or section == "bridge_paging_generation" then
	local generation = progress().generation_floor
	local released = f.authority:apply(f:state_event("release_controller", {
		expected_owner_id = f.origin.owner_id, expected_generation = f.origin.owner_generation }))
	assert(released.ok, released.message)
	local admitted = f.authority:apply(f:state_event("admit_controller", {
		pane_binding = { host_pane_id = f.origin.host_pane_id, alias_nonce = f.origin.alias_nonce } }))
	assert(admitted.ok, admitted.message)
	w:palette("continue_controller"); w:pick({ continue_controller = true })
	assert(w:outcome().ok, w:outcome().message)
	f.origin = clone(w.events[#w.events].origin)
	count = #controls()
	local continuation_response_seen = false
	w:after_control_response(function(request)
		check(f.authority.registry.sessions[sid].admitted ~= true
			and request.control_origin.binding.owner_generation == f.origin.owner_generation,
			"the continued owner remains unadmitted until its own peer response is consumed")
		continuation_response_seen = true
	end)
	-- One continuation drives the remaining steps; no second manual reconciliation.
	w.api.schedule(w.cx); for _ = 1, 4 do w:tick() end
	settle()
	local changed_generation = controls()[#controls()]
	check(continuation_response_seen and #controls() == count + 1 and changed_generation.generation_floor > generation
		and changed_generation.control_origin.binding.owner_generation == f.origin.owner_generation
		and f.authority.registry.sessions[sid].admitted == true,
		"one explicit continuation admits the verified new generation and native-command origin")
	w:reload()
	w:palette("continue_controller"); w:pick({ continue_controller = true })
	assert(w:outcome().ok, w:outcome().message)
	f.origin = clone(w.events[#w.events].origin)
	count = #controls(); w.api.schedule(w.cx); settle()
	check(#controls() == count + 1 and controls()[#controls()].control_origin.binding.window_epoch == f.origin.window_epoch,
		"reload and explicit continuation reconcile the new native origin without replaying an old effect")
	count = #controls()
	w:click("bridge_reconcile"); settle()
	check(#controls() == count + 1, "explicit owner reconciliation remains available even when progress is unchanged")
	end
	if section == nil or section == "bridge_paging_prompt" then
	local project = f:apply("new_project", { name = "Captured completion intent" })
	assert(project.ok, project.message)
	f:catalog(0)
	reconcile()
	-- Capture a real current project prompt; an unrelated commit must not renew its fence.
	local captured_revision = f.authority.registry.revision
	w:click("project_finish", { orch_project_id = project.orch_project_id })
	assert(w:editor(), "project completion prompt required")
	w:click("pause")
	check(w:outcome().ok and f.authority.registry.revision > captured_revision,
		"pause commits an unrelated authority revision while the project summary remains open")
	writes = f.memory.writes
	local before = runtime.json.encode(f.authority.registry)
	local project_before = runtime.json.encode(f.authority.registry.dispatch.projects[project.orch_project_id])
	count = #controls()
	for _ = 1, 24 do w:tick() end
	check(#controls() == count and f.memory.writes == writes and runtime.json.encode(f.authority.registry) == before,
		"an unrelated authority revision does not change delivery progress or trigger automatic reconciliation during user prompts")
	local event_count, effect_count = #w.events, #w:bridge_events()
	w:answer("Keep this exact user completion summary fenced.")
	local submitted = w.events[#w.events]
	check(#w.events == event_count + 1 and submitted.command == "project_finish"
		and submitted.orch_project_id == project.orch_project_id
		and submitted.expected_revision == captured_revision
		and submitted.result == "Keep this exact user completion summary fenced.",
		"the actual project prompt submits its captured intent without refreshing the authority revision")
	check(not w:outcome().ok and w:outcome().code == "stale_revision"
		and f.memory.writes == writes and runtime.json.encode(f.authority.registry) == before
		and #w:bridge_events() == effect_count,
		"unrelated revision changes refuse the old project summary without a write, worker or effect")
	for _ = 1, 24 do w:tick() end
	check(runtime.json.encode(f.authority.registry.dispatch.projects[project.orch_project_id]) == project_before,
		"background reconciliation cannot replay the refused project completion")
	end
	for _, event in w:bridge_events() do
		check(event.op == "reconcile_session" or event.op == "owner_status",
			"progress reconciliation and reload never replay any claimed or completed effect")
	end
end
-- A staged native control can lose its captured revision before SPAWN authorizes it.
if section == nil or section == "bridge_authorization" then
	local intervened = false
	local w = window_fixture({ no_worker = true, before_control_authorization = function(f, request)
		if intervened then return end
		intervened = true
		local changed = f:apply("pause")
		assert(changed.ok and f.authority.registry.revision > request.authority_revision,
			"the staged control must encounter a real intervening authority commit")
	end })
	local f, sid = w.f, w.f.origin.logical_session_id
	assert(f:apply("policy", { policy = { sweep_enabled = false } }).ok)
	w:bridge({ placeholder = true })
	local function current_control() return f.authority.registry.sessions[sid].bridge_control end
	local function sent(request_id)
		local count = 0
		for _, event in w:bridge_events() do if event.request_id == request_id then count += 1 end end
		return count
	end
	w.api.schedule(w.cx)
	local original = clone(assert(current_control()))
	local peer_before = w:peer_revision()
	w:tick() -- SPAWN stages the immutable bytes; the real pause commits before native authorization.
	local withheld = w:control_authorizations()[1]
	check(withheld ~= nil and not withheld.authorized and withheld.captured_revision < withheld.observed_revision
		and flow(f).policy.paused and current_control().request_bytes == original.request_bytes
		and sent(original.request.request_id) == 1 and w:peer_revision() == peer_before,
		"an intervening commit withholds stale native control authorization without changing its bytes, replaying it or mutating SPAWN")
	local writes, revision = f.memory.writes, f.authority.registry.revision
	w.api.schedule(w.cx)
	local query = w:bridge_events()[#w:bridge_events()]
	check(query.op == "owner_status" and query.admission_seq == original.request.admission_seq
		and shared.quota.digest(query.origin_binding) == shared.quota.digest(original.request.control_origin.binding)
		and current_control().request_bytes == original.request_bytes and sent(original.request.request_id) == 1
		and f.memory.writes == writes and f.authority.registry.revision == revision and w:peer_revision() == peer_before,
		"a fresh read-only observation inspects the positively known current admission without refreshing or resending the captured control")
	w:tick()
	check(current_control() == nil and f.authority.registry.sessions[sid].admitted
		and w:outcome().command == "bridge_observe" and w:outcome().ok and w:outcome().code == "control_observed"
		and sent(original.request.request_id) == 1,
		"only the correlated positive owner observation clears the obsolete control while retaining admission")
	w:tick() -- Consume the observation and start the existing five-second cadence.
	w:elapse(4999); w.api.schedule(w.cx)
	check(current_control() == nil and #w:control_authorizations() == 1,
		"observation recovery does not immediately replace the old control in a mutating hot loop")
	w:elapse(1); w.api.schedule(w.cx)
	local fresh = clone(assert(current_control()))
	check(fresh.request.request_id ~= original.request.request_id and fresh.request.action_id ~= original.request.action_id
		and fresh.request.authority_revision > original.request.authority_revision
		and shared.quota.digest(fresh.request.control_origin) == shared.quota.digest(original.request.control_origin),
		"normal pacing creates a distinct current reconciliation intent under the same genuine native origin")
	w:tick(); w:tick(); w:tick()
	local authorized = w:control_authorizations()[2]
	check(authorized ~= nil and authorized.authorized and authorized.request_id == fresh.request.request_id
		and authorized.captured_revision == authorized.observed_revision and current_control() == nil
		and sent(fresh.request.request_id) == 1 and sent(original.request.request_id) == 1,
		"the new exact revision authorizes and settles once; the original staged control is never replayed")
	for _, event in w:bridge_events() do
		check(event.op == "reconcile_session" or event.op == "owner_status",
			"stale control recovery never launches or repeats an ordinary effect")
	end
end
-- A delivered SPAWN refusal needs its exact host receipt before read-only admission recovery.
if section == nil or section == "bridge_refusal" or section == "startup_recovery" then
	local refusal_codes = if section == "bridge_refusal" then { "stale_revision" }
		elseif section == "startup_recovery" then { "stale_binding" } else { "stale_revision", "stale_binding" }
	for _, refusal_code in refusal_codes do
	for _, advanced in { false, true } do for _, owner_answer in { "current", "absent", "unknown", "unreadable", "previous_incarnation", "other_binding" } do
		local refused, fixture = false, nil
		local options = { no_worker = true, hold_control_result_receipt = true, control_refusal = function(request)
			if refused then return nil end
			refused = true
			if advanced then assert(fixture:apply("pause").ok) end
			assert((advanced and fixture.authority.registry.revision > request.authority_revision)
				or (not advanced and fixture.authority.registry.revision == request.authority_revision),
				"the native refusal covers both unchanged and advanced local authority")
			return { code = refusal_code, message = if refusal_code == "stale_binding"
				then "binding_mismatch: Native operation deadline elapsed" else "Current exact native control challenge required" }
		end }
		local w = window_fixture(options)
		local f, sid = w.f, w.f.origin.logical_session_id
		fixture = f
		assert(f:apply("policy", { policy = { sweep_enabled = false } }).ok)
		w:bridge({ placeholder = true })
		w:owner_answer(owner_answer)
		local function current_control() return f.authority.registry.sessions[sid].bridge_control end
		local function commands(command)
			local out = {}
			for _, event in w.events do if event.command == command then table.insert(out, event) end end
			return out
		end
		local function wire_count(request_id)
			local count = 0
			for _, event in w:bridge_events() do if event.request_id == request_id then count += 1 end end
			return count
		end
		w.api.schedule(w.cx)
		local original = clone(assert(current_control()))
		local peer_before = w:peer_revision()
		w:tick(); w:tick() -- Deliver the canonical refusal through the real bridge_result reducer, withholding only its receipt.
		local deliveries = commands("bridge_result")
		local delivery = clone(assert(deliveries[1]))
		local rejected = assert(shared.codec.decode_dispatch_response(delivery.response_bytes, original.request))
		check(#deliveries == 1 and delivery.query_bytes == original.request_bytes
			and rejected.category == refusal_code and rejected.status == "rejected"
			and current_control().request_bytes == original.request_bytes and f.authority.registry.sessions[sid].admitted
			and w:peer_revision() == peer_before,
			owner_answer .. ": actual stale control delivery refuses without changing the original control or either admission")
		local writes, revision = f.memory.writes, f.authority.registry.revision
		w:tick(); w:tick()
		check(#w:bridge_events() == 1 and #commands("bridge_result") == 1 and #commands("bridge_observe") == 0
			and current_control().request_bytes == original.request_bytes and wire_count(original.request.request_id) == 1
			and f.memory.writes == writes and f.authority.registry.revision == revision,
			owner_answer .. ": a lost delivery receipt and unrelated creation receipt neither imply refusal nor replay the request or result")
		local receipt = w:release_control_receipt()
		check(receipt.request_id == delivery.request_id and receipt.command == "bridge_result"
			and receipt.ok == false and receipt.code == refusal_code,
			owner_answer .. ": recovery receives the exact real host refusal, not a fabricated success or arbitrary receipt")
		w.api.schedule(w.cx)
		local query = w:bridge_events()[#w:bridge_events()]
		check(query.op == "owner_status" and query.request_id ~= original.request.request_id
			and query.admission_seq == original.request.admission_seq
			and shared.quota.digest(query.origin_binding) == shared.quota.digest(original.request.control_origin.binding)
			and current_control().request_bytes == original.request_bytes and #commands("bridge_observe") == 0
			and f.memory.writes == writes and f.authority.registry.revision == revision and w:peer_revision() == peer_before,
			owner_answer .. ": exact stale refusal only starts a fresh read-only same-binding admission query")
		w:tick()
		if owner_answer == "current" then
			check(current_control() == nil and f.authority.registry.sessions[sid].admitted
				and w:outcome().command == "bridge_observe" and w:outcome().ok and w:outcome().code == "control_observed",
				"only correlated current same-binding admission proof both settles the stale control and confirms admission")
			w:tick() -- Consume the observation before checking the normal pacing boundary.
			w:elapse(4999); w.api.schedule(w.cx)
			check(current_control() == nil and #commands("bridge_control") == 1,
				"delivered refusal recovery preserves the existing reconciliation cadence")
			w:elapse(1); w.api.schedule(w.cx)
			local fresh = clone(assert(current_control()))
			check(fresh.request.request_id ~= original.request.request_id and fresh.request.action_id ~= original.request.action_id
				and fresh.request.authority_revision > original.request.authority_revision
				and shared.quota.digest(fresh.request.control_origin) == shared.quota.digest(original.request.control_origin),
				"positive observation permits a distinct normal reconciliation without refreshing the refused intent")
			w:tick(); w:tick(); w:tick()
			check(current_control() == nil and wire_count(fresh.request.request_id) == 1,
				"the new normal reconciliation settles exactly once after delivered refusal recovery")
		elseif owner_answer == "previous_incarnation" then
			check(current_control() == nil and f.authority.registry.sessions[sid].admitted ~= true
				and w:outcome().command == "bridge_observe" and w:outcome().ok and w:outcome().code == "control_observed",
				"verified prior-window route proof settles only its old reconcile control; it does not confer current-window admission")
			check(f:apply("catalog").code == "admission_required" and next(f.authority.registry.dispatch.workers) == nil,
				"settling a prior-window control cannot authorize even a catalog read or agent startup")
			-- Only this observation carries the old route. Current admission needs its own fresh control receipt.
			w:owner_answer("current")
			w:tick()
			if current_control() == nil then w:click("bridge_reconcile") end
			local fresh = clone(assert(current_control()))
			check(fresh.request.request_id ~= original.request.request_id and fresh.request.action_id ~= original.request.action_id
				and fresh.request.authority_revision > original.request.authority_revision
				and fresh.request.admission_seq == original.request.admission_seq
				and shared.quota.digest(fresh.request.control_origin) == shared.quota.digest(original.request.control_origin)
				and f.authority.registry.sessions[sid].admitted ~= true,
				"the unadmitted current route creates a distinct exact same-session control without reviving the refused request")
			for _ = 1, 8 do w:tick(); if current_control() == nil then break end end
			check(current_control() == nil and f.authority.registry.sessions[sid].admitted
				and wire_count(fresh.request.request_id) == 1 and wire_count(original.request.request_id) == 1,
				"only the fresh current-route control receipt restores admission, without replaying the old control or an ordinary effect")
		else
			w:tick(); w:elapse(6000); w:tick()
			check(current_control() ~= nil and current_control().request_bytes == original.request_bytes
				and f.authority.registry.sessions[sid].admitted and #commands("bridge_control") == 1
				and f.memory.writes == writes and f.authority.registry.revision == revision and w:peer_revision() == peer_before,
				owner_answer .. ": absent, unreadable or different-binding admission evidence cannot clear or replace the original control")
			if owner_answer == "unreadable" then
				check(#commands("bridge_observe") == 0, "an unreadable peer supplies no invented admission observation")
			else
				check(#commands("bridge_observe") == 1 and not w:outcome().ok,
					owner_answer .. ": the real reducer refuses non-authorizing admission evidence without writes")
			end
		end
		local original_results = 0
		for _, event in commands("bridge_result") do
			if event.request_id == delivery.request_id or event.query_bytes == original.request_bytes then
				original_results += 1
				check(event.request_id == delivery.request_id and event.query_bytes == original.request_bytes
					and event.response_bytes == delivery.response_bytes,
					owner_answer .. ": the refused delivery retains its exact immutable query and response bytes")
			end
		end
		check(original_results == 1 and wire_count(original.request.request_id) == 1,
			owner_answer .. ": neither the original control nor its refused result is resent during recovery")
		for _, event in w:bridge_events() do
			check(event.op == "reconcile_session" or event.op == "owner_status",
				owner_answer .. ": delivered control refusal recovery never executes an ordinary effect")
		end
	end end
	end
end

-- Confirmation language follows the same startup evidence as the rendered warning.
if section == nil or section == "startup_recovery" then
	local w = window_fixture({ no_worker = true })
	local f = w.f
	f:catalog(0)
	local queued = f:queue(false); assert(queued.ok)
	w:click("cancel_work", { worker_id = queued.worker_id })
	check(w:picker().placeholder:find("Cancel queued work", 1, true) == 1
		and w:picker().placeholder:find("normal startup does not require cancellation", 1, true) ~= nil
		and w:picker().placeholder:find("Continuation", 1, true) == nil,
		"pending startup confirmation is optional cancellation, not invented continuation recovery")
	w:pick({ confirm = false })
	check(f:action(queued.action_id).phase == "ready", "declining cancellation preserves normal ready startup")
	assert(f:apply("claim", { action_id = queued.action_id, executor = f.origin.window_epoch }).ok)
	local claimed = f:action(queued.action_id)
	assert(f:apply("lost", { action_id = queued.action_id, executor = claimed.claim.executor, grant_id = claimed.claim.grant_id }).ok)
	w:click("cancel_work", { worker_id = queued.worker_id })
	check(w:picker().placeholder:find("Check before cancelling work", 1, true) == 1
		and w:picker().placeholder:find("outcome is unconfirmed", 1, true) ~= nil
		and w:picker().placeholder:find("must first prove nonexecution", 1, true) ~= nil,
		"uncertain startup confirmation requires proof rather than claiming the effect never ran")
	w:pick({ confirm = false })
	check(f:action(queued.action_id).phase == "uncertain" and #w:bridge_events() == 0,
		"declining uncertain cancellation neither queries nor replays the original effect")
end

-- A normal owner queue follows the current admission through provisioning and launch,
-- including after a distinct-group switch and a definitively expired control challenge.
if section == nil or section == "startup_recovery" then
	for _, paused in { false, true } do
		local refused, effects = false, {}
		local w = window_fixture({ no_worker = true, commit_results = true,
			control_refusal = function()
				if refused then return nil end
				refused = true
				return { code = "stale_binding", message = "binding_mismatch: Native operation deadline elapsed" }
			end,
			startup_handler = function(f, request)
				table.insert(effects, clone(request))
				local action = assert(f:action(request.action_id))
				local status, facts
				if request.op == "mailbox_provision" then
					status = "provisioned"
					facts = { handle = "mailbox-startup", binding_digest = string.rep("a", 64),
						capabilities = runtime.json.array({ "report-files-v1", "native-ask-v1", "coordinator-control-v1", "project-start-v1" }) }
				else
					assert(f:apply("spawn_claimed", { action_id = request.action_id, grant_id = action.claim.grant_id,
						spawn_namespace = "fixture-spawn", claim_nonce = "startup-native-claim" }).ok)
					status = "awaiting_acceptance"
					facts = { pane_binding = { pane_id = "9002", window_key = f.origin.window_key,
						window_epoch = f.origin.window_epoch, native_session_id = f.origin.native_session_id,
						window_host_id = f.origin.window_host_id } }
				end
				return shared.frame(request, status, f:peer_payload(action, status, facts))
			end })
		local f, old_sid = w.f, w.f.origin.logical_session_id
		w:click("catalog") -- Leave an unstarted per-source driver in the previous group.
		local old_action = assert(w:outcome().action_id)
		w:click("pause")
		local old_session = runtime.json.encode(f.authority.registry.sessions[old_sid])
		assert(f.authority:apply(f:state_event("register_session", { orch_session_id = "startup-group", name = "Startup group" })).ok)
		local admitted = f.authority:apply(f:state_event("admit_controller", { orch_session_id = "startup-group",
			pane_binding = { host_pane_id = f.origin.host_pane_id, alias_nonce = f.origin.alias_nonce } }))
		assert(admitted.ok, admitted.message)
		f.origin = clone(f.origin)
		f.origin.logical_session_id = "startup-group"; f.origin.owner_id = admitted.owner_id; f.origin.owner_generation = admitted.generation
		w:click("resume")
		assert(f:control("admit_session").ok)
		assert(f:apply("policy", { policy = { sweep_enabled = false } }).ok)
		f:catalog(0)
		w:bridge({ placeholder = true })
		w:click("bridge_reconcile")
		local original = clone(assert(f.authority.registry.sessions["startup-group"].bridge_control))
		w:tick() -- The native receiver publishes the exact deadline refusal.
		-- This fixture exercises startup transport after an explicit task approval.
		-- The removed queue wizard is not an input route; native conversation creation
		-- has its own project/agent picker coverage.
		local queued = f:queue(false)
		assert(queued.ok and queued.worker_id and queued.action_id, queued.message)
		local function worker() return f.authority.registry.dispatch.workers[queued.worker_id] end
		check(worker().phase == "queued" and f:action(queued.action_id).request_bytes == nil,
			"one approved queue retains ordinary ready startup, not a continuation-fenced effect")
		local rendered = w:rendered(true)
		check(rendered:find("Startup pending:", 1, true) ~= nil and rendered:find("Cancel queued work", 1, true) ~= nil
			and rendered:find("explicit continuation fenced", 1, true) == nil
			and rendered:find("cancel this work and queue", 1, true) == nil,
			"normal pending startup stays cancellable without a false continuation warning or mandatory requeue")
		if paused then w:click("pause") end
		for _ = 1, 24 do
			w:tick()
			if worker().pane_binding or (paused and f.authority.registry.sessions["startup-group"].bridge_control == nil) then break end
		end
		if paused then
			for _ = 1, 3 do w:tick() end
			check(#effects == 0 and worker().phase == "queued" and f:action(queued.action_id).claim == nil
				and dispatch.policy(f.authority.registry, "startup-group").paused,
				"positive admission recovery never resumes a paused group or claims its ready startup")
			w:click("resume")
			for _ = 1, 24 do w:tick(); if worker().pane_binding then break end end
		end
		check(worker().phase == "awaiting_acceptance" and worker().pane_binding ~= nil and #effects == 2
			and effects[1].op == "mailbox_provision" and effects[2].op == "launch",
			"queue automatically provisions once and launches once without Execute, Retry or cancellation")
		for _, effect in effects do
			check(effect.logical_session_id == "startup-group"
				and shared.quota.digest(effect.origin_binding) == shared.quota.digest(f.origin),
				"startup uses only the explicitly selected new group's exact current origin")
		end
		local controls = 0
		for _, event in w:bridge_events() do if event.request_id == original.request.request_id then controls += 1 end end
		check(controls == 1 and runtime.json.encode(f.authority.registry.sessions[old_sid]) == old_session
			and dispatch.policy(f.authority.registry, old_sid).paused and f:action(old_action).phase == "ready"
			and f:action(old_action).request_bytes == nil,
			"recovery never replays the refused control, runs the previous group's action or changes its paused owner")
		for _, event in w.events do
			check(event.command ~= "retry" and event.command ~= "cancel_work" and event.command ~= "continue_controller",
				"normal startup requires no extra recovery or internal execution command")
		end
	end
end

-- Reconnect renews exhausted status observation, not the uncertain startup itself.
if section == nil or section == "startup_recovery" then
	local recover, outcome = false, nil
	local queries = {}
	local w = window_fixture({ no_worker = true, commit_results = true, bridge_handler = function(request)
		assert(request.op == "status", "paused startup recovery must only inspect the retained request")
		table.insert(queries, clone(request))
		return if recover then shared.frame(request, "found", { outcome = outcome }) else shared.frame(request, "missing")
	end })
	local f = w.f
	f:catalog(0)
	local queued = f:queue(false); assert(queued.ok)
	assert(f:apply("claim", { action_id = queued.action_id, executor = f.origin.window_epoch }).ok)
	local original = clone(f:action(queued.action_id))
	outcome = peer_body(original.request, "provisioned", f:peer_payload(original, "provisioned", {
		handle = "mailbox-reconnected", binding_digest = string.rep("a", 64),
		capabilities = runtime.json.array({ "report-files-v1", "native-ask-v1", "coordinator-control-v1", "project-start-v1" }),
	}))
	assert(f:apply("lost", { action_id = queued.action_id, executor = original.claim.executor, grant_id = original.claim.grant_id }).ok)
	w:click("pause"); w:bridge({ placeholder = true })
	for _ = 1, 80 do w:elapse(4500); w:tick() end
	check(#queries == 4 and f:action(queued.action_id).phase == "uncertain"
		and f:action(queued.action_id).claim.grant_id == original.claim.grant_id,
		"automatic missing observations stop at their bound without cancelling or replacing uncertain startup")
	for _ = 1, 8 do w:elapse(4500); w:tick() end
	check(#queries == 4, "an exhausted observation budget does not poll indefinitely")
	recover = true
	w:click("recovery_guide")
	for _ = 1, 24 do w:tick(); if f:action(queued.action_id) == nil then break end end
	check(#queries > 4 and f:action(queued.action_id) == nil
		and f.authority.registry.dispatch.workers[queued.worker_id].mailbox_handle == "mailbox-reconnected",
		"one Reconnect observes the now-available original outcome after automatic reads were exhausted")
	for _, query in queries do
		check(query.target_request_id == original.request.request_id and query.target_request_serial == original.request.request_serial,
			"recovery inspects only the exact original request")
	end
	for _, request in w:bridge_events() do
		check(request.op ~= "mailbox_provision" and request.op ~= "launch",
			"reconnection never resubmits startup or launches the next step of a paused project")
	end
	check(dispatch.policy(f.authority.registry, f.origin.logical_session_id).paused,
		"successful startup observation preserves the user's paused state")
end
-- A fresh read-only admission observation can itself cross an authority commit.
if section == nil or section == "control_observation" then
	local staged, observed = false, false
	local w = window_fixture({ no_worker = true,
		before_control_authorization = function(f)
			if not staged then staged = true; assert(f:apply("pause").ok) end
		end,
		before_authority = function(f, input)
			if input.command == "bridge_observe" and not observed then
				observed = true
				assert(f:apply("resume").ok)
			end
		end })
	local f, sid = w.f, w.f.origin.logical_session_id
	assert(f:apply("policy", { policy = { sweep_enabled = false } }).ok)
	w:bridge({ placeholder = true })
	local function queries()
		local out = {}
		for _, event in w:bridge_events() do if event.op == "owner_status" then table.insert(out, event) end end
		return out
	end
	w.api.schedule(w.cx)
	local original = clone(assert(f.authority.registry.sessions[sid].bridge_control))
	local peer_before = w:peer_revision()
	w:tick(); w:tick(); w:tick()
	local refused = clone(w:outcome())
	check(refused.command == "bridge_observe" and not refused.ok and refused.code == "stale_revision"
		and #queries() == 1 and f.authority.registry.sessions[sid].bridge_control.request_bytes == original.request_bytes,
		"an intervening commit refuses the read-only settlement without clearing or replaying the original control")
	w.api.schedule(w.cx)
	w:elapse(4999); w.api.schedule(w.cx)
	check(#queries() == 1, "a correlated stale observation does not start an unpaced read loop")
	w:elapse(1); w.api.schedule(w.cx)
	local reads = queries()
	check(#reads == 2 and reads[2].request_id ~= reads[1].request_id
		and reads[2].action_id ~= reads[1].action_id and reads[2].admission_seq == reads[1].admission_seq,
		"the stale observation causes a distinct fresh same-admission read, not resubmission of its old evidence")
	w:tick()
	check(f.authority.registry.sessions[sid].bridge_control == nil
		and f.authority.registry.sessions[sid].admitted and w:outcome().ok
		and w:outcome().command == "bridge_observe" and w:outcome().request_id ~= refused.request_id,
		"fresh current admission evidence settles the retained control after the exact stale read refusal")
	local mutations = 0
	for _, event in w:bridge_events() do
		if event.op ~= "owner_status" then
			mutations += 1
			assert(event.request_id == original.request.request_id)
		end
	end
	check(mutations == 1 and w:peer_revision() == peer_before,
		"read recovery neither replays the control nor executes or authorizes a native effect")
end
-- Definite pre-effect backpressure can be withdrawn, but a restored fresh draft or
-- a potentially started action missing from the peer cannot be called never executed.
if section == nil or section == "withdraw_fenced" then
	local function failed_allocation(initial, uncertain)
		local mode, target, provision, original, f = initial, nil, nil, nil, nil
		local subject = window_fixture({ no_worker = true, hold_poll = true, bridge_handler = function(request)
			if request.op == "mailbox_allocation" then
				if mode == "unknown" then return shared.frame(request, "uncertain", nil, { code = "target_unavailable", message = "Allocation is not conclusively known." }) end
				local observed = clone(target)
				if mode == "mismatch" then observed.worker_generation += 1 end
				return shared.frame(request, "allocation", { target = observed,
					allocation = if mode == "retained" then { state = "retained", provision = provision } else { state = "none" } })
			elseif request.op == "status" and uncertain then
				check(request.target_request_id == original.request_id and request.target_request_serial == original.request_serial,
					"uncertain cancellation reads the exact original provision rather than inventing a replacement")
				local row = dispatch.project(f.authority.registry, f.origin.logical_session_id, f.origin.alias_nonce).workers[target.worker_id]
				check(row and row.allocation_target == nil,
					"automatic allocation observation commits before reading uncertain provision status")
				return shared.frame(request, "full", { resource = "window_authorization", current = 1, limit = 1, retryable = true, effect_started = false })
			elseif request.op == "mailbox_retire" then return shared.frame(request, "pending") end
			error("Allocation recovery must not issue a startup operation: " .. tostring(request.op))
		end })
		f = subject.f
		local existing = f:accepted(false)
		local queued = f:queue(false); assert(queued.ok, queued.message)
		assert(f:apply("claim", { action_id = queued.action_id, executor = f.origin.window_epoch }).ok)
		provision = f:peer_payload(f:action(queued.action_id), "provisioned", { handle = "observer-retained",
			binding_digest = string.rep("e", 64), capabilities = runtime.json.array({ "report-files-v1", "native-ask-v1" }), limits = {} })
		original = clone(f:action(queued.action_id).request)
		if uncertain then
			local claim = f:action(queued.action_id).claim
			assert(f:apply("lost", { action_id = queued.action_id, executor = claim.executor, grant_id = claim.grant_id }).ok)
		else
			assert(f:finish(queued.action_id, "rejected", nil, { code = "storage_error", message = "Provisioning ended after prepare without a returned handle." }).ok)
		end
		local row = dispatch.project(f.authority.registry, f.origin.logical_session_id, f.origin.alias_nonce).workers[queued.worker_id]
		target = assert(row.allocation_target, "failed consumed provisioning requires its exact immutable allocation target")
		subject:bridge({ placeholder = true })
		return subject, queued.worker_id, existing, function(value) mode = value end
	end
	for _, mode in { "none", "retained", "unknown", "mismatch" } do
		local automatic, id, existing, change = failed_allocation(mode)
		local f = automatic.f
		local phase, reason = f.authority.registry.dispatch.workers[id].phase, runtime.json.encode(f.authority.registry.dispatch.workers[id].reason)
		for _ = 1, 24 do automatic:tick() end
		local current = assert(f.authority.registry.dispatch.workers[id])
		local row = dispatch.project(f.authority.registry, f.origin.logical_session_id, f.origin.alias_nonce).workers[id]
		check(current.phase == phase and runtime.json.encode(current.reason) == reason and automatic:picker() == nil,
			"automatic allocation facts preserve the original failure and require no internal-step question")
		check(f.authority.registry.dispatch.workers[existing] ~= nil and automatic.panes[9002] ~= nil,
			"allocation recovery does not cancel or close an accepted idle conversation")
		local facts, cancellations, startup = 0, 0, 0
		for _, event in automatic.events do if event.command == "observe_allocation" then facts += 1 elseif event.command == "cancel_work" then cancellations += 1 end end
		for _, request in automatic:bridge_events() do if request.op == "provision" or request.op == "launch" then startup += 1 end end
		check(cancellations == 0 and startup == 0, "automatic observation never cancels work, reprovisions a mailbox or launches an agent")
		if mode == "none" or mode == "retained" then
			check(facts >= 1 and row.allocation_target == nil
				and (mode ~= "retained" or current.mailbox_handle == "observer-retained"),
				"only a matching positive allocation proof records actual allocation-free or retained metadata")
			automatic:click("cancel_work", { worker_id = id }); automatic:pick({ confirm = true })
			for _ = 1, 12 do automatic:tick() end
			if mode == "none" then check(f.authority.registry.dispatch.workers[id] == nil, "owner cancellation releases positively allocation-free failed work")
			else
				local retires = 0
				for _, request in automatic:bridge_events() do if request.op == "mailbox_retire" then retires += 1 end end
				check(retires == 1 and f.authority.registry.dispatch.workers[id] ~= nil, "owner cancellation drives exactly one existing unused-mailbox retirement and retains work until confirmation")
			end
		else
			check(facts == 0 and row.allocation_target ~= nil and current.mailbox_handle == nil,
				"unknown or mismatched allocation proof cannot invent absence, recover a handle or remove failed work")
			if mode == "unknown" then
				change("none")
				for _ = 1, 40 do automatic:elapse(2000); automatic:tick() end
				local refreshed = dispatch.project(f.authority.registry, f.origin.logical_session_id, f.origin.alias_nonce).workers[id]
				check(refreshed and refreshed.allocation_target == nil and f.authority.registry.dispatch.workers[id].phase == phase,
					"unknown allocation is re-observed with fresh reads rather than negatively cached forever")
			end
		end
	end
	local waiting, waiting_id, accepted_id = failed_allocation("none", true)
	waiting:click("cancel_work", { worker_id = waiting_id }); waiting:pick({ confirm = true })
	for _ = 1, 32 do waiting:tick() end
	local fact_index, cancel_index, cancels = nil, nil, 0
	for index, event in waiting.events do
		if event.command == "observe_allocation" then fact_index = fact_index or index
		elseif event.command == "cancel_work" then cancel_index = index; cancels += 1 end
	end
	local reads = 0
	for _, request in waiting:bridge_events() do if request.op == "status" then reads += 1 end end
	check(fact_index and cancel_index and fact_index < cancel_index and cancels == 1 and reads == 1
		and waiting.f.authority.registry.dispatch.workers[waiting_id] == nil
		and waiting.f.authority.registry.dispatch.workers[accepted_id] ~= nil and waiting:picker() == nil,
		"one owner decision waits for automatic allocation facts and original refusal, then cancels only that allocation-free generation")
	local w = window_fixture()
	local f = w.f
	local queued = f:queue(false); assert(queued.ok, queued.message)
	assert(f:finish(queued.action_id, "provisioned", { handle = "mailbox-withdraw", binding_digest = string.rep("e", 64),
		capabilities = runtime.json.array({ "report-files-v1", "native-ask-v1" }), limits = {} }).ok)
	local wid = queued.worker_id
	local launch = f.authority.registry.dispatch.workers[wid].launch_action_id
	local expired = { resource = "window_authorization", current = 1, limit = 1, retryable = true, effect_started = false }
	assert(f:finish(launch, "full", expired).code == "backpressure")
	local fenced = f:action(launch)
	check(fenced.phase == "backpressure" and fenced.response.status == "full", "the live exact pre-effect refusal remains available for deliberate withdrawal")
	local r = fenced.request
	w:bridge(peer_body(r, "full", expired))
	w:click("cancel_work", { worker_id = wid })
	check(w:picker().placeholder:find("Cancel never-launched work", 1, true) == 1 and w:picker().placeholder:find("never-used mailbox is retired", 1, true) ~= nil,
		"the owner confirms withdrawal of the never-launched work first, told its unused mailbox is retired")
	local function withdrawal() local row = dispatch.project(f.authority.registry, f.origin.logical_session_id, f.origin.alias_nonce).workers[wid]; return if row then row.withdrawal else nil end
	check(withdrawal().mailbox_provisioned == true and withdrawal().mailbox_retire == "not_requested", "the withdrawal offer names the provisioned mailbox before any cancel")
	local before = #w:bridge_events()
	w:pick({ confirm = true })
	for _ = 1, 8 do if w:outcome() and w:outcome().command == "cancel_work" then break end; w:tick() end
	local reads = 0
	for index = before + 1, #w:bridge_events() do
		local e = w:bridge_events()[index]
		if e.op == "status" and e.target_request_id == r.request_id then reads += 1 end
	end
	check(reads == 0 and w:outcome().command == "cancel_work" and w:outcome().code == "withdrawal_retiring" and f.authority.registry.dispatch.workers[wid] ~= nil
		and withdrawal().mailbox_retire == "retiring" and withdrawal().status_required == false,
		"the exact current refusal needs no historical replay; withdrawal retains the worker until mailbox retirement")
	-- The window drives that retirement: it claims the retire action, sends the one exact
	-- mailbox_retire to SPAWN and delivers SPAWN's answer to the controller block as a
	-- `dispatch-result/<grant>/<epoch>` event. This fixture records that event instead of committing
	-- it (the host block commits it in production), so the test commits the delivered bytes.
	local retire_id = w:outcome().action_id
	local function delivered()
		local a = f:action(retire_id)
		if not a or not a.claim then return nil end
		for index = 1, #w:result_events() do -- Grants are unique, so only this retirement's delivery matches.
			local e = w:result_events()[index]
			local prefix = "dispatch-result/" .. a.claim.grant_id .. "/" -- The continued window's execution epoch follows.
			if e.act:sub(1, #prefix) == prefix then return e end
		end
		return nil
	end
	local ticks = 0
	for _ = 1, 12 do if delivered() then break end; w:tick(); ticks += 1 end
	local retires = 0
	for index = before + 1, #w:bridge_events() do if w:bridge_events()[index].op == "mailbox_retire" then retires += 1 end end
	local delivery = delivered()
	local claim = f:action(retire_id) and f:action(retire_id).claim
	-- Commit under the exact controller origin that created this withdrawal intent.
	for index = #w.events, 1, -1 do if w.events[index].command == "cancel_work" then f.origin = clone(w.events[index].origin); break end end
	local envelope = if delivery then runtime.json.decode(delivery.value) else nil
	local committed = if envelope and claim then f:apply("result", { action_id = retire_id, executor = claim.executor, grant_id = claim.grant_id,
		authority_namespace = envelope.authority_namespace, expected_revision = envelope.expected_revision, response_bytes = envelope.response_bytes }) else nil
	local retired_worker = f.authority.registry.dispatch.workers[wid]
	check(retires == 1 and committed ~= nil and committed.ok and retired_worker ~= nil and retired_worker.mailbox_retired == true,
		"the withdrawal driver sends the one exact retirement and SPAWN's confirmation is recorded; retires=" .. retires .. " ticks=" .. ticks
			.. " retire_phase=" .. tostring(f:action(retire_id) and f:action(retire_id).phase) .. " delivered=" .. tostring(delivery ~= nil)
			.. " commit=" .. tostring(committed and committed.code) .. " mailbox_retired=" .. tostring(retired_worker and retired_worker.mailbox_retired)
			.. " reason=" .. tostring(retired_worker and retired_worker.reason and retired_worker.reason.code))
	assert(f:queue(false).ok)
	check(f.authority.registry.dispatch.workers[wid] == nil, "the retired never-launched worker is reclaimed")
	local uncertain = shared.fixture()
	uncertain:catalog(0)
	local pending = uncertain:queue(false); assert(pending.ok)
	assert(uncertain:finish(pending.action_id, "provisioned", { handle = "mailbox-unknown", binding_digest = string.rep("f", 64),
		capabilities = runtime.json.array({ "report-files-v1", "native-ask-v1" }), limits = {} }).ok)
	local unknown_id = uncertain.authority.registry.dispatch.workers[pending.worker_id].launch_action_id
	local launch_identity = uncertain.authority.registry.dispatch.workers[pending.worker_id].launch_request_id
	assert(uncertain:apply("claim", { action_id = unknown_id, executor = uncertain.origin.window_epoch }).ok)
	local unknown = clone(uncertain:action(unknown_id))
	assert(uncertain:apply("lost", { action_id = unknown_id, executor = unknown.claim.executor, grant_id = unknown.claim.grant_id }).ok)
	local q = { schema = 2, origin = "orchplus", op = "status", request_id = "withdraw-status", action_id = "withdraw-status-action",
		authority_namespace = unknown.request.authority_namespace, logical_session_id = unknown.request.logical_session_id,
		admission_seq = unknown.request.admission_seq, origin_binding = clone(unknown.request.origin_binding),
		controller_pane = unknown.request.controller_pane, controller_generation = unknown.request.controller_generation,
		target_request_id = unknown.request.request_id, target_request_serial = unknown.request.request_serial }
	local unchanged = runtime.json.encode(uncertain.authority.registry)
	check(uncertain:apply("cancel_work", { worker_id = pending.worker_id, query_bytes = runtime.json.encode(q),
		response_bytes = shared.frame(q, "missing", nil) }).code == "unknown_effect"
		and runtime.json.encode(uncertain.authority.registry) == unchanged,
		"missing peer state cannot prove that a potentially started launch never executed")
	assert(uncertain:apply("result", { action_id = unknown_id, executor = unknown.claim.executor, grant_id = unknown.claim.grant_id,
		response_bytes = shared.frame(unknown.request, "full", expired) }).ok)
	local retry = uncertain:apply("retry", { action_id = unknown_id }); assert(retry.ok)
	check(uncertain:action(retry.action_id).request_bytes == nil
		and uncertain:action(retry.action_id).retry_after_serial == unknown.request.request_serial
		and uncertain.authority.registry.dispatch.workers[pending.worker_id].launch_request_id == launch_identity,
		"a fresh launch attempt retains its worker identity and waits for consumption of the exact prior serial")
	check(uncertain:apply("claim", { action_id = retry.action_id, executor = uncertain.origin.window_epoch }).code == "peer_reconcile_required",
		"an unacknowledged full result cannot be replaced by a new launch claim")
	uncertain.authority = shared.host.new_authority(uncertain.memory); assert(uncertain.authority:load().ok)
	assert(uncertain:apply("continue_controller", { operator_verified = true }).ok)
	assert(uncertain:control("reconcile_session").ok)
		local restored = uncertain:action(retry.action_id)
		check(restored.phase == "held_ready" and restored.request_bytes == nil and restored.claim == nil
			and restored.retry_after_serial == nil,
			"restored retry remains unissued and held after the peer consumes its exact older refusal")
		local held = runtime.json.encode(uncertain.authority.registry)
		check(not uncertain:apply("claim", { action_id = retry.action_id, executor = uncertain.origin.window_epoch }).ok
			and runtime.json.encode(uncertain.authority.registry) == held,
			"reconciliation cannot turn a restored unissued retry into permission to launch")
		check(not uncertain:apply("cancel_work", { worker_id = pending.worker_id, query_bytes = runtime.json.encode(q),
			response_bytes = shared.frame(q, "found", { outcome = peer_body(unknown.request, "full", expired) }) }).ok
			and runtime.json.encode(uncertain.authority.registry) == held,
			"an older request's pre-effect refusal is not evidence for the current unissued retry")
		local cancelled = uncertain:apply("cancel_work", { worker_id = pending.worker_id })
		check(cancelled.ok and cancelled.code == "withdrawal_retiring"
			and uncertain:action(retry.action_id) == nil and uncertain:action(cancelled.action_id).request.op == "mailbox_retire"
			and uncertain.authority.registry.dispatch.workers[pending.worker_id] ~= nil,
			"explicit cancellation of the proven unissued retry only retires its mailbox and retains the worker until positive proof")
end
-- Pre-controller catalog forwarding uses SPAWN's structured page cursor without writing authority.
if section == nil or section == "config_cards" then
	local refs = assert(shared.host.repository_refs("refs/heads/feature\t\nrefs/heads/release\t\nrefs/remotes/origin/HEAD\trefs/remotes/origin/release\nrefs/remotes/origin/release\t\n"))
	check(refs.default_ref == "refs/heads/release", "offline remote HEAD metadata selects a non-main repository default independently of a feature checkout")
	local conflict = assert(shared.host.repository_refs("refs/heads/feature\t\nrefs/heads/release\t\nrefs/heads/stable\t\nrefs/remotes/origin/HEAD\trefs/remotes/origin/release\nrefs/remotes/upstream/HEAD\trefs/remotes/upstream/stable\n"))
	check(conflict.default_ref == nil and #conflict.branches == 3, "conflicting remote defaults retain existing local targets for explicit selection")
	local missing = assert(shared.host.repository_refs("refs/heads/feature\t\nrefs/remotes/origin/HEAD\trefs/remotes/origin/release\n"))
	check(missing.default_ref == nil, "a missing local advertised default never silently substitutes the feature branch")
	local stored, writes, marker, marker_writes = state.new_registry(), 0, nil, 0
	local definition
	local fake = table.clone(runtime)
	fake.kv = { get = function(key)
		if key == "authority_state_initialized" then return clone(marker) end
		assert(key == "authority_state")
		return clone(stored)
	end, set = function(key, value)
		if key == "authority_state_initialized" then marker = clone(value); marker_writes += 1; return end
		assert(key == "authority_state")
		stored = clone(value); writes += 1
	end }
	fake.block = { define = function(id, value) if id == "orchestrator" then definition = value end end }
	fake.on = function() end
	fake.timer = function() return { cancel = function() end } end
	local chunk = assert(loadstring(runtime.fs.read(root .. "/host.luau"), "health-setup-cursor-host"))
	setfenv(chunk, setmetatable({ tern = fake, require = shared.load }, { __index = environment }))
	chunk()
	local cx = { pane = 42, render = function() end }
	local view = definition.init(cx, { "config" }, nil)
	check(marker == true and marker_writes == 1, "the existing health fixture backfills its separate installation marker once")
	local before, baseline_writes = runtime.json.encode(stored), writes
	local origin = { host_pane_id = "42", window_key = "", window_epoch = "setup-cursor-window",
		native_session_id = "7", window_host_id = "local" }
	local serial = 0
	local function request(cursor)
		serial += 1
		return { schema = 2, origin = "orchplus", op = "catalog", request_id = "catalog-page-" .. serial,
			action_id = "catalog-action-" .. serial, setup_origin = clone(origin), cursor = cursor }
	end
	local function send(value, nonce, outer_origin)
		definition.event(view, { ev = "action", act = "setup-command", value = runtime.json.encode({
			kind = "catalog_request", source_nonce = nonce or view.alias_nonce, request_id = "host-" .. value.request_id,
			setup_origin = outer_origin or clone(origin), request = value,
		}) }, cx)
	end
	local function published()
		local function find(node)
			if node.p and node.p.role == "orchplus.setup.request" then
				local span = node.p.spans[1]
				return runtime.json.decode(if type(span) == "string" then span else span.t)
			end
			for _, child in node.c or {} do local found = find(child); if found then return found end end
			return nil
		end
		return find(definition.view(view, cx).main)
	end
	-- Deterministic SPAWN response fixtures use the actual framed consumer, not a string cursor
	-- or a source-text assertion. Every returned cursor must survive the host view roundtrip.
	local cursor, seen = nil, {}
	for page = 1, 3 do
		local outgoing = request(cursor)
		send(outgoing)
		local forwarded = assert(published())
		check(view.setup_result.ok and view.setup_result.code == "catalog_requested"
			and view.setup_result.request_id == "host-" .. outgoing.request_id
			and shared.quota.digest(forwarded) == shared.quota.digest(outgoing),
			"setup catalog page " .. page .. " forwards the exact request and structured cursor through the real host surface")
		local records = {}
		for index = (page - 1) * 2 + 1, page * 2 do
			table.insert(records, { id = "record-" .. index, revision = 7, provider = "omp", account_label = "fixture",
				backend = "native-agent", enabled = true, eligible = true, capabilities = runtime.json.array({ "report-files-v1" }),
				unsupported = runtime.json.array(), capability_evidence = "configured_operator_attestation_not_runtime_proof",
				effective_identity = { provider = "omp", identity_status = "configured_not_verified" }, cwd = "/fixture", placement = "split" })
		end
		local body = { schema = 2, op = "catalog", request_id = forwarded.request_id, action_id = forwarded.action_id,
			setup_origin = forwarded.setup_origin, category = "current_result", status = "catalog", payload = {
				catalog_version = 2, namespace = "fixture-spawn", host_key = "fixture-host", revision = 7, config_revision = 7,
				setup = { schema = 1, state = "completed", config_revision = 7,
					readiness = { state = "not_run", config_revision = 7, summary = "" } },
				records = runtime.json.array(records), next_cursor = if page < 3 then { revision = 7, index = page * 2 + 1 } else nil,
			} }
		local wire = assert(shared.codec.encode_dispatch_response(body))
		local response = assert(protocol.decode_setup_response(wire, forwarded))
		for _, record in response.payload.records do table.insert(seen, record.id) end
		cursor = response.payload.next_cursor
	end
	check(cursor == nil and table.concat(seen, ",") == "record-1,record-2,record-3,record-4,record-5,record-6",
		"second and subsequent setup pages reach the full fixture roster without losing records")
	for _, value in { { revision = 0, index = 1 }, { revision = 9007199254740991, index = 9007199254740991 } } do
		send(request(value))
		check(view.setup_result.ok and shared.quota.digest(published().cursor) == shared.quota.digest(value),
			"host accepts SPAWN's inclusive numeric cursor bounds without coercion")
	end
	local retained = shared.quota.digest(published())
	for _, value in { "page-2", 2, false, {}, { revision = 7 }, { index = 3 }, { revision = "7", index = 3 },
		{ revision = 7, index = "3" }, { revision = false, index = 3 }, { revision = 7, index = true },
		{ revision = -1, index = 3 }, { revision = 7, index = 0 }, { revision = 7, index = -1 },
		{ revision = 0.5, index = 3 }, { revision = 7, index = 1.5 },
		{ revision = 9007199254740992, index = 3 }, { revision = 7, index = 9007199254740992 },
		{ revision = 7, index = 3, extra = true }, runtime.json.array({ 7, 3 }) } do
		send(request(value))
		check(not view.setup_result.ok and view.setup_result.code == "invalid_catalog_request"
			and shared.quota.digest(published()) == retained,
			"malformed, nonclosed or out-of-bound cursor refuses without replacing the pending catalog request")
	end
	local result = shared.quota.digest(view.setup_result)
	for _, raw_cursor in { "null", '{"revision":7,"index":1e309}', '{"revision":1e309,"index":3}',
		'{"revision":7,"index":3,"index":4}', '{"revision":7,"index":' } do
		local malformed = runtime.json.encode({ kind = "catalog_request", source_nonce = view.alias_nonce,
			request_id = "malformed-cursor", request = request("RAW_CURSOR") }):gsub('"RAW_CURSOR"', function() return raw_cursor end)
		definition.event(view, { ev = "action", act = "setup-command", value = malformed }, cx)
		check(shared.quota.digest(view.setup_result) == result and shared.quota.digest(published()) == retained,
			"null, nonfinite, duplicate-key or truncated cursor is rejected before changing host view state")
	end
	send(request({ revision = 7, index = 3 }), "foreign-source-nonce")
	check(shared.quota.digest(view.setup_result) == result and shared.quota.digest(published()) == retained,
		"structured cursor cannot bypass source nonce correlation")
	local foreign = clone(origin); foreign.window_epoch = "another-window"
	send(request({ revision = 7, index = 3 }), nil, foreign)
	check(view.setup_result.code == "invalid_catalog_request" and shared.quota.digest(published()) == retained,
		"structured cursor cannot bypass outer and request setup-origin correlation")
	local wrong = request({ revision = 7, index = 3 }); wrong.setup_origin.host_pane_id = "99"
	send(wrong)
	check(view.setup_result.code == "invalid_catalog_request" and shared.quota.digest(published()) == retained,
		"structured cursor cannot forward a request naming another host view")
	check(writes == baseline_writes and runtime.json.encode(stored) == before and next(stored.sessions) == nil,
		"setup catalog pages and refusals create no controller, history or authority mutation")

	-- Legacy inspection needs the same validated read-only catalog transport,
	-- not permission to configure or initialize the existing authority.
	local empty = state.new_registry()
	stored = { version = 3, revision = 0, next_session_id = 0, next_owner_id = 0, execution_epoch = 1,
		sessions = {}, request_outcomes = {}, retired = {}, setup = clone(empty.setup),
		installation_defaults = clone(empty.installation_defaults) }
	chunk()
	view = definition.init(cx, { "config" }, nil)
	local legacy_bytes, legacy_writes, legacy_marker_writes = runtime.json.encode(stored), writes, marker_writes
	local legacy_request = request(nil)
	send(legacy_request)
	check(view.setup_result.ok and view.setup_result.code == "catalog_requested"
		and shared.quota.digest(published()) == shared.quota.digest(legacy_request),
		"legacy migration can publish its exact read-only catalog request through the native HOST view")
	local legacy_published = shared.quota.digest(published())
	local malformed = request(nil); malformed.op = "launch"
	send(malformed)
	check(view.setup_result.code == "invalid_catalog_request" and shared.quota.digest(published()) == legacy_published,
		"legacy catalog admission cannot forward an effect disguised as a read-only request")
	local foreign_request = request(nil); foreign_request.setup_origin.host_pane_id = "99"
	send(foreign_request)
	check(view.setup_result.code == "invalid_catalog_request" and shared.quota.digest(published()) == legacy_published,
		"legacy catalog admission retains the exact native HOST origin boundary")
	local refused = shared.quota.digest(view.setup_result)
	send(request(nil), "stale-legacy-view")
	check(shared.quota.digest(view.setup_result) == refused and shared.quota.digest(published()) == legacy_published,
		"a stale legacy view cannot replace the pending catalog request")
	for _, command in {
		{ act = "setup-command", kind = "installation_defaults" },
		{ act = "setup-command", kind = "setup_lifecycle" },
		{ act = "setup-repository-probe", kind = "catalog_request" },
	} do
		definition.event(view, { ev = "action", act = command.act, value = runtime.json.encode({
			kind = command.kind, source_nonce = view.alias_nonce, request_id = "legacy-mutation-" .. command.kind,
			setup_origin = clone(origin),
		}) }, cx)
		check(view.setup_result.code == "authority_unavailable" and shared.quota.digest(published()) == legacy_published,
			"legacy inspection does not authorize " .. command.act .. "/" .. command.kind)
	end
	definition.event(view, { ev = "action", act = "setup-command", value = runtime.json.encode({
		kind = "catalog_clear", source_nonce = view.alias_nonce, request_id = "legacy-clear", setup_origin = clone(origin),
	}) }, cx)
	check(view.setup_result.ok and view.setup_result.code == "catalog_cleared" and published() == nil,
		"legacy inspection can clear only its transient catalog publication")
	check(runtime.json.encode(stored) == legacy_bytes and writes == legacy_writes and marker_writes == legacy_marker_writes,
		"legacy catalog publication, clear and refusals preserve exact authority and initialization evidence")
	for _, unavailable in {
		{ name = "absent", initialized = false },
		{ name = "missing-established", initialized = true },
		{ name = "quarantined", initialized = true, source = { invalid_authority = true } },
	} do
		stored = clone(unavailable.source)
		marker = if unavailable.initialized then true else nil
		chunk()
		view = definition.init(cx, { "config" }, nil)
		local unavailable_bytes, unavailable_writes, unavailable_marker_writes = runtime.json.encode(stored), writes, marker_writes
		send(request(nil))
		local catalog_available = if unavailable.name == "absent" then view.setup_result.ok and published() ~= nil
			else view.setup_result.code == "authority_unavailable" and published() == nil
		check(catalog_available and runtime.json.encode(stored) == unavailable_bytes and writes == unavailable_writes
			and marker_writes == unavailable_marker_writes,
			"catalog inspection preserves " .. unavailable.name .. " authority without initialization or repair")
	end
end

-- Grouped settings are a separate progressive editor, not the old multi-card checkbox maze.
if section == nil or section == "config_cards" then
	local f = shared.fixture()
	local views = shared.load("views")
	local function render(nonce)
		local projection = state.project(f.authority.registry)
		projection.dispatch = dispatch.project(f.authority.registry, f.origin.logical_session_id, f.origin.alias_nonce)
		local view = { pane = 42, alias_nonce = nonce, orch_session_id = f.origin.logical_session_id, config_open = true, action_serial = 0 }
		local tree = views.render(view, projection, "ready")
		return tree, view
	end
	local tree, view = render(f.origin.alias_nonce)
	local defaults, settings, save_defaults = false, false, false
	for _, entry in view.actions do
		defaults = defaults or entry.kind == "setup-intent" and entry.command == "defaults"
		settings = settings or entry.kind == "operator-intent" and entry.request.command == "settings"
		save_defaults = save_defaults or entry.kind == "operator-intent" and entry.request.command == "save_defaults"
		check(entry.kind ~= "config-step" and entry.kind ~= "config-move" and entry.kind ~= "config-change", "obsolete +/- and checkbox workflow is absent")
	end
	check(defaults and settings and save_defaults, "settings distinguish reusable defaults from orchestration overrides")
	local hidden, visible_json = 0, false
	local function walk(node)
		if type(node) ~= "table" then return end
		if node.p and node.p.hidden then hidden += 1; return end
		for _, span in (if node.p then node.p.spans or {} else {}) do
			local text = if type(span) == "string" then span else span.t
			if type(text) == "string" and text:sub(1, 1) == "{" then visible_json = true end
		end
		for _, child in node.c or {} do walk(child) end
	end
	walk(tree)
	check(hidden > 0 and not visible_json, "machine channels remain readable nodes without visible JSON")
	local _, foreign = render("another-view")
	for _, entry in foreign.actions do
		check(not (entry.kind == "operator-intent" and (entry.request.command == "settings" or entry.request.command == "save_defaults")), "another view cannot edit admitted orchestration settings")
	end
	local w = window_fixture({ no_worker = true })
	local saved_defaults = runtime.json.encode(w.f.authority.registry.installation_defaults)
	w:click("policy", { policy = { require_code_review = false }, expected_sha256 = shared.quota.digest(flow(w.f).policy) })
	check(w:outcome().ok and not flow(w.f).policy.require_other_family, "review-off normalizes its dependent family requirement")
	check(runtime.json.encode(w.f.authority.registry.installation_defaults) == saved_defaults, "changing an orchestration does not silently overwrite installation defaults")
end
if section == nil or section == "work_picker" then
	for _, glitch in { false, true } do
		local w = window_fixture({ no_worker = true })
		assert(w.f:apply("policy", { policy = { glitch_integration = glitch } }).ok)
		w:click("orchestration_menu")
		local choices = {}
		for _, item in w:picker().items do if item.source then choices[item.source] = true end end
		check(choices["add-plan"] and choices["add-board"] and choices["start-template"], "neutral source actions remain available without a Glitch installation")
		local projection = state.project(w.f.authority.registry)
		projection.dispatch = dispatch.project(w.f.authority.registry, w.f.origin.logical_session_id, w.f.origin.alias_nonce)
		local view = { pane = 42, alias_nonce = w.f.origin.alias_nonce, orch_session_id = w.f.origin.logical_session_id, action_serial = 0 }
		shared.load("views").render(view, projection, "ready")
		local work_on = false
		for _, entry in view.actions do
			if entry.kind == "operator-intent" and entry.request.command == "work-on" then work_on = true end
		end
		check(work_on == glitch, "WORK ON project discovery appears only with Glitch integration enabled")
		check(#w.board_opened == 0 and #w.events == 0, "opening source choices never starts work or guesses a board")
	end
end

-- Checkpoint 6 (D12, Contract K): the window's inbox poller archives a file only after its intake
-- is accepted; a window restart before the archive re-scans and archives without a second intake.
if section == nil or section == "inbox_window" then
	local w = window_fixture({ no_worker = true, forbid_desktop_inbox = true })
	w.f:catalog(0) -- No unrelated live checkout worker: this section isolates intake/archive ordering.
	local dir = "/tmp/orch-cp6d-" .. shared.codec.sha256(tostring(os.clock()) .. ":" .. tostring(math.random())):sub(1, 16)
	runtime.fs.mkdir(dir)
	local saved = w.f:apply("policy", { policy = { inbox_folder = dir, auto_start_projects = true, poll_ms = 1000,
		preferred_worker_record = "native" } })
	assert(saved.ok, saved.message)
	local body = "**CLASS**: build\n\nImplement the inbox window fixture.\n"
	runtime.fs.write(dir .. "/task.md", body)
	local id = shared.quota.digest({ kind = "inbox", path = dir .. "/task.md", sha256 = shared.codec.sha256(body) })
	local function intakes() local n, last = 0, nil; for _, e in w.events do if e.command == "inbox_intake" then n += 1; last = e end end; return n, last end
	for _ = 1, 8 do if intakes() > 0 then break end; w:tick() end
	local count, sent = intakes()
	check(count == 1 and sent.name == "task.md" and sent.content_sha256 == shared.codec.sha256(body), "the poller sends one inbox_intake {name, content_sha256}")
	local rec = w.f.authority.registry.dispatch.intakes[id]
	check(rec and rec.state == "accepted", "the host accepted the intake under the window's intake_id")
	check(runtime.fs.exists(dir .. "/task.md"), "the file is not archived in the tick that sent the intake")
	-- Window restart before the archive: in-memory poller state is lost.
	w:reload()
	local taken = dir .. "/.orchplus-taken/" .. id .. "-task.md"
	for _ = 1, 12 do if runtime.fs.exists(taken) then break end; w:tick() end
	check(runtime.fs.exists(taken) and runtime.fs.read(taken, 65536) == body and not runtime.fs.exists(dir .. "/task.md"),
		"after a restart the re-scan archives the accepted file to .orchplus-taken/<intake_id>-<name>")
	check(intakes() == 1, "the restarted window archives without re-intake")
	-- Other way: a received (not accepted) intake is never archived.
	local g = window_fixture({ no_worker = true })
	g.f:catalog(0)
	local dir2 = dir .. "-held"; runtime.fs.mkdir(dir2)
	assert(g.f:apply("policy", { policy = { inbox_folder = dir2, auto_start_projects = true, poll_ms = 1000, preferred_worker_record = "" } }).ok)
	runtime.fs.write(dir2 .. "/task.md", body)
	for _ = 1, 12 do g:tick() end
	local held = g.f.authority.registry.dispatch.intakes[shared.quota.digest({ kind = "inbox", path = dir2 .. "/task.md", sha256 = shared.codec.sha256(body) })]
	check(held and held.state == "received" and runtime.fs.exists(dir2 .. "/task.md") and not runtime.fs.exists(dir2 .. "/.orchplus-taken"),
		"an intake that is only received (no route) leaves the file in the inbox")
end
-- Strings of a rendered view tree, in order (machine nodes included; callers match by prefix).
local function strings(node, out)
	if type(node) ~= "table" then return out end
	for key, value in node do
		if type(value) == "string" then table.insert(out, value) elseif key ~= "actions" then strings(value, out) end
	end
	return out
end
local function render_view(f, extra)
	local projection = state.project(f.authority.registry)
	projection.dispatch = dispatch.project(f.authority.registry, f.origin.logical_session_id, f.origin.alias_nonce)
	local view = { pane = 42, alias_nonce = f.origin.alias_nonce, orch_session_id = f.origin.logical_session_id, action_serial = 0 }
	for key, value in extra or {} do view[key] = value end
	return view, projection
end
-- Native control identity is current-only: equal consecutive descriptors keep their token,
-- but no changed, removed or reincarnated control can recover an earlier identity.
if section == nil or section == "controls" then
	local f = shared.fixture(function() return { now_ms = 1700000000000, mono_ms = 1000, epoch = "control-identity" } end)
	assert(f:apply("new_project", { name = "Live project navigation" }).ok)
	local id = f:accepted(false)
	assert(f:apply("intake", { worker_id = id, bytes = f:report(id, 2, "ASK", {
		question = "Keep this exact question current", options = runtime.json.array({ { id = "yes", label = "Yes" } }),
	}) }).ok)
	local views = shared.load("views")
	local view, projection = render_view(f, { workflow_worker = id, advanced_open = true })
	local durable, writes = runtime.json.encode(f.authority.registry), f.memory.writes
	local function redraw()
		return views.render(view, projection, "ready")
	end
	local function control(matches)
		for _, token in view.action_order do
			local entry = view.actions[token]
			if matches(entry) then return token, entry end
		end
		return nil
	end
	local function answer(entry) return entry.kind == "operator-intent" and entry.request.command == "answer" end
	local function inspect(entry)
		return entry.kind == "assist-intent" and entry.request.kind == "inspect" and entry.request.target == "controller"
	end
	local function config(entry) return entry.kind == "config-open" end
	redraw()
	local first_order = table.clone(view.action_order)
	-- Reconstructed but unchanged state must leave the displayed buttons usable.
	projection = clone(projection)
	redraw()
	for _, token in first_order do
		check(view.actions[token] ~= nil, "an unchanged redraw preserves the displayed native click target")
	end
	local function project_menu(entry) return entry.kind == "operator-intent" and entry.request.command == "project_menu" end
	local menu_token = assert(control(project_menu))
	local old_revision = projection.revision
	projection.revision += 1
	redraw()
	check(control(project_menu) == menu_token and view.actions[menu_token] ~= nil,
		"background workflow progress must not invalidate an otherwise unchanged project-menu click")
	projection.revision = old_revision
	redraw()
	local function invalidates(matches, change, restore, label)
		local before = assert(control(matches), label)
		change(); redraw()
		local changed = assert(control(matches), label)
		check(changed ~= before and view.actions[before] == nil,
			label .. " removes the stale click target")
		restore(); redraw()
		local returned = assert(control(matches), label)
		check(returned ~= before and returned ~= changed and view.actions[before] == nil and view.actions[changed] == nil,
			label .. " ABA never revives either discarded token")
	end
	local owner
	for _, session in projection.sessions do if session.orch_session_id == view.orch_session_id then owner = session.controller end end
	assert(owner)
	local gate
	for _, candidate in projection.dispatch.workflow.gates do if candidate.kind == "owner_question" then gate = candidate end end
	assert(gate)
	for _, case in {
		{ projection, "authority_namespace", "replacement-authority", answer, "authority namespace" },
		{ projection, "authority_namespace", "replacement-navigation-authority", project_menu, "navigation authority namespace" },
		{ projection, "revision", projection.revision + 1, answer, "authority revision" },
		{ owner, "owner_id", "replacement-owner", inspect, "nested owner identity" },
		{ owner, "generation", owner.generation + 1, inspect, "nested owner generation" },
		{ gate, "revision", gate.revision + 1, answer, "nested gate revision" },
	} do
		local target, key, replacement, matches, label = unpack(case)
		local original = target[key]
		invalidates(matches, function() target[key] = replacement end, function() target[key] = original end, label)
	end
	invalidates(answer, function() view.config_open = true end, function() view.config_open = nil end,
		"unchanged entry shifted to another ordinal")
	local removed = assert(control(answer))
	local gates = projection.dispatch.workflow.gates
	projection.dispatch.workflow.gates = {}
	redraw()
	check(control(answer) == nil and view.actions[removed] == nil, "removed gate controls are absent from the current map")
	projection.dispatch.workflow.gates = gates
	redraw()
	check(control(answer) ~= removed and view.actions[removed] == nil, "returning gate controls receive new tokens, not retired identities")
	local before_alias, old_alias = table.clone(view.action_order), view.alias_nonce
	local before_config = assert(control(config))
	view.alias_nonce = "replacement-view-incarnation"
	redraw()
	local new_config = assert(control(config))
	check(new_config ~= before_config and new_config:sub(1, #view.alias_nonce + 1) == view.alias_nonce .. ":",
		"alias change invalidates even a descriptor with no source nonce field")
	for _, token in before_alias do check(view.actions[token] == nil, "a new incarnation keeps no old alias token") end
	view.alias_nonce = old_alias
	redraw()
	check(control(config) ~= before_config and view.actions[before_config] == nil and view.actions[new_config] == nil,
		"alias ABA cannot restore an earlier incarnation's token")
	-- Nested retained-summary links must not share their mutable projection table with a click.
	view.finished_open = true
	projection.dispatch.finished_projects = { { name = "Completed research", result = "Notes retained",
		links = { { kind = "result", label = "Read notes", ref = "/notes/original.md" } } } }
	local function summary_link(entry) return entry.kind == "operator-intent" and entry.request.command == "summary_link" end
	redraw()
	local token, captured = control(summary_link); assert(token)
	projection.dispatch.finished_projects[1].links[1].ref = "/notes/changed.md"
	check(captured.request.link.ref == "/notes/original.md", "projection mutation cannot rewrite a captured result-link decision")
	redraw()
	local changed = assert(control(summary_link))
	check(changed ~= token and view.actions[token] == nil, "changed nested links allocate a new current token")
	projection.dispatch.finished_projects[1].links[1].ref = "/notes/original.md"
	redraw()
	check(control(summary_link) ~= token and view.actions[changed] == nil, "nested link ABA cannot revive an old control")
	-- Host confirmation compares the armed intent by identity, unlike value-only
	-- dispatch payloads. Equal redraws retain that pointer; replacement arms do not.
	view.executor_confirmation = { action_id = "fixture-action", executor = "fixture-executor", revision = projection.revision }
	local function executor_confirmation(entry) return entry.kind == "executor-confirm" end
	redraw()
	local confirmation_token, confirmation_entry = control(executor_confirmation); assert(confirmation_token)
	check(confirmation_entry.intent == view.executor_confirmation,
		"a rendered confirmation keeps the exact host-armed intent identity")
	redraw()
	local same_token, same_entry = control(executor_confirmation)
	check(same_token == confirmation_token and same_entry == confirmation_entry,
		"an equal redraw reuses its captured descriptor without recopying or changing the armed intent")
	view.executor_confirmation = clone(view.executor_confirmation)
	redraw()
	local replacement_token, replacement_entry = control(executor_confirmation)
	check(replacement_token ~= confirmation_token and view.actions[confirmation_token] == nil
		and replacement_entry.intent == view.executor_confirmation and confirmation_entry.intent ~= view.executor_confirmation,
		"a newly armed equal-valued confirmation invalidates the prior pointer-bound token")
	check(f.memory.writes == writes and runtime.json.encode(f.authority.registry) == durable,
		"render-only identity changes never mutate durable authority")
	-- The non-ready early return follows the same current-only lifecycle.
	local inert = { pane = 43, alias_nonce = "inert-incarnation", action_serial = 0 }
	local first = runtime.json.encode(views.render(inert, nil, "missing"))
	local serial = inert.action_serial
	check(runtime.json.encode(views.render(inert, nil, "missing")) == first and inert.action_serial == serial
		and inert.action_previous == nil, "identical first-use redraws keep their controls and release the prior map")
	local initialization
	for token, entry in inert.actions do if entry.kind == "setup-intent" and entry.command == "new_orchestration" then initialization = token end end
	assert(initialization)
	views.render(inert, nil, "invalid")
	check(inert.actions[initialization] == nil and inert.action_previous == nil, "unavailable initialization drops its token without retaining a previous map")
	views.render(inert, nil, "missing")
	check(inert.actions[initialization] == nil and inert.action_serial > serial and inert.action_previous == nil,
		"first-use control removal and return never resurrects the previous token")
end
if section == nil or section == "template_start" then
	local w = window_fixture({ no_worker = true })
	local project = w.f:apply("new_project", { name = "Notes" }); assert(project.ok, project.message)
	assert(w.f:apply("policy", { policy = { templates = runtime.json.array({
		{ id = "draft", title = "Draft notes", prompt = "Draft from {input}.", output = "out/draft.md", next = "", class = "build" },
	}) } }).ok)
	w:click("start-template", { orch_project_id = project.orch_project_id })
	local offered
	for _, item in w:picker().items do if item.template then offered = item; break end end
	assert(offered); w:pick(offered); w:tick()
	check(w:editor().placeholder:find("held work", 1, true) ~= nil, "template input makes passive intake explicit")
	w:answer("Research context"); w:tick()
	local submitted
	for _, event in w.events do if event.command == "template_start" then submitted = event end end
	check(submitted and submitted.orch_project_id == project.orch_project_id and submitted.source_revision ~= nil, "template addition pins the actual saved template revision and selected project")
	for _, event in w.events do check(event.command ~= "project_start" and event.command ~= "queue", "template addition does not secretly authorize dispatch") end
end
-- Eligibility/account identity is projected from actual peer records; internal paging is tested by picker_ui.
if section == nil or section == "role_pickers" then
	local w = window_fixture()
	local row = clone(w.f.authority.registry.dispatch.catalogs[w.f.origin.logical_session_id].records[1])
	local disabled = clone(row); disabled.id = "disabled"; disabled.enabled = false
	local unsupported = clone(row); unsupported.id = "unsupported"; unsupported.eligible = false
	unsupported.unsupported = runtime.json.array({ "report-files-v1 unavailable" })
	local pending = w.f:apply("catalog"); assert(pending.ok)
	assert(w.f:finish(pending.action_id, "catalog", { catalog_version = 2, namespace = "fixture-spawn", host_key = "fixture-host",
		config_revision = 0, revision = 0, setup = { schema = 1, state = "completed", config_revision = 0,
			readiness = { state = "not_run", config_revision = 0, summary = "" } },
		records = runtime.json.array({ row, disabled, unsupported }), next_cursor = { revision = 0, index = 4 } }).ok)
	local index = w:catalog_index()
	check(index.loaded and index.total == 3 and #index.records == 1 and index.next_cursor.index == 4, "internal index retains page boundaries while excluding unusable choices")
	check(index.records[1].id == row.id and index.records[1].revision == row.revision
		and index.records[1].provider == row.provider and index.records[1].account_label == row.account_label,
		"picker identity retains real record revision, provider and configured account label")
	check(index.catalog_version == 2 and index.setup.state == "completed", "readiness receives actual peer setup metadata rather than fabricated completion")
end
-- 8C (CP4 smoke): a landing row never says "owner approved" once a refresh voided the approval.
if section == nil or section == "landing_row" then
	local f = shared.fixture(function() return { now_ms = 1700000000000, mono_ms = 1000, epoch = "landing-row" } end)
	local views = shared.load("views")
	local function row(patch)
		local view, projection = render_view(f, { advanced_open = true })
		local item = { id = "landing-1", revision = 1, status = "blocked", position = 1, work_id = "work-1", worker_id = "worker-1", gate_id = "gate-1", approved = true,
			refresh_required = false, request = { source_ref = "refs/heads/work", source_revision = string.rep("a", 40), target_revision = string.rep("b", 40) } }
		for key, value in patch do item[key] = value end
		projection.dispatch.workflow.landing = { { id = "queue-1", repo_ref = "/repo", target_ref = "refs/heads/main", project_id = "p", items = { item } } }
		local normal = clone(view); normal.advanced_open = false
		local normal_row = false
		for _, text in strings(views.render(normal, projection, "ready"), {}) do normal_row = normal_row or text:sub(1, 13) == "#1 landing-1 " end
		check(not normal_row, "normal conversation UI hides the technical landing queue row")
		for _, text in strings(views.render(view, projection, "ready"), {}) do if text:sub(1, 13) == "#1 landing-1 " then return text end end
		error("landing row missing")
	end
	local held = { code = "refresh_required", message = "The previous grant was released without landing." }
	local smoke = row({ refresh_required = true, hold = held })
	check(smoke:find("owner approved", 1, true) == nil and smoke:find("approval void — awaiting fresh review/request", 1, true) ~= nil,
		"refresh_required with a retained approval shows the approval as void, not owner approved")
	check(row({ refresh_required = true, approved = false, hold = held }):find("approval void — awaiting fresh review/request", 1, true) ~= nil,
		"refresh_required without an approval says a fresh review and request are awaited")
	check(row({ hold = { code = "target_moved", message = "Target moved." } }):find("approval void", 1, true) ~= nil, "target_moved voids the shown approval too")
	check(row({ status = "ready" }):find("owner approved", 1, true) ~= nil, "an approved item without a refresh still says owner approved")
end
-- 8C (item 9): a coordinator proposal ORCH+ refused itself (sent before its checkpoint) reads as
-- ORCH+'s refusal, never as an owner answer.
if section == nil or section == "gate_refusal" then
	local f = shared.fixture(function() return { now_ms = 1700000000000, mono_ms = 1000, epoch = "gate-refusal" } end)
	local id = f:accepted(true)
	local views = shared.load("views")
	local function rendered(answer)
		local view, projection = render_view(f, { advanced_open = true })
		local w = projection.dispatch.workflow.workers[1]
		projection.dispatch.workflow.gates = { { id = "gate-9", revision = 2, worker_id = id, worker_generation = w.worker_generation, work_id = w.work_id, kind = "coordinator_proposal",
			phase = "answered", question = "Dispatch 2A?", options = { { id = "approve", label = "Approve" }, { id = "reject", label = "Reject" } }, answer = answer } }
		local normal = clone(view); normal.advanced_open = false
		local normal_text = table.concat(strings(views.render(normal, projection, "ready"), {}), "\n")
		check(normal_text:find("Refused by ORCH+", 1, true) == nil and normal_text:find("Owner answer:", 1, true) == nil,
			"settled technical gate evidence is disclosed in Advanced, not on the normal conversation surface")
		return table.concat(strings(views.render(view, projection, "ready"), {}), "\n")
	end
	local text = rendered({ choice_id = "reject", answer = "Checkpoint 2 has not started; proposal refused.", source = { kind = "refusal", code = "scope_mismatch" } })
	check(text:find("Refused by ORCH+ (scope_mismatch), not an owner answer: Checkpoint 2 has not started; proposal refused.", 1, true) ~= nil
		and text:find("Owner answer:", 1, true) == nil, "an ORCH+ refusal is shown as ORCH+'s, with its code and reason, never as an owner answer")
	check(rendered({ choice_id = "approve", source = { kind = "owner" } }):find("Owner answer:", 1, true) ~= nil, "an owner answer still reads as the owner's")
end
-- Normal plans are continuous through 100 tasks; larger plans group at logical checkpoints.
if section == nil or section == "plans_view" then
	local f = shared.fixture(); f:catalog(0)
	local path = "/tmp/orch-plan-view-" .. shared.codec.sha256(tostring(os.clock()) .. ":" .. tostring(math.random())):sub(1, 16) .. ".md"
	runtime.fs.write(path, runtime.fs.read(root .. "/tests/fixtures/plan-modern.md", 1048576))
	local imported = f:apply("plan_import", { path = path }); assert(imported.ok, imported.message)
	local views = shared.load("views")
	local view, projection = render_view(f)
	local plan = projection.dispatch.workflow.plans[1]
	views.render(view, projection, "ready")
	for _, entry in view.actions do check(not (entry.kind == "workflow-page" and entry.name == "plan " .. plan.plan_id), "normal plan has no artificial page controls") end
	plan.checkpoints = {}
	for group = 1, 3 do
		local cp = { title = "Logical group " .. tostring(group), n = group, tasks = {}, flags = {} }
		for index = 1, 40 do table.insert(cp.tasks, { id = tostring(group) .. "-" .. tostring(index), title = "Task " .. group .. "/" .. index, state = "queued_plan", flags = {} }) end
		table.insert(plan.checkpoints, cp)
	end
	local large = views.render(view, projection, "ready")
	local groups = 0
	local function visit(node)
		if node.p and node.p.collapsible == true and node.p.collapsed == true then groups += 1 end
		for _, child in node.c or {} do visit(child) end
	end
	visit(large)
	check(groups == 3, "120 tasks use their three actual logical checkpoints, not arbitrary slices")
	runtime.fs.remove(path)
end
-- Tern does not wake an untouched window for a due tern.timer, but a finished child process does.
-- The idle-wake helper keeps one short argv-only wait child in flight only while this window
-- drives a live controller with timed work, and that controller's Health card shows it.
if section == nil or section == "idle_wake" then
	local OK = { status = 0, stdout = "", stderr = "", timed_out = false }
	local function finish(w, outcome) w.processes[#w.processes].callback(outcome or OK, table.clone(w.cx)) end
	local function last_state(w) local event = w.wake_events[#w.wake_events]; return if event then event.state else nil end
	local function waits(w) return #w.processes - (w.idle_process_floor or 0) end
	local w = window_fixture()
	check(#w.processes == 0 and #w.wake_events == 0, "no helper before the window has scheduled a controller")
	w:tick()
	local argv = w.processes[1] and w.processes[1].argv
	check(#w.processes == 1 and argv[1] == "sleep" and argv[2] == "2" and #argv == 2,
		"a live controller polling a worker starts one argv-only 2 s wait child, below the 5 s suspension gap")
	check(last_state(w) == "active", "the driven controller reports active timed work")
	local published = #w.wake_events
	for _ = 1, 3 do w:tick() end
	check(#w.processes == 1 and #w.timers == 1 and #w.wake_events == published, "ticks never stack wait children or timers, nor republish an unchanged state")
	finish(w)
	check(#w.processes == 2 and #w.timers == 1, "a finished wait child starts exactly the next one")
	w.current.id = 8 -- The controller's session is no longer current: this window drives nothing.
	for _ = 1, 3 do w:tick() end
	check(last_state(w) == "idle" and #w.wake_events == published + 1,
		"the controller that left this window is told once that the helper stopped")
	finish(w)
	check(#w.processes == 2, "no wait child follows the in-flight one once no controller has timed work")
	w.current.id = 7
	w:tick()
	check(#w.processes == 3 and last_state(w) == "active", "the helper resumes when the controller is driven again")
	-- Disable scheduled housekeeping before resume: otherwise the previous day's
	-- catch-up sweep is genuine pending work, not an idle controller.
	local bare = window_fixture({ no_worker = true, sweep_enabled = false, idle_baseline = true })
	for _ = 1, 3 do bare:tick() end
	check(waits(bare) == 0 and last_state(bare) == "idle", "a live controller with no worker, effect, backoff or read runs no helper: "
		.. runtime.json.encode({ wake_events = bare.wake_events, diagnostic = bare:diagnostic() }))
	bare.f:accepted(false)
	bare:tick()
	check(waits(bare) == 1 and last_state(bare) == "active", "registering a worker gives the controller timed work and starts the helper")
	local conversation = window_fixture({ no_worker = true, sweep_enabled = false, idle_baseline = true, context = "window", hold_conversation_receipt = "project_finish" })
	local project = conversation.f:project("Wake-only completed notes", false)
	conversation:click("project_finish", { orch_project_id = project })
	conversation:answer("Completed notes; no agent session was needed.")
	for _ = 1, 3 do conversation:tick() end
	local waiting = conversation.processes[#conversation.processes] and conversation.processes[#conversation.processes].argv
	check(next(conversation.f.authority.registry.dispatch.workers) == nil and waits(conversation) == 1
		and waiting[1] == "sleep" and waiting[2] == "2" and #waiting == 2 and last_state(conversation) == "active",
		"a genuine pending conversation receipt with zero workers keeps the existing single sleep helper active")
	local issued = 0
	for _, event in conversation.events do if event.command == "project_finish" then issued += 1 end end
	check(issued == 1, "waiting for a conversation receipt never resubmits its project command")
	conversation:release_conversation_receipt()
	for _ = 1, 3 do conversation:tick() end
	check(last_state(conversation) == "idle", "settling the exact conversation receipt stops timed work when no other job or worker remains: "
		.. runtime.json.encode({ wake_events = conversation.wake_events, diagnostic = conversation:diagnostic() }))
	finish(conversation)
	check(waits(conversation) == 1 and next(conversation.f.authority.registry.dispatch.workers) == nil,
		"settled zero-worker conversation work starts no replacement helper, daemon or agent")
	-- Inbox or board polling alone is timed work (final smoke: a file dropped into an untouched
	-- window with no workers was first seen after 288–560 s).
	local dir = "/tmp/orch-idle-wake-" .. shared.codec.sha256(tostring(os.clock()) .. ":" .. tostring(math.random())):sub(1, 16)
	runtime.fs.mkdir(dir)
	local inbox = window_fixture({ no_worker = true, sweep_enabled = false, idle_baseline = true })
	assert(inbox.f:apply("policy", { policy = { inbox_folder = dir } }).ok)
	inbox:tick()
	check(waits(inbox) == 1 and last_state(inbox) == "active",
		"inbox polling alone starts the helper without a worker")
	assert(inbox.f:apply("policy", { policy = { inbox_folder = "" } }).ok)
	inbox:tick()
	check(waits(inbox) == 1 and last_state(inbox) == "idle", "clearing the inbox folder stops the helper")
	local board = window_fixture({ no_worker = true, sweep_enabled = false, idle_baseline = true })
	assert(board.f:apply("policy", { policy = { board_path = "/tmp/fixture-board.tern" } }).ok)
	board:tick()
	check(waits(board) == 1 and last_state(board) == "active",
		"board polling alone starts the helper without a worker")
	local hosted_inbox = window_fixture({ context = "host", no_worker = true })
	assert(hosted_inbox.f:apply("policy", { policy = { inbox_folder = dir } }).ok)
	for _ = 1, 3 do hosted_inbox:tick() end
	check(#hosted_inbox.processes == 0 and #hosted_inbox.wake_events == 0, "a host VM never runs the helper for inbox polling")
	pcall(runtime.fs.remove, dir)
	local elsewhere = window_fixture()
	elsewhere.current.id = 8
	for _ = 1, 3 do elsewhere:tick() end
	check(#elsewhere.processes == 0 and #elsewhere.wake_events == 0, "a window that drives no controller runs no helper")
	local hosted = window_fixture({ context = "host" })
	for _ = 1, 3 do hosted:tick() end
	check(#hosted.processes == 0 and #hosted.wake_events == 0 and #hosted.timers == 1, "a host VM (native tests) never runs the helper")
	local windows = window_fixture({ os = "windows" })
	windows:tick()
	local pings = windows.processes[1] and windows.processes[1].argv
	check(pings ~= nil and table.concat(pings, " ") == "ping -n 3 127.0.0.1" and #pings == 4, "Windows waits with argv-only loopback pings, never a shell string")
	local refused = window_fixture({ process_error = "tern.process is not available on iOS" })
	for _ = 1, 3 do refused:tick() end
	check(#refused.processes == 0 and last_state(refused) == "unavailable" and #refused.wake_events == 1 and #refused.timers == 1,
		"an unavailable helper is reported once while plain-timer observation continues")
	for _, outcome in { { status = 1, stdout = "", stderr = "", timed_out = false }, OK } do
		local stopped = window_fixture()
		stopped:tick()
		if outcome ~= OK then stopped:tick(); stopped:tick() end -- A failure after a full wait; OK below exits at once.
		finish(stopped, outcome)
		stopped:tick(); stopped:tick()
		check(#stopped.processes == 1 and last_state(stopped) == "unavailable", "a failed or early-exiting wait child stops the helper instead of spinning")
	end
end
return "health/" .. tostring(section or "all") .. ": " .. tostring(checks) .. " checks passed"
