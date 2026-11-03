--!strict
-- Applies one projected helper response (metadata + usage) to a source reading.
local identity = require("./identity")
local enrichment = {}

function enrichment.apply(reading: any, response: any): (any, string?)
	local result = table.clone(reading)
	result.windows = tern.json.array()
	for _, window in reading.windows do table.insert(result.windows, table.clone(window)) end
	local metadata = response.metadata
	local reported = identity.metadata(reading.provider, metadata)
	if reported ~= nil then
		local aliases = identity.aliases(reading.provider, metadata)
		if (reading.principal_id ~= nil and reading.principal_id ~= reported.principal_id)
			or (reading.canonical_id ~= nil and table.find(aliases, reading.canonical_id) == nil) then
			return result, "Source metadata disagrees with the reading's account identity"
		end
		result.account_id, result.account_label = reported.id, reported.label
		result.canonical_id, result.principal_id = reported.canonical_id, reported.principal_id
		result.account_aliases = aliases
		if result.plan == nil and type(metadata.plan) == "string" then result.plan = metadata.plan end
	end
	local usage = response.usage
	if type(usage) == "table" and usage.provider == reading.provider then
		if usage.unavailable_reason ~= nil then
			result.credit_balance = nil
			-- A cold standalone CLI probe cannot invalidate quota already shown
			-- by a reading that still carries measured windows.
			for _, window in result.windows do
				if window.used ~= nil then return result, response.error end
			end
			result.windows = { { key = "subscription", pool = "default", unavailable_reason = usage.unavailable_reason,
				observed_at_ms = usage.observed_at_ms } }
			result.last_reading_at_ms = usage.observed_at_ms
			return result, response.error
		end
		-- The provider's own usage view is authoritative for every pool it reports.
		result.windows = usage.windows
		result.plan = usage.plan or result.plan
		result.credit_balance = usage.credit_balance
		for _, window in usage.windows do
			result.last_reading_at_ms = math.max(result.last_reading_at_ms or 0, window.observed_at_ms)
		end
	end
	return result, response.error
end

return enrichment
