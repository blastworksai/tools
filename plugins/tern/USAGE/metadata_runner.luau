--!strict
-- Bounded projection of one helper response ({version, metadata?, usage?, error?}).
-- Commands, selectors and raw helper output never become display data.
local snapshot = require("./snapshot")
local runner = {}
local REASONS, text = snapshot.REASONS, snapshot.text
local ALLOWED = { claude = true, openai = true, kimi = true, muse = true, antigravity = true, grok = true }
local FIELDS = { "principal", "principal_kind", "label", "plan", "organization", "organization_id", "workspace", "workspace_id", "tenant", "tenant_id" }

local function finite(value: any): boolean
	return type(value) == "number" and value == value and value > 0 and value < 253370764800000
end

local function generation(value: any): boolean
	return finite(value) and value % 1 == 0
end

-- Unknown or non-reading codes become the generic quota-unavailable reason.
local function error_code(err: any): string
	local code = if type(err) == "table" then err.code else err
	return if type(code) == "string" and REASONS[code] then code else "source_usage_unavailable"
end

local function metadata(value: any): any?
	if type(value) ~= "table" then return nil end
	local result = {}
	for _, key in FIELDS do
		local field = value[key]
		if field ~= nil and type(field) ~= "userdata" then
			if not text(field, 512) or field:match("^[/\\]") or field:match("^%a:[/\\]") or field:find("://", 1, true) then return nil end
			result[key] = field
		end
	end
	if not result.principal or not result.label or (result.principal_kind ~= "email" and result.principal_kind ~= "id") then return nil end
	return result
end

local function usage_view(usage: any): any?
	if type(usage) ~= "table" or not ALLOWED[usage.provider] or type(usage.windows) ~= "table" or #usage.windows > 64 or not finite(usage.observed_at_ms) then return nil end
	local windows, seen = tern.json.array(), {}
	for _, window in usage.windows do
		if type(window) ~= "table" or not text(window.key, 128) or not text(window.pool, 128)
			or not finite(window.observed_at_ms) or (window.resets_at_ms ~= nil and not finite(window.resets_at_ms)) then return nil end
		local pair = tostring(#window.key) .. ":" .. window.key .. window.pool
		if seen[pair] then return nil end
		seen[pair] = true
		local safe_window = { key = window.key, pool = window.pool, observed_at_ms = window.observed_at_ms,
			resets_at_ms = window.resets_at_ms }
		if window.unavailable_reason ~= nil then
			if not REASONS[window.unavailable_reason] or window.used ~= nil or window.remaining ~= nil then return nil end
			safe_window.unavailable_reason = window.unavailable_reason
		else
			if type(window.used) ~= "number" or window.used ~= window.used or window.used < 0 or window.used > 100
				or type(window.remaining) ~= "number" or window.remaining ~= window.remaining
				or math.abs(window.used + window.remaining - 100) > 0.000001 then return nil end
			safe_window.used, safe_window.remaining = window.used, window.remaining
		end
		if window.window_duration_mins ~= nil then
			if not generation(window.window_duration_mins) or window.window_duration_mins > 525600 then return nil end
			safe_window.window_duration_mins = window.window_duration_mins
		end
		table.insert(windows, safe_window)
	end
	local result: any = { provider = usage.provider, windows = windows, observed_at_ms = usage.observed_at_ms }
	if usage.plan ~= nil then
		if not text(usage.plan, 512) then return nil end
		result.plan = usage.plan
	end
	if usage.credit_balance ~= nil then
		local balance = usage.credit_balance
		if type(balance) ~= "number" or balance ~= balance or balance < 0 or balance > 9007199254740991 then return nil end
		result.credit_balance = balance
	end
	if usage.unavailable_reason ~= nil then
		if #windows ~= 0 or not REASONS[usage.unavailable_reason] then return nil end
		result.unavailable_reason = usage.unavailable_reason
	end
	return result
end

-- nil means the whole response is malformed; the caller marks that item unparsed.
function runner.project(value: any): any?
	if type(value) ~= "table" or value.version ~= 1 then return nil end
	local safe: any = { version = 1 }
	if value.metadata ~= nil and type(value.metadata) ~= "userdata" then
		safe.metadata = metadata(value.metadata)
		if safe.metadata == nil then return nil end
	end
	if value.usage ~= nil and type(value.usage) ~= "userdata" then
		safe.usage = usage_view(value.usage)
		if safe.usage == nil then return nil end
	end
	if value.error ~= nil then safe.error = error_code(value.error) end
	return safe
end

return runner
