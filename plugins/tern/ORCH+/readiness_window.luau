--!strict
-- Optional real exercise. Never substitutes catalog presence or worker prose for a landed result.
local M = {}
function M.new(api: any): any
	local runs: any = {}
	local function toast(cx: WindowCx, message: string) cx:toast("info", "ORCH+ optional readiness", message) end
	local function persist(cx: WindowCx, source: number, data: any, state: string, summary: string, run: any?)
		local request_id = api.id()
		cx.session:event(source, { ev = "action", id = "main.setup-index", act = "setup-command", value = tern.json.encode({
			kind = "setup_lifecycle", source_nonce = data.source_nonce, request_id = request_id, expected_revision = data.installation_defaults.revision,
			readiness = { state = state, config_revision = data.installation_defaults.revision, summary = summary },
			readiness_policy = if state == "passed" and run then { logical_session_id = run.origin.logical_session_id, revision = run.policy_revision } else nil }) })
		return request_id
	end
	local function policy_current(cx: WindowCx, source: number, revision: number, expected: any): boolean
		local flow = api.flow(cx, source)
		return flow ~= nil and flow.policy_revision == revision and api.same(flow.policy, expected)
	end
	local function finish(cx: WindowCx, run: any, state: string, message: string)
		if runs[run.source] ~= run then return end
		if not api.current(cx, run.source, run.origin) or not policy_current(cx, run.source, run.policy_revision, run.policy) then
			state = "unavailable"; message = "Session policy or controller changed during readiness; the original policy was not qualified."
		end
		local data = api.setup(cx, run.source)
		if data and data.source_nonce == run.nonce and data.installation_defaults.revision == run.revision then
			local request = persist(cx, run.source, data, state, message, run)
			if state == "passed" then
				run.phase = "finishing"; run.result_request = request; run.result_message = message
				return
			end
		else message ..= " Configuration changed; this result was not attached to newer defaults." end
		runs[run.source] = nil
		toast(cx, message .. " Disposable repository retained at " .. run.path .. ". Live workers are not silently stopped or retried.")
	end
	local function launch(cx: WindowCx, run: any, catalog: any)
		local record
		for _, row in catalog.records do if row.id == run.builder then record = row end end
		if not record or not record.eligible or record.enabled ~= true or not table.find(record.capabilities or {}, "check-runner-v1") then
			return finish(cx, run, "unavailable", "Configured builder has no eligible check-runner route.")
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
			coordinator = false, cwd = record.cwd, placement = record.placement, prompt = task, base_ref = "refs/heads/main",
			files = tern.json.array({ "readiness.txt" }), checks = tern.json.array({ { check_id = "readiness", argv = tern.json.array({ "git", "-C", run.path, "cat-file", "-e", "HEAD:readiness.txt" }) } }) })
		if not run.request then return finish(cx, run, "unavailable", "Controller changed before the exercise could be queued.") end
		run.phase = "queued"
		toast(cx, "Real provider task queued. Answer ordinary review/landing owner gates in ORCH+. Readiness passes only after a matching landed result and Git readback; observation stops after 15 minutes.")
	end
	local function prepare(cx: WindowCx, run: any)
		local ok, problem = pcall(function() tern.fs.mkdir(run.path) end)
		if not ok then return finish(cx, run, "unavailable", "Disposable directory creation failed: " .. tostring(problem):sub(1, 300)) end
		local steps = {
			{ "git", "init", "--initial-branch=main", run.path },
			{ "git", "-C", run.path, "config", "--local", "user.name", "ORCH readiness" },
			{ "git", "-C", run.path, "config", "--local", "user.email", "orch-readiness@localhost" },
			{ "git", "-C", run.path, "-c", "user.name=ORCH readiness", "-c", "user.email=orch-readiness@localhost", "commit", "--allow-empty", "-m", "Readiness baseline" },
		}
		local function step(fresh: WindowCx, position: number)
			if runs[run.source] ~= run then return end
			if not policy_current(fresh, run.source, run.policy_revision, run.policy) then return finish(fresh, run, "unavailable", "Session policy changed before readiness launch.") end
			if not api.current(fresh, run.source, run.origin) then return finish(fresh, run, "unavailable", "Native controller context changed before readiness launch.") end
			if not steps[position] then run.phase = "catalog"; api.catalog(fresh, run.source, run.origin); return end
			tern.process.run(steps[position], { timeout_ms = 10000 }, function(result: any, next_cx: WindowCx?)
				if not next_cx then return end
				if result.status ~= 0 then finish(next_cx, run, "failed", "Disposable Git initialization failed: " .. tostring(result.stderr):sub(1, 300))
				else step(next_cx, position + 1) end
			end)
		end
		step(cx, 1)
	end
	local function start(cx: WindowCx, source: number)
		if runs[source] then return toast(cx, "A readiness exercise is already observed in this window. It is never launched twice.") end
		local data, origin = api.setup(cx, source), api.origin(cx, source)
		if not data then return toast(cx, "Open ORCH+ and complete required setup first.") end
		if not origin then
			api.open_controller(cx, source)
			return toast(cx, "Select/register a distinct logical session and explicitly claim/continue its controller in ORCH+, then run Optional readiness again. No controller was fabricated.")
		end
		if cx.hosts:current().kind == "remote" then persist(cx, source, data, "unavailable", "Optional local readiness needs the same-user local execution host; remote setup remains completed."); return toast(cx, "This exercise requires the local execution host; remote configuration was not changed.") end
		if data.setup.state ~= "completed" and data.setup.state ~= "adopted_existing" then return toast(cx, "Finish required setup first. Optional exercise cannot stand in for provisioning/probe attestation.") end
		local flow = api.flow(cx, source)
		if not flow or type(flow.policy_revision) ~= "number" or not api.same(flow.policy, data.installation_defaults.policy) then return toast(cx, "This session has overrides different from installation defaults. Use a new session seeded from current defaults to exercise those defaults; overrides will not be overwritten.") end
		cx:pick({ placeholder = "Optional readiness — consent to a real provider task and disposable Git landing", items = {
			{ label = "Not now — keep completed setup", consent = false },
			{ label = "Run real readiness exercise", detail = "Creates a disposable repository under plugin data, launches configured workers (provider costs), runs checks/review/landing. No production repository changes.", consent = true },
		} }):next(function(choice: any, err: string?, fresh: WindowCx?)
			if not fresh or not choice or err then return end
			local current = api.setup(fresh, source)
			-- Visibility fences this delayed consent, not an already-consented exercise's observation.
			if not current or current.source_nonce ~= data.source_nonce or current.installation_defaults.revision ~= data.installation_defaults.revision
				or not policy_current(fresh, source, flow.policy_revision, data.installation_defaults.policy)
				or not api.consent_current(fresh, source, origin) then return toast(fresh, "Configuration/context changed during consent. Nothing launched.") end
			if not choice.consent then persist(fresh, source, current, "not_run", "Owner declined optional exercise; required setup remains complete."); return end
			local run = { source = source, origin = origin, nonce = current.source_nonce, revision = current.installation_defaults.revision,
				policy_revision = flow.policy_revision, policy = data.installation_defaults.policy,
				path = tern.plugin.data .. "/readiness-" .. api.id(), builder = current.installation_defaults.builder_record, started = tern.now(), phase = "consent" }
			runs[source] = run
			run.consent_request = persist(fresh, source, current, "unavailable", "Exercise consented; result unconfirmed. Reload/interruption never implies success. Repository: " .. run.path)
		end)
	end
	local function tick(cx: WindowCx)
		for _, run in runs do
			if not api.current(cx, run.source, run.origin) then finish(cx, run, "unavailable", "Readiness observation lost its exact controller context."); continue end
			if tern.now() - run.started > 900000 then finish(cx, run, "failed", "Readiness deadline elapsed without confirmed landing; inspect retained workflow and workers."); continue end
			if run.phase == "finishing" then
				local data = api.setup(cx, run.source)
				local result = if data then data.setup_result else nil
				if result and result.request_id == run.result_request then
					runs[run.source] = nil
					toast(cx, (if result.ok then run.result_message else "Readiness result was not saved: " .. tostring(result.code))
						.. " Disposable repository retained at " .. run.path .. ".")
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
			elseif run.phase == "catalog" then
				local observation = api.observation(cx, run.source)
				if observation and observation.catalog then launch(cx, run, observation.catalog) end
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
						tern.process.run({ "git", "-C", run.path, "show", "refs/heads/main:readiness.txt" }, { timeout_ms = 10000 }, function(result: any, fresh: WindowCx?)
							if fresh then finish(fresh, run, if result.status == 0 and result.stdout:match("^ready%s*$") then "passed" else "failed", if result.status == 0 and result.stdout:match("^ready%s*$") then "Actual managed task, helper checks and policy-gated release-manager landing confirmed by Git readback." else "Landing reported but disposable target readback did not match readiness artifact.") end
						end)
						break
					end
				end
			end
		end
	end
	return { start = start, tick = tick }
end
return M
