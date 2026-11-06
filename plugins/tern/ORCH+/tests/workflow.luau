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
W.CAPS = { "report-files-v1", "native-ask-v1", "coordinator-control-v1", "check-runner-v1", "release-manager-v1" }
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
		table.insert(records, { id = row[1], revision = 0, provider = row[2], account_label = "configured, not verified", backend = "native-agent", enabled = true, eligible = true,
			capability_evidence = "configured_operator_attestation_not_runtime_proof", effective_identity = { provider = row[2], evidence = "configured" },
			capabilities = W.arr(W.CAPS), unsupported = W.arr(), cwd = "/fixture", placement = "split" })
	end
	local r = f:apply("catalog"); assert(r.ok, r.message)
	assert(f:finish(r.action_id, "catalog", { namespace = "fixture-spawn", host_key = "fixture-host", config_revision = 0, revision = 0, records = W.arr(records) }).ok)
end
-- A fresh store with the family catalog and a Config v4 policy patch. The session's release manager
-- record defaults to "kimi" (Kimi: no other fixture role uses it); a patch may override it, "" = none.
-- The default clock is fixed: native runs are sliced across real seconds, so wall-clock time must not
-- move a fixture across launch/claim timeouts mid-section.
function W.fixture(patch, clock)
	W.api(); local f = api.fixture(clock or function() return { now_ms = 1700000000000, mono_ms = 1000 } end); W.catalog(f)
	local merged = { release_manager_record = "kimi" }
	for key, value in patch or {} do merged[key] = value end
	local saved = f:apply("policy", { policy = merged }); assert(saved.ok, saved.message)
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
	assert(f:finish(w.launch_action_id, "awaiting_acceptance", { pane_binding = { pane_id = tostring(9700 + W.serial), window_key = f.origin.window_key,
		window_epoch = f.origin.window_epoch, native_session_id = f.origin.native_session_id, window_host_id = f.origin.window_host_id } }).ok)
	assert(f:apply("intake", { worker_id = worker_id, bytes = f:report(worker_id, 1, "ACCEPTED", { assignment_sha256 = w.assignment_sha256 }) }).ok)
	assert(f:finish(f:apply("poll", { worker_id = worker_id }).action_id, "published", {}).ok)
	assert(f:finish(f:apply("poll", { worker_id = worker_id }).action_id, "accepted", {}).ok)
	return worker_id
end
function W.builder(f, record, fields)
	local event = { record_id = record or "builder", record_revision = 0, catalog_revision = 0, prompt = "Implement the declared fixture task.", cwd = "/fixture",
		placement = "split", coordinator = false, checks = W.unit() }
	for key, value in fields or {} do event[key] = value end
	local queued = f:apply("queue", event); assert(queued.ok and queued.action_id, queued.message)
	return W.start(f, queued.worker_id, queued.action_id)
end
function W.cp(cp_id, revision)
	return { checkpoint_id = cp_id, task_ref = "task:fixture", project_id = "project-one", worktree_ref = "worktree:fixture", artifact_revision = W.hx(revision),
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
-- Checkpoint (and optionally a helper check result) then REVIEW_READY for that revision.
function W.ready(f, id, cp_id, revision, exit_code)
	W.settle(f, id)
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
	local ready = W.ready(f, builder_id, cp_id, revision, exit_code); assert(ready.ok, ready.message)
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
-- Checkpoint 4 (Contracts I/J): the session's release manager is the only grant holder.
function W.rm_id(f)
	for key, w in f.authority.registry.dispatch.workers do if w.role == "release_manager" and w.finish == nil and w.release == nil then return key end end
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
-- A proven (cross-family round), owner-approved request on `target`, granted to the release manager.
function W.granted(f, cp_id, target)
	local b = W.builder(f); W.round(f, b, cp_id, "rev-" .. cp_id, "approved")
	local lid = W.request(f, b, cp_id, "rev-" .. cp_id, target); assert(W.approve(f, lid).ok); W.rm(f)
	assert(#W.item(f, lid).grants == 1, "fixture request was not granted: " .. tostring(W.item(f, lid).hold and W.item(f, lid).hold.code))
	return b, lid
end
-- The release manager consumes the grant and reports it landed at `head`.
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
-- A DEPLOY_RESULT for the deploy's latest attempt, sent by that attempt's release manager.
function W.deploy_result(f, lid, outcome, fields, extra)
	local dep, a = W.deploy(f, lid), W.attempt(f, lid)
	local p = { deploy_id = dep.deploy_id, attempt_id = a.attempt_id, landing_id = lid, outcome = outcome, revision = dep.revision, evidence = W.arr({ "deploy:log" }) }
	for key, value in fields or {} do p[key] = value end
	W.settle(f, a.worker_id)
	return W.send(f, a.worker_id, "DEPLOY_RESULT", p, extra or { action_id = a.action_id, action_revision = a.action_revision })
end
-- Invariant sweep (Checkpoint 4): builders never receive `landing_grant`. Every retained reply of every
-- non-release-manager worker, every non-legacy grant record and every deploy attempt is checked, and
-- every grant holder's record differs from the builder's and the reviewer's (signer ≠ reviewer).
-- W.restores runs it, so each fixture's full registry output is swept.
function W.sweep(f)
	local d = f.authority.registry.dispatch
	for wid, w in d.workers do
		if w.role ~= "release_manager" then
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
				assert(h and h.role == "release_manager" and h.record_id ~= b.record_id, "a landing grant addressed to a non-release-manager or the builder record: " .. lid)
				local r = it.proof and (d.reviews or {})[it.proof.review_id]
				assert(r == nil or r.reviewer_record_id ~= h.record_id, "a landing grant held by the reviewer record: " .. lid)
			end
		end
	end
	for did, dep in d.deploys or {} do
		for _, a in dep.attempts do
			assert(d.workers[a.worker_id] and d.workers[a.worker_id].role == "release_manager", "a deploy grant addressed to a non-release-manager: " .. did)
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
			local r = assert((d.reviews or {})[p.review_id], "grant proof names no reviewer-worker review: " .. lid)
			assert(r.status == "approved" and r.artifact_revision == p.artifact_revision and r.builder_worker_id == it.worker_id, "grant proof review not approved for the revision: " .. lid)
			assert(r.reviewer_worker_id ~= nil and r.reviewer_worker_id ~= it.worker_id and r.reviewer_record_id ~= b.record_id, "grant proof reviewed by its builder: " .. lid)
			if p.mode == "cross_family_review" then
				assert(r.builder_family ~= nil and r.reviewer_family ~= nil and r.builder_family ~= r.reviewer_family, "cross-family proof without different declared families: " .. lid)
			else
				assert(p.mode == "helper_checks" and #b.checks > 0, "helper-checks proof without declared checks: " .. lid)
				for _, c in b.checks do
					local res = b.check_results and b.check_results[c.check_id]
					assert(res and res.exit_code == 0 and res.head == p.artifact_revision, "helper-checks proof without a passing check at the revision: " .. lid)
				end
			end
		end
	end
	checks += 1
end

if section == nil or section == "plan_import" then
	local importer, codec = load("plan_import"), load("transport")
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

	-- Legacy conventions: import safely, never as independent work.
	local legacy, legacy_problem = importer.parse(LEGACY)
	check(legacy ~= nil and legacy_problem == nil, "the legacy plan parses: " .. tostring(legacy_problem and legacy_problem.message))
	check(legacy.title == "Demo service 1.0 — legacy-convention fixture" and legacy.plan_revision == "1f2cb7489faa4ae3d110beeed59aa7794379c7aa6d095f4ee41aa79107f3faa1"
		and legacy.project_hint.kind == "workspace" and legacy.project_hint.name == "other", "legacy plan title, revision and home")
	local legacy_ids = {}
	for _, cp in legacy.checkpoints do for _, t in cp.tasks do table.insert(legacy_ids, t.id) end end
	check(#legacy.checkpoints == 3 and same(legacy_ids, { "1A", "1B", "1C", "2A", "2B" }), "legacy plan: 3 checkpoints, 5 tasks")
	for _, cp in legacy.checkpoints do for _, t in cp.tasks do
		check(t.independent == false, t.id .. ": prose 'INDEPENDENT of …' is not the marker")
		if t.id == "1A" then check(t.sequential_why == "establishes canonical files before builders edit them." and not has(t.flags, "sequential_default"), "1A SEQUENTIAL reason")
		else check(has(t.flags, "sequential_default") and t.sequential_why == nil, t.id .. ": no marker → sequential_default") end
		check(#t.checks == 0 and has(t.flags, "no_checks") and not has(t.flags, "check_unparsed"), t.id .. ": plain '- VALIDATE:' lines are not checks")
		check(#t.files == 1 and has(t.flags, "file_outside_home"), t.id .. ": files outside home workspace:other are flagged")
	end end
	check(#legacy.checkpoints[3].tasks == 0 and has(legacy.checkpoints[3].flags, "no_tasks") and has(legacy.checkpoints[3].flags, "untasked_actions")
		and #legacy.checkpoints[2].flags == 0, "legacy checkpoint 3 has untasked action headers and no tasks; checkpoint 2 is clean")
	check(task_headers(legacy) == #PLAN_CHECK.legacy.lines - 3, "legacy plan: all action headers except checkpoint 3's two and the Progress one sit inside tasks")

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
	refused({ "# Feature: X", "## Overview", "#### Task 1A — t", "### Checkpoint 1 — One" }, "task_outside_checkpoint", "task before any checkpoint")
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
	check(W.ready(f, b, "cp-1", "rev-1").ok, "REVIEW_READY is accepted")
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
	local s = W.fixture({ enforce_cross_family = false, reviewer_records = W.arr({ "claude2" }) })
	local sb = W.builder(s); assert(W.ready(s, sb, "cp-1", "rev-1", 0).ok)
	local sr = W.review(s, sb); local sv, sreq = W.open(s, sr)
	check(W.worker(s, sv).family == "anthropic", "the same-family reviewer was eligible while enforcement was off")
	assert(s:apply("policy", { policy = { enforce_cross_family = true } }).ok)
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
	local m = W.fixture({ enforce_cross_family = false, reviewer_records = W.arr({ "builder", "claude2" }) })
	local mb = W.builder(m)
	local mr = W.round(m, mb, "cp-1", "rev-1", "approved", nil, 0)
	check(mr.status == "approved" and mr.reviewer_record_id == "claude2" and mr.reviewer_family == "anthropic",
		"enforcement off: the builder's own record is skipped and a same-family reviewer is accepted")
	local ml = W.request(m, mb, "cp-1", "rev-1"); assert(W.approve(m, ml).ok)
	check(W.item(m, ml).status == "granted" and W.item(m, ml).proof.mode == "helper_checks", "same-family review plus passing helper checks grants with enforcement off")
	local n = W.fixture({ enforce_cross_family = false, reviewer_records = W.arr({ "builder" }) })
	local nb = W.builder(n)
	check(W.ready(n, nb, "cp-1", "rev-1").ok and #W.gates(n, "reviewer_unavailable") == 1, "reviewer record = builder record is never eligible")
	W.rule_h(m); W.rule_h(n); check(W.restores(m) and W.restores(n), "enforcement-off reviews restore")
end

if section == nil or section == "review_rounds" then
	local f = W.fixture({ reviewer_records = W.arr({ "codex" }) })
	local b = W.builder(f)
	local r1, v1 = W.round(f, b, "cp-1", "rev-1", "changes_required", W.findings(2), 1)
	check(r1.status == "changes_required" and r1.round == 1 and #r1.findings == 2 and v1 ~= b, "round 1 changes_required keeps its findings")
	local rework = W.replies(f, b, "rework")
	check(#rework == 1, "changes_required issues exactly one rework reply to the builder")
	local p = rework[1].reply.payload
	local keys = {}; for key in p do table.insert(keys, key) end; table.sort(keys)
	check(table.concat(keys, ",") == "artifact_revision,failed_checks,findings,review_id,round" and p.review_id == r1.review_id and p.round == 1
		and p.artifact_revision == W.hx("rev-1") and #p.failed_checks == 0 and #p.findings == 2 and p.findings[1].finding_id == "f1" and p.findings[2].line == 2,
		"the rework payload carries only the review's findings (cross-family mode: no failed checks, no summary, no score)")
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
	-- A new artifact revision voids the approval and its check proof.
	W.settle(f, b)
	check(W.send(f, b, "CHECKPOINT", W.cp("cp-3", "rev-3")).ok, "a new revision is checkpointed")
	local voided = f.authority.registry.dispatch.reviews[r2.review_id]
	check(voided.void ~= nil and voided.void.artifact_revision == W.hx("rev-3"), "new revision voids approval: the approved review records the void")
	local l3 = W.request(f, b, "cp-3", "rev-3", "refs/heads/next"); assert(W.approve(f, l3).ok)
	check(#W.item(f, l3).grants == 0 and W.item(f, l3).proof == nil and W.item(f, l3).hold.code == "review_required",
		"landing the new revision waits for its own review")
	W.rule_h(f); check(W.restores(f), "rework rounds and voided approvals restore")
	-- Helper-checks mode (enforcement off): rework names the failed checks as well.
	local n = W.fixture({ enforce_cross_family = false, reviewer_records = W.arr({ "codex" }) })
	local nb = W.builder(n)
	W.round(n, nb, "cp-1", "rev-1", "changes_required", W.findings(1), 1)
	local nrework = W.replies(n, nb, "rework")
	local np = nrework[#nrework].reply.payload
	check(#np.failed_checks == 1 and np.failed_checks[1].check_id == "unit" and np.failed_checks[1].exit_code == 1 and #np.findings == 1,
		"helper-checks mode: rework carries the findings and the failed helper checks")
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
	assert(f:apply("reply", { worker_id = reviewer }).ok)
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
end

if section == nil or section == "proof_rule" then
	-- Grid {enforce on/off} × {review approved/changes_required/none} × {checks pass/fail/missing}.
	-- One builder per review row holds an ungranted landing request on its own target; the declared
	-- helper check moves missing → fail → pass and every state is evaluated under both policies (the
	-- proof is recomputed on each commit; a proven request waits only for owner approval). A second
	-- approved builder ("surprise") carries the two surprising cells through an actual owner approval.
	local EXPECT = {
		on = { approved = { missing = "proven", fail = "proven", pass = "proven" },
			changes_required = { missing = "review_not_approved", fail = "review_not_approved", pass = "review_not_approved" },
			none = { missing = "review_required", fail = "review_required", pass = "review_required" } },
		off = { approved = { missing = "check_missing", fail = "check_failed", pass = "proven" },
			changes_required = { missing = "check_missing", fail = "check_failed", pass = "review_not_approved" },
			none = { missing = "check_missing", fail = "check_failed", pass = "review_required" } },
	}
	local ROWS = { "approved", "changes_required", "none" }
	local f = W.fixture({ reviewer_records = W.arr({ "codex" }) })
	local rows, enforced = {}, true
	for _, outcome in { "approved", "changes_required", "none", "surprise" } do
		local b = W.builder(f); local cp_id, revision = "cp-" .. outcome, "rev-" .. outcome
		if outcome == "none" then W.settle(f, b); assert(W.send(f, b, "CHECKPOINT", W.cp(cp_id, revision)).ok)
		else W.round(f, b, cp_id, revision, if outcome == "changes_required" then "changes_required" else "approved", if outcome == "changes_required" then W.findings(1) else nil) end
		rows[outcome] = { builder = b, revision = revision, lid = W.request(f, b, cp_id, revision, "refs/heads/" .. outcome) }
	end
	local function mode(on)
		if on ~= enforced then local saved = f:apply("policy", { policy = { enforce_cross_family = on } }); assert(saved.ok, saved.message); enforced = on end
	end
	local function sweep(state)
		for _, on in { true, false } do
			mode(on)
			for _, outcome in ROWS do
				local it, want = W.item(f, rows[outcome].lid), EXPECT[if on then "on" else "off"][outcome][state]
				local label = "enforce " .. (if on then "on" else "off") .. " × review " .. outcome .. " × checks " .. state
				if want == "proven" then
					check(it.hold ~= nil and it.hold.code == "approval_pending" and it.proof ~= nil and #it.grants == 0
						and it.proof.mode == (if on then "cross_family_review" else "helper_checks"), label .. ": Rule H holds; only the owner approval remains")
				else
					check(it.hold ~= nil and it.hold.code == want and it.proof == nil and #it.grants == 0,
						label .. ": held " .. want .. " (got " .. tostring(it.hold and it.hold.code) .. ")")
				end
			end
			W.rule_h(f)
		end
	end
	local function helper_check(exit_code)
		for _, outcome in { "approved", "changes_required", "none", "surprise" } do
			local b = rows[outcome].builder; W.settle(f, b)
			assert(W.send(f, b, "CHECK_RESULT", { check_id = "unit", argv_sha256 = api.codec.sha256("argv"), exit_code = exit_code, output_sha256 = api.codec.sha256("check output"),
				head = W.hx(rows[outcome].revision), ran_at_ms = 1 }).ok)
		end
	end
	local surprise = function() return W.item(f, rows.surprise.lid) end
	sweep("missing")
	assert(W.approve(f, rows.surprise.lid).ok)
	check(surprise().approval ~= nil and surprise().hold.code == "check_missing" and #surprise().grants == 0,
		"surprising: enforcement off + approved review + owner-approved landing + missing helper checks is held")
	helper_check(1)
	check(surprise().hold.code == "check_failed" and #surprise().grants == 0, "enforcement off: a failed helper check holds the owner-approved request")
	-- Enforcement on makes the surprise row grantable: ORCH+ queues the release manager, which is launched.
	mode(true); W.rm(f)
	sweep("fail")
	check(surprise().status == "granted" and surprise().proof.mode == "cross_family_review" and #surprise().proof.check_refs == 0,
		"surprising: enforcement on + failed helper check + approved cross-family review is granted (helper checks are evidence only)")
	helper_check(0)
	sweep("pass")
	for _, outcome in ROWS do assert(W.approve(f, rows[outcome].lid).ok) end
	for _, on in { false, true } do
		mode(on)
		for _, outcome in ROWS do
			local it = W.item(f, rows[outcome].lid)
			check((#it.grants == 1) == (outcome == "approved"), "enforce " .. (if on then "on" else "off") .. " × review " .. outcome .. " × checks pass, owner-approved: granted only when Rule H holds")
		end
		W.rule_h(f)
	end
	check(W.item(f, rows.approved.lid).proof.mode == "helper_checks" and #W.item(f, rows.approved.lid).proof.check_refs == 1,
		"enforcement off grants the approved, all-passing row with its helper-check proof")
	check(W.restores(f), "every grid state restores")
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
	check(W.landing_result(f, a, la, "landed", { result_revision = "head-1" }).code == "landing_unauthorized" and W.grant(f, la).result == nil,
		"the requesting builder's LANDING_RESULT is refused")
	check(W.landing_result(f, b, la, "landed", { result_revision = "head-1" }).code == "landing_unauthorized", "another builder's LANDING_RESULT is refused")
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
	check(W.request(f, b, "cp-b2", "rev-b2", nil, "head-1") == lb and table.find({ "review_required", "review_stale" }, W.item(f, lb).hold.code) ~= nil
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
	check(W.request(f, b, "cp-b3", "rev-b3", nil, "head-7") == lb and table.find({ "review_required", "review_stale" }, W.item(f, lb).hold.code) ~= nil
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
	-- A 0.3.0 store with a grant addressed to a builder restores as legacy_grant_outstanding.
	do
		local g = W.fixture({ reviewer_records = W.arr({ "codex" }) })
		local lbid, ll = W.granted(g, "cp-l")
		local stored = api.clone(g.memory.value); W.legacy(stored, ll)
		g.memory.value = stored; g.authority = api.host.new_authority(g.memory); assert(g.authority:load().ok)
		local lit = W.item(g, ll)
		check(W.grant(g, ll).legacy == true and lit.hold.code == "legacy_grant_outstanding" and lit.status == "granted" and #lit.grants == 1 and #W.gates(g, "legacy_grant_outstanding") == 1,
			"a legacy 0.3.0 granted item restores as legacy_grant_outstanding with one owner gate")
		check(lit.holder ~= nil and lit.holder.worker_id == lbid, "the legacy grant's holder is the builder generation it was addressed to, never re-addressed")
		check(W.restores(g), "the upgraded legacy store restores")
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
					W.settle(f, b)
					local sent = W.send(f, b, "LANDING_REQUEST", { checkpoint_id = "cp-n", project_id = "project-one", repo_ref = "repo:fixture", target_ref = "refs/heads/main",
						target_revision = head, source_ref = "refs/heads/cp-n", source_revision = W.hx("rev-new") })
					local it = W.item(f, lid)
					if status == "queued" or status == "approved" then
						check(sent.ok and it.approval == nil and it.proof == nil and it.request.source_revision == W.hx("rev-new") and #it.grants == 0
							and table.find({ "review_required", "review_stale" }, it.hold.code) ~= nil, label .. ": the same item rebinds, approval voided, fresh review required")
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
	if answer then check(f.authority:apply(api.clone(answer)).ok, label .. ": the exact answer replay is accepted") end
	assert(f.authority:apply({ kind = "workflow_tick" }))
	check(W.effects(f) == effects and runtime.json.encode(f.authority.registry.dispatch.gates[gid].execution) == execution, label .. ": answer replay and tick never execute twice")
	local restored = assert(api.state.rehydrate(api.clone(f.authority.registry)), label .. ": restore")
	local twin = api.dispatch.tick(restored, { kind = "workflow_tick" }, { now_ms = 1, mono_ms = 1, epoch = "autonomy-twin" }) or restored
	check(runtime.json.encode(twin.dispatch.gates[gid].execution) == execution, label .. ": the restored twin keeps the execution record")
	local tf = { authority = { registry = twin } }
	check(W.effects(tf) == effects, label .. ": the restored twin's tick executes nothing again")
	f.authority = api.host.new_authority(f.memory); assert(f.authority:load().ok)
	assert(f.authority:apply({ kind = "workflow_tick" }))
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
		check(table.find(g.evidence, "scope:" .. W.OUT[kind][2]) ~= nil and g.question:find("Outside plan scope", 1, true) ~= nil,
			label .. ": the gate names why the work is outside plan scope")
	else
		check(table.find(g.evidence, "scope:in") ~= nil, label .. ": the gate records the work as in plan scope")
	end
	check(g.question:find("does not execute a native or landing effect", 1, true) == nil, label .. ": gate text no longer claims approval executes nothing")
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
		check(e.state == "done" and new ~= nil and new.record_id == "claude2" and new.prompt == "Implement the follow-on planned task."
			and runtime.json.encode(new.source) == runtime.json.encode(bw.source) and runtime.json.encode(new.scope) == runtime.json.encode(bw.scope),
			label .. ": dispatch queues the proposed record/prompt inheriting the parent's source and scope")
	elseif kind == "report" then
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

-- Checkpoint 6 (D10, D12, D16; Contracts G, K, L): plan scheduling, durable intake, template chains.
-- Host file reads are real tern.fs reads of fixture files in a fresh scratch folder.
function W.scratch()
	W.api()
	local dir = "/tmp/orch-cp6d-" .. api.codec.sha256(tostring(os.clock()) .. ":" .. tostring(math.random())):sub(1, 16)
	runtime.fs.mkdir(dir)
	return dir
end
W.ROUTES = { { class = "build", record_id = "builder" }, { class = "docs", record_id = "claude2" } }
function W.src_fixture(patch)
	W.api()
	local merged = { routes = W.arr(api.clone(W.ROUTES)) }
	for key, value in patch or {} do merged[key] = value end
	return W.fixture(merged)
end
-- Cold-start twin: a second host loads the stored bytes and ticks. The restored controller stays
-- uncertain until re-admitted, so the twin is inspected while the live authority continues.
function W.cold(f)
	local memory = { value = api.clone(f.memory.value), writes = 0 }
	memory.get = function() return api.clone(memory.value) end
	memory.set = function(_, value) memory.value = api.clone(value); memory.writes += 1 end
	local twin = { authority = api.host.new_authority(memory), origin = f.origin }
	local loaded = twin.authority:load(); assert(loaded.ok, "cold start load: " .. tostring(loaded.code) .. " " .. tostring(loaded.message))
	assert(twin.authority:apply({ kind = "workflow_tick" }))
	return twin
end
function W.plan(f, id) return f.authority.registry.dispatch.plans[id] end
function W.task(plan, task_id)
	for _, cp in plan.checkpoints do for _, t in cp.tasks do if t.id == task_id then return t end end end
	error("task missing: " .. task_id)
end
-- Launch (if still queued) then finish one source worker cleanly.
function W.complete(f, worker_id)
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
	-- Join + INDEPENDENT fan-out under concurrency_limit 2.
	local dir = W.scratch()
	local f = W.src_fixture({ concurrency_limit = 2 })
	check(f.authority.registry.dispatch.plans == nil, "cold start: a fresh store has no plans collection")
	local path = W.write_plan(dir)
	local imported = f:apply("plan_import", { path = path })
	assert(imported.ok, imported.message)
	check(imported.code == "plan_imported" and imported.checkpoints == 2 and imported.tasks == 5, "the plan imports with its two checkpoints and five tasks")
	local plan = W.plan(f, imported.plan_id)
	check(plan.plan_revision == api.codec.sha256(W.PLAN_TEXT) and plan.path == path, "the plan revision is the sha256 of the host-read bytes")
	check(#imported.started == 2 and W.task(plan, "1A").state == "running" and W.task(plan, "1B").state == "running",
		"INDEPENDENT tasks start together up to concurrency_limit (2)")
	check(W.task(plan, "1C").state == "queued_plan", "the third INDEPENDENT task waits for a free slot (limit 2), not for its siblings")
	check(W.task(plan, "1D").state == "queued_plan" and W.task(plan, "2A").state == "queued_plan", "the sequential task and checkpoint 2 stay queued_plan")
	local wa = W.worker(f, W.task(plan, "1A").worker_id)
	check(wa.source.kind == "plan" and wa.source.ref == path .. "#1A" and wa.source.revision == plan.plan_revision, "plan work carries the Contract G source {plan, path#task, revision}")
	check(#wa.checks == 1 and wa.checks[1].check_id == "1A-c1" and wa.checks[1].argv[1] == "luau", "the parsed VALIDATE item is check 1A-c1; the prose item is never a check")
	check(table.find(W.task(plan, "1A").flags, "check_unparsed") ~= nil, "the unsplittable VALIDATE item is flagged on the task (shown, never executed)")
	check(wa.files[1] == "src/a.luau" and wa.scope.paths[1] == "src/a.luau" and #wa.scope.systems == 2 and wa.scope.systems[1] == "orch" and wa.scope.systems[2] == "spawn",
		"files and scope.paths come from the action headers; scope.systems only from **SYSTEMS**")
	check(#W.worker(f, W.task(plan, "1B").worker_id).scope.systems == 0, "a task without **SYSTEMS** has no systems")
	check(wa.record_id == "builder", "plan work routes to the build route's record")
	local again = f:apply("plan_import", { path = path })
	check(again.ok and again.code == "plan_already_imported" and again.plan_id == imported.plan_id, "re-importing the same revision changes nothing")
	check(W.restores(f), "the imported plan restores")
	W.complete(f, W.task(plan, "1A").worker_id)
	plan = W.plan(f, imported.plan_id)
	check(W.task(plan, "1A").state == "done" and W.task(plan, "1C").state == "running", "a finished task frees its slot: the waiting INDEPENDENT task starts")
	check(W.task(plan, "1D").state == "queued_plan", "the sequential task still waits for every earlier task of its checkpoint")
	W.complete(f, W.task(plan, "1B").worker_id)
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
	check(not refused.ok and refused.code == "no_title" and refused.message:find("Plan import refused", 1, true) == 1, "a malformed plan is refused with the parser's reason")
	check(not u:apply("plan_import", { path = dir .. "/absent.md" }).ok, "a missing plan file is refused")
	check(u:apply("plan_import", { path = "relative/plan.md" }).code == "invalid_path", "a relative plan path is refused")

	-- Intake gate: auto_launch_intake=false holds new intake work behind an `intake` gate.
	local board = "/tmp/fixture-board.tern"
	for _, auto in { false, true } do
		local g = W.src_fixture({ board_path = board, auto_launch_intake = auto })
		local tags = W.arr({ "#class-build" })
		local sent = g:apply("board_intake", { board_path = board, card_id = "card-1", text = "Add the fixture feature.", tags = tags,
			text_sha256 = api.quota.digest({ text = "Add the fixture feature.", tags = tags }) })
		assert(sent.ok, sent.message)
		local w = W.worker(g, sent.worker_id)
		local gates = W.gates(g, "intake")
		if auto then
			check(sent.code == "intake_accepted" and sent.state == "accepted" and #gates == 0 and w.launch_gates == nil, "auto_launch_intake=true: the intake launches directly with no intake gate")
		else
			check(sent.code == "intake_received" and sent.state == "received" and #gates == 1 and w.launch_gates and w.launch_gates[1] == gates[1].id and w.phase == "queued",
				"auto_launch_intake=false: the work waits behind an intake gate and nothing is provisioned")
			check(W.provision_of(g, sent.worker_id) == nil, "no provision is queued before the owner answers")
			local tg = W.cold(g)
			check(#W.gates(tg, "intake") == 1 and tg.authority.registry.dispatch.intakes[sent.intake_id].state == "received", "cold start: the intake gate and received state survive")
			local gate = W.gates(g, "intake")[1]
			local answered = g:apply("answer", { gate_id = gate.id, gate_revision = gate.revision, choice_id = "launch_anyway", answer = "Launch it." })
			assert(answered.ok, answered.message)
			check(g.authority.registry.dispatch.intakes[sent.intake_id].state == "accepted" and W.provision_of(g, sent.worker_id) ~= nil,
				"the owner's launch answer launches the work and the intake becomes accepted")
			-- Cancel: the second card's work is dropped and the intake refused.
			local tags2 = W.arr({ "class-build" })
			local second = g:apply("board_intake", { board_path = board, card_id = "card-2", text = "A different card.", tags = tags2,
				text_sha256 = api.quota.digest({ text = "A different card.", tags = tags2 }) })
			local g2 = W.gates(g, "intake")[1]
			assert(g:apply("answer", { gate_id = g2.id, gate_revision = g2.revision, choice_id = "cancel", answer = "Not now." }).ok)
			local rec = g.authority.registry.dispatch.intakes[second.intake_id]
			check(rec.state == "refused" and rec.refusal == "owner_cancelled", "cancelling the intake gate refuses the intake (owner_cancelled)")
		end
		check(W.restores(g), "intake gate state restores (auto=" .. tostring(auto) .. ")")
	end

	-- Template chain: a ⇄ b cycle stops after 8 successful steps with a loop_cap gate naming the bound.
	local templates = W.arr({ { id = "draft", title = "Draft", prompt = "Draft from {input}.", output = "out/draft.md", next = "polish" },
		{ id = "polish", title = "Polish", prompt = "Polish {input}.", output = "out/polish.md", next = "draft" },
		{ id = "solo", title = "Solo", prompt = "Do {input}.", output = "out/solo.md", next = "" } })
	local c = W.src_fixture({ templates = templates })
	check(c.authority.registry.dispatch.chains == nil, "cold start: no chains collection before the first template start")
	local started = c:apply("template_start", { template_id = "draft", input = "notes/brief.md" })
	assert(started.ok, started.message)
	check(started.code == "template_started" and started.action_id ~= nil, "template_start launches the first step")
	local chain_id = started.chain_id
	local worker_id, inputs = started.worker_id, {}
	for step = 1, 8 do
		local w = W.worker(c, worker_id)
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
	check(#caps == 1 and caps[1].question:find("chain bound 8", 1, true) ~= nil, "a loop_cap gate names \"chain bound 8\"")
	local opts = {}; for _, o in caps[1].options do table.insert(opts, o.id) end
	check(table.find(opts, "allow_more") == nil, "the structural chain bound offers no allow_more")
	local workers = 0; for _ in c.authority.registry.dispatch.workers do workers += 1 end
	check(workers == 8, "no ninth step worker was created")
	local tc = W.cold(c)
	check(tc.authority.registry.dispatch.chains[chain_id].status == "capped" and #W.gates(tc, "loop_cap") == 1, "cold start: the capped chain and its gate survive; no step starts")
	check(W.restores(c), "the capped chain restores")
	-- Other way: a template with no next ends the chain after one step, no gate.
	local solo = c:apply("template_start", { template_id = "solo", input = "x.md" }); assert(solo.ok, solo.message)
	W.start(c, solo.worker_id, assert(W.provision_of(c, solo.worker_id)))
	W.done(c, solo.worker_id, "out/solo.md")
	check(c.authority.registry.dispatch.chains[solo.chain_id].status == "done" and #W.gates(c, "loop_cap") == 1, "a chain whose template has no next ends done without a gate")
	check(c:apply("template_start", { template_id = "missing", input = "x" }).code == "template_unknown", "an unknown template is refused")
end

if section == nil or section == "intake" then
	local dir = W.scratch()
	local inbox = dir .. "/inbox"; runtime.fs.mkdir(inbox)
	local f = W.src_fixture({ inbox_folder = inbox, auto_launch_intake = true })
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
	check(second.ok and second.code == "intake_accepted" and second.intake_id ~= first.intake_id and second.work_id ~= first.work_id,
		"new content under the same name is a new intake with its own work")
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
	local board = "/tmp/fixture-board.tern"
	local g = W.src_fixture({ board_path = board, auto_launch_intake = true })
	local tags = W.arr({ "urgent", "class-docs" })
	local text = "Document the board flow."
	local tsha = api.quota.digest({ text = text, tags = tags })
	local card = g:apply("board_intake", { board_path = board, card_id = "card-old", text = text, tags = tags, text_sha256 = tsha })
	assert(card.ok, card.message)
	check(card.intake_id == api.quota.digest({ kind = "board", path = board, sha256 = tsha }), "the board intake_id matches the window's derivation")
	check(W.worker(g, card.worker_id).record_id == "claude2", "a board tag class-<route class> picks that route")
	local remap = g:apply("board_intake", { board_path = board, card_id = "card-new", text = text, tags = tags, text_sha256 = tsha })
	check(remap.code == "intake_duplicate" and remap.work_id == card.work_id and g.authority.registry.dispatch.intakes[card.intake_id].card_id == "card-new",
		"after a reload the re-sent card id re-maps the existing intake")
	local cards = api.dispatch.project(g.authority.registry, g.origin.logical_session_id, g.origin.alias_nonce).workflow.board.cards
	check(#cards == 1 and cards[1].card_id == "card-new" and cards[1].intake_id == card.intake_id, "the board projection maps the new card id to the intake")
	local long = string.rep("y", 4097)
	local oversize = g:apply("board_intake", { board_path = board, card_id = "card-big", text = long, tags = W.arr(), text_sha256 = api.quota.digest({ text = long, tags = W.arr() }) })
	check(oversize.code == "intake_refused" and oversize.refusal == "card_too_large" and g.authority.registry.dispatch.intakes[oversize.intake_id].state == "refused",
		"a card longer than 4096 bytes is refused card_too_large durably")
	check(g:apply("board_intake", { board_path = "/tmp/other.tern", card_id = "c", text = text, tags = tags, text_sha256 = tsha }).code == "board_mismatch", "a board other than Config's is refused")
	check(g:apply("board_intake", { board_path = board, card_id = "c", text = text .. "!", tags = tags, text_sha256 = tsha }).code == "intake_invalid", "a text_sha256 mismatch is refused")
	-- No class: held label_pending, no worker. An ordinary tag equal to a route class never routes.
	local plain_tags = W.arr({ "docs", "#build", "class-unknown" })
	local plain = g:apply("board_intake", { board_path = board, card_id = "card-plain", text = "Unlabelled.", tags = plain_tags, text_sha256 = api.quota.digest({ text = "Unlabelled.", tags = plain_tags }) })
	check(plain.ok and plain.state == "received" and plain.work_id == nil and plain.hold and plain.hold.code == "label_pending",
		"a card whose tags only equal route classes (docs, #build) or name no route (class-unknown) waits for the labeller")
	local tb = W.cold(g)
	check(tb.authority.registry.dispatch.intakes[card.intake_id].card_id == "card-new", "cold start: the re-mapped card id is durable")
	check(W.restores(g), "board intakes restore")
end

-- Checkpoint 7 (D13, Contracts B/C/D/L): unclassed intake → labeller worker → LABEL routes in code.
W.BOARD = "/tmp/fixture-board.tern"
function W.router(patch)
	local merged = { board_path = W.BOARD, auto_launch_intake = true, labeller_record = "omp", loop_cap = 2 }
	for key, value in patch or {} do merged[key] = value end
	return W.src_fixture(merged)
end
function W.card(f, card_id, text)
	local sha = api.quota.digest({ text = text, tags = W.arr() })
	local r = f:apply("board_intake", { board_path = W.BOARD, card_id = card_id, text = text, tags = W.arr(), text_sha256 = sha }); assert(r.ok, r.message)
	return r
end
function W.intake(f, intake_id) return f.authority.registry.dispatch.intakes[intake_id] end
function W.labellers(f)
	local n = 0; for _, w in f.authority.registry.dispatch.workers do if w.role == "labeller" then n += 1 end end; return n
end
-- Launch the intake's current labeller (if queued), deliver and acknowledge its label_request.
function W.label_open(f, intake_id)
	local id = assert(W.intake(f, intake_id).label and W.intake(f, intake_id).label.worker_id, "intake has no labeller")
	if W.worker(f, id).phase == "queued" then W.start(f, id, (assert(W.provision_of(f, id), "labeller provision missing"))) end
	W.settle(f, id, true)
	local issued = W.replies(f, id, "label_request"); assert(#issued >= 1, "label_request missing")
	local entry = issued[#issued]
	assert(W.send(f, id, "reply_ack", { message_id = entry.reply.message_id, reply_seq = entry.reply.reply_seq, reply_sha256 = api.codec.sha256(entry.retained.bytes),
		status = "recorded" }, { action_id = entry.reply.action_id, action_revision = entry.reply.action_revision }).ok)
	return id, entry.reply
end
function W.label(f, id, request, class, extra)
	local p = { work_ref = request.payload.work_ref, class = class, reason = "fixture label" }
	for key, value in extra or {} do p[key] = value end
	return W.send(f, id, "LABEL", p, { action_id = request.action_id, action_revision = request.action_revision })
end
function W.gate_answer(f, gate, choice) return f:apply("answer", { gate_id = gate.id, gate_revision = gate.revision, choice_id = choice, answer = "Owner chose " .. choice .. "." }) end

if section == nil or section == "router" then
	-- No labeller configured: label_pending hold pointing at Config; no labeller worker.
	local none = W.router({ labeller_record = "" })
	local held = W.card(none, "card-1", "Please write the onboarding guide.")
	check(held.work_id == nil and held.hold and held.hold.code == "label_pending" and W.labellers(none) == 0, "no labeller_record → label_pending hold, no labeller worker")
	check(held.hold.message:find("Config", 1, true) ~= nil, "the label_pending hold points the owner at Config")
	check(W.cold(none).authority.registry.dispatch.intakes[held.intake_id].hold.code == "label_pending", "cold start: the label_pending hold is durable")
	check(W.restores(none), "the held intake restores")

	-- Known label routes in code to that class's record.
	local f = W.router()
	local fresh = W.card(f, "card-1", "Please write the onboarding guide.")
	local rec = W.intake(f, fresh.intake_id)
	check(fresh.work_id == nil and rec.label and rec.label.worker_id and W.labellers(f) == 1, "unclassed intake with a labeller_record queues exactly one labeller")
	check(not (fresh.hold and fresh.hold.code == "label_pending"), "with a labeller configured the intake is not label_pending")
	local lw = W.worker(f, rec.label.worker_id)
	check(lw.role == "labeller" and lw.record_id == "omp" and lw.class == nil, "the labeller runs the Config labeller_record with role labeller and no class")
	local twin = W.cold(f)
	check(twin.authority.registry.dispatch.intakes[fresh.intake_id].label.worker_id == rec.label.worker_id, "cold start: the labeller binding is durable")
	local lid, request = W.label_open(f, fresh.intake_id)
	check(request.payload.work_ref == fresh.intake_id and #request.payload.classes == 2 and request.payload.classes[1] == "build" and request.payload.classes[2] == "docs"
		and request.payload.text == "Please write the onboarding guide.", "label_request carries {work_ref, classes = route classes in Config order, text}")
	W.settle(f, lid, true)
	check(W.worker(f, lid).finish == nil and W.intake(f, fresh.intake_id).work_id == nil, "a settled labeller without a LABEL is pinned, not finished, and nothing is routed")
	check(W.label(f, lid, request, "docs", { work_ref = "intake-other" }).ok == false or W.intake(f, fresh.intake_id).class == nil, "a LABEL for another work_ref never routes this intake")
	local labelled = W.label(f, lid, request, "docs")
	check(labelled.ok, "LABEL with a routed class is accepted")
	rec = W.intake(f, fresh.intake_id)
	check(rec.class == "docs" and rec.work_id ~= nil, "a class in routes routes the intake in code")
	local routed
	for _, w in f.authority.registry.dispatch.workers do if w.work_id == rec.work_id and w.role ~= "labeller" then routed = w end end
	check(routed and routed.record_id == "claude2" and routed.class == "docs", "the routed worker runs the route's record (model/effort live in that record) with the class")
	check(#W.gates(f, "label_unknown") == 0, "a known class opens no label_unknown gate")
	-- Labeller auto-finishes (CP3 rule) once its LABEL receipt is settled.
	check(W.worker(f, lid).finish == nil, "unsettled: the LABEL receipt is unpublished, so no finish yet")
	W.settle(f, lid, true)
	local finish = W.worker(f, lid).finish
	check(finish and finish.source and finish.source.kind == "policy" and finish.source.rule == "auto_finish:labeller", "settled: ORCH+ finishes the labeller with policy auto_finish:labeller")
	check(routed.finish == nil, "auto-finish never applies to the routed worker")
	local twin2 = W.cold(f)
	check(twin2.authority.registry.dispatch.intakes[fresh.intake_id].class == "docs" and twin2.authority.registry.dispatch.intakes[fresh.intake_id].work_id == rec.work_id,
		"cold start: the routed class and work are durable")
	check(W.restores(f), "a routed, auto-finishing labeller restores")
	-- A class written on the card is routed without any labeller.
	local tagged = f:apply("board_intake", { board_path = W.BOARD, card_id = "card-tag", text = "Build it.", tags = W.arr({ "class-build" }),
		text_sha256 = api.quota.digest({ text = "Build it.", tags = W.arr({ "class-build" }) }) })
	check(tagged.ok and tagged.work_id ~= nil and W.labellers(f) == 1, "an intake that already names a route class never queues a labeller")

	-- Unknown label gates; route_now re-gates until Config routes the class; cancel refuses.
	local u = W.router()
	local ucard = W.card(u, "card-u", "Deploy the release to staging.")
	local uid, ureq = W.label_open(u, ucard.intake_id)
	check(W.label(u, uid, ureq, "deploy").ok, "LABEL with an unrouted class is recorded")
	local gates = W.gates(u, "label_unknown")
	check(#gates == 1 and W.intake(u, ucard.intake_id).work_id == nil and W.intake(u, ucard.intake_id).class == nil, "a class outside routes opens one label_unknown gate and routes nothing")
	check(W.intake(u, ucard.intake_id).hold and W.intake(u, ucard.intake_id).hold.code == "label_unknown", "the intake is held label_unknown")
	check(W.cold(u).authority.registry.dispatch.intakes[ucard.intake_id].hold.code == "label_unknown", "cold start: the label_unknown hold is durable")
	local again = W.gate_answer(u, gates[1], "route_now")
	check(again.ok and W.intake(u, ucard.intake_id).work_id == nil and #W.gates(u, "label_unknown") == 1, "route now without a Config route re-gates; nothing routes")
	local routes = api.clone(W.ROUTES); table.insert(routes, { class = "deploy", record_id = "codex" })
	assert(u:apply("policy", { policy = { routes = W.arr(routes) } }).ok)
	local open = W.gates(u, "label_unknown")
	check(W.gate_answer(u, open[1], "route_now").ok and W.intake(u, ucard.intake_id).class == "deploy" and W.intake(u, ucard.intake_id).work_id ~= nil,
		"route now after Config gains the class routes the intake")
	check(#W.gates(u, "label_unknown") == 0, "routing resolves the label_unknown gate")
	local c = W.router()
	local ccard = W.card(c, "card-c", "Something odd.")
	local cid2, creq = W.label_open(c, ccard.intake_id)
	assert(W.label(c, cid2, creq, "mystery").ok)
	check(W.gate_answer(c, W.gates(c, "label_unknown")[1], "cancel").ok and W.intake(c, ccard.intake_id).state == "refused"
		and W.intake(c, ccard.intake_id).refusal == "owner_cancelled", "cancel on label_unknown refuses the intake owner_cancelled")
	check(W.restores(u) and W.restores(c), "label_unknown outcomes restore")

	-- Retries capped (Contract L, loop_cap 2): a labeller ending without LABEL is retried; the failure
	-- after loop_cap retries opens one loop_cap gate instead of another labeller.
	local r = W.router({ loop_cap = 2 })
	local rcard = W.card(r, "card-r", "Unclear request.")
	local started = {}
	for attempt = 1, 3 do
		local wid = W.intake(r, rcard.intake_id).label.worker_id
		check(wid ~= nil and not table.find(started, wid) and #W.gates(r, "loop_cap") == 0, "attempt " .. attempt .. ": a fresh labeller, no loop_cap gate yet")
		table.insert(started, wid)
		W.label_open(r, rcard.intake_id)
		W.complete(r, wid)
	end
	local loops = W.gates(r, "loop_cap")
	check(#loops == 1 and W.labellers(r) == 3 and W.intake(r, rcard.intake_id).work_id == nil, "loop_cap 2: the third ended labeller opens one loop_cap gate, no fourth labeller")
	check(W.intake(r, rcard.intake_id).hold and W.intake(r, rcard.intake_id).hold.code == "loop_cap", "the intake is held loop_cap")
	check(W.cold(r).authority.registry.dispatch.intakes[rcard.intake_id].label.loop.count == 2, "cold start: the retry count is durable")
	check(W.gate_answer(r, loops[1], "allow_more").ok and W.labellers(r) == 4, "allow more queues one more labeller")
	local s = W.router({ loop_cap = 1 })
	local scard = W.card(s, "card-s", "Unclear request.")
	for _ = 1, 2 do local wid = W.intake(s, scard.intake_id).label.worker_id; W.label_open(s, scard.intake_id); W.complete(s, wid) end
	local sl = W.gates(s, "loop_cap")
	check(#sl == 1 and W.labellers(s) == 2, "loop_cap 1: one retry, then the gate")
	check(W.gate_answer(s, sl[1], "stop").ok and W.intake(s, scard.intake_id).state == "refused" and W.intake(s, scard.intake_id).refusal == "label_stopped" and W.labellers(s) == 2,
		"stop refuses the intake label_stopped and queues nothing")
	check(W.restores(r) and W.restores(s), "capped labeller loops restore")
end

-- FinalSmoke2 defect 2: a labeller's auto-finish runs the standard finish to its end — exact pane
-- stop, then settled mailbox retirement — both when its LABEL routes behind an intake gate and when
-- it opens a label_unknown gate. Until the worker publishes its receipt watermark the finish waits
-- (never stops an unsettled journal). `phase` stays "accepted" (the accept lifecycle, not completion).
if section == nil or section == "labeller_finish" then
	local function projected(f, id)
		return api.dispatch.project(f.authority.registry, f.origin.logical_session_id, f.origin.alias_nonce).workers[id]
	end
	for _, case in { { name = "routed", patch = { auto_launch_intake = false }, class = "docs" }, { name = "label_unknown", patch = {}, class = "deploy" } } do
		local f = W.router(case.patch)
		local card = W.card(f, "card-lf", "Ship the release notes.")
		local id, request = W.label_open(f, card.intake_id)
		check(W.label(f, id, request, case.class).ok, case.name .. ": the LABEL is accepted")
		if case.name == "routed" then
			check(W.intake(f, card.intake_id).work_id ~= nil and #W.gates(f, "intake") == 1, "routed: the label routes the intake behind one intake gate")
		else
			check(#W.gates(f, "label_unknown") == 1 and W.intake(f, card.intake_id).work_id == nil, "label_unknown: the label opens one label_unknown gate")
		end
		-- Publish every owed receipt (the LABEL's last) but no watermark: like the worker whose helper
		-- never consumed the LABEL ACK, the journal is not settled yet.
		for _ = 1, 8 do
			local owed = false
			for _, receipt in W.worker(f, id).receipts do if receipt.publish then owed = true end end
			if not owed then break end
			local publish = f:apply("poll", { worker_id = id }); assert(publish.ok and publish.action_id, publish.message)
			assert(f:action(publish.action_id).request.op == "mailbox_publish_ack")
			assert(f:finish(publish.action_id, "published", {}).ok)
		end
		local w = W.worker(f, id)
		check(w.finish ~= nil and w.finish.source.rule == "auto_finish:labeller" and w.compacted_floor < w.accepted_seq,
			case.name .. ": the published LABEL receipt queues the policy finish before any watermark")
		local early = f:apply("poll", { worker_id = id })
		local early_op = if early.action_id then f:action(early.action_id).request.op else nil
		check(early_op ~= "stop" and W.worker(f, id).stop_action_id == nil, case.name .. ": without the worker's watermark no stop is issued (the journal is not settled)")
		if early.action_id then
			assert(f:finish(early.action_id, if early_op == "mailbox_retire" then "compacted" elseif early_op == "mailbox_read" then "missing" else "published", {}).ok)
		end
		assert(f:watermark(id).ok)
		local stop = f:apply("poll", { worker_id = id }); assert(stop.ok and stop.action_id, stop.message)
		local sr = f:action(stop.action_id).request
		check(sr.op == "stop" and W.worker(f, id).stop_action_id == stop.action_id, case.name .. ": the settled finish issues the exact pane stop")
		check(f:finish(stop.action_id, "stopped", { pane_binding = api.clone(sr.pane_binding), observation = "absent" }).ok, case.name .. ": the stop outcome commits")
		local retire = f:apply("poll", { worker_id = id }); assert(retire.ok and retire.action_id, retire.message)
		local rr = f:action(retire.action_id).request
		check(rr.op == "mailbox_retire" and rr.mode == "retire" and rr.report_floor == W.worker(f, id).accepted_seq, case.name .. ": the stopped labeller's mailbox retirement follows")
		check(f:finish(retire.action_id, "retired", {}).ok, case.name .. ": the retirement outcome commits")
		w = W.worker(f, id)
		local pw = projected(f, id)
		check(w.stopped ~= nil and w.mailbox_retired == true and w.phase == "accepted" and pw and pw.finish_requested and pw.stop_status == "absent" and pw.mailbox_status == "retired",
			case.name .. ": the labeller is finished: stopped and retired (phase stays accepted; inspect shows the stop and retirement)")
		check(not (f:apply("poll", { worker_id = id }).action_id), case.name .. ": nothing further is issued for the retired labeller")
		check(W.restores(f), case.name .. ": the finished labeller restores")
	end
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

-- 8C (D14): every assignment ORCH+ sends starts with its role's Config guidance — typed queue work,
-- coordinator starts, attached panes and approved dispatch proposals as well as composed prompts.
if section == nil or section == "role_guidance" then
	local f = W.fixture({ reviewer_records = W.arr({ "codex" }) })
	local G = { builder = "Builder guidance: stay inside scope.", reviewer = "Reviewer guidance: cite lines.", release_manager = "Release guidance: follow AGENTS.md.",
		coordinator = "Coordinator guidance: propose small steps.", labeller = "Labeller guidance: pick the closest class." }
	for _, role in { "builder", "reviewer", "release_manager", "coordinator", "labeller" } do
		local saved = f:apply("policy", { role_guidance_put = { role = role, text = G[role] } }); assert(saved.ok, saved.message)
	end
	local function guided(id, role, text)
		local w = W.worker(f, id)
		return w ~= nil and w.prompt:sub(1, #G[role] + 2) == G[role] .. "\n\n" and (text == nil or w.prompt == G[role] .. "\n\n" .. text)
			and w.assignment_sha256 == api.codec.sha256(w.prompt)
	end
	local typed = f:apply("queue", { record_id = "builder", record_revision = 0, catalog_revision = 0, prompt = "Typed fixture task.", cwd = "/fixture", placement = "split", coordinator = false })
	assert(typed.ok, typed.message)
	check(guided(typed.worker_id, "builder", "Typed fixture task."), "a typed queue task starts with the builder guidance (assignment digest of the guided prompt)")
	local as_reviewer = f:apply("queue", { record_id = "claude2", record_revision = 0, catalog_revision = 0, prompt = "Typed review task.", cwd = "/fixture", placement = "split",
		coordinator = false, role = "reviewer" }); assert(as_reviewer.ok, as_reviewer.message)
	check(guided(as_reviewer.worker_id, "reviewer", "Typed review task."), "a typed task queued with role reviewer gets the reviewer guidance")
	local adopted = f:apply("adopt", { record_id = "builder", record_revision = 0, catalog_revision = 0, prompt = "Adopted fixture task.", attestation = "operator_verified_exact_agent_pane",
		pane_binding = { pane_id = "9690", window_key = f.origin.window_key, window_epoch = f.origin.window_epoch, native_session_id = f.origin.native_session_id, window_host_id = f.origin.window_host_id } })
	assert(adopted.ok, adopted.message)
	check(guided(adopted.worker_id, "builder", "Adopted fixture task."), "an attached pane's task starts with the builder guidance")
	local cid = W.coordinator(f)
	check(guided(cid, "coordinator", "Coordinate the fixture plan."), "a coordinator start begins with the coordinator guidance")
	local b = W.builder(f, "builder", { source = W.PLAN, files = W.arr({ "src/feature.luau" }) })
	check(guided(b, "builder", "Implement the declared fixture task."), "a launched builder accepted the guided prompt")
	local rv = W.round(f, b, "cp-1", "rev-1", "approved")
	check(guided(rv.reviewer_worker_id, "reviewer"), "the reviewer ORCH+ composes starts with the reviewer guidance")
	local lid = W.request(f, b, "cp-1", "rev-1"); assert(W.approve(f, lid).ok)
	check(W.rm_id(f) ~= nil and guided(W.rm_id(f), "release_manager"), "the release manager starts with the release-manager guidance")
	local sent = W.propose(f, cid, "dispatch", W.worker(f, b).work_id, { record_id = "claude2", record_revision = 0, prompt = "Implement the follow-on planned task." })
	assert(sent.ok, sent.message)
	local g = W.proposal_gate(f)
	local answered = f:apply("answer", { gate_id = g.id, gate_revision = g.revision, choice_id = "approve", answer = "Owner approves this proposal." }); assert(answered.ok, answered.message)
	local e = f.authority.registry.dispatch.gates[g.id].execution
	local new = e and e.effect_ref:match("^worker:(.+)$")
	check(e ~= nil and e.state == "done" and new ~= nil and guided(new, "builder", "Implement the follow-on planned task."),
		"an approved dispatch proposal's new work starts with the builder guidance (" .. tostring(e and e.effect_ref) .. ")")
	check(W.restores(f), "guided assignments restore")
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
			assert(f.authority:apply({ kind = "workflow_tick" })); assert(W.send(f, cid, "HEARTBEAT", { state = "working" }).ok)
			local restored = assert(api.state.rehydrate(api.clone(f.authority.registry)))
			local twin = api.dispatch.tick(restored, { kind = "workflow_tick" }, { now_ms = 1, mono_ms = 1, epoch = "paused-proposal-twin" }) or restored
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
		and g.answer.answer:find("Propose again", 1, true) ~= nil and table.find(g.evidence, "refused:scope_mismatch") ~= nil and g.execution == nil,
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

assert(section == nil or table.find({ "plan_import", "usage_delta", "review_cross_family", "review_rounds", "auto_finish", "proof_rule",
	"release_config", "release_launch", "release_refresh", "release_holder", "deploy", "deploy_held", "deploy_retry", "deploy_lost",
	"grid_queued_new_revision", "grid_queued_target_moved", "grid_queued_rm_rollover", "grid_queued_cancel",
	"grid_approved_new_revision", "grid_approved_target_moved", "grid_approved_rm_rollover", "grid_approved_cancel",
	"grid_granted_new_revision", "grid_granted_target_moved", "grid_granted_rm_rollover", "grid_granted_cancel",
	"grid_landed_new_revision", "grid_landed_target_moved", "grid_landed_rm_rollover", "grid_landed_cancel",
	"grid_deploy_held_new_revision", "grid_deploy_held_target_moved", "grid_deploy_held_rm_rollover", "grid_deploy_held_cancel",
	"autonomy", "autonomy_dispatch", "autonomy_report", "autonomy_review", "autonomy_landing", "sources", "intake", "router", "labeller_finish",
	"role_guidance", "autonomy_paused", "proposal_early" }, section), "unknown workflow section")
return "workflow/" .. tostring(section or "all") .. ": " .. tostring(checks) .. " checks passed"
