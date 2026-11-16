-- Actual source-window/parser/adapter consumers; native endpoints retain observable board effects.
local root, section = ...
local runtime, environment = tern, getfenv()
local desktop
local test_tern = setmetatable({ plugin = { data = "/desktop/plugin-data" }, fs = {
	exists = function(path) return desktop.files[path] ~= nil end,
	mkdir = function(path) desktop.directories[path] = true end,
	read = function(path, maximum)
		local bytes = assert(desktop.files[path], "missing desktop file")
		assert(maximum == 16384 and #bytes <= maximum, "journal reads are bounded regular-file reads")
		return bytes
	end,
	write = function(path, bytes)
		if desktop.journal_error then error("desktop journal unavailable") end
		desktop.files[path] = bytes
	end,
	remove = function(path) desktop.files[path] = nil end,
} }, { __index = runtime })
local modules = {}
local function load(name)
	name = name:gsub("^%./", "")
	if modules[name] then return modules[name] end
	local chunk = assert(loadstring(runtime.fs.read(root .. "/" .. name .. ".luau"), name))
	setfenv(chunk, setmetatable({ require = load, tern = test_tern }, { __index = environment }))
	local value = chunk(); modules[name] = value; return value
end
local source_ui, adapter, parser, quota = load("source_window"), load("source_adapter"), load("plan_import"), load("quota")
local codec = load("wire/codec")
local checks = 0
local function check(ok, message) assert(ok, message); checks += 1 end
local PLAN = [[# Feature: Source UI research
## CP1 — Research
### Task A1 — Find evidence
**INDEPENDENT**
#### Steps
- [ ] Read the evidence
### Task A2 — Compare evidence
SEQUENTIAL: Wait for evidence.
Compare the evidence.
]]
local path, intake_board = "/host/plans/research.md", "/desktop/Work board.md"
local function native_tags(value)
	local tags = {}
	for tag in value:gmatch("#([A-Za-z0-9_%-]+)") do if not table.find(tags, tag) then table.insert(tags, tag) end end
	return tags
end
local function card(id, text, tags) return { id = id, text = text, tags = tags or {}, done = false } end
local function fixture()
	local f = { clock = 0, serial = 0, valid = true, sent = {}, events = {}, notices = {}, reads = {}, writes = {}, pending = {},
		files = {}, directories = {}, forms = {}, policy = { glitch_integration = true, work_on_enabled = true, paused = true, templates = {} }, snapshot = {},
		lanes = { { id = "lane-1", title = "Plans", complete = false, more = 0, cards = {} } }, page_lanes = 1,
		plan = assert(parser.parse(PLAN)), selected_board = intake_board }
	f.authority_revision = 1
	f.origin = { alias_nonce = "source-view", logical_session_id = "session", owner_id = "owner", window_host_id = "remote-host", expected_revision = 1 }
	function f:context()
		desktop = self
		local cx = { session = {}, board = {}, docs = {}, layout = {} }; self.cx = cx
		local function current() check(f.cx == cx, "native effects receive the current callback context") end
		local function pending(kind, fields)
			current(); fields.kind = kind; table.insert(f.pending, fields)
			return { next = function(_, callback) fields.callback = callback end }
		end
		function cx.session:pane(value)
			current()
			if value ~= 88 or f.link_missing then return nil end
			return { pane = value, kind = f.link_kind or "board", path = f.link_board or f.ui.board_path(f.origin) }
		end
		function cx.layout:focus(pane) current(); f.focused = pane end
		function cx:open(value) current(); f.opened_source = value end
		function cx:toast(_, message) current(); f.route_error = message end
		function cx:pick(opts)
			current(); f.conflict = { options = opts }
			return { next = function(_, callback) f.conflict.callback = callback end }
		end
		function cx.session:event(_, event)
			current(); check(event.act == "source-discover", "source window uses only host source-discovery events")
			local request = runtime.json.decode(event.value); table.insert(f.events, request)
			local response
			if f.discovery_fn then response = f.discovery_fn(request)
			elseif request.revision and request.revision ~= f.plan.plan_revision then response = { ok = false, message = "Plan changed" }
			elseif request.metadata_only then response = { ok = true, source = { kind = "plan_file", path = request.path, revision = f.plan.plan_revision, plan = { title = f.plan.title } } }
			else
				local bytes = runtime.json.encode({ kind = "plan_file", path = request.path, revision = f.plan.plan_revision, plan = f.plan })
				local offset = request.offset or 0; local last = math.min(#bytes, offset + 137)
				while last < #bytes and bytes:byte(last + 1) >= 128 and bytes:byte(last + 1) < 192 do last -= 1 end
				response = { ok = true, source_page = { path = request.path, revision = f.plan.plan_revision, offset = offset,
					bytes = bytes:sub(offset + 1, last), total_bytes = #bytes, sha256 = codec.sha256(bytes), next_offset = if last < #bytes then last else nil } }
			end
			response.request_id = request.request_id; f.discovery = response
		end
		function cx.board:boards() return pending("boards", {}) end
		function cx.board:read(value, opts)
			table.insert(f.reads, { path = value, options = opts })
			return pending("read", { path = value, options = opts })
		end
		function cx.board:add(value, fields) return pending("add", { path = value, card = fields }) end
		function cx.board:edit(id, fields) return pending("edit", { id = id, fields = fields }) end
		function cx.board:check(id, done) return pending("check", { id = id, done = done }) end
		function cx.board:add_lane(value, fields) return pending("add-lane", { path = value, fields = fields }) end
		function cx.board:open(value) current(); f.opened = value; return 88 end
		function cx.docs:read(value) return pending("doc-read", { path = value }) end
		function cx.docs:write(value, bytes) return pending("doc-write", { path = value, bytes = bytes }) end
		function cx.docs:edit(value, fields) return pending("doc-edit", { path = value, fields = fields }) end
		function cx.docs:search(value, query) return pending("doc-search", { path = value, query = query }) end
		return cx
	end
	function f:resolve()
		local operation = table.remove(self.pending, 1); if not operation then return end
		local value, err
		if operation.kind == "boards" then value = { { path = self.selected_board, open = true } }
		elseif operation.kind == "read" then
			local lanes = {}; local last = math.min(#self.lanes, operation.options.from + self.page_lanes - 1)
			for i = operation.options.from, last do table.insert(lanes, self.lanes[i]) end
			local count, done = 0, 0; for _, lane in ipairs(self.lanes) do for _, row in ipairs(lane.cards) do count += 1; if row.done then done += 1 end end end
			value = { path = if operation.path == "relative.md" then self.selected_board else operation.path,
				phase = "ready", total = #self.lanes, open = count - done, done = done, more = #self.lanes - last, first = operation.options.from, lanes = lanes }
		elseif operation.kind == "doc-read" then value = self.files[operation.path]
		elseif operation.kind == "doc-search" then
			value = {}
			for line, text in ipairs((self.files[operation.path] or ""):split("\n")) do
				local column = text:find(operation.query, 1, true)
				if column then table.insert(value, { line = line, column = column, text = text }) end
			end
		else
			table.insert(self.writes, operation)
			if self.write_error then err = self.write_error
			elseif operation.kind == "doc-write" then
				self.files[operation.path] = operation.bytes; value = { from = 1, to = 6 }; self.lanes = {}
				for title in operation.bytes:gmatch("\n## ([^\n]+)") do
					table.insert(self.lanes, { id = "seed-lane-" .. tostring(#self.lanes + 1), title = title, complete = title == "Done", more = 0, cards = {} })
				end
			elseif operation.kind == "doc-edit" then self.files[operation.path] = operation.fields.insert .. self.files[operation.path]; value = { from = 1, to = 1 }
			elseif operation.kind == "add-lane" then
				value = runtime.json.encode({ operation.path, 1, #self.writes })
				table.insert(self.lanes, { id = value, title = operation.fields.title, complete = false, more = 0, cards = {} })
			elseif operation.kind == "add" then
				value = runtime.json.encode({ operation.path, 1, #self.writes })
				for _, lane in ipairs(self.lanes) do if lane.id == operation.card.lane or lane.title == operation.card.lane then table.insert(lane.cards, card(value, operation.card.text, native_tags(operation.card.text))) end end
			else
				value = false
				for _, lane in ipairs(self.lanes) do for _, row in ipairs(lane.cards) do if row.id == operation.id then
					if operation.kind == "check" then row.done = operation.done else row.text = operation.fields.text; row.tags = native_tags(operation.fields.text) end
					value = true
				end end end
			end
		end
		if self.invalid_result ~= nil then value = self.invalid_result end
		operation.callback(value, err, self:context())
	end
	local function retain(kind, spec, done)
		local form = { kind = kind, spec = spec, done = done }; table.insert(f.forms, form); f.form, f.retained_form = form, form
	end
	f.api = {
		id = function() f.serial += 1; return "source-request-" .. tostring(f.serial) end,
		now = function() f.clock += 0.05; return f.clock end,
		current = function(cx, _, origin) return f.valid and cx == f.cx and origin.alias_nonce == f.origin.alias_nonce end,
		origin = function() return f.origin end,
		fresh = function(cx) check(cx == f.cx, "authority intent is captured in a fresh context"); local origin = table.clone(f.origin); origin.expected_revision = f.authority_revision; return origin end,
		snapshot = function() return f.snapshot end,
		forms = {
			choose = function(_, _, _, spec, done) retain("choose", spec, done) end,
			open = function(_, _, _, spec, done) retain("open", spec, done) end,
			active = function(_, tag) return f.retained_form ~= nil and (tag == nil or f.retained_form.spec.tag == tag) end,
			update = function(_, _, patch)
				if not f.retained_form then return false end
				f.form = f.retained_form; f.form.feedback = patch
				return true
			end,
			cancel = function() f.form, f.retained_form = nil, nil; f.form_cancelled = true end,
		},
		work_on = function(_, _, _, _, done) f.work_done = done end,
		source_settings = function() f.settings_opened = (f.settings_opened or 0) + 1; return true end,
		node = function(_, _, key)
			if key == "workflow-index" then return { policy = f.policy, plan_ids = { "plan-1" } }
			elseif key == "workflow-plan-plan-1" then return { path = path }
			elseif key == "source-discovery" then return f.discovery
			elseif key == "project-index" then return { projects = { existing = { name = "Existing research" } } }
			elseif key == "workflow-gate-gate" then return f.gate
			elseif key == "decision-context-result" then return f.decision_result end
		end,
		send = function(cx, _, origin, command, fields)
			check(cx == f.cx, "authority send uses fresh callback context")
			f.serial += 1; local id = "command-" .. tostring(f.serial)
			table.insert(f.sent, { command = command, fields = fields, request_id = id })
			if f.auto_ack then f.snapshot.command_result = { request_id = id, ok = origin.expected_revision == f.authority_revision, orch_project_id = fields.orch_project_id or "created-project" } end
			return id
		end,
		decision = function(_, _, _, command, fields) f.serial += 1; f.decision = { request_id = "decision-" .. f.serial, command = command, fields = fields }; return f.decision.request_id end,
		notice = function(_, _, _, message, level) table.insert(f.notices, { message = message, level = level }) end,
	}
	f.ui = source_ui.new(f.api)
	function f:reload()
		-- Queued native effects survive, but the old VM's callbacks do not.
		for _, operation in ipairs(self.pending) do operation.callback = function() end end
		self.ui = source_ui.new(self.api)
	end
	function f:start(command, request) self.ui.start(self:context(), 1, self.origin, command, request or {}) end
	function f:tick() self.ui.tick(self:context()) end
	function f:until_(predicate)
		for _ = 1, 10000 do if predicate() then return end; if #self.pending > 0 then self:resolve() else self:tick() end end
		error("source consumer did not reach expected native boundary")
	end
	function f:choose(match)
		self:until_(function() return self.form ~= nil end)
		local form = self.form; self.form = nil; check(form.kind == "choose", "choice uses native pane form adapter")
		local selected; for _, item in ipairs(form.spec.items) do if match(item) then selected = item; break end end
		assert(selected, "expected source form choice"); form.done(self:context(), selected)
		if f.retained_form == form then f.retained_form = nil end
	end
	function f:values(values, action)
		self:until_(function() return self.form ~= nil end)
		local form = self.form; self.form = nil; check(form.kind == "open", "source fields submit one in-pane values object")
		form.done(self:context(), values, action or "submit")
	end
	function f:notice() self:until_(function() return #self.notices > 0 end); return self.notices[#self.notices] end
	function f:sync() self.ui.sync(self:context(), 1, self.origin) end
	function f:settle() self:until_(function() return not self.ui.active(1) and #self.pending == 0 end) end
	function f:again() self.clock += 6000; self:sync() end
	function f:cards()
		local cards = {}; for _, lane in ipairs(self.lanes) do for _, row in ipairs(lane.cards) do table.insert(cards, row) end end
		return cards
	end
	return f
end

if section == nil or section == "discovery" then
	do
		local f = fixture(); f.auto_ack = true; f.policy.glitch_integration = false
		f:start("add-plan"); f:values({ path = path }); f:choose(function(item) return item.project_id == "existing" end)
		f.authority_revision += 1; check(f:notice().level == "success" and #f.sent == 1, "neutral form plan import survives unrelated bookkeeping without START or replay")
		check(f.sent[1].command == "plan_import" and f.sent[1].fields.source_revision == f.plan.plan_revision and f.sent[1].fields.orch_project_id == "existing", "host parser's selected revision reaches the existing single writer")
	end
	do
		local f = fixture(); f:start("work-on"); check(f.work_done and #f.events == 0 and #f.forms == 0, "WORK ON delegates to the real WORK pane, not another ORCH catalog")
		f.work_done(f:context(), { kind = "plan_file", path = path, revision = f.plan.plan_revision }, function(_, accepted) f.work_accepted = accepted end)
		f:choose(function(item) return item.project_id == "existing" end); f:until_(function() return #f.sent == 1 end)
		check(f.work_accepted == nil, "WORK frame is not ACKed merely because source discovery finished")
		f.snapshot.command_result = { request_id = f.sent[1].request_id, ok = true }; f:settle()
		check(f.work_accepted == true, "WORK selection ACK follows actual authority acceptance")
	end
	for _, ending in ipairs({ "refused", "timeout", "cancelled" }) do
		local f = fixture(); f:start("work-on")
		f.work_done(f:context(), { kind = "plan_file", path = path, revision = f.plan.plan_revision }, function(_, accepted, message, outcome)
			f.work_accepted, f.work_message, f.work_outcome = accepted, message, outcome
		end)
		if ending == "cancelled" then
			f:until_(function() return f.form ~= nil end)
			local form = f.form; f.form = nil; form.done(f:context(), nil)
		else
			f:choose(function(item) return item.project_id == "existing" end); f:until_(function() return #f.sent == 1 end)
			if ending == "refused" then f.snapshot.command_result = { request_id = f.sent[1].request_id, ok = false, message = "Selected source changed" }
			else f.clock += 16000 end
		end
		f:settle()
		check(f.work_accepted == false and f.work_outcome == (if ending == "cancelled" then "cancelled" else "refused"),
			"WORK request settles with a non-success outcome after " .. ending .. " rather than remaining Returning selected context")
		check(#f.sent == (if ending == "cancelled" then 0 else 1), "WORK settlement never resends an issued domain command")
		if ending ~= "cancelled" then check(type(f.work_message) == "string" and #f.work_message > 0, "WORK receives the actual refusal or unknown-completion explanation") end
	end
	do
		local f = fixture(); f.policy.glitch_integration = false; f:start("work-on")
		check(f.work_done == nil and #f.events == 0 and #f.sent == 0, "Glitch-off has no WORK prerequisite")
	end
	do
		local f = fixture(); f:start("work-on")
		f.work_done(f:context(), { kind = "plan_file", path = path, revision = f.plan.plan_revision }, function(_, accepted, message, outcome)
			f.work_accepted, f.work_message, f.work_outcome = accepted, message, outcome
		end)
		f:choose(function(item) return item.project_id == "existing" end); f:until_(function() return #f.sent == 1 end)
		f.valid = false; f:tick()
		check(f.work_accepted == false and f.work_outcome == "refused" and f.work_message:find("unknown", 1, true) and #f.sent == 1,
			"changed origin after a sent import reports unknown completion, not cancellation or a fabricated nothing-imported result")
	end
	do
		local f = fixture(); f:start("work-on"); local delayed = f.work_done
		f.valid = false; f:tick(); f.valid = true
		delayed(f:context(), { kind = "plan_file", path = path, revision = f.plan.plan_revision }, function(_, accepted, _message, outcome)
			f.work_accepted, f.work_outcome = accepted, outcome
		end)
		check(f.work_accepted == false and f.work_outcome == "cancelled" and #f.sent == 0,
			"a WORK frame delivered after its source job ended receives a terminal UI ACK without importing")
	end
	do
		local f = fixture(); f:start("add-plan"); f:values({ path = path }); f:choose(function(item) return item.new end)
		f.policy.auto_start_projects = true; check(f:notice().level == "error" and #f.sent == 0, "held source cannot silently become automatic execution while its form is open")
	end
	do
		local f = fixture(); f.policy.templates = { { id = "research", title = "Research", prompt = "Research {input} for {audience}", output = "notes/{audience}.md", next = "", custom_fields = { audience = "engineers", tone = "neutral" } } }
		f:start("start-template"); f:choose(function(item) return item.template ~= nil end); f:values({ input = "Retain this topic", ["custom-audience"] = "designers", ["custom-tone"] = "neutral" })
		f:choose(function(item) return item.new end); f:until_(function() return #f.sent == 1 end)
		check(f.sent[1].fields.custom_fields.audience == "designers" and f.sent[1].fields.custom_fields.tone == nil,
			"only actual changed field values become invocation overrides; template defaults cannot leak into the next template")
		f.snapshot.command_result = { request_id = f.sent[1].request_id, ok = false }; f:notice(); f:start("start-template"); f:choose(function(item) return item.template ~= nil end)
		f:until_(function() return f.form ~= nil end)
		check(f.form.spec.fields[1].value == "Retain this topic" and f.form.spec.fields[2].value == "designers" and #f.sent == 1, "refusal retains all source drafts without resubmitting")
	end
	do
		local f = fixture(); f.auto_ack = true; f:start("add-plan", { orch_project_id = "existing" }); f:values({ path = "" })
		check(f.form and f.form.feedback.errors.path and f.ui.active(1) and #f.events == 0 and #f.sent == 0,
			"invalid path stays editable in its pane without discovery or a domain command")
		f:values({ path = path })
		check(f:notice().level == "success" and f.retained_form == nil and #f.sent == 1,
			"corrected path submits once and terminal host acceptance settles the delivered source form")
	end
	do
		local f = fixture(); f.auto_ack = true
		f.policy.templates = { { id = "research", title = "Research", prompt = "Research {input}", output = "notes/result.md", next = "", custom_fields = {} } }
		f:start("start-template", { orch_project_id = "existing" }); f:choose(function(item) return item.template ~= nil end); f:values({ input = string.rep("x", 2049) })
		check(f.form and f.form.feedback.notice and f.ui.active(1) and #f.sent == 0,
			"oversized source input retains an editable form without creating work")
		f:values({ input = "Corrected topic" })
		check(f.retained_form ~= nil and #f.sent == 1, "delivered source draft remains owned until the actual host receipt")
		check(f:notice().level == "success" and #f.sent == 1 and f.sent[1].fields.input == "Corrected topic" and f.retained_form == nil,
			"corrected template input reaches its real command once and closes the delivered form")
	end
end
if section == nil or section == "board" then
	do
		local f = fixture(); f.auto_ack = true
		f.lanes[1].cards = { card("one", "First task"), card("mirror", "Plan", { "orchplus-plan-mirror" }) }
		table.insert(f.lanes, { id = "lane-2", title = "More", complete = false, more = 0, cards = { card("two", "Second task"), card("copy", "First task") } })
		f:start("add-board"); f:choose(function(item) return item.path ~= nil end); f:choose(function(item) return item.new end); f:choose(function(item) return item.add end); f:settle()
		check(#f.reads == 4 and f.reads[2].options.from == 2 and #f.sent == 2 and #f.writes == 0, "complete native lane paging deduplicates held intake without mutating the board")
		check(f.sent[2].fields.orch_project_id == "created-project", "batched board tasks retain confirmed project association")
	end
	do
		local f = fixture(); f.lanes[1].more = 1; f:start("add-board"); f:choose(function(item) return item.path ~= nil end)
		check(f:notice().level == "error" and #f.sent == 0, "unpageable native lane refuses incomplete source rather than importing its prefix")
	end
	do
		local f = fixture(); f.auto_ack = true; f.lanes[1].cards = { card("one", "Relative desktop task") }
		f:start("add-board", { orch_project_id = "existing" }); f:choose(function(item) return item.custom end)
		f:values({ board_path = "relative.md" }); f:choose(function(item) return item.add end); f:settle()
		check(f.reads[1].path == "relative.md" and f.reads[2].path == intake_board and f.sent[1].fields.board_path == intake_board,
			"relative board paths resolve through the actual desktop API before canonical source identity is sent to the host")
	end
end
if section == nil or section == "proposal" then
	for _, changed in ipairs({ false, true }) do
		local f = fixture(); f.lanes[1].cards = { card("one", "Approved board task") }
		local cards = assert(adapter.board_intakes({ path = intake_board, phase = "ready", more = 0, lanes = f.lanes }))
		f.gate = { revision = 7, source_request = { kind = "board", path = intake_board, revision = quota.digest(cards), orch_project_id = "existing" } }
		if changed then f.lanes[1].cards[1].text = "Changed" end
		f:start("source-proposal", { gate_id = "gate", gate_revision = 7 }); f:until_(function() return #f.sent > 0 or #f.notices > 0 end)
		check((#f.sent == 0) == changed, "only the exact complete native source can consume an approved source proposal")
	end
end
if section == nil or section == "sync" then
	do
		local f = fixture(); f:sync()
		f:until_(function() local page = f.discovery and f.discovery.source_page; return page and page.next_offset == nil end)
		f:tick()
		local issued = f.pending[1]
		check(issued and issued.kind == "doc-write" and #f.pending == 1,
			"one bounded turn drains correlated final-page parsing and ready continuations up to the next native I/O boundary")
		f:tick()
		check(#f.pending == 1 and f.pending[1] == issued and #f.writes == 0,
			"an unresolved native boundary never spins, issues another write or manufactures completion")
		f:settle()
		check(#f:cards() == 5 and #f.sent == 0, "drained presentation stages still complete the real hierarchy without domain execution")
	end
	do
		local f = fixture(); f.policy.board_path = "/desktop/" .. string.rep("nested/", 22) .. "Board.md"
		f:sync(); f:settle()
		local retained = 0; for name in pairs(f.files) do if name:find("/source-board-sync/", 1, true) then retained += 1 end end
		check(#f:cards() == 5 and #f:cards()[1].id > 128 and retained == 0,
			"genuine path-derived native lane/card callbacks settle the exact journal without arbitrary short-id holds")
	end
	do
		local f = fixture(); f:sync(); f:settle()
		local writes = #f.writes; local board = f.ui.board_path(f.origin)
		check(f.files[board] ~= nil and board:sub(1, 21) == "/desktop/plugin-data/" and #f:cards() == 5, "first relevant use creates the actual desktop native board and full declared hierarchy while paused")
		local columns = {}; for _, lane in ipairs(f.lanes) do columns[lane.title] = true end
		check(columns.Todo and columns.Doing and columns.Review and columns.Done and columns.Plans,
			"first-use native board includes functional intake/progress columns alongside source hierarchy lanes")
		check(#f.sent == 0 and #f.forms == 0 and f.conflict == nil, "automatic linked presentation requires no Copy, confirmation or execution command")
		local retained = 0
		for name in pairs(f.files) do if name:find("/source-board-sync/", 1, true) then retained += 1 end end
		check(retained == 0, "positive completion of every native effect in the current live batch removes only its own pending journal")
		local reads = #f.reads
		f.plan = assert(parser.parse(PLAN .. "\n## Progress\nBackground bookkeeping only.\n"))
		f:again(); f:settle()
		check(#f.writes == writes and #f.reads - reads == #f.lanes, "Progress-only source revisions perform one bounded poll, no per-card edit/check/rescan cycle")
		f:again(); f:settle(); check(#f.writes == writes, "bounded rescan does not duplicate unchanged native cards")
		f.plan = assert(parser.parse(PLAN:gsub("%[ %] Read", "[x] Read")))
		f:again(); f:settle()
		local completed = 0; for _, row in ipairs(f:cards()) do if row.done then completed += 1 end end
		check(completed == 1 and #f:cards() == 5 and #f.sent == 0, "explicit source child progress uses native check and fabricates no managed task or sibling completion")
		f:start("open-plan-board"); f:settle(); check(f.opened == board, "opening the real native board has no copy prerequisite")
		local url = f:cards()[1].text:match("%((tern://orchplus%-plan%?[^%)]+)%)")
		check(url and f.ui.route(f:context(), { pane = 88, url = url }) and f.opened_source == path and f.focused == 1,
			"real board source links use current execution-host native file navigation, not desktop path masquerading")
		f.opened_source = nil; f.link_board = "/desktop/Unrelated.md"
		f.ui.route(f:context(), { pane = 88, url = url })
		check(f.opened_source == nil and f.route_error ~= nil, "a copied link from an unrelated native board cannot cross its retained source binding")
		f.link_board = board; f.route_error = nil
		f.ui.route(f:context(), { pane = 88, url = url:gsub("scope=[a-f0-9]+", "scope=" .. string.rep("f", 24), 1) })
		check(f.opened_source == nil and f.route_error ~= nil, "edited link scope cannot acquire another retained navigation capability")
		f.route_error = nil
		f.ui.route(f:context(), { pane = 88, url = url:gsub("board=[a-f0-9]+", "board=" .. string.rep("f", 64), 1) })
		check(f.opened_source == nil and f.route_error ~= nil, "edited link board identity cannot bypass the actual native pane's board binding")
		for _, link in ipairs({ { url = url }, { url = url, pane = "88" }, { url = url, pane = 99 } }) do
			f.route_error = nil
			check(f.ui.route(f:context(), link) and f.opened_source == nil and f.route_error ~= nil,
				"claimed plan links without an actual numeric native board pane are handled as refusals, never opened or delegated to builtin navigation")
		end
		f.link_kind = "file"; f.route_error = nil
		check(f.ui.route(f:context(), { pane = 88, url = url }) and f.opened_source == nil and f.route_error ~= nil,
			"matching file-pane paths cannot masquerade as the native linked board")
		f.link_kind = nil; f.link_missing = true; f.route_error = nil
		check(f.ui.route(f:context(), { pane = 88, url = url }) and f.opened_source == nil and f.route_error ~= nil,
			"a removed native board pane is refused without throwing or opening an unbound plan")
	end
	do
		local f = fixture(); f:sync(); f:settle()
		local edited = "Human-edited plan summary · " .. f:cards()[1].text; f:cards()[1].text = edited
		local writes = #f.writes; f:again(); f:until_(function() return f.conflict ~= nil end)
		local conflict = f.conflict; f.conflict = nil; conflict.callback(conflict.options.items[1], nil, f:context()); f:settle()
		check(f:cards()[1].text == edited and #f.writes == writes, "automatic polling preserves actual human edits after a meaningful keep decision")
		f:again(); f:settle(); check(f.conflict == nil and #f.writes == writes, "the same kept conflict does not repeatedly interrupt the owner")
		f.plan = assert(parser.parse(PLAN .. "\n## Progress\nAnother progress report.\n"))
		f:again(); f:settle(); check(f.conflict == nil and #f.writes == writes, "a kept human conflict is not re-asked merely because whole-file progress revision changed")
	end
	do
		local f = fixture(); f:sync(); f:until_(function() for _, op in ipairs(f.pending) do if op.kind == "add" then return true end end; return false end)
		f.write_error = "Native write outcome unknown"; f:resolve(); f:settle(); local writes = #f.writes
		f.write_error = nil; f:again(); f:settle()
		check(#f.writes == writes, "an uncertain native create is never blindly replayed by automatic polling")
	end
	for _, kind in ipairs({ "doc-write", "add", "check" }) do
		local f = fixture(); f.plan = assert(parser.parse(PLAN:gsub("%[ %] Read", "[x] Read"))); f:sync()
		f:until_(function() return f.pending[1] and f.pending[1].kind == kind end)
		f.valid = false; f:tick()
		check(f.ui.active(1), "pending native " .. kind .. " waits for its callback/deadline despite unrelated inactive context")
		f:resolve()
		local retained = 0; for name in pairs(f.files) do if name:find("/source-board-sync/", 1, true) then retained += 1 end end
		check(retained == 0 and not f.ui.active(1), "genuine positive " .. kind .. " completion settles its original batch even while source context is inactive")
		f.valid = true; f:again(); f:settle()
		check(#f:cards() == 5 and f.conflict == nil, "context return resumes only remaining source presentation after documented native completion")
	end
	do
		local f = fixture(); f:sync(); f:until_(function() return f.pending[1] and f.pending[1].kind == "doc-write" end)
		f.clock += 20000; f:tick()
		local retained = 0; for name in pairs(f.files) do if name:find("/source-board-sync/", 1, true) then retained += 1 end end
		check(not f.ui.active(1) and retained == 1, "native timeout stops scheduling but retains the genuinely unknown issued write")
		f:resolve()
		retained = 0; for name in pairs(f.files) do if name:find("/source-board-sync/", 1, true) then retained += 1 end end
		check(retained == 0, "a genuine positive callback after timeout settles only its own still-retained batch")
		f:again(); f:settle()
		local creations = 0; for _, operation in ipairs(f.writes) do if operation.kind == "doc-write" then creations += 1 end end
		check(creations == 1 and #f:cards() == 5, "late positive completion allows remaining presentation without replaying board creation")
	end
	for _, invalid in ipairs({ false, {} }) do
		local f = fixture(); f:sync(); f:until_(function() return f.pending[1] and f.pending[1].kind == "doc-write" end)
		f.valid, f.invalid_result = false, invalid; f:resolve(); f.valid, f.invalid_result = true, nil
		local writes, retained = #f.writes, 0
		for name in pairs(f.files) do if name:find("/source-board-sync/", 1, true) then retained += 1 end end
		f:again(); f:settle()
		check(retained == 1 and #f.writes == writes, "false/malformed native range results are not promoted to successful completion evidence")
	end
	do
		local f = fixture(); f.plan = assert(parser.parse(PLAN:gsub("%[ %] Read", "[x] Read"))); f:sync(); f:settle()
		local checks_before = 0; for _, op in ipairs(f.writes) do if op.kind == "check" then checks_before += 1 end end
		f.plan = assert(parser.parse(PLAN:gsub("%[ %] Read", "[x] Read"):gsub("Find evidence", "Find primary evidence")))
		f:again(); f:settle()
		local checks_after = 0; for _, op in ipairs(f.writes) do if op.kind == "check" then checks_after += 1 end end
		check(checks_before == 1 and checks_after == checks_before, "description edits preserve an already-matching explicit native check without issuing another check")
	end
	do
		local f = fixture(); f:sync(); f:until_(function() return f.pending[1] and f.pending[1].kind == "add" end)
		f:reload(); local old_native = table.remove(f.pending, 1); local writes = #f.writes
		local journal, before
		for name, bytes in pairs(f.files) do if name:find("/source-board-sync/", 1, true) then journal, before = name, bytes end end
		f:start("open-plan-board"); f:until_(function() return f.form ~= nil end)
		check(f.form.spec.fields[1].disabled == true and f.opened == nil and #f.writes == writes and f.files[journal] == before,
			"unknown writer allows actual read-only native-board inspection without opening an editable board or clearing its journal")
		f:values({}, "choose-board"); f:settle()
		check(f.settings_opened == 1 and f.files[journal] == before, "choosing a separate board opens the real settings route and never resets unknown completion")
		table.insert(f.pending, old_native); f:resolve()
	end
	for _, kind in ipairs({ "doc-write", "add" }) do
		local f = fixture(); f:sync()
		f:until_(function() return f.pending[1] and f.pending[1].kind == kind end)
		f:reload()
		local issued = table.remove(f.pending, 1)
		local before, retained, journal_count = #f.writes, nil, 0
		for name, bytes in pairs(f.files) do
			if name:find("/source-board-sync/", 1, true) then retained = runtime.json.decode(bytes); journal_count += 1 end
		end
		check(journal_count == 1 and retained.phase == "pending" and retained.source_path == path
			and retained.source_revision == f.plan.plan_revision and retained.board_path == f.ui.board_path(f.origin),
			"issued native " .. kind .. " durably fences the exact source revision and desktop board before VM replacement")
		f:sync(); f:settle()
		check(#f.writes == before and #f.pending == 0, "replacement VM cannot reissue an unconfirmed native " .. kind)
		table.insert(f.pending, issued); f:resolve()
		f:again(); f:settle()
		check(#f.writes == before + 1, "late original " .. kind .. " completion is not permission for another batch")
		local remaining = 0
		for name in pairs(f.files) do if name:find("/source-board-sync/", 1, true) then remaining += 1 end end
		check(remaining == 1, "matching native output without its original completion callback leaves the durable unknown-write hold intact")
	end
	do
		local f = fixture(); f.journal_error = true; f:sync(); f:settle()
		check(#f.writes == 0 and #f.pending == 0 and #f.notices > 0, "unavailable durable journal refuses native writes before invocation")
	end
	for _, damage in ipairs({ "corrupt", "foreign-batch" }) do
		local f = fixture(); f:sync(); f:until_(function() return f.pending[1] and f.pending[1].kind == "doc-write" end)
		local journal
		for name in pairs(f.files) do if name:find("/source-board-sync/", 1, true) then journal = name end end
		assert(journal)
		local altered = "{unreadable-journal"
		if damage == "foreign-batch" then
			local value = runtime.json.decode(f.files[journal]); value.batch_id = "different-current-batch"; altered = runtime.json.encode(value)
		end
		f.files[journal] = altered; f:reload(); table.remove(f.pending, 1)
		f:sync(); f:settle()
		check(#f.writes == 0 and f.files[journal] == altered, damage .. " evidence survives reload and cannot be replaced by a new board sync")
	end
	do
		local f = fixture(); f:sync(); f:settle()
		local before, board = #f.writes, f.ui.board_path(f.origin)
		f.files[board] ..= "\n\n<!-- orchplus-linked-board v1 another-orchestration -->\n"
		f:again(); f:settle()
		check(#f.writes == before and f.conflict == nil and #f.notices > 0,
			"our marker cannot conceal another orchestration's marker later in the native board document")
	end
	do
		local f = fixture(); local board = f.ui.board_path(f.origin)
		f.files[board] = "# A human's unrelated board\n"; f:sync(); f:until_(function() return f.conflict ~= nil end)
		check(#f.writes == 0, "an existing custom board is untouched before a real linking decision")
		local decision = f.conflict; f.conflict = nil; decision.callback(decision.options.items[1], nil, f:context()); f:settle()
		f:again(); f:settle()
		check(#f.writes == 0 and f.conflict == nil and f.files[board] == "# A human's unrelated board\n", "keeping an unrelated board preserves it without repeated automatic prompts")
	end
	do
		local f = fixture(); f.policy.board_path = "custom/team.md"
		local board = f.ui.board_path(f.origin, f.policy.board_path)
		check(board:find("/boards/", 1, true) and board:sub(-15) == "/custom/team.md", "configured relative location resolves in the documented desktop orchestration folder")
		local original = "# Team board\n\n## Human work\n"
		f.files[board] = original; f.selected_board = board; f.lanes[1].title = "Human work"
		f.lanes[1].cards = { card("human", "A human's independent request", { "research" }) }
		f:sync(); f:until_(function() return f.conflict ~= nil end)
		local decision = f.conflict; f.conflict = nil; decision.callback(decision.options.items[2], nil, f:context()); f:settle()
		check(f.files[board]:sub(-#original) == original and f:cards()[1].id == "human" and f:cards()[1].text == "A human's independent request",
			"approved custom linking inserts provenance while preserving unrelated Markdown and human card content")
		local intakes = assert(adapter.board_intakes({ path = board, phase = "ready", more = 0, lanes = f.lanes }))
		check(#f:cards() == 6 and #intakes == 1 and intakes[1].card_id == "human", "automatic hierarchy synchronization followed by real intake projection excludes every own mirror but preserves human work")
		f.auto_ack = true; f:start("add-board", { orch_project_id = "existing" })
		f:choose(function(item) return item.path == board end); f:choose(function(item) return item.add end); f:settle()
		check(#f.sent == 1 and f.sent[1].fields.card_id == "human" and f.sent[1].fields.board_path == board,
			"native board sync then normal polling/import cannot enqueue duplicate plan work")
	end
end
assert(section == nil or table.find({ "discovery", "board", "proposal", "sync" }, section), "unknown source UI section")
return "source_ui/" .. tostring(section or "all") .. ": " .. tostring(checks) .. " checks"
