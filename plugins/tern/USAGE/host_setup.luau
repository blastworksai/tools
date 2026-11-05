--!strict
-- Host-run Setup (`usage.setup` on the host-owned config block). A window attached to this
-- host confirms every change in its own Setup; this block only maps one bounded request onto
-- this host's companion. No other companion operation, setting or consent can be selected.
local companion = require("./companion")
local host_setup = {}
host_setup.ACTION = "usage.setup"
host_setup.NODE = "usage-setup-response"
host_setup.PREFIX = "USAGE_SETUP v1\n"
host_setup.MAX = 32768
local MAX_REQUEST = 16384
local ACTIONS: { [string]: { [string]: boolean } } = {
	bind = { operation = true, scope_id = true, id = true, definition_revision = true, canonical_id = true },
	revoke = { operation = true, scope_id = true, id = true },
	associate = { operation = true, scope_id = true, id = true, definition_revision = true, account_id = true },
	dissociate = { operation = true, scope_id = true, id = true },
}
local CONSENT: { [string]: string } = { bind = "binding", associate = "association" }
local SETTINGS: { [string]: string } = { metadata_enabled = "metadata", capacity_enabled = "capacity" }
-- Operations that change this host's companion; reads never notify the host display.
local CHANGES: { [string]: boolean } = { ensure = true, configure = true }

local function opaque(value: any): boolean
	return type(value) == "string" and #value > 0 and #value <= 128 and value:match("^[%w_.:%-]+$") ~= nil
end
local function text(value: any): boolean
	return type(value) == "string" and #value > 0 and #value <= 4096 and not value:find("%c")
end
local function only(value: any, fields: { [string]: boolean }): boolean
	if type(value) ~= "table" then return false end
	for key in value do if not fields[key] then return false end end
	return true
end
-- The consent object grants exactly `name = value` and nothing else.
local function grants(consent: any, name: string, value: boolean): boolean
	return only(consent, { [name] = true }) and consent[name] == value
end
local function empty(payload: any): boolean
	return payload == nil or (type(payload) == "table" and next(payload) == nil)
end
-- The same shapes local Setup sends: one headless-read or capacity toggle with its own consent,
-- or one binding action (bind/associate with their consent, revoke/dissociate without).
local function configuration(payload: any): boolean
	if type(payload) ~= "table" then return false end
	local action = payload.binding_action
	if action ~= nil then
		if type(action) ~= "table" or type(action.operation) ~= "string" then return false end
		local fields = ACTIONS[action.operation]
		if fields == nil or not only(action, fields) then return false end
		for key in fields do if key ~= "operation" and not text(action[key]) then return false end end
		local name = CONSENT[action.operation]
		if name == nil then return only(payload, { binding_action = true }) end
		return only(payload, { binding_action = true, consent = true }) and grants(payload.consent, name, true)
	end
	if not only(payload, { changes = true, consent = true }) or type(payload.changes) ~= "table" then return false end
	local key, value = next(payload.changes)
	if type(key) ~= "string" or next(payload.changes, key) ~= nil or SETTINGS[key] == nil or type(value) ~= "boolean" then return false end
	return grants(payload.consent, SETTINGS[key], value)
end

-- Returns the request, or nil plus the request id when one could be read (for correlation).
function host_setup.decode(raw: any): (any?, string?)
	if type(raw) ~= "string" or #raw > MAX_REQUEST then return nil, nil end
	local ok, request = pcall(tern.json.decode, raw)
	if not ok or type(request) ~= "table" then return nil, nil end
	local id = if opaque(request.request_id) then request.request_id else nil
	if request.version ~= 1 or id == nil or not only(request, { version = true, request_id = true, op = true, payload = true }) then return nil, id end
	local payload = request.payload
	if request.op == "setup_state" or request.op == "binding_candidates" then
		if not empty(payload) then return nil, id end
	elseif request.op == "ensure" then
		if not only(payload, { install_dependencies = true }) or payload.install_dependencies ~= true then return nil, id end
	elseif request.op == "configure" then
		if not configuration(payload) then return nil, id end
	else return nil, id end
	return request, id
end

-- Window side: the versioned response text read from this block's surface.
function host_setup.parse(bytes: any): any?
	if type(bytes) ~= "string" or #bytes > host_setup.MAX + #host_setup.PREFIX or bytes:sub(1, #host_setup.PREFIX) ~= host_setup.PREFIX then return nil end
	local ok, response = pcall(tern.json.decode, bytes:sub(#host_setup.PREFIX + 1))
	if not ok or type(response) ~= "table" or response.version ~= 1 or type(response.status) ~= "string"
		or type(response.ok) ~= "boolean" then return nil end
	return response
end

function host_setup.new(): any
	return { serial = 0, busy = false, response = { version = 1, ok = false, status = "request_required" } }
end

-- Only public setup fields leave the companion: no peers, hub, certificate or sharing address.
local function reduce(op: string, value: any): any?
	if type(value) ~= "table" then return nil end
	if op == "setup_state" then
		local source, settings = value.source, value.settings
		if type(source) ~= "table" or type(source.device_id) ~= "string" or type(settings) ~= "table"
			or type(settings.role) ~= "string" or type(settings.metadata_enabled) ~= "boolean"
			or type(settings.capacity_enabled) ~= "boolean" then return nil end
		return { source = { device_id = source.device_id }, settings = { role = settings.role,
			metadata_enabled = settings.metadata_enabled, capacity_enabled = settings.capacity_enabled } }
	elseif op == "binding_candidates" then
		if type(value.accounts) ~= "table" or type(value.consumers) ~= "table" then return nil end
		return { accounts = value.accounts, consumers = value.consumers }
	elseif op == "ensure" then return { state = "ready" } end
	return { saved = true }
end

-- `changed` runs after a successful change so the host's own display and collector follow it.
function host_setup.event(state: any, event: any, cx: any, changed: (() -> ())?)
	if event.ev ~= "action" or event.act ~= host_setup.ACTION or state.busy then return end
	local request, id = host_setup.decode(event.value)
	-- A resent request that already has its answer is never run twice.
	if id ~= nil and id == state.response.request_id then return end
	state.serial += 1
	if request == nil then
		state.response = { version = 1, request_id = id, ok = false, status = "failed", code = "invalid_request",
			message = "Use the bounded USAGE host Setup protocol." }
		cx:render(); return
	end
	local serial = state.serial
	state.busy = true
	state.response = { version = 1, request_id = id, op = request.op, ok = false, status = "pending" }
	cx:render()
	local function done(value: any?, err: any?)
		if state.serial ~= serial then return end
		state.busy = false
		local public = if value ~= nil then reduce(request.op, value) else nil
		if public ~= nil then
			state.response = { version = 1, request_id = id, op = request.op, ok = true, status = "done", value = public }
		else
			local code = if err ~= nil then err.code else "decode_failed"
			state.response = { version = 1, request_id = id, op = request.op, ok = false, status = "failed", code = code,
				message = if err ~= nil then err.message else "The USAGE companion on this host returned an invalid response." }
		end
		if #tern.json.encode(state.response) > host_setup.MAX then
			state.response = { version = 1, request_id = id, op = request.op, ok = false, status = "failed", code = "response_too_large",
				message = "The USAGE host Setup response exceeds its size limit." }
		end
		cx:render()
		if public ~= nil and CHANGES[request.op] and changed ~= nil then changed() end
	end
	if request.op == "setup_state" then
		-- Same order as local Setup: the runtime check first; it never installs anything.
		companion.ensure(function(ready, err)
			if ready == nil then done(nil, err); return end
			companion.request("setup_state", {}, function(value, failure) done(value, failure) end)
		end, { install_dependencies = false })
	elseif request.op == "ensure" then
		companion.ensure(function(value, err) done(value, err) end, { install_dependencies = true })
	else
		companion.request(request.op, if request.op == "configure" then request.payload else {}, function(value, err) done(value, err) end)
	end
end

function host_setup.view(state: any): any
	local node = tern.ui.text(host_setup.PREFIX .. tern.json.encode(state.response))
	node.p = node.p or {}
	node.p.key = host_setup.NODE
	node.p.role = host_setup.NODE
	return tern.ui.node("col", { role = "usage-host-setup", gap = "xs" }, {
		tern.ui.text(tern.ui.span("Host Setup: USAGE Setup in a window attached to this machine configures this machine's companion, after you confirm each change there.", "muted")),
		node,
	})
end

return host_setup
