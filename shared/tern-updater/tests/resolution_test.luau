local Journal = require("../journal")
local State = require("../state")
local ROOT = "/owned/resolution"
local DIRECTORY = ROOT .. "/updater/"
local function record(name, reference, kind)
	local value = { schema = 2, owner = { window = name, conn = 7, since = 100,
		route = { socket = "/owned/daemon", config = "/owned/config" } },
		attempt = name, revision = 0, phase = if reference then "resolving" else "claiming", payload = { targets = {} } }
	if reference then value.payload.resolving = { name = reference.name, kind = kind or "cleanup", bytes_base64 = tern.base64.encode(reference.bytes) } end
	return value
end
local function row(value)
	return { name = assert(Journal.filename(value.owner)), bytes = tern.json.encode(value), record = value }
end
local function fixture()
	local a = row(record("a"))
	local b = row(record("b", a, "takeover"))
	local c = row(record("c", b))
	local d = record("d", c)
	local files = { [DIRECTORY .. a.name] = a.bytes, [DIRECTORY .. c.name] = c.bytes }
	local faults, fs = {}, {}
	function fs.mkdir(_) end
	function fs.exists(path) return files[path] ~= nil end
	function fs.read(path, limit)
		if path == faults.unreadable or files[path] == nil then error("read unavailable") end
		assert(#files[path] <= limit)
		return files[path]
	end
	function fs.write(path, bytes) files[path] = bytes end
	function fs.remove(path) files[path] = nil end
	function fs.list(_)
		if faults.inventory then error("inventory unavailable") end
		local names = {}
		for path in pairs(files) do table.insert(names, path:sub(#DIRECTORY + 1)) end
		return names
	end
	local store = assert(Journal.open(ROOT, d.owner, fs, tern.json.encode, tern.json.decode))
	return { a = a, b = b, c = c, d = d, files = files, faults = faults, store = store, fs = fs }
end
return {
	{ "interrupted nested cleanup reaches the retained original without recreating its missing resolver", function()
		local f = fixture()
		local original = f.store.read(f.c.name)
		local allowed = assert(State.resolver_dependencies(f.store, original))
		assert(allowed[f.a.name] and allowed[f.b.name] and allowed[f.c.name])
		local handle = assert(f.store.claim(f.d, allowed))
		assert(f.store.remove(original, { outcome = true, owner_status = "gone" }))
		assert(f.store.remove(handle))
		assert(f.files[DIRECTORY .. f.a.name] == f.a.bytes and f.files[DIRECTORY .. f.b.name] == nil
			and f.files[DIRECTORY .. f.c.name] == nil and f.files[DIRECTORY .. f.store.name] == nil)
		local next_record = record("next", f.a, "takeover")
		local next_store = assert(Journal.open(ROOT, next_record.owner, f.fs, tern.json.encode, tern.json.decode))
		assert(next_store.claim(next_record, { [f.a.name] = true }))
		assert(f.files[DIRECTORY .. f.a.name] == f.a.bytes)
	end },
	{ "unreadable present dependencies and unavailable inventories are not absence", function()
		for _, fault in ipairs({ "unreadable", "inventory" }) do
			local f = fixture()
			if fault == "unreadable" then f.files[DIRECTORY .. f.b.name] = f.b.bytes; f.faults.unreadable = DIRECTORY .. f.b.name
			else f.faults.inventory = true end
			local before = tern.json.encode(f.files)
			assert(State.resolver_dependencies(f.store, f.store.read(f.c.name)) == nil)
			assert(tern.json.encode(f.files) == before)
		end
	end },
	{ "missing resolver reconstruction rejects corrupt bytes wrong owners and malformed state", function()
		for _, fault in ipairs({ "base64", "json", "owner", "state" }) do
			local f = fixture()
			local reference = f.c.record.payload.resolving
			if fault == "base64" then reference.bytes_base64 = "%%%"
			elseif fault == "json" then reference.bytes_base64 = tern.base64.encode("{interrupted")
			elseif fault == "owner" then reference.bytes_base64 = tern.base64.encode(tern.json.encode(record("different-owner")))
			else local malformed = f.b.record; malformed.payload.targets = "broken"; reference.bytes_base64 = tern.base64.encode(tern.json.encode(malformed)) end
			f.files[DIRECTORY .. f.c.name] = tern.json.encode(f.c.record)
			assert(State.resolver_dependencies(f.store, f.store.read(f.c.name)) == nil)
			assert(f.files[DIRECTORY .. f.a.name] == f.a.bytes and f.files[DIRECTORY .. f.store.name] == nil)
		end
	end },
	{ "a reconstructed root must retain its exact filename owner identity", function()
		local f = fixture()
		f.c.name = f.b.name
		assert(State.resolver_dependencies(f.store, f.c) == nil)
		assert(f.files[DIRECTORY .. f.a.name] == f.a.bytes and f.files[DIRECTORY .. f.store.name] == nil)
	end },
	{ "a changed live dependency cannot substitute a different retained chain", function()
		local f = fixture()
		local changed = f.b.record; changed.attempt = "replaced"
		f.files[DIRECTORY .. f.b.name] = tern.json.encode(changed)
		assert(State.resolver_dependencies(f.store, f.store.read(f.c.name)) == nil)
		assert(f.files[DIRECTORY .. f.b.name] == tern.json.encode(changed) and f.files[DIRECTORY .. f.a.name] == f.a.bytes)
	end },
	{ "an unrelated pending record still blocks the cleanup claim", function()
		local f = fixture()
		local peer = row(record("unrelated")); f.files[DIRECTORY .. peer.name] = peer.bytes
		local allowed = assert(State.resolver_dependencies(f.store, f.store.read(f.c.name)))
		assert(not allowed[peer.name] and f.store.claim(f.d, allowed) == nil)
		assert(f.files[DIRECTORY .. peer.name] == peer.bytes and f.files[DIRECTORY .. f.a.name] == f.a.bytes
			and f.files[DIRECTORY .. f.c.name] == f.c.bytes and f.files[DIRECTORY .. f.store.name] == nil)
	end },
	{ "an already removed explicitly unknown leaf needs no invented upstream record", function()
		local f = fixture()
		local missing = { name = "unknown.json", bytes = "{interrupted" }
		local unknown = row(record("unknown-resolver", missing, "unknown"))
		local allowed = assert(State.resolver_dependencies(f.store, unknown))
		assert(allowed[unknown.name] and allowed[missing.name] and not allowed[f.a.name])
	end },
}
