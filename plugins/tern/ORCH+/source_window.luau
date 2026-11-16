--!strict
-- Desktop source selection only. Authority stays in the host; boards never use host FS.
local adapter = require("./source_adapter")
local quota = require("./quota")
local codec = require("./wire/codec")
local protocol = require("./dispatch_protocol")
local M = {}

function M.new(api: any): any
	local jobs: any = {}
	local drafts: any = {}
	local uncertain: any = {}
	local uncertain_count = 0
	local mirrors: any = {}
	local serial = 0
	local now = api.now or function() return tern.now() end
	local function active(cx: any, job: any): boolean
		if jobs[job.source] ~= job or not api.current(cx, job.source, job.origin) then return false end
		if job.board_setting ~= nil then
			local model = api.node(cx, job.source, "workflow-index", "orchplus.workflow")
			if not model or type(model.policy) ~= "table" or (model.policy.board_path or "") ~= job.board_setting then return false end
		end
		return true
	end
	-- This is a native-effect fence, not source authority. One pending batch per
	-- resolved desktop board locator survives VM replacement. Observation of matching
	-- cards/file bytes is not proof that an earlier native writer has finished.
	local function journal_path(board: string): string
		local data = assert(adapter.normalize_root(tern.plugin.data, tern.runtime.os), "Desktop plugin data path is unavailable")
		return data .. "/source-board-sync/" .. codec.sha256(board) .. ".json"
	end
	local function journal_read(board: string): any
		local path = journal_path(board)
		if not tern.fs.exists(path) then return nil end
		local bytes = tern.fs.read(path, 16384)
		local value = tern.json.decode(bytes)
		local fields = { version = true, phase = true, batch_id = true, board_path = true, source_path = true,
			source_revision = true, source_provenance = true, host = true, session = true, window = true, alias = true }
		if type(value) ~= "table" or value.version ~= 1 or value.phase ~= "pending" or value.board_path ~= board then error("Invalid board sync journal; preserve the original file") end
		for key in pairs(value) do if not fields[key] then error("Unknown board sync journal field; preserve the original file") end end
		for _, key in ipairs({ "batch_id", "board_path", "source_path", "source_revision", "source_provenance", "host", "session", "window", "alias" }) do
			local text = value[key]
			if type(text) ~= "string" or #text > (if key == "board_path" or key == "source_path" then 4096 else 512)
				or utf8.len(text) == nil or text:find("%z") then error("Invalid board sync journal identity; preserve the original file") end
		end
		if value.batch_id == "" then error("Board sync journal is missing its batch identity") end
		return value
	end
	local function journal_begin(job: any): (boolean, string?)
		local board = job.desktop_board_path
		if type(board) ~= "string" then return false, "Native board write has no captured desktop destination." end
		local ok, failure = pcall(function()
			local prior = journal_read(board)
			if job.journal then
				if not prior or quota.canonical(prior) ~= quota.canonical(job.journal) then error("Board sync journal changed; the original batch remains unresolved") end
				return
			end
			if prior then error("A previous native board sync batch has no confirmed completion. Automatic writes remain held; matching current cards do not prove the original writer ended. Keep this board unchanged or choose a separate Board location until native completion can be established. Source: " .. prior.source_path .. " · Desktop board: " .. board) end
			local selected = job.plan_source or {}
			local marker = { version = 1, phase = "pending", batch_id = api.id(), board_path = board,
				source_path = selected.path or "", source_revision = selected.revision or "",
				source_provenance = if selected.path then codec.sha256(selected.path) else "",
				host = tostring(job.origin.window_host_id or ""), session = tostring(job.origin.logical_session_id or ""),
				window = tostring(job.origin.window_key or ""), alias = tostring(job.origin.alias_nonce or "") }
			local path = journal_path(board)
			local bytes = tern.json.encode(marker)
			if #bytes > 16384 then error("Board sync journal exceeds its safety bound") end
			tern.fs.mkdir(assert(path:match("^(.*)/[^/]+$")))
			tern.fs.write(path, bytes)
			local retained = journal_read(board)
			if not retained or quota.canonical(retained) ~= quota.canonical(marker) then error("Board sync journal read-back differs; no native effect was issued") end
			job.journal = marker
		end)
		return ok, if ok then nil else tostring(failure)
	end
	local function journal_finish(job: any): (boolean, string?)
		if not job.journal or job.pending_native then return true, nil end
		local ok, failure = pcall(function()
			local prior = journal_read(job.desktop_board_path)
			if not prior or quota.canonical(prior) ~= quota.canonical(job.journal) then error("Board sync journal changed before settlement; preserve it") end
			tern.fs.remove(journal_path(job.desktop_board_path))
			if tern.fs.exists(journal_path(job.desktop_board_path)) then error("Board sync settlement did not confirm journal removal") end
			job.journal = nil
		end)
		return ok, if ok then nil else tostring(failure)
	end
	local function confirm_native(job: any) job.pending_native = false end
	local function clear_uncertainty(key: string?)
		if key and uncertain[key] then uncertain[key] = nil; uncertain_count -= 1 end
	end
	local function range_result(value: any): boolean
		return type(value) == "table" and type(value.from) == "number" and type(value.to) == "number"
			and value.from >= 1 and value.from % 1 == 0 and value.to >= value.from and value.to % 1 == 0
	end
	local function id_result(value: any): boolean
		return type(value) == "string" and #value > 0 and #value <= protocol.NATIVE_BOARD_ID_BYTES and utf8.len(value) ~= nil and not value:find("%c")
	end
	local function boolean_result(value: any): boolean return value == true end
	local function stop(cx: any, job: any, message: string?, level: string?)
		if jobs[job.source] ~= job then return end
		if api.forms.active(job.source, "source-work") then api.forms.cancel(cx, job.source) end
		local settled, failure = journal_finish(job)
		if not settled then message, level = "Native board sync settlement is held: " .. tostring(failure), "error" end
		if job.work_finalize then
			local finalize = job.work_finalize; job.work_finalize = nil
			finalize(cx, level == "success", message, if level == "success" then "success" elseif message then "refused" else "cancelled")
		end
		jobs[job.source] = nil
		if job.operation == "sync-board" then
			local mirror = mirrors[job.source]
			if mirror then
				mirror.next_at = now() + 5000
				if not message or level == "success" then mirror.error = nil; return end
				if mirror.error == message then return end
				mirror.error = message
			end
		end
		if message then api.notice(cx, job.source, job.origin.alias_nonce, message, level or "error", "ORCH+ work sources") end
	end
	local function later(job: any, fn: any)
		job.next = fn; job.waiting = nil; job.deadline = nil
	end
	local function watch(cx: any, job: any, make: any, done: any, effect: boolean?, validate: any?, effect_key: string?)
		if effect then
			if type(validate) ~= "function" then clear_uncertainty(effect_key); stop(cx, job, "A native effect has no completion validator; nothing was issued."); return end
			local retained, failure = journal_begin(job)
			if not retained then clear_uncertainty(effect_key); stop(cx, job, "Native board synchronization is held: " .. tostring(failure)); return end
			job.pending_native = true
		end
		job.waiting = true; job.deadline = now() + 15000; job.effect = effect == true
		job.io_epoch = (job.io_epoch or 0) + 1
		local ok, promise = pcall(make, cx)
		if not ok then stop(cx, job, "Source operation could not complete: " .. tostring(promise) .. (if effect then ". Its outcome may be uncertain; it will not be repeated." else "")); return end
		local callback = function(value: any, err: any, fresh: any)
			if effect then
				job.effect = false
				if not err and validate(value) then
					-- Positive native completion is effect evidence even when the
					-- unrelated source/session is no longer the current UI context.
					confirm_native(job); clear_uncertainty(effect_key)
					if not fresh or not active(fresh, job) then
						local settled, failure = journal_finish(job)
						job.native_inactive = true
						job.native_notice = if settled then nil else "Native board settlement remains held: " .. tostring(failure)
						if fresh and jobs[job.source] == job then stop(fresh, job, job.native_notice) end
						return
					end
				else
					job.native_notice = (if err then tostring(err) else "The native result did not validate completion") .. ". The write's outcome remains unknown and it was not repeated."
					job.native_inactive = true
					if fresh and jobs[job.source] == job then stop(fresh, job, job.native_notice) end
					return
				end
			end
			if not fresh or not active(fresh, job) then return end
			if err then stop(fresh, job, tostring(err)); return end
			later(job, function(next_cx: any) done(next_cx, value) end)
		end
		promise:next(callback)
	end
	local function pick(cx: any, job: any, title: string, items: any, done: any)
		if #items == 0 then stop(cx, job, "No available choices. Nothing was added."); return end
		job.waiting = true; job.deadline = nil
		api.forms.choose(cx, job.source, job.origin, { tag = "source-work", title = title,
			placeholder = title, description = (if job.auto_start then "Saved auto-start enabled. " else "Adding does not start work. ")
				.. (if job.paused then "The orchestration is paused; adding does not resume it." else ""), items = items },
			function(fresh: any, choice: any)
				if not active(fresh, job) then return end
				if not choice or choice.cancel then stop(fresh, job); return end
				later(job, function(next_cx: any) done(next_cx, choice) end)
			end)
	end
	local function form_error(cx: any, job: any, message: string, errors: any?)
		if api.forms.active(job.source, "source-work") and api.forms.update(cx, job.source, { busy = false, notice = message, errors = errors or {} }) then return end
		stop(cx, job, message)
	end
	local function input_form(cx: any, job: any, key: string, title: string, scope: string?, done: any)
		job.waiting = true; job.deadline = nil
		api.forms.open(cx, job.source, job.origin, { tag = "source-work", title = title,
			description = if job.paused then "Adding is available while paused and will not resume work." else "Only the supported Markdown plan schema becomes a workflow.",
			fields = { { id = key, label = title, kind = if scope then "path" else "text", scope = scope, value = job.draft[key] or "" } },
			actions = { { id = "continue", label = "Continue", submit = true } } },
			function(fresh: any, values: any)
				if not active(fresh, job) then return end
				if not values then stop(fresh, job); return end
				job.draft[key] = values[key]
				if type(values[key]) ~= "string" or not values[key]:find("%S") or values[key]:find("%c") then
					form_error(fresh, job, "Enter a nonempty path or name without control characters.", { [key] = "Enter a path or name." }); return
				end
				later(job, function(next_cx: any) done(next_cx, values[key]) end)
			end)
	end
	-- Pure transformations can yield at a card/task/hash block; no WindowCx survives a yield.
	local function compute(job: any, fn: any, done: any)
		job.compute = coroutine.create(fn); job.computed = done
	end
	local function bytes_digest(bytes: string): string
		local hash = codec.sha256_begin(); codec.sha256_feed(hash, bytes)
		while not codec.sha256_step(hash, 32) do coroutine.yield() end
		return codec.sha256_digest(hash)
	end
	local function digest(value: any): string return bytes_digest(quota.canonical(value)) end
	local function flow(cx: any, job: any): any
		return api.node(cx, job.source, "workflow-index", "orchplus.workflow")
	end
	local function submit(cx: any, job: any, command: string, fields: any, done: any?)
		local model = flow(cx, job)
		local policy = if model then model.policy else nil
		local auto_start = policy and policy.auto_start_projects == true and job.operation ~= "source-proposal" and job.operation ~= "sync-board"
		if not policy or (policy.paused == true) ~= job.paused or auto_start ~= job.auto_start
			or (job.operation == "work-on" and policy.glitch_integration ~= true) then
			stop(cx, job, "The source's start settings changed while you were choosing it. Your entries are retained; review the current settings before adding it.")
			return
		end
		-- Discovery and human input can span unrelated host commits. Capture the final
		-- decision now; source revisions and the host's strict commit fence still apply.
		local origin = if api.fresh then api.fresh(cx, job.source, job.origin) else job.origin
		if not origin or not api.current(cx, job.source, origin) then
			stop(cx, job, "The controller changed. Nothing was added; your entered text is retained.")
			return
		end
		job.origin = origin
		job.command = command
		if command == "new_project" and fields.decision_context == nil then
			local id = api.decision(cx, job.source, job.origin, command, fields)
			if not id then stop(cx, job, "Project creation could not be reviewed. Your selection is retained; nothing was created."); return end
			job.decision = { request_id = id, fields = fields, done = done }
			job.waiting = true; job.deadline = now() + 15000
			return
		end
		job.request_id = api.send(cx, job.source, job.origin, command, fields, true)
		if not job.request_id then stop(cx, job, "Nothing further was sent. Your source selection and entered text are retained."); return end
		job.result = done; job.waiting = true; job.deadline = now() + 15000
	end
	local function refresh(cx: any, job: any): boolean
		local origin = if api.fresh then api.fresh(cx, job.source, job.origin) else api.origin(cx, job.source)
		if not origin or not api.current(cx, job.source, origin) then stop(cx, job, "The source was added, but the controller changed before the next item. Nothing else was sent."); return false end
		job.origin = origin; return true
	end
	local function project(cx: any, job: any, title: string, done: any)
		if job.project_id then done(cx); return end
		local index = api.node(cx, job.source, "project-index", "orchplus.projects")
		local items: any = { { label = "New project — " .. title, new = true,
			detail = if job.auto_start then "Saved auto-start starts added work when the orchestration is not paused" else "Add first; START remains a separate instruction" } }
		for id, row in pairs(if index and type(index.projects) == "table" then index.projects else {}) do
			if row.finished ~= true then table.insert(items, { label = row.name, project_id = id, current = job.draft.project_id == id, detail = "Existing orchestrated project" }) end
		end
		pick(cx, job, "Add to which project?", items, function(fresh: any, choice: any)
			job.project_id = choice.project_id; job.draft.project_id = choice.project_id; done(fresh)
		end)
	end
	local function discover(cx: any, job: any, fields: any, done: any)
		local request = table.clone(fields)
		request.source_nonce = job.origin.alias_nonce; request.request_id = api.id()
		job.discovery = { request_id = request.request_id, done = done }
		job.waiting = true; job.deadline = now() + 15000
		cx.session:event(job.source, { ev = "action", id = "main", act = "source-discover", value = tern.json.encode(request) })
	end
	local function discover_pages(cx: any, job: any, fields: any, page_key: string, done: any)
		local parts, offset, total, checksum, pinned = {}, 0, nil, nil, fields.revision
		local receive: any
		receive = function(fresh: any, response: any)
			if response.ok ~= true then stop(fresh, job, tostring(response.message or "Source discovery is unavailable.")); return end
			local page = response[page_key]
			if type(page) ~= "table" or (fields.path and page.path ~= fields.path) or page.offset ~= offset or type(page.revision) ~= "string"
				or (pinned and pinned ~= page.revision) or type(page.sha256) ~= "string" or not page.sha256:match("^[a-f0-9]+$") or #page.sha256 ~= 64
				or (checksum and checksum ~= page.sha256) or type(page.bytes) ~= "string" or #page.bytes == 0 or #page.bytes > 16000
				or type(page.total_bytes) ~= "number" or page.total_bytes % 1 ~= 0 or page.total_bytes < 1 or page.total_bytes > 8 * 1024 * 1024
				or (total and total ~= page.total_bytes) then stop(fresh, job, "Source pages changed or are incomplete. Nothing was added or exported."); return end
			pinned = page.revision; total = page.total_bytes; checksum = page.sha256
			table.insert(parts, page.bytes); offset += #page.bytes
			if offset > total or (offset < total and page.next_offset ~= offset) or (offset == total and page.next_offset ~= nil) then
				stop(fresh, job, "Source paging did not advance exactly. Nothing was added or exported."); return
			end
			if offset < total then
				local next_request = table.clone(fields); next_request.revision = pinned; next_request.offset = offset
				discover(fresh, job, next_request, receive); return
			end
			compute(job, function()
				local bytes = table.concat(parts)
				if bytes_digest(bytes) ~= checksum then return nil, "Source pages failed their integrity check." end
				local ok, value = pcall(tern.json.decode, bytes)
				return if ok and type(value) == "table" then value else nil, "The complete source could not be decoded."
			end, function(next_cx: any, value: any, err: any)
				if not value then stop(next_cx, job, err); return end
				done(next_cx, value, pinned)
			end)
		end
		local request = table.clone(fields); request.offset = 0
		discover(cx, job, request, receive)
	end
	local function read_plan(cx: any, job: any, path: string, revision: string?, done: any)
		if not adapter.normalize_root(path) then stop(cx, job, "Choose an absolute plan path on the execution host. Only the supported plan schema can be added."); return end
		job.draft.path = path
		local full = job.operation == "sync-board"
		local function accept(fresh: any, selected: any, pinned: string?)
			if type(selected) ~= "table" or selected.kind ~= "plan_file" or selected.path ~= path or type(selected.revision) ~= "string"
				or (pinned and selected.revision ~= pinned) or type(selected.plan) ~= "table" or type(selected.plan.title) ~= "string"
				or (full and (selected.plan.plan_revision ~= selected.revision or type(selected.plan.checkpoints) ~= "table")) then
				stop(fresh, job, "Plan metadata is incomplete or changed at its selected revision."); return
			end
			job.plan_source = selected; done(fresh, selected)
		end
		if full then discover_pages(cx, job, { path = path, revision = revision }, "source_page", accept)
		else discover(cx, job, { path = path, revision = revision, metadata_only = true }, function(fresh: any, response: any)
			if response.ok ~= true then stop(fresh, job, tostring(response.message or "The selected supported plan could not be read.")); return end
			accept(fresh, response.source, revision)
		end) end
	end
	local function add_plan(cx: any, job: any, source: any)
		project(cx, job, source.plan.title, function(fresh: any)
			submit(fresh, job, "plan_import", { path = source.path, source_revision = source.revision, orch_project_id = job.project_id })
		end)
	end
	local function custom_plan(cx: any, job: any, done: any)
		input_form(cx, job, "path", "Plan file on the execution host", "host", function(fresh: any, path: string)
			read_plan(fresh, job, path, nil, done)
		end)
	end
	local function work_on(cx: any, job: any)
		job.waiting = true; job.deadline = nil
		api.work_on(cx, job.source, job.origin, job.input, function(fresh: any, selected: any, finalize: any)
			if not active(fresh, job) then
				if finalize then finalize(fresh, false, "This selection was cancelled before delivery; no import was issued by it.", "cancelled") end
				return
			end
			job.work_finalize = finalize
			if not selected then stop(fresh, job); return end
			if selected.kind == "plan_file" then
				read_plan(fresh, job, selected.path, selected.revision, function(next_cx: any, source: any) add_plan(next_cx, job, source) end)
			elseif selected.kind == "context" and type(selected.name) == "string" and type(selected.path) == "string" and type(selected.revision) == "string" then
				submit(fresh, job, "new_project", { name = selected.name, source = { kind = "manual", ref = selected.path, revision = selected.revision } })
			else stop(fresh, job, "WORK did not return a current supported project or plan selection.") end
		end)
	end
	local function template(cx: any, job: any)
		local model = flow(cx, job)
		local templates = if model and model.policy then model.policy.templates or {} else {}
		local items = {}
		for _, saved in ipairs(templates) do
			if not job.input.template_id or saved.id == job.input.template_id then table.insert(items, { label = saved.title, current = saved.id == job.draft.template_id, detail = saved.output, template = saved }) end
		end
		pick(cx, job, if job.auto_start then "Start from template — saved auto-start enabled" else "Start from template — add before starting", items, function(fresh: any, choice: any)
			local saved = choice.template; local revision = quota.digest(saved); job.draft.template_id = saved.id
			local fields = { { id = "input", label = "Input", kind = "editor", value = job.draft.input or "",
				help = "Up to " .. tostring(protocol.SOURCE_INPUT_BYTES) .. " UTF-8 bytes." } }
			local names = {}; for name in pairs(saved.custom_fields or {}) do table.insert(names, name) end; table.sort(names)
			for _, name in ipairs(names) do table.insert(fields, { id = "custom-" .. name, label = name, kind = "text", value = (job.draft.custom_fields or {})[name] or saved.custom_fields[name] }) end
			job.waiting = true; job.deadline = nil
			api.forms.open(fresh, job.source, job.origin, { tag = "source-work", title = saved.title, description = if job.auto_start then "Saved auto-start enabled." else "Add first; START remains separate.",
				fields = fields, actions = { { id = "add", label = "Add template work", submit = true } } }, function(next_cx: any, values: any)
				if not active(next_cx, job) then return end
				if not values then stop(next_cx, job); return end
				local custom = {}
				for _, name in ipairs(names) do
					local value = values["custom-" .. name]
					if value ~= saved.custom_fields[name] then custom[name] = value end
				end
				job.draft.input, job.draft.custom_fields = values.input, custom
				local source, err = adapter.template_source(saved, revision, values.input, custom)
				if not source then form_error(next_cx, job, err.message); return end
				project(next_cx, job, saved.title, function(final_cx: any)
					submit(final_cx, job, "template_start", { template_id = source.template_id, source_revision = revision, input = values.input,
						custom_fields = source.custom_fields, orch_project_id = job.project_id })
				end)
			end)
		end)
	end
	-- `from` pages lanes, not cards. Native lane.more has no card cursor: never
	-- mislabel a truncated lane complete or intake/export only its visible prefix.
	local function scan(job: any, path: string, done: any)
		job.scan = { path = path, from = 1, pages = 0, lanes = {}, ids = {}, cards = 0, done = done }
	end
	local function scan_step(cx: any, job: any)
		local s = job.scan
		watch(cx, job, function(fresh: any) return fresh.board:read(s.path, { rows = 500, from = s.from, max_chars = 1048576 }) end, function(fresh: any, page: any)
			if type(page) ~= "table" or type(page.path) ~= "string" or (s.pages > 0 and page.path ~= s.path)
				or page.phase == "failed" or page.phase == "loading" or type(page.lanes) ~= "table"
				or type(page.more) ~= "number" or page.more < 0 then stop(fresh, job, "The complete desktop board is unavailable. No source or mirror was changed."); return end
			s.path = page.path -- The native desktop API resolves relative paths, never the execution host.
			if s.total and (s.total ~= page.total or s.open ~= page.open or s.done_count ~= page.done) then stop(fresh, job, "The board changed while paging. Inspect it and choose the source again."); return end
			s.total = page.total; s.open = page.open; s.done_count = page.done
			for _, lane in ipairs(page.lanes) do
				if type(lane.id) ~= "string" or s.ids[lane.id] or lane.more ~= 0 or type(lane.cards) ~= "table" then stop(fresh, job, "A board lane is incomplete or changed while paging. Native board paging cannot read hidden cards within a lane; nothing was added."); return end
				s.ids[lane.id] = true; s.cards += #lane.cards; table.insert(s.lanes, lane)
			end
			s.pages += 1
			local large = job.operation == "sync-board" or job.inspect_read_only
			local max_cards, max_pages = if large then 32768 else 4096, if large then 128 else 64
			if s.cards > max_cards or s.pages > max_pages or (s.pages == max_pages and page.more > 0) then
				stop(fresh, job, "The complete desktop board exceeds its safe snapshot bound (" .. tostring(max_cards) .. " cards / " .. tostring(max_pages) .. " lane pages). Unseen cards were preserved."); return
			end
			if page.more > 0 then
				if #page.lanes == 0 then stop(fresh, job, "Board paging did not advance. Nothing was added."); return end
				s.from += #page.lanes; job.waiting = nil; return
			end
			job.scan = nil
			s.done(fresh, { path = s.path, phase = page.phase, more = 0, lanes = s.lanes })
		end)
	end
	local function boards(cx: any, job: any, done: any)
		watch(cx, job, function(fresh: any) return fresh.board:boards() end, function(fresh: any, rows: any)
			local items, paths = {}, {}
			for _, row in ipairs(rows or {}) do
				if type(row.path) == "string" and not paths[row.path] then paths[row.path] = true; table.insert(items, { label = row.path, path = row.path, current = job.draft.board_path == row.path, detail = "Desktop board — not a file on the execution host" }) end
			end
			table.insert(items, { label = "Choose another desktop board…", custom = true })
			pick(fresh, job, "Choose a Tern board on this desktop", items, function(next_cx: any, choice: any)
				if choice.custom then input_form(next_cx, job, "board_path", "Desktop board file", "desktop", function(final_cx: any, path: string)
					done(final_cx, path)
				end) else job.draft.board_path = choice.path; done(next_cx, choice.path) end
			end)
		end)
	end
	local function intake(cx: any, job: any, path: string, proposal: any?)
		scan(job, path, function(_fresh: any, snapshot: any)
			path = snapshot.path
			compute(job, function()
				local cards, err = adapter.board_intakes(snapshot, coroutine.yield)
				if not cards then return nil, err end
				return { cards = cards, revision = digest(cards) }, nil
			end, function(fresh: any, observed: any, err: any)
				if not observed then stop(fresh, job, err.message); return end
				if proposal then
					if #observed.cards > 256 or observed.revision ~= proposal.revision then stop(fresh, job, "The complete desktop board no longer matches this approved source revision (or exceeds 256 cards). No proposal intake was sent."); return end
					submit(fresh, job, "source_request", { gate_id = job.input.gate_id, gate_revision = job.input.gate_revision, source_revision = observed.revision, cards = observed.cards }); return
				end
				if #observed.cards == 0 then stop(fresh, job, "No independent unfinished tasks on this board. Plan mirrors are presentation only and are not imported again.", "info"); return end
				project(fresh, job, path:match("[^/\\]+$") or "Board work", function(next_cx: any)
					pick(next_cx, job, "Add " .. tostring(#observed.cards) .. (if job.auto_start then " board tasks with saved auto-start?" else " board tasks without starting them?"), {
						{ label = if job.auto_start then "Add board tasks with auto-start" else "Add held board tasks", add = true, detail = "Desktop snapshot; duplicates and plan mirrors excluded" }, { label = "Cancel", cancel = true },
					}, function(_final_cx: any)
						-- Re-read after the owner choice; changed content needs a new decision.
						scan(job, path, function(_check_cx: any, current: any)
							compute(job, function()
								local cards, problem = adapter.board_intakes(current, coroutine.yield)
								return if cards then { cards = cards, revision = digest(cards) } else nil, problem
							end, function(send_cx: any, checked: any, problem: any)
								if not checked or checked.revision ~= observed.revision then stop(send_cx, job, if problem then problem.message else "The board changed after selection. Nothing was added; choose it again."); return end
								local index = 1
								local send_next: any
								send_next = function(current_cx: any)
									local fields = table.clone(checked.cards[index]); fields.board_path = path; fields.orch_project_id = job.project_id
									submit(current_cx, job, "board_intake", fields, function(result_cx: any, result: any)
										job.project_id = job.project_id or result.orch_project_id
										index += 1
										if index > #checked.cards then stop(result_cx, job, if job.auto_start then "Board tasks added with saved auto-start. An orchestration pause remains in effect." else "Board tasks added. START the selected project when ready; nothing was resumed.", "success"); return end
										if not job.project_id then stop(result_cx, job, "The first task was added, but its project identity is unavailable. Remaining tasks were not sent."); return end
										if refresh(result_cx, job) then later(job, send_next) end
									end)
								end
								later(job, send_next)
							end)
						end)
					end)
				end)
			end)
		end)
	end

	local BOARD_MARKER = "<!-- orchplus-linked-board v1 "
	local function board_location(origin: any, configured: any?): (string?, string)
		local scope = codec.sha256(tostring(origin.window_host_id or "") .. "\n" .. tostring(origin.logical_session_id)):sub(1, 24)
		local data = adapter.normalize_root(tern.plugin.data, tern.runtime.os)
		if not data then return nil, scope end
		local folder = data .. "/boards/" .. scope
		if configured == nil or configured == "" then return folder .. "/ORCH+ Board.md", scope end
		if type(configured) ~= "string" or #configured > protocol.BOARD_SETTING_PATH_BYTES or configured:find("[%c]") or utf8.len(configured) == nil then return nil, scope end
		local absolute = adapter.normalize_root(configured, tern.runtime.os)
		if absolute then return absolute, scope end
		if configured:match("^%a:") or configured:sub(1, 1) == "/" or configured:sub(1, 1) == "\\" then return nil, scope end
		local parts = {}
		for segment in configured:gsub("\\", "/"):gmatch("[^/]+") do
			if segment == ".." then return nil, scope end
			if segment ~= "." then table.insert(parts, segment) end
		end
		if #parts == 0 then return nil, scope end
		return folder .. "/" .. table.concat(parts, "/"), scope
	end
	local function source_link(origin: any, path: string, board: string?): string
		local _, scope = board_location(origin)
		return adapter.plan_link_base(scope, path, if board then codec.sha256(board) else nil)
	end
	local function route(cx: any, link: any): boolean
		if type(link.url) ~= "string" or link.url:sub(1, 21) ~= "tern://orchplus-plan?" then return false end
		local parsed = if type(link.pane) == "number" then adapter.parse_plan_link(link.url) else nil
		for source, state in pairs(mirrors) do
			local path = if parsed then state.links[parsed.nav_url] else nil
			if path and api.current(cx, source, state.origin) then
				local board = cx.session:pane(link.pane)
				local expected, scope = board_location(state.origin, state.board_setting)
				if type(board) ~= "table" or board.kind ~= "board" or board.path ~= expected or parsed.scope ~= scope
					or (parsed.board_key and parsed.board_key ~= codec.sha256(expected)) then break end
				-- cx.open follows the current execution host; docs.open is desktop-only.
				cx.layout:focus(source); cx:open(path, "tab")
				return true
			end
		end
		cx:toast("error", "This plan link is not bound to a current ORCH+ Board and connected orchestration.")
		return true
	end
	local function check_board_marker(cx: any, job: any, path: string, marker: string, done: any)
		watch(cx, job, function(fresh: any) return fresh.docs:search(path, BOARD_MARKER) end, function(fresh: any, matches: any)
			-- Search the actual document, not just its first lines: our marker must
			-- never conceal a second orchestration's marker farther down the file.
			if type(matches) ~= "table" or #matches > 1 or (#matches == 1 and (type(matches[1]) ~= "table" or matches[1].text ~= marker)) then
				stop(fresh, job, "This board contains another orchestration's marker or conflicting provenance. Choose a separate desktop board; its content was not changed."); return
			end
			done(fresh, #matches == 1)
		end)
	end
	local function inspect_board(cx: any, job: any, path: string, exists: boolean)
		job.inspect_read_only = true
		local function show(fresh: any, text: string)
			job.waiting = true; job.deadline = nil
			api.forms.open(fresh, job.source, job.origin, { tag = "source-work", title = "Inspect ORCH+ Board",
				description = "A previous native writer has not confirmed completion. This is a read-only snapshot, not the native board editor. Inspection does not clear the pending write or authorize replay.",
				fields = { { id = "snapshot", label = path, kind = "editor", value = text, disabled = true } },
				actions = { { id = "close", label = "Close snapshot", submit = true },
					{ id = "choose-board", label = "Choose separate board…", submit = true } } },
				function(next_cx: any, _values: any, action: string)
					if not active(next_cx, job) then return end
					api.forms.cancel(next_cx, job.source); stop(next_cx, job)
					if action == "choose-board" then api.source_settings(next_cx, job.source, job.origin) end
				end)
		end
		if not exists then
			show(cx, "The desktop board file was not visible when this inspection was requested.\nIts original creation may still complete. No replacement file was written.")
			return
		end
		scan(job, path, function(_fresh: any, snapshot: any)
			compute(job, function()
				local parts, bytes, truncated = {}, 0, false
				local function append(value: string)
					local remaining = 32768 - bytes
					if #value > remaining then
						local cut = remaining
						while cut > 0 do
							local next_byte = value:byte(cut + 1)
							if not next_byte or next_byte < 128 or next_byte >= 192 then break end
							cut -= 1
						end
						value = value:sub(1, cut); truncated = true
					end
					bytes += #value; table.insert(parts, value)
				end
				for _, lane in ipairs(snapshot.lanes) do
					if truncated then break end
					append("\n## " .. (lane.title or "Untitled lane") .. "\n")
					for _, card in ipairs(lane.cards) do
						if truncated then break end
						if type(card.text) ~= "string" or type(card.done) ~= "boolean" then return nil, "The native board returned an invalid card; nothing was changed." end
						append("\n[" .. (if card.done then "x" else " ") .. "] " .. card.text .. "\n")
						coroutine.yield()
					end
				end
				if truncated then table.insert(parts, "\n[Read-only snapshot display limit reached. Remaining native board content is not shown and has not been changed.]\n") end
				return table.concat(parts), nil
			end, function(fresh: any, text: any, err: any)
				if not text then stop(fresh, job, err); return end
				show(fresh, text)
			end)
		end)
	end
	local function ensure_board(cx: any, job: any, done: any)
		local path, scope = board_location(job.origin, job.board_setting)
		if not path then stop(cx, job, "Choose a valid desktop board path; relative locations use this orchestration's desktop board folder."); return end
		job.desktop_board_path = path
		if not job.journal then
			local inspected, pending = pcall(journal_read, path)
			if not inspected then stop(cx, job, "The desktop board sync journal cannot be read safely. Preserve it; no native write was issued: " .. tostring(pending)); return end
			if pending then
				stop(cx, job, "A previous native board sync batch has no confirmed completion. Automatic writes are held even if matching cards are visible. Keep this board unchanged or choose a separate Board location until the original writer's completion is established. Source: " .. pending.source_path .. " · Desktop board: " .. path)
				return
			end
		end
		local marker = BOARD_MARKER .. scope .. " -->"
		local ok, exists = pcall(tern.fs.exists, path)
		if not ok then stop(cx, job, "The desktop ORCH+ Board storage is unavailable."); return end
		if exists then
			check_board_marker(cx, job, path, marker, function(owned_cx: any, owned: boolean)
				if owned then done(owned_cx, path); return end
				watch(owned_cx, job, function(fresh: any) return fresh.docs:read(path, { from = 1, lines = 4 }) end, function(fresh: any, bytes: any)
				if type(bytes) ~= "string" then stop(fresh, job, "The selected desktop board could not be read; it was not changed."); return end
				local mirror = mirrors[job.source]
				if mirror and mirror.declined and mirror.declined.path == path and mirror.declined.head == bytes then stop(fresh, job); return end
				local choices = {
					{ label = "Keep this board unchanged", skip = true },
					{ label = "Link this desktop board", link = true, detail = path .. "\nAdds plan hierarchy/progress mirrors and a provenance marker. Existing human cards remain independent intake; nothing is started." },
				}
				job.waiting = true; job.deadline = nil; job.conflict = true
				local promise = fresh:pick({ placeholder = "Link the existing board to this orchestration?", items = choices, action = "decide" })
				local callback = function(answer: any, err: any, current: any)
					if not current or not active(current, job) then return end
					job.conflict = nil
					if err then stop(current, job, tostring(err)); return end
					if not answer or not answer.link then
						if mirror then mirror.declined = { path = path, head = bytes } end
						stop(current, job); return
					end
					watch(current, job, function(next_cx: any) return next_cx.docs:read(path, { from = 1, lines = 4 }) end, function(check_cx: any, checked: any)
						if checked ~= bytes then stop(check_cx, job, "The board's link/provenance changed during the decision. Nothing was linked; inspect it again."); return end
						check_board_marker(check_cx, job, path, marker, function(marker_cx: any, now_owned: boolean)
							if now_owned then stop(marker_cx, job, "The board's provenance changed during the link decision. Nothing further was changed."); return end
						local key = path .. "\0link-board\0" .. scope
						if uncertain[key] or uncertain_count >= 256 then stop(marker_cx, job, "A prior desktop link write is uncertain. It will not be replayed."); return end
						uncertain[key] = true; uncertain_count += 1
						watch(marker_cx, job, function(native_cx: any) return native_cx.docs:edit(path, { line = 1, insert = marker .. "\n" }) end, function(link_cx: any, result: any)
							if type(result) ~= "table" then stop(link_cx, job, "The desktop link was not confirmed; no write will be repeated."); return end
							clear_uncertainty(key)
							if mirror then mirror.declined = nil end
							done(link_cx, path)
						end, true, range_result, key)
						end)
					end)
				end
				if api.capture then api.capture(job.source, job.origin, promise, callback) else promise:next(callback) end
			end)
			end)
		else
			local key = path .. "\0create-board"
			if uncertain[key] or uncertain_count >= 256 then stop(cx, job, "Creating the ORCH+ Board has an uncertain outcome or the safety bound is full. No write will be repeated."); return end
			local made = pcall(tern.fs.mkdir, path:match("^(.*)/[^/]+$"))
			if not made then stop(cx, job, "The desktop ORCH+ Board directory could not be created."); return end
			uncertain[key] = true; uncertain_count += 1
			local columns = { "Todo", "Doing", "Review", "Done", "Plans" }
			local current = flow(cx, job)
			local configured = if current and current.policy then current.policy.board_lanes or {} else {}
			for _, key_name in ipairs({ "queued", "running", "review", "done" }) do
				local title = configured[key_name]
				if title ~= nil then
					if type(title) ~= "string" or title == "" or title:find("%c") then clear_uncertainty(key); stop(cx, job, "A configured desktop board lane is invalid. No board was written."); return end
					if not table.find(columns, title) then table.insert(columns, title) end
				end
			end
			local seed = "# ORCH+ Board\n\n" .. marker .. "\n"
			for _, title in ipairs(columns) do seed ..= "\n## " .. title .. "\n" end
			watch(cx, job, function(fresh: any)
				return fresh.docs:write(path, seed)
			end, function(fresh: any, result: any)
				if type(result) ~= "table" then stop(fresh, job, "The desktop board file creation was not confirmed; it will not be repeated."); return end
				clear_uncertainty(key); done(fresh, path)
			end, true, range_result, key)
		end
	end
	local function ensure_lanes(cx: any, job: any, path: string, snapshot: any, description: any, done: any)
		local counts, wanted, seen = {}, {}, {}
		for _, lane in ipairs(snapshot.lanes) do if lane.title then counts[lane.title] = (counts[lane.title] or 0) + 1 end end
		for _, item in ipairs(description.creates) do
			local name = item.card.lane
			if not seen[name] then table.insert(wanted, name); seen[name] = true end
		end
		local index, next_lane = 1, nil
		next_lane = function(fresh: any)
			local name = wanted[index]
			if not name then done(fresh); return end
			local key = path .. "\0lane\0" .. name
			if counts[name] == 1 then
				clear_uncertainty(key)
				index += 1; later(job, next_lane); return
			end
			if counts[name] then stop(fresh, job, "The linked board has duplicate task-lane titles. Rename the duplicate lane before automatic synchronization continues."); return end
			if uncertain[key] or uncertain_count >= 256 then stop(fresh, job, "A native lane creation is uncertain or the safety bound is full. It will not be replayed."); return end
			uncertain[key] = true; uncertain_count += 1
			watch(fresh, job, function(native_cx: any) return native_cx.board:add_lane(path, { title = name }) end, function(next_cx: any, id: any)
				if type(id) ~= "string" or id == "" then stop(next_cx, job, "The linked board's native lane creation did not confirm success. It will not be repeated."); return end
				clear_uncertainty(key); counts[name] = 1; index += 1; later(job, next_lane)
			end, true, id_result, key)
		end
		later(job, next_lane)
	end
	local function sync_plan(cx: any, job: any, source: any)
		ensure_board(cx, job, function(_fresh: any, path: string)
			local mirror = mirrors[job.source]
			local url = source_link(job.origin, source.path, path)
			mirror.links[url] = source.path
			-- Existing, human-kept legacy cards retain their genuine old navigation link.
			mirror.links[source_link(job.origin, source.path)] = source.path
			local function describe(snapshot: any): any
				local description, err = adapter.plan_to_board(source.plan, source.path, snapshot, "Plans", coroutine.yield, url)
				return description, err
			end
			local approved = {}
			local function clear(key: string)
				if uncertain[key] then uncertain[key] = nil; uncertain_count -= 1 end
			end
			local operations, index = {}, 1
			local next_write: any
			next_write = function(step_cx: any)
				local op = operations[index]
				if not op then stop(step_cx, job, nil, "success"); return end
				-- Read before every write. Native model ids survive our edits, not external
				-- reloads; current provenance and human baselines are re-established here.
				scan(job, path, function(_scan_cx: any, snapshot: any)
					compute(job, function() return describe(snapshot) end, function(write_cx: any, latest: any, err: any)
						if not latest then stop(write_cx, job, err.message); return end
						local selected, kind = nil, nil
						for _, item in ipairs(latest.creates) do if item.task_id == op.task_id then selected, kind = item, "create" end end
						for _, item in ipairs(latest.updates) do if item.task_id == op.task_id then selected, kind = item, "update" end end
						for _, conflict in ipairs(latest.conflicts) do if conflict.task_id == op.task_id then
							local consent = approved[op.task_id]
							if not consent or quota.canonical(consent) ~= quota.canonical(conflict) then
								stop(write_cx, job, "A board conflict changed after the decision. No further writes were made."); return
							end
							selected, kind = { card_id = conflict.card_id, fields = conflict.proposed_fields, done = conflict.proposed_done,
								check_required = conflict.proposed_done ~= nil and conflict.proposed_done ~= conflict.current_done }, "update"
						end end
						local key = path .. "\0" .. source.path .. "\0" .. op.task_id
						if not selected then
							if not table.find(latest.unchanged, op.task_id) then stop(write_cx, job, "The source hierarchy changed before its board write."); return end
							clear(key); index += 1; later(job, next_write); return
						end
						if kind ~= op.kind or (kind == "update" and (selected.card_id ~= op.card_id or quota.canonical(selected.fields) ~= quota.canonical(op.fields) or selected.done ~= op.done)) then
							stop(write_cx, job, "The desktop mirror changed before its board write. Nothing further was overwritten."); return
						end
						if uncertain[key] then stop(write_cx, job, "A prior board write has an uncertain outcome. It will not be repeated; inspect the board before reconciling it."); return end
						if uncertain_count >= 256 then stop(write_cx, job, "Unresolved desktop writes fill the safety bound. No more board writes were issued."); return end
						uncertain[key] = true; uncertain_count += 1
						watch(write_cx, job, function(native_cx: any)
							return if kind == "create" then native_cx.board:add(path, selected.card) else native_cx.board:edit(selected.card_id, selected.fields)
						end, function(done_cx: any, result: any)
							if (kind == "create" and (type(result) ~= "string" or result == "")) or (kind == "update" and result ~= true) then
								stop(done_cx, job, "The native board write did not confirm success. It will not be repeated."); return
							end
							local card_id = if kind == "create" then result else selected.card_id
							local function finish(_cx: any)
								clear(key); index += 1; later(job, next_write)
							end
							if not selected.check_required then finish(done_cx)
							else
								watch(done_cx, job, function(native_cx: any) return native_cx.board:check(card_id, selected.done) end, function(check_cx: any, checked: any)
									if checked ~= true then stop(check_cx, job, "The explicit plan progress was not confirmed on the native board. No write will be repeated."); return end
									finish(check_cx)
								end, true, boolean_result, key)
							end
						end, true, if kind == "create" then id_result else boolean_result, key)
					end)
				end)
			end
			scan(job, path, function(_scan_cx: any, snapshot: any)
				compute(job, function() return describe(snapshot) end, function(review_cx: any, description: any, err: any)
					if not description then stop(review_cx, job, err.message); return end
					for _, id in ipairs(description.unchanged) do clear(path .. "\0" .. source.path .. "\0" .. id) end
					for _, item in ipairs(description.creates) do table.insert(operations, { task_id = item.task_id, kind = "create" }) end
					for _, item in ipairs(description.updates) do table.insert(operations, { task_id = item.task_id, kind = "update", card_id = item.card_id, fields = item.fields, done = item.done }) end
					local conflict_index, review = 1, nil
					review = function(fresh: any)
						local conflict = description.conflicts[conflict_index]
						if not conflict then
							if #operations == 0 then stop(fresh, job, nil, "success"); return end
							read_plan(fresh, job, source.path, source.revision, function(_check_cx: any)
								later(job, next_write)
							end)
							return
						end
						local conflict_key = source.path .. "\0" .. conflict.task_id
						local signature = conflict.signature
						if mirror.kept[conflict_key] == signature then conflict_index += 1; later(job, review); return end
						local choices = { { label = "Keep my board version", skip = true, detail = conflict.code } }
						if conflict.code == "human_edit" then table.insert(choices, { label = "Use the current plan version", overwrite = true,
							detail = "Board checked: " .. tostring(conflict.current_done) .. "\nPlan checked: "
								.. (if conflict.proposed_done == nil then "not declared; preserve the current check" else tostring(conflict.proposed_done))
								.. "\n\nBoard:\n" .. conflict.current_text .. "\n\nPlan:\n" .. conflict.proposed_text }) end
						-- This is a consequential human-edit decision, not source navigation.
						job.waiting = true; job.deadline = nil; job.conflict = true
						local promise = fresh:pick({ placeholder = "Plan / board conflict — " .. conflict.task_id, items = choices, action = "decide" })
						local callback = function(answer: any, problem: any, current: any)
							if not current or not active(current, job) then return end
							job.conflict = nil
							if problem or not answer then stop(current, job, if problem then tostring(problem) else nil); return end
							if answer.overwrite then
								approved[conflict.task_id] = conflict
								table.insert(operations, { task_id = conflict.task_id, kind = "update", card_id = conflict.card_id, fields = conflict.proposed_fields, done = conflict.proposed_done })
							else mirror.kept[conflict_key] = signature end
							conflict_index += 1; later(job, review)
						end
						if api.capture then api.capture(job.source, job.origin, promise, callback) else promise:next(callback) end
					end
					ensure_lanes(review_cx, job, path, snapshot, description, function(_ready: any) later(job, review) end)
				end)
			end)
		end)
	end
	-- One bounded scheduler in the existing owning window, including while paused.
	-- No board is a second source of plan execution and no independent daemon is involved.
	local function sync(cx: any, source: number, origin: any, plans: any?)
		if not api.current(cx, source, origin) then mirrors[source] = nil; return end
		local state = mirrors[source]
		if not state or state.alias ~= origin.alias_nonce then
			state = { alias = origin.alias_nonce, origin = origin, cursor = 0, next_at = 0, kept = {}, links = {} }; mirrors[source] = state
		end
		state.origin = origin
		if jobs[source] or now() < state.next_at then return end
		local count = 0; for _ in pairs(jobs) do count += 1 end
		if count >= 16 then state.next_at = now() + 1000; return end
		local model = api.node(cx, source, "workflow-index", "orchplus.workflow")
		state.board_setting = if model and model.policy then model.policy.board_path or "" else ""
		local ids = if plans then plans else (if model then model.plan_ids or {} else {})
		if #ids == 0 then state.next_at = now() + 5000; return end
		state.cursor = state.cursor % #ids + 1
		local row = ids[state.cursor]
		local plan = if type(row) == "table" then row else api.node(cx, source, "workflow-plan-" .. tostring(row), "orchplus.plan")
		if not plan or type(plan.path) ~= "string" then state.next_at = now() + 5000; return end
		local job = { source = source, origin = origin, operation = "sync-board", input = {}, draft = {}, paused = true, auto_start = false, board_setting = state.board_setting }
		jobs[source] = job
		read_plan(cx, job, plan.path, nil, function(fresh: any, selected: any) sync_plan(fresh, job, selected) end)
	end

	local function start(cx: any, source: number, origin: any, command: string, request: any)
		if not api.current(cx, source, origin) then return end
		local existing = jobs[source]
		if existing and existing.operation == "sync-board" and not existing.effect and not existing.conflict then stop(cx, existing); existing = nil end
		if existing then api.notice(cx, source, origin.alias_nonce, "A source selection, decision or native write is still pending. Settle that operation before choosing another source."); return end
		local count = 0; for _ in pairs(jobs) do count += 1 end
		if count >= 16 then api.notice(cx, source, origin.alias_nonce, "Finish a pending source selection before opening another."); return end
		request = request or {}
		local key = tostring(source) .. "|" .. origin.alias_nonce .. "|" .. command
		if not drafts[key] then
			serial += 1; drafts[key] = { serial = serial }
			if serial > 64 then for old, draft in pairs(drafts) do if draft.serial <= serial - 64 then drafts[old] = nil end end end
		end
		local job: any = { source = source, origin = origin, operation = command, input = request, draft = drafts[key], project_id = request.orch_project_id }
		jobs[source] = job
		local model = flow(cx, job)
		local policy = if model then model.policy else nil
		job.paused = policy and policy.paused == true
		job.auto_start = policy and policy.auto_start_projects == true and command ~= "source-proposal"
		if command == "work-on" and (not policy or policy.glitch_integration ~= true or policy.work_on_enabled == false) then stop(cx, job, "WORK ON is available with Glitch integration and WORK ON enabled. Use Add plan file…, Add board… or Start from template… in project overflow."); return end
		if command == "work-on" then work_on(cx, job)
		elseif command == "add-plan" then custom_plan(cx, job, function(fresh: any, plan: any) add_plan(fresh, job, plan) end)
		elseif command == "start-template" then template(cx, job)
		elseif command == "add-board" then boards(cx, job, function(fresh: any, path: string) intake(fresh, job, path, nil) end)
		elseif command == "open-plan-board" then
			job.board_setting = if policy then policy.board_path or "" else ""
			local path = board_location(origin, job.board_setting)
			if not path then stop(cx, job, "Choose a valid desktop Board location in settings."); return end
			local read_ok, pending = pcall(journal_read, path)
			if not read_ok or pending then
				local exists_ok, exists = pcall(tern.fs.exists, path)
				if not exists_ok then stop(cx, job, "The desktop board cannot be inspected safely. No file or pending journal was changed."); return end
				inspect_board(cx, job, path, exists); return
			end
			ensure_board(cx, job, function(fresh: any, selected_path: string)
				local opened, pane = pcall(function() return fresh.board:open(selected_path, { how = "tab" }) end)
				stop(fresh, job, if opened and type(pane) == "number" then nil else "The native board could not be opened: " .. tostring(pane))
			end)
		elseif command == "source-proposal" then
			local gate = api.node(cx, source, "workflow-gate-" .. tostring(request.gate_id), "orchplus.gate")
			local proposed = gate and gate.source_request
			if not gate or gate.revision ~= request.gate_revision or not proposed or proposed.kind ~= "board" then stop(cx, job, "This approved board proposal is no longer awaiting its desktop source."); return end
			intake(cx, job, proposed.path, proposed)
		else stop(cx, job, "Unknown source operation; nothing was added.") end
	end
	local function advance(cx: any, job: any, deadline: number): boolean
		if job.native_inactive then stop(cx, job, job.native_notice); return false end
		if not active(cx, job) then
			if job.effect and job.deadline and now() < job.deadline then return false end
			local message = if job.request_id then "The import command was already sent before the source context changed. Its outcome is unknown; it was not cancelled or retried."
				elseif job.decision then "The source context changed before import authorization was confirmed. No import command was sent."
				elseif job.effect then "The native board write has not confirmed completion after its source context changed. Its outcome is unknown and it was not repeated."
				else nil
			stop(cx, job, message); return false
		end
		if job.deadline and now() >= job.deadline then stop(cx, job, "The source operation has not confirmed its outcome. It will not be retried. Your entered text and selection are retained."); return false end
		if job.discovery then
			local response = api.node(cx, job.source, "source-discovery", "orchplus.sources")
			if not response or response.request_id ~= job.discovery.request_id then return false end
			local done = job.discovery.done; job.discovery = nil; later(job, function(fresh: any) done(fresh, response) end)
		elseif job.decision then
			local result = api.node(cx, job.source, "decision-context-result", "orchplus.decision")
			if not result or result.request_id ~= job.decision.request_id then return false end
			local decision = job.decision; job.decision = nil
			if not result.decision_context then stop(cx, job, "Project creation settings changed. Your selection is retained; nothing was created.")
			else
				decision.fields.decision_context = result.decision_context
				submit(cx, job, job.command, decision.fields, decision.done)
			end
		elseif job.request_id then
			local data = api.snapshot(cx, job.source)
			local result = nil
			for _, key in { "command_result", "driver_result", "result" } do
				local candidate = if data then data[key] else nil
				if candidate and candidate.request_id == job.request_id then result = candidate; break end
			end
			if not result then return false end
			job.request_id = nil
			if result.ok ~= true then stop(cx, job, tostring(result.message or result.code or "Source was refused") .. ". Your entered text is retained; no retry was sent.")
			elseif job.result then local done = job.result; job.result = nil; later(job, function(fresh: any) done(fresh, result) end)
			else
				local message = result.message
				if not message or message == result.code then
					message = if job.paused then "Work added. New work remains paused."
						elseif job.auto_start then "Work added. Automatic start is on."
						else "Work added. Select START when you are ready."
				end
				stop(cx, job, tostring(message), "success")
			end
		elseif job.compute then
			while now() < deadline and job.compute do
				local ok, value, err = coroutine.resume(job.compute)
				if not ok then stop(cx, job, "Source transformation failed: " .. tostring(value)); return false end
				if coroutine.status(job.compute) == "dead" then
					local done = job.computed; job.compute = nil; job.computed = nil
					later(job, function(fresh: any) done(fresh, value, err) end)
				end
			end
		elseif job.next then local step = job.next; job.next = nil; step(cx)
		elseif job.scan and not job.waiting then scan_step(cx, job)
		else return false end
		return true
	end
	local function tick(cx: any)
		local deadline = now() + 8
		for source, state in pairs(mirrors) do
			if not jobs[source] and not api.current(cx, source, state.origin) then mirrors[source] = nil end
		end
		for _, job in pairs(jobs) do
			-- Correlated receipts, pure transforms and their continuations are already
			-- runnable. Do not add another 500ms timer delay to every such stage.
			for _ = 1, 16 do
				if now() >= deadline or jobs[job.source] ~= job then break end
				local io_epoch = job.io_epoch
				if not advance(cx, job, deadline) then break end
				-- Even an already-resolved awaitable is an I/O boundary. Its next
				-- continuation runs in a later turn, never recursively in a callback.
				if job.waiting or job.io_epoch ~= io_epoch then break end
			end
		end
	end
	return { start = start, tick = tick, sync = sync, route = route, active = function(source: number) return jobs[source] ~= nil end,
		board_path = function(origin: any, configured: any?): string? local path = board_location(origin, configured); return path end }
end
return M
