-- One ordinary file per native window incarnation. Files are coordination, not history.
-- A missing, replaced or unreadable owned file never authorizes recreating it.
local Journal = {}
Journal.MAX_BYTES = 1048576
Journal.MAX_FILES = 64
Journal.LEGACY_KEY = "updater.v1"

local function integer(value)
	return type(value) == "number" and value >= 0 and value <= 9007199254740991 and value % 1 == 0
end
local function text(value, limit)
	return type(value) == "string" and #value <= limit and not value:find("%z") and utf8.len(value) ~= nil
end
local function same_route(a, b)
	return type(a) == "table" and type(b) == "table"
		and a.socket == b.socket and a.config == b.config
end
function Journal.owner_valid(owner)
	return type(owner) == "table" and text(owner.window, 256)
		and integer(owner.conn) and integer(owner.since)
		and type(owner.route) == "table"
		and (owner.route.socket == false or text(owner.route.socket, 4096))
		and (owner.route.config == false or text(owner.route.config, 4096))
end
function Journal.same_owner(a, b)
	return Journal.owner_valid(a) and Journal.owner_valid(b)
		and a.window == b.window and a.conn == b.conn and a.since == b.since
		and same_route(a.route, b.route)
end
function Journal.filename(owner)
	if not Journal.owner_valid(owner) then return nil, "Native window incarnation is unavailable" end
	local key = owner.window:gsub(".", function(byte) return string.format("%02x", string.byte(byte)) end)
	local name = string.format("owner-%s-%.0f-%.0f.json", key, owner.conn, owner.since)
	if #name > 240 then return nil, "Native window key exceeds the filesystem name bound" end
	return name
end
-- A corrupt file's name can prove a matching owner live, never prove its
-- original daemon absent: the recorded connection itself is unavailable.
function Journal.owner_hint(name, route)
	if type(name) ~= "string" then return nil end
	local key, conn, since = name:match("^owner%-(%x*)%-(%d+)%-(%d+)%.json$")
	if key == nil or #key % 2 ~= 0 then return nil end
	local window = key:gsub("%x%x", function(pair)
		local byte = assert(tonumber(pair, 16), "Matched hex pair must decode")
		return string.char(byte)
	end)
	local owner = { window = window, conn = tonumber(conn), since = tonumber(since), route = route }
	return if Journal.owner_valid(owner) then owner else nil
end
local function basename(name)
	return text(name, 255) and name ~= "" and name ~= "." and name ~= ".." and not name:find("[/\\]")
end
local function bounded(value, depth, budget)
	budget.left -= 1
	if budget.left < 0 or depth > 12 then return false end
	if type(value) == "string" then return #value <= Journal.MAX_BYTES end
	if type(value) == "number" then return value == value and math.abs(value) < math.huge end
	if type(value) == "boolean" or value == nil then return true end
	if type(value) ~= "table" then return false end
	for key, item in pairs(value) do
		if (type(key) ~= "string" and type(key) ~= "number") or not bounded(item, depth + 1, budget) then return false end
	end
	return true
end
function Journal.valid(record)
	return type(record) == "table" and record.schema == 2 and Journal.owner_valid(record.owner)
		and text(record.attempt, 160) and record.attempt ~= "" and integer(record.revision)
		and (record.phase == "claiming" or record.phase == "pending" or record.phase == "resolving")
		and type(record.payload) == "table" and bounded(record, 0, { left = 8192 })
end

-- Complete inspect output only. Missing/duplicate/malformed clients are not absence proof.
function Journal.inventory(result, decode)
	if type(result) ~= "table" or result.status ~= 0 or result.timed_out == true
		or result.truncated == true or result.stdout_truncated == true
		or type(result.stdout) ~= "string" or #result.stdout > 2097152 then return nil, "Native window inventory is unavailable" end
	local ok, value = pcall(decode, result.stdout)
	if not ok or type(value) ~= "table" or value.complete == false or value.truncated == true
		or type(value.clients) ~= "table" then return nil, "Native window inventory is incomplete" end
	local rows, windows, connections, count = {}, {}, {}, 0
	for index, row in pairs(value.clients) do
		if not integer(index) or index < 1 or index > #value.clients or type(row) ~= "table"
			or not text(row.kind, 64) or row.kind == "" or not integer(row.conn) or not integer(row.since) then
			return nil, "Native window inventory is malformed"
		end
		count += 1
		if row.kind == "window" then
			if not text(row.window, 256) or not integer(row.conn) or not integer(row.since)
				or windows[row.window] or connections[row.conn] then return nil, "Native window incarnation is ambiguous" end
			windows[row.window], connections[row.conn] = true, true
			table.insert(rows, { window = row.window, conn = row.conn, since = row.since })
		end
	end
	if count ~= #value.clients then return nil, "Native window inventory has gaps" end
	return rows
end
function Journal.incarnation(window, route, rows)
	if type(rows) ~= "table" then return nil, "Native window inventory is unavailable" end
	for _, row in ipairs(rows) do
		if row.window == window then
			local owner = { window = window, conn = row.conn, since = row.since, route = route }
			if Journal.owner_valid(owner) then return owner end
		end
	end
	return nil, "This window is absent from the complete native inventory"
end
function Journal.owner_status(owner, route, rows)
	if not Journal.owner_valid(owner) or not same_route(owner.route, route) or type(rows) ~= "table" then return "unknown" end
	for _, row in ipairs(rows) do
		if row.window == owner.window and row.conn == owner.conn and row.since == owner.since then return "live" end
	end
	return "gone"
end
function Journal.legacy_pending(value)
	if value == nil then return false end
	if type(value) ~= "table" then return true end
	for key in pairs(value) do
		if type(key) ~= "string" or key:sub(1, 8) == "pending_" then return true end
		if key ~= "checked_at" and key ~= "remote" and key ~= "notified" then return true end
		if key == "checked_at" and not integer(value[key]) then return true end
		if (key == "remote" or key == "notified") and (not text(value[key], 128) or value[key] == "") then return true end
	end
	return false
end

function Journal.open(data, owner, fs, encode, decode)
	local name, problem = Journal.filename(owner)
	if name == nil then return nil, problem end
	local directory = data .. "/updater"
	local store = { name = name, owner = owner }
	local function read_file(file)
		if not basename(file) then return { name = file, error = "Invalid updater filename" } end
		local ok, bytes = pcall(fs.read, directory .. "/" .. file, Journal.MAX_BYTES)
		if not ok then return { name = file, error = "Updater file is unreadable" } end
		local decoded, record = pcall(decode, bytes)
		if not decoded or not Journal.valid(record) or Journal.filename(record.owner) ~= file then
			return { name = file, bytes = bytes, error = "Updater file is corrupt or has a different owner" }
		end
		return { name = file, bytes = bytes, record = record }
	end
	store.read = read_file
	function store.scan()
		local ok, names = pcall(fs.list, directory)
		if not ok or type(names) ~= "table" or #names > Journal.MAX_FILES then return nil, "Updater inventory is unreadable or exceeds its bound" end
		local rows, count, seen = {}, 0, {}
		for index, file in pairs(names) do
			if not integer(index) or index < 1 or index > #names or not basename(file) or seen[file] then return nil, "Updater inventory is incomplete" end
			seen[file], count = true, count + 1
			table.insert(rows, read_file(file))
		end
		if count ~= #names then return nil, "Updater inventory has gaps" end
		return rows
	end
	function store.prepare()
		local ok = pcall(fs.mkdir, directory)
		if not ok then return false, "Couldn't create the updater state directory" end
		return true
	end
	function store.current(handle)
		if type(handle) ~= "table" or handle.name ~= name then return nil, "This updater file belongs to another window" end
		local row = read_file(name)
		if row.record == nil or row.bytes ~= handle.bytes or not Journal.same_owner(row.record.owner, owner) then
			return nil, "Updater ownership changed; the saved file was not recreated"
		end
		return row.record
	end
	local function encoded(record)
		if not Journal.valid(record) or not Journal.same_owner(record.owner, owner) then return nil, "Invalid owned updater record" end
		local ok, bytes = pcall(encode, record)
		if not ok or type(bytes) ~= "string" or #bytes > Journal.MAX_BYTES then return nil, "Updater record exceeds its encoding bound" end
		return bytes
	end
	local function write_verified(record, bytes)
		local ok = pcall(fs.write, directory .. "/" .. name, bytes)
		if not ok then return nil, "Updater write failed; existing bytes were retained for resolution" end
		local row = read_file(name)
		if row.bytes ~= bytes or row.record == nil then return nil, "Updater write could not be verified; resolution is required" end
		return { name = name, bytes = bytes, record = record }
	end
	function store.advance(handle, record)
		local current, err = store.current(handle)
		if current == nil then return nil, err end
		if record.attempt ~= current.attempt or record.revision ~= current.revision + 1 then return nil, "Updater transition is stale" end
		local bytes, encoding_error = encoded(record)
		if bytes == nil then return nil, encoding_error end
		return write_verified(record, bytes)
	end
	-- Delete only the bytes just observed, after the caller presents the outcome.
	function store.remove(row, resolution)
		if type(row) ~= "table" or not basename(row.name) or type(row.bytes) ~= "string" then return false, "No exact updater bytes are available" end
		if row.name ~= name and (type(resolution) ~= "table" or resolution.outcome ~= true
			or resolution.owner_status == "live" or (resolution.owner_status ~= "gone" and resolution.owner_stopped_attested ~= true)) then
			return false, "Another owner's file requires a resolved outcome and fresh owner-absence proof or explicit attestation"
		end
		local fresh = read_file(row.name)
		if fresh.bytes ~= row.bytes then return false, "Updater file changed during resolution" end
		if row.name == name and (fresh.record == nil or not Journal.same_owner(fresh.record.owner, owner)) then
			return false, "This filename no longer proves ownership by the recorded native route"
		end
		local ok = pcall(fs.remove, directory .. "/" .. row.name)
		if not ok then return false, "Couldn't remove the resolved updater file" end
		local observed, exists = pcall(fs.exists, directory .. "/" .. row.name)
		if not observed or exists then return false, "Updater removal could not be verified" end
		return true
	end
	-- allowed contains only the explicitly selected resolution target(s), never a
	-- wildcard. Ordinary installers pass no exemptions. Claim precedes the scan.
	function store.claim(record, allowed)
		if record.phase ~= "claiming" and record.phase ~= "resolving" then return nil, "A new updater file must begin with a claim" end
		if allowed ~= nil and record.phase ~= "resolving" then return nil, "Only explicit resolution can name an existing target" end
		local bytes, encoding_error = encoded(record)
		if bytes == nil then return nil, encoding_error end
		local prepared, preparation_error = store.prepare()
		if not prepared then return nil, preparation_error end
		local known, exists = pcall(fs.exists, directory .. "/" .. name)
		if not known or exists then return nil, "This window already has unresolved updater state" end
		local handle, err = write_verified(record, bytes)
		if handle == nil then return nil, err end
		local rows, scan_error = store.scan()
		local blocker = scan_error
		if rows ~= nil then
			for _, row in ipairs(rows) do
				if row.name ~= name and not (allowed and allowed[row.name] == true) then
					blocker = "Another updater file is unresolved: " .. row.name
					break
				end
			end
		end
		if blocker ~= nil then
			local removed, removal_error = store.remove(handle)
			return nil, blocker .. (if removed then "" else "; " .. removal_error)
		end
		return handle
	end
	-- A malformed own file cannot acquire a second file. Explicit resolution may
	-- replace it in place while keeping its exact bytes inside the resolving claim.
	function store.adopt_unknown(row, record)
		if row.name ~= name or (row.record ~= nil and not Journal.same_owner(row.record.owner, owner)) or type(row.bytes) ~= "string"
			or record.phase ~= "resolving" or record.payload.original_base64 ~= tern.base64.encode(row.bytes) then
			return nil, "Unknown updater state requires explicit in-place resolution"
		end
		local bytes, err = encoded(record)
		if bytes == nil then return nil, err end
		if read_file(name).bytes ~= row.bytes then return nil, "Unknown updater file changed before resolution" end
		return write_verified(record, bytes)
	end
	return store
end
return Journal
