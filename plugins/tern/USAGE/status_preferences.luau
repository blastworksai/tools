--!strict
-- Persisted status-bar selection: master switch plus stable account ids, one closed record in
-- Tern's plugin kv (shared by the host half and every window). Pure: the caller passes the
-- store (`env.get`, `env.set`, `env.exists`, `env.data`), so tests drive it without a runtime.
-- Ids are the SPAWN scope/account ids of roster rows, never labels or percentages.
local M = {}
M.KEY = "usage_status_prefs"
M.VERSION = 1
M.MAX_SELECTED = 16
M.MAX_ROSTER = 64
M.MAX_ID = 1024
-- How many accounts the pre-selection status summary showed; a retained install keeps exactly those.
M.LEGACY_VISIBLE = 3

local FIELDS: { [string]: boolean } = { version = true, migration_complete = true, enabled = true, selected = true }

local function valid_id(value: any): boolean
	return type(value) == "string" and #value > 0 and #value <= M.MAX_ID and not value:find("%c")
end

-- Drops invalid and duplicate ids; keeps order and the selection bound.
function M.clean_ids(list: any): { string }
	local result = tern.json.array()
	if type(list) ~= "table" then return result end
	local seen: { [string]: boolean } = {}
	for _, value in ipairs(list) do
		if valid_id(value) and not seen[value] then
			seen[value] = true
			table.insert(result, value)
			if #result >= M.MAX_SELECTED then break end
		end
	end
	return result
end

local function record(enabled: boolean, complete: boolean, selected: any): any
	return { version = M.VERSION, migration_complete = complete, enabled = enabled, selected = M.clean_ids(selected) }
end

-- Fresh install: master Off, nothing selected.
function M.fresh(): any
	return record(false, true, {})
end

-- A stored record, normalised; nil when it is not exactly the closed shape.
function M.decode(raw: any): any?
	if type(raw) ~= "table" then return nil end
	for key in raw do
		if FIELDS[key] ~= true then return nil end
	end
	if raw.version ~= M.VERSION or type(raw.migration_complete) ~= "boolean"
		or type(raw.enabled) ~= "boolean" or type(raw.selected) ~= "table" then return nil end
	return record(raw.enabled, raw.migration_complete, raw.selected)
end

-- True when data from before this feature is present. Companion data is created by an old
-- install only; the two kv keys are old USAGE settings.
function M.legacy_evidence(env: any): boolean
	local ok, exists = pcall(env.exists, env.data .. "/companion")
	if ok and exists == true then return true end
	for _, key in { "usage_layout", "usage_python" } do
		local read, value = pcall(env.get, key)
		if read and value ~= nil then return true end
	end
	return false
end

-- Reads the record. When there is none, decides fresh or retained BEFORE anything else of this
-- plugin runs, and stores the answer so the decision is made once. A retained install is
-- stored master On with migration pending: the accounts are chosen when a roster is known.
-- A record that cannot be decoded resets to Off/empty (the old choice cannot be recovered).
-- A store that cannot be read changes nothing.
function M.load(env: any): any
	local read, raw = pcall(env.get, M.KEY)
	if not read then return M.fresh() end
	local decoded = if raw ~= nil then M.decode(raw) else nil
	if decoded ~= nil then return decoded end
	local created = if raw == nil and M.legacy_evidence(env) then record(true, false, {}) else M.fresh()
	pcall(env.set, M.KEY, created)
	return created
end

function M.save(env: any, prefs: any): boolean
	return (pcall(env.set, M.KEY, record(prefs.enabled, prefs.migration_complete, prefs.selected)))
end

-- Completes a pending migration with the old first-three projection of `ordered_ids`.
function M.complete_migration(prefs: any, ordered_ids: { string }): any
	if prefs.migration_complete then return prefs end
	local picked = {}
	for index = 1, math.min(#ordered_ids, M.LEGACY_VISIBLE) do table.insert(picked, ordered_ids[index]) end
	return record(prefs.enabled, true, picked)
end

function M.with_enabled(prefs: any, enabled: boolean): any
	return record(enabled, prefs.migration_complete, prefs.selected)
end

-- `roster` maps every current id (a row's id or one it also answers to) to the row's id.
-- Unknown ids are refused, so a removed or changed account cannot be toggled from stale UI.
function M.with_selected(prefs: any, id: string, selected: boolean, roster: { [string]: string }): (any?, string?)
	local canonical = roster[id]
	if canonical == nil or not valid_id(canonical) then return nil, "unknown_account" end
	local others = {}
	for _, value in prefs.selected do
		if roster[value] ~= canonical then table.insert(others, value) end
	end
	if selected then
		if #others >= M.MAX_SELECTED then
			-- Ids no longer in the roster only reserve room; they give way first.
			local kept = {}
			for _, value in others do
				if roster[value] ~= nil then table.insert(kept, value) end
			end
			others = kept
		end
		if #others >= M.MAX_SELECTED then return nil, "selection_full" end
		table.insert(others, canonical)
	end
	return record(prefs.enabled, prefs.migration_complete, others), nil
end

function M.selected_set(prefs: any): { [string]: boolean }
	local set: { [string]: boolean } = {}
	for _, value in prefs.selected do set[value] = true end
	return set
end

-- A row is selected when its own id or an id it also answers to is.
function M.row_selected(set: { [string]: boolean }, row: any): boolean
	if set[row.id] == true then return true end
	for _, alias in row.also_configured or {} do
		if set[alias.id] == true then return true end
	end
	return false
end

-- id (row id and aliases) -> row id, for the rows of a projected model.
function M.roster_map(rows: { any }): { [string]: string }
	local map: { [string]: string } = {}
	for _, row in rows do
		map[row.id] = row.id
		for _, alias in row.also_configured or {} do map[alias.id] = row.id end
	end
	return map
end

return M
