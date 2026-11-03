--!strict
-- Status, bar and details share account order, quota selection and freshness.
local presentation = {}
local PROVIDER_ORDER = { claude = 1, openai = 2, kimi = 3, muse = 4, antigravity = 5, grok = 6 }
-- Tern's StatusSegment has no width/tooltip/custom SVG API. Keep the summary
-- bounded independently of account count; the overflow opens the complete list.
presentation.SUMMARY_LIMIT = 3
presentation.EMPTY_TEXT = "Define accounts in SPAWN to show usage."
presentation.MUSE_WAITING = "Awaiting usage after a turn"
presentation.icons = {
	claude = "provider-anthropic", openai = "provider-openai-codex",
	kimi = "provider-kimi-code", muse = "provider-meta", antigravity = "provider-google-antigravity",
	grok = "provider:xai",
}

function presentation.ordered_accounts(accounts: { any }): { any }
	local ordered = table.create(#accounts)
	for index, account in ipairs(accounts) do ordered[index] = account end
	table.sort(ordered, function(left, right)
		local left_rank = PROVIDER_ORDER[left.provider] or 100
		local right_rank = PROVIDER_ORDER[right.provider] or 100
		if left_rank ~= right_rank then return left_rank < right_rank end
		if left.provider ~= right.provider then return left.provider < right.provider end
		if left.account_label ~= right.account_label then return left.account_label < right.account_label end
		return left.id < right.id
	end)
	return ordered
end

-- Compact rows prefer a measured weekly (seven_day) quota of any pool: Codex
-- arrives as pool `codex`, Grok as `grok`. Among weeklies the account-wide
-- pool wins, then key/pool order keeps the choice independent of input order.
-- Windows are already normalized by the reducer (weekly→seven_day, all→default).
local function window_precedes(left: any, right: any): boolean
	if (left.used ~= nil) ~= (right.used ~= nil) then return left.used ~= nil end
	local left_weekly, right_weekly = left.key == "seven_day", right.key == "seven_day"
	if left_weekly ~= right_weekly then return left_weekly end
	local left_default, right_default = left.pool == "default", right.pool == "default"
	if left_weekly and left_default ~= right_default then return left_default end
	if left.key ~= right.key then return left.key < right.key end
	return left.pool < right.pool
end

function presentation.account_window(account: any): any?
	local selected = nil
	for _, window in account.windows do
		if selected == nil or window_precedes(window, selected) then selected = window end
	end
	return selected
end

function presentation.tone(used: number?): string
	if used == nil then return "muted" end
	if used >= 90 then return "error" end
	if used >= 70 then return "warn" end
	return "ok"
end

-- Text-node role for a measured, current percentage: usage.css colours
-- `usage-heat-0` (green) through `usage-heat-100` (red) in 10% steps.
-- Anything not current gets nil and stays muted, so old values never look live.
function presentation.heat(used: number?, state: string): string?
	if used == nil or state ~= "fresh" then return nil end
	local step = math.floor(math.clamp(used, 0, 100) / 10 + 0.5) * 10
	return "usage-heat-" .. tostring(step)
end

function presentation.ring(used: number?): string
	if used == nil then return "◇" end
	if used == 0 then return "○" end
	if used >= 100 then return "●" end
	if used >= 62.5 then return "◕" end
	if used >= 37.5 then return "◑" end
	return "◔"
end

function presentation.window_state(window: any?, now_ms: number?): string
	if window == nil or window.used == nil then return "unavailable" end
	local now = now_ms or math.floor(os.time() * 1000)
	if window.resets_at_ms ~= nil and window.resets_at_ms <= now then return "reset_passed" end
	if window.freshness == "stale" then return "stale" end
	if window.unavailable_reason ~= nil or window.last_known_reason ~= nil then return "last_known" end
	return "fresh"
end

function presentation.account_projection(account: any, now_ms: number?): any
	local window = presentation.account_window(account)
	local used = if window ~= nil then window.used else nil
	local state = presentation.window_state(window, now_ms)
	local value = if used == nil then "—" else tostring(math.floor(used + 0.5)) .. "% used"
	return {
		window = window, used = used, state = state, icon = presentation.icons[account.provider] or "gauge",
		text = if used == nil and account.provider == "muse" then presentation.MUSE_WAITING
			else presentation.ring(used) .. " " .. value
				.. (if state == "stale" then " last-known · stale" elseif state == "reset_passed" then " last-known · Reset passed"
					elseif state == "last_known" then " last-known" else ""),
		tone = if state == "fresh" then presentation.tone(used) else "muted",
		heat = presentation.heat(used, state),
	}
end

-- Rounds up so "Reset passed" appears exactly when window_state flips.
function presentation.countdown(resets_at_ms: number, now_ms: number, compact: boolean?): string
	local seconds_left = math.max(0, math.ceil((resets_at_ms - now_ms) / 1000))
	if seconds_left == 0 then return "Reset passed" end
	local days = seconds_left // 86400
	local hours = (seconds_left % 86400) // 3600
	local minutes = (seconds_left % 3600) // 60
	local seconds = seconds_left % 60
	return string.format(if compact then "Resets in %02dd %02d:%02d:%02d" else "%02d days, %02d:%02d:%02d left.", days, hours, minutes, seconds)
end

-- The compact countdown of the window the percentage came from. An unknown
-- reset has no countdown; a passed reset is already stated by the projection.
function presentation.compact_countdown(value: any, now_ms: number): string?
	if value.used == nil or value.window == nil or value.window.resets_at_ms == nil or value.state == "reset_passed" then return nil end
	return presentation.countdown(value.window.resets_at_ms, now_ms, true)
end

function presentation.summary(model: any, now_ms: number?): any
	local accounts = presentation.ordered_accounts(model.accounts)
	local visible_count = math.min(#accounts, presentation.SUMMARY_LIMIT)
	local measured, current = 0, 0
	for _, account in accounts do
		local value = presentation.account_projection(account, now_ms)
		if value.used ~= nil then measured += 1 end
		if value.state == "fresh" then current += 1 end
	end
	return { accounts = accounts, visible_count = visible_count,
		overflow_count = #accounts - visible_count, total_count = #accounts, current_count = current,
		header = tostring(#accounts) .. " accounts · " .. tostring(current)
			.. " current · " .. tostring(measured - current) .. " last-known · " .. tostring(#accounts - measured) .. " unavailable" }
end

function presentation.consumer_text(consumer: any): string
	local accounts = if #consumer.account_labels > 0 then table.concat(consumer.account_labels, ", ")
		else "account not linked"
	return consumer.label .. " · Uses underlying subscription · " .. accounts
end

function presentation.segments(model: any): { any }
	local summary = presentation.summary(model)
	local segments = {}
	local now_ms = math.floor(os.time() * 1000)
	for index = 1, summary.visible_count do
		local value = presentation.account_projection(summary.accounts[index], now_ms)
		table.insert(segments, { text = value.text, icon = value.icon,
			tone = value.tone, command = "plugin.usage.details" })
	end
	if summary.overflow_count > 0 then
		table.insert(segments, { text = "+" .. tostring(summary.overflow_count),
			tone = "muted", command = "plugin.usage.details" })
	end
	if #segments == 0 then
		table.insert(segments, { text = presentation.EMPTY_TEXT, tone = "muted", command = "plugin.usage.details" })
	end
	return segments
end

return presentation
