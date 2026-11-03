-- Run in Tern's Lua runtime: assert(loadstring(tern.fs.read(TEST_PATH)))(PLUGIN_DIR)
local root = ...
assert(type(root) == "string", "pass the plugin directory")
local modules = {}
local environment = getfenv()
local function load(name)
	name = name:gsub("^%./", "")
	if modules[name] ~= nil then return modules[name] end
	local chunk = assert(loadstring(tern.fs.read(root .. "/" .. name .. ".luau"), name))
	setfenv(chunk, setmetatable({ require = load }, { __index = environment }))
	local module = chunk()
	modules[name] = module
	return module
end
local accounts, identity = load("accounts"), load("identity")
local checks = 0
local function check(condition, message)
	assert(condition, message)
	checks += 1
	-- Yield between cases so no Tern driver slice accumulates several of them.
	if type(await) == "function" then await(tern.sleep(0)) end
end
-- Legacy Muse inventory is earlier readings fed back before the current ones.
local function retain(readings, earlier)
	local all = {}
	for _, reading in earlier or {} do table.insert(all, reading) end
	for _, reading in readings do table.insert(all, reading) end
	return accounts.retain_muse(all)
end
local function reading(source, account, used, time, provider)
	return {
		id = source, provider = provider or "claude", provider_label = "Provider",
		source_label = "Agent " .. source, account_id = account,
		account_label = if account then account:match(":(.+)$") else nil,
		plan = "Paid", usage_source = source, last_reading_at_ms = time,
		windows = {{ key = "seven_day", pool = "default", used = used, remaining = 100 - used,
			observed_at_ms = time, resets_at_ms = time + 100000 }},
	}
end

local older = reading("device:a", "claude:primary", 23, 100)
local newer = reading("desktop:b", "claude:primary", 41, 200)
local distinct = reading("device:c", "claude:second", 41, 200)
local unresolved = reading("device:d", nil, 41, 200)
local grouped, unknown = accounts.group({ older, newer, distinct, unresolved })
check(#grouped == 2 and #unknown == 1, "count accounts, not agents or equal percentages")
check(grouped[1].id == "claude:primary" and grouped[1].account_label == "primary", "preserve configured account reference and label")
check(grouped[1].windows[1].used == 41, "select the newest quota; never add shared-account readings")
check(grouped[1].windows[1].resets_at_ms == 100200, "preserve the winning observation's reset")
check(unknown[1] == unresolved, "unidentified sources must not become account cards")
grouped[1].windows[1].used = 99
check(newer.windows[1].used == 41, "grouping must not mutate source readings")

local placeholder = reading("legacy:discovery", "claude:primary", 0, 50)
placeholder.windows = { { key = "observation", pool = "default", observed_at_ms = 50, unavailable_reason = "not_yet_measured" } }
local with_discovery = accounts.group({ placeholder, newer })
check(#with_discovery[1].windows == 1 and with_discovery[1].windows[1].used == 41,
	"retained discovery placeholders are not extra allowances beside measured quota")
local only_discovery = accounts.group({ placeholder })
check(only_discovery[1].windows[1].unavailable_reason == "not_yet_measured", "unmeasured accounts remain explicitly unavailable")
local unavailable_pool = reading("source:missing-pool", "claude:primary", 0, 250)
unavailable_pool.windows = { { key = "five_hour", pool = "model", observed_at_ms = 250, unavailable_reason = "not_reported" } }
local with_missing_pool = accounts.group({ placeholder, newer, unavailable_pool })
check(#with_missing_pool[1].windows == 2 and with_missing_pool[1].windows[1].unavailable_reason == "not_reported",
	"genuine unavailable provider pools survive removal of discovery placeholders")

local ties_a = reading("a", "claude:primary", 17, 300)
local ties_b = reading("b", "claude:primary", 29, 300)
local forward = accounts.group({ ties_a, ties_b })
local reverse = accounts.group({ ties_b, ties_a })
check(forward[1].windows[1].used == reverse[1].windows[1].used, "source order must not change tied observations")

local pools_a = reading("source:a", "antigravity:primary", 11, 100, "antigravity")
pools_a.windows[1].pool = "gemini"
table.insert(pools_a.windows, { key = "seven_day", pool = "claude_gpt", used = 84, remaining = 16, observed_at_ms = 300 })
local pools_b = reading("source:b", "antigravity:primary", 22, 200, "antigravity")
pools_b.windows[1].pool = "gemini"
table.insert(pools_b.windows, { key = "seven_day", pool = "claude_gpt", used = 70, remaining = 30, observed_at_ms = 200 })
local merged = accounts.group({ pools_a, pools_b })
check(#merged == 1 and #merged[1].windows == 2, "retain both account pools")
local pool_values = {}
for _, window in merged[1].windows do pool_values[window.pool] = window.used end
check(pool_values.gemini == 22 and pool_values.claude_gpt == 84, "choose freshness independently per pool")

local enrich = load("enrichment")
local provider_metadata = { principal = "primary@example.invalid", principal_kind = "email",
	label = "Primary", organization = "Personal", organization_id = "org-one", plan = "Max" }
local named = assert(identity.email("claude", provider_metadata.principal, { organization = "Personal" }))
local vm = reading("vm:one", "claude:configured-name", 23, 100)
vm.canonical_id, vm.principal_id = named.id, named.principal_id
local enriched, enrich_error = enrich.apply(vm, { metadata = provider_metadata })
local desktop = reading("desktop:one", named.id, 41, 200)
desktop.canonical_id, desktop.principal_id = named.id, named.principal_id
local hybrid = accounts.group({ enriched, desktop })
check(#hybrid == 1 and hybrid[1].windows[1].used == 41, "VM and local aliases share one account without summing usage")
local other_metadata = table.clone(provider_metadata)
other_metadata.organization_id = "org-two"
local other = enrich.apply(reading("other", nil, 7, 250), { metadata = other_metadata })
local scoped, ambiguous = accounts.group({ enriched, other, desktop })
check(#scoped == 2 and #ambiguous == 1 and ambiguous[1].id == desktop.id,
	"a name-only scope shared by two verified organization IDs remains unresolved rather than merging their quotas")
local conflicting = table.clone(provider_metadata)
conflicting.principal = "different@example.invalid"
local unchanged, mismatch = enrich.apply(enriched, { metadata = conflicting })
check(mismatch ~= nil and unchanged.canonical_id == enriched.canonical_id, "metadata for another login cannot relabel measured usage")
local detailed_plan = reading("source", nil, 9, 200, "openai")
detailed_plan.plan = "Pro 200"
local preserved_plan = enrich.apply(detailed_plan, { metadata = {
	principal = "primary@example.invalid", principal_kind = "email", label = "Primary", plan = "pro", workspace_id = "workspace-one",
} })
check(preserved_plan.plan == "Pro 200", "less-specific credential metadata cannot erase the reported subscription tier")

local muse = reading("muse-source", "muse:primary", 84, 100, "muse")
local unavailable = enrich.apply(muse, { usage = {
	provider = "muse",
	windows = {}, observed_at_ms = 200, unavailable_reason = "server_sent_no_usage",
} })
check(#unavailable.windows == 1 and unavailable.windows[1].used == 84
	and unavailable.windows[1].observed_at_ms == 100
	and unavailable.windows[1].resets_at_ms == muse.windows[1].resets_at_ms
	and unavailable.last_reading_at_ms == 100,
	"an unavailable standalone probe must not erase or freshen valid interactive Muse usage")
local cold_muse = table.clone(muse)
cold_muse.windows, cold_muse.last_reading_at_ms = {}, nil
local cold_unavailable = enrich.apply(cold_muse, { usage = {
	provider = "muse",
	windows = {}, observed_at_ms = 200, unavailable_reason = "server_sent_no_usage",
} })
check(#cold_unavailable.windows == 1 and cold_unavailable.windows[1].used == nil
	and cold_unavailable.windows[1].unavailable_reason == "server_sent_no_usage",
	"a genuinely cold unavailable probe must not invent numeric quota")

local complete = reading("source:a", "claude:primary", 20, 100)
complete.windows[1].resets_at_ms = 1000
table.insert(complete.windows, { key = "seven_day", pool = "fable", used = 4, remaining = 96, observed_at_ms = 100 })
local partial = reading("source:b", "claude:primary", 30, 200)
partial.plan, partial.windows[1].resets_at_ms = nil, nil
local combined = accounts.group({ complete, partial })[1]
check(combined.plan == "Paid" and #combined.windows == 2, "partial readings retain subscription and independent model allowance")
check(combined.windows[1].used == 30 and combined.windows[1].resets_at_ms == 1000
	and combined.windows[1].reset_observed_at_ms == 100, "fresh usage preserves a known same-cycle reset without freshening it")
check(combined.windows[2].observed_at_ms == 100, "missing model measurements retain their original observation time")
local reset_counter = reading("source:c", "claude:primary", 0, 300)
reset_counter.windows[1].resets_at_ms = nil
check(accounts.group({ complete, reset_counter })[1].windows[1].resets_at_ms == nil, "a lower counter cannot inherit the preceding cycle's reset")
partial.windows[1].observed_at_ms = 1100
check(accounts.group({ complete, partial })[1].windows[1].resets_at_ms == nil, "a passed reset is never carried into a new cycle")

local muse_identity = assert(identity.email("muse", "primary@example.invalid"))
local muse_direct = reading("vm:muse", "muse:configured", 84, 100, "muse")
muse_direct.canonical_id = muse_direct.account_id
muse_direct.windows[1].resets_at_ms = 1000
muse_direct.windows[1].reset_label = "synthetic reset"
local muse_desktop = reading("desktop:muse", "muse:configured", 84, 100, "muse")
muse_desktop.canonical_id = muse_identity.id
muse_desktop.account_aliases = { muse_identity.id }
muse_desktop.windows = {}
muse_desktop.plan = nil
local joined, join_unknown = accounts.group({ muse_direct, muse_desktop })
check(#joined == 1 and #join_unknown == 0 and joined[1].id == muse_identity.id,
	"an accepted account_id to canonical_id association joins host-filled legacy canonical IDs")
local muse_without_canonical = table.clone(muse_direct)
muse_without_canonical.canonical_id = nil
check(#accounts.group({ muse_without_canonical, muse_desktop }) == 1,
	"the same accepted association joins a direct source with no canonical ID")
local muse_conflict = table.clone(muse_desktop)
muse_conflict.id = "desktop:other"
muse_conflict.canonical_id = assert(identity.email("muse", "other@example.invalid")).id
muse_conflict.account_aliases = { muse_conflict.canonical_id }
local conflict_groups, conflict_unknown = accounts.group({ muse_direct, muse_desktop, muse_conflict })
check(#conflict_groups == 2 and #conflict_unknown == 1 and conflict_unknown[1] == muse_direct,
	"a conflicting configured alias cannot choose or merge distinct canonical accounts")
local scoped_claim = table.clone(muse_conflict)
scoped_claim.account_id = "muse:separate-configured"
scoped_claim.account_aliases = { muse_desktop.canonical_id }
local explicit_scopes = accounts.group({ muse_desktop, scoped_claim })
check(#explicit_scopes == 2,
	"an alias claim cannot relabel another explicitly verified canonical account or scope")
local public_identity = table.clone(muse_desktop)
public_identity.account_id = public_identity.canonical_id
check(#accounts.group({ public_identity, scoped_claim }) == 2,
	"provider-confirmed identities remain distinct without configured aliases")

local projected, saved = retain({ muse_direct })
check(#saved == 1 and saved[1].windows[1].used == 84 and saved[1].windows[1].observed_at_ms == 100,
	"identified numerical Muse quota is retained with its real observation time")
check(saved[1] ~= muse_direct and saved[1].windows[1] ~= muse_direct.windows[1],
	"retention owns its copies without mutating input readings")
local unavailable_copy = table.clone(muse_desktop)
unavailable_copy.last_reading_at_ms = 200
unavailable_copy.windows = {{ key = "subscription", pool = "default",
	unavailable_reason = "unavailable", observed_at_ms = 200 }}
local recovered, canonical_saved = retain({ unavailable_copy }, saved)
local recovered_groups = accounts.group(recovered)
check(#recovered_groups == 1 and recovered_groups[1].id == muse_identity.id
	and #recovered_groups[1].windows == 1 and recovered_groups[1].windows[1].used == 84,
	"cold unavailability retains quota and canonical enrichment does not duplicate the saved account")
check(canonical_saved[1].windows[1].observed_at_ms == 100 and canonical_saved[1].plan == "Paid"
	and canonical_saved[1].windows[1].resets_at_ms == 1000,
	"unavailable responses preserve the last known quota, reset, subscription, and observation")
check(saved[1].canonical_id == "muse:configured" and muse_direct.canonical_id == "muse:configured",
	"canonical migration must not rewrite either input")
check(canonical_saved[1].account_id == unavailable_copy.account_id
	and #canonical_saved[1].account_aliases == 1
	and canonical_saved[1].account_aliases[1] == muse_identity.id,
	"saved identity keeps the accepted account binding and provider aliases, not a historical alias union")
local obsolete_identity = table.clone(canonical_saved[1])
obsolete_identity.account_aliases = { "muse:obsolete-binding" }
local current_identity = table.clone(unavailable_copy)
current_identity.account_aliases = {}
for index = 1, 27 do table.insert(current_identity.account_aliases, "muse:accepted-alias-" .. tostring(index)) end
local _, bounded_identity = retain({ current_identity }, { obsolete_identity })
check(#bounded_identity[1].account_aliases == 27
	and table.find(bounded_identity[1].account_aliases, "muse:obsolete-binding") == nil
	and bounded_identity[1].windows[1].observed_at_ms == 100,
	"latest accepted identity replaces obsolete aliases within the decoder bound without freshening quota")
local disappeared, disappeared_saved = retain({}, canonical_saved)
check(#disappeared == 1 and #disappeared_saved == 1 and disappeared[1].windows[1].used == 84,
	"a disappearing source must not delete its last known allowance")
local restarted = tern.json.decode(tern.json.encode(disappeared_saved))
local restart_projection, restart_saved = retain({ muse_without_canonical }, restarted)
check(#accounts.group(restart_projection) == 1 and #restart_saved == 1
	and restart_saved[1].canonical_id == muse_identity.id,
	"serialized restart preserves canonical associations for legacy source IDs")
local after_reset = table.clone(unavailable_copy)
after_reset.last_reading_at_ms = 1100
after_reset.windows = {{ key = "subscription", pool = "default",
	unavailable_reason = "unavailable", observed_at_ms = 1100 }}
local expired_projection, expired_saved = retain({ after_reset }, restarted)
check(expired_saved[1].windows[1].used == 84 and expired_saved[1].windows[1].resets_at_ms == 1000
	and expired_saved[1].windows[1].observed_at_ms == 100,
	"a passed reset remains history, not fabricated zero usage or a fabricated next reset")
check(accounts.group(expired_projection)[1].windows[1].resets_at_ms == 1000,
	"projection leaves the expired reset visible for the UI's awaiting-fresh-usage state")
local zero = reading("vm:muse", "muse:configured", 0, 1200, "muse")
zero.plan = nil
zero.windows[1].resets_at_ms = 2000
local zero_projection, zero_saved = retain({ zero }, expired_saved)
check(zero_saved[1].windows[1].used == 0 and zero_saved[1].windows[1].observed_at_ms == 1200
	and zero_saved[1].windows[1].resets_at_ms == 2000 and zero_saved[1].plan == "Paid",
	"a genuine newer zero replaces the expired cycle without losing the known plan")
local _, replay_saved = retain({ muse_direct }, zero_saved)
check(replay_saved[1].windows[1].used == 0 and replay_saved[1].windows[1].resets_at_ms == 2000,
	"old source observations cannot replace a newer cycle")
local replay = reading("replayed", "muse:configured", 84, 1300, "muse")
replay.windows[1].resets_at_ms = 1000
local _, replayed_cycle = retain({ replay }, zero_saved)
check(replayed_cycle[1].windows[1].used == 0 and replayed_cycle[1].windows[1].observed_at_ms == 1200,
	"a replayed old reset cycle cannot replace the new cycle even with a newer transport timestamp")
local _, reversed_replay = retain({ replay, zero })
check(reversed_replay[1].windows[1].used == 0,
	"old-cycle rejection is independent of input ordering")
local partial_muse = reading("vm:muse", "muse:configured", 87, 300, "muse")
partial_muse.plan = nil
partial_muse.windows[1].resets_at_ms = nil
local _, partial_saved = retain({ partial_muse }, restarted)
check(partial_saved[1].windows[1].used == 87 and partial_saved[1].windows[1].resets_at_ms == 1000
	and partial_saved[1].windows[1].reset_observed_at_ms == 100
	and partial_saved[1].windows[1].observed_at_ms == 300,
	"a newer partial numeric reading preserves same-cycle reset detail at its original observation time")
local unresolved_reset = reading("same-observation", "muse:configured", 85, 250, "muse")
unresolved_reset.windows[1].resets_at_ms = nil
local _, unresolved_reset_saved = retain({ unresolved_reset })
local resolved_reset = reading("same-observation", "muse:configured", 85, 250, "muse")
resolved_reset.windows[1].resets_at_ms = 1000
resolved_reset.windows[1].reset_observed_at_ms = 250
local _, detailed_reset_saved = retain({ resolved_reset }, unresolved_reset_saved)
check(detailed_reset_saved[1].windows[1].used == 85
	and detailed_reset_saved[1].windows[1].resets_at_ms == 1000
	and detailed_reset_saved[1].windows[1].observed_at_ms == 250,
	"reset resolution can add detail to the same observation without inventing a newer reading")
local missing_quota = table.clone(unavailable_copy)
missing_quota.windows = {{ key = "seven_day", pool = "default", observed_at_ms = 400,
	unavailable_reason = "unavailable" }}
local _, missing_saved = retain({ missing_quota }, partial_saved)
check(missing_saved[1].windows[1].used == 87 and missing_saved[1].windows[1].observed_at_ms == 300,
	"a newer nonnumeric window cannot erase or freshen a saved allowance")
local no_reset_zero = reading("vm:muse", "muse:configured", 0, 1200, "muse")
no_reset_zero.windows[1].resets_at_ms = nil
local _, resetless_saved = retain({ no_reset_zero }, restarted)
local _, resetless_replay = retain({ replay }, resetless_saved)
check(resetless_replay[1].windows[1].used == 0 and resetless_replay[1].windows[1].resets_at_ms == nil,
	"a fresh zero without a reset cannot inherit or be replaced by a replayed expired reset")
local separate_pool = reading("vm:pool", "muse:configured", 10, 150, "muse")
separate_pool.windows[1].pool = "secondary"
local _, pool_saved = retain({ separate_pool }, restarted)
check(#pool_saved == 2, "retention keeps independent quota pools instead of observation history")
local alias_window = reading("vm:weekly", "muse:configured", 89, 500, "muse")
alias_window.windows[1].key, alias_window.windows[1].pool = "weekly", "all"
alias_window.windows[1].resets_at_ms = nil
local _, normalized_saved = retain({ alias_window }, partial_saved)
check(#normalized_saved == 1 and normalized_saved[1].windows[1].key == "seven_day"
	and normalized_saved[1].windows[1].pool == "default", "retention uses the same window aliases as account grouping")
local unidentified_muse = reading("unknown:muse", nil, 22, 500, "muse")
local untouched, no_muse_saved = accounts.retain_muse({ older, unidentified_muse, cold_unavailable })
check(#untouched == 3 and untouched[1] == older and untouched[2] == unidentified_muse
	and #no_muse_saved == 0, "non-Muse readings are unchanged; unidentified or cold unavailable sources create no inventory")
local current_conflict = retain({ muse_conflict, unavailable_copy }, restarted)
local retained_conflict_groups = accounts.group(current_conflict)
check(#retained_conflict_groups == 2, "saved aliases must not collapse conflicting canonical accounts")

return "PASS " .. tostring(checks) .. " account identity and grouping checks"
