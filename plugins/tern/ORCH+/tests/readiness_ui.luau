-- Optional readiness consent and lifecycle boundaries, without launching a provider.
local root = ...
local chunk = assert(loadstring(tern.fs.read(root .. "/readiness_window.luau"), "readiness-window"))
local module = chunk()
local events, toasts, picks = {}, {}, {}
local data = { source_nonce = "view", setup = { state = "completed" }, installation_defaults = { revision = 7, builder_record = "builder", policy = {} } }
local cx = { session = {}, hosts = {} }
function cx.session:event(_, event) table.insert(events, event) end
function cx.hosts:current() return { kind = "local" } end
function cx:toast(_, _, message) table.insert(toasts, message) end
function cx:pick(options) table.insert(picks, options); return { next = function(_, callback) cx.answer = callback end } end
local origin, serial, current, visible = {}, 0, true, true
local ui = module.new({ setup = function() return data end, origin = function() return origin end, current = function() return current end,
	consent_current = function() return current and visible end,
	flow = function() return { policy = data.installation_defaults.policy, policy_revision = 0 } end, same = function(a, b) return a == b end,
	id = function() serial += 1; return "readiness-" .. serial end,
	queue = function() error("consent test must never launch") end, open_controller = function() end })
ui.start(cx, 1)
assert(#events == 0 and #picks == 1, "opening readiness must not mutate or launch")
cx.answer(picks[1].items[1], nil, cx)
assert(#events == 1, "declining records only the optional observation")
local event = tern.json.decode(events[1].value)
assert(event.kind == "setup_lifecycle" and event.state == nil and event.readiness.state == "not_run", "declining cannot reset required setup")
assert(event.expected_revision == 7 and event.readiness.config_revision == 7, "readiness is fenced to tested configuration")
data.setup.state = "in_progress"
ui.start(cx, 1)
assert(#picks == 1 and #events == 1, "readiness cannot replace incomplete required provisioning")
data.setup.state = "completed"
ui.start(cx, 1)
current = false
cx.answer(picks[2].items[2], nil, cx)
assert(#events == 1, "stale consent cannot persist approval or launch a task")
current = true
ui.start(cx, 1)
cx.answer(picks[3].items[2], nil, cx)
assert(#events == 2 and tern.json.decode(events[2].value).readiness.state == "unavailable",
	"explicit consent records an unconfirmed exercise, never fabricated success")
visible = false
ui.tick(cx)
ui.start(cx, 1)
assert(#events == 2 and #picks == 3, "hiding an already-consented source neither terminates nor repeats its pending exercise")

-- Actual block args/event -> rendered intent -> actual window consumer. Only native APIs are
-- replaced; the owner host, views, setup and readiness modules execute their real paths.
local runtime, environment = tern, getfenv()
local checks = 8
local function check(ok, message) assert(ok, message); checks += 1 end
-- Drive the real readiness state machine; only native process/UI endpoints are fixtures.
local function exercise(project_snapshot)
	local f = { policy_revision = 4, events = {}, notices = {}, processes = {}, queued = {}, serial = 0 }
	local defaults = { require_code_review = true }
	f.data = { source_nonce = "exercise-view", setup = { state = "completed" },
		installation_defaults = { revision = 7, builder_record = "builder", policy = defaults } }
	f.origin = { logical_session_id = "session-exercise" }
	f.policy = defaults
	local fake = table.clone(runtime)
	fake.now = function() return 1000 end
	fake.plugin = { data = "/fixture/plugin-data" }
	fake.fs = { mkdir = function(path) f.path = path end }
	fake.process = { run = function(argv, _, callback) table.insert(f.processes, { argv = argv, callback = callback }) end }
	local script = assert(loadstring(runtime.fs.read(root .. "/readiness_window.luau"), "readiness-exercise"))
	setfenv(script, setmetatable({ tern = fake }, { __index = environment }))
	local cx = { session = {}, hosts = { current = function() return { kind = "local" } end } }
	function cx:toast(_, _, message) table.insert(f.notices, message) end
	function cx:pick(options) f.options = options; return { next = function(_, callback) f.answer = callback end } end
	function cx.session:event(_, event) table.insert(f.events, runtime.json.decode(event.value)) end
	f.ui = script().new({
		id = function() f.serial += 1; return "exercise-" .. f.serial end,
		setup = function() return f.data end, origin = function() return f.origin end,
		current = function() return true end, consent_current = function() return true end,
		same = function(a, b) return runtime.json.encode(a) == runtime.json.encode(b) end,
		flow = function() return { policy_revision = f.policy_revision, policy = f.policy } end,
		catalog = function() end, snapshot = function() return if f.snapshot and project_snapshot then project_snapshot(f.snapshot) else f.snapshot end,
		observation = function() return { catalog = { revision = 3, records = { { id = "builder", revision = 2, enabled = true,
			eligible = true, capabilities = { "check-runner-v1" }, cwd = "/configured/not-the-task", placement = "split" } } }, landings = f.landings or {} } end,
		queue = function(_, _, _, assignment) table.insert(f.queued, assignment); return "queued-exercise" end,
	})
	f.cx = cx
	function f:tick() self.ui.tick(cx) end
	function f:consent()
		self.ui.start(cx, 1); self.answer(self.options.items[2], nil, cx)
		self.data.setup_result = { request_id = self.events[#self.events].request_id, ok = true }
		self:tick()
	end
	function f:complete(index)
		self.processes[index].callback({ status = 0, stdout = "ready\n", stderr = "" }, cx)
	end
	function f:land()
		self:consent()
		for index = 1, 4 do self:complete(index) end
		self:tick()
		self.snapshot = { driver_result = { request_id = "queued-exercise", ok = true, worker_id = "exercise-builder" } }
		self:tick()
		self.landings = { { worker_id = "exercise-builder", repo_ref = self.path, status = "landed" } }
		self:tick()
	end
	function f:restore_policy() self.policy_revision += 2 end -- Two committed edits, final equality restored.
	return f
end
do
	local f = exercise()
	f.ui.start(f.cx, 1)
	f:restore_policy()
	f.answer(f.options.items[2], nil, f.cx)
	check(#f.events == 0 and #f.processes == 0 and #f.queued == 0, "away-and-back policy edits during consent launch nothing")
end
do
	local f = exercise(); f:consent()
	f:restore_policy(); f:complete(1)
	check(#f.processes == 1 and #f.queued == 0 and f.events[#f.events].readiness.state == "unavailable",
		"policy edits during asynchronous repository preparation stop before any further process or provider launch")
end
do
	local f = exercise(); f:land()
	check(#f.queued == 1 and #f.processes == 5, "fixture reaches actual readiness readback only after its matching landed observation")
	f:restore_policy(); f:complete(5)
	check(f.events[#f.events].readiness.state == "unavailable", "away-and-back edits while Git readback is in flight cannot pass the original policy")
	f:tick(); f:complete(5)
	check(#f.queued == 1 and f.events[#f.events].readiness.state == "unavailable", "ended readiness never replays launch or a delayed success callback")
end
do
	local f = exercise(); f:land()
	f:restore_policy(); f:tick()
	local count = #f.events
	f:complete(5)
	check(#f.events == count and f.events[count].readiness.state == "unavailable", "tick detects temporary policy edits and late readback cannot overwrite its refusal")
end
for _, accepted in { true, false } do
	local f = exercise(); f:land(); f:complete(5)
	local result = f.events[#f.events]
	check(result.readiness.state == "passed" and result.readiness_policy.logical_session_id == f.origin.logical_session_id
		and result.readiness_policy.revision == 4, "unchanged run submits its original session policy fence with the passed observation")
	local before = #f.notices
	f:tick()
	check(#f.notices == before, "passing Git readback is not announced before the authority accepts its fence")
	f.data.setup_result = { request_id = result.request_id, ok = accepted, code = if accepted then "setup_saved" else "stale_policy" }
	f:tick()
	check(#f.notices == before + 1 and (f.notices[#f.notices]:find("not saved", 1, true) ~= nil) == (not accepted),
		"final readiness announcement reflects the authority's policy-fenced commit outcome")
end
local function fixture(stored)
	local fake, modules, definition = table.clone(runtime), {}, nil
	local writes, effects, now, timers, hooks, events, notices, picks, commands = 0, 0, 1000, {}, {}, {}, {}, {}, {}
	local function clone(value) return runtime.json.decode(runtime.json.encode(value)) end
	fake.kv = { get = function() return if stored then clone(stored) else nil end,
		set = function(_, value) writes += 1; stored = clone(value) end }
	fake.block = { define = function(_, value) definition = value end }
	fake.now = function() return now end
	fake.on = function(name, callback) hooks[name] = callback end
	fake.timer = function(_, callback) table.insert(timers, callback); return { cancel = function() end } end
	fake.command = function(command) commands[command.id] = command end
	fake.files = { button = function() end }
	local function forbidden_effect()
		effects += 1
		error("page navigation must not launch providers or provision resources")
	end
	fake.process = { run = forbidden_effect }
	fake.fs = table.clone(runtime.fs)
	fake.fs.mkdir = forbidden_effect
	local function load(name, base)
		name = (base or "") .. name:gsub("^%./", "")
		if modules[name] then return modules[name] end
		local chunk = assert(loadstring(runtime.fs.read(root .. "/" .. name .. ".luau"), "readiness-page-" .. name))
		local dir = name:match("^(.*/)")
		setfenv(chunk, setmetatable({ tern = fake, require = function(child) return load(child, dir) end }, { __index = environment }))
		local value = chunk(); modules[name] = value; return value
	end
	if stored == true then
		-- Persisted completed-setup fixture, not evidence of provisioning by navigation.
		stored = load("state").new_registry()
		stored.setup.state = "completed"
	end
	load("host")
	local api = load("window")
	local block_cx = { pane = 42, render = function() end }
	local host = { id = "local", state = "connected", kind = "local", panes = { 42 } }
	local other = { id = "foreign", state = "connected", kind = "local", panes = {} }
	local pane = { pane = 42, block = "orchplus.orchestrator", tab = 1 }
	local session = { id = 7 }
	local f = { visible = true, present = true, window = "", current_host = host, pane = pane, host = host,
		other = other, session = session, tabs = { 1 }, events = events, notices = notices, picks = picks, definition = definition,
		commands = commands, opened = {}, target_events = {}, focuses = {} }
	local cx = { session = {}, sessions = { current = function() return session end },
		hosts = { current = function() return f.current_host end, list = function() return { host, other } end },
		actions = { run = forbidden_effect }, action = forbidden_effect, layout = {} }
	function cx.layout:focus(target)
		f.focused = target
		table.insert(f.focuses, target)
		-- Native focus reveals a pane on an inactive tab before setup validates visibility.
		if target == 42 then f.visible = true end
	end
	f.cx = cx
	function cx:window_key() return f.window end
	function cx:toast(_, _, message) table.insert(notices, message) end
	function cx:pick(options) table.insert(picks, options); return { next = function(_, callback) f.answer = callback end } end
	function cx.session:pane(target)
		if f.present and target == 42 then return pane end
		return if f.spawn and target == f.spawn.pane then f.spawn else nil
	end
	function cx.session:panes()
		local panes = if f.present then { pane } else {}
		if f.spawn then table.insert(panes, f.spawn) end
		return panes
	end
	function cx.session:focused() return f.focused end
	function cx.session:sessions() return { { id = 7, tabs = f.tabs }, { id = 8, tabs = { 2 } } } end
	function cx.session:view(target)
		if target == 42 then return if f.visible and f.present then {} else nil end
		return if f.spawn and target == f.spawn.pane and f.spawn_visible then {} else nil
	end
	function cx:new_block(block, args, placement, options)
		table.insert(f.opened, { block = block, args = args, placement = placement, options = options })
		if block ~= "spawn.spawner" then forbidden_effect() end
		return 91
	end
	local function find(node, key)
		if node.p and node.p.key == key then return node end
		for _, child in node.c or {} do local found = find(child, key); if found then return found end end
		return nil
	end
	function cx.session:surface(_, options)
		local node = find(definition.view(f.view, block_cx).main, options.root:sub(6))
		if not node then return nil end
		node = clone(node); node.id = options.root
		return { surface = { role = "plugin.orchplus.orchestrator" }, main = node }
	end
	function cx.session:event(target, event)
		if target ~= 42 then
			table.insert(f.target_events, { target = target, event = event, focused = f.focused })
			return
		end
		table.insert(events, event)
		definition.event(f.view, event, block_cx)
	end
	function f:open(value, saved)
		self.view = definition.init(block_cx, { "config", value }, saved)
	end
	function f:entry(value, id)
		definition.event(self.view, { ev = "action", id = id or "main", act = "page-entry", value = value }, block_cx)
	end
	function f:consume() api.intents(cx) end
	function f:render() return definition.view(self.view, block_cx).main end
	local function control_node(node, kind, command)
		local click = if node.p and node.p.actions then node.p.actions.click else nil
		local token = if type(click) == "string" then click:match("^control=(.+)$") else nil
		local action = if token then f.view.actions[token] else nil
		if action and action.kind == kind and (command == nil or action.command == command) then return node, token end
		for _, child in node.c or {} do
			local found, value = control_node(child, kind, command)
			if found then return found, value end
		end
		return nil
	end
	function f:has_control(kind, command) return control_node(self:render(), kind, command) ~= nil end
	function f:control(kind, command)
		local node, value = control_node(self:render(), kind, command)
		assert(node, "missing rendered owner control " .. kind .. "/" .. tostring(command))
		if command == "spawn" then
			assert(node.p.attrs and node.p.attrs["data-orchplus-setup"] == "spawn", "SPAWN navigation must be an exposed rendered setup button")
		end
		definition.event(self.view, { ev = "action", id = "main", act = "control", value = value }, block_cx)
	end
	function f:rendered_intent()
		local node = find(self:render(), "operator-intent")
		if not node then return nil end
		local span = node.p.spans[1]
		return runtime.json.decode(if type(span) == "string" then span else span.t)
	end
	function f:effects() return effects end
	function f:writes() return writes end
	function f:stored() return stored end
	function f:expire()
		now += 30001
		timers[1]()
	end
	fake.pane = { list = function() return if f.present then { { pane = 42 } } else {} end }
	return f
end
do
	local rendered = fixture(true)
	rendered:open(nil)
	for _, control in { "register-arm", "register-confirm", "config-close", "admit" } do rendered:control(control) end
	local f = exercise(function(result)
		rendered.view.dispatch_driver_result = result.driver_result
		local surface = rendered.cx.session:surface(42, { root = "main.dispatch-state" })
		assert(surface, "actual controller dispatch surface is unavailable")
		local span = surface.main.p.spans[1]
		return runtime.json.decode(if type(span) == "string" then span else span.t)
	end)
	f:land()
	check(#f.processes == 5, "the real rendered queue result binds readiness to its worker so a matching landed observation starts Git readback")
	f:complete(5)
	check(f.events[#f.events].readiness.state == "passed", "actual controller projection permits successful readback to submit the policy-fenced readiness result")
end
local function page(window) return runtime.json.encode({ kind = "page", page = "readiness", native_window = window }) end
local cold = fixture()
cold:open(page(""))
local intent = cold.view.operator_intent
check(cold.view.config_open and intent.kind == "setup" and intent.request.command == "readiness"
	and intent.request.native_window == "" and intent.request.source_nonce == cold.view.alias_nonce, "empty native window publishes the owner setup intent")
check(cold:writes() == 0 and cold:stored() == nil and cold.view.orch_session_id == nil, "page-only cold start neither initializes authority nor fabricates a controller")
cold:consume()
check(cold.view.operator_intent == nil and #cold.events == 1 and #cold.notices == 1 and #cold.picks == 0,
	"rendered cold-start page settles once and explains the real setup prerequisite")
check(cold:writes() == 0 and cold:stored() == nil, "readiness navigation leaves absent authority absent")
cold:consume()
check(#cold.events == 1 and #cold.notices == 1, "settled launch args do not replay")
cold:entry(page(""))
cold:consume()
check(#cold.events == 2 and #cold.notices == 2 and cold:writes() == 0, "existing-pane main/page-entry follows the same owner consumer")
local saved = cold.definition.save(cold.view)
cold:open(page(""), saved)
check(cold.view.operator_intent == nil, "saved/reloaded views do not replay original native page args")

for _, value in {
	"{}", '{"kind":"page","page":"readiness","native_window":"","extra":true}',
	'{"kind":"other","page":"readiness","native_window":""}',
	'{"kind":"page","page":"managed","native_window":""}',
	'{"kind":"page","page":"readiness","native_window":false}',
	'{"kind":"page","page":"readiness"}', page(string.rep("w", 257)), page("bad\0window"),
	'{"kind":"page","page":"readiness","native_window":"","native_window":"other"}',
} do
	cold:entry(value)
	check(cold.view.operator_intent == nil and cold:writes() == 0, "malformed/extra/duplicate/overbound page fields cannot publish an intent")
end
cold:entry(page(""), "main.other")
check(cold.view.operator_intent == nil, "page entry is accepted only on the main owner node")

local foreign = fixture()
foreign:open(page("another-window"))
foreign:consume()
check(foreign.view.operator_intent ~= nil and #foreign.events == 0 and #foreign.notices == 0,
	"another window does not steal or settle the addressed window's page intent")
foreign.window = "another-window"
foreign:consume()
check(#foreign.events == 0 and #foreign.notices == 0, "a mismatched entry is not delayed navigation after this window changes")
foreign:expire()
check(foreign.view.operator_intent == nil and foreign:writes() == 0, "unconsumed page entry expires through the existing bounded host lifecycle")

for _, invalid in { "hidden", "parked", "foreign-session", "stale-tab", "foreign-host", "disconnected", "stale-alias" } do
	local f = fixture()
	f:open(page(""))
	local alias_nonce = f.view.alias_nonce
	if invalid == "hidden" then f.visible = false
	elseif invalid == "parked" then f.pane.tab = nil
	elseif invalid == "foreign-session" then f.pane.tab = 2
	elseif invalid == "stale-tab" then f.tabs = {}
	elseif invalid == "foreign-host" then f.current_host = f.other
	elseif invalid == "disconnected" then f.host.state = "disconnected"
	else f.view.alias_nonce = "replacement-view" end
	f:consume()
	check(f.view.operator_intent == nil and #f.events == 1 and #f.notices == 1 and #f.picks == 0 and f:writes() == 0,
		invalid .. " page context refuses and settles without setup/provider effects")
	f.visible = true; f.pane.tab = 1; f.tabs = { 1 }; f.current_host = f.host; f.host.state = "connected"; f.view.alias_nonce = alias_nonce
	f:consume()
	check(#f.events == 1 and #f.notices == 1, invalid .. " page cannot run later after moving/restoring its context")
end
local closed = fixture()
closed:open(page(""))
closed.present = false
closed:consume()
closed:expire()
check(#closed.events == 0 and #closed.notices == 0 and closed:writes() == 0, "closed source cannot consume or create effects")
closed.present = true
closed:open(page(""), closed.definition.save(closed.view))
closed:consume()
check(closed.view.operator_intent == nil and #closed.events == 0, "restoring a closed saved source cannot replay page navigation")
local remote = fixture()
remote.host.kind = "remote"
remote:open(page(""))
remote:consume()
check(remote.view.operator_intent == nil and #remote.events == 1 and remote:writes() == 0 and #remote.picks == 0,
	"remote navigation reports the local prerequisite without persisting readiness unavailable")
local configured = fixture(true)
configured:open(nil)
configured:control("register-arm")
configured:control("register-confirm")
configured:control("config-close")
configured:control("admit")
local before = runtime.json.encode(configured:stored())
local before_writes = configured:writes()
configured:entry(page(""))
configured:consume()
check(#configured.picks == 1 and configured.view.operator_intent == nil and configured:writes() == before_writes
	and runtime.json.encode(configured:stored()) == before, "actual owner page opens consent without touching completed setup, authority or provider effects")
configured.visible = false
configured.answer(configured.picks[1].items[2], nil, configured.cx)
check(configured:writes() == before_writes, "hidden source cannot turn delayed consent into authority writes")
configured.visible = true
configured:entry(page(""))
configured:consume()
check(#configured.picks == 2 and configured:writes() == before_writes, "a fresh explicit page entry can reopen consent without auto-approving")

-- Registered palette commands must reveal the selected sole ORCH pane on an inactive
-- tab before the real setup/readiness origin checks run.
for _, command in { "orch_setup", "installation_defaults" } do
	local f = fixture(true)
	f:open(nil)
	f.tabs = { 1, 3 }
	f.pane.tab = 3
	f.visible = false
	f.focused = 900
	local stored_before, writes_before = runtime.json.encode(f:stored()), f:writes()
	check(f.cx.session:view(42) == nil and f.commands[command] ~= nil, command .. ": registered command starts with the sole ORCH pane hidden")
	f.commands[command].run(f.cx)
	check(f.focused == 42 and f.visible and #f.focuses == 1 and #f.opened == 0,
		command .. ": palette focuses and reveals the selected inactive-tab pane instead of opening another")
	check(#f.picks == 1 and f.picks[1].items[1].configure == true and f.picks[1].items[2].spawn == true and #f.notices == 0,
		command .. ": real setup wizard opens after focus rather than refusing a hidden source")
	check(f:writes() == writes_before and runtime.json.encode(f:stored()) == stored_before and f:effects() == 0 and #f.events == 0,
		command .. ": opening the wizard does not persist setup or launch a provider")
end
configured.tabs = { 1, 3 }
configured.pane.tab = 3
configured.visible = false
configured.focused = 900
local readiness_picks = #configured.picks
local readiness_notices = #configured.notices
configured.commands.orch_readiness.run(configured.cx)
check(configured.focused == 42 and configured.visible and #configured.focuses == 1 and #configured.opened == 0,
	"orch_readiness: registered palette command reveals the sole inactive-tab controller")
check(#configured.picks == readiness_picks + 1 and configured.picks[#configured.picks].items[2].consent == true
	and #configured.notices == readiness_notices, "orch_readiness: real optional readiness consent opens after focus")
check(configured:writes() == before_writes and runtime.json.encode(configured:stored()) == before and configured:effects() == 0,
	"orch_readiness: palette navigation preserves completed setup without consent or provider effects")

-- Click the actual rendered setup button, let the host publish its render-scoped
-- intent, then consume that surface with the real window owner. SPAWN is represented
-- only by native pane endpoints: this fixture does not import a foreign plugin.
for _, status in { "missing", "quarantined", "missing_established" } do
	for _, destination in { "new-pane", "existing-pane" } do
		local f = fixture(if status == "quarantined" then { invalid_authority = true, retained_owner = "do-not-replace" } else nil)
		f:open(nil, if status == "missing_established" then { established = true } else nil)
		if destination == "existing-pane" then
			f.spawn = { pane = 91, block = "spawn.spawner", tab = 1 }
			f.spawn_visible = true
			table.insert(f.host.panes, 91)
		end
		local name = status .. "/" .. destination
		local stored_before = if f:stored() ~= nil then runtime.json.encode(f:stored()) else nil
		check(runtime.json.encode(f:render()):find("Authority store: " .. status, 1, true) ~= nil,
			name .. ": real owner renders its unavailable authority status")
		check(f:has_control("recheck-store") and f:has_control("initialize-arm") == (status == "missing")
			and not f:has_control("initialize-confirm"), name .. ": recovery and first-use confirmation gates remain available only where appropriate")
		f:control("setup-intent", "spawn")
		local published = f:rendered_intent()
		check(published and published.kind == "setup" and published.request.command == "spawn"
			and published.source_nonce == f.view.alias_nonce and published.request.source_nonce == f.view.alias_nonce
			and published.request.native_window == nil, name .. ": rendered button publishes the real nonce-bound operator intent")
		check(#f.opened == 0 and #f.target_events == 0 and f:writes() == 0 and f:effects() == 0,
			name .. ": host click alone does not navigate, initialize or provision")
		f:consume()
		check(f.view.operator_intent == nil and f:rendered_intent() == nil and #f.events == 1
			and f.events[1].act == "operator-intent-done", name .. ": actual window settles the rendered intent exactly once")
		local entry
		if destination == "new-pane" then
			check(#f.opened == 1 and #f.target_events == 0 and #f.focuses == 0,
				name .. ": actual window opens a native SPAWN pane without dispatching a plugin action")
			local opened = f.opened[1]
			check(opened.block == "spawn.spawner" and opened.placement == "beside" and #opened.args == 1
				and opened.options.target == 42 and opened.options.focus == true,
				name .. ": new native page is focused beside the validated source")
			entry = runtime.json.decode(opened.args[1])
		else
			check(#f.opened == 0 and #f.target_events == 1 and #f.focuses == 1 and f.focuses[1] == 91,
				name .. ": actual window reuses the suitable native SPAWN pane")
			local delivered = f.target_events[1]
			check(delivered.target == 91 and delivered.focused == 91 and delivered.event.ev == "action"
				and delivered.event.id == "main" and delivered.event.act == "page-entry",
				name .. ": native focus precedes the owner-handled page-entry event")
			entry = runtime.json.decode(delivered.event.value)
		end
		check(entry.kind == "page" and entry.page == "managed" and entry.native_window == "",
			name .. ": native owner receives the managed page and exact empty window key")
		local fields = 0
		for _ in entry do fields += 1 end
		check(fields == 3, name .. ": native page payload contains navigation only")
		f:consume()
		check(#f.events == 1 and #f.opened + #f.target_events == 1 and #f.notices == 0 and #f.picks == 0,
			name .. ": settled click never replays navigation or invokes setup mutations")
		local stored_after = if f:stored() ~= nil then runtime.json.encode(f:stored()) else nil
		check(f:writes() == 0 and stored_after == stored_before and f:effects() == 0
			and f.view.orch_session_id == nil, name .. ": absent authority stays absent and corrupt authority remains unchanged without provider effects")
		check(f:has_control("setup-intent", "spawn") and f:has_control("recheck-store")
			and f:has_control("initialize-arm") == (status == "missing") and not f:has_control("initialize-confirm"),
			name .. ": SPAWN navigation leaves recovery and initialization controls intact")
	end
end
return "readiness_ui: " .. tostring(checks) .. " checks"
