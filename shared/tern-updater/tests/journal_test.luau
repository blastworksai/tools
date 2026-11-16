local Journal = require("../journal")
local ROOT = "/owned/plugin-data"
local DIRECTORY = ROOT .. "/updater/"
local function owner(window, conn, route)
	return { window = window or "one", conn = conn or 7, since = 100,
		route = route or { socket = "/owned/daemon", config = "/owned/config" } }
end
local function record(who, phase)
	return { schema = 2, owner = who, attempt = "attempt", revision = 0, phase = phase or "claiming", payload = {} }
end
-- Deterministic filesystem fault injection exercises the real journal protocol;
-- native qualification separately proves these boundaries on actual files.
local function filesystem()
	local files, faults = {}, {}
	local fs = {}
	function fs.mkdir(_) if faults.mkdir then error("mkdir denied") end end
	function fs.exists(path) if faults.exists then error("unreadable existence") end; return files[path] ~= nil end
	function fs.read(path, limit)
		if faults.read == path or files[path] == nil then error("unreadable file") end
		if #files[path] > limit then error("oversized file") end
		return files[path]
	end
	function fs.write(path, bytes)
		if faults.torn then files[path] = bytes:sub(1, 9); error("interrupted write") end
		files[path] = bytes
		if faults.after_write then local action = faults.after_write; faults.after_write = nil; action(path) end
	end
	function fs.list(_)
		if faults.list then error("inventory unavailable") end
		if faults.names then return faults.names end
		local names = {}
		for path in pairs(files) do table.insert(names, path:sub(#DIRECTORY + 1)) end
		table.sort(names)
		return names
	end
	function fs.remove(path) if faults.remove then error("remove denied") end; files[path] = nil end
	return fs, files, faults
end
local function open(who, fs)
	return assert(Journal.open(ROOT, who, fs, tern.json.encode, tern.json.decode))
end
local function next_record(value)
	local out = table.clone(value)
	out.revision += 1
	out.phase = "pending"
	return out
end
return {
	{ "an unresolved peer blocks a claim without deleting peer evidence", function()
		local fs, files = filesystem()
		local a, b = owner(), owner("two", 8)
		local first, second = open(a, fs), open(b, fs)
		local retained = assert(first.claim(record(a)))
		assert(second.claim(record(b)) == nil)
		assert(files[DIRECTORY .. first.name] == retained.bytes and files[DIRECTORY .. second.name] == nil)
	end },
	{ "a peer appearing after own write is caught by the post-claim scan", function()
		local fs, files, faults = filesystem()
		local a, b = owner(), owner("two", 8)
		local store = open(a, fs)
		local peer_name, peer_bytes = assert(Journal.filename(b)), tern.json.encode(record(b))
		faults.after_write = function(_) files[DIRECTORY .. peer_name] = peer_bytes end
		assert(store.claim(record(a)) == nil)
		assert(files[DIRECTORY .. store.name] == nil and files[DIRECTORY .. peer_name] == peer_bytes)
	end },
	{ "corrupt and unreadable peer files remain unresolved blockers", function()
		for _, unreadable in ipairs({ false, true }) do
			local fs, files, faults = filesystem()
			local who = owner()
			local store = open(who, fs)
			local path = DIRECTORY .. "unknown.json"
			files[path] = "{interrupted"
			if unreadable then faults.read = path end
			assert(store.claim(record(who)) == nil)
			assert(files[path] == "{interrupted" and files[DIRECTORY .. store.name] == nil)
		end
	end },
	{ "an incomplete inventory releases only the effect-free own claim", function()
		local fs, files, faults = filesystem()
		local who = owner()
		local store = open(who, fs)
		files[DIRECTORY .. "retained"] = "evidence"
		faults.list = true
		assert(store.claim(record(who)) == nil)
		assert(files[DIRECTORY .. store.name] == nil and files[DIRECTORY .. "retained"] == "evidence")
	end },
	{ "missing or replaced owned files are never recreated by a transition", function()
		for _, replacement in ipairs({ false, "replacement" }) do
			local fs, files = filesystem()
			local who = owner()
			local store = open(who, fs)
			local value = record(who)
			local handle = assert(store.claim(value))
			files[DIRECTORY .. store.name] = if replacement then replacement else nil
			assert(store.advance(handle, next_record(value)) == nil)
			assert(files[DIRECTORY .. store.name] == (if replacement then replacement else nil))
		end
	end },
	{ "stale completion cannot overwrite an advanced record", function()
		local fs, files = filesystem()
		local who = owner()
		local store = open(who, fs)
		local value = record(who)
		local handle = assert(store.claim(value))
		local advanced = assert(store.advance(handle, next_record(value)))
		assert(store.advance(handle, next_record(value)) == nil)
		assert(files[DIRECTORY .. store.name] == advanced.bytes)
	end },
	{ "torn writes retain their bytes and cannot be silently replaced by a new claim", function()
		local fs, files, faults = filesystem()
		local who = owner()
		local store = open(who, fs)
		faults.torn = true
		assert(store.claim(record(who)) == nil)
		local torn = files[DIRECTORY .. store.name]
		assert(torn == tern.json.encode(record(who)):sub(1, 9))
		faults.torn = nil
		assert(store.claim(record(who)) == nil and files[DIRECTORY .. store.name] == torn)
		assert(store.read(store.name).record == nil)
	end },
	{ "foreign removal needs an outcome and cannot override a live owner", function()
		local fs, files = filesystem()
		local a, b = owner(), owner("two", 8)
		local first, second = open(a, fs), open(b, fs)
		local row = assert(first.claim(record(a)))
		assert(not second.remove(row))
		assert(not second.remove(row, { outcome = true, owner_status = "live", owner_stopped_attested = true }))
		assert(not second.remove(row, { outcome = true, owner_status = "unknown" }))
		assert(files[DIRECTORY .. first.name] == row.bytes)
		assert(second.remove(row, { outcome = true, owner_status = "gone" }))
		assert(files[DIRECTORY .. first.name] == nil)
	end },
	{ "resolution refuses changed bytes even after owner absence is proved", function()
		local fs, files = filesystem()
		local a, b = owner(), owner("two", 8)
		local first, second = open(a, fs), open(b, fs)
		local row = assert(first.claim(record(a)))
		files[DIRECTORY .. first.name] = "changed after observation"
		assert(not second.remove(row, { outcome = true, owner_status = "gone" }))
		assert(files[DIRECTORY .. first.name] == "changed after observation")
	end },
	{ "matching window numbers from a different daemon route do not confer ownership", function()
		local fs, files = filesystem()
		local original = owner()
		local replacement = owner("one", 7, { socket = "/other/daemon", config = "/other/config" })
		local first, other = open(original, fs), open(replacement, fs)
		local row = assert(first.claim(record(original)))
		assert(other.current(row) == nil and not other.remove(row))
		assert(files[DIRECTORY .. first.name] == row.bytes)
	end },
	{ "ordinary installers cannot exempt foreign pending files", function()
		local fs, files = filesystem()
		local who = owner()
		local store = open(who, fs)
		files[DIRECTORY .. "foreign.json"] = "unknown"
		assert(store.claim(record(who), { ["foreign.json"] = true }) == nil)
		assert(files[DIRECTORY .. store.name] == nil and files[DIRECTORY .. "foreign.json"] == "unknown")
	end },
	{ "in-place unknown adoption preserves original bytes and fences replacement", function()
		local fs, files = filesystem()
		local who = owner()
		local store = open(who, fs)
		files[DIRECTORY .. store.name] = "{broken"
		local row = store.read(store.name)
		local value = record(who, "resolving")
		value.payload.original_base64 = tern.base64.encode(row.bytes)
		files[DIRECTORY .. store.name] = "new evidence"
		assert(store.adopt_unknown(row, value) == nil)
		assert(files[DIRECTORY .. store.name] == "new evidence")
		row = store.read(store.name)
		value.payload.original_base64 = tern.base64.encode(row.bytes)
		local adopted = assert(store.adopt_unknown(row, value))
		assert(tern.base64.decode(adopted.record.payload.original_base64) == "new evidence")
	end },
	{ "native owner absence needs a complete same-daemon inventory", function()
		local who = owner()
		local function inventory(value)
			return Journal.inventory({ status = 0, stdout = tern.json.encode(value) }, tern.json.decode)
		end
		local live = assert(inventory({ clients = { { kind = "window", window = who.window, conn = who.conn, since = who.since } } }))
		assert(Journal.owner_status(who, who.route, live) == "live")
		local reused = assert(inventory({ clients = { { kind = "window", window = who.window, conn = 99, since = 200 } } }))
		assert(Journal.owner_status(who, who.route, reused) == "gone")
		assert(Journal.owner_status(who, { socket = false, config = false }, reused) == "unknown")
		assert(inventory({ clients = {}, complete = false }) == nil)
		assert(inventory({ clients = { { kind = "window", window = "one", conn = 7, since = 100 },
			{ kind = "window", window = "one", conn = 8, since = 101 } } }) == nil)
		assert(Journal.owner_status(who, who.route, nil) == "unknown")
	end },
	{ "legacy uncertainty blocks while a check-only cache does not", function()
		assert(not Journal.legacy_pending({ checked_at = 100, remote = "1.1.0", notified = "1.1.0" }))
		assert(Journal.legacy_pending({ pending_at = 0 }))
		assert(Journal.legacy_pending({ unexpected = true }))
		assert(Journal.legacy_pending("torn"))
	end },
}
