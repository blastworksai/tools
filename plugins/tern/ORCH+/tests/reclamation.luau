-- Real HOST blocks and canonical reducers; no production KV, native effects or copied host logic.
local root, section = ...
assert(section == nil or table.find({ "host_retirement", "host_stale_result", "host_withdrawal", "project_history", "host_forget", "host_forget_relay", "forget_window" }, section), "unknown reclamation section")
local runtime, environment = tern, getfenv()
local fixture_chunk = assert(loadstring(runtime.fs.read(root .. "/tests/dispatch.luau"), "reclamation-fixture"))
setfenv(fixture_chunk, setmetatable({}, { __index = environment }))
local shared = fixture_chunk(root, "fixture")
local clone, codec = shared.clone, shared.codec
local checks = 0
local function check(ok, message) assert(ok, message); checks += 1 end
local function node(tree, key)
	if type(tree) ~= "table" then return nil end
	if tree.p and tree.p.key == key then return tree end
	for _, child in tree.c or {} do local found = node(child, key); if found then return found end end
	return nil
end
local function fixture(options)
	local f = shared.fixture()
	local fake, definition = table.clone(runtime), nil
	local contexts, views, modules = {}, {}, {}
	local channel_files, channel_dirs = {}, {}
	fake.plugin = table.clone(runtime.plugin); fake.plugin.data = if options and options.relay then "/fixture/plugins/orchplus" else "/fixture/plugins/orchplus-reclamation"
	fake.fs = {
		exists = function(path) return channel_files[path] ~= nil or channel_dirs[path] == true end,
		mkdir = function(path) channel_dirs[path] = true end,
		read = function(path, maximum)
			local bytes = assert(channel_files[path], "missing fixture file")
			assert(type(maximum) == "number" and #bytes <= maximum, "carrier reads are bounded")
			return bytes
		end,
		write = function(path, bytes) channel_files[path] = bytes end,
		remove = function(path) channel_files[path] = nil; channel_dirs[path] = nil end,
		list = function() error("carrier must not list directories") end,
	}
	fake.pane = { list = function() return {
		{ pane = 42, program = "orchplus.orchestrator", title = "Reclamation owner" },
		{ pane = 43, program = "orchplus.orchestrator", title = "Reclamation observer" },
		{ pane = 44, program = "orchplus.orchestrator", title = "Reclamation creation observer" },
	} end }
	fake.kv = { get = f.memory.get, set = function(key, value)
		f.memory.set(key, value)
		if key == "authority_state" then f.authority.registry = f.memory.value end
	end }
	fake.block = { define = function(id, value)
		if id == "orchestrator" then
			assert(definition == nil, "orchestrator block must be defined once")
			definition = value
		end
	end }
	fake.on = function() end
	fake.timer = function(ms, callback)
		if ms == 100 and options and options.relay then f.relay_tick = callback end
		return { cancel = function() end }
	end
	f.fake = fake
	local function load(name, base)
		name = (base or "") .. name:gsub("^%./", "")
		if modules[name] then return modules[name] end
		local chunk = assert(loadstring(runtime.fs.read(root .. "/" .. name .. ".luau"), name))
		setfenv(chunk, setmetatable({ tern = fake, require = function(path) return load(path, name:match("^(.*/)")) end }, { __index = environment }))
		modules[name] = chunk(); return modules[name]
	end
	load("host")
	f.fake_load = function(name) return load(name) end
	assert(definition and type(definition.init) == "function" and type(definition.view) == "function"
		and type(definition.event) == "function", "actual orchplus.orchestrator lifecycle is required")
	for _, pane in { 42, 43, 44 } do
		contexts[pane] = { pane = pane, render = function() if views[pane] then definition.view(views[pane], contexts[pane]) end end }
		views[pane] = definition.init(contexts[pane], {}, { pane = pane, alias_nonce = if pane == 42 then f.origin.alias_nonce else "other-view",
			orch_session_id = f.origin.logical_session_id, established = true })
	end
	local proxy = { registry = f.memory.value }
	function proxy:apply(input)
		local view = views[42]
		local response
		if input.kind == "dispatch" then
			local effect = table.find({ "claim", "result", "spawn_claimed", "lost" }, input.command) ~= nil
			local control = table.find({ "bridge_control", "bridge_result", "bridge_observe" }, input.command) ~= nil
			definition.event(view, { ev = "action", act = if effect then "dispatch-command" else "dispatch-operator-command", value = runtime.json.encode(input) }, contexts[42])
			response = if control then view.dispatch_control_result elseif effect then view.dispatch_result else view.dispatch_command_result
		else
			definition.event(view, { ev = "action", act = "authority-command", value = runtime.json.encode({ source_nonce = f.origin.alias_nonce,
				origin = f.origin, event = input }) }, contexts[42])
			response = view.dispatch_background_result
		end
		assert(response and response.request_id == input.request_id, "actual HOST callback must return this request's correlated result, not an earlier operator receipt: " .. tostring(input.kind))
		return response
	end
	f.authority = proxy
	-- Reload makes the owner uncertain; the actual owner command establishes this consumer.
	local continued = f:apply("continue_controller", { expected_revision = f.authority.registry.revision, operator_verified = true })
	assert(continued.ok, runtime.json.encode(continued))
	assert(f:control("reconcile_session").ok)
	function f:attest_stopped()
		local view, cx = views[42], contexts[42]
		definition.event(view, { ev = "action", act = "assistance-result", value = runtime.json.encode({
			source_nonce = self.origin.alias_nonce, orch_session_id = self.origin.logical_session_id,
			authority_namespace = self.authority.registry.authority_namespace, expected_revision = self.authority.registry.revision,
			target = "controller", owner_id = self.origin.owner_id, generation = self.origin.owner_generation,
			observation = "unavailable", message = "Synthetic owner stopped; no native executor was created",
		}) }, cx)
		-- Stopped-owner attestation is an explicit recovery operation, never an ordinary admission control.
		for _, kind in { "advanced-toggle", "attest", "attest-confirm", "advanced-toggle" } do
			definition.view(view, cx)
			local key
			for candidate, entry in view.actions do
				if entry.kind == kind then key = candidate; break end
			end
			assert(key, "missing actual HOST control " .. kind .. ": " .. tostring(view.notice))
			definition.event(view, { ev = "action", act = "control", value = key }, cx)
		end
		local owner = self.authority.registry.sessions[self.origin.logical_session_id].controller
		assert(owner.owner_active == false and owner.pending_executors == 0
			and owner.pending_executor_evidence == "operator_attested", tostring(view.notice))
	end
	function f:scope(action_id, pane) return node(definition.view(views[pane or 42], contexts[pane or 42]).main, "dispatch-action-" .. action_id) end
	function f:retained()
		local count = 0
		for _, view in views do for _ in view.scoped_results or {} do count += 1 end end
		return count
	end
	function f:deliver(action_id, bytes, envelope)
		local a = assert(self:action(action_id))
		local event = { ev = "action", act = "dispatch-result/" .. a.claim.grant_id .. "/" .. self.origin.window_epoch,
			value = envelope or runtime.json.encode({ authority_namespace = self.authority.registry.authority_namespace,
				expected_revision = self.authority.registry.revision, response_bytes = bytes }) }
		definition.event(views[42], event, contexts[42])
		return clone(views[42].dispatch_result), event
	end
	function f:catalog_delivery()
		local queued = self:apply("catalog"); assert(queued.ok, queued.message)
		local claimed = self:apply("claim", { action_id = queued.action_id, executor = self.origin.window_epoch }); assert(claimed.ok, claimed.message)
		local request = self:action(queued.action_id).request
		local bytes = shared.frame(request, "rejected", nil, { code = "storage_error", message = "Retained fixture failure; no native effect" })
		return queued.action_id, bytes
	end
	function f:redraw() definition.view(views[43], contexts[43]) end
	f.views = views
	function f:saved(pane) return definition.save(views[pane]) end
	function f:render(pane) return definition.view(views[pane], contexts[pane]) end
	function f:host_event(pane, act, value) definition.event(views[pane], { ev = "action", act = act, value = runtime.json.encode(value) }, contexts[pane]) end
	function f:create(pane, name)
		definition.event(views[pane], { ev = "action", act = "orchestration-create", value = runtime.json.encode({
			source_nonce = views[pane].alias_nonce, request_id = "create-" .. name, name = name,
			authority_namespace = self.authority.registry.authority_namespace, expected_revision = self.authority.registry.revision,
		}) }, contexts[pane])
		return assert(views[pane].orchestration_result)
	end
	function f:release(input)
		input.source_nonce = self.origin.alias_nonce
		definition.event(views[42], { ev = "action", act = "dispatch-release-scope", value = runtime.json.encode(input) }, contexts[42])
	end
	return f
end
if section == nil or section == "host_stale_result" then
	local f = fixture()
	local id, bytes = f:catalog_delivery()
	local original = runtime.json.encode({ authority_namespace = f.authority.registry.authority_namespace,
		expected_revision = f.authority.registry.revision, response_bytes = bytes })
	assert(f:apply("pause").ok)
	local writes = f.memory.writes
	local refused, event = f:deliver(id, bytes, original)
	check(not refused.ok and refused.code == "stale_revision" and f.memory.writes == writes and f:action(id).phase == "claimed",
		"actual HOST positively refuses the captured stale result without consuming its grant")
	local replay = f:deliver(id, bytes, original)
	check(replay.request_id == refused.request_id and not replay.ok and event.value == original and f.memory.writes == writes,
		"exact immutable replay preserves refusal identity and writes nothing")
	local committed = f:deliver(id, bytes)
	check(committed.ok and committed.request_id ~= refused.request_id and f:action(id) == nil and f:scope(id) ~= nil,
		"a distinct current observation of the same retained bytes commits under a distinct HOST request identity")
end
if section == nil or section == "host_retirement" then
	local f = fixture()
	local id, bytes = f:catalog_delivery(); assert(f:deliver(id, bytes).ok)
	local writes = f.memory.writes
	for _ = 1, 12 do f:redraw() end
	check(f:scope(id) ~= nil and f.memory.writes == writes, "lost-ACK receipt-only action survives unrelated redraws without durable history")
	assert(f:apply("pause").ok); assert(f:apply("resume").ok)
	check(f:scope(id) ~= nil, "ordinary same-consumer commands never retire a delivery receipt")
	local stale = f:event("continue_controller", { operator_verified = true })
	stale.origin = clone(f.origin); stale.origin.window_epoch = "refused-consumer"
	assert(f:apply("pause").ok)
	check(f.authority:apply(stale).code == "stale_revision" and f:scope(id) ~= nil,
		"a refused continuation is not retirement proof and cannot erase a live lost-ACK receipt")
	assert(f:apply("continue_controller", { expected_revision = f.authority.registry.revision, operator_verified = true }).ok)
	check(f:scope(id) ~= nil, "continuing the same native incarnation does not invent consumer retirement")
	f.origin.window_epoch = "continued-consumer"
	assert(f:apply("continue_controller", { expected_revision = f.authority.registry.revision, operator_verified = true }).ok)
	f:redraw()
	check(f:scope(id) == nil and f:retained() == 0, "actual HOST removes receipt-only action nodes and current bookkeeping after consumer continuation, including other-view redraws")
	local closed = fixture()
	local closed_id, closed_bytes = closed:catalog_delivery(); assert(closed:deliver(closed_id, closed_bytes).ok)
	local sid, close_id = closed.origin.logical_session_id, "fixture-confirmed-close"
	local survivor = closed:create(44, "Surviving creation"); assert(survivor.ok)
	local survivor_session = runtime.json.encode(closed.authority.registry.sessions[survivor.orch_session_id])
	local creation = { ok = true, orch_session_id = sid, request_id = "closed-creation" }
	closed.views[42].orchestration_result = clone(creation)
	closed.views[43].orchestration_result = clone(creation)
	closed.views[43].orch_session_id = survivor.orch_session_id
	local function begin_close()
		return closed.authority:apply(closed:state_event("begin_close", { close_id = close_id,
			control_origin = { kind = "closing", binding = clone(closed.origin), controller_pane = "9001", close_id = close_id } }))
	end
	local unconfirmed = begin_close()
	check(not unconfirmed.ok and unconfirmed.code == "session_busy" and closed:scope(closed_id) ~= nil,
		"unconfirmed restored executor evidence cannot close a session or retire its receipt")
	closed:attest_stopped()
	local begun = begin_close(); assert(begun.ok, runtime.json.encode(begun))
	check(closed:scope(closed_id) ~= nil, "begin_close is not consumer retirement or proof of confirmed closure")
	check(closed.views[42].orchestration_result ~= nil and closed.views[43].orchestration_result ~= nil,
		"pending close preserves creation outcomes in selected and elsewhere-selected views")
	assert(closed.authority:apply(closed:state_event("release_controller", { expected_owner_id = closed.origin.owner_id,
		expected_generation = closed.origin.owner_generation })).ok)
	assert(closed:control("close_session").ok)
	assert(closed.authority:apply(closed:state_event("confirm_close", { close_id = close_id })).ok)
	check(closed.authority.registry.sessions[sid] == nil and closed:scope(closed_id) == nil and closed:retained() == 0,
		"actual HOST confirmed close removes receipt-only action nodes without a durable tombstone")
	check(closed.views[42].orchestration_result == nil and closed.views[43].orchestration_result == nil,
		"confirmed removal clears only that session's creation outcome across all view selections")
	check(closed.views[44].orchestration_result == survivor
		and runtime.json.encode(closed.authority.registry.sessions[survivor.orch_session_id]) == survivor_session,
		"confirmed removal preserves unrelated creation results and current session ownership")
end
if section == nil or section == "host_forget" then
	local f = fixture()
	local id, bytes = f:catalog_delivery(); assert(f:deliver(id, bytes).ok)
	local sid = f.origin.logical_session_id
	local survivor = f:create(44, "Surviving creation"); assert(survivor.ok)
	local survivor_session = runtime.json.encode(f.authority.registry.sessions[survivor.orch_session_id])
	f.views[43].orch_session_id = sid
	f.views[42].relay_notice = "stale relay notice"
	check(f.views[42].dispatch_command_result ~= nil and f:saved(42).orch_session_id == sid and f:saved(43).orch_session_id == sid,
		"before forgetting, saved window data names the session and its last command result")
	local codec = shared.codec
	local function bound(epoch)
		local o = clone(f.origin); o.window_epoch = epoch or o.window_epoch; return o
	end
	local function request_bytes(attempt, o)
		local session = f.authority.registry.sessions[sid]
		return runtime.json.encode({ schema = 1, origin = "orchplus", op = "discard_session", request_id = "forget-" .. attempt, attempt_id = attempt,
			authority_namespace = f.authority.registry.authority_namespace, spawn_namespace = session.spawn_namespace, logical_session_id = sid,
			admission_seq = session.admission_seq, controller_pane = "9001", challenge = "forget-0000000000000000", dispatch_revision = 7, spawn_boot = "boot-1",
			owner = { owner_id = o.owner_id, owner_generation = o.owner_generation, host_pane_id = o.host_pane_id, alias_nonce = o.alias_nonce,
				window_key = o.window_key, native_session_id = o.native_session_id, window_host_id = o.window_host_id } })
	end
	local function forget(kind, attempt, o)
		return f.authority:apply(f:state_event(kind, { attempt_id = attempt, request_bytes = request_bytes(attempt, o), preview = { spawn_boot = "boot-1", dispatch_revision = 7 },
			control_origin = { kind = "closing", binding = o, controller_pane = "9001", close_id = attempt } }))
	end
	local ordinary = f.authority:apply(f:state_event("begin_close", { close_id = "ordinary",
		control_origin = { kind = "closing", binding = clone(f.origin), controller_pane = "9001", close_id = "ordinary" } }))
	check(not ordinary.ok and ordinary.code == "session_busy", "an ordinary close refuses unconfirmed executor evidence")
	-- Window-side progress reaches the actual host view as a closed set of stages and bounded rows.
	local card = { { kind = "pane", agent = "claude-a", host = "7", pane = "55" }, { kind = "unobservable", agent = "omp-b", host = "9" }, { kind = "shared_pane", agent = "x", host = "7", pane = "66" } }
	f:host_event(42, "forget-state", { stage = "blocked", blockers = card, pending = false })
	check(f.views[42].forget ~= nil and f.views[42].forget.stage == "blocked" and #f.views[42].forget.blockers == 3, "the host keeps the blocker rows of the preview")
	f:host_event(42, "forget-state", { stage = "exploit", blockers = card })
	check(f.views[42].forget.stage == "blocked", "an unknown stage is ignored")
	local function texts(tree, out)
		out = out or {}
		if type(tree) ~= "table" then return out end
		if tree.p and tree.p.spans and not tree.p.hidden then for _, span in tree.p.spans do if type(span) == "table" and span.t then table.insert(out, span.t) end end end
		for _, child in tree.c or {} do texts(child, out) end
		return out
	end
	local shown = table.concat(texts(f:render(42).main), "\n")
	for _, expected in { "Cannot forget yet. Review the blockers below.", "Close these panes using Tern, then check again:", "claude-a · pane 55 · 7",
		"omp-b · cannot be checked on 9", "x · pane 66 on 7 is associated with another orchestration. Do not close it for this reset." } do
		check(shown:find(expected, 1, true) ~= nil, "the blocker card shows: " .. expected)
	end
	local close_at, shared_at = shown:find("Close these panes using Tern", 1, true), shown:find("associated with another orchestration", 1, true)
	check(close_at ~= nil and shared_at ~= nil and select(1, shown:find("claude-a · pane 55", 1, true)) > close_at and shared_at > close_at
		and shown:find("Close these panes", shared_at, true) == nil, "only the exclusive pane group carries the close-through-Tern instruction")
	local begun = forget("begin_forget", "attempt-a", bound()); assert(begun.ok, runtime.json.encode(begun))
	check(f.authority.registry.sessions[sid].close.forget.attempt_id == "attempt-a", "the owner's confirmed forget fences the session despite unconfirmed executor evidence")
	f:host_event(42, "forget-state", { stage = "idle" })
	local pending_tree = f:render(42).main
	local pending_text = table.concat(texts(pending_tree), "\n")
	check(pending_text:find("Forgetting is pending. This orchestration remains fenced. Resolve the listed blockers, then continue.", 1, true) ~= nil
		and runtime.json.encode(pending_tree):find("Continue forgetting", 1, true) ~= nil, "a persisted forget shows the pending notice and Continue forgetting even after a reload (no window state)")
	-- Crash/reload after fencing: the window epoch is new; recovery supersedes the pending bytes from the current origin.
	f.origin.window_epoch = "reloaded-window"
	local recovered = forget("supersede_forget", "attempt-b", bound()); assert(recovered.ok, runtime.json.encode(recovered))
	check(f.authority.registry.sessions[sid].close.control_origin.binding.window_epoch == "reloaded-window", "recovery is accepted through the actual host from the reloaded window's origin")
	local session = f.authority.registry.sessions[sid]
	local request = codec.decode_forget_request(session.close.forget.request_bytes)
	local closed = codec.encode_forget_response({ schema = 1, op = "discard_session", request_id = request.request_id, attempt_id = "attempt-b", status = "closed",
		spawn_namespace = request.spawn_namespace, authority_namespace = request.authority_namespace, logical_session_id = sid, admission_seq = request.admission_seq,
		spawn_boot = "boot-1", payload = { admission_cursor = 9 } })
	local before_next = f.authority.registry.next_admission_seq
	local done = f.authority:apply(f:state_event("complete_forget", { attempt_id = "attempt-b", response_bytes = closed }))
	assert(done.ok, runtime.json.encode(done))
	check(f.authority.registry.sessions[sid] == nil and f.authority.registry.next_admission_seq == math.max(before_next, 10), "host authority no longer holds the session and its admission is never reissued")
	for _, pane in { 42, 43 } do
		local saved = f:saved(pane)
		check(saved.orch_session_id == nil and saved.dispatch_command_result == nil and saved.relay_notice == nil
			and saved.notice == "Orchestration forgotten. Mailbox files were kept. You can create a new orchestration.", "saved window data of every view on the forgotten session keeps no session, result or relay trace, and shows the completion notice")
		check(f.views[pane].scoped_results == nil and f.views[pane].orchestration_result == nil and f.views[pane].forget == nil, "live view results of the session are cleared too")
	end
	check(f:saved(44).orch_session_id ~= sid and runtime.json.encode(f.authority.registry.sessions[survivor.orch_session_id]) == survivor_session,
		"an unrelated session and its view are untouched")
	-- Forget a second orchestration (never admitted to SPAWN: one local commit). The notice now names B, not A.
	local sid_b = survivor.orch_session_id
	local b_origin = { logical_session_id = sid_b, owner_id = survivor.owner_id, owner_generation = survivor.generation, host_pane_id = "44",
		alias_nonce = f.views[44].alias_nonce, window_key = "", window_epoch = "b", native_session_id = "7", window_host_id = "local" }
	f:host_event(44, "authority-command", { source_nonce = f.views[44].alias_nonce, origin = b_origin, event = { kind = "begin_forget", request_id = "b-forget",
		orch_session_id = sid_b, authority_namespace = f.authority.registry.authority_namespace, expected_revision = f.authority.registry.revision,
		attempt_id = "attempt-b2", control_origin = { kind = "closing", binding = b_origin, controller_pane = "9001", close_id = "attempt-b2" } } })
	check(f.authority.registry.sessions[sid_b] == nil and f.authority.registry.forgotten.orch_session_id == sid_b, "the second orchestration is forgotten and the notice names it")
	-- A stale view of the FIRST forgotten session (A) is reopened: it is normalized against the loaded authority too.
	f.views[43].orch_session_id = sid
	f.views[43].scoped_results = { stale = { result = {} } }
	check(f:saved(43).orch_session_id == nil, "saved window data never carries a session the authority lacks")
	f:render(43)
	check(f.views[43].orch_session_id == sid, "the closed-view alias keeps the id through a short grace")
	f.views[43].absent_since = -1000000000
	f:render(43)
	check(f.views[43].orch_session_id == nil and f.views[43].scoped_results == nil, "after the grace every absent id is cleared with its scoped results, not only the latest forgotten one")
end
if section == nil or section == "host_forget_relay" then
	-- The REAL host relay and carrier: capability, preview and discard travel on their own protocol end to end.
	local f = fixture({ relay = true })
	local Channel = f.fake_load("channel/channel")
	local peer = assert(Channel.open({ plugin_id = "spawn", plugin_data = "/fixture/plugins/spawn", incarnation = "spawn-fixture-boot",
		fs = f.fake.fs, json = f.fake.json, base64 = f.fake.base64 }))
	local metadata = f.views[42].spawn_relay
	local function event(act, bytes, peer_boot)
		f:host_event(42, "spawn_relay", { schema = 1, source_nonce = f.views[42].alias_nonce, relay_endpoint = metadata.relay_endpoint, relay_boot = metadata.relay_boot,
			lane_id = "forget", peer_boot = peer_boot, act = act, bytes = bytes })
	end
	local function pump() for _ = 1, 4 do f.relay_tick() end end
	event("bind", runtime.json.encode(f.origin))
	local bind = assert(peer.receive(4)[1], "the host forwards the bind"); assert(peer.ack(bind))
	assert(peer.send({ peer = "orchplus", route = "spawn.source", binding = metadata.relay_endpoint .. ":forget", id = "r-1",
		body = runtime.json.encode({ schema = 1, relay_endpoint = metadata.relay_endpoint, relay_boot = metadata.relay_boot, lane_id = "forget",
			host_pane_id = "42", source_nonce = f.views[42].alias_nonce, peer_boot = "spawn-fixture-boot", bind_request = { id = bind.id, incarnation = bind.incarnation } }) }))
	pump()
	check(metadata.lanes[1] ~= nil and metadata.lanes[1].peer_boot == "spawn-fixture-boot", "the lane is bound to the real controller identity")
	local codec = shared.codec
	local sid = f.origin.logical_session_id
	local session = f.authority.registry.sessions[sid]
	local o = f.origin
	local function request(op, extra, owner_patch)
		local r = { schema = 1, origin = "orchplus", op = op, request_id = "relay-" .. op, attempt_id = "relay-attempt", authority_namespace = f.authority.registry.authority_namespace,
			spawn_namespace = session.spawn_namespace, logical_session_id = sid, admission_seq = session.admission_seq, controller_pane = "42",
			owner = { owner_id = o.owner_id, owner_generation = o.owner_generation, host_pane_id = o.host_pane_id, alias_nonce = o.alias_nonce,
				window_key = o.window_key, native_session_id = o.native_session_id, window_host_id = o.window_host_id } }
		for k, v in extra or {} do r[k] = v end
		for k, v in owner_patch or {} do r.owner[k] = v end
		return r
	end
	local serial = 1
	local function roundtrip(op, extra)
		local r = request(op, extra)
		event(op, runtime.json.encode(r), "spawn-fixture-boot")
		local forwarded = peer.receive(4)
		check(#forwarded == 1 and forwarded[1].route == "spawn.request" and forwarded[1].body == runtime.json.encode(r)
			and forwarded[1].binding:find(":" .. op .. ":", 1, true) ~= nil, "the host forwards " .. op .. " bytes unchanged on the carrier")
		assert(peer.ack(forwarded[1]))
		local body = { schema = 1, op = op, request_id = r.request_id, attempt_id = r.attempt_id, spawn_namespace = r.spawn_namespace, authority_namespace = r.authority_namespace,
			logical_session_id = sid, admission_seq = r.admission_seq, spawn_boot = "boot-1" }
		if op == "discard_capability" then body.status, body.payload = "capable", { challenge = "forget-0000000000000000" }
		elseif op == "discard_preview" then body.status, body.payload = "clean", { dispatch_revision = 4, inventory = { requests = 0, workers = 0, generations = 0 } }
		else body.status, body.payload = "closed", { admission_cursor = 6 } end
		local bytes = assert(codec.encode_forget_response(body))
		serial += 1
		local receipt = assert(peer.send({ peer = "orchplus", route = "spawn.response", binding = metadata.relay_endpoint .. ":forget", id = "r-" .. serial, body = bytes }))
		pump()
		check(f.views[42].spawn_relay_frames.forget.response == bytes and not metadata.held, "the host publishes the " .. op .. " response unchanged and is not held")
		check(codec.decode_forget_response(f.views[42].spawn_relay_frames.forget.response, r) ~= nil, "the window can decode it against its own request")
		event("ack", runtime.json.encode({ route = "spawn.response", id = "r-" .. serial, incarnation = "spawn-fixture-boot" }), "spawn-fixture-boot")
		for _ = 1, 4 do peer.settle(4); pump() end
		check(not metadata.held, "acknowledging a forget response never raises an unresolved effect")
	end
	roundtrip("discard_capability")
	roundtrip("discard_preview", { challenge = "forget-0000000000000000" })
	roundtrip("discard_session", { challenge = "forget-0000000000000000", dispatch_revision = 4, spawn_boot = "boot-1" })
	local forged = request("discard_capability", nil, { alias_nonce = "someone-else" })
	event("discard_capability", runtime.json.encode(forged), "spawn-fixture-boot")
	check(#peer.receive(4) == 0, "a request whose owner is not the lane's bound source is never forwarded")
	local legacy = request("discard_capability"); legacy.schema = 2
	event("discard_capability", runtime.json.encode(legacy), "spawn-fixture-boot")
	check(#peer.receive(4) == 0, "a malformed request is never forwarded")
end
if section == nil or section == "forget_window" then
	-- The window module itself, driven with a scripted SPAWN: recovery after a reload (new epoch) and an absent session.
	local codec = shared.codec
	local modules = {}
	local function load_module(name)
		if modules[name] then return modules[name] end
		local chunk = assert(loadstring(runtime.fs.read(root .. "/" .. name .. ".luau"), name))
		setfenv(chunk, setmetatable({ require = function(path) return load_module((path:gsub("^%./", ""))) end }, { __index = environment }))
		modules[name] = chunk(); return modules[name]
	end
	local function scenario(absent, same_identity)
		local old = { owner_id = "owner", owner_generation = 1, host_pane_id = "42", alias_nonce = "alias", window_key = "", window_epoch = "epoch-old", native_session_id = "3", window_host_id = "7", logical_session_id = "s1" }
		local now = clone(old); now.window_epoch = "epoch-new"
		if not same_identity then now.alias_nonce = "someone-else" end
		local data = { source_nonce = "nonce", authority_namespace = "orch-ns", spawn_namespace = "spawn-ns", authority_revision = 5,
			session_control = { admission_seq = 1, name = "Stuck", close = { control_origin = { kind = "closing", binding = old, controller_pane = "42", close_id = "attempt-old" },
				forget = { attempt_id = "attempt-old", request_bytes = "{}" } } } }
		local sent_ops, authority_calls, states = {}, {}, {}
		local last_response
		local serial = 0
		local api = {
			id = function() serial += 1; return "id-" .. serial end,
			notice = function() end,
			current = function() return false end, -- the old window epoch makes the cursor comparison fail after a reload
			context = function() return true end,
			closing = function() return false end,
			snapshot = function() return data end, origin = function() return now end,
			capture = function(_, _, _, done) done({ confirm = true }, nil, { }) end,
			intent = function(origin) return origin end,
			bridge = function() return { endpoint = true } end,
			peer = function() return true, last_response end,
			authority = function(_, _, _, kind, fields) table.insert(authority_calls, { kind = kind, fields = fields }) end,
			relay = function(_, _, event)
				table.insert(sent_ops, event.act)
				local r = assert(codec.decode_forget_request(event.value))
				local body = { schema = 1, op = r.op, request_id = r.request_id, attempt_id = r.attempt_id, spawn_namespace = r.spawn_namespace, authority_namespace = r.authority_namespace,
					logical_session_id = r.logical_session_id, admission_seq = r.admission_seq, spawn_boot = "boot-1" }
				if r.op == "discard_capability" then body.status, body.payload = "capable", { challenge = "forget-0000000000000000", absent = if absent then true else nil }
				else body.status, body.payload = "clean", { dispatch_revision = 4, inventory = { requests = 0, workers = 0, generations = 0 } } end
				last_response = assert(codec.encode_forget_response(body))
			end,
		}
		local cx = { session = { event = function(_, _, ev) table.insert(states, ev) end }, pick = function() return {} end }
		local module = load_module("forget_window").new(api)
		local started = module.start(cx, 42, now, data, true)
		for _ = 1, 8 do if started then module.tick_source(cx, 42, data, now) end end
		return started, sent_ops, authority_calls
	end
	local started, ops, calls = scenario(false, true)
	check(started and ops[1] == "discard_capability" and ops[2] == "discard_preview" and #calls == 1 and calls[1].kind == "supersede_forget",
		"after a reload (new epoch, same owner) recovery passes the check, runs capability and preview and reaches supersede_forget")
	local request = codec.decode_forget_request(calls[1].fields.request_bytes)
	check(request ~= nil and request.op == "discard_session" and request.dispatch_revision == 4 and request.spawn_boot == "boot-1" and calls[1].fields.attempt_id ~= "attempt-old",
		"the superseding request is a fresh discard bound to the new preview and attempt")
	local started2, ops2, calls2 = scenario(true, true)
	check(started2 and ops2[1] == "discard_capability" and ops2[2] == nil and #calls2 == 1 and calls2[1].kind == "supersede_forget",
		"an absent session skips the preview and goes straight to the idempotent discard")
	local request2 = codec.decode_forget_request(calls2[1].fields.request_bytes)
	check(request2 ~= nil and request2.dispatch_revision == 0, "the absent-session discard carries no observed revision")
	local started3, _, calls3 = scenario(false, false)
	check(not started3 and #calls3 == 0, "a different owner identity is refused: only the exact retained identity recovers")
end
if section == nil or section == "host_withdrawal" then
	local f = fixture(); f:catalog(0)
	local queued = f:queue(false); assert(queued.ok)
	assert(f:apply("pause").ok)
	local refusal = f:apply("claim", { action_id = queued.action_id, executor = f.origin.window_epoch })
	check(not refusal.ok and f:action(queued.action_id).claim == nil, "paused claim positively refuses before native issuance")
	assert(f:apply("resume").ok)
	local cancelled = f:apply("cancel_work", { worker_id = queued.worker_id }); assert(cancelled.ok, cancelled.message)
	local scoped = assert(f:scope(queued.action_id), "withdrawn held scope owes its watching consumer a receipt")
	local span = scoped.p.spans[1]
	local machine = runtime.json.decode(if type(span) == "string" then span else span.t)
	check(machine.action == nil and machine.receipt.worker_id == queued.worker_id,
		"successful withdrawal renders a receipt-only scope for its exact grantless held worker")
	f:release({ action_id = queued.action_id, worker_id = "other-worker", withdrawal_request_id = cancelled.request_id })
	check(f:scope(queued.action_id) ~= nil, "unrelated withdrawal acknowledgement cannot erase a held consumer scope")
	f:release({ action_id = queued.action_id, worker_id = queued.worker_id, withdrawal_request_id = cancelled.request_id })
	check(f:scope(queued.action_id) == nil, "exact withdrawal consumption releases the ephemeral receipt without a tombstone")
end
if section == nil or section == "project_history" then
	local f = shared.fixture(nil, { passive = true })
	local first
	for i = 1, 103 do
		local created = f:apply("new_project", { name = "Completed project " .. tostring(i),
			source = { kind = "manual", ref = "source:" .. tostring(i), revision = "observed-" .. tostring(i) } })
		assert(created.ok, created.message); first = first or created.orch_project_id
		local project = f.authority.registry.dispatch.projects[created.orch_project_id]
		assert(f:apply("project_finish", { orch_project_id = project.orch_project_id, project_revision = project.revision,
			result = "Owner finished the conversation-only work." }).ok)
	end
	local history = f.authority.registry.dispatch.finished_projects
	check(#history == 100 and history[1].name == "Completed project 4" and history[100].name == "Completed project 103",
		"history independently retains the newest hundred summaries without evicting authority")
	local bounded = #runtime.json.encode(history) <= 512 * 1024
	for _, summary in history do bounded = bounded and #runtime.json.encode(summary) <= 4096 end
	check(bounded and f.authority.registry.dispatch.projects[first] ~= nil,
		"presentation limits do not prune the corresponding live graph")
	local source = clone(history[1].source)
	local reopened = f:apply("project_reopen", { summary_index = 1 }); assert(reopened.ok, reopened.message)
	local project = f.authority.registry.dispatch.projects[reopened.orch_project_id]
	check(not project.started and runtime.json.encode(project.sources[1]) == runtime.json.encode(source)
		and next(f.authority.registry.dispatch.workers) == nil and next(f.authority.registry.dispatch.actions) == nil,
		"reopening copies only the source into a fresh unstarted project")
	local detached = clone(f.authority.registry)
	shared.dispatch.reclaim_session(detached, f.origin.logical_session_id)
	check(#detached.dispatch.finished_projects == 100 and next(detached.dispatch.projects) == nil,
		"session graph reclamation keeps independent finished summaries")
	local before = runtime.json.encode(f.authority.registry.dispatch.projects)
	assert(f:apply("delete_history").ok)
	check(#f.authority.registry.dispatch.finished_projects == 0
		and runtime.json.encode(f.authority.registry.dispatch.projects) == before, "deleting history leaves project authority unchanged")
	local malformed = clone(f.authority.registry)
	malformed.dispatch.projects[reopened.orch_project_id].associations = { bad = 1 }
	local safe, valid = pcall(shared.state.valid, malformed)
	check(safe and valid == false, "malformed association values are rejected without indexing untrusted scalars")
	check(shared.state.rehydrate(clone(f.authority.registry)) ~= nil, "bounded history and reopened source restore")
end

return "reclamation/" .. tostring(section or "all") .. ": " .. tostring(checks) .. " checks passed"
