-- Native incarnation-local files. HOST alone initializes/migrates the shared namespace.
local Journal = {}
local Codec = require("./wire/codec")
local ROOT = tern.plugin.data .. "/window-observer"
local NAMESPACE = ROOT .. "/namespace.json"
local LIMIT = 16000000
local function integer(value)
	return type(value) == "number" and value >= 0 and value <= 9007199254740991 and value % 1 == 0
end
local function text(value, limit, empty)
	return type(value) == "string" and #value <= limit and (empty or #value > 0) and not value:find("%c")
end
local function equal(a, b)
	if type(a) ~= type(b) then return false end
	if type(a) ~= "table" then return a == b end
	for key, value in pairs(a) do if not equal(value, b[key]) then return false end end
	for key in pairs(b) do if a[key] == nil then return false end end
	return true
end
-- Hex with a non-reserved prefix is injective on Windows too (case-insensitive,
-- trailing dots/spaces, devices and separators). Bound each directory component.
local function component(value)
	local hex = value:gsub(".", function(byte) return string.format("%02x", string.byte(byte)) end)
	local parts = {}
	for offset = 1, #hex, 120 do table.insert(parts, "x" .. hex:sub(offset, offset + 119)) end
	if #parts == 0 then return "x" end
	return table.concat(parts, "/")
end
local function read(path)
	if not tern.fs.exists(path) then return nil end
	return tern.json.decode(tern.fs.read(path, LIMIT))
end
local function write(path, value)
	tern.fs.mkdir(assert(path:match("^(.*)/[^/]+$")))
	tern.fs.write(path, tern.json.encode(value))
	if not equal(read(path), value) then error("Native journal read-back differs: " .. path) end
end
local function copy(path, value)
	local prior = read(path)
	if prior == nil then write(path, value)
	elseif not equal(prior, value) then error("Legacy/native journal conflict: " .. path) end
end
local function base(namespace) return ROOT .. "/" .. component(namespace) end
local function observer_id(namespace, window, conn, since)
	return "window-" .. namespace .. "-" .. tostring(conn) .. "-" .. string.format("%.0f", since) .. "-" .. window
end
local function identity(namespace, window, conn, since)
	return { version = 1, namespace = namespace, window_key = window, conn = conn, since = since, observer_id = observer_id(namespace, window, conn, since) }
end
local function flat_directory(value)
	local bytes = string.format("spawn-window-incarnation-v1\n%d:%s%d:%s%.0f:%.0f", #value.namespace, value.namespace, #value.window_key, value.window_key, value.conn, value.since)
	-- Keep complete ordinary Windows paths below the existing path budget.
	-- The 224-bit locator is not identity: full identity is checked on every open.
	return base(value.namespace) .. "/windows/i" .. Codec.sha256(bytes):sub(1, 56)
end
local function layout(root, status)
	if type(status) ~= "table" or status.layout ~= "flat-v1" then error("Unsupported native window journal layout; preserve existing native files") end
	for key in pairs(status) do if key ~= "phase" and key ~= "layout" then error("Unsupported native window journal metadata; preserve existing native files") end end
	if status.phase ~= "copying" and status.phase ~= "deleting" and status.phase ~= "cleanup" and status.phase ~= "ready" then error("Unsupported native window journal phase") end
	local windows = root .. "/windows"
	if tern.fs.exists(windows) then
		for _, name in ipairs(tern.fs.list(windows)) do
			if #name ~= 57 or not name:match("^i[0-9a-f]+$") then error("Unsupported native window journal layout; preserve existing native files") end
		end
	end
end
local function namespace_value()
	local namespace = read(NAMESPACE)
	if not text(namespace, 96) then error("HOST-created observer namespace is unavailable; open SPAWN Config on this machine") end
	return namespace
end
-- This receives the actual bounded native process result, not a caller's partial
-- client list. Missing/ambiguous/malformed inventory never downgrades identity.
function Journal.client_inventory(result)
	if type(result) ~= "table" or result.status ~= 0 or result.timed_out
		or result.truncated or result.stdout_truncated or type(result.stdout) ~= "string" or #result.stdout > 2000000 then
		return nil, "Complete native client inspection is unavailable"
	end
	local ok, inventory = pcall(tern.json.decode, result.stdout)
	if not ok or type(inventory) ~= "table" or type(inventory.clients) ~= "table" or inventory.complete == false or inventory.truncated == true then
		return nil, "Native client inventory is incomplete or invalid"
	end
	local windows, count = {}, 0
	for index, entry in pairs(inventory.clients) do
		count += 1
		if not integer(index) or index < 1 or index > #inventory.clients or type(entry) ~= "table" or not text(entry.kind, 256) then return nil, "Native client inventory is not a complete array" end
		if entry.kind == "window" then
			if not text(entry.window, 256, true) or windows[entry.window] or not integer(entry.conn) or not integer(entry.since) then return nil, "Native client incarnation is ambiguous or invalid" end
			windows[entry.window] = { window_key = entry.window, conn = entry.conn, since = entry.since }
		end
	end
	if count ~= #inventory.clients then return nil, "Native client inventory is not a complete array" end
	return windows, nil, inventory
end
function Journal.incarnation(window, result)
	if not text(window, 256, true) then return nil, "Native window identity is invalid" end
	local windows, why = Journal.client_inventory(result)
	if not windows then return nil, why end
	if not windows[window] then return nil, "Native client incarnation is unavailable" end
	return windows[window]
end
function Journal.same_recipient(a, b)
	return type(a) == "table" and type(b) == "table" and a.observer_id == b.observer_id
		and a.window_key == b.window_key and a.conn == b.conn and a.since == b.since
end
local function finish_migration(root)
	-- These copies are recovery inputs only until legacy deletion is durable.
	-- Current incarnations already own their equal-value cache copies.
	local index = read(root .. "/index.json")
	for _, name in ipairs({ "spawn.intents.v1.json", "spawn.records-seen.v1.json", "index.json" }) do
		-- An unindexed legacy exclusion cache has no incarnation copy. Retain it
		-- in place as unresolved migration evidence, not as a seed for new windows.
		if name == "spawn.intents.v1.json" and (type(index) ~= "table" or next(index) == nil) then
			local intents = read(root .. "/" .. name)
			if type(intents) ~= "table" or next(intents) ~= nil then continue end
		end
		local path = root .. "/" .. name
		if tern.fs.exists(path) then tern.fs.remove(path) end
		if tern.fs.exists(path) then error("Migration copy cleanup is incomplete: " .. path) end
	end
	write(root .. "/migration.json", { phase = "ready", layout = "flat-v1" })
end
function Journal.host_initialize(create_namespace)
	if tern.context ~= "host" then return nil, "Only HOST may initialize or migrate window journals" end
	local ok, value = pcall(function()
		local namespace = read(NAMESPACE)
		local legacy = tern.kv.get("window-observer-namespace")
		if namespace == nil then
			if legacy == nil and tern.fs.exists(ROOT) then error("Native observer namespace is missing; preserve the existing window journals") end
			namespace = if legacy ~= nil then legacy else create_namespace()
			if not text(namespace, 96) then error("Invalid HOST observer namespace") end
			copy(NAMESPACE, namespace)
		elseif not text(namespace, 96) or (legacy ~= nil and legacy ~= namespace) then error("Observer namespace conflicts with legacy state") end
		local root = base(namespace)
		local status = read(root .. "/migration.json")
		if status == nil then
			if tern.fs.exists(root) and #tern.fs.list(root) > 0 then error("Unsupported native window journal layout; preserve existing native files") end
			status = { phase = "copying", layout = "flat-v1" }
			write(root .. "/migration.json", status)
		end
		layout(root, status)
		if status and status.phase == "ready" then return namespace end
		if status and status.phase == "cleanup" then finish_migration(root);return namespace end
		local index_key = "window-observer-index:" .. namespace
		local index = tern.kv.get(index_key)
		if index == nil then index = read(root .. "/index.json") or {} end
		if type(index) ~= "table" then error("Legacy observer index is invalid") end
		copy(root .. "/index.json", index)
		local keys, directories, identities = {}, {}, {}
		for key, entry in pairs(index) do
			if type(key) ~= "string" or type(entry) ~= "table" or not text(entry.window, 256, true) then error("Legacy observer index entry is invalid") end
			local prefix = "window-observer:window-" .. namespace .. "-"
			if key:sub(1, #prefix) ~= prefix then error("Legacy observer namespace mismatch") end
			local conn, since, window = key:sub(#prefix + 1):match("^(%d+)%-(%d+)%-(.*)$")
			conn, since = tonumber(conn), tonumber(since)
			if not integer(conn) or not integer(since) or window ~= entry.window then error("Legacy observer incarnation is invalid") end
			local full_identity = identity(namespace, window, conn, since)
			local current_directory = flat_directory(full_identity)
			-- Existing identities are ownership evidence, not publication work.
			-- Check every destination before copying any incarnation obligations.
			local identity_path = current_directory .. "/identity.json"
			if tern.fs.exists(identity_path) and not equal(read(identity_path), full_identity) then
				error("Legacy/native journal identity conflict: " .. identity_path)
			end
			table.insert(keys, key)
			table.insert(directories, current_directory)
			table.insert(identities, full_identity)
		end
		for index, key in ipairs(keys) do
			local path = directories[index] .. "/observer.json"
			local saved = tern.kv.get(key)
			-- The legacy window indexed itself before its first save, and read a
			-- missing journal as this empty initial value. Preserve that contract
			-- only while copying; missing native state after deletion is still loss.
			if saved == nil and status.phase == "copying" then
				saved = { version = 2, id = key:sub(17), transports = {}, tracked = {}, next_run = 1 }
			end
			if saved ~= nil then
				if type(saved) ~= "table" or saved.version ~= 2 or saved.id ~= key:sub(17) then error("Legacy observer journal identity is invalid") end
				copy(path, saved)
			elseif not (status and status.phase == "deleting" and read(path) ~= nil) then error("Indexed legacy journal is missing; migration is incomplete") end
		end
		for _, key in ipairs({ "spawn.records-seen.v1", "spawn.intents.v1" }) do
			local saved = tern.kv.get(key)
			local path = root .. "/" .. key .. ".json"
			if saved ~= nil then
				if type(saved) ~= "table" then error("Legacy window cache is invalid: " .. key) end
				copy(path, saved)
			elseif read(path) == nil then copy(path, {}) end
			local value = read(path)
			for _, current_directory in ipairs(directories) do
				copy(current_directory .. "/" .. key .. ".json", value)
			end
			table.insert(keys, key)
		end
		-- Publish each identity only after its observer and both obligation caches
		-- have complete verified copies. Only this migration may resume partial leaves.
		for index, current_directory in ipairs(directories) do
			copy(current_directory .. "/identity.json", identities[index])
		end
		-- All sources have equal-value native read-back before the first deletion.
		-- Keep the index until last, so interruption resumes the exact source set.
		write(root .. "/migration.json", { phase = "deleting", layout = "flat-v1" })
		for _, key in ipairs(keys) do tern.kv.set(key, nil) end
		tern.kv.set(index_key, nil)
		tern.kv.set("window-observer-namespace", nil)
		write(root .. "/migration.json", { phase = "cleanup", layout = "flat-v1" })
		finish_migration(root)
		return namespace
	end)
	return if ok then value else nil, if ok then nil else "Window journal migration incomplete: " .. tostring(value)
end
local function empty(value) return type(value) == "table" and next(value) == nil end
local function fields(value, allowed)
	if type(value) ~= "table" then return false end
	for key in pairs(value) do if not allowed[key] then return false end end
	return true
end
local function required_state(path, id)
	local observer = read(path .. "/observer.json")
	local intents = read(path .. "/spawn.intents.v1.json")
	local records = read(path .. "/spawn.records-seen.v1.json")
	if type(observer) ~= "table" or observer.id ~= id or type(intents) ~= "table" or type(records) ~= "table" then
		error("Native journal obligation state is missing or unreadable; preserve this incarnation")
	end
	return observer, intents, records
end
local function stored_identity(namespace, path)
	local value = read(path .. "/identity.json")
	if not fields(value, { version = true, namespace = true, window_key = true, conn = true, since = true, observer_id = true })
		or value.version ~= 1 or value.namespace ~= namespace or not text(value.window_key, 256, true)
		or not integer(value.conn) or not integer(value.since) or flat_directory(value) ~= path
		or value.observer_id ~= observer_id(namespace, value.window_key, value.conn, value.since) then return nil end
	return value
end
-- Capture candidates BEFORE starting the native inspection. A complete inventory
-- from an earlier asynchronous turn cannot prove a later-created leaf has ended.
function Journal.capture()
	local ok, captured = pcall(function()
		local namespace = namespace_value()
		local root = base(namespace)
		local status = read(root .. "/migration.json")
		layout(root, status)
		if status.phase ~= "ready" then error("HOST window journal migration is incomplete") end
		local result = { namespace = namespace, leaves = {} }
		local windows = root .. "/windows"
		if tern.fs.exists(windows) then
			for _, name in ipairs(tern.fs.list(windows)) do
				local path = windows .. "/" .. name
				local readable, value = pcall(stored_identity, namespace, path)
				if readable and value then table.insert(result.leaves, { path = path, identity = value }) end
			end
		end
		return result
	end)
	return if ok then captured else nil, if ok then nil else tostring(captured)
end
local function disposable(path, id, incarnation)
	-- Inspect every file before removal. Unknown extensions/schema, unreadable
	-- caches, legacy exclusions and all tracked history are obligations, not age.
	local identity_seen, observer_seen, intents_seen, records_seen = false, false, false, false
	for _, name in ipairs(tern.fs.list(path)) do
		local value = read(path .. "/" .. name)
		if name == "identity.json" then
			if incarnation == nil or not equal(value, incarnation) then return false end
			identity_seen = true
			continue
		end
		if name == "observer.json" then
			if not fields(value, { version = true, id = true, transports = true, tracked = true, next_run = true, restart_notices = true })
				or value.version ~= 2 or value.id ~= id or not integer(value.next_run) or value.next_run < 1
				or not empty(value.transports) or not empty(value.tracked)
				or (value.restart_notices ~= nil and not empty(value.restart_notices)) then return false end
			observer_seen = true
		elseif name == "spawn.intents.v1.json" then
			if not empty(value) then return false end
			intents_seen = true
		elseif name == "spawn.records-seen.v1.json" then
			if type(value) ~= "table" then return false end
			for host, count in pairs(value) do if not text(host, 1024) or not integer(count) then return false end end
			records_seen = true
		else return false end
	end
	return identity_seen and observer_seen and intents_seen and records_seen
end
local function retire(namespace, windows, captured)
	if type(captured) ~= "table" or captured.namespace ~= namespace or type(captured.leaves) ~= "table" then return end
	local function retire_leaf(candidate)
		local value = stored_identity(namespace, candidate.path)
		if value == nil or not equal(value, candidate.identity) then return end
		local live = windows[value.window_key]
		if live and live.conn == value.conn and live.since == value.since then return end
		if disposable(candidate.path, value.observer_id, value) then tern.fs.remove(candidate.path) end
	end
	for _, candidate in ipairs(captured.leaves) do pcall(retire_leaf, candidate) end
end
function Journal.open(window, result, captured)
	if not text(window, 256, true) then return nil, "Native window identity is invalid" end
	local windows, why = Journal.client_inventory(result)
	if not windows then return nil, why end
	local incarnation = windows[window]
	if not incarnation then return nil, "Native client incarnation is unavailable" end
	local ok, handle = pcall(function()
		local namespace = namespace_value()
		local root = base(namespace)
		local status = read(root .. "/migration.json")
		layout(root, status)
		if type(status) ~= "table" or status.phase ~= "ready" then error("HOST window journal migration is incomplete") end
		-- Reuse this complete native observation; no second inventory or index.
		-- Cleanup failure retains the remaining candidates and never blocks opening.
		pcall(retire, namespace, windows, captured)
		local id = observer_id(namespace, window, incarnation.conn, incarnation.since)
		if #id > 200 then error("Native observer identity exceeds the supported length") end
		local full_identity = identity(namespace, window, incarnation.conn, incarnation.since)
		local path = flat_directory(full_identity)
		local saved_identity = read(path .. "/identity.json")
		local saved
		if tern.fs.exists(path) or saved_identity ~= nil then
			if not equal(saved_identity, full_identity) then error("Native journal identity is missing or differs; preserve this directory") end
			saved = required_state(path, id)
		else
			saved = { version = 2, id = id, transports = {}, tracked = {}, next_run = 1 }
			write(path .. "/observer.json", saved)
			write(path .. "/spawn.intents.v1.json", {})
			write(path .. "/spawn.records-seen.v1.json", {})
			write(path .. "/identity.json", full_identity)
		end
		incarnation.observer_id = id
		local result_handle = { id = id, path = path, root = root, recipient = incarnation, observer = saved, identity = full_identity }
		return result_handle
	end)
	return if ok then handle else nil, if ok then nil else tostring(handle)
end
local function existing_state(handle)
	if not equal(read(handle.path .. "/identity.json"), handle.identity) then error("Native journal identity changed; preserve this incarnation") end
	return required_state(handle.path, handle.id)
end
function Journal.save(handle, observer)
	existing_state(handle)
	write(handle.path .. "/observer.json", observer)
end
function Journal.cache(handle, name)
	if name ~= "spawn.records-seen.v1" and name ~= "spawn.intents.v1" then error("Unsupported window cache") end
	local _, intents, records = existing_state(handle)
	local value = if name == "spawn.intents.v1" then intents else records
	return value
end
function Journal.save_cache(handle, name, value)
	if name ~= "spawn.records-seen.v1" and name ~= "spawn.intents.v1" then error("Unsupported window cache") end
	existing_state(handle)
	write(handle.path .. "/" .. name .. ".json", value)
end
return Journal
