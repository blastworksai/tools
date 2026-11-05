--!strict
local ui = tern.ui
local projects = require("../projects")
local spawn = require("../spawn")

-- The default-agent row's id; SPAWN record ids start with a letter or digit.
local DEFAULT_ROW = ":default"
local MENU_KEY = "work-on-"

type State = {
	pane: number,
	catalog: any,
	selection: any,
	notice: string?,
	-- SPAWN's saved agents on this host; nil when SPAWN isn't installed here.
	roster: any?,
	actions: { [string]: any },
	next_action: number,
}


type BlockCx = { pane: number, open: (target: string) -> () }
type UiEvent = { ev: string, act: string?, value: any?, id: string? }

local function save_selection(state: State)
	projects.save_selection(state.selection)
end

local function action(state: State, kind: string, payload: any): string
	local token = tostring(state.next_action)
	state.next_action += 1
	state.actions[token] = { kind = kind, payload = payload }
	return token
end

local function spawn_agents(state: State): boolean
	return state.roster ~= nil and #state.roster.agents > 0
end

local function workspace_meta(item: any): any
	local spans = { ui.span(item.kind, "muted") }
	if item.remote ~= nil then
		table.insert(spans, ui.span(" · ", "muted"))
		table.insert(spans, ui.link("GitHub", item.remote, "link"))
	end
	return ui.text(spans)
end

-- With SPAWN agents saved on this host, Work On drops down a menu of them.
local function work_on_menu(state: State, item: any): any
	local rows: { any } = { { header = "Work on " .. item.name .. " with" } }
	for _, agent in ipairs(state.roster.agents) do
		table.insert(rows, { id = agent.id, label = agent.label, icon = agent.icon, disabled = agent.disabled or false })
	end
	table.insert(rows, "-")
	table.insert(rows, { id = DEFAULT_ROW, label = "Tern default agent", icon = "tern" })
	return ui.node("menu", {
		key = MENU_KEY .. item.id,
		role = "glitch.work-on",
		text = "Work On",
		caret = true,
		trigger = "primary",
		size = "sm",
		variant = "dense",
		align = "end",
		title = "Work On",
		items = rows,
	})
end

local function work_on_button(state: State, item: any): any
	local work_token = action(state, "work-on", item.id)
	return ui.node("row", {
		role = "omp.btn",
		class = "glitch-plan-work",
		actions = { click = "work-on=" .. work_token },
		title = "Work On",
		tone = "warning",
	}, {
		ui.text("Work On"),
	})
end

local function plan_row(state: State, item: any): any
	local selected = state.selection.workspace_id == item.id
	local select_token = action(state, "select", item.id)
	return ui.el("div", {
		class = if selected then "glitch-plan-row glitch-plan-row-selected" else "glitch-plan-row",
		actions = { click = "select=" .. select_token },
	}, {
		ui.el("div", { class = "glitch-plan-info" }, {
			ui.text({ ui.span(item.name, "strong") }),
			workspace_meta(item),
		}),
		if spawn_agents(state) then work_on_menu(state, item) else work_on_button(state, item),
	})
end

local function view(state: State): any
	state.actions = {}
	state.next_action = 1
	local rows = {
		ui.text({ ui.span("WORK", "title") }),
		ui.text({ ui.span("Active workspaces known to /work-on.", "muted") }),
	}

	if #state.catalog.items == 0 then
		table.insert(rows, ui.text({ ui.span("No active workspaces found.", "muted") }))
	else
		for _, item in ipairs(state.catalog.items) do
			table.insert(rows, plan_row(state, item))
		end

	end

	if state.notice ~= nil then
		table.insert(rows, ui.text({ ui.span(state.notice, "info") }))
	end
	if state.roster ~= nil and state.roster.problem ~= nil then
		table.insert(rows, ui.text({ ui.span(state.roster.problem, "muted") }))
	end
	return ui.col(rows)
end

local function start_default(state: State, workspace_id: string, cx: any)
	local item = projects.find(state.catalog, workspace_id)
	if item == nil then
		cx:toast("error", "Workspace unavailable", "It is no longer an active Glitch workspace.")
		return
	end
	cx:open(projects.work_on_url(item.id, projects.brain_root()))
end

local function start_spawn(state: State, workspace_id: string, agent_id: string, cx: any)
	local item = projects.find(state.catalog, workspace_id)
	if item == nil then
		cx:toast("error", "Workspace unavailable", "It is no longer an active Glitch workspace.")
		return
	end
	local agent = spawn.find(state.roster, agent_id)
	if agent == nil or agent.disabled ~= nil then
		cx:toast("error", "SPAWN agent unavailable", if agent ~= nil then agent.disabled else "It is no longer saved in SPAWN.")
		return
	end
	local command, delivery, problem = spawn.render(agent.record, "/work-on " .. item.id)
	if command == nil or delivery == nil then
		cx:toast("error", "Could not start " .. agent.label, problem)
		return
	end
	cx:open(projects.work_on_url(item.id, projects.brain_root(), {
		agent = agent.id, label = agent.label, delivery = delivery, command = command,
	}))
end

local function on_menu_event(state: State, event: UiEvent, cx: BlockCx): boolean
	if type(event.id) ~= "string" then return false end
	local workspace_id = string.match(event.id, "work%-on%-([a-z0-9][a-z0-9%-]*)$")
	if workspace_id == nil then return false end
	if event.ev == "action" and type(event.act) == "string" then
		if event.act == DEFAULT_ROW then
			start_default(state, workspace_id, cx)
		else
			start_spawn(state, workspace_id, event.act, cx)
		end
	end
	return true
end

local function on_event(state: State, event: UiEvent, cx: BlockCx)
	-- SPAWN's roster can change while WORK is open; any interaction rereads it.
	state.roster = spawn.load()
	if on_menu_event(state, event, cx) then return end
	if event.ev ~= "action" or event.act == nil or type(event.value) ~= "string" then return end
	local entry = state.actions[event.value]
	if entry == nil or entry.kind ~= event.act then return end

	if entry.kind == "work-on" then
		start_default(state, entry.payload, cx)
		return
	end

	if entry.kind == "select" then
		state.selection = projects.selection(state.catalog, { workspace_id = entry.payload })
		save_selection(state)
		return
	end

end

local function catalog_from_args(args: { string }): (any, string?)
	if type(args[1]) ~= "string" then
		return projects.load()
	end
	local ok, payload = pcall(tern.json.decode, args[1])
	if not ok or type(payload) ~= "table" or type(payload.catalog) ~= "table" then
		return projects.empty(), "workspace catalog passed from Tern window is invalid"
	end
	return payload.catalog, if type(payload.notice) == "string" then payload.notice else nil
end

local definition = {
	font = "sans",
	init = function(cx: BlockCx, args: { string }, _saved: any): State
		local catalog, problem = catalog_from_args(args)
		local selection = projects.load_selection(catalog)
		return {
			pane = cx.pane,
			catalog = catalog,
			selection = selection,
			notice = problem,
			roster = spawn.load(),
			actions = {},
			next_action = 1,
		}
	end,
	title = function(_state: State): string
		return "WORK"
	end,
	view = function(state: State, _cx: BlockCx)
		return { main = view(state) }
	end,
	event = function(state: State, event: UiEvent, cx: BlockCx)
		on_event(state, event, cx)
	end,
	save = function(state: State)
		return { selection = state.selection }
	end,
}

return definition
