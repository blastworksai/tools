-- Run in Tern: assert(loadstring(tern.fs.read(TEST_PATH)))(PLUGIN_DIR)
local root = ...
local runtime, environment = tern, getfenv()
local modules, requests, checks = {}, {}, 0
local function check(ok, why) assert(ok, why); checks += 1 end
modules.companion = { request = function(operation, payload, callback)
	check(operation == "display", "display assembler uses authenticated owner-local route only")
	table.insert(requests, { payload = payload, callback = callback })
end }
local function load(name)
	name = name:gsub("^%./", "")
	if modules[name] ~= nil then return modules[name] end
	local chunk = assert(loadstring(runtime.fs.read(root .. "/" .. name .. ".luau"), name))
	setfenv(chunk, setmetatable({ require = load }, { __index = environment }))
	local value = chunk(); modules[name] = value; return value
end
local assembler = load("aggregate").new()
local value = { version = 3, publisher = "fixture", as_of_ms = 1000, readings = {
	{ id = "fixture-reading", provider = "claude", provider_label = "Claude", source_label = "Synthetic Å", account_id = "claude:fixture", account_label = "Fixture",
		usage_source = "fixture", windows = { { key = "seven_day", pool = "default", used = 23, remaining = 77, observed_at_ms = 1000 } } },
} }
value.roster = { version = 1, scopes = { { id = "host:fixture", revision = "fixture", updated_at_ms = 1000,
	accounts = { { id = "fixture-account", provider = "claude", provider_label = "Claude", account_label = "Fixture",
		canonical_ids = { "claude:fixture" }, reading_ids = { "fixture-reading" } } }, consumers = {} } } }
local text = runtime.json.encode(value)
local split = math.floor(#text / 2)
while utf8.len(text:sub(1, split)) == nil do split -= 1 end
local function part(index, data, size, count)
	return { publisher = value.publisher, index = index, count = count or 2, size = size or #text, data = data }
end
local completed, failure, context = 0, nil, {}
local function start()
	assembler:refresh(function(ok, err, cx)
		completed += 1; failure = not ok
		check(cx == context, "completion forwards fresh callback context")
	end)
end
local function reply(page, err)
	local request = table.remove(requests, 1)
	assert(request, "expected page request")
	request.callback(page, err, context)
	return request.payload
end
start()
reply({ revision = "one", parts = { part(0, text:sub(1, split)) }, complete = false, next_cursor = "page-two" })
check(completed == 0 and next(assembler.snapshots) == nil, "first fragment cannot become a partial model")
check(requests[1].payload.cursor == "page-two", "next page uses opaque service cursor")
reply({ revision = "one", parts = { part(1, text:sub(split + 1)) }, complete = true })
check(completed == 1 and not failure and assembler.snapshots.fixture.as_of_ms == 1000, "complete model commits original timestamps atomically")
local old = assembler.snapshots
local projected = assembler:project(2000000)
check(projected.accounts[1].windows[1].used == 23 and projected.accounts[1].windows[1].freshness == "stale", "last-good quotas age rather than vanish")
start()
reply({ revision = "two", parts = { part(0, text:sub(1, split)) }, complete = false, next_cursor = "two-b" })
reply({ revision = "three", parts = { part(1, text:sub(split + 1)) }, complete = true })
check(failure and assembler.snapshots == old, "mixed revisions preserve last-good aggregate")
start()
reply({ revision = "two", parts = { part(0, text:sub(1, split)) }, complete = true })
check(failure and assembler.snapshots == old, "incomplete publication cannot commit")
start()
reply({ revision = "two", parts = { part(0, text, #text + 1, 1) }, complete = true })
check(failure and assembler.snapshots == old, "total UTF8 byte count is exact")
start()
reply({ revision = "two", parts = { part(0, text, #text, 1), part(0, text, #text, 1) }, complete = true })
check(failure and assembler.snapshots == old, "duplicate publisher cannot replace an earlier completed publication")
start()
reply({ revision = "two", parts = { part(0, string.char(255), 1, 1) }, complete = true })
check(failure and assembler.snapshots == old, "invalid UTF8 fragment never reaches the JSON decoder")
start()
reply({ revision = "two", parts = {}, complete = false, next_cursor = "loop" })
reply({ revision = "two", parts = {}, complete = false, next_cursor = "loop" })
check(failure and assembler.snapshots == old, "repeated cursor terminates rather than spinning a page chain")
start()
reply(nil, { code = "source_unreachable" })
check(failure and assembler.snapshots == old, "companion failure retains all previous accounts")
local muse = runtime.json.decode(text)
muse.readings[1].provider, muse.readings[1].provider_label = "muse", "Muse"
muse.readings[1].account_id = "muse:fixture"
muse.roster.scopes[1].accounts[1].provider = "muse"
muse.roster.scopes[1].accounts[1].provider_label = "Muse"
muse.roster.scopes[1].accounts[1].canonical_ids = { "muse:fixture" }
local muse_text = runtime.json.encode(muse)
start()
reply({ revision = "muse", parts = { part(0, muse_text, #muse_text, 1) }, complete = true })
check(not failure and #assembler:project(2000).accounts == 1, "authorized Muse reading enters canonical last-known model")
start()
reply({ revision = "empty", parts = {}, complete = true })
check(not failure and next(assembler.snapshots) == nil, "complete empty authorized revision removes withdrawn publishers")
check(#assembler:project(2000).accounts == 0, "a withdrawn authorized source leaves no account behind")
return "PASS " .. tostring(checks) .. " aggregate behavior checks"
