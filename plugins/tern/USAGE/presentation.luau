--!strict
-- Status, bar and details share account order, quota selection and freshness.
local presentation = {}
local snapshot = require("./snapshot")
local PROVIDER_ORDER = { claude = 1, openai = 2, kimi = 3, muse = 4, antigravity = 5, grok = 6 }
-- Tern's StatusSegment has no width/tooltip/custom SVG API: a fixed USAGE launcher plus one
-- segment per account the owner ticked in USAGE settings, bounded by MAX_ACCOUNT_SEGMENTS.
presentation.LAUNCHER_TEXT = "USAGE"
presentation.DETAILS_COMMAND = "plugin.usage.details"
presentation.ACCOUNT_COMMAND_PREFIX = "plugin.usage.status_account_"
presentation.MAX_ACCOUNT_SEGMENTS = 16
presentation.EMPTY_TEXT = "Define accounts in SPAWN to show usage."
presentation.MUSE_WAITING = "Awaiting usage after a turn"
presentation.icons = {
	claude = "provider-anthropic", openai = "provider-openai-codex",
	kimi = "provider-kimi-code", muse = "provider-meta", antigravity = "provider-google-antigravity",
	grok = "provider:xai", omp = "pi-mark",
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

-- Last-known because the provider login failed. Signing in fixes these and
-- waiting does not, so they never read like an ordinary stale value.
presentation.LOGIN_REASONS = {
	web_login_expired = "login expired",
	local_login_unavailable = "signed out",
	web_login_forbidden = "login refused",
} :: { [string]: string }

function presentation.login_problem(window: any?): string?
	if window == nil then return nil end
	local reason = window.last_known_reason or window.unavailable_reason
	return if reason ~= nil then presentation.LOGIN_REASONS[reason] else nil
end

function presentation.window_state(window: any?, now_ms: number?): string
	if window == nil or window.used == nil then return "unavailable" end
	if presentation.login_problem(window) ~= nil then return "login" end
	local now = now_ms or math.floor(os.time() * 1000)
	if window.resets_at_ms ~= nil and window.resets_at_ms <= now then return "reset_passed" end
	if window.freshness == "stale" or now - window.observed_at_ms > snapshot.LEASE_MS then return "stale" end
	if window.unavailable_reason ~= nil or window.last_known_reason ~= nil then return "last_known" end
	return "fresh"
end

-- Span style for a quota's text: current values take their heat role's colour,
-- a failed login warns, every other non-current value stays muted.
function presentation.text_style(state: string): string?
	if state == "fresh" then return nil end
	return if state == "login" then "warning" else "muted"
end

function presentation.elapsed(milliseconds: number): string
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

function presentation.account_projection(account: any, now_ms: number?): any
	local now = now_ms or math.floor(os.time() * 1000)
	local window = presentation.account_window(account)
	local used = if window ~= nil then window.used else nil
	local state = presentation.window_state(window, now)
	local value = if used == nil then "—" else tostring(math.floor(used + 0.5)) .. "% used"
	local status = if state == "login" then " · " .. (presentation.login_problem(window) :: string)
		elseif state == "stale" then " last-known · stale" elseif state == "reset_passed" then " last-known · Reset passed"
		elseif state == "last_known" then " last-known" else ""
	-- A value that is not current says how old it is.
	local age = if state ~= "fresh" and used ~= nil and window.observed_at_ms > 0
		then " · " .. presentation.elapsed(now - window.observed_at_ms) .. " old" else ""
	return {
		window = window, used = used, state = state, icon = presentation.icons[account.provider] or "gauge",
		text = if used == nil and account.provider == "muse" then presentation.MUSE_WAITING
			else presentation.ring(used) .. " " .. value .. status .. age,
		tone = if state == "fresh" then presentation.tone(used) elseif state == "login" then "warn" else "muted",
		heat = presentation.heat(used, state),
		style = presentation.text_style(state),
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
	local conflicts = #(model.roster_conflicts or {})
	local measured, current = 0, 0
	for _, account in accounts do
		local value = presentation.account_projection(account, now_ms)
		if value.used ~= nil then measured += 1 end
		if value.state == "fresh" then current += 1 end
	end
	return { accounts = accounts, total_count = #accounts, current_count = current, conflict_count = conflicts,
		header = tostring(#accounts) .. " accounts · " .. tostring(current)
			.. " current · " .. tostring(measured - current) .. " last-known · " .. tostring(#accounts - measured) .. " unavailable"
			.. (if conflicts > 0 then " · " .. tostring(conflicts) .. " account-list conflicts" else "") }
end

function presentation.consumer_text(consumer: any): string
	local accounts = if #consumer.account_labels > 0 then table.concat(consumer.account_labels, ", ")
		else "account not linked"
	return consumer.label .. " · Uses underlying subscription · " .. accounts
end

function presentation.launcher(): any
	return { text = presentation.LAUNCHER_TEXT, icon = "gauge", command = presentation.DETAILS_COMMAND }
end

-- "Provider: Label" for a status segment.
function presentation.status_label(account: any): string
	return (account.provider_label or account.provider) .. ": " .. account.account_label
end

-- The ring and percentage of a measured value; "—" when there is no number (never a zero).
-- A value that is not current says so, so it never reads as live.
function presentation.status_value(value: any): string
	if value.used == nil then return "—" end
	local text = presentation.ring(value.used) .. " " .. tostring(math.floor(value.used + 0.5)) .. "%"
	if value.state == "login" then return text .. " · " .. (presentation.login_problem(value.window) :: string) end
	if value.state ~= "fresh" then return text .. " last-known" end
	return text
end

-- Launcher, then (master On) one segment per selected account in provider order.
-- `prefs` is a status_preferences record; nil or Off renders the launcher alone.
-- The second result lists the account ids behind the account segments, in segment order.
function presentation.segments(model: any, prefs: any?, now_ms: number?): ({ any }, { string })
	local segments = { presentation.launcher() }
	local ids: { string } = {}
	if prefs == nil or prefs.enabled ~= true then return segments, ids end
	local now = now_ms or math.floor(os.time() * 1000)
	if #(model.roster_conflicts or {}) > 0 then
		table.insert(segments, { text = "Account list needs review", tone = "warn", command = presentation.DETAILS_COMMAND })
	end
	local set: { [string]: boolean } = {}
	for _, id in prefs.selected do set[id] = true end
	for _, account in presentation.ordered_accounts(model.accounts) do
		if #ids >= presentation.MAX_ACCOUNT_SEGMENTS then break end
		local chosen = set[account.id] == true
		for _, alias in account.also_configured or {} do
			if set[alias.id] == true then chosen = true end
		end
		if chosen then
			local value = presentation.account_projection(account, now)
			table.insert(ids, account.id)
			table.insert(segments, { text = presentation.status_label(account) .. "  " .. presentation.status_value(value),
				icon = value.icon, tone = value.tone, command = presentation.ACCOUNT_COMMAND_PREFIX .. tostring(#ids) })
		end
	end
	if #model.accounts == 0 and #segments == 1 then
		table.insert(segments, { text = presentation.EMPTY_TEXT, tone = "muted", command = presentation.DETAILS_COMMAND })
	end
	return segments, ids
end

-- Export only current, explicitly bound definitions. The same snapshot reducer
-- and account projection select quota/status; labels never establish a join.
function presentation.display_records(snapshots: any, access: any, now: number): { any }
	local records = {}
	local function same(left: any, right: any): boolean
		if type(left) ~= type(right) then return false end
		if type(left) ~= "table" then return left == right end
		for key, value in left do if not same(value, right[key]) then return false end end
		for key in right do if left[key] == nil then return false end end
		return true
	end
	for _, scope in access.scopes do
		local matching = {}
		for publisher, source in snapshots do
			for _, cached in if source.roster ~= nil then source.roster.scopes else {} do
				if cached.id ~= scope.id or cached.revision ~= scope.revision then continue end
				local valid = true
				for _, definition in scope.accounts do
					local found = false
					for _, entry in cached.accounts do
						if entry.id == definition.id and entry.definition_revision == definition.definition_revision
							and same(entry.profile_binding, definition.profile_binding) then found = true; break end
					end
					if not found then valid = false; break end
				end
				if valid then
					local copy = table.clone(source)
					copy.roster = { version = 1, scopes = { cached } }
					matching[publisher] = copy
				end
			end
		end
		local projected = snapshot.project(matching, now)
		local byId = {}
		for _, row in projected.accounts do
			byId[row.id] = row
			for _, alias in row.also_configured or {} do byId[alias.id] = row end
		end
		local byRecord = {}
		for _, definition in scope.accounts do
			local id = "spawn:" .. tostring(#scope.id) .. ":" .. scope.id .. ":" .. definition.id
			local row = if definition.profile_binding ~= nil then byId[id] else nil
			row = row or { provider = definition.provider, windows = {} }
			local value = presentation.account_projection(row, now)
			local window = value.window
			local join = scope.spawn_join
			-- SPAWN dispatch.catalog sets every row.revision to the authority's
			-- config_revision (not a per-record counter); spawn_join carries that writer value.
			local entry = { record_id = definition.id, record_revision = join.config_revision, definition_revision = definition.definition_revision,
				scope_id = scope.id, roster_revision = scope.revision, namespace = join.namespace, host_key = join.host_key, config_revision = join.config_revision,
				provider = definition.provider, provider_label = definition.provider_label, account_label = definition.account_label,
				icon = value.icon, used = value.used, state = value.state, text = value.text,
				observed_at_ms = if window ~= nil then window.observed_at_ms else nil,
				resets_at_ms = if window ~= nil then window.resets_at_ms else nil,
				age_ms = if window ~= nil and window.observed_at_ms > 0 then math.max(0, now - window.observed_at_ms) else nil,
				reason = if definition.profile_binding == nil then "binding_unavailable"
					elseif window ~= nil then window.last_known_reason or window.unavailable_reason else "not_reported" }
			table.insert(records, entry)
			byRecord[definition.id] = entry
		end
		for _, consumer in scope.consumers do
			local underlying = if consumer.account_ids ~= nil and #consumer.account_ids == 1 then byRecord[consumer.account_ids[1]] else nil
			local join = scope.spawn_join
			local entry = if underlying ~= nil then table.clone(underlying) else {
				scope_id = scope.id, roster_revision = scope.revision, namespace = join.namespace, host_key = join.host_key, config_revision = join.config_revision,
				state = "unavailable", text = "Underlying subscription not linked", reason = "binding_unavailable" }
			entry.record_id, entry.definition_revision = consumer.id, consumer.definition_revision
			entry.record_revision = join.config_revision
			entry.provider, entry.provider_label, entry.account_label, entry.icon = "omp", "OMP", consumer.label, presentation.icons.omp
			entry.underlying_record_id = if underlying ~= nil then underlying.record_id else nil
			table.insert(records, entry)
		end
	end
	table.sort(records, function(a, b) return a.scope_id < b.scope_id or (a.scope_id == b.scope_id and a.record_id < b.record_id) end)
	return records
end

return presentation
