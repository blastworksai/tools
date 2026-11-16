-- Run in Tern: assert(loadstring(tern.fs.read(TEST_PATH)))(PLUGIN_DIR)
local root = ...
assert(type(root) == "string", "pass the plugin directory")
local modules, environment = {}, getfenv()
local function load(name)
	name = name:gsub("^%./", "")
	if modules[name] ~= nil then return modules[name] end
	local chunk = assert(loadstring(tern.fs.read(root .. "/" .. name .. ".luau"), name))
	setfenv(chunk, setmetatable({ require = load, tern = tern }, { __index = environment }))
	modules[name] = chunk()
	return modules[name]
end
local settings, prefs, layout = load("status_settings"), load("status_preferences"), load("view_layout")
local checks = 0
local function check(value, why) assert(value, why); checks += 1 end
check(settings.MASTER_LABEL == "Show usage statistics in status bar?" and settings.HEADING == "Per-Agent Status Bar selection:"
	and settings.WARNING == "Don’t overcrowd your status bar." and settings.OMP_REASON == "No independent usage allowance",
	"the contract's copy is exact")

local function row(id, provider, label, extra)
	local value = { id = id, provider = provider, provider_label = provider, account_label = label, windows = {} }
	for key, item in extra or {} do value[key] = item end
	return value
end
local model = { accounts = { row("spawn:1:s:b", "openai", "Two"), row("spawn:1:s:a", "claude", "One"), row("spawn:1:s:c", "kimi", "Three") },
	consumers = { { id = "omp-1", label = "Orchestrator", account_labels = {} } } }
local state = { version = 1, migration_complete = true, enabled = true, selected = { "spawn:1:s:a" } }
local snap = settings.snapshot(state, model)
check(snap.enabled and not snap.pending and #snap.accounts == 3 and snap.accounts[1].id == "spawn:1:s:a" and snap.accounts[1].selected
	and snap.accounts[1].label == "claude: One" and snap.accounts[2].id == "spawn:1:s:b" and not snap.accounts[2].selected,
	"the snapshot lists the full current roster in provider order with each choice")
check(#snap.consumers == 1 and snap.consumers[1].label == "OMP: Orchestrator", "OMP records are listed, never as accounts")
check(settings.snapshot({ version = 1, migration_complete = false, enabled = false, selected = {} }, model).pending, "a pending migration is visible")
check(#settings.snapshot(state, { accounts = {} }).accounts == 0, "an empty roster gives an empty list")
local huge = { accounts = {} }
for index = 1, prefs.MAX_ROSTER + 9 do table.insert(huge.accounts, row("id-" .. string.format("%03d", index), "claude", "n" .. index)) end
check(#settings.snapshot(state, huge).accounts == prefs.MAX_ROSTER, "the roster section is bounded")
local long_id = { accounts = { row(string.rep("z", prefs.MAX_ID + 1), "claude", "Long") } }
check(#settings.snapshot(state, long_id).accounts == 0, "an id too long to store is not offered")
local full_state = { version = 1, migration_complete = true, enabled = true, selected = {} }
local wide = { accounts = {} }
for index = 1, prefs.MAX_SELECTED + 1 do
	local item = row("w" .. string.format("%02d", index), "claude", "W" .. index)
	table.insert(wide.accounts, item)
	if index <= prefs.MAX_SELECTED then table.insert(full_state.selected, item.id) end
end
local full_snap = settings.snapshot(full_state, wide)
local full_by_id = {}
for _, item in full_snap.accounts do full_by_id[item.id] = item end
check(full_by_id.w01.full == false and full_by_id.w17.full == true and full_by_id.w17.selected == false, "only unticked rows are marked full once the bound is reached")

local encoded = tern.json.encode(snap)
local decoded = settings.decode(encoded)
check(decoded ~= nil and #decoded.accounts == 3 and decoded.accounts[1].selected == true and decoded.consumers[1].id == "omp-1", "a pushed snapshot round-trips")
check(settings.decode("{") == nil and settings.decode(nil) == nil and settings.decode(string.rep("x", settings.MAX_STATE_BYTES + 1)) == nil, "bad or oversized pushes are refused")
for _, bad in { { version = 2 }, { version = 1, enabled = true, pending = false, accounts = { { id = "", label = "x", selected = true, full = false } }, consumers = {} },
	{ version = 1, enabled = true, pending = false, accounts = { { id = "a", label = "x", selected = "yes", full = false } }, consumers = {} },
	{ version = 1, enabled = true, pending = false, accounts = {}, consumers = { { id = "o" } } } } do
	check(settings.decode(tern.json.encode(bad)) == nil, "a malformed push is refused")
end

local function decode(value) return layout.decode(value) end
local function url(path) return path:match("^usage://status/(.+)$") end
local sync = settings.parse_link("sync", decode)
check(sync ~= nil and sync.kind == "sync", "sync parses")
local master_on, master_off = settings.parse_link(url(settings.master_url(true)), decode), settings.parse_link(url(settings.master_url(false)), decode)
check(master_on.kind == "master" and master_on.on == true and master_off.on == false, "master links round-trip")
local awkward = "spawn:3:a/b:id with space/on"
local account = settings.parse_link(url(settings.account_url(awkward, true, layout.encode)), decode)
check(account.kind == "account" and account.id == awkward and account.on == true, "an account id with slashes and spaces round-trips")
check(settings.parse_link(url(settings.account_url("x", false, layout.encode)), decode).on == false, "an untick parses")
for _, bad in { "master/maybe", "account/abc", "account//on", "account/abc/maybe", "account/%ZZ/on", "other", "" } do
	check(settings.parse_link(bad, decode) == nil, "malformed status links are ignored: " .. bad)
end
-- Block events become links; controls that should not ask do not.
local function link(event) return settings.link_for_event(event, layout.encode) end
check(link({ ev = "change", name = "status_master", checked = true }) == "usage://status/master/on", "master change asks for the master link")
check(link({ ev = "change", name = "status_account", value = "a", checked = false }) == "usage://status/account/a/off", "account change asks for its link")
check(link({ ev = "change", name = "status_omp", value = "o", checked = true }) == nil and link({ ev = "action", name = "status_master", checked = true }) == nil
	and link({ ev = "change", name = "status_account", checked = true }) == nil and link({ ev = "change", name = "status_master" }) == nil, "OMP, non-change and incomplete events ask for nothing")
return "PASS status_settings: " .. checks .. " checks"
