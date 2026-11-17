--!strict
local root = ...
assert(type(root) == "string", "pass the plugin directory")
local environment = getfenv()
local modules = {}
local function load(name: string, runtime: any): any
	name = string.gsub(name, "^%.%./", "")
	name = string.gsub(name, "^%./", "")
	if modules[name] ~= nil then return modules[name] end
	local chunk = assert(loadstring(tern.fs.read(root .. "/" .. name .. ".luau"), name))
	setfenv(chunk, setmetatable({
		tern = runtime,
		require = function(child: string) return load(child, runtime) end,
	}, { __index = environment }))
	local module = chunk()
	modules[name] = module
	return module
end

local Launch = load("launch", tern)
local Spawn = load("spawn", tern)
local projects = load("projects", tern)
local function check(condition: boolean, message: string)
	if not condition then error(message) end
end

local function agent(kind: string, os: string, argv: { string }): any
	return { kind = kind, os = os, argv = argv }
end

local simple = assert(Launch.validate_agent(agent("acp", "linux", { "tern", "acp" })))
check(simple.kind == "acp" and simple.argv[2] == "acp", "valid ACP agent normalizes")
check(Launch.validate_agent(agent("other", "linux", { "tern" })) == nil, "unknown agent kind refused")
check(Launch.validate_agent(agent("cli", "ios", { "claude" })) == nil, "client-only or unknown execution OS refused")
check(Launch.validate_agent(agent("cli", "linux", {})) == nil, "empty argv refused")
check(Launch.validate_agent(agent("cli", "linux", { " " })) == nil, "blank executable refused")
check(Launch.validate_agent(agent("cli", "linux", { "claude", "bad\narg" })) == nil, "control characters refused")
check(Launch.validate_agent(agent("cli", "linux", { "claude", string.char(255) })) == nil, "invalid UTF-8 refused")
check(Launch.validate_agent(agent("cli", "linux", { [1] = "claude", [3] = "gap" })) == nil, "sparse argv refused")
local empty = assert(Launch.validate_agent(agent("cli", "linux", { "claude", "" })))
check(empty.argv[2] == "", "empty argument is retained")
check(Launch.decode_agent("{", tern.json.decode) == nil, "malformed host payload refused")
local decoded = assert(Launch.decode_agent(tern.json.encode(simple), tern.json.decode))
check(decoded.kind == "acp" and decoded.os == "linux", "host payload decodes and revalidates")

local posix = assert(Launch.command(agent("cli", "linux", {
	"agent", "", "two words", "single'quote", 'double"quote', "雪😀", "trailing\\",
}), tern.json.encode))
check(posix == "agent '' 'two words' 'single'\\''quote' 'double\"quote' '雪😀' 'trailing\\'", "POSIX argv stays literal: " .. posix)
local macos = assert(Launch.command(agent("cli", "macos", { "/opt/My Agent/run", "C:\\literal\\" }), tern.json.encode))
check(macos == "'/opt/My Agent/run' 'C:\\literal\\'", "macOS backslashes and spaces stay literal")
check(assert(Launch.command(simple, tern.json.encode)) == "tern acp", "ACP native command remains distinct")

check(Launch.windows_argument("") == '""', "Windows empty argument")
check(Launch.windows_argument("two words") == '"two words"', "Windows spaces")
check(Launch.windows_argument('a"b') == '"a\\"b"', "Windows quote")
check(Launch.windows_argument("a\\") == '"a\\\\"', "Windows trailing backslash doubles")
check(Launch.windows_argument('a\\"b') == '"a\\\\\\"b"', "Windows backslashes before quote")
local windows_argv = { "C:\\Program Files\\Agent\\agent.exe", "", "two words", 'a"b', "雪😀", "trailing\\", "%PATH% & ^ < > | ! ( )" }
local windows = assert(Launch.command(agent("cli", "windows", windows_argv), tern.json.encode))
check(string.match(windows, "^powershell%.exe %-NoLogo %-NoProfile %-EncodedCommand [A-Za-z0-9+/=]+$") ~= nil, "Windows outer command contains encoded data only")
check(string.find(windows, "雪", 1, true) == nil and string.find(windows, "two words", 1, true) == nil, "Windows argv never enters shell source")

for _, extension in ipairs({ ".cmd", ".bat", ".CMD" }) do
	for _, argument in ipairs({ "%PATH%", "&", "^", "<", ">", "|", "!", '"', "(", ")", "\r", "\n" }) do
		check(Launch.command(agent("cli", "windows", { "agent" .. extension, argument }), tern.json.encode) == nil,
			"batch launch fails closed for " .. extension .. " argument " .. string.format("%q", argument))
	end
end

local function host_url(value: any, workspace: string?, cwd: string?): string
	return projects.work_on_url(workspace or "alpha", cwd or "/glitch", {
		agent = ":host", label = "WORK host agent", delivery = "host", command = tern.json.encode(value),
	})
end

local function spawn_record(id: string, fields: any?): any
	local value = {
		id = id, provider = if id == "seat" then "Seat" else "Claude", account_label = "Work",
		backend = "local-terminal", enabled = true, command = if id == "seat" then "seat-launcher work" else "claude", arguments = {},
	}
	for key, field in pairs(fields or {}) do value[key] = field end
	return value
end

local function spawn_snapshot(): any
	return {
		version = 2, ready = true, host_key = "host:test", host_os = "linux", config_revision = 7,
		records = { spawn_record("claude-work"), spawn_record("seat"), spawn_record("default") },
	}
end

local function snapshot_tree(snapshot: any): any
	if snapshot == nil then return {} end
	return {
		surface = { role = "plugin.spawn.spawner" },
		main = { id = "main.spawn-state", k = "text", p = { spans = { { t = "SPAWN_STATE_V2 " .. tern.json.encode(snapshot) } } } },
	}
end

local function spawn_url(id: string, delivery: string, revision: number?): string
	return projects.work_on_url("alpha", "/glitch", {
		agent = id, label = id, delivery = delivery,
		command = tern.json.encode({ host_key = "host:test", host_os = "linux", config_revision = revision or 7 }),
	})
end

local function new_window(name: string, panel_tab: number?): any
	local window = {
		name = name, splits = {}, agents = {}, copies = {}, toasts = {}, runs = {}, focuses = {}, next_pane = 100,
		exit_created = false, spawn_snapshot = spawn_snapshot(), config_snapshots = {}, surface_reads = 0,
		dispatch_available = true, current_revision = 7,
		handlers = {}, commands = {}, file_buttons = {}, panels = 0, prompts = {}, closed = {},
	}
	local panes = {
		[11] = { pane = 11, block = "tern-work.panel", kind = "plugin", title = "WORK", tab = panel_tab or 2 },
		[12] = { pane = 12, block = nil, kind = "terminal", title = "shell", tab = 1 },
		[20] = { pane = 20, block = "spawn.spawner", kind = "plugin", title = "SPAWN A" },
		[21] = { pane = 21, block = "spawn.spawner", kind = "plugin", title = "SPAWN B" },
	}
	local fake_tern = {
		json = tern.json,
		on = function(event: string, handler: any) window.handlers[event] = handler end,
		route = { link = function(handler: any) window.route = handler end },
		command = function(def: any) window.commands[def.id] = def end,
		files = { button = function(def: any) table.insert(window.file_buttons, def) end },
		chrome = { status = function(fn: any) window.status = fn end },
		timer = function() error("WORK must not poll or delay prompt delivery") end,
	}
	local cx: any = { session = {}, layout = {}, agents = {} }
	function cx.session:pane(id: number): any return panes[id] end
	function cx.session:panes(): { any }
		local result = {}
		for _, pane in pairs(panes) do table.insert(result, pane) end
		return result
	end
	function cx.session:tabs(): { any } return {} end
	function cx.session:tab_of(id: number): number? return if panes[id] ~= nil then panes[id].tab else nil end
	function cx.session:focused(): number return 12 end
	function cx.session:block_types(): { any } return { { kind = "spawn.spawner" } } end
	function cx.session:surface(pane: number, _options: any): any
		window.surface_reads += 1
		assert(panes[pane] ~= nil and panes[pane].block == "spawn.spawner", "snapshot comes from a live SPAWN Config pane")
		return snapshot_tree(window.config_snapshots[pane] or window.spawn_snapshot)
	end
	function cx.layout:focus(pane: number)
		assert(panes[pane] ~= nil, "focus target exists")
		table.insert(window.focuses, pane)
	end
	function cx.layout:close(pane: number) table.insert(window.closed, pane) end
	function cx.layout:split(target: number, direction: string, launch: any): number
		assert(panes[target] ~= nil and direction == "right", "split origin is live and explicit")
		window.next_pane += 1
		local pane = window.next_pane
		panes[pane] = { pane = pane, kind = "terminal", exited = if window.exit_created then 1 else nil }
		table.insert(window.splits, { target = target, launch = launch, pane = pane })
		return pane
	end
	function cx.agents:start(options: any): number
		window.next_pane += 1
		local pane = window.next_pane
		panes[pane] = { pane = pane, kind = "agent", exited = if window.exit_created then 1 else nil }
		table.insert(window.agents, { options = options, pane = pane })
		return pane
	end
	function cx:copy(text: string) table.insert(window.copies, text) end
	function cx:toast(level: string, text: string, sub: string?) table.insert(window.toasts, { level = level, text = text, sub = sub }) end
	function cx:run(pane: number, text: string) table.insert(window.runs, { pane = pane, text = text }) end
	function cx:window_key(): string return name end
	function cx:new_block(): number?
		window.panels += 1
		return nil
	end
	window.cx = cx
	local chunk = assert(loadstring(tern.fs.read(root .. "/window.luau"), "work-window-entry-" .. name))
	setfenv(chunk, setmetatable({
		tern = fake_tern,
		require = function(name: string)
			if name == "./launch" then return Launch end
			if name == "./spawn" then return Spawn end
			if name == "./status/status_prompt" then
				return { ensure = function(_cx: any, id: string) table.insert(window.prompts, id) end }
			end
			if name == "./updater/window" then return { register = function() end } end
			error("unexpected require " .. name)
		end,
	}, { __index = environment }))
	chunk()
	assert(type(window.route) == "function", "window route registered")
	return window
end

local status_window = new_window("status")
check(#status_window.file_buttons == 0, "WORK registers no Files-pane button")
check(status_window.commands.show_projects ~= nil and status_window.commands.show_projects.title == "WORK", "palette command WORK is kept")
local segments = status_window.status({})
check(#segments == 1 and segments[1].text == "WORK" and segments[1].icon == "list", "one WORK status segment with the list icon")
check(segments[1].command == "plugin.tern-work.show_projects", "segment runs the WORK command")
status_window.handlers.window_start(status_window.cx)
check(#status_window.prompts == 1 and status_window.prompts[1] == "tern-work", "status-bar prompt ensured once on window start for tern-work")
status_window.commands.show_projects.run(status_window.cx)
check(status_window.panels == 1, "segment command opens the WORK panel exactly once")
check(status_window.toasts[#status_window.toasts].level == "error", "open_panel reports an unavailable host honestly")

local held = new_window("panel-in-tab", 1)
held.commands.show_projects.run(held.cx)
check(held.panels == 0 and #held.closed == 1 and held.closed[1] == 11, "a click with WORK already in the focused tab closes it instead of opening a second")

local function follow(window: any, url: string, pane: number?): any
	return window.route({ url = url, pane = pane, mods = {} }, window.cx)
end

local first, second = new_window("first"), new_window("second")
local decision = follow(first, host_url(agent("acp", "linux", { "tern", "acp" })), 11)
check(decision.handled == true, "WORK route handled in clicking window")
check(#first.agents == 1 and #first.splits == 0, "ACP uses native agent start exactly once")
check(first.agents[1].options.prompt == "/work-on alpha", "ACP prompt uses native ready queue")
check(first.agents[1].options.command == "tern acp", "ACP execution command comes from host argv")
check(first.agents[1].options.cwd == "/glitch", "execution cwd is the preserved Glitch root")
check(first.focuses[1] == 11, "ACP placement uses clicked pane, not focused pane authorization")
check(#first.copies == 0 and #second.copies == 0 and #second.agents == 0 and #second.splits == 0, "other window receives no launch or clipboard")
check(#first.runs == 0, "ACP never types into a terminal")

first, second = new_window("cli-first"), new_window("cli-second")
follow(first, host_url(agent("cli", "linux", { "claude", "--label", "two words" })), 11)
check(#first.splits == 1 and #first.agents == 0, "CLI uses a terminal split, not ACP")
check(first.splits[1].launch.command == "claude --label 'two words'", "CLI command uses host argv")
check(first.splits[1].launch.cwd == "/glitch", "CLI also starts at the Glitch root")
check(#first.copies == 1 and first.copies[1] == "/work-on alpha", "CLI prompt goes to clicking-window clipboard")
check(#second.copies == 0 and #second.splits == 0, "CLI fallback does not broadcast")
check(#first.runs == 0, "CLI fallback never types or presses Enter")

first = new_window("windows-cli")
follow(first, host_url(agent("cli", "windows", windows_argv)), 11)
check(#first.splits == 1 and #first.copies == 1, "Windows CLI launches on host command and copies locally")

first, second = new_window("foreign"), new_window("foreign-other")
follow(first, host_url(agent("cli", "linux", { "claude" })), 12)
check(#first.splits == 0 and #first.agents == 0 and #first.copies == 0, "crafted foreign-pane link refused")
check(first.toasts[#first.toasts].level == "error", "foreign origin has visible refusal")

first = new_window("duplicate")
follow(first, host_url(agent("cli", "linux", { "claude" })) .. "&cwd=%2Fevil", 11)
check(#first.splits == 0 and #first.copies == 0, "duplicate crafted query fields refused")

first = new_window("bad-agent")
local malformed = projects.work_on_url("alpha", "/glitch", {
	agent = ":host", label = "host", delivery = "host", command = "{",
})
follow(first, malformed, 11)
check(#first.splits == 0 and #first.agents == 0, "invalid structured host agent refused")

first = new_window("exited")
first.exit_created = true
follow(first, host_url(agent("cli", "linux", { "claude" })), 11)
check(#first.splits == 1 and #first.copies == 0, "exited pane is rechecked before clipboard write")
check(first.toasts[#first.toasts].level == "error", "exited pane fallback is honest")

local function spawn_hold(window: any, name: string)
	check(#window.splits == 0 and #window.agents == 0 and #window.copies == 0 and #window.runs == 0, name .. " has no launch or clipboard effect")
	check(window.surface_reads == 0, name .. " never trusts a rendered Config snapshot")
	check(window.toasts[#window.toasts].level == "error", name .. " has a visible hold")
end

first = new_window("spawn-argument-held")
follow(first, spawn_url("claude-work", "argument"), 11)
spawn_hold(first, "SPAWN argument link")

first, second = new_window("spawn-copy-held"), new_window("spawn-copy-other")
follow(first, spawn_url("seat", "clipboard"), 11)
spawn_hold(first, "SPAWN clipboard link")
check(#second.copies == 0 and #second.splits == 0, "SPAWN hold has no other-window effect")

first = new_window("spawn-old-type")
local old_type = projects.work_on_url("alpha", "/glitch", {
	agent = "seat", label = "Seat", delivery = "type", command = "seat-launcher work",
})
follow(first, old_type, 11)
spawn_hold(first, "legacy settled-screen typing route")


first = new_window("spawn-windows")
first.spawn_snapshot.host_os = "windows"
local windows_spawn = projects.work_on_url("alpha", "/glitch", {
	agent = "claude-work", label = "Claude", delivery = "argument",
	command = tern.json.encode({ host_key = "host:test", host_os = "windows", config_revision = 7 }),
})
follow(first, windows_spawn, 11)
spawn_hold(first, "Windows SPAWN")


local function walk(node: any, visit: (any) -> ())
	if type(node) ~= "table" then return end
	visit(node)
	for _, child in ipairs(node.c or {}) do walk(child, visit) end
	for _, span in ipairs(if type(node.p) == "table" then node.p.spans or {} else {}) do walk(span, visit) end
end

local function action(definition: any, state: any, kind: string, cx: any)
	for token, entry in pairs(state.actions) do
		if entry.kind == kind then
			definition.event(state, { ev = "action", act = kind, value = token }, cx)
			return
		end
	end
	error("missing panel action " .. kind)
end

local files: { [string]: string } = {}
local writes = 0
local path = "/work-data/config.json"
local catalog = {
	root = "/glitch/",
	agent = { kind = "acp", argv = { "tern", "acp" } },
	items = {
		{ id = "alpha", name = "alpha", kind = "coding", path = "/glitch/workspaces/alpha" },
		{ id = "zeta", name = "zeta", kind = "coding", path = "/glitch/workspaces/zeta" },
	},
}
local projects_stub = {}
function projects_stub.load(): (any, string?)
	local current = { root = catalog.root, agent = catalog.agent, items = catalog.items }
	if files[path] ~= nil then
		local configured = tern.json.decode(files[path])
		current.root = configured.glitch_root
		current.agent = configured.agent
	end
	return current, nil
end
function projects_stub.load_selection(current: any): any return projects.selection(current, nil) end
function projects_stub.selection(current: any, selected: any): any return projects.selection(current, selected) end
function projects_stub.save_selection() end
projects_stub.work_on_url = projects.work_on_url
local registry_roots: { [string]: boolean } = { ["/fresh/glitch"] = true }
function projects_stub.registry_ok(root: string): (boolean, string?)
	if registry_roots[root] then return true, nil end
	return false, "That folder has no valid Glitch workspace registry."
end
local spawn_stub = {}
function spawn_stub.load(): any
	return {
		host_key = "host:test", host_os = "linux", config_revision = 7,
		agents = {
			{ id = "default", label = "Claude default", record = spawn_record("default") },
			{ id = "configured", label = "Claude configured", record = spawn_record("configured") },
		},
	}
end
local panel_tern = {
	ui = tern.ui,
	json = tern.json,
	plugin = { data = "/work-data", dir = "/native/plugins/tern-work" },
	runtime = { os = "linux" },
	fs = {
		exists = function(target: string): boolean return files[target] ~= nil end,
		read = function(target: string, maximum: number): string
			assert(files[target] ~= nil, "missing panel fixture " .. target)
			assert(#files[target] <= maximum, "file exceeds read bound")
			return files[target]
		end,
		write = function(target: string, text: string)
			writes += 1
			files[target] = text
		end,
	},
}
local panel_chunk = assert(loadstring(tern.fs.read(root .. "/blocks/panel.luau"), "work-panel"))
setfenv(panel_chunk, setmetatable({
	tern = panel_tern,
	require = function(name: string)
		if name == "../config" then return load("config", tern) end
		if name == "../launch" then return Launch end
		if name == "../projects" then return projects_stub end
		if name == "../spawn" then return spawn_stub end
		if name == "../orchestration" then return load("orchestration", panel_tern) end
		if name == "../text_edit" then return load("text_edit", panel_tern) end
		error("unexpected panel require " .. name)
	end,
}, { __index = environment }))
local panel = panel_chunk()
local block_cx = { pane = 11, frames = {} }
function block_cx:frame(ops: any) table.insert(self.frames, ops) end
local state = panel.init(block_cx, {}, nil)
local function workspace_keys(): string
	local keys = {}
	walk(panel.view(state, block_cx).main, function(node: any)
		if type(node.p) == "table" and type(node.p.key) == "string" and string.match(node.p.key, "^workspace:") ~= nil then table.insert(keys, node.p.key) end
	end)
	table.sort(keys)
	return table.concat(keys, ",")
end
local before = workspace_keys()
state.catalog.items = { state.catalog.items[2], state.catalog.items[1] }
check(workspace_keys() == before and before == "workspace:alpha,workspace:zeta", "workspace row keys survive reorder")
state.catalog.items = { state.catalog.items[2] }
check(string.find(workspace_keys(), "workspace:zeta", 1, true) == nil, "workspace key follows identity through removal")

local launch_keys, launch_hrefs = {}, {}
walk(panel.view(state, block_cx).main, function(node: any)
	if type(node.p) == "table" and type(node.p.key) == "string" and (string.match(node.p.key, "^agent:") ~= nil or string.match(node.p.key, "^spawn%-agent:") ~= nil) then launch_keys[node.p.key] = true end
	if type(node.href) == "string" then table.insert(launch_hrefs, node.href) end
end)
check(launch_keys["agent:configured"] == true, "the configured Work On launcher is drawn")
local launcher_count, held_text = 0, false
for key in pairs(launch_keys) do
	launcher_count += 1
	check(string.match(key, "^spawn%-agent:") == nil, "held SPAWN agents draw no launcher row: " .. key)
end
check(launcher_count == 1, "a workspace card shows exactly one launcher, Work On")
walk(panel.view(state, block_cx).main, function(node: any)
	if type(node.p) == "table" and node.p.role == "work.spawn-hold" then held_text = true end
	if type(node.t) == "string" and string.find(node.t, "Launch held", 1, true) ~= nil then held_text = true end
end)
check(not held_text, "no held SPAWN row or Launch held text is drawn")
check(#launch_hrefs >= 1 and string.find(launch_hrefs[1], "cwd=%2Fglitch%2F", 1, true) ~= nil, "launch links retain the Glitch root cwd")
for _, href in ipairs(launch_hrefs) do
	if string.find(href, "tern://work", 1, true) == 1 then check(string.find(href, "workspaces", 1, true) == nil, "workspace path never becomes launch cwd") end
end

panel.view(state, block_cx)
action(panel, state, "setup-open", block_cx)
panel.event(state, { ev = "change", id = "main.setup-kind", value = "cli" }, block_cx)
panel.event(state, { ev = "focus", id = "main.setup-arg-1" }, block_cx)
local original_argument = state.setup.args[1].text
panel.key(state, { name = "home", ctrl = false, alt = false, meta = false }, block_cx)
panel.key(state, { name = "paste", text = "/opt/", ctrl = false, alt = false, meta = false }, block_cx)
check(state.setup.args[1].text == "/opt/" .. original_argument, "target-kind argv remains natively editable")
panel.event(state, { ev = "change", id = "main.setup-kind", value = "acp" }, block_cx)

local function edit_argument(text: string, keys: { string }): (string, number)
	state.setup.args[1].text = text
	panel.event(state, { ev = "focus", id = "main.setup-arg-1" }, block_cx)
	for _, key in ipairs(keys) do
		panel.key(state, { name = key, ctrl = false, alt = false, meta = false }, block_cx)
	end
	return state.setup.args[1].text, state.setup.args[1].cursor
end
local edited, cursor = edit_argument("abc", { "backspace" })
check(edited == "ab" and cursor == 2, "backspace removes exactly one ASCII character")
edited, cursor = edit_argument("a雪😀z", { "left", "backspace" })
check(edited == "a雪z" and cursor == #"a雪", "backspace removes one Unicode character before the cursor")
edited, cursor = edit_argument("a雪z", { "home", "right", "delete" })
check(edited == "az" and cursor == 1, "delete removes one Unicode character after the cursor")
state.setup.args[1].text, state.setup.args[1].cursor = "A😀雪Z", #"A😀雪Z"
panel.event(state, { ev = "edit", id = "main.setup-arg-1", from = 1, to = 4, text = "é", cursor = 2, len = 5 }, block_cx)
check(state.setup.args[1].text == "AéZ" and state.setup.args[1].cursor == #"Aé", "standalone setup accepts native Unicode selection replacement")
panel.event(state, { ev = "edit", id = "main.setup-arg-1", from = 0, to = 3, text = "stale", cursor = 5, len = 5 }, block_cx)
check(state.setup.args[1].text == "AéZ", "standalone setup refuses stale native edit lengths")
panel.event(state, { ev = "undo", id = "main.setup-arg-1" }, block_cx)
check(state.setup.args[1].text == "A😀雪Z", "standalone setup native undo restores the draft")

catalog.root, catalog.agent = nil, nil
state.catalog.root, state.catalog.agent = nil, nil
state.setup = nil
panel.view(state, block_cx)
action(panel, state, "setup-open", block_cx)
check(state.setup.root == "" and state.setup.root_readonly == false, "fresh installed Setup starts with an editable empty root")
panel.event(state, { ev = "focus", id = "main.setup-root" }, block_cx)
panel.key(state, { name = "paste", text = "/typo/glitch", ctrl = false, alt = false, meta = false }, block_cx)
panel.view(state, block_cx)
action(panel, state, "setup-save", block_cx)
check(writes == 0 and files[path] == nil and state.setup ~= nil and state.setup.hold ~= nil, "a first root without a readable registry is held and nothing is written")
state.setup.root, state.setup.root_cursor = "", 0
panel.event(state, { ev = "focus", id = "main.setup-root" }, block_cx)
panel.key(state, { name = "paste", text = "/fresh/glitch", ctrl = false, alt = false, meta = false }, block_cx)
panel.view(state, block_cx)
action(panel, state, "setup-save", block_cx)
check(writes == 1 and state.setup == nil, "fresh install validates, writes and reads back without JSON")
local saved = tern.json.decode(files[path])
check(saved.glitch_root == "/fresh/glitch" and saved.agent.kind == "acp" and saved.agent.argv[2] == "acp", "native root and structured argv persist")

files[path] = tern.json.encode({ glitch_root = "/preserved/" })
catalog.root, catalog.agent = nil, nil
state.catalog.root, state.catalog.agent = nil, nil
state.setup = nil
panel.view(state, block_cx)
action(panel, state, "setup-open", block_cx)
check(state.setup.root == "/preserved/" and state.setup.root_readonly == true, "root-only upgrade preserves and locks its existing root")
panel.view(state, block_cx)
action(panel, state, "setup-save", block_cx)
saved = tern.json.decode(files[path])
check(writes == 2 and saved.glitch_root == "/preserved/" and state.setup == nil, "root-only upgrade completes agent Setup without changing root")

panel.view(state, block_cx)
action(panel, state, "setup-open", block_cx)
local old_text = files[path]
files[path] = tern.json.encode({ glitch_root = "/elsewhere", agent = { kind = "cli", argv = { "claude" } } })
panel.view(state, block_cx)
action(panel, state, "setup-save", block_cx)
check(writes == 2 and files[path] ~= old_text and state.setup.hold ~= nil, "external edit becomes visible hold without a second write")

local function open_config(document: any)
	files[path] = tern.json.encode(document)
	state.setup = nil
	panel.view(state, block_cx)
	action(panel, state, "setup-open", block_cx)
	panel.view(state, block_cx)
end
open_config({ glitch_root = "/preserved/", unknown = "must remain" })
local protected_text, protected_writes = files[path], writes
action(panel, state, "setup-save", block_cx)
check(files[path] == protected_text and writes == protected_writes and state.setup.hold ~= nil,
	"invalid root-only configuration remains byte-for-byte untouched")

for _, document in ipairs({
	{ glitch_root = "/preserved/", unknown = tern.json.null },
	{ glitch_root = "/preserved/", agent = tern.json.null },
	{ glitch_root = "/preserved/", agent = { kind = "cli", argv = { "agent" }, unknown = tern.json.null } },
}) do
	open_config(document)
	protected_text, protected_writes = files[path], writes
	action(panel, state, "setup-save", block_cx)
	check(files[path] == protected_text and writes == protected_writes and state.setup.hold ~= nil,
		"null members cannot disappear through native decoding and authorize a destructive rewrite")
end

open_config({ glitch_root = "/preserved/" })
protected_text, protected_writes = files[path], writes
state.setup.args = { { id = 1, text = "agent", cursor = 5 } }
for index = 2, 10 do
	table.insert(state.setup.args, { id = index, text = string.rep("a", 4096), cursor = 4096 })
end
action(panel, state, "setup-save", block_cx)
check(files[path] == protected_text and writes == protected_writes and state.setup.hold ~= nil,
	"oversized valid argv is refused before replacing readable configuration")

state.catalog = { items = {} }
open_config({ glitch_root = "/preserved/", agent = { kind = "cli", argv = { "/opt/custom agent", "--profile", "private" } } })
action(panel, state, "setup-save", block_cx)
saved = tern.json.decode(files[path])
check(saved.agent.kind == "cli" and #saved.agent.argv == 3
	and saved.agent.argv[1] == "/opt/custom agent" and saved.agent.argv[2] == "--profile" and saved.agent.argv[3] == "private",
	"registry failure cannot replace the configured agent with Setup defaults")

local literal_arguments = { "agent", "null", 'quoted "null"', "backslash\\", '\\\"null' }
open_config({ glitch_root = "/null/glitch/", agent = { kind = "cli", argv = literal_arguments } })
protected_writes = writes
action(panel, state, "setup-save", block_cx)
saved = tern.json.decode(files[path])
check(writes == protected_writes + 1 and state.setup == nil and saved.glitch_root == "/null/glitch/",
	"literal null text and escaped strings allow a validated Setup save with root preserved")
for index, argument in ipairs(literal_arguments) do
	check(saved.agent.argv[index] == argument, "Setup preserves escaped literal argument content")
end

-- SKILLS-193: Setup wording, labels, hints and calm first-run message.
local function setup_encoded(): string
	return tern.json.encode(panel.view(state, block_cx).main)
end
local function has(encoded: string, needle: string): boolean
	return string.find(encoded, needle, 1, true) ~= nil
end
local function reopen_fresh()
	files[path] = nil
	catalog.root, catalog.agent = nil, nil
	state.catalog.root, state.catalog.agent = nil, nil
	state.setup = nil
	state.attempted = nil
	state.notice = nil
	panel.view(state, block_cx)
	action(panel, state, "setup-open", block_cx)
end
reopen_fresh()
local fresh = setup_encoded()
check(has(fresh, '"ACP - Recommended"'), "SKILLS-193 item 1: ACP label is exact")
check(has(fresh, '"CLI - Manual Paste Req."'), "SKILLS-193 item 1: CLI label is exact")
check(not has(fresh, "native ready signal") and not has(fresh, "clipboard fallback"), "SKILLS-193 item 1: old kind labels are gone")

-- item 2: untouched Setup is calm; a failed attempt shows the red error
state.notice = "setup_required: Glitch folder not configured. Set glitch_root and an ACP or CLI agent argv in " .. path .. " on this host, then Refresh."
local calm = setup_encoded()
check(not has(calm, "setup_required") and not has(calm, "Glitch folder not configured"), "SKILLS-193 item 2: untouched Setup hides the red setup_required line")
check(has(calm, "Choose a Glitch folder and an agent below, then select Save Setup."), "SKILLS-193 item 2: untouched Setup shows the calm instruction")
action(panel, state, "setup-save", block_cx)
local failed = setup_encoded()
check(state.setup ~= nil and state.setup.hold ~= nil and has(failed, "Enter the absolute Glitch folder on this host in Glitch root."), "SKILLS-193 item 2: failed save keeps its error")
check(has(failed, "setup_required: Glitch folder not configured") and not has(failed, "Choose a Glitch folder and an agent below"), "SKILLS-193 item 2: after an attempted save the red notice returns and the calm line goes")
reopen_fresh()
state.notice = "setup_required: Glitch folder not configured."
action(panel, state, "refresh", block_cx)
check(state.attempted == true, "SKILLS-193 item 2: a refresh counts as an attempt")

-- item 3: argv row labels and the add button
reopen_fresh()
local rows = setup_encoded()
check(has(rows, '"Command"') and has(rows, '"Option 1"') and not has(rows, '"Option 2"'), "SKILLS-193 item 3: row 1 is Command, row 2 is Option 1")
check(has(rows, '"Add option"') and not has(rows, "Add argument"), "SKILLS-193 item 3: add button reads Add option")
action(panel, state, "setup-add", block_cx)
check(has(setup_encoded(), '"Option 2"'), "SKILLS-193 item 3: a third row is Option 2")

-- item 4: hint only while rows equal the kind's defaults
reopen_fresh()
check(has(setup_encoded(), "Starts Tern's own agent pane."), "SKILLS-193 item 4: ACP default shows its hint")
panel.event(state, { ev = "change", id = "main.setup-kind", value = "cli" }, block_cx)
local cli_hint = setup_encoded()
check(has(cli_hint, "Starts Claude Code in a terminal.") and not has(cli_hint, "Starts Tern's own agent pane."), "SKILLS-193 item 4: CLI default shows its hint")
panel.event(state, { ev = "focus", id = "main.setup-arg-1" }, block_cx)
panel.key(state, { name = "paste", text = "x", ctrl = false, alt = false, meta = false }, block_cx)
local edited_hint = setup_encoded()
check(not has(edited_hint, "Starts Claude Code in a terminal.") and not has(edited_hint, "Starts Tern's own agent pane."), "SKILLS-193 item 4: an edited command hides the hint")
panel.event(state, { ev = "change", id = "main.setup-kind", value = "acp" }, block_cx)
action(panel, state, "setup-add", block_cx)
check(not has(setup_encoded(), "Starts Tern's own agent pane."), "SKILLS-193 item 4: an added option hides the hint")

-- item 5: Glitch root placeholder
reopen_fresh()
local placeholder = nil
walk(panel.view(state, block_cx).main, function(node: any)
	if type(node.p) == "table" and type(node.p.key) == "string" and string.match(node.p.key, "setup%-root$") ~= nil then placeholder = node.p.placeholder end
end)
check(placeholder == "Your Glitch folder, e.g. /opt/glitch or C:\\Users\\you\\Glitch", "SKILLS-193 item 5: root placeholder is exact: " .. tostring(placeholder))

-- item 6: intro line and removed recovery line
reopen_fresh()
local intro = setup_encoded()
check(has(intro, "Choose which agent opens when you click Work On."), "SKILLS-193 item 6: new intro line")
check(not has(intro, "Configure the agent on this execution host"), "SKILLS-193 item 6: old intro line is gone")
check(not has(intro, "recovery only") and not has(intro, "Setup checks for external edits") and not has(intro, "config.json"), "SKILLS-193 item 6: config.json line is removed from the screen")
return true
