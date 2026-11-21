--!strict
local BLOCK = "orchplus.orchestrator"
local codec = require("./wire/codec")
local dispatch = require("./dispatch_protocol")
local quota = require("./quota")
local source_adapter = require("./source_adapter")
local provider_display = require("./provider_display")
local status_prompt = require("./status/status_prompt")
local picker_ui: any, source_ui: any, conversation_ui: any, forms_ui: any
local work_tick: any
local connection_attempts: any = {}
local automatic_connection: any
local agent_of: any, pane_binding: any
local incarnation = string.format("window-%d-%08x-%08x", os.time(), math.random(1, 2147483647), math.random(1, 2147483647))
local dispatch_serial = 0
local function dispatch_id(): string dispatch_serial += 1; return incarnation .. "-" .. tostring(dispatch_serial) end
-- Bounded FIFO map: once `limit` keys are held, the oldest key ages out.
local function fifo(limit: number): any
	local map: any = { values = {}, order = {} }
	function map.put(key: any, value: any)
		if map.values[key] == nil then
			table.insert(map.order, key)
			if #map.order > limit then map.values[table.remove(map.order, 1)] = nil end
		end
		map.values[key] = value
	end
	return map
end
local function host_for(cx: WindowCx, pane: number): any?
	for _, host in cx.hosts:list() do
		for _, candidate in host.panes do
			if candidate == pane then return host end
		end
	end
	return nil
end
local function panes_on(cx: WindowCx, host: any): { any }
	local members = {}
	for _, pane in host.panes do members[pane] = true end
	local result = {}
	for _, pane in cx.session:panes() do
		if members[pane.pane] then table.insert(result, pane) end
	end
	return result
end
-- Execution and control consume only role-keyed native plugin nodes, never rendered
-- conversation text. Native role=user messages do not prove human-input provenance.
local function role_node(node: any, role: string, depth: number, limit: number, whole: boolean): any?
	if type(node) ~= "table" or depth > limit or (whole and node.more ~= nil and node.more ~= 0) then return nil end
	if node.k == "text" and type(node.p) == "table" and node.p.role == role then return node end
	for _, child in (if type(node.c) == "table" then node.c else {}) do
		local found = role_node(child, role, depth + 1, limit, whole)
		if found then return found end
	end
	return nil
end
-- A node's text when it is exactly one span of at most `limit` bytes.
local function span_text(node: any, limit: number): string?
	local spans = node.p.spans
	if type(spans) ~= "table" or #spans ~= 1 then return nil end
	local text = if type(spans[1]) == "string" then spans[1] else spans[1].t
	return if type(text) == "string" and #text <= limit then text else nil
end
local function alias(cx: WindowCx, pane: number): any?
	local info = cx.session:pane(pane)
	if info == nil or info.block ~= BLOCK then return nil end
	local ok, tree = pcall(function() return cx.session:surface(pane, { root = "main.ownership-alias", nodes = 4, depth = 2, max_chars = 8192 }) end)
	local node = if ok and type(tree) == "table" then role_node(tree.main, "orchplus.alias", 0, 12, false) else nil
	local encoded = if node then span_text(node, 8192) else nil
	if not encoded then return nil end
	local parsed, value = pcall(tern.json.decode, encoded)
	return if parsed and type(value) == "table" and value.version == 2 and type(value.alias_nonce) == "string" then value else nil
end
local function matching_owner(cx: WindowCx, source: number, nonce: string?): (any?, string?)
	if nonce == nil then return nil, "Owner has no proven window alias. Inspect the recorded owner manually; no native target will be guessed." end
	local host = host_for(cx, source)
	if host == nil or host.state ~= "connected" then return nil, "Source host is unavailable. Ownership remains occupied." end
	local match = nil
	for _, pane in panes_on(cx, host) do
		if pane.block ~= BLOCK then continue end
		local bridge = alias(cx, pane.pane)
		if bridge ~= nil and bridge.alias_nonce == nonce then
			if match ~= nil then return nil, "Ambiguous owner aliases. Select the logical registration and inspect its owners manually; no pane was chosen." end
			match = pane
		end
	end
	return match, if match == nil then "Owner alias unavailable in this same-host window snapshot. It may be parked, moved, disconnected or restored; absence is not termination." else nil
end
local function valid_source(cx: WindowCx, source: number, request: any): boolean
	local bridge = alias(cx, source)
	if bridge == nil or bridge.alias_nonce ~= request.source_nonce or bridge.orch_session_id ~= request.orch_session_id
		or bridge.authority_namespace ~= request.authority_namespace or bridge.revision ~= request.expected_revision then return false end
	local owner = if type(bridge.owners) == "table" then bridge.owners[request.target] else nil
	return owner ~= nil and owner.owner_id == request.owner_id and owner.generation == request.generation and owner.alias_nonce == request.owner_alias
end
local function result(cx: WindowCx, source: number, request: any, message: string, observation: string?)
	if #message > 2048 then
		message = "Assistance detail omitted because it exceeds the display limit. Recorded owner "
			.. request.owner_id .. " / generation " .. tostring(request.generation) .. ". Inspect/recheck the recorded owner."
	end
	cx.session:event(source, { ev = "action", id = "main", act = "assistance-result", value = tern.json.encode({
		source_nonce = request.source_nonce, target = request.target, owner_id = request.owner_id, generation = request.generation,
		message = message, observation = observation, revision = request.revision, orch_session_id = request.orch_session_id,
		authority_namespace = request.authority_namespace, expected_revision = request.expected_revision,
	}) })
	cx:toast("info", "ORCH+", message)
end
local function describe(pane: any): string
	-- Titles are unbounded display text, not identity; omit them rather than byte-truncate UTF-8.
	return "Window pane " .. tostring(pane.pane) .. " · "
		.. (if pane.parked then "parked" else "visible/attached") .. "; presence is not quiescence."
end
local function assist(cx: WindowCx, source: number, request: any)
	if not valid_source(cx, source, request) then
		cx:toast("error", "ORCH+ stale assistance", "The displayed registration, owner or revision changed. Reopen its current recovery controls.")
		return
	end
	local pane, reason = matching_owner(cx, source, request.owner_alias)
	if pane == nil then
		result(cx, source, request, reason or "Owner unavailable; inspect manually.", "unavailable")
		return
	end
	if request.kind == "inspect" or request.kind == "recheck" then
		result(cx, source, request, describe(pane), "active")
	elseif request.kind == "reveal" then
		if pane.parked then
			local ok, error_message = cx.layout:unpark(pane.pane)
			if not ok then result(cx, source, request, "Reveal failed: " .. tostring(error_message)); return end
		end
		cx.layout:focus(pane.pane)
		result(cx, source, request, "Revealed recorded owner. " .. describe(pane), "active")
	elseif request.kind == "stop" then
		local input_session, input_host = cx.sessions:current(), cx.hosts:current()
		cx:pick({ placeholder = "Stop this recorded controller? Ownership will NOT be cleared.", items = {
			{ label = "Cancel — keep owner running", stop = false },
			{ label = "Close recorded controller " .. request.owner_id, detail = describe(pane), stop = true },
		} }):next(function(choice: any, err: string?, next_cx: WindowCx?)
			if next_cx == nil or choice == nil or err ~= nil or choice.stop ~= true then return end
			local now, selected = next_cx.sessions:current(), next_cx.hosts:current()
			local source_info = next_cx.session:pane(source)
			local attached = false
			for _, tab in next_cx.session:tabs() do
				if source_info and tab.id == source_info.tab and tab.session == input_session.id then attached = true; break end
			end
			if now.id ~= input_session.id or now.host ~= input_host.id or selected.id ~= input_host.id
				or selected.state ~= "connected" or not attached then return end
			if not valid_source(next_cx, source, request) then
				next_cx:toast("error", "ORCH+ stop refused", "Owner or revision changed during confirmation.")
				return
			end
			local current = matching_owner(next_cx, source, request.owner_alias)
			if current == nil or current.pane ~= pane.pane then
				result(next_cx, source, request, "Owner alias changed or became unavailable. No pane was closed.", "unavailable")
				return
			end
			-- Assistance can close its proven controller block only, never type into or guess an AI/shell.
			next_cx.layout:close(current.pane)
			if current.pane ~= source then
				result(next_cx, source, request, "Close requested. Ownership is retained; independently verify stop and reconcile executors before recovery.", "unavailable")
			else
				next_cx:toast("info", "ORCH+ owner closed", "Open ORCH+ again, select the existing registration, inspect and explicitly recover. No ownership was cleared.")
			end
		end)
	end
end
local function tab_sessions(cx: WindowCx): { [number]: number }
	local membership = {}
	for _, session in cx.session:sessions() do
		for _, tab in session.tabs do membership[tab] = session.id end
	end
	return membership
end
local function new_view(cx: WindowCx, config: boolean?): number?
	-- New entry gets its own fullscreen tab; existing views keep their arrangements.
	local pane = cx:new_block(BLOCK, if config then { "config" } else {}, "tab")
	if pane == nil then cx:toast("error", "ORCH+ unavailable", "This host has no Ready ORCH+ plugin.") end
	return pane
end
local function reveal(cx: WindowCx, pane: number, config: boolean?)
	cx.layout:focus(pane)
	-- Config mode is display-only in the block; editing still requires its admitted controller.
	if config then cx.session:event(pane, { ev = "action", id = "main", act = "config-open-request", value = "{}" }) end
end
local function open(cx: WindowCx, config: boolean?)
	local current = cx.sessions:current()
	local host = cx.hosts:current()
	local membership = tab_sessions(cx)
	local existing = {}
	local ambiguous = false
	for _, pane in panes_on(cx, host) do
		if pane.block ~= BLOCK then continue end
		local session_id = if pane.tab ~= nil then membership[pane.tab] else nil
		if session_id == current.id then
			table.insert(existing, { pane = pane, uncertain = false })
		elseif session_id == nil then
			-- Parked/restored membership is unknown, not proof that it belongs here.
			table.insert(existing, { pane = pane, uncertain = true })
			ambiguous = true
		end
		-- A known other-session view is never an automatic routing target.
	end
	if #existing == 0 then
		new_view(cx, config)
	elseif #existing == 1 and not ambiguous then
		reveal(cx, existing[1].pane.pane, config)
	else
		local items = {
			{ label = "Open a new ORCH+ view", detail = "Open an empty view in this session. No agent will start.", new_view = true },
		}
		for _, entry in existing do
			local pane = entry.pane
			table.insert(items, {
				label = pane.title or "Orchestration view",
				detail = if entry.uncertain then "Its session is not confirmed. Inspect this existing view without restarting work."
					else "Open this existing orchestration view.",
				pane = pane.pane,
			})
		end
		-- The unknown/parked candidate cannot own a native form. Use only a positively
		-- current-session source; this display carrier grants no authority to any target.
		local source = nil
		for _, pane in panes_on(cx, host) do
			if not pane.parked and pane.tab ~= nil and membership[pane.tab] == current.id then source = pane.pane; break end
		end
		local empty_source = nil
		if source == nil then source = new_view(cx, config); empty_source = source end
		if source == nil then return end
		forms_ui.choose(cx, source, nil, { placeholder = "Choose an orchestration view", items = items }, function(next_cx: WindowCx, choice: any)
			if choice == nil then return end
			-- Close the chooser before navigation; its automatic close would otherwise
			-- return focus to the carrier after the chosen view was revealed.
			forms_ui.cancel(next_cx, source)
			local now = next_cx.sessions:current()
			if now.id ~= current.id or now.host ~= current.host then
				next_cx:toast("error", "ORCH+ routing changed", "The current session changed during selection. Open ORCH+ again.")
				return
			end
			if choice.new_view then
				if empty_source then reveal(next_cx, empty_source, config) else new_view(next_cx, config) end
				return
			end
			local pane = next_cx.session:pane(choice.pane)
			local selected_host = host_for(next_cx, choice.pane)
			if pane == nil or pane.block ~= BLOCK or selected_host == nil or selected_host.id ~= host.id then return end
			local owner_session = if pane.tab ~= nil then tab_sessions(next_cx)[pane.tab] else nil
			if owner_session ~= nil and owner_session ~= now.id then
				next_cx:toast("error", "ORCH+ view moved", "The chosen view belongs to another session. No session was switched.")
				return
			end
			if pane.parked then
				local ok = next_cx.layout:unpark(pane.pane)
				if not ok then next_cx:toast("error", "ORCH+", "The selected view could not be revealed."); return end
			end
			reveal(next_cx, pane.pane, config)
		end)
	end
end
-- Rebuild a decoded value: arrays carry the native array marker, which table.clone cannot copy.
local function plain(value: any): any
	if type(value) ~= "table" or value == tern.json.null then return value end
	local out = if getmetatable(value) ~= nil then tern.json.array() else {}
	for key, child in value do out[key] = plain(child) end
	return out
end
-- The tick re-reads the same host-published nodes many times per turn and a strict decode costs
-- most of the 50 ms budget, so successful decodes are memoized by exact bytes. Callers may mutate
-- what they read: each read gets its own copy.
local decoded = (function()
	local cache = fifo(128)
	return function(bytes: string, maximum: number): any?
		if #bytes > maximum then return nil end
		local hit = cache.values[bytes]
		if hit == nil then
			hit = codec.strict_decode(bytes, maximum)
			if hit == nil then return nil end
			cache.put(bytes, hit)
		end
		return plain(hit)
	end
end)()
local function surface_node(cx: WindowCx, pane: number, block: string, role: string, explicit_key: string?, max_bytes: number?): (any?, string?)
	local info = cx.session:pane(pane)
	if info == nil or info.block ~= block then return nil, nil end
	local key = explicit_key or (if role == "spawn.dispatch.response" then "spawn-dispatch-response" elseif role == "orchplus.request" then "dispatch-request" else "dispatch-state")
	local root = "main." .. key
	local limit = max_bytes or 8192
	local ok, tree = pcall(function() return cx.session:surface(pane, { root = root, nodes = 4, depth = 2, max_chars = limit }) end)
	if not ok or type(tree) ~= "table" or type(tree.surface) ~= "table" or tree.surface.role ~= "plugin." .. block or (tree.more ~= nil and tree.more ~= 0) then return nil, nil end
	local node = role_node(tree.main, role, 0, 16, true)
	if node == nil or node.id ~= root then return nil, nil end
	local bytes = span_text(node, limit)
	if not bytes then return nil, nil end
	return node, bytes
end
local function snapshot(cx: WindowCx, pane: number, action_id: string?): (any?, any?)
	local limit = if action_id then 8192 else 65536
	local node, bytes = surface_node(cx, pane, BLOCK, "orchplus.dispatch", if action_id then "dispatch-action-" .. action_id else nil, limit)
	if not bytes then return nil, nil end
	local value = decoded(bytes, limit)
	if value and value.action then
		if action_id and value.action.action_id ~= action_id then return nil, nil end
		local draft = value.action.phase == "ready" or value.action.phase == "held_ready"
		local key = (if draft then "dispatch-draft" else "dispatch-request") .. (if action_id then "-" .. action_id else "")
		local _, request_bytes = surface_node(cx, pane, BLOCK, if draft then "orchplus.draft" else "orchplus.request", key)
		local request = if request_bytes then decoded(request_bytes, 8192) else nil
		if not request or request.action_id ~= value.action.action_id then return nil, nil end
		value.action.request = request; value.action.request_bytes = if draft then nil else request_bytes
	end
	return value, node
end
	-- Fences belong to intent instances, never to a mutable native binding or generic sender.
local intent_fences = setmetatable({}, { __mode = "k" })
local function intent_origin(origin: any, captured: any): any
	local copy = table.clone(origin)
	intent_fences[copy] = { authority_namespace = captured.authority_namespace,
		expected_revision = captured.expected_revision or captured.authority_revision }
	return copy
end
local function fresh_intent(cx: WindowCx, source: number, origin: any): any
	local captured = snapshot(cx, source)
	return intent_origin(origin, captured or {})
end
local function origin_now(cx: WindowCx, source: number, request: any): any?
	local data = snapshot(cx, source)
	local host = host_for(cx, source); local current = cx.sessions:current(); local pane = cx.session:pane(source)
	local membership = tab_sessions(cx)
	if not data or data.source_nonce ~= request.source_nonce or data.orch_session_id ~= request.orch_session_id
		or not host or host.state ~= "connected" or cx.hosts:current().id ~= host.id
		or not pane or pane.tab == nil or membership[pane.tab] ~= current.id then return nil end
	if not data.owner_id then
		local close = if data.session_control then data.session_control.close else nil
		local binding = if close and close.control_origin then close.control_origin.binding else nil
		if not binding or not table.find({ "close_session", "bridge_reconcile", "forget_session", "forget_continue" }, request.command)
			or binding.window_key ~= cx:window_key() or binding.native_session_id ~= tostring(current.id)
			or binding.window_host_id ~= tostring(host.id) or binding.alias_nonce ~= data.source_nonce then return nil end
		return intent_origin(binding, if request.authority_namespace ~= nil then request else data)
	end
	return intent_origin({ logical_session_id = data.orch_session_id, owner_id = data.owner_id, owner_generation = data.owner_generation,
		host_pane_id = data.host_pane_id, alias_nonce = data.source_nonce, window_key = cx:window_key(), window_epoch = incarnation,
		native_session_id = tostring(current.id), window_host_id = tostring(host.id) },
		if request.authority_namespace ~= nil then request else data)
end
-- Human responses must still belong to the actual native input context, even when
-- their custom authority guard also permits background settlement.
local native_scope: any = {}
function native_scope.input_context(cx: WindowCx, source: number, origin: any): boolean
	local current, selected = cx.sessions:current(), cx.hosts:current()
	local pane, host = cx.session:pane(source), host_for(cx, source)
	return pane ~= nil and not pane.parked and pane.tab ~= nil and host ~= nil and host.state == "connected"
		and selected.state == "connected" and selected.id == host.id and current.host == host.id
		and origin.window_key == cx:window_key() and tostring(host.id) == origin.window_host_id
		and tostring(current.id) == origin.native_session_id and tab_sessions(cx)[pane.tab] == current.id
end
-- Background authority comes from the captured native binding, never the selected session.
-- SessionCx reads/events and AgentsCx get/ask accept numeric pane ids across this window.
function native_scope.owned_origin(cx: WindowCx, source: number, origin: any): boolean
	local data = snapshot(cx, source)
	local pane, host = cx.session:pane(source), host_for(cx, source)
	if not data or not pane or pane.block ~= BLOCK or pane.parked or pane.tab == nil
		or not host or host.state ~= "connected" or tostring(host.id) ~= origin.window_host_id
		or tostring(tab_sessions(cx)[pane.tab]) ~= origin.native_session_id
		or origin.window_key ~= cx:window_key() or origin.window_epoch ~= incarnation
		or data.source_nonce ~= origin.alias_nonce or data.orch_session_id ~= origin.logical_session_id
		or data.host_pane_id ~= origin.host_pane_id or data.owner_id ~= origin.owner_id
		or data.owner_generation ~= origin.owner_generation then return false end
	local cursor = data.command_cursor
	if not cursor or cursor.controller_pane ~= tostring(source) then return false end
	for key, value in origin do if cursor.origin[key] ~= value then return false end end
	for key, value in cursor.origin do if origin[key] ~= value then return false end end
	return true
end
local function closing_context(cx: WindowCx, source: number, origin: any, read_only: boolean?): boolean
	local data = snapshot(cx, source)
	local close = if data and data.session_control then data.session_control.close else nil
	local control = if close then close.control_origin else nil
	if not control or control.kind ~= "closing" then return false end
	local pane, host = cx.session:pane(source), host_for(cx, source)
	if not pane or not host or host.state ~= "connected" or tostring(host.id) ~= origin.window_host_id
		or pane.parked or pane.tab == nil or tostring(tab_sessions(cx)[pane.tab]) ~= origin.native_session_id
		or origin.window_key ~= cx:window_key() or (not read_only and origin.window_epoch ~= incarnation) then return false end
	for key, value in control.binding do if origin[key] ~= value then return false end end
	return data.source_nonce == origin.alias_nonce and control.controller_pane == tostring(source)
end
local function current_context(cx: WindowCx, source: number, origin: any): boolean
	local now = origin_now(cx, source, { source_nonce = origin.alias_nonce, orch_session_id = origin.logical_session_id })
	if now == nil then return false end
	for k, v in origin do if now[k] ~= v then return false end end
	return true
end
local function current_origin(cx: WindowCx, source: number, origin: any): boolean
	if not current_context(cx, source, origin) then return false end
	local data = snapshot(cx, source)
	local cursor = if data then data.command_cursor else nil
	if cursor and cursor.origin.owner_id == origin.owner_id and cursor.origin.owner_generation == origin.owner_generation then
		for key, value in cursor.origin do if origin[key] ~= value then return false end end
	end
	return true
end
function native_scope.authorized_origin(cx: WindowCx, source: number, origin: any): boolean
	-- Foreground bootstrap has no durable cursor until its first command commits.
	-- Only an existing captured cursor may authorize a nonselected source.
	return native_scope.owned_origin(cx, source, origin) or current_origin(cx, source, origin)
end
-- Names the first authority check that failed, in the order owned_origin makes them, so a notice
-- says what is wrong instead of guessing. Call it only after authorized_origin returned false.
function native_scope.authority_gap(cx: WindowCx, source: number, origin: any): string
	local data = snapshot(cx, source)
	local pane, host = cx.session:pane(source), host_for(cx, source)
	if not data then return "the controller's published state cannot be read in this window" end
	if not host or host.state ~= "connected" then return "the execution host is not connected" end
	if not pane or pane.block ~= BLOCK or pane.parked or pane.tab == nil then return "the controller's pane is not available in this window" end
	if tostring(host.id) ~= origin.window_host_id or tostring(tab_sessions(cx)[pane.tab]) ~= origin.native_session_id then
		return "the selected host or session is not the one this command was prepared for"
	end
	if origin.window_key ~= cx:window_key() or origin.window_epoch ~= incarnation then return "this window was reloaded or replaced after the command was prepared" end
	if data.source_nonce ~= origin.alias_nonce or data.orch_session_id ~= origin.logical_session_id or data.owner_id ~= origin.owner_id
		or data.owner_generation ~= origin.owner_generation or data.host_pane_id ~= origin.host_pane_id then
		return "another window or a newer generation now holds this controller"
	end
	return "the controller's recorded command position does not match this window"
end
local function notice(cx: WindowCx, source: number, nonce: string, message: string, level: string?, title: string?, metadata: any?)
	local severity = level or "error"
	local payload = { source_nonce = nonce, message = message, level = severity }
	if metadata then
		payload.context, payload.code = metadata.context, metadata.code
		local detail = metadata.detail
		if type(detail) == "string" then
			payload.detail = if #detail <= 2048 and utf8.len(detail) ~= nil then detail else "Technical details exceed the display limit. Inspect the retained action in Advanced."
		end
	end
	local _, node = snapshot(cx, source)
	if node then cx.session:event(source, { ev = "action", id = node.id, act = "dispatch-notice", value = tern.json.encode(payload) }) end
	cx:toast(severity :: any, title or "ORCH+", message)
end
local command_cursors: any = {}
-- Deep equality: policies carry the excluded_workers list, so the stale-editor check compares deeply.
local function same_policy(left: any, right: any): boolean
	if type(left) ~= type(right) then return false end
	if type(left) ~= "table" then return left == right end
	for key, value in left do if not same_policy(value, right[key]) then return false end end
	for key in right do if left[key] == nil then return false end end
	return true
end
local function same_origin(left: any, right: any): boolean
	return type(left) == "table" and type(right) == "table" and same_policy(left, right)
end
local setup_api: any = { surface = surface_node, decode = decoded, host = host_for,
	membership = tab_sessions, epoch = incarnation, same = same_policy, copy = plain, id = dispatch_id,
	family = dispatch.provider_family, decode_setup_response = dispatch.decode_setup_response }
forms_ui = require("./form_window").new({ surface = surface_node, id = dispatch_id,
	host = host_for, membership = tab_sessions, same = same_policy })
setup_api.forms = forms_ui
local setup_ui = require("./setup_window").new(setup_api)
-- Request IDs this window incarnation sent: a refusal is this window's own evidence only when it
-- answers one of them, so another window's (or older incarnation's) refusal never holds a driver.
local issued = fifo(512)
-- send_command returns the request id, or nil with the plain reason it refused; a third value true
-- means the command was already handed to the native transport before the window lost its authority
-- (the host may or may not have applied it).
-- native_scope.return_refusal: an oversized envelope is returned as the reason for the caller to
-- display, never noticed here, so one click has one outcome. Only owner_send and the owner's capacity
-- reader set it, through native_scope.send_returning.
-- (The window sits at Luau's 200-local limit, so the owner-send helpers hang on this table.)
native_scope.return_refusal = false
local function send_command(cx: WindowCx, source: number, origin: any, command: string, fields: any?, operator: boolean?): (string?, string?, boolean?)
	local closing = (command == "bridge_control" or command == "bridge_result" or command == "bridge_observe")
		and closing_context(cx, source, origin, command == "bridge_observe")
	if not closing and not (if command == "continue_controller" then current_context(cx, source, origin)
		else native_scope.authorized_origin(cx, source, origin)) then
		return nil, "this window cannot act as the controller: " .. native_scope.authority_gap(cx, source, origin) .. ". Continue the controller in this window, then try again."
	end
	local data, node = snapshot(cx, source)
	if not node then return nil, "the controller's state cannot be read in this window right now. Try again in a moment." end
	local fence = intent_fences[origin]
	if not fence or type(fence.authority_namespace) ~= "string" or type(fence.expected_revision) ~= "number" then
		return nil, "this command carries no controller revision to check against (it was prepared without a fence). Click the control again."
	end
	local event = { kind = "dispatch", request_id = dispatch_id(), orch_session_id = origin.logical_session_id, origin = origin,
		controller_pane = tostring(source), command = command,
		authority_namespace = fence.authority_namespace, expected_revision = fence.expected_revision }
	for k, v in fields or {} do event[k] = v end
	if command ~= "claim" and command ~= "result" and command ~= "lost" and command ~= "spawn_claimed" then
		local retained = command_cursors[source]
		local seq = if retained and same_origin(retained.origin, origin) then retained.seq else 0
		local committed = data.command_cursor
		if committed then seq = math.max(seq, committed.seq) end
		event.command_seq = seq + 1
		command_cursors[source] = { origin = origin, seq = event.command_seq }
	end
	if command == "observe" then event.observation_seq = dispatch_serial end
	local bytes = tern.json.encode(event)
	if #bytes > (if command == "policy" or command == "cancel_work" or command == "observe_allocation" then dispatch.NATIVE_COMMAND_BYTES elseif command == "bridge_result" or command == "bridge_observe" or command == "source_request" then codec.LIMITS.logical else 8192) then
		local refusal = if command == "policy" then "These settings exceed the supported native settings envelope. Your draft is retained; shorten templates or guidance."
			elseif command == "cancel_work" or command == "observe_allocation" then "The allocation evidence exceeds the supported native envelope. Work remains held; no proof was truncated or request sent."
			elseif command == "capacity" then "The capacity evidence exceeds the 8192-byte native bridge limit. Nothing was sent."
			else "Task request exceeds the 8192-byte native bridge limit; shorten the explicit assignment. Nothing was queued."
		if native_scope.return_refusal then return nil, refusal end
		notice(cx, source, origin.alias_nonce, refusal)
		return nil
	end
	cx.session:event(source, { ev = "action", id = node.id, act = if operator then "dispatch-operator-command" else "dispatch-command", value = bytes })
	issued.put(event.request_id, true)
	-- Native delivery returns before HOST commits the continued window origin.
	-- Use the same guard as admission; the old cursor must not hide a submitted continuation.
	if closing or (if command == "continue_controller" then current_context(cx, source, origin)
		else native_scope.authorized_origin(cx, source, origin)) then return event.request_id end
	return nil, "Handed to the native transport, but this window could not confirm the controller afterwards ("
		.. native_scope.authority_gap(cx, source, origin) .. "). This window could not verify the host's response; the result may not show here. Check before sending again.", true
end
-- send_command for an owner's own command: its refusal, including an oversized envelope, comes back
-- as the reason and nothing is noticed inside, so the caller shows exactly one outcome.
function native_scope.send_returning(cx: WindowCx, source: number, origin: any, command: string, fields: any?, operator: boolean?): (string?, string?, boolean?)
	native_scope.return_refusal = true
	local ok, id, why, emitted = pcall(send_command, cx, source, origin, command, fields, operator)
	native_scope.return_refusal = false
	if not ok then error(id, 0) end
	return id, why, emitted
end
-- An owner's own command that could not be sent says so; a silent click reads as a broken button.
function native_scope.owner_send(cx: WindowCx, source: number, origin: any, command: string, fields: any?): string?
	local id, why, emitted = native_scope.send_returning(cx, source, origin, command, fields, true)
	if not id and why then
		notice(cx, source, origin.alias_nonce, if emitted then why else "Not sent: " .. why)
	end
	return id
end
local function workflow_node(cx: WindowCx, source: number, key: string, role: string): any?
	-- workflow-index carries the policy with three bounded routing allowlists; 64 KiB covers them.
	local _, bytes = surface_node(cx, source, BLOCK, role, key, codec.LIMITS.logical)
	return if bytes then decoded(bytes, codec.LIMITS.logical) else nil
end
function native_scope.project_start_delivery(cx: WindowCx, source: number, action_id: string): any?
	local index = workflow_node(cx, source, "project-index", "orchplus.projects")
	for _, project in (if index and type(index.projects) == "table" then index.projects else {}) do
		local start = project.start
		if type(start) == "table" and start.delivery_action_id == action_id then return start end
	end
	return nil
end
local function worker_now(cx: WindowCx, source: number, worker_id: string): any?
	local worker = workflow_node(cx, source, "workflow-worker-" .. worker_id, "orchplus.worker")
	return if worker and worker.worker_id == worker_id then worker else nil
end
-- The pane, when it sits on its connected host and native session exactly as `scope` records them.
local function scoped_pane(cx: WindowCx, pane: number?, scope: any, membership: any?): any?
	local info = if pane then cx.session:pane(pane) else nil
	local host = if pane then host_for(cx, pane) else nil
	if not info or not host or host.state ~= "connected" or tostring(host.id) ~= scope.window_host_id then return nil end
	if info.parked or info.tab == nil or tostring((membership or tab_sessions(cx))[info.tab]) ~= scope.native_session_id then return nil end
	return info
end
local function native_observation(cx: WindowCx, source: number, worker: any): (string, string?, any?, string?)
	local binding, origin = worker.pane_binding, worker.origin_binding
	if not binding or not origin or not native_scope.authorized_origin(cx, source, origin)
		or binding.window_key ~= cx:window_key() or binding.window_epoch ~= incarnation
		or binding.native_session_id ~= origin.native_session_id or binding.window_host_id ~= origin.window_host_id then
		return "unknown", "Awaiting the exact authorized window/session binding; after reload run ORCH+ Continue controller in this window from the palette. Restored numeric pane IDs are not identity.", nil
	end
	local target = tonumber(binding.pane_id)
	local pane = scoped_pane(cx, target, binding)
	if not pane then
		return "unknown", "Bound pane unavailable, moved or parked without current session evidence; absence is not exit.", nil
	end
	if pane.exited ~= nil then return "exited", nil, pane end
	for _, agent in cx.agents:list() do
		if agent.pane == target then
			local native = if agent.state == "waiting_input" then "waiting-input" else agent.state
			if not table.find({ "working", "idle", "waiting-input", "exited" }, native) then native = "unknown" end
			local problem = if type(agent.delivery_error) == "string" then
				(if #agent.delivery_error > 0 and #agent.delivery_error <= 1024 and utf8.len(agent.delivery_error) ~= nil then agent.delivery_error
					else "Native prompt delivery is held. Open this exact pane to inspect the full native error.") else nil
			return native, problem, pane, problem
		end
	end
	return "unknown", "Unrecognized terminal: lifecycle only; no native input or readiness inferred. A verified worker-poll capability is required for replies.", pane
end
local drivers: any = {}
local scans: any = {} -- per-source worker scan state (see the worker scan below)
local executed: any = {} -- grant_id -> true: set-before-send markers (pruned only once settled).
local held_actions: any = {}
-- Per-action bookkeeping (`executed`, `auto_reconcile`, `held_actions`) is pruned only on positive
-- evidence from the action's own controller pane that it settled; one watched action per tick.
local settle_watch: any, settle_order: any, settle_cursor = {}, {}, 0
local function watch_settle(source: number, action_id: string, grant_id: string?, request: any?, scope: any?)
	local entry = settle_watch[action_id]
	if entry == nil then entry = { grants = {} }; settle_watch[action_id] = entry; table.insert(settle_order, action_id) end
	entry.source = source
	if grant_id then entry.grants[grant_id] = true end
	if request then
		entry.authority_namespace = request.authority_namespace; entry.logical_session_id = request.logical_session_id
		entry.admission_seq = request.admission_seq; entry.request_serial = request.request_serial
		entry.origin = request.origin_binding
		entry.logical_session_id = entry.logical_session_id or request.origin_binding.logical_session_id
	end
	if scope then
		entry.authority_namespace = entry.authority_namespace or scope.authority_namespace
		entry.worker_id = scope.action.worker_id
	end
end
local bridge_by_source: any = {}
local retained_relays: any = {}
local relay_busy: any = {}
local timer: any = nil
-- Effect deadlines measure awake time: a tick gap far beyond TICK_MS (sleep, App Nap, a paused
-- hook) counts as one nominal tick, so deadlines are extended, never shortened.
local TICK_MS = 500
local SUSPENSION_GAP_MS = 5000
local EFFECT_DEADLINE_MS = 30000
local awake: any = { last = nil, suspended = 0 }
local function awake_now(): number return tern.now() - awake.suspended end
local function observe_tick()
	local now = tern.now()
	if awake.last ~= nil and now - awake.last > SUSPENSION_GAP_MS then awake.suspended += now - awake.last - TICK_MS end
	awake.last = now
end
-- Automatic read-only reconciliation of an uncertain retained effect: the owner's "Read retained
-- SPAWN outcome" status read, once per attempt after awake backoff; never a claim or re-send.
local AUTO_RECONCILE_DELAYS = { 2000, 10000, 30000, 60000 }
local auto_reconcile: any = {}
-- Idempotent ACK/reply publications also get "readback before retry": after one non-definitive
-- read the host resolves the attempt and the outbox re-issues the same immutable bytes, which SPAWN
-- reads back first. At most AUTO_READBACKS per publication identity (aging one out of the FIFO
-- repeats only a read-only readback).
local AUTO_READBACKS = 3
local auto_readback = fifo(512)
local function prune_settled(cx: WindowCx)
	if #settle_order == 0 then return end
	settle_cursor = settle_cursor % #settle_order + 1
	local action_id = settle_order[settle_cursor]
	local entry = settle_watch[action_id]
	local scoped, node = snapshot(cx, entry.source, action_id)
	local a = if scoped then scoped.action else nil
	local receipt = if scoped then scoped.receipt else nil
	local consumed = not a and scoped and scoped.authority_namespace == entry.authority_namespace
		and scoped.orch_session_id == entry.logical_session_id and receipt and receipt.action_id == action_id
		and ((receipt.grant_id ~= nil and entry.grants[receipt.grant_id] == true)
			or (next(entry.grants) == nil and receipt.withdrawal_request_id ~= nil and entry.worker_id ~= nil
				and receipt.worker_id == entry.worker_id and receipt.authority_namespace == entry.authority_namespace
				and receipt.logical_session_id == entry.logical_session_id))
	if not consumed then
		local data = snapshot(cx, entry.source)
		local control = if data then data.control else nil
		local request = if control then codec.decode_dispatch_request(control.request_bytes) else nil
		consumed = entry.request_serial ~= nil and request ~= nil and data.authority_namespace == entry.authority_namespace
			and data.orch_session_id == entry.logical_session_id and request.authority_namespace == entry.authority_namespace
			and table.find({ "admit_session", "reconcile_session", "close_session" }, request.op) ~= nil
			and request.logical_session_id == entry.logical_session_id and request.admission_seq == entry.admission_seq
			and (request.settled_before > entry.request_serial or table.find(request.consumed or {}, entry.request_serial) ~= nil)
		local session = if data then data.session_control else nil
		if not consumed and data and session and data.authority_namespace == entry.authority_namespace
			and data.orch_session_id == entry.logical_session_id then
			consumed = entry.request_serial ~= nil and session.admission_seq == entry.admission_seq
				and type(session.request_floor) == "number" and session.request_floor > entry.request_serial
			local cursor = data.command_cursor
			if not consumed and next(entry.grants) == nil and entry.origin then
				consumed = session.generation_floor >= entry.origin.owner_generation
					or (cursor ~= nil and cursor.continued_epoch ~= nil and not same_origin(cursor.origin, entry.origin))
			end
		end
		if not consumed then
			local owner = alias(cx, entry.source)
			consumed = owner ~= nil and owner.authority_namespace == entry.authority_namespace
				and owner.orch_session_id == entry.logical_session_id and owner.session_closed == true
		end
	end
	if consumed then
		if receipt and receipt.withdrawal_request_id and node and entry.origin then
			cx.session:event(entry.source, { ev = "action", id = node.id, act = "dispatch-release-scope", value = tern.json.encode({
				source_nonce = entry.origin.alias_nonce, action_id = action_id, worker_id = entry.worker_id,
				withdrawal_request_id = receipt.withdrawal_request_id,
			}) })
		end
		for grant in entry.grants do executed[grant] = nil end
		auto_reconcile[action_id] = nil; held_actions[action_id] = nil
		settle_watch[action_id] = nil; table.remove(settle_order, settle_cursor); settle_cursor -= 1
		return
	end
	if not a or a.action_id ~= action_id or scoped.authority_namespace ~= entry.authority_namespace
		or scoped.orch_session_id ~= entry.logical_session_id then return end
	local live = if a.claim then a.claim.grant_id else nil
	-- The live grant's marker survives while claimed, uncertain or backpressured under it.
	for grant in entry.grants do if grant ~= live then executed[grant] = nil; entry.grants[grant] = nil end end
	local reconcile = auto_reconcile[action_id]
	if reconcile and reconcile.grant_id ~= live then auto_reconcile[action_id] = nil end
	if next(entry.grants) == nil and auto_reconcile[action_id] == nil and not held_actions[action_id] then
		settle_watch[action_id] = nil; table.remove(settle_order, settle_cursor); settle_cursor -= 1
	end
end
-- A claim refused with `full` is pre-effect (still `ready`, never granted): it resumes with awake
-- backoff under the same host claim rules, at most CAPACITY_RETRIES times, then holds for the owner.
local CAPACITY_RETRY_MS = 5000
local CAPACITY_RETRIES = 120
local capacity_waits: any = {}
-- A claim is sent once with its captured fence. Missing replies require observation, not a refreshed retry.
local CLAIM_NOTICE_MS = 1000
local claims_in_flight: any = {}
-- A captured SPAWN outcome awaiting its host receipt is replayed (idempotently) with backoff. `lost`
-- is sent only after DELIVERY_IDLE_MS without rendered host progress (Tern's longest hook pause is
-- 5 min) or DELIVERY_MAX_MS in total, both awake time.
local REPLAY_RETRY_MS = { 1000, 2000, 4000, 8000, 15000 }
local DELIVERY_IDLE_MS = 300000
local DELIVERY_MAX_MS = 900000
local function retry_delay(delays: { number }, attempt: number): number
	return delays[math.clamp(attempt, 1, #delays)]
end
-- What the controller block rendered for this scope; changes whenever the host answers for it.
local function host_progress(data: any): string
	local r = data.result
	return tostring(data.revision) .. "|" .. tostring(if r then r.request_id else nil) .. "|" .. tostring(if r then r.code else nil)
end
local function capacity_hold(source: number, action_id: string, stale: any, scope: any)
	local wait = capacity_waits[action_id] or { attempts = 0 }
	claims_in_flight[action_id] = nil -- The refused claim is answered; the capacity backoff owns the retry.
	wait.attempts += 1; wait.next_at = awake_now() + CAPACITY_RETRY_MS; wait.stale = stale; wait.source = source
	if wait.attempts > CAPACITY_RETRIES then capacity_waits[action_id] = nil; held_actions[action_id] = true; watch_settle(source, action_id, nil, scope.action.request, scope)
	else capacity_waits[action_id] = wait end
end
-- Ready to (re)claim now, plus the refusal result a resumed driver must not mistake for its own.
local function capacity_ready(action_id: string): (boolean, any)
	local wait = capacity_waits[action_id]
	if not wait then return true, nil end
	return awake_now() >= wait.next_at, wait.stale
end
-- A retained `backpressure` action is SPAWN's definitive pre-effect refusal. It is rechecked with the
-- capacity backoff by the owner's exact `retry`, one per lane, at most CAPACITY_RETRIES times.
local recheck_waits: any = {}
-- `carried` is the replacement chain's retry count, so the bound survives each fresh action id.
local function recheck_hold(source: number, action_id: string, carried: number?)
	local wait = recheck_waits[action_id] or { attempts = carried or 0 }
	wait.next_at = awake_now() + CAPACITY_RETRY_MS; wait.source = source
	recheck_waits[action_id] = wait
end
local start_driver: any = nil -- Assigned after the observation timer helpers.
-- Reload recovery: pending read-only SPAWN owner_status probes and the last observed owner state.
local guides: any = {}
local owner_states: any = {}
-- Fenced never-launched work: a pending read-only SPAWN `status` per controller (see withdraw_step).
local withdrawals: any = {}
local allocation_reads: any = {}
local allocation_retries: any = {}
local allocation_notices: any = {}
-- One capacity reader per controller. Transport endpoints belong to the existing ORCH panel.
local readers: any = {}
local usage_by_source: any = {}
local validations: any = {}
local start_reader: any = nil
local reader_step: any = nil
-- Legacy native views are inspected only for positively confirmed closure, never reused as a carrier.
local BRIDGE_BLOCK = "spawn.dispatch"
local BRIDGE_LEASE_PREFIX = "SPAWN_BRIDGE v1 "
local BRIDGE_SCAN_LIMIT = 24
local function bridge_lease(cx: WindowCx, pane: number): (any?, any?)
	local node, bytes = surface_node(cx, pane, BRIDGE_BLOCK, "spawn.dispatch.lease", "spawn-dispatch-lease", 2048)
	if not bytes or bytes:sub(1, #BRIDGE_LEASE_PREFIX) ~= BRIDGE_LEASE_PREFIX then return nil, nil end
	local lease = codec.strict_decode(bytes:sub(#BRIDGE_LEASE_PREFIX + 1), 2048)
	if type(lease) ~= "table" or lease.schema ~= 1 or type(lease.held) ~= "boolean" or type(lease.live) ~= "boolean" or type(lease.busy) ~= "boolean" then return nil, nil end
	local owner = lease.owner
	if owner ~= nil and (type(owner) ~= "table" or type(owner.controller_pane) ~= "string" or type(owner.alias_nonce) ~= "string"
		or type(owner.window_key) ~= "string" or type(owner.window_epoch) ~= "string") then return nil, nil end
	return lease, node
end
local controls: any = {}
local pairings: any = {}
local ruling_jobs: any = {}
local captured_inputs: any = {}
local function control_pending(source: number, allow_form_read: boolean?): boolean
	local pending = controls[source]
	local ruling = ruling_jobs[source]
	local input = captured_inputs[source]
	return (pending ~= nil and (pending.creating ~= nil or pending.bytes ~= nil))
		or (ruling ~= nil and ruling.mode == "write" and not ruling.edit_started)
		or (input ~= nil and input.blocking)
		or (allow_form_read ~= true and forms_ui.active(source))
end
local function capture_input(source: number, origin: any, promise: any, done: (any, string?, WindowCx?) -> ())
	local input = { origin = origin, blocking = true }
	captured_inputs[source] = input
	promise:next(function(value: any, err: string?, fresh: WindowCx?)
		if captured_inputs[source] ~= input then return end
		captured_inputs[source] = nil
		if fresh == nil or not native_scope.input_context(fresh, source, origin) then return end
		done(value, err, fresh)
	end)
end
local function bridge_in_use(pane: number): boolean
	for _, driver in drivers do if driver.bridge == pane then return true end end
	for _, guide in guides do if guide.bridge == pane then return true end end
	for _, probe in withdrawals do if probe.bridge == pane then return true end end
	for _, control in controls do if control.bridge == pane then return true end end
	for _, pairing in pairings do if pairing.bridge == pane then return true end end
	return false
end
-- Reclaim only a consumed native view, not a pane or execution record. SPAWN
-- advertises positive peer closure; ORCH must independently expose its matching
-- session_closed alias before its final close ACK can be discarded.
local closed_view_scans: any = {}
local function release_closed_bridge_view(cx: WindowCx, source: number)
	local owner = alias(cx, source)
	if not owner or owner.session_closed ~= true then return end
	local panes = cx.session:panes()
	if #panes == 0 then closed_view_scans[source] = nil; return end
	local cursor, inspected = closed_view_scans[source] or 0, 0
	for _ = 1, #panes do
		if inspected == BRIDGE_SCAN_LIMIT then return end
		cursor = cursor % #panes + 1; closed_view_scans[source] = cursor
		local pane = panes[cursor]
		if pane.block ~= BRIDGE_BLOCK or bridge_in_use(pane.pane) then continue end
		inspected += 1
		local lease, node = bridge_lease(cx, pane.pane)
		local recipient = if lease then lease.owner else nil
		local scope = if lease then lease.closed_scope else nil
		if not recipient or not node or lease.live or lease.busy or type(scope) ~= "table"
			or recipient.controller_pane ~= tostring(source) or recipient.window_key ~= cx:window_key()
			or scope.authority_namespace ~= owner.authority_namespace or scope.logical_session_id ~= owner.orch_session_id
			or type(scope.admission_seq) ~= "number" or scope.admission_seq < 1 or scope.admission_seq % 1 ~= 0
			or type(scope.spawn_namespace) ~= "string" or type(scope.request_id) ~= "string" or type(scope.action_id) ~= "string" then continue end
		cx.session:event(pane.pane, { ev = "action", id = node.id, act = "spawn.release_closed_view", value = tern.json.encode({
			source_nonce = recipient.alias_nonce, authority_namespace = scope.authority_namespace,
			logical_session_id = scope.logical_session_id, admission_seq = scope.admission_seq,
			request_id = scope.request_id, action_id = scope.action_id, spawn_namespace = scope.spawn_namespace,
		}) })
		return
	end
end
-- Logical peer endpoints are not native panes. The real ORCH panel is their sole native carrier.
local function relay_index(cx: WindowCx, source: number, peer: string): (any?, any?)
	local node, bytes = surface_node(cx, source, BLOCK, "orchplus." .. peer .. "-relay", "orchplus-" .. peer .. "-relay", 65536)
	local value = if bytes then decoded(bytes, 65536) else nil
	local owner = alias(cx, source)
	if not value or value.schema ~= 1 or value.peer ~= peer or not owner or value.source_nonce ~= owner.alias_nonce
		or value.host_pane_id ~= owner.host_pane_id or type(value.relay_endpoint) ~= "string"
		or type(value.relay_boot) ~= "string" then return nil, nil end
	return value, node
end
local function relay_live(cx: WindowCx, endpoint: any): (any?, any?, any?)
	if type(endpoint) ~= "table" or not scoped_pane(cx, endpoint.source, endpoint.origin) then return nil, nil, nil end
	local value, node = relay_index(cx, endpoint.source, endpoint.peer)
	if not value or value.relay_endpoint ~= endpoint.relay_endpoint or value.relay_boot ~= endpoint.relay_boot
		or value.source_nonce ~= endpoint.source_nonce or value.host_pane_id ~= endpoint.host_pane_id then return nil, nil, nil end
	if endpoint.peer == "usage" then return value, node, value[endpoint.kind] end
	for _, lane in value.lanes or {} do
		if lane.lane_id == endpoint.lane_id then
			if endpoint.rebinding then
				if not lane.peer_boot or not lane.bind_id or lane.bind_id == endpoint.rebinding.bind_id then return value, node, nil end
				endpoint.peer_boot, endpoint.rebinding = lane.peer_boot, nil
			elseif endpoint.peer_boot and lane.peer_boot ~= endpoint.peer_boot then return nil, nil, nil end
			if lane.peer_boot then endpoint.peer_boot = lane.peer_boot end
			endpoint.bind_id = lane.bind_id
			return value, node, lane
		end
	end
	return value, node, nil
end
local function relay_event(cx: WindowCx, endpoint: any, event: any): boolean
	local value, _, lane = relay_live(cx, endpoint)
	local migration = if event.act == "migration" then decoded(event.value, 65536) else nil
	local read_only = event.act == "bind" or event.act == "status" or event.act == "owner_status" or event.act == "catalog" or event.act == "mailbox_inventory" or event.act == "mailbox_allocation" or event.act == "ack" or event.act == "release"
		or (migration ~= nil and migration.operation == "source")
	if not value or (not read_only and (endpoint.retiring or value.held or value.error or (lane and (lane.held or lane.error)))) then return false end
	local payload = { schema = 1, source_nonce = endpoint.source_nonce, relay_endpoint = endpoint.relay_endpoint,
		relay_boot = endpoint.relay_boot, bytes = event.value }
	if endpoint.peer == "spawn" then
		if event.act ~= "bind" and (not lane or not lane.peer_boot) then return false end
		payload.lane_id, payload.peer_boot, payload.act = endpoint.lane_id, if lane then lane.peer_boot else nil, event.act
	else
		payload.kind, payload.act = endpoint.kind, if event.act == "ack" then "ack" else "request"
		if payload.act == "request" then
			local request = decoded(event.value, 65536)
			if not request or type(request.request_id) ~= "string" then return false end
			endpoint.request_id = request.request_id
			if request.op == "snapshot" then endpoint.peer_boot, endpoint.peer_changed = nil, nil end
		end
	end
	cx.session:event(endpoint.source, { ev = "action", id = "main", act = endpoint.peer .. "_relay", value = tern.json.encode(payload) })
	if event.act ~= "release" and event.act ~= "ack" then endpoint.last_used = awake_now() end
	return true
end
local function relay_ack(cx: WindowCx, endpoint: any, kind: string, captured: any?): boolean
	local message = captured or (endpoint.reads and endpoint.reads[kind])
	if not message then return false end
	local identity = message.incarnation .. ":" .. message.id
	if endpoint.acked == identity then return true end
	if not relay_event(cx, endpoint, { act = "ack", value = tern.json.encode({ route = message.route, id = message.id, incarnation = message.incarnation }) }) then return false end
	endpoint.acked = identity
	return true
end
local function peer_surface(cx: WindowCx, endpoint: any, _block: string, role: string, _key: string?, maximum: number?): (any?, string?)
	local value, anchor, lane = relay_live(cx, endpoint)
	if not value or endpoint.retiring then return nil, nil end
	local kind = if endpoint.peer == "usage" then endpoint.kind
		elseif role == "spawn.dispatch.state" then "current"
		else "response"
	if endpoint.peer == "spawn" and (not lane or not lane.peer_boot) then return nil, nil end
	if endpoint.peer == "usage" and lane then
		if lane.request_id ~= endpoint.request_id then return anchor, nil end
		if endpoint.peer_boot and lane.peer_boot ~= endpoint.peer_boot then
			endpoint.peer_changed = true
			-- The restarted helper's reply to the retained read is never adopted, but the host holds the read until
			-- that exact reply is acknowledged; without this the next request is refused as read_pending.
			local reply = lane.message
			if type(reply) == "table" and reply.binding ~= nil and reply.id ~= nil and reply.incarnation == lane.peer_boot then relay_ack(cx, endpoint, endpoint.kind, reply) end
			return anchor, nil
		end
		if lane.peer_boot then endpoint.peer_boot = lane.peer_boot end
	end
	local proof = if endpoint.peer == "spawn" then lane.messages and lane.messages[kind] else lane and lane.message
	if not proof then return anchor, nil end -- Actual host relay is ready; no peer response is fabricated.
	if proof.incarnation ~= lane.peer_boot or proof.binding == nil or proof.id == nil then return nil, nil end
	local key = if endpoint.peer == "spawn" then "spawn-relay-" .. endpoint.lane_id .. "-" .. kind else "usage-relay-" .. kind .. "-response"
	local peer_role = if endpoint.peer == "spawn" then "orchplus.spawn-" .. kind else "orchplus.usage-" .. kind .. "-response"
	-- A retained-status envelope has bounded room beyond its ordinary result.
	-- Correlated decoders still enforce the response operation's own wire limit.
	local limit = maximum or (if endpoint.peer == "spawn" and kind == "response" then codec.LIMITS.bridge_status else codec.LIMITS.bridge)
	local node, bytes = surface_node(cx, endpoint.source, BLOCK, peer_role, key, limit)
	local again, _, current = relay_live(cx, endpoint)
	local after = if endpoint.peer == "spawn" then current and current.messages and current.messages[kind] else current and current.message
	if not again or not same_policy(proof, after) or not node or type(bytes) ~= "string" then return nil, nil end
	endpoint.reads = endpoint.reads or {}
	endpoint.reads[kind] = proof
	if kind == "current" then relay_ack(cx, endpoint, kind) end -- Read-only observation, never an execution/result receipt.
	endpoint.last_used = awake_now()
	return node, bytes
end
local function relay_endpoint(cx: WindowCx, source: number, peer: string, kind: string, origin: any, setup: boolean?): any?
	local value = relay_index(cx, source, peer)
	if not value or not scoped_pane(cx, source, origin) then return nil end
	local endpoint = { source = source, peer = peer, kind = kind, origin = plain(origin), source_nonce = value.source_nonce,
		host_pane_id = value.host_pane_id, relay_endpoint = value.relay_endpoint, relay_boot = value.relay_boot, setup = setup, last_used = awake_now() }
	if peer == "spawn" then
		endpoint.lane_id = "l" .. codec.sha256(dispatch_id()):sub(1, 20)
		if not relay_event(cx, endpoint, { act = "bind", value = tern.json.encode(origin) }) then return nil end
	end
	return endpoint
end
local function acquire_usage(cx: WindowCx, source: number, origin: any): any?
	local current = usage_by_source[source]
	if current then return if relay_live(cx, current) then current else nil end
	local endpoint = relay_endpoint(cx, source, "usage", "capacity", origin)
	usage_by_source[source] = endpoint
	return endpoint
end
local function acquire_bridge(cx: WindowCx, source: number, origin: any, lane: string): any?
	local key = tostring(source) .. ":" .. lane
	local existing = bridge_by_source[key]
	if existing then
		if not same_origin(existing.origin, origin) or not relay_live(cx, existing) then return nil end
		existing.last_used = awake_now()
		return existing
	end
	local endpoint = relay_endpoint(cx, source, "spawn", lane, origin, lane == "setup")
	bridge_by_source[key] = endpoint
	return endpoint
end
-- Retirement is a bounded transport operation, never proof that managed work stopped.
-- Only the host's positive peer receipt permits dropping a cached logical endpoint.
local function relay_maintenance(cx: WindowCx)
	table.clear(relay_busy)
	for _, driver in drivers do
		if driver.bridge then relay_busy[driver.bridge] = true end
		local endpoint = bridge_by_source[tostring(driver.source) .. ":" .. tostring(driver.worker_id or "catalog")]
		if endpoint then relay_busy[endpoint] = true end
	end
	for _, pending in controls do if pending.bridge then relay_busy[pending.bridge] = true end end
	for _, pending in guides do if pending.bridge then relay_busy[pending.bridge] = true end end
	for _, pending in withdrawals do if pending.bridge then relay_busy[pending.bridge] = true end end
	for _, pending in pairings do if pending.bridge then relay_busy[pending.bridge] = true end end
	local function maintain(cache: any)
		for key, endpoint in cache do
			local value = relay_index(cx, endpoint.source, "spawn")
			if not value or value.relay_endpoint ~= endpoint.relay_endpoint or value.relay_boot ~= endpoint.relay_boot
				or value.source_nonce ~= endpoint.source_nonce or not scoped_pane(cx, endpoint.source, endpoint.origin) then continue end
			local released = false
			for _, receipt in value.releases or {} do
				if receipt.lane_id == endpoint.lane_id and receipt.peer_boot == endpoint.peer_boot then
					released = true; endpoint.retired = true
					if awake_now() >= (endpoint.release_ack_at or 0) then
						endpoint.release_ack_at = awake_now() + 1000
						cx.session:event(endpoint.source, { ev = "action", id = "main", act = "spawn_relay", value = tern.json.encode({
							schema = 1, source_nonce = endpoint.source_nonce, relay_endpoint = endpoint.relay_endpoint, relay_boot = endpoint.relay_boot,
							lane_id = endpoint.lane_id, peer_boot = endpoint.peer_boot, act = "release_ack", bytes = "{}",
						}) })
					end
					break
				end
			end
			if released then continue end
			if endpoint.retired then cache[key] = nil; continue end -- Exact release receipt was already observed; host consumed its ACK.
			local _, _, lane = relay_live(cx, endpoint)
			if not lane then continue end
			if endpoint.retiring and lane.release_held then endpoint.retiring = nil end
			if endpoint.retiring or endpoint.rebinding or relay_busy[endpoint]
				or (endpoint.setup and (setup_ui.active(endpoint.source) or (picker_ui and picker_ui.active(endpoint.source))))
				or awake_now() - math.max(endpoint.last_used or 0, endpoint.release_at or 0) < 10000 then continue end
			endpoint.release_at = awake_now()
			if relay_event(cx, endpoint, { act = "release", value = "{}" }) then endpoint.retiring = true end
		end
	end
	maintain(bridge_by_source); maintain(retained_relays)
end
local function reconnect_relays(cx: WindowCx, source: number, origin: any)
	local value = relay_index(cx, source, "spawn")
	if not value then return end
	for _, driver in drivers do
		if driver.source == source and not driver.delivery then driver.connection_hold = true end
	end
	local function retain_unissued(action_id: string?)
		local scoped = if action_id then snapshot(cx, source, action_id) else snapshot(cx, source)
		local action = if scoped then scoped.action else nil
		if action and not dispatch.READ_ONLY_OPS[action.request.op] and (action.phase == "ready" or action.phase == "backpressure") then
			held_actions[action.action_id] = true; watch_settle(source, action.action_id, nil, action.request, scoped)
		end
	end
	retain_unissued(nil)
	local flow = workflow_node(cx, source, "workflow-index", "orchplus.workflow")
	for _, id in (if flow then flow.worker_ids or {} else {}) do
		local worker = worker_now(cx, source, id)
		if worker and worker.active_action_id then retain_unissued(worker.active_action_id) end
	end
	for key, endpoint in bridge_by_source do
		if endpoint.source ~= source then continue end
		if endpoint.relay_endpoint ~= value.relay_endpoint or endpoint.relay_boot ~= value.relay_boot or not same_origin(endpoint.origin, origin) then
			local count = 0; for _ in retained_relays do count += 1 end
			if count >= 32 then
				notice(cx, source, origin.alias_nonce, "Earlier connections still have retained obligations. Reconcile them before opening another connection.")
				return
			end
			retained_relays[endpoint.relay_boot .. ":" .. endpoint.lane_id] = endpoint
			bridge_by_source[key] = nil -- Preserve the old identity; only subsequent current-origin reads bind a new lane.
			continue
		end
		local lane
		for _, item in value.lanes or {} do if item.lane_id == endpoint.lane_id then lane = item; break end end
		if not lane or endpoint.retiring then continue end
		relay_live(cx, endpoint)
		if endpoint.rebinding and awake_now() - endpoint.rebinding.at < 30000 then continue end
		if value.held or lane.held or endpoint.peer_boot ~= lane.peer_boot or endpoint.rebinding then
			endpoint.rebinding = { bind_id = endpoint.bind_id or lane.bind_id, at = awake_now() }
			cx.session:event(source, { ev = "action", id = "main", act = "spawn_relay", value = tern.json.encode({
				schema = 1, source_nonce = endpoint.source_nonce, relay_endpoint = endpoint.relay_endpoint, relay_boot = endpoint.relay_boot,
				lane_id = endpoint.lane_id, peer_boot = endpoint.peer_boot, act = "rebind", bytes = tern.json.encode(endpoint.origin),
			}) })
			-- Existing deliveries and native grants are untouched. Remaining reads use their original target.
			for _, driver in drivers do
				if driver.bridge == endpoint and driver.scope then driver.require_status = true; driver.reconcile_action_id = driver.scope end
			end
			local control = controls[source]
			if control and control.bridge == endpoint and control.bytes then control.observing = true end
		end
	end
end
local function queue_control(cx: WindowCx, source: number, origin: any, operation: string, compatibility: any, operator: boolean?)
	local sweep_progress = if operation == "reconcile_session" and controls[source] then controls[source].sweep_progress else nil
	local request_id = send_command(cx, source, origin, "bridge_control", { operation = operation, compatibility = compatibility }, operator)
	if request_id then controls[source] = { creating = request_id, origin = origin, sweep_progress = sweep_progress } end
end
local function authority_command(cx: WindowCx, source: number, origin: any, kind: string, fields: any, operator: boolean?)
	local fence = intent_fences[origin]
	if not fence or not (native_scope.authorized_origin(cx, source, origin) or current_context(cx, source, origin)
		or closing_context(cx, source, origin, kind == "confirm_close")) then return end
	local event = { kind = kind, request_id = dispatch_id(), orch_session_id = origin.logical_session_id,
		authority_namespace = fence.authority_namespace, expected_revision = fence.expected_revision }
	for key, value in fields do event[key] = value end
	cx.session:event(source, { ev = "action", id = "main.dispatch-state", act = if operator then "authority-operator-command" else "authority-command",
		value = tern.json.encode({ source_nonce = origin.alias_nonce, origin = origin, event = event }) })
end
local function observe_control(cx: WindowCx, source: number, data: any, origin: any, pending: any)
	local bridge = acquire_bridge(cx, source, origin, "control")
	pending.bridge = bridge
	local node, bytes
	if bridge then node, bytes = peer_surface(cx, bridge, BRIDGE_BLOCK, "spawn.dispatch.response") end
	if not node or not data.session_control or not data.session_control.admission_seq then return end
	if pending.observation_id then
		local receipt = data.control_result
		if not receipt or receipt.request_id ~= pending.observation_id or receipt.command ~= "bridge_observe"
			or receipt.ok ~= false or receipt.code ~= "stale_revision" then return end
		-- The read's settlement was refused, not the original control's effect.
		-- Obtain new peer evidence at the ordinary cadence; never replay either
		-- the mutating control or an old observation under a refreshed fence.
		pending.next_observation_at = pending.next_observation_at or tern.now() + 5000
		if tern.now() < pending.next_observation_at then return end
		pending.query = nil; pending.observation_id = nil; pending.next_observation_at = nil
	end
	if not pending.query then
		pending.query = { schema = 2, origin = "orchplus", op = "owner_status", request_id = dispatch_id(), action_id = dispatch_id(),
			authority_namespace = data.authority_namespace, logical_session_id = origin.logical_session_id, admission_seq = data.session_control.admission_seq,
			origin_binding = origin, controller_pane = tostring(source), controller_generation = origin.owner_generation }
		pending.observer_epoch = incarnation
		relay_event(cx, bridge, { act = "owner_status", value = tern.json.encode(pending.query) })
		return
	end
	local response = if bytes then codec.decode_dispatch_response(bytes, pending.query) else nil
	if response and not pending.observation_id and pending.observer_epoch == incarnation then
		pending.observation_id = send_command(cx, source, intent_origin(pending.origin, data), "bridge_observe",
			{ query_bytes = tern.json.encode(pending.query), response_bytes = bytes }, true)
	end
end
-- One current pacing cursor, not a completed control/request history. A host
-- revision alone is not ACK progress and must not keep invalidating user prompts.
local function control_progress(request: any): any
	local progress = {}
	for _, key in { "authority_namespace", "admission_seq", "generation_floor", "next_request_serial",
		"settled_before", "consumed", "outstanding_cursor", "control_origin" } do
		progress[key] = plain(request[key])
	end
	return progress
end
local function bridge_control_tick(cx: WindowCx, source: number, data: any, origin: any)
	if not (native_scope.authorized_origin(cx, source, origin) or closing_context(cx, source, origin, true)) then return end
	local pairing = pairings[source]
	if pairing then
		if not native_scope.authorized_origin(cx, source, pairing.origin) then pairings[source] = nil; return end
		if data.compatibility and data.phase == "stable" then
			pairings[source] = nil
			queue_control(cx, source, intent_origin(origin, data), pairing.operation, data.compatibility, true)
			return
		end
		local bridge = acquire_bridge(cx, source, origin, "control")
		pairing.bridge = bridge
		local node, bytes
		if bridge then node, bytes = peer_surface(cx, bridge, BRIDGE_BLOCK, "spawn.dispatch.response") end
		if not node then return end
		if not pairing.query then
			local seq = if data.session_control then data.session_control.admission_seq else nil
			seq = seq or data.next_admission_seq
			if not seq then return end
			pairing.query = { schema = 2, origin = "orchplus", op = "owner_status", request_id = dispatch_id(), action_id = dispatch_id(),
				authority_namespace = data.authority_namespace, logical_session_id = origin.logical_session_id, admission_seq = seq,
				origin_binding = origin, controller_pane = tostring(source), controller_generation = origin.owner_generation }
			relay_event(cx, bridge, { act = "owner_status", value = tern.json.encode(pairing.query) })
			return
		end
		if pairing.sent or not bytes or not codec.decode_dispatch_response(bytes, pairing.query) then return end
		local _, proof_bytes = peer_surface(cx, bridge, BRIDGE_BLOCK, "spawn.dispatch.state", "spawn-dispatch-state", codec.LIMITS.logical)
		local peer = if proof_bytes then decoded(proof_bytes, codec.LIMITS.logical) else nil
		if not peer or not peer.qualification or type(peer.qualification.proof) ~= "table"
			or peer.spawn_namespace ~= peer.qualification.proof.candidate_namespace
			or peer.authority_revision ~= peer.qualification.proof.source_revision then
			pairings[source] = nil
			cx:toast("info", "ORCH+ paired admission", "Open SPAWN Config Runtime and explicitly Inspect its existing store first, then read paired evidence in ORCH+ Config. No store was inferred or initialized.")
			return
		end
		pairing.sent = true
		local fence = intent_fences[pairing.origin]
		cx.session:event(source, { ev = "action", id = "main.dispatch-state", act = "qualify-current", value = tern.json.encode({
			source_nonce = origin.alias_nonce, origin = pairing.origin, peer = peer.qualification,
			event = { kind = "qualify_current", request_id = dispatch_id(), authority_namespace = fence.authority_namespace, expected_revision = fence.expected_revision } }) })
		return
	end
	local current, pending = data.control, controls[source]
	if current then
		local request = current.request
		if type(current.request_bytes) ~= "string" or not request or request.authority_namespace ~= data.authority_namespace then return end
		if not pending or pending.bytes ~= current.request_bytes then
			local result = data.control_result
			local created = pending and pending.creating and result and result.request_id == pending.creating and result.ok and result.code == "control_queued"
			pending = { bytes = current.request_bytes, request = request, origin = intent_origin(origin, data), sent = false, observing = not created,
				sweep_progress = if request.outstanding_cursor and pending then pending.sweep_progress else nil }
			controls[source] = pending
		end
		local bridge = acquire_bridge(cx, source, origin, "control")
		if not bridge then return end
		pending.bridge = bridge
		local node, bytes = peer_surface(cx, bridge, BRIDGE_BLOCK, "spawn.dispatch.response")
		if not node then return end
		if pending.observing then observe_control(cx, source, data, origin, pending); return end
		if not pending.sent then
			pending.sent = true
			pending.sent = relay_event(cx, bridge, { act = request.op, value = current.request_bytes })
			return
		end
		local response = if bytes then codec.decode_dispatch_response(bytes, request) else nil
		local receipt = data.control_result
		local refused_delivery = pending.delivered and receipt and receipt.request_id == pending.delivery_id
			and receipt.command == "bridge_result" and receipt.ok == false
			and (receipt.code == "stale_revision" or receipt.code == "stale_binding")
		if data.session_control.admitted and (refused_delivery
			or (not response and not pending.delivered and data.authority_revision > request.authority_revision)) then
			-- A correlated stale delivery (including an expired native control challenge)
			-- permits a fresh read-only observation. Only current same-binding peer proof
			-- can settle the control; silence still requires progress. Never replay it.
			pending.observing = true
			observe_control(cx, source, data, origin, pending)
			return
		end
		if response and not pending.delivered then
			local _, peer_bytes = peer_surface(cx, bridge, BRIDGE_BLOCK, "spawn.dispatch.state", "spawn-dispatch-state", codec.LIMITS.logical)
			local peer = if peer_bytes then decoded(peer_bytes, codec.LIMITS.logical) else nil
			local observed = if peer then peer.control_response else nil
			if type(observed) == "table" and observed.request_id == request.request_id and observed.action_id == request.action_id
				and observed.spawn_namespace == response.spawn_namespace and type(observed.session_progress) == "string" then
				pending.peer_observation = observed
			end
			pending.delivered = true
			pending.response = response
			-- This observation is a new intent. Capture its fence once now, never again
			-- after submission, while retaining the original native tuple and exact bytes.
			pending.delivery_id = send_command(cx, source, intent_origin(pending.origin, data), "bridge_result",
				{ query_bytes = current.request_bytes, response_bytes = bytes })
		end
		return
	end
	if pending and pending.bytes then
		local receipt = data.control_result
		local acknowledged = not pending.observing and pending.response and pending.peer_observation and receipt and receipt.ok
			and receipt.request_id == pending.delivery_id and receipt.code == "control_observed"
		local response = if acknowledged then pending.response else nil
		local page = if response and pending.request.op == "reconcile_session" then response.payload.outstanding else nil
		local progress = if page then control_progress(pending.request) else nil
		local sweep_progress = if page then (if pending.request.outstanding_cursor then pending.sweep_progress else pending.peer_observation.session_progress) else nil
		if page and page.complete then progress.outstanding_cursor = nil end
		-- Keep the FIRST page's peer fingerprint through the finite sweep. A lower arrival
		-- behind its cursor must trigger a fresh sweep, not be absorbed by the final page.
		-- Reload without that ephemeral baseline also requires a fresh complete sweep.
		controls[source] = { next_at = tern.now() + 5000, progress = progress,
			sweep_progress = if page and not page.complete then sweep_progress else nil,
			peer_progress = if page and page.complete then sweep_progress else nil,
			peer_namespace = if acknowledged then pending.peer_observation.spawn_namespace else nil }
		pending = controls[source]
	end
	if pending and pending.creating then
		local receipt = data.control_result
		if not receipt or receipt.request_id ~= pending.creating then return end
		if receipt.ok == false then
			-- This exact command was refused before a control was persisted. Keep the visible refusal,
			-- but not a forever-waiting creation; only an explicit existing control action retries it.
			controls[source] = { refused = true, approved_close_id = pending.approved_close_id }
		elseif receipt.ok and receipt.code == "already_admitted" then
			-- Admission was a current-state no-op, not a pending wire request. Resume normal observation.
			controls[source] = { next_at = tern.now() + 5000 }
		end
		-- A queued receipt without its current immutable control is not proof that nothing happened.
		return
	end
	local control = data.session_control
	if not control then return end
	if pending and pending.refused then
		-- A new explicit Close supersedes an earlier pre-effect refusal only
		-- after that exact close commits. A refused Close cannot rearm anything.
		if not pending.approved_close_id or control.phase ~= "closing" or not control.close
			or control.close.close_id ~= pending.approved_close_id then return end
		controls[source] = nil
		pending = nil
	end
	if control.phase == "closing" then
		local close = control.close
		if not close then return end
		if origin.window_epoch ~= incarnation and not close.peer_closed then
			if not pending or not pending.observing then
				pending = { observing = true, origin = intent_origin(origin, data) }; controls[source] = pending
			end
			observe_control(cx, source, data, origin, pending)
			return
		end
		if pending and pending.closing_stage == (if data.owner_id then "release" elseif close.peer_closed then "confirm" else "peer") then return end
		controls[source] = { closing_stage = if data.owner_id then "release" elseif close.peer_closed then "confirm" else "peer" }
		if data.owner_id then
			authority_command(cx, source, intent_origin(origin, data), "release_controller",
				{ expected_owner_id = data.owner_id, expected_generation = data.owner_generation })
		elseif close.peer_closed then
			authority_command(cx, source, intent_origin(origin, data), "confirm_close", { close_id = close.close_id })
		elseif data.phase == "stable" and data.compatibility then
			queue_control(cx, source, intent_origin(origin, data), "close_session", data.compatibility)
		end
	elseif data.phase == "stable" and data.compatibility and control.admitted and (not pending or tern.now() >= (pending.next_at or 0)) then
		-- Do not invalidate an already captured write preparation with new background work.
		-- Existing controls, effects and timers still settle under their original fences.
		if control_pending(source) then return end
		-- Do not occupy the control lane before its native receiver is available.
		local bridge = acquire_bridge(cx, source, origin, "control")
		if not bridge then return end
		local node, response_bytes = peer_surface(cx, bridge, BRIDGE_BLOCK, "spawn.dispatch.response")
		if not node then return end
		if pending and pending.progress and same_policy(pending.progress, data.reconcile_progress) then
			-- Native surfaces are cached renders. A fresh existing read-only owner_status
			-- query republishes this bridge's current-store projection without an ORCH commit.
			local probe = pending.probe
			local observation = if probe and response_bytes then codec.decode_dispatch_response(response_bytes, probe.query) else nil
			if not probe or (not observation and tern.now() >= probe.next_at) then
				local query = { schema = 2, origin = "orchplus", op = "owner_status", request_id = dispatch_id(), action_id = dispatch_id(),
					authority_namespace = data.authority_namespace, logical_session_id = origin.logical_session_id, admission_seq = control.admission_seq,
					origin_binding = origin, controller_pane = tostring(source), controller_generation = origin.owner_generation }
				pending.probe = { query = query, next_at = tern.now() + 5000 }
				relay_event(cx, bridge, { act = "owner_status", value = tern.json.encode(query) })
				return
			end
			if not observation then return end
			local _, bytes = peer_surface(cx, bridge, BRIDGE_BLOCK, "spawn.dispatch.state", "spawn-dispatch-state", codec.LIMITS.logical)
			local peer = if bytes then decoded(bytes, codec.LIMITS.logical) else nil
			pending.probe = nil; pending.next_at = tern.now() + 5000
			if not peer or type(peer.authority_revision) ~= "number" or type(peer.spawn_namespace) ~= "string" then return end
			if observation.category == "current_admission" and type(peer.session_progress) == "string" and peer.session_progress == pending.peer_progress
				and peer.spawn_namespace == pending.peer_namespace and peer.authority_namespace == data.authority_namespace then return end
		end
		queue_control(cx, source, intent_origin(origin, data), "reconcile_session", data.compatibility)
	end
end
-- A bounded version-1 index node of the controller (views.luau "routing-index", "catalog-index").
local function index_node(cx: WindowCx, source: number, role: string, key: string): any?
	local _, bytes = surface_node(cx, source, BLOCK, role, key, 65536)
	local value = if bytes then decoded(bytes, 65536) else nil
	return if type(value) == "table" and value.version == 1 and type(value.records) == "table" then value else nil
end
local function routing_index(cx: WindowCx, source: number): any?
	local value = index_node(cx, source, "orchplus.routing", "routing-index")
	return if value and type(value.workers) == "table" then value else nil
end
local function trimmed(value: string): string return value:match("^%s*(.-)%s*$") or "" end
local STALE_CONFIG = "Settings changed while the editor was open. Your draft is retained; newer settings were not overwritten."
-- Policy saves retain the saved-policy digest and send the edited object through the existing
-- bounded native setup envelope, not SPAWN's smaller provider-effect bridge.
local function save_policy(cx: WindowCx, source: number, origin: any, previous: any, fields: any)
	if not current_origin(cx, source, origin) then return nil, { ok = false, code = "context_changed", message = "The orchestration connection changed. Your draft is retained; nothing was sent." } end
	local current = workflow_node(cx, source, "workflow-index", "orchplus.workflow")
	if not current or type(current.policy_sha256) ~= "string" or not same_policy(current.policy, previous) then
		notice(cx, source, origin.alias_nonce, STALE_CONFIG)
		return nil, { ok = false, code = "stale_policy", message = STALE_CONFIG }
	end
	local candidate = table.clone(previous)
	for key, value in fields.policy do candidate[key] = value end
	if #quota.canonical(candidate) > dispatch.POLICY_BYTES then
		local message = "These settings exceed the supported 48 KiB policy limit. Shorten templates, custom fields, guidance or allowlists; your draft is retained."
		notice(cx, source, origin.alias_nonce, message)
		return nil, { ok = false, code = "policy_too_large", message = message }
	end
	fields.expected_policy_sha256 = current.policy_sha256
	local id = send_command(cx, source, fresh_intent(cx, source, origin), "policy", fields, true)
	if not id then return nil, { ok = false, code = "save_not_sent", message = "Settings could not be sent. Check the current connection or shorten large templates and guidance. Your draft is retained." } end
	return id
end
local function ask_text(cx: WindowCx, source: number, origin: any, value: string?, placeholder: string, action: string, done: (WindowCx, string) -> ())
	capture_input(source, origin, cx:prompt({ value = value, placeholder = placeholder, action = action }), function(text: string?, err: string?, fresh: WindowCx?)
		if not fresh or text == nil or err or not current_origin(fresh, source, origin) then return end
		done(fresh, text)
	end)
end
local function public_frame(body: any): string?
	return codec.encode_dispatch_response(body)
end
local function drop(driver: any) drivers[driver.key or driver.source] = nil end
-- Stop driving a retained claim: an executing driver marks it lost (uncertain) and tells the owner;
-- an automatic read of an already uncertain action only ends, leaving its owner control unchanged.
local function abandon(cx: WindowCx, driver: any, uncertain: boolean, action_id: string, executor: string, grant_id: string, message: string)
	if not (driver.auto and uncertain) then
		send_command(cx, driver.source, driver.origin, "lost", { action_id = action_id, executor = executor, grant_id = grant_id })
		if driver.catalog then
			notice(cx, driver.source, driver.origin.alias_nonce, "Couldn’t load your agents. No agent was started.", "error", "ORCH+",
				{ context = "catalog", code = "catalog_unconfirmed", detail = message })
		else notice(cx, driver.source, driver.origin.alias_nonce, message) end
	end
	drop(driver)
end
-- A read-only SPAWN query on the controller's behalf, sent on its bridge's response node.
local function send_query(cx: WindowCx, bridge: any, node: any, source: number, op: string, binding: any, generation: any, target: string?, target_serial: number?, allocation: any?): (any?, string?)
	local data = snapshot(cx, source)
	local control = if data then data.session_control else nil
	if not control then return nil, nil end
	-- Before first admission, inspect the next candidate sequence just as pairing does.
	-- This read neither reserves that sequence nor admits the controller.
	local seq = control.admission_seq
	if op == "owner_status" then seq = seq or data.next_admission_seq end
	local query = { schema = 2, origin = "orchplus", op = op, request_id = dispatch_id(), action_id = dispatch_id(),
		authority_namespace = data.authority_namespace, logical_session_id = binding.logical_session_id, admission_seq = seq,
		origin_binding = binding, controller_pane = tostring(source), controller_generation = generation, target_request_id = target }
	if target then
		if not target_serial then return nil, nil end
		query.target_request_serial = target_serial
	end
	if op == "mailbox_allocation" then query.target = allocation end
	local bytes = tern.json.encode(query)
	if not relay_event(cx, bridge, { act = op, value = bytes }) then return nil, nil end
	return query, bytes
end
local function stale_witness(a: any, outcome: any): boolean
	return a ~= nil and a.phase == "claimed" and a.claim ~= nil and a.claim.executor == incarnation
		and outcome ~= nil and outcome.ok == false and outcome.command == "spawn_claimed" and outcome.code == "stale_revision"
		and outcome.action_id == a.action_id and outcome.grant_id == a.claim.grant_id
end
local SETTLING = { "resolved", "claimed", "launching", "pending" }
function native_scope.launch_needs_foreground(cx: WindowCx, source: number, origin: any, request: any, worker_id: string?): boolean
	if request.op ~= "launch" or native_scope.input_context(cx, source, origin) then return false end
	local worker = if worker_id then worker_now(cx, source, worker_id) else nil
	-- SDK split(target, ..., {focus=false}) can address an existing source for terminal
	-- backends. Native-agent start and new_tab have no target-session parameter.
	return request.presentation == "user_new_tab" or request.placement ~= "split" or worker == nil
		or (worker.backend ~= "local-terminal" and worker.backend ~= "ssh-command")
end
local function advance(cx: WindowCx, driver: any)
	-- Never switch sessions/focus to finish background work. A persisted claim stays held.
	if not native_scope.authorized_origin(cx, driver.source, driver.origin) then drop(driver); return end
	local data, node = snapshot(cx, driver.source, driver.scope)
	if not data and driver.delivery then
		data, node = snapshot(cx, driver.source)
		if data then
			data.action = nil
			if data.result and data.result.action_id ~= driver.delivery.action_id then data.result = nil end
		end
	end
	-- New driver transitions capture here. Delivery retries keep their original envelope.
	if data then driver.origin = intent_origin(driver.origin, data) end
	if driver.command_request_id then
		local current = snapshot(cx, driver.source)
		local receipt = if current and current.driver_result and current.driver_result.request_id == driver.command_request_id then current.driver_result
			elseif current and current.command_result and current.command_result.request_id == driver.command_request_id then current.command_result
			elseif current and current.result and current.result.request_id == driver.command_request_id then current.result else nil
		if not receipt and current and current.poll_result and current.poll_result.command == "poll"
			and current.poll_result.request_id == driver.command_request_id and current.poll_result.worker_id == driver.worker_id then
			-- Automatic polls have one independent current receipt, including refusals and no-ops.
			-- Another worker's effect delivery or an owner command cannot replace it.
			receipt = current.poll_result
		end
		if receipt then
			if not driver.scope and receipt.action_id then
				driver.scope = receipt.action_id
				data, node = snapshot(cx, driver.source, driver.scope)
			elseif receipt.ok and receipt.action_id and receipt.action_id ~= driver.scope then
				-- An owner retry can replace the action before its old delivery receipt is observed.
				-- Keep that delivery immutable; follow the new action only after it settles.
				driver.next_scope = receipt.action_id
			end
			if data then data.driver_result = receipt end
		end
	end
	if not data then
		-- The host may remove a deferred, never-captured wake: drop only that inert driver. Missing
		-- surfaces never redirect execution or change durable claim state.
		if driver.scope and not driver.action_id and not driver.delivery then drop(driver) end
		return
	end
	local a = data.action
	local outcome = data.result
	-- An automatic attempt starts from the action's existing uncertain result; only a result
	-- committed during this read-only attempt can end it.
	if driver.stale_result ~= nil and outcome and outcome.request_id == driver.stale_result then outcome = nil end
	if driver.command_request_id then
		local command_result = if data.driver_result and data.driver_result.request_id == driver.command_request_id then data.driver_result else data.result
		local matched = command_result and command_result.request_id == driver.command_request_id
		if not matched and not driver.delivery and not driver.scope then return end
		-- An owner command the host refused is always noticed with its reason, whichever branch
		-- below ends or continues this driver (the refusal row alone is replaced by later commands).
		if matched and command_result.ok == false and driver.owner_command then
			notice(cx, driver.source, driver.origin.alias_nonce, "Refused " .. tostring(command_result.command or "command") .. ": "
				.. tostring(command_result.message or command_result.code) .. " Nothing changed.")
		end
		driver.owner_command = nil
		if matched and not command_result.action_id and not driver.scope and not driver.delivery then
			local scan = if driver.continuation then scans[driver.source] else nil
			if scan and scan.paced then scan.paced[driver.worker_id] = tern.now() + (driver.pace_ms or dispatch.COORDINATOR_POLL_MS) end
			drop(driver); return
		end
		driver.command_request_id = nil
		-- Unrelated workflow controls cannot strand an already captured grant/delivery.
		if matched and command_result.ok == false and not a and not driver.delivery then drop(driver); return end
	end
	if a then driver.scope = a.action_id end
	local delivery = driver.delivery
	if delivery then
		local receipt = data.receipt
		local current = snapshot(cx, driver.source)
		local session = if current then current.session_control else nil
		local consumed = false
		if current and session and current.authority_namespace == delivery.authority_namespace
			and current.orch_session_id == delivery.logical_session_id and session.admission_seq == delivery.admission_seq then
			consumed = type(session.request_floor) == "number" and session.request_floor > delivery.request_serial
			local control = current.control
			local request = if control and type(control.request_bytes) == "string" then codec.decode_dispatch_request(control.request_bytes) else nil
			if request and table.find({ "admit_session", "reconcile_session", "close_session" }, request.op)
				and request.authority_namespace == delivery.authority_namespace and request.logical_session_id == delivery.logical_session_id
				and request.admission_seq == delivery.admission_seq then
				consumed = consumed or request.settled_before > delivery.request_serial or table.find(request.consumed, delivery.request_serial) ~= nil
			end
		end
		if consumed or (type(receipt) == "table" and receipt.action_id == delivery.action_id and receipt.grant_id == delivery.grant_id
			and receipt.response_sha256 == delivery.response_sha256) then
			-- Transport completion follows this exact durable observation, not the
			-- currently rendered response (which may already belong to another read).
			if delivery.response_receipt and driver.bridge then relay_ack(cx, driver.bridge, "response", delivery.response_receipt) end
			driver.last_response = delivery.bytes; driver.delivery = nil
			cx.session:event(driver.source, { ev = "action", id = node.id, act = "dispatch-release-scope", value = tern.json.encode({
				source_nonce = driver.origin.alias_nonce, action_id = delivery.action_id, grant_id = delivery.grant_id, response_sha256 = delivery.response_sha256,
			}) })
			-- A committed retained outcome that leaves the effect uncertain ends this automatic read.
			if driver.auto and a and a.action_id == delivery.action_id and a.phase == "uncertain" then drop(driver); return end
		elseif not delivery.refused and outcome and outcome.command == "result" and outcome.request_id == delivery.request_id
			and outcome.action_id == delivery.action_id and outcome.grant_id == delivery.grant_id
			and outcome.ok == false and outcome.code == "stale_revision" and data.authority_namespace == delivery.authority_namespace
			and data.authority_revision > delivery.expected_revision then
			-- Positive refusal of THIS immutable observation only. Keep its envelope until a fresh
			-- read proves the same effect; a lost/unrelated reply cannot enter this transition.
			delivery.refused = true
			driver.require_status = true; driver.query = nil; driver.query_bytes = nil; driver.next_status = nil
			driver.reconcile_action_id = delivery.action_id
		elseif not delivery.refused then
			local now = awake_now()
			local progress = host_progress(data)
			if progress ~= delivery.progress then delivery.progress = progress; delivery.progress_at = now end
			local waited = now - delivery.started
			if waited > DELIVERY_MAX_MS or (waited > DELIVERY_IDLE_MS and now - delivery.progress_at > DELIVERY_IDLE_MS) then
				abandon(cx, driver, a ~= nil and a.phase == "uncertain", delivery.action_id, delivery.executor, delivery.grant_id,
					"SPAWN outcome was observed but its host commit receipt is unconfirmed. Inspect the exact retained action; no native effect was repeated.")
				return
			end
			if now < delivery.next_replay then return end
			delivery.replays += 1
			delivery.next_replay = now + retry_delay(REPLAY_RETRY_MS, delivery.replays + 1)
			-- Replay only the captured host observation, never the SPAWN request or its effect.
			cx.session:event(driver.source, { ev = "action", id = node.id, act = "dispatch-result/" .. delivery.grant_id .. "/" .. driver.origin.window_epoch, value = delivery.envelope })
			if not native_scope.authorized_origin(cx, driver.source, driver.origin) then drop(driver) end
			return
		end
		if driver.delivery and delivery.refused then
			local now = awake_now()
			if now - delivery.started > DELIVERY_MAX_MS or now - delivery.progress_at > DELIVERY_IDLE_MS then
				abandon(cx, driver, a ~= nil and a.phase == "uncertain", delivery.action_id, delivery.executor, delivery.grant_id,
					"The refused host observation has no confirmed current retained outcome. Its original envelope and native claim were not reissued.")
				return
			end
			-- Neither replacement grants nor changed request/route identities can inherit this read.
			if not a or not a.claim or a.action_id ~= delivery.action_id or a.claim.grant_id ~= delivery.grant_id
				or a.claim.executor ~= delivery.executor or a.claim.epoch ~= delivery.claim_epoch
				or a.request_bytes ~= delivery.request_bytes or not same_origin(a.execution_origin or a.request.origin_binding, driver.origin)
				or data.authority_namespace ~= delivery.authority_namespace then return end
			outcome = nil
		end
	end
	if driver.next_scope and not driver.delivery and not a then
		driver.scope = driver.next_scope; driver.next_scope = nil
		data, node = snapshot(cx, driver.source, driver.scope)
		if not data then drop(driver); return end
		a = data.action; outcome = data.result
		driver.origin = intent_origin(driver.origin, data)
	end
	local relevant_result = outcome and not stale_witness(a, outcome) and ((a and outcome.action_id == a.request.action_id
		and (outcome.grant_id == nil or (a.claim and outcome.grant_id == a.claim.grant_id)))
		or (outcome.action_id == nil and a == nil))
	-- A grantless refusal is this driver's evidence only if this window sent that request. A refused
	-- duplicate claim whose sibling claim by this window already won is superseded: the driver continues.
	local claim_pending = if a then claims_in_flight[a.action_id] else nil
	local rejected = driver.rejected_claim
	if rejected and (not a or not outcome or outcome.request_id ~= rejected.request_id
		or outcome.action_id ~= rejected.action_id or outcome.command ~= "claim"
		or outcome.ok ~= false or outcome.code ~= "stale_revision" or outcome.grant_id ~= nil) then
		driver.rejected_claim = nil; rejected = nil
	end
	if relevant_result and a and a.phase == "ready" and a.claim == nil and outcome.ok == false
		and outcome.command == "claim" and outcome.code == "stale_revision" and outcome.grant_id == nil
		and claim_pending and claim_pending.request_id == outcome.request_id
		and claim_pending.authority_namespace == data.authority_namespace
		and data.authority_revision > claim_pending.revision then
		-- This exact claim definitely wrote nothing. Decide anew from the current ready
		-- action; a missing reply never takes this path or upgrades its captured fence.
		rejected = { request_id = outcome.request_id, action_id = a.action_id }
		driver.rejected_claim = rejected
		claims_in_flight[a.action_id] = nil; claim_pending = nil
	end
	if rejected then relevant_result = false end
	local current_claim = a and a.phase ~= "ready" and a.claim and a.claim.executor == incarnation
	local superseded = driver.superseded_claim
	if superseded and (not current_claim or not outcome or outcome.code ~= "stale_revision"
		or outcome.request_id ~= superseded.request_id or a.action_id ~= superseded.action_id
		or a.claim.grant_id ~= superseded.grant_id) then
		driver.superseded_claim = nil; superseded = nil
	end
	if relevant_result and outcome.ok == false and outcome.grant_id == nil and outcome.code == "stale_revision"
		and current_claim and claim_pending and claim_pending.request_id == outcome.request_id and not superseded then
		-- The in-flight marker clears once the grant is observed. Retain this exact correlation
		-- on its live driver so the same delayed refusal cannot strand the grant on the next tick.
		superseded = { request_id = outcome.request_id, action_id = a.action_id, grant_id = a.claim.grant_id }
		driver.superseded_claim = superseded
	end
	local granted_claim_refusal = current_claim and outcome
		and (outcome.code == "effect_already_claimed" or (outcome.code == "stale_revision" and superseded ~= nil))
	if relevant_result and outcome.ok == false and outcome.grant_id == nil
		and (not issued.values[outcome.request_id] or granted_claim_refusal) then relevant_result = false end
	if relevant_result and ((outcome.ok == false and outcome.code ~= "pending") or outcome.code == "bridge_rejected" or outcome.code == "effect_uncertain" or outcome.code == "backpressure") then
		if a and claim_pending and claim_pending.request_id == outcome.request_id and outcome.command == "claim" then
			claims_in_flight[a.action_id] = nil -- Positive receipt; a withdrawn ready action owes no unanswered claim.
		end
		if a and a.phase == "ready" and outcome.ok == false and outcome.code == "full" then
			capacity_hold(driver.source, a.action_id, outcome.request_id, data) -- Pre-effect capacity refusal: resume when slots free.
		elseif a and a.phase == "backpressure" and outcome.code == "backpressure" then
			recheck_hold(driver.source, a.action_id, a.retry_count) -- Definitive pre-effect refusal: bounded automatic recheck.
		elseif a then held_actions[a.action_id] = true; watch_settle(driver.source, a.action_id, nil, a.request, data) end
		drop(driver); return
	end
	if relevant_result and outcome.code == "coordinator_retired" then drop(driver); return end
	if a and a.worker_id then driver.worker_id = a.worker_id end
	if driver.action_id and (not a or a.request.action_id ~= driver.action_id) then
		driver.query = nil; driver.query_bytes = nil; driver.query_replays = nil; driver.query_next_replay = nil
		driver.sent = nil; driver.action_id = nil; driver.grant_id = nil; driver.started = nil; driver.last_response = nil; driver.require_status = nil; driver.next_status = nil
	end
	if a and a.phase ~= "ready" then claims_in_flight[a.action_id] = nil end -- Its claim was answered.
	if a == nil then drop(driver); return end
	local request = a.request
	driver.catalog = request.op == "catalog"
	local execution_origin = a.execution_origin or request.origin_binding
	-- An automatic attempt follows only the owner control's exact route for its retained claim;
	-- a changed route or phase ends the attempt instead of idling a driver.
	if driver.auto and not (a.claim and (a.phase == "uncertain" or a.phase == "claimed")
		and (a.reconciliation_only or (a.claim.executor == incarnation and request.controller_pane == tostring(driver.source)))
		and same_origin(execution_origin, driver.origin) and native_scope.authorized_origin(cx, driver.source, execution_origin)) then
		drop(driver); return
	end
	local transport = bridge_by_source[tostring(driver.source) .. ":" .. tostring(a.worker_id or "catalog")]
	if driver.connection_hold then
		driver.connection_hold = nil
		if not dispatch.READ_ONLY_OPS[request.op] then
			if a.phase == "ready" or a.phase == "backpressure" then
				held_actions[a.action_id] = true; watch_settle(driver.source, a.action_id, nil, request, data); drop(driver); return
			elseif a.claim then driver.require_status = true; driver.reconcile_action_id = a.action_id end
		end
	end
	if transport and (transport.retiring or transport.retired) then return end
	if not same_origin(execution_origin, driver.origin) or not native_scope.authorized_origin(cx, driver.source, execution_origin) then return end
	if a.reconciliation_only then
		driver.reconcile_action_id = request.action_id
		driver.require_status = true
	elseif request.controller_pane ~= tostring(driver.source) then return end
	local launch_wait = native_scope.launch_needs_foreground(cx, driver.source, driver.origin, request, a.worker_id)
	if launch_wait and (a.phase == "ready" or (a.phase == "claimed" and a.claim and a.claim.spawn_claim == nil
		and not executed[a.claim.grant_id] and driver.reconcile_action_id ~= request.action_id and not driver.delivery)) then
		if not driver.targeted_launch_hold then
			driver.targeted_launch_hold = true
			cx.session:event(driver.source, { ev = "action", id = node.id, act = "dispatch-notice", value = tern.json.encode({
				source_nonce = driver.origin.alias_nonce, level = "error", code = "targeted_native_launch_unavailable",
				message = "Launch needs a targeted native agent API. This SDK cannot create this conversation in a nonselected session without changing focus. No new launch was issued; the original authorization remains held.",
			}) })
		end
		driver.started = nil
		return
	end
	if not launch_wait then driver.targeted_launch_hold = nil end
	if a.phase == "ready" then
		if a.reconciliation_only or a.start_blocked then return end
		-- A loading selector or ordinary form must not strand its read-only catalog
		-- or an already-authorized exact route attachment. Other controls stay fenced.
		local form_independent = request.op == "catalog" or (request.op == "attach_worker" and driver.attachment_action_id == request.action_id)
		if not claims_in_flight[request.action_id] and control_pending(driver.source, form_independent) then
			-- Only an open form or menu is silent to the owner; say so once, until the launch issues.
			if not form_independent and not driver.form_hold_notice and forms_ui.active(driver.source) then
				driver.form_hold_notice = true
				local name = forms_ui.title and forms_ui.title(driver.source) or "the open menu or form"
				notice(cx, driver.source, driver.origin.alias_nonce, "Launch waits until you close " .. name, "info")
			end
			return
		end
		driver.form_hold_notice = nil
		if a.retry_after_serial then
			if not driver.retry_notice then
				driver.retry_notice = true
				notice(cx, driver.source, driver.origin.alias_nonce, "Retry waits for explicit/current SPAWN reconciliation to acknowledge the preceding result. No changed request bytes were issued under the old live key.", "info")
			end
			return
		end
		if request.op == "native_wake" then
			local worker = if a.worker_id then worker_now(cx, driver.source, a.worker_id) else nil
			if not worker then return end
			local native, _reason, _pane, problem = native_observation(cx, driver.source, worker)
			if native ~= "idle" or problem then
				send_command(cx, driver.source, driver.origin, "observe", { worker_id = worker.worker_id,
					pane_binding = worker.pane_binding, native_state = native, delivery_error = problem })
				local deferred = snapshot(cx, driver.source, request.action_id)
				if (not deferred or not deferred.action) and not driver.action_id and not driver.delivery then drop(driver) end
				return
			end
		end
		-- A lost claim response is observation/recovery work, not permission to upgrade its fence.
		local in_flight = claims_in_flight[request.action_id]
		if in_flight then
			if awake_now() >= in_flight.next_at and not in_flight.noticed then
				in_flight.noticed = true
				notice(cx, driver.source, driver.origin.alias_nonce, "Claim response is unconfirmed. Inspect current state; the original intent was not resent with a newer revision.")
			end
			return
		end
		local claim_fields: any = { action_id = request.action_id, executor = incarnation }
		if request.op == "launch" or request.op == "adopt" or request.op == "enrol" or request.op == "mailbox_provision" then
			local flow = workflow_node(cx, driver.source, "workflow-index", "orchplus.workflow")
			if not flow or not flow.policy or flow.policy.paused then return end
			-- Quota-routed work never claims while held/gated; a routed launch first has USAGE confirm the
			-- exact decision revision is still current. Unrouted work has no `routing` and claims as is.
			local worker = if a.worker_id then worker_now(cx, driver.source, a.worker_id) else nil
			local routed = if worker then worker.routing else nil
			if worker and worker.orch_project_id and not worker.open_conversation and not worker.coordinator_owner_id then
				local projects = workflow_node(cx, driver.source, "project-index", "orchplus.projects")
				local project = if projects then projects.projects[worker.orch_project_id] else nil
				if not project or project.started ~= true or project.finished then return end
			end
			if type(routed) == "table" then
				if routed.phase ~= "selected" then return end
				if request.op == "launch" and routed.mode == "quota" then
					local v = validations[driver.source]
					if not v or v.revision ~= routed.evidence_revision or tern.now() - v.at > 5000 then
						if type(routed.evidence_revision) == "string" then start_reader(driver.source, driver.origin, "validate", routed.evidence_revision) end
						return
					end
					validations[driver.source] = nil -- One validation authorizes at most one claim attempt.
					claim_fields.capacity_validation = v.value
				end
			end
		end
		local fence = intent_fences[driver.origin]
		local claim_id = send_command(cx, driver.source, driver.origin, "claim", claim_fields)
		if claim_id then
			claims_in_flight[request.action_id] = { request_id = claim_id, next_at = awake_now() + CLAIM_NOTICE_MS,
				authority_namespace = fence.authority_namespace, revision = fence.expected_revision }
		end
		return
	end
	if not a.claim or (not a.reconciliation_only and a.claim.executor ~= incarnation) or (a.phase ~= "claimed" and a.phase ~= "uncertain") then return end
	if driver.grant_id and driver.grant_id ~= a.claim.grant_id then drop(driver); return end
	local function give_up(uncertain: boolean, message: string)
		abandon(cx, driver, uncertain, request.action_id, a.claim.executor, a.claim.grant_id, message)
	end
	driver.claim_executor = a.claim.executor
	capacity_waits[request.action_id] = nil
	driver.action_id = request.action_id
	driver.grant_id = a.claim.grant_id
	driver.started = driver.started or awake_now()
	local unclaimed_launch_wait = launch_wait and a.claim.spawn_claim == nil
	if a.wake_status == "awaiting_window" or unclaimed_launch_wait or driver.launch_clock_paused then driver.started = awake_now() end
	driver.launch_clock_paused = unclaimed_launch_wait
	-- A relay sent before selection changed can wait for its native receiver without
	-- becoming "lost" only while there is no committed SPAWN claim witness. Once a
	-- witness exists, normal uncertain-effect deadlines and no-replay rules apply.
	local expired = driver.delivery == nil and awake_now() - driver.started > EFFECT_DEADLINE_MS
	if expired and not executed[a.claim.grant_id] and a.phase == "claimed" and driver.reconcile_action_id ~= request.action_id then
		return give_up(false, "The effect deadline elapsed before native submission. Its exact claim remains retained; no late native effect was started.")
	end
	if driver.bridge == nil then
		driver.bridge = acquire_bridge(cx, driver.source, driver.origin, tostring(driver.worker_id or "catalog"))
		if driver.bridge == nil then
			return give_up(a.phase == "uncertain", "Missing SPAWN dispatch bridge on this host. Install/enable the compatible SPAWN package; no raw-command fallback is available.")
		end
		if not native_scope.authorized_origin(cx, driver.source, driver.origin) then drop(driver); return end
	end
	if not relay_live(cx, driver.bridge) then
		return give_up(a.phase == "uncertain", "The exact agent connection changed or became unavailable; retained work was not redirected or repeated.")
	end
	local bridge_node, bytes = peer_surface(cx, driver.bridge, "spawn.dispatch", "spawn.dispatch.response")
	if not bridge_node then
		driver.absent_since = driver.absent_since or awake_now()
		if awake_now() - driver.absent_since >= 30000 then
			give_up(a.phase == "uncertain", "The internal SPAWN connection did not become readable. The retained claim remains held; no second producer or visible fallback was created.")
		end
		return
	end
	driver.absent_since = nil
	if not executed[a.claim.grant_id] and a.phase == "claimed" and driver.reconcile_action_id ~= request.action_id then
		executed[a.claim.grant_id] = true -- Set BEFORE the native event, including exceptions/lost callbacks.
		watch_settle(driver.source, request.action_id, a.claim.grant_id, request)
		driver.sent = true; driver.require_status = a.retry_count ~= nil; driver.last_response = nil
		if not relay_event(cx, driver.bridge, { act = request.op, value = a.request_bytes }) then return give_up(true, "The current agent connection could not accept this action. No replacement request was sent.") end
		if not native_scope.authorized_origin(cx, driver.source, driver.origin) then drop(driver) end
		return
	end
	local body = if driver.require_status and driver.query == nil then nil else dispatch.decode_response(bytes, driver.query or request)
	if body == nil and driver.query ~= nil and not driver.require_status then
		body = dispatch.decode_response(bytes, request)
		if body ~= nil then driver.query = nil end
	end
	local response_receipt = if body and table.find({ "catalog", "owner_status", "status", "mailbox_inventory", "mailbox_allocation" }, body.op)
		then driver.bridge.reads.response else nil
	if body and driver.query then
		if body.status == "found" and type(body.payload) == "table" and type(body.payload.outcome) == "table" then
			body = body.payload.outcome
			bytes = public_frame(body)
			body = dispatch.decode_response(bytes, request)
			if body then driver.require_status = nil end
		elseif body.status == "rejected" and body.error and body.error.code == "oversize" then
			-- An automatic attempt never takes the exact-request replay path below.
			if a.reconciliation_only or driver.auto or driver.delivery ~= nil then
				if not driver.auto then
					notice(cx, driver.source, driver.origin.alias_nonce, "Retained outcome is too large for status inspection. The old effect is not resubmitted; reconcile its exact executor explicitly.")
				end
				drop(driver); return
			end
			-- Exact retained request replay is a registry read, not a new launch permission; the direct
			-- retained outcome is read on the next turn before another status event.
			if not relay_event(cx, driver.bridge, { act = request.op, value = a.request_bytes }) then return give_up(true, "The connection changed during reconciliation. The retained operation remains held.") end
			driver.query = nil
			driver.require_status = nil
			return
		elseif body.status == "missing" and a.phase == "uncertain" and dispatch.READ_ONLY_OPS[request.op] then
			-- SPAWN never recorded this retained read: the host checks this exact status evidence and
			-- resolves it without effect. Mutating effects never take this path (`missing` stays uncertain).
			send_command(cx, driver.source, driver.origin, "read_missing", { action_id = request.action_id, executor = a.claim.executor,
				grant_id = a.claim.grant_id, query_bytes = driver.query_bytes, response_bytes = bytes })
			drop(driver); return
		else body = nil end
		driver.query = nil
		-- One SPAWN registry answer per automatic attempt: pending or unknown stays uncertain.
		if driver.auto and a.phase == "uncertain" and (body == nil or table.find(SETTLING, body.status)) then drop(driver); return end
	end
	if body and bytes == driver.last_response then body = nil end
	if driver.delivery and driver.delivery.refused and body then
		-- A correlated status response must reproduce the captured native outcome exactly.
		if codec.sha256(bytes) ~= driver.delivery.response_sha256 then body = nil; driver.require_status = true end
	end
	if body and not table.find(SETTLING, body.status) then
		if request.op == "launch" and request.presentation == "coordinator_adjacent"
			and body.payload and body.payload.pane_binding then
			local binding = body.payload.pane_binding
			local target = tonumber(binding.pane_id)
			local native = if target then scoped_pane(cx, target, driver.origin) else nil
			local controller = cx.session:pane(driver.source)
			if not native or not controller or binding.window_key ~= driver.origin.window_key
				or binding.window_epoch ~= driver.origin.window_epoch or binding.native_session_id ~= driver.origin.native_session_id
				or binding.window_host_id ~= driver.origin.window_host_id or native.block ~= nil then
				return give_up(true, "The created orchestrator's native binding could not be verified. It remains a real retained launch; nothing was launched again.")
			end
			if native.tab ~= controller.tab then
				if not cx.layout:move(target :: number, driver.source, "left", { focus = native_scope.input_context(cx, driver.source, driver.origin) }) then
					return give_up(true, "The orchestrator was created but could not be composed beside its panel. Its existing launch remains held for reconciliation.")
				end
				cx.layout:resize(driver.source, "left", -20)
			end
			local composed = scoped_pane(cx, target, driver.origin)
			if not composed or composed.tab ~= cx.session:pane(driver.source).tab then
				return give_up(true, "The composed orchestrator could not be observed. Its launch is retained; activation remains held.")
			end
		end
		if #bytes <= 8192 and native_scope.authorized_origin(cx, driver.source, driver.origin) then
			local now = awake_now()
			local previous = driver.delivery
			local envelope = { authority_namespace = data.authority_namespace, expected_revision = data.authority_revision, response_bytes = bytes }
			driver.delivery = { action_id = request.action_id, grant_id = a.claim.grant_id, executor = a.claim.executor, bytes = bytes,
				authority_namespace = request.authority_namespace, logical_session_id = request.logical_session_id,
				admission_seq = request.admission_seq, request_serial = request.request_serial,
				request_bytes = a.request_bytes, claim_epoch = a.claim.epoch, expected_revision = data.authority_revision,
				response_receipt = response_receipt,
				request_id = dispatch.result_request_id(a.claim.grant_id, driver.origin.window_epoch, envelope),
				response_sha256 = codec.sha256(bytes), started = if previous then previous.started else now,
				replays = 0, next_replay = now + retry_delay(REPLAY_RETRY_MS, 1), progress = host_progress(data), progress_at = now }
			driver.delivery.envelope = tern.json.encode(envelope)
			cx.session:event(driver.source, { ev = "action", id = node.id, act = "dispatch-result/" .. a.claim.grant_id .. "/" .. driver.origin.window_epoch, value = driver.delivery.envelope })
		end
		return
	end
	-- A delayed timer first consumes an available correlated outcome: expiry limits waiting and
	-- submission, never conclusive retained evidence.
	if expired then
		return give_up(a.phase == "uncertain", "No conclusive SPAWN outcome is available after the effect deadline. The exact claim remains occupied; read its retained outcome or explicitly recover it.")
	end
	-- Terminal continuation stages only after its asynchronous process proof.
	-- A status read on this same lane would replace that still-unrecorded stage.
	-- Observe the original response until its existing deadline; uncertain
	-- recovery may inspect retained status, but never reissues this attachment.
	if request.op == "attach_worker" and request.attestation == "same_terminal_process_no_pending_effects"
		and a.phase == "claimed" and not driver.require_status then return end
	if driver.query == nil then
		if tern.now() < (driver.next_status or 0) then return end
		driver.next_status = tern.now() + 5000
		driver.query, driver.query_bytes = send_query(cx, driver.bridge, bridge_node, driver.source, "status",
			execution_origin, execution_origin.owner_generation, request.request_id, request.request_serial)
		if driver.query then
			driver.query_replays = 0
			driver.query_next_replay = awake_now() + retry_delay(REPLAY_RETRY_MS, 1)
		end
	elseif awake_now() >= driver.query_next_replay then
		-- The bridge has one response surface. Authorization or another observation may replace a
		-- status reply before this turn; repeat only these captured read-only bytes, never the effect.
		if not same_origin(driver.query.origin_binding, execution_origin)
			or driver.query.target_request_id ~= request.request_id or driver.query.target_request_serial ~= request.request_serial
			or driver.query.authority_namespace ~= request.authority_namespace or driver.query.admission_seq ~= request.admission_seq then
			drop(driver); return
		end
		driver.query_replays += 1
		driver.query_next_replay = awake_now() + retry_delay(REPLAY_RETRY_MS, driver.query_replays + 1)
		relay_event(cx, driver.bridge, { act = "status", value = driver.query_bytes })
	end
end
local pane_pushes: any = {}
local function short_title(title: any): string
	-- Display only: UTF-8-safe truncation; titles are never identity.
	if type(title) ~= "string" or utf8.len(title) == nil then return "" end
	if #title <= 64 then return title end
	local stop = 0
	for position, code in utf8.codes(title) do
		local last = position + #utf8.char(code) - 1
		if last > 61 then break end
		stop = last
	end
	return title:sub(1, stop) .. "…"
end
-- While a block shows Config, push this window's agent panes in its native session and host; a
-- managed worker is named only through its exact current window binding.
local function push_config_panes(cx: WindowCx, source: number, host: any, session: any, membership: any)
	local bridge = alias(cx, source)
	if not bridge then pane_pushes[source] = nil; return end
	local managed = {}
	local flow = workflow_node(cx, source, "workflow-index", "orchplus.workflow")
	for _, worker_id in (if flow and type(flow.worker_ids) == "table" then flow.worker_ids else {}) do
		local worker = worker_now(cx, source, worker_id)
		local binding = if worker then (worker.pane_binding or worker.launch_pane_binding or worker.adopt_pane_binding) else nil
		if binding and binding.window_epoch == incarnation and binding.window_key == cx:window_key()
			and binding.native_session_id == tostring(session.id) and binding.window_host_id == tostring(host.id) then managed[binding.pane_id] = worker_id end
	end
	local rows = {}
	local agents = {}; for _, agent in cx.agents:list() do agents[agent.pane] = agent end
	for _, pane in cx.session:panes() do
		local agent, owner = agents[pane.pane], host_for(cx, pane.pane)
		if pane.pane ~= source and (agent or pane.kind == "terminal") and pane.tab ~= nil
			and membership[pane.tab] == session.id and owner and owner.id == host.id then
			local state = if pane.exited ~= nil then "exited"
				elseif agent and table.find({ "idle", "working", "waiting_input", "exited" }, agent.state) then agent.state else "unknown"
			table.insert(rows, { pane = pane.pane, title = short_title(provider_display.pane_title(pane)), state = state,
				exit_code = pane.exited, worker_id = managed[tostring(pane.pane)] })
		end
	end
	table.sort(rows, function(a, b) return a.pane < b.pane end)
	local more = 0
	while #rows > 64 do table.remove(rows); more += 1 end
	local payload = { version = 1, source_nonce = bridge.alias_nonce, native_session_id = tostring(session.id), window_host_id = tostring(host.id),
		window_epoch = incarnation, panes = rows, more = more }
	local bytes = tern.json.encode(payload)
	while #bytes > 8192 and #rows > 0 do table.remove(rows); payload.more += 1; bytes = tern.json.encode(payload) end
	if pane_pushes[source] == bytes then return end
	pane_pushes[source] = bytes
	cx.session:event(source, { ev = "action", id = "main", act = "config-panes", value = bytes })
end
-- scans is declared beside drivers: the driver drop path paces continuation with it.
-- Start one bounded automatic read-only attempt for an uncertain retained effect once its backoff
-- is due, only on the owner control's exact route; everything else waits for the owner.
local function auto_reconcile_due(cx: WindowCx, source: number, origin: any, scoped: any, key: any, worker_id: string?)
	local a = scoped.action
	if a.phase ~= "uncertain" or not a.claim or not a.request or drivers[key] then return end
	local execution_origin = a.execution_origin or a.request.origin_binding
	if not same_origin(execution_origin, origin) or not (a.reconciliation_only
		or (a.claim.executor == incarnation and a.request.controller_pane == tostring(source))) then return end
	local state = auto_reconcile[a.action_id]
	if state == nil or state.grant_id ~= a.claim.grant_id then
		state = { grant_id = a.claim.grant_id, attempts = 0, next_at = awake_now() + AUTO_RECONCILE_DELAYS[1] }
		auto_reconcile[a.action_id] = state; watch_settle(source, a.action_id, a.claim.grant_id, a.request)
	end
	if state.attempts >= #AUTO_RECONCILE_DELAYS then return end
	if awake_now() < state.next_at then return end
	if not native_scope.project_start_delivery(cx, source, a.action_id)
		and (a.request.op == "mailbox_publish_ack" or a.request.op == "mailbox_publish_reply") and a.wake_status == nil and state.attempts >= 1 and not state.readback
		and awake_now() >= state.next_at and worker_id then
		local identity = worker_id .. ":" .. tostring(a.request.ack_sha256 or a.request.object_sha256)
		if (auto_readback.values[identity] or 0) < AUTO_READBACKS then
			state.readback = true; auto_readback.put(identity, (auto_readback.values[identity] or 0) + 1)
			send_command(cx, source, origin, "readback_publication", { action_id = a.action_id })
			return
		end
	end
	state.attempts += 1
	state.next_at = awake_now() + (AUTO_RECONCILE_DELAYS[state.attempts + 1] or 0)
	drivers[key] = { key = key, source = source, origin = origin, scope = a.action_id, worker_id = worker_id,
		reconcile_action_id = a.action_id, auto = true, stale_result = if scoped.result then scoped.result.request_id else nil }
end
-- Nightly orphan mailbox sweep. The local clock's latest slot at or before now (today's sweep_time,
-- else yesterday's) is due once when newer than the durable last run (late = catch-up); the host
-- refuses any date at or before its last run, so reloads and duplicate views never run a day twice.
local SWEEP_RETRY_MS = 600000
local sweep_attempts: any = {}
local function sweep_slot(time_text: any): (string?, boolean)
	local hour: string?, minute: string?, second: string? = nil, nil, nil
	if type(time_text) == "string" then hour, minute, second = time_text:match("^(%d%d):(%d%d):(%d%d)$") end
	if not hour then return nil, false end
	local now = os.time()
	local t: any = os.date("*t", now)
	local slot = (tonumber(hour) or 0) * 3600 + (tonumber(minute) or 0) * 60 + (tonumber(second) or 0)
	local current = t.hour * 3600 + t.min * 60 + t.sec
	if current >= slot then return os.date("%Y-%m-%d", now) :: string, current - slot > 900 end
	return os.date("%Y-%m-%d", os.time({ year = t.year, month = t.month, day = t.day - 1, hour = 12 })) :: string, true
end
local function sweep_due(cx: WindowCx, source: number, origin: any, flow: any)
	if flow.policy.sweep_enabled ~= true then return end
	local date, catch_up = sweep_slot(flow.policy.sweep_time)
	if not date or (type(flow.sweep_last_date) == "string" and flow.sweep_last_date >= date) then return end
	-- One request per due day per controller incarnation; a refused request is retried only after 10 minutes.
	local attempt = sweep_attempts[source]
	if attempt and attempt.date == date and attempt.nonce == origin.alias_nonce and tern.now() < attempt.retry_at then return end
	sweep_attempts[source] = { date = date, nonce = origin.alias_nonce, retry_at = tern.now() + SWEEP_RETRY_MS }
	send_command(cx, source, origin, "sweep", { local_date = date, catch_up = catch_up })
end
local cleanup_observations: any = {}
local function cleanup_interaction(cx: WindowCx, source: number)
	local flow, data = workflow_node(cx, source, "workflow-index", "orchplus.workflow"), snapshot(cx, source)
	if not flow or not data or not flow.policy.sweep_enabled then return end
	local date = sweep_slot(flow.policy.sweep_time)
	local today = os.date("%Y-%m-%d", os.time())
	if date ~= today or (flow.cleanup_notice_date or "") >= today or cleanup_observations[source] then return end
	local origin = origin_now(cx, source, data)
	if origin and current_origin(cx, source, origin) then
		cleanup_observations[source] = { origin = origin, date = today, started = tern.now(), stale_ms = flow.policy.stale_ms }
	end
end
local function cleanup_tick(cx: WindowCx)
	for source, pending in cleanup_observations do
		if not native_scope.authorized_origin(cx, source, pending.origin) then cleanup_observations[source] = nil; continue end
		if not pending.command and tern.now() - pending.started > 60000 then
			cleanup_observations[source] = nil
			notice(cx, source, pending.origin.alias_nonce, "Communication-file observation did not finish in time. No counts were inferred; the next panel interaction will check again.", "info")
			continue
		end
		local data = snapshot(cx, source)
		if pending.command then
			local result = if data then data.command_result else nil
			if result and result.request_id == pending.command then
				if result.ok and result.code == "cleanup_summary" and type(result.message) == "string" then notice(cx, source, pending.origin.alias_nonce, result.message, "info") end
				if pending.bridge then relay_ack(cx, pending.bridge, "response") end
				cleanup_observations[source] = nil
			elseif tern.now() - (pending.command_started or pending.started) > 30000 then
				cleanup_observations[source] = nil
				notice(cx, source, pending.origin.alias_nonce, "The daily summary's saved result is not confirmed. No notification was replayed.", "info")
			end
			continue
		end
		if not data or not data.session_control or not data.session_control.admitted then continue end
		local bridge = pending.bridge or acquire_bridge(cx, source, pending.origin, "inventory")
		if not bridge then continue end
		pending.bridge = bridge
		local node, bytes = peer_surface(cx, bridge, BRIDGE_BLOCK, "spawn.dispatch.response")
		if not node then continue end
		if not pending.query then
			local query = { schema = 2, origin = "orchplus", op = "mailbox_inventory", request_id = dispatch_id(), action_id = dispatch_id(),
				authority_namespace = data.authority_namespace, logical_session_id = pending.origin.logical_session_id,
				admission_seq = data.session_control.admission_seq, origin_binding = pending.origin, controller_pane = tostring(source),
				controller_generation = pending.origin.owner_generation, stale_ms = pending.stale_ms }
			pending.query, pending.query_json = query, tern.json.encode(query)
			if not relay_event(cx, bridge, { act = "mailbox_inventory", value = pending.query_json }) then pending.query = nil end
			continue
		end
		local response = if bytes then dispatch.decode_response(bytes, pending.query) else nil
		if response and response.status == "inventory" and bridge.reads and bridge.reads.response then
			pending.command = send_command(cx, source, fresh_intent(cx, source, pending.origin), "cleanup_notice", {
				local_date = pending.date, time_zone = os.date("%Z"),
				inventory_proof = { query_json = pending.query_json, lane_id = bridge.lane_id, peer_boot = bridge.peer_boot,
					receipt = { id = bridge.reads.response.id, incarnation = bridge.reads.response.incarnation } },
			}, true)
			if pending.command then pending.command_started = tern.now() end
		elseif response and response.status ~= "pending" or tern.now() - pending.started > 60000 then
			if response then relay_ack(cx, bridge, "response") end
			cleanup_observations[source] = nil
			notice(cx, source, pending.origin.alias_nonce, "Communication files could not be checked yet. No count or stale-file result was inferred; the next interaction will check again.", "info")
		end
	end
end
-- Work sources (D10/D12, Contract K): the Start work picker, board lane writer and inbox poller. The
-- host's `*_intake` commands are idempotent on intake_id = quota.digest({kind, path, sha256}) (path =
-- board_path or inbox_folder/name; sha256 = the card's text_sha256 or the file's content sha256),
-- which serializes racing windows. This window owns native desktop board lane writes and asks
-- the execution host to observe its inbox and archive only exact accepted versions. Polling
-- runs on poll_ms with bounded per-tick work.
local work_sources = (function()
	local TICK_BUDGET_MS, CALLBACK_BUDGET_MS = 8, 20 -- Lua-time slices; anything left defers.
	local BOARD_ROWS, BOARD_PAGES = 500, 8
	local RESEND_MS, RECHECK_MS = 30000, 60000
	local state: any = {} -- controller source -> { nonce, board, inbox }
	local warned, digests = fifo(256), fifo(2048) -- A 500-card board holds two memo entries per card.
	local function over(deadline: number): boolean return tern.now() >= deadline end
	-- Attention: one dispatch notice per condition key (bounded), never a per-tick toast storm.
	local function warn(cx: WindowCx, source: number, origin: any, key: string, message: string)
		key = origin.alias_nonce .. "|" .. key
		if warned.values[key] then return end
		warned.put(key, true)
		notice(cx, source, origin.alias_nonce, message)
	end
	local function memo(key: string, compute: () -> any): any
		local hit = digests.values[key]
		if hit == nil then hit = compute(); digests.put(key, hit) end
		return hit
	end
	local function derive(kind: string, path: string, sha256: string): string
		return memo(kind .. "\0" .. path .. "\0" .. sha256, function() return quota.digest({ kind = kind, path = path, sha256 = sha256 }) end)
	end
	local function tag_list(tags: any): any
		local out = tern.json.array()
		if type(tags) == "table" then for _, tag in tags do if type(tag) == "string" then table.insert(out, tag) end end end
		return out
	end
	-- { text_sha256, intake_id } of one card's exact text + tags on this board.
	local function card_digest(path: string, text: string, tags: any): any
		return memo("card\0" .. path .. "\0" .. text .. "\0" .. table.concat(tags, "\0"), function()
			local text_sha256 = quota.digest({ text = text, tags = tags })
			return { text_sha256 = text_sha256, intake_id = derive("board", path, text_sha256) }
		end)
	end
	local function ensure(source: number, origin: any): any
		local s = state[source]
		if not s or s.nonce ~= origin.alias_nonce then s = { nonce = origin.alias_nonce }; state[source] = s end
		return s
	end
	local function board_state(s: any, path: string): any
		if not s.board or s.board.path ~= path then s.board = { path = path, remap = {}, sent = {}, moving = {}, next_poll = 0 } end
		return s.board
	end
	-- Host projection (views "workflow-intake"): newest intakes by id plus the mapped board cards.
	local function intake_index(cx: WindowCx, source: number): any?
		local node = workflow_node(cx, source, "workflow-intake", "orchplus.intake")
		if type(node) ~= "table" then return nil end
		local by_id = {}
		for _, rec in (if type(node.intakes) == "table" then node.intakes else {}) do
			if type(rec) == "table" and type(rec.intake_id) == "string" then by_id[rec.intake_id] = rec end
		end
		return { by_id = by_id, board = if type(node.board) == "table" then node.board else nil }
	end
	-- Board: one full scan (≤BOARD_PAGES reads of ≤500 rows, one read per tick) then one pass that
	-- applies desired lanes, re-maps id-invalidated cards and sends new queued cards.
	local function apply_board(cx: WindowCx, source: number, origin: any, b: any, lanes: any, truncated: boolean)
		if not native_scope.authorized_origin(cx, source, origin) then return end
		local flow = workflow_node(cx, source, "workflow-index", "orchplus.workflow")
		local view = intake_index(cx, source)
		if not flow or type(flow.policy) ~= "table" or source_ui.board_path(origin, flow.policy.board_path) ~= b.path or not view then return end
		local titles = if type(flow.policy.board_lanes) == "table" then flow.policy.board_lanes else {}
		local deadline = tern.now() + CALLBACK_BUDGET_MS
		local lane_by_title, duplicate, live, by_id = {}, {}, {}, {}
		for _, lane in lanes do
			if type(lane.title) == "string" then
				if lane_by_title[lane.title] then duplicate[lane.title] = true else lane_by_title[lane.title] = lane end
			end
			for _, card in (if type(lane.cards) == "table" then lane.cards else {}) do
				if type(card) == "table" and type(card.id) == "string" and type(card.text) == "string" and not by_id[card.id] then
					local c = { id = card.id, text = card.text, tags = tag_list(card.tags), lane = lane.title }
					table.insert(live, c); by_id[c.id] = c
				end
			end
		end
		local board = view.board
		local mapped = {}
		for _, mapping in (if board and type(board.cards) == "table" then board.cards else {}) do
			if mapping.path == b.path then table.insert(mapped, mapping) end
		end
		-- Projected card_id → live card, through this window's re-maps after id-invalidating reloads.
		local claimed, missing, projected, remap = {}, {}, {}, {}
		for _, m in mapped do
			if type(m) ~= "table" or type(m.card_id) ~= "string" or type(m.intake_id) ~= "string" then continue end
			projected[m.intake_id] = true
			local c = by_id[b.remap[m.card_id] or m.card_id] or by_id[m.card_id]
			if c and not claimed[c.id] then
				claimed[c.id] = m; m.live = c
				if c.id ~= m.card_id then remap[m.card_id] = c.id end
			else table.insert(missing, m) end
		end
		b.remap = remap
		-- Single lane writer: move each mapped card to the host's desired lane by exact lane id.
		for _, m in mapped do
			local c = if type(m) == "table" then m.live else nil
			local title = if c then titles[m.lane] else nil
			if not c or type(title) ~= "string" or c.lane == title or b.moving[c.id] then continue end
			local lane = lane_by_title[title]
			if duplicate[title] or not lane or type(lane.id) ~= "string" then
				warn(cx, source, origin, "board-lane:" .. b.path .. ":" .. title, "Board lane \"" .. title .. "\" is " .. (if duplicate[title] then "duplicated" else "missing")
					.. " on " .. b.path .. ", so mapped cards are not moved. Fix the board or Board lanes in Config.")
				continue
			end
			local card_id = c.id
			b.moving[card_id] = true
			local ok, pending = pcall(function() return cx.board:move(card_id, lane.id) end)
			if not ok then b.moving[card_id] = nil; continue end
			pending:next(function(_moved: any, err: string?, fresh: WindowCx?)
				b.moving[card_id] = nil
				if err and fresh then warn(fresh, source, origin, "board-move:" .. card_id .. ":" .. title, "Board card move to \"" .. title .. "\" failed: " .. tostring(err):sub(1, 300) .. ". It is retried on the next poll.") end
			end)
		end
		-- Exact text+tags digests of unmapped cards (memoized; an over-budget pass resumes next scan).
		local queued, candidates = titles.queued, {}
		for _, c in live do
			if source_adapter.is_plan_mirror(c.tags, c.text) or claimed[c.id] or (#missing == 0 and c.lane ~= queued) then continue end
			if over(deadline) then return end
			local d = card_digest(b.path, c.text, c.tags)
			c.text_sha256 = d.text_sha256
			local list = candidates[d.intake_id] or {}
			table.insert(list, c); candidates[d.intake_id] = list
		end
		local function send(c: any, intake_id: string)
			local sent = b.sent[intake_id]
			if sent and sent.card_id == c.id and awake_now() < sent.at + RESEND_MS then return end
			b.sent[intake_id] = { card_id = c.id, at = awake_now() }
			send_command(cx, source, origin, "board_intake", { board_path = b.path, card_id = c.id, text = c.text, tags = c.tags, text_sha256 = c.text_sha256 })
		end
		-- Re-map by exact text + tags among unmapped cards; zero or several matches → attention.
		for _, m in missing do
			if truncated then break end -- Unread rows could hold another match: never guess.
			local list = candidates[m.intake_id]
			if not list then
				warn(cx, source, origin, "board-gone:" .. m.intake_id .. ":" .. m.card_id, "The board card of intake " .. m.intake_id:sub(1, 12)
					.. " is no longer on " .. b.path .. " with its exact text and tags; its lane is not written. Restore the card or settle the work.")
			elseif #list > 1 then
				warn(cx, source, origin, "board-ambiguous:" .. m.intake_id .. ":" .. tostring(#list), tostring(#list) .. " unmapped cards on " .. b.path
					.. " have the exact text and tags of intake " .. m.intake_id:sub(1, 12) .. "; none was re-mapped. Remove the copies.")
			else
				local c = list[1]
				b.remap[m.card_id] = c.id; claimed[c.id] = m; candidates[m.intake_id] = nil
				send(c, m.intake_id) -- Same intake_id: the host keeps the record and learns the new card id.
			end
		end
		-- New cards in the queued lane become intakes; identical unmapped copies are ambiguous.
		for intake_id, list in candidates do
			local fresh_cards = {}
			for _, c in list do if c.lane == queued and not claimed[c.id] then table.insert(fresh_cards, c) end end
			if #fresh_cards == 0 then continue end
			local known = view.by_id[intake_id]
			if projected[intake_id] then
				warn(cx, source, origin, "board-copy:" .. intake_id, "A card on " .. b.path .. " repeats the exact text and tags of intake "
					.. intake_id:sub(1, 12) .. "; the copy is not a new intake.")
			elseif known and known.kind == "board" then
				continue -- Already recorded (received, accepted or refused): never re-sent.
			elseif #fresh_cards > 1 then
				warn(cx, source, origin, "board-twins:" .. intake_id .. ":" .. tostring(#fresh_cards), tostring(#fresh_cards) .. " new cards in \"" .. tostring(queued)
					.. "\" have identical text and tags; none was taken. Make each card distinct.")
			else
				send(fresh_cards[1], intake_id)
			end
		end
		-- Resend memory only for intakes still awaiting their projection.
		for intake_id in b.sent do if candidates[intake_id] == nil then b.sent[intake_id] = nil end end
	end
	local function read_board_page(cx: WindowCx, source: number, origin: any, b: any)
		local scan = b.scan
		scan.waiting = true; scan.started = tern.now()
		local ok, pending = pcall(function() return cx.board:read(b.path, { rows = BOARD_ROWS, from = scan.from }) end)
		if not ok then b.scan = nil; warn(cx, source, origin, "board-read:" .. b.path, "Board " .. b.path .. " cannot be read: " .. tostring(pending):sub(1, 300)); return end
		pending:next(function(snap: any, err: string?, fresh: WindowCx?)
			if not fresh or state[source] == nil or state[source].board ~= b or b.scan ~= scan then return end
			if err or type(snap) ~= "table" or type(snap.lanes) ~= "table" or snap.phase == "failed" then
				b.scan = nil
				warn(fresh, source, origin, "board-read:" .. b.path, "Board " .. b.path .. " cannot be read on this desktop: " .. tostring(err or snap and snap.phase or "no data"):sub(1, 300))
				return
			end
			if snap.phase == "loading" then b.scan = nil; return end -- Next poll reads it once loaded.
			for _, lane in snap.lanes do
				table.insert(scan.lanes, lane)
				if type(lane.more) == "number" and lane.more > 0 then scan.truncated = true end
			end
			scan.pages += 1
			local more = type(snap.more) == "number" and snap.more > 0
			if more and #snap.lanes > 0 and scan.pages < BOARD_PAGES then
				scan.from += #snap.lanes; scan.waiting = false -- The next tick reads the next ≤500 rows.
				return
			end
			if more then
				scan.truncated = true
				warn(fresh, source, origin, "board-large:" .. b.path, "Board " .. b.path .. " exceeds " .. tostring(BOARD_ROWS * BOARD_PAGES)
					.. " rows; cards past that are not taken and no card is re-mapped while unread rows remain.")
			end
			b.scan = nil
			apply_board(fresh, source, origin, b, scan.lanes, scan.truncated)
		end)
	end
	local function board_tick(cx: WindowCx, source: number, origin: any, flow: any, s: any)
		local path = source_ui.board_path(origin, flow.policy.board_path)
		if type(path) ~= "string" or (flow.policy.board_path == "" and not tern.fs.exists(path)) then s.board = nil; return end
		local b = board_state(s, path)
		local now = tern.now()
		-- A read whose answer never arrives (board closed mid-read) is abandoned; the next poll rescans.
		if b.scan and b.scan.waiting and now - b.scan.started > EFFECT_DEADLINE_MS then b.scan = nil end
		if b.scan then
			if not b.scan.waiting then read_board_page(cx, source, origin, b) end
			return
		end
		if now < b.next_poll then return end
		b.next_poll = now + flow.policy.poll_ms
		b.scan = { from = 1, lanes = {}, pages = 0, truncated = false, waiting = false, started = now }
		read_board_page(cx, source, origin, b)
	end
	-- Inbox reads and archival execute in the owning host VM, never the desktop VM.
	local function inbox_request(cx: WindowCx, source: number, origin: any, ib: any, fields: any, archive: boolean?)
		fields.source_nonce, fields.origin, fields.request_id = origin.alias_nonce, origin, dispatch_id()
		fields.orch_project_id = ib.project_id
		ib.pending = { request_id = fields.request_id, name = fields.name, archive = archive, started = tern.now() }
		cx.session:event(source, { ev = "action", id = "main", act = if archive then "inbox-archive" else "inbox-observe", value = tern.json.encode(fields) })
	end
	local function inbox_tick(cx: WindowCx, source: number, origin: any, flow: any, s: any, view: any, _deadline: number)
		local configured = flow.policy.inbox_folder
		if type(configured) ~= "string" or configured == "" then s.inbox = nil; return end
		local ib = s.inbox
		if not ib or ib.configured ~= configured then
			ib = { configured = configured, files = {}, names = {}, cursor = 0, next_list = 0 }; s.inbox = ib
		end
		if ib.pending then
			local pending = ib.pending
			local response = workflow_node(cx, source, "inbox-observation", "orchplus.inbox")
			if not response or response.request_id ~= pending.request_id then
				if tern.now() - pending.started > EFFECT_DEADLINE_MS then
					ib.pending = nil; ib.next_list = tern.now() + flow.policy.poll_ms
					warn(cx, source, origin, "inbox-timeout:" .. pending.request_id, "The execution-host inbox did not answer. Its files remain retained; no work is resubmitted from an assumed result.")
				end
				return
			end
			ib.pending = nil
			if response.ok ~= true then
				if pending.name then ib.files[pending.name] = { checked_at = awake_now(), hold_until = awake_now() + RECHECK_MS } end
				ib.next_list = tern.now() + flow.policy.poll_ms
				warn(cx, source, origin, "inbox-host:" .. tostring(response.message), tostring(response.message or "Open session Sources and intake to choose an execution-host inbox."))
				return
			end
			ib.folder, ib.project_id = response.folder, response.orch_project_id
			if pending.archive then ib.files[pending.name] = { archived = true }; return end
			if response.names then
				for _, name in response.names do table.insert(ib.names, name) end
				if response.next_offset then inbox_request(cx, source, origin, ib, { offset = response.next_offset }); return end
				local present = {}
				for _, name in ib.names do present[name] = true end
				for name, entry in ib.files do if not present[name] or entry.archived then ib.files[name] = nil end end
				ib.cursor, ib.next_list = 0, tern.now() + flow.policy.poll_ms
			elseif pending.name and type(response.content_sha256) == "string" then
				local name, hash = pending.name, response.content_sha256
				local intake_id = derive("inbox", ib.folder .. "/" .. name, hash)
				local previous = ib.files[name]
				local entry = { intake_id = intake_id, checked_at = awake_now(), sent_at = if previous and previous.intake_id == intake_id then previous.sent_at else nil }
				ib.files[name] = entry
				local record = view.by_id[intake_id]
				if record and record.state == "accepted" then
					inbox_request(cx, source, origin, ib, { name = name, intake_id = intake_id, content_sha256 = hash }, true)
				elseif record and record.state == "refused" then
					warn(cx, source, origin, "inbox-refused:" .. intake_id, "Inbox file " .. name .. " was refused and stays untaken on its execution host.")
				elseif not record and (not entry.sent_at or awake_now() >= entry.sent_at + RESEND_MS) then
					entry.sent_at = awake_now()
					send_command(cx, source, origin, "inbox_intake", { name = name, content_sha256 = hash, orch_project_id = ib.project_id })
				end
				return
			end
		end
		if ib.cursor >= #ib.names then
			if tern.now() < ib.next_list then return end
			ib.names, ib.cursor = {}, 0
			inbox_request(cx, source, origin, ib, {})
			return
		end
		local examined = 0
		while ib.cursor < #ib.names and examined < 128 do
			ib.cursor += 1; examined += 1
			local name = ib.names[ib.cursor]
			local entry = ib.files[name]
			local record = if entry and entry.intake_id then view.by_id[entry.intake_id] else nil
			if not entry or (not entry.archived and awake_now() >= (entry.hold_until or 0)
				and ((record and record.state == "accepted") or awake_now() >= (entry.checked_at or 0) + RECHECK_MS)) then
				inbox_request(cx, source, origin, ib, { name = name })
				return
			end
		end
	end
	-- One step per controller per observation tick (from schedule). Returns the sources this window
	-- polls for the controller ("the intake inbox", "the board", or both), or nil: the idle-wake
	-- helper counts them as timed work.
	local function step(cx: WindowCx, source: number, origin: any, flow: any): string?
		local s = ensure(source, origin)
		local view = intake_index(cx, source)
		if not view then return nil end
		local deadline = tern.now() + TICK_BUDGET_MS
		local ok, failure = pcall(board_tick, cx, source, origin, flow, s)
		if not ok then s.board = nil; warn(cx, source, origin, "board-failure:" .. tostring(failure):sub(1, 120), "Board polling failed: " .. tostring(failure):sub(1, 300)) end
		ok, failure = pcall(inbox_tick, cx, source, origin, flow, s, view, deadline)
		if not ok then
			if s.inbox then s.inbox.pending = nil end
			warn(cx, source, origin, "inbox-failure:" .. tostring(failure):sub(1, 120), "Inbox polling failed: " .. tostring(failure):sub(1, 300))
		end
		-- A configured Tern board is always desktop-owned, including for an attached execution host.
		local board = s.board ~= nil
		local inbox = s.inbox ~= nil
		return if board and inbox then "the intake inbox and board" elseif inbox then "the intake inbox" elseif board then "the board" else nil
	end
	local function prune(live: any) for source in state do if not live[source] then state[source] = nil end end end
	return { step = step, prune = prune }
end)()
-- The controller blocks this window scans each tick: in its current session on its current host.
local function scanned_controller(pane: any, membership: any, session: any): boolean
	return pane.block == BLOCK and pane.tab ~= nil and membership[pane.tab] == session.id
end
-- Whether a driver of this source already scopes the action, or drives the given bridge lane.
local function scope_busy(source: number, action_id: string): boolean
	for _, other in drivers do if other.source == source and other.scope == action_id then return true end end
	return false
end
local function lane_busy(source: number, worker_id: string?): boolean
	local lane = worker_id or "catalog"
	for _, other in drivers do if other.source == source and (other.worker_id or "catalog") == lane then return true end end
	return false
end
-- Tern limitation (0.9.12, a Tern bug): a due window tern.timer does not wake an untouched
-- window. On Linux/X11 (Xvfb) no window timer of any plugin ran for minutes, until input, a
-- control request, a rendered block frame or a finished child process woke the loop, while host
-- timers kept time; every due timer runs in such a wake. So while this window drives an active
-- controller with timed work (a registered worker's observation and poll, inbox or board polling
-- this window performs, an effect driver, a capacity or backpressure backoff, a USAGE read), or an
-- owner-started recovery or withdrawal read is pending, exactly one short argv-only wait child
-- stays in flight. It does nothing; its callback only starts the next one. None without such work,
-- in host VMs (native tests) or after a failed or early-exiting child. WAKE_MS stays below
-- SUSPENSION_GAP_MS, so an untouched window is never mistaken for a suspended host. Each
-- controller's Health card shows the helper state.
local idle_wake = (function()
	local WAKE_MS = 2000
	-- Windows has no argv-only headless sleep (timeout.exe refuses redirected input); three
	-- loopback pings are 2 s apart in total.
	local WAKE_ARGV: any = { windows = { "ping", "-n", "3", "127.0.0.1" } }
	-- Controllers this window drove in its latest schedule pass: source -> alias nonce, workers, active.
	local controllers: any = {}
	local wake: any = { pending = false, needed = false, unavailable = nil, published = {} }
	local function work(source: number): string?
		local controller = controllers[source]
		if controller == nil then return nil end
		if guides[source] or withdrawals[source] then return "reading SPAWN status for the owner" end
		if not controller.active then return nil end -- Awaiting explicit continuation: nothing timed runs.
		if conversation_ui and conversation_ui.runnable(source) then return "settling a conversation choice" end
		if setup_ui.active(source) then return "loading or saving settings" end
		if controller.workers > 0 then return "polling " .. tostring(controller.workers) .. (if controller.workers == 1 then " worker" else " workers") end
		if controller.sources then return "polling " .. controller.sources end
		for _, driver in drivers do if driver.source == source then return "driving an effect" end end
		for _, waiting in capacity_waits do if waiting.source == source then return "capacity backoff" end end
		for _, waiting in recheck_waits do if waiting.source == source then return "backpressure recheck" end end
		if readers[source] then return "reading USAGE capacity" end
		return nil
	end
	local function start()
		if wake.pending or wake.unavailable or not wake.needed then return end
		local started_at = tern.now()
		local ok, failure = pcall(function()
			tern.process.run(WAKE_ARGV[tern.runtime.os] or { "sleep", "2" }, function(result: any, _fresh: WindowCx?)
				wake.pending = false
				if result.status ~= 0 then wake.unavailable = "its wait child failed (status " .. tostring(result.status) .. ")"; return end
				if tern.now() - started_at < WAKE_MS / 2 then wake.unavailable = "its wait child exited early"; return end
				start()
			end)
		end)
		wake.pending = ok
		if not ok then wake.unavailable = tostring(failure):sub(1, 200) end
	end
	-- After schedule: start or stop the helper, then publish each controller's helper state on change.
	local function keep(cx: WindowCx)
		if tern.context ~= "window" then return end
		local states = {}
		wake.needed = false
		for source, controller in controllers do
			local timed = work(source)
			wake.needed = wake.needed or timed ~= nil
			states[source] = { source_nonce = controller.nonce, state = if timed == nil then "idle" else "active", detail = timed }
		end
		start()
		for _, status in states do
			if status.state == "active" and wake.unavailable then status.state = "unavailable"; status.detail = wake.unavailable end
		end
		for source, published in wake.published do
			if states[source] == nil then states[source] = { source_nonce = published.source_nonce, state = "idle" } end -- Left this window: once.
		end
		for source, status in states do
			local bytes = tern.json.encode(status)
			if wake.published[source] == nil or wake.published[source].bytes ~= bytes then
				local _, node = snapshot(cx, source)
				if node then cx.session:event(source, { ev = "action", id = node.id, act = "idle-wake", value = bytes })
				elseif controllers[source] then continue end -- Unreadable now: publish on a later tick.
			end
			wake.published[source] = if controllers[source] then { source_nonce = status.source_nonce, bytes = bytes } else nil
		end
	end
	local function note(source: number, nonce: string, workers: number, active: boolean)
		controllers[source] = { nonce = nonce, workers = workers, active = active }
	end
	-- The work sources (inbox, board) this window polled for the controller in this pass.
	local function sources(source: number, polled: string?)
		if controllers[source] then controllers[source].sources = polled end
	end
	return { clear = function() table.clear(controllers) end, note = note, sources = sources, keep = keep }
end)()
-- A queued attachment changes the worker's continuation proof while its old route
-- remains uncontinued. Follow that exact new action, never submit another decision.
local function retain_attachment(cx: WindowCx, source: number, origin: any, worker: any): boolean
	if not worker.active_action_id or not (worker.continuation_required or worker.reattach_needed) then return false end
	local scoped = snapshot(cx, source, worker.active_action_id)
	local action = if scoped then scoped.action else nil
	local request = if action then action.request else nil
	if not request or request.op ~= "attach_worker" then return false end
	if action.phase ~= "ready" or action.claim or action.reconciliation_only or action.start_blocked or held_actions[action.action_id]
		or action.worker_id ~= worker.worker_id or request.worker_id ~= worker.worker_id
		or request.worker_generation ~= worker.worker_generation or request.work_id ~= worker.work_id
		or request.controller_pane ~= tostring(source) or not same_origin(request.origin_binding, origin)
		or not same_origin(action.execution_origin or request.origin_binding, origin)
		or not same_policy(request.previous_pane_binding, worker.pane_binding)
		or not same_origin(request.previous_origin_binding, worker.origin_binding) then return true end
	local target = if request.pane_binding then tonumber(request.pane_binding.pane_id) else nil
	local pane = if target then scoped_pane(cx, target, origin) else nil
	if not pane or pane.exited ~= nil or pane.at_prompt == true or not same_policy(request.pane_binding, pane_binding(target :: number, origin)) then return true end
	for _, candidate in drivers do
		if candidate.source == source and (candidate.scope == action.action_id or (candidate.command_request_id
			and scoped.result and scoped.result.ok and scoped.result.request_id == candidate.command_request_id
			and scoped.result.action_id == action.action_id)) then
			candidate.attachment_action_id = action.action_id
			return true
		end
	end
	local due, stale = capacity_ready(action.action_id)
	local key = tostring(source) .. ":attach:" .. worker.worker_id
	if due and not drivers[key] then
		drivers[key] = { key = key, source = source, origin = fresh_intent(cx, source, origin), scope = action.action_id,
			worker_id = worker.worker_id, attachment_action_id = action.action_id, stale_result = stale }
	end
	return true
end

local function schedule(cx: WindowCx)
	idle_wake.clear()
	local membership = tab_sessions(cx)
	local live = {}
	for _, pane in cx.session:panes() do
		if pane.block ~= BLOCK or pane.parked or pane.tab == nil then continue end
		local host = host_for(cx, pane.pane)
		local session = { id = membership[pane.tab] }
		if not host or host.state ~= "connected" or session.id == nil then continue end
		local source = pane.pane
		live[source] = true
		push_config_panes(cx, source, host, session, membership)
		local data = snapshot(cx, source)
		if not data then release_closed_bridge_view(cx, source); continue end
		setup_api.upgrade_readbacks = setup_api.upgrade_readbacks or {}
		if data.authority_version == 5 and setup_api.upgrade_readbacks[source] ~= data.authority_namespace then
			setup_api.upgrade_readbacks[source] = data.authority_namespace
			cx.session:event(source, { ev = "action", id = "main", act = "upgrade-window-readback", value = tern.json.encode({
				source_nonce = data.source_nonce, version = 5, authority_namespace = data.authority_namespace, revision = data.authority_revision }) })
		end
		local input = captured_inputs[source]
		if input then
			if not current_origin(cx, source, input.origin) then input.blocking = false
			else
				-- A real intervening commit already invalidated this input. Let background
				-- work continue, but retain its original fence for the eventual refusal.
				local fence = intent_fences[input.origin]
				input.blocking = fence ~= nil and fence.authority_namespace == data.authority_namespace
					and fence.expected_revision == data.authority_revision
			end
		end
		closed_view_scans[source] = nil
		local close = if data.session_control then data.session_control.close else nil
		local captured = data.command_cursor and data.command_cursor.origin
		local origin = if captured and native_scope.owned_origin(cx, source, captured) then intent_origin(captured, data)
			elseif data.owner_id then origin_now(cx, source, data)
			elseif close and close.control_origin then intent_origin(close.control_origin.binding, data) else nil
		if not origin then continue end
		if automatic_connection and current_context(cx, source, origin) then automatic_connection(cx, source, data, origin) end
		-- A persisted or running forget owns this session's closing pipeline; ordinary close never runs beside it.
		if not conversation_ui.forget.tick_source(cx, source, data, origin) then bridge_control_tick(cx, source, data, origin) end
		if not data.owner_id or (data.session_control and data.session_control.phase == "closing") then continue end
		local flow = workflow_node(cx, source, "workflow-index", "orchplus.workflow")
		if not flow or type(flow.worker_ids) ~= "table" or type(flow.policy) ~= "table" then continue end
		idle_wake.note(source, origin.alias_nonce, #flow.worker_ids, data.controller_phase == "active")
		if data.session_control and data.session_control.admitted and native_scope.authorized_origin(cx, source, origin) and not control_pending(source, true) then
			for _, id in flow.worker_ids do
				local worker = worker_now(cx, source, id)
				if worker then retain_attachment(cx, source, origin, worker) end
			end
		end
		-- Give captured native controls, work-source dialogs and write preparation priority.
		-- Timers and captured effect drivers continue; no deadline or fence is changed.
		if control_pending(source) then
			-- Only an open form holds here: a capacity-refused launch has no driver, so a due backoff
			-- still gets one, and its guard tells the owner the form is why it waits.
			if not control_pending(source, true) then
				for action_id, wait in capacity_waits do
					local key = tostring(source) .. ":capacity:" .. action_id
					if wait.source == source and not drivers[key] and not held_actions[action_id] and awake_now() >= wait.next_at and not scope_busy(source, action_id) then
						local scoped = snapshot(cx, source, action_id)
						if scoped and scoped.action and scoped.action.phase == "ready" and not scoped.action.start_blocked and not lane_busy(source, scoped.action.worker_id) then
							drivers[key] = { key = key, source = source, origin = origin, scope = action_id, worker_id = scoped.action.worker_id, stale_result = wait.stale }
						end
					end
				end
			end
			continue
		end
		if native_scope.authorized_origin(cx, source, origin) and source_ui and source_ui.sync then source_ui.sync(cx, source, origin) end
		if native_scope.authorized_origin(cx, source, origin) then
			setup_api.proposals = setup_api.proposals or {}
			if current_origin(cx, source, origin) and source_ui and not source_ui.active(source) then
				for _, proposal in flow.source_requests or {} do
					local key = origin.alias_nonce .. ":" .. proposal.gate_id .. ":" .. tostring(proposal.gate_revision)
					if not setup_api.proposals[key] then
						setup_api.proposals[key] = true
						source_ui.start(cx, source, fresh_intent(cx, source, origin), "source-proposal", proposal)
						break
					end
				end
			end
			local index = workflow_node(cx, source, "project-index", "orchplus.projects")
			local observed = false
			for _, project in (if index then index.projects or {} else {}) do
				for id, association in project.associations or {} do
					local binding = association.pane_binding
					local pane = if binding.window_epoch == incarnation then scoped_pane(cx, tonumber(binding.pane_id), origin) else nil
					if not pane then continue end
					local active = pane.busy == true
					for _, native in cx.agents:list() do
						if native.pane == pane.pane then active = native.state == "idle" or native.state == "working" or native.state == "waiting_input"; break end
					end
					if active ~= association.active then
						send_command(cx, source, fresh_intent(cx, source, origin), "observe_conversation", {
							orch_project_id = project.orch_project_id, project_revision = project.revision, conversation_id = id,
							pane_binding = binding, active = active })
						observed = true; break
					end
				end
				if observed then break end
			end
		end
		sweep_due(cx, source, fresh_intent(cx, source, origin), flow)
		-- Work sources (time-sliced; step pcalls each half), then USAGE refresh when routing awaits it.
		idle_wake.sources(source, work_sources.step(cx, source, fresh_intent(cx, source, origin), flow))
		local routing = if flow.policy.quota_routing then routing_index(cx, source) else nil
		if routing and routing.refresh_due == true and readers[source] == nil then start_reader(source, fresh_intent(cx, source, origin), "snapshot") end
		local scan = scans[source]
		if not scan or scan.nonce ~= origin.alias_nonce then
			scan = { nonce = origin.alias_nonce, cursor = 0, observed = {}, watermarks = {}, next_poll = {}, startup_until = {}, paced = {}, focused_until = {} }; scans[source] = scan
		end
		-- One registered worker per turn: bounded callback work and fair rotation.
		if #flow.worker_ids == 0 then
			-- The last worker left: forget every per-worker timer and counter at once.
			for _, per_worker in { scan.observed, scan.watermarks, scan.next_poll, scan.startup_until, scan.paced, scan.focused_until } do table.clear(per_worker) end
		end
		if #flow.worker_ids > 0 then
			scan.cursor = scan.cursor % #flow.worker_ids + 1
			if scan.cursor == 1 then
				-- Once per rotation: forget per-worker timers/counters of workers no longer registered.
				local registered = {}
				for _, worker_id in flow.worker_ids do registered[worker_id] = true end
				for _, per_worker in { scan.observed, scan.watermarks, scan.next_poll, scan.startup_until, scan.paced, scan.focused_until } do
					for worker_id in per_worker do if not registered[worker_id] then per_worker[worker_id] = nil end end
				end
			end
			local worker = worker_now(cx, source, flow.worker_ids[scan.cursor])
			if worker and worker.origin_binding and native_scope.authorized_origin(cx, source, worker.origin_binding) then
				local now = tern.now()
				-- Enrollment is a bounded startup handshake, not a periodic progress report.
				local startup = worker.pane_binding ~= nil and (worker.phase == "awaiting_acceptance"
					or worker.phase == "accepted" and worker.coordinator_owner_id ~= nil and worker.activation_received ~= true)
				if startup then
					scan.startup_until[worker.worker_id] = scan.startup_until[worker.worker_id] or now + 120000
					startup = now < scan.startup_until[worker.worker_id]
				else scan.startup_until[worker.worker_id] = nil end
				-- The host decides each worker's cadence (coordinators look every 10 s, SKILLS-214).
				local cadence = if type(worker.poll_ms) == "number" and worker.poll_ms > 0 then worker.poll_ms else flow.policy.poll_ms
				local poll_ms = if startup then math.min(cadence, 2000) else cadence
				-- Talking to a coordinator in its own pane is activity ORCH+ cannot see otherwise: OMP's
				-- state stays unknown and typing is not observable. While its pane is focused in this
				-- window, and for 10 minutes after, it is checked at its 10 s cadence (einh's pick
				-- "Focus restarts it", SKILLS-214). Window memory only; nothing is persisted.
				if worker.coordinator_owner_id ~= nil and worker.pane_binding then
					local pane = scoped_pane(cx, tonumber(worker.pane_binding.pane_id), worker.pane_binding)
					if pane and pane.focused == true then scan.focused_until[worker.worker_id] = now + dispatch.COORDINATOR_FAST_MS end
				end
				local talking = now < (scan.focused_until[worker.worker_id] or 0)
				if now >= (scan.observed[worker.worker_id] or 0) then
					scan.observed[worker.worker_id] = now + poll_ms
					local native, _reason, _pane, problem = native_observation(cx, source, worker)
					if worker.pane_binding then
						send_command(cx, source, fresh_intent(cx, source, origin), "observe", { worker_id = worker.worker_id, pane_binding = worker.pane_binding,
							native_state = native, delivery_error = problem })
					end
				end
				local driver, command_pending = nil, false
				for _, candidate in drivers do
					if candidate.source == source then
						if candidate.command_request_id then command_pending = true end
						if candidate.worker_id == worker.worker_id
							or (worker.active_action_id and candidate.scope == worker.active_action_id)
							or (worker.active_action_id and candidate.command_request_id and data.driver_result and data.driver_result.request_id == candidate.command_request_id
								and data.driver_result.action_id == worker.active_action_id) then driver = candidate end
					end
				end
				-- A continuation poll that came back without an action (refused or nothing granted) is
				-- paced for one cadence before continuation may bypass the schedule again (SKILLS-214).
				local continuation = worker.poll_continuation == true and now >= (scan.paced[worker.worker_id] or 0)
				if not worker.active_action_id and not driver and not command_pending
					and (continuation or now >= (scan.next_poll[worker.worker_id] or 0)) then
					local scheduled = false
					-- This is a new intent, not a replay of the observation sent above or a pending poll.
					local command_origin = fresh_intent(cx, source, origin)
					-- Policy rollover only requests a checkpoint; the host reducer rechecks every condition.
					if continuation then
						local request_id = send_command(cx, source, command_origin, "poll", { worker_id = worker.worker_id })
						if request_id then
							local key = tostring(source) .. ":" .. worker.worker_id
							driver = { key = key, source = source, origin = command_origin, worker_id = worker.worker_id, command_request_id = request_id,
								continuation = true, pace_ms = poll_ms }
							drivers[key] = driver
						end
					elseif worker.due_rollover and not flow.policy.paused then
						scheduled = send_command(cx, source, command_origin, "rollover", { worker_id = worker.worker_id, trigger = "policy" }) ~= nil
					elseif worker.due_report and not worker.report_request_pending and not flow.policy.paused then
						scheduled = send_command(cx, source, command_origin, "reply", { worker_id = worker.worker_id, trigger = "policy" }) ~= nil
					elseif worker.stale_coordinator ~= true
						and (startup or worker.due_poll or talking or (worker.report_request_pending and not worker.report_held)) then
						-- A stale coordinator generation is never polled (the host refuses it with owner_mismatch).
						-- A held report blocks this generation's report lane (no automatic report or watermark
						-- re-read until the owner acts); due_poll covers outbound settlement.
						-- Alternate receipt confirmation with report discovery while receipts
						-- remain unconfirmed. A debt-free watermark cannot advance anything.
						local watermark = not worker.report_held and worker.receipt_unconfirmed == true
							and scan.watermarks[worker.worker_id] ~= true
						scan.watermarks[worker.worker_id] = watermark
						local request_id = send_command(cx, source, command_origin, "poll", { worker_id = worker.worker_id,
							bytes = if watermark then "watermark" else nil })
						if request_id then
							scheduled = true
							local key = tostring(source) .. ":" .. worker.worker_id
							driver = { key = key, source = source, origin = command_origin, worker_id = worker.worker_id, command_request_id = request_id }
							drivers[key] = driver
						end
					end
					if scheduled and not continuation then scan.next_poll[worker.worker_id] = now + poll_ms end
				end
				worker = worker_now(cx, source, worker.worker_id) or worker
				if not driver and worker.active_action_id then
					local scoped = snapshot(cx, source, worker.active_action_id)
					local key = tostring(source) .. ":" .. worker.worker_id
					local due, stale = capacity_ready(worker.active_action_id)
					if scoped and scoped.action and scoped.action.phase == "ready" and not scoped.action.start_blocked and not held_actions[worker.active_action_id] then
						if due then drivers[key] = { key = key, source = source, origin = origin, scope = worker.active_action_id, worker_id = worker.worker_id, stale_result = stale } end
					elseif scoped and scoped.action then
						if scoped.action.phase == "backpressure" and not held_actions[worker.active_action_id] and not recheck_waits[worker.active_action_id] then
							recheck_hold(source, worker.active_action_id, scoped.action.retry_count)
						end
						auto_reconcile_due(cx, source, origin, scoped, key, worker.worker_id)
					end
				end
			end
		end
		-- Catalog has no worker; it still gets one exact scoped executor.
		if not drivers[source] and data.action and not data.action.worker_id and data.action.phase == "ready" and not data.action.start_blocked and not held_actions[data.action.action_id] then
			local due, stale = capacity_ready(data.action.action_id)
			if due then drivers[source] = { source = source, origin = origin, scope = data.action.action_id, stale_result = stale } end
		end
		if data.action and not data.action.worker_id and data.action.phase == "backpressure" and not held_actions[data.action.action_id] and not recheck_waits[data.action.action_id] then
			recheck_hold(source, data.action.action_id, data.action.retry_count)
		end
		-- Capacity-refused (still ready, never granted) actions resume once their backoff is due,
		-- whether or not they are selected; anything no longer ready leaves the wait.
		for action_id, wait in capacity_waits do
			if wait.source == source and not held_actions[action_id] and awake_now() >= wait.next_at and not scope_busy(source, action_id) then
				local scoped = snapshot(cx, source, action_id)
				if scoped == nil or not scoped.action or scoped.action.phase ~= "ready" then capacity_waits[action_id] = nil
				elseif not scoped.action.start_blocked and not lane_busy(source, scoped.action.worker_id) then
					local key = tostring(source) .. ":capacity:" .. action_id
					drivers[key] = { key = key, source = source, origin = origin, scope = action_id, worker_id = scoped.action.worker_id, stale_result = wait.stale }
				end
			end
		end
		-- Definitive pre-effect backpressure: once its backoff is due, send the owner's exact `retry`.
		-- Only the action's own bridge lane must be free (a worker action, ready again, is claimed by its
		-- worker's lane driver; a worker-less action's lane is the source's command driver). Anything no
		-- longer retryable on this exact route leaves the wait.
		for action_id, wait in recheck_waits do
			if wait.source == source and not held_actions[action_id] and awake_now() >= wait.next_at and not scope_busy(source, action_id) then
				local scoped = snapshot(cx, source, action_id)
				local a = if scoped then scoped.action else nil
				if a == nil or (a.phase ~= "backpressure" and a.phase ~= "ready" and a.phase ~= "claimed")
					or not same_origin(a.request.origin_binding, origin) or a.request.controller_pane ~= tostring(source) then
					recheck_waits[action_id] = nil
				elseif native_scope.project_start_delivery(cx, source, action_id) then
					-- START publication retries belong only to the scoped immutable grant.
					recheck_waits[action_id] = nil; held_actions[action_id] = true
					watch_settle(source, action_id, if a.claim then a.claim.grant_id else nil, a.request, scoped)
				elseif a.phase == "backpressure" and (wait.attempts >= CAPACITY_RETRIES or (a.retry_loop ~= nil and a.retry_loop.state ~= nil)) then
					recheck_waits[action_id] = nil; held_actions[action_id] = true; watch_settle(source, action_id, if a.claim then a.claim.grant_id else nil, a.request, scoped)
				-- Its operator answer would replace an owner command's still-unread answer: wait for that first.
				elseif a.phase == "backpressure" and not lane_busy(source, a.worker_id) and not (a.worker_id == nil and drivers[source] ~= nil)
					and not (drivers[source] ~= nil and drivers[source].owner_command) then
					wait.attempts += 1; wait.next_at = awake_now() + CAPACITY_RETRY_MS
					local id = send_command(cx, source, origin, "retry", { action_id = action_id }, true)
					if id and a.worker_id == nil then start_driver(source, origin, id) end
				end
			end
		end
		-- Every uncertain retained action gets bounded automatic read-only reconciliation, one read per
		-- bridge lane at a time (concurrent reads would overwrite its single response node).
		for _, action_id in (if type(data.uncertain_actions) == "table" then data.uncertain_actions else {}) do
			local scoped = if scope_busy(source, action_id) then nil else snapshot(cx, source, action_id)
			if scoped and scoped.action and scoped.action.phase == "uncertain" and not lane_busy(source, scoped.action.worker_id) then
				auto_reconcile_due(cx, source, origin, scoped, tostring(source) .. ":auto:" .. action_id, scoped.action.worker_id)
			end
		end
	end
	for source in scans do if not live[source] then scans[source] = nil end end
	for source in closed_view_scans do if not live[source] then closed_view_scans[source] = nil end end
	for source in sweep_attempts do if not live[source] then sweep_attempts[source] = nil end end
	for source in cleanup_observations do if not live[source] then cleanup_observations[source] = nil end end
	for source in allocation_reads do if not live[source] then allocation_reads[source] = nil end end
	for source in allocation_retries do if not live[source] then allocation_retries[source] = nil; allocation_notices[source] = nil end end
	for source in connection_attempts do if not live[source] then connection_attempts[source] = nil end end
	for source in pane_pushes do if not live[source] then pane_pushes[source] = nil end end
	for source in captured_inputs do if not live[source] then captured_inputs[source] = nil end end
	work_sources.prune(live)
	prune_settled(cx)
end
-- One explicit recovery flow: continue, recover SPAWN, retire/reclaim a fenced
-- controller generation when necessary, reconcile admission, then reattach.
-- Every mutation remains a separate native control; owner_status is read-only.
local OWNER_STEPS: any = {
	previous_incarnation = "SPAWN still binds this session to an earlier controller window. In SPAWN Config → Runtime, fence the managed controller, verify it and its launch executors stopped or retired, then confirm there.",
	other_owner = "SPAWN binds this session to a different controller owner. In SPAWN Config → Runtime, inspect and recover that owner explicitly.",
	fenced = "SPAWN owner recovery is fenced but not confirmed. Verify the previous controller and its launch executors stopped or retired, then confirm in SPAWN Config → Runtime.",
	other_authority = "SPAWN's managed authority or host session differs from this window. Open SPAWN Config in the original session and inspect its owner there.",
	unknown = "SPAWN's owner state could not be read (bridge unavailable or no answer). Open SPAWN Config → Runtime to inspect it.",
}
local function observed_owner_state(source: number, origin: any): string
	local observed = owner_states[source]
	return if observed and same_origin(observed.origin, origin) then observed.state else "unknown"
end
local guide_control: any = nil -- dispatch_control, assigned after its definition.
local consume_intents: any = nil -- Operator-intent consumer, assigned after dispatch_control.
local function guide_steps(cx: WindowCx, source: number, origin: any): { any }
	local steps = {}
	local data = snapshot(cx, source)
	-- A host-only restart keeps this window's origin but restores the controller as uncertain;
	-- the host projection, not the window epoch, decides whether continuation remains.
	local uncontinued = data ~= nil and data.owner_id ~= nil and data.controller_phase ~= "active"
	if uncontinued or not current_origin(cx, source, origin) then
		table.insert(steps, { kind = "continue", label = "Continue controller after reload",
			detail = "Attest that previous ORCH+/SPAWN executors stopped or retired; old claims and coordinator uncertainty stay held." })
	end
	local state = observed_owner_state(source, origin)
	if state == "retired" then
		table.insert(steps, { kind = "retire_controller", label = "Retire this fenced controller generation",
			detail = "SPAWN has retired this generation. Retire only this controller, then use Advanced → Recover this view for review only in the same orchestration. If its panel is closed, open ORCH+ and select the existing orchestration, not New orchestration. Review-only recovery does not admit SPAWN or resume workers; unresolved executors still prevent retirement." })
	elseif state ~= "current" and state ~= "none" then
		table.insert(steps, { kind = "spawn", label = "Recover the previous SPAWN owner (" .. tostring(state) .. ")", detail = OWNER_STEPS[state] or OWNER_STEPS.unknown })
	end
	local control = if data then data.session_control else nil
	if control and control.phase == "open" and (control.admitted ~= true or state == "none" or state == "retired") then
		table.insert(steps, if control.admission_seq ~= nil then
			{ kind = "reconcile_admission", label = "Reconcile the retained SPAWN admission",
				detail = "Observe and reconcile the existing admission through its normal bridge. Never replace an uncertain admission or replay an old effect." }
			else { kind = "admit", label = "Explicitly admit this controller to SPAWN",
				detail = "Use the normal current-pair admission control before reattachment; opening the guide grants no authority." })
	end
	local flow = workflow_node(cx, source, "workflow-index", "orchplus.workflow")
	for _, worker_id in (if flow and type(flow.worker_ids) == "table" then flow.worker_ids else {}) do
		local worker = worker_now(cx, source, worker_id)
		if worker and worker.cleanup_ready then
			table.insert(steps, { kind = "cleanup", worker_id = worker_id, label = "Settle stopped worker " .. worker_id,
				detail = "SPAWN positively observed this exact pane stopped. Read/retire its settled mailbox under the current admission; never attach to an absent pane." })
		end
		if worker and worker.reattach_needed then
			local pane = worker.launch_pane_binding or worker.pane_binding
			table.insert(steps, { kind = "reattach", worker_id = worker_id, label = "Reattach " .. worker.work_id .. " / " .. worker_id
				.. " (recorded pane " .. (if type(pane) == "table" and type(pane.pane_id) == "string" then pane.pane_id else "not recorded") .. ")",
				detail = "Select the exact existing pane and attest the old executors stopped or retired; nothing is adopted automatically." })
		end
	end
	local uncertain = if data and type(data.uncertain_actions) == "table" then #data.uncertain_actions else 0
	if uncertain > 0 then
		table.insert(steps, { kind = "uncertain", label = tostring(uncertain) .. " uncertain retained action" .. (if uncertain == 1 then "" else "s"),
			detail = "Automatic read-only reconciliation reads their SPAWN outcomes. A read SPAWN never recorded resolves without effect; an uncertain read never blocks reattachment and is superseded on the reattached route. Other effects that stay uncertain need Read retained SPAWN outcome or executor verification. Nothing is retried." })
	end
	return steps
end
local function publish_steps(cx: WindowCx, source: number, origin: any, steps: { any })
	local _, node = snapshot(cx, source)
	if not node then return end
	local rows = {}
	for _, step in steps do table.insert(rows, { label = step.label, detail = step.detail }) end
	local bytes = tern.json.encode({ source_nonce = origin.alias_nonce, steps = rows })
	while #bytes > 8192 and #rows > 0 do table.remove(rows); bytes = tern.json.encode({ source_nonce = origin.alias_nonce, steps = rows }) end
	cx.session:event(source, { ev = "action", id = node.id, act = "recovery-steps", value = bytes })
end
local function open_guide(cx: WindowCx, source: number, origin: any)
	local data = snapshot(cx, source)
	if not data then return end
	local steps = guide_steps(cx, source, origin)
	publish_steps(cx, source, origin, steps)
	local items, informational = {}, ""
	for _, step in steps do
		if step.kind == "uncertain" then informational = " Existing work is being checked."
		else
			table.insert(items, { label = (if #items == 0 then "Next: " else "Then: ") .. step.label, detail = step.detail, kind = step.kind, worker_id = step.worker_id })
		end
	end
	if #items == 0 then
		notice(cx, source, origin.alias_nonce, if informational ~= "" then "Checking your existing work without starting another copy."
			else "Connection checked. Existing work and permissions are unchanged.", "info", "ORCH+")
		return
	end
	table.insert(items, { label = "Close — nothing is done automatically" })
	forms_ui.choose(cx, source, origin, { placeholder = "Advanced connection details" .. informational, items = items }, function(fresh: WindowCx, choice: any)
		if not choice or not choice.kind or not current_context(fresh, source, origin) then return end
		local first = guide_steps(fresh, source, origin)[1]
		if not first or first.kind ~= choice.kind or first.worker_id ~= choice.worker_id then
			return notice(fresh, source, origin.alias_nonce, "Complete the preceding recovery step, then reopen the guide. No later step was submitted.")
		end
		local request = { source_nonce = origin.alias_nonce, orch_session_id = origin.logical_session_id,
			authority_namespace = data.authority_namespace, expected_revision = data.authority_revision }
		if choice.kind == "continue" then
			request.command = "continue_controller"; guide_control(fresh, source, request)
		elseif choice.kind == "retire_controller" then
			request.command = "retire_controller"; guide_control(fresh, source, request)
		elseif choice.kind == "reconcile_admission" or choice.kind == "admit" then
			request.command = if choice.kind == "reconcile_admission" then "bridge_reconcile" else "bridge_admit"
			guide_control(fresh, source, request)
		elseif choice.kind == "reattach" then
			request.command = "continue_worker"; request.worker_id = choice.worker_id; guide_control(fresh, source, request)
		elseif choice.kind == "cleanup" then
			request.command = "poll"; request.worker_id = choice.worker_id; guide_control(fresh, source, request)
		elseif choice.kind == "spawn" then
			-- SPAWN keeps its independent operator check: ORCH+ only opens its recovery page.
			local value = tern.json.encode({ kind = "page", page = "runtime", native_window = fresh:window_key() })
			local opened = fresh:new_block("spawn.spawner", { value }, "beside", { target = source, focus = true })
			notice(fresh, source, origin.alias_nonce, (if opened then "Opened SPAWN Config → Runtime." else "Open SPAWN Config → Runtime.")
				.. " Fence the managed controller, verify, then confirm. Reopen the recovery guide afterwards; ORCH+ never attests SPAWN recovery.")
		end
	end)
end
-- Start the read-only SPAWN owner_status probe; the guide opens once it answers or after 5 s awake.
-- Callers rearm the observation timer that drives probe_step.
local function start_guide(source: number, origin: any, open: boolean, continuation: string?)
	guides[source] = { origin = origin, open = open, continuation = continuation, started = awake_now() }
end
-- Send one read-only query of a probe `entry` on the source's catalog bridge lane, only while no
-- lane driver and no `other` probe's live read could have its single response node overwritten.
local function catalog_query(cx: WindowCx, source: number, entry: any, other: any, op: string, binding: any, generation: any, target: string?, target_serial: number?, allocation: any?)
	if other ~= nil and other.query ~= nil then return end
	for _, driver in drivers do if driver.source == source and driver.worker_id == nil then return end end
	local bridge = acquire_bridge(cx, source, entry.origin, "catalog")
	local node = if bridge ~= nil then peer_surface(cx, bridge, "spawn.dispatch", "spawn.dispatch.response") else nil
	if node then entry.bridge = bridge; entry.query = send_query(cx, bridge, node, source, op, binding, generation, target, target_serial, allocation) end
end
local function probe_step(cx: WindowCx)
	for source, guide in guides do
		if not (native_scope.owned_origin(cx, source, guide.origin) or current_context(cx, source, guide.origin)) then guides[source] = nil; continue end
		if guide.continuation then
			local data = snapshot(cx, source)
			local receipt = if data then data.command_result else nil
			if not receipt or receipt.request_id ~= guide.continuation or receipt.command ~= "continue_controller" then
				if awake_now() - guide.started > 5000 then
					guides[source] = nil
					notice(cx, source, guide.origin.alias_nonce, "The continuation result is not yet confirmed. Existing work remains held; no connection or effect was repeated.")
				end
				continue
			end
			if not receipt.ok or not native_scope.authorized_origin(cx, source, guide.origin) then guides[source] = nil; continue end
			-- A confirmed continuation can use a new native origin. Retain the old
			-- lane's obligations instead of letting its cached identity block admission.
			reconnect_relays(cx, source, guide.origin)
			guide.continuation = nil
		end
		local state: string? = nil
		if guide.query == nil then
			local target = guide.catalog_request
			if target then
				catalog_query(cx, source, guide, withdrawals[source], "status", target.origin_binding, target.controller_generation,
					target.request_id, target.request_serial)
			else catalog_query(cx, source, guide, withdrawals[source], "owner_status", guide.origin, guide.origin.owner_generation) end
		else
			local _, bytes = peer_surface(cx, guide.bridge, "spawn.dispatch", "spawn.dispatch.response")
			local body = if bytes then dispatch.decode_response(bytes, guide.query) else nil
			if body then guide.response_receipt = guide.bridge.reads.response end
			if body and guide.catalog_request then
				state = "catalog_unconfirmed"
				guide.catalog_status = body.status
				local retained = if body.status == "found" and body.payload then public_frame(body.payload.outcome) else nil
				local outcome = if retained then dispatch.decode_response(retained, guide.catalog_request) else nil
				if outcome and outcome.status == "catalog" then state = "catalog_available" end
			elseif body and body.category == "admission_absent" then state = "none"
			elseif body and body.category == "current_admission" and body.payload then
				local control = body.payload.control
				local binding = if control then control.binding else nil
				if control and control.recovery then
					if control.recovery.phase == "confirmed" and not binding then
						state = if guide.origin.owner_generation <= control.generation_floor then "retired" else "none"
					else state = "fenced" end
				elseif not binding then state = "none"
				elseif same_origin(binding, guide.origin) then state = "current"
				elseif binding.owner_id == guide.origin.owner_id and binding.owner_generation == guide.origin.owner_generation then state = "previous_incarnation"
				else state = "other_owner" end
			elseif body and body.category == "stale_authority" then state = "other_authority"
			elseif body then state = "unknown" end
		end
		if state == nil and awake_now() - guide.started > 5000 then state = "unknown" end
		if state ~= nil then
			guides[source] = nil
			if not guide.catalog_request and not guide.read_only then owner_states[source] = { origin = guide.origin, state = state } end
			local data = snapshot(cx, source)
			local control = if data then data.session_control else nil
			if guide.read_only then
				if guide.response_receipt and guide.bridge then relay_ack(cx, guide.bridge, "response", guide.response_receipt) end
				local connected = state == "catalog_available" or (state == "current" and control and control.admitted == true)
				local message = if guide.catalog_request then
					(if connected then "The earlier agent list result is available. No agent was started." else "Couldn’t load your agents. No agent was started.")
					elseif connected then "Connection checked. Your agents have not been reloaded. No agent was started."
					else "Couldn’t confirm the connection. Your agents have not been reloaded. No agent was started."
				notice(cx, source, guide.origin.alias_nonce, message, if connected then "info" else "error", "ORCH+", { context = "catalog",
					code = if connected then nil else "catalog_unconfirmed",
					detail = if guide.catalog_request then "Retained catalog status: " .. tostring(guide.catalog_status or "unconfirmed")
						elseif connected then nil else "Owner connection state: " .. tostring(state) })
				continue
			end
			if (guide.open or guide.automatic) and (state == "current" or state == "none" or (guide.automatic and state == "previous_incarnation")) and data and data.controller_phase == "active"
				and native_scope.authorized_origin(cx, source, guide.origin) and data.compatibility and control and control.phase == "open"
				and not data.control and (control.admitted ~= true or state == "none" or state == "previous_incarnation" or guide.rebind) then
				queue_control(cx, source, fresh_intent(cx, source, guide.origin),
					if control.admission_seq then "reconcile_session" else "admit_session", data.compatibility, true)
				notice(cx, source, guide.origin.alias_nonce, "Checking the verified connection. Retained effects stay held until their exact outcomes are reconciled.", "info")
				continue
			end
			if guide.open and current_origin(cx, source, guide.origin) then open_guide(cx, source, guide.origin)
			else publish_steps(cx, source, guide.origin, guide_steps(cx, source, guide.origin)) end
		end
	end
end
automatic_connection = function(cx: WindowCx, source: number, data: any, origin: any)
	local attempt = connection_attempts[source]
	if not attempt or attempt.nonce ~= origin.alias_nonce then
		attempt = { nonce = origin.alias_nonce, workers = {}, next_probe = 0 }; connection_attempts[source] = attempt
	end
	local continuation = data.command_result
	if attempt.continuation and continuation and continuation.request_id == attempt.continuation
		and continuation.command == "continue_controller" and continuation.ok == false and continuation.code == "stale_revision" then
		-- This exact route replacement was positively refused before writing anything.
		-- Re-evaluate the same native identity with a fresh fence; silence/unknown
		-- outcomes never clear the latch and never replay an issued operation.
		attempt.continuation = nil
		origin = fresh_intent(cx, source, origin)
	end
	-- Replacing only a verified route fences the old window. Claims and uncertain effects remain
	-- owned by their original executor and can only advance through retained-outcome reconciliation.
	if data.controller_phase ~= "active" or not current_origin(cx, source, origin) then
		local previous = if data.command_cursor then data.command_cursor.origin else nil
		if previous and not attempt.continuation and previous.owner_id == origin.owner_id and previous.owner_generation == origin.owner_generation
			and previous.host_pane_id == origin.host_pane_id and previous.alias_nonce == origin.alias_nonce
			and previous.window_key == origin.window_key and previous.native_session_id == origin.native_session_id
			and previous.window_host_id == origin.window_host_id then
			attempt.continuation = send_command(cx, source, origin, "continue_controller", {
				machine_proof = { previous_origin = previous } }, true)
			if attempt.continuation then start_guide(source, origin, false, attempt.continuation); guides[source].automatic = true end
		end
		return
	end
	if not data.compatibility or data.compatibility.kind ~= "current" then
		if not attempt.migration and not setup_ui.active(source) then
			attempt.migration = true
			setup_ui.start(cx, source, "migration_update", nil, { done = function(fresh: WindowCx, ok: boolean, message: string?)
				if not ok then notice(fresh, source, origin.alias_nonce, message or "The compatible update needs attention in Advanced. Existing work remains held.") end
			end })
		end
		return
	end
	local relay = relay_index(cx, source, "spawn")
	if relay and (relay.held or relay.error) and tern.now() >= attempt.next_probe then
		reconnect_relays(cx, source, origin)
		attempt.next_probe = tern.now() + 30000
		if not guides[source] then start_guide(source, origin, false); guides[source].automatic, guides[source].rebind = true, true end
	end
	local control = data.session_control
	if control and control.phase == "open" and control.admitted ~= true and not control_pending(source, true)
		and tern.now() >= attempt.next_probe and not guides[source] then
		attempt.next_probe = tern.now() + 30000
		start_guide(source, origin, false); guides[source].automatic = true
	end
	if not control or not control.admitted or control_pending(source) then return end
	local flow = workflow_node(cx, source, "workflow-index", "orchplus.workflow")
	if flow and type(flow.worker_ids) == "table" and not allocation_reads[source] then
		local retries = allocation_retries[source] or {}; allocation_retries[source] = retries
		for id in retries do if table.find(flow.worker_ids, id) == nil then retries[id] = nil end end
		local unresolved = false
		for _, id in flow.worker_ids do
			local worker = worker_now(cx, source, id)
			local target = if worker then worker.allocation_target else nil
			if not target then retries[id] = nil; continue end
			unresolved = true
			local retry = retries[id]
			if not retry or retry.namespace ~= data.authority_namespace or not same_policy(retry.target, target) then
				retry = { namespace = data.authority_namespace, target = target, failures = 0, next_at = 0 }; retries[id] = retry
			end
			if awake_now() >= retry.next_at then
				allocation_reads[source] = { source = source, origin = origin, worker_id = id, target = retry.target,
					namespace = data.authority_namespace, retry = retry, started = awake_now(), fact_attempts = 0 }
				break
			end
		end
		if not unresolved then allocation_notices[source] = nil end
	end
	local catalog = workflow_node(cx, source, "catalog-index", "orchplus.catalog")
	if flow and next(flow.family_migrations or {}) and (not catalog or catalog.catalog_complete ~= true)
		and picker_ui and not picker_ui.active() and not setup_ui.active(source) then
		local key = quota.digest({ scope = flow.family_migration_scope, obligations = flow.family_migrations,
			catalog_revision = if catalog then catalog.config_revision else nil })
		if attempt.family_catalog_key ~= key then
			attempt.family_catalog_key = key
			picker_ui.load(cx, source, fresh_intent(cx, source, origin), function(fresh: WindowCx, full: any, problem: any)
				if not full then notice(fresh, source, origin.alias_nonce, tostring(problem or "The complete agent catalog could not be read. Open SPAWN setup, then choose an agent again.")) end
			end)
		end
	end
	local family_key = if flow and next(flow.family_migrations or {}) and catalog and catalog.loaded and catalog.catalog_complete == true then quota.digest({
		scope = flow.family_migration_scope, obligations = flow.family_migrations, catalog_revision = catalog.config_revision }) else nil
	if attempt.family_request then
		for _, key in { "command_result", "driver_result" } do
			local receipt = data[key]
			if receipt and receipt.request_id == attempt.family_request then
				attempt.family_action = receipt.action_id
				if receipt.ok == false then attempt.family_request, attempt.family_action = nil, nil end
			end
		end
		local outcome = if attempt.family_action then snapshot(cx, source, attempt.family_action) else nil
		if outcome and outcome.result and outcome.result.action_id == attempt.family_action and outcome.result.code == "bridge_committed"
			and picker_ui and not picker_ui.active() and not setup_ui.active(source) then
			attempt.family_request, attempt.family_action = nil, nil
			picker_ui.load(cx, source, fresh_intent(cx, source, origin), function() end)
		end
	elseif family_key and attempt.family_key ~= family_key then
		attempt.family_key = family_key
		attempt.family_request = send_command(cx, source, fresh_intent(cx, source, origin), "migrate_families", {}, true)
		if attempt.family_request then start_driver(source, origin, attempt.family_request, nil, true) end
	end
	for _, id in (if flow then flow.worker_ids or {} else {}) do
		local worker = worker_now(cx, source, id)
		local previous = if worker then worker.pane_binding else nil
		if not worker or not worker.continuation_proof or not previous or not (worker.continuation_required or worker.reattach_needed) then continue end
		if retain_attachment(cx, source, origin, worker) or attempt.workers[worker.continuation_proof] then continue end
		if previous.window_key ~= origin.window_key or previous.native_session_id ~= origin.native_session_id
			or previous.window_host_id ~= origin.window_host_id then continue end
		local target = tonumber(previous.pane_id)
		local pane = if target then scoped_pane(cx, target, origin) else nil
		local terminal = worker.backend == "local-terminal"
		local native = if target and not terminal then agent_of(cx, target) else nil
		local eligible_native = native and (native.state == "idle" or native.state == "working" or native.state == "waiting_input")
		local eligible_terminal = terminal and pane and (pane.kind == "terminal" or pane.kind == "agent") and pane.exited == nil and pane.at_prompt ~= true
		if not pane or (not eligible_native and not eligible_terminal) then continue end
		local binding = pane_binding(target :: number, origin)
		local request = send_command(cx, source, fresh_intent(cx, source, origin), "continue_worker", {
			worker_id = id, pane_binding = binding, continuation_proof = worker.continuation_proof,
			machine_proof = { previous_pane_binding = previous } }, true)
		if request then
			attempt.workers[worker.continuation_proof] = request
		end
		break
	end
end
-- Observe the exact fenced request or its immutable mailbox-allocation target, then submit the
-- existing owner withdrawal. Missing/unknown observations never release work or replay startup.
local function submit_withdrawal(cx: WindowCx, source: number, probe: any, proof: any?)
	local fields = proof or { worker_id = probe.worker_id }
	local sent, id = pcall(send_command, cx, source, probe.origin, "cancel_work", fields, true)
	if sent and id then probe.command, probe.sent_at = id, awake_now()
	else
		withdrawals[source] = nil
		if not sent then notice(cx, source, probe.origin.alias_nonce, "Cancellation submission was not confirmed. Inspect retained work; no request was repeated.") end
	end
end

local function withdraw_step(cx: WindowCx)
	for source, probe in withdrawals do
		if not native_scope.authorized_origin(cx, source, probe.origin) then
			withdrawals[source] = nil
			notice(cx, source, probe.origin.alias_nonce, if probe.command then "The cancellation result is not confirmed after the connection changed. Inspect retained work; nothing was retried."
				else "The cancellation check lost its source connection. No cancellation was issued; work stays held.")
			continue
		end
		if probe.command then
			local data = snapshot(cx, source)
			local result
			for _, key in { "command_result", "driver_result", "result" } do
				local candidate = if data then data[key] else nil
				if candidate and candidate.request_id == probe.command then result = candidate; break end
			end
			if result then
				withdrawals[source] = nil
				if probe.bridge then relay_ack(cx, probe.bridge, "response") end
				if result.ok and result.action_id then
					start_driver(source, probe.origin, probe.command, probe.worker_id, true)
					local driver = drivers[source]
					if not driver.scope and not driver.action_id and not driver.delivery then driver.scope = result.action_id
					elseif driver.scope ~= result.action_id then driver.next_scope = result.action_id end
				elseif not result.ok then notice(cx, source, probe.origin.alias_nonce, tostring(result.message or "The cancellation was refused. Work remains retained.")) end
			elseif awake_now() - probe.sent_at > 30000 then
				withdrawals[source] = nil
				notice(cx, source, probe.origin.alias_nonce, "The cancellation result is not confirmed. Inspect retained work before another decision; it was not retried.")
			end
			continue
		end
		if probe.fenced.status_required and probe.fenced.allocation_target then
			local worker = worker_now(cx, source, probe.worker_id)
			local target = probe.fenced.allocation_target
			if not worker or worker.worker_generation ~= target.worker_generation or worker.work_id ~= target.work_id then
				withdrawals[source] = nil
				notice(cx, source, probe.origin.alias_nonce, "The selected work generation changed. No cancellation was issued.")
				continue
			end
			-- Allocation is a separate fact, not proof the original uncertain provision did
			-- not execute. Let automatic recovery commit it before reading original status.
			if worker.allocation_target then
				if awake_now() - probe.started > 60000 then
					withdrawals[source] = nil
					notice(cx, source, probe.origin.alias_nonce, "Automatic recovery has not confirmed this work's exact allocation. Work stays held; no cancellation was issued.")
				end
				continue
			end
			if type(worker.withdrawal) ~= "table" then
				withdrawals[source] = nil
				notice(cx, source, probe.origin.alias_nonce, "This work is no longer eligible for cancellation. No cancellation was issued.")
				continue
			end
			probe.fenced, probe.started = worker.withdrawal, awake_now()
			probe.origin = fresh_intent(cx, source, probe.origin)
			if not probe.fenced.status_required and not probe.fenced.allocation_target then
				submit_withdrawal(cx, source, probe, nil)
				continue
			end
		end
		if probe.query == nil then
			if probe.fenced.allocation_target then
				catalog_query(cx, source, probe, guides[source], "mailbox_allocation", probe.origin, probe.origin.owner_generation, nil, nil, probe.fenced.allocation_target)
			else catalog_query(cx, source, probe, guides[source], "status", probe.fenced.origin_binding, probe.fenced.controller_generation, probe.fenced.request_id, probe.fenced.request_serial) end
		else
			local _, bytes = peer_surface(cx, probe.bridge, "spawn.dispatch", "spawn.dispatch.response")
			local body = if bytes then dispatch.decode_response(bytes, probe.query) else nil
			if body and body.status ~= "pending" then
				if probe.query.op == "mailbox_allocation" and body.status ~= "allocation" then
					withdrawals[source] = nil; relay_ack(cx, probe.bridge, "response")
					notice(cx, source, probe.origin.alias_nonce, "SPAWN could not confirm this work's exact mailbox allocation. Work remains held; nothing was deleted, reprovisioned or launched.")
					continue
				end
				submit_withdrawal(cx, source, probe, {
					worker_id = probe.worker_id, query_bytes = tern.json.encode(probe.query), response_bytes = bytes })
				continue
			end
		end
		if awake_now() - probe.started > 10000 then
			withdrawals[source] = nil
			notice(cx, source, probe.origin.alias_nonce, "SPAWN did not confirm the cancellation observation within 10 seconds. Work stays held; no cancellation was issued.")
		end
	end
end
local function allocation_hold(cx: WindowCx, source: number, job: any, code: string)
	job.retry.failures = math.min(job.retry.failures + 1, #AUTO_RECONCILE_DELAYS)
	job.retry.next_at = awake_now() + AUTO_RECONCILE_DELAYS[job.retry.failures]
	allocation_reads[source] = nil
	if job.bridge and job.response_bytes then relay_ack(cx, job.bridge, "response") end
	local notes = allocation_notices[source] or {}; allocation_notices[source] = notes
	if not notes.warned then
		notes.warned = true
		if code ~= "native_read_failed" then notice(cx, source, job.origin.alias_nonce, "Agent communication resources remain unconfirmed. Work stays held while read-only checks continue; Advanced shows the retained startup failure.", "info") end
	end
	if code == "native_read_failed" then notes.native_error = true end
end
local function allocation_step(cx: WindowCx)
	for source, job in allocation_reads do
		if not native_scope.authorized_origin(cx, source, job.origin) then continue end
		local data, worker = snapshot(cx, source), worker_now(cx, source, job.worker_id)
		if worker and worker.allocation_target == nil then
			if job.bridge and job.response_bytes then relay_ack(cx, job.bridge, "response") end
			allocation_reads[source] = nil
			continue
		end
		if not data or data.authority_namespace ~= job.namespace or not worker or not same_policy(worker.allocation_target, job.target) then allocation_hold(cx, source, job, "source_changed"); continue end
		if job.command then
			local result = data.allocation_result
			if result and result.request_id == job.command then
				if result.ok then
					allocation_reads[source] = nil; job.retry.failures, job.retry.next_at = 0, 0
					if job.bridge then relay_ack(cx, job.bridge, "response") end
				elseif result.code == "stale_revision" and job.fact_attempts < 3 then job.command = nil
				else allocation_hold(cx, source, job, "fact_refused") end
			elseif awake_now() - job.sent_at > 30000 then allocation_hold(cx, source, job, "fact_unconfirmed") end
			continue
		end
		if not data.session_control or not data.session_control.admitted or data.controller_phase ~= "active" or data.control then
			if awake_now() - job.started > 10000 then allocation_hold(cx, source, job, "connection_pending") end
			continue
		end
		if job.response_bytes then
			if control_pending(source) then continue end
			job.fact_attempts += 1
			local sent, id = pcall(send_command, cx, source, fresh_intent(cx, source, job.origin), "observe_allocation",
				{ worker_id = job.worker_id, query_bytes = job.query_json, response_bytes = job.response_bytes })
			if sent and id then job.command, job.sent_at = id, awake_now() else allocation_hold(cx, source, job, "fact_unconfirmed") end
			continue
		end
		local bridge = job.bridge or acquire_bridge(cx, source, job.origin, "allocation")
		if bridge then
			job.bridge = bridge
			local node, bytes = peer_surface(cx, bridge, "spawn.dispatch", "spawn.dispatch.response")
			if not job.query then
				if node then job.query, job.query_json = send_query(cx, bridge, node, source, "mailbox_allocation",
					job.origin, job.origin.owner_generation, nil, nil, job.target) end
			else
				local body = if bytes then dispatch.decode_response(bytes, job.query) else nil
				if body and body.status == "allocation" then
					job.response_bytes = bytes
				elseif body and body.status ~= "pending" and not (body.error and body.error.code == "allocation_pending") then
					relay_ack(cx, bridge, "response"); allocation_hold(cx, source, job, "allocation_unknown"); continue
				end
			end
		end
		if not job.response_bytes and awake_now() - job.started > 10000 then allocation_hold(cx, source, job, "allocation_pending") end
	end
end
local driver_turn = 0
local readiness_ui: any
local function send_ruling(cx: WindowCx, job: any, command: string, extra: any?)
	if not current_origin(cx, job.source, job.origin) then return false end
	local fence = intent_fences[job.origin]
	local data = snapshot(cx, job.source)
	if not fence or not data then return false end
	local retained = command_cursors[job.source]
	local seq = math.max(if retained then retained.seq else 0, if data.command_cursor then data.command_cursor.seq else 0) + 1
	command_cursors[job.source] = { origin = job.origin, seq = seq }
	local request = { command = command, request_id = dispatch_id(), source_nonce = job.origin.alias_nonce, origin = job.origin,
		authority_namespace = fence.authority_namespace, expected_revision = fence.expected_revision, command_seq = seq,
		gate_id = job.gate_id, gate_revision = job.gate_revision, writer = job.writer, previous_writer = job.previous_writer,
		operator_verified = job.verified == true, remote_buffer_attested = job.remote_buffer_attested == true,
		writer_ended_verified = job.writer_ended_verified == true, no_late_write_verified = job.no_late_write_verified == true,
		same_machine = cx.hosts:current().kind ~= "remote" }
	for key, value in extra or {} do request[key] = value end
	local bytes = tern.json.encode(request)
	if #bytes > codec.LIMITS.logical then
		notice(cx, job.source, job.origin.alias_nonce, "Native document observation exceeds the bounded envelope; the exact owner obligation remains pending.")
		return false
	end
	job.request_id = request.request_id; job.waiting = command
	cx.session:event(job.source, { ev = "action", id = "main", act = "ruling-command", value = bytes })
	return true
end
local function ruling_buffer(cx: WindowCx, job: any, command: string)
	if job.writer and job.writer.kind == "worker" then
		-- This is a labelled owner attestation about the remote participating writer, never a
		-- fabricated local Docs observation. The host independently reads the actual disk.
		send_ruling(cx, job, command, { remote_buffer_attested = job.remote_buffer_attested == true })
		return
	end
	job.reading = true
	cx.docs:read(job.path):next(function(bytes: string?, why: string?, fresh: WindowCx?)
		job.reading = nil
		if not fresh or ruling_jobs[job.source] ~= job or not current_origin(fresh, job.source, job.origin) then return end
		if why or type(bytes) ~= "string" then
			notice(fresh, job.source, job.origin.alias_nonce, "Existing native document could not be read; no write or confirmation occurred.")
			ruling_jobs[job.source] = nil; return
		end
		job.buffer = bytes
		send_ruling(fresh, job, command, { buffer_bytes = bytes, buffer_observed = true })
	end)
end
local function execute_ruling(cx: WindowCx, job: any, edit: any)
	-- Intent is already durable. One invocation only, even when edit/readback callbacks are lost.
	if job.edit_started then return end
	job.edit_started = true
	local function inspect_again(fresh: WindowCx, message: string?)
		if message then notice(fresh, job.source, job.origin.alias_nonce, message .. " No append was repeated.") end
		job.phase = "observe"; job.origin = fresh_intent(fresh, job.source, job.origin)
		ruling_buffer(fresh, job, "ruling_observe")
	end
	cx.docs:read(job.path):next(function(bytes: string?, why: string?, fresh: WindowCx?)
		if not fresh or ruling_jobs[job.source] ~= job or not current_origin(fresh, job.source, job.origin) then return end
		if why or type(bytes) ~= "string" or codec.sha256(bytes) ~= edit.expected_document_sha256 then
			job.phase = "observe"; job.origin = fresh_intent(fresh, job.source, job.origin)
			ruling_buffer(fresh, job, "ruling_observe"); return
		end
		local gate = workflow_node(fresh, job.source, "workflow-gate-" .. job.gate_id, "orchplus.gate")
		local intent = if gate and gate.ruling then gate.ruling.intent else nil
		if not intent or not same_policy(intent.writer, job.writer) or intent.expected_document_sha256 ~= edit.expected_document_sha256 then
			ruling_jobs[job.source] = nil
			notice(fresh, job.source, job.origin.alias_nonce, "Ruling intent changed before native edit; the captured write was not used.")
			return
		end
		fresh.docs:search(job.path, gate.ruling.marker):next(function(matches: any, search_error: string?, searched: WindowCx?)
			if not searched or ruling_jobs[job.source] ~= job then return end
			if search_error or type(matches) ~= "table" or #matches ~= 0 then
				inspect_again(searched, "Marker search changed or could not prove exact absence."); return
			end
			searched.docs:read(job.path):next(function(latest: string?, read_error: string?, ready: WindowCx?)
			if not ready or ruling_jobs[job.source] ~= job or not current_origin(ready, job.source, job.origin) then return end
			if read_error or latest ~= bytes then inspect_again(ready, "Document changed during native search."); return end
			local offset = edit.offset
			if type(offset) ~= "number" or offset < 0 or offset > #bytes or offset % 1 ~= 0 then
				ruling_jobs[job.source] = nil
				notice(ready, job.source, job.origin.alias_nonce, "Native edit offset is invalid; keep the exact pending ruling for review.")
				return
			end
			local _, lines = bytes:sub(1, offset):gsub("\n", "")
			local line = lines + 1
			if offset == #bytes and #bytes > 0 and bytes:sub(-1) ~= "\n" then line += 1 end
			-- An existing block's offset was parsed outside fences by the authority; target its
			-- exact line, never the first literal closing marker (which could be an example).
			if offset < #bytes and (offset > 0 and bytes:sub(offset, offset) ~= "\n") then
				ruling_jobs[job.source] = nil
				notice(ready, job.source, job.origin.alias_nonce, "Native edit is not at a parsed line boundary; keep the exact pending ruling for review.")
				return
			end
			ready.docs:edit(job.path, { line = line, insert = edit.text }):next(function(_range: any, edit_error: string?, after: WindowCx?)
				if not after or ruling_jobs[job.source] ~= job then return end
				if edit_error then notice(after, job.source, job.origin.alias_nonce, "Native write is unresolved: " .. tostring(edit_error) .. ". Inspect buffer and disk; no automatic append retry.") end
				job.phase = "observe"; job.origin = fresh_intent(after, job.source, job.origin)
				ruling_buffer(after, job, "ruling_observe")
			end)
			end)
		end)
	end)
end
local function ruling_tick(cx: WindowCx)
	for source, job in ruling_jobs do
		if not current_origin(cx, source, job.origin) then ruling_jobs[source] = nil; continue end
		local response = workflow_node(cx, source, "ruling-result", "orchplus.ruling.result")
		if response and response.request_id == job.request_id and job.waiting then
			local command = job.waiting; job.waiting = nil
			cx.session:event(source, { ev = "action", id = "main", act = "ruling-clear",
				value = tern.json.encode({ source_nonce = job.origin.alias_nonce, request_id = job.request_id }) })
			if response.ok ~= true then
				notice(cx, source, job.origin.alias_nonce, tostring(response.message or response.code))
				if command == "ruling_observe" and response.code == "stale_revision"
					and job.mode == "write" and job.phase == "observe" and job.edit_started
					and job.writer and job.writer.kind == "window" then
					-- Only the original local writer's post-write read was refused.
					-- Keep its ordinary observation cadence; never repeat prepare/edit
					-- or reuse an ended/remote writer attestation as fresh evidence.
					job.next_at = tern.now() + 5000
				else ruling_jobs[source] = nil end
				continue
			end
			if command == "ruling_inspect" then
				job.writer = job.writer or response.writer; job.path = response.path
				ruling_buffer(cx, job, if job.mode == "observe" then "ruling_observe" elseif job.mode == "reissue" then "ruling_reissue" else "ruling_prepare")
			elseif command == "ruling_prepare" then
				if not response.edit then ruling_jobs[source] = nil; continue end
				if job.writer.kind == "worker" then
					job.origin = fresh_intent(cx, source, job.origin)
					send_ruling(cx, job, "ruling_remote")
				else execute_ruling(cx, job, response.edit) end
			elseif command == "ruling_observe" or command == "ruling_remote" then
				local gate = workflow_node(cx, source, "workflow-gate-" .. job.gate_id, "orchplus.gate")
				if job.writer.kind == "worker" then
					ruling_jobs[source] = nil
					if gate and gate.ruling then notice(cx, source, job.origin.alias_nonce,
						"Remote ruling remains pending. After the writer finishes, freshly verify its participating buffer and choose Observe durable ruling. The original buffer attestation is never reused.", "info") end
				elseif not gate or not gate.ruling then ruling_jobs[source] = nil
				else job.phase = "observe"; job.next_at = tern.now() + 5000 end
			else
				-- Reissue only cleared the ended writer intent; a new owner click creates a new write.
				ruling_jobs[source] = nil
			end
		elseif job.phase == "observe" and not job.waiting and not job.reading and tern.now() >= (job.next_at or 0) then
			job.origin = fresh_intent(cx, source, job.origin)
			ruling_buffer(cx, job, "ruling_observe")
		end
	end
end
-- An owner's "refresh capacity" is only reported as done once the host has answered the exact
-- capacity command it sent: the toast follows the host's receipt, never the send.
native_scope.capacity_confirms = {}
-- One waiting refresh: it ends here with exactly one visible outcome, or stays waiting.
function native_scope.capacity_confirm_one(cx: WindowCx, source: number, wait: any)
	if not native_scope.authorized_origin(cx, source, wait.origin) then
		native_scope.capacity_confirms[source] = nil
		cx:toast("error", "ORCH+ quota evidence", "Capacity evidence was sent, but this window could not confirm the host's answer ("
			.. native_scope.authority_gap(cx, source, wait.origin) .. "). Check the result before refreshing again.")
		return
	end
	local data = snapshot(cx, source)
	local result
	-- capacity_result is the refresh's own receipt; the others stay as fallbacks for an older host.
	for _, key in { "capacity_result", "command_result", "driver_result", "result" } do
		local candidate = if data then data[key] else nil
		if candidate and candidate.request_id == wait.request_id then result = candidate; break end
	end
	if result then
		native_scope.capacity_confirms[source] = nil
		if result.ok then cx:toast("info", "ORCH+ quota evidence", "USAGE capacity evidence refreshed and validated.")
		else cx:toast("error", "ORCH+ quota evidence", "Capacity evidence was not recorded: " .. tostring(result.message or result.code) .. " Nothing changed.") end
	elseif awake_now() - wait.sent_at > 30000 then
		native_scope.capacity_confirms[source] = nil
		cx:toast("error", "ORCH+ quota evidence", "The host has not confirmed the capacity evidence. Refresh again.")
	end
end
-- An error while checking one waiting refresh ends that refresh with a notice; every other one keeps waiting.
function native_scope.capacity_confirm_step(cx: WindowCx)
	for source, wait in native_scope.capacity_confirms do
		local ok, failure = pcall(native_scope.capacity_confirm_one, cx, source, wait)
		if not ok then
			-- Remove the entry before reporting it: a report that raises must neither keep the entry nor skip the others.
			native_scope.capacity_confirms[source] = nil
			pcall(function()
				cx:toast("error", "ORCH+ quota evidence", "Capacity evidence was sent, but this window could not confirm the host's answer ("
					.. tostring(failure):sub(1, 200) .. "). Check the result before refreshing again.")
			end)
		end
	end
end
local function arm()
	if timer ~= nil then return end
	timer = tern.timer(TICK_MS, function(fresh: WindowCx?)
		timer = nil
		observe_tick() -- Before any deadline check in this turn.
		arm() -- Rearm before work so an unexpected native-context failure cannot kill observation.
		if fresh ~= nil then
			-- Clicked window-side controls first: each published intent runs at most once here.
			if setup_api.migration_tick then setup_api.migration_tick(fresh) end
			forms_ui.tick(fresh)
			if work_tick then work_tick(fresh) end
			cleanup_tick(fresh)
			setup_ui.tick(fresh)
			if readiness_ui then readiness_ui.tick(fresh) end
			if picker_ui then picker_ui.tick(fresh) end
			if source_ui then source_ui.tick(fresh) end
			if conversation_ui then conversation_ui.tick(fresh) end
			for source, save in setup_api.saves or {} do
				local data = snapshot(fresh, source)
				local result = if data then data.command_result else nil
				if result and result.request_id == save.request_id then
					setup_api.saves[source] = nil
					local flow = workflow_node(fresh, source, "workflow-index", "orchplus.workflow")
					local reply = table.clone(result)
					if flow then reply.policy_revision, reply.policy_sha256 = flow.policy_revision, flow.policy_sha256 end
					save.done(fresh, reply)
				elseif not current_origin(fresh, source, save.origin) then
					setup_api.saves[source] = nil
					save.done(fresh, { ok = false, code = "save_context_changed", message = "The connection changed before the save result was confirmed. Your draft is retained; inspect current settings before another save." })
				elseif awake_now() - save.started > 30000 then
					setup_api.saves[source] = nil
					save.done(fresh, { ok = false, code = "save_unconfirmed", message = "The save result was not confirmed within 30 seconds. Your draft is retained; no save was retried." })
				end
			end
			ruling_tick(fresh)
			pcall(consume_intents, fresh)
			local scheduled, failure = pcall(schedule, fresh)
			if next(allocation_reads) ~= nil then
				local observed, problem = pcall(allocation_step, fresh)
				if not observed then
					for source, job in allocation_reads do
						if not allocation_notices[source] or not allocation_notices[source].native_error then fresh:toast("error", "ORCH+ resource observation",
							"Read-only observation failed; existing work is retained: " .. tostring(problem):sub(1, 200)) end
						allocation_hold(fresh, source, job, "native_read_failed")
					end
				end
			end
			if not scheduled then
				-- Keep the loop alive without toast storms; a fresh attached view exposes the hold.
				for _, driver in drivers do
					if native_scope.authorized_origin(fresh, driver.source, driver.origin) then
						local _, node = snapshot(fresh, driver.source)
						if node then fresh.session:event(driver.source, { ev = "action", id = node.id, act = "dispatch-notice",
							value = tern.json.encode({ source_nonce = driver.origin.alias_nonce, level = "error", message = "Workflow observation unavailable: " .. tostring(failure):sub(1, 700) }) }) end
					end
				end
			end
			local pending = {}
			for _, driver in drivers do table.insert(pending, driver) end
			table.sort(pending, function(a, b) return tostring(a.key or a.source) < tostring(b.key or b.source) end)
			for _ = 1, math.min(4, #pending) do
				driver_turn = driver_turn % #pending + 1
				local driver = pending[driver_turn]
				local ok = pcall(advance, fresh, driver)
				if not ok then
					if native_scope.authorized_origin(fresh, driver.source, driver.origin) and driver.action_id then
						send_command(fresh, driver.source, fresh_intent(fresh, driver.source, driver.origin), "lost", { action_id = driver.action_id, executor = driver.claim_executor or incarnation, grant_id = driver.grant_id })
					end
					drop(driver)
					fresh:toast("error", "ORCH+ effect uncertain", "Native bridge operation failed; its durable claim is retained for reconciliation, never repeated.")
				end
			end
			-- USAGE capacity readers: one bounded native read/verify step per source per tick.
			local active = {}
			for _, reader in readers do table.insert(active, reader) end
			for _, reader in active do
				local ok, failure = pcall(reader_step, fresh, reader)
				if not ok then
					readers[reader.source] = nil
					fresh:toast("error", "ORCH+ quota evidence", "USAGE capacity read failed: " .. tostring(failure):sub(1, 300) .. ". Quota-routed work stays held.")
				end
			end
			-- Guided reload recovery: at most one read-only owner_status probe step per controller.
			if next(guides) ~= nil and not pcall(probe_step, fresh) then table.clear(guides) end
			-- Fenced-work withdrawal: at most one read-only status step per controller.
			if next(withdrawals) ~= nil and not pcall(withdraw_step, fresh) then table.clear(withdrawals) end
			if next(native_scope.capacity_confirms) ~= nil then pcall(native_scope.capacity_confirm_step, fresh) end
			relay_maintenance(fresh)
			pcall(idle_wake.keep, fresh) -- Last: this turn's schedule decides whether timed work remains.
		end
	end)
end
-- `owner`: the owner chose this command, so its host refusal is noticed with the reason.
start_driver = function(source: number, origin: any, request_id: string, worker_id: string?, owner: boolean?)
	local driver = drivers[source]
	-- An automatic read that has not captured a grant yields to the owner's command.
	if driver == nil or (driver.auto and not driver.action_id and not driver.delivery) then driver = { source = source, origin = origin } end
	driver.command_request_id = request_id
	driver.owner_command = owner == true
	if worker_id and not driver.action_id and not driver.delivery then driver.worker_id = worker_id end
	drivers[source] = driver; arm() -- Never discard a live action's captured delivery/grant.
end
-- USAGE capacity consumer: reads only USAGE's public, owner-enabled `usage.capacity` block with
-- bounded, correlated requests; every page of one revision is assembled and verified (length +
-- SHA-256) before parsing, then validated by USAGE before the host records the evidence.
local next_refresh: any = {}
local reader_notices: any = {}
local function reader_done(cx: WindowCx, reader: any, ok: boolean, message: string?)
	if readers[reader.source] == reader then readers[reader.source] = nil end
	if not ok then
		next_refresh[reader.source] = tern.now() + 30000
		-- An owner's click always ends in a visible outcome, even when the same failure was already shown.
		if reader.owner and not message then
			notice(cx, reader.source, reader.origin.alias_nonce, "Capacity refresh was not sent. Nothing was recorded; try again.")
		elseif message and (reader.owner or reader_notices[reader.source] ~= message) then
			reader_notices[reader.source] = message
			notice(cx, reader.source, reader.origin.alias_nonce, message)
		end
	else
		reader_notices[reader.source] = nil
		if reader.owner and not reader.capacity_request then
			notice(cx, reader.source, reader.origin.alias_nonce, reader.capacity_refusal
				or "A capacity check that was already running finished without recording evidence. Refresh again to record it.")
		end
	end
	local after = reader.after
	reader.after = nil
	for _, fn in after or {} do pcall(fn, cx, ok, reader.capacity_request) end
end
local HINTS = {
	export_disabled = " Enable the read-only capacity export in USAGE Setup.",
	export_revoked = " The USAGE owner revoked the capacity export or its authorization changed.",
	companion_unavailable = " Open USAGE Setup to prepare its companion.",
}
start_reader = function(source: number, origin: any, mode: string, revision: string?, after: any?)
	local reader = readers[source]
	if reader == nil then
		-- Automatic refreshes back off after a failure; explicit owner/validate requests do not.
		if mode == "snapshot" and after == nil and tern.now() < (next_refresh[source] or 0) then return end
		reader = { source = source, origin = origin, mode = mode, revision = revision, after = {} }
		readers[source] = reader
		if mode == "snapshot" then next_refresh[source] = tern.now() + 30000 end
	end
	if after then table.insert(reader.after, after) end
	arm()
end
reader_step = function(cx: WindowCx, reader: any)
	local source, origin = reader.source, reader.origin
	local function unverified(problem: any) reader_done(cx, reader, false, "USAGE capacity " .. problem.code .. ": " .. problem.message .. " No evidence was used.") end
	if not native_scope.authorized_origin(cx, source, origin) then
		-- Only the owner's own click is told why; an automatic refresh ends quietly as before.
		reader_done(cx, reader, false, if reader.owner then "Capacity refresh was not sent: this window cannot act as the controller ("
			.. native_scope.authority_gap(cx, source, origin) .. "). Continue the controller in this window, then try again." else nil)
		return
	end
	local pane = reader.pane or usage_by_source[source]
	if not pane then
		pane = acquire_usage(cx, source, origin)
		if not pane then reader_done(cx, reader, false, "Usage is not connected. Enable its read-only capacity export; quota-routed work remains held."); return end
	end
	reader.pane = pane
	if not relay_live(cx, pane) then
		reader_done(cx, reader, false, "The exact usage connection changed. No stale evidence was accepted.")
		return
	end
	local node, text = peer_surface(cx, pane, quota.BLOCK, quota.NODE, quota.NODE, quota.MAX_RESPONSE_CHARS)
	if pane.peer_changed then
		reader.mode, reader.request, reader.assembly, reader.document = "snapshot", nil, nil, nil
		pane.peer_boot, pane.peer_changed = nil, nil
		return -- Fresh causal snapshot; never mix pages or validation across helper incarnations.
	end
	if not node then
		reader.absent = (reader.absent or 0) + 1
		if reader.absent > 20 then reader_done(cx, reader, false, "USAGE capacity surface is missing, clipped or incompatible (USAGE_CAPACITY v1 required); quota-routed work stays held.") end
		return
	end
	reader.absent = 0
	-- Hash delivered pages incrementally, one bounded step per tick, so no 50 ms callback hashes the
	-- whole document; an interrupted step fails closed.
	local assembly = reader.assembly
	if assembly ~= nil and reader.document == nil then
		local _, hash_failure = quota.hash_step(assembly)
		if hash_failure then unverified(hash_failure); return end
	end
	local pending = reader.request
	if pending == nil then
		local op, revision, cursor
		if reader.mode == "validate" then op = "validate"; revision = reader.revision
		elseif assembly == nil then op = "snapshot"
		elseif not assembly.complete then op = "page"; revision = assembly.revision; cursor = assembly.next_cursor
		elseif reader.document == nil then
			-- Every page is in: verify once the incremental hash has caught up, then validate next tick.
			if not assembly.hashed then return end
			local document, failure = quota.finish(assembly)
			if not document then unverified(failure); return end
			reader.document = document
			return
		else op = "validate"; revision = assembly.revision end
		local request_id = dispatch_id()
		local bytes = quota.request(op, request_id, revision, cursor)
		if not bytes then reader_done(cx, reader, false, "Could not form a bounded USAGE capacity request."); return end
		reader.request = { request_id = request_id, op = op, revision = revision, bytes = bytes, sent = tern.now(), resent = 0 }
		if not relay_event(cx, pane, { act = quota.ACTION, value = bytes }) then reader_done(cx, reader, false, "The current usage connection changed; no evidence was accepted.") end
		return
	end
	if text == nil then
		if tern.now() - pending.sent > 30000 then reader_done(cx, reader, false, "Usage did not answer within 30 seconds. Quota-routed work remains held.") end
		return
	end
	local response, problem = quota.decode_response_json(text, pending)
	if response == nil then
		if problem.code == "pending" or problem.code == "uncorrelated" then
			local waited = tern.now() - pending.sent
			-- USAGE ignores events while busy with another reader; resend the same idempotent read.
			if problem.code == "uncorrelated" and waited > 5000 * (pending.resent + 1) and pending.resent < 3 then
				pending.resent += 1
				relay_event(cx, pane, { act = quota.ACTION, value = pending.bytes })
			elseif waited > 30000 then
				reader_done(cx, reader, false, "USAGE capacity did not answer within 30 s; quota-routed work stays held.")
			end
			return
		end
		relay_ack(cx, pane, "capacity") -- Correlated refusal is consumed, not evidence of capacity.
		if reader.mode == "validate" then
			-- The decision's revision is no longer current: refresh, never launch on it.
			reader.mode = "snapshot"; reader.request = nil; reader.assembly = nil; reader.document = nil
			return
		end
		reader_done(cx, reader, false, "USAGE capacity " .. problem.code .. ": " .. tostring(problem.message) .. (HINTS[problem.code] or "") .. " Quota-routed work stays held.")
		return
	end
	relay_ack(cx, pane, "capacity")
	reader.request = nil
	if pending.op == "snapshot" or pending.op == "page" then
		local ok, err
		if pending.op == "snapshot" then reader.assembly, err = quota.assembly(response); ok = reader.assembly ~= nil
		else ok, err = quota.add_page(reader.assembly, response) end
		if not ok then unverified(err); return end
		return -- Hashing and verification continue on later ticks.
	end
	-- A snapshot validates only a verified, parsed document; anything else fails closed (retryable).
	if reader.mode ~= "validate" and reader.document == nil then
		reader_done(cx, reader, false, "USAGE capacity document was not verified before validation; no evidence was used. Quota-routed work stays held.")
		return
	end
	local validation = { revision = response.revision, auth_revision = response.auth_revision, status = response.status,
		validated_at_ms = response.validated_at_ms, expires_at_ms = response.expires_at_ms }
	validations[source] = { revision = response.revision, value = validation, at = tern.now() }
	if reader.mode == "validate" then reader_done(cx, reader, true); return end
	local index = routing_index(cx, source)
	if not index or type(index.namespace) ~= "string" or type(index.host_key) ~= "string" or type(index.config_revision) ~= "number" then
		reader_done(cx, reader, false, "Load the SPAWN catalog before quota routing; USAGE evidence binds to its exact namespace/host/config revision.")
		return
	end
	local a = reader.assembly
	local evidence = quota.normalize(reader.document, { revision = a.revision, auth_revision = a.auth_revision, issued_at_ms = a.issued_at_ms,
		expires_at_ms = a.expires_at_ms, validation = validation }, index, math.floor(os.time() * 1000))
	-- The command must fit the 8192-byte bridge; lowest-priority records drop to "not in evidence".
	while #tern.json.encode(evidence) > 6500 and #evidence.records > 0 do table.remove(evidence.records) end
	-- An owner-requested refresh sends as an owner command so the host's answer is readable here.
	local request_id, why, emitted
	if reader.owner == true then request_id, why, emitted = native_scope.send_returning(cx, source, fresh_intent(cx, source, origin), "capacity", { capacity = evidence }, true)
	else request_id, why, emitted = send_command(cx, source, fresh_intent(cx, source, origin), "capacity", { capacity = evidence }, false) end
	reader.capacity_request = request_id
	if not request_id and why then reader.capacity_refusal = if emitted then why else "Capacity evidence was not sent: " .. why end
	reader_done(cx, reader, true)
end
local function current_gate(cx: WindowCx, source: number, request: any): any?
	if type(request.gate_id) ~= "string" then return nil end
	local gate = workflow_node(cx, source, "workflow-gate-" .. request.gate_id, "orchplus.gate")
	if not gate or gate.id ~= request.gate_id or gate.revision ~= request.gate_revision
		or (request.decision_context ~= nil and gate.decision_context ~= request.decision_context) then return nil end
	local worker = worker_now(cx, source, gate.worker_id)
	return if worker and worker.worker_generation == gate.worker_generation then gate else nil
end
local function landing_now(cx: WindowCx, source: number, request: any): any?
	if type(request.landing_id) ~= "string" then return nil end
	local item = workflow_node(cx, source, "workflow-landing-" .. request.landing_id, "orchplus.landing")
	if not item or item.id ~= request.landing_id or item.revision ~= request.landing_revision then return nil end
	return item
end
local function inspect_worker(cx: WindowCx, source: number, origin: any, worker_id: string, reveal: boolean)
	local worker = worker_now(cx, source, worker_id)
	if not worker then notice(cx, source, origin.alias_nonce, "Worker projection unavailable. No pane was guessed."); return end
	local native, problem, pane, delivery_error = native_observation(cx, source, worker)
	if worker.pane_binding and worker.origin_binding and current_origin(cx, source, worker.origin_binding) then
		send_command(cx, source, origin, "observe", { worker_id = worker_id, pane_binding = worker.pane_binding, native_state = native, delivery_error = delivery_error })
	end
	if reveal and pane then
		-- Explicit owner click, restricted to the durably authorized current session.
		if pane.parked then
			local ok = cx.layout:unpark(pane.pane)
			if not ok then notice(cx, source, origin.alias_nonce, "Exact relevant pane could not be unparked. No other pane was selected."); return end
		end
		cx.layout:focus(pane.pane)
	end
	local message = if native == "exited" then "Agent pane ended"
		.. (if pane and pane.exited ~= nil then " (exit " .. tostring(pane.exited) .. ")" else "")
		.. ". Open the pane to read its output. Its launch and any unread messages remain retained."
		elseif native == "unknown" then "Agent status is not confirmed. A missing pane does not prove it stopped."
		elseif native == "waiting-input" then "The agent is waiting for input. Open its pane to respond."
		elseif native == "working" then "The agent is working." else "The agent pane is idle."
	cx:toast(if delivery_error or (native == "exited" and (not pane or pane.exited ~= 0)) then "error" else "info", "ORCH+ agent status", message)
end
agent_of = function(cx: WindowCx, pane: number): any?
	for _, agent in cx.agents:list() do if agent.pane == pane then return agent end end
	return nil
end
-- A pane (not a block, not the controller) on the origin's exact connected host and native session.
local function origin_pane(cx: WindowCx, source: number, target: number, origin: any): any?
	local pane = if target ~= source then scoped_pane(cx, target, origin) else nil
	return if pane and pane.block == nil then pane else nil
end
pane_binding = function(target: number, origin: any): any
	return { pane_id = tostring(target), window_key = origin.window_key, window_epoch = origin.window_epoch,
		native_session_id = origin.native_session_id, window_host_id = origin.window_host_id }
end
setup_api.work_status = function(cx: WindowCx, _source: number): (string, boolean)
	for _, block in cx.session:block_types() do if block.kind == "tern-work.panel" then return "WORK is available. Its own pane checks the Glitch root when you select work.", true end end
	return "Requires WORK plugin on this execution host. Neutral operation does not require it.", false
end
setup_api.install_work = function(cx: WindowCx, source: number, origin: any)
	for _, action in cx.actions:list() do
		if action.id == "plugin.tern-work.check_updates" and action.available then cx:action(action.id); return end
	end
	local command = "tern plugin install github.com/blastworksai/tools/plugins/tern/WORK --json"
	forms_ui.open(cx, source, origin, { title = "Install WORK on the execution host",
		description = "WORK is optional with Glitch off. Run this command on the host containing your Glitch registry, then reopen WORK ON. This page does not install or certify a package.",
		fields = { { id = "command", label = "Installation command", kind = "text", value = command, disabled = true } },
		actions = { { id = "copy", label = "Copy install command" }, { id = "cancel", label = "Back" } } },
		function(fresh: WindowCx, _values: any, action: string)
			if action == "copy" then fresh:copy(command); forms_ui.update(fresh, source, { busy = false, notice = "Installation command copied. Run it on your execution host." })
			else forms_ui.cancel(fresh, source) end
		end)
end
local function continuation_candidate(cx: WindowCx, source: number, target: number, origin: any): any?
	if not current_context(cx, source, origin) then return nil end
	local pane = origin_pane(cx, source, target, origin)
	if not pane or (not agent_of(cx, target) and pane.kind ~= "terminal") then return nil end
	return pane_binding(target, origin)
end
-- An owner command whose host answer a driver follows; a host refusal of it is noticed.
local function drive(cx: WindowCx, source: number, origin: any, command: string, fields: any, worker_id: string?): string?
	if not current_origin(cx, source, origin) then return nil end
	local id = send_command(cx, source, origin, command, fields, true)
	if id then start_driver(source, origin, id, worker_id, true) end
	return id
end
-- Companions use the existing host writer, native surfaces and exact current window route.
local ui_api: any = { id = dispatch_id, node = workflow_node, snapshot = snapshot, current = current_origin,
	fresh = fresh_intent, notice = notice, capture = capture_input, surface = surface_node, same = same_policy,
	forms = forms_ui,
	alias = alias, agent = agent_of, pane = origin_pane, binding = pane_binding,
	origin = function(cx: WindowCx, source: number)
		local data = snapshot(cx, source)
		return if data then origin_now(cx, source, data) else nil
	end,
	decision = function(cx: WindowCx, source: number, origin: any, command: string, fields: any): string?
		local fence = intent_fences[origin]
		if not fence or not current_origin(cx, source, origin) then return nil end
		local id = dispatch_id()
		local event = { kind = "dispatch", request_id = id, orch_session_id = origin.logical_session_id, origin = origin,
			controller_pane = tostring(source), command = command, authority_namespace = fence.authority_namespace, expected_revision = fence.expected_revision }
		for key, value in fields do event[key] = value end
		cx.session:event(source, { ev = "action", id = "main", act = "decision-context",
			value = tern.json.encode({ request_id = id, source_nonce = origin.alias_nonce, event = event }) })
		return id
	end,
	send = function(cx: WindowCx, source: number, origin: any, command: string, fields: any, _operator: boolean?)
		return drive(cx, source, origin, command, fields)
	end,
	catalog = function(cx: WindowCx, source: number, origin: any, cursor: any, context: string)
		return drive(cx, source, origin, "catalog", { bytes = cursor, decision_context = context })
	end,
	event = relay_event, ack = relay_ack,
	transport = function(cx: WindowCx, source: number, block: string, _args: any, captured_origin: any?)
		if block ~= "usage.display" then return nil end
		local data = snapshot(cx, source)
		local origin = captured_origin or (if data then origin_now(cx, source, data) else nil)
		return if origin then relay_endpoint(cx, source, "usage", "display", origin) else nil
	end,
	-- Installation evidence for USAGE: its Ready block types ("usage.*") on this window's host. nil = could not tell.
	usage_installed = function(cx: WindowCx): boolean?
		local ok, blocks = pcall(function() return cx.session:block_types() end)
		if not ok or type(blocks) ~= "table" then return nil end
		for _, block in blocks do if type(block.kind) == "string" and string.sub(block.kind, 1, 6) == "usage." then return true end end
		return false
	end,
	read_surface = peer_surface,
	capacity = function(_cx: WindowCx, source: number, origin: any, done: any)
		start_reader(source, origin, "snapshot", nil, done)
	end,
	new_panel = function(cx: WindowCx) return cx:new_block(BLOCK, {}, "tab") end,
	count = function(cx: WindowCx)
		local count = 0
		for _, pane in panes_on(cx, cx.hosts:current()) do
			local owner = if pane.block == BLOCK then alias(cx, pane.pane) else nil
			if owner and owner.orch_session_id then count += 1 end
		end
		return count
	end,
}
ui_api.agent_titles = function(cx: WindowCx, source: number, record_id: string, origin: any): string?
	local flow = workflow_node(cx, source, "workflow-index", "orchplus.workflow")
	local names = {}
	for _, id in (if flow then flow.worker_ids or {} else {}) do
		local worker = worker_now(cx, source, id)
		local binding = if worker and worker.record_id == record_id then worker.pane_binding else nil
		local pane = if binding and binding.window_key == origin.window_key and binding.window_epoch == origin.window_epoch
			and binding.native_session_id == origin.native_session_id and binding.window_host_id == origin.window_host_id
			then scoped_pane(cx, tonumber(binding.pane_id), origin) else nil
		local title = provider_display.pane_title(pane)
		if title then table.insert(names, title) end
	end
	return if #names > 0 then table.concat(names, " / ") else nil
end
ui_api.project_folders = function(cx: WindowCx, source: number, origin: any, project: any): any
	local paths, seen = {}, {}
	local function observe(binding: any)
		local target = if binding then tonumber(binding.pane_id) else nil
		if not target or not same_policy(binding, pane_binding(target, origin)) or not scoped_pane(cx, target, origin) then return end
		local agent = agent_of(cx, target)
		if agent and type(agent.cwd) == "string" and #agent.cwd <= 512 and not seen[agent.cwd] and #paths < 16 then
			seen[agent.cwd] = true; table.insert(paths, agent.cwd)
		end
	end
	for _, association in project.associations or {} do observe(association.pane_binding) end
	for _, id in project.members or {} do
		local worker = worker_now(cx, source, id)
		if worker then observe(worker.pane_binding) end
	end
	return paths
end
ui_api.open_spawn = function(cx: WindowCx, source: number)
	setup_ui.start(cx, source, "spawn")
end
ui_api.setup_ready = function(cx: WindowCx, source: number, done: any) setup_ui.ready(cx, source, done) end
ui_api.source_settings = function(cx: WindowCx, source: number, origin: any)
	if not current_origin(cx, source, origin) then
		notice(cx, source, origin.alias_nonce, "The source connection changed. Reopen this orchestration's settings from its current pane.")
		return false
	end
	setup_ui.start(cx, source, "session")
	return true
end
local work_requests: any = {}
local function settle_work(cx: WindowCx, pending: any, outcome: string, message: string?)
	local request = pending.request
	local pane, host = cx.session:pane(pending.pane), host_for(cx, pending.pane)
	if not pane or pane.block ~= "tern-work.panel" or not host or host.state ~= "connected"
		or tostring(host.id) ~= request.source.host or not pane.tab
		or tostring(tab_sessions(cx)[pane.tab]) ~= request.source.session then return end
	local _, bytes = surface_node(cx, pending.pane, "tern-work.panel", "work.orch.selection", "orch-selection", 32768)
	local frame = if bytes then decoded(bytes, 32768) else nil
	if not frame or frame.form_nonce ~= request.form_nonce or frame.request_id ~= request.request_id
		or not same_policy(frame.source, request.source) or frame.revision ~= request.revision or frame.selection_revision ~= 1 then return end
	local summary = if type(message) == "string" then message:gsub("[%c]", " ") else nil
	if summary and (#summary > 512 or utf8.len(summary) == nil) then summary = "The selection finished without a confirmed import. Inspect the orchestration's retained result." end
	cx.session:event(pending.pane, { ev = "action", id = "main", act = "orch-selection-ack", value = tern.json.encode({
		form_nonce = request.form_nonce, request_id = request.request_id, selection_revision = 1, outcome = outcome, message = summary }) })
end
ui_api.work_on = function(cx: WindowCx, source: number, origin: any, _request: any, done: any)
	local data = snapshot(cx, source)
	local flow = workflow_node(cx, source, "workflow-index", "orchplus.workflow")
	if not data or not current_origin(cx, source, origin) or not flow or not flow.policy.glitch_integration or not flow.policy.work_on_enabled then
		notice(cx, source, origin.alias_nonce, "Enable Glitch integration and Work On in Settings before selecting work.")
		return done(cx, nil, nil)
	end
	local retained = work_requests[source]
	if retained then
		if not retained.delivered and retained.authority_namespace == data.authority_namespace and current_origin(cx, source, retained.origin) then
			local pane = scoped_pane(cx, retained.pane, retained.origin)
			if pane and pane.block == "tern-work.panel" then
				retained.done = done
				local _, bytes = surface_node(cx, retained.pane, "tern-work.panel", "work.orch.context", "orch-context", 32768)
				local context = if bytes then decoded(bytes, 32768) else nil
				if context and context.mode == "orchestration" and context.form_nonce == retained.request.form_nonce
					and context.request_id == retained.request.request_id and same_policy(context.source, retained.request.source) then cx.layout:focus(retained.pane) end
				return
			end
		end
		notice(cx, source, origin.alias_nonce, "WORK is still finishing its selected context. Wait for its retained import result before choosing again.")
		return done(cx, nil, nil)
	end
	local request = { mode = "orchestration", form_nonce = dispatch_id(), request_id = dispatch_id(),
		source = { pane = tostring(source), host = tostring(cx.hosts:current().id), window = cx:window_key(), session = tostring(cx.sessions:current().id) },
		revision = data.authority_revision }
	local target = nil
	local membership = tab_sessions(cx)
	for _, pane in panes_on(cx, cx.hosts:current()) do
		if pane.block ~= "tern-work.panel" or pane.parked or not pane.tab or tostring(membership[pane.tab]) ~= request.source.session then continue end
		local _, bytes = surface_node(cx, pane.pane, "tern-work.panel", "work.orch.context", "orch-context", 32768)
		local previous = if bytes then decoded(bytes, 32768) else nil
		if not previous or previous.mode ~= "orchestration" or previous.phase ~= "accepted" then continue end
		target = pane.pane; break
	end
	if target then
		cx.session:event(target, { ev = "action", id = "main", act = "orch-open", value = tern.json.encode(request) })
		cx.layout:focus(target)
	else
		local ok, created = pcall(function() return cx:new_block("tern-work.panel", { tern.json.encode(request) }, "beside", { target = source, dir = "right", focus = true }) end)
		if ok then target = created end
	end
	if not target then
		return forms_ui.open(cx, source, origin, { title = "Requires WORK plugin", description = "Glitch work selection needs the compatible WORK plugin on this execution host. Install or update WORK, configure its Glitch root, then use WORK ON again. Neutral operation does not require WORK.", fields = {},
			actions = { { id = "cancel", label = "Back" } } }, function(fresh: WindowCx) forms_ui.cancel(fresh, source); done(fresh, nil, nil) end)
	end
	work_requests[source] = { origin = origin, authority_namespace = data.authority_namespace, request = request, pane = target, done = done, started = tern.now() }
end
work_tick = function(cx: WindowCx)
	for source, pending in work_requests do
		-- The source consumer owns any already-issued import and its exact outcome.
		-- Losing focus/connection is not evidence that it was cancelled or did not happen.
		if pending.delivered then continue end
		local request, data = pending.request, snapshot(cx, source)
		local pane, host = cx.session:pane(pending.pane), host_for(cx, pending.pane)
		local flow = workflow_node(cx, source, "workflow-index", "orchplus.workflow")
		if not data or data.authority_namespace ~= pending.authority_namespace or not current_origin(cx, source, pending.origin)
			or not flow or not flow.policy.glitch_integration or not flow.policy.work_on_enabled
			or not pane or pane.block ~= "tern-work.panel" or not host or host.state ~= "connected"
			or tostring(host.id) ~= request.source.host or not pane.tab or tostring(tab_sessions(cx)[pane.tab]) ~= request.source.session then
			work_requests[source] = nil
			settle_work(cx, pending, "cancelled", "The selecting orchestration or WORK connection changed.")
			notice(cx, source, pending.origin.alias_nonce, "The orchestration or WORK connection changed. Select work again; nothing was imported.")
			pending.done(cx, nil, nil)
			continue
		end
		local _, context_bytes = surface_node(cx, pending.pane, "tern-work.panel", "work.orch.context", "orch-context", 32768)
		local context = if context_bytes then decoded(context_bytes, 32768) else nil
		if context and (context.mode == "standalone" or (context.mode == "orchestration"
			and (context.form_nonce ~= request.form_nonce or context.request_id ~= request.request_id
				or not same_policy(context.source, request.source) or context.revision ~= request.revision))) then
			work_requests[source] = nil
			pending.done(cx, nil, nil)
			continue
		end
		if pending.verifying then
			local response = workflow_node(cx, source, "source-discovery", "orchplus.sources")
			if not response or response.request_id ~= pending.verifying then continue end
			if response.ok and response.work_selection then
				pending.delivered = true
				pending.done(cx, response.work_selection, function(fresh: WindowCx, accepted: boolean, message: string?, outcome: string?)
					if work_requests[source] ~= pending then return end
					work_requests[source] = nil
					settle_work(fresh, pending, outcome or (if accepted then "success" else "refused"), message)
				end)
			else
				work_requests[source] = nil
				settle_work(cx, pending, "refused", response.message or "The selected source did not pass the execution-host checks.")
				notice(cx, source, pending.origin.alias_nonce, tostring(response.message or "The selected WORK source changed. Choose it again."))
				pending.done(cx, nil, nil)
			end
			continue
		end
		local _, bytes = surface_node(cx, pending.pane, "tern-work.panel", "work.orch.selection", "orch-selection", 32768)
		local frame = if bytes then decoded(bytes, 32768) else nil
		if frame and frame.phase == "cancelled" and frame.form_nonce == request.form_nonce and frame.request_id == request.request_id
			and same_policy(frame.source, request.source) and frame.revision == request.revision and frame.selection_revision == 1 then
			settle_work(cx, pending, "cancelled", nil)
			work_requests[source] = nil
			pending.done(cx, nil, nil)
			continue
		end
		if frame and frame.phase == "selected" and frame.form_nonce == request.form_nonce and frame.request_id == request.request_id
			and same_policy(frame.source, request.source) and frame.revision == request.revision and frame.selection_revision == 1 then
			pending.verifying = dispatch_id()
			cx.session:event(source, { ev = "action", id = "main", act = "source-discover", value = tern.json.encode({
				source_nonce = pending.origin.alias_nonce, request_id = pending.verifying, work_selection = {
					workspace_id = frame.workspace_id, workspace_path = frame.workspace_path, glitch_root = frame.glitch_root,
					source_kind = frame.source_kind, source_locator = frame.source_locator } }) })
		elseif tern.now() - pending.started > 1800000 then
			work_requests[source] = nil
			settle_work(cx, pending, "cancelled", "The WORK selection expired. No import was retried.")
			notice(cx, source, pending.origin.alias_nonce, "WORK selection expired without importing anything. Use WORK ON to choose again.")
			pending.done(cx, nil, nil)
		end
	end
end
readiness_ui = require("./readiness_window").new({
	id = dispatch_id, same = same_policy, snapshot = snapshot, current = current_origin,
	decision = ui_api.decision,
	decision_result = function(cx: WindowCx, source: number): any? return workflow_node(cx, source, "decision-context-result", "orchplus.decision") end,
	consent_current = function(cx: WindowCx, source: number, origin: any): boolean
		return cx.session:view(source, { nodes = 1, depth = 0, max_chars = 1 }) ~= nil and current_origin(cx, source, origin)
	end,
	open_controller = function(cx: WindowCx, source: number) cx.layout:focus(source) end,
	setup = function(cx: WindowCx, source: number): any? return workflow_node(cx, source, "setup-index", "orchplus.setup") end,
	flow = function(cx: WindowCx, source: number): any? return workflow_node(cx, source, "workflow-index", "orchplus.workflow") end,
	observation = function(cx: WindowCx, source: number): any? return workflow_node(cx, source, "readiness-index", "orchplus.readiness") end,
	origin = function(cx: WindowCx, source: number): any?
		local data = snapshot(cx, source)
		if not data then return nil end
		local origin = origin_now(cx, source, { source_nonce = data.source_nonce, orch_session_id = data.orch_session_id })
		return if origin and current_origin(cx, source, origin) and data.controller_phase == "active" then origin else nil
	end,
	catalog = function(cx: WindowCx, source: number, origin: any, done: any)
		picker_ui.load(cx, source, origin, function(fresh: WindowCx, catalog: any, problem: any)
			if not catalog then done(fresh, nil, problem); return end
			local flow = workflow_node(fresh, source, "workflow-index", "orchplus.workflow")
			local builder = if flow and flow.policy then flow.policy.preferred_worker_record else nil
			if not builder or builder == "" then done(fresh, nil, "Choose a preferred worker for this orchestration before running the optional exercise."); return end
			picker_ui.ensure(fresh, source, origin, builder, function(last: WindowCx, record: any, full: any, why: any)
				done(last, if record then full else nil, why)
			end)
		end)
	end,
	queue = function(cx: WindowCx, source: number, origin: any, fields: any): string? return drive(cx, source, fresh_intent(cx, source, origin), "queue", fields) end,
	command = function(cx: WindowCx, source: number, origin: any, command: string, fields: any)
		return drive(cx, source, fresh_intent(cx, source, origin), command, fields)
	end,
	project_context = function(cx: WindowCx, source: number, _origin: any, id: string)
		local index = workflow_node(cx, source, "project-index", "orchplus.projects")
		return if index then index.projects[id] else nil
	end,
})
local ORIGIN_LOST = "this window is no longer the controller's current execution origin, so nothing was sent or its answer cannot be followed here. Run ORCH+ Continue controller in this window, then retry."
-- An owner pick: `done` runs for a choice with `key` set (when given) while `still` holds
-- (default: this window is still the current execution origin).
local function ask_pick(cx: WindowCx, source: number, origin: any, placeholder: string, items: any, key: string?, done: (WindowCx, any) -> (), still: ((WindowCx) -> boolean)?)
	forms_ui.choose(cx, source, origin, { placeholder = placeholder, items = items }, function(fresh: WindowCx, choice: any)
		if not choice or (key and not choice[key]) or not native_scope.input_context(fresh, source, origin) then return end
		if not (if still then still(fresh) else current_origin(fresh, source, origin)) then return end
		done(fresh, choice)
	end)
end
local function ask_decision(cx: WindowCx, source: number, origin: any, placeholder: string, items: any, key: string?, done: (WindowCx, any) -> (), still: ((WindowCx) -> boolean)?)
	capture_input(source, origin, cx:pick({ placeholder = placeholder, items = items }), function(choice: any, err: string?, fresh: WindowCx?)
		if not fresh or not choice or err or (key and not choice[key]) then return end
		if not (if still then still(fresh) else current_origin(fresh, source, origin)) then return end
		done(fresh, choice)
	end)
end
-- Owner confirmation of one worker control: the re-read worker must keep its generation and pass
-- `same`; otherwise `changed` is noticed and nothing is sent. `refusal`, when given, names why the
-- re-read worker cannot take the command (noticed; nothing is sent). Every unsent choice is noticed.
local function confirm_worker(cx: WindowCx, source: number, origin: any, worker: any, placeholder: string, keep: string, act: string, key: string,
	same: (any) -> any, changed: string, command: string, fields: any, refusal: ((any) -> string?)?)
	local detail = worker.worker_id .. " / generation " .. tostring(worker.worker_generation)
	ask_decision(cx, source, origin, placeholder, { { label = keep, [key] = false }, { label = act, detail = detail, [key] = true } }, key, function(fresh)
		local current = worker_now(fresh, source, worker.worker_id)
		if not current or current.worker_generation ~= worker.worker_generation or not same(current) then return notice(fresh, source, origin.alias_nonce, changed) end
		local reason = if refusal then refusal(current) else nil
		if reason then return notice(fresh, source, origin.alias_nonce, reason) end
		if not drive(fresh, source, origin, command, fields, worker.worker_id) then notice(fresh, source, origin.alias_nonce, act .. ": " .. ORIGIN_LOST) end
	end, function(fresh)
		if current_origin(fresh, source, origin) then return true end
		notice(fresh, source, origin.alias_nonce, act .. ": " .. ORIGIN_LOST)
		return false
	end)
end
-- Finish pre-check: the reducer's definitive Finish refusals visible in the worker projection (the
-- reducer validates again; its own refusal is noticed by the driver). Nil: Finish may be sent.
local function finish_refusal(worker: any, origin: any): string?
	local id = worker.worker_id
	if worker.coordinator_owner_id then return "Finish refused: " .. id .. " is a coordinator; coordinators use graceful retirement. Nothing was stopped." end
	if worker.finish_requested then
		-- After SPAWN's pre-effect retirement refusal, Finish re-arms exactly one fresh retirement.
		if worker.retirement_refused then return nil end
		return "Finish is already requested for " .. id .. "; it stops and retires once every effect settles. Nothing was sent again."
	end
	if worker.phase ~= "accepted" then
		local held = worker.held_reason
		return "Finish refused: " .. id .. " is " .. tostring(worker.phase)
			.. (if type(held) == "table" then " (" .. tostring(held.code) .. ": " .. tostring(held.message) .. ")" else "")
			.. ". Only an accepted worker can finish; reconcile or cancel its work first. Nothing was stopped."
	end
	if worker.continuation_required then
		return "Finish refused: " .. id .. " needs explicit reattachment first (Continue after reload / reattach explicitly…). Nothing was stopped."
	end
	if not same_origin(worker.origin_binding, origin) then
		return "Finish refused: " .. id .. " is controlled through another window or session route; reattach it in this window first. Nothing was stopped."
	end
	if worker.active_action_id then
		return "Finish refused: " .. id .. " has unsettled effect " .. tostring(worker.active_action_id)
			.. "; Finish cannot discard unresolved effects. Read / settle it, or reconcile the retained action, first. Nothing was stopped."
	end
	if worker.report_request_pending then
		return "Finish refused: " .. id .. " has a pending report request; settle it first. Nothing was stopped."
	end
	if worker.report_held then
		return "Finish refused: " .. id .. " holds a rejected report; re-check or inspect it first. Nothing was stopped."
	end
	return nil
end
local function live_rollover(worker: any): any?
	return if worker and worker.rollover and worker.rollover.phase ~= "complete" and worker.rollover.phase ~= "cancelled" then worker.rollover else nil
end
local function dispatch_control(cx: WindowCx, source: number, request: any)
	local origin = origin_now(cx, source, request)
	if not origin then notice(cx, source, request.source_nonce, "Dispatch refused: this is not the admitted controller in its current host/session. No session was switched."); return end
	local command = request.command
	if command == "open_plan" then
		local plan = if type(request.plan_id) == "string" then workflow_node(cx, source, "workflow-plan-" .. request.plan_id, "orchplus.plan") else nil
		if not current_origin(cx, source, origin) or not plan or plan.plan_id ~= request.plan_id
			or plan.orch_project_id ~= request.orch_project_id or not source_adapter.normalize_root(plan.path, nil) then
			notice(cx, source, origin.alias_nonce, "This plan is no longer available here. Open its current project and try again."); return
		end
		cx.layout:focus(source)
		cx:open(plan.path, "tab")
		return
	end
	if command == "settings" or command == "save_defaults" then
		setup_ui.start(cx, source, if command == "settings" then "session" else "save_defaults"); return
	end
	if conversation_ui.start(cx, source, origin, command, request) then return end
	if table.find({ "work-on", "add-plan", "add-board", "start-template", "open-plan-board", "source-proposal" }, command) then
		source_ui.start(cx, source, origin, command, request); return
	end
	local function refuse(message: string) notice(cx, source, origin.alias_nonce, message) end
	local worker = if type(request.worker_id) == "string" then worker_now(cx, source, request.worker_id) else nil
	if command == "ruling_write" or command == "ruling_observe" or command == "ruling_remote" or command == "ruling_reissue" then
		local gate = current_gate(cx, source, request)
		if not gate or not gate.ruling or ruling_jobs[source] then return end
		local previous_writer = if gate.ruling.intent then gate.ruling.intent.writer else nil
		local remote = command == "ruling_remote" or (previous_writer and previous_writer.kind == "worker")
		if cx.hosts:current().kind == "remote" and not remote then
			return refuse("Native Docs requires the same local machine. Use the existing authorized document-owning worker, or record the exact pending entry yourself.")
		end
		local job = { source = source, origin = origin, gate_id = gate.id, gate_revision = gate.revision, previous_writer = previous_writer,
			path = gate.ruling.path, mode = if command == "ruling_observe" then "observe" elseif command == "ruling_reissue" then "reissue" else "write" }
		if remote and previous_writer then job.writer = previous_writer end
		local function begin(fresh: WindowCx)
			ruling_jobs[source] = job
			send_ruling(fresh, job, "ruling_inspect")
		end
		local choices: any = { { label = "Keep exact ruling pending for the owner" } }
		if command ~= "ruling_reissue" then
			table.insert(choices, { label = if remote then "I verified the remote writer exclusively owns the document, it is quiescent, and no participating buffer has unsaved edits"
				elseif command == "ruling_observe" then "Read current buffer and disk as the original writer"
				else "Document is quiescent; no other writer may edit it during this operation", confirm = true })
		end
		if previous_writer and (command == "ruling_reissue" or (command == "ruling_observe" and not remote)) then
			table.insert(choices, { label = "I verified the exact original writer ended and no pending native write can complete",
				detail = tern.json.encode(previous_writer) .. "; current buffer and host disk will be read independently",
				confirm = true, ended = true })
		end
		ask_decision(cx, source, origin, "Use one participating writer for this existing document?", choices, "confirm", function(fresh, choice)
			job.verified = true
			job.remote_buffer_attested = remote == true
			job.writer_ended_verified = choice.ended == true
			job.no_late_write_verified = choice.ended == true
			if command == "ruling_remote" and not job.writer then
				local flow = workflow_node(fresh, source, "workflow-index", "orchplus.workflow")
				local items = { { label = "Cancel — keep pending" } }
				for _, id in (if flow then flow.worker_ids or {} else {}) do
					local candidate = worker_now(fresh, source, id)
					if candidate then table.insert(items, { label = id .. " / " .. candidate.work_id, worker = candidate }) end
				end
				ask_pick(fresh, source, origin, "Select the existing document-owning authorized writer (host verifies provisioned capability)", items, "worker", function(last, choice)
					job.writer = { kind = "worker", worker_id = choice.worker.worker_id, worker_generation = choice.worker.worker_generation }
					begin(last)
				end)
			else begin(fresh) end
		end)
		return
	elseif command == "associate_document" then
		if not worker then return end
		forms_ui.input(cx, source, origin, { placeholder = "Existing document path on this execution host", confirm_label = "Associate document" }, function(fresh: WindowCx, path: string?)
			if path == nil or not current_origin(fresh, source, origin) then return end
			local job = { source = source, origin = origin }
			send_ruling(fresh, job, "associate_document", { worker_id = worker.worker_id, path = path })
		end)
		return
	end
	if command == "bridge_admit" or command == "bridge_reconcile" then
		local data = snapshot(cx, source)
		if not data or not (current_origin(cx, source, origin) or (command == "bridge_reconcile" and closing_context(cx, source, origin, true))) then return end
		local operation = if command == "bridge_admit" then "admit_session" else "reconcile_session"
		if not data.compatibility then pairings[source] = { origin = origin, operation = operation }
		elseif data.control then controls[source] = nil
		else queue_control(cx, source, origin, operation, data.compatibility, true) end
		arm(); return
	elseif command == "close_session" then
		ask_decision(cx, source, origin, "Close this logical session after all current obligations settle?", {
			{ label = "Keep session open" }, { label = "Close session; preserve documents, sources and Git", confirm = true },
		}, "confirm", function(fresh)
			local current = snapshot(fresh, source)
			if current and current.session_control and current.session_control.phase == "closing" then
				controls[source] = nil
				arm()
				return
			end
			local close_id = dispatch_id()
			local pending = controls[source]
			local receipt = if current then current.control_result else nil
			if pending and (pending.refused or (pending.creating and receipt
				and receipt.request_id == pending.creating and receipt.ok == false)) then
				pending.approved_close_id = close_id
			end
			authority_command(fresh, source, origin, "begin_close", { close_id = close_id,
				control_origin = { kind = "closing", binding = origin, controller_pane = tostring(source), close_id = close_id } })
		end, function(fresh) return current_origin(fresh, source, origin) or closing_context(fresh, source, origin, true) end)
		return
	elseif command == "forget_session" or command == "forget_continue" then
		local data = snapshot(cx, source)
		if data then conversation_ui.forget.start(cx, source, origin, data, command == "forget_continue") end
		arm()
		return
	elseif command == "forget_back" then
		conversation_ui.forget.clear(cx, source)
		return
	elseif command == "close_handover" then
		ask_decision(cx, source, origin, "Close retired handover without a successor?", {
			{ label = "Keep handover pending" }, { label = "Leave no coordinator; require an explicit new start", confirm = true },
		}, "confirm", function(fresh)
			native_scope.owner_send(fresh, source, origin, "close_handover", { worker_id = request.worker_id })
		end)
		return
	end
	if command == "check_connection" then
		if guides[source] then
			notice(cx, source, origin.alias_nonce, "A connection check is already in progress. No agent was started.", "info", "ORCH+", { context = "catalog" })
			return
		end
		start_guide(source, origin, false)
		guides[source].read_only = true
		local data = snapshot(cx, source, if type(request.action_id) == "string" then request.action_id else nil)
		local action = if data then data.action else nil
		if action and action.request.op == "catalog" and action.claim and (action.phase == "claimed" or action.phase == "uncertain")
			and same_origin(action.execution_origin or action.request.origin_binding, origin) then
			guides[source].catalog_request = plain(action.request)
		end
		notice(cx, source, origin.alias_nonce, "Checking the connection. No agent will be started.", "info", "ORCH+", { context = "catalog" })
		arm()
		return
	end
	if command == "recovery_guide" then
		reconnect_relays(cx, source, origin)
		-- Explicit reconnect retries only bounded observation, never the original
		-- launch. Keep any already-used immutable-publication readback allowance.
		local data = snapshot(cx, source)
		for _, id in (if data then data.uncertain_actions else {}) or {} do
			local scoped = snapshot(cx, source, id)
			local action = if scoped then scoped.action else nil
			local previous = auto_reconcile[id]
			if action and action.phase == "uncertain" and action.claim and previous
				and previous.grant_id == action.claim.grant_id
				and same_origin(action.execution_origin or action.request.origin_binding, origin) then
				previous.attempts, previous.next_at = 0, awake_now()
			end
		end
		start_guide(source, origin, true); arm()
		return
	end
	if command == "continue_controller" then
		local data = snapshot(cx, source)
		if not data or (request.expected_revision and request.expected_revision ~= data.revision) then
			return refuse("Controller revision changed. Run ORCH+ Continue controller in this window from the palette again.")
		end
		local revision = data.revision
		ask_decision(cx, source, origin, "Continue controller " .. origin.owner_id .. " / generation " .. tostring(origin.owner_generation)
			.. " / revision " .. tostring(revision) .. "? Old claims and coordinator uncertainty stay held.", {
			{ label = "Cancel — retain current binding", continue_controller = false },
			{ label = "I independently verified previous ORCH+/SPAWN executors stopped or retired",
				detail = "Operator attestation, not native proof. Enables retained-outcome inspection; never retries old effects or clears pending claims.", continue_controller = true },
		}, "continue_controller", function(fresh)
			local current = snapshot(fresh, source)
			if not current or current.revision ~= revision then
				return notice(fresh, source, origin.alias_nonce, "Controller changed during verification. Run ORCH+ Continue controller in this window again; nothing was rebound.")
			end
			-- Reconnect only after this exact continuation is durably acknowledged.
			local continuation = native_scope.owner_send(fresh, source, origin, "continue_controller", { expected_revision = revision, operator_verified = true })
			if continuation then
				start_guide(source, origin, false, continuation)
				guides[source].automatic = true
				arm()
			end
		end, function(fresh) return current_context(fresh, source, origin) end)
		return
	end
	if command == "project_start_retry" then
		if not current_origin(cx, source, origin) then return end
		local index = workflow_node(cx, source, "project-index", "orchplus.projects")
		local project = if index and type(index.projects) == "table" then index.projects[request.orch_project_id] else nil
		local start = if project then project.start else nil
		if not start or start.start_id ~= request.start_id or start.project_revision ~= request.project_revision
			or start.decision_context ~= request.decision_context then return refuse("This project changed. Review it and choose START again.") end
		local delivery_id = start.delivery_action_id
		local scoped = if type(delivery_id) == "string" then snapshot(cx, source, delivery_id) else nil
		local action = if scoped then scoped.action else nil
		local id = native_scope.owner_send(cx, source, origin, command, { orch_project_id = request.orch_project_id, start_id = request.start_id,
			project_revision = request.project_revision, decision_context = request.decision_context })
		if not id or not action or action.action_id ~= delivery_id then return end
		if start.delivery_state == "uncertain" and action.phase == "uncertain" and action.claim
			and action.request and action.request.op == "mailbox_publish_reply" then
			-- This executor can only inspect the original live claim. It cannot claim,
			-- begin or resend publication, even if the host projection changes afterward.
			if not scope_busy(source, delivery_id) and not lane_busy(source, action.worker_id) then
				local key = tostring(source) .. ":start-retry:" .. delivery_id
				drivers[key] = { key = key, source = source, origin = origin, scope = delivery_id, worker_id = action.worker_id,
					reconcile_action_id = delivery_id, require_status = true, auto = true,
					stale_result = if scoped.result then scoped.result.request_id else nil }
				arm()
			end
		elseif table.find({ "ready", "held_ready", "backpressure" }, start.delivery_state) then
			-- Only the scoped host command can re-arm demonstrably unissued bytes.
			held_actions[delivery_id] = nil; recheck_waits[delivery_id] = nil
		end
		return
	end
	if not current_origin(cx, source, origin) then
		return refuse("This window is not the continued execution origin. Run the palette command ORCH+ Continue controller in this window, inspect retained outcomes, then explicitly reattach workers.")
	end
	if command == "retire_controller" then
		if observed_owner_state(source, origin) ~= "retired" then
			return refuse("SPAWN has not proved this exact controller generation retired. Reopen the recovery guide; no ownership changed.")
		end
		ask_decision(cx, source, origin, "Retire this SPAWN-fenced controller generation?", {
			{ label = "Keep this controller", retire = false },
			{ label = "Retire this controller generation; preserve workers and pending evidence", retire = true,
				detail = "Outstanding executors or unresolved dispatch prevent retirement. Workers, accepted sessions and pending evidence remain retained. Advanced recovery can inspect this same orchestration; restoring managed work requires verified ownership and reconciliation, never a duplicate launch." },
		}, "retire", function(fresh)
			if observed_owner_state(source, origin) ~= "retired" then
				return notice(fresh, source, origin.alias_nonce, "Recovery evidence changed; no ownership retirement was submitted.")
			end
			reveal(fresh, source, true)
			authority_command(fresh, source, origin, "release_controller",
				{ expected_owner_id = origin.owner_id, expected_generation = origin.owner_generation }, true)
		end)
		return
	end
	if command == "continue_worker" then
		if not worker or type(worker.continuation_proof) ~= "string" then return end
		local proof = worker.continuation_proof
		local function unchanged(fresh: WindowCx, candidate: any): boolean
			local current = worker_now(fresh, source, worker.worker_id)
			return candidate ~= nil and current ~= nil and current.continuation_proof == proof and current.worker_generation == worker.worker_generation
		end
		local candidates = { { label = "Cancel — do not adopt a pane" } }
		for _, pane in panes_on(cx, cx.hosts:current()) do
			if continuation_candidate(cx, source, pane.pane, origin) then
				table.insert(candidates, { label = "Inspect and select existing pane " .. tostring(pane.pane),
					detail = "Explicit operator identification required; number and current membership are not worker identity proof.", pane = pane.pane })
			end
		end
		ask_pick(cx, source, origin, "Select the exact existing worker for " .. worker.work_id .. " / " .. worker.worker_id, candidates, "pane", function(fresh, choice)
			local candidate = continuation_candidate(fresh, source, choice.pane, origin)
			if not unchanged(fresh, candidate) then
				return notice(fresh, source, origin.alias_nonce, "Worker, owner or retained executor evidence changed. No attachment was submitted.")
			end
			ask_decision(fresh, source, origin, "Attach " .. worker.worker_id .. " / generation " .. tostring(worker.worker_generation)
				.. " to pane " .. candidate.pane_id .. " against its exact retained identity and executor evidence?", {
				{ label = "Cancel — retain original route", attach = false },
				{ label = "I verified this exact worker and old executors stopped or retired",
					detail = "Original launch: " .. tern.json.encode(worker.launch_origin_binding or worker.origin_binding)
						.. " · original pane: " .. tern.json.encode(worker.launch_pane_binding or worker.pane_binding)
						.. ". Decisions remain bound to this generation; uncertain effects are never retried.", attach = true },
			}, "attach", function(next_cx)
				local verified = continuation_candidate(next_cx, source, choice.pane, origin)
				if not unchanged(next_cx, verified) or not same_origin(verified, candidate) then
					return notice(next_cx, source, origin.alias_nonce, "Attachment confirmation expired; no pane was adopted.")
				end
				drive(next_cx, source, origin, "continue_worker", { worker_id = worker.worker_id, pane_binding = candidate,
					continuation_proof = proof, operator_verified = true }, worker.worker_id)
			end)
		end)
	elseif command == "pause" or command == "resume" then
		native_scope.owner_send(cx, source, origin, command, nil)
	elseif command == "policy" then
		local flow = workflow_node(cx, source, "workflow-index", "orchplus.workflow")
		if not flow or not flow.policy or type(flow.policy_sha256) ~= "string" then return end
		local previous = flow.policy
		if request.expected_sha256 ~= flow.policy_sha256 then return refuse("Config changed since this control was displayed. Reopen Config; nothing changed.") end
		if request.field == nil and type(request.policy) == "table" then
			save_policy(cx, source, origin, previous, { policy = request.policy })
		else setup_ui.start(cx, source, "session") end
	elseif command == "finish" then
		if not worker then return refuse("Finish requires a current ordinary worker; its projection is unavailable. Nothing was stopped.") end
		local reason = finish_refusal(worker, origin)
		if reason then return refuse(reason) end
		local retry = worker.finish_requested == true
		confirm_worker(cx, source, origin, worker, if retry then "Retry the mailbox retirement of " .. worker.work_id .. " once? SPAWN refused it before any effect."
			else "Finish " .. worker.work_id .. "? Stop and retire only after every gate, delivery and claim is settled.",
			"Cancel — keep worker", if retry then "Retry mailbox retirement once" else "Finish this ordinary worker", "finish",
			function(current) return (current.finish_requested == true) == retry end,
			"Worker changed during confirmation; nothing was stopped.", "finish", { worker_id = worker.worker_id },
			function(current) return finish_refusal(current, origin) end)
	elseif command == "rollover" then
		local active = live_rollover(worker)
		if not worker or worker.finish_requested then return refuse("Rollover controls apply to a current worker or the activated coordinator.") end
		local placeholder = if active then "Request the checkpoint again for rollover " .. active.id .. "? The previous checkpoint stays as evidence."
			elseif worker.coordinator_owner_id then "Roll over coordinator " .. worker.work_id .. "? ORCH+ asks for a verified checkpoint, retires and stops this coordinator, and only after its observed closure and slot release starts a fresh successor."
			else "Roll over " .. worker.work_id .. "? ORCH+ asks for a verified checkpoint, starts a fresh successor, and stops this worker only after the successor accepts."
		local act = if active then "Request checkpoint again" elseif worker.coordinator_owner_id then "Roll over coordinator" else "Roll over worker"
		confirm_worker(cx, source, origin, worker, placeholder, "Keep current state", act, "confirm", function(current)
			local now = live_rollover(current)
			return (if now then now.id else nil) == (if active then active.id else nil)
		end, "Worker or rollover changed during confirmation; nothing was requested.", "rollover",
			{ worker_id = worker.worker_id, trigger = "owner" })
	elseif command == "recheck_report" then
		if not worker or not worker.report_held or worker.continuation_required then
			return refuse("Re-check needs a held report on an explicitly continued worker. Continue after reload first if required.")
		end
		confirm_worker(cx, source, origin, worker, "Re-check the held report of " .. worker.worker_id .. "? The same retained bytes are decoded again with current validation; nothing is skipped or replaced.",
			"Keep it held", "Re-check held report", "confirm", function(current) return current.report_held end,
			"The held report changed during confirmation; nothing was re-checked.", "recheck_report", { worker_id = worker.worker_id })
	elseif command == "reconcile_restored" then
		if not worker or not worker.restored or worker.restored.reconciled then return refuse("No unreconciled restored coordinator pane is recorded for this worker.") end
		ask_decision(cx, source, origin, "Confirm you independently stopped the restored retired coordinator pane " .. worker.worker_id .. "? This records operator attestation only; nothing is stopped or restarted.", {
			{ label = "Keep coordinator effects held", confirm = false },
			{ label = "I stopped it — record reconciliation", detail = worker.worker_id, confirm = true },
		}, "confirm", function(fresh)
			local current = worker_now(fresh, source, worker.worker_id)
			if not current or not current.restored or current.restored.reconciled or current.restored.at_ms ~= worker.restored.at_ms then
				return notice(fresh, source, origin.alias_nonce, "Restoration evidence changed during confirmation; nothing was recorded.")
			end
			native_scope.owner_send(fresh, source, origin, "reconcile_restored", { worker_id = worker.worker_id, operator_verified = true })
		end)
	elseif command == "cancel_landing" or command == "move_landing" or command == "landing_lost" or command == "reconcile_landing" then
		local item = landing_now(cx, source, request)
		if not item then return refuse("Landing item changed; reopen its current controls. Nothing was submitted.") end
		local fields: any = { landing_id = item.id, landing_revision = item.revision }
		local function still(fresh: WindowCx): boolean
			if current_origin(fresh, source, origin) and landing_now(fresh, source, fields) then return true end
			notice(fresh, source, origin.alias_nonce, "Landing item changed during confirmation; nothing was submitted.")
			return false
		end
		local function ask_reason(fresh: WindowCx, placeholder: string, action: string, done: (WindowCx, string) -> ())
			forms_ui.input(fresh, source, origin, { placeholder = placeholder, confirm_label = action }, function(next_cx: WindowCx, reason: string?)
				if not reason or reason:find("%S") == nil or not still(next_cx) then return end
				done(next_cx, reason)
			end)
		end
		-- Contract J: a landed item's uncertain deploy takes the same read-only lost/reconcile path.
		local deployed = item.status == "landed"
		local unordered_head = not deployed and item.grant and item.grant.uncertain
			and item.grant.uncertain.code == "repository_head_unordered"
		local roles = if command == "cancel_landing" or (deployed and (command == "landing_lost" or command == "reconcile_landing")) then workflow_node(cx, source, "workflow-landing-roles-" .. item.id, "orchplus.landing-roles") else nil
		local deploy = if roles and roles.id == item.id and type(roles.deploy) == "table" then roles.deploy else nil
		if command == "move_landing" then
			if (request.direction == "up" and item.move_up) or (request.direction == "down" and item.move_down) then
				fields.direction = request.direction
				native_scope.owner_send(cx, source, origin, "move_landing", fields)
			end
		elseif command == "cancel_landing" then
			if not item.cancellable then return end
			local stop_deployment = item.status == "landed" and deploy and deploy.status == "pending" and deploy.attempts == 0
			if item.status == "landed" and not stop_deployment then return refuse("The deployment's current unissued state is unavailable or changed. Reopen its current controls; nothing was stopped.") end
			ask_decision(cx, source, origin, if stop_deployment then "Stop the pending deployment for " .. item.id .. "? Its merge is already landed and will not be undone. Only a deployment with no issued attempt may be stopped."
				else "Cancel ungranted landing " .. item.id .. "? Its approval gate is withdrawn; landing later needs a new worker request.", {
				{ label = if stop_deployment then "Keep pending deployment" else "Keep this request", confirm = false },
				{ label = if stop_deployment then "Stop pending deployment" else "Cancel this exact request", confirm = true },
			}, "confirm", function(fresh) native_scope.owner_send(fresh, source, origin, "cancel_landing", fields) end, still)
		elseif command == "landing_lost" then
			if not (if deployed then deploy and deploy.markable_lost == true else item.markable_lost) then return end
			ask_reason(cx, if deployed then "Deploy result lost — hold " .. tostring(deploy.deploy_id) .. " for reconciliation? Why is it lost? Nothing is re-granted or retried."
				else "Why is the exact result of " .. item.id .. " lost? The slot stays held for reconciliation; nothing is retried.",
				if deployed then "hold deploy" else "hold landing slot", function(fresh, reason)
				fields.reason = reason
				native_scope.owner_send(fresh, source, origin, "landing_lost", fields)
			end)
		else
			if not (if deployed then deploy and deploy.reconcilable == true else item.reconcilable) then return end
			local placeholder = if deployed then "Reconcile uncertain deploy " .. tostring(deploy.deploy_id) .. " of " .. item.id .. " from your read-only inspection of the target environment. ORCH+ never re-runs the deploy."
				else "Reconcile uncertain landing " .. item.id .. " from your read-only inspection of the target. ORCH+ never re-runs the merge."
			local items = if deployed then {
				{ label = "Keep the deploy held" },
				{ label = "I observed it DEPLOYED", detail = "Settles the deploy as deployed.", outcome = "deployed" },
				{ label = "I observed it NOT deployed", detail = "Settles this attempt as failed; nothing is retried automatically.", outcome = "not_deployed" },
			} else {
				{ label = "Keep the slot held" },
				{ label = "I observed it LANDED", detail = "Record this landing's resulting revision and the current target head separately.", outcome = "landed" },
				{ label = "I observed it NOT landed", detail = "Releases the slot; the worker must publish a fresh request. Nothing is retried.", outcome = "not_landed" },
			}
			ask_decision(cx, source, origin, placeholder, items, "outcome", function(fresh, choice)
				local function settle(next_cx: WindowCx, observed: string)
					ask_reason(next_cx, if deployed then "Evidence of your read-only inspection (for example the observed deploy log entry)"
						else "Evidence of your read-only inspection (for example the observed log entry)", if deployed then "reconcile deploy" else "reconcile landing", function(last_cx, reason)
						fields.outcome = choice.outcome; fields.reason = reason; fields.operator_verified = true
						if observed ~= "" then fields.target_revision = observed end
						native_scope.owner_send(last_cx, source, origin, "reconcile_landing", fields)
					end)
				end
				if deployed then return settle(fresh, "") end
				forms_ui.input(fresh, source, origin, { placeholder = if choice.outcome == "landed" then "Resulting target head revision (required)"
					elseif unordered_head then "Observed current target head revision (required to resolve unordered results)"
					else "Observed current target head revision (optional; leave empty if unknown)",
					confirm_label = "Record target head" }, function(next_cx: WindowCx, head: string?)
					if head == nil or not still(next_cx) then return end
					local observed = trimmed(head)
					if observed == "" and (choice.outcome == "landed" or unordered_head) then
						return notice(next_cx, source, origin.alias_nonce, "This reconciliation needs the observed target revision; nothing was submitted.")
					end
					if choice.outcome ~= "landed" then return settle(next_cx, observed) end
					forms_ui.input(next_cx, source, origin, { placeholder = "Observed current target head revision (required; may differ from this landing's result)",
						confirm_label = "Record current target head" }, function(current_cx: WindowCx, current: string?)
						if current == nil or not still(current_cx) then return end
						local current_head = trimmed(current)
						if current_head == "" then return notice(current_cx, source, origin.alias_nonce, "Inspect the current target head separately; nothing was submitted.") end
						fields.current_target_revision = current_head
						settle(current_cx, observed)
					end)
				end)
			end, still)
		end
	elseif command == "inspect_worker" or command == "open_worker" then
		if request.gate_id and not current_gate(cx, source, request) then return refuse("Gate changed; reopen its current controls.") end
		if type(request.worker_id) == "string" then inspect_worker(cx, source, origin, request.worker_id, command == "open_worker") end
	elseif command == "answer" or command == "cancel_gate" or command == "recheck_gate" then
		local gate = current_gate(cx, source, request)
		if not gate then return refuse("Gate revision or recipient changed. No answer or control was submitted.") end
		local fields = { gate_id = gate.id, gate_revision = gate.revision }
		local function gate_still(message: string): (WindowCx) -> boolean
			return function(fresh: WindowCx): boolean
				if not current_origin(fresh, source, origin) then return false end
				if current_gate(fresh, source, request) then return true end
				notice(fresh, source, origin.alias_nonce, message)
				return false
			end
		end
		if command == "recheck_gate" then
			native_scope.owner_send(cx, source, origin, "recheck_gate", fields)
			-- A quota fallback has no pane yet: recheck means a fresh, validated USAGE snapshot.
			if gate.kind == "quota_fallback" then start_reader(source, origin, "snapshot", nil, function() end)
			else inspect_worker(cx, source, origin, gate.worker_id, false) end
		elseif command == "cancel_gate" then
			ask_decision(cx, source, origin, "Cancel " .. gate.id .. "? Possible delivery cannot be retracted.", {
				{ label = "Keep gate", cancel_gate = false }, { label = "Cancel this exact gate revision", cancel_gate = true },
			}, "cancel_gate", function(fresh) native_scope.owner_send(fresh, source, origin, "cancel_gate", fields) end, gate_still("Gate changed during confirmation; nothing cancelled."))
		elseif gate.kind == "native_input" then
			refuse("Native input requires owner action in the exact pane. Open it, then recheck; ORCH+ cannot answer native permission or authentication prompts.")
		elseif gate.phase ~= "pending" then
			refuse("This question is no longer pending; immutable answers are not replaced.")
		else
			local _, bytes = surface_node(cx, source, BLOCK, "orchplus.gate-content", "workflow-gate-content-" .. gate.id, codec.LIMITS.logical)
			local content = if bytes then codec.strict_decode(bytes, codec.LIMITS.logical) else nil
			if not content or content.version ~= 1 or content.id ~= gate.id or content.revision ~= gate.revision
				or content.worker_id ~= gate.worker_id or content.worker_generation ~= gate.worker_generation
				or type(content.question) ~= "string" or type(content.options) ~= "table" or not current_gate(cx, source, request) then
				return refuse("The complete current question and choices are unavailable. Reopen this gate; no answer was requested.")
			end
			local items = {}
			for _, option in content.options do table.insert(items, { label = option.label, choice_id = option.id }) end
			ask_decision(cx, source, origin, content.question, items, nil, function(fresh, choice)
				local answer_fields = { gate_id = gate.id, gate_revision = gate.revision, choice_id = choice.choice_id, answer = choice.label,
					decision_context = request.decision_context or gate.decision_context }
				if dispatch.HOST_GATES[gate.kind] then
					-- Host-consumed decision: the chosen option is the whole answer (no free-text prompt). A
					-- stale-claim answer never changes the claim; open_recovery also opens the recovery guide.
					local id = native_scope.owner_send(fresh, source, origin, "answer", answer_fields)
					if id and gate.kind == "stale_claim" and choice.choice_id == "open_recovery" then start_guide(source, origin, true); arm() end
					return
				end
				ask_text(fresh, source, origin, nil, "Explicit owner answer for " .. gate.id .. " / " .. choice.label, "send immutable answer", function(next_cx, answer)
					if not gate_still("Question changed before submission; no answer sent.")(next_cx) then return end
					answer_fields.answer = answer
					native_scope.owner_send(next_cx, source, origin, "answer", answer_fields)
				end)
			end, gate_still("Question changed during selection; no answer sent."))
		end
	elseif command == "dismiss_refusal" then
		if not current_gate(cx, source, request) then return refuse("Gate revision or recipient changed. No answer or control was submitted.") end
		native_scope.owner_send(cx, source, origin, "dismiss_refusal", { gate_id = request.gate_id, gate_revision = request.gate_revision })
	elseif command == "queue" then
		conversation_ui.start(cx, source, origin, if request.coordinator then "start_orchestrator" else "new_conversation", request)
	elseif command == "capacity_refresh" then
		-- One owner refresh at a time: a second click never joins the running reader or replaces its pending confirmation.
		local running = readers[source]
		if (running and running.owner) or native_scope.capacity_confirms[source] then
			notice(cx, source, origin.alias_nonce, "A capacity refresh is already in progress. Wait for its result, then refresh again.", "info")
			return
		end
		start_reader(source, origin, "snapshot", nil, function(_: WindowCx, ok: boolean, request_id: string?)
			if ok and request_id then native_scope.capacity_confirms[source] = { request_id = request_id, origin = origin, sent_at = awake_now() }; arm() end
		end)
		if readers[source] then readers[source].owner = true end
	elseif command == "cancel_work" then
		if not worker then return refuse("Queued work changed; nothing was cancelled.") end
		-- Cancellation eligibility is not continuation or nonexecution evidence.
		-- Uncertain startup first needs SPAWN's exact retained pre-effect refusal.
		local fenced = if type(worker.withdrawal) == "table" then worker.withdrawal else nil
		if fenced and fenced.mailbox_retire == "retiring" then
			return refuse("This work's unused mailbox is already being retired; inspect that retirement's outcome. Nothing else was started.")
		end
		-- A launch SPAWN rejected after provisioning also retires the unused mailbox (driven like any queued effect).
		local retires = fenced ~= nil and fenced.mailbox_retire ~= nil
		local allocation_required = fenced and fenced.allocation_target ~= nil
		local failed_startup = fenced and fenced.evidence == "failed_startup"
		local placeholder = if failed_startup then "Remove failed startup " .. worker.work_id .. "? This coordinator launched but never accepted or activated. Its recovered owner has no authority. SPAWN first checks its exact original pane in this authorized native window and proves its producer journal unused before retirement. Live, restored or unknown evidence removes nothing. The original launch and mailbox target are preserved; no native stop, acceptance or release is fabricated."
			elseif fenced then (if allocation_required then "Check mailbox allocation before cancelling work " elseif fenced.status_required then "Check before cancelling work "
				elseif fenced.pending_startup then "Cancel queued work " else "Cancel never-launched work ") .. worker.work_id .. "? "
			.. (if allocation_required then "Startup failed without a confirmed allocation handle. An exact read-only allocation observation must first establish whether an unused mailbox remains"
				elseif fenced.status_required then "Its " .. tostring(fenced.op) .. " outcome is unconfirmed; SPAWN's retained status must first prove nonexecution"
				elseif fenced.pending_startup then "Its " .. tostring(fenced.op) .. " has not been sent; normal startup does not require cancellation"
				elseif fenced.evidence == "spawn_rejected" then "SPAWN returned a terminal startup rejection"
				elseif fenced.evidence == "unissued" then "Its " .. tostring(fenced.op) .. " was never sent"
				else "SPAWN proved its " .. tostring(fenced.op) .. " did not execute")
			.. (if fenced.status_required then ". Only after that proof can cancellation proceed" else "")
			.. (if allocation_required then ". A retained unused mailbox is retired through the existing path; unknown allocation stays held. No agent is launched or reprovisioned."
				elseif retires then ". Its provisioned, never-used mailbox is retired through the exact retirement path; the worker stays visible until SPAWN confirms retirement. Nothing native is stopped."
				else ". The worker and its assignment are discarded only if unexecuted; nothing native is stopped or retired.")
			else "Cancel held work " .. worker.work_id .. "? It was never provisioned or launched; its assignment is discarded."
		ask_decision(cx, source, origin, placeholder, {
			{ label = if fenced then "Keep it" else "Keep it held", confirm = false },
			{ label = if failed_startup then "Remove this failed startup" elseif allocation_required then "Observe allocation and cancel only when safe" elseif fenced and fenced.status_required then "Read status and cancel only if unexecuted"
				elseif fenced and not fenced.pending_startup then "Cancel this never-launched work" else "Cancel this queued work", detail = worker.worker_id, confirm = true },
		}, "confirm", function(fresh)
			if fenced and (fenced.status_required or allocation_required) then
				if withdrawals[source] then return notice(fresh, source, origin.alias_nonce, "Another cancellation is still reading SPAWN status; nothing else was started.") end
				withdrawals[source] = { origin = origin, worker_id = worker.worker_id, fenced = fenced, started = awake_now() }
				arm()
				return
			end
			local id = native_scope.owner_send(fresh, source, origin, "cancel_work", { worker_id = worker.worker_id })
			if id and retires then start_driver(source, origin, id, worker.worker_id) end
		end)
	elseif command == "start_work" then
		local model = workflow_node(cx, source, "workflow-index", "orchplus.workflow")
		source_ui.start(cx, source, origin, if request.template_id then "start-template"
			elseif model and model.policy.glitch_integration then "work-on" else "add-plan", request)
	elseif command == "withdraw_start_retire" then
		if not worker or worker.start_retirement_ready ~= true or worker.start_retirement_requested == true then
			return refuse("This conversation changed. Review it again before withdrawing START.")
		end
		drive(cx, source, origin, "retire", { worker_id = worker.worker_id, withdraw_starts = true }, worker.worker_id)
	elseif command == "catalog" or command == "poll" or command == "reply" or command == "retire" then
		drive(cx, source, origin, command, { bytes = request.bytes, worker_id = request.worker_id }, request.worker_id)
	elseif command == "retry" then
		if type(request.action_id) ~= "string" then return end
		held_actions[request.action_id] = nil; capacity_waits[request.action_id] = nil; recheck_waits[request.action_id] = nil
		drive(cx, source, origin, "retry", { action_id = request.action_id, trigger = "owner" })
	elseif command == "readback_publication" then
		if type(request.action_id) ~= "string" then return end
		held_actions[request.action_id] = nil
		native_scope.owner_send(cx, source, origin, "readback_publication", { action_id = request.action_id })
	elseif command == "reconcile" or command == "execute" then
		if type(request.action_id) ~= "string" then return end
		-- Reconciliation only reads status. Ready execution still requires a fresh durable claim.
		local _, node = snapshot(cx, source)
		cx.session:event(source, { ev = "action", id = node.id, act = "dispatch-select", value = tern.json.encode({ source_nonce = origin.alias_nonce, action_id = request.action_id }) })
		local driver = drivers[source]
		if driver and (driver.delivery or driver.action_id) then
			return refuse("A captured delivery or live grant is still settling. Its driver is retained; inspect the selected action after settlement.")
		end
		for _, active in drivers do
			if active.source == source and active.scope == request.action_id then
				return refuse(if active.auto then "An automatic read-only reconciliation of this exact action is already reading its retained SPAWN outcome. No second driver or grant was created."
					else "This exact action already has its retained executor. No second driver or grant was created.")
			end
		end
		held_actions[request.action_id] = nil; capacity_waits[request.action_id] = nil
		if command == "execute" then claims_in_flight[request.action_id] = nil end
		-- An unstarted automatic read of another action yields; the owner's driver never inherits it.
		drivers[source] = if driver and not driver.auto then driver else { source = source, origin = origin }
		drivers[source].scope = request.action_id
		drivers[source].reconcile_action_id = if command == "reconcile" then request.action_id else nil
		arm()
	end
end
picker_ui = require("./picker_window").new(ui_api)
setup_api.picker = picker_ui
source_ui = require("./source_window").new(ui_api)
ui_api.picker, ui_api.sources = picker_ui, source_ui
conversation_ui = require("./conversation_window").new(ui_api)
-- (window.luau is at Luau's 200-local limit: the forget module hangs off conversation_ui instead of a new local.)
ui_api.bridge = function(cx: WindowCx, source: number, origin: any) return acquire_bridge(cx, source, origin, "control") end
ui_api.peer, ui_api.relay, ui_api.closing, ui_api.authority, ui_api.intent = peer_surface, relay_event, closing_context, authority_command, intent_origin
ui_api.context = current_context
conversation_ui.forget = require("./forget_window").new(ui_api)
tern.route.link(function(link: any, cx: WindowCx)
	if source_ui.route and source_ui.route(cx, link) then return { handled = true } end
	return nil
end)
ui_api.control = function(cx: WindowCx, source: number, command: string, origin: any, fields: any?)
	if command == "new_orchestration" then conversation_ui.create(cx); return end
	if command == "switch_orchestration" then open(cx); return end
	local data = snapshot(cx, source)
	if data then
		local request = { command = command, source_nonce = origin.alias_nonce, orch_session_id = origin.logical_session_id,
			authority_namespace = data.authority_namespace, expected_revision = data.authority_revision }
		if command == "project_start_retry" then
			for _, key in { "orch_project_id", "start_id", "project_revision", "decision_context" } do request[key] = if fields then fields[key] else nil end
		end
		dispatch_control(cx, source, request)
	end
end
ui_api.creation_current = function(cx: WindowCx, source: number, creation: any): boolean
	if type(creation) ~= "table" then return false end
	for key in creation do
		if not table.find({ "request_id", "orch_session_id", "owner_id", "generation", "authority_namespace", "source_nonce" }, key) then return false end
	end
	local owner, data = alias(cx, source), snapshot(cx, source)
	local result = workflow_node(cx, source, "orchestration-result", "orchplus.orchestration.result")
	local controller = owner and owner.owners and owner.owners.controller
	return result ~= nil and result.ok == true and result.code == "controller_granted" and controller ~= nil
		and owner.session_closed == false and owner.authority_namespace == creation.authority_namespace
		and owner.alias_nonce == creation.source_nonce and owner.orch_session_id == creation.orch_session_id
		and result.request_id == creation.request_id and result.orch_session_id == creation.orch_session_id
		and result.owner_id == creation.owner_id and result.generation == creation.generation
		and controller.owner_id == creation.owner_id and controller.generation == creation.generation
		and controller.alias_nonce == creation.source_nonce and result.owner ~= nil
		and result.owner.owner_id == creation.owner_id and result.owner.generation == creation.generation
		and result.owner.owner_active == true and result.owner.phase == "active"
		and result.owner.pane_binding ~= nil and result.owner.pane_binding.host_pane_id == owner.host_pane_id
		and result.owner.pane_binding.alias_nonce == creation.source_nonce
		and data ~= nil and data.authority_namespace == creation.authority_namespace
		and data.orch_session_id == creation.orch_session_id and data.source_nonce == creation.source_nonce
		and data.owner_id == creation.owner_id and data.owner_generation == creation.generation
		and data.controller_phase == "active" and data.session_control ~= nil
		and data.session_control.phase == "open" and data.session_control.admitted == nil
end
ui_api.connect = function(cx: WindowCx, source: number, creation: any, done: any)
	if not ui_api.creation_current(cx, source, creation) then return done(cx, false, "The created orchestration's native ownership changed. Nothing was initialized.") end
	setup_ui.start(cx, source, "migration_update", nil, { creation = plain(creation), done = done })
	arm()
end
setup_api.transport = function(cx: WindowCx, source: number, origin: any)
	return acquire_bridge(cx, source, origin, "setup")
end
setup_api.surface = function(cx: WindowCx, endpoint: any, block: string, role: string, key: string?, maximum: number?)
	if type(endpoint) == "table" then return peer_surface(cx, endpoint, block, role, key, maximum) end
	return surface_node(cx, endpoint, block, role, key, maximum)
end
setup_api.event, setup_api.ack = relay_event, relay_ack
setup_api.migration_jobs = {}
setup_api.migration_source_fields = { protocol = true, phase = true, spawn_namespace = true, authority_namespace = true,
	authority_revision = true, admission_cursor = true, sessions = true, session_progress = true, compatibility = true, qualification = true }
setup_api.migrate = function(cx: WindowCx, source: number, origin: any, operation: any, done: any)
	local function refused(message: string) done(cx, nil, message) end
	if setup_api.migration_jobs[source] then return refused("An exact update operation is still pending. Its outcome must be inspected before another operation.") end
	local count = 0; for _ in setup_api.migration_jobs do count += 1 end
	if count >= 32 then return refused("Other update operations still have retained outcomes. Inspect those connections before opening another update.") end
	if type(operation) ~= "table" or not table.find({ "source", "bootstrap", "inspect", "prepare", "finish" }, operation.operation)
		or not codec.validate_dispatch_setup_origin(origin) or not scoped_pane(cx, source, origin)
		or origin.window_epoch ~= incarnation or origin.window_key ~= cx:window_key()
		or origin.native_session_id ~= tostring(cx.sessions:current().id)
		or origin.window_host_id ~= tostring(cx.hosts:current().id) or cx.hosts:current().state ~= "connected" then
		return refused("The update no longer has its exact native host, window and session.")
	end
	for key in operation do if not table.find({ "operation", "expected", "peer", "creation" }, key) then return refused("Unsupported update operation fields.") end end
	if operation.operation == "source" then
		if operation.expected ~= nil or operation.peer ~= nil or operation.creation ~= nil then return refused("Source inspection cannot carry a mutation proof.") end
	elseif operation.operation == "bootstrap" then
		if operation.expected ~= nil or operation.peer ~= nil or not ui_api.creation_current(cx, source, operation.creation) then
			return refused("First use requires the exact current native creation and controller result; no existing state was changed.")
		end
	elseif operation.creation ~= nil or type(operation.expected) ~= "table" or type(operation.peer) ~= "table"
		or not codec.validate_dispatch_migration_qualification(operation.peer.qualification, "orch")
		or not codec.validate_dispatch_migration_qualification({ proof = operation.expected, selection = operation.peer.qualification.selection }, "spawn") then
		return refused("The update requires complete, current source proofs from both owners.")
	end
	local metadata = relay_index(cx, source, "spawn")
	if not metadata or metadata.host_pane_id ~= origin.host_pane_id then return refused("The real orchestration connection is not readable. No update was submitted.") end
	if operation.operation ~= "source" and operation.operation ~= "bootstrap" and (operation.peer.host_pane_id ~= metadata.host_pane_id
		or operation.peer.source_nonce ~= metadata.source_nonce) then
		return refused("The captured ORCH source belongs to another native view. No update was submitted.")
	end
	local existing = bridge_by_source[tostring(source) .. ":setup"]
	if operation.operation == "source" and existing and not relay_live(cx, existing) then
		if existing.relay_endpoint ~= metadata.relay_endpoint or existing.relay_boot ~= metadata.relay_boot
			or existing.source_nonce ~= metadata.source_nonce or not same_origin(existing.origin, origin) then
			local retained = 0; for _ in retained_relays do retained += 1 end
			if retained >= 32 then return refused("Earlier connections still require reconciliation; no identity was replaced.") end
			retained_relays[existing.relay_boot .. ":" .. existing.lane_id] = existing
			bridge_by_source[tostring(source) .. ":setup"] = nil
		elseif not existing.retiring then
			existing.rebinding = { bind_id = existing.bind_id, at = awake_now() }
			cx.session:event(source, { ev = "action", id = "main", act = "spawn_relay", value = tern.json.encode({
				schema = 1, source_nonce = existing.source_nonce, relay_endpoint = existing.relay_endpoint, relay_boot = existing.relay_boot,
				lane_id = existing.lane_id, peer_boot = existing.peer_boot, act = "rebind", bytes = tern.json.encode(existing.origin) }) })
		end
	end
	local request = { schema = 2, origin = "orchplus", op = "catalog", request_id = dispatch_id(), action_id = dispatch_id(), setup_origin = plain(origin) }
	local job = { origin = plain(origin), source_nonce = metadata.source_nonce, request = request, operation = plain(operation),
		started = awake_now(), done = done, relay_endpoint = metadata.relay_endpoint, relay_boot = metadata.relay_boot }
	setup_api.migration_jobs[source] = job
	-- This publishes the canonical native witness only; it does not request a catalog or mutate SPAWN.
	cx.session:event(source, { ev = "action", id = "main.setup-index", act = "setup-command", value = tern.json.encode({
		kind = "catalog_request", source_nonce = metadata.source_nonce, request_id = request.request_id,
		setup_origin = origin, request = request }) })
	arm()
end
setup_api.migration_tick = function(cx: WindowCx)
	local function finish(source: number, job: any, projection: any?, message: string?, proof: any?, code: string?)
		if setup_api.migration_jobs[source] ~= job then return end
		setup_api.migration_jobs[source] = nil
		job.done(cx, projection, message, proof, code)
	end
	for source, job in setup_api.migration_jobs do
		if not scoped_pane(cx, source, job.origin) or job.origin.window_epoch ~= incarnation or job.origin.window_key ~= cx:window_key()
			or job.origin.native_session_id ~= tostring(cx.sessions:current().id)
			or job.origin.window_host_id ~= tostring(cx.hosts:current().id) or cx.hosts:current().state ~= "connected" then
			finish(source, job, nil, "The native update context changed. Any submitted phase remains unconfirmed; inspect its retained source before continuing.")
			continue
		end
		local metadata = relay_index(cx, source, "spawn")
		if not metadata then continue end -- An unreadable/hidden panel is not proof that its submitted operation failed.
		if metadata.source_nonce ~= job.source_nonce or metadata.relay_endpoint ~= job.relay_endpoint or metadata.relay_boot ~= job.relay_boot then
			finish(source, job, nil, "The orchestration host restarted. No update phase was repeated; inspect the retained sources.")
			continue
		end
		if not job.sent and awake_now() - job.started > 30000 then
			finish(source, job, nil, "The update connection was not ready before the bounded wait ended. No mutation was submitted.")
			continue
		end
		local endpoint = job.endpoint or acquire_bridge(cx, source, job.origin, "setup")
		if not endpoint then continue end
		job.endpoint = endpoint
		local value, _, lane = relay_live(cx, endpoint)
		if not value or (job.peer_boot and lane and lane.peer_boot ~= job.peer_boot) then
			finish(source, job, nil, "SPAWN's native connection changed during the update. Its outcome remains unconfirmed; no phase was replayed.")
			continue
		end
		if not lane or not lane.peer_boot then continue end
		if not job.sent then
			if job.operation.operation == "bootstrap" and not ui_api.creation_current(cx, source, job.operation.creation) then
				finish(source, job, nil, "The created orchestration changed before first-use authorization. Nothing was initialized.")
				continue
			end
			local _, published = surface_node(cx, source, BLOCK, "orchplus.setup.request", "setup-catalog-request", 8192)
			if not published or not same_policy(decoded(published, 8192), job.request) then continue end
			local stage = { schema = 1, request_json = published, operation = job.operation.operation,
				expected = job.operation.expected, peer = job.operation.peer, creation = job.operation.creation }
			local bytes = tern.json.encode(stage)
			if #bytes > 65536 then finish(source, job, nil, "The complete source proofs exceed the update transport bound; nothing was submitted."); continue end
			if relay_event(cx, endpoint, { act = "migration", value = bytes }) then
				job.sent, job.request_json, job.peer_boot = true, published, lane.peer_boot
			elseif value.held or lane.held then
				finish(source, job, nil, "The connection retains unresolved work. Review that uncertainty before updating; no phase was submitted.")
			end
			continue
		end
		local _, bytes = peer_surface(cx, endpoint, BRIDGE_BLOCK, "spawn.dispatch.state", "spawn-dispatch-state", 65536)
		local current = if bytes then decoded(bytes, 65536) else nil
		local result = if type(current) == "table" then current.migration_response else nil
		if type(result) ~= "table" or result.request_json ~= job.request_json or result.operation ~= job.operation.operation then
			if awake_now() - job.started > 30000 then
				finish(source, job, nil, "The submitted update outcome is still unconfirmed. Inspect both retained sources; this phase was not retried.")
			end
			continue
		end
		local valid = true
		for key in result do if not table.find({ "request_json", "operation", "response", "source" }, key) then valid = false end end
		local response = result.response
		if not valid or type(response) ~= "table" or type(response.ok) ~= "boolean" then
			finish(source, job, nil, "The update returned an invalid correlated result. Inspect both sources; no phase was repeated."); continue
		end
		local receipt = endpoint.reads and endpoint.reads.current
		if not receipt or receipt.route ~= "spawn.current" or receipt.incarnation ~= job.peer_boot
			or receipt.binding ~= endpoint.relay_endpoint .. ":" .. endpoint.lane_id then
			finish(source, job, nil, "The update result has no exact current native source receipt. No subsequent phase ran.")
			continue
		end
		local proof = { relay_endpoint = endpoint.relay_endpoint, lane_id = endpoint.lane_id,
			peer_boot = job.peer_boot, receipt = { id = receipt.id, incarnation = receipt.incarnation } }
		if not response.ok then
			for key in response do if not table.find({ "ok", "error", "disposition", "code" }, key) then valid = false end end
			if response.code ~= nil then
				local source_code = job.operation.operation == "source" and table.find({ "source_absent", "source_unavailable" }, response.code)
				local bootstrap_code = job.operation.operation == "bootstrap" and table.find({ "bootstrap_refused", "bootstrap_uncertain" }, response.code)
				if not source_code and not bootstrap_code or response.code == "source_absent" and response.disposition ~= "refused" then valid = false end
			end
			if not valid or type(response.error) ~= "string" or #response.error == 0 or #response.error > 512
				or not table.find({ "refused", "uncertain" }, response.disposition) then
				finish(source, job, nil, "The update did not provide a valid outcome. Inspect retained state; no mutation was retried.")
			else finish(source, job, nil, response.error .. (if response.disposition == "uncertain" then " Its outcome remains uncertain; no phase was retried." else ""), proof, response.code) end
			continue
		end
		for key in response do if not table.find({ "ok", "value" }, key) then valid = false end end
		local projection = result.source
		for key in current do
			if not setup_api.migration_source_fields[key] and key ~= "migration_response" and key ~= "control_response" then valid = false end
		end
		if type(projection) == "table" then
			for key in projection do if not setup_api.migration_source_fields[key] then valid = false end end
		end
		if type(response.value) == "table" then
			for key in response.value do if key ~= "proof" and key ~= "selection" and key ~= "compatibility" then valid = false end end
		else valid = false end
		if not valid or type(projection) ~= "table" or projection.migration_response ~= nil
			or not codec.validate_dispatch_migration_qualification(projection.qualification, "spawn")
			or not same_policy(response.value.proof, projection.qualification.proof)
			or not same_policy(response.value.selection, projection.qualification.selection)
			or (response.value.compatibility ~= nil and not codec.validate_dispatch_compatibility(response.value.compatibility))
			or current.protocol ~= projection.protocol or current.phase ~= projection.phase
			or current.spawn_namespace ~= projection.spawn_namespace or current.authority_revision ~= projection.authority_revision
			or not same_policy(current.qualification, projection.qualification)
			or projection.spawn_namespace ~= projection.qualification.proof.candidate_namespace
			or projection.authority_revision ~= projection.qualification.proof.source_revision
			or projection.protocol ~= projection.qualification.proof.protocol
			then
			finish(source, job, nil, "SPAWN did not return matching complete source evidence for this update. No subsequent phase ran.")
			continue
		end
		finish(source, job, projection, nil, proof)
	end
end
setup_api.flow = function(cx: WindowCx, source: number) return workflow_node(cx, source, "workflow-index", "orchplus.workflow") end
setup_api.origin = ui_api.origin
setup_api.save_policy = function(cx: WindowCx, source: number, origin: any, previous: any, values: any, done: any)
	setup_api.saves = setup_api.saves or {}
	if setup_api.saves[source] then return done(cx, { ok = false, code = "save_pending", message = "The previous settings save is still awaiting its result. Your draft is retained." }) end
	local sent, id, refusal = pcall(save_policy, cx, source, origin, previous, { policy = values })
	if not sent then return done(cx, { ok = false, code = "save_unconfirmed", message = "The native save could not confirm submission. Your draft is retained; inspect current settings before another save." }) end
	if not id then return done(cx, refusal) end
	setup_api.saves[source] = { request_id = id, done = done, origin = origin, started = awake_now() }
end
guide_control = dispatch_control
-- Operator intents: a clicked window-side control (views.luau `dispatch_link`/`assistance`) is
-- published by its controller block as `main.operator-intent` and runs at most once per
-- (source_nonce, serial) in this VM, then is settled host-side. Only the window that owns the
-- controller's origin acts; others leave it silently. A host-block click names no window (every
-- client of one window key shares key, session and focus), so a fresh incarnation continues only
-- through the palette commands below. Assistance follows the same rule while the host stamps a live
-- origin's window into the intent (`window`); unstamped, any window showing the controller may assist.
local INTENT_KINDS = { dispatch = true, assist = true, setup = true }
local ASSIST_KINDS = { inspect = true, recheck = true, reveal = true, stop = true }
local intents_seen = fifo(256)
local function stamped_window(cx: WindowCx, source: number, window: any): boolean
	local host = host_for(cx, source)
	return type(window) == "table" and host ~= nil and window.window_key == cx:window_key() and window.window_epoch == incarnation
		and window.native_session_id == tostring(cx.sessions:current().id) and window.window_host_id == tostring(host.id)
end
local function native_page_current(cx: WindowCx, source: number, request: any): boolean
	if not table.find({ "readiness", "defaults" }, request.command) or type(request.native_window) ~= "string" or #request.native_window > 256
		or utf8.len(request.native_window) == nil or request.native_window:find("%z") or request.native_window ~= cx:window_key() then return false end
	for key in request do if not table.find({ "command", "source_nonce", "native_window", "authority_namespace", "expected_revision" }, key) then return false end end
	local host, current = host_for(cx, source), cx.hosts:current()
	local pane, session = cx.session:pane(source), cx.sessions:current()
	if not host or host.state ~= "connected" or current.state ~= "connected" or host.id ~= current.id
		or not pane or not scanned_controller(pane, tab_sessions(cx), session)
		or cx.session:view(source, { nodes = 1, depth = 0, max_chars = 1 }) == nil then return false end
	local owner = alias(cx, source)
	return owner ~= nil and owner.alias_nonce == request.source_nonce
end
local function intent_step(cx: WindowCx, source: number, current: boolean)
	local node, bytes = surface_node(cx, source, BLOCK, "orchplus.intent", "operator-intent", codec.LIMITS.logical)
	if not node or not bytes then return end
	local intent = codec.strict_decode(bytes, codec.LIMITS.logical)
	if type(intent) ~= "table" or intent.version ~= 1 or not INTENT_KINDS[intent.kind] or type(intent.source_nonce) ~= "string"
		or type(intent.serial) ~= "string" or #intent.serial > 256 or type(intent.request) ~= "table"
		or intent.request.source_nonce ~= intent.source_nonce then return end
	local request = intent.request
	local native_page = intent.kind == "setup" and request.native_window ~= nil
	local id = intent.source_nonce .. "|" .. intent.serial
	if intents_seen.values[id] then return end
	-- A human control is consumed once, not deferred until the user returns to its
	-- session. Only its addressed window may settle this refusal; peers leave it alone.
	if not native_page and not current then
		local data = snapshot(cx, source)
		local binding = intent.window or (data and data.command_cursor and data.command_cursor.origin)
		if binding then
			if binding.window_key ~= cx:window_key() or binding.window_epoch ~= incarnation then return end
		else
			-- A fresh/unowned source cannot stamp a window yet. Its exact native alias
			-- can prove only which source to refuse, never permission to execute later.
			local bridge, host = alias(cx, source), host_for(cx, source)
			if not bridge or bridge.alias_nonce ~= intent.source_nonce or not host or host.state ~= "connected" then return end
		end
		intents_seen.put(id, true)
		cx.session:event(source, { ev = "action", id = node.id, act = "operator-intent-done",
			value = tern.json.encode({ source_nonce = intent.source_nonce, serial = intent.serial }) })
		cx:toast("info", "ORCH+ control refused", "The current native input session changed. Nothing ran; choose the control again in its session.")
		return
	end
	intents_seen.put(id, true)
	-- Another native window may be consuming its own addressed entry concurrently.
	if native_page and request.native_window ~= cx:window_key() then return end
	if native_page and not native_page_current(cx, source, request) then
		cx.session:event(source, { ev = "action", id = node.id, act = "operator-intent-done",
			value = tern.json.encode({ source_nonce = intent.source_nonce, serial = intent.serial }) })
		cx:toast("info", "ORCH+ settings entry refused", "The native window, host, session or visible source changed. Nothing ran; this page entry will not retry.")
		return
	end
	if intent.kind == "setup" then
		if intent.window ~= nil and not stamped_window(cx, source, intent.window) then return end
	elseif intent.kind == "dispatch" then
		local origin = origin_now(cx, source, request)
		local stamped = intent.window == nil or stamped_window(cx, source, intent.window)
		if not stamped or not origin or not (current_origin(cx, source, origin)
			or (table.find({ "bridge_reconcile", "close_session", "forget_session", "forget_continue" }, request.command) and closing_context(cx, source, origin, true))) then
			local data = snapshot(cx, source)
			local cursor = data and data.command_cursor and data.command_cursor.origin
			local binding = intent.window or cursor
			local addressed = binding == nil
			if binding and binding.window_key == cx:window_key() and binding.native_session_id == tostring(cx.sessions:current().id) then
				addressed = binding.window_epoch == incarnation
				if not addressed and cursor then
					-- Refusal only: the obsolete stamp must be exactly the source's still-
					-- recorded cursor. It never grants this fresh VM execution authority.
					addressed = true
					for _, key in { "window_key", "window_epoch", "native_session_id", "window_host_id" } do
						if binding[key] ~= cursor[key] then addressed = false; break end
					end
				end
			end
			local bridge, host = alias(cx, source), host_for(cx, source)
			if addressed and bridge and bridge.alias_nonce == intent.source_nonce and host and host.state == "connected"
				and (binding == nil or binding.window_host_id == tostring(host.id)) then
				cx.session:event(source, { ev = "action", id = node.id, act = "operator-intent-done",
					value = tern.json.encode({ source_nonce = intent.source_nonce, serial = intent.serial }) })
			end
			return
		end
	elseif request.version ~= 2 or (request.target ~= "controller" and request.target ~= "orchestrator") or not ASSIST_KINDS[request.kind]
		or (intent.window ~= nil and not stamped_window(cx, source, intent.window)) then
		return
	end
	-- Settle before acting: a failing or prompting control is never re-run from the same intent.
	cx.session:event(source, { ev = "action", id = node.id, act = "operator-intent-done",
		value = tern.json.encode({ source_nonce = intent.source_nonce, serial = intent.serial }) })
	if intent.kind == "dispatch" then cleanup_interaction(cx, source) end
	if native_page and request.command == "readiness" and cx.hosts:current().kind == "remote" then
		cx:toast("info", "ORCH+ optional readiness", "This exercise requires the local execution host. Navigation did not change setup or readiness.")
		return
	end
	if intent.kind == "setup" then
		if request.command == "new_orchestration" then conversation_ui.create(cx, source)
		elseif request.command == "readiness" then readiness_ui.start(cx, source, request)
		else setup_ui.start(cx, source, request.command, request) end
	elseif intent.kind == "dispatch" then
		dispatch_control(cx, source, request)
	else
		local performed, failure = pcall(assist, cx, source, request)
		if not performed then cx:toast("error", "ORCH+ assistance failed", tostring(failure)) end
	end
end
consume_intents = function(cx: WindowCx)
	local host, session = cx.hosts:current(), cx.sessions:current()
	local membership = tab_sessions(cx)
	for _, pane in cx.session:panes() do
		if pane.block == BLOCK then
			local current = host.state == "connected" and table.find(host.panes, pane.pane) ~= nil and scanned_controller(pane, membership, session)
			local ok, failure = pcall(intent_step, cx, pane.pane, current)
			if not ok then cx:toast("error", "ORCH+ control failed", tostring(failure):sub(1, 300)) end
		end
	end
end
tern.command({ id = "open", title = "ORCH+", icon = "flow", group = "ORCH+", run = function(cx: WindowCx) open(cx) end })
tern.command({ id = "new_orchestration", title = "ORCH+ New orchestration…", icon = "flow", group = "ORCH+", run = function(cx: WindowCx) conversation_ui.create(cx) end })
tern.command({ id = "switch_orchestration", title = "ORCH+ Switch orchestration…", icon = "flow", group = "ORCH+", run = function(cx: WindowCx) open(cx) end })
local function setup_palette(cx: WindowCx, command: string)
	local host, session = cx.hosts:current(), cx.sessions:current()
	local membership, candidates = tab_sessions(cx), {}
	for _, pane in panes_on(cx, host) do
		if pane.block == BLOCK and pane.tab and membership[pane.tab] == session.id then table.insert(candidates, pane.pane) end
	end
	local source = if #candidates == 1 then candidates[1] else nil
	if not source then
		for _, pane in candidates do if pane == cx.session:focused() then source = pane end end
	end
	if source then
		cx.layout:focus(source)
		if command == "defaults" then
			local owner = alias(cx, source)
			if owner then cx.session:event(source, { ev = "action", id = "main", act = "defaults-open",
				value = tern.json.encode({ source_nonce = owner.alias_nonce, native_window = cx:window_key() }) }) end
		elseif command == "readiness" then readiness_ui.start(cx, source)
		else setup_ui.start(cx, source, command) end
	else
		open(cx, true)
		cx:toast("info", "ORCH+ settings", "Choose Default settings in this view to configure future orchestrations without creating one. Existing ownership is never reset.")
	end
end
tern.command({ id = "orch_setup", title = "ORCH+ Settings", icon = "flow", group = "ORCH+", run = function(cx: WindowCx) setup_palette(cx, "wizard") end })
tern.command({ id = "installation_defaults", title = "ORCH+ Default settings", icon = "flow", group = "ORCH+", run = function(cx: WindowCx) setup_palette(cx, "defaults") end })
tern.command({ id = "orch_readiness", title = "ORCH+ Optional readiness exercise", icon = "flow", group = "ORCH+", run = function(cx: WindowCx) setup_palette(cx, "readiness") end })
-- Palette continuation: the one input Tern attributes to the window it happened in. Targets this
-- session's only controller with a recorded owner, else the focused one; dispatch_control re-validates it.
local function palette_continuation(cx: WindowCx, command: string, title: string)
	local host, session = cx.hosts:current(), cx.sessions:current()
	local membership, candidates = tab_sessions(cx), {}
	if host.state == "connected" then
		for _, pane in panes_on(cx, host) do
			local data = if scanned_controller(pane, membership, session) then snapshot(cx, pane.pane) else nil
			if data and data.owner_id then table.insert(candidates, { pane = pane.pane, data = data }) end
		end
	end
	local chosen = if #candidates == 1 then candidates[1] else nil
	if not chosen and #candidates > 1 then
		local focused = cx.session:focused()
		for _, candidate in candidates do if candidate.pane == focused then chosen = candidate end end
	end
	if not chosen then
		cx:toast("error", title, if #candidates == 0 then "No ORCH+ controller with a recorded owner is shown here. Open ORCH+, select the existing orchestration, then use Advanced → Recover this view for review only after verified retirement. This does not admit SPAWN or resume workers."
			else "Several ORCH+ controllers are shown here: focus the one to recover, then run the command again.")
		return
	end
	dispatch_control(cx, chosen.pane, { command = command, source_nonce = chosen.data.source_nonce, orch_session_id = chosen.data.orch_session_id,
		authority_namespace = chosen.data.authority_namespace, expected_revision = chosen.data.authority_revision })
end
tern.command({ id = "continue_controller", title = "ORCH+ Continue controller in this window", icon = "flow", group = "ORCH+",
	run = function(cx: WindowCx) palette_continuation(cx, "continue_controller", "ORCH+ Continue controller in this window") end })
-- Settings remain a deliberate secondary view, never the conversation's landing page. The status-bar
-- launcher opens Config only: no controller, activation, admission, continuation or dispatch happens here.
tern.command({ id = "status_open", title = "ORCH+ Config", icon = "flow", group = "ORCH+", run = function(cx: WindowCx) open(cx, true) end })
tern.chrome.status(function(_pane: StatusPaneInfo) return { { icon = "flow", text = "ORCH+", tone = "muted", command = "plugin.orchplus.status_open" } } end)
tern.on("window_start", function(cx: WindowCx) status_prompt.ensure(cx, "orchplus"); arm() end)
tern.on("title", function(_event: any, cx: WindowCx)
	pane_pushes = {}
	local host, session = cx.hosts:current(), cx.sessions:current()
	if host and session and host.state == "connected" then
		local membership = tab_sessions(cx)
		for _, pane in panes_on(cx, host) do
			if scanned_controller(pane, membership, session) then push_config_panes(cx, pane.pane, host, session, membership) end
		end
	end
	arm()
end)
arm() -- Also rearms when reloaded without window_start; one timer owns observation and dispatch.
-- Diagnostic: how many entries this window VM's bookkeeping tables retain.
local function bookkeeping(): any
	local function size(t: any): number local n = 0; for _ in t do n += 1 end; return n end
	local per_worker = 0
	for _, scan in scans do per_worker += size(scan.observed) + size(scan.watermarks) + size(scan.next_poll) + size(scan.startup_until) + size(scan.paced or {}) + size(scan.focused_until or {}) end
	return { executed = size(executed), auto_reconcile = size(auto_reconcile), auto_readback = size(auto_readback.values), held_actions = size(held_actions),
		sweep_attempts = size(sweep_attempts), scan_workers = per_worker, watched = #settle_order }
end
require("./updater/window").register({ name = "ORCH+", dir = "ORCH+", title_prefix = "ORCH+ " })
return { native_observation = native_observation, schedule = schedule, intents = consume_intents, bookkeeping = bookkeeping, owned_origin = native_scope.owned_origin, owner_send = native_scope.owner_send,
	capacity_confirms = native_scope.capacity_confirms, fresh_intent = fresh_intent }
