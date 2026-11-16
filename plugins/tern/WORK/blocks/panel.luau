--!strict
local ui = tern.ui
local Config = require("../config")
local Launch = require("../launch")
local projects = require("../projects")
local spawn = require("../spawn")
local orchestration = require("../orchestration")
local text_edit = require("../text_edit")

local CONFIG_MAX_BYTES = 32 * 1024

type Arg = { id: number, text: string, cursor: number }
type Setup = {
	kind: string,
	root: string,
	root_cursor: number,
	root_readonly: boolean,
	args: { Arg },
	next_arg: number,
	focus: any,
	expected: any,
	hold: string?,
	undo: { [string]: any },
}
type State = {
	pane: number,
	catalog: any,
	selection: any,
	notice: string?,
	roster: any?,
	setup: Setup?,
	actions: { [string]: any },
	next_action: number,
	orchestration: any?,
}

local function config_path(): string
	return tern.plugin.data .. "/config.json"
end

local function read_snapshot(): any
	local path = config_path()
	local exists_ok, exists = pcall(tern.fs.exists, path)
	if not exists_ok then return { error = "Could not inspect WORK configuration: " .. tostring(exists) } end
	if exists ~= true then return { exists = false } end
	local read_ok, text = pcall(tern.fs.read, path, CONFIG_MAX_BYTES)
	if not read_ok or type(text) ~= "string" then
		return { exists = true, error = "Could not read WORK configuration: " .. tostring(text) }
	end
	return { exists = true, text = text }
end

local function default_argv(kind: string): { string }
	return if kind == "acp" then { "tern", "acp" } else { "claude" }
end

local function linked_root(): string?
	local plugin_dir = Config.normalize_root(tern.plugin.dir, tern.runtime.os)
	return if plugin_dir ~= nil then string.match(plugin_dir, "^(.*)/_local/[^/]+$") else nil
end

local function argument_rows(source: { string }): { Arg }
	local args = {}
	for index, argument in ipairs(source) do table.insert(args, { id = index, text = argument, cursor = #argument }) end
	return args
end

local function new_setup(catalog: any): Setup
	local snapshot = read_snapshot()
	local existing = nil
	if snapshot.exists and snapshot.text ~= nil then
		existing = Config.decode(snapshot.text, tern.json.decode)
	end
	local configured = if existing ~= nil then Config.validate(existing, tern.runtime.os) else nil
	local agent = if configured ~= nil then configured.agent elseif type(catalog.agent) == "table" then catalog.agent else nil
	local kind = if agent ~= nil and (agent.kind == "acp" or agent.kind == "cli") then agent.kind else "acp"
	local source = if agent ~= nil and type(agent.argv) == "table" and #agent.argv > 0 then agent.argv else default_argv(kind)
	local existing_root = if existing ~= nil and type(existing.glitch_root) == "string" and existing.glitch_root ~= "" then existing.glitch_root else nil
	local root = existing_root or catalog.root or linked_root() or ""
	local args = argument_rows(source)
	return {
		kind = kind,
		root = root,
		root_cursor = #root,
		root_readonly = existing_root ~= nil,
		args = args,
		next_arg = #args + 1,
		focus = nil,
		expected = snapshot,
		hold = snapshot.error,
		undo = {},
	}
end

local function set_kind(setup: Setup, kind: string)
	if setup.kind == kind then return end
	setup.kind = kind
	setup.args = argument_rows(default_argv(kind))
	setup.next_arg = #setup.args + 1
	setup.focus = nil
	setup.undo = {}
end

local function config_problem(notice: string?): boolean
	return notice == "setup_required" or notice == "config_invalid"
		or (type(notice) == "string" and (string.match(notice, "^setup_required:") ~= nil or string.match(notice, "^config_invalid:") ~= nil))
end

local function needs_setup(catalog: any, notice: string?): boolean
	return config_problem(notice) or (notice == nil and catalog.agent == nil)
end

local function save_selection(state: State)
	projects.save_selection(state.selection)
end

local function action(state: State, kind: string, payload: any): string
	local token = tostring(state.next_action)
	state.next_action += 1
	state.actions[token] = { kind = kind, payload = payload }
	return token
end

local function workspace_meta(item: any): any
	local spans = { ui.span(item.kind, "muted") }
	if item.remote ~= nil then
		table.insert(spans, ui.span(" · ", "muted"))
		table.insert(spans, ui.link("GitHub", item.remote, "link"))
	end
	return ui.text(spans)
end

local function host_agent(state: State): any?
	if type(state.catalog.agent) ~= "table" then return nil end
	local payload = {
		kind = state.catalog.agent.kind,
		argv = state.catalog.agent.argv,
		os = tern.runtime.os,
	}
	local valid = Launch.validate_agent(payload)
	return valid
end

local function launch_link(key: string, label: string, url: string, title: string): any
	return ui.node("row", {
		key = key,
		role = "omp.btn",
		class = "glitch-plan-work",
		title = title,
		tone = "warning",
	}, {
		ui.text({ ui.link(label, url, "link") }),
	})
end

local function default_link(state: State, item: any, agent: any): any
	local url = projects.work_on_url(item.id, state.catalog.root, {
		agent = ":host",
		label = "WORK host agent",
		delivery = "host",
		command = tern.json.encode(agent),
	})
	return launch_link("agent:configured", "Work On", url, "Start the configured " .. string.upper(agent.kind) .. " agent on this WORK host")
end

local function spawn_link(_state: State, _item: any, agent: any): any
	local reason = agent.disabled or "Launch held: SPAWN has no supported fresh host-owned read and native single-winner claim for WORK"
	return ui.node("row", { key = "spawn-agent:" .. agent.id, role = "work.spawn-hold" }, {
		ui.text({ ui.span(agent.label .. " — " .. reason, "muted") }),
	})
end

local function plan_row(state: State, item: any, agent: any): any
	local selected = state.selection.workspace_id == item.id
	local select_token = action(state, "select", item.id)
	local launchers = { default_link(state, item, agent) }
	if state.roster ~= nil then
		for _, saved in ipairs(state.roster.agents) do table.insert(launchers, spawn_link(state, item, saved)) end
	end
	return ui.el("div", {
		key = "workspace:" .. item.id,
		class = if selected then "glitch-plan-row glitch-plan-row-selected" else "glitch-plan-row",
		actions = { click = "select=" .. select_token },
	}, {
		ui.el("div", { class = "glitch-plan-info" }, {
			ui.text({ ui.span(item.name, "strong") }),
			workspace_meta(item),
		}),
		ui.el("div", { class = "glitch-plan-launchers" }, launchers),
	})
end

local function utf16_length(value: string): number
	local length = 0
	for _, codepoint in utf8.codes(value) do length += if codepoint >= 65536 then 2 else 1 end
	return length
end

local function setup_view(state: State, setup: Setup): any
	local rows = {
		ui.text({ ui.span("WORK Setup", "title") }),
		ui.text({ ui.span("Configure the agent on this execution host. ACP receives a native queued prompt; CLI requires manual paste.", "muted") }),
		ui.node("field", { label = if setup.root_readonly then "Glitch root (preserved)" else "Glitch root" }, {
			ui.node("input", {
				key = "setup-root",
				text = setup.root,
				cursor = utf16_length(string.sub(setup.root, 1, setup.root_cursor)),
				placeholder = "Absolute Glitch folder on this host",
				aria = "Glitch root on the execution host",
				readonly = setup.root_readonly,
				mono = true,
			}),
		}),
		ui.node("field", { label = "Agent kind" }, {
			ui.node("select", {
				key = "setup-kind",
				value = setup.kind,
				options = {
					{ value = "acp", label = "ACP — native ready signal" },
					{ value = "cli", label = "CLI — clipboard fallback" },
				},
			}),
		}),
	}
	for _, argument in ipairs(setup.args) do
		local remove_token = action(state, "setup-remove", argument.id)
		table.insert(rows, ui.node("row", { key = "setup-arg-row:" .. argument.id }, {
			ui.node("input", {
				key = "setup-arg-" .. argument.id,
				text = argument.text,
				cursor = utf16_length(string.sub(argument.text, 1, argument.cursor)),
				placeholder = if argument.id == 1 then "Executable on the WORK host" else "Argument",
				aria = "Agent argument " .. argument.id,
				grow = 1,
			}),
			ui.button("Remove", {
				key = "setup-remove-" .. argument.id,
				size = "sm",
				disabled = if #setup.args == 1 then "At least the executable is required" else false,
				actions = { click = "setup-remove=" .. remove_token },
			}),
		}))
	end
	table.insert(rows, ui.row({
		ui.button("Add argument", { actions = { click = "setup-add=" .. action(state, "setup-add", nil) } }),
		ui.button("Save Setup", { variant = "primary", actions = { click = "setup-save=" .. action(state, "setup-save", nil) } }),
		ui.button("Cancel", { actions = { click = "setup-cancel=" .. action(state, "setup-cancel", nil) } }),
	}))
	table.insert(rows, ui.text({ ui.span("Setup checks for external edits and verifies the saved configuration. JSON at " .. config_path() .. " is recovery only.", "muted") }))
	if setup.hold ~= nil then table.insert(rows, ui.text({ ui.span(setup.hold, "error") })) end
	return ui.col(rows)
end

local function view(state: State): any
	if state.orchestration ~= nil then return orchestration.view(state.orchestration) end
	state.actions = {}
	local rows = {
		orchestration.context_node(nil),
		ui.text({ ui.span("WORK", "title") }),
		ui.text({ ui.span("Active workspaces known to /work-on.", "muted") }),
		ui.row({
			ui.button("Refresh", {
				key = "refresh",
				actions = { click = "refresh=" .. action(state, "refresh", nil) },
				title = "Refresh workspaces and host configuration",
			}),
			ui.button("Setup", { key = "setup", actions = { click = "setup-open=" .. action(state, "setup-open", nil) } }),
		}),
	}
	if state.setup ~= nil then
		table.insert(rows, setup_view(state, state.setup))
	else
		local agent = host_agent(state)
		if agent == nil and state.notice == nil then state.notice = "WORK host agent configuration is invalid; open Setup." end
		if #state.catalog.items == 0 and state.notice == nil then
			table.insert(rows, ui.text({ ui.span("No active workspaces found.", "muted") }))
		elseif agent ~= nil then
			for _, item in ipairs(state.catalog.items) do table.insert(rows, plan_row(state, item, agent)) end
		end
	end
	if state.notice ~= nil then table.insert(rows, ui.text({ ui.span(state.notice, "error") })) end
	if state.roster ~= nil and state.roster.problem ~= nil then
		table.insert(rows, ui.text({ ui.span(state.roster.problem, "muted") }))
	end
	return ui.col(rows)
end

local function refresh(state: State, keep_setup: boolean)
	state.catalog, state.notice = projects.load()
	state.selection = projects.selection(state.catalog, state.selection)
	state.roster = spawn.load()
	if keep_setup or needs_setup(state.catalog, state.notice) then
		state.setup = new_setup(state.catalog)
	else
		state.setup = nil
	end
end

local function hold(setup: Setup, message: string)
	setup.hold = message
end

local function decoded_snapshot(snapshot: any): any?
	if not snapshot.exists then return {} end
	local value = Config.decode(snapshot.text, tern.json.decode)
	return value
end

local function same_agent(left: any, right: any): boolean
	if type(left) ~= "table" or type(right) ~= "table" or left.kind ~= right.kind or type(left.argv) ~= "table" or type(right.argv) ~= "table" then return false end
	if #left.argv ~= #right.argv then return false end
	for index, argument in ipairs(left.argv) do if right.argv[index] ~= argument then return false end end
	return true
end

local function save_setup(state: State)
	local setup = state.setup
	if setup == nil then return end
	local current = read_snapshot()
	if current.error ~= nil then hold(setup, current.error); return end
	if current.exists ~= setup.expected.exists or (current.exists and current.text ~= setup.expected.text) then
		hold(setup, "WORK configuration changed outside Setup. Refresh before saving; no file was written.")
		return
	end
	local existing = decoded_snapshot(current)
	if existing == nil then hold(setup, "Existing WORK JSON is invalid. Repair it as JSON recovery, then Refresh; no file was written."); return end
	if current.exists and (type(existing.glitch_root) ~= "string" or existing.glitch_root == "") then
		hold(setup, "Existing WORK configuration has no usable glitch_root to preserve. Use JSON recovery; no file was written.")
		return
	end
	if current.exists then
		local valid_existing, existing_problem = Config.validate(existing, tern.runtime.os)
		if valid_existing == nil and existing_problem ~= "setup_required" then
			hold(setup, "Existing WORK configuration is incomplete or invalid. Use JSON recovery, then Refresh; no file was written.")
			return
		end
	end
	local root = setup.root
	if current.exists and root ~= existing.glitch_root then
		hold(setup, "Setup must preserve the existing glitch_root. Refresh before editing the agent; no file was written.")
		return
	end
	if type(root) ~= "string" or root == "" then
		hold(setup, "Enter the absolute Glitch folder on this host in Glitch root.")
		return
	end
	local argv = {}
	for _, argument in ipairs(setup.args) do table.insert(argv, argument.text) end
	local candidate = { glitch_root = root, agent = { kind = setup.kind, argv = argv } }
	local normalized, problem = Config.validate(candidate, tern.runtime.os)
	if normalized == nil then hold(setup, tostring(problem)); return end
	if not current.exists then
		-- A first root is committed only after its host registry reads; a typo must not lock Setup read-only.
		local registry_ok, registry_problem = projects.registry_ok(normalized.glitch_root)
		if not registry_ok then hold(setup, tostring(registry_problem) .. " No file was written."); return end
	end
	local document = {
		glitch_root = root,
		agent = { kind = normalized.agent.kind, argv = tern.json.array(normalized.agent.argv) },
	}
	local encoded = tern.json.encode(document, true)
	if #encoded > CONFIG_MAX_BYTES then
		hold(setup, "WORK configuration exceeds the 32 KiB read limit. Shorten the arguments; no file was written.")
		return
	end
	local write_ok, write_problem = pcall(function()
		tern.fs.write(config_path(), encoded)
		return true
	end)
	if not write_ok then hold(setup, "Could not write WORK configuration: " .. tostring(write_problem)); return end
	local saved = read_snapshot()
	local readback = if saved.error == nil then decoded_snapshot(saved) else nil
	local valid_readback = if readback ~= nil then Config.validate(readback, tern.runtime.os) else nil
	if readback == nil or valid_readback == nil or readback.glitch_root ~= root or not same_agent(valid_readback.agent, normalized.agent) then
		hold(setup, "WORK wrote but could not verify the configuration read-back. Inspect external edits before retrying.")
		return
	end
	state.catalog, state.notice = projects.load()
	state.selection = projects.selection(state.catalog, state.selection)
	if needs_setup(state.catalog, state.notice) then
		setup.expected = saved
		hold(setup, "WORK saved configuration but the host still holds Setup: " .. tostring(state.notice))
		return
	end
	state.setup = nil
end

local function on_event(state: State, event: any, cx: any)
	if event.ev == "action" and event.act == "orch-open" and state.orchestration == nil then
		state.notice = "This WORK pane is standalone. WORK ON uses its own selection-mode WORK pane."
		return
	end
	if state.orchestration ~= nil then
		local context = state.orchestration
		if event.ev == "action" and event.act == "orch-standalone" and context.result ~= nil and (context.result.phase == "accepted" or context.result.phase == "cancelled") then
			local entry = context.actions[event.value]
			if entry ~= nil and entry.kind == "orch-standalone" then state.orchestration = nil; refresh(state, false) end
			return
		end
		orchestration.event(context, event, cx)
		return
	end
	state.roster = spawn.load()
	local setup = state.setup
	if setup ~= nil and (event.ev == "edit" or event.ev == "undo") and type(event.id) == "string" then
		local root = event.id:match("setup%-root$") ~= nil
		local selected = nil
		local id = tonumber(event.id:match("setup%-arg%-(%d+)$") or "")
		for _, argument in ipairs(setup.args) do if argument.id == id then selected = argument; break end end
		if (root and setup.root_readonly) or (not root and selected == nil) then return end
		local field = if root then "root" else tostring(id)
		local value = if root then setup.root else selected.text
		local cursor = if root then setup.root_cursor else selected.cursor
		local history = setup.undo[field] or {}; setup.undo[field] = history
		local next_value, next_cursor
		if event.ev == "undo" then
			local old = table.remove(history)
			if old ~= nil then next_value, next_cursor = old.text, old.cursor end
		else
			next_value, next_cursor = text_edit.apply(value, event, 4096)
			if next_value ~= nil and next_value ~= value then text_edit.remember(history, value, cursor) end
		end
		if next_value ~= nil and next_cursor ~= nil then
			if root then setup.root, setup.root_cursor, setup.focus = next_value, next_cursor, "root"
			else selected.text, selected.cursor, setup.focus = next_value, next_cursor, id end
		end
		return
	end
	if setup ~= nil and event.ev == "change" and type(event.id) == "string" and string.match(event.id, "setup%-kind$") ~= nil then
		if event.value == "acp" or event.value == "cli" then set_kind(setup, event.value) end
		return
	end
	if setup ~= nil and event.ev == "focus" and type(event.id) == "string" then
		if string.match(event.id, "setup%-root$") ~= nil and not setup.root_readonly then
			setup.focus = "root"
			setup.root_cursor = #setup.root
			cx:frame({ { "focus", event.id } })
			return
		end
		local id = tonumber(string.match(event.id, "setup%-arg%-(%d+)$") or "")
		for _, argument in ipairs(setup.args) do
			if argument.id == id then
				setup.focus = id
				argument.cursor = #argument.text
				cx:frame({ { "focus", event.id } })
				return
			end
		end
	end
	if event.ev ~= "action" or event.act == nil or type(event.value) ~= "string" then return end
	local entry = state.actions[event.value]
	if entry == nil or entry.kind ~= event.act then return end
	if entry.kind == "refresh" then refresh(state, state.setup ~= nil); return end
	if entry.kind == "setup-open" then state.setup = new_setup(state.catalog); return end
	if entry.kind == "setup-cancel" then state.setup = if needs_setup(state.catalog, state.notice) then state.setup else nil; return end
	if entry.kind == "setup-add" and setup ~= nil then
		table.insert(setup.args, { id = setup.next_arg, text = "", cursor = 0 })
		setup.next_arg += 1
		return
	end
	if entry.kind == "setup-remove" and setup ~= nil then
		for index, argument in ipairs(setup.args) do
			if argument.id == entry.payload and #setup.args > 1 then table.remove(setup.args, index); break end
		end
		return
	end
	if entry.kind == "setup-save" then save_setup(state); return end
	if entry.kind == "select" then
		state.selection = projects.selection(state.catalog, { workspace_id = entry.payload })
		save_selection(state)
		return
	end
end

local function previous_offset(value: string, cursor: number): number?
	if cursor <= 0 then return nil end
	local offset = utf8.offset(value, -1, cursor + 1)
	return if offset ~= nil then offset - 1 else nil
end

local function next_offset(value: string, cursor: number): number
	if cursor >= #value then return #value end
	local offset = utf8.offset(value, 2, cursor + 1)
	return if offset ~= nil then offset - 1 else #value
end

local function edit_value(value: string, cursor: number, key: any): (string, number, boolean)
	if key.name == "backspace" then
		local previous = previous_offset(value, cursor)
		if previous == nil then return value, cursor, true end
		return string.sub(value, 1, previous) .. string.sub(value, cursor + 1), previous, true
	elseif key.name == "delete" then
		local following = next_offset(value, cursor)
		return string.sub(value, 1, cursor) .. string.sub(value, following + 1), cursor, true
	elseif key.name == "left" then
		return value, previous_offset(value, cursor) or cursor, true
	elseif key.name == "right" then
		return value, next_offset(value, cursor), true
	elseif key.name == "home" then
		return value, 0, true
	elseif key.name == "end" then
		return value, #value, true
	elseif (key.name == "paste" or key.text ~= nil) and key.text ~= nil and key.text ~= "" and not key.ctrl and not key.alt and not key.meta then
		return string.sub(value, 1, cursor) .. key.text .. string.sub(value, cursor + 1), cursor + #key.text, true
	end
	return value, cursor, false
end

local function on_key(state: State, key: any): boolean
	if state.orchestration ~= nil then return orchestration.key(state.orchestration, key, edit_value) end
	local setup = state.setup
	if setup == nil or setup.focus == nil then return false end
	if key.name == "escape" then setup.focus = nil; return true end
	if setup.focus == "root" then
		if setup.root_readonly then return false end
		local value, cursor, handled = edit_value(setup.root, setup.root_cursor, key)
		if value ~= setup.root then
			local history = setup.undo.root or {}; setup.undo.root = history
			text_edit.remember(history, setup.root, setup.root_cursor)
		end
		setup.root, setup.root_cursor = value, cursor
		return handled
	end
	local selected = nil
	for _, argument in ipairs(setup.args) do
		if argument.id == setup.focus then selected = argument; break end
	end
	if selected == nil then return false end
	local value, cursor, handled = edit_value(selected.text, selected.cursor, key)
	if value ~= selected.text then
		local field = tostring(selected.id)
		local history = setup.undo[field] or {}; setup.undo[field] = history
		text_edit.remember(history, selected.text, selected.cursor)
	end
	selected.text, selected.cursor = value, cursor
	return handled
end

local definition: BlockDef<State> = {
	font = "sans",
	features = { "edit", "undo" },
	init = function(cx: BlockCx, args: { string }, saved: any): State
		local context = orchestration.new(args, saved)
		local catalog, problem
		if context ~= nil then catalog, problem = context.catalog, context.notice
		else catalog, problem = projects.load() end
		local selection = if context ~= nil then {} else projects.load_selection(catalog)
		return {
			pane = cx.pane,
			catalog = catalog,
			selection = selection,
			notice = problem,
			roster = if context == nil then spawn.load() else nil,
			setup = if context == nil and needs_setup(catalog, problem) then new_setup(catalog) else nil,
			orchestration = context,
			actions = {},
			next_action = 1,
		}
	end,
	title = function(_state: State): string return "WORK" end,
	view = function(state: State, _cx: BlockCx): BlockView return { main = view(state) } end,
	event = function(state: State, event: UiEvent, cx: BlockCx) on_event(state, event, cx) end,
	key = function(state: State, key: Key, _cx: BlockCx): boolean return on_key(state, key) end,
	save = function(state: State) return { mode = if state.orchestration == nil then "standalone" else "orchestration", selection = state.selection, orchestration = if state.orchestration ~= nil then orchestration.save(state.orchestration) else nil } end,
}

return definition
