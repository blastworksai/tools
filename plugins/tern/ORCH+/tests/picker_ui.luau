-- Exercise authoritative catalog selection and display-only usage through the real window state machine.
local root = ...
local runtime, environment = tern, getfenv()
local provider = assert(loadstring(runtime.fs.read(root .. "/provider_display.luau")))()
local checks = 0
local function check(value, message) assert(value, message); checks += 1 end
local function record(id, extra)
	local row = { id = id, revision = 7, definition_revision = "definition-" .. id, provider = "claude", account_label = "Team",
		cwd = "/saved/" .. id, placement = "split", backend = "native-agent", eligible = true, enabled = true,
		capabilities = { "report-files-v1", "coordinator-control-v1" } }
	for key, value in extra or {} do row[key] = value end
	return row
end
local function page(records, cursor)
	return { loaded = true, namespace = "spawn", host_key = "host", config_revision = 7, revision = 7, records = records, next_cursor = cursor }
end
local function fixture(options)
	local f = { clock = 1000, wall = 1800000000, serial = 0, requests = {}, events = {}, outcomes = {}, selected = {}, notices = {}, catalog = page({}), current = true }
	local fake = table.clone(runtime); fake.now = function() return f.clock end
	local chunk = assert(loadstring(runtime.fs.read(root .. "/picker_window.luau")))
	setfenv(chunk, setmetatable({ tern = fake, os = { time = function() return f.wall end }, require = function(name) assert(name == "./provider_display"); return provider end }, { __index = environment }))
	f.module = chunk()
	f.cx = {}
	local function next_id() f.serial += 1; return "request-" .. f.serial end
	f.ui = f.module.new({
		forms = {
			active = function(_, tag) return f.form ~= nil and (tag == nil or f.form.spec.tag == tag) end,
			cancel = function() f.form = nil end,
			open = function(_, _, _, spec, done) f.form_opens = (f.form_opens or 0) + 1; f.form = { spec = spec, done = done } end,
			choose = function(_, _, _, spec, done) f.form_opens = (f.form_opens or 0) + 1; f.form = { spec = spec, done = done, choices = true } end,
			update = function(_, _, patch)
				if not f.form or f.update_failure then return false end
				if patch.choices then f.form.spec.items = patch.choices
				else for key, value in patch do f.form.spec[key] = value end end
				return true
			end,
		},
		current = function() return f.current end, fresh = function() return { alias_nonce = "alias" } end,
		id = next_id, notice = function(_, _, _, message, level, _, metadata)
			table.insert(f.notices, message); f.notice = { message = message, level = level, metadata = metadata }
		end,
		control = function(_, source, command, origin) f.control = { source = source, command = command, origin = origin } end,
		agent_titles = function() return provider.pane_title(f.native_pane) end,
		pane = function() return f.bound_pane end,
		node = function(_, _, key) return if key == "catalog-index" then f.catalog else f.context end,
		decision = function(_, _, _, command, fields)
			assert(command == "catalog"); local id = next_id(); f.context_request = id
			if not f.defer_context then f.context = { request_id = id, decision_context = "bound" } end
			return id
		end,
		catalog = function(_, _, _, cursor) local id = next_id(); table.insert(f.requests, { id = id, cursor = cursor }); return id end,
		snapshot = function(_, _, action) return if action then f.outcomes[action] else { command_result = f.receipt, driver_result = f.unrelated } end,
		usage_installed = function() return f.installed end,
		transport = function() return if f.no_usage then nil elseif f.pane_table then f.pane_table else 30 end,
		surface = function() return { id = "display" }, if f.response then runtime.json.encode(f.response) else nil end,
		event = function(_, _, event) table.insert(f.events, runtime.json.decode(event.value)); return true end,
		ack = function() f.acks = (f.acks or 0) + 1; return true end,
	})
	function f:tick() self.ui.tick(self.cx) end
	function f:open() self.ui.pick(self.cx, 1, { alias_nonce = "alias" }, options or {}, function(_, row, catalog)
		table.insert(self.selected, { row = row, catalog = catalog })
		if self.on_selected then self.on_selected(row, catalog) end
	end) end
	function f:settle(catalog, code)
		local request = assert(self.requests[#self.requests]); local action = "action-" .. request.id
		self.catalog, self.receipt = catalog, { request_id = request.id, action_id = action, ok = true }
		self.outcomes[action] = { result = { action_id = action, ok = true, code = code or "bridge_committed" } }; self:tick()
	end
	function f:select(position)
		local form = assert(self.form); assert(form.choices)
		form.done(self.cx, form.spec.items[position])
	end
	function f:reading(id, extra)
		local reading = { record_id = id, record_revision = 7, definition_revision = "definition-" .. id, namespace = "spawn", host_key = "host",
			config_revision = 7, scope_id = "subscription", state = "fresh", used = 42, observed_at_ms = self.wall * 1000 - 60000 }
		for key, value in extra or {} do reading[key] = value end
		return reading
	end
	function f:usage(rows, complete, cursor, status, revision)
		local request = assert(self.events[#self.events])
		self.response = { version = 1, display_only = true, request_id = request.request_id, op = request.op,
			ok = status == nil, status = status or "current", revision = revision or "usage-1", records = rows, complete = complete, next_cursor = cursor }
		self:tick()
	end
	function f:percentage(position)
		local item = self.form and self.form.choices and self.form.spec.items[position]
		return if item then tonumber(item.detail:match("^(%d+)%%")) else nil
	end
	return f
end

do
	local f = fixture(); f:open(); check(#f.requests == 1, "catalog starts one read")
	f:settle(page({ record("a") }, { revision = 7, index = 2 })); check(#f.requests == 2, "pagination is automatic")
	f:settle(page({ record("b") })); check(#f.form.spec.items == 2, "equal display labels remain separate choices")
	f:select(1); check(#f.selected == 0 and #f.requests == 3 and f.requests[3].cursor == nil, "selection rereads its exact original page")
	f.unrelated = { request_id = "background", ok = false }
	f:settle(page({ record("a") }, { revision = 7, index = 2 }))
	check(#f.selected == 1 and f.selected[1].row.id == "a" and f.selected[1].row.cwd == "/saved/a" and not f.ui.active(), "matching receipt commits only the selected authoritative record")
end
do
	-- Requester evidence (SKILLS-200): after the roster is whole, choosing a record from a later page makes the
	-- picker send that page's cursor to the host with no first page in the same request chain.
	local f = fixture(); f:open()
	f:settle(page({ record("a"), record("b") }, { revision = 7, index = 3 }))
	f:settle(page({ record("c"), record("d") }))
	check(#f.requests == 2 and f.requests[2].cursor.index == 3, "the picker walks the pages with SPAWN's cursor shape")
	f:select(3)
	check(#f.requests == 3 and f.requests[3].cursor ~= nil and f.requests[3].cursor.revision == 7 and f.requests[3].cursor.index == 3,
		"selecting a later-page record sends that page's bare cursor, a cursor page the host did not just chain from page one")
end
do
	local f = fixture()
	local callback_owned = false
	f.on_selected = function()
		callback_owned = f.form ~= nil
		f.form = { spec = { tag = "next-form" } }
	end
	f:open(); f:settle(page({ record("a") })); f:select(1); f:settle(page({ record("a") }))
	check(callback_owned and f.form and f.form.spec.tag == "next-form" and not f.ui.active(),
		"asynchronous acceptance calls its consumer while owned and never closes the replacement form")
end
do
	local f = fixture(); f:open(); f:settle(page({ record("a") }))
	f:usage({ f:reading("a") }, true); f:tick(); f:usage({}, true)
	local form, opens = f.form, f.form_opens
	f.wall += 60; f:tick()
	check(f.form == form and f.form_opens == opens, "age-only usage refresh retains the exact form instead of reopening or refocusing it")
	local settings = { spec = { tag = "settings" } }; f.form = settings; f:tick()
	check(f.form == settings and not f.ui.active(), "a superseded picker cannot overwrite another form or cancel its draft")
	local failed = fixture(); failed:open(); failed:settle(page({ record("a") })); failed.update_failure = true
	failed:select(1)
	check(not failed.ui.active() and failed.form == nil and #failed.requests == 1,
		"failed selection-progress ownership explicitly settles before any catalog recheck or launch")
end
do
	check(provider.pane_title({ title = "sudo", program = "/usr/bin/sudo" }) == nil,
		"an unchanged sudo wrapper title is not presented as a chosen pane name")
	check(provider.pane_title({ title = "My research", program = "/usr/bin/sudo" }) == "My research"
		and provider.pane_title({ title = "sudo", program = "omp" }) == "sudo",
		"native renamed titles are preserved without guessing a user-title flag")
	local f = fixture(); f.native_pane = { title = "sudo", program = "sudo" }
	f:open(); f:settle(page({ record("a") }))
	local form, opens, requests = f.form, f.form_opens, #f.requests
	check(not form.spec.items[1].label:find("sudo", 1, true), "default wrapper title stays out of the compact agent choice")
	f.native_pane.title = "Current user pane name"; f:tick()
	check(f.form == form and f.form_opens == opens and #f.requests == requests and #f.selected == 0
		and form.spec.items[1].label:find(f.native_pane.title, 1, true) ~= nil,
		"current native title updates the owned list without refocusing, selecting or reading another catalog")
end
do
	local f = fixture({ pane_binding = { pane_id = "51" }, pane_title = "Old attachment name" })
	f.native_pane, f.bound_pane = { title = "Different managed pane" }, { title = "Attached native pane" }
	f:open(); f:settle(page({ record("a") }))
	check(f.form.spec.items[1].label:find("Attached native pane", 1, true) ~= nil,
		"attachment selection uses its exact pane's current metadata rather than another session for that account")
	f.bound_pane = nil; f:tick()
	check(not f.form.spec.items[1].label:find("Attached native pane", 1, true) and #f.selected == 0,
		"a missing attachment pane loses its stale name without inferring stopped or making a selection")
end

do
	local f = fixture(); f:open(); f:tick(); f:tick(); check(#f.requests == 1, "waiting never repeats catalog effect")
	f:settle(page({ record("a") })); f:select(1); f:settle(page({ record("a", { cwd = "/changed" }) }))
	check(#f.selected == 0 and #f.notices == 1, "record revision/content change refuses selection")
	local other = fixture(); other:open(); other:settle(page({ record("a") }, { revision = 7, index = 2 }))
	local changed = page({ record("b") }); changed.namespace = "other"; other:settle(changed)
	check(#other.selected == 0 and #other.notices == 1, "mixed authorities cannot form a catalog")
end

do
	local f = fixture({ need = "coordinator-control-v1" }); f:open()
	f:settle(page({ record("disabled", { enabled = false }), record("unverified", { eligible = false }), record("worker", { capabilities = { "report-files-v1" } }) }))
	check(not f.form.choices and #f.events == 0 and #f.selected == 0, "only positive required capabilities are selectable")
	f.form.done(f.cx, nil, "cancel"); check(not f.ui.active(), "cancel settles empty selector")
	local delayed = fixture(); delayed.defer_context = true; delayed:open()
	delayed.context = { request_id = "wrong", decision_context = "wrong" }; delayed:tick(); check(#delayed.requests == 0, "unrelated context cannot authorize catalog")
	delayed.context = { request_id = delayed.context_request, decision_context = "bound" }; delayed:tick(); check(#delayed.requests == 1, "matching current context releases one read")
end

do
	local f = fixture({ need = "project-start-v1" }); f:open()
	f:settle(page({ record("old"), record("missing-control", { capabilities = { "report-files-v1", "project-start-v1" } }),
		record("current", { capabilities = { "report-files-v1", "coordinator-control-v1", "project-start-v1" } }) }))
	check(f.form.choices and #f.form.spec.items == 1 and f.form.spec.items[1].choice_key == "record:current", "fresh coordinator runtime selection requires both positive typed capabilities")
	f.form.done(f.cx, nil, "cancel")
	local preferences = fixture({ need = "coordinator-control-v1" }); preferences:open()
	preferences:settle(page({ record("saved-old") }))
	check(preferences.form.choices and #preferences.form.spec.items == 1, "saved preferred-agent metadata remains selectable without pretending an old runtime bundle supports START")
	preferences.form.done(preferences.cx, nil, "cancel")
end

do
	local f = fixture(); f.catalog = nil; f:open(); check(#f.requests == 0 and #f.notices == 1, "missing catalog is not empty success")
	local timeout = fixture(); timeout:open(); local loading = timeout.form
	check(loading.spec.description_tone == nil, "picker loading uses neutral default text")
	timeout.clock += 30001; timeout:tick()
	check(#timeout.notices == 1 and #timeout.selected == 0 and #timeout.requests == 1 and timeout.form == loading
		and timeout.form_opens == 1 and loading.spec.description_tone == "error" and not loading.spec.busy,
		"timeout replaces the owned loading state with an unlocked failure without reopening, selecting or retrying")
	check(timeout.notice.level == "error" and timeout.notice.message == loading.spec.description
		and timeout.notice.metadata.context == "catalog" and timeout.notice.metadata.code == "catalog_unconfirmed"
		and not loading.spec.description:find(timeout.notice.metadata.detail, 1, true),
		"native picker and dispatch notice agree on human severity while technical detail remains separate")
	check(#loading.spec.actions == 1 and loading.spec.actions[1].id == "check_connection",
		"failed native picker exposes one scoped observation action")
	loading.done(timeout.cx, nil, "check_connection")
	check(timeout.control.command == "check_connection" and timeout.control.source == 1 and timeout.control.origin.alias_nonce == "alias"
		and #timeout.requests == 1 and #timeout.selected == 0 and not timeout.ui.active(),
		"connection action invokes the real current-source handler without repeating catalog or choosing an agent")
end

do
	local f = fixture(); f:open(); f:settle(page({ record("a") }))
	f:usage({ f:reading("a") }, true); check(f:percentage(1) == nil, "snapshot does not publish before validation")
	f:tick(); check(f.events[#f.events].op == "validate", "display requires independent exact revision validation")
	f:usage({}, true); check(f:percentage(1) == 42, "validated display publishes atomically")
	f.clock += 15000; f:tick(); f:usage({}, nil, nil, "display_disabled")
	check(f:percentage(1) == nil, "revocation removes cached display")
end

do
	for _, field in { "namespace", "host_key", "definition_revision", "config_revision", "record_revision" } do
		local f = fixture(); f:open(); f:settle(page({ record("a") }))
		f:usage({ f:reading("a", { [field] = if field == "config_revision" or field == "record_revision" then 8 else "changed" }) }, true)
		f:tick(); f:usage({}, true); check(f:percentage(1) == nil, "changed identity cannot join usage: " .. field)
	end
	local f = fixture(); f:open(); f:settle(page({ record("a") })); f:usage({ f:reading("a"), f:reading("a") }, true)
	check(f:percentage(1) == nil, "ambiguous identity never publishes")
end

do
	local f = fixture(); f:open(); f:settle(page({ record("a"), record("b") }))
	local rows = { f:reading("a") }; for n = 2, 16 do table.insert(rows, f:reading("other-" .. n)) end
	f:usage(rows, false, 16); f:tick(); check(f.events[#f.events].cursor == 16, "usage pagination uses exact offsets")
	f:usage({ f:reading("b", { used = 63 }) }, true); f:tick(); check(f:percentage(1) == nil and f:percentage(2) == nil, "partial aggregate stays hidden")
	f:usage({}, true); check(f:percentage(1) == 42 and f:percentage(2) == 63, "complete validated aggregate publishes together")
end

do
	local f = fixture(); f:open(); f:settle(page({ record("a") })); local original = f.events[1]
	for _ = 1, 4 do f.clock += 15001; f:tick() end
	check(#f.events == 1 and f:percentage(1) == nil, "unanswered display read keeps immutable request without stale percentages")
	f.ui.cancel(f.cx, 1); f:open(); f:settle(page({ record("a") })); check(#f.events == 1, "reopen cannot replace unanswered display operation")
	f.response = { version = 1, display_only = true, request_id = original.request_id, op = "validate", ok = true, status = "current", revision = "late", records = {}, complete = true }
	f:tick(); check((f.acks or 0) == 0, "wrong-operation late reply cannot consume retained read")
	f.response.op = original.op; f:tick(); check(f.acks == 1, "exact abandoned reply drains with ACK")
	f.current = false; f:tick(); check(not f.ui.active() and #f.selected == 0, "lost controller cancels without selection")
end

do
	-- A USAGE restart between display pages must not leave an abandoned reader blocking later reads.
	local f = fixture(); f.pane_table = {}; f:open(); f:settle(page({ record("a") }))
	local rows = { f:reading("a") }; for n = 2, 16 do table.insert(rows, f:reading("other-" .. n)) end
	f:usage(rows, false, 16); f:tick()
	check(#f.events == 2 and f.events[2].op == "page", "second display page is in flight")
	f.response = nil; f.pane_table.peer_changed = true; f:tick()
	f:tick() -- the restarted helper keeps the old read's identity; the drain must release it.
	f.pane_table.peer_changed = nil; f:tick(); f:tick()
	check(#f.events >= 3 and f.events[#f.events].op == "snapshot", "after a helper restart a fresh usage snapshot read starts")
end
do
	local f = fixture(); local loaded, selected, full
	f.ui.load(f.cx, 1, {}, function(_, value) loaded = value end)
	f:settle(page({ record("a") }, { revision = 7, index = 2 })); f:settle(page({ record("b") }))
	check(loaded and #loaded.records == 2 and not f.ui.active(), "read-only load returns complete exact catalog")
	f.ui.ensure(f.cx, 1, {}, "a", function(_, row, catalog) selected, full = row, catalog end)
	f:settle(page({ record("a") }, { revision = 7, index = 2 }))
	check(selected and selected.id == "a" and #full.records == 2, "ensure revalidates saved record against original page")
	local failed = fixture(); local problem, metadata
	failed.ui.load(failed.cx, 1, {}, function(_, value, why, details)
		check(value == nil, "failed load produces no catalog"); problem, metadata = why, details
	end)
	failed.clock += 30001; failed:tick()
	check(problem and metadata.context == "catalog" and metadata.code == "catalog_unconfirmed" and not failed.ui.active(),
		"failed read-only load settles caller with typed catalog failure context")
end
do
	-- Backlog 8: Tern gives plugins no usage read API, so without USAGE the row only POINTS at Tern's own widget.
	local HINT = "Tern's own usage widget (widget bar › AI usage limits) shows per-provider limits. Install USAGE for per-account figures."
	local function detail(f) return f.form.spec.items[1].detail end
	-- Uninstalled, yet the host still publishes its own relay (transport succeeds) and the read goes unanswered.
	local gone = fixture(); gone.installed = false; gone.pane_table = {}; gone:open(); gone:settle(page({ record("a") })); gone:tick()
	check(detail(gone):find("Usage unavailable\n" .. HINT, 1, true) == 1, "USAGE uninstalled with the host relay present: hint shows")
	gone.clock += 60000; gone:tick()
	check(detail(gone):find("Usage unavailable\n" .. HINT, 1, true) == 1 and not detail(gone):find("%d+%%"), "after the read times out the hint stays and no number appears")
	-- Installed but unreachable (no transport / out of scope): unknown, never the hint.
	local lost = fixture(); lost.installed = true; lost.no_usage = true; lost:open(); lost:settle(page({ record("a") })); lost:tick()
	check(detail(lost):find("Usage unavailable", 1, true) == 1 and detail(lost):find("Tern's own usage widget", 1, true) == nil, "USAGE installed but unreachable: no hint")
	local unknown = fixture(); unknown.no_usage = true; unknown:open(); unknown:settle(page({ record("a") })); unknown:tick()
	check(detail(unknown):find("Tern's own usage widget", 1, true) == nil, "installation unknown (nil) with no transport: no hint")
	local present = fixture(); present.installed = true; present:open(); present:settle(page({ record("a") })); present:tick()
	check(detail(present):find("Tern's own usage widget", 1, true) == nil, "USAGE installed but silent: no hint")
	present:usage({ present:reading("a") }, true); present:tick(); present:usage({}, true)
	check(present:percentage(1) == 42 and detail(present):find("Tern's own usage widget", 1, true) == nil, "USAGE installed with data: no hint")
	local off = fixture(); off.installed = true; off:open(); off:settle(page({ record("a") })); off:tick(); off:usage({}, nil, nil, "display_disabled")
	check(detail(off):find("enable Show usage in ORCH+ in USAGE", 1, true) ~= nil and detail(off):find("Tern's own usage widget", 1, true) == nil, "USAGE installed but disabled: old text, no hint")
end
return "picker_ui: " .. checks .. " checks"
