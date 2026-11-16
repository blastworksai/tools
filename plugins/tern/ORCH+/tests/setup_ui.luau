-- Native setup UI behavioral tests; no provider process is launched by this fixture.
local root = ...
local runtime, environment = tern, getfenv()
local clock = 0
local setup_runtime = setmetatable({ now = function() return clock end }, { __index = runtime })
local modules = {}
local function load(name)
	name = name:gsub("^%./", "")
	if modules[name] ~= nil then return modules[name] end
	local chunk = assert(loadstring(runtime.fs.read(root .. "/" .. name .. ".luau"), name))
	setfenv(chunk, setmetatable({ require = load, tern = if name == "setup_window" then setup_runtime else runtime }, { __index = environment }))
	local result = chunk(); modules[name] = result; return result
end
local module, dispatch, codec, state = load("setup_window"), load("dispatch"), load("wire/codec"), load("state")
local protocol = load("dispatch_protocol")
local function frame(body, change)
	local bytes = runtime.json.encode(body)
	local envelope = { schema = 2, op = body.op, request_id = body.request_id, complete = true,
		body_bytes = #bytes, body_sha256 = codec.sha256(bytes), body_json = bytes }
	if change then change(envelope) end
	return "SPAWN_DISPATCH v2 " .. runtime.json.encode(envelope)
end
local checks = 0
local function check(value, message) assert(value, message); checks += 1 end
local function copy(value)
	if type(value) ~= "table" then return value end
	local out = if getmetatable(value) ~= nil or #value > 0 then runtime.json.array() else {}
	for key, child in value do out[key] = copy(child) end; return out
end
local function same(a, b)
	if type(a) ~= type(b) then return false end
	if type(a) ~= "table" then return a == b end
	for k, v in a do if not same(v, b[k]) then return false end end
	for k in b do if a[k] == nil then return false end end
	return true
end
local function find_node(node, predicate)
	if predicate(node) then return node end
	for _, child in node.c or {} do local found = find_node(child, predicate); if found then return found end end
	return nil
end
local function span_text(node)
	local spans = if node and node.p then node.p.spans else nil
	if type(spans) ~= "table" or #spans ~= 1 then return nil end
	local value = spans[1]; return if type(value) == "string" then value elseif type(value) == "table" then value.t else nil
end
local function fixture(registry)
	if registry == nil then
		registry = state.new_registry()
		-- Configuration revisions belong to the authority history; never seed them ahead of it.
		registry.revision = 4
		registry.installation_defaults.revision = 4; registry.setup.config_revision = 4
	end
	assert(state.valid(registry), "setup fixture must begin with valid current authority")
	local data = { version = 1, source_nonce = "view", host_pane_id = "host-pane", setup = copy(registry.setup),
		authority_namespace = registry.authority_namespace, authority_revision = registry.revision,
		installation_defaults = copy(registry.installation_defaults) }
	local f = { registry = registry, data = data, picks = {}, prompts = {}, events = {}, event_panes = {}, toasts = {}, migrations = {},
		new_blocks = {}, focused = {}, navigation = {}, host_id = 2, session_id = 3, window = "",
		panes = { [9] = { pane = 9, tab = 1, block = "orchplus.orchestrator" } },
		pane_hosts = { [9] = 2 }, hosts = { [2] = { id = 2, state = "connected", kind = "local" },
			[7] = { id = 7, state = "connected", kind = "remote" } },
		membership = { [1] = 3, [2] = 4, [3] = 3 }, hidden = {}, listed = {} }
	local cx = { session = {}, hosts = {}, sessions = {}, layout = {} }; f.cx = cx
	function cx.session:pane(id) return f.panes[id] end
	function cx.session:panes()
		local rows = {}; for _, pane in f.panes do table.insert(rows, pane) end
		for _, pane in f.listed do table.insert(rows, pane) end
		return rows
	end
	function cx.session:view(id) return if f.panes[id] and not f.hidden[id] then { id = "main" } else nil end
	function cx.layout:focus(id)
		table.insert(f.focused, id); table.insert(f.navigation, { kind = "focus", pane = id })
		if f.hide_source_on_form_focus then f.hidden[9] = if id == 20 then true else nil end
		if f.focus_error then error("native focus refused") end
	end
	function cx.layout:close(id) f.panes[id] = nil; f.hidden[id] = nil end
	local form_def = load("form_host").definition
	function f:click(encoded)
		local node = find_node(form_def.view(self.form, {}).main, function(n) return n.k == "button" and n.p and n.p.actions and n.p.actions.click == encoded end)
		if not node or node.p.disabled or node.p.busy then return false end
		local act, value = encoded:match("^([^=]+)=(.*)$")
		form_def.event(self.form, { ev = "action", id = node.p.key or "main", act = act or encoded, value = value }, {})
		return true
	end
	function f:reveal(group)
		if not group then return end
		for _, entry in self.form.spec.groups do if entry.id == group then
			self:reveal(entry.parent)
			if self.form.collapsed[group] then assert(self:click("form-group=" .. group), "native disclosure action missing") end
			return
		end end
	end
	function cx.session:event(pane, event)
		if pane == 20 and f.form then form_def.event(f.form, event, {}); return end
		if event.act == "page-entry" then
			table.insert(f.navigation, { kind = "event", pane = pane, event = event })
			if f.event_error then error("native event refused") end
		end
		table.insert(f.event_panes, pane)
		table.insert(f.events, event)
		local value = runtime.json.decode(event.value)
		if value.kind == "catalog_request" then f.catalog_request = value.request; f.issued_catalog_request = value.request end
		if value.kind == "catalog_clear" then f.catalog_request = nil end
	end
	function cx.hosts:current() return f.hosts[f.host_id] end
	function cx.sessions:current() return { id = f.session_id } end
	function cx:window_key() return f.window end
	function cx:pick(options) table.insert(f.picks, options); return { next = function(_, fn) f.answer = fn end } end
	function cx:prompt(options) table.insert(f.prompts, options); return { next = function(_, fn) f.answer = fn end } end
	function cx:toast(_, title, message) table.insert(f.toasts, { title, message }) end
	function cx:new_block(block, args, how, opts)
		local call = { block = block, args = args, how = how, opts = opts }
		table.insert(f.new_blocks, call)
		if block == "orchplus.form" then
			f.panes[20] = { pane = 20, tab = 1, block = block }; f.pane_hosts[20] = 2
			f.form = form_def.init({}, args, nil); return 20
		end
		if block == "spawn.spawner" then
			table.insert(f.navigation, { kind = "new", call = call })
			if f.new_error then error("native launch refused") end
			return if f.unavailable then nil else 11
		end
		return 10
	end
	local serial = 0
	local api = { surface = function(_, pane, block, _, key)
		if pane == 20 and key == "form-result" and f.form then
			local node = find_node(form_def.view(f.form, {}).main, function(n) return n.p and n.p.role == "orchplus.form.result" end)
			return node, span_text(node)
		end
		if key == "setup-index" then return {}, if f.no_index then nil else runtime.json.encode(data) end
		if key == "migration-state" then return {}, if f.migration then runtime.json.encode(f.migration) else nil end
		if key == "spawn-dispatch-state" then return {}, if f.peer then runtime.json.encode(f.peer) else nil end
		if key == "setup-catalog-request" and f.catalog_request then return {}, runtime.json.encode(f.catalog_request) end
		if block == "spawn.dispatch" then return { id = "main" }, f.catalog_reply end
		return nil, nil
	end,
		forms = nil,
		decode = codec.strict_decode, decode_setup_response = protocol.decode_setup_response,
		copy = copy, same = same, epoch = "epoch", id = function() serial += 1; return "request-" .. serial end,
		host = function(_, pane) return f.hosts[f.pane_hosts[pane]] end, membership = function() return f.membership end,
		event = function(current, endpoint, event) current.session:event(endpoint, event); return true end,
		work_status = function() return "WORK is available.", true end,
		ack = function() f.catalog_acks = (f.catalog_acks or 0) + 1 end,
		migrate = function(_, source, origin, request, done)
			assert(source == 9)
			table.insert(f.migrations, { origin = copy(origin), request = copy(request), done = done })
		end,
		transport = function(_, source, origin)
			f.transport_calls = (f.transport_calls or 0) + 1
			f.transport_origin = copy(origin)
			assert(source == 9)
			return if f.transport_failure then nil else 10, f.transport_failure
		end,
		flow = function() return { policy = f.policy or data.installation_defaults.policy } end,
		origin = function() return { logical_session_id = "fixture-session" } end,
		save_policy = function(_, _, origin, previous, policy, done)
			f.policy_save = { origin = origin, previous = copy(previous), policy = copy(policy), done = done }
			if f.policy_refusal then done(cx, { ok = false, code = f.policy_refusal }) end
		end,
	}
	f.forms = load("form_window").new(api); api.forms = f.forms; f.ui = module.new(api)
	function f:change(id, value)
		for _, entry in self.form.spec.fields do if entry.id == id then self:reveal(entry.group); break end end
		form_def.event(self.form, { ev = "change", id = "main.field:" .. id, value = value }, {})
	end
	function f:select_check(id, selected)
		for _, entry in self.form.spec.fields do if entry.id == id then
			self:reveal(entry.group)
			for i, option in entry.options do if option.value == selected then
				form_def.event(self.form, { ev = "change", id = "main.field:" .. id .. ":option:" .. i, value = true }, {})
				return
			end end
		end end
		error("Missing checklist option: " .. id .. "/" .. selected)
	end
	function f:text(id, value)
		for _, entry in self.form.spec.fields do if entry.id == id then self:reveal(entry.group); break end end
		local old = self.form.values[id]; local units = 0
		for _, code in utf8.codes(old) do units += if code > 65535 then 2 else 1 end
		local caret = 0; for _, code in utf8.codes(value) do caret += if code > 65535 then 2 else 1 end
		form_def.event(self.form, { ev = "edit", id = "main.field:" .. id, ["from"] = 0, to = units, len = units, cursor = caret, text = value }, {})
	end
	function f:submit(action)
		for _, entry in self.form.spec.actions do if entry.id == action then self:reveal(entry.group); break end end
		local clicked = self:click("form-action=" .. action); self.forms.tick(self.cx); return clicked
	end
	function f:observe()
		self.data.installation_defaults = copy(self.registry.installation_defaults)
		self.data.setup = copy(self.registry.setup)
		self.data.authority_namespace = self.registry.authority_namespace; self.data.authority_revision = self.registry.revision
	end
	function f:commit()
		local request = runtime.json.decode(self.events[#self.events].value)
		request.source_nonce = nil; request.setup_origin = nil
		local next_registry, result = state.apply(self.registry, request)
		if next_registry then self.registry = next_registry end
		self:observe()
		self.data.setup_result = copy(result); self.data.setup_result.request_id = request.request_id
		return result
	end
	return f
end
local records = {
	{ id = "builder", provider = "Claude", account_label = "Fixture worker", revision = 1, enabled = true, eligible = true, unsupported = runtime.json.array(), capabilities = { "report-files-v1", "check-runner-v1" } },
	{ id = "release", provider = "Codex", account_label = "Fixture release", revision = 1, enabled = true, eligible = true, unsupported = runtime.json.array(), capabilities = { "report-files-v1", "release-manager-v1" } },
	{ id = "reviewer", provider = "Codex", account_label = "Fixture reviewer", revision = 1, enabled = true, eligible = true, unsupported = runtime.json.array(), capabilities = { "report-files-v1" } },
}
for _, row in records do row.placement = "split"; row.backend = "native-agent" end
local function body(f, rows, cursor)
	local request = assert(f.catalog_request)
	return { schema = 2, op = "catalog", request_id = request.request_id, action_id = request.action_id, setup_origin = copy(request.setup_origin),
		category = "current_result", status = "catalog", payload = { catalog_version = 2, revision = 1, config_revision = 1,
			namespace = "spawn-fixture", host_key = "fixture-host", records = copy(rows), next_cursor = cursor,
			setup = { schema = 1, state = "completed", config_revision = 1, readiness = { state = "not_run", config_revision = 1, summary = "" } } } }
end
local function answer_catalog(f, rows, cursor)
	f.catalog_reply = frame(body(f, rows or records, cursor))
	f.ui.tick(f.cx)
	f.forms.tick(f.cx)
end
local function latest(f)
	local event = assert(f.events[#f.events], "Settings did not submit")
	return runtime.json.decode(event.value)
end
local function open(f, command) f.ui.start(f.cx, 9, command or "defaults") end
local function open_cross_tab(f)
	f.forms.choose(f.cx, 9, nil, { tag = "gate", retain = true, items = { { label = "Continue" } } }, function() end)
	f.panes[20].tab = 3
	f.hide_source_on_form_focus = true
	open(f); answer_catalog(f)
end
do
	local f = fixture(state.new_registry()); open(f); answer_catalog(f)
	local canonical = dispatch.default_policy()
	check(f.form.values.concurrency_limit == tostring(canonical.concurrency_limit) and canonical.concurrency_limit == 4
		and f.form.values.quota_age_enabled == false and canonical.quota_max_age_ms == 0
		and f.form.values.auto_rollover == true and canonical.auto_rollover,
		"never-saved settings display canonical concurrency, quota-age and automatic-rollover defaults")
	check(canonical.rollover_threshold_pct == 0 and f.form.values.rollover_mode == "calculated" and f.form.values.rollover_threshold_pct == "",
		"internal formula sentinel is presented as calculated mode without a public zero percentage")
	check(f.form.values.track_checkout_roots and not f.form.values.glitch_integration
		and f.form.values.default_work_source == nil and f.form.values.glitch_project_discovery == nil
		and f.form.values.merge_actor == "worker", "fresh settings preserve approved neutral, tracked-checkout and worker-merge defaults")
	check(f.form.values.sweep_enabled and f.form.values.sweep_time == "03:00:00"
		and f.form.values.poll_duration == "05:00" and f.form.values.report_duration == "15:00"
		and f.form.values.stale_duration == "30:00" and not f.form.values.automatic_reports
		and f.form.values.loop_cap == "5" and f.form.values.review_rounds == "5" and f.form.values.claim_duration == "02:00:00",
		"all explicitly supplied cleanup, reporting and stalled-work defaults reach native fields")
	for _, kind in { "dispatch", "report", "review", "landing" } do
		check(f.form.values["approval_" .. kind] == true, "automatic approval supplied defaults are On")
	end
	check(f.form.values.merge_coordination, "merge coordination supplied default is On")
	for _, scope in { "initial_dispatch", "worker_rollover", "coordinator_rollover" } do
		check(not f.form.values[scope .. "_enabled"] and not f.form.values[scope .. "_provider"] and not f.form.values[scope .. "_account"],
			"alternative allowances and each provider/account override default Off")
	end
end
do
	local registry = state.new_registry()
	registry.installation_defaults.defined = true
	registry.installation_defaults.policy.concurrency_limit = 2
	registry.installation_defaults.policy.quota_max_age_ms = 7200000
	registry.installation_defaults.policy.auto_rollover = false
	local f = fixture(registry); open(f); answer_catalog(f)
	check(f.form.values.concurrency_limit == "2" and f.form.values.quota_age_enabled and f.form.values.quota_age_hours == "2"
		and not f.form.values.auto_rollover, "explicit saved user defaults are not overwritten by supplied canonical defaults")
end
do
	local f = fixture(); local unready = copy(records)
	for _, record in unready do record.enabled = false; record.eligible = false end
	open(f)
	local reply = body(f, unready); reply.payload.setup.state = "not_started"
	f.catalog_reply = frame(reply); f.ui.tick(f.cx); f.forms.tick(f.cx)
	check(f.form ~= nil, "incomplete SPAWN setup does not block editing saved agent preferences")
	for _, field in f.form.spec.fields do
		if field.kind == "select" or field.kind == "checklist" then
			if field.id == "preferred_worker_record" or field.id == "preferred_orchestrator_record" or field.id == "merge_actor"
				or field.id == "reviewer_records" or field.id:match("_records$") then
				for _, option in field.options do check(option.disabled ~= true, "saved catalog preferences stay selectable independently of launch readiness") end
			end
		end
	end
	f:change("preferred_worker_record", "builder"); f:change("preferred_orchestrator_record", "reviewer")
	f:change("merge_actor", "record:release"); f:select_check("reviewer_records", "reviewer")
	for _, scope in { "initial_dispatch", "worker_rollover", "coordinator_rollover" } do
		f:change(scope .. "_enabled", true); f:select_check(scope .. "_records", "builder")
	end
	assert(f:submit("defaults")); check(f:commit().ok, "saved preferences persist without claiming unready agents can launch")
	local p = f.registry.installation_defaults.policy
	check(p.preferred_worker_record == "builder" and p.preferred_orchestrator_record == "reviewer"
		and p.release_manager_record == "release" and p.reviewer_records[1] == "reviewer"
		and p.initial_dispatch_records[1] == "builder" and p.worker_rollover_records[1] == "builder" and p.coordinator_rollover_records[1] == "builder",
		"every preference selector/checklist saves actual agent identities")
	check(next(f.registry.sessions) == nil, "preference selection and saving start no agent or orchestration")
end
do
	local f = fixture(); open(f); answer_catalog(f)
	for _, scope in { "initial_dispatch", "worker_rollover", "coordinator_rollover" } do
		f:change(scope .. "_enabled", true)
		f:select_check(scope .. "_records", "reviewer"); f:select_check(scope .. "_records", "builder")
	end
	f:select_check("reviewer_records", "reviewer"); f:select_check("reviewer_records", "builder")
	assert(f:submit("defaults")); check(f:commit().ok, "unordered alternative selections save through canonical authority")
	local p = f.registry.installation_defaults.policy
	for _, key in { "initial_dispatch_records", "worker_rollover_records", "coordinator_rollover_records" } do
		check(same(p[key], { "builder", "reviewer" }), "each alternative set is canonicalized without losing choices")
	end
	check(same(p.reviewer_records, { "reviewer", "builder" }), "reviewer preference order survives saving")
end
do
	local f = fixture(); open(f); answer_catalog(f)
	f:text("concurrency_limit", "101"); f:text("poll_duration", "00:00")
	f.form.collapsed.agents = true; f.form.collapsed.advanced = true; f.form.collapsed.reports = true
	local before = #f.events; assert(f:submit("defaults"))
	check(#f.events == before and f.form.errors.concurrency_limit ~= nil and f.form.errors.poll_duration ~= nil,
		"canonical bounds identify each actual blocking field before any policy submission")
	check(not f.form.collapsed.agents and not f.form.collapsed.advanced and not f.form.collapsed.reports
		and f.form.values.concurrency_limit == "101" and f.form.values.poll_duration == "00:00",
		"validation expands all invalid ancestors without replacing entered values")
end
do
	local f = fixture(); open(f); answer_catalog(f)
	f:change("rollover_mode", "percentage"); f:text("rollover_threshold_pct", "0"); local before = #f.events
	assert(f:submit("defaults")); check(#f.events == before and f.form.errors.rollover_threshold_pct ~= nil,
		"percentage override cannot submit the internal formula sentinel")
	f:text("rollover_threshold_pct", "99"); assert(f:submit("defaults")); check(f:commit().ok, "upper numeric override boundary saves")
	check(f.registry.installation_defaults.policy.rollover_threshold_pct == 99, "explicit override remains an exact percentage")
	f.ui.tick(f.cx); open(f); answer_catalog(f)
	check(f.form.values.rollover_mode == "percentage" and f.form.values.rollover_threshold_pct == "99", "saved override is not silently rebased to calculated")
	f:change("rollover_mode", "calculated"); assert(f:submit("defaults")); check(f:commit().ok
		and f.registry.installation_defaults.policy.rollover_threshold_pct == 0, "calculated choice saves internal sentinel explicitly")
end
do
	local f = fixture(); open(f); answer_catalog(f)
	assert(f:submit("add_template"))
	f:text("template_1_id", "first"); f:text("template_1_title", "First")
	f:text("template_1_prompt", "No input substitution"); f:text("template_1_output", "result.txt")
	local before = #f.events; assert(f:submit("defaults"))
	check(#f.events == before and f.form.errors.template_1_prompt ~= nil and f.form.errors.template_1_title == nil,
		"template validation identifies the invalid prompt without blaming valid sibling fields")
	f:text("template_1_prompt", "Complete {input}"); assert(f:submit("defaults")); check(f:commit().ok,
		"correcting a template field saves the original entered template")
end
do
	local f = fixture(); open(f); answer_catalog(f)
	f:text("poll_duration", "invalid"); f:text("concurrency_limit", "unfinished")
	assert(f:submit("spawn"))
	check(f.new_blocks[#f.new_blocks].block == "spawn.spawner" and f.form.values.poll_duration == "invalid",
		"contextual SPAWN setup opens without validating or discarding unrelated draft inputs")
	assert(f:submit("refresh_agents")); answer_catalog(f)
	check(f.form.values.poll_duration == "invalid" and f.form.values.concurrency_limit == "unfinished",
		"refreshing SPAWN choices retains even temporarily invalid native draft input")
end
do
	local f = fixture(); open(f); answer_catalog(f)
	f:text("concurrency_limit", "unfinished"); assert(f:submit("refresh_agents"))
	assert(f:click("form-cancel")); f.forms.tick(f.cx)
	check(not f.forms.active(9), "Close discards the settings draft while a catalog refresh is pending")
	answer_catalog(f)
	check(not f.forms.active(9), "late catalog completion cannot reopen explicitly closed settings")
	open(f); answer_catalog(f)
	check(f.form.values.concurrency_limit == tostring(f.registry.installation_defaults.policy.concurrency_limit),
		"reopening after Close uses saved policy instead of navigation-retained raw draft input")
end
do
	local f = fixture(state.new_registry()); local policy = copy(f.registry.installation_defaults.policy)
	open_cross_tab(f)
	check(#f.new_blocks == 1 and f.cx.session:view(9) == nil and f.forms.active(9, "settings"),
		"defaults reuse the gate pane in another tab without requiring the source to stay mounted")
	local count = #f.events; assert(f:submit("defaults"))
	check(#f.events == count + 1 and latest(f).kind == "installation_defaults" and f.form.busy,
		"unchanged first cross-tab submission issues exactly one deliberate defaults write")
	check(f:commit().ok and f.registry.installation_defaults.defined and f.registry.installation_defaults.revision == 1
		and same(f.registry.installation_defaults.policy, policy), "explicit first save defines unchanged server defaults without altering policy")
	f.ui.tick(f.cx); f.forms.tick(f.cx); f.ui.tick(f.cx)
	check(not f.forms.active(9) and f.panes[20] == nil and f.form.closed and f.form.result == nil
		and #f.events == count + 1, "successful cross-tab save acknowledges and closes its form without repeating the write")
	check(next(f.registry.sessions) == nil and (f.registry.dispatch == nil or next(f.registry.dispatch.workers) == nil) and f.policy_save == nil,
		"defining defaults creates no orchestration, worker or instance-policy write")
	open(f); answer_catalog(f)
	check(f.form.spec.title == "Edit Default Settings" and f:submit("defaults"),
		"reopening explicitly saved defaults provides a usable Edit Default Settings form")
	check(f:commit().ok, "reopened default settings accepts another deliberate unchanged save")
	f.ui.tick(f.cx)
end
do
	local f = fixture(); open_cross_tab(f)
	f:change("quota_routing", true); f:text("quota_reserve_pct", "17")
	local defaults = copy(f.registry.installation_defaults); defaults.policy.concurrency_limit = 6
	f.registry = assert(state.apply(f.registry, { kind = "installation_defaults", request_id = "cross-tab-external",
		authority_namespace = f.registry.authority_namespace, expected_revision = f.registry.revision, expected_config_revision = defaults.revision,
		defaults = { policy = defaults.policy, builder_record = defaults.builder_record, coordinator_record = defaults.coordinator_record } }))
	f:observe(); assert(f:submit("defaults")); check(not f:commit().ok, "cross-tab save retains its captured configuration fence")
	local count = #f.events; f.ui.tick(f.cx); f.forms.tick(f.cx)
	check(f.forms.active(9, "settings") and not f.form.busy and f.form.result == nil and f.form.values.quota_reserve_pct == "17"
		and f.registry.installation_defaults.policy.concurrency_limit == 6 and #f.events == count,
		"cross-tab refusal acknowledges, retains entered values and never repeats or overwrites a conflicting save")
end
for _, boundary in { "window", "session", "host", "source_session", "form_session" } do
	local f = fixture(); open_cross_tab(f); local count = #f.events
	if boundary == "window" then f.window = "other-window"
	elseif boundary == "session" then f.session_id = 4
	elseif boundary == "host" then f.host_id = 7
	elseif boundary == "source_session" then f.panes[9].tab = 2
	else f.panes[20].tab = 2 end
	assert(f:submit("defaults")); f.forms.tick(f.cx)
	check(#f.events == count, "an unmounted source cannot issue a write across the captured " .. boundary .. " boundary")
	f.window = ""; f.session_id = 3; f.host_id = 2; f.panes[9].tab = 1; f.panes[20].tab = 3
	f.forms.tick(f.cx); f.forms.tick(f.cx)
	if #f.events == count then assert(f:submit("defaults")) end
	check(#f.events == count + 1 and latest(f).kind == "installation_defaults", "the restored " .. boundary .. " scope accepts a deliberate save without duplication")
	f.forms.tick(f.cx)
	check(#f.events == count + 1, "acknowledging the " .. boundary .. " refusal cannot duplicate the save")
end
do
	local f = fixture(); open_cross_tab(f); f:change("quota_routing", true); f:text("quota_reserve_pct", "17"); local count = #f.events
	f.data.source_nonce = "replacement"; assert(f:submit("defaults")); f.forms.tick(f.cx)
	check(#f.events == count and f.form.result == nil and not f.form.busy and f.form.values.quota_reserve_pct == "17",
		"reloaded hidden source refuses with an acknowledged retained draft and no write")
end
do
	local f = fixture(); open(f); answer_catalog(f)
	check(f.form ~= nil and #f.picks == 0 and #f.prompts == 0, "settings use an editable native pane")
	check(f.form.values.merge_actor == "worker", "genuinely fresh policy selects the existing-worker merge mode")
	local roots = 0; for _, group in f.form.spec.groups do if group.parent == nil then roots += 1; check(f.form.collapsed[group.id], "top-level settings disclosures start collapsed") end end
	check(roots == 6 and find_node(load("form_host").definition.view(f.form, {}).main, function(n) return n.k == "input" or n.k == "editor" or n.k == "select" or n.k == "switch" end) == nil,
		"initial native settings view has six calm disclosures rather than expanded controls")
	f:change("require_code_review", false); f:change("auto_rollover", false); f:submit("defaults")
	check(f.registry.installation_defaults.policy.auto_rollover == true, "draft does not mutate authority")
	check(f:commit().ok, "authoritative defaults reducer accepts native form")
	f.ui.tick(f.cx)
	check(not f.registry.installation_defaults.policy.auto_rollover and not f.registry.installation_defaults.policy.require_code_review, "real save persists effective policy")
	check(next(f.registry.sessions) == nil and (f.registry.dispatch == nil or next(f.registry.dispatch.workers) == nil), "saving defaults starts no work")
end
do
	local f = fixture(); open(f); answer_catalog(f)
	f:change("quota_routing", true); f:text("quota_reserve_pct", "17"); f:text("poll_duration", "05:90"); local count = #f.events
	f:submit("defaults")
	check(#f.events == count and f.form.errors.poll_duration ~= nil and f.form.values.quota_reserve_pct == "17", "validation retains other entered fields and sends no write")
	f:text("poll_duration", "05:00"); f:submit("defaults")
	check(f:commit().ok and f.registry.installation_defaults.policy.poll_ms == 300000 and f.registry.installation_defaults.policy.quota_reserve_pct == 17, "corrected duration reaches real save")
end
do
	local f = fixture(); open(f); answer_catalog(f)
	f:change("quota_routing", true); f:text("quota_reserve_pct", "17")
	local defaults = copy(f.registry.installation_defaults); defaults.policy.concurrency_limit = 6
	f.registry = assert(state.apply(f.registry, { kind = "installation_defaults", request_id = "external-defaults",
		authority_namespace = f.registry.authority_namespace, expected_revision = f.registry.revision, expected_config_revision = defaults.revision,
		defaults = { policy = defaults.policy, builder_record = defaults.builder_record, coordinator_record = defaults.coordinator_record } }))
	f:observe(); f:submit("defaults"); local request = latest(f)
	check(request.expected_revision == f.registry.revision and request.expected_config_revision == defaults.revision, "save uses live global revision but keeps captured configuration fence")
	check(not f:commit().ok and f.registry.installation_defaults.policy.concurrency_limit == 6, "real config conflict refuses rather than overwriting another defaults edit")
	f.ui.tick(f.cx); check(f.form.values.quota_reserve_pct == "17" and not f.form.busy, "real refusal retains editable entered values")
	local count = #f.events; f.ui.tick(f.cx); open(f)
	check(#f.events == count and f.form.values.quota_reserve_pct == "17", "background refresh and reopen do not discard or replay an unsaved draft")
	assert(f:submit("reload")); answer_catalog(f)
	check(f.form.values.concurrency_limit == "6" and f.form.values.quota_reserve_pct == "10", "explicit reload discards the draft and captures current saved settings")
	f:text("concurrency_limit", "7"); assert(f:submit("defaults")); check(f:commit().ok, "fresh baseline saves after deliberate conflict reload")
end
do
	local f = fixture(); open(f); answer_catalog(f)
	f.registry = assert(state.apply(f.registry, { kind = "register_session", request_id = "background-progress", orch_session_id = "other",
		name = "Other", authority_namespace = f.registry.authority_namespace, expected_revision = f.registry.revision }))
	f:observe(); f:text("concurrency_limit", "6"); assert(f:submit("defaults"))
	check(latest(f).expected_revision == f.registry.revision and f:commit().ok, "unrelated global progress does not permanently poison a defaults draft")
	f.ui.tick(f.cx); check(not f.forms.active(9) and f.panes[20] == nil, "successful defaults save drops the completed draft and closes its pane")
	open(f); answer_catalog(f); check(f.form.values.concurrency_limit == "6", "reopen after success reads the actual saved baseline")
end
do
	local registry = state.new_registry()
	registry = assert(state.apply(registry, { kind = "register_session", request_id = "checkout-source", orch_session_id = "checkout-source",
		name = "Existing work", authority_namespace = registry.authority_namespace, expected_revision = registry.revision }))
	local live = dispatch.policy(registry, "checkout-source")
	live.paused = true; live.excluded_workers = { "old-worker" }; live.checkout_roots = { "/old/repo", "/old/other-worktree" }
	live.board_path = "/old/board"; live.inbox_folder = "/old/inbox"
	dispatch.seed_policy(registry, "checkout-source", live)
	local f = fixture(registry); f.policy = copy(live); local sessions = copy(registry.sessions)
	open(f, "session"); answer_catalog(f); f:change("auto_rollover", true); f:submit("defaults")
	local defaults = latest(f).defaults
	check(not defaults.policy.paused and #defaults.policy.excluded_workers == 0 and #defaults.policy.checkout_roots == 0
		and defaults.policy.board_path == "" and defaults.policy.inbox_folder == "", "defaults omit live controls and absolute host/project locations")
	check(defaults.projects == nil and defaults.owner_id == nil and defaults.repository == nil and f:commit().ok, "real defaults path carries no instance authority")
	check(#f.registry.installation_defaults.policy.checkout_roots == 0
		and same(dispatch.policy(f.registry, "checkout-source"), live) and same(f.registry.sessions, sessions)
		and next(f.registry.dispatch.workers) == nil,
		"saving defaults from existing work stores no live checkout folders and leaves that work's complete policy and sessions untouched")
	local newer, result = state.apply(f.registry, { kind = "register_session", request_id = "checkout-new", orch_session_id = "checkout-new",
		name = "New work", authority_namespace = f.registry.authority_namespace, expected_revision = f.registry.revision })
	check(newer and result.ok and dispatch.policy(newer, "checkout-new").auto_rollover
		and #dispatch.policy(newer, "checkout-new").checkout_roots == 0
		and same(dispatch.policy(newer, "checkout-source"), live) and same(newer.sessions["checkout-source"], sessions["checkout-source"]),
		"new work reuses the saved settings without inheriting either live checkout folder or changing the existing work")
end
do
	local f = fixture(); f.policy = copy(f.data.installation_defaults.policy); f.policy.paused = true
	open(f, "session"); answer_catalog(f)
	f:change("initial_dispatch_enabled", true); f:change("initial_dispatch_provider", true)
	f:change("worker_rollover_enabled", true); f:change("worker_rollover_account", true)
	f:change("coordinator_rollover_enabled", true); f:change("coordinator_rollover_provider", true)
	f:submit("instance"); local saved = f.policy_save
	check(saved.policy.initial_dispatch_provider and saved.policy.worker_rollover_account and saved.policy.coordinator_rollover_provider
		and not saved.policy.initial_dispatch_account and not saved.policy.worker_rollover_provider, "three allowance scopes remain independent")
	check(saved.policy.paused == nil and saved.previous.paused and f.data.installation_defaults.policy.initial_dispatch_enabled == false, "instance save excludes live pause and does not save installation defaults")
	saved.done(f.cx, { ok = false, code = "stale_policy" })
	check(f.form.values.worker_rollover_account and not f.form.busy, "instance refusal retains editable draft")
end
do
	local f = fixture(); open(f); answer_catalog(f)
	f:submit("add_template")
	f:text("template_1_id", "research"); f:text("template_1_title", "Research"); f:text("template_1_prompt", "{input}: {audience}")
	f:text("template_1_output", "notes/{audience}.md"); f:text("template_1_new_custom", "audience"); f:submit("custom_1")
	f:text("template_1_custom_value_1", "team"); f:submit("defaults")
	check(f:commit().ok, "real authority accepts editable custom-field template")
	local t = f.registry.installation_defaults.policy.templates[1]
	check(t.custom_fields.audience == "team" and t.class == nil and t.prompt == "{input}: {audience}", "optional metadata and custom-field values persist")
end
do
	local f = fixture(); open(f); answer_catalog(f, { records[1] }, { revision = 1, index = 2 })
	check(f.form == nil and f.catalog_request.cursor.index == 2, "catalog pages automatically before exposing a complete choices snapshot")
	answer_catalog(f, { records[2], records[3] })
	check(f.form and f.catalog_request == nil, "complete catalog opens one native form without a transport pane")
	local n = #f.new_blocks; open(f); check(#f.new_blocks == n, "settings reopen reuses the existing native pane")
end
for _, ready_state in { "not_started", "completed", "adopted_existing" } do
	local f = fixture(); local result
	f.ui.ready(f.cx, 9, function(_, ok, problem) result = { ok, problem } end)
	local reply = body(f, records); reply.payload.setup.state = ready_state
	f.catalog_reply = frame(reply); f.ui.tick(f.cx)
	check(result ~= nil and result[1] == (ready_state ~= "not_started"), "creation readiness uses actual catalog setup state")
	check(next(f.registry.sessions) == nil, "readiness observation initializes no orchestration")
end
for _, malformed in {
	function(b) return runtime.json.encode(b) end,
	function(b) return frame(b, function(e) e.body_bytes += 1 end) end,
	function(b) b.setup_origin.window_epoch = "foreign"; return frame(b) end,
} do
	local f = fixture(); local result
	f.ui.ready(f.cx, 9, function(_, ok) result = ok end)
	f.catalog_reply = malformed(body(f, records)); f.ui.tick(f.cx)
	check(result == nil and f.form == nil, "malformed or foreign setup evidence cannot admit creation")
end
do
	local f = fixture(); open(f, "dismiss"); clock += 30001; f.ui.tick(f.cx); f.ui.tick(f.cx)
	check(#f.events == 1, "unknown write outcome is never retried")
end
do
	local registry = state.new_registry()
	registry = assert(state.apply(registry, { kind = "register_session", request_id = "live-session", orch_session_id = "live",
		name = "Live", authority_namespace = registry.authority_namespace, expected_revision = registry.revision }))
	local live = dispatch.policy(registry, "live")
	live.paused = true; live.excluded_workers = { "existing-worker" }; live.checkout_roots = { "/project/worktree" }
	live.board_path = "/desktop/custom.md"; live.inbox_folder = "/project/inbox"
	live.templates = { { id = "keep", title = "Keep", prompt = "{input}", output = "keep.md", next = "", custom_fields = {} } }
	dispatch.seed_policy(registry, "live", live)
	local f = fixture(registry); f.policy = copy(live); open(f, "defaults"); answer_catalog(f)
	check(not f:submit("instance") and f.policy_save == nil and same(dispatch.policy(f.registry, "live"), live),
		"defaults-only editor cannot write over actual live exclusions, checkout roots, board or templates")
	f:change("auto_rollover", true); assert(f:submit("defaults")); check(f:commit().ok, "defaults editor saves through its actual defaults authority")
	check(same(dispatch.policy(f.registry, "live"), live), "saving reusable defaults leaves the actual existing instance policy unchanged")
	local newer, result = state.apply(f.registry, { kind = "register_session", request_id = "new-live", orch_session_id = "new-live",
		name = "New", authority_namespace = f.registry.authority_namespace, expected_revision = f.registry.revision })
	check(newer and result.ok and dispatch.policy(newer, "new-live").auto_rollover and #dispatch.policy(newer, "new-live").checkout_roots == 0,
		"new orchestration reuses defaults without inheriting live project checkout locations")
end
do
	local f = fixture(); f.policy = copy(f.data.installation_defaults.policy); open(f, "session"); answer_catalog(f)
	f:change("quota_routing", true); f:text("quota_reserve_pct", "17"); assert(f:submit("instance"))
	local callback = f.policy_save.done; clock += 30001; f.ui.tick(f.cx)
	check(not f.form.busy and f.forms.active(9) and f.form.values.quota_reserve_pct == "17", "instance-save deadline unlocks and retains entered values")
	callback(f.cx, { ok = true }); check(f.forms.active(9) and not f.form.closed, "late success cannot upgrade an expired instance save or close the retained draft")
end
do
	local f = fixture(); f.policy = copy(f.data.installation_defaults.policy); f.policy_refusal = "stale_policy"
	open(f, "session"); answer_catalog(f); f:text("concurrency_limit", "6"); assert(f:submit("instance"))
	check(not f.form.busy and f.forms.active(9) and f.form.values.concurrency_limit == "6", "immediate instance refusal unlocks editable draft")
end
do
	local f = fixture(); local p = copy(f.registry.installation_defaults.policy)
	p.merge_actor_mode = "selected_record"; p.release_manager_record = ""
	f.registry.installation_defaults.policy = copy(p); f.data.installation_defaults.policy = copy(p)
	open(f); answer_catalog(f)
	check(f.form.values.merge_actor == "record:", "saved selected-empty release hold has an unambiguous control value")
	f:text("concurrency_limit", "6"); assert(f:submit("defaults")); check(f:commit().ok, "unrelated defaults edit saves a selected-empty release hold")
	check(f.registry.installation_defaults.policy.merge_actor_mode == "selected_record" and f.registry.installation_defaults.policy.release_manager_record == "",
		"actual defaults save does not silently authorize same-worker merge from a legacy selected-empty hold")
	f.ui.tick(f.cx); open(f); answer_catalog(f); f:change("merge_actor", "worker"); assert(f:submit("defaults")); check(f:commit().ok, "explicit same-worker selection saves")
	check(f.registry.installation_defaults.policy.merge_actor_mode == "worker", "only explicit actor selection changes the saved merge mode")
end
do
	local f = fixture(); f.policy = copy(f.data.installation_defaults.policy)
	f.policy.merge_actor_mode = "selected_record"; f.policy.release_manager_record = ""
	open(f, "session"); answer_catalog(f); f:text("concurrency_limit", "6"); assert(f:submit("instance"))
	check(f.policy_save.policy.merge_actor_mode == "selected_record" and f.policy_save.policy.release_manager_record == "",
		"instance-scope form conversion also preserves the selected-empty permission hold")
end
do
	local f = fixture(); local p = copy(f.registry.installation_defaults.policy); p.templates = {}
	for i = 1, 3 do table.insert(p.templates, { id = "large-" .. i, title = "Large " .. i, prompt = string.rep("x", 3500) .. "{input}", output = "output-" .. i .. ".md", next = "", custom_fields = {} }) end
	check(dispatch.valid_policy(p), "large form fixture remains within the real canonical policy schema")
	f.registry.installation_defaults.policy = copy(p); f.data.installation_defaults.policy = copy(p)
	open(f); answer_catalog(f); f:text("concurrency_limit", "6"); assert(f:submit("defaults"))
	check(#f.events[#f.events].value > 8192 and f:commit().ok and #f.registry.installation_defaults.policy.templates[3].prompt > 3500,
		"actual rendered form submits and authoritative defaults writer persists a valid policy above eight KiB")
end
do
	local f = fixture(); open(f); answer_catalog(f); f:change("preferred_worker_record", "builder"); assert(f:submit("defaults"))
	check(f:commit().ok and f.registry.installation_defaults.builder_record == "builder"
		and f.registry.installation_defaults.policy.preferred_worker_record == "builder",
		"human-facing catalog selection preserves the opaque agent identity through the actual defaults writer")
end
for _, scope in { "defaults", "session" } do
	local f = fixture(); local p = copy(f.registry.installation_defaults.policy); p.templates = {}
	for i = 1, 12 do table.insert(p.templates, { id = "budget-" .. i, title = "Budget " .. i, prompt = string.rep("x", 3000) .. "{input}", output = "budget-" .. i .. ".md", next = "", custom_fields = {} }) end
	check(dispatch.valid_policy(p), "budget test begins with an actually valid saved policy")
	f.registry.installation_defaults.policy = copy(p); f.data.installation_defaults.policy = copy(p); f.policy = copy(p)
	open(f, scope); answer_catalog(f)
	for i = 1, 12 do f:text("template_" .. i .. "_prompt", string.rep("x", 4089) .. "{input}") end
	local before = #f.events; assert(f:submit(if scope == "session" then "instance" else "defaults"))
	check(#f.events == before and f.policy_save == nil and not f.form.busy and f.form.errors.template_1_prompt ~= nil,
		"over-budget settings produce actual field errors before either scope issues a write")
	check(#f.form.values.template_12_prompt == 4096 and #f.registry.installation_defaults.policy.templates[12].prompt == 3007,
		"over-budget refusal retains all entered text and leaves authoritative defaults unchanged")
end
for _, scope in { "defaults", "session" } do
	local f = fixture(); f.policy = copy(f.registry.installation_defaults.policy)
	open(f, scope); answer_catalog(f)
	for _, field in f.form.spec.fields do
		check(field.id:match("^guidance_") == nil, "retired global role instructions have no editable fields")
	end
	for _, group in f.form.spec.groups do check(group.id ~= "guidance", "retired global role instructions have no form group") end
	f:text("concurrency_limit", "6"); assert(f:submit(if scope == "session" then "instance" else "defaults"))
	local saved = if scope == "session" then f.policy_save.policy else latest(f).defaults.policy
	check(saved.role_guidance == nil, "neither settings scope serializes retired global role overrides")
	for _, retired in { "glitch_project_discovery", "default_work_source" } do
		for _, field in f.form.spec.fields do check(field.id ~= retired, "retired setting has no control: " .. retired) end
		check(saved[retired] == nil and f.form.values[retired] == nil, "neither settings scope serializes retired setting " .. retired)
	end
	if scope == "defaults" then check(f:commit().ok, "defaults save remains valid without role overrides") end
end
local function migration_fixture(orch_phase, spawn_phase)
	local f = fixture()
	local selection = { logical_session_ids = runtime.json.array(), mailbox_handles = runtime.json.array() }
	local managed = assert(codec.dispatch_managed_digest(runtime.json.encode({
		schema = 1, sessions = runtime.json.array(), workers = runtime.json.array() })))
	local function proof(namespace, revision, legacy, orch)
		return { candidate_namespace = namespace, source_namespace = if legacy and orch then nil else namespace,
			source_revision = revision, source_schema = if orch then (if legacy then 3 else 5) else (if legacy then 1 else 2),
			source_sha256 = codec.sha256(namespace .. ":" .. revision), protocol = if legacy then 1 else 2,
			phase = if legacy then "prepared" else "stable", state = "ready", managed_sha256 = managed, pending_immutable = 0, blockers = 0 }
	end
	f.migration = { protocol = 2, phase = orch_phase, source_nonce = "view", host_pane_id = "host-pane",
		authority_namespace = "migration-candidate", authority_revision = 5,
		qualification = { proof = proof("migration-candidate", 5, orch_phase == "legacy", true), selection = copy(selection) } }
	f.migration.source_sha256 = f.migration.qualification.proof.source_sha256
	f.peer = { protocol = if spawn_phase == "legacy" then 1 else 2, phase = if spawn_phase == "legacy" then "prepared" else spawn_phase,
		spawn_namespace = "spawn-fixture", authority_revision = 8,
		authority_namespace = if spawn_phase == "legacy" or spawn_phase == "unpaired" then nil else "migration-candidate",
		qualification = { proof = proof("spawn-fixture", 8, spawn_phase == "legacy", false), selection = copy(selection) } }
	if spawn_phase == "unpaired" then f.peer.phase = "stable" end
	local current = { schema = 1, kind = "current", protocol = 2, authority_namespace = "migration-candidate", spawn_namespace = "spawn-fixture" }
	local function pair()
		return { schema = 1, kind = "migration", orch = copy(f.migration.qualification.proof), spawn = copy(f.peer.qualification.proof) }
	end
	if orch_phase == "prepared" then f.migration.compatibility = pair()
	elseif orch_phase == "stable" then f.migration.compatibility = copy(current) end
	if spawn_phase == "prepared" then f.peer.compatibility = pair()
	elseif spawn_phase == "stable" then f.peer.compatibility = copy(current) end
	function f:ack_spawn(problem, change, code)
		local call = self.migrations[#self.migrations]
		assert(call and not call.answered, "a new automatic SPAWN phase must be pending")
		call.answered = true
		local operation = call.request.operation
		if operation ~= "source" and operation ~= "bootstrap" then
			check(same(call.request.expected, self.peer.qualification.proof) and same(call.request.peer, self.migration),
				"SPAWN phase captures the exact local proof and full current native ORCH projection")
		end
		if not problem and (operation == "prepare" or operation == "finish") then
			self.peer.authority_revision += 1; self.peer.protocol = 2
			self.peer.authority_namespace = "migration-candidate"
			self.peer.phase = if operation == "prepare" then "prepared" else "stable"
			self.peer.qualification.proof = proof("spawn-fixture", self.peer.authority_revision, false, false)
			self.peer.compatibility = if operation == "prepare" then pair() else copy(current)
		end
		local source = copy(self.peer)
		if change then change(source) end
		self.relay = { relay_endpoint = "setup-endpoint", lane_id = "lane-id", peer_boot = "spawn-boot",
			receipt = { id = "source-" .. #self.migrations, incarnation = "spawn-incarnation" } }
		call.done(self.cx, source, problem, copy(self.relay), code)
		self.ui.tick(self.cx)
		return call
	end
	function f:ack_orch(problem)
		local request = latest(self)
		assert(self.events[#self.events].act == "migration-command")
		check(same(request.relay_proof, self.relay) and same(request.peer, self.peer.qualification),
			"every ORCH phase carries its exact latest SPAWN source receipt and complete qualification")
		if not problem and request.operation ~= "inspect" then
			self.migration.authority_revision += 1
			self.migration.phase = if request.operation == "prepare" and self.migration.phase == "legacy" then "prepared" else "stable"
			self.migration.qualification.proof = proof("migration-candidate", self.migration.authority_revision, false, true)
			self.migration.source_sha256 = self.migration.qualification.proof.source_sha256
			self.migration.compatibility = if self.migration.phase == "prepared" then pair() else copy(current)
		end
		self.migration.result = { request_id = request.intent.request_id, ok = not problem, message = problem }
		self.ui.tick(self.cx)
		return request
	end
	function f:inspect_round()
		check(self.migrations[#self.migrations].request.operation == "source", "each round starts with genuine SPAWN source capture")
		self:ack_spawn()
		check(latest(self).operation == "inspect", "fresh SPAWN source is inspected by the actual ORCH owner")
		self:ack_orch()
		check(self.migrations[#self.migrations].request.operation == "inspect", "SPAWN independently inspects the fresh ORCH qualification")
		self:ack_spawn()
	end
	return f
end
local function create_connection(f)
	f.creation = { request_id = "create-request", orch_session_id = "created-session", owner_id = "created-owner",
		generation = 1, authority_namespace = "migration-candidate", source_nonce = "view" }
	f.completions = {}
	f.ui.start(f.cx, 9, "migration_update", nil, { creation = f.creation, done = function(_, ok, message)
		table.insert(f.completions, { ok = ok, message = message })
	end })
end
do
	local f = migration_fixture("stable", "unpaired"); f.migration.compatibility = nil
	create_connection(f)
	check(f.migrations[1].request.operation == "source" and #f.events == 0,
		"actual Create first observes the managed source; it never initializes through a read or sends owner_status")
	f:ack_spawn("Managed source has never been initialized", nil, "source_absent")
	local bootstrap = f.migrations[#f.migrations]
	check(bootstrap.request.operation == "bootstrap" and same(bootstrap.request.creation, f.creation)
		and bootstrap.request.expected == nil and bootstrap.request.peer == nil and #f.completions == 0,
		"only proven genuine absence carries the exact Create result to the separate native bootstrap")
	f:ack_spawn()
	f:inspect_round(); f:ack_spawn(); f:inspect_round(); f:ack_orch(); f:inspect_round(); f:ack_spawn(); f:inspect_round()
	check(#f.completions == 1 and f.completions[1].ok and not f.ui.active(9),
		"bootstrap is not connection success: Create continues only after both actual owners complete qualification")
	local count = #f.migrations
	bootstrap.done(f.cx, copy(f.peer), nil, copy(f.relay)); f.ui.tick(f.cx)
	check(#f.migrations == count and #f.completions == 1, "late bootstrap callback cannot restart the completed Create")
end
do
	local f = migration_fixture("stable", "stable")
	create_connection(f); f:inspect_round()
	check(#f.migrations == 2 and #f.completions == 1 and f.completions[1].ok,
		"an existing compatible store uses the read/qualification route and never bootstrap")
end
for _, code in { "source_unavailable", "untyped" } do
	local f = migration_fixture("stable", "unpaired"); create_connection(f)
	f:ack_spawn("Managed source cannot be trusted", nil, if code == "untyped" then nil else code)
	check(#f.migrations == 1 and #f.completions == 1 and not f.completions[1].ok and not f.ui.active(9),
		"lost, corrupt, marked or untyped absence never authorizes first-use initialization")
end
for _, failure in { "bootstrap_uncertain", "bootstrap_refused", "source_absent_again" } do
	local f = migration_fixture("stable", "unpaired"); create_connection(f)
	f:ack_spawn("Never initialized", nil, "source_absent")
	if failure == "source_absent_again" then f:ack_spawn(); f:ack_spawn("Still absent", nil, "source_absent")
	else f:ack_spawn("Initialization did not have a confirmed outcome", nil, failure) end
	local count = #f.migrations; f.ui.tick(f.cx); f.ui.tick(f.cx)
	check(#f.migrations == count and #f.completions == 1 and not f.completions[1].ok,
		"a refused, uncertain or vanished bootstrap is retained, never automatically initialized again")
end
do
	local f = migration_fixture("stable", "unpaired"); open(f, "migration_update")
	f:ack_spawn("Never initialized", nil, "source_absent")
	check(#f.migrations == 1 and not f.ui.active(9), "ordinary Update without a real Create witness cannot bootstrap")
end
do
	local f = migration_fixture("legacy", "legacy")
	open(f, "migration_update")
	check(#f.events == 0 and #f.picks == 0 and #f.new_blocks == 0, "one Update begins owner source capture, not catalog or another pane")
	f:inspect_round()
	check(f.migrations[#f.migrations].request.operation == "prepare", "SPAWN prepares first against both exact legacy sources")
	f:ack_spawn(); f:inspect_round()
	check(latest(f).operation == "prepare" and f.peer.phase == "prepared", "ORCH prepares only after acknowledged SPAWN preparation")
	f:ack_orch(); f:inspect_round()
	check(f.migrations[#f.migrations].request.operation == "finish" and f.migration.phase == "prepared", "SPAWN finishes only after both prepared sources were inspected")
	f:ack_spawn(); f:inspect_round()
	check(latest(f).operation == "finish" and f.peer.phase == "stable", "ORCH finishes against the freshly observed stable SPAWN candidate")
	f:ack_orch(); f:inspect_round()
	local count = #f.events + #f.migrations; f.ui.tick(f.cx)
	check(not f.ui.active(9) and #f.events + #f.migrations == count and #f.toasts == 1
		and f.toasts[1][1] == "Orchestration updated" and #f.picks == 0, "both-owner single-button update completes exactly once without manual phase controls")
end
do
	local f = migration_fixture("stable", "unpaired"); f.migration.compatibility = nil
	open(f, "migration_update"); f:inspect_round(); f:ack_spawn(); f:inspect_round()
	check(latest(f).operation == "prepare", "current unpaired ORCH is qualified only after SPAWN establishes the pair")
	f:ack_orch(); f:inspect_round(); f:ack_spawn(); f:inspect_round()
	check(not f.ui.active(9) and f.toasts[1][1] == "Orchestration updated", "initial current pairing finishes SPAWN without inventing an ORCH prepared obligation")
end
do
	local f = migration_fixture("stable", "stable")
	open(f, "migration_update"); f:inspect_round()
	check(#f.events == 1 and #f.migrations == 2 and not f.ui.active(9), "already stable pair is freshly inspected without forbidden repeated SPAWN preparation")
end
do
	local f = migration_fixture("prepared", "prepared")
	open(f, "migration_update"); f:inspect_round()
	check(f.migrations[#f.migrations].request.operation == "finish", "reconnect resumes actual prepared obligations without replaying preparation")
end
for _, corrupt in {
	function(v) v.authority_revision += 1 end,
	function(v) v.qualification.proof.extra = true end,
	function(v) v.qualification.selection.mailbox_handles = {} end,
	function(v) v.spawn_namespace = "replacement" end,
	function(v) v.compatibility = { kind = "current" } end,
} do
	local f = migration_fixture("legacy", "legacy")
	open(f, "migration_update"); f:ack_spawn(nil, corrupt)
	check(#f.events == 0 and #f.migrations == 1 and not f.ui.active(9), "malformed or mismatched source cannot start any ORCH phase")
end
for _, change in {
	function(f) f.peer.qualification.proof.blockers = 1; f.peer.qualification.proof.state = "blocked" end,
	function(f) f.peer.qualification.proof.managed_sha256 = string.rep("a", 64) end,
	function(f) f.peer.authority_namespace = "other-authority" end,
} do
	local f = migration_fixture("stable", "stable"); change(f)
	open(f, "migration_update"); f:inspect_round()
	check(#f.events == 1 and #f.migrations == 2 and f.toasts[1][1] ~= "Orchestration updated",
		"uncertain effects, unequal identities or a different retained pair never become an update success")
end
do
	local f = migration_fixture("legacy", "legacy"); open(f, "migration_update"); f:inspect_round()
	local call = f:ack_spawn("Commit outcome uncertain")
	local count = #f.events + #f.migrations
	call.done(f.cx, copy(f.peer), nil, copy(f.relay)); f.ui.tick(f.cx)
	check(not f.ui.active(9) and #f.events + #f.migrations == count and f.toasts[1][1] ~= "Orchestration updated",
		"uncertain SPAWN mutation stops the chain and a late positive duplicate cannot upgrade it")
end
do
	local f = migration_fixture("legacy", "legacy"); open(f, "migration_update")
	f.hidden[9] = true; f:ack_spawn()
	check(#f.events == 0, "hidden source acknowledgement cannot issue a new owner mutation")
	clock += 30001; f.ui.tick(f.cx); f.hidden[9] = nil; f.ui.tick(f.cx)
	check(#f.events == 1 and latest(f).operation == "inspect", "captured positive source acknowledgement survives a hidden view without replay")
end
for _, variant in { "timeout", "revision", "nonce", "session" } do
	local f = migration_fixture("legacy", "legacy"); open(f, "migration_update")
	if variant == "timeout" then clock += 30001; f.ui.tick(f.cx)
	elseif variant == "revision" then f.migration.authority_revision += 1
	elseif variant == "nonce" then f.migration.source_nonce = "replacement"
	else f.panes[9].tab = 2 end
	f:ack_spawn()
	check(#f.events == 0 and #f.migrations == 1 and not f.ui.active(9),
		variant .. ": delayed source callback cannot rebase or resume the original update")
end
for _, corrupt in {
	function(v) v.extra = true end,
	function(v) v.peer_boot = "" end,
	function(v) v.receipt = nil end,
	function(v) v.receipt.extra = true end,
	function(v) v.receipt.id = string.rep("x", 81) end,
	function(v) v.receipt.incarnation = "../other" end,
} do
	local f = migration_fixture("legacy", "legacy"); open(f, "migration_update")
	local relay = { relay_endpoint = "endpoint", lane_id = "lane", peer_boot = "boot", receipt = { id = "message", incarnation = "incarnation" } }
	corrupt(relay)
	f.migrations[1].done(f.cx, copy(f.peer), nil, relay); f.ui.tick(f.cx)
	check(#f.events == 0 and not f.ui.active(9), "incomplete, open or malformed native source receipt cannot authorize ORCH inspection")
end
do
	local f = migration_fixture("legacy", "legacy"); open(f, "migration_update")
	f:ack_spawn(); f:ack_orch("Source receipt no longer current")
	check(#f.migrations == 1 and not f.ui.active(9), "ORCH refusal cannot begin SPAWN inspection or mutation")
end
do
	local f = migration_fixture("legacy", "legacy"); open(f, "migration_update")
	local call = f:ack_spawn()
	call.done(f.cx, copy(f.peer), nil, copy(f.relay)); f.ui.tick(f.cx)
	check(#f.events == 1 and #f.migrations == 1, "duplicate source callback cannot repeat the ORCH owner event")
end
do
	local f = migration_fixture("legacy", "legacy")
	f.ui.start(f.cx, 9, "migration_update", { authority_namespace = f.migration.authority_namespace,
		expected_revision = f.migration.authority_revision - 1, source_sha256 = f.migration.source_sha256 })
	check(#f.migrations == 0 and #f.events == 0, "stale captured Update intent is not rebased onto a newer authority")
end
do
	local f = migration_fixture("legacy", "legacy"); open(f, "migration_update")
	f:ack_spawn()
	f.migration.source_sha256 = string.rep("b", 64); f.migration.qualification.proof.source_sha256 = f.migration.source_sha256
	f:ack_orch()
	check(#f.migrations == 1 and not f.ui.active(9), "same-revision replacement source cannot be adopted through an ORCH inspection acknowledgement")
end
do
	local f = migration_fixture("legacy", "legacy"); open(f, "migration_update")
	f:ack_spawn(); f:ack_orch()
	f:ack_spawn(nil, function(v)
		v.authority_revision += 1; v.qualification.proof.source_revision = v.authority_revision
	end)
	check(#f.migrations == 2 and not f.ui.active(9), "SPAWN inspect acknowledgement cannot substitute a newer source for its captured proof")
end
do
	local f = migration_fixture("legacy", "legacy"); open(f, "migration_update"); f:inspect_round()
	f:ack_spawn(nil, function(v)
		v.authority_revision += 1; v.qualification.proof.source_revision = v.authority_revision
	end)
	check(#f.migrations == 3 and not f.ui.active(9), "a SPAWN mutation acknowledgement cannot advance after an unrelated additional owner revision")
end
do
	local f = migration_fixture("legacy", "legacy"); open(f, "migration_update"); f:inspect_round()
	f:ack_spawn(); f:inspect_round()
	-- A positive correlated result is not permission to absorb another committed change.
	f.migration.authority_revision += 1
	f:ack_orch()
	check(not f.ui.active(9) and f.migrations[#f.migrations].request.operation == "inspect",
		"ORCH preparation acknowledgement cannot rebase onto an extra committed revision")
end
do
	local f = migration_fixture("legacy", "legacy")
	open(f, "migration_prepare")
	check(#f.events == 0 and #f.migrations == 0, "obsolete manual phase entry cannot bypass the single Update coordinator")
end
do
	local registry = state.new_registry()
	registry = assert(state.apply(registry, { kind = "register_session", request_id = "old-session", orch_session_id = "old",
		name = "Existing orchestration", authority_namespace = registry.authority_namespace, expected_revision = registry.revision }))
	local old = dispatch.policy(registry, "old"); old.auto_rollover = false; dispatch.seed_policy(registry, "old", old)
	local f = fixture(registry); open(f); answer_catalog(f); f:change("auto_rollover", true); f:submit("defaults")
	check(f:commit().ok, "native defaults save accepted alongside an existing orchestration")
	local created, result = state.apply(f.registry, { kind = "register_session", request_id = "new-session", orch_session_id = "new",
		name = "New orchestration", authority_namespace = f.registry.authority_namespace, expected_revision = f.registry.revision })
	check(created and result.ok and dispatch.policy(created, "new").auto_rollover and not dispatch.policy(created, "old").auto_rollover,
		"actual new-orchestration API reuses defaults without changing existing overrides")
	check(created.sessions.new.controller == nil and next(created.dispatch.workers) == nil, "default reuse grants no owner and starts no worker")
end
-- Exercise the real window adapter across native events/surfaces, independently of the
-- coordinator's reducer fixtures above. Only native I/O is recorded; adapter logic is not copied.
local function native_migration_fixture()
	local f = migration_fixture("stable", "stable")
	f.migration.host_pane_id = "9"
	clock = 0
	local api, cache = nil, {}
	local fake = table.clone(runtime)
	fake.now = function() return clock end
	fake.command, fake.on = function() end, function() end
	fake.files = { button = function() end }
	fake.chrome = { status = function() end }
	fake.route = { link = function() end }
	fake.timer = function() return { cancel = function() end } end
	local function native_load(name, base)
		name = (base or "") .. name:gsub("^%./", "")
		if cache[name] then return cache[name] end
		local chunk = assert(loadstring(runtime.fs.read(root .. "/" .. name .. ".luau"), "native-setup/" .. name))
		setfenv(chunk, setmetatable({ tern = fake, require = function(path) return native_load(path, name:match("^(.*/)")) end }, { __index = environment }))
		local value = chunk()
		if name == "setup_window" then
			local create = value.new
			value = { new = function(input) api = input; return create(input) end }
		end
		cache[name] = value; return value
	end
	native_load("window")
	assert(api and api.migrate and api.migration_tick)
	f.native_api, f.native_stages, f.native_results = api, {}, {}
	f.native_origin = { host_pane_id = "9", window_key = "", window_epoch = api.epoch, native_session_id = "3", window_host_id = "2" }
	f.native_metadata = { schema = 1, peer = "spawn", host_pane_id = "9", source_nonce = "view",
		relay_endpoint = "native-migration-endpoint", relay_boot = "orch-native-boot", lanes = {}, releases = {} }
	f.hosts[2].panes = { 9 }
	function f.cx.hosts:list() return { f.hosts[2] } end
	function f.cx.session:sessions() return { { id = 3, tabs = { 1 } } } end
	local original_event = f.cx.session.event
	function f.cx.session:event(pane, event)
		if event.act ~= "spawn_relay" then original_event(self, pane, event); return end
		assert(pane == 9, "only the actual ORCH native panel carries migration traffic")
		local outer = runtime.json.decode(event.value)
		assert(outer.source_nonce == "view" and outer.relay_endpoint == f.native_metadata.relay_endpoint
			and outer.relay_boot == f.native_metadata.relay_boot)
		if outer.act == "bind" then
			f.native_lane = { lane_id = outer.lane_id, peer_boot = "spawn-native-boot", bind_id = "native-bind", messages = {} }
			f.native_metadata.lanes = { f.native_lane }
		elseif outer.act == "migration" then
			assert(outer.peer_boot == f.native_lane.peer_boot and outer.lane_id == f.native_lane.lane_id)
			table.insert(f.native_stages, runtime.json.decode(outer.bytes))
		elseif outer.act == "ack" then
			f.native_ack = runtime.json.decode(outer.bytes)
		else error("unexpected native migration transport act " .. tostring(outer.act)) end
	end
	function f.cx.session:surface(pane, options)
		if pane ~= 9 or f.hidden[9] then return nil end
		local key = options.root:sub(6)
		local role, value
		if key == "ownership-alias" then
			role, value = "orchplus.alias", f.native_alias or { version = 2, host_pane_id = "9", alias_nonce = "view", owners = {} }
		elseif key == "orchplus-spawn-relay" then role, value = "orchplus.spawn-relay", f.native_metadata
		elseif key == "setup-catalog-request" then role, value = "orchplus.setup.request", if f.delay_native_witness then nil else f.catalog_request
		elseif key == "orchestration-result" then role, value = "orchplus.orchestration.result", f.native_creation
		elseif key == "dispatch-state" then role, value = "orchplus.dispatch", f.native_dispatch
		elseif f.native_lane and key == "spawn-relay-" .. f.native_lane.lane_id .. "-current" then
			role, value = "orchplus.spawn-current", f.native_current
		else return nil end
		if value == nil then return nil end
		return { surface = { role = "plugin.orchplus.orchestrator" },
			main = { id = options.root, k = "text", p = { role = role, spans = { runtime.json.encode(value) } }, c = {} } }
	end
	function f:start_native(operation)
		api.migrate(self.cx, 9, self.native_origin, operation or { operation = "source" }, function(_, projection, problem, receipt, code)
			table.insert(self.native_results, { projection = projection, problem = problem, receipt = receipt, code = code })
		end)
		api.migration_tick(self.cx)
	end
	function f:publish_native(change)
		local request = assert(self.native_stages[#self.native_stages])
		local source = copy(self.peer)
		self.native_current = copy(source)
		self.native_current.migration_response = { request_json = request.request_json, operation = request.operation,
			response = { ok = true, value = copy(source.qualification) }, source = source }
		self.native_lane.messages.current = { id = "native-result-" .. tostring(#self.native_stages), incarnation = self.native_lane.peer_boot,
			route = "spawn.current", binding = self.native_metadata.relay_endpoint .. ":" .. self.native_lane.lane_id }
		if change then change(self.native_current) end
	end
	function f:created_native()
		self.creation = { request_id = "native-create", orch_session_id = "native-session", owner_id = "native-owner",
			generation = 1, authority_namespace = "migration-candidate", source_nonce = "view" }
		self.native_alias = { version = 2, host_pane_id = "9", alias_nonce = "view", authority_namespace = "migration-candidate",
			orch_session_id = "native-session", session_closed = false,
			owners = { controller = { owner_id = "native-owner", generation = 1, alias_nonce = "view" } } }
		self.native_creation = { ok = true, code = "controller_granted", request_id = "native-create", orch_session_id = "native-session",
			owner_id = "native-owner", generation = 1, owner = { owner_id = "native-owner", generation = 1, owner_active = true,
				phase = "active", pane_binding = { host_pane_id = "9", alias_nonce = "view" } } }
		self.native_dispatch = { authority_namespace = "migration-candidate", orch_session_id = "native-session", source_nonce = "view",
			owner_id = "native-owner", owner_generation = 1, controller_phase = "active", session_control = { phase = "open" } }
	end
	return f
end
do
	local f = native_migration_fixture()
	f:start_native()
	check(#f.native_stages == 1 and f.native_stages[1].operation == "source"
		and same(runtime.json.decode(f.native_stages[1].request_json), f.catalog_request)
		and #f.new_blocks == 0, "real window adapter publishes the native witness before one pane-free source stage, without a catalog query")
	f:publish_native(function(value) value.migration_response.request_json = "{}" end)
	f.native_api.migration_tick(f.cx)
	check(#f.native_results == 0, "another operation's result cannot settle the current native update")
	f:publish_native()
	f.native_api.migration_tick(f.cx); f.native_api.migration_tick(f.cx)
	check(#f.native_results == 1 and f.native_results[1].problem == nil
		and same(f.native_results[1].projection, f.peer)
		and f.native_results[1].receipt.receipt.id == f.native_lane.messages.current.id and #f.native_stages == 1,
		"exact current source result returns its actual carrier receipt once without resubmitting the phase")
end
do
	local f = native_migration_fixture()
	f:start_native({ operation = "inspect", expected = copy(f.peer.qualification.proof), peer = copy(f.migration) })
	f:publish_native(function(value) value.migration_response.response.value.compatibility = copy(f.peer.compatibility) end)
	f.native_api.migration_tick(f.cx)
	check(#f.native_results == 1 and f.native_results[1].problem == nil,
		"actual inspect qualification may include validated compatibility without changing its exact source proof")
end
for _, change in {
	function(value) value.migration_response.extra = true end,
	function(value) value.migration_response.source.extra = true end,
	function(value) value.authority_revision += 1 end,
	function(value) value.migration_response.response.value.proof.source_revision += 1 end,
} do
	local f = native_migration_fixture(); f:start_native(); f:publish_native(change)
	f.native_api.migration_tick(f.cx)
	check(#f.native_results == 1 and f.native_results[1].projection == nil and f.native_results[1].problem ~= nil
		and #f.native_stages == 1, "malformed or no-longer-current native source evidence cannot advance or replay an update")
end
do
	local f = native_migration_fixture(); f:start_native(); f:publish_native()
	f.hidden[9] = true; clock = 31000; f.native_api.migration_tick(f.cx)
	check(#f.native_results == 0, "hidden native surface does not turn a retained positive source result into a failed mutation")
	f.hidden[9] = nil; f.native_api.migration_tick(f.cx)
	check(#f.native_results == 1 and f.native_results[1].problem == nil and #f.native_stages == 1,
		"returning to the same native context consumes its exact retained result before applying a local wait timeout")
end
do
	local f = native_migration_fixture(); f:start_native(); clock = 31000
	f.native_api.migration_tick(f.cx); f.native_api.migration_tick(f.cx)
	check(#f.native_results == 1 and f.native_results[1].projection == nil and f.native_results[1].problem ~= nil
		and #f.native_stages == 1, "unconfirmed update outcome stops without renewing or replaying its original phase")
end
do
	local f = native_migration_fixture(); f:start_native(); f:publish_native()
	f.native_metadata.relay_boot = "reloaded-orch-host"
	f.native_api.migration_tick(f.cx)
	check(#f.native_results == 1 and f.native_results[1].projection == nil and #f.native_stages == 1,
		"host incarnation changes cannot adopt an old update response or create a replacement phase")
end
for _, boundary in { "window", "session", "host" } do
	local f = native_migration_fixture(); f:start_native(); f:publish_native()
	if boundary == "window" then f.window = "other-window"
	elseif boundary == "session" then f.session_id = 4
	else f.host_id = 7 end
	f.native_api.migration_tick(f.cx)
	check(#f.native_results == 1 and f.native_results[1].projection == nil and #f.native_stages == 1,
		boundary .. ": changed current native identity cannot advance an update through a still-readable old panel")
end
do
	local f = native_migration_fixture(); f:created_native(); f:start_native()
	f:publish_native(function(value)
		value.migration_response.source = nil
		value.migration_response.response = { ok = false, error = "Managed state has never been initialized", disposition = "refused", code = "source_absent" }
	end)
	f.native_api.migration_tick(f.cx)
	check(#f.native_results == 1 and f.native_results[1].code == "source_absent" and f.native_results[1].receipt ~= nil,
		"only the exact correlated native source refusal returns typed genuine absence with its carrier receipt")
	local lane = f.native_lane.lane_id
	f:start_native({ operation = "bootstrap", creation = copy(f.creation) })
	check(#f.native_stages == 2 and f.native_stages[2].operation == "bootstrap"
		and same(f.native_stages[2].creation, f.creation) and f.native_stages[2].expected == nil
		and f.native_stages[2].peer == nil and f.native_lane.lane_id == lane and #f.new_blocks == 0,
		"real window bootstrap publishes the exact Create witness on the same pane-free setup lane")
	f:publish_native(); f.native_api.migration_tick(f.cx)
	check(#f.native_results == 2 and f.native_results[2].problem == nil and f.native_results[2].projection ~= nil,
		"bootstrap settles only from its actual matching source projection, never a callback echo")
end
for _, change in {
	function(f) f.creation.request_id = "forged-create" end,
	function(f) f.native_alias.owners.controller.generation = 2 end,
	function(f) f.native_creation.owner.pane_binding.alias_nonce = "old-view" end,
	function(f) f.native_dispatch.session_control.admitted = true end,
	function(f) f.native_dispatch.controller_phase = "restored" end,
	function(f) f.creation.extra = true end,
} do
	local f = native_migration_fixture(); f:created_native(); change(f)
	f:start_native({ operation = "bootstrap", creation = copy(f.creation) })
	check(#f.native_stages == 0 and #f.native_results == 1 and f.native_results[1].problem ~= nil,
		"forged, open, stale, admitted or inactive creation evidence cannot publish a bootstrap stage")
end
do
	local f = native_migration_fixture(); f:created_native(); f.delay_native_witness = true
	f:start_native({ operation = "bootstrap", creation = copy(f.creation) })
	f.native_creation.owner_id = "replacement-owner"; f.delay_native_witness = nil
	f.native_api.migration_tick(f.cx)
	check(#f.native_stages == 0 and #f.native_results == 1 and f.native_results[1].problem ~= nil,
		"creation ownership is reread after request publication and before the bootstrap is actually submitted")
end
for _, variant in { "no_receipt", "uncertain_absence", "wrong_code" } do
	local f = native_migration_fixture(); f:start_native()
	f:publish_native(function(value)
		value.migration_response.response = { ok = false, error = "No confirmed source", disposition = "refused", code = "source_absent" }
		if variant == "uncertain_absence" then value.migration_response.response.disposition = "uncertain"
		elseif variant == "wrong_code" then value.migration_response.response.code = "bootstrap_refused" end
	end)
	if variant == "no_receipt" then f.native_lane.messages.current = nil; clock = 31000 end
	f.native_api.migration_tick(f.cx)
	check(#f.native_results == 1 and f.native_results[1].code == nil and f.native_results[1].projection == nil,
		"uncertain, operation-mismatched or receiptless errors never become genuine-absence authorization")
end
return "setup_ui: " .. tostring(checks) .. " checks"
