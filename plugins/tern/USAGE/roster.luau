--!strict
-- SPAWN defines membership; observations only supply measurements for those rows.
-- The roster itself is validated by snapshot.decode.
local accounts = require("./accounts")
local roster = {}

local function row_id(scope: string, entry: string): string
	return "spawn:" .. tostring(#scope) .. ":" .. scope .. ":" .. entry
end

-- Latest definitions win as a whole. Only copies of that revision can contribute
-- local associations; an older revision cannot resurrect a removed entry.
local function selected(snapshots: any): { any }
	local winners, copies = {}, {}
	for publisher, source in snapshots do
		for _, scope in if source.roster ~= nil then source.roster.scopes else {} do
			local item = { scope = scope, publisher = publisher, source = source }
			local previous = winners[scope.id]
			if previous == nil or scope.updated_at_ms > previous.scope.updated_at_ms
				or (scope.updated_at_ms == previous.scope.updated_at_ms and publisher < previous.publisher) then
				winners[scope.id] = item
			end
			if copies[scope.id] == nil then copies[scope.id] = {} end
			table.insert(copies[scope.id], item)
		end
	end
	local result = {}
	for id, winner in winners do
		winner.copies = {}
		for _, copy in copies[id] do
			if copy.scope.revision == winner.scope.revision then table.insert(winner.copies, copy) end
		end
		table.insert(result, winner)
	end
	table.sort(result, function(a, b) return a.scope.id < b.scope.id end)
	return result
end

local function set(values: { string }): { [string]: boolean }
	local result = {}
	for _, value in values do result[value] = true end
	return result
end


local function matches_identity(reading: accounts.Reading, identity: string, tokens: { [string]: boolean }): boolean
	if tokens[identity] or (reading.canonical_id ~= nil and tokens[reading.canonical_id])
		or (reading.account_id ~= nil and tokens[reading.account_id]) then return true end
	for _, alias in reading.account_aliases or {} do
		if tokens[alias] then return true end
	end
	return false
end

local function conflicting_mappings(mappings: { any }): boolean
	if #mappings < 2 then return false end
	local connected, joined = table.clone(mappings[1]), { [1] = true }
	local count = 1
	while count < #mappings do
		local before = count
		for index, mapping in mappings do
			if joined[index] then continue end
			local overlaps = false
			for token in mapping do if connected[token] then overlaps = true; break end end
			if overlaps then
				joined[index] = true
				count += 1
				for token in mapping do connected[token] = true end
			end
		end
		if count == before then return true end
	end
	return false
end

-- Classification also covers retained/active source observations outside the
-- winning membership revision: a known OMP observation never becomes quota.
function roster.consumer_readings(snapshots: any): { [accounts.Reading]: boolean }
	local result = {}
	for _, source in snapshots do
		local ids = {}
		for _, scope in if source.roster ~= nil then source.roster.scopes else {} do
			for _, consumer in scope.consumers do
				for _, id in consumer.reading_ids do ids[id] = true end
			end
		end
		for _, reading in source.readings do
			if ids[reading.id] or reading.agent_id == "omp" then result[reading] = true end
		end
	end
	return result
end

-- Rows: one per SPAWN definition, except that a provider login proven by readings
-- in definitions from different SPAWN host scopes is one account (the first scope
-- in id order keeps the row and lists the others in `also_configured`). The same
-- login under two definitions of one scope stays an identity_conflict.
function roster.project(snapshots: any, readings: { accounts.Reading }, current: { accounts.Reading }, excluded: any?): (any, any, any)
	local scopes = selected(snapshots)
	local all = {}
	for _, reading in readings do table.insert(all, reading) end
	for _, reading in current do table.insert(all, reading) end
	local identities = accounts.resolve_identities(all)
	local consumer_readings = excluded or roster.consumer_readings(snapshots)
	local rows, consumers, matched = tern.json.array(), tern.json.array(), {}
	local configured = {}
	local accounts_by_login: { [string]: any } = {}
	for _, winner in scopes do
		local pending, owners = {}, {}
		for _, definition in winner.scope.accounts do
			local tokens, direct, candidates = {}, {}, {}
			local mappings = {}
			for _, copy in winner.copies do
				for _, entry in copy.scope.accounts do
					if entry.id ~= definition.id or entry.provider ~= definition.provider then continue end
					for _, id in entry.canonical_ids do tokens[id] = true end
					if #entry.canonical_ids > 0 then table.insert(mappings, set(entry.canonical_ids)) end
					local wanted = set(entry.reading_ids)
					for _, reading in copy.source.readings do
						if wanted[reading.id] and reading.provider == definition.provider and not consumer_readings[reading] then
							direct[reading] = true
							local identity = identities[reading]
							if identity ~= nil then candidates[identity] = true end
						end
					end
				end
			end
			for _, mapping in mappings do
				for _, reading in all do
					local resolved = identities[reading]
					if reading.provider == definition.provider and resolved ~= nil and matches_identity(reading, resolved, mapping) then
						mapping[resolved] = true
					end
				end
			end
			for _, reading in all do
				if reading.provider ~= definition.provider then continue end
				local identity = identities[reading]
				if identity ~= nil and matches_identity(reading, identity, tokens) then candidates[identity] = true end
			end
			local identity, ambiguous = nil, conflicting_mappings(mappings)
			for candidate in candidates do
				if identity ~= nil then ambiguous = true end
				identity = candidate
			end
			local item = { definition = definition, identity = identity, direct = direct, ambiguous = ambiguous }
			-- Within one definition set, competing bindings remain unknown rather
			-- than duplicating a subscription's quota across configured accounts.
			local ownership = if identity ~= nil then definition.provider .. ":" .. identity else nil
			if ownership ~= nil then
				if owners[ownership] ~= nil then owners[ownership].ambiguous = true; item.ambiguous = true
				else owners[ownership] = item end
			end
			for reading in direct do
				-- Direct bindings identify an observation in its source, not a
				-- globally unique raw ID (canonical login matching is above).
				if owners[reading] ~= nil and owners[reading] ~= item then
					owners[reading].ambiguous = true; item.ambiguous = true
				else owners[reading] = item end
			end
			table.insert(pending, item)
		end
		for _, item in pending do
			local definition = item.definition
			table.insert(configured, item)
			local login = if item.identity ~= nil and not item.ambiguous then definition.provider .. ":" .. item.identity else nil
			local kept = if login ~= nil then accounts_by_login[login] else nil
			if kept ~= nil then
				-- Same login configured on another SPAWN host: its quota is already
				-- this earlier row's (selection below is by identity, not definition).
				item.merged_into = kept.item
				table.insert(kept.row.also_configured, { id = row_id(winner.scope.id, definition.id),
					scope = winner.scope.id, account_label = definition.account_label })
				continue
			end
			local id = row_id(winner.scope.id, definition.id)
			local selected_readings, latest_numeric = {}, {}
			if not item.ambiguous then
				local function accepts(reading)
					return reading.provider == definition.provider and not consumer_readings[reading] and reading.agent_id ~= "omp"
						and ((item.identity ~= nil and identities[reading] == item.identity)
							or (item.direct[reading] and reading.canonical_id == nil and reading.account_id == nil))
				end
				for _, reading in readings do
					if accepts(reading) then
						local copy = table.clone(reading)
						-- This copy groups an already-bound display row, not a
						-- provider identity or an alias exported to snapshots/history.
						copy.account_id, copy.canonical_id, copy.principal_id = id, id, id
						copy.account_label, copy.account_aliases = definition.account_label, nil
						table.insert(selected_readings, copy)
						matched[reading] = true
					end
				end
				for _, reading in current do
					if accepts(reading) then
						for _, window in reading.windows do
							if window.used ~= nil and reading.usage_source ~= "last-good" then
								local key = accounts.key_for(window) .. ":" .. accounts.pool_for(window)
								latest_numeric[key] = math.max(latest_numeric[key] or 0, window.observed_at_ms)
							end
						end
					end
				end
			end
			-- Direct-only observations acquire a grouping identity only inside
			-- this configured row. Apply Muse's measured-value reducer here too,
			-- so a newer unavailable window cannot erase a bound retained value.
			if definition.provider == "muse" then
				selected_readings = accounts.retain_muse(selected_readings)
			end
			local grouped = accounts.group(selected_readings)
			local row: any = grouped[1] or { id = id, usage_source = "SPAWN", windows = {} }
			row.provider, row.provider_label, row.account_label = definition.provider, definition.provider_label, definition.account_label
			if #row.windows == 0 then
				row.windows = { { key = "subscription", pool = "default", observed_at_ms = 0, unavailable_reason = "not_reported" } }
			end
			if item.ambiguous then row.unresolved_reason = "identity_conflict" end
			if definition.provider == "muse" then
				for _, window in row.windows do
					if window.used ~= nil and latest_numeric[window.key .. ":" .. window.pool] ~= window.observed_at_ms then
						window.unavailable_reason = "not_yet_measured"
					end
				end
			end
			if login ~= nil then
				row.also_configured = tern.json.array()
				accounts_by_login[login] = { item = item, row = row }
			end
			table.insert(rows, row)
		end
	end
	for _, winner in scopes do
		for _, definition in winner.scope.consumers do
			local labels, seen = tern.json.array(), {}
			for _, copy in winner.copies do
				for _, consumer in copy.scope.consumers do
					if consumer.id ~= definition.id then continue end
					local wanted = set(consumer.reading_ids)
					for _, reading in copy.source.readings do
						local identity = identities[reading]
						if not wanted[reading.id] or identity == nil then continue end
						for _, item in configured do
							local owner = item.merged_into or item
							local label = owner.definition.account_label
							if not item.ambiguous and item.identity == identity and item.definition.provider == reading.provider
								and not seen[label] then
								seen[label] = true
								table.insert(labels, label)
							end
						end
					end
				end
			end
			table.sort(labels)
			table.insert(consumers, { id = row_id(winner.scope.id, definition.id), label = definition.label, account_labels = labels })
		end
	end
	local unresolved = tern.json.array()
	for _, reading in readings do if not matched[reading] then table.insert(unresolved, reading) end end
	return rows, consumers, unresolved
end

return roster
