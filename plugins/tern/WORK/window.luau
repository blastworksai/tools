--!strict
local Launch = require("./launch")

local PANEL_BLOCK = "tern-work.panel"
local previous_non_panel: number? = nil

local function pane_info(cx: any, pane_id: number): any?
	local ok, pane = pcall(function() return cx.session:pane(pane_id) end)
	if ok then return pane end
	return nil
end

local function panel_pane(cx: any, pane_id: number?): number?
	if pane_id == nil then return nil end
	local pane = pane_info(cx, pane_id)
	if pane ~= nil and pane.block == PANEL_BLOCK and pane.exited == nil then return pane.pane end
	return nil
end

local function origin_ok(cx: any, pane_id: any): boolean
	return type(pane_id) == "number" and panel_pane(cx, pane_id) == pane_id
end

local function tab_contains(tab: any, pane_id: number): boolean
	if type(tab.panes) ~= "table" then return false end
	for _, candidate in ipairs(tab.panes) do if candidate == pane_id then return true end end
	return false
end

local function focused_tab(cx: any): any
	local focused = cx.session:focused()
	if focused == nil then return nil end
	for _, tab in ipairs(cx.session:tabs()) do if tab_contains(tab, focused) then return tab end end
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

local function url_decode(value: string): string?
	local remaining = string.gsub(value, "%%(%x%x)", "")
	if string.find(remaining, "%%") ~= nil then return nil end
	return (string.gsub(value, "%%(%x%x)", function(hex)
		return string.char(assert(tonumber(hex, 16))) -- %x%x always captures one byte.
	end))
end

local function query_values(query: string): any?
	local values = {}
	for pair in string.gmatch(query, "([^&]+)") do
		local key, value = string.match(pair, "^([^=]+)=(.*)$")
		if key == nil or value == nil then return nil end
		local decoded_key, decoded_value = url_decode(key), url_decode(value)
		if decoded_key == nil or decoded_value == nil or values[decoded_key] ~= nil then return nil end
		values[decoded_key] = decoded_value
	end
	return values
end

local function valid_request(workspace_id: any, cwd: any): boolean
	if type(workspace_id) ~= "string" or string.match(workspace_id, "^[a-z0-9][a-z0-9%-]*$") == nil then return false end
	if type(cwd) ~= "string" or string.find(cwd, "%.%.") ~= nil or string.find(cwd, "%c") ~= nil then return false end
	return string.match(cwd, "^/") ~= nil or string.match(cwd, "^%a:[/\\]") ~= nil or string.match(cwd, "^\\\\") ~= nil
end

local function refuse(cx: any, text: string, detail: string?)
	cx:toast("error", text, detail)
end

local function copy_prompt(cx: any, work_pane: number, pane: number, prompt: string, label: string)
	if not origin_ok(cx, work_pane) then refuse(cx, "Agent prompt not copied", "The WORK pane changed before the clipboard write."); return end
	local info = pane_info(cx, pane)
	if info == nil or info.exited ~= nil then refuse(cx, label .. " stopped", "Paste was not prepared because the new agent pane is unavailable."); return end
	local ok, problem = pcall(function() cx:copy(prompt) end)
	if not ok then refuse(cx, "Could not copy " .. prompt, tostring(problem)); return end
	cx:toast("info", "Paste " .. prompt .. " into " .. label, "Paste it only when that agent's own prompt is ready, then submit it yourself. WORK did not type or press Enter.")
end

local function start_acp(agent: any, workspace_id: string, cwd: string, work_pane: number, cx: any)
	local command, problem = Launch.command(agent, tern.json.encode)
	if command == nil then refuse(cx, "Could not start the ACP agent", problem); return end
	if not origin_ok(cx, work_pane) then refuse(cx, "Agent not started", "Only a live WORK pane can start an agent."); return end
	local focus_ok, focus_problem = pcall(function() cx.layout:focus(work_pane) end)
	if not focus_ok then refuse(cx, "Could not place the ACP agent", tostring(focus_problem)); return end
	if not origin_ok(cx, work_pane) then refuse(cx, "Agent not started", "The WORK pane changed before launch."); return end
	local prompt = "/work-on " .. workspace_id
	local ok, pane = pcall(function()
		return cx.agents:start({ prompt = prompt, cwd = cwd, command = command, how = "split" })
	end)
	if not ok or type(pane) ~= "number" then refuse(cx, "Could not start the ACP agent", tostring(pane)); return end
	local info = pane_info(cx, pane)
	if info == nil or info.exited ~= nil then refuse(cx, "ACP agent unavailable", "The new agent pane ended before WORK could confirm it."); return end
	cx:toast("success", "Started " .. workspace_id, "Tern queued " .. prompt .. " for the ACP agent and will submit it only when native input is ready.")
end

local function start_cli(agent: any, workspace_id: string, cwd: string, work_pane: number, cx: any)
	local command, problem = Launch.command(agent, tern.json.encode)
	if command == nil then refuse(cx, "Could not start the CLI agent", problem); return end
	if not origin_ok(cx, work_pane) then refuse(cx, "Agent not started", "Only a live WORK pane can start an agent."); return end
	local ok, pane = pcall(function()
		return cx.layout:split(work_pane, "right", { command = command, cwd = cwd })
	end)
	if not ok or type(pane) ~= "number" then refuse(cx, "Could not start the CLI agent", tostring(pane)); return end
	copy_prompt(cx, work_pane, pane, "/work-on " .. workspace_id, "the CLI agent")
end

local function start_spawn_agent(_values: any, _workspace_id: string, _cwd: string, work_pane: number, cx: any)
	if not origin_ok(cx, work_pane) then refuse(cx, "Agent not started", "Only a live WORK pane can start SPAWN agents."); return end
	refuse(cx, "SPAWN launch held", "SPAWN has no supported fresh host-owned current-record read and native single-winner launch claim for WORK. No launch or clipboard write occurred; use the configured WORK agent.")
end

tern.route.link(function(link, cx)
	local query = string.match(link.url, "^tern://work%?(.+)$")
	if query == nil then return nil end
	if not origin_ok(cx, link.pane) then
		refuse(cx, "Agent not started", "Only a link in the live WORK pane can start an agent.")
		return { handled = true }
	end
	local values = query_values(query)
	local workspace_id, cwd = if values ~= nil then values.workspace else nil, if values ~= nil then values.cwd else nil
	if not valid_request(workspace_id, cwd) then
		refuse(cx, "Workspace unavailable", "The WORK link did not include one complete, safe workspace.")
		return { handled = true }
	end
	local route = if values ~= nil then values.agent else nil
	if route == ":host" then
		if values.delivery ~= "host" then refuse(cx, "Agent not started", "The WORK host-agent route is invalid.")
		else
			local agent, problem = Launch.decode_agent(values.command, tern.json.decode)
			if agent == nil then refuse(cx, "Agent not started", problem)
			elseif agent.kind == "acp" then start_acp(agent, workspace_id, cwd, link.pane, cx)
			else start_cli(agent, workspace_id, cwd, link.pane, cx) end
		end
	elseif type(route) == "string" then
		start_spawn_agent(values, workspace_id, cwd, link.pane, cx)
	else
		refuse(cx, "Agent not started", "The WORK link did not select an agent.")
	end
	return { handled = true }
end)

local function open_panel(cx: any): number?
	local pane = cx:new_block(PANEL_BLOCK, {}, "beside")
	if pane == nil then cx:toast("error", "WORK unavailable", "WORK must run on the Glitch host that owns workspaces/registry.json.") end
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
			if previous_non_panel ~= nil and panel_pane(cx, previous_non_panel) == nil then cx.layout:focus(previous_non_panel) end
			return
		end
		open_panel(cx)
	end,
})

tern.files.button({
	id = "work",
	title = "WORK",
	icon = "list",
	run = function(_files, cx) open_panel(cx) end,
})

require("./updater/window").register({
	name = "WORK", dir = "WORK", title_prefix = "WORK ",
	background_ready = function(cx)
		-- Background discovery must not spawn helpers while the user is working
		-- in this panel, including Setup. Explicit updater commands still run.
		local focused = cx.session:focused()
		if focused == nil then return true end
		local pane = pane_info(cx, focused)
		return pane ~= nil and (pane.block ~= PANEL_BLOCK or pane.exited ~= nil)
	end,
})
