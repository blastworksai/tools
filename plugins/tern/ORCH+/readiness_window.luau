--!strict
-- Optional real exercise. Never substitutes catalog presence or worker prose for a landed result.
local M = {}
function M.new(api: any): any
	local runs: any = {}
	local function toast(cx: WindowCx, message: string) cx:toast("info", "ORCH+ optional readiness", message) end
	-- The host publishes every readiness outcome as its own receipt keyed by request id, so a newer repository result
	-- or a late refusal cannot replace it before this window reads it. The shared result slot stays a fallback.
	local function readiness_outcome(data: any?, request: string?): any?
		if not data or request == nil then return nil end
		local receipts = data.readiness_receipts
		local own = if type(receipts) == "table" then receipts[request] else nil
		if own then return own end
		local result = data.setup_result
		return if result and result.request_id == request then result else nil
	end
	local function persist(cx: WindowCx, source: number, data: any, state: string, summary: string, run: any?)
		local request_id = api.id()
		cx.session:event(source, { ev = "action", id = "main.setup-index", act = "setup-command", value = tern.json.encode({
			kind = "setup_lifecycle", source_nonce = data.source_nonce, request_id = request_id,
			authority_namespace = data.authority_namespace, expected_revision = data.authority_revision,
			expected_config_revision = data.installation_defaults.revision,
			readiness = { state = state, config_revision = data.installation_defaults.revision, summary = summary },
			readiness_policy = if state == "passed" and run then { logical_session_id = run.origin.logical_session_id, revision = run.policy_revision } else nil }) })
		return request_id
	end
	local function policy_current(cx: WindowCx, source: number, revision: number, expected: any): boolean
		local flow = api.flow(cx, source)
		return flow ~= nil and flow.policy_revision == revision and api.same(flow.policy, expected)
	end
	-- The checkout path exists only once preparation succeeded.
	local function retained(run: any): string
		return if run.path then " Disposable repository retained at " .. run.path .. "." else ""
	end
	local function finish(cx: WindowCx, run: any, state: string, message: string)
		if runs[run.source] ~= run or run.phase == "finishing" then return end
		if not api.current(cx, run.source, run.origin) or not policy_current(cx, run.source, run.policy_revision, run.policy) then
			state = "unavailable"; message = "Session policy or controller changed during readiness; the original policy was not qualified."
		end
		local data = api.setup(cx, run.source)
		if data and data.source_nonce == run.nonce and data.installation_defaults.revision == run.revision then
			local request = persist(cx, run.source, data, state, message, run)
			run.phase = "finishing"; run.result_request = request; run.result_message = message; run.finishing_started = tern.now()
			return
		else message ..= " Configuration changed; this result was not attached to newer defaults." end
		runs[run.source] = nil
		toast(cx, message .. retained(run) .. " Live workers are not silently stopped or retried.")
	end
	local function launch(cx: WindowCx, run: any, catalog: any)
		local record
		for _, row in catalog.records do if row.id == run.builder then record = row end end
		if not record or not record.eligible or record.enabled ~= true or not table.find(record.capabilities or {}, "check-runner-v1") then
			return finish(cx, run, "unavailable", "Configured builder has no eligible check-runner route.")
		end
		local signer = if run.policy.merge_actor_mode == "worker" then record else nil
		if run.policy.merge_actor_mode == "selected_record" then
			for _, row in catalog.records do if row.id == run.policy.release_manager_record then signer = row end end
		end
		if not signer or not signer.enabled or not signer.eligible or not table.find(signer.capabilities or {}, "release-manager-v1") then
			return finish(cx, run, "unavailable", "The configured merge actor needs managed merge capability. In Same agent as worker mode, the existing worker performs the merge; text and research do not need it.")
		end
		local task = "Optional ORCH readiness exercise. Operate ONLY in this disposable repository: " .. run.path
			.. ". Your configured launch cwd is not the task repository. Do not modify it. Create and check out branch orch-readiness-work from refs/heads/main; do not leave main checked out during release-manager landing."
			.. " Add readiness.txt containing ready and commit it. Run the packaged mailbox helper with its process working directory set to " .. run.path .. ": mode checkout publishes actual CHECKOUT; mode run-checks with check id readiness publishes CHECK_RESULT. Do not invent a --cwd helper flag."
			.. " checkpoint.worktree_ref must equal that absolute path. Declared check readiness runs git -C " .. run.path .. " cat-file -e HEAD:readiness.txt."
			.. " Publish CHECKPOINT and REVIEW_READY as required by current policy, then LANDING_REQUEST for project orch-readiness, repo_ref " .. run.path
			.. ", target_ref refs/heads/main, source_ref refs/heads/orch-readiness-work, with actual current source/target revisions."
			.. " The release manager must use that absolute repo_ref, not its configured launch cwd, and preserve the checked-out source branch while applying the ordinary expected-target guarded landing flow."
			.. " Use the ordinary review, owner approval and release-manager landing flow; never claim checks/review/landing that did not happen. No deployment applies."
		run.request = api.queue(cx, run.source, run.origin, { record_id = record.id, record_revision = record.revision, catalog_revision = catalog.revision,
			coordinator = false, cwd = record.cwd, placement = record.placement, execution_cwd = run.repository.cwd,
			presentation = "user_new_tab", orch_project_id = run.project, prompt = task, base_ref = "refs/heads/main",
			files = tern.json.array({ "readiness.txt" }), checks = tern.json.array({ { check_id = "readiness", argv = tern.json.array({ "git", "-C", run.path, "cat-file", "-e", "HEAD:readiness.txt" }) } }) })
		if not run.request then return finish(cx, run, "unavailable", "Controller changed before the exercise could be queued.") end
		run.phase = "queued"
		toast(cx, "Real provider task queued. Answer ordinary review/landing owner gates in ORCH+. Readiness passes only after a matching landed result and Git readback; observation stops after 15 minutes.")
	end
	local function prepare(cx: WindowCx, run: any)
		if not policy_current(cx, run.source, run.policy_revision, run.policy) or not api.current(cx, run.source, run.origin) then
			return finish(cx, run, "unavailable", "Settings or controller changed before exercise preparation.")
		end
		run.phase, run.request = "repository_probe", api.id()
		cx.session:event(run.source, { ev = "action", id = "main.setup-index", act = "setup-readiness-prepare",
			value = tern.json.encode({ source_nonce = run.nonce, request_id = run.request }) })
	end
	local function start(cx: WindowCx, source: number, intent: any?)
		if runs[source] then return toast(cx, "A readiness exercise is already observed in this window. It is never launched twice.") end
		local data, origin = api.setup(cx, source), api.origin(cx, source)
		if not data then return toast(cx, "Open ORCH+ and complete required setup first.") end
		data = table.clone(data)
		if intent and intent.authority_namespace ~= nil then
			data.authority_namespace = intent.authority_namespace
			data.authority_revision = intent.expected_revision
		end
		if not origin then
			api.open_controller(cx, source)
			return toast(cx, "Reconnect this orchestration before running the optional exercise. Unknown ownership has not been cleared.")
		end
		if data.setup.state ~= "completed" and data.setup.state ~= "adopted_existing" then return toast(cx, "Complete agent setup first. This optional exercise does not replace missing account or capability prerequisites.") end
		local flow = api.flow(cx, source)
		if not flow or type(flow.policy_revision) ~= "number" or not api.same(flow.policy, data.installation_defaults.policy) then return toast(cx, "This session has overrides different from installation defaults. Use a new session seeded from current defaults to exercise those defaults; overrides will not be overwritten.") end
		if flow.policy.paused then return toast(cx, "This orchestration is paused. Resume explicitly before running a provider exercise; opening readiness never resumes work.") end
		if flow.policy.merge_actor_mode == "selected_record" and (not flow.policy.release_manager_record or flow.policy.release_manager_record == "") then
			persist(cx, source, data, "unavailable", "Choose the selected merge agent, or use Same agent as worker. Text and research setup remains complete.")
			return toast(cx, "Select a merge agent in Settings or use Same agent as worker before exercising repository merging.")
		end
		cx:pick({ placeholder = "Optional readiness — consent to a real provider task and disposable Git landing", items = {
			{ label = "Not now — keep completed setup", consent = false },
			{ label = "Run real readiness exercise", detail = "Creates a disposable repository under plugin data, launches configured workers (provider costs), runs checks/review/landing. No production repository changes.", consent = true },
		} }):next(function(choice: any, err: string?, fresh: WindowCx?)
			if not fresh or not choice or err then return end
			local current = api.setup(fresh, source)
			-- Visibility fences this delayed consent, not an already-consented exercise's observation.
			if not current or current.source_nonce ~= data.source_nonce or current.installation_defaults.revision ~= data.installation_defaults.revision
				or current.authority_namespace ~= data.authority_namespace or current.authority_revision ~= data.authority_revision
				or not policy_current(fresh, source, flow.policy_revision, data.installation_defaults.policy)
				or not api.consent_current(fresh, source, origin) then return toast(fresh, "Configuration/context changed during consent. Nothing launched.") end
			if not choice.consent then persist(fresh, source, data, "not_run", "Owner declined optional exercise; required setup remains complete."); return end
			local run = { source = source, origin = origin, nonce = current.source_nonce, revision = current.installation_defaults.revision,
				policy_revision = flow.policy_revision, policy = data.installation_defaults.policy,
				builder = current.installation_defaults.builder_record, started = tern.now(), phase = "consent" }
			runs[source] = run
			run.consent_request = persist(fresh, source, data, "unavailable", "Exercise consented; result unconfirmed. A private disposable checkout will be created on the current execution host. Reload/interruption never implies success.")
		end)
	end
	local function tick(cx: WindowCx)
		for _, run in runs do
			if run.phase ~= "finishing" and not api.current(cx, run.source, run.origin) then finish(cx, run, "unavailable", "Readiness observation lost its exact controller context."); continue end
			if run.phase ~= "finishing" and tern.now() - run.started > 900000 then finish(cx, run, "unavailable", "Observation ended without a confirmed landing. The outcome is unknown; inspect retained work before another exercise."); continue end
			if run.phase == "finishing" then
				local data = api.setup(cx, run.source)
				local result = if data then data.setup_result else nil
				if result and result.request_id == run.result_request then
					runs[run.source] = nil
					toast(cx, (if result.ok then run.result_message else "Readiness result was not saved: " .. tostring(result.code))
						.. retained(run))
				elseif tern.now() - run.finishing_started > 30000 then
					runs[run.source] = nil
					toast(cx, "The readiness result could not be confirmed as saved. The outcome is unknown; no exercise or result write was repeated.")
				end
				continue
			end
			if not policy_current(cx, run.source, run.policy_revision, run.policy) then finish(cx, run, "unavailable", "Session policy changed during readiness."); continue end
			if run.phase == "consent" then
				local data = api.setup(cx, run.source)
				local result = if data then data.setup_result else nil
				if result and result.request_id == run.consent_request then
					if result.ok and data.installation_defaults.revision == run.revision then run.phase = "prepare"; prepare(cx, run)
					else runs[run.source] = nil; toast(cx, "Readiness consent could not be persisted; nothing launched.") end
				end
			elseif run.phase == "repository_probe" then
				local result = readiness_outcome(api.setup(cx, run.source), run.request)
				if result then
					if not result.ok or type(result.repository) ~= "table" then
						finish(cx, run, "unavailable", "Disposable repository verification failed: " .. tostring(result.message or result.code))
					else
						run.repository = table.clone(result.repository); run.repository.queue_route = "orch_queue"
						run.path = run.repository.cwd
						run.decision_fields = { name = "Optional readiness exercise" }; run.decision_command = "new_project"
						run.request = api.decision(cx, run.source, run.origin, run.decision_command, run.decision_fields)
						run.phase = "project_decision"
						if not run.request then finish(cx, run, "unavailable", "Controller changed before reviewing the disposable exercise project.") end
					end
				end
			elseif run.phase == "new_project" or run.phase == "project_repository" or run.phase == "project_start" then
				local snapshot = api.snapshot(cx, run.source)
				local result = if not snapshot then nil
					elseif snapshot.command_result and snapshot.command_result.request_id == run.request then snapshot.command_result
					elseif snapshot.driver_result and snapshot.driver_result.request_id == run.request then snapshot.driver_result
					elseif snapshot.result and snapshot.result.request_id == run.request then snapshot.result else nil
				if result and result.request_id == run.request then
					if not result.ok then finish(cx, run, "unavailable", "Exercise preparation refused: " .. tostring(result.message or result.code)); continue end
					if run.phase == "project_start" then
						run.phase = "catalog"
						api.catalog(cx, run.source, run.origin, function(fresh: WindowCx, catalog: any?, problem: string?)
							if runs[run.source] ~= run or run.phase ~= "catalog" then return end
							if not api.current(fresh, run.source, run.origin) or not policy_current(fresh, run.source, run.policy_revision, run.policy) then
								return finish(fresh, run, "unavailable", "Readiness context changed while loading the agent catalog.")
							end
							if not catalog then return finish(fresh, run, "unavailable", problem or "The current agent catalog could not be loaded.") end
							launch(fresh, run, catalog)
						end)
						continue
					end
					if run.phase == "new_project" then run.project = result.orch_project_id end
					local context = if run.project then api.project_context(cx, run.source, run.origin, run.project) else nil
					if not context then finish(cx, run, "unavailable", "The disposable exercise project has no current decision context."); continue end
					local fields = { orch_project_id = run.project, project_revision = context.project_revision or context.revision }
					if run.phase == "new_project" then
						fields.repository = run.repository; run.phase = "project_decision"
						run.decision_fields = fields; run.decision_command = "project_repository"
					else
						fields.decision_context = context.decision_context; run.phase = "project_start"
					end
					run.request = if run.phase == "project_decision" then api.decision(cx, run.source, run.origin, run.decision_command, fields)
						else api.command(cx, run.source, run.origin, run.phase, fields)
					if not run.request then finish(cx, run, "unavailable", "Controller changed before the next exercise step; no step was repeated.") end
				end
			elseif run.phase == "project_decision" then
				local result = api.decision_result(cx, run.source)
				if result and result.request_id == run.request then
					if not result.decision_context then finish(cx, run, "unavailable", "The disposable project or repository decision changed."); continue end
					run.decision_fields.decision_context = result.decision_context
					run.request = api.command(cx, run.source, run.origin, run.decision_command, run.decision_fields)
					run.decision_fields = nil; run.phase = run.decision_command; run.decision_command = nil
					if not run.request then finish(cx, run, "unavailable", "Controller changed before saving the disposable project decision; nothing was repeated.") end
				end
			elseif run.phase == "queued" then
				local snapshot = api.snapshot(cx, run.source)
				local result = if snapshot then snapshot.driver_result else nil
				if result and result.request_id == run.request then
					if result.ok == false then finish(cx, run, "failed", "Readiness dispatch refused: " .. tostring(result.code))
					elseif result.worker_id then run.worker = result.worker_id; run.phase = "landing" end
				end
			elseif run.phase == "landing" then
				local observation = api.observation(cx, run.source)
				for _, item in (if observation then observation.landings else {}) do
					if item.worker_id ~= run.worker or item.repo_ref ~= run.path then continue end
					if item.status == "failed" or item.status == "cancelled" then finish(cx, run, "failed", "Readiness landing " .. item.status); break end
					if item.status == "landed" then
						run.phase = "readback"
						run.request = api.id()
						cx.session:event(run.source, { ev = "action", id = "main.setup-index", act = "setup-readiness-verify",
							value = tern.json.encode({ source_nonce = run.nonce, request_id = run.request, orch_project_id = run.project }) })
						break
					end
				end
			elseif run.phase == "readback" then
				local result = readiness_outcome(api.setup(cx, run.source), run.request)
				if result then
					finish(cx, run, if result.ok and result.readiness_passed then "passed" else "failed",
						if result.ok and result.readiness_passed then "Actual managed task, helper checks and policy-gated release-manager landing confirmed by execution-host Git readback."
						else tostring(result.message or "The disposable target did not contain the readiness artifact."))
				end
			end
		end
	end
	return { start = start, tick = tick }
end
return M
