-- Source-only bridge behavior; no provider processes, panes, or owner input.
local root = ...
local real, environment = tern, getfenv()
local modules, calls, timers = {}, {}, {}
local clock = 100
local fake_companion = {}
function fake_companion.set_client() end
function fake_companion.ensure(done) done({ ok = true }, nil) end
function fake_companion.request(operation, payload, done)
	table.insert(calls, { operation = operation, payload = payload, done = done })
end
local runtime = setmetatable({ now = function() return clock end, timer = function(_, callback)
	local timer = { callback = callback, cancel = function(self) self.cancelled = true end }
	table.insert(timers, timer)
	return timer
end }, { __index = real })
local function load(name)
	name = name:gsub("^%./", "")
	if name == "companion" then return fake_companion end
	if modules[name] ~= nil then return modules[name] end
	local chunk = assert(loadstring(real.fs.read(root .. "/" .. name .. ".luau"), name))
	setfenv(chunk, setmetatable({ require = load, tern = runtime }, { __index = environment }))
	modules[name] = chunk()
	return modules[name]
end
local source, snapshot = load("source_collect"), load("snapshot")
local checks = 0
local function check(value, message)
	assert(value, message)
	checks += 1
	-- Yield between cases so no Tern driver slice accumulates several of them.
	if type(await) == "function" then await(real.sleep(0)) end
end
local function result(provider, measured)
	provider = provider or "claude"
	local response = { version = 1, metadata = {
		principal = "person@example.test", principal_kind = "email", label = "Person" } }
	if measured ~= false then response.usage = { provider = provider, observed_at_ms = 1800000000123,
		windows = { { key = "seven_day", pool = "provider-pool", used = 28, remaining = 72,
			observed_at_ms = 1800000000123, resets_at_ms = 1800100000456, window_duration_mins = 10080 } } }
	else response.error = "local_login_unavailable" end
	return { token = "result-token", source = { device_id = "device", generation = "generation" }, previous = {},
		roster = { version = 1, scopes = { { id = "host:other", revision = "roster", updated_at_ms = 1800000000000,
			accounts = { { id = "account", provider = provider, provider_label = provider, account_label = "Account",
				canonical_ids = {}, reading_ids = {} } }, consumers = { { id = "omp", label = "OMP", reading_ids = {} } } } } },
		items = { { scope_id = "host:other", id = "account", revision = "definition", provider = provider,
			label = "Account", response = response } } }
end
for _, provider in { "claude", "openai", "antigravity", "grok", "kimi", "muse" } do
	local projected = assert(source.project(result(provider)))
	local reading = projected.readings[1]
	check(reading.provider == provider and reading.canonical_id ~= nil and reading.usage_source == "headless",
		"all six providers use canonical enrichment and headless provenance")
	check(reading.windows[1].pool == "provider-pool" and reading.windows[1].window_duration_mins == 10080, "provider pools and duration survive publication")
	check(#reading.windows == 1, "template placeholders do not become extra allowances")
	check(projected.roster.scopes[1].accounts[1].reading_ids[1] == reading.id, "every definition binds directly to its source reading without enrollment")
	check(#projected.roster.scopes[1].consumers == 1 and #projected.readings == 1, "OMP remains a consumer not a quota account")
end
local elsewhere = result()
elsewhere.source.device_id = "other-device"
check(assert(source.project(elsewhere)).readings[1].id ~= assert(source.project(result())).readings[1].id,
	"reading ids are scoped to their publishing device")
local credit_result = result("openai")
credit_result.items[1].response.usage.credit_balance = 0
local credited = assert(source.project(credit_result))
local credit_account = snapshot.project({ headless = credited }, 1800000000200).accounts[1]
check(credit_account.credit_balance == 0 and credit_account.windows[1].used == 28,
	"an exhausted credit balance is not missing and does not change rolling quota usage")
local credit_failed = result("openai", false)
credit_failed.previous[credited.readings[1].id] = credited.readings[1]
local credit_after_failure = snapshot.project({ headless = assert(source.project(credit_failed)) }, 1800000000200).accounts[1]
check(credit_after_failure.credit_balance == nil and credit_after_failure.windows[1].last_known_reason == "local_login_unavailable",
	"failed acquisition cannot present an old credit balance as current while quota remains explicitly last-known")
local original = assert(source.project(result()))
local old = original.readings[1]
local failed = result("claude", false)
failed.previous[old.id] = old
local retained = assert(source.project(failed)).readings[1]
local known
for _, window in retained.windows do if window.used ~= nil then known = window end end
check(known ~= nil and known.used == 28 and known.last_known_reason == "local_login_unavailable", "unavailable refresh retains same-identity value with explicit last-known cause")
check(known.observed_at_ms == 1800000000123 and known.resets_at_ms == 1800100000456,
	"retained measurement keeps exact original observation/reset times")
check(retained.last_reading_at_ms == 1800000000123, "failed attempt does not relabel account measurement time")
local anonymous = result("claude", false)
anonymous.items[1].response.metadata = nil
anonymous.previous[old.id] = old
local unlinked = assert(source.project(anonymous))
check(unlinked.readings[1].canonical_id == nil and unlinked.readings[1].account_id == nil
	and #unlinked.roster.scopes[1].accounts[1].canonical_ids == 0,
	"a response that proves no identity never inherits the previous login")
local function measured_window(model)
	for _, window in model.accounts[1].windows do if window.used ~= nil then return window end end
	return nil
end
local unlinked_window = measured_window(snapshot.project({ headless = unlinked }, 1800000000200))
check(unlinked_window ~= nil and unlinked_window.used == 28 and unlinked_window.last_known_reason == "local_login_unavailable",
	"the definition row still shows its last-known value through the direct binding")
anonymous.previous[old.id] = unlinked.readings[1]
local repeated = measured_window(snapshot.project({ headless = assert(source.project(anonymous)) }, 1800000000200))
check(repeated ~= nil and repeated.used == 28 and repeated.observed_at_ms == 1800000000123,
	"repeated failed reads keep the same last-known value without re-dating it")
failed.items[1].response.metadata.principal = "other@example.test"
local switched = assert(source.project(failed)).readings[1]
check(switched.canonical_id ~= old.canonical_id and switched.windows[1].used == nil, "different login cannot inherit old quota")
failed.items[1].response.metadata = nil
failed.items[1].revision = "new-definition"
local redefined = assert(source.project(failed)).readings[1]
check(redefined.id ~= old.id and redefined.windows[1].used == nil, "definition edit fences old retained quota")
for _, code in { "source_remote", "web_login_expired" } do
	local unavailable = result("claude", false)
	unavailable.items[1].response.error = code
	check(assert(source.project(unavailable)).readings[1].windows[1].unavailable_reason == code,
		"remote and expired-login reasons reach the display unchanged")
end
local unknown_code = result("claude", false)
unknown_code.items[1].response.error = "setup_required"
check(assert(source.project(unknown_code)).readings[1].windows[1].unavailable_reason == "source_usage_unavailable",
	"codes that are not reading reasons become the generic quota-unavailable reason")
local cold = result("muse")
cold.items[1].response.usage.windows = {}
cold.items[1].response.usage.unavailable_reason = "server_sent_no_usage"
check(assert(source.project(cold)).readings[1].windows[1].unavailable_reason == "server_sent_no_usage", "Muse awaits real turn honestly")
local measured_muse = assert(source.project(result("muse")))
local muse_old = measured_muse.readings[1]
cold.previous[muse_old.id] = muse_old
local muse_last = assert(source.project(cold))
local legacy_readings = real.json.decode(real.json.encode(measured_muse.readings))
for _, reading in legacy_readings do reading.usage_source = "last-good" end
local legacy = assert(snapshot.decode({ version = 3, publisher = "legacy", as_of_ms = 1800000000123, readings = legacy_readings }))
local aggregate = snapshot.project({ headless = muse_last, legacy = legacy }, 1800000000200)
local found = false
for _, account in aggregate.accounts do
	for _, window in account.windows do
		if window.used == 28 then
			check(window.last_known_reason == "server_sent_no_usage", "legacy Muse inventory cannot erase source last-known marker")
			found = true
		end
	end
end
check(found, "retained Muse quota reaches the aggregate")
local removed = result()
removed.items, removed.roster.scopes[1].accounts = {}, {}
removed.previous[old.id] = old
check(#assert(source.project(removed)).readings == 0, "removed accounts cannot leak from source retention")
local partial = result()
local invalid = result("openai")
invalid.items[1].id, invalid.roster.scopes[1].accounts[1].id = "other", "other"
invalid.items[1].response.version = 99
table.insert(partial.items, invalid.items[1])
table.insert(partial.roster.scopes[1].accounts, invalid.roster.scopes[1].accounts[1])
local isolated = assert(source.project(partial))
check(isolated.readings[1].windows[1].used == 28 and isolated.readings[2].windows[1].unavailable_reason == "unparsed",
	"one malformed provider response cannot block the other account's measured publication")
local orphaned = result()
table.insert(orphaned.items, { scope_id = "host:other", id = "missing", revision = "definition", provider = "claude",
	label = "Missing", response = { version = 1 } })
table.insert(orphaned.items, "not an item")
check(#assert(source.project(orphaned)).readings == 1, "an unattributable result is skipped instead of blocking every account")
local bad_label = result()
bad_label.items[1].label = "control\127label"
check(assert(source.project(bad_label)).readings[1].source_label == "Account",
	"an invalid result label falls back to the validated SPAWN label")
local many = result()
local template = many.items[1]
many.items, many.roster.scopes[1].accounts = {}, {}
for index = 1, 129 do
	local id = "account-" .. tostring(index)
	table.insert(many.roster.scopes[1].accounts, { id = id, provider = "claude", provider_label = "claude",
		account_label = "Account " .. tostring(index), canonical_ids = {}, reading_ids = {} })
	local item = table.clone(template)
	item.id = id
	table.insert(many.items, item)
end
check(#assert(source.project(many)).readings == 129, "more than 128 configured accounts still publish")

-- Heartbeat: register, read completed results, publish; state() reports failures only.
local updates = 0
source.start(function() updates += 1 end)
check(source.state() == nil, "a starting collector reports no failure")
check(calls[1].operation == "register_client", "source heartbeat registers its local host")
calls[1].done({ registered = true }, nil)
check(calls[2].operation == "usage_results", "polling only reads completed source results")
calls[2].done(result(), nil)
check(calls[3].operation == "usage_publish", "source bridge publishes normalized immutable token")
calls[3].done({ accepted = true }, nil)
check(updates == 1 and source.state() == nil, "accepted publication updates host display")
source.flush()
check(#calls == 4 and calls[4].operation == "usage_results", "flush reads results at once when idle")
source.flush()
check(#calls == 4, "a flush during an in-flight read is deferred, not dropped or doubled")
calls[4].done({ disabled = true }, nil)
check(#calls == 5 and calls[5].operation == "usage_results", "the deferred flush runs when the in-flight read ends")
calls[5].done({ disabled = true }, nil)
check(#calls == 5 and updates == 1, "a deferred flush runs once and an unchanged result does not redraw")
clock = 100 + 59999
source.flush()
check(calls[6].operation == "usage_results", "the host lease is not renewed on every heartbeat")
calls[6].done({ disabled = true }, nil)
clock = 100 + 60000
source.flush()
check(calls[7].operation == "register_client" and calls[7].payload.ttl_seconds == 90,
	"the host lease is renewed inside its 90 s lifetime")
calls[7].done({ registered = true }, nil)
calls[8].done(result(), nil)
calls[9].done(nil, { code = "conflict", message = "The request conflicts with existing state." })
check(updates == 2 and source.state() ~= nil and source.state().code == "source_publication_failed",
	"a rejected publication is reported and redraws instead of looking refreshed")
source.flush()
calls[10].done(nil, { code = "timeout", message = "The USAGE operation timed out." })
check(source.state().code == "source_usage_unavailable", "an unreadable result is reported")
source.flush()
local unpublishable = result()
unpublishable.source = nil
calls[11].done(unpublishable, nil)
check(source.state().code == "source_snapshot_rejected", "a result that cannot be projected is reported")
source.flush()
calls[12].done(result(), nil)
calls[13].done({ accepted = true }, nil)
check(updates == 5 and source.state() == nil, "the next accepted publication clears the failure with one redraw")
for _, call in calls do check(call.operation ~= "usage_refresh", "display heartbeat never acquires provider quota") end
local timer = timers[#timers]
timer.callback()
local pending = calls[#calls]
source.stop()
pending.done(result(), nil)
check(updates == 5 and source.state() == nil, "late source completion after stop cannot publish")
return "PASS source_collect: " .. checks .. " checks"
