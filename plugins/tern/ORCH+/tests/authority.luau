-- Run in Tern's Lua runtime; exercises the real reducer and host commit boundary.
local root = ...
assert(type(root) == "string", "pass the plugin directory")
local runtime, environment = tern, getfenv()
local function clone(value) return if value == nil then nil else runtime.json.decode(runtime.json.encode(value)) end
local function store()
	local memory = { value = nil, marker = nil, fail_read = false, fail_write = false, writes = 0,
		marker_writes = 0, fail_marker_read = false, fail_marker_write = false, write_order = {} }
	-- The shared status-bar prompt keeps its own flag keys in the same kv; they are not authority state.
	local function status_key(key) return key == "status_prompt.v1" or key == "status_prompt.v1.request" end
	memory.get = function(key)
		if status_key(key) then return nil end
		if key == "authority_state_v4_original" then
			if memory.fail_backup_read then error("injected backup read failure") end
			return clone(memory.backup)
		end
		if key == "authority_state_initialized" then
			if memory.fail_marker_read then error("injected marker read failure") end
			return clone(memory.marker)
		end
		assert(key == "authority_state")
		if memory.fail_read then error("injected read failure") end
		return clone(memory.value)
	end
	memory.set = function(key, value)
		if status_key(key) then return end
		if key == "authority_state_v4_original" then
			if memory.fail_backup_write then error("injected backup write failure") end
			memory.backup = clone(value)
		elseif key == "authority_state_initialized" then
			if memory.on_marker_write then memory.on_marker_write() end
			if memory.fail_marker_write then error("injected marker write failure") end
			memory.marker = clone(value); memory.marker_writes += 1
		else
			assert(key == "authority_state")
			if memory.fail_write then error("injected durable write failure") end
			memory.value = clone(value); memory.writes += 1
		end
		table.insert(memory.write_order, key)
		if key == "authority_state" and memory.on_root_write then memory.on_root_write() end
		if key == "authority_state" and memory.partial_root_write then error("injected failure after root write") end
		-- Native kv.set deliberately returns no value.
	end
	return memory
end
local fake = table.clone(runtime)
fake.json = table.clone(runtime.json)
-- All carrier IO uses this isolated in-memory filesystem, never the runner's plugin data.
local channel_files, channel_dirs, channel_writes = {}, {}, 0
fake.plugin = table.clone(runtime.plugin); fake.plugin.data = "/fixture/plugins/orchplus"
fake.fs = {
	exists = function(path) return channel_files[path] ~= nil or channel_dirs[path] == true end,
	mkdir = function(path) channel_dirs[path] = true end,
	read = function(path, maximum)
		local bytes = assert(channel_files[path], "missing fixture file")
		assert(type(maximum) == "number" and #bytes <= maximum, "carrier reads are bounded")
		return bytes
	end,
	write = function(path, bytes) channel_files[path] = bytes; channel_writes += 1 end,
	remove = function(path) channel_files[path] = nil; channel_dirs[path] = nil end,
	list = function() error("carrier must not list directories") end,
}
fake.pane = { list = function() return {
	{ pane = 11, program = "orchplus.orchestrator", title = "Fixture one" },
	{ pane = 12, program = "orchplus.orchestrator", title = "Fixture two" },
} end }
local relay_tick
local ui_store = store(); fake.kv = ui_store
local definition
fake.block = { define = function(id, value)
	assert(id == "orchestrator" or id == "updater-recovery" or id == "form", "unexpected host block: " .. tostring(id))
	if id == "orchestrator" then definition = value end
end }
fake.on = function() end
fake.timer = function(ms, callback)
	if ms == 100 then relay_tick = callback end
	return { cancel = function() end }
end
local modules = {}
local function load(name, base)
	name = (base or "") .. name:gsub("^%./", "")
	if modules[name] ~= nil then return modules[name] end
	local chunk = assert(loadstring(runtime.fs.read(root .. "/" .. name .. ".luau"), name))
	local dir = name:match("^(.*/)")
	setfenv(chunk, setmetatable({ require = function(n) return load(n, dir) end, tern = fake }, { __index = environment }))
	local value = chunk(); modules[name] = value; return value
end
-- Exercise producer settlement racing with an already returned receive batch.
local carrier_delivery, carrier_acknowledged
local channel = load("channel/channel")
local open_channel = channel.open
channel.open = function(options)
	local endpoint, err = open_channel(options)
	if endpoint and options.plugin_id == "orchplus" then
		local receive, ack = endpoint.receive, endpoint.ack
		endpoint.receive = function(...)
			local messages, failure = receive(...)
			return if carrier_delivery then carrier_delivery(messages) else messages, failure
		end
		endpoint.ack = function(message)
			local ok, failure = ack(message)
			if ok and carrier_acknowledged then carrier_acknowledged(message) end
			return ok, failure
		end
	end
	return endpoint, err
end
local host, state = load("host"), load("state")
local checks, serial = 0, 0
local function check(condition, message) assert(condition, message); checks += 1 end
-- Captures the fence at intent creation, not in apply or retry.
local function intent(authority, kind, sid, extra)
	serial += 1
	local r = authority.registry
	local event = { kind = kind, request_id = "authority-intent-" .. serial, orch_session_id = sid,
		authority_namespace = r.authority_namespace, expected_revision = r.revision }
	for key, value in extra or {} do event[key] = value end
	return event
end
local function owned(authority, kind, sid, owner, extra)
	local event = intent(authority, kind, sid, extra)
	event.expected_owner_id, event.expected_generation = owner.owner_id, owner.generation
	return event
end
local memory = store()
local authority = host.new_authority(memory)
check(authority:load().code == "store_missing" and authority.registry == nil and memory.writes == 0, "missing store does not initialize")
check(not authority:initialize(false).ok, "first-use confirmation is mandatory")
memory.fail_write = true
check(authority:initialize(true).code == "persistence_failed" and authority.registry == nil and memory.value == nil, "failed initialization exposes nothing")
memory.fail_write = false
check(authority:initialize(true).code == "initialization_refused", "uncertain failed initialization must reload before another initialization")
check(authority:load().code == "store_missing" and memory.marker == nil, "root write failure without persistence leaves genuine first use after reread")
check(authority:initialize(true).ok and authority.registry.version == 5, "explicit initialization durably creates current authority")
check(memory.marker == true and memory.marker_writes == 1 and memory.write_order[1] == "authority_state"
	and memory.write_order[2] == "authority_state_initialized", "first use saves ROOT then marker before authority is exposed")
local namespace = authority.registry.authority_namespace
local registration = intent(authority, "register_session", "authority-session", { name = "Authority fixture" })
local response = authority:apply(registration)
check(response.ok and response.orch_session_id == "authority-session", "caller-generated session identity commits")
local session = response.orch_session_id
local binding = { host_pane_id = "42", alias_nonce = "authority-fixture-alias" }
local admission = intent(authority, "admit_controller", session, { pane_binding = binding })
local prior, writes = runtime.json.encode(authority.registry), memory.writes
memory.fail_write = true
response = authority:apply(admission)
check(response.code == "persistence_failed" and response.owner == nil, "failed grant exposes no owner result")
check(runtime.json.encode(authority.registry) == prior and memory.writes == writes and memory.value.sessions[session].controller == nil,
	"failed grant retains exact old authority")
memory.fail_write = false
response = authority:apply(admission)
check(response.ok and response.owner ~= nil, "uncommitted original intent may commit without refreshing its fence")
local owner = response.owner
writes = memory.writes; memory.fail_write = true
response = authority:apply(admission)
check(response.ok and response.code == "current_owner" and response.owner.owner_id == owner.owner_id and memory.writes == writes,
	"matching current owner observation writes nothing, even with unavailable persistence")
memory.fail_write = false
local restarted = host.new_authority(memory)
check(restarted:load().ok and restarted.registry.authority_namespace == namespace, "reload persists epoch before exposing immutable namespace")
check(restarted.registry.sessions[session].controller.phase == "uncertain", "restored ownership remains occupied")
response = restarted:apply(admission)
check(response.ok and response.code == "current_owner" and response.owner.phase == "uncertain", "lost response reports current uncertainty, not historical granted state")
authority = restarted
local competitor = intent(authority, "admit_controller", session, { pane_binding = { host_pane_id = "43", alias_nonce = "competitor" } })
check(authority:apply(competitor).code == "controller_slot_occupied", "different binding cannot take occupied slot")
local observation = owned(authority, "observe_owner", session, owner, { target = "controller", status = "unavailable", evidence = "observed" })
check(authority:apply(observation).ok and authority.registry.sessions[session].controller.owner_active == nil, "native unavailable fact never clears ownership")
check(authority:apply(owned(authority, "observe_owner", session, owner, { target = "controller", status = "verified stopped", evidence = "operator_attested",
	operator_verified = true, owner_active = false, pending_executors = 0 })).ok, "deliberate external verification remains explicit")
response = authority:apply(owned(authority, "begin_recovery", session, owner, { target = "controller" }))
check(response.ok, "revision-bound recovery begins")
local confirmation = owned(authority, "confirm_recovery", session, owner, { target = "controller", intent_id = response.intent_id,
	evidence = "operator_attested", operator_verified = true })
prior = runtime.json.encode(authority.registry); memory.fail_write = true
check(authority:apply(confirmation).code == "persistence_failed", "failed recovery commit is visible")
check(runtime.json.encode(authority.registry) == prior and memory.value.sessions[session].controller.owner_id == owner.owner_id,
	"failed recovery preserves owner and live intent")
memory.fail_write = false
check(authority:apply(confirmation).ok and authority.registry.sessions[session].controller == nil, "successful recovery clears only exact current owner")
response = authority:apply(intent(authority, "admit_controller", session, { pane_binding = binding }))
local successor = response.owner
check(response.ok and successor.generation > owner.generation, "separate fresh intent grants successor generation")
writes = memory.writes
response = authority:apply(confirmation)
check(response.ok and response.code == "not_held" and memory.writes == writes and authority.registry.sessions[session].controller.owner_id == successor.owner_id,
	"late recovery is a no-write current absence observation and cannot clear successor")
for _, kind in { "workflow_tick", "dispatch", "dispatch_reconcile", "setup_lifecycle", "installation_defaults" } do
	local stale = intent(authority, kind, session); stale.expected_revision -= 1
	check(authority:apply(stale).code == "stale_revision", "every routed mutation shares captured authority revision")
	stale.expected_revision = authority.registry.revision; stale.authority_namespace = "replaced-authority"
	check(authority:apply(stale).code == "stale_authority", "every routed mutation shares immutable authority namespace")
end
local committed = clone(memory.value)
memory.value.sessions = {}
check(authority:apply(intent(authority, "register_session", "external-conflict", { name = "No" })).code == "store_changed", "same-revision external store corruption is not overwritten")
check(authority.registry.sessions[session].controller.owner_id == successor.owner_id, "external corruption preserves in-memory ownership")
memory.value = nil
check(authority:load().code == "store_missing" and authority.status == "missing_established", "missing initialized store is not first use")
check(not authority:initialize(true).ok and memory.value == nil, "explicit first-use button cannot reset established missing store")
memory.value = committed; memory.fail_write = true
local failed_restore = host.new_authority(memory)
check(failed_restore:load().code == "persistence_failed" and failed_restore.registry == nil, "failed restored epoch save exposes no authority")
memory.fail_write = false; memory.value = { version = 1, workers = {} }
local legacy = host.new_authority(memory)
check(legacy:load().code == "migration_required" and legacy.registry == nil and memory.value.version == 1, "unsupported source quarantines unchanged")
check(not legacy:initialize(true).ok, "quarantined source cannot be silently reset")
memory.fail_read = true
check(host.new_authority(memory):load().code == "store_unreadable", "unreadable source never grants ownership")
-- Installation loss evidence survives a cold host with no saved block/view state.
do
	local disk = store(); disk.value = clone(committed); disk.fail_write = true
	local cold = host.new_authority(disk)
	check(cold:load().code == "persistence_failed" and cold.registry == nil and disk.marker == true,
		"existing ROOT gets its marker even when restored epoch persistence fails")
	disk.value = nil
	local lost = host.new_authority(disk)
	check(lost:load().code == "store_missing" and lost.status == "missing_established" and not lost:initialize(true).ok,
		"failed restore followed by cold ROOT deletion never becomes first use")
end
do
	local disk = store()
	local fresh = host.new_authority(disk)
	assert(fresh:load().code == "store_missing")
	disk.on_root_write = function() disk.fail_marker_read = true end
	check(fresh:initialize(true).code == "store_unreadable" and fresh.registry == nil and disk.value ~= nil and disk.marker == nil,
		"marker read failure after ROOT persistence exposes no initialized authority")
	local namespace = disk.value.authority_namespace
	disk.on_root_write = nil; disk.fail_marker_read = false
	check(not fresh:initialize(true).ok, "repairing marker reads alone cannot retry first-use initialization")
	check(fresh:load().ok and fresh.registry.authority_namespace == namespace and disk.marker == true,
		"explicit partial initialization reload recovers the same saved identity after marker-read repair")
	disk.fail_marker_read = true
	check(fresh:load().code == "store_unreadable" and fresh.registry == nil,
		"a failed later marker read withdraws previously exposed runtime authority")
end
do
	local disk = store()
	disk.marker = false -- Presence, not truthiness or namespace equality, is the contract.
	local cold = host.new_authority(disk)
	check(cold:load().code == "store_missing" and cold.status == "missing_established", "non-null marker alone fences cold first use")
	check(not cold:initialize(true).ok and disk.writes == 0, "cold initialized root deletion never creates a replacement")
end
for _, existing in { false, true } do
	local disk = store()
	if existing then disk.value = clone(committed) end
	local exact = clone(disk.value)
	disk.fail_marker_read = true
	local cold = host.new_authority(disk)
	check(cold:load().code == "store_unreadable" and cold.registry == nil, "unreadable marker exposes no authority, with or without a root")
	check(cold:apply({ kind = "register_session" }).code == "authority_unavailable"
		and not cold:initialize(true).ok and disk.writes == 0 and disk.marker_writes == 0,
		"marker read failure permits no initialization or authority effect")
	check(runtime.json.encode(disk.value) == runtime.json.encode(exact), "marker read failure preserves exact root")
end
do
	local disk = store()
	local fresh = host.new_authority(disk)
	assert(fresh:load().code == "store_missing")
	disk.fail_marker_read = true
	check(fresh:initialize(true).code == "store_unreadable" and disk.writes == 0, "initialization rechecks marker readability before writing ROOT")
end
do
	local disk = store()
	local fresh = host.new_authority(disk)
	assert(fresh:load().code == "store_missing")
	disk.marker = true
	check(fresh:initialize(true).code == "initialization_refused" and disk.writes == 0, "marker appearing after first-use inspection refuses initialization")
end
do
	local disk = store()
	local fresh = host.new_authority(disk)
	assert(fresh:load().code == "store_missing")
	disk.fail_marker_write = true
	disk.on_marker_write = function()
		check(disk.value ~= nil and fresh.registry == nil, "ROOT is durable but no authority is exposed during marker save")
		check(fresh:apply({ kind = "register_session" }).code == "authority_unavailable", "no effect can enter during first marker save")
	end
	check(fresh:initialize(true).code == "persistence_failed" and fresh.registry == nil and disk.marker == nil,
		"failed first marker save retains only the unexposed ROOT")
	disk.on_marker_write = nil
	local namespace, revision = disk.value.authority_namespace, disk.value.revision
	check(not fresh:initialize(true).ok and disk.writes == 1, "failed marker cannot regenerate first-use identity")
	local cold = host.new_authority(disk)
	check(cold:load().code == "persistence_failed" and cold.registry == nil and disk.writes == 1,
		"cold partial initialization remains held while marker persistence fails")
	disk.fail_marker_write = false
	check(cold:load().ok and disk.marker == true and cold.registry.authority_namespace == namespace
		and cold.registry.revision >= revision, "repaired marker reload preserves exact initialized namespace")
	disk.value = nil
	local lost = host.new_authority(disk)
	check(lost:load().code == "store_missing" and lost.status == "missing_established" and not lost:initialize(true).ok,
		"cold root deletion after repaired initialization cannot become fresh")
end
do
	local disk = store()
	local fresh = host.new_authority(disk)
	assert(fresh:load().code == "store_missing")
	disk.partial_root_write = true
	check(fresh:initialize(true).code == "persistence_failed" and fresh.registry == nil and disk.value ~= nil and disk.marker == nil,
		"ROOT save throwing after persistence exposes no authority and does not advance to marker")
	local namespace = disk.value.authority_namespace
	disk.partial_root_write = false
	local cold = host.new_authority(disk)
	check(cold:load().ok and cold.registry.authority_namespace == namespace and disk.marker == true,
		"cold partial ROOT save reload backfills marker without allocating another identity")
end
-- Backfill precedes rehydration/validation, including corrupt and legacy sources.
for _, source in { clone(committed), { invalid_authority = true }, { version = 1, workers = {} } } do
	local disk = store(); disk.value = clone(source)
	local exact = runtime.json.encode(disk.value)
	disk.fail_marker_write = true
	local cold = host.new_authority(disk)
	check(cold:load().code == "persistence_failed" and cold.registry == nil and disk.writes == 0
		and runtime.json.encode(disk.value) == exact, "backfill failure preserves exact current, corrupt or legacy source")
	check(cold:migrate("prepare", {}, {}).code == "authority_unavailable", "marker hold cannot be bypassed through migration")
	disk.fail_marker_write = false
	cold:load()
	check(disk.marker == true and disk.marker_writes == 1, "every existing source persists initialization evidence before becoming usable")
	if source.version ~= 5 then
		check(disk.writes == 0 and runtime.json.encode(disk.value) == exact, "legacy or quarantined source remains byte-identical after marker backfill")
	end
	disk.value = nil
	local lost = host.new_authority(disk)
	check(lost:load().code == "store_missing" and lost.status == "missing_established" and not lost:initialize(true).ok,
		"deleting even quarantined or legacy ROOT cannot create fresh authority in a cold VM")
end
for _, version in { 2, 3 } do
	local codec = load("wire/codec")
	local empty = state.new_registry()
	local disk = store()
	disk.value = { version = version, revision = 0, next_session_id = 0, next_owner_id = 0, execution_epoch = 1,
		sessions = {}, request_outcomes = {}, retired = {} }
	if version == 3 then disk.value.setup, disk.value.installation_defaults = clone(empty.setup), clone(empty.installation_defaults) end
	local exact = runtime.json.encode(disk.value)
	local migration = host.new_authority(disk)
	assert(migration:load().code == "migration_required")
	local namespace, source_hash = migration.migration_namespace, migration.migration_source_hash
	local normal = { schema = 1, sessions = runtime.json.array(), workers = runtime.json.array() }
	local selection = { logical_session_ids = runtime.json.array(), mailbox_handles = runtime.json.array() }
	local peer = { proof = { source_schema = 1, source_revision = 0, source_namespace = "spawn-fixture", source_sha256 = string.rep("a", 64),
		candidate_namespace = "spawn-fixture", protocol = 1, state = "ready", phase = "stable",
		managed_sha256 = assert(codec.dispatch_managed_digest(runtime.json.encode(normal))), pending_immutable = 0, blockers = 0 }, selection = selection }
	local captured = { authority_namespace = namespace, expected_revision = 0, source_sha256 = source_hash }
	check(migration.status == "migration_required" and migration.registry == nil and migration.migration_source.version == version
		and disk.writes == 0 and runtime.json.encode(disk.value) == exact,
		"validated v" .. version .. " load exposes migration without rewriting saved source")
	check(migration:migrate("inspect", captured, peer).ok
		and migration.migration_qualification.proof.source_schema == version
		and migration.migration_qualification.proof.source_sha256 == source_hash
		and source_hash == codec.sha256(codec.dispatch_source_bytes(disk.value))
		and disk.writes == 0 and runtime.json.encode(disk.value) == exact,
		"native inspection publishes the exact original v" .. version .. " source proof without preparation")
	local stale = clone(captured); stale.source_sha256 = string.rep("f", 64)
	check(migration:migrate("prepare", stale, peer).code == "stale_revision"
		and disk.writes == 0 and runtime.json.encode(disk.value) == exact, "wrong captured source digest cannot prepare legacy authority")
	disk.fail_marker_read = true
	check(migration:migrate("prepare", captured, peer).code == "store_unreadable" and migration.registry == nil
		and disk.writes == 0 and runtime.json.encode(disk.value) == exact, "migration cannot bypass a newly unreadable marker or alter the exact legacy source")
	disk.fail_marker_read = false
	check(migration:migrate("prepare", captured, peer).code == "authority_unavailable", "marker failure remains held until explicit source reload")
	assert(migration:load().code == "migration_required")
	check(migration.migration_namespace == namespace and migration.migration_source_hash == source_hash, "reload preserves migration namespace and complete source proof")
	disk.marker = nil; disk.fail_marker_write = true
	check(migration:migrate("prepare", captured, peer).code == "persistence_failed" and disk.writes == 0
		and runtime.json.encode(disk.value) == exact, "migration refuses marker backfill failure without changing source")
	disk.fail_marker_write = false
	assert(migration:load().code == "migration_required")
	disk.fail_write = true
	check(migration:migrate("prepare", captured, peer).code == "persistence_failed" and migration.registry == nil
		and disk.writes == 0 and runtime.json.encode(disk.value) == exact,
		"failed prepared-candidate write keeps the original legacy schema, settings and exact source authoritative")
	disk.fail_write = false
	check(migration:migrate("prepare", captured, peer).ok and migration.registry.authority_namespace == namespace
		and migration.registry.migration ~= nil and disk.marker == true, "successful paired preparation uses the original captured namespace/source only after marker success")
	check(migration.registry.migration.orch.source_schema == version
		and migration.registry.migration.orch.source_sha256 == source_hash and disk.writes == 1,
		"only validated preparation replaces the legacy store and retains its original schema/hash proof")
	if version == 2 then
		check(migration.registry.setup.state == "in_progress" and migration.registry.setup.review_existing
			and migration.registry.setup.readiness.state == "not_run" and migration.registry.installation_defaults.revision == 0,
			"committed v2 candidate visibly requires adoption without fabricated completion or readiness")
	end
	local cold = host.new_authority(disk)
	check(cold:load().ok and cold.registry.authority_namespace == namespace and cold.registry.migration ~= nil,
		"prepared migration cold reload retains namespace and migration hold")
end
do
	local empty = state.new_registry()
	for label, extra in {
		setup_only = { setup = clone(empty.setup) },
		defaults_only = { installation_defaults = clone(empty.installation_defaults) },
		both = { setup = clone(empty.setup), installation_defaults = clone(empty.installation_defaults) },
		explicit_null = { setup = runtime.json.null },
	} do
		local disk = store()
		disk.value = { version = 2, revision = 0, next_session_id = 0, next_owner_id = 0, execution_epoch = 1,
			sessions = {}, request_outcomes = {}, retired = {} }
		for key, value in extra do disk.value[key] = value end
		-- JSON roundtrip cloning drops explicit null; retain the malformed root field
		-- so this case actually reaches the host validator rather than testing absence.
		local get = disk.get
		disk.get = function(key)
			return if key == "authority_state" then table.clone(disk.value) else get(key)
		end
		local exact = runtime.json.encode(disk.value)
		local invalid = host.new_authority(disk); invalid:load()
		check(invalid.status == "quarantined" and invalid.registry == nil and invalid.migration_source == nil
			and not invalid:initialize(true).ok and disk.writes == 0 and runtime.json.encode(disk.value) == exact,
			label .. ": malformed v2/v3 installation hybrid stays quarantined, cannot initialize, and keeps exact saved source")
	end
end
-- Failed safety observations keep the existing fail-closed runtime guard.
local safety_store = store(); local safety = host.new_authority(safety_store)
safety:load(); assert(safety:initialize(true).ok)
assert(safety:apply(intent(safety, "register_session", "safety", { name = "Safety" })).ok)
local safety_owner = safety:apply(intent(safety, "admit_controller", "safety", { pane_binding = binding })).owner
local fact = owned(safety, "observe_owner", "safety", safety_owner, { target = "controller", status = "new native fact", evidence = "observed", owner_active = false })
safety_store.fail_write = true
check(safety:apply(fact).code == "persistence_failed" and safety.uncommitted_observation, "uncommitted safety fact fences later settlement")
safety_store.fail_write = false
check(safety:apply(owned(safety, "release_controller", "safety", safety_owner)).code == "uncommitted_observation", "repaired storage alone does not revive stale permission")
check(safety:load().ok and safety.uncommitted_observation, "store reread cannot silently clear runtime safety fence")
-- Byte reserve is independent of removed historical entry counts.
local capacity_store = store(); local capacity = host.new_authority(capacity_store)
capacity:load(); assert(capacity:initialize(true).ok)
assert(capacity:apply(intent(capacity, "register_session", "capacity", { name = "Capacity" })).ok)
local reserved = capacity:apply(intent(capacity, "reserve_coordinator", "capacity")).owner
local encoded_size = 8 * 1024 * 1024 - 512 * 1024 + 1
fake.json.encode = function(value, pretty)
	if type(value) == "table" and value.version == 5 then return string.rep("x", encoded_size) end
	return runtime.json.encode(value, pretty)
end
check(capacity:apply(intent(capacity, "register_session", "overflow", { name = "Refused" })).code == "capacity_reached", "ordinary admission cannot consume byte settlement reserve")
check(capacity:apply(owned(capacity, "bind_coordinator", "capacity", reserved, { pane_binding = binding })).ok,
	"existing reservation can finish binding inside byte reserve")
encoded_size = 8 * 1024 * 1024 + 1
check(capacity:apply(owned(capacity, "request_retirement", "capacity", reserved)).code == "capacity_reached", "settlement still respects absolute byte bound")
fake.json.encode = runtime.json.encode
-- Close is one durable scoped reclamation, never deletion before a successful write.
local closing_store = store(); local closing = host.new_authority(closing_store)
closing:load(); assert(closing:initialize(true).ok)
local captured = intent(closing, "register_session", "closing", { name = "Closing" })
assert(closing:apply(captured).ok)
assert(closing:apply(intent(closing, "register_session", "survivor", { name = "Survivor" })).ok)
local other = runtime.json.encode(closing.registry.sessions.survivor)
assert(closing:apply(intent(closing, "begin_close", "closing", { close_id = "closure" })).ok)
local close = intent(closing, "confirm_close", "closing", { close_id = "closure" })
prior = runtime.json.encode(closing.registry); closing_store.fail_write = true
check(closing:apply(close).code == "persistence_failed" and runtime.json.encode(closing.registry) == prior,
	"failed final close persists neither session removal nor partial scoped cleanup")
closing_store.fail_write = false
check(closing:apply(close).ok and closing.registry.sessions.closing == nil and closing.registry.dispatch.policies.closing == nil,
	"successful final close atomically removes session and scoped policy")
check(runtime.json.encode(closing.registry.sessions.survivor) == other, "close preserves live other session")
check(closing:apply(captured).code == "stale_revision" and closing.registry.sessions.closing == nil, "late captured registration cannot recreate closed identity")
check(closing.registry.request_outcomes == nil and closing.registry.retired == nil, "host persists no completed authority histories")
-- Real native block controls capture fences and use the same single writer.
local renders = { [11] = 0, [12] = 0 }
local function context(pane) return { pane = pane, render = function() renders[pane] += 1 end } end
local cx1, cx2 = context(11), context(12)
local view1, view2 = definition.init(cx1, {}, nil), definition.init(cx2, {}, nil)
do
	local writes, value = ui_store.writes, runtime.json.encode(ui_store.value)
	local function deliver(level, extra)
		local input = { source_nonce = view1.alias_nonce, message = "Catalog outcome", level = level,
			context = "catalog", code = "catalog_unconfirmed", detail = "Retained diagnostic" }
		for key, item in extra or {} do input[key] = item end
		definition.event(view1, { ev = "action", act = "dispatch-notice", value = runtime.json.encode(input) }, cx1)
	end
	deliver("error")
	local red_renders = renders[11]
	deliver("info")
	check(view1.notice.level == "info" and renders[11] > red_renders, "same-message severity changes redraw and clear a prior error")
	deliver("success")
	local retained = view1.notice
	deliver("error", { source_nonce = view2.alias_nonce })
	deliver("unexpected")
	check(view1.notice == retained, "foreign source or invalid severity cannot replace the current presentation")
	check(ui_store.writes == writes and runtime.json.encode(ui_store.value) == value, "notice transitions never mutate orchestration authority")
	view1.notice = nil
end
local function click(view, cx, kind)
	definition.view(view, cx)
	for token, entry in view.actions do
		if entry.kind == kind then definition.event(view, { ev = "action", act = "control", value = token }, cx); return end
	end
	error("missing actual native control: " .. kind)
end
definition.view(view1, cx1)
local defaults_token
for token, entry in view1.actions do
	if entry.kind == "setup-intent" and entry.command == "defaults" then defaults_token = token; break end
end
assert(defaults_token, "fresh native view exposes Default settings without an orchestration")
definition.event(view1, { ev = "action", act = "control", value = defaults_token }, cx1)
check(ui_store.value ~= nil and next(ui_store.value.sessions) == nil and ui_store.value.dispatch == nil
	and view1.orch_session_id == nil and view1.orchestration_result == nil
	and view1.operator_intent and view1.operator_intent.kind == "setup" and view1.operator_intent.request.command == "defaults",
	"ordinary first-use defaults initialize only guarded empty authority and open the grouped settings editor, never a ghost orchestration or worker")
definition.event(view1, { ev = "action", act = "operator-intent-done", value = runtime.json.encode({
	source_nonce = view1.alias_nonce, serial = view1.operator_intent.serial }) }, cx1)
assert(view1.config_open, "native default settings opened the settings view")
definition.event(view1, { ev = "action", act = "orchestration-create", value = runtime.json.encode({
	source_nonce = view1.alias_nonce, request_id = "create-from-native-window", name = "Native authority fixture",
	authority_namespace = ui_store.value.authority_namespace, expected_revision = ui_store.value.revision }) }, cx1)
check(view1.orchestration_result.ok and view1.orchestration_result.request_id == "create-from-native-window",
	"single native action creates and admits the requested orchestration after pre-session defaults without creating another group")
check(view1.config_open == false,
	"creating an orchestration from default settings returns to work instead of hiding conversation controls")
do
	local first_result = view1.orchestration_result
	definition.event(view1, { ev = "action", act = "orchestration-create", value = "{invalid" }, cx1)
	definition.view(view2, cx2)
	check(view1.orchestration_result == first_result,
		"creation input deserialization failure is not proof of session removal")
	definition.event(view2, { ev = "action", act = "orchestration-create", value = runtime.json.encode({
		source_nonce = view2.alias_nonce, request_id = "create-unrelated-native-window", name = "Unrelated native fixture",
		authority_namespace = ui_store.value.authority_namespace, expected_revision = ui_store.value.revision,
	}) }, cx2)
	local unrelated = view2.orchestration_result
	assert(unrelated.ok and unrelated.orch_session_id ~= first_result.orch_session_id)
	view1.orch_session_id = unrelated.orch_session_id
	definition.view(view2, cx2)
	check(view1.orchestration_result == first_result and view2.orchestration_result == unrelated,
		"other-view redraw and changed selection preserve creation results for both existing sessions")
	view1.orch_session_id = first_result.orch_session_id
end
view2.orch_session_id = view1.orch_session_id
local native_owner = ui_store.value.sessions[view1.orch_session_id].controller
check(native_owner.pane_binding.host_pane_id == "11" and native_owner.pane_binding.alias_nonce == view1.alias_nonce, "native host pane and alias bind controller")
definition.view(view2, cx2)
local available = false
for _, entry in view2.actions do if entry.kind == "admit" then available = true end end
check(not available and renders[11] > 0 and renders[12] > 0, "both native views share occupied authoritative slot")
local saved = definition.save(view1)
check(saved.orch_session_id == view1.orch_session_id and saved.registry == nil and saved.sessions == nil and saved.established == true,
	"saved block contains display binding and established evidence, never a second authority store")
local config_before, config_writes = runtime.json.encode(ui_store.value), ui_store.writes
local tick = { kind = "workflow_tick", request_id = "forged-window-tick", orch_session_id = view1.orch_session_id,
	authority_namespace = ui_store.value.authority_namespace, expected_revision = ui_store.value.revision,
	now_ms = 9999999999999, mono_ms = 9999999999999, epoch = "forged-window" }
definition.event(view1, { ev = "action", act = "dispatch-command", value = runtime.json.encode(tick) }, cx1)
check(ui_store.writes == config_writes, "window cannot supply host-only timer clock authority")
-- Document obligations settle only through the dedicated ruling route; the generic dispatch route
-- never forwards caller-supplied buffer or disk evidence.
do
	local sid = view1.orch_session_id
	local owner = ui_store.value.sessions[sid].controller
	local origin = { logical_session_id = sid, owner_id = owner.owner_id, owner_generation = owner.generation,
		host_pane_id = "11", alias_nonce = view1.alias_nonce, window_key = "", window_epoch = "forged-ruling",
		native_session_id = "2", window_host_id = "1" }
	for _, name in { "ruling_observe", "ruling_prepare", "ruling_reissue", "ruling_remote", "associate_document" } do
		local before_result, before_writes = view1.dispatch_command_result, ui_store.writes
		local input = { kind = "dispatch", command = name, request_id = "forged-" .. name, orch_session_id = sid,
			authority_namespace = ui_store.value.authority_namespace, expected_revision = ui_store.value.revision, command_seq = 1,
			controller_pane = "11", origin = origin, gate_id = "gate-1", gate_revision = 1, path = "/fixture/forged.md",
			writer = { kind = "native", pane = "11" }, evidence = { existing = true, document = "forged bytes" } }
		definition.event(view1, { ev = "action", act = "dispatch-command", value = runtime.json.encode(input) }, cx1)
		check(view1.dispatch_command_result == before_result and ui_store.writes == before_writes,
			name .. " is ignored on the generic dispatch route, which cannot carry document evidence")
	end
end
-- Explicit retirement uses the real host receiver; background closure cannot borrow it.
do
	local sid = view1.orch_session_id
	local owner = ui_store.value.sessions[sid].controller
	local origin = { logical_session_id = sid, owner_id = owner.owner_id, owner_generation = owner.generation,
		host_pane_id = "11", alias_nonce = view1.alias_nonce, window_key = "", window_epoch = "explicit-retirement",
		native_session_id = "2", window_host_id = "1" }
	local input = { source_nonce = view1.alias_nonce, origin = origin,
		event = { kind = "release_controller", request_id = "explicit-controller-retirement", orch_session_id = sid,
			authority_namespace = ui_store.value.authority_namespace, expected_revision = ui_store.value.revision,
			expected_owner_id = owner.owner_id, expected_generation = owner.generation } }
	local before, writes = runtime.json.encode(ui_store.value), ui_store.writes
	local function deliver(act, value, view, cx)
		definition.event(view or view1, { ev = "action", act = act, value = runtime.json.encode(value) }, cx or cx1)
	end
	deliver("authority-command", input)
	check(runtime.json.encode(ui_store.value) == before and ui_store.writes == writes,
		"background authority cannot retire an open-session controller")
	for _, invalid in { "other_kind", "other_session", "other_generation", "stale_revision", "other_view" } do
		local rejected = clone(input)
		rejected.event.request_id = "retirement-refusal-" .. invalid
		if invalid == "other_kind" then rejected.event.kind = "begin_close"
		elseif invalid == "other_session" then rejected.origin.logical_session_id = "foreign-session"
		elseif invalid == "other_generation" then rejected.event.expected_generation += 1
		elseif invalid == "stale_revision" then rejected.event.expected_revision -= 1 end
		deliver("authority-operator-command", rejected,
			if invalid == "other_view" then view2 else view1, if invalid == "other_view" then cx2 else cx1)
		check(runtime.json.encode(ui_store.value) == before and ui_store.writes == writes,
			invalid .. ": explicit retirement preserves current ownership and all authority bytes")
	end
	local retained = runtime.json.encode(ui_store.value.dispatch)
	deliver("authority-operator-command", input)
	check(view1.dispatch_command_result.ok and view1.dispatch_command_result.code == "owner_retired"
		and ui_store.value.sessions[sid].controller == nil and ui_store.value.sessions[sid].admitted == nil
		and runtime.json.encode(ui_store.value.dispatch) == retained,
		"the explicit native command retires only the guarded controller, without replacing ownership or discarding dispatch evidence")
	definition.view(view1, cx1)
	local ordinary_claim = false
	for _, entry in view1.actions do if entry.kind == "admit" then ordinary_claim = true end end
	check(not ordinary_claim, "retirement does not turn ordinary conversation creation back into manual controller admission")
	local admission_seq, next_session_id = ui_store.value.sessions[sid].admission_seq, ui_store.value.next_session_id
	click(view1, cx1, "advanced-toggle")
	click(view1, cx1, "admit")
	local replacement = ui_store.value.sessions[sid].controller
	check(view1.orch_session_id == sid and ui_store.value.next_session_id == next_session_id
		and ui_store.value.sessions[sid].admitted == nil and ui_store.value.sessions[sid].admission_seq == admission_seq
		and runtime.json.encode(ui_store.value.dispatch) == retained,
		"Advanced review-only recovery claims this existing orchestration without peer admission, policy changes, or worker dispatch")
	before, writes = runtime.json.encode(ui_store.value), ui_store.writes
	deliver("authority-operator-command", input)
	check(replacement.owner_id ~= owner.owner_id and replacement.generation > owner.generation
		and runtime.json.encode(ui_store.value) == before and ui_store.writes == writes,
		"a delayed old retirement cannot clear the separately claimed replacement")
	click(view1, cx1, "advanced-toggle")
end
do
	local sid = view1.orch_session_id
	local owner = ui_store.value.sessions[sid].controller
	local previous_result, previous_notice = view1.dispatch_command_result, view1.notice
	local origin = { logical_session_id = sid, owner_id = owner.owner_id, owner_generation = owner.generation,
		host_pane_id = "11", alias_nonce = view1.alias_nonce, window_key = "", window_epoch = "conversation-receipt",
		native_session_id = "2", window_host_id = "1" }
	local function command(name, id)
		definition.event(view1, { ev = "action", act = "dispatch-operator-command", value = runtime.json.encode({
			kind = "dispatch", request_id = id, orch_session_id = sid, origin = origin, controller_pane = "11",
			command = name, authority_namespace = ui_store.value.authority_namespace, expected_revision = ui_store.value.revision,
		}) }, cx1)
	end
	command("new_project", "retained-project-result")
	local retained = assert(view1.conversation_result)
	check(retained.source_nonce == view1.alias_nonce and retained.orch_session_id == sid
		and retained.result.request_id == "retained-project-result" and retained.result.command == "new_project",
		"the actual host keeps an exact scoped composer receipt, including a refused command")
	command("cleanup_notice", "unrelated-cleanup-result")
	check(view1.dispatch_command_result.request_id == "unrelated-cleanup-result" and view1.conversation_result == retained,
		"an unrelated housekeeping result cannot overwrite the composer's exact retained completion")
	view1.dispatch_command_result, view1.notice, view1.conversation_result = previous_result, previous_notice, nil
end
-- Current-window tab membership routes views only; it never allocates logical owners.
local open_command, status_open_command, files_buttons = nil, nil, 0
fake.command = function(command) if command.id == "open" then open_command = command.run elseif command.id == "status_open" then status_open_command = command.run end end
fake.files = { button = function() files_buttons += 1 end }
fake.chrome = { status = function() end }
fake.route = { link = function() end }
local native_forms = load("form_window")
local form_new, routing_forms = native_forms.new, nil
native_forms.new = function(api) local form = form_new(api); routing_forms = form; return form end
load("window")
native_forms.new = form_new
local native_session = { id = 2, host = 1, name = "B", current = true }
local host_row = { id = 1, state = "connected", panes = { 101, 202, 303, 404 }, current = true }
local other_view = { pane = 101, tab = 10, block = "orchplus.orchestrator", title = "Session A" }
local here = { pane = 202, tab = 20, block = "orchplus.orchestrator", title = "Session B" }
local unknown = { pane = 303, parked = true, block = "orchplus.orchestrator", title = "Unknown" }
local current_chat = { pane = 404, tab = 20, kind = "terminal", title = "Current session chat" }
local native_panes = { other_view }
local focused, picker, selection_callback, config_requested
local opened = 0
local placements = {}
local form_serial, form_results = 0, {}
local routing_cx = {
	window_key = function() return "routing-window" end,
	sessions = { current = function() return native_session end },
	hosts = { current = function() return host_row end, list = function() return { host_row } end },
	session = {
		sessions = function() return { { id = 1, tabs = { 10 } }, { id = 2, tabs = { 20 } } } end,
		panes = function() return native_panes end,
		pane = function(_, id) for _, pane in native_panes do if pane.pane == id then return pane end end; return nil end,
		surface = function(_, pane)
			local result = form_results[pane]; if not result then return nil end
			return { surface = { role = "plugin.orchplus.form" }, main = { k = "text", id = "main.form-result",
				p = { role = "orchplus.form.result", spans = { runtime.json.encode(result) } } } }
		end,
		event = function(_, pane, event)
			if event.act == "config-open-request" then config_requested = pane end
		end,
	},
	layout = { focus = function(_, pane) focused = pane end,
		unpark = function(_, id)
			for _, pane in native_panes do if pane.pane == id then pane.parked, pane.tab = false, 20; return true end end
			return false
		end,
		close = function(_, id) for i, pane in native_panes do if pane.pane == id then table.remove(native_panes, i); return end end end,
		move_to_new_tab = function() error("reopening must preserve the user's existing layout") end },
	new_block = function(_, kind, args, placement, options)
		if kind == "orchplus.form" then
			local source
			for _, pane in native_panes do if pane.pane == options.target then source = pane; break end end
			assert(placement == "beside" and source and source.tab == 20 and not source.parked,
				"entry decisions need a positively current-session source")
			form_serial += 1
			local id, spec = 900 + form_serial, runtime.json.decode(args[1])
			table.insert(native_panes, { pane = id, tab = 20, block = kind })
			table.insert(host_row.panes, id)
			form_results[id] = { form_nonce = spec.form_nonce, request_id = spec.request_id, phase = "ready" }
			picker = { items = spec.fields[1].options }
			selection_callback = function(choice, _, fresh)
				form_results[id] = { form_nonce = spec.form_nonce, request_id = spec.request_id,
					phase = "submitted", action = "choose", values = { choice = choice.value } }
				routing_forms.tick(fresh)
			end
			return id
		end
		assert(kind == "orchplus.orchestrator" and #args == 0)
		table.insert(placements, placement)
		opened += 1
		local id = 400 + opened
		table.insert(native_panes, { pane = id, tab = 20, block = kind, title = "Empty ORCH+ view" })
		table.insert(host_row.panes, id)
		return id
	end,
	pick = function() error("ordinary entry navigation must use a native pane form") end,
	toast = function() end,
}
local authority_writes = ui_store.writes
open_command(routing_cx)
check(opened == 1 and focused == nil and picker == nil, "session B opening never silently focuses sole session A view")
check(placements[1] == "tab", "first ORCH entry creates a fullscreen tab rather than splitting the user's active pane")
native_panes = { other_view, here }
check(files_buttons == 0, "ORCH+ registers no Files-pane button")
status_open_command(routing_cx)
check(opened == 1 and focused == 202 and config_requested == 202, "status entry reveals only known current-session view in Config mode")
open_command(routing_cx)
check(opened == 1 and focused == 202, "ordinary reopening focuses the existing arranged view without relocating it")
native_panes = { other_view, unknown, current_chat }; focused = nil
open_command(routing_cx)
check(picker ~= nil and #picker.items == 2 and picker.items[2].label == unknown.title
	and picker.items[1].label ~= other_view.title,
	"ambiguous parked membership offers an explicit native choice, excluding the proven foreign-session view")
selection_callback(picker.items[1], nil, routing_cx)
check(opened == 2 and focused ~= unknown.pane and unknown.parked,
	"choosing a new inert view never silently reveals the unknown-session candidate")
open_command(routing_cx)
unknown.tab, unknown.parked = 10, false
selection_callback(picker.items[2], nil, routing_cx)
check(focused ~= unknown.pane and ui_store.writes == authority_writes,
	"the native choice refuses newly proven foreign membership without authority writes")
unknown.tab, unknown.parked = nil, true
open_command(routing_cx)
selection_callback(picker.items[2], nil, routing_cx)
check(focused == unknown.pane and unknown.parked == false and ui_store.writes == authority_writes,
	"only the explicit current native choice may reveal an unknown-session view without granting authority")
unknown.tab, unknown.parked = nil, true
native_panes = { other_view, unknown }
local before_empty = opened
open_command(routing_cx)
check(opened == before_empty + 1 and #picker.items == 2 and unknown.parked,
	"an empty current session gets an inert fullscreen chooser source, not guessed ownership of its parked candidate")
selection_callback(picker.items[1], nil, routing_cx)
check(opened == before_empty + 1 and focused ~= unknown.pane and ui_store.writes == authority_writes,
	"the new-view choice reuses its empty carrier rather than creating an extra tab or logical owner")
do
	local before, writes = runtime.json.encode(ui_store.value), ui_store.writes
	local input = { source_nonce = view1.alias_nonce, operation = "inspect", peer = {},
		setup_origin = { host_pane_id = tostring(view1.pane), window_key = "", window_epoch = "migration-test",
			native_session_id = "2", window_host_id = "1" },
		intent = { request_id = "native-migration-stale", authority_namespace = ui_store.value.authority_namespace,
			expected_revision = ui_store.value.revision - 1 } }
	definition.event(view1, { ev = "action", act = "migration-command", value = runtime.json.encode(input) }, cx1)
	check(view1.migration_result and view1.migration_result.code == "stale_migration_peer"
		and view1.migration_result.request_id == input.intent.request_id,
		"native migration without an actual current relay receipt is refused before authority source fencing")
	view1.migration_result = nil
	definition.event(view1, { ev = "action", act = "migration-command", value = string.rep(" ", load("wire/codec").LIMITS.logical + 1) }, cx1)
	check(view1.migration_result == nil and ui_store.writes == writes and runtime.json.encode(ui_store.value) == before,
		"native migration oversize and stale source refusals never write authority")
end
do
	local original = state.new_registry()
	original.version = 4
	local backing = store()
	backing.value, backing.marker = clone(original), true
	local upgrading = host.new_authority(backing)
	backing.fail_backup_write = true
	check(upgrading:load().code == "upgrade_backup_failed" and backing.writes == 0 and backing.value.version == 4,
		"failed original preservation prevents every v5 root write")
	backing.fail_backup_write = false
	backing.backup = clone(original); backing.backup.revision += 1
	check(upgrading:load().code == "upgrade_backup_conflict" and backing.writes == 0,
		"conflicting forensic original is never overwritten")
	backing.backup = nil
	check(upgrading:load().ok and backing.value.version == 5 and backing.backup.version == 4,
		"v4 original readback precedes first v5 authority publication")
	check(backing.write_order[1] == "authority_state_v4_original" and backing.write_order[2] == "authority_state",
		"upgrade write ordering preserves source before candidate")
	local namespace, revision = upgrading.registry.authority_namespace, upgrading.registry.revision
	local archived = 0
	check(upgrading:window_readback(namespace, revision - 1, function() archived += 1; return true end).code == "stale_revision"
		and archived == 0 and backing.backup ~= nil, "stale window projection cannot archive upgrade evidence")
	check(upgrading:window_readback(namespace, revision, function() return false end).code == "upgrade_archive_failed"
		and backing.backup ~= nil, "unconfirmed private archive retains temporary original")
	check(upgrading:window_readback(namespace, revision, function(value)
		archived += 1; return runtime.json.encode(value) == runtime.json.encode(original)
	end).ok and archived == 1 and backing.backup == nil and backing.value.version == 5,
		"compatible window readback archives exact original then removes only temporary key without rollback")
end
do
	local backing = store()
	local creator = host.new_authority(backing)
	creator:load(); creator:initialize(true)
	local event = intent(creator, "register_session", "atomic-create", { name = "Named work", binding = { host_pane_id = "800", alias_nonce = "atomic-view" } })
	local before = backing.writes
	local response = creator:create(event, creator.registry.installation_defaults.revision + 1)
	check(response.code == "stale_defaults" and backing.writes == before, "changed defaults cannot create an unreviewed orchestration")
	response = creator:create(event, creator.registry.installation_defaults.revision)
	check(response.ok and backing.writes == before + 1 and creator.registry.sessions["atomic-create"].controller ~= nil,
		"one owner creation commits registration and actual admission together")
	check(not creator:create(event, creator.registry.installation_defaults.revision).ok and backing.writes == before + 1,
		"captured orchestration creation cannot replay")
end
do
	local outcome = { ok = false, code = "decision_context_changed", message = "The proposed target changed. Review the new decision.", request_id = "owner-decision" }
	view1.dispatch_command_result, view1.notice = outcome, outcome.message
	local input = { kind = "dispatch", command = "bridge_observe", request_id = "background-observation",
		orch_session_id = view1.orch_session_id, authority_namespace = ui_store.value.authority_namespace,
		expected_revision = ui_store.value.revision, command_seq = 1, controller_pane = tostring(view1.pane),
		origin = { logical_session_id = view1.orch_session_id, owner_id = "owner-1", owner_generation = 1,
			host_pane_id = tostring(view1.pane), alias_nonce = view1.alias_nonce, window_key = "", window_epoch = "outcome-window",
			native_session_id = "2", window_host_id = "1" } }
	definition.event(view1, { ev = "action", act = "dispatch-operator-command", value = runtime.json.encode(input) }, cx1)
	check(view1.dispatch_control_result ~= nil and view1.dispatch_command_result == outcome and view1.notice == outcome.message,
		"control observations including refusals cannot replace the owner's pending decision outcome")
	local saved = definition.save(view1)
	check(saved.dispatch_command_result == outcome and saved.notice == outcome.message, "owner result and explanation survive block save")
end
do
	local original_fs = fake.fs
	local reads = {}
	local bytes = "# Feature: Host research\n\n## Implementation\n### Checkpoint 1 — Research\n#### Task A1 — Gather evidence\n**INDEPENDENT**\nCollect public references.\n"
	fake.fs = table.clone(original_fs)
	fake.fs.read = function(path, maximum)
		table.insert(reads, path)
		assert(path == "/execution-host/research.md" and maximum == 1048576, "source must read bounded execution-host path")
		return bytes
	end
	local before = ui_store.writes
	definition.event(view1, { ev = "action", act = "source-discover", value = runtime.json.encode({
		source_nonce = view1.alias_nonce, request_id = "read-host-plan", path = "/execution-host/research.md" }) }, cx1)
	check(view1.source_discovery.ok and view1.source_discovery.source.path == "/execution-host/research.md"
		and #reads == 1 and ui_store.writes == before, "host source preview reads actual host plan without admitting or starting work")
	local revision = view1.source_discovery.source.revision
	definition.event(view1, { ev = "action", act = "source-discover", value = runtime.json.encode({
		source_nonce = view1.alias_nonce, request_id = "read-stale-plan", path = "/execution-host/research.md", revision = revision .. "-changed" }) }, cx1)
	check(not view1.source_discovery.ok and view1.source_discovery.source == nil and ui_store.writes == before,
		"pinned plan revision cannot silently follow changed source bytes")
	bytes = "# Feature: Large Unicode research\n\n## Implementation\n### Checkpoint 1 — Research\n"
	for index = 1, 60 do
		bytes ..= "#### Task A" .. tostring(index) .. " — Evidence\n**INDEPENDENT**\n" .. string.rep("évidence ", 180) .. "\n"
	end
	definition.event(view1, { ev = "action", act = "source-discover", value = runtime.json.encode({
		source_nonce = view1.alias_nonce, request_id = "large-plan-metadata", path = "/execution-host/research.md", metadata_only = true }) }, cx1)
	check(view1.source_discovery.ok and view1.source_discovery.source.plan.title == "Large Unicode research",
		"large supported plan metadata stays usable for passive import")
	local chunks, offset, pinned, digest = {}, 0, nil, nil
	repeat
		definition.event(view1, { ev = "action", act = "source-discover", value = runtime.json.encode({
			source_nonce = view1.alias_nonce, request_id = "source-page-" .. tostring(offset), path = "/execution-host/research.md",
			offset = offset, revision = pinned }) }, cx1)
		local page = view1.source_discovery.source_page
		check(view1.source_discovery.ok and page and page.offset == offset and utf8.len(page.bytes) ~= nil
			and #runtime.json.encode(view1.source_discovery) <= load("wire/codec").LIMITS.logical,
			"each actual host source page preserves UTF-8 and frame bounds")
		check((pinned == nil or pinned == page.revision) and (digest == nil or digest == page.sha256), "all source pages bind one exact source")
		pinned, digest = page.revision, page.sha256
		table.insert(chunks, page.bytes); offset = page.next_offset
	until offset == nil
	local assembled = table.concat(chunks)
	check(#chunks > 1 and load("wire/codec").sha256(assembled) == digest
		and #runtime.json.decode(assembled).plan.checkpoints[1].tasks == 60 and ui_store.writes == before,
		"full large source remains reachable through pinned pages without source execution")
	fake.fs = original_fs
end
do
	local Channel = load("channel/channel")
	local peer = assert(Channel.open({ plugin_id = "spawn", plugin_data = "/fixture/plugins/spawn", incarnation = "spawn-fixture-boot",
		fs = fake.fs, json = fake.json, base64 = fake.base64 }))
	local metadata = view1.spawn_relay
	local origin = { host_pane_id = "11", window_key = "", window_epoch = "relay-fixture", native_session_id = "2", window_host_id = "1" }
	local function event(act, bytes, peer_boot, lane_id)
		definition.event(view1, { ev = "action", act = "spawn_relay", value = runtime.json.encode({
			schema = 1, source_nonce = view1.alias_nonce, relay_endpoint = metadata.relay_endpoint, relay_boot = metadata.relay_boot,
			lane_id = lane_id or "setup", peer_boot = peer_boot, act = act, bytes = bytes }) }, cx1)
	end
	local function pump() assert(relay_tick, "host relay timer registered")(); end
	event("bind", runtime.json.encode(origin))
	local messages = assert(peer.receive(4))
	check(#messages == 1 and messages[1].route == "spawn.request", "real carrier receives host-generated bind")
	local descriptor = runtime.json.decode(messages[1].body)
	check(descriptor.host_pane_id == "11" and descriptor.source_nonce == view1.alias_nonce
		and descriptor.host_program == "orchplus.orchestrator" and descriptor.desktop_proof == "delegated_native_window",
		"relay binds the real ORCH panel, never fabricates SPAWN identity")
	assert(peer.ack(messages[1]))
	local source = { schema = 1, relay_endpoint = metadata.relay_endpoint, relay_boot = metadata.relay_boot, lane_id = "setup",
		host_pane_id = "11", source_nonce = view1.alias_nonce, peer_boot = "spawn-fixture-boot",
		bind_request = { id = messages[1].id, incarnation = messages[1].incarnation } }
	assert(peer.send({ peer = "orchplus", route = "spawn.source", binding = metadata.relay_endpoint .. ":setup", id = "r-1", body = runtime.json.encode(source) }))
	pump()
	check(metadata.lanes[1].peer_boot == "spawn-fixture-boot", "matching carrier incarnation establishes only the read-only peer binding")
	do
		-- Use the independently created second panel's real retained Create result.
		-- Review-only replacement of the first controller must not count as first use.
		local result = assert(view2.orchestration_result)
		view2.orch_session_id = result.orch_session_id
		definition.view(view2, cx2)
		local second = view2.spawn_relay
		local second_origin = clone(origin); second_origin.host_pane_id = "12"
		local function second_event(act, bytes, peer_boot)
			definition.event(view2, { ev = "action", act = "spawn_relay", value = runtime.json.encode({
				schema = 1, source_nonce = view2.alias_nonce, relay_endpoint = second.relay_endpoint, relay_boot = second.relay_boot,
				lane_id = "firstuse", peer_boot = peer_boot, act = act, bytes = bytes }) }, cx2)
		end
		second_event("bind", runtime.json.encode(second_origin))
		local bind = assert(peer.receive(4)[1]); assert(peer.ack(bind))
		assert(peer.send({ peer = "orchplus", route = "spawn.source", binding = second.relay_endpoint .. ":firstuse", id = "r-17",
			body = runtime.json.encode({ schema = 1, relay_endpoint = second.relay_endpoint, relay_boot = second.relay_boot, lane_id = "firstuse",
				host_pane_id = "12", source_nonce = view2.alias_nonce, peer_boot = "spawn-fixture-boot",
				bind_request = { id = bind.id, incarnation = bind.incarnation } }) }))
		pump()
		local request = { schema = 2, origin = "orchplus", op = "catalog", request_id = "creation-bootstrap-witness",
			action_id = "creation-bootstrap-witness-action", setup_origin = second_origin }
		definition.event(view2, { ev = "action", act = "setup-command", value = runtime.json.encode({
			kind = "catalog_request", source_nonce = view2.alias_nonce, request_id = "publish-bootstrap-witness",
			setup_origin = second_origin, request = request }) }, cx2)
		local creation = { request_id = result.request_id, orch_session_id = result.orch_session_id, owner_id = result.owner_id,
			generation = result.generation, authority_namespace = ui_store.value.authority_namespace, source_nonce = view2.alias_nonce }
		local stage = { schema = 1, operation = "bootstrap", request_json = runtime.json.encode(request), creation = creation }
		local domain_writes = ui_store.writes
		for _, field in { "request_id", "orch_session_id", "owner_id", "generation", "authority_namespace", "source_nonce", "extra" } do
			local wrong = clone(stage)
			wrong.creation[field] = if field == "generation" then creation.generation + 1 else "forged"
			second_event("migration", runtime.json.encode(wrong), "spawn-fixture-boot")
			check(#peer.receive(4) == 0 and ui_store.writes == domain_writes,
				field .. ": host bootstrap rejects forged or stale Create/controller identity before forwarding")
		end
		second_event("migration", runtime.json.encode(stage), "spawn-fixture-boot")
		local forwarded = peer.receive(4)
		check(#forwarded == 1 and forwarded[1].body == runtime.json.encode(stage) and ui_store.writes == domain_writes,
			"host forwards only the exact current durable native Create witness; forwarding itself never initializes either owner: "
				.. runtime.json.encode({ messages = forwarded, creation = creation, result = view2.orchestration_result,
					session = ui_store.value.sessions[view2.orch_session_id], relay = second, writes_before = domain_writes, writes_after = ui_store.writes }))
		assert(peer.ack(forwarded[1]))
		second_event("migration", runtime.json.encode(stage), "spawn-fixture-boot")
		check(#peer.receive(4) == 0, "repeated exact bootstrap stage coalesces; it never mints a replacement initialization")
	end
	local execution = "SPAWN_EXECUTION v2 " .. runtime.json.encode({ schema = 2, kind = "setup_catalog" })
	assert(peer.send({ peer = "orchplus", route = "spawn.execution", binding = metadata.relay_endpoint .. ":setup", id = "r-2", body = execution }))
	pump()
	check(view1.spawn_relay_frames.setup.execution == execution and metadata.lanes[1].messages.execution.id == "r-2",
		"relay publishes exact peer execution bytes with actual carrier provenance")
	local writes = channel_writes
	event("ack", runtime.json.encode({ route = "spawn.execution", id = "r-2", incarnation = "spawn-fixture-boot" }), "spawn-fixture-boot")
	check(channel_writes == writes, "window cannot acknowledge an execution merely by claiming it consumed a frame")
	local function callback(receipt_id, request_id)
		return runtime.json.encode({ request_json = runtime.json.encode({ schema = 2, origin = "orchplus", op = "catalog",
			request_id = request_id, action_id = request_id .. "-action", setup_origin = origin }),
			relay_execution = { id = receipt_id, incarnation = "spawn-fixture-boot" } })
	end
	local callback_a = callback("r-2", "execution-a")
	event("spawn.setup_catalog", callback_a, "spawn-fixture-boot")
	local forwarded_a = peer.receive(4)
	check(#forwarded_a == 1 and forwarded_a[1].body == callback_a, "native callback forwards only against its current execution receipt")
	assert(peer.ack(forwarded_a[1]))
	local execution_b = execution .. " "
	local execution_c = execution .. "  "
	assert(peer.send({ peer = "orchplus", route = "spawn.execution", binding = metadata.relay_endpoint .. ":setup", id = "r-3", body = execution_b }))
	assert(peer.send({ peer = "orchplus", route = "spawn.execution", binding = metadata.relay_endpoint .. ":setup", id = "r-4", body = "" }))
	assert(peer.send({ peer = "orchplus", route = "spawn.execution", binding = metadata.relay_endpoint .. ":setup", id = "r-5", body = execution_c }))
	for _ = 1, 4 do pump() end
	check(metadata.lanes[1].messages.execution.id == "r-2" and view1.spawn_relay_frames.setup.execution == execution,
		"later execution and empty-clear frames cannot replace an unconsumed published execution")
	source.consumed_execution = { id = "r-2", incarnation = "spawn-fixture-boot" }
	assert(peer.send({ peer = "orchplus", route = "spawn.source", binding = metadata.relay_endpoint .. ":setup", id = "r-6", body = runtime.json.encode(source) }))
	for _ = 1, 4 do pump() end
	check(channel_writes > writes and metadata.lanes[1].messages.execution.id == "r-3"
		and view1.spawn_relay_frames.setup.execution == execution_b,
		"exact consumed proof withdraws A and promotes the lowest queued execution serial B")
	writes = channel_writes
	event("spawn.setup_catalog", callback_a, "spawn-fixture-boot")
	check(channel_writes == writes, "exact already-sent callback A coalesces before the current B receipt guard")
	event("spawn.setup_catalog", callback("r-2", "late-execution-a"), "spawn-fixture-boot")
	check(channel_writes == writes, "a new callback carrying retired execution A cannot forward after B is published")
	local callback_b = callback("r-3", "execution-b")
	event("spawn.setup_catalog", callback_b, "spawn-fixture-boot")
	local forwarded_b = peer.receive(4)
	check(#forwarded_b == 1 and forwarded_b[1].body == callback_b, "the newly current execution B still accepts its own callback")
	assert(peer.ack(forwarded_b[1]))
	source.consumed_execution = { id = "r-3", incarnation = "spawn-fixture-boot" }
	assert(peer.send({ peer = "orchplus", route = "spawn.source", binding = metadata.relay_endpoint .. ":setup", id = "r-7", body = runtime.json.encode(source) }))
	for _ = 1, 4 do pump() end
	check(metadata.lanes[1].messages.execution.id == "r-5" and view1.spawn_relay_frames.setup.execution == execution_c,
		"queued empty clear is acknowledged only after B consumption, then the next serial C is promoted")
	event("spawn.setup_catalog", callback("r-5", "execution-c"), "spawn-fixture-boot")
	local forwarded_c = peer.receive(4)
	check(#forwarded_c == 1, "promoted C remains callable after the ordered clear")
	assert(peer.ack(forwarded_c[1]))
	source.consumed_execution = { id = "r-5", incarnation = "spawn-fixture-boot" }
	assert(peer.send({ peer = "orchplus", route = "spawn.source", binding = metadata.relay_endpoint .. ":setup", id = "r-8", body = runtime.json.encode(source) }))
	for _ = 1, 4 do pump() end
	check(metadata.lanes[1].messages.execution == nil and view1.spawn_relay_frames.setup.execution == nil,
		"final exact consumption removes both receipt and raw execution projection")
	for _ = 1, 8 do peer.settle(4); pump() end
	writes = channel_writes
	for _ = 1, 8 do pump(); peer.settle(4) end
	check(channel_writes == writes, "settled relay polling writes zero bytes")
	do
		assert(peer.send({ peer = "orchplus", route = "spawn.execution", binding = metadata.relay_endpoint .. ":setup",
			id = "r-50", body = execution }))
		for _ = 1, 8 do pump() end
		check(metadata.lanes[1].messages.execution.id == "r-50", "race predecessor is published")
		local buffered, delivered = {}, false
		carrier_delivery = function(messages)
			local forwarded = {}
			for _, message in messages do
				if table.find({ "r-50", "r-51", "r-52" }, message.id) then buffered[message.id] = message
				else table.insert(forwarded, message) end
			end
			if not delivered and buffered["r-50"] and buffered["r-51"] and buffered["r-52"] then
				delivered = true
				table.insert(forwarded, buffered["r-51"])
				table.insert(forwarded, buffered["r-50"])
				table.insert(forwarded, buffered["r-52"])
			end
			return forwarded
		end
		carrier_acknowledged = function(message)
			if message.id == "r-50" then for _ = 1, 8 do peer.settle(4) end end
		end
		source.consumed_execution = { id = "r-50", incarnation = "spawn-fixture-boot" }
		assert(peer.send({ peer = "orchplus", route = "spawn.source", binding = metadata.relay_endpoint .. ":setup",
			id = "r-51", body = runtime.json.encode(source) }))
		assert(peer.send({ peer = "orchplus", route = "spawn.execution", binding = metadata.relay_endpoint .. ":setup",
			id = "r-52", body = execution_b }))
		for _ = 1, 16 do pump() end
		carrier_delivery, carrier_acknowledged = nil, nil
		check(delivered and metadata.lanes[1].messages.execution
			and metadata.lanes[1].messages.execution.id == "r-52" and view1.spawn_relay_frames.setup.execution == execution_b,
			"consumed predecessor in the same receive batch cannot block its successor after producer settlement")
		source.consumed_execution = { id = "r-52", incarnation = "spawn-fixture-boot" }
		assert(peer.send({ peer = "orchplus", route = "spawn.source", binding = metadata.relay_endpoint .. ":setup",
			id = "r-53", body = runtime.json.encode(source) }))
		for _ = 1, 8 do pump(); peer.settle(4) end
	end
	do
		local serial = 100
		local revocation_source = table.clone(source)
		revocation_source.consumed_execution = nil
		local domain_writes = ui_store.writes
		local function publish(route, body, id)
			if not id then serial += 1; id = "r-" .. tostring(serial) end
			assert(peer.send({ peer = "orchplus", route = route, binding = metadata.relay_endpoint .. ":setup",
				id = id, body = body }))
			for _ = 1, 4 do pump(); peer.settle(4) end
			return id
		end
		local function revoke(id, override)
			local proof = table.clone(revocation_source)
			proof.revoked_execution = { id = id, incarnation = "spawn-fixture-boot" }
			if override then override(proof) end
			return publish("spawn.source", runtime.json.encode(proof))
		end
		local function consume(id)
			local proof = table.clone(revocation_source)
			proof.consumed_execution = { id = id, incarnation = "spawn-fixture-boot" }
			publish("spawn.source", runtime.json.encode(proof))
		end
		local control = "SPAWN_EXECUTION v2 " .. runtime.json.encode({ schema = 2, kind = "control_authorize" })
		local first = publish("spawn.execution", control)
		for _, field in { "source_nonce", "relay_boot", "lane_id", "host_pane_id" } do
			revoke(first, function(proof) proof[field] = "foreign" end)
			check(metadata.lanes[1].messages.execution.id == first,
				field .. ": foreign source cannot revoke the retained private control challenge")
		end
		revoke(first, function(proof) proof.bind_request = { id = "foreign", incarnation = metadata.relay_boot } end)
		check(metadata.lanes[1].messages.execution.id == first, "foreign bind receipt cannot revoke a control execution")
		revoke(first, function(proof) proof.revoked_execution.incarnation = "foreign-boot" end)
		check(metadata.lanes[1].messages.execution.id == first, "revocation requires the exact execution incarnation")
		publish("spawn.execution", "")
		local successor = publish("spawn.execution", execution)
		check(metadata.lanes[1].messages.execution.id == first, "queued blank cannot retire a control challenge without proof")
		revoke(first)
		check(metadata.lanes[1].messages.execution.id == successor and view1.spawn_relay_frames.setup.execution == execution,
			"exact control revocation drains the queued blank and promotes the successor")
		writes = channel_writes
		event("spawn.control_authorize", callback(first, "retired-control"), "spawn-fixture-boot")
		check(channel_writes == writes and ui_store.writes == domain_writes,
			"retiring a control carrier never forwards its stale callback or changes domain authority")
		consume(successor)
		local foreign_receipt = publish("spawn.current", control)
		revoke(foreign_receipt)
		check(metadata.lanes[1].messages.current.id == foreign_receipt and metadata.lanes[1].messages.execution == nil,
			"control-shaped bytes on a foreign route cannot be revoked as an execution receipt")
		event("ack", runtime.json.encode({ route = "spawn.current", id = foreign_receipt,
			incarnation = "spawn-fixture-boot" }), "spawn-fixture-boot")
		for _, kind in { "launch", "wake", "stop", "result", "setup_catalog" } do
			local frame = "SPAWN_EXECUTION v2 " .. runtime.json.encode({ schema = 2, kind = kind })
			local id = publish("spawn.execution", frame)
			revoke(id)
			check(metadata.lanes[1].messages.execution.id == id and view1.spawn_relay_frames.setup.execution == frame,
				kind .. ": producer revocation cannot retire a non-control execution")
			consume(id)
		end
		local malformed = publish("spawn.execution", "SPAWN_EXECUTION v2 not-json")
		revoke(malformed)
		check(metadata.lanes[1].messages.execution.id == malformed, "revocation must decode the retained execution body")
		consume(malformed)
		-- The proof is delivered while its target is absent. Its source envelope has
		-- a later producer serial, as when carrier delivery reorders two sends.
		serial += 1
		local early_target = "r-" .. tostring(serial)
		revoke(early_target)
		check(metadata.lanes[1].messages.execution == nil, "early proof cannot manufacture or discard an execution")
		for _ = 1, 8 do peer.settle(4); pump() end
		publish("spawn.execution", control, early_target)
		for _ = 1, 8 do pump(); peer.settle(4) end
		check(metadata.lanes[1].messages.execution == nil and view1.spawn_relay_frames.setup.execution == nil,
			"unacknowledged early proof reconciles its exact later-arriving control carrier")
		local final = publish("spawn.execution", execution)
		check(metadata.lanes[1].messages.execution.id == final and ui_store.writes == domain_writes,
			"out-of-order revocation leaves the following unrelated native execution intact")
		consume(final)
	end
	local invalid = table.clone(source); invalid.source_nonce = "other-panel"
	assert(peer.send({ peer = "orchplus", route = "spawn.source", binding = metadata.relay_endpoint .. ":setup", id = "r-9", body = runtime.json.encode(invalid) }))
	pump()
	check(metadata.lanes[1].error == "invalid_peer_source" and view1.spawn_relay_frames.setup.execution == nil,
		"wrong native source proof is held without replacing peer frames")
	assert(peer.send({ peer = "orchplus", route = "spawn.execution", binding = "closed-panel:old-lane", id = "r-10", body = execution }))
	pump()
	local disposed = peer.settle(4)
	check(disposed > 0 and view1.spawn_relay_frames.setup.execution == nil,
		"unbound execution projection drains by rejection without publishing or claiming its managed effect settled")
	event("release", "{}", "spawn-fixture-boot")
	local requests = peer.receive(4)
	local release
	for _, request in requests do
		if request.binding == metadata.relay_endpoint .. ":setup:release:spawn-fixture-boot" then release = request end
	end
	check(release ~= nil and #metadata.lanes == 1, "requesting release alone does not retire a relay lane")
	assert(peer.ack(release))
	local held_error = metadata.lanes[1].error
	assert(peer.send({ peer = "orchplus", route = "spawn.source", binding = metadata.relay_endpoint .. ":setup", id = "r-11",
		body = runtime.json.encode({ schema = 1, kind = "held", relay_endpoint = metadata.relay_endpoint, lane_id = "setup",
			peer_boot = "spawn-fixture-boot", error = "release_held", rejected_message = { id = release.id, incarnation = release.incarnation } }) }))
	pump()
	check(metadata.lanes[1].release_held == true and metadata.lanes[1].error == held_error and #metadata.releases == 0,
		"causal inertness refusal keeps the lane live without adding or clearing unrelated holds")
	event("release", "{}", "spawn-fixture-boot")
	local retried = peer.receive(4)
	local fresh_release
	for _, request in retried do
		if request.binding == release.binding and request.id ~= release.id then fresh_release = request end
	end
	check(fresh_release ~= nil, "a positively refused release can later perform a new read-only inertness check")
	assert(peer.ack(fresh_release))
	source.released = true
	assert(peer.send({ peer = "orchplus", route = "spawn.source", binding = metadata.relay_endpoint .. ":setup", id = "r-12", body = runtime.json.encode(source) }))
	pump()
	check(#metadata.lanes == 0 and view1.spawn_relay_frames.setup == nil, "exact peer positive inert-release proof retires only its lane")
	check(#metadata.releases == 1 and metadata.releases[1].lane_id == "setup" and metadata.releases[1].peer_boot == "spawn-fixture-boot",
		"window receives positive release evidence rather than inferring retirement from lane absence")
	event("release_ack", "{}", "wrong-peer-boot")
	check(#metadata.releases == 1, "release receipt acknowledgement rejects a different peer incarnation")
	local before_ack = channel_writes
	event("release_ack", "{}", "spawn-fixture-boot")
	check(#metadata.releases == 0 and channel_writes == before_ack, "exact window acknowledgement removes only ephemeral release evidence")
	event("bind", runtime.json.encode(origin), nil, "reconnect")
	local first_bind = peer.receive(4)[1]
	assert(first_bind and peer.ack(first_bind))
	local reconnect_source = table.clone(source)
	reconnect_source.lane_id, reconnect_source.released, reconnect_source.consumed_execution = "reconnect", nil, nil
	reconnect_source.bind_request = { id = first_bind.id, incarnation = first_bind.incarnation }
	assert(peer.send({ peer = "orchplus", route = "spawn.source", binding = metadata.relay_endpoint .. ":reconnect", id = "r-13", body = runtime.json.encode(reconnect_source) }))
	pump()
	event("rebind", runtime.json.encode(origin), "spawn-fixture-boot", "reconnect")
	check(metadata.lanes[1].peer_boot == nil and metadata.lanes[1].bind_id == nil and next(view1.spawn_relay_frames.reconnect) == nil,
		"explicit rebind withdraws old projections without replaying any native effect")
	local fresh_bind = peer.receive(4)[1]
	check(fresh_bind and fresh_bind.id ~= first_bind.id and fresh_bind.body == first_bind.body,
		"rebind sends a new causal observation of the same immutable source descriptor")
	assert(peer.ack(fresh_bind))
	assert(peer.send({ peer = "orchplus", route = "spawn.source", binding = metadata.relay_endpoint .. ":reconnect", id = "r-14", body = runtime.json.encode(reconnect_source) }))
	pump()
	check(metadata.lanes[1].peer_boot == nil and metadata.lanes[1].bind_id == nil, "old answered bind proof cannot satisfy a later explicit rebind")
	reconnect_source.bind_request = { id = fresh_bind.id, incarnation = fresh_bind.incarnation }
	assert(peer.send({ peer = "orchplus", route = "spawn.source", binding = metadata.relay_endpoint .. ":reconnect", id = "r-15", body = runtime.json.encode(reconnect_source) }))
	pump()
	check(metadata.lanes[1].peer_boot == "spawn-fixture-boot" and metadata.lanes[1].bind_id == fresh_bind.id
		and next(view1.spawn_relay_frames.reconnect) == nil,
		"only the fresh exact bind receipt restores connection identity, not old execution projections")
	assert(peer.send({ peer = "orchplus", route = "spawn.execution", binding = metadata.relay_endpoint .. ":reconnect",
		id = "r-16", body = execution }))
	pump()
	check(metadata.lanes[1].messages.execution.id == "r-16",
		"an unconsumed execution remains published before its producer restarts")
	-- Stop the old producer before opening its replacement; never run two host writers.
	peer = assert(Channel.open({ plugin_id = "spawn", plugin_data = "/fixture/plugins/spawn", incarnation = "spawn-fixture-restarted",
		fs = fake.fs, json = fake.json, base64 = fake.base64 }))
	assert(peer.send({ peer = "orchplus", route = "spawn.source", binding = "spawn-host", id = "r-1",
		priority = "settlement", body = runtime.json.encode({ schema = 1, kind = "host_boot", peer_boot = "spawn-fixture-restarted" }) }))
	for _ = 1, 4 do pump() end
	check(metadata.lanes[1].peer_boot == nil and next(view1.spawn_relay_frames.reconnect) == nil,
		"fresh host announcement withdraws old execution projections without claiming their effects settled")
	event("rebind", runtime.json.encode(origin), "spawn-fixture-boot", "reconnect")
	local restarted_bind
	for _, request in peer.receive(4) do
		if request.route == "spawn.request" and request.binding == fresh_bind.binding then restarted_bind = request end
	end
	assert(restarted_bind and peer.ack(restarted_bind))
	reconnect_source.peer_boot = "spawn-fixture-restarted"
	reconnect_source.bind_request = { id = restarted_bind.id, incarnation = restarted_bind.incarnation }
	assert(peer.send({ peer = "orchplus", route = "spawn.source", binding = metadata.relay_endpoint .. ":reconnect",
		id = "r-2", body = runtime.json.encode(reconnect_source) }))
	pump()
	assert(peer.send({ peer = "orchplus", route = "spawn.execution", binding = metadata.relay_endpoint .. ":reconnect",
		id = "r-3", body = execution_b }))
	for _ = 1, 4 do pump() end
	check(metadata.lanes[1].messages.execution and metadata.lanes[1].messages.execution.id == "r-3"
		and metadata.lanes[1].messages.execution.incarnation == "spawn-fixture-restarted"
		and view1.spawn_relay_frames.reconnect.execution == execution_b,
		"fresh causal binding promotes only the new producer's execution without requiring forged cross-boot consumption")
	do
		local codec = load("wire/codec")
		event("bind", runtime.json.encode(origin), nil, "migration")
		local bind = peer.receive(4)[1]
		assert(bind and peer.ack(bind))
		local migration_source = clone(reconnect_source)
		migration_source.lane_id = "migration"
		migration_source.bind_request = { id = bind.id, incarnation = bind.incarnation }
		assert(peer.send({ peer = "orchplus", route = "spawn.source", binding = metadata.relay_endpoint .. ":migration",
			id = "r-4", body = runtime.json.encode(migration_source) }))
		for _ = 1, 4 do pump() end
		local request = { schema = 2, origin = "orchplus", op = "catalog", request_id = "paired-migration-source",
			action_id = "paired-migration-source-action", setup_origin = origin }
		local request_json = runtime.json.encode(request)
		definition.event(view1, { ev = "action", act = "setup-command", value = runtime.json.encode({
			kind = "catalog_request", source_nonce = view1.alias_nonce, request_id = "publish-migration-request",
			request = request, setup_origin = origin }) }, cx1)
		local stage = { schema = 1, request_json = request_json, operation = "source" }
		local before_stage = channel_writes
		for _, invalid_stage in {
			{ schema = 1, request_json = request_json, operation = "prepare" },
			{ schema = 1, request_json = request_json, operation = "source", peer = {} },
			{ schema = 1, request_json = request_json, operation = "source", arbitrary = true },
		} do event("migration", runtime.json.encode(invalid_stage), "spawn-fixture-restarted", "migration") end
		check(channel_writes == before_stage, "migration accepts only the closed staged native catalog request and phase prerequisites")
		event("migration", runtime.json.encode(stage), "spawn-fixture-restarted", "migration")
		local staged = peer.receive(4)
		check(#staged == 1 and staged[1].body == runtime.json.encode(stage),
			"private migration source observation uses the existing lane without issuing an ordinary catalog request")
		assert(peer.ack(staged[1]))
		local execution_frame = "SPAWN_EXECUTION v2 " .. runtime.json.encode({ schema = 2, kind = "migration",
			request = request, request_json = request_json, operation = "source", nonce = "migration-native-nonce",
			boot = "spawn-fixture-restarted", deadline = 1000 })
		assert(peer.send({ peer = "orchplus", route = "spawn.execution", binding = metadata.relay_endpoint .. ":migration",
			id = "r-5", body = execution_frame }))
		for _ = 1, 4 do pump() end
		local callback = { request_json = request_json, nonce = "migration-native-nonce", executor_id = "migration-executor" }
		before_stage = channel_writes
		event("spawn.migration", runtime.json.encode(callback), "spawn-fixture-restarted", "migration")
		check(channel_writes == before_stage, "native migration callback cannot bypass the current execution receipt fence")
		callback.relay_execution = { id = "r-5", incarnation = "spawn-fixture-restarted" }
		event("spawn.migration", runtime.json.encode(callback), "spawn-fixture-restarted", "migration")
		local callbacks = peer.receive(4)
		check(#callbacks == 1 and callbacks[1].body == runtime.json.encode(callback), "exact current migration callback is forwarded unchanged")
		assert(peer.ack(callbacks[1]))
		-- Controlled SPAWN-owner qualification fixture; the real ORCH reducer still
		-- independently derives and validates its own complete managed identities.
		local selection = load("dispatch").migration_selection(ui_store.value)
		local own = assert(state.migration_proof(ui_store.value, selection))
		local peer_proof = clone(own)
		peer_proof.source_schema, peer_proof.source_revision = 2, 1
		peer_proof.source_namespace, peer_proof.candidate_namespace = "paired-spawn-fixture", "paired-spawn-fixture"
		peer_proof.source_sha256 = string.rep("a", 64)
		local qualification = { proof = peer_proof, selection = selection }
		local current_source = { protocol = 2, phase = "stable", spawn_namespace = "paired-spawn-fixture",
			authority_revision = 1, qualification = qualification }
		local current = clone(current_source)
		current.migration_response = { request_json = request_json, operation = "source",
			response = { ok = true, value = qualification }, source = clone(current_source) }
		local function publish(value, id)
			assert(peer.send({ peer = "orchplus", route = "spawn.current", binding = metadata.relay_endpoint .. ":migration",
				id = id, body = runtime.json.encode(value) }))
			for _ = 1, 4 do pump() end
		end
		publish(current, "r-6")
		migration_source.consumed_execution = { id = "r-5", incarnation = "spawn-fixture-restarted" }
		assert(peer.send({ peer = "orchplus", route = "spawn.source", binding = metadata.relay_endpoint .. ":migration",
			id = "r-7", body = runtime.json.encode(migration_source) }))
		for _ = 1, 4 do pump() end
		local input = { source_nonce = view1.alias_nonce, operation = "prepare", setup_origin = origin, peer = qualification,
			intent = { request_id = "paired-orch-prepare", authority_namespace = ui_store.value.authority_namespace,
				expected_revision = ui_store.value.revision },
			relay_proof = { relay_endpoint = metadata.relay_endpoint, lane_id = "migration", peer_boot = "spawn-fixture-restarted",
				receipt = { id = "wrong-receipt", incarnation = "spawn-fixture-restarted" } } }
		local before, writes = runtime.json.encode(ui_store.value), ui_store.writes
		local function prepare()
			definition.event(view1, { ev = "action", act = "migration-command", value = runtime.json.encode(input) }, cx1)
		end
		local function refused(message)
			prepare()
			check(view1.migration_result.code == "stale_migration_peer" and ui_store.writes == writes
				and runtime.json.encode(ui_store.value) == before, message)
		end
		refused("ORCH preparation cannot substitute a different current carrier receipt")
		local refusal = clone(current)
		refusal.migration_response.response = { ok = false, error = "Source was refused", disposition = "refused" }
		publish(refusal, "r-8")
		input.relay_proof.receipt.id = "r-8"
		refused("a genuine refused SPAWN result cannot advance ORCH preparation even when old source qualification remains")
		local advanced = clone(current); advanced.authority_revision += 1
		publish(advanced, "r-9")
		input.relay_proof.receipt.id = "r-9"
		refused("a newer outer SPAWN source cannot reuse nested qualification captured before that source changed")
		publish(current, "r-10")
		input.relay_proof.receipt.id = "r-10"
		input.peer = clone(qualification); input.peer.proof.source_sha256 = string.rep("b", 64)
		refused("caller-supplied qualification must equal the successful actual current source")
		input.peer = qualification
		-- Replace the producer, not its authority: delayed old-proof preparation is
		-- refused until a fresh causal binding and source observation are available.
		peer = assert(Channel.open({ plugin_id = "spawn", plugin_data = "/fixture/plugins/spawn", incarnation = "spawn-fixture-migration-restarted",
			fs = fake.fs, json = fake.json, base64 = fake.base64 }))
		assert(peer.send({ peer = "orchplus", route = "spawn.source", binding = "spawn-host", id = "r-1",
			priority = "settlement", body = runtime.json.encode({ schema = 1, kind = "host_boot", peer_boot = "spawn-fixture-migration-restarted" }) }))
		for _ = 1, 8 do pump() end
		refused("delayed ORCH preparation after SPAWN reload cannot adopt the previous producer's successful source")
		event("rebind", runtime.json.encode(origin), "spawn-fixture-restarted", "migration")
		local rebound = peer.receive(4)[1]
		assert(rebound and peer.ack(rebound))
		migration_source.peer_boot, migration_source.consumed_execution = "spawn-fixture-migration-restarted", nil
		migration_source.bind_request = { id = rebound.id, incarnation = rebound.incarnation }
		assert(peer.send({ peer = "orchplus", route = "spawn.source", binding = metadata.relay_endpoint .. ":migration",
			id = "r-2", body = runtime.json.encode(migration_source) }))
		for _ = 1, 4 do pump() end
		event("migration", runtime.json.encode(stage), "spawn-fixture-migration-restarted", "migration")
		local observed = peer.receive(4)[1]
		assert(observed and peer.ack(observed))
		publish(current, "r-3")
		input.relay_proof.peer_boot = "spawn-fixture-migration-restarted"
		input.relay_proof.receipt = { id = "r-3", incarnation = "spawn-fixture-migration-restarted" }
		refused("a fresh migration receipt cannot bypass another lane's unresolved reload hold")
		event("rebind", runtime.json.encode(origin), "spawn-fixture-restarted", "reconnect")
		local other_bind = peer.receive(4)[1]
		assert(other_bind and peer.ack(other_bind))
		reconnect_source.peer_boot, reconnect_source.consumed_execution = "spawn-fixture-migration-restarted", nil
		reconnect_source.bind_request = { id = other_bind.id, incarnation = other_bind.incarnation }
		assert(peer.send({ peer = "orchplus", route = "spawn.source", binding = metadata.relay_endpoint .. ":reconnect",
			id = "r-4", body = runtime.json.encode(reconnect_source) }))
		for _ = 1, 4 do pump() end
		prepare()
		check(view1.migration_result.ok and view1.migration_result.code == "peer_qualified"
			and ui_store.writes == writes + 1 and ui_store.value.compatibility.spawn_namespace == "paired-spawn-fixture",
			"the exact fresh successful current source reaches real ORCH preparation and persists qualification once")
	end
	local usage = assert(Channel.open({ plugin_id = "usage", plugin_data = "/fixture/plugins/usage", incarnation = "usage-fixture-boot",
		fs = fake.fs, json = fake.json, base64 = fake.base64 }))
	local function usage_event(act, bytes, kind)
		definition.event(view1, { ev = "action", act = "usage_relay", value = runtime.json.encode({
			schema = 1, source_nonce = view1.alias_nonce, relay_endpoint = view1.usage_relay.relay_endpoint,
			relay_boot = view1.usage_relay.relay_boot, kind = kind or "display", act = act, bytes = bytes }) }, cx1)
	end
	usage_event("request", runtime.json.encode({ version = 1, request_id = "display-current-read", op = "snapshot" }))
	local reads = usage.receive(4)
	check(#reads == 1 and reads[1].route == "usage.display.request", "USAGE receives unchanged read protocol on its fixed peer route")
	assert(usage.ack(reads[1]))
	local response_bytes = runtime.json.encode({ version = 1, request_id = "display-current-read", op = "snapshot",
		ok = false, status = "disabled", display_only = true, records = {} })
	assert(usage.send({ peer = "orchplus", route = "usage.display.response", binding = reads[1].binding, id = "u-1", body = response_bytes }))
	pump()
	check(view1.usage_relay_frames.display == response_bytes and view1.usage_relay.display.peer_boot == "usage-fixture-boot",
		"USAGE response requires exact causal binding and request ID and retains actual peer incarnation")
	local proof = view1.usage_relay.display.message
	usage_event("ack", runtime.json.encode({ route = proof.route, id = proof.id, incarnation = proof.incarnation }))
	for _ = 1, 8 do usage.settle(4); peer.settle(4); pump() end
	writes = channel_writes
	for _ = 1, 8 do pump(); usage.settle(4); peer.settle(4) end
	check(channel_writes == writes, "fully acknowledged SPAWN and USAGE lanes have zero idle writes")
	local codec = load("wire/codec")
	local observational = { schema = 2, op = "owner_status", request_id = "pairing-read", action_id = "pairing-read-action",
		category = "migration_blocked", status = "rejected", authority_namespace = "orch-read", spawn_namespace = "spawn-read",
		authority_revision = 0, logical_session_id = "read-session", admission_seq = 1, controller_generation = 1,
		origin_binding = { host_pane_id = "11", alias_nonce = view1.alias_nonce, window_key = "", window_epoch = "relay-fixture",
			native_session_id = "2", window_host_id = "1", logical_session_id = "read-session", owner_id = "read-owner", owner_generation = 1 },
		error = { code = "migration_blocked", message = "Paired managed stores are not qualified" } }
	local read_bytes = assert(codec.encode_dispatch_response(observational))
	local domain_writes = ui_store.writes
	assert(peer.send({ peer = "orchplus", route = "spawn.response", binding = metadata.relay_endpoint .. ":reconnect",
		id = "r-5", body = read_bytes }))
	pump()
	event("ack", runtime.json.encode({ route = "spawn.response", id = "r-5", incarnation = "spawn-fixture-migration-restarted" }),
		"spawn-fixture-migration-restarted", "reconnect")
	check(peer.settle(4) > 0 and not metadata.held and ui_store.writes == domain_writes,
		"a canonical migration-blocked owner_status is a read refusal, not an uncorrelated effect; its exact window receipt can drain")
	assert(peer.send({ peer = "orchplus", route = "spawn.response", binding = "closed-panel:old-lane",
		id = "readonly-old", body = read_bytes }))
	pump()
	check(peer.settle(4) > 0 and not metadata.held and ui_store.writes == domain_writes,
		"old complete read responses drain by classification without adopting state or requiring a new outgoing bind")
	do
		local lane_id, peer_boot = "reconnect", "spawn-fixture-migration-restarted"
		local binding = metadata.relay_endpoint .. ":" .. lane_id
		local serial, last_response = 5, nil
		local function publish(route, bytes)
			serial += 1
			local receipt, failure = peer.send({ peer = "orchplus", route = route, binding = binding, id = "r-" .. serial, body = bytes })
			assert(receipt, "consecutive observations must not exhaust the real bounded carrier: " .. tostring(failure and failure.code))
			for _ = 1, 8 do pump(); peer.settle(4) end
			return receipt
		end
		local catalog = clone(observational)
		catalog.op, catalog.category, catalog.status, catalog.error = "catalog", "current_result", "catalog", nil
		catalog.payload = { catalog_version = 2, namespace = "spawn-read", host_key = "fixture-host", config_revision = 0, revision = 0,
			setup = { schema = 1, state = "completed", config_revision = 0, readiness = { state = "not_run", config_revision = 0, summary = "" } },
			records = runtime.json.array() }
		for index = 1, 32 do
			catalog.request_id, catalog.action_id, catalog.request_serial = "catalog-" .. index, "catalog-action-" .. index, index
			publish("spawn.current", runtime.json.encode({ protocol = 2, authority_revision = index }))
			last_response = publish("spawn.response", assert(codec.encode_dispatch_response(catalog)))
		end
		check(view1.spawn_relay_frames[lane_id].response == codec.encode_dispatch_response(catalog) and ui_store.writes == domain_writes,
			"more than a carrier's lifetime of consecutive catalog/current projections drains superseded observations without changing authority")
		local function ack_path(receipt)
			return string.format("/fixture/plugins/orchplus/plugin-channel-v1/a-spawn-%03d.json", receipt.slot)
		end
		check(channel_files[ack_path(last_response)] == nil,
			"the latest nonempty catalog remains unacknowledged until its consumer supplies the exact receipt")
		event("ack", runtime.json.encode({ route = "spawn.response", id = last_response.id, incarnation = peer_boot }), peer_boot, lane_id)
		check(channel_files[ack_path(last_response)] ~= nil, "the exact current read response can settle independently of picker lifetime")
		for _ = 1, 8 do pump(); peer.settle(4) end
		local large = clone(catalog)
		large.payload.records = runtime.json.array()
		for index = 1, 10 do
			table.insert(large.payload.records, { id = "wide-native-" .. index, revision = 0, eligible = true,
				capabilities = runtime.json.array(), unsupported = runtime.json.array(), account_label = string.rep("a", 360) })
		end
		large.payload.records[1].selector_evidence = "x"
		local original = assert(codec.encode_dispatch_response(large))
		large.payload.records[1].selector_evidence ..= string.rep("x", 7647 - #original)
		original = assert(codec.encode_dispatch_response(large))
		assert(#original == 7647, "wide-status fixture retains an ordinary 7647-byte original")
		local status = clone(large)
		status.op, status.status, status.request_serial = "status", "found", nil
		status.request_id, status.action_id, status.payload = "wide-retained-read", "wide-retained-read-action", { outcome = large }
		local wide = assert(codec.encode_dispatch_response(status))
		assert(#wide > codec.LIMITS.bridge and #wide <= codec.LIMITS.bridge_status,
			"the actual retained-status envelope exceeds only the ordinary response bound")
		local wide_receipt = publish("spawn.response", wide)
		check(view1.spawn_relay_frames[lane_id].response == wide and channel_files[ack_path(wide_receipt)] == nil,
			"the host publishes a wide status unchanged and never infers its consumer ACK")
		event("ack", runtime.json.encode({ route = "spawn.response", id = "wrong-wide-receipt", incarnation = peer_boot }), peer_boot, lane_id)
		check(channel_files[ack_path(wide_receipt)] == nil, "a different receipt cannot retire the wide retained-status response")
		event("ack", runtime.json.encode({ route = "spawn.response", id = wide_receipt.id, incarnation = peer_boot }), peer_boot, lane_id)
		check(channel_files[ack_path(wide_receipt)] ~= nil and not metadata.held and ui_store.writes == domain_writes,
			"the exact wide read receipt drains without adopting its original outcome or changing authority")
		for _ = 1, 8 do pump(); peer.settle(4) end
		assert(peer.send({ peer = "orchplus", route = "spawn.response", binding = "closed-panel:wide-read",
			id = "wide-readonly-old", body = wide }))
		pump()
		check(peer.settle(4) > 0 and not metadata.held and ui_store.writes == domain_writes,
			"an unbound but fully valid wide status is classified as inspection, never an unresolved native effect")
		local superseded = publish("spawn.response", wide)
		serial += 1
		assert(peer.send({ peer = "orchplus", route = "spawn.response", binding = binding, id = "r-" .. serial,
			body = assert(codec.encode_dispatch_response(catalog)) }))
		for _ = 1, 8 do pump() end
		check(channel_files[ack_path(superseded)] ~= nil,
			"a later observation can retire a complete wide status without requiring result adoption")
		for _ = 1, 8 do peer.settle(4); pump() end
		local oversized_original = publish("spawn.response", original .. string.rep(" ", codec.LIMITS.bridge + 1 - #original))
		event("ack", runtime.json.encode({ route = "spawn.response", id = oversized_original.id, incarnation = peer_boot }), peer_boot, lane_id)
		publish("spawn.response", assert(codec.encode_dispatch_response(catalog)))
		check(channel_files[ack_path(oversized_original)] == nil,
			"the wider inspection budget never classifies or acknowledges an oversized ordinary catalog frame")
		local mutating = clone(catalog)
		mutating.op, mutating.status, mutating.category, mutating.payload = "launch", "uncertain", "unknown_effect", nil
		local effect_receipt = publish("spawn.response", assert(codec.encode_dispatch_response(mutating)))
		local damaged = runtime.json.decode(assert(codec.encode_dispatch_response(catalog)):sub(#codec.DISPATCH.prefix + 1))
		damaged.body_sha256 = string.rep("0", 64)
		local damaged_receipt = publish("spawn.response", codec.DISPATCH.prefix .. runtime.json.encode(damaged))
		publish("spawn.response", assert(codec.encode_dispatch_response(catalog)))
		check(channel_files[ack_path(effect_receipt)] == nil and channel_files[ack_path(damaged_receipt)] == nil,
			"supersession never acknowledges a mutating result or an ambiguously framed catalog")
	end
	do
		-- Replace a separate real native panel, never mutate/restore the source
		-- that owns the deliberately retained SPAWN effects above.
		local native_list = fake.pane.list
		fake.pane.list = function()
			local panes = native_list()
			table.insert(panes, { pane = 13, program = "orchplus.orchestrator", title = "Display source replacement" })
			return panes
		end
		renders[13] = 0
		local cx3 = context(13)
		local retired = definition.init(cx3, {}, nil)
		local function source_event(view, act, bytes)
			definition.event(view, { ev = "action", act = "usage_relay", value = runtime.json.encode({
				schema = 1, source_nonce = view.alias_nonce, relay_endpoint = view.usage_relay.relay_endpoint,
				relay_boot = view.usage_relay.relay_boot, kind = "display", act = act, bytes = bytes }) }, cx3)
		end
		local request = runtime.json.encode({ version = 1, request_id = "source-display", op = "snapshot" })
		source_event(retired, "request", request)
		local stale = assert(usage.receive(4)[1]); assert(usage.ack(stale))
		local replacement = definition.init(cx3, {}, nil)
		source_event(replacement, "request", request)
		local current = assert(usage.receive(4)[1]); assert(usage.ack(current))
		local bytes = runtime.json.encode({ version = 1, request_id = "source-display", op = "snapshot",
			display_only = true, ok = false, status = "disabled" })
		assert(usage.send({ peer = "orchplus", route = "usage.display.response", binding = stale.binding,
			id = "retired-display-response", body = bytes }))
		for _ = 1, 8 do pump(); usage.settle(4) end
		check(retired.alias_nonce ~= replacement.alias_nonce and stale.binding ~= current.binding
			and retired.usage_relay.display == nil and replacement.usage_relay.display == nil and not metadata.held,
			"same-ID late response cannot cross native source replacement: " .. runtime.json.encode({
				old_binding = stale.binding, new_binding = current.binding, old_display = retired.usage_relay.display,
				new_display = replacement.usage_relay.display, held = metadata.held, error = metadata.error }))
		local accepted = assert(usage.send({ peer = "orchplus", route = "usage.display.response", binding = current.binding,
			id = "replacement-display-response", body = bytes }))
		for _ = 1, 8 do pump() end
		local published = replacement.usage_relay.display
		check(published ~= nil and published.message.id == accepted.id and published.message.binding == current.binding
			and retired.usage_relay.display == nil and not metadata.held,
			"only the replacement's exact request can publish its display: " .. runtime.json.encode({
				expected = accepted, actual = published, held = metadata.held, error = metadata.error }))
		source_event(replacement, "ack", runtime.json.encode({
			route = published.message.route, id = published.message.id, incarnation = published.message.incarnation }))
		for _ = 1, 8 do pump(); usage.settle(4) end
		fake.pane.list = native_list
	end
	do
		local native_now, now = fake.now, fake.now()
		fake.now = function() return now end
		local function observed(details)
			return runtime.json.encode({ held = metadata.held == true, error = metadata.error or "none",
				display_error = view1.usage_relay.display_error or "none", display = view1.usage_relay.display or false,
				domain_writes = ui_store.writes - domain_writes, details = details })
		end
		local read_json = runtime.json.encode({ version = 1, request_id = "absent-display", op = "snapshot" })
		usage_event("request", read_json)
		local original = assert(usage.receive(4)[1])
		now += 30001; pump()
		check(not metadata.held and view1.usage_relay.display_error == "usage_read_timeout"
			and view1.usage_relay.display == nil and ui_store.writes == domain_writes,
			"absent display cannot hold SPAWN or change authority: " .. observed({ request = original.id }))
		usage_event("request", runtime.json.encode({ version = 1, request_id = "replacement-display", op = "snapshot" }))
		local retained = usage.receive(4)
		check(#retained == 1 and retained[1].id == original.id and retained[1].body == original.body
			and view1.usage_relay.display_error == "read_pending" and not metadata.held,
			"replacement preserves the unanswered immutable display request: " .. observed({ original = original, retained = retained }))
		assert(usage.ack(original))
		local late = { version = 1, request_id = "absent-display", op = "page", display_only = true, ok = false, status = "disabled" }
		assert(usage.send({ peer = "orchplus", route = "usage.display.response", binding = original.binding, id = "late-wrong-op",
			body = runtime.json.encode(late) }))
		for _ = 1, 8 do pump(); usage.settle(4) end
		check(view1.usage_relay.display == nil and not metadata.held,
			"same-ID wrong-operation response cannot satisfy the read: " .. observed({ offered = late }))
		late.op = "snapshot"
		local response = assert(usage.send({ peer = "orchplus", route = "usage.display.response", binding = original.binding, id = "late-display",
			body = runtime.json.encode(late) }))
		for _ = 1, 8 do pump() end
		local published = view1.usage_relay.display
		check(published ~= nil, "exact late display is published: " .. observed({ expected = response }))
		local receipt = published.message
		local response_ack = string.format("/fixture/plugins/orchplus/plugin-channel-v1/a-usage-%03d.json", response.slot)
		check(receipt.id == response.id and receipt.incarnation == response.incarnation
			and receipt.route == response.route and receipt.binding == original.binding,
			"late display preserves exact carrier identity: " .. observed({ expected = response, original_binding = original.binding }))
		check(channel_files[response_ack] == nil,
			"repeated immutable display delivery never fabricates window consumption: " .. observed({
				ack_path = response_ack, ack_present = channel_files[response_ack] ~= nil }))
		check(view1.usage_relay.display_error == nil and not metadata.held and ui_store.writes == domain_writes,
			"late display clears only its optional timeout diagnostic: " .. observed())
		usage_event("ack", runtime.json.encode({ route = receipt.route, id = receipt.id, incarnation = receipt.incarnation }))
		check(channel_files[response_ack] ~= nil, "exact window receipt must ACK late display: " .. observed({ ack_path = response_ack }))
		for _ = 1, 8 do pump(); usage.settle(4) end
		usage_event("request", runtime.json.encode({ version = 1, request_id = "absent-capacity", op = "snapshot" }), "capacity")
		local capacity = assert(usage.receive(4)[1]); assert(usage.ack(capacity))
		now += 30001; pump()
		check(metadata.held and metadata.error == "usage_read_timeout" and view1.usage_relay.capacity == nil,
			"capacity evidence absence still fails closed: " .. observed({ capacity = view1.usage_relay.capacity or false }))
		usage_event("request", runtime.json.encode({ version = 1, request_id = "display-under-hold", op = "snapshot" }))
		local under_hold = assert(usage.receive(4)[1]); assert(usage.ack(under_hold))
		now += 30001; pump()
		late.request_id = "display-under-hold"
		assert(usage.send({ peer = "orchplus", route = "usage.display.response", binding = under_hold.binding, id = "display-held-response",
			body = runtime.json.encode(late) }))
		for _ = 1, 8 do pump() end
		check(view1.usage_relay.display ~= nil and view1.usage_relay.display.request_id == late.request_id
			and view1.usage_relay.display_error == nil and metadata.held
			and metadata.error == "usage_read_timeout" and ui_store.writes == domain_writes,
			"display recovery preserves the unrelated capacity hold: " .. observed({ expected_request = late.request_id }))
		receipt = view1.usage_relay.display.message
		usage_event("ack", runtime.json.encode({ route = receipt.route, id = receipt.id, incarnation = receipt.incarnation }))
		for _ = 1, 8 do pump(); usage.settle(4); peer.settle(4) end
		fake.now = native_now
	end
	local bad_frame = runtime.json.decode(read_bytes:sub(#codec.DISPATCH.prefix + 1))
	bad_frame.body_sha256 = string.rep("0", 64)
	local effect = clone(observational)
	effect.op, effect.request_serial, effect.action_id = "launch", 1, "unretained-effect"
	effect.category, effect.status, effect.error = "unknown_effect", "uncertain", nil
	assert(peer.send({ peer = "orchplus", route = "spawn.response", binding = "closed-panel:old-lane",
		id = "damaged-observation", body = codec.DISPATCH.prefix .. runtime.json.encode(bad_frame) }))
	assert(peer.send({ peer = "orchplus", route = "spawn.response", binding = "closed-panel:old-lane",
		id = "unretained-effect", body = assert(codec.encode_dispatch_response(effect)) }))
	for _ = 1, 4 do pump() end
	check(peer.settle(4) == 0 and metadata.held and metadata.error == "unreconciled_peer_result" and ui_store.writes == domain_writes,
		"bad read framing and uncorrelatable effect outcomes stay visibly held and unacknowledged; read classification cannot erase an effect")
end
do
	local original_process = fake.process
	local calls, prepared = {}, nil
	fake.process = { run = function(argv, options, callback)
		check(options.timeout_ms == 10000, "readiness subprocess has a finite timeout")
		table.insert(calls, table.clone(argv))
		local stdout = ""
		if argv[2] == "init" then prepared = argv[4] end
		if table.find(argv, "--show-toplevel") then stdout = prepared .. "\n"
		elseif table.find(argv, "--git-common-dir") then stdout = prepared .. "/.git\n"
		elseif table.find(argv, "--verify") then stdout = string.rep("a", 40) .. "\n" end
		callback({ status = 0, stdout = stdout, stderr = "" })
	end }
	definition.event(view1, { ev = "action", act = "setup-readiness-prepare", value = runtime.json.encode({
		source_nonce = view1.alias_nonce, request_id = "invalid-readiness", cwd = "/not-owned" }) }, cx1)
	check(#calls == 0, "fixed readiness action rejects caller-selected filesystem targets")
	definition.event(view1, { ev = "action", act = "setup-readiness-prepare", value = runtime.json.encode({
		source_nonce = view1.alias_nonce, request_id = "prepare-host-readiness" }) }, cx1)
	check(view1.setup_result.ok and view1.setup_result.request_id == "prepare-host-readiness"
		and prepared:sub(1, #fake.plugin.data + 11) == fake.plugin.data .. "/readiness-"
		and view1.setup_result.repository.cwd == prepared,
		"readiness creates only a unique execution-host-private checkout and returns canonical host probe evidence")
	local before = #calls
	definition.event(view1, { ev = "action", act = "setup-readiness-verify", value = runtime.json.encode({
		source_nonce = view1.alias_nonce, request_id = "verify-unowned-readiness", orch_project_id = "unknown-project" }) }, cx1)
	check(view1.setup_result.code == "readiness_unowned" and #calls == before,
		"readiness refuses arbitrary project readback before invoking Git")
	fake.process = original_process
end
do
	-- A late pending projection can arrive after its conclusive outcome was
	-- committed and the action removed. Reconstruct that durable, bounded state.
	local late_store = store()
	late_store.value, late_store.marker = clone(ui_store.value), true
	local sid = assert(next(late_store.value.sessions))
	local session = late_store.value.sessions[sid]
	session.admission_seq = late_store.value.next_admission_seq
	late_store.value.next_admission_seq += 1
	session.next_request_serial, session.request_floor = 4, 1
	session.admitted = nil
	modules, channel_files, channel_dirs = {}, {}, {}
	fake.kv = late_store
	local late_host = load("host")
	local loaded = late_host.new_authority(late_store)
	check(loaded:load().ok, "consumed-request fixture passes the real saved-state validator")
	local late_view = definition.init(cx1, {}, nil)
	local Channel, codec = load("channel/channel"), load("wire/codec")
	local peer = assert(Channel.open({ plugin_id = "spawn", plugin_data = "/fixture/plugins/spawn",
		incarnation = "late-result-peer", fs = fake.fs, json = fake.json, base64 = fake.base64 }))
	local body = { schema = 2, op = "mailbox_provision", request_id = "consumed-request", action_id = "consumed-action",
		request_serial = 3, category = "current_result", status = "pending",
		authority_namespace = late_store.value.authority_namespace,
		spawn_namespace = late_store.value.compatibility.spawn_namespace,
		authority_revision = late_store.value.revision, logical_session_id = sid,
		admission_seq = session.admission_seq, controller_generation = 1,
		origin_binding = { host_pane_id = "11", alias_nonce = late_view.alias_nonce,
			window_key = "", window_epoch = "late-result-window", native_session_id = "2", window_host_id = "1",
			logical_session_id = sid, owner_id = "retired-owner", owner_generation = 1 } }
	local before, writes = runtime.json.encode(late_store.value), late_store.writes
	local function offer(id, value, expected_ack)
		local receipt = assert(peer.send({ peer = "orchplus", route = "spawn.response",
			binding = "retired-panel:retired-lane", id = id, body = assert(codec.encode_dispatch_response(value)) }))
		for _ = 1, 4 do relay_tick() end
		local ack = string.format("/fixture/plugins/orchplus/plugin-channel-v1/a-spawn-%03d.json", receipt.slot)
		check((channel_files[ack] ~= nil) == expected_ack, id .. ": late effect carrier retirement follows durable consumption")
	end
	offer("consumed-pending-result", body, true)
	check(not late_view.spawn_relay.held and runtime.json.encode(late_store.value) == before and late_store.writes == writes,
		"late consumed result neither blocks later work nor changes or reissues its completed operation")
	for _, field in { "authority_namespace", "spawn_namespace", "admission_seq", "request_serial", "authority_revision" } do
		local wrong = clone(body)
		wrong[field] = if type(wrong[field]) == "number" then wrong[field] + 1 else "different-" .. wrong[field]
		offer("unaccounted-" .. field, wrong, false)
	end
	late_store.fail_read = true
	offer("unreadable-consumption", body, false)
	late_store.fail_read = false
	late_store.value.revision += 1
	offer("changed-durable-consumption", body, false)
	check(late_view.spawn_relay.held and late_store.writes == writes,
		"foreign, unissued, unreadable and diverged evidence remain held without domain mutation")
end
-- A fresh owner-status observation may settle a control while its original
-- response is still in transit. Retiring the lane must not stall later starts.
for _, scenario in { "early", "late", "future", "foreign_request", "foreign_origin", "failed_save", "unreadable", "diverged", "reload" } do
	local backing = store()
	backing.value, backing.marker = clone(ui_store.value), true
	local sid = view1.orch_session_id
	local session = backing.value.sessions[sid]
	session.admission_seq = backing.value.next_admission_seq
	backing.value.next_admission_seq += 1
	session.admitted, session.spawn_namespace = true, backing.value.compatibility.spawn_namespace
	local origin = { logical_session_id = sid, owner_id = session.controller.owner_id, owner_generation = session.controller.generation,
		host_pane_id = "11", alias_nonce = view1.alias_nonce, window_key = "", window_epoch = "control-retirement-" .. scenario,
		native_session_id = "2", window_host_id = "1" }
	modules, channel_files, channel_dirs = {}, {}, {}
	fake.kv = backing
	local current_host = load("host")
	check(current_host.new_authority(backing):load().ok, scenario .. ": control fixture validates")
	local panel = definition.init(cx1, {}, { pane = 11, alias_nonce = view1.alias_nonce, orch_session_id = sid })
	local Channel, codec = load("channel/channel"), load("wire/codec")
	local peer = assert(Channel.open({ plugin_id = "spawn", plugin_data = "/fixture/plugins/spawn",
		incarnation = "control-result-peer", fs = fake.fs, json = fake.json, base64 = fake.base64 }))
	local metadata, command_seq = panel.spawn_relay, 0
	local function command(name, fields)
		command_seq += 1
		local input = { kind = "dispatch", command = name, request_id = "control-test-" .. tostring(command_seq),
			orch_session_id = sid, authority_namespace = backing.value.authority_namespace, expected_revision = backing.value.revision,
			command_seq = command_seq, controller_pane = "11", origin = origin }
		for key, value in fields or {} do input[key] = value end
		definition.event(panel, { ev = "action", act = "dispatch-command", value = runtime.json.encode(input) }, cx1)
		return panel.dispatch_control_result
	end
	local function event(act, bytes)
		definition.event(panel, { ev = "action", act = "spawn_relay", value = runtime.json.encode({
			schema = 1, source_nonce = panel.alias_nonce, relay_endpoint = metadata.relay_endpoint, relay_boot = metadata.relay_boot,
			lane_id = "control", peer_boot = "control-result-peer", act = act, bytes = bytes }) }, cx1)
	end
	local function pump() for _ = 1, 8 do assert(relay_tick)() end end
	event("bind", runtime.json.encode(origin))
	local bind = assert(peer.receive(4)[1]); assert(peer.ack(bind))
	local source = { schema = 1, relay_endpoint = metadata.relay_endpoint, relay_boot = metadata.relay_boot, lane_id = "control",
		host_pane_id = "11", source_nonce = panel.alias_nonce, peer_boot = "control-result-peer",
		bind_request = { id = bind.id, incarnation = bind.incarnation } }
	local function publish(sequence, body, route)
		return assert(peer.send({ peer = "orchplus", route = route or "spawn.response", binding = metadata.relay_endpoint .. ":control",
			id = "r-" .. tostring(sequence), body = body }))
	end
	command("continue_controller", { operator_verified = true })
	check(backing.value.sessions[sid].controller.phase == "active", scenario .. ": restored fixture explicitly continues its controller")
	publish(1, runtime.json.encode(source), "spawn.source"); pump()
	local queued = command("bridge_control", { operation = "reconcile_session", compatibility = backing.value.compatibility })
	check(queued and queued.ok, scenario .. ": exact control is durably queued: " .. runtime.json.encode(queued))
	local control = clone(backing.value.sessions[sid].bridge_control.request)
	event("reconcile_session", runtime.json.encode(control))
	local sent = assert(peer.receive(4)[1]); assert(peer.ack(sent))
	local payload = { admission_cursor = session.admission_seq, compatibility = clone(backing.value.compatibility),
		control = { binding = clone(origin), generation_floor = session.generation_floor, last_authority_revision = control.authority_revision,
			next_request_serial = session.next_request_serial, request_floor = session.request_floor, phase = "open" } }
	local body = { schema = 2, op = control.op, request_id = control.request_id, action_id = control.action_id,
		authority_namespace = control.authority_namespace, authority_revision = control.authority_revision,
		logical_session_id = sid, admission_seq = session.admission_seq, control_origin = clone(control.control_origin),
		spawn_namespace = session.spawn_namespace, category = "current_admission", status = "reconciled", payload = clone(payload) }
	body.payload.outstanding = { after_serial = 0, complete = true, entries = runtime.json.array(), next_after_serial = 0, through_serial = 0 }
	local bytes, invalid = codec.encode_dispatch_response(body)
	assert(bytes, runtime.json.encode(invalid))
	local receipt
	if scenario == "early" or scenario == "failed_save" then receipt = publish(2, bytes); pump() end
	local query = { schema = 2, origin = "orchplus", op = "owner_status", request_id = "observe-control", action_id = "observe-control-action",
		authority_namespace = control.authority_namespace, logical_session_id = sid, admission_seq = session.admission_seq,
		origin_binding = clone(origin), controller_pane = "11", controller_generation = origin.owner_generation }
	event("owner_status", runtime.json.encode(query))
	for _, request in peer.receive(4) do assert(peer.ack(request)) end
	local observation = { schema = 2, op = query.op, request_id = query.request_id, action_id = query.action_id,
		authority_namespace = control.authority_namespace, authority_revision = backing.value.revision, logical_session_id = sid,
		admission_seq = session.admission_seq, origin_binding = clone(origin), controller_generation = origin.owner_generation,
		spawn_namespace = session.spawn_namespace, category = "current_admission", status = "owner_status", payload = payload }
	local observed_bytes = assert(codec.encode_dispatch_response(observation))
	publish(3, observed_bytes); pump()
	backing.fail_write = scenario == "failed_save"
	local observed = command("bridge_observe", { query_bytes = runtime.json.encode(query), response_bytes = observed_bytes })
	backing.fail_write = false
	check(observed and observed.ok == (scenario ~= "failed_save"), scenario .. ": observation follows durable commit outcome")
	check((backing.value.sessions[sid].bridge_control == nil) == (scenario ~= "failed_save"),
		scenario .. ": only a saved observation clears the exact pending control")
	if scenario == "unreadable" then backing.fail_read = true
	elseif scenario == "diverged" then backing.value.revision += 1
	elseif scenario == "reload" then
		modules = {}; load("host")
		panel = definition.init(cx1, {}, { pane = 11, alias_nonce = view1.alias_nonce, orch_session_id = sid })
	end
	if not receipt then
		if scenario == "foreign_request" then body.request_id = "different-old-control"
		elseif scenario == "foreign_origin" then body.control_origin.binding.owner_id = "different-owner" end
		receipt = publish(if scenario == "future" then 4 else 2, assert(codec.encode_dispatch_response(body)))
		pump()
	end
	local expected = scenario == "early" or scenario == "late"
	if scenario ~= "reload" then
		event("release", "{}")
		for _, request in peer.receive(4) do assert(peer.ack(request)) end
		source.released = true
		publish(5, runtime.json.encode(source), "spawn.source"); pump()
	end
	local ack = string.format("/fixture/plugins/orchplus/plugin-channel-v1/a-spawn-%03d.json", receipt.slot)
	check((channel_files[ack] ~= nil) == expected,
		scenario .. ": superseded control retirement needs the exact request and earlier same-boot carrier evidence")
	if expected then
		check(#metadata.lanes == 0 and not metadata.held,
			scenario .. ": a consumed control no longer blocks lane release or subsequent conversations")
	end
end
return "PASS " .. tostring(checks) .. " current authority durability assertions"
