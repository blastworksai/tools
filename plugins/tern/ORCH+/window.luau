--!strict
local BLOCK = "orchplus.orchestrator"
local codec = require("./transport")
local dispatch = require("./dispatch")
local quota = require("./quota")
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
-- Only role-keyed native plugin text nodes are consumed; no screen/transcript path exists. `whole`
-- also refuses clipped (`more`) nodes.
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
		or bridge.revision ~= request.revision then return false end
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
		message = message, observation = observation, revision = request.revision,
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
		cx:pick({ placeholder = "Stop this recorded controller? Ownership will NOT be cleared.", items = {
			{ label = "Cancel — keep owner running", stop = false },
			{ label = "Close recorded controller " .. request.owner_id, detail = describe(pane), stop = true },
		} }):next(function(choice: any, err: string?, next_cx: WindowCx?)
			if next_cx == nil or choice == nil or err ~= nil or choice.stop ~= true then return end
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
local function new_view(cx: WindowCx, config: boolean?)
	-- Opening a view is inert: registration selection and admission remain host UI actions.
	if cx:new_block(BLOCK, if config then { "config" } else {}, "beside") == nil then
		cx:toast("error", "ORCH+ unavailable", "This host has no Ready ORCH+ plugin.")
	end
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
			{ label = "Open an unbound view in this session", detail = "No logical registration or controller ownership is created.", new_view = true },
		}
		for _, entry in existing do
			local pane = entry.pane
			local bridge = alias(cx, pane.pane)
			table.insert(items, {
				label = (if entry.uncertain then "Inspect unknown-session view " else "Open this-session view ") .. tostring(pane.pane),
				detail = (if entry.uncertain then "Parked/restored membership is ambiguous. " else "")
					.. (if bridge ~= nil then tostring(bridge.orch_session_id or "registration not selected") else "alias unavailable; inspect explicitly"),
				pane = pane.pane,
			})
		end
		cx:pick({ placeholder = "Choose an ORCH+ view explicitly", items = items }):next(function(choice: any, _err: string?, next_cx: WindowCx?)
			if choice == nil or next_cx == nil then return end
			local now = next_cx.sessions:current()
			if now.id ~= current.id or now.host ~= current.host then
				next_cx:toast("error", "ORCH+ routing changed", "The current session changed during selection. Open ORCH+ again.")
				return
			end
			if choice.new_view then new_view(next_cx, config); return end
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
	local node, bytes = surface_node(cx, pane, BLOCK, "orchplus.dispatch", if action_id then "dispatch-action-" .. action_id else nil)
	if not bytes then return nil, nil end
	local value = decoded(bytes, 8192)
	if value and value.action then
		if action_id and value.action.action_id ~= action_id then return nil, nil end
		local _, request_bytes = surface_node(cx, pane, BLOCK, "orchplus.request", if action_id then "dispatch-request-" .. action_id else nil)
		local request = if request_bytes then decoded(request_bytes, 8192) else nil
		if not request or request.action_id ~= value.action.action_id then return nil, nil end
		value.action.request = request; value.action.request_bytes = request_bytes
	end
	return value, node
end
local function origin_now(cx: WindowCx, source: number, request: any): any?
	local data = snapshot(cx, source)
	local host = host_for(cx, source); local current = cx.sessions:current(); local pane = cx.session:pane(source)
	local membership = tab_sessions(cx)
	if not data or not data.owner_id or data.source_nonce ~= request.source_nonce or data.orch_session_id ~= request.orch_session_id
		or not host or host.state ~= "connected" or cx.hosts:current().id ~= host.id
		or not pane or pane.tab == nil or membership[pane.tab] ~= current.id then return nil end
	return { logical_session_id = data.orch_session_id, owner_id = data.owner_id, owner_generation = data.owner_generation,
		host_pane_id = data.host_pane_id, alias_nonce = data.source_nonce, window_key = cx:window_key(), window_epoch = incarnation,
		native_session_id = tostring(current.id), window_host_id = tostring(host.id) }
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
local function notice(cx: WindowCx, source: number, nonce: string, message: string, level: string?, title: string?)
	local _, node = snapshot(cx, source)
	if node then cx.session:event(source, { ev = "action", id = node.id, act = "dispatch-notice", value = tern.json.encode({ source_nonce = nonce, message = message }) }) end
	cx:toast((level or "error") :: any, title or "ORCH+ dispatch", message)
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
-- Exact-entry prompts pre-check the reducer's bounds; the host reducer validates again.
local POLICY_FIELDS = {
	rollover_threshold_pct = { label = "Rollover threshold %", minimum = 1, maximum = 99 },
	poll_ms = { label = "Poll interval ms", minimum = 1000, maximum = 60000 },
	heartbeat_ms = { label = "Heartbeat ms", minimum = 5000, maximum = 3600000 },
	stale_ms = { label = "Stale after ms", minimum = 5000, maximum = 86400000 },
	quota_reserve_pct = { label = "Quota reserve %", minimum = 0, maximum = 99 },
	quota_max_age_ms = { label = "Quota evidence max age ms", minimum = 60000, maximum = 900000 },
	concurrency_limit = { label = "Concurrent routed launches (0 = no limit)", minimum = 0, maximum = 32 },
	loop_cap = { label = "Loop cap (attempts per workflow loop)", minimum = 1, maximum = 10 },
	review_rounds = { label = "Review rounds", minimum = 1, maximum = 2 },
	stale_claim_min = { label = "Stale claim minutes (0 = off)", minimum = 0, maximum = 1440 },
}
-- Request IDs this window incarnation sent: a refusal is this window's own evidence only when it
-- answers one of them, so another window's (or older incarnation's) refusal never holds a driver.
local issued = fifo(512)
local function send_command(cx: WindowCx, source: number, origin: any, command: string, fields: any?, operator: boolean?): string?
	if not (if command == "continue_controller" then current_context(cx, source, origin) else current_origin(cx, source, origin)) then return nil end
	local data, node = snapshot(cx, source); if not node then return nil end
	local event = { kind = "dispatch", request_id = dispatch_id(), orch_session_id = origin.logical_session_id, origin = origin,
		controller_pane = tostring(source), command = command }
	for k, v in fields or {} do event[k] = v end
	if command ~= "claim" and command ~= "result" and command ~= "lost" then
		local retained = command_cursors[source]
		local seq = if retained and same_origin(retained.origin, origin) then retained.seq else 0
		local committed = data.command_cursor
		if committed then seq = math.max(seq, committed.seq) end
		event.command_seq = seq + 1
		command_cursors[source] = { origin = origin, seq = event.command_seq }
	end
	if command == "observe" then event.observation_seq = dispatch_serial end
	local bytes = tern.json.encode(event)
	if #bytes > 8192 then
		notice(cx, source, origin.alias_nonce, if command == "policy" then "This setting is too large to send — shorten it. Nothing changed."
			else "Task request exceeds the 8192-byte native bridge limit; shorten the explicit assignment. Nothing was queued.")
		return nil
	end
	cx.session:event(source, { ev = "action", id = node.id, act = if operator then "dispatch-operator-command" else "dispatch-command", value = bytes })
	issued.put(event.request_id, true)
	return if current_origin(cx, source, origin) then event.request_id else nil
end
local function workflow_node(cx: WindowCx, source: number, key: string, role: string): any?
	-- workflow-index carries the policy with three bounded routing allowlists; 64 KiB covers them.
	local _, bytes = surface_node(cx, source, BLOCK, role, key, codec.LIMITS.logical)
	return if bytes then decoded(bytes, codec.LIMITS.logical) else nil
end
local function worker_now(cx: WindowCx, source: number, worker_id: string): any?
	local worker = workflow_node(cx, source, "workflow-worker-" .. worker_id, "orchplus.worker")
	return if worker and worker.worker_id == worker_id then worker else nil
end
-- The pane, when it sits on its connected host and native session exactly as `scope` records them.
local function scoped_pane(cx: WindowCx, pane: number?, scope: any, membership: any?): any?
	local info = if pane then cx.session:pane(pane) else nil
	local host = if pane then host_for(cx, pane) else nil
	if not info or not host or host.state ~= "connected" or tostring(host.id) ~= scope.window_host_id
		or info.tab == nil or tostring((membership or tab_sessions(cx))[info.tab]) ~= scope.native_session_id then return nil end
	return info
end
local function native_observation(cx: WindowCx, source: number, worker: any): (string, string?, any?, string?)
	local binding, origin = worker.pane_binding, worker.origin_binding
	if not binding or not origin or not current_origin(cx, source, origin)
		or binding.window_key ~= cx:window_key() or binding.window_epoch ~= incarnation
		or binding.native_session_id ~= origin.native_session_id or binding.window_host_id ~= origin.window_host_id then
		return "unknown", "Awaiting the exact authorized window/session binding; after reload run ORCH+ Continue controller in this window from the palette. Restored numeric pane IDs are not identity.", nil
	end
	local target = tonumber(binding.pane_id)
	local pane = scoped_pane(cx, target, binding)
	if not pane then
		return "unknown", "Bound pane unavailable, moved or parked without current session evidence; absence is not exit.", nil
	end
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
	if pane.exited ~= nil then return "exited", nil, pane end
	return "unknown", "Unrecognized terminal: lifecycle only; no native input or readiness inferred. A verified worker-poll capability is required for replies.", pane
end
local drivers: any = {}
local executed: any = {} -- grant_id -> true: set-before-send markers (pruned only once settled).
local held_actions: any = {}
-- Per-action bookkeeping (`executed`, `auto_reconcile`, `held_actions`) is pruned only on positive
-- evidence from the action's own controller pane that it settled; one watched action per tick.
local settle_watch: any, settle_order: any, settle_cursor = {}, {}, 0
local function watch_settle(source: number, action_id: string, grant_id: string?)
	local entry = settle_watch[action_id]
	if entry == nil then entry = { grants = {} }; settle_watch[action_id] = entry; table.insert(settle_order, action_id) end
	entry.source = source
	if grant_id then entry.grants[grant_id] = true end
end
local bridge_by_source: any = {}
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
	local scoped = snapshot(cx, entry.source, action_id)
	local a = if scoped then scoped.action else nil
	if not a or a.action_id ~= action_id then return end
	local terminal = a.phase == "complete" or a.phase == "resolved"
	local live = if a.claim and not terminal then a.claim.grant_id else nil
	-- The live grant's marker survives while claimed, uncertain or backpressured under it.
	for grant in entry.grants do if grant ~= live then executed[grant] = nil; entry.grants[grant] = nil end end
	local reconcile = auto_reconcile[action_id]
	if reconcile and reconcile.grant_id ~= live then auto_reconcile[action_id] = nil end
	if terminal then held_actions[action_id] = nil end
	if next(entry.grants) == nil and auto_reconcile[action_id] == nil and not held_actions[action_id] then
		settle_watch[action_id] = nil; table.remove(settle_order, settle_cursor); settle_cursor -= 1
	end
end
-- A claim refused with `full` is pre-effect (still `ready`, never granted): it resumes with awake
-- backoff under the same host claim rules, at most CAPACITY_RETRIES times, then holds for the owner.
local CAPACITY_RETRY_MS = 5000
local CAPACITY_RETRIES = 120
local capacity_waits: any = {}
-- Host commits can lag the tick: a claim is re-sent only with backoff while its action still looks
-- `ready` (the host refuses duplicates), so a re-send only covers a lost window event.
local CLAIM_RETRY_MS = { 1000, 2000, 4000, 8000 }
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
local function capacity_hold(source: number, action_id: string, stale: any)
	local wait = capacity_waits[action_id] or { attempts = 0 }
	claims_in_flight[action_id] = nil -- The refused claim is answered; the capacity backoff owns the retry.
	wait.attempts += 1; wait.next_at = awake_now() + CAPACITY_RETRY_MS; wait.stale = stale; wait.source = source
	if wait.attempts > CAPACITY_RETRIES then capacity_waits[action_id] = nil; held_actions[action_id] = true; watch_settle(source, action_id)
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
local function recheck_hold(source: number, action_id: string)
	local wait = recheck_waits[action_id] or { attempts = 0 }
	wait.next_at = awake_now() + CAPACITY_RETRY_MS; wait.source = source
	recheck_waits[action_id] = wait
end
local start_driver: any = nil -- Assigned after the observation timer helpers.
-- Reload recovery: pending read-only SPAWN owner_status probes and the last observed owner state.
local guides: any = {}
local owner_states: any = {}
-- Fenced never-launched work: a pending read-only SPAWN `status` per controller (see withdraw_step).
local withdrawals: any = {}
-- USAGE capacity: one reader per controller and its bound `usage.capacity` pane (lost on reload;
-- the sweep and reader_step reuse/close earlier incarnations' panes).
local readers: any = {}
local usage_by_source: any = {}
local validations: any = {}
local start_reader: any = nil
local reader_step: any = nil
-- SPAWN bridges: one `spawn.dispatch` pane carries one read at a time. This window binds at most
-- one per controller source and lane (`bridge_by_source`, lost on reload), first adopting an inert
-- bridge of the same controller, alias and window in the same session (SPAWN_BRIDGE v1 lease: not
-- held, live or busy, and no current driver or probe on it). Earlier incarnations' inert bridges are
-- closed one per pass, keeping BRIDGE_SPARES in the bridge tab; unreadable leases are never reused
-- or closed. Bridges are never moved or parked (a moved pane's surface reads nil, a parked one has
-- no provable session), so each opens where it stays, in the session's "SPAWN bridges" tab.
local BRIDGE_BLOCK = "spawn.dispatch"
local BRIDGE_LEASE_PREFIX = "SPAWN_BRIDGE v1 "
local BRIDGE_TAB = "SPAWN bridges"
local BRIDGE_SCAN_LIMIT = 24 -- Lease reads per adoption or sweep pass.
local BRIDGE_SPARES = 2 -- Idle earlier-incarnation bridges in the bridge tab kept per present controller.
local BRIDGE_SWEEP_MS = 1000 -- Awake interval between passes; each pass closes at most one pane.
local BRIDGE_SKIP_MS = 30000 -- A lease that forbids closing is not re-read for this long.
local bridge_sweep_at = 0
local bridge_skip: any = {}
local function bridge_lease(cx: WindowCx, pane: number): any?
	local _, bytes = surface_node(cx, pane, BRIDGE_BLOCK, "spawn.dispatch.lease", "spawn-dispatch-lease", 2048)
	if not bytes or bytes:sub(1, #BRIDGE_LEASE_PREFIX) ~= BRIDGE_LEASE_PREFIX then return nil end
	local lease = codec.strict_decode(bytes:sub(#BRIDGE_LEASE_PREFIX + 1), 2048)
	if type(lease) ~= "table" or lease.schema ~= 1 or type(lease.held) ~= "boolean" or type(lease.live) ~= "boolean" or type(lease.busy) ~= "boolean" then return nil end
	local owner = lease.owner
	if owner ~= nil and (type(owner) ~= "table" or type(owner.controller_pane) ~= "string" or type(owner.alias_nonce) ~= "string"
		or type(owner.window_key) ~= "string" or type(owner.window_epoch) ~= "string") then return nil end
	return lease
end
local function bridge_inert(lease: any?): boolean
	return lease ~= nil and lease.owner ~= nil and not lease.held and not lease.live and not lease.busy
end
-- A bridge a current driver or owner probe holds is in use until that driver/probe ends, whatever
-- its lease says: adoption and the sweep test this before reading any lease.
local function bridge_in_use(pane: number): boolean
	for _, driver in drivers do if driver.bridge == pane then return true end end
	for _, guide in guides do if guide.bridge == pane then return true end end
	for _, probe in withdrawals do if probe.bridge == pane then return true end end
	return false
end
-- Tabs holding only bridges and USAGE capacity readers (the bridge tab), each with its lowest pane.
local function bridge_tabs(cx: WindowCx): any
	local only, lowest = {}, {}
	for _, row in cx.session:panes() do
		if row.tab ~= nil then
			if only[row.tab] == nil then only[row.tab] = true end
			if row.block ~= BRIDGE_BLOCK and row.block ~= quota.BLOCK then only[row.tab] = false end
			if lowest[row.tab] == nil or row.pane < lowest[row.tab] then lowest[row.tab] = row.pane end
		end
	end
	local tabs = {}
	for tab, bridges in only do if bridges then tabs[tab] = lowest[tab] end end
	return tabs
end
-- Bridge-tab panes first (adopting them keeps the controller's tab clear), then by pane id.
local function bridge_order(tabs: any): (any, any) -> boolean
	return function(a: any, b: any): boolean
		local ta, tb = tabs[a.tab] ~= nil, tabs[b.tab] ~= nil
		if ta ~= tb then return ta end
		return a.pane < b.pane
	end
end
-- The controller's native session (nil when unknown) and the current tab membership.
local function controller_session(cx: WindowCx, source: number): (any, any)
	local controller, membership = cx.session:pane(source), tab_sessions(cx)
	return (if controller and controller.tab ~= nil then membership[controller.tab] else nil), membership
end
-- Open a bridge (or USAGE reader) where it will stay: beside a bridge-tab pane of the controller's
-- session, else in a new named bridge tab. A new block that lands outside the controller's session
-- was never sent anything: it is closed and reopened beside the controller.
local function open_bridge(cx: WindowCx, source: number, block: string, args: any): number?
	local session, membership = controller_session(cx, source)
	if session == nil then return cx:new_block(block, args, "beside", { focus = false, target = source }) end
	local target = nil
	for tab, pane in bridge_tabs(cx) do
		if membership[tab] == session and (target == nil or pane < target) then target = pane end
	end
	if target ~= nil then return cx:new_block(block, args, "beside", { focus = false, target = target }) end
	local created = cx:new_block(block, args, "tab", { focus = false })
	local info = if created ~= nil then cx.session:pane(created) else nil
	if info == nil or info.tab == nil then return created end
	if tab_sessions(cx)[info.tab] == session then
		pcall(function() cx.layout:name_tab(info.tab :: number, BRIDGE_TAB) end)
		return created
	end
	cx.layout:close(created :: number)
	return cx:new_block(block, args, "beside", { focus = false, target = source })
end
-- A USAGE capacity pane a reader request is in flight on, or bound to a controller.
local function usage_in_use(pane: number): boolean
	for _, reader in readers do if reader.pane == pane then return true end end
	for _, bound in usage_by_source do if bound == pane then return true end end
	return false
end
-- The reader pane: an idle `usage.capacity` pane already in the session's bridge tab (read-only, so
-- reuse is safe), else a new one opened like a bridge.
local function acquire_usage(cx: WindowCx, source: number): number?
	local session, membership = controller_session(cx, source)
	if session ~= nil then
		local tabs, best = bridge_tabs(cx), nil
		for _, row in cx.session:panes() do
			if row.block == quota.BLOCK and row.tab ~= nil and tabs[row.tab] ~= nil and membership[row.tab] == session
				and not usage_in_use(row.pane) and (best == nil or row.pane < best) then best = row.pane end
		end
		if best ~= nil then return best end
	end
	return open_bridge(cx, source, quota.BLOCK, {})
end
local function acquire_bridge(cx: WindowCx, source: number, origin: any, lane: string): number?
	local key = tostring(source) .. ":" .. lane
	local membership = tab_sessions(cx)
	local mapped = bridge_by_source[key]
	local bound = if mapped ~= nil then scoped_pane(cx, mapped, origin, membership) else nil
	if bound and bound.block == BRIDGE_BLOCK then return mapped end
	bridge_by_source[key] = nil -- Closed or moved away: this lane binds a bridge afresh.
	local candidates = {}
	for _, row in cx.session:panes() do
		if row.block == BRIDGE_BLOCK and row.tab ~= nil and not bridge_in_use(row.pane) then table.insert(candidates, row) end
	end
	table.sort(candidates, bridge_order(bridge_tabs(cx)))
	local reads = 0
	for _, row in candidates do
		if reads >= BRIDGE_SCAN_LIMIT then break end
		local pane = row.pane
		if scoped_pane(cx, pane, origin, membership) then
			reads += 1
			-- An unreadable lease (legacy SPAWN, or a pane an earlier build moved) is never adopted.
			local lease = bridge_lease(cx, pane)
			local owner = if lease then lease.owner else nil
			if bridge_inert(lease) and owner.controller_pane == tostring(source) and owner.alias_nonce == origin.alias_nonce
				and owner.window_key == origin.window_key then
				-- An idle bridge of another lane moves to this one; a lane never shares a live bridge.
				for other, bound in bridge_by_source do if bound == pane then bridge_by_source[other] = nil end end
				bridge_by_source[key] = pane; bridge_skip[pane] = nil
				return pane
			end
		end
	end
	local created = open_bridge(cx, source, BRIDGE_BLOCK, { tern.json.encode({ schema = 1, controller_pane = tostring(source),
		alias_nonce = origin.alias_nonce, window_key = origin.window_key, window_epoch = incarnation }) })
	if created == nil then return nil end
	bridge_by_source[key] = created
	return created
end
-- One bounded pass per BRIDGE_SWEEP_MS awake closes at most one inert earlier-incarnation pane. An
-- unreadable lease keeps its pane: it might still be the bridge of a requested authorization.
local function bridge_sweep(cx: WindowCx)
	local now = awake_now()
	if now < bridge_sweep_at then return end
	bridge_sweep_at = now + BRIDGE_SWEEP_MS
	local host, current = cx.hosts:current(), cx.sessions:current()
	if host == nil or current == nil or host.state ~= "connected" then return end
	local membership = tab_sessions(cx)
	local tabs = bridge_tabs(cx)
	-- Earlier incarnations' idle USAGE readers close, except one unbound bridge-tab spare kept for
	-- reuse while no reader is bound.
	local spare_ok = next(usage_by_source) == nil
	local usage_extra = nil
	for _, row in panes_on(cx, host) do
		if row.block == quota.BLOCK and row.tab ~= nil and membership[row.tab] == current.id and not usage_in_use(row.pane) then
			if tabs[row.tab] ~= nil and spare_ok then
				spare_ok = false
			elseif usage_extra == nil or row.pane > usage_extra then
				usage_extra = row.pane
			end
		end
	end
	if usage_extra ~= nil then cx.layout:close(usage_extra); return end
	local bound = {}
	for _, pane in bridge_by_source do bound[pane] = true end
	local candidates, present = {}, {}
	for _, row in panes_on(cx, host) do
		if row.block == BRIDGE_BLOCK and row.tab ~= nil and membership[row.tab] == current.id and not bound[row.pane] and not bridge_in_use(row.pane) then
			table.insert(candidates, row); present[row.pane] = true
		end
	end
	for pane in bridge_skip do if not present[pane] then bridge_skip[pane] = nil end end
	table.sort(candidates, bridge_order(tabs))
	local window_key = cx:window_key()
	local controllers, spares, reads = {}, {}, 0
	for _, row in candidates do
		local pane = row.pane
		if (bridge_skip[pane] or 0) > now then continue end
		if reads >= BRIDGE_SCAN_LIMIT then return end
		reads += 1
		local lease = bridge_lease(cx, pane)
		local owner = if lease then lease.owner else nil
		-- Unreadable, held, live or busy leases, another window's bridges and this incarnation's own stay.
		if not bridge_inert(lease) or owner.window_key ~= window_key or owner.window_epoch == incarnation then
			bridge_skip[pane] = now + BRIDGE_SKIP_MS
			continue
		end
		local id = owner.controller_pane .. "|" .. owner.alias_nonce
		if controllers[id] == nil then
			local controller = tonumber(owner.controller_pane)
			local info = if controller then cx.session:pane(controller) else nil
			local found = if info and info.tab ~= nil and membership[info.tab] == current.id then alias(cx, controller :: number) else nil
			controllers[id] = found ~= nil and found.alias_nonce == owner.alias_nonce
		end
		-- Reload spares wait in the bridge tab; stale bridges beside the controller are closed.
		if controllers[id] and tabs[row.tab] ~= nil and (spares[id] or 0) < BRIDGE_SPARES then
			spares[id] = (spares[id] or 0) + 1
			continue
		end
		cx.layout:close(pane)
		return
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
-- Config v4 editors for list, map, record and text keys (booleans, auto_approve_kinds and
-- default_work_source are host Config draft edits). Each async answer re-reads the saved policy and
-- saves one whole key only while Config is unchanged; the host reducer validates every value again.
local BOARD_LANES = { queued = "Queued", running = "Running", review = "Review", done = "Done" }
local GUIDANCE_ROLES = { builder = "Builder", reviewer = "Reviewer", release_manager = "Release manager", labeller = "Labeller", coordinator = "Coordinator" }
local RECORD_FIELDS = { release_manager_record = "Release manager record", labeller_record = "Labeller record" }
-- A release manager must carry release-manager-v1 (D5 signer rule); SPAWN grants landing to no other mailbox.
local RECORD_NEEDS = { release_manager_record = "release-manager-v1" }
local PATH_FIELDS = { board_path = "Board file", inbox_folder = "Intake inbox folder" }
local function trimmed(value: string): string return value:match("^%s*(.-)%s*$") or "" end
local function one_line(value: string, maximum: number): boolean return #value <= maximum and not value:find("%c") end
local function text_ok(value: string, maximum: number): boolean return #value <= maximum and not value:find("[%z\1-\8\11\12\14-\31\127]") end
local function absolute_path(value: string): boolean
	return #value > 0 and one_line(value, 512) and (value:sub(1, 1) == "/" or value:match("^%a:[\\/]") ~= nil)
end
local function relative_path(value: string): boolean
	if #value == 0 or not one_line(value, 256) or value:find("^[/\\]") or value:match("^%a:") then return false end
	for part in value:gmatch("[^/\\]+") do if part == ".." then return false end end
	return true
end
local function slug(value: string, maximum: number): boolean return #value <= maximum and value:match("^[a-z][a-z0-9%-]*$") ~= nil end
local function present(value: any): boolean return type(value) == "string" and value ~= "" end
local function list_of(value: any): any
	local out = tern.json.array()
	if type(value) == "table" and value ~= tern.json.null then for _, item in value do table.insert(out, plain(item)) end end
	return out
end
local function map_of(value: any): any
	local out = {}
	if type(value) == "table" and value ~= tern.json.null then for key, item in value do if type(key) == "string" then out[key] = plain(item) end end end
	return out
end
local STALE_CONFIG = "Config changed while the editor was open. Reopen Config; the newer policy was not overwritten."
-- Every policy save carries the host-projected digest of the saved policy (workflow-index
-- `policy_sha256`), never the full policy, so it fits the 8192-byte bridge.
local function save_policy(cx: WindowCx, source: number, origin: any, previous: any, fields: any)
	if not current_origin(cx, source, origin) then return end
	local current = workflow_node(cx, source, "workflow-index", "orchplus.workflow")
	if not current or type(current.policy_sha256) ~= "string" or not same_policy(current.policy, previous) then
		notice(cx, source, origin.alias_nonce, STALE_CONFIG)
		return
	end
	fields.expected_policy_sha256 = current.policy_sha256
	send_command(cx, source, origin, "policy", fields, true)
end
local function save_policy_key(cx: WindowCx, source: number, origin: any, previous: any, key: string, value: any)
	save_policy(cx, source, origin, previous, { policy = { [key] = value } })
end
local function ask_text(cx: WindowCx, source: number, origin: any, value: string?, placeholder: string, action: string, done: (WindowCx, string) -> ())
	cx:prompt({ value = value, placeholder = placeholder, action = action }):next(function(text: string?, err: string?, fresh: WindowCx?)
		if not fresh or text == nil or err or not current_origin(fresh, source, origin) then return end
		done(fresh, text)
	end)
end
-- Prompt each { value, placeholder, action, check } step in order. `check` stores its entry or
-- returns a refusal, which ends the flow with a notice ending in `suffix`.
local function ask_steps(cx: WindowCx, source: number, origin: any, steps: any, suffix: string, done: (WindowCx) -> (), index: number?)
	local position = index or 1
	local step = steps[position]
	if not step then return done(cx) end
	ask_text(cx, source, origin, step[1], step[2], step[3], function(fresh, text)
		local problem = step[4](text)
		if problem then return notice(fresh, source, origin.alias_nonce, problem .. suffix) end
		ask_steps(fresh, source, origin, steps, suffix, done, position + 1)
	end)
end
-- One exact-entry Config value; `parse` returns the value to save, or nil and the refusal.
local function ask_policy_value(cx: WindowCx, source: number, origin: any, previous: any, field: string, value: string, placeholder: string, action: string, parse: (string) -> (any, string?))
	ask_text(cx, source, origin, value, placeholder, action, function(fresh, text)
		local current = workflow_node(fresh, source, "workflow-index", "orchplus.workflow")
		if not current or not same_policy(current.policy, previous) then return notice(fresh, source, origin.alias_nonce, STALE_CONFIG) end
		local parsed, problem = parse(text)
		if parsed == nil then return notice(fresh, source, origin.alias_nonce, problem :: string) end
		save_policy_key(fresh, source, origin, previous, field, parsed)
	end)
end
local function ask_choice(cx: WindowCx, source: number, origin: any, placeholder: string, items: any, done: (WindowCx, any) -> ())
	table.insert(items, 1, { label = "Cancel — nothing changes" })
	cx:pick({ placeholder = placeholder, items = items }):next(function(choice: any, err: string?, fresh: WindowCx?)
		if not fresh or not choice or err or choice.value == nil or not current_origin(fresh, source, origin) then return end
		done(fresh, choice.value)
	end)
end
-- Record pickers list every eligible, enabled record of the loaded SPAWN catalog ("catalog-index"),
-- not the priority-capped routing-index, that offers capability `need` (when given) and is not in `exclude`.
local function pick_record(cx: WindowCx, source: number, origin: any, placeholder: string, allow_none: boolean, exclude: any, done: (WindowCx, any) -> (), need: string?)
	local index = index_node(cx, source, "orchplus.catalog", "catalog-index")
	local items, listed = {}, (if index then index.records else {})
	for _, record in listed do
		if type(record) == "table" and type(record.id) == "string" and not exclude[record.id]
			and (need == nil or (type(record.capabilities) == "table" and table.find(record.capabilities, need) ~= nil)) then
			local detail = "SPAWN record " .. record.id .. " / revision " .. tostring(record.revision)
				.. (if type(record.provider) == "string" then " · " .. record.provider else "") .. (if type(record.account_label) == "string" then " · " .. record.account_label else "")
			table.insert(items, { label = record.id, detail = detail, value = record.id })
		end
	end
	if #listed == 0 or (#items == 0 and not allow_none) then
		notice(cx, source, origin.alias_nonce, if #listed == 0 then "Load the SPAWN catalog first; pickers list only its eligible, enabled records. Nothing changed."
			else "No other eligible, enabled record of the loaded catalog can take this role. Nothing changed.")
		return
	end
	if allow_none then table.insert(items, 1, { label = "None — clear this record", value = "" }) end
	ask_choice(cx, source, origin, placeholder, items, done)
end
local function template_steps(cx: WindowCx, source: number, origin: any, previous: any, list: any, position: number)
	local draft = plain(list[position] or {})
	local others = {}
	for index, other in list do if index ~= position and type(other) == "table" and type(other.id) == "string" then others[other.id] = true end end
	local original = if type(list[position]) == "table" then list[position].id else nil
	ask_steps(cx, source, origin, {
		{ tostring(draft.id or ""), "Template id: lowercase letters, digits and hyphens, starting with a letter (≤32)", "next: title", function(raw)
			local id = trimmed(raw)
			if not slug(id, 32) or others[id] then return "Template id must be a new [a-z][a-z0-9-] id of at most 32 characters." end
			if original ~= nil and id ~= original then return "A template id cannot change; add a new template and remove this one." end
			draft.id = id
		end },
		{ tostring(draft.title or ""), "Template title (1–80 characters)", "next: prompt", function(raw)
			local title = trimmed(raw)
			if #title == 0 or not one_line(title, 80) then return "Template title must be 1–80 characters on one line." end
			draft.title = title
		end },
		{ tostring(draft.prompt or "{input}"), "Template prompt (≤4096 characters, exactly one {input})", "next: output path", function(prompt)
			local _, inputs = prompt:gsub("{input}", "")
			if not text_ok(prompt, 4096) or inputs ~= 1 then return "Template prompt must be at most 4096 characters and contain {input} exactly once." end
			draft.prompt = prompt
		end },
		{ tostring(draft.output or ""), "Output: relative path ≤256 characters (no leading /, drive or ..)", "next: next template", function(raw)
			local output = trimmed(raw)
			if not relative_path(output) then return "Template output must be a relative path of at most 256 characters without .. segments." end
			draft.output = output
		end },
		{ if present(draft.next) then tostring(draft.next) else "", "Next template id (empty = none)", "next: class", function(raw)
			local next_id = trimmed(raw)
			if #next_id > 0 and not others[next_id] then return "Next template must name another existing template id, or stay empty." end
			draft.next = next_id
		end },
		{ tostring(draft.class or ""), "Work class for this template (empty = none; [a-z][a-z0-9-] ≤32)", "save template", function(raw)
			local class = trimmed(raw)
			if #class > 0 and not slug(class, 32) then return "Template class must be [a-z][a-z0-9-] of at most 32 characters, or empty." end
			draft.class = if #class > 0 then class else nil
		end },
	}, " Nothing changed.", function(fresh) save_policy(fresh, source, origin, previous, { template_put = draft }) end)
end
-- Returns true when the field is a Config v4 list/map/record/text key handled here.
local function policy_editor(cx: WindowCx, source: number, origin: any, request: any, previous: any): boolean
	local field, item, op = request.field, request.item, request.op
	local function refuse(fresh: WindowCx, message: string) notice(fresh, source, origin.alias_nonce, message .. " Nothing changed.") end
	local function save(fresh: WindowCx, value: any) save_policy_key(fresh, source, origin, previous, field, value) end
	local position = if type(request.index) == "number" and request.index >= 1 and request.index % 1 == 0 then request.index else nil
	-- List keys: remove one exact entry (by `at`, else by item value), or add one below the bound.
	local function list_edit(maximum: number, noun: string, at: number?, add: (any) -> ())
		local current = list_of(previous[field])
		if op == "remove" then
			local index = at or (if type(item) == "string" then table.find(current, item) else nil)
			if index and current[index] then table.remove(current, index); save(cx, current) end
		elseif #current >= maximum then refuse(cx, "At most " .. tostring(maximum) .. " " .. noun .. ".")
		else add(current) end
	end
	if field == "family_map" then
		local map = map_of(previous.family_map)
		local function set_family(fresh: WindowCx, record_id: string)
			ask_text(fresh, source, origin, tostring(map[record_id] or ""), "Provider family for " .. record_id .. " ([a-z][a-z0-9-] ≤24; empty removes)", "save family", function(next_cx, raw)
				local family = trimmed(raw)
				if #family == 0 then map[record_id] = nil
				elseif not slug(family, 24) then return refuse(next_cx, "Family must be [a-z][a-z0-9-] of at most 24 characters.")
				else map[record_id] = family end
				local count = 0; for _ in map do count += 1 end
				if count > 24 then return refuse(next_cx, "The family map holds at most 24 records.") end
				save(next_cx, map)
			end)
		end
		if type(item) == "string" then set_family(cx, item)
		else pick_record(cx, source, origin, "Set the provider family of which record?", false, {}, set_family) end
	elseif field == "reviewer_records" then
		list_edit(8, "reviewer records", nil, function(current)
			-- The release manager signs landings and must never be the approving reviewer (D5).
			local exclude = {}; for _, record_id in current do exclude[record_id] = true end
			if present(previous.release_manager_record) then exclude[previous.release_manager_record] = true end
			pick_record(cx, source, origin, "Add which reviewer record?", false, exclude, function(fresh, record_id)
				table.insert(current, record_id); save(fresh, current) -- Owner order is kept.
			end)
		end)
	elseif RECORD_FIELDS[field] then
		local exclude = {}
		if field == "release_manager_record" then for _, record_id in list_of(previous.reviewer_records) do exclude[record_id] = true end end
		pick_record(cx, source, origin, RECORD_FIELDS[field] .. ": " .. (if present(previous[field]) then tostring(previous[field]) else "none")
			.. (if RECORD_NEEDS[field] then " (records offering " .. RECORD_NEEDS[field] .. ", not a reviewer record)" else ""), true, exclude, save, RECORD_NEEDS[field])
	elseif field == "checkout_roots" then
		list_edit(8, "checkout roots", nil, function(current)
			ask_text(cx, source, origin, "", "Checkout root: absolute path (≤512 characters)", "add root", function(fresh, raw)
				local path = trimmed(raw)
				if not absolute_path(path) then return refuse(fresh, "A checkout root must be an absolute path of at most 512 characters.") end
				if table.find(current, path) then return refuse(fresh, "That checkout root is already listed.") end
				table.insert(current, path); save(fresh, current)
			end)
		end)
	elseif PATH_FIELDS[field] then
		local shown = if present(previous[field]) then tostring(previous[field]) else ""
		ask_text(cx, source, origin, shown, PATH_FIELDS[field] .. ": absolute path ≤512 characters (empty clears)", "save " .. PATH_FIELDS[field], function(fresh, raw)
			local path = trimmed(raw)
			if #path == 0 then return save(fresh, "") end
			if not absolute_path(path) then return refuse(fresh, PATH_FIELDS[field] .. " must be an absolute path of at most 512 characters.") end
			save(fresh, path)
		end)
	elseif field == "board_lanes" then
		if type(item) ~= "string" or not BOARD_LANES[item] then return true end
		local lanes = map_of(previous.board_lanes)
		ask_text(cx, source, origin, tostring(lanes[item] or BOARD_LANES[item]), "Board lane title for " .. BOARD_LANES[item] .. " work (1–64 characters)", "save lane title", function(fresh, raw)
			local title = trimmed(raw)
			if #title == 0 or not one_line(title, 64) then return refuse(fresh, "A lane title must be 1–64 characters on one line.") end
			lanes[item] = title; save(fresh, lanes)
		end)
	elseif field == "routes" then
		list_edit(16, "routes", position, function(current)
			ask_text(cx, source, origin, "", "Work class to route ([a-z][a-z0-9-] ≤32)", "next: record", function(fresh, raw)
				local class = trimmed(raw)
				if not slug(class, 32) then return refuse(fresh, "A work class must be [a-z][a-z0-9-] of at most 32 characters.") end
				for _, route in current do if type(route) == "table" and route.class == class then return refuse(fresh, "Class " .. class .. " already has a route; remove it first.") end end
				pick_record(fresh, source, origin, "Route " .. class .. " work to which record?", false, {}, function(next_cx, record_id)
					table.insert(current, { class = class, record_id = record_id }); save(next_cx, current)
				end)
			end)
		end)
	elseif field == "role_guidance" then
		if type(item) ~= "string" or not GUIDANCE_ROLES[item] then return true end
		local guidance = map_of(previous.role_guidance)
		ask_text(cx, source, origin, tostring(guidance[item] or ""), GUIDANCE_ROLES[item] .. " guidance (≤1024 characters; guidance only — restrict tools in the SPAWN record's own CLI flags)", "save guidance", function(fresh, text)
			if not text_ok(text, 1024) then return refuse(fresh, "Role guidance must be at most 1024 characters without control characters.") end
			save_policy(fresh, source, origin, previous, { role_guidance_put = { role = item, text = text } })
		end)
	elseif field == "templates" then
		local current = list_of(previous.templates)
		if op == "remove" then
			local removed = if position then current[position] else nil
			if not removed then return true end
			for _, other in current do
				if other ~= removed and type(other) == "table" and other.next == removed.id then
					refuse(cx, "Template " .. tostring(other.id) .. " chains to " .. tostring(removed.id) .. "; change its next template first.")
					return true
				end
			end
			save_policy(cx, source, origin, previous, { template_remove = removed.id })
		elseif op == "edit" then
			if position and current[position] then template_steps(cx, source, origin, previous, current, position) end
		elseif #current >= 16 then refuse(cx, "At most 16 templates.")
		else template_steps(cx, source, origin, previous, current, #current + 1) end
	else
		return false
	end
	return true
end
-- Contract G assignment fields entered after the task text. Bounds mirror dispatch.luau
-- config.worker_fields; the reducer validates again. Check argv is split into words here and
-- never passed through a shell: whitespace separates words, '…' or "…" quotes a word verbatim.
local function assignment_text(value: string, maximum: number): boolean
	return #value > 0 and #value <= maximum and utf8.len(value) ~= nil and not value:find("%z")
end
local function parse_files(raw: string): (any?, string?)
	local files = tern.json.array()
	for part in raw:gmatch("[^,\n]+") do
		local path = part:match("^%s*(.-)%s*$") or ""
		if #path > 0 then
			if not assignment_text(path, 256) then return nil, "Each declared file or glob must be valid UTF-8 of at most 256 bytes." end
			if table.find(files, path) == nil then table.insert(files, path) end
		end
	end
	if #files > 64 then return nil, "At most 64 declared files or globs." end
	return if #files > 0 then files else nil, nil
end
-- One check per line (or separated by an unquoted ';'): `id: argv words`.
local function parse_checks(raw: string): (any?, string?)
	if utf8.len(raw) == nil then return nil, "Checks must be valid UTF-8." end
	local checks, seen = tern.json.array(), {}
	local entries, current, quote = {}, {}, nil
	for _, code in utf8.codes(raw) do
		local ch = utf8.char(code)
		if quote == nil and (ch == "\n" or ch == ";") then table.insert(entries, table.concat(current)); current = {}
		else
			if quote == nil and (ch == "'" or ch == '"') then quote = ch elseif ch == quote then quote = nil end
			table.insert(current, ch)
		end
	end
	if quote ~= nil then return nil, "A check has an unterminated " .. quote .. " quote." end
	table.insert(entries, table.concat(current))
	for _, entry in entries do
		local line = entry:match("^%s*(.-)%s*$") or ""
		if #line > 0 then
			local check_id, rest = line:match("^([A-Za-z0-9_%-]+)%s*:%s*(.*)$")
			if not check_id or #check_id > 96 then return nil, "Each check is `id: argv words` with an id of letters, digits, _ or - (≤96): " .. line:sub(1, 80) end
			if seen[check_id] then return nil, "Check id " .. check_id .. " is declared twice." end
			seen[check_id] = true
			local argv, word, in_word, q = tern.json.array(), {}, false, nil
			for _, code in utf8.codes(rest) do
				local ch = utf8.char(code)
				if q ~= nil then
					if ch == q then q = nil else table.insert(word, ch) end
				elseif ch == "'" or ch == '"' then q = ch; in_word = true
				elseif ch:match("^%s$") then
					if in_word then table.insert(argv, table.concat(word)); word = {}; in_word = false end
				else table.insert(word, ch); in_word = true end
			end
			if in_word then table.insert(argv, table.concat(word)) end
			if #argv == 0 or #argv > 16 then return nil, "Check " .. check_id .. " needs 1–16 argv words." end
			for _, arg in argv do
				if not assignment_text(arg, 512) then return nil, "Check " .. check_id .. " has an empty or over-512-byte argv word." end
			end
			table.insert(checks, { check_id = check_id, argv = argv })
		end
	end
	if #checks > 16 then return nil, "At most 16 checks." end
	return if #checks > 0 then checks else nil, nil
end
local function public_frame(body: any): string
	local bytes = tern.json.encode(body)
	return "SPAWN_DISPATCH v1 " .. tern.json.encode({ schema = 1, op = body.op, request_id = body.request_id, complete = true,
		body_bytes = #bytes, body_sha256 = codec.sha256(bytes), body_json = bytes })
end
local function drop(driver: any) drivers[driver.key or driver.source] = nil end
-- Stop driving a retained claim: an executing driver marks it lost (uncertain) and tells the owner;
-- an automatic read of an already uncertain action only ends, leaving its owner control unchanged.
local function abandon(cx: WindowCx, driver: any, uncertain: boolean, action_id: string, executor: string, grant_id: string, message: string)
	if not (driver.auto and uncertain) then
		send_command(cx, driver.source, driver.origin, "lost", { action_id = action_id, executor = executor, grant_id = grant_id })
		notice(cx, driver.source, driver.origin.alias_nonce, message)
	end
	drop(driver)
end
-- A read-only SPAWN query on the controller's behalf, sent on its bridge's response node.
local function send_query(cx: WindowCx, bridge: number, node: any, source: number, op: string, binding: any, generation: any, target: string?): any
	local query = { schema = 1, origin = "orchplus", op = op, request_id = dispatch_id(), action_id = dispatch_id(),
		origin_binding = binding, controller_pane = tostring(source), controller_generation = generation, target_request_id = target }
	cx.session:event(bridge, { ev = "action", id = node.id, act = op, value = tern.json.encode(query) })
	return query
end
local SETTLING = { "resolved", "claimed", "launching", "pending" }
local function advance(cx: WindowCx, driver: any)
	-- Never switch sessions/focus to finish background work. A persisted claim stays held.
	if not current_origin(cx, driver.source, driver.origin) then drop(driver); return end
	local data, node = snapshot(cx, driver.source, driver.scope)
	if driver.command_request_id then
		local current = snapshot(cx, driver.source)
		if current and current.driver_result and current.driver_result.request_id == driver.command_request_id then
			if not driver.scope and current.driver_result.action_id then
				driver.scope = current.driver_result.action_id
				data, node = snapshot(cx, driver.source, driver.scope)
			end
			if data then data.driver_result = current.driver_result end
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
		local command_result = data.driver_result
		local matched = command_result and command_result.request_id == driver.command_request_id
		if not matched and not driver.delivery and not driver.scope then return end
		-- An owner command the host refused is always noticed with its reason, whichever branch
		-- below ends or continues this driver (the refusal row alone is replaced by later commands).
		if matched and command_result.ok == false and driver.owner_command then
			notice(cx, driver.source, driver.origin.alias_nonce, "Refused " .. tostring(command_result.command or "command") .. ": "
				.. tostring(command_result.message or command_result.code) .. " Nothing changed.")
		end
		driver.owner_command = nil
		if matched and not command_result.action_id and not driver.scope and not driver.delivery then drop(driver); return end
		driver.command_request_id = nil
		-- Unrelated workflow controls cannot strand an already captured grant/delivery.
		if matched and command_result.ok == false and (not a or a.phase == "complete") and not driver.delivery then drop(driver); return end
	end
	if a then driver.scope = a.action_id end
	local delivery = driver.delivery
	if delivery then
		local receipt = data.receipt
		if type(receipt) == "table" and receipt.action_id == delivery.action_id and receipt.grant_id == delivery.grant_id
			and receipt.response_sha256 == delivery.response_sha256 then
			driver.last_response = delivery.bytes; driver.delivery = nil
			cx.session:event(driver.source, { ev = "action", id = node.id, act = "dispatch-release-scope", value = tern.json.encode({
				source_nonce = driver.origin.alias_nonce, action_id = delivery.action_id, grant_id = delivery.grant_id, response_sha256 = delivery.response_sha256,
			}) })
			-- A committed retained outcome that leaves the effect uncertain ends this automatic read.
			if driver.auto and a and a.action_id == delivery.action_id and a.phase == "uncertain" then drop(driver); return end
		elseif outcome and outcome.action_id == delivery.action_id and outcome.grant_id == delivery.grant_id and outcome.ok == false then
			drop(driver); return -- A failed host commit is not an ACK or permission to repeat the native effect.
		else
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
			cx.session:event(driver.source, { ev = "action", id = node.id, act = "dispatch-result/" .. delivery.grant_id .. "/" .. driver.origin.window_epoch, value = delivery.bytes })
			if not current_origin(cx, driver.source, driver.origin) then drop(driver) end
			return
		end
	end
	local relevant_result = outcome and ((a and outcome.action_id == a.request.action_id
		and (outcome.grant_id == nil or (a.claim and outcome.grant_id == a.claim.grant_id)))
		or (outcome.action_id == nil and (a == nil or a.phase == "complete")))
	-- A grantless refusal is this driver's evidence only if this window sent that request. A refused
	-- duplicate claim whose sibling claim by this window already won is superseded: the driver continues.
	if relevant_result and outcome.ok == false and outcome.grant_id == nil
		and (not issued.values[outcome.request_id] or (outcome.code == "effect_already_claimed" and a and a.phase ~= "ready"
			and a.claim and a.claim.executor == incarnation)) then relevant_result = false end
	if relevant_result and ((outcome.ok == false and outcome.code ~= "pending") or outcome.code == "bridge_rejected" or outcome.code == "effect_uncertain" or outcome.code == "backpressure") then
		if a and a.phase == "ready" and outcome.ok == false and outcome.code == "full" then
			capacity_hold(driver.source, a.action_id, outcome.request_id) -- Pre-effect capacity refusal: resume when slots free.
		elseif a and a.phase == "backpressure" and outcome.code == "backpressure" then
			recheck_hold(driver.source, a.action_id) -- Definitive pre-effect refusal: bounded automatic recheck.
		elseif a then held_actions[a.action_id] = true; watch_settle(driver.source, a.action_id) end
		drop(driver); return
	end
	if relevant_result and outcome.code == "coordinator_retired" then drop(driver); return end
	if a and a.worker_id then driver.worker_id = a.worker_id end
	if driver.action_id and (not a or a.request.action_id ~= driver.action_id or a.phase == "complete") then
		driver.query = nil; driver.sent = nil; driver.action_id = nil; driver.started = nil; driver.last_response = nil; driver.require_status = nil; driver.next_status = nil
	end
	if a and a.phase ~= "ready" then claims_in_flight[a.action_id] = nil end -- Its claim was answered.
	if a == nil or a.phase == "complete" then drop(driver); return end
	local request = a.request
	local execution_origin = a.execution_origin or request.origin_binding
	-- An automatic attempt follows only the owner control's exact route for its retained claim;
	-- a changed route or phase ends the attempt instead of idling a driver.
	if driver.auto and not (a.claim and (a.phase == "uncertain" or a.phase == "claimed")
		and (a.reconciliation_only or (a.claim.executor == incarnation and request.controller_pane == tostring(driver.source)))
		and same_origin(execution_origin, driver.origin) and current_origin(cx, driver.source, execution_origin)) then
		drop(driver); return
	end
	if not same_origin(execution_origin, driver.origin) or not current_origin(cx, driver.source, execution_origin) then return end
	if a.reconciliation_only then
		driver.reconcile_action_id = request.action_id
		driver.require_status = true
	elseif request.controller_pane ~= tostring(driver.source) then return end
	if a.phase == "ready" then
		if a.reconciliation_only then return end
		if request.op == "native_wake" then
			local worker = if a.worker_id then worker_now(cx, driver.source, a.worker_id) else nil
			if not worker then return end
			local native, _reason, _pane, problem = native_observation(cx, driver.source, worker)
			if native ~= "idle" or problem then
				send_command(cx, driver.source, driver.origin, "observe", { worker_id = worker.worker_id,
					pane_binding = worker.pane_binding, native_state = native, delivery_error = problem })
				local deferred = snapshot(cx, driver.source, request.action_id)
				if (not deferred or not deferred.action or deferred.action.phase == "complete") and not driver.action_id and not driver.delivery then drop(driver) end
				return
			end
		end
		-- One claim in flight per action: no fresh-ID re-send until the backoff elapses.
		local in_flight = claims_in_flight[request.action_id]
		if in_flight and awake_now() < in_flight.next_at then return end
		local claim_fields: any = { action_id = request.action_id, executor = incarnation }
		if request.op == "launch" or request.op == "adopt" or request.op == "mailbox_provision" then
			local flow = workflow_node(cx, driver.source, "workflow-index", "orchplus.workflow")
			if not flow or not flow.policy or flow.policy.paused then return end
			-- Quota-routed work never claims while held/gated; a routed launch first has USAGE confirm the
			-- exact decision revision is still current. Unrouted work has no `routing` and claims as is.
			local worker = if a.worker_id then worker_now(cx, driver.source, a.worker_id) else nil
			local routed = if worker then worker.routing else nil
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
		local claim_id = send_command(cx, driver.source, driver.origin, "claim", claim_fields)
		if claim_id then
			local attempts = (if in_flight then in_flight.attempts else 0) + 1
			claims_in_flight[request.action_id] = { request_id = claim_id, attempts = attempts, next_at = awake_now() + retry_delay(CLAIM_RETRY_MS, attempts) }
		end
		return
	end
	if not a.claim or (not a.reconciliation_only and a.claim.executor ~= incarnation) or (a.phase ~= "claimed" and a.phase ~= "uncertain") then return end
	local function give_up(uncertain: boolean, message: string)
		abandon(cx, driver, uncertain, request.action_id, a.claim.executor, a.claim.grant_id, message)
	end
	driver.claim_executor = a.claim.executor
	capacity_waits[request.action_id] = nil
	driver.action_id = request.action_id
	driver.grant_id = a.claim.grant_id
	driver.started = driver.started or awake_now()
	if a.wake_status == "awaiting_window" then driver.started = awake_now() end -- No wake effect has begun; busy is not uncertainty.
	local expired = awake_now() - driver.started > EFFECT_DEADLINE_MS
	if expired and not executed[a.claim.grant_id] and a.phase == "claimed" and driver.reconcile_action_id ~= request.action_id then
		return give_up(false, "The effect deadline elapsed before native submission. Its exact claim remains retained; no late native effect was started.")
	end
	if driver.bridge == nil then
		driver.bridge = acquire_bridge(cx, driver.source, driver.origin, tostring(driver.worker_id or "catalog"))
		if driver.bridge == nil then
			return give_up(a.phase == "uncertain", "Missing SPAWN dispatch bridge on this host. Install/enable the compatible SPAWN package; no raw-command fallback is available.")
		end
		if not current_origin(cx, driver.source, driver.origin) then drop(driver); return end
	end
	if not scoped_pane(cx, driver.bridge, driver.origin) then
		return give_up(a.phase == "uncertain", "The bound SPAWN bridge moved or became unavailable; its retained operation was not redirected or repeated.")
	end
	local bridge_node, bytes = surface_node(cx, driver.bridge, "spawn.dispatch", "spawn.dispatch.response")
	if not bridge_node then
		driver.absent = (driver.absent or 0) + 1
		if driver.absent >= 10 then
			give_up(a.phase == "uncertain", "SPAWN bridge surface is incompatible, incomplete or clipped. Install the matching SPAWN_DISPATCH v1 bridge and inspect the retained claim.")
		end
		return
	end
	if not executed[a.claim.grant_id] and a.phase == "claimed" and driver.reconcile_action_id ~= request.action_id then
		executed[a.claim.grant_id] = true -- Set BEFORE the native event, including exceptions/lost callbacks.
		watch_settle(driver.source, request.action_id, a.claim.grant_id)
		driver.sent = true; driver.require_status = a.retry_count ~= nil; driver.last_response = nil
		cx.session:event(driver.bridge, { ev = "action", id = bridge_node.id, act = request.op, value = a.request_bytes })
		if not current_origin(cx, driver.source, driver.origin) then drop(driver) end
		return
	end
	local body = if driver.require_status and driver.query == nil then nil else dispatch.decode_response(bytes, driver.query or request)
	if body == nil and driver.query ~= nil and not driver.require_status then
		body = dispatch.decode_response(bytes, request)
		if body ~= nil then driver.query = nil end
	end
	if body and driver.query then
		if body.status == "found" and type(body.payload) == "table" and type(body.payload.outcome) == "table" then
			driver.require_status = nil
			body = body.payload.outcome
			bytes = public_frame(body)
			body = dispatch.decode_response(bytes, request)
		elseif body.status == "rejected" and body.error and body.error.code == "oversize" then
			-- An automatic attempt never takes the exact-request replay path below.
			if a.reconciliation_only or driver.auto then
				if not driver.auto then
					notice(cx, driver.source, driver.origin.alias_nonce, "Retained outcome is too large for status inspection. The old effect is not resubmitted; reconcile its exact executor explicitly.")
				end
				drop(driver); return
			end
			-- Exact retained request replay is a registry read, not a new launch permission; the direct
			-- retained outcome is read on the next turn before another status event.
			cx.session:event(driver.bridge, { ev = "action", id = bridge_node.id, act = request.op, value = a.request_bytes })
			driver.query = nil
			driver.require_status = nil
			return
		elseif body.status == "missing" and a.phase == "uncertain" and dispatch.READ_ONLY_OPS[request.op] then
			-- SPAWN never recorded this retained read: the host checks this exact status evidence and
			-- resolves it without effect. Mutating effects never take this path (`missing` stays uncertain).
			send_command(cx, driver.source, driver.origin, "read_missing", { action_id = request.action_id, executor = a.claim.executor,
				grant_id = a.claim.grant_id, query_bytes = tern.json.encode(driver.query), response_bytes = bytes })
			drop(driver); return
		else body = nil end
		driver.query = nil
		-- One SPAWN registry answer per automatic attempt: pending or unknown stays uncertain.
		if driver.auto and a.phase == "uncertain" and (body == nil or table.find(SETTLING, body.status)) then drop(driver); return end
	end
	if body and bytes == driver.last_response then body = nil end
	if body and not table.find(SETTLING, body.status) then
		if #bytes <= 8192 and current_origin(cx, driver.source, driver.origin) then
			local now = awake_now()
			driver.delivery = { action_id = request.action_id, grant_id = a.claim.grant_id, executor = a.claim.executor, bytes = bytes,
				response_sha256 = codec.sha256(bytes), started = now, replays = 0, next_replay = now + retry_delay(REPLAY_RETRY_MS, 1),
				progress = host_progress(data), progress_at = now }
			cx.session:event(driver.source, { ev = "action", id = node.id, act = "dispatch-result/" .. a.claim.grant_id .. "/" .. driver.origin.window_epoch, value = bytes })
		end
		return
	end
	-- A delayed timer first consumes an available correlated outcome: expiry limits waiting and
	-- submission, never conclusive retained evidence.
	if expired then
		return give_up(a.phase == "uncertain", "No conclusive SPAWN outcome is available after the effect deadline. The exact claim remains occupied; read its retained outcome or explicitly recover it.")
	end
	if driver.query == nil then
		if (a.wake_status ~= nil or driver.auto) and tern.now() < (driver.next_status or 0) then return end
		driver.next_status = tern.now() + 5000
		driver.query = send_query(cx, driver.bridge, bridge_node, driver.source, "status", request.origin_binding, request.controller_generation, request.request_id)
	end
end
local pane_pushes: any = {}
local function short_title(title: any): string
	-- Display only: UTF-8-safe truncation; titles are never identity.
	if type(title) ~= "string" or utf8.len(title) == nil then return "" end
	if #title <= 40 then return title end
	local stop = 0
	for position, code in utf8.codes(title) do
		local last = position + #utf8.char(code) - 1
		if last > 37 then break end
		stop = last
	end
	return title:sub(1, stop) .. "…"
end
-- While a block shows Config, push this window's agent panes in its native session and host; a
-- managed worker is named only through its exact current window binding.
local function push_config_panes(cx: WindowCx, source: number, host: any, session: any, membership: any)
	local bridge = alias(cx, source)
	if not bridge or bridge.config_open ~= true then pane_pushes[source] = nil; return end
	local managed = {}
	local flow = workflow_node(cx, source, "workflow-index", "orchplus.workflow")
	for _, worker_id in (if flow and type(flow.worker_ids) == "table" then flow.worker_ids else {}) do
		local worker = worker_now(cx, source, worker_id)
		local binding = if worker then (worker.pane_binding or worker.adopt_pane_binding) else nil
		if binding and binding.window_epoch == incarnation and binding.window_key == cx:window_key()
			and binding.native_session_id == tostring(session.id) and binding.window_host_id == tostring(host.id) then managed[binding.pane_id] = worker_id end
	end
	local rows = {}
	for _, agent in cx.agents:list() do
		local pane = cx.session:pane(agent.pane)
		local owner = host_for(cx, agent.pane)
		if agent.pane ~= source and pane and pane.tab ~= nil and membership[pane.tab] == session.id and owner and owner.id == host.id then
			local state = if table.find({ "idle", "working", "waiting_input", "exited" }, agent.state) then agent.state else "unknown"
			table.insert(rows, { pane = agent.pane, title = short_title(pane.title), state = state, worker_id = managed[tostring(agent.pane)] })
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
local scans: any = {}
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
		auto_reconcile[a.action_id] = state; watch_settle(source, a.action_id)
	end
	if state.attempts >= #AUTO_RECONCILE_DELAYS then
		if not state.reported then
			state.reported = true
			notice(cx, source, origin.alias_nonce, "Automatic read-only reconciliation found no definitive SPAWN outcome for " .. a.request.op .. " "
				.. a.action_id .. " after " .. tostring(state.attempts) .. " reads. It stays uncertain and was never repeated; use \"Read retained SPAWN outcome (never relaunch)\" or verify its executor.")
		end
		return
	end
	if awake_now() < state.next_at then return end
	if (a.request.op == "mailbox_publish_ack" or a.request.op == "mailbox_publish_reply") and a.wake_status == nil and state.attempts >= 1 and not state.readback
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
	local hour: string?, minute: string? = nil, nil
	if type(time_text) == "string" then hour, minute = time_text:match("^(%d%d):(%d%d)$") end
	if not hour then return nil, false end
	local now = os.time()
	local t: any = os.date("*t", now)
	local slot = (tonumber(hour) or 0) * 60 + (tonumber(minute) or 0)
	local current = t.hour * 60 + t.min
	if current >= slot then return os.date("%Y-%m-%d", now) :: string, current - slot > 15 end
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
-- Work sources (D10/D12, Contract K): the Start work picker, board lane writer and inbox poller. The
-- host's `*_intake` commands are idempotent on intake_id = quota.digest({kind, path, sha256}) (path =
-- board_path or inbox_folder/name; sha256 = the card's text_sha256 or the file's content sha256),
-- which serializes racing windows. This window reads the desktop board/inbox, sends intakes, is the
-- sole lane writer (cx.board:move) and archives an inbox file once accepted. Polling runs on poll_ms
-- and every hook is time-sliced inside the 50 ms window budget.
local work_sources = (function()
	local TICK_BUDGET_MS, CALLBACK_BUDGET_MS = 8, 20 -- Lua-time slices; anything left defers.
	local BOARD_ROWS, BOARD_PAGES = 500, 8
	local INBOX_PER_TICK, INBOX_MAX_BYTES, HASH_BLOCKS = 256, 32768, 32
	local RESEND_MS, RECHECK_MS = 30000, 60000
	local TAKEN = ".orchplus-taken"
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
		if not current_origin(cx, source, origin) then return end
		local flow = workflow_node(cx, source, "workflow-index", "orchplus.workflow")
		local view = intake_index(cx, source)
		if not flow or type(flow.policy) ~= "table" or flow.policy.board_path ~= b.path or not view then return end
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
		local mapped = if board and board.path == b.path and type(board.cards) == "table" then board.cards else {}
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
			if claimed[c.id] or (#missing == 0 and c.lane ~= queued) then continue end
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
		local path = flow.policy.board_path
		if type(path) ~= "string" or path == "" then s.board = nil; return end
		local b = board_state(s, path)
		local host = cx.hosts:current()
		if host.kind == "remote" and b.remote_ok ~= host.id then
			warn(cx, source, origin, "board-remote:" .. path .. ":" .. tostring(host.id), "Board source refused: this window is attached to remote host "
				.. tostring(host.name) .. ", so " .. path .. " would be read on this desktop, not the execution host. Confirm it once via Start work… → From a Tern board.")
			return
		end
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
	-- Inbox: list per poll_ms, examine ≤256 entries per tick, hash one file at a time across ticks.
	local function due(ib: any, name: string, view: any): boolean
		local lower = name:lower()
		if name:sub(1, 1) == "." or #name > 255 or name:find("[%c/\\]") or (lower:sub(-3) ~= ".md" and lower:sub(-4) ~= ".txt") then return false end
		local e = ib.files[name]
		if e == nil then return true end
		if e.archived then return false end -- Gone; the next listing forgets it.
		local now = awake_now()
		if e.hold_until and now < e.hold_until then return false end
		local rec = if e.intake_id then view.by_id[e.intake_id] else nil
		if rec and rec.state == "accepted" then return true end
		if rec then return now >= e.checked_at + RECHECK_MS end -- received/refused: notice a new version.
		return now >= (e.sent_at or 0) + RESEND_MS
	end
	local function settle_file(cx: WindowCx, source: number, origin: any, ib: any, view: any, name: string, bytes: string, sha256: string)
		local path = ib.folder .. "/" .. name
		local intake_id = derive("inbox", path, sha256)
		local old = ib.files[name]
		local e = { intake_id = intake_id, checked_at = awake_now(), sent_at = if old and old.intake_id == intake_id then old.sent_at else nil }
		ib.files[name] = e
		local rec = view.by_id[intake_id]
		if rec and rec.state == "accepted" then
			-- Archive only now: write the exact accepted bytes to .orchplus-taken, then remove the original.
			local dir = ib.folder .. "/" .. TAKEN
			local ok, failure = pcall(function()
				tern.fs.mkdir(dir)
				tern.fs.write(dir .. "/" .. intake_id .. "-" .. name, bytes)
				tern.fs.remove(path)
			end)
			if ok then ib.files[name] = { archived = true }
			else
				e.hold_until = awake_now() + RECHECK_MS
				warn(cx, source, origin, "inbox-archive:" .. intake_id, "Accepted inbox file " .. name .. " could not be archived to " .. TAKEN .. ": "
					.. tostring(failure):sub(1, 300) .. ". It is retried; it is never taken twice.")
			end
		elseif rec and rec.state == "refused" then
			warn(cx, source, origin, "inbox-refused:" .. intake_id, "Inbox file " .. name .. " was refused by the host; it stays in the inbox untaken.")
		elseif not rec and (e.sent_at == nil or awake_now() >= e.sent_at + RESEND_MS) then
			e.sent_at = awake_now()
			send_command(cx, source, origin, "inbox_intake", { name = name, content_sha256 = sha256 })
		end
	end
	-- Advances the current hash job; true when it finished (settled or dropped).
	local function run_job(cx: WindowCx, source: number, origin: any, ib: any, view: any, deadline: number): boolean
		local job = ib.job
		while not over(deadline) do
			if codec.sha256_step(job.sha, HASH_BLOCKS) then
				ib.job = nil
				local sha256 = codec.sha256_digest(job.sha)
				-- Re-read so a file replaced mid-hash is never archived or sent under a stale hash.
				local ok, again = pcall(tern.fs.read, ib.folder .. "/" .. job.name, INBOX_MAX_BYTES)
				if ok and again == job.bytes then settle_file(cx, source, origin, ib, view, job.name, job.bytes, sha256) end
				return true
			end
		end
		return false
	end
	local function inbox_tick(cx: WindowCx, source: number, origin: any, flow: any, s: any, view: any, deadline: number)
		local folder = flow.policy.inbox_folder
		if type(folder) ~= "string" or folder == "" then s.inbox = nil; return end
		if cx.hosts:current().kind == "remote" then
			-- tern.fs reads this desktop; the host reads inbox files on the execution host.
			warn(cx, source, origin, "inbox-remote:" .. folder, "Inbox " .. folder .. " is not polled: this window is attached to a remote host, and it would list the desktop folder, not the execution host's.")
			s.inbox = nil
			return
		end
		local ib = s.inbox
		if not ib or ib.folder ~= folder then ib = { folder = folder, files = {}, names = nil, cursor = 0, next_list = 0, job = nil }; s.inbox = ib end
		local now = tern.now()
		if now >= ib.next_list and (ib.names == nil or ib.cursor >= #ib.names) then
			ib.next_list = now + flow.policy.poll_ms
			local ok, names = pcall(tern.fs.list, folder)
			if not ok or type(names) ~= "table" then
				warn(cx, source, origin, "inbox-list:" .. folder, "Inbox " .. folder .. " cannot be listed: " .. tostring(names):sub(1, 300))
				return
			end
			ib.names, ib.cursor = names, 0
			local present = {}
			for _, name in names do present[name] = true end
			-- An archived name listed again is a new file version: forget it so it is hashed afresh.
			for name, e in ib.files do if not present[name] or e.archived then ib.files[name] = nil end end
		end
		local examined = 0
		while not over(deadline) do
			if ib.job then
				if not run_job(cx, source, origin, ib, view, deadline) then return end
			else
				if ib.names == nil or ib.cursor >= #ib.names or examined >= INBOX_PER_TICK then return end
				ib.cursor += 1; examined += 1
				local name = ib.names[ib.cursor]
				if type(name) == "string" and due(ib, name, view) then
					local ok, bytes = pcall(tern.fs.read, folder .. "/" .. name, INBOX_MAX_BYTES)
					if not ok or type(bytes) ~= "string" then
						ib.files[name] = { hold_until = awake_now() + RECHECK_MS, checked_at = awake_now() }
						if tern.fs.exists(folder .. "/" .. name) then
							warn(cx, source, origin, "inbox-read:" .. name, "Inbox file " .. name .. " is larger than 32 KiB or not a regular file; it stays untaken.")
						end
					else
						local sha = codec.sha256_begin()
						codec.sha256_feed(sha, bytes)
						ib.job = { name = name, bytes = bytes, sha = sha }
					end
				end
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
		-- An interrupted hash leaves its state unusable: drop the job; the file is re-hashed later.
		if not ok then
			if s.inbox then s.inbox.job = nil end
			warn(cx, source, origin, "inbox-failure:" .. tostring(failure):sub(1, 120), "Inbox polling failed: " .. tostring(failure):sub(1, 300))
		end
		-- A board on a remote host is polled only after the owner confirmed it once; a remote inbox never.
		local host = cx.hosts:current()
		local board = s.board ~= nil and (host.kind ~= "remote" or s.board.remote_ok == host.id)
		local inbox = s.inbox ~= nil
		return if board and inbox then "the intake inbox and board" elseif inbox then "the intake inbox" elseif board then "the board" else nil
	end
	local function plan_flow(cx: WindowCx, source: number, origin: any)
		cx:prompt({ placeholder = "Absolute path of the /glitch-plan file on the execution host (≤1 MiB)", action = "import plan" }):next(function(text: string?, err: string?, fresh: WindowCx?)
			if not fresh or err or text == nil or not current_origin(fresh, source, origin) then return end
			local path = trimmed(text)
			if not absolute_path(path) then notice(fresh, source, origin.alias_nonce, "Plan import needs one absolute file path (≤512 bytes, one line). Nothing was imported."); return end
			-- The host reads and parses the file itself: plan bytes never cross the 8192-byte bridge.
			send_command(fresh, source, origin, "plan_import", { path = path })
		end)
	end
	local function board_flow(cx: WindowCx, source: number, origin: any)
		local flow = workflow_node(cx, source, "workflow-index", "orchplus.workflow")
		local path = if flow and type(flow.policy) == "table" then flow.policy.board_path else nil
		if type(path) ~= "string" or path == "" then
			notice(cx, source, origin.alias_nonce, "Set the Board file in Config → Work sources first. Nothing was started.")
			return
		end
		local host = cx.hosts:current()
		local function use(fresh: WindowCx)
			local b = board_state(ensure(source, origin), path)
			if host.kind == "remote" then b.remote_ok = host.id end
			local ok, failure = pcall(function() return fresh.board:open(path) end)
			if not ok then notice(fresh, source, origin.alias_nonce, "Board " .. path .. " could not be opened: " .. tostring(failure):sub(1, 300)); return end
			b.next_poll = 0; arm()
		end
		if host.kind ~= "remote" then use(cx); return end
		cx:pick({ placeholder = "This window is attached to remote host " .. tostring(host.name) .. ": the board " .. path .. " is read on this desktop, not the execution host.", items = {
			{ label = "Cancel — do not use this board", confirm = false },
			{ label = "Use the desktop board anyway", detail = path, confirm = true },
		} }):next(function(choice: any, err: string?, fresh: WindowCx?)
			if not fresh or err or not choice or choice.confirm ~= true or not current_origin(fresh, source, origin) or fresh.hosts:current().id ~= host.id then return end
			use(fresh)
		end)
	end
	-- A saved template (D16): the owner picks one (unless Config → Templates "Start…" named it) and
	-- enters its {input}; the host validates the input and starts the chain (`template_start`).
	local function template_flow(cx: WindowCx, source: number, origin: any, template_id: string?)
		local flow = workflow_node(cx, source, "workflow-index", "orchplus.workflow")
		local templates = if flow and type(flow.policy) == "table" and type(flow.policy.templates) == "table" then flow.policy.templates else {}
		if template_id == nil then
			local items = {}
			for _, t in templates do
				table.insert(items, { label = tostring(t.id) .. " — " .. tostring(t.title), template_id = t.id,
					detail = "Output " .. tostring(t.output) .. (if present(t.next) then ", then template " .. tostring(t.next) else ", last step") })
			end
			if #items == 0 then notice(cx, source, origin.alias_nonce, "No saved templates; add one in Config → Templates. Nothing was started."); return end
			cx:pick({ placeholder = "Start which template?", items = items }):next(function(choice: any, err: string?, fresh: WindowCx?)
				if not fresh or err or not choice or type(choice.template_id) ~= "string" or not current_origin(fresh, source, origin) then return end
				template_flow(fresh, source, origin, choice.template_id)
			end)
			return
		end
		local found = nil
		for _, t in templates do if t.id == template_id then found = t end end
		if not found then notice(cx, source, origin.alias_nonce, "Template " .. template_id .. " is not saved in Config. Nothing was started."); return end
		ask_text(cx, source, origin, "", "Input for template " .. template_id .. ": replaces {input} in its prompt (1–2048 bytes)", "start template", function(fresh, text)
			if #text > 2048 or utf8.len(text) == nil or not text:find("%S") then
				return notice(fresh, source, origin.alias_nonce, "Template input must be 1–2048 bytes of UTF-8 text. Nothing was started.")
			end
			send_command(fresh, source, origin, "template_start", { template_id = template_id, input = text })
		end)
	end
	-- Controller button "Start work…" (D10, D16); a template id comes from Config → Templates "Start…".
	local function start(cx: WindowCx, source: number, origin: any, template_id: string?)
		if template_id ~= nil then template_flow(cx, source, origin, template_id); return end
		local flow = workflow_node(cx, source, "workflow-index", "orchplus.workflow")
		if not flow or type(flow.policy) ~= "table" then notice(cx, source, origin.alias_nonce, "Workflow projection unavailable; nothing was started."); return end
		local policy = flow.policy
		if policy.glitch_integration == false then board_flow(cx, source, origin); return end
		local plan = { label = "From a /glitch-plan file", detail = "The execution host reads and imports the plan file", source = "plan" }
		local board = { label = "From a Tern board", detail = if present(policy.board_path) then policy.board_path else "set the Board file in Config first", source = "board" }
		local items = if policy.default_work_source == "board" then { board, plan } else { plan, board }
		items[1].label ..= " (Recommended)"
		local templates = if type(policy.templates) == "table" then #policy.templates else 0
		if templates > 0 then
			table.insert(items, { label = "From a template", detail = tostring(templates) .. " saved in Config → Templates; you enter its {input}", source = "template" })
		end
		cx:pick({ placeholder = "Start work from…", items = items }):next(function(choice: any, err: string?, fresh: WindowCx?)
			if not fresh or err or not choice or not current_origin(fresh, source, origin) then return end
			if choice.source == "plan" then plan_flow(fresh, source, origin)
			elseif choice.source == "template" then template_flow(fresh, source, origin)
			else board_flow(fresh, source, origin) end
		end)
	end
	local function prune(live: any) for source in state do if not live[source] then state[source] = nil end end end
	return { step = step, start = start, prune = prune }
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
local function schedule(cx: WindowCx)
	local host, session = cx.hosts:current(), cx.sessions:current()
	idle_wake.clear()
	if host.state ~= "connected" then return end
	local membership = tab_sessions(cx)
	local live = {}
	for _, pane in panes_on(cx, host) do
		if not scanned_controller(pane, membership, session) then continue end
		local source = pane.pane
		live[source] = true
		push_config_panes(cx, source, host, session, membership)
		local data = snapshot(cx, source)
		if not data or not data.owner_id then continue end
		local origin = origin_now(cx, source, data)
		if not origin then continue end
		local flow = workflow_node(cx, source, "workflow-index", "orchplus.workflow")
		if not flow or type(flow.worker_ids) ~= "table" or type(flow.policy) ~= "table" then continue end
		idle_wake.note(source, origin.alias_nonce, #flow.worker_ids, data.controller_phase == "active")
		sweep_due(cx, source, origin, flow)
		-- Work sources (time-sliced; step pcalls each half), then USAGE refresh when routing awaits it.
		idle_wake.sources(source, work_sources.step(cx, source, origin, flow))
		local routing = if flow.policy.quota_routing then routing_index(cx, source) else nil
		if routing and routing.refresh_due == true and readers[source] == nil then start_reader(source, origin, "snapshot") end
		local scan = scans[source]
		if not scan or scan.nonce ~= origin.alias_nonce then
			scan = { nonce = origin.alias_nonce, cursor = 0, observed = {}, polls = {}, next_poll = {} }; scans[source] = scan
		end
		-- One registered worker per turn: bounded callback work and fair rotation.
		if #flow.worker_ids > 0 then
			scan.cursor = scan.cursor % #flow.worker_ids + 1
			if scan.cursor == 1 then
				-- Once per rotation: forget per-worker timers/counters of workers no longer registered.
				local registered = {}
				for _, worker_id in flow.worker_ids do registered[worker_id] = true end
				for _, per_worker in { scan.observed, scan.polls, scan.next_poll } do
					for worker_id in per_worker do if not registered[worker_id] then per_worker[worker_id] = nil end end
				end
			end
			local worker = worker_now(cx, source, flow.worker_ids[scan.cursor])
			if worker and worker.origin_binding and current_origin(cx, source, worker.origin_binding) then
				local now = tern.now()
				if now >= (scan.observed[worker.worker_id] or 0) then
					scan.observed[worker.worker_id] = now + flow.policy.poll_ms
					local native, _reason, _pane, problem = native_observation(cx, source, worker)
					if worker.pane_binding then
						send_command(cx, source, origin, "observe", { worker_id = worker.worker_id, pane_binding = worker.pane_binding,
							native_state = native, delivery_error = problem })
					end
				end
				local driver = nil
				for _, candidate in drivers do
					if candidate.source == source and (candidate.worker_id == worker.worker_id
						or (worker.active_action_id and candidate.scope == worker.active_action_id)
						or (worker.active_action_id and candidate.command_request_id and data.driver_result and data.driver_result.request_id == candidate.command_request_id
							and data.driver_result.action_id == worker.active_action_id)) then driver = candidate; break end
				end
				if not worker.active_action_id and not driver and now >= (scan.next_poll[worker.worker_id] or 0) then
					scan.next_poll[worker.worker_id] = now + flow.policy.poll_ms
					-- Policy rollover only requests a checkpoint; the host reducer rechecks every condition.
					if worker.due_rollover and not flow.policy.paused then
						send_command(cx, source, origin, "rollover", { worker_id = worker.worker_id, trigger = "policy" })
					elseif worker.due_report and not worker.report_request_pending and not flow.policy.paused then
						send_command(cx, source, origin, "reply", { worker_id = worker.worker_id, trigger = "policy" })
					elseif worker.due_poll or (worker.report_request_pending and not worker.report_held) then
						-- A held report blocks this generation's report lane (no automatic report or watermark
						-- re-read until the owner acts); due_poll covers outbound settlement.
						scan.polls[worker.worker_id] = (scan.polls[worker.worker_id] or 0) + 1
						send_command(cx, source, origin, "poll", { worker_id = worker.worker_id,
							bytes = if not worker.report_held and scan.polls[worker.worker_id] % 4 == 0 then "watermark" else nil })
					end
				end
				worker = worker_now(cx, source, worker.worker_id) or worker
				if not driver and worker.active_action_id then
					local scoped = snapshot(cx, source, worker.active_action_id)
					local key = tostring(source) .. ":" .. worker.worker_id
					local due, stale = capacity_ready(worker.active_action_id)
					if scoped and scoped.action and scoped.action.phase == "ready" and not held_actions[worker.active_action_id] then
						if due then drivers[key] = { key = key, source = source, origin = origin, scope = worker.active_action_id, worker_id = worker.worker_id, stale_result = stale } end
					elseif scoped and scoped.action then
						if scoped.action.phase == "backpressure" and not held_actions[worker.active_action_id] and not recheck_waits[worker.active_action_id] then
							recheck_hold(source, worker.active_action_id)
						end
						auto_reconcile_due(cx, source, origin, scoped, key, worker.worker_id)
					end
				end
			end
		end
		-- Catalog has no worker; it still gets one exact scoped executor.
		if not drivers[source] and data.action and not data.action.worker_id and data.action.phase == "ready" and not held_actions[data.action.action_id] then
			local due, stale = capacity_ready(data.action.action_id)
			if due then drivers[source] = { source = source, origin = origin, scope = data.action.action_id, stale_result = stale } end
		end
		if data.action and not data.action.worker_id and data.action.phase == "backpressure" and not held_actions[data.action.action_id] and not recheck_waits[data.action.action_id] then
			recheck_hold(source, data.action.action_id)
		end
		-- Capacity-refused (still ready, never granted) actions resume once their backoff is due,
		-- whether or not they are selected; anything no longer ready leaves the wait.
		for action_id, wait in capacity_waits do
			if wait.source == source and not held_actions[action_id] and awake_now() >= wait.next_at and not scope_busy(source, action_id) then
				local scoped = snapshot(cx, source, action_id)
				if scoped == nil or not scoped.action or scoped.action.phase ~= "ready" then capacity_waits[action_id] = nil
				elseif not lane_busy(source, scoped.action.worker_id) then
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
				elseif a.phase == "backpressure" and wait.attempts >= CAPACITY_RETRIES then
					recheck_waits[action_id] = nil; held_actions[action_id] = true; watch_settle(source, action_id)
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
	for source in sweep_attempts do if not live[source] then sweep_attempts[source] = nil end end
	for source in pane_pushes do if not live[source] then pane_pushes[source] = nil end end
	work_sources.prune(live)
	prune_settled(cx)
end
-- Guided reload recovery: one owner flow lists every remaining step in order and opens each as the
-- existing explicit, attested control (controller continuation, SPAWN's own owner recovery — never
-- attested from ORCH+ — then per-worker reattachment). SPAWN's owner state comes from a read-only
-- owner_status read.
local OWNER_STEPS: any = {
	previous_incarnation = "SPAWN still binds this session to an earlier controller window. In SPAWN: Running agents → Transport review, fence the managed controller, verify it and its launch executors stopped or retired, then confirm there.",
	other_owner = "SPAWN binds this session to a different controller owner. In SPAWN: Running agents → Transport review, inspect and recover that owner explicitly.",
	fenced = "SPAWN owner recovery is fenced but not confirmed. Verify the previous controller and its launch executors stopped or retired, then confirm in SPAWN: Running agents → Transport review.",
	other_authority = "SPAWN's managed authority or host session differs from this window. Open SPAWN Config in the original session and inspect its owner there.",
	retired = "SPAWN retired this exact controller binding. It cannot regain authority; continue the controller from a fresh window binding.",
	unknown = "SPAWN's owner state could not be read (bridge unavailable or no answer). Open SPAWN: Running agents → Transport review to inspect it.",
}
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
	local observed = owner_states[source]
	local state = if observed and observed.nonce == origin.alias_nonce then observed.state else "unknown"
	if state ~= "current" and state ~= "none" then
		table.insert(steps, { kind = "spawn", label = "Recover the previous SPAWN owner (" .. tostring(state) .. ")", detail = OWNER_STEPS[state] or OWNER_STEPS.unknown })
	end
	local flow = workflow_node(cx, source, "workflow-index", "orchplus.workflow")
	for _, worker_id in (if flow and type(flow.worker_ids) == "table" then flow.worker_ids else {}) do
		local worker = worker_now(cx, source, worker_id)
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
	local steps = guide_steps(cx, source, origin)
	publish_steps(cx, source, origin, steps)
	local items, informational = {}, ""
	for _, step in steps do
		if step.kind == "uncertain" then informational = " " .. step.label .. " are being read automatically."
		else
			table.insert(items, { label = (if #items == 0 then "Next: " else "Then: ") .. step.label, detail = step.detail, kind = step.kind, worker_id = step.worker_id })
		end
	end
	if #items == 0 then
		notice(cx, source, origin.alias_nonce, "Reload recovery: no controller, SPAWN owner or worker reattachment step remains." .. informational, "info", "ORCH+ Reload recovery guide")
		-- Informational only: neither item has a kind, so choosing either does nothing.
		cx:pick({ placeholder = "Reload recovery: nothing to do." .. informational, items = {
			{ label = "No reload recovery step remains (controller, SPAWN owner and every worker are settled)" },
			{ label = "Close" },
		} })
		return
	end
	table.insert(items, { label = "Close — nothing is done automatically" })
	cx:pick({ placeholder = "Reload recovery: " .. tostring(#items - 1) .. " explicit step(s) remain, in order." .. informational, items = items }):next(function(choice: any, err: string?, fresh: WindowCx?)
		if not fresh or not choice or err or not choice.kind or not current_context(fresh, source, origin) then return end
		local request = { source_nonce = origin.alias_nonce, orch_session_id = origin.logical_session_id }
		if choice.kind == "continue" then
			request.command = "continue_controller"; guide_control(fresh, source, request)
		elseif choice.kind == "reattach" then
			request.command = "continue_worker"; request.worker_id = choice.worker_id; guide_control(fresh, source, request)
		elseif choice.kind == "spawn" then
			-- SPAWN keeps its independent operator check: ORCH+ only opens its recovery page.
			local opened = pcall(function() fresh.actions:run("SPAWN: Running agents") end)
			notice(fresh, source, origin.alias_nonce, (if opened then "Opened SPAWN: Running agents." else "Open SPAWN: Running agents from the palette.")
				.. " Use Transport review → Fence managed controller, verify, then confirm. Reopen the guide afterwards (palette: ORCH+ Reload recovery guide); ORCH+ never attests SPAWN recovery.")
		end
	end)
end
-- Start the read-only SPAWN owner_status probe; the guide opens once it answers or after 5 s awake.
-- Callers rearm the observation timer that drives probe_step.
local function start_guide(source: number, origin: any, open: boolean)
	guides[source] = { origin = origin, open = open, started = awake_now() }
end
-- Send one read-only query of a probe `entry` on the source's catalog bridge lane, only while no
-- lane driver and no `other` probe's live read could have its single response node overwritten.
local function catalog_query(cx: WindowCx, source: number, entry: any, other: any, op: string, binding: any, generation: any, target: string?)
	if other ~= nil and other.query ~= nil then return end
	for _, driver in drivers do if driver.source == source and driver.worker_id == nil then return end end
	local bridge = acquire_bridge(cx, source, entry.origin, "catalog")
	local node = if bridge ~= nil then surface_node(cx, bridge, "spawn.dispatch", "spawn.dispatch.response") else nil
	if node then entry.bridge = bridge; entry.query = send_query(cx, bridge :: number, node, source, op, binding, generation, target) end
end
local function probe_step(cx: WindowCx)
	for source, guide in guides do
		if not current_context(cx, source, guide.origin) then guides[source] = nil; continue end
		local state: string? = nil
		if guide.query == nil then
			catalog_query(cx, source, guide, withdrawals[source], "owner_status", guide.origin, guide.origin.owner_generation)
		else
			local _, bytes = surface_node(cx, guide.bridge, "spawn.dispatch", "spawn.dispatch.response")
			local body = if bytes then dispatch.decode_response(bytes, guide.query) else nil
			if body and body.status == "owner_status" and type(body.payload) == "table" and type(body.payload.owner) == "string" then state = body.payload.owner
			elseif body then state = "unknown" end
		end
		if state == nil and awake_now() - guide.started > 5000 then state = "unknown" end
		if state ~= nil then
			guides[source] = nil
			owner_states[source] = { nonce = guide.origin.alias_nonce, state = state }
			if guide.open then open_guide(cx, source, guide.origin) else publish_steps(cx, source, guide.origin, guide_steps(cx, source, guide.origin)) end
		end
	end
end
-- One read-only SPAWN `status` of the fenced request, then the owner's `cancel_work` carrying that
-- exact query and answer (the host decides whether it is definitively unexecutable). No answer
-- within 10 s awake ends with a notice and nothing is cancelled.
local function withdraw_step(cx: WindowCx)
	for source, probe in withdrawals do
		if not current_origin(cx, source, probe.origin) then withdrawals[source] = nil; continue end
		if probe.query == nil then
			catalog_query(cx, source, probe, guides[source], "status", probe.fenced.origin_binding, probe.fenced.controller_generation, probe.fenced.request_id)
		else
			local _, bytes = surface_node(cx, probe.bridge, "spawn.dispatch", "spawn.dispatch.response")
			if bytes and dispatch.decode_response(bytes, probe.query) then
				withdrawals[source] = nil
				local id = send_command(cx, source, probe.origin, "cancel_work", { worker_id = probe.worker_id, query_bytes = tern.json.encode(probe.query), response_bytes = bytes }, true)
				if id and probe.fenced.mailbox_provisioned then start_driver(source, probe.origin, id, probe.worker_id) end
				continue
			end
		end
		if awake_now() - probe.started > 10000 then
			withdrawals[source] = nil
			notice(cx, source, probe.origin.alias_nonce, "SPAWN did not answer the status read for " .. probe.worker_id .. "'s fenced request within 10 s; nothing was cancelled. Try again.")
		end
	end
end
local driver_turn = 0
local function arm()
	if timer ~= nil then return end
	timer = tern.timer(TICK_MS, function(fresh: WindowCx?)
		timer = nil
		observe_tick() -- Before any deadline check in this turn.
		arm() -- Rearm before work so an unexpected native-context failure cannot kill observation.
		if fresh ~= nil then
			-- Clicked window-side controls first: each published intent runs at most once here.
			pcall(consume_intents, fresh)
			local scheduled, failure = pcall(schedule, fresh)
			if not scheduled then
				-- Keep the loop alive without toast storms; a fresh attached view exposes the hold.
				for _, driver in drivers do
					if current_origin(fresh, driver.source, driver.origin) then
						local _, node = snapshot(fresh, driver.source)
						if node then fresh.session:event(driver.source, { ev = "action", id = node.id, act = "dispatch-notice",
							value = tern.json.encode({ source_nonce = driver.origin.alias_nonce, message = "Workflow observation unavailable: " .. tostring(failure):sub(1, 700) }) }) end
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
					if current_origin(fresh, driver.source, driver.origin) and driver.action_id then
						send_command(fresh, driver.source, driver.origin, "lost", { action_id = driver.action_id, executor = driver.claim_executor or incarnation, grant_id = driver.grant_id })
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
			-- Earlier-incarnation SPAWN bridges: at most one native close or move per pass.
			pcall(bridge_sweep, fresh)
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
		if message and reader_notices[reader.source] ~= message then
			reader_notices[reader.source] = message
			notice(cx, reader.source, reader.origin.alias_nonce, message)
		end
	else
		reader_notices[reader.source] = nil
	end
	local after = reader.after
	reader.after = nil
	for _, fn in after or {} do pcall(fn, cx, ok) end
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
	if not current_origin(cx, source, origin) then reader_done(cx, reader, false); return end
	local pane = reader.pane or usage_by_source[source]
	local info = if pane then cx.session:pane(pane) else nil
	if info == nil or info.block ~= quota.BLOCK then
		pane = acquire_usage(cx, source)
		if pane == nil then
			reader_done(cx, reader, false, "USAGE capacity block is unavailable. Install/enable USAGE and turn on its read-only capacity export; quota-routed work stays held.")
			return
		end
		usage_by_source[source] = pane
	end
	reader.pane = pane
	if not scoped_pane(cx, pane, origin) then
		usage_by_source[source] = nil
		reader_done(cx, reader, false, "The USAGE capacity block is not on this controller's host/session; no evidence was read.")
		return
	end
	local node, text = surface_node(cx, pane, quota.BLOCK, quota.NODE, quota.NODE, quota.MAX_RESPONSE_CHARS)
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
		cx.session:event(pane, { ev = "action", id = node.id, act = quota.ACTION, value = bytes })
		return
	end
	local response, problem = quota.decode_response(text, pending)
	if response == nil then
		if problem.code == "pending" or problem.code == "uncorrelated" then
			local waited = tern.now() - pending.sent
			-- USAGE ignores events while busy with another reader; resend the same idempotent read.
			if problem.code == "uncorrelated" and waited > 5000 * (pending.resent + 1) and pending.resent < 3 then
				pending.resent += 1
				cx.session:event(pane, { ev = "action", id = node.id, act = quota.ACTION, value = pending.bytes })
			elseif waited > 30000 then
				reader_done(cx, reader, false, "USAGE capacity did not answer within 30 s; quota-routed work stays held.")
			end
			return
		end
		if reader.mode == "validate" then
			-- The decision's revision is no longer current: refresh, never launch on it.
			reader.mode = "snapshot"; reader.request = nil; reader.assembly = nil; reader.document = nil
			return
		end
		reader_done(cx, reader, false, "USAGE capacity " .. problem.code .. ": " .. tostring(problem.message) .. (HINTS[problem.code] or "") .. " Quota-routed work stays held.")
		return
	end
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
	send_command(cx, source, origin, "capacity", { capacity = evidence })
	reader_done(cx, reader, true)
end
local function current_gate(cx: WindowCx, source: number, request: any): any?
	if type(request.gate_id) ~= "string" then return nil end
	local gate = workflow_node(cx, source, "workflow-gate-" .. request.gate_id, "orchplus.gate")
	if not gate or gate.id ~= request.gate_id or gate.revision ~= request.gate_revision then return nil end
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
	cx:toast("info", "ORCH+ worker inspection", worker_id .. " · " .. native .. " · " .. tostring(problem or "Native lifecycle observed; report and gate facts remain separate."))
end
local function agent_of(cx: WindowCx, pane: number): any?
	for _, agent in cx.agents:list() do if agent.pane == pane then return agent end end
	return nil
end
-- A pane (not a block, not the controller) on the origin's exact connected host and native session.
local function origin_pane(cx: WindowCx, source: number, target: number, origin: any): any?
	local pane = if target ~= source then scoped_pane(cx, target, origin) else nil
	return if pane and pane.block == nil then pane else nil
end
local function pane_binding(target: number, origin: any): any
	return { pane_id = tostring(target), window_key = origin.window_key, window_epoch = origin.window_epoch,
		native_session_id = origin.native_session_id, window_host_id = origin.window_host_id }
end
-- An attach candidate is an idle, recognized native agent pane of this exact window, native session
-- and host that no managed worker already binds. Terminal/shell panes are never candidates.
local function adoption_candidate(cx: WindowCx, source: number, target: any, origin: any): any?
	if type(target) ~= "number" or not current_origin(cx, source, origin) or not origin_pane(cx, source, target, origin) then return nil end
	local native = agent_of(cx, target)
	if not native or native.state ~= "idle" or (native.delivery_error ~= nil and native.delivery_error ~= tern.json.null) then return nil end
	local binding = pane_binding(target, origin)
	local flow = workflow_node(cx, source, "workflow-index", "orchplus.workflow")
	for _, worker_id in (if flow and type(flow.worker_ids) == "table" then flow.worker_ids else {}) do
		local worker = worker_now(cx, source, worker_id)
		if worker and (same_origin(worker.pane_binding, binding) or same_origin(worker.adopt_pane_binding, binding)) then return nil end
	end
	return binding
end
local function continuation_candidate(cx: WindowCx, source: number, target: number, origin: any): any?
	if not current_context(cx, source, origin) then return nil end
	local pane = origin_pane(cx, source, target, origin)
	if not pane or (not agent_of(cx, target) and pane.kind ~= "terminal") then return nil end
	return pane_binding(target, origin)
end
-- An owner command whose host answer a driver follows; a host refusal of it is noticed.
local function drive(cx: WindowCx, source: number, origin: any, command: string, fields: any, worker_id: string?): string?
	local id = send_command(cx, source, origin, command, fields, true)
	if id then start_driver(source, origin, id, worker_id, true) end
	return id
end
local ORIGIN_LOST = "this window is no longer the controller's current execution origin, so nothing was sent or its answer cannot be followed here. Run ORCH+ Continue controller in this window, then retry."
-- An owner pick: `done` runs for a choice with `key` set (when given) while `still` holds
-- (default: this window is still the current execution origin).
local function ask_pick(cx: WindowCx, source: number, origin: any, placeholder: string, items: any, key: string?, done: (WindowCx, any) -> (), still: ((WindowCx) -> boolean)?)
	cx:pick({ placeholder = placeholder, items = items }):next(function(choice: any, err: string?, fresh: WindowCx?)
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
	ask_pick(cx, source, origin, placeholder, { { label = keep, [key] = false }, { label = act, detail = detail, [key] = true } }, key, function(fresh)
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
	local function refuse(message: string) notice(cx, source, origin.alias_nonce, message) end
	local worker = if type(request.worker_id) == "string" then worker_now(cx, source, request.worker_id) else nil
	if command == "recovery_guide" then
		start_guide(source, origin, true); arm()
		return
	end
	if command == "continue_controller" then
		local data = snapshot(cx, source)
		if not data or (request.expected_revision and request.expected_revision ~= data.revision) then
			return refuse("Controller revision changed. Run ORCH+ Continue controller in this window from the palette again.")
		end
		local revision = data.revision
		ask_pick(cx, source, origin, "Continue controller " .. origin.owner_id .. " / generation " .. tostring(origin.owner_generation)
			.. " / revision " .. tostring(revision) .. "? Old claims and coordinator uncertainty stay held.", {
			{ label = "Cancel — retain current binding", continue_controller = false },
			{ label = "I independently verified previous ORCH+/SPAWN executors stopped or retired",
				detail = "Operator attestation, not native proof. Enables retained-outcome inspection; never retries old effects or clears pending claims.", continue_controller = true },
		}, "continue_controller", function(fresh)
			local current = snapshot(fresh, source)
			if not current or current.revision ~= revision then
				return notice(fresh, source, origin.alias_nonce, "Controller changed during verification. Run ORCH+ Continue controller in this window again; nothing was rebound.")
			end
			-- After continuation, list every remaining recovery step (SPAWN owner, reattachments).
			if send_command(fresh, source, origin, "continue_controller", { expected_revision = revision, operator_verified = true }, true) then start_guide(source, origin, true); arm() end
		end, function(fresh) return current_context(fresh, source, origin) end)
		return
	end
	if not current_origin(cx, source, origin) then
		return refuse("This window is not the continued execution origin. Run the palette command ORCH+ Continue controller in this window, inspect retained outcomes, then explicitly reattach workers.")
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
			ask_pick(fresh, source, origin, "Attach " .. worker.worker_id .. " / generation " .. tostring(worker.worker_generation)
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
		send_command(cx, source, origin, command, nil, true)
	elseif command == "policy" then
		local flow = workflow_node(cx, source, "workflow-index", "orchplus.workflow")
		if not flow or not flow.policy or type(flow.policy_sha256) ~= "string" then return end
		local previous = flow.policy
		if request.expected_sha256 ~= flow.policy_sha256 then return refuse("Config changed since this control was displayed. Reopen Config; nothing changed.") end
		local bounds = POLICY_FIELDS[request.field]
		if request.field == nil then
			-- Saved Config draft: the host reducer validates it and refuses a changed policy digest.
			if type(request.policy) == "table" then save_policy(cx, source, origin, previous, { policy = request.policy }) end
		elseif request.field == "sweep_time" then
			ask_policy_value(cx, source, origin, previous, "sweep_time", tostring(previous.sweep_time or "03:00"), "Nightly mailbox sweep time: local HH:MM (00:00–23:59)", "save sweep time", function(value)
				local hour, minute = value:match("^%s*(%d%d?):(%d%d)%s*$")
				local h, m = tonumber(hour), tonumber(minute)
				if not h or not m or h > 23 or m > 59 then return nil, "Sweep time must be a local 24-hour HH:MM from 00:00 to 23:59; nothing changed." end
				return string.format("%02d:%02d", h, m)
			end)
		elseif not policy_editor(cx, source, origin, request, previous) and bounds then
			local minimum, maximum = tostring(bounds.minimum), tostring(bounds.maximum)
			ask_policy_value(cx, source, origin, previous, request.field, tostring(previous[request.field]), bounds.label .. ": whole number " .. minimum .. "–" .. maximum, "save " .. bounds.label, function(value)
				local digits = value:match("^%s*(%d+)%s*$")
				local number = if digits and #digits <= 9 then tonumber(digits) else nil
				if not number or number < bounds.minimum or number > bounds.maximum then return nil, bounds.label .. " must be a whole number from " .. minimum .. " to " .. maximum .. "; nothing changed." end
				return number
			end)
		end
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
	elseif command == "rollover" or command == "cancel_rollover" then
		local cancel = command == "cancel_rollover"
		local active = live_rollover(worker)
		if not worker or worker.finish_requested or (cancel and not active) then return refuse("Rollover controls apply to a current worker or the activated coordinator.") end
		local placeholder = if cancel then "Cancel rollover " .. active.id .. "? Only possible before a successor pane exists or coordinator retirement starts; the predecessor keeps running."
			elseif active then "Request the checkpoint again for rollover " .. active.id .. "? The previous checkpoint stays as evidence."
			elseif worker.coordinator_owner_id then "Roll over coordinator " .. worker.work_id .. "? ORCH+ asks for a verified checkpoint, retires and stops this coordinator, and only after its observed closure and slot release starts a fresh successor."
			else "Roll over " .. worker.work_id .. "? ORCH+ asks for a verified checkpoint, starts a fresh successor, and stops this worker only after the successor accepts."
		local act = if cancel then "Cancel this rollover" elseif active then "Request checkpoint again" elseif worker.coordinator_owner_id then "Roll over coordinator" else "Roll over worker"
		confirm_worker(cx, source, origin, worker, placeholder, "Keep current state", act, "confirm", function(current)
			local now = live_rollover(current)
			return (if now then now.id else nil) == (if active then active.id else nil)
		end, "Worker or rollover changed during confirmation; nothing was requested.", command,
			if cancel then { worker_id = worker.worker_id } else { worker_id = worker.worker_id, trigger = "owner" })
	elseif command == "adopt" then
		local records = if type(request.records) == "table" then request.records else {}
		local candidate = adoption_candidate(cx, source, request.pane, origin)
		if not candidate or #records == 0 then
			return refuse("Attach needs an idle native agent pane in this exact window, session and host that no worker binds, plus an eligible native SPAWN record. Nothing was attached.")
		end
		local items = { { label = "Cancel — do not attach" } }
		for _, record in records do
			if type(record) == "table" and type(record.record_id) == "string" and type(record.label) == "string" then
				table.insert(items, { label = "Runs under " .. record.label, detail = "SPAWN record " .. record.record_id .. " / revision " .. tostring(record.record_revision), record = record })
			end
		end
		ask_pick(cx, source, origin, "Attach pane " .. candidate.pane_id .. ": choose the SPAWN record whose account/profile this agent already runs under", items, "record", function(fresh, choice)
			ask_text(fresh, source, origin, nil, "Explicit assignment for the attached agent in pane " .. candidate.pane_id, "continue", function(next_cx, task)
				ask_pick(next_cx, source, origin, "Attest pane " .. candidate.pane_id .. " (window " .. candidate.window_epoch .. ", session " .. candidate.native_session_id
					.. ", host " .. candidate.window_host_id .. ") is the exact agent to enroll as an ORCH+ worker?", {
					{ label = "Cancel — do not attach", attach = false },
					{ label = "I verified this exact agent pane runs under " .. choice.record.label, attach = true,
						detail = "SPAWN delivers the transport preface and assignment once by native ask. A busy, non-agent, out-of-session or already-bound pane is refused; an uncertain delivery is never repeated." },
				}, "attach", function(last_cx)
					local verified = adoption_candidate(last_cx, source, request.pane, origin)
					if not verified or not same_origin(verified, candidate) then
						return notice(last_cx, source, origin.alias_nonce, "The pane changed, became busy or was bound during confirmation; nothing was attached.")
					end
					drive(last_cx, source, origin, "adopt", { record_id = choice.record.record_id, record_revision = choice.record.record_revision,
						catalog_revision = choice.record.catalog_revision, prompt = task, pane_binding = verified, attestation = "operator_verified_exact_agent_pane" })
				end)
			end)
		end)
	elseif command == "recheck_report" then
		if not worker or not worker.report_held or worker.continuation_required then
			return refuse("Re-check needs a held report on an explicitly continued worker. Continue after reload first if required.")
		end
		confirm_worker(cx, source, origin, worker, "Re-check the held report of " .. worker.worker_id .. "? The same retained bytes are decoded again with current validation; nothing is skipped or replaced.",
			"Keep it held", "Re-check held report", "confirm", function(current) return current.report_held end,
			"The held report changed during confirmation; nothing was re-checked.", "recheck_report", { worker_id = worker.worker_id })
	elseif command == "reconcile_restored" then
		if not worker or not worker.restored or worker.restored.reconciled then return refuse("No unreconciled restored coordinator pane is recorded for this worker.") end
		ask_pick(cx, source, origin, "Confirm you independently stopped the restored retired coordinator pane " .. worker.worker_id .. "? This records operator attestation only; nothing is stopped or restarted.", {
			{ label = "Keep coordinator effects held", confirm = false },
			{ label = "I stopped it — record reconciliation", detail = worker.worker_id, confirm = true },
		}, "confirm", function(fresh)
			local current = worker_now(fresh, source, worker.worker_id)
			if not current or not current.restored or current.restored.reconciled or current.restored.at_ms ~= worker.restored.at_ms then
				return notice(fresh, source, origin.alias_nonce, "Restoration evidence changed during confirmation; nothing was recorded.")
			end
			send_command(fresh, source, origin, "reconcile_restored", { worker_id = worker.worker_id, operator_verified = true }, true)
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
			fresh:prompt({ placeholder = placeholder, action = action }):next(function(reason: string?, err: string?, next_cx: WindowCx?)
				if not next_cx or not reason or err or reason:find("%S") == nil or not still(next_cx) then return end
				done(next_cx, reason)
			end)
		end
		-- Contract J: a landed item's uncertain deploy takes the same read-only lost/reconcile path.
		local deployed = item.status == "landed"
		local roles = if deployed and (command == "landing_lost" or command == "reconcile_landing") then workflow_node(cx, source, "workflow-landing-roles-" .. item.id, "orchplus.landing-roles") else nil
		local deploy = if roles and roles.id == item.id and type(roles.deploy) == "table" then roles.deploy else nil
		if command == "move_landing" then
			if (request.direction == "up" and item.move_up) or (request.direction == "down" and item.move_down) then
				fields.direction = request.direction
				send_command(cx, source, origin, "move_landing", fields, true)
			end
		elseif command == "cancel_landing" then
			if not item.cancellable then return end
			ask_pick(cx, source, origin, "Cancel ungranted landing " .. item.id .. "? Its approval gate is withdrawn; landing later needs a new worker request.", {
				{ label = "Keep this request", confirm = false }, { label = "Cancel this exact request", confirm = true },
			}, "confirm", function(fresh) send_command(fresh, source, origin, "cancel_landing", fields, true) end, still)
		elseif command == "landing_lost" then
			if not (if deployed then deploy and deploy.markable_lost == true else item.markable_lost) then return end
			ask_reason(cx, if deployed then "Deploy result lost — hold " .. tostring(deploy.deploy_id) .. " for reconciliation? Why is it lost? Nothing is re-granted or retried."
				else "Why is the exact result of " .. item.id .. " lost? The slot stays held for reconciliation; nothing is retried.",
				if deployed then "hold deploy" else "hold landing slot", function(fresh, reason)
				fields.reason = reason
				send_command(fresh, source, origin, "landing_lost", fields, true)
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
				{ label = "I observed it LANDED", detail = "Enter the resulting target head next; later grants use it.", outcome = "landed" },
				{ label = "I observed it NOT landed", detail = "Releases the slot; the worker must publish a fresh request. Nothing is retried.", outcome = "not_landed" },
			}
			ask_pick(cx, source, origin, placeholder, items, "outcome", function(fresh, choice)
				local function settle(next_cx: WindowCx, observed: string)
					ask_reason(next_cx, if deployed then "Evidence of your read-only inspection (for example the observed deploy log entry)"
						else "Evidence of your read-only inspection (for example the observed log entry)", if deployed then "reconcile deploy" else "reconcile landing", function(last_cx, reason)
						fields.outcome = choice.outcome; fields.reason = reason; fields.operator_verified = true
						if observed ~= "" then fields.target_revision = observed end
						send_command(last_cx, source, origin, "reconcile_landing", fields, true)
					end)
				end
				if deployed then return settle(fresh, "") end
				fresh:prompt({ placeholder = if choice.outcome == "landed" then "Resulting target head revision (required)" else "Observed current target head revision (optional; leave empty if unknown)",
					action = "record target head" }):next(function(head: string?, head_error: string?, next_cx: WindowCx?)
					if not next_cx or head == nil or head_error or not still(next_cx) then return end
					local observed = trimmed(head)
					if choice.outcome == "landed" and observed == "" then
						return notice(next_cx, source, origin.alias_nonce, "A landed reconciliation needs the resulting target head; nothing was submitted.")
					end
					settle(next_cx, observed)
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
			send_command(cx, source, origin, "recheck_gate", fields, true)
			-- A quota fallback has no pane yet: recheck means a fresh, validated USAGE snapshot.
			if gate.kind == "quota_fallback" then start_reader(source, origin, "snapshot", nil, function() end)
			else inspect_worker(cx, source, origin, gate.worker_id, false) end
		elseif command == "cancel_gate" then
			ask_pick(cx, source, origin, "Cancel " .. gate.id .. "? Possible delivery cannot be retracted.", {
				{ label = "Keep gate", cancel_gate = false }, { label = "Cancel this exact gate revision", cancel_gate = true },
			}, "cancel_gate", function(fresh) send_command(fresh, source, origin, "cancel_gate", fields, true) end, gate_still("Gate changed during confirmation; nothing cancelled."))
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
			ask_pick(cx, source, origin, content.question, items, nil, function(fresh, choice)
				local answer_fields = { gate_id = gate.id, gate_revision = gate.revision, choice_id = choice.choice_id, answer = choice.label }
				if dispatch.HOST_GATES[gate.kind] then
					-- Host-consumed decision: the chosen option is the whole answer (no free-text prompt). A
					-- stale-claim answer never changes the claim; open_recovery also opens the recovery guide.
					local id = send_command(fresh, source, origin, "answer", answer_fields, true)
					if id and gate.kind == "stale_claim" and choice.choice_id == "open_recovery" then start_guide(source, origin, true); arm() end
					return
				end
				ask_text(fresh, source, origin, nil, "Explicit owner answer for " .. gate.id .. " / " .. choice.label, "send immutable answer", function(next_cx, answer)
					if not gate_still("Question changed before submission; no answer sent.")(next_cx) then return end
					answer_fields.answer = answer
					send_command(next_cx, source, origin, "answer", answer_fields, true)
				end)
			end, gate_still("Question changed during selection; no answer sent."))
		end
	elseif command == "queue" then
		local fields: any = { record_id = request.record_id, record_revision = request.record_revision, catalog_revision = request.catalog_revision,
			coordinator = request.coordinator, cwd = request.cwd, placement = request.placement }
		local function submit(next_cx: WindowCx)
			local flow = workflow_node(next_cx, source, "workflow-index", "orchplus.workflow")
			if not (flow and flow.policy and flow.policy.quota_routing) then return drive(next_cx, source, origin, "queue", fields) end
			-- Decide on freshly validated USAGE evidence; if it cannot be read the work is held, visibly.
			start_reader(source, origin, "snapshot", nil, function(last_cx: WindowCx)
				if current_origin(last_cx, source, origin) then drive(last_cx, source, origin, "queue", fields) end
			end)
		end
		-- Optional Contract G fields follow the task; scope defaults to the declared files in the reducer.
		ask_steps(cx, source, origin, {
			{ nil, "Explicit assignment for " .. tostring(request.record_id), "next: declared files", function(task) fields.prompt = task end },
			{ nil, "Declared files (comma-separated paths/globs, empty = none)", "next: checks", function(raw)
				local files, problem = parse_files(raw)
				fields.files = files
				return problem
			end },
			{ nil, "Checks (one per line `id: argv words`, empty = none)", "next: base ref", function(raw)
				local checks, problem = parse_checks(raw)
				fields.checks = checks
				return problem
			end },
			{ nil, "Base ref (empty = none)", "queue task", function(raw)
				local base_ref = trimmed(raw)
				if #base_ref > 0 and not assignment_text(base_ref, 256) then return "Base ref must be valid UTF-8 of at most 256 bytes." end
				fields.base_ref = if #base_ref > 0 then base_ref else nil
			end },
		}, " Nothing was queued.", submit)
	elseif command == "capacity_refresh" then
		start_reader(source, origin, "snapshot", nil, function(next_cx: WindowCx, ok: boolean)
			if ok then next_cx:toast("info", "ORCH+ quota evidence", "USAGE capacity evidence refreshed and validated.") end
		end)
	elseif command == "cancel_work" then
		if not worker then return refuse("Queued work changed; nothing was cancelled.") end
		-- Fenced never-launched work: its provision, launch or adoption request was fenced unexecuted at
		-- continuation. When SPAWN received it, its retained SPAWN status is read and sent with the command.
		local fenced = if type(worker.withdrawal) == "table" then worker.withdrawal else nil
		if fenced and fenced.mailbox_retire == "retiring" then
			return refuse("This work's unused mailbox is already being retired; inspect that retirement's outcome. Nothing else was started.")
		end
		-- A launch SPAWN rejected after provisioning also retires the unused mailbox (driven like any queued effect).
		local retires = fenced ~= nil and fenced.mailbox_retire ~= nil
		local placeholder = if fenced then "Cancel never-launched work " .. worker.work_id .. "? "
			.. (if fenced.evidence == "spawn_rejected" then "SPAWN rejected its " .. tostring(fenced.op) .. " before any effect"
				else "Continuation fenced its " .. tostring(fenced.op) .. " as unexecuted")
			.. (if fenced.status_required then "; SPAWN's retained status of that request is read first and must prove it can never run" else "")
			.. (if retires then ". Its provisioned, never-used mailbox is retired through the exact retirement path; the worker stays visible until SPAWN confirms retirement. Nothing native is stopped."
				else ". The worker and its assignment are discarded; nothing native is stopped or retired.")
			else "Cancel held work " .. worker.work_id .. "? It was never provisioned or launched; its assignment is discarded."
		ask_pick(cx, source, origin, placeholder, {
			{ label = if fenced then "Keep it" else "Keep it held", confirm = false },
			{ label = if fenced then "Cancel this never-launched work" else "Cancel this queued work", detail = worker.worker_id, confirm = true },
		}, "confirm", function(fresh)
			if fenced and fenced.status_required then
				if withdrawals[source] then return notice(fresh, source, origin.alias_nonce, "Another cancellation is still reading SPAWN status; nothing else was started.") end
				withdrawals[source] = { origin = origin, worker_id = worker.worker_id, fenced = fenced, started = awake_now() }
				arm()
				return
			end
			local id = send_command(fresh, source, origin, "cancel_work", { worker_id = worker.worker_id }, true)
			if id and retires then start_driver(source, origin, id, worker.worker_id) end
		end)
	elseif command == "start_work" then
		work_sources.start(cx, source, origin, if type(request.template_id) == "string" then request.template_id else nil)
	elseif command == "catalog" or command == "poll" or command == "reply" or command == "retire" then
		drive(cx, source, origin, command, { bytes = request.bytes, worker_id = request.worker_id }, request.worker_id)
	elseif command == "retry" then
		if type(request.action_id) ~= "string" then return end
		held_actions[request.action_id] = nil; capacity_waits[request.action_id] = nil; recheck_waits[request.action_id] = nil
		drive(cx, source, origin, "retry", { action_id = request.action_id, trigger = "owner" })
	elseif command == "readback_publication" then
		if type(request.action_id) ~= "string" then return end
		held_actions[request.action_id] = nil
		send_command(cx, source, origin, "readback_publication", { action_id = request.action_id }, true)
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
		-- An unstarted automatic read of another action yields; the owner's driver never inherits it.
		drivers[source] = if driver and not driver.auto then driver else { source = source, origin = origin }
		drivers[source].scope = request.action_id
		drivers[source].reconcile_action_id = if command == "reconcile" then request.action_id else nil
		arm()
	end
end
guide_control = dispatch_control
-- Operator intents: a clicked window-side control (views.luau `dispatch_link`/`assistance`) is
-- published by its controller block as `main.operator-intent` and runs at most once per
-- (source_nonce, serial) in this VM, then is settled host-side. Only the window that owns the
-- controller's origin acts; others leave it silently. A host-block click names no window (every
-- client of one window key shares key, session and focus), so a fresh incarnation continues only
-- through the palette commands below. Assistance follows the same rule while the host stamps a live
-- origin's window into the intent (`window`); unstamped, any window showing the controller may assist.
local INTENT_KINDS = { dispatch = true, assist = true }
local ASSIST_KINDS = { inspect = true, recheck = true, reveal = true, stop = true }
local intents_seen = fifo(256)
local function stamped_window(cx: WindowCx, source: number, window: any): boolean
	local host = host_for(cx, source)
	return type(window) == "table" and host ~= nil and window.window_key == cx:window_key() and window.window_epoch == incarnation
		and window.native_session_id == tostring(cx.sessions:current().id) and window.window_host_id == tostring(host.id)
end
local function intent_step(cx: WindowCx, source: number)
	local node, bytes = surface_node(cx, source, BLOCK, "orchplus.intent", "operator-intent", codec.LIMITS.logical)
	if not node or not bytes then return end
	local intent = codec.strict_decode(bytes, codec.LIMITS.logical)
	if type(intent) ~= "table" or intent.version ~= 1 or not INTENT_KINDS[intent.kind] or type(intent.source_nonce) ~= "string"
		or type(intent.serial) ~= "string" or #intent.serial > 256 or type(intent.request) ~= "table"
		or intent.request.source_nonce ~= intent.source_nonce then return end
	local id = intent.source_nonce .. "|" .. intent.serial
	if intents_seen.values[id] then return end
	intents_seen.put(id, true)
	local request = intent.request
	if intent.kind == "dispatch" then
		local origin = origin_now(cx, source, request)
		if not origin or not current_origin(cx, source, origin) then return end
	elseif request.version ~= 2 or (request.target ~= "controller" and request.target ~= "orchestrator") or not ASSIST_KINDS[request.kind]
		or (intent.window ~= nil and not stamped_window(cx, source, intent.window)) then
		return
	end
	-- Settle before acting: a failing or prompting control is never re-run from the same intent.
	cx.session:event(source, { ev = "action", id = node.id, act = "operator-intent-done",
		value = tern.json.encode({ source_nonce = intent.source_nonce, serial = intent.serial }) })
	if intent.kind == "dispatch" then
		dispatch_control(cx, source, request)
	else
		local performed, failure = pcall(assist, cx, source, request)
		if not performed then cx:toast("error", "ORCH+ assistance failed", tostring(failure)) end
	end
end
consume_intents = function(cx: WindowCx)
	local host, session = cx.hosts:current(), cx.sessions:current()
	if host.state ~= "connected" then return end
	local membership = tab_sessions(cx)
	for _, pane in panes_on(cx, host) do
		if scanned_controller(pane, membership, session) then
			local ok, failure = pcall(intent_step, cx, pane.pane)
			if not ok then cx:toast("error", "ORCH+ control failed", tostring(failure):sub(1, 300)) end
		end
	end
end
tern.command({ id = "open", title = "ORCH+", icon = "flow", group = "ORCH+", run = function(cx: WindowCx) open(cx) end })
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
		cx:toast("error", title, if #candidates == 0 then "No ORCH+ controller with a recorded owner is shown in this session on this host."
			else "Several ORCH+ controllers are shown here: focus the one to recover, then run the command again.")
		return
	end
	dispatch_control(cx, chosen.pane, { command = command, source_nonce = chosen.data.source_nonce, orch_session_id = chosen.data.orch_session_id })
end
tern.command({ id = "continue_controller", title = "ORCH+ Continue controller in this window", icon = "flow", group = "ORCH+",
	run = function(cx: WindowCx) palette_continuation(cx, "continue_controller", "ORCH+ Continue controller in this window") end })
tern.command({ id = "recovery_guide", title = "ORCH+ Reload recovery guide", icon = "flow", group = "ORCH+",
	run = function(cx: WindowCx) palette_continuation(cx, "recovery_guide", "ORCH+ Reload recovery guide") end })
-- The Files button opens the orchestration Config; Config has a button back to the controller.
tern.files.button({ id = "open", title = "Open ORCH+ Config", icon = "flow", run = function(_files: FilesInfo, cx: WindowCx) open(cx, true) end })
tern.on("window_start", function(_cx: WindowCx) arm() end)
arm() -- Also rearms when reloaded without window_start; one timer owns observation and dispatch.
-- Diagnostic: how many entries this window VM's bookkeeping tables retain.
local function bookkeeping(): any
	local function size(t: any): number local n = 0; for _ in t do n += 1 end; return n end
	local per_worker = 0
	for _, scan in scans do per_worker += size(scan.observed) + size(scan.polls) + size(scan.next_poll) end
	return { executed = size(executed), auto_reconcile = size(auto_reconcile), auto_readback = size(auto_readback.values), held_actions = size(held_actions),
		sweep_attempts = size(sweep_attempts), scan_workers = per_worker, watched = #settle_order }
end
return { native_observation = native_observation, schedule = schedule, intents = consume_intents, bookkeeping = bookkeeping }
