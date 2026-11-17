--!strict
local codec = require("./wire/codec")
local provider_display = require("./provider_display")
local selectors = require("./selectors")
local M = {}
-- Native conversations stay native. This module owns only explicit choices and their one-shot
-- host submissions; a lost response is never converted into another launch/enrollment.
function M.new(api: any): any
	local jobs: any = {}
	local drafts: any = {}
	local starts: any = {}
	local decisions: any = {}
	local repositories: any = {}
	local repository_drafts: any = {}
	local function problem(cx: any, source: number, origin: any, text: string, metadata: any?)
		api.notice(cx, source, origin.alias_nonce, text, "error", nil, metadata)
	end
	local function projects(cx: any, source: number): any
		local index = api.node(cx, source, "project-index", "orchplus.projects")
		return if index then index.projects or {} else {}
	end
	local function ask(cx: any, source: number, origin: any, title: string, items: any, done: any)
		api.forms.choose(cx, source, origin, { placeholder = title, items = items }, function(fresh: any, choice: any)
			if choice and api.current(fresh, source, origin) then done(fresh, choice) end
		end)
	end
	local function submit(cx: any, source: number, origin: any, command: string, fields: any, done: any?, initial_creation: string?)
		if jobs[source] or decisions[source] then return problem(cx, source, origin, "The previous action is still settling. Nothing was sent twice.") end
		if command == "new_project" and fields.decision_context == nil then
			local id = api.decision(cx, source, origin, command, fields)
			if id then decisions[source] = { request_id = id, command = command, origin = origin, fields = fields, done = done,
				initial_creation = initial_creation, at = tern.now() } end
			return
		end
		local id = api.send(cx, source, origin, command, fields, true)
		if id then
			local drafts = repository_drafts[source]
			local draft = if command == "project_repository" and drafts then drafts[fields.orch_project_id] else nil
			jobs[source] = { request_id = id, origin = origin, done = done, at = tern.now(), command = command,
				form_tag = if draft then draft.form_tag else nil, initial_creation = initial_creation }
		end
	end
	local function choose_project(cx: any, source: number, origin: any, preferred: string?, done: any)
		local choices = { { label = "New project…", new = true } }
		for id, project in projects(cx, source) do
			if not project.finished then table.insert(choices, { label = project.name, project_id = id, current = id == preferred }) end
		end
		ask(cx, source, origin, "Choose a project", choices, function(fresh: any, choice: any)
			if choice.project_id then return done(fresh, api.fresh(fresh, source, origin), choice.project_id) end
			api.forms.input(fresh, source, origin, { placeholder = "New project name", value = drafts[source], confirm_label = "Add project",
				validate = function(name: string): string? return if not name:find("%S") or #name > 160 or name:find("%c") then "Use a project name of 1–160 bytes on one line." else nil end }, function(next_cx: any, name: any)
				if name == nil or not api.current(next_cx, source, origin) then return end
				drafts[source] = name
				submit(next_cx, source, api.fresh(next_cx, source, origin), "new_project", { name = name }, function(last: any, response: any)
					drafts[source] = nil
					if response.orch_project_id then done(last, api.fresh(last, source, origin), response.orch_project_id) end
				end)
			end)
		end)
	end
	local function choose_agent(cx: any, source: number, origin: any, project_id: string, coordinator: boolean?, binding: any?, delivery: string?)
		local flow = api.node(cx, source, "workflow-index", "orchplus.workflow")
		local preferred = if not binding and flow and flow.policy then
			(if coordinator then flow.policy.preferred_orchestrator_record else flow.policy.preferred_worker_record) else nil
		local options = { placeholder = if coordinator then "Choose your orchestrator" else "Choose an agent",
			need = if coordinator then "project-start-v1" else "report-files-v1" }
		if binding then
			local pane = api.pane(cx, source, tonumber(binding.pane_id), origin)
			options.pane_title = provider_display.pane_title(pane)
			options.pane_binding = binding
		end
		-- `picked` is true only for an agent the owner just chose in the picker: that is when the optional
		-- Model and Effort fields appear. A saved preferred agent keeps its zero-prompt start and its saved settings.
		local chosen_with: any
		local function chosen(fresh: any, record: any, catalog: any, picked: boolean?)
			if not record then return end
			local project = projects(fresh, source)[project_id]
			if not project or project.finished then return problem(fresh, source, origin, "The project changed. Select a current project; nothing was launched.") end
			local current = api.fresh(fresh, source, origin)
			if binding then
				local pane = api.pane(fresh, source, tonumber(binding.pane_id), current)
				if not pane then return problem(fresh, source, origin, "That conversation is no longer available on this host and session.") end
				local agent = api.agent(fresh, tonumber(binding.pane_id))
				if delivery == "native_ask" and (not agent or agent.state ~= "idle") then
					return problem(fresh, source, origin, "This native conversation is busy. Wait until it is idle, then attach; its context was not changed.")
				end
				submit(fresh, source, current, "enrol", { record_id = record.id, record_revision = record.revision,
					catalog_revision = catalog.revision, orch_project_id = project_id, pane_binding = binding, delivery = delivery })
				return
			end
			local choices = if picked then selectors.picker_choices(record.provider) else nil
			if choices ~= nil and not binding then
				-- Optional per-start model and effort. Empty keeps the agent's saved settings; nothing here edits them.
				local tag = "launch-selectors:" .. api.id()
				local rows = { { id = "model", label = "Model (exact id, optional)", kind = "text", value = "",
					description = (if record.model_variant then "Saved for this agent: " .. record.model_variant .. ". " else "") .. "Leave empty to use the saved setting, or the CLI's own default." } }
				if choices.efforts ~= nil then
					local options = { { value = "", label = "Agent default" } }
					for _, effort in choices.efforts do table.insert(options, { value = effort, label = effort }) end
					table.insert(rows, { id = "effort", label = "Effort", kind = "select", value = "", options = options })
				end
				api.forms.open(fresh, source, origin, { tag = tag, title = (if coordinator then "Orchestrator" else "Agent") .. " model and effort",
					description = "Optional. Applies to this start only; the agent's saved settings do not change.",
					fields = rows, actions = { { id = "start", label = "Start", submit = true }, { id = "cancel", label = "Back" } } },
					function(form_cx: any, values: any, action: string)
						if action ~= "start" or type(values) ~= "table" then return end
						local model = if type(values.model) == "string" then values.model:match("^%s*(.-)%s*$") else ""
						if model == "" or model == record.model_variant then model = nil end
						local effort = if values.effort ~= nil and values.effort ~= "" then values.effort else nil
						local errors = {}
						if model ~= nil then
							local why = selectors.model_error(model)
							if why then errors.model = why end
						end
						if effort ~= nil and (choices.efforts == nil or not table.find(choices.efforts, effort)) then errors.effort = "Choose one of the listed efforts." end
						if next(errors) ~= nil then api.forms.update(form_cx, source, { busy = false, errors = errors }); return end
						api.forms.update(form_cx, source, { busy = true, notice = "Starting…" })
						chosen_with(form_cx, record, catalog, model, effort)
						if api.forms.active(source, tag) then api.forms.cancel(form_cx, source) end
					end)
				return
			end
			chosen_with(fresh, record, catalog, nil, nil)
		end
		chosen_with = function(fresh: any, record: any, catalog: any, model: string?, effort: string?)
			local project = projects(fresh, source)[project_id]
			if not project or project.finished then return problem(fresh, source, origin, "The project changed. Select a current project; nothing was launched.") end
			local current = api.fresh(fresh, source, origin)
			local fields ={ record_id = record.id, record_revision = record.revision, catalog_revision = catalog.revision,
				launch_model = model, launch_effort = effort,
				orch_project_id = project_id, cwd = record.cwd, placement = record.placement,
				presentation = if coordinator then "coordinator_adjacent" else "user_new_tab",
				open_conversation = if coordinator then nil else true, coordinator = coordinator == true,
				prompt = if coordinator then "Act as the orchestrator for this conversation. Discuss the user's goals, propose held projects and sources through the coordinator protocol, and wait for an explicit project START before executing project tasks. Preserve existing work and ask only meaningful decisions."
					else codec.OPEN_CONVERSATION_ASSIGNMENT,
				execution_cwd = if project.repository then project.repository.cwd else nil }
			local flow = api.node(fresh, source, "workflow-index", "orchplus.workflow")
			if flow and flow.policy and flow.policy.quota_routing then
				api.capacity(fresh, source, current, function(last: any)
					-- Display percentages never authorize this choice. The reducer assesses actual
					-- capacity and offers a bound decision rather than silently replacing this record.
					submit(last, source, api.fresh(last, source, current), "queue", fields)
				end)
			else submit(fresh, source, current, "queue", fields) end
		end
		if preferred and preferred ~= "" then
			api.picker.load(cx, source, origin, function(fresh: any, catalog: any, why: any, metadata: any?)
				if not catalog then problem(fresh, source, origin, tostring(why or "Saved agent settings could not be read."), metadata); return end
				api.picker.ensure(fresh, source, origin, preferred, function(last: any, record: any, full: any, reason: any, metadata: any?)
					if record and table.find(record.capabilities or {}, options.need)
						and (not coordinator or table.find(record.capabilities or {}, "coordinator-control-v1")) then chosen(last, record, full)
					elseif metadata then problem(last, source, origin, "We could not load your saved agent. No agent was started.", metadata)
					else
						api.notice(last, source, origin.alias_nonce, if coordinator then "Your saved orchestrator needs an update before it can start project work. Your saved choice has not changed. Choose another ready agent."
							else tostring(reason or "Your saved agent is not ready. Choose another agent."), if reason then "error" else "info", nil,
							if coordinator then { context = "project_start", code = "orchestrator_update_required", detail = reason } else nil)
						api.picker.pick(last, source, api.fresh(last, source, origin), options, function(c: any, r: any, k: any) chosen(c, r, k, true) end)
					end
				end)
			end)
		else api.picker.pick(cx, source, origin, options, function(c: any, r: any, k: any) chosen(c, r, k, true) end) end
	end
	local repository_form: any
	local function repository_back(cx: any, source: number, origin: any, draft: any)
		if repositories[source] and repositories[source].draft == draft then repositories[source] = nil end
		if decisions[source] and decisions[source].command == "project_repository" and decisions[source].form_tag == draft.form_tag then decisions[source] = nil end
		local job = jobs[source]
		if job and job.command == "project_repository" and job.form_tag == draft.form_tag then
			api.notice(cx, source, origin.alias_nonce, "This settings save was already sent. Closing the editor does not cancel it; its confirmed or unknown result remains tracked.", "info")
		end
		if api.forms.active(source, draft.form_tag) then api.forms.cancel(cx, source) end
	end
	local function repository_discover(cx: any, source: number, origin: any, project: any, draft: any)
		draft.form_tag = draft.form_tag or ("repository:" .. api.id())
		local id = api.id()
		repositories[source] = { phase = "discover", request_id = id, origin = origin, project = project, draft = draft, at = tern.now() }
		api.forms.open(cx, source, origin, { tag = draft.form_tag, title = "Code and merging · " .. project.name,
			description = "Reading this project's known folders and local repository defaults on the execution host. No network request or settings write is made.",
			fields = {}, actions = { { id = "cancel", label = "Back" } } }, function(fresh: any)
				repository_back(fresh, source, origin, draft)
			end)
		if not api.forms.active(source, draft.form_tag) then
			repositories[source] = nil
			problem(cx, source, origin, "Project settings could not open on this connection. Reopen the project's settings from its current pane; nothing was saved.")
			return
		end
		cx.session:event(source, { ev = "action", id = "main.setup-index", act = "setup-repository-discover",
			value = tern.json.encode({ source_nonce = origin.alias_nonce, request_id = id, orch_project_id = project.orch_project_id,
				cwd = draft.cwd, cwd_candidates = if api.project_folders then api.project_folders(cx, source, origin, project) else {} }) })
	end
	repository_form = function(cx: any, source: number, origin: any, project: any, draft: any)
		local fields, actions = {}, {}
		if draft.cwd ~= "" or draft.edit_folder then
			table.insert(fields, { id = "cwd", label = "Project folder", kind = if draft.edit_folder then "path" else "text",
				scope = "host", value = draft.cwd, disabled = not draft.edit_folder })
		elseif #(draft.folders or {}) > 0 then
			local options = { { value = "", label = "Choose a known project folder" } }
			for _, path in draft.folders do table.insert(options, { value = path, label = path }) end
			table.insert(fields, { id = "known_folder", label = "Known project folders", kind = "select", value = "", options = options })
		end
		if draft.repository_found and not draft.edit_folder then
			local options, seen = { { value = "", label = "Choose an existing branch" } }, {}
			for _, ref in draft.branches or {} do table.insert(options, { value = ref, label = ref:gsub("^refs/heads/", "") }); seen[ref] = true end
			if draft.target_ref ~= "" and not seen[draft.target_ref] then table.insert(options, { value = draft.target_ref, label = draft.target_ref }) end
			table.insert(fields, { id = "target_ref", label = "Merge changes into", kind = "select", value = draft.target_ref,
				options = options, disabled = not draft.editing })
			table.insert(fields, { id = "queue_route", label = "Who handles merges?", kind = "select", value = draft.queue_route, group = "repository_advanced",
				disabled = not draft.editing, options = { { value = "orch_queue", label = "ORCH+" }, { value = "repository_queue", label = "This repository's merge queue" } } })
			table.insert(fields, { id = "custom_target", label = "Other existing branch/ref", kind = "text", value = draft.custom_target or "",
				group = "repository_advanced", disabled = not draft.editing,
				description = "Leave the selector blank to use an exact existing ref not in its bounded list. A protected merge queue is not certified by this screen." })
			table.insert(actions, if draft.editing then { id = "save", label = "Verify and save", submit = true } else { id = "edit", label = "Edit", submit = true })
		end
		if draft.edit_folder or (draft.cwd == "" and #(draft.folders or {}) > 0) then
			table.insert(actions, { id = "discover", label = "Use this folder", submit = true })
		end
		if not draft.edit_folder then table.insert(actions, { id = "change_folder", label = if draft.cwd == "" then "Choose project folder" else "Change folder", submit = true }) end
		table.insert(actions, { id = "cancel", label = "Back" })
		api.forms.open(cx, source, origin, { tag = draft.form_tag, title = "Code and merging · " .. project.name,
			description = draft.message or "Project settings are shared by its plans. Agent working copies remain separately tracked. Text and research need no repository.",
			fields = fields, groups = if draft.repository_found and not draft.edit_folder then { { id = "repository_advanced", label = "Advanced", collapsed = true } } else {}, actions = actions },
			function(fresh: any, values: any, action: string)
				if action == "cancel" then repository_back(fresh, source, origin, draft); return end
				if not api.current(fresh, source, origin) then
					if not api.forms.update(fresh, source, { busy = false, notice = "The source connection changed. Your draft is retained; reopen this project's settings before saving." }) then api.forms.cancel(fresh, source) end
					return
				end
				if not values then return api.forms.update(fresh, source, { busy = false, notice = "The form values were not available. Your draft is retained." }) end
				if type(values.cwd) == "string" then draft.cwd = values.cwd end
				if type(values.target_ref) == "string" then draft.target_ref = values.target_ref end
				if type(values.queue_route) == "string" then draft.queue_route = values.queue_route end
				if type(values.custom_target) == "string" then draft.custom_target = values.custom_target end
				if action == "edit" or action == "change_folder" then
					draft.editing, draft.edit_folder = true, action == "change_folder"
					repository_form(fresh, source, origin, project, draft); return
				elseif action == "discover" then
					if type(values.known_folder) == "string" and values.known_folder ~= "" then draft.cwd = values.known_folder end
					if draft.cwd == "" then return api.forms.update(fresh, source, { busy = false, errors = { known_folder = "Select a known folder, or choose a different project folder." } }) end
					draft.edit_folder = false
					repository_discover(fresh, source, origin, project, draft); return
				elseif action ~= "save" then return end
				local current = projects(fresh, source)[project.orch_project_id]
				if not current or current.revision ~= project.revision then
					return api.forms.update(fresh, source, { busy = false, notice = "The project changed. Reopen Code and merging; your draft is retained." })
				end
				local target = if draft.custom_target and draft.custom_target ~= "" then draft.custom_target else draft.target_ref
				if draft.custom_target and draft.custom_target ~= "" and draft.target_ref ~= "" then
					local selected = if draft.target_ref:sub(1, 5) == "refs/" then draft.target_ref else "refs/heads/" .. draft.target_ref
					local custom = if draft.custom_target:sub(1, 5) == "refs/" then draft.custom_target else "refs/heads/" .. draft.custom_target
					if selected ~= custom then return api.forms.update(fresh, source, { busy = false,
						errors = { custom_target = "Choose one merge target: clear this value to use the selector, or clear the selector to use this exact ref." } }) end
				end
				if target == "" then return api.forms.update(fresh, source, { busy = false, errors = { target_ref = "Select the intended existing merge target; the current checkout branch is not assumed to be the default." } }) end
				local id = api.id()
				repositories[source] = { phase = "verify", request_id = id, origin = origin, project = project, route = draft.queue_route, draft = draft, at = tern.now() }
				api.forms.update(fresh, source, { busy = true, notice = "Verifying this checkout and the selected merge target…" })
				fresh.session:event(source, { ev = "action", id = "main.setup-index", act = "setup-repository-probe",
					value = tern.json.encode({ source_nonce = origin.alias_nonce, request_id = id, cwd = draft.cwd, target_ref = target }) })
			end)
	end
	local function attach(cx: any, source: number, origin: any, request: any)
		local items = {}
		for _, pane in cx.session:panes() do
			if api.pane(cx, source, pane.pane, origin) then
				local agent = api.agent(cx, pane.pane)
				if agent or pane.kind == "terminal" then
					table.insert(items, { label = provider_display.pane_title(pane) or "Agent session", detail = if agent then "Native agent session · " .. agent.state else "Terminal · attach without sending",
						pane = pane.pane, delivery = if agent then "native_ask" else "clipboard" })
				end
			end
		end
		if #items == 0 then return problem(cx, source, origin, "No attachable conversation exists in this native session on this host.") end
		ask(cx, source, origin, "Attach an existing conversation — preserve its context", items, function(fresh: any, choice: any)
			local binding = api.binding(choice.pane, origin)
			choose_project(fresh, source, origin, request.orch_project_id, function(selected: any, next_origin: any, project_id: string)
				local project = projects(selected, source)[project_id]
				local pane = api.pane(selected, source, choice.pane, next_origin)
				if not project or not pane then return problem(selected, source, next_origin, "The selected project or conversation changed. Nothing was attached.") end
				local native = api.agent(selected, choice.pane)
				local fields = { orch_project_id = project_id, project_revision = project.revision, pane_binding = binding,
					active = if native then native.state == "idle" or native.state == "working" or native.state == "waiting_input" else pane.busy == true }
				local id = api.decision(selected, source, next_origin, "associate_conversation", fields)
				if not id then return end
				decisions[source] = { request_id = id, command = "associate_conversation", origin = next_origin, fields = fields, at = tern.now(), done = function(last: any)
					local current = api.fresh(last, source, next_origin)
					local agent = api.agent(last, choice.pane)
					if choice.delivery == "native_ask" and (not agent or agent.state ~= "idle") then
						api.notice(last, source, current.alias_nonce, "Conversation attached without sending anything. Busy does not START project work. Enable coordination when the conversation is idle.", "info")
						return
					end
					ask(last, source, current, "Conversation attached — optionally enable managed coordination", {
						{ label = "Keep existing conversation unchanged" },
						{ label = if choice.delivery == "clipboard" then "Copy enrollment instructions once" else "Send enrollment to this idle conversation", enable = true,
							detail = "Choose its saved agent configuration next. Context is preserved. A real ACCEPTED reply is required; copying is not acceptance." },
					}, function(next_cx: any, consent: any)
						if consent.enable then choose_agent(next_cx, source, api.fresh(next_cx, source, current), project_id, false, binding, choice.delivery) end
					end)
				end }
			end)
		end)
	end
	-- Native controls can arrive before an idle window's next timer. Consume only an
	-- already returned exact receipt here as well; a pending/unknown command stays held.
	local function consume_job_result(cx: any, source: number, job: any): (boolean, boolean)
		local live = api.current(cx, source, job.origin)
		if not live and job.start_choice then
			-- Only the unissued menu choice is cancelled. The actual project command and
			-- its confirmed/unknown outcome keep their normal reconciliation hold.
			job.done, job.start_choice = nil, nil
		end
		local data = api.snapshot(cx, source)
		if not data or data.source_nonce ~= job.origin.alias_nonce or data.orch_session_id ~= job.origin.logical_session_id then data = nil end
		local response = job.confirmed
		local retained = api.node(cx, source, "conversation-result", "orchplus.conversation.result")
		if retained and retained.source_nonce == job.origin.alias_nonce and retained.orch_session_id == job.origin.logical_session_id
			and (job.initial_creation == nil or retained.creation_request_id == job.initial_creation)
			and type(retained.result) == "table" and retained.result.request_id == job.request_id
			and retained.result.command == job.command and type(retained.result.ok) == "boolean" then response = retained.result end
		if not response then
			for _, key in { "command_result", "driver_result", "result" } do
				local candidate = if data then data[key] else nil
				if candidate and candidate.request_id == job.request_id then response = candidate; break end
			end
		end
		if not response or response.request_id ~= job.request_id then return false, false end
		if response.ok and not live and job.command ~= "project_repository" then
			job.confirmed = response
			return false, false
		end
		jobs[source] = nil
		if response.ok then
			if job.done then job.done(cx, response) end
			return true, job.done == nil
		end
		if job.command == "project_repository" and api.forms.active(source, job.form_tag) then
			if not api.forms.update(cx, source, { busy = false, notice = tostring(response.message or response.code) .. " Your input is retained." }) then api.forms.cancel(cx, source) end
		end
		if job.command == "project_start" then
			problem(cx, source, job.origin, "We could not start this work. It is still on hold. Review the project before trying again.",
				{ context = "project_start", code = response.code, detail = tostring(response.message or response.code) })
			return true, false
		end
		problem(cx, source, job.origin, tostring(response.message or response.code) .. " Your draft is retained; no action was retried.")
		return true, false
	end
	local start: any
	start = function(cx: any, source: number, origin: any, command: string, request: any): boolean
		request = request or {}
		if table.find({ "new_conversation", "start_orchestrator", "attach_conversation" }, command) and jobs[source] then
			local job = jobs[source]
			if command == "start_orchestrator" and job.command == "new_project" and job.initial_creation
				and not job.done and api.current(cx, source, origin) then
				local project_id = request.orch_project_id
				job.start_choice = true
				job.done = function(fresh: any, _response: any)
					if api.current(fresh, source, origin) then
						start(fresh, source, api.fresh(fresh, source, origin), "start_orchestrator", { orch_project_id = project_id })
					end
				end
			end
			local consumed, next_choice = consume_job_result(cx, source, job)
			if consumed and not next_choice then return true end
			if not consumed and job.start_choice then
				api.notice(cx, source, origin.alias_nonce, "Finishing setup. Your project choices will open when its result is confirmed.", "info")
				return true
			end
		end
		if (command == "new_conversation" or command == "start_orchestrator" or command == "attach_conversation") and (jobs[source] or decisions[source]) then
			problem(cx, source, origin, "The previous action is still settling. Check its status before starting another session.")
			return true
		end
		if command == "new_conversation" or command == "start_orchestrator" then
			choose_project(cx, source, origin, request.orch_project_id, function(fresh: any, selected: any, project_id: string)
				choose_agent(fresh, source, selected, project_id, command == "start_orchestrator")
			end)
		elseif command == "attach_conversation" then attach(cx, source, origin, request)
		elseif command == "project_start" then
			local project = projects(cx, source)[request.orch_project_id]
			if not project or project.revision ~= request.project_revision or project.decision_context ~= request.decision_context then
				problem(cx, source, origin, "This project changed. Review it and choose START again.")
				return true
			end
			if project.start and project.start.state ~= "claimed" and not project.start.restartable then
				api.notice(cx, source, origin.alias_nonce, "Your orchestrator is still getting ready. New work remains on hold. START was not sent again.", "info")
				return true
			end
			local fields = { orch_project_id = project.orch_project_id, project_revision = project.revision, decision_context = request.decision_context }
			if project.checks_pending then
				local checks = {}
				for _, work in project.checks or {} do for _, check in work.checks or {} do
					local argv = {}; for _, arg in check.argv do table.insert(argv, string.format("%q", arg)) end
					table.insert(checks, check.check_id .. ": " .. table.concat(argv, " "))
				end end
				ask(cx, source, origin, "Review declared checks for " .. project.name .. "\n" .. table.concat(checks, "\n"), {
					{ label = "Keep project unstarted" }, { label = "START this project with these checks", confirm = true },
				}, function(fresh: any, choice: any) if choice.confirm then fields.checks_reviewed = true; submit(fresh, source, origin, "project_start", fields) end end)
			else submit(cx, source, origin, "project_start", fields) end
		elseif command == "project_start_retry" then
			local project = projects(cx, source)[request.orch_project_id]
			local grant = if project then project.start else nil
			if not grant or grant.start_id ~= request.start_id or grant.project_revision ~= request.project_revision
				or grant.decision_context ~= request.decision_context then
				problem(cx, source, origin, "The START request changed. Check the current project before trying again.")
				return true
			end
			api.control(cx, source, "project_start_retry", origin, { orch_project_id = project.orch_project_id, start_id = grant.start_id,
				project_revision = grant.project_revision, decision_context = grant.decision_context })
		elseif command == "project_menu" then
			local project = projects(cx, source)[request.orch_project_id]
			if not project then return true end
			local items = {
				{ label = "New Agent Session", command = "new_conversation" }, { label = "Attach Existing Agent Session", command = "attach_conversation" },
				{ label = "Move managed conversation here…", command = "project_associate" },
				{ label = "Add plan file…", source = "add-plan" }, { label = "Add board…", source = "add-board" },
				{ label = "Start from template…", source = "start-template" },
				{ label = "Open ORCH+ Board", source = "open-plan-board" },
				{ label = "Settings", command = "project_settings" },
				{ label = "Finish project…", command = "project_finish" },
			}
			if project.start and project.start.state ~= "claimed" and not project.start.restartable then
				table.insert(items, 1, { label = if project.start.failure and project.start.failure.retryable then "Try sending START again" else "Check START",
					command = "project_start_retry" })
			elseif not project.started or project.held_work then table.insert(items, 1, { label = "START this project's held work", command = "project_start" }) end
			ask(cx, source, origin, project.name, items, function(fresh: any, choice: any)
				if choice.source then api.sources.start(fresh, source, origin, choice.source, request)
				else
					local grant = if choice.command == "project_start_retry" then project.start else nil
					start(fresh, source, origin, choice.command, { orch_project_id = project.orch_project_id,
						start_id = if grant then grant.start_id else nil, project_revision = if grant then grant.project_revision else project.revision,
						decision_context = if grant then grant.decision_context else project.decision_context })
				end
			end)
		elseif command == "project_associate" then
			local project = projects(cx, source)[request.orch_project_id]
			if not project then return true end
			local items = {}
			for worker_id, proof in project.association_contexts or {} do
				local worker = api.node(cx, source, "workflow-worker-" .. worker_id, "orchplus.worker")
				if worker and worker.orch_project_id ~= project.orch_project_id then
					local binding = worker.pane_binding
					local pane = if binding and binding.window_key == origin.window_key and binding.window_epoch == origin.window_epoch
						and binding.native_session_id == origin.native_session_id and binding.window_host_id == origin.window_host_id
						then api.pane(cx, source, tonumber(binding.pane_id), origin) else nil
					table.insert(items, { label = provider_display.pane_title(pane) or "Managed agent session",
						worker_id = worker_id, proof = proof, detail = "Move only its project association. The agent's conversation and task stay unchanged." })
				end
			end
			if #items == 0 then
				problem(cx, source, origin, "No managed conversation can move here without splitting active work, a plan or a source.")
				return true
			end
			ask(cx, source, origin, "Associate an existing managed conversation with " .. project.name, items, function(fresh: any, choice: any)
				local current = projects(fresh, source)[project.orch_project_id]
				if not current or current.revision ~= project.revision or not current.association_contexts
					or current.association_contexts[choice.worker_id] ~= choice.proof then
					return problem(fresh, source, origin, "The project or managed conversation changed. Nothing moved.")
				end
				submit(fresh, source, origin, "project_associate", { orch_project_id = project.orch_project_id,
					project_revision = project.revision, worker_id = choice.worker_id, decision_context = choice.proof })
			end)
		elseif command == "project_settings" then
			local project = projects(cx, source)[request.orch_project_id]
			if not project then return true end
			ask(cx, source, origin, "Project settings · " .. project.name, {
				{ label = "Code and merging", command = "project_repository",
					detail = if project.repository then project.repository.cwd .. " · " .. project.repository.target_ref else "No repository settings saved. Text and research need none." },
				{ label = "Back", command = "project_menu" },
			}, function(fresh: any, choice: any) start(fresh, source, origin, choice.command, request) end)
		elseif command == "project_repository" then
			local project = projects(cx, source)[request.orch_project_id]
			if not project or repositories[source] then return true end
			if (jobs[source] and jobs[source].command == "project_repository") or (decisions[source] and decisions[source].command == "project_repository") then
				problem(cx, source, origin, "The previous repository save is still awaiting its exact result. Inspect the project after it settles; no second save was started."); return true
			end
			local flow = api.node(cx, source, "workflow-index", "orchplus.workflow")
			local drafts = repository_drafts[source] or {}; repository_drafts[source] = drafts
			local draft = drafts[project.orch_project_id] or { cwd = if project.repository then project.repository.cwd else "",
				target_ref = if project.repository then project.repository.target_ref else "", editing = project.repository == nil,
				queue_route = if project.repository then project.repository.queue_route
					elseif flow and flow.policy.merge_coordination == false then "repository_queue" else "orch_queue" }
			drafts[project.orch_project_id] = draft
			repository_discover(cx, source, origin, project, draft)
		elseif command == "project_finish" then
			local project = projects(cx, source)[request.orch_project_id]
			if not project then return true end
			api.forms.input(cx, source, origin, { placeholder = "Finished project summary", description = "Associated conversations keep running.", confirm_label = "Finish project", multiline = true, value = drafts[source] }, function(fresh: any, text: any)
				if text == nil or not api.current(fresh, source, origin) then return end
				drafts[source] = text
				submit(fresh, source, origin, "project_finish", { orch_project_id = project.orch_project_id, project_revision = project.revision, result = text }, function() drafts[source] = nil end)
			end)
		elseif command == "project_reopen" then submit(cx, source, origin, command, { summary_index = request.summary_index })
		elseif command == "association_menu" then
			local project = projects(cx, source)[request.orch_project_id]
			local association = if project then project.associations[request.conversation_id] else nil
			if not association then return true end
			ask(cx, source, origin, "Attached agent session", {
				{ label = "Open conversation", open = true },
				{ label = "Enable managed coordination…", enable = true },
				{ label = "Detach from project — keep conversation running", detach = true },
			}, function(fresh: any, choice: any)
				local binding = association.pane_binding
				local bound = binding.window_key == origin.window_key and binding.window_epoch == origin.window_epoch
					and binding.native_session_id == origin.native_session_id and binding.window_host_id == origin.window_host_id
				local pane = if bound then api.pane(fresh, source, tonumber(binding.pane_id), origin) else nil
				if choice.detach then
					submit(fresh, source, origin, "detach_conversation", { orch_project_id = project.orch_project_id,
						project_revision = project.revision, conversation_id = request.conversation_id })
				elseif not pane then problem(fresh, source, origin, "The native conversation is unavailable. It was not recreated.")
				elseif choice.open then fresh.layout:focus(pane.pane)
				elseif choice.enable then
					local agent = api.agent(fresh, pane.pane)
					if agent then choose_agent(fresh, source, origin, project.orch_project_id, false, binding, "native_ask")
					else
						ask(fresh, source, origin, "Terminal enrollment preserves its context; copying is not acceptance", {
							{ label = "Keep conversation unchanged" }, { label = "Copy enrollment instructions once", copy = true },
						}, function(next_cx: any, consent: any)
							if consent.copy then choose_agent(next_cx, source, origin, project.orch_project_id, false, binding, "clipboard") end
						end)
					end
				end
			end)
		elseif command == "summary_link" then
			local index = api.node(cx, source, "project-index", "orchplus.projects")
			local summary = if index then index.finished_projects[request.summary_index] else nil
			local found = false
			for _, link in (if summary then summary.links else {}) do if api.same(link, request.link) then found = true end end
			if not found then return true end
			if request.link.kind == "conversation" then
				local ok, binding = pcall(tern.json.decode, request.link.ref)
				local pane = if ok and type(binding) == "table" and binding.window_key == cx:window_key()
					and binding.native_session_id == origin.native_session_id and binding.window_host_id == origin.window_host_id
					then api.pane(cx, source, tonumber(binding.pane_id), origin) else nil
				if pane then cx.layout:focus(pane.pane) else problem(cx, source, origin, "That native conversation is no longer available. The summary is retained; no transcript was recreated.") end
			else cx:open(request.link.ref) end
		elseif command == "orchestration_menu" then
			ask(cx, source, origin, "Orchestration", {
				{ label = "Settings", command = "settings" }, { label = "Save as my default settings", command = "save_defaults" },
				{ label = "Switch orchestration…", command = "switch_orchestration" }, { label = "New orchestration…", command = "new_orchestration" },
				{ label = "Add plan file…", source = "add-plan" }, { label = "Add board…", source = "add-board" },
				{ label = "Start from template…", source = "start-template" },
				{ label = "Open ORCH+ Board", source = "open-plan-board" },
				{ label = "Close orchestration…", command = "close_session" },
			}, function(fresh: any, choice: any)
				if choice.source then api.sources.start(fresh, source, origin, choice.source, request)
				else api.control(fresh, source, choice.command, origin) end
			end)
		else return false end
		return true
	end
	local function create(cx: any, source: number?)
		local pane = source or api.new_panel(cx)
		if not pane or starts[pane] then return end
		starts[pane] = { phase = "preflight", at = tern.now() }
	end
	local function tick(cx: any)
		for source, pending in repositories do
			if not api.current(cx, source, pending.origin) or not api.forms.active(source, pending.draft.form_tag) then repositories[source] = nil; continue end
			local setup = api.node(cx, source, "setup-index", "orchplus.setup")
			local response = if setup then setup.setup_result else nil
			if response and response.request_id == pending.request_id then
				repositories[source] = nil
				if pending.phase == "discover" then
					local draft = pending.draft
					draft.cwd, draft.folders = response.cwd or draft.cwd, response.folders or {}
					draft.branches, draft.repository_found, draft.message = response.branches or {}, response.ok == true, response.message
					if draft.target_ref == "" and response.default_ref then draft.target_ref = response.default_ref end
					if response.branches_clipped then draft.message = (draft.message or "") .. " More local branches exist; Advanced accepts an exact existing branch/ref." end
					repository_form(cx, source, pending.origin, pending.project, draft)
				elseif not response.ok or type(response.repository) ~= "table" then
					if response.code == "repository_target_required" then
						pending.draft.branches, pending.draft.message = response.branches or {}, response.message
						repository_form(cx, source, pending.origin, pending.project, pending.draft)
					else api.forms.update(cx, source, { busy = false, notice = tostring(response.message or "Checkout verification failed.") .. " Your input is retained." }) end
				else
					local repository = response.repository
					repository.queue_route = pending.route
					local origin = api.fresh(cx, source, pending.origin)
					local fields = { orch_project_id = pending.project.orch_project_id, project_revision = pending.project.revision, repository = repository }
					local id = api.decision(cx, source, origin, "project_repository", fields)
					api.forms.update(cx, source, { busy = id ~= nil, notice = if id then "Checkout and target verified. Saving…" else "The save could not start. Your input is retained." })
					if id then decisions[source] = { request_id = id, command = "project_repository", origin = origin, fields = fields,
						form_tag = pending.draft.form_tag, at = tern.now(), done = function(fresh: any)
							local drafts = repository_drafts[source]
							if drafts then drafts[pending.project.orch_project_id] = nil end
							if api.forms.active(source, pending.draft.form_tag) then
								api.forms.cancel(fresh, source)
								if api.current(fresh, source, origin) then fresh.layout:focus(source) end
							end
							api.notice(fresh, source, origin.alias_nonce, "Code and merging settings saved for " .. pending.project.name .. ".", "info")
						end } end
				end
			elseif tern.now() - pending.at > 30000 then
				repositories[source] = nil
				if pending.phase == "discover" then
					pending.draft.message = "Project-folder discovery did not finish. Your input is retained. Choose a folder or return to the project."
					repository_form(cx, source, pending.origin, pending.project, pending.draft)
				else api.forms.update(cx, source, { busy = false, notice = "Checkout verification did not finish. Your input is retained; no project association was changed." }) end
			end
		end
		for source, decision in decisions do
			if not api.current(cx, source, decision.origin)
				or (decision.command == "project_repository" and not api.forms.active(source, decision.form_tag)) then decisions[source] = nil; continue end
			local result = api.node(cx, source, "decision-context-result", "orchplus.decision")
			if result and result.request_id == decision.request_id then
				decisions[source] = nil
				if not result.decision_context and decision.command == "project_repository" then
					api.forms.update(cx, source, { busy = false, notice = "The project or checkout changed. Your input is retained; nothing was changed." })
				end
				if not result.decision_context then problem(cx, source, decision.origin,
					if decision.command == "project_repository" then "The project or checkout changed. Your input is retained; nothing was changed."
					elseif decision.command == "new_project" then "The project creation settings changed. Your name is retained; nothing was created."
					else "The project or conversation changed. Nothing was attached.")
				else
					decision.fields.decision_context = result.decision_context
					submit(cx, source, decision.origin, decision.command, decision.fields, decision.done, decision.initial_creation)
				end
			elseif tern.now() - decision.at > 30000 then
				if decision.command == "project_repository" then api.forms.update(cx, source, { busy = false, notice = "Checkout review did not complete. Your input is retained; nothing was changed." }) end
				decisions[source] = nil; problem(cx, source, decision.origin,
					if decision.command == "project_repository" then "Checkout review did not complete. Your input is retained; nothing was changed."
					elseif decision.command == "new_project" then "Project creation review did not complete. Your name is retained; nothing was created."
					else "Attachment review did not complete. No conversation was changed.")
			end
		end
		for source, pending in starts do
			local alias = api.alias(cx, source)
			if not alias then
				if tern.now() - pending.at > 30000 then starts[source] = nil; cx:toast("error", "ORCH+", "The orchestration panel did not become ready. Nothing was started.") end
				continue
			end
			if pending.phase == "preflight" then
				pending.phase = "checking_setup"
				api.setup_ready(cx, source, function(fresh: any, ok: boolean, why: string?)
					if starts[source] ~= pending then return end
					if ok then pending.phase, pending.at = "settings_choice", tern.now(); return end
					starts[source] = nil
					api.forms.open(fresh, source, alias, { title = "Complete agent setup first",
						description = why or "No agent setup found in SPAWN. Set up agents first.",
						fields = {}, actions = { { id = "spawn", label = "Set up agents in SPAWN" }, { id = "cancel", label = "Back" } } },
						function(last: any, _values: any, action: string)
							api.forms.cancel(last, source)
							if action == "spawn" then api.open_spawn(last, source) end
						end)
				end)
			elseif pending.phase == "settings_choice" then
				pending.phase = "choosing"
				api.forms.choose(cx, source, alias, { title = "New orchestration", placeholder = "Choose settings. No agent will start.",
					items = {
						{ label = "Default settings", mode = "default", detail = "Use your saved defaults, or the built-in defaults if you have not defined them." },
						{ label = "Custom settings", mode = "custom", detail = "Create the orchestration, then edit its settings before starting an agent." },
					} }, function(fresh: any, choice: any)
					if starts[source] ~= pending then return end
					local current = api.alias(fresh, source)
					if not choice or not current or current.alias_nonce ~= alias.alias_nonce then starts[source] = nil; return end
					pending.settings_mode, pending.phase, pending.at = choice.mode, "name", tern.now()
				end)
			elseif pending.phase == "name" then
				pending.phase = "prompt"
				local setup = api.node(cx, source, "setup-index", "orchplus.setup")
				local default_revision = if setup and setup.installation_defaults then setup.installation_defaults.revision else nil
				local name = "Orchestration " .. tostring(api.count(cx) + 1)
				api.forms.input(cx, source, alias, { value = name, title = "New orchestration", label = "Orchestration name", placeholder = "Orchestration name",
					description = if pending.settings_mode == "custom" then "Create this orchestration, then edit its settings. No agent will start."
						else "Create this orchestration with default settings. No agent will start.", confirm_label = "Create orchestration",
					validate = function(value: string): string? return if #value > 160 or not value:find("%S") or value:find("%c") then "Use a readable orchestration name of at most 160 bytes on one line." else nil end }, function(fresh: any, value: any)
					if value == nil then starts[source] = nil; return end
					local current = api.alias(fresh, source)
					if not current or current.alias_nonce ~= alias.alias_nonce or current.revision ~= alias.revision then starts[source] = nil; return end
					pending.request_id, pending.name, pending.phase, pending.at = api.id(), value, "created", tern.now()
					fresh.session:event(source, { ev = "action", id = "main", act = "orchestration-create", value = tern.json.encode({
						request_id = pending.request_id, source_nonce = alias.alias_nonce, name = value,
						authority_namespace = alias.authority_namespace, expected_revision = alias.revision, defaults_revision = default_revision,
					}) })
				end)
			elseif pending.phase == "created" then
				local response = api.node(cx, source, "orchestration-result", "orchplus.orchestration.result")
				if response and response.request_id == pending.request_id then
					if not response.ok then starts[source] = nil; problem(cx, source, alias, tostring(response.message or response.code)); continue end
					local origin = api.origin(cx, source)
					if not origin then continue end
					pending.phase, pending.origin, pending.at = "pairing", origin, tern.now()
					local creation = { request_id = response.request_id, orch_session_id = response.orch_session_id,
						owner_id = response.owner_id, generation = response.generation,
						authority_namespace = alias.authority_namespace, source_nonce = alias.alias_nonce }
					api.connect(cx, source, creation, function(fresh: any, ok: boolean, message: string?)
						if starts[source] ~= pending or pending.phase ~= "pairing" then return end
						if not ok or not api.current(fresh, source, origin) then
							starts[source] = nil
							return problem(fresh, source, alias, message or "The created orchestration changed before connection. Nothing was admitted or launched.")
						end
						pending.phase, pending.at = "connected", tern.now()
						api.control(fresh, source, "bridge_admit", origin)
					end)
				end
			elseif pending.phase == "connected" then
				local data = api.snapshot(cx, source)
				if data and data.session_control and data.session_control.admitted then
					starts[source] = nil
					local origin = api.origin(cx, source)
					if origin then
						local done: ((any, any) -> ())? = nil
						if pending.settings_mode == "custom" then
							done = function(fresh: any, _response: any)
								local current = api.origin(fresh, source)
								if current then api.control(fresh, source, "settings", current) end
							end
						end
						submit(cx, source, origin, "new_project", { name = pending.name }, done,
							if pending.settings_mode == "custom" then nil else pending.request_id)
					end
				elseif data and data.control_result and data.control_result.ok == false then
					starts[source] = nil; problem(cx, source, alias, tostring(data.control_result.message or data.control_result.code))
				end
			end
			if starts[source] and pending.phase ~= "prompt" and pending.phase ~= "choosing" and pending.phase ~= "pairing" and tern.now() - pending.at > 60000 then
				starts[source] = nil; problem(cx, source, alias, "Connection is not confirmed. Existing ownership and effects remain held; nothing was retried.")
			end
		end
		for source, job in jobs do
			if consume_job_result(cx, source, job) then continue end
			if job.confirmed then
				if tern.now() - job.at > 30000 then
					jobs[source] = nil
					api.notice(cx, source, job.origin.alias_nonce, "The requested action is confirmed in its original orchestration. Reopen that context to continue the editor's next step.", "info")
				end
			elseif tern.now() - job.at > 30000 then
				jobs[source] = nil
				if job.command == "project_repository" and api.forms.active(source, job.form_tag) then
					if not api.forms.update(cx, source, { busy = false, notice = "The save result is not confirmed. Your input is retained; inspect the project before making another decision." }) then api.forms.cancel(cx, source) end
				end
				problem(cx, source, job.origin, "The action's result is not confirmed. Inspect retained work before any new decision; it was not retried.")
			end
		end
	end
	local function runnable(source: number): boolean
		if jobs[source] or decisions[source] or repositories[source] then return true end
		local creation = starts[source]
		return creation ~= nil and creation.phase ~= "prompt" and creation.phase ~= "choosing"
	end
	return { start = start, tick = tick, create = create, runnable = runnable }
end
return M
