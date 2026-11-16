--!strict
-- Each window reads its local companion; source hosts collect without any block.
-- Unload releases this VM's lease; expiry covers unload/callback loss.
local companion = require("./companion")
local aggregate = require("./aggregate").new()
local view_layout = require("./view_layout")
local layouts = view_layout.new()
local refresh: any
local presentation = require("./presentation")
local setup_module = require("./setup")
local status_prefs = require("./status_preferences")
local status_settings = require("./status_settings")
local status_prompt = require("./status/status_prompt")
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
local unloaded = false
-- The status-bar choice (kv record, shared with the host half and other windows) and the
-- account ids behind the account segments as last drawn: a click resolves its slot here.
local kv_env = {
	get = function(key: string): any return tern.kv.get(key) end,
	set = function(key: string, value: any) tern.kv.set(key, value) end,
	exists = function(path: string): boolean return tern.fs.exists(path) end,
	data = tern.plugin.data,
}
-- Decided here, before any poll can create companion data, so fresh and retained installs differ.
local prefs: any = status_prefs.load(kv_env)
local rendered_ids: { string } = {}
local pushed: { [number]: string } = {}

-- Reads the shared record, and completes a pending migration once the roster has answered.
-- Not for formatters: it touches kv.
local function sync_prefs(model: any)
	prefs = status_prefs.load(kv_env)
	if not prefs.migration_complete and phase == "ready" then
		local ids: { string } = {}
		for _, account in presentation.ordered_accounts(model.accounts) do table.insert(ids, account.id) end
		local settled = status_prefs.complete_migration(prefs, ids)
		if status_prefs.save(kv_env, settled) then prefs = settled end
	end
end

local function render()
	if unloaded then return end
	local model = aggregate:project(math.floor(os.time() * 1000))
	local hold = setup_module.platform_hold()
	sync_prefs(model)
	-- Until the companion has answered, an empty model says nothing about SPAWN.
	local known = hold == nil and (#model.accounts > 0 or phase == "ready")
	status_segments, rendered_ids = presentation.segments(model, if known then prefs else nil)
	-- A hold or a missing setup is actionable and always shown; the rest only when the owner
	-- turned the usage statistics on, so the default bar stays a lone launcher.
	if hold ~= nil then
		table.insert(status_segments, { text = "USAGE hold · " .. hold, icon = "gauge", tone = "warning", command = DIAGNOSTICS })
	elseif phase == "setup_required" then
		table.insert(status_segments, { text = "USAGE setup required", icon = "gauge", tone = "muted", command = DIAGNOSTICS })
	elseif prefs.enabled then
		if phase ~= "ready" then
			table.insert(status_segments, { text = if phase == "loading" then "USAGE loading" else "USAGE unavailable · last known",
				icon = "gauge", tone = "muted", command = DIAGNOSTICS })
		elseif aggregate.diagnostics ~= nil and (aggregate.diagnostics.stale_sources or 0) > 0 then
			table.insert(status_segments, { text = "USAGE partial · " .. tostring(aggregate.diagnostics.stale_sources) .. " sources not current",
				icon = "gauge", tone = "muted", command = DIAGNOSTICS })
		end
		if refresh ~= nil and (refresh.requesting or refresh.problem ~= nil or (refresh.progress and refresh.progress.state == "running")) then
			table.insert(status_segments, { text = refresh:text(), icon = "gauge", tone = "muted", command = DETAILS })
		end
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
local details: (any?) -> ()

-- Sends the status-bar section's state to every open configuration block of this session
-- (`force` also re-sends an unchanged state, for a block that has just asked).
local function push_status(cx: any?, force: boolean?)
	if cx == nil or unloaded then return end
	local targets = {}
	for _, pane in cx.session:panes() do
		if pane.block == "usage.config" then table.insert(targets, pane.pane) end
	end
	if #targets == 0 then return end
	local encoded = tern.json.encode(status_settings.snapshot(prefs, aggregate:project(math.floor(os.time() * 1000))))
	for _, id in targets do
		if force == true or pushed[id] ~= encoded then
			pushed[id] = encoded
			cx.session:event(id, { ev = "action", act = status_settings.ACTION, value = encoded })
		end
	end
end

-- A configuration block asked to change the status bar. The roster is read now, so a stale
-- checkbox for a removed or changed account is refused; nothing here reads a provider.
local function status_link(cx: any, request: any)
	if request.kind == "sync" then push_status(cx, true); return end
	local now = math.floor(os.time() * 1000)
	local model = aggregate:project(now)
	sync_prefs(model)
	if request.kind == "master" then
		local changed = status_prefs.with_enabled(prefs, request.on)
		if status_prefs.save(kv_env, changed) then prefs = changed else cx:toast("error", "USAGE status bar choice was not saved", "Tern's plugin store is unavailable. Try again.") end
	elseif not prefs.migration_complete then
		cx:toast("info", "USAGE is still loading accounts", "Your earlier status bar choice carries over once the account list arrives.")
	elseif not prefs.enabled then
		cx:toast("info", "Usage statistics are off", "Turn them on first; your selection is kept while they are off.")
	else
		local changed, why = status_prefs.with_selected(prefs, request.id, request.on, status_prefs.roster_map(model.accounts))
		if changed == nil then
			cx:toast("info", if why == "selection_full" then "Status bar selection is full" else "That account is no longer in SPAWN",
				if why == "selection_full" then "Untick another account first." else "The list below shows the current accounts.")
		elseif status_prefs.save(kv_env, changed) then prefs = changed
		else cx:toast("error", "USAGE status bar choice was not saved", "Tern's plugin store is unavailable. Try again.") end
	end
	render()
	push_status(cx, true)
end

-- A status-bar account segment: resolve its slot against the roster now, then show that account.
local function open_status_account(cx: any?, slot: number)
	if cx == nil then return end
	local id = rendered_ids[slot]
	local row = nil
	if id ~= nil then
		for _, candidate in aggregate:project(math.floor(os.time() * 1000)).accounts do
			if candidate.id == id then row = candidate; break end
		end
	end
	if row == nil then
		if id ~= nil then cx:toast("info", "That account is no longer in SPAWN", "USAGE shows the current accounts.") end
		details(cx)
		return
	end
	if not layouts:focus_account(cx, row.id) then details(cx) end
end
local setup = setup_module.new(function(cx) poll(cx) end, function(cx) layouts:config(cx) end)
local function schedule(delay: number)
	if timer ~= nil then timer:cancel() end
	if unloaded then return end
	timer = tern.timer(delay, function(cx)
		timer = nil
		poll(cx)
	end)
end
poll = function(cx: any?)
	if unloaded then return end
	if inflight then return end
	if cx == nil then schedule(250); return end
	if window == nil then
		window = cx:window_key()
		companion.set_client("window:" .. (window :: string), "window")
	end
	if timer ~= nil then timer:cancel(); timer = nil end
	inflight = true
	local function finished()
		if unloaded then return end
		inflight = false
		render()
		schedule(POLL_MS)
	end
	local function display()
		aggregate:refresh(function(ok, err, fresh)
			if unloaded then return end
			if ok then phase, problem = "ready", nil else set_problem(err) end
			finished()
			if ok then refresh:poll() end
			push_status(fresh, false)
		end)
	end
	if not ready then
		companion.ensure(function(value, err)
			if unloaded then return end
			if value == nil then set_problem(err); finished(); return end
			ready = true
			display()
		end)
	else
		companion.renew(function(value, err)
			if unloaded then return end
			if value == nil then ready = false; set_problem(err); finished(); return end
			display()
		end)
	end
end
details = function(cx: any?)
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
		local items = {}
		for _, item in setup_module.diagnostic_items() do table.insert(items, item) end
		table.insert(items, { label = "Companion: " .. phase, detail = if problem ~= nil then problem.message elseif setup_module.platform_hold() ~= nil then "Companion process state only; this is not platform qualification or healthy usage evidence." else "Original observation times retained; missing quotas are not zero." })
		table.insert(items, { label = refresh:text(), detail = "The companion runs headless usage reads. No owner-pane input or synthetic turns." })
		table.insert(items, { label = if hidden then "Status bar off" elseif prefs.enabled then "Usage statistics in status bar: on" else "Usage statistics in status bar: off",
			detail = "Choose which accounts show in USAGE Configuration. USAGE never turns Tern's status bar on by itself; it asks once.", action = "status" })
		table.insert(items, { label = "Open USAGE Setup", detail = "Runtime, pairing, export and headless-read permission. Accounts come from SPAWN.", action = "setup" })
		if refresh.progress ~= nil then
			for _, failure in refresh.progress.failures or {} do
				if type(failure.code) == "string" then
					for _, item in setup_module.failure_diagnostics(failure.account, failure.code) do table.insert(items, item) end
				end
			end
		end
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
			elseif item.action == "status" then layouts:config(latest) end
		end)
	end
	companion.request("diagnostics", {}, function(remote, err, fresh)
		if request_generation ~= diagnostics_generation then return end
		show(fresh, remote, err)
	end)
end
tern.chrome.status(function(_pane: StatusPaneInfo) return status_segments end)
-- In a window attached to a remote host, that host is the source: its own USAGE block runs the
-- refresh (host.luau `refresh` action). Refresh never opens a pane for this.
local HOST_BLOCKS = { ["usage.accounts"] = true, ["usage.account"] = true, ["usage.config"] = true }
local function host_refresh(cx: any, host: string)
	local title = "USAGE refresh on host " .. host
	for _, pane in cx.session:panes() do
		if HOST_BLOCKS[pane.block] then
			cx.session:event(pane.pane, { ev = "action", act = "refresh" })
			cx:toast("info", title, "Requested through the host's USAGE pane; its progress shows there.")
			return
		end
	end
	cx:toast("error", title, "No USAGE pane is open in this session. Open USAGE Details, then Refresh; the host refreshes through it.")
end
tern.command({ id = "refresh", title = "USAGE Refresh", icon = "gauge", group = "USAGE", run = function(cx)
	local host = setup_module.attached(cx)
	if host ~= nil then host_refresh(cx, host); return end
	refresh:refresh(function(problem, fresh)
		if problem ~= nil and fresh ~= nil then fresh:toast("error", "USAGE refresh failed", problem) end
	end)
end })
tern.command({ id = "details", title = "USAGE Details", icon = "gauge", group = "USAGE", run = details })
-- Palette fallback for the status bar's account segments: one command per slot, listed only while its segment is drawn.
for slot = 1, presentation.MAX_ACCOUNT_SEGMENTS do
	tern.command({ id = "status_account_" .. tostring(slot), title = "USAGE Account " .. tostring(slot), icon = "gauge", group = "USAGE",
		available = function(_cx: any) return rendered_ids[slot] ~= nil end,
		run = function(cx) open_status_account(cx, slot) end })
end
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
		local status = link.url:match("^usage://status/(.+)$")
		local change = if status ~= nil then status_settings.parse_link(status, view_layout.decode) else nil
		local mode = link.url:match("^usage://layout/(%a+)$")
		local interval = link.url:match("^usage://interval/(%d+)$")
		if status ~= nil then
			if change ~= nil then status_link(cx, change) end
		elseif link.url == "usage://config/close" then
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
tern.command({ id = "status_settings", title = "USAGE Status Bar Settings", icon = "gauge", group = "USAGE", run = function(cx) layouts:config(cx) end })
local function unload(_cx: any)
	unloaded = true
	diagnostics_generation += 1
	prompt_generation += 1
	if timer ~= nil then timer:cancel(); timer = nil end
	companion.unload()
end
-- First start path: the shared prompt asks once per install whether to turn on the status bar.
tern.on("window_start", function(cx)
	status_prompt.ensure(cx, "usage")
	poll(cx)
end)
render()
schedule(0)

require("./updater/window").register({ name = "USAGE", dir = "USAGE", title_prefix = "USAGE " })

companion.on_unload(unload)
