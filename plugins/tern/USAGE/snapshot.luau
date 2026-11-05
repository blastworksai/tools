--!strict
-- Validated v3 boundary and the shared account projection. No storage or collection.
local account_grouping = require("./accounts")
local roster = require("./roster")
type Reading = account_grouping.Reading
type UsageWindow = account_grouping.UsageWindow
export type SourceSnapshot = { version: number, as_of_ms: number, publisher: string, readings: { Reading }, roster: any? }
local snapshot = {}
snapshot.LEASE_MS = 900000

-- The only unavailable/last-known reasons a window may carry; mirrors
-- usage_service/protocol.py REASONS. Collectors map any other code to source_usage_unavailable.
snapshot.REASONS = {
	not_reported = true, unparsed = true, source_unreachable = true,
	not_yet_measured = true, reset_passed = true, stale = true,
	web_login_expired = true, unavailable = true, server_sent_no_usage = true,
	local_login_unavailable = true, source_metadata_disabled = true, vendor_usage_unavailable = true,
	source_timeout = true, source_context_ambiguous = true, source_profile_invalid = true,
	source_profile_unavailable = true, source_usage_unavailable = true, source_remote = true, api_key_login = true,
	web_login_forbidden = true,
}
local REASONS = snapshot.REASONS

local function finite(value: any): boolean
	return type(value) == "number" and value == value and value ~= math.huge and value ~= -math.huge
end

-- Display/identity text: non-blank, bounded, no control characters (incl. DEL).
function snapshot.text(value: any, maximum: number): boolean
	return type(value) == "string" and value:find("%S") ~= nil
		and #value <= maximum and not value:find("%c")
end
local text = snapshot.text

local function timestamp(value: any): boolean
	return finite(value) and value >= 0 and value <= 9007199254740991 and value % 1 == 0
end

local function percent(value: any): boolean
	return finite(value) and value >= 0 and value <= 100
end

-- Element count of a dense 1-based JSON array, or nil.
local function array_count(value: any, maximum: number): number?
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
	if count > maximum then return nil end
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
	if not timestamp(value) then
		return nil
	end
	return value
end

local function decode_calendar(raw: any): any?
	if type(raw) ~= "table" then return nil end
	local calendar = {}
	for key, bounds in { year = { 1970, 2100 }, month = { 1, 12 }, day = { 1, 31 }, hour = { 0, 23 }, minute = { 0, 59 } } do
		local value = raw[key]
		if value ~= nil then
			if not finite(value) or value % 1 ~= 0 or value < bounds[1] or value > bounds[2] then return nil end
			calendar[key] = value
		end
	end
	if calendar.hour == nil or calendar.minute == nil then return nil end
	if raw.timezone ~= nil then
		if type(raw.timezone) ~= "string" or raw.timezone == "" or #raw.timezone > 128 or raw.timezone:find("%c") then return nil end
		calendar.timezone = raw.timezone
	end
	return calendar
end

local function decode_window(raw: any): UsageWindow?
	if type(raw) ~= "table" or not text(raw.key, 128) or not text(raw.pool, 128) then
		return nil
	end
	if not timestamp(raw.observed_at_ms) then
		return nil
	end
	local resets_at_ms = optional_number(raw.resets_at_ms)
	if raw.resets_at_ms ~= nil and resets_at_ms == nil then
		return nil
	end
	if raw.reset_label ~= nil and not text(raw.reset_label, 1024) then
		return nil
	end
	local reset_observed_at_ms = optional_number(raw.reset_observed_at_ms)
	if raw.reset_observed_at_ms ~= nil and reset_observed_at_ms == nil then return nil end
	local reset_calendar = if raw.reset_calendar ~= nil then decode_calendar(raw.reset_calendar) else nil
	if raw.reset_calendar ~= nil and reset_calendar == nil then return nil end
	local reason: string? = nil
	if raw.unavailable_reason ~= nil then
		if type(raw.unavailable_reason) ~= "string" or not REASONS[raw.unavailable_reason] then
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
	local last_known_reason = raw.last_known_reason
	if last_known_reason ~= nil and (not REASONS[last_known_reason] or used == nil or reason ~= nil) then return nil end
	local duration = raw.window_duration_mins
	if duration ~= nil and (not timestamp(duration) or duration < 1 or duration > 525600) then return nil end
	return {
		key = raw.key,
		pool = raw.pool,
		used = used,
		remaining = remaining,
		resets_at_ms = resets_at_ms,
		reset_label = raw.reset_label,
		observed_at_ms = raw.observed_at_ms,
		reset_observed_at_ms = reset_observed_at_ms,
		reset_calendar = reset_calendar,
		unavailable_reason = reason,
		last_known_reason = last_known_reason,
		window_duration_mins = duration,
	}
end

local function decode_reading(raw: any): Reading?
	if type(raw) ~= "table" then
		return nil
	end
	if not text(raw.id, 4096) or not text(raw.provider, 128) then
		return nil
	end
	if not text(raw.provider_label, 1024) or not text(raw.source_label, 1024) then
		return nil
	end
	if raw.agent_id ~= nil and not text(raw.agent_id, 4096) then return nil end
	if raw.agent_label ~= nil and not text(raw.agent_label, 1024) then return nil end

	if raw.account_id ~= nil or raw.account_label ~= nil then
		if not text(raw.account_id, 4096) or not text(raw.account_label, 1024) then
			return nil
		end
	end
	if raw.canonical_id ~= nil and not text(raw.canonical_id, 4096) then return nil end
	if raw.principal_id ~= nil and not text(raw.principal_id, 4096) then return nil end
	local account_aliases = nil
	if raw.account_aliases ~= nil then
		if array_count(raw.account_aliases, 27) == nil or raw.canonical_id == nil then return nil end
		account_aliases = tern.json.array()
		for _, alias in raw.account_aliases do
			if type(alias) ~= "string" or alias == "" or #alias > 4096 or alias:find("%c") then return nil end
			table.insert(account_aliases, alias)
		end
	end
	if not text(raw.usage_source, 1024) then
		return nil
	end
	local plan: string? = nil
	if raw.plan ~= nil then
		if not text(raw.plan, 1024) then
			return nil
		end
		plan = raw.plan
	end
	local last_reading_at_ms = optional_number(raw.last_reading_at_ms)
	if raw.last_reading_at_ms ~= nil and last_reading_at_ms == nil then
		return nil
	end
	local credit_balance = raw.credit_balance
	if credit_balance ~= nil and (not finite(credit_balance) or credit_balance < 0 or credit_balance > 9007199254740991) then return nil end
	local window_count = array_count(raw.windows, 65)
	if window_count == nil then
		return nil
	end
	local windows: { UsageWindow } = tern.json.array()
	for index = 1, window_count do
		local raw_window = raw.windows[index]
		local window = decode_window(raw_window)
		if window == nil then return nil end
		local ignored_claude_window = type(raw_window) == "table"
			and raw.provider == "claude"
			and (raw_window.key == "iguana_necktie" or raw_window.key == "nimbus_quill")
		if not ignored_claude_window then
			table.insert(windows, window)
		end
	end
	return {
		id = raw.id,
		provider = raw.provider,
		provider_label = raw.provider_label,
		agent_id = raw.agent_id,
		agent_label = raw.agent_label,
		source_label = raw.source_label,
		account_id = raw.account_id,
		account_label = raw.account_label,
		canonical_id = raw.canonical_id,
		principal_id = raw.principal_id,
		account_aliases = account_aliases,
		plan = plan,
		credit_balance = credit_balance,
		usage_source = raw.usage_source,
		last_reading_at_ms = last_reading_at_ms,
		windows = windows,
	}
end

local function ids(raw: any): any?
	if array_count(raw, 1000) == nil then return nil end
	local result = tern.json.array()
	for _, value in raw do
		if not text(value, 4096) then return nil end
		table.insert(result, value)
	end
	return result
end

-- Binding evidence mirrors usage_service/protocol.py _binding_fields: accounts may
-- carry `profile_binding`, consumers `account_ids`; either needs a definition revision.
local function binding_fields(raw: any, result: any, evidence: string): boolean
	if raw[if evidence == "profile_binding" then "account_ids" else "profile_binding"] ~= nil then return false end
	if raw.definition_revision ~= nil then
		if type(raw.definition_revision) ~= "string" or #raw.definition_revision ~= 64
			or not raw.definition_revision:match("^[0-9a-f]+$") then return false end
		result.definition_revision = raw.definition_revision
	end
	if raw.profile_binding ~= nil then
		local binding = raw.profile_binding
		if type(binding) ~= "table" or result.definition_revision == nil or not text(binding.handle, 256)
			or not timestamp(binding.generation) or binding.generation < 1 then return false end
		local canonical = ids(binding.canonical_ids)
		if canonical == nil or #canonical < 1 or #canonical > 32 then return false end
		result.profile_binding = { handle = binding.handle, generation = binding.generation, canonical_ids = canonical }
	end
	if raw.account_ids ~= nil then
		local accounts = ids(raw.account_ids)
		if accounts == nil or #accounts ~= 1 or result.definition_revision == nil then return false end
		result.account_ids = accounts
	end
	return true
end

-- SPAWN membership published with a snapshot (roster schema 1).
local function decode_roster(raw: any): any?
	if type(raw) ~= "table" or raw.version ~= 1 or array_count(raw.scopes, 128) == nil then return nil end
	local scopes, seen = tern.json.array(), {}
	for _, scope in raw.scopes do
		if type(scope) ~= "table" or not text(scope.id, 512) or seen[scope.id]
			or not text(scope.revision, 512) or not timestamp(scope.updated_at_ms)
			or array_count(scope.accounts, 1000) == nil or array_count(scope.consumers, 1000) == nil then return nil end
		seen[scope.id] = true
		local entries, consumers, members = tern.json.array(), tern.json.array(), {}
		for _, entry in scope.accounts do
			if type(entry) ~= "table" or not text(entry.id, 4096) or members[entry.id]
				or not text(entry.provider, 256) or not text(entry.provider_label, 1024)
				or not text(entry.account_label, 1024) then return nil end
			local canonical_ids, reading_ids = ids(entry.canonical_ids), ids(entry.reading_ids)
			if canonical_ids == nil or reading_ids == nil then return nil end
			members[entry.id] = true
			local item = { id = entry.id, provider = entry.provider, provider_label = entry.provider_label,
				account_label = entry.account_label, canonical_ids = canonical_ids, reading_ids = reading_ids }
			if not binding_fields(entry, item, "profile_binding") then return nil end
			table.insert(entries, item)
		end
		for _, consumer in scope.consumers do
			if type(consumer) ~= "table" or not text(consumer.id, 4096) or members[consumer.id]
				or not text(consumer.label, 1024) then return nil end
			local reading_ids = ids(consumer.reading_ids)
			if reading_ids == nil then return nil end
			members[consumer.id] = true
			local item = { id = consumer.id, label = consumer.label, reading_ids = reading_ids }
			if not binding_fields(consumer, item, "account_ids") then return nil end
			table.insert(consumers, item)
		end
		local item = { id = scope.id, revision = scope.revision, updated_at_ms = scope.updated_at_ms,
			accounts = entries, consumers = consumers }
		if scope.spawn_join ~= nil then
			local join = scope.spawn_join
			if type(join) ~= "table" or not text(join.namespace, 512) or not text(join.host_key, 512)
				or not timestamp(join.config_revision) then return nil end
			item.spawn_join = { namespace = join.namespace, host_key = join.host_key, config_revision = join.config_revision }
		end
		table.insert(scopes, item)
	end
	return { version = 1, scopes = scopes }
end

function snapshot.decode(raw: any): (SourceSnapshot?, string?)
	local value = raw
	if type(raw) == "string" then
		if #raw > 1048576 then return nil, "snapshot_too_large" end
		local ok, decoded = pcall(tern.json.decode, raw)
		if not ok then return nil, "snapshot_rejected" end
		value = decoded
	end
	if type(value) ~= "table" or value.version ~= 3 or not timestamp(value.as_of_ms)
		or not text(value.publisher, 512) then
		return nil, "snapshot_rejected"
	end
	local reading_count = array_count(value.readings, 1000)
	if reading_count == nil then return nil, "snapshot_rejected" end
	if type(raw) == "table" then
		-- Decoded documents enforce the same byte bound as wire text.
		local ok, encoded = pcall(tern.json.encode, raw)
		if not ok then return nil, "snapshot_rejected" end
		if #encoded > 1048576 then return nil, "snapshot_too_large" end
	end
	local readings: { Reading } = tern.json.array()
	for index = 1, reading_count do
		local reading = decode_reading(value.readings[index])
		if reading == nil then return nil, "snapshot_rejected" end
		table.insert(readings, reading)
	end
	local configured = if value.roster ~= nil then decode_roster(value.roster) else nil
	if value.roster ~= nil and configured == nil then return nil, "snapshot_rejected" end
	return {
		version = 3,
		publisher = value.publisher,
		as_of_ms = value.as_of_ms,
		readings = readings,
		roster = configured,
	}, nil
end

-- Inputs are decoded at ingress. Expiry changes presentation, never membership or
-- source timestamps. Removal belongs to the owner of the keyed publisher set.
-- Returns { accounts, consumers, unresolved, freshness = { next_change_at_ms } };
-- every account window carries `freshness` (fresh/stale/last_known/unavailable).
function snapshot.project(snapshots: { [string]: SourceSnapshot }, now_ms: number): any
	local readings: { Reading } = tern.json.array()
	local next_change: number? = nil
	local function expires(at: number)
		if at > now_ms then next_change = math.min(next_change or at, at) end
	end
	local ordered = {}
	for publisher in snapshots do table.insert(ordered, publisher) end
	table.sort(ordered)
	for _, publisher in ordered do
		local source = snapshots[publisher]
		expires(source.as_of_ms + snapshot.LEASE_MS + 1)
		for _, reading in source.readings do table.insert(readings, reading) end
	end
	local consumer_readings = roster.consumer_readings(snapshots)
	local projected = account_grouping.retain_muse(readings, consumer_readings)
	local accounts, consumers, unresolved = roster.project(snapshots, projected, readings, consumer_readings)
	for _, account_value in accounts do
		local account: any = account_value
		for _, value in account.windows do
			local window: any = value
			local stale = now_ms - window.observed_at_ms > snapshot.LEASE_MS
				or (window.resets_at_ms ~= nil and window.resets_at_ms <= now_ms)
			window.freshness = if window.used == nil then "unavailable" elseif window.last_known_reason ~= nil then "last_known" elseif stale then "stale" else "fresh"
			if window.used ~= nil then
				expires(window.observed_at_ms + snapshot.LEASE_MS + 1)
				if window.resets_at_ms ~= nil then expires(window.resets_at_ms) end
			end
		end
	end
	return { accounts = accounts, consumers = consumers, unresolved = unresolved,
		freshness = { next_change_at_ms = next_change } }
end

return snapshot
