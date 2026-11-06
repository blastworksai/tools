-- Deterministic actual reducer/host behavior; no native effects. Run sections separately.
local root, section = ...
-- The fixture runs in this group's environment (as tests/run.luau loads groups), so its tern.json calls are
-- the stepped runner's yield points and a long scenario spans many native slices.
local fixture_chunk = assert(loadstring(tern.fs.read(root .. "/tests/dispatch.luau"), "dispatch-fixture"))
setfenv(fixture_chunk, setmetatable({}, { __index = getfenv() }))
local api = fixture_chunk(root, "fixture")
local checks = 0
local function check(ok, message) assert(ok, message); checks += 1 end
local function worker(f, id) return f.authority.registry.dispatch.workers[id] end
local function send(f, id, kind, payload, extra)
 local w = worker(f, id)
 return f:apply("intake", { worker_id = id, bytes = f:report(id, w.accepted_seq + 1, kind, payload, extra) })
end
local function cp(id, revision)
 return { checkpoint_id = id or "checkpoint-one", task_ref = "task:fixture", project_id = "project-one", worktree_ref = "worktree:fixture", artifact_revision = revision or "revision-one",
  completed = tern.json.array({ "Implemented assigned change" }), remaining = tern.json.array(), holds = tern.json.array(), checks = tern.json.array({ { check_id = "unit", artifact_revision = revision or "revision-one", outcome = "not_run", evidence_ref = "owner-will-run" } }) }
end
local function ack(f, id, delivery)
 return send(f, id, "reply_ack", { message_id = delivery.message_id, reply_seq = delivery.reply_seq, reply_sha256 = api.codec.sha256(delivery.bytes), status = "recorded" }, { action_id = delivery.action_id, action_revision = delivery.action_revision })
end
if section == nil or section == "core" then
 local f = api.fixture(); local id = f:accepted(false)
 for _, case in { { "READY", { state = "idle", summary = "Ready" } }, { "HEARTBEAT", { state = "working" } }, { "WAITING", { reason = "Waiting on owner" } }, { "BLOCKED", { reason = "Check failed", evidence = tern.json.array({ "check:unit" }) } }, { "CHECKPOINT", cp() }, { "REVIEW_READY", { checkpoint_id = "checkpoint-one", artifact_revision = "revision-one" } }, { "DONE", { checkpoint_id = "checkpoint-one", artifact_revision = "revision-one", summary = "Assigned change complete, native pane still present" } } } do
  local result = send(f, id, case[1], case[2]); check(result.ok, case[1] .. " has actual durable semantic intake")
  check(worker(f, id).workflow.evidence[case[1]] ~= nil, case[1] .. " retains structured evidence")
 end
 check(worker(f, id).pane_binding ~= nil and worker(f, id).release == nil and worker(f, id).stopped == nil, "DONE never proves native closure, release or landing")
 check(api.state.rehydrate(api.clone(f.authority.registry)) ~= nil, "all accepted semantic evidence restores through root state validation")
 local g = api.fixture(); local gid = g:accepted(false)
 check(send(g, gid, "CHECKPOINT", cp()).ok, "checkpoint accepted")
 check(send(g, gid, "ROLLOVER_REQUEST", { checkpoint_id = "checkpoint-one", reason = "Fresh context requested" }).ok, "rollover evidence retained without lifecycle execution")
 check(worker(g, gid).stop_action_id == nil, "rollover request is not native stop permission")
 check(g:apply("finish", { worker_id = gid }).code == "workflow_unsettled", "ordinary finish explicitly refuses pinned rollover/checkpoint evidence rather than deleting CP4 references")
 local before = tern.json.encode(g.authority.registry)
 check(not send(g, gid, "DONE", { checkpoint_id = "absent", artifact_revision = "revision-one", summary = "No checkpoint" }).ok, "missing checkpoint rejected")
 check(not send(g, gid, "CHECKPOINT", cp("checkpoint-one", "different")).ok, "checkpoint ID cannot change its revision")
 check(tern.json.encode(g.authority.registry) == before, "invalid references leave state/cursor untouched")
 local bytes = g:report(gid, worker(g, gid).accepted_seq + 1, "HEARTBEAT", { state = "idle" })
 local candidate = api.clone(g.authority.registry); local cw = candidate.dispatch.workers[gid]
 local snapshot = tern.json.encode(candidate)
 local _, err = api.dispatch.intake(candidate, cw, bytes:gsub('"idle"', 'null'), { now_ms = 1 })
 check(err ~= nil and tern.json.encode(candidate) == snapshot, "null report leaves even the candidate untouched")
 local event = g:event("intake", { worker_id = gid, bytes = bytes }); g.memory.fail = true
 check(g.authority:apply(event).code == "persistence_failed" and tern.json.encode(g.authority.registry) == before, "failed save exposes neither workflow nor receipt")
 g.memory.fail = false; check(g.authority:apply(event).ok, "same report commits after storage recovers")
end
if section == nil or section == "correlation" then
 local f = api.fixture(); local id = f:accepted(false)
 check(f:apply("reply", { worker_id = id }).ok, "one progress request issued")
 local request = api.clone(worker(f, id).workflow.report_request)
 local writes = f.memory.writes
 local pending_intent = f:event("reply", { worker_id = id })
 check(f.authority:apply(pending_intent).code == "report_request_pending" and f.memory.writes == writes + 1, "new no-effect owner intent consumes its durable replay sequence without issuing another reply")
 check(f.authority:apply(api.clone(pending_intent)).code == "report_request_pending" and f.memory.writes == writes + 1, "exact pending-intent replay creates neither reply nor write storm")
 check(ack(f, id, request).ok, "matching immutable reply consumption accepted")
 check(worker(f, id).workflow.report_request.acknowledged and worker(f, id).workflow.report_request ~= nil, "reply ACK is not a progress response")
 local before = tern.json.encode(f.authority.registry)
 check(not send(f, id, "HEARTBEAT", { state = "working", request_id = "wrong-request" }).ok, "mismatched response rejected")
 check(tern.json.encode(f.authority.registry) == before, "mismatched request changes no cursor/evidence")
 check(send(f, id, "WAITING", { reason = "Need longer", request_id = request.request_id }).ok and worker(f, id).workflow.report_request ~= nil, "WAITING retains outstanding request without resend")
 check(send(f, id, "HEARTBEAT", { state = "working", request_id = request.request_id }).ok, "correlated progress fulfills request")
 check(worker(f, id).workflow.report_request == nil, "request settles only after both ACK and response")
 check(f.authority:apply(api.clone(pending_intent)).code == "report_request_pending" and worker(f,id).workflow.report_request == nil, "previously successful no-effect reply intent cannot create a new request after the old cycle settles")
 check(api.state.rehydrate(api.clone(f.authority.registry)) ~= nil, "request settlement restores")
 local g = api.fixture(); local gid = g:accepted(false); assert(g:apply("reply", { worker_id = gid }).ok)
 local r = api.clone(worker(g, gid).workflow.report_request); local payload = cp(); payload.request_id = r.request_id
 check(send(g, gid, "CHECKPOINT", payload).ok and worker(g, gid).workflow.report_request ~= nil, "response before ACK retains immutable pending outbox")
 check(ack(g, gid, r).ok and worker(g, gid).workflow.report_request == nil, "later exact ACK settles early response")
end
if section == nil or section == "proposals" then
 local f = api.fixture(); local id = f:accepted(true)
 local w = worker(f, id); local activation = api.clone(w.activation)
 local activation_reply = api.codec.decode_reply(activation.bytes, w); activation.message_id = activation_reply.message_id
 check(send(f, id, "CHECKPOINT", cp()).ok, "coordinator assignment scope checkpoint retained")
 local p = { owner_id = w.coordinator_owner_id, owner_generation = w.coordinator_generation, activation_token = activation.activation_token,
  proposal_id = "proposal-one", kind = "review", work_id = w.work_id, project_id = "project-one", checkpoint_id = "checkpoint-one" }
 check(send(f, id, "COORDINATOR_PROPOSAL", p).code == "proposal_unauthorized", "coordinator label without activation ACK cannot propose")
 check(ack(f, id, activation).ok, "activation acknowledgement admitted")
 local wrong = api.clone(p); wrong.activation_token = string.rep("0", 64)
 check(send(f, id, "COORDINATOR_PROPOSAL", wrong).code == "proposal_unauthorized", "wrong activation token rejected")
 assert(f:apply("pause").ok)
 local paused = send(f, id, "COORDINATOR_PROPOSAL", p)
 check(paused.ok and paused.code == "session_paused" and worker(f, id).rejected_report == nil, "pause refuses a new proposal (session_paused) definitely: the report commits, its lane never holds")
 local pg; for _, g in f.authority.registry.dispatch.gates do pg = g end
 check(pg.phase == "answered" and pg.answer.choice_id == "reject" and pg.answer.source.kind == "refusal" and pg.answer.source.code == "session_paused",
  "the paused refusal is a visible ORCH+ reject (source refusal session_paused), never an owner gate")
 assert(f:apply("resume").ok)
 wrong = api.clone(p); wrong.work_id = "foreign-work"; wrong.proposal_id = "proposal-foreign"
 local foreign = send(f, id, "COORDINATOR_PROPOSAL", wrong)
 check(foreign.ok and foreign.code == "scope_mismatch" and worker(f, id).rejected_report == nil, "a proposal naming foreign work is refused scope_mismatch definitely, never a held report")
 local refused; for _, g in f.authority.registry.dispatch.gates do if g.id ~= pg.id then refused = g end end
 check(refused and refused.phase == "answered" and refused.answer.choice_id == "reject" and refused.answer.source.kind == "refusal"
  and refused.answer.source.code == "scope_mismatch", "foreign work never acquires an owner gate: ORCH+ answers it reject itself (refusal scope_mismatch)")
 check(send(f, id, "COORDINATOR_PROPOSAL", p).ok, "after resume the refused proposal may be sent again (same id) and becomes a durable question")
 local gate; for _, g in f.authority.registry.dispatch.gates do if g.id ~= pg.id and g.id ~= refused.id then gate = g end end
 check(gate.kind == "coordinator_proposal" and gate.phase == "pending" and gate.answer == nil and gate.delivery == nil, "proposal is data, not native/merge execution; it waits for the owner")
 check(api.state.rehydrate(api.clone(f.authority.registry)) ~= nil, "typed proposal, refusals and activation evidence restore")
end
if section == nil or section == "results" then
 for _, kind in { "review", "landing" } do
  local f = api.fixture(); local id = f:accepted(true); local w = worker(f,id)
  local activation = api.clone(w.activation); activation.message_id = api.codec.decode_reply(activation.bytes, w).message_id
  assert(ack(f,id,activation).ok); assert(send(f,id,"CHECKPOINT",cp()).ok)
  local proposal = { owner_id = w.coordinator_owner_id, owner_generation = w.coordinator_generation, activation_token = activation.activation_token,
   proposal_id = "proposal-" .. kind, kind = kind, work_id = w.work_id, project_id = "project-one", checkpoint_id = "checkpoint-one" }
  assert(send(f,id,"COORDINATOR_PROPOSAL",proposal).ok)
  local gid; for key in f.authority.registry.dispatch.gates do gid = key end
  assert(f:apply("answer", { gate_id = gid, gate_revision = 1, choice_id = "approve", answer = "Proposal only; preserve actual evidence." }).ok)
  for _ = 1, 12 do
   if f.authority.registry.dispatch.gates[gid].phase == "delivered" then break end
   local queued = f:apply("poll", { worker_id = id }); assert(queued.ok, queued.message)
   local op = f:action(queued.action_id).request.op
   assert(f:finish(queued.action_id, if op == "mailbox_retire" then "compacted" else "published", {}).ok)
  end
  local delivery = api.clone(f.authority.registry.dispatch.gates[gid].delivery)
  assert(delivery and delivery.published)
  local extra = { action_id = delivery.action_id, action_revision = delivery.action_revision }
  -- Approved proposals execute their own effect (CP5), never a result: LANDING_RESULT correlates to
  -- landing grants and, since CP3, REVIEW_RESULT comes only from a reviewer worker answering its review_request.
  local payload = if kind == "review" then { review_id = "proposal-review", round = 1, artifact_revision = "revision-one", outcome = "approved", findings = tern.json.array() }
   else { landing_id = "landing-none", grant_id = "grant-none", project_id = "project-one", repo_ref = "repo:fixture", target_ref = "main", target_revision = "base",
    source_revision = "revision-one", outcome = "landed", result_revision = "reported-result", evidence = tern.json.array({ "landing:reported" }) }
  assert(ack(f,id,delivery).ok)
  if kind == "landing" then
   local e = f.authority.registry.dispatch.gates[gid].execution
   check(e and e.state == "pending" and e.effect_ref == "landing_not_requested",
    "an approved landing proposal approves the work's landing request; with none requested it waits (" .. tostring(e and e.state) .. " " .. tostring(e and e.effect_ref) .. ")")
   check(send(f,id,"LANDING_RESULT",payload,extra).code == "landing_unauthorized",
    "an approved landing proposal cannot authorize a LANDING_RESULT; only the release manager holding an issued landing_grant can")
   check(f.authority.registry.dispatch.landing == nil, "a landing proposal approves an existing request; it never creates a queue item or grant")
  else
   local before = tern.json.encode(f.authority.registry.dispatch.reviews or {})
   check(send(f,id,"REVIEW_RESULT",payload,extra).code == "review_unauthorized",
    "a coordinator never files REVIEW_RESULT, even correlated to its own approved review proposal")
   check(f.authority.registry.dispatch.gates[gid].result == nil and worker(f,id).workflow.evidence.REVIEW_RESULT == nil
    and tern.json.encode(f.authority.registry.dispatch.reviews or {}) == before, "the refused coordinator result records no review evidence")
  end
  check(worker(f,id).stop_action_id == nil and worker(f,id).release == nil, "a refused result never invents native closure/release")
  check(api.state.rehydrate(api.clone(f.authority.registry)) ~= nil, "the approved decision survives restoration")
 end
end
if section == nil or section == "migration" then
 local f = api.fixture(); local id = f:accepted(false); assert(f:apply("reply", { worker_id = id }).ok)
 local old = api.clone(f.authority.registry); local issued = worker(f,id).workflow.report_request.bytes
 old.dispatch.workers[id].workflow = nil; old.dispatch.gates = nil; old.dispatch.policies = nil
 local restored = api.state.rehydrate(old)
 check(restored ~= nil and restored.version == 2, "additive CP2 workflow migration preserves schema2 authority")
 check(restored.dispatch.workers[id].workflow.report_request.bytes == issued, "migration adopts exact existing report-request outbox without reissuing")
 check(restored.dispatch.workers[id].workflow.health.freshness == "unconfirmed", "migration never invents old progress freshness")
 local invalid = api.clone(f.authority.registry); invalid.dispatch.workers[id].workflow.observation_cursor = true
 check(api.state.rehydrate(invalid) == nil, "malformed persisted observation cursor rejects rather than throwing")
 invalid = api.clone(f.authority.registry); invalid.dispatch.workers[id].workflow.report_request.acknowledged = true
 check(api.state.rehydrate(invalid) == nil, "forged consumption flag without exact receipt evidence cannot restore")
end
if section == nil or section == "capacity" then
 local f = api.fixture(); local id = f:accepted(false); local w = worker(f, id)
 local bytes = f:report(id, 2, "HEARTBEAT", { state = "working" })
 assert(f:apply("intake", { worker_id = id, bytes = bytes }).ok)
 local saved_ack = worker(f, id).receipts["2"].bytes
 -- Cosmetic history is independent of receipt identity; fill only settled display entries.
 w = worker(f, id); w.workflow.thread = {}
 for i = 1, 128 do table.insert(w.workflow.thread, { id = "history-" .. i, kind = "HEARTBEAT", summary = "Settled display", at_ms = 1, state = "settled" }) end
 f.memory.value = api.clone(f.authority.registry)
 check(send(f, id, "READY", { state = "idle" }).ok and #worker(f, id).workflow.thread == 128, "settled display history evicts at its bound")
 check(f:apply("intake", { worker_id = id, bytes = bytes }).code == "report_replayed", "exact report replay survives display eviction")
 check(worker(f, id).receipts["2"].bytes == saved_ack, "replay retains original committed ACK bytes/revision")
 w = worker(f, id)
 for _, entry in w.workflow.thread do entry.state = "pending" end
 local candidate = api.clone(f.authority.registry); local snapshot = tern.json.encode(candidate)
 local _, err = api.dispatch.intake(candidate, candidate.dispatch.workers[id], f:report(id, 4, "ASK", { question = "Retain me", options = tern.json.array({ { id = "yes", label = "Yes" } }) }), { now_ms = 2 })
 check(err.code == "full" and tern.json.encode(candidate) == snapshot, "full pending thread rejects without mutating candidate/gates/serial/receipt")
end
if section == nil or section == "checkpoint_capacity" then
 local f = api.fixture(); local id = f:accepted(false)
 for index = 1, 16 do
  check(send(f,id,"CHECKPOINT",cp("checkpoint-" .. index, "revision-" .. index)).ok, "live immutable checkpoint retained")
  local queued = f:apply("poll", { worker_id = id }); assert(queued.ok)
  assert(f:action(queued.action_id).request.op == "mailbox_publish_ack")
  assert(f:finish(queued.action_id, "published", {}).ok)
  assert(f:watermark(id).ok)
 end
 local before = tern.json.encode(f.authority.registry)
 check(send(f,id,"CHECKPOINT",cp("checkpoint-17","revision-17")).code == "full", "live checkpoint capacity remains truthful backpressure without a safe CP4 settlement contract")
 check(tern.json.encode(f.authority.registry) == before and worker(f,id).workflow.checkpoints["checkpoint-1"] ~= nil, "capacity never evicts immutable checkpoint IDs or their evidence")
 check(send(f,id,"ROLLOVER_REQUEST", { checkpoint_id = "checkpoint-1", reason = "Pinned old checkpoint still needed" }).ok, "old checkpoint remains available for a later explicit CP4 reference")
 check(f:apply("finish", { worker_id = id }).code == "workflow_unsettled", "finish diagnostics retain referenced live checkpoint work")
 check(api.state.rehydrate(api.clone(f.authority.registry)) ~= nil, "full live checkpoint evidence restores without weakening validation")
end
if section == nil or section == "context" then
 local f = api.fixture(); local id = f:accepted(false)
 local function context() return worker(f, id).workflow.context end
 check(send(f, id, "HEARTBEAT", { state = "working", context_used_pct = 0 }).ok and context().used_pct == 0 and context().seq == worker(f, id).accepted_seq,
  "HEARTBEAT context_used_pct 0 is stored with its report seq")
 check(send(f, id, "READY", { state = "idle", context_used_pct = 100 }).ok and context().used_pct == 100 and context().seq == worker(f, id).accepted_seq,
  "READY context_used_pct 100 replaces the latest value and seq")
 local reported_seq = context().seq
 for _, bad in { -1, 101, 42.5, "42", true } do
  local before = tern.json.encode(f.authority.registry)
  check(not send(f, id, "HEARTBEAT", { state = "working", context_used_pct = bad }).ok and tern.json.encode(f.authority.registry) == before,
   "context_used_pct " .. tostring(bad) .. " rejects the whole report with nothing changed")
 end
 local before = tern.json.encode(f.authority.registry)
 check(not send(f, id, "WAITING", { reason = "Need input", context_used_pct = 10 }).ok and tern.json.encode(f.authority.registry) == before,
  "context_used_pct is accepted only on READY and HEARTBEAT")
 check(send(f, id, "HEARTBEAT", { state = "working" }).ok and context().used_pct == 100 and context().seq == reported_seq,
  "a report without context_used_pct keeps the latest reported value and its seq")
 local projected = api.dispatch.project(f.authority.registry, f.origin.logical_session_id, f.origin.alias_nonce).workflow.workers[1]
 check(projected.context_used_pct == 100 and projected.context_seq == reported_seq, "worker health projection exposes the worker-reported value and seq")
 check(api.state.rehydrate(api.clone(f.authority.registry)) ~= nil, "stored context usage restores through strict validation")
 for _, forged in { { used_pct = 101, seq = reported_seq }, { used_pct = 5.5, seq = reported_seq }, { used_pct = 5, seq = worker(f, id).accepted_seq + 1 }, { used_pct = 5, seq = reported_seq, extra = true } } do
  local invalid = api.clone(f.authority.registry); invalid.dispatch.workers[id].workflow.context = forged
  check(api.state.rehydrate(invalid) == nil, "malformed stored context usage cannot restore")
 end
end
-- CP2 (0.4.0): Contract G assignments, helper-produced CHECK_RESULT/CHECKOUT reports and the Rule H
-- landing proof. Revisions are git object names (lowercase hex); `hx` maps a readable fixture name to one.
local function hx(name) return api.codec.sha256("revision:" .. name):sub(1, 40) end
local CAPS = { "report-files-v1", "native-ask-v1", "coordinator-control-v1", "check-runner-v1", "release-manager-v1" }
local OUTPUT = api.codec.sha256("check output")
local UNIT = tern.json.array({ { check_id = "unit", argv = tern.json.array({ "luau", "tests/run.luau" }) } })
-- Every CP2+ catalog carries the `reviewer` record (CP3 reviewers are fresh workers queued by ORCH+ on
-- `reviewer_records`); its OMP provider has no declared family, which Rule H's helper-checks branch allows.
local function catalog(f, rows)
 local records = {}
 for _, row in rows do
  table.insert(records, { id = row[1], revision = 0, provider = "omp", account_label = "configured, not verified", backend = "native-agent", enabled = true, eligible = true,
   capability_evidence = "configured_operator_attestation_not_runtime_proof", effective_identity = { provider = "omp", evidence = "configured" },
   capabilities = tern.json.array(CAPS), unsupported = tern.json.array(), cwd = row[2], placement = "split" })
 end
 local reviewer = api.clone(records[1]); reviewer.id = "reviewer"; reviewer.cwd = "/fixture"; table.insert(records, reviewer)
 -- CP4: the session's release manager (the only merging actor) is its own record.
 local release = api.clone(records[1]); release.id = "release"; release.cwd = "/fixture"; table.insert(records, release)
 local r = f:apply("catalog"); assert(r.ok, r.message)
 assert(f:finish(r.action_id, "catalog", { namespace = "fixture-spawn", host_key = "fixture-host", config_revision = 0, revision = 0, records = tern.json.array(records) }).ok)
 assert(f:apply("policy", { policy = { reviewer_records = tern.json.array({ "reviewer" }), release_manager_record = "release" } }).ok)
 f.cp2_catalog = true
end
local function queue_work(f, record, cwd, fields, coordinator)
 local event = { record_id = record, record_revision = 0, catalog_revision = 0, prompt = "Complete the declared fixture assignment.", cwd = cwd, placement = "split", coordinator = coordinator == true }
 for key, value in fields or {} do event[key] = value end
 return f:apply("queue", event)
end
local launches = 0
-- Provision (action_id from queue or launch_released), launch, ACCEPT; caps are the provisioned capabilities.
local function start(f, worker_id, action_id, caps)
 launches += 1
 -- SPAWN's provision result names the manifest digest it bound (absent without a manifest).
 assert(f:finish(action_id, "provisioned", { handle = "mailbox-cp2-" .. launches, binding_digest = string.rep("e", 64), capabilities = tern.json.array(caps or CAPS), limits = {},
  manifest_sha256 = worker(f, worker_id).manifest_sha256 }).ok)
 local w = worker(f, worker_id)
 assert(f:finish(w.launch_action_id, "awaiting_acceptance", { pane_binding = { pane_id = tostring(9500 + launches), window_key = f.origin.window_key, window_epoch = f.origin.window_epoch,
  native_session_id = f.origin.native_session_id, window_host_id = f.origin.window_host_id } }).ok)
 assert(f:apply("intake", { worker_id = worker_id, bytes = f:report(worker_id, 1, "ACCEPTED", { assignment_sha256 = w.assignment_sha256 }) }).ok)
 assert(f:finish(f:apply("poll", { worker_id = worker_id }).action_id, "published", {}).ok)
 assert(f:finish(f:apply("poll", { worker_id = worker_id }).action_id, "accepted", {}).ok)
 return worker_id
end
local function launch(f, record, cwd, fields, caps)
 local queued = queue_work(f, record, cwd, fields); assert(queued.ok and queued.action_id, queued.message)
 return start(f, queued.worker_id, queued.action_id, caps)
end
-- A landing builder: Rule H's helper-checks branch (enforce_cross_family=false) with one declared check.
local function builder(f, fields, caps)
 if not f.cp2_catalog then catalog(f, { { "native", "/fixture" } }); assert(f:apply("policy", { policy = { enforce_cross_family = false } }).ok) end
 return launch(f, "native", "/fixture", fields or { checks = UNIT }, caps)
end
-- CP2/CP3 cycles add helper reports (CHECK_RESULT) and a reviewer-worker review per landing, so long fixtures
-- publish owed ACKs and the worker's cumulative watermark before each cycle (8-receipt report lane).
local function settle(f, id)
 for _ = 1, 24 do
  local owed = false
  for _, receipt in worker(f, id).receipts do if receipt.publish then owed = true end end
  if not owed then break end
  local queued = f:apply("poll", { worker_id = id }); assert(queued.ok and queued.action_id, queued.message)
  local op = f:action(queued.action_id).request.op
  assert(f:finish(queued.action_id, if op == "mailbox_retire" then "compacted" elseif op == "mailbox_read" then "missing" else "published", {}).ok)
 end
 if next(worker(f, id).receipts) ~= nil then assert(f:watermark(id).ok) end
end
local function check_result(f, id, revision, exit_code, check_id)
 return send(f, id, "CHECK_RESULT", { check_id = check_id or "unit", argv_sha256 = api.codec.sha256("argv"), exit_code = exit_code or 0, output_sha256 = OUTPUT, head = hx(revision), ran_at_ms = 1 })
end
local function checkout(f, id, path, files, fields)
 local p = { worktree_path = path, common_dir = path .. "/.git", branch = "feature", head = hx("checkout-head"), base = hx("checkout-base"),
  changed_files = tern.json.array(files or {}), changed_overflow = false, changed_total = #(files or {}), dirty = #(files or {}) > 0 }
 for key, value in fields or {} do p[key] = value end
 return send(f, id, "CHECKOUT", p)
end
local function gates_of(f, id, kind)
 local found = {}
 for _, g in f.authority.registry.dispatch.gates or {} do
  if (id == nil or g.worker_id == id) and (kind == nil or g.kind == kind) and not table.find({ "resolved", "cancelled", "superseded" }, g.phase) then table.insert(found, g) end
 end
 return found
end
local function answer(f, g, choice)
 return f:apply("answer", { gate_id = g.id, gate_revision = g.revision, choice_id = choice, answer = "Owner decision for this exact gate." })
end
local function options(g)
 local ids = {}; for _, o in g.options do table.insert(ids, o.id) end
 return table.concat(ids, ",")
end
local rm -- launches the session's queued release manager (defined with the landing helpers)
-- An approved REVIEW_RESULT for the builder's checkpoint from a fresh reviewer worker (CP3): the builder
-- reports REVIEW_READY, ORCH+ queues the reviewer, issues its review_request after ACCEPT, and the
-- reviewer answers that exact request. Returns the review ID.
local function review(f, id, cp_id, revision, outcome)
 settle(f, id)
 local sent = send(f, id, "REVIEW_READY", { checkpoint_id = cp_id, artifact_revision = hx(revision) }); assert(sent.ok, sent.message)
 local rv, serial = nil, -1
 for _, candidate in f.authority.registry.dispatch.reviews or {} do
  local n = tonumber(candidate.review_id:match("(%d+)$")) or 0
  if candidate.builder_work_id == worker(f, id).work_id and n > serial then rv, serial = candidate, n end
 end
 -- A revision whose latest review is already approved (and not voided) needs no second review.
 if rv and rv.status == "approved" and rv.void == nil and rv.artifact_revision == hx(revision) and (outcome or "approved") == "approved" then return rv.review_id end
 assert(rv and rv.status == "queued", "REVIEW_READY queued no review")
 local rid = rv.reviewer_worker_id
 if not rid then for key, w in f.authority.registry.dispatch.workers do if w.role == "reviewer" and w.review_id == rv.review_id and w.phase == "queued" then rid = key end end end
 local provision
 for key, a in f.authority.registry.dispatch.actions do if a.worker_id == rid and a.request.op == "mailbox_provision" and a.phase == "ready" then provision = key end end
 assert(provision, "reviewer provision missing"); start(f, rid, provision)
 local request = f.authority.registry.dispatch.reviews[rv.review_id].request; assert(request, "review_request missing")
 local result = send(f, rid, "REVIEW_RESULT", { review_id = rv.review_id, round = request.round, artifact_revision = hx(revision), outcome = outcome or "approved",
  findings = tern.json.array(), summary = "Reviewed the exact checkpoint revision" }, { action_id = request.action_id, action_revision = request.action_revision })
 assert(result.ok, result.message)
 rm(f)
 return rv.review_id
end
-- Landing queue (CP4): exact requests, owner approval gates, one slot per target, exact results.
local function lcp(id, revision, outcome, holds)
 return { checkpoint_id = id, task_ref = "task:fixture", project_id = "project-one", worktree_ref = "worktree:fixture", artifact_revision = hx(revision),
  completed = tern.json.array({ "Implemented the assigned change" }), remaining = tern.json.array(), holds = holds or tern.json.array(),
  checks = tern.json.array({ { check_id = "unit", artifact_revision = hx(revision), outcome = outcome or "passed", evidence_ref = "unit:log" } }) }
end
local function lreq(cp_id, revision, head, target)
 return { checkpoint_id = cp_id, project_id = "project-one", repo_ref = "repo:fixture", target_ref = target or "refs/heads/main",
  target_revision = head or "head-0", source_ref = "refs/heads/" .. cp_id, source_revision = hx(revision) }
end
-- Checkpoint plus the full Rule H proof for its revision: a passing helper check and an approved review.
local function ready(f, id, cp_id, revision)
 settle(f, id)
 local sent = send(f, id, "CHECKPOINT", lcp(cp_id, revision)); assert(sent.ok, sent.message)
 sent = check_result(f, id, revision); assert(sent.ok, sent.message)
 return review(f, id, cp_id, revision)
end
local function landing(f) return f.authority.registry.dispatch.landing end
local function item(f, lid) return landing(f).items[lid] end
local function queue(f, lid) return landing(f).queues[item(f, lid).queue_id] end
local function grant(f, lid) local it = item(f, lid); return it.grants[#it.grants] end
-- Invariant sweep (CP4): builders never receive `landing_grant` (or `deploy_grant`). Every retained reply of
-- every non-release-manager worker and every non-legacy grant record is checked; restores() runs it, so
-- each fixture's full registry output is swept, not one spot.
local function no_builder_grant(f)
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
   assert(g.legacy or (d.workers[g.worker_id] and d.workers[g.worker_id].role == "release_manager"), "a landing grant addressed to a non-release-manager: " .. lid)
  end
 end
 for did, dep in d.deploys or {} do
  for _, attempt in dep.attempts do
   assert(d.workers[attempt.worker_id] and d.workers[attempt.worker_id].role == "release_manager", "a deploy grant addressed to a non-release-manager: " .. did)
  end
 end
 return true
end
local function restores(f) return no_builder_grant(f) and api.state.rehydrate(api.clone(f.authority.registry)) ~= nil end
local function request(f, id, cp_id, revision, head, target)
 local sent = send(f, id, "LANDING_REQUEST", lreq(cp_id, revision, head, target)); assert(sent.ok, sent.message)
 for key, candidate in landing(f).items do
  if candidate.work_id == worker(f, id).work_id and candidate.request.target_ref == (target or "refs/heads/main")
   and table.find({ "queued", "verifying", "ready", "blocked", "granted", "landing" }, candidate.status) then return key end
 end
 error("landing item missing")
end
-- CP4: ORCH+ queues the session's release manager when a landing item first becomes grantable;
-- launch it (provision → ACCEPT) so the grant is issued to it. Returns its worker ID.
function rm(f)
 for key, w in f.authority.registry.dispatch.workers do
  if w.role == "release_manager" and w.finish == nil then
   if w.phase == "queued" then
    for aid, a in f.authority.registry.dispatch.actions do
     if a.worker_id == key and a.request.op == "mailbox_provision" and a.phase == "ready" then start(f, key, aid); break end
    end
   end
   return key
  end
 end
 return nil
end
local function holder(f, lid) local it = item(f, lid); return it.holder and it.holder.worker_id end
local function approve(f, lid, choice)
 local gate = f.authority.registry.dispatch.gates[item(f, lid).gate_id]
 local answered = f:apply("answer", { gate_id = gate.id, gate_revision = gate.revision, choice_id = choice or "approve", answer = "Owner decision for this exact landing request." })
 if answered.ok then rm(f) end
 return answered
end
local function ack_grant(f, lid)
 local g = grant(f, lid)
 return send(f, g.worker_id, "reply_ack", { message_id = g.message_id, reply_seq = g.reply_seq, reply_sha256 = api.codec.sha256(g.bytes), status = "recorded" },
  { action_id = g.action_id, action_revision = g.action_revision })
end
-- A LANDING_RESULT for the item's latest grant, sent by `id` (the grant holder unless a test says otherwise).
local function report_landing(f, id, lid, outcome, fields)
 local it, g = item(f, lid), grant(f, lid)
 local p = { landing_id = lid, grant_id = g.grant_id, project_id = it.request.project_id, repo_ref = it.request.repo_ref, target_ref = it.request.target_ref,
  target_revision = g.target_revision, source_revision = g.source_revision, outcome = outcome, evidence = tern.json.array({ "log:fixture" }) }
 for key, value in fields or {} do p[key] = value end
 settle(f, id or g.worker_id)
 return send(f, id or g.worker_id, "LANDING_RESULT", p, { action_id = g.action_id, action_revision = g.action_revision })
end
if section == nil or section == "landing_queue" then
 local f = api.fixture(); local a = builder(f); local b = builder(f)
 ready(f, a, "cp-a", "rev-a"); ready(f, b, "cp-b", "rev-b")
 local la = request(f, a, "cp-a", "rev-a"); local lb = request(f, b, "cp-b", "rev-b")
 local q = queue(f, la)
 check(q == queue(f, lb) and q.order[1] == la and q.order[2] == lb and q.slot == nil, "requests for one project/repository/target share one FIFO queue in arrival order")
 check(item(f, la).status == "verifying" and item(f, la).hold.code == "approval_pending" and #item(f, la).grants == 0,
  "fresh evidence alone never grants: the head waits for its exact owner approval")
 check(f.authority.registry.dispatch.gates[item(f, la).gate_id].kind == "landing_approval", "landing approval is a durable owner gate")
 assert(approve(f, lb).ok)
 check(item(f, lb).status == "ready" and #item(f, lb).grants == 0 and queue(f, lb).slot == nil, "an approved item behind the head is ready but never granted out of order")
 assert(approve(f, la).ok)
 q = queue(f, la)
 check(q.slot == la and item(f, la).status == "granted" and #item(f, la).grants == 1 and #item(f, lb).grants == 0, "only the queue head receives the single slot")
 local manager = rm(f)
 check(manager ~= nil and worker(f, manager).role == "release_manager" and worker(f, manager).record_id == "release" and holder(f, la) == manager
  and item(f, la).holder.worker_generation == worker(f, manager).worker_generation and item(f, la).worker_id == a and grant(f, la).worker_id == manager,
  "the grant is held by the session's release manager; the builder stays the requester")
 check(no_builder_grant(f), "the builder never receives a landing_grant")
 local issued = api.codec.decode_reply(grant(f, la).bytes, worker(f, manager))
 check(issued.kind == "landing_grant" and issued.payload.landing_id == la and issued.payload.target_revision == "head-0" and issued.payload.source_revision == hx("rev-a")
  and issued.payload.repo_ref == "repo:fixture" and issued.payload.checkpoint_id == "cp-a" and issued.payload.builder_work_id == worker(f, a).work_id
  and issued.payload.review_id == item(f, la).proof.review_id, "the grant names the exact artifact, target, expected head, builder work and review")
 check(send(f, a, "LANDING_REQUEST", lreq("cp-a", "rev-a")).code == "landing_in_progress", "a granted work cannot re-request the same target")
 local lr = request(f, b, "cp-b", "rev-b", "release-0", "refs/heads/release")
 assert(approve(f, lr).ok)
 check(queue(f, lr) ~= queue(f, la) and queue(f, lr).slot == lr and item(f, lr).status == "granted" and queue(f, la).slot == la,
  "another target keeps an independent FIFO queue and slot")
 check(restores(f), "queued, approved and granted landing state restores through strict validation")
 check(ack_grant(f, la).ok and item(f, la).status == "landing" and grant(f, la).acknowledged, "grant consumption moves granted to landing, never to landed")
 check(report_landing(f, nil, la, "landed", { result_revision = "head-1", pr_ref = "pr:1" }).ok, "exact landed result accepted")
 q = queue(f, la)
 check(item(f, la).status == "landed" and q.slot == nil and q.head.revision == "head-1" and q.head.source == "landed" and q.order[1] == lb,
  "landed records the resulting head, releases the slot and advances the queue")
 check(item(f, lb).status == "blocked" and item(f, lb).hold.code == "target_moved" and #item(f, lb).grants == 0,
  "the next request expecting the old head is blocked, not granted against a moved target")
 check(report_landing(f, nil, la, "landed", { result_revision = "head-1" }).code == "result_already_recorded", "one grant has one immutable result")
 ready(f, b, "cp-b2", "rev-b2")
 check(request(f, b, "cp-b2", "rev-b2", "head-1") == lb and item(f, lb).status == "verifying" and item(f, lb).approval == nil,
  "refresh keeps the queue position and voids the prior approval")
 assert(approve(f, lb).ok)
 check(queue(f, lb).slot == lb and grant(f, lb).target_revision == "head-1" and grant(f, lb).source_revision == hx("rev-b2"), "later grants for the target use the new head")
 check(restores(f), "landed history and refreshed grant restore")
end
if section == nil or section == "landing_reorder" then
 local g = api.fixture(); local x = builder(g); local y = builder(g); local z = builder(g)
 for index, wid in { x, y, z } do ready(g, wid, "cp-" .. index, "rev-" .. index) end
 local lx, ly, lz = request(g, x, "cp-1", "rev-1"), request(g, y, "cp-2", "rev-2"), request(g, z, "cp-3", "rev-3")
 check(g:apply("move_landing", { landing_id = lz, landing_revision = item(g, lz).revision, direction = "up" }).ok and queue(g, lz).order[2] == lz,
  "owner moves an ungranted item up one place")
 check(g:apply("move_landing", { landing_id = lx, landing_revision = item(g, lx).revision + 1, direction = "down" }).code == "stale_landing", "a stale revision cannot reorder")
 check(g:apply("move_landing", { landing_id = lx, landing_revision = item(g, lx).revision, direction = "up" }).code == "landing_not_movable", "the head cannot move further up")
 check(g:apply("cancel_landing", { landing_id = ly, landing_revision = item(g, ly).revision }).ok and item(g, ly).status == "cancelled"
  and table.find(queue(g, lx).order, ly) == nil and g.authority.registry.dispatch.gates[item(g, ly).gate_id].phase == "cancelled",
  "owner cancels an ungranted item and withdraws its approval gate")
 assert(approve(g, lx).ok)
 check(g:apply("cancel_landing", { landing_id = lx, landing_revision = item(g, lx).revision }).code == "landing_not_cancellable", "a granted item cannot be cancelled")
 check(g:apply("move_landing", { landing_id = lz, landing_revision = item(g, lz).revision, direction = "up" }).code == "landing_not_movable", "no item moves past the granted slot")
 assert(approve(g, lz, "reject").ok)
 check(item(g, lz).status == "cancelled" and item(g, lz).hold.code == "owner_rejected" and #item(g, lz).grants == 0, "an owner rejection withdraws the request without a grant")
 check(restores(g), "reordered, cancelled and rejected items restore")
end
if section == nil or section == "landing_evidence" then
 local f = api.fixture(); local id = builder(f)
 assert(send(f, id, "CHECKPOINT", lcp("cp-1", "rev-1")).ok)
 check(send(f, id, "LANDING_REQUEST", lreq("absent", "rev-1")).code == "checkpoint_mismatch", "a request must reference a retained checkpoint")
 check(send(f, id, "LANDING_REQUEST", lreq("cp-1", "rev-other")).code == "checkpoint_mismatch", "the source revision must be the checkpoint's artifact revision")
 local lid = request(f, id, "cp-1", "rev-1")
 assert(approve(f, lid).ok)
 local function blocked(code, why)
  check(item(f, lid).status == "blocked" and item(f, lid).hold.code == code and #item(f, lid).grants == 0 and queue(f, lid).slot == nil and item(f, lid).proof == nil, why)
 end
 blocked("check_missing", "worker-attested checkpoint checks are not proof: without a helper CHECK_RESULT the approved request is blocked")
 assert(check_result(f, id, "rev-1").ok)
 blocked("review_required", "passing helper checks alone never grant: an approved review for the revision is also required")
 local gid = review(f, id, "cp-1", "rev-1")
 check(item(f, lid).status == "granted" and grant(f, lid).checkpoint_id == "cp-1", "helper checks plus an approved review grant the approved head")
 local proof = item(f, lid).proof
 check(item(f, lid).verification == nil and proof.mode == "helper_checks" and proof.artifact_revision == hx("rev-1") and proof.review_id == gid
  and #proof.check_refs == 1 and proof.check_refs[1] == "unit:" .. OUTPUT, "the stored proof names the mode, revision, review and each helper check")
 local issued = api.codec.decode_reply(grant(f, lid).bytes, worker(f, holder(f, lid)))
 check(issued.payload.review_id == gid and issued.payload.builder_work_id == worker(f, id).work_id and issued.payload.proof.mode == "helper_checks", "the grant carries the proof")
 local k = api.fixture(); local kid = builder(k); ready(k, kid, "cp-1", "rev-1"); local klid = request(k, kid, "cp-1", "rev-1")
 local function held(code, why) check(item(k, klid).hold.code == code and #item(k, klid).grants == 0 and item(k, klid).proof == nil, why) end
 assert(send(k, kid, "CHECKPOINT", lcp("cp-4", "rev-1", "passed", tern.json.array({ "Waiting for owner review" }))).ok); held("hold_present", "a checkpoint hold blocks landing")
 assert(send(k, kid, "CHECKPOINT", lcp("cp-5", "rev-2")).ok); held("verification_stale", "the worker's latest checkpoint must be for the requested revision")
 assert(send(k, kid, "CHECKPOINT", lcp("cp-6", "rev-1")).ok)
 held("review_required", "the intervening rev-2 checkpoint voided the rev-1 approval: returning to rev-1 needs a fresh review")
 review(k, kid, "cp-6", "rev-1")
 check(item(k, klid).hold.code == "approval_pending" and #item(k, klid).grants == 0 and item(k, klid).proof ~= nil and item(k, klid).proof.artifact_revision == hx("rev-1"),
  "a fresh review for the latest checkpoint's revision leaves only the owner approval, with the proof already established")
 assert(approve(k, klid).ok)
 check(item(k, klid).status == "granted" and grant(k, klid).checkpoint_id == "cp-6", "the approved, proven head is granted against the latest checkpoint")
 local g = api.fixture(); local gid = builder(g)
 ready(g, gid, "cp-1", "rev-1"); local glid = request(g, gid, "cp-1", "rev-1")
 assert(send(g, gid, "BLOCKED", { reason = "New project hold" }).ok); assert(approve(g, glid).ok)
 check(item(g, glid).hold.code == "worker_blocked" and #item(g, glid).grants == 0, "a new BLOCKED hold invalidates landing readiness")
 assert(g:apply("pause").ok); assert(send(g, gid, "HEARTBEAT", { state = "working" }).ok)
 check(item(g, glid).hold.code == "session_paused" and #item(g, glid).grants == 0, "pause holds landing grants")
 assert(g:apply("resume").ok); rm(g)
 check(item(g, glid).status == "granted", "resume grants the still-fresh approved head")
 check(restores(f) and restores(g), "blocked and granted landing evidence restores")
end
if section == nil or section == "landing_results" then
 local f = api.fixture(); local a = builder(f); local b = builder(f)
 ready(f, a, "cp-a", "rev-a"); ready(f, b, "cp-b", "rev-b")
 local la, lb = request(f, a, "cp-a", "rev-a"), request(f, b, "cp-b", "rev-b")
 assert(approve(f, la).ok); assert(approve(f, lb).ok)
 check(report_landing(f, b, la, "landed", { result_revision = "head-x" }).code == "landing_unauthorized", "a builder cannot settle a grant: only its release-manager holder reports the result")
 check(report_landing(f, a, la, "landed", { result_revision = "head-x" }).code == "landing_unauthorized", "not even the requesting builder settles its own grant")
 check(report_landing(f, nil, la, "landed", { result_revision = "head-x", target_revision = "other" }).code == "revision_mismatch", "a result must echo the grant's expected head")
 check(report_landing(f, nil, la, "rejected", { reason = "Merge conflicts in a shared file" }).ok, "exact rejected result accepted")
 check(item(f, la).status == "failed" and item(f, la).hold.code == "rejected" and queue(f, la).head == nil, "rejected fails the item without inventing a target head")
 check(queue(f, lb).slot == lb and item(f, lb).status == "granted" and grant(f, lb).target_revision == "head-0", "the next approved head is granted after a rejection")
 check(report_landing(f, nil, lb, "stale_target", { observed_target_revision = "head-9" }).ok, "stale_target accepted with the observed head")
 local q = queue(f, lb)
 check(q.slot == nil and q.head.revision == "head-9" and q.head.source == "stale_target" and q.order[1] == lb and item(f, lb).status == "blocked"
  and item(f, lb).refresh_required and item(f, lb).hold.code == "refresh_required", "stale target releases the grant and requeues the request as needing refresh")
 assert(send(f, b, "HEARTBEAT", { state = "working" }).ok)
 check(#item(f, lb).grants == 1 and queue(f, lb).slot == nil, "a released stale grant is never retried automatically")
 ready(f, b, "cp-b2", "rev-b2")
 request(f, b, "cp-b2", "rev-b2", "head-0")
 check(item(f, lb).hold.code == "target_moved", "a refresh against the stale head is still refused")
 request(f, b, "cp-b2", "rev-b2", "head-9"); assert(approve(f, lb).ok)
 check(queue(f, lb).slot == lb and #item(f, lb).grants == 2 and grant(f, lb).target_revision == "head-9", "the refreshed request is granted against the observed head")
 check(restores(f), "rejected, stale and regranted landing evidence restores")
end
if section == nil or section == "landing_uncertain" then
 local f = api.fixture(); local a = builder(f); local b = builder(f)
 ready(f, a, "cp-a", "rev-a"); ready(f, b, "cp-b", "rev-b")
 local la, lb = request(f, a, "cp-a", "rev-a"), request(f, b, "cp-b", "rev-b")
 assert(approve(f, la).ok); assert(approve(f, lb).ok)
 check(report_landing(f, nil, la, "uncertain", { reason = "Push timed out before the remote answered" }).ok, "release-manager-reported uncertainty accepted")
 check(queue(f, la).slot == la and grant(f, la).uncertain.code == "worker_reported_uncertain" and item(f, lb).status == "ready" and #item(f, lb).grants == 0,
  "an uncertain result holds the slot and blocks the next approved request")
 check(report_landing(f, nil, la, "landed", { result_revision = "head-1" }).code == "result_already_recorded", "uncertainty is not replaced by a second worker result")
 local function reconcile(fx, lid, fields)
  local event = { landing_id = lid, landing_revision = item(fx, lid).revision }
  for key, value in fields do event[key] = value end
  return fx:apply("reconcile_landing", event)
 end
 check(reconcile(f, la, { outcome = "landed", reason = "Inspected", operator_verified = true }).code == "reconciliation_required", "landed reconciliation needs the resulting head")
 check(reconcile(f, la, { outcome = "landed", target_revision = "head-1", reason = "Inspected" }).code == "reconciliation_required", "reconciliation needs explicit operator verification")
 check(restores(f), "uncertain held slot restores")
 f.authority = api.host.new_authority(f.memory); assert(f.authority:load().ok)
 check(queue(f, la).slot == la and grant(f, la).uncertain ~= nil and #item(f, lb).grants == 0, "reload mid-landing keeps the held slot and its uncertainty")
 assert(f:apply("continue_controller", { expected_revision = f.authority.registry.revision, operator_verified = true }).ok)
 check(queue(f, la).slot == la and #item(f, lb).grants == 0, "continuing the controller grants nothing while the slot is uncertain")
 check(reconcile(f, la, { outcome = "landed", target_revision = "head-1", reason = "Inspected the remote target log read-only", operator_verified = true }).ok,
  "owner reconciles the observed landed outcome")
 check(item(f, la).status == "landed" and queue(f, la).head.revision == "head-1" and queue(f, la).head.source == "owner" and queue(f, la).slot == nil,
  "reconciliation records the observed head and releases the slot")
 check(item(f, lb).hold.code == "target_moved", "later grants use the reconciled head")
 local g = api.fixture(); local gid = builder(g)
 ready(g, gid, "cp-1", "rev-1"); local lid = request(g, gid, "cp-1", "rev-1"); assert(approve(g, lid).ok)
 check(reconcile(g, lid, { outcome = "not_landed", reason = "Unchanged", operator_verified = true }).code == "reconciliation_required", "a live grant without uncertainty cannot be reconciled")
 check(g:apply("landing_lost", { landing_id = lid, landing_revision = item(g, lid).revision, reason = "Worker went silent mid-landing" }).ok
  and grant(g, lid).uncertain.code == "owner_marked_lost", "the owner can hold a silent landing as uncertain")
 check(reconcile(g, lid, { outcome = "not_landed", target_revision = "head-0", reason = "Target log unchanged", operator_verified = true }).ok, "owner reconciles not landed")
 check(queue(g, lid).slot == nil and item(g, lid).status == "blocked" and item(g, lid).refresh_required and #item(g, lid).grants == 1, "not landed releases the slot but never retries")
 check(report_landing(g, nil, lid, "landed", { result_revision = "head-1" }).ok and grant(g, lid).late_result.outcome == "landed" and item(g, lid).status == "blocked",
  "a late worker result after reconciliation is retained as evidence only")
 ready(g, gid, "cp-2", "rev-1"); request(g, gid, "cp-2", "rev-1", "head-0"); assert(approve(g, lid).ok)
 check(#item(g, lid).grants == 2 and queue(g, lid).slot == lid, "only an explicit fresh request and approval grant again")
 assert(send(g, gid, "DONE", { checkpoint_id = "cp-2", artifact_revision = hx("rev-1"), summary = "Task complete" }).ok)
 check(grant(g, lid).uncertain == nil and grant(g, lid).result == nil and item(g, lid).status == "granted" and queue(g, lid).slot == lid,
  "the builder's DONE neither settles nor clouds the release manager's grant; the slot stays held")
 check(restores(g), "reconciled, late and missing-result evidence restores")
 local clock = { now_ms = 1000, mono_ms = 1000, epoch = "landing-host" }
 local h = api.fixture(function() return api.clone(clock) end); local hid = builder(h)
 ready(h, hid, "cp-1", "rev-1"); local hl = request(h, hid, "cp-1", "rev-1"); assert(approve(h, hl).ok)
 assert(h:apply("observe", { worker_id = holder(h, hl), pane_binding = api.clone(worker(h, holder(h, hl)).pane_binding), native_state = "exited" }).ok)
 check(grant(h, hl).uncertain.code == "result_lost" and queue(h, hl).slot == hl and item(h, hl).status == "granted", "a worker that exits mid-landing leaves the slot uncertain, never landed")
end
if section == nil or section == "landing_lifecycle" then
 local clock = { now_ms = 1000, mono_ms = 1000, epoch = "landing-host" }
 local function idle_fixture()
  local fx = api.fixture(function() return api.clone(clock) end); local wid = builder(fx)
  assert(fx:apply("observe", { worker_id = wid, pane_binding = api.clone(worker(fx, wid).pane_binding), native_state = "idle" }).ok)
  ready(fx, wid, "cp-1", "rev-1")
  return fx, wid
 end
 local f, id = idle_fixture(); local lid = request(f, id, "cp-1", "rev-1")
 check(f:apply("finish", { worker_id = id }).code == "workflow_unsettled", "finish refuses a worker with an open landing request")
 local rolled = f:apply("rollover", { worker_id = id, trigger = "owner" })
 check(rolled.ok and item(f, lid).hold.code == "rollover_in_progress", "an ungranted request is held while its worker rolls over")
 assert(approve(f, lid).ok)
 check(#item(f, lid).grants == 0, "no grant is issued while the requesting builder is in an unfinished rollover")
 local g, gid = idle_fixture(); local glid = request(g, gid, "cp-1", "rev-1"); assert(approve(g, glid).ok)
 local rid = holder(g, glid)
 check(queue(g, glid).slot == glid and rid ~= nil and rid ~= gid, "fixture holds the landing slot on the release manager")
 assert(g:apply("observe", { worker_id = rid, pane_binding = api.clone(worker(g, rid).pane_binding), native_state = "idle" }).ok)
 check(g:apply("rollover", { worker_id = rid, trigger = "owner" }).code == "landing_in_progress", "the release manager holding a landing grant is pinned against rollover")
 check(g:apply("finish", { worker_id = rid }).code == "workflow_unsettled", "finish cannot abandon a granted landing")
 assert(g:apply("policy", { policy = { auto_rollover = true, rollover_threshold_pct = 50 } }).ok)
 settle(g, rid); assert(send(g, rid, "READY", { state = "idle", context_used_pct = 90 }).ok)
 local due = g:apply("rollover", { worker_id = rid, trigger = "policy" })
 local projected
 for _, row in api.dispatch.project(g.authority.registry, g.origin.logical_session_id, g.origin.alias_nonce).workflow.workers do if row.worker_id == rid then projected = row end end
 check(due.code == "landing_in_progress" and projected ~= nil and projected.due_rollover == false, "policy rollover is never requested or due while the release manager holds a landing grant")
 check(restores(f) and restores(g), "rollover/finish landing interaction restores")
end
-- Live gap: a queued request blocked as target_moved after another item landed was never told.
local function notices(f, id)
 local n = 0
 for _, entry in worker(f, id).workflow.thread do if entry.kind == "landing_refresh" then n += 1 end end
 return n
end
local function refresh_replies(f, id)
 local found = {}
 for _, retained in worker(f, id).replies do
  local reply = api.codec.decode_reply(retained.bytes, worker(f, id))
  if reply.kind == "landing_refresh" then table.insert(found, reply) end
 end
 return found
end
local function landed_bytes(f, id, lid, head)
 settle(f, id)
 local it, g = item(f, lid), grant(f, lid)
 return f:report(id, worker(f, id).accepted_seq + 1, "LANDING_RESULT", { landing_id = lid, grant_id = g.grant_id, project_id = it.request.project_id,
  repo_ref = it.request.repo_ref, target_ref = it.request.target_ref, target_revision = g.target_revision, source_revision = g.source_revision,
  outcome = "landed", result_revision = head, evidence = tern.json.array({ "log:fixture" }) }, { action_id = g.action_id, action_revision = g.action_revision })
end
if section == nil or section == "landing_refresh" then
 local f = api.fixture(); local a = builder(f); local b = builder(f); local c = builder(f)
 ready(f, a, "cp-a", "rev-a"); ready(f, b, "cp-b", "rev-b"); ready(f, c, "cp-c", "rev-c")
 local la, lb, lc = request(f, a, "cp-a", "rev-a"), request(f, b, "cp-b", "rev-b"), request(f, c, "cp-c", "rev-c")
 assert(approve(f, la).ok); assert(approve(f, lb).ok)
 check(queue(f, la).slot == la and item(f, lb).status == "ready" and notices(f, b) == 0 and notices(f, c) == 0 and item(f, lb).refresh == nil,
  "no refresh is owed while every queued request expects the recorded head")
 local manager = holder(f, la)
 local landed = landed_bytes(f, manager, la, "head-1")
 check(f:apply("intake", { worker_id = manager, bytes = landed }).ok and item(f, la).status == "landed" and queue(f, la).head.revision == "head-1", "the first request lands")
 check(item(f, lb).status == "blocked" and item(f, lb).hold.code == "target_moved" and #item(f, lb).grants == 0, "the second request is blocked target_moved, never granted")
 local issued = refresh_replies(f, b)
 check(#issued == 1 and notices(f, b) == 1 and issued[1].payload.landing_id == lb and issued[1].payload.project_id == "project-one"
  and issued[1].payload.repo_ref == "repo:fixture" and issued[1].payload.target_ref == "refs/heads/main" and issued[1].payload.expected_revision == "head-0"
  and issued[1].payload.current_revision == "head-1" and issued[1].gate_id == nil, "its worker generation gets exactly one typed landing_refresh naming the new head")
 local sent = api.clone(item(f, lb).refresh)
 check(sent.worker_id == b and sent.worker_generation == worker(f, b).worker_generation and sent.action_id == issued[1].action_id and sent.current_revision == "head-1"
  and not sent.published and not sent.acknowledged, "the item records the immutable refresh delivery to the builder generation, not the release manager")
 check(#refresh_replies(f, c) == 1 and refresh_replies(f, c)[1].payload.landing_id == lc and item(f, lc).hold.code == "target_moved",
  "a later queued request expecting the old head is told once as well")
 f:apply("intake", { worker_id = manager, bytes = landed })
 assert(send(f, b, "HEARTBEAT", { state = "working" }).ok)
 check(notices(f, b) == 1 and #refresh_replies(f, b) == 1 and notices(f, c) == 1 and item(f, lb).refresh.action_id == sent.action_id,
  "replaying the landed result and later commits never duplicate the refresh")
 check(restores(f), "an issued landing refresh restores through strict validation")
 for _ = 1, 32 do
  if item(f, lb).refresh.published then break end
  local poll = f:apply("poll", { worker_id = b }); assert(poll.ok, poll.message)
  local op = f:action(poll.action_id).request.op
  assert(op == "mailbox_publish_ack" or op == "mailbox_publish_reply" or op == "mailbox_retire", "unexpected poll operation " .. op)
  assert(f:finish(poll.action_id, if op == "mailbox_retire" then "compacted" else "published", {}).ok)
 end
 check(item(f, lb).refresh.published, "normal reply publication delivers the refresh")
 check(send(f, b, "reply_ack", { message_id = sent.message_id, reply_seq = sent.reply_seq, reply_sha256 = api.codec.sha256(sent.bytes), status = "recorded" },
  { action_id = sent.action_id, action_revision = sent.action_revision }).ok and item(f, lb).refresh.acknowledged, "the worker consumes the refresh once")
 ready(f, b, "cp-b2", "rev-b2")
 check(request(f, b, "cp-b2", "rev-b2", "head-1") == lb and item(f, lb).status == "verifying" and item(f, lb).hold.code == "approval_pending"
  and item(f, lb).approval == nil and #item(f, lb).grants == 0, "the refreshed request rebinds the item and needs owner approval again")
 check(notices(f, b) == 1, "a refreshed request against the current head owes no further notice")
 assert(approve(f, lb).ok)
 check(queue(f, lb).slot == lb and grant(f, lb).target_revision == "head-1" and grant(f, lb).source_revision == hx("rev-b2"), "only the new approval grants against the new head")
 ready(f, c, "cp-c2", "rev-c2")
 check(request(f, c, "cp-c2", "rev-c2", "head-1") == lc and notices(f, c) == 1, "the other worker refreshes against head-1 without a new notice")
 check(f:apply("intake", { worker_id = manager, bytes = landed_bytes(f, manager, lb, "head-2") }).ok and item(f, lc).hold.code == "target_moved", "a second target move blocks the refreshed request")
 check(notices(f, c) == 2 and item(f, lc).refresh.expected_revision == "head-1" and item(f, lc).refresh.current_revision == "head-2"
  and #refresh_replies(f, c) == 2, "a second move after the refresh issues exactly one new notice for the new head")
 check(restores(f), "refreshed, regranted and re-notified landing state restores")
end
-- CP2/CP3 proofs (helper check plus reviewer-worker review per request) make each fixture heavier, so the
-- deferred and backfilled refresh cases run as their own sections within the native slice budget.
if section == nil or section == "landing_refresh_deferred" then
 -- A full builder reply outbox (eight answered owner questions, unacknowledged) defers the notice with a
 -- visible hold and keeps the obligation.
 local g = api.fixture(); local ga = builder(g); local gb = builder(g)
 ready(g, ga, "cp-a", "rev-a"); ready(g, gb, "cp-b", "rev-b")
 local gla, glb = request(g, ga, "cp-a", "rev-a"), request(g, gb, "cp-b", "rev-b")
 assert(approve(g, gla).ok); assert(approve(g, glb).ok)
 for index = 1, 8 do
  settle(g, gb)
  assert(send(g, gb, "ASK", { question = "Proceed with fixture step " .. index .. "?", options = tern.json.array({ { id = "yes", label = "Yes" } }) }).ok)
  local open = {}
  for _, gate in gates_of(g, gb, "owner_question") do if gate.phase == "pending" then table.insert(open, gate) end end
  assert(#open == 1, "ASK opened no owner question")
  assert(answer(g, open[1], "yes").ok)
  -- The answered gate becomes an owner_decision reply on the builder's next poll.
  for _ = 1, 8 do
   local n = 0; for _ in worker(g, gb).replies do n += 1 end
   if n >= index then break end
   local polled = g:apply("poll", { worker_id = gb }); assert(polled.ok, polled.message)
   if not polled.action_id then break end
   local op = g:action(polled.action_id).request.op
   assert(g:finish(polled.action_id, if op == "mailbox_retire" then "compacted" elseif op == "mailbox_read" then "missing" else "published", {}).ok)
  end
 end
 local held = 0; for _ in worker(g, gb).replies do held += 1 end
 check(held == 8, "the builder's unacknowledged reply outbox is full")
 check(report_landing(g, nil, gla, "landed", { result_revision = "head-1" }).ok, "the first request lands while the outbox is full")
 check(item(g, glb).status == "blocked" and item(g, glb).hold.code == "target_moved" and item(g, glb).hold.message:find("Refresh notice deferred", 1, true) ~= nil
  and item(g, glb).refresh == nil and notices(g, gb) == 0, "a full outbox keeps the target_moved hold visible and defers the notice")
 settle(g, gb); assert(send(g, gb, "HEARTBEAT", { state = "working" }).ok)
 check(item(g, glb).refresh == nil and notices(g, gb) == 0 and item(g, glb).hold.code == "target_moved", "later commits keep the obligation while the outbox stays full")
 check(restores(g), "a deferred refresh obligation restores")
 local oldest, first
 for _, retained in worker(g, gb).replies do
  local reply = api.codec.decode_reply(retained.bytes, worker(g, gb))
  if first == nil or reply.reply_seq < first.reply_seq then oldest, first = retained, reply end
 end
 check(send(g, gb, "reply_ack", { message_id = first.message_id, reply_seq = first.reply_seq, reply_sha256 = api.codec.sha256(oldest.bytes), status = "recorded" },
  { action_id = first.action_id, action_revision = first.action_revision }).ok, "consuming the oldest reply frees outbox capacity")
 check(item(g, glb).refresh ~= nil and item(g, glb).refresh.current_revision == "head-1" and notices(g, gb) == 1 and #refresh_replies(g, gb) == 1
  and item(g, glb).hold.code == "target_moved" and item(g, glb).hold.message:find("deferred", 1, true) == nil, "the deferred refresh is issued exactly once on the next commit")
 check(restores(g), "the late-issued refresh restores")
end
if section == nil or section == "landing_refresh_backfill" then
 -- State written before landing_refresh existed: already blocked target_moved, never notified.
 local h = api.fixture(); local ha = builder(h); local hb = builder(h)
 ready(h, ha, "cp-a", "rev-a"); ready(h, hb, "cp-b", "rev-b")
 local hla, hlb = request(h, ha, "cp-a", "rev-a"), request(h, hb, "cp-b", "rev-b")
 assert(approve(h, hla).ok); assert(approve(h, hlb).ok)
 assert(report_landing(h, nil, hla, "landed", { result_revision = "head-1" }).ok)
 local stored = api.clone(h.memory.value)
 local stored_item, stored_worker = stored.dispatch.landing.items[hlb], stored.dispatch.workers[hb]
 local prior = stored_item.refresh; stored_item.refresh = nil
 assert(prior.reply_seq == stored_worker.reply_seq)
 stored_worker.replies[tostring(prior.reply_seq)] = nil; stored_worker.reply_seq -= 1
 for index, entry in stored_worker.workflow.thread do if entry.action_id == prior.action_id then table.remove(stored_worker.workflow.thread, index); break end end
 check(api.state.rehydrate(api.clone(stored)) ~= nil, "the pre-refresh stored shape is valid authority")
 h.memory.value = stored
 h.authority = api.host.new_authority(h.memory); assert(h.authority:load().ok)
 check(item(h, hlb).status == "blocked" and item(h, hlb).hold.code == "target_moved" and item(h, hlb).refresh == nil and notices(h, hb) == 0,
  "the reloaded item is blocked target_moved without any notice")
 assert(h:apply("continue_controller", { expected_revision = h.authority.registry.revision, operator_verified = true }).ok)
 check(item(h, hlb).refresh ~= nil and item(h, hlb).refresh.expected_revision == "head-0" and item(h, hlb).refresh.current_revision == "head-1"
  and notices(h, hb) == 1 and #refresh_replies(h, hb) == 1, "the next commit issues the missing refresh for an already blocked item")
 assert(h:apply("pause").ok); assert(h:apply("resume").ok)
 check(notices(h, hb) == 1 and #refresh_replies(h, hb) == 1, "later commits never duplicate the backfilled refresh")
 check(restores(h), "the backfilled refresh restores")
end
if section == nil or section == "effect_retention" then
 local f = api.fixture(); local id = f:accepted(false)
 local commands = function() return f.authority.registry.dispatch.commands end
 local function effects()
  local claims, results, bytes, per_action, repeated = 0, 0, 0, {}, false
  for _, command in commands() do
   local kind = command.event.command
   if kind == "claim" or kind == "result" or kind == "lost" then
    bytes += #tern.json.encode(command)
    if kind == "claim" then claims += 1 end
    if kind == "result" then
     results += 1; repeated = repeated or command.event.response_bytes ~= nil
     per_action[command.event.action_id] = (per_action[command.event.action_id] or 0) + 1
    end
   end
  end
  local most = 0; for _, n in per_action do most = math.max(most, n) end
  return claims, results, bytes, most, repeated
 end
 for cycle = 1, 24 do
  assert(send(f, id, "HEARTBEAT", { state = "working" }).ok)
  local queued = f:apply("poll", { worker_id = id }); assert(queued.ok, queued.message)
  assert(f:action(queued.action_id).request.op == "mailbox_publish_ack")
  assert(f:finish(queued.action_id, "published", {}).ok)
  if cycle % 4 == 0 then
   assert(f:watermark(id).ok)
   local compact = f:apply("poll", { worker_id = id }); assert(compact.ok, compact.message)
   assert(f:action(compact.action_id).request.op == "mailbox_retire")
   assert(f:finish(compact.action_id, "compacted", {}).ok)
  end
  local claims, results, bytes, most, repeated = effects()
  local polls = 0; for _, command in commands() do if command.event.command == "poll" then polls += 1 end end
  check(claims == 0 and most <= 1 and not repeated and bytes <= 768 * results and polls == 0,
   "cycle " .. cycle .. ": settled effects keep one compact result per action, no claim copy, no repeated response bytes and no poll outcome")
 end
 -- Exact duplicate result after its bytes were pruned from the retained outcome.
 assert(send(f, id, "HEARTBEAT", { state = "idle" }).ok)
 local poll_event = f:event("poll", { worker_id = id })
 local queued = f.authority:apply(poll_event); assert(queued.ok, queued.message)
 assert(f:apply("claim", { action_id = queued.action_id, executor = f.origin.window_epoch }).ok)
 local a = f:action(queued.action_id)
 local result_event = f:event("result", { action_id = queued.action_id, executor = f.origin.window_epoch, grant_id = a.claim.grant_id,
  response_bytes = api.frame(a.request, "published", {}) })
 local committed = f.authority:apply(result_event); assert(committed.ok, committed.message)
 assert(send(f, id, "READY", { state = "idle", summary = "Still here" }).ok)
 local retained = commands()[result_event.request_id]
 check(retained ~= nil and retained.event.response_bytes == nil and f:action(queued.action_id).response_bytes == result_event.response_bytes,
  "the retained result outcome omits the bytes its action already holds")
 local writes, revision = f.memory.writes, f.authority.registry.revision
 local replay = f.authority:apply(api.clone(result_event))
 check(replay.ok and replay.code == committed.code and f.memory.writes == writes and f.authority.registry.revision == revision,
  "an exact duplicate result is still a read-only replay after pruning")
 local changed = api.clone(result_event); changed.response_bytes = api.frame(a.request, "already_published", {})
 check(f.authority:apply(changed).code == "request_conflict" and f.memory.writes == writes, "different bytes under the same result request ID still conflict")
 check(f.authority:apply(api.clone(poll_event)).code == "stale_command" and f.memory.writes == writes and f:action(queued.action_id).phase == "complete",
  "a replayed poll without a retained outcome is refused by the command_seq barrier and queues nothing")
 -- Legacy stores: full claim/result outcomes validate, then restore compacts or drops them once.
 local legacy = api.clone(f.authority.registry); local sid = f.origin.logical_session_id
 legacy.dispatch.commands[result_event.request_id].event.response_bytes = result_event.response_bytes
 legacy.dispatch.commands["legacy-claim"] = { revision = legacy.revision, event = { kind = "dispatch", request_id = "legacy-claim", orch_session_id = sid,
  origin = api.clone(f.origin), controller_pane = "9001", command = "claim", action_id = queued.action_id, executor = f.origin.window_epoch },
  result = { ok = true, code = "effect_granted", message = "effect_granted", action_id = queued.action_id, request = api.clone(a.request), claim = api.clone(a.claim) } }
 legacy.dispatch.commands["legacy-orphan"] = { revision = legacy.revision, event = { kind = "dispatch", request_id = "legacy-orphan", orch_session_id = sid,
  origin = api.clone(f.origin), controller_pane = "9001", command = "result", action_id = "action-999999", executor = f.origin.window_epoch,
  grant_id = "grant-999999", response_bytes = result_event.response_bytes }, result = { ok = true, code = "bridge_committed", message = "bridge_committed" } }
 check(api.dispatch.valid(legacy.dispatch, legacy), "legacy full effect outcomes still validate")
 local restored = assert(api.state.rehydrate(api.clone(legacy)))
 local kept = restored.dispatch.commands
 check(kept[result_event.request_id] ~= nil and kept[result_event.request_id].event.response_bytes == nil and kept["legacy-claim"] == nil and kept["legacy-orphan"] == nil,
  "restore compacts the current result and drops settled claims and orphaned outcomes once")
 check(api.state.rehydrate(api.clone(restored)) ~= nil, "the compacted store restores again")
end
if section == nil or section == "idle_poll" then
 local now = 1000
 local f = api.fixture(function() return { now_ms = 1700000000000 + now, mono_ms = now, epoch = "idle-host" } end)
 local id = f:accepted(false)
 local function observe(state) return f:apply("observe", { worker_id = id, pane_binding = api.clone(worker(f, id).pane_binding), native_state = state }) end
 assert(observe("idle").ok)
 now += 10
 local read = f:apply("poll", { worker_id = id }); assert(read.ok, read.message)
 local selector = f:action(read.action_id).request.selector
 assert(f:action(read.action_id).request.op == "mailbox_read" and selector.stream == "report" and selector.slot == worker(f, id).accepted_seq + 1)
 assert(f:finish(read.action_id, "missing", {}).ok)
 check(worker(f, id).workflow.empty_read ~= nil and api.state.rehydrate(api.clone(f.authority.registry)) ~= nil, "an empty read of the next report is recorded and restores")
 now += 10
 local writes, revision, actions = f.memory.writes, f.authority.registry.revision, tern.json.encode(f.authority.registry.dispatch.actions)
 local idle = f:apply("poll", { worker_id = id })
 check(idle.ok and idle.code == "mailbox_idle" and idle.action_id == nil and f.memory.writes == writes and f.authority.registry.revision == revision
  and tern.json.encode(f.authority.registry.dispatch.actions) == actions, "an idle poll with nothing to read commits no revision and grants no read")
 check(send(f, id, "HEARTBEAT", { state = "idle" }).ok and f.authority.registry.revision == revision + 1, "a real report still commits")
 local publish = f:apply("poll", { worker_id = id })
 check(publish.ok and f.authority.registry.revision == revision + 2 and f:action(publish.action_id).request.op == "mailbox_publish_ack",
  "the poll after a report commits its outbound settlement")
 assert(f:finish(publish.action_id, "published", {}).ok)
 local next_read = f:apply("poll", { worker_id = id })
 check(next_read.ok and f:action(next_read.action_id).request.op == "mailbox_read" and f:action(next_read.action_id).request.selector.slot == worker(f, id).accepted_seq + 1,
  "an empty read of an earlier slot cannot suppress reading the next report")
 assert(f:finish(next_read.action_id, "missing", {}).ok)
 now += 10; assert(observe("working").ok)
 now += 10; assert(observe("idle").ok)
 local after_work = f:apply("poll", { worker_id = id })
 check(after_work.ok and f:action(after_work.action_id).request.op == "mailbox_read", "a native working edge after the empty read makes the next poll read again")
 assert(f:finish(after_work.action_id, "missing", {}).ok)
 now += 45000
 local stale = f:apply("poll", { worker_id = id })
 check(stale.ok and f:action(stale.action_id).request.op == "mailbox_read", "idle evidence older than stale_ms/4 no longer suppresses the read")
end
-- Contract B 0.3.0 → 0.4.0 landing upgrade: a retained 0.3.0 landing_grant (the closed 9-key payload, no
-- builder/review/proof fields) restores fail-closed as legacy_grant_outstanding; nothing re-addresses it.
local LEGACY_ENVELOPE = "version logical_session_id worker_id worker_generation launch_request_id work_id message_id reply_seq action_id action_revision kind payload"
local LEGACY_PAYLOAD = "landing_id grant_id project_id checkpoint_id repo_ref target_ref target_revision source_ref source_revision"
local function legacy_bytes(bytes)
 local raw = tern.json.decode(bytes); local old = { version = 1, payload = {} }
 for key in LEGACY_ENVELOPE:gmatch("%S+") do if key ~= "version" and key ~= "payload" then old[key] = raw[key] end end
 for key in LEGACY_PAYLOAD:gmatch("%S+") do old.payload[key] = raw.payload[key] end
 return tern.json.encode(old)
end
-- Rewrite one stored grant to the 0.3.0 shape: 0.3.0 addressed the grant to the requesting builder, so its
-- retained reply moves from the release manager's outbox to the builder's (re-enveloped for that builder,
-- closed 9-key payload), the item loses its 0.4.0 holder and proof, and the release manager forgets it.
local function to_legacy(stored, lid)
 local d = stored.dispatch
 local it = d.landing.items[lid]; local g = it.grants[#it.grants]
 local manager, b = d.workers[g.worker_id], d.workers[it.worker_id]
 local reply = manager.replies[tostring(g.reply_seq)]; manager.replies[tostring(g.reply_seq)] = nil
 if manager.reply_seq == g.reply_seq then manager.reply_seq -= 1 end
 for index, entry in manager.workflow.thread do if entry.action_id == g.action_id then table.remove(manager.workflow.thread, index); break end end
 local raw = tern.json.decode(g.bytes)
 for _, key in { "logical_session_id", "worker_id", "worker_generation", "launch_request_id", "work_id" } do raw[key] = b[key] end
 b.reply_seq += 1; raw.reply_seq = b.reply_seq
 local bytes = legacy_bytes(tern.json.encode(raw))
 g.bytes = bytes; g.worker_id = b.worker_id; g.reply_seq = b.reply_seq; it.proof = nil; it.holder = nil
 -- codec.frame refuses legacy bytes (it decodes under Contract D); the validator checks only digest, length and chunk count.
 local chunks = {}; for offset = 1, #bytes, 2048 do table.insert(chunks, bytes:sub(offset, offset + 2047)) end
 reply.bytes = bytes; reply.sha256 = api.codec.sha256(bytes); reply.reply_seq = b.reply_seq
 reply.frames = { manifest = reply.frames.manifest, chunks = chunks, message_sha256 = reply.sha256, message_bytes = #bytes }
 b.replies[tostring(b.reply_seq)] = reply
 return g
end
if section == nil or section == "landing_legacy" then
 local f = api.fixture(); local a = builder(f); local b = builder(f)
 ready(f, a, "cp-a", "rev-a"); assert(send(f, b, "CHECKPOINT", lcp("cp-b", "rev-b")).ok); assert(check_result(f, b, "rev-b").ok)
 local la, lb = request(f, a, "cp-a", "rev-a"), request(f, b, "cp-b", "rev-b")
 assert(approve(f, la).ok); assert(approve(f, lb).ok)
 assert(item(f, la).status == "granted" and item(f, lb).approval ~= nil and #item(f, lb).grants == 0)
 check(gates_of(f, nil, "legacy_grant_outstanding")[1] == nil and grant(f, la).legacy == nil, "a 0.4.0 grant is never marked legacy")
 local stored = api.clone(f.memory.value); local before = to_legacy(stored, la)
 local revision = stored.dispatch.landing.items[la].revision
 local restored = api.state.rehydrate(api.clone(stored))
 check(restored ~= nil and api.dispatch.valid(restored.dispatch, restored), "a store holding a 0.3.0 landing_grant restores and the upgraded registry validates")
 f.memory.value = stored; f.authority = api.host.new_authority(f.memory); assert(f.authority:load().ok)
 local g = grant(f, la); local it = item(f, la)
 check(g.legacy == true and worker(f, a).replies[tostring(g.reply_seq)].legacy == true and g.bytes == before.bytes,
  "the legacy grant and its retained reply are marked legacy and kept byte-for-byte as evidence")
 check(it.status == "granted" and it.hold.code == "legacy_grant_outstanding" and g.uncertain.code == "legacy_grant_outstanding" and it.revision == revision + 1
  and queue(f, la).slot == la and #it.grants == 1, "the outstanding legacy grant holds its slot as uncertain; it is never re-granted or re-addressed")
 local open = gates_of(f, nil, "legacy_grant_outstanding")
 check(#open == 1 and options(open[1]) == "acknowledge" and open[1].evidence[1] == "landing:" .. la and open[1].evidence[2] == "grant:" .. g.grant_id,
  "exactly one owner gate names the legacy landing and grant")
 check(item(f, lb).approval ~= nil and item(f, lb).hold.code == "review_required" and #item(f, lb).grants == 0,
  "an approved-but-ungranted item keeps its approval and is re-verified under Rule H")
 check(restores(f), "the upgraded store restores again without a second gate")
 f.authority = api.host.new_authority(f.memory); assert(f.authority:load().ok)
 check(#gates_of(f, nil, "legacy_grant_outstanding") == 1, "restoring twice never duplicates the legacy gate")
 -- A restored controller is uncertain until the same owner explicitly continues (same window epoch);
 -- each worker generation is then explicitly reattached before it may report again.
 assert(f:apply("continue_controller", { expected_revision = f.authority.registry.revision, operator_verified = true }).ok)
 for _, wid in { a, b } do
  local w = worker(f, wid); local pane = api.clone(w.pane_binding)
  local attached = f:apply("continue_worker", { worker_id = wid, pane_binding = pane,
   continuation_proof = api.dispatch.continuation_proof(f.authority.registry, w), operator_verified = true }); assert(attached.ok, attached.message)
  assert(f:finish(attached.action_id, "attached", { pane_binding = pane, previous_origin_binding = api.clone(w.origin_binding), previous_pane_binding = pane }).ok)
 end
 local refused = report_landing(f, a, la, "landed", { result_revision = "head-1" })
 check(not refused.ok and grant(f, la).late_result == nil and grant(f, la).result == nil and item(f, la).status == "granted" and queue(f, la).slot == la,
  "a builder LANDING_RESULT is refused even for the legacy grant addressed to it; it never settles it (" .. tostring(refused.code) .. ")")
 check(f:apply("reconcile_landing", { landing_id = la, landing_revision = item(f, la).revision, outcome = "not_landed", target_revision = "head-0",
  reason = "Inspected the target log read-only", operator_verified = true }).ok and queue(f, la).slot == nil and item(f, la).status == "blocked",
  "the existing reconcile path settles the legacy grant and releases the slot")
 assert(send(f, b, "HEARTBEAT", { state = "working" }).ok)
 check(#gates_of(f, nil, "legacy_grant_outstanding") == 0 and f.authority.registry.dispatch.gates[open[1].id].phase == "superseded",
  "the legacy gate is superseded once its grant is reconciled")
 check(restores(f), "the reconciled legacy landing restores")
end
-- CP2 gates (D6, D7, D9) and Rule H helper-checks proof. Each gate is tested both ways.
local arr = tern.json.array
local function action_count(f) local n = 0; for _ in f.authority.registry.dispatch.actions do n += 1 end; return n end
-- A queue refused into launch gates: no provision effect, the named gates open, owner options launch_anyway/cancel.
local function gated(f, result, kind, why)
 local open = if result.worker_id then gates_of(f, result.worker_id, kind) else {}
 check(result.code == "task_gated" and result.action_id == nil and type(result.gate_ids) == "table" and #result.gate_ids >= 1 and #open == 1
  and table.find(result.gate_ids, open[1].id) ~= nil and options(open[1]) == "launch_anyway,cancel"
  and open[1].question:find("Only same-session ORCH+ workers are visible", 1, true) ~= nil, why)
 return open[1], result.worker_id
end
local function launched_free(f, result, why)
 check(result.ok and result.code ~= "task_gated" and result.action_id ~= nil and (result.worker_id == nil or #gates_of(f, result.worker_id) == 0), why)
 return result
end
if section == nil or section == "checkout_gates" then
 local ROOT, WS = "/srv/agents/workspaces", "/srv/agents/workspaces/tools"
 local rows = { { "ws", WS }, { "nest", WS .. "/plugins/tern" }, { "dotted", WS .. "/plugins/../" }, { "other", ROOT .. "/other" }, { "top", "/srv/agents" },
  { "srv1", "/srv/one" }, { "srv2", "/srv/two" } }
 local f = api.fixture(); catalog(f, rows); assert(f:apply("policy", { policy = { checkout_roots = arr({ ROOT }) } }).ok)
 local first = launched_free(f, queue_work(f, "ws", WS), "cold start: the first worker in a session is never gated, even inside a checkout root")
 local a = start(f, first.worker_id, first.action_id)
 local before = action_count(f)
 local same, same_id = gated(f, queue_work(f, "ws", WS), "shared_checkout", "a second worker in the same checkout under a root is gated before launch")
 check(action_count(f) == before and worker(f, same_id).launch_action_id ~= nil and f:action(worker(f, same_id).launch_action_id) == nil,
  "a gated worker has no provision or launch effect")
 local nested, nested_id = gated(f, queue_work(f, "nest", WS .. "/plugins/tern"), "shared_checkout", "a worker nested inside another worker's checkout is gated")
 local dotted, dotted_id = gated(f, queue_work(f, "dotted", WS .. "/plugins/../"), "shared_checkout", "lexical normalization resolves .. and the trailing slash before comparing")
 local cancelled = answer(f, nested, "cancel")
 check(cancelled.code == "work_cancelled" and worker(f, nested_id) == nil and #gates_of(f, nested_id) == 0, "cancel removes the gated work without launching it")
 assert(answer(f, dotted, "cancel").code == "work_cancelled")
 local released = answer(f, same, "launch_anyway")
 check(released.code == "launch_released" and released.action_id ~= nil and #gates_of(f, same_id) == 0, "launch_anyway releases the normal launch path")
 start(f, same_id, released.action_id)
 launched_free(f, queue_work(f, "other", ROOT .. "/other"), "a disjoint checkout under the same root is not gated")
 launched_free(f, queue_work(f, "ws", WS, nil, true), "a coordinator is never checkout-gated")
 launched_free(f, queue_work(f, "top", "/srv/agents"), "root-excluded: a /srv/agents launch cwd is not gated when the root is /srv/agents/workspaces")
 local g = api.fixture(); catalog(g, rows); launch(g, "ws", WS)
 launched_free(g, queue_work(g, "ws", WS), "with no checkout_roots the shared-checkout gate is off")
 -- Intake of helper checkout facts: the later worker reporting the same worktree under a root is gated.
 local h = api.fixture(); catalog(h, rows); assert(h:apply("policy", { policy = { checkout_roots = arr({ ROOT }) } }).ok)
 local p = launch(h, "ws", WS); local q = launch(h, "other", ROOT .. "/other")
 local s1 = launch(h, "srv1", "/srv/one"); local s2 = launch(h, "srv2", "/srv/two")
 check(checkout(h, p, WS).ok and worker(h, p).checkout.worktree_path == WS and #gates_of(h) == 0, "a single worker's CHECKOUT is stored and never gates")
 check(checkout(h, q, ROOT .. "/other").ok and #gates_of(h) == 0, "different reported worktrees do not gate")
 check(checkout(h, q, WS).ok and #gates_of(h, q, "shared_checkout") == 1 and options(gates_of(h, q, "shared_checkout")[1]) == "acknowledge"
  and #gates_of(h, p) == 0, "the later worker reporting the same worktree under a root is gated; the earlier one is not")
 check(checkout(h, s1, "/srv/shared").ok and checkout(h, s2, "/srv/shared").ok and #gates_of(h, s1) == 0 and #gates_of(h, s2) == 0,
  "a shared worktree outside every checkout root is not gated")
 check(restores(f) and restores(h), "launch gates and checkout facts restore")
end
if section == nil or section == "file_overlap" then
 local rows = { { "repo", "/repo" }, { "elsewhere", "/elsewhere" } }
 local f = api.fixture(); catalog(f, rows)
 local a = launch(f, "repo", "/repo", { files = arr({ "src/a.luau", "docs/**" }) })
 launched_free(f, queue_work(f, "repo", "/repo", { files = arr({ "src/b.luau" }) }), "disjoint declared files in the same repository are not gated")
 launched_free(f, queue_work(f, "repo", "/repo"), "work without declared files is never overlap-gated")
 launched_free(f, queue_work(f, "elsewhere", "/elsewhere", { files = arr({ "src/a.luau" }) }), "the same path in another repository is not an overlap")
 for _, case in { { "src/a.luau", "an exact declared path overlaps" }, { "docs/guide.md", "a path under another worker's glob overlaps" },
  { "src/*", "a glob whose literal prefix is an ancestor of a declared path overlaps" } } do
  local gate, id = gated(f, queue_work(f, "repo", "/repo", { files = arr({ case[1] }) }), "file_overlap", case[2])
  check(answer(f, gate, "cancel").code == "work_cancelled" and worker(f, id) == nil, "cancelling the overlap removes the work")
 end
 assert(checkout(f, a, "/repo", { "lib/x.luau" }).ok)
 local gate, id = gated(f, queue_work(f, "repo", "/repo", { files = arr({ "lib/x.luau" }) }), "file_overlap", "a declared file another worker reported changed overlaps")
 launched_free(f, queue_work(f, "repo", "/repo", { files = arr({ "lib/y.luau" }) }), "a file nobody declared or changed is not gated")
 local released = answer(f, gate, "launch_anyway")
 check(released.code == "launch_released" and released.action_id ~= nil, "launch_anyway releases the overlapping work")
 start(f, id, released.action_id)
 -- Both launch gates at once: the last answer releases the launch.
 local g = api.fixture(); catalog(g, rows); assert(g:apply("policy", { policy = { checkout_roots = arr({ "/repo" }) } }).ok)
 launch(g, "repo", "/repo", { files = arr({ "src/a.luau" }) })
 local both = queue_work(g, "repo", "/repo", { files = arr({ "src/a.luau" }) })
 local overlap = gates_of(g, both.worker_id, "file_overlap")[1]; local shared = gates_of(g, both.worker_id, "shared_checkout")[1]
 check(both.code == "task_gated" and #both.gate_ids == 2 and overlap ~= nil and shared ~= nil, "a shared checkout with overlapping files opens both launch gates")
 check(answer(g, overlap, "launch_anyway").code == "launch_gate_answered" and both.action_id == nil, "one answered gate does not launch while another is open")
 local last = answer(g, shared, "launch_anyway")
 check(last.code == "launch_released" and last.action_id ~= nil and #gates_of(g, both.worker_id) == 0, "answering the last open launch gate releases the launch")
 check(restores(f) and restores(g), "overlap gates restore")
end
if section == nil or section == "scope" then
 local f = api.fixture(); catalog(f, { { "repo", "/repo" } }); assert(f:apply("policy", { policy = { enforce_cross_family = false } }).ok)
 local a = launch(f, "repo", "/repo", { files = arr({ "src/feature.luau" }), scope = { paths = arr({ "src/**" }), systems = arr() }, checks = UNIT })
 local function scoped() return gates_of(f, a, "scope") end
 check(checkout(f, a, "/repo", { "src/feature.luau" }).ok and #scoped() == 0, "changed files inside scope.paths do not gate")
 check(checkout(f, a, "/repo", { "src/feature.luau", "notes.txt" }, { dirty = true }).ok and #scoped() == 1 and options(scoped()[1]) == "accept,keep_blocked",
  "an untracked file outside scope.paths gates")
 local cp = lcp("cp-1", "rev-1"); cp.worktree_ref = "/repo"
 assert(send(f, a, "CHECKPOINT", cp).ok); local lid = request(f, a, "cp-1", "rev-1")
 check(item(f, lid).hold.code == "scope_open" and #item(f, lid).grants == 0, "landing is held while the scope gate is open")
 check(checkout(f, a, "/repo", { "src/feature.luau" }).ok and #scoped() == 0 and item(f, lid).hold.code ~= "scope_open", "a newer in-scope CHECKOUT supersedes the open scope gate")
 check(checkout(f, a, "/repo", { "src/feature.luau" }, { changed_overflow = true, changed_total = 900 }).ok and #scoped() == 1 and item(f, lid).hold.code == "scope_open",
  "changed_overflow gates even when every listed file is in scope")
 check(answer(f, scoped()[1], "accept").ok and #scoped() == 0 and item(f, lid).hold.code ~= "scope_open", "the owner's accept closes the scope gate and releases the hold")
 local moved = lcp("cp-2", "rev-1"); moved.worktree_ref = "/elsewhere"
 assert(send(f, a, "CHECKPOINT", moved).ok)
 local attention = false; for _, entry in worker(f, a).workflow.thread do attention = attention or entry.kind == "attention" end
 check(attention and item(f, lid).hold.code == "checkout_mismatch", "a CHECKPOINT naming another worktree than the latest CHECKOUT raises attention and holds landing")
 settle(f, a); local back = lcp("cp-3", "rev-1"); back.worktree_ref = "/repo/"
 check(send(f, a, "CHECKPOINT", back).ok and item(f, lid).hold.code ~= "checkout_mismatch", "a worktree_ref equal after normalization clears the mismatch")
 local b = launch(f, "repo", "/repo", { files = arr({ "lib/a.luau" }) })
 check(checkout(f, b, "/repo", { "lib/a.luau" }).ok and #gates_of(f, b, "scope") == 0, "scope defaults to the declared files: a declared file is in scope")
 check(checkout(f, b, "/repo", { "lib/a.luau", "lib/b.luau" }).ok and #gates_of(f, b, "scope") == 1, "an undeclared file is out of the default scope")
 local c = launch(f, "repo", "/repo")
 check(checkout(f, c, "/repo", { "anything.txt" }, { changed_overflow = true, changed_total = 700 }).ok and #gates_of(f, c) == 0, "work without declared scope or files is never scope-gated")
 local d = launch(f, "repo", "/repo", nil, { "report-files-v1", "native-ask-v1" })
 check(not checkout(f, d, "/repo", { "x" }).ok and worker(f, d).checkout == nil, "CHECKOUT needs the check-runner-v1 capability")
 check(restores(f), "scope gates, checkout facts and mismatch holds restore")
end
-- CP2 live smoke: a queue reclaimed the resolved scope accept gate and landing re-blocked as
-- scope_open with no gate left to answer. Owner decisions live on the worker, written with the
-- answer; gate reclamation removes only the question, never the decision or its thread record.
if section == nil or section == "scope_durable" then
 local f = api.fixture(); catalog(f, { { "repo", "/repo" }, { "other", "/other" } }); assert(f:apply("policy", { policy = { enforce_cross_family = false } }).ok)
 local a = launch(f, "repo", "/repo", { files = arr({ "src/feature.luau" }), scope = { paths = arr({ "src/**" }), systems = arr() }, checks = UNIT })
 local function hold(lid) local h = item(f, lid).hold; return if h then h.code else nil end
 assert(checkout(f, a, "/repo", { "src/feature.luau", "notes.txt" }).ok)
 local sg = gates_of(f, a, "scope")[1]; assert(sg, "out-of-scope CHECKOUT opens a scope gate")
 local cp = lcp("cp-1", "rev-1"); cp.worktree_ref = "/repo"
 assert(send(f, a, "CHECKPOINT", cp).ok); local lid = request(f, a, "cp-1", "rev-1")
 check(hold(lid) == "scope_open", "landing holds scope_open while the scope gate is unanswered")
 local accepted = answer(f, sg, "accept")
 local sa = worker(f, a).scope_accepted
 check(accepted.ok and sa ~= nil and sa.gate_id == sg.id and "scope:" .. sa.changed_digest == sg.evidence[1] and hold(lid) ~= "scope_open",
  "accept is recorded on the worker, keyed to the exact out-of-scope change set, in the answer's commit")
 assert(queue_work(f, "other", "/other").ok)
 check(f.authority.registry.dispatch.gates[sg.id] == nil, "queueing other work reclaims the resolved scope gate")
 check(hold(lid) ~= "scope_open", "landing stays released after the accepted gate is reclaimed")
 local recorded = false
 for _, entry in worker(f, a).workflow.thread do
  if entry.kind == "answer" and entry.gate_id == nil and entry.summary:find(sg.id, 1, true) and entry.summary:find("Accept these changes for landing", 1, true)
   and entry.summary:find("Question: " .. sg.question, 1, true) then recorded = true end
 end
 check(recorded, "the answered question and the chosen option remain in the thread after the gate is reclaimed")
 check(checkout(f, a, "/repo", { "src/feature.luau", "notes.txt" }).ok and #gates_of(f, a, "scope") == 0 and hold(lid) ~= "scope_open",
  "a repeated CHECKOUT of the accepted change set raises no new scope gate")
 check(checkout(f, a, "/repo", { "src/feature.luau", "other.txt" }).ok and #gates_of(f, a, "scope") == 1 and hold(lid) == "scope_open",
  "a different out-of-scope change set is not covered by the earlier accept")
 check(restores(f), "durable scope acceptance restores")
 -- A post-launch shared_checkout acknowledgement is durable too: reclamation never re-asks it.
 local h = api.fixture(); catalog(h, { { "p", "/root/p" }, { "q", "/root/q" }, { "z", "/elsewhere" } })
 assert(h:apply("policy", { policy = { checkout_roots = arr({ "/root" }) } }).ok)
 local p = launch(h, "p", "/root/p"); local q = launch(h, "q", "/root/q")
 assert(checkout(h, p, "/root/p").ok and checkout(h, q, "/root/p").ok)
 local shared = gates_of(h, q, "shared_checkout")[1]; assert(shared, "the later worker reporting the same worktree is gated")
 check(answer(h, shared, "acknowledge").ok and table.find(worker(h, q).shared_acked or {}, "peer:" .. p .. ":/root/p") ~= nil,
  "the acknowledgement is recorded on the worker in the answer's commit")
 assert(queue_work(h, "z", "/elsewhere").ok)
 check(h.authority.registry.dispatch.gates[shared.id] == nil, "queueing other work reclaims the acknowledged gate")
 check(checkout(h, q, "/root/p").ok and #gates_of(h, q, "shared_checkout") == 0, "a reclaimed acknowledgement is never asked again for the same peer and worktree")
 check(restores(h), "durable shared-checkout acknowledgements restore")
end
if section == nil or section == "check_proof" then
 local TWO = arr({ { check_id = "unit", argv = arr({ "luau", "tests/run.luau" }) }, { check_id = "lint", argv = arr({ "luau-analyze", "." }) } })
 local f = api.fixture(); local id = builder(f, { checks = TWO })
 assert(send(f, id, "CHECKPOINT", lcp("cp-1", "rev-1")).ok); local gid = review(f, id, "cp-1", "rev-1")
 local lid = request(f, id, "cp-1", "rev-1"); assert(approve(f, lid).ok)
 local function held(fx, l, code, why) check(item(fx, l).hold.code == code and #item(fx, l).grants == 0 and item(fx, l).proof == nil, why) end
 held(f, lid, "check_missing", "missing: no CHECK_RESULT for a declared check blocks the grant")
 check(check_result(f, id, "rev-1", 0, "unit").ok and worker(f, id).check_results.unit.exit_code == 0, "a passing helper check is stored by check_id")
 held(f, lid, "check_missing", "every declared check needs a result, not just one")
 assert(check_result(f, id, "rev-1", 1, "lint").ok); held(f, lid, "check_failed", "failed: a non-zero exit blocks the grant")
 assert(check_result(f, id, "rev-0", 0, "lint").ok); held(f, lid, "check_stale", "stale-head: a pass for another head blocks the grant")
 check(check_result(f, id, "rev-1", 0, "undeclared").ok and worker(f, id).check_results.undeclared == nil, "an undeclared check result is accepted but never stored as proof")
 held(f, lid, "check_stale", "an undeclared result does not change the proof")
 assert(check_result(f, id, "rev-1", 0, "lint").ok); rm(f)
 local proof = item(f, lid).proof
 check(item(f, lid).status == "granted" and proof.mode == "helper_checks" and proof.review_id == gid and proof.artifact_revision == hx("rev-1")
  and #proof.check_refs == 2 and proof.check_refs[1] == "unit:" .. OUTPUT and proof.check_refs[2] == "lint:" .. OUTPUT, "passing: every declared check passing at the head grants with its proof")
 local g = api.fixture(); local gw = builder(g, {}); assert(send(g, gw, "CHECKPOINT", lcp("cp-1", "rev-1")).ok); review(g, gw, "cp-1", "rev-1")
 local glid = request(g, gw, "cp-1", "rev-1"); assert(approve(g, glid).ok)
 held(g, glid, "checks_undeclared", "work that declared no checks cannot prove itself in helper-checks mode")
 local k = api.fixture(); local kw = builder(k, nil, { "report-files-v1", "native-ask-v1", "check-runner-v1" }); ready(k, kw, "cp-1", "rev-1")
 local klid = request(k, kw, "cp-1", "rev-1"); assert(approve(k, klid).ok)
 check(item(k, klid).status == "granted" and holder(k, klid) ~= kw and item(k, klid).proof ~= nil,
  "the builder needs no release-manager-v1: a fully proven request is granted to the release manager, never the builder")
 local m = api.fixture(); local mw = builder(m, nil, { "report-files-v1", "native-ask-v1", "release-manager-v1" })
 check(not check_result(m, mw, "rev-1").ok and next(worker(m, mw).check_results or {}) == nil, "CHECK_RESULT needs the check-runner-v1 capability")
 -- enforce_cross_family=true: a reviewer-worker review between undeclared (OMP) families is no cross-family proof.
 local e = api.fixture(); local ew = builder(e); ready(e, ew, "cp-1", "rev-1")
 assert(e:apply("policy", { policy = { enforce_cross_family = true } }).ok)
 local elid = request(e, ew, "cp-1", "rev-1"); assert(approve(e, elid).ok)
 held(e, elid, "family_unknown", "enforcement on: passing checks and an approved review without declared different families never grant")
 assert(e:apply("policy", { policy = { enforce_cross_family = false } }).ok); rm(e)
 check(item(e, elid).status == "granted" and item(e, elid).proof.mode == "helper_checks", "turning enforcement off re-evaluates the same evidence and grants")
 check(restores(f) and restores(g) and restores(k) and restores(e), "check results, holds and proofs restore")
end
-- Invariant sweep: a fixture that passes every CP2 check produces no gate beyond the expected kinds.
if section == nil or section == "gate_invariants" then
 local ROOT = "/srv/agents/workspaces"
 local f = api.fixture(); catalog(f, { { "native", "/fixture" }, { "one", ROOT .. "/one" }, { "two", ROOT .. "/two" }, { "top", "/srv/agents" } })
 assert(f:apply("policy", { policy = { enforce_cross_family = false, checkout_roots = arr({ ROOT }) } }).ok)
 local fields = { files = arr({ "src/a.luau" }), scope = { paths = arr({ "src/**" }), systems = arr() }, checks = UNIT }
 local one = launch(f, "one", ROOT .. "/one", fields); local two = launch(f, "two", ROOT .. "/two", fields); launch(f, "top", "/srv/agents")
 assert(checkout(f, one, ROOT .. "/one", { "src/a.luau" }).ok); assert(checkout(f, two, ROOT .. "/two", { "src/a.luau" }).ok)
 local cp = lcp("cp-1", "rev-1"); cp.worktree_ref = ROOT .. "/one"
 assert(send(f, one, "CHECKPOINT", cp).ok); assert(check_result(f, one, "rev-1").ok); review(f, one, "cp-1", "rev-1")
 local lid = request(f, one, "cp-1", "rev-1"); assert(approve(f, lid).ok)
 check(item(f, lid).status == "granted", "the passing fixture is granted")
 local kinds = {}
 for _, g in f.authority.registry.dispatch.gates do kinds[g.kind] = (kinds[g.kind] or 0) + 1 end
 local unexpected = {}
 for kind in kinds do if kind ~= "landing_approval" then table.insert(unexpected, kind) end end
 check(#unexpected == 0 and kinds.landing_approval == 1,
  "a passing fixture (reviewer-worker review) produces only its landing approval gate, never " .. table.concat(unexpected, ","))
end
-- Contract G: SPAWN's provision result must name exactly the manifest digest the work stored.
if section == nil or section == "manifest_provision" then
 local f = api.fixture(); catalog(f, { { "native", "/fixture" } })
 local function provisioning(fields)
  local queued = queue_work(f, "native", "/fixture", fields); assert(queued.ok and queued.action_id, queued.message)
  assert(f:apply("claim", { action_id = queued.action_id, executor = f.origin.window_epoch }).ok)
  return queued.worker_id, queued.action_id
 end
 local function provisioned(action_id, digest)
  return f:finish(action_id, "provisioned", { handle = "mailbox-manifest-" .. action_id, binding_digest = string.rep("e", 64), capabilities = tern.json.array(CAPS),
   limits = {}, manifest_sha256 = digest })
 end
 local id, action_id = provisioning({ checks = UNIT })
 local w, request = worker(f, id), f:action(action_id).request
 check(w.manifest_sha256 ~= nil and type(request.manifest) == "string" and api.codec.sha256(request.manifest) == w.manifest_sha256,
  "the provision request carries the exact manifest whose digest the work stored")
 local unchanged = tern.json.encode(worker(f, id))
 local missing = provisioned(action_id, nil)
 check(not missing.ok and missing.code == "manifest_mismatch" and tern.json.encode(worker(f, id)) == unchanged and f:action(action_id).phase == "claimed",
  "a provision result without the manifest digest is refused and binds no mailbox")
 local other = provisioned(action_id, api.codec.sha256("another manifest"))
 check(not other.ok and other.code == "manifest_mismatch" and worker(f, id).mailbox_handle == nil and worker(f, id).phase == "queued",
  "a different provisioned manifest digest authorizes no launch")
 check(provisioned(action_id, w.manifest_sha256).ok and worker(f, id).phase == "provisioned" and worker(f, id).mailbox_handle ~= nil,
  "the exact stored digest provisions and queues the launch")
 local plain, plain_action = provisioning(nil)
 check(worker(f, plain).manifest_sha256 == nil and f:action(plain_action).request.manifest == nil, "work without assignment fields provisions no manifest")
 local stray = provisioned(plain_action, api.codec.sha256("stray manifest"))
 check(not stray.ok and stray.code == "manifest_mismatch" and worker(f, plain).mailbox_handle == nil, "a manifest digest on a manifest-less provision is refused")
 check(provisioned(plain_action, nil).ok and worker(f, plain).phase == "provisioned", "a manifest-less provision without a digest proceeds")
 check(restores(f), "cross-checked provisions restore")
end
-- Contract G: SPAWN's provision result must name exactly the manifest digest the work stored.
if section == nil or section == "manifest_provision" then
 local f = api.fixture(); catalog(f, { { "native", "/fixture" } })
 local function provisioning(fields)
  local queued = queue_work(f, "native", "/fixture", fields); assert(queued.ok and queued.action_id, queued.message)
  assert(f:apply("claim", { action_id = queued.action_id, executor = f.origin.window_epoch }).ok)
  return queued.worker_id, queued.action_id
 end
 local function provisioned(action_id, digest)
  return f:finish(action_id, "provisioned", { handle = "mailbox-manifest-" .. action_id, binding_digest = string.rep("e", 64), capabilities = tern.json.array(CAPS),
   limits = {}, manifest_sha256 = digest })
 end
 local id, action_id = provisioning({ checks = UNIT })
 local w, request = worker(f, id), f:action(action_id).request
 check(w.manifest_sha256 ~= nil and type(request.manifest) == "string" and api.codec.sha256(request.manifest) == w.manifest_sha256,
  "the provision request carries the exact manifest whose digest the work stored")
 local unchanged = tern.json.encode(worker(f, id))
 local missing = provisioned(action_id, nil)
 check(not missing.ok and missing.code == "manifest_mismatch" and tern.json.encode(worker(f, id)) == unchanged and f:action(action_id).phase == "claimed",
  "a provision result without the manifest digest is refused and binds no mailbox")
 local other = provisioned(action_id, api.codec.sha256("another manifest"))
 check(not other.ok and other.code == "manifest_mismatch" and worker(f, id).mailbox_handle == nil and worker(f, id).phase == "queued",
  "a different provisioned manifest digest authorizes no launch")
 check(provisioned(action_id, w.manifest_sha256).ok and worker(f, id).phase == "provisioned" and worker(f, id).mailbox_handle ~= nil,
  "the exact stored digest provisions and queues the launch")
 local plain, plain_action = provisioning(nil)
 check(worker(f, plain).manifest_sha256 == nil and f:action(plain_action).request.manifest == nil, "work without assignment fields provisions no manifest")
 local stray = provisioned(plain_action, api.codec.sha256("stray manifest"))
 check(not stray.ok and stray.code == "manifest_mismatch" and worker(f, plain).mailbox_handle == nil, "a manifest digest on a manifest-less provision is refused")
 check(provisioned(plain_action, nil).ok and worker(f, plain).phase == "provisioned", "a manifest-less provision without a digest proceeds")
 check(restores(f), "cross-checked provisions restore")
end
assert(section == nil or table.find({ "core", "correlation", "proposals", "results", "migration", "capacity", "checkpoint_capacity", "context",
 "landing_queue", "landing_reorder", "landing_evidence", "landing_results", "landing_uncertain", "landing_lifecycle", "landing_refresh", "landing_refresh_deferred", "landing_refresh_backfill", "effect_retention", "idle_poll",
 "landing_legacy", "checkout_gates", "file_overlap", "scope", "scope_durable", "check_proof", "gate_invariants", "manifest_provision" }, section), "unknown reports section")
return "reports/" .. tostring(section or "all") .. ": " .. tostring(checks) .. " checks passed"
