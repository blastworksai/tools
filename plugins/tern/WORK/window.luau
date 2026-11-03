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

local function valid_request(workspace_id: string, cwd: string): boolean
	if string.match(workspace_id, "^[a-z0-9][a-z0-9%-]*$") == nil then return false end
	if string.find(cwd, "%.%.") ~= nil or string.find(cwd, "%c") ~= nil then return false end
	return string.match(cwd, "^/") ~= nil or string.match(cwd, "^%a:[/\\]") ~= nil
end

local PLACE_ATTEMPTS = 8
local PLACE_RETRY_MS = 250

-- Tern splits an agent off the window's focused pane, which for a WORK block on
-- another host can sit in a different tab. Pin the agent to the WORK pane's right.
local function place_beside(agent_pane: number, work_pane: number, workspace_id: string, attempt: number, cx: any)
	local ok, moved = pcall(function()
		return cx.layout:move(agent_pane, work_pane, "right")
	end)
	if ok and moved == true then
		cx:toast("success", "Started " .. workspace_id, "The default Tern agent is working beside WORK.")
		return
	end
	if attempt >= PLACE_ATTEMPTS then
		cx:toast("error", "Agent opened elsewhere", "Could not move pane " .. tostring(agent_pane) .. " beside WORK.")
		return
	end
	tern.timer(PLACE_RETRY_MS, function(next_cx)
		if next_cx ~= nil then place_beside(agent_pane, work_pane, workspace_id, attempt + 1, next_cx) end
	end)
end

-- Tern's own chats (`tern acp …`) take a prompt through Tern's send path. A CLI
-- in a terminal (claude, codex, omp) gets it as its launch argument instead:
-- Tern's queued prompt never reached a TUI agent on a remote host.
local function start_work(workspace_id: string, cwd: string, work_pane: number, cx: any): boolean
	if not valid_request(workspace_id, cwd) then
		cx:toast("error", "Workspace unavailable", "The WORK link is not valid.")
		return true
	end
	local command = cx.settings:get("agent_command")
	if type(command) ~= "string" or string.match(command, "^%s*$") then
		cx:toast("error", "No default agent", "Set Preferences › Coding agents › Agent.")
		return true
	end
	-- The slug is [a-z0-9-], so double quotes are safe in POSIX shells and on Windows.
	local prompt = "/work-on " .. workspace_id
	if string.match(command, "^%s*tern%s") then
		local ok, pane = pcall(function()
			return cx.agents:start({ prompt = prompt, cwd = cwd, command = command, how = "split" })
		end)
		if not ok or type(pane) ~= "number" then
			cx:toast("error", "Could not start the agent", tostring(pane))
		else
			place_beside(pane, work_pane, workspace_id, 1, cx)
		end
		return true
	end
	local ok, pane = pcall(function()
		return cx.layout:split(work_pane, "right", { command = command .. ' "' .. prompt .. '"', cwd = cwd })
	end)
	if not ok or type(pane) ~= "number" then
		cx:toast("error", "Could not start the agent", tostring(pane))
	else
		cx:toast("success", "Started " .. workspace_id, "The default Tern agent is running " .. prompt .. " beside WORK.")
	end
	return true
end

tern.route.link(function(link, cx)
	local query = string.match(link.url, "^tern://work%?(.+)$")
	if query == nil then return nil end
	-- The WORK block's cx:open reaches every window showing its pane. Only the
	-- window the click came from has the WORK pane focused; the rest stand down,
	-- or each attached window would start its own agent.
	if cx.session:focused() ~= link.pane then return { handled = true } end
	local workspace_id = query_value(query, "workspace")
	local cwd = query_value(query, "cwd")
	if workspace_id == nil or cwd == nil then
		cx:toast("error", "Could not start the agent", "The WORK link did not include a complete workspace.")
		return { handled = true }
	end
	start_work(workspace_id, cwd, link.pane, cx)
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

