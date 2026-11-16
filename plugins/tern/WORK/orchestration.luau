--!strict
-- WORK's native pane returns locators only. No execution or agent launch lives here.
local projects = require("./projects")
local text_edit = require("./text_edit")
local ui = tern.ui
local M = {}
local function utf16_length(value: string): number
	local length = 0
	for _, codepoint in utf8.codes(value) do length += if codepoint >= 65536 then 2 else 1 end
	return length
end
local function atom(v: any): boolean
	return (type(v) == "string" and #v > 0 and #v <= 512 and not v:find("%c")) or (type(v) == "number" and v == v and math.abs(v) < 2^53)
end
local function decode(bytes: any): any?
	if type(bytes) ~= "string" or #bytes > 8192 then return nil end
	local ok, value = pcall(tern.json.decode, bytes)
	return if ok and type(value) == "table" then value else nil
end
local function valid(request: any): boolean
	if type(request) ~= "table" or request.mode ~= "orchestration" or not atom(request.form_nonce) or not atom(request.request_id) or not atom(request.revision) or type(request.source) ~= "table" then return false end
	for key in pairs(request) do
		if key ~= "mode" and key ~= "form_nonce" and key ~= "request_id" and key ~= "revision" and key ~= "source" then return false end
	end
	for key in pairs(request.source) do
		if key ~= "pane" and key ~= "host" and key ~= "window" and key ~= "session" then return false end
	end
	for _, key in ipairs({ "pane", "host", "session" }) do if not atom(request.source[key]) then return false end end
	-- Tern can expose no window key; the captured pane, host and session still fence the request.
	if request.source.window ~= "" and not atom(request.source.window) then return false end
	return true
end
local function same(left: any, right: any): boolean
	if not valid(left) or not valid(right) then return false end
	for _, key in ipairs({ "form_nonce", "request_id", "revision" }) do if left[key] ~= right[key] then return false end end
	for _, key in ipairs({ "pane", "host", "window", "session" }) do if left.source[key] ~= right.source[key] then return false end end
	return true
end
local function load(state: any)
	state.catalog, state.notice = projects.load(true)
	if state.catalog.root ~= nil and #state.catalog.root > 2048 then
		state.catalog, state.notice = projects.empty(), "The configured Glitch root exceeds the context locator limit."
	end
	for index = #state.catalog.items, 1, -1 do
		local item = state.catalog.items[index]
		if #item.id > 256 or #item.path > 4096 then table.remove(state.catalog.items, index) end
	end
	state.plans = projects.load_plans(state.catalog)
	if state.root_expected == nil or not state.root_setup then state.root_expected = projects.root_snapshot() end
	if state.root == nil then state.root = state.catalog.root or "" end
	if state.catalog.root == nil then state.root_setup = true end
end
function M.new(args: { string }, saved: any): any?
	if type(saved) == "table" and saved.mode == "standalone" then return nil end
	local request = decode(args[1])
	local prior = if type(saved) == "table" then saved.orchestration else nil
	-- A reused block retains its latest request, not its original launch args.
	if type(prior) == "table" and valid(prior.request) then request = prior.request end
	if not valid(request) then return nil end
	local state: any = { request = request, query = "", path = "", workspace_id = nil, plan_path = nil, focus = nil, cursor = 0, actions = {}, next_action = 1, undo = {} }
	if type(prior) == "table" and same(request, prior.request) then
		state.result = prior.result
		state.workspace_id, state.plan_path = prior.workspace_id, prior.plan_path
		state.query, state.path = prior.query or "", prior.path or ""
		state.root, state.root_setup, state.cancelled = prior.root, prior.root_setup, prior.cancelled
		state.outcome, state.final_message = prior.outcome, prior.final_message
		if prior.root_setup then state.root_expected = prior.root_expected or { error = "Refresh WORK configuration before saving this retained folder draft." } end
	end
	load(state)
	return state
end
function M.save(state: any): any
	return { request = state.request, result = state.result, workspace_id = state.workspace_id, plan_path = state.plan_path, query = state.query, path = state.path, root = state.root, root_setup = state.root_setup, root_expected = state.root_expected, cancelled = state.cancelled, outcome = state.outcome, final_message = state.final_message }
end
local function button(state: any, label: string, kind: string, value: any, disabled: any?): any
	local token = tostring(state.next_action); state.next_action += 1
	state.actions[token] = { kind = kind, value = value }
	return ui.button(label, { disabled = disabled or false, actions = { click = kind .. "=" .. token } })
end
function M.context_node(state: any?): any
	local context: any = { mode = "standalone" }
	if state ~= nil then
		local request = state.request
		context = { mode = "orchestration", form_nonce = request.form_nonce, request_id = request.request_id, source = request.source, revision = request.revision,
			selection_revision = 1, phase = if state.result ~= nil then state.result.phase else "choosing", outcome = state.outcome }
	end
	local node = ui.text(tern.json.encode(context))
	node.p.key, node.p.role, node.p.hidden = "orch-context", "work.orch.context", true
	return node
end
function M.view(state: any): any
	state.actions = {}
	local rows = { ui.text({ ui.span("WORK ON", "title") }), ui.text({ ui.span("Choose context for the orchestration. This does not start an agent or resume a plan.", "muted") }) }
	table.insert(rows, M.context_node(state))
	if state.result ~= nil then
		local message = state.final_message or (if state.cancelled then "Context selection cancelled."
			elseif state.outcome == "success" then "Context added to the orchestration."
			elseif state.outcome == "refused" then "Context was not added. Return to WORK or choose WORK ON again."
			else "Returning selected context…")
		table.insert(rows, ui.text({ ui.span(message, "muted") }))
		local node = ui.text(tern.json.encode(state.result))
		node.p.key, node.p.role, node.p.hidden = "orch-selection", "work.orch.selection", true
		table.insert(rows, node)
		if state.result.phase == "accepted" or state.result.phase == "cancelled" then table.insert(rows, button(state, "Back to WORK", "orch-standalone", nil)) end
		return ui.col(rows)
	end
	table.insert(rows, ui.row({ button(state, "Back", "orch-cancel", nil), button(state, "Configure Glitch folder", "orch-root-open", nil) }))
	if state.root_setup then
		table.insert(rows, ui.text("Set the Glitch folder on this execution host. WORK checks its actual workspace registry before saving. No agent setup is required."))
		table.insert(rows, ui.node("field", { label = "Glitch folder on execution host" }, {
			ui.node("input", { key = "orch-root", text = state.root, cursor = utf16_length(state.root:sub(1, if state.focus == "root" then state.cursor else #state.root)), placeholder = "Absolute folder containing workspaces/registry.json", mono = true }),
		}))
		table.insert(rows, button(state, "Use Glitch folder", "orch-root-save", nil))
		if state.notice then table.insert(rows, ui.text({ ui.span(state.notice, "error") })) end
		table.insert(rows, button(state, "Refresh configuration", "orch-refresh", nil))
		return ui.col(rows)
	end
	table.insert(rows, ui.node("field", { label = "Search projects and unarchived plans" }, { ui.node("input", { key = "orch-search", text = state.query, placeholder = "Name or path", cursor = utf16_length(state.query:sub(1, if state.focus == "query" then state.cursor else #state.query)) }) }))
	table.insert(rows, ui.node("field", { label = "Plan path on this execution host" }, { ui.node("input", { key = "orch-path", text = state.path, placeholder = if state.catalog.root then state.catalog.root .. "/plans/…" else "Configure the WORK Glitch root", cursor = utf16_length(state.path:sub(1, if state.focus == "path" then state.cursor else #state.path)), mono = true }) }))
	table.insert(rows, ui.row({ button(state, "Select path", "orch-path", nil), button(state, "Refresh", "orch-refresh", nil) }))
	local query = state.query:lower()
	local shown = 0
	for _, item in ipairs(state.catalog.items) do
		if query ~= "" and not (item.name .. " " .. item.path):lower():find(query, 1, true) then continue end
		shown += 1
		if shown > 100 then continue end
		table.insert(rows, button(state, (if state.workspace_id == item.id then "✓ " else "") .. item.name, "orch-workspace", item.id))
		table.insert(rows, ui.text({ ui.span(item.path, "path") }))
	end
	for _, plan in ipairs(state.plans.items) do
		if query ~= "" and not (plan.title .. " " .. plan.path):lower():find(query, 1, true) then continue end
		shown += 1
		if shown > 100 then continue end
		table.insert(rows, button(state, (if state.plan_path == plan.path then "✓ " else "") .. plan.title, "orch-plan", plan.path))
		table.insert(rows, ui.text({ ui.span(plan.path .. (if plan.needs_project_choice then " — choose a project explicitly" else " — " .. plan.workspace_id), "muted") }))
	end
	if shown > 100 then table.insert(rows, ui.text({ ui.span("More matches: narrow the search to reach them.", "muted") })) end
	if shown == 0 then table.insert(rows, ui.text({ ui.span("No matching active projects or unarchived plans.", "muted") })) end
	table.insert(rows, button(state, "Project context only", "orch-context", nil))
	table.insert(rows, button(state, "Use selected context", "orch-submit", nil, if state.workspace_id == nil then "Select a project" else false))
	if state.notice then table.insert(rows, ui.text({ ui.span(state.notice, "error") })) end
	for _, problem in ipairs(state.plans.rejected) do table.insert(rows, ui.text({ ui.span(problem, "muted") })) end
	return ui.col(rows)
end
function M.event(state: any, event: any, cx: any): boolean
	if (event.ev == "edit" or event.ev == "undo") and type(event.id) == "string" and state.result == nil then
		local field = if event.id:match("orch%-search$") and not state.root_setup then "query"
			elseif event.id:match("orch%-path$") and not state.root_setup then "path"
			elseif event.id:match("orch%-root$") and state.root_setup then "root" else nil
		if field == nil then return true end
		local history = state.undo[field] or {}; state.undo[field] = history
		if event.ev == "undo" then
			local old = table.remove(history)
			if old then state[field], state.cursor, state.focus = old.text, old.cursor, field end
		else
			local value, cursor = text_edit.apply(state[field], event, if field == "root" then 2048 else 4096)
			if value ~= nil and cursor ~= nil then
				if value ~= state[field] then text_edit.remember(history, state[field], if state.focus == field then state.cursor else #state[field]) end
				state[field], state.cursor, state.focus = value, cursor, field
			end
		end
		return true
	end
	if event.ev == "focus" and type(event.id) == "string" then
		if event.id:match("orch%-search$") and not state.root_setup then state.focus = "query"; state.cursor = #state.query; cx:frame({ { "focus", event.id } }); return true end
		if event.id:match("orch%-path$") and not state.root_setup then state.focus = "path"; state.cursor = #state.path; cx:frame({ { "focus", event.id } }); return true end
		if event.id:match("orch%-root$") and state.root_setup then state.focus = "root"; state.cursor = #state.root; cx:frame({ { "focus", event.id } }); return true end
	end
	if event.ev ~= "action" then return true end
	if event.act == "orch-selection-ack" then
		local ack = decode(event.value)
		if ack and state.result and state.result.phase ~= "accepted" and ack.form_nonce == state.request.form_nonce and ack.request_id == state.request.request_id and ack.selection_revision == 1
			and (ack.outcome == "success" or ack.outcome == "refused" or ack.outcome == "cancelled")
			and (ack.message == nil or type(ack.message) == "string" and #ack.message <= 512 and utf8.len(ack.message) ~= nil and not ack.message:find("%c")) then
			if state.cancelled and ack.outcome ~= "cancelled" then return true end
			state.outcome = ack.outcome
			state.cancelled = ack.outcome == "cancelled"
			state.final_message = ack.message
			state.result.phase = "accepted"
		end
		return true
	end
	if event.act == "orch-open" then
		local request = decode(event.value)
		if same(request, state.request) then return true end
		if valid(request) and state.result ~= nil and state.result.phase == "accepted" then
			-- Never renew/replay the settled request with a changed origin or revision.
			if request.form_nonce == state.request.form_nonce or request.request_id == state.request.request_id then return true end
			local fresh = M.new({ event.value }, nil)
			for key in pairs(state) do state[key] = nil end
			for key, value in pairs(fresh) do state[key] = value end
		end
		return true
	end
	if state.result ~= nil then return true end
	local entry = state.actions[event.value]
	if entry == nil or entry.kind ~= event.act then return true end
	if entry.kind == "orch-refresh" then state.root_expected = nil; load(state)
	elseif entry.kind == "orch-cancel" then
		local request = state.request
		state.cancelled = true
		state.result = { form_nonce = request.form_nonce, request_id = request.request_id, source = request.source, revision = request.revision, selection_revision = 1, phase = "cancelled" }
	elseif entry.kind == "orch-root-open" then state.root_setup = true; state.focus = nil
	elseif entry.kind == "orch-root-save" then
		local ok, problem = projects.configure_root(state.root, state.root_expected)
		if not ok then state.notice = problem
		else
			state.root_setup, state.focus = false, nil
			state.workspace_id, state.plan_path, state.path = nil, nil, ""
			load(state)
		end
	elseif entry.kind == "orch-workspace" then state.workspace_id = entry.value
	elseif entry.kind == "orch-context" then state.plan_path, state.path, state.notice = nil, "", nil
	elseif entry.kind == "orch-plan" or entry.kind == "orch-path" then
		local path = if entry.kind == "orch-path" then state.path else entry.value
		local plan = nil
		for _, candidate in ipairs(state.plans.items) do if candidate.path == path then plan = candidate; break end end
		if plan == nil then state.notice = "Choose a listed, unarchived plan on this execution host."
		else state.plan_path, state.path = plan.path, plan.path; state.workspace_id = plan.workspace_id; state.notice = nil end
	elseif entry.kind == "orch-submit" then
		load(state)
		local workspace = projects.find(state.catalog, state.workspace_id)
		if workspace == nil then state.notice = "The selected project changed. Select it again."; return true end
		if state.plan_path ~= nil then
			local plan = nil
			for _, candidate in ipairs(state.plans.items) do if candidate.path == state.plan_path then plan = candidate; break end end
			if plan == nil then state.notice = "The selected plan is no longer available."; return true end
			if plan.workspace_id ~= nil and plan.workspace_id ~= workspace.id then state.notice = "This plan belongs to a different project. Select the plan again."; return true end
		end
		local request = state.request
		state.result = { form_nonce = request.form_nonce, request_id = request.request_id, source = request.source, revision = request.revision, selection_revision = 1, phase = "selected", workspace_id = workspace.id, workspace_path = workspace.path, glitch_root = state.catalog.root, source_kind = if state.plan_path then "plan_file" else "workspace", source_locator = state.plan_path or workspace.path }
	end
	return true
end
function M.key(state: any, key: any, edit_value: any): boolean
	if state.result ~= nil or state.focus == nil then return false end
	if key.name == "escape" then state.focus = nil; return true end
	local value, cursor, handled = edit_value(state[state.focus], state.cursor, key)
	if handled and #value <= 4096 and utf8.len(value) ~= nil and not value:find("%c") then
		if value ~= state[state.focus] then
			local history = state.undo[state.focus] or {}; state.undo[state.focus] = history
			text_edit.remember(history, state[state.focus], state.cursor)
		end
		state[state.focus], state.cursor = value, cursor
	end
	return handled
end
return M
