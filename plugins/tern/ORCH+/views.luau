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
	local owner = selected.controller
	local bound = owner ~= nil and owner.pane_binding ~= nil
		and owner.pane_binding.host_pane_id == tostring(view.pane) and owner.pane_binding.alias_nonce == view.alias_nonce
	local admitted = bound and owner.phase == "active"
	local rows = { ui.text("SPAWN owns launch/configuration and mailbox target access. Display identity is configured metadata, not verified account isolation.") }
	table.insert(rows, ui.text("Host scope: local workers use local ORCH+. For remote workers, open ORCH+ on that attached remote Tern host. Controller, workers, mailbox and SPAWN authority stay on the same execution host; managed SSH hops are not supported. Ordinary SPAWN SSH launches are unchanged."))
	if admitted then table.insert(rows, dispatch_link(view, "catalog", "Load configured SPAWN catalog"))
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
			local detail = record.id .. " · " .. tostring(record.provider or "") .. " · " .. tostring(record.account_label or "") .. " · " .. tostring(record.backend or "")
			table.insert(rows, ui.text(detail))
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
		if admitted and a.phase == "backpressure" then
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
	if command_result and command_result.ok == false and not command_result.acknowledged then
		table.insert(rows, ui.text(ui.span("REFUSED: " .. tostring(command_result.message or command_result.code), "error")))
		table.insert(rows, button(view, "Acknowledge command refusal", { kind = "dispatch-acknowledge", request_id = command_result.request_id }))
	end
	-- Every uncertain retained action (bounded): the window's read-only reconciliation covers each
	-- one, independent of selection or which worker is active.
	local uncertain_ids = {}
	for id, a in d.actions do if a.phase == "uncertain" and a.claim then table.insert(uncertain_ids, id) end end
	table.sort(uncertain_ids)
	while #uncertain_ids > 16 do table.remove(uncertain_ids) end
	local machine = { version = 1, source_nonce = view.alias_nonce, host_pane_id = tostring(view.pane), orch_session_id = view.orch_session_id,
		owner_id = if bound then owner.owner_id else nil, owner_generation = if bound then owner.generation else nil,
		controller_phase = if bound then owner.phase else nil, revision = projection.revision, command_cursor = d.command_cursor,
		action = if active then { action_id = active.request.action_id, phase = active.phase, claim = active.claim, worker_id = active.worker_id,
			retry_count = active.retry_count, wake_status = active.wake_status, execution_origin = active.execution_origin,
			execution_pane_binding = active.execution_pane_binding, execution_controller_pane = active.execution_controller_pane,
			reconciliation_only = active.reconciliation_only } else nil,
		result = if outcome then { ok = outcome.ok, code = outcome.code, request_id = outcome.request_id, action_id = outcome.action_id, grant_id = outcome.grant_id,
			worker_id = outcome.worker_id, work_id = outcome.work_id, wake_status = outcome.wake_status } else nil,
		command_result = if command_result then { request_id = command_result.request_id, command = command_result.command, action_id = command_result.action_id,
			ok = command_result.ok, code = command_result.code, message = command_result.message, acknowledged = command_result.acknowledged } else nil,
		driver_result = if driver_result then { request_id = driver_result.request_id, command = driver_result.command,
			action_id = driver_result.action_id, ok = driver_result.ok, code = driver_result.code } else nil,
		receipt = view.dispatch_receipt, uncertain_actions = uncertain_ids }
	local request_node = nil
	if active then
		request_node = ui.text(active.request_bytes); request_node.p.key = "dispatch-request"; request_node.p.role = "orchplus.request"
	end
	local bytes = tern.json.encode(machine)
	if #bytes > 8192 then
		bytes = tern.json.encode({ version = 1, source_nonce = view.alias_nonce, error = "Dispatch projection exceeds 8192 bytes; no grant exposed." })
	end
	local bridge = ui.text(bytes); bridge.p.key = "dispatch-state"; bridge.p.role = "orchplus.dispatch"
	local scoped_nodes = {}
	for id, a in d.actions do
		local scoped = table.clone(machine)
		scoped.action = { action_id = id, phase = a.phase, claim = a.claim, worker_id = a.worker_id, retry_count = a.retry_count, wake_status = a.wake_status,
			execution_origin = a.execution_origin, execution_pane_binding = a.execution_pane_binding,
			execution_controller_pane = a.execution_controller_pane, reconciliation_only = a.reconciliation_only }
		local retained = if view.scoped_results then view.scoped_results[id] else nil
		local response = if retained then retained.result elseif outcome and outcome.action_id == id then outcome else nil
		scoped.result = if response then { ok = response.ok, code = response.code, request_id = response.request_id, action_id = id,
			grant_id = response.grant_id, worker_id = response.worker_id, work_id = response.work_id, wake_status = response.wake_status } else nil
		scoped.receipt = if retained then retained.receipt elseif view.dispatch_receipt and view.dispatch_receipt.action_id == id then view.dispatch_receipt else nil
		scoped.command_result = nil
		local encoded = tern.json.encode(scoped)
		if #encoded <= 8192 then
			local node = ui.text(encoded); node.p.key = "dispatch-action-" .. id; node.p.role = "orchplus.dispatch"
			table.insert(scoped_nodes, node)
			local request = ui.text(a.request_bytes); request.p.key = "dispatch-request-" .. id; request.p.role = "orchplus.request"
			table.insert(scoped_nodes, request)
		else table.insert(rows, ui.text(ui.span("Exact action surface unavailable: " .. id .. " exceeds 8192 bytes. No grant exposed.", "error"))) end
	end
	return ui.card("Managed dispatch", rows), bridge, request_node, scoped_nodes
end
local function workflow_view(view: any, projection: any, selected: any): (any, any)
	local flow = if projection.dispatch then projection.dispatch.workflow else nil
	local owner = selected.controller
	local bound = owner and owner.pane_binding
		and owner.pane_binding.host_pane_id == tostring(view.pane) and owner.pane_binding.alias_nonce == view.alias_nonce
	local admitted = bound and owner.phase == "active"
	local rows, nodes, ids = {}, {}, {}
	if not flow then return ui.card("Workflow", { ui.text("Workflow unavailable; no scheduling authority exposed.") }), nodes end
	local function machine(key: string, role: string, value: any, limit: number?)
		local bytes = tern.json.encode(value)
		if #bytes > (limit or 8192) then
			table.insert(rows, ui.text(ui.span("Workflow surface unavailable: " .. key .. " exceeds the native bounded projection.", "error")))
			return
		end
		local node = ui.text(bytes); node.p.key = key; node.p.role = role
		table.insert(nodes, node)
	end
	local policy = flow.policy
	table.insert(rows, ui.text((if policy.paused then "Paused — new work held; receipts, reports and answers still settle." else "Scheduling enabled")
		.. " · poll " .. tostring(policy.poll_ms) .. "ms · heartbeat " .. tostring(policy.heartbeat_ms) .. "ms · stale " .. tostring(policy.stale_ms) .. "ms"
		.. " · automatic reports " .. (if policy.automatic_reports then "enabled" else "off")))
	if admitted then
		table.insert(rows, dispatch_link(view, if policy.paused then "resume" else "pause", if policy.paused then "Resume scheduling" else "Pause new work"))
	end
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
		machine("workflow-worker-" .. worker.worker_id, "orchplus.worker", {
			worker_id = worker.worker_id, work_id = worker.work_id, worker_generation = worker.worker_generation,
			origin_binding = worker.origin_binding, pane_binding = worker.pane_binding,
			due_poll = worker.due_poll, due_report = worker.due_report, report_request_pending = worker.report_request_pending,
			report_held = worker.rejected_report ~= nil, reattach_needed = worker.reattach_needed == true,
			active_action_id = worker.active_action_id,
			finish_requested = worker.finish_requested, coordinator_owner_id = worker.coordinator_owner_id,
			launch_origin_binding = worker.launch_origin_binding, launch_pane_binding = worker.launch_pane_binding,
			continuation_required = worker.continuation_required, continuation_proof = worker.continuation_proof,
			orchestration_excluded = worker.orchestration_excluded, context_used_pct = worker.context_used_pct,
			phase = worker.phase, due_rollover = worker.due_rollover, rollover = worker.rollover, restored = worker.restored, adopt_pane_binding = worker.adopt_pane_binding,
			-- Fenced never-launched work only: the exact request the window reads SPAWN status for before cancel_work.
			withdrawal = worker.withdrawal,
			-- Routed work only; absent for explicit (unrouted) dispatch so its claim path is unchanged.
			routing = if worker.routing then { phase = worker.routing.phase, mode = worker.routing.mode, evidence_revision = worker.routing.evidence_revision } else nil,
		})
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
				{ "Report request", if worker.report_request_pending then "Pending worker response; not duplicated" elseif worker.due_report then "Due; safe delivery required" else "Not due" },
				{ "Context", if worker.context_used_pct ~= nil then "context " .. tostring(worker.context_used_pct) .. "% (worker-reported) · report seq " .. shown(worker.context_seq, "unknown") else "not reported" },
				{ "Orchestration", if worker.orchestration_excluded then "Excluded in Config — skipped by automatic reports and automatic rollover; not stopped" else "Eligible" } }),
		}
		if (worker.wake_pending_count or 0) > 0 then
			table.insert(details, ui.text("Durably published notifications: " .. tostring(worker.wake_pending_count)
				.. " pending · " .. tostring(worker.wake_unstarted_count or 0) .. " not started (no native effect begun)"
				.. " · " .. tostring(worker.wake_uncertain_count or 0) .. " claimed/uncertain (remain occupied). Only fresh safe-idle workers are woken; publication is not consumption."))
		end
		if admitted then
			table.insert(details, ui.row({ dispatch_link(view, "inspect_worker", "Inspect native facts", { worker_id = worker.worker_id }),
				dispatch_link(view, "open_worker", "Open exact relevant pane", { worker_id = worker.worker_id }) }))
		end
		if bound then
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
			if rollover.hold then table.insert(details, ui.text(ui.span("Held: " .. rollover.hold.code .. " · " .. rollover.hold.message, "warning"))) end
			if rollover.checkpoint then
				table.insert(details, ui.text("Checkpoint " .. rollover.checkpoint.checkpoint_id .. " @ " .. rollover.checkpoint.artifact_revision
					.. " · checks " .. tern.json.encode(rollover.checkpoint.checks) .. " — worker-attested, not independent verification"))
			end
			if admitted and rollover.rerequestable and worker.rollover.role == "predecessor" then
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
	local gate_page = math.min(view.workflow_gates or 0, math.max(0, math.ceil(#gates / 2) - 1))
	page_controls(rows, "gates", gate_page, #gates, 2)
	for index = gate_page * 2 + 1, math.min(#gates, gate_page * 2 + 2) do
		local gate = gates[index]
		machine("workflow-gate-" .. gate.id, "orchplus.gate", {
			id = gate.id, revision = gate.revision, worker_id = gate.worker_id, worker_generation = gate.worker_generation,
			kind = gate.kind, phase = gate.phase,
		})
		machine("workflow-gate-content-" .. gate.id, "orchplus.gate-content", {
			version = 1, id = gate.id, revision = gate.revision, worker_id = gate.worker_id, worker_generation = gate.worker_generation,
			question = gate.question, options = gate.options,
		}, 65536)
		local fields = { gate_id = gate.id, gate_revision = gate.revision, worker_id = gate.worker_id }
		local details = { ui.text(gate.id .. " / revision " .. tostring(gate.revision) .. " · " .. gate.kind .. " · " .. gate.phase),
			ui.text(gate.question), ui.text("Evidence: " .. shown(gate.evidence, "none supplied")) }
		for _, option in gate.options do table.insert(details, ui.text(option.id .. " · " .. option.label)) end
		if gate.answer then table.insert(details, ui.text("Owner answer: " .. tern.json.encode(gate.answer))) end
		if gate.delivery then table.insert(details, ui.text("Immutable delivery: " .. tern.json.encode(gate.delivery))) end
		if gate.result then table.insert(details, ui.text("Correlated worker result (not native effect proof): " .. tern.json.encode(gate.result))) end
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
			if gate.phase ~= "cancelled" and gate.phase ~= "superseded" and gate.phase ~= "acknowledged" and gate.phase ~= "resolved" then
				table.insert(details, dispatch_link(view, "cancel_gate", "Cancel this gate…", fields))
			end
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
			machine("workflow-landing-" .. item.id, "orchplus.landing", { id = item.id, revision = item.revision, status = item.status, queue_id = queue.id,
				worker_id = item.worker_id, uncertain = item.uncertain, cancellable = item.cancellable, move_up = item.move_up, move_down = item.move_down,
				markable_lost = item.markable_lost, reconcilable = item.reconcilable })
			local r, grant = item.request, item.grant
			table.insert(entries, ui.text((if item.position then "#" .. tostring(item.position) .. " " else "") .. item.id .. " · " .. item.status .. " · " .. item.work_id
				.. " · " .. r.source_ref .. "@" .. r.source_revision .. " → expects " .. r.target_revision
				.. (if item.approved then " · owner approved" elseif item.gate_id then " · approval gate " .. item.gate_id else "")))
			if item.hold then
				table.insert(entries, ui.text(ui.span(item.hold.code .. " · " .. item.hold.message, if item.status == "blocked" then "warning" else "info")))
			end
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
			if admitted and item.position then
				local fields = { landing_id = item.id, landing_revision = item.revision }
				local controls = {}
				if item.move_up then table.insert(controls, dispatch_link(view, "move_landing", "Move up", { landing_id = item.id, landing_revision = item.revision, direction = "up" })) end
				if item.move_down then table.insert(controls, dispatch_link(view, "move_landing", "Move down", { landing_id = item.id, landing_revision = item.revision, direction = "down" })) end
				if item.cancellable then table.insert(controls, dispatch_link(view, "cancel_landing", "Cancel…", fields)) end
				if item.markable_lost then table.insert(controls, dispatch_link(view, "landing_lost", "Result lost — hold slot…", fields)) end
				if item.reconcilable then table.insert(controls, dispatch_link(view, "reconcile_landing", "Reconcile observed outcome…", fields)) end
				if #controls > 0 then table.insert(entries, ui.row(controls)) end
			end
		end
		table.insert(entries, ui.text("The project worker performs its own approved merge workflow; ORCH+ never runs git and never infers landing from REVIEW_READY, DONE or a closed pane."))
		table.insert(rows, ui.card("Landing queue · " .. queue.target_ref, entries))
	end
	machine("workflow-index", "orchplus.workflow", { policy = policy, worker_ids = ids, sweep_last_date = if type(flow.sweep) == "table" then flow.sweep.last_date else nil }, 65536)
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
			table.insert(routed, { worker_id = worker.worker_id, phase = r.phase, mode = r.mode, evidence_revision = r.evidence_revision,
				auth_revision = r.auth_revision, launch_action_id = worker.launch_action_id })
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
	local records, seen, ordered = {}, {}, {}
	if catalog and catalog.namespace then
		for _, record in catalog.records do
			if record.eligible and record.enabled == true and not seen[record.id] then seen[record.id] = true; table.insert(ordered, record) end
		end
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
		evidence = if evidence then { revision = evidence.revision, auth_revision = evidence.auth_revision, expires_at_ms = evidence.expires_at_ms } else nil,
		refresh_due = policy.quota_routing and catalog ~= nil and catalog.namespace ~= nil and (evidence == nil or evidence.expires_at_ms <= now + 15000 or pending),
		workers = routed }, 65536)
	return ui.card("Health, owner inbox and durable threads", rows), nodes
end
local EDITABLE = { "poll_ms", "heartbeat_ms", "stale_ms", "automatic_reports", "auto_rollover", "rollover_threshold_pct",
	"rollover_include_coordinator", "quota_routing", "excluded_workers", "quota_reserve_pct", "quota_max_age_ms",
	"initial_dispatch_records", "initial_dispatch_provider", "initial_dispatch_account", "initial_dispatch_model", "sweep_enabled", "sweep_time",
	"worker_rollover_records", "worker_rollover_provider", "worker_rollover_account", "worker_rollover_model",
	"coordinator_rollover_records", "coordinator_rollover_provider", "coordinator_rollover_account", "coordinator_rollover_model", "concurrency_limit" }
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
	local owner = selected.controller
	local bound = owner ~= nil and owner.pane_binding ~= nil
		and owner.pane_binding.host_pane_id == tostring(view.pane) and owner.pane_binding.alias_nonce == view.alias_nonce
	local admitted = bound and owner.phase == "active"
	if owner ~= nil and not bound then table.insert(head, assistance(view, "controller", owner, projection.revision, "reveal", "Reveal recorded controller pane")) end
	if not admitted then
		table.insert(head, ui.text(ui.span(if owner == nil then "Read-only: no controller is claimed for this session. Open the controller and claim it to edit settings."
			elseif not bound then "Read-only: this view is not the session's controller (" .. tostring(owner.owner_id) .. "). Edit settings from that controller."
			else "Read-only: this controller is " .. tostring(owner.phase) .. "; continue or recover it before editing.", "warning")))
	end
	local flow = if projection.dispatch then projection.dispatch.workflow else nil
	if not flow then
		table.insert(head, ui.text("Session policy unavailable; nothing can be edited."))
		return finish()
	end
	local saved = flow.policy
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
			if not dirty then table.insert(row, dispatch_link(view, "policy", "Enter value…", { field = field, expected = saved })) end
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
	local routing_catalog = if projection.dispatch then projection.dispatch.catalog else nil
	-- Strict routing schema: each scope has its own explicit allowlist and substitution permissions.
	for _, scope in { { key = "initial_dispatch", prefix = "route", title = "initial dispatch (new tasks and coordinator starts)" },
		{ key = "worker_rollover", prefix = "wroute", title = "worker rollover successors" },
		{ key = "coordinator_rollover", prefix = "croute", title = "coordinator rollover successors" } } do
		local list = values[scope.key .. "_records"]
		table.insert(routing, ui.text(ui.span("Allowed alternatives for " .. scope.title .. " (explicit records; none by default)", "strong")))
		local listed_records = {}
		for _, record in (if routing_catalog then routing_catalog.records else {}) do
			if record.eligible and record.enabled == true and not listed_records[record.id] then
				listed_records[record.id] = true
				table.insert(routing, checkbox(scope.prefix .. ":" .. record.id, table.find(list, record.id) ~= nil, admitted,
					record.id .. " · provider " .. tostring(record.provider or "unset") .. " · account " .. tostring(record.account_label or "unset")
						.. " · model " .. tostring(record.model_variant or "unset") .. " · selector unverified"))
			end
		end
		for _, record_id in list do
			if not listed_records[record_id] then table.insert(routing, checkbox(scope.prefix .. ":" .. record_id, true, admitted, record_id .. " · not in the loaded catalog page (never used until it is)")) end
		end
		table.insert(routing, checkbox(scope.key .. "_provider", values[scope.key .. "_provider"], admitted, "Allow switching to a different provider"))
		table.insert(routing, checkbox(scope.key .. "_account", values[scope.key .. "_account"], admitted, "Allow switching to a different account/profile"))
		table.insert(routing, checkbox(scope.key .. "_model", values[scope.key .. "_model"], admitted, "Allow switching to a different model"))
	end
	if not routing_catalog then table.insert(routing, ui.text("Load the SPAWN catalog in the controller to choose alternatives.")) end
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
	if admitted then table.insert(scheduling, dispatch_link(view, if saved.paused then "resume" else "pause", if saved.paused then "Resume scheduling" else "Pause new work")) end
	table.insert(cards, ui.card("Scheduling and health", scheduling))
	local sweep = { checkbox("sweep_enabled", values.sweep_enabled == true, admitted, "Nightly orphan mailbox sweep") }
	local at = { ui.text("Runs once per local day at " .. shown(values.sweep_time, "03:00") .. " (24-hour, this window's local time)") }
	if admitted and not dirty then table.insert(at, dispatch_link(view, "policy", "Enter time…", { field = "sweep_time", expected = saved })) end
	table.insert(sweep, ui.row(at))
	table.insert(sweep, ui.text("Each run checks every worker mailbox in this session. It queues the normal mailbox retirement only for a worker whose exact native stop was observed, whose receipts, replies and notifications are settled and that no rollover, landing or review references; queues pending compaction for live workers; and keeps everything else with its reason. It never stops a worker. A missed time (no window attached, host asleep) runs once on the next attach; one run per scheduled day, recorded durably."))
	for _, row in sweep_rows(flow.sweep, 16) do table.insert(sweep, row) end
	table.insert(cards, ui.card("Mailbox sweep", sweep))
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
		local catalog = if projection.dispatch then projection.dispatch.catalog else nil
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
				dispatch_link(view, "policy", "Save session settings", { policy = changed, expected = saved }),
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
				owners[target] = { owner_id = owner.owner_id, generation = owner.generation,
					alias_nonce = if owner.pane_binding ~= nil then owner.pane_binding.alias_nonce else nil }
			end
		end
	end
	-- One-shot operator intent of the last clicked window-side control (host-bounded). The window
	-- whose origin owns this controller consumes it once per (source_nonce, serial).
	if type(view.operator_intent) == "table" then
		local intent = ui.text(tern.json.encode(view.operator_intent))
		intent.p.key = "operator-intent"
		intent.p.role = "orchplus.intent"
		table.insert(rows, intent)
	end
	-- config_open only asks this window for the display-only session agent-pane list.
	local bridge = ui.text(tern.json.encode({ version = 2, alias_nonce = view.alias_nonce,
		orch_session_id = view.orch_session_id, revision = projection.revision, owners = owners, config_open = view.config_open == true }))
	bridge.p.key = "ownership-alias"
	bridge.p.role = "orchplus.alias"
	table.insert(rows, ui.text("Window alias diagnostic (not identity or authorization)"))
	table.insert(rows, bridge)
	return ui.col(rows)
end
return M
