-- Actual reducer/sole-host persistence cases. Run each section in a bounded host callback.
local root, section = ...
-- Test chunks run in this group's environment (as tests/run.luau loads groups), so their tern.json calls are
-- the stepped runner's yield points and a long section spans many native slices.
local function load_test(name, chunkname, ...)
 local chunk = assert(loadstring(tern.fs.read(root .. "/tests/" .. name .. ".luau"), chunkname))
 setfenv(chunk, setmetatable({}, { __index = getfenv() }))
 return chunk(root, ...)
end
local api = load_test("dispatch", "dispatch-fixture", "fixture")
local checks = 0
local function check(ok, message) assert(ok, message); checks += 1 end
local function w(f, id) return f.authority.registry.dispatch.workers[id] end
local function gate(f, id) return f.authority.registry.dispatch.gates[id] end
local function ask(f, id)
 local result = f:apply("intake", { worker_id = id, bytes = f:report(id, w(f,id).accepted_seq + 1, "ASK", { question = "Which path should this exact work take?", options = tern.json.array({ { id = "safe", label = "Use reviewed path" }, { id = "hold", label = "Hold" } }), evidence = tern.json.array({ "checkpoint:fixture" }) }) })
 assert(result.ok, result.message)
 for key, g in f.authority.registry.dispatch.gates do if g.phase == "pending" then return key end end
 error("gate missing")
end
local function publish(f, id, gid)
 for _ = 1, 12 do
  if gate(f,gid).phase == "delivered" then return end
  local queued = f:apply("poll", { worker_id = id }); assert(queued.ok, queued.message)
  local action = f:action(queued.action_id)
  assert(action.request.op == "mailbox_publish_ack" or action.request.op == "mailbox_publish_reply", action.request.op)
  assert(f:finish(queued.action_id, "published", {}).ok)
 end
 error("decision outbox did not finish")
end
local function acknowledge(f, id, delivery)
 return f:apply("intake", { worker_id = id, bytes = f:report(id, w(f,id).accepted_seq + 1, "reply_ack", { message_id = delivery.message_id, reply_seq = delivery.reply_seq,
  reply_sha256 = api.codec.sha256(delivery.bytes), status = "recorded" }, { action_id = delivery.action_id, action_revision = delivery.action_revision }) })
end
if section == nil or section == "lifecycle" then
 local f = api.fixture(); local id = f:accepted(false); local gid = ask(f,id)
 check(gate(f,gid).phase == "pending" and gate(f,gid).worker_generation == w(f,id).worker_generation, "ASK binds durable question/options/recipient")
 check(api.state.rehydrate(api.clone(f.authority.registry)) ~= nil, "pending question restores")
 local event = f:event("answer", { gate_id = gid, gate_revision = 1, choice_id = "safe", answer = "Use the reviewed path only." })
 local before = tern.json.encode(f.authority.registry); f.memory.fail = true
 check(f.authority:apply(event).code == "persistence_failed" and tern.json.encode(f.authority.registry) == before, "failed answer save changes no gate, thread, reply or grant")
 f.memory.fail = false
 check(f.authority:apply(event).code == "gate_answered" and gate(f,gid).phase == "answered" and gate(f,gid).delivery == nil, "answer records UI source before separate outbox issuance")
 local writes = f.memory.writes
 check(f.authority:apply(api.clone(event)).ok and f.memory.writes == writes, "same exact answer request is idempotent")
 local changed = api.clone(event); changed.answer = "Different operation"
 check(f.authority:apply(changed).code == "request_conflict", "same answer ID cannot authorize different text")
 check(f:apply("answer", { gate_id = gid, gate_revision = 1, choice_id = "hold", answer = "Changed mind" }).code == "stale_gate", "changed answer cannot replace an answered revision")
 assert(f:apply("pause").ok)
 publish(f,id,gid)
 local delivery = api.clone(gate(f,gid).delivery)
 check(gate(f,gid).phase == "delivered" and not delivery.acknowledged, "publication is not consumption, even while paused")
 local reply = api.codec.decode_reply(delivery.bytes, w(f,id))
 check(reply.kind == "owner_decision" and reply.gate_id == gid and reply.gate_revision == 1 and reply.payload.choice_id == "safe", "immutable reply carries exact gate/revision and answer")
 check(acknowledge(f,id,delivery).ok and gate(f,gid).phase == "acknowledged", "only correlated worker ACK settles decision")
 check(w(f,id).reply_floor == delivery.reply_seq and w(f,id).replies[tostring(delivery.reply_seq)] == nil, "settled reply compacts without losing durable decision evidence")
 check(api.state.rehydrate(api.clone(f.authority.registry)) ~= nil, "acknowledged gate restores after reply compaction")
 for _, entry in w(f,id).workflow.thread do if entry.gate_id == gid then check(entry.state == "settled", "gate-related pending entries settle on consumption") end end
end
if section == nil or section == "cancel" then
 local f = api.fixture(); local id = f:accepted(false); local gid = ask(f,id)
 check(f:apply("answer", { gate_id = gid, gate_revision = 2, choice_id = "safe", answer = "No" }).code == "stale_gate", "stale gate revision rejected")
 local wrong = f:event("answer", { gate_id = gid, gate_revision = 1, choice_id = "safe", answer = "No" }); wrong.origin.window_epoch = "other-window"
 check(f.authority:apply(wrong).code == "continuation_required", "different recipient origin cannot answer without explicit continuation")
 assert(f:apply("answer", { gate_id = gid, gate_revision = 1, choice_id = "safe", answer = "Proceed only with named work" }).ok)
 publish(f,id,gid)
 local delivery = api.clone(gate(f,gid).delivery)
 check(f:apply("cancel_gate", { gate_id = gid, gate_revision = 1 }).ok and gate(f,gid).phase == "cancelled", "owner cancellation is explicit")
 check(gate(f,gid).delivery_uncertain and gate(f,gid).delivery.bytes == delivery.bytes, "cancellation after possible delivery preserves immutable uncertainty")
 check(w(f,id).replies[tostring(delivery.reply_seq)] ~= nil, "unacknowledged cancelled decision cannot be evicted")
 check(acknowledge(f,id,delivery).ok and gate(f,gid).phase == "cancelled" and not gate(f,gid).delivery_uncertain, "late exact ACK settles transport without undoing cancellation")
 check(api.state.rehydrate(api.clone(f.authority.registry)) ~= nil, "cancelled and acknowledged uncertainty restores")
 local g = api.fixture(); local wid = g:accepted(false); local pending = ask(g,wid)
 check(g:apply("cancel_gate", { gate_id = pending, gate_revision = 1 }).ok and gate(g,pending).delivery == nil, "pre-answer cancellation creates no decision reply")
end
if section == nil or section == "native" then
 local clock = { now_ms = 100, mono_ms = 10, epoch = "host-test" }
 local f = api.fixture(function() return api.clone(clock) end); local id = f:accepted(false)
 local observation = { worker_id = id, pane_binding = api.clone(w(f,id).pane_binding), native_state = "waiting-input", observation_seq = 1 }
 local failure = api.fixture(function() return api.clone(clock) end); local failed_id = failure:accepted(false)
 local failed_event = failure:event("observe", { worker_id = failed_id, pane_binding = api.clone(w(failure,failed_id).pane_binding), native_state = "waiting-input", observation_seq = 1 })
 local original = tern.json.encode(failure.authority.registry); failure.memory.fail = true
 check(failure.authority:apply(failed_event).code == "persistence_failed" and tern.json.encode(failure.authority.registry) == original, "failed observation save advances neither highwater nor freshness/gate")
 failure.memory.fail = false
 check(failure.authority:apply(failed_event).code == "uncommitted_observation", "failed safety observation retains the existing runtime fence; test never clears it")
 local event = f:event("observe", observation)
 check(f.authority:apply(event).ok, "fresh exact native prompt observation is accepted")
 local writes = f.memory.writes
 check(f.authority:apply(api.clone(event)).ok and f.memory.writes == writes, "latest observation replay is idempotent without another permanent command")
 check(f.authority.registry.dispatch.command_cursors[f.origin.logical_session_id].seq == event.command_seq and w(f,id).workflow.observation_cursor.seq == 1, "observation keeps both durable intent replay barrier and bounded per-worker observation cursor")
 local gid; for key in f.authority.registry.dispatch.gates do gid = key end
 check(gate(f,gid).kind == "native_input", "native prompt has an owner remedy gate")
 check(f:apply("answer", { gate_id = gid, gate_revision = 1, choice_id = "recheck", answer = "yes" }).code == "recheck_only", "native remedy never creates a typed prompt answer")
 check(f:apply("reply", { worker_id = id }).code == "worker_not_sendable", "native waiting-input is never interrupted")
 local replies = w(f,id).reply_seq
 check(f:apply("recheck_gate", { gate_id = gid, gate_revision = 1 }).ok and w(f,id).reply_seq == replies, "owner resolved button only requests observation")
 clock.mono_ms += 100; clock.now_ms += 100; observation.native_state = "idle"; observation.observation_seq = 2
 check(f:apply("observe", observation).ok and gate(f,gid).phase == "superseded", "fresh safe native observation supersedes resolved prompt gate")
 check(w(f,id).reply_seq == replies, "recheck never signs in, sends permission input or creates generic retry")
 local before = tern.json.encode(f.authority.registry); observation.observation_seq = 1
 check(f:apply("observe", observation).code == "stale_observation" and tern.json.encode(f.authority.registry) == before, "old observation sequence cannot refresh stale evidence")
 local changed = f:event("observe", observation); changed.origin.window_epoch = "new-incarnation"; changed.observation_seq = 999
 check(f.authority:apply(changed).code == "continuation_required" and tern.json.encode(f.authority.registry) == before, "new window incarnation cannot reset or bypass original worker origin")
 clock.epoch = "host-after-reload"; clock.mono_ms = 1
 local restored = api.state.rehydrate(api.clone(f.authority.registry))
 check(restored ~= nil and restored.dispatch.workers[id].workflow.observation_cursor.seq == 2, "restore retains observation highwater independently of host epoch")
 check(restored.dispatch.workers[id].workflow.health.freshness == "unconfirmed", "restore never compares old monotonic timestamps to new epoch")
end
if section == nil or section == "capacity" then
 local f = api.fixture(); local id = f:accepted(false); local gid = ask(f,id)
 local candidate = api.clone(f.authority.registry); local template = candidate.dispatch.gates[gid]
 for i = 2, 64 do
  local pending = api.clone(template); pending.id = "capacity-gate-" .. i
  candidate.dispatch.gates[pending.id] = pending
  table.insert(candidate.dispatch.workers[id].workflow.thread, { id = "capacity-entry-" .. i, kind = "question", summary = pending.question, at_ms = 1, state = "pending", gate_id = pending.id })
 end
 check(api.state.rehydrate(api.clone(candidate)) ~= nil, "bounded full gate fixture restores with every pending question retained")
 local original = tern.json.encode(candidate)
 local bytes = f:report(id, 3, "ASK", { question = "Do not drop another question", options = tern.json.array({ { id = "hold", label = "Hold" } }) })
 local _, err = api.dispatch.intake(candidate, candidate.dispatch.workers[id], bytes, { now_ms = 1 })
 check(err.code == "full" and tern.json.encode(candidate) == original, "gate capacity rejects atomically instead of evicting pending decisions")
 candidate.dispatch.gates[gid].worker_generation += 1
 check(api.state.rehydrate(candidate) == nil, "mismatched persisted gate recipient generation cannot restore")
 local invalid = api.clone(f.authority.registry); invalid.dispatch.gates[gid].options = tern.json.null
 check(api.state.rehydrate(invalid) == nil, "null gate options reject without candidate fallback")
end
if section == nil or section == "settled_history" then
 local clock = { now_ms = 100, mono_ms = 100, epoch = "gate-history" }
 local f = api.fixture(function() return api.clone(clock) end); local id = f:accepted(false)
 local original_report = f:report(id, 2, "ASK", { question = "Retain replay fencing", options = tern.json.array({ { id = "safe", label = "Safe" } }) })
 assert(f:apply("intake", { worker_id = id, bytes = original_report }).ok)
 local original_gate = next(f.authority.registry.dispatch.gates)
 assert(f:apply("answer", { gate_id = original_gate, gate_revision = 1, choice_id = "safe", answer = "Exactly this question." }).ok)
 publish(f,id,original_gate); assert(acknowledge(f,id,gate(f,original_gate).delivery).ok)
 for index = 1, 65 do
  clock.now_ms += 1; clock.mono_ms += 1
  assert(f:apply("observe", { worker_id = id, pane_binding = w(f,id).pane_binding, native_state = "waiting-input" }).ok)
  local pending
  for key, value in f.authority.registry.dispatch.gates do if value.phase == "pending" then pending = key end end
  assert(pending, "actual native input observation creates next gate")
  assert(f:apply("cancel_gate", { gate_id = pending, gate_revision = 1 }).ok)
  assert(f:apply("observe", { worker_id = id, pane_binding = w(f,id).pane_binding, native_state = "idle" }).ok)
 end
 check(gate(f,original_gate) == nil, "more than64 settled gates reclaim acknowledged/cancelled-safe history")
 local gates_before = tern.json.encode(f.authority.registry.dispatch.gates)
 check(f:apply("intake", { worker_id = id, bytes = original_report }).code == "report_replayed", "old ASK replays its durable receipt independently of removed gate history")
 check(tern.json.encode(f.authority.registry.dispatch.gates) == gates_before and w(f,id).accepted_seq == 3, "old ASK cannot recreate an owner question after gate pruning")
 check(f:watermark(id).ok, "receipt watermark settles independently of removed gate display history")
 check(f:apply("intake", { worker_id = id, bytes = original_report }).code == "already_compacted", "confirmed receipt floor remains a permanent stale-report barrier")
 check(api.state.rehydrate(api.clone(f.authority.registry)) ~= nil, "reclaimed gates leave no dangling thread/health references")
end
-- Stale claims (CP1): one advisory stale_claim gate per claimed action after stale_claim_min
-- minutes on this host epoch; restore and epoch changes rebase aging; answers never move a claim.
if section == nil or section == "stale_claim" then
 local MIN = 60000
 local function stale_gates(f, aid)
  local found = {}
  for key, g in f.authority.registry.dispatch.gates or {} do
   if g.kind == "stale_claim" and (aid == nil or table.find(g.evidence, "action:" .. aid)) then table.insert(found, key) end
  end
  return found
 end
 local function stale_in(reg) local n = 0; for _, value in reg.dispatch.gates or {} do if value.kind == "stale_claim" then n += 1 end end; return n end
 local function claimed(minutes)
  local clock = { now_ms = 1700000000000, mono_ms = 1000, epoch = "stale-host" }
  local f = api.fixture(function() return api.clone(clock) end); local id = f:accepted(false)
  if minutes ~= nil then assert(f:apply("policy", { policy = { stale_claim_min = minutes } }).ok) end
  local queued = f:apply("poll", { worker_id = id }); assert(queued.ok and queued.action_id, queued.message)
  assert(f:apply("claim", { action_id = queued.action_id, executor = f.origin.window_epoch }).ok)
  return f, clock, queued.action_id
 end
 local function advance(f, clock, ms) clock.mono_ms += ms; clock.now_ms += ms; return f.authority:apply({ kind = "workflow_tick" }) end
 -- Default 30 minutes: fresh, N-1, N, then no duplicate.
 local f, clock, aid = claimed(nil)
 check(api.dispatch.policy(f.authority.registry, f.origin.logical_session_id).stale_claim_min == 30, "stale_claim_min defaults to 30 minutes")
 local stamped = f:action(aid).claim.claimed_at
 check(stamped ~= nil and stamped.epoch == "stale-host" and stamped.mono_ms == clock.mono_ms, "a claim is stamped with the host clock when it is granted")
 advance(f, clock, 0)
 check(#stale_gates(f) == 0, "cold start: a fresh claim never gates")
 advance(f, clock, 29 * MIN)
 check(#stale_gates(f) == 0 and f:action(aid).claim.stale_gate_id == nil, "at N-1 minutes no stale_claim gate opens")
 advance(f, clock, MIN)
 local opened = stale_gates(f, aid)
 check(#opened == 1 and f:action(aid).claim.stale_gate_id == opened[1], "at N minutes exactly one stale_claim gate opens for the action")
 local g = gate(f, opened[1])
 local lead = "Action " .. aid .. " has been claimed for 30 minutes without a result. ORCH+ never takes over a claim; open the recovery guide to reconcile it by hand."
 check(g.question:sub(1, #lead) == lead, "the stale_claim gate names the action, its minutes and that ORCH+ never takes over")
 check(#g.options == 2 and g.options[1].id == "keep_waiting" and g.options[1].label == "Keep waiting" and g.options[2].id == "open_recovery"
  and g.options[2].label == "Open recovery guide", "the stale_claim gate offers keep_waiting and open_recovery")
 advance(f, clock, MIN); advance(f, clock, 60 * MIN)
 check(#stale_gates(f) == 1, "later ticks never open a duplicate stale_claim gate")
 check(api.state.rehydrate(api.clone(f.authority.registry)) ~= nil, "a stale-claim gate and stamped claim restore")
 -- Answers never change the claim phase or grant.
 local grant_id = f:action(aid).claim.grant_id
 local keep = f:apply("answer", { gate_id = g.id, gate_revision = g.revision, choice_id = "keep_waiting", answer = "Keep waiting" })
 check(keep.code == "stale_claim_answered" and f:action(aid).phase == "claimed" and f:action(aid).claim.grant_id == grant_id, "keep_waiting leaves the claim exactly as it was")
 check(gate(f, g.id).phase ~= "pending" and gate(f, g.id).delivery == nil, "the answer settles the advisory gate without a worker reply")
 local h, hclock, haid = claimed(1)
 advance(h, hclock, MIN)
 local hg = gate(h, stale_gates(h, haid)[1])
 local hgrant = h:action(haid).claim.grant_id
 check(h:apply("answer", { gate_id = hg.id, gate_revision = hg.revision, choice_id = "open_recovery", answer = "Open recovery guide" }).code == "stale_claim_answered"
  and h:action(haid).phase == "claimed" and h:action(haid).claim.grant_id == hgrant, "open_recovery leaves the claim claimed with the same grant; recovery is by hand")
 -- stale_claim_min = 0 is off; 1 is on.
 local z, zclock = claimed(0)
 advance(z, zclock, 1440 * MIN)
 check(#stale_gates(z) == 0, "stale_claim_min = 0 never gates, even after a day")
 local one, oclock, oaid = claimed(1)
 advance(one, oclock, MIN)
 check(#stale_gates(one, oaid) == 1, "stale_claim_min = 1 gates after one minute")
 -- CP2 live smoke: a backpressured action is not a stuck claim, and its capacity rechecks (fresh
 -- grants for the same exact request) never stream new stale_claim gates: one gate per action.
 local b, bclock, baid = claimed(1)
 local FULL = { resource = "capacity_admission", current = 1, limit = 1, retryable = true, effect_started = false }
 check(b:finish(baid, "full", FULL).code == "backpressure", "a definitive pre-effect full refusal leaves the action backpressured with its claim")
 advance(b, bclock, MIN); advance(b, bclock, 10 * MIN)
 check(#stale_gates(b, baid) == 0, "a backpressured action never opens a stale_claim gate")
 local s, sclock, said = claimed(1)
 advance(s, sclock, MIN)
 local first_gate = stale_gates(s, said)[1]
 assert(first_gate and s:finish(said, "full", FULL).code == "backpressure")
 advance(s, sclock, 0)
 check(gate(s, first_gate).phase == "superseded", "the claim's open stale_claim gate is superseded once SPAWN refuses it before effects")
 for round = 1, 3 do
  assert(s:apply("retry", { action_id = said }).ok)
  check(s:action(said).stale_gate_id == first_gate and s:action(said).claim == nil, "a rechecked action keeps its stale-claim lineage while it waits for a claim")
  assert(s:apply("claim", { action_id = said, executor = s.origin.window_epoch }).ok)
  check(s:action(said).claim.stale_gate_id == first_gate and s:action(said).stale_gate_id == nil, "the recheck's fresh claim inherits the action's stale_claim gate")
  advance(s, sclock, 10 * MIN)
  check(#stale_gates(s, said) == 1, "recheck claim " .. round .. " that waits past the limit opens no second stale_claim gate")
  assert(s:finish(said, "full", FULL).code == "backpressure")
 end
 check(api.state.rehydrate(api.clone(s.authority.registry)) ~= nil, "a rechecked claim lineage restores")
 assert(s:apply("retry", { action_id = said }).ok)
 check(api.state.rehydrate(api.clone(s.authority.registry)) ~= nil, "a ready action carrying its stale-claim lineage restores")
 -- A restored 0.3.0 claim without claimed_at is rebased on the first tick, never gated on it.
 local r, rclock, raid = claimed(1)
 local legacy = api.clone(r.authority.registry); legacy.dispatch.actions[raid].claim.claimed_at = nil
 local restored = api.state.rehydrate(api.clone(legacy))
 check(restored ~= nil and restored.dispatch.actions[raid].claim.claimed_at == nil, "a 0.3.0 claim without claimed_at restores unstamped")
 rclock.mono_ms += 600 * MIN
 local first = api.dispatch.tick(restored, { kind = "workflow_tick" }, api.clone(rclock))
 check(first ~= nil and first.dispatch.actions[raid].claim.claimed_at.mono_ms == rclock.mono_ms and first.dispatch.actions[raid].claim.claimed_at.epoch == rclock.epoch
  and stale_in(first) == 0, "the first tick after restore rebases the unstamped claim and opens no gate")
 rclock.mono_ms += MIN - 1
 check(stale_in(api.dispatch.tick(first, { kind = "workflow_tick" }, api.clone(rclock)) or first) == 0, "the rebased claim is not stale one millisecond before N minutes")
 rclock.mono_ms += 1
 local due = api.dispatch.tick(first, { kind = "workflow_tick" }, api.clone(rclock))
 check(due ~= nil and stale_in(due) == 1, "the rebased claim gates N minutes after the rebase")
 -- A timestamped claim across a host restart (new epoch) is rebased, then gates N minutes later.
 local e, eclock, eaid = claimed(1)
 local old = api.clone(e:action(eaid).claim.claimed_at)
 eclock.epoch = "stale-host-restarted"; eclock.mono_ms = 5
 local reloaded = api.state.rehydrate(api.clone(e.authority.registry))
 local rebased = api.dispatch.tick(reloaded, { kind = "workflow_tick" }, api.clone(eclock))
 check(old.epoch == "stale-host" and rebased ~= nil and rebased.dispatch.actions[eaid].claim.claimed_at.epoch == "stale-host-restarted"
  and rebased.dispatch.actions[eaid].claim.claimed_at.mono_ms == 5 and stale_in(rebased) == 0, "a claim from the previous host epoch is rebased on the first tick, not gated")
 eclock.mono_ms += MIN - 1
 check(stale_in(api.dispatch.tick(rebased, { kind = "workflow_tick" }, api.clone(eclock)) or rebased) == 0, "the cross-epoch claim does not gate before N minutes on the new epoch")
 eclock.mono_ms += 1
 local later = api.dispatch.tick(rebased, { kind = "workflow_tick" }, api.clone(eclock))
 check(later ~= nil and stale_in(later) == 1, "the cross-epoch claim gates N minutes after its rebase")
end
-- Checkpoint 5 invariant sweep (D8/D9). Every fixture command in every group already runs
-- f:autonomy_sweep (tests/dispatch.luau): no policy answer without enabled auto_approve_kinds, and
-- never on manual work. This section adds pause, manual-source and restore-idempotence cases.
if section == nil or section == "autonomy" then
 local W = load_test("workflow", "workflow-helpers", "helpers", api)
 local wapi = W.api()
 local function new_gate(f, before)
  for key, g in f.authority.registry.dispatch.gates or {} do if not before[key] then return g end end
  error("no new gate")
 end
 local function ids(f) local out = {}; for key in f.authority.registry.dispatch.gates or {} do out[key] = true end; return out end
 local function propose(f, cid, kind, b, extra)
  local before = ids(f); local sent = W.propose(f, cid, kind, W.worker(f, b).work_id, extra); assert(sent.ok, sent.message)
  return new_gate(f, before)
 end
 local PLANNED = { source = W.PLAN, files = W.arr({ "src/feature.luau" }) }
 -- Default policy: an in-scope proposal is never answered by policy.
 do
  local f = W.fixture({ reviewer_records = W.arr({ "codex" }) })
  local b = W.builder(f, "builder", PLANNED); W.settle(f, b); assert(W.send(f, b, "CHECKPOINT", W.cp("cp-1", "rev-1")).ok)
  local cid = W.coordinator(f)
  for _, kind in { "report", "review", "dispatch" } do
   local g = propose(f, cid, kind, b, if kind == "dispatch" then { record_id = "claude2", record_revision = 0, prompt = "Next task." } elseif kind == "review" then { checkpoint_id = "cp-1" } else nil)
   check(g.phase == "pending" and g.answer == nil and g.execution == nil, "auto_approve_kinds=[]: in-scope " .. kind .. " proposal waits for the owner")
  end
  check(f.autonomous ~= true, "the default-policy fixture never enabled auto-approval (sweep asserted no policy answers)")
 end
 -- Manual-source work never auto-approves, even with every kind enabled.
 do
  local f = W.fixture({ reviewer_records = W.arr({ "codex" }), auto_approve_kinds = W.arr({ "dispatch", "report", "review", "landing" }) })
  local b = W.builder(f, "builder", { source = { kind = "manual" }, files = W.arr({ "src/feature.luau" }) })
  W.round(f, b, "cp-1", "rev-1", "approved"); local lid = W.request(f, b, "cp-1", "rev-1"); W.rm(f)
  local lg = f.authority.registry.dispatch.gates[W.item(f, lid).gate_id]
  check(lg.answer == nil and W.item(f, lid).approval == nil and #W.item(f, lid).grants == 0, "manual work: the proven landing approval still waits for the owner")
  local cid = W.coordinator(f)
  for _, kind in { "report", "review", "dispatch", "landing" } do
   local g = propose(f, cid, kind, b, if kind == "dispatch" then { record_id = "claude2", record_revision = 0, prompt = "Next task." } elseif kind == "report" then nil else { checkpoint_id = "cp-1" })
   check(g.phase == "pending" and g.answer == nil and g.execution == nil and table.find(g.evidence, "scope:source_not_planned") ~= nil,
    "manual work: " .. kind .. " proposal is out of scope and never auto-approved")
  end
  check(W.restores(f), "manual-source proposals restore")
 end
 -- Pause executes nothing: an owner-approved proposal records pending session_paused through tick and
 -- restore; enabling landing auto-approval while paused answers nothing; resume executes once.
 do
  local f = W.fixture({ reviewer_records = W.arr({ "codex" }) })
  local b = W.builder(f, "builder", PLANNED)
  W.round(f, b, "cp-1", "rev-1", "approved"); local lid = W.request(f, b, "cp-1", "rev-1"); W.rm(f)
  local b2 = W.builder(f, "claude2", { source = W.PLAN, files = W.arr({ "src/other.luau" }) }); W.settle(f, b2); assert(W.send(f, b2, "CHECKPOINT", W.cp("cp-2", "rev-2")).ok)
  local cid = W.coordinator(f)
  local g = propose(f, cid, "review", b2, { checkpoint_id = "cp-2" })
  assert(f:apply("pause").ok)
  check(W.propose(f, cid, "report", W.worker(f, b2).work_id).code == "session_paused", "pause refuses new proposals")
  local before = W.effects(f)
  local answered = f:apply("answer", { gate_id = g.id, gate_revision = g.revision, choice_id = "approve", answer = "Owner approves." })
  local e = f.authority.registry.dispatch.gates[g.id].execution
  check(answered.ok and e ~= nil and e.state == "pending" and e.effect_ref == "session_paused" and W.effects(f) == before, "paused: the owner answer records a pending execution and executes nothing")
  assert(f:apply("policy", { policy = { auto_approve_kinds = W.arr({ "landing" }) } }).ok)
  assert(f.authority:apply({ kind = "workflow_tick" }))
  local lg = f.authority.registry.dispatch.gates[W.item(f, lid).gate_id]
  check(lg.answer == nil and W.item(f, lid).approval == nil and #W.item(f, lid).grants == 0 and W.effects(f) == before, "paused: landing auto-approval answers nothing and nothing executes on tick")
  local restored = assert(wapi.state.rehydrate(wapi.clone(f.authority.registry)))
  local twin = wapi.dispatch.tick(restored, { kind = "workflow_tick" }, { now_ms = 1, mono_ms = 1, epoch = "paused-twin" }) or restored
  check(W.effects({ authority = { registry = twin } }) == before and twin.dispatch.gates[g.id].execution.state == "pending", "paused: a restored twin executes nothing")
  assert(f:apply("resume").ok)
  e = f.authority.registry.dispatch.gates[g.id].execution
  local r = W.review(f, b2)
  check(e.state == "done" and r ~= nil and e.effect_ref == "review:" .. r.review_id, "resume executes the pending approved proposal once")
  W.rm(f)
  lg = f.authority.registry.dispatch.gates[W.item(f, lid).gate_id]
  check(lg.answer ~= nil and lg.answer.source.kind == "policy" and lg.answer.source.rule == "auto_approve:landing" and #W.item(f, lid).grants == 1,
   "after resume the proven in-scope landing approval is answered by policy and granted once")
  W.idempotent(f, "paused then resumed review", g.id, nil)
  check(W.restores(f), "the resumed session restores")
 end
 -- Restore migration: an untagged owner answer becomes kind="owner"; a pre-CP5 approved proposal
 -- without an execution record restores as decision-only and never executes.
 do
  local f = W.fixture({ reviewer_records = W.arr({ "codex" }) })
  local b = W.builder(f, "builder", PLANNED); W.settle(f, b); assert(W.send(f, b, "CHECKPOINT", W.cp("cp-1", "rev-1")).ok)
  local cid = W.coordinator(f)
  local g = propose(f, cid, "report", b)
  local stored = wapi.clone(f.memory.value)
  local raw = stored.dispatch.gates[g.id]
  raw.answer = { choice_id = "approve", answer = "Approved before 0.4.0.", source = wapi.clone(f.origin), at_ms = 0 }
  raw.phase = "answered"
  stored.dispatch.gates[g.id] = raw
  local before = W.effects(f)
  f.memory.value = stored; f.authority = wapi.host.new_authority(f.memory)
  local loaded = f.authority:load()
  check(loaded.ok, "a store with an untagged pre-0.4.0 answer loads (" .. tostring(loaded.code) .. ")")
  local mg = f.authority.registry.dispatch.gates[g.id]
  check(mg.answer.source.kind == "owner" and mg.answer.source.owner_id == f.origin.owner_id, "restore tags the existing answer source kind=owner")
  check(mg.execution ~= nil and mg.execution.state == "refused" and mg.execution.effect_ref == "legacy_decision_only", "a pre-0.4.0 approved proposal restores decision-only")
  assert(f.authority:apply({ kind = "workflow_tick" })); f:autonomy_sweep()
  check(W.effects(f) == before and W.worker(f, b).workflow.report_request == nil, "the migrated decision never executes")
 end
end
assert(section == nil or table.find({ "lifecycle", "cancel", "native", "capacity", "settled_history", "stale_claim", "autonomy" }, section), "unknown gates section")
return "gates/" .. tostring(section or "all") .. ": " .. tostring(checks) .. " checks passed"
