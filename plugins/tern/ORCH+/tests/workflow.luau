-- Workflow group (ORCH+ 0.4.0): pure importer and usage-delta contracts, plus cross-family review,
-- rework rounds, reviewer auto-finish and the Rule H landing proof (Checkpoint 3). Deterministic
-- reducer/host behavior; run sections separately.
-- `shared_api`: a caller loading these helpers (section "helpers") passes its already-loaded dispatch
-- fixture, so the fixture modules are compiled once per native slice budget, not twice.
local root, section, shared_api = ...
local runtime, environment = tern, getfenv()
local modules = {}
local function load(name)
	name = name:gsub("^%./", "")
	if modules[name] then return modules[name] end
	local chunk = assert(loadstring(runtime.fs.read(root .. "/" .. name .. ".luau"), name))
	setfenv(chunk, setmetatable({ require = load }, { __index = environment }))
	local value = chunk(); modules[name] = value; return value
end
local checks = 0
local function check(ok, message) assert(ok, message); checks += 1 end
local function lines_of(bytes)
	local out = {}
	for _, raw in bytes:split("\n") do table.insert(out, if raw:sub(-1) == "\r" then raw:sub(1, -2) else raw) end
	return out
end
local function same(a, b) return runtime.json.encode(a) == runtime.json.encode(b) end

-- Checkpoint 3 fixtures: the dispatch test fixture plus catalog records with declared provider
-- families (Claude → anthropic, Codex → openai; OMP has no family until the owner maps it).
local api = shared_api
local W = {}
-- The fixture runs in this group's environment (as tests/run.luau loads groups), so its tern.json calls are
-- the stepped runner's yield points and a long scenario spans many native slices.
function W.api()
	if not api then
		local chunk = assert(loadstring(runtime.fs.read(root .. "/tests/dispatch.luau"), "dispatch-fixture"))
		setfenv(chunk, setmetatable({}, { __index = environment }))
		api = chunk(root, "fixture")
	end
	return api
end
W.CAPS = { "report-files-v1", "native-ask-v1", "coordinator-control-v1", "project-start-v1", "check-runner-v1", "release-manager-v1" }
W.ROWS = { { "builder", "Claude" }, { "claude2", "Claude" }, { "codex", "Codex" }, { "kimi", "Kimi" }, { "omp", "omp" } }
function W.hx(name) return api.codec.sha256("revision:" .. name):sub(1, 40) end
function W.arr(t) return runtime.json.array(t or {}) end
function W.unit() return W.arr({ { check_id = "unit", argv = W.arr({ "luau", "tests/run.luau" }) } }) end
function W.worker(f, id) return f.authority.registry.dispatch.workers[id] end
function W.send(f, id, kind, payload, extra)
	local w = W.worker(f, id)
	return f:apply("intake", { worker_id = id, bytes = f:report(id, w.accepted_seq + 1, kind, payload, extra) })
end
function W.catalog(f, rows)
	local records = {}
	for _, row in rows or W.ROWS do
		table.insert(records, { id = row[1], revision = 0, provider = row[2], provider_family = ({ Claude = "anthropic", Codex = "openai", Kimi = "moonshot" })[row[2]], account_label = "configured, not verified", backend = "native-agent", enabled = true, eligible = true,
			capability_evidence = "configured_operator_attestation_not_runtime_proof", effective_identity = { provider = row[2], identity_status = "configured_not_verified" },
			capabilities = W.arr(W.CAPS), unsupported = W.arr(), cwd = "/fixture", placement = "split" })
	end
	local r = f:apply("catalog"); assert(r.ok, r.message)
	assert(f:finish(r.action_id, "catalog", { catalog_version = 2, setup = { schema = 1, state = "completed", config_revision = 0, readiness = { state = "not_run", config_revision = 0, summary = "" } }, namespace = "fixture-spawn", host_key = "fixture-host", config_revision = 0, revision = 0, records = W.arr(records) }).ok)
end
-- Model the actual project owner transaction. Native scenarios separately prove its Git probe.
function W.repository(f, common_dir, target, route, project_id, cwd)
	local registry = f.authority.registry
	local project = (registry.dispatch.projects or {})[project_id or f.default_project]
	if not project or project.logical_session_id ~= f.origin.logical_session_id or project.finished then
		f.default_project = f:project("Workflow fixture project", true)
		registry = f.authority.registry; project = registry.dispatch.projects[f.default_project]
	end
	if route == nil then
		for _, choice in registry.dispatch.repository_policies or {} do if choice.common_dir == common_dir and choice.target_ref == target then route = choice.queue_route end end
	end
	route = route or "orch_queue"; cwd = cwd or "/fixture/worktree"
	if project.repository and project.repository.common_dir == common_dir and project.repository.target_ref == target
		and project.repository.queue_route == route and project.repository.cwd == cwd then return end
	local saved = f:apply("project_repository", { orch_project_id = project.orch_project_id, project_revision = project.revision,
		repository = { cwd = cwd, repo_root = cwd, common_dir = common_dir,
			target_ref = target, head_revision = W.hx("configured-target"), queue_route = route } })
	assert(saved.ok, saved.message)
end
-- A fresh store with the family catalog and a Config v4 policy patch. The session's release manager
-- record defaults to "kimi" (Kimi: no other fixture role uses it); a patch may override it, "" = none.
-- The default clock is fixed: native runs are sliced across real seconds, so wall-clock time must not
-- move a fixture across launch/claim timeouts mid-section. Its epoch makes workflow ticks use the
-- same complete host-clock contract as dispatch commands.
function W.fixture(patch, clock)
	W.api(); local f = api.fixture(clock or function() return { now_ms = 1700000000000, mono_ms = 1000, epoch = "workflow-fixture-host" } end); W.catalog(f)
	local merged = { merge_actor_mode = "selected_record", release_manager_record = "kimi", preferred_worker_record = "builder", auto_approve_kinds = W.arr(), review_rounds = 2, concurrency_limit = 32 }
	for key, value in patch or {} do merged[key] = value end
	local saved = f:apply("policy", { policy = merged }); assert(saved.ok, saved.message)
	W.repository(f, "/fixture/repository/.git", "refs/heads/main", "orch_queue")
	return f
end
W.serial = 0
-- Provision → launch → ACCEPTED for a queued worker (its provision action id given); `caps` are the
-- provisioned capabilities (default W.CAPS).
function W.start(f, worker_id, action_id, caps)
	W.serial += 1
	assert(f:finish(action_id, "provisioned", { handle = "mailbox-cp3-" .. W.serial, binding_digest = string.rep("e", 64), capabilities = W.arr(caps or W.CAPS), limits = {},
		manifest_sha256 = W.worker(f, worker_id).manifest_sha256 }).ok)
	local w = W.worker(f, worker_id)
	local launched = f:finish(w.launch_action_id, "awaiting_acceptance", { pane_binding = { pane_id = tostring(9700 + W.serial), window_key = f.origin.window_key,
		window_epoch = f.origin.window_epoch, native_session_id = f.origin.native_session_id, window_host_id = f.origin.window_host_id } })
	assert(launched.ok, tern.json.encode({ result = launched, worker_id = worker_id, source = w.source, phase = w.phase, launch_gates = w.launch_gates }))
	local handover = if w.handover_id then { handover_id = w.handover_id, handover_token = w.handover_token } else nil
	assert(f:apply("intake", { worker_id = worker_id, bytes = f:report(worker_id, 1, "ACCEPTED", { assignment_sha256 = w.assignment_sha256 }, handover) }).ok)
	assert(f:finish(f:apply("poll", { worker_id = worker_id }).action_id, "published", {}).ok)
	assert(f:finish(f:apply("poll", { worker_id = worker_id }).action_id, "accepted", {}).ok)
	return worker_id
end
function W.builder(f, record, fields)
	local event = { record_id = record or "builder", record_revision = 0, catalog_revision = 0, prompt = "Implement the declared fixture task.", cwd = "/fixture",
		placement = "split", coordinator = false, checks = W.unit() }
	for key, value in fields or {} do event[key] = value end
	local queued = f:allow_shared_fixture(f:apply("queue", event)); assert(queued.ok and queued.action_id, queued.message)
	return W.start(f, queued.worker_id, queued.action_id)
end
function W.cp(cp_id, revision)
	return { checkpoint_id = cp_id, task_ref = "task:fixture", project_id = "project-one", worktree_ref = "/fixture/worktree", artifact_revision = W.hx(revision),
		completed = W.arr({ "Implemented the assigned change" }), remaining = W.arr(), holds = W.arr(),
		checks = W.arr({ { check_id = "unit", artifact_revision = W.hx(revision), outcome = "passed", evidence_ref = "unit:log" } }) }
end
-- Publish owed receipts and the cumulative receipt watermark of one worker before its 8-receipt
-- report lane fills; `full` also publishes owed replies and settles even a short lane.
function W.settle(f, id, full)
	local held = 0; for _ in W.worker(f, id).receipts do held += 1 end
	if not full and held < 5 then return end
	for _ = 1, 32 do
		local owed = false
		for _, receipt in W.worker(f, id).receipts do if receipt.publish then owed = true end end
		if full then for _, reply in W.worker(f, id).replies do if reply.part <= #reply.frames.chunks + 1 then owed = true end end end
		if not owed then break end
		local queued = f:apply("poll", { worker_id = id }); assert(queued.ok and queued.action_id, queued.message)
		local op = f:action(queued.action_id).request.op
		assert(f:finish(queued.action_id, if op == "mailbox_retire" then "compacted" elseif op == "mailbox_read" then "missing" else "published", {}).ok)
	end
	if next(W.worker(f, id).receipts) ~= nil then assert(f:watermark(id).ok) end
end
function W.checkout(f, id, revision, path)
	local result = W.send(f, id, "CHECKOUT", { worktree_path = path or "/fixture/worktree", common_dir = "/fixture/repository/.git",
		branch = "refs/heads/fixture-work", head = W.hx(revision), base = W.hx("base"), changed_files = W.arr(),
		changed_overflow = false, changed_total = 0, dirty = false })
	if result.ok then
		local shared = {}
		for _, gate in f.authority.registry.dispatch.gates do
			if gate.worker_id == id and gate.kind == "shared_checkout" and gate.phase == "pending" then table.insert(shared, { id = gate.id, revision = gate.revision }) end
		end
		for _, gate in shared do
			local acknowledged = f:apply("answer", { gate_id = gate.id, gate_revision = gate.revision, choice_id = "acknowledge",
				answer = "The fixture owner intentionally coordinates these shared-worktree edits." })
			assert(acknowledged.ok, acknowledged.message)
		end
	end
	return result
end
-- Checkpoint (and optionally a helper check result) then REVIEW_READY for that revision.
function W.ready(f, id, cp_id, revision, exit_code)
	W.settle(f, id, true)
	assert(W.checkout(f, id, revision).ok)
	local sent = W.send(f, id, "CHECKPOINT", W.cp(cp_id, revision)); assert(sent.ok, sent.message)
	if exit_code ~= nil then
		sent = W.send(f, id, "CHECK_RESULT", { check_id = "unit", argv_sha256 = api.codec.sha256("argv"), exit_code = exit_code, output_sha256 = api.codec.sha256("check output"),
			head = W.hx(revision), ran_at_ms = 1 }); assert(sent.ok, sent.message)
	end
	return W.send(f, id, "REVIEW_READY", { checkpoint_id = cp_id, artifact_revision = W.hx(revision) })
end
function W.reviews(f, builder_id)
	local found = {}
	for _, r in f.authority.registry.dispatch.reviews or {} do
		if builder_id == nil or r.builder_worker_id == builder_id then table.insert(found, r) end
	end
	local function serial(r) return tonumber(r.review_id:match("(%d+)$")) or 0 end
	table.sort(found, function(a, b) return serial(a) < serial(b) end)
	return found
end
function W.review(f, builder_id) local all = W.reviews(f, builder_id); return all[#all] end
function W.gates(f, kind, phase_open)
	local found = {}
	for _, g in f.authority.registry.dispatch.gates or {} do
		local open = not table.find({ "resolved", "cancelled", "superseded" }, g.phase)
		if (kind == nil or g.kind == kind) and (phase_open == false or open) then table.insert(found, g) end
	end
	return found
end
function W.replies(f, id, kind)
	local found = {}
	for _, retained in W.worker(f, id).replies do
		local reply = api.codec.decode_reply(retained.bytes, W.worker(f, id))
		if kind == nil or reply.kind == kind then table.insert(found, { reply = reply, retained = retained }) end
	end
	table.sort(found, function(a, b) return a.reply.reply_seq < b.reply.reply_seq end)
	return found
end
-- The review's current reviewer: the bound worker, else the fresh queued reviewer for its open round.
function W.reviewer_of(f, r)
	local live = f.authority.registry.dispatch.reviews and f.authority.registry.dispatch.reviews[r.review_id] or r
	if live.reviewer_worker_id then return live.reviewer_worker_id end
	for key, w in f.authority.registry.dispatch.workers do
		if w.role == "reviewer" and w.review_id == r.review_id and w.finish == nil and w.phase ~= "accepted" then return key end
	end
	return nil
end
function W.provision_of(f, id)
	for key, a in f.authority.registry.dispatch.actions do
		if a.worker_id == id and a.request.op == "mailbox_provision" and a.phase == "ready" then return key end
	end
	return nil
end
-- Launch the queued reviewer of review r, deliver and acknowledge its review_request; returns reviewer id and the request.
function W.open(f, r)
	local id = assert(W.reviewer_of(f, r), "review has no reviewer worker")
	if W.worker(f, id).phase ~= "accepted" then W.start(f, id, (assert(W.provision_of(f, id), "reviewer provision missing"))) end
	W.settle(f, id, true)
	local issued = W.replies(f, id, "review_request")
	assert(#issued >= 1, "review_request missing")
	local entry = issued[#issued]
	local ack = W.send(f, id, "reply_ack", { message_id = entry.reply.message_id, reply_seq = entry.reply.reply_seq, reply_sha256 = api.codec.sha256(entry.retained.bytes),
		status = "recorded" }, { action_id = entry.reply.action_id, action_revision = entry.reply.action_revision })
	assert(ack.ok, ack.message)
	return id, entry.reply
end
function W.findings(n)
	local out = {}
	for index = 1, n or 0 do table.insert(out, { finding_id = "f" .. index, path = "src/feature.luau", line = index, summary = "Finding " .. index .. " tied to its line." }) end
	return W.arr(out)
end
function W.result(f, reviewer_id, request, outcome, findings, fields)
	local p = { review_id = request.payload.review_id, round = request.payload.round, artifact_revision = request.payload.artifact_revision, outcome = outcome or "approved",
		findings = findings or W.arr(), summary = "Answered the fixed judge question." }
	for key, value in fields or {} do p[key] = value end
	return W.send(f, reviewer_id, "REVIEW_RESULT", p, { action_id = request.action_id, action_revision = request.action_revision })
end
-- One whole review round: REVIEW_READY → reviewer → result. Returns the review record and reviewer id.
function W.round(f, builder_id, cp_id, revision, outcome, findings, exit_code)
	local ready = W.ready(f, builder_id, cp_id, revision, if exit_code == nil then 0 else exit_code); assert(ready.ok, ready.message)
	local r = assert(W.review(f, builder_id), "REVIEW_READY opened no review")
	local reviewer, request = W.open(f, r)
	local sent = W.result(f, reviewer, request, outcome, findings); assert(sent.ok, sent.message)
	W.rm(f)
	return api.clone(f.authority.registry.dispatch.reviews[r.review_id]), reviewer
end
function W.landing(f) return f.authority.registry.dispatch.landing end
function W.item(f, lid) return W.landing(f).items[lid] end
function W.request(f, id, cp_id, revision, target, head)
	W.settle(f, id)
	if not W.worker(f, id).checkout or W.worker(f, id).checkout.head ~= W.hx(revision) then
		local checkout = W.checkout(f, id, revision); assert(checkout.ok, checkout.message)
	end
	local requested_target = target or "refs/heads/main"
	local canonical_target = if requested_target:sub(1, 5) == "refs/" then requested_target else "refs/heads/" .. requested_target
	W.repository(f, W.worker(f, id).checkout.common_dir, canonical_target, nil, W.worker(f, id).orch_project_id)
	local sent = W.send(f, id, "LANDING_REQUEST", { checkpoint_id = cp_id, project_id = "project-one", repo_ref = "repo:fixture", target_ref = target or "refs/heads/main",
		target_revision = head or "head-0", source_ref = "refs/heads/" .. cp_id, source_revision = W.hx(revision) }); assert(sent.ok, sent.message)
	for key, candidate in W.landing(f).items do
		if candidate.work_id == W.worker(f, id).work_id and candidate.request.target_ref == (target or "refs/heads/main")
			and table.find({ "queued", "verifying", "ready", "blocked", "granted", "landing" }, candidate.status) then return key end
	end
	error("landing item missing")
end
-- Owner approval; a release manager ORCH+ queued for the now-grantable item is launched.
function W.approve(f, lid)
	local gate = f.authority.registry.dispatch.gates[W.item(f, lid).gate_id]
	local answered = f:apply("answer", { gate_id = gate.id, gate_revision = gate.revision, choice_id = "approve", answer = "Owner approves this exact landing request." })
	if answered.ok then W.rm(f) end
	return answered
end
-- Selected-record fixtures can launch a separate release-manager grant holder.
function W.rm_id(f)
	for key, w in f.authority.registry.dispatch.workers do if w.logical_session_id == f.origin.logical_session_id and w.role == "release_manager" and w.finish == nil and w.release == nil then return key end end
	return nil
end
-- Launch the release manager ORCH+ queued (if any); returns its worker ID.
function W.rm(f, caps)
	local id = W.rm_id(f)
	if id and W.worker(f, id).phase == "queued" then W.start(f, id, assert(W.provision_of(f, id), "release manager provision missing"), caps) end
	return id
end
function W.holder(f, lid) local it = W.item(f, lid); return it.holder and it.holder.worker_id end
function W.grant(f, lid) local it = W.item(f, lid); return it.grants[#it.grants] end
-- Acknowledge one retained delivery {message_id, reply_seq, bytes, action_id, action_revision} as `id`.
function W.ack(f, id, delivery)
	W.settle(f, id)
	return W.send(f, id, "reply_ack", { message_id = delivery.message_id, reply_seq = delivery.reply_seq, reply_sha256 = api.codec.sha256(delivery.bytes), status = "recorded" },
		{ action_id = delivery.action_id, action_revision = delivery.action_revision })
end
-- A LANDING_RESULT for the item's latest grant, sent by `id`.
function W.landing_result(f, id, lid, outcome, fields)
	local it, g = W.item(f, lid), W.grant(f, lid)
	local p = { landing_id = lid, grant_id = g.grant_id, project_id = it.request.project_id, repo_ref = it.request.repo_ref, target_ref = it.request.target_ref,
		target_revision = g.target_revision, source_revision = g.source_revision, outcome = outcome, evidence = W.arr({ "log:fixture" }) }
	for key, value in fields or {} do p[key] = value end
	W.settle(f, id)
	return W.send(f, id, "LANDING_RESULT", p, { action_id = g.action_id, action_revision = g.action_revision })
end
-- A proven, owner-approved request on `target`, granted to the configured exact actor.
function W.granted(f, cp_id, target)
	local b = W.builder(f); W.round(f, b, cp_id, "rev-" .. cp_id, "approved")
	local lid = W.request(f, b, cp_id, "rev-" .. cp_id, target); assert(W.approve(f, lid).ok); W.rm(f)
	assert(#W.item(f, lid).grants == 1, "fixture request was not granted: " .. tostring(W.item(f, lid).hold and W.item(f, lid).hold.code))
	return b, lid
end
-- The exact grant holder consumes the grant and reports it landed at `head`.
function W.land(f, lid, head)
	local rm = W.holder(f, lid)
	assert(W.ack(f, rm, W.grant(f, lid)).ok)
	local sent = W.landing_result(f, rm, lid, "landed", { result_revision = head or "head-1" }); assert(sent.ok, sent.message)
end
function W.deploy(f, lid)
	for _, dep in f.authority.registry.dispatch.deploys or {} do if dep.landing_id == lid then return dep end end
	return nil
end
function W.attempt(f, lid) local dep = W.deploy(f, lid); return dep and dep.attempts[#dep.attempts] end
-- The worker consumes every retained reply it was sent (keeps its 8-reply outbox from filling).
function W.drain(f, id)
	local owed = {}
	for _, entry in W.replies(f, id) do if not entry.retained.acknowledged then table.insert(owed, entry) end end
	for _, entry in owed do
		local sent = W.ack(f, id, { message_id = entry.reply.message_id, reply_seq = entry.reply.reply_seq, bytes = entry.retained.bytes,
			action_id = entry.reply.action_id, action_revision = entry.reply.action_revision }); assert(sent.ok, sent.message)
	end
end
-- A DEPLOY_RESULT for the deploy's latest attempt, sent by that attempt's exact holder.
function W.deploy_result(f, lid, outcome, fields, extra)
	local dep, a = W.deploy(f, lid), W.attempt(f, lid)
	local p = { deploy_id = dep.deploy_id, attempt_id = a.attempt_id, landing_id = lid, outcome = outcome, revision = dep.revision, evidence = W.arr({ "deploy:log" }) }
	for key, value in fields or {} do p[key] = value end
	W.settle(f, a.worker_id)
	return W.send(f, a.worker_id, "DEPLOY_RESULT", p, extra or { action_id = a.action_id, action_revision = a.action_revision })
end
-- Every exact issued actor stays bound to its grant, independent of later policy edits.
function W.sweep(f)
	local d = f.authority.registry.dispatch
	for wid, w in d.workers do
		if w.role ~= "release_manager" and w.role ~= "builder" then
			for _, retained in w.replies do
				local reply = not retained.legacy and api.codec.decode_reply(retained.bytes, w)
				assert(not reply or (reply.kind ~= "landing_grant" and reply.kind ~= "deploy_grant"), "a non-release-manager worker holds a grant reply: " .. wid)
			end
		end
	end
	for lid, it in (d.landing or {}).items or {} do
		for _, g in it.grants do
			if not g.legacy then
				local h, b = d.workers[g.worker_id], d.workers[it.worker_id]
				local r = it.proof and (d.reviews or {})[it.proof.review_id]
				local builder_record = if b then b.record_id elseif r then r.builder_record_id else nil
				assert(b or table.find({ "landed", "rejected", "cancelled" }, it.status), "an open landing lost its builder: " .. lid)
				assert(h and builder_record ~= nil and (h.role == "release_manager" and h.record_id ~= builder_record or h.role == "builder" and h.worker_id == it.worker_id),
					"a landing grant addressed to neither the selected release actor nor the exact builder: " .. lid)
				assert(r == nil or r.reviewer_record_id ~= h.record_id, "a landing grant held by the reviewer record: " .. lid)
			end
		end
	end
	for did, dep in d.deploys or {} do
		for _, a in dep.attempts do
			local h, it = d.workers[a.worker_id], d.landing.items[dep.landing_id]
			assert(h and (h.role == "release_manager" or (h.role == "builder" and it and h.worker_id == it.worker_id)), "a deploy grant addressed to an unrelated actor: " .. did)
		end
	end
	checks += 1
end
function W.restores(f) W.sweep(f); return api.state.rehydrate(api.clone(f.authority.registry)) ~= nil end
-- Invariant sweep: no landing grant exists without Rule H holding for its exact revision.
function W.rule_h(f)
	local d = f.authority.registry.dispatch
	for lid, it in (d.landing or {}).items or {} do
		if #it.grants > 0 and not it.legacy then
			local p, b = it.proof, d.workers[it.worker_id]
			assert(p ~= nil and p.artifact_revision == it.request.source_revision, "grant without proof for its revision: " .. lid)
			if p.mode == "review_disabled" then
				assert(p.review_id == nil, "review-disabled proof invents a review: " .. lid)
			else
				local r = assert((d.reviews or {})[p.review_id], "grant proof names no reviewer-worker review: " .. lid)
				assert(r.status == "approved" and r.artifact_revision == p.artifact_revision and r.builder_worker_id == it.worker_id, "grant proof review not approved for the revision: " .. lid)
				assert(r.reviewer_worker_id ~= nil and r.reviewer_worker_id ~= it.worker_id and r.reviewer_record_id ~= b.record_id, "grant proof reviewed by its builder: " .. lid)
				if p.mode == "cross_family_review" then
					assert(r.builder_family ~= nil and r.reviewer_family ~= nil and r.builder_family ~= r.reviewer_family, "cross-family proof without different declared families: " .. lid)
				else assert(p.mode == "helper_checks", "unknown reviewed proof mode: " .. lid) end
			end
			for _, c in b.checks do
				local res = b.check_results and b.check_results[c.check_id]
				assert(res and res.exit_code == 0 and res.head == p.artifact_revision, "grant without a passing declared check at the revision: " .. lid)
			end
		end
	end
	checks += 1
end

if section == nil or section == "plan_import" then
	-- Scope globs: unsupported syntax must never widen what a worker may change.
	local rules = load("workflow_rules")
	check(rules.path_in_scope("src/**", "src/api/a.luau") and rules.path_in_scope("src/*.luau", "src/a.luau")
		and rules.path_in_scope("src", "src/a.luau") and not rules.path_in_scope("src/*.luau", "src/secrets.env"),
		"supported scope globs and literal ancestors still match exactly")
	check(not rules.path_in_scope("src/{api,ui}/**", "src/secrets.env"), "a brace glob does not widen scope to its literal prefix")
	check(not rules.path_in_scope("src/[ab]*", "src/secrets.env"), "a character-class glob does not widen scope to its literal prefix")
	check(not rules.path_in_scope(string.rep("*/", 9) .. "x", "a/b/c/d/e/f/g/h/i/x"), "a glob with more than eight wildcards matches nothing instead of its prefix")
	local began = os.clock()
	local pathological = not rules.path_in_scope("*a*a*a*a*a*a*a*b", string.rep("a", 200))
	check(pathological and os.clock() - began < 1, "a pathological glob against a long name settles in bounded time with the same answer")
	check(rules.path_in_scope("*a*a*a*a*a*a*a*b", string.rep("a", 200) .. "b") and rules.path_in_scope("src/**/x.luau", "src/x.luau")
		and rules.path_in_scope("src/**/x.luau", "src/a/b/x.luau") and not rules.path_in_scope("src/*/x.luau", "src/a/b/x.luau"),
		"memoized matching keeps `**` and `*` segment semantics")
end
if section == nil or section == "plan_import" then
	local importer, codec = load("plan_import"), load("wire/codec")
	local function task_of(plan, id)
		for _, cp in plan.checkpoints do for _, t in cp.tasks do if t.id == id then return t end end end
		return nil
	end
	local function has(list, name) return table.find(list, name) ~= nil end
	local function argv_list(t) local out = {} for _, c in t.checks do table.insert(out, table.concat(c.argv, " ")) end return out end
	local function action_lines(bytes)
		local found, targets = {}, {}
		for n, line in lines_of(bytes) do
			local target = importer.action_target(line)
			if target then table.insert(found, n); table.insert(targets, target) end
		end
		return found, targets
	end
	local function task_headers(plan)
		local n = 0
		for _, cp in plan.checkpoints do for _, t in cp.tasks do
			for _, line in lines_of(t.text) do if importer.action_target(line) then n += 1 end end
		end end
		return n
	end
	local function plan(lines) return table.concat(lines, "\n") .. "\n" end

	-- Synthetic fixtures (tests/fixtures/, neutral names only; no real hosts, people or paths):
	--   plan-modern.md  current /glitch-plan conventions: 8 checkpoints, **INDEPENDENT** / SEQUENTIAL: markers, prose and
	--                   multi-item VALIDATE lines, home: workspace:demo with one file outside it, a fenced header, ## Progress.
	--                   sha256 232be2836c9cde06763109f88126e755e76e14d2f30dd9fc92ad56bb84741849
	--   plan-legacy.md  0.3-era conventions: prose "INDEPENDENT of …", plain "- VALIDATE:" lines, a checkpoint with no
	--                   tasks and untasked action headers. sha256 1f2cb7489faa4ae3d110beeed59aa7794379c7aa6d095f4ee41aa79107f3faa1
	local MODERN = runtime.fs.read(root .. "/tests/fixtures/plan-modern.md")
	local LEGACY = runtime.fs.read(root .. "/tests/fixtures/plan-legacy.md")

	-- Contract drift vs plan_check.py. Expected values computed offline on 2026-11-06 with
	--   re.compile(rf"^#{{1,6}}\s+(?:{'|'.join(_ACTION_KEYWORDS)})\s+(.+?)\s*$", re.MULTILINE)
	-- copied from the Glitch engine's .claude/scripts/plan_check.py:64-68 (_ACTION_KEYWORDS + _ACTION_HEADER), run over the
	-- fixture bytes: match start line numbers (1-based; every match's group 1 starts on its own header line, so no
	-- multi-line match exists in these fixtures) and sha256 of the "\n"-joined group(1) targets.
	local PLAN_CHECK = {
		modern = { lines = { 7, 16, 24, 25, 26, 27, 36, 43, 50, 59, 66, 75, 78, 88, 97, 104, 113, 122, 129, 146 },
			targets = "34f4f193f049fb9676b11158359a7361af8e074145305362b87b375ad329d905" },
		legacy = { lines = { 11, 19, 27, 37, 45, 53, 55, 67 }, targets = "bb498b092546868fef797f69c8841d570ba797336f6f4f2dfaf3c79d8bba73fa" },
	}
	for name, bytes in { modern = MODERN, legacy = LEGACY } do
		local found, targets = action_lines(bytes)
		local want = PLAN_CHECK[name].lines
		local first = nil
		for k = 1, math.max(#found, #want) do if found[k] ~= want[k] then first = k; break end end
		check(first == nil, name .. ": plan_import header lines equal plan_check's (first difference at match " .. tostring(first) .. ": luau line "
			.. tostring(first and found[first]) .. ", python line " .. tostring(first and want[first]) .. ")")
		check(codec.sha256(table.concat(targets, "\n")) == PLAN_CHECK[name].targets, name .. ": plan_import header targets equal plan_check's group 1")
	end
	-- Edge lines, same regex offline over these 14 lines joined by "\n" -> matches on lines {1, 7, 8, 9, 11, 12, 13} with targets
	-- a/b.lua | a/h.lua | `a/i.lua` to `a/j.lua` | x.md | spaced/k.lua | .env | a/l.lua  (line 13 ends in "\r").
	local EDGE = { "### CREATE a/b.lua", "### CREATED a/c.lua", "####### UPDATE a/d.lua", "#UPDATE a/e.lua", " ### UPDATE a/f.lua", "### update a/g.lua",
		"###\tDELETE\ta/h.lua  ", "###### MOVE `a/i.lua` to `a/j.lua`", "## REMOVE x.md", "### UPDATEx y", "### MIRROR  spaced/k.lua  \t", "# ADD .env",
		"### REFACTOR a/l.lua\r", "text ### UPDATE a/m.lua" }
	local edge_lines, edge_targets = action_lines(table.concat(EDGE, "\n"))
	check(same(edge_lines, { 1, 7, 8, 9, 11, 12, 13 }) and same(edge_targets, { "a/b.lua", "a/h.lua", "`a/i.lua` to `a/j.lua`", "x.md", "spaced/k.lua", ".env", "a/l.lua" }),
		"edge headers: 1-6 hashes and exact keywords match, CREATED/UPDATEx/7 hashes/indent/lowercase/no-space/mid-line refused, as plan_check")

	-- Current conventions: 8 checkpoints, INDEPENDENT flags as written.
	local modern, modern_problem = importer.parse(MODERN)
	check(modern ~= nil and modern_problem == nil, "the modern plan parses: " .. tostring(modern_problem and modern_problem.message))
	check(modern.title == "Demo service 2.0 — synthetic importer fixture", "title from '# Feature:'")
	check(modern.plan_revision == "232be2836c9cde06763109f88126e755e76e14d2f30dd9fc92ad56bb84741849", "plan_revision is sha256 of the exact bytes")
	check(modern.project_hint.kind == "workspace" and modern.project_hint.name == "demo" and #modern.flags == 0, "## Build choices home: line becomes the project hint")
	local WANT = { { "1A", "1B" }, { "2A", "2B", "2C" }, { "3A", "3B" }, { "4A" }, { "5A" }, { "6A", "6B" }, { "7A" }, { "8A", "8B" } }
	check(#modern.checkpoints == 8, "exactly 8 checkpoints (Progress and prose never add any)")
	for n, ids in WANT do
		local cp = modern.checkpoints[n]
		local got = {}; for _, t in cp.tasks do table.insert(got, t.id) end
		check(cp.n == n and same(got, ids) and #cp.flags == 0, "checkpoint " .. n .. " holds tasks " .. table.concat(ids, ","))
		for _, t in cp.tasks do
			if n < 8 then
				check(t.independent == true and t.sequential_why == nil and not has(t.flags, "sequential_default"), t.id .. " is INDEPENDENT as written")
			else
				check(t.independent == false and type(t.sequential_why) == "string" and t.sequential_why ~= "" and not has(t.flags, "sequential_default"),
					t.id .. " is SEQUENTIAL with its stated reason")
			end
			for k, c in t.checks do check(c.check_id == t.id .. "-c" .. k, t.id .. " check ids are <task-id>-c<n>") end
		end
	end
	check(task_of(modern, "8A").sequential_why == "needs every feature checkpoint landed; one owner for the whole package.", "8A reason kept verbatim")
	check(task_of(modern, "9Z") == nil, "a task under ## Progress is never imported")
	check(task_headers(modern) == #PLAN_CHECK.modern.lines - 2, "every action header sits inside a task except the overview's and the Progress one")
	check(same(argv_list(task_of(modern, "1A")), { "demo settings" }) and same(task_of(modern, "1A").files, { "app/settings.luau" })
		and not has(task_of(modern, "1A").flags, "file_outside_home"), "1A: one check, files relative to the home workspace")
	check(same(argv_list(task_of(modern, "1B")), { "demo settings", "demo gates", "demo health" }) and task_of(modern, "1B").checks[3].check_id == "1B-c3",
		"1B: a comma list after a plain qualifier yields one check per span")
	check(#task_of(modern, "1B").files == 4 and task_of(modern, "1B").files[4] == "/srv/demo-evidence/harness.py"
		and has(task_of(modern, "1B").flags, "file_outside_home"), "1B: a file outside the home workspace is kept and flagged")
	check(same(argv_list(task_of(modern, "6A")), { "demo workflow/import" }), "6A: commas inside a trailing (...) never split the item")
	check(#task_of(modern, "2C").checks == 4 and same(task_of(modern, "2C").checks[4].argv, { "python3", "workspaces/demo/helpers/tests/posix.py" })
		and task_of(modern, "2C").checks[4].check_id == "2C-c4", "2C: ';' separates items too")
	check(same(task_of(modern, "4A").files, { "app/landing.luau", "app/fenced.luau" }), "4A: a fenced action header still declares a file, as plan_check reads it")
	for _, id in { "2B", "3A" } do
		local t = task_of(modern, id)
		check(has(t.flags, "check_unparsed") and #t.checks == 0 and not has(t.flags, "no_checks"), id .. ": prose VALIDATE is flagged check_unparsed and never a check")
	end
	check(not has(task_of(modern, "1A").flags, "check_unparsed"), "a clean VALIDATE is not flagged")
	local again = importer.parse(MODERN)
	check(same(again, modern), "parsing the same bytes twice gives the identical plan (stable ids)")
	local ruling = "\n" .. importer.RULINGS_OPEN .. "\n> orchplus-ruling:test_authority:gate_1\n> Decision: approved &lt;literal&gt;\n" .. importer.RULINGS_CLOSE .. "\n"
	check(same(assert(importer.parse(MODERN .. ruling)), modern), "canonical owner rulings change neither plan identity nor executable tasks")
	local no_eof = MODERN:gsub("\n$", "")
	check(same(assert(importer.parse(no_eof .. ruling)), assert(importer.parse(no_eof))), "metadata's own separator preserves a plan without final newline")
	local progress = "## Progress\nNew routine progress after ruling metadata\n"
	check(assert(importer.parse(MODERN .. ruling .. progress)).plan_revision == codec.sha256(MODERN .. progress),
		"later Progress remains identity-bearing content, not accidentally stripped with metadata")
	local changed = MODERN:gsub("### UPDATE", "### REFACTOR", 1)
	check(assert(importer.parse(changed .. ruling)).plan_revision == codec.sha256(changed)
		and assert(importer.parse(changed .. ruling)).plan_revision ~= modern.plan_revision,
		"independent executable edits retain normal re-import invalidation")
	local duplicate, duplicate_problem = importer.parse(MODERN .. ruling .. ruling)
	check(duplicate == nil and duplicate_problem ~= nil, "duplicate ruling blocks fail import safely without discarding instructions")

	-- Legacy conventions: import safely, never as independent work.
	local legacy, legacy_problem = importer.parse(LEGACY)
	check(legacy ~= nil and legacy_problem == nil, "the legacy plan parses: " .. tostring(legacy_problem and legacy_problem.message))
	check(legacy.title == "Demo service 1.0 — legacy-convention fixture" and legacy.plan_revision == "1f2cb7489faa4ae3d110beeed59aa7794379c7aa6d095f4ee41aa79107f3faa1"
		and legacy.project_hint.kind == "workspace" and legacy.project_hint.name == "other", "legacy plan title, revision and home")
	local legacy_ids = {}
	for _, cp in legacy.checkpoints do for _, t in cp.tasks do table.insert(legacy_ids, t.id) end end
	check(#legacy.checkpoints == 3 and #legacy_ids == 7 and #legacy.checkpoints[3].tasks == 2, "file-action work is retained as executable tasks")
	for _, cp in legacy.checkpoints do for _, t in cp.tasks do
		check(t.independent == false, t.id .. ": prose 'INDEPENDENT of …' is not the marker")
		if t.id == "1A" then check(t.sequential_why == "establishes canonical files before builders edit them." and not has(t.flags, "sequential_default"), "1A SEQUENTIAL reason")
		else check(has(t.flags, "sequential_default") and t.sequential_why == nil, t.id .. ": no marker → sequential_default") end
		check(#t.files == 1 and has(t.flags, "file_outside_home"), t.id .. ": files outside home workspace:other are flagged")
	end end
	check(#legacy.checkpoints[3].tasks == 2 and not has(legacy.checkpoints[3].flags, "untasked_actions"), "action-owned tasks no longer disappear from the plan")
	check(task_headers(legacy) == #PLAN_CHECK.legacy.lines - 1, "all executable action headers remain task-owned; Progress remains excluded")

	-- Inline plans: markers, checks, refusals; each both ways.
	local GOOD = {
		"# Feature: Fixture", "", "## Build choices", "", "home: workspace:tools", "",
		"## IMPLEMENTATION PLAN", "", "### Checkpoint 1 — One", "",
		"#### Task 1A — marked independent", "**INDEPENDENT** — alongside 1B.", "", "### UPDATE workspaces/tools/a.lua", "",
		"- **VALIDATE**: native `rorch dispatch`, `rorch \"gates x\"`", "",
		"#### Task 1B — no marker", "", "### CREATE workspaces/tools/b.lua", "", "- **VALIDATE**: `rorch \"dispatch`", "",
		"#### Task 1C — sequential", "SEQUENTIAL: after 1A.", "", "### UPDATE workspaces/tools/c.lua", "", "- **VALIDATE**: doc review.", "",
		"#### Task 1D — both markers", "**INDEPENDENT**", "SEQUENTIAL: contradicts.", "", "### UPDATE workspaces/tools/d.lua", "",
		"- **VALIDATE**: `a one`, prose here, `b two`", "",
		"### Checkpoint 2 — Two", "", "#### Task 2A — later", "**INDEPENDENT**", "", "### UPDATE workspaces/tools/e.lua", "",
		"## Progress", "", "### Checkpoint 9 — never imported", "#### Task 9A — never imported", "**INDEPENDENT**",
	}
	local good, good_problem = importer.parse(plan(GOOD))
	check(good ~= nil and good_problem == nil and #good.checkpoints == 2 and #good.checkpoints[2].tasks == 1, "a well-formed plan is accepted; ## Progress is skipped")
	local t1a, t1b, t1c, t1d = task_of(good, "1A"), task_of(good, "1B"), task_of(good, "1C"), task_of(good, "1D")
	check(t1a.independent and #t1a.flags == 0, "INDEPENDENT marker → independent, no flags")
	check(not t1b.independent and has(t1b.flags, "sequential_default"), "no marker → sequential by default and flagged sequential_default")
	check(not t1c.independent and t1c.sequential_why == "after 1A." and not has(t1c.flags, "sequential_default"), "SEQUENTIAL: <why> → sequential, not flagged")
	check(not t1d.independent and has(t1d.flags, "marker_conflict"), "both markers → sequential and flagged marker_conflict")
	check(#t1a.checks == 2 and t1a.checks[1].check_id == "1A-c1" and same(t1a.checks[1].argv, { "rorch", "dispatch" }) and t1a.checks[2].check_id == "1A-c2" and same(t1a.checks[2].argv, { "rorch", "gates x" }),
		"quoted argument stays one argv element; ids 1A-c1, 1A-c2")
	check(#t1b.checks == 0 and has(t1b.flags, "check_unparsed") and not has(t1b.flags, "no_checks"), "unbalanced quote → check_unparsed, never a check")
	check(#t1c.checks == 0 and has(t1c.flags, "check_unparsed"), "prose VALIDATE → check_unparsed")
	check(same(argv_list(t1d), { "a one", "b two" }) and t1d.checks[2].check_id == "1D-c2" and has(t1d.flags, "check_unparsed"),
		"an unparsed item between commands is flagged and skipped; parsed items keep consecutive ids")
	check(not has(t1a.flags, "check_unparsed") and same(t1a.files, { "a.lua" }), "a clean task carries no check_unparsed flag")
	-- Stable ids: unrelated edits elsewhere never renumber a task's checks.
	local edited = table.clone(GOOD)
	table.insert(edited, 10, "Extra prose line that mentions `rorch other`.")
	table.insert(edited, 11, "#### Task 0Z — inserted first")
	table.insert(edited, 12, "- **VALIDATE**: `rorch first`")
	local moved = importer.parse(plan(edited))
	check(moved ~= nil and same(task_of(moved, "1A").checks, t1a.checks) and task_of(moved, "0Z").checks[1].check_id == "0Z-c1" and moved.plan_revision ~= good.plan_revision,
		"check ids are task-scoped: a new task and prose elsewhere keep 1A-c1/1A-c2; the revision changes")

	-- Malformed plans are refused with a code and no plan.
	local function refused(lines_or_bytes, code, why)
		local bytes = if type(lines_or_bytes) == "table" then plan(lines_or_bytes) else lines_or_bytes
		local value, p = importer.parse(bytes)
		check(value == nil and type(p) == "table" and p.ok == false and p.code == code and type(p.message) == "string" and p.message ~= "",
			why .. " → " .. code .. " (got " .. tostring(p and p.code) .. ")")
	end
	refused({ "# Not a feature", "### Checkpoint 1 — One", "#### Task 1A — t", "**INDEPENDENT**" }, "no_title", "missing '# Feature:' title")
	refused({ "# Feature: Empty", "", "Prose only." }, "no_checkpoints", "title but no checkpoints")
	refused({ "# Feature: X", "### Checkpoint 1 One", "#### Task 1A — t" }, "checkpoint_header_invalid", "checkpoint without the dash title")
	refused({ "# Feature: X", "### Checkpoint 2 — Two", "#### Task 2A — t", "### Checkpoint 1 — One", "#### Task 1A — t" }, "checkpoint_order", "decreasing checkpoint numbers")
	local outside = assert(importer.parse(plan({ "# Feature: X", "## Task Format Guidelines", "#### Task 1A — example, not executable",
		"## Plan", "### Checkpoint 1 — One", "#### Task 1B — actual work", "Do the bounded work." })))
	check(#outside.checkpoints == 1 and #outside.checkpoints[1].tasks == 1 and outside.checkpoints[1].tasks[1].id == "1B",
		"Task-like format examples outside a checkpoint do not create work or invalidate the real checkpoint")
	refused({ "# Feature: X", "### Checkpoint 1 — One", "#### Task 1A first" }, "task_header_invalid", "task with a digit id but no dash title")
	refused({ "# Feature: X", "### Checkpoint 1 — One", "#### Task 1A.b — t" }, "task_id_invalid", "task id outside [A-Za-z0-9_-]")
	refused({ "# Feature: X", "### Checkpoint 1 — One", "#### Task 1A — t", "### Checkpoint 2 — Two", "#### Task 1A — again" }, "duplicate_task", "duplicate task id")
	refused(string.rep("a", importer.MAX_BYTES + 1), "too_large", "over 1 MiB")
	refused(plan(GOOD) .. "\0", "invalid_input", "NUL byte")
	refused(plan(GOOD) .. "\255", "invalid_input", "invalid UTF-8")
	refused(42, "invalid_input", "non-string input")
	check(importer.parse(plan({ "# Feature: X", "### Checkpoint 1 — One", "#### Task notes about this checkpoint" })) ~= nil,
		"a prose '#### Task …' heading without a digit id is content, not a malformed task")
end


if section == nil or section == "review_cross_family" then
	-- Cold start: the first-ever review on a fresh store creates the collection.
	local f = W.fixture({ reviewer_records = W.arr({ "claude2", "codex" }) })
	local b = W.builder(f)
	check(f.authority.registry.dispatch.reviews == nil or next(f.authority.registry.dispatch.reviews) == nil, "a fresh store has no review records")
	check(W.worker(f, b).family == "anthropic", "the builder's declared family resolves from its catalog provider")
	check(W.ready(f, b, "cp-1", "rev-1", 0).ok, "REVIEW_READY is accepted")
	local r = W.review(f, b)
	check(r ~= nil and r.round == 1 and r.artifact_revision == W.hx("rev-1") and r.builder_family == "anthropic" and r.builder_worker_id == b,
		"cold start: the first REVIEW_READY on a fresh store opens round 1 for the exact revision")
	check(r.reviewer_record_id == "codex" and r.reviewer_family == "openai", "enforced: the same-family first entry is skipped for the first different-family reviewer record")
	local rid = W.reviewer_of(f, r)
	check(rid ~= nil and rid ~= b and W.worker(f, rid).role == "reviewer" and W.worker(f, rid).record_id == "codex", "a fresh reviewer worker is queued on the chosen record")
	check(W.restores(f), "an open review with its queued reviewer restores")
	local reviewer, request = W.open(f, r)
	local p = request.payload
	check(p.review_id == r.review_id and p.round == 1 and p.question_id == "implements_task_v1" and p.artifact_revision == W.hx("rev-1")
		and p.builder_work_id == W.worker(f, b).work_id and p.task_ref == "task:fixture" and #p.findings_prev == 0,
		"after ACCEPT the reviewer receives the fixed-question review_request for the builder's exact revision")
	-- The builder cannot answer its own review, even with the request's correlation.
	local before = runtime.json.encode(f.authority.registry.dispatch.reviews)
	local self_review = W.result(f, b, request, "approved")
	check(self_review.code == "reviewer_is_builder" and runtime.json.encode(f.authority.registry.dispatch.reviews) == before, "reviewer = builder: the builder's own REVIEW_RESULT is refused")
	check(W.result(f, reviewer, request, "approved", nil, { artifact_revision = W.hx("rev-other") }).code == "review_mismatch", "a result for another revision is refused")
	check(W.result(f, reviewer, request, "approved", nil, { round = 2 }).code == "review_mismatch", "a result for another round is refused")
	check(W.result(f, reviewer, request, "approved").ok, "different family: the reviewer's approved result is accepted")
	r = f.authority.registry.dispatch.reviews[r.review_id]
	check(r.status == "approved" and r.reviewer_worker_id == reviewer and r.result ~= nil and r.result.outcome == "approved", "the review record owns the accepted result")
	check(W.result(f, reviewer, request, "approved").code == "review_closed" and f.authority.registry.dispatch.reviews[r.review_id].status == "approved", "one request authorizes one result")
	local lid = W.request(f, b, "cp-1", "rev-1"); assert(W.approve(f, lid).ok)
	local it = W.item(f, lid)
	check(it.status == "granted" and it.proof.mode == "cross_family_review" and it.proof.review_id == r.review_id, "an approved different-family review is the landing proof")
	W.rule_h(f); check(W.restores(f), "approved review, proof and grant restore")

	-- Same family refused at the result: a same-family reviewer chosen while enforcement was off answers
	-- after the owner turns enforcement on (declared families are fixed when each worker is queued).
	local s = W.fixture({ require_other_family = false, reviewer_records = W.arr({ "claude2" }) })
	local sb = W.builder(s); assert(W.ready(s, sb, "cp-1", "rev-1", 0).ok)
	local sr = W.review(s, sb); local sv, sreq = W.open(s, sr)
	check(W.worker(s, sv).family == "anthropic", "the same-family reviewer was eligible while enforcement was off")
	assert(s:apply("policy", { policy = { require_other_family = true } }).ok)
	check(W.result(s, sv, sreq, "approved").ok, "the same-family reviewer's report is accepted as evidence")
	sr = s.authority.registry.dispatch.reviews[sr.review_id]
	check(sr.status ~= "approved" and sr.result == nil and sr.refusal ~= nil and sr.refusal.code == "family_same" and sr.reviewer_worker_id ~= sv,
		"same family refused: the result is recorded as a family_same refusal, never an approval, and the reviewer is released")
	local sl = W.request(s, sb, "cp-1", "rev-1"); assert(W.approve(s, sl).ok)
	check(#W.item(s, sl).grants == 0, "a refused same-family result never grants")
	W.rule_h(s); check(W.restores(s), "a refused review restores")

	-- Same family only: no eligible reviewer → reviewer_unavailable, nothing queued.
	local g = W.fixture({ reviewer_records = W.arr({ "claude2" }) })
	local gb = W.builder(g); local workers = 0; for _ in g.authority.registry.dispatch.workers do workers += 1 end
	check(W.ready(g, gb, "cp-1", "rev-1").ok, "REVIEW_READY accepted without an eligible reviewer")
	local after = 0; for _ in g.authority.registry.dispatch.workers do after += 1 end
	local unavailable = W.gates(g, "reviewer_unavailable")
	check(#unavailable == 1 and unavailable[1].worker_id == gb and after == workers, "same family refused: only a same-family reviewer record opens reviewer_unavailable on the builder and queues no reviewer")
	check(table.concat({ unavailable[1].options[1].id, unavailable[1].options[2].id }, ",") == "retry,cancel", "reviewer_unavailable offers retry or cancel")
	local gl = W.request(g, gb, "cp-1", "rev-1"); assert(W.approve(g, gl).ok)
	check(#W.item(g, gl).grants == 0 and W.item(g, gl).proof == nil, "without a different-family review nothing is granted")
	W.rule_h(g); check(W.restores(g), "reviewer_unavailable restores")

	-- Unknown families gate: an OMP builder, and an only-OMP reviewer list.
	local h = W.fixture({ reviewer_records = W.arr({ "codex" }) })
	local hb = W.builder(h, "omp")
	check(W.worker(h, hb).family == nil, "an OMP record has no declared family until the owner maps it")
	check(W.ready(h, hb, "cp-1", "rev-1").ok and #W.gates(h, "family_unknown") == 1 and W.reviewer_of(h, W.review(h, hb) or {}) == nil,
		"unknown builder family gates family_unknown and queues no reviewer")
	local k = W.fixture({ reviewer_records = W.arr({ "omp" }) })
	local kb = W.builder(k)
	check(W.ready(k, kb, "cp-1", "rev-1").ok and #W.gates(k, "family_unknown") + #W.gates(k, "reviewer_unavailable") == 1 and #W.gates(k, "family_unknown") == 1,
		"an unmapped reviewer family gates family_unknown, never a guess")
	W.rule_h(h); W.rule_h(k); check(W.restores(h) and W.restores(k), "family gates restore")

	-- Enforcement off: same family is allowed, but never the builder's own record.
	local m = W.fixture({ require_other_family = false, reviewer_records = W.arr({ "builder", "claude2" }) })
	local mb = W.builder(m)
	local mr = W.round(m, mb, "cp-1", "rev-1", "approved", nil, 0)
	check(mr.status == "approved" and mr.reviewer_record_id == "claude2" and mr.reviewer_family == "anthropic",
		"enforcement off: the builder's own record is skipped and a same-family reviewer is accepted")
	local ml = W.request(m, mb, "cp-1", "rev-1"); assert(W.approve(m, ml).ok)
	check(W.item(m, ml).status == "granted" and W.item(m, ml).proof.mode == "helper_checks", "same-family review plus passing helper checks grants with enforcement off")
	local n = W.fixture({ require_other_family = false, reviewer_records = W.arr({ "builder" }) })
	local nb = W.builder(n)
	check(W.ready(n, nb, "cp-1", "rev-1").ok and #W.gates(n, "reviewer_unavailable") == 1, "reviewer record = builder record is never eligible")
	W.rule_h(m); W.rule_h(n); check(W.restores(m) and W.restores(n), "enforcement-off reviews restore")

	-- Turning review off during an active availability hold closes the gate immediately.
	do
		local t = W.fixture({ reviewer_records = W.arr({ "claude2" }) })
		local tb = W.builder(t)
		assert(W.ready(t, tb, "cp-toggle", "rev-toggle", 0).ok)
		local gate = W.gates(t, "reviewer_unavailable")[1]
		assert(gate and gate.phase == "pending", "toggle fixture needs a pending reviewer availability gate")
		assert(t:apply("policy", { policy = { require_code_review = false } }).ok)
		local p = t.authority.registry.dispatch.policies[t.origin.logical_session_id]
		check(not p.require_code_review and not p.require_other_family, "disabling review clears the active family's requirement")
		check(#W.gates(t, "reviewer_unavailable") == 0 and #W.gates(t, "family_unknown") == 0,
			"disabling review closes the pending reviewer availability gate")
		check(t.authority.registry.dispatch.gates[gate.id] == nil,
			"the settled availability gate is reclaimed, not merely hidden")
		assert(W.ready(t, tb, "cp-off", "rev-off", 0).ok)
		assert(t:tick())
		for _, w in t.authority.registry.dispatch.workers do check(w.role ~= "reviewer", "reports and ticks while review is off spawn no reviewer") end
		check(#W.gates(t, "reviewer_unavailable") == 0 and #W.gates(t, "family_unknown") == 0, "off reports never reopen review availability gates")
		check(W.restores(t), "active review-off transition restores")
		assert(t:apply("policy", { policy = { require_code_review = true } }).ok)
		p = t.authority.registry.dispatch.policies[t.origin.logical_session_id]
		check(p.require_code_review and not p.require_other_family, "reenabling review does not remember the old family requirement")
		assert(W.ready(t, tb, "cp-on", "rev-on", 0).ok)
		local review = assert(W.review(t, tb))
		check(review.reviewer_record_id == "claude2" and W.reviewer_of(t, review) ~= nil,
			"reenabled review actually queues the formerly ineligible same-family reviewer")
		check(W.restores(t), "reenabled same-family review restores")
	end
end

if section == nil or section == "review_rounds" then
	local f = W.fixture({ reviewer_records = W.arr({ "codex" }) })
	local b = W.builder(f)
	local r1, v1 = W.round(f, b, "cp-1", "rev-1", "changes_required", W.findings(2), 0)
	check(r1.status == "changes_required" and r1.round == 1 and #r1.findings == 2 and v1 ~= b, "round 1 changes_required keeps its findings")
	local rework = W.replies(f, b, "rework")
	check(#rework == 1, "changes_required issues exactly one rework reply to the builder")
	local p = rework[1].reply.payload
	local keys = {}; for key in p do table.insert(keys, key) end; table.sort(keys)
	check(table.concat(keys, ",") == "artifact_revision,failed_checks,findings,review_id,round" and p.review_id == r1.review_id and p.round == 1
		and p.artifact_revision == W.hx("rev-1") and #p.failed_checks == 0 and #p.findings == 2 and p.findings[1].finding_id == "f1" and p.findings[2].line == 2,
		"review rework carries only findings when the independent helper checks pass")
	-- Round 2 on a new revision: the same review, a fresh reviewer worker, the previous findings attached.
	local ready = W.ready(f, b, "cp-2", "rev-2", 0); assert(ready.ok, ready.message)
	local r2 = W.review(f, b)
	check(r2.review_id == r1.review_id and r2.round == 2 and r2.artifact_revision == W.hx("rev-2"), "the next REVIEW_READY on a new revision opens round 2 of the same review")
	local v2, request2 = W.open(f, r2)
	check(v2 ~= v1 and v2 ~= b and #request2.payload.findings_prev == 2 and request2.payload.findings_prev[1].finding_id == "f1" and request2.payload.round == 2,
		"round 2 goes to a fresh reviewer worker with the round 1 findings")
	assert(W.result(f, v2, request2, "approved").ok)
	r2 = api.clone(f.authority.registry.dispatch.reviews[r2.review_id])
	check(r2.status == "approved" and #W.replies(f, b, "rework") == 1, "an approved round 2 sends no further rework")
	local lid = W.request(f, b, "cp-2", "rev-2"); assert(W.approve(f, lid).ok)
	check(W.item(f, lid).status == "granted" and W.item(f, lid).proof.review_id == r2.review_id, "the round 2 approval proves its revision")
	W.rule_h(f)
	local project = f.authority.registry.dispatch.projects[W.worker(f, b).orch_project_id]
	local retained_grant = api.clone(W.grant(f, lid))
	local refreshed = f:apply("project_repository", { orch_project_id = project.orch_project_id,
		project_revision = project.revision, repository = api.clone(project.repository) })
	check(refreshed.ok and refreshed.code == "no_progress"
		and f.authority.registry.dispatch.projects[project.orch_project_id].revision == project.revision
		and api.quota.digest(W.grant(f, lid)) == api.quota.digest(retained_grant),
		"an identical verified repository refresh preserves a pending landing and its immutable grant")
	local observation = api.clone(project.repository)
	observation.target_ref = "main"; observation.head_revision = W.hx("fresh-target-observation")
	local observed = f:apply("project_repository", { orch_project_id = project.orch_project_id,
		project_revision = project.revision, repository = observation })
	check(observed.ok and api.quota.digest(W.grant(f, lid)) == api.quota.digest(retained_grant),
		"refreshing head evidence under the same canonical checkout/target preserves the pending immutable grant")
	local current_project = f.authority.registry.dispatch.projects[project.orch_project_id]
	local retarget = api.clone(current_project.repository); retarget.target_ref = "refs/heads/other"
	check(f:apply("project_repository", { orch_project_id = current_project.orch_project_id,
		project_revision = current_project.revision, repository = retarget }).code == "repository_busy"
		and api.quota.digest(W.grant(f, lid)) == api.quota.digest(retained_grant),
		"a genuinely different target stays fenced while its old landing is unsettled")
	W.land(f, lid, "head-1")
	-- A new artifact revision voids the approval and its check proof.
	W.settle(f, b)
	check(W.send(f, b, "CHECKPOINT", W.cp("cp-3", "rev-3")).ok, "a new revision is checkpointed")
	local voided = f.authority.registry.dispatch.reviews[r2.review_id]
	check(voided.void ~= nil and voided.void.artifact_revision == W.hx("rev-3"), "new revision voids approval: the approved review records the void")
	local l3 = W.request(f, b, "cp-3", "rev-3", nil, "head-1"); assert(W.approve(f, l3).ok)
	check(#W.item(f, l3).grants == 0 and W.item(f, l3).proof == nil and W.item(f, l3).hold.code == "check_stale",
		"landing the new revision waits for fresh checks as well as its own review")
	W.rule_h(f); check(W.restores(f), "rework rounds and voided approvals restore")
	-- Same-family-allowed mode retains the independent review findings loop.
	local n = W.fixture({ require_other_family = false, reviewer_records = W.arr({ "codex" }) })
	local nb = W.builder(n)
	W.round(n, nb, "cp-1", "rev-1", "changes_required", W.findings(1), 0)
	local nrework = W.replies(n, nb, "rework")
	local np = nrework[#nrework].reply.payload
	check(#np.failed_checks == 0 and #np.findings == 1,
		"same-family mode keeps review findings separate from passing checks")
	W.rule_h(n); check(W.restores(n), "helper-checks rework restores")

	-- Round cap at review_rounds: changes_required on the last allowed round caps the review with one loop_cap gate.
	for _, cap in { 1, 2 } do
		local g = W.fixture({ reviewer_records = W.arr({ "codex" }), review_rounds = cap })
		local gb = W.builder(g)
		local last
		for index = 1, cap do last = W.round(g, gb, "cp-" .. index, "rev-" .. index, "changes_required", W.findings(1)) end
		local capped = g.authority.registry.dispatch.reviews[last.review_id]
		local loops = W.gates(g, "loop_cap")
		check(capped.status == "capped" and capped.round == cap and #loops == 1 and loops[1].options[1].id == "stop" and #loops[1].options == 1,
			"cap " .. cap .. ": changes_required on round " .. cap .. " caps the review with one stop-only loop_cap gate")
		check(#W.replies(g, gb, "rework") == cap - 1, "cap " .. cap .. ": the capped round sends no rework")
		local workers = 0; for _ in g.authority.registry.dispatch.workers do workers += 1 end
		W.settle(g, gb)
		assert(W.send(g, gb, "CHECKPOINT", W.cp("cp-x", "rev-x")).ok)
		check(W.send(g, gb, "REVIEW_READY", { checkpoint_id = "cp-x", artifact_revision = W.hx("rev-x") }).ok, "cap " .. cap .. ": a later REVIEW_READY is still accepted as a report")
		local after = 0; for _ in g.authority.registry.dispatch.workers do after += 1 end
		check(g.authority.registry.dispatch.reviews[last.review_id].status == "capped" and g.authority.registry.dispatch.reviews[last.review_id].round == cap
			and #W.reviews(g, gb) == 1 and after == workers, "cap " .. cap .. ": no round beyond review_rounds is opened and no reviewer is queued")
		W.rule_h(g); check(W.restores(g), "cap " .. cap .. ": a capped review restores")
	end
end

if section == nil or section == "auto_finish" then
	local f = W.fixture({ reviewer_records = W.arr({ "codex" }) })
	local b = W.builder(f)
	assert(W.ready(f, b, "cp-1", "rev-1").ok)
	local r = W.review(f, b)
	local reviewer, request = W.open(f, r)
	-- Unsettled state defers: a pending owner progress request to the reviewer.
	local unconfirmed = f:apply("reply", { worker_id = reviewer })
	check(not unconfirmed.ok and unconfirmed.code == "worker_not_sendable", "an unobserved reviewer is never interrupted by a progress request")
	assert(f:apply("observe", { worker_id = reviewer, pane_binding = api.clone(W.worker(f, reviewer).pane_binding), native_state = "idle" }).ok)
	local reply = f:apply("reply", { worker_id = reviewer })
	assert(reply.ok, reply.message)
	check(W.result(f, reviewer, request, "approved").ok, "the reviewer's result is accepted")
	check(W.worker(f, reviewer).finish == nil, "unsettled: the result's receipt is unpublished and a reply is pending, so no finish is queued")
	local pending = W.worker(f, reviewer).workflow.report_request
	W.settle(f, reviewer, true)
	check(W.worker(f, reviewer).finish == nil, "unsettled: a published but unacknowledged reply still defers the finish")
	assert(W.send(f, reviewer, "reply_ack", { message_id = pending.message_id, reply_seq = pending.reply_seq, reply_sha256 = api.codec.sha256(pending.bytes), status = "recorded" },
		{ action_id = pending.action_id, action_revision = pending.action_revision }).ok)
	assert(W.send(f, reviewer, "HEARTBEAT", { state = "idle", request_id = pending.request_id }).ok)
	check(W.worker(f, reviewer).finish == nil, "unsettled: the new receipts are not yet published under a watermark")
	W.settle(f, reviewer, true)
	local w = W.worker(f, reviewer)
	check(w.finish ~= nil and w.finish.source ~= nil and w.finish.source.kind == "policy" and w.finish.source.rule == "auto_finish:reviewer",
		"settled: ORCH+ queues the standard finish with a policy source auto_finish:reviewer")
	check(f.authority.registry.dispatch.reviews[r.review_id].status == "approved" and f.authority.registry.dispatch.reviews[r.review_id].result ~= nil,
		"the review record keeps the evidence after the reviewer finishes")
	local stop = f:apply("poll", { worker_id = reviewer })
	check(stop.ok and stop.action_id and f:action(stop.action_id).request.op == "stop", "the standard finish effect follows: exact pane stop first")
	check(W.worker(f, b).finish == nil, "auto-finish never applies to the builder")
	W.rule_h(f); check(W.restores(f), "an auto-finishing reviewer restores")
	-- Clean path: the only unsettled state is the result's own receipt.
	local g = W.fixture({ reviewer_records = W.arr({ "codex" }) })
	local gb = W.builder(g); assert(W.ready(g, gb, "cp-1", "rev-1").ok)
	local gr = W.review(g, gb); local gv, greq = W.open(g, gr)
	W.settle(g, gv, true)
	check(W.worker(g, gv).finish == nil, "a reviewer with an open review is pinned and never finishes before its result")
	assert(W.result(g, gv, greq, "changes_required", W.findings(1)).ok)
	check(W.worker(g, gv).finish == nil, "unsettled: the result receipt is not yet published")
	W.settle(g, gv, true)
	check(W.worker(g, gv).finish ~= nil and W.worker(g, gv).finish.source.rule == "auto_finish:reviewer", "a changes_required reviewer also auto-finishes once settled")
	check(W.worker(g, gb).finish == nil and #W.replies(g, gb, "rework") == 1, "the builder keeps its rework and is never finished")
	W.rule_h(g); check(W.restores(g), "the settled auto-finish restores")
	-- An acknowledged request still owes a result when the owner turns review off.
	for _, outcome in { "approved", "changes_required" } do
		local t = W.fixture({ reviewer_records = W.arr({ "codex" }) })
		local tb = W.builder(t); assert(W.ready(t, tb, "cp-off", "rev-off", 0).ok)
		local review = assert(W.review(t, tb)); local reviewer_id, issued = W.open(t, review)
		W.settle(t, reviewer_id, true)
		check(next(W.worker(t, reviewer_id).replies) == nil and next(W.worker(t, reviewer_id).receipts) == nil,
			"late " .. outcome .. ": request ACK and receipt lane are settled before disabling review")
		assert(t:apply("policy", { policy = { require_code_review = false } }).ok)
		check(W.worker(t, reviewer_id).finish == nil and t.authority.registry.dispatch.reviews[review.review_id].status == "cancelled",
			"late " .. outcome .. ": cancellation removes review authority but preserves the issued reviewer's settlement obligation")
		check(W.restores(t), "late " .. outcome .. ": cancelled outstanding review restores before its result")
		local accepted = W.result(t, reviewer_id, issued, outcome, W.findings(1))
		check(accepted.ok and W.worker(t, reviewer_id).rejected_report == nil
			and W.worker(t, reviewer_id).workflow.evidence.REVIEW_RESULT ~= nil,
			"late " .. outcome .. ": exact correlated result is consumed, not rejected as worker_retiring")
		local cancelled = t.authority.registry.dispatch.reviews[review.review_id]
		check(cancelled.status == "cancelled" and cancelled.result == nil and #W.reviews(t) == 1
			and #W.replies(t, tb, "rework") == 0,
			"late " .. outcome .. ": consumption neither approves/reopens the review nor creates completed review history or rework")
		W.settle(t, reviewer_id, true)
		check(W.worker(t, reviewer_id).finish ~= nil, "late " .. outcome .. ": normal automatic retirement resumes after actual result settlement")
		check(W.restores(t), "late " .. outcome .. ": consumed cancellation and retirement restore")
		local stop = t:apply("poll", { worker_id = reviewer_id })
		assert(stop.ok and stop.action_id and t:action(stop.action_id).request.op == "stop")
		assert(t:finish(stop.action_id, "stopped", { pane_binding = api.clone(t:action(stop.action_id).request.pane_binding), observation = "absent" }).ok)
		local retire = t:apply("poll", { worker_id = reviewer_id })
		assert(retire.ok and retire.action_id and t:action(retire.action_id).request.mode == "retire")
		assert(t:finish(retire.action_id, "retired", {}).ok)
		W.builder(t) -- Ordinary queue reclaims settled workers and their cancelled obligations.
		check(W.worker(t, reviewer_id) == nil and t.authority.registry.dispatch.reviews[review.review_id] == nil,
			"late " .. outcome .. ": worker reclamation also removes its settled cancellation, without retaining result history")
		assert(t:apply("policy", { policy = { require_code_review = true } }).ok)
		assert(W.ready(t, tb, "cp-next", "rev-next", 0).ok)
		local next_review = assert(W.review(t, tb))
		check(next_review.review_id ~= review.review_id and next_review.reviewer_worker_id ~= nil and #W.reviews(t) == 1,
			"late " .. outcome .. ": further review uses a fresh record rather than leaking a permanently pending cancellation")
		check(W.restores(t), "late " .. outcome .. ": reclaimed cancellation and further review restore")
	end
end

if section == nil or section == "review_reclamation" then
	local f = W.fixture({ reviewer_records = W.arr({ "codex" }) })
	local b = W.builder(f, nil, { checks = W.arr() })
	local first_review, first_worker
	for index = 1, 65 do
		assert(f:apply("policy", { policy = { require_code_review = true } }).ok)
		assert(W.ready(f, b, "cp-cycle", "rev-cycle").ok)
		local review = assert(W.review(f, b))
		local rid, request = W.open(f, review)
		first_review = first_review or review.review_id; first_worker = first_worker or rid
		W.settle(f, rid, true)
		assert(f:apply("policy", { policy = { require_code_review = false } }).ok)
		assert(W.result(f, rid, request, if index % 2 == 0 then "approved" else "changes_required", W.findings(1)).ok)
		check(W.review(f, b).status == "cancelled" and W.review(f, b).result == nil,
			"cycle " .. index .. ": cancelled result is settlement only, never review approval/history")
		W.settle(f, rid, true)
		local stop = f:apply("poll", { worker_id = rid })
		assert(stop.ok and stop.action_id and f:action(stop.action_id).request.op == "stop")
		assert(f:finish(stop.action_id, "stopped", { pane_binding = api.clone(f:action(stop.action_id).request.pane_binding), observation = "absent" }).ok)
		local retire = f:apply("poll", { worker_id = rid })
		assert(retire.ok and retire.action_id and f:action(retire.action_id).request.mode == "retire")
		assert(f:finish(retire.action_id, "retired", {}).ok)
	end
	check(W.worker(f, first_worker) == nil and f.authority.registry.dispatch.reviews[first_review] == nil and #W.reviews(f) < 32,
		"ordinary worker-cap reclamation removes settled cancellations and allows more than 64 consecutive reviews")
	check(W.restores(f), "post-cap cancelled-review reclamation restores with bounded current state")
end

if section == nil or section == "review_location" then
	for _, task in { "task:ordinary", "task:orch-readiness" } do
		local f = W.fixture({ reviewer_records = W.arr({ "codex" }) })
		local b = W.builder(f)
		local cp = W.cp("cp-location", "rev-location")
		cp.task_ref = task; cp.worktree_ref = "/disposable/review-repository"
		assert(W.send(f, b, "CHECKPOINT", cp).ok)
		assert(W.send(f, b, "REVIEW_READY", { checkpoint_id = cp.checkpoint_id, artifact_revision = cp.artifact_revision }).ok)
		local review = assert(W.review(f, b))
		check(review.reviewer_worker_id == nil and review.hold.code == "review_location_unverified",
			task .. ": a checkpoint alone cannot substitute the configured cwd for an actual review location")
		assert(W.checkout(f, b, "rev-location", "/different/repository").ok)
		assert(W.send(f, b, "REVIEW_READY", { checkpoint_id = cp.checkpoint_id, artifact_revision = cp.artifact_revision }).ok)
		check(W.review(f, b).reviewer_worker_id == nil, task .. ": contradictory helper location never launches a reviewer")
		W.settle(f, b, true)
		assert(W.checkout(f, b, "rev-old", cp.worktree_ref).ok)
		assert(W.send(f, b, "REVIEW_READY", { checkpoint_id = cp.checkpoint_id, artifact_revision = cp.artifact_revision }).ok)
		check(W.review(f, b).reviewer_worker_id == nil, task .. ": checkout for another revision cannot verify the location")
		assert(W.checkout(f, b, "rev-location", cp.worktree_ref).ok)
		assert(W.send(f, b, "REVIEW_READY", { checkpoint_id = cp.checkpoint_id, artifact_revision = cp.artifact_revision }).ok)
		local rid, request = W.open(f, W.review(f, b))
		local reviewer = W.worker(f, rid)
		check(reviewer.cwd == "/fixture" and reviewer.prompt:find(cp.worktree_ref, 1, true) ~= nil
			and request.payload.source_ref == "refs/heads/fixture-work" and request.payload.artifact_revision == cp.artifact_revision,
			task .. ": actual delivered reviewer assignment names the verified worktree separately from branch and artifact, despite another launch cwd")
		check(W.result(f, rid, request, "approved").ok and W.review(f, b).status == "approved",
			task .. ": the location-bearing assignment retains ordinary correlated review behavior")
		check(W.restores(f), task .. ": verified review location restores")
	end
end

if section == nil or section == "policy_revision" then
	local f = W.fixture()
	local sid = f.origin.logical_session_id
	local function flow() return api.dispatch.project(f.authority.registry, sid, f.origin.alias_nonce).workflow end
	local original = flow()
	assert(f:apply("policy", { policy = { require_code_review = original.policy.require_code_review } }).code == "no_progress")
	check(flow().policy_revision == original.policy_revision, "a no-op policy save does not invalidate the current policy fence")
	assert(f:apply("policy", { policy = { require_code_review = false } }).ok)
	local changed = flow()
	assert(f:apply("policy", { policy = { require_code_review = true, require_other_family = true } }).ok)
	local restored = flow()
	check(same(restored.policy, original.policy) and restored.policy_revision > changed.policy_revision
		and changed.policy_revision > original.policy_revision, "away-and-back edits retain a monotonic policy fence despite identical final policy")
	assert(f:apply("catalog").ok)
	check(flow().policy_revision == restored.policy_revision, "ordinary dispatch commands preserve the latest policy-change revision")
	local registry = assert(api.state.rehydrate(api.clone(f.authority.registry)))
	check(api.dispatch.policy_revision(registry, sid) == restored.policy_revision, "the current fence survives restore without retaining policy history")
	registry.installation_defaults.policy = api.clone(original.policy)
	local function result(revision)
		return api.state.apply(registry, { kind = "setup_lifecycle", request_id = "qualified-readiness", expected_revision = registry.installation_defaults.revision,
			readiness_policy = { logical_session_id = sid, revision = revision },
			readiness = { state = "passed", config_revision = registry.installation_defaults.revision, summary = "Fixture landed and read back." } })
	end
	local rejected, problem = result(original.policy_revision)
	check(rejected == nil and problem.code == "stale_policy", "commit rejects the original readiness fence after temporary policy edits, even with restored equality")
	local accepted = assert(result(restored.policy_revision))
	check(accepted.setup.readiness.state == "passed", "unchanged current policy can attach its passed readiness result")
	local invalid = api.clone(registry)
	invalid.dispatch.command_cursors[sid].policy_revision = invalid.revision + 1
	check(api.state.rehydrate(invalid) == nil, "a future policy fence cannot restore")
end

if section == nil or section == "proof_rule" then
	for _, mode in { { true, true, "cross_family_review" }, { true, false, "helper_checks" }, { false, false, "review_disabled" } } do
		for _, state in { "empty", "passed", "failed", "missing", "stale" } do
			local label = mode[3] .. "/" .. state
			local f = W.fixture({ require_code_review = mode[1], require_other_family = mode[2],
				reviewer_records = W.arr(if mode[1] then { if mode[2] then "codex" else "claude2" } else {}) })
			local b = W.builder(f, nil, { checks = if state == "empty" then W.arr() else W.unit() })
			assert(W.ready(f, b, "cp-1", "rev-1", if state == "passed" then 0 elseif state == "failed" then 1 else nil).ok)
			if state == "stale" then
				assert(W.send(f, b, "CHECK_RESULT", { check_id = "unit", argv_sha256 = api.codec.sha256("argv"), exit_code = 0,
					output_sha256 = api.codec.sha256("check output"), head = W.hx("rev-old"), ran_at_ms = 1 }).ok)
			end
			if mode[1] then
				local reviewer, request = W.open(f, assert(W.review(f, b)))
				assert(W.result(f, reviewer, request, "approved").ok)
			else
				check(#W.reviews(f) == 0 and #W.gates(f, "reviewer_unavailable") == 0 and #W.gates(f, "family_unknown") == 0,
					label .. ": no automatic review or reviewer availability gate")
				for _, w in f.authority.registry.dispatch.workers do check(w.role ~= "reviewer", label .. ": no reviewer worker") end
			end
			local lid = W.request(f, b, "cp-1", "rev-1"); assert(W.approve(f, lid).ok)
			local it = W.item(f, lid)
			if state == "empty" or state == "passed" then
				check(it.status == "granted" and it.proof.mode == mode[3] and #it.proof.check_refs == (if state == "empty" then 0 else 1),
					label .. ": independent predicates allow exact grant")
				local issued = assert(api.codec.decode_reply(W.grant(f, lid).bytes, W.worker(f, W.holder(f, lid))))
				check((issued.payload.review_id == nil) == (not mode[1]) and (issued.payload.reviewer_family == nil) == (not mode[1])
					and (issued.payload.proof.review_id == nil) == (not mode[1]), label .. ": review identity absent only when disabled")
				if not mode[1] then
					W.land(f, lid, "head-disabled")
					check(W.item(f, lid).status == "landed" and #W.reviews(f) == 0, label .. ": release manager lands without a reviewer")
				end
			else
				check(#it.grants == 0 and it.proof == nil and it.hold.code == ({ failed = "check_failed", missing = "check_missing", stale = "check_stale" })[state],
					label .. ": owner and reviewer approval cannot override checks")
			end
			local repairs = W.replies(f, b, "rework")
			check(#repairs == (if state == "failed" then 1 else 0), label .. ": only failed current checks trigger repair")
			if state == "failed" then
				local p = repairs[1].reply.payload
				check(p.review_id == nil and #p.findings == 0 and #p.failed_checks == 1 and p.failed_checks[1].check_id == "unit",
					label .. ": check-only repair never invents review findings or identity")
				-- Watermark polling also delivers the answered landing gate. Finish that setup before
				-- counting reply sequences so its owner_decision cannot masquerade as a second repair.
				W.settle(f, b, true)
				local approval = f.authority.registry.dispatch.gates[W.item(f, lid).gate_id]
				check(approval.delivery ~= nil and approval.delivery.published and #W.replies(f, b, "rework") == 1,
					label .. ": publishing the landing approval leaves exactly one repair")
				local repair_seq = W.worker(f, b).reply_seq
				W.drain(f, b); W.settle(f, b, true)
				check(#W.replies(f, b, "rework") == 0 and W.worker(f, b).reply_seq == repair_seq,
					label .. ": consuming the repair never issues a replacement")
				assert(W.send(f, b, "CHECK_RESULT", { check_id = "unit", argv_sha256 = api.codec.sha256("argv"), exit_code = 2,
					output_sha256 = api.codec.sha256("different failure"), head = W.hx("rev-1"), ran_at_ms = 2 }).ok)
				local ticked = f:tick()
				assert(ticked.ok, label .. ": workflow tick refused: " .. tostring(ticked.code) .. " " .. tostring(ticked.message))
				check(W.worker(f, b).reply_seq == repair_seq, label .. ": unchanged revision never launches repeated repair after consumption")
				check(#W.item(f, lid).grants == 0, label .. ": repeated failure remains blocked")
				if not mode[1] then
					assert(W.ready(f, b, "cp-2", "rev-2", 1).ok)
					check(W.worker(f, b).reply_seq == repair_seq + 1, label .. ": a new failed revision permits one new repair")
					W.settle(f, b)
					assert(W.send(f, b, "CHECK_RESULT", { check_id = "unit", argv_sha256 = api.codec.sha256("argv"), exit_code = 0,
						output_sha256 = api.codec.sha256("repaired"), head = W.hx("rev-2"), ran_at_ms = 3 }).ok)
					check(W.request(f, b, "cp-2", "rev-2") == lid, label .. ": repaired revision rebinds the held item")
					assert(W.approve(f, lid).ok)
					check(W.item(f, lid).status == "granted" and #W.reviews(f) == 0, label .. ": repair advances without review")
				end
			end
			W.rule_h(f); check(W.restores(f), label .. ": state restores")
		end
	end
end

-- Checkpoint 4: landing to the release manager (Contract I, Task 4A) and the fail-closed 0.3.0 upgrade.
function W.refreshes(f, id) return #W.replies(f, id, "landing_refresh") end
-- Rewrite one stored grant to the 0.3.0 shape: addressed to the requesting builder (re-enveloped,
-- closed 9-key payload), no holder or proof on the item, the release manager's copy removed.
function W.legacy(stored, lid)
	local d = stored.dispatch
	local it = d.landing.items[lid]; local g = it.grants[#it.grants]
	local manager, b = d.workers[g.worker_id], d.workers[it.worker_id]
	local reply = manager.replies[tostring(g.reply_seq)]; manager.replies[tostring(g.reply_seq)] = nil
	if manager.reply_seq == g.reply_seq then manager.reply_seq -= 1 end
	for index, entry in manager.workflow.thread do if entry.action_id == g.action_id then table.remove(manager.workflow.thread, index); break end end
	local raw = runtime.json.decode(g.bytes); local old = { version = 1, payload = {} }
	for _, key in { "logical_session_id", "worker_id", "worker_generation", "launch_request_id", "work_id" } do old[key] = b[key] end
	for _, key in { "message_id", "action_id", "action_revision", "kind" } do old[key] = raw[key] end
	for key in ("landing_id grant_id project_id checkpoint_id repo_ref target_ref target_revision source_ref source_revision"):gmatch("%S+") do old.payload[key] = raw.payload[key] end
	b.reply_seq += 1; old.reply_seq = b.reply_seq
	local bytes = runtime.json.encode(old)
	g.bytes = bytes; g.worker_id = b.worker_id; g.reply_seq = b.reply_seq; it.proof = nil; it.holder = nil
	-- codec.frame refuses legacy bytes (it decodes under Contract D); the validator checks only digest, length and chunk count.
	local chunks = {}; for offset = 1, #bytes, 2048 do table.insert(chunks, bytes:sub(offset, offset + 2047)) end
	reply.bytes = bytes; reply.sha256 = api.codec.sha256(bytes); reply.reply_seq = b.reply_seq
	reply.frames = { manifest = reply.frames.manifest, chunks = chunks, message_sha256 = reply.sha256, message_bytes = #bytes }
	b.replies[tostring(b.reply_seq)] = reply
end

if section == nil or section == "release_config" then
	-- Configuration and signer refusals: an otherwise grantable item is held and nothing is granted.
	for _, case in { { "", "release_manager_missing" }, { "builder", "release_manager_is_builder" }, { "codex", "release_manager_is_reviewer" } } do
		local f = W.fixture({ reviewer_records = W.arr({ "codex" }), release_manager_record = case[1] })
		local b = W.builder(f)
		W.round(f, b, "cp-1", "rev-1", "approved")
		local lid = W.request(f, b, "cp-1", "rev-1")
		assert(W.approve(f, lid).ok)
		local it = W.item(f, lid)
		check(it.hold ~= nil and it.hold.code == case[2] and #it.grants == 0 and W.rm_id(f) == nil,
			"release manager record '" .. case[1] .. "': held " .. case[2] .. " (got " .. tostring(it.hold and it.hold.code) .. "), nothing launched or granted")
		check(W.restores(f), "a " .. case[2] .. " hold restores")
	end
	for _, case in { { "", "release_manager_missing" }, { "builder", "release_manager_is_builder" } } do
		local f = W.fixture({ require_code_review = false, reviewer_records = W.arr(), release_manager_record = case[1] })
		local b = W.builder(f); assert(W.ready(f, b, "cp-disabled", "rev-disabled", 0).ok)
		local lid = W.request(f, b, "cp-disabled", "rev-disabled"); assert(W.approve(f, lid).ok)
		check(W.item(f, lid).hold.code == case[2] and #W.item(f, lid).grants == 0 and #W.reviews(f) == 0,
			"review disabled: signer validation is nil-safe and still refuses " .. case[2])
		check(W.restores(f), "review-disabled signer refusal restores")
	end
	do
		local f = W.fixture({ merge_actor_mode = "worker", release_manager_record = "", reviewer_records = W.arr({ "codex" }) })
		local b, lid = W.granted(f, "existing-builder")
		check(W.holder(f, lid) == b and W.rm_id(f) == nil and W.grant(f, lid).worker_id == b, "worker mode grants the exact existing builder without a manager launch")
		check(W.item(f, lid).proof.review_id ~= nil and W.worker(f, b).role == "builder", "worker merge preserves independent review and builder identity")
		W.land(f, lid, W.hx("landed-builder"))
		check(W.attempt(f, lid).worker_id == b and W.rm_id(f) == nil, "deployment also stays with the exact existing builder")
		check(W.deploy_result(f, lid, "not_applicable", { reason = "No deployment is defined." }).ok, "the grant-bound builder's exact deploy result is consumed")
		check(W.restores(f), "worker merge and deploy proof restore with bound identities")
		local missing = W.fixture({ merge_actor_mode = "worker", release_manager_record = "", require_code_review = false })
		local queued = missing:allow_shared_fixture(missing:apply("queue", { record_id = "builder", record_revision = 0, catalog_revision = 0,
			prompt = "Complete the bounded capability fixture.", cwd = "/fixture", placement = "split", coordinator = false, checks = W.unit() }))
		assert(queued.ok and queued.action_id, queued.message)
		local worker = W.start(missing, queued.worker_id, queued.action_id, { "report-files-v1", "native-ask-v1", "check-runner-v1" })
		assert(W.ready(missing, worker, "capability-checkpoint", "capability-revision", 0).ok)
		local held = W.request(missing, worker, "capability-checkpoint", "capability-revision")
		assert(W.approve(missing, held).ok)
		check(#W.item(missing, held).grants == 0 and W.item(missing, held).hold.code == "capability_missing" and W.rm_id(missing) == nil,
			"a configured record label never substitutes for this builder mailbox's real release capability, and no extra manager starts")
		check(W.restores(missing), "missing worker merge capability remains an actionable durable hold")
	end
	do
		local patch = { merge_actor_mode = "selected_record", release_manager_record = "kimi", require_code_review = false,
			auto_approve_kinds = W.arr(), concurrency_limit = 32 }
		local f = W.fixture(patch)
		local sid = "headroom-second-session"
		assert(f.authority:apply(f:state_event("register_session", { orch_session_id = sid, name = "Second selected release owner" })).ok)
		local admitted = f.authority:apply(f:state_event("admit_controller", { orch_session_id = sid,
			pane_binding = { host_pane_id = "43", alias_nonce = "headroom-second-controller" } }))
		assert(admitted.ok, admitted.message)
		local other = table.clone(f)
		other.origin = { logical_session_id = sid, owner_id = admitted.owner_id, owner_generation = admitted.generation,
			host_pane_id = "43", alias_nonce = "headroom-second-controller", window_key = "", window_epoch = "headroom-second-window",
			native_session_id = "7", window_host_id = "local" }
		other.controller_pane, other.command_seq, other.default_project = "9003", nil, nil
		assert(other:control("admit_session").ok); W.catalog(other)
		assert(other:apply("policy", { policy = patch }).ok)
		W.repository(other, "/fixture/repository/.git", "refs/heads/second", "orch_queue")
		local first, second = W.builder(f), W.builder(other)
		local function queue()
			return f:allow_shared_fixture(f:apply("queue", { record_id = "builder", record_revision = 0, catalog_revision = 0,
				prompt = "Wait for the bounded capacity assignment.", cwd = "/fixture", placement = "split", coordinator = false }))
		end
		for _ = 1, 11 do local queued = queue(); assert(queued.ok and queued.action_id, queued.message) end
		local held = queue(); assert(held.ok, held.message)
		check(held.code == "task_held" and held.action_id == nil and W.worker(f, held.worker_id).reason.code == "waiting_for_agent_space",
			"two active selected-actor sessions preserve two future manager slots and one shared progress slot within the physical sixteen-generation domain")
		assert(W.ready(f, first, "headroom-first", "headroom-first", 0).ok)
		local one = W.request(f, first, "headroom-first", "headroom-first", "refs/heads/main"); assert(W.approve(f, one).ok)
		assert(W.ready(other, second, "headroom-second", "headroom-second", 0).ok)
		local two = W.request(other, second, "headroom-second", "headroom-second", "refs/heads/second"); assert(W.approve(other, two).ok)
		check(W.holder(f, one) == W.rm_id(f) and W.holder(other, two) == W.rm_id(other)
			and W.rm_id(f) ~= W.rm_id(other) and #W.item(f, one).grants == 1 and #W.item(other, two).grants == 1,
			"both selected release actors really provision and obtain independent exact target grants despite held ordinary work")
		check(W.provision_of(f, held.worker_id) == nil and W.restores(f), "reserved progress never releases another ordinary launch or loses held work on restore")
	end
end
if section == nil or section == "release_launch" then
	-- The first grantable head queues the session's release manager; one without release-manager-v1 is never granted.
	do
		local f = W.fixture({ reviewer_records = W.arr({ "codex" }) })
		local b = W.builder(f); W.round(f, b, "cp-1", "rev-1", "approved")
		local lid = W.request(f, b, "cp-1", "rev-1")
		local gate = f.authority.registry.dispatch.gates[W.item(f, lid).gate_id]
		assert(f:apply("answer", { gate_id = gate.id, gate_revision = gate.revision, choice_id = "approve", answer = "Owner approves." }).ok)
		local rm = W.rm_id(f)
		check(rm ~= nil and W.worker(f, rm).record_id == "kimi" and W.worker(f, rm).phase == "queued" and W.item(f, lid).hold.code == "release_manager_starting"
			and #W.item(f, lid).grants == 0, "the first grantable item queues the session's release manager and waits for it")
		W.rm(f, { "report-files-v1", "native-ask-v1" })
		check(W.item(f, lid).hold.code == "capability_missing" and #W.item(f, lid).grants == 0, "a release manager provisioned without release-manager-v1 is never granted")
		check(f:apply("queue", { record_id = "kimi", record_revision = 0, catalog_revision = 0, prompt = "Merge things.", cwd = "/fixture", placement = "split",
			coordinator = false, role = "release_manager" }).code == "invalid_assignment", "the owner cannot queue a release manager by hand")
		check(W.restores(f), "a capability-held release manager restores")
	end
end
if section == nil or section == "release_refresh" then
	local f = W.fixture({ reviewer_records = W.arr({ "codex" }) })
	local a, la = W.granted(f, "cp-a")
	local b = W.builder(f); W.round(f, b, "cp-b", "rev-cp-b", "approved")
	local lb = W.request(f, b, "cp-b", "rev-cp-b"); assert(W.approve(f, lb).ok)
	local rm = W.holder(f, la)
	local it = W.item(f, la)
	check(rm ~= nil and W.worker(f, rm).role == "release_manager" and it.worker_id == a and it.holder.worker_generation == W.worker(f, rm).worker_generation
		and W.grant(f, la).worker_id == rm, "the grant is held by the release manager generation; the builder stays the requester")
	local issued = W.replies(f, rm, "landing_grant")
	check(#issued == 1 and issued[1].reply.payload.landing_id == la and issued[1].reply.payload.builder_work_id == W.worker(f, a).work_id
		and issued[1].reply.payload.reviewer_family == "openai" and issued[1].reply.payload.review_id == it.proof.review_id
		and issued[1].reply.payload.proof.mode == "cross_family_review", "the release manager's landing_grant carries builder work, review, reviewer family and proof")
	check(#W.replies(f, a, "landing_grant") == 0 and #W.replies(f, b, "landing_grant") == 0, "no builder receives a landing_grant")
	check(W.item(f, lb).status == "ready" and #W.item(f, lb).grants == 0, "one slot per target: the second item waits")
	-- Builder LANDING_RESULT refused; only the holder settles the grant.
	check(W.landing_result(f, a, la, "landed", { result_revision = "head-1" }).code == "binding_mismatch" and W.grant(f, la).result == nil,
		"the requesting builder's LANDING_RESULT is refused")
	check(W.landing_result(f, b, la, "landed", { result_revision = "head-1" }).code == "binding_mismatch", "another builder's LANDING_RESULT is refused")
	-- Target moved → one refresh to the builder → approval voided → fresh review required.
	local rv_b = W.review(f, b)
	W.land(f, la, "head-1")
	check(W.item(f, lb).hold.code == "target_moved" and W.refreshes(f, b) == 1 and W.refreshes(f, rm) == 0,
		"target_moved sends exactly one landing_refresh, to the builder")
	local void = f.authority.registry.dispatch.reviews[rv_b.review_id].void
	check(void ~= nil and void.target_revision == "head-1" and void.artifact_revision == nil,
		"the refresh voids the builder's review approval on the moved target head (void.target_revision), not as an artifact revision")
	W.settle(f, b); assert(W.send(f, b, "HEARTBEAT", { state = "working" }).ok)
	check(W.refreshes(f, b) == 1, "later commits never duplicate the refresh")
	W.settle(f, b); assert(W.send(f, b, "CHECKPOINT", W.cp("cp-b2", "rev-b2")).ok)
	check(W.request(f, b, "cp-b2", "rev-b2", nil, "head-1") == lb and W.item(f, lb).hold.code == "check_stale"
		and W.item(f, lb).approval == nil and #W.item(f, lb).grants == 0, "the refreshed revision needs a fresh review before any grant")
	W.round(f, b, "cp-b2", "rev-b2", "approved")
	check(W.item(f, lb).hold.code == "approval_pending", "after the fresh review only the owner approval remains")
	assert(W.approve(f, lb).ok)
	check(W.item(f, lb).status == "granted" and W.grant(f, lb).target_revision == "head-1" and W.holder(f, lb) == rm, "the fresh approval grants against the new head")
	-- stale_target → the same single refresh obligation.
	local rv_b2 = W.review(f, b)
	assert(W.ack(f, rm, W.grant(f, lb)).ok)
	check(W.landing_result(f, rm, lb, "stale_target", { observed_target_revision = "head-7" }).ok and W.item(f, lb).hold.code == "refresh_required",
		"the release manager's stale_target result leaves the item needing refresh")
	local void2 = f.authority.registry.dispatch.reviews[rv_b2.review_id].void
	check(W.refreshes(f, b) == 2 and void2 ~= nil and void2.target_revision == "head-7" and void2.artifact_revision == nil,
		"stale_target sends exactly one more landing_refresh to the builder and voids its approval on the observed head")
	W.settle(f, b); assert(W.send(f, b, "CHECKPOINT", W.cp("cp-b3", "rev-b3")).ok)
	check(W.request(f, b, "cp-b3", "rev-b3", nil, "head-7") == lb and W.item(f, lb).hold.code == "check_stale"
		and #W.item(f, lb).grants == 1, "the stale_target refresh also requires a fresh review")
	check(W.restores(f), "refreshed and regranted release state restores")
	-- Restore validates each void pattern: {artifact_revision} (new checkpoint, and every pre-8C record) or {target_revision}.
	local function with_void(v)
		local reg = api.clone(f.authority.registry); reg.dispatch.reviews[rv_b.review_id].void = v
		return api.state.rehydrate(reg) ~= nil
	end
	check(with_void({ artifact_revision = "head-1", at_ms = 0 }) and with_void({ target_revision = "head-1", at_ms = 0 }),
		"a stored void restores in either pattern (artifact_revision keeps its pre-8C meaning)")
	check(not with_void({ artifact_revision = "x", target_revision = "head-1", at_ms = 0 }) and not with_void({ at_ms = 0 }) and not with_void({ target_revision = 7, at_ms = 0 }),
		"a void naming both, neither or a malformed revision is refused at restore")
	-- With review off, the same stale-target workflow uses checks and owner approval, never review.
	do
		local t = W.fixture({ require_code_review = false, reviewer_records = W.arr() })
		local tb = W.builder(t); assert(W.ready(t, tb, "cp-off", "rev-off", 0).ok)
		local lid = W.request(t, tb, "cp-off", "rev-off"); assert(W.approve(t, lid).ok)
		local holder = W.holder(t, lid); assert(W.ack(t, holder, W.grant(t, lid)).ok)
		assert(W.landing_result(t, holder, lid, "stale_target", { observed_target_revision = "head-off" }).ok)
		W.settle(t, tb); assert(W.send(t, tb, "CHECKPOINT", W.cp("cp-off-new", "rev-off-new")).ok)
		check(W.request(t, tb, "cp-off-new", "rev-off-new", nil, "head-off") == lid
			and W.item(t, lid).hold.code == "check_stale" and #W.item(t, lid).grants == 1,
			"disabled review refresh still refuses the old revision's passing helper check")
		assert(W.send(t, tb, "CHECK_RESULT", { check_id = "unit", argv_sha256 = api.codec.sha256("argv"), exit_code = 0,
			output_sha256 = api.codec.sha256("check output"), head = W.hx("rev-off-new"), ran_at_ms = 1 }).ok)
		assert(W.approve(t, lid).ok)
		check(W.item(t, lid).status == "granted" and #W.item(t, lid).grants == 2 and #W.reviews(t) == 0
			and W.item(t, lid).proof.mode == "review_disabled" and W.grant(t, lid).target_revision == "head-off",
			"fresh checks and owner approval regrant the new revision directly without any reviewer")
		check(W.restores(t), "review-disabled refresh and regrant restore")
	end
end

if section == nil or section == "release_holder" then
	-- Holder rollover: an uncertain grant stays on the generation that claimed it.
	do
		local g = W.fixture({ reviewer_records = W.arr({ "codex" }) })
		local _, lu = W.granted(g, "cp-u")
		local old = W.holder(g, lu); local generation = W.item(g, lu).holder.worker_generation
		assert(W.ack(g, old, W.grant(g, lu)).ok)
		check(g:apply("rollover", { worker_id = old, trigger = "owner" }).code == "landing_in_progress", "a live grant pins its release manager against rollover")
		check(W.landing_result(g, old, lu, "uncertain", { reason = "Push timed out before the remote answered" }).ok and W.grant(g, lu).uncertain ~= nil,
			"the release manager reports the landing uncertain")
		assert(g:apply("observe", { worker_id = old, pane_binding = api.clone(W.worker(g, old).pane_binding), native_state = "idle" }).ok)
		local rolled = g:apply("rollover", { worker_id = old, trigger = "owner" })
		check(rolled.ok and W.item(g, lu).holder.worker_id == old and W.item(g, lu).holder.worker_generation == generation and W.grant(g, lu).worker_id == old,
			"an uncertain-only release manager may roll over; the grant stays on the generation that claimed it (" .. tostring(rolled.code) .. ")")
		for key, w in g.authority.registry.dispatch.workers do
			if w.role == "release_manager" and key ~= old then check(#W.replies(g, key, "landing_grant") == 0, "a release-manager successor never inherits the issued grant") end
		end
		check(g:apply("reconcile_landing", { landing_id = lu, landing_revision = W.item(g, lu).revision, outcome = "landed", target_revision = "head-1",
			reason = "Inspected the remote target log read-only", operator_verified = true }).ok and W.item(g, lu).status == "landed", "the owner reconciles the uncertain grant read-only")
		check(W.restores(g), "the reconciled uncertain grant restores")
	end
	-- Current grant stores cannot invoke historical upgrade by re-addressing immutable grant bytes.
	do
		local g = W.fixture({ reviewer_records = W.arr({ "codex" }) })
		local lbid, ll = W.granted(g, "cp-l")
		local stored = api.clone(g.memory.value); W.legacy(stored, ll)
		local exact, writes = runtime.json.encode(stored), g.memory.writes
		g.memory.value = stored; g.authority = api.host.new_authority(g.memory)
		local loaded = g.authority:load()
		check(not loaded.ok and loaded.code == "state_corrupt", "an obsolete builder-addressed grant injected into the current store fails closed")
		check(g.memory.writes == writes and runtime.json.encode(g.memory.value) == exact, "failed current grant validation preserves exact bytes and invents no historical holder")
	end
	-- A reviewed grant with inconsistent immutable review identities must block before validation.
	do
		local g = W.fixture({ reviewer_records = W.arr({ "codex" }) })
		local _, lid = W.granted(g, "cp-mismatch")
		local stored = api.clone(g.memory.value)
		local grant = stored.dispatch.landing.items[lid].grants[1]
		local raw = runtime.json.decode(grant.bytes)
		raw.payload.review_id = "review-mismatched"
		local bytes = runtime.json.encode(raw)
		grant.bytes = bytes
		local retained = stored.dispatch.workers[grant.worker_id].replies[tostring(grant.reply_seq)]
		retained.bytes = bytes; retained.sha256 = api.codec.sha256(bytes)
		local chunks = {}; for offset = 1, #bytes, 2048 do table.insert(chunks, bytes:sub(offset, offset + 2047)) end
		retained.frames = { manifest = retained.frames.manifest, chunks = chunks, message_sha256 = retained.sha256, message_bytes = #bytes }
		local exact = runtime.json.encode(stored)
		local restored = api.state.rehydrate(stored)
		check(restored == nil, "a current immutable grant with a different review identity is invalid, not a request for legacy migration")
		check(runtime.json.encode(stored) == exact and grant.bytes == bytes and retained.bytes == bytes,
			"blocked restore leaves the complete snapshot and both immutable grant copies unchanged")
		g.memory.value = api.clone(stored)
		local writes = g.memory.writes
		g.authority = api.host.new_authority(g.memory)
		local loaded = g.authority:load()
		check(not loaded.ok and loaded.code == "state_corrupt", "cold authority load rejects the malformed current immutable grant")
		check(g.memory.writes == writes and runtime.json.encode(g.memory.value) == exact, "blocked authority load never rewrites the persisted grant")
	end
end

-- A proven, owner-approved request on its own target, granted and landed at head-<cp_id>; returns
-- the landing id and its deploy (one attempt).
function W.landed(f, cp_id)
	local live = W.rm_id(f); if live then W.drain(f, live) end
	local _, lid = W.granted(f, cp_id, "refs/heads/" .. cp_id); W.land(f, lid, "head-" .. cp_id)
	local dep = W.deploy(f, lid)
	assert(W.item(f, lid).status == "landed" and dep ~= nil and #dep.attempts == 1, "landed opened no deploy attempt")
	return lid, dep
end
if section == nil or section == "deploy" then
	do
		local stop = W.fixture({ merge_actor_mode = "worker", release_manager_record = "", reviewer_records = W.arr({ "codex" }) })
		local builder, lid = W.granted(stop, "pending-stop")
		assert(W.ack(stop, builder, W.grant(stop, lid)).ok); assert(stop:apply("pause").ok)
		assert(W.landing_result(stop, builder, lid, "landed", { result_revision = W.hx("pending-stop-landed") }).ok)
		check(W.deploy(stop, lid).status == "pending" and #W.deploy(stop, lid).attempts == 0, "pause preserves a real completed merge with an unissued deployment")
		assert(stop:apply("observe", { worker_id = builder, pane_binding = api.clone(W.worker(stop, builder).pane_binding), native_state = "exited" }).ok)
		assert(stop:apply("resume").ok)
		check(W.deploy(stop, lid).status == "pending" and W.deploy(stop, lid).hold ~= nil and W.rm_id(stop) == nil,
			"an absent current builder leaves deployment actionably held without another manager launch")
		local old = W.item(stop, lid).revision
		check(not stop:apply("cancel_landing", { landing_id = lid, landing_revision = old - 1 }).ok, "stopping pending deployment still requires the exact current item revision")
		assert(stop:apply("cancel_landing", { landing_id = lid, landing_revision = old }).ok)
		check(W.item(stop, lid).status == "landed" and W.deploy(stop, lid).status == "stopped" and #W.deploy(stop, lid).attempts == 0
			and W.deploy(stop, lid).revision == W.hx("pending-stop-landed") and W.restores(stop),
			"owner stops only the unissued deployment; the exact completed merge remains intact and durable")
	end
	do
		local f = W.fixture({ merge_actor_mode = "worker", release_manager_record = "", reviewer_records = W.arr({ "codex" }) })
		local builder, lid = W.granted(f, "pending-successor")
		assert(W.ack(f, builder, W.grant(f, lid)).ok); assert(f:apply("pause").ok)
		assert(W.landing_result(f, builder, lid, "landed", { result_revision = W.hx("successor-landed") }).ok)
		assert(f:apply("observe", { worker_id = builder, pane_binding = api.clone(W.worker(f, builder).pane_binding), native_state = "idle" }).ok)
		local rollover = f:apply("rollover", { worker_id = builder, trigger = "owner" }); assert(rollover.ok, rollover.message)
		assert(f:apply("resume").ok)
		local request = api.clone(W.worker(f, builder).workflow.report_request); assert(request)
		assert(W.ack(f, builder, request).ok)
		local cp = W.cp("pending-successor-handover", "rev-pending-successor"); cp.request_id = request.request_id
		assert(W.send(f, builder, "CHECKPOINT", cp).ok)
		local successor = assert(f.authority.registry.dispatch.rollovers[rollover.handover_id].successor_worker_id)
		W.start(f, successor, assert(W.provision_of(f, successor)))
		check(W.deploy(f, lid).status == "pending" and #W.deploy(f, lid).attempts == 0,
			"an active predecessor/successor handover keeps the already-landed deployment pending")
		W.settle(f, builder, true)
		local stopped = f:apply("poll", { worker_id = builder }); assert(stopped.ok, stopped.message)
		assert(f:action(stopped.action_id).request.op == "stop")
		assert(f:finish(stopped.action_id, "stopped", { pane_binding = api.clone(f:action(stopped.action_id).request.pane_binding), observation = "exited" }).ok)
		check(W.attempt(f, lid) and W.attempt(f, lid).worker_id == successor and W.rm_id(f) == nil
			and W.item(f, lid).worker_id == builder and W.grant(f, lid).worker_id == builder
			and W.deploy(f, lid).revision == W.hx("successor-landed"),
			"after the exact predecessor exit, the accepted same-work successor receives only the pending deployment; original merge/proof identities stay unchanged")
		assert(W.deploy_result(f, lid, "not_applicable", { reason = "This landed fixture has no deployment." }).ok)
		check(#W.deploy(f, lid).attempts == 1 and W.restores(f), "successor deployment settles exactly once without merge replay or an extra actor")
	end
	-- Contract J: after landed, one deploy_grant per attempt to the release manager.
	local f = W.fixture({ reviewer_records = W.arr({ "codex" }), loop_cap = 2 })
	local ld, dep = W.landed(f, "cp-d")
	local rm = W.holder(f, ld)
	local grants = W.replies(f, rm, "deploy_grant")
	check(#grants == 1 and grants[1].reply.payload.deploy_id == dep.deploy_id and grants[1].reply.payload.landing_id == ld and grants[1].reply.payload.revision == "head-cp-d"
		and grants[1].reply.payload.target_ref == "refs/heads/cp-d" and grants[1].reply.payload.attempt_id == dep.attempts[1].attempt_id,
		"landed issues exactly one deploy_grant for exactly the landed revision to the release manager")
	check(dep.status == "granted" and W.item(f, ld).status == "landed", "landed stays terminal for the merge while the deploy is granted")
	check(W.deploy_result(f, ld, "deployed", { revision = "head-other" }).code == "revision_mismatch", "a DEPLOY_RESULT must name the granted revision")
	check(W.deploy_result(f, ld, "deployed").ok and W.deploy(f, ld).status == "deployed" and W.attempt(f, ld).status == "deployed", "deployed settles the deploy")
	check(not W.deploy_result(f, ld, "failed").ok and W.deploy(f, ld).status == "deployed" and #W.deploy(f, ld).attempts == 1, "one attempt has one result")
	local ln = W.landed(f, "cp-n")
	check(W.deploy_result(f, ln, "not_applicable", { reason = "The repository defines no deploy" }).ok and W.deploy(f, ln).status == "not_applicable",
		"not_applicable settles the deploy")
	check(W.restores(f), "deployed and not_applicable deploys restore")
end
-- Contract J, continued (own section: the native slice budget). held → deploy_hold gate; the owner's
-- answer is relayed to the release manager.
if section == nil or section == "deploy_held" then
	local f = W.fixture({ reviewer_records = W.arr({ "codex" }), loop_cap = 2 })
	local lh = W.landed(f, "cp-h")
	local rm = W.holder(f, lh)
	check(W.deploy_result(f, lh, "held", { reason = "A database migration needs the owner" }).ok and W.deploy(f, lh).status == "held", "held parks the deploy")
	local hold = W.gates(f, "deploy_hold")
	check(#hold == 1 and hold[1].worker_id == rm, "held opens one deploy_hold gate on the release manager")
	local before = #W.replies(f, rm, "owner_decision")
	check(f:apply("answer", { gate_id = hold[1].id, gate_revision = hold[1].revision, choice_id = "deploy", answer = "Migration reviewed; deploy." }).ok
		and W.attempt(f, lh).status == "granted" and #W.deploy(f, lh).attempts == 1, "the owner's deploy answer resumes the same attempt")
	-- The answered gate is relayed as owner_decision on the release manager's next poll.
	for _ = 1, 8 do
		if #W.replies(f, rm, "owner_decision") > before then break end
		local polled = f:apply("poll", { worker_id = rm }); assert(polled.ok, polled.message)
		if not polled.action_id then break end
		local op = f:action(polled.action_id).request.op
		assert(f:finish(polled.action_id, if op == "mailbox_retire" then "compacted" elseif op == "mailbox_read" then "missing" else "published", {}).ok)
	end
	check(#W.replies(f, rm, "owner_decision") == before + 1 and #W.deploy(f, lh).attempts == 1, "the owner's answer is relayed to the release manager as owner_decision")
	check(W.deploy_result(f, lh, "deployed").ok and W.deploy(f, lh).status == "deployed", "the held attempt then reports its final result")
	check(W.restores(f), "a held then deployed deploy restores")
end

-- Contract J, continued (own section: the native slice budget). failed → a new attempt only on the
-- owner's answer, capped by loop_cap.
if section == nil or section == "deploy_retry" then
	local f = W.fixture({ reviewer_records = W.arr({ "codex" }), loop_cap = 2 })
	local _, lf = W.granted(f, "cp-f", "refs/heads/cp-f"); W.land(f, lf, "head-cp-f")
	local rm = W.holder(f, lf)
	check(W.deploy_result(f, lf, "failed", { reason = "Health check failed" }).ok and W.deploy(f, lf).status == "failed" and #W.deploy(f, lf).attempts == 1,
		"failed never retries by itself")
	W.settle(f, rm); assert(W.send(f, rm, "HEARTBEAT", { state = "working" }).ok)
	check(#W.deploy(f, lf).attempts == 1, "later commits issue no new attempt")
	local retry = {}
	for _, gate in W.gates(f, "deploy_hold") do if gate.phase == "pending" then table.insert(retry, gate) end end
	W.drain(f, rm)
	local first_attempt = W.attempt(f, lf).attempt_id
	check(#retry == 1 and f:apply("answer", { gate_id = retry[1].id, gate_revision = retry[1].revision, choice_id = "retry", answer = "Retry once." }).ok,
		"the owner answers retry on the failed deploy")
	for _ = 1, 8 do
		if #W.deploy(f, lf).attempts == 2 then break end
		local polled = f:apply("poll", { worker_id = rm }); assert(polled.ok, polled.message)
		if not polled.action_id then break end
		local op = f:action(polled.action_id).request.op
		assert(f:finish(polled.action_id, if op == "mailbox_retire" then "compacted" elseif op == "mailbox_read" then "missing" else "published", {}).ok)
	end
	check(#W.deploy(f, lf).attempts == 2 and W.attempt(f, lf).status == "granted" and W.attempt(f, lf).attempt_id ~= first_attempt,
		"the retry answer issues exactly one new attempt with a new deploy_grant (attempts: " .. #W.deploy(f, lf).attempts .. ")")
	check(W.deploy_result(f, lf, "failed", { reason = "Health check failed again" }).ok and #W.deploy(f, lf).attempts == 2, "the second attempt fails")
	local capped = W.gates(f, "loop_cap")
	check(#capped == 1 and W.deploy(f, lf).loop ~= nil and W.deploy(f, lf).loop.state == "gated" and #W.deploy(f, lf).attempts == 2,
		"loop_cap 2: the failure at the cap stops at a loop_cap gate instead of another attempt")
	check(W.restores(f), "failed and capped deploys restore")
end

-- Lost result → uncertain → read-only reconcile, never re-granted.
if section == nil or section == "deploy_lost" then
	local f = W.fixture({ reviewer_records = W.arr({ "codex" }) })
	local _, lu = W.granted(f, "cp-u", "refs/heads/cp-u"); W.land(f, lu, "head-cp-u")
	local rm = W.holder(f, lu)
	local grants_before = #W.replies(f, rm, "deploy_grant")
	check(f:apply("landing_lost", { landing_id = lu, landing_revision = W.item(f, lu).revision, reason = "Release manager went silent mid-deploy" }).ok
		and W.attempt(f, lu).status == "uncertain" and W.deploy(f, lu).status == "uncertain", "the owner holds a silent deploy as uncertain")
	W.settle(f, rm); assert(W.send(f, rm, "HEARTBEAT", { state = "working" }).ok)
	check(#W.replies(f, rm, "deploy_grant") == grants_before and #W.deploy(f, lu).attempts == 1, "an uncertain deploy is never re-granted")
	check(not f:apply("reconcile_landing", { landing_id = lu, landing_revision = W.item(f, lu).revision,
		outcome = "deployed", current_target_revision = "unrelated-head", reason = "Inspected the service read-only", operator_verified = true }).ok
		and W.deploy(f, lu).status == "uncertain", "deploy reconciliation refuses landing-only current-head evidence")
	check(f:apply("reconcile_landing", { landing_id = lu, landing_revision = W.item(f, lu).revision, outcome = "deployed", reason = "Inspected the service read-only",
		operator_verified = true }).ok and W.deploy(f, lu).status == "deployed" and W.attempt(f, lu).reconciliation ~= nil, "read-only reconcile settles the uncertain deploy")
	W.deploy_result(f, lu, "failed", { reason = "Late report" })
	check(W.deploy(f, lu).status == "deployed" and #W.deploy(f, lu).attempts == 1, "a late DEPLOY_RESULT changes nothing")
	check(W.restores(f), "uncertain and reconciled deploys restore")
	-- Exited release manager → result_lost, never re-granted.
	local g = W.fixture({ reviewer_records = W.arr({ "codex" }) }, function() return { now_ms = 1000, mono_ms = 1000, epoch = "deploy-host" } end)
	local _, gl = W.granted(g, "cp-x"); W.land(g, gl, "head-x")
	local grm = W.holder(g, gl)
	assert(g:apply("observe", { worker_id = grm, pane_binding = api.clone(W.worker(g, grm).pane_binding), native_state = "exited" }).ok)
	check(W.attempt(g, gl).status == "uncertain" and W.attempt(g, gl).uncertain.code == "result_lost" and #W.deploy(g, gl).attempts == 1,
		"a release manager that exits mid-deploy leaves the attempt uncertain (result_lost), never re-granted")
	check(W.restores(g), "a lost deploy restores")
end

-- Status × operation grid for landing items: {queued, approved, granted, landed, deploy_held} ×
-- {new revision, target moved, release manager rollover, cancel}; one section per cell
-- (grid_<status>_<op>, within the native slice budget), each with a live release manager (an earlier
-- item on another target landed and deployed).
W.GRID = { grid_queued = "queued", grid_approved = "approved", grid_granted = "granted", grid_landed = "landed", grid_deploy_held = "deploy_held" }
W.GRID_OPS = { "new_revision", "target_moved", "rm_rollover", "cancel" }
W.GRID_DEPLOY = { landed = "granted", deploy_held = "held" }
if section == nil or string.sub(section, 1, 5) == "grid_" then
	for name, status in W.GRID do
		for _, op in W.GRID_OPS do
			if section == nil or section == name .. "_" .. op then
				local label = status .. " × " .. op
				local f = W.fixture({ reviewer_records = W.arr({ "codex" }) })
				local _, lo = W.granted(f, "cp-o", "refs/heads/other"); W.land(f, lo, "other-1")
				assert(W.deploy_result(f, lo, "deployed").ok)
				local rm = W.rm_id(f)
				-- queued/approved cells keep an unapproved request at the queue head so this one is never granted.
				local front, lfront
				if status == "queued" or status == "approved" then
					front = W.builder(f); W.round(f, front, "cp-f", "rev-cp-f", "approved"); lfront = W.request(f, front, "cp-f", "rev-cp-f")
				end
				local b = W.builder(f); W.round(f, b, "cp-g", "rev-cp-g", "approved")
				local lid = W.request(f, b, "cp-g", "rev-cp-g")
				if status ~= "queued" then assert(W.approve(f, lid).ok) end
				if status == "landed" or status == "deploy_held" then W.land(f, lid, "head-1") end
				if status == "deploy_held" then assert(W.deploy_result(f, lid, "held", { reason = "Service unit change needs the owner" }).ok) end
				local it0 = api.clone(W.item(f, lid)); local grants0 = #it0.grants
				assert(({ queued = it0.status ~= "granted" and it0.approval == nil, approved = it0.status == "ready", granted = it0.status == "granted",
					landed = it0.status == "landed" and W.deploy(f, lid).status == "granted", deploy_held = it0.status == "landed" and W.deploy(f, lid).status == "held" })[status],
					label .. ": fixture did not reach " .. status)
				local head = if status == "landed" or status == "deploy_held" then "head-1" else "head-0"
				if op == "new_revision" then
					W.settle(f, b); assert(W.send(f, b, "CHECKPOINT", W.cp("cp-n", "rev-new")).ok)
					assert(W.checkout(f, b, "rev-new").ok)
					W.settle(f, b)
					local sent = W.send(f, b, "LANDING_REQUEST", { checkpoint_id = "cp-n", project_id = "project-one", repo_ref = "repo:fixture", target_ref = "refs/heads/main",
						target_revision = head, source_ref = "refs/heads/cp-n", source_revision = W.hx("rev-new") })
					local it = W.item(f, lid)
					if status == "queued" or status == "approved" then
						check(sent.ok and it.approval == nil and it.proof == nil and it.request.source_revision == W.hx("rev-new") and #it.grants == 0
							and it.hold.code == "check_stale", label .. ": the same item rebinds, approval voided, fresh checks and review required")
					elseif status == "granted" then
						check(sent.code == "landing_in_progress" and #it.grants == grants0 and it.request.source_revision == it0.request.source_revision,
							label .. ": refused while the release manager holds the grant")
					else
						check(it.status == "landed" and it.request.source_revision == it0.request.source_revision and W.deploy(f, lid).status == W.GRID_DEPLOY[status],
							label .. ": the landed item and its deploy are terminal for this request (" .. tostring(sent.code) .. ")")
					end
				elseif op == "target_moved" then
					if status == "queued" or status == "approved" then
						assert(W.approve(f, lfront).ok); W.land(f, lfront, "head-m")
						check(W.item(f, lid).hold.code == "target_moved" and W.refreshes(f, b) == 1 and #W.item(f, lid).grants == 0,
							label .. ": target_moved → one landing_refresh to the builder, never a grant")
					elseif status == "granted" then
						assert(W.ack(f, rm, W.grant(f, lid)).ok)
						assert(W.landing_result(f, rm, lid, "stale_target", { observed_target_revision = "head-9" }).ok)
						check(W.item(f, lid).hold.code == "refresh_required" and W.refreshes(f, b) == 1 and #W.item(f, lid).grants == grants0,
							label .. ": stale_target → one landing_refresh to the builder, no regrant")
					else
						local mover = W.builder(f); W.round(f, mover, "cp-m", "rev-cp-m", "approved")
						local lm = W.request(f, mover, "cp-m", "rev-cp-m", nil, "head-1"); assert(W.approve(f, lm).ok)
						W.land(f, lm, "head-m")
						check(W.item(f, lid).status == "landed" and W.refreshes(f, b) == 0 and W.deploy(f, lid).status == W.GRID_DEPLOY[status],
							label .. ": a landed item owes no refresh and its deploy is unaffected")
					end
				elseif op == "rm_rollover" then
					assert(f:apply("observe", { worker_id = rm, pane_binding = api.clone(W.worker(f, rm).pane_binding), native_state = "idle" }).ok)
					local rolled = f:apply("rollover", { worker_id = rm, trigger = "owner" })
					if status == "granted" then
						check(rolled.code == "landing_in_progress" and W.holder(f, lid) == rm, label .. ": the release manager holding a live grant is pinned")
					elseif status == "landed" or status == "deploy_held" then
						check(rolled.code == "deploy_in_progress" and #W.deploy(f, lid).attempts == 1, label .. ": the release manager with an open deploy attempt is pinned")
					else
						check(rolled.ok and #W.item(f, lid).grants == 0, label .. ": a release manager holding nothing may roll over; no grant is issued")
					end
				else
					local cancelled = f:apply("cancel_landing", { landing_id = lid, landing_revision = W.item(f, lid).revision })
					if status == "queued" or status == "approved" then
						check(cancelled.ok and W.item(f, lid).status == "cancelled" and #W.item(f, lid).grants == 0, label .. ": an ungranted item is cancelled")
					else
						check(cancelled.code == "landing_not_cancellable" and W.item(f, lid).status == it0.status, label .. ": refused (" .. tostring(cancelled.code) .. ")")
					end
				end
				check(W.restores(f), label .. ": restores")
			end
		end
	end
end

-- Checkpoint 5 (D8/D9): coordinator proposals {dispatch, report, review, landing} × {in plan scope,
-- out of scope} × {kind auto-approved or not}. Each cell has its own fixture: a planned builder
-- (source plan, declared scope.paths) or an out-of-scope one, an activated coordinator, one proposal.
W.PLAN = { kind = "plan", ref = "plan:fixture", revision = "plan-rev-1" }
-- Out-of-scope variants per kind and the in_scope code each must report.
W.OUT = { dispatch = { { source = { kind = "manual" } }, "source_not_planned" }, report = { { source = W.PLAN, scope = { paths = W.arr(), systems = W.arr() } }, "scope_undeclared" },
	review = { { source = { kind = "inbox", ref = "inbox:item" } }, "source_not_planned" }, landing = { { source = { kind = "manual" } }, "source_not_planned" } }
-- Queue, launch and activate a coordinator; returns its id and the proposal envelope fields.
function W.coordinator(f)
	local queued = f:apply("queue", { record_id = "omp", record_revision = 0, catalog_revision = 0, prompt = "Coordinate the fixture plan.", cwd = "/fixture",
		placement = "split", coordinator = true }); assert(queued.ok, queued.message)
	local id = W.start(f, queued.worker_id, queued.action_id)
	local w = W.worker(f, id); local activation = api.clone(w.activation)
	activation.message_id = api.codec.decode_reply(activation.bytes, w).message_id
	assert(W.ack(f, id, activation).ok, "coordinator activation ACK")
	return id
end
function W.propose(f, cid, kind, work_id, fields)
	W.pserial = (W.pserial or 0) + 1
	local w = W.worker(f, cid)
	local p = { owner_id = w.coordinator_owner_id, owner_generation = w.coordinator_generation, activation_token = w.activation.activation_token,
		proposal_id = "proposal-" .. kind .. "-" .. tostring(W.pserial), kind = kind, work_id = work_id, project_id = "project-one" }
	if kind == "new_work" or kind == "add_source" then p.work_id = nil; p.project_id = nil end
	for key, value in fields or {} do p[key] = value end
	W.settle(f, cid)
	return W.send(f, cid, "COORDINATOR_PROPOSAL", p)
end
function W.proposal_gate(f)
	local found = W.gates(f, "coordinator_proposal", false)
	assert(#found == 1, "expected one proposal gate"); return found[1]
end
-- Durable effects an execution may create: workers, reviews, report requests, landing approvals/grants.
function W.effects(f)
	local d, out = f.authority.registry.dispatch, {}
	for key, w in d.workers do table.insert(out, key .. ":" .. tostring(w.workflow and w.workflow.report_request and w.workflow.report_request.request_id)) end
	for key in d.reviews or {} do table.insert(out, "review:" .. key) end
	for key, it in (d.landing or {}).items or {} do table.insert(out, "landing:" .. key .. ":" .. tostring(it.approval ~= nil) .. ":" .. #it.grants) end
	table.sort(out); return table.concat(out, ",")
end
-- Idempotence: a workflow tick, an exact answer replay, a restore + tick twin and a cold start of the
-- host from the stored bytes leave the effects and the execution record unchanged.
function W.idempotent(f, label, gid, answer)
	local effects, execution = W.effects(f), runtime.json.encode(f.authority.registry.dispatch.gates[gid].execution)
	if answer then check(not f.authority:apply(api.clone(answer)).ok, label .. ": an already consumed subject cannot execute the old answer again") end
	assert(f:tick())
	check(W.effects(f) == effects and runtime.json.encode(f.authority.registry.dispatch.gates[gid].execution) == execution, label .. ": answer replay and tick never execute twice")
	local restored = assert(api.state.rehydrate(api.clone(f.authority.registry)), label .. ": restore")
	local twin = api.dispatch.tick(restored, { kind = "workflow_tick", authority_namespace = restored.authority_namespace,
		expected_revision = restored.revision }, { now_ms = 1, mono_ms = 1, epoch = "autonomy-twin" }) or restored
	check(runtime.json.encode(twin.dispatch.gates[gid].execution) == execution, label .. ": the restored twin keeps the execution record")
	local tf = { authority = { registry = twin } }
	check(W.effects(tf) == effects, label .. ": the restored twin's tick executes nothing again")
	f.authority = api.host.new_authority(f.memory); assert(f.authority:load().ok)
	assert(f:tick())
	check(W.effects(f) == effects and runtime.json.encode(f.authority.registry.dispatch.gates[gid].execution) == execution, label .. ": a cold start revisits the answered gate without executing again")
end
-- One cell. Returns nothing; every expectation is a check.
function W.autonomy_cell(kind, scoped, auto)
	local label = kind .. " × " .. (if scoped then "in scope" else "out of scope") .. " × " .. (if auto then "auto-approved" else "not auto-approved")
	local kinds = if auto then W.arr({ kind }) else W.arr()
	local f = W.fixture({ reviewer_records = W.arr({ "codex" }), auto_approve_kinds = kinds })
	local fields = if scoped then { source = W.PLAN, files = W.arr({ "src/feature.luau" }) } else W.OUT[kind][1]
	local b = W.builder(f, "builder", fields)
	local lid
	if kind == "landing" then
		W.round(f, b, "cp-1", "rev-1", "approved"); lid = W.request(f, b, "cp-1", "rev-1"); W.rm(f)
		local lg = f.authority.registry.dispatch.gates[W.item(f, lid).gate_id]
		if auto and scoped then
			check(lg.answer ~= nil and lg.answer.source.kind == "policy" and lg.answer.source.rule == "auto_approve:landing" and W.item(f, lid).approval ~= nil,
				label .. ": the proven in-scope landing approval is answered by session policy")
		else
			check(lg.answer == nil and W.item(f, lid).approval == nil and #W.item(f, lid).grants == 0, label .. ": the landing approval waits for the owner")
		end
	elseif kind == "review" then
		W.settle(f, b); assert(W.send(f, b, "CHECKPOINT", W.cp("cp-1", "rev-1")).ok)
	else
		W.settle(f, b); assert(W.send(f, b, "CHECKPOINT", W.cp("cp-1", "rev-1")).ok)
	end
	local cid = W.coordinator(f)
	local before = W.effects(f)
	local extra = if kind == "dispatch" then { record_id = "claude2", record_revision = 0, prompt = "Implement the follow-on planned task." }
		elseif kind == "report" then nil else { checkpoint_id = "cp-1" }
	local sent = W.propose(f, cid, kind, W.worker(f, b).work_id, extra); check(sent.ok, label .. ": proposal accepted (" .. tostring(sent.code) .. ")")
	local g = W.proposal_gate(f)
	if not scoped then
		check(table.find(g.evidence, "scope:" .. W.OUT[kind][2]) ~= nil,
			label .. ": the gate records why the work is outside plan scope")
	else
		check(table.find(g.evidence, "scope:in") ~= nil, label .. ": the gate records the work as in plan scope")
	end
	local answer
	if auto and scoped then
		check(g.answer ~= nil and g.answer.choice_id == "approve" and g.answer.source.kind == "policy" and g.answer.source.rule == "auto_approve:" .. kind
			and #g.answer.source.policy_revision == 64, label .. ": answered by session policy with the tagged policy source")
	else
		check(g.phase == "pending" and g.answer == nil and g.execution == nil and W.effects(f) == before, label .. ": the proposal gates for the owner and executes nothing")
		answer = f:event("answer", { gate_id = g.id, gate_revision = g.revision, choice_id = "approve", answer = "Owner approves this proposal." })
		local answered = f.authority:apply(answer); f:autonomy_sweep()
		check(answered.ok and answered.execution ~= nil, label .. ": the owner answer executes in its own commit (" .. tostring(answered.code) .. ")")
		g = f.authority.registry.dispatch.gates[g.id]
		check(g.answer.source.kind == "owner" and g.answer.source.owner_id == f.origin.owner_id, label .. ": the owner answer carries the tagged owner source")
	end
	g = f.authority.registry.dispatch.gates[g.id]
	local e, bw = g.execution, W.worker(f, b)
	check(e ~= nil and e.gate_revision == g.revision and (e.at_ms == 0 or e.at_ms > 0), label .. ": a durable execution record is written with the answer")
	if kind == "dispatch" then
		local new = e.effect_ref and f.authority.registry.dispatch.workers[e.effect_ref:match("^worker:(.+)$") or ""]
		check(e.state == "done" and new ~= nil and new.record_id == "claude2"
			and new.prompt:find("Implement the follow-on planned task.", 1, true) ~= nil
			and runtime.json.encode(new.source) == runtime.json.encode(bw.source) and runtime.json.encode(new.scope) == runtime.json.encode(bw.scope),
			label .. ": dispatch queues the proposed record/prompt inheriting the parent's source and scope")
	elseif kind == "report" then
		check(e.state == "pending" and e.effect_ref == "worker_not_sendable" and bw.workflow.report_request == nil,
			label .. ": an approved proposal waits for actual safe-idle evidence (" .. runtime.json.encode(e) .. ")")
		assert(f:apply("observe", { worker_id = b, pane_binding = api.clone(bw.pane_binding), native_state = "idle" }).ok)
		f:autonomy_sweep()
		g = f.authority.registry.dispatch.gates[g.id]
		e, bw = g.execution, W.worker(f, b)
		local rr = bw.workflow.report_request
		check(e.state == "done" and rr ~= nil and e.effect_ref == "report_request:" .. rr.request_id, label .. ": report sends one report_request to the work")
	elseif kind == "review" then
		local r = W.review(f, b)
		check(e.state == "done" and r ~= nil and e.effect_ref == "review:" .. r.review_id and r.checkpoint_id == "cp-1", label .. ": review opens a review of that checkpoint")
	else
		W.rm(f)
		local it, lg = W.item(f, lid), f.authority.registry.dispatch.gates[W.item(f, lid).gate_id]
		check(it.approval ~= nil and #it.grants == 1 and lg.answer ~= nil, label .. ": the landing item is approved and granted once (Rule H and the release manager still apply)")
		if auto and scoped then
			check(e.state == "done" or e.state == "refused", label .. ": the already-approved item settles the proposal execution (" .. tostring(e.state) .. " " .. tostring(e.effect_ref) .. ")")
		else
			check(e.state == "done" and e.effect_ref == "landing:" .. lid and lg.answer.source.kind == "owner", label .. ": the proposal answers the item's approval with the owner source")
		end
	end
	W.idempotent(f, label, g.id, answer)
	check(W.restores(f), label .. ": restores")
end
-- C4 uses two admitted sessions in one authority, not two isolated stores.
if section == nil or (section and section:match("^repository_")) then
	local function second_session(f, patch)
		local sid = "repository-second-session"
		local registered = f.authority:apply(f:state_event("register_session", { orch_session_id = sid, name = "Other repository owner" }))
		assert(registered.ok, registered.message)
		local admitted = f.authority:apply(f:state_event("admit_controller", { orch_session_id = sid,
			pane_binding = { host_pane_id = "43", alias_nonce = "repository-second-controller" } }))
		assert(admitted.ok, admitted.message)
		local other = table.clone(f)
		other.origin = { logical_session_id = sid, owner_id = admitted.owner_id, owner_generation = admitted.generation,
			host_pane_id = "43", alias_nonce = "repository-second-controller", window_key = "", window_epoch = "repository-second-window",
			native_session_id = "7", window_host_id = "local" }
		other.controller_pane, other.command_seq, other.default_project = "9003", nil, nil
		other:control("admit_session"); W.catalog(other)
		local policy = { require_code_review = false, merge_actor_mode = "selected_record", release_manager_record = "kimi" }
		for key, value in patch or {} do policy[key] = value end
		local saved = other:apply("policy", { policy = policy }); assert(saved.ok, saved.message)
		W.repository(other, "/fixture/repository/.git", "refs/heads/main")
		return other
	end
	local function prepared(f, name)
		local builder = W.builder(f)
		assert(W.ready(f, builder, name, name, 0).ok)
		return builder
	end
	local function request(f, builder, name, target, label, head)
		W.settle(f, builder)
		local sent = W.send(f, builder, "LANDING_REQUEST", { checkpoint_id = name, project_id = "project-one", repo_ref = label or "repo:fixture",
			target_ref = target or "refs/heads/main", target_revision = head or "head-0", source_ref = "refs/heads/" .. name, source_revision = W.hx(name) })
		assert(sent.ok, sent.message)
		for id, item in W.landing(f).items do if item.worker_id == builder then return id end end
		error("repository request missing")
	end
	local function rejected(f, lid)
		local holder = W.holder(f, lid)
		assert(W.ack(f, holder, W.grant(f, lid)).ok)
		assert(W.landing_result(f, holder, lid, "rejected", { reason = "Repository rejected this attempt without moving its target." }).ok)
	end
	if section == nil or section == "repository_sessions" then
		local f = W.fixture({ require_code_review = false })
		local other = second_session(f)
		local a = prepared(f, "repo-a"); local la = request(f, a, "repo-a")
		assert(W.approve(f, la).ok)
		local b = prepared(other, "repo-b"); local lb = request(other, b, "repo-b", "main", "a different free-text repository label")
		assert(W.approve(other, lb).ok)
		check(#W.item(f, la).grants == 1 and #W.item(f, lb).grants == 0 and W.item(f, lb).hold.code == "repository_wait",
			"distinct sessions, labels and short/full target spellings share one canonical repository slot")
		local view = api.dispatch.project(f.authority.registry, other.origin.logical_session_id, other.origin.alias_nonce).workflow
		check(#view.landing == 1 and view.landing[1].repository_slot == la and view.landing[1].items[1].repository_position == 2,
			"the second owner sees its actual global position and the first owner's occupied slot")
		rejected(f, la)
		local manager = assert(W.rm_id(other), "foreign-session release manager was not advanced")
		check(W.worker(other, manager).origin_binding.logical_session_id == other.origin.logical_session_id
			and W.worker(other, manager).controller_pane == other.controller_pane,
			"settlement in one session advances the other using that session's own bound controller")
		W.rm(other)
		check(#W.item(f, lb).grants == 1 and W.holder(other, lb) == manager, "the released slot grants the next session exactly once")
		check(W.restores(f), "the shared queue and both immutable grants survive restoration")
	end
	if section == nil or section == "repository_policy" then
		local f = W.fixture({ require_code_review = false })
		local other = second_session(f, { require_code_review = true, require_other_family = true, reviewer_records = W.arr({ "codex" }) })
		local a = prepared(f, "policy-a"); local la = request(f, a, "policy-a"); assert(W.approve(f, la).ok)
		local b = prepared(other, "policy-b"); local lb = request(other, b, "policy-b"); assert(W.approve(other, lb).ok)
		rejected(f, la)
		check(#W.item(other, lb).grants == 0 and W.item(other, lb).proof == nil and W.item(other, lb).hold ~= nil,
			"the first session's disabled review never supplies the second session's missing review proof")
		check(W.restores(f), "different session review policies remain independently valid")
	end
	if section == nil or section == "repository_paused" then
		local f = W.fixture({ require_code_review = false }); local other = second_session(f)
		local a = prepared(f, "paused-a"); local la = request(f, a, "paused-a"); assert(W.approve(f, la).ok)
		local b = prepared(other, "paused-b"); local lb = request(other, b, "paused-b"); assert(W.approve(other, lb).ok)
		assert(other:apply("pause").ok); rejected(f, la)
		check(#W.item(other, lb).grants == 0 and W.item(other, lb).hold.code == "session_paused",
			"foreign settlement does not resume a paused owner")
		assert(other:apply("resume").ok); W.rm(other)
		check(#W.item(other, lb).grants == 1, "explicit resume permits the already approved next request")
	end
	if section == nil or section == "repository_external" then
		local f = W.fixture({ require_code_review = false })
		W.repository(f, "/fixture/repository/.git", "refs/heads/main", "repository_queue")
		local other = second_session(f)
		local a = prepared(f, "external-a"); local la = request(f, a, "external-a"); assert(W.approve(f, la).ok)
		local b = prepared(other, "external-b"); local lb = request(other, b, "external-b"); assert(W.approve(other, lb).ok)
		check(#W.item(f, la).grants == 1 and #W.item(other, lb).grants == 1,
			"an explicitly declared protected repository queue receives both normal authorized grants without a competing local slot")
		for _, q in W.landing(f).queues do check(q.slot == nil, "repository_queue never owns an ORCH landing slot") end
		local first = W.grant(f, la).bytes
		rejected(other, lb)
		check(W.item(f, lb).status == "failed" and W.grant(f, la).bytes == first and W.grant(f, la).result == nil,
			"one external rejection settles only its exact grant")
		check(W.restores(f), "external grants and independently settled outcomes restore")
	end
	if section == nil or section == "repository_result_order" then
		for _, outcome in { "stale_target", "landed" } do
			local f = W.fixture({ require_code_review = false })
			W.repository(f, "/fixture/repository/.git", "refs/heads/main", "repository_queue")
			local other = second_session(f)
			local a = prepared(f, "order-a"); local la = request(f, a, "order-a"); assert(W.approve(f, la).ok)
			local b = prepared(other, "order-b"); local lb = request(other, b, "order-b"); assert(W.approve(other, lb).ok)
			local holder, original = W.holder(other, lb), W.grant(other, lb).bytes
			assert(W.ack(other, holder, W.grant(other, lb)).ok)
			if outcome == "landed" then
				local first_holder = W.holder(f, la)
				assert(W.ack(f, first_holder, W.grant(f, la)).ok)
				assert(W.landing_result(f, first_holder, la, "stale_target", { observed_target_revision = "head-1" }).ok)
			else
				W.land(f, la, "head-1")
			end
			local c = prepared(f, "order-c"); local lc = request(f, c, "order-c", nil, nil, "head-1")
			assert(W.approve(f, lc).ok); W.land(f, lc, "head-2")
			local fields = if outcome == "landed" then { result_revision = "head-1" } else { observed_target_revision = "head-1" }
			assert(W.landing_result(other, holder, lb, outcome, fields).ok)
			for _, queue in W.landing(f).queues do
				check(queue.head.revision == "head-2", "a delayed " .. outcome .. " result cannot replace the newer shared head")
			end
			local grant = W.grant(other, lb)
			check(grant.bytes == original and grant.result == nil and grant.late_result.outcome == outcome
				and grant.uncertain.code == "repository_head_unordered" and W.deploy(other, lb) == nil,
				"the exact conflicting result is retained without replay, premature settlement or deployment")
			check(W.refreshes(other, b) == 0 and W.restores(f), "disputed ordering restores without an obsolete refresh notice")
			local d = prepared(f, "order-d"); local ld = request(f, d, "order-d", nil, nil, "head-2")
			assert(W.approve(f, ld).ok)
			check(#W.item(f, ld).grants == 0 and W.item(f, ld).hold.code == "repository_head_unordered",
				"unresolved ordering blocks new grants across repository partitions")
			local reconciliation = { landing_id = lb, landing_revision = W.item(other, lb).revision,
				outcome = if outcome == "landed" then "landed" else "not_landed",
				target_revision = if outcome == "landed" then "head-1" else nil,
				reason = "Inspected this attempt and the current repository head independently.", operator_verified = true }
			check(not other:apply("reconcile_landing", reconciliation).ok, "unordered reconciliation requires a fresh current-head observation")
			if outcome == "landed" then reconciliation.current_target_revision = "head-2" else reconciliation.target_revision = "head-2" end
			reconciliation.landing_revision = W.item(other, lb).revision
			assert(other:apply("reconcile_landing", reconciliation).ok)
			check(#W.item(f, ld).grants == 1, "retained historical uncertainty no longer blocks the reconciled repository")
			if outcome == "landed" then
				check(W.deploy(other, lb).revision == "head-1", "deployment uses this grant's landing result, not the later current head")
			else
				assert(W.ready(other, b, "order-b-fresh", "order-b-fresh", 0).ok)
				assert(request(other, b, "order-b-fresh", nil, nil, "head-2") == lb)
				check(#W.item(other, lb).grants == 1 and W.item(other, lb).hold.code == "approval_pending",
					"reconciliation does not approve or replay a refreshed landing request")
				assert(W.approve(other, lb).ok)
				check(#W.item(other, lb).grants == 2 and W.grant(other, lb).target_revision == "head-2",
					"only a new owner approval grants the refreshed request")
			end
			for _, queue in W.landing(f).queues do check(queue.head.revision == "head-2" and queue.slot == nil, "external reconciliation preserves the current head without a local slot") end
			check(W.restores(f), "separate result and current-head evidence survive restoration")
		end
	end
	if section == nil or section == "repository_targets" then
		local f = W.fixture({ require_code_review = false }); local other = second_session(f)
		local a = prepared(f, "target-a"); local la = request(f, a, "target-a"); assert(W.approve(f, la).ok)
		W.repository(other, "/fixture/repository/.git", "refs/heads/release", "orch_queue")
		local b = prepared(other, "target-b"); local lb = request(other, b, "target-b", "refs/heads/release"); assert(W.approve(other, lb).ok)
		check(#W.item(f, la).grants == 1 and #W.item(other, lb).grants == 1,
			"distinct verified targets have independent local slots")
		local qa, qb = W.landing(f).queues[W.item(f, la).queue_id], W.landing(f).queues[W.item(f, lb).queue_id]
		check(qa.repository.key ~= qb.repository.key and qa.slot == la and qb.slot == lb, "independence is target identity, not session identity")
	end
	if section == nil or section == "repository_head" then
		local f = W.fixture({ require_code_review = false }); local other = second_session(f)
		local a = prepared(f, "head-a"); local la = request(f, a, "head-a"); assert(W.approve(f, la).ok)
		local b = prepared(other, "head-b"); local lb = request(other, b, "head-b"); assert(W.approve(other, lb).ok)
		W.land(f, la, "head-new")
		check(#W.item(other, lb).grants == 0 and W.item(other, lb).hold.code == "target_moved",
			"a landing in another session blocks the stale expected-head request before any grant")
		check(W.refreshes(other, b) == 1, "cross-session target movement issues one normal refresh, not a replayed grant")
		assert(W.ready(other, b, "head-b-fresh", "head-b-fresh", 0).ok)
		check(W.request(other, b, "head-b-fresh", "head-b-fresh", nil, "head-new") == lb
			and #W.item(other, lb).grants == 0 and W.item(other, lb).hold.code == "approval_pending",
			"fresh cross-session head and checks cannot reuse the prior request's owner approval")
		assert(W.approve(other, lb).ok)
		check(#W.item(other, lb).grants == 1 and W.grant(other, lb).target_revision == "head-new",
			"a new explicit owner approval grants only the refreshed target head")
	end
	if section == nil or section == "repository_route_change" then
		local f = W.fixture({ require_code_review = false })
		local a = prepared(f, "route-a"); local la = request(f, a, "route-a"); assert(W.approve(f, la).ok)
		local original, writes = W.grant(f, la).bytes, f.memory.writes
		local project = f.authority.registry.dispatch.projects[W.worker(f, a).orch_project_id]
		local repository = api.clone(project.repository); repository.queue_route = "repository_queue"
		local changed = f:apply("project_repository", { orch_project_id = project.orch_project_id, project_revision = project.revision, repository = repository })
		check(not changed.ok and changed.code == "repository_busy" and f.memory.writes == writes and W.grant(f, la).bytes == original,
			"changing queue route cannot strand or reinterpret an outstanding grant")
		rejected(f, la)
		W.repository(f, "/fixture/repository/.git", "refs/heads/main", "repository_queue")
		check(f.authority.registry.dispatch.projects[f.default_project].repository.queue_route == "repository_queue", "the owner can change the project's route after settlement")
	end
	if section == nil or section == "repository_sharing" then
		local f = W.fixture({ require_code_review = false }); local other = second_session(f)
		W.builder(f)
		local queued = other:apply("queue", { record_id = "builder", record_revision = 0, catalog_revision = 0,
			prompt = "Intentional shared-tree boundary case.", cwd = "/fixture", placement = "split", coordinator = false })
		check(queued.ok and queued.code == "task_gated" and queued.action_id == nil,
			"another session's live worker gates the same checkout even with empty checkout_roots")
		local worker = W.worker(other, queued.worker_id)
		check(worker.mailbox_handle == nil and #worker.launch_gates == 1, "shared checkout requires owner input before any provision")
		local granted = other:allow_shared_fixture(queued)
		check(granted.ok and granted.action_id ~= nil, "the explicit existing sharing decision releases only this launch")
	end
end

-- tests/gates.luau reuses these fixtures for its Checkpoint 5 invariant sweep.
if section == "helpers" then return W end
W.AUTONOMY = { autonomy_dispatch = "dispatch", autonomy_report = "report", autonomy_review = "review", autonomy_landing = "landing" }
if section == nil or section == "autonomy" or W.AUTONOMY[section] then
	for _, kind in { "dispatch", "report", "review", "landing" } do
		if section == nil or section == "autonomy" or W.AUTONOMY[section] == kind then
			for _, scoped in { true, false } do
				for _, auto in { true, false } do W.autonomy_cell(kind, scoped, auto) end
			end
		end
	end
end
if section == nil or section == "autonomy" or section == "autonomy_review" then
	local f = W.fixture({ require_code_review = false, reviewer_records = W.arr(), auto_approve_kinds = W.arr({ "review" }) })
	local b = W.builder(f, nil, { source = W.PLAN, files = W.arr({ "src/feature.luau" }) })
	assert(W.ready(f, b, "cp-disabled", "rev-disabled", 0).ok)
	local cid = W.coordinator(f)
	local before = W.effects(f)
	local sent = W.propose(f, cid, "review", W.worker(f, b).work_id, { checkpoint_id = "cp-disabled" })
	check(sent.ok and W.worker(f, cid).rejected_report == nil, "disabled review proposal is a committed refusal, not a held report")
	local g = W.proposal_gate(f)
	check(g.answer ~= nil and g.answer.choice_id == "reject" and g.answer.source.kind == "refusal"
		and g.answer.source.code == "review_disabled" and g.execution == nil and #g.answer.answer > 0,
		"disabled review proposal receives a clear policy refusal even when review auto-approval is enabled")
	check(W.effects(f) == before and #W.reviews(f) == 0, "explicit disabled review proposal creates no reviewer or review")
	check(W.restores(f), "disabled review refusal restores")

	-- An already-approved review proposal can be pending execution when policy changes.
	do
		local t = W.fixture({ reviewer_records = W.arr({ "codex" }) })
		local tb = W.builder(t, nil, { source = W.PLAN, files = W.arr({ "src/feature.luau" }) })
		assert(W.send(t, tb, "CHECKPOINT", W.cp("cp-pending", "rev-pending")).ok)
		local tc = W.coordinator(t)
		assert(W.propose(t, tc, "review", W.worker(t, tb).work_id, { checkpoint_id = "cp-pending" }).ok)
		local pending = W.proposal_gate(t)
		assert(pending.phase == "pending" and pending.execution == nil)
		assert(t:apply("pause").ok)
		assert(t:apply("answer", { gate_id = pending.id, gate_revision = pending.revision, choice_id = "approve", answer = "Review after resume." }).ok)
		local execution = t.authority.registry.dispatch.gates[pending.id].execution
		check(execution ~= nil and execution.state == "pending" and execution.effect_ref == "session_paused",
			"approved review proposal is pending execution while paused")
		local before = W.effects(t)
		assert(t:apply("policy", { policy = { require_code_review = false } }).ok)
		assert(t:apply("resume").ok)
		execution = t.authority.registry.dispatch.gates[pending.id].execution
		check(execution ~= nil and execution.state == "refused" and execution.effect_ref == "review_disabled",
			"pending explicit review execution is visibly refused after review is disabled")
		check(W.effects(t) == before and #W.reviews(t) == 0, "pending proposal creates no review or reviewer after disabling review")
		assert(t:apply("policy", { policy = { require_code_review = true } }).ok)
		check(W.effects(t) == before and t.authority.registry.dispatch.gates[pending.id].execution.state == "refused",
			"reenabling review never resurrects the refused pending proposal")
		W.idempotent(t, "review disabled before pending execution", pending.id, nil)
		check(W.restores(t), "disabled pending proposal execution restores")
	end
end

-- Checkpoint 6 (D10, D12, D16; Contracts G, K, L): plan scheduling, durable intake, template chains.
-- Host file reads are real tern.fs reads of fixture files in a fresh scratch folder.
function W.scratch()
	W.api()
	local dir = "/tmp/orch-cp6d-" .. api.codec.sha256(tostring(os.clock()) .. ":" .. tostring(math.random())):sub(1, 16)
	runtime.fs.mkdir(dir)
	return dir
end
function W.src_fixture(patch)
	W.api()
	local merged = { preferred_worker_record = "builder", auto_start_projects = true }
	for key, value in patch or {} do merged[key] = value end
	return W.fixture(merged)
end
-- Cold-start twin: a second host loads the stored bytes and ticks. The restored controller stays
-- uncertain until re-admitted, so the twin is inspected while the live authority continues.
function W.cold(f)
	local memory = { value = api.clone(f.memory.value), marker = f.memory.marker, writes = 0, marker_writes = 0 }
	memory.get = function(key)
		if key == "authority_state_initialized" then return memory.marker end
		assert(key == "authority_state")
		return api.clone(memory.value)
	end
	memory.set = function(key, value)
		if key == "authority_state_initialized" then memory.marker = value; memory.marker_writes += 1; return end
		assert(key == "authority_state")
		memory.value = api.clone(value); memory.writes += 1
	end
	local twin = { authority = api.host.new_authority(memory), origin = f.origin, tick = f.tick }
	local loaded = twin.authority:load(); assert(loaded.ok, "cold start load: " .. tostring(loaded.code) .. " " .. tostring(loaded.message))
	assert(twin:tick().ok)
	return twin
end
function W.plan(f, id) return f.authority.registry.dispatch.plans[id] end
function W.task(plan, task_id)
	for _, cp in plan.checkpoints do for _, t in cp.tasks do if t.id == task_id then return t end end end
	error("task missing: " .. task_id)
end
-- Positive scheduling fixtures explicitly authorize only their real checkout launch gates.
function W.release_queue(f, worker_id)
	local w = W.worker(f, worker_id)
	for _, gate_id in api.clone(w.launch_gates or {}) do
		local gate = f.authority.registry.dispatch.gates[gate_id]
		assert(gate and (gate.kind == "shared_checkout" or gate.kind == "file_overlap"), "unexpected source launch gate")
		local answered = f:apply("answer", { gate_id = gate.id, gate_revision = gate.revision,
			choice_id = "launch_anyway", answer = "Fixture owner explicitly coordinates this shared checkout." })
		assert(answered.ok, answered.message)
	end
end
-- Launch (if still queued) then finish one source worker cleanly.
function W.complete(f, worker_id)
	W.release_queue(f, worker_id)
	local w = W.worker(f, worker_id)
	if w.phase == "queued" then W.start(f, worker_id, (assert(W.provision_of(f, worker_id), "source work has no provision"))) end
	W.settle(f, worker_id, true)
	local done = f:apply("finish", { worker_id = worker_id }); assert(done.ok, done.message)
end
-- CHECKPOINT then DONE (optional output_ref) from an accepted worker.
function W.done(f, worker_id, output_ref)
	W.settle(f, worker_id)
	local cp_id = "cp-" .. worker_id
	assert(W.send(f, worker_id, "CHECKPOINT", W.cp(cp_id, cp_id)).ok)
	local p = { checkpoint_id = cp_id, artifact_revision = W.hx(cp_id), summary = "Template step output written." }
	if output_ref then p.output_ref = output_ref end
	local sent = W.send(f, worker_id, "DONE", p); assert(sent.ok, sent.message)
end
W.PLAN_TEXT = table.concat({
	"# Feature: Fixture scheduling plan", "", "## Plan", "",
	"### Checkpoint 1 — Foundations", "",
	"#### Task 1A — alpha", "**INDEPENDENT**", "### UPDATE `src/a.luau`", "- **SYSTEMS**: orch, spawn", "- **VALIDATE**: `luau tests/run.luau a`, then eyeball the output", "",
	"#### Task 1B — beta", "**INDEPENDENT**", "### UPDATE `src/b.luau`", "- **VALIDATE**: `luau tests/run.luau b`", "",
	"#### Task 1C — gamma", "**INDEPENDENT**", "### UPDATE `src/c.luau`", "- **VALIDATE**: `luau tests/run.luau c`", "",
	"#### Task 1D — delta", "SEQUENTIAL: consumes 1A-1C", "### UPDATE `src/d.luau`", "- **VALIDATE**: `luau tests/run.luau d`", "",
	"### Checkpoint 2 — Follow-on", "",
	"#### Task 2A — epsilon", "**INDEPENDENT**", "### UPDATE `src/e.luau`", "- **VALIDATE**: `luau tests/run.luau e`", "",
}, "\n")
function W.write_plan(dir, text, name)
	local path = dir .. "/" .. (name or "plan.md"); runtime.fs.write(path, text or W.PLAN_TEXT); return path
end

if section == nil or section == "sources" then
	do
		local legacy = W.src_fixture({ concurrency_limit = 4, auto_start_projects = false })
		local original = table.concat({ "# Feature: Stable work", "", "### Checkpoint 1 — Retained work",
			"### UPDATE `src/alpha.luau`", "**INDEPENDENT**", "Keep alpha instructions.", "",
			"### UPDATE `src/beta.luau`", "**INDEPENDENT**", "Keep beta instructions.", "" }, "\n")
		local path = W.write_plan(W.scratch(), original)
		local imported = legacy:apply("plan_import", { path = path }); assert(imported.ok, imported.message)
		local old = W.plan(legacy, imported.plan_id)
		-- A real old stored shape, before any worker is queued: later worker receipts are issued
		-- by the reducer with these original numeric-checkpoint-era identities, never rewritten.
		old.checkpoints[1].id = nil; old.checkpoints[1].source_state = nil
		local alpha, beta = old.checkpoints[1].tasks[1], old.checkpoints[1].tasks[2]
		alpha.id = "cp1-legacy-alpha"; beta.id = "cp1-legacy-beta"
		for _, task in old.checkpoints[1].tasks do
			task.source_identity = nil; task.identity_ambiguous = nil; task.source_state = nil
			task.steps = nil; task.filechanges = nil; task.validationchecks = nil; task.depends_on = nil
		end
		local project = legacy.authority.registry.dispatch.projects[imported.orch_project_id]
		assert(legacy:apply("project_start", { orch_project_id = project.orch_project_id, project_revision = project.revision, checks_reviewed = true }).ok)
		old = W.plan(legacy, imported.plan_id)
		local first_id, running_id = old.checkpoints[1].tasks[1].worker_id, old.checkpoints[1].tasks[2].worker_id
		W.release_queue(legacy, first_id); W.start(legacy, first_id, assert(W.provision_of(legacy, first_id)))
		W.release_queue(legacy, running_id); W.start(legacy, running_id, assert(W.provision_of(legacy, running_id)))
		W.done(legacy, first_id)
		W.complete(legacy, first_id)
		local first_source, running_source = api.clone(W.worker(legacy, first_id).source), api.clone(W.worker(legacy, running_id).source)
		local done_bytes = W.worker(legacy, first_id).workflow.evidence.DONE
		local revised = original:gsub("### Checkpoint 1 — Retained work", "### Checkpoint 1 — Inserted work\n### UPDATE `src/new.luau`\n**INDEPENDENT**\nOnly the new task is new work.\n\n### Checkpoint 2 — Retained work")
		runtime.fs.write(path, revised)
		local reimported = legacy:apply("plan_import", { path = path }); assert(reimported.ok, reimported.message)
		local next_plan = W.plan(legacy, reimported.plan_id)
		local by_file = {}
		for _, cp in next_plan.checkpoints do for _, task in cp.tasks do by_file[task.files[1]] = task end end
		check(by_file["src/alpha.luau"].state == "done" and by_file["src/alpha.luau"].worker_id == first_id
			and by_file["src/beta.luau"].state == "running" and by_file["src/beta.luau"].worker_id == running_id
			and by_file["src/new.luau"].state == "queued_plan" and by_file["src/new.luau"].worker_id == nil,
			"insert/renumber reconciliation preserves old done/running executions and queues only genuinely new source work")
		project = legacy.authority.registry.dispatch.projects[imported.orch_project_id]
		assert(legacy:apply("project_start", { orch_project_id = project.orch_project_id, project_revision = project.revision, checks_reviewed = true }).ok)
		local count = 0; for _ in legacy.authority.registry.dispatch.workers do count += 1 end
		check(count == 3 and W.worker(legacy, first_id).source.ref == first_source.ref
			and W.worker(legacy, first_id).source.revision == first_source.revision
			and W.worker(legacy, running_id).source.ref == running_source.ref
			and W.worker(legacy, running_id).source.revision == running_source.revision
			and W.worker(legacy, first_id).workflow.evidence.DONE == done_bytes,
			"only the new task gets a new worker; immutable old source revisions, protocol references and completion bytes are not rebound")
		local before = runtime.json.encode(legacy.authority.registry)
		runtime.fs.write(path, revised:gsub("Keep alpha instructions%.", "Changed alpha instructions."))
		local edited = legacy:apply("plan_import", { path = path })
		check(not edited.ok and edited.code == "plan_identity_changed" and runtime.json.encode(legacy.authority.registry) == before,
			"editing a managed source task holds the import without rerunning done work or replacing existing proof")
		check(W.restores(legacy), "legacy semantic carry with old receipt identities restores")
	end
	do
		local ambiguous = W.src_fixture()
		local path = W.write_plan(W.scratch(), table.concat({ "# Feature: Duplicate work", "### Checkpoint 1 — Work",
			"### UPDATE `src/same.luau`", "**INDEPENDENT**", "Same instructions.",
			"### UPDATE `src/same.luau`", "**INDEPENDENT**", "Same instructions." }, "\n"))
		local added = ambiguous:apply("plan_import", { path = path }); assert(added.ok, added.message)
		local plan = W.plan(ambiguous, added.plan_id)
		check(#plan.checkpoints[1].tasks == 2 and next(ambiguous.authority.registry.dispatch.workers) == nil
			and plan.checkpoints[1].tasks[1].hold.code == "plan_identity_ambiguous"
			and plan.checkpoints[1].tasks[2].hold.code == "plan_identity_ambiguous",
			"identical repeated source actions parse but cannot silently execute twice on their initial import")
	end
	-- Join + INDEPENDENT fan-out under concurrency_limit 2.
	local dir = W.scratch()
	local f = W.src_fixture({ concurrency_limit = 2, auto_start_projects = false })
	check(f.authority.registry.dispatch.plans == nil, "cold start: a fresh store has no plans collection")
	local path = W.write_plan(dir)
	local imported = f:apply("plan_import", { path = path })
	assert(imported.ok, imported.message)
	check(imported.code == "plan_imported" and imported.checkpoints == 2 and imported.tasks == 5, "the plan imports with its two checkpoints and five tasks")
	local plan = W.plan(f, imported.plan_id)
	check(plan.plan_revision == api.codec.sha256(W.PLAN_TEXT) and plan.path == path, "the plan revision is the sha256 of the host-read bytes")
	check(#imported.started == 0 and W.task(plan, "1A").state == "queued_plan" and W.effects(f) == "",
		"ordinary import records a held source without dispatching")
	local project = f.authority.registry.dispatch.projects[imported.orch_project_id]
	assert(f:apply("project_start", { orch_project_id = project.orch_project_id, project_revision = project.revision, checks_reviewed = true }).ok)
	plan = W.plan(f, imported.plan_id)
	check(W.task(plan, "1A").state == "running" and W.task(plan, "1B").state == "running", "explicit START releases independent tasks up to concurrency_limit")
	check(W.task(plan, "1C").state == "queued_plan", "the third INDEPENDENT task waits for a free slot (limit 2), not for its siblings")
	check(W.task(plan, "1D").state == "queued_plan" and W.task(plan, "2A").state == "queued_plan", "the sequential task and checkpoint 2 stay queued_plan")
	local wa = W.worker(f, W.task(plan, "1A").worker_id)
	check(wa.source.kind == "plan" and wa.source.ref == path .. "#1A" and wa.source.revision == plan.plan_revision, "plan work carries the Contract G source {plan, path#task, revision}")
	check(#wa.checks == 1 and wa.checks[1].check_id == "1A-c1" and wa.checks[1].argv[1] == "luau", "the parsed VALIDATE item is check 1A-c1; the prose item is never a check")
	check(table.find(W.task(plan, "1A").flags, "check_unparsed") ~= nil, "the unsplittable VALIDATE item is flagged on the task (shown, never executed)")
	check(wa.files[1] == "src/a.luau" and wa.scope.paths[1] == "src/a.luau" and #wa.scope.systems == 2 and wa.scope.systems[1] == "orch" and wa.scope.systems[2] == "spawn",
		"files and scope.paths come from the action headers; scope.systems only from **SYSTEMS**")
	check(#W.worker(f, W.task(plan, "1B").worker_id).scope.systems == 0, "a task without **SYSTEMS** has no systems")
	check(wa.record_id == "builder", "plan work uses the preferred worker")
	local again = f:apply("plan_import", { path = path })
	check(again.ok and again.code == "plan_already_imported" and again.plan_id == imported.plan_id, "re-importing the same revision changes nothing")
	check(W.restores(f), "the imported plan restores")
	W.complete(f, W.task(plan, "1A").worker_id)
	plan = W.plan(f, imported.plan_id)
	check(W.task(plan, "1A").state == "done" and W.task(plan, "1C").state == "running", "a finished task frees its slot: the waiting INDEPENDENT task starts")
	check(W.task(plan, "1D").state == "queued_plan", "the sequential task still waits for every earlier task of its checkpoint")
	local second_worker = W.task(plan, "1B").worker_id
	W.release_queue(f, second_worker)
	local retained_gate
	for _, gate in f.authority.registry.dispatch.gates do
		if gate.worker_id == second_worker and gate.ruling then retained_gate = gate; break end
	end
	check(retained_gate ~= nil and retained_gate.phase == "resolved" and retained_gate.pane_binding == nil,
		"the released prelaunch decision retains its plan-document obligation without inventing a native pane")
	local original_gate = tern.json.encode(retained_gate)
	W.complete(f, W.task(plan, "1B").worker_id)
	check(tern.json.encode(f.authority.registry.dispatch.gates[retained_gate.id]) == original_gate,
		"launch, acceptance and finish preserve the exact prelaunch decision and pending document obligation")
	local substituted = api.clone(f.authority.registry)
	substituted.dispatch.gates[retained_gate.id].pane_binding = api.clone(W.worker(f, second_worker).pane_binding)
	substituted.dispatch.gates[retained_gate.id].pane_binding.pane_id = "999999"
	check(not api.state.valid(substituted), "a retained prelaunch ruling never authorizes a substituted native recipient")
	plan = W.plan(f, imported.plan_id)
	check(W.task(plan, "1D").state == "queued_plan" and W.task(plan, "2A").state == "queued_plan", "with 1C open, neither 1D nor checkpoint 2 starts")
	W.complete(f, W.task(plan, "1C").worker_id)
	plan = W.plan(f, imported.plan_id)
	check(W.task(plan, "1D").state == "running", "the sequential task starts once its predecessors are done")
	check(W.task(plan, "2A").state == "queued_plan", "join: checkpoint 2 never starts while checkpoint 1 has an unfinished task")
	-- Cold start twin: a restarted host keeps the join.
	local twin = W.cold(f)
	local tp = W.plan(twin, imported.plan_id)
	check(W.task(tp, "2A").state == "queued_plan" and W.task(tp, "1D").state == "running", "cold start: the restarted host keeps the join and the running task")
	W.complete(f, W.task(plan, "1D").worker_id)
	plan = W.plan(f, imported.plan_id)
	check(W.task(plan, "2A").state == "running", "checkpoint 2 starts once every checkpoint 1 task is done")
	check(W.restores(f), "the advanced plan restores")
	-- Unlimited (concurrency_limit 0 → 32): all three INDEPENDENT tasks start at once.
	local u = W.src_fixture()
	local ui = u:apply("plan_import", { path = path }); assert(ui.ok, ui.message)
	check(#ui.started == 3, "without a concurrency limit every INDEPENDENT task of checkpoint 1 starts together")
	-- Malformed plan: refused with the parser's reason; nothing stored.
	local bad = W.write_plan(dir, "no title here\n", "bad.md")
	local refused = u:apply("plan_import", { path = bad })
	check(not refused.ok and refused.code == "no_title", "a malformed plan is refused with the parser's reason")
	check(not u:apply("plan_import", { path = dir .. "/absent.md" }).ok, "a missing plan file is refused")
	check(u:apply("plan_import", { path = "relative/plan.md" }).code == "invalid_path", "a relative plan path is refused")

	-- One start policy: off keeps sources passive; explicit START is sufficient.
	local board = "/tmp/fixture-board.tern"
	for _, auto in { false, true } do
		local g = W.src_fixture({ board_path = board, auto_start_projects = auto })
		local tags = W.arr({ "#class-build" })
		local sent = g:apply("board_intake", { board_path = board, card_id = "card-1", text = "Add the fixture feature.", tags = tags,
			text_sha256 = api.quota.digest({ text = "Add the fixture feature.", tags = tags }) })
		assert(sent.ok, sent.message)
		check(#W.gates(g, "intake") == 0, "new intake never creates the obsolete second start question")
		if auto then
			check(sent.state == "accepted" and sent.worker_id ~= nil, "saved explicit auto-start policy can release new intake")
		else
			check(sent.state == "received" and sent.worker_id == nil and W.effects(g) == "", "default intake creates no worker or launch")
			local tg = W.cold(g)
			check(tg.authority.registry.dispatch.intakes[sent.intake_id].held == true and W.effects(tg) == "", "cold start retains passive intake")
			local project = g.authority.registry.dispatch.projects[sent.orch_project_id]
			assert(g:apply("project_start", { orch_project_id = project.orch_project_id, project_revision = project.revision }).ok)
			local rec = g.authority.registry.dispatch.intakes[sent.intake_id]
			check(rec.state == "accepted" and W.provision_of(g, rec.worker_id) ~= nil, "one explicit START releases the intake")
			local second = g:apply("board_intake", { orch_project_id = project.orch_project_id, board_path = board,
				card_id = "card-2", text = "A different card.", tags = tags, text_sha256 = api.quota.digest({ text = "A different card.", tags = tags }) })
			check(second.ok and second.worker_id == nil and g.authority.registry.dispatch.intakes[second.intake_id].held == true,
				"adding work to an already active project still waits for a fresh explicit START")
		end
		check(W.restores(g), "passive/explicit source policy restores")
	end

	-- Template chain: a ⇄ b cycle stops after 8 successful steps with a loop_cap gate naming the bound.
	local templates = W.arr({ { id = "draft", title = "Draft", prompt = "Draft from {input}.", output = "out/draft.md", next = "polish", custom_fields = {} },
		{ id = "polish", title = "Polish", prompt = "Polish {input}.", output = "out/polish.md", next = "draft", custom_fields = {} },
		{ id = "solo", title = "Solo", prompt = "Do {input}.", output = "out/solo.md", next = "", custom_fields = {} } })
	local c = W.src_fixture({ templates = templates })
	check(c.authority.registry.dispatch.chains == nil, "cold start: no chains collection before the first template start")
	local started = c:apply("template_start", { template_id = "draft", input = "notes/brief.md" })
	assert(started.ok, started.message)
	check(started.code == "template_added" and W.provision_of(c, started.worker_id) ~= nil, "saved auto-start policy releases the first template step")
	local chain_id = started.chain_id
	local worker_id, inputs = started.worker_id, {}
	for step = 1, 8 do
		local w = W.worker(c, worker_id)
		W.release_queue(c, worker_id)
		table.insert(inputs, w.prompt)
		W.start(c, worker_id, (assert(W.provision_of(c, worker_id), "chain step has no provision")))
		W.done(c, worker_id, if step % 2 == 1 then "out/draft.md" else "out/polish.md")
		local chain = c.authority.registry.dispatch.chains[chain_id]
		if step < 8 then
			local nxt = chain.steps[#chain.steps]
			check(chain.successes == step and nxt.state == "running" and nxt.input == (if step % 2 == 1 then "out/draft.md" else "out/polish.md"),
				"chain step " .. step .. ": DONE.output_ref feeds the next template's {input}")
			worker_id = nxt.worker_id
		end
	end
	check(inputs[2]:find("Polish out/draft.md.", 1, true) ~= nil, "the next step's prompt substitutes the previous output file")
	local chain = c.authority.registry.dispatch.chains[chain_id]
	local caps = W.gates(c, "loop_cap")
	check(chain.status == "capped" and chain.successes == 8, "the chain stops at 8 successful steps")
	check(#caps == 1, "the capped chain has one owner gate")
	local opts = {}; for _, o in caps[1].options do table.insert(opts, o.id) end
	check(table.find(opts, "allow_more") == nil, "the structural chain bound offers no allow_more")
	local workers = 0; for _ in c.authority.registry.dispatch.workers do workers += 1 end
	check(workers == 8, "no ninth step worker was created")
	local tc = W.cold(c)
	check(tc.authority.registry.dispatch.chains[chain_id].status == "capped" and #W.gates(tc, "loop_cap") == 1, "cold start: the capped chain and its gate survive; no step starts")
	check(W.restores(c), "the capped chain restores")
	-- Other way: a template with no next ends the chain after one step, no gate.
	local solo = c:apply("template_start", { template_id = "solo", input = "x.md" }); assert(solo.ok, solo.message)
	W.release_queue(c, solo.worker_id)
	W.start(c, solo.worker_id, assert(W.provision_of(c, solo.worker_id)))
	W.done(c, solo.worker_id, "out/solo.md")
	check(c.authority.registry.dispatch.chains[solo.chain_id].status == "done" and #W.gates(c, "loop_cap") == 1, "a chain whose template has no next ends done without a gate")
	check(c:apply("template_start", { template_id = "missing", input = "x" }).code == "template_unknown", "an unknown template is refused")
	do
		local custom = W.src_fixture({ templates = W.arr({
			{ id = "custom", title = "Custom", prompt = "Process {input} for {topic}.", output = "out/{topic}.md", next = "follow", custom_fields = { topic = "default" } },
			{ id = "follow", title = "Follow", prompt = "Continue {input} for {topic}.", output = "out/{topic}-follow.md", next = "", custom_fields = { topic = "other-default" } },
		}) })
		local added = custom:apply("template_start", { template_id = "custom", input = "brief.md", custom_fields = { topic = "selected" } })
		assert(added.ok, added.message)
		local current = custom.authority.registry.dispatch.chains[added.chain_id]
		check(current.steps[1].output_path == "out/selected.md" and current.steps[1].custom_fields.topic == "selected", "custom invocation values reach resolved template output and durable chain state")
		W.start(custom, added.worker_id, assert(W.provision_of(custom, added.worker_id)))
		W.done(custom, added.worker_id, "out/selected.md")
		current = custom.authority.registry.dispatch.chains[added.chain_id]
		local following = current.steps[#current.steps]
		check(following.template_id == "follow" and following.output_path == "out/selected-follow.md", "matching custom values carry into the actual next template step")
		check(not custom:apply("template_start", { template_id = "custom", input = "brief.md", custom_fields = { unknown = "x" } }).ok, "unknown custom fields cannot silently save or execute")
		check(W.restores(custom), "custom template fields and resolved output paths survive restore")
	end
	do
		local defaults = W.src_fixture({ templates = W.arr({
			{ id = "first", title = "First", prompt = "Process {input} in {lang}.", output = "out/first.md", next = "next", custom_fields = { lang = "en" } },
			{ id = "next", title = "Next", prompt = "Continue {input} in {lang}.", output = "out/{lang}.md", next = "", custom_fields = { lang = "de" } },
		}) })
		local added = defaults:apply("template_start", { template_id = "first", input = "brief.md" }); assert(added.ok, added.message)
		W.start(defaults, added.worker_id, assert(W.provision_of(defaults, added.worker_id)))
		W.done(defaults, added.worker_id, "out/first.md")
		local chain = defaults.authority.registry.dispatch.chains[added.chain_id]
		check(chain.steps[#chain.steps].output_path == "out/de.md", "template B uses B's default, not template A's expanded defaults, when no invocation override was supplied")
		check(W.restores(defaults), "separate template defaults and invocation overrides restore across a real next-step transition")
	end
end

if section == nil or section == "intake" then
	local dir = W.scratch()
	local inbox = dir .. "/inbox"; runtime.fs.mkdir(inbox)
	local f = W.src_fixture({ inbox_folder = inbox })
	check(f.authority.registry.dispatch.intakes == nil, "cold start: a fresh store has no intakes collection")
	local body = "**CLASS**: build\n\nImplement the inbox fixture task.\n"
	runtime.fs.write(inbox .. "/task.md", body)
	local sha = api.codec.sha256(body)
	local expected_id = api.quota.digest({ kind = "inbox", path = inbox .. "/task.md", sha256 = sha })
	local first = f:apply("inbox_intake", { name = "task.md", content_sha256 = sha })
	assert(first.ok, first.message)
	check(first.intake_id == expected_id, "the host derives intake_id exactly as the window does (quota.digest{kind,path,sha256})")
	check(first.state == "accepted" and first.work_id ~= nil, "the inbox intake is accepted and launches its work")
	local w = W.worker(f, first.worker_id)
	check(w.source.kind == "inbox" and w.source.ref == "task.md" and w.source.revision == sha, "inbox work carries the Contract G source {inbox, name, content sha256}")
	local workers = 0; for _ in f.authority.registry.dispatch.workers do workers += 1 end
	-- Duplicate / racing windows: the same intake_id returns the existing record.
	local dup = f:apply("inbox_intake", { name = "task.md", content_sha256 = sha })
	local race = f:apply("inbox_intake", { name = "task.md", content_sha256 = sha })
	check(dup.ok and dup.code == "intake_duplicate" and dup.intake_id == first.intake_id and dup.work_id == first.work_id and dup.state == "accepted",
		"a duplicate intake_id returns the existing record")
	check(race.code == "intake_duplicate" and race.work_id == first.work_id, "a second racing window's intake of the same file also gets the existing record")
	local after = 0; for _ in f.authority.registry.dispatch.workers do after += 1 end
	check(after == workers, "two racing intakes of the same file make exactly one work")
	-- New content under the same name is a new intake.
	local body2 = body .. "Second version.\n"
	runtime.fs.write(inbox .. "/task.md", body2)
	local stale = f:apply("inbox_intake", { name = "task.md", content_sha256 = api.codec.sha256("never this") })
	check(not stale.ok and stale.code == "content_changed", "a hash that no longer matches the file is refused content_changed")
	check(f.authority.registry.dispatch.intakes[api.quota.digest({ kind = "inbox", path = inbox .. "/task.md", sha256 = api.codec.sha256("never this") })] == nil,
		"content_changed is not durable (retried next poll)")
	local second = f:apply("inbox_intake", { name = "task.md", content_sha256 = api.codec.sha256(body2) })
	check(second.ok and second.code == "intake_received" and second.intake_id ~= first.intake_id
		and second.work_id ~= first.work_id and W.worker(f, second.worker_id).launch_gates ~= nil,
		"new content creates distinct work but its shared checkout remains gated")
	W.release_queue(f, second.worker_id)
	check(f.authority.registry.dispatch.intakes[second.intake_id].state == "accepted",
		"only the exact owner's checkout decision makes this intake archivable")
	-- Too large: refused durably, file untaken.
	local big = string.rep("x", 40000)
	runtime.fs.write(inbox .. "/big.md", big)
	local large = f:apply("inbox_intake", { name = "big.md", content_sha256 = api.codec.sha256(big) })
	check(large.code == "intake_refused" and large.refusal == "too_large" and large.state == "refused" and f.authority.registry.dispatch.intakes[large.intake_id].state == "refused",
		"a >32 KiB inbox file is refused too_large durably")
	local large_again = f:apply("inbox_intake", { name = "big.md", content_sha256 = api.codec.sha256(big) })
	check(large_again.code == "intake_duplicate" and large_again.state == "refused", "the durable refusal answers a re-poll of the same oversize content")
	check(runtime.fs.exists(inbox .. "/big.md"), "the refused file stays in the inbox")
	check(f:apply("inbox_intake", { name = "../escape.md", content_sha256 = sha }).code == "intake_invalid", "an inbox name outside the folder is refused")
	-- Restart before archive: the accepted record survives; the re-scan's intake is a duplicate, no new work.
	local tf = W.cold(f)
	check(tf.authority.registry.dispatch.intakes[second.intake_id].state == "accepted", "cold start: the accepted record survives a host restart")
	local projected
	for _, rec in api.dispatch.project(tf.authority.registry, f.origin.logical_session_id, f.origin.alias_nonce).workflow.intakes do
		if rec.intake_id == second.intake_id then projected = rec end
	end
	check(projected and projected.state == "accepted", "cold start: the workflow-intake projection shows the accepted intake the window archives against")
	local rescan = f:apply("inbox_intake", { name = "task.md", content_sha256 = api.codec.sha256(body2) })
	check(rescan.code == "intake_duplicate" and rescan.state == "accepted" and rescan.work_id == second.work_id, "a re-scan of the taken file returns the accepted record, never a new work")
	check(W.restores(f), "the intakes collection restores")

	-- Board: card id re-map after an id-invalidating reload; oversize card refused.
	local board = "/tmp/" .. string.rep("nested-board/", 48) .. "fixture-board.tern"
	local g = W.src_fixture({ board_path = board })
	local tags = W.arr({ "urgent", "class-docs" })
	local text = "Document the board flow."
	local tsha = api.quota.digest({ text = text, tags = tags })
	local old_id = tern.json.encode(W.arr({ board, 1, 7 }))
	local new_id = tern.json.encode(W.arr({ board, 2, 7 }))
	local card = g:apply("board_intake", { board_path = board, card_id = old_id, text = text, tags = tags, text_sha256 = tsha })
	assert(card.ok, card.message)
	check(card.intake_id == api.quota.digest({ kind = "board", path = board, sha256 = tsha }), "the board intake_id matches the window's derivation")
	check(W.worker(g, card.worker_id).record_id == "builder" and W.worker(g, card.worker_id).class == "docs", "task type is retained metadata; Preferred Worker selects the actual record")
	local before_remap, source = W.effects(g), tern.json.encode(W.worker(g, card.worker_id).source)
	local remap = g:apply("board_intake", { board_path = board, card_id = new_id, text = text, tags = tags, text_sha256 = tsha })
	check(remap.code == "intake_duplicate" and remap.work_id == card.work_id and g.authority.registry.dispatch.intakes[card.intake_id].card_id == new_id
		and W.effects(g) == before_remap and tern.json.encode(W.worker(g, card.worker_id).source) == source,
		"full-path opaque native IDs survive generation remapping without another worker, changed manifest/source identity or replay")
	check(W.worker(g, card.worker_id).source.ref == board .. "#" .. card.intake_id,
		"the real full board path and semantic intake digest bind work without embedding/truncating its transient native ID")
	local cards = api.dispatch.project(g.authority.registry, g.origin.logical_session_id, g.origin.alias_nonce).workflow.board.cards
	check(#cards == 1 and cards[1].card_id == new_id and cards[1].intake_id == card.intake_id, "the board projection retains the complete current native association")
	local long = string.rep("y", 4097)
	local oversize = g:apply("board_intake", { board_path = board, card_id = "card-big", text = long, tags = W.arr(), text_sha256 = api.quota.digest({ text = long, tags = W.arr() }) })
	check(oversize.code == "intake_refused" and oversize.refusal == "card_too_large" and g.authority.registry.dispatch.intakes[oversize.intake_id].state == "refused",
		"a card longer than 4096 bytes is refused card_too_large durably")
	local other = g:apply("board_intake", { board_path = "/tmp/other.tern", card_id = "c", text = text, tags = tags, text_sha256 = tsha })
	check(other.ok and other.intake_id ~= card.intake_id and g.authority.registry.dispatch.intakes[other.intake_id].path == "/tmp/other.tern"
		and api.dispatch.policy(g.authority.registry, g.origin.logical_session_id).board_path == board,
		"explicit intake from another absolute board keeps its own source identity without replacing the watched board")
	local before_relative = tern.json.encode(g.authority.registry)
	check(g:apply("board_intake", { board_path = "relative.tern", card_id = "c", text = text, tags = tags, text_sha256 = tsha }).code == "board_mismatch"
		and tern.json.encode(g.authority.registry) == before_relative, "a relative board path is rejected without a source or project write")
	check(g:apply("board_intake", { board_path = board, card_id = "c", text = text .. "!", tags = tags, text_sha256 = tsha }).code == "intake_invalid", "a text_sha256 mismatch is refused")
	-- Unclassified work also uses the preferred worker, never a classifier session.
	local plain_tags = W.arr({ "docs", "#build", "class-unknown" })
	local plain = g:apply("board_intake", { board_path = board, card_id = "card-plain", text = "Unlabelled.", tags = plain_tags, text_sha256 = api.quota.digest({ text = "Unlabelled.", tags = plain_tags }) })
	check(plain.ok and plain.work_id ~= nil and W.worker(g, plain.worker_id).record_id == "builder", "unclassified intake reaches the preferred worker without classifier-only machinery")
	local tb = W.cold(g)
	check(tb.authority.registry.dispatch.intakes[card.intake_id].card_id == new_id, "cold start: the full-path native generation ID remapping is durable")
	check(W.restores(g), "board intakes restore")
	local protocol = api.load("dispatch_protocol")
	local before_invalid, writes = tern.json.encode(g.authority.registry), g.memory.writes
	check(not g:apply("board_intake", { board_path = board, card_id = string.rep("x", protocol.NATIVE_BOARD_ID_BYTES + 1),
		text = text, tags = tags, text_sha256 = tsha }).ok and g.memory.writes == writes and tern.json.encode(g.authority.registry) == before_invalid,
		"overbound opaque identity refuses atomically rather than truncating or rebinding an existing card")
end

-- The old section selectors remain registered acceptance groups for the routing cutover.
if section == nil or section == "router" or section == "labeller_finish" then
	local board = "/tmp/fixture-preferred-board.tern"
	local function add(f, card, text, tags)
		tags = tags or W.arr()
		return f:apply("board_intake", { board_path = board, card_id = card, text = text, tags = tags, text_sha256 = api.quota.digest({ text = text, tags = tags }) })
	end
	local f = W.src_fixture({ board_path = board, preferred_worker_record = "claude2" })
	local first = add(f, "unclassified", "Write the documentation.")
	assert(first.ok, first.message)
	check(first.worker_id ~= nil and W.worker(f, first.worker_id).record_id == "claude2", "unclassified work uses the instance preferred worker")
	for _, worker in f.authority.registry.dispatch.workers do check(worker.role ~= "labeller", "intake creates no classifier-only worker") end
	local tagged = add(f, "typed", "Build it.", W.arr({ "class-build" }))
	assert(tagged.ok, tagged.message)
	check(W.worker(f, tagged.worker_id).record_id == "claude2" and W.worker(f, tagged.worker_id).class == "build", "task metadata never selects a static build route")
	local missing = W.src_fixture({ board_path = board, preferred_worker_record = "" })
	local held = add(missing, "held", "Keep this work.")
	check(held.ok and held.worker_id == nil and held.hold.code == "preferred_worker_missing", "missing preference holds original intake without inventing a fallback")
	check(not missing:apply("policy", { policy = { routes = W.arr({ { class = "build", record_id = "builder" } }) } }).ok, "removed static routing is not a writable alias")
	check(not missing:apply("policy", { policy = { labeller_record = "omp" } }).ok, "removed classifier setup is refused")
	check(W.restores(f) and W.restores(missing), "preferred routing and held original work survive restore")
end

-- Checkpoint 7 (D17, Task 7B math): account usage delta between two pinned readings.
if section == nil or section == "usage_delta" then
	local quota = W.api().quota
	local NOW = 1800000000000
	local function reading(opts)
		opts = opts or {}
		local account = if opts.unbound then nil else { canonical_ids = opts.ids or { "claude:native" }, generation = opts.generation or 2 }
		return { account = account, observed_at_ms = opts.at or NOW,
			windows = opts.windows or {
				{ key = "five_hour", pool = "default", remaining = opts.five or 70, observed_at_ms = opts.at or NOW, resets_at_ms = opts.five_reset or NOW + 3600000 },
				{ key = "seven_day", pool = "default", remaining = opts.week or 60, observed_at_ms = opts.at or NOW, resets_at_ms = opts.week_reset or NOW + 86400000 } } }
	end
	local function row(result, key) for _, r in result.windows do if r.key == key then return r end end; return nil end
	local before = reading()

	-- Same reset → delta.
	local d = quota.usage_delta(before, reading({ at = NOW + 60000, five = 55, week = 50 }))
	check(d.comparable and d.reason == nil and #d.windows == 2 and d.windows[1].key == "five_hour|default" and d.windows[2].key == "seven_day|default",
		"same account and resets: comparable, one row per key|pool sorted by key")
	check(row(d, "five_hour|default").used_before == 30 and row(d, "five_hour|default").used_after == 45 and row(d, "five_hour|default").delta == 15
		and row(d, "seven_day|default").delta == 10 and row(d, "five_hour|default").reason == nil, "delta = (100 - remaining_after) - (100 - remaining_before)")
	-- Reset crossed → reset_crossed (one window, then all).
	local one = quota.usage_delta(before, reading({ at = NOW + 60000, five = 95, five_reset = NOW + 7200000 }))
	check(one.comparable and row(one, "five_hour|default").reason == "reset_crossed" and row(one, "five_hour|default").delta == nil
		and row(one, "seven_day|default").delta == 0, "a crossed reset voids that window only")
	local all = quota.usage_delta(before, reading({ at = NOW + 60000, five_reset = NOW + 7200000, week_reset = NOW + 90000000 }))
	check(not all.comparable and all.reason == "reset_crossed" and row(all, "seven_day|default").delta == nil, "every reset crossed → not comparable: reset_crossed")
	local appeared = quota.usage_delta(reading({ windows = { { key = "five_hour", pool = "default", remaining = 70, observed_at_ms = NOW } } }),
		reading({ at = NOW + 1, windows = { { key = "five_hour", pool = "default", remaining = 60, observed_at_ms = NOW + 1, resets_at_ms = NOW + 3600000 } } }))
	check(not appeared.comparable and appeared.reason == "reset_crossed", "a reset appearing between readings counts as crossed")
	-- Unbound → unbound.
	for name, pair in { before_unbound = { reading({ unbound = true }), reading({ at = NOW + 1 }) }, after_unbound = { before, reading({ at = NOW + 1, unbound = true }) },
		no_generation = { before, { account = { canonical_ids = { "claude:native" } }, windows = reading({ at = NOW + 1 }).windows } },
		no_ids = { before, reading({ at = NOW + 1, ids = {} }) }, missing = { nil, reading({ at = NOW + 1 }) } } do
		local r = quota.usage_delta(pair[1], pair[2])
		check(not r.comparable and r.reason == "unbound" and #r.windows == 0, name .. " → not comparable: unbound")
	end
	check(quota.usage_delta(before, reading({ at = NOW + 1 })).comparable, "bound on both sides → comparable")
	-- Different account → different_account.
	check(quota.usage_delta(before, reading({ at = NOW + 1, ids = { "claude:other" } })).reason == "different_account", "other canonical id → different_account")
	check(quota.usage_delta(before, reading({ at = NOW + 1, generation = 3 })).reason == "different_account", "rebound generation → different_account")
	check(not quota.usage_delta(before, reading({ at = NOW + 1, ids = { "claude:native", "claude:alias" } })).comparable, "an added canonical id is another account")
	check(quota.usage_delta(reading({ ids = { "b", "a" } }), reading({ at = NOW + 1, ids = { "a", "b" } })).comparable, "canonical id order is not identity")
	-- Stale: observation never advanced, went backwards, or a window is missing/invalid.
	check(quota.usage_delta(before, reading()).reason == "stale", "same observed_at_ms → stale")
	check(quota.usage_delta(before, reading({ at = NOW - 1 })).reason == "stale", "older after-reading → stale")
	local partial = quota.usage_delta(before, reading({ at = NOW + 1, windows = { { key = "five_hour", pool = "default", remaining = 60, observed_at_ms = NOW + 1, resets_at_ms = NOW + 3600000 } } }))
	check(partial.comparable and row(partial, "seven_day|default").reason == "stale" and row(partial, "five_hour|default").delta == 10, "a window missing after → that row stale")
	check(quota.usage_delta(before, reading({ at = NOW + 1, five = 101, week = -1 })).reason == "stale", "remaining outside 0..100 → stale")
	check(quota.usage_delta(reading({ windows = {} }), reading({ at = NOW + 1, windows = {} })).reason == "stale", "no windows → stale")
	check(quota.usage_delta(before, reading({ at = NOW + 1 })).reason == nil, "an advanced observation is not stale")

	-- Contract drift: the same USAGE capacity fixture drives quota.normalize and usage_delta.
	-- Shape: USAGE capacity export (USAGE/usage_service/capacity.py:55-90) of protocol-validated readings
	-- (protocol.py:149-215: window {key, pool, used, remaining = 100 - used, observed_at_ms, resets_at_ms?}),
	-- as in tests/dispatch.luau quota_normalize. A 7A-style worker reading takes the account from the bound
	-- profile_binding and the windows from the bound reading.
	local JOIN = { namespace = "fixture-spawn", host_key = "fixture-host", config_revision = 0 }
	local function publication(opts)
		local canonical = opts.canonical or { "claude:native" }
		return { protocol = 1, observer_device_id = "remote-a", subject_source_id = "remote-a", publisher = "remote-a:host", epoch = "epoch-1", sequence = 1,
			kind = "passive", generation = "gen-1", profile_generation = 3,
			snapshot = { version = 3, publisher = "remote-a:host", as_of_ms = opts.at,
				readings = { { id = "native-reading", provider = "claude", provider_label = "Claude", source_label = "Fixture", usage_source = "native-headless",
					canonical_id = canonical[1], windows = opts.windows } },
				roster = { version = 1, scopes = { { id = "remote-a:host:local", revision = "definition", spawn_join = JOIN, consumers = {},
					accounts = { { id = opts.id or "native", provider = "claude", provider_label = "Claude", account_label = "Fixture", canonical_ids = canonical,
						reading_ids = { "native-reading" }, definition_revision = string.rep("d", 64),
						profile_binding = { handle = "h-native", generation = opts.generation or 2, canonical_ids = canonical } } } } } } } }
	end
	local function document(pub)
		return { version = 1, complete = true, incomplete = false, auth_revision = "auth-1", records = { pub },
			sources = { { source_id = "remote-a", generation = "gen-1", profile_generation = 3, status = "current", last_received_ms = NOW, clock_skew = false } },
			inventory = {}, stale_after_ms = 900000, window_lease_ms = 900000, quota_unit = "percent", model_mapping = "unknown", current_source_id = "local-source" }
	end
	local function normalized(pub, now)
		local meta = { revision = string.rep("a", 64), auth_revision = "auth-1", issued_at_ms = now, expires_at_ms = now + 120000,
			validation = { validated_at_ms = now, expires_at_ms = now + 120000 } }
		return quota.normalize(document(pub), meta, { namespace = JOIN.namespace, host_key = JOIN.host_key, config_revision = 0, records = { { id = "native", revision = 0 } } }, now).records[1]
	end
	local function worker_reading(pub)
		local account = pub.snapshot.roster.scopes[1].accounts[1]
		return { account = { canonical_ids = account.profile_binding.canonical_ids, generation = account.profile_binding.generation },
			observed_at_ms = pub.snapshot.as_of_ms, windows = pub.snapshot.readings[1].windows }
	end
	local function windows(at, five_used, week_used, week_key)
		return { { key = "five_hour", pool = "default", used = five_used, remaining = 100 - five_used, observed_at_ms = at, resets_at_ms = NOW + 3600000 },
			{ key = week_key or "seven_day", pool = "default", used = week_used, remaining = 100 - week_used, observed_at_ms = at, resets_at_ms = NOW + 86400000 } }
	end
	local T1, T2 = NOW - 120000, NOW - 60000
	local pub1 = publication({ at = T1, windows = windows(T1, 30, 40) })
	local pub2 = publication({ at = T2, windows = windows(T2, 45, 50, "weekly") })
	local n1, n2 = normalized(pub1, T1 + 1000), normalized(pub2, T2 + 1000)
	check(n1.state == "known" and n2.state == "known" and n1.binding == n2.binding and n1.windows == 2 and n2.windows == 2, "the fixture normalizes as one bound account on both readings")
	local drift = quota.usage_delta(worker_reading(pub1), worker_reading(pub2))
	check(drift.comparable and #drift.windows == 2 and row(drift, "seven_day|default").delta == 10, "usage_delta folds 'weekly' into seven_day exactly as normalization does")
	local max_before, max_after = 0, 0
	for _, r in drift.windows do max_before = math.max(max_before, r.used_before); max_after = math.max(max_after, r.used_after) end
	check(n1.remaining_pct == 100 - max_before and n2.remaining_pct == 100 - max_after, "used = 100 - remaining agrees with normalization's remaining_pct")
	for _, w in pub2.snapshot.readings[1].windows do check(row(drift, (if w.key == "weekly" then "seven_day" else w.key) .. "|" .. w.pool).used_after == w.used, "used_after equals USAGE's own used for " .. w.key) end
	-- Rebinding: normalization changes the binding digest; usage_delta refuses the pair.
	local rebound = publication({ at = T2, windows = windows(T2, 45, 50), generation = 3 })
	check(normalized(rebound, T2 + 1000).binding ~= n1.binding and quota.usage_delta(worker_reading(pub1), worker_reading(rebound)).reason == "different_account",
		"a rebound generation is a new binding to both normalization and usage_delta")
	-- Reordered canonical ids: same principal to normalization, same account to usage_delta.
	local pair1 = publication({ at = T1, windows = windows(T1, 30, 40), canonical = { "claude:native", "claude:alias" } })
	local pair2 = publication({ at = T2, windows = windows(T2, 45, 50), canonical = { "claude:alias", "claude:native" } })
	pair2.snapshot.readings[1].canonical_id = "claude:native"
	check(normalized(pair1, T1 + 1000).principal == normalized(pair2, T2 + 1000).principal and quota.usage_delta(worker_reading(pair1), worker_reading(pair2)).comparable,
		"canonical id order is not identity to either")
	-- Out-of-range remaining: normalization refuses the unit, usage_delta refuses the window.
	local bad = publication({ at = T2, windows = { { key = "five_hour", pool = "default", used = 0, remaining = 101, observed_at_ms = T2, resets_at_ms = NOW + 3600000 } } })
	check(normalized(bad, T2 + 1000).reason == "unit_unknown" and row(quota.usage_delta(worker_reading(pub1), worker_reading(bad)), "five_hour|default").reason == "stale",
		"remaining > 100 is rejected by both")

	-- Capture (Task 7A, D17): the same USAGE fixture, normalized and recorded through the `capacity`
	-- command, stamps usage_before at launch and usage_after at DONE in the pinned reading shape.
	local clock = { now_ms = T1 + 1000, mono_ms = 1000, epoch = "usage-capture-host" }
	local function tick(at) clock.now_ms = at; clock.mono_ms = 1000 + (at - T1) end
	local function evidence(pub, now)
		local meta = { revision = string.rep("a", 64), auth_revision = "auth-1", issued_at_ms = now, expires_at_ms = now + 120000,
			validation = { validated_at_ms = now, expires_at_ms = now + 120000 } }
		return quota.normalize(document(pub), meta, { namespace = JOIN.namespace, host_key = JOIN.host_key, config_revision = 0, records = { { id = "builder", revision = 0 } } }, now)
	end
	local function record(f, pub)
		local recorded = f:apply("capacity", { capacity = evidence(pub, clock.now_ms) }); assert(recorded.ok and recorded.code == "capacity_recorded", recorded.message)
	end
	local function projected(f, id)
		for _, pw in api.dispatch.project(f.authority.registry, f.origin.logical_session_id, f.origin.alias_nonce).workflow.workers do if pw.worker_id == id then return pw end end
		return nil
	end
	local cf = W.fixture({}, function() return api.clone(clock) end)
	-- No capacity export yet: nothing is captured (the row stays hidden).
	local blind = W.builder(cf)
	check(W.worker(cf, blind).usage_before == nil and projected(cf, blind).usage_before == nil, "no USAGE capacity evidence → no usage_before captured")
	local cpub1 = publication({ id = "builder", at = T1, windows = windows(T1, 30, 40) })
	record(cf, cpub1)
	local b1 = W.builder(cf)
	local ub = W.worker(cf, b1).usage_before
	check(ub ~= nil and ub.observed_at_ms == T1 and ub.account ~= nil and #ub.account.canonical_ids == 1 and ub.account.generation == 2 and #ub.windows == 2,
		"launch with current evidence stores usage_before {account{canonical_ids, generation}, windows, observed_at_ms}")
	for _, w in ub.windows do check(w.remaining == (if w.key == "five_hour" then 70 else 60) and w.observed_at_ms == T1 and w.resets_at_ms ~= nil, "usage_before window " .. w.key .. " is the USAGE reading") end
	check(projected(cf, b1).usage_after == nil and projected(cf, b1).usage_before ~= nil, "running: projected usage_before, usage_after nil")
	check(W.worker(cf, blind).usage_before == nil, "evidence arriving later never back-fills a worker already running")
	local b2 = W.builder(cf)
	check(projected(cf, b1).usage_shared_with == 1 and projected(cf, b2).usage_shared_with == 1, "two live workers on one account: each shared with 1 other")
	check(projected(cf, blind).usage_shared_with == nil and projected(cf, b1).usage_shared_with == 1, "a worker without a reading has no shared count and is never counted")
	tick(T2 + 1000)
	record(cf, publication({ id = "builder", at = T2, windows = windows(T2, 45, 50, "weekly") }))
	W.done(cf, b1)
	local ua = W.worker(cf, b1).usage_after
	check(ua ~= nil and ua.observed_at_ms == T2, "DONE stores usage_after from the current evidence")
	local cd = quota.usage_delta(W.worker(cf, b1).usage_before, ua)
	check(cd.comparable and row(cd, "five_hour|default").delta == 15 and row(cd, "seven_day|default").delta == 10,
		"the captured pair yields the same deltas as the raw USAGE readings (contract drift end to end)")
	check(projected(cf, b1).usage_after ~= nil and W.worker(cf, b2).usage_after == nil, "only the worker that reported DONE gains usage_after")
	local b3 = W.builder(cf)
	check(projected(cf, b3).usage_shared_with == 1, "a worker launched after b1's DONE overlaps only the still-running b2")
	check(projected(cf, b1).usage_shared_with == 1, "b1's run overlapped only b2 (b3 started after its usage_after)")
	local twin = W.cold(cf)
	check(twin.authority.registry.dispatch.workers[b1].usage_after.observed_at_ms == T2 and twin.authority.registry.dispatch.workers[b2].usage_before.observed_at_ms == T1,
		"cold start: captured readings are durable")
	-- Rollover successor (Contract A): usage readings are never copied.
	assert(cf:apply("observe", { worker_id = b2, pane_binding = api.clone(W.worker(cf, b2).pane_binding), native_state = "idle" }).ok)
	W.settle(cf, b2, true)
	local requested = cf:apply("rollover", { worker_id = b2, trigger = "owner" }); assert(requested.ok and requested.code == "rollover_requested", requested.message)
	local rq = api.clone(W.worker(cf, b2).workflow.report_request)
	assert(W.send(cf, b2, "reply_ack", { message_id = rq.message_id, reply_seq = rq.reply_seq, reply_sha256 = api.codec.sha256(rq.bytes), status = "recorded" },
		{ action_id = rq.action_id, action_revision = rq.action_revision }).ok)
	local hcp = W.cp("rollover-cp-1", "rollover-cp-1"); hcp.request_id = rq.request_id
	local answered = W.send(cf, b2, "CHECKPOINT", hcp); assert(answered.ok, answered.message)
	local succ = cf.authority.registry.dispatch.rollovers[requested.handover_id].successor_worker_id
	check(succ ~= nil and W.worker(cf, succ).usage_before == nil and W.worker(cf, succ).usage_after == nil and W.worker(cf, b2).usage_before ~= nil,
		"the rollover successor does not inherit usage_before/usage_after")
end

-- Task text and built-in review policy remain; retired custom overrides never rewrite
-- immutable assignments or transport evidence during restore.
if section == nil or section == "assignment_policy" then
	local f = W.fixture()
	local typed = f:apply("queue", { record_id = "builder", record_revision = 0, catalog_revision = 0,
		prompt = "Typed fixture task.", cwd = "/fixture", placement = "split", coordinator = false })
	assert(typed.ok, typed.message)
	local w = W.worker(f, typed.worker_id)
	check(w.prompt:sub(1, #"Typed fixture task.") == "Typed fixture task."
		and w.prompt:find("ORCH+ review policy at assignment: require_code_review=true", 1, true) ~= nil
		and w.assignment_sha256 == api.codec.sha256(w.prompt),
		"typed task instructions retain their content, applicable built-in review policy and immutable digest")
	local old = api.clone(f.authority.registry)
	local sid = f.origin.logical_session_id
	old.dispatch.policies[sid].role_guidance = { builder = "Retired custom override.", reviewer = "",
		release_manager = "", labeller = "", coordinator = "" }
	local worker_before = api.clone(old.dispatch.workers[typed.worker_id])
	local actions_before = api.clone(old.dispatch.actions)
	local restored = assert(api.state.rehydrate(old))
	local retained = restored.dispatch.workers[typed.worker_id]
	check(restored.dispatch.policies[sid].role_guidance == nil
		and retained.prompt == worker_before.prompt and retained.assignment_sha256 == worker_before.assignment_sha256
		and retained.launch_request_id == worker_before.launch_request_id and retained.launch_action_id == worker_before.launch_action_id,
		"retiring stored overrides leaves the historical assignment and launch identity unchanged")
	for id, action in actions_before do
		local after = restored.dispatch.actions[id]
		check(after ~= nil and after.request_bytes == action.request_bytes and after.request_sha256 == action.request_sha256
			and after.response_bytes == action.response_bytes,
			"retirement preserves immutable request/response evidence for " .. id)
	end
end

-- Poll the coordinator until gate `gid`'s owner_decision is published; returns the delivered reply.
function W.deliver(f, cid, gid)
	for _ = 1, 16 do
		if f.authority.registry.dispatch.gates[gid].phase == "delivered" then break end
		local queued = f:apply("poll", { worker_id = cid }); assert(queued.ok, queued.message)
		local op = f:action(queued.action_id).request.op
		assert(f:finish(queued.action_id, if op == "mailbox_retire" then "compacted" elseif op == "mailbox_read" then "missing" else "published", {}).ok)
	end
	local g = f.authority.registry.dispatch.gates[gid]
	assert(g.phase == "delivered" and g.delivery, "gate " .. gid .. " was not delivered (" .. g.phase .. ")")
	return api.codec.decode_reply(g.delivery.bytes, W.worker(f, cid))
end
-- 8C (Contract E, D8): pause answers nothing by policy. A proposal already pending when the pause began
-- is evaluated once, on resume (here: its kind was enabled for auto-approval during the pause); the owner
-- may answer first. A NEW proposal during pause is refused session_paused — definitely and visibly (a
-- typed owner_decision reject from ORCH+), never holding the coordinator's report lane.
if section == nil or section == "autonomy_paused" then
	local DISPATCH = { record_id = "claude2", record_revision = 0, prompt = "Implement the follow-on planned task." }
	for _, case in { "resume", "owner_first", "not_enabled", "new_while_paused" } do
		local f = W.fixture({ reviewer_records = W.arr({ "codex" }) })
		local b = W.builder(f, "builder", { source = W.PLAN, files = W.arr({ "src/feature.luau" }) })
		W.settle(f, b); assert(W.send(f, b, "CHECKPOINT", W.cp("cp-1", "rev-1")).ok)
		local cid = W.coordinator(f)
		if case == "new_while_paused" then
			assert(f:apply("pause").ok)
			local sent = W.propose(f, cid, "dispatch", W.worker(f, b).work_id, api.clone(DISPATCH))
			check(sent.ok and sent.code == "session_paused" and W.worker(f, cid).rejected_report == nil,
				"new_while_paused: a new proposal is refused session_paused, committed; the coordinator's lane never holds (" .. tostring(sent.code) .. ")")
			local g = W.proposal_gate(f)
			check(g.phase == "answered" and g.answer.choice_id == "reject" and g.answer.source.kind == "refusal" and g.answer.source.code == "session_paused"
				and table.find(g.evidence, "refused:session_paused") ~= nil and g.execution == nil, "new_while_paused: the refusal is a visible ORCH+ reject, never an owner gate")
			local reply = W.deliver(f, cid, g.id)
			check(reply.kind == "owner_decision" and reply.payload.choice_id == "reject" and reply.payload.answer == g.answer.answer, "new_while_paused: the coordinator receives one typed owner_decision reject")
			check(W.send(f, cid, "HEARTBEAT", { state = "working" }).ok, "new_while_paused: the coordinator's next report is accepted at once")
			assert(f:apply("resume").ok)
			check(f.authority.registry.dispatch.gates[g.id].answer.source.kind == "refusal", "new_while_paused: resume never revisits a refusal")
			local again = W.propose(f, cid, "dispatch", W.worker(f, b).work_id, api.clone(DISPATCH))
			check(again.ok and again.code == "report_committed", "new_while_paused: after resume a fresh proposal opens a normal gate")
		else
			local sent = W.propose(f, cid, "dispatch", W.worker(f, b).work_id, api.clone(DISPATCH)); assert(sent.ok, sent.message)
			local g = W.proposal_gate(f)
			check(g.phase == "pending" and g.answer == nil and table.find(g.evidence, "scope:in") ~= nil, case .. ": the in-scope proposal waits (its kind is not auto-approved yet)")
			assert(f:apply("pause").ok)
			if case ~= "not_enabled" then assert(f:apply("policy", { policy = { auto_approve_kinds = W.arr({ "dispatch" }) } }).ok) end
			local before = W.effects(f)
			assert(f:tick()); assert(W.send(f, cid, "HEARTBEAT", { state = "working" }).ok)
			local restored = assert(api.state.rehydrate(api.clone(f.authority.registry)))
			local twin = api.dispatch.tick(restored, { kind = "workflow_tick", authority_namespace = restored.authority_namespace,
				expected_revision = restored.revision }, { now_ms = 1, mono_ms = 1, epoch = "paused-proposal-twin" }) or restored
			check(f.authority.registry.dispatch.gates[g.id].answer == nil and twin.dispatch.gates[g.id].answer == nil and W.effects(f) == before,
				case .. ": while paused, ticks, later reports and a restored twin answer nothing by policy")
			if case == "owner_first" then
				local answered = f:apply("answer", { gate_id = g.id, gate_revision = g.revision, choice_id = "reject", answer = "Not this one." })
				check(answered.ok and f.authority.registry.dispatch.gates[g.id].answer.source.kind == "owner", "owner_first: the owner may answer during pause")
			end
			assert(f:apply("resume").ok)
			local after = f.authority.registry.dispatch.gates[g.id]
			if case == "resume" then
				check(after.answer ~= nil and after.answer.choice_id == "approve" and after.answer.source.kind == "policy" and after.answer.source.rule == "auto_approve:dispatch",
					"resume: the pending proposal is evaluated once on resume and answered by the session policy")
				check(after.execution ~= nil and after.execution.state == "done" and after.execution.effect_ref:match("^worker:") ~= nil, "resume: the approved dispatch runs once after resume")
				W.idempotent(f, "paused then resumed proposal", g.id, nil)
			elseif case == "owner_first" then
				check(after.answer.source.kind == "owner" and after.answer.choice_id == "reject" and after.execution == nil and W.effects(f) == before,
					"owner_first: resume never overrides the owner's answer")
			else
				check(after.phase == "pending" and after.answer == nil and W.effects(f) == before, "not_enabled: a kind not auto-approved still waits for the owner after resume")
			end
		end
		check(W.restores(f), case .. ": restores")
	end
end

-- 8C: a proposal naming work whose CHECKPOINT is not registered yet is refused definitely — a typed
-- owner_decision reject from ORCH+, visible on its gate — and never holds the coordinator's lane.
if section == nil or section == "proposal_early" then
	local f = W.fixture({ reviewer_records = W.arr({ "codex" }), auto_approve_kinds = W.arr({ "review" }) })
	local b = W.builder(f, "builder", { source = W.PLAN, files = W.arr({ "src/feature.luau" }) })
	local cid = W.coordinator(f)
	local early = W.propose(f, cid, "review", W.worker(f, b).work_id, { proposal_id = "proposal-early", checkpoint_id = "cp-1" })
	check(early.ok and W.worker(f, cid).rejected_report == nil, "a proposal before its checkpoint is accepted as a refusal, never held (" .. tostring(early.code) .. ")")
	local g = W.proposal_gate(f)
	check(g.phase == "answered" and g.answer.choice_id == "reject" and g.answer.source.kind == "refusal" and g.answer.source.code == "scope_mismatch"
		and table.find(g.evidence, "refused:scope_mismatch") ~= nil and g.execution == nil,
		"ORCH+ answers the early proposal reject itself (source refusal scope_mismatch); nothing waits for the owner")
	local reply = W.deliver(f, cid, g.id)
	check(reply.kind == "owner_decision" and reply.gate_id == g.id and reply.payload.choice_id == "reject" and reply.payload.answer == g.answer.answer,
		"the refusal reaches the coordinator as one typed owner_decision reject")
	check(W.send(f, cid, "HEARTBEAT", { state = "working" }).ok, "the coordinator's next report is accepted at once")
	W.settle(f, b); assert(W.send(f, b, "CHECKPOINT", W.cp("cp-1", "rev-1")).ok)
	local again = W.propose(f, cid, "review", W.worker(f, b).work_id, { proposal_id = "proposal-early", checkpoint_id = "cp-1" })
	check(again.ok, "after the checkpoint the coordinator may propose again, even with the refused proposal id (" .. tostring(again.code) .. ")")
	local fresh
	for _, candidate in W.gates(f, "coordinator_proposal", false) do if candidate.id ~= g.id then fresh = candidate end end
	check(fresh ~= nil and fresh.answer ~= nil and fresh.answer.source.kind == "policy" and fresh.execution ~= nil and fresh.execution.state == "done",
		"the in-scope re-proposal is a normal proposal gate (here answered by policy and executed)")
	check(W.propose(f, cid, "review", W.worker(f, b).work_id, { proposal_id = "proposal-early", checkpoint_id = "cp-1" }).code == "proposal_conflict",
		"a live (non-refused) proposal id still conflicts")
	check(W.restores(f), "refused and re-proposed gates restore")
end

-- START scenarios use the real proposal, approval, immutable reply publication and
-- report intake paths. No fixture writes a started flag or manufactures a host claim.
function W.held_proposal(f, cid, project_id)
	local before = {}; for key in f.authority.registry.dispatch.workers do before[key] = true end
	local proposed = W.propose(f, cid, "new_work", nil, { orch_project_id = project_id,
		new_project_name = if project_id then nil else "Typed START work", record_id = "builder", record_revision = 0,
		prompt = "Implement only the approved START task.", scope = { paths = W.arr({ "src/start-" .. tostring((W.pserial or 0) + 1) .. ".luau" }), systems = W.arr() },
		checks = W.unit() })
	assert(proposed.ok, runtime.json.encode(proposed))
	local gate
	for _, value in W.gates(f, "coordinator_proposal") do if value.phase == "pending" then gate = value end end
	assert(gate, "pending new_work proposal")
	assert(f:apply("answer", { gate_id = gate.id, gate_revision = gate.revision, choice_id = "approve", answer = "Add this real work held." }).ok)
	for key, w in f.authority.registry.dispatch.workers do if not before[key] then return w.orch_project_id, key end end
	error("approved task missing")
end
function W.project_start(f, project_id)
	local p = f.authority.registry.dispatch.projects[project_id]
	return f:apply("project_start", { orch_project_id = project_id, project_revision = p.revision, checks_reviewed = true })
end
function W.start_publication(f, cid, project_id)
	for _ = 1, 32 do
		local s = f.authority.registry.dispatch.projects[project_id].start
		local queued = f:apply("poll", { worker_id = cid }); assert(queued.ok and queued.action_id, queued.message)
		local a = f:action(queued.action_id)
		if a.request.op == "mailbox_publish_reply" and a.request.reply_seq == s.reply_seq then return queued.action_id end
		assert(f:finish(queued.action_id, if a.request.op == "mailbox_retire" then "compacted" elseif a.request.op == "mailbox_read" then "missing" else "published", {}).ok)
	end
	error("original START publication was not scheduled")
end
function W.publish_start(f, cid, project_id)
	for _ = 1, 16 do
		if f.authority.registry.dispatch.projects[project_id].start.published then return end
		local action = W.start_publication(f, cid, project_id)
		assert(f:finish(action, "published", {}).ok)
	end
	error("START manifest was not published last")
end
function W.start_claim(f, cid, project_id, changes, headers)
	local s = f.authority.registry.dispatch.projects[project_id].start
	local reply = assert(api.codec.decode_reply(s.bytes, W.worker(f, cid)))
	local payload = api.clone(reply.payload)
	for key, value in changes or {} do payload[key] = value end
	local extra = { action_id = s.action_id, action_revision = s.action_revision }
	for key, value in headers or {} do extra[key] = value end
	return W.send(f, cid, "PROJECT_START_CLAIM", payload, extra)
end
function W.start_retry(f, project_id, changes)
	local s = f.authority.registry.dispatch.projects[project_id].start
	local fields = { orch_project_id = project_id, start_id = s.start_id, project_revision = s.project_revision, decision_context = s.decision_context }
	for key, value in changes or {} do fields[key] = value end
	return f:apply("project_start_retry", fields)
end
function W.mailbox_start_report(f, cid, bytes)
	local frames = assert(api.codec.frame(bytes, "report", W.worker(f, cid)))
	local objects = { frames.manifest }; for _, chunk in frames.chunks do table.insert(objects, chunk) end
	local outcome
	for _, object in objects do
		local read
		for _ = 1, 32 do
			local queued = f:apply("poll", { worker_id = cid }); assert(queued.ok and queued.action_id, queued.message)
			local request = f:action(queued.action_id).request
			if request.op == "mailbox_read" and request.selector.stream == "report" then read = queued.action_id; break end
			assert(f:finish(queued.action_id, if request.op == "mailbox_retire" then "compacted"
				elseif request.op == "accept" then "accepted" elseif request.op == "native_wake" then "submitted" else "published", {}).ok)
		end
		assert(read, "bounded production report read")
		local page = assert(api.codec.project_page(object, f:action(read).request.selector))
		outcome = f:finish(read, "read", runtime.json.decode(page)); assert(outcome.ok, outcome.message)
	end
	return outcome
end
function W.claim_report(f, cid, start)
	local reply = assert(api.codec.decode_reply(start.bytes, W.worker(f, cid)))
	return f:report(cid, W.worker(f, cid).accepted_seq + 1, "PROJECT_START_CLAIM", reply.payload,
		{ action_id = start.action_id, action_revision = start.action_revision })
end
if section == nil or section == "project_start" then
	local f = W.src_fixture({ auto_start_projects = false }); local cid = W.coordinator(f)
	local project, member = W.held_proposal(f, cid)
	local requested = W.project_start(f, project); assert(requested.ok, requested.message)
	local p = f.authority.registry.dispatch.projects[project]; local original = api.clone(p.start)
	check(not p.started and W.worker(f, member).checks_pending and W.provision_of(f, member) == nil,
		"approval and START record a real immutable grant but do not release managed work")
	check(requested.start.state == "publishing" and requested.start.activation_token == nil and requested.start.bytes == nil
		and requested.start.snapshot == nil and requested.start.coordinator.worker_id == cid, "START response exposes only safe correlated diagnostics")
	local seq = W.worker(f, cid).reply_seq
	check(W.project_start(f, project).ok and W.worker(f, cid).reply_seq == seq
		and f.authority.registry.dispatch.projects[project].start.bytes == original.bytes, "a repeated click retains one action, token and exact reply bytes")
	check(not W.start_claim(f, cid, project).ok and not f.authority.registry.dispatch.projects[project].started,
		"claim before confirmed manifest publication cannot release work")
	W.publish_start(f, cid, project)
	check(not W.start_claim(f, cid, project).ok, "publication alone is not an accepted consume receipt")
	assert(W.ack(f, cid, f.authority.registry.dispatch.projects[project].start).ok)
	for _, change in { { owner_id = "other-owner" }, { owner_generation = 99 }, { activation_token = string.rep("f", 64) },
		{ orch_project_id = "other-project" }, { project_revision = original.project_revision + 1 }, { decision_context = string.rep("f", 64) } } do
		check(not W.start_claim(f, cid, project, change).ok and not f.authority.registry.dispatch.projects[project].started,
			"a claim with another owner, activation, project, revision or source proof is refused atomically")
	end
	check(not W.start_claim(f, cid, project, nil, { action_id = "other-action" }).ok
		and not W.start_claim(f, cid, project, nil, { action_revision = 2 }).ok, "claim header action and revision are exact")
	local w = W.worker(f, cid); local reply = api.codec.decode_reply(original.bytes, w)
	local claim_bytes = f:report(cid, w.accepted_seq + 1, "PROJECT_START_CLAIM", reply.payload,
		{ action_id = original.action_id, action_revision = original.action_revision })
	assert(f:apply("intake", { worker_id = cid, bytes = claim_bytes }).ok)
	p = f.authority.registry.dispatch.projects[project]; local revision = p.revision
	check(p.started and p.start.claim == claim_bytes and not W.worker(f, member).checks_pending,
		"accepted authentic claim and captured membership release commit together")
	check(f:apply("intake", { worker_id = cid, bytes = claim_bytes }).code == "report_replayed"
		and f.authority.registry.dispatch.projects[project].revision == revision, "claim replay never releases or increments the project twice")
	check(not W.start_claim(f, cid, project).ok and W.worker(f, cid).accepted_seq == w.accepted_seq + 1,
		"a second claim at a fresh report sequence is refused rather than acknowledged or applied again")
	local before_repeat = W.worker(f, cid).reply_seq
	check(W.project_start(f, project).code == "project_already_started" and W.worker(f, cid).reply_seq == before_repeat
		and f.authority.registry.dispatch.projects[project].start.bytes == original.bytes,
		"START after completion without new held work creates no new grant")
	check(W.restores(f), "accepted claim, publication and receipt proof survive rehydration")
end
if section == nil or section == "project_start_membership" then
	local f = W.src_fixture({ auto_start_projects = false }); local cid = W.coordinator(f)
	local project, approved = W.held_proposal(f, cid)
	local function card(name)
		local text, tags = "Approved source " .. name, W.arr({ "docs" })
		local result = f:apply("board_intake", { orch_project_id = project, board_path = "/fixture/start-board.md",
			card_id = "start-" .. name, text = text, tags = tags, text_sha256 = api.quota.digest({ text = text, tags = tags }) })
		assert(result.ok, result.message); return result.intake_id
	end
	local approved_source = card("original")
	assert(W.project_start(f, project).ok)
	local original = api.clone(f.authority.registry.dispatch.projects[project].start)
	local _, later = W.held_proposal(f, cid, project)
	local later_source = card("later")
	W.publish_start(f, cid, project); assert(W.ack(f, cid, f.authority.registry.dispatch.projects[project].start).ok)
	assert(W.start_claim(f, cid, project).ok)
	check(not W.worker(f, approved).checks_pending and W.worker(f, later).checks_pending
		and W.worker(f, later).project_held and W.provision_of(f, later) == nil,
		"later approved held membership does not inherit an older START snapshot")
	check(not f.authority.registry.dispatch.intakes[approved_source].held
		and f.authority.registry.dispatch.intakes[later_source].held,
		"the original held source is released but a later source cannot inherit the captured START approval")
	check(f.authority.registry.dispatch.projects[project].start.action_id == original.action_id and W.restores(f),
		"later additions neither replace the original grant nor invalidate its retained accepted claim")
	local legacy = W.src_fixture({ auto_start_projects = false })
	local old = W.coordinator(legacy)
	-- Persisted pre-upgrade provisioning stays old: today's selected descriptor is
	-- not retroactive evidence about helpers that generation actually received.
	local saved = api.clone(legacy.authority.registry)
	saved.dispatch.workers[old].capabilities = W.arr({ "report-files-v1", "native-ask-v1", "coordinator-control-v1" })
	saved.dispatch.workers[old].project_start_protocol = nil
	check(api.state.rehydrate(api.clone(saved)) ~= nil, "persisted old-helper capability evidence remains valid")
	-- This case is a running pre-upgrade generation, not a host restart. Rehydration
	-- separately validates its persisted shape but deliberately fences execution on restart.
	legacy.authority.registry = saved
	legacy.memory.value = api.clone(saved)
	local held, member = W.held_proposal(legacy, old)
	check(W.project_start(legacy, held).code == "unsupported_capability"
		and not legacy.authority.registry.dispatch.projects[held].started and W.worker(legacy, member).project_held
		and legacy.authority.registry.dispatch.projects[held].start == nil,
		"an existing old-capability coordinator cannot receive a START grant or fall back to standalone release")
	local standalone = W.src_fixture({ auto_start_projects = false })
	local created = standalone:project("Legitimate standalone", false)
	check(W.project_start(standalone, created).code == "project_started"
		and standalone.authority.registry.dispatch.projects[created].start == nil,
		"explicit no-coordinator START remains the separate host-owned mode, with no fabricated claim")
end
if section == nil or section == "project_start_failures" then
	local f = W.src_fixture({ auto_start_projects = false }); local cid = W.coordinator(f)
	local project, member = W.held_proposal(f, cid)
	f.memory.fail = true; local failed = W.project_start(f, project); f.memory.fail = false
	check(not failed.ok and f.authority.registry.dispatch.projects[project].start == nil and W.worker(f, member).project_held,
		"failed authority persistence publishes no grant and releases no work")
	assert(W.project_start(f, project).ok); local original = api.clone(f.authority.registry.dispatch.projects[project].start)
	local action = W.start_publication(f, cid, project)
	assert(f:finish(action, "full", { resource = "mailbox", current = 1, limit = 1, retryable = true, effect_started = false }).ok)
	check(not f.authority.registry.dispatch.projects[project].started and W.worker(f, member).project_held,
		"definite pre-effect publication failure keeps the exact approved work held")
	check(not f:apply("retry", { action_id = action, trigger = "owner" }).ok, "generic retry cannot replace a START publication")
	check(not W.start_retry(f, project, { start_id = "other-start" }).ok
		and not W.start_retry(f, project, { project_revision = original.project_revision + 1 }).ok
		and not W.start_retry(f, project, { decision_context = string.rep("f", 64) }).ok, "retry is scoped to the captured original grant")
	assert(W.start_retry(f, project).ok)
	local retried = W.start_publication(f, cid, project)
	check(f:action(retried).request.reply_seq == original.reply_seq
		and f.authority.registry.dispatch.projects[project].start.bytes == original.bytes
		and f.authority.registry.dispatch.projects[project].start.action_id == original.action_id,
		"definite refusal retry republishes only the original typed action and immutable object bytes")
	local object = api.clone(f:action(retried).request)
	check(f:finish(retried, "rejected", nil, { code = "binding_mismatch", message = "Definite pre-effect prerequisite refusal." }).code == "project_start_delivery_failed",
		"a conclusive non-revocation refusal retains a recoverable original delivery")
	check(W.start_retry(f, project).code == "project_start_retry_queued", "repairing definite refusal prerequisites can rearm the same original grant")
	retried = W.start_publication(f, cid, project)
	check(f:action(retried).request.object_b64 == object.object_b64 and f:action(retried).request.part == object.part
		and f:action(retried).request.reply_seq == original.reply_seq and f.authority.registry.dispatch.projects[project].start.bytes == original.bytes,
		"definite refusal retry retains the exact object, cursor, reply slot and typed bytes")
	assert(f:apply("claim", { action_id = retried, executor = f.origin.window_epoch }).ok)
	local failed_delivery = f:finish(retried, "uncertain", nil, { code = "storage_error", message = "Publication outcome is not proven." })
	check(failed_delivery.code == "effect_uncertain",
		"an authentic uncertain publication retains its exact action, never a retryable refusal: " .. runtime.json.encode(failed_delivery))
	local serial, seq = f.authority.registry.dispatch.serial, W.worker(f, cid).reply_seq
	check(W.start_retry(f, project).code == "project_start_inspection"
		and f.authority.registry.dispatch.serial == serial and W.worker(f, cid).reply_seq == seq,
		"uncertain publication is inspection-only and cannot issue another transport or typed grant")
	local diagnostic = api.dispatch.project(f.authority.registry, f.origin.logical_session_id).projects[project].start
	check(diagnostic.state == "failed" and diagnostic.delivery_state == "uncertain" and diagnostic.delivery_action_id == retried
		and not diagnostic.failure.retryable and diagnostic.activation_token == nil,
		"safe uncertainty diagnostics retain the exact status-inspection action without granting retry")
	check(not f:apply("readback_publication", { action_id = retried }).ok and W.worker(f, member).project_held
		and not f.authority.registry.dispatch.projects[project].started, "generic readback cannot turn START uncertainty into a re-publication")
	local twin = W.cold(f)
	local restored = twin.authority.registry.dispatch.projects[project]
	check(restored.start.bytes == original.bytes and restored.start.action_id == original.action_id and not restored.started,
		"cold reload retains one grant and publication uncertainty without releasing held work")
	check(W.restores(f), "failed and uncertain original START remain valid durable state")
end

if section == nil or section == "project_start_publication" then
	local f = W.src_fixture({ auto_start_projects = false }); local cid = W.coordinator(f)
	local project, member = W.held_proposal(f, cid); assert(W.project_start(f, project).ok)
	local action
	for _ = 1, 16 do
		local selected = W.start_publication(f, cid, project)
		if f:action(selected).request.part == "manifest" then action = selected; break end
		assert(f:finish(selected, "published", {}).ok)
	end
	assert(action, "original manifest action")
	assert(f:apply("claim", { action_id = action, executor = f.origin.window_epoch }).ok)
	local a = f:action(action); local request = api.clone(a.request)
	assert(f:apply("lost", { action_id = action, executor = f.origin.window_epoch, grant_id = a.claim.grant_id }).ok)
	assert(W.ack(f, cid, f.authority.registry.dispatch.projects[project].start).ok)
	local start = f.authority.registry.dispatch.projects[project].start
	check(start.acknowledged and not start.published and W.worker(f, cid).replies[tostring(start.reply_seq)] ~= nil
		and not W.start_claim(f, cid, project).ok and W.worker(f, member).project_held,
		"early authentic consumption retains original publication bytes but cannot release work during publication uncertainty")
	assert(f:finish(action, "published", { wake_status = "awaiting_window", wake_effect_started = false,
		wake_target_request_id = request.request_id, wake_target_action_id = request.action_id }).ok)
	start = f.authority.registry.dispatch.projects[project].start
	check(start.published and start.publication.request_bytes ~= nil and start.publication.response_bytes ~= nil
		and W.worker(f, cid).wakes[request.action_id] ~= nil and not f.authority.registry.dispatch.projects[project].started,
		"complete manifest-last publication proof is durable before native wake and still is not a START claim")
	assert(W.start_claim(f, cid, project).ok)
	check(f.authority.registry.dispatch.projects[project].started and W.restores(f),
		"the original status outcome can settle after consume, and only the subsequent exact accepted claim releases work")
	local damaged = api.clone(f.authority.registry)
	damaged.dispatch.projects[project].start.publication.response_bytes = "{}"
	check(api.state.rehydrate(damaged) == nil, "restore validates full original publication evidence instead of trusting a published boolean")
end

if section == nil or section == "project_start_policy" then
	local f = W.src_fixture({ auto_start_projects = true }); local cid = W.coordinator(f)
	local project, manual = W.held_proposal(f, cid)
	local text, tags = "The owner enabled automatic admission of this source.", W.arr({ "docs" })
	local added = f:apply("board_intake", { orch_project_id = project, board_path = "/fixture/automatic-start.md",
		card_id = "policy-card", text = text, tags = tags, text_sha256 = api.quota.digest({ text = text, tags = tags }) })
	assert(added.ok, added.message)
	local p = f.authority.registry.dispatch.projects[project]; local grant = api.clone(p.start)
	check(grant and grant.source.kind == "policy" and grant.source.rule == "auto_start_projects"
		and #grant.source.policy_revision == 64 and not p.started and f.authority.registry.dispatch.intakes[added.intake_id].held,
		"saved explicit auto-start policy creates an honestly policy-sourced typed intent, never direct managed release")
	local seq = W.worker(f, cid).reply_seq
	assert(f:apply("pause").ok)
	check(W.worker(f, cid).reply_seq == seq and f.authority.registry.dispatch.projects[project].start.bytes == grant.bytes,
		"later bookkeeping and pause cannot allocate another automatic START grant")
	W.publish_start(f, cid, project); assert(W.ack(f, cid, f.authority.registry.dispatch.projects[project].start).ok)
	assert(W.start_claim(f, cid, project).ok)
	check(not f.authority.registry.dispatch.intakes[added.intake_id].held and W.worker(f, manual).project_held
		and W.worker(f, manual).checks_pending and W.provision_of(f, manual) == nil,
		"policy approval releases only its actual source snapshot and never older force-held proposal membership")
	local _, later = W.held_proposal(f, cid, project)
	check(W.worker(f, later).project_held and W.worker(f, later).checks_pending
		and f.authority.registry.dispatch.projects[project].start.action_id == grant.action_id
		and not f.authority.registry.dispatch.projects[project].start.snapshot.workers[later] and W.restores(f),
		"coordinator-proposed force-held additions remain explicit-owner-only even with auto-start enabled")
	local g = W.src_fixture({ auto_start_projects = true }); local coordinator = W.coordinator(g)
	local target = g:project("Independent future policy sources", false)
	local function policy_card(id)
		local text, tags = "Policy-admitted source " .. id, W.arr({ "docs" })
		local added = g:apply("board_intake", { orch_project_id = target, board_path = "/fixture/policy-successor.md",
			card_id = id, text = text, tags = tags, text_sha256 = api.quota.digest({ text = text, tags = tags }) })
		assert(added.ok, added.message); return added.intake_id
	end
	local revoked = policy_card("revoked")
	W.publish_start(g, coordinator, target); assert(W.ack(g, coordinator, g.authority.registry.dispatch.projects[target].start).ok)
	local old = api.clone(g.authority.registry.dispatch.projects[target].start)
	W.repository(g, "/fixture/policy-revised/.git", "refs/heads/reviewed", "orch_queue", target, "/fixture/policy-revised")
	local fresh_source = policy_card("new-policy-authority")
	local current = g.authority.registry.dispatch.projects[target].start
	check(current.action_id ~= old.action_id and current.source.kind == "policy" and current.snapshot.intakes[fresh_source]
		and not current.snapshot.intakes[revoked] and g.authority.registry.dispatch.projects[target].start_history[1].bytes == old.bytes,
		"a new policy-admitted source gets an independent typed grant while the revoked source stays excluded and correlated")
	W.publish_start(g, coordinator, target); assert(W.ack(g, coordinator, g.authority.registry.dispatch.projects[target].start).ok)
	assert(W.start_claim(g, coordinator, target).ok)
	check(g.authority.registry.dispatch.intakes[revoked].held and not g.authority.registry.dispatch.intakes[fresh_source].held
		and W.restores(g), "saved policy resumes for genuinely new membership, never by reapproving a revoked snapshot")
end
if section == nil or section == "project_start_subject" then
	local f = W.src_fixture({ auto_start_projects = false }); local cid = W.coordinator(f)
	local dir = W.scratch(); local path = W.write_plan(dir, nil, "start-source.md")
	local imported = f:apply("plan_import", { path = path }); assert(imported.ok, imported.message)
	local project = imported.orch_project_id; assert(W.project_start(f, project).ok)
	local original = api.clone(f.authority.registry.dispatch.projects[project].start)
	W.write_plan(dir, W.PLAN_TEXT:gsub("Fixture scheduling plan", "Changed source plan", 1), "start-source.md")
	assert(f:apply("plan_import", { path = path, orch_project_id = project }).ok)
	W.publish_start(f, cid, project); assert(W.ack(f, cid, f.authority.registry.dispatch.projects[project].start).ok)
	local before = W.worker(f, cid).accepted_seq
	local refused = W.start_claim(f, cid, project)
	check(refused.ok and refused.refused == "start_subject_changed" and W.worker(f, cid).accepted_seq == before + 1
		and not f.authority.registry.dispatch.projects[project].started and not W.worker(f, cid).rejected_report,
		"an authentic stale START report is consumed as a refused fact, never a work release or a blocked report lane")
	check(W.start_retry(f, project).code == "project_start_inspection"
		and f.authority.registry.dispatch.projects[project].start.bytes == original.bytes and W.restores(f),
		"Retry cannot turn a terminal stale decision into another approval")
	assert(W.project_start(f, project).ok)
	check(f.authority.registry.dispatch.projects[project].start.action_id ~= original.action_id
		and f.authority.registry.dispatch.projects[project].start_history[1].bytes == original.bytes,
		"a new explicit current-source START creates a fresh decision only after preserving the closed original")
	local reserved = W.src_fixture({ auto_start_projects = false })
	assert(reserved:apply("queue", { record_id = "omp", record_revision = 0, catalog_revision = 0, prompt = "Await actual coordinator acceptance.",
		cwd = "/fixture", placement = "split", coordinator = true }).ok)
	local target = reserved:project("Reserved coordinator must not become standalone", false)
	check(W.project_start(reserved, target).code == "start_coordinator_unavailable"
		and not reserved.authority.registry.dispatch.projects[target].started,
		"a reserved coordinator cannot be misrepresented as an absent coordinator to bypass typed START")
end

if section == nil or section == "project_start_active" then
	local f = W.src_fixture({ auto_start_projects = true }); local cid = W.coordinator(f)
	local project = f.default_project; assert(f.authority.registry.dispatch.projects[project].started)
	assert(f:apply("pause").ok)
	local queued = f:apply("queue", { orch_project_id = project, record_id = "builder", record_revision = 0, catalog_revision = 0,
		prompt = "Continue already approved work after pause.", cwd = "/fixture", placement = "split", coordinator = false })
	assert(queued.ok, queued.message)
	local approved = W.worker(f, queued.worker_id); assert(approved.project_held and not approved.checks_pending)
	local text, tags = "Automatically approved new source", W.arr({ "docs" })
	local source = f:apply("board_intake", { orch_project_id = project, board_path = "/fixture/active-start.md", card_id = "active-source",
		text = text, tags = tags, text_sha256 = api.quota.digest({ text = text, tags = tags }) }); assert(source.ok, source.message)
	local p = f.authority.registry.dispatch.projects[project]
	check(p.started and p.start and not p.start.snapshot.workers[queued.worker_id] and not W.worker(f, queued.worker_id).checks_pending,
		"a new scoped policy START preserves existing project permission and does not reclassify pause-held approved work")
	assert(f:apply("resume").ok)
	check(f.authority.registry.dispatch.projects[project].started and not W.worker(f, queued.worker_id).checks_pending,
		"Resume remains sufficient for already-approved work while the separate new-source START is pending")
	check(f.authority.registry.dispatch.intakes[source.intake_id].held and W.restores(f),
		"preserving ACTIVE does not release the new unclaimed source")
end
if section == nil or section == "project_start_mailbox" then
	local f = W.src_fixture({ auto_start_projects = false }); local cid = W.coordinator(f)
	local project, member = W.held_proposal(f, cid); assert(W.project_start(f, project).ok)
	W.publish_start(f, cid, project); assert(W.ack(f, cid, f.authority.registry.dispatch.projects[project].start).ok)
	local old = api.clone(f.authority.registry.dispatch.projects[project].start)
	W.repository(f, "/fixture/revised/.git", "refs/heads/reviewed", "orch_queue", project, "/fixture/revised")
	check(f.authority.registry.dispatch.projects[project].start.closed ~= nil, "known settled stale source decision closes without discarding its original correlation")
	assert(W.project_start(f, project).ok)
	local fresh = api.clone(f.authority.registry.dispatch.projects[project].start)
	assert(fresh.action_id ~= old.action_id)
	local bytes = W.claim_report(f, cid, old); local before = W.worker(f, cid).accepted_seq
	check(W.mailbox_start_report(f, cid, bytes).code == "bridge_committed" and W.worker(f, cid).accepted_seq == before + 1
		and W.worker(f, cid).rejected_report == nil and W.worker(f, cid).receipts[tostring(before + 1)].kind == "PROJECT_START_CLAIM",
		"the actual mailbox-read route consumes an exact late closed-grant report as a refused fact instead of reject_read")
	check(not f.authority.registry.dispatch.projects[project].started and W.worker(f, member).checks_pending
		and f.authority.registry.dispatch.projects[project].start.action_id == fresh.action_id
		and f.authority.registry.dispatch.projects[project].start_history[1].closed.report_bytes == bytes,
		"accepting the old report's receipt releases nothing and cannot match the fresh grant")
	assert(W.ack(f, cid, f.authority.registry.dispatch.projects[project].start).ok)
	assert(W.mailbox_start_report(f, cid, W.claim_report(f, cid, fresh)).ok)
	check(f.authority.registry.dispatch.projects[project].started and W.worker(f, cid).rejected_report == nil and W.restores(f),
		"a fresh exact grant remains usable after the refused old report and its receipt")
	local g = W.src_fixture({ auto_start_projects = false }); local coordinator = W.coordinator(g)
	local empty = g:project("Finish must retain exact claim lookup", false)
	assert(W.project_start(g, empty).ok)
	W.publish_start(g, coordinator, empty); assert(W.ack(g, coordinator, g.authority.registry.dispatch.projects[empty].start).ok)
	local earlier = api.clone(g.authority.registry.dispatch.projects[empty].start)
	W.repository(g, "/fixture/finish-revised/.git", "refs/heads/reviewed", "orch_queue", empty, "/fixture/finish-revised")
	local function finish_empty()
		local p = g.authority.registry.dispatch.projects[empty]
		return g:apply("project_finish", { orch_project_id = empty, project_revision = p.revision, result = "No implementation work was admitted." })
	end
	check(not finish_empty().ok and not g.authority.registry.dispatch.projects[empty].finished,
		"an otherwise empty project cannot discard its acknowledged START before the authentic claim/refusal arrives")
	assert(W.project_start(g, empty).ok)
	W.publish_start(g, coordinator, empty); assert(W.ack(g, coordinator, g.authority.registry.dispatch.projects[empty].start).ok)
	local latest = api.clone(g.authority.registry.dispatch.projects[empty].start)
	assert(W.mailbox_start_report(g, coordinator, W.claim_report(g, coordinator, latest)).ok)
	check(not finish_empty().ok and g.authority.registry.dispatch.projects[empty].start_history[1].bytes == earlier.bytes,
		"settling the current grant cannot discard a historical exact claim that has not arrived")
	assert(W.mailbox_start_report(g, coordinator, W.claim_report(g, coordinator, earlier)).ok)
	check(finish_empty().ok and g.authority.registry.dispatch.projects[empty].finished and W.worker(g, coordinator).rejected_report == nil,
		"the real mailbox route consumes the historical refusal and only then allows project history compaction")
end
if section == nil or section == "project_start_malformed" then
	local f = W.src_fixture({ auto_start_projects = false }); local cid = W.coordinator(f)
	local project = W.held_proposal(f, cid); assert(W.project_start(f, project).ok)
	W.publish_start(f, cid, project); assert(W.ack(f, cid, f.authority.registry.dispatch.projects[project].start).ok)
	local s = f.authority.registry.dispatch.projects[project].start
	local report = runtime.json.decode(W.claim_report(f, cid, s)); report.action_revision += 1
	local before = W.worker(f, cid).accepted_seq
	check(W.mailbox_start_report(f, cid, runtime.json.encode(report)).code == "report_rejected"
		and W.worker(f, cid).accepted_seq == before and W.worker(f, cid).rejected_report.code == "start_claim_unauthorized"
		and not f.authority.registry.dispatch.projects[project].started,
		"the real reject_read path retains a forged action revision without an acceptance receipt, skipped sequence or release")
end

if section == nil or section == "project_start_retirement" then
	local f = W.src_fixture({ auto_start_projects = false }); local cid = W.coordinator(f)
	local other = f:project("Another acknowledged START", false)
	assert(W.project_start(f, other).ok)
	W.publish_start(f, cid, other); assert(W.ack(f, cid, f.authority.registry.dispatch.projects[other].start).ok)
	local other_start = api.clone(f.authority.registry.dispatch.projects[other].start)
	W.settle(f, cid, true)
	local project, member = W.held_proposal(f, cid)
	local gate = W.proposal_gate(f)
	W.deliver(f, cid, gate.id)
	assert(W.project_start(f, project).ok)
	local original = api.clone(f.authority.registry.dispatch.projects[project].start)
	assert(f:apply("observe", { worker_id = cid, pane_binding = api.clone(W.worker(f, cid).pane_binding), native_state = "idle" }).ok)
	check(not f:apply("retire", { worker_id = cid, withdraw_starts = true }).ok,
		"an unpublished START and an unconsumed non-START reply cannot be withdrawn")
	W.publish_start(f, cid, project)
	check(not f:apply("retire", { worker_id = cid, withdraw_starts = true }).ok,
		"complete START publication cannot bypass an unrelated owner-decision consumption obligation")
	assert(W.ack(f, cid, f.authority.registry.dispatch.gates[gate.id].delivery).ok)
	W.settle(f, cid, true)
	local before = api.clone(W.worker(f, cid))
	assert(before.reply_floor < original.reply_seq and before.release == nil and before.compacted_floor == before.accepted_seq)
	assert(f:apply("observe", { worker_id = cid, pane_binding = api.clone(before.pane_binding), native_state = "working" }).ok)
	check(not f:apply("retire", { worker_id = cid, withdraw_starts = true }).ok,
		"a working coordinator cannot be stopped merely because its START is pending")
	assert(f:apply("observe", { worker_id = cid, pane_binding = api.clone(before.pane_binding), native_state = "idle" }).ok)
	local ready = api.dispatch.project(f.authority.registry, f.origin.logical_session_id).workers[cid]
	check(ready.start_retirement_ready and ready.start_retirement_requested == false and ready.start_retirement == nil,
		"only safe withdrawal eligibility, never the private original grants or retirement proof, is projected")
	assert(f:apply("retire", { worker_id = cid, withdraw_starts = true }).code == "start_retirement_requested")
	local intent = runtime.json.encode(W.worker(f, cid).start_retirement)
	check(f:apply("retire", { worker_id = cid, withdraw_starts = true }).code == "retirement_already_requested"
		and runtime.json.encode(W.worker(f, cid).start_retirement) == intent, "repeated owner withdrawal retains the one exact intent")
	check(W.worker(f, cid).release == nil and W.worker(f, cid).reply_floor == before.reply_floor
		and not f.authority.registry.dispatch.projects[project].started and W.worker(f, member).checks_pending,
		"withdrawal records no ACK, self-release, floor advancement or task permission")
	check(W.project_start(f, project).code == "project_start_pending", "fresh START remains blocked until real old-owner closure")
	local before_other = W.worker(f, cid).accepted_seq
	local refused_other = f:apply("intake", { worker_id = cid, bytes = W.claim_report(f, cid, other_start) })
	check(refused_other.ok and refused_other.refused == "start_owner_changed" and W.worker(f, cid).accepted_seq == before_other + 1
		and W.worker(f, cid).rejected_report == nil and not f.authority.registry.dispatch.projects[other].started,
		"withdrawal consumes a late acknowledged START from another project as a refused fact instead of holding the report lane")
	W.settle(f, cid, true)
	local final_report_floor, final_report_chain = W.worker(f, cid).compacted_floor, W.worker(f, cid).compacted_chain
	local stop = f:apply("poll", { worker_id = cid }); assert(stop.ok and stop.action_id)
	local stop_request = api.clone(f:action(stop.action_id).request); assert(stop_request.op == "stop")
	check(f:finish(stop.action_id, "uncertain", nil).code == "effect_uncertain"
		and f:apply("retry", { action_id = stop.action_id }).code == "retry_refused"
		and W.project_start(f, project).code == "project_start_pending", "uncertain native stop stays fenced and cannot grant successor approval")
	assert(f:finish(stop.action_id, "stopped", { pane_binding = stop_request.pane_binding, observation = "exited" }).ok)
	check(f.authority.registry.sessions[f.origin.logical_session_id].orchestrator ~= nil and W.project_start(f, project).code == "project_start_pending",
		"positive native exit alone neither retires communication nor releases the owner")
	local retire = f:apply("poll", { worker_id = cid }); assert(retire.ok and retire.action_id)
	local request = api.clone(f:action(retire.action_id).request)
	check(request.op == "mailbox_retire" and request.mode == "retire" and request.reply_floor == before.reply_floor
		and request.report_floor == final_report_floor and request.report_chain_sha256 == final_report_chain
		and #request.withdrawn_starts == 1 and request.withdrawn_starts[1].reply_seq == original.reply_seq
		and request.withdrawn_starts[1].message_id == original.message_id
		and request.withdrawn_starts[1].message_sha256 == api.codec.sha256(original.bytes),
		"real retirement carries only the closed original START tail and actual unchanged floors/receipt chain")
	check(f:finish(retire.action_id, "uncertain", nil).code == "effect_uncertain"
		and f:apply("poll", { worker_id = cid }).code == "operation_pending",
		"uncertain physical retirement retains its one exact request without a replacement")
	assert(f:finish(retire.action_id, "retired", {}).code == "coordinator_retired")
	local retired = W.worker(f, cid); local p = f.authority.registry.dispatch.projects[project]
	check(retired.stopped and retired.mailbox_retired and retired.release == nil and retired.reply_floor == before.reply_floor
		and not p.start.acknowledged and p.start.closed.retired and not p.started
		and f.authority.registry.sessions[f.origin.logical_session_id].orchestrator == nil,
		"real stop, exact physical retirement and generation fencing close the unconsumed grant without manufacturing consumption")
	check(W.restores(f), "withdrawn original bytes and positive retirement proof restore together")
	local successor = W.coordinator(f)
	assert(W.project_start(f, project).ok)
	p = f.authority.registry.dispatch.projects[project]
	check(p.start.coordinator.worker_id == successor and p.start.action_id ~= original.action_id
		and p.start_history[1].bytes == original.bytes and W.worker(f, member).checks_pending,
		"fresh explicit approval targets the real successor and retains immutable terminal original correlation")
	local refused = f:apply("intake", { worker_id = cid, bytes = W.claim_report(f, cid, original) })
	check(refused.ok and refused.refused == "start_owner_revoked" and not f.authority.registry.dispatch.projects[project].started,
		"an exact late original claim is a consumed refused fact, never successor permission")
	W.publish_start(f, successor, project)
	assert(W.ack(f, successor, f.authority.registry.dispatch.projects[project].start).ok)
	assert(W.start_claim(f, successor, project).ok)
	check(f.authority.registry.dispatch.projects[project].started and not W.worker(f, member).checks_pending
		and W.restores(f), "only the successor's original published and consumed grant releases captured work")
end

if section == nil or section == "passive_proposals" then
	local f = W.src_fixture({ auto_start_projects = true, auto_approve_kinds = W.arr({ "dispatch" }) })
	local cid = W.coordinator(f)
	assert(f:apply("pause").ok)
	assert(W.propose(f, cid, "new_work", nil, { new_project_name = "Proposed research",
		record_id = "builder", record_revision = 0, prompt = "Investigate the specified source without widening scope.",
		scope = { paths = W.arr({ "src/research.luau" }), systems = W.arr() },
		checks = W.arr({ { check_id = "research-check", argv = W.arr({ "luau", "tests/research.luau" }) } }) }).ok)
	local gate = W.proposal_gate(f)
	check(gate.answer == nil, "passive proposal requires owner review despite old dispatch auto-approval policy and no parent checkpoint")
	local proposal = assert(api.codec.decode_report(gate.proposal, W.worker(f, cid)))
	check(proposal.payload.work_id == nil and proposal.payload.project_id == nil, "passive proposal never invents a parent checkpoint binding")
	assert(f:apply("answer", { gate_id = gate.id, gate_revision = gate.revision, choice_id = "approve", answer = "Add this held task." }).ok)
	local work
	for _, worker in f.authority.registry.dispatch.workers do if worker.worker_id ~= cid then work = worker end end
	assert(work, "approved passive task missing")
	local project = f.authority.registry.dispatch.projects[work.orch_project_id]
	check(work.project_held and work.checks_pending and not project.started and W.provision_of(f, work.worker_id) == nil,
		"approval while paused adds real held work, not a launch")
	check(work.checks[1].argv[2] == "tests/research.luau" and work.scope.paths[1] == "src/research.luau",
		"literal check argv and scope reach the pending work")
	check(not f:apply("project_start", { orch_project_id = project.orch_project_id, project_revision = project.revision }).ok,
		"START cannot bypass review of proposed check commands")
	assert(f:apply("project_start", { orch_project_id = project.orch_project_id, project_revision = project.revision, checks_reviewed = true }).ok)
	check(not f.authority.registry.dispatch.projects[project.orch_project_id].started and W.provision_of(f, work.worker_id) == nil,
		"managed START during pause records a grant without release or native effect")
	W.publish_start(f, cid, project.orch_project_id)
	assert(W.ack(f, cid, f.authority.registry.dispatch.projects[project.orch_project_id].start).ok)
	assert(W.start_claim(f, cid, project.orch_project_id).ok)
	check(f.authority.registry.dispatch.projects[project.orch_project_id].started and W.provision_of(f, work.worker_id) == nil,
		"accepted START claim records approval during pause but still performs no native launch")
	check(W.restores(f), "passive proposal, owner decision and held start restore coherently")

	local dir = W.scratch()
	for _, kind in { "plan_file", "template", "board" } do
		local templates = W.arr({ { id = "notes", title = "Notes", prompt = "Summarize {input}.", output = "notes.md", next = "", custom_fields = {} } })
		local g = W.src_fixture({ auto_start_projects = true, templates = templates })
		local coordinator = W.coordinator(g)
		assert(g:apply("pause").ok)
		local cards = W.arr({ { card_id = "passive-card", text = "Document the observation.", tags = W.arr({ "docs" }),
			text_sha256 = api.quota.digest({ text = "Document the observation.", tags = W.arr({ "docs" }) }) } })
		local source
		if kind == "plan_file" then source = { kind = kind, path = W.write_plan(dir, nil, "proposal.md"), revision = api.codec.sha256(W.PLAN_TEXT) }
		elseif kind == "template" then source = { kind = kind, template_id = "notes", revision = api.quota.digest(templates[1]), input = "the observed source" }
		else source = { kind = kind, path = dir .. "/board.md", revision = api.quota.digest(cards) } end
		assert(W.propose(g, coordinator, "add_source", nil, { new_project_name = "Passive " .. kind, source = source }).ok)
		local proposed = W.proposal_gate(g)
		assert(g:apply("answer", { gate_id = proposed.id, gate_revision = proposed.revision, choice_id = "approve", answer = "Add, but do not start." }).ok)
		local admitted = g.authority.registry.dispatch.gates[proposed.id]
		if kind == "board" then
			check(admitted.execution.state == "pending" and next(g.authority.registry.dispatch.intakes or {}) == nil,
				"board approval waits for an actual desktop snapshot rather than scraping a file")
			local before = runtime.json.encode(g.authority.registry)
			check(not g:apply("source_request", { gate_id = admitted.id, gate_revision = admitted.revision,
				source_revision = api.quota.digest({}), cards = W.arr() }).ok and runtime.json.encode(g.authority.registry) == before,
				"a changed snapshot cannot consume the approved source request")
			assert(g:apply("source_request", { gate_id = admitted.id, gate_revision = admitted.revision,
				source_revision = source.revision, cards = cards }).ok)
		end
		local workers = 0; for _ in g.authority.registry.dispatch.workers do workers += 1 end
		check(workers == 1, kind .. " approval creates no worker beyond the already active coordinator")
		local held = false
		for _, value in g.authority.registry.dispatch.plans or {} do held = held or value.held == true end
		for _, value in g.authority.registry.dispatch.intakes or {} do held = held or value.held == true end
		for _, value in g.authority.registry.dispatch.chains or {} do held = held or value.held == true end
		check(held and W.restores(g), kind .. " is a durable held source even under saved auto-start policy")
	end
end

if section == nil or section == "plan_capacity" then
	local dir, f = W.scratch(), W.src_fixture({ auto_start_projects = false })
	local admitted = {}
	for i = 1, 9 do
		local imported = f:apply("plan_import", { path = W.write_plan(dir, nil, "plan-" .. tostring(i) .. ".md") })
		assert(imported.ok, imported.message); table.insert(admitted, imported.plan_id)
	end
	local count = 0; for _ in f.authority.registry.dispatch.plans do count += 1 end
	check(count == 9 and W.effects(f) == "", "plan admission has no four-plan cap and starts no work")
	for _, id in admitted do check(W.plan(f, id).status == "active" and W.plan(f, id).held == true,
		"admitting another plan does not evict an active held plan") end
	check(#runtime.json.encode(f.authority.registry) < 8 * 1024 * 1024 - 512 * 1024 and W.restores(f),
		"admitted plans retain the settlement reserve and all associations restore")
end

if section == nil or section == "project_review" then
	for _, kind in { "plan", "board", "template" } do
		local templates = W.arr({ { id = "held-notes", title = "Notes", prompt = "Summarize {input}.", output = "notes.md", next = "", custom_fields = {} } })
		local f = W.src_fixture({ auto_start_projects = true, templates = templates })
		local project = f:project("Only this new source is automatic", false)
		local queued = f:apply("queue", { orch_project_id = project, record_id = "builder", record_revision = 0, catalog_revision = 0,
			prompt = "This earlier manual task still needs START.", cwd = "/fixture", placement = "split", coordinator = false })
		assert(queued.ok and queued.action_id == nil)
		local added
		if kind == "plan" then added = f:apply("plan_import", { orch_project_id = project, path = W.write_plan(W.scratch()) })
		elseif kind == "board" then
			local tags = W.arr({ "class-docs" })
			added = f:apply("board_intake", { orch_project_id = project, board_path = "/fixture/native-board.md", card_id = "new-auto-card",
				text = "Document the new source.", tags = tags, text_sha256 = api.quota.digest({ text = "Document the new source.", tags = tags }) })
		else added = f:apply("template_start", { orch_project_id = project, template_id = "held-notes", input = "only the new source" }) end
		assert(added.ok, added.message)
		check(f.authority.registry.dispatch.projects[project].started and W.worker(f, queued.worker_id).checks_pending
			and W.provision_of(f, queued.worker_id) == nil, kind .. ": auto-start intake cannot release older unrelated held work")
		check(W.restores(f), kind .. ": independent hold survives restoration")
	end
	do
		local f = W.src_fixture({ auto_start_projects = false })
		local title = string.rep("a", 159) .. "—漢字"
		local bytes = W.PLAN_TEXT:gsub("Fixture scheduling plan", function() return title end, 1)
		local imported = f:apply("plan_import", { path = W.write_plan(W.scratch(), bytes, "unicode.md") }); assert(imported.ok, imported.message)
		local name = f.authority.registry.dispatch.projects[imported.orch_project_id].name
		check(name == string.rep("a", 159) and utf8.len(name) == 159, "project titles stop before a split UTF-8 codepoint")
		local old = api.clone(f.authority.registry)
		old.version = 4; old.dispatch.projects = nil; old.dispatch.finished_projects = nil
		old.installation_defaults.policy.auto_start_projects = nil; old.installation_defaults.policy.auto_launch_intake = false
		for _, policy in old.dispatch.policies do policy.auto_start_projects = nil; policy.auto_launch_intake = false end
		for _, plan in old.dispatch.plans do plan.orch_project_id = nil; plan.held = nil end
		local converted, info = api.state.rehydrate(old)
		assert(converted, info and info.message)
		local parent = converted.dispatch.projects[converted.dispatch.plans[imported.plan_id].orch_project_id]
		check(parent.name == name and converted.authority_namespace == old.authority_namespace
			and converted.dispatch.plans[imported.plan_id].plan_revision == imported.plan_revision,
			"v4 Unicode plan conversion preserves source identity while producing a valid bounded display name")
	end
	do
		local f = W.fixture({ reviewer_records = W.arr({ "codex" }) })
		local builder, lid = W.granted(f, "project-finish-proof", "refs/heads/project-finish")
		local rm, project = W.holder(f, lid), W.worker(f, builder).orch_project_id
		local function finish_project()
			return f:apply("project_finish", { orch_project_id = project,
				project_revision = f.authority.registry.dispatch.projects[project].revision, result = "Code task settled." })
		end
		check(not finish_project().ok, "an issued landing grant still blocks project finish")
		assert(W.ack(f, rm, W.grant(f, lid)).ok)
		assert(W.landing_result(f, rm, lid, "uncertain", { reason = "Result needs owner inspection." }).ok)
		check(not finish_project().ok, "release-manager infrastructure exemption cannot abandon an uncertain landing")
		assert(f:apply("reconcile_landing", { landing_id = lid, landing_revision = W.item(f, lid).revision, outcome = "landed",
			target_revision = "project-finished-head", reason = "Inspected target read-only.", operator_verified = true }).ok)
		assert(W.ack(f, rm, W.attempt(f, lid)).ok)
		assert(W.deploy_result(f, lid, "not_applicable", { reason = "This task defines no deployment." }).ok)
		local members = {}
		for id in f.authority.registry.dispatch.workers do table.insert(members, id) end
		for _, id in members do W.drain(f, id); W.settle(f, id, true) end
		for _, id in members do if id ~= rm then
			if not W.worker(f, id).finish then assert(f:apply("finish", { worker_id = id }).ok) end
			for _ = 1, 8 do
				if W.worker(f, id).mailbox_retired then break end
				local next_step = f:apply("poll", { worker_id = id }); assert(next_step.ok and next_step.action_id, next_step.message)
				local request = f:action(next_step.action_id).request
				if request.op == "stop" then
					assert(f:finish(next_step.action_id, "stopped", { pane_binding = api.clone(request.pane_binding), observation = "absent" }).ok)
				elseif request.op == "mailbox_retire" then assert(f:finish(next_step.action_id, if request.mode == "retire" then "retired" else "compacted", {}).ok)
				else error("unexpected settlement operation " .. request.op) end
			end
			assert(W.worker(f, id).mailbox_retired, "ordinary project member failed to settle")
		end end
		check(f.authority.registry.dispatch.projects[project].finished == true
			and W.worker(f, rm).phase == "accepted" and W.worker(f, rm).finish == nil and W.worker(f, rm).mailbox_retired ~= true,
			"settled business work reaches finished history without stopping its session release manager")
		check(W.restores(f), "finished project and live settled infrastructure restore together")
	end
end

-- Settle a real accepted member through its public stop and mailbox-retirement protocol.
function W.close_member(f, id)
	W.drain(f, id); W.settle(f, id, true)
	if not W.worker(f, id).finish then assert(f:apply("finish", { worker_id = id }).ok) end
	for _ = 1, 8 do
		if W.worker(f, id).mailbox_retired then return end
		local next_step = f:apply("poll", { worker_id = id }); assert(next_step.ok and next_step.action_id, next_step.message)
		local request = f:action(next_step.action_id).request
		if request.op == "stop" then
			assert(f:finish(next_step.action_id, "stopped", { pane_binding = api.clone(request.pane_binding), observation = "absent" }).ok)
		elseif request.op == "mailbox_retire" then
			assert(f:finish(next_step.action_id, if request.mode == "retire" then "retired" else "compacted", {}).ok)
		else error("unexpected settlement operation " .. request.op) end
	end
	assert(W.worker(f, id).mailbox_retired, "member did not settle through its bounded retirement protocol")
end
if section == nil or section == "project_gate_rearm" then
	for _, choice in { "launch_anyway", "cancel" } do
		local f = W.src_fixture()
		local queued = f:apply("queue", { record_id = "builder", record_revision = 0, catalog_revision = 0,
			prompt = "Previously queued manual work.", cwd = "/fixture", placement = "split", coordinator = false })
		assert(queued.ok and queued.action_id, queued.message)
		local raw = api.clone(f.authority.registry)
		raw.version = 4; raw.dispatch.projects = nil; raw.dispatch.finished_projects = nil
		raw.installation_defaults.policy.auto_start_projects = nil; raw.installation_defaults.policy.auto_launch_intake = false
		for _, policy in raw.dispatch.policies do policy.auto_start_projects = nil; policy.auto_launch_intake = false end
		for _, worker in raw.dispatch.workers do worker.orch_project_id = nil; worker.presentation = nil; worker.selected_record = nil end
		local restored, info = api.state.rehydrate(raw); assert(restored, info and info.message)
		f.authority.registry = restored; f.memory.value = api.clone(restored)
		assert(f:apply("continue_controller", { operator_verified = true }).ok)
		assert(f:control("reconcile_session").ok); W.catalog(f)
		local project = W.worker(f, queued.worker_id).orch_project_id
		assert(f:apply("policy", { policy = { auto_start_projects = true,
			templates = W.arr({ { id = "new-notes", title = "Notes", prompt = "Describe {input}.", output = "notes.md", next = "", custom_fields = {} } }) } }).ok)
		assert(f:apply("template_start", { orch_project_id = project, template_id = "new-notes", input = "only this new source" }).ok)
		assert(W.worker(f, queued.worker_id).checks_pending and f:action(queued.action_id).phase == "held_ready")
		local other = f:project("Independent checkout peer", true)
		W.repository(f, "/fixture/repository/.git", "refs/heads/main", "orch_queue", other, "/fixture/worktree")
		local peer = f:allow_shared_fixture(f:apply("queue", { orch_project_id = other, record_id = "codex", record_revision = 0,
			catalog_revision = 0, prompt = "Independent peer work.", cwd = "/fixture", placement = "split", coordinator = false }))
		assert(peer.ok, peer.message)
		assert(f:apply("project_start", { orch_project_id = project, project_revision = f.authority.registry.dispatch.projects[project].revision }).ok)
		local worker = W.worker(f, queued.worker_id); assert(worker.launch_gates and #worker.launch_gates > 0)
		check(f:action(queued.action_id).phase == "held_ready"
			and api.dispatch.project(f.authority.registry, f.origin.logical_session_id, f.origin.alias_nonce, queued.action_id).actions[queued.action_id].start_blocked
			and not f:apply("claim", { action_id = queued.action_id, executor = f.origin.window_epoch }).ok,
			choice .. ": START cannot issue a retained provision before its newly required checkout decision")
		local gate = f.authority.registry.dispatch.gates[worker.launch_gates[1]]
		local answered = f:apply("answer", { gate_id = gate.id, gate_revision = gate.revision, choice_id = choice,
			answer = "Exact owner checkout decision." }); assert(answered.ok, answered.message)
		if choice == "cancel" then
			check(W.worker(f, queued.worker_id) == nil and f:action(queued.action_id) == nil and W.worker(f, peer.worker_id) ~= nil,
				"cancelling the gate removes only the worker and its proven-unissued provision")
		else
			local provisions = 0
			for _, action in f.authority.registry.dispatch.actions do
				if action.worker_id == queued.worker_id and action.request.op == "mailbox_provision" then provisions += 1 end
			end
			check(provisions == 1 and answered.action_id == queued.action_id and f:action(queued.action_id).phase == "ready",
				"approval rearms the original provision instead of allocating a second mailbox")
		end
		check(W.restores(f), choice .. ": gate settlement has no dangling worker, action or decision")
	end
end
if section == nil or section == "project_plan_reopen" then
	for _, revised in { false, true } do
		local f = W.src_fixture({ auto_start_projects = false })
		local body = "# Feature: A repeatable plan\n\n## Plan\n\n### Checkpoint 1 — Work\n\n#### Task 1A — Read\n**INDEPENDENT**\n### UPDATE `notes.txt`\n"
		local path = W.write_plan(W.scratch(), body, "repeat.md")
		local imported = f:apply("plan_import", { path = path }); assert(imported.ok, imported.message)
		local project = f.authority.registry.dispatch.projects[imported.orch_project_id]
		assert(f:apply("project_start", { orch_project_id = project.orch_project_id, project_revision = project.revision, checks_reviewed = true }).ok)
		local task = W.task(W.plan(f, imported.plan_id), "1A")
		W.complete(f, task.worker_id); W.close_member(f, task.worker_id)
		assert(f.authority.registry.dispatch.projects[project.orch_project_id].finished)
		local old = runtime.json.encode(W.plan(f, imported.plan_id))
		local reopened = f:apply("project_reopen", { summary_index = #f.authority.registry.dispatch.finished_projects }); assert(reopened.ok)
		if revised then runtime.fs.write(path, body .. "\nA newly inspected revision.\n") end
		local added = f:apply("plan_import", { path = path, orch_project_id = reopened.orch_project_id })
		check(added.ok and added.plan_id ~= imported.plan_id and added.orch_project_id == reopened.orch_project_id,
			"explicit re-add after Finish/Reopen creates a distinct plan for " .. (if revised then "new" else "identical") .. " source bytes")
		local fresh = W.task(W.plan(f, added.plan_id), "1A")
		check(fresh.state == "queued_plan" and fresh.worker_id == nil and fresh.work_id == nil
			and not f.authority.registry.dispatch.projects[reopened.orch_project_id].started
			and runtime.json.encode(W.plan(f, imported.plan_id)) == old,
			"reopening preserves the old outcome without carrying completed work or START authority into the new project")
		check(W.restores(f), "old completed plan and new passive re-import restore independently")
	end
end
if section == nil or section == "project_live_conversation" then
	for _, kind in { "association", "open", "enrol" } do
		local board = "/fixture/lifecycle-board.tern"
		local f = W.src_fixture({ board_path = board })
		local project = f.default_project
		local pane = { pane_id = tostring(9700 + W.serial + 1), window_key = f.origin.window_key, window_epoch = f.origin.window_epoch,
			native_session_id = f.origin.native_session_id, window_host_id = f.origin.window_host_id }
		local conversation
		if kind == "association" then
			assert(f:apply("associate_conversation", { orch_project_id = project, project_revision = f.authority.registry.dispatch.projects[project].revision,
				pane_binding = pane, active = false }).ok)
		else
			local fields = { orch_project_id = project, record_id = "builder", record_revision = 0, catalog_revision = 0 }
			if kind == "enrol" then fields.pane_binding = pane; fields.delivery = "native_ask"
			else fields.prompt = api.codec.OPEN_CONVERSATION_ASSIGNMENT; fields.cwd = "/fixture"; fields.placement = "split"
				fields.coordinator = false; fields.open_conversation = true; fields.presentation = "user_new_tab" end
			local queued = f:apply(if kind == "enrol" then "enrol" else "queue", fields); assert(queued.ok, queued.message)
			conversation = W.start(f, queued.worker_id, queued.action_id)
			W.settle(f, conversation, true)
		end
		local text, tags = string.rep("x", 4097), W.arr()
		local outcome = f:apply("board_intake", { orch_project_id = project, board_path = board, card_id = "settled-refusal", text = text,
			tags = tags, text_sha256 = api.quota.digest({ text = text, tags = tags }) })
		assert(outcome.ok and outcome.code == "intake_refused", outcome.message)
		check(not f.authority.registry.dispatch.projects[project].finished and #f.authority.registry.dispatch.finished_projects == 0,
			kind .. ": a settled source outcome cannot auto-finish a still-associated native conversation")
		if conversation then W.settle(f, conversation, true) end
		local finished = f:apply("project_finish", { orch_project_id = project,
			project_revision = f.authority.registry.dispatch.projects[project].revision, result = "Owner explicitly ends the project, not the conversation." })
		check(finished.ok and (not conversation or not W.worker(f, conversation).stopped),
			kind .. ": explicit project Finish remains available after protocol obligations settle and does not stop native work")
	end
end
if section == nil or section == "project_deploy_boundary" then
	local f = W.fixture({ reviewer_records = W.arr({ "codex" }) })
	local builder, lid = W.granted(f, "deploy-pins-project", "refs/heads/deploy-pins-project")
	W.land(f, lid, "deploy-pins-head")
	assert(W.ack(f, W.holder(f, lid), W.attempt(f, lid)).ok)
	W.drain(f, builder); W.settle(f, builder, true)
	check(not f:apply("finish", { worker_id = builder }).ok and W.worker(f, builder).finish == nil,
		"a landed item with a live deploy still pins its source work")
	local project = W.worker(f, builder).orch_project_id
	check(not f:apply("project_finish", { orch_project_id = project,
		project_revision = f.authority.registry.dispatch.projects[project].revision, result = "Not yet settled." }).ok,
		"project completion cannot claim deployment obligations are settled while a deploy is outstanding")
	assert(W.deploy_result(f, lid, "not_applicable", { reason = "The owner-defined task has no deployment." }).ok)
	W.drain(f, builder); W.settle(f, builder, true)
	check(f:apply("finish", { worker_id = builder }).ok, "a terminal deploy releases the real source work for normal finish")
end
if section == nil or section == "project_manager_boundary" then
	local f = W.fixture({ reviewer_records = W.arr({ "codex" }) })
	local builder, lid = W.granted(f, "finished-manager", "refs/heads/finished-manager")
	local rm, project = W.holder(f, lid), W.worker(f, builder).orch_project_id
	W.land(f, lid, "finished-manager-head")
	assert(W.ack(f, rm, W.attempt(f, lid)).ok)
	assert(W.deploy_result(f, lid, "not_applicable", { reason = "No deployment is defined." }).ok)
	local members = {}
	for id in f.authority.registry.dispatch.workers do table.insert(members, id) end
	for _, id in members do W.drain(f, id); W.settle(f, id, true) end
	for _, id in members do if id ~= rm then W.close_member(f, id) end end
	assert(f.authority.registry.dispatch.projects[project].finished)
	assert(f:apply("observe", { worker_id = rm, pane_binding = api.clone(W.worker(f, rm).pane_binding), native_state = "idle" }).ok)
	assert(f:apply("policy", { policy = { auto_rollover = true, rollover_threshold_pct = 50 } }).ok)
	assert(W.send(f, rm, "READY", { state = "idle", context_used_pct = 95 }).ok)
	local due
	for _, worker in api.dispatch.project(f.authority.registry, f.origin.logical_session_id).workflow.workers do
		if worker.worker_id == rm then due = worker.due_rollover end
	end
	check(due == false and not f:apply("rollover", { worker_id = rm, trigger = "owner" }).ok
		and next(f.authority.registry.dispatch.rollovers or {}) == nil,
		"finished-project infrastructure cannot enter a permanently blocked handover")
	W.drain(f, rm); W.settle(f, rm, true)
	local original_approval = runtime.json.encode(W.item(f, lid).approval)
	local original_grants = runtime.json.encode(W.item(f, lid).grants)
	local old_gate = W.item(f, lid).gate_id
	local _, second = W.granted(f, "another-project", "refs/heads/another-project")
	check(W.holder(f, second) == rm and #W.item(f, second).grants == 1,
		"the still-live settled release manager continues granting another project's real landing")
	check(W.worker(f, builder) == nil and f.authority.registry.dispatch.gates[old_gate] == nil
		and runtime.json.encode(W.item(f, lid).approval) == original_approval
		and runtime.json.encode(W.item(f, lid).grants) == original_grants,
		"new admission reclaims the settled builder and consumed gate, not the immutable landing approval or grants")
	check(W.restores(f), "finished-project history and independent live landing restore together")
end

-- SKILLS-201: a coordinator can only propose real eligible records. The activation lists them from the
-- assembled roster; an unknown or stale record is refused at proposal time (both kinds) with the reason and
-- the list sent back; an approved proposal refused at execution reaches the coordinator; the owner re-targets
-- a refused proposal through the roster, never by typing an id.
if section == nil or section == "proposal_records" then
	local f = W.fixture({ reviewer_records = W.arr({ "codex" }) })
	local b = W.builder(f, "builder", { source = W.PLAN, files = W.arr({ "src/feature.luau" }) })
	W.settle(f, b); assert(W.send(f, b, "CHECKPOINT", W.cp("cp-1", "rev-1")).ok)
	local cid = W.coordinator(f)
	local cw = W.worker(f, cid)
	local sid = cw.logical_session_id
	local function D() return f.authority.registry.dispatch end
	local work = W.worker(f, b).work_id
	-- 1. The activation names every eligible record of the assembled roster, as record_id@revision.
	local instructions = api.codec.decode_reply(cw.activation.bytes, cw).payload.instructions
	local expected, listed = 0, 0
	for _, row in D().catalogs[sid].records do
		local token = row.id .. "@" .. string.format("%.0f", row.revision)
		local fits = row.eligible and row.enabled == true
		if fits then expected += 1 end
		if fits == (instructions:find(token, 1, true) ~= nil) then listed += 1 end
	end
	check(expected >= 5 and listed == #D().catalogs[sid].records, "the activation lists exactly the eligible roster records as record_id@revision (" .. listed .. "/" .. #D().catalogs[sid].records .. ")")
	check(instructions:find("Name only a record from the eligible list", 1, true) ~= nil, "the activation tells the coordinator to choose only from that list")
	local function refusal_gate(code)
		for _, g in D().gates do if table.find(g.evidence, "refused:" .. code) then return g end end
		return nil
	end
	local function deliver_answer(g)
		local reply = W.deliver(f, cid, g.id)
		check(reply.kind == "owner_decision" and reply.payload.choice_id == "reject" and reply.payload.answer == g.answer.answer, "gate " .. g.id .. " reaches the coordinator as one typed owner_decision reject")
		return reply.payload.answer
	end
	-- 2. Invented ids and stale revisions, for both kinds, are refused before any gate asks the owner.
	local cases = {
		{ kind = "dispatch", code = "unknown_record", fields = { record_id = "tools-docs-human-rewrite", record_revision = 0, prompt = "Do the thing." } },
		{ kind = "dispatch", code = "catalog_changed", fields = { record_id = "codex", record_revision = 7, prompt = "Do the thing." } },
		{ kind = "new_work", code = "unknown_record", fields = { orch_project_id = f.default_project, record_id = "tools-docs-human-rewrite", record_revision = 0,
			prompt = "Do the thing.", scope = { paths = W.arr({ "src/a.luau" }), systems = W.arr() }, checks = W.unit() } },
		{ kind = "new_work", code = "catalog_changed", fields = { orch_project_id = f.default_project, record_id = "codex", record_revision = 7,
			prompt = "Do the thing.", scope = { paths = W.arr({ "src/b.luau" }), systems = W.arr() }, checks = W.unit() } },
	}
	for _, case in cases do
		local before = #W.gates(f, "coordinator_proposal", false)
		local sent = W.propose(f, cid, case.kind, if case.kind == "dispatch" then work else nil, api.clone(case.fields))
		local label = case.kind .. "/" .. case.code
		check(sent.ok and sent.code == case.code and W.worker(f, cid).rejected_report == nil, label .. ": refused at proposal time, committed, never held (" .. tostring(sent.code) .. ")")
		check(#W.gates(f, "coordinator_proposal", false) == before + 1, label .. ": exactly one gate, the refusal")
		local g
		for _, candidate in D().gates do
			if candidate.answer and candidate.answer.source.kind == "refusal" and candidate.answer.source.code == case.code and not candidate.seen_by_test then g = candidate end
		end
		check(g ~= nil and g.phase == "answered" and g.answer.choice_id == "reject" and g.execution == nil, label .. ": settled reject by ORCH+, never an owner gate")
		local text = deliver_answer(g)
		check(text:find(case.code, 1, true) ~= nil and text:find("codex@0", 1, true) ~= nil and text:find("builder@0", 1, true) ~= nil,
			label .. ": the coordinator's reply names the code and the current eligible list")
		check(table.find(g.evidence, "retarget:open") ~= nil, label .. ": the refused proposal stays open for the owner to re-target")
		g.seen_by_test = true
	end
	for _, g in D().gates do g.seen_by_test = nil end
	-- 3. An approved proposal refused at execution reaches the coordinator with its code and message.
	local ok_proposal = W.propose(f, cid, "dispatch", work, { record_id = "codex", record_revision = 0, prompt = "Implement the follow-on planned task." })
	check(ok_proposal.ok and ok_proposal.code == "report_committed", "a proposal naming a real record opens its gate (" .. tostring(ok_proposal.code) .. ")")
	local pending
	for _, g in D().gates do if g.kind == "coordinator_proposal" and g.phase == "pending" then pending = g end end
	for _, row in D().catalogs[sid].records do if row.id == "codex" then row.enabled = false end end
	local approved = f:apply("answer", { gate_id = pending.id, gate_revision = pending.revision, choice_id = "approve", answer = "Go." })
	check(approved.ok and D().gates[pending.id].execution ~= nil and D().gates[pending.id].execution.state == "refused"
		and D().gates[pending.id].execution.effect_ref == "catalog_changed", "the approved proposal is refused at execution (catalog_changed)")
	local told = refusal_gate("execution_refused")
	check(told ~= nil and told.answer.source.code == "execution_refused" and told.answer.choice_id == "reject", "ORCH+ settles a second reject for the approved-then-refused proposal")
	local told_text = deliver_answer(told)
	check(told_text:find("catalog_changed", 1, true) ~= nil and told_text:find("no longer current and eligible", 1, true) ~= nil and told_text:find("builder@0", 1, true) ~= nil,
		"the coordinator receives the execution refusal's code, its message and the eligible list")
	-- Acknowledged delivery must not reclaim a refusal the owner has yet to re-target.
	local delivered = api.clone(D().gates[told.id].delivery)
	delivered.message_id = api.codec.decode_reply(delivered.bytes, cw).message_id
	check(W.ack(f, cid, delivered).ok, "the coordinator acknowledges the refusal")
	assert(f:tick()); assert(W.send(f, cid, "HEARTBEAT", { state = "working" }).ok)
	check(D().gates[told.id] ~= nil and table.find(D().gates[told.id].evidence, "retarget:open") ~= nil, "an acknowledged stale-record refusal stays on the owner's surface for re-targeting")
	for _, row in D().catalogs[sid].records do if row.id == "codex" then row.enabled = true end end
	-- 4. The owner re-targets through the roster: the same proposal id is re-issued on the chosen record.
	local stale = refusal_gate("catalog_changed")
	local catalog = D().catalogs[sid]
	local bad = f:apply("retarget_proposal", { gate_id = stale.id, gate_revision = stale.revision, record_id = "typed-by-hand", record_revision = 0, catalog_revision = catalog.revision })
	check(not bad.ok and bad.code == "unknown_record" and table.find(stale.evidence, "retarget:open") ~= nil, "a record outside the roster cannot re-target (" .. tostring(bad.code) .. ")")
	local moved = f:apply("retarget_proposal", { gate_id = stale.id, gate_revision = stale.revision, record_id = "claude2", record_revision = 0, catalog_revision = catalog.revision })
	check(moved.ok and moved.code == "proposal_retargeted", "choosing a real record re-issues the proposal (" .. tostring(moved.code) .. " " .. tostring(moved.message) .. ")")
	stale = D().gates[stale.id]
	check(table.find(stale.evidence, "retarget:done") ~= nil and table.find(stale.evidence, "retarget:open") == nil, "the refused proposal is marked re-targeted")
	local reissued
	for _, g in D().gates do
		if g.kind == "coordinator_proposal" and g.phase == "pending" and g.id ~= pending.id then reissued = g end
	end
	local payload = if reissued then api.codec.decode_report(reissued.proposal, cw).payload else nil
	check(payload ~= nil and payload.record_id == "claude2" and payload.record_revision == 0 and payload.proposal_id == api.codec.decode_report(stale.proposal, cw).payload.proposal_id,
		"the re-issued proposal waits on the owner with the chosen record and the original proposal id")
	local again = f:apply("retarget_proposal", { gate_id = stale.id, gate_revision = stale.revision, record_id = "claude2", record_revision = 0, catalog_revision = catalog.revision })
	check(not again.ok and again.code == "stale_gate", "a re-targeted proposal cannot be re-targeted twice")
	check(W.restores(f), "refused, notified and re-targeted proposal gates restore")
end

assert(section == nil or table.find({ "plan_import", "usage_delta", "review_cross_family", "review_rounds", "auto_finish", "proof_rule",
	"release_config", "release_launch", "release_refresh", "release_holder", "deploy", "deploy_held", "deploy_retry", "deploy_lost",
	"grid_queued_new_revision", "grid_queued_target_moved", "grid_queued_rm_rollover", "grid_queued_cancel",
	"grid_approved_new_revision", "grid_approved_target_moved", "grid_approved_rm_rollover", "grid_approved_cancel",
	"grid_granted_new_revision", "grid_granted_target_moved", "grid_granted_rm_rollover", "grid_granted_cancel",
	"grid_landed_new_revision", "grid_landed_target_moved", "grid_landed_rm_rollover", "grid_landed_cancel",
	"grid_deploy_held_new_revision", "grid_deploy_held_target_moved", "grid_deploy_held_rm_rollover", "grid_deploy_held_cancel",
	"autonomy", "autonomy_dispatch", "autonomy_report", "autonomy_review", "autonomy_landing", "sources", "intake", "router", "labeller_finish", "passive_proposals", "project_start", "project_start_membership", "project_start_failures", "project_start_publication", "project_start_policy", "project_start_subject", "project_start_active", "project_start_mailbox", "project_start_malformed", "project_start_retirement", "plan_capacity", "project_review",
	"project_gate_rearm", "project_plan_reopen", "project_live_conversation", "project_deploy_boundary", "project_manager_boundary",
	"assignment_policy", "autonomy_paused", "proposal_early", "repository_sessions", "repository_policy", "repository_paused",
	"proposal_records", "repository_external", "repository_result_order", "repository_targets", "repository_head", "repository_route_change", "repository_sharing" }, section), "unknown workflow section")
return "workflow/" .. tostring(section or "all") .. ": " .. tostring(checks) .. " checks passed"
