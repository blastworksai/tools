--!strict
-- Each window reads its local companion; source hosts collect without any block.
-- Reload replaces this VM and its timers, so no stop path is needed.
local companion = require("./companion")
local aggregate = require("./aggregate").new()
local view_layout = require("./view_layout")
local layouts = view_layout.new()
local refresh: any
local presentation = require("./presentation")
local setup_module = require("./setup")
local BLOCK = "usage.accounts"
local DETAILS = "plugin.usage.details"
local DIAGNOSTICS = "plugin.usage.diagnostics"
local POLL_MS = 15000
local status_segments: { any } = {}
local problem: any = nil
local phase = "loading"
local timer: any = nil
local inflight = false
local ready = false
local window: string? = nil
local diagnostics_generation = 0

local function render()
	local model = aggregate:project(math.floor(os.time() * 1000))
	-- Until the companion has answered, an empty model says nothing about SPAWN.
	status_segments = if #model.accounts > 0 or phase == "ready" then presentation.segments(model) else {}
	if phase ~= "ready" then
		table.insert(status_segments, { text = if phase == "loading" then "USAGE loading" elseif phase == "setup_required" then "USAGE setup required" else "USAGE unavailable · last known",
			icon = "gauge", tone = "muted", command = DIAGNOSTICS })
	end
	if phase == "ready" and aggregate.diagnostics ~= nil and (aggregate.diagnostics.stale_sources or 0) > 0 then
		table.insert(status_segments, { text = "USAGE partial · " .. tostring(aggregate.diagnostics.stale_sources) .. " sources not current",
			icon = "gauge", tone = "muted", command = DIAGNOSTICS })
	end
	if refresh ~= nil and (refresh.requesting or refresh.problem ~= nil or (refresh.progress and refresh.progress.state == "running")) then
		table.insert(status_segments, { text = refresh:text(), icon = "gauge", tone = "muted", command = DETAILS })
	end
	tern.chrome.refresh()
end
refresh = require("./view_state").new(render)
local function set_problem(err: any?)
	problem = err
	local code = if err ~= nil then err.code else "companion_unavailable"
	phase = if code == "setup_required" or code == "python_required" or code == "migration_conflict" then "setup_required" else "unavailable"
end
local poll: (any?) -> ()
local setup = setup_module.new(function(cx) poll(cx) end)
local function schedule(delay: number)
	if timer ~= nil then timer:cancel() end
	timer = tern.timer(delay, function(cx)
		timer = nil
		poll(cx)
	end)
end
poll = function(cx: any?)
	if inflight then return end
	if cx == nil then schedule(250); return end
	if window == nil then
		window = cx:window_key()
		companion.set_client("window:" .. (window :: string), "window")
	end
	if timer ~= nil then timer:cancel(); timer = nil end
	inflight = true
	local function finished()
		inflight = false
		render()
		schedule(POLL_MS)
	end
	local function display()
		aggregate:refresh(function(ok, err)
			if ok then phase, problem = "ready", nil else set_problem(err) end
			finished()
			if ok then refresh:poll() end
		end)
	end
	if not ready then
		companion.ensure(function(value, err)
			if value == nil then set_problem(err); finished(); return end
			ready = true
			display()
		end)
	else
		companion.request("register_client", { client_id = "window:" .. (window :: string), kind = "window", ttl_seconds = 90 }, function(value, err)
			if value == nil then ready = false; set_problem(err); finished(); return end
			display()
		end)
	end
end
local function details(cx: any?)
	if cx == nil then return end
	layouts:show(cx)
end
local function diagnostics(cx: any?)
	if cx == nil then return end
	diagnostics_generation += 1
	local request_generation = diagnostics_generation
	local function show(fresh: any, remote: any?, err: any?)
		if fresh == nil or request_generation ~= diagnostics_generation then return end
		local hidden = fresh.settings:get("status_bar") ~= true
		local items = {
			{ label = "Companion: " .. phase, detail = if problem ~= nil then problem.message else "Original observation times retained; missing quotas are not zero." },
			{ label = refresh:text(), detail = "The companion runs headless usage reads. No owner-pane input or synthetic turns." },
			{ label = if hidden then "Summary hidden (status bar off)" else "Summary enabled", detail = "Show Summary turns on Tern's status bar; USAGE never changes it on its own.", action = "summary" },
			{ label = "Open USAGE Setup", detail = "Runtime, pairing, export and headless-read permission. Accounts come from SPAWN.", action = "setup" },
		}
		if err ~= nil then table.insert(items, { label = "Local diagnostics unavailable", detail = err.message }) end
		if remote ~= nil then
			table.insert(items, { label = "Sync: " .. tostring(remote.sync.state), detail = tostring(remote.sync.error or "No sync error") })
			table.insert(items, { label = "Membership: " .. remote.role, detail = "Device " .. remote.device_id .. " · group " .. remote.group_id })
			if remote.peer_listener_error ~= nil then
				table.insert(items, { label = "Peer listener not running", detail = tostring(remote.peer_listener_error) .. " · reopen Share in USAGE Setup or choose Standalone" })
			end
			table.insert(items, { label = "Last service error", detail = tostring(remote.last_error or "None") })
		end
		fresh:pick({ placeholder = "USAGE Diagnostics", icon = "gauge", items = items }):next(function(item, _error, latest)
			if request_generation ~= diagnostics_generation or latest == nil or item == nil then return end
			if item.action == "setup" then setup:open(latest)
			elseif item.action == "summary" then setup:show_summary(latest) end
		end)
	end
	companion.request("diagnostics", {}, function(remote, err, fresh)
		if request_generation ~= diagnostics_generation then return end
		show(fresh, remote, err)
	end)
end
tern.chrome.status(function(_pane: StatusPaneInfo) return status_segments end)
tern.command({ id = "refresh", title = "USAGE Refresh", icon = "gauge", group = "USAGE", run = function(_cx)
	refresh:refresh(function(problem, fresh)
		if problem ~= nil and fresh ~= nil then fresh:toast("error", "USAGE refresh failed", problem) end
	end)
end })
tern.command({ id = "details", title = "USAGE Details", icon = "gauge", group = "USAGE", run = details })
tern.files.button({ id = "usage", title = "USAGE", icon = "gauge", run = function(_files, cx) details(cx) end })
tern.command({ id = "config", title = "USAGE Configuration", icon = "gauge", group = "USAGE", run = function(cx) layouts:config(cx) end })
local prompt_generation = 0
tern.route.link(function(link, cx)
	if link.url:sub(1, 8) ~= "usage://" then return nil end
	local origin = nil
	for _, pane in cx.session:panes() do if pane.pane == link.pane then origin = pane; break end end
	if origin == nil or (origin.block ~= BLOCK and origin.block ~= "usage.account" and origin.block ~= "usage.config") then
		return { handled = true }
	end
	local encoded = link.url:match("^usage://account/(.+)$")
	if encoded ~= nil then
		local account = view_layout.decode(encoded)
		if account ~= nil then layouts:account(cx, link.pane, account) end
	elseif link.url == "usage://config" then layouts:config(cx, link.pane)
	elseif origin.block == "usage.config" then
		local mode = link.url:match("^usage://layout/(%a+)$")
		local interval = link.url:match("^usage://interval/(%d+)$")
		if link.url == "usage://config/close" then
			cx.layout:close(link.pane)
		elseif mode ~= nil then
			layouts:show(cx, mode, link.pane)
		elseif interval ~= nil then
			prompt_generation += 1
			cx.session:event(link.pane, { ev = "action", act = "interval", value = interval })
		elseif link.url == "usage://interval/custom" then
			prompt_generation += 1
			local request = prompt_generation
			cx:prompt({ placeholder = "Refresh interval: whole seconds, 60–86400", icon = "gauge" }):next(function(value, err, fresh)
				if request ~= prompt_generation or value == nil or fresh == nil then return end
				local present = false
				for _, pane in fresh.session:panes() do
					if pane.pane == link.pane and pane.block == "usage.config" then present = true; break end
				end
				if not present then return end
				local seconds = if value:match("^%d+$") then tonumber(value) else nil
				if err ~= nil or seconds == nil or seconds < 60 or seconds > 86400 then
					fresh.session:event(link.pane, { ev = "action", act = "config_error", value = "Enter whole seconds from 60 to 86400." })
					return
				end
				fresh.session:event(link.pane, { ev = "action", act = "interval", value = tostring(seconds) })
			end)
		end
	end
	return { handled = true }
end)
tern.command({ id = "diagnostics", title = "USAGE Diagnostics", icon = "gauge", group = "USAGE", run = diagnostics })
tern.command({ id = "setup", title = "USAGE Setup", icon = "gauge", group = "USAGE", run = function(cx) setup:open(cx) end })
tern.command({ id = "show_summary", title = "USAGE Show Summary", icon = "gauge", group = "USAGE", run = function(cx) if cx ~= nil then setup:show_summary(cx) end end })
tern.on("window_start", function(cx) poll(cx) end)
render()
schedule(0)
