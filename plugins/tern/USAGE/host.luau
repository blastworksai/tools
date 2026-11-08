--!strict
-- USAGE blocks, rendered by the host from its own authenticated companion.
local ui = tern.ui
local aggregate = require("./aggregate").new()
local collector = require("./source_collect")
local host_setup = require("./host_setup")
local presentation = require("./presentation")
local view_layout = require("./view_layout")
local refresh: any
type UsageWindow = any
type Account = any

local POLL_MS = 15000
-- While a refresh runs only its status is polled. Display data changes only
-- when the collector publishes, a refresh completes, or the idle poll runs.
local STATUS_MS = 1000
local RENDER_MS = 1000

type BlockState = {
	kind: string,
	mode: string,
	account: string?,
	problem: string?,
	-- Config blocks only: host-run Setup for attached windows.
	setup: any?,
}

local blocks: { [number]: { cx: BlockCx, state: BlockState } } = {}
local model: any? = nil
local problem: string? = nil
local loading = true
-- True while the latest display read succeeded: only then is an empty model an empty SPAWN roster.
local answered = false
local expiry_at_ms: number? = nil
local poll_timer: TimerHandle? = nil
local render_timer: TimerHandle? = nil
local poll_generation = 0
local render_generation = 0

local WINDOW_LABELS: { [string]: string } = {
	five_hour = "5 hours",
	seven_day = "7 days",
	window = "Window",
	monthly_code = "Monthly code",
}

local REASONS: { [string]: string } = {
	not_reported = "not reported",
	unparsed = "could not parse",
	unavailable = "unavailable",
	server_sent_no_usage = "provider sent no usage",
	source_unreachable = "source unreachable",
	not_yet_measured = "not measured yet",
	reset_passed = "reset passed",
	stale = "stale reading",
	web_login_expired = "provider login expired; open the provider's CLI once to renew it",
	local_login_unavailable = "usage credentials unavailable on source",
	source_metadata_disabled = "headless usage reads are off (USAGE Setup)",
	vendor_usage_unavailable = "provider usage endpoint unavailable",
	source_timeout = "usage read timed out",
	source_usage_unavailable = "usage source could not read this account",
	source_context_ambiguous = "account context could not be verified",
	source_profile_invalid = "account profile invalid",
	source_profile_unavailable = "account profile unavailable or signed out",
	source_remote = "runs on another machine over SSH; USAGE reads it only on that machine",
	api_key_login = "signed in with an API key; no subscription quota",
	web_login_forbidden = "provider refused usage access; sign in again with the provider's CLI",
}

-- collector.state() codes: why the latest source publication did not land.
local COLLECTOR: { [string]: string } = {
	companion_unavailable = "local companion unavailable",
	host_lease_unavailable = "could not register with the local companion",
	source_usage_unavailable = "could not read refresh results",
	source_snapshot_rejected = "refresh results were rejected",
	source_publication_failed = "could not publish refresh results",
}

local USAGE_SOURCES: { [string]: string } = {
	headless = "headless read",
	["last-good"] = "last good read",
	SPAWN = "defined in SPAWN, not measured",
}

-- Drops blocks whose panes are gone; true while any USAGE block is open.
local function prune(): boolean
	local live: { [number]: boolean } = {}
	for _, pane in tern.pane.list() do
		live[pane.pane] = true
	end
	for pane in blocks do
		if not live[pane] then blocks[pane] = nil end
	end
	return next(blocks) ~= nil
end

local function cancel_poll()
	poll_generation += 1
	if poll_timer ~= nil then
		(poll_timer :: TimerHandle):cancel()
		poll_timer = nil
	end
end

local function cancel_render()
	render_generation += 1
	if render_timer ~= nil then
		(render_timer :: TimerHandle):cancel()
		render_timer = nil
	end
end

local function render_all()
	prune()
	for _, block in blocks do
		block.cx:render()
	end
end

local function wall_now(): number
	return math.floor(os.time() * 1000)
end

local function percent_text(value: number): string
	return tostring(math.floor(value + 0.5)) .. "%"
end

local function title_key(key: string): string
	local words: { string } = {}
	for word in string.gmatch(key, "[^_]+") do
		table.insert(words, string.upper(string.sub(word, 1, 1)) .. string.sub(word, 2))
	end
	return table.concat(words, " ")
end

local function reason_text(code: string): string
	return REASONS[code] or title_key(code)
end

-- A failed login warns; every other unavailable/last-known cause stays muted.
local function reason_span(code: string, prefix: string?): any
	return ui.span((prefix or "") .. reason_text(code), if presentation.LOGIN_REASONS[code] ~= nil then "warning" else "muted")
end

local POOL_LABELS: { [string]: string } = {
	claude_gpt = "GPT / Claude",
	gemini = "Gemini",
}

local function pool_label(pool: string): string
	if POOL_LABELS[pool] ~= nil then return POOL_LABELS[pool] end
	if pool:sub(1, 1) == "{" then
		local ok, scope = pcall(tern.json.decode, pool)
		if ok and type(scope) == "table" then
			local model_name = scope.model
			if type(model_name) == "table" then model_name = model_name.display_name or model_name.displayName or model_name.id end
			local label = if type(model_name) == "string" then model_name else nil
			if type(scope.surface) == "string" then label = if label ~= nil then label .. " / " .. scope.surface else scope.surface end
			return label or "Scoped allowance"
		end
	end
	return title_key(pool)
end

local function window_name(window: UsageWindow): string
	local label = WINDOW_LABELS[window.key] or title_key(window.key)
	if window.pool ~= "default" then
		label ..= " · " .. pool_label(window.pool)
	end
	return label
end

local function collector_text(): string?
	local health = collector.state()
	if health == nil then return nil end
	-- The display problem already says the companion is unavailable.
	if health.code == "companion_unavailable" and problem ~= nil then return nil end
	local retained = model ~= nil and #(model :: any).accounts > 0
	return "Source collection: " .. (COLLECTOR[health.code] or title_key(health.code)) .. (if retained then "; last readings retained." else ".")
end

local function append_problems(children: { Node })
	if problem ~= nil then table.insert(children, ui.text(ui.span(problem, "error"))) end
	local health = collector_text()
	if health ~= nil then table.insert(children, ui.text(ui.span(health, "error"))) end
end

-- Text for a model without accounts: the roster is empty only if the companion said so.
local function no_accounts_text(): string?
	if answered then return presentation.EMPTY_TEXT end
	return if loading then "Loading accounts…" else nil
end

-- A detail block may name a definition merged into this row because the same
-- login is configured in another SPAWN host scope; returns the label it names.
local function selected_label(account: Account, selected: string?): string?
	if selected == nil then return nil end
	if account.id == selected then return account.account_label end
	for _, other in account.also_configured or {} do
		if other.id == selected then return other.account_label end
	end
	return nil
end

local function window_usage(window: UsageWindow, now_ms: number): string
	local state = presentation.window_state(window, now_ms)
	if state == "unavailable" then return reason_text(window.unavailable_reason or "unavailable") end
	if state ~= "fresh" then
		return "Last known " .. percent_text(window.used) .. " used"
			.. (if state == "login" then " · " .. (presentation.login_problem(window) :: string)
				elseif state == "reset_passed" then " · reset passed" elseif state == "stale" then " · stale" else "")
	end
	return percent_text(window.used) .. " used"
end

-- Text coloured along usage.css's green-to-red used gradient: Tern drops a
-- role on a bare text node, so a row carries it; spans without their own
-- style inherit the colour. A nil role returns the plain text node.
local function heat_text(spans: any, role: string?): Node
	local node = ui.text(spans)
	if role == nil then return node end
	return ui.node("row", { role = role, gap = "none" }, { node })
end

local function quota_span(text: string, style: string?): any
	return ui.span(text, style)
end

local function window_detail_node(window: UsageWindow, now_ms: number, selected: boolean, provider: string): Node
	local state = presentation.window_state(window, now_ms)
	local role = presentation.heat(window.used, state)
	local usage = if provider == "muse" and window.used == nil then presentation.MUSE_WAITING else window_usage(window, now_ms)
	local children: { Node } = {
		ui.node("row", { role = "usage-quota-heading" }, {
			ui.text(ui.span(window_name(window) .. (if selected then " · summary" else ""), "strong")),
			heat_text(quota_span(usage, presentation.text_style(state)), role),
		}),
	}
	if window.used ~= nil then
		table.insert(children, ui.meter(window.used / 100, {}))
	end
	-- Missing reset/timezone metadata is not a countdown. Keep unknown rows
	-- compact rather than repeating several unavailable lines for each source.
	if window.resets_at_ms ~= nil then
		local resets_at_ms = window.resets_at_ms :: number
		table.insert(children, ui.text(ui.span("Resets: " .. os.date("%A %d %b at %H:%M %Z", math.floor(resets_at_ms / 1000)), "muted")))
		table.insert(children, ui.text(ui.span(presentation.countdown(resets_at_ms, now_ms), "muted")))
	elseif window.reset_label ~= nil then
		table.insert(children, ui.text(ui.span(window.reset_label, "muted")))
	end
	local observed = if window.observed_at_ms > 0 then "Observed " .. presentation.elapsed(now_ms - window.observed_at_ms) .. " ago" else "Not yet observed"
	if window.reset_calendar ~= nil and window.reset_calendar.timezone ~= nil then
		observed ..= " · Source timezone: " .. window.reset_calendar.timezone
	end
	table.insert(children, ui.text(ui.span(observed, "muted")))
	local reason = window.unavailable_reason or window.last_known_reason
	if reason ~= nil then
		table.insert(children, ui.text(reason_span(reason, "Unavailable: ")))
	end
	return ui.node("col", { role = "usage-quota", gap = "xs" }, children)
end

local function account_hovercard(account: Account, now_ms: number): Node
	local value = presentation.account_projection(account, now_ms)
	local details: { Node } = {
		ui.node("row", { role = "usage-account-heading" }, {
			ui.node("icon", { name = value.icon }),
			ui.text(ui.span((account.provider_label or title_key(account.provider)) .. " · " .. account.account_label, "strong")),
			heat_text(quota_span(value.text, value.style), value.heat),
		}),
		ui.text(ui.span("Source: " .. (USAGE_SOURCES[account.usage_source] or account.usage_source)
			.. (if account.plan ~= nil then " · " .. account.plan else ""), "muted")),
	}
	if account.also_configured ~= nil and #account.also_configured > 0 then
		local labels: { string } = {}
		for _, other in account.also_configured do table.insert(labels, other.account_label) end
		table.insert(details, ui.text(ui.span("Also configured as: " .. table.concat(labels, ", "), "muted")))
	end
	if account.credit_balance ~= nil then
		table.insert(details, ui.text(ui.span("Last reported balance: " .. tostring(account.credit_balance) .. " credits remaining", "muted")))
	end
	if #account.windows == 0 then
		table.insert(details, ui.text(ui.span(if account.provider == "muse" then presentation.MUSE_WAITING else "Not measured yet", "muted")))
	else
		for _, window in account.windows do
			table.insert(details, window_detail_node(window, now_ms, window == value.window, account.provider))
		end
	end
	return ui.node("col", { role = "usage-account-card", gap = "xs" }, details)
end

local function controls(): Node
	return ui.node("row", { role = "usage-controls" }, {
		ui.text(ui.span("USAGE", "strong")),
		ui.button("Refresh", { busy = refresh.requesting, actions = { click = "refresh" }, title = "Request fresh headless provider reads" }),
		ui.text(ui.link("Configure", "usage://config")),
	})
end

local function compact_view(mode: string): Node
	local bottom = mode == "bottom"
	local children: { Node } = { controls() }
	if not bottom then table.insert(children, ui.text(ui.span(refresh:text(), "muted"))) end
	if model == nil then
		table.insert(children, ui.text(if loading then "Loading accounts…" else "No readings yet"))
	else
		local now_ms = wall_now()
		local summary = presentation.summary(model, now_ms)
		if bottom then
			local progress = if refresh.requesting or refresh.problem ~= nil or (refresh.progress ~= nil and refresh.progress.state == "running") then refresh:text() .. " · " else ""
			children[1] = ui.node("row", { role = "usage-bottom-toolbar" }, {
				controls(),
				ui.text(ui.span(progress .. summary.header .. " · OMP uses underlying subscriptions", "muted")),
			})
		else
			table.insert(children, ui.text(ui.span(summary.header, "muted")))
		end
		local rows: { Node } = {}
		for _, account in summary.accounts do
			local value = presentation.account_projection(account, now_ms)
			local reasons, seen = {}, {}
			for _, window in account.windows do
				local reason = window.unavailable_reason or window.last_known_reason
				if reason ~= nil and not seen[reason] then
					seen[reason] = true
					if #reasons > 0 then table.insert(reasons, ui.span(" · ", "muted")) end
					table.insert(reasons, reason_span(reason))
				end
			end
			local label = (account.provider_label or title_key(account.provider)) .. " · " .. account.account_label
			local link = ui.link(label, "usage://account/" .. view_layout.encode(account.id), "strong")
			local quota = quota_span(value.text, value.style)
			local countdown = presentation.compact_countdown(value, now_ms)
			local usage_node = heat_text(if countdown ~= nil then { quota, ui.span(" · " .. countdown, "muted") } else quota, value.heat)
			if bottom then
				table.insert(rows, ui.node("row", { key = account.id, role = "usage-compact-account", gap = "xs" }, {
					ui.node("icon", { name = value.icon }),
					ui.text(link),
					usage_node,
				}))
			else
				table.insert(rows, ui.node("col", { key = account.id, role = "usage-compact-account", gap = "xs" }, {
					ui.node("row", { role = "usage-account-heading", gap = "xs" }, {
						ui.node("icon", { name = value.icon }),
						ui.text(link),
					}),
					usage_node,
					ui.text(if #reasons > 0 then reasons else ui.span("", "muted")),
				}))
			end
		end
		table.insert(children, ui.node(if bottom then "row" else "col", { role = "usage-compact-list", gap = "xs" }, rows))
		if #rows == 0 then
			local empty = no_accounts_text()
			if empty ~= nil then table.insert(children, ui.text(ui.span(empty, "muted"))) end
		end
		if not bottom then table.insert(children, ui.text(ui.span("OMP uses underlying subscriptions; no separate allowance.", "muted"))) end
	end
	append_problems(children)
	return ui.node("col", { role = "usage-" .. mode .. "-root", gap = "xs" }, children)
end

local function details_view(selected: string?): Node
	if model == nil then
		local children: { Node } = { ui.text(if loading then "USAGE loading" else "No usage readings yet.") }
		append_problems(children)
		return ui.col(children)
	end
	local now_ms = wall_now()
	local summary = presentation.summary(model, now_ms)
	local ordered = summary.accounts
	local children: { Node } = {}
	if selected == nil then
		table.insert(children, controls())
		table.insert(children, ui.text(ui.span(refresh:text(), "muted")))
		table.insert(children, ui.text(ui.span(summary.header, "muted")))
	end
	if selected == nil and summary.current_count == 0 and #ordered > 0 then
		table.insert(children, ui.text(ui.span("No current measured quota. Unmeasured is not zero; last-known readings stay labelled.", "muted")))
	end
	append_problems(children)
	local found = false
	for _, account in ordered do
		if selected == nil or selected_label(account, selected) ~= nil then
			found = true
			table.insert(children, account_hovercard(account, now_ms))
		end
	end
	if selected ~= nil and not found and answered then table.insert(children, ui.text("This account is no longer defined in SPAWN.")) end
	if #ordered == 0 then
		local empty = no_accounts_text()
		if empty ~= nil then table.insert(children, ui.text(ui.span(empty, "muted"))) end
	end
	if selected == nil and model.consumers ~= nil and #model.consumers > 0 then
		local consumers: { Node } = { ui.text(ui.span("OMP · subscription users (not quotas)", "strong")) }
		for _, consumer in model.consumers do
			table.insert(consumers, ui.text(ui.span(presentation.consumer_text(consumer), "muted")))
		end
		table.insert(children, ui.node("col", { role = "usage-consumers", gap = "xs" }, consumers))
	end
	return ui.node("col", { role = "usage-details-root", gap = "sm" }, children)
end

local function config_view(state: BlockState): Node
	local preferences = refresh.preferences
	local interval = if preferences ~= nil then preferences.refresh_interval_seconds else nil
	local children: { Node } = {
		ui.node("row", { role = "usage-config-heading" }, {
			ui.text(ui.span("USAGE Configuration", "strong")),
			ui.button("", { icon = "x", title = "Close configuration", aria = "Close configuration", size = "sm", actions = { click = "close_config" } }),
		}),
		ui.node("row", { role = "usage-config-options" }, { ui.text("Layout:"), ui.text(ui.link("Narrow", "usage://layout/narrow")), ui.text(ui.link("Wide", "usage://layout/wide")), ui.text(ui.link("Bottom", "usage://layout/bottom")) }),
		ui.text(if refresh.saving then "Saving refresh interval…" elseif interval == nil then "Loading refresh interval…" elseif interval == 0 then "Refresh: Manual only" else "Refresh: every " .. tostring(interval) .. " seconds"),
		ui.node("row", { role = "usage-config-options" }, { ui.text(ui.link("Manual", "usage://interval/0")), ui.text(ui.link("1 min", "usage://interval/60")), ui.text(ui.link("5 min", "usage://interval/300")), ui.text(ui.link("15 min", "usage://interval/900")), ui.text(ui.link("Custom…", "usage://interval/custom")) }),
		ui.text(ui.span("Refresh schedule is shared with the source. Layout choice is saved here.", "muted")),
		ui.text(ui.span(refresh:text(), "muted")),
		ui.button("Refresh now", { busy = refresh.requesting, actions = { click = "refresh" } }),
	}
	if refresh.progress ~= nil then
		for _, failure in refresh.progress.failures or {} do
			table.insert(children, ui.text(ui.span((failure.account or "Source") .. ": " .. reason_text(failure.code), "muted")))
		end
	end
	append_problems(children)
	if refresh.preference_problem ~= nil then table.insert(children, ui.text(ui.span(refresh.preference_problem, "error"))) end
	if state.problem ~= nil then table.insert(children, ui.text(ui.span(state.problem, "error"))) end
	if state.setup ~= nil then table.insert(children, host_setup.view(state.setup)) end
	return ui.node("col", { role = "usage-config-root", gap = "sm" }, children)
end

local function main_view(state: BlockState): Node
	if state.mode == "narrow" or state.mode == "bottom" then return compact_view(state.mode) end
	return details_view(state.account)
end

local fetch: () -> ()

local function rebuild_snapshot()
	model = aggregate:project(wall_now())
	expiry_at_ms = (model :: any).freshness.next_change_at_ms
	render_all()
end

-- Every accounts/account block shows a countdown (compact rows for their
-- selected window, cards for each window) while any reset is still ahead.
local function countdown_needed(): boolean
	if model == nil then return false end
	local shown = false
	for _, block in blocks do
		if block.state.kind ~= "config" then shown = true; break end
	end
	if not shown then return false end
	local now_ms = wall_now()
	for _, account in (model :: any).accounts do
		for _, window in account.windows do
			if window.resets_at_ms ~= nil and window.resets_at_ms > now_ms then return true end
		end
	end
	return false
end

-- Ticks re-render the cached model only; countdowns never request providers.
local function arm_render()
	if render_timer ~= nil or not prune() or not countdown_needed() then return end
	local generation = render_generation
	render_timer = tern.timer(RENDER_MS, function(_cx: WindowCx?)
		if generation ~= render_generation then return end
		render_timer = nil
		if expiry_at_ms ~= nil and wall_now() >= (expiry_at_ms :: number) then rebuild_snapshot() else render_all() end
		arm_render()
	end)
end

-- Idle while no USAGE block is open: the collector publishes on its own and
-- source_updated reads the display again.
local function rearm_poll()
	cancel_poll()
	if not prune() then return end
	local running = refresh.requesting or (refresh.progress ~= nil and refresh.progress.state == "running")
	local generation = poll_generation
	poll_timer = tern.timer(if running then STATUS_MS else POLL_MS, function(_cx: WindowCx?)
		if generation ~= poll_generation then return end
		poll_timer = nil
		if running then refresh:poll() else fetch() end
	end)
end

local completed_at: number? = nil
refresh = require("./view_state").new(function()
	render_all()
	rearm_poll()
	if refresh.progress == nil then return end
	local completed = refresh.progress.last_completed_ms or 0
	if completed == completed_at then return end
	local first = completed_at == nil
	completed_at = completed
	-- A finished refresh changes what the source publishes and what a hub
	-- displays; the first status seen is only the baseline.
	if not first then
		collector.flush()
		fetch()
	end
end)

local function source_updated() fetch() end
fetch = function()
	if aggregate.busy then return end
	cancel_poll()
	loading = true
	refresh:poll()
	for _, block in blocks do
		if block.state.kind == "config" then refresh:read_preferences(); break end
	end
	aggregate:refresh(function(ok, err)
		loading = false
		answered = ok
		problem = if ok then nil else (if err ~= nil then err.message else "USAGE unavailable; last readings retained.")
		if ok and aggregate.diagnostics ~= nil then
			if aggregate.diagnostics.role == "member" then collector.stop()
			elseif aggregate.diagnostics.role == "hub" or aggregate.diagnostics.role == "standalone" then
				collector.start(source_updated)
			end
		end
		rebuild_snapshot()
		rearm_poll()
		arm_render()
	end)
end

local function on_key(key: Key): boolean?
	if key.ctrl or key.alt or key.meta then
		return false
	end
	if key.name ~= "r" and key.text ~= "r" then
		return false
	end
	refresh:refresh()
	return true
end

local function on_event(event: UiEvent, state: BlockState, cx: BlockCx)
	if event.ev ~= "action" then return end
	if event.act == host_setup.ACTION then
		-- A completed host change is picked up by this host's collector and display at once.
		if state.setup ~= nil then host_setup.event(state.setup, event, cx, function() collector.flush(); fetch() end) end
		return
	end
	if event.act == "close_config" and state.kind == "config" then
		cx:open("usage://config/close")
		return
	end
	if event.act == "refresh" then refresh:refresh()
	elseif event.act == "interval" and type(event.value) == "string" then
		local seconds = tonumber(event.value)
		if seconds ~= nil then state.problem = nil; refresh:set_interval(seconds) end
	elseif event.act == "config_error" or event.act == "pip_error" then state.problem = tostring(event.value)
	end
	cx:render()
end

local function definition(kind: string): BlockDef<BlockState>
	return {
		font = "sans",
		init = function(cx: BlockCx, args: { string }, saved: any): BlockState
			local mode = if args[1] == "wide" or args[1] == "bottom" then args[1] else "narrow"
			local account = if kind == "account" then args[1] else nil
			if type(saved) == "table" then
				if saved.mode == "narrow" or saved.mode == "wide" or saved.mode == "bottom" then mode = saved.mode end
				if kind == "account" and type(saved.account) == "string" then account = saved.account end
			end
			if kind ~= "accounts" then mode = kind end
			local state: BlockState = { kind = kind, mode = mode, account = account, setup = if kind == "config" then host_setup.new() else nil }
			blocks[cx.pane] = { cx = cx, state = state }
			if kind == "config" then refresh:read_preferences() end
			fetch()
			arm_render()
			return state
		end,
		title = function(state: BlockState): string?
			if kind == "config" then return "USAGE Configuration" end
			if kind == "account" then
				for _, account in (if model ~= nil then model.accounts else {}) do
					local label = selected_label(account, state.account)
					if label ~= nil then return "USAGE · " .. (account.provider_label or title_key(account.provider)) .. " · " .. label end
				end
				return "USAGE Account"
			end
			return "USAGE"
		end,
		view = function(state: BlockState, _cx: BlockCx): BlockView
			local main = if kind == "config" then config_view(state) else main_view(state)
			if kind ~= "config" and state.problem ~= nil then main = ui.col({ ui.text(ui.span(state.problem, "error")), main }) end
			return { main = main, dock = nil }
		end,
		key = function(_state: BlockState, key: Key, _cx: BlockCx): boolean? return on_key(key) end,
		event = function(state: BlockState, event: UiEvent, cx: BlockCx) on_event(event, state, cx) end,
		save = function(state: BlockState): any return { mode = state.mode, account = state.account } end,
	}
end

tern.block.define("accounts", definition("accounts"))
tern.block.define("account", definition("account"))
tern.block.define("config", definition("config"))
require("./capacity").install()

tern.on("pane_exited", function(event: PaneExitedEvent)
	blocks[event.pane] = nil
	if not prune() then
		cancel_poll()
		cancel_render()
	end
end)

-- The collector runs even when no USAGE block or desktop window is open.
collector.start(source_updated)
fetch()
