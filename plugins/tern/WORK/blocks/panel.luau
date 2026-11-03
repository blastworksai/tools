--!strict
local ui = tern.ui
local projects = require("../projects")

type State = {
	pane: number,
	catalog: any,
	selection: any,
	notice: string?,
	actions: { [string]: any },
	next_action: number,
}


type BlockCx = { pane: number, open: (target: string) -> () }
type UiEvent = { ev: string, act: string?, value: any? }

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

local function plan_row(state: State, item: any): any
	local selected = state.selection.workspace_id == item.id
	local select_token = action(state, "select", item.id)
	local work_token = action(state, "work-on", item.id)
	local work_on = ui.node("row", {
		role = "omp.btn",
		class = "glitch-plan-work",
		actions = { click = "work-on=" .. work_token },
		title = "Work On",
		tone = "warning",
	}, {
		ui.text("Work On"),
	})
	return ui.el("div", {
		class = if selected then "glitch-plan-row glitch-plan-row-selected" else "glitch-plan-row",
		actions = { click = "select=" .. select_token },
	}, {
		ui.el("div", { class = "glitch-plan-info" }, {
			ui.text({ ui.span(item.name, "strong") }),
			workspace_meta(item),
		}),
		work_on,
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
	return ui.col(rows)
end



local function on_event(state: State, event: UiEvent, cx: BlockCx)
	if event.ev ~= "action" or event.act == nil or type(event.value) ~= "string" then return end
	local entry = state.actions[event.value]
	if entry == nil or entry.kind ~= event.act then return end

	if entry.kind == "work-on" then
		local item = projects.find(state.catalog, entry.payload)
		if item == nil then
			cx:toast("error", "Workspace unavailable", "It is no longer an active Glitch workspace.")
		else
			cx:open(projects.work_on_url(item.id, projects.brain_root()))
		end
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
