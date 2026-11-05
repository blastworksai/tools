-- Actual reducer/sole-host persistence cases. Run each section in a bounded host callback.
local root, section = ...
local api = assert(loadstring(tern.fs.read(root .. "/tests/dispatch.luau"), "dispatch-fixture"))(root, "fixture")
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
assert(section == nil or table.find({ "lifecycle", "cancel", "native", "capacity", "settled_history" }, section), "unknown gates section")
return "gates/" .. tostring(section or "all") .. ": " .. tostring(checks) .. " checks passed"
