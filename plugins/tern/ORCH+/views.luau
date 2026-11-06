--!strict
local ui = tern.ui
local quota = require("./quota")
local M = {}

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
		if record.eligible and record.enabled == true and not seen[record.id] then
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
-- `attrs` are display-only `data-*` hints for automation that locates a control; the click
-- still resolves only through the host-side entry its render-scoped token names.
local function button(view: any, label: string, entry: any, attrs: any?): any
	view.action_serial += 1
	local token = tostring(view.action_serial)
	view.actions[token] = entry
	return ui.el("button", { text = label, actions = { click = "control=" .. token }, attrs = attrs })
end
-- An unacknowledged command refusal (dispatch card and Config share it).
local function refusal_rows(view: any, rows: { any }, result: any)
	table.insert(rows, ui.text(ui.span("REFUSED: " .. tostring(result.message or result.code), "error")))
	table.insert(rows, button(view, "Acknowledge command refusal", { kind = "dispatch-acknowledge", request_id = result.request_id }))
end
-- Dispatch machine-node fields copied from a projected action and from a command outcome.
local ACTION_KEYS = "phase claim worker_id retry_count wake_status execution_origin execution_pane_binding execution_controller_pane reconciliation_only"
local RESULT_KEYS = "ok code request_id grant_id worker_id work_id wake_status"
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
local function dispatch_link(view: any, command: string, label: string, extra: any?): any
	local request = { command = command, source_nonce = view.alias_nonce, orch_session_id = view.orch_session_id }
	for key, value in extra or {} do request[key] = value end
	local attrs = { ["data-orchplus-command"] = command }
	if type(request.worker_id) == "string" then attrs["data-orchplus-worker"] = request.worker_id end
	return button(view, label, { kind = "operator-intent", request = request }, attrs)
end
local function pause_link(view: any, policy: any): any
	return dispatch_link(view, if policy.paused then "resume" else "pause", if policy.paused then "Resume scheduling" else "Pause new work")
end
-- `orchplus.worker` node fields copied verbatim from the projected workflow worker.
local WORKER_KEYS = "worker_id work_id worker_generation origin_binding pane_binding due_poll due_report report_request_pending active_action_id"
	.. " finish_requested coordinator_owner_id launch_origin_binding launch_pane_binding continuation_required continuation_proof"
	.. " orchestration_excluded context_used_pct phase due_rollover rollover restored adopt_pane_binding withdrawal role family review_id"
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
local function dispatch_view(view: any, projection: any, selected: any): (any, any, any?, any)
	local d = projection.dispatch or { actions = {}, workers = {} }
	local owner, bound, admitted = controller(view, selected)
	local rows = { ui.text("SPAWN owns launch/configuration and mailbox target access. Display identity is configured metadata, not verified account isolation.") }
	table.insert(rows, ui.text("Host scope: local workers use local ORCH+. For remote workers, open ORCH+ on that attached remote Tern host. Controller, workers, mailbox and SPAWN authority stay on the same execution host; managed SSH hops are not supported. Ordinary SPAWN SSH launches are unchanged."))
	if admitted then
		table.insert(rows, ui.row({ dispatch_link(view, "catalog", "Load configured SPAWN catalog"), dispatch_link(view, "start_work", "Start work…") }))
		table.insert(rows, ui.text("Start work imports a /glitch-plan file (read by the execution host), uses the Tern board in Config, or starts a saved template with your input. The board and the intake inbox are polled by this desktop window; inbox files are archived to .orchplus-taken/ only after their intake is accepted."))
	else table.insert(rows, ui.text("This panel is inert for dispatch: only this registration's admitted active controller can claim effects.")) end
	if bound then
		table.insert(rows, dispatch_link(view, "continue_controller", "Continue controller after reload…", { expected_revision = projection.revision }))
		table.insert(rows, dispatch_link(view, "recovery_guide", "Guided reload recovery — next step…"))
		table.insert(rows, ui.text("After a reload, run the palette command ORCH+ Continue controller in this window, then ORCH+ Reload recovery guide, in the window you are using. A button click does not say which window it came from, so the two buttons above act only in the window that already is this controller's continued origin; every other window ignores them."))
		table.insert(rows, ui.text("Reload recovery: first verify old executors and continue this exact controller; then recover the previous SPAWN owner in SPAWN's own Config when it still binds an earlier window; then explicitly reattach each worker. The guide lists every remaining step and opens each explicit, attested control in order; it never attests, retries or reactivates anything by itself."))
		local guide = view.recovery_steps
		if type(guide) == "table" and type(guide.steps) == "table" then
			local checklist = { ui.text(if #guide.steps == 0 then "No reload recovery step remains (as last checked)." else "Remaining steps, in order (as last checked; open the guide to refresh):") }
			for index, step in guide.steps do
				table.insert(checklist, ui.text(tostring(index) .. ". " .. step.label .. (if step.detail then " — " .. step.detail else "")))
			end
			table.insert(rows, ui.card("Reload recovery checklist", checklist))
		end
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
		local fenced = worker.withdrawal
		if fenced then
			table.insert(rows, ui.text(ui.span("Never launched: " .. (if fenced.evidence == "spawn_rejected" then "SPAWN rejected its " .. fenced.op .. " (" .. fenced.action_id .. ") before any effect"
				else "explicit continuation fenced its " .. fenced.op .. " (" .. fenced.action_id .. ", " .. fenced.evidence .. ") as unexecuted")
				.. ". Nothing re-issues it and the old request is never re-sent; cancel this work and queue the assignment again.", "warning")))
			if fenced.mailbox_retire == "retiring" then
				table.insert(rows, ui.text("Cancelled by the owner: its unused mailbox is being retired (" .. tostring(worker.mailbox_status) .. "). The worker is removed once SPAWN confirms retirement; an uncertain retirement is never re-issued, so inspect its retained outcome."))
			elseif admitted then
				table.insert(rows, dispatch_link(view, "cancel_work", "Cancel never-launched work…", { worker_id = worker.worker_id }))
				local retire_sentence = if fenced.mailbox_provisioned
					then " Its provisioned, never-used mailbox is then retired through the exact retirement path; the worker is removed once SPAWN confirms retirement. Nothing native is stopped."
					else " Nothing native is stopped or retired."
				table.insert(rows, ui.text(if fenced.mailbox_retire == "refused" then "SPAWN refused the previous retirement of this work's unused mailbox (reason above); nothing was removed. Cancel again to issue one fresh retirement."
					elseif fenced.status_required
					then "SPAWN received that exact request, so cancel first reads its retained SPAWN status. The worker is removed and its reservations released only when the request can never run: SPAWN has no record of it, rejected it, or reports a pre-effect refusal such as an expired window challenge. A live challenge refuses until it expires (30 s)." .. retire_sentence
					elseif fenced.mailbox_retire ~= nil then (if fenced.evidence == "spawn_rejected" then "SPAWN's rejection is terminal and no producer ever ran"
						else "Continuation proved this request never ran")
						.. ", so cancel retires the unused mailbox through the exact retirement path. The worker and its reservations are released once SPAWN confirms retirement; a refused or uncertain retirement keeps the worker here with that outcome."
					elseif fenced.evidence == "spawn_rejected" then "SPAWN's retained rejection is terminal and no mailbox was created, so cancel removes the worker and releases its reservations directly. Nothing native is stopped or retired."
					elseif fenced.mailbox_provisioned then "That exact request was never sent." .. retire_sentence
					else "That exact request was never sent, so cancel removes the worker and releases its reservations directly. Nothing native is stopped or retired."))
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
				elseif worker.retirement_requested then "retirement requested — waiting for authenticated quiescent release"
				elseif worker.activation_received then "activated — explicit release required when finished"
				elseif worker.activation_issued then "activation issued — awaiting durable reply receipt"
				else "no activation grant — startup or an earlier build; occupied, never inferred active"
			table.insert(rows, ui.text("Coordinator " .. worker.coordinator_owner_id .. " / generation " .. shown(worker.coordinator_generation, "unknown") .. " · " .. phase))
			table.insert(rows, ui.text("Native stop: " .. shown(worker.stop_status, "not requested") .. " · mailbox: " .. shown(worker.mailbox_status, "not provisioned")
				.. " · contiguous replies " .. shown(worker.reply_floor, "0") .. "/" .. shown(worker.reply_seq, "0")))
			if admitted and worker.activation_issued and not worker.retirement_requested and not worker.release_seq and not worker.owner_released then
				table.insert(rows, dispatch_link(view, "retire", "Request graceful coordinator retirement", { worker_id = worker.worker_id }))
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
	if active == nil or active.phase == "complete" then
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
			table.insert(rows, dispatch_link(view, "retry", "Recheck unexecuted capacity refusal: " .. a.request.op, { action_id = id }))
		end
		if a.phase == "claimed" or a.phase == "uncertain" then
			table.insert(rows, ui.text("Retained " .. a.request.op .. " · " .. a.request.request_id .. " / " .. id .. " · " .. a.phase
				.. " · executor " .. tostring(if a.claim then a.claim.executor else "none")))
			if admitted then table.insert(rows, dispatch_link(view, "reconcile", "Read retained SPAWN outcome (never relaunch)", { action_id = id })) end
			if admitted and a.phase == "uncertain" and (a.request.op == "mailbox_publish_ack" or a.request.op == "mailbox_publish_reply") then
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
		table.insert(rows, button(view, "Confirm exact retained executor reconciliation", { kind = "executor-confirm" }))
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
	local machine = { version = 1, source_nonce = view.alias_nonce, host_pane_id = tostring(view.pane), orch_session_id = view.orch_session_id,
		owner_id = if bound then owner.owner_id else nil, owner_generation = if bound then owner.generation else nil,
		controller_phase = if bound then owner.phase else nil, revision = projection.revision, command_cursor = d.command_cursor,
		action = if active then pick(active, ACTION_KEYS, { action_id = active.request.action_id }) else nil,
		result = if outcome then pick(outcome, RESULT_KEYS, { action_id = outcome.action_id }) else nil,
		command_result = if command_result then pick(command_result, "request_id command action_id ok code message acknowledged") else nil,
		driver_result = if driver_result then pick(driver_result, "request_id command action_id ok code message") else nil,
		receipt = view.dispatch_receipt, uncertain_actions = uncertain_ids }
	local request_node = if active then keyed(active.request_bytes, "dispatch-request", "orchplus.request") else nil
	local bytes = tern.json.encode(machine)
	if #bytes > 8192 then
		bytes = tern.json.encode({ version = 1, source_nonce = view.alias_nonce, error = "Dispatch projection exceeds 8192 bytes; no grant exposed." })
	end
	local bridge = keyed(bytes, "dispatch-state", "orchplus.dispatch")
	local scoped_nodes = {}
	for id, a in d.actions do
		local scoped = table.clone(machine)
		scoped.action = pick(a, ACTION_KEYS, { action_id = id })
		local retained = if view.scoped_results then view.scoped_results[id] else nil
		local response = if retained then retained.result elseif outcome and outcome.action_id == id then outcome else nil
		scoped.result = if response then pick(response, RESULT_KEYS, { action_id = id }) else nil
		scoped.receipt = if retained then retained.receipt elseif view.dispatch_receipt and view.dispatch_receipt.action_id == id then view.dispatch_receipt else nil
		scoped.command_result = nil
		local encoded = tern.json.encode(scoped)
		if #encoded <= 8192 then
			table.insert(scoped_nodes, keyed(encoded, "dispatch-action-" .. id, "orchplus.dispatch"))
			table.insert(scoped_nodes, keyed(a.request_bytes, "dispatch-request-" .. id, "orchplus.request"))
		else table.insert(rows, ui.text(ui.span("Exact action surface unavailable: " .. id .. " exceeds 8192 bytes. No grant exposed.", "error"))) end
	end
	return ui.card("Managed dispatch", rows), bridge, request_node, scoped_nodes
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
		.. " · poll " .. tostring(policy.poll_ms) .. "ms · heartbeat " .. tostring(policy.heartbeat_ms) .. "ms · stale " .. tostring(policy.stale_ms) .. "ms"
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
				{ "Context", if worker.context_used_pct ~= nil then "context " .. tostring(worker.context_used_pct) .. "% (worker-reported) · report seq " .. shown(worker.context_seq, "unknown") else "not reported" },
				{ "Orchestration", if worker.orchestration_excluded then "Excluded in Config — skipped by automatic reports and automatic rollover; not stopped" else "Eligible" } }),
		}
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
			local enforce = flow.policy and flow.policy.enforce_cross_family == true
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
				local revision = if review then review.artifact_revision else nil
				for _, r in worker.check_results or {} do
					if r.exit_code == 0 and (revision == nil or r.head == revision) then passed += 1 end
				end
				local checks = "checks " .. tostring(passed) .. "/" .. tostring(total) .. " helper-run"
				local status = if review and not review.voided then review.status else nil
				local proof = if enforce then (ENFORCED_PROOF[status] or "awaiting cross-family review") .. " · " .. checks .. " (evidence only)"
					else checks .. (if total > 0 and passed == total then "" else " — landing waits for every declared check")
						.. " · " .. (PLAIN_PROOF[status] or "awaiting review")
				table.insert(facts, { "Proof (Rule H)", proof })
			end
			table.insert(details, ui.kv(facts))
		end
		if admitted then
			table.insert(details, ui.row({ dispatch_link(view, "inspect_worker", "Inspect native facts", { worker_id = worker.worker_id }),
				dispatch_link(view, "open_worker", "Open exact relevant pane", { worker_id = worker.worker_id }) }))
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
			local phases = {}
			for _, edge in rollover.history do table.insert(phases, edge.phase .. "@" .. tostring(edge.revision)) end
			table.insert(details, ui.text("Rollover " .. rollover.id .. " · " .. worker.rollover.role .. " · " .. rollover.phase .. " · trigger " .. rollover.trigger
				.. " · predecessor " .. rollover.predecessor_worker_id .. " · successor " .. tostring(rollover.successor_worker_id or "not granted")))
			table.insert(details, ui.text("Durable edges: " .. table.concat(phases, " → ")))
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
			if admitted and rollover.cancellable and worker.rollover.role == "predecessor" then
				table.insert(details, dispatch_link(view, "cancel_rollover", "Cancel rollover…", { worker_id = worker.worker_id }))
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
	for _, gate in flow.gates do if chosen and gate.worker_id == chosen.worker_id then table.insert(gates, gate) end end
	-- Open questions first, then settled history; each group in creation order (numeric gate serial).
	local function open_gate(gate: any): boolean return not GATE_SETTLED[gate.phase] end
	local function serial(gate: any): number return tonumber(gate.id:match("(%d+)$")) or 0 end
	table.sort(gates, function(a, b)
		if open_gate(a) ~= open_gate(b) then return open_gate(a) end
		return serial(a) < serial(b) or (serial(a) == serial(b) and a.id < b.id)
	end)
	local gate_page = math.min(view.workflow_gates or 0, math.max(0, math.ceil(#gates / 2) - 1))
	page_controls(rows, "gates", gate_page, #gates, 2)
	for index = gate_page * 2 + 1, math.min(#gates, gate_page * 2 + 2) do
		local gate = gates[index]
		machine("workflow-gate-" .. gate.id, "orchplus.gate", pick(gate, "id revision worker_id worker_generation kind phase"))
		machine("workflow-gate-content-" .. gate.id, "orchplus.gate-content", pick(gate, "id revision worker_id worker_generation question options", { version = 1 }), 65536)
		local fields = { gate_id = gate.id, gate_revision = gate.revision, worker_id = gate.worker_id }
		local details = { ui.text(gate.id .. " / revision " .. tostring(gate.revision) .. " · " .. gate.kind .. " · " .. gate.phase),
			ui.text(gate.question), ui.text("Evidence: " .. shown(gate.evidence, "none supplied")) }
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
	-- Landing queues: FIFO per project/repository/target with one granted slot. Owners reorder or
	-- cancel only ungranted items; uncertain results hold the slot until explicit reconciliation.
	for _, queue in flow.landing or {} do
		local entries = { ui.text(queue.repo_ref .. " · " .. queue.target_ref .. " · project " .. queue.project_id
			.. " · head " .. (if queue.head then queue.head.revision .. " (" .. queue.head.source .. ")" else "unknown until a recorded result")
			.. " · slot " .. (queue.slot or "free")) }
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
			table.insert(entries, ui.text((if item.position then "#" .. tostring(item.position) .. " " else "") .. item.id .. " · " .. item.status .. " · " .. item.work_id
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
				if item.cancellable then table.insert(controls, dispatch_link(view, "cancel_landing", "Cancel…", fields)) end
				if item.markable_lost then table.insert(controls, dispatch_link(view, "landing_lost", "Result lost — hold slot…", fields)) end
				if item.reconcilable then table.insert(controls, dispatch_link(view, "reconcile_landing", "Reconcile observed outcome…", fields)) end
				if #controls > 0 then table.insert(entries, ui.row(controls)) end
			end
		end
		table.insert(entries, ui.text("The release manager performs the repository's approved merge and deploy workflow; ORCH+ never runs git or deploys and never infers landing from REVIEW_READY, DONE or a closed pane."))
		table.insert(rows, ui.card("Landing queue · " .. queue.target_ref, entries))
	end
	-- Imported /glitch-plan files (D10): each checkpoint and task with its state and parser flags,
	-- eight rows per page (per plan), in plan order.
	local function flagged(flags: any): string return if type(flags) == "table" and #flags > 0 then " · flags " .. table.concat(flags, ", ") else "" end
	for _, plan in flow.plans or {} do
		local lines = {}
		for _, cp in plan.checkpoints do
			table.insert(lines, "Checkpoint " .. tostring(cp.n) .. " — " .. preview(cp.title, 120) .. " · " .. tostring(#cp.tasks) .. " task(s)" .. flagged(cp.flags))
			for _, t in cp.tasks do
				table.insert(lines, "Task " .. t.id .. " — " .. preview(t.title, 120) .. " · " .. t.state .. (if t.independent then " · independent" else "")
					.. (if t.worker_id then " · " .. t.worker_id else "") .. (if t.hold then " · held " .. t.hold.code else "") .. flagged(t.flags))
			end
		end
		local entries = { ui.text(plan.plan_id .. " · revision " .. plan.plan_revision:sub(1, 12) .. " · " .. plan.status .. " · " .. plan.path .. flagged(plan.flags)) }
		local page = math.clamp((view.workflow_plans or {})[plan.plan_id] or 0, 0, math.max(0, math.ceil(#lines / 8) - 1))
		page_controls(entries, "plan " .. plan.plan_id, page, #lines, 8)
		for index = page * 8 + 1, math.min(#lines, page * 8 + 8) do table.insert(entries, ui.text(lines[index])) end
		table.insert(rows, ui.card("Imported plan · " .. preview(plan.title, 80), entries))
	end
	machine("workflow-index", "orchplus.workflow", { policy = policy, policy_sha256 = flow.policy_sha256, worker_ids = ids, sweep_last_date = if type(flow.sweep) == "table" then flow.sweep.last_date else nil }, 65536)
	-- Window contract for work sources (Contract K): newest intakes and the desired lane of each mapped board card.
	machine("workflow-intake", "orchplus.intake", { intakes = flow.intakes or {}, board = flow.board or {} }, 65536)
	table.insert(rows, ui.text(ui.span("Nightly mailbox sweep" .. (if policy.sweep_enabled then " at " .. shown(policy.sweep_time, "03:00") .. " local time" else " (off in Config)"), "strong")))
	for _, row in sweep_rows(flow.sweep, 8) do table.insert(rows, row) end
	-- Window contract for the USAGE capacity reader: catalog join, candidate records (pending
	-- routed work first, then the allowlist, then other eligible records), evidence lease and
	-- routed launches that need a fresh USAGE `validate` before their claim.
	local catalog = if projection.dispatch then projection.dispatch.catalog else nil
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
	-- Config record pickers: every eligible, enabled record of the loaded catalog page, in catalog order,
	-- with its capabilities (the release-manager picker lists only release-manager-v1 records).
	local listed = {}
	for _, record in enabled_records(catalog) do table.insert(listed, pick(record, "id revision provider account_label capabilities")) end
	machine("catalog-index", "orchplus.catalog", { version = 1, revision = if catalog then catalog.revision else nil, records = listed }, 65536)
	return ui.card("Health, owner inbox and durable threads", rows), nodes
end
local EDITABLE = { "poll_ms", "heartbeat_ms", "stale_ms", "automatic_reports", "auto_rollover", "rollover_threshold_pct",
	"rollover_include_coordinator", "quota_routing", "excluded_workers", "quota_reserve_pct", "quota_max_age_ms",
	"initial_dispatch_records", "initial_dispatch_provider", "initial_dispatch_account", "initial_dispatch_model", "sweep_enabled", "sweep_time",
	"worker_rollover_records", "worker_rollover_provider", "worker_rollover_account", "worker_rollover_model",
	"coordinator_rollover_records", "coordinator_rollover_provider", "coordinator_rollover_account", "coordinator_rollover_model", "concurrency_limit",
	"loop_cap", "review_rounds", "stale_claim_min", "enforce_cross_family", "family_map", "reviewer_records", "release_manager_record",
	"checkout_roots", "auto_approve_kinds", "glitch_integration", "default_work_source", "board_path", "board_lanes", "inbox_folder",
	"auto_launch_intake", "routes", "labeller_record", "role_guidance", "templates" }
-- Lists in Config show at most this many rows per page; the rest page explicitly.
local CONFIG_PAGE = 8
local APPROVE_KINDS = { "dispatch", "report", "review", "landing" }
local GUIDANCE_ROLES = { { key = "builder", label = "Builder" }, { key = "reviewer", label = "Reviewer" },
	{ key = "release_manager", label = "Release manager" }, { key = "labeller", label = "Labeller" }, { key = "coordinator", label = "Coordinator" } }
local BOARD_LANES = { { key = "queued", label = "Queued lane" }, { key = "running", label = "Running lane" },
	{ key = "review", label = "Review lane" }, { key = "done", label = "Done lane" } }
-- Optional policy values: the reducer stores "none" as the empty string.
local function present(value: any): boolean return type(value) == "string" and value ~= "" end
local function same(left: any, right: any): boolean
	if type(left) ~= type(right) then return false end
	if type(left) ~= "table" then return left == right end
	for key, value in left do if not same(value, right[key]) then return false end end
	for key in right do if left[key] == nil then return false end end
	return true
end
local function checkbox(name: string, checked: boolean, enabled: boolean, label: string): any
	return ui.row({ ui.el("input", { type = "checkbox", name = name, checked = checked, disabled = not enabled }), ui.text(label) })
end
-- Config renders the saved policy, or this view's unsaved draft over it. Only the admitted
-- controller gets editing controls; saving goes through the ordinary policy command.
local function config_view(view: any, projection: any, selected: any): { any }
	local head = {
		ui.text("Orchestration settings for this logical session. Launch records, accounts, models and host settings remain in SPAWN Config."),
		button(view, "Open ORCH+ controller", { kind = "config-close" }),
	}
	local cards = {}
	local function finish(): { any } table.insert(cards, 1, ui.card("ORCH+ Config", head)); return cards end
	if selected == nil then
		table.insert(head, ui.text(ui.span("No logical session is selected in this view. Select an existing registration below or register a distinct one, then claim its controller to edit these settings.", "warning")))
		return finish()
	end
	table.insert(head, ui.text(ui.span(selected.name .. " · " .. selected.orch_session_id, "strong")))
	local owner, bound, admitted = controller(view, selected)
	if owner ~= nil and not bound then table.insert(head, assistance(view, "controller", owner, projection.revision, "reveal", "Reveal recorded controller pane")) end
	local reason = if admitted then nil
		elseif owner == nil then "Read-only: no controller is claimed for this session. Open the controller and claim it to edit settings."
		elseif not bound then "Read-only: this view is not the session's controller (" .. tostring(owner.owner_id) .. "). Edit settings from that controller."
		else "Read-only: this controller is " .. tostring(owner.phase) .. "; continue or recover it before editing."
	if reason then table.insert(head, ui.text(ui.span(reason, "warning"))) end
	-- A refused Config save (e.g. policy_too_large) uses the dispatch card's refusal display.
	local command_result = view.dispatch_command_result
	if command_result and command_result.command == "policy" and command_result.ok == false and not command_result.acknowledged then refusal_rows(view, head, command_result) end
	local flow = if projection.dispatch then projection.dispatch.workflow else nil
	if not flow then
		table.insert(head, ui.text("Session policy unavailable; nothing can be edited."))
		return finish()
	end
	local saved, catalog = flow.policy, projection.dispatch.catalog
	-- Config links fence on the saved policy's digest, never a copy of the policy itself.
	local saved_sha256 = if admitted then flow.policy_sha256 else nil
	local draft = view.policy_draft
	if draft and (draft.session ~= view.orch_session_id or not same(draft.base, saved)) then
		local landed = true
		for _, key in EDITABLE do if not same(draft.values[key], saved[key]) then landed = false end end
		if not landed then table.insert(head, ui.text(ui.span("Saved Config changed; unsaved edits were discarded. Review the current values and repeat your change.", "warning"))) end
		view.policy_draft = nil; draft = nil
	end
	local values = if draft then draft.values else saved
	local changed, dirty = {}, false
	for _, key in EDITABLE do if not same(values[key], saved[key]) then changed[key] = values[key]; dirty = true end end
	local function stepper(field: string, label: string, unit: string, steps: { number }): any
		local row = { ui.text(label .. ": " .. tostring(values[field]) .. unit) }
		if admitted then
			for _, delta in steps do
				table.insert(row, button(view, (if delta > 0 then "+" else "−") .. tostring(math.abs(delta)), { kind = "config-step", field = field, delta = delta }))
			end
			-- Exact entry saves one field immediately, so offer it only without an unsaved draft.
			if not dirty then table.insert(row, dispatch_link(view, "policy", "Enter value…", { field = field, expected_sha256 = saved_sha256 })) end
		end
		return ui.row(row)
	end
	local rollover = { checkbox("auto_rollover", values.auto_rollover, admitted, "Automatic worker rollover") }
	if values.auto_rollover then table.insert(rollover, stepper("rollover_threshold_pct", "Roll over at", "% of worker-reported context (1–99)", { -10, -1, 1, 10 })) end
	table.insert(rollover, checkbox("rollover_include_coordinator", values.rollover_include_coordinator, admitted, "Include the orchestrator (coordinator) in rollover"))
	table.insert(rollover, ui.text("Worker and coordinator rollover are active: when enabled, an idle accepted worker whose latest self-reported context reaches the threshold is asked for a verified checkpoint; every later step still needs its own evidence, and excluded workers are skipped. The activated coordinator is included only when its setting is on; its successor starts only after the predecessor's native stop and slot release, so two coordinators never overlap."))
	table.insert(cards, ui.card("Rollover", rollover))
	local routing = {
		checkbox("quota_routing", values.quota_routing, admitted, "Use remaining quota and weekly reset as a task-routing consideration"),
		ui.text("Active when on (requires USAGE's owner-enabled capacity export): each new task or coordinator start is decided on a validated USAGE snapshot. The record you choose launches only if its identity-bound quota is fresh and strictly above the reserve on every bound window. Otherwise an allowed alternative below is used, a substitution Config does not permit becomes an owner decision, and missing, stale, revoked or unbound evidence holds the work. Among alternatives, the earlier weekly reset is used first; a passed reset needs fresh evidence. USAGE re-confirms the exact evidence revision immediately before each launch. Off: dispatch is exactly the record you choose."),
		stepper("quota_reserve_pct", "Keep in reserve", "% on every bound window (0–99)", { -10, -1, 1, 10 }),
		stepper("quota_max_age_ms", "Evidence max age", " ms (60000–900000)", { -60000, 60000 }),
		stepper("concurrency_limit", "Concurrent routed launches", " per session (0 = no limit configured; 1–32)", { -1, 1 }),
		ui.text("The concurrency limit counts this session's routed work from reservation until verified stop/retirement or a definitive launch failure (an uncertain launch keeps its slot). It serializes this session only, not other sessions' use of the same quota."),
	}
	local offered, offered_ids = enabled_records(catalog), {}
	for _, record in offered do offered_ids[record.id] = true end
	-- Strict routing schema: each scope has its own explicit allowlist and substitution permissions.
	for _, scope in { { key = "initial_dispatch", prefix = "route", title = "initial dispatch (new tasks and coordinator starts)" },
		{ key = "worker_rollover", prefix = "wroute", title = "worker rollover successors" },
		{ key = "coordinator_rollover", prefix = "croute", title = "coordinator rollover successors" } } do
		local list = values[scope.key .. "_records"]
		table.insert(routing, ui.text(ui.span("Allowed alternatives for " .. scope.title .. " (explicit records; none by default)", "strong")))
		for _, record in offered do
			table.insert(routing, checkbox(scope.prefix .. ":" .. record.id, table.find(list, record.id) ~= nil, admitted,
				record.id .. " · provider " .. tostring(record.provider or "unset") .. " · account " .. tostring(record.account_label or "unset")
					.. " · model " .. tostring(record.model_variant or "unset") .. " · selector unverified"))
		end
		for _, record_id in list do
			if not offered_ids[record_id] then table.insert(routing, checkbox(scope.prefix .. ":" .. record_id, true, admitted, record_id .. " · not in the loaded catalog page (never used until it is)")) end
		end
		table.insert(routing, checkbox(scope.key .. "_provider", values[scope.key .. "_provider"], admitted, "Allow switching to a different provider"))
		table.insert(routing, checkbox(scope.key .. "_account", values[scope.key .. "_account"], admitted, "Allow switching to a different account/profile"))
		table.insert(routing, checkbox(scope.key .. "_model", values[scope.key .. "_model"], admitted, "Allow switching to a different model"))
	end
	if not catalog then table.insert(routing, ui.text("Load the SPAWN catalog in the controller to choose alternatives.")) end
	table.insert(routing, ui.text("Unticked permissions turn an otherwise usable alternative into a one-action owner decision. A rollover successor prefers its predecessor's record; a switch needs that rollover kind's allowlist and permission or an owner decision on the predecessor, and the running predecessor never changes. Landing is unaffected. Model/profile selectors are reported unverified: SPAWN exposes no typed selector status, so ORCH+ does not claim enforcement. Quota is never reserved with the provider."))
	table.insert(cards, ui.card("Task routing", routing))
	local scheduling = {
		checkbox("automatic_reports", values.automatic_reports, admitted, "Automatic progress-report requests"),
		stepper("poll_ms", "Poll interval", " ms (1000–60000)", { -1000, 1000 }),
		stepper("heartbeat_ms", "Heartbeat", " ms (5000–3600000)", { -60000, -5000, 5000, 60000 }),
		stepper("stale_ms", "Stale after", " ms (heartbeat–86400000)", { -600000, -60000, 60000, 600000 }),
	}
	if values.stale_ms < values.heartbeat_ms then table.insert(scheduling, ui.text(ui.span("Stale must be at least the heartbeat; Save will be refused.", "warning"))) end
	table.insert(scheduling, ui.text(if saved.paused then "Scheduling paused — new work held; receipts, reports and answers still settle." else "Scheduling enabled."))
	if admitted then table.insert(scheduling, pause_link(view, saved)) end
	table.insert(cards, ui.card("Scheduling and health", scheduling))
	local sweep = { checkbox("sweep_enabled", values.sweep_enabled == true, admitted, "Nightly orphan mailbox sweep") }
	local at = { ui.text("Runs once per local day at " .. shown(values.sweep_time, "03:00") .. " (24-hour, this window's local time)") }
	if admitted and not dirty then table.insert(at, dispatch_link(view, "policy", "Enter time…", { field = "sweep_time", expected_sha256 = saved_sha256 })) end
	table.insert(sweep, ui.row(at))
	table.insert(sweep, ui.text("Each run checks every worker mailbox in this session. It queues the normal mailbox retirement only for a worker whose exact native stop was observed, whose receipts, replies and notifications are settled and that no rollover, landing or review references; queues pending compaction for live workers; and keeps everything else with its reason. It never stops a worker. A missed time (no window attached, host asleep) runs once on the next attach; one run per scheduled day, recorded durably."))
	for _, row in sweep_rows(flow.sweep, 16) do table.insert(sweep, row) end
	table.insert(cards, ui.card("Mailbox sweep", sweep))
	do
		-- Config v4 cards. Numeric/boolean keys edit the draft; list, text and record keys save one
		-- field through the window's bounded prompt, offered only without an unsaved draft.
		local pages = view.config_pages or {}
		local function field_link(label: string, field: string, extra: any?): any?
			if not admitted or dirty then return nil end
			local request: any = { field = field, expected_sha256 = saved_sha256 }
			for key, value in extra or {} do request[key] = value end
			return dispatch_link(view, "policy", label, request)
		end
		local function add(rows: { any }, node: any?) if node then table.insert(rows, node) end end
		local function line(text: string, ...: any): any
			local row = { ui.text(text) }
			for index = 1, select("#", ...) do
				local node = select(index, ...)
				if node then table.insert(row, node) end
			end
			return ui.row(row)
		end
		local function config_card(title: string, rows: { any }, single_field: boolean)
			if reason then table.insert(rows, 1, ui.text(ui.span(reason, "warning")))
			elseif single_field and dirty then table.insert(rows, 1, ui.text(ui.span("Save or discard unsaved changes first; this field saves on its own.", "warning"))) end
			table.insert(cards, ui.card(title, rows))
		end
		local function paged(rows: { any }, name: string, total: number, each: (number) -> ())
			local last = math.max(0, math.ceil(total / CONFIG_PAGE) - 1)
			local page = math.clamp(pages[name] or 0, 0, last)
			for index = page * CONFIG_PAGE + 1, math.min(total, (page + 1) * CONFIG_PAGE) do each(index) end
			if total > CONFIG_PAGE then
				table.insert(rows, ui.text(tostring(total) .. " entries · page " .. tostring(page + 1) .. "/" .. tostring(last + 1)))
				if page > 0 then table.insert(rows, button(view, "Previous page", { kind = "config-page", name = name, page = page - 1 })) end
				if page < last then table.insert(rows, button(view, "Next page", { kind = "config-page", name = name, page = page + 1 })) end
			end
		end
		config_card("Loops", {
			stepper("loop_cap", "Loop cap", " attempts per loop (1–10)", { -1, 1 }),
			stepper("review_rounds", "Review rounds", " per piece of work (1–2)", { -1, 1 }),
			stepper("stale_claim_min", "Stale-claim alert after", " minutes (0 = off; 0–1440)", { -30, -5, 5, 30 }),
			ui.text("Every loop that re-engages a model or a worker stops at the cap with one loop_cap owner decision naming the loop; allowing more resets only that loop's counter. Code-only waits stay time-bounded. A claim older than the stale-claim limit raises one stale_claim decision; ORCH+ never takes over a claim."),
		}, false)
		local review = { checkbox("enforce_cross_family", values.enforce_cross_family == true, admitted,
			"Enforce cross-family review — a green review from a different provider family is the landing proof; off: checks run by the SPAWN helper are the proof") }
		table.insert(review, ui.text(ui.span("Family map (owner-declared, not verified)", "strong")))
		local mapped = {}
		for record_id in values.family_map do table.insert(mapped, record_id) end
		table.sort(mapped)
		paged(review, "family_map", #mapped, function(index: number)
			local record_id = mapped[index]
			table.insert(review, line(record_id .. " → " .. tostring(values.family_map[record_id]) .. " (declared)", field_link("Set family…", "family_map", { item = record_id })))
		end)
		table.insert(review, ui.text("Unmapped records use their provider: Claude → anthropic, Codex → openai, Kimi → moonshot, Agy → google, Grok → xai, Muse → muse. OMP and unknown providers have no family until mapped; cross-family checks on them raise family_unknown."))
		if #mapped < 24 then add(review, field_link("Set family…", "family_map")) end
		table.insert(review, ui.text(ui.span("Reviewer records (tried in order)", "strong")))
		local reviewers = values.reviewer_records
		paged(review, "reviewer_records", #reviewers, function(index: number)
			table.insert(review, line(tostring(index) .. ". " .. reviewers[index],
				if admitted and index > 1 then button(view, "Move up", { kind = "config-move", field = "reviewer_records", item = reviewers[index] }) else nil,
				field_link("Remove", "reviewer_records", { op = "remove", item = reviewers[index] })))
		end)
		if #reviewers == 0 then table.insert(review, ui.text("No reviewer records: review requests hold as reviewer_unavailable.")) end
		if #reviewers < 8 then add(review, field_link("Add reviewer record…", "reviewer_records", { op = "add" })) end
		config_card("Review & proof", review, true)
		local manager = values.release_manager_record
		config_card("Release", {
			line("Release manager record: " .. (if present(manager) then tostring(manager) else "none"), field_link("Choose release manager…", "release_manager_record")),
			ui.text("The release manager is the only merging actor: landing and deploy grants go to it, never to builders. With none configured, landing items hold release_manager_missing."),
		}, true)
		local roots = values.checkout_roots
		local checkouts = { ui.text("Absolute checkout roots (up to 8). Two same-session ORCH+ workers sharing a checkout at or under a root raise shared_checkout; other sessions' workers are not visible.") }
		paged(checkouts, "checkout_roots", #roots, function(index: number)
			table.insert(checkouts, line(roots[index], field_link("Remove", "checkout_roots", { op = "remove", item = roots[index] })))
		end)
		if #roots == 0 then table.insert(checkouts, ui.text("No roots: the shared-checkout gate is off.")) end
		if table.find(roots, "/") then table.insert(checkouts, ui.text(ui.span("Root / covers every path: every worker checkout is gated.", "warning"))) end
		if #roots < 8 then add(checkouts, field_link("Add root…", "checkout_roots", { op = "add" })) end
		config_card("Checkouts", checkouts, true)
		local AUTONOMY_LABELS = { dispatch = "Dispatch — start the proposed worker on the proposed record",
			report = "Report — request a progress report", review = "Review — request a review",
			landing = "Landing — queue the release manager's merge without asking you (proof rule still required)" }
		local autonomy = { ui.text("Approve in-scope coordinator proposals by policy: work from a plan or board with declared scope paths and no open scope, file-overlap or shared-checkout gate. Policy approval never bypasses loop caps, proof, capacity or pause, and every policy answer is recorded and visible.") }
		for _, kind in APPROVE_KINDS do
			table.insert(autonomy, checkbox("approve:" .. kind, table.find(values.auto_approve_kinds, kind) ~= nil, admitted, AUTONOMY_LABELS[kind]))
		end
		config_card("Autonomy", autonomy, false)
		local sources = { checkbox("glitch_integration", values.glitch_integration == true, admitted, "Glitch integration (offer /glitch-plan files as a work source)") }
		if values.glitch_integration == true then
			table.insert(sources, ui.text("Default work source (choose one):"))
			table.insert(sources, checkbox("work_source:glitch_plan", values.default_work_source == "glitch_plan", admitted, "/glitch-plan file"))
			table.insert(sources, checkbox("work_source:board", values.default_work_source == "board", admitted, "Tern board"))
		end
		table.insert(sources, line("Board: " .. (if present(values.board_path) then tostring(values.board_path) else "none"), field_link("Set board path…", "board_path")))
		for _, lane in BOARD_LANES do
			table.insert(sources, line(lane.label .. ": " .. tostring(values.board_lanes[lane.key]), field_link("Set title…", "board_lanes", { item = lane.key })))
		end
		table.insert(sources, line("Inbox folder: " .. (if present(values.inbox_folder) then tostring(values.inbox_folder) else "none"), field_link("Set inbox folder…", "inbox_folder")))
		table.insert(sources, checkbox("auto_launch_intake", values.auto_launch_intake == true, admitted, "Launch new board cards and inbox files automatically (off: each waits for your intake decision)"))
		table.insert(sources, ui.text("The board is read by the desktop window: when this window is attached to a remote host, the board path is on the desktop, not the execution host, and the board is not polled until you confirm it once via Start work…. The inbox folder is listed by the desktop window too, so it is polled only when this window runs on the execution host."))
		config_card("Work sources", sources, true)
		local routes = values.routes
		local by_class = { ui.text("Work without a class is labelled by the labeller record; the label's class picks the route's record. Model and effort are whatever that SPAWN record runs; ORCH+ never sets CLI flags.") }
		paged(by_class, "routes", #routes, function(index: number)
			local route = routes[index]
			table.insert(by_class, line(tostring(route.class) .. " → " .. tostring(route.record_id), field_link("Remove", "routes", { op = "remove", index = index })))
		end)
		if #routes == 0 then table.insert(by_class, ui.text("No routes configured.")) end
		if #routes < 16 then add(by_class, field_link("Add route…", "routes", { op = "add" })) end
		local labeller = values.labeller_record
		table.insert(by_class, line("Labeller record: " .. (if present(labeller) then tostring(labeller) else "none"), field_link("Choose labeller…", "labeller_record")))
		config_card("Routing", by_class, true)
		local guidance = { ui.text("guidance only — restrict tools in the SPAWN record's own CLI flags") }
		for _, role in GUIDANCE_ROLES do
			table.insert(guidance, line(role.label .. ": " .. preview(values.role_guidance[role.key], 80), field_link("Edit…", "role_guidance", { item = role.key })))
		end
		config_card("Role guidance", guidance, true)
		local templates = values.templates
		local chain = { ui.text("Each template's prompt holds one {input}; its output file feeds the next template. A chain stops at its bound with a loop_cap decision.") }
		paged(chain, "templates", #templates, function(index: number)
			local template = templates[index]
			table.insert(chain, line(tostring(template.id) .. " · " .. preview(template.title, 80) .. " → " .. tostring(template.output)
				.. (if present(template.next) then " · then " .. tostring(template.next) else " · last")
				.. (if present(template.class) then " · class " .. tostring(template.class) else ""),
				if admitted then dispatch_link(view, "start_work", "Start…", { template_id = template.id }) else nil,
				field_link("Edit…", "templates", { op = "edit", index = index }), field_link("Remove", "templates", { op = "remove", index = index })))
		end)
		if #templates == 0 then table.insert(chain, ui.text("No templates.")) end
		if #templates < 16 then add(chain, field_link("Add template…", "templates", { op = "add" })) end
		config_card("Templates", chain, true)
	end
	local panes = view.session_panes
	local pane_for = {}
	for _, row in (if panes then panes.panes else {}) do if row.worker_id then pane_for[row.worker_id] = row.pane end end
	local list = {
		ui.text("Every agent pane in this native session, ticked by default. Ticked means eligible for orchestration; unticked means excluded. Pane numbers and titles are never identity proof."),
		ui.text(ui.span("Managed workers (durable, identified by worker ID)", "strong")),
	}
	for _, worker in flow.workers do
		local label = worker.work_id .. " / " .. worker.worker_id .. (if worker.coordinator_owner_id then " · coordinator" else "")
			.. (if pane_for[worker.worker_id] then " · pane " .. tostring(pane_for[worker.worker_id]) else " · no exact pane in this window")
		table.insert(list, checkbox("worker:" .. worker.worker_id, table.find(values.excluded_workers, worker.worker_id) == nil, admitted, label))
	end
	if #flow.workers == 0 then table.insert(list, ui.text("No managed workers in this session.")) end
	table.insert(list, ui.text("Unticked managed workers are skipped by automatic report scheduling. Nothing is stopped or retired by a tick change."))
	table.insert(list, ui.text(ui.span("Hand-opened agent panes (window-scoped)", "strong")))
	if not panes then
		table.insert(list, ui.text("Waiting for this window's agent-pane observation…"))
	else
		-- Explicit verified attach offers only eligible native-agent records with report-files-v1.
		local adoptable = {}
		for _, record in (if catalog then catalog.records else {}) do
			if record.eligible and record.enabled == true and record.backend == "native-agent" and table.find(record.capabilities or {}, "report-files-v1") and #adoptable < 8 then
				table.insert(adoptable, { record_id = record.id, record_revision = record.revision, catalog_revision = catalog.revision,
					label = record.id .. " · " .. tostring(record.provider or "") .. " · " .. tostring(record.account_label or "") })
			end
		end
		local hand = 0
		for _, row in panes.panes do
			if row.worker_id == nil then
				hand += 1
				table.insert(list, checkbox("pane:" .. row.key, not (view.pane_exclusions or {})[row.key], admitted,
					"Pane " .. tostring(row.pane) .. (if row.title ~= "" then " · " .. row.title else "") .. " · " .. row.state
						.. " · eligibility only; orchestration requires an explicit attach"))
				if admitted and not (view.pane_exclusions or {})[row.key] and row.state == "idle" then
					if #adoptable > 0 then
						table.insert(list, dispatch_link(view, "adopt", "Attach pane " .. tostring(row.pane) .. " as ORCH+ worker…",
							{ pane = row.pane, window_epoch = panes.window_epoch, records = adoptable }))
					else
						table.insert(list, ui.text("Attach needs a loaded SPAWN catalog with an eligible native-agent record (Load configured SPAWN catalog in the controller)."))
					end
				end
			end
		end
		if hand == 0 then table.insert(list, ui.text("No other agent panes in this native session.")) end
		if panes.more > 0 then table.insert(list, ui.text("… " .. tostring(panes.more) .. " more agent panes not listed")) end
		table.insert(list, ui.text("Hand-opened pane marks are not durable: after reload they reappear ticked. Ticking never adopts a pane; only the explicit, owner-attested attach enrolls an idle native agent, and nothing is typed into terminals or shells."))
	end
	table.insert(cards, ui.card("Pane orchestration list", list))
	if admitted then
		if dirty then
			table.insert(cards, ui.card("Unsaved changes", {
				dispatch_link(view, "policy", "Save session settings", { policy = changed, expected_sha256 = saved_sha256 }),
				button(view, "Discard unsaved changes", { kind = "config-discard" }),
			}))
		else
			table.insert(cards, ui.text("All settings saved."))
		end
	end
	return finish()
end
function M.render(view: any, projection: any, status: string, diagnostic: string?): any
	view.actions = {}
	local rows = {
		ui.text(ui.span("ORCH+ · ownership and managed dispatch", "strong")),
		ui.text("Host-persisted claims, explicit assignments and durable mailbox receipts. Missing capability is a visible prerequisite, never a raw-command fallback."),
	}
	if diagnostic ~= nil then table.insert(rows, ui.text(ui.span(diagnostic, "error"))) end
	if view.notice ~= nil then table.insert(rows, ui.text(ui.span(view.notice, "info"))) end
	if status ~= "ready" then
		table.insert(rows, ui.text("Authority store: " .. status .. ". Existing ownership is never silently reset."))
		table.insert(rows, button(view, "Recheck restored store", { kind = "recheck-store" }))
		if status == "missing" then
			table.insert(rows, ui.text("First installation only: initialize after verifying that there is no previous ownership store or active ORCH+ owner. Otherwise restore the backup and recheck."))
			table.insert(rows, button(view, "Initialize first-use authority…", { kind = "initialize-arm" }))
			if view.initialize_armed then
				table.insert(rows, button(view, "Confirm first use — no prior owners or lost store", { kind = "initialize-confirm" }))
			end
		end
		return ui.col(rows)
	end
	table.insert(rows, ui.text("Committed registry revision " .. tostring(projection.revision) .. " · all controller blocks share this host authority."))
	local selected = nil
	for _, session in projection.sessions do if session.orch_session_id == view.orch_session_id then selected = session end end
	if view.config_open then
		for _, card in config_view(view, projection, selected) do table.insert(rows, card) end
	else
		table.insert(rows, button(view, "Config", { kind = "config-open" }))
	end
	if not view.config_open or selected == nil then
		table.insert(rows, ui.text("Choose an existing logical session. Names and native IDs are observations, never automatic identity or an excuse for another owner."))
		for _, session in projection.sessions do
			table.insert(rows, button(view, (if session.orch_session_id == view.orch_session_id then "Selected: " else "Select: ") .. session.name .. " · " .. session.orch_session_id,
				{ kind = "select", orch_session_id = session.orch_session_id }))
		end
		table.insert(rows, button(view, "Register a distinct logical session…", { kind = "register-arm" }))
		if view.register_armed then
			table.insert(rows, ui.text("Only create a separate registration for genuinely distinct work. If this is the same native session or an ambiguous restored pane, select its existing registration above."))
			table.insert(rows, button(view, "Confirm distinct session registration", { kind = "register-confirm" }))
		end
	end
	if selected ~= nil then
		local card, dispatch_node, request_node, scoped_nodes = dispatch_view(view, projection, selected)
		local workflow, workflow_nodes = workflow_view(view, projection, selected)
		if not view.config_open then
			table.insert(rows, ui.text(ui.span(selected.name .. " · " .. selected.orch_session_id, "strong")))
			table.insert(rows, owner_card(view, "controller", selected.controller, selected.controller_generation, projection.revision))
			if selected.controller == nil then table.insert(rows, button(view, "Claim controller in this pane", { kind = "admit" })) end
			table.insert(rows, owner_card(view, "orchestrator", selected.orchestrator, selected.orchestrator_generation, projection.revision))
			table.insert(rows, card)
			table.insert(rows, workflow)
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
				button(view, "Confirm owner stopped AND every retained executor reconciled", { kind = "attest-executors-confirm" }),
			}))
		else
			table.insert(rows, ui.card("Explicit operator attestation", {
				ui.text("I independently checked this unavailable owner has stopped. There are no pending executors. A missing window or pane alone is NOT stop proof; this assertion cannot override known active or pending facts and is not authenticated human provenance."),
				button(view, "Record my verification (does not clear ownership)", { kind = "attest-confirm" }),
			}))
		end
	end
	if view.recovery ~= nil then
		table.insert(rows, ui.card("Recovery confirmation", {
			ui.text("Clear only " .. view.recovery.target .. " " .. view.recovery.owner_id .. " / generation " .. tostring(view.recovery.generation)
				.. " at registry revision " .. tostring(view.recovery.revision) .. ". Any intervening change invalidates this confirmation. Nothing will start."),
			button(view, "Confirm verified recovery — clear this owner only", { kind = "confirm-recovery" }),
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
	-- One-shot operator intent of the last clicked window-side control (host-bounded). The window
	-- whose origin owns this controller consumes it once per (source_nonce, serial).
	if type(view.operator_intent) == "table" then table.insert(rows, keyed(tern.json.encode(view.operator_intent), "operator-intent", "orchplus.intent")) end
	-- config_open only asks this window for the display-only session agent-pane list.
	table.insert(rows, ui.text("Window alias diagnostic (not identity or authorization)"))
	table.insert(rows, keyed(tern.json.encode({ version = 2, alias_nonce = view.alias_nonce, orch_session_id = view.orch_session_id,
		revision = projection.revision, owners = owners, config_open = view.config_open == true }), "ownership-alias", "orchplus.alias"))
	return ui.col(rows)
end
return M
