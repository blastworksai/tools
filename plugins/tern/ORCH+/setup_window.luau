--!strict
-- Drafts live only in this window; every committed value belongs to the host authority.
local codec = require("./wire/codec")
local provider_display = require("./provider_display")
local quota = require("./quota")
local protocol = require("./dispatch_protocol")
local policy_validation = require("./policy_validation")
local M = {}
function M.new(api: any): any
	local pending: any = {}
	local drafts: any = {}
	local feedbacks: any = {}
	local function fail(cx: WindowCx, message: string) cx:toast("error", "ORCH+ setup", message) end
	local function index(cx: WindowCx, source: number): any?
		local _, bytes = api.surface(cx, source, "orchplus.orchestrator", "orchplus.setup", "setup-index", codec.LIMITS.logical)
		return if bytes then api.decode(bytes, codec.LIMITS.logical) else nil
	end
	local function migration_index(cx: WindowCx, source: number): any?
		local _, bytes = api.surface(cx, source, "orchplus.orchestrator", "orchplus.migration", "migration-state", codec.LIMITS.logical)
		return if bytes then api.decode(bytes, codec.LIMITS.logical) else nil
	end
	local function migration_relay(value: any): boolean
		local function closed(row: any, fields: any): boolean
			if type(row) ~= "table" then return false end
			for key in row do if fields[key] == nil then return false end end
			for key, limit in fields do
				if type(row[key]) ~= "string" or #row[key] == 0 or #row[key] > limit
					or not row[key]:match("^[A-Za-z0-9_.%-]+$") then return false end
			end
			return true
		end
		if type(value) ~= "table" then return false end
		for key in value do
			if key ~= "relay_endpoint" and key ~= "lane_id" and key ~= "peer_boot" and key ~= "receipt" then return false end
		end
		return closed({ relay_endpoint = value.relay_endpoint, lane_id = value.lane_id, peer_boot = value.peer_boot },
			{ relay_endpoint = 128, lane_id = 128, peer_boot = 64 })
			and closed(value.receipt, { id = 80, incarnation = 64 })
	end
	local function migration_source(data: any, owner: string): boolean
		if type(data) ~= "table" or not codec.validate_dispatch_migration_qualification(data.qualification, owner) then return false end
		local proof = data.qualification.proof
		if data.authority_revision ~= proof.source_revision or proof.phase ~= (if proof.protocol == 1 then "prepared" else "stable") then return false end
		if owner == "spawn" then
			if data.protocol ~= proof.protocol or data.spawn_namespace ~= proof.candidate_namespace
				or data.phase == "legacy" or data.protocol == 1 and data.phase ~= "prepared" then return false end
		elseif data.protocol ~= 2 or data.authority_namespace ~= proof.candidate_namespace
			or data.source_sha256 ~= proof.source_sha256 or (data.phase == "legacy") ~= (proof.protocol == 1) then return false end
		if data.compatibility ~= nil and not codec.validate_dispatch_compatibility(data.compatibility) then return false end
		return table.find({ "legacy", "prepared", "stable" }, data.phase) ~= nil
	end
	local function migration_next(own: any, peer: any): (string?, string?)
		if not migration_source(own, "orch") or not migration_source(peer, "spawn") then return nil, "A complete current source proof is unavailable." end
		local a, b = own.qualification.proof, peer.qualification.proof
		if a.state ~= "ready" or b.state ~= "ready" or a.pending_immutable ~= 0 or b.pending_immutable ~= 0
			or a.blockers ~= 0 or b.blockers ~= 0 or a.managed_sha256 ~= b.managed_sha256
			or not api.same(own.qualification.selection, peer.qualification.selection) then
			return nil, "The independent sources do not agree, or unresolved effects still require review."
		end
		local function paired(value: any): boolean
			if value == nil then return true end
			if value.kind == "current" then
				return value.authority_namespace == a.candidate_namespace and value.spawn_namespace == b.candidate_namespace
			end
			return value.orch.candidate_namespace == a.candidate_namespace and value.spawn.candidate_namespace == b.candidate_namespace
		end
		if not paired(own.compatibility) or not paired(peer.compatibility)
			or peer.authority_namespace ~= nil and peer.authority_namespace ~= a.candidate_namespace then
			return nil, "The retained pair belongs to a different authority. Neither store was replaced."
		end
		-- SPAWN must establish its candidate before ORCH can prepare against it.
		-- A proof's stable phase describes its schema, not a retained prepared obligation.
		if peer.protocol == 1 or peer.phase == "stable" and peer.authority_namespace == nil then return "spawn", "prepare" end
		if own.phase == "legacy" or own.phase == "stable" and (not own.compatibility or own.compatibility.kind ~= "current") then return "orch", "prepare" end
		if peer.phase == "prepared" then return "spawn", "finish" end
		if own.phase == "prepared" then return "orch", "finish" end
		if own.phase ~= "stable" or peer.phase ~= "stable" or not own.compatibility or not peer.compatibility
			or own.compatibility.kind ~= "current" or peer.compatibility.kind ~= "current"
			or not codec.dispatch_compatibility_ready({ schema = 1, kind = "migration", orch = a, spawn = b }) then
			return nil, "Both components have not published a stable matching pair."
		end
		return "complete", nil
	end
	local function identity(cx: WindowCx, source: number, data: any?): any?
		local pane, host = cx.session:pane(source), api.host(cx, source)
		local membership = api.membership(cx)
		if not pane or pane.block ~= "orchplus.orchestrator" or pane.parked
			or not host or host.state ~= "connected"
			or pane.tab == nil or membership[pane.tab] == nil then return nil end
		if data and (type(data.source_nonce) ~= "string" or data.source_nonce == ""
			or type(data.host_pane_id) ~= "string" or data.host_pane_id == "") then return nil end
		return { host_pane_id = if data then data.host_pane_id else nil, window_key = cx:window_key(), window_epoch = api.epoch,
			native_session_id = tostring(membership[pane.tab]), window_host_id = tostring(host.id) }
	end
	local function origin(cx: WindowCx, source: number, data: any?, settings_form: boolean?): any?
		local binding = identity(cx, source, data)
		if not binding or (not settings_form and cx.session:view(source) == nil) or cx.hosts:current().state ~= "connected"
			or binding.window_host_id ~= tostring(cx.hosts:current().id)
			or binding.native_session_id ~= tostring(cx.sessions:current().id) then return nil end
		return binding
	end
	local function live(cx: WindowCx, s: any): any?
		local data = if s.migration then migration_index(cx, s.source) else index(cx, s.source)
		-- The exact retained settings form may live in a different tab from its source.
		-- Its nonce and native host/session still fence every read and deliberate write.
		local settings_form = not s.migration and api.forms.active(s.source, "settings")
		if not data or data.source_nonce ~= s.nonce or not api.same(origin(cx, s.source, data, settings_form), s.origin) then return nil end
		return data
	end
	local function spawn_managed(cx: WindowCx, s: any)
		local current = if s.nonce ~= nil then live(cx, s) ~= nil else api.same(origin(cx, s.source, nil), s.origin)
		if not current then return fail(cx, "Setup view moved or reloaded. Reopen setup; nothing was repeated.") end
		local membership = api.membership(cx)
		local target: number? = nil
		for _, row in cx.session:panes() do
			local pane = cx.session:pane(row.pane)
			local host = if pane then api.host(cx, pane.pane) else nil
			if pane and pane.block == "spawn.spawner" and not pane.parked and pane.tab ~= nil
				and tostring(membership[pane.tab]) == s.origin.native_session_id
				and host and host.state == "connected" and tostring(host.id) == s.origin.window_host_id
				and cx.session:view(pane.pane) ~= nil then
				-- More than one suitable view is not permission to guess.
				if target ~= nil then target = nil; break end
				target = pane.pane
			end
		end
		local value = tern.json.encode({ kind = "page", page = "managed", native_window = cx:window_key() })
		local ok, opened = pcall(function()
			if target ~= nil then
				cx.layout:focus(target)
				cx.session:event(target, { ev = "action", id = "main", act = "page-entry", value = value })
				return target
			end
			-- Placement stays anchored to the validated source, not whichever pane gained focus.
			return cx:new_block("spawn.spawner", { value }, "beside", { target = s.source, focus = true })
		end)
		if not ok then
			fail(cx, "SPAWN page navigation failed; nothing was retried. " .. tostring(opened):sub(1, 300))
		elseif opened == nil then
			fail(cx, "SPAWN managed setup is unavailable on this execution host. Install/enable SPAWN, then open setup again; nothing was retried.")
		end
	end
	local function send(cx: WindowCx, s: any, kind: string, fields: any, done: any?)
		local data = live(cx, s)
		if not data then
			api.forms.update(cx, s.source, { busy = false, notice = "Setup source changed. Entered values are retained; no operation was sent." })
			return fail(cx, "Setup view moved or reloaded. Reopen setup; nothing was repeated.")
		end
		local request = { source_nonce = s.nonce, request_id = api.id(), kind = kind, expected_config_revision = s.revision,
			authority_namespace = s.authority_namespace, expected_revision = data.authority_revision, setup_origin = s.origin }
		for key, value in fields do request[key] = value end
		cx.session:event(s.source, { ev = "action", id = "main.setup-index", act = "setup-command", value = tern.json.encode(request) })
		if done then
			s.wait = { id = request.request_id, done = done, started = tern.now(), writes_config = true }
			pending[s.source] = s
		end
	end
	local menu: any
	local catalog: any
	local query: any
	local function reusable(defaults: any): any
		local p = api.copy(defaults.policy)
		p.paused = false; p.excluded_workers = tern.json.array(); p.checkout_roots = tern.json.array()
		for _, key in { "board_path", "inbox_folder" } do
			if p[key]:match("^[/\\]") or p[key]:match("^%a:") then p[key] = "" end
		end
		return { policy = p, builder_record = p.preferred_worker_record, coordinator_record = p.preferred_orchestrator_record }
	end
	local function feedback(cx: WindowCx, s: any, message: string, errors: any?)
		if drafts[s.source] ~= s then return end
		local value = { notice = message, notice_tone = "error", errors = errors or {}, busy = false }
		if api.forms.active(s.source, "settings") and api.forms.update(cx, s.source, value) then feedbacks[s.source] = nil
		else feedbacks[s.source] = { draft = s, value = value } end
	end
	local function completed(cx: WindowCx, s: any)
		local selected = tern.json.array(); local p = s.defaults.policy
		for _, record in s.catalog.records do
			if record.id == p.preferred_worker_record or record.id == p.preferred_orchestrator_record
				or record.id == p.release_manager_record or table.find(p.reviewer_records, record.id) then table.insert(selected, record) end
		end
		send(cx, s, "setup_lifecycle", { state = if s.adopt then "adopted_existing" else "completed",
			catalog_version = 2, spawn_setup = s.catalog.setup, records = selected }, function(last: WindowCx)
			feedback(last, s, "Default settings saved. No work was started.")
		end)
	end
	local function save(cx: WindowCx, s: any, scope: string)
		if not live(cx, s) then feedback(cx, s, "Settings source changed. Entered values are retained; reopen current settings before saving."); return end
		local target = if scope == "instance" then s.defaults.policy else reusable(s.defaults).policy
		local encoded, bytes = pcall(quota.canonical, target)
		if not encoded or #bytes > protocol.POLICY_BYTES then
			local errors = {}
			local message = if encoded then "Total settings exceed 48 KiB. Shorten content or remove some entries; nothing was saved." else "Some settings cannot be encoded. Check numeric values and durations; nothing was saved."
			for i, template in target.templates do
				for _, key in { "title", "prompt", "output" } do if template[key] ~= "" then errors["template_" .. i .. "_" .. key] = message end end
				for j = 1, (s.custom_counts[i] or 0) do errors["template_" .. i .. "_custom_value_" .. j] = message end
			end
			for _, key in { "reviewer_records", "initial_dispatch_records", "worker_rollover_records", "coordinator_rollover_records" } do
				if #target[key] > 0 then errors[key] = message end
			end
			for _, key in { "board_path", "inbox_folder" } do if target[key] ~= "" then errors[key] = message end end
			if not encoded then
				for _, key in { "concurrency_limit", "loop_cap", "review_rounds", "quota_reserve_pct", "quota_age_hours", "poll_duration", "report_duration", "stale_duration", "claim_duration" } do errors[key] = message end
			end
			feedback(cx, s, message, errors); return
		end
		if scope == "instance" then
			if not s.session or not s.session_origin or not s.previous then feedback(cx, s, "Instance settings can only be saved from this orchestration's settings editor."); return end
			local policy = api.copy(s.defaults.policy); policy.paused = nil
			local wait = { started = tern.now() }; s.instance_wait = wait; pending[s.source] = s
			api.forms.update(cx, s.source, { busy = true, notice = "Saving this orchestration…" })
			return api.save_policy(cx, s.source, s.session_origin, s.previous, policy, function(fresh: WindowCx, result: any)
				if s.instance_wait ~= wait then return end
				s.instance_wait = nil; if pending[s.source] == s then pending[s.source] = nil end
				if result.ok then
					local flow, data = api.flow(fresh, s.source), live(fresh, s)
					s.previous = api.copy(if flow then flow.policy else s.defaults.policy)
					s.session_origin = api.origin(fresh, s.source)
					if data then s.authority_revision = data.authority_revision end
					drafts[s.source] = nil; api.forms.cancel(fresh, s.source)
					fresh:toast("info", "Settings saved", "Saved for this orchestration. Installation defaults and project targets are unchanged.")
				else feedback(fresh, s, tostring(result.message or result.code or "Save refused. Entered values are retained.")) end
			end)
		end
		api.forms.update(cx, s.source, { busy = true, notice = "Saving reusable defaults…" })
		send(cx, s, "installation_defaults", { defaults = reusable(s.defaults) }, function(fresh: WindowCx)
			local data = live(fresh, s)
			if data then s.defaults = api.copy(data.installation_defaults); s.revision = data.installation_defaults.revision end
			drafts[s.source] = nil; api.forms.cancel(fresh, s.source)
			fresh:toast("info", "Default settings saved", "New orchestrations reuse them. Absolute board/inbox paths and live state were not copied; existing work and project targets are unchanged.")
			if s.wizard and s.catalog then completed(fresh, s) end
		end)
	end
	local function duration(value: number, hours: boolean): string
		local seconds = math.floor(value / 1000 + 0.000001)
		return if hours then string.format("%02d:%02d:%02d", math.floor(seconds / 3600), math.floor(seconds / 60) % 60, seconds % 60)
			else string.format("%02d:%02d", math.floor(seconds / 60), seconds % 60)
	end
	local function parse_duration(value: any, hours: boolean): number?
		if type(value) ~= "string" then return nil end
		local h, m, sec
		if hours then h, m, sec = value:match("^(%d+):(%d%d):(%d%d)$") else m, sec = value:match("^(%d+):(%d%d)$"); h = "0" end
		if not h or not m or not sec or tonumber(sec) > 59 or hours and tonumber(m) > 59 then return nil end
		return (tonumber(h) * 3600 + tonumber(m) * 60 + tonumber(sec)) * 1000
	end
	menu = function(cx: WindowCx, s: any)
		local p = s.defaults.policy; local fields, bindings, groups, actions = {}, {}, {}, {}
		local retained_values = s.retained_values; s.retained_values = nil
		local function group(id: string, label: string, parent: string?, collapsed: boolean?, tone: string?, separator_after: boolean?)
			table.insert(groups, { id = id, label = label, parent = parent, collapsed = if parent == nil then true else collapsed, tone = tone, separator_after = separator_after })
		end
		local function add(id: string, label: string, kind: string, parent: string, opts: any?)
			local entry: any = { id = id, label = label, kind = kind, group = parent, value = p[id] }
			for k, v in opts or {} do entry[k] = v end
			if retained_values and retained_values[id] ~= nil then entry.value = api.copy(retained_values[id]) end
			if kind == "number" then entry.value = tostring(entry.value) end
			table.insert(fields, entry); if p[id] ~= nil then bindings[id] = true end
		end
		local function button(id: string, label: string, disabled: boolean?, parent: string?, after_field: string?)
			table.insert(actions, { id = id, label = label, submit = true, disabled = disabled, group = parent, after_field = after_field })
		end
		local options = { { value = "", label = "Not selected" } }; local checks = {}
		local needs_setup = s.catalog ~= nil and s.catalog.setup.state ~= "completed" and s.catalog.setup.state ~= "adopted_existing"
		for _, record in if s.catalog then s.catalog.records else {} do
			if record.enabled ~= true or record.eligible ~= true then needs_setup = true end
			local account = if type(record.account_label) == "string" and record.account_label:find("%S") then record.account_label else "Account not specified"
			local choice = { value = record.id, label = provider_display.name(record.provider) .. " · " .. account,
				icon = provider_display.icon(record.provider) }
			table.insert(options, choice); table.insert(checks, api.copy(choice))
		end
		for _, id in { p.preferred_worker_record, p.preferred_orchestrator_record, p.release_manager_record } do
			if id and id ~= "" then
				local found = false; for _, option in options do if option.value == id then found = true end end
				if not found then table.insert(options, { value = id, label = id .. " (saved; unavailable on this host)" }); needs_setup = true end
			end
		end
		for _, key in { "reviewer_records", "initial_dispatch_records", "worker_rollover_records", "coordinator_rollover_records" } do
			for _, id in p[key] do
				local found = false; for _, option in checks do if option.value == id then found = true end end
				if not found then table.insert(checks, { value = id, label = id .. " (saved; unavailable on this host)" }); needs_setup = true end
			end
		end
		group("glitch", "Glitch Integration", nil, nil, nil, true)
		add("glitch_integration", "Enable Glitch integration", "switch", "glitch")
		add("work_on_enabled", "Enable Work On", "switch", "glitch", { enabled_by = "glitch_integration" })
		local work_status, work_available
		if api.work_status then work_status, work_available = api.work_status(cx, s.source) end
		add("work_requirement", "WORK prerequisite", "note", "glitch", { space_before = true, tone = if work_available then "success" else nil,
			value = work_status or "Requires WORK plugin when Glitch is enabled. Use Install or update WORK if unavailable." })
		group("general", "General"); group("checkout", "Checkout Locations", "general")
		add("track_checkout_roots", "Track each agent’s actual working folder automatically.", "switch", "checkout", {
			help = "Glitch enabled: discover the workspace and its worktrees from Glitch.\nGlitch disabled: obtain the project folder when adding the project." })
		add("auto_start_projects", "Start work automatically when added", "switch", "general", { help = "Start newly added projects/work immediately, without requiring you to press the START button." })
		add("board_path", "Board file location", "path", "general", { scope = "desktop",
			help = "Leave blank for ORCH+ to manage the location, or choose another location." })
		group("agents", "Agents and Routing")
		add("spawn_help", "Agent setup", "note", "agents", { value = "Reminder: Agent setup is handled in SPAWN" })
		if needs_setup then add("agent_readiness", "Before starting work", "note", "agents", {
			value = "Saved agent preferences can be selected here. Complete the required setup in SPAWN before starting an agent that is not ready, then refresh agents." }) end
		add("preferred_worker_record", "Preferred Worker", "select", "agents", { options = options, help = "Your default Agent" })
		add("preferred_orchestrator_record", "Preferred Orchestrator", "select", "agents", { options = options, help = "Your default Orchestrator" })
		add("quota_routing", "Route by remaining quota", "switch", "agents", { help = "Consider verified USAGE capacity when choosing an agent." })
		add("quota_reserve_pct", "Remaining quota reserve", "number", "agents", { unit = "%", enabled_by = "quota_routing", help = "How much quota to leave unused." })
		add("quota_age_enabled", "Maximum quota-evidence age", "switch", "agents", { value = p.quota_max_age_ms > 0, help = "How recent a quota reading must be in hours." })
		add("quota_age_hours", "Maximum evidence age", "number", "agents", { value = if p.quota_max_age_ms > 0 then p.quota_max_age_ms / 3600000 else 1, unit = "hours", enabled_by = "quota_age_enabled" })
		add("quota_age_validity", "When the override is off", "note", "agents", { value = "USAGE still checks source freshness and reset validity." })
		add("concurrency_limit", "Concurrent work limit", "number", "agents", { help = "How much work items can concurrently run in orchestration across all agents." })
		add("ram_formula", "Suggestion", "math", "agents", { value = "\\text{Max concurrent tasks}=\\left\\lfloor\\frac{\\text{RAM budget for tasks}}{\\text{peak RAM per task}}\\right\\rfloor", copyable = true,
			help = "- Reserve memory for other applications and a safety margin.\n- Measure representative work before recommending a higher limit.\n- Consider CPU and disk pressure too—RAM alone is insufficient." })
		group("alternatives", "Alternative Agent Allowances", "agents", true)
		add("alternatives_help", "Alternative Agent Allowances", "note", "alternatives", { value = "Can ORCH+ use an alternative agent over your preferred agent?" })
		for _, scope in {
			{ "initial_dispatch", "Starting new work", "This is off by default - The worked route is to tell your orchestrator which agent to use, or to start the agent yourself and attach it to orchestration." },
			{ "worker_rollover", "Change worker agent on rollover", "This is off by default - The worked route is to have the same agent continue the work on a rollover." },
			{ "coordinator_rollover", "Change orchestrator agent on rollover", "This is off by default - The worked route is to have the same agent continue orchestration on a rollover." },
		} do
			group(scope[1], scope[2], "alternatives")
			add(scope[1] .. "_enabled", scope[2], "switch", scope[1], { help = scope[3] })
			add(scope[1] .. "_records", "Allowed agents", "checklist", scope[1], { options = checks, enabled_by = scope[1] .. "_enabled", help = "Choose the agents ORCH+ may use instead." })
			add(scope[1] .. "_provider", "Allow a different provider", "switch", scope[1], { enabled_by = scope[1] .. "_enabled", help = "For example, use Codex instead of Claude." })
			add(scope[1] .. "_account", "Allow a different account", "switch", scope[1], { enabled_by = scope[1] .. "_enabled", help = "For example, use your Personal account instead of Work." })
		end
		group("review", "Review and Completion")
		add("require_code_review", "Require review", "switch", "review", { help = "Another agent must check the code before ORCH+ allows it to be merged." })
		add("require_other_family", "Require a different declared family", "switch", "review", { visible_when = "require_code_review",
			help = "The reviewer must use a different AI provider from the builder.\nFor example:\n- Claude builds, Codex reviews: allowed.\n- Claude Work builds, Claude Personal reviews: not a different provider." })
		add("reviewer_records", "Reviewers", "checklist", "review", { options = checks, enabled_by = "require_code_review", help = "Which agents may review work." })
		local release = { { value = "worker", label = "Same agent as worker (default)" } }
		for _, option in options do if option.value ~= "" then
			local selected = api.copy(option); selected.value = "record:" .. option.value; table.insert(release, selected)
		end end
		if p.merge_actor_mode == "selected_record" and p.release_manager_record == "" then
			table.insert(release, { value = "record:", label = "Choose a release agent", disabled = true })
		end
		add("merge_actor", "Release manager", "select", "review", { value = if p.merge_actor_mode == "worker" then "worker" else "record:" .. p.release_manager_record, options = release,
			help = "The reviewer checks the work; the release manager handles the merge/release after the required checks and approvals.\nResearch or writing tasks do not need a release manager." })
		group("continuity", "Continuity")
		add("auto_rollover", "Automatic worker rollover", "switch", "continuity", { help = "Replace a worker when its measured context reaches the threshold, at the next completed CP." })
		add("rollover_mode", "Reported context threshold", "select", "continuity", { value = if p.rollover_threshold_pct == 0 then "calculated" else "percentage",
			options = { { value = "calculated", label = "Calculated (default)" }, { value = "percentage", label = "Percentage override" } }, enabled_by = "auto_rollover" })
		add("rollover_formula", "Calculated threshold", "math", "continuity", {
			value = "\\begin{aligned}\\text{context now}&\\geq\\text{first-turn context}\\\\&+0.55\\times(\\text{window}\\\\&-\\text{first-turn context})\\end{aligned}", copyable = true,
			visible_when = { id = "rollover_mode", value = "calculated" },
			help = "Uses 55% of the context headroom remaining after the first turn. Requires reliable context measurements; unavailable measurements stay unknown." })
		add("rollover_threshold_pct", "Percentage override", "number", "continuity", { value = if p.rollover_threshold_pct == 0 then "" else p.rollover_threshold_pct,
			unit = "%", enabled_by = "auto_rollover", visible_when = { id = "rollover_mode", value = "percentage" }, help = "Enter a whole percentage from 1 to 99." })
		add("rollover_include_coordinator", "Include orchestrator", "switch", "continuity", { enabled_by = "auto_rollover",
			help = "Use the same calculated threshold or percentage override for the orchestrator. It rolls over when the threshold is reached, without waiting for a CP." })
		group("advanced", "ADVANCED", nil, true); group("approvals", "Automatic Approvals", "advanced")
		add("approvals_help", "Automatic Approvals", "note", "approvals", { value = "These do not remove the required checks or project protections." })
		for _, kind in {
			{ "dispatch", "Dispatch", "Approve starting proposed work." },
			{ "report", "Report", "approve requesting a progress report." },
			{ "review", "Review", "approve requesting a review." },
			{ "landing", "Merging / release", "approve queuing an eligible merge/release." },
		} do
			add("approval_" .. kind[1], kind[2], "switch", "approvals", { value = table.find(p.auto_approve_kinds, kind[1]) ~= nil, help = kind[3] })
		end
		add("merge_coordination", "Merge Coordination", "switch", "approvals", { help = "Let ORCH+ coordinate merging." })
		group("cleanup", "Cleanup", "advanced")
		add("sweep_enabled", "Night Cleanup", "switch", "cleanup", {
			help = "Once a day, check for communication files left behind by finished agents. Remove them only when all messages have been handled and nothing still needs them. On your first interaction with the orchestrator after the set time, orchestrator notifies you how many communication files are open, and if any of them look stale.\nIt does not delete your plans, code or conversations, and it does not stop working agents. Unfinished or uncertain communication is kept." })
		add("sweep_time", "Cleanup Time", "text", "cleanup", { unit = "hh:mm:ss", enabled_by = "sweep_enabled",
			help = "When that daily cleanup check should run. The current default is 03:00.\nIf Tern is closed or the computer is asleep, it catches up when the window runs again—not through a separate background service." })
		add("cleanup_clock", "Cleanup clock and notification", "note", "cleanup", {
			value = "Uses the local time on the computer running the Tern window. The next interaction with the ORCH+ panel shows the cleanup summary. Native conversation events do not reliably distinguish human messages, so they cannot trigger it." })
		group("reports", "Reporting and Monitoring", "advanced")
		add("poll_duration", "Report polling", "text", "reports", { value = duration(p.poll_ms, false), unit = "mm:ss", help = "How often ORCH+ checks for updates from orchestrated agents." })
		add("stale_duration", "Stale report interval", "text", "reports", { value = duration(p.stale_ms, false), unit = "mm:ss", help = "— when an agent’s report is considered old." })
		add("automatic_reports", "Request reports automatically", "switch", "reports", { help = "Automatically ask agents for progress reports." })
		add("report_duration", "Automatic-report interval", "text", "reports", { value = duration(p.report_request_ms, false), unit = "mm:ss", enabled_by = "automatic_reports" })
		group("limits", "Limits and Stalled Work", "advanced")
		add("loop_cap", "Loop limit", "number", "limits", { help = "How many attempts a work loop may make before asking for a decision." })
		add("review_rounds", "Review rounds", "number", "limits", { help = "Number of review rounds a change may go through before asking for a decision." })
		add("claim_duration", "Stale claim interval", "text", "limits", { value = duration(p.stale_claim_min * 60000, true), unit = "hh:mm:ss", help = "When to alert about work that has remained claimed too long; it does not automatically take ownership away." })
		group("inbox", "OPTIONAL: Inbox location", "advanced", true)
		add("inbox_folder", "Inbox location", "path", "inbox", { scope = "host", placeholder = ".orchplus/inbox", help = "optional external integration mechanism" })
		group("templates", "OPTIONAL: Templates", "advanced", true)
		add("templates_help", "Template setup", "note", "templates", { value = "Ask your orchestrator to help set up custom work item templates" })
		s.custom_counts = {}
		for i, template in p.templates do
			local parent = "template_" .. i; group(parent, template.title ~= "" and template.title or "Template " .. i, "templates")
			for _, row in { { "id", "ID" }, { "title", "Title" }, { "prompt", "Prompt" }, { "output", "Output file path" }, { "next", "Optional next template" }, { "class", "Optional task type" } } do add(parent .. "_" .. row[1], row[2], if row[1] == "prompt" then "editor" else "text", parent, { value = template[row[1]] or "" }) end
			local names = {}; for name in template.custom_fields or {} do table.insert(names, name) end; table.sort(names); s.custom_counts[i] = #names
			for j, name in names do
				add(parent .. "_custom_name_" .. j, "Custom field name", "text", parent, { value = name })
				add(parent .. "_custom_value_" .. j, "Custom field value", "editor", parent, { value = template.custom_fields[name] })
				button("remove_custom_" .. i .. "_" .. j, "Remove custom field " .. name, nil, parent)
			end
			add(parent .. "_new_custom", "Add custom field name", "text", parent, { value = "" })
			button("custom_" .. i, "Add custom field", #names >= 16, parent)
			button("remove_template_" .. i, "Remove template", nil, parent)
		end
		button("add_template", "Add template", #p.templates >= 16, "templates")
		button("spawn", "Open SPAWN", nil, "agents", "spawn_help")
		button("refresh_agents", "Refresh SPAWN agents", nil, "agents", "spawn_help")
		button("work_install", "Install or update WORK", nil, "glitch", "work_requirement")
		button("defaults", "SAVE AS DEFAULT ORCHESTRATION SETTINGS"); button("instance", "SAVE FOR THIS ORCHESTRATION INSTANCE ONLY", not s.session or s.session_origin == nil)
		button("reload", "Reload saved settings (discard this draft)")
		api.forms.open(cx, s.source, s.origin, { tag = "settings", title = if s.session then "Orchestration settings" elseif s.defaults.defined == true then "Edit Default Settings" else "Define Default Settings",
			description = "Changes stay in this pane until saved. Defaults apply only to new orchestrations and omit absolute board/inbox paths and live state. Instance settings apply only here.", fields = fields, groups = groups, actions = actions },
			function(fresh: WindowCx, values: any, action: string)
				if action == "cancel" then
					drafts[s.source] = nil; feedbacks[s.source] = nil
					s.retained_values = nil; s.catalog_done = nil
					api.forms.cancel(fresh, s.source); return
				end
				if not live(fresh, s) then feedback(fresh, s, "Source changed. Entered values are retained; no write was attempted."); return end
				if action == "reload" then s.reload(fresh); return end
				if type(values) ~= "table" then feedback(fresh, s, "Complete form values unavailable."); return end
				if action == "spawn" then feedback(fresh, s, "Draft retained. Complete SPAWN setup, then refresh agents."); return spawn_managed(fresh, s) end
				if action == "work_install" then
					feedback(fresh, s, "WORK is required only for Glitch. Use the plugin manager's explicit install/update consent.")
					if api.install_work then api.install_work(fresh, s.source, s.origin)
					else feedback(fresh, s, "The WORK install/update action is unavailable in this window. Update the connected ORCH+ window plugin first.") end; return
				end
				if action == "refresh_agents" then
					s.retained_values = api.copy(values)
					feedback(fresh, s, "Refreshing SPAWN agents…")
					return catalog(fresh, s, function(last: WindowCx) menu(last, s) end)
				end
				local next_policy = api.copy(s.defaults.policy); local errors = {}
				for key in bindings do
					if key == "rollover_threshold_pct" and values.rollover_mode == "calculated" then next_policy[key] = 0; continue end
					local value = values[key]
					if type(next_policy[key]) == "number" then local n = tonumber(value); if not n or n % 1 ~= 0 then errors[key] = "Enter a whole number." else next_policy[key] = n end
					elseif type(next_policy[key]) ~= type(value) then errors[key] = "Invalid value type."
					else next_policy[key] = api.copy(value) end
				end
				if values.rollover_mode ~= "calculated" and values.rollover_mode ~= "percentage" then errors.rollover_mode = "Choose the calculated threshold or a percentage override."
				elseif values.rollover_mode == "percentage" and next_policy.rollover_threshold_pct == 0 then errors.rollover_threshold_pct = "Enter a whole percentage from 1 to 99, or choose Calculated." end
				for _, key in { "initial_dispatch_records", "worker_rollover_records", "coordinator_rollover_records" } do
					table.sort(next_policy[key])
				end
				if values.quota_age_enabled then
					local hours = tonumber(values.quota_age_hours)
					local age = if hours then math.floor(hours * 3600000 + 0.5) else nil
					if not age or age ~= age or age == math.huge or age == -math.huge then errors.quota_age_hours = "Enter a finite number of hours."
					else next_policy.quota_max_age_ms = age end
				else next_policy.quota_max_age_ms = 0 end
				for _, row in { { "poll_duration", "poll_ms", false }, { "report_duration", "report_request_ms", false }, { "stale_duration", "stale_ms", false }, { "claim_duration", "stale_claim_min", true } } do
					local n = parse_duration(values[row[1]], row[3])
					if not n then errors[row[1]] = "Enter " .. (if row[3] then "hh:mm:ss." else "mm:ss.")
					else next_policy[row[2]] = if row[2] == "stale_claim_min" then n / 60000 else n end
				end
				if not next_policy.require_code_review then next_policy.require_other_family = false end
				if values.merge_actor == "worker" then next_policy.merge_actor_mode = "worker"; next_policy.release_manager_record = ""
				elseif type(values.merge_actor) == "string" and values.merge_actor:sub(1, 7) == "record:" then
					next_policy.merge_actor_mode = "selected_record"; next_policy.release_manager_record = values.merge_actor:sub(8)
				else errors.merge_actor = "Choose the existing worker or a configured release agent." end
				next_policy.auto_approve_kinds = tern.json.array()
				for _, kind in { "dispatch", "report", "review", "landing" } do if values["approval_" .. kind] == true then table.insert(next_policy.auto_approve_kinds, kind) end end
				for i, template in next_policy.templates do
					local prefix = "template_" .. i .. "_"
					for _, key in { "id", "title", "prompt", "output", "next", "class" } do template[key] = values[prefix .. key] end
					if template.class == "" then template.class = nil end
					template.custom_fields = {}
					for j = 1, s.custom_counts[i] do
						local name, value = values[prefix .. "custom_name_" .. j], values[prefix .. "custom_value_" .. j]
						local name_error = policy_validation.custom_field_error(name, "")
						local value_error = policy_validation.custom_field_error("field", value)
						if name_error then errors[prefix .. "custom_name_" .. j] = name_error
						elseif template.custom_fields[name] ~= nil then errors[prefix .. "custom_name_" .. j] = "Choose a unique custom field name."
						else template.custom_fields[name] = value end
						if value_error then errors[prefix .. "custom_value_" .. j] = value_error end
					end
				end
				local controls = { poll_ms = "poll_duration", report_request_ms = "report_duration", stale_ms = "stale_duration",
					stale_claim_min = "claim_duration", quota_max_age_ms = "quota_age_hours", merge_actor_mode = "merge_actor", release_manager_record = "merge_actor" }
				if action == "defaults" or action == "instance" then
					for key, message in policy_validation.policy_errors(next_policy) do
						local control = controls[key] or key
						local ti, vi = key:match("^template_(%d+)_custom_value_(%d+)$")
						if ti then
							local names = {}; for name in next_policy.templates[tonumber(ti)].custom_fields do table.insert(names, name) end; table.sort(names)
							for j = 1, s.custom_counts[tonumber(ti)] do
								if values["template_" .. ti .. "_custom_name_" .. j] == names[tonumber(vi)] then control = "template_" .. ti .. "_custom_value_" .. j; break end
							end
						end
						if key == "templates" then
							for _, entry in fields do if entry.id:match("^template_%d+_") then errors[entry.id] = errors[entry.id] or message end end
						else errors[control] = errors[control] or message end
					end
				end
				if next(errors) then feedback(fresh, s, "Correct the marked fields; other entries are retained.", errors); return end
				s.defaults.policy = next_policy
				if action == "defaults" or action == "instance" then return save(fresh, s, action) end
				if action == "add_template" then table.insert(next_policy.templates, { id = "", title = "", prompt = "", output = "", next = "", class = "", custom_fields = {} }) end
				local remove = action:match("^remove_template_(%d+)$"); if remove then table.remove(next_policy.templates, tonumber(remove)) end
				local template_index, custom_index = action:match("^remove_custom_(%d+)_(%d+)$")
				if template_index then
					local i, j = tonumber(template_index), tonumber(custom_index)
					next_policy.templates[i].custom_fields[values["template_" .. i .. "_custom_name_" .. j]] = nil
				end
				local custom = action:match("^custom_(%d+)$")
				if custom then
					local i = tonumber(custom); local name = values["template_" .. i .. "_new_custom"]
					local problem = policy_validation.custom_field_error(name, "")
					if problem or next_policy.templates[i].custom_fields[name] ~= nil then feedback(fresh, s, "Enter a new unique custom field name.", { ["template_" .. i .. "_new_custom"] = problem or "Choose a unique custom field name." }); return end
					next_policy.templates[i].custom_fields[name] = ""
				end
				menu(fresh, s)
			end)
	end
	query = function(cx: WindowCx, s: any, cursor: any?)
		local request = { schema = 2, origin = "orchplus", op = "catalog", request_id = api.id(), action_id = api.id(), setup_origin = s.origin, cursor = cursor }
		s.query = request; s.query_started = tern.now(); s.sent = false; s.reply = nil
		send(cx, s, "catalog_request", { request = request })
		pending[s.source] = s
	end
	local function catalog_failure(cx: WindowCx, s: any, message: string)
		pending[s.source] = nil; s.query = nil
		if s.ready_done then local done = s.ready_done; s.ready_done = nil; done(cx, false, message)
		else
			if drafts[s.source] ~= s then return end
			if not api.forms.active(s.source) then menu(cx, s) else s.retained_values = nil end
			feedback(cx, s, message .. " Open Agent setup in SPAWN, then refresh agents here.")
		end
	end
	catalog = function(cx: WindowCx, s: any, done: any?)
		s.catalog_done = done; s.page_done = nil
		local bridge, problem = api.transport(cx, s.source, s.origin); s.bridge = bridge
		if not bridge then return catalog_failure(cx, s, problem or "The shared agent connection is unavailable.") end
		s.catalog = nil; query(cx, s)
	end
	local migration_round: any
	local migration_decide: any
	local function migration_fail(cx: WindowCx, s: any, message: string)
		pending[s.source] = nil
		local detail = message .. " Existing work and uncertain outcomes are retained; no step was repeated."
		if s.complete then s.complete(cx, false, detail) else fail(cx, detail) end
	end
	local function migration_current(cx: WindowCx, s: any): any?
		local current = live(cx, s)
		if not current or current.authority_namespace ~= s.authority_namespace or current.authority_revision ~= s.authority_revision
			or s.source_sha256 ~= nil and current.source_sha256 ~= s.source_sha256 then return nil end
		return current
	end
	local function migration_spawn(cx: WindowCx, s: any, operation: string, done: any)
		local current = migration_current(cx, s)
		if not current then return migration_fail(cx, s, "Update context changed before the next agent-source observation.") end
		local request: any = { operation = operation }
		if operation == "bootstrap" then
			request.creation = api.copy(s.creation)
		elseif operation ~= "source" then
			if not migration_source(current, "orch") or not migration_source(s.peer, "spawn") then
				return migration_fail(cx, s, "A complete exact source qualification is missing.")
			end
			request.expected = api.copy(s.peer.qualification.proof)
			request.peer = api.copy(current)
		end
		local wait: any = { started = tern.now(), done = done, operation = operation, expected = request.expected }
		s.peer_wait = wait; pending[s.source] = s
		api.migrate(cx, s.source, s.origin, request, function(_fresh: WindowCx, peer: any, problem: string?, relay_proof: any?, code: string?)
			if pending[s.source] ~= s or s.peer_wait ~= wait or wait.received then return end
			wait.received = true; wait.peer = peer; wait.problem = problem; wait.relay_proof = relay_proof; wait.code = code
		end)
	end
	local function migration_orch(cx: WindowCx, s: any, operation: string, done: any)
		if not migration_current(cx, s) or not migration_source(s.peer, "spawn") or not s.relay_proof then
			return migration_fail(cx, s, "The current paired source observation is unavailable.")
		end
		local request = { source_nonce = s.nonce, setup_origin = s.origin, operation = operation, peer = s.peer.qualification,
			relay_proof = s.relay_proof,
			intent = { request_id = api.id(), authority_namespace = s.authority_namespace,
				expected_revision = s.authority_revision, source_sha256 = s.source_sha256 } }
		local bytes = tern.json.encode(request)
		if #bytes > codec.LIMITS.logical then return migration_fail(cx, s, "Complete migration evidence exceeds the native bound.") end
		s.wait = { id = request.intent.request_id, started = tern.now(), writes_config = false, done = function(fresh: WindowCx)
			local current = live(fresh, s)
			if not migration_source(current, "orch") or current.authority_namespace ~= s.authority_namespace
				or current.authority_revision ~= s.authority_revision + (if operation == "inspect" then 0 else 1)
				or operation == "inspect" and s.source_sha256 ~= nil and current.source_sha256 ~= s.source_sha256 then
				return migration_fail(fresh, s, "The acknowledged update has no matching complete current source proof.")
			end
			s.authority_revision = current.authority_revision; s.source_sha256 = current.source_sha256
			done(fresh)
		end }
		pending[s.source] = s
		cx.session:event(s.source, { ev = "action", id = "main.migration-state", act = "migration-command", value = bytes })
	end
	migration_round = function(cx: WindowCx, s: any)
		migration_spawn(cx, s, "source", function(fresh: WindowCx)
			migration_orch(fresh, s, "inspect", function(next_cx: WindowCx)
				migration_spawn(next_cx, s, "inspect", function(last: WindowCx) migration_decide(last, s) end)
			end)
		end)
	end
	migration_decide = function(cx: WindowCx, s: any)
		local owner, operation = migration_next(migration_current(cx, s), s.peer)
		if not owner then return migration_fail(cx, s, operation or "The paired update is held.") end
		if owner == "complete" then
			pending[s.source] = nil
			if s.complete then s.complete(cx, true)
			else cx:toast("info", "Orchestration updated", "Both connected components agree. Existing work and unresolved outcomes were preserved.") end
			return
		end
		if not operation then return migration_fail(cx, s, "The paired source has no valid next operation.") end
		local step = owner .. ":" .. operation
		if s.steps[step] then return migration_fail(cx, s, "The update did not advance to a verifiable next stage.") end
		s.steps[step] = true
		local done = function(fresh: WindowCx) migration_round(fresh, s) end
		if owner == "spawn" then migration_spawn(cx, s, operation, done)
		else migration_orch(cx, s, operation, done) end
	end
	local function start(cx: WindowCx, source: number, command: string, intent: any?, first_use: any?)
		local function refused(message: string)
			if first_use then first_use.done(cx, false, message) else fail(cx, message) end
		end
		if pending[source] then return refused("A settings operation is awaiting its result. Nothing was repeated.") end
		if command == "spawn" then
			-- A cold authority has no setup-index. Navigation needs only the actual native source.
			local binding = origin(cx, source, nil)
			if not binding then return fail(cx, "Setup requires a live ORCH view in this native session on the connected execution host.") end
			return spawn_managed(cx, { source = source, origin = binding })
		end
		local operation = command:match("^migration_(%a+)$")
		if operation then
			local data = migration_index(cx, source)
			local binding = if data then origin(cx, source, data) else nil
			if not binding or operation ~= "update" then return refused("A current native Update / reconnect control is required.") end
			local captured = intent or { authority_namespace = data.authority_namespace, expected_revision = data.authority_revision, source_sha256 = data.source_sha256 }
			local s = { source = source, nonce = data.source_nonce, origin = binding, migration = true, steps = {},
				authority_namespace = captured.authority_namespace, authority_revision = captured.expected_revision,
				source_sha256 = captured.source_sha256, creation = if first_use then api.copy(first_use.creation) else nil,
				complete = if first_use then first_use.done else nil }
			return migration_round(cx, s)
		end
		local data = index(cx, source)
		local binding = if data then origin(cx, source, data) else nil
		if not binding then return fail(cx, "Setup requires a live ORCH view in this native session on the connected execution host.") end
		if not data.installation_defaults then return fail(cx, "Saved settings are unavailable. Return to the orchestration to complete first use or reconnect existing data; no previous settings were replaced.") end
		local defaults = api.copy(data.installation_defaults)
		local s = { source = source, nonce = data.source_nonce, origin = binding, revision = data.installation_defaults.revision,
			authority_namespace = if intent then intent.authority_namespace else data.authority_namespace,
			authority_revision = if intent then intent.expected_revision else data.authority_revision,
			defaults = defaults, wizard = command == "setup" or command == "wizard", adopt = data.setup.review_existing == true }
		s.reload = function(fresh: WindowCx)
			drafts[source] = nil; api.forms.cancel(fresh, source); start(fresh, source, command)
		end
		if command == "dismiss" then return send(cx, s, "setup_lifecycle", { state = "dismissed" }, function(fresh: WindowCx) fresh:toast("info", "Setup dismissed", "Your saved configuration is unchanged.") end) end
		local flow, owner = api.flow(cx, source), api.origin(cx, source)
		if flow and owner then s.session_origin = owner; s.previous = api.copy(flow.policy) end
		if command == "session" or command == "save_defaults" then
			if not flow or not owner then return fail(cx, "Reconnect this orchestration before changing its settings. No ownership was assumed.") end
			s.defaults.policy = api.copy(flow.policy); s.session = true
		end
		-- Reopening never replaces native unsaved input with a background snapshot.
		local previous = drafts[source]
		if previous and previous.nonce == s.nonce and previous.session == s.session then
			if api.forms.active(source, "settings") and api.forms.focus(cx, source) then return end
			menu(cx, previous); return
		end
		drafts[source] = s
		catalog(cx, s, function(fresh: WindowCx) menu(fresh, s) end)
	end
	local function ready(cx: WindowCx, source: number, done: any)
		local data = index(cx, source); local binding = if data then origin(cx, source, data) else nil
		if not data or not binding or not data.installation_defaults then done(cx, false, "Agent setup status is unavailable on this execution machine. Open SPAWN to inspect setup; no saved agents were changed."); return end
		if pending[source] then done(cx, false, "An agent setup observation is already pending."); return end
		local s = { source = source, nonce = data.source_nonce, origin = binding,
			revision = data.installation_defaults.revision, authority_namespace = data.authority_namespace,
			authority_revision = data.authority_revision, defaults = api.copy(data.installation_defaults), ready_done = done }
		catalog(cx, s, function(fresh: WindowCx)
			if s.ready_done then local finish = s.ready_done; s.ready_done = nil; finish(fresh, true) end
		end)
	end
	local function tick(cx: WindowCx)
		for source, item in feedbacks do
			if drafts[source] ~= item.draft then feedbacks[source] = nil
			elseif api.forms.active(source, "settings") and api.forms.update(cx, source, item.value) then feedbacks[source] = nil end
		end
		for source, s in pending do
			local function stopped(message: string)
				pending[source] = nil
				s.instance_wait = nil
				if s.ready_done then local done = s.ready_done; s.ready_done = nil; done(cx, false, message)
				else feedback(cx, s, message .. " Entered values are retained; no operation was repeated.") end
			end
			-- Native identity survives a hidden surface or a different current UI scope.
			-- A retained settings form can act from its own tab; migration still requires its source view.
			local binding = identity(cx, source, nil)
			if binding then binding.host_pane_id = s.origin.host_pane_id end
			if not api.same(binding, s.origin) then
				if s.migration then migration_fail(cx, s, "The native update identity changed.") else stopped("The native settings identity changed.") end
				continue
			end
			local data = if s.migration then migration_index(cx, source) else index(cx, source)
			if data and (data.source_nonce ~= s.nonce or not api.same(identity(cx, source, data), s.origin)) then
				if s.migration then migration_fail(cx, s, "The update source incarnation changed.") else stopped("The settings source reloaded.") end
				continue
			end
			local in_scope = origin(cx, source, nil, not s.migration and api.forms.active(source, "settings")) ~= nil
			if in_scope and not data then
				if s.migration then migration_fail(cx, s, "The current update source is unavailable.") else stopped("The settings source is unavailable.") end
				continue
			end
			if s.instance_wait then
				if tern.now() - s.instance_wait.started > 30000 then
					s.instance_wait = nil; pending[source] = nil
					feedback(cx, s, "Instance-save result unavailable. Entered values remain; inspect saved settings before another deliberate save. No operation was repeated.")
				end
			elseif s.peer_wait then
				local wait = s.peer_wait
				if not in_scope then continue end
				if wait.received then
					s.peer_wait = nil
					if wait.problem ~= nil and wait.operation == "source" and wait.code == "source_absent"
						and s.creation and not s.bootstrap_attempted then
						s.bootstrap_attempted = true
						migration_spawn(cx, s, "bootstrap", function(fresh: WindowCx) migration_round(fresh, s) end)
					elseif wait.problem ~= nil then migration_fail(cx, s, tostring(wait.problem))
					elseif not migration_current(cx, s) or not migration_source(wait.peer, "spawn") or not migration_relay(wait.relay_proof) then
						migration_fail(cx, s, "The agent update returned no complete matching native source receipt.")
					elseif wait.operation == "inspect" and not api.same(wait.peer.qualification.proof, wait.expected)
						or wait.operation ~= "source" and wait.operation ~= "inspect" and wait.operation ~= "bootstrap"
							and (wait.peer.authority_revision ~= wait.expected.source_revision + 1
								or wait.peer.spawn_namespace ~= wait.expected.candidate_namespace) then
						migration_fail(cx, s, "The agent acknowledgement no longer names the exact observed transition.")
					else
						s.peer = wait.peer; s.relay_proof = wait.relay_proof
						wait.done(cx)
					end
				elseif tern.now() - wait.started > 30000 then
					migration_fail(cx, s, "The agent update result is unavailable. Reconnect to inspect its current source.")
				end
			elseif s.wait then
				local result = if data then data.setup_result or data.result else nil
				if not s.wait.result and result and result.request_id == s.wait.id then
					s.wait.result = result
				end
				if not in_scope then continue end
				result = s.wait.result
				if result then
					local done, writes_config = s.wait.done, s.wait.writes_config
					s.wait = nil; pending[source] = nil
					if result.ok ~= true then
						local message = tostring(result.message or result.code or "Setup write refused; reopen current settings.")
						if s.migration then migration_fail(cx, s, message) else feedback(cx, s, message) end
					elseif writes_config and (type(result.config_revision) ~= "number" or result.config_revision < 0
						or result.config_revision > 9007199254740991 or result.config_revision % 1 ~= 0) then
						feedback(cx, s, "Setup write returned no valid revision. Entered values remain; inspect current settings before retrying.")
					else
						-- A successful previous step creates the next wizard step; never upgrade a retry.
						if writes_config then
							s.revision = result.config_revision
							s.authority_revision = result.revision
						end
						done(cx, result)
					end
				elseif tern.now() - s.wait.started > 30000 then
					if s.migration then migration_fail(cx, s, "The update result is unavailable.")
					else pending[source] = nil; feedback(cx, s, "Setup result unavailable. Entered values remain; inspect saved defaults before retrying. No write was repeated.") end
				end
			elseif s.query then
				if not s.sent and type(s.bridge) == "table" and s.bridge.retired then
					s.bridge = api.transport(cx, source, s.origin)
					if not s.bridge then continue end
				end
				local node, bytes = api.surface(cx, s.bridge, "spawn.dispatch", "spawn.dispatch.response", nil, 65536)
				if not s.sent and in_scope and node and tern.now() - s.query_started <= 30000 then
					local _, published = api.surface(cx, source, "orchplus.orchestrator", "orchplus.setup.request", "setup-catalog-request", 8192)
					local published_request = if published then api.decode(published, 8192) else nil
					if api.same(published_request, s.query) then
						s.sent = api.event(cx, s.bridge, { act = "catalog", value = published })
					end
				end
				if s.sent and not s.reply and bytes then
					local reply = api.decode_setup_response(bytes, s.query)
					if reply and reply.status ~= "pending" then s.reply = reply; api.ack(cx, s.bridge, "response") end
				end
				if not in_scope then continue end
				local reply = s.reply
				-- Observe a correlated reply before applying the original bounded deadline.
				if not reply then
					if tern.now() - s.query_started > 30000 then send(cx, s, "catalog_clear", {}); catalog_failure(cx, s, "SPAWN catalog did not answer. Setup is not inferred from saved records.") end
					continue
				end
				pending[source] = nil; s.reply = nil; send(cx, s, "catalog_clear", {})
				local payload = reply.payload
				if s.page_done then
					local done = s.page_done; s.page_done = nil; s.query = nil
					if reply.status == "catalog" then done(payload, nil)
					else done(nil, "SPAWN setup catalog unavailable/incompatible: " .. tostring(if reply.error then reply.error.message or reply.error.code else reply.status)) end
					continue
				end
				if reply.status ~= "catalog" then
					catalog_failure(cx, s, "SPAWN setup catalog unavailable/incompatible: " .. tostring(if reply.error then reply.error.message or reply.error.code else reply.status)); continue
				end
				if not s.catalog then s.catalog = payload else
					if s.catalog.config_revision ~= payload.config_revision or s.catalog.revision ~= payload.revision
						or s.catalog.namespace ~= payload.namespace or s.catalog.host_key ~= payload.host_key
						or not api.same(s.catalog.setup, payload.setup) then catalog_failure(cx, s, "Agent catalog changed while loading. No mixed account list was used."); continue end
					for _, record in payload.records do table.insert(s.catalog.records, record) end
				end
				if payload.next_cursor then query(cx, s, payload.next_cursor); continue end
				s.query = nil
				if s.ready_done and #s.catalog.records == 0 then
					catalog_failure(cx, s, "No agent setup found in SPAWN. Set up agents first.")
				elseif s.ready_done and payload.setup.state ~= "completed" and payload.setup.state ~= "adopted_existing" then
					catalog_failure(cx, s, "Your saved agents are available. In SPAWN, prepare them for ORCH+ so it can start agents and receive progress. Optional provider-readiness checks are separate.")
				elseif s.catalog_done then local done = s.catalog_done; s.catalog_done = nil; done(cx) end
			end
		end
	end
	return { start = start, ready = ready, tick = tick, active = function(source: number): boolean return pending[source] ~= nil end }
end
return M
