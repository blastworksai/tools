-- Native Tern runner; only KV durability and the identity clock are injected.
local root, section = ...
assert(type(root) == "string", "pass the package directory")
assert(type(section) == "string", "pass an explicit test section")
local runtime, environment = tern, getfenv()
local checks = 0
local function check(condition, message)
	assert(condition, message)
	checks += 1
end
local function copy(value)
	if type(value) ~= "table" then return value end
	local result = {}
	for key, item in pairs(value) do result[key] = copy(item) end
	return result
end
local function equal(left, right)
	if type(left) ~= type(right) then return false end
	if type(left) ~= "table" then return left == right end
	for key, item in pairs(left) do if not equal(item, right[key]) then return false end end
	for key in pairs(right) do if left[key] == nil then return false end end
	return true
end
local function same(left, right, message) check(equal(left, right), message) end
local function count(value)
	local n = 0
	for _ in pairs(value) do n += 1 end
	return n
end
local function record(id, fields)
	local value = {
		id = id, provider = "custom", account_label = id, backend = "local-terminal",
		command = "ordinary-cli", arguments = {}, enabled = true, include_all = true,
		duplicate_policy = "skip", placement = "tab",
	}
	for key, item in pairs(fields or {}) do value[key] = item end
	return value
end
local function boundary(seed)
	local saved = copy(seed or {})
	local db = { writes = 0, authority_writes = 0, now = 1700000000 }
	db.kv = {
		get = function(key)
			if db.fail_get == key then error("injected read failure") end
			return copy(saved[key])
		end,
		set = function(key, value)
			db.writes += 1
			if key == "authority" then
				db.authority_writes += 1
				if db.fail_authority_at == db.authority_writes then error("injected atomic write failure") end
			end
			if db.fail_set == key then error("injected atomic write failure") end
			saved[key] = copy(value)
		end,
	}
	function db.peek(key) return copy(saved[key]) end
	function db.image() return copy(saved) end
	function db.fail_after(n) db.fail_authority_at = db.authority_writes + n end
	return db
end
local function modules(db)
	local injected = setmetatable({ kv = db.kv }, { __index = runtime })
	local clock = setmetatable({ time = function() return db.now end }, { __index = os })
	local loaded = {}
	local function load(name)
		name = name:gsub("^%./", "")
		if loaded[name] ~= nil then return loaded[name] end
		local chunk = assert(loadstring(runtime.fs.read(root .. "/" .. name .. ".luau"), name))
		setfenv(chunk, setmetatable({ require = load, tern = injected, os = clock }, { __index = environment }))
		local result = chunk()
		loaded[name] = result
		return result
	end
	return load("authority"), load("config"), load("launch_state")
end
local function snapshot(authority, binding)
	local value, err = authority.snapshot(binding)
	assert(value, tostring(err))
	return value
end
local function edit(authority, binding, operation, data)
	local view = snapshot(authority, binding)
	local ok, err = authority.edit(binding, view.config_revision, operation, data or {})
	check(ok, "accept deliberate " .. operation .. ": " .. tostring(err))
end
local function fresh(records)
	local db = boundary()
	local authority, config, launch = modules(db)
	local binding, err = authority.open("host-A", 4)
	assert(binding, tostring(err))
	if records then edit(authority, binding, "replace-records", { records = records }) end
	return db, authority, binding, config, launch
end
local function request(binding, observer, sequence, revision, op, data, acknowledged)
	return {
		version = 2, request_id = observer .. "/" .. tostring(sequence), authority_id = binding.authority_id,
		observer_id = observer, request_sequence = sequence, acknowledged_requests = acknowledged or {},
		expected_config_revision = revision, op = op or "refresh", data = data or {},
	}
end
local function reserve_request(binding, observer, sequence, revision, id)
	return request(binding, observer, sequence, revision, "launch_record", { record_id = id })
end
local function submit(authority, binding, value)
	local ok, err = authority.request(binding, value)
	check(ok, "request admitted and committed: " .. tostring(err))
	local reply = snapshot(authority, binding).replies[value.request_id]
	check(reply ~= nil, "committed request retains its reply")
	return reply
end
local function refused_unchanged(db, action, message, reason)
	local before = db.image()
	local ok, err = action()
	check(not ok and type(err) == "string" and #err > 0, message .. " refuses with an error")
	if reason then check(err == reason, message .. " reports its domain reason") end
	same(db.image(), before, message .. " preserves every durable value")
end
local function native(pane)
	return { pane = pane or 42, window_key = "", program = "/bin/bash", executable = "/opt/tern", socket = "/tmp/tern.sock" }
end
local function claim(authority, binding, id, pane)
	local job, err = authority.claim_execution(binding, id, native(pane))
	check(job ~= nil, "host claims immutable native pane: " .. tostring(err))
	return job
end
local function update(authority, binding, id, stage, patch, observation)
	local job, err = authority.update_execution(binding, id, stage, patch, observation)
	check(job ~= nil, "host commits execution evidence: " .. tostring(err))
	return job
end
local sections = {}

-- Two observers interleave reservations and acknowledgments without a last-reply slot.
sections.interleaving = function()
	local db, authority, binding, _, launch = fresh({ record("first"), record("second") })
	local revision = snapshot(authority, binding).config_revision
	local a = reserve_request(binding, "A", 1, revision, "first")
	local b = reserve_request(binding, "B", 1, revision, "second")
	local reply_a, reply_b = submit(authority, binding, a), submit(authority, binding, b)
	check(reply_a.ok and reply_b.ok, "independent accounts both reserve")
	check(reply_a.result.attempt.id ~= reply_b.result.attempt.id, "interleaved reservations have distinct identities")
	local view = snapshot(authority, binding)
	check(count(view.replies) == 2 and #view.attempts == 2, "A and B results and attempts coexist")
	same(view.replies[a.request_id], reply_a, "B cannot replace A's retained result")
	check(launch.validate(db.peek("authority").sessions[binding.session_key].launch) ~= nil, "authority persists a real valid launch ledger")
	local before = db.image()
	check(authority.request(binding, a), "identical retained request is idempotent")
	same(db.image(), before, "identical retry creates no attempt or reply mutation")
	local changed = copy(a)
	changed.data.record_id = "second"
	refused_unchanged(db, function() return authority.request(binding, changed) end, "changed request ID reuse", "changed-request-reuse")
	local cross_ack = request(binding, "A", 2, revision, nil, nil, { a.request_id, b.request_id })
	refused_unchanged(db, function() return authority.request(binding, cross_ack) end, "acknowledging another observer", "acknowledgment-observer-mismatch")
	local a2 = request(binding, "A", 2, revision, nil, nil, { a.request_id })
	check(submit(authority, binding, a2).ok, "A acknowledges its own result")
	view = snapshot(authority, binding)
	check(view.replies[a.request_id] == nil and view.replies[a2.request_id] ~= nil, "A's old reply alone is pruned")
	same(view.replies[b.request_id], reply_b, "A's acknowledgment preserves B's reply exactly")
	check(view.request_sequences.A == 2 and view.request_sequences.B == 1, "watermarks remain observer scoped")
	refused_unchanged(db, function() return authority.request(binding, a) end, "acknowledged request replay", "stale-request-sequence")
	local renamed_replay = copy(a)
	renamed_replay.request_id = "A/new-id-old-sequence"
	refused_unchanged(db, function() return authority.request(binding, renamed_replay) end, "old sequence with fresh request ID", "stale-request-sequence")
	-- Snapshot tables are not writable aliases into durable state.
	before = db.image()
	view.records[1].command = "tampered"
	view.attempts[1].phase = "Exited"
	view.replies[b.request_id].ok = false
	same(db.image(), before, "consumer snapshot mutation cannot change durable state")
end

-- Stale configuration mutations may retain an error reply, never stale roster data.
sections.stale_config = function()
	local db, authority, binding = fresh({ record("first") })
	local old_revision = snapshot(authority, binding).config_revision
	edit(authority, binding, "replace-records", { records = { record("first", { command = "approved-command", arguments = { "two words", "" } }), record("second") } })
	local before = snapshot(authority, binding)
	refused_unchanged(db, function()
		return authority.edit(binding, old_revision, "replace-records", { records = { record("stale") } })
	end, "stale form edit")
	local stale = request(binding, "importer", 1, old_revision, "import_records", { setup_run_id = "old-setup", records = { record("stale") } })
	local reply = submit(authority, binding, stale)
	check(not reply.ok and reply.error == "stale-config", "stale import returns a retained rejection")
	local after = snapshot(authority, binding)
	same(after.records, before.records, "stale import leaves roster exact")
	check(after.config_revision == before.config_revision, "stale import does not advance configuration revision")
	local imported = { record("third", { prompt = "Keep exact prompt.\nNo automatic launch." }) }
	local add = request(binding, "importer", 2, after.config_revision, "import_records", { setup_run_id = "approved-setup", records = imported })
	check(submit(authority, binding, add).result.imported == 1, "review-confirmed import adds the intended record")
	after = snapshot(authority, binding)
	check(#after.attempts == 0, "import does not reserve or execute a launch")
	local replay = request(binding, "importer", 3, after.config_revision, "import_records", add.data)
	local replay_reply = submit(authority, binding, replay)
	check(replay_reply.ok and replay_reply.result.imported == 0, "identical import is idempotent under a new request")
	local conflict = request(binding, "importer", 4, after.config_revision, "import_records", { setup_run_id = "approved-setup", records = { record("third", { command = "different" }) } })
	check(not submit(authority, binding, conflict).ok, "conflicting import of an existing record is rejected")
	same(snapshot(authority, binding).records, after.records, "setup replay and conflict preserve exact roster")
end

-- Resolution is fenced by the inspected launch revision on both mutation paths.
sections.stale_resolution = function()
	for _, path in ipairs({ "native", "remote" }) do
		local db, authority, binding = fresh({ record("resolve") })
		local revision = snapshot(authority, binding).config_revision
		local reserved = submit(authority, binding, reserve_request(binding, "owner", 1, revision, "resolve"))
		check(reserved.ok, "reserve attempt before resolution review")
		local inspected = snapshot(authority, binding)
		local id = reserved.result.attempt.id
		claim(authority, binding, id)
		update(authority, binding, id, "claimed", { stage = "submission_intent", command = "ordinary-cli" })
		update(authority, binding, id, "submission_intent", { stage = "running" }, { phase = "Running", pane = 42 })
		local advanced = snapshot(authority, binding)
		check(advanced.attempt_revision > inspected.attempt_revision and advanced.attempts[1].unresolved,
			"observation invalidates old resolution view without releasing reservation")
		local ledger = db.peek("authority").sessions[binding.session_key].launch
		if path == "native" then
			refused_unchanged(db, function()
				return authority.edit(binding, revision, "resolve-attempt", { id = id })
			end, "native resolution without inspected attempt revision")
			refused_unchanged(db, function()
				return authority.edit(binding, revision, "resolve-attempt", { id = id, attempt_revision = inspected.attempt_revision })
			end, "native stale resolution")
		else
			local unfenced = request(binding, "owner", 3, revision, "resolve_attempt", { attempt_id = id })
			refused_unchanged(db, function() return authority.request(binding, unfenced) end,
				"remote resolution without inspected attempt revision")
			local stale = request(binding, "owner", 3, revision, "resolve_attempt", {
				attempt_id = id, attempt_revision = inspected.attempt_revision,
			})
			local reply = submit(authority, binding, stale)
			check(not reply.ok and reply.error == "stale-attempt-revision", "remote stale resolution retains explicit rejection")
		end
		same(db.peek("authority").sessions[binding.session_key].launch, ledger,
			path .. " stale resolution preserves full ledger including unresolved flag and revision")
		local current = snapshot(authority, binding)
		if path == "native" then
			edit(authority, binding, "resolve-attempt", { id = id, attempt_revision = current.attempt_revision })
		else
			local resolve = request(binding, "owner", 4, revision, "resolve_attempt", {
				attempt_id = id, attempt_revision = current.attempt_revision,
			})
			check(submit(authority, binding, resolve).ok, "current remote resolution is accepted")
		end
		local resolved = snapshot(authority, binding)
		check(#resolved.attempts == 1 and resolved.attempts[1].id == id and not resolved.attempts[1].unresolved,
			path .. " fresh deliberate resolution releases only the existing attempt")
		check(resolved.attempt_revision > current.attempt_revision and resolved.attempts[1].exit_status == nil,
			path .. " resolution advances history without inventing exit evidence")
		check(resolved.jobs[1].stage == "resolved", path .. " resolution updates corresponding execution job")
	end
end

-- One atomic write commits the mutation, reply and watermark together.
sections.recovery = function()
	local db, authority, binding = fresh({ record("fault") })
	local revision = snapshot(authority, binding).config_revision
	local value = reserve_request(binding, "fault-observer", 1, revision, "fault")
	db.fail_after(1)
	refused_unchanged(db, function() return authority.request(binding, value) end, "failed atomic admission")
	local scope = db.peek("authority").sessions[binding.session_key]
	check(#scope.launch.attempts == 0 and next(scope.replies) == nil and next(scope.request_sequences) == nil, "failed admission creates no attempt, reply, or watermark")
	local writes = db.authority_writes
	local reply = submit(authority, binding, value)
	check(db.authority_writes == writes + 1, "admission commits with exactly one atomic write")
	local committed = snapshot(authority, binding)
	check(#committed.attempts == 1 and count(committed.replies) == 1 and reply.ok, "one reservation and one successful reply")
	same(reply.result.attempt, committed.attempts[1], "reply identifies the actual committed attempt")
	check(committed.request_sequences["fault-observer"] == 1, "admission commits the replay watermark")
	local durable = db.image()
	for _ = 1, 3 do
		same(snapshot(authority, binding), committed, "repeated snapshot retains the same reply and attempt")
		check(authority.request(binding, value), "same request ID retry is accepted idempotently")
	end
	same(db.image(), durable, "retries never recommit the request")
end

-- Capacity rotates the transport generation, never drops replay fences in place.
sections.reply_capacity = function()
	local db, authority, binding = fresh({ record("kept", { duplicate_policy = "allow" }) })
	local captured = reserve_request(binding, "captured", 1, 1, "kept")
	local admitted = submit(authority, binding, captured)
	local id = admitted.result.attempt.id
	claim(authority, binding, id)
	update(authority, binding, id, "claimed", { stage = "submission_intent", command = "ordinary-cli" })
	for sequence = 1, 63 do check(submit(authority, binding, request(binding, "full", sequence, 1)).ok, "retain bounded reply") end
	local before = db.peek("authority").sessions[binding.session_key]
	local trigger = reserve_request(binding, "overflow", 1, 1, "kept")
	db.fail_after(1)
	refused_unchanged(db, function() return authority.request(binding, trigger) end, "failed generation rotation")
	local ok, err = authority.request(binding, trigger)
	check(not ok and err == "stale-authority", "capacity trigger is refused, never executed")
	local after = db.peek("authority").sessions[binding.session_key]
	check(after.authority_id ~= before.authority_id and next(after.replies) == nil and next(after.request_sequences) == nil, "rotation atomically retires old transport")
	same(after.launch, before.launch, "rotation preserves active history")
	same(after.jobs, before.jobs, "rotation preserves execution jobs")
	refused_unchanged(db, function() return authority.request(binding, captured) end, "captured old launch cannot reexecute", "stale-authority")
	refused_unchanged(db, function() return authority.request(binding, trigger) end, "overflow launch cannot auto-replay", "stale-authority")
	check(authority.snapshot(binding) == nil, "old UI binding must explicitly reopen")
	-- Host execution is session-scoped, independent of the retired UI generation.
	update(authority, binding, id, "submission_intent", { stage = "completed" }, { phase = "Exited", exit_status = 0 })
	refused_unchanged(db, function() return authority.claim_execution(binding, id, native()) end, "retired binding cannot claim the job twice")
	local reopened = assert(authority.open("host-A", 4, nil, binding.session_key))
	refused_unchanged(db, function() return authority.request(reopened, captured) end, "captured request rejected with refreshed binding", "stale-authority")
	local view = snapshot(authority, reopened)
	check(#view.attempts == 1 and view.jobs[1].stage == "completed", "one admitted job completes across generation rotation")
	check(submit(authority, reopened, request(reopened, "fresh", 1, 1)).ok, "explicit refreshed observer can continue")
end
sections.observer_capacity = function()
	local db, authority, binding = fresh()
	local captured = request(binding, "observer-1", 1, 0)
	for index = 1, 130 do
		local value = request(binding, "observer-" .. tostring(index), 1, 0)
		if index == 65 or index == 129 then
			local ok, err = authority.request(binding, value)
			check(not ok and err == "stale-authority", "reconnect capacity requires explicit refresh")
			local previous = binding
			binding = assert(authority.open("host-A", 4, nil, previous.session_key))
			refused_unchanged(db, function() return authority.request(previous, value) end, "retired reconnect request", "stale-authority")
			refused_unchanged(db, function() return authority.request(binding, captured) end, "captured old observer after recovery", "stale-authority")
			value = request(binding, "observer-" .. tostring(index), 1, 0)
		end
		check(submit(authority, binding, value).ok, "admit reconnect observer after explicit refresh")
		edit(authority, binding, "review-reply", { id = value.request_id })
	end
	check(count(snapshot(authority, binding).request_sequences) == 2, "130 reconnects reclaim bounded watermarks safely")
end
sections.byte_capacity = function()
	local db, authority, binding, config = fresh({ record("kept") })
	local large = {}
	for index = 1, 3 do large[index] = record("large-" .. tostring(index), { prompt = string.rep("x", 30000) }) end
	check(config.validate_records(large) ~= nil, "large import is individually schema-valid")
	local value = request(binding, "large", 1, 1, "import_records", { setup_run_id = "large-setup", records = large })
	refused_unchanged(db, function() return authority.request(binding, value) end, "encoded durable state capacity")
	check(#snapshot(authority, binding).attempts == 0, "oversized request has no side effects")
end

-- Review preserves both originals and requires a choice for every record, including omissions.
sections.review_conflict = function()
	local original = { schema = 1, agents = { record("shared", { command = "host-command" }), record("host-only") } }
	local client = { schema = 1, agents = { record("shared", { command = "client-command", arguments = { "approved" } }), record("client-only") } }
	local db = boundary({ config = original })
	local authority, config = modules(db)
	local binding = assert(authority.open("host-A", 4, client))
	local view = snapshot(authority, binding)
	check(not view.ready and view.migration ~= nil and #view.migration.sources == 2, "conflicting host and client rosters require visible review")
	same(db.peek("config"), original, "opening review preserves the original config key")
	same(db.peek("migration-original"), original, "host original is durably backed up")
	same(db.peek("migration-client-1"), client, "client original is durably backed up separately")
	same(view.records, original.agents, "opening conflict does not overwrite host roster with client copy")
	refused_unchanged(db, function() return authority.edit(binding, view.config_revision, "review-confirm", {}) end, "review without per-record choices")
	local blocked = reserve_request(binding, "review-observer", 1, view.config_revision, "shared")
	check(not submit(authority, binding, blocked).ok, "review-pending configuration cannot reserve")
	check(#snapshot(authority, binding).attempts == 0, "review block creates no launch attempt")
	edit(authority, binding, "review-choice", { id = "shared", source = 2 })
	view = snapshot(authority, binding)
	refused_unchanged(db, function() return authority.edit(binding, view.config_revision, "review-confirm", {}) end, "partially selected review")
	refused_unchanged(db, function() return authority.edit(binding, view.config_revision, "review-choice", { id = "host-only", source = 2 }) end, "source missing selected record")
	edit(authority, binding, "review-choice", { id = "host-only", source = 1 })
	edit(authority, binding, "review-choice", { id = "client-only", source = 0 })
	edit(authority, binding, "review-confirm", {})
	view = snapshot(authority, binding)
	check(view.ready and view.migration == nil, "explicit complete review makes the authority ready")
	local expected = assert(config.validate_records({ original.agents[2], client.agents[1] }))
	same(view.records, expected, "review keeps selected source per account and explicit omission")
	same(db.peek("config"), original, "review confirmation never alters legacy original")
	same(db.peek("migration-original"), original, "review confirmation preserves host backup")
	same(db.peek("migration-client-1"), client, "review confirmation preserves client backup")
	local reopened = assert(authority.open("host-A", 4, client, binding.session_key))
	check(snapshot(authority, reopened).ready, "already reviewed client copy does not reopen conflict")
	same(snapshot(authority, reopened).records, expected, "reopening reviewed source retains deliberate decisions")

	-- A client's bucket key is an alias, not the authority's durable roster key.
	local alias_db, alias_authority, origin, canonical = fresh()
	local client_blob = { schema = 2, hosts = {
		["client-alias-A"] = { schema = 2, agents = { record("alias-a", { command = "/usr/bin/true" }) } },
		["client-alias-B"] = { schema = 2, agents = { record("alias-b", { command = "/usr/bin/true" }) } },
		["unrelated-host"] = { schema = 2, agents = { record("unrelated", { command = "/usr/bin/true" }) } },
	} }
	local expected_a = assert(canonical.validate_records(client_blob.hosts["client-alias-A"].agents))
	local expected_b = assert(canonical.validate_records(client_blob.hosts["client-alias-B"].agents))
	local first = assert(alias_authority.open("client-alias-A", 4, client_blob, origin.session_key))
	local first_view = snapshot(alias_authority, first)
	check(not first_view.ready and #first_view.migration.sources == 2, "incoming client alias exposes its legacy bucket for explicit review")
	same(first_view.migration.sources[1].records, {}, "opening alias review preserves empty authoritative roster")
	same(first_view.migration.sources[2].records, expected_a, "only alias A's bucket is offered, not B or unrelated buckets")
	same(alias_db.peek("migration-client-1"), client_blob, "alias review preserves the entire client original including unrelated buckets")
	refused_unchanged(alias_db, function()
		return alias_authority.edit(first, first_view.config_revision, "review-confirm", {})
	end, "alias source review without an explicit per-record choice")
	edit(alias_authority, first, "review-choice", { id = "alias-a", source = 2 })
	edit(alias_authority, first, "review-confirm", {})
	same(snapshot(alias_authority, first).records, expected_a, "explicit alias A selection enters the canonical roster")
	local settled_a = alias_db.image()
	local repeated_a = assert(alias_authority.open("client-alias-A", 4, client_blob, origin.session_key))
	check(snapshot(alias_authority, repeated_a).ready, "same-alias reviewed copy remains ready")
	same(alias_db.image(), settled_a, "same-alias review replay does not change revisions, decisions or saved originals")

	local second = assert(alias_authority.open("client-alias-B", 4, client_blob, origin.session_key))
	local second_view = snapshot(alias_authority, second)
	check(not second_view.ready and #second_view.migration.sources == 2, "the identical whole client blob under alias B needs a distinct source review")
	same(second_view.migration.sources[1].records, expected_a, "alias B review retains the deliberate canonical roster")
	same(second_view.migration.sources[2].records, expected_b, "alias B exposes B's distinct record without offering unrelated buckets")
	same(second.authority_id, origin.authority_id, "changing client source alias does not replace the native authority")
	same(second.session_key, origin.session_key, "changing client source alias does not rebind its durable namespace")
	same(second.host_key, origin.host_key, "canonical roster key is independent of incoming client aliases")
	refused_unchanged(alias_db, function()
		return alias_authority.edit(second, second_view.config_revision, "review-confirm", {})
	end, "alias B cannot bypass per-record review using alias A's receipt")
	edit(alias_authority, second, "review-choice", { id = "alias-a", source = 1 })
	edit(alias_authority, second, "review-choice", { id = "alias-b", source = 2 })
	edit(alias_authority, second, "review-confirm", {})
	local expected_both = assert(canonical.validate_records({ expected_a[1], expected_b[1] }))
	same(snapshot(alias_authority, second).records, expected_both, "both explicitly selected accounts are saved under the canonical host")
	same(alias_db.peek("authority").config.hosts[origin.host_key].agents, expected_both, "only the original canonical roster bucket receives reviewed records")
	check(alias_db.peek("authority").config.hosts["client-alias-A"] == nil
		and alias_db.peek("authority").config.hosts["client-alias-B"] == nil, "client aliases never create authoritative roster buckets")
	same(alias_db.peek("migration-client-1"), client_blob, "first alias original remains untouched after later review")
	same(alias_db.peek("migration-client-2"), client_blob, "second alias original retains all unrelated client buckets")
	local settled_b = alias_db.image()
	for _, alias in ipairs({ "client-alias-A", "client-alias-B" }) do
		local replay = assert(alias_authority.open(alias, 4, client_blob, origin.session_key))
		check(snapshot(alias_authority, replay).ready, "each settled alias receipt remains independently idempotent")
	end
	same(alias_db.image(), settled_b, "replaying either reviewed alias preserves later deliberate selections")
end

-- Reset needs no retained replies; it never erases reservations.
sections.transport_reset = function()
	local db, authority, binding = fresh({ record("reset") })
	local revision = snapshot(authority, binding).config_revision
	local value = reserve_request(binding, "reset-observer", 1, revision, "reset")
	check(submit(authority, binding, value).ok, "prepare an admitted request with a retained reply")
	local view = snapshot(authority, binding)
	refused_unchanged(db, function() return authority.edit(binding, revision, "reset-transport", {}) end, "reset with retained reply")
	edit(authority, binding, "review-reply", { id = value.request_id })
	refused_unchanged(db, function() return authority.edit(binding, revision, "reset-transport", {}) end, "reset with active attempt")
	update(authority, binding, view.jobs[1].id, "admitted", { stage = "unknown" }, { phase = "Unknown" })
	refused_unchanged(db, function() return authority.edit(binding, revision, "reset-transport", {}) end, "reset with unresolved unknown attempt")
	view = snapshot(authority, binding)
	edit(authority, binding, "resolve-attempt", { id = view.attempts[1].id, attempt_revision = view.attempt_revision })
	view = snapshot(authority, binding)
	local before = db.peek("authority")
	local old_binding = copy(binding)
	local old_scope = before.sessions[binding.session_key]
	edit(authority, binding, "reset-transport", {})
	local after = db.peek("authority")
	local new_scope = after.sessions[binding.session_key]
	check(binding.authority_id ~= old_binding.authority_id, "transport reset rotates authority identity")
	check(new_scope.authority_id == binding.authority_id, "binding follows committed rotated identity")
	same(new_scope.launch, old_scope.launch, "transport reset preserves full attempt ledger and identity counter")
	same(new_scope.jobs, old_scope.jobs, "transport reset preserves execution jobs")
	same(after.config, before.config, "transport reset preserves roster")
	same(new_scope.request_sequences, {}, "explicit reset clears observer watermarks")
	check(next(new_scope.replies) == nil and next(new_scope.requests) == nil, "reset leaves transport empty")
	refused_unchanged(db, function() return authority.request(old_binding, value) end, "old authority request after reset", "stale-authority")
	check(authority.snapshot(old_binding) == nil, "old authority binding cannot read as the new identity")
	same(snapshot(authority, binding).attempts, view.attempts, "reset preserves explicitly resolved history")
	local next_launch = reserve_request(binding, "new-observer", 1, revision, "reset")
	check(submit(authority, binding, next_launch).ok, "explicit new launch allowed only after resolution")
end

-- An explicitly empty client roster is still a conflicting source, not an absent copy.
sections.empty_client = function()
for index, client in ipairs({
	{ schema = 1, agents = {} },
	{ schema = 2, hosts = { ["host-A"] = { schema = 2, agents = {} } } },
}) do
	local host_records = { record("host-kept") }
	local db, authority, binding = fresh(host_records)
	local original_config = db.peek("authority").config
	local reopened = assert(authority.open("host-A", 4, client, binding.session_key))
	local view = snapshot(authority, reopened)
	check(not view.ready and view.migration ~= nil, "explicit empty client roster requires deliberate conflict review")
	check(#view.migration.sources == 2, "empty client source is retained beside populated host source")
	same(view.migration.sources[1].records, host_records, "empty client conflict preserves populated host review source")
	same(view.migration.sources[2].records, {}, "empty client source remains explicitly represented")
	same(view.records, host_records, "opening empty client conflict never silently replaces host roster")
	same(db.peek("authority").config, original_config, "opening empty client conflict preserves canonical host config")
	same(db.peek("migration-client-1"), client, "explicit empty client original is backed up exactly")
	refused_unchanged(db, function()
		return authority.edit(reopened, view.config_revision, "review-confirm", {})
	end, "empty client conflict without a per-record decision")
	local choice = if index == 1 then 1 else 0
	edit(authority, reopened, "review-choice", { id = "host-kept", source = choice })
	edit(authority, reopened, "review-confirm", {})
	view = snapshot(authority, reopened)
	check(view.ready and view.migration == nil, "deliberate empty-source conflict decision completes review")
	same(view.records, if choice == 1 then host_records else {}, "only explicit selection or omission determines final roster")
	same(db.peek("migration-client-1"), client, "empty client original survives review confirmation")
	local again = assert(authority.open("host-A", 4, client, binding.session_key))
	check(snapshot(authority, again).ready, "reviewed empty source does not reopen settled conflict")
end
end

-- Minimal current migration fixtures: empty flat and host-scoped, plus a real legacy record.
sections.migration = function()
for _, original in ipairs({
	{ schema = 1, agents = {} },
	{ schema = 2, hosts = { ["host-A"] = { schema = 2, agents = { record("current") } } } },
	{ schema = 1, agents = { { id = "legacy", provider = "custom", backend = "local-terminal", command = "ordinary-cli", arguments = { "two words", "" } } } },
}) do
	local db = boundary({ config = original })
	local authority, config = modules(db)
	local expected = assert(config.migrate(original, "host-A")).records
	local binding = assert(authority.open("host-A", 4))
	local view = snapshot(authority, binding)
	check(not view.ready, "existing configuration needs deliberate migration review")
	for _, item in ipairs(expected) do edit(authority, binding, "review-choice", { id = item.id, source = 1 }) end
	edit(authority, binding, "review-confirm", {})
	view = snapshot(authority, binding)
	check(view.ready and #view.attempts == 0, "migration review never starts agents")
	same(view.records, expected, "authority migration uses canonical config transformation")
	same(db.peek("config"), original, "minimal fixture remains exact at original key")
	same(db.peek("migration-original"), original, "minimal fixture remains exact in backup")
end
end

-- Missing saved scope, future formats and corruption fail closed instead of resetting history.
sections.invalid_authority = function()
	local db, authority, binding = fresh({ record("preserved") })
	local original = db.image()
	local absent = boundary()
	local missing = modules(absent)
	refused_unchanged(absent, function() return missing.open("host-A", 4, nil, binding.session_key) end, "missing saved authority on reopen")
	refused_unchanged(absent, function() return missing.snapshot(binding) end, "snapshot of missing saved authority")
	refused_unchanged(absent, function() return missing.request(binding, request(binding, "missing", 1, 1)) end, "request against missing saved authority")
	local mutations = {
		function(value) value.version = 99 end,
		function(value) value.version = 1 end,
		function(value) value.reviewed_sources["1"] = { schema = 1, agents = {} } end,
		function(value) value.reviewed_sources["1"] = { config = { schema = 1, agents = {} } } end,
		function(value) value.reviewed_sources["1"] = { host_key = "", config = { schema = 1, agents = {} } } end,
		function(value) value.reviewed_sources["1"] = { host_key = "client-alias", config = { schema = 99 } } end,
		function(value) value.reviewed_sources["1"] = { host_key = "client-alias", config = { schema = 1, agents = "corrupt" } } end,
		function(value) value.reviewed_sources["1"] = { host_key = "client-alias", config = { schema = 1, agents = {} }, unexpected = true } end,
		function(value) value.config.hosts["host-A"].agents = "corrupt" end,
		function(value) value.sessions[binding.session_key].launch.version = 99 end,
		function(value) value.sessions[binding.session_key].request_sequences.bad = -1 end,
		function(value) value.sessions[binding.session_key] = nil end,
	}
	for index, mutate in ipairs(mutations) do
		local seed = copy(original)
		mutate(seed.authority)
		local broken_db = boundary(seed)
		local broken = modules(broken_db)
		refused_unchanged(broken_db, function() return broken.open("host-A", 4, nil, binding.session_key) end, "invalid saved authority reopen " .. tostring(index))
		refused_unchanged(broken_db, function() return broken.snapshot(binding) end, "invalid saved authority snapshot " .. tostring(index))
		refused_unchanged(broken_db, function() return broken.request(binding, request(binding, "broken", 1, 1)) end, "invalid saved authority request " .. tostring(index))
	end
	db.fail_get = "authority"
	refused_unchanged(db, function() return authority.snapshot(binding) end, "failed authority read")
end
sections.invalid_migration = function()
for _, original in ipairs({ { schema = 99, agents = {} }, { schema = 2, hosts = false }, { schema = 1, agents = { record("same"), record("same") } } }) do
	local db = boundary({ config = original })
	local authority = modules(db)
	refused_unchanged(db, function() return authority.open("host-A", 4) end, "future or corrupt migration source")
end
end
sections.backup_failure = function()
	local original = { schema = 1, agents = { record("backup") } }
	local db = boundary({ config = original })
	local authority = modules(db)
	db.fail_set = "migration-original"
	refused_unchanged(db, function() return authority.open("host-A", 4) end, "failed original preservation")
	check(db.peek("authority") == nil, "failed migration backup cannot initialize authority")
end

sections.execution_lifecycle = function()
	local empty = modules(boundary())
	same(empty.execution_bindings(), {}, "uninitialized host has no execution bindings")
	local db, authority, binding = fresh({ record("native") })
	local old_wire = request(binding, "old-window", 1, 1); old_wire.version = 1
	refused_unchanged(db, function() return authority.request(binding, old_wire) end, "retired wire protocol")
	local old_observe = request(binding, "old-window", 1, 1, "observe_attempt", {})
	refused_unchanged(db, function() return authority.request(binding, old_observe) end, "window cannot publish execution evidence")
	local admitted = submit(authority, binding, reserve_request(binding, "window", 1, 1, "native"))
	local id = admitted.result.attempt.id
	check(admitted.result.job.stage == "admitted" and admitted.result.job.command == nil and admitted.result.job.record == nil, "wire admission exposes only inert public job")
	check(admitted.result.attempt.observer_id ~= "window", "host owns runtime observations")
	local bindings = assert(authority.execution_bindings())
	same(bindings, { binding }, "executor discovers durable native scope")
	local before = db.image()
	local jobs = assert(authority.execution_jobs(binding))
	jobs[1].provider = "tampered"
	same(db.image(), before, "private execution reads are detached")
	local wrong_scope = copy(binding); wrong_scope.native_session = 5
	refused_unchanged(db, function() return authority.execution_job(wrong_scope, id) end, "wrong native session")
	local invalid = native(); invalid.executable = "relative-tern"
	refused_unchanged(db, function() return authority.claim_execution(binding, id, invalid) end, "claim without absolute fresh executable")
	db.fail_after(1)
	refused_unchanged(db, function() return authority.claim_execution(binding, id, native()) end, "failed atomic claim")
	local job = claim(authority, binding, id)
	check(job.stage == "claimed" and snapshot(authority, binding).attempts[1].pane == 42, "claim binds job and attempt atomically")
	refused_unchanged(db, function() return authority.claim_execution(binding, id, native(43)) end, "duplicate claim")
	refused_unchanged(db, function() return authority.update_execution(binding, id, "admitted", { stage = "failed" }, { phase = "Failed" }) end, "expected-stage compare")
	refused_unchanged(db, function() return authority.update_execution(binding, id, "claimed", { stage = "running" }, { phase = "Running" }) end, "cannot bypass persisted submission intent")
	local revision = snapshot(authority, binding).attempt_revision
	update(authority, binding, id, "claimed", { epoch = "daemon:1", native_tab = 7 })
	check(snapshot(authority, binding).attempt_revision > revision, "metadata-only change advances launch revision")
	refused_unchanged(db, function() return authority.update_execution(binding, id, "claimed", { epoch = "daemon:2" }) end, "immutable native epoch")
	db.fail_after(1)
	refused_unchanged(db, function() return authority.update_execution(binding, id, "claimed", { stage = "submission_intent", command = "ordinary-cli" }) end, "intent persistence fails before permission")
	update(authority, binding, id, "claimed", { stage = "submission_intent", command = "ordinary-cli" })
	refused_unchanged(db, function() return authority.update_execution(binding, id, "submission_intent", { command = "other-cli" }) end, "immutable submitted command")
	update(authority, binding, id, "submission_intent", { stage = "submitted" })
	refused_unchanged(db, function() return authority.update_execution(binding, id, "submitted", { stage = "running" }, { phase = "Running", pane = 43 }) end, "host pane evidence fence")
	update(authority, binding, id, "submitted", { stage = "running" }, { phase = "Running" })
	update(authority, binding, id, "running", { stage = "completed" }, { phase = "Failed", exit_status = 23 })
	refused_unchanged(db, function() return authority.update_execution(binding, id, "submission_intent", { stage = "submitted" }) end, "late submitted callback loses completion race")
	refused_unchanged(db, function() return authority.update_execution(binding, id, "completed", { stage = "running" }, { phase = "Running" }) end, "wrapper alive cannot undo completion")
	update(authority, binding, id, "completed", {}, { phase = "Unknown", diagnostic = "wrapper disappeared" })
	local finished = snapshot(authority, binding)
	check(finished.attempts[1].phase == "Failed" and finished.attempts[1].exit_status == 23, "completion wins over shell disappearance")
	update(authority, binding, id, "completed", { pane_reused = true })
	refused_unchanged(db, function() return authority.update_execution(binding, id, "completed", { pane_reused = false }) end, "pane reuse remains monotonic")
	check(snapshot(authority, binding).jobs[1].pane_reused, "public job preserves provider artwork invalidation")
end

sections.execution_approval = function()
	for _, claimed in ipairs({ false, true }) do
		local db, authority, binding = fresh({ record("approval") })
		local admitted = submit(authority, binding, reserve_request(binding, "window", 1, 1, "approval"))
		local id = admitted.result.attempt.id
		if claimed then claim(authority, binding, id) end
		edit(authority, binding, "replace-records", { records = { record("approval", { command = "changed" }) } })
		if claimed then
			refused_unchanged(db, function() return authority.update_execution(binding, id, "claimed", { stage = "submission_intent", command = "ordinary-cli" }) end, "approval changes before submission", "approval-revision-changed")
		else
			refused_unchanged(db, function() return authority.claim_execution(binding, id, native()) end, "approval changes before claim", "approval-revision-changed")
		end
		refused_unchanged(db, function() return authority.execution_record(binding, id) end, "approved record lookup after change", "approval-revision-changed")
	end
	local db, authority, binding = fresh({ record("reused") })
	local id = submit(authority, binding, reserve_request(binding, "window", 1, 1, "reused")).result.attempt.id
	claim(authority, binding, id)
	update(authority, binding, id, "claimed", { pane_reused = true })
	refused_unchanged(db, function() return authority.update_execution(binding, id, "claimed", { stage = "submission_intent", command = "ordinary-cli" }) end, "pane reuse blocks provider submission")
end

sections.admission_expiry = function()
	for _, path in ipairs({ "snapshot", "claim" }) do
		local db, authority, binding = fresh({ record("expired") })
		local id = submit(authority, binding, reserve_request(binding, "window", 1, 1, "expired")).result.attempt.id
		check(authority.execution_job(binding, id).admitted_at == db.now, "drain forwards captured admission time")
		db.now += 29
		check(snapshot(authority, binding).jobs[1].stage == "admitted", "admission remains claimable before deadline")
		db.now += 1
		if path == "claim" then check(authority.claim_execution(binding, id, native()) == nil, "expired claim supplies no execution permission")
		else snapshot(authority, binding) end
		local view = snapshot(authority, binding)
		check(view.jobs[1].stage == "unknown" and view.attempts[1].unresolved, "30 second expiry is durable blocking Unknown")
		check(not submit(authority, binding, reserve_request(binding, "window", 2, 1, "expired")).ok, "expired unknown cannot replay by another launch")
		edit(authority, binding, "resolve-attempt", { id = id, attempt_revision = view.attempt_revision })
		check(submit(authority, binding, reserve_request(binding, "window", 3, 1, "expired")).ok, "explicit resolution permits a new launch")
	end
end

sections.clear_history = function()
	local helper = record("helper", { provider = "omp", backend = "native-agent", enabled = false, prompt = "Approved normal prompt" })
	local db, authority, binding = fresh({ helper, record("active") })
	local setup = request(binding, "window", 1, 1, "start_setup", { record_id = "helper", setup_run_id = "setup-once" })
	local reply = submit(authority, binding, setup)
	check(reply.ok and reply.result.job.initial_prompt ~= helper.prompt, "disabled reviewed helper has dedicated setup prompt")
	local helper_id = reply.result.attempt.id
	claim(authority, binding, helper_id)
	update(authority, binding, helper_id, "claimed", { stage = "submission_intent", command = "omp setup" })
	update(authority, binding, helper_id, "submission_intent", { stage = "completed" }, { phase = "Exited", exit_status = 0 })
	local active_id = submit(authority, binding, reserve_request(binding, "window", 2, 1, "active")).result.attempt.id
	local before = db.peek("authority").sessions[binding.session_key]
	local view = snapshot(authority, binding)
	edit(authority, binding, "clear-history", { attempt_revision = view.attempt_revision })
	local after = db.peek("authority").sessions[binding.session_key]
	check(#after.launch.attempts == 1 and after.launch.attempts[1].id == active_id, "cleanup retains every unresolved attempt")
	check(count(after.jobs) == 1 and after.jobs[active_id] ~= nil and after.jobs[helper_id] == nil, "cleanup removes only corresponding released jobs")
	check(after.launch.next_attempt == before.launch.next_attempt, "history cleanup never reuses attempt IDs")
	check(authority.request(binding, setup), "redelivered setup request is answered from its retained reply")
	check(#snapshot(authority, binding).attempts == 1, "redelivery never starts the cleared setup run again")
	check(authority.execution_job(binding, helper_id) == nil, "removed private job cannot be recovered or claimed")
end

sections.late_completion = function()
	for _, resolve in ipairs({ false, true }) do
		local db, authority, binding = fresh({ record("late") })
		local id = submit(authority, binding, reserve_request(binding, "window", 1, 1, "late")).result.attempt.id
		claim(authority, binding, id)
		update(authority, binding, id, "claimed", { stage = "submission_intent", command = "ordinary-cli" })
		update(authority, binding, id, "submission_intent", { stage = "unknown" }, { phase = "Unknown", diagnostic = "lost host observation" })
		refused_unchanged(db, function() return authority.update_execution(binding, id, "unknown", { stage = "submission_intent", command = "ordinary-cli" }) end, "unknown may never resend")
		if resolve then
			local view = snapshot(authority, binding)
			edit(authority, binding, "resolve-attempt", { id = id, attempt_revision = view.attempt_revision })
			refused_unchanged(db, function() return authority.update_execution(binding, id, "resolved", { stage = "running" }, { phase = "Running" }) end, "resolved attempt cannot regain liveness")
		else
			update(authority, binding, id, "unknown", { stage = "running" }, { phase = "Running" })
		end
		update(authority, binding, id, if resolve then "resolved" else "running", { stage = "completed" }, { phase = "Exited", exit_status = 0 })
		local view = snapshot(authority, binding)
		check(view.jobs[1].stage == "completed" and view.attempts[1].phase == "Exited" and not view.attempts[1].unresolved, "late host completion supersedes uncertainty or explicit resolution")
	end
end

-- Stored jobs from before the record-copy removal stay valid and are stripped
-- on the next persist; a pending legacy inbox is refused rather than dropped.
sections.legacy_job = function()
	local db, authority, binding = fresh({ record("legacy") })
	local id = submit(authority, binding, reserve_request(binding, "window", 1, 1, "legacy")).result.attempt.id
	local image = db.image()
	local scope = image.authority.sessions[binding.session_key]
	local job = scope.jobs[id]
	job.record = record("legacy", { retired_field = "today's validator would reject this copy" })
	job.provider, job.account_label, job.backend, job.placement, job.cwd = nil, nil, nil, nil, nil
	scope.inbox, scope.imports, scope.setup_runs = {}, { old = {} }, { old = {} }
	local legacy_db = boundary(image)
	local legacy = modules(legacy_db)
	local view = snapshot(legacy, binding)
	check(view.jobs[1].provider == "custom" and view.jobs[1].account_label == "legacy" and view.jobs[1].cwd == "~", "legacy job keeps its admission display fields")
	claim(legacy, binding, id)
	local stored = legacy_db.peek("authority").sessions[binding.session_key]
	check(stored.jobs[id].record == nil and stored.jobs[id].provider == "custom", "next persist strips the record copy")
	check(stored.inbox == nil and stored.imports == nil and stored.setup_runs == nil, "next persist strips retired receipts")
	check(assert(legacy.execution_record(binding, id)).command == "ordinary-cli", "submission reads the approved record from current configuration")
	update(legacy, binding, id, "claimed", { stage = "submission_intent", command = "ordinary-cli" })
	local pending = copy(image)
	pending.authority.sessions[binding.session_key].inbox = { reserve_request(binding, "window", 2, 1, "legacy") }
	local pending_db = boundary(pending)
	local blocked = modules(pending_db)
	refused_unchanged(pending_db, function() return blocked.snapshot(binding) end, "legacy pending request")
	refused_unchanged(pending_db, function() return blocked.request(binding, reserve_request(binding, "window", 3, 1, "legacy")) end, "request over legacy pending request")
end

-- Ended session buckets are forgotten only against a verified live inventory.
sections.forget_sessions = function()
	local db, authority, binding = fresh({ record("kept", { duplicate_policy = "allow" }) })
	local ended = assert(authority.open("host-A", 5))
	local live = assert(authority.open("host-A", 6))
	for sequence = 1, 2 do
		local id = submit(authority, ended, reserve_request(ended, "window", sequence, 1, "kept")).result.attempt.id
		claim(authority, ended, id, 40 + sequence)
		update(authority, ended, id, "claimed", { stage = "submission_intent", command = "ordinary-cli" })
		update(authority, ended, id, "submission_intent", { stage = "completed" }, { phase = "Exited", exit_status = 0 })
	end
	local running = assert(authority.open("host-A", 7))
	local running_id = submit(authority, running, reserve_request(running, "window", 1, 1, "kept")).result.attempt.id
	claim(authority, running, running_id, 50)
	update(authority, running, running_id, "claimed", { stage = "submission_intent", command = "ordinary-cli" })
	update(authority, running, running_id, "submission_intent", { stage = "running" }, { phase = "Running" })
	for _, inventory in ipairs({ false, {}, { [6] = "yes" }, { ["6"] = true } }) do
		refused_unchanged(db, function() return authority.forget_sessions(binding, inventory or nil, true) end, "forget without a verified inventory")
	end
	local before = db.image()
	local preview = assert(authority.forget_sessions(binding, { [6] = true }, false))
	check(preview.sessions == 1 and preview.attempts == 2 and preview.bytes > 0 and preview.kept == 1, "preview counts ended sessions, attempts, bytes and active absent sessions kept")
	same(db.image(), before, "preview changes nothing")
	local writes = db.authority_writes
	local result = assert(authority.forget_sessions(binding, { [6] = true }, true))
	same(result, preview, "forget reports what it removed")
	check(db.authority_writes == writes + 1, "forget is one atomic persist")
	local sessions = db.peek("authority").sessions
	check(sessions[ended.session_key] == nil, "ended session bucket is removed")
	check(sessions[binding.session_key] ~= nil and sessions[live.session_key] ~= nil, "bound and live sessions are kept")
	check(sessions[running.session_key] ~= nil, "an absent session with a Running attempt is kept")
	check(#runtime.json.encode(before.authority) > #runtime.json.encode(db.peek("authority")), "forgetting frees stored bytes")
	local kept = assert(authority.forget_sessions(live, { [4] = true }, true))
	check(kept.sessions == 0 and db.peek("authority").sessions[live.session_key] ~= nil, "the caller's bound session is never forgotten")
end

-- Each write keeps only the 26 newest finished attempts; blocking ones stay.
sections.trim_history = function()
	local db, authority, binding = fresh({ record("many", { duplicate_policy = "allow" }) })
	local sequence = 0
	local function admit()
		sequence += 1
		local acks = if sequence > 1 then { "window/" .. tostring(sequence - 1) } else {}
		return submit(authority, binding, request(binding, "window", sequence, 1, "launch_record", { record_id = "many" }, acks)).result.attempt.id
	end
	local running = admit()
	claim(authority, binding, running, 200)
	update(authority, binding, running, "claimed", { stage = "submission_intent", command = "ordinary-cli" })
	update(authority, binding, running, "submission_intent", { stage = "running" }, { phase = "Running" })
	local unknown = admit()
	update(authority, binding, unknown, "admitted", { stage = "unknown" }, { phase = "Unknown" })
	local finished = {}
	for index = 1, 30 do
		local id = admit()
		claim(authority, binding, id, 300 + index)
		update(authority, binding, id, "claimed", { stage = "submission_intent", command = "ordinary-cli" })
		local writes = db.authority_writes
		update(authority, binding, id, "submission_intent", { stage = "completed" }, { phase = "Exited", exit_status = 0 })
		check(db.authority_writes == writes + 1, "completion and trimming commit in one atomic write")
		table.insert(finished, id)
	end
	local function kept()
		local stored = db.peek("authority").sessions[binding.session_key]
		local ids = {}
		for _, a in ipairs(stored.launch.attempts) do ids[a.id] = true end
		check(count(stored.jobs) == #stored.launch.attempts, "trimmed attempts take their jobs with them")
		return ids
	end
	local ids = kept()
	check(ids[running] and ids[unknown], "active and unresolved attempts are never trimmed")
	for index, id in ipairs(finished) do check((ids[id] == true) == (index > 4), "exactly the 26 newest finished attempts are kept") end
	local view = snapshot(authority, binding)
	edit(authority, binding, "resolve-attempt", { id = unknown, attempt_revision = view.attempt_revision })
	ids = kept()
	check(not ids[unknown] and ids[running] and ids[finished[5]], "a newly finished older attempt is trimmed in the same write")
end

-- Runs the real host Config block against the real authority; native
-- inspection reports session 4 holding the block unless `fail` is set.
local function host_block(db, authority, config)
	local pane, definition = 9, nil
	local harness = { fail = false }
	local native_cli = { inspect = function(_window, _options, callback)
		if harness.fail then callback({ status = 1, timed_out = false, stdout = "", stderr = "injected inspection failure" }, nil); return end
		callback({ status = 0, timed_out = false, stdout = runtime.json.encode({ sessions = { { id = 4, tabs = { { blocks = { { id = pane } } } } } } }) }, nil)
	end }
	local fake = setmetatable({
		kv = db.kv, on = function() end, timer = function() end, now = function() return 0 end,
		ui = { text = function(value) return { t = value } end, col = function(children) return children end, node = function() return {} end },
		block = { define = function(_, value) definition = value end },
	}, { __index = runtime })
	local chunk = assert(loadstring(runtime.fs.read(root .. "/host.luau"), "host"))
	setfenv(chunk, setmetatable({ tern = fake, require = function(name)
		if name == "./config" then return config end
		if name == "./authority" then return authority end
		if name == "./native_cli" then return native_cli end
		if name == "./host_executor" then return { install = function() end, attach = function() end } end
		error("Unexpected host dependency: " .. name)
	end }, { __index = environment }))
	chunk()
	harness.definition, harness.cx = definition, { pane = pane, save = function() end, render = function() end }
	harness.state = definition.init(harness.cx, { runtime.json.encode({ host = { name = "A" }, native_window = "w" }) }, nil)
	return harness
end

-- A freshly verified inventory forgets ended sessions automatically; failed
-- inspection and absent sessions with an active launch are left alone.
sections.auto_forget = function()
	local db = boundary()
	local authority, config = modules(db)
	local ended = assert(authority.open("host:a", 5))
	check(authority.edit(ended, 0, "replace-records", { records = { record("x") } }), "seed a launchable record")
	local active = assert(authority.open("host:a", 7))
	check(submit(authority, active, reserve_request(active, "window", 1, 1, "x")).ok, "absent session holds an active launch")
	local harness = host_block(db, authority, config)
	local state = harness.state
	check(state.binding ~= nil and state.binding.native_session == 4, "host block binds its verified session")
	local sessions = db.peek("authority").sessions
	check(sessions[ended.session_key] == nil, "verified inventory forgets the ended session automatically")
	check(sessions[active.session_key] ~= nil and sessions[state.binding.session_key] ~= nil, "bound session and absent session with an active launch are kept")
	check(state.forget.sessions == 1 and state.forget.kept == 1, "status reports what was forgotten and kept")
	local later = assert(authority.open("host:a", 8))
	harness.fail = true
	harness.definition.event(state, { ev = "action", act = "refresh" }, harness.cx)
	check(db.peek("authority").sessions[later.session_key] ~= nil, "failed inspection forgets nothing")
	harness.fail = false
	harness.definition.event(state, { ev = "action", act = "refresh" }, harness.cx)
	check(db.peek("authority").sessions[later.session_key] == nil, "the next verified inventory forgets it")
end

-- Refusals that admitted nothing reach their requester through the rendered
-- replies at once; they never shadow durable replies and stay bounded.
sections.transient_reply = function()
	local db = boundary()
	local authority, config = modules(db)
	local harness = host_block(db, authority, config)
	local definition, state, cx = harness.definition, harness.state, harness.cx
	local binding = assert(state.binding, "host block binds its authority")
	local function send(value) definition.event(state, { ev = "action", id = "main", act = "spawn.request", value = runtime.json.encode(value) }, cx) end
	local function replies()
		local text = definition.view(state, cx).main[2].t
		return runtime.json.decode(text:sub(#"SPAWN_STATE_V2 " + 1)).replies
	end
	send(request(binding, "A", 1, 0))
	check(replies()["A/1"].ok, "durable reply is rendered")
	local invalid = request(binding, "A", 2, 0); invalid.op = "bogus"
	send(invalid)
	local reply = replies()["A/2"]
	check(reply ~= nil and not reply.ok and reply.observer_id == "A" and reply.request_sequence == 2 and type(reply.error) == "string", "invalid request refusal reaches its requester at once")
	check(db.peek("authority").sessions[binding.session_key].replies["A/2"] == nil, "refusal reply is not persisted")
	local stale = request(binding, "A", 1, 0); stale.request_id = "A/stale"
	send(stale)
	check(replies()["A/stale"] ~= nil and not replies()["A/stale"].ok, "stale-sequence refusal reaches its requester")
	local reused = request(binding, "A", 1, 5)
	send(reused)
	check(replies()["A/1"].ok, "a refusal never shadows the durable reply for the same request ID")
	local foreign = request(binding, "B", 1, 0); foreign.authority_id = "other-generation"
	send(foreign)
	check(replies()["B/1"] == nil, "a refusal for another authority generation is not rendered")
	for _, item in pairs(replies()) do check(item.observer_id == "A", "only requests that were sent produce replies, each naming its requester") end
	send(request(binding, "A", 3, 0, nil, nil, { "A/1", "A/2", "A/stale" }))
	check(replies()["A/2"] == nil and replies()["A/stale"] == nil, "acknowledged refusals are released")
	for index = 1, 20 do local value = request(binding, "D", index, 0); value.op = "bogus"; send(value) end
	local refused = 0
	for _, item in pairs(replies()) do if item.observer_id == "D" then refused += 1 end end
	check(refused == 16, "refusal replies are bounded")
end

local run = assert(sections[section], "unknown authority test section: " .. section)
run()
return "PASS " .. section .. " " .. tostring(checks) .. " SPAWN authority checks"
