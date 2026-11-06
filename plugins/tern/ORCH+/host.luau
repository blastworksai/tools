--!strict
local state = require("./state")
local views = require("./views")
local dispatch = require("./dispatch")
local codec = require("./transport")
local STORE_KEY = "authority_state"
local MAX_AUTHORITY_BYTES = 8 * 1024 * 1024
local CONTROL_RESERVE_BYTES = 512 * 1024
local SETTLEMENT = { bind_coordinator = true, request_retirement = true, begin_recovery = true, confirm_recovery = true, release_controller = true, release_coordinator = true, dispatch_reconcile = true }
local OBSERVATION = { observe_owner = true, mark_uncertain = true }
local function settlement(event: any): boolean
	return SETTLEMENT[event.kind] == true or (event.kind == "dispatch" and event.command ~= "queue" and event.command ~= "catalog" and event.command ~= "reply" and event.command ~= "capacity")
end
local UNSAVED_OBSERVATION = "A fresh safety observation could not be persisted. Release and recovery are blocked in this runtime; repair storage/capacity and restart for fresh inspection."
local boot = string.format("host-%d-%08x-%08x", os.time(), math.random(1, 2147483647), math.random(1, 2147483647))
local function host_clock(): any
	return { now_ms = math.floor(os.time() * 1000), mono_ms = tern.now(), epoch = boot }
end
-- Operator intents (window-side controls) are bounded and one-shot: the consuming window settles
-- one; an intent no window took within INTENT_TTL_MS expires visibly, never later.
local INTENT_LIMIT = 65536
local INTENT_TTL_MS = 30000

-- Detect removed, externally changed or corrupt persisted authority before overwriting it.
local function same_value(left: any, right: any, depth: number): boolean
	if type(left) ~= type(right) or depth > 16 then return false end
	if type(left) ~= "table" then return left == right end
	for key, value in left do
		if not same_value(value, right[key], depth + 1) then return false end
	end
	for key in right do if left[key] == nil then return false end end
	return true
end

-- The host VM is the only writer. A candidate never becomes authority until set returns.
local function new_authority(storage: any, clock: any?): any
	-- `persisted`: the exact JSON text of `registry` as last saved, from the capacity encode.
	local authority: any = { registry = nil, status = "unloaded", diagnostic = nil, raw = nil, established = false, uncommitted_observation = false, persisted = nil }
	local function problem(code: string, message: string): any
		authority.diagnostic = message
		return { ok = false, code = code, message = message }
	end
	local function observation_failure(event: any, failure: any): any
		if OBSERVATION[event.kind] or (event.kind == "dispatch" and (event.command == "result" or event.command == "lost" or event.command == "observe")) then
			authority.uncommitted_observation = true
			authority.diagnostic = UNSAVED_OBSERVATION
			failure.message = tostring(failure.message or failure.code) .. " " .. UNSAVED_OBSERVATION
		end
		return failure
	end
	local function capacity(candidate: any, ordinary: boolean): (any?, boolean, string?)
		local ok, encoded = pcall(tern.json.encode, candidate)
		if not ok then return problem("serialization_failed", "Authority could not be encoded; no ownership change was published."), false, nil end
		local limit = MAX_AUTHORITY_BYTES - (if ordinary then CONTROL_RESERVE_BYTES else 0)
		if #encoded > limit then
			return problem("capacity_reached", "Authority storage capacity reached. Ordinary operations cannot consume the retirement/recovery reserve; unresolved ownership is retained."), false, nil
		end
		return nil, #encoded > MAX_AUTHORITY_BYTES - CONTROL_RESERVE_BYTES, encoded
	end
	local function remember(registry: any, text: string?)
		authority.persisted = if text ~= nil then { registry = registry, text = text } else nil
	end
	-- Equal JSON text proves the stored value is the saved registry (both round-trip through
	-- kv JSON). Differing text (key order, an external write) falls back to the deep compare.
	local function stored_text_matches(raw: any): boolean
		local saved = authority.persisted
		if saved == nil or saved.registry ~= authority.registry then return false end
		local ok, text = pcall(tern.json.encode, raw)
		if not ok then return false end
		if text == saved.text then return true end
		if saved.decoded_text == nil then
			-- kv.get returns decoded JSON; compare against the saved text in that same decoded form.
			local decoded, value = pcall(tern.json.decode, saved.text)
			local encoded, again = false, nil
			if decoded then encoded, again = pcall(tern.json.encode, value) end
			saved.decoded_text = if encoded then again else false
		end
		return text == saved.decoded_text
	end
	function authority:load(): any
		local ok, raw = pcall(storage.get, STORE_KEY)
		if not ok then
			self.status = "unreadable"
			return problem("store_unreadable", "Authority store could not be read. Restore or repair its backup; no authority was replaced.")
		end
		self.raw = raw
		if raw == nil then
			self.status = if self.established then "missing_established" else "missing"
			return problem("store_missing", "No authority store found. If this installation had owners, restore its backup; do not initialize a replacement.")
		end
		local candidate, diagnostic = state.rehydrate(raw)
		if candidate == nil then
			self.status = "quarantined"
			return problem(if type(diagnostic) == "table" then diagnostic.code else "invalid_store", "Stored authority is quarantined; restore a valid schema-2 backup. Legacy data needs a later explicit migration.")
		end
		local full, _, encoded = capacity(candidate, false)
		if full ~= nil then
			self.status = "quarantined"
			return full
		end
		local saved = pcall(storage.set, STORE_KEY, candidate)
		if not saved then
			self.status = "restore_save_failed"
			return problem("persistence_failed", "Restored ownership could not be persisted. No restored grant is exposed; retry the store read after repairing storage.")
		end
		self.registry = candidate
		remember(candidate, encoded)
		self.established = true
		self.status = "ready"
		self.diagnostic = if self.uncommitted_observation then UNSAVED_OBSERVATION else nil
		return { ok = true, code = "restored", revision = candidate.revision }
	end
	function authority:initialize(verified_first_use: boolean): any
		if self.status ~= "missing" or self.established or verified_first_use ~= true then
			return problem("initialization_refused", "Initialization is only for explicitly verified first use, never lost or quarantined ownership.")
		end
		local ok, raw = pcall(storage.get, STORE_KEY)
		if not ok or raw ~= nil then
			self.status = "store_changed"
			return problem("store_changed", "The store changed or became unreadable. Recheck it before proceeding.")
		end
		local candidate = state.new_registry()
		local full, _, encoded = capacity(candidate, true)
		if full ~= nil then return full end
		if not pcall(storage.set, STORE_KEY, candidate) then
			return problem("persistence_failed", "Initialization was not saved. No controller ownership was granted.")
		end
		self.registry = candidate
		remember(candidate, encoded)
		self.established = true
		self.status = "ready"
		self.diagnostic = nil
		return { ok = true, code = "initialized", revision = candidate.revision }
	end
	function authority:apply(event: any): any
		if self.status ~= "ready" or self.registry == nil then
			return problem("authority_unavailable", "Repair or restore the authority store before changing ownership.")
		end
		-- The external-change check guards the write below. Refusals, exact replays and no-op
		-- answers never write, so they skip it. An unchanged store is matched natively against
		-- the saved JSON text; only a text mismatch pays the O(registry) Lua deep compare.
		local function store_unchanged(): any?
			local ok, raw = pcall(storage.get, STORE_KEY)
			if ok and raw ~= nil and (stored_text_matches(raw) or same_value(raw, self.registry, 0)) then return nil end
			self.status = "store_changed"
			return problem("store_changed", "Authority storage disappeared or changed. Ownership remains occupied; restore/recheck before continuing.")
		end
		local now = (clock or host_clock)()
		local candidate, response = state.apply(self.registry, event, now)
		if candidate == nil then
			if response.code == "capacity_reached" then return observation_failure(event, response) end
			return response
		end
		if candidate == self.registry then return response end
		if self.uncommitted_observation and (SETTLEMENT[event.kind] or event.kind == "dispatch") then
			return problem("uncommitted_observation", UNSAVED_OBSERVATION)
		end
		local full, uses_reserve, encoded = capacity(candidate, not settlement(event) and event.kind ~= "observe_owner")
		if full ~= nil then return observation_failure(event, full) end
		if uses_reserve then
			-- Byte capacity can hit reserve before the outcome count does. Reuse the
			-- reducer's exact no-progress/serialization policy; no first candidate escaped.
			local reserved = table.clone(now); reserved.reserved_capacity = true
			candidate, response = state.apply(self.registry, event, reserved)
			if candidate == nil then
				if response.code == "capacity_reached" then return observation_failure(event, response) end
				return response
			end
			local ok, text = pcall(tern.json.encode, candidate)
			encoded = if ok then text else nil
		end
		local changed = store_unchanged()
		if changed ~= nil then return changed end
		if not pcall(storage.set, STORE_KEY, candidate) then
			return observation_failure(event, problem("persistence_failed", "Ownership change was not saved. The previous owner and recovery intent remain authoritative."))
		end
		self.registry = candidate
		remember(candidate, encoded)
		self.diagnostic = if self.uncommitted_observation then UNSAVED_OBSERVATION else nil
		return response
	end
	return authority
end

local authority = new_authority(tern.kv)
local contexts: { [number]: any } = {}
local serial = 0
local function nonce(): string
	serial += 1
	return boot .. "-" .. tostring(serial)
end
-- While an event is being handled, nested render requests are ignored; `event` below then
-- renders every block only when committed authority changed, else just the originating block
-- when its own view-visible state changed (window drivers read its result/receipt surfaces).
local handling_event = false
local function render_all()
	if handling_event then return end
	for _, entry in contexts do entry.cx:render() end
end
local function authority_signature(): string
	return tostring(authority.status) .. "\0" .. tostring(authority.diagnostic) .. "\0" .. tostring(authority.uncommitted_observation)
end
local function view_signature(view: any): string?
	-- `actions`/`action_serial` are rebuilt by every render, so they never request one.
	local visible = table.clone(view); visible.actions = nil; visible.action_serial = nil
	local ok, encoded = pcall(tern.json.encode, visible)
	return if ok then encoded else nil
end
local function decode(value: any): any?
	if type(value) ~= "string" or #value > 8192 then return nil end
	local result = codec.strict_decode(value, 8192)
	return if type(result) == "table" then result else nil
end
local function session_for(view: any): any?
	return if authority.registry ~= nil and view.orch_session_id ~= nil then authority.registry.sessions[view.orch_session_id] else nil
end
-- The window an assist intent must run in: the continued origin's window, named by the session's command
-- cursor while it belongs to the active controller owner/generation. With no cursor yet, or a controller
-- restored uncertain (no live origin to prefer), nil keeps assistance open to any window showing it.
local function assist_window(view: any): any?
	local session = session_for(view)
	local owner = if session then session.controller else nil
	if not owner or owner.phase ~= "active" or not authority.registry.dispatch then return nil end
	local cursor = (authority.registry.dispatch.command_cursors or {})[view.orch_session_id]
	local origin = if type(cursor) == "table" then cursor.origin else nil
	if type(origin) ~= "table" or origin.owner_id ~= owner.owner_id or origin.owner_generation ~= owner.generation then return nil end
	return { window_key = origin.window_key, window_epoch = origin.window_epoch, native_session_id = origin.native_session_id, window_host_id = origin.window_host_id }
end
local function binding(view: any): any
	return { host_pane_id = tostring(view.pane), alias_nonce = view.alias_nonce }
end
-- Plain reasons for refusals whose reducer text is not owner-facing.
local REFUSAL_TEXT = { policy_too_large = "Settings too large — shorten templates or guidance." }
local function action(view: any, event: any, defer_render: boolean?): any
	event.request_id = event.request_id or nonce()
	local response = table.clone(authority:apply(event))
	if response.ok == false and REFUSAL_TEXT[response.code] then response.message = REFUSAL_TEXT[response.code] end
	response.request_id = event.request_id
	view.notice = tostring(response.message or response.code)
	if not defer_render then render_all() end
	return response
end
local function owner_event(view: any, entry: any, kind: string): any
	return {
		kind = kind, orch_session_id = view.orch_session_id, target = entry.target,
		expected_owner_id = entry.owner_id, expected_generation = entry.generation,
	}
end
local function capture_dispatch(view: any, response: any, receipt: any?)
	if type(response.action_id) ~= "string" or not authority.registry or not authority.registry.dispatch
		or not authority.registry.dispatch.actions[response.action_id] then return end
	view.scoped_results = view.scoped_results or {}
	local retained = view.scoped_results[response.action_id] or {}
	retained.result = response
	if receipt then retained.receipt = receipt end
	local a = authority.registry.dispatch.actions[response.action_id]
	if response.ok and a.phase == "complete" and retained.receipt then
		-- Another worker may compact a settled read before this window consumes its
		-- commit receipt. Retain only a completed projection, never runnable authority.
		retained.completed = { request = a.request, request_bytes = a.request_bytes, phase = "complete", claim = dispatch.public_claim(a.claim), worker_id = a.worker_id }
	end
	view.scoped_results[response.action_id] = retained
end
-- Config edits are a view-local draft over the saved session policy. The window saves it via the
-- ordinary policy command fenced by expected_policy_sha256 (digest of the displayed saved policy),
-- so a stale draft is refused.
local STEPS = { rollover_threshold_pct = { minimum = 1, maximum = 99 }, poll_ms = { minimum = 1000, maximum = 60000 },
	heartbeat_ms = { minimum = 5000, maximum = 3600000 }, stale_ms = { minimum = 5000, maximum = 86400000 },
	quota_reserve_pct = { minimum = 0, maximum = 99 }, quota_max_age_ms = { minimum = 60000, maximum = 900000 },
	concurrency_limit = { minimum = 0, maximum = 32 }, loop_cap = { minimum = 1, maximum = 10 },
	review_rounds = { minimum = 1, maximum = 2 }, stale_claim_min = { minimum = 0, maximum = 1440 } }
local SWITCHES = { automatic_reports = true, auto_rollover = true, rollover_include_coordinator = true, quota_routing = true,
	initial_dispatch_provider = true, initial_dispatch_account = true, initial_dispatch_model = true, sweep_enabled = true,
	worker_rollover_provider = true, worker_rollover_account = true, worker_rollover_model = true,
	coordinator_rollover_provider = true, coordinator_rollover_account = true, coordinator_rollover_model = true,
	enforce_cross_family = true, glitch_integration = true, auto_launch_intake = true }
-- Draft-edited choice sets: `approve:<kind>` toggles auto_approve_kinds (stored in this canonical
-- order); `work_source:<value>` is a radio.
local APPROVE_ORDER = { "dispatch", "report", "review", "landing" }
local APPROVE_KINDS = { dispatch = true, report = true, review = true, landing = true }
local WORK_SOURCES = { glitch_plan = true, board = true }
-- Config list pages (views paginate lists over 8 rows).
local CONFIG_PAGES = { family_map = true, reviewer_records = true, checkout_roots = true, routes = true, templates = true }
-- Checkbox prefixes for each routing scope's explicit record allowlist.
local ROUTE_PREFIXES = { route = "initial_dispatch_records", wroute = "worker_rollover_records", croute = "coordinator_rollover_records" }
local PANE_STATES = { idle = true, working = true, waiting_input = true, exited = true, unknown = true }
local function controls_config(view: any): boolean
	local session = session_for(view)
	local owner = if session then session.controller else nil
	return view.config_open == true and owner ~= nil and owner.phase == "active" and owner.pane_binding ~= nil
		and owner.pane_binding.host_pane_id == tostring(view.pane) and owner.pane_binding.alias_nonce == view.alias_nonce
end
local function config_draft(view: any): any?
	if not controls_config(view) then
		view.notice = "Config is read-only here: only this session's admitted active controller can change settings."
		return nil
	end
	local saved = dispatch.policy(authority.registry, view.orch_session_id)
	local draft = view.policy_draft
	if draft and (draft.session ~= view.orch_session_id or not same_value(draft.base, saved, 0)) then
		view.policy_draft = nil
		view.notice = "Saved Config changed; unsaved edits were discarded. Review the current values and repeat your change."
		return nil
	end
	if not draft then
		local values = dispatch.policy(authority.registry, view.orch_session_id); values.paused = nil
		draft = { session = view.orch_session_id, base = saved, values = values }
		view.policy_draft = draft
	end
	return draft
end
local function config_change(view: any, name: string, checked: boolean)
	local pane_key = name:match("^pane:(.+)$")
	if pane_key then
		-- Hand-opened panes: window-scoped eligibility marks only. Never adoption, never durable.
		if not controls_config(view) then view.notice = "Config is read-only here: only this session's admitted active controller can change settings."; return end
		for _, row in (if view.session_panes then view.session_panes.panes else {}) do
			if row.key == pane_key and row.worker_id == nil then
				view.pane_exclusions = view.pane_exclusions or {}
				view.pane_exclusions[pane_key] = if checked then nil else true
			end
		end
		return
	end
	local worker_id = name:match("^worker:(.+)$")
	local approve_kind = name:match("^approve:(.+)$")
	if approve_kind and not APPROVE_KINDS[approve_kind] then approve_kind = nil end
	local work_source = name:match("^work_source:(.+)$")
	if work_source and not WORK_SOURCES[work_source] then work_source = nil end
	local prefix, record_id = name:match("^(%a+):(.+)$")
	local route_list = if prefix then ROUTE_PREFIXES[prefix] else nil
	if not route_list then record_id = nil end
	if not SWITCHES[name] and not worker_id and not record_id and not approve_kind and not work_source then return end
	-- A radio choice is set by checking it; unchecking the current choice changes nothing.
	if work_source and not checked then return end
	local draft = config_draft(view)
	if not draft then return end
	if worker_id then
		local w = if authority.registry.dispatch then authority.registry.dispatch.workers[worker_id] else nil
		if not w or w.logical_session_id ~= view.orch_session_id then return end
		local list = draft.values.excluded_workers
		local index = table.find(list, worker_id)
		if checked and index then table.remove(list, index)
		elseif not checked and not index then table.insert(list, worker_id); table.sort(list) end
	elseif record_id then
		-- Explicit routing alternatives: only records shown from the current catalog page.
		local catalog = if authority.registry.dispatch then authority.registry.dispatch.catalogs[view.orch_session_id] else nil
		local listed = false
		for _, record in (if catalog then catalog.records else {}) do if record.id == record_id then listed = true end end
		local list = draft.values[route_list]
		local index = table.find(list, record_id)
		if checked and not index and listed then table.insert(list, record_id); table.sort(list)
		elseif not checked and index then table.remove(list, index) end
	elseif approve_kind then
		local selected = {}
		for _, kind in draft.values.auto_approve_kinds do selected[kind] = true end
		selected[approve_kind] = checked or nil
		local list = {}
		for _, kind in APPROVE_ORDER do if selected[kind] then table.insert(list, kind) end end
		draft.values.auto_approve_kinds = list
	elseif work_source then
		draft.values.default_work_source = work_source
	else
		draft.values[name] = checked
	end
end
local function bounded_text(value: any, maximum: number, empty: boolean?): boolean
	return type(value) == "string" and (empty or #value > 0) and #value <= maximum and utf8.len(value) ~= nil
end
local function session_panes(input: any): any?
	-- Window-side observation pushed for display only: bounded current-session agent panes, never identity.
	if type(input) ~= "table" or input.version ~= 1 or not bounded_text(input.native_session_id, 256) or not bounded_text(input.window_host_id, 256)
		or not bounded_text(input.window_epoch, 256) or type(input.panes) ~= "table" or #input.panes > 64
		or type(input.more) ~= "number" or input.more < 0 or input.more % 1 ~= 0 then return nil end
	for key in input do
		if not table.find({ "version", "source_nonce", "native_session_id", "window_host_id", "window_epoch", "panes", "more" }, key) then return nil end
	end
	for _, row in input.panes do
		if type(row) ~= "table" or type(row.pane) ~= "number" or row.pane < 0 or row.pane % 1 ~= 0 or not bounded_text(row.title, 64, true)
			or not PANE_STATES[row.state] or (row.worker_id ~= nil and not (bounded_text(row.worker_id, 96) and row.worker_id:match("^[A-Za-z0-9_-]+$"))) then return nil end
		for key in row do if not table.find({ "pane", "title", "state", "worker_id" }, key) then return nil end end
		row.key = string.format("%d@%s@%s@%s", row.pane, input.window_epoch, input.native_session_id, input.window_host_id)
	end
	return input
end
local function handle(view: any, ev: any, cx: any)
	if ev.ev == "change" then
		if type(ev.name) == "string" and #ev.name <= 512 and type(ev.checked) == "boolean" then
			config_change(view, ev.name, ev.checked)
			render_all()
		end
		return
	end
	if ev.ev ~= "action" then return end
	if ev.act == "config-open-request" then
		-- Files-pane entry: display mode only; edits still require the admitted controller.
		view.config_open = true
		render_all()
		return
	elseif ev.act == "config-panes" then
		local input = decode(ev.value)
		local observed = if input and input.source_nonce == view.alias_nonce then session_panes(input) else nil
		if observed then
			view.session_panes = observed
			local listed = {}
			for _, row in observed.panes do listed[row.key] = true end
			for key in view.pane_exclusions or {} do if not listed[key] then view.pane_exclusions[key] = nil end end
			render_all()
		end
		return
	end
	if ev.act == "dispatch-release-scope" then
		local input = decode(ev.value)
		local retained = if input and view.scoped_results then view.scoped_results[input.action_id] else nil
		local receipt = if retained then retained.receipt else nil
		if input and input.source_nonce == view.alias_nonce and receipt and receipt.grant_id == input.grant_id
			and receipt.response_sha256 == input.response_sha256 then
			view.scoped_results[input.action_id] = nil
			render_all()
		end
		return
	end
	if ev.act == "dispatch-select" then
		local input = decode(ev.value)
		local retained = if input and authority.registry and authority.registry.dispatch then authority.registry.dispatch.actions[input.action_id] else nil
		if retained and input.source_nonce == view.alias_nonce and retained.request.origin_binding.alias_nonce == view.alias_nonce
			and retained.request.origin_binding.host_pane_id == tostring(view.pane) then
			view.dispatch_action = input.action_id; view.dispatch_result = nil
			view.dispatch_command_result = nil -- Explicit operator selection supersedes the previous command.
			if view.scoped_results and view.scoped_results[input.action_id] then view.scoped_results[input.action_id].result = nil end
			render_all()
		end
		return
	end
	if ev.act == "dispatch-command" or ev.act == "dispatch-operator-command" then
		local input = decode(ev.value)
		if input == nil or input.kind ~= "dispatch" or input.command == "intake" or not dispatch.origin(input.origin)
			or input.origin.host_pane_id ~= tostring(view.pane) or input.origin.alias_nonce ~= view.alias_nonce
			or input.orch_session_id ~= view.orch_session_id then return end
		local operator = ev.act == "dispatch-operator-command"
		if operator and not table.find({ "catalog", "queue", "poll", "reply", "retry", "retire", "finish", "rollover", "cancel_rollover", "reconcile_restored", "continue_controller", "continue_worker", "policy", "pause", "resume", "answer", "cancel_gate", "recheck_gate",
			"cancel_landing", "move_landing", "landing_lost", "reconcile_landing", "capacity", "cancel_work", "recheck_report", "adopt", "readback_publication" }, input.command) then return end
		-- Adoption of a hand-opened pane is only ever an explicit owner action, never a background command.
		if not operator and input.command == "adopt" then return end
		local notice = view.notice
		local response = action(view, input, true)
		-- A background poll of a provably idle worker commits nothing: keep the view (and its render) unchanged.
		if not operator and response.ok and response.code == "mailbox_idle" and response.action_id == nil then
			view.notice = notice
			return
		end
		response.action_id = response.action_id or input.action_id
		response.grant_id = input.grant_id or (if response.claim then response.claim.grant_id else nil)
		-- cancel_work is not workflow-only: withdrawing a rejected launch queues its mailbox retirement,
		-- which the window drives from this command result like any other queued effect.
		local workflow_only = table.find({ "observe", "policy", "pause", "resume", "answer", "cancel_gate", "recheck_gate", "continue_controller",
			"cancel_landing", "move_landing", "landing_lost", "reconcile_landing", "capacity", "sweep", "plan_import", "board_intake", "inbox_intake", "template_start" }, input.command) ~= nil
		if operator then
			view.dispatch_command_result = response
			response.command = input.command
			if not workflow_only then view.dispatch_driver_result = response end
		end
		if (not operator or response.ok) and not workflow_only then view.dispatch_result = response end
		if response.ok and response.action_id then view.dispatch_action = response.action_id end
		if not workflow_only then capture_dispatch(view, response) end
		render_all()
		return
	elseif type(ev.act) == "string" and ev.act:sub(1, 16) == "dispatch-result/" then
		if type(ev.value) ~= "string" or #ev.value > 8192 or authority.registry == nil then return end
		local prefix = "SPAWN_DISPATCH v1 "
		if ev.value:sub(1, #prefix) ~= prefix then return end
		local frame = codec.strict_decode(ev.value:sub(#prefix + 1), 8192)
		if not frame then return end
		for id, pending in (authority.registry.dispatch or { actions = {} }).actions do
			local request = pending.request
			if request.request_id == frame.request_id and request.origin_binding.host_pane_id == tostring(view.pane)
				and request.origin_binding.alias_nonce == view.alias_nonce and request.origin_binding.logical_session_id == view.orch_session_id
				and pending.claim ~= nil then
				local projected = dispatch.project(authority.registry, view.orch_session_id, view.alias_nonce, id).actions[id]
				local execution_origin = if projected then projected.execution_origin or request.origin_binding else nil
				if not execution_origin or ev.act:sub(17) ~= pending.claim.grant_id .. "/" .. execution_origin.window_epoch then return end
				local grant_id = pending.claim.grant_id
				local response_sha256 = codec.sha256(ev.value)
				local response = action(view, { kind = "dispatch", request_id = "result-" .. codec.sha256(grant_id .. ":" .. execution_origin.window_epoch .. ":" .. response_sha256), command = "result", action_id = id,
					orch_session_id = view.orch_session_id, origin = execution_origin,
					controller_pane = projected.execution_controller_pane or request.controller_pane,
					executor = pending.claim.executor, grant_id = grant_id, response_bytes = ev.value }, true)
				response.action_id = id; response.grant_id = grant_id
				view.dispatch_result = response
				if response.ok then
					view.dispatch_receipt = { action_id = id, grant_id = grant_id, response_sha256 = response_sha256 }
				end
				capture_dispatch(view, response, if response.ok then view.dispatch_receipt else nil)
				render_all()
				return
			end
		end
		return
	elseif ev.act == "recovery-steps" then
		-- Window-computed reload checklist: display only, never authority or attestation.
		local input = decode(ev.value)
		if not input or input.source_nonce ~= view.alias_nonce or type(input.steps) ~= "table" or #input.steps > 24 then return end
		local steps = {}
		for _, step in input.steps do
			if type(step) ~= "table" or not bounded_text(step.label, 256) or (step.detail ~= nil and not bounded_text(step.detail, 512)) then return end
			table.insert(steps, { label = step.label, detail = step.detail })
		end
		view.recovery_steps = { steps = steps }
		render_all()
		return
	elseif ev.act == "dispatch-notice" then
		local input = decode(ev.value)
		if input and input.source_nonce == view.alias_nonce and type(input.message) == "string" and #input.message <= 1024 and view.notice ~= input.message then
			view.notice = input.message
			render_all()
		end
		return
	elseif ev.act == "idle-wake" then
		-- The window's idle-wake helper state (window.luau idle_wake): display only, never authority.
		local input = decode(ev.value)
		if not input or input.source_nonce ~= view.alias_nonce or (input.state ~= "active" and input.state ~= "idle" and input.state ~= "unavailable")
			or (input.detail ~= nil and not bounded_text(input.detail, 256)) then return end
		view.idle_wake = if input.state == "idle" then nil else { state = input.state, detail = input.detail }
		render_all()
		return
	end
	if ev.act == "assistance-result" then
		local input = decode(ev.value)
		if input == nil or input.source_nonce ~= view.alias_nonce or type(input.message) ~= "string" or #input.message > 2048 then return end
		local session = session_for(view)
		local owner = if session ~= nil and (input.target == "controller" or input.target == "orchestrator") then session[input.target] else nil
		if owner == nil or owner.owner_id ~= input.owner_id or owner.generation ~= input.generation
			or authority.registry.revision ~= input.revision then
			view.notice = "Ignored stale assistance result; the owner changed."
			return
		end
		view.notice = input.message
		-- A missing window alias is uncertainty, never proof that an owner stopped.
		if input.observation == "active" or input.observation == "unavailable" then
			local event = owner_event(view, input, "observe_owner")
			event.evidence = "observed"
			if input.observation == "active" then
				event.status = "Same-host window alias observed; " .. string.sub(input.message, 1, 180)
				event.owner_active = true
			else
				event.status = "unavailable"
			end
			event.request_id = nonce()
			local response = authority:apply(event)
			if response.ok then render_all() else view.notice = tostring(response.message or response.code) end
		end
		return
	end
	if ev.act == "operator-intent-done" then
		-- The consuming window settles the one-shot intent; a stale or foreign serial changes nothing.
		local input = decode(ev.value)
		local intent = view.operator_intent
		if input and intent and input.source_nonce == intent.source_nonce and input.serial == intent.serial then
			view.operator_intent = nil; view.operator_intent_at = nil
		end
		return
	end
	local entry = view.actions[ev.value]
	if ev.act ~= "control" then return end
	if entry == nil then
		local session = session_for(view)
		local owner = if session then session.controller else nil
		view.refusal = { ok = false, code = if owner then "controller_slot_occupied" else "stale_action",
			owner_id = if owner then owner.owner_id else nil, generation = if owner then owner.generation else nil,
			orch_session_id = view.orch_session_id, revision = if authority.registry then authority.registry.revision else nil }
		view.notice = if owner then "REFUSED: the displayed action is stale and this controller slot is occupied by " .. owner.owner_id
			.. " / generation " .. tostring(owner.generation) .. " / phase " .. owner.phase .. ". Inspect or reveal the current owner; no action was retried."
			else "REFUSED: this displayed action expired after the view changed. Inspect the current state and choose a current action; nothing was retried."
		render_all()
		return
	end
	view.refusal = nil
	if entry.kind == "operator-intent" or entry.kind == "assist-intent" then
		-- Window-side controls (pickers, prompts, panes) run in the window. Publish the exact stored
		-- request as a bounded one-shot intent; the window re-validates everything before acting.
		local intent = { version = 1, source_nonce = view.alias_nonce, serial = nonce(),
			kind = if entry.kind == "operator-intent" then "dispatch" else "assist", request = entry.request,
			window = if entry.kind == "assist-intent" then assist_window(view) else nil }
		local ok, bytes = pcall(tern.json.encode, intent)
		if not ok or #bytes > INTENT_LIMIT then
			view.notice = "REFUSED: this control's request exceeds the " .. tostring(INTENT_LIMIT) .. "-byte intent bound; nothing ran."
			return
		end
		view.operator_intent = intent; view.operator_intent_at = tern.now()
		return
	end
	if entry.kind == "config-open" or entry.kind == "config-close" then
		-- Viewing Config is display-only; unbound/duplicate views render it read-only with the reason.
		view.config_open = entry.kind == "config-open"
		render_all()
	elseif entry.kind == "config-step" then
		local draft, bounds = config_draft(view), STEPS[entry.field]
		if draft and bounds then
			local minimum = if entry.field == "stale_ms" then math.max(bounds.minimum, draft.values.heartbeat_ms) else bounds.minimum
			draft.values[entry.field] = math.clamp(draft.values[entry.field] + entry.delta, minimum, bounds.maximum)
		end
		render_all()
	elseif entry.kind == "config-page" then
		-- Display paging only; it never touches the draft or authority.
		if CONFIG_PAGES[entry.name] and type(entry.page) == "number" and entry.page >= 0 and entry.page % 1 == 0 then
			view.config_pages = view.config_pages or {}
			view.config_pages[entry.name] = entry.page
		end
		render_all()
	elseif entry.kind == "config-move" then
		-- Reorder an owner-ordered list in the draft; saved through the ordinary Save path.
		local draft = config_draft(view)
		local list = if draft and entry.field == "reviewer_records" then draft.values.reviewer_records else nil
		local index = if list then table.find(list, entry.item) else nil
		if list and index and index > 1 then list[index], list[index - 1] = list[index - 1], list[index] end
		render_all()
	elseif entry.kind == "config-discard" then
		view.policy_draft = nil
		render_all()
	elseif entry.kind == "workflow-select" then
		view.workflow_worker = entry.worker_id
		view.workflow_gates = 0; view.workflow_thread = 0
		render_all()
	elseif entry.kind == "workflow-page" then
		local plan_id = entry.name:match("^plan (.+)$")
		if entry.name == "gates" then view.workflow_gates = entry.page
		elseif plan_id then view.workflow_plans = view.workflow_plans or {}; view.workflow_plans[plan_id] = entry.page
		else view.workflow_thread = entry.page end
		render_all()
	elseif entry.kind == "dispatch-acknowledge" then
		local retained = view.dispatch_command_result
		if retained and retained.request_id == entry.request_id and retained.ok == false then
			retained.acknowledged = true
			render_all()
		end
	elseif entry.kind == "recheck-store" then
		if authority.status ~= "ready" then authority:load() end
		view.notice = authority.diagnostic or "Authority store ready."
		render_all()
	elseif entry.kind == "initialize-arm" then
		view.initialize_armed = true
	elseif entry.kind == "initialize-confirm" then
		if view.initialize_armed then
			local response = authority:initialize(true)
			view.notice = response.message or response.code
			view.initialize_armed = false
			render_all()
		end
	elseif entry.kind == "select" then
		if authority.registry ~= nil and authority.registry.sessions[entry.orch_session_id] ~= nil then
			view.orch_session_id = entry.orch_session_id
			view.recovery = nil
		end
	elseif entry.kind == "register-arm" then
		view.register_armed = true
	elseif entry.kind == "register-confirm" then
		if not view.register_armed then return end
		local response = action(view, { kind = "register_session", name = "Logical session " .. tostring(authority.registry.next_session_id), binding = binding(view) })
		if response.ok then view.orch_session_id = response.orch_session_id end
		view.register_armed = false
	elseif entry.kind == "admit" then
		action(view, { kind = "admit_controller", orch_session_id = view.orch_session_id, pane_binding = binding(view) })
	elseif entry.kind == "executor-arm" then
		view.executor_confirmation = entry
	elseif entry.kind == "executor-confirm" then
		local retained = view.executor_confirmation; view.executor_confirmation = nil
		if retained then
			action(view, { kind = "dispatch_reconcile", orch_session_id = view.orch_session_id, action_id = retained.action_id,
				expected_revision = retained.revision, executor = retained.executor, operator_verified = true,
				reason = "Operator independently verified this exact retained executor and any delayed native launch are stopped or reconciled." })
		end
	elseif entry.kind == "attest" or entry.kind == "attest-executors" then
		view.attestation = entry
	elseif entry.kind == "attest-confirm" or entry.kind == "attest-executors-confirm" then
		local previous = view.attestation
		view.attestation = nil
		if previous == nil or entry.kind ~= previous.kind .. "-confirm"
			or authority.registry == nil or previous.revision ~= authority.registry.revision then
			view.notice = "Attestation expired because ownership changed. Inspect and recheck again."
			return
		end
		local event = owner_event(view, previous, "observe_owner")
		event.status = if previous.kind == "attest-executors" then "Operator independently verified unavailable owner and every retained unconfirmed executor stopped or reconciled"
			else "Operator independently verified unavailable owner stopped; no pending executors"
		event.owner_active = false
		event.pending_executors = 0
		event.evidence = "operator_attested"
		event.operator_verified = true
		if previous.kind == "attest-executors" then event.executors_verified = true end
		action(view, event)
	elseif entry.kind == "begin-recovery" then
		local event = owner_event(view, entry, "begin_recovery")
		event.expected_revision = entry.revision
		local response = action(view, event)
		if response.ok then
			view.recovery = { target = entry.target, owner_id = entry.owner_id, generation = entry.generation, revision = response.revision, intent_id = response.intent_id }
		end
	elseif entry.kind == "confirm-recovery" then
		local recovery = view.recovery
		if recovery == nil then return end
		local event = owner_event(view, recovery, "confirm_recovery")
		event.expected_revision = recovery.revision
		event.intent_id = recovery.intent_id
		event.operator_verified = true
		event.evidence = "operator_attested"
		local response = action(view, event)
		if response.ok then view.recovery = nil end
	end
end

-- Renders follow what an event actually changed: duplicate replays, refusals and no-op
-- answers that leave authority and this view's visible state unchanged render nothing.
local function handle_event(view: any, ev: any, cx: any)
	local registry, global, visible = authority.registry, authority_signature(), view_signature(view)
	handling_event = true
	local ok, failure = pcall(handle, view, ev, cx)
	handling_event = false
	if authority.registry ~= registry or authority_signature() ~= global then
		render_all()
	else
		local after = view_signature(view)
		if visible == nil or after == nil or after ~= visible then cx:render() end
	end
	if not ok then error(failure, 0) end
end

local timer: any = nil
local function arm()
	if timer ~= nil then return end
	timer = tern.timer(1000, function()
		timer = nil
		arm()
		-- Host lifecycle IDs are never translated to window aliases or worker identities.
		local live = {}
		for _, pane in tern.pane.list() do live[pane.pane] = true end
		for pane, entry in contexts do
			if not live[pane] then contexts[pane] = nil
			elseif entry.view.operator_intent ~= nil and tern.now() - (entry.view.operator_intent_at or 0) > INTENT_TTL_MS then
				entry.view.operator_intent = nil; entry.view.operator_intent_at = nil
				entry.view.notice = "A clicked control was not confirmed by a window showing this controller in its admitted session within 30 s; it will not run later. Check the current state, then use a current control. After a reload, run ORCH+ Continue controller in this window from the palette first."
				entry.cx:render()
			end
		end
		if authority.status == "ready" then
			local before = authority.registry
			authority:apply({ kind = "workflow_tick" })
			if authority.registry ~= before then render_all() end
		end
	end)
end

local definition: BlockDef<any> = {
	init = function(cx: BlockCx, args: { string }, saved: any): any
		if authority.status == "unloaded" then authority:load() end
		arm()
		-- The Files-pane button opens new views directly in Config mode.
		local view: any = { pane = cx.pane, alias_nonce = nonce(), actions = {}, action_serial = 0, config_open = type(args) == "table" and args[1] == "config" }
		if type(saved) == "table" then
			if saved.established == true then authority.established = true end
			if authority.status == "missing" and authority.established then authority.status = "missing_established" end
			if saved.pane == cx.pane and type(saved.alias_nonce) == "string" and #saved.alias_nonce <= 128 then view.alias_nonce = saved.alias_nonce end
			if type(saved.orch_session_id) == "string" and #saved.orch_session_id <= 128 then view.orch_session_id = saved.orch_session_id end
		end
		contexts[cx.pane] = { cx = cx, view = view }
		return view
	end,
	title = function(_view: any): string return "ORCH+ · ownership" end,
	view = function(view: any, _cx: BlockCx): BlockView
		local projection = if authority.registry ~= nil then state.project(authority.registry, { orch_session_id = view.orch_session_id }) else nil
		if projection ~= nil and view.orch_session_id ~= nil then
			projection.dispatch = dispatch.project(authority.registry, view.orch_session_id, view.alias_nonce, view.dispatch_action, view.scoped_results)
			for id, retained in view.scoped_results or {} do
				if projection.dispatch.actions[id] == nil and retained.completed
					and retained.completed.request.origin_binding.logical_session_id == view.orch_session_id then
					projection.dispatch.actions[id] = retained.completed
				end
			end
		end
		return { main = views.render(view, projection, authority.status, if authority.uncommitted_observation then UNSAVED_OBSERVATION else authority.diagnostic) }
	end,
	event = handle_event,
	save = function(view: any): any
		return { pane = view.pane, alias_nonce = view.alias_nonce, orch_session_id = view.orch_session_id, established = authority.established }
	end,
}
tern.block.define("orchestrator", definition)
tern.on("pane_exited", function(ev: any, _cx: EffectCx) contexts[ev.pane] = nil end)
arm() -- Module reload does not emit window_start; rearm independently of any view.
return { new_authority = new_authority }
