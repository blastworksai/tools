--!strict
-- Display-only consumer protocol. Never refresh providers or change preferences.
local companion = require("./companion")
local presentation = require("./presentation")
local display = {}
display.NODE = "usage-display-response"
display.PREFIX = "USAGE_DISPLAY v1\n"
display.PAGE_SIZE = 16
display.MAX = 65536
function display.decode(raw: any): any?
	if type(raw) ~= "string" or #raw > 4096 then return nil end
	local ok, request = pcall(tern.json.decode, raw)
	if not ok or type(request) ~= "table" or request.version ~= 1 or type(request.request_id) ~= "string"
		or #request.request_id < 1 or #request.request_id > 128 or not request.request_id:match("^[%w_.:%-]+$") then return nil end
	local fields = { version = true, request_id = true, op = true }
	if request.op == "page" or request.op == "validate" then
		fields.revision = true
		if type(request.revision) ~= "string" or #request.revision < 1 or #request.revision > 512 then return nil end
	end
	if request.op == "page" then
		fields.cursor = true
		if type(request.cursor) ~= "number" or request.cursor < 16 or request.cursor > 128 or request.cursor % 16 ~= 0 then return nil end
	elseif request.op ~= "snapshot" and request.op ~= "validate" then return nil end
	for key in request do if not fields[key] then return nil end end
	return request
end
function display.response(request: any, access: any, cache: any, now: number, platform: string): any
	local result: any = { version = 1, display_only = true, request_id = request.request_id, op = request.op,
		ok = false, status = "unavailable", records = tern.json.array() }
	if platform ~= "linux" then result.status = "platform_hold"; return result end
	if cache.revision == nil then return result end
	local revision = access.revision .. ":" .. cache.revision
	if request.op ~= "snapshot" and request.revision ~= revision then result.status = "revoked"; return result end
	result.revision, result.as_of_ms, result.source_id = revision, now, access.source_id
	local rows = presentation.display_records(cache.snapshots, access, now)
	local offset = request.cursor or 0
	if offset > 0 and offset >= #rows then result.status = "invalid_request"; return result end
	if request.op ~= "validate" then
		for index = offset + 1, math.min(#rows, offset + display.PAGE_SIZE) do table.insert(result.records, rows[index]) end
	end
	result.ok, result.status = true, "current"
	result.complete = request.op == "validate" or offset + display.PAGE_SIZE >= #rows
	if not result.complete then result.next_cursor = offset + display.PAGE_SIZE end
	if #tern.json.encode(result) > display.MAX then
		return { version = 1, display_only = true, request_id = request.request_id, op = request.op,
			ok = false, status = "response_too_large", records = tern.json.array() }
	end
	return result
end
function display.request(cache: any, raw: any, done: (any) -> ())
	local request = display.decode(raw)
	local function fail(code: string)
		done({ version = 1, display_only = true, request_id = if request ~= nil then request.request_id else nil,
			op = if request ~= nil then request.op else nil, ok = false, status = code, records = tern.json.array() })
	end
	if request == nil then fail("invalid_request"); return end
	if tern.runtime.os ~= "linux" then fail("platform_hold"); return end
	local function authorize()
		companion.request("display_access", {}, function(access, err)
			if access == nil then fail(if err ~= nil then err.code else "unavailable"); return end
			done(display.response(request, access, cache, math.floor(os.time() * 1000), tern.runtime.os))
		end)
	end
	-- Reads the existing companion presentation cache, never usage_refresh.
	if request.op == "snapshot" then
		if cache.busy then fail("pending"); return end
		cache:refresh(function(ok, err)
			if not ok then fail(if err ~= nil then err.code else "unavailable"); return end
			authorize()
		end)
	else authorize() end
end

function display.install(cache: any)
	tern.block.define("display", {
		init = function(): any return { busy = false, response = { version = 1, display_only = true,
			ok = false, status = "request_required", records = tern.json.array() } } end,
		title = function(): string return "USAGE Display" end,
		view = function(state: any): any
			local node = tern.ui.text(display.PREFIX .. tern.json.encode(state.response))
			node.p = node.p or {}; node.p.key = display.NODE; node.p.role = display.NODE; node.p.hidden = true
			return { main = tern.ui.col({ node }) }
		end,
		event = function(state: any, event: any, cx: any)
			if event.ev ~= "action" or event.act ~= "usage.display" or state.busy then return end
			local request = display.decode(event.value)
			state.busy = true
			state.response = { version = 1, display_only = true, request_id = if request ~= nil then request.request_id else nil,
				op = if request ~= nil then request.op else nil,
				ok = false, status = "pending", records = tern.json.array() }
			cx:render()
			display.request(cache, event.value, function(response)
				state.response = response
				state.busy = false
				cx:render()
			end)
		end,
	})
end
return display
