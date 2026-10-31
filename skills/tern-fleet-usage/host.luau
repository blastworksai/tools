--!strict
-- Read-only Agent Usage Block. The window half queries active Tern agents;
-- this plugin never opens provider credentials or contacts a provider.

local ui = tern.ui
local el = ui.el

local POLL_MS = 300000
local RENDER_MS = 60000

type UsageWindow = {
	key: string,
	pool: string,
	used: number?,
	remaining: number?,
	resets_at_ms: number?,
	observed_at_ms: number,
	unavailable_reason: string?,
}

type Account = {
	id: string,
	provider: string,
	provider_label: string,
	account_label: string,
	plan: string?,
	usage_source: string,
	last_reading_at_ms: number?,
	windows: { UsageWindow },
}
type ProviderGroup = {
	key: string,
	label: string,
	accounts: { Account },
}

type Snapshot = {
	version: number,
	as_of_ms: number,
	accounts: { Account },
}

type BlockState = {
	pane: number,
}

type SharedState = {
	snapshot: Snapshot?,
	snapshot_mono_ms: number?,
	last_success_wall_ms: number?,
	problem: string?,
	loading: boolean,
	poll_timer: TimerHandle?,
	render_timer: TimerHandle?,
	open_blocks: { [number]: BlockCx },
}

local shared: SharedState = {
	snapshot = nil,
	snapshot_mono_ms = nil,
	last_success_wall_ms = nil,
	problem = nil,
	loading = false,
	poll_timer = nil,
	render_timer = nil,
	open_blocks = {},
}

local WINDOW_LABELS: { [string]: string } = {
	five_hour = "5 hours",
	seven_day = "7 days",
	weekly = "Weekly",
	window = "Window",
	monthly_code = "Monthly code",
	nimbus_quill = "Nimbus / Quill",
}

local REASONS: { [string]: string } = {
	not_reported = "not reported",
	unparsed = "could not parse",
	source_unreachable = "source unreachable",
	not_yet_measured = "not measured yet",
	reset_passed = "reset passed",
	stale = "stale reading",
	web_login_expired = "web login expired",
}

local function finite(value: any): boolean
	return type(value) == "number" and value == value and value ~= math.huge and value ~= -math.huge
end

local function percent(value: any): boolean
	return finite(value) and value >= 0 and value <= 100
end

local function array_count(value: any): number?
	if type(value) ~= "table" then
		return nil
	end
	local count = 0
	for key, _ in value do
		if type(key) ~= "number" or key < 1 or key % 1 ~= 0 then
			return nil
		end
		count += 1
	end
	for index = 1, count do
		if value[index] == nil then
			return nil
		end
	end
	return count
end

local function optional_number(value: any): number?
	if value == nil then
		return nil
	end
	if not finite(value) then
		return nil
	end
	return value
end

local function decode_window(raw: any): UsageWindow?
	if type(raw) ~= "table" or type(raw.key) ~= "string" or raw.key == "" or type(raw.pool) ~= "string" or raw.pool == "" then
		return nil
	end
	if not finite(raw.observed_at_ms) then
		return nil
	end
	local resets_at_ms = optional_number(raw.resets_at_ms)
	if raw.resets_at_ms ~= nil and resets_at_ms == nil then
		return nil
	end
	local reason: string? = nil
	if raw.unavailable_reason ~= nil then
		if type(raw.unavailable_reason) ~= "string" or raw.unavailable_reason == "" then
			return nil
		end
		reason = raw.unavailable_reason
	end
	local used = raw.used
	local remaining = raw.remaining
	if reason ~= nil then
		if used ~= nil or remaining ~= nil then
			return nil
		end
	else
		if not percent(used) or not percent(remaining) then
			return nil
		end
		if math.abs(remaining - (100 - used)) > 0.000001 then
			return nil
		end
	end
	return {
		key = raw.key,
		pool = raw.pool,
		used = used,
		remaining = remaining,
		resets_at_ms = resets_at_ms,
		observed_at_ms = raw.observed_at_ms,
		unavailable_reason = reason,
	}
end

local function decode_account(raw: any): Account?
	if type(raw) ~= "table" then
		return nil
	end
	if type(raw.id) ~= "string" or raw.id == "" or type(raw.provider) ~= "string" or raw.provider == "" then
		return nil
	end
	if type(raw.provider_label) ~= "string" or raw.provider_label == "" or type(raw.account_label) ~= "string" or raw.account_label == "" then
		return nil
	end
	if type(raw.usage_source) ~= "string" or raw.usage_source == "" then
		return nil
	end
	local plan: string? = nil
	if raw.plan ~= nil then
		if type(raw.plan) ~= "string" or raw.plan == "" then
			return nil
		end
		plan = raw.plan
	end
	local last_reading_at_ms = optional_number(raw.last_reading_at_ms)
	if raw.last_reading_at_ms ~= nil and last_reading_at_ms == nil then
		return nil
	end
	local window_count = array_count(raw.windows)
	if window_count == nil then
		return nil
	end
	local windows: { UsageWindow } = {}
	for index = 1, window_count do
		local raw_window = raw.windows[index]
		local ignored_claude_window = type(raw_window) == "table"
			and raw.provider == "claude"
			and (raw_window.key == "iguana_necktie" or raw_window.key == "nimbus_quill")
		if not ignored_claude_window then
			local window = decode_window(raw_window)
			if window == nil then
				return nil
			end
			table.insert(windows, window)
		end
	end
	return {
		id = raw.id,
		provider = raw.provider,
		provider_label = raw.provider_label,
		account_label = raw.account_label,
		plan = plan,
		usage_source = raw.usage_source,
		last_reading_at_ms = last_reading_at_ms,
		windows = windows,
	}
end

local function decode(text: string): Snapshot?
	local ok, value = pcall(tern.json.decode, text)
	if not ok or type(value) ~= "table" or value.version ~= 1 or not finite(value.as_of_ms) then
		return nil
	end
	local account_count = array_count(value.accounts)
	if account_count == nil then
		return nil
	end
	local accounts: { Account } = {}
	for index = 1, account_count do
		local account = decode_account(value.accounts[index])
		if account == nil then
			return nil
		end
		table.insert(accounts, account)
	end
	return {
		version = 1,
		as_of_ms = value.as_of_ms,
		accounts = accounts,
	}
end

local function live_panes(): { [number]: boolean }
	local live: { [number]: boolean } = {}
	for _, pane in tern.pane.list() do
		live[pane.pane] = true
	end
	return live
end

local function choose_live(live: { [number]: boolean }): number?
	for pane, _ in shared.open_blocks do
		if live[pane] then
			return pane
		end
		shared.open_blocks[pane] = nil
	end
	return nil
end

local function cancel_poll()
	if shared.poll_timer ~= nil then
		(shared.poll_timer :: TimerHandle):cancel()
		shared.poll_timer = nil
	end
end

local function cancel_render()
	if shared.render_timer ~= nil then
		(shared.render_timer :: TimerHandle):cancel()
		shared.render_timer = nil
	end
end

local function render_all()
	local live = live_panes()
	for pane, cx in shared.open_blocks do
		if live[pane] then
			cx:render()
		else
			shared.open_blocks[pane] = nil
		end
	end
	if choose_live(live) == nil then
		cancel_poll()
		cancel_render()
	end
end

local function wall_now(): number
	local snapshot = shared.snapshot
	local snapshot_mono_ms = shared.snapshot_mono_ms
	if snapshot ~= nil and snapshot_mono_ms ~= nil then
		return snapshot.as_of_ms + math.max(0, tern.now() - snapshot_mono_ms)
	end
	return shared.last_success_wall_ms or 0
end

local function elapsed_text(milliseconds: number): string
	local seconds = math.max(0, math.floor(milliseconds / 1000))
	if seconds < 60 then
		return "<1m"
	elseif seconds < 3600 then
		return tostring(seconds // 60) .. "m"
	elseif seconds < 86400 then
		local hours = seconds // 3600
		local minutes = (seconds % 3600) // 60
		return tostring(hours) .. "h" .. (if minutes > 0 then " " .. tostring(minutes) .. "m" else "")
	end
	local days = seconds // 86400
	local hours = (seconds % 86400) // 3600
	return tostring(days) .. "d" .. (if hours > 0 then " " .. tostring(hours) .. "h" else "")
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

local POOL_LABELS: { [string]: string } = {
	claude_gpt = "GPT / Claude",
	gemini = "Agy",
}


local function window_name(window: UsageWindow): string
	local label = WINDOW_LABELS[window.key] or title_key(window.key)
	if window.pool ~= "default" and window.pool ~= "all" then
		label ..= " · " .. (POOL_LABELS[window.pool] or title_key(window.pool))
	end
	return label
end

local function model_window_name(window: UsageWindow): string
	local marker = string.find(window.key, "model.", 1, true)
	if marker ~= nil then
		return string.sub(window.key, marker + 6)
	end
	return window_name(window)
end


local function reset_day_line(window: UsageWindow): string
	if window.resets_at_ms == nil then
		return "Resets: unavailable"
	end
	return "Resets: " .. os.date("%A at %H:%M", math.floor((window.resets_at_ms :: number) / 1000))
end

local function reset_countdown_line(window: UsageWindow, now_ms: number): string
	if window.resets_at_ms == nil then
		return "Countdown unavailable"
	end
	local seconds_left = math.max(0, math.floor(((window.resets_at_ms :: number) - now_ms) / 1000))
	local days = seconds_left // 86400
	local hours = (seconds_left % 86400) // 3600
	local minutes = (seconds_left % 3600) // 60
	local seconds = seconds_left % 60
	return string.format("%02d days, %02d:%02d:%02d left.", days, hours, minutes, seconds)
end
local function window_node(account_id: string, window: UsageWindow, now_ms: number): Node
	local label = window_name(window)
	local key = account_id .. ":" .. window.key .. ":" .. window.pool
	if window.used == nil then
		return el("div", { class = "tfu-window tfu-unavailable", key = key }, {
			el("span", { class = "tfu-window-name", text = label }),
			el("span", { class = "tfu-reason", text = REASONS[window.unavailable_reason or "unavailable"] or "unavailable" }),
		})
	end
	local used = window.used :: number
	return el("div", { class = "tfu-window", key = key }, {
		el("div", { class = "tfu-ring-row" }, {
			el("div", { class = "tfu-ring" }, {
				ui.node("meter", {
					style = "ring",
					value = used / 100,
					thresholds = { warn = 0.70, bad = 0.90 },
					label = percent_text(used) .. " used",
				}),
			}),
		}),
		el("span", { class = "tfu-window-name", text = label }),
		el("span", { class = "tfu-reset", text = reset_day_line(window) }),
		el("span", { class = "tfu-reset", text = reset_countdown_line(window, now_ms) }),
	})
end


local function model_window_node(account_id: string, window: UsageWindow): Node
	local label = model_window_name(window)
	local key = account_id .. ":" .. window.key .. ":" .. window.pool
	local used = window.used or 0
	local text = if window.used == nil
		then REASONS[window.unavailable_reason or "unavailable"] or "unavailable"
		else percent_text(used)
	return el("div", { class = "tfu-model-window", key = key }, {
		el("span", { class = "tfu-model-name", text = label }),
		ui.node("meter", {
			style = "bar",
			value = used / 100,
			thresholds = { warn = 0.70, bad = 0.90 },
			label = text,
		}),
	})
end

local function account_node(account: Account, now_ms: number): Node
	local weekly: { UsageWindow } = {}
	local models: { Node } = {}
	for _, window in account.windows do
		if window.key == "seven_day" or window.key == "weekly" then
			table.insert(weekly, window)
		elseif string.find(window.key, ":", 1, true) ~= nil then
			table.insert(models, model_window_node(account.id, window))
		end
	end
	local usage: { Node } = {}
	for _, window in weekly do
		table.insert(usage, window_node(account.id, window, now_ms))
	end
	for _, model in models do
		table.insert(usage, model)
	end
	if #usage == 0 then
		table.insert(usage, el("span", {
			class = "tfu-reason",
			text = if account.usage_source == "none" then "Provider does not report usage." else "No weekly usage reading yet.",
		}))
	end
	local heading: { Node } = {
		el("div", { class = "tfu-identity" }, {
			el("span", { class = "tfu-account", text = account.account_label }),
		}),
	}
	if account.plan ~= nil then
		table.insert(heading, el("span", { class = "tfu-plan", text = account.plan :: string }))
	end
	return el("article", { class = "tfu-card", key = account.id }, {
		el("div", { class = "tfu-card-head" }, heading),
		el("div", { class = "tfu-windows" }, usage),
	})
end


local PROVIDER_ORDER: { [string]: number } = {
	claude = 1,
	openai = 2,
	kimi = 3,
	muse = 4,
	antigravity = 5,
}

local function provider_rank(provider: string): number
	return PROVIDER_ORDER[provider] or 100
end

local function provider_groups(accounts: { Account }): { ProviderGroup }
	local groups: { ProviderGroup } = {}
	local by_provider: { [string]: ProviderGroup } = {}
	local labels: { [string]: string } = {
		claude = "Claude",
		openai = "Codex",
		kimi = "Kimi",
		muse = "Muse",
		antigravity = "Google",
	}
	for _, account in accounts do
		local group = by_provider[account.provider]
		if group == nil then
			group = {
				key = account.provider,
				label = labels[account.provider] or account.provider_label,
				accounts = {},
			}
			by_provider[account.provider] = group
			table.insert(groups, group)
		end
		table.insert(group.accounts, account)
	end
	table.sort(groups, function(left, right)
		local left_rank = provider_rank(left.key)
		local right_rank = provider_rank(right.key)
		if left_rank == right_rank then
			return left.key < right.key
		end
		return left_rank < right_rank
	end)
	return groups
end

local function provider_node(group: ProviderGroup, now_ms: number): Node
	local cards: { Node } = {}
	for _, account in group.accounts do
		table.insert(cards, account_node(account, now_ms))
	end
	return el("section", { class = "tfu-provider-group", key = group.key }, {
		el("div", { class = "tfu-provider-heading" }, {
			ui.node("avatar", { text = group.label, seed = group.key }),
			el("span", { class = "tfu-provider", text = group.label }),
			el("span", { class = "tfu-provider-count", text = tostring(#cards) .. " accounts" }),
		}),
		el("div", { class = "tfu-grid" }, cards),
	})
end

local function main_view(): Node
	if shared.snapshot == nil then
		if shared.problem ~= nil then
			return el("div", { class = "tfu-root tfu-empty" }, {
				ui.node("icon", { name = "error", tone = "error" }),
				el("strong", { text = "Agent usage unavailable" }),
				el("span", { text = shared.problem :: string }),
				el("span", { class = "tfu-muted", text = "Idle agents are queried automatically." }),
			})
		end
		return el("div", { class = "tfu-root tfu-empty" }, {
			ui.node("spinner", { style = "dots", label = "Reading agent usage…" }),
		})
	end
	local snapshot = shared.snapshot :: Snapshot
	local groups: { Node } = {}
	for _, group in provider_groups(snapshot.accounts) do
		table.insert(groups, provider_node(group, wall_now()))
	end
	if #groups == 0 then
		table.insert(groups, el("div", { class = "tfu-empty", text = "No active fleet subscription accounts." }))
	end
	return el("div", { class = "tfu-root" }, groups)
end


local function dock_view(): Node
	local status = "Reading…"
	local snapshot = shared.snapshot
	if snapshot ~= nil and shared.last_success_wall_ms ~= nil then
		status = "Updated " .. elapsed_text(wall_now() - (shared.last_success_wall_ms :: number)) .. " ago"
	end
	if shared.problem ~= nil and snapshot ~= nil then
		status = "Last read failed · showing previous snapshot"
	elseif shared.loading and snapshot ~= nil then
		status = "Refreshing…"
	end
	return el("div", { class = "tfu-root tfu-dock" }, {
		el("span", {
			class = if shared.problem ~= nil then "tfu-status tfu-status-warn" else "tfu-status",
			text = status,
			title = shared.problem,
		}),
		el("button", {
			class = "tfu-refresh",
			title = "Refresh native agent usage (r)",
			actions = { click = "refresh" },
		}, {
			ui.node("icon", { name = "redo" }),
		}),
	})
end


local fetch: (number) -> ()

local function arm_render()
	if shared.render_timer ~= nil then
		return
	end
	local live = live_panes()
	local source = choose_live(live)
	if source == nil then
		return
	end
	shared.render_timer = tern.timer(RENDER_MS, function(_cx: WindowCx?)
		shared.render_timer = nil
		local current_live = live_panes()
		if not current_live[source] then
			source = choose_live(current_live)
		end
		if source ~= nil and current_live[source] then
			render_all()
			arm_render()
		end
	end)
end

local function rearm_poll()
	if shared.poll_timer ~= nil then
		(shared.poll_timer :: TimerHandle):cancel()
		shared.poll_timer = nil
	end
	local live = live_panes()
	local source = choose_live(live)
	if source == nil then
		return
	end
	shared.poll_timer = tern.timer(POLL_MS, function(_cx: WindowCx?)
		shared.poll_timer = nil
		local current_live = live_panes()
		if not current_live[source] then
			source = choose_live(current_live)
		end
		if source ~= nil and current_live[source] then
			fetch(source :: number)
		end
	end)
end

fetch = function(pane: number)
	local live = live_panes()
	if not live[pane] or shared.loading then
		return
	end
	if shared.poll_timer ~= nil then
		(shared.poll_timer :: TimerHandle):cancel()
		shared.poll_timer = nil
	end
	shared.loading = true
	render_all()
	local raw = tern.kv.get("native_snapshot")
	local next_snapshot: Snapshot? = nil
	if type(raw) == "table" then
		local encoded_ok, encoded = pcall(tern.json.encode, raw)
		if encoded_ok then
			next_snapshot = decode(encoded)
		end
	end
	shared.loading = false
	if next_snapshot == nil then
		shared.problem = "No native agent usage reading yet"
	else
		shared.snapshot = next_snapshot
		shared.snapshot_mono_ms = tern.now()
		shared.last_success_wall_ms = next_snapshot.as_of_ms
		shared.problem = nil
	end
	render_all()
	rearm_poll()
end

local function on_key(key: Key, pane: number): boolean?
	if key.ctrl or key.alt or key.meta then
		return false
	end
	if key.name ~= "r" and key.text ~= "r" then
		return false
	end
	fetch(pane)
	return true
end

local function on_event(event: UiEvent, pane: number)
	if event.ev == "action" and event.act == "refresh" then
		fetch(pane)
	end
end

local def: BlockDef<BlockState> = {
	font = "sans",
	init = function(cx: BlockCx, _args: { string }, _saved: any): BlockState
		shared.open_blocks[cx.pane] = cx
		arm_render()
		fetch(cx.pane)
		return { pane = cx.pane }
	end,
	title = function(_state: BlockState): string?
		return "Agent Usage Block"
	end,
	view = function(_state: BlockState, _cx: BlockCx): BlockView
		return { main = ui.col({ main_view() }), dock = ui.col({ dock_view() }) }
	end,
	key = function(state: BlockState, key: Key, _cx: BlockCx): boolean?
		return on_key(key, state.pane)
	end,
	event = function(state: BlockState, event: UiEvent, _cx: BlockCx)
		on_event(event, state.pane)
	end,
}

tern.block.define("accounts", def)
