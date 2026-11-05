-- Deterministic actual reducer/host behavior; no native effects. Run sections separately.
local root, section = ...
local api = assert(loadstring(tern.fs.read(root .. "/tests/dispatch.luau"), "dispatch-fixture"))(root, "fixture")
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
 check(f:apply("pause").ok and send(f, id, "COORDINATOR_PROPOSAL", p).code == "session_paused", "pause blocks new coordinator proposals")
 assert(f:apply("resume").ok)
 wrong = api.clone(p); wrong.work_id = "foreign-work"
 check(send(f, id, "COORDINATOR_PROPOSAL", wrong).code == "scope_mismatch", "foreign work cannot acquire an owner gate")
 check(send(f, id, "COORDINATOR_PROPOSAL", p).ok, "typed active coordinator proposal becomes durable question")
 local gate; for _, g in f.authority.registry.dispatch.gates do gate = g end
 check(gate.kind == "coordinator_proposal" and gate.phase == "pending" and gate.delivery == nil, "proposal is data, not native/merge execution")
 check(api.state.rehydrate(api.clone(f.authority.registry)) ~= nil, "typed proposal and activation evidence restore")
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
  -- An approved landing proposal is a decision record only; LANDING_RESULT correlates to landing grants.
  local payload = if kind == "review" then { artifact_revision = "revision-one", outcome = "approved", evidence = tern.json.array({ "review:fixture" }) }
   else { landing_id = "landing-none", grant_id = "grant-none", project_id = "project-one", repo_ref = "repo:fixture", target_ref = "main", target_revision = "base",
    source_revision = "revision-one", outcome = "landed", result_revision = "reported-result", evidence = tern.json.array({ "landing:reported" }) }
  local report_kind = if kind == "review" then "REVIEW_RESULT" else "LANDING_RESULT"
  if kind == "landing" then
   assert(ack(f,id,delivery).ok)
   check(send(f,id,report_kind,payload,{ action_id = delivery.action_id, action_revision = delivery.action_revision }).code == "action_mismatch",
    "an approved landing proposal decision cannot authorize a LANDING_RESULT; only an issued landing_grant can")
   check(f.authority.registry.dispatch.landing == nil, "a landing proposal never creates a queue item or grant")
   continue
  end
  check(send(f,id,report_kind,payload,extra).code == "action_mismatch", "publication alone cannot authorize " .. report_kind)
  assert(ack(f,id,delivery).ok)
  local wrong = api.clone(extra); wrong.action_revision += 1
  check(send(f,id,report_kind,payload,wrong).code == "binding_mismatch", "wrong action revision cannot correlate " .. report_kind)
  local changed = api.clone(payload)
  if kind == "review" then changed.artifact_revision = "changed" else changed.source_revision = "changed" end
  check(send(f,id,report_kind,changed,extra).code == "revision_mismatch", "changed checkpoint revision cannot authorize " .. report_kind)
  check(send(f,id,report_kind,payload,extra).ok, report_kind .. " retains exact correlated result evidence")
  check(f.authority.registry.dispatch.gates[gid].result ~= nil and worker(f,id).workflow.evidence[report_kind] ~= nil, "result remains durable beyond latest summary")
  check(send(f,id,report_kind,payload,extra).code == "result_already_recorded", "one decision cannot authorize a second result event")
  check(worker(f,id).stop_action_id == nil and worker(f,id).release == nil, "reported result never invents native closure/release")
  check(api.state.rehydrate(api.clone(f.authority.registry)) ~= nil, "correlated result and decision survive restoration")
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
-- Landing queue (CP4): exact requests, owner approval gates, one slot per target, exact results.
local function lcp(id, revision, outcome, holds)
 return { checkpoint_id = id, task_ref = "task:fixture", project_id = "project-one", worktree_ref = "worktree:fixture", artifact_revision = revision,
  completed = tern.json.array({ "Implemented the assigned change" }), remaining = tern.json.array(), holds = holds or tern.json.array(),
  checks = tern.json.array({ { check_id = "unit", artifact_revision = revision, outcome = outcome or "passed", evidence_ref = "unit:log" } }) }
end
local function lreq(cp_id, revision, head, target)
 return { checkpoint_id = cp_id, project_id = "project-one", repo_ref = "repo:fixture", target_ref = target or "refs/heads/main",
  target_revision = head or "head-0", source_ref = "refs/heads/" .. cp_id, source_revision = revision }
end
local function landing(f) return f.authority.registry.dispatch.landing end
local function item(f, lid) return landing(f).items[lid] end
local function queue(f, lid) return landing(f).queues[item(f, lid).queue_id] end
local function grant(f, lid) local it = item(f, lid); return it.grants[#it.grants] end
local function restores(f) return api.state.rehydrate(api.clone(f.authority.registry)) ~= nil end
local function request(f, id, cp_id, revision, head, target)
 local sent = send(f, id, "LANDING_REQUEST", lreq(cp_id, revision, head, target)); assert(sent.ok, sent.message)
 for key, candidate in landing(f).items do
  if candidate.work_id == worker(f, id).work_id and candidate.request.target_ref == (target or "refs/heads/main")
   and table.find({ "queued", "verifying", "ready", "blocked", "granted", "landing" }, candidate.status) then return key end
 end
 error("landing item missing")
end
local function approve(f, lid, choice)
 local gate = f.authority.registry.dispatch.gates[item(f, lid).gate_id]
 return f:apply("answer", { gate_id = gate.id, gate_revision = gate.revision, choice_id = choice or "approve", answer = "Owner decision for this exact landing request." })
end
local function ack_grant(f, id, lid)
 local g = grant(f, lid)
 return send(f, id, "reply_ack", { message_id = g.message_id, reply_seq = g.reply_seq, reply_sha256 = api.codec.sha256(g.bytes), status = "recorded" },
  { action_id = g.action_id, action_revision = g.action_revision })
end
local function report_landing(f, id, lid, outcome, fields)
 local it, g = item(f, lid), grant(f, lid)
 local p = { landing_id = lid, grant_id = g.grant_id, project_id = it.request.project_id, repo_ref = it.request.repo_ref, target_ref = it.request.target_ref,
  target_revision = g.target_revision, source_revision = g.source_revision, outcome = outcome, evidence = tern.json.array({ "log:fixture" }) }
 for key, value in fields or {} do p[key] = value end
 return send(f, id, "LANDING_RESULT", p, { action_id = g.action_id, action_revision = g.action_revision })
end
local function second_worker(f, handle, pane)
 local queued = f:queue(false); assert(queued.ok, queued.message)
 assert(f:finish(queued.action_id, "provisioned", { handle = handle, binding_digest = string.rep("d", 64),
  capabilities = tern.json.array({ "report-files-v1", "native-ask-v1" }), limits = {} }).ok)
 local w = worker(f, queued.worker_id)
 assert(f:finish(w.launch_action_id, "awaiting_acceptance", { pane_binding = { pane_id = pane, window_key = f.origin.window_key, window_epoch = f.origin.window_epoch,
  native_session_id = f.origin.native_session_id, window_host_id = f.origin.window_host_id } }).ok)
 assert(f:apply("intake", { worker_id = queued.worker_id, bytes = f:report(queued.worker_id, 1, "ACCEPTED", { assignment_sha256 = w.assignment_sha256 }) }).ok)
 assert(f:finish(f:apply("poll", { worker_id = queued.worker_id }).action_id, "published", {}).ok)
 assert(f:finish(f:apply("poll", { worker_id = queued.worker_id }).action_id, "accepted", {}).ok)
 return queued.worker_id
end
if section == nil or section == "landing_queue" then
 local f = api.fixture(); local a = f:accepted(false); local b = second_worker(f, "mailbox-second", "9004")
 assert(send(f, a, "CHECKPOINT", lcp("cp-a", "rev-a")).ok); assert(send(f, b, "CHECKPOINT", lcp("cp-b", "rev-b")).ok)
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
 local issued = api.codec.decode_reply(grant(f, la).bytes, worker(f, a))
 check(issued.kind == "landing_grant" and issued.payload.landing_id == la and issued.payload.target_revision == "head-0" and issued.payload.source_revision == "rev-a"
  and issued.payload.repo_ref == "repo:fixture" and issued.payload.checkpoint_id == "cp-a", "the grant names the exact artifact, target and expected head")
 check(send(f, a, "LANDING_REQUEST", lreq("cp-a", "rev-a")).code == "landing_in_progress", "a granted work cannot re-request the same target")
 local lr = request(f, b, "cp-b", "rev-b", "release-0", "refs/heads/release")
 assert(approve(f, lr).ok)
 check(queue(f, lr) ~= queue(f, la) and queue(f, lr).slot == lr and item(f, lr).status == "granted" and queue(f, la).slot == la,
  "another target keeps an independent FIFO queue and slot")
 check(restores(f), "queued, approved and granted landing state restores through strict validation")
 check(ack_grant(f, a, la).ok and item(f, la).status == "landing" and grant(f, la).acknowledged, "grant consumption moves granted to landing, never to landed")
 check(report_landing(f, a, la, "landed", { result_revision = "head-1", pr_ref = "pr:1" }).ok, "exact landed result accepted")
 q = queue(f, la)
 check(item(f, la).status == "landed" and q.slot == nil and q.head.revision == "head-1" and q.head.source == "landed" and q.order[1] == lb,
  "landed records the resulting head, releases the slot and advances the queue")
 check(item(f, lb).status == "blocked" and item(f, lb).hold.code == "target_moved" and #item(f, lb).grants == 0,
  "the next request expecting the old head is blocked, not granted against a moved target")
 check(report_landing(f, a, la, "landed", { result_revision = "head-1" }).code == "result_already_recorded", "one grant has one immutable result")
 assert(send(f, b, "CHECKPOINT", lcp("cp-b2", "rev-b2")).ok)
 check(request(f, b, "cp-b2", "rev-b2", "head-1") == lb and item(f, lb).status == "verifying" and item(f, lb).approval == nil,
  "refresh keeps the queue position and voids the prior approval")
 assert(approve(f, lb).ok)
 check(queue(f, lb).slot == lb and grant(f, lb).target_revision == "head-1" and grant(f, lb).source_revision == "rev-b2", "later grants for the target use the new head")
 check(restores(f), "landed history and refreshed grant restore")
 local g = api.fixture(); local x = g:accepted(false); local y = second_worker(g, "mailbox-y", "9004"); local z = second_worker(g, "mailbox-z", "9005")
 for index, wid in { x, y, z } do assert(send(g, wid, "CHECKPOINT", lcp("cp-" .. index, "rev-" .. index)).ok) end
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
 local f = api.fixture(); local id = f:accepted(false)
 assert(send(f, id, "CHECKPOINT", lcp("cp-1", "rev-1", "not_run")).ok)
 check(send(f, id, "LANDING_REQUEST", lreq("absent", "rev-1")).code == "checkpoint_mismatch", "a request must reference a retained checkpoint")
 check(send(f, id, "LANDING_REQUEST", lreq("cp-1", "rev-other")).code == "checkpoint_mismatch", "the source revision must be the checkpoint's artifact revision")
 local lid = request(f, id, "cp-1", "rev-1")
 assert(approve(f, lid).ok)
 local function blocked(code, why)
  check(item(f, lid).status == "blocked" and item(f, lid).hold.code == code and #item(f, lid).grants == 0 and queue(f, lid).slot == nil, why)
 end
 blocked("verification_missing", "an approved request whose check was not run is blocked, never granted")
 assert(send(f, id, "CHECKPOINT", lcp("cp-2", "rev-1", "failed")).ok); blocked("verification_failed", "failed required checks block landing")
 local stale = lcp("cp-3", "rev-1"); stale.checks[1].artifact_revision = "rev-0"
 assert(send(f, id, "CHECKPOINT", stale).ok); blocked("verification_stale", "checks for another revision are stale")
 assert(send(f, id, "CHECKPOINT", lcp("cp-4", "rev-1", "passed", tern.json.array({ "Waiting for owner review" }))).ok); blocked("hold_present", "a checkpoint hold blocks landing")
 assert(send(f, id, "CHECKPOINT", lcp("cp-5", "rev-2")).ok); blocked("verification_stale", "the worker's latest checkpoint must be for the requested revision")
 assert(send(f, id, "CHECKPOINT", lcp("cp-6", "rev-1")).ok)
 check(queue(f, lid).slot == lid and item(f, lid).status == "granted" and grant(f, lid).checkpoint_id == "cp-6"
  and item(f, lid).verification.attestation == "worker-attested", "fresh worker-attested evidence for the exact revision grants the approved head")
 local g = api.fixture(); local gid = g:accepted(false)
 assert(send(g, gid, "CHECKPOINT", lcp("cp-1", "rev-1")).ok); local glid = request(g, gid, "cp-1", "rev-1")
 assert(send(g, gid, "BLOCKED", { reason = "New project hold" }).ok); assert(approve(g, glid).ok)
 check(item(g, glid).hold.code == "worker_blocked" and #item(g, glid).grants == 0, "a new BLOCKED hold invalidates landing readiness")
 assert(g:apply("pause").ok); assert(send(g, gid, "HEARTBEAT", { state = "working" }).ok)
 check(item(g, glid).hold.code == "session_paused" and #item(g, glid).grants == 0, "pause holds landing grants")
 assert(g:apply("resume").ok)
 check(item(g, glid).status == "granted", "resume grants the still-fresh approved head")
 check(restores(f) and restores(g), "blocked and granted landing evidence restores")
end
if section == nil or section == "landing_results" then
 local f = api.fixture(); local a = f:accepted(false); local b = second_worker(f, "mailbox-second", "9004")
 assert(send(f, a, "CHECKPOINT", lcp("cp-a", "rev-a")).ok); assert(send(f, b, "CHECKPOINT", lcp("cp-b", "rev-b")).ok)
 local la, lb = request(f, a, "cp-a", "rev-a"), request(f, b, "cp-b", "rev-b")
 assert(approve(f, la).ok); assert(approve(f, lb).ok)
 check(report_landing(f, b, la, "landed", { result_revision = "head-x" }).code == "binding_mismatch", "another worker cannot settle this grant")
 check(report_landing(f, a, la, "landed", { result_revision = "head-x", target_revision = "other" }).code == "revision_mismatch", "a result must echo the grant's expected head")
 check(report_landing(f, a, la, "rejected", { reason = "Merge conflicts in a shared file" }).ok, "exact rejected result accepted")
 check(item(f, la).status == "failed" and item(f, la).hold.code == "rejected" and queue(f, la).head == nil, "rejected fails the item without inventing a target head")
 check(queue(f, lb).slot == lb and item(f, lb).status == "granted" and grant(f, lb).target_revision == "head-0", "the next approved head is granted after a rejection")
 check(report_landing(f, b, lb, "stale_target", { observed_target_revision = "head-9" }).ok, "stale_target accepted with the observed head")
 local q = queue(f, lb)
 check(q.slot == nil and q.head.revision == "head-9" and q.head.source == "stale_target" and q.order[1] == lb and item(f, lb).status == "blocked"
  and item(f, lb).refresh_required and item(f, lb).hold.code == "refresh_required", "stale target releases the grant and requeues the request as needing refresh")
 assert(send(f, b, "HEARTBEAT", { state = "working" }).ok)
 check(#item(f, lb).grants == 1 and queue(f, lb).slot == nil, "a released stale grant is never retried automatically")
 assert(send(f, b, "CHECKPOINT", lcp("cp-b2", "rev-b2")).ok)
 request(f, b, "cp-b2", "rev-b2", "head-0")
 check(item(f, lb).hold.code == "target_moved", "a refresh against the stale head is still refused")
 request(f, b, "cp-b2", "rev-b2", "head-9"); assert(approve(f, lb).ok)
 check(queue(f, lb).slot == lb and #item(f, lb).grants == 2 and grant(f, lb).target_revision == "head-9", "the refreshed request is granted against the observed head")
 check(restores(f), "rejected, stale and regranted landing evidence restores")
end
if section == nil or section == "landing_uncertain" then
 local f = api.fixture(); local a = f:accepted(false); local b = second_worker(f, "mailbox-second", "9004")
 assert(send(f, a, "CHECKPOINT", lcp("cp-a", "rev-a")).ok); assert(send(f, b, "CHECKPOINT", lcp("cp-b", "rev-b")).ok)
 local la, lb = request(f, a, "cp-a", "rev-a"), request(f, b, "cp-b", "rev-b")
 assert(approve(f, la).ok); assert(approve(f, lb).ok)
 check(report_landing(f, a, la, "uncertain", { reason = "Push timed out before the remote answered" }).ok, "worker-reported uncertainty accepted")
 check(queue(f, la).slot == la and grant(f, la).uncertain.code == "worker_reported_uncertain" and item(f, lb).status == "ready" and #item(f, lb).grants == 0,
  "an uncertain result holds the slot and blocks the next approved request")
 check(report_landing(f, a, la, "landed", { result_revision = "head-1" }).code == "result_already_recorded", "uncertainty is not replaced by a second worker result")
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
 local g = api.fixture(); local gid = g:accepted(false)
 assert(send(g, gid, "CHECKPOINT", lcp("cp-1", "rev-1")).ok); local lid = request(g, gid, "cp-1", "rev-1"); assert(approve(g, lid).ok)
 check(reconcile(g, lid, { outcome = "not_landed", reason = "Unchanged", operator_verified = true }).code == "reconciliation_required", "a live grant without uncertainty cannot be reconciled")
 check(g:apply("landing_lost", { landing_id = lid, landing_revision = item(g, lid).revision, reason = "Worker went silent mid-landing" }).ok
  and grant(g, lid).uncertain.code == "owner_marked_lost", "the owner can hold a silent landing as uncertain")
 check(reconcile(g, lid, { outcome = "not_landed", target_revision = "head-0", reason = "Target log unchanged", operator_verified = true }).ok, "owner reconciles not landed")
 check(queue(g, lid).slot == nil and item(g, lid).status == "blocked" and item(g, lid).refresh_required and #item(g, lid).grants == 1, "not landed releases the slot but never retries")
 check(report_landing(g, gid, lid, "landed", { result_revision = "head-1" }).ok and grant(g, lid).late_result.outcome == "landed" and item(g, lid).status == "blocked",
  "a late worker result after reconciliation is retained as evidence only")
 assert(send(g, gid, "CHECKPOINT", lcp("cp-2", "rev-1")).ok); request(g, gid, "cp-2", "rev-1", "head-0"); assert(approve(g, lid).ok)
 check(#item(g, lid).grants == 2 and queue(g, lid).slot == lid, "only an explicit fresh request and approval grant again")
 assert(send(g, gid, "DONE", { checkpoint_id = "cp-2", artifact_revision = "rev-1", summary = "Task complete" }).ok)
 check(grant(g, lid).uncertain.code == "result_missing" and item(g, lid).status == "granted" and queue(g, lid).slot == lid, "DONE never means landed; the slot stays held")
 check(restores(g), "reconciled, late and missing-result evidence restores")
 local clock = { now_ms = 1000, mono_ms = 1000, epoch = "landing-host" }
 local h = api.fixture(function() return api.clone(clock) end); local hid = h:accepted(false)
 assert(send(h, hid, "CHECKPOINT", lcp("cp-1", "rev-1")).ok); local hl = request(h, hid, "cp-1", "rev-1"); assert(approve(h, hl).ok)
 assert(h:apply("observe", { worker_id = hid, pane_binding = api.clone(worker(h, hid).pane_binding), native_state = "exited" }).ok)
 check(grant(h, hl).uncertain.code == "result_lost" and queue(h, hl).slot == hl and item(h, hl).status == "granted", "a worker that exits mid-landing leaves the slot uncertain, never landed")
end
if section == nil or section == "landing_lifecycle" then
 local clock = { now_ms = 1000, mono_ms = 1000, epoch = "landing-host" }
 local function idle_fixture()
  local fx = api.fixture(function() return api.clone(clock) end); local wid = fx:accepted(false)
  assert(fx:apply("observe", { worker_id = wid, pane_binding = api.clone(worker(fx, wid).pane_binding), native_state = "idle" }).ok)
  assert(send(fx, wid, "CHECKPOINT", lcp("cp-1", "rev-1")).ok)
  return fx, wid
 end
 local f, id = idle_fixture(); local lid = request(f, id, "cp-1", "rev-1")
 check(f:apply("finish", { worker_id = id }).code == "workflow_unsettled", "finish refuses a worker with an open landing request")
 local rolled = f:apply("rollover", { worker_id = id, trigger = "owner" })
 check(rolled.ok and item(f, lid).hold.code == "rollover_in_progress", "an ungranted request is held while its worker rolls over")
 assert(approve(f, lid).ok)
 check(#item(f, lid).grants == 0, "no grant is issued to a worker in an unfinished rollover")
 local g, gid = idle_fixture(); local glid = request(g, gid, "cp-1", "rev-1"); assert(approve(g, glid).ok)
 check(queue(g, glid).slot == glid, "fixture holds the landing slot")
 check(g:apply("rollover", { worker_id = gid, trigger = "owner" }).code == "landing_in_progress", "a worker holding a landing grant is pinned against rollover")
 check(g:apply("finish", { worker_id = gid }).code == "workflow_unsettled", "finish cannot abandon a granted landing")
 assert(g:apply("policy", { policy = { auto_rollover = true, rollover_threshold_pct = 50 } }).ok)
 assert(send(g, gid, "READY", { state = "idle", context_used_pct = 90 }).ok)
 local due = g:apply("rollover", { worker_id = gid, trigger = "policy" })
 local projected = api.dispatch.project(g.authority.registry, g.origin.logical_session_id, g.origin.alias_nonce).workflow.workers[1]
 check(due.code == "landing_in_progress" and projected.due_rollover == false, "policy rollover is never requested or due while the worker holds a landing grant")
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
 local it, g = item(f, lid), grant(f, lid)
 return f:report(id, worker(f, id).accepted_seq + 1, "LANDING_RESULT", { landing_id = lid, grant_id = g.grant_id, project_id = it.request.project_id,
  repo_ref = it.request.repo_ref, target_ref = it.request.target_ref, target_revision = g.target_revision, source_revision = g.source_revision,
  outcome = "landed", result_revision = head, evidence = tern.json.array({ "log:fixture" }) }, { action_id = g.action_id, action_revision = g.action_revision })
end
if section == nil or section == "landing_refresh" then
 local f = api.fixture(); local a = f:accepted(false); local b = second_worker(f, "mailbox-second", "9004"); local c = second_worker(f, "mailbox-third", "9005")
 assert(send(f, a, "CHECKPOINT", lcp("cp-a", "rev-a")).ok); assert(send(f, b, "CHECKPOINT", lcp("cp-b", "rev-b")).ok); assert(send(f, c, "CHECKPOINT", lcp("cp-c", "rev-c")).ok)
 local la, lb, lc = request(f, a, "cp-a", "rev-a"), request(f, b, "cp-b", "rev-b"), request(f, c, "cp-c", "rev-c")
 assert(approve(f, la).ok); assert(approve(f, lb).ok)
 check(queue(f, la).slot == la and item(f, lb).status == "ready" and notices(f, b) == 0 and notices(f, c) == 0 and item(f, lb).refresh == nil,
  "no refresh is owed while every queued request expects the recorded head")
 local landed = landed_bytes(f, a, la, "head-1")
 check(f:apply("intake", { worker_id = a, bytes = landed }).ok and item(f, la).status == "landed" and queue(f, la).head.revision == "head-1", "the first request lands")
 check(item(f, lb).status == "blocked" and item(f, lb).hold.code == "target_moved" and #item(f, lb).grants == 0, "the second request is blocked target_moved, never granted")
 local issued = refresh_replies(f, b)
 check(#issued == 1 and notices(f, b) == 1 and issued[1].payload.landing_id == lb and issued[1].payload.project_id == "project-one"
  and issued[1].payload.repo_ref == "repo:fixture" and issued[1].payload.target_ref == "refs/heads/main" and issued[1].payload.expected_revision == "head-0"
  and issued[1].payload.current_revision == "head-1" and issued[1].gate_id == nil, "its worker generation gets exactly one typed landing_refresh naming the new head")
 local sent = api.clone(item(f, lb).refresh)
 check(sent.worker_id == b and sent.action_id == issued[1].action_id and sent.current_revision == "head-1" and not sent.published and not sent.acknowledged,
  "the item records the immutable refresh delivery")
 check(#refresh_replies(f, c) == 1 and refresh_replies(f, c)[1].payload.landing_id == lc and item(f, lc).hold.code == "target_moved",
  "a later queued request expecting the old head is told once as well")
 f:apply("intake", { worker_id = a, bytes = landed })
 assert(send(f, b, "HEARTBEAT", { state = "working" }).ok)
 check(notices(f, b) == 1 and #refresh_replies(f, b) == 1 and notices(f, c) == 1 and item(f, lb).refresh.action_id == sent.action_id,
  "replaying the landed result and later commits never duplicate the refresh")
 check(restores(f), "an issued landing refresh restores through strict validation")
 for _ = 1, 32 do
  if item(f, lb).refresh.published then break end
  local poll = f:apply("poll", { worker_id = b }); assert(poll.ok, poll.message)
  local op = f:action(poll.action_id).request.op
  assert(op == "mailbox_publish_ack" or op == "mailbox_publish_reply", "unexpected poll operation " .. op)
  assert(f:finish(poll.action_id, "published", {}).ok)
 end
 check(item(f, lb).refresh.published, "normal reply publication delivers the refresh")
 check(send(f, b, "reply_ack", { message_id = sent.message_id, reply_seq = sent.reply_seq, reply_sha256 = api.codec.sha256(sent.bytes), status = "recorded" },
  { action_id = sent.action_id, action_revision = sent.action_revision }).ok and item(f, lb).refresh.acknowledged, "the worker consumes the refresh once")
 assert(send(f, b, "CHECKPOINT", lcp("cp-b2", "rev-b2")).ok)
 check(request(f, b, "cp-b2", "rev-b2", "head-1") == lb and item(f, lb).status == "verifying" and item(f, lb).hold.code == "approval_pending"
  and item(f, lb).approval == nil and #item(f, lb).grants == 0, "the refreshed request rebinds the item and needs owner approval again")
 check(notices(f, b) == 1, "a refreshed request against the current head owes no further notice")
 assert(approve(f, lb).ok)
 check(queue(f, lb).slot == lb and grant(f, lb).target_revision == "head-1" and grant(f, lb).source_revision == "rev-b2", "only the new approval grants against the new head")
 assert(send(f, c, "CHECKPOINT", lcp("cp-c2", "rev-c2")).ok)
 check(request(f, c, "cp-c2", "rev-c2", "head-1") == lc and notices(f, c) == 1, "the other worker refreshes against head-1 without a new notice")
 check(f:apply("intake", { worker_id = b, bytes = landed_bytes(f, b, lb, "head-2") }).ok and item(f, lc).hold.code == "target_moved", "a second target move blocks the refreshed request")
 check(notices(f, c) == 2 and item(f, lc).refresh.expected_revision == "head-1" and item(f, lc).refresh.current_revision == "head-2"
  and #refresh_replies(f, c) == 2, "a second move after the refresh issues exactly one new notice for the new head")
 check(restores(f), "refreshed, regranted and re-notified landing state restores")

 -- A full reply outbox defers the notice with a visible hold and keeps the obligation.
 local g = api.fixture(); local ga = g:accepted(false); local gb = second_worker(g, "mailbox-second", "9004")
 assert(send(g, ga, "CHECKPOINT", lcp("cp-a", "rev-a")).ok); assert(send(g, gb, "CHECKPOINT", lcp("cp-b", "rev-b")).ok)
 local gla, glb = request(g, ga, "cp-a", "rev-a"), request(g, gb, "cp-b", "rev-b")
 assert(approve(g, gla).ok); assert(approve(g, glb).ok)
 local others = {}
 for index = 1, 8 do
  assert(g:watermark(gb).ok)
  local lid = request(g, gb, "cp-b", "rev-b", "t-0", "refs/heads/t" .. index); assert(approve(g, lid).ok)
  check(queue(g, lid).slot == lid, "fixture grants another target to fill the reply outbox"); table.insert(others, lid)
 end
 local held = 0; for _ in worker(g, gb).replies do held += 1 end
 check(held == 8, "the worker's unacknowledged reply outbox is full")
 check(report_landing(g, ga, gla, "landed", { result_revision = "head-1" }).ok, "the first request lands while the outbox is full")
 check(item(g, glb).status == "blocked" and item(g, glb).hold.code == "target_moved" and item(g, glb).hold.message:find("Refresh notice deferred", 1, true) ~= nil
  and item(g, glb).refresh == nil and notices(g, gb) == 0, "a full outbox keeps the target_moved hold visible and defers the notice")
 assert(send(g, gb, "HEARTBEAT", { state = "working" }).ok)
 check(item(g, glb).refresh == nil and notices(g, gb) == 0 and item(g, glb).hold.code == "target_moved", "later commits keep the obligation while the outbox stays full")
 check(restores(g), "a deferred refresh obligation restores")
 check(ack_grant(g, gb, others[1]).ok, "consuming the oldest reply frees outbox capacity")
 check(item(g, glb).refresh ~= nil and item(g, glb).refresh.current_revision == "head-1" and notices(g, gb) == 1 and #refresh_replies(g, gb) == 1
  and item(g, glb).hold.code == "target_moved" and item(g, glb).hold.message:find("deferred", 1, true) == nil, "the deferred refresh is issued exactly once on the next commit")
 check(restores(g), "the late-issued refresh restores")

 -- State written before landing_refresh existed: already blocked target_moved, never notified.
 local h = api.fixture(); local ha = h:accepted(false); local hb = second_worker(h, "mailbox-second", "9004")
 assert(send(h, ha, "CHECKPOINT", lcp("cp-a", "rev-a")).ok); assert(send(h, hb, "CHECKPOINT", lcp("cp-b", "rev-b")).ok)
 local hla, hlb = request(h, ha, "cp-a", "rev-a"), request(h, hb, "cp-b", "rev-b")
 assert(approve(h, hla).ok); assert(approve(h, hlb).ok)
 assert(report_landing(h, ha, hla, "landed", { result_revision = "head-1" }).ok)
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
assert(section == nil or table.find({ "core", "correlation", "proposals", "results", "migration", "capacity", "checkpoint_capacity", "context",
 "landing_queue", "landing_evidence", "landing_results", "landing_uncertain", "landing_lifecycle", "landing_refresh", "effect_retention", "idle_poll" }, section), "unknown reports section")
return "reports/" .. tostring(section or "all") .. ": " .. tostring(checks) .. " checks passed"
