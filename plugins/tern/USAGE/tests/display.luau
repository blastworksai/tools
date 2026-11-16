-- Run through tests/run_luau.luau in the isolated native harness.
local root = ...
local checks = 0
local function check(value, message) assert(value, message); checks += 1 end
local native, modules, definition, calls = tern, {}, nil, {}
local accessResult, accessError = nil, nil
local fake = setmetatable({ block = { define = function(id, value)
	check(id == "display", "declares display block only"); definition = value
end }, runtime = { os = "linux" } }, { __index = native })
local function load(name)
	name = name:gsub("^%./", "")
	if modules[name] then return modules[name] end
	if name == "companion" then return { request = function(op, payload, done)
		table.insert(calls, op); check(op == "display_access" and next(payload) == nil, "consumer cannot select effects")
		done(accessResult, accessError)
	end } end
	local chunk = assert(loadstring(native.fs.read(root .. "/" .. name .. ".luau"), name))
	setfenv(chunk, setmetatable({ tern = fake, require = load }, { __index = getfenv() }))
	modules[name] = chunk(); return modules[name]
end
local display, snapshot, presentation = load("display"), load("snapshot"), load("presentation")
local now = math.floor(os.time() * 1000)
local binding = { handle = string.rep("b", 64), generation = 1, canonical_ids = { "claude:dummy" } }
local account = { id = "account", provider = "claude", provider_label = "Claude", account_label = "Demo",
	definition_revision = string.rep("d", 64), profile_binding = binding, canonical_ids = { "claude:dummy" }, reading_ids = { "reading" } }
local consumer = { id = "omp", label = "OMP · Demo", definition_revision = string.rep("e", 64),
	account_ids = { "account" }, reading_ids = {} }
local scope = { id = "host:dummy", revision = "roster", updated_at_ms = now,
	spawn_join = { namespace = "dummy", host_key = "host:dummy", config_revision = 4 }, accounts = { account }, consumers = { consumer } }
local raw = { version = 3, publisher = "dummy", as_of_ms = now, roster = { version = 1, scopes = { scope } }, readings = {
	{ id = "reading", provider = "claude", provider_label = "Claude", account_id = "claude:dummy", canonical_id = "claude:dummy",
		account_label = "Demo", source_label = "Dummy", usage_source = "headless", windows = {
			{ key = "five_hour", pool = "default", used = 12, remaining = 88, observed_at_ms = now },
			{ key = "seven_day", pool = "default", used = 72, remaining = 28, observed_at_ms = now, resets_at_ms = now + 1800000 } } } } }
local source = assert(snapshot.decode(raw))
local cache = { snapshots = { dummy = source }, revision = string.rep("c", 64), busy = false }
function cache:refresh(done) done(true) end
accessResult = { revision = string.rep("a", 64), source_id = "dummy", scopes = { scope } }
local request = { version = 1, request_id = "read-1", op = "snapshot" }
check(display.decode(native.json.encode(request)) ~= nil, "closed snapshot accepted")
for _, extra in { "refresh", "configure", "token", "path", "cursor", "revision" } do
	local bad = table.clone(request); bad[extra] = "forbidden"
	check(display.decode(native.json.encode(bad)) == nil, "snapshot rejects extra fields")
end
local ordinary = presentation.account_projection(snapshot.project(cache.snapshots, now).accounts[1], now)
local response = display.response(request, accessResult, cache, now, "linux")
check(response.ok and response.display_only and #response.records == 2, "complete display-only page")
local row = response.records[1]
check(row.used == ordinary.used and row.state == ordinary.state and row.text == ordinary.text, "same observation uses ordinary quota and status")
check(row.age_ms == 0 and row.observed_at_ms == now, "age uses observation not export time")
check(response.records[2].underlying_record_id == "account" and response.records[2].used == 72, "OMP uses explicit subscription only")
check(row.record_revision == 4 and response.records[2].record_revision == 4
	and row.definition_revision == account.definition_revision, "catalog numeric generation stays separate from semantic binding hash")
local old = display.response(request, accessResult, cache, now + 900001, "linux")
check(old.records[1].state == "stale" and old.records[1].age_ms == 900001 and old.records[1].used == 72, "cached numeric value ages without collection")
local bytes = native.json.encode(response)
for _, private in { "canonical_ids", "profile_binding", "windows", "reading_ids", "claude:dummy", "usage_source" } do
	check(not bytes:find(private, 1, true), "export contains no raw identity/reading fields")
end
local validate = { version = 1, request_id = "validation", op = "validate", revision = response.revision }
check(display.response(validate, accessResult, cache, now, "linux").ok, "same revision validates")
accessResult.revision = string.rep("f", 64)
local revoked = display.response(validate, accessResult, cache, now, "linux")
check(not revoked.ok and revoked.status == "revoked" and #revoked.records == 0, "mapping revision invalidates previously assembled pages")
scope.spawn_join.config_revision = 5
local changedCatalog = display.response(request, accessResult, cache, now, "linux")
check(changedCatalog.records[1].record_revision == 5 and changedCatalog.records[2].record_revision == 5
	and changedCatalog.records[1].definition_revision == row.definition_revision,
	"current authoritative catalog generation replaces old numeric joins without resetting unchanged account semantics")
scope.accounts[1].profile_binding = nil
local unbound = display.response(request, accessResult, cache, now, "linux")
check(unbound.records[1].used == nil and unbound.records[1].state == "unavailable", "revoked binding cannot borrow cached quota")
scope.consumers[1].account_ids = nil
check(display.response(request, accessResult, cache, now, "linux").records[2].underlying_record_id == nil, "unknown OMP association is not inferred")
for _, platform in { "windows", "macos", "ios" } do
	local hold = display.response(request, accessResult, cache, now, platform)
	check(not hold.ok and hold.status == "platform_hold" and #hold.records == 0, "native platform hold carries no readings")
end
-- Bounded pagination includes every record exactly once, followed by validation.
local many = {}
for index = 1, 40 do
	local item = table.clone(account); item.id = string.format("account-%02d", index); item.profile_binding = nil
	table.insert(many, item)
end
scope.accounts, scope.consumers = many, {}
local page = display.response(request, accessResult, cache, now, "linux")
local seen = {}
while true do
	check(page.ok and #page.records <= 16 and #native.json.encode(page) <= display.MAX, "page bounded")
	for _, entry in page.records do check(not seen[entry.record_id], "no duplicate rows"); seen[entry.record_id] = true end
	if page.complete then break end
	page = display.response({ version = 1, request_id = "next", op = "page", revision = page.revision, cursor = page.next_cursor }, accessResult, cache, now, "linux")
end
local count = 0; for _ in seen do count += 1 end
check(count == 40, "all paginated rows reachable")
display.install(cache)
local state, renders = definition.init(), 0
local cx = { render = function() renders += 1 end }
definition.event(state, { ev = "action", act = "usage.display", value = native.json.encode(request) }, cx)
check(state.response.ok and renders > 0 and #calls == 1, "native consumer executes actual read boundary")
local tree = definition.view(state)
check(tree.main.c[1].p.hidden == true and tree.main.c[1].p.key == display.NODE, "machine response hidden but addressable")
accessResult, accessError = nil, { code = "display_disabled" }
definition.event(state, { ev = "action", act = "usage.display", value = native.json.encode(request) }, cx)
check(not state.response.ok and state.response.status == "display_disabled" and #state.response.records == 0, "disable clears previous successful response")
definition.event(state, { ev = "action", act = "usage.display", value = '{"version":1,"request_id":"x","op":"configure"}' }, cx)
check(state.response.status == "invalid_request" and #calls == 2, "invalid effect request never reaches companion")
local direct = nil
display.request(cache, native.json.encode(request), function(value) direct = value end)
check(direct.status == "display_disabled" and #direct.records == 0, "pane-free display preserves revocation without native block context")
local before = #calls
display.request(cache, '{"version":1,"request_id":"bad","op":"usage_refresh"}', function(value) direct = value end)
check(direct.status == "invalid_request" and #calls == before, "pane-free display never collects providers")
return "PASS " .. tostring(checks) .. " display boundary checks"
