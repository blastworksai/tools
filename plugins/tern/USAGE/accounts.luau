--!strict

local accounts = {}

export type UsageWindow = {
	key: string,
	pool: string,
	used: number?,
	remaining: number?,
	resets_at_ms: number?,
	reset_label: string?,
	observed_at_ms: number,
	reset_calendar: any?,
	reset_observed_at_ms: number?,
	unavailable_reason: string?,
	last_known_reason: string?,
	window_duration_mins: number?,
}

export type Reading = {
	id: string,
	provider: string,
	provider_label: string,
	agent_id: string?,
	agent_label: string?,
	source_label: string,
	account_id: string?,
	account_label: string?,
	canonical_id: string?,
	principal_id: string?,
	account_aliases: { string }?,
	plan: string?,
	credit_balance: number?,
	usage_source: string,
	last_reading_at_ms: number?,
	windows: { UsageWindow },
}

export type Account = {
	id: string,
	provider: string,
	provider_label: string,
	account_label: string,
	plan: string?,
	credit_balance: number?,
	usage_source: string,
	last_reading_at_ms: number?,
	windows: { UsageWindow },
}

type WindowObservation = {
	window: UsageWindow,
	source_id: string,
}

type Group = {
	account_id: string,
	metadata: Reading,
	plan_reading: Reading?,
	label_reading: Reading,
	windows: { [string]: { [string]: WindowObservation } },
}

-- Tied observations choose the lexically smaller source ID, never combined values.
local function newer(time: number?, source_id: string, previous_time: number?, previous_source_id: string): boolean
	local current = time or -math.huge
	local previous = previous_time or -math.huge
	return current > previous or (current == previous and source_id < previous_source_id)
end

-- One spelling per allowance: legacy `weekly`/`all` aliases normalize here only.
function accounts.key_for(window: UsageWindow): string
	return if window.key == "weekly" then "seven_day" else window.key
end
local key_for = accounts.key_for

function accounts.pool_for(window: UsageWindow): string
	return if window.pool == "all" then "default" else window.pool
end
local pool_for = accounts.pool_for

local function principal(reading: Reading): string?
	return reading.canonical_id or reading.account_id
end

type AliasIndex = { [string]: { [string]: string | boolean } }

local function alias_index(readings: { Reading }): AliasIndex
	local aliases: AliasIndex = {}
	for _, reading in readings do
		local canonical = reading.canonical_id
		if canonical == nil then continue end
		local provider = aliases[reading.provider]
		if provider == nil then provider = {}; aliases[reading.provider] = provider end
		local function associate(alias: string)
			-- Host-decoded legacy identities can have canonical_id == account_id.
			-- Their self-reference is not a competing verified association.
			if alias == canonical then return end
			local previous = provider[alias]
			provider[alias] = if previous == nil or previous == canonical then canonical else false
		end
		if reading.account_id ~= nil then associate(reading.account_id) end
		for _, alias in reading.account_aliases or {} do associate(alias) end
	end
	return aliases
end

local function account_for(reading: Reading, aliases: AliasIndex, require_label: boolean?): string?
	local account_id = principal(reading)
	local provider = aliases[reading.provider]
	-- Provider-reported or enriched identities may still need that association.
	local explicit = reading.canonical_id ~= nil and reading.account_aliases ~= nil
		and table.find(reading.account_aliases, reading.canonical_id) ~= nil
	if not explicit and account_id ~= nil and provider ~= nil and provider[account_id] ~= nil then
		local resolved = provider[account_id]
		if type(resolved) ~= "string" then return nil end
		account_id = resolved
	end
	if account_id == nil or string.find(account_id, "%S") == nil
		or (require_label ~= false and (reading.account_label == nil or string.find(reading.account_label, "%S") == nil)) then return nil end
	return account_id
end

-- Share the reducer's verified alias resolution with roster membership. A nil
-- identity remains unresolved; configured labels never establish an identity.
function accounts.resolve_identities(readings: { Reading }): { [Reading]: string }
	local aliases = alias_index(readings)
	local resolved: { [Reading]: string } = {}
	for _, reading in readings do
		local account_id = account_for(reading, aliases, false)
		if account_id ~= nil then resolved[reading] = account_id end
	end
	return resolved
end

local function preferred_label(left: Reading, right: Reading): boolean
	local left_alias = left.canonical_id ~= nil and left.account_id ~= left.canonical_id
	local right_alias = right.canonical_id ~= nil and right.account_id ~= right.canonical_id
	if left_alias ~= right_alias then return left_alias end
	return newer(left.last_reading_at_ms, left.id, right.last_reading_at_ms, right.id)
end

-- A partial observation must not discard a known reset in the same allowance
-- cycle. A lower counter or a passed reset is evidence against carrying it.
local function combine_window(latest: UsageWindow, earlier: UsageWindow): UsageWindow
	local result = table.clone(latest)
	if result.resets_at_ms == nil and result.reset_label ~= nil and result.reset_label ~= earlier.reset_label then return result end
	if earlier.resets_at_ms == nil or earlier.resets_at_ms <= latest.observed_at_ms then return result end
	if latest.used == nil or earlier.used == nil or latest.used < earlier.used then return result end
	local earlier_time = earlier.reset_observed_at_ms or earlier.observed_at_ms
	local latest_time = latest.reset_observed_at_ms or latest.observed_at_ms
	if result.resets_at_ms ~= nil and (latest_time > earlier_time
		or (latest_time == earlier_time and result.resets_at_ms <= earlier.resets_at_ms)) then return result end
	result.resets_at_ms = earlier.resets_at_ms
	result.reset_label = earlier.reset_label
	result.reset_calendar = earlier.reset_calendar
	result.reset_observed_at_ms = earlier_time
	return result
end

function accounts.group(readings: { Reading }): ({ Account }, { Reading })
	local by_provider: { [string]: { [string]: Group } } = {}
	local groups: { Group } = {}
	local unresolved: { Reading } = {}

	local aliases = alias_index(readings)
	for _, reading in readings do
		-- Identity comes from accepted provider associations, never labels.
		local account_id = account_for(reading, aliases)
		if account_id == nil then
			table.insert(unresolved, reading)
			continue
		end

		local provider_groups = by_provider[reading.provider]
		if provider_groups == nil then
			provider_groups = {}
			by_provider[reading.provider] = provider_groups
		end
		local group = provider_groups[account_id]
		if group == nil then
			group = { account_id = account_id, metadata = reading, label_reading = reading, windows = {} }
			provider_groups[account_id] = group
			table.insert(groups, group)
		elseif newer(reading.last_reading_at_ms, reading.id, group.metadata.last_reading_at_ms, group.metadata.id) then
			group.metadata = reading
		end
		if preferred_label(reading, group.label_reading) then group.label_reading = reading end

		local plan_reading = group.plan_reading
		if reading.plan ~= nil and (plan_reading == nil
			or newer(reading.last_reading_at_ms, reading.id, plan_reading.last_reading_at_ms, plan_reading.id)) then
			group.plan_reading = reading
		end

		-- Each key/pool is a separate allowance observation, including model pools.
		for _, window in reading.windows do
			local key, pool = key_for(window), pool_for(window)
			local pools = group.windows[key]
			if pools == nil then
				pools = {}
				group.windows[key] = pools
			end
			local previous = pools[pool]
			if previous == nil then
				local copy = table.clone(window)
				copy.key, copy.pool = key, pool
				pools[pool] = { window = copy, source_id = reading.id }
			elseif newer(window.observed_at_ms, reading.id, previous.window.observed_at_ms, previous.source_id) then
				local copy = combine_window(window, previous.window)
				copy.key, copy.pool = key, pool
				pools[pool] = { window = copy, source_id = reading.id }
			else
				previous.window = combine_window(previous.window, window)
			end
		end
	end

	local grouped: { Account } = {}
	for _, group in groups do
		local windows: { UsageWindow } = {}
		-- Discovery/login placeholders are account state, not additional allowances.
		local has_allowance = false
		for key, pools in group.windows do
			if key ~= "observation" and key ~= "subscription" then has_allowance = true; break end
			for _, observation in pools do
				if observation.window.used ~= nil then has_allowance = true; break end
			end
			if has_allowance then break end
		end
		for _, pools in group.windows do
			for _, observation in pools do
				if has_allowance and observation.window.used == nil
					and (observation.window.key == "observation" or observation.window.key == "subscription") then continue end
				-- Copy the whole winning observation, preserving reset and unavailable data.
				table.insert(windows, table.clone(observation.window))
			end
		end
		table.sort(windows, function(left: UsageWindow, right: UsageWindow): boolean
			return left.key < right.key or (left.key == right.key and left.pool < right.pool)
		end)
		local metadata = group.metadata
		local plan_reading = group.plan_reading
		table.insert(grouped, {
			id = group.account_id,
			provider = metadata.provider,
			provider_label = metadata.provider_label,
			account_label = group.label_reading.account_label :: string,
			plan = if plan_reading ~= nil then plan_reading.plan else nil,
			credit_balance = metadata.credit_balance,
			usage_source = metadata.usage_source,
			last_reading_at_ms = metadata.last_reading_at_ms,
			windows = windows,
		})
	end
	table.sort(grouped, function(left: Account, right: Account): boolean
		return left.id < right.id
	end)
	return grouped, unresolved
end

type RetainedObservation = { window: UsageWindow, reading: Reading }
type RetainedGroup = {
	identity: Reading,
	plan: Reading?,
	windows: { [string]: { [string]: RetainedObservation } },
}

local function numeric(window: UsageWindow): boolean
	return window.unavailable_reason == nil and window.used ~= nil and window.remaining ~= nil
end

local function older_cycle(window: UsageWindow, previous: UsageWindow): boolean
	return window.resets_at_ms ~= nil and window.resets_at_ms <= previous.observed_at_ms
		and (previous.resets_at_ms == nil or window.resets_at_ms < previous.resets_at_ms)
end

-- Inputs have already passed the host Reading decoder. Keep one genuine numeric
-- observation per identified Muse account/key/pool, not a rolling source history.
-- Legacy last-good inventory (pre-2.0 publishers) arrives as ordinary readings;
-- the projection replaces cold/unavailable Muse sources with these observations,
-- which keep their original times even after their reset has passed.
-- No clock, inferred zero, or inferred next reset is introduced here.
function accounts.retain_muse(readings: { Reading }, consumers: { [Reading]: boolean }?): ({ Reading }, { Reading })
	local aliases = alias_index(readings)
	-- Headless source publication already owns durable, definition-fenced
	-- retention. Do not let the legacy Muse history erase its failure markers.
	local managed: { [string]: boolean } = {}
	for _, reading in readings do
		if reading.provider == "muse" and reading.usage_source == "headless" then
			local account_id = account_for(reading, aliases, false)
			if account_id ~= nil then managed[account_id] = true end
		end
	end
	local groups: { [string]: RetainedGroup } = {}
	for _, reading in readings do
		if reading.provider ~= "muse" or reading.agent_id == "omp" or (consumers ~= nil and consumers[reading]) then continue end
		local account_id = account_for(reading, aliases, false)
		if account_id == nil or managed[account_id] then continue end
		local group = groups[account_id]
		if group == nil then
			group = { identity = reading, windows = {} }
			groups[account_id] = group
		end
		if preferred_label(reading, group.identity) then group.identity = reading end
		local plan = group.plan
		if reading.plan ~= nil and (plan == nil
			or newer(reading.last_reading_at_ms, reading.id, plan.last_reading_at_ms, plan.id)) then group.plan = reading end
		for _, window in reading.windows do
			if not numeric(window) then continue end
			local key, pool = key_for(window), pool_for(window)
			local pools = group.windows[key]
			if pools == nil then pools = {}; group.windows[key] = pools end
			local previous = pools[pool]
			if previous == nil then
				pools[pool] = { window = table.clone(window), reading = reading }
			elseif older_cycle(window, previous.window) then
				continue
			elseif older_cycle(previous.window, window)
				or newer(window.observed_at_ms, reading.id, previous.window.observed_at_ms, previous.reading.id) then
				pools[pool] = { window = combine_window(window, previous.window), reading = reading }
			else
				previous.window = combine_window(previous.window, window)
			end
		end
	end

	local next_stored: { Reading } = tern.json.array()
	local retained: { [string]: boolean } = {}
	for account_id, group in groups do
		for key, pools in group.windows do
			for pool, observation in pools do
				local saved = table.clone(observation.reading)
				saved.canonical_id = account_id
				saved.account_id = group.identity.account_id
				saved.account_label = group.identity.account_label
				saved.principal_id = group.identity.principal_id
				local account_aliases = group.identity.account_aliases
				saved.account_aliases = nil
				if account_aliases ~= nil then
					local copied = tern.json.array()
					for _, alias in account_aliases do table.insert(copied, alias) end
					saved.account_aliases = copied
				end
				local plan = group.plan
				saved.plan = if plan ~= nil then plan.plan else nil
				local window = table.clone(observation.window)
				window.key, window.pool = key, pool
				saved.windows = { window }
				table.insert(next_stored, saved)
				retained[account_id] = true
			end
		end
	end
	table.sort(next_stored, function(left: Reading, right: Reading): boolean
		local left_id, right_id = left.canonical_id :: string, right.canonical_id :: string
		if left_id ~= right_id then return left_id < right_id end
		local left_window, right_window = left.windows[1], right.windows[1]
		return left_window.key < right_window.key
			or (left_window.key == right_window.key and left_window.pool < right_window.pool)
	end)
	local projected: { Reading } = tern.json.array()
	for _, reading in readings do
		local account_id = if reading.provider == "muse" and reading.agent_id ~= "omp"
			and not (consumers ~= nil and consumers[reading]) then account_for(reading, aliases, false) else nil
		if account_id == nil or not retained[account_id] then table.insert(projected, reading) end
	end
	for _, reading in next_stored do table.insert(projected, reading) end
	return projected, next_stored
end

return accounts
