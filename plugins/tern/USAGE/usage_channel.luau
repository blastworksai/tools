--!strict
-- USAGE remains the sole producer. This adapter accepts only the two existing
-- read protocols; carrier receipt/ACK is never quota permission or freshness.
local display = require("./display")
local capacity = require("./capacity")
local adapter = {}
local ROUTES = { ["usage.display.request"] = "usage.display.response", ["usage.capacity.request"] = "usage.capacity.response" }
local MAX_PENDING = 4
function adapter.new(cache: any, endpoint: any): any
	local pending, count, serial = {}, 0, 0
	local held: string? = nil
	local self = {}
	local function failure(code: any)
		held = if type(code) == "string" then code else "channel_unavailable"
	end
	function self.status(): any
		return { state = if held ~= nil then "held" else "ready", code = held, pending = count }
	end
	function self.pump()
		local settled, settleError = endpoint.settle(4)
		if settleError ~= nil then failure(settleError.code) elseif settled > 0 then held = nil end
		-- An immutable response is durable handling of a read. Until its send
		-- succeeds, keep precisely these bytes and do not repeat the companion call.
		for key, job in pending do
			if job.body == nil then continue end
			if not job.sent then
				local receipt, err = endpoint.send({ peer = "orchplus", route = job.route,
					binding = job.message.binding, id = job.id, body = job.body })
				if receipt == nil then failure(if err ~= nil then err.code else nil); continue end
				job.sent = true
			end
			local ok, err = endpoint.ack(job.message)
			if ok then pending[key] = nil; count -= 1; held = nil
			else failure(if err ~= nil then err.code else nil) end
		end
		if count >= MAX_PENDING then return end
		local messages, receiveError = endpoint.receive(4)
		if receiveError ~= nil then failure(receiveError.code) end
		for _, message in messages do
			local route = ROUTES[message.route]
			if message.peer ~= "orchplus" or message.recipient ~= "usage" or route == nil then failure("invalid_route"); continue end
			local key = message.peer .. "/" .. message.incarnation .. "/" .. message.id
			if pending[key] ~= nil then continue end
			if count >= MAX_PENDING then break end
			serial += 1
			local job: any = { message = message, route = route, id = "read-" .. tostring(serial), sent = false }
			pending[key] = job; count += 1
			local function done(response: any)
				if job.body ~= nil then return end
				local ok, bytes = pcall(tern.json.encode, response)
				if not ok or #bytes > 65536 then
					local request = if message.route == "usage.display.request" then display.decode(message.body) else capacity.decode(message.body)
					bytes = tern.json.encode({ version = 1, request_id = if request ~= nil then request.request_id else nil,
						op = if request ~= nil then request.op else nil, ok = false, status = "response_too_large",
						display_only = if message.route == "usage.display.request" then true else nil })
				end
				job.body = bytes
			end
			local ok = pcall(function()
				if message.route == "usage.display.request" then display.request(cache, message.body, done)
				else capacity.request(message.body, done) end
			end)
			if not ok then
				-- Read-only failure has no actor effect to preserve or replay.
				-- Publish a bounded rejection so its request slot can settle.
				local request = if message.route == "usage.display.request" then display.decode(message.body) else capacity.decode(message.body)
				done({ version = 1, request_id = if request ~= nil then request.request_id else nil,
					op = if request ~= nil then request.op else nil, ok = false, status = "internal_error",
					display_only = if message.route == "usage.display.request" then true else nil })
			end
		end
	end
	return self
end
return adapter
