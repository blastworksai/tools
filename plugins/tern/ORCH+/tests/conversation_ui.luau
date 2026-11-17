-- Exercise real conversation-window choices and one-shot submissions through native API boundaries.
local root, section = ...
assert(section == nil or table.find({ "conversation", "association", "projects", "creation", "presentation", "project_choice" }, section), "unknown conversation UI section")
local runtime, environment = tern, getfenv()
local checks = 0
local function check(value, message) assert(value, message); checks += 1 end
local function equal(a, b)
	if type(a) ~= type(b) then return false end
	if type(a) ~= "table" then return a == b end
	for key, value in a do if not equal(value, b[key]) then return false end end
	for key in b do if a[key] == nil then return false end end
	return true
end
local function fixture()
	local f = { now = 0, serial = 0, valid = true, sent = {}, notices = {}, picks = {}, prompts = {}, events = {}, controls = {}, focused = {},
		projects = { p1 = { orch_project_id = "p1", name = "Research", revision = 1, decision_context = "project-proof", started = false, associations = {} } },
		data = { source_nonce = "view", orch_session_id = "orchestration" }, policy = { quota_routing = false }, panes = { { pane = 51, kind = "agent", title = "Existing research" } },
		agent = { pane = 51, state = "idle" }, defaults = { revision = 3, coordinator_record = "preferred" } }
	f.origin = { alias_nonce = "view", logical_session_id = "orchestration", window_key = "window", window_epoch = "epoch", native_session_id = "session", window_host_id = "local" }
	f.record = { id = "preferred", revision = 7, capabilities = { "report-files-v1", "coordinator-control-v1", "project-start-v1" }, cwd = "/research", placement = "split", backend = "native-agent" }
	local fake = table.clone(runtime); fake.now = function() return f.now end
	local modules = {}
	local function load(name)
		name = name:gsub("^%./", "")
		if modules[name] then return modules[name] end
		local chunk = assert(loadstring(runtime.fs.read(root .. "/" .. name .. ".luau"), name))
		setfenv(chunk, setmetatable({ tern = fake, require = load }, { __index = environment }))
		modules[name] = chunk(); return modules[name]
	end
	function f:id() self.serial += 1; return "request-" .. tostring(self.serial) end
	function f:context()
		local cx = { session = {}, layout = {} }; self.cx = cx
		local function pending(collection, options)
			local item = { options = options }; table.insert(collection, item)
			return { next = function(_, callback) item.callback = callback end }
		end
		function cx:pick(options) return pending(f.picks, options) end
		function cx:prompt(options) return pending(f.prompts, options) end
		function cx:toast(_, _, message) table.insert(f.notices, message) end
		function cx:window_key() return "window" end
		function cx:open(path) f.opened = path end
		function cx.session:panes() return f.panes end
		function cx.session:event(source, event) table.insert(f.events, { source = source, action = event.act, value = runtime.json.decode(event.value) }) end
		function cx.layout:focus(pane) table.insert(f.focused, pane) end
		return cx
	end
	local api = {
		id = function() return f:id() end, same = equal,
		forms = {
			choose = function(_, _, _, options, done) table.insert(f.picks, { options = options, callback = function(choice, _, fresh) done(fresh, choice) end }) end,
			input = function(_, _, _, options, done) table.insert(f.prompts, { options = options, callback = function(value, _, fresh) done(fresh, value) end }) end,
			open = function(_, _, _, spec, done) f.form = { spec = spec, done = done } end,
			update = function(_, _, changes) f.feedback = changes end,
			cancel = function() f.form = nil end,
			active = function(_, tag) return f.form ~= nil and (tag == nil or f.form.spec.tag == tag) end,
		},
		setup_ready = function(cx, _, done) done(cx, f.setup_ok ~= false, "Managed setup is incomplete") end,
		open_spawn = function() f.spawn_opened = true end,
		current = function() return f.valid end, fresh = function(_, _, origin) return table.clone(origin) end,
		origin = function() return f.origin end,
		notice = function(_, _, _, message) table.insert(f.notices, message) end,
		capture = function(_, _, promise, callback) promise:next(callback) end,
		node = function(_, _, key)
			if key == "project-index" then return { projects = f.projects, finished_projects = f.finished or {} }
			elseif key == "workflow-index" then return { policy = f.policy }
			elseif key == "setup-index" then return { installation_defaults = f.defaults, setup_result = f.setup_result }
			elseif key:sub(1, 16) == "workflow-worker-" then return f.workers and f.workers[key:sub(17)]
			elseif key == "decision-context-result" then return f.decision_result
			elseif key == "conversation-result" then return f.conversation_result
			elseif key == "orchestration-result" then return f.creation_result end
		end,
		snapshot = function() return f.data end,
		alias = function() return { alias_nonce = "view", authority_namespace = "authority", revision = 4 } end,
		pane = function(_, _, id) for _, pane in f.panes do if pane.pane == id then return pane end end end,
		agent = function(_, id) return if f.agent and id == f.agent.pane then f.agent else nil end,
		binding = function(id, origin) return { pane_id = tostring(id), window_key = origin.window_key, window_epoch = origin.window_epoch, native_session_id = origin.native_session_id, window_host_id = origin.window_host_id } end,
		send = function(_, source, origin, command, fields)
			local id = f:id(); table.insert(f.sent, { request_id = id, command = command, fields = fields, origin = origin, source = source }); return id
		end,
		decision = function(_, _, origin, command, fields) local id = f:id(); f.decision = { request_id = id, fields = fields, origin = origin, command = command }; return id end,
		capacity = function(cx, _, _, done) f.capacity_reads = (f.capacity_reads or 0) + 1; done(cx, true) end,
		new_panel = function() f.created_panel = true; return 42 end, count = function() return 0 end,
		control = function(_, _, command, origin, fields) table.insert(f.controls, command); f.control_request = { command = command, origin = origin, fields = fields } end,
		connect = function(_, source, creation, done) f.connection = { source = source, creation = creation, done = done } end,
		sources = { start = function(_, _, _, command, request) f.source = { command = command, request = request } end },
		picker = {
			pick = function(_, _, _, options, done) f.agent_picker = { options = options, done = done } end,
			load = function(cx, _, _, done) f.catalog_loaded = true; done(cx, { revision = 8 }) end,
			ensure = function(cx, _, _, id, done) check(id == "preferred", "only exact saved preferred record is resolved"); done(cx, f.record, { revision = 8 }) end,
		},
	}
	f.ui = load("conversation_window").new(api)
	function f:another_project()
		self.projects.p0 = { orch_project_id = "p0", name = "Archive", revision = 1, decision_context = "other-proof", started = false, associations = {} }
	end
	function f:tick() self.ui.tick(self:context()) end
	function f:choose(field, value)
		local pending = table.remove(self.picks, 1); assert(pending, "missing native picker")
		local chosen
		for _, item in pending.options.items do if item[field] == value then chosen = item; break end end
		assert(chosen, "missing offered choice " .. tostring(field) .. "=" .. tostring(value))
		pending.callback(chosen, nil, self:context())
	end
	function f:text(value) local input = table.remove(self.prompts, 1); assert(input); input.callback(value, nil, self:context()) end
	function f:agent_choice() local picker = self.agent_picker; assert(picker); self.agent_picker = nil; picker.done(self:context(), self.record, { revision = 8 }) end
	function f:answer(extra)
		local last = self.sent[#self.sent]; assert(last)
		local response = { request_id = last.request_id, ok = true }; for key, value in extra or {} do response[key] = value end
		self.data.command_result = { request_id = "unrelated-persistent-outcome", ok = false }
		self.data.driver_result = response; self:tick()
	end
	function f:start(command, request) return self.ui.start(self:context(), 42, self.origin, command, request or {}) end
	function f:create(mode)
		self.ui.create(self:context()); self:tick(); self:tick()
		self:choose("mode", mode or "default"); self:tick()
	end
	return f
end
if section == nil or section == "conversation" then
	local f = fixture(); f.policy.quota_routing = true
	f:start("new_conversation"); f:agent_choice()
	local sent = f.sent[1]
	check(sent.command == "queue" and sent.fields.presentation == "user_new_tab" and sent.fields.open_conversation == true, "new conversation overrides saved split with a focused native tab")
	check(sent.fields.cwd == "/research" and sent.fields.execution_cwd == nil and sent.fields.files == nil and sent.fields.checks == nil, "text and research have no repository/files/checks/base wizard")
	check(f.capacity_reads == 1 and #f.prompts == 0, "real capacity path precedes the explicit saved-record launch without a task prompt")
	f:tick(); f.now = 31000; f:tick(); f:tick()
	check(#f.sent == 1 and #f.notices == 1, "uncertain launch is never automatically replayed")
	local fresh = fixture(); fresh:another_project(); fresh:start("new_conversation"); fresh:choose("new", true); fresh:text("Notes")
	check(#fresh.sent == 0 and fresh.agent_picker == nil, "new project waits for its own subject decision before creating or launching anything")
	fresh.decision_result = { request_id = "another-decision", decision_context = "unrelated" }; fresh:tick()
	check(#fresh.sent == 0, "another decision cannot authorize project creation")
	fresh.decision_result = { request_id = fresh.decision.request_id, decision_context = "selected-project" }; fresh:tick()
	check(fresh.sent[1].command == "new_project" and fresh.agent_picker == nil, "new project is admitted passively before agent choice")
	fresh.projects.p2 = { orch_project_id = "p2", name = "Notes", revision = 1, associations = {} }
	fresh:answer({ orch_project_id = "p2" }); fresh:agent_choice()
	check(fresh.sent[2].fields.orch_project_id == "p2", "matching driver outcome is followed even when a different persistent owner outcome remains visible")
	local preferred = fixture()
	preferred.policy.preferred_worker_record, preferred.defaults.builder_record = "preferred", "other-default"
	preferred:start("new_conversation")
	check(preferred.sent[1].fields.record_id == "preferred" and preferred.agent_picker == nil,
		"an existing orchestration's preferred worker drives its actual normal launch independently of reusable defaults")
	local orchestrator = fixture()
	orchestrator.policy.preferred_orchestrator_record, orchestrator.defaults.coordinator_record = "preferred", "other-default"
	orchestrator:start("start_orchestrator")
	check(orchestrator.sent[1].fields.record_id == "preferred" and orchestrator.sent[1].fields.coordinator == true,
		"an existing orchestration's preferred orchestrator drives the actual adjacent coordinator launch")
	local empty_preference = fixture(); empty_preference.policy.preferred_orchestrator_record = ""
	empty_preference:start("start_orchestrator")
	check(empty_preference.agent_picker ~= nil and #empty_preference.sent == 0,
		"an empty saved preference opens the actual agent selector without choosing or launching an agent")
	local old_bundle = fixture(); old_bundle.policy.preferred_orchestrator_record = "preferred"
	old_bundle.record.capabilities = { "report-files-v1", "coordinator-control-v1" }
	old_bundle:start("start_orchestrator")
	check(#old_bundle.sent == 0 and old_bundle.agent_picker.options.need == "project-start-v1"
		and old_bundle.policy.preferred_orchestrator_record == "preferred",
		"a stale preferred bundle remains saved metadata but cannot start a fresh START-capable coordinator")
	local changed = fixture(); changed:another_project(); changed:start("new_conversation"); changed:choose("new", true); changed:text("Retain this name")
	changed.decision_result = { request_id = changed.decision.request_id }; changed:tick(); changed:tick()
	check(#changed.sent == 0 and changed.agent_picker == nil, "changed creation context never creates a project or launches a conversation")
	changed:start("new_conversation"); changed:choose("new", true)
	check(changed.prompts[1].options.value == "Retain this name", "refused project creation retains the user's name for their next decision")
end
if section == nil or section == "association" then
	local f = fixture(); f.agent.state = "working"
	f:start("attach_conversation"); f:choose("pane", 51)
	check(#f.sent == 0 and f.decision.fields.active and f.agent_picker == nil, "busy unknown-account conversation is associated without a saved-agent assertion or task delivery")
	f.decision_result = { request_id = f.decision.request_id, decision_context = "association-proof" }; f:tick()
	check(f.sent[1].command == "associate_conversation" and f.sent[1].fields.decision_context == "association-proof", "passive association uses exact host-produced subject proof")
	f:answer(); check(#f.sent == 1 and f.agent_picker == nil and not f.projects.p1.started, "busy attachment neither enrolls nor starts a project")
	local idle = fixture(); idle:start("attach_conversation"); idle:choose("pane", 51)
	idle.decision_result = { request_id = idle.decision.request_id, decision_context = "proof" }; idle:tick(); idle:answer(); idle:choose("enable", true); idle:agent_choice()
	local enrolled = idle.sent[2]
	check(enrolled.command == "enrol" and enrolled.fields.delivery == "native_ask" and enrolled.fields.prompt == nil and enrolled.fields.attestation == nil, "native idle enrollment appends only canonical protocol enrollment, never fake attestation or task replay")
	local terminal = fixture(); terminal.agent = nil; terminal.panes[1].kind = "terminal"
	terminal:start("attach_conversation"); terminal:choose("pane", 51)
	terminal.decision_result = { request_id = terminal.decision.request_id, decision_context = "proof" }; terminal:tick(); terminal:answer(); terminal:choose("enable", true); terminal:agent_choice()
	check(terminal.sent[2].fields.delivery == "clipboard", "terminal enrollment requires the explicit one-time copy choice and never reports ACCEPTED")
end
if section == nil or section == "projects" then
	local f = fixture(); local p = f.projects.p1
	p.checks_pending = true; p.checks = { { checks = { { check_id = "review", argv = { "check", "path with spaces" } } } } }
	f:start("project_start", { orch_project_id = "p1", project_revision = 1, decision_context = "project-proof" })
	check(#f.sent == 0 and f.picks[1] ~= nil, "declared-check review waits for an explicit project start choice")
	f:choose("confirm", true)
	check(f.sent[1].command == "project_start" and f.sent[1].fields.checks_reviewed == true and f.sent[1].fields.decision_context == "project-proof", "START submits only the chosen project and captured proof")
	local stale = fixture(); stale:start("project_start", { orch_project_id = "p1", project_revision = 0, decision_context = "old" })
	check(#stale.sent == 0 and #stale.notices == 1, "stale rendered START does not refresh its authorization")
	local reopen = fixture(); reopen:start("project_reopen", { summary_index = 2 })
	check(reopen.sent[1].command == "project_reopen" and reopen.sent[1].fields.summary_index == 2, "reopen asks the reducer for a new unstarted project, never resumes old execution")
	local held = fixture(); held.projects.p1.started, held.projects.p1.held_work = true, true
	held:start("project_menu", { orch_project_id = "p1" }); held:choose("command", "project_start")
	check(held.sent[1].command == "project_start", "an ACTIVE project still exposes explicit START for newly held passive work")
	local pending = fixture()
	pending.projects.p1.revision = 7
	pending.projects.p1.start = { start_id = "original-start", project_revision = 2, action_id = "typed-action", action_revision = 1,
		decision_context = "original-proof", state = "failed", failure = { code = "refused", message = "Held", retryable = true } }
	pending:start("project_menu", { orch_project_id = "p1" }); pending:choose("command", "project_start_retry")
	check(#pending.sent == 0 and pending.control_request.command == "project_start_retry"
		and pending.control_request.fields.start_id == "original-start" and pending.control_request.fields.project_revision == 2
		and pending.control_request.fields.decision_context == "original-proof",
		"Retry delivery uses the original grant revision/proof, not current project revision or a new START")
	pending:start("project_start", { orch_project_id = "p1", project_revision = 7, decision_context = "project-proof" })
	check(#pending.sent == 0 and #pending.controls == 1, "a repeated START while its original grant is pending cannot issue another approval")
	pending:start("project_start_retry", { orch_project_id = "p1", start_id = "wrong-start", project_revision = 2, decision_context = "original-proof" })
	check(#pending.controls == 1, "stale retry identity is refused before entering native delivery controls")
	local repo = fixture(); repo:start("project_repository", { orch_project_id = "p1" })
	local discovery = repo.events[1]
	repo.setup_result = { request_id = discovery.value.request_id, ok = true, cwd = "/known/workspace",
		folders = { "/known/workspace" }, branches = { "refs/heads/feature", "refs/heads/release" }, default_ref = "refs/heads/release" }
	repo:tick()
	repo.form.done(repo:context(), { queue_route = "repository_queue" }, "save")
	local probe = repo.events[2]
	check(probe.action == "setup-repository-probe" and probe.value.cwd == "/known/workspace"
		and probe.value.target_ref == "refs/heads/release" and #repo.sent == 0,
		"a discovered project folder and non-main repository default need no duplicate path entry or feature-HEAD assumption")
	repo.setup_result = { request_id = probe.value.request_id, ok = true, repository = {
		cwd = "/canonical/checkout", repo_root = "/canonical/checkout", common_dir = "/canonical/checkout/.git",
		target_ref = "refs/heads/release", head_revision = string.rep("a", 40) } }
	repo:tick()
	check(#repo.sent == 0, "choosing a landing route waits for the authority's exact project/repository decision")
	repo.decision_result = { request_id = "unrelated-decision", decision_context = "not-this-checkout" }; repo:tick()
	check(#repo.sent == 0, "another decision result cannot authorize the selected checkout")
	repo.decision_result = { request_id = repo.decision.request_id, decision_context = "selected-checkout-proof" }; repo:tick(); repo:tick()
	check(repo.sent[1].command == "project_repository" and repo.sent[1].fields.repository.cwd == "/canonical/checkout"
		and repo.sent[1].fields.repository.queue_route == "repository_queue" and repo.sent[1].fields.project_revision == 1
		and repo.sent[1].fields.decision_context == "selected-checkout-proof" and #repo.sent == 1,
		"only canonical host proof plus the real landing-route decision becomes this project's association")
	local ambiguous = fixture(); ambiguous:start("project_repository", { orch_project_id = "p1" })
	ambiguous.setup_result = { request_id = ambiguous.events[1].value.request_id, ok = true, cwd = "/known/workspace",
		folders = { "/known/workspace" }, branches = { "refs/heads/feature", "refs/heads/release" } }; ambiguous:tick()
	ambiguous.form.done(ambiguous:context(), {}, "save")
	check(#ambiguous.events == 1 and ambiguous.feedback.errors.target_ref ~= nil, "ambiguous defaults wait for an explicit inline branch selection before host verification")
	local existing = fixture()
	existing.projects.p1.repository = { cwd = "/known/workspace", target_ref = "refs/heads/retained", queue_route = "orch_queue" }
	existing:start("project_repository", { orch_project_id = "p1" })
	existing.setup_result = { request_id = existing.events[1].value.request_id, ok = true, cwd = "/known/workspace",
		folders = { "/known/workspace" }, branches = { "refs/heads/release" }, default_ref = "refs/heads/release" }; existing:tick()
	existing.form.done(existing:context(), {}, "edit"); existing.form.done(existing:context(), {}, "save")
	check(existing.events[2].value.target_ref == "refs/heads/retained", "repository discovery never redirects an explicit existing merge target")
	local function prepared_repository()
		local value = fixture(); value:start("project_repository", { orch_project_id = "p1" })
		value.setup_result = { request_id = value.events[1].value.request_id, ok = true, cwd = "/known/workspace",
			folders = { "/known/workspace" }, branches = { "refs/heads/release" }, default_ref = "refs/heads/release" }
		value:tick(); value.form.done(value:context(), {}, "save")
		return value
	end
	local cancelled = prepared_repository()
	local late_probe = cancelled.events[2]
	cancelled.form.done(cancelled:context(), nil, "cancel")
	cancelled.setup_result = { request_id = late_probe.value.request_id, ok = true, repository = repo.setup_result.repository }; cancelled:tick()
	check(cancelled.form == nil and cancelled.decision == nil and #cancelled.sent == 0,
		"Back during verification clears its pre-write continuation so a late proof cannot save repository settings")
	local reviewed = prepared_repository()
	reviewed.setup_result = { request_id = reviewed.events[2].value.request_id, ok = true, repository = repo.setup_result.repository }; reviewed:tick()
	local late_decision = reviewed.decision.request_id
	reviewed.form.done(reviewed:context(), nil, "cancel")
	reviewed.decision_result = { request_id = late_decision, decision_context = "late-confirmation" }; reviewed:tick()
	check(#reviewed.sent == 0, "Back during the read-only decision context prevents its late result from issuing a save")
	local sent = prepared_repository()
	sent.setup_result = { request_id = sent.events[2].value.request_id, ok = true, repository = repo.setup_result.repository }; sent:tick()
	sent.decision_result = { request_id = sent.decision.request_id, decision_context = "confirmed-before-back" }; sent:tick()
	sent.form.done(sent:context(), nil, "cancel")
	local replacement = { spec = { tag = "settings" } }; sent.form = replacement
	sent.valid = false; sent:answer()
	check(sent.form == replacement and #sent.sent == 1, "an already-issued save settles its exact receipt across focus loss without cancelling or overwriting a replacement form")
	local moved = fixture()
	moved.projects.p1.association_contexts = { worker = "captured-association-proof" }
	moved.workers = { worker = { worker_id = "worker", work_id = "Existing research", orch_project_id = "elsewhere" } }
	moved:start("project_associate", { orch_project_id = "p1" }); moved:choose("worker_id", "worker")
	check(moved.sent[1].command == "project_associate" and moved.sent[1].fields.decision_context == "captured-association-proof"
		and moved.sent[1].fields.project_revision == 1, "managed association carries the captured subject proof without START or a native effect")
	local changed = fixture()
	changed.projects.p1.association_contexts = { worker = "before" }; changed.workers = moved.workers
	changed:start("project_associate", { orch_project_id = "p1" }); changed.projects.p1.association_contexts.worker = "after"
	changed:choose("worker_id", "worker")
	check(#changed.sent == 0, "managed association does not replace its pre-choice subject proof after the worker changes")
end
if section == nil or section == "creation" then
	local f = fixture(); f.policy.preferred_orchestrator_record = "preferred"; f:create()
	check(not f.ui.runnable(42), "waiting for an orchestration name does not keep an idle wake helper running")
	check(f.created_panel and f.prompts[1] ~= nil and #f.events == 0, "new orchestration stays uncreated until its in-pane name is submitted")
	f:text("Research desk")
	check(f.events[1].action == "orchestration-create" and f.events[1].value.defaults_revision == 3, "one creation action pins installation defaults")
	f.creation_result = { request_id = f.events[1].value.request_id, ok = true, orch_session_id = "created-session", owner_id = "created-owner", generation = 1 }; f:tick()
	check(f.connection and f.connection.creation.request_id == f.creation_result.request_id
		and f.connection.creation.orch_session_id == "created-session" and f.connection.creation.owner_id == "created-owner"
		and f.connection.creation.generation == 1 and f.connection.creation.authority_namespace == "authority"
		and f.connection.creation.source_nonce == "view" and #f.controls == 0 and #f.sent == 0,
		"Create binds its actual ownership result to paired first use before admission or any native launch")
	f:tick()
	check(#f.controls == 0 and #f.sent == 0, "an unfinished pairing never becomes an owner_status/admission shortcut")
	f.connection.done(f:context(), true)
	f.connection.done(f:context(), true)
	check(#f.controls == 1 and f.controls[1] == "bridge_admit" and #f.sent == 0, "only successful bilateral completion admits once before project creation")
	f.data.session_control = { admitted = true }; f:tick()
	f.decision_result = { request_id = f.decision.request_id, decision_context = "new-orchestration-project" }; f:tick()
	f.projects.p2 = { orch_project_id = "p2", name = "Research desk", revision = 1, associations = {} }
	local project_request = f.sent[1]
	check(f.ui.runnable(42), "a pending container project receipt is timed work even before any worker exists")
	f.data.command_result = { request_id = "housekeeping", ok = true, code = "cleanup_summary" }
	f.data.driver_result = { request_id = "other-effect", ok = true }
	local function retained_result()
		return { source_nonce = f.origin.alias_nonce, orch_session_id = f.origin.logical_session_id, creation_request_id = f.events[1].value.request_id,
			result = { request_id = project_request.request_id, command = "new_project", ok = true, orch_project_id = "p2" } }
	end
	for _, wrong in { "request", "command", "source", "session", "creation" } do
		local retained = retained_result()
		if wrong == "request" then retained.result.request_id = "other-request"
		elseif wrong == "command" then retained.result.command = "project_start"
		elseif wrong == "source" then retained.source_nonce = "other-source"
		elseif wrong == "creation" then retained.creation_request_id = "other-creation"
		else retained.orch_session_id = "other-session" end
		f.conversation_result = retained; f:tick(); f:start("start_orchestrator")
		check(#f.picks == 0 and #f.sent == 1, "a mismatched retained receipt cannot release the creation hold: " .. wrong)
	end
	f.conversation_result = retained_result()
	f.valid = false; f:start("start_orchestrator")
	check(#f.picks == 0 and #f.sent == 1, "a positive project receipt cannot release startup in a changed native context")
	f.valid = true
	check(#f.sent == 1 and f.sent[1].command == "new_project" and f.agent_picker == nil,
		"creating with defaults makes only the held project, never a provider launch")
	f:start("start_orchestrator", { orch_project_id = "p2" })
	check(#f.picks == 0 and #f.sent == 2,
		"native Start consumes an already returned exact project receipt before its guard, without waiting for a timer or replaying creation")
	check(f.sent[2].command == "queue" and f.ui.runnable(42), "settling the exact creation receipt leaves no stale creation job; only the launch it released is in flight")
	local queued = f.sent[2]
	check(f.catalog_loaded and queued.command == "queue" and queued.fields.coordinator and queued.fields.presentation == "coordinator_adjacent",
		"only an explicit Start orchestrator action resolves the saved preferred agent and queues its adjacent pane")
	f:start("start_orchestrator", { orch_project_id = "p2" })
	check(#f.sent == 2 and #f.picks == 0, "an unsettled explicit startup cannot open another launch choice")
	for _, variant in { "uncertain", "identity_changed" } do
		local held = fixture(); held:create(); held:text("Held creation")
		held.creation_result = { request_id = held.events[1].value.request_id, ok = true,
			orch_session_id = "held-session", owner_id = "held-owner", generation = 1 }
		held:tick()
		if variant == "identity_changed" then held.valid = false end
		held.connection.done(held:context(), variant ~= "uncertain", "First-use result remains uncertain")
		held.connection.done(held:context(), true)
		held:tick()
		check(#held.controls == 0 and #held.sent == 0,
			"uncertain first use or changed native ownership never admits, and a late success cannot revive the stopped Create")
	end
	for _, boundary in { "same", "changed", "refused" } do
		local early = fixture(); early:create(); early:text("Delayed container")
		early.creation_result = { request_id = early.events[1].value.request_id, ok = true,
			orch_session_id = "delayed-session", owner_id = "delayed-owner", generation = 1 }
		early:tick(); early.connection.done(early:context(), true)
		early.data.session_control = { admitted = true }; early:tick()
		early.decision_result = { request_id = early.decision.request_id, decision_context = "delayed-project" }; early:tick()
		early.data.command_result = { request_id = "unrelated-housekeeping", ok = true }
		early:start("start_orchestrator"); early:start("start_orchestrator")
		check(#early.picks == 0 and #early.sent == 1 and early.ui.runnable(42),
			"a premature Start retains only one unissued choice on the exact initial project job: " .. boundary)
		early.conversation_result = { source_nonce = early.origin.alias_nonce, orch_session_id = early.origin.logical_session_id,
			creation_request_id = early.events[1].value.request_id,
			result = { request_id = early.sent[1].request_id, command = "new_project", ok = boundary ~= "refused",
				code = if boundary == "refused" then "project_refused" else "project_created", orch_project_id = "p1" } }
		if boundary == "changed" then early.valid = false; early:tick(); early.valid = true end
		early:tick(); early:tick()
		check(#early.sent == 1 and #early.picks == 0 and (early.agent_picker ~= nil) == (boundary == "same"),
			"only the matching successful result in the unchanged scope continues to that first project's agent choice once: " .. boundary)
		check(not early.ui.runnable(42), "the settled initial job cannot keep an idle helper or a second creation alive: " .. boundary)
		if boundary ~= "same" then
			early:start("start_orchestrator")
			check(#early.picks == 0 and early.agent_picker ~= nil and #early.sent == 1,
				"changed/refused initial setup needs a fresh explicit choice and never replays an effect: " .. boundary)
		end
	end
	local custom = fixture(); custom:create("custom"); custom:text("Custom desk")
	custom.creation_result = { request_id = custom.events[1].value.request_id, ok = true, orch_session_id = "custom-session", owner_id = "custom-owner", generation = 1 }
	custom:tick(); custom.connection.done(custom:context(), true)
	custom.data.session_control = { admitted = true }; custom:tick()
	custom.decision_result = { request_id = custom.decision.request_id, decision_context = "custom-project" }; custom:tick()
	custom.conversation_result = { source_nonce = custom.origin.alias_nonce, orch_session_id = custom.origin.logical_session_id,
		result = { request_id = custom.sent[1].request_id, command = "new_project", ok = true, orch_project_id = "p2" } }
	custom.data.command_result = { request_id = "other-housekeeping", ok = true }
	custom:tick()
	check(#custom.sent == 1 and custom.sent[1].command == "new_project"
		and custom.controls[2] == "settings" and custom.agent_picker == nil and #custom.picks == 0,
		"Custom's exact creation receipt automatically opens its instance settings continuation without another human click")
	check(not custom.ui.runnable(42), "Custom's completed project and settings handoff leave no pending creation job")
	local cancelled = fixture(); cancelled.ui.create(cancelled:context()); cancelled:tick(); cancelled:tick()
	local choice = table.remove(cancelled.picks, 1); assert(choice); choice.callback(nil, nil, cancelled:context())
	cancelled:tick()
	check(#cancelled.events == 0 and #cancelled.prompts == 0 and #cancelled.sent == 0,
		"leaving the default/custom choice creates no container, project or agent")
	check(not cancelled.ui.runnable(42), "cancelling the settings choice clears runnable creation state")
	cancelled.ui.create(cancelled:context(), 42); cancelled:tick(); cancelled:tick()
	check(#cancelled.picks == 1 and not cancelled.ui.runnable(42),
		"a second explicit creation reaches its own settings choice without a stranded earlier draft")
	local second_choice = table.remove(cancelled.picks, 1); second_choice.callback(nil, nil, cancelled:context())
	local incomplete = fixture(); incomplete.setup_ok = false; incomplete.ui.create(incomplete:context()); incomplete:tick(); incomplete:tick()
	check(#incomplete.events == 0 and #incomplete.sent == 0 and #incomplete.prompts == 0 and #incomplete.picks == 0,
		"incomplete required setup blocks settings navigation, naming, creation and agent launch")
	incomplete.form.done(incomplete:context(), nil, "cancel")
	check(incomplete.form == nil and #incomplete.events == 0, "Back from incomplete setup closes its owned form without creating or launching anything")
end
if section == nil or section == "presentation" then
	local chunk = assert(loadstring(runtime.fs.read(root .. "/tests/dispatch.luau"), "conversation-view-fixture"))
	setfenv(chunk, setmetatable({}, { __index = environment }))
	local shared = chunk(root, "fixture")
	local f = shared.fixture(); f:accepted(false)
	local projection = shared.state.project(f.authority.registry)
	projection.dispatch = shared.dispatch.project(f.authority.registry, f.origin.logical_session_id, f.origin.alias_nonce)
	local views = shared.load("views")
	local view = { pane = 42, alias_nonce = f.origin.alias_nonce, orch_session_id = f.origin.logical_session_id, action_serial = 0 }
	view.conversation_result = { source_nonce = view.alias_nonce, orch_session_id = view.orch_session_id, creation_request_id = "view-creation",
		result = { request_id = "retained-project-view-result", command = "new_project", ok = true, orch_project_id = "p2" } }
	local function styles(node, tone)
		if type(node) ~= "table" or (node.p and node.p.hidden) then return 0 end
		local total = if type(node.t) == "string" and type(node.s) == "string" and node.s:find(tone, 1, true) then 1 else 0
		for _, value in node do if type(value) == "table" then total += styles(value, tone) end end
		return total
	end
	local baseline = views.render(view, projection, "ready")
	local function receipt_node(node)
		if node.p and node.p.role == "orchplus.conversation.result" then return node end
		for _, child in node.c or {} do local found = receipt_node(child); if found then return found end end
		return nil
	end
	local node = receipt_node(baseline)
	check(node ~= nil and node.p.hidden == true, "the exact composer receipt is projected only through its hidden native node")
	local span = node.p.spans[1]
	check(equal(runtime.json.decode(if type(span) == "string" then span else span.t), view.conversation_result),
		"the native receipt node preserves source, logical session, command and exact result identity")
	local initializing = shared.clone(projection)
	initializing.dispatch.projects, initializing.dispatch.workers = {}, {}
	initializing.dispatch.workflow.projects, initializing.dispatch.workflow.workers = {}, {}
	local initial_view = { pane = view.pane, alias_nonce = view.alias_nonce, orch_session_id = view.orch_session_id, action_serial = 0,
		orchestration_result = { ok = true, orch_session_id = view.orch_session_id, request_id = "view-creation" } }
	local function offers(command)
		for _, action in initial_view.actions do if action.request and action.request.command == command then return true end end
		return false
	end
	views.render(initial_view, initializing, "ready")
	check(not offers("start_orchestrator") and not offers("new_conversation") and not offers("attach_conversation"),
		"admission alone cannot expose startup controls before the initial container project completes")
	initializing.dispatch.projects = shared.clone(projection.dispatch.projects)
	views.render(initial_view, initializing, "ready")
	check(not offers("start_orchestrator"), "a visible logical project alone is not the source-bound initial result publication")
	initial_view.conversation_result = shared.clone(view.conversation_result)
	views.render(initial_view, initializing, "ready")
	check(offers("start_orchestrator") and offers("new_conversation") and offers("attach_conversation"),
		"the actual project/result presentation exposes the first meaningful startup choices without another settling click")
	initial_view.conversation_result = { source_nonce = view.alias_nonce, orch_session_id = view.orch_session_id,
		result = { request_id = "later-project-operation", command = "project_start", ok = true } }
	views.render(initial_view, initializing, "ready")
	check(offers("start_orchestrator"), "a later unrelated completion cannot re-hide established startup choices")
	initial_view.orchestration_result.request_id = "another-creation"
	initial_view.conversation_result = shared.clone(view.conversation_result)
	views.render(initial_view, initializing, "ready")
	check(not offers("start_orchestrator"), "a previous creation's result cannot authorize readiness for another creation token")
	initializing.dispatch.projects, initial_view.conversation_result, initial_view.orchestration_result = {}, nil, nil
	views.render(initial_view, initializing, "ready")
	check(offers("start_orchestrator"), "an existing empty orchestration is not mistaken for this pane's in-progress creation")
	local green, errors = styles(baseline, "success"), styles(baseline, "error")
	for _, code in { "catalog_queued", "attachment_queued", "enrolment_queued", "task_held", "task_gated", "pending", "project_start_pending", "project_start_retry_queued", "project_start_inspection" } do
		view.dispatch_command_result = { ok = true, code = code }
		local rendered = views.render(view, projection, "ready")
		check(styles(rendered, "success") == green and styles(rendered, "error") == errors,
			"queued and pending outcomes never gain success/error styling: " .. code)
	end
	for _, code in { "effect_uncertain", "bridge_rejected", "transport_backpressure", "project_start_delivery_failed" } do
		view.dispatch_command_result = { ok = true, code = code }
		local rendered = views.render(view, projection, "ready")
		check(styles(rendered, "success") == green and styles(rendered, "error") > errors,
			"a retained failure is an error even when its transport committed: " .. code)
	end
	do
		local function visible_texts(node, out)
			out = out or {}
			if type(node) ~= "table" or (node.p and node.p.hidden) then return out end
			if type(node.t) == "string" then out[node.t] = true end
			for _, value in node do if type(value) == "table" then visible_texts(value, out) end end
			return out
		end
		view.dispatch_command_result, view.notice = nil, nil
		local plain = visible_texts(views.render(view, projection, "ready"))
		do
			local staged = shared.clone(projection); local project_id = next(staged.dispatch.projects)
			local project = staged.dispatch.projects[project_id]
			project.status, project.started = "ACTIVE", false
			project.start = { start_id = "retained-start", project_revision = project.revision, action_id = "typed-start-action",
				action_revision = 1, decision_context = "original-context", state = "publishing",
				source = { kind = "policy", rule = "auto_start_projects", policy_revision = string.rep("a", 64) } }
			view.orch_project_id = project_id
			local function status_node(node)
				if type(node) ~= "table" then return nil end
				if node.p and node.p.key == "project-start-status-" .. project_id and node.p.role == "orchplus.project.start" then return node end
				for _, child in node.c or {} do local found = status_node(child); if found then return found end end
				return nil
			end
			for _, state in { "publishing", "queued", "delivered", "failed", "claimed" } do
				project.start.state = state
				project.start.failure = if state == "failed" then { code = "uncertain", message = "Original delivery is uncertain.", retryable = false } else nil
				local tree = views.render(view, staged, "ready"); local rendered, status = visible_texts(tree), status_node(tree); local scoped
				for _, action in view.actions do if action.request and action.request.command == "project_start_retry" then scoped = action.request end end
				check(rendered.ACTIVE and (if state == "claimed" then scoped == nil else scoped and scoped.start_id == "retained-start"),
					"native conversational ACTIVE stays separate from each durable START state: " .. state)
				check(status and status.p.state == state and status.p.source == "policy"
					and styles(status, "error") == (if state == "failed" then 1 else 0),
					"the specific project status preserves policy provenance and distinguishes failure from neutral waiting: " .. state)
			end
			project.start.state = "failed"; project.start.failure = { code = "refused", message = "START_TEST_TECHNICAL_DETAIL", retryable = true }
			local retriable = views.render(view, staged, "ready"); local retry
			for _, action in view.actions do if action.request and action.request.command == "project_start_retry" then retry = action.request end end
			check(retry and retry.start_id == project.start.start_id and retry.decision_context == project.start.decision_context,
				"retrying a definite refusal retains the exact original START identity")
			check(not visible_texts(retriable).START_TEST_TECHNICAL_DETAIL, "normal project status does not expose raw host diagnostics")
			view.advanced_open = true
			check(visible_texts(views.render(view, staged, "ready")).START_TEST_TECHNICAL_DETAIL, "Advanced retains the original host diagnostic")
			view.advanced_open = nil
			project.start.closed, project.start.restartable = true, true
			views.render(view, staged, "ready"); local fresh, old_retry
			for _, action in view.actions do
				if action.request and action.request.command == "project_start" then fresh = action.request end
				if action.request and action.request.command == "project_start_retry" then old_retry = action.request end
			end
			check(fresh and fresh.project_revision == project.revision and fresh.decision_context == project.decision_context and not old_retry,
				"a terminal stale START offers fresh current-project approval, never original-delivery Retry")
			local worker_id = next(staged.dispatch.workers); local worker = staged.dispatch.workers[worker_id]
			worker.coordinator_owner_id, worker.activation_issued = "start-retirement-owner", true
			worker.retirement_requested, worker.start_retirement_requested, worker.start_retirement_ready = false, false, true
			view.advanced_open = true
			views.render(view, staged, "ready"); local withdrawal
			for _, action in view.actions do if action.request and action.request.command == "withdraw_start_retire" then withdrawal = action.request end end
			check(withdrawal and withdrawal.worker_id == worker_id, "only the eligible exact coordinator receives the explicit START-withdrawal retirement action")
			worker.start_retirement_ready = false
			views.render(view, staged, "ready"); local unexpected
			for _, action in view.actions do if action.request and action.request.command == "withdraw_start_retire" then unexpected = action.request end end
			check(unexpected == nil, "unsafe or unsettled coordinators never offer the withdrawal action")
			worker.start_retirement_ready, worker.start_retirement_requested, worker.retirement_requested = true, true, true
			views.render(view, staged, "ready"); unexpected = nil
			for _, action in view.actions do if action.request and table.find({ "withdraw_start_retire", "retire" }, action.request.command) then unexpected = action.request end end
			check(unexpected == nil, "a recorded withdrawal cannot offer a new retirement intent")
			view.advanced_open = nil
			view.orch_project_id = nil
		end
		view.dispatch_command_result = { ok = true, code = "catalog_queued", command = "catalog" }
		local loading = views.render(view, projection, "ready")
		check(styles(loading, "info") == styles(baseline, "info"), "loading uses default neutral text, not a status color")
		local progress = visible_texts(loading)
		view.notice = { message = "Catalog outcome", level = "error", context = "catalog",
			code = "catalog_unconfirmed", detail = "Retained diagnostic" }
		local failed = views.render(view, projection, "ready")
		local visible = visible_texts(failed)
		check(visible["Catalog outcome"] and not visible["Retained diagnostic"] and styles(failed, "error") > errors,
			"human catalog failure is red while protocol diagnostic stays out of normal presentation")
		for message in progress do if not plain[message] then
			check(not visible[message], "catalog failure supersedes its stale progress presentation")
		end end
		local checks = 0
		for _, action in view.actions do if action.request and action.request.command == "check_connection" then
			checks += 1
			check(action.orch_session_id == view.orch_session_id and action.request.source_nonce == view.alias_nonce,
				"connection check captures this exact orchestration and native source")
		end end
		check(checks == 1, "a catalog failure offers one scoped connection observation")
		for _, level in { "info", "success" } do
			view.notice = { message = "Catalog outcome", level = level, context = "catalog", code = "catalog_checked" }
			local updated = views.render(view, projection, "ready")
			check(styles(updated, "error") == errors and styles(updated, "success") == green + (if level == "success" then 1 else 0),
				"a later same-message outcome owns its severity independently: " .. level)
		end
		view.notice = { message = "Catalog outcome", level = "error", context = "catalog",
			code = "catalog_unconfirmed", detail = "Retained diagnostic" }
		view.advanced_open = true
		check(visible_texts(views.render(view, projection, "ready"))["Retained diagnostic"],
			"Advanced exposes retained technical detail without substituting it for the human outcome")
		view.advanced_open, view.notice = nil, nil
		view.dispatch_command_result = { ok = true, code = "policy_updated" }
		check(styles(views.render(view, projection, "ready"), "success") > green, "confirmed settings saves remain success after an error")
	end
	local summary = "observed mailbox count summary"
	view.dispatch_command_result = { ok = true, code = "cleanup_summary", message = summary }
	local function contains(node)
		if type(node) ~= "table" or (node.p and node.p.hidden) then return false end
		if node.t == summary then return true end
		for _, value in node do if type(value) == "table" and contains(value) then return true end end
		return false
	end
	local summary_view = views.render(view, projection, "ready")
	check(contains(summary_view) and styles(summary_view, "success") == green,
		"observed housekeeping counts stay informational and cannot become a generic acknowledgement of an unrelated click")
	view.dispatch_command_result = nil
	local worker = projection.dispatch.workflow.workers[1]
	worker.role, worker.phase = "coordinator", "awaiting_acceptance"
	views.render(view, projection, "ready")
	local function start_offered()
		for _, action in view.actions do
			if action.request and action.request.command == "start_orchestrator" then return true end
		end
		return false
	end
	check(not start_offered(), "an existing pending coordinator prevents another startup before activation")
	local lifecycle = projection.dispatch.workers[worker.worker_id]
	lifecycle.mailbox_status = "claimed"
	views.render(view, projection, "ready")
	check(not start_offered(), "pending retirement cannot offer a replacement coordinator")
	lifecycle.mailbox_status = "retired"
	views.render(view, projection, "ready")
	check(start_offered(), "confirmed retirement exposes the replacement start without requiring another queue first")
	projection.dispatch.workers[worker.worker_id] = nil
	views.render(view, projection, "ready")
	check(not start_offered(), "missing lifecycle evidence cannot enable duplicate coordinator startup")
end
if section == nil or section == "project_choice" then
	local function prompted(f) return #f.picks == 1 and f.picks[1].options.placeholder == "Choose a project" end
	local zero = fixture(); zero.projects = {}
	zero:start("new_conversation")
	check(#zero.picks == 0 and #zero.prompts == 1 and zero.prompts[1].options.placeholder == "New project name",
		"no project goes straight to the New-project flow without a picker")
	zero:text("Fresh start")
	check(zero.decision ~= nil and zero.decision.command == "new_project" and zero.decision.fields.name == "Fresh start",
		"the New-project flow from the empty case is unchanged: same decision for the same command and fields")
	local one = fixture(); one:start("new_conversation")
	check(#one.picks == 0 and #one.prompts == 0 and one.agent_picker ~= nil, "exactly one unfinished project is used without asking")
	local attach = fixture(); attach:start("attach_conversation"); attach:choose("pane", 51)
	check(#attach.picks == 0 and attach.decision ~= nil and attach.decision.fields.orch_project_id == "p1",
		"attach also uses the only unfinished project without asking")
	local finished = fixture(); finished.projects.p0 = { orch_project_id = "p0", name = "Old", revision = 1, finished = true, associations = {} }
	finished:start("new_conversation")
	check(#finished.picks == 0 and finished.agent_picker ~= nil, "finished projects do not count as a choice")
	local preferred = fixture(); preferred:another_project()
	preferred:start("new_conversation", { orch_project_id = "p0" })
	check(#preferred.picks == 0 and preferred.agent_picker ~= nil, "a preferred unfinished project is used without asking, even beside others")
	local stale = fixture(); stale:another_project()
	stale:start("new_conversation", { orch_project_id = "gone" })
	check(prompted(stale), "a preferred project that is not unfinished falls back to the picker")
	local two = fixture(); two:another_project()
	two:start("new_conversation")
	check(prompted(two), "two unfinished projects prompt as before")
	local menu_choice = fixture(); menu_choice:another_project()
	menu_choice:start("project_menu", { orch_project_id = "p1" }); menu_choice:choose("command", "new_conversation")
	check(#menu_choice.picks == 0 and menu_choice.agent_picker ~= nil, "New Agent Session from a project menu uses that project")
	local reach = fixture()
	reach:start("project_menu", { orch_project_id = "p1" }); reach:choose("label", "Start in another project…")
	check(prompted(reach), "the project menu still reaches the picker when only one project exists")
end
return string.format("conversation_ui/%s: %d checks", section or "all", checks)
