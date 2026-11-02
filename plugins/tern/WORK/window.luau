--!strict
-- Window-owned pane command; row actions run in the host block.
local PANEL_BLOCK = "tern-work.panel"

local previous_non_panel: number? = nil

local function pane_info(cx: any, pane_id: number)
	for _, pane in ipairs(cx.session:panes()) do
		if pane.pane == pane_id then return pane end
	end
	return nil
end

local function panel_pane(cx: any, pane_id: number?): number?
	if pane_id == nil then return nil end
	local pane = pane_info(cx, pane_id)
	if pane ~= nil and pane.block == PANEL_BLOCK then return pane.pane end
	return nil
end

local function tab_contains(tab: any, pane_id: number): boolean
	if type(tab.panes) ~= "table" then return false end
	for _, candidate in ipairs(tab.panes) do
		if candidate == pane_id then return true end
	end
	return false
end

local function focused_tab(cx: any): any
	local focused = cx.session:focused()
	if focused == nil then return nil end
	for _, tab in ipairs(cx.session:tabs()) do
		if tab_contains(tab, focused) then return tab end
	end
	return nil
end

local function panel_in_focused_tab(cx: any): number?
	local tab = focused_tab(cx)
	if tab == nil or type(tab.panes) ~= "table" then return nil end
	for _, pane_id in ipairs(tab.panes) do
		local panel = panel_pane(cx, pane_id)
		if panel ~= nil then return panel end
	end
	return nil
end

tern.on("window_start", function(cx)
	local focused = cx.session:focused()
	if focused ~= nil and panel_pane(cx, focused) == nil then previous_non_panel = focused end
end)

tern.on("focus", function(event, cx)
	if event.pane ~= nil and panel_pane(cx, event.pane) == nil then previous_non_panel = event.pane end
end)

local function url_decode(value: string): string
	return (string.gsub(value, "%%(%x%x)", function(hex)
		return string.char(tonumber(hex, 16))
	end))
end

local function query_value(query: string, wanted: string): string?
	for key, value in string.gmatch(query, "([^&=]+)=([^&]*)") do
		if url_decode(key) == wanted then return url_decode(value) end
	end
	return nil
end

local function valid_workspace_path(workspace_id: string, cwd: string): boolean
	if string.find(cwd, "%.%.") ~= nil then return false end
	local normalized = string.gsub(cwd, "\\", "/")
	local workspace_path = string.match(normalized, "/workspaces/([^/]+)$")
	return string.match(workspace_id, "^[a-z0-9][a-z0-9%-]*$") ~= nil
		and workspace_path ~= nil
		and string.match(workspace_path, "^[a-z0-9][a-z0-9%-]*$") ~= nil
end

local function start_work(workspace_id: string, cwd: string, cx: any): boolean
	if not valid_workspace_path(workspace_id, cwd) then
		cx:toast("error", "Workspace unavailable", "The workspace path is not valid.")
		return true
	end
	local ok, pane = pcall(function()
		return cx.agents:start({
			prompt = "Work on " .. workspace_id,
			cwd = cwd,
			how = "split",
		})
	end)
	if not ok or type(pane) ~= "number" then
		cx:toast("error", "Could not start the agent", tostring(pane))
	else
		cx:toast("success", "Started " .. workspace_id, "The default Tern agent is working in pane " .. tostring(pane) .. ".")
	end
	return true
end

tern.route.link(function(link, cx)
	local query = string.match(link.url, "^tern://work%?(.+)$")
	if query == nil then return nil end
	local workspace_id = query_value(query, "workspace")
	local cwd = query_value(query, "cwd")
	if workspace_id == nil or cwd == nil then
		cx:toast("error", "Could not start the agent", "The WORK link did not include a complete workspace.")
		return { handled = true }
	end
	start_work(workspace_id, cwd, cx)
	return { handled = true }
end)

local function open_panel(cx: any): number?
	local pane = cx:new_block(PANEL_BLOCK, {}, "beside")
	if pane == nil then
		cx:toast("error", "WORK unavailable", "WORK must run on the Glitch host that owns workspaces/registry.json.")
	end
	return pane
end
tern.command({
	id = "show_projects",
	title = "WORK",
	icon = "list",
	group = "Glitch",
	keys = {},
	run = function(cx)
		local existing = panel_in_focused_tab(cx)
		if existing ~= nil then
			cx.layout:close(existing)
			if previous_non_panel ~= nil and panel_pane(cx, previous_non_panel) == nil then
				cx.layout:focus(previous_non_panel)
			end
			return
		end
		open_panel(cx)
	end,
})

tern.files.button({
	id = "work",
	title = "WORK",
	icon = "list",
	run = function(_files, cx)
		open_panel(cx)
	end,
})
