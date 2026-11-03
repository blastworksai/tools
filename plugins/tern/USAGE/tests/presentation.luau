-- Run in Tern: assert(loadstring(tern.fs.read(TEST_PATH)))(PLUGIN_DIR)
local root = ...
assert(type(root) == "string", "pass the plugin directory")
local modules, environment = {}, getfenv()
local function load(name)
	name = name:gsub("^%./", "")
	if modules[name] ~= nil then return modules[name] end
	local chunk = assert(loadstring(tern.fs.read(root .. "/" .. name .. ".luau"), name))
	setfenv(chunk, setmetatable({ require = load }, { __index = environment }))
	modules[name] = chunk()
	return modules[name]
end
local presentation, snapshot = load("presentation"), load("snapshot")
local checks = 0
local function check(condition, message) assert(condition, message); checks += 1 end
local now = math.floor(os.time() * 1000)
local function window(key, used, pool)
	return { key = key, pool = pool or "default", used = used, remaining = 100 - used,
		observed_at_ms = now, resets_at_ms = now + 120000 }
end
local function reading(id, provider, windows)
	return { id = id, account_id = id, account_label = "Synthetic " .. id,
		provider = provider, provider_label = provider, source_label = "Synthetic desktop",
		usage_source = "Synthetic desktop", last_reading_at_ms = now, windows = windows }
end
local function configure(raw)
	local entries = tern.json.array()
	for _, item in raw.readings do
		if item.account_id ~= nil then
			table.insert(entries, { id = item.id, provider = item.provider, provider_label = item.provider_label,
				account_label = item.account_label, canonical_ids = tern.json.array(), reading_ids = { item.id } })
		end
	end
	raw.roster = { version = 1, scopes = { { id = "host:" .. raw.publisher, revision = "fixture",
		updated_at_ms = now, accounts = entries, consumers = tern.json.array() } } }
	return raw
end
local raw = { version = 3, publisher = "synthetic-publisher", as_of_ms = now, readings = {
	reading("muse", "muse", { window("window", 100) }),
	reading("claude", "claude", { window("five_hour", 12), window("seven_day", 72) }),
	reading("openai", "openai", { window("seven_day", 0) }),
	reading("kimi", "kimi", tern.json.array()),
	reading("antigravity", "antigravity", { window("window", 83, "gemini"), window("window", 21, "claude_gpt") }),
} }
local source = assert(snapshot.decode(configure(raw)))
local model = snapshot.project({ [source.publisher] = source }, now)
local ordered = presentation.ordered_accounts(model.accounts)
local segments = presentation.segments(model)
local summary = presentation.summary(model)
check(summary.total_count == 5 and summary.current_count == 4
	and summary.header == "5 accounts · 4 current · 0 last-known · 1 unavailable",
	"configured counts distinguish numeric availability, including genuine zero")
check(#ordered == 5 and #segments == presentation.SUMMARY_LIMIT + 1
	and summary.visible_count + summary.overflow_count == #ordered, "bounded summary accounts for every input account")
check(ordered[1].provider == "claude" and ordered[2].provider == "openai" and ordered[5].provider == "antigravity",
	"status uses the established provider ordering")
check(presentation.account_projection(ordered[1]).used == 72, "weekly default quota wins over the five-hour fallback")
check(presentation.account_projection(ordered[5]).used == 21, "multiple named pools use the reducer's deterministic first fallback")
local reversed = table.clone(ordered[5])
reversed.windows = { ordered[5].windows[2], ordered[5].windows[1] }
check(presentation.account_window(reversed).pool == presentation.account_window(ordered[5]).pool,
	"window selection does not depend on incoming pool order")
check(presentation.ring(nil) ~= presentation.ring(0) and presentation.ring(0) ~= presentation.ring(1)
	and presentation.ring(99) ~= presentation.ring(100), "missing, zero, positive and full quota have distinct glyphs")
check(presentation.account_projection(ordered[2]).used == 0 and presentation.account_projection(ordered[3]).used == nil
	and segments[2].text ~= segments[3].text, "missing quota never appears as zero")
check(segments[1].tone == "warn" and segments[2].tone == "ok" and segments[3].tone == "muted"
	and presentation.account_projection(ordered[4]).tone == "error", "only supported status tones are emitted")
local stale = snapshot.project({ [source.publisher] = source }, now + 900001)
check(presentation.account_projection(stale.accounts[1]).state == "stale"
	and presentation.segments(stale)[1].tone == "muted", "stale numeric observations are not current usage")
local expired = table.clone(ordered[1])
expired.windows = { window("weekly", 100) }
expired.windows[1].resets_at_ms = now - 1
local expired_value = presentation.account_projection(expired, now)
check(expired_value.state == "reset_passed" and expired_value.used == 100 and expired_value.tone == "muted"
	and expired_value.text ~= presentation.account_projection(ordered[4]).text, "past reset preserves last known usage without presenting it as current")
check(select(2, expired_value.text:gsub("Reset passed", "")) == 1 and presentation.compact_countdown(expired_value, now) == nil,
	"an expired compact row states the passed reset exactly once")
local missing = table.clone(ordered[3])
missing.windows = { { key = "weekly", pool = "default", observed_at_ms = now, unavailable_reason = "not_yet_measured" } }
check(presentation.account_window(missing) == missing.windows[1] and presentation.account_projection(missing).used == nil,
	"unmeasured selected windows remain identifiable without inventing a quota")
local muse_waiting = table.clone(missing)
muse_waiting.provider = "muse"
local muse_known = table.clone(ordered[4])
muse_known.windows = { window("window", 0) }
muse_known.windows[1].freshness = "stale"
local availability = presentation.summary({ accounts = { muse_waiting, muse_known } }, now)
check(availability.current_count == 0 and availability.header == "2 accounts · 0 current · 1 last-known · 1 unavailable",
	"absent and retained measurements cannot count as current")
muse_known.windows[1].freshness = "fresh"
muse_known.windows[1].unavailable_reason = "not_yet_measured"
check(presentation.account_projection(muse_known, now).state == "last_known"
	and presentation.account_projection(muse_known, now).tone == "muted",
	"unavailable Muse refresh preserves a number as last-known even before its age threshold")
local retained = table.clone(ordered[1])
retained.windows = { window("weekly", 8) }
retained.windows[1].last_known_reason = "local_login_unavailable"
check(presentation.account_projection(retained, now).state == "last_known"
	and presentation.account_projection(retained, now).used == 8
	and retained.windows[1].observed_at_ms == now,
	"failed headless refresh labels a retained numeric observation last-known without renewing its measurement time")
local shuffled = table.clone(model)
shuffled.accounts = {}
for index = #ordered, 1, -1 do table.insert(shuffled.accounts, ordered[index]) end
check(tern.json.encode(presentation.segments(shuffled)) == tern.json.encode(segments),
	"account input order cannot alter bounded status membership")
for count = 0, presentation.SUMMARY_LIMIT do
	local small = { accounts = {} }
	for index = 1, count do table.insert(small.accounts, ordered[index]) end
	local small_summary = presentation.summary(small)
	check(small_summary.total_count == count and small_summary.overflow_count == 0
		and #presentation.segments(small) == math.max(1, count), "empty and within-cap summaries never invent overflow")
end
local mixed = table.clone(ordered[1])
mixed.windows = { window("five_hour", 12), window("seven_day", 72) }
mixed.windows[2].freshness = "stale"
check(presentation.account_projection(mixed).window.key == "seven_day"
	and presentation.account_projection(mixed).state == "stale",
	"a fresher alternate window never silently substitutes for the selected weekly allowance")
-- Compact quota selection prefers a measured weekly window of any pool, and the
-- countdown comes from that same window.
local function quota(key, used, pool, resets_at_ms)
	return { key = key, pool = pool, used = used, observed_at_ms = now, resets_at_ms = resets_at_ms }
end
local countdown_ms = (3 * 86400 + 9 * 3600 + 32 * 60 + 55) * 1000
local codex = reading("codex", "openai", { quota("five_hour", 40, "codex", now + 3600000), quota("seven_day", 8, "codex", now + countdown_ms) })
local codex_value = presentation.account_projection(codex, now)
check(codex_value.window.key == "seven_day" and codex_value.used == 8,
	"Codex's weekly window (pool codex) wins over its five-hour window")
check(codex_value.text .. " · " .. presentation.compact_countdown(codex_value, now) == "◔ 8% used · Resets in 03d 09:32:55",
	"compact row shows percentage and countdown of the same selected window")
local grok = reading("grok", "grok", { quota("monthly_code", 90, "grok", now + 60000), quota("seven_day", 30, "grok", now + 120000) })
check(presentation.account_projection(grok, now).window.key == "seven_day", "Grok's weekly window (pool grok) wins over other keys")
local weeklies = reading("weeklies", "antigravity", { quota("seven_day", 50, "gemini"), quota("seven_day", 10, "claude_gpt"), quota("seven_day", 20, "default"), quota("five_hour", 5, "default") })
check(presentation.account_projection(weeklies, now).used == 20, "among weekly windows the account-wide pool wins")
table.remove(weeklies.windows, 3)
local first = presentation.account_projection(weeklies, now).window
weeklies.windows = { weeklies.windows[3], weeklies.windows[2], weeklies.windows[1] }
check(first.pool == "claude_gpt" and presentation.account_projection(weeklies, now).window == first,
	"named weekly pools are chosen deterministically, independent of input order")
local unmeasured_weekly = reading("unmeasured", "claude", { quota("seven_day", nil, "default", now + countdown_ms), quota("five_hour", 12, "default", now + 61000) })
local unmeasured_value = presentation.account_projection(unmeasured_weekly, now)
check(unmeasured_value.window.key == "five_hour" and presentation.compact_countdown(unmeasured_value, now) == "Resets in 00d 00:01:01",
	"an unmeasured weekly never lends its reset to another window's percentage")
check(presentation.compact_countdown(presentation.account_projection(reading("no-reset", "kimi", { quota("seven_day", 12, "default") }), now), now) == nil,
	"an unknown reset produces no countdown")
check(presentation.countdown(now + 1, now) ~= "Reset passed" and presentation.countdown(now, now) == "Reset passed",
	"Reset passed appears exactly when the window state flips")
-- Real host blocks, reducer and UI builders; provider requests remain controlled.
local defs, events, timers, requests, log = {}, {}, {}, {}, {}
local live = { { pane = 21 }, { pane = 22 }, { pane = 23 } }
local renders, writes, acquisitions, flushes, source_changed = 0, 0, 0, 0, nil
local display_sources = { source }
local interval = 0
local status_value = { state = "idle", completed = 0, total = 5 }
local collector_health = nil
local display_error = nil
modules.companion = {
	request = function(operation, payload, done)
		table.insert(log, operation)
		if operation == "usage_refresh" then
			acquisitions += 1
			table.insert(requests, done)
		elseif operation == "usage_status" then done(status_value)
		elseif operation == "usage_preferences" then
			if payload.refresh_interval_seconds ~= nil then interval = payload.refresh_interval_seconds end
			done({ refresh_interval_seconds = interval })
		elseif operation == "display" then
			if display_error ~= nil then done(nil, display_error, nil); return end
			local parts = tern.json.array()
			for _, value in display_sources do
				local data = tern.json.encode(value)
				table.insert(parts, { publisher = value.publisher, index = 0, count = 1, size = #data, data = data })
			end
			done({ revision = "synthetic-display", parts = parts, complete = true }, nil, nil)
		else error("unexpected operation " .. operation) end
	end,
}
modules.source_collect = {
	start = function(callback) source_changed = callback end,
	stop = function() end,
	flush = function() flushes += 1 end,
	state = function() return collector_health end,
}
local runtime = {
	ui = tern.ui, json = tern.json,
	pane = { list = function() return live end },
	kv = { get = function() error("host must not read a duplicate layout/interval registry") end,
		set = function() writes += 1; error("host must not replace companion preferences") end },
	block = { define = function(id, value) defs[id] = value end },
	on = function(name, callback) events[name] = callback end,
	timer = function(delay, callback)
		local timer = { delay = delay, callback = callback, active = true }
		function timer:cancel() self.active = false end
		table.insert(timers, timer)
		return timer
	end,
}
local function context(pane)
	return { pane = pane, render = function() renders += 1 end,
		toast = function() error("account detail must never be a toast") end }
end
local cx, detail_cx, config_cx = context(21), context(22), context(23)
local chunk = assert(loadstring(tern.fs.read(root .. "/host.luau"), "host"))
setfenv(chunk, setmetatable({ tern = runtime, require = load }, { __index = environment }))
chunk()
local def, detail_def, config_def = defs.accounts, defs.account, defs.config
local state = def.init(cx, {}, nil)
local function has_span(value, text, tone)
	if type(value) ~= "table" then return false end
	if value.t == text and (tone == nil or value.s == tone) then return true end
	for _, child in value do if has_span(child, text, tone) then return true end end
	return false
end
local function count_roles(value, role)
	if type(value) ~= "table" then return 0 end
	local count = if value.role == role then 1 else 0
	for _, child in value do count += count_roles(child, role) end
	return count
end
local function links(value, result)
	result = result or {}
	if type(value) ~= "table" then return result end
	if value.href then result[value.href] = value.t end
	for _, child in value do if type(child) == "table" then links(child, result) end end
	return result
end
local function find_span(value, pattern)
	if type(value) ~= "table" then return nil end
	if type(value.t) == "string" and value.t:find(pattern) then return value.t end
	for _, child in value do
		local found = find_span(child, pattern)
		if found ~= nil then return found end
	end
	return nil
end
local function active(delay)
	local result = {}
	for _, timer in timers do if timer.active and timer.delay == delay then table.insert(result, timer) end end
	return result
end
-- Fires the timers armed so far; callbacks may arm new ones for the next call.
local function fire(delay)
	for _, timer in active(delay) do timer.active = false; timer.callback(nil) end
end
local function operations_since(mark)
	local seen = {}
	for index = mark + 1, #log do seen[log[index]] = (seen[log[index]] or 0) + 1 end
	return seen
end
local function publish(values)
	display_sources = values
	source_changed()
end
local compact = def.view(state, cx).main
check(find_span(compact, "^ · Resets in %d%dd %d%d:%d%d:%d%d$") ~= nil and find_span(compact, "%d+%% used$") ~= nil,
	"narrow compact rows show the selected quota with a seconds countdown")
check(#active(1000) == 1, "an open narrow block arms the one-second countdown render")
local renders_before, log_before = renders, #log
fire(1000)
check(renders > renders_before and #log == log_before and #active(1000) == 1,
	"countdown ticks re-render cached data without companion requests, then re-arm")
local targets = links(compact)
for _, account in ordered do
	check(targets["usage://account/" .. load("view_layout").encode(account.id)] ~= nil,
		"every compact row routes its exact canonical account to its originating window")
end
local detail_state = detail_def.init(detail_cx, { ordered[1].id }, nil)
local detail = detail_def.view(detail_state, detail_cx).main
check(count_roles(detail, "usage-account-card") == 1, "account detail renders one card, not the entire inventory")
check(has_span(detail, "12% used") and has_span(detail, "72% used"), "detail preserves every actual quota pool/window")
local saved_detail = detail_def.save(detail_state)
detail_state = detail_def.init(detail_cx, {}, saved_detail)
check(detail_state.account == ordered[1].id, "detail identity survives saved-block restoration")
state = def.init(cx, { "wide" }, nil)
check(state.mode == "wide", "wide mode renders full cards")
check(count_roles(def.view(state, cx).main, "usage-account-card") == #ordered, "wide exposes every configured account card")
local saved = def.save(state)
state = def.init(cx, {}, saved)
check(state.mode == "wide", "saved layout survives host reload rather than reverting to launch default")
local config = config_def.init(config_cx, {}, nil)
config_def.event(config, { ev = "action", act = "interval", value = "300" }, config_cx)
check(interval == 300 and writes == 0, "configuration persists cadence only through companion operation")
config_def.event(config, { ev = "action", act = "interval", value = "59" }, config_cx)
check(interval == 300, "invalid interval cannot reach companion persistence")
collector_health = { code = "source_publication_failed" }
check(has_span(config_def.view(config, config_cx).main, "Source collection: could not publish refresh results; last readings retained.", "error"),
	"configuration shows collector health")
collector_health = nil
def.event(state, { ev = "action", act = "refresh" }, cx)
def.event(state, { ev = "action", act = "refresh" }, cx)
check(acquisitions == 1, "rapid host Refresh clicks share one outstanding acquisition request")
status_value = { state = "running", completed = 1, total = 5 }
requests[1]({ state = "running", completed = 0, total = 5 })
local mark = #log
fire(1000)
local polled = operations_since(mark)
check(polled.usage_status == 1 and polled.display == nil and polled.usage_preferences == nil,
	"a running refresh polls only its status each second")
mark = #log
status_value = { state = "idle", completed = 5, total = 5, last_completed_ms = now }
fire(1000)
polled = operations_since(mark)
check(flushes == 1 and polled.display == 1, "refresh completion flushes the collector and reads the display once")
local crowded = { version = 3, publisher = "crowded", as_of_ms = now, readings = {} }
for index = 1, 11 do table.insert(crowded.readings, reading("known-" .. tostring(index), "openai", { window("weekly", index) })) end
configure(crowded)
crowded.roster.scopes[1].consumers = {
	{ id = "omp-unlinked", label = "OMP unlinked", reading_ids = tern.json.array() },
}
local crowded_source = assert(snapshot.decode(crowded))
publish({ crowded_source })
state = def.init(cx, { "bottom" }, nil)
local bottom = def.view(state, cx).main
check(find_span(bottom, "11 accounts · 11 current · 0 last%-known · 0 unavailable · OMP uses underlying subscriptions$") ~= nil,
	"bottom toolbar reports the full current/last-known/unavailable counts")
local bottom_links = links(bottom)
for _, account in snapshot.project({ crowded = crowded_source }, now).accounts do
	check(bottom_links["usage://account/" .. load("view_layout").encode(account.id)] ~= nil,
		"short bottom view keeps all eleven accounts accessible rather than clipping to summary limit")
end
state = def.init(cx, { "wide" }, nil)
publish({ { version = 2, publisher = "invalid" } })
check(count_roles(def.view(state, cx).main, "usage-account-card") == 11, "invalid aggregate retains complete prior inventory")
local waiting = configure({ version = 3, publisher = "waiting", as_of_ms = now,
	readings = { reading("waiting", "muse", {}) } })
publish({ waiting })
check(count_roles(def.view(state, cx).main, "usage-account-card") == 1, "complete publication removes withdrawn accounts")
check(count_roles(detail_def.view(detail_state, detail_cx).main, "usage-account-card") == 0,
	"open detail cannot keep displaying a removed identity")
-- A PIP for a definition merged into another host scope's row (same login).
local function login_reading(id, used)
	local value = reading(id, "claude", { window("seven_day", used) })
	value.account_id, value.canonical_id = "claude:merged", "claude:merged"
	return value
end
local function host_scope(id, definition, reading_id)
	return { id = id, revision = "fixture", updated_at_ms = now, consumers = tern.json.array(), accounts = {
		{ id = definition, provider = "claude", provider_label = "Claude", account_label = "Configured " .. definition,
			canonical_ids = tern.json.array(), reading_ids = { reading_id } } } }
end
local merged = assert(snapshot.decode({ version = 3, publisher = "merged", as_of_ms = now,
	readings = { login_reading("merged-a", 30), login_reading("merged-b", 40) },
	roster = { version = 1, scopes = { host_scope("host:a", "desktop", "merged-a"), host_scope("host:b", "laptop", "merged-b") } } }))
local merged_row = snapshot.project({ merged = merged }, now).accounts[1]
local merged_id = merged_row.also_configured[1].id
check(type(merged_id) == "string" and merged_id ~= merged_row.id, "the merged definition keeps its own row id")
publish({ merged })
local merged_state = detail_def.init(detail_cx, { merged_id }, nil)
check(count_roles(detail_def.view(merged_state, detail_cx).main, "usage-account-card") == 1
	and detail_def.title(merged_state) == "USAGE · Claude · Configured laptop",
	"a PIP for a definition merged into another scope's row still shows that account")
publish({ configure({ version = 3, publisher = "empty", as_of_ms = now, readings = {} }) })
local narrow_state = def.init(cx, {}, nil)
check(has_span(def.view(narrow_state, cx).main, presentation.EMPTY_TEXT), "an answered empty roster asks for SPAWN accounts")
display_error = { code = "companion_unavailable", message = "The local USAGE companion is unavailable." }
collector_health = { code = "companion_unavailable" }
source_changed()
local unavailable = def.view(narrow_state, cx).main
check(not has_span(unavailable, presentation.EMPTY_TEXT) and has_span(unavailable, display_error.message, "error")
	and find_span(unavailable, "^Source collection") == nil,
	"an unavailable companion is reported once and is not blamed on the SPAWN roster")
display_error, collector_health = nil, nil
local before = renders
live = {}
events.pane_exited({ pane = 21 })
events.pane_exited({ pane = 22 })
events.pane_exited({ pane = 23 })
publish({ source })
check(renders == before, "closed blocks receive no late source completion renders")
check(#active(1000) == 0 and #active(15000) == 0, "with no USAGE block open the host neither polls nor ticks")
return "PASS presentation: " .. checks .. " checks"
