--!strict
local ui = tern.ui
local quota = require("./quota")
local provider_display = require("./provider_display")
local M = {}
local STATUS_MESSAGES = {
	task_queued = "Agent session queued. It has not joined yet.",
	attachment_queued = "Reconnecting your agent…",
	catalog_queued = "Loading available agents…",
	enrolment_queued = "Agent attachment queued. It has not joined yet.",
	task_held = "Work added and held. Choose START when you are ready.",
	task_gated = "Work needs your decision before it can start.",
	project_start_pending = "Waiting for your orchestrator to start the new work.",
	project_start_retry_queued = "Trying to send START again. Your new work is still on hold.",
	project_start_delivery_failed = "Could not send START. Your new work is still on hold.",
	project_start_inspection = "START status checked. Your new work is still on hold.",
	project_start_claimed = "Your orchestrator has started the approved work.",
	pending = "The action is still pending. No second request was sent.",
	effect_uncertain = "The previous action's outcome is not confirmed. Check its status in Advanced; do not start it again.",
	bridge_rejected = "The agent action could not be completed. Check its retained status in Advanced.",
	transport_backpressure = "The agent connection is busy. The existing request remains retained.",
	backpressure = "The agent connection is busy. The existing request remains retained.",
	control_observed = "Status checked.",
	controller_continued = "Orchestration restored.",
	bridge_committed = "Agent information updated.",
	policy_updated = "Settings saved.",
	project_repository_updated = "Project settings saved.",
	plan_imported = "Plan added.",
	catalog_cleared = "Agent list inspection closed.",
	catalog_requested = "Checking available agents.",
	refusal_dismissed = "Refusal dismissed.",
}
local ERROR_RESULTS = { effect_uncertain = true, bridge_rejected = true, transport_backpressure = true,
	backpressure = true, publication_uncertain = true, project_start_delivery_failed = true }
local SAVED_RESULTS = { policy_updated = true, project_repository_updated = true, plan_imported = true,
	controller_continued = true, control_observed = true }
local TASK_STATUS = {
	queued_plan = "Waiting to start",
	source_done = "Completed in source",
	held = "Needs attention",
	running = "In progress",
	done = "Done",
	failed = "Failed",
	cancelled = "Cancelled",
}

-- Rendered text never shows raw JSON null or Lua nil: empty values get readable words.
local function shown(value: any, empty: string): string
	if value == nil or value == tern.json.null then return empty end
	if type(value) == "table" then return if next(value) == nil then empty else tern.json.encode(value) end
	return tostring(value)
end
-- Bounded one-line preview of stored text (UTF-8 safe; stored text is validated UTF-8).
local function preview(text: any, limit: number): string
	if type(text) ~= "string" or text == "" then return "(none)" end
	local cut = utf8.offset(text, limit + 1)
	local line = if cut and cut <= #text then text:sub(1, cut - 1) .. "…" else text
	return (line:gsub("[\r\n\t]+", " "))
end
-- Copies the named fields (space-separated, like dispatch's *_KEYS lists) into `into` or a fresh table.
local function pick(source: any, keys: string, into: any?): any
	local out = into or {}
	for key in keys:gmatch("%S+") do out[key] = source[key] end
	return out
end
-- A keyed contract node: the window locates these by key and role, never by position.
local function keyed(text: string, key: string, role: string): any
	local node = ui.text(text)
	node.p.key = key
	node.p.role = role
	node.p.hidden = true
	return node
end
-- Bound: the recorded controller pane binding is this exact pane and alias. Admitted: bound and active.
local function controller(view: any, selected: any): (any, boolean, boolean)
	local owner = selected.controller
	local bound = owner ~= nil and owner.pane_binding ~= nil
		and owner.pane_binding.host_pane_id == tostring(view.pane) and owner.pane_binding.alias_nonce == view.alias_nonce
	return owner, bound, bound and owner.phase == "active"
end
-- Eligible, enabled records of the loaded catalog page: first occurrence of each ID, in catalog order.
local function enabled_records(catalog: any): { any }
	local list, seen = {}, {}
	for _, record in (if catalog then catalog.records else {}) do
		if record.eligible == true and record.enabled == true and not seen[record.id] then
			seen[record.id] = true
			table.insert(list, record)
		end
	end
	return list
end
-- A worker's shown state: retirement and a verified native stop outrank the last recorded phase.
local function worker_state(worker: any): string
	if worker.mailbox_status == "retired" then return "retired" end
	if worker.stop_status == "absent" or worker.stop_status == "exited" then return "stopped" end
	return tostring(worker.phase)
end
local SWEEP_REASON_TEXT = {
	retired = "mailbox already retired",
	stopped_settled = "provably stopped and settled — the normal mailbox retirement was queued",
	compaction_pending = "live — its pending receipt compaction was queued",
	continuation_required = "its control route needs explicit continuation after reload",
	uncertain = "an uncertain effect is retained; reconcile it first",
	retirement_pending = "a mailbox retirement is already issued and not yet settled",
	effect_pending = "a retained effect is still queued, running or backpressured",
	owner_unresolved = "coordinator owner or its executors are unresolved",
	report_held = "a rejected report is held",
	held = "the worker is held",
	unlaunched = "never bound to a launched pane",
	live = "live — the sweep never stops a worker",
	finishing = "finish/release requested, but no exact native stop has been observed yet",
	unsettled = "stopped, but receipts, replies or notifications are not settled",
	referenced = "referenced by active rollover, landing or review work",
	oversize = "the retirement request would exceed the bridge bound",
}
-- Last sweep summary plus every non-retired decision (kept, retirement or compaction queued).
local function sweep_rows(sweep: any, limit: number): { any }
	local runs = if type(sweep) == "table" and type(sweep.runs) == "table" then sweep.runs else {}
	local last = runs[#runs]
	if last == nil then return { ui.text("Last sweep: none yet.") } end
	local rows = { ui.text("Last sweep: " .. last.local_date .. (if last.catch_up then " (catch-up run)" else "") .. " · registry revision " .. shown(last.revision, "unknown")
		.. " · retirements queued " .. shown(last.retire, "0") .. " · compactions queued " .. shown(last.compact, "0") .. " · kept " .. shown(last.keep, "0")
		.. " · already retired " .. shown(last.none, "0") .. " · " .. tostring(#runs) .. (if #runs == 1 then " run" else " runs") .. " retained") }
	local listed = 0
	for _, decision in last.decisions or {} do
		if decision.decision ~= "none" then
			listed += 1
			if listed <= limit then
				table.insert(rows, ui.text((if decision.decision == "keep" then "Kept " elseif decision.decision == "retire" then "Retirement queued " else "Compaction queued ")
					.. decision.work_id .. " / " .. decision.worker_id .. " — " .. (SWEEP_REASON_TEXT[decision.reason] or decision.reason)))
			end
		end
	end
	if listed > limit then table.insert(rows, ui.text("… " .. tostring(listed - limit) .. " more decisions in the durable run log")) end
	if (last.more or 0) > 0 then table.insert(rows, ui.text("… " .. tostring(last.more) .. " more workers beyond the recorded decision bound")) end
	if listed == 0 then table.insert(rows, ui.text("Nothing was kept or queued: every mailbox was already retired, or none exist.")) end
	return rows
end
local function same(left: any, right: any): boolean
	if type(left) ~= type(right) then return false end
	if type(left) ~= "table" then return left == right end
	for key, value in left do if not same(value, right[key]) then return false end end
	for key in right do if left[key] == nil then return false end end
	return true
end
-- Dispatch requests are value snapshots; native JSON arrays need their marker
-- preserved, not table.clone's unsupported copy of a protected metatable.
local function copy_request(value: any): any
	if type(value) ~= "table" or value == tern.json.null then return value end
	local out = if getmetatable(value) ~= nil then tern.json.array() else {}
	for key, child in value do out[key] = copy_request(child) end
	return out
end
-- `attrs` are display-only `data-*` hints for automation that locates a control; the click
-- still resolves only through the host-side entry its current token names.
local function button(view: any, label: string, entry: any, attrs: any?): any
	-- Navigation does not authorize an effect. Capture its revision when clicked;
	-- effect/confirmation controls retain their exact displayed revision.
	local navigation = entry.navigation or entry.kind == "config-open" or entry.kind == "config-close"
		or entry.kind == "project-select" or entry.kind == "advanced-toggle" or entry.kind == "finished-toggle"
	entry.authority_namespace = view.authority_namespace
	entry.expected_revision = if navigation then nil else view.authority_revision
	if navigation then entry.navigation_scope = view.navigation_scope end
	entry.orch_session_id = entry.orch_session_id or view.orch_session_id
	if entry.request then
		entry.request.authority_namespace = entry.authority_namespace
		entry.request.expected_revision = entry.expected_revision
	end
	-- Read-only navigation keeps its current semantic target across unrelated row
	-- insertions. Effects remain ordinal-bound; removed controls retain no history.
	local ordinal = #view.action_order + 1
	local request = entry.request
	local navigation_key = if navigation then entry.kind .. "\0" .. tostring(request and request.command or "")
		.. "\0" .. tostring(entry.orch_project_id or (request and request.orch_project_id) or "") .. "\0" .. tostring(request and request.conversation_id or "") else nil
	local previous = view.action_previous
	local token = if previous then (if navigation_key then previous.navigation[navigation_key] else previous.order[ordinal]) else nil
	local retained = if token then previous.actions[token] else nil
	if retained == nil or entry.intent ~= retained.intent or not same(entry, retained) then
		view.action_serial += 1
		token = view.alias_nonce .. ":" .. tostring(view.action_serial)
		-- Confirmation intents intentionally keep identity with the armed host view.
		-- Request and navigation snapshots may borrow nested projection tables.
		if entry.request then entry.request = copy_request(entry.request) end
		if navigation then entry.navigation_scope = copy_request(entry.navigation_scope) end
	else
		entry = retained
	end
	view.action_order[ordinal] = token
	if navigation_key then view.navigation_actions[navigation_key] = token end
	view.actions[token] = entry
	return ui.el("button", { text = label, actions = { click = "control=" .. token }, attrs = attrs })
end
-- An unacknowledged command refusal (dispatch card and Config share it).
local function refusal_rows(view: any, rows: { any }, result: any)
	table.insert(rows, ui.text(ui.span("REFUSED: " .. tostring(result.message or result.code), "error")))
	table.insert(rows, button(view, "Acknowledge command refusal", { kind = "dispatch-acknowledge", request_id = result.request_id }))
end
-- Dispatch machine-node fields copied from a projected action and from a command outcome.
local ACTION_KEYS = "phase claim worker_id retry_count retry_after_serial wake_status execution_origin execution_pane_binding execution_controller_pane reconciliation_only authority_namespace authority_revision logical_session_id admission_seq request_serial request_sha256"
local RESULT_KEYS = "ok code command request_id grant_id worker_id work_id wake_status"
local function owner_entry(kind: string, target: string, owner: any, revision: number): any
	return { kind = kind, target = target, owner_id = owner.owner_id, generation = owner.generation, revision = revision }
end
-- Window-side owner assistance: the host publishes the exact request as a one-shot operator
-- intent (`main.operator-intent`) that this session's window consumes; no URL is involved.
local function assistance(view: any, target: string, owner: any, revision: number, kind: string, label: string): any
	local request = {
		version = 2, kind = kind, source_nonce = view.alias_nonce, orch_session_id = view.orch_session_id,
		target = target, owner_id = owner.owner_id, generation = owner.generation, revision = revision,
		owner_alias = if owner.pane_binding ~= nil then owner.pane_binding.alias_nonce else nil,
	}
	return button(view, label, { kind = "assist-intent", request = request }, { ["data-orchplus-assist"] = kind, ["data-orchplus-target"] = target })
end
local function owner_card(view: any, target: string, owner: any, generation: number, revision: number): any
	if owner == nil then
		return ui.card(if target == "controller" then "Controller" else "Orchestrator", {
			ui.text("Unowned · generation " .. tostring(generation)),
			ui.text(if target == "controller" then "Select this registration, then claim its controller explicitly." else "Select an eligible SPAWN record below. Starting reserves this slot before provisioning; a pane-less reservation remains occupied."),
		})
	end
	local binding = owner.pane_binding or {}
	local observation = owner.last_observation
	local rows = {
		ui.kv({
			{ "Owner", tostring(owner.owner_id) },
			{ "Phase / generation", tostring(owner.phase) .. " / " .. tostring(owner.generation) },
			{ "Recorded host-local pane", tostring(binding.host_pane_id or "not bound (reservation remains occupied)") },
			{ "Native session evidence", tostring(binding.session_name or binding.host_session_id or "unavailable; logical registration is explicit") },
			{ "Work", tostring(owner.work_id or "none recorded") },
			{ "Managed worker binding", tostring(owner.managed_worker_id or "none") },
			{ "Pending executors", shown(owner.pending_executors, "none recorded") .. " · " .. tostring(owner.pending_executor_evidence or "unconfirmed") },
			{ "Owner active", if owner.owner_active == true then "known active" elseif owner.owner_active == false then "reported inactive; see evidence" else "unknown" },
			{ "Last observation", if observation ~= nil then tern.json.encode(observation) else "none; absence is not termination" },
		}),
		ui.row({
			assistance(view, target, owner, revision, "inspect", "Inspect"),
			assistance(view, target, owner, revision, "recheck", "Recheck"),
			assistance(view, target, owner, revision, "reveal", "Reveal owner"),
			assistance(view, target, owner, revision, "stop", "Stop assistance…"),
		}),
		ui.text("No timeout or missing pane clears ownership. Stop and reconcile the owner and all pending executors before recovery."),
		button(view, "Begin fenced recovery", owner_entry("begin-recovery", target, owner, revision)),
	}
	local stale_executors = owner.pending_executors > 0 and owner.pending_executor_evidence == "unconfirmed"
		and owner.owner_active == nil and observation ~= nil and observation.status == "unavailable"
	if stale_executors then
		local entry = owner_entry("attest-executors", target, owner, revision)
		entry.pending_executors = owner.pending_executors
		table.insert(rows, button(view, "Verify retained executors and unavailable owner…", entry))
	elseif owner.owner_active == true or owner.pending_executors > 0 then
		table.insert(rows, ui.text("Operator attestation cannot override a known active owner or currently observed pending executors. Retained unconfirmed executor counts require an unavailable observation and separate explicit reconciliation."))
	else
		table.insert(rows, button(view, "Independently verify unavailable owner stopped…", owner_entry("attest", target, owner, revision)))
	end
	return ui.card(if target == "controller" then "Recorded controller owner" else "Recorded orchestrator owner", rows)
end
-- Window-side dispatch control, published like `assistance`; the request table stays host-side
-- until clicked, so large policy/adopt payloads are never size-limited by a URL.
local NAVIGATION_COMMANDS = { project_menu = true, orchestration_menu = true, association_menu = true, open_plan = true }
local function dispatch_link(view: any, command: string, label: string, extra: any?): any
	local request = { command = command, source_nonce = view.alias_nonce, orch_session_id = view.orch_session_id }
	for key, value in extra or {} do request[key] = value end
	local attrs = { ["data-orchplus-command"] = command }
	if type(request.worker_id) == "string" then attrs["data-orchplus-worker"] = request.worker_id end
	return button(view, label, { kind = "operator-intent", request = request, navigation = NAVIGATION_COMMANDS[command] }, attrs)
end
local function pause_link(view: any, policy: any): any
	return dispatch_link(view, if policy.paused then "resume" else "pause", if policy.paused then "Resume scheduling" else "Pause new work")
end
-- `orchplus.worker` node fields copied verbatim from the projected workflow worker.
local WORKER_KEYS = "worker_id work_id worker_generation origin_binding pane_binding due_poll poll_ms poll_continuation stale_coordinator due_report report_request_pending active_action_id cleanup_ready"
	.. " activation_received"
	.. " finish_requested coordinator_owner_id launch_origin_binding launch_pane_binding continuation_required continuation_proof"
	.. " orchestration_excluded context_used_pct context_seq context_rollover phase due_rollover rollover restored adopt_pane_binding withdrawal role family review_id"
	.. " orch_project_id open_conversation presentation execution_cwd record_id checks backend allocation_target"
-- Why an account USAGE delta (or one of its windows) is not comparable.
local USAGE_WHY = { reset_crossed = "a quota reset happened in between", stale = "a reading is stale or missing",
	unbound = "a reading has no bound account", different_account = "the readings are from different accounts" }
-- Rule H proof wording by current (non-voided) review status, with and without cross-family enforcement.
local ENFORCED_PROOF = { approved = "cross-family review approved", changes_required = "changes required — rework round pending", capped = "review rounds capped — owner decision" }
local PLAIN_PROOF = { approved = "review approved", capped = "review rounds capped" }
-- Gate phases that are settled history: no cancel control, sorted after open questions.
local GATE_SETTLED = { acknowledged = true, cancelled = true, superseded = true, resolved = true }
-- Quota evidence display (USAGE capacity v1, normalized by quota.luau). Unknown is never "plenty".
local function when(ms: any): string
	if type(ms) ~= "number" then return "unknown" end
	return os.date("!%Y-%m-%d %H:%M UTC", math.floor(ms / 1000)) :: string
end
local function ago(ms: any, now: number): string
	if type(ms) ~= "number" then return "unknown" end
	local seconds = math.max(0, math.floor((now - ms) / 1000))
	return if seconds < 120 then tostring(seconds) .. "s ago" elseif seconds < 7200 then tostring(math.floor(seconds / 60)) .. "m ago" else tostring(math.floor(seconds / 3600)) .. "h ago"
end
local function quota_line(assessed: any, now: number): string
	local text = "Quota (USAGE): " .. assessed.status
	if assessed.remaining_pct ~= nil then
		text ..= " · " .. tostring(assessed.remaining_pct) .. "% remaining (lowest bound window) · weekly reset " .. when(assessed.weekly_reset_ms)
			.. " · observed " .. ago(assessed.observed_at_ms, now)
	end
	if assessed.reason then text ..= " — " .. (quota.REASONS[assessed.reason] or assessed.reason) end
	text ..= " · binding " .. (if assessed.binding then "verified " .. assessed.binding:sub(1, 8) .. "…" else "none (unknown, never inferred from labels)")
	return text
end
local function evidence_line(evidence: any, p: any, now: number): string
	if not evidence then
		return "USAGE capacity evidence: none current for this catalog" .. (if p.quota_routing then "; quota routing holds new work until a validated snapshot arrives." else ".")
	end
	return "USAGE capacity evidence: revision " .. evidence.revision:sub(1, 12) .. "… · validated " .. ago(evidence.validated_at_ms, now)
		.. " · lease ends " .. (if evidence.expires_at_ms > now then "in " .. tostring(math.floor((evidence.expires_at_ms - now) / 1000)) .. "s" else "expired")
		.. " · reserve " .. tostring(p.quota_reserve_pct) .. "% · max age " .. tostring(math.floor(p.quota_max_age_ms / 60000)) .. "m · not a provider reservation"
end
local function routing_rows(view: any, rows: any, worker: any, admitted: boolean)
	local r = worker.routing
	if not r then return end
	local head = "Routing (" .. r.mode .. ", " .. tostring(r.scope or "initial_dispatch") .. "): " .. r.phase .. " · requested " .. r.requested.id
		.. (if r.selected then " · selected " .. r.selected.id else "")
		.. (if r.switched then " · substitution by " .. tostring(r.authority) .. (if r.needs then " (" .. r.needs .. " change)" else "") else "")
		.. " · policy " .. r.policy_digest:sub(1, 8) .. " · evidence " .. (if r.evidence_revision then r.evidence_revision:sub(1, 8) else "none")
		.. (if r.reservation then " · reservation " .. r.reservation.id .. " " .. r.reservation.phase else "")
		.. (if r.selector then " · selector " .. (if r.selector == "unverified_owner_text" then "unverified (owner text only)" else "unverified (none recorded)") else "")
	table.insert(rows, ui.text(ui.span(head, if r.phase == "selected" then "strong" else "warning")))
	if r.reason then table.insert(rows, ui.text(r.reason.code .. " · " .. r.reason.message)) end
	for _, c in r.candidates do
		table.insert(rows, ui.text("  " .. (if c.rank == 0 then "selected by owner: " else "alternative: ") .. c.id .. " · " .. c.status
			.. (if c.remaining_pct ~= nil then " · " .. tostring(c.remaining_pct) .. "%" else "") .. (if c.weekly_reset_ms then " · weekly reset " .. when(c.weekly_reset_ms) else "")
			.. (if c.reason then " · " .. c.reason else "") .. (if c.needs then " · needs " .. c.needs .. " permission" else "")
			.. (if c.rejection then " · rejected: " .. c.rejection else "")))
	end
	if admitted and not r.bound and r.phase ~= "selected" then
		table.insert(rows, ui.row({ dispatch_link(view, "capacity_refresh", "Re-check capacity now"),
			dispatch_link(view, "cancel_work", "Cancel this queued work…", { worker_id = worker.worker_id }) }))
	elseif admitted and r.phase ~= "selected" then
		table.insert(rows, ui.text("Provisioned for " .. worker.record_id .. "; it launches only after fresh evidence clears it (or quota routing is turned off for an unsubstituted record)."))
		table.insert(rows, dispatch_link(view, "capacity_refresh", "Re-check capacity now"))
	end
end
-- "Forget this orchestration…" is visible at the top level, not hidden in Advanced: its blockers and its pending state
-- are owner decisions. No row ever tells the owner to close a pane: Forget checks SPAWN's own work, not panes.
local function forget_view(view: any, projection: any): { any }
	local nodes: { any } = {}
	local control = if projection.dispatch then projection.dispatch.session_control else nil
	local pending = control ~= nil and control.close ~= nil and control.close.forget ~= nil
	local forget = view.forget
	if type(forget) ~= "table" and not pending then return nodes end
	local text = require("./forget_text")
	if type(forget) == "table" and forget.stage == "checking" then
		table.insert(nodes, ui.text(text.CHECKING))
		return nodes
	end
	local card: { any } = {}
	if type(forget) == "table" and forget.stage == "blocked" then
		table.insert(card, ui.text(text.BLOCKED))
		for _, row in forget.blockers do table.insert(card, ui.text(text.row(row))) end
		if type(forget.blockers_omitted) == "number" and forget.blockers_omitted > 0 then table.insert(card, ui.text(text.additional_blockers(forget.blockers_omitted))) end
		local has_participants = type(forget.participants) == "table" and #forget.participants > 0
		local omitted = if type(forget.omitted) == "number" then forget.omitted else 0
		if has_participants or omitted > 0 then
			table.insert(card, ui.text(text.PARTICIPANTS))
			if has_participants then for _, row in forget.participants do table.insert(card, ui.text(text.row({ agent = row.agent, host = row.host }))) end end
			if omitted > 0 then table.insert(card, ui.text(text.additional(omitted))) end
		end
		table.insert(card, ui.text(text.RESIDUAL))
	end
	if pending or (type(forget) == "table" and (forget.stage == "pending" or forget.pending == true)) then
		table.insert(card, ui.text(text.PENDING))
		table.insert(card, dispatch_link(view, "forget_continue", text.CONTINUE))
	end
	if type(forget) == "table" then
		table.insert(card, ui.row({ dispatch_link(view, "forget_session", text.CHECK_AGAIN), dispatch_link(view, "forget_back", text.BACK) }))
	end
	table.insert(nodes, ui.card(text.MENU, card))
	return nodes
end
local function dispatch_view(view: any, projection: any, selected: any): (any, any, any?, any)
	local d = projection.dispatch or { actions = {}, workers = {} }
	local owner, bound, admitted = controller(view, selected)
	local rows = { ui.text("SPAWN owns launch/configuration and mailbox target access. Display identity is configured metadata, not verified account isolation.") }
	if bound then
		table.insert(rows, ui.row({ dispatch_link(view, "bridge_admit", "Admit this session to SPAWN"),
			dispatch_link(view, "bridge_reconcile", "Reconcile current SPAWN control"),
			dispatch_link(view, "close_session", "Close logical session…"),
			dispatch_link(view, "forget_session", require("./forget_text").MENU) }))
		table.insert(rows, ui.text("Close fences new work. Owners, uncertain effects, deliveries and document writes must settle before removal; source documents and Git are untouched."))
	end
	local closing = if d.session_control and d.session_control.close then d.session_control.close.control_origin else nil
	local forgetting = d.session_control ~= nil and d.session_control.close ~= nil and d.session_control.close.forget ~= nil
	if not forgetting and not bound and closing and closing.binding.alias_nonce == view.alias_nonce and closing.controller_pane == tostring(view.pane) then
		table.insert(rows, ui.row({ dispatch_link(view, "bridge_reconcile", "Read current closure status"),
			dispatch_link(view, "close_session", "Continue explicit close…") }))
	end
	table.insert(rows, ui.text("Host scope: local workers use local ORCH+. For remote workers, open ORCH+ on that attached remote Tern host. Controller, workers, mailbox and SPAWN authority stay on the same execution host; managed SSH hops are not supported. Ordinary SPAWN SSH launches are unchanged."))
	if admitted then
		table.insert(rows, dispatch_link(view, "catalog", "Refresh configured agents"))
	else table.insert(rows, ui.text("Agent connection is being checked automatically. Existing conversations and held work are preserved.")) end
	if bound then
		table.insert(rows, dispatch_link(view, "recovery_guide", "Connection details and exceptional recovery"))
		table.insert(rows, ui.text("Routine reloads and compatible updates reconnect automatically. Uncertain effects are checked without launching another copy. Only conflicts or unconfirmed outcomes need a decision here."))
	end
	local routing_policy = if d.workflow then d.workflow.policy else nil
	local evidence = if d.workflow then d.workflow.capacity else nil
	local now = math.floor(os.time() * 1000)
	if routing_policy and (routing_policy.quota_routing or evidence) then
		table.insert(rows, ui.text(evidence_line(evidence, routing_policy, now)))
		if admitted then table.insert(rows, dispatch_link(view, "capacity_refresh", "Refresh quota evidence from USAGE")) end
		if routing_policy.quota_routing then
			table.insert(rows, ui.text("Quota routing is on: the record you choose launches only on fresh identity-bound USAGE evidence above the reserve; an allowed alternative may be used, a denied substitution becomes an owner decision, and unknown evidence holds the work."))
		end
	end
	if d.catalog then
		table.insert(rows, ui.text("Catalog revision " .. tostring(d.catalog.revision) .. " · this page only"))
		for _, record in d.catalog.records do
			table.insert(rows, ui.text(record.id .. " · " .. tostring(record.provider or "") .. " · " .. tostring(record.account_label or "") .. " · " .. tostring(record.backend or "")))
			table.insert(rows, ui.text("Capabilities: " .. tern.json.encode(record.capabilities) .. " · prerequisites: " .. tern.json.encode(record.unsupported)))
			if record.capability_evidence then table.insert(rows, ui.text("Capability evidence: " .. tostring(record.capability_evidence))) end
			if record.effective_identity then table.insert(rows, ui.text("Catalog identity facts: " .. tern.json.encode(record.effective_identity))) end
			if record.model_variant or record.profile_variant then table.insert(rows, ui.text("Configured variants: " .. tostring(record.model_variant or "") .. " / " .. tostring(record.profile_variant or ""))) end
			-- SPAWN exposes no typed selector verification status; never shown as enforced.
			table.insert(rows, ui.text("Model/profile selector: unverified · " .. (if quota.selector_state(record) == "unverified_owner_text"
				then "owner-entered evidence text: " .. tostring(record.selector_evidence) else "no selector evidence recorded") .. " (not enforced)"))
			if routing_policy and (routing_policy.quota_routing or evidence) and record.eligible then
				table.insert(rows, ui.text(quota_line(quota.assess(evidence, record.id, record.revision, routing_policy, now), now)))
			end
			if admitted and record.eligible then
				local fields = { record_id = record.id, record_revision = record.revision, catalog_revision = d.catalog.revision, coordinator = false, cwd = record.cwd, placement = record.placement }
				table.insert(rows, dispatch_link(view, "queue", "Assign explicit task to " .. record.id, fields))
				fields = table.clone(fields); fields.coordinator = true
				if table.find(record.capabilities, "coordinator-control-v1") then
					table.insert(rows, dispatch_link(view, "queue", "Start selected coordinator " .. record.id, fields))
				else table.insert(rows, ui.text("Coordinator unavailable: explicitly configure/provision coordinator-control-v1 after helper verification. Ordinary task dispatch remains available.")) end
			end
		end
		if admitted and d.catalog.next_cursor ~= nil then table.insert(rows, dispatch_link(view, "catalog", "Next catalog page", { bytes = d.catalog.next_cursor })) end
	end
	for _, worker in d.workers do
		table.insert(rows, ui.text(worker.work_id .. " / " .. worker.worker_id .. " · " .. worker.record_id .. " · " .. worker_state(worker)
			.. " · receipt " .. shown(worker.accepted_seq, "none yet") .. " / confirmed " .. shown(worker.compacted_floor, "none yet")))
		if worker.reason then table.insert(rows, ui.text(tern.json.encode(worker.reason))) end
		routing_rows(view, rows, worker, admitted)
		local withdrawal = worker.withdrawal
		if withdrawal then
			if withdrawal.evidence == "failed_startup" then
				table.insert(rows, ui.text("This coordinator really launched but never accepted or activated. Its owner was recovered. Removal first asks SPAWN to check the exact original native pane in this authorized window; only proved exit/absence and an unused producer journal permit retirement."))
				if withdrawal.mailbox_retire == "retiring" then
					table.insert(rows, ui.text("Failed-startup retirement is " .. tostring(worker.mailbox_status) .. ". Keep its original pane, launch and mailbox target until SPAWN confirms retirement; an uncertain outcome is never re-issued."))
				elseif admitted then
					table.insert(rows, dispatch_link(view, "cancel_work", "Remove failed startup…", { worker_id = worker.worker_id }))
					table.insert(rows, ui.text("No native stop, acceptance or release is fabricated. Live, restored, unknown or consumed generations remain retained. Across a continued window epoch, only genuine original-pane absence is accepted; an existing restored target is refused."))
				end
			else
			local effect = withdrawal.op .. (if withdrawal.action_id then " (" .. withdrawal.action_id .. ")" else "")
			if withdrawal.allocation_target then
				table.insert(rows, ui.text(ui.span("Startup failed without a confirmed mailbox handle. Cancellation first checks the exact retained allocation; unknown allocation stays held. No startup is repeated.", "warning")))
			elseif withdrawal.status_required then
				table.insert(rows, ui.text(ui.span("Startup outcome unconfirmed: " .. effect .. " may have run. Nothing re-issues it. Inspect its retained SPAWN outcome; cancellation requires positive proof of nonexecution.", "warning")))
			elseif withdrawal.pending_startup then
				table.insert(rows, ui.text("Startup pending: " .. effect .. " has not been sent. Approved work starts automatically while this group is running; cancellation is optional."))
			elseif withdrawal.mailbox_retire ~= "retiring" then
				table.insert(rows, ui.text(ui.span(if withdrawal.evidence == "spawn_rejected"
					then "Startup rejected: SPAWN refused " .. effect .. ". Cancellation settles only its verified unused resources; startup is not retried."
					else "Startup held" .. (if worker.continuation_required then " after continuation" else "")
						.. ": " .. effect .. " did not execute. Inspect the retained refusal or cancellation; this is not permission to repeat an uncertain effect.", "warning")))
			end
			if withdrawal.mailbox_retire == "retiring" then
				table.insert(rows, ui.text("Cancelled by the owner: its unused mailbox is being retired (" .. tostring(worker.mailbox_status) .. "). The worker is removed once SPAWN confirms retirement; an uncertain retirement is never re-issued, so inspect its retained outcome."))
			elseif admitted then
				local label = if withdrawal.allocation_target then "Cancel failed work…"
					elseif withdrawal.pending_startup then "Cancel queued work…"
					elseif withdrawal.status_required then "Check before cancelling work…" else "Cancel never-launched work…"
				table.insert(rows, dispatch_link(view, "cancel_work", label, { worker_id = worker.worker_id }))
				local retire_sentence = if withdrawal.mailbox_provisioned
					then " Its provisioned, never-used mailbox is then retired through the exact retirement path; the worker is removed once SPAWN confirms retirement. Nothing native is stopped."
					else " Nothing native is stopped or retired."
				table.insert(rows, ui.text(if withdrawal.mailbox_retire == "refused" then "SPAWN refused the previous retirement of this work's unused mailbox (reason above); nothing was removed. Cancel again to issue one fresh retirement."
					elseif withdrawal.allocation_target then "Cancel observes the exact allocation target. Only verified absence releases work directly; an existing unused mailbox follows normal verified retirement. Unknown observations never delete work or relaunch an agent."
					elseif withdrawal.status_required
					then "Cancel first reads SPAWN's retained status of that exact request. Missing after reclamation is not proof of nonexecution; only positive pre-effect refusal permits withdrawal." .. retire_sentence
					elseif withdrawal.mailbox_retire ~= nil then (if withdrawal.evidence == "spawn_rejected" then "SPAWN's retained startup rejection is terminal"
						elseif withdrawal.evidence == "unissued" then "This request was never sent" else "SPAWN proved this request did not execute")
						.. ", so cancel retires the unused mailbox through the exact retirement path. The worker and its reservations are released once SPAWN confirms retirement; a refused or uncertain retirement keeps the worker here with that outcome."
					elseif withdrawal.evidence == "spawn_rejected" then "SPAWN's retained startup rejection is terminal. Cancellation releases reservations only after allocation is verified and any unused mailbox is retired. Nothing native is stopped."
					else "Cancel removes this unexecuted work and releases its reservations directly. Nothing native is stopped or retired."))
			end
			end
		end
		if worker.rejected_report then
			table.insert(rows, ui.text(ui.span("Report held: " .. tostring(worker.rejected_report.code) .. " · "
				.. tostring(worker.rejected_report.message) .. ". Its immutable bytes remain retained and unacknowledged. Inspect the producer and this generation; no report is skipped or automatically retried, and automatic report/watermark reads stop until you act (only pending outbound ACK/reply settlement continues). The explicit Read / settle and watermark controls remain available.", "error")))
			if admitted and not worker.continuation_required then
				table.insert(rows, dispatch_link(view, "recheck_report", "Re-check held report…", { worker_id = worker.worker_id }))
				table.insert(rows, ui.text("Re-check decodes the same retained bytes (same sequence, event ID and SHA-256) with current validation. If they are now valid they proceed exactly like a fresh read; otherwise they stay held with the new reason. Nothing is skipped or replaced."))
			end
		end
		-- Reload leaves every generation, including an unaccepted launch, without a continued route.
		if bound and worker.continuation_required and worker.pane_binding and worker.stop_status ~= "absent" and worker.stop_status ~= "exited" and worker.mailbox_status ~= "retired" then
			table.insert(rows, dispatch_link(view, "continue_worker", "Continue after reload / reattach explicitly…", { worker_id = worker.worker_id }))
			table.insert(rows, ui.text("This " .. worker.phase .. " generation needs explicit reattachment after reload before its mailbox (including a pending ACCEPTED) is read again. Select its exact pane and attest old executors stopped; identity and enrolment are unchanged."))
		end
		if worker.pane_binding then table.insert(rows, ui.text("Correlated native pane observation (window-local): " .. tern.json.encode(worker.pane_binding))) end
		if worker.effective_identity then table.insert(rows, ui.text("SPAWN outcome identity facts: " .. tern.json.encode(worker.effective_identity))) end
		if worker.coordinator_owner_id then
			local phase = if worker.owner_released then "retired — slot released; successor requires explicit start"
				elseif worker.mailbox_status == "retired" then "mailbox retired — settle normal owner release"
				elseif worker.stop_status == "absent" or worker.stop_status == "exited" then "native stopped — retire mailbox"
				elseif worker.release_seq then "quiescent release committed — drain final ACKs/replies and confirm watermark before native stop"
				elseif worker.start_retirement_requested then "owner withdrew pending START — stopping the idle orchestrator, then retiring its mailbox"
				elseif worker.retirement_requested then "retirement requested — waiting for authenticated quiescent release"
				elseif worker.activation_received then "activated — explicit release required when finished"
				elseif worker.activation_issued then "activation issued — awaiting durable reply receipt"
				else "no activation grant — startup or an earlier build; occupied, never inferred active"
			table.insert(rows, ui.text("Coordinator " .. worker.coordinator_owner_id .. " / generation " .. shown(worker.coordinator_generation, "unknown") .. " · " .. phase))
			table.insert(rows, ui.text("Native stop: " .. shown(worker.stop_status, "not requested") .. " · mailbox: " .. shown(worker.mailbox_status, "not provisioned")
				.. " · contiguous replies " .. shown(worker.reply_floor, "0") .. "/" .. shown(worker.reply_seq, "0")))
			if admitted and worker.activation_issued and not worker.retirement_requested and not worker.release_seq and not worker.owner_released then
				table.insert(rows, dispatch_link(view, "retire", "Request graceful coordinator retirement", { worker_id = worker.worker_id }))
				if worker.start_retirement_ready then
					table.insert(rows, dispatch_link(view, "withdraw_start_retire", "Withdraw pending START and retire idle orchestrator", { worker_id = worker.worker_id }))
					table.insert(rows, ui.text("This permanently cancels only the pending START approval. Its work stays held. Retirement still requires a verified idle or exited orchestrator and settled communication; unknown activity or other unfinished obligations block it."))
				end
			end
		end
		if not worker.coordinator_owner_id and worker.stop_status ~= nil and worker.stop_status ~= "not_requested" and not (admitted and worker.finish_requested) then
			table.insert(rows, ui.text("Native stop: " .. tostring(worker.stop_status) .. " · mailbox: " .. shown(worker.mailbox_status, "not provisioned")))
		end
		if admitted and not worker.coordinator_owner_id then
			if worker.finish_requested then
				table.insert(rows, ui.text("Finish requested · native stop " .. shown(worker.stop_status, "not requested")
					.. " · mailbox " .. shown(worker.mailbox_status, "not provisioned") .. ". Capacity is released only after verified stop and settled retirement."))
				if worker.mailbox_status == "refused" then
					table.insert(rows, dispatch_link(view, "finish", "Retry mailbox retirement once…", { worker_id = worker.worker_id }))
					table.insert(rows, ui.text("SPAWN refused retirement before any effect: the stopped worker's helper journal still holds pending reports or unacknowledged/unresolved control messages. The mailbox stays provisioned and nothing is retried automatically; the nightly sweep or this control issues one fresh attempt."))
				end
			else
				table.insert(rows, dispatch_link(view, "finish", "Finish ordinary worker…", { worker_id = worker.worker_id }))
			end
		end
		if admitted and not worker.owner_released then
			table.insert(rows, dispatch_link(view, "poll", "Read / settle " .. worker.work_id, { worker_id = worker.worker_id }))
			table.insert(rows, dispatch_link(view, "poll", "Read cumulative receipt watermark", { worker_id = worker.worker_id, bytes = "watermark" }))
			if not worker.retirement_requested and not worker.release_seq then
				table.insert(rows, dispatch_link(view, "reply", "Queue immutable progress request", { worker_id = worker.worker_id }))
			end
		end
	end
	local active = d.actions[view.dispatch_action]
	if active == nil then
		for _, a in d.actions do if a.phase == "ready" then active = a; break end end
	end
	-- Newly selected queued work must not hide a live grant from its executor.
	if active == nil or active.phase ~= "claimed" then
		for _, a in d.actions do if a.phase == "claimed" then active = a; break end end
	end
	-- A published manifest's native wake is still a real effect. Keep its original
	-- grant addressable even when another UI command selects newly queued work.
	for _, a in d.actions do if a.wake_pending then active = a; break end end
	for id, a in d.actions do
		local start, start_project
		for key, project in d.projects or {} do if project.start and project.start.delivery_action_id == id then
			start, start_project = project.start, key
		end end
		local scoped = if view.scoped_results then view.scoped_results[id] else nil
		if scoped and scoped.result and scoped.result.ok == false then
			table.insert(rows, ui.text(ui.span("Held " .. a.request.op .. " / " .. id .. ": "
				.. tostring(scoped.result.message or scoped.result.code) .. ". No automatic retry; inspect the exact action.", "error")))
		end
		if a.wake_status == "awaiting_window" then
			table.insert(rows, ui.text("Awaiting safe authorized-window delivery for " .. id .. "; working, native-input and unavailable workers are not interrupted. Other workers keep their independent mailbox drivers."))
		end
		if admitted and a.phase == "ready" then
			table.insert(rows, dispatch_link(view, "execute", "Run queued " .. a.request.op .. " in its original window", { action_id = id }))
		end
		-- An owner-stopped retry loop (loop_cap "Keep it stopped") is final: no retry control.
		local retry_stopped = a.retry_loop ~= nil and a.retry_loop.state == "stopped"
		if a.phase == "backpressure" and retry_stopped then
			table.insert(rows, ui.text(ui.span("Retries of " .. a.request.op .. " / " .. id .. " stopped by the owner (loop cap). It stays unexecuted; cancel the work to end it.", "warning")))
		elseif admitted and a.phase == "backpressure" then
			if start then
				table.insert(rows, dispatch_link(view, "project_start_retry", "Retry original START delivery",
					{ orch_project_id = start_project, start_id = start.start_id, project_revision = start.project_revision, decision_context = start.decision_context }))
			else table.insert(rows, dispatch_link(view, "retry", "Recheck unexecuted capacity refusal: " .. a.request.op, { action_id = id })) end
		end
		if a.phase == "claimed" or a.phase == "uncertain" then
			table.insert(rows, ui.text("Retained " .. a.request.op .. " · " .. a.request.request_id .. " / " .. id .. " · " .. a.phase
				.. " · executor " .. tostring(if a.claim then a.claim.executor else "none")))
			if admitted then table.insert(rows, dispatch_link(view, "reconcile", "Read retained SPAWN outcome (never relaunch)", { action_id = id })) end
			if admitted and not start and a.phase == "uncertain" and (a.request.op == "mailbox_publish_ack" or a.request.op == "mailbox_publish_reply") then
				table.insert(rows, dispatch_link(view, "readback_publication", "Read back and re-publish the exact same bytes", { action_id = id }))
				table.insert(rows, ui.text("Immutable ACK/reply bytes are idempotent: SPAWN reads them back first and publishes the same bytes only if absent. Native effects are never repeated."))
			end
			if a.phase == "uncertain" and (a.request.op == "mailbox_read" or a.request.op == "catalog") then
				table.insert(rows, ui.text("Read-only: it changed nothing and holds no effect slot. If SPAWN has no record of it, it resolves without effect."
					.. (if a.request.op == "mailbox_read" then " It never blocks reattachment; the reattached route supersedes it and re-reads from the durable cursor." else "")))
			end
			if a.phase == "uncertain" and a.claim then table.insert(rows, button(view, "Verify this retained executor stopped…",
				{ kind = "executor-arm", action_id = id, executor = a.claim.executor, revision = projection.revision })) end
		end
	end
	if view.executor_confirmation then
		table.insert(rows, ui.text("I independently stopped/reconciled action " .. view.executor_confirmation.action_id .. ", executor "
			.. view.executor_confirmation.executor .. ", including any delayed native launch. This does not retry it or clear ownership."))
		table.insert(rows, button(view, "Confirm exact retained executor reconciliation", { kind = "executor-confirm", intent = view.executor_confirmation }))
	end
	local outcome = view.dispatch_result
	local command_result = view.dispatch_command_result
	local driver_result = view.dispatch_driver_result
	if command_result and command_result.ok == false and not command_result.acknowledged then refusal_rows(view, rows, command_result) end
	-- Every uncertain retained action (bounded): the window's read-only reconciliation covers each
	-- one, independent of selection or which worker is active.
	local uncertain_ids = {}
	for id, a in d.actions do if a.phase == "uncertain" and a.claim then table.insert(uncertain_ids, id) end end
	table.sort(uncertain_ids)
	while #uncertain_ids > 16 do table.remove(uncertain_ids) end
	local machine = { version = 2, authority_version = projection.version, name = selected.name, source_nonce = view.alias_nonce, host_pane_id = tostring(view.pane), orch_session_id = view.orch_session_id,
		owner_id = if bound then owner.owner_id else nil, owner_generation = if bound then owner.generation else nil,
		protocol = d.protocol, phase = d.phase, authority_namespace = projection.authority_namespace, authority_revision = projection.revision,
		next_admission_seq = d.next_admission_seq,
		spawn_namespace = d.spawn_namespace, compatibility = d.compatibility, sessions = d.sessions, control = d.control,
		session_control = if d.session_control then pick(d.session_control, "phase admission_seq admitted generation_floor request_floor next_request_serial last_authority_revision close") else nil,
		reconcile_progress = d.reconcile_progress,
		control_result = if view.dispatch_control_result then pick(view.dispatch_control_result, "request_id command ok code message") else nil,
		controller_phase = if bound then owner.phase else nil, revision = projection.revision, command_cursor = d.command_cursor,
		action = if active then pick(active, ACTION_KEYS, { action_id = active.request.action_id }) else nil,
		result = if outcome then pick(outcome, RESULT_KEYS, { action_id = outcome.action_id }) else nil,
		command_result = if command_result then pick(command_result, "request_id command action_id ok code message acknowledged orch_project_id orch_session_id") else nil,
		driver_result = if driver_result then pick(driver_result, "request_id command action_id worker_id ok code message orch_project_id") else nil,
		poll_result = if view.dispatch_poll_result then pick(view.dispatch_poll_result, "request_id command action_id worker_id ok code message") else nil,
		allocation_result = if view.dispatch_allocation_result then pick(view.dispatch_allocation_result, "request_id command worker_id ok code message") else nil,
		receipt = view.dispatch_receipt, uncertain_actions = uncertain_ids }
	local request_node = if not active then nil elseif active.request_bytes then keyed(active.request_bytes, "dispatch-request", "orchplus.request")
		else keyed(tern.json.encode(active.request), "dispatch-draft", "orchplus.draft")
	local bytes = tern.json.encode(machine)
	if #bytes > 65536 then
		bytes = tern.json.encode({ version = 2, source_nonce = view.alias_nonce, error = "Current control projection exceeds 65536 bytes; no grant exposed." })
	end
	local bridge = keyed(bytes, "dispatch-state", "orchplus.dispatch")
	local scoped_nodes = {}
	for id, a in d.actions do
		local scoped = table.clone(machine)
		scoped.sessions = nil; scoped.control = nil; scoped.session_control = nil; scoped.compatibility = nil
		scoped.action = pick(a, ACTION_KEYS, { action_id = id })
		local retained = if view.scoped_results then view.scoped_results[id] else nil
		local response = if retained then retained.result elseif outcome and outcome.action_id == id then outcome else nil
		scoped.result = if response then pick(response, RESULT_KEYS, { action_id = id }) else nil
		scoped.receipt = if retained then retained.receipt elseif view.dispatch_receipt and view.dispatch_receipt.action_id == id then view.dispatch_receipt else nil
		scoped.command_result = nil
		scoped.allocation_result = nil
		local encoded = tern.json.encode(scoped)
		if #encoded <= 8192 then
			table.insert(scoped_nodes, keyed(encoded, "dispatch-action-" .. id, "orchplus.dispatch"))
			if a.request_bytes then table.insert(scoped_nodes, keyed(a.request_bytes, "dispatch-request-" .. id, "orchplus.request"))
			else table.insert(scoped_nodes, keyed(tern.json.encode(a.request), "dispatch-draft-" .. id, "orchplus.draft")) end
		else table.insert(rows, ui.text(ui.span("Exact action surface unavailable: " .. id .. " exceeds 8192 bytes. No grant exposed.", "error"))) end
	end
	-- Consumed actions are absent. A live delivery receipt remains visible until its window ACKs it,
	-- without retaining the completed request, response or a runnable action.
	for id, retained in view.scoped_results or {} do
		if d.actions[id] == nil and retained.receipt then
			local scoped = table.clone(machine)
			scoped.sessions = nil; scoped.control = nil; scoped.session_control = nil; scoped.compatibility = nil
			scoped.action = nil; scoped.command_result = nil
			scoped.allocation_result = nil
			scoped.result = pick(retained.result, RESULT_KEYS, { action_id = id })
			scoped.receipt = retained.receipt
			table.insert(scoped_nodes, keyed(tern.json.encode(scoped), "dispatch-action-" .. id, "orchplus.dispatch"))
		end
	end
	return ui.card("Managed dispatch", rows), bridge, request_node, scoped_nodes
end
-- Pending owner notifications ride gate evidence (orchplus-notice:v1:<status>:<order>:<cleared>:<code>:<reason>).
local function pending_notices(flow: any): { any }
	local found = {}
	for _, gate in flow.gates do
		for _, entry in gate.evidence or {} do
			if type(entry) == "string" and entry:sub(1, 19) == "orchplus-notice:v1:" then
				local status, order, cleared, code, reason = entry:sub(20):match("^(%a+):(%d+):(%d+):([%w_%-]+):(.*)$")
				if status == "pending" then table.insert(found, { gate = gate, order = tonumber(order), cleared = tonumber(cleared), code = code, reason = reason }) end
			end
		end
	end
	table.sort(found, function(a: any, b: any): boolean return a.order < b.order or (a.order == b.order and a.gate.id < b.gate.id) end)
	return found
end
-- Refusals stay on the main surface, above every other decision and for every project, until dismissed.
local function proposal_refusals(view: any, projection: any, selected: any): any?
	local flow = if projection.dispatch then projection.dispatch.workflow else nil
	if not flow then return nil end
	local _, _, admitted = controller(view, selected)
	local rows = {}
	for _, worker in flow.workers do
		-- Capacity-held intake is recorded as the worker's reason (code full); the immutable source stays unacknowledged.
		local projected = if projection.dispatch.workers then projection.dispatch.workers[worker.worker_id] else nil
		if projected and projected.reason and projected.reason.code == "full" then
			table.insert(rows, ui.text(ui.span("Delivery is held by capacity. Nothing was added or queued. Inspect the retained report and use Re-check after capacity is restored.", "warning")))
		end
	end
	for _, item in pending_notices(flow) do
		table.insert(rows, ui.text(ui.span("Your orchestrator's proposal was refused (" .. item.code .. "): " .. item.reason, "warning")))
		if item.cleared > 0 then table.insert(rows, ui.text(tostring(item.cleared) .. " older refusals were cleared")) end
		if admitted then
			table.insert(rows, dispatch_link(view, "dismiss_refusal", "Dismiss", { gate_id = item.gate.id, gate_revision = item.gate.revision, worker_id = item.gate.worker_id }))
		end
	end
	if #rows == 0 then return nil end
	return ui.card("Proposal refused", rows)
end
local function workflow_view(view: any, projection: any, selected: any): (any, any)
	local flow = if projection.dispatch then projection.dispatch.workflow else nil
	local _, bound, admitted = controller(view, selected)
	local rows, nodes, ids = {}, {}, {}
	if not flow then return ui.card("Workflow", { ui.text("Workflow unavailable; no scheduling authority exposed.") }), nodes end
	local function machine(key: string, role: string, value: any, limit: number?)
		local bytes = tern.json.encode(value)
		if #bytes > (limit or 8192) then
			table.insert(rows, ui.text(ui.span("Workflow surface unavailable: " .. key .. " exceeds the native bounded projection.", "error")))
			return
		end
		table.insert(nodes, keyed(bytes, key, role))
	end
	local policy = flow.policy
	table.insert(rows, ui.text((if policy.paused then "Paused — new work held; receipts, reports and answers still settle." else "Scheduling enabled")
		.. " · report polling " .. tostring(math.floor(policy.poll_ms / 1000)) .. "s · automatic-report interval " .. tostring(math.floor(policy.report_request_ms / 1000)) .. "s · stale after " .. tostring(math.floor(policy.stale_ms / 1000)) .. "s"
		.. " · automatic reports " .. (if policy.automatic_reports then "enabled" else "off")))
	local wake = view.idle_wake
	if type(wake) == "table" and wake.state == "active" then
		table.insert(rows, ui.text("Idle-wake helper active: " .. shown(wake.detail, "timed work pending")
			.. ". Tern does not run window timers while a window is untouched, so one short wait process at a time keeps this window observing."))
	elseif type(wake) == "table" and wake.state == "unavailable" then
		table.insert(rows, ui.text(ui.span("Idle-wake helper unavailable: " .. shown(wake.detail, "unknown reason")
			.. ". While this window is untouched, orchestration may pause until it is used again.", "error")))
	end
	if admitted then table.insert(rows, pause_link(view, policy)) end
	local chosen = nil
	for _, worker in flow.workers do if worker.worker_id == view.workflow_worker then chosen = worker end end
	chosen = chosen or flow.workers[1]
	local function page_controls(target: any, name: string, page: number, total: number, size: number)
		local last = math.max(0, math.ceil(total / size) - 1)
		table.insert(target, ui.text(tostring(total) .. " retained items · page " .. tostring(page + 1) .. "/" .. tostring(last + 1) .. " · display paging never discards pending evidence"))
		if page > 0 then table.insert(target, button(view, "Previous " .. name, { kind = "workflow-page", name = name, page = page - 1 })) end
		if page < last then table.insert(target, button(view, "Next " .. name, { kind = "workflow-page", name = name, page = page + 1 })) end
	end
	for _, worker in flow.workers do
		table.insert(ids, worker.worker_id)
		-- Fenced never-launched work only carries `withdrawal`: the exact request the window reads
		-- SPAWN status for before cancel_work. Only routed work carries `routing`; it is absent for
		-- explicit (unrouted) dispatch so its claim path is unchanged.
		-- held_reason and retirement_refused let the window pre-check Finish and name its refusal.
		local projected = if projection.dispatch.workers then projection.dispatch.workers[worker.worker_id] else nil
		machine("workflow-worker-" .. worker.worker_id, "orchplus.worker", pick(worker, WORKER_KEYS, {
			report_held = worker.rejected_report ~= nil, reattach_needed = worker.reattach_needed == true,
			receipt_unconfirmed = projected ~= nil and projected.accepted_seq > projected.compacted_floor,
			routing = if worker.routing then pick(worker.routing, "phase mode evidence_revision") else nil,
			review = if worker.review then pick(worker.review, "review_id round status findings_count reviewer_family") else nil,
			held_reason = if projected and projected.reason and worker.phase ~= "accepted" then pick(projected.reason, "code message") else nil,
			retirement_refused = projected ~= nil and projected.mailbox_status == "refused",
		}))
		local health = worker.health
		table.insert(rows, button(view, worker.work_id .. " · " .. health.status .. " · " .. health.freshness .. (if worker == chosen then " · selected" else ""),
			{ kind = "workflow-select", worker_id = worker.worker_id }))
		if worker ~= chosen then continue end
		local details = {
			ui.text(worker.work_id .. " / " .. worker.worker_id .. " · " .. health.status .. " · " .. health.freshness),
			ui.text(shown(health.reason, "No health reason recorded yet.")),
			ui.kv({ { "Native", shown(health.native_state, "unknown") }, { "Reported", shown(health.reported_state, "none") },
				{ "Latest native evidence", shown(health.latest_native, "none yet") }, { "Latest accepted report", shown(health.latest_report, "none yet") },
				{ "Durable native exit evidence", shown(health.latest_exit, "none (no exit observed)") },
				{ "Window", if health.awaiting_window then "Awaiting exact authorized window binding; use explicit reload continuation, never guessed pane adoption." else "Observation available" },
				{ "Report request", if worker.report_request_pending then "Pending worker response; not duplicated"
					elseif worker.report_loop and worker.report_loop.state == "stopped" then "Automatic requests stopped by the owner (loop cap); a new report from the worker resumes them"
					elseif worker.due_report then "Due; safe delivery required" else "Not due" },
				{ "Context", if worker.context_used_pct ~= nil then tostring(worker.context_used_pct) .. "% measured · report " .. shown(worker.context_seq, "unknown") else "Unknown — reliable context measurement is unavailable." },
				{ "Rollover threshold", if worker.context_rollover and worker.context_rollover.mode == "percentage" then
					tostring(worker.context_rollover.threshold_pct) .. "% override"
					else "Calculated default — first-turn context plus 55% of the remaining window" },
				{ "Rollover measurement", if worker.context_rollover then worker.context_rollover.status else "unknown" },
				{ "Orchestration", if worker.orchestration_excluded then "Excluded in Config — skipped by automatic reports and automatic rollover; not stopped" else "Eligible" } }),
		}
		if admitted then table.insert(details, dispatch_link(view, "associate_document", "Associate existing ruling document…", { worker_id = worker.worker_id })) end
		if (worker.wake_pending_count or 0) > 0 then
			table.insert(details, ui.text("Durably published notifications: " .. tostring(worker.wake_pending_count)
				.. " pending · " .. tostring(worker.wake_unstarted_count or 0) .. " not started (no native effect begun)"
				.. " · " .. tostring(worker.wake_uncertain_count or 0) .. " claimed/uncertain (remain occupied). Only fresh safe-idle workers are woken; publication is not consumption."))
		end
		-- D17: account-level USAGE delta (percent, account-wide); never a per-worker exact figure.
		if worker.usage_before ~= nil then
			local shared = if type(worker.usage_shared_with) == "number" then math.max(0, math.floor(worker.usage_shared_with)) else 0
			local scope = if shared > 0 then " — shared with " .. tostring(shared) .. " other worker" .. (if shared == 1 then "" else "s") .. " on this account" else " — account-wide, not this worker's exact use"
			if worker.usage_after == nil then
				table.insert(details, ui.text("Account delta while this worker ran" .. scope .. ": pending until the worker finishes."))
			else
				local delta = quota.usage_delta(worker.usage_before, worker.usage_after)
				if not delta.comparable then
					table.insert(details, ui.text("Account delta while this worker ran: not comparable (" .. (USAGE_WHY[delta.reason] or "unknown reason") .. ")."))
				else
					local parts = {}
					for i, w in delta.windows do
						if i > 8 then table.insert(parts, "…"); break end
						table.insert(parts, tostring(w.key) .. ": " .. (if w.delta ~= nil then (if w.delta >= 0 then "+" else "") .. tostring(w.delta) .. " pts used"
							else "not comparable (" .. (USAGE_WHY[w.reason] or "unknown reason") .. ")"))
					end
					table.insert(details, ui.text("Account delta while this worker ran" .. scope .. ": " .. table.concat(parts, " · ")))
				end
			end
		end
		-- Task 3B: role, declared family, review round/status, findings and Rule H proof status.
		do
			local review_required = flow.policy and flow.policy.require_code_review == true
			local enforce = review_required and flow.policy.require_other_family == true
			local review = worker.review
			local facts = { { "Role", shown(worker.role, "builder") },
				{ "Family", (if worker.family then tostring(worker.family) else "unknown") .. " (declared, not verified)" } }
			if worker.role == "reviewer" then table.insert(facts, { "Reviewing", shown(worker.review_id, "unbound") }) end
			if review then
				local cap = if flow.policy and flow.policy.review_rounds then " of " .. tostring(flow.policy.review_rounds) else ""
				table.insert(facts, { "Review", "round " .. tostring(review.round) .. cap .. " · " .. review.status
					.. (if review.reviewer_family then " · reviewer family " .. tostring(review.reviewer_family) .. " (declared)" else " · reviewer not chosen") })
				table.insert(facts, { "Latest findings", tostring(review.findings_count or 0) })
				if review.voided then table.insert(facts, { "Approval", "voided — a newer revision needs a fresh review" }) end
				if review.refusal then table.insert(facts, { "Refused result", tostring(review.refusal.code) .. ": " .. tostring(review.refusal.message) }) end
				if review.hold then table.insert(facts, { "Review held", tostring(review.hold.code) .. ": " .. tostring(review.hold.message) }) end
			end
			if worker.check_rework then
				table.insert(facts, { "Check rework", tostring(worker.check_rework.count) .. " · " .. tostring(worker.check_rework.state) })
			end
			if worker.role == nil or worker.role == "builder" then
				local total, passed = worker.checks_count or 0, 0
				local revision = worker.artifact_revision
				for _, r in worker.check_results or {} do
					if revision ~= nil and r.exit_code == 0 and r.head == revision then passed += 1 end
				end
				local checks = "checks " .. tostring(passed) .. "/" .. tostring(total) .. " helper-run" .. (if revision == nil and total > 0 then " · current artifact revision unconfirmed" else "")
				local status = if review and not review.voided then review.status else nil
				local proof = if not review_required then "Review disabled"
					elseif enforce then ENFORCED_PROOF[status] or "awaiting cross-family review"
					else PLAIN_PROOF[status] or "awaiting review"
				table.insert(facts, { "Review policy", proof })
				table.insert(facts, { "Mandatory checks", checks .. (if total == 0 then " — none declared (no fabricated evidence)"
					elseif passed == total then " — current evidence still subject to landing validation"
					else " — landing waits for every declared check; approval cannot override failures") })
			end
			table.insert(details, ui.kv(facts))
		end
		if admitted then
			table.insert(details, ui.row({ dispatch_link(view, "inspect_worker", "Inspect native facts", { worker_id = worker.worker_id }),
				dispatch_link(view, "open_worker", "Open exact relevant pane", { worker_id = worker.worker_id }) }))
		end
		if bound and worker.cleanup_ready then
			table.insert(details, dispatch_link(view, "poll", "Settle positively stopped worker mailbox…", { worker_id = worker.worker_id }))
			table.insert(details, ui.text("Cleanup only: fresh mailbox read/retirement under current admission, never reattach or launch the absent pane."))
		end
		-- Only a launched generation left without the continued route needs continuation; a
		-- never-launched or freshly launched worker has nothing to reattach.
		if bound and worker.pane_binding ~= nil and (worker.continuation_required or worker.reattach_needed) then
			table.insert(details, dispatch_link(view, "continue_worker", "Continue after reload / reattach explicitly…", { worker_id = worker.worker_id }))
			table.insert(details, ui.text("Continuation requires selecting the exact existing worker and independently verifying old executors stopped or retired. Pane numbers and titles are not identity proof. Pending decisions and uncertain outcomes remain retained."))
		end
		local rollover
		for _, candidate in flow.rollovers or {} do
			if worker.rollover and candidate.id == worker.rollover.id then rollover = candidate end
		end
		if rollover then
			table.insert(details, ui.text("Rollover " .. rollover.id .. " · " .. worker.rollover.role .. " · " .. rollover.phase .. " · trigger " .. rollover.trigger
				.. " · predecessor " .. rollover.predecessor_worker_id .. " · successor " .. tostring(rollover.successor_worker_id or "not granted")))
			table.insert(details, ui.text("Current handover revision " .. shown(rollover.revision, "unknown") .. " · " .. shown(rollover.updated_at, "time unavailable")))
			-- An owner-stopped checkpoint loop (loop_cap "Keep it stopped") offers no re-request.
			local checkpoint_stopped = rollover.checkpoint_loop ~= nil and rollover.checkpoint_loop.state == "stopped"
			if checkpoint_stopped then
				table.insert(details, ui.text(ui.span("Checkpoint re-requests stopped by the owner (loop cap). Cancel the rollover to end it.", "warning")))
			elseif rollover.hold then table.insert(details, ui.text(ui.span("Held: " .. rollover.hold.code .. " · " .. rollover.hold.message, "warning"))) end
			if rollover.checkpoint then
				table.insert(details, ui.text("Checkpoint " .. rollover.checkpoint.checkpoint_id .. " @ " .. rollover.checkpoint.artifact_revision
					.. " · checks " .. tern.json.encode(rollover.checkpoint.checks) .. " — worker-attested, not independent verification"))
			end
			if admitted and rollover.rerequestable and not checkpoint_stopped and worker.rollover.role == "predecessor" then
				table.insert(details, dispatch_link(view, "rollover", "Request the checkpoint again…", { worker_id = worker.worker_id }))
			end
			if admitted and (rollover.cancellable or rollover.close_without_successor) and worker.rollover.role == "predecessor" then
				table.insert(details, dispatch_link(view, "close_handover", "Close handover without successor…", { worker_id = worker.worker_id }))
				table.insert(details, ui.text("Only after predecessor retirement and before any successor effect may have begun. Otherwise use fenced recovery; no cancel/relaunch."))
			end
		end
		local rolling = rollover and rollover.phase ~= "complete" and rollover.phase ~= "cancelled"
		if worker.restored then
			table.insert(details, ui.text(ui.span("Retired coordinator observed alive again (" .. tostring(worker.restored.state) .. ") · "
				.. (if worker.restored.reconciled then "reconciled: " .. worker.restored.reconciled else "every coordinator effect is held; it is never counted as healthy"), if worker.restored.reconciled then "strong" else "error")))
			if admitted and not worker.restored.reconciled then
				table.insert(details, dispatch_link(view, "reconcile_restored", "I stopped this restored pane — confirm reconciliation…", { worker_id = worker.worker_id }))
			end
		end
		if admitted and not rolling and not worker.finish_requested and worker.phase == "accepted" and not worker.restored and health.status ~= "exited" then
			if worker.coordinator_owner_id then
				table.insert(details, dispatch_link(view, "rollover", "Roll over coordinator…", { worker_id = worker.worker_id }))
				table.insert(details, ui.text("Coordinator rollover asks for a verified checkpoint, quiesces through typed retirement, waits for the exact native stop and normal slot release, then reserves and starts a fresh successor. Two managed coordinators never overlap."))
			else
				table.insert(details, dispatch_link(view, "rollover", "Roll over worker…", { worker_id = worker.worker_id }))
				table.insert(details, ui.text("Rollover asks this worker for a verified checkpoint, starts a fresh successor from the same configured record, and stops this worker only after the successor accepts. A failure keeps this worker running."))
			end
		end
		table.insert(rows, ui.card("Worker health", details))
	end
	local gates = {}
	for _, gate in flow.gates do table.insert(gates, gate) end
	-- Open questions first, then settled history; each group in creation order (numeric gate serial).
	local function open_gate(gate: any): boolean return not GATE_SETTLED[gate.phase] end
	local function serial(gate: any): number return tonumber(gate.id:match("(%d+)$")) or 0 end
	table.sort(gates, function(a, b)
		if open_gate(a) ~= open_gate(b) then return open_gate(a) end
		return serial(a) < serial(b) or (serial(a) == serial(b) and a.id < b.id)
	end)
	for _, gate in gates do
		machine("workflow-gate-" .. gate.id, "orchplus.gate", pick(gate, "id revision worker_id worker_generation kind phase ruling decision_context source_request"))
		machine("workflow-gate-content-" .. gate.id, "orchplus.gate-content", pick(gate, "id revision worker_id worker_generation question options decision_context proposal", { version = 1 }), 65536)
		local fields = { gate_id = gate.id, gate_revision = gate.revision, worker_id = gate.worker_id, decision_context = gate.decision_context }
		local details = { ui.text(gate.id .. " / revision " .. tostring(gate.revision) .. " · " .. gate.kind .. " · " .. gate.phase),
			ui.text(gate.question), ui.text("Evidence: " .. shown(gate.evidence, "none supplied")) }
		if gate.ruling then
			table.insert(details, ui.text("Existing-document ruling: " .. gate.ruling.path .. " · " .. gate.ruling.state))
			table.insert(details, ui.text(gate.ruling.entry))
			if admitted then
				table.insert(details, ui.row({ dispatch_link(view, "ruling_write", "Record ruling in existing document…", fields),
					dispatch_link(view, "ruling_observe", "Reconcile ruling buffer and disk", fields),
					dispatch_link(view, "ruling_remote", "Record through existing authorized worker…", fields) }))
				if gate.ruling.intent then table.insert(details, dispatch_link(view, "ruling_reissue", "Inspect ended writer before enabling a new write", fields)) end
			end
		end
		for _, option in gate.options do table.insert(details, ui.text(option.id .. " · " .. option.label)) end
		if gate.answer then
			local source = gate.answer.source
			if type(source) == "table" and source.kind == "policy" then
				table.insert(details, ui.text(ui.span("Policy answer (" .. tostring(source.rule) .. ", policy " .. tostring(source.policy_revision):sub(1, 12) .. "), not yours: " .. tostring(gate.answer.choice_id), "warning")))
			elseif type(source) == "table" and source.kind == "refusal" then
				table.insert(details, ui.text(ui.span("Refused by ORCH+ (" .. tostring(source.code) .. "), not an owner answer: " .. shown(gate.answer.answer, tostring(gate.answer.choice_id)), "warning")))
			else
				table.insert(details, ui.text("Owner answer: " .. tern.json.encode(gate.answer)))
			end
		end
		if gate.execution then table.insert(details, ui.text("Execution: " .. gate.execution.state .. " · " .. gate.execution.effect_ref)) end
		if gate.kind == "deploy_hold" then
			local cause = if type(gate.evidence) == "table" and table.find(gate.evidence, "cause:failed") then "failed" else "held"
			table.insert(details, ui.text(ui.span(if cause == "failed"
				then "Deploy attempt failed: retry starts a new attempt for the same revision; stop ends the deploy. The release manager receives your decision; ORCH+ never deploys."
				else "The release manager held this deploy: proceed relays your go-ahead for the same revision; stop ends the deploy. ORCH+ never deploys.", "warning")))
		end
		if gate.delivery then table.insert(details, ui.text("Immutable delivery: " .. tern.json.encode(gate.delivery))) end
		if gate.delivery_uncertain then table.insert(details, ui.text("Possible delivery retained. Cancellation cannot retract bytes already published or consumed.")) end
		if admitted then
			if gate.kind ~= "quota_fallback" then
				table.insert(details, ui.row({ dispatch_link(view, "inspect_worker", "Inspect gate recipient", fields),
					dispatch_link(view, "open_worker", "Open relevant pane for owner action", fields) }))
			else
				table.insert(details, ui.text("Host-consumed routing decision for unlaunched work: no pane exists and nothing is delivered to a worker."))
			end
			if gate.phase == "pending" and gate.kind ~= "native_input" then
				table.insert(details, dispatch_link(view, "answer", "Answer exact question…", fields))
			end
			if open_gate(gate) then table.insert(details, dispatch_link(view, "cancel_gate", "Cancel this gate…", fields)) end
			table.insert(details, dispatch_link(view, "recheck_gate", if gate.kind == "native_input" then "I resolved this in the pane — recheck only" else "Recheck gate evidence", fields))
		end
		table.insert(rows, ui.card("Owner gate · " .. gate.work_id, details))
	end
	for _, thread in flow.threads do
		if not chosen or thread.work_id ~= chosen.work_id then continue end
		local entries = {}
		local thread_page = math.min(view.workflow_thread or 0, math.max(0, math.ceil(#thread.entries / 4) - 1))
		page_controls(entries, "thread", thread_page, #thread.entries, 4)
		-- Newest-first pages retain every unresolved item and expose older settled history explicitly.
		for index = #thread.entries - thread_page * 4, math.max(1, #thread.entries - thread_page * 4 - 3), -1 do
			local entry = thread.entries[index]
			table.insert(entries, ui.text(entry.id .. " · " .. entry.kind .. " · " .. shown(entry.at_ms, "time not recorded")
				.. " · " .. entry.state .. " · " .. entry.summary))
		end
		table.insert(rows, ui.card("Durable ORCH+ thread · " .. thread.work_id, entries))
	end
	-- Session-owned controls show their positions in the shared canonical repository/target queue.
	-- Repository-side queues retain exact grant outcomes without taking a competing local slot.
	for _, queue in flow.landing or {} do
		local external = queue.repository and queue.repository.queue_route == "repository_queue"
		machine("workflow-repository-" .. queue.id, "orchplus.repository", { queue_id = queue.id, identity = queue.repository,
			slot = queue.repository_slot, first = queue.repository_first, count = queue.repository_count })
		local entries = { ui.text(queue.repo_ref .. " · " .. queue.target_ref .. " · project " .. queue.project_id
			.. " · head " .. (if queue.head then queue.head.revision .. " (" .. queue.head.source .. ")" else "unknown until a recorded result")
			.. (if external then " · repository_queue · no local slot" else " · local slot " .. (queue.repository_slot or queue.slot or "free"))) }
		if queue.repository then
			table.insert(entries, ui.text("Verified " .. queue.repository.host_key .. ":" .. queue.repository.common_dir .. " · " .. queue.repository.target_ref
				.. " · " .. tostring(queue.repository_count or #queue.items) .. " outstanding across local sessions."
				.. " Coordination covers this authority/data directory, not other machines or unmanaged agents."))
		else
			table.insert(entries, ui.text(ui.span("Pre-cutover request without verified repository identity: settle its existing grant, or cancel and submit a fresh checkout-backed request. No automatic replay.", "warning")))
		end
		for _, item in queue.items do
			machine("workflow-landing-" .. item.id, "orchplus.landing",
				pick(item, "id revision status worker_id uncertain cancellable move_up move_down markable_lost reconcilable", { queue_id = queue.id }))
			machine("workflow-landing-roles-" .. item.id, "orchplus.landing-roles", pick(item, "id builder reviewer holder release_manager deploy_due", {
				deploy = if item.deploy then pick(item.deploy, "deploy_id status revision attempts gate_id retry markable_lost reconcilable") else nil }))
			local r, grant = item.request, item.grant
			-- A refresh (target moved, or a grant released without landing) voids the review approval:
			-- the rebased revision needs a fresh review and LANDING_REQUEST before any new approval.
			local hold_code = if item.hold then item.hold.code else nil
			local void = item.refresh_required or (item.approved and (hold_code == "refresh_required" or hold_code == "target_moved"))
			table.insert(entries, ui.text((if item.position then "#" .. tostring(item.repository_position or item.position) .. " " else "") .. item.id .. " · " .. item.status .. " · " .. item.work_id
				.. " · " .. r.source_ref .. "@" .. r.source_revision .. " → expects " .. r.target_revision
				.. (if void then " · approval void — awaiting fresh review/request"
					elseif item.approved then " · owner approved" elseif item.gate_id then " · approval gate " .. item.gate_id else "")))
			if item.hold then
				table.insert(entries, ui.text(ui.span(item.hold.code .. " · " .. item.hold.message, if item.status == "blocked" then "warning" else "info")))
			end
			local b, rv, rm = item.builder, item.reviewer, item.release_manager
			table.insert(entries, ui.text("Builder " .. (if b then shown(b.worker_id, "unknown") .. " (" .. shown(b.record_id, "record unknown") .. ", " .. shown(b.family, "family unknown") .. ")" else shown(item.worker_id, "unknown"))
				.. " · reviewer " .. (if rv then shown(rv.worker_id, "unknown") .. " (" .. shown(rv.record_id, "record unknown") .. ", declared family " .. shown(rv.family, "unknown") .. ")" else "none yet")
				.. " · release manager " .. (if rm then shown(rm.worker_id, "unknown") .. " (" .. shown(rm.record_id, "record unknown") .. ", " .. shown(rm.phase, "unknown") .. ")" else "none")))
			if grant then
				table.insert(entries, ui.text("Grant " .. grant.grant_id .. " · expects head " .. grant.target_revision .. " · "
					.. (if grant.acknowledged then "consumed by worker" elseif grant.published then "published, awaiting worker ACK" else "issued")
					.. (if grant.result then " · worker result " .. grant.result.outcome .. (if grant.result.result_revision then " → " .. grant.result.result_revision else "") else "")
					.. (if grant.reconciliation then " · owner reconciled " .. grant.reconciliation.outcome else "")))
				if item.uncertain then
					table.insert(entries, ui.text(ui.span("Slot held · " .. grant.uncertain.code .. " · " .. grant.uncertain.message, "error")))
				end
				if grant.late_result then table.insert(entries, ui.text("Late worker result kept as evidence only: " .. grant.late_result.outcome)) end
			end
			local dep = item.deploy
			if dep then
				local cur = dep.current
				table.insert(entries, ui.text("Deploy " .. dep.deploy_id .. " · " .. dep.status .. " · revision " .. shown(dep.revision, "unknown")
					.. " · attempts " .. shown(dep.attempts, "0")
					.. (if cur then " · attempt " .. cur.attempt_id .. " " .. cur.status
						.. (if cur.acknowledged then " (consumed by release manager)" elseif cur.published then " (published, awaiting ACK)" else "")
						.. (if cur.reconciliation then " · owner reconciled " .. shown(cur.reconciliation.outcome, "unknown") else "") else "")
					.. (if dep.gate_id then " · gate " .. dep.gate_id else "")
					.. (if dep.retry then " · new attempt pending" else "")))
				if dep.hold then
					table.insert(entries, ui.text(ui.span(dep.hold.code .. " · " .. dep.hold.message, if dep.status == "held" or dep.status == "failed" or dep.status == "uncertain" then "warning" else "info")))
				end
				if cur and cur.uncertain then table.insert(entries, ui.text(ui.span("Deploy uncertain · " .. shown(cur.uncertain.code, "") .. " · " .. shown(cur.uncertain.message, ""), "error"))) end
			elseif item.deploy_due then
				table.insert(entries, ui.text("Deploy due: a deploy grant for this landed revision goes to the release manager next."))
			end
			local fields = { landing_id = item.id, landing_revision = item.revision }
			if admitted and dep and (dep.markable_lost or dep.reconcilable) then
				local controls = {}
				if dep.markable_lost then table.insert(controls, dispatch_link(view, "landing_lost", "Deploy result lost — hold…", fields)) end
				if dep.reconcilable then table.insert(controls, dispatch_link(view, "reconcile_landing", "Reconcile observed deploy…", fields)) end
				table.insert(entries, ui.row(controls))
			end
			if admitted and item.position then
				local controls = {}
				if item.move_up then table.insert(controls, dispatch_link(view, "move_landing", "Move up", { landing_id = item.id, landing_revision = item.revision, direction = "up" })) end
				if item.move_down then table.insert(controls, dispatch_link(view, "move_landing", "Move down", { landing_id = item.id, landing_revision = item.revision, direction = "down" })) end
				if item.cancellable then table.insert(controls, dispatch_link(view, "cancel_landing",
					if item.status == "landed" and item.deploy and item.deploy.status == "pending" and item.deploy.attempts == 0 then "Stop pending deployment" else "Cancel…", fields)) end
				if item.markable_lost then table.insert(controls, dispatch_link(view, "landing_lost", "Result lost — hold slot…", fields)) end
				if item.reconcilable then table.insert(controls, dispatch_link(view, "reconcile_landing", "Reconcile observed outcome…", fields)) end
				if #controls > 0 then table.insert(entries, ui.row(controls)) end
			end
		end
		table.insert(entries, ui.text("The release manager performs the repository's approved merge and deploy workflow; ORCH+ never runs git or deploys and never infers landing from REVIEW_READY, DONE or a closed pane."))
		table.insert(rows, ui.card("Landing queue · " .. queue.target_ref, entries))
	end
	-- A checkpoint is never split across arbitrary pages. Large plans disclose real groups.
	local plan_ids = {}
	for _, plan in flow.plans or {} do
		table.insert(plan_ids, plan.plan_id)
		local count = 0
		for _, cp in plan.checkpoints do count += #cp.tasks end
		local entries = {}
		for _, cp in plan.checkpoints do
			local tasks = {}
			for _, task in cp.tasks do
				table.insert(tasks, ui.text(task.title .. " · " .. (TASK_STATUS[task.state] or "Status unavailable")
					.. (if task.hold then " — " .. tostring(task.hold.message or "See Advanced for details.") else "")))
			end
			local group = ui.card(cp.title .. " · " .. tostring(#cp.tasks) .. (if #cp.tasks == 1 then " task" else " tasks"), tasks)
			group.p.collapsible = count > 100
			group.p.collapsed = count > 100
			table.insert(entries, group)
		end
		table.insert(rows, ui.card(plan.title, entries))
		machine("workflow-plan-" .. plan.plan_id, "orchplus.plan", plan, 65536)
	end
	machine("project-index", "orchplus.projects", { version = 5, projects = projection.dispatch.projects or {},
		finished_projects = projection.dispatch.finished_projects or projection.finished_projects or {} }, 65536)
	local source_requests = {}
	for _, gate in flow.gates or {} do
		if gate.source_request then table.insert(source_requests, { gate_id = gate.id, gate_revision = gate.revision }) end
	end
	machine("workflow-index", "orchplus.workflow", { policy = policy, policy_revision = flow.policy_revision, policy_sha256 = flow.policy_sha256,
		worker_ids = ids, plan_ids = plan_ids, source_requests = source_requests,
		family_migrations = flow.family_migrations, family_migration_scope = flow.family_migration_scope,
		class_choices = require("./source_adapter").class_choices(flow.plans or {}, policy.templates),
		cleanup_notice_date = flow.cleanup_notice_date,
		sweep_last_date = if type(flow.sweep) == "table" then flow.sweep.last_date else nil }, 65536)
	local readiness_landings = {}
	for _, queue in flow.landing or {} do
		for _, item in queue.items do table.insert(readiness_landings, { worker_id = item.worker_id, status = item.status, repo_ref = queue.repo_ref }) end
	end
	machine("readiness-index", "orchplus.readiness", { catalog = if projection.dispatch then projection.dispatch.catalog else nil, landings = readiness_landings }, 65536)
	-- Window contract for work sources (Contract K): newest intakes and the desired lane of each mapped board card.
	machine("workflow-intake", "orchplus.intake", { intakes = flow.intakes or {}, board = flow.board or {} }, 65536)
	table.insert(rows, ui.text(ui.span("Nightly mailbox sweep" .. (if policy.sweep_enabled then " at " .. shown(policy.sweep_time, "03:00") .. " local time" else " (off in Config)"), "strong")))
	for _, row in sweep_rows(flow.sweep, 8) do table.insert(rows, row) end
	-- Window contract for the USAGE capacity reader: catalog join, candidate records (pending
	-- routed work first, then the allowlist, then other eligible records), evidence lease and
	-- routed launches that need a fresh USAGE `validate` before their claim.
	-- Candidates for capacity reads come from the assembled roster, never from the last page read.
	local catalog = if projection.dispatch then (projection.dispatch.roster or projection.dispatch.catalog) else nil
	local now = math.floor(os.time() * 1000)
	local routed, pending, priority = {}, false, {}
	for _, worker in flow.workers do
		local r = worker.routing
		if r and (worker.phase == "queued" or worker.phase == "provisioned") then
			table.insert(routed, pick(r, "phase mode evidence_revision auth_revision", { worker_id = worker.worker_id, launch_action_id = worker.launch_action_id }))
			if r.phase ~= "selected" or r.policy_digest ~= quota.policy_digest(policy) then pending = true end
			priority[r.requested.id] = 0
			if r.selected then priority[r.selected.id] = 0 end
		end
	end
	-- Rollovers waiting for their successor grant need fresh evidence for the predecessor's record.
	for _, rollover in flow.rollovers or {} do
		if rollover.phase == (if rollover.kind == "coordinator" then "owner_retired" else "checkpoint_verified") then
			pending = true
			local pred = if projection.dispatch and projection.dispatch.workers then projection.dispatch.workers[rollover.predecessor_worker_id] else nil
			if pred then priority[pred.record_id] = 0 end
		end
	end
	for _, scope in quota.SCOPES do
		for _, record_id in policy[scope .. "_records"] or {} do priority[record_id] = priority[record_id] or 1 end
	end
	local records = {}
	if catalog and catalog.namespace then
		local ordered = enabled_records(catalog)
		table.sort(ordered, function(a, b)
			local pa, pb = priority[a.id] or 2, priority[b.id] or 2
			return pa < pb or (pa == pb and a.id < b.id)
		end)
		for index = 1, math.min(#ordered, quota.MAX_RECORDS) do table.insert(records, { id = ordered[index].id, revision = ordered[index].revision }) end
	end
	local evidence = flow.capacity
	machine("routing-index", "orchplus.routing", { version = 1, quota_routing = policy.quota_routing,
		namespace = if catalog then catalog.namespace else nil, host_key = if catalog then catalog.host_key else nil,
		config_revision = if catalog then catalog.config_revision else nil, records = records,
		evidence = if evidence then pick(evidence, "revision auth_revision expires_at_ms") else nil,
		refresh_due = policy.quota_routing and catalog ~= nil and catalog.namespace ~= nil and (evidence == nil or evidence.expires_at_ms <= now + 15000 or pending),
		workers = routed }, 65536)
	-- Config pickers retain page identity and availability even when filtering leaves no choices:
	-- the node describes the page just read, and `total` counts the assembled roster.
	local page = if projection.dispatch then projection.dispatch.catalog else nil
	local listed = {}
	for _, record in enabled_records(page) do table.insert(listed, pick(record, "id revision provider account_label capabilities cwd placement backend label eligible enabled definition_revision")) end
	machine("catalog-index", "orchplus.catalog", { version = 1, loaded = page ~= nil, catalog_complete = projection.dispatch.catalog_complete == true,
		namespace = if page then page.namespace else nil, host_key = if page then page.host_key else nil,
		config_revision = if page then page.config_revision else nil, revision = if page then page.revision else nil,
		catalog_version = if page then page.catalog_version else nil, setup = if page then page.setup else nil,
		next_cursor = if page then page.next_cursor else nil, total = if catalog then #catalog.records else 0,
		records = listed }, 65536)
	return ui.card("Health, owner inbox and durable threads", rows), nodes
end
local function conversation_row(provider: string, link: any): any
	local icon = provider_display.icon(provider)
	local label = link.p.text
	link.p.text = nil
	link.c = { ui.node("text", { text = label, truncate = "end", title = label, min = { w = 0 } }) }
	return ui.row(if icon then { ui.node("icon", { name = icon, shrink = 0 }), link } else { link })
end

local function project_panel(view: any, projection: any, selected: any): any
	local d = projection.dispatch or {}
	local flow = d.workflow or { workers = {}, gates = {}, plans = {}, policy = {} }
	local _, _, admitted = controller(view, selected)
	local rows = { ui.text(ui.span(selected.name, "strong")) }
	local creation, completion = view.orchestration_result, view.conversation_result
	local current_creation = creation and creation.ok == true and creation.orch_session_id == selected.orch_session_id
		and type(creation.request_id) == "string"
	local ready = view.creation_ready
	local creation_pending = current_creation and not (ready and ready.source_nonce == view.alias_nonce
		and ready.orch_session_id == selected.orch_session_id and ready.creation_request_id == creation.request_id)
	if creation_pending and completion and completion.source_nonce == view.alias_nonce
		and completion.orch_session_id == selected.orch_session_id and completion.creation_request_id == creation.request_id
		and type(completion.result) == "table"
		and completion.result.command == "new_project" and type(completion.result.request_id) == "string"
		and type(completion.result.ok) == "boolean" then
		-- This is only presentation readiness, not execution authority. Retain its source
		-- and creation token so later unrelated results cannot re-hide established controls.
		view.creation_ready = { source_nonce = view.alias_nonce, orch_session_id = selected.orch_session_id,
			creation_request_id = creation.request_id, project_request_id = completion.result.request_id }
		creation_pending = false
	end
	local coordinator_pending = false
	for _, worker in flow.workers do
		local lifecycle = d.workers and d.workers[worker.worker_id]
		if worker.role == "coordinator" and (not lifecycle or lifecycle.mailbox_status ~= "retired") then coordinator_pending = true; break end
	end
	local connection_held = view.spawn_relay and (view.spawn_relay.held or view.spawn_relay.error)
	local uncertain_starts = {}
	for _, action in d.actions or {} do
		local op = action.request.op
		if action.phase == "uncertain" and action.worker_id and (op == "launch" or op == "adopt" or op == "enrol" or op == "mailbox_provision") then
			uncertain_starts[action.worker_id] = true
		end
	end
	if connection_held or next(uncertain_starts) then
		local recovery = { ui.text(ui.span(if next(uncertain_starts) then "An agent session's startup is not confirmed."
			else "The agent connection needs attention.", "error")),
			ui.text("Existing sessions will not be restarted. Open Advanced to check the retained outcome.") }
		table.insert(rows, ui.card("Check agent connection", recovery))
	end
	if flow.policy.paused then table.insert(rows, ui.text(ui.span("Paused — new work waits. You can still discuss and add projects.", "warning"))) end
	if admitted and creation_pending then
		table.insert(rows, ui.text("Finishing orchestration setup. No agent has started."))
	end
	if admitted and not creation_pending then
		if selected.orchestrator == nil and not coordinator_pending then
			table.insert(rows, ui.col({ dispatch_link(view, "start_orchestrator", "Start orchestrator pane"),
				ui.text("Discuss your goals before starting project work.") }))
		end
		table.insert(rows, ui.col({ dispatch_link(view, "new_conversation", "New Agent Session"), ui.text("Open one new agent pane.") }))
		table.insert(rows, ui.col({ dispatch_link(view, "attach_conversation", "Attach Existing Agent Session"),
			ui.text("Keep its current conversation. Attaching does not start project work.") }))
		if flow.policy.glitch_integration and flow.policy.work_on_enabled then
			table.insert(rows, ui.col({ dispatch_link(view, "work-on", "WORK ON"), ui.text("Choose a Glitch project or plan in WORK.") }))
		end
		table.insert(rows, ui.row({ pause_link(view, flow.policy), dispatch_link(view, "orchestration_menu", "Orchestration menu") }))
	end
	local catalog, pane_titles, native_titles, native_workers, workers = {}, {}, {}, {}, {}
	for _, record in (if d.roster then d.roster.records elseif d.catalog then d.catalog.records else {}) do catalog[record.id] = record end
	for _, pane in (if view.session_panes then view.session_panes.panes else {}) do
		local title = if pane.title ~= "" then pane.title else nil
		native_titles[tostring(pane.pane)] = title
		if pane.worker_id then pane_titles[pane.worker_id], native_workers[pane.worker_id] = title, pane end
	end
	for _, worker in flow.workers do workers[worker.worker_id] = worker end
	local projects = {}
	for _, project in d.projects or {} do if not project.finished then table.insert(projects, project) end end
	table.sort(projects, function(a, b) return a.orch_project_id < b.orch_project_id end)
	for _, project in projects do
		local selected_project = view.orch_project_id == project.orch_project_id or (view.orch_project_id == nil and projects[1] == project)
		local start = project.start
		local pending_start = start ~= nil and start.state ~= "claimed" and not start.restartable
		local children = { ui.row({
			button(view, project.name, { kind = "project-select", orch_project_id = project.orch_project_id }),
			if project.status == "ACTIVE" then ui.text(ui.span("ACTIVE", "success"))
				elseif pending_start then ui.text(ui.span(if start.state == "failed" then "Needs attention" else "Waiting to start", if start.state == "failed" then "warning" else "info"))
				else dispatch_link(view, "project_start", "START", { orch_project_id = project.orch_project_id,
					project_revision = project.revision, decision_context = project.decision_context }),
			dispatch_link(view, "project_menu", "…", { orch_project_id = project.orch_project_id }),
		}) }
		if selected_project and start then
			if start.source and start.source.kind == "policy" then table.insert(children, ui.text("Automatic start is on for this source.")) end
			local states = { publishing = "Sending START to your orchestrator. New work is still on hold.",
				queued = "Waiting for your orchestrator to start the new work.",
				delivered = "Waiting for your orchestrator to begin.",
				claimed = "Your orchestrator has started the approved work.",
				failed = "Could not start the new work. It is still on hold." }
			local status = ui.text(if start.state == "failed" then ui.span(
				if start.restartable then "The project or orchestrator changed. Review this project and choose START again." else states.failed, "error")
				else states[start.state] or "Check START before trying again.")
			status.p.key = "project-start-status-" .. project.orch_project_id; status.p.role = "orchplus.project.start"
			status.p.state = start.state; status.p.source = if start.source then start.source.kind else nil
			status.p.restartable = start.restartable == true
			table.insert(children, status)
			if start.failure then
				if view.advanced_open then table.insert(children, ui.text(start.failure.message))
				elseif start.failure.code == "start_publication_uncertain" then table.insert(children, ui.text("We could not confirm that START was sent. Check its status before trying again.")) end
			end
			if pending_start then
				table.insert(children, dispatch_link(view, "project_start_retry",
					if start.failure and start.failure.retryable then "Try sending START again" else "Check START",
					{ orch_project_id = project.orch_project_id, start_id = start.start_id, project_revision = start.project_revision,
						decision_context = start.decision_context }))
			elseif start.restartable then
				table.insert(children, dispatch_link(view, "project_start", "Review and START", { orch_project_id = project.orch_project_id,
					project_revision = project.revision, decision_context = project.decision_context }))
			end
		end
		local conversations = {}
		if selected_project and project.paused and project.started then table.insert(children, ui.text("Waiting for orchestration to resume.")) end
		for _, worker_id in project.members or {} do
			local worker = workers[worker_id]
			if not worker then continue end
			local record = catalog[worker.record_id] or {}
			local provider = worker.provider or record.provider or "Agent"
			local account = worker.account_label or record.account_label or "account unknown"
			local title = pane_titles[worker_id]
			local observed = native_workers[worker_id]
			local ended = (worker.health and worker.health.latest_exit ~= nil) or (observed and observed.state == "exited")
			local pending_title = if ended then "Agent pane ended"
				elseif connection_held or uncertain_starts[worker_id] then "Startup not confirmed"
				elseif worker.phase == "held" then "Needs attention"
				elseif worker.phase == "accepted" then "Agent session unavailable"
				elseif flow.policy.paused or worker.project_held then "Queued — not started"
				elseif worker.phase == "awaiting_acceptance" then "Waiting to join" else "Agent session queued"
			local label = provider_display.name(provider) .. " · " .. account .. " — " .. (title or pending_title)
			table.insert(conversations, conversation_row(provider,
				if worker.pane_binding or worker.launch_pane_binding then dispatch_link(view, "open_worker", label, { worker_id = worker_id })
				else ui.text(label)))
			if selected_project and ended then
				table.insert(conversations, ui.text(ui.span("Agent pane ended"
					.. (if observed and observed.exit_code ~= nil then " (exit " .. tostring(observed.exit_code) .. ")" else "")
					.. ". Its launch and any unread messages remain retained.", if observed and observed.exit_code == 0 then "info" else "error")))
				table.insert(conversations, dispatch_link(view, "inspect_worker", "Check agent status", { worker_id = worker_id }))
			elseif selected_project and worker.phase ~= "accepted" and not connection_held and not uncertain_starts[worker_id] then
				local held = (d.workers or {})[worker_id]
				if held and held.reason then table.insert(conversations, ui.text(tostring(held.reason.message)))
				elseif worker.phase == "awaiting_acceptance" then
					table.insert(conversations, ui.text("The pane opened, but the agent has not joined yet."))
					table.insert(conversations, dispatch_link(view, "inspect_worker", "Check agent status", { worker_id = worker_id }))
				elseif title then table.insert(conversations, ui.text("Agent startup is pending.")) end
			end
		end
		for id, association in project.associations or {} do
			local observed = view.session_panes
			local binding = association.pane_binding
			local same_native = observed and binding and observed.window_epoch == binding.window_epoch
				and observed.native_session_id == binding.native_session_id and observed.window_host_id == binding.window_host_id
			local title = if same_native then native_titles[binding.pane_id] else nil
			local provider = association.provider or "Agent"
			table.insert(conversations, conversation_row(provider, dispatch_link(view, "association_menu",
				provider_display.name(provider) .. " · " .. (association.account_label or "account unknown") .. " — " .. (title or "Conversation unavailable"),
				{ orch_project_id = project.orch_project_id, conversation_id = id })))
		end
		if #conversations > 0 then
			table.insert(children, ui.el("div", { class = "orch-project-conversations" }, { ui.col(conversations) }))
		end
		if selected_project then
			for _, plan in flow.plans or {} do
				if plan.orch_project_id ~= project.orch_project_id then continue end
				local count = 0
				for _, cp in plan.checkpoints do count += #cp.tasks end
				table.insert(children, ui.row({ ui.text(ui.span(plan.title or plan.plan_id, "strong")),
					dispatch_link(view, "open_plan", "Open plan", { plan_id = plan.plan_id, orch_project_id = project.orch_project_id }) }))
				for _, cp in plan.checkpoints do
					local tasks = {}
					for _, task in cp.tasks do table.insert(tasks, ui.text(task.title .. " · " .. (TASK_STATUS[task.state] or "Status unavailable")
						.. (if task.hold then " — " .. tostring(task.hold.message or "See Advanced for details.") else ""))) end
					local group = ui.card(cp.title .. " · " .. tostring(#cp.tasks) .. (if #cp.tasks == 1 then " task" else " tasks"), tasks)
					group.p.collapsible, group.p.collapsed = count > 100, count > 100
					table.insert(children, group)
				end
			end
		end
		table.insert(rows, ui.el("div", { class = "orch-project" }, { ui.col(children) }))
	end
	if #projects == 0 then table.insert(rows, ui.text("Add an agent session or discuss a project with your orchestrator. Use a project's START action when its work is ready.")) end
	for _, gate in flow.gates do
		if gate.source_request then
			table.insert(rows, dispatch_link(view, "source-proposal", "Read approved board source", { gate_id = gate.id, gate_revision = gate.revision }))
			continue
		end
		if gate.phase ~= "pending" then continue end
		local question = { ui.text(gate.question) }
		for _, option in gate.options do table.insert(question, ui.text(option.label)) end
		if admitted then table.insert(question, dispatch_link(view, if gate.kind == "native_input" then "open_worker" else "answer", if gate.kind == "native_input" then "Open conversation" else "Review decision…", {
			gate_id = gate.id, gate_revision = gate.revision, worker_id = gate.worker_id, decision_context = gate.decision_context })) end
		table.insert(rows, ui.card("Your decision", question))
	end
	local finished = d.finished_projects or projection.finished_projects or {}
	if #finished > 0 then
		table.insert(rows, button(view, "Finished projects (" .. tostring(#finished) .. ")", { kind = "finished-toggle" }))
		if view.finished_open then
			for index, summary in finished do
				local details = { ui.text(summary.result) }
				for _, link in summary.links or {} do table.insert(details, dispatch_link(view, "summary_link", link.label, { summary_index = index, link = link })) end
				table.insert(details, dispatch_link(view, "project_reopen", "Reopen as new project", { summary_index = index }))
				table.insert(rows, ui.card(summary.name, details))
			end
			table.insert(rows, ui.text("Recent summaries are retained independently of open orchestrations, up to 100. Conversation links work only while the native conversation remains available."))
		end
	end
	local panel = ui.col(rows)
	panel.p.role = "orchplus-project-list"
	return panel
end
function M.render(view: any, projection: any, status: string, diagnostic: string?): any
	-- Keep the previous current map only while rebuilding; no retired control history survives.
	view.action_previous = if view.action_incarnation == view.alias_nonce and view.action_order ~= nil
		then { actions = view.actions, order = view.action_order, navigation = view.navigation_actions or {} } else nil
	view.actions, view.action_order, view.navigation_actions = {}, {}, {}
	view.action_incarnation = view.alias_nonce
	view.authority_namespace = if projection then projection.authority_namespace elseif view.migration then view.migration.authority_namespace else nil
	view.authority_revision = if projection then projection.revision elseif view.migration then view.migration.authority_revision else nil
	local selected = nil
	for _, session in (if projection then projection.sessions or {} else {}) do
		if session.orch_session_id == view.orch_session_id then selected = session; break end
	end
	local owner = if selected then selected.controller else nil
	local flow = if projection and projection.dispatch then projection.dispatch.workflow else nil
	view.navigation_scope = {
		controller = if owner then pick(owner, "owner_id generation phase pane_binding") else nil,
		policy_revision = if flow then flow.policy_revision else nil,
		policy_sha256 = if flow then flow.policy_sha256 else nil,
	}
	local rows = { ui.text(ui.span("ORCHESTRATED WORK", "strong")) }
	for _, peer in { "spawn", "usage" } do
		local relay = view[peer .. "_relay"]
		if relay then
			table.insert(rows, keyed(tern.json.encode(relay), "orchplus-" .. peer .. "-relay", "orchplus." .. peer .. "-relay"))
			if (peer ~= "spawn" or view.advanced_open) and (relay.held or relay.error) then
				table.insert(rows, ui.text(ui.span((if peer == "spawn" then "Agent connection" else "Usage connection")
					.. " needs attention: " .. tostring(relay.error or "unavailable"):gsub("_", " ") .. ". Existing work remains held.", "warning")))
			end
		end
	end
	for lane_id, frames in view.spawn_relay_frames or {} do
		for kind, bytes in frames do table.insert(rows, keyed(bytes, "spawn-relay-" .. lane_id .. "-" .. kind, "orchplus.spawn-" .. kind)) end
	end
	for kind, bytes in view.usage_relay_frames or {} do
		table.insert(rows, keyed(bytes, "usage-relay-" .. kind .. "-response", "orchplus.usage-" .. kind .. "-response"))
	end
	if view.source_discovery then table.insert(rows, keyed(tern.json.encode(view.source_discovery), "source-discovery", "orchplus.sources")) end
	if view.inbox_observation then table.insert(rows, keyed(tern.json.encode(view.inbox_observation), "inbox-observation", "orchplus.inbox")) end
	if view.decision_context_result then table.insert(rows, keyed(tern.json.encode(view.decision_context_result), "decision-context-result", "orchplus.decision")) end
	if view.orchestration_result then table.insert(rows, keyed(tern.json.encode(view.orchestration_result), "orchestration-result", "orchplus.orchestration.result")) end
	if view.conversation_result then
		local bytes = tern.json.encode(view.conversation_result)
		if #bytes <= 65536 then table.insert(rows, keyed(bytes, "conversation-result", "orchplus.conversation.result")) end
	end
	if view.migration then
		local migration = view.migration
		local bytes = tern.json.encode(migration)
		if #bytes <= 65536 then table.insert(rows, keyed(bytes, "migration-state", "orchplus.migration"))
		else table.insert(rows, ui.text(ui.span("Compact migration evidence exceeds 65536 bytes; pairing remains blocked.", "error"))) end
		if view.advanced_open and (migration.phase ~= "stable" or migration.compatibility == nil or migration.compatibility.kind ~= "current") then
			table.insert(rows, ui.card("Connection needs attention", {
				ui.text("The automatic compatible update could not finish. Review retained connection evidence; existing work and uncertain effects stay held."),
				button(view, "Inspect compatible update", { kind = "setup-intent", command = "migration_update", source_sha256 = migration.source_sha256 }),
			}))
		end
	end
	if view.ruling_result then
		local bytes = tern.json.encode(view.ruling_result)
		if #bytes <= 65536 then table.insert(rows, keyed(bytes, "ruling-result", "orchplus.ruling.result")) end
	end
	if status == "ready" and projection.setup and projection.installation_defaults then
		local setup, defaults = projection.setup, projection.installation_defaults
		local function control(label: string, command: string): any
			return button(view, label, { kind = "setup-intent", command = command }, { ["data-orchplus-setup"] = command })
		end
		if view.config_open then
			table.insert(rows, ui.card("Settings", {
				ui.text("Reusable defaults apply only to new orchestrations. Projects keep their own repository and target; text and research need neither."),
				control(if defaults.defined == true then "Edit Default Settings" else "Define Default Settings", "defaults"),
				control("Open SPAWN", "spawn"),
				button(view, "Back to work", { kind = "config-close" }),
			}))
		end
		if view.setup_result and view.setup_result.ok == false then
			table.insert(rows, ui.text(ui.span(if view.advanced_open then "Setup refused: " .. tostring(view.setup_result.message or view.setup_result.code)
				else "Setup could not be completed. Check the open settings or agent setup screen.", "error")))
		end
		table.insert(rows, keyed(tern.json.encode({ version = 1, source_nonce = view.alias_nonce, host_pane_id = tostring(view.pane),
			authority_namespace = projection.authority_namespace, authority_revision = projection.revision,
			setup = setup, installation_defaults = defaults, setup_result = view.setup_result, setup_repository = view.setup_repository }), "setup-index", "orchplus.setup"))
	end
	if view.setup_catalog_request then table.insert(rows, keyed(tern.json.encode(view.setup_catalog_request), "setup-catalog-request", "orchplus.setup.request")) end
	if diagnostic ~= nil and view.advanced_open then table.insert(rows, ui.text(ui.span(diagnostic, "error"))) end
	local result = view.dispatch_command_result
	local notice = view.notice
	local explicit = if type(notice) == "table" then notice else nil
	local notice_message = if explicit then explicit.message else notice
	local catalog_notice = explicit and explicit.context == "catalog"
	local superseded = explicit and result and (result.message == notice_message
		or (catalog_notice and (result.command == "catalog" or result.code == "catalog_queued" or result.code == "catalog_requested")))
	if result and (not superseded or view.advanced_open) and (result.code ~= "task_queued" or view.advanced_open) then
		local message = if view.advanced_open or result.code == "cleanup_summary" then result.message or STATUS_MESSAGES[result.code]
			else STATUS_MESSAGES[result.code] or (if result.ok and not ERROR_RESULTS[result.code] then "Action recorded."
				else "The action could not be completed. Open Advanced to check its retained status.")
		local level = if not result.ok or ERROR_RESULTS[result.code] then "error"
			elseif SAVED_RESULTS[result.code] then "success" else "info"
		message = tostring(message or (if result.ok then "Action recorded." else "The action could not be completed."))
		table.insert(rows, ui.text(if level == "info" then message else ui.span(message, level)))
	end
	if notice_message ~= nil and (view.advanced_open or notice_message ~= "task_queued")
		and (explicit or result == nil or notice_message ~= result.message) then
		local message = if explicit then notice_message else STATUS_MESSAGES[notice_message] or notice_message
		local level = if explicit then explicit.level elseif ERROR_RESULTS[notice_message] then "error" else "info"
		table.insert(rows, ui.text(if level == "info" then message else ui.span(message, level)))
		if explicit and view.advanced_open and explicit.detail then table.insert(rows, ui.text(explicit.detail)) end
		if catalog_notice and explicit.code == "catalog_unconfirmed" and selected then
			local _, bound = controller(view, selected)
			if bound then
				local action = if projection.dispatch then projection.dispatch.actions[view.dispatch_action] else nil
				local target = if action and action.request.op == "catalog" then action.request.action_id else nil
				table.insert(rows, dispatch_link(view, "check_connection", "Check connection", { action_id = target }))
			end
		end
	end
	-- Host-bounded one-shot window intent. Native page entry can expose prerequisites before authority exists;
	-- the consuming window validates its live scope, and controller operations still require their owner origin.
	if type(view.operator_intent) == "table" then table.insert(rows, keyed(tern.json.encode(view.operator_intent), "operator-intent", "orchplus.intent")) end
	if status ~= "ready" then
		if view.migration or view.setup_preview then
			local preview = view.setup_preview or {}
			table.insert(rows, keyed(tern.json.encode({ version = 1, source_nonce = view.alias_nonce, host_pane_id = tostring(view.pane),
				authority_namespace = if view.migration then view.migration.authority_namespace else nil,
				authority_revision = if view.migration then view.migration.authority_revision else nil,
				setup = preview.setup, installation_defaults = preview.installation_defaults, setup_result = view.setup_result }), "setup-index", "orchplus.setup"))
		end
		if status ~= "missing" then table.insert(rows, ui.text("Your saved orchestration needs attention before it can continue. Open Advanced for the retained details; no work has been restarted.")) end
		table.insert(rows, button(view, if view.advanced_open then "Hide Advanced" else "Advanced", { kind = "advanced-toggle" }))
		if view.advanced_open then table.insert(rows, button(view, "Check for restored orchestration data", { kind = "recheck-store" })) end
		if status == "missing" then
			table.insert(rows, ui.text("Set up a new orchestration. ORCH+ checks your SPAWN agent setup before creating it."))
			local defaults = if view.setup_preview then view.setup_preview.installation_defaults else nil
			table.insert(rows, button(view, if defaults and defaults.defined == true then "Edit Default Settings" else "Define Default Settings", { kind = "setup-intent", command = "defaults" }))
			table.insert(rows, button(view, "New orchestration", { kind = "setup-intent", command = "new_orchestration" }))
		end
		-- View identity only: an inert page may ask its window to show prerequisites before authority exists.
		table.insert(rows, keyed(tern.json.encode({ version = 2, host_pane_id = tostring(view.pane), alias_nonce = view.alias_nonce,
			owners = {}, config_open = view.config_open == true }), "ownership-alias", "orchplus.alias"))
		view.action_previous = nil
		return ui.col(rows)
	end
	local navigation = {}
	if not view.config_open then table.insert(navigation, button(view, "Settings", { kind = "config-open" })) end
	table.insert(navigation, button(view, if view.advanced_open then "Hide Advanced" else "Advanced", { kind = "advanced-toggle" }))
	table.insert(rows, ui.row(navigation))
	if view.config_open and selected then
		local _, bound, admitted = controller(view, selected)
		if admitted then
			table.insert(rows, dispatch_link(view, "settings", "This orchestration's settings"))
			table.insert(rows, dispatch_link(view, "save_defaults", "Save as my default settings"))
		elseif bound then table.insert(rows, ui.text("Checking this orchestration's verified connection. Settings become available here when it is ready; existing work stays retained."))
		else table.insert(rows, ui.text("Open this orchestration's controlling view to change its settings.")) end
	end
	if selected == nil and not view.config_open then
		table.insert(rows, ui.text("Create a new orchestration or open one below."))
		table.insert(rows, button(view, if projection.installation_defaults and projection.installation_defaults.defined == true then "Edit Default Settings" else "Define Default Settings", { kind = "setup-intent", command = "defaults" }))
		table.insert(rows, button(view, "New orchestration", { kind = "setup-intent", command = "new_orchestration" }))
		local sessions = {}
		for _, session in projection.sessions do
			table.insert(sessions, button(view, session.name, { kind = "select", orch_session_id = session.orch_session_id }))
		end
		if #sessions > 0 then table.insert(rows, ui.card("Your orchestrations", sessions)) end
	end
	if selected ~= nil then
		local current = if projection.dispatch then projection.dispatch.session_control else nil
		if view.advanced_open and selected.controller == nil and selected.orchestrator == nil and current and current.admission_seq == nil then
			table.insert(rows, button(view, "Close unused logical session…", { kind = "close-unowned-arm" }))
			if view.close_armed and view.close_armed.orch_session_id == selected.orch_session_id then
				table.insert(rows, button(view, "Confirm close — no owner or peer admission", { kind = "close-unowned-confirm", intent = view.close_armed }))
			end
		end
		local card, dispatch_node, request_node, scoped_nodes = dispatch_view(view, projection, selected)
		local workflow, workflow_nodes = workflow_view(view, projection, selected)
		for _, node in forget_view(view, projection) do table.insert(rows, node) end
		if not view.config_open then
			local refusals = proposal_refusals(view, projection, selected)
			if refusals then table.insert(rows, refusals) end
			table.insert(rows, project_panel(view, projection, selected))
		end
		if view.advanced_open then
			table.insert(rows, owner_card(view, "controller", selected.controller, selected.controller_generation, projection.revision))
			if selected.controller == nil then
				table.insert(rows, button(view, "Recover this view for review only", { kind = "admit" }))
				table.insert(rows, ui.text("Recover only this existing orchestration after verified retirement. Saved work and pending evidence stay retained; connection is checked automatically afterwards."))
			end
			table.insert(rows, owner_card(view, "orchestrator", selected.orchestrator, selected.orchestrator_generation, projection.revision))
			local connection_details = ui.card("Advanced · Connection and retained outcomes", { card })
			connection_details.p.collapsible, connection_details.p.collapsed = true, true
			local work_details = ui.card("Advanced · Workers, rulings and merging", { workflow })
			work_details.p.collapsible, work_details.p.collapsed = true, true
			table.insert(rows, connection_details)
			table.insert(rows, work_details)
		end
		-- Config is a display mode: scheduling and effect drivers still need every machine node.
		for _, node in workflow_nodes do table.insert(rows, node) end
		-- Native keyed IDs include every parent: these contract nodes must be main's direct children.
		table.insert(rows, dispatch_node)
		if request_node then table.insert(rows, request_node) end
		for _, node in scoped_nodes do table.insert(rows, node) end
	elseif view.orch_session_id ~= nil then
		table.insert(rows, ui.text(ui.span("Saved registration is unavailable. Select an existing registration; no replacement has been created.", "warning")))
	end
	if view.attestation ~= nil then
		if view.attestation.kind == "attest-executors" then
			table.insert(rows, ui.card("Separate retained-executor verification", {
				ui.text("The stored count of " .. tostring(view.attestation.pending_executors) .. " executors is retained but unconfirmed after restore. I independently verified that the unavailable owner AND every retained executor have stopped or been reconciled. Missing observations alone do not prove this. No currently observed pending executor can be overridden."),
				button(view, "Confirm owner stopped AND every retained executor reconciled", { kind = "attest-executors-confirm", intent = view.attestation }),
			}))
		else
			table.insert(rows, ui.card("Explicit operator attestation", {
				ui.text("I independently checked this unavailable owner has stopped. There are no pending executors. A missing window or pane alone is NOT stop proof; this assertion cannot override known active or pending facts and is not authenticated human provenance."),
				button(view, "Record my verification (does not clear ownership)", { kind = "attest-confirm", intent = view.attestation }),
			}))
		end
	end
	if view.recovery ~= nil then
		table.insert(rows, ui.card("Recovery confirmation", {
			ui.text("Clear only " .. view.recovery.target .. " " .. view.recovery.owner_id .. " / generation " .. tostring(view.recovery.generation)
				.. " at registry revision " .. tostring(view.recovery.revision) .. ". Any intervening change invalidates this confirmation. Nothing will start."),
			button(view, "Confirm verified recovery — clear this owner only", { kind = "confirm-recovery", intent = view.recovery }),
		}))
	end
	-- Only this exact keyed native plugin node is an alias handshake, not terminal/report text.
	local owners = {}
	if selected ~= nil then
		for _, target in { "controller", "orchestrator" } do
			local owner = selected[target]
			if owner ~= nil then
				owners[target] = pick(owner, "owner_id generation", { alias_nonce = if owner.pane_binding ~= nil then owner.pane_binding.alias_nonce else nil })
			end
		end
	end
	table.insert(rows, keyed(tern.json.encode({ version = 2, host_pane_id = tostring(view.pane), authority_version = projection.version, alias_nonce = view.alias_nonce, orch_session_id = view.orch_session_id,
		authority_namespace = projection.authority_namespace, revision = projection.revision, owners = owners, config_open = view.config_open == true,
		session_closed = selected == nil and view.orch_session_id ~= nil }), "ownership-alias", "orchplus.alias"))
	view.action_previous = nil
	return ui.col(rows)
end
return M
