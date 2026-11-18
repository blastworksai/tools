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
 check(f.authority:apply(api.clone(event)).code == "stale_revision" and f.memory.writes == writes, "old answer intent cannot execute again after its captured revision changed")
 local changed = api.clone(event); changed.answer = "Different operation"
 check(f.authority:apply(changed).code == "stale_revision", "changing stale answer bytes cannot refresh its authority")
 check(not f:apply("answer", { gate_id = gid, gate_revision = 1, choice_id = "hold", answer = "Changed mind" }).ok, "changed answer cannot replace an answered revision")
 assert(f:apply("pause").ok)
 publish(f,id,gid)
 local delivery = api.clone(gate(f,gid).delivery)
 check(gate(f,gid).phase == "delivered" and not delivery.acknowledged, "publication is not consumption, even while paused")
 local reply = api.codec.decode_reply(delivery.bytes, w(f,id))
 check(reply.kind == "owner_decision" and reply.gate_id == gid and reply.gate_revision == 1 and reply.payload.choice_id == "safe", "immutable reply carries exact gate/revision and answer")
 check(acknowledge(f,id,delivery).ok and gate(f,gid) == nil, "correlated worker ACK reclaims the settled unassociated gate")
 check(w(f,id).reply_floor == delivery.reply_seq and w(f,id).replies[tostring(delivery.reply_seq)] == nil, "settled reply compacts to the current reply floor")
 check(api.state.rehydrate(api.clone(f.authority.registry)) ~= nil, "settled gate absence restores after reply compaction")
 for _, entry in w(f,id).workflow.thread do check(entry.gate_id ~= gid, "completed gate question/answer thread copies are removed") end
end
if section == nil or section == "cancel" then
 local f = api.fixture(); local id = f:accepted(false); local gid = ask(f,id)
 check(not f:apply("answer", { gate_id = gid, gate_revision = 2, choice_id = "safe", answer = "No" }).ok, "stale gate revision rejected")
 local wrong = f:event("answer", { gate_id = gid, gate_revision = 1, choice_id = "safe", answer = "No" }); wrong.origin.window_epoch = "other-window"
 check(not f.authority:apply(wrong).ok and gate(f,gid).phase == "pending", "different recipient origin cannot answer without explicit continuation")
 assert(f:apply("answer", { gate_id = gid, gate_revision = 1, choice_id = "safe", answer = "Proceed only with named work" }).ok)
 publish(f,id,gid)
 local delivery = api.clone(gate(f,gid).delivery)
 check(f:apply("cancel_gate", { gate_id = gid, gate_revision = 1 }).ok and gate(f,gid).phase == "cancelled", "owner cancellation is explicit")
 check(gate(f,gid).delivery_uncertain and gate(f,gid).delivery.bytes == delivery.bytes, "cancellation after possible delivery preserves immutable uncertainty")
 check(w(f,id).replies[tostring(delivery.reply_seq)] ~= nil, "unacknowledged cancelled decision cannot be evicted")
 check(acknowledge(f,id,delivery).ok and gate(f,gid) == nil, "late exact ACK settles cancellation and reclaims its final live gate")
 check(api.state.rehydrate(api.clone(f.authority.registry)) ~= nil, "settled cancellation absence restores")
 local g = api.fixture(); local wid = g:accepted(false); local pending = ask(g,wid)
 check(g:apply("cancel_gate", { gate_id = pending, gate_revision = 1 }).ok and gate(g,pending) == nil, "pre-answer cancellation leaves no completed gate or decision reply")
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
 check(f.authority:apply(api.clone(event)).code == "stale_revision" and f.memory.writes == writes, "captured observation replay cannot refresh its authority fence or write again")
 check(f.authority.registry.dispatch.command_cursors[f.origin.logical_session_id].seq == event.command_seq and w(f,id).workflow.observation_cursor.seq == 1, "observation keeps both durable intent replay barrier and bounded per-worker observation cursor")
 local gid; for key in f.authority.registry.dispatch.gates do gid = key end
 check(gate(f,gid).kind == "native_input", "native prompt has an owner remedy gate")
 check(f:apply("answer", { gate_id = gid, gate_revision = 1, choice_id = "recheck", answer = "yes" }).code == "recheck_only", "native remedy never creates a typed prompt answer")
 check(f:apply("reply", { worker_id = id }).code == "worker_not_sendable", "native waiting-input is never interrupted")
 local replies = w(f,id).reply_seq
 check(f:apply("recheck_gate", { gate_id = gid, gate_revision = 1 }).ok and w(f,id).reply_seq == replies, "owner resolved button only requests observation")
 clock.mono_ms += 100; clock.now_ms += 100; observation.native_state = "idle"; observation.observation_seq = 2
 check(f:apply("observe", observation).ok and gate(f,gid) == nil, "fresh safe native observation reclaims the resolved prompt gate")
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
 local function advance(f, clock, ms) clock.mono_ms += ms; clock.now_ms += ms; return f:tick() end
 -- Explicit 30-minute threshold: fresh, N-1, N, then no duplicate.
 local f, clock, aid = claimed(30)
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
 check(#g.options == 2 and g.options[1].id == "keep_waiting" and g.options[2].id == "open_recovery",
  "the stale_claim gate offers only keep_waiting and open_recovery decisions")
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
  local previous = said; local retry = s:apply("retry", { action_id = said }); assert(retry.ok)
  said = retry.action_id
  check(said ~= previous and s:action(previous) == nil, "pre-effect retry consumes the old issuance and allocates a fresh draft identity")
  check(s:action(said).stale_gate_id == first_gate and s:action(said).claim == nil, "a rechecked action keeps its stale-claim lineage while it waits for a claim")
  assert(s:apply("claim", { action_id = said, executor = s.origin.window_epoch }).ok)
  check(s:action(said).claim.stale_gate_id == first_gate and s:action(said).stale_gate_id == nil, "the recheck's fresh claim inherits the action's stale_claim gate")
  advance(s, sclock, 10 * MIN)
  check(#stale_gates(s) == 1, "fresh retry claim " .. round .. " retains the same live advisory lineage rather than opening a second stale_claim gate")
  assert(s:finish(said, "full", FULL).code == "backpressure")
 end
 check(api.state.rehydrate(api.clone(s.authority.registry)) ~= nil, "a rechecked claim lineage restores")
 local final_retry = s:apply("retry", { action_id = said }); assert(final_retry.ok); said = final_retry.action_id
 check(api.state.rehydrate(api.clone(s.authority.registry)) ~= nil, "a ready action carrying its stale-claim lineage restores")
 -- A restored 0.3.0 claim without claimed_at is rebased on the first tick, never gated on it.
 local r, rclock, raid = claimed(1)
 local legacy = api.clone(r.authority.registry); legacy.dispatch.actions[raid].claim.claimed_at = nil
 local restored = api.state.rehydrate(api.clone(legacy))
 check(restored ~= nil and restored.dispatch.actions[raid].claim.claimed_at == nil, "a 0.3.0 claim without claimed_at restores unstamped")
 rclock.mono_ms += 600 * MIN
 local first = api.dispatch.tick(restored, { kind = "workflow_tick", authority_namespace = restored.authority_namespace,
  expected_revision = restored.revision }, api.clone(rclock))
 check(first ~= nil and first.dispatch.actions[raid].claim.claimed_at.mono_ms == rclock.mono_ms and first.dispatch.actions[raid].claim.claimed_at.epoch == rclock.epoch
  and stale_in(first) == 0, "the first tick after restore rebases the unstamped claim and opens no gate")
 rclock.mono_ms += MIN - 1
 check(stale_in(api.dispatch.tick(first, { kind = "workflow_tick", authority_namespace = first.authority_namespace,
  expected_revision = first.revision }, api.clone(rclock)) or first) == 0, "the rebased claim is not stale one millisecond before N minutes")
 rclock.mono_ms += 1
 local due = api.dispatch.tick(first, { kind = "workflow_tick", authority_namespace = first.authority_namespace,
  expected_revision = first.revision }, api.clone(rclock))
 check(due ~= nil and stale_in(due) == 1, "the rebased claim gates N minutes after the rebase")
 -- A timestamped claim across a host restart (new epoch) is rebased, then gates N minutes later.
 local e, eclock, eaid = claimed(1)
 local old = api.clone(e:action(eaid).claim.claimed_at)
 eclock.epoch = "stale-host-restarted"; eclock.mono_ms = 5
 local reloaded = api.state.rehydrate(api.clone(e.authority.registry))
 local rebased = api.dispatch.tick(reloaded, { kind = "workflow_tick", authority_namespace = reloaded.authority_namespace,
  expected_revision = reloaded.revision }, api.clone(eclock))
 check(old.epoch == "stale-host" and rebased ~= nil and rebased.dispatch.actions[eaid].claim.claimed_at.epoch == "stale-host-restarted"
  and rebased.dispatch.actions[eaid].claim.claimed_at.mono_ms == 5 and stale_in(rebased) == 0, "a claim from the previous host epoch is rebased on the first tick, not gated")
 eclock.mono_ms += MIN - 1
 check(stale_in(api.dispatch.tick(rebased, { kind = "workflow_tick", authority_namespace = rebased.authority_namespace,
  expected_revision = rebased.revision }, api.clone(eclock)) or rebased) == 0, "the cross-epoch claim does not gate before N minutes on the new epoch")
 eclock.mono_ms += 1
 local later = api.dispatch.tick(rebased, { kind = "workflow_tick", authority_namespace = rebased.authority_namespace,
  expected_revision = rebased.revision }, api.clone(eclock))
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
  assert(f:tick())
  local lg = f.authority.registry.dispatch.gates[W.item(f, lid).gate_id]
  check(lg.answer == nil and W.item(f, lid).approval == nil and #W.item(f, lid).grants == 0 and W.effects(f) == before, "paused: landing auto-approval answers nothing and nothing executes on tick")
  local restored = assert(wapi.state.rehydrate(wapi.clone(f.authority.registry)))
  local twin = wapi.dispatch.tick(restored, { kind = "workflow_tick", authority_namespace = restored.authority_namespace,
   expected_revision = restored.revision }, { now_ms = 1, mono_ms = 1, epoch = "paused-twin" }) or restored
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
-- Current stores cannot claim legacy provenance by injecting an untagged historical answer.
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
 local original = tern.json.encode(stored)
 f.memory.value = stored; f.authority = wapi.host.new_authority(f.memory)
 local loaded = f.authority:load()
 check(not loaded.ok and loaded.code == "state_corrupt", "an untagged answer injected into the current schema is not an implicit legacy migration")
 check(tern.json.encode(f.memory.value) == original, "failed current-store validation never rewrites provenance or invents a historical execution")
 end
end
if section == nil or section == "rulings" then
 local f = api.fixture(); local id = f:accepted(false)
 assert(f:apply("associate_document", { worker_id = id, path = "/fixture/existing-plan.md", evidence = { existing = true } }).ok)
 local gid = ask(f,id)
 assert(f:apply("answer", { gate_id = gid, gate_revision = 1, choice_id = "safe", answer = "Use <literal> `safe` path only." }).ok)
 local o = gate(f,gid).ruling
 check(o ~= nil and o.path == "/fixture/existing-plan.md" and o.gate_revision == 1
  and o.marker == "orchplus-ruling:" .. f.authority.registry.authority_namespace .. ":" .. gid,
  "an explicit owner answer creates one existing-document obligation bound to original question revision")
 publish(f,id,gid); assert(acknowledge(f,id,api.clone(gate(f,gid).delivery)).ok)
 check(gate(f,gid) ~= nil and gate(f,gid).ruling ~= nil, "worker answer delivery cannot erase the pending document obligation")
 check(api.dispatch.close_problem(f.authority.registry, f.origin.logical_session_id) ~= nil, "document obligation blocks session close")
 local writer = { kind = "window", window_key = "0", conn = 17, since = 1234 }
 local before = "# Existing plan\n## Progress\nRoutine progress before fresh B0\n"
 local evidence = { existing = true, quiescent = true, identity_proven = true, same_machine = true, buffer_observed = true, disk_bytes = before }
 local prepared = f:apply("ruling_prepare", { gate_id = gid, gate_revision = gate(f,gid).revision, writer = writer, evidence = evidence })
 check(prepared.ok and prepared.edit ~= nil and gate(f,gid).ruling.state == "writing", "authority commits one writer intent before returning the targeted insertion")
 local second = api.clone(writer); second.conn = 18
 check(f:apply("ruling_prepare", { gate_id = gid, gate_revision = gate(f,gid).revision, writer = second, evidence = evidence }).code == "writer_unproved",
  "second window cannot issue or observe another writer's one-shot intent")
 local edit = prepared.edit
 local after = before:sub(1, edit.offset) .. edit.text .. before:sub(edit.offset + 1)
 evidence.buffer_bytes = after
 local unsaved = f:apply("ruling_observe", { gate_id = gid, gate_revision = gate(f,gid).revision, writer = writer, evidence = evidence })
 check(unsaved.code == "unsaved_edits" and gate(f,gid).ruling.intent ~= nil, "unsaved native buffer marker remains a live obligation; no forced save or duplicate append")
 check(api.state.rehydrate(api.clone(f.authority.registry)) ~= nil, "unsaved one-shot document obligation restores with exact original writer")
 evidence.disk_bytes = after
 check(f:apply("ruling_observe", { gate_id = gid, gate_revision = gate(f,gid).revision, writer = writer, evidence = evidence }).code == "ruling_recorded",
  "host durable B1 exact entry and unchanged non-rulings bytes settles the document obligation")
 check(gate(f,gid) == nil, "completed answer/effect/document obligations reclaim the gate without a settled answer log")
 for _, row in w(f,id).workflow.thread do check(row.gate_id ~= gid and row.kind ~= "answer", "completed ruling leaves no question/answer thread copy") end
 check(api.state.rehydrate(api.clone(f.authority.registry)) ~= nil, "settled ruling leaves no dangling gate or writer references")
end
if section == nil or section == "rulings_remote" then
 local f = api.fixture(); local id = f:accepted(false)
 assert(f:apply("associate_document", { worker_id = id, path = "/fixture/remote-existing.md", evidence = { existing = true } }).ok)
 local gid = ask(f,id)
 assert(f:apply("answer", { gate_id = gid, gate_revision = 1, choice_id = "safe", answer = "Keep the approved remote path." }).ok)
 publish(f,id,gid); assert(acknowledge(f,id,api.clone(gate(f,gid).delivery)).ok)
 local writer = { kind = "worker", worker_id = id, worker_generation = w(f,id).worker_generation }
 local before = "# Existing remote plan\n"
 local evidence = { existing = true, quiescent = true, identity_proven = true, buffer_observed = true, disk_bytes = before }
 local prepared = f:apply("ruling_prepare", { gate_id = gid, gate_revision = gate(f,gid).revision, writer = writer, evidence = evidence })
 assert(prepared.ok and prepared.edit)
 check(f:apply("ruling_remote", { gate_id = gid, gate_revision = gate(f,gid).revision, worker_id = id }).code == "ruling_queued",
  "existing provisioned coordinator-control worker receives the exact typed ruling request")
 local transport = gate(f,gid).ruling_delivery
 local retained = api.clone(w(f,id).replies[tostring(transport.reply_seq)])
 local reply = assert(api.codec.decode_reply(retained.bytes, w(f,id)))
 local keys = 0; for _ in reply.payload do keys += 1 end
 check(reply.kind == "record_ruling" and keys == 5 and reply.payload.path == "/fixture/remote-existing.md"
  and reply.payload.marker == gate(f,gid).ruling.marker and reply.payload.entry == gate(f,gid).ruling.entry
  and reply.payload.expected_document_sha256 == prepared.edit.expected_document_sha256
  and reply.payload.expected_non_rulings_sha256 == prepared.edit.expected_non_rulings_sha256,
  "remote transport carries only the canonical five-field targeted optimistic edit contract")
 check(f:apply("ruling_remote", { gate_id = gid, gate_revision = gate(f,gid).revision, worker_id = id }).code == "write_in_flight",
  "one-shot remote writer cannot receive a duplicate ruling command")
 for _ = 1, 16 do
  local live = w(f,id).replies[tostring(transport.reply_seq)]
  if live.part > #live.frames.chunks + 1 then break end
  local publication = f:apply("poll", { worker_id = id }); assert(publication.ok, publication.message)
  local operation = f:action(publication.action_id).request.op
  assert(operation == "mailbox_publish_ack" or operation == "mailbox_publish_reply" or operation == "mailbox_retire",
   "ruling delivery must drain only its real receipt/reply/compaction obligations")
  local result = f:finish(publication.action_id, if operation == "mailbox_retire" then "compacted" else "published")
  assert(result.ok, result.message)
 end
 assert(acknowledge(f,id,retained).ok)
 check(gate(f,gid).ruling ~= nil and gate(f,gid).ruling.intent.writer.worker_id == id,
  "worker transport receipt is not proof of a saved document; the original writer obligation remains")
 local edit = prepared.edit
 evidence.disk_bytes = before:sub(1,edit.offset) .. edit.text .. before:sub(edit.offset + 1)
 check(f:apply("ruling_observe", { gate_id = gid, gate_revision = gate(f,gid).revision, writer = writer, evidence = evidence }).code == "ruling_recorded"
  and gate(f,gid) == nil, "only durable exact readback settles remote ruling and reclaims the gate")
 check(api.state.rehydrate(api.clone(f.authority.registry)) ~= nil, "remote typed reply compaction and document settlement restore cleanly")
end
if section == nil or section == "rulings_reissue" then
 local f = api.fixture(); local id = f:accepted(false)
 assert(f:apply("associate_document", { worker_id = id, path = "/fixture/continued-existing.md", evidence = { existing = true } }).ok)
 local gid = ask(f,id)
 assert(f:apply("answer", { gate_id = gid, gate_revision = 1, choice_id = "safe", answer = "One exact document entry." }).ok)
 local old_writer = { kind = "window", window_key = "0", conn = 17, since = 1234 }
 local new_writer = { kind = "window", window_key = "0", conn = 18, since = 1235 }
 local evidence = { existing = true, quiescent = true, identity_proven = true, same_machine = true, buffer_observed = true, disk_bytes = "# Existing plan\n" }
 assert(f:apply("ruling_prepare", { gate_id = gid, gate_revision = gate(f,gid).revision, writer = old_writer, evidence = evidence }).edit)
 check(f:apply("ruling_reissue", { gate_id = gid, gate_revision = gate(f,gid).revision, writer = new_writer, evidence = evidence }).code == "write_in_flight",
  "a different current observer cannot treat the prior window's disappearance as nonexecution")
 evidence.writer_ended = true; evidence.no_write_can_complete = true; evidence.previous_writer = new_writer
 check(f:apply("ruling_reissue", { gate_id = gid, gate_revision = gate(f,gid).revision, writer = new_writer, evidence = evidence }).code == "writer_unproved"
  and gate(f,gid).ruling.intent.writer.conn == 17, "end evidence for the wrong incarnation cannot clear the old writer")
 evidence.previous_writer = old_writer; evidence.buffer_observed = false
 f:apply("ruling_reissue", { gate_id = gid, gate_revision = gate(f,gid).revision, writer = new_writer, evidence = evidence })
 check(gate(f,gid).ruling.intent ~= nil, "disk absence without a fresh live-buffer absence observation cannot reissue")
 evidence.buffer_observed = true
 local reissued = f:apply("ruling_reissue", { gate_id = gid, gate_revision = gate(f,gid).revision, writer = new_writer, evidence = evidence })
 check(reissued.ok and gate(f,gid).ruling.intent == nil and gate(f,gid).ruling.state == "pending",
  "new observer may clear only the exact positively ended prior intent with both absence proofs")
 evidence.previous_writer = nil; evidence.writer_ended = nil; evidence.no_write_can_complete = nil
 local replacement = f:apply("ruling_prepare", { gate_id = gid, gate_revision = gate(f,gid).revision, writer = new_writer, evidence = evidence })
 check(replacement.edit ~= nil and gate(f,gid).ruling.intent.writer.conn == 18,
  "fresh preparation separately commits the replacement writer before any new native append")
 check(f:apply("ruling_observe", { gate_id = gid, gate_revision = gate(f,gid).revision, writer = old_writer, evidence = evidence }).code == "writer_unproved",
  "late original writer cannot observe or settle the replacement intent")
 check(api.state.rehydrate(api.clone(f.authority.registry)) ~= nil, "replacement one-shot intent restores without an old writer history")
 local observer = { kind = "window", window_key = "0", conn = 19, since = 1236 }
 local edit, original = replacement.edit, evidence.disk_bytes
 evidence.disk_bytes = original:sub(1,edit.offset) .. edit.text .. original:sub(edit.offset + 1)
 evidence.buffer_bytes = evidence.disk_bytes
 check(f:apply("ruling_observe", { gate_id = gid, gate_revision = gate(f,gid).revision, writer = observer, evidence = evidence }).code == "writer_unproved",
  "a new observer cannot take over B1 merely because a marker appears")
 evidence.previous_writer = old_writer; evidence.writer_ended = true; evidence.no_write_can_complete = true
 check(f:apply("ruling_observe", { gate_id = gid, gate_revision = gate(f,gid).revision, writer = observer, evidence = evidence }).code == "writer_unproved",
  "B1 takeover end proof must name the actual latest owning incarnation")
 evidence.previous_writer = new_writer
 check(f:apply("ruling_observe", { gate_id = gid, gate_revision = gate(f,gid).revision, writer = observer, evidence = evidence }).code == "ruling_recorded"
  and gate(f,gid).ruling == nil, "positive exact writer end lets a fresh observer reconcile a save completed before the original B1 callback")
 publish(f,id,gid); assert(acknowledge(f,id,api.clone(gate(f,gid).delivery)).ok)
 check(gate(f,gid) == nil and api.state.rehydrate(api.clone(f.authority.registry)) ~= nil,
  "recovered exact saved entry settles without reissuing, duplicating or keeping a completed writer transcript")
end
if section == nil or section == "decision_subject" then
 local f = api.fixture(); local id = f:accepted(false); local gid = ask(f,id)
 local draft = f:event("answer", { gate_id = gid, gate_revision = gate(f,gid).revision, choice_id = "safe", answer = "Keep this literal draft." })
 local proof = draft.decision_context
 assert(f:apply("intake", { worker_id = id, bytes = f:report(id, w(f,id).accepted_seq + 1, "HEARTBEAT", { state = "working" }) }).ok)
 draft.command_seq = f.command_seq + 1; f.command_seq = draft.command_seq
 local answered = f.authority:apply(draft)
 check(answered.ok and draft.decision_context == proof and gate(f,gid).answer.answer == "Keep this literal draft.",
  "same-subject heartbeat/receipt bookkeeping does not discard the captured owner draft")
 local g = api.fixture(); local worker = g:accepted(false); local question = ask(g,worker)
 local stale = g:event("answer", { gate_id = question, gate_revision = gate(g,question).revision, choice_id = "safe", answer = "Old question." })
 assert(g:apply("pause").ok)
 stale.command_seq = g.command_seq + 1; g.command_seq = stale.command_seq
 local writes = g.memory.writes
 check(not g.authority:apply(stale).ok and g.memory.writes == writes and gate(g,question).phase == "pending",
  "a consequential pause/policy change rejects the old proof without recording an answer")
 local missing = g:event("answer", { gate_id = question, gate_revision = gate(g,question).revision, choice_id = "safe", answer = "No proof." })
 missing.decision_context = nil
 check(not g.authority:apply(missing).ok and g.memory.writes == writes, "missing proof is not a legacy authorization path")
 local exact = g:event("answer", { gate_id = question, gate_revision = gate(g,question).revision, choice_id = "safe", answer = "Current reviewed question." })
 local changed = api.clone(g.authority.registry)
 changed.dispatch.gates[question].question = "A genuinely different owner decision"
 g.authority.registry = changed; g.memory.value = api.clone(changed)
 check(not g.authority:apply(exact).ok and gate(g,question).phase == "pending", "same global revision cannot conceal changed question bytes")
end
-- Explicit forget (SKILLS-205): durable intent, recovery supersede, one-commit completion. No cancel exists.
if section == nil or section == "forget" then
 local W = load_test("workflow", "workflow-helpers", "helpers", api)
 local f = W.fixture({ reviewer_records = W.arr({ "codex" }) })
 local sid = f.origin.logical_session_id
 local b = W.builder(f, "builder", { source = W.PLAN, files = W.arr({ "src/feature.luau" }) })
 W.settle(f, b); assert(W.send(f, b, "CHECKPOINT", W.cp("cp-1", "rev-1")).ok)
 local cid = W.coordinator(f)
 assert(W.propose(f, cid, "report", W.worker(f, b).work_id).ok)
 local proposal = W.proposal_gate(f)
 local question = ask(f, b)
 check(proposal.phase == "pending" and gate(f, question).phase == "pending", "fixture holds a worker, a question gate and a pending proposal")
 local other = f.authority:apply(f:state_event("register_session", { orch_session_id = "other-session", name = "Other session" }))
 assert(other.ok, other.message)
 local other_before = tern.json.encode(f.authority.registry.sessions["other-session"])
 local codec = api.codec
 local function session() return f.authority.registry.sessions[sid] end
 local function binding(epoch) local o = api.clone(f.origin); o.window_epoch = epoch or o.window_epoch; return o end
 local function request_bytes(attempt, who, revision, boot)
  local o = who or binding()
  local r = { schema = 1, origin = "orchplus", op = "discard_session", request_id = "forget-" .. attempt, attempt_id = attempt,
   authority_namespace = f.authority.registry.authority_namespace, spawn_namespace = session().spawn_namespace, logical_session_id = sid,
   admission_seq = session().admission_seq, controller_pane = "9001", challenge = "forget-0000000000000000",
   dispatch_revision = revision or 7, spawn_boot = boot or "boot-1",
   owner = { owner_id = o.owner_id, owner_generation = o.owner_generation, host_pane_id = o.host_pane_id, alias_nonce = o.alias_nonce,
    window_key = o.window_key, native_session_id = o.native_session_id, window_host_id = o.window_host_id } }
  return tern.json.encode(r)
 end
 local function begin(kind, attempt, who, bytes)
  local o = who or binding()
  return f.authority:apply(f:state_event(kind, { attempt_id = attempt, request_bytes = bytes or request_bytes(attempt, o),
   preview = { spawn_boot = "boot-1", dispatch_revision = 7 },
   control_origin = { kind = "closing", binding = o, controller_pane = "9001", close_id = attempt } }))
 end
 local function closed_bytes(attempt, cursor)
  local request = codec.decode_forget_request(session().close.forget.request_bytes)
  return codec.encode_forget_response({ schema = 1, op = "discard_session", request_id = request.request_id, attempt_id = attempt, status = "closed",
   spawn_namespace = request.spawn_namespace, authority_namespace = request.authority_namespace, logical_session_id = sid, admission_seq = request.admission_seq,
   spawn_boot = "boot-1", payload = { admission_cursor = cursor } })
 end
 local foreign = binding(); foreign.alias_nonce = "someone-else"
 check(begin("begin_forget", "attempt-a", foreign).code == "owner_mismatch" and session().phase == "open", "only the exact current controller can begin; nothing changes otherwise")
 local bad_admission = tern.json.decode(request_bytes("attempt-a")); bad_admission.admission_seq += 5
 check(begin("begin_forget", "attempt-a", nil, tern.json.encode(bad_admission)).code == "invalid_event", "the persisted request must name this session's exact admission")
 check(begin("begin_forget", "attempt-a", nil, "{}").code == "invalid_event", "a request that is not the canonical discard schema is refused")
 local ordinary = f.authority:apply(f:state_event("begin_close", { close_id = "ordinary", control_origin = { kind = "closing", binding = binding(), controller_pane = "9001", close_id = "ordinary" } }))
 check(not ordinary.ok, "an ordinary close still refuses while obligations remain (waived only by Forget)")
 local started = begin("begin_forget", "attempt-a")
 local fenced = session()
 check(started.ok and fenced.phase == "closing" and fenced.close.forget.attempt_id == "attempt-a" and fenced.bridge_control == nil and fenced.close.peer_closed == false,
  "begin persists the intent, origin, attempt id and exact request bytes and fences the session")
 check(api.state.rehydrate(api.clone(f.authority.registry)) ~= nil, "the fenced, pending forget restores")
 check(begin("begin_forget", "attempt-b").code == "forget_pending", "a second begin is refused: recovery supersedes, nothing cancels")
 check(not f.authority:apply(f:state_event("confirm_close", { close_id = "attempt-a" })).ok, "ordinary close confirmation cannot complete a pending forget")
 local ctl = f:apply("bridge_control", { operation = "close_session", compatibility = api.clone(f.authority.registry.compatibility) })
 check(not ctl.ok and ctl.code == "forget_pending", "ordinary controls never run beside a pending forget")
 check(f.authority:apply(f:state_event("complete_forget", { attempt_id = "attempt-z", response_bytes = closed_bytes("attempt-a", 3) })).code == "forget_superseded", "only the pending attempt can complete")
 local refused_body = tern.json.decode(closed_bytes("attempt-a", 3):sub(#codec.FORGET.prefix + 1)); refused_body.status = "refused"; refused_body.payload = nil
 refused_body.error = { code = "blocked", message = "x" }
 local unproven = f.authority:apply(f:state_event("complete_forget", { attempt_id = "attempt-a", response_bytes = codec.FORGET.prefix .. tern.json.encode(refused_body) }))
 check(unproven.code == "forget_unproven" and session() ~= nil, "only SPAWN's exact closed result completes forgetting")
 -- A crash before SPAWN processed it: the window reloads with a new epoch and recovers from the current origin.
 local reloaded = binding("reloaded-window")
 check(begin("supersede_forget", "attempt-a", reloaded).code == "forget_not_pending", "recovery must be a different attempt")
 local foreign_recovery = api.clone(reloaded); foreign_recovery.alias_nonce = "someone-else"
 check(begin("supersede_forget", "attempt-b", foreign_recovery).code == "owner_mismatch", "recovery from a different owner identity is refused")
 local recovered = begin("supersede_forget", "attempt-b", reloaded)
 check(recovered.ok and session().close.forget.attempt_id == "attempt-b" and session().close.control_origin.binding.window_epoch == "reloaded-window"
  and f.authority.registry.dispatch.command_cursors[sid].origin.window_epoch == "reloaded-window",
  "recovery atomically replaces the pending request bytes and rebinds the command cursor to the verified controller")
 check(f.authority:apply(f:state_event("complete_forget", { attempt_id = "attempt-a", response_bytes = closed_bytes("attempt-b", 3) })).code == "forget_superseded",
  "a superseded attempt can never complete locally")
 local next_before = f.authority.registry.next_admission_seq
 local done = f.authority:apply(f:state_event("complete_forget", { attempt_id = "attempt-b", response_bytes = closed_bytes("attempt-b", next_before + 40) }))
 local registry = f.authority.registry
 check(done.ok and registry.sessions[sid] == nil, "SPAWN's closed result completes forgetting in one commit")
 local d = registry.dispatch
 local left = 0
 for _, field in { "workers", "gates", "reviews", "plans", "intakes", "chains", "projects" } do
  for _, row in d[field] or {} do if row.logical_session_id == sid then left += 1 end end
 end
 for _, a in d.actions do if a.request.origin_binding.logical_session_id == sid then left += 1 end end
 check(left == 0 and d.policies[sid] == nil and d.catalogs[sid] == nil and d.command_cursors[sid] == nil, "no worker, gate, proposal, action, setting or cursor of the session remains")
 check(registry.next_admission_seq == next_before + 41, "next_admission_seq advances above SPAWN's returned cursor so the admission is never reissued")
 check(registry.forgotten ~= nil and registry.forgotten.name == "Dispatch fixture" and registry.forgotten.revision == registry.revision, "an installation-level completion notice is persisted in the same commit")
 check(tern.json.encode(registry.sessions["other-session"]) == other_before, "another session is untouched byte for byte")
 check(api.state.rehydrate(api.clone(registry)) ~= nil, "the registry restores with no dangling reference and a valid notice")
 -- A session SPAWN never admitted holds nothing there: one local commit.
 local fresh = f.authority:apply(f:state_event("register_session", { orch_session_id = "local-session", name = "Never admitted" }))
 assert(fresh.ok, fresh.message)
 local admitted = f.authority:apply(f:state_event("admit_controller", { orch_session_id = "local-session", pane_binding = { host_pane_id = "77", alias_nonce = "local-alias" } }))
 assert(admitted.ok, admitted.message)
 local lo = { logical_session_id = "local-session", owner_id = admitted.owner_id, owner_generation = admitted.generation, host_pane_id = "77", alias_nonce = "local-alias",
  window_key = "", window_epoch = "w", native_session_id = "7", window_host_id = "local" }
 local local_done = f.authority:apply(f:state_event("begin_forget", { orch_session_id = "local-session", attempt_id = "attempt-l",
  control_origin = { kind = "closing", binding = lo, controller_pane = "9001", close_id = "attempt-l" } }))
 check(local_done.ok and f.authority.registry.sessions["local-session"] == nil and f.authority.registry.forgotten.name == "Never admitted",
  "a session never admitted to SPAWN is forgotten locally in one commit")
end
assert(section == nil or table.find({ "lifecycle", "cancel", "native", "capacity", "settled_history", "stale_claim", "autonomy", "rulings", "rulings_remote", "rulings_reissue", "decision_subject", "forget" }, section), "unknown gates section")
return "gates/" .. tostring(section or "all") .. ": " .. tostring(checks) .. " checks passed"
