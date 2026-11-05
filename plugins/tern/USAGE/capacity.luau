--!strict
-- Read-only consumer seam (`usage.capacity`). No consumer input can select another companion operation.
local companion = require("./companion")
local capacity = {}
capacity.NODE = "usage-capacity-response"
capacity.PREFIX = "USAGE_CAPACITY v1\n"
local function opaque(value: any): boolean
	return type(value) == "string" and #value > 0 and #value <= 128 and value:match("^[%w_.:%-]+$") ~= nil
end
function capacity.decode(raw: any): any?
	if type(raw) ~= "string" or #raw > 4096 then return nil end
	local ok, request = pcall(tern.json.decode, raw)
	if not ok or type(request) ~= "table" or request.version ~= 1 or not opaque(request.request_id) then return nil end
	local fields = { version = true, request_id = true, op = true }
	if request.op == "page" or request.op == "validate" then
		fields.revision = true
		if type(request.revision) ~= "string" or #request.revision ~= 64 or not request.revision:match("^[0-9a-f]+$") then return nil end
	end
	if request.op == "page" then
		fields.cursor = true
		if not opaque(request.cursor) then return nil end
	elseif request.op ~= "snapshot" and request.op ~= "validate" then return nil end
	for key in request do if not fields[key] then return nil end end
	return request
end
function capacity.install()
	tern.block.define("capacity", {
		init = function(_cx: any, _args: any, _saved: any): any
			return { serial = 0, busy = false, response = { version = 1, ok = false, status = "request_required", message = "Send a versioned capacity request." } }
		end,
		title = function(): string return "USAGE Capacity" end,
		view = function(state: any, _cx: any): any
			local node = tern.ui.text(capacity.PREFIX .. tern.json.encode(state.response))
			node.p = node.p or {}
			node.p.key = capacity.NODE
			node.p.role = capacity.NODE
			return { main = tern.ui.col({ node }) }
		end,
		event = function(state: any, event: any, cx: any)
			if event.ev ~= "action" or event.act ~= "usage.capacity" then return end
			if state.busy then return end
			local request = capacity.decode(event.value)
			if request == nil then
				state.serial += 1; state.busy = false
				state.response = { version = 1, ok = false, status = "invalid_request", message = "Use the bounded capacity v1 read protocol." }
				cx:render(); return
			end
			state.serial += 1
			local serial = state.serial
			state.busy = true
			state.response = { version = 1, request_id = request.request_id, op = request.op, ok = false, status = "pending" }
			cx:render()
			companion.request("capacity", request, function(value, err)
				if state.serial ~= serial then return end
				state.busy = false
				if value ~= nil and type(value.response) == "table" then state.response = value.response
				else state.response = { version = 1, request_id = request.request_id, op = request.op, ok = false,
					status = if err ~= nil then err.code else "companion_unavailable",
					message = if err ~= nil then err.message else "Open USAGE Setup to prepare its existing companion." } end
				cx:render()
			end)
		end,
	})
end
return capacity
