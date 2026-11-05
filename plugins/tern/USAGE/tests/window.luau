-- Run in Tern: assert(loadstring(tern.fs.read(TEST_PATH)))(PLUGIN_DIR)
local root = ...
local runtime, environment = tern, getfenv()
local checks, preferences = 0, {}
local function check(value, why) assert(value, why); checks += 1 end
local function forbidden() error("owner pane input, provider process or unrelated mutation") end
local function launch()
	local state = { commands = {}, hooks = {}, requests = {}, timers = {}, panes = {
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
		check(key == "usage_layout", "UI stores only layout, not acquisition cadence"); preferences[key] = value
	end }
	fake.process, fake.fetch = { run = forbidden }, forbidden
	fake.timer = function(ms, callback)
		local timer = { ms = ms, callback = callback, cancelled = false }
		function timer:cancel() self.cancelled = true end
		table.insert(state.timers, timer); return timer
	end
	fake.command = function(value) state.commands[value.id] = value end
	fake.on = function(name, callback) state.hooks[name] = callback end
	fake.route = { link = function(callback) state.route = callback end }
	fake.files = { button = function(value) state.files = value end }
	fake.chrome = { status = function(callback) state.status = callback end, refresh = function() end }
	local modules = { companion = {
		set_client = function() end, invalidate = function() end,
		ensure = function(done) table.insert(state.requests, { operation = "ensure", callback = done }) end,
		request = function(operation, payload, done) table.insert(state.requests, { operation = operation, payload = payload, callback = done }) end,
	} }
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
local state, load = launch()
check(#state.created == 0 and state.focus == 11, "startup does not create or focus panes")
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
state.files.run({}, state.cx)
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
restored.files.run({}, restored.cx)
check(restored.created[1].args[1] == "bottom", "new VM reads persisted local layout")
restored.focus = 33
restored.files.run({}, restored.cx)
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
return "PASS " .. tostring(checks) .. " window behavior checks"
