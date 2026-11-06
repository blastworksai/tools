--!strict
local BLOCK = "orchplus.orchestrator"
local codec = require("./transport")
local dispatch = require("./dispatch")
local quota = require("./quota")
local incarnation = string.format("window-%d-%08x-%08x", os.time(), math.random(1, 2147483647), math.random(1, 2147483647))
local dispatch_serial = 0
local function dispatch_id(): string dispatch_serial += 1; return incarnation .. "-" .. tostring(dispatch_serial) end

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
local function alias_node(node: any, depth: number): any?
	if type(node) ~= "table" or depth > 12 then return nil end
	if node.k == "text" and type(node.p) == "table" and node.p.role == "orchplus.alias" then
		local spans = node.p.spans
		if type(spans) ~= "table" or #spans ~= 1 then return nil end
		local encoded = if type(spans[1]) == "string" then spans[1] else spans[1].t
		if type(encoded) ~= "string" or #encoded > 8192 then return nil end
		local ok, value = pcall(tern.json.decode, encoded)
		if ok and type(value) == "table" and value.version == 2 and type(value.alias_nonce) == "string" then return value end
		return nil
	end
	if type(node.c) == "table" then
		for _, child in node.c do
			local found = alias_node(child, depth + 1)
			if found ~= nil then return found end
		end
	end
	return nil
end
local function alias(cx: WindowCx, pane: number): any?
	local info = cx.session:pane(pane)
	if info == nil or info.block ~= BLOCK then return nil end
	local ok, tree = pcall(function() return cx.session:surface(pane, { root = "main.ownership-alias", nodes = 4, depth = 2, max_chars = 8192 }) end)
	if not ok or type(tree) ~= "table" then return nil end
	return alias_node(tree.main, 0)
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
			local updated_membership = tab_sessions(next_cx)
			local owner_session = if pane.tab ~= nil then updated_membership[pane.tab] else nil
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
-- Only role-keyed native plugin nodes are consumed. No screen/transcript path exists.
local function machine_node(node: any, role: string, depth: number): any?
	if type(node) ~= "table" or depth > 16 or (node.more ~= nil and node.more ~= 0) then return nil end
	if node.k == "text" and type(node.p) == "table" and node.p.role == role then return node end
	for _, child in node.c or {} do local found = machine_node(child, role, depth + 1); if found then return found end end
	return nil
end
-- The tick re-reads the same host-published nodes many times per turn; a strict Luau decode of
-- each costs most of the 50 ms window budget. Identical bytes decode to the identical value, so
-- successful decodes are memoized by exact bytes (bounded). Callers may mutate what they read,
-- so every read gets its own copy of the cached value: a plain table copy is far cheaper than
-- the strict decode, and strictness is unchanged because a hit requires an earlier decode.
local decoded = (function()
	local LIMIT = 128
	local cache: any, order: any = {}, {}
	-- strict_decode builds arrays with tern.json.array() (a native marker metatable, which
	-- table.clone cannot copy) and objects as plain tables; rebuild each the same way.
	local function copy(value: any): any
		if type(value) ~= "table" then return value end
		local out = if getmetatable(value) ~= nil then tern.json.array() else {}
		for key, child in value do out[key] = copy(child) end
		return out
	end
	return function(bytes: string, maximum: number): any?
		if #bytes > maximum then return nil end
		local hit = cache[bytes]
		if hit == nil then
			hit = codec.strict_decode(bytes, maximum)
			if hit == nil then return nil end
			cache[bytes] = hit; table.insert(order, bytes)
			if #order > LIMIT then cache[table.remove(order, 1)] = nil end
		end
		return copy(hit)
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
	local node = machine_node(tree.main, role, 0)
	if node == nil or node.id ~= root or type(node.p.spans) ~= "table" or #node.p.spans ~= 1 then return nil, nil end
	local span = node.p.spans[1]; local bytes = if type(span) == "string" then span else span.t
	if type(bytes) ~= "string" or #bytes > limit then return nil, nil end
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
local function same_origin(left: any, right: any): boolean
	if type(left) ~= "table" or type(right) ~= "table" then return false end
	for key, value in left do if right[key] ~= value then return false end end
	for key, value in right do if left[key] ~= value then return false end end
	return true
end
-- Policies carry the excluded_workers list, so the stale-editor check compares them deeply.
local function same_policy(left: any, right: any): boolean
	if type(left) ~= type(right) then return false end
	if type(left) ~= "table" then return left == right end
	for key, value in left do if not same_policy(value, right[key]) then return false end end
	for key in right do if left[key] == nil then return false end end
	return true
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
}
-- Request IDs this window incarnation sent. A refusal shown for an action is this window's own
-- evidence only when it answers one of them; another window's (or an older incarnation's)
-- refusal never holds this window's driver. Bounded FIFO: the oldest IDs age out.
local ISSUED_LIMIT = 512
local issued: any, issued_order: any = {}, {}
local function remember_issued(request_id: string)
	if issued[request_id] then return end
	issued[request_id] = true; table.insert(issued_order, request_id)
	if #issued_order > ISSUED_LIMIT then issued[table.remove(issued_order, 1)] = nil end
end
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
	if #bytes > 8192 then notice(cx, source, origin.alias_nonce, "Task request exceeds the 8192-byte native bridge limit; shorten the explicit assignment. Nothing was queued."); return nil end
	cx.session:event(source, { ev = "action", id = node.id, act = if operator then "dispatch-operator-command" else "dispatch-command", value = bytes })
	remember_issued(event.request_id)
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
local function native_observation(cx: WindowCx, source: number, worker: any): (string, string?, any?, string?)
	local binding, origin = worker.pane_binding, worker.origin_binding
	if not binding or not origin or not current_origin(cx, source, origin)
		or binding.window_key ~= cx:window_key() or binding.window_epoch ~= incarnation
		or binding.native_session_id ~= origin.native_session_id or binding.window_host_id ~= origin.window_host_id then
		return "unknown", "Awaiting the exact authorized window/session binding; after reload run ORCH+ Continue controller in this window from the palette. Restored numeric pane IDs are not identity.", nil
	end
	local target = tonumber(binding.pane_id)
	local pane = if target then cx.session:pane(target) else nil
	local host = if target then host_for(cx, target) else nil
	if not pane or not host or host.state ~= "connected" or tostring(host.id) ~= binding.window_host_id
		or pane.tab == nil or tostring(tab_sessions(cx)[pane.tab]) ~= binding.native_session_id then
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
-- Per-action window bookkeeping (`executed` grant markers, `auto_reconcile` state, `held_actions`)
-- is pruned only on positive evidence, read from the action's own controller pane, that it
-- settled: phase complete/resolved, or a current claim other than the marked grant. Missing,
-- clipped or unreadable evidence keeps every marker; one watched action is checked per tick.
local settle_watch: any, settle_order: any, settle_cursor = {}, {}, 0
local function watch_settle(source: number, action_id: string, grant_id: string?)
	local entry = settle_watch[action_id]
	if entry == nil then entry = { grants = {} }; settle_watch[action_id] = entry; table.insert(settle_order, action_id) end
	entry.source = source
	if grant_id then entry.grants[grant_id] = true end
end
local bridge_by_source: any = {}
local timer: any = nil
-- Effect deadlines measure awake progress, not wall time across a host suspension. The one
-- observation timer ticks every TICK_MS; a gap far beyond that between two ticks (sleep, App
-- Nap, a paused hook) counts only as one nominal tick. Deadlines are extended, never shortened.
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
-- Automatic read-only reconciliation of an uncertain retained effect: the same status read as
-- the owner's "Read retained SPAWN outcome" control, one read per attempt after awake backoff.
-- It never claims, executes or re-sends the effect; exhausted attempts leave the owner control.
local AUTO_RECONCILE_DELAYS = { 2000, 10000, 30000, 60000 }
local auto_reconcile: any = {}
-- Idempotent ACK/reply publications additionally get the plan's "readback before retry": after one
-- non-definitive registry read, the host resolves the uncertain attempt and the outbox re-issues the
-- exact same immutable bytes, which SPAWN reads back first and republishes only if absent. At most
-- AUTO_READBACKS times per publication identity; native effects never take this path.
local AUTO_READBACKS = 3
-- Publication identity -> attempts. Bounded FIFO like `issued`: an identity this old has long
-- settled, and a readback is read-only, so aging one out never repeats a native effect.
local AUTO_READBACK_LIMIT = 512
local auto_readback: any, auto_readback_order: any = {}, {}
local function count_readback(identity: string)
	if auto_readback[identity] == nil then
		table.insert(auto_readback_order, identity)
		if #auto_readback_order > AUTO_READBACK_LIMIT then auto_readback[table.remove(auto_readback_order, 1)] = nil end
	end
	auto_readback[identity] = (auto_readback[identity] or 0) + 1
end
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
-- A claim refused with `full` is pre-effect: the action is still `ready` and was never granted.
-- It resumes automatically with awake backoff through the same exact host claim rules, at most
-- CAPACITY_RETRIES times; after that it holds for the owner's "Run queued" control. Uncertain,
-- claimed or settled actions never enter this path.
local CAPACITY_RETRY_MS = 5000
local CAPACITY_RETRIES = 120
local capacity_waits: any = {}
-- Host commits can lag behind the 500 ms observation tick. A claim is therefore sent once and
-- only re-sent with awake backoff while its action still looks `ready`; the host refuses any
-- duplicate anyway (effect_already_claimed), so a re-send only covers a lost window event.
local CLAIM_RETRY_MS = { 1000, 2000, 4000, 8000 }
local claims_in_flight: any = {}
-- A captured SPAWN outcome awaiting its host commit receipt is replayed with awake backoff,
-- not every tick; each replay is idempotent at the host (deterministic result request ID).
local REPLAY_RETRY_MS = { 1000, 2000, 4000, 8000, 15000 }
-- The outcome is already in hand, so waiting never risks repeating an effect. `lost` is sent
-- only once the host has shown no rendered progress for DELIVERY_IDLE_MS (Tern's longest hook
-- pause is 5 min) or after DELIVERY_MAX_MS in total; both are awake time.
local DELIVERY_IDLE_MS = 300000
local DELIVERY_MAX_MS = 900000
local function retry_delay(delays: { number }, attempt: number): number
	return delays[math.clamp(attempt, 1, #delays)]
end
-- What the controller block has rendered for this scope: changes whenever the host commits or
-- answers a command for it.
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
-- A retained `backpressure` action is SPAWN's definitive pre-effect refusal: a retryable `full`
-- with effect_started=false (an expired, never-consumed window authorization is reported the
-- same way). It is rechecked with the capacity backoff by sending the owner's exact `retry`
-- command, driven like that control, one per lane at a time and at most CAPACITY_RETRIES times;
-- after that it holds for the owner's control. Uncertain actions never enter this path.
local recheck_waits: any = {}
local function recheck_hold(source: number, action_id: string)
	local wait = recheck_waits[action_id] or { attempts = 0 }
	wait.next_at = awake_now() + CAPACITY_RETRY_MS; wait.source = source
	recheck_waits[action_id] = wait
end
local start_driver: any = nil -- Assigned after the observation timer helpers.
-- Guided reload recovery state: a pending read-only SPAWN owner_status probe per controller and
-- the latest observed SPAWN owner state for this window's controller alias.
local guides: any = {}
local owner_states: any = {}
-- Owner withdrawal of fenced never-launched work: a pending read-only SPAWN `status` of the exact
-- fenced request per controller, answered into that controller's `cancel_work` (see withdraw_step).
local withdrawals: any = {}
-- USAGE capacity reader (defined after the timer helpers). One reader per controller source.
local readers: any = {}
-- Controller source -> its one `usage.capacity` pane (lost on reload; the sweep and reader_step
-- reuse/close earlier incarnations' panes so a reload never stacks another reader).
local usage_by_source: any = {}
local validations: any = {}
local start_reader: any = nil
local reader_step: any = nil
-- SPAWN bridge lifecycle. A bridge is one `spawn.dispatch` pane; its single response node carries
-- one read at a time. This window binds at most one bridge per controller source and lane
-- (`bridge_by_source`, lost on every window/plugin reload). Before opening another pane it adopts
-- an idle bridge of the same controller (pane, alias, window) in the same host session: SPAWN's
-- lease marker (SPAWN_BRIDGE v1) must show no requested authorization naming it, no live execution
-- projection and no verification in flight, and no current driver or owner probe may use it.
-- Inert bridges left by earlier incarnations of this window are closed through the native pane
-- close, one per pass; up to two in the bridge tab stay as reload spares while their controller
-- is present. Unknown, legacy or unreadable leases are never reused or closed.
-- Bridges are never moved between tabs or parked. A pane moved with move_to_tab/move_to_new_tab
-- answers cx.session:surface with nil in the live window, so neither ORCH+ nor SPAWN's window
-- executor could read it again, and a parked pane has no provable session. Each bridge opens where
-- it stays: the session's first in a new "SPAWN bridges" tab, later ones beside a pane there.
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
-- Session and host ids (strings) of a tabbed bridge pane on a connected host.
local function bridge_scope(cx: WindowCx, pane: number, membership: any): (string?, string?)
	local info = cx.session:pane(pane)
	if info == nil or info.block ~= BRIDGE_BLOCK or info.tab == nil or membership[info.tab] == nil then return nil, nil end
	local host = host_for(cx, pane)
	if host == nil or host.state ~= "connected" then return nil, nil end
	return tostring(membership[info.tab]), tostring(host.id)
end
-- Tabs holding nothing but bridges and USAGE capacity readers (the background bridge tab), each
-- with its lowest pane.
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
-- Open a bridge (or USAGE capacity reader) where it will stay. With a bridge tab in the
-- controller's session, split one of its panes (a block created there is readable even beside an
-- unreadable moved pane). Otherwise open the session's bridge tab with this block and name it. A
-- block that lands outside the controller's session is brand new and was never sent anything: it
-- is closed, and only then does it open beside the controller.
local function open_bridge(cx: WindowCx, source: number, block: string, args: any): number?
	local controller = cx.session:pane(source)
	local membership = tab_sessions(cx)
	local session = if controller and controller.tab ~= nil then membership[controller.tab] else nil
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
-- The reader pane for a controller: an idle `usage.capacity` pane already in the session's bridge
-- tab (left by an earlier incarnation; the block is read-only, so reuse is safe), else a new one
-- opened like a bridge.
local function acquire_usage(cx: WindowCx, source: number): number?
	local controller = cx.session:pane(source)
	local membership = tab_sessions(cx)
	local session = if controller and controller.tab ~= nil then membership[controller.tab] else nil
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
	if mapped ~= nil then
		local session, host = bridge_scope(cx, mapped, membership)
		if session == origin.native_session_id and host == origin.window_host_id then return mapped end
		bridge_by_source[key] = nil -- Closed or moved away: this lane binds a bridge afresh.
	end
	local candidates = {}
	for _, row in cx.session:panes() do
		if row.block == BRIDGE_BLOCK and row.tab ~= nil and not bridge_in_use(row.pane) then table.insert(candidates, row) end
	end
	table.sort(candidates, bridge_order(bridge_tabs(cx)))
	local reads = 0
	for _, row in candidates do
		if reads >= BRIDGE_SCAN_LIMIT then break end
		local pane = row.pane
		local session, host = bridge_scope(cx, pane, membership)
		if session == origin.native_session_id and host == origin.window_host_id then
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
-- One bounded pass per BRIDGE_SWEEP_MS awake: close one inert earlier-incarnation bridge of this
-- window. An unreadable lease keeps its pane: without it SPAWN's authorization.bridge listing is
-- unknown, so it might still be the bridge of a requested authorization.
local function bridge_sweep(cx: WindowCx)
	local now = awake_now()
	if now < bridge_sweep_at then return end
	bridge_sweep_at = now + BRIDGE_SWEEP_MS
	local host, current = cx.hosts:current(), cx.sessions:current()
	if host == nil or current == nil or host.state ~= "connected" then return end
	local membership = tab_sessions(cx)
	local tabs = bridge_tabs(cx)
	-- Earlier incarnations' idle USAGE capacity readers: those beside a controller close; the bridge
	-- tab keeps one unbound spare (for reuse after reload) only while no reader is bound.
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
-- Bounded read of the host's routing contract node (views.luau "routing-index").
local function routing_index(cx: WindowCx, source: number): any?
	local _, bytes = surface_node(cx, source, BLOCK, "orchplus.routing", "routing-index", 65536)
	local value = if bytes then decoded(bytes, 65536) else nil
	return if type(value) == "table" and value.version == 1 and type(value.records) == "table" and type(value.workers) == "table" then value else nil
end
local function public_frame(body: any): string
	local bytes = tern.json.encode(body)
	return "SPAWN_DISPATCH v1 " .. tern.json.encode({ schema = 1, op = body.op, request_id = body.request_id, complete = true,
		body_bytes = #bytes, body_sha256 = codec.sha256(bytes), body_json = bytes })
end
-- Stop driving a retained claim. An executing driver marks it lost (uncertain) and tells the
-- owner; an automatic read-only attempt on an already uncertain action only ends, leaving the
-- action and its owner control unchanged.
local function abandon(cx: WindowCx, driver: any, uncertain: boolean, action_id: string, executor: string, grant_id: string, message: string)
	if not (driver.auto and uncertain) then
		send_command(cx, driver.source, driver.origin, "lost", { action_id = action_id, executor = executor, grant_id = grant_id })
		notice(cx, driver.source, driver.origin.alias_nonce, message)
	end
	drivers[driver.key or driver.source] = nil
end
local function advance(cx: WindowCx, driver: any)
	if not current_origin(cx, driver.source, driver.origin) then
		-- Never switch sessions/focus to finish background work. A persisted claim stays held.
		drivers[driver.key or driver.source] = nil
		return
	end
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
		-- A deferred, never-captured wake may be removed by the host after a busy
		-- observation. Drop only its inert driver, never a captured grant/delivery.
		-- Missing surfaces never redirect execution or change durable claim state.
		if driver.scope and not driver.action_id and not driver.delivery then drivers[driver.key or driver.source] = nil end
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
		if matched and not command_result.action_id and not driver.scope and not driver.delivery then drivers[driver.key or driver.source] = nil; return end
		driver.command_request_id = nil
		-- Unrelated workflow controls cannot strand an already captured grant/delivery.
		if matched and command_result.ok == false and (not a or a.phase == "complete") and not driver.delivery then drivers[driver.key or driver.source] = nil; return end
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
			if driver.auto and a and a.action_id == delivery.action_id and a.phase == "uncertain" then drivers[driver.key or driver.source] = nil; return end
		elseif outcome and outcome.action_id == delivery.action_id and outcome.grant_id == delivery.grant_id and outcome.ok == false then
			drivers[driver.key or driver.source] = nil; return -- A failed host commit is not an ACK or permission to repeat the native effect.
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
			if not current_origin(cx, driver.source, driver.origin) then drivers[driver.key or driver.source] = nil end
			return
		end
	end
	local relevant_result = outcome and ((a and outcome.action_id == a.request.action_id
		and (outcome.grant_id == nil or (a.claim and outcome.grant_id == a.claim.grant_id)))
		or (outcome.action_id == nil and (a == nil or a.phase == "complete")))
	-- A grantless refusal (claim, operator or workflow command) is this driver's evidence only if
	-- this window sent that request. A refused duplicate claim whose sibling claim by this window
	-- already won is superseded: the action is claimed for us and the driver continues with it.
	if relevant_result and outcome.ok == false and outcome.grant_id == nil
		and (not issued[outcome.request_id] or (outcome.code == "effect_already_claimed" and a and a.phase ~= "ready"
			and a.claim and a.claim.executor == incarnation)) then relevant_result = false end
	if relevant_result and ((outcome.ok == false and outcome.code ~= "pending") or outcome.code == "bridge_rejected" or outcome.code == "effect_uncertain" or outcome.code == "backpressure") then
		if a and a.phase == "ready" and outcome.ok == false and outcome.code == "full" then
			capacity_hold(driver.source, a.action_id, outcome.request_id) -- Pre-effect capacity refusal: resume when slots free.
		elseif a and a.phase == "backpressure" and outcome.code == "backpressure" then
			recheck_hold(driver.source, a.action_id) -- Definitive pre-effect refusal: bounded automatic recheck.
		elseif a then held_actions[a.action_id] = true; watch_settle(driver.source, a.action_id) end
		drivers[driver.key or driver.source] = nil; return
	end
	if relevant_result and outcome.code == "coordinator_retired" then drivers[driver.key or driver.source] = nil; return end
	if a and a.worker_id then driver.worker_id = a.worker_id end
	if driver.action_id and (not a or a.request.action_id ~= driver.action_id or a.phase == "complete") then
		driver.query = nil; driver.sent = nil; driver.action_id = nil; driver.started = nil; driver.last_response = nil; driver.require_status = nil; driver.next_status = nil
	end
	if a and a.phase ~= "ready" then claims_in_flight[a.action_id] = nil end -- Its claim was answered.
	if a == nil or a.phase == "complete" then drivers[driver.key or driver.source] = nil; return end
	local request = a.request
	local execution_origin = a.execution_origin or request.origin_binding
	-- An automatic attempt follows only the owner control's exact route for its retained claim;
	-- a changed route or phase ends the attempt instead of idling a driver.
	if driver.auto and not (a.claim and (a.phase == "uncertain" or a.phase == "claimed")
		and (a.reconciliation_only or (a.claim.executor == incarnation and request.controller_pane == tostring(driver.source)))
		and same_origin(execution_origin, driver.origin) and current_origin(cx, driver.source, execution_origin)) then
		drivers[driver.key or driver.source] = nil; return
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
				if (not deferred or not deferred.action or deferred.action.phase == "complete") and not driver.action_id and not driver.delivery then
					drivers[driver.key or driver.source] = nil
				end
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
			-- Quota-routed work: never claim while held/gated; a routed launch first gets USAGE to
			-- confirm the exact decision revision is still current, immediately before the claim.
			-- Unrouted (explicit) work has no `routing` on its worker node and claims exactly as before.
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
	driver.claim_executor = a.claim.executor
	capacity_waits[request.action_id] = nil
	driver.action_id = request.action_id
	driver.grant_id = a.claim.grant_id
	driver.started = driver.started or awake_now()
	if a.wake_status == "awaiting_window" then driver.started = awake_now() end -- No wake effect has begun; busy is not uncertainty.
	local expired = awake_now() - driver.started > EFFECT_DEADLINE_MS
	if expired and not executed[a.claim.grant_id] and a.phase == "claimed" and driver.reconcile_action_id ~= request.action_id then
		abandon(cx, driver, false, request.action_id, a.claim.executor, a.claim.grant_id,
			"The effect deadline elapsed before native submission. Its exact claim remains retained; no late native effect was started.")
		return
	end
	if driver.bridge == nil then
		driver.bridge = acquire_bridge(cx, driver.source, driver.origin, tostring(driver.worker_id or "catalog"))
		if driver.bridge == nil then
			abandon(cx, driver, a.phase == "uncertain", request.action_id, a.claim.executor, a.claim.grant_id,
				"Missing SPAWN dispatch bridge on this host. Install/enable the compatible SPAWN package; no raw-command fallback is available.")
			return
		end
		if not current_origin(cx, driver.source, driver.origin) then drivers[driver.key or driver.source] = nil; return end
	end
	local bridge_host = host_for(cx, driver.bridge)
	local bridge_pane = cx.session:pane(driver.bridge)
	if bridge_host == nil or tostring(bridge_host.id) ~= driver.origin.window_host_id or bridge_host.state ~= "connected"
		or bridge_pane == nil or bridge_pane.tab == nil or tostring(tab_sessions(cx)[bridge_pane.tab]) ~= driver.origin.native_session_id then
		abandon(cx, driver, a.phase == "uncertain", request.action_id, a.claim.executor, a.claim.grant_id,
			"The bound SPAWN bridge moved or became unavailable; its retained operation was not redirected or repeated.")
		return
	end
	local bridge_node, bytes = surface_node(cx, driver.bridge, "spawn.dispatch", "spawn.dispatch.response")
	if not bridge_node then
		driver.absent = (driver.absent or 0) + 1
		if driver.absent >= 10 then
			abandon(cx, driver, a.phase == "uncertain", request.action_id, a.claim.executor, a.claim.grant_id,
				"SPAWN bridge surface is incompatible, incomplete or clipped. Install the matching SPAWN_DISPATCH v1 bridge and inspect the retained claim.")
		end
		return
	end
	if not executed[a.claim.grant_id] and a.phase == "claimed" and driver.reconcile_action_id ~= request.action_id then
		executed[a.claim.grant_id] = true -- Set BEFORE the native event, including exceptions/lost callbacks.
		watch_settle(driver.source, request.action_id, a.claim.grant_id)
		driver.sent = true; driver.require_status = a.retry_count ~= nil; driver.last_response = nil
		cx.session:event(driver.bridge, { ev = "action", id = bridge_node.id, act = request.op, value = a.request_bytes })
		if not current_origin(cx, driver.source, driver.origin) then drivers[driver.key or driver.source] = nil end
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
			if a.reconciliation_only or driver.auto then
				-- An automatic attempt never takes the exact-request replay path below.
				if not driver.auto then
					notice(cx, driver.source, driver.origin.alias_nonce, "Retained outcome is too large for status inspection. The old effect is not resubmitted; reconcile its exact executor explicitly.")
				end
				drivers[driver.key or driver.source] = nil
				return
			end
			-- Exact retained request replay is a registry read, not a new launch permission.
			cx.session:event(driver.bridge, { ev = "action", id = bridge_node.id, act = request.op, value = a.request_bytes })
			driver.query = nil
			driver.require_status = nil
			return -- Read the direct retained outcome on the next turn before another status event.
		elseif body.status == "missing" and a.phase == "uncertain" and dispatch.READ_ONLY_OPS[request.op] then
			-- SPAWN holds no record of this retained read. The host checks this exact status evidence and
			-- resolves the read without effect; the normal poll lane then re-reads from the durable cursor.
			-- Mutating effects never take this path: for them `missing` stays uncertain below.
			send_command(cx, driver.source, driver.origin, "read_missing", { action_id = request.action_id, executor = a.claim.executor,
				grant_id = a.claim.grant_id, query_bytes = tern.json.encode(driver.query), response_bytes = bytes })
			drivers[driver.key or driver.source] = nil
			return
		else body = nil end
		driver.query = nil
		-- One SPAWN registry answer per automatic attempt: pending or unknown stays uncertain.
		if driver.auto and a.phase == "uncertain" and (body == nil or table.find({ "resolved", "claimed", "launching", "pending" }, body.status)) then
			drivers[driver.key or driver.source] = nil; return
		end
	end
	if body and bytes == driver.last_response then body = nil end
	if body and not table.find({ "resolved", "claimed", "launching", "pending" }, body.status) then
		if #bytes <= 8192 and current_origin(cx, driver.source, driver.origin) then
			local now = awake_now()
			driver.delivery = { action_id = request.action_id, grant_id = a.claim.grant_id, executor = a.claim.executor, bytes = bytes,
				response_sha256 = codec.sha256(bytes), started = now, replays = 0, next_replay = now + retry_delay(REPLAY_RETRY_MS, 1),
				progress = host_progress(data), progress_at = now }
			cx.session:event(driver.source, { ev = "action", id = node.id, act = "dispatch-result/" .. a.claim.grant_id .. "/" .. driver.origin.window_epoch, value = bytes })
		end
		return
	end
	-- A delayed timer must first consume an already available, correlated outcome.
	-- Expiry limits waiting/submission; it never invalidates conclusive retained evidence.
	if expired then
		abandon(cx, driver, a.phase == "uncertain", request.action_id, a.claim.executor, a.claim.grant_id,
			"No conclusive SPAWN outcome is available after the effect deadline. The exact claim remains occupied; read its retained outcome or explicitly recover it.")
		return
	end
	if driver.query == nil then
		if (a.wake_status ~= nil or driver.auto) and tern.now() < (driver.next_status or 0) then return end
		driver.next_status = tern.now() + 5000
		driver.query = { schema = 1, origin = "orchplus", op = "status", request_id = dispatch_id(), action_id = dispatch_id(),
			origin_binding = request.origin_binding, controller_pane = tostring(driver.source), controller_generation = request.controller_generation,
			target_request_id = request.request_id }
		cx.session:event(driver.bridge, { ev = "action", id = bridge_node.id, act = "status", value = tern.json.encode(driver.query) })
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
-- While a block shows Config, push this window's agent panes in the current native session and host.
-- A managed worker is named only through its exact current window binding; otherwise rows are hand-opened.
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
-- Start one bounded automatic read-only attempt for an uncertain retained effect once its awake
-- backoff is due. Only actions the owner control's driver could read through the same exact
-- route are eligible; everything else keeps waiting for the owner.
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
		if (auto_readback[identity] or 0) < AUTO_READBACKS then
			state.readback = true; count_readback(identity)
			send_command(cx, source, origin, "readback_publication", { action_id = a.action_id })
			return
		end
	end
	state.attempts += 1
	state.next_at = awake_now() + (AUTO_RECONCILE_DELAYS[state.attempts + 1] or 0)
	drivers[key] = { key = key, source = source, origin = origin, scope = a.action_id, worker_id = worker_id,
		reconcile_action_id = a.action_id, auto = true, stale_result = if scoped.result then scoped.result.request_id else nil }
end
-- Nightly orphan mailbox sweep. The local wall clock defines the scheduled day: the latest slot at
-- or before now (today's sweep_time, else yesterday's). A slot newer than the durable last run is
-- due, on time or once as a catch-up on the next attach or wake. The host refuses any date at or
-- before its recorded last run, so reloads and duplicate views never run one day twice.
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
-- The controller blocks this window scans each tick: in its current session on its current host.
local function scanned_controller(pane: any, membership: any, session: any): boolean
	return pane.block == BLOCK and pane.tab ~= nil and membership[pane.tab] == session.id
end
local function schedule(cx: WindowCx)
	local host, session = cx.hosts:current(), cx.sessions:current()
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
		sweep_due(cx, source, origin, flow)
		-- Quota routing: refresh USAGE evidence when none is current or routed work awaits it.
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
						send_command(cx, source, origin, "reply", { worker_id = worker.worker_id })
					elseif worker.due_poll or (worker.report_request_pending and not worker.report_held) then
						-- A held report blocks this generation's report lane: no automatic report or
						-- watermark re-read until the owner acts; due_poll covers outbound settlement.
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
			if wait.source == source and not held_actions[action_id] and awake_now() >= wait.next_at then
				local busy = false
				for _, other in drivers do if other.source == source and other.scope == action_id then busy = true end end
				local scoped = if busy then nil else snapshot(cx, source, action_id)
				if not busy and (scoped == nil or not scoped.action or scoped.action.phase ~= "ready") then capacity_waits[action_id] = nil
				elseif scoped then
					local lane = scoped.action.worker_id or "catalog"
					for _, other in drivers do if other.source == source and (other.worker_id or "catalog") == lane then busy = true end end
					local key = tostring(source) .. ":capacity:" .. action_id
					if not busy then drivers[key] = { key = key, source = source, origin = origin, scope = action_id, worker_id = scoped.action.worker_id, stale_result = wait.stale } end
				end
			end
		end
		-- Definitive pre-effect backpressure: once its backoff is due, send the owner's exact `retry`
		-- and drive it like that control. Never while this source's command driver or the action's
		-- lane is busy; anything no longer retryable on this exact route leaves the wait.
		for action_id, wait in recheck_waits do
			if wait.source == source and not held_actions[action_id] and awake_now() >= wait.next_at then
				local busy = drivers[source] ~= nil
				for _, other in drivers do if other.source == source and other.scope == action_id then busy = true end end
				local scoped = if busy then nil else snapshot(cx, source, action_id)
				local a = if scoped then scoped.action else nil
				if not busy and (a == nil or (a.phase ~= "backpressure" and a.phase ~= "ready" and a.phase ~= "claimed")
					or not same_origin(a.request.origin_binding, origin) or a.request.controller_pane ~= tostring(source)) then
					recheck_waits[action_id] = nil
				elseif a and a.phase == "backpressure" and wait.attempts >= CAPACITY_RETRIES then
					recheck_waits[action_id] = nil; held_actions[action_id] = true; watch_settle(source, action_id)
				elseif a and a.phase == "backpressure" then
					local lane = a.worker_id or "catalog"
					for _, other in drivers do if other.source == source and (other.worker_id or "catalog") == lane then busy = true end end
					if not busy then
						wait.attempts += 1; wait.next_at = awake_now() + CAPACITY_RETRY_MS
						local id = send_command(cx, source, origin, "retry", { action_id = action_id }, true)
						if id then start_driver(source, origin, id, a.worker_id) end
					end
				end
			end
		end
		-- Every uncertain retained action gets bounded automatic read-only reconciliation, whichever
		-- action is selected or active. One read per bridge lane at a time: concurrent reads would
		-- overwrite that bridge's single response node.
		for _, action_id in (if type(data.uncertain_actions) == "table" then data.uncertain_actions else {}) do
			local busy = false
			for _, other in drivers do if other.source == source and other.scope == action_id then busy = true end end
			local scoped = if busy then nil else snapshot(cx, source, action_id)
			if scoped and scoped.action and scoped.action.phase == "uncertain" then
				local lane = scoped.action.worker_id or "catalog"
				for _, other in drivers do if other.source == source and (other.worker_id or "catalog") == lane then busy = true end end
				if not busy then auto_reconcile_due(cx, source, origin, scoped, tostring(source) .. ":auto:" .. action_id, scoped.action.worker_id) end
			end
		end
	end
	for source in scans do if not live[source] then scans[source] = nil end end
	for source in sweep_attempts do if not live[source] then sweep_attempts[source] = nil end end
	for source in pane_pushes do if not live[source] then pane_pushes[source] = nil end end
	prune_settled(cx)
end
-- Guided reload recovery. One owner flow lists every remaining step in order and opens each as
-- the existing explicit, attested control: controller continuation, SPAWN's own Config owner
-- recovery (fence, verify, confirm — never attested from ORCH+), then per-worker reattachment.
-- SPAWN's owner state comes from a read-only owner_status read that reserves and changes nothing.
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
local function probe_step(cx: WindowCx)
	for source, guide in guides do
		if not current_context(cx, source, guide.origin) then guides[source] = nil; continue end
		local state: string? = nil
		if guide.query == nil then
			-- The probe shares the catalog bridge lane; never overwrite a live read's response node.
			local busy = withdrawals[source] ~= nil and withdrawals[source].query ~= nil
			for _, other in drivers do if other.source == source and other.worker_id == nil then busy = true end end
			local bridge = if busy then nil else acquire_bridge(cx, source, guide.origin, "catalog")
			local node = if bridge ~= nil then surface_node(cx, bridge, "spawn.dispatch", "spawn.dispatch.response") else nil
			if node then
				guide.bridge = bridge
				guide.query = { schema = 1, origin = "orchplus", op = "owner_status", request_id = dispatch_id(), action_id = dispatch_id(),
					origin_binding = guide.origin, controller_pane = tostring(source), controller_generation = guide.origin.owner_generation }
				cx.session:event(bridge, { ev = "action", id = node.id, act = "owner_status", value = tern.json.encode(guide.query) })
			end
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
-- One read-only SPAWN `status` of the fenced request on the catalog lane, then the owner's
-- `cancel_work` carrying that exact query and answer; the host decides whether it is definitively
-- unexecutable. No answer within 10 s awake ends with a notice and nothing is cancelled.
local function withdraw_step(cx: WindowCx)
	for source, probe in withdrawals do
		if not current_origin(cx, source, probe.origin) then withdrawals[source] = nil; continue end
		if probe.query == nil then
			local busy = guides[source] ~= nil and guides[source].query ~= nil
			for _, other in drivers do if other.source == source and other.worker_id == nil then busy = true end end
			local bridge = if busy then nil else acquire_bridge(cx, source, probe.origin, "catalog")
			local node = if bridge ~= nil then surface_node(cx, bridge, "spawn.dispatch", "spawn.dispatch.response") else nil
			if node then
				probe.bridge = bridge
				probe.query = { schema = 1, origin = "orchplus", op = "status", request_id = dispatch_id(), action_id = dispatch_id(),
					origin_binding = probe.fenced.origin_binding, controller_pane = tostring(source), controller_generation = probe.fenced.controller_generation,
					target_request_id = probe.fenced.request_id }
				cx.session:event(bridge, { ev = "action", id = node.id, act = "status", value = tern.json.encode(probe.query) })
			end
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
					drivers[driver.key or driver.source] = nil
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
		end
	end)
end
start_driver = function(source: number, origin: any, request_id: string, worker_id: string?)
	local driver = drivers[source]
	-- An automatic read that has not captured a grant yields to the owner's command.
	if driver == nil or (driver.auto and not driver.action_id and not driver.delivery) then driver = { source = source, origin = origin } end
	driver.command_request_id = request_id
	if worker_id and not driver.action_id and not driver.delivery then driver.worker_id = worker_id end
	drivers[source] = driver; arm() -- Never discard a live action's captured delivery/grant.
end
-- USAGE capacity consumer. Reads only USAGE's public native `usage.capacity` block (owner-enabled,
-- revocable export): bounded surface reads, versioned correlated responses, every page of one
-- immutable revision assembled and verified (byte length + SHA-256) before parsing, then USAGE
-- `validate` before the host records the normalized evidence. No USAGE private state or credentials.
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
	local host, placed = host_for(cx, pane), cx.session:pane(pane)
	if host == nil or tostring(host.id) ~= origin.window_host_id or host.state ~= "connected"
		or placed == nil or placed.tab == nil or tostring(tab_sessions(cx)[placed.tab]) ~= origin.native_session_id then
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
	-- Hash the delivered pages incrementally, one bounded step per tick (quota.HASH_BLOCKS_PER_STEP),
	-- so no single 50 ms callback hashes the whole document. An interrupted step fails closed.
	local assembly = reader.assembly
	if assembly ~= nil and reader.document == nil then
		local _, hash_failure = quota.hash_step(assembly)
		if hash_failure then reader_done(cx, reader, false, "USAGE capacity " .. hash_failure.code .. ": " .. hash_failure.message .. " No evidence was used."); return end
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
			if not document then reader_done(cx, reader, false, "USAGE capacity " .. failure.code .. ": " .. failure.message .. " No evidence was used."); return end
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
		if not ok then reader_done(cx, reader, false, "USAGE capacity " .. err.code .. ": " .. err.message .. " No evidence was used."); return end
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
-- An attach candidate is an idle, recognized native agent pane of this exact window, native session
-- and host that no managed worker already binds. Terminal/shell panes are never candidates.
local function adoption_candidate(cx: WindowCx, source: number, target: any, origin: any): any?
	if type(target) ~= "number" or not current_origin(cx, source, origin) then return nil end
	local pane, host = cx.session:pane(target), host_for(cx, target)
	if target == source or not pane or pane.block ~= nil or pane.tab == nil or not host or host.state ~= "connected"
		or tostring(host.id) ~= origin.window_host_id or tostring(tab_sessions(cx)[pane.tab]) ~= origin.native_session_id then return nil end
	local native = nil
	for _, agent in cx.agents:list() do if agent.pane == target then native = agent; break end end
	if not native or native.state ~= "idle" or (native.delivery_error ~= nil and native.delivery_error ~= tern.json.null) then return nil end
	local binding = { pane_id = tostring(target), window_key = origin.window_key, window_epoch = origin.window_epoch,
		native_session_id = origin.native_session_id, window_host_id = origin.window_host_id }
	local flow = workflow_node(cx, source, "workflow-index", "orchplus.workflow")
	for _, worker_id in (if flow and type(flow.worker_ids) == "table" then flow.worker_ids else {}) do
		local worker = worker_now(cx, source, worker_id)
		if worker and (same_origin(worker.pane_binding, binding) or same_origin(worker.adopt_pane_binding, binding)) then return nil end
	end
	return binding
end
local function continuation_candidate(cx: WindowCx, source: number, target: number, origin: any): any?
	if not current_context(cx, source, origin) then return nil end
	local pane, host = cx.session:pane(target), host_for(cx, target)
	if target == source or not pane or pane.block ~= nil or pane.tab == nil or not host or host.state ~= "connected"
		or tostring(host.id) ~= origin.window_host_id or tostring(tab_sessions(cx)[pane.tab]) ~= origin.native_session_id then return nil end
	local recognized = false
	for _, agent in cx.agents:list() do if agent.pane == target then recognized = true; break end end
	if not recognized and pane.kind ~= "terminal" then return nil end
	return { pane_id = tostring(target), window_key = origin.window_key, window_epoch = origin.window_epoch,
		native_session_id = origin.native_session_id, window_host_id = origin.window_host_id }
end
local function dispatch_control(cx: WindowCx, source: number, request: any)
	local origin = origin_now(cx, source, request)
	if not origin then notice(cx, source, request.source_nonce, "Dispatch refused: this is not the admitted controller in its current host/session. No session was switched."); return end
	if request.command == "recovery_guide" then
		start_guide(source, origin, true); arm()
		return
	end
	if request.command == "continue_controller" then
		local data = snapshot(cx, source)
		if not data or (request.expected_revision and request.expected_revision ~= data.revision) then
			notice(cx, source, origin.alias_nonce, "Controller revision changed. Run ORCH+ Continue controller in this window from the palette again.")
			return
		end
		local revision = data.revision
		cx:pick({ placeholder = "Continue controller " .. origin.owner_id .. " / generation " .. tostring(origin.owner_generation)
			.. " / revision " .. tostring(revision) .. "? Old claims and coordinator uncertainty stay held.", items = {
			{ label = "Cancel — retain current binding", continue_controller = false },
			{ label = "I independently verified previous ORCH+/SPAWN executors stopped or retired",
				detail = "Operator attestation, not native proof. Enables retained-outcome inspection; never retries old effects or clears pending claims.", continue_controller = true },
		} }):next(function(choice: any, err: string?, fresh: WindowCx?)
			if not fresh or not choice or err or not choice.continue_controller or not current_context(fresh, source, origin) then return end
			local current = snapshot(fresh, source)
			if not current or current.revision ~= revision then
				notice(fresh, source, origin.alias_nonce, "Controller changed during verification. Run ORCH+ Continue controller in this window again; nothing was rebound.")
				return
			end
			local continued = send_command(fresh, source, origin, "continue_controller", { expected_revision = revision, operator_verified = true }, true)
			-- After continuation, list every remaining recovery step (SPAWN owner, reattachments).
			if continued then start_guide(source, origin, true); arm() end
		end)
		return
	end
	if not current_origin(cx, source, origin) then
		notice(cx, source, origin.alias_nonce, "This window is not the continued execution origin. Run the palette command ORCH+ Continue controller in this window, inspect retained outcomes, then explicitly reattach workers.")
		return
	end
	if request.command == "continue_worker" then
		local worker = if type(request.worker_id) == "string" then worker_now(cx, source, request.worker_id) else nil
		if not worker or type(worker.continuation_proof) ~= "string" then return end
		local proof = worker.continuation_proof
		local candidates = { { label = "Cancel — do not adopt a pane" } }
		for _, pane in panes_on(cx, cx.hosts:current()) do
			if continuation_candidate(cx, source, pane.pane, origin) then
				table.insert(candidates, { label = "Inspect and select existing pane " .. tostring(pane.pane),
					detail = "Explicit operator identification required; number and current membership are not worker identity proof.", pane = pane.pane })
			end
		end
		cx:pick({ placeholder = "Select the exact existing worker for " .. worker.work_id .. " / " .. worker.worker_id, items = candidates }):next(function(choice: any, err: string?, fresh: WindowCx?)
			if not fresh or not choice or err or not choice.pane or not current_origin(fresh, source, origin) then return end
			local candidate = continuation_candidate(fresh, source, choice.pane, origin)
			local updated = worker_now(fresh, source, worker.worker_id)
			if not candidate or not updated or updated.continuation_proof ~= proof or updated.worker_generation ~= worker.worker_generation then
				notice(fresh, source, origin.alias_nonce, "Worker, owner or retained executor evidence changed. No attachment was submitted.")
				return
			end
			fresh:pick({ placeholder = "Attach " .. worker.worker_id .. " / generation " .. tostring(worker.worker_generation)
				.. " to pane " .. candidate.pane_id .. " against its exact retained identity and executor evidence?", items = {
				{ label = "Cancel — retain original route", attach = false },
				{ label = "I verified this exact worker and old executors stopped or retired",
					detail = "Original launch: " .. tern.json.encode(worker.launch_origin_binding or worker.origin_binding)
						.. " · original pane: " .. tern.json.encode(worker.launch_pane_binding or worker.pane_binding)
						.. ". Decisions remain bound to this generation; uncertain effects are never retried.", attach = true },
			} }):next(function(confirmation: any, confirmation_error: string?, next_cx: WindowCx?)
				if not next_cx or not confirmation or confirmation_error or not confirmation.attach or not current_origin(next_cx, source, origin) then return end
				local recipient = worker_now(next_cx, source, worker.worker_id)
				local verified = continuation_candidate(next_cx, source, choice.pane, origin)
				if not recipient or recipient.continuation_proof ~= proof or recipient.worker_generation ~= worker.worker_generation
					or not verified or not same_origin(verified, candidate) then
					notice(next_cx, source, origin.alias_nonce, "Attachment confirmation expired; no pane was adopted.")
					return
				end
				local id = send_command(next_cx, source, origin, "continue_worker", { worker_id = worker.worker_id, pane_binding = candidate,
					continuation_proof = proof, operator_verified = true }, true)
				if id then start_driver(source, origin, id, worker.worker_id) end
			end)
		end)
		return
	end
	if request.command == "pause" or request.command == "resume" then
		send_command(cx, source, origin, request.command, nil, true)
		return
	elseif request.command == "policy" then
		local flow = workflow_node(cx, source, "workflow-index", "orchplus.workflow")
		if not flow or not flow.policy then return end
		local previous = flow.policy
		if not same_policy(previous, request.expected) then
			notice(cx, source, origin.alias_nonce, "Config changed since this control was displayed. Reopen Config; nothing changed.")
			return
		end
		if request.field == nil then
			-- Saved Config draft: the host reducer validates it and refuses a changed expected_policy.
			if type(request.policy) ~= "table" then return end
			send_command(cx, source, origin, "policy", { policy = request.policy, expected_policy = previous }, true)
			return
		end
		if request.field == "sweep_time" then
			cx:prompt({ value = tostring(previous.sweep_time or "03:00"), placeholder = "Nightly mailbox sweep time: local HH:MM (00:00–23:59)",
				action = "save sweep time" }):next(function(value: string?, err: string?, fresh: WindowCx?)
				if not fresh or not value or err or not current_origin(fresh, source, origin) then return end
				local current = workflow_node(fresh, source, "workflow-index", "orchplus.workflow")
				if not current or not same_policy(current.policy, previous) then
					notice(fresh, source, origin.alias_nonce, "Config changed while the editor was open. Reopen Config; the newer policy was not overwritten.")
					return
				end
				local hour, minute = value:match("^%s*(%d%d?):(%d%d)%s*$")
				local h, m = tonumber(hour), tonumber(minute)
				if not h or not m or h > 23 or m > 59 then
					notice(fresh, source, origin.alias_nonce, "Sweep time must be a local 24-hour HH:MM from 00:00 to 23:59; nothing changed.")
					return
				end
				send_command(fresh, source, origin, "policy", { policy = { sweep_time = string.format("%02d:%02d", h, m) }, expected_policy = previous }, true)
			end)
			return
		end
		local bounds = POLICY_FIELDS[request.field]
		if not bounds then return end
		cx:prompt({ value = tostring(previous[request.field]), placeholder = bounds.label .. ": whole number " .. tostring(bounds.minimum) .. "–" .. tostring(bounds.maximum),
			action = "save " .. bounds.label }):next(function(value: string?, err: string?, fresh: WindowCx?)
			if not fresh or not value or err or not current_origin(fresh, source, origin) then return end
			local current = workflow_node(fresh, source, "workflow-index", "orchplus.workflow")
			if not current or not same_policy(current.policy, previous) then
				notice(fresh, source, origin.alias_nonce, "Config changed while the editor was open. Reopen Config; the newer policy was not overwritten.")
				return
			end
			local digits = value:match("^%s*(%d+)%s*$")
			local number = if digits and #digits <= 9 then tonumber(digits) else nil
			if not number or number < bounds.minimum or number > bounds.maximum then
				notice(fresh, source, origin.alias_nonce, bounds.label .. " must be a whole number from " .. tostring(bounds.minimum) .. " to " .. tostring(bounds.maximum) .. "; nothing changed.")
				return
			end
			send_command(fresh, source, origin, "policy", { policy = { [request.field] = number }, expected_policy = previous }, true)
		end)
		return
	elseif request.command == "finish" then
		local worker = if type(request.worker_id) == "string" then worker_now(cx, source, request.worker_id) else nil
		if not worker or worker.coordinator_owner_id or worker.finish_requested then
			notice(cx, source, origin.alias_nonce, "Finish requires a current ordinary worker not already finishing. Coordinator retirement is separate.")
			return
		end
		cx:pick({ placeholder = "Finish " .. worker.work_id .. "? Stop and retire only after every gate, delivery and claim is settled.", items = {
			{ label = "Cancel — keep worker", finish = false },
			{ label = "Finish this ordinary worker", detail = worker.worker_id .. " / generation " .. tostring(worker.worker_generation), finish = true },
		} }):next(function(choice: any, err: string?, fresh: WindowCx?)
			if not fresh or not choice or err or not choice.finish or not current_origin(fresh, source, origin) then return end
			local current = worker_now(fresh, source, worker.worker_id)
			if not current or current.worker_generation ~= worker.worker_generation or current.finish_requested then
				notice(fresh, source, origin.alias_nonce, "Worker changed during confirmation; nothing was stopped.")
				return
			end
			local id = send_command(fresh, source, origin, "finish", { worker_id = worker.worker_id }, true)
			if id then start_driver(source, origin, id, worker.worker_id) end
		end)
		return
	elseif request.command == "rollover" or request.command == "cancel_rollover" then
		local worker = if type(request.worker_id) == "string" then worker_now(cx, source, request.worker_id) else nil
		local cancel = request.command == "cancel_rollover"
		local active = if worker and worker.rollover and worker.rollover.phase ~= "complete" and worker.rollover.phase ~= "cancelled" then worker.rollover else nil
		if not worker or worker.finish_requested or (cancel and not active) then
			notice(cx, source, origin.alias_nonce, "Rollover controls apply to a current worker or the activated coordinator.")
			return
		end
		local placeholder = if cancel then "Cancel rollover " .. active.id .. "? Only possible before a successor pane exists or coordinator retirement starts; the predecessor keeps running."
			elseif active then "Request the checkpoint again for rollover " .. active.id .. "? The previous checkpoint stays as evidence."
			elseif worker.coordinator_owner_id then "Roll over coordinator " .. worker.work_id .. "? ORCH+ asks for a verified checkpoint, retires and stops this coordinator, and only after its observed closure and slot release starts a fresh successor."
			else "Roll over " .. worker.work_id .. "? ORCH+ asks for a verified checkpoint, starts a fresh successor, and stops this worker only after the successor accepts."
		cx:pick({ placeholder = placeholder, items = {
			{ label = "Keep current state", confirm = false },
			{ label = if cancel then "Cancel this rollover" elseif active then "Request checkpoint again" elseif worker.coordinator_owner_id then "Roll over coordinator" else "Roll over worker", detail = worker.worker_id .. " / generation " .. tostring(worker.worker_generation), confirm = true },
		} }):next(function(choice: any, err: string?, fresh: WindowCx?)
			if not fresh or not choice or err or not choice.confirm or not current_origin(fresh, source, origin) then return end
			local current = worker_now(fresh, source, worker.worker_id)
			local live = if current and current.rollover and current.rollover.phase ~= "complete" and current.rollover.phase ~= "cancelled" then current.rollover.id else nil
			if not current or current.worker_generation ~= worker.worker_generation or live ~= (if active then active.id else nil) then
				notice(fresh, source, origin.alias_nonce, "Worker or rollover changed during confirmation; nothing was requested.")
				return
			end
			local id = send_command(fresh, source, origin, request.command, if cancel then { worker_id = worker.worker_id } else { worker_id = worker.worker_id, trigger = "owner" }, true)
			if id then start_driver(source, origin, id, worker.worker_id) end
		end)
		return
	elseif request.command == "adopt" then
		local records = if type(request.records) == "table" then request.records else {}
		local candidate = adoption_candidate(cx, source, request.pane, origin)
		if not candidate or #records == 0 then
			notice(cx, source, origin.alias_nonce, "Attach needs an idle native agent pane in this exact window, session and host that no worker binds, plus an eligible native SPAWN record. Nothing was attached.")
			return
		end
		local items = { { label = "Cancel — do not attach" } }
		for _, record in records do
			if type(record) == "table" and type(record.record_id) == "string" and type(record.label) == "string" then
				table.insert(items, { label = "Runs under " .. record.label, detail = "SPAWN record " .. record.record_id .. " / revision " .. tostring(record.record_revision), record = record })
			end
		end
		cx:pick({ placeholder = "Attach pane " .. candidate.pane_id .. ": choose the SPAWN record whose account/profile this agent already runs under", items = items }):next(function(choice: any, err: string?, fresh: WindowCx?)
			if not fresh or not choice or err or not choice.record or not current_origin(fresh, source, origin) then return end
			fresh:prompt({ placeholder = "Explicit assignment for the attached agent in pane " .. candidate.pane_id, action = "continue" }):next(function(task: string?, task_error: string?, next_cx: WindowCx?)
				if not next_cx or not task or task_error or not current_origin(next_cx, source, origin) then return end
				next_cx:pick({ placeholder = "Attest pane " .. candidate.pane_id .. " (window " .. candidate.window_epoch .. ", session " .. candidate.native_session_id
					.. ", host " .. candidate.window_host_id .. ") is the exact agent to enroll as an ORCH+ worker?", items = {
					{ label = "Cancel — do not attach", attach = false },
					{ label = "I verified this exact agent pane runs under " .. choice.record.label, attach = true,
						detail = "SPAWN delivers the transport preface and assignment once by native ask. A busy, non-agent, out-of-session or already-bound pane is refused; an uncertain delivery is never repeated." },
				} }):next(function(confirmation: any, confirmation_error: string?, last_cx: WindowCx?)
					if not last_cx or not confirmation or confirmation_error or not confirmation.attach or not current_origin(last_cx, source, origin) then return end
					local verified = adoption_candidate(last_cx, source, request.pane, origin)
					if not verified or not same_origin(verified, candidate) then
						notice(last_cx, source, origin.alias_nonce, "The pane changed, became busy or was bound during confirmation; nothing was attached.")
						return
					end
					local id = send_command(last_cx, source, origin, "adopt", { record_id = choice.record.record_id, record_revision = choice.record.record_revision,
						catalog_revision = choice.record.catalog_revision, prompt = task, pane_binding = verified, attestation = "operator_verified_exact_agent_pane" }, true)
					if id then start_driver(source, origin, id) end
				end)
			end)
		end)
		return
	elseif request.command == "recheck_report" then
		local worker = if type(request.worker_id) == "string" then worker_now(cx, source, request.worker_id) else nil
		if not worker or not worker.report_held or worker.continuation_required then
			notice(cx, source, origin.alias_nonce, "Re-check needs a held report on an explicitly continued worker. Continue after reload first if required.")
			return
		end
		cx:pick({ placeholder = "Re-check the held report of " .. worker.worker_id .. "? The same retained bytes are decoded again with current validation; nothing is skipped or replaced.", items = {
			{ label = "Keep it held", confirm = false },
			{ label = "Re-check held report", detail = worker.worker_id .. " / generation " .. tostring(worker.worker_generation), confirm = true },
		} }):next(function(choice: any, err: string?, fresh: WindowCx?)
			if not fresh or not choice or err or not choice.confirm or not current_origin(fresh, source, origin) then return end
			local current = worker_now(fresh, source, worker.worker_id)
			if not current or not current.report_held or current.worker_generation ~= worker.worker_generation then
				notice(fresh, source, origin.alias_nonce, "The held report changed during confirmation; nothing was re-checked.")
				return
			end
			local id = send_command(fresh, source, origin, "recheck_report", { worker_id = worker.worker_id }, true)
			if id then start_driver(source, origin, id, worker.worker_id) end
		end)
		return
	elseif request.command == "reconcile_restored" then
		local worker = if type(request.worker_id) == "string" then worker_now(cx, source, request.worker_id) else nil
		if not worker or not worker.restored or worker.restored.reconciled then notice(cx, source, origin.alias_nonce, "No unreconciled restored coordinator pane is recorded for this worker."); return end
		cx:pick({ placeholder = "Confirm you independently stopped the restored retired coordinator pane " .. worker.worker_id .. "? This records operator attestation only; nothing is stopped or restarted.", items = {
			{ label = "Keep coordinator effects held", confirm = false },
			{ label = "I stopped it — record reconciliation", detail = worker.worker_id, confirm = true },
		} }):next(function(choice: any, err: string?, fresh: WindowCx?)
			if not fresh or not choice or err or not choice.confirm or not current_origin(fresh, source, origin) then return end
			local current = worker_now(fresh, source, worker.worker_id)
			if not current or not current.restored or current.restored.reconciled or current.restored.at_ms ~= worker.restored.at_ms then
				notice(fresh, source, origin.alias_nonce, "Restoration evidence changed during confirmation; nothing was recorded.")
				return
			end
			send_command(fresh, source, origin, "reconcile_restored", { worker_id = worker.worker_id, operator_verified = true }, true)
		end)
		return
	elseif request.command == "cancel_landing" or request.command == "move_landing" or request.command == "landing_lost" or request.command == "reconcile_landing" then
		local item = landing_now(cx, source, request)
		if not item then notice(cx, source, origin.alias_nonce, "Landing item changed; reopen its current controls. Nothing was submitted."); return end
		local fields: any = { landing_id = item.id, landing_revision = item.revision }
		local function still(fresh: WindowCx): boolean
			if current_origin(fresh, source, origin) and landing_now(fresh, source, fields) then return true end
			notice(fresh, source, origin.alias_nonce, "Landing item changed during confirmation; nothing was submitted.")
			return false
		end
		if request.command == "move_landing" then
			if (request.direction == "up" and item.move_up) or (request.direction == "down" and item.move_down) then
				fields.direction = request.direction
				send_command(cx, source, origin, "move_landing", fields, true)
			end
		elseif request.command == "cancel_landing" then
			if not item.cancellable then return end
			cx:pick({ placeholder = "Cancel ungranted landing " .. item.id .. "? Its approval gate is withdrawn; landing later needs a new worker request.", items = {
				{ label = "Keep this request", confirm = false }, { label = "Cancel this exact request", confirm = true },
			} }):next(function(choice: any, err: string?, fresh: WindowCx?)
				if not fresh or not choice or err or not choice.confirm or not still(fresh) then return end
				send_command(fresh, source, origin, "cancel_landing", fields, true)
			end)
		elseif request.command == "landing_lost" then
			if not item.markable_lost then return end
			cx:prompt({ placeholder = "Why is the exact result of " .. item.id .. " lost? The slot stays held for reconciliation; nothing is retried.", action = "hold landing slot" }):next(function(reason: string?, err: string?, fresh: WindowCx?)
				if not fresh or not reason or err or reason:find("%S") == nil or not still(fresh) then return end
				fields.reason = reason
				send_command(fresh, source, origin, "landing_lost", fields, true)
			end)
		else
			if not item.reconcilable then return end
			cx:pick({ placeholder = "Reconcile uncertain landing " .. item.id .. " from your read-only inspection of the target. ORCH+ never re-runs the merge.", items = {
				{ label = "Keep the slot held" },
				{ label = "I observed it LANDED", detail = "Enter the resulting target head next; later grants use it.", outcome = "landed" },
				{ label = "I observed it NOT landed", detail = "Releases the slot; the worker must publish a fresh request. Nothing is retried.", outcome = "not_landed" },
			} }):next(function(choice: any, err: string?, fresh: WindowCx?)
				if not fresh or not choice or err or not choice.outcome or not still(fresh) then return end
				fresh:prompt({ placeholder = if choice.outcome == "landed" then "Resulting target head revision (required)" else "Observed current target head revision (optional; leave empty if unknown)",
					action = "record target head" }):next(function(head: string?, head_error: string?, next_cx: WindowCx?)
					if not next_cx or head == nil or head_error or not still(next_cx) then return end
					local observed = head:match("^%s*(.-)%s*$") or ""
					if choice.outcome == "landed" and observed == "" then
						notice(next_cx, source, origin.alias_nonce, "A landed reconciliation needs the resulting target head; nothing was submitted.")
						return
					end
					next_cx:prompt({ placeholder = "Evidence of your read-only inspection (for example the observed log entry)", action = "reconcile landing" }):next(function(reason: string?, reason_error: string?, last_cx: WindowCx?)
						if not last_cx or not reason or reason_error or reason:find("%S") == nil or not still(last_cx) then return end
						fields.outcome = choice.outcome; fields.reason = reason; fields.operator_verified = true
						if observed ~= "" then fields.target_revision = observed end
						send_command(last_cx, source, origin, "reconcile_landing", fields, true)
					end)
				end)
			end)
		end
		return
	elseif request.command == "inspect_worker" or request.command == "open_worker" then
		if request.gate_id and not current_gate(cx, source, request) then notice(cx, source, origin.alias_nonce, "Gate changed; reopen its current controls."); return end
		if type(request.worker_id) == "string" then inspect_worker(cx, source, origin, request.worker_id, request.command == "open_worker") end
		return
	elseif request.command == "answer" or request.command == "cancel_gate" or request.command == "recheck_gate" then
		local gate = current_gate(cx, source, request)
		if not gate then notice(cx, source, origin.alias_nonce, "Gate revision or recipient changed. No answer or control was submitted."); return end
		local fields = { gate_id = gate.id, gate_revision = gate.revision }
		if request.command == "recheck_gate" then
			send_command(cx, source, origin, "recheck_gate", fields, true)
			if gate.kind == "quota_fallback" then
				-- No pane exists yet: recheck means a fresh, validated USAGE snapshot.
				start_reader(source, origin, "snapshot", nil, function() end)
			else
				inspect_worker(cx, source, origin, gate.worker_id, false)
			end
		elseif request.command == "cancel_gate" then
			cx:pick({ placeholder = "Cancel " .. gate.id .. "? Possible delivery cannot be retracted.", items = {
				{ label = "Keep gate", cancel_gate = false }, { label = "Cancel this exact gate revision", cancel_gate = true },
			} }):next(function(choice: any, err: string?, fresh: WindowCx?)
				if not fresh or not choice or err or not choice.cancel_gate or not current_origin(fresh, source, origin) then return end
				if not current_gate(fresh, source, request) then notice(fresh, source, origin.alias_nonce, "Gate changed during confirmation; nothing cancelled."); return end
				send_command(fresh, source, origin, "cancel_gate", fields, true)
			end)
		elseif gate.kind == "native_input" then
			notice(cx, source, origin.alias_nonce, "Native input requires owner action in the exact pane. Open it, then recheck; ORCH+ cannot answer native permission or authentication prompts.")
		elseif gate.phase ~= "pending" then
			notice(cx, source, origin.alias_nonce, "This question is no longer pending; immutable answers are not replaced.")
		else
			local _, bytes = surface_node(cx, source, BLOCK, "orchplus.gate-content", "workflow-gate-content-" .. gate.id, codec.LIMITS.logical)
			local content = if bytes then codec.strict_decode(bytes, codec.LIMITS.logical) else nil
			if not content or content.version ~= 1 or content.id ~= gate.id or content.revision ~= gate.revision
				or content.worker_id ~= gate.worker_id or content.worker_generation ~= gate.worker_generation
				or type(content.question) ~= "string" or type(content.options) ~= "table" or not current_gate(cx, source, request) then
				notice(cx, source, origin.alias_nonce, "The complete current question and choices are unavailable. Reopen this gate; no answer was requested.")
				return
			end
			local items = {}
			for _, option in content.options do table.insert(items, { label = option.label, choice_id = option.id }) end
			cx:pick({ placeholder = content.question, items = items }):next(function(choice: any, err: string?, fresh: WindowCx?)
				if not fresh or not choice or err or not current_origin(fresh, source, origin) then return end
				if not current_gate(fresh, source, request) then notice(fresh, source, origin.alias_nonce, "Question changed during selection; no answer sent."); return end
				if gate.kind == "quota_fallback" then
					-- Host-consumed routing decision: the chosen option is the whole answer.
					send_command(fresh, source, origin, "answer", { gate_id = gate.id, gate_revision = gate.revision, choice_id = choice.choice_id, answer = choice.label }, true)
					return
				end
				fresh:prompt({ placeholder = "Explicit owner answer for " .. gate.id .. " / " .. choice.label, action = "send immutable answer" }):next(function(answer: string?, answer_error: string?, next_cx: WindowCx?)
					if not next_cx or not answer or answer_error or not current_origin(next_cx, source, origin) then return end
					if not current_gate(next_cx, source, request) then notice(next_cx, source, origin.alias_nonce, "Question changed before submission; no answer sent."); return end
					send_command(next_cx, source, origin, "answer", { gate_id = gate.id, gate_revision = gate.revision, choice_id = choice.choice_id, answer = answer }, true)
				end)
			end)
		end
		return
	end
	if request.command == "queue" then
		cx:prompt({ placeholder = "Explicit assignment for " .. tostring(request.record_id), action = "queue task" }):next(function(task: string?, err: string?, fresh: WindowCx?)
			if not fresh or not task or err or not current_origin(fresh, source, origin) then return end
			local fields = { record_id = request.record_id, record_revision = request.record_revision, catalog_revision = request.catalog_revision,
				coordinator = request.coordinator, prompt = task, cwd = request.cwd, placement = request.placement }
			local flow = workflow_node(fresh, source, "workflow-index", "orchplus.workflow")
			if flow and flow.policy and flow.policy.quota_routing then
				-- Decide on freshly validated USAGE evidence; if it cannot be read the work is held, visibly.
				start_reader(source, origin, "snapshot", nil, function(next_cx: WindowCx)
					if not current_origin(next_cx, source, origin) then return end
					local id = send_command(next_cx, source, origin, "queue", fields, true)
					if id then start_driver(source, origin, id) end
				end)
				return
			end
			local id = send_command(fresh, source, origin, "queue", fields, true)
			if id then start_driver(source, origin, id) end
		end)
	elseif request.command == "capacity_refresh" then
		start_reader(source, origin, "snapshot", nil, function(next_cx: WindowCx, ok: boolean)
			if ok then next_cx:toast("info", "ORCH+ quota evidence", "USAGE capacity evidence refreshed and validated.") end
		end)
	elseif request.command == "cancel_work" then
		local worker = if type(request.worker_id) == "string" then worker_now(cx, source, request.worker_id) else nil
		if not worker then notice(cx, source, origin.alias_nonce, "Queued work changed; nothing was cancelled."); return end
		-- Fenced never-launched work: its provision, launch or adoption request was fenced unexecuted at
		-- continuation. When SPAWN received it, its retained SPAWN status is read and sent with the command.
		local fenced = if type(worker.withdrawal) == "table" then worker.withdrawal else nil
		if fenced and fenced.mailbox_retire == "retiring" then
			notice(cx, source, origin.alias_nonce, "This work's unused mailbox is already being retired; inspect that retirement's outcome. Nothing else was started.")
			return
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
		cx:pick({ placeholder = placeholder, items = {
			{ label = if fenced then "Keep it" else "Keep it held", confirm = false },
			{ label = if fenced then "Cancel this never-launched work" else "Cancel this queued work", detail = worker.worker_id, confirm = true },
		} }):next(function(choice: any, err: string?, fresh: WindowCx?)
			if not fresh or not choice or err or not choice.confirm or not current_origin(fresh, source, origin) then return end
			if fenced and fenced.status_required then
				if withdrawals[source] then notice(fresh, source, origin.alias_nonce, "Another cancellation is still reading SPAWN status; nothing else was started."); return end
				withdrawals[source] = { origin = origin, worker_id = worker.worker_id, fenced = fenced, started = awake_now() }
				arm()
				return
			end
			local id = send_command(fresh, source, origin, "cancel_work", { worker_id = worker.worker_id }, true)
			if id and retires then start_driver(source, origin, id, worker.worker_id) end
		end)
	elseif request.command == "catalog" or request.command == "poll" or request.command == "reply" or request.command == "retire" then
		local id = send_command(cx, source, origin, request.command, { bytes = request.bytes, worker_id = request.worker_id }, true)
		if id then start_driver(source, origin, id, request.worker_id) end
	elseif request.command == "retry" then
		if type(request.action_id) ~= "string" then return end
		held_actions[request.action_id] = nil; capacity_waits[request.action_id] = nil; recheck_waits[request.action_id] = nil
		local id = send_command(cx, source, origin, "retry", { action_id = request.action_id }, true)
		if id then start_driver(source, origin, id) end
	elseif request.command == "readback_publication" then
		if type(request.action_id) ~= "string" then return end
		held_actions[request.action_id] = nil
		send_command(cx, source, origin, "readback_publication", { action_id = request.action_id }, true)
	elseif request.command == "reconcile" or request.command == "execute" then
		if type(request.action_id) ~= "string" then return end
		-- Reconciliation only reads status. Ready execution still requires a fresh durable claim.
		local _, node = snapshot(cx, source)
		cx.session:event(source, { ev = "action", id = node.id, act = "dispatch-select", value = tern.json.encode({ source_nonce = origin.alias_nonce, action_id = request.action_id }) })
		local driver = drivers[source]
		if driver and (driver.delivery or driver.action_id) then
			notice(cx, source, origin.alias_nonce, "A captured delivery or live grant is still settling. Its driver is retained; inspect the selected action after settlement.")
			return
		end
		for _, active in drivers do
			if active.source == source and active.scope == request.action_id then
				notice(cx, source, origin.alias_nonce, if active.auto then "An automatic read-only reconciliation of this exact action is already reading its retained SPAWN outcome. No second driver or grant was created."
					else "This exact action already has its retained executor. No second driver or grant was created.")
				return
			end
		end
		held_actions[request.action_id] = nil; capacity_waits[request.action_id] = nil
		-- An unstarted automatic read of another action yields; the owner's driver never inherits it.
		drivers[source] = if driver and not driver.auto then driver else { source = source, origin = origin }
		drivers[source].scope = request.action_id
		drivers[source].reconcile_action_id = if request.command == "reconcile" then request.action_id else nil
		arm()
	end
end
guide_control = dispatch_control
-- Operator intents: a clicked window-side control (see views.luau `dispatch_link`/`assistance`)
-- is published by its controller block as `main.operator-intent`. Each scanned controller's
-- intent runs at most once per (source_nonce, serial) in this VM, then is settled host-side.
-- Only the window that currently owns the controller's origin acts; every other window leaves it
-- silently. That includes continuation and the recovery guide: a host-block click names no window,
-- and every client attached to one window key shares its key, shown session and focus, so a fresh
-- incarnation continues only through the palette commands below, which run where they are invoked.
-- Assistance follows the same rule while a live origin exists: the host stamps that origin's window
-- into the intent (`window`); unstamped (no command cursor yet, or a controller restored uncertain),
-- any window showing the controller may assist.
local INTENT_KINDS = { dispatch = true, assist = true }
local ASSIST_KINDS = { inspect = true, recheck = true, reveal = true, stop = true }
local INTENTS_SEEN_LIMIT = 256
local intents_seen: any, intents_order: any = {}, {}
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
	if intents_seen[id] then return end
	intents_seen[id] = true; table.insert(intents_order, id)
	if #intents_order > INTENTS_SEEN_LIMIT then intents_seen[table.remove(intents_order, 1)] = nil end
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
	return { executed = size(executed), auto_reconcile = size(auto_reconcile), auto_readback = size(auto_readback), held_actions = size(held_actions),
		sweep_attempts = size(sweep_attempts), scan_workers = per_worker, watched = #settle_order }
end
return { native_observation = native_observation, schedule = schedule, intents = consume_intents, bookkeeping = bookkeeping }
