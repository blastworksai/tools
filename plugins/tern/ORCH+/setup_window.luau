--!strict
-- Drafts live only in this window; every committed value belongs to the host authority.
local M = {}
function M.new(api: any): any
	local pending: any = {}
	local function fail(cx: WindowCx, message: string) cx:toast("error", "ORCH+ setup", message) end
	local function index(cx: WindowCx, source: number): any?
		local _, bytes = api.surface(cx, source, "orchplus.orchestrator", "orchplus.setup", "setup-index", 65536)
		return if bytes then api.decode(bytes, 65536) else nil
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
	local function origin(cx: WindowCx, source: number, data: any?): any?
		local binding = identity(cx, source, data)
		if not binding or cx.session:view(source) == nil or cx.hosts:current().state ~= "connected"
			or binding.window_host_id ~= tostring(cx.hosts:current().id)
			or binding.native_session_id ~= tostring(cx.sessions:current().id) then return nil end
		return binding
	end
	local function live(cx: WindowCx, s: any): any?
		local data = index(cx, s.source)
		if not data or data.source_nonce ~= s.nonce or not api.same(origin(cx, s.source, data), s.origin) then return nil end
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
		if not data then return fail(cx, "Setup view moved or reloaded. Reopen setup; nothing was repeated.") end
		local request = { source_nonce = s.nonce, request_id = api.id(), kind = kind, expected_revision = s.revision, setup_origin = s.origin }
		for key, value in fields do request[key] = value end
		local act = if kind == "verify_repository" then "setup-repository-probe" else "setup-command"
		if kind == "verify_repository" then request = { source_nonce = s.nonce, request_id = request.request_id, cwd = fields.cwd, target_ref = fields.target_ref } end
		cx.session:event(s.source, { ev = "action", id = "main.setup-index", act = act, value = tern.json.encode(request) })
		if done then
			s.wait = { id = request.request_id, done = done, started = tern.now(), writes_config = kind ~= "verify_repository" }
			pending[s.source] = s
		end
	end
	local function pick(cx: WindowCx, s: any, title: string, items: any, done: any)
		cx:pick({ placeholder = title, items = items }):next(function(choice: any, err: string?, fresh: WindowCx?)
			if not fresh or not choice or err then return end
			if not live(fresh, s) then return fail(fresh, "Setup context changed. Reopen setup.") end
			done(fresh, choice)
		end)
	end
	local function prompt(cx: WindowCx, s: any, title: string, value: string?, done: any)
		cx:prompt({ placeholder = title, value = value }):next(function(text: string?, err: string?, fresh: WindowCx?)
			if not fresh or text == nil or err then return end
			if not live(fresh, s) then return fail(fresh, "Setup context changed. Reopen setup.") end
			done(fresh, text)
		end)
	end
	local function completed(cx: WindowCx, s: any)
		pick(cx, s, "Required setup complete; optional provider readiness is separate", {
			{ label = "Finish setup", detail = "Save verified configuration; do not launch a provider task", state = if s.adopt then "adopted_existing" else "completed" },
			{ label = "Keep configuration, finish later", state = "in_progress" },
		}, function(fresh: WindowCx, choice: any)
			local fields: any = { state = choice.state }
			if choice.state == "completed" or choice.state == "adopted_existing" then
				fields.catalog_version = 2; fields.spawn_setup = s.catalog.setup; fields.records = s.selected
			end
			send(fresh, s, "setup_lifecycle", fields, function(last: WindowCx)
				last:toast("info", "ORCH+ setup saved", "Required setup and optional readiness are separate. Existing session overrides were not changed.")
			end)
		end)
	end
	local function save(cx: WindowCx, s: any)
		local found = false
		for _, route in s.defaults.policy.routes do
			if route.class == "build" then route.record_id = s.defaults.builder_record; found = true end
		end
		if not found then table.insert(s.defaults.policy.routes, { class = "build", record_id = s.defaults.builder_record }) end
		send(cx, s, "installation_defaults", { defaults = s.defaults }, function(fresh: WindowCx)
			if s.wizard then completed(fresh, s) else fresh:toast("info", "Installation defaults saved", "Only new sessions inherit these values; existing session overrides are unchanged.") end
		end)
	end
	local roles = { { key = "builder_record", label = "Builder", capability = "check-runner-v1" },
		{ key = "release_manager_record", label = "Release manager", capability = "release-manager-v1", policy = true },
		{ key = "reviewer_records", label = "Reviewer", policy = true },
		{ key = "coordinator_record", label = "Coordinator (optional)", capability = "coordinator-control-v1", optional = true },
		{ key = "labeller_record", label = "Labeller (optional)", policy = true, optional = true } }
	local choose_role: any
	choose_role = function(cx: WindowCx, s: any, position: number)
		local role = roles[position]
		if not role then return save(cx, s) end
		if role.key == "reviewer_records" and not s.defaults.policy.require_code_review then
			s.defaults.policy.reviewer_records = tern.json.array(); return choose_role(cx, s, position + 1)
		end
		local items = {}
		if role.optional then table.insert(items, { label = "None — optional", none = true }) end
		for _, record in s.catalog.records do
			local capabilities = record.capabilities or {}
			if record.enabled == true and record.eligible == true and table.find(capabilities, "report-files-v1") and (not role.capability or table.find(capabilities, role.capability))
				and (role.key ~= "release_manager_record" or record.id ~= s.defaults.builder_record)
				and (role.key ~= "reviewer_records" or (record.id ~= s.defaults.builder_record and record.id ~= s.defaults.policy.release_manager_record)) then
				table.insert(items, { label = record.id, detail = tostring(record.provider or "unknown family") .. " · " .. tostring(record.backend or "native") .. " · " .. tostring(record.cwd or "") .. " · declared identity, not isolation", record = record })
			end
		end
		if #items == 0 then
			local separation = if role.key == "release_manager_record" then " The signer must use a record other than the builder's."
				elseif role.key == "reviewer_records" then " The reviewer must use a record other than both the builder's and release manager's." else ""
			return fail(cx, "No eligible " .. role.label .. " record." .. separation .. " Open SPAWN managed setup, provision/probe/attest the required capability, then reopen ORCH+ setup.")
		end
		pick(cx, s, "Select " .. role.label .. " — verified SPAWN catalog", items, function(fresh: WindowCx, choice: any)
			local value = if choice.none then "" else choice.record.id
			local function selected(last: WindowCx)
				if role.key == "reviewer_records" then
					if s.defaults.policy.require_other_family then
						local family = s.defaults.policy.family_map[value] or api.family(choice.record.provider)
						local builder = s.builder
						local builder_family = s.defaults.policy.family_map[builder.id] or api.family(builder.provider)
						if not family or not builder_family or family == builder_family then return fail(last, "Different-family review requires known, different declared families. Choose compatible records; no identity isolation is inferred.") end
					end
					s.defaults.policy.reviewer_records = tern.json.array({ value })
				elseif role.policy then s.defaults.policy[role.key] = value else s.defaults[role.key] = value end
				if choice.record then table.insert(s.selected, choice.record) end
				if role.key == "builder_record" then s.builder = choice.record end
				choose_role(last, s, position + 1)
			end
			if choice.record and s.defaults.policy.require_code_review and (role.key == "builder_record" or role.key == "reviewer_records")
				and not s.defaults.policy.family_map[value] and not api.family(choice.record.provider) then
				prompt(fresh, s, "Declare provider family for " .. value .. " (guidance, not verified identity isolation)", nil, function(last: WindowCx, family: string)
					if #family == 0 or #family > 24 or not family:match("^[a-z][a-z0-9%-]*$") then return fail(last, "Family must be a lowercase provider-family name with optional hyphens, at most 24 bytes.") end
					s.defaults.policy.family_map[value] = family
					selected(last)
				end)
			else selected(fresh) end
		end)
	end
	local function query(cx: WindowCx, s: any, cursor: any?)
		local request = { schema = 1, origin = "orchplus", op = "catalog", request_id = api.id(), action_id = api.id(), setup_origin = s.origin, cursor = cursor }
		s.query = request; s.query_started = tern.now(); s.sent = false; s.reply = nil
		send(cx, s, "catalog_request", { request = request })
		pending[s.source] = s
	end
	local function catalog(cx: WindowCx, s: any)
		s.bridge = cx:new_block("spawn.dispatch", {}, "beside")
		if not s.bridge then return fail(cx, "Compatible SPAWN is unavailable on this execution host. Install/enable it; no controller was fabricated.") end
		s.catalog = nil; s.selected = tern.json.array(); query(cx, s)
	end
	local function repository(cx: WindowCx, s: any)
		local previous = s.defaults.repository or {}
		prompt(cx, s, "Repository checkout path on this execution host (Git will verify it)", previous.cwd, function(fresh: WindowCx, cwd: string)
			prompt(fresh, s, "Existing target ref to verify (for example refs/heads/main)", previous.target_ref, function(next_cx: WindowCx, target: string)
				pick(next_cx, s, "Owner-declared landing queue — never inferred from provider", {
					{ label = "repository_queue", detail = "Repository-side queue is the landing route", route = "repository_queue" },
					{ label = "orch_queue", detail = "ORCH local queue; not distributed repository protection", route = "orch_queue" },
				}, function(last: WindowCx, choice: any)
					send(last, s, "verify_repository", { cwd = cwd, target_ref = target }, function(verified: WindowCx, result: any)
						local current = live(verified, s)
						local evidence = result.repository or (if current then current.setup_repository else nil)
						if type(evidence) ~= "table" then return fail(verified, "Host repository verification returned no evidence; configuration was not saved.") end
						s.defaults.repository = api.copy(evidence); s.defaults.repository.queue_route = choice.route
						catalog(verified, s)
					end)
				end)
			end)
		end)
	end
	local function review(cx: WindowCx, s: any)
		pick(cx, s, "Choose review policy explicitly — declared checks always required", {
			{ label = "Require review from a different provider family", review = true, family = true },
			{ label = "Require review; same provider family allowed", review = true, family = false },
			{ label = "Disable code review; retain all declared checks", review = false, family = false },
		}, function(fresh: WindowCx, choice: any)
			s.defaults.policy.require_code_review = choice.review; s.defaults.policy.require_other_family = choice.family
			repository(fresh, s)
		end)
	end
	local function start(cx: WindowCx, source: number, command: string)
		if command == "spawn" then
			-- A cold authority has no setup-index. Navigation needs only the actual native source.
			local binding = origin(cx, source, nil)
			if not binding then return fail(cx, "Setup requires a live ORCH view in this native session on the connected execution host.") end
			return spawn_managed(cx, { source = source, origin = binding })
		end
		local data = index(cx, source)
		local binding = if data then origin(cx, source, data) else nil
		if not binding then return fail(cx, "Setup requires a live ORCH view in this native session on the connected execution host.") end
		if not data.installation_defaults then return fail(cx, "Initialize a genuinely absent ORCH authority through its first-use confirmation, or restore/recheck an existing store, then reopen setup.") end
		local defaults = api.copy(data.installation_defaults); defaults.revision = nil
		local s = { source = source, nonce = data.source_nonce, origin = binding, revision = data.installation_defaults.revision,
			defaults = defaults, wizard = command ~= "defaults", adopt = data.setup.review_existing == true }
		if command == "dismiss" then return send(cx, s, "setup_lifecycle", { state = "dismissed" }, function(fresh: WindowCx) fresh:toast("info", "Setup dismissed", "Configuration remains available in Installation defaults.") end) end
		pick(cx, s, if s.adopt then "Review existing setup — no resources will be replaced" else "ORCH+ setup on " .. tostring(cx.hosts:current().name or cx.hosts:current().id), {
			{ label = "Configure ORCH installation defaults", detail = "Host Git verification, explicit review policy and catalog role selection; no SSH/sudo required for same-user local setup", configure = true },
			{ label = "Open SPAWN managed setup first", detail = "Detect actual account/route, create helpers, probe and attest owned resources", spawn = true },
		}, function(fresh: WindowCx, choice: any)
			if choice.spawn then return spawn_managed(fresh, s) end
			if s.wizard then send(fresh, s, "setup_lifecycle", { state = "in_progress" }, function(last: WindowCx) review(last, s) end)
			else review(fresh, s) end
		end)
	end
	local function tick(cx: WindowCx)
		for source, s in pending do
			-- Native identity survives a hidden surface or a different current UI scope.
			-- Only already-issued observations may proceed until the source is visible.
			local binding = identity(cx, source, nil)
			if binding then binding.host_pane_id = s.origin.host_pane_id end
			if not api.same(binding, s.origin) then pending[source] = nil; continue end
			local data = index(cx, source)
			if data and (data.source_nonce ~= s.nonce or not api.same(identity(cx, source, data), s.origin)) then
				pending[source] = nil; continue
			end
			local visible = origin(cx, source, nil) ~= nil
			if visible and not data then pending[source] = nil; continue end
			if s.wait then
				local result = if data then data.setup_result or data.result else nil
				if not s.wait.result and result and result.request_id == s.wait.id then
					s.wait.result = result
					if not s.wait.writes_config and not result.repository then result.repository = data.setup_repository end
				end
				if not visible then continue end
				result = s.wait.result
				if result then
					local done, writes_config = s.wait.done, s.wait.writes_config
					s.wait = nil; pending[source] = nil
					if result.ok ~= true then fail(cx, tostring(result.message or result.code or "Setup write refused; reopen current settings."))
					elseif writes_config and (type(result.config_revision) ~= "number" or result.config_revision < 0
						or result.config_revision > 9007199254740991 or result.config_revision % 1 ~= 0) then
						fail(cx, "Setup write returned no valid configuration revision. Reopen current settings; no write was repeated.")
					else
						if writes_config then s.revision = result.config_revision end
						done(cx, result)
					end
				elseif tern.now() - s.wait.started > 30000 then pending[source] = nil; fail(cx, "Setup result unavailable. Inspect current defaults before trying again; no write was repeated.") end
			elseif s.query then
				local node, bytes = api.surface(cx, s.bridge, "spawn.dispatch", "spawn.dispatch.response", nil, 65536)
				if not s.sent and visible and node and tern.now() - s.query_started <= 30000 then
					local _, published = api.surface(cx, source, "orchplus.orchestrator", "orchplus.setup.request", "setup-catalog-request", 8192)
					local published_request = if published then api.decode(published, 8192) else nil
					if api.same(published_request, s.query) then
						cx.session:event(s.bridge, { ev = "action", id = node.id, act = "catalog", value = published }); s.sent = true
					end
				end
				if s.sent and not s.reply and bytes then
					local reply = api.decode_setup_response(bytes, s.query)
					if reply and reply.status ~= "pending" then s.reply = reply end
				end
				if not visible then continue end
				local reply = s.reply
				-- Observe a correlated reply before applying the original bounded deadline.
				if not reply then
					if tern.now() - s.query_started > 30000 then pending[source] = nil; send(cx, s, "catalog_clear", {}); fail(cx, "SPAWN catalog did not answer. Setup is incomplete, not inferred from saved records.") end
					continue
				end
				pending[source] = nil; s.reply = nil; send(cx, s, "catalog_clear", {})
				local payload = reply.payload
				if reply.status ~= "catalog" then
					fail(cx, "SPAWN setup catalog unavailable/incompatible: " .. tostring(if reply.error then reply.error.message or reply.error.code else reply.status)); continue
				end
				if not s.catalog then s.catalog = payload else
					if s.catalog.config_revision ~= payload.config_revision then fail(cx, "SPAWN configuration changed during pagination. Reopen setup."); continue end
					for _, record in payload.records do table.insert(s.catalog.records, record) end
				end
				if payload.next_cursor then query(cx, s, payload.next_cursor); continue end
				s.query = nil
				if payload.setup.state ~= "completed" and payload.setup.state ~= "adopted_existing" then
					pick(cx, s, "SPAWN required setup is " .. tostring(payload.setup.state), { { label = "Open SPAWN managed setup — create, probe and attest", spawn = true } }, function(fresh: WindowCx) spawn_managed(fresh, s) end)
				else choose_role(cx, s, 1) end
			end
		end
	end
	return { start = start, tick = tick }
end
return M
