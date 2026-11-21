-- Optional readiness consent and lifecycle boundaries, without launching a provider.
local root = ...
local chunk = assert(loadstring(tern.fs.read(root .. "/readiness_window.luau"), "readiness-window"))
local module = chunk()
local events, toasts, picks = {}, {}, {}
local data = { source_nonce = "view", authority_namespace = "readiness-authority", authority_revision = 12,
	setup = { state = "completed" }, installation_defaults = { revision = 7, builder_record = "builder", policy = { merge_actor_mode = "selected_record", release_manager_record = "release" } } }
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
assert(event.expected_config_revision == 7 and event.readiness.config_revision == 7
	and event.authority_namespace == "readiness-authority" and event.expected_revision == 12,
	"readiness independently fences tested configuration and authority namespace/revision")
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

-- Exercise the real readiness state machine; only native I/O endpoints are replaced.
local runtime, environment = tern, getfenv()
local checks = 8
local function check(ok, message) assert(ok, message); checks += 1 end
-- Drive the real readiness state machine; only native process/UI endpoints are fixtures.
local function exercise(project_snapshot)
	local f = { policy_revision = 4, events = {}, notices = {}, processes = {}, queued = {}, commands = {}, serial = 0, clock = 1000 }
	local defaults = { require_code_review = true, merge_actor_mode = "selected_record", release_manager_record = "release" }
	f.data = { source_nonce = "exercise-view", authority_namespace = "exercise-authority", authority_revision = 10, setup = { state = "completed" },
		installation_defaults = { revision = 7, builder_record = "builder", policy = defaults } }
	f.origin = { logical_session_id = "session-exercise" }
	f.policy = defaults
	local fake = table.clone(runtime)
	fake.now = function() return f.clock end
	fake.plugin = { data = "/fixture/plugin-data" }
	fake.fs = { mkdir = function() error("readiness window must not create a desktop checkout") end }
	fake.process = { run = function() error("readiness window must not execute Git on the desktop") end }
	local script = assert(loadstring(runtime.fs.read(root .. "/readiness_window.luau"), "readiness-exercise"))
	setfenv(script, setmetatable({ tern = fake }, { __index = environment }))
	local cx = { session = {}, hosts = { current = function() return { kind = if f.remote then "remote" else "local" } end } }
	function cx:toast(_, _, message) table.insert(f.notices, message) end
	function cx:pick(options) f.options = options; return { next = function(_, callback) f.answer = callback end } end
	function cx.session:event(_, event)
		local request = runtime.json.decode(event.value); table.insert(f.events, request)
		if event.act == "setup-readiness-prepare" or event.act == "setup-readiness-verify" then
			table.insert(f.processes, { act = event.act, request = request })
		end
	end
	local function catalog()
		return { revision = 3, records = {
			{ id = "builder", revision = 2, enabled = true, eligible = true, capabilities = if f.worker_merge then { "check-runner-v1", "release-manager-v1" } else { "check-runner-v1" }, cwd = "/configured/not-the-task", placement = "split" },
			{ id = "release", enabled = true, eligible = not f.signer_unavailable, capabilities = { "release-manager-v1" } },
		} }
	end
	f.ui = script().new({
		id = function() f.serial += 1; return "exercise-" .. f.serial end,
		setup = function() return f.data end, origin = function() return f.origin end,
		current = function() return true end, consent_current = function() return true end,
		same = function(a, b) return runtime.json.encode(a) == runtime.json.encode(b) end,
		flow = function() return { policy_revision = f.policy_revision, policy = f.policy } end,
		catalog = function(_, _, _, done) f.catalog_done = done end,
		snapshot = function() return if f.snapshot and project_snapshot then project_snapshot(f.snapshot) else f.snapshot end,
		observation = function() return { catalog = catalog(), landings = f.landings or {} } end,
		command = function(_, _, _, command, fields)
			local request = "command-" .. tostring(#f.commands + 1)
			table.insert(f.commands, { command = command, fields = fields, request_id = request }); return request
		end,
		decision = function(_, _, _, command, fields)
			f.serial += 1; f.decision = { request_id = "decision-" .. f.serial, command = command, fields = fields }
			return f.decision.request_id
		end,
		decision_result = function() return f.decision_result end,
		project_context = function(_, _, _, id)
			assert(id == "exercise-project")
			return { project_revision = #f.commands, decision_context = "exact-project-decision" }
		end,
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
		local operation = assert(self.processes[index])
		if operation.act == "setup-readiness-prepare" then
			self.path = "/fixture/execution-host/readiness-owned"
			self.data.setup_result = { request_id = operation.request.request_id, ok = true, repository = {
				cwd = self.path, repo_root = self.path, common_dir = self.path .. "/.git", head_revision = string.rep("a", 40), target_ref = "refs/heads/main" } }
		else self.data.setup_result = { request_id = operation.request.request_id, ok = true, readiness_passed = true } end
		self:tick()
	end
	function f:prepared()
		self:consent()
		self:complete(1)
		self.decision_result = { request_id = self.decision.request_id, decision_context = "exact-creation-decision" }
		self:tick()
		for index = 1, 3 do
			self.snapshot = { command_result = { request_id = self.commands[index].request_id, ok = true, orch_project_id = "exercise-project" },
				driver_result = { request_id = "unrelated-background-observation", ok = false } }
			self:tick()
			if index == 1 then
				self.decision_result = { request_id = self.decision.request_id, decision_context = "exact-repository-decision" }
				self:tick()
			end
		end
		if not self.hold_catalog then self.catalog_done(cx, catalog()) end
	end
	function f:land()
		self:prepared()
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
	f.data.authority_revision += 1
	f.answer(f.options.items[2], nil, f.cx)
	check(#f.events == 0 and #f.queued == 0, "unrelated authority changes during consent refuse instead of refreshing the mutation fence")
end
do
	local f = exercise()
	f.ui.start(f.cx, 1)
	f.data.authority_namespace = "replacement-authority"
	f.answer(f.options.items[1], nil, f.cx)
	check(#f.events == 0, "even a declined readiness intent cannot write into a replacement authority")
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
		"policy edits during asynchronous execution-host preparation stop before provider launch")
end
do
	local f = exercise(); f:land()
	check(#f.queued == 1 and #f.processes == 2, "readiness requests host readback only after its matching landed observation")
	f:restore_policy(); f:complete(2)
	check(f.events[#f.events].readiness.state == "unavailable", "away-and-back edits while Git readback is in flight cannot pass the original policy")
	f:tick(); f:complete(2)
	check(#f.queued == 1 and f.events[#f.events].readiness.state == "unavailable", "ended readiness never replays launch or a delayed success callback")
end
do
	local f = exercise(); f:land()
	f:restore_policy(); f:tick()
	local count = #f.events
	f:complete(2)
	check(#f.events == count and f.events[count].readiness.state == "unavailable", "tick detects temporary policy edits and late readback cannot overwrite its refusal")
end
for _, accepted in { true, false } do
	local f = exercise(); f:land(); f:complete(2)
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
do
	local f = exercise(); f:land()
	check(#f.commands == 3 and f.commands[1].command == "new_project" and f.commands[2].command == "project_repository"
		and f.commands[3].command == "project_start", "one consent drives verified project preparation in acknowledgement order")
	check(f.commands[2].fields.repository.cwd == f.path and f.commands[2].fields.repository.queue_route == "orch_queue"
		and f.commands[3].fields.decision_context == "exact-project-decision", "exercise binds host repository proof and exact project-start decision")
	check(f.queued[1].orch_project_id == "exercise-project" and f.queued[1].execution_cwd == f.path
		and f.queued[1].cwd == "/configured/not-the-task" and f.queued[1].placement == "split"
		and f.queued[1].presentation == "user_new_tab", "exercise preserves saved record fields separately from verified project cwd and new-tab intent")
end
do
	local f = exercise(); f.worker_merge = true; f.policy.merge_actor_mode = "worker"; f.policy.release_manager_record = ""
	f:land()
	check(#f.queued == 1 and f.queued[1].record_id == "builder", "same-worker merge exercise uses one existing capable builder without selecting a second release record")
	local missing = exercise(); missing.policy.merge_actor_mode = "worker"; missing.policy.release_manager_record = ""
	missing:prepared()
	check(#missing.queued == 0 and missing.events[#missing.events].readiness.state == "unavailable", "same-worker readiness requires actual managed merge capability on the builder")
end
for _, phase in { "creation", "repository" } do
	local f = exercise(); f:consent(); f:complete(1)
	if phase == "repository" then
		f.decision_result = { request_id = f.decision.request_id, decision_context = "exact-creation-decision" }; f:tick()
		f.snapshot = { command_result = { request_id = f.commands[1].request_id, ok = true, orch_project_id = "exercise-project" } }
		f:tick()
	end
	f.decision_result = { request_id = f.decision.request_id }; f:tick()
	check(#f.commands == (if phase == "creation" then 0 else 1) and #f.queued == 0 and f.events[#f.events].readiness.state == "unavailable",
		"changed " .. phase .. " decision stops readiness before its mutation or worker launch")
end
do
	local f = exercise(); f.policy.release_manager_record = ""
	f.ui.start(f.cx, 1)
	check(f.options == nil and #f.processes == 0 and #f.queued == 0 and f.data.setup.state == "completed",
		"research setup remains complete when optional landing exercise has no release manager")
	check(f.events[#f.events].readiness.state == "unavailable", "missing optional signer is persistent unavailability, not fake readiness")
end
do
	local f = exercise(); f.policy.paused = true; f.ui.start(f.cx, 1)
	check(#f.events == 0 and #f.processes == 0 and #f.commands == 0, "readiness never resumes a paused orchestration")
end
do
	local f = exercise(); f:consent()
	local probe = f.events[#f.events]
	f.data.setup_result = { request_id = probe.request_id, ok = false, code = "not_git" }; f:tick()
	check(#f.commands == 0 and #f.queued == 0 and f.events[#f.events].readiness.state == "unavailable",
		"failed host repository proof cannot create, start or queue exercise work")
	local count = #f.events; f:tick(); f:tick()
	check(#f.events == count, "failure result awaiting persistence is not repeatedly written")
end
do
	local f = exercise(); f.signer_unavailable = true; f:prepared(); f:tick()
	check(#f.queued == 0 and f.events[#f.events].readiness.state == "unavailable", "fresh catalog signer eligibility is checked before a real provider launch")
end
do
	local f = exercise(); f:consent(); f.clock += 900001; f:tick()
	check(f.events[#f.events].readiness.state == "unavailable", "elapsed observation without landing is unknown, never an invented provider failure")
	local count = #f.events; f.clock += 30001; f:tick(); f:tick()
	check(#f.events == count and #f.queued == 0 and f.notices[#f.notices]:find("unknown", 1, true) ~= nil,
		"missing final save acknowledgement is disclosed without resubmitting or relaunching")
end
do
	local f = exercise(); f.hold_catalog = true; f:prepared(); f:tick()
	check(#f.queued == 0, "a pre-existing cached catalog cannot count as completion of the fresh catalog request")
	f.catalog_done(f.cx, nil, "Agent catalog unavailable")
	check(#f.queued == 0 and f.events[#f.events].readiness.state == "unavailable", "catalog load refusal persists without provider launch")
	local remote = exercise(); remote.remote = true; remote:land(); remote:complete(2)
	check(remote.events[#remote.events].readiness.state == "passed" and remote.queued[1].execution_cwd == "/fixture/execution-host/readiness-owned",
		"attached remote uses the same consent, host-owned checkout and verified landing flow without a desktop filesystem assumption")
end
do
	-- Preparation can fail before any checkout path exists; reporting that must not itself throw.
	local f = exercise(); f:consent()
	local operation = assert(f.processes[1])
	f.data.setup_result = { request_id = operation.request.request_id, ok = false, code = "prepare_failed", message = "no repository" }
	check(pcall(f.tick, f), "a failed preparation is reported without throwing on the missing checkout path")
	local result = f.events[#f.events]
	check(result.readiness.state == "unavailable", "failed preparation persists an unavailable readiness result")
	f.data.setup_result = { request_id = result.request_id, ok = true }
	check(pcall(f.tick, f) and f.notices[#f.notices]:find("nil", 1, true) == nil
		and f.notices[#f.notices]:find("Disposable repository retained", 1, true) == nil, "no checkout path means no retained-repository sentence")
	local changed = exercise(); changed:consent()
	local prepare = assert(changed.processes[1])
	changed.data.installation_defaults.revision += 1
	changed.data.setup_result = { request_id = prepare.request.request_id, ok = false, code = "prepare_failed", message = "no repository" }
	check(pcall(changed.tick, changed) and changed.notices[#changed.notices]:find("not attached to newer defaults", 1, true) ~= nil,
		"a configuration change during failed preparation is reported without throwing")
end
-- SKILLS-221 R4: the host publishes the readiness outcome as its own receipt, so the shared result slot being replaced
-- (by a newer repository result, in either arrival order) cannot hide the refusal from the readiness caller.
-- Fails on the old code: the window read only the shared result slot, saw another request id and waited until timeout.
for _, replaced in { "newer_result", "other_refusal" } do
	local f = exercise(); f:consent()
	local operation = assert(f.processes[1])
	f.data.readiness_receipts = { [operation.request.request_id] = { request_id = operation.request.request_id, ok = false,
		code = "repository_probe_superseded", message = "A newer repository check replaced this one; it was not completed." } }
	f.data.setup_result = if replaced == "newer_result" then { request_id = "newer-probe", ok = true, code = "repository_verified" }
		else { request_id = "another-probe", ok = false, code = "repository_unavailable" }
	f:tick()
	check(#f.commands == 0 and #f.queued == 0 and f.events[#f.events].readiness.state == "unavailable"
		and f.events[#f.events].readiness.summary:find("newer repository check", 1, true) ~= nil,
		"a superseded readiness refusal is read from its own receipt when the shared result belongs to " .. replaced)
end
do
	local f = exercise(); f:consent()
	local operation = assert(f.processes[1])
	f.path = "/fixture/execution-host/readiness-owned"
	f.data.readiness_receipts = { [operation.request.request_id] = { request_id = operation.request.request_id, ok = true, repository = {
		cwd = f.path, repo_root = f.path, common_dir = f.path .. "/.git", head_revision = string.rep("a", 40), target_ref = "refs/heads/main" } } }
	f.data.setup_result = { request_id = "newer-probe", ok = true, code = "repository_verified" }
	f:tick()
	check(f.decision ~= nil and f.decision.command == "new_project", "a verified readiness receipt proceeds although the shared result was replaced")
end
return "readiness_ui: " .. tostring(checks) .. " checks"
