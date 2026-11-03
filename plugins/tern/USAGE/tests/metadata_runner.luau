-- Source-response boundary fixtures, exercised in Tern's Luau runtime.
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
local runner = load("metadata_runner")
local function identity()
	return { principal = "fixture@example.test", principal_kind = "email", label = "Fixture", workspace_id = "scope" }
end
local count = 0
local function test(name, body)
	local ok, err = pcall(body)
	assert(ok, name .. ": " .. tostring(err))
	count += 1
	if type(await) == "function" then await(tern.sleep(0)) end
end

test("only normalized account fields reach the consumer", function()
	local value = { version = 1, resets = {}, metadata = identity(), raw = "SECRET raw response", selectors = { CODEX_HOME = "/PRIVATE" } }
	value.metadata.access_token = "SECRET token"
	local projected = assert(runner.project(value))
	assert(projected.metadata.workspace_id == "scope")
	local encoded = tern.json.encode(projected)
	assert(not encoded:find("SECRET", 1, true) and not encoded:find("PRIVATE", 1, true))
end)

test("raw errors never become user-facing exception text", function()
	for _, code in { "source_timeout", "source_remote", "web_login_expired" } do
		assert(assert(runner.project({ version = 1, error = code })).error == code)
	end
	local unknown = assert(runner.project({ version = 1, error = "SECRET helper exception" }))
	assert(unknown.error == "source_usage_unavailable")
end)

test("malformed account identity is rejected before publication", function()
	for _, label in { "/PRIVATE/path", "   " } do
		local value = { version = 1, metadata = identity() }
		value.metadata.label = label
		assert(runner.project(value) == nil)
	end
end)

test("Muse cold state preserves its real observation and does not become zero quota", function()
	local value = assert(runner.project({ version = 1, metadata = identity(), usage = {
		provider = "muse", windows = {}, observed_at_ms = 1800000000000, unavailable_reason = "server_sent_no_usage", raw = "SECRET",
	} }))
	assert(#value.usage.windows == 0)
	assert(value.usage.observed_at_ms == 1800000000000)
	assert(value.usage.unavailable_reason == "server_sent_no_usage")
	assert(not tern.json.encode(value):find("SECRET", 1, true))
end)

test("usage windows are validated per pool", function()
	local function usage(window)
		return { version = 1, usage = { provider = "openai", observed_at_ms = 1800000000000, windows = { window } } }
	end
	local measured = assert(runner.project(usage({ key = "seven_day", pool = "codex", used = 8, remaining = 92,
		observed_at_ms = 1800000000000, resets_at_ms = 1800300000000 })))
	assert(measured.usage.windows[1].used == 8 and measured.usage.windows[1].pool == "codex")
	assert(runner.project(usage({ key = "seven_day", pool = "codex", used = 8, remaining = 91, observed_at_ms = 1800000000000 })) == nil)
	assert(runner.project(usage({ key = "seven_day", pool = "codex", unavailable_reason = "SECRET", observed_at_ms = 1800000000000 })) == nil)
end)

return "PASS " .. tostring(count) .. " metadata projection behavior checks"
