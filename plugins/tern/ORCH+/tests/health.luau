-- Deterministic real reducer/host/window coverage. Run bounded sections in native host callbacks.
local root, section = ...
assert(section == nil or table.find({ "clock", "native", "controls", "timer", "driver_controls", "epoch_window", "epoch_host", "finish", "continuation", "alias_recovery", "held_report", "sweep_schedule", "readable_views", "cp2_controls", "guided_recovery", "guided_recovery_empty", "guided_recovery_host_restart", "stopped_worker_view", "expired_wake", "revoked_authorization", "observe_retention", "uncertain_read", "quota_reader", "bridge_lifecycle", "withdraw_fenced", "config_cards", "work_picker", "inbox_window", "usage_row",
	"template_start", "role_pickers", "landing_row", "plans_view", "idle_wake", "gate_refusal", "finish_refusal" }, section), "unknown health section")
local runtime, environment = tern, getfenv()
-- The fixture runs in this group's environment (as tests/run.luau loads groups), so its tern.json calls are
-- the stepped runner's yield points and a long section spans many native slices.
local fixture_chunk = assert(loadstring(runtime.fs.read(root .. "/tests/dispatch.luau"), "health-fixture"))
setfenv(fixture_chunk, setmetatable({}, { __index = environment }))
local shared = fixture_chunk(root, "fixture")
local clone, state, dispatch = shared.clone, shared.state, shared.dispatch
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
if section == nil or section == "clock" then
	local now, epoch = 1000.125, "health-epoch-one"
	local clock = function() return { now_ms = 1700000000000, mono_ms = now, epoch = epoch } end
	local f = shared.fixture(clock)
	local id = f:accepted(false)
	assert(f:apply("intake", { worker_id = id, bytes = f:report(id, 2, "HEARTBEAT", { state = "idle" }) }).ok)
	check(observed(f, id, "idle").ok, "exact pane observation commits with fractional host monotonic time")
	check(health(f, id).native_state == "idle" and health(f, id).freshness == "fresh", "fresh epoch evidence is derived, not window supplied")
	local writes = f.memory.writes
	assert(f.authority:apply({ kind = "workflow_tick" }).ok)
	local settled = f.memory.writes
	assert(f.authority:apply({ kind = "workflow_tick" }).ok)
	check(f.memory.writes == settled and settled >= writes, "idle host ticks do not burn durable writes or request IDs")
	-- An idle tick decides "nothing due" without cloning or comparing the dispatch tree. The
	-- command history is never read by refresh, so any walk of it is the full-tree clone.
	local tick_now = 1000
	local t = shared.fixture(function() return { now_ms = 1700000000000, mono_ms = tick_now, epoch = "health-epoch-tick" } end)
	local tid = t:accepted(false)
	assert(t:apply("intake", { worker_id = tid, bytes = t:report(tid, 2, "HEARTBEAT", { state = "idle" }) }).ok)
	assert(observed(t, tid, "idle").ok)
	assert(t.authority:apply({ kind = "workflow_tick" }).ok)
	assert(t.authority:apply({ kind = "workflow_tick" }).ok)
	local tick_writes = t.memory.writes
	local walks = 0
	local commands = t.authority.registry.dispatch.commands
	setmetatable(commands, { __iter = function(value) walks += 1; return next, value end })
	local idle = t.authority:apply({ kind = "workflow_tick" })
	setmetatable(commands, nil)
	check(idle.ok and idle.code == "no_progress" and walks == 0 and t.memory.writes == tick_writes, "idle host tick clones and compares no dispatch subtree")
	tick_now += 600000
	local due = t.authority:apply({ kind = "workflow_tick" })
	check(due.ok and due.code == "workflow_updated" and t.memory.writes == tick_writes + 1 and health(t, tid).freshness == "stale",
		"elapsed staleness is still committed by the next tick")
	check(t.authority:apply({ kind = "workflow_tick" }).code == "no_progress" and t.memory.writes == tick_writes + 1, "the committed tick leaves nothing due")
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
	local g = shared.fixture(clock); local other = g:accepted(false)
	assert(g:apply("intake", { worker_id = other, bytes = g:report(other, 2, "HEARTBEAT", { state = "working" }) }).ok)
	assert(observed(g, other, "working").ok)
	now += 180001
	assert(g.authority:apply({ kind = "workflow_tick" }).ok)
	check(health(g, other).freshness == "stale" and health(g, other).status == "stale_report", "required report expiry outranks working")
	epoch = "health-epoch-two"; now = 0.5
	assert(g.authority:apply({ kind = "workflow_tick" }).ok)
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
	local now = 1000
	local f = shared.fixture(function() return { now_ms = 1700000000000, mono_ms = now, epoch = "health-host" } end)
	local id
	local controller_alias = 9001
	local bridge_outcome, bridge_bytes, bridge_missing
	-- SPAWN bridge panes: lease markers (SPAWN_BRIDGE v1) and native create/close/move records. As in
	-- the live window, a pane moved with move_to_tab/move_to_new_tab answers surface reads with nil.
	local leases, bridge_panes, bridge_placements, bridges_closed, moved, tab_names, usage_placements = {}, {}, {}, {}, {}, {}, {}
	local session_tabs = { [7] = { 1 }, [8] = { 2 } }
	local next_bridge, next_lease = nil, nil
	local bridge_events, result_events = {}, {}
	local timers, hooks, events, notices, toasts = {}, {}, {}, {}, {}
	local pick_callback, prompt_callback, picked, picker_spec, prompt_spec
	-- The controller block's published one-shot operator intent (host.luau publishes it on click).
	local intent, intent_serial = nil, 0
	local selected, selected_worker, result, command_result, driver_result
	-- Guided recovery: SPAWN's read-only owner_status answer, published checklist and palette runs.
	local owner_answer, recovery_steps, ran_actions = "current", nil, {}
	-- USAGE capacity export: a fixture server answering the reader's correlated requests.
	local usage = nil
	local board_opened = {}
	local host = { id = "local", state = "connected", panes = { 9001, 9002, 9004 } }
	local panes = { [9001] = { pane = 9001, block = "orchplus.orchestrator", tab = 1 }, [9002] = { pane = 9002, tab = 1 }, [9004] = { pane = 9004, tab = 1 } }
	local agents = { { pane = 9002, state = "idle" }, { pane = 9004, state = "working" } }
	local current = { id = 7, host = "local" }
	local ftern = table.clone(runtime)
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
	ftern.command = function(def) palette[def.id] = def end; ftern.files = { button = function() end }
	ftern.route = { link = function() error("ORCH+ must not claim links; controls are native buttons") end }
	local function find(node, key)
		if node.p and node.p.key == key then return node end
		for _, child in node.c or {} do local match = find(child, key); if match then return match end end
		return nil
	end
	local function tree()
		local projection = state.project(f.authority.registry)
		projection.dispatch = dispatch.project(f.authority.registry, f.origin.logical_session_id, f.origin.alias_nonce, selected)
		return shared.load("views").render({ pane = 42, alias_nonce = f.origin.alias_nonce, orch_session_id = f.origin.logical_session_id,
			action_serial = 0, dispatch_action = selected, dispatch_result = result, dispatch_command_result = command_result,
			dispatch_driver_result = driver_result, workflow_worker = selected_worker, operator_intent = intent, idle_wake = idle_wake }, projection, "ready")
	end
	local cx = { hosts = { current = function() return host end, list = function() return { host } end },
		sessions = { current = function() return current end }, window_key = function() return "" end,
		agents = { list = function() return agents end, ask = function() error("ORCH+ must not ask agents directly") end },
		layout = { focus = function(_, pane) picked = pane end, unpark = function() return true end,
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
			if block == "usage.capacity" then
				if not usage then return nil end
				-- Created in place like a bridge: a new tab of the current session, or the target's tab.
				local pane = if #usage_placements == 0 then 9005 else 9600 + #usage_placements
				table.insert(usage_placements, { pane = pane, how = how, target = if options then options.target else nil, focus = if options then options.focus else nil })
				panes[pane] = { pane = pane, block = "usage.capacity" }
				if how == "tab" then
					local tab = 100 + #session_tabs[current.id]; table.insert(session_tabs[current.id], tab); panes[pane].tab = tab
				else panes[pane].tab = if options and options.target and panes[options.target] then panes[options.target].tab else 1 end
				if not table.find(host.panes, pane) then table.insert(host.panes, pane) end
				return pane
			end
			if not bridge_outcome then return nil end
			table.insert(bridge_placements, { how = how, target = if options then options.target else nil, focus = if options then options.focus else nil })
			local pane = next_bridge or 9003
			if not panes[pane] then panes[pane] = { pane = pane, block = "spawn.dispatch" }; table.insert(host.panes, pane) end
			if next_bridge then leases[pane] = next_lease; next_bridge, next_lease = nil, nil end
			-- Created in place: a new tab of the current session, or the target's tab.
			if how == "tab" then
				local tab = 100 + #session_tabs[current.id]; table.insert(session_tabs[current.id], tab); panes[pane].tab = tab
			else panes[pane].tab = if options and options.target and panes[options.target] then panes[options.target].tab else 1 end
			return pane
		end,
		pick = function(_, spec) picker_spec = clone(spec); return { next = function(_, callback) pick_callback = callback end } end,
		prompt = function(_, spec) prompt_spec = clone(spec); return { next = function(_, callback) prompt_callback = callback end } end,
		actions = { run = function(_, label) table.insert(ran_actions, label); return label end },
		-- Desktop board cx: opens are recorded; reads never answer (no board fixture is polled).
		board = { open = function(_, path) table.insert(board_opened, path) end,
			read = function() return { next = function() end } end, move = function() return { next = function() end } end },
		session = {} }
	function cx.session:pane(pane) return panes[pane] end
	function cx.session:panes() local rows = {}; for _, pane in panes do table.insert(rows, pane) end; return rows end
	function cx.session:sessions() return { { id = 7, tabs = session_tabs[7] }, { id = 8, tabs = session_tabs[8] } } end
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
			return { surface = { role = "plugin.spawn.dispatch" }, main = { k = "text", id = "main.spawn-dispatch-response",
				p = { role = "spawn.dispatch.response", spans = { bridge_bytes or "SPAWN_DISPATCH v1 {}" } } } }
		end
		if pane ~= controller_alias then return nil end
		local node = find(tree(), options.root:sub(6)); if not node then return nil end
		node = clone(node); node.id = options.root
		return { surface = { role = "plugin.orchplus.orchestrator" }, main = node }
	end
	function cx.session:event(pane, event)
		if panes[pane] and panes[pane].block == "usage.capacity" then usage.handle(runtime.json.decode(event.value)); return end
		if panes[pane] and panes[pane].block == "spawn.dispatch" then
			table.insert(bridge_panes, pane)
			local input = runtime.json.decode(event.value)
			table.insert(bridge_events, input)
			if input.op == "owner_status" then bridge_bytes = shared.frame(input, "owner_status", { owner = owner_answer }); return end
			-- A withdrawal's exact unused-mailbox retirement (never the original effect): SPAWN confirms it.
			if input.op == "mailbox_retire" and input.mode == "retire" then bridge_bytes = shared.frame(input, "retired", {}); return end
			assert(input.op == "status", "replacement window must never resubmit the original effect")
			bridge_bytes = if bridge_missing then shared.frame(input, "missing") else shared.frame(input, "found", { outcome = bridge_outcome })
			return
		end
		assert(pane == controller_alias)
		if event.act:sub(1, 16) == "dispatch-result/" then table.insert(result_events, clone(event)); return end
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
		if event.act == "dispatch-notice" then return end
		if event.act == "recovery-steps" then recovery_steps = runtime.json.decode(event.value); return end
		local input = runtime.json.decode(event.value)
		table.insert(events, input)
		if event.act == "dispatch-select" then selected = input.action_id; return end
		local response = f.authority:apply(input)
		response.request_id = input.request_id; response.command = input.command
		response.action_id = response.action_id or input.action_id
		local workflow_only = table.find({ "observe", "pause", "resume", "policy", "answer", "cancel_gate", "recheck_gate", "continue_controller", "sweep" }, input.command) ~= nil
		if event.act == "dispatch-operator-command" then
			command_result = response
			if not workflow_only then driver_result = response end
		end
		if not workflow_only then result = response end
		if response.ok and response.action_id then selected = response.action_id end
	end
	local module = assert(loadstring(runtime.fs.read(root .. "/window.luau"), "health-window"))
	-- Injected local wall clock: the nightly sweep schedule reads os.time/os.date; tables still convert.
	local wall = 1700000000
	local fixed_os = table.clone(os); fixed_os.time = function(spec: any?) if spec ~= nil then return os.time(spec) end return wall end
	setfenv(module, setmetatable({ tern = ftern, require = shared.load, os = fixed_os }, { __index = environment }))
	local api = module()
	local w = { f = f, id = id, cx = cx, api = api, timers = timers, hooks = hooks, events = events, agents = agents, panes = panes, current = current, notices = notices, board_opened = board_opened,
		processes = processes, wake_events = wake_events, toasts = toasts }
	function w:rendered() return runtime.json.encode(tree()) end
	-- The owner clicks a dispatch button: its host block publishes the exact request as a one-shot
	-- intent, which the window's observation consumer runs at most once.
	function w:click(command, fields)
		local request = { command = command, source_nonce = f.origin.alias_nonce, orch_session_id = f.origin.logical_session_id }
		for key, value in fields or {} do request[key] = value end
		intent_serial += 1
		intent = { version = 1, source_nonce = f.origin.alias_nonce, serial = "fixture-intent-" .. tostring(intent_serial), kind = "dispatch", request = request }
		api.intents(table.clone(cx))
	end
	-- The owner runs an ORCH+ palette command in this window (the latest loaded VM's registration).
	function w:palette(id) assert(palette[id], id).run(table.clone(cx)) end
	function w:tick() now += 500; local token = assert(table.remove(timers, 1)); assert(not token.cancelled); token.callback(table.clone(cx)) end
	function w:elapse(ms) now += ms; assert(f.authority:apply({ kind = "workflow_tick" }).ok) end
	function w:set_wall(t) wall = t end
	function w:pick(choice) assert(pick_callback)(choice, nil, table.clone(cx)) end
	function w:picker() return picker_spec end
	function w:editor() return prompt_spec end
	function w:answer(value) assert(prompt_callback)(value, nil, table.clone(cx)) end
	function w:focused() return picked end
	function w:outcome() return command_result end
	function w:worker() for _, worker in flow(f).workers do if worker.worker_id == id then return worker end end end
	function w:select_worker(worker_id) selected_worker = worker_id end
	function w:move_controller(alias)
		local pane = panes[controller_alias]; panes[controller_alias] = nil
		for index, value in host.panes do if value == controller_alias then host.panes[index] = alias end end
		controller_alias = alias; pane.pane = alias; panes[alias] = pane
	end
	function w:bridge(outcome)
		bridge_outcome = clone(outcome)
		panes[9003] = { pane = 9003, block = "spawn.dispatch", tab = 1 }
		table.insert(host.panes, 9003)
	end
	function w:add_bridge(pane, lease, tab)
		tab = tab or 1
		if not table.find(session_tabs[7], tab) then table.insert(session_tabs[7], tab) end
		panes[pane] = { pane = pane, block = "spawn.dispatch", tab = tab }
		table.insert(host.panes, pane); leases[pane] = lease
	end
	function w:lease(pane, lease) leases[pane] = lease end
	function w:moved_earlier(pane) moved[pane] = true end -- An earlier build moved it: unreadable now.
	function w:next_bridge(pane, lease) next_bridge, next_lease = pane, lease end
	function w:bridge_panes() return bridge_panes end
	function w:bridge_placements() return bridge_placements end
	function w:bridges_closed() return bridges_closed end
	function w:tab_names() return tab_names end
	function w:moves() local n = 0; for _ in moved do n += 1 end; return n end
	-- SPAWN's registry has no record of the status target (never staged, or compacted).
	function w:bridge_missing(flag) bridge_missing = flag end
	function w:bridge_events() return bridge_events end
	function w:result_events() return result_events end
	function w:owner_answer(state) owner_answer = state end
	function w:recovery_steps() return recovery_steps end
	function w:ran_actions() return ran_actions end
	function w:usage(server) usage = server end
	function w:usage_placements() return usage_placements end
	-- A `usage.capacity` pane an earlier incarnation left (tab 1 = beside the controller).
	function w:add_usage(pane, tab) panes[pane] = { pane = pane, block = "usage.capacity", tab = tab }; table.insert(host.panes, pane) end
	function w:reload()
		table.clear(timers) -- A real VM reload drops its callbacks before loading the new entry.
		api = module(); self.api = api
	end
	w:click("pause")
	assert(#events == 1 and events[1].command == "pause", "fixture must obtain its origin from the real window command")
	f.origin = clone(events[1].origin)
	w:click("resume")
	table.clear(events)
	if not (options and options.no_worker) then id = f:accepted(false); w.id = id end
	return w
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
		assert(f.authority:apply({ kind = "workflow_tick" }).ok)
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
if section == nil or section == "controls" then
	local w = window_fixture()
	w:click("pause")
	check(flow(w.f).policy.paused, "actual pause button invokes concrete admitted reducer command")
	w:click("resume")
	check(not flow(w.f).policy.paused, "actual resume button preserves session policy")
	local function edit(field) w:click("policy", { field = field, expected_sha256 = shared.quota.digest(flow(w.f).policy) }) end
	edit("poll_ms")
	w:answer("2000")
	check(flow(w.f).policy.poll_ms == 2000, "policy prompt saves bounded concrete policy")
	local editor = assert(w:editor())
	check(editor.value == "5000", "Config editor starts with the saved value rather than a second settings store")
	local policy_before = runtime.json.encode(flow(w.f).policy)
	edit("poll_ms"); w:answer(nil)
	check(runtime.json.encode(flow(w.f).policy) == policy_before, "cancelled Config prompt changes no saved setting")
	for _, bad in { "0", "100", "80.5", "-1", "eighty", "" } do
		edit("rollover_threshold_pct"); w:answer(bad)
		check(runtime.json.encode(flow(w.f).policy) == policy_before, "threshold entry " .. bad .. " is refused with nothing changed")
	end
	edit("rollover_threshold_pct"); w:answer(" 95 ")
	check(flow(w.f).policy.rollover_threshold_pct == 95, "whole-number threshold entry saves through the policy command")
	local displayed = flow(w.f).policy
	w:click("policy", { policy = { auto_rollover = true, quota_routing = true }, expected_sha256 = shared.quota.digest(displayed) })
	check(flow(w.f).policy.auto_rollover and flow(w.f).policy.quota_routing and flow(w.f).policy.poll_ms == 2000, "Config draft save commits only its changed settings")
	w:click("policy", { policy = { auto_rollover = false }, expected_sha256 = shared.quota.digest(displayed) })
	check(flow(w.f).policy.auto_rollover, "draft displayed before a newer save cannot overwrite it")
	edit("poll_ms")
	w:click("pause")
	w:answer("9000")
	check(flow(w.f).policy.poll_ms == 2000 and flow(w.f).policy.paused, "stale editor cannot overwrite an intervening policy control")
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
	w:click("policy", { field = "poll_ms", expected_sha256 = shared.quota.digest(flow(w.f).policy) }); w:answer(nil)
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
end
if section == nil or section == "driver_controls" then
	for _, command in { "poll", "catalog" } do
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
	check(publication == nil or publication.phase == "complete", "confirmed publication releases its execution slot while retaining a separate not-started wake obligation")
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
	local timers, callbacks = {}, {}
	local fake = table.clone(runtime)
	fake.timer = function(_, callback) table.insert(timers, callback); return {} end
	fake.on = function() end; fake.pane = { list = function() return {} end }
	fake.kv = { get = function() return nil end, set = function() error("timer must not initialize storage") end }
	fake.block = { define = function(_, definition) callbacks.definition = definition end }
	local chunk = assert(loadstring(runtime.fs.read(root .. "/host.luau"), "health-host-timer"))
	setfenv(chunk, setmetatable({ tern = fake, require = shared.load }, { __index = environment })); chunk()
	check(#timers == 1, "host module initializes timer without any block or window")
	callbacks.definition.init({ pane = 42, render = function() end }, {}, nil)
	check(#timers == 1, "host block init does not duplicate timer")
	table.remove(timers, 1)()
	check(#timers == 1, "host rearmed after missing store and vanished block without inventing authority")
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
	assert(w.f:finish(read.action_id, "complete", runtime.json.decode(page)).ok)
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
	assert(w.f:finish(read.action_id, "complete", runtime.json.decode(page)).ok)
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
	w:click("policy", { field = "poll_ms", expected_sha256 = shared.quota.digest(flow(w.f).policy) }) -- Keep its old callback to prove a delayed old-VM editor cannot save.
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
	w:answer("2000")
	check(flow(w.f).policy.poll_ms == 5000, "delayed old Config callback cannot overwrite policy after continuation")
	w:click("continue_worker", { worker_id = w.id })
	w:pick({ pane = 9002 }); w:pick({ attach = false })
	check(w:worker().origin_binding.window_epoch == old_origin.window_epoch, "candidate selection plus cancellation never adopts a worker")
	w:click("continue_worker", { worker_id = w.id })
	w:pick({ pane = 9002 })
	local attachment_revision = w.f.authority.registry.revision
	assert(observed(w.f, unrelated, "working").ok)
	check(w.f.authority.registry.revision > attachment_revision, "unrelated worker observation advances the global registry during attachment confirmation")
	w:pick({ attach = true })
	assert(w:outcome().ok)
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
	w:bridge({ schema = 1, op = action.request.op, request_id = action.request.request_id, action_id = action.request.action_id,
		origin_binding = action.request.origin_binding, controller_generation = action.request.controller_generation,
		status = "catalog", payload = { namespace = "fixture-spawn", host_key = "fixture-host", config_revision = 0, revision = 0, records = runtime.json.array() } })
	w:click("reconcile", { action_id = action.request.action_id })
	w:tick(); w:tick()
	local query = assert(w:bridge_events()[1])
	check(query.op == "status" and query.controller_pane == "9010" and query.origin_binding.window_epoch == action.request.origin_binding.window_epoch,
		"replacement window inspects immutable original outcome through the new window-local controller alias")
	local delivered = assert(w:result_events()[1])
	check(delivered.act == "dispatch-result/" .. action.claim.grant_id .. "/" .. w.f.origin.window_epoch,
		"changed-alias result callback retains original grant and carries the continued execution epoch")
	local original = assert(dispatch.decode_response(delivered.value, action.request))
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
	local w = window_fixture()
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
end
if section == nil or section == "readable_views" then
	local f = shared.fixture(function() return { now_ms = 1700000000000, mono_ms = 1000, epoch = "views-host" } end)
	local id = f:accepted(false)
	local queued = f:queue(false); assert(queued.ok)
	local views = shared.load("views")
	local function render(config, worker_id)
		local projection = state.project(f.authority.registry)
		projection.dispatch = dispatch.project(f.authority.registry, f.origin.logical_session_id, f.origin.alias_nonce)
		return views.render({ pane = 42, alias_nonce = f.origin.alias_nonce, orch_session_id = f.origin.logical_session_id, action_serial = 0,
			workflow_worker = worker_id, config_open = config }, projection, "ready")
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
	for _, case in { { false, id, "controller health for a fresh worker" }, { false, queued.worker_id, "controller view of unprovisioned work" }, { true, id, "Config" } } do
		local all = table.concat(texts(render(case[1], case[2]), {}), "\n")
		check(all ~= "" and all:find("%f[%a]null%f[%A]") == nil and all:find("%f[%a]nil%f[%A]") == nil, case[3] .. " never renders raw null/nil")
		if case[1] then check(all:find("Last sweep: none yet.", 1, true) ~= nil, "Config shows a readable empty sweep history") end
	end
end
-- CP2 live smoke: host-consumed gates are answered by the chosen option alone; the worker gate list
-- shows open questions first in numeric order; continuation is offered only where it is needed.
if section == nil or section == "cp2_controls" then
	for _, kind in { "quota_fallback", "loop_cap", "stale_claim", "shared_checkout", "file_overlap", "scope", "reviewer_unavailable", "family_unknown", "legacy_grant_outstanding" } do
		check(dispatch.HOST_GATES[kind] == true, kind .. " is a host-consumed gate kind the window answers by choice alone")
	end
	local w = window_fixture()
	assert(w.f:apply("policy", { policy = { checkout_roots = runtime.json.array({ "/fixture" }) } }).ok)
	local gated = w.f:queue(false)
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
		return table.concat(texts(views.render({ pane = 42, alias_nonce = f.origin.alias_nonce, orch_session_id = f.origin.logical_session_id, action_serial = 0,
			workflow_worker = worker_id }, projection, "ready"), {}), "\n")
	end
	-- Gate order: gate-7/8 settled, gate-9/10 pending. Open first, numeric order (not "gate-10" < "gate-7").
	local owner = w:worker()
	local all = render(w.f, w.id, function(workflow)
		for index = #workflow.gates, 1, -1 do if workflow.gates[index].worker_id == w.id then table.remove(workflow.gates, index) end end
		for _, row in { { 7, "resolved" }, { 8, "superseded" }, { 9, "pending" }, { 10, "pending" } } do
			table.insert(workflow.gates, { id = "gate-" .. row[1], revision = 1, worker_id = w.id, worker_generation = owner.worker_generation, work_id = owner.work_id,
				kind = "shared_checkout", phase = row[2], question = "Fixture question " .. row[1], options = { { id = "acknowledge", label = "Understood" } }, evidence = {} })
		end
		table.sort(workflow.gates, function(a, b) return a.id < b.id end)
	end)
	local nine, ten = all:find("gate-9 / revision 1", 1, true), all:find("gate-10 / revision 1", 1, true)
	check(nine ~= nil and ten ~= nil and nine < ten and all:find("gate-7 / revision", 1, true) == nil and all:find("gate-8 / revision", 1, true) == nil,
		"the first gate page shows the pending gates, oldest first by number, before settled ones")
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
	r:bridge({ schema = 1, op = "catalog", request_id = held.request.request_id, action_id = cat.action_id, origin_binding = held.request.origin_binding,
		controller_generation = held.request.controller_generation, status = "pending", payload = {} })
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
	local function card(patch)
		local w = f.authority.registry.dispatch.workers[id]
		w.usage_before, w.usage_after = patch.before, patch.after
		local projection = state.project(f.authority.registry)
		projection.dispatch = dispatch.project(f.authority.registry, f.origin.logical_session_id, f.origin.alias_nonce)
		if patch.shared ~= nil then for _, pw in projection.dispatch.workflow.workers do if pw.worker_id == id then pw.usage_shared_with = patch.shared end end end
		local out = {}
		local function walk(node)
			if type(node) ~= "table" then return end
			for key, value in node do
				if type(value) == "string" and (key == "t" or key == "text" or type(key) == "number") then table.insert(out, value) elseif key ~= "actions" then walk(value) end
			end
		end
		walk(views.render({ pane = 42, alias_nonce = f.origin.alias_nonce, orch_session_id = f.origin.logical_session_id, action_serial = 0, workflow_worker = id, config_open = false },
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
	local w = window_fixture()
	local id = w.id
	w:bridge({ placeholder = true }) -- A SPAWN bridge pane answers read-only probes.
	w:owner_answer("previous_incarnation")
	w:reload()
	local function labels() local out = {}; for _, item in w:picker().items do table.insert(out, item.label) end; return out end
	local function probes() local n = 0; for _, e in w:bridge_events() do if e.op == "owner_status" then n += 1 end end; return n end
	local before = #w.events
	w:palette("recovery_guide"); w:tick(); w:tick()
	local items = labels()
	check(items[1] == "Next: Continue controller after reload" and items[2] == "Then: Recover the previous SPAWN owner (previous_incarnation)" and #items == 3,
		"before continuation the guide lists continuation, then SPAWN owner recovery, in order")
	check(#w.events == before and probes() == 1, "opening the guide is one read-only owner_status probe; no host command or attestation")
	w:pick({ kind = "continue" })
	check(w:picker().placeholder:find("Continue controller", 1, true) ~= nil and #w.events == before,
		"the continuation step opens the existing attested picker; nothing is sent until the owner attests")
	w:pick({ continue_controller = true }); assert(w:outcome().ok)
	w:tick(); w:tick()
	local worker = w.f.authority.registry.dispatch.workers[id]
	local reattach = "Reattach " .. worker.work_id .. " / " .. id .. " (recorded pane 9002)"
	items = labels()
	check(items[1] == "Next: Recover the previous SPAWN owner (previous_incarnation)" and items[2] == "Then: " .. reattach and #items == 3,
		"after continuation the guide reopens with SPAWN owner recovery, then each worker's reattachment and recorded pane")
	local published = assert(w:recovery_steps())
	check(#published.steps == 2 and published.steps[2].label == reattach, "the controller view receives the same ordered checklist")
	local sent = #w.events
	w:pick({ kind = "spawn" })
	check(w:ran_actions()[1] == "SPAWN: Running agents" and #w.events == sent, "the SPAWN step only opens SPAWN's own recovery page; ORCH+ sends and attests nothing")
	w:owner_answer("none") -- The owner fenced, verified and confirmed in SPAWN Config.
	w:palette("recovery_guide"); w:tick(); w:tick()
	items = labels()
	check(items[1] == "Next: " .. reattach and #items == 2 and probes() == 3, "after SPAWN recovery only the reattachment remains, read again from SPAWN")
	w:pick({ kind = "reattach", worker_id = id })
	check(w:picker().placeholder == "Select the exact existing worker for " .. worker.work_id .. " / " .. id,
		"the reattachment step opens the existing exact pane picker")
	local attached = 0
	for _, e in w.events do if e.command == "continue_worker" then attached += 1 end end
	check(attached == 0, "no attachment is submitted without the owner's explicit pane selection and attestation")
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
	assert(w.f:finish(read.action_id, "complete", runtime.json.decode(page)).ok)
	local stop = w.f:apply("poll", { worker_id = w.id })
	local request = w.f:action(stop.action_id).request
	assert(request.op == "stop", request.op)
	assert(w.f:finish(stop.action_id, "stopped", { pane_binding = request.pane_binding, observation = observation }).ok)
end
-- Nothing to recover: the guide still opens a picker that says so, with an info (not error) toast.
if section == nil or section == "guided_recovery_empty" then
	local w = window_fixture()
	w:bridge({ placeholder = true }) -- A SPAWN bridge pane answers read-only probes.
	w:owner_answer("current")
	stop_worker(w, "absent") -- A stopped worker never needs reattachment.
	local seen, toasts_before = w:picker(), #w.toasts
	w:palette("recovery_guide")
	for _ = 1, 6 do if w:picker() ~= seen then break end; w:tick() end
	local picker = w:picker()
	check(picker ~= seen and picker.items[1].label:find("No reload recovery step remains", 1, true) == 1 and picker.items[1].kind == nil and picker.items[2].kind == nil,
		"an empty guide opens a picker that says no reload recovery step remains; no item acts")
	check(#w:recovery_steps().steps == 0, "the controller checklist is published empty")
	local errors, infos = 0, 0
	for index = toasts_before + 1, #w.toasts do
		local toast = w.toasts[index]
		if toast.level == "error" then errors += 1 elseif toast.level == "info" then infos += 1 end
	end
	check(errors == 0 and infos == 1, "an empty guide is one info toast, never an error")
end
-- Host-only restart (e.g. `tern remote serve` daemon): the window VM and its origin are unchanged,
-- but the host restores the controller as uncertain, so the guide must still list continuation.
if section == nil or section == "guided_recovery_host_restart" then
	local w = window_fixture()
	local id = w.id
	w:bridge({ placeholder = true }) -- SPAWN answers owner_status with "current".
	w.f.authority = shared.host.new_authority(w.f.memory, function() return { now_ms = 1700000000000, mono_ms = 5000, epoch = "health-host-restarted" } end)
	assert(w.f.authority:load().ok)
	check(w.f.authority.registry.sessions[w.f.origin.logical_session_id].controller.phase == "uncertain", "host restart restores the controller as uncertain")
	local function open()
		local seen = w:picker()
		w:palette("recovery_guide")
		for _ = 1, 6 do if w:picker() ~= seen then break end; w:tick() end
		local out = {}; for _, item in w:picker().items do table.insert(out, item.label) end; return out
	end
	local worker = w.f.authority.registry.dispatch.workers[id]
	local reattach = "Reattach " .. worker.work_id .. " / " .. id .. " (recorded pane 9002)"
	local items = open()
	check(items[1] == "Next: Continue controller after reload" and items[2] == "Then: " .. reattach and #items == 3,
		"with an unchanged window incarnation the guide still lists controller continuation first, then the host-projected reattachment")
	check(w:recovery_steps().steps[1].label == "Continue controller after reload", "the checklist shows the continuation step")
	w:pick({ kind = "continue" })
	w:pick({ continue_controller = true }); assert(w:outcome().ok)
	check(w.f.authority.registry.sessions[w.f.origin.logical_session_id].controller.phase == "active", "explicit continuation makes the controller active")
	items = open()
	check(items[1] == "Next: " .. reattach and #items == 2, "after continuation the step disappears; only the worker reattachment remains")
	check(#w:recovery_steps().steps == 1 and w:recovery_steps().steps[1].label == reattach, "the checklist drops the continuation step")
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
	local function render(f)
		local projection = state.project(f.authority.registry)
		projection.dispatch = dispatch.project(f.authority.registry, f.origin.logical_session_id, f.origin.alias_nonce)
		return texts(views.render({ pane = 42, alias_nonce = f.origin.alias_nonce, orch_session_id = f.origin.logical_session_id, action_serial = 0 }, projection, "ready"), {})
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
	local request, request_bytes = f:action(wake_id).request, f:action(wake_id).request_bytes
	assert(request.op == "native_wake", "fixture must queue the retained native wake")
	assert(f:apply("claim", { action_id = wake_id, executor = f.origin.window_epoch }).ok)
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
	check(retried.ok and f:action(wake_id).phase == "ready" and f:action(wake_id).claim == nil and f:action(wake_id).request_bytes == request_bytes,
		"the backpressured wake is rechecked as the same immutable request")
	check(f:apply("claim", { action_id = wake_id, executor = f.origin.window_epoch }).ok and f:action(wake_id).claim.grant_id ~= grant.grant_id,
		"the recheck requires a fresh exact grant")
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
	check(revoked.ok and revoked.code == "authorization_reissue" and worker(f, id).phase == "accepted" and f:action(wake_id).phase == "complete",
		"a revoked never-consumed native wake authorization completes its action without holding the worker")
	local obligation = (worker(f, id).wakes or {})[target_id]
	check(obligation ~= nil and obligation.action_id == nil, "the wake obligation is retained and released for re-issue")
	local fresh = f:apply("poll", { worker_id = id }); assert(fresh.ok, fresh.message)
	local reissued = f:action(fresh.action_id).request
	check(fresh.action_id ~= wake_id and reissued.op == "native_wake" and reissued.target_action_id == target_id
		and worker(f, id).wakes[target_id].action_id == fresh.action_id, "a later poll grants a fresh native wake for the same obligation")
	check(state.rehydrate(clone(f.authority.registry)) ~= nil, "the re-issued wake obligation restores")
	-- Durable state written before this fix: held by the revocation, its wake marker still occupied.
	local lf, lid, lwake, ltarget = wake_fixture()
	assert(reject(lf, lwake, { code = "authorization_revoked", message = REVOKED }).ok)
	local stored = worker(lf, lid); stored.phase = "held"; stored.reason = { code = "authorization_revoked", message = REVOKED }; stored.wakes[ltarget].action_id = lwake
	lf.memory.value = clone(lf.authority.registry)
	local legacy = lf:apply("poll", { worker_id = lid }); assert(legacy.ok, legacy.message)
	check(worker(lf, lid).phase == "accepted" and worker(lf, lid).reason == nil and lf:action(legacy.action_id).request.op == "native_wake"
		and legacy.action_id ~= lwake, "a worker held only by a pre-fix revocation resumes and re-issues its wake on the continued route")
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
	local id = f:accepted(false)
	local binding = clone(f.authority.registry.dispatch.workers[id].pane_binding)
	local seq = 0
	local function observation(native)
		seq += 1
		return f:event("observe", { worker_id = id, pane_binding = clone(binding), native_state = native, observation_seq = seq })
	end
	local function commands() local n = 0; for _ in f.authority.registry.dispatch.commands do n += 1 end; return n end
	local first = observation("idle")
	check(f.authority:apply(first).ok and f.authority.registry.dispatch.commands[first.request_id] == nil and health(f, id).native_state == "idle",
		"a sequenced observation commits its evidence without retaining a command outcome")
	local retained, revision, writes = commands(), f.authority.registry.revision, f.memory.writes
	now += 5000
	local unchanged = observation("idle")
	local answer = f.authority:apply(unchanged)
	check(answer.ok and answer.code == "observation_recorded" and commands() == retained and f.authority.registry.revision == revision
		and f.memory.writes == writes, "an unchanged observation grows no command history, bumps no revision and writes nothing")
	now += 1000
	local changed = observation("working")
	check(f.authority:apply(changed).ok and f.authority.registry.revision == revision + 1 and health(f, id).native_state == "working"
		and commands() == retained, "a changed observation still commits its new evidence")
	revision = f.authority.registry.revision
	now += 180000 / 4 + 1000 -- Past the default stale_ms/4 refresh bound.
	check(f.authority:apply(observation("working")).ok and f.authority.registry.revision == revision + 1,
		"unchanged evidence is still re-stamped before it could go stale")
	revision = f.authority.registry.revision
	local before = runtime.json.encode(f.authority.registry)
	check(f.authority:apply(clone(first)).code == "stale_observation" and runtime.json.encode(f.authority.registry) == before
		and health(f, id).native_state == "working", "replaying an older observation cannot regress newer evidence")
	check(f.authority:apply(clone(unchanged)).code == "stale_observation" and runtime.json.encode(f.authority.registry) == before,
		"replaying an older unchanged observation is refused too")
	-- A store written before outcomes stopped being retained still holds observe outcomes.
	local legacy = clone(f.authority.registry)
	legacy.dispatch.commands[first.request_id] = { event = clone(first), result = { ok = true, code = "observation_recorded", message = "observation_recorded" }, revision = revision }
	local restored = state.rehydrate(clone(legacy))
	check(restored ~= nil and restored.dispatch.commands[first.request_id] == nil, "restore prunes retained observation outcomes once")
	local clock = { now_ms = 1700000000000, mono_ms = now + 1000, epoch = "retention-host" }
	local next_change = observation("idle")
	local pruned = state.apply(clone(legacy), next_change, clock)
	check(pruned ~= nil and pruned.dispatch.commands[first.request_id] == nil, "the next committed command prunes retained observation outcomes")
	local replayed, refusal = state.apply(pruned, clone(first), clock)
	check(replayed == nil and refusal.code == "stale_observation" and pruned.dispatch.workers[id].workflow.native.state == "idle",
		"a pruned old observation replay is refused and cannot rewrite current evidence")
	local again, response = state.apply(pruned, clone(next_change), clock)
	check(again == pruned and response.code == "observation_recorded", "the latest observation replay stays idempotent after pruning")
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
	local function status_query(request, controller_pane)
		return { schema = 1, origin = "orchplus", op = "status", request_id = "status-probe", action_id = "status-probe-action",
			origin_binding = clone(request.origin_binding), controller_pane = controller_pane, controller_generation = request.controller_generation,
			target_request_id = request.request_id }
	end
	-- Plugin reload (host and window) with a report read claimed by the previous incarnation.
	local w = window_fixture()
	local f, id = w.f, w.id
	local read = f:apply("poll", { worker_id = id }); assert(read.ok, read.message)
	local request = clone(f:action(read.action_id).request); assert(request.op == "mailbox_read", request.op)
	assert(f:apply("claim", { action_id = read.action_id, executor = f.origin.window_epoch }).ok)
	local claim = clone(f:action(read.action_id).claim)
	f.authority = shared.host.new_authority(f.memory, function() return { now_ms = 1700000000000, mono_ms = 5000, epoch = "uncertain-read-host" } end)
	assert(f.authority:load().ok)
	w:reload()
	w:bridge({ placeholder = true }); w:bridge_missing(true)
	w:palette("continue_controller"); w:pick({ continue_controller = true }); assert(w:outcome().ok)
	f.origin = clone(w.events[#w.events].origin)
	local executors = controller(f).pending_executors
	check(f:action(read.action_id).phase == "uncertain" and executors >= 1 and worker(f, id).continuation_required,
		"reload retains the previous incarnation's claimed read as uncertain executor occupancy")
	local query = status_query(request, f.controller_pane or "9001")
	check(f:apply("read_missing", { action_id = read.action_id, executor = claim.executor, grant_id = claim.grant_id, query_bytes = runtime.json.encode(query),
		response_bytes = shared.frame(query, "found", { outcome = { status = "pending" } }) }).code == "status_not_missing" and f:action(read.action_id).phase == "uncertain",
		"only SPAWN's missing status resolves a retained read")
	for _ = 1, 16 do
		local current = f:action(read.action_id)
		if not current or current.phase ~= "uncertain" then break end
		w:tick()
	end
	local statuses = 0
	for _, e in w:bridge_events() do if e.op == "status" then statuses += 1; assert(e.target_request_id == request.request_id) end end
	local resolved = f:action(read.action_id)
	check(resolved ~= nil and resolved.phase == "resolved" and resolved.resolution.evidence == "read_lost_no_effect" and #resolved.resolution.status_sha256 == 64 and statuses == 1,
		"one automatic status read reporting missing resolves the previous incarnation's read without resubmitting it")
	check(controller(f).pending_executors == executors - 1 and worker(f, id).read_selector == nil and worker(f, id).assembly == nil,
		"the resolved read releases its executor count and its read selector/reassembly state")
	check(state.rehydrate(clone(f.authority.registry)) ~= nil, "missing-status read evidence restores")
	local forged = clone(f.authority.registry); forged.dispatch.actions[read.action_id].resolution.status_sha256 = nil
	check(state.rehydrate(forged) == nil, "missing-status read evidence without its exact status digest is quarantined")
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
		assert(f:finish(queued.action_id, "complete", runtime.json.decode(assert(shared.codec.project_page(object, next_read.selector)))).ok)
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
	local cread = clone(c:action(cread_id).request)
	assert(c:apply("claim", { action_id = cread_id, executor = c.origin.window_epoch }).ok)
	local cclaim = clone(c:action(cread_id).claim)
	continued_reload(c)
	local function coordinator_owner() return c.authority.registry.sessions[c.origin.logical_session_id].orchestrator end
	check(c:apply("result", { action_id = cread_id, executor = cclaim.executor, grant_id = cclaim.grant_id,
		response_bytes = shared.frame(cread, "uncertain", nil, { code = "target_unavailable", message = "Outcome uncertain" }) }).code == "effect_uncertain"
		and c:action(cread_id).phase == "uncertain" and coordinator_owner().phase == "uncertain", "SPAWN's ambiguous outcome keeps the coordinator's read uncertain")
	local cattached = attach(c, cid, "9011")
	check(cattached.ok, "explicit coordinator reattachment is not refused by its uncertain read: " .. tostring(cattached.message))
	local resolution = c:action(cread_id).resolution
	check(c:action(cread_id).phase == "resolved" and resolution.evidence == "read_superseded" and resolution.status_sha256 == nil
		and resolution.executor == cclaim.executor, "the attached route supersedes the ambiguous read")
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
	local mrequest = clone(m:action(pub.action_id).request); assert(mrequest.op == "mailbox_publish_reply", mrequest.op)
	assert(m:apply("claim", { action_id = pub.action_id, executor = m.origin.window_epoch }).ok)
	local mclaim = clone(m:action(pub.action_id).claim)
	continued_reload(m)
	check(attach(m, mid, "9011").code == "settlement_pending" and m:action(pub.action_id).phase == "uncertain" and worker(m, mid).continuation_required,
		"an uncertain mailbox_publish_reply still blocks attachment")
	local mquery = status_query(mrequest, "9010")
	check(m:apply("read_missing", { action_id = pub.action_id, executor = mclaim.executor, grant_id = mclaim.grant_id, query_bytes = runtime.json.encode(mquery),
		response_bytes = shared.frame(mquery, "missing") }).code == "stale_claim" and m:action(pub.action_id).phase == "uncertain",
		"SPAWN's missing status never resolves a mutating effect")
	local mforged = clone(m.authority.registry); local fa = mforged.dispatch.actions[pub.action_id]
	fa.phase = "resolved"; fa.resolution = { revision = mforged.revision, executor = mclaim.executor, evidence = "publication_readback", reason = "control" }
	check(state.rehydrate(clone(mforged)) ~= nil, "control: the same resolved publication restores with its own readback evidence")
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
		server.text = quota.PREFIX .. runtime.json.encode(r)
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
	local placed = w:usage_placements()
	check(#placed == 1 and placed[1].how == "tab" and placed[1].target == nil and placed[1].focus == false
		and w.panes[placed[1].pane].tab ~= 1 and w:tab_names()[w.panes[placed[1].pane].tab] == "SPAWN bridges",
		"the USAGE capacity reader opens in the background SPAWN bridges tab, never beside the controller")
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
	-- Reload: the reader reuses its pane in the bridge tab (no second new_block), and the sweep
	-- closes an idle leftover reader beside the controller.
	local reader_pane = placed[1].pane
	w:add_usage(9650, 1)
	w:reload()
	w:palette("continue_controller"); w:pick({ continue_controller = true }); assert(w:outcome().ok)
	w.f.origin = clone(w.events[#w.events].origin)
	server.requests = {}
	refresh(function() return successes() == 3 end)
	check(successes() == 3 and #w:usage_placements() == 1 and w.panes[reader_pane] ~= nil and w.panes[reader_pane].block == "usage.capacity",
		"after a window reload the reader reuses the existing usage.capacity pane: no second new_block")
	for _ = 1, 4 do w:tick() end
	check(w.panes[9650] == nil and table.find(w:bridges_closed(), reader_pane) == nil,
		"the sweep closes an idle leftover reader beside the controller and keeps the bound one")
	codec.sha256_step, codec.sha256 = original_step, original_sha256
end
-- SPAWN bridge lifecycle across window reloads: the next effect adopts an idle bridge of the same
-- controller (no new pane, no move); inert bridges of earlier incarnations close one per pass while
-- held, live, busy, foreign-window, legacy and unreadable (moved) bridges stay; reloads and
-- repeated effects never add panes; new bridges open where they stay, never moved.
if section == nil or section == "bridge_lifecycle" then
	local w = window_fixture()
	local pending = w.f:apply("catalog"); assert(pending.ok)
	assert(w.f:apply("claim", { action_id = pending.action_id, executor = w.f.origin.window_epoch }).ok)
	local action = clone(w.f:action(pending.action_id))
	local old = w.f.origin.window_epoch
	local function lease(fields: any?, owner: any?)
		local value = { schema = 1, held = false, live = false, busy = false,
			owner = { controller_pane = "9001", alias_nonce = w.f.origin.alias_nonce, window_key = "", window_epoch = old } }
		for key, v in fields or {} do value[key] = v end
		for key, v in owner or {} do value.owner[key] = v end
		return value
	end
	local function bridges() local n = 0; for _, row in w.panes do if row.block == "spawn.dispatch" then n += 1 end end; return n end
	-- The earlier window incarnation left these bridges: some split beside the controller (tab 1),
	-- some in its background bridge tab 50, where an earlier build also moved 8996 (unreadable now).
	w:bridge({ schema = 1, op = action.request.op, request_id = action.request.request_id, action_id = action.request.action_id,
		origin_binding = action.request.origin_binding, controller_generation = action.request.controller_generation,
		status = "catalog", payload = { namespace = "fixture-spawn", host_key = "fixture-host", config_revision = 0, revision = 0, records = runtime.json.array() } })
	w:lease(9003, lease())
	w:add_bridge(8990, lease({ held = true })) -- SPAWN still names it in a requested authorization.
	w:add_bridge(8991, lease({ live = true })) -- Its execution projection is live.
	w:add_bridge(8992, lease(nil, { controller_pane = "9099", alias_nonce = "gone-controller" })) -- Another controller, now absent.
	w:add_bridge(8993, lease(nil, { window_key = "other-window" })) -- Another window's bridge.
	w:add_bridge(8994, nil) -- A legacy SPAWN bridge renders no lease.
	w:add_bridge(8995, lease({ busy = true })) -- A membership verification is in flight.
	w:add_bridge(8996, lease(), 50); w:moved_earlier(8996) -- Would be idle, but its surface is unreadable.
	w:add_bridge(9020, lease(), 50); w:add_bridge(9021, lease(), 50) -- Created directly in the bridge tab.
	for pane = 9022, 9024 do w:add_bridge(pane, lease()) end -- Inert leftovers beside the controller.
	w:reload()
	w:palette("continue_controller"); w:pick({ continue_controller = true }); assert(w:outcome().ok)
	w.f.origin = clone(w.events[#w.events].origin)
	w:click("reconcile", { action_id = action.request.action_id })
	w:tick(); w:tick()
	local query = assert(w:bridge_events()[1])
	check(#w:bridge_placements() == 0 and w:bridge_panes()[1] == 9020 and query.op == "status" and w:moves() == 1 and w.panes[9020].tab == 50,
		"after a window reload the next effect reuses an idle bridge of the bridge tab in place: no new pane and no move")
	for _ = 1, 15 do
		local before = #w:bridges_closed()
		w:tick(); w:tick()
		check(#w:bridges_closed() - before <= 1, "inert bridges are closed at a bounded rate, one per pass")
	end
	local closed = table.clone(w:bridges_closed()); table.sort(closed)
	check(table.concat(closed, ",") == "8992,9003,9022,9023,9024",
		"stale inert bridges close through the native pane close; only bridge-tab spares of the present controller stay")
	for _, pane in { 8990, 8991, 8993, 8994, 8995, 8996, 9020, 9021 } do
		check(w.panes[pane] ~= nil, "held, live, busy, foreign-window, legacy, unreadable, bound and spare bridges are kept: " .. tostring(pane))
	end
	check(w:moves() == 1 and w.panes[8990].tab == 1 and w.panes[9021].tab == 50, "no bridge is ever moved between tabs")
	local settled = bridges()
	for cycle = 1, 6 do
		w:reload()
		local sent = #w:bridge_panes()
		w:palette("recovery_guide"); for _ = 1, 3 do w:tick() end
		check(#w:bridge_panes() == sent + 1 and w:bridge_panes()[sent + 1] == 9020 and #w:bridge_placements() == 0 and bridges() == settled,
			"reload " .. tostring(cycle) .. ": the owner probe reuses the idle bridge and the bridge count stays bounded")
	end
	for _ = 1, 10 do w:palette("recovery_guide"); for _ = 1, 3 do w:tick() end end
	check(#w:bridge_placements() == 0 and bridges() == settled, "repeated effects in one window session reuse the lane's bridge")
	w:lease(9020, lease({ held = true }))
	w:reload()
	local sent = #w:bridge_panes()
	w:palette("recovery_guide"); for _ = 1, 3 do w:tick() end
	check(w:bridge_panes()[sent + 1] == 9021 and #w:bridge_placements() == 0,
		"a bridge SPAWN names in a requested authorization is never reused, nor an unreadable one; another idle bridge is")
	w:lease(9021, lease({ live = true }))
	w:next_bridge(9100, nil)
	w:reload()
	sent = #w:bridge_panes()
	w:palette("recovery_guide"); for _ = 1, 3 do w:tick() end
	local placed = w:bridge_placements()[1]
	check(#w:bridge_placements() == 1 and placed.how == "beside" and placed.target == 8996 and placed.focus == false
		and w.panes[9100].tab == 50 and w:bridge_panes()[sent + 1] == 9100 and w:moves() == 1,
		"with no idle bridge left a new one opens directly in the bridge tab, readable and never moved")
	-- No bridge tab yet: the first bridge opens its own named tab in place (a moved pane would be unreadable).
	local v = window_fixture()
	v:bridge({ placeholder = true })
	v:reload()
	v:palette("recovery_guide"); for _ = 1, 3 do v:tick() end
	local first = v:bridge_placements()[1]
	check(#v:bridge_placements() == 1 and first.how == "tab" and first.target == nil and first.focus == false
		and v.panes[9003].tab ~= 1 and v:tab_names()[v.panes[9003].tab] == "SPAWN bridges",
		"the session's first bridge opens in a new SPAWN bridges tab, never splitting the controller")
	check(v:moves() == 0 and v:bridge_panes()[1] == 9003 and v:bridge_events()[1] ~= nil and v:bridge_events()[1].op == "owner_status",
		"the first bridge is never moved, so its surface stays readable and the owner probe reaches it")
end
-- Owner withdrawal of fenced never-launched work through the real window (a retried launch whose expired challenge was rechecked): the
-- owner confirms, the window reads SPAWN's status of the exact fenced request once (never
-- resubmitting it) and sends that evidence; the host cancels on SPAWN's expired-challenge answer.
if section == nil or section == "withdraw_fenced" then
	local w = window_fixture()
	local f = w.f
	local queued = f:queue(false); assert(queued.ok, queued.message)
	assert(f:finish(queued.action_id, "provisioned", { handle = "mailbox-withdraw", binding_digest = string.rep("e", 64),
		capabilities = runtime.json.array({ "report-files-v1", "native-ask-v1" }), limits = {} }).ok)
	local wid = queued.worker_id
	local launch = f.authority.registry.dispatch.workers[wid].launch_action_id
	local expired = { resource = "window_authorization", current = 1, limit = 1, retryable = true, effect_started = false }
	assert(f:finish(launch, "full", expired).code == "backpressure")
	assert(f:apply("retry", { action_id = launch }).ok)
	w:reload(); w:palette("continue_controller"); w:pick({ continue_controller = true }); assert(w:outcome().ok)
	local fenced = f:action(launch)
	check(fenced.phase == "resolved" and fenced.resolution.evidence == "never_claimed", "continuation fences the retried old-route launch")
	local r = fenced.request
	w:bridge({ schema = 1, op = r.op, request_id = r.request_id, action_id = r.action_id, origin_binding = clone(r.origin_binding),
		controller_generation = r.controller_generation, status = "full", payload = expired })
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
	check(reads == 1 and w:outcome().command == "cancel_work" and w:outcome().code == "withdrawal_retiring" and f.authority.registry.dispatch.workers[wid] ~= nil
		and withdrawal().mailbox_retire == "retiring" and withdrawal().status_required == false,
		"the window reads SPAWN's status of the exact fenced request once; the host keeps the worker and retires its unused mailbox")
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
	-- The host block commits under the continued controller origin the window used (as in
	-- alias_recovery); the fixture's pre-reload origin is refused with continuation_required.
	for index = #w.events, 1, -1 do if w.events[index].command == "cancel_work" then f.origin = clone(w.events[index].origin); break end end
	local committed = if delivery and claim then f:apply("result", { action_id = retire_id, executor = claim.executor, grant_id = claim.grant_id, response_bytes = delivery.value }) else nil
	local retired_worker = f.authority.registry.dispatch.workers[wid]
	check(retires == 1 and committed ~= nil and committed.ok and retired_worker ~= nil and retired_worker.mailbox_retired == true,
		"the withdrawal driver sends the one exact retirement and SPAWN's confirmation is recorded; retires=" .. retires .. " ticks=" .. ticks
			.. " retire_phase=" .. tostring(f:action(retire_id) and f:action(retire_id).phase) .. " delivered=" .. tostring(delivery ~= nil)
			.. " commit=" .. tostring(committed and committed.code) .. " mailbox_retired=" .. tostring(retired_worker and retired_worker.mailbox_retired)
			.. " reason=" .. tostring(retired_worker and retired_worker.reason and retired_worker.reason.code))
	assert(f:queue(false).ok)
	check(f.authority.registry.dispatch.workers[wid] == nil, "the retired never-launched worker is reclaimed")
end
-- Config v4 cards (CP1): every new card renders; outside the admitted controller each is read-only
-- with the reason first, checkboxes disabled and no step buttons or field links.
if section == nil or section == "config_cards" then
	local f = shared.fixture(function() return { now_ms = 1700000000000, mono_ms = 1000, epoch = "cards-host" } end)
	local views = shared.load("views")
	local function render(nonce, policy_patch)
		local projection = state.project(f.authority.registry)
		projection.dispatch = dispatch.project(f.authority.registry, f.origin.logical_session_id, f.origin.alias_nonce)
		for k, v in policy_patch or {} do projection.dispatch.workflow.policy[k] = v end
		return views.render({ pane = 42, alias_nonce = nonce, orch_session_id = f.origin.logical_session_id, action_serial = 0, config_open = true }, projection, "ready")
	end
	local function texts(node, out)
		if type(node) ~= "table" then return out end
		if type(node.p) == "table" and type(node.p.role) == "string" and node.p.role:sub(1, 9) == "orchplus." then return out end
		for key, value in node do
			if type(value) == "string" then
				if key == "t" or key == "text" or key == "label" or key == "title" or type(key) == "number" then table.insert(out, value) end
			elseif key ~= "actions" then texts(value, out) end
		end
		return out
	end
	-- The card is the smallest subtree that names the title and holds more than the title itself.
	local function card(node, title)
		if type(node) ~= "table" then return nil end
		for _, child in node.c or {} do local found = card(child, title); if found then return found end end
		local all = texts(node, {})
		if #all > 1 and table.find(all, title) then return node end
		return nil
	end
	-- Nodes are { p = props, c = children }; each node's props are visited exactly once.
	local function walk(node, visit)
		if type(node) ~= "table" then return end
		if type(node.p) == "table" then visit(node.p) end
		for _, child in node.c or {} do walk(child, visit) end
	end
	local function controls(node)
		local out = { checkboxes = 0, disabled = 0, buttons = 0 }
		walk(node, function(p)
			if p.type == "checkbox" then out.checkboxes += 1; if p.disabled == true then out.disabled += 1 end end
			if type(p.actions) == "table" and p.actions.click then out.buttons += 1 end
		end)
		return out
	end
	local titles = { "Loops", "Review & proof", "Release", "Checkouts", "Autonomy", "Work sources", "Routing", "Role guidance", "Templates" }
	local admitted, foreign = render(f.origin.alias_nonce), render("someone-else-nonce")
	for _, title in titles do
		local own, other = card(admitted, title), card(foreign, title)
		check(own ~= nil and other ~= nil, "Config renders the " .. title .. " card for the controller and for other views")
		local own_text, other_text = texts(own, {}), texts(other, {})
		local function first_row(list) for _, t in list do if t ~= title then return t end end return "" end
		check(first_row(other_text):sub(1, 11) == "Read-only: " and first_row(other_text):find("not the session's controller", 1, true) ~= nil,
			title .. " card outside the controller starts with the read-only reason")
		check(first_row(own_text):sub(1, 11) ~= "Read-only: ", title .. " card in the admitted controller is not marked read-only")
		local mine, theirs = controls(own), controls(other)
		check(theirs.buttons == 0 and theirs.disabled == theirs.checkboxes, title .. " card outside the controller has no buttons and only disabled checkboxes")
		check(mine.buttons > 0 or (mine.checkboxes > 0 and mine.disabled == 0), title .. " card in the controller offers its editing controls")
	end
	local function joined(node) return table.concat(texts(node, {}), "\n") end
	local review = joined(card(admitted, "Review & proof"))
	check(review:find("Enforce cross-family review — a green review from a different provider family is the landing proof; off: checks run by the SPAWN helper are the proof", 1, true) ~= nil,
		"Review & proof labels the cross-family switch with both proof rules")
	check(joined(card(admitted, "Role guidance")):find("guidance only — restrict tools in the SPAWN record's own CLI flags", 1, true) ~= nil,
		"Role guidance says it does not restrict tools")
	local loops = joined(card(admitted, "Loops"))
	local loop_lines = texts(card(admitted, "Loops"), {})
	check(table.find(loop_lines, "Loop cap: 3 attempts per loop (1–10)") ~= nil and table.find(loop_lines, "Review rounds: 2 per piece of work (1–2)") ~= nil
		and table.find(loop_lines, "Stale-claim alert after: 30 minutes (0 = off; 0–1440)") ~= nil, "Loops card shows the saved loop_cap, review_rounds and stale_claim_min defaults")
	local changed = texts(card(render(f.origin.alias_nonce, { loop_cap = 7, stale_claim_min = 0 }), "Loops"), {})
	check(table.find(changed, "Loop cap: 7 attempts per loop (1–10)") ~= nil and table.find(changed, "Stale-claim alert after: 0 minutes (0 = off; 0–1440)") ~= nil
		and table.find(changed, "Loop cap: 3 attempts per loop (1–10)") == nil, "Loops card renders the saved values, not fixed text")
	check(loops ~= "", "Loops card has readable text")
	local radios = 0
	walk(card(admitted, "Work sources"), function(p) if type(p.name) == "string" and p.name:sub(1, 12) == "work_source:" then radios += 1 end end)
	check(radios == 2, "default work source choices render while Glitch integration is on")
	radios = 0
	walk(card(render(f.origin.alias_nonce, { glitch_integration = false }), "Work sources"), function(p) if type(p.name) == "string" and p.name:sub(1, 12) == "work_source:" then radios += 1 end end)
	check(radios == 0, "default work source choices are hidden while Glitch integration is off")
	local approvals = 0
	walk(card(admitted, "Autonomy"), function(p) if type(p.name) == "string" and p.name:sub(1, 8) == "approve:" then approvals += 1 end end)
	check(approvals == 4, "Autonomy offers exactly the four auto-approve kinds")
end
-- Checkpoint 6 (D10): the Start work… picker. Glitch off → board flow directly, no picker;
-- otherwise the Config default work source is first and marked "(Recommended)".
if section == nil or section == "work_picker" then
	local function set(w, patch) local saved = w.f:apply("policy", { policy = patch }); assert(saved.ok, saved.message) end
	local w = window_fixture()
	set(w, { glitch_integration = false, board_path = "" })
	local before = w:picker()
	w:click("start_work")
	check(w:picker() == before and #w.board_opened == 0, "Glitch off without a board file: no picker opens and nothing is started")
	check(w.notices[#w.notices]:find("Set the Board file", 1, true) ~= nil, "the owner is told to set the board file")
	set(w, { glitch_integration = false, board_path = "/tmp/fixture-board.tern" })
	w:click("start_work")
	check(w:picker() == before, "Glitch off: Start work never opens the source picker")
	check(#w.board_opened == 1 and w.board_opened[1] == "/tmp/fixture-board.tern", "Glitch off: Start work goes straight to the board flow and opens the Config board")
	for _, default in { "glitch_plan", "board" } do
		set(w, { glitch_integration = true, default_work_source = default })
		w:click("start_work")
		local picker = assert(w:picker())
		check(picker ~= before and #picker.items == 2, "Glitch on (" .. default .. "): the native picker offers both sources")
		local first, second = picker.items[1], picker.items[2]
		check(first.source == (if default == "board" then "board" else "plan") and first.label:find("(Recommended)", 1, true) ~= nil,
			"default " .. default .. ": its option is first and marked (Recommended)")
		check(second.label:find("Recommended", 1, true) == nil, "default " .. default .. ": the other option is not marked")
		before = picker
	end
	-- The plan option prompts for a path the execution host reads; the window sends only the path.
	set(w, { glitch_integration = true, default_work_source = "glitch_plan" })
	w:click("start_work")
	local items = w:picker().items
	w:pick(items[1])
	check(w:editor() ~= nil, "the plan option prompts for the plan path")
	local sent = #w.events
	w:answer("relative/plan.md")
	check(#w.events == sent, "a relative plan path is refused in the window; nothing is sent")
	w:click("start_work"); w:pick(w:picker().items[1])
	w:answer("/tmp/orch-cp6d-absent/plan.md")
	local last = w.events[#w.events]
	check(#w.events == sent + 1 and last.command == "plan_import" and last.path == "/tmp/orch-cp6d-absent/plan.md" and last.bytes == nil,
		"an absolute path is sent as plan_import {path}; plan bytes never cross the bridge")
end

-- Checkpoint 6 (D12, Contract K): the window's inbox poller archives a file only after its intake
-- is accepted; a window restart before the archive re-scans and archives without a second intake.
if section == nil or section == "inbox_window" then
	local w = window_fixture()
	local dir = "/tmp/orch-cp6d-" .. shared.codec.sha256(tostring(os.clock()) .. ":" .. tostring(math.random())):sub(1, 16)
	runtime.fs.mkdir(dir)
	local saved = w.f:apply("policy", { policy = { inbox_folder = dir, auto_launch_intake = true, poll_ms = 1000,
		routes = runtime.json.array({ { class = "build", record_id = "native" } }) } })
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
	local g = window_fixture()
	local dir2 = dir .. "-held"; runtime.fs.mkdir(dir2)
	assert(g.f:apply("policy", { policy = { inbox_folder = dir2, auto_launch_intake = true, poll_ms = 1000, routes = runtime.json.array() } }).ok)
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
-- 8C (D16): a saved template starts from Start work… → From a template, and from its Config →
-- Templates "Start…" row; the window sends template_start {template_id, input}.
if section == nil or section == "template_start" then
	local w = window_fixture()
	local saved = w.f:apply("policy", { policy = { routes = runtime.json.array({ { class = "build", record_id = "native" } }),
		templates = runtime.json.array({ { id = "draft", title = "Draft notes", prompt = "Draft from {input}.", output = "out/draft.md", next = "", class = "build" } }) } })
	assert(saved.ok, saved.message)
	w:click("start_work")
	local items = assert(w:picker()).items
	check(#items == 3 and items[3].source == "template" and items[3].label == "From a template" and items[1].label:find("(Recommended)", 1, true) ~= nil,
		"with a saved template, Start work offers From a template after the two work sources")
	w:pick(items[3])
	local list = w:picker().items
	check(#list == 1 and list[1].template_id == "draft" and list[1].label:find("Draft notes", 1, true) ~= nil, "From a template lists the saved policy.templates")
	w:pick(list[1])
	check(w:editor() ~= nil and w:editor().placeholder:find("{input}", 1, true) ~= nil, "picking a template prompts for its {input}")
	local sent = #w.events
	w:answer("   ")
	check(#w.events == sent, "a blank template input is refused in the window; nothing is sent")
	-- Config → Templates "Start…" names the template: the window prompts for the input directly.
	local views = shared.load("views")
	local function starts(nonce)
		local view, projection = render_view(w.f, { alias_nonce = nonce, config_open = true })
		views.render(view, projection, "ready")
		local out = {}
		for _, entry in view.actions do
			if entry.kind == "operator-intent" and entry.request.command == "start_work" and entry.request.template_id then table.insert(out, entry.request.template_id) end
		end
		return out
	end
	local row = starts(w.f.origin.alias_nonce)
	check(#row == 1 and row[1] == "draft", "Config → Templates offers Start… for each saved template")
	check(#starts("someone-else-nonce") == 0, "Start… is not offered outside the admitted controller")
	w:click("start_work", { template_id = row[1] })
	w:answer("notes/brief.md")
	local last = w.events[#w.events]
	check(#w.events == sent + 1 and last.command == "template_start" and last.template_id == "draft" and last.input == "notes/brief.md",
		"the input is sent as template_start {template_id, input}")
	local chains = w.f.authority.registry.dispatch.chains
	check(chains ~= nil and next(chains) ~= nil, "the host starts the template chain")
	w:click("start_work", { template_id = "gone" })
	check(#w.events == sent + 1 and w.notices[#w.notices]:find("not saved", 1, true) ~= nil, "a template no longer saved is refused in the window; nothing is sent")
end
-- 8C (D5): Config record pickers list only records that can hold the role.
if section == nil or section == "role_pickers" then
	local w = window_fixture()
	local records = {}
	for _, row in { { "native", false, true }, { "release", true, true }, { "reviewer", true, true }, { "spare", true, false } } do
		local caps = { "report-files-v1", "native-ask-v1" }
		if row[2] then table.insert(caps, "release-manager-v1") end
		table.insert(records, { id = row[1], revision = 0, provider = "omp", account_label = "configured, not verified", backend = "native-agent", enabled = true, eligible = row[3],
			capability_evidence = "configured_operator_attestation_not_runtime_proof", effective_identity = { provider = "omp", evidence = "configured" },
			capabilities = runtime.json.array(caps), unsupported = runtime.json.array(), cwd = "/fixture", placement = "split" })
	end
	local r = w.f:apply("catalog"); assert(r.ok, r.message)
	assert(w.f:finish(r.action_id, "catalog", { namespace = "fixture-spawn", host_key = "fixture-host", config_revision = 0, revision = 0, records = runtime.json.array(records) }).ok)
	assert(w.f:apply("policy", { policy = { reviewer_records = runtime.json.array({ "reviewer" }) } }).ok)
	local function offered(field)
		w:click("policy", { field = field, expected_sha256 = shared.quota.digest(flow(w.f).policy) })
		local out = {}
		for _, item in assert(w:picker()).items do if type(item.value) == "string" and item.value ~= "" then table.insert(out, item.value) end end
		table.sort(out)
		return table.concat(out, ",")
	end
	check(offered("release_manager_record") == "release", "the release-manager picker lists only eligible release-manager-v1 records that are not reviewer records")
	check(offered("labeller_record") == "native,release,reviewer", "the labeller picker lists every eligible, enabled record and no ineligible one")
	assert(w.f:apply("policy", { policy = { release_manager_record = "release" } }).ok)
	check(offered("reviewer_records") == "native", "the reviewer picker lists only eligible records that are neither listed reviewers nor the release manager")
end
-- 8C (CP4 smoke): a landing row never says "owner approved" once a refresh voided the approval.
if section == nil or section == "landing_row" then
	local f = shared.fixture(function() return { now_ms = 1700000000000, mono_ms = 1000, epoch = "landing-row" } end)
	local views = shared.load("views")
	local function row(patch)
		local view, projection = render_view(f)
		local item = { id = "landing-1", revision = 1, status = "blocked", position = 1, work_id = "work-1", worker_id = "worker-1", gate_id = "gate-1", approved = true,
			refresh_required = false, request = { source_ref = "refs/heads/work", source_revision = string.rep("a", 40), target_revision = string.rep("b", 40) } }
		for key, value in patch do item[key] = value end
		projection.dispatch.workflow.landing = { { id = "queue-1", repo_ref = "/repo", target_ref = "refs/heads/main", project_id = "p", items = { item } } }
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
		local view, projection = render_view(f)
		local w = projection.dispatch.workflow.workers[1]
		projection.dispatch.workflow.gates = { { id = "gate-9", revision = 2, worker_id = id, worker_generation = w.worker_generation, work_id = w.work_id, kind = "coordinator_proposal",
			phase = "answered", question = "Dispatch 2A?", options = { { id = "approve", label = "Approve" }, { id = "reject", label = "Reject" } }, answer = answer } }
		return table.concat(strings(views.render(view, projection, "ready"), {}), "\n")
	end
	local text = rendered({ choice_id = "reject", answer = "Checkpoint 2 has not started; proposal refused.", source = { kind = "refusal", code = "scope_mismatch" } })
	check(text:find("Refused by ORCH+ (scope_mismatch), not an owner answer: Checkpoint 2 has not started; proposal refused.", 1, true) ~= nil
		and text:find("Owner answer:", 1, true) == nil, "an ORCH+ refusal is shown as ORCH+'s, with its code and reason, never as an owner answer")
	check(rendered({ choice_id = "approve", source = { kind = "owner" } }):find("Owner answer:", 1, true) ~= nil, "an owner answer still reads as the owner's")
end
-- 8C (D10): imported plans render on the controller surface: title, revision, checkpoints and
-- tasks with states and flags, eight rows per page.
if section == nil or section == "plans_view" then
	local f = shared.fixture(function() return { now_ms = 1700000000000, mono_ms = 1000, epoch = "plans-view" } end)
	f:catalog(0)
	local path = "/tmp/orch-8c-plan-" .. shared.codec.sha256(tostring(os.clock()) .. ":" .. tostring(math.random())):sub(1, 16) .. ".md"
	runtime.fs.write(path, runtime.fs.read(root .. "/tests/fixtures/plan-modern.md", 1048576))
	local imported = f:apply("plan_import", { path = path }); assert(imported.ok, imported.message)
	local views = shared.load("views")
	local function page(n)
		local view, projection = render_view(f, { workflow_plans = if n then { [imported.plan_id] = n } else nil })
		return strings(views.render(view, projection, "ready"), {}), view, projection.dispatch.workflow.plans[1]
	end
	local shown, view, plan = page(nil)
	check(table.find(shown, "Imported plan · " .. plan.title) ~= nil, "each imported plan renders a card titled with the plan title")
	local header = plan.plan_id .. " · revision " .. plan.plan_revision:sub(1, 12) .. " · " .. plan.status .. " · " .. path
	local found = false
	for _, text in shown do if text:sub(1, #header) == header then found = true end end
	check(found, "the plan card names the plan, its short revision, status and path")
	local expected, total = {}, 0
	for _, cp in plan.checkpoints do
		total += 1; table.insert(expected, { prefix = "Checkpoint " .. tostring(cp.n) .. " — " .. cp.title, flags = cp.flags })
		for _, t in cp.tasks do total += 1; table.insert(expected, { prefix = "Task " .. t.id .. " — " .. t.title .. " · " .. t.state, flags = t.flags }) end
	end
	check(total > 8, "the fixture plan needs more than one page")
	local next_page
	for _, entry in view.actions do if entry.kind == "workflow-page" and entry.name == "plan " .. plan.plan_id then next_page = entry end end
	check(next_page ~= nil and next_page.page == 1, "a plan longer than one page offers its next page")
	local seen, flagged = 0, 0
	for p = 0, math.ceil(total / 8) - 1 do
		local rows = page(p)
		local on_page = 0
		for index = p * 8 + 1, math.min(total, p * 8 + 8) do
			local want = expected[index]
			for _, text in rows do
				if text:sub(1, #want.prefix) == want.prefix then
					on_page += 1
					if #want.flags > 0 then
						check(text:find("flags " .. table.concat(want.flags, ", "), 1, true) ~= nil, "a flagged row shows its parser flags: " .. want.prefix); flagged += 1
					end
					break
				end
			end
		end
		check(on_page == math.min(8, total - p * 8), "page " .. tostring(p + 1) .. " shows its checkpoint and task rows in plan order")
		seen += on_page
	end
	check(seen == total and flagged > 0, "every checkpoint and task row renders exactly on its page, flags included")
	runtime.fs.remove(path)
end
-- Tern does not wake an untouched window for a due tern.timer, but a finished child process does.
-- The idle-wake helper keeps one short argv-only wait child in flight only while this window
-- drives a live controller with timed work, and that controller's Health card shows it.
if section == nil or section == "idle_wake" then
	local OK = { status = 0, stdout = "", stderr = "", timed_out = false }
	local function finish(w, outcome) w.processes[#w.processes].callback(outcome or OK, table.clone(w.cx)) end
	local function last_state(w) local event = w.wake_events[#w.wake_events]; return if event then event.state else nil end
	local w = window_fixture()
	check(#w.processes == 0 and #w.wake_events == 0, "no helper before the window has scheduled a controller")
	w:tick()
	local argv = w.processes[1] and w.processes[1].argv
	check(#w.processes == 1 and argv[1] == "sleep" and argv[2] == "2" and #argv == 2,
		"a live controller polling a worker starts one argv-only 2 s wait child, below the 5 s suspension gap")
	check(last_state(w) == "active" and w.wake_events[1].detail == "polling 1 worker"
		and w:rendered():find("Idle-wake helper active: polling 1 worker", 1, true) ~= nil, "Health shows the active helper and its timed work")
	local published = #w.wake_events
	for _ = 1, 3 do w:tick() end
	check(#w.processes == 1 and #w.timers == 1 and #w.wake_events == published, "ticks never stack wait children or timers, nor republish an unchanged state")
	finish(w)
	check(#w.processes == 2 and #w.timers == 1, "a finished wait child starts exactly the next one")
	w.current.id = 8 -- The controller's session is no longer current: this window drives nothing.
	for _ = 1, 3 do w:tick() end
	check(last_state(w) == "idle" and #w.wake_events == published + 1 and w:rendered():find("Idle-wake helper", 1, true) == nil,
		"the controller that left this window is told once that the helper stopped")
	finish(w)
	check(#w.processes == 2, "no wait child follows the in-flight one once no controller has timed work")
	w.current.id = 7
	w:tick()
	check(#w.processes == 3 and last_state(w) == "active", "the helper resumes when the controller is driven again")
	local bare = window_fixture({ no_worker = true })
	for _ = 1, 3 do bare:tick() end
	check(#bare.processes == 0 and last_state(bare) == "idle", "a live controller with no worker, effect, backoff or read runs no helper")
	bare.f:accepted(false)
	bare:tick()
	check(#bare.processes == 1 and last_state(bare) == "active", "registering a worker gives the controller timed work and starts the helper")
	-- Inbox or board polling alone is timed work (final smoke: a file dropped into an untouched
	-- window with no workers was first seen after 288–560 s).
	local dir = "/tmp/orch-idle-wake-" .. shared.codec.sha256(tostring(os.clock()) .. ":" .. tostring(math.random())):sub(1, 16)
	runtime.fs.mkdir(dir)
	local inbox = window_fixture({ no_worker = true })
	assert(inbox.f:apply("policy", { policy = { inbox_folder = dir } }).ok)
	inbox:tick()
	check(#inbox.processes == 1 and last_state(inbox) == "active" and inbox.wake_events[#inbox.wake_events].detail == "polling the intake inbox"
		and inbox:rendered():find("Idle-wake helper active: polling the intake inbox", 1, true) ~= nil,
		"inbox polling alone, with no worker, starts the helper and Health shows it")
	inbox.cx.hosts:current().kind = "remote" -- A remote host's inbox is never polled from this desktop.
	inbox:tick(); finish(inbox); inbox:tick()
	check(#inbox.processes == 1 and last_state(inbox) == "idle", "an inbox this window does not poll is not timed work")
	inbox.cx.hosts:current().kind = nil
	assert(inbox.f:apply("policy", { policy = { inbox_folder = "" } }).ok)
	inbox:tick()
	check(#inbox.processes == 1 and last_state(inbox) == "idle", "clearing the inbox folder stops the helper")
	local board = window_fixture({ no_worker = true })
	assert(board.f:apply("policy", { policy = { board_path = "/tmp/fixture-board.tern" } }).ok)
	board:tick()
	check(#board.processes == 1 and last_state(board) == "active" and board.wake_events[#board.wake_events].detail == "polling the board"
		and board:rendered():find("Idle-wake helper active: polling the board", 1, true) ~= nil,
		"board polling alone, with no worker, starts the helper and Health shows it")
	local both = window_fixture({ no_worker = true })
	assert(both.f:apply("policy", { policy = { board_path = "/tmp/fixture-board.tern", inbox_folder = dir } }).ok)
	both:tick()
	check(last_state(both) == "active" and both.wake_events[#both.wake_events].detail == "polling the intake inbox and board", "Health names both polled sources")
	local unbound = window_fixture({ no_worker = true }) -- Host restart: polling configured, controller awaiting continuation.
	assert(unbound.f:apply("policy", { policy = { inbox_folder = dir } }).ok)
	unbound.f.authority = shared.host.new_authority(unbound.f.memory, function() return { now_ms = 1700000000000, mono_ms = 5000, epoch = "health-host-restarted" } end)
	assert(unbound.f.authority:load().ok)
	for _ = 1, 3 do unbound:tick() end
	check(#unbound.processes == 0 and last_state(unbound) == "idle", "a controller awaiting explicit continuation runs no helper, even while its inbox is configured")
	local hosted_inbox = window_fixture({ context = "host", no_worker = true })
	assert(hosted_inbox.f:apply("policy", { policy = { inbox_folder = dir } }).ok)
	for _ = 1, 3 do hosted_inbox:tick() end
	check(#hosted_inbox.processes == 0 and #hosted_inbox.wake_events == 0, "a host VM never runs the helper for inbox polling")
	pcall(runtime.fs.remove, dir)
	local restarted = window_fixture() -- Host restart: the controller is restored uncertain until continued.
	restarted.f.authority = shared.host.new_authority(restarted.f.memory, function() return { now_ms = 1700000000000, mono_ms = 5000, epoch = "health-host-restarted" } end)
	assert(restarted.f.authority:load().ok)
	for _ = 1, 3 do restarted:tick() end
	check(#restarted.processes == 0 and last_state(restarted) == "idle", "a controller awaiting explicit continuation runs no helper, even with workers")
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
	local reason = refused.wake_events[#refused.wake_events]
	check(#refused.processes == 0 and last_state(refused) == "unavailable" and reason.detail:find("not available on iOS", 1, true) ~= nil and #refused.wake_events == 1
		and #refused.timers == 1 and refused:rendered():find("Idle-wake helper unavailable", 1, true) ~= nil,
		"an unavailable helper shows in Health once and observation continues on the plain timer")
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
