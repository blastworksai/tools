-- Run in Tern: assert(loadstring(tern.fs.read(TEST_PATH)))(PLUGIN_DIR)
local root = ...
local modules, environment = {}, getfenv()
local function load(name)
	name = name:gsub("^%./", "")
	if modules[name] ~= nil then return modules[name] end
	local chunk = assert(loadstring(tern.fs.read(root .. "/" .. name .. ".luau"), name))
	setfenv(chunk, setmetatable({ require = load }, { __index = environment }))
	modules[name] = chunk()
	return modules[name]
end
local snapshot, presentation = load("snapshot"), load("presentation")
local checks = 0
local function check(ok, why)
	assert(ok, why); checks += 1
	if type(await) == "function" then await(tern.sleep(0)) end
end
local function clone(value) return tern.json.decode(tern.json.encode(value)) end
local function reading(id, canonical, used, at, provider)
	return { id = id, provider = provider or "claude", provider_label = "Observed provider",
		account_id = canonical, canonical_id = canonical, account_label = if canonical then "Observed account" else nil,
		source_label = "Fixture", usage_source = "fixture", last_reading_at_ms = at,
		windows = if used ~= nil then { { key = "weekly", pool = "all", used = used, remaining = 100 - used,
			observed_at_ms = at, resets_at_ms = 2000000 } } else {
			{ key = "subscription", pool = "default", observed_at_ms = 0, unavailable_reason = "not_yet_measured" } } }
end
local function entry(id, provider, canonical, reading_ids)
	return { id = id, provider = provider or "claude", provider_label = "Configured provider", account_label = "Configured " .. id,
		canonical_ids = canonical or {}, reading_ids = reading_ids or {} }
end
local function scope(entries, revision, at, consumers)
	return { id = "host:fixture", revision = revision or "definition-1", updated_at_ms = at or 100,
		accounts = entries, consumers = consumers or {} }
end
local function source(publisher, readings, configured)
	return assert(snapshot.decode({ version = 3, publisher = publisher, as_of_ms = 1000, readings = readings,
		roster = if configured then { version = 1, scopes = { configured } } else nil }))
end
local function project(sources, now)
	return snapshot.project(sources, now or 3000)
end
-- Pre-2.0 publishers left measurements as rosterless last-good inventory.
local function legacy(readings)
	local saved = {}
	for _, value in readings do
		local copy = clone(value)
		copy.usage_source = "last-good"
		table.insert(saved, copy)
	end
	return source("legacy", saved, nil)
end
local a = entry("primary", "claude", { "claude:one" })
local old = reading("pane-a", "claude:one", 21, 1000)
local newer = reading("pane-b", "claude:one", 34, 2000)
local duplicate = source("a", { old, newer }, scope({ a }))
local model = project({ a = duplicate })
check(#model.accounts == 1 and model.accounts[1].windows[1].used == 34,
	"duplicate sessions choose the latest observation, never sum")
check(model.accounts[1].account_label == "Configured primary" and model.accounts[1].provider_label == "Configured provider",
	"SPAWN labels override observed labels")
check(model.accounts[1].id == "spawn:12:host:fixture:primary", "membership identity uses scope and stable entry ID")
local pools = clone(newer)
pools.id = "pane-pools"
table.insert(pools.windows, { key = "weekly", pool = "model", used = 76, remaining = 24, observed_at_ms = 2000 })
local pooled = project({ a = source("a", { old, pools }, scope({ a })) })
check(#pooled.accounts[1].windows == 2 and pooled.accounts[1].windows[1].used == 34
	and pooled.accounts[1].windows[2].used == 76, "existing reducer preserves independent model pools")
local unknown = project({ a = source("a", {}, scope({ entry("waiting", "muse"), entry("custom", "custom-provider") })) })
check(#unknown.accounts == 2 and unknown.accounts[1].windows[1].freshness == "unavailable"
	and unknown.accounts[2].windows[1].freshness == "unavailable", "every configured provider remains a row without measurements")
check(unknown.accounts[1].windows[1].used == nil and unknown.accounts[1].windows[1].observed_at_ms == 0
	and unknown.accounts[1].windows[1].unavailable_reason == "not_reported", "unknown quota is not zero or a fresh observation")
check(#project({ a = source("a", { old }, nil) }).accounts == 0, "observed identities without a roster never define accounts")
local empty = assert(snapshot.decode({ version = 3, publisher = "empty", as_of_ms = 1000,
	readings = { old }, roster = { version = 1, scopes = {} } }))
check(#project({ empty = empty }).accounts == 0, "an explicit empty roster never falls back to pane membership")
local custom = entry("long-custom", string.rep("c", 256))
check(project({ a = source("a", {}, scope({ custom })) }).accounts[1].provider == custom.provider,
	"valid full-length custom SPAWN providers remain unavailable configured rows")

local changed = entry("primary", "claude", { "claude:two" })
changed.account_label = "Edited account"
local edit = source("b", { reading("new-pane", "claude:two", 52, 2500) }, scope({ changed }, "definition-2", 200))
local edited = project({ old = duplicate, new = edit })
check(#edited.accounts == 1 and edited.accounts[1].account_label == "Edited account" and edited.accounts[1].windows[1].used == 52,
	"latest scope replaces definitions and excludes stale associations")
local removal = source("b", {}, scope({}, "definition-3", 300))
check(#project({ old = duplicate, new = removal }).accounts == 0, "scope removal cannot be undone by a stale source copy")
local tie = source("a", {}, scope({ entry("tie", "muse") }, "tie-revision", 200))
check(project({ a = tie, b = edit }).accounts[1].account_label == "Configured tie",
	"equal-mtime conflicting definitions choose the deterministic publisher tie break")
local copy_a = source("a", {}, scope({ a }))
local copy_b = source("b", { newer }, scope({ entry("primary", "claude", {}, { "pane-b" }) }))
check(project({ a = copy_a, b = copy_b }).accounts[1].windows[1].used == 34,
	"same-definition copies combine source-local reading associations")
local alias_reading = clone(newer)
alias_reading.account_aliases = { "claude:one", "legacy:one", "profile:one" }
local aliases = source("a", { alias_reading }, scope({ entry("primary", "claude", { "legacy:one", "profile:one" }) }))
check(project({ a = aliases }).accounts[1].windows[1].used == 34, "known aliases resolve before deciding mapping ambiguity")
local alias_copy = source("b", {}, scope({ entry("primary", "claude", { "claude:one" }) }))
check(project({ a = aliases, b = alias_copy }).accounts[1].windows[1].used == 34,
	"same-definition alias copies combine through known canonical resolution")
local conflicting = source("b", { reading("other", "claude:two", 71, 2000) },
	scope({ entry("primary", "claude", { "claude:two" }, { "other" }) }))
local conflict = project({ a = duplicate, b = conflicting })
check(#conflict.accounts == 1 and conflict.accounts[1].windows[1].used == nil
	and conflict.accounts[1].unresolved_reason == "identity_conflict", "conflicting mappings cannot merge unrelated quotas")
local conflicting_inventory = source("b", {}, scope({ entry("primary", "claude", { "claude:two" }) }))
check(project({ a = duplicate, b = conflicting_inventory }).accounts[1].windows[1].used == nil,
	"a conflicting copy stays ambiguous even before it has produced a measurement")
local shared = project({ a = source("a", { newer }, scope({ a, entry("second", "claude", { "claude:one" }) })) })
check(#shared.accounts == 2 and shared.accounts[1].windows[1].used == nil and shared.accounts[2].windows[1].used == nil
	and shared.accounts[1].unresolved_reason == "identity_conflict" and presentation.summary(shared, 3000).total_count == 2,
	"one login under two definitions of one SPAWN scope stays an identity conflict and never duplicates quota")
-- The same login configured on two SPAWN hosts is one account.
local function host_scope(id, entries, consumers)
	local value = scope(entries, nil, nil, consumers)
	value.id = id
	return value
end
local function hosts(readings, first, second)
	return assert(snapshot.decode({ version = 3, publisher = "hosts", as_of_ms = 1000, readings = readings,
		roster = { version = 1, scopes = { first, second } } }))
end
local on_b = reading("host-b-reading", "claude:one", 55, 2600)
local across = project({ hosts = hosts({ newer, on_b },
	host_scope("host:b", { entry("laptop", "claude", {}, { on_b.id }) }, { { id = "omp", label = "OMP", reading_ids = { "omp-b" } } }),
	host_scope("host:a", { entry("desktop", "claude", {}, { newer.id }) })) })
check(#across.accounts == 1 and across.accounts[1].account_label == "Configured desktop"
	and across.accounts[1].windows[1].used == 55 and presentation.summary(across, 3000).total_count == 1,
	"one login seen in two SPAWN host scopes is one row, kept by scope order, with the latest measurement")
check(#across.accounts[1].also_configured == 1 and across.accounts[1].also_configured[1].scope == "host:b"
	and across.accounts[1].also_configured[1].account_label == "Configured laptop"
	and across.accounts[1].also_configured[1].id == "spawn:6:host:b:laptop",
	"the merged row records where else the login is configured, including that definition's row id")
local omp_b = reading("omp-b", "claude:one", 70, 2700)
local across_omp = project({ hosts = hosts({ newer, on_b, omp_b },
	host_scope("host:b", { entry("laptop", "claude", {}, { on_b.id }) }, { { id = "omp", label = "OMP", reading_ids = { "omp-b" } } }),
	host_scope("host:a", { entry("desktop", "claude", {}, { newer.id }) })) })
check(#across_omp.consumers == 1 and #across_omp.consumers[1].account_labels == 1
	and across_omp.consumers[1].account_labels[1] == "Configured desktop",
	"OMP on the second host links to the merged account row")
local other_login = reading("host-b-other", "claude:two", 12, 2600)
local distinct = project({ hosts = hosts({ newer, other_login },
	host_scope("host:a", { entry("desktop", "claude", {}, { newer.id }) }),
	host_scope("host:b", { entry("laptop", "claude", {}, { other_login.id }) })) })
check(#distinct.accounts == 2 and presentation.summary(distinct, 3000).total_count == 2,
	"different logins on two hosts stay two rows")
local unproven = project({ hosts = hosts({},
	host_scope("host:a", { entry("desktop", "claude", { "claude:one" }) }),
	host_scope("host:b", { entry("laptop", "claude", { "claude:one" }) })) })
check(#unproven.accounts == 2, "configured identity tokens alone never merge rows before a reading proves the login")
local unbound = reading("bound-by-source", nil, 13, 1000)
check(project({ a = source("a", { unbound }, scope({ entry("primary", "claude", {}, { unbound.id }) })) }).accounts[1].windows[1].used == 13,
	"verified source-local reading associations can fill a configured row without inventing an identity")

local consumer = { id = "omp", label = "OMP configured", reading_ids = { "omp-pane" } }
local omp = reading("omp-pane", nil, 88, 2500, "unknown")
local unlinked = project({ a = source("a", { old, omp }, scope({ a }, nil, nil, { consumer })) })
check(#unlinked.accounts == 1 and #unlinked.consumers == 1 and #unlinked.consumers[1].account_labels == 0,
	"unlinked OMP is an explicit consumer caveat, never a quota row")
local linked_omp = reading("omp-pane", "claude:one", 88, 2500)
local linked = project({ a = source("a", { old, linked_omp }, scope({ a }, nil, nil, { consumer })) })
check(#linked.accounts == 1 and linked.accounts[1].windows[1].used == 21,
	"matched OMP does not add or replace the underlying subscription quota")
check(linked.consumers[1].label == "OMP configured" and linked.consumers[1].account_labels[1] == "Configured primary",
	"only known canonical OMP associations name the underlying configured account")
local only_omp = project({ a = source("a", { linked_omp }, scope({ a }, nil, nil, { consumer })) })
check(only_omp.accounts[1].windows[1].used == nil and #only_omp.consumers[1].account_labels == 1,
	"OMP identity links alone never manufacture an underlying quota")
local only_canonical = clone(linked_omp)
only_canonical.account_id, only_canonical.account_label = nil, nil
local consumer_scope = scope({}, nil, nil, { consumer })
consumer_scope.id = "host:consumer"
local cross_scope = project({ a = source("a", { old }, scope({ a })),
	b = source("b", { only_canonical }, consumer_scope) })
check(#cross_scope.accounts == 1 and cross_scope.consumers[1].account_labels[1] == "Configured primary",
	"a known canonical identity links OMP across scopes without an observed account label")
local active_omp = clone(linked_omp)
active_omp.id, active_omp.agent_id = "active-omp", "omp"
check(project({ a = duplicate, active = source("active", { active_omp }, nil) }).accounts[1].windows[1].used == 34,
	"known active OMP observations outside a roster publication remain consumers, never quota")

local muse_entry = entry("muse", "muse", { "muse:current" })
local measured = reading("muse-measured", "muse:current", 42, 1000, "muse")
local orphan = reading("muse-legacy", "muse:orphan", 89, 500, "muse")
local cold = reading("muse-cold", "muse:current", nil, 2500, "muse")
local muse_source = source("a", { cold }, scope({ muse_entry }))
local retained = project({ a = muse_source, legacy = legacy({ measured, orphan }) })
check(#retained.accounts == 1 and retained.accounts[1].windows[1].used == 42,
	"orphan legacy Muse never becomes an account or replaces a genuine configured reading")
check(retained.accounts[1].windows[1].observed_at_ms == 1000
	and retained.accounts[1].last_reading_at_ms == 1000
	and retained.accounts[1].windows[1].unavailable_reason == "not_yet_measured",
	"no-measurement refresh preserves last-known Muse values and original ages with a display caveat")
local measured_inventory = legacy({ measured })
local refresh = project({ a = muse_source, legacy = measured_inventory }, 2001000)
check(refresh.accounts[1].windows[1].used == 42 and refresh.accounts[1].windows[1].observed_at_ms == 1000
	and refresh.accounts[1].windows[1].freshness == "stale", "repeated Muse refreshes do not freshen a retained measurement")
check(measured_inventory.readings[1].windows[1].unavailable_reason == nil
	and measured_inventory.readings[1].windows[1].freshness == nil,
	"the last-known display caveat does not contaminate the published measurement")
local cached_measurement = clone(measured)
cached_measurement.usage_source = "last-good"
local cached_muse = project({ a = source("a", { cached_measurement }, scope({ muse_entry })) })
check(cached_muse.accounts[1].windows[1].used == 42
	and cached_muse.accounts[1].windows[1].observed_at_ms == 1000
	and cached_muse.accounts[1].windows[1].unavailable_reason == "not_yet_measured",
	"last-good source cache readings remain visibly last-known without refreshing ages")
local removed_muse = project({ a = source("a", {}, scope({}, "removed", 200)), legacy = legacy({ measured }) })
check(#removed_muse.accounts == 0, "retained Muse inventory cannot resurrect a removed roster entry")
local legacy_alias = clone(measured)
legacy_alias.account_id, legacy_alias.canonical_id = "muse:legacy", nil
local verified = clone(cold)
verified.account_aliases = { "muse:current", "muse:legacy" }
local migrated = project({ a = source("a", { verified }, scope({ muse_entry })), legacy = legacy({ legacy_alias }) })
check(#migrated.accounts == 1 and migrated.accounts[1].windows[1].used == 42
	and migrated.accounts[1].windows[1].observed_at_ms == 1000, "genuine legacy Muse measurement attaches only through a known alias")
local canonical_measurement = clone(measured)
canonical_measurement.account_id, canonical_measurement.account_label = nil, nil
local canonical_history = project({ a = muse_source, legacy = legacy({ canonical_measurement }) })
check(canonical_history.accounts[1].windows[1].used == 42
	and canonical_history.accounts[1].windows[1].observed_at_ms == 1000,
	"configured labels allow genuine canonical Muse measurements to retain without observed display labels")
local muse_omp = reading("omp-pane", "muse:current", 88, 2500, "muse")
local muse_consumer = project({ a = source("a", { cold, muse_omp }, scope({ muse_entry }, nil, nil, { consumer })),
	legacy = legacy({ measured }) })
check(muse_consumer.accounts[1].windows[1].used == 42 and muse_consumer.accounts[1].windows[1].observed_at_ms == 1000,
	"OMP observations cannot overwrite genuine retained Muse quota")

-- Display inventory carries the current originating publication's roster, never
-- a global raw-ID association or a historical membership definition.
-- Same reading-id shape source_collect publishes for a definition.
local function source_reading_id(publisher, provider, item)
	return "source:" .. tostring(#publisher) .. ":" .. publisher .. ":" .. provider .. ":" .. item
end
local direct_id = source_reading_id("device-a", "muse", "7")
local direct_entry = entry("direct-muse", "muse", {}, { direct_id })
local direct_scope = scope({ direct_entry })
local direct_measured = reading(direct_id, nil, 40, 1000, "muse")
local direct_cold = reading(direct_id, nil, nil, 2000, "muse")
direct_cold.windows = { { key = "weekly", pool = "all", observed_at_ms = 2000,
	unavailable_reason = "not_yet_measured" } }
local function direct_projection(measurement, configured, live)
	local saved = clone(measurement)
	saved.usage_source = "last-good"
	return project({ live = source("live", { live or direct_cold }, configured),
		inventory = source("usage-inventory:fixture:0", { saved }, configured),
		unrelated = source("unrelated", { reading(direct_id, nil, 99, 9000, "muse") }) })
end
local direct_live = project({ live = source("live", { direct_measured }, direct_scope) })
check(#direct_live.accounts == 1 and direct_live.accounts[1].windows[1].used == 40,
	"source-qualified direct-only Muse measurement binds without inventing a login")
local function numeric_window(row)
	for _, window in row.windows do if window.used ~= nil then return window end end
	return nil
end
local direct_retained = direct_projection(direct_measured, direct_scope)
local direct_window = numeric_window(direct_retained.accounts[1])
check(#direct_retained.accounts == 1 and direct_window ~= nil and direct_window.used == 40
	and direct_window.observed_at_ms == 1000 and direct_window.resets_at_ms == 2000000
	and direct_window.unavailable_reason ~= nil,
	"direct-only durable Muse copy retains value, age, reset and last-known status without a duplicate account")
local direct_zero = reading(direct_id, nil, 0, 1500, "muse")
local zero_window = numeric_window(direct_projection(direct_zero, direct_scope).accounts[1])
check(zero_window ~= nil and zero_window.used == 0 and zero_window.observed_at_ms == 1500,
	"direct-only retained zero remains a genuine measurement")
local direct_fresh = reading(direct_id, nil, 65, 3000, "muse")
local fresh_window = numeric_window(direct_projection(direct_measured, direct_scope, direct_fresh).accounts[1])
check(fresh_window ~= nil and fresh_window.used == 65 and fresh_window.observed_at_ms == 3000
	and fresh_window.unavailable_reason == nil, "a later genuine direct Muse reading supersedes retained usage")
check(#direct_projection(direct_measured, scope({}, "removed", 200)).accounts == 0,
	"current configured removal also removes direct-only retained membership")
local direct_omp_scope = scope({ direct_entry }, nil, nil, {
	{ id = "omp", label = "OMP", reading_ids = { direct_id } } })
check(numeric_window(direct_projection(direct_measured, direct_omp_scope).accounts[1]) == nil,
	"source-local OMP classification excludes the retained direct copy from quota")
local left_scope = scope({ entry("left", "muse", {}, { "raw" }), entry("right", "muse") })
local right_scope = scope({ entry("left", "muse"), entry("right", "muse", {}, { "raw" }) })
local separate = project({
	left = source("left", { reading("raw", nil, 10, 1000, "muse") }, left_scope),
	right = source("right", { reading("raw", nil, 20, 1000, "muse") }, right_scope) })
local separate_values = {}
for _, row in separate.accounts do
	local window = numeric_window(row)
	if window ~= nil then separate_values[row.account_label] = window.used end
end
check(#separate.accounts == 2 and separate_values["Configured left"] == 10
	and separate_values["Configured right"] == 20,
	"unrelated publishers with identical raw IDs do not collide or share direct quota")

return "PASS roster: " .. checks .. " checks"
