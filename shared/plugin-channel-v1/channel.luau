--!strict
-- Host-local delivery only. Installed plugins share one OS-user trust boundary.
-- Files and ACKs NEVER prove native authority, consent, freshness or completion.
-- Requires one native host writer per plugin/configuration profile. Plugin data
-- is config-root scoped, NOT socket scoped: independent hosts need separate
-- private TERN_CONFIG_DIR roots. fs.write provides no interprocess exclusion.
local Channel = {}

local SLOT_COUNT = 24
local MAX_BODY = 65536
local MAX_FRAME = 98304
local MAX_TURN = 4
local DIRECTORY = "plugin-channel-v1"
local ACK_HEAD = '{"v":1,"kind":"ack","message":'
local PEERS = { orchplus = { "spawn", "usage" }, spawn = { "orchplus" }, usage = { "orchplus" } }
-- ORCH's two drain slots are exclusively for SPAWN, never USAGE requests.
-- Each peer's own response pool remains independent and bounded by 24.
local SETTLEMENT_PEER = { orchplus = "spawn", spawn = "orchplus", usage = "orchplus" }
local ROUTES = {
	orchplus = {
		spawn = { ["spawn.request"] = true },
		usage = { ["usage.capacity.request"] = true, ["usage.display.request"] = true },
	},
	spawn = { orchplus = {
		["spawn.response"] = true, ["spawn.execution"] = true, ["spawn.current"] = true,
		["spawn.control"] = true, ["spawn.source"] = true, ["spawn.catalog"] = true,
	} },
	usage = { orchplus = { ["usage.capacity.response"] = true, ["usage.display.response"] = true } },
}

local function token(value: any, maximum: number): boolean
	return type(value) == "string" and #value >= 1 and #value <= maximum
		and value:match("^[A-Za-z0-9_.:-]+$") ~= nil
end

local function integer(value: any, low: number, high: number): boolean
	return type(value) == "number" and value >= low and value <= high and value == math.floor(value)
end

local function route_allowed(from: any, to: any, route: any): boolean
	if type(from) ~= "string" or type(to) ~= "string" or type(route) ~= "string" then return false end
	local destinations = (ROUTES :: any)[from]
	return destinations ~= nil and destinations[to] ~= nil and destinations[to][route] == true
end

local function failure(code: string, operation: string, peer: string?, slot: number?): any
	return { code = code, operation = operation, peer = peer, slot = slot }
end

local function data_root(value: any, plugin: string): string?
	if type(value) ~= "string" or #value == 0 or #value > 4096 or value:find("[%z\1-\31\127]") then return nil end
	local path = value:gsub("\\", "/"):gsub("/+$", "")
	if path:sub(1, 1) ~= "/" and not path:match("^[A-Za-z]:/") then return nil end
	local rest = if path:sub(1, 2) == "//" then path:sub(3) else path:sub(2)
	if rest:find("//", 1, true) then return nil end
	for component in path:gmatch("[^/]+") do
		if component == "." or component == ".." then return nil end
	end
	local parent, leaf = path:match("^(.*)/([^/]+)$")
	if parent == nil or parent == "" or leaf ~= plugin then return nil end
	return parent
end

-- Every string interpolated here is either a closed enum, a safe token or
-- canonical standard base64. Canonical byte equality also rejects duplicate,
-- unknown and null members, escaped spellings, trailing bytes and extra roots.
local function encode_frame(frame: any, encoded: string): string
	return '{"v":1,"kind":"message","from":"' .. frame.peer
		.. '","to":"' .. frame.recipient .. '","incarnation":"' .. frame.incarnation
		.. '","id":"' .. frame.id .. '","route":"' .. frame.route
		.. '","binding":"' .. frame.binding .. '","slot":' .. tostring(frame.slot)
		.. ',"body_bytes":' .. tostring(#frame.body) .. ',"body":"' .. encoded .. '"}'
end

local function ack_frame(raw: string): string
	return ACK_HEAD .. raw .. "}"
end

function Channel.open(options: any): (any?, any?)
	if type(options) ~= "table" or type(options.plugin_id) ~= "string" or (PEERS :: any)[options.plugin_id] == nil
		or not token(options.incarnation, 80) then return nil, failure("invalid_options", "open") end
	local plugin: string = options.plugin_id
	local parent = data_root(options.plugin_data, plugin)
	local fs, json, base64 = options.fs, options.json, options.base64
	if parent == nil or type(fs) ~= "table" or type(json) ~= "table" or type(base64) ~= "table"
		or type(json.decode) ~= "function" or type(base64.encode) ~= "function" or type(base64.decode) ~= "function" then
		return nil, failure("invalid_options", "open")
	end
	for _, name in { "exists", "read", "write", "mkdir", "remove" } do
		if type(fs[name]) ~= "function" then return nil, failure("invalid_options", "open") end
	end
	local incarnation: string = options.incarnation
	local peers = (PEERS :: any)[plugin]
	local roots = {}
	for id in PEERS do roots[id] = parent .. "/" .. id .. "/" .. DIRECTORY end
	local own = roots[plugin]
	local exists_ok, exists = pcall(fs.exists, own)
	if not exists_ok then return nil, failure("io_error", "open") end
	if not exists then
		local made = pcall(fs.mkdir, own)
		if not made then return nil, failure("io_error", "open") end
	end

	local endpoint = {}
	local last_error: any = nil
	local receive_cursor, settle_cursor = 1, 1
	-- Bounded by fixed producer slots, never by lifetime message count.
	local incoming: { [number]: any } = {}
	local outgoing: { [number]: any } = {}

	local function report(err: any): any
		last_error = err
		return err
	end
	local function progressed()
		last_error = nil
	end
	local function data_path(owner: string, slot: number): string
		return roots[owner] .. string.format("/m-%03d.json", slot)
	end
	local function ack_path(consumer: string, producer: string, slot: number): string
		return roots[consumer] .. string.format("/a-%s-%03d.json", producer, slot)
	end
	local function read_file(path: string, operation: string, peer: string, slot: number, known_present: boolean?): (string?, any?)
		local present = known_present
		if present == nil then
			local checked, found = pcall(fs.exists, path)
			if not checked then return nil, failure("io_error", operation, peer, slot) end
			present = found
		end
		if not present then return nil, nil end
		-- Native bounded read rejects oversize, symlinks and nonregular files.
		local ok, raw = pcall(fs.read, path, MAX_FRAME)
		if not ok or type(raw) ~= "string" or #raw > MAX_FRAME then return nil, failure("unreadable_frame", operation, peer, slot) end
		return raw, nil
	end
	local function decode_frame(raw: string, producer: string, slot: number): (any?, string?)
		if #raw + #ACK_HEAD + 1 > MAX_FRAME then return nil, "oversize_frame" end
		if raw:sub(-1) ~= "}" then return nil, "incomplete_frame" end
		local ok, value = pcall(json.decode, raw)
		if not ok or type(value) ~= "table" then return nil, "invalid_frame" end
		if value.v ~= 1 or value.kind ~= "message" or value.from ~= producer or value.slot ~= slot
			or not route_allowed(value.from, value.to, value.route)
			or not token(value.incarnation, 80) or not token(value.id, 80) or not token(value.binding, 160)
			or not integer(value.body_bytes, 0, MAX_BODY) or type(value.body) ~= "string"
			or #value.body > 87384 or value.body:find("[^A-Za-z0-9+/=]") then return nil, "invalid_frame" end
		local decoded, body = pcall(base64.decode, value.body)
		if not decoded or type(body) ~= "string" or #body ~= value.body_bytes then return nil, "invalid_frame" end
		local encoded, canonical = pcall(base64.encode, body)
		if not encoded or canonical ~= value.body then return nil, "invalid_frame" end
		local message = { peer = producer, recipient = value.to, incarnation = value.incarnation,
			id = value.id, route = value.route, binding = value.binding, body = body, slot = slot }
		if encode_frame(message, canonical) ~= raw then return nil, "invalid_frame" end
		return message, nil
	end
	local function decode_ack(raw: string, producer: string, slot: number, recipient: string?): (any?, string?)
		if raw:sub(1, #ACK_HEAD) ~= ACK_HEAD or raw:sub(-1) ~= "}" then return nil, "invalid_ack" end
		local message, code = decode_frame(raw:sub(#ACK_HEAD + 1, -2), producer, slot)
		if message == nil then return nil, code end
		if message.recipient ~= (recipient or plugin) then return nil, "conflicting_ack" end
		return message, nil
	end
	local function remove_exact(path: string, raw: string, operation: string, peer: string, slot: number): any?
		local current, err = read_file(path, operation, peer, slot)
		if err then return err end
		if current ~= raw then return failure("conflict", operation, peer, slot) end
		-- Only this just-bounded-read regular file is removed. Never a directory.
		-- Same-user trusted plugins are required: SDK has no atomic checked unlink.
		local ok = pcall(fs.remove, path)
		if not ok then return failure("io_error", operation, peer, slot) end
		return nil
	end
	local function write_once(path: string, raw: string, operation: string, peer: string, slot: number): (boolean, any?)
		local previous, err = read_file(path, operation, peer, slot)
		if err then return false, err end
		if previous ~= nil then
			if previous == raw then return true, nil end
			return false, failure("conflict", operation, peer, slot)
		end
		-- fs.write is NOT atomic. A failed or partial write is not overwritten.
		local ok = pcall(fs.write, path, raw)
		if not ok then return false, failure("write_unconfirmed", operation, peer, slot) end
		local current, read_error = read_file(path, operation, peer, slot)
		if read_error then return false, read_error end
		if current ~= raw then return false, failure("write_unconfirmed", operation, peer, slot) end
		return true, nil
	end
	local function receipt(message: any): any
		return { peer = message.recipient, incarnation = message.incarnation, id = message.id,
			route = message.route, binding = message.binding, slot = message.slot }
	end
	local function turn_limit(value: any): number?
		if value == nil then return MAX_TURN end
		return if integer(value, 1, MAX_TURN) then value else nil
	end

	function endpoint.send(request: any): (any?, any?)
		if type(request) ~= "table" then return nil, report(failure("invalid_request", "send")) end
		local allowed = { peer = true, route = true, binding = true, id = true, body = true, priority = true }
		for key in request do if not allowed[key] then return nil, report(failure("invalid_request", "send")) end end
		if not route_allowed(plugin, request.peer, request.route) or not token(request.id, 80)
			or not token(request.binding, 160) or type(request.body) ~= "string" or #request.body > MAX_BODY
			or (request.priority ~= nil and request.priority ~= "settlement")
			or (request.priority == "settlement" and request.peer ~= (SETTLEMENT_PEER :: any)[plugin]) then
			return nil, report(failure("invalid_request", "send"))
		end
		local free_general: number? = nil
		local free_reserved: number? = nil
		local repeated: any = nil
		local first_fault: any = nil
		for slot = 1, SLOT_COUNT do
			local raw, err = read_file(data_path(plugin, slot), "send", plugin, slot)
			if err then return nil, report(err) end
			if raw ~= nil then
				local cached = outgoing[slot]
				local message, code
				if cached and cached.raw == raw then message = cached.message else message, code = decode_frame(raw, plugin, slot) end
				if message == nil then
					local fault = failure(code or "invalid_frame", "send", plugin, slot)
					-- A partial own slot stays occupied. Remember attempted bytes
					-- before writing so a same-load retry cannot relocate the same
					-- uncertain message into a second slot.
					if cached and cached.message.incarnation == incarnation and cached.message.id == request.id then
						return nil, report(fault)
					end
					first_fault = first_fault or fault
					continue
				end
				outgoing[slot] = { raw = raw, message = message }
				if message.incarnation == incarnation and message.id == request.id then
					if message.recipient ~= request.peer or message.route ~= request.route or message.binding ~= request.binding
						or message.body ~= request.body or repeated ~= nil then return nil, report(failure("conflict", "send", plugin, slot)) end
					repeated = message
				end
			else
				outgoing[slot] = nil
				local available = true
				for _, peer in peers do
					local checked, present = pcall(fs.exists, ack_path(peer, plugin, slot))
					if not checked then return nil, report(failure("io_error", "send", peer, slot)) end
					if present then available = false end
				end
				if available then
					if slot <= SLOT_COUNT - 2 and free_general == nil then free_general = slot end
					if slot > SLOT_COUNT - 2 and free_reserved == nil then free_reserved = slot end
				end
			end
		end
		if repeated ~= nil then
			if first_fault then report(first_fault) end
			return receipt(repeated), nil
		end
		-- Reserve two slots for completion/control drain. This affects allocation
		-- only, never frame identity, domain priority or authorization.
		local free = if request.priority == "settlement" then (free_reserved or free_general) else free_general
		if free == nil then return nil, report(first_fault or failure("backpressure", "send")) end
		local message = { peer = plugin, recipient = request.peer, incarnation = incarnation, id = request.id,
			route = request.route, binding = request.binding, body = request.body, slot = free }
		local encoded, body = pcall(base64.encode, request.body)
		if not encoded or type(body) ~= "string" then return nil, report(failure("encoding_failed", "send")) end
		local raw = encode_frame(message, body)
		if #raw + #ACK_HEAD + 1 > MAX_FRAME then return nil, report(failure("oversize_frame", "send")) end
		outgoing[free] = { raw = raw, message = message }
		local ok, err = write_once(data_path(plugin, free), raw, "send", request.peer, free)
		if not ok then return nil, report(err) end
		if first_fault then report(first_fault) else progressed() end
		return receipt(message), nil
	end

	function endpoint.receive(limit: any): ({ any }, any?)
		local count = turn_limit(limit)
		if count == nil then return {}, report(failure("invalid_limit", "receive")) end
		local messages, first_error = {}, nil
		local visited, processed = 0, 0
		while visited < #peers * SLOT_COUNT and processed < count do
			visited += 1
			local index = receive_cursor
			receive_cursor = (receive_cursor % (#peers * SLOT_COUNT)) + 1
			local peer = peers[math.floor((index - 1) / SLOT_COUNT) + 1]
			local slot = ((index - 1) % SLOT_COUNT) + 1
			local data_checked, data_present = pcall(fs.exists, data_path(peer, slot))
			local ack_checked, ack_present = pcall(fs.exists, ack_path(plugin, peer, slot))
			if not data_checked or not ack_checked then
				processed += 1
				first_error = first_error or failure("io_error", "receive", peer, slot)
				continue
			end
			if not data_present and not ack_present then incoming[index] = nil; continue end
			local remembered = incoming[index]
			-- A verified immutable data/ACK pair cannot be reused until this
			-- consumer observes data absence and removes its own ACK. Existing
			-- pairs therefore need no repeated body reads or delivery budget.
			if data_present and ack_present and remembered and remembered.acknowledged then continue end
			processed += 1
			local raw, err = read_file(data_path(peer, slot), "receive", peer, slot, data_present)
			if err then first_error = first_error or err; continue end
			local acknowledged, ack_error = read_file(ack_path(plugin, peer, slot), "receive", peer, slot, ack_present)
			if ack_error then first_error = first_error or ack_error; continue end
			if raw == nil then
				incoming[index] = nil
				if acknowledged ~= nil then
					local old, code = decode_ack(acknowledged, peer, slot)
					if old == nil then first_error = first_error or failure(code or "invalid_ack", "receive", peer, slot)
					else
						local removed = remove_exact(ack_path(plugin, peer, slot), acknowledged, "receive", peer, slot)
						if removed then first_error = first_error or removed else progressed() end
					end
				end
				continue
			end
			local cached = incoming[index]
			local message, code
			if cached and cached.raw == raw then message = cached.identity else message, code = decode_frame(raw, peer, slot) end
			if message == nil then first_error = first_error or failure(code or "invalid_frame", "receive", peer, slot); continue end
			if acknowledged ~= nil and (message.recipient ~= plugin or acknowledged ~= ack_frame(raw)) then
				first_error = first_error or failure("conflicting_ack", "receive", peer, slot); continue
			end
			if message.recipient ~= plugin then incoming[index] = nil; continue end
			if cached == nil or cached.raw ~= raw then
				cached = { raw = raw, identity = message, delivered = table.clone(message) }
				incoming[index] = cached
			end
			cached.acknowledged = acknowledged ~= nil
			if cached.acknowledged then continue end
			table.insert(messages, cached.delivered)
		end
		if first_error then report(first_error) end
		return messages, first_error
	end

	function endpoint.ack(message: any): (boolean, any?)
		if type(message) ~= "table" then return false, report(failure("invalid_receipt", "ack")) end
		local cached
		for _, entry in incoming do
			if entry.delivered == message then cached = entry; break end
		end
		if cached == nil then return false, report(failure("invalid_receipt", "ack")) end
		for key, value in cached.identity do
			if message[key] ~= value then return false, report(failure("invalid_receipt", "ack")) end
		end
		for key in message do
			if cached.identity[key] == nil then return false, report(failure("invalid_receipt", "ack")) end
		end
		local peer, slot = cached.identity.peer, cached.identity.slot
		local raw, read_error = read_file(data_path(peer, slot), "ack", peer, slot)
		if read_error then return false, report(read_error) end
		if raw == nil or raw ~= cached.raw then return false, report(failure("conflict", "ack", peer, slot)) end
		local ok, err = write_once(ack_path(plugin, peer, slot), ack_frame(raw), "ack", peer, slot)
		if not ok then return false, report(err) end
		-- Bounded immutable-pair cache avoids spending receive budget on an ACK
		-- waiting for producer settlement; disappearance still triggers cleanup.
		cached.acknowledged = true
		progressed()
		return true, nil
	end

	function endpoint.settle(limit: any): (number, any?)
		local count = turn_limit(limit)
		if count == nil then return 0, report(failure("invalid_limit", "settle")) end
		local settled, first_error = 0, nil
		local visited, processed = 0, 0
		while visited < SLOT_COUNT and processed < count do
			visited += 1
			local slot = settle_cursor
			settle_cursor = (settle_cursor % SLOT_COUNT) + 1
			local checked, present = pcall(fs.exists, data_path(plugin, slot))
			if not checked then
				processed += 1
				first_error = first_error or failure("io_error", "settle", plugin, slot)
				continue
			end
			if not present then outgoing[slot] = nil; continue end
			processed += 1
			local raw, err = read_file(data_path(plugin, slot), "settle", plugin, slot, true)
			if err then first_error = first_error or err; continue end
			if raw == nil then outgoing[slot] = nil; continue end
			local cached = outgoing[slot]
			local message, code
			if cached and cached.raw == raw then message = cached.message else message, code = decode_frame(raw, plugin, slot) end
			if message == nil then first_error = first_error or failure(code or "invalid_frame", "settle", plugin, slot); continue end
			outgoing[slot] = { raw = raw, message = message }
			local acknowledged, ack_error = read_file(ack_path(message.recipient, plugin, slot), "settle", message.recipient, slot)
			if ack_error then first_error = first_error or ack_error; continue end
			if acknowledged == nil then continue end
			if acknowledged ~= ack_frame(raw) then
				first_error = first_error or failure("conflicting_ack", "settle", message.recipient, slot); continue
			end
			local removed = remove_exact(data_path(plugin, slot), raw, "settle", plugin, slot)
			if removed then first_error = first_error or removed
			else outgoing[slot] = nil; settled += 1; progressed() end
		end
		if first_error then report(first_error) end
		return settled, first_error
	end

	-- Read-only observation of a receiver-owned ACK for a restored exact message.
	-- This does not recreate ack()'s capability or prove a domain/native effect.
	-- Persist any positive domain fence BEFORE receive() can retire ACK-only
	-- files; failed/unprocessed fence persistence must prevent that cleanup.
	function endpoint.acknowledged(message: any): (boolean, any?)
		if type(message) ~= "table" then return false, report(failure("invalid_receipt", "acknowledged")) end
		local allowed = { peer = true, recipient = true, incarnation = true, id = true,
			route = true, binding = true, body = true, slot = true }
		for key in message do
			if not allowed[key] then return false, report(failure("invalid_receipt", "acknowledged")) end
		end
		if message.recipient ~= plugin or not route_allowed(message.peer, plugin, message.route)
			or not token(message.incarnation, 80) or not token(message.id, 80) or not token(message.binding, 160)
			or not integer(message.slot, 1, SLOT_COUNT) or type(message.body) ~= "string" or #message.body > MAX_BODY then
			return false, report(failure("invalid_receipt", "acknowledged"))
		end
		local peer, slot = message.peer, message.slot
		local acknowledged, ack_error = read_file(ack_path(plugin, peer, slot), "acknowledged", peer, slot)
		if ack_error then return false, report(ack_error) end
		if acknowledged == nil then return false, nil end
		local encoded, body = pcall(base64.encode, message.body)
		if not encoded or type(body) ~= "string" then return false, report(failure("encoding_failed", "acknowledged", peer, slot)) end
		local expected = encode_frame(message, body)
		if #expected + #ACK_HEAD + 1 > MAX_FRAME then return false, report(failure("oversize_frame", "acknowledged", peer, slot)) end
		if acknowledged ~= ack_frame(expected) then
			local parsed, code = decode_ack(acknowledged, peer, slot)
			return false, report(failure(if parsed == nil then (code or "invalid_ack") else "conflicting_ack", "acknowledged", peer, slot))
		end
		local current, data_error = read_file(data_path(peer, slot), "acknowledged", peer, slot)
		if data_error then return false, report(data_error) end
		if current ~= nil and current ~= expected then return false, report(failure("conflict", "acknowledged", peer, slot)) end
		return true, nil
	end

	-- Read-only transport retirement observation, never native/domain proof.
	-- Batch only at a retirement boundary, not once per lane or every poll:
	-- at most 96 fixed probes / 12 bounded reads, otherwise unknown/busy. No
	-- exclusion of future writes; the caller must separately close the domain.
	function endpoint.quiescent(peer: any, bindings: any): (any?, any?)
		if type(peer) ~= "string" or table.find(peers, peer) == nil or type(bindings) ~= "table" then
			return nil, report(failure("invalid_request", "quiescent"))
		end
		local count = 0
		for key in bindings do
			if not integer(key, 1, 64) then return nil, report(failure("invalid_request", "quiescent")) end
			count += 1
		end
		if count == 0 then return nil, report(failure("invalid_request", "quiescent")) end
		local clear: { [string]: boolean } = {}
		local prefixes: { [string]: string } = {}
		for index = 1, count do
			local binding = bindings[index]
			if not token(binding, 160) or clear[binding] ~= nil then
				return nil, report(failure("invalid_request", "quiescent"))
			end
			clear[binding] = true
			prefixes[binding] = binding .. ":"
		end
		local remaining = count
		local reads = 0
		local function observe(path: string, producer: string, recipient: string, slot: number, is_ack: boolean): any?
			local checked, present = pcall(fs.exists, path)
			if not checked then return failure("io_error", "quiescent", producer, slot) end
			if not present then return nil end
			if reads >= MAX_TURN * 3 then return failure("observation_budget", "quiescent", producer, slot) end
			reads += 1
			local raw, err = read_file(path, "quiescent", producer, slot, true)
			if err then return err end
			if raw == nil then return nil end
			local message, code
			if is_ack then message, code = decode_ack(raw, producer, slot, recipient)
			else message, code = decode_frame(raw, producer, slot) end
			if message == nil then return failure(code or "invalid_frame", "quiescent", producer, slot) end
			if message.recipient ~= recipient then return nil end
			for binding, prefix in prefixes do
				if clear[binding] and (message.binding == binding or message.binding:sub(1, #prefix) == prefix) then
					clear[binding] = false
					remaining -= 1
				end
			end
			return nil
		end
		local function uncertain(err: any): (any, any)
			for binding in clear do clear[binding] = false end
			return clear, report(err)
		end
		for slot = 1, SLOT_COUNT do
			local err = observe(data_path(plugin, slot), plugin, peer, slot, false)
			if err then return uncertain(err) end
			if remaining == 0 then return clear, nil end
			err = observe(data_path(peer, slot), peer, plugin, slot, false)
			if err then return uncertain(err) end
			if remaining == 0 then return clear, nil end
			err = observe(ack_path(plugin, peer, slot), peer, plugin, slot, true)
			if err then return uncertain(err) end
			if remaining == 0 then return clear, nil end
			err = observe(ack_path(peer, plugin, slot), plugin, peer, slot, true)
			if err then return uncertain(err) end
			if remaining == 0 then return clear, nil end
		end
		return clear, nil
	end

	function endpoint.status(): any
		if last_error == nil then return { state = "ready" } end
		return { state = "held", code = last_error.code, operation = last_error.operation }
	end
	return endpoint, nil
end

return Channel
