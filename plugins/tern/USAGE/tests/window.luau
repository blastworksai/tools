-- Run in Tern: assert(loadstring(tern.fs.read(TEST_PATH)))(PLUGIN_DIR)
local root = ...
local runtime, environment = tern, getfenv()
local checks, preferences = 0, {}
local function check(value, why) assert(value, why); checks += 1 end
local function forbidden() error("owner pane input, provider process or unrelated mutation") end
local STATUS_KEY = "usage_status_prefs"
local function launch(supports_unload, installed)
	local state = { prompt_asks = {}, companion_data = installed == true, commands = {}, hooks = {}, requests = {}, timers = {}, panes = {
		{ pane = 11, tab = 1, title = "Editor" }, { pane = 22, tab = 1, title = "Owner agent" },
		{ pane = 33, tab = 2, title = "Other window tab" },
	}, focus = 11, created = {}, closed = {}, floats = {}, prompts = {}, events = {} }
	local cx = { session = {}, layout = {}, settings = {}, run = forbidden }
	function cx:window_key() return "fixture-window" end
	function cx.session:panes() return state.panes end
	function cx.session:focused() return state.focus end
	function cx.session:event(id, event) table.insert(state.events, { id = id, event = event }) end
	function cx.layout:focus(id) state.focus = id end
	function cx.layout:close(id)
		for index, pane in state.panes do
			if pane.pane == id then check(pane.block == "usage.accounts" or pane.block == "usage.config", "close never targets an owner or detail pane"); table.remove(state.panes, index); table.insert(state.closed, id); return end
		end
		error("missing close target")
	end
	function cx.layout:float(id, owner, corner, opts)
		check(state.created[#state.created].id == id and state.created[#state.created].kind == "usage.account", "float targets freshly created owned detail")
		table.insert(state.floats, { id = id, owner = owner, corner = corner, opts = opts })
		return not state.float_failure, state.float_failure
	end
	cx.layout.move, cx.layout.resize, cx.layout.split = forbidden, forbidden, forbidden
	function cx:new_block(kind, args, how, opts)
		check(how == "beside" and opts.target ~= nil and opts.ratio > 0 and opts.ratio < 1, "real split uses an explicit target and ratio")
		if state.create_failure then return nil end
		local tab
		for _, pane in state.panes do if pane.pane == opts.target then tab = pane.tab end end
		local id = 100 + #state.created
		table.insert(state.created, { id = id, kind = kind, args = args, how = how, opts = opts })
		table.insert(state.panes, { pane = id, block = kind, tab = tab })
		if opts.focus then state.focus = id end
		return id
	end
	function cx:prompt(opts)
		return { next = function(_, callback) table.insert(state.prompts, callback) end }
	end
	function cx:pick() return { next = function() end } end
	function cx:toast(kind, title, body)
		state.toasts = state.toasts or {}
		table.insert(state.toasts, { kind = kind, title = title, body = body })
	end
	function cx.settings:get() return false end
	local fake = table.clone(runtime)
	fake.kv = { get = function(key) return preferences[key] end, set = function(key, value)
		check(key == "usage_layout" or key == STATUS_KEY, "UI stores only layout and the status-bar choice, not acquisition cadence"); preferences[key] = value
	end }
	fake.process, fake.fetch = { run = forbidden }, forbidden
	fake.timer = function(ms, callback)
		local timer = { ms = ms, callback = callback, cancelled = false }
		function timer:cancel() self.cancelled = true end
		table.insert(state.timers, timer); return timer
	end
	fake.command = function(value) state.commands[value.id] = value end
	local window_events = { window_start = true, focus = true, pane_created = true, pane_closed = true,
		tab_created = true, tab_closed = true, command_started = true, command_finished = true,
		cwd = true, title = true, agent_finished = true, agent_state = true,
		float_moved = true, session_ended = true, budget = true, canvas_action = true }
	window_events.unload = supports_unload == true
	fake.on = function(name, callback)
		if not window_events[name] then error('tern.on: unknown window event `' .. name .. '`', 0) end
		state.hooks[name] = callback
	end
	fake.route = { link = function(callback) state.route = callback end }
	fake.files = { button = function() error("USAGE lives in the status bar; it registers no Files button") end }
	fake.plugin = { data = "/fixture/usage", dir = "/fixture/usage-code" }
	fake.fs = { exists = function() return state.companion_data end }
	fake.chrome = { status = function(callback) state.status = callback end, refresh = function() end }
	fake.context = "window"
	fake.log = { warn = function(message) state.lifecycle_warning = message end }
	local modules = { companion = {
		set_client = function() end, invalidate = function() end,
		unload = function() state.unloaded = true end,
		renew = function(done) table.insert(state.requests, { operation = "register_client", callback = done }) end,
		ensure = function(done) table.insert(state.requests, { operation = "ensure", callback = done }) end,
		request = function(operation, payload, done) table.insert(state.requests, { operation = operation, payload = payload, callback = done }) end,
	}, ["updater/window"] = { register = function(cfg) state.updater = cfg end },
		["status/status_prompt"] = { ensure = function(_cx, id) table.insert(state.prompt_asks, id) end } }
	local lifecycle = assert(loadstring(runtime.fs.read(root .. "/companion.luau"), "companion lifecycle"))
	setfenv(lifecycle, setmetatable({ tern = fake }, { __index = environment }))
	modules.companion.on_unload = lifecycle().on_unload
	local function load(name)
		name = name:gsub("^%./", "")
		if modules[name] then return modules[name] end
		local chunk = assert(loadstring(runtime.fs.read(root .. "/" .. name .. ".luau"), name))
		setfenv(chunk, setmetatable({ tern = fake, require = load }, { __index = environment }))
		modules[name] = chunk(); return modules[name]
	end
	state.entry, state.cx = load("window"), cx
	function state:reply(operation, value, err)
		for index, request in self.requests do
			if request.operation == operation then table.remove(self.requests, index); request.callback(value, err, cx); return end
		end
		error("no pending " .. operation)
	end
	function state:tick()
		for index, timer in self.timers do
			if not timer.cancelled then table.remove(self.timers, index); timer.callback(cx); return end
		end
		error("no timer")
	end
	function state:link(pane, url) return self.route({ pane = pane, url = url }, cx) end
	return state, load
end
preferences[STATUS_KEY] = { version = 1, migration_complete = true, enabled = true, selected = {} }
local state, load = launch()
check(#state.created == 0 and state.focus == 11, "startup does not create or focus panes")
local updater_keys = 0
for _ in state.updater or {} do updater_keys += 1 end
check(updater_keys == 3 and state.updater.name == "USAGE" and state.updater.dir == "USAGE" and state.updater.title_prefix == "USAGE ",
	"window registers the updater with USAGE's name, dir and title prefix")
local starting = runtime.json.encode(state.status({}))
check(starting:find("USAGE loading", 1, true) ~= nil and starting:find("SPAWN", 1, true) == nil,
	"before the companion answers, the status bar does not blame the SPAWN roster")
state:tick()
state:reply("ensure", {})
state:reply("display", { revision = "empty", parts = {}, complete = true })
state:reply("usage_status", { state = "idle", completed = 0, total = 0 })
local empty = runtime.json.encode(state.status({}))
check(empty:find("Define accounts in SPAWN", 1, true) ~= nil and empty:find("not yet measured", 1, true) == nil,
	"a ready empty roster asks for SPAWN accounts once, without a contradicting segment")
check(#state.created == 0, "display and status polling never acquire via owner panes")
state.commands.refresh.run(state.cx)
state.commands.refresh.run(state.cx)
check(#state.requests == 1 and state.requests[1].operation == "usage_refresh", "rapid manual clicks coalesce before acknowledgement")
state:reply("usage_refresh", { state = "running", completed = 0, total = 11 })
local status = runtime.json.encode(state.status({}))
check(status:find("Refreshing", 1, true) ~= nil, "queued acquisition is not completion")
state.commands.details.run(state.cx)
local narrow = state.created[1]
check(narrow.kind == "usage.accounts" and narrow.args[1] == "narrow" and narrow.opts.dir == "right", "default opens a real sidebar")
state.commands.details.run(state.cx)
check(#state.created == 1, "repeat open reuses same-tab owned list")
local account = "claude:email+name@example/a"
local encoded = load("view_layout").encode(account)
check(load("view_layout").decode(encoded) == account, "canonical account ids survive URL encoding")
state:link(narrow.id, "usage://account/" .. encoded)
local detail = state.created[2]
check(detail.args[1] == account and state.floats[1].id == detail.id and state.floats[1].owner == 11, "detail floats atomically over originating content owner, not sidebar or focused pane")
state:link(narrow.id, "usage://account/" .. encoded)
check(#state.created == 2 and #state.floats == 1, "rapid same-account clicks reuse the owned detail")
state:link(22, "usage://account/forged")
check(#state.created == 2, "unowned pane cannot invoke plugin layout mutations")
state:link(narrow.id, "usage://config")
local config = state.created[3]
state:link(config.id, "usage://layout/wide")
check(preferences.usage_layout == "wide" and state.created[4].opts.dir == "right" and state.closed[1] == narrow.id, "wide replaces only list and persists successful placement")
state:link(config.id, "usage://layout/bottom")
check(preferences.usage_layout == "bottom" and state.created[5].opts.dir == "down", "bottom opens below the owner")
state.create_failure = true
state:link(config.id, "usage://layout/narrow")
check(preferences.usage_layout == "bottom" and #state.closed == 2, "failed replacement retains current pane and preference")
state.create_failure = false
state:link(config.id, "usage://interval/custom")
state.prompts[1](nil, nil, state.cx)
check(#state.requests == 0, "dismissed prompt cannot change source cadence")
state:link(config.id, "usage://interval/custom")
state:link(config.id, "usage://interval/60")
local event_count = #state.events
state.prompts[2]("300", nil, state.cx)
check(#state.events == event_count and state.events[event_count].event.value == "60", "preset supersedes an outstanding custom prompt")
state:link(config.id, "usage://interval/custom")
state.prompts[3]("60.5", nil, state.cx)
check(state.events[#state.events].event.act == "config_error", "fractional custom interval rejected without mutation")
state:link(config.id, "usage://interval/custom")
state.prompts[4]("86400", nil, state.cx)
check(state.events[#state.events].event.act == "interval" and state.events[#state.events].event.value == "86400", "valid custom interval goes to companion-backed config block")
state.float_failure = "fixture float unavailable"
state:link(state.created[5].id, "usage://account/second")
check(state.events[#state.events].event.act == "pip_error", "float failure remains explicit on real detail split")
local restored = launch()
restored.commands.details.run(restored.cx)
check(restored.created[1].args[1] == "bottom", "new VM reads persisted local layout")
restored.focus = 33
restored.commands.details.run(restored.cx)
local other_list = restored.created[2]
restored.focus = 11
restored:link(other_list.id, "usage://account/other-tab")
check(restored.floats[1].owner == 33, "link origin, not current focus, selects the account PIP's tab and content owner")
restored:link(other_list.id, "usage://config")
local closing_config = restored.created[4]
restored:link(closing_config.id, "usage://interval/custom")
restored:link(11, "usage://config/close")
restored:link(other_list.id, "usage://config/close")
check(#restored.closed == 0, "close route cannot dismiss an owner or accounts pane")
restored.focus = 11
restored:link(closing_config.id, "usage://config/close")
check(#restored.closed == 1 and restored.closed[1] == closing_config.id and restored.focus == 11, "close targets the originating configuration without moving owner focus")
local events_before = #restored.events
restored.prompts[1]("600", nil, restored.cx)
check(#restored.events == events_before, "closed config pane cannot apply a late prompt choice")
-- Exercise source preference serialization and stale callback exclusion directly.
local refresh = load("view_state").new(function() end)
refresh:read_preferences()
refresh:set_interval(60)
refresh:set_interval(900)
state:reply("usage_preferences", { refresh_interval_seconds = 0 })
check(refresh.preferences == nil, "late initial preference read cannot overwrite a newer intent")
state:reply("usage_preferences", { refresh_interval_seconds = 60 })
check(refresh.saving, "rapid interval choices serialize rather than race at the service")
state:reply("usage_preferences", { refresh_interval_seconds = 900 })
check(refresh.preferences.refresh_interval_seconds == 900 and not refresh.saving, "last chosen interval is the confirmed source value")
refresh:poll()
refresh:refresh()
state:reply("usage_refresh", { state = "running", completed = 0, total = 11 })
state:reply("usage_status", { state = "idle", completed = 11, total = 11 })
check(refresh.progress.state == "running", "pre-refresh status response cannot overwrite a new running acknowledgement")
refresh:poll()
state:reply("usage_status", nil, { message = "Hub unreachable" })
check(refresh:text():find("Hub unreachable", 1, true) ~= nil, "transport failure remains truthful while retaining last progress")
refresh.progress = { state = "idle", last_completed_ms = 1000, failures = { { account = "Example account", code = "source_timeout" } } }
refresh.problem = nil
check(refresh:text():find("1 issue", 1, true) ~= nil and refresh:text():find("Example account", 1, true) == nil,
	"completed refresh counts issues; the configuration pane names them")
restored.commands.refresh.run(restored.cx)
restored:reply("usage_refresh", nil, { code = "source_roster_invalid", message = "SPAWN's account list is invalid." })
check(restored.toasts ~= nil and #restored.toasts == 1 and restored.toasts[1].kind == "error"
	and restored.toasts[1].body == "SPAWN's account list is invalid.",
	"a failed palette Refresh is reported even when the status bar is hidden")
-- A window attached to a remote host refreshes that host through its own USAGE pane, never this machine's companion.
local function on_host(kind)
	local window = launch()
	window.cx.hosts = { current = function() return { id = 2, kind = kind, name = "vm-orch", state = "connected" } end }
	return window
end
local attached = on_host("remote")
attached.commands.refresh.run(attached.cx)
check(#attached.requests == 0 and #attached.events == 0 and #attached.created == 0 and attached.toasts[1].kind == "error"
	and attached.toasts[1].title == "USAGE refresh on host vm-orch",
	"without a USAGE pane on the host, Refresh opens none, refreshes nothing locally and says why")
table.insert(attached.panes, { pane = 44, tab = 1, block = "usage.accounts" })
attached.commands.refresh.run(attached.cx)
check(#attached.requests == 0 and #attached.events == 1 and attached.events[1].id == 44 and attached.events[1].event.act == "refresh"
	and attached.toasts[2].kind == "info" and attached.toasts[2].title == "USAGE refresh on host vm-orch",
	"Refresh is requested from the host's USAGE block and labelled with the host")
local local_host = on_host("local")
local_host.commands.refresh.run(local_host.cx)
check(#local_host.events == 0 and #local_host.requests == 1 and local_host.requests[1].operation == "usage_refresh",
	"a window on a local host refreshes its own companion as before")
check(state.lifecycle_warning ~= nil, "a runtime without unload keeps the bounded lease-expiry path instead of failing load")
local unloading = launch(true)
unloading:tick()
check(#unloading.requests == 1 and unloading.requests[1].operation == "ensure", "unload fixture has a real pending startup")
unloading.hooks.unload(unloading.cx)
unloading:reply("ensure", {})
check(unloading.unloaded and #unloading.requests == 0, "a late startup completion after unload cannot request display or renew a lease")
for _, timer in unloading.timers do check(timer.cancelled, "unload cancels this window's pending poll") end

-- Status-bar selection: launcher, migration, settings links, account clicks.
local function reset_store(values)
	for key in preferences do preferences[key] = nil end
	for key, value in values or {} do preferences[key] = value end
end
local now_ms = math.floor(os.time() * 1000)
local function display_for(accounts)
	local readings, entries = {}, runtime.json.array()
	for _, item in accounts do
		table.insert(readings, { id = item.id, account_id = item.id, account_label = item.label, provider = item.provider, provider_label = item.provider,
			source_label = "Synthetic", usage_source = "Synthetic", last_reading_at_ms = now_ms,
			windows = { { key = "seven_day", pool = "default", used = item.used, remaining = 100 - item.used, observed_at_ms = now_ms, resets_at_ms = now_ms + 3600000 } } })
		table.insert(entries, { id = item.id, provider = item.provider, provider_label = item.provider, account_label = item.label,
			canonical_ids = runtime.json.array(), reading_ids = { item.id } })
	end
	local raw = { version = 3, publisher = "synthetic", as_of_ms = now_ms, readings = readings,
		roster = { version = 1, scopes = { { id = "host:synthetic", revision = "fixture", updated_at_ms = now_ms, accounts = entries, consumers = runtime.json.array() } } } }
	local data = runtime.json.encode(raw)
	return { revision = "r" .. tostring(#data) .. tostring(math.random(1, 1000000)), complete = true,
		parts = { { publisher = "synthetic", index = 0, count = 1, size = #data, data = data } } }
end
local roster = { { id = "c1", provider = "claude", label = "One", used = 40 }, { id = "o1", provider = "openai", label = "Two", used = 10 },
	{ id = "k1", provider = "kimi", label = "Three", used = 95 }, { id = "g1", provider = "grok", label = "Four", used = 5 } }
local function ready(window, accounts, polled)
	if not polled then window:tick() end
	window:reply("ensure", {})
	window:reply("display", display_for(accounts))
	window:reply("usage_status", { state = "idle", completed = 0, total = 0 })
end
local function status_text(window) return runtime.json.encode(window.status({})) end
local function stored() return preferences[STATUS_KEY] end

-- Fresh install: the bar is the lone launcher, master Off, no files button, prompt asked once from the window start path.
reset_store()
local fresh = launch(false, false)
check(stored().enabled == false and stored().migration_complete == true and #stored().selected == 0, "a fresh install records master Off and nothing selected")
local launcher_only = fresh.status({})
check(#launcher_only == 1 and launcher_only[1].text == "USAGE" and launcher_only[1].icon == "gauge" and launcher_only[1].command == "plugin.usage.details",
	"the fixed launcher is the only segment while loading on a fresh install")
check(fresh.commands.details ~= nil and fresh.files == nil, "the launcher's command exists and no Files button was registered")
check(#fresh.prompt_asks == 0, "the status-bar prompt is not asked at load")
fresh.hooks.window_start(fresh.cx)
check(#fresh.prompt_asks == 1 and fresh.prompt_asks[1] == "usage", "the window start path asks the shared prompt once with USAGE's plugin id")
ready(fresh, roster, true)
local off_bar = fresh.status({})
check(#off_bar == 1, "master Off draws no account segments after the roster arrives")
check(stored().enabled == false and #stored().selected == 0, "nothing migrates on a fresh install")

-- Retained install: master On and exactly the old first three, once the roster answers.
reset_store({ usage_layout = "wide" })
local retained = launch(false, true)
check(stored().enabled == true and stored().migration_complete == false, "retained data records master On with migration pending, before any poll")
local pending_bar = retained.status({})
check(#pending_bar == 2 and pending_bar[2].text == "USAGE loading", "while pending the bar shows the launcher and the loading state")
ready(retained, roster)
check(stored().migration_complete == true and #stored().selected == 3 and stored().selected[1] ~= nil, "migration completes on the first answered roster")
local bar = retained.status({})
check(#bar == 4 and bar[1].text == "USAGE" and bar[2].text:find("^claude: One  ◑ 40%%") ~= nil and bar[3].text:find("^openai: Two  ◔ 10%%") ~= nil
	and bar[4].text:find("^kimi: Three  ◕ 95%%") ~= nil, "the old first-three accounts appear, in provider order, after the launcher")
check(not status_text(retained):find("Four", 1, true), "the fourth account is not selected by migration")
check(bar[2].command == "plugin.usage.status_account_1" and bar[4].command == "plugin.usage.status_account_3", "account segments carry slot commands")
check(retained.commands.status_account_1.available(retained.cx) and retained.commands.status_account_3.available(retained.cx)
	and not retained.commands.status_account_4.available(retained.cx), "only drawn slots are listed in the palette")
-- A later window with the record present never migrates again.
local reopened = launch(false, true)
check(stored().migration_complete == true and #stored().selected == 3, "reinstall or a second window with the record present does not migrate again")
check(#reopened.created == 0, "a second window opens nothing by itself")

-- A retained install whose first display beats the host's publication: no roster yet, so the
-- migration stays pending and completes with the legacy first three once the roster arrives.
reset_store({ usage_layout = "wide" })
local early = launch(false, true)
early:tick()
early:reply("ensure", {})
early:reply("display", { revision = "empty", complete = true, parts = runtime.json.array() })
early:reply("usage_status", { state = "idle", completed = 0, total = 0 })
check(stored().migration_complete == false and #stored().selected == 0, "a display answered before any roster is published leaves the migration pending")
early:tick()
early:reply("register_client", {})
early:reply("display", display_for(roster))
early:reply("usage_status", { state = "idle", completed = 0, total = 0 })
check(stored().migration_complete == true and #stored().selected == 3, "the legacy first three are selected once the roster is published")

-- Clicking an account segment opens that account's detail, resolved against the roster now.
retained.commands.status_account_2.run(retained.cx)
local opened = retained.created[#retained.created]
check(opened.kind == "usage.account" and opened.args[1] == stored().selected[2] and retained.floats[#retained.floats].id == opened.id,
	"an account segment opens that account's detail pane without a list pane")
local detail_count = #retained.created
retained.commands.status_account_2.run(retained.cx)
check(#retained.created == detail_count, "a second click focuses the open detail")
-- The account disappears from the roster: its click opens USAGE and says so; the bar drops it, the selection keeps the id.
retained:tick()
retained:reply("register_client", {})
retained:reply("display", display_for({ roster[1], roster[3], roster[4] }))
retained:reply("usage_status", { state = "idle", completed = 0, total = 0 })
check(#retained.status({}) == 3 and not status_text(retained):find("Two", 1, true), "a removed account stops rendering and no row is invented")
check(#stored().selected == 3, "the removed account's choice is kept for if it comes back")
local created_before = #retained.created
retained.commands.status_account_3.run(retained.cx)
check(#retained.created == created_before + 1 and retained.created[#retained.created].kind == "usage.accounts"
	and not retained.commands.status_account_3.available(retained.cx),
	"a slot that is no longer drawn opens no account detail, only the USAGE list")

-- Settings links from the owned configuration pane.
local list = retained.created[#retained.created]
check(list.kind == "usage.accounts", "the list pane exists for the settings walk")
retained:link(list.id, "usage://config")
local config_pane = retained.created[#retained.created]
check(config_pane.kind == "usage.config", "Configure opens the configuration pane")
local function pushes() local result = {} for _, item in retained.events do if item.event.act == "status_state" then table.insert(result, item) end end return result end
local before_events = #pushes()
retained:link(config_pane.id, "usage://status/sync")
check(#pushes() == before_events + 1 and pushes()[#pushes()].id == config_pane.id, "a block asking for sync gets the state pushed")
local pushed_state = runtime.json.decode(pushes()[#pushes()].event.value)
local claude_id, grok_id = pushed_state.accounts[1].id, pushed_state.accounts[3].id
check(pushed_state.enabled == true and #pushed_state.accounts == 3 and pushed_state.accounts[1].selected == true, "the pushed state is the window's roster and choice")
local writes_before = #retained.requests
retained:link(config_pane.id, "usage://status/master/off")
check(stored().enabled == false and #stored().selected == 3 and #retained.status({}) == 1, "master Off keeps the selection and draws no account segments")
check(#retained.requests == writes_before, "saving reads no provider and makes no remote request")
check(runtime.json.decode(pushes()[#pushes()].event.value).enabled == false, "the block is told of the change")
retained:link(config_pane.id, "usage://status/account/" .. load("view_layout").encode(grok_id) .. "/on")
check(#stored().selected == 3 and retained.toasts[#retained.toasts].title == "Usage statistics are off", "an account cannot be ticked while the master is Off")
retained:link(config_pane.id, "usage://status/master/on")
check(stored().enabled == true and #retained.status({}) == 3, "master On brings the saved selection back")
retained:link(config_pane.id, "usage://status/account/" .. load("view_layout").encode(grok_id) .. "/on")
check(#stored().selected == 4 and #retained.status({}) == 4 and retained.status({})[4].text:find("^grok: Four") ~= nil, "ticking an account adds its segment")
retained:link(config_pane.id, "usage://status/account/" .. load("view_layout").encode(claude_id) .. "/off")
check(#retained.status({}) == 3 and not status_text(retained):find("One", 1, true), "unticking removes its segment")
local count_before = #stored().selected
retained:link(config_pane.id, "usage://status/account/" .. load("view_layout").encode("gone") .. "/on")
check(#stored().selected == count_before and retained.toasts[#retained.toasts].title == "That account is no longer in SPAWN", "a stale or unknown account cannot be toggled")
retained:link(config_pane.id, "usage://status/account/" .. load("view_layout").encode(claude_id) .. "/maybe")
retained:link(config_pane.id, "usage://status/master/maybe")
check(#stored().selected == count_before and stored().enabled == true, "malformed status links change nothing")
retained:link(22, "usage://status/master/off")
retained:link(list.id, "usage://status/master/off")
check(stored().enabled == true, "only the configuration pane can change the status bar")
-- A second window sees the shared record at its next render.
local other = launch(false, true)
local other_bar = other.status({})
check(#other_bar == 2 and other_bar[2].text == "USAGE loading", "a second window loads the shared record (master On) and shows its own loading state")

-- Pending migration refuses selection changes but allows master Off.
reset_store({ usage_python = "python3" })
local waiting = launch(false, true)
waiting:tick(); waiting:reply("ensure", {})
waiting.commands.details.run(waiting.cx)
waiting:link(waiting.created[#waiting.created].id, "usage://config")
local waiting_config = waiting.created[#waiting.created]
waiting:link(waiting_config.id, "usage://status/account/" .. load("view_layout").encode("c1") .. "/on")
check(#stored().selected == 0 and stored().migration_complete == false and waiting.toasts[#waiting.toasts].title == "USAGE is still loading accounts",
	"a selection change waits for the carried-over choice")
waiting:link(waiting_config.id, "usage://status/master/off")
check(stored().enabled == false and stored().migration_complete == false, "master Off is allowed while migration is pending and does not complete it")
waiting:reply("display", display_for(roster))
check(stored().migration_complete == true and stored().enabled == false and #stored().selected == 3, "migration then completes with the master still Off")

-- A corrupted record resets to Off/empty rather than breaking the bar.
reset_store({ [STATUS_KEY] = { version = 1, enabled = "yes" } })
local broken = launch(false, true)
check(stored().enabled == false and stored().migration_complete == true and #broken.status({}) == 1, "a corrupted record starts Off and empty")
-- The status formatter is a plain upvalue read: no kv, no refresh inside it.
reset_store({ [STATUS_KEY] = { version = 1, migration_complete = true, enabled = true, selected = {} } })
local timed = launch(false, true)
local started = os.clock()
for _ = 1, 200 do timed.status({}) end
check((os.clock() - started) / 200 < 0.004, "the status formatter stays within its 4 ms budget")
return "PASS " .. tostring(checks) .. " window behavior checks"
