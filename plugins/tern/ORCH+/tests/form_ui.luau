-- Native form editing behavior; no provider, filesystem mutation or plugin install.
local root = ...
local runtime, environment = tern, getfenv()
local checks = 0
local function check(ok, why) assert(ok, why); checks += 1 end
local function same(a, b)
	if type(a) ~= type(b) then return false end
	if type(a) ~= "table" then return a == b end
	for key, value in a do if not same(value, b[key]) then return false end end
	for key in b do if a[key] == nil then return false end end; return true
end
local listed = {}
local fake = setmetatable({ fs = { list = function(path)
	table.insert(listed, path)
	if path == "/host" then local out = {}; for i = 1, 140 do out[i] = "entry-" .. i end; return out end
	error("not a directory")
end } }, { __index = runtime })
local window_listed = {}
local window_runtime = setmetatable({ fs = { list = function(path)
	table.insert(window_listed, path)
	if path == "/desktop" then return { "window-file.md", "folder" } end
	if path == "/desktop/folder" then return { "nested.md" } end
	error("window folder unavailable")
end } }, { __index = runtime })
local function load(name, context)
	local chunk = assert(loadstring(runtime.fs.read(root .. "/" .. name .. ".luau"), name))
	setfenv(chunk, setmetatable({ tern = context or fake }, { __index = environment })); return chunk()
end
local host, adapter = load("form_host"), load("form_window", window_runtime)
local def = host.definition
local function spec()
	return { form_nonce = "nonce", request_id = "request", title = "Form", groups = { { id = "advanced", label = "Advanced", collapsed = true } },
		fields = {
			{ id = "text", label = "Text", kind = "editor", value = "A😀雪Z" },
			{ id = "enabled", label = "Enabled", kind = "switch", value = false },
			{ id = "dependent", label = "Dependent", kind = "text", value = "kept", enabled_by = "enabled" },
			{ id = "choice", label = "Choice", kind = "select", value = "a", options = { { value = "a", label = "A" }, { value = "b", label = "B", enabled_by = "enabled" } } },
			{ id = "agents", kind = "checklist", label = "Agents", value = runtime.json.array(), options = { { value = "agent", label = "Agent" } } },
			{ id = "secret", label = "Advanced", kind = "text", value = "retained", group = "advanced" },
			{ id = "path", label = "Host folder", kind = "path", value = "/host", scope = "host" },
			{ id = "desktop", label = "Board", kind = "path", value = "/desktop", scope = "desktop" },
		}, actions = { { id = "save", label = "Save", submit = true }, { id = "nav", label = "Navigate" } } }
end
local function find_node(node, predicate, id)
	id = id or "main"
	if predicate(node) then return node, id end
	for i, child in node.c or {} do
		local suffix = if child.p and child.p.key ~= nil then tostring(child.p.key) else tostring(i - 1)
		local found, native_id = find_node(child, predicate, id .. "." .. suffix)
		if found then return found, native_id end
	end
	return nil, nil
end
local function state() return def.init({}, { runtime.json.encode(spec()) }, nil) end
local function event(s, ev, cx)
	-- Use the real ancestry-qualified block ids, including checklist children.
	-- Intentionally stale/hidden-field events retain their old synthetic address.
	for _, key in { "id", "item" } do
		local short = if type(ev[key]) == "string" then ev[key]:match("^main%.(.+)$") else nil
		if short then
			local _, id = find_node(def.view(s, {}).main, function(node) return node.p and node.p.key == short end)
			if id then ev = table.clone(ev); ev[key] = id end
		end
	end
	def.event(s, ev, cx or {})
end
local function units(text) local n = 0; for _, code in utf8.codes(text) do n += if code > 65535 then 2 else 1 end; return n end
local function edit(s, id, from, to, text)
	event(s, { ev = "edit", id = "main.field:" .. id, ["from"] = from, to = to, len = units(s.values[id]), cursor = from + units(text), text = text })
end
local function change(s, id, value) event(s, { ev = "change", id = "main.field:" .. id, value = value }) end
local function focus(s, id)
	local cx = { frames = {} }
	function cx:frame(ops) table.insert(self.frames, ops) end
	event(s, { ev = "focus", id = "main.field:" .. id }, cx)
	return cx
end
local function key(s, cx, name, text) return def.key(s, { name = name, text = text }, cx) end
local function span_text(node)
	local spans = if node and node.p then node.p.spans else nil
	if type(spans) ~= "table" or #spans ~= 1 then return nil end
	local value = spans[1]; return if type(value) == "string" then value elseif type(value) == "table" then value.t else nil
end
local function click_action(s, encoded, cx)
	local node, id = find_node(def.view(s, {}).main, function(n) return n.k == "button" and n.p and n.p.actions and n.p.actions.click == encoded end)
	if not node or node.p.disabled or node.p.busy then return false end
	local act, value = encoded:match("^([^=]+)=(.*)$")
	def.event(s, { ev = "action", id = id, act = act or encoded, value = value }, cx or {})
	return true
end
local function action(s, name, value)
	if name == "form-ack" or name == "form-open" or name == "form-resume" or name == "form-refresh" then event(s, { ev = "action", act = name, value = value }); return true end
	return click_action(s, name .. (if value ~= nil then "=" .. tostring(value) else ""))
end
local function ack(s, value)
	value.form_nonce = "nonce"; value.request_id = "request"; action(s, "form-ack", runtime.json.encode(value))
end
local function contains(node, text)
	if node.p and node.p.text == text then return true end
	for _, child in node.c or {} do if contains(child, text) then return true end end
	return false
end
do
	local s = state(); edit(s, "text", 1, 3, "Ω")
	check(s.values.text == "AΩ雪Z" and s.cursors.text == 2, "native edits replace UTF16 units, not bytes or codepoints")
	event(s, { ev = "undo", id = "main.field:text" }); check(s.values.text == "A😀雪Z", "undo restores multi-byte draft")
	edit(s, "text", 2, 3, "bad"); check(s.values.text == "A😀雪Z", "an edit splitting a surrogate pair is refused")
	edit(s, "dependent", 0, 4, "lost"); check(s.values.dependent == "kept", "disabled field cannot change")
	change(s, "enabled", true); edit(s, "dependent", 0, 4, "changed"); check(s.values.dependent == "changed", "parent switch enables actual editing")
end
do
	local s = state(); change(s, "choice", "b"); check(s.values.choice == "a", "conditional option is disabled until prerequisite")
	change(s, "enabled", true); change(s, "choice", "b"); check(s.values.choice == "b", "native dropdown commits enabled option")
	change(s, "agents:option:1", true); check(s.values.agents[1] == "agent", "checklist toggles a captured choice")
	change(s, "agents:option:1", false); check(#s.values.agents == 0, "checklist supports clearing every choice")
end
do
	local s = state(); check(not contains(def.view(s, {}).main, "retained"), "collapsed group hides editable descendants")
	action(s, "form-group", "advanced"); check(contains(def.view(s, {}).main, "retained"), "native disclosure opens retained content")
	action(s, "form-action", "save"); check(s.result.phase == "submitted" and s.result.values.text == "A😀雪Z", "save publishes complete values once")
	ack(s, { errors = { text = "Invalid combination" }, notice = "Refused" })
	check(s.result == nil and s.values.text == "A😀雪Z" and s.errors.text ~= nil, "refusal acknowledges without discarding draft or field errors")
	action(s, "form-action", "nav"); check(s.result.phase == "action" and s.result.values == nil, "non-submit navigation publishes no full payload")
	ack(s, {}); action(s, "form-cancel"); check(s.result.phase == "cancelled" and s.result.values == nil, "cancel carries no full payload")
end
do
	local s = state(); action(s, "form-browse", "path")
	check(s.browser and #s.browser.rows == 128 and s.browser.clipped, "host browser bounds rendered entries")
	local n = #listed; action(s, "form-browse", "desktop")
	check(#listed == n and s.result.phase == "browse" and s.result.path == "/desktop", "desktop Browse dispatches its current path without reading host files")
	ack(s, { busy = true }); edit(s, "text", 0, 1, "x"); check(s.values.text == "A😀雪Z", "pending save disables edits")
end
do
	local s = state(); local cx = focus(s, "text")
	check(cx.frames[1][1][1] == "focus" and cx.frames[1][1][2] == "main.row:text.field:text" and s.cursors.text == 5,
		"clicking an editable field emits native caret focus at its UTF16 end")
	key(s, cx, "left"); key(s, cx, "left"); key(s, cx, "left")
	check(s.cursors.text == 1, "ordinary arrows cross a supplementary character without splitting its UTF16 pair")
	key(s, cx, "right"); key(s, cx, "paste", "Ω🚀")
	check(s.values.text == "A😀Ω🚀雪Z" and s.cursors.text == 6, "paste inserts at the focused UTF16 caret rather than at a byte offset")
	key(s, cx, "backspace"); key(s, cx, "delete")
	check(s.values.text == "A😀ΩZ" and s.cursors.text == 4, "ordinary Backspace and Delete remove whole supplementary or multibyte characters")
	event(s, { ev = "undo", id = "main.field:text" })
	check(s.values.text == "A😀Ω雪Z" and s.cursors.text == 4, "native Undo restores a keyboard deletion and its caret")
	def.key(s, { name = "z", ctrl = true }, cx)
	check(s.values.text == "A😀Ω🚀雪Z" and s.cursors.text == 6, "keyboard undo uses the same retained edit history")
	key(s, cx, "end"); key(s, cx, "enter"); key(s, cx, "paste", "雪")
	check(s.values.text == "A😀Ω🚀雪Z\n雪" and s.cursors.text == 10, "multiline editor accepts Enter and pasted non-ASCII text")
	key(s, cx, "home"); check(s.cursors.text == 9, "Home moves to the current editor line's start")
	key(s, cx, "end"); check(s.cursors.text == 10, "End moves to the current editor line's end")
	key(s, cx, "escape"); check(s.focus == nil and not key(s, cx, "a", "a"), "Escape releases keyboard ownership without changing the draft")
end
do
	for _, guard in { "busy", "closed", "needs_resume", "submitted", "readonly", "hidden", "collapsed", "disabled" } do
		local s = state(); local cx = focus(s, "text"); key(s, cx, "a", "a")
		def.key(s, { name = "a", ctrl = true }, cx)
		if guard == "submitted" then action(s, "form-action", "save")
		elseif guard == "readonly" then s.spec.fields[1].readonly = true
		elseif guard == "hidden" then s.spec.fields[1].visible_when = "enabled"
		elseif guard == "collapsed" then s.spec.fields[1].group = "advanced"
		elseif guard == "disabled" then s.spec.fields[1].enabled_by = "enabled"
		else s[guard] = true end
		local before, cursor, anchor = s.values.text, s.cursors.text, s.anchors.text
		check(not key(s, cx, "paste", "lost") and not def.key(s, { name = "a", ctrl = true }, cx)
			and not def.key(s, { name = "left", shift = true }, cx)
			and s.values.text == before and s.cursors.text == cursor and s.anchors.text == anchor,
			guard .. " field cannot accept keys or selection through retained focus")
		event(s, { ev = "undo", id = "main.field:text" }); edit(s, "text", 0, units(before), "lost")
		check(s.values.text == before and s.cursors.text == cursor, guard .. " field rejects stale native edit and undo events as well")
		local refused = focus(s, "text"); check(#refused.frames == 0, guard .. " field cannot reacquire native editing focus")
	end
	local s = state(); local cx = focus(s, "text"); ack(s, { busy = true })
	ack(s, { errors = { text = "Review" }, notice = "Refused" }); key(s, cx, "paste", " retained")
	check(s.values.text == "A😀雪Z retained" and s.errors.text == "Review", "refusal unlocks keyboard editing without discarding the draft or errors")
	local replacement = spec(); replacement.form_nonce = "new"; replacement.request_id = "new"
	action(s, "form-open", runtime.json.encode(replacement))
	check(s.focus == nil and not key(s, cx, "a", "a") and s.values.text == "A😀雪Z", "reusing a pane cannot type into a replacement form through its predecessor's focus")
end
do
	local s = state(); local cx = focus(s, "desktop")
	check(not key(s, cx, "enter") and s.result == nil and s.values.desktop == "/desktop", "Enter in a one-line input neither inserts a newline nor silently submits")
	key(s, cx, "home"); key(s, cx, "X", "X"); key(s, cx, "right"); key(s, cx, "delete")
	check(s.values.desktop == "X/esktop" and s.cursors.desktop == 2, "ordinary typed text and caret navigation edit a one-line path")
	local invalid = string.char(255); local before = s.values.desktop
	check(not key(s, cx, "paste", invalid) and s.values.desktop == before, "invalid UTF8 paste cannot corrupt a retained field")
	s.values.desktop = string.rep("x", 65536); s.cursors.desktop = 65536
	check(not key(s, cx, "paste", "a") and #s.values.desktop == 65536, "keyboard paste respects the same per-field byte bound as native selection edits")
	key(s, cx, "backspace"); key(s, cx, "a", "a")
	check(#s.values.desktop == 65536 and s.values.desktop:sub(-1) == "a", "deletion releases capacity for a deliberate keyboard replacement")
end
do
	for _, modifier in { "ctrl", "meta" } do
		local s = state(); local cx = focus(s, "text")
		local select_all = { name = "a" }; select_all[modifier] = true
		check(def.key(s, select_all, cx), modifier .. "+A selects the focused field without native composer editing")
		local rendered = find_node(def.view(s, {}).main, function(node) return node.p and node.p.key == "field:text" end)
		check(rendered.p.anchor == 0 and rendered.p.cursor == 5 and s.values.text == "A😀雪Z", "fallback select-all draws its UTF16 range without changing the draft")
		key(s, cx, "paste", "Conversation desk")
		check(s.values.text == "Conversation desk" and s.cursors.text == 17 and s.anchors.text == nil, "typing or paste replaces the whole program-owned selection")
		event(s, { ev = "undo", id = "main.field:text" })
		check(s.values.text == "A😀雪Z" and s.cursors.text == 5 and s.anchors.text == 0, "undo restores the selected original draft and its caret")
		check(key(s, cx, "delete") and s.values.text == "" and s.cursors.text == 0 and s.anchors.text == nil, "Delete removes the selected range, not just the following character")
		event(s, { ev = "undo", id = "main.field:text" })
		check(key(s, cx, "backspace") and s.values.text == "" and s.cursors.text == 0, "Backspace removes the selected range, including multibyte text")
	end
end
do
	local s = state(); local cx = focus(s, "text")
	for _ = 1, 3 do def.key(s, { name = "left", shift = true }, cx) end
	check(s.anchors.text == 5 and s.cursors.text == 1, "Shift+Left extends a reversed selection across whole UTF16 characters")
	def.key(s, { name = "right", shift = true }, cx); key(s, cx, "Ω", "Ω")
	check(s.values.text == "A😀Ω" and s.cursors.text == 4 and s.anchors.text == nil, "reversing Shift navigation and typing replaces precisely the selected suffix")
	event(s, { ev = "undo", id = "main.field:text" }); key(s, cx, "right")
	check(s.cursors.text == 5 and s.anchors.text == nil, "ordinary Right collapses a reversed selection to its right edge without stepping beyond it")
	def.key(s, { name = "home", shift = true }, cx)
	check(s.anchors.text == 5 and s.cursors.text == 0, "Shift+Home extends selection to the logical line start")
	def.key(s, { name = "end", shift = true }, cx)
	check(s.cursors.text == 5 and s.anchors.text == nil, "returning Shift+End to the anchor clears an empty selection")
	def.key(s, { name = "left", shift = true }, cx); key(s, cx, "left")
	check(s.cursors.text == 4 and s.anchors.text == nil, "ordinary Left collapses selection to its left edge without deleting text")
end
do
	local s = state(); local cx = focus(s, "text"); def.key(s, { name = "a", ctrl = true }, cx)
	edit(s, "text", 1, 3, "Ω"); key(s, cx, "x", "x")
	check(s.values.text == "AΩx雪Z" and s.anchors.text == nil, "a native selection edit replaces program-owned selection state before subsequent typing")
	def.key(s, { name = "a", ctrl = true }, cx); focus(s, "text")
	check(s.anchors.text == nil, "a fresh native focus clears program-owned selection")
	def.key(s, { name = "a", ctrl = true }, cx)
	local restored = def.init({}, {}, def.save(s))
	check(restored.values.text == s.values.text and restored.anchors.text == nil and restored.focus == nil,
		"draft restoration keeps entered text but never restores an actionable keyboard selection")
	s.values.text = string.rep("x", 65536); s.cursors.text = 65536; s.anchors.text = nil
	def.key(s, { name = "a", ctrl = true }, cx); key(s, cx, "paste", "雪")
	check(s.values.text == "雪" and s.cursors.text == 1 and s.anchors.text == nil, "replacing a full-size selected field subtracts selected bytes before applying the bound")
end
local function fixture(ids)
	local source, form = if ids then ids.source else 9, if ids then ids.form else 20
	local f = { source = source, form = form, panes = { [source] = { pane = source, tab = 1, block = "orchplus.orchestrator" } },
		hidden = {}, membership = { [1] = 3, [2] = 3, [3] = 4 }, connected = true, source_current = true,
		session_id = 3, host_id = 2, window = "window", count = 0, serial = 0 }
	local cx = { session = {}, hosts = {}, sessions = {}, layout = {} }; f.cx = cx
	function cx.session:pane(id) return f.panes[id] end
	function cx.session:view(id) return if f.panes[id] and not f.hidden[id] then {} else nil end
	function cx.session:event(id, ev) if id == form then event(f.state, ev) end end
	function cx.hosts:current() return { id = f.host_id, state = if f.connected then "connected" else "reconnecting" } end
	function cx.sessions:current() return { id = f.session_id } end
	function cx:window_key() return f.window end
	function cx:toast() end
	function cx.layout:focus(id) f.focus = id end
	function cx.layout:close(id) check(id == form, "only the owned form pane closes"); f.closed = (f.closed or 0) + 1; f.panes[id] = nil end
	function cx:new_block(kind, args, how, opts)
		check(kind == "orchplus.form" and how == "beside" and opts.target == source, "pane creation anchors to the unchanged native source id")
		f.count += 1; f.panes[form] = { pane = form, tab = 1, block = kind }; f.state = def.init({}, args, nil); return form
	end
	f.forms = adapter.new({ id = function() f.serial += 1; return "id-" .. f.serial end,
		host = function(_, id) return if f.panes[id] then { id = f.panes[id].host or 2, state = if f.connected then "connected" else "reconnecting" } else nil end,
		membership = function() return f.membership end, same = same, current = function() return f.source_current end,
		surface = function(_, id, block, role, key)
			check(id == form and block == "orchplus.form" and role == "orchplus.form.result" and key == "form-result", "receipt reads the exact native form, never its source or a guessed pane")
			if f.unreadable then return nil, nil end
			local node, native_id = find_node(def.view(f.state, {}).main, function(n) return n.p and n.p.role == role end)
			check(node == nil or native_id == "main.form-result", "receipt is a direct keyed child of the native main region")
			return node, span_text(node)
		end })
	return f
end
do
	local f = fixture()
	f.forms.open(f.cx, 9, nil, { title = "Agent selector", description = "Pending", fields = {}, tag = "picker" }, function() end)
	local nonce, request = f.state.spec.form_nonce, f.state.spec.request_id
	f.hidden[9] = true
	check(f.forms.update(f.cx, 9, { description = "Connection unavailable", description_tone = "error", busy = false }),
		"an owned selector can finish its loading state while the source tab is unmounted")
	event(f.state, { ev = "action", act = "form-ack", value = runtime.json.encode({
		form_nonce = nonce, request_id = request, description = "Pending", description_tone = "info", busy = true }) })
	local tree = def.view(f.state, {}).main
	local problem = find_node(tree, function(node) return span_text(node) == "Connection unavailable" end)
	check(f.count == 1 and f.state.spec.form_nonce == nonce and problem and problem.p.spans[1].s == "error"
		and not f.state.busy and find_node(tree, function(node) return span_text(node) == "Pending" end) == nil,
		"a stale loading ACK cannot rewind the same selector's rendered failure or lock its Close control")
	action(f.state, "form-cancel"); f.forms.tick(f.cx)
	check(not f.forms.active(9) and f.closed == 1, "the failed selector closes once without another source action")
end
do
	local f = fixture(); local results = {}; local original = { { label = "One", id = "one" }, { label = "Two", id = "two" } }
	f.forms.choose(f.cx, 9, nil, { items = original }, function(_, row) table.insert(results, row) end)
	event(f.state, { ev = "select", id = "main.field:choice", item = "main.choice:choice:2" }); f.forms.tick(f.cx); f.forms.tick(f.cx)
	check(#results == 1 and results[1] == original[2], "selection resolves captured index to original record exactly once")
	f.forms.input(f.cx, 9, nil, { value = "draft" }, function(_, text) table.insert(results, text) end)
	check(f.count == 2, "a completed terminal choice closes before a later unrelated input opens")
	edit(f.state, "text", 0, 5, "retained"); action(f.state, "form-action", "submit")
	f.session_id = 4; f.forms.tick(f.cx)
	check(#results == 1 and f.state.result == nil and not f.state.busy and f.state.values.text == "retained" and f.state.notice ~= nil,
		"source session change explicitly refuses and unlocks a retained draft without consuming input")
	f.session_id = 3; action(f.state, "form-action", "submit"); f.state.result.form_nonce = "foreign"; f.forms.tick(f.cx)
	check(#results == 1, "foreign nonce cannot settle a retained request")
end
do
	local f = fixture(); local count = 0
	local spec_value = spec()
	f.forms.open(f.cx, 9, nil, spec_value, function(cx)
		count += 1; f.forms.update(cx, 9, { notice = "Refused; keep editing." })
	end)
	action(f.state, "form-action", "save")
	local old = runtime.json.encode(f.state.result)
	f.forms.tick(f.cx); check(count == 1 and f.state.result == nil, "ACK reopens editable form")
	-- Emulate one old native surface crossing the outbound ACK, not an echoed result.
	local stale = runtime.json.decode(old); f.state.result = stale
	f.forms.tick(f.cx); check(count == 1, "rotated request id rejects an acknowledged result while ACK is in flight")
	f.state.result = nil; action(f.state, "form-action", "save"); f.forms.tick(f.cx)
	check(count == 2, "a deliberate new submission uses the rotated request binding")
end
do
	local f = fixture(); local received = 0
	f.forms.choose(f.cx, 9, nil, { tag = "gate", retain = true, items = { { label = "Continue" } } }, function() end)
	f.panes[20].tab = 2
	f.forms.open(f.cx, 9, nil, spec(), function(cx)
		received += 1; f.forms.update(cx, 9, { notice = "Refused; keep editing." })
	end)
	f.hidden[9] = true
	check(f.count == 1 and f.cx.session:view(9) == nil, "reused form occupies another tab while the native source is unmounted")
	action(f.state, "form-action", "save"); local submitted = runtime.json.encode(f.state.result)
	f.forms.tick(f.cx)
	check(received == 1 and f.state.result == nil and not f.state.busy, "same-session form submission is acknowledged without a mounted source accessibility view")
	f.state.result = runtime.json.decode(submitted); f.forms.tick(f.cx)
	check(received == 1, "cross-tab acknowledgement still fences a delayed duplicate submission")
	f.state.result = nil; edit(f.state, "text", 0, 5, "Retained"); action(f.state, "form-action", "save"); f.forms.tick(f.cx)
	check(received == 2 and f.state.values.text == "Retained" and f.state.result == nil, "cross-tab refusal leaves the original draft usable for a new deliberate save")
end
do
	local f = fixture(); local result
	f.forms.input(f.cx, 9, nil, { value = "", validate = function(text) return if text:match("%S") then nil else "A name is required." end },
		function(_, text) result = text end)
	action(f.state, "form-action", "submit"); f.forms.tick(f.cx)
	check(result == nil and f.state.errors.text ~= nil and f.forms.active(9), "invalid naming input retains its editor, errors and callback")
	local cx = focus(f.state, "text")
	for letter in ("Project"):gmatch(".") do key(f.state, cx, letter:lower(), letter) end
	check(f.state.values.text == "Project", "ordinary native typing updates the actual naming form before submission")
	action(f.state, "form-action", "submit"); f.forms.tick(f.cx)
	check(result == "Project" and not f.forms.active(9), "corrected input settles once and closes editing")
end
do
	local f = fixture(); local result
	f.forms.input(f.cx, 9, nil, { value = "ORCH+ / orchestration #1" }, function(_, text) result = text end)
	local cx = focus(f.state, "text"); def.key(f.state, { name = "a", ctrl = true }, cx)
	for letter in ("Conversation desk"):gmatch(".") do key(f.state, cx, letter:lower(), letter) end
	check(f.state.values.text == "Conversation desk", "select-all and ordinary typing replace a prefilled orchestration name rather than appending")
	action(f.state, "form-action", "submit"); f.forms.tick(f.cx)
	check(result == "Conversation desk" and not f.forms.active(9), "the naming consumer receives exactly the selected replacement name")
end
do
	local s = state()
	event(s, { ev = "edit", id = "main.field:text", ["from"] = 1, to = 3, len = 4, cursor = 0, text = "Ω" })
	check(s.values.text == "A😀雪Z", "stale edit length cannot corrupt a newer draft")
	event(s, { ev = "edit", id = "main.field:text", ["from"] = 1, to = 3, len = 5, cursor = 0, text = "Ω" })
	check(s.values.text == "AΩ雪Z" and s.cursors.text == 0, "valid edit honors supplied UTF16 caret instead of assuming insertion end")
	event(s, { ev = "edit", id = "main.field:text", ["from"] = 0, to = 0, len = 4, cursor = 2, text = "😀" })
	check(s.values.text == "😀AΩ雪Z" and s.cursors.text == 2, "supplementary input uses UTF16 caret boundaries")
	local large = string.rep("a", 65530); s.values.text = large
	edit(s, "text", 0, 65530, string.rep("b", 65530))
	check(s.values.text == string.rep("b", 65530), "full replacement near byte cap subtracts replaced bytes before checking limit")
end
do
	local s = state(); edit(s, "text", 0, 5, "Draft 😀")
	ack(s, { errors = { text = "Review this value" }, notice = "Refused" })
	local saved = def.save(s); local restored = def.init({}, {}, saved)
	check(restored.values.text == "Draft 😀" and restored.errors.text == "Review this value"
		and restored.spec.form_nonce == s.spec.form_nonce and restored.spec.request_id == s.spec.request_id,
		"host reload preserves entered draft, field errors and captured request")
	action(s, "form-action", "save"); saved = def.save(s); restored = def.init({}, {}, saved)
	check(restored.values.text == "Draft 😀" and restored.result == nil and not restored.busy,
		"restoring a submitted form never republishes its submitted values or repeats a write")
end
do
	local f = fixture(); local selected
	local options = { { label = "Unavailable", disabled = "Account setup required", icon = "provider-openai" }, { label = "Ready", id = "ready", detail = "Current account", icon = "provider-anthropic" } }
	f.forms.choose(f.cx, 9, nil, { items = options }, function(_, row) selected = row end)
	event(f.state, { ev = "select", id = "main.field:choice", item = "main.choice:choice:1" }); f.forms.tick(f.cx)
	check(selected == nil and f.state.result == nil, "disabled chooser row cannot submit")
	event(f.state, { ev = "select", id = "main.field:choice", item = "main.choice:choice:2" }); f.forms.tick(f.cx)
	check(selected == options[2], "one native row click submits its retained original choice without confirmation")
end
do
	local f = fixture(); local callback_owned, answer
	f.forms.input(f.cx, 9, nil, { tag = "back", value = "retained" }, function(_, value)
		callback_owned = f.forms.active(9, "back"); answer = value
	end)
	action(f.state, "form-cancel"); f.forms.tick(f.cx)
	check(callback_owned and answer == nil and not f.forms.active(9) and f.panes[20] == nil and f.focus == 9,
		"Back delivers while owned, then closes the form and returns source focus")
	check(f.state.closed and f.state.result == nil, "cancelled host state is settled, not an enabled orphan editor")
end
do
	local f = fixture(); local old_result, second
	f.forms.choose(f.cx, 9, nil, { tag = "first", items = { { label = "Next" } } }, function(cx, choice)
		check(choice ~= nil and f.forms.active(9, "first"), "selected callback retains legitimate form ownership")
		f.forms.input(cx, 9, nil, { tag = "second", value = "draft" }, function(_, text) second = text end)
	end)
	event(f.state, { ev = "select", id = "main.field:choice", item = "main.choice:choice:1" })
	old_result = runtime.json.decode(runtime.json.encode(f.state.result)); f.forms.tick(f.cx)
	check(f.count == 1 and f.forms.active(9, "second") and not f.closed and not f.state.closed,
		"immediate submenu reuses the existing pane and survives cleanup of its predecessor")
	f.state.result = old_result; f.forms.tick(f.cx); check(second == nil, "delayed predecessor result cannot settle replacement input")
	f.state.result = nil; action(f.state, "form-action", "submit"); f.forms.tick(f.cx)
	check(second == "draft" and f.closed == 1 and not f.forms.active(9), "successful terminal submenu closes its owned pane")
end
do
	local f = fixture(); local selected, cancelled = 0, false
	f.forms.choose(f.cx, 9, nil, { tag = "async", retain = true, items = { { label = "Agent" } } }, function(_, row)
		if row then selected += 1 else cancelled = true end
	end)
	event(f.state, { ev = "select", id = "main.field:choice", item = "main.choice:choice:1" })
	local delayed = runtime.json.decode(runtime.json.encode(f.state.result)); f.forms.tick(f.cx)
	check(selected == 1 and f.forms.active(9, "async") and f.state.busy and not f.closed, "async catalog owner retains a disabled live pane")
	f.state.result = delayed; f.forms.tick(f.cx); check(selected == 1, "delayed selected snapshot cannot repeat an async callback")
	f.state.result = nil; action(f.state, "form-cancel"); f.forms.tick(f.cx)
	check(cancelled and not f.forms.active(9) and f.closed == 1, "Back cancels retained async ownership and closes its pane")
end
do
	local s = state()
	check(click_action(s, "form-group=advanced") and not s.collapsed.advanced, "rendered disclosure click opens its native group")
	check(click_action(s, "form-browse=path") and s.browser.path == "/host", "rendered Browse button invokes execution-host navigation")
	check(click_action(s, "form-file=1") and s.values.path == "/host/entry-1" and s.browser == nil, "rendered browser entry selects an actual returned file path")
	s.values.path = "/host"; check(click_action(s, "form-browse=path"), "browser can be reopened from its rendered action")
	check(click_action(s, "form-parent") and s.errors.path ~= nil, "rendered parent-folder action retains a genuine listing refusal")
	check(click_action(s, "form-use-folder") and s.browser == nil and s.values.path == "/host", "rendered folder-selection action commits the browsed folder")
	check(click_action(s, "form-action=save") and s.result.phase == "submitted", "rendered Save action submits the complete form")
end
do
	local s = state(); edit(s, "text", 0, 5, "Retained draft")
	local restored = def.init({}, {}, def.save(s)); local exited
	check(restored.needs_resume and not click_action(restored, "form-action=save"), "restored orphan has disabled Save until a real window reconnects")
	edit(restored, "text", 0, 14, "lost"); check(restored.values.text == "Retained draft", "disconnected restored fields remain retained and noninteractive")
	check(click_action(restored, "form-cancel", { exit = function(_, code) exited = code end })
		and exited == 0 and restored.closed and restored.result == nil, "orphan Back settles and exits the host block without a missing window consumer")
end
do
	local f = fixture(); local received = 0
	f.forms.open(f.cx, 9, nil, spec(), function() received += 1 end)
	edit(f.state, "text", 0, 5, "Retained")
	f.forms.update(f.cx, 9, { errors = { text = "Review retained value" } })
	f.state = def.init({}, {}, def.save(f.state)); f.forms.tick(f.cx)
	check(not f.state.needs_resume and f.state.values.text == "Retained" and f.state.errors.text ~= nil and received == 0,
		"retained matching window resumes a restored draft without replacing values/errors or replaying a result")
	check(click_action(f.state, "form-action=save"), "reconnected form permits a deliberate new native submission")
	f.forms.tick(f.cx); check(received == 1, "only the deliberate post-reconnect submission reaches its consumer")
end
do
	local f = fixture(); local selected
	local row = { choice_key = "record:one", label = "Agent", detail = "Observed recently", id = "one" }
	f.forms.choose(f.cx, 9, nil, { tag = "refresh", retain = true, items = { row } }, function(_, choice) selected = choice end)
	local request, nonce, focus = f.state.spec.request_id, f.state.spec.form_nonce, f.focus
	check(f.forms.update(f.cx, 9, { choices = { { choice_key = "record:one", label = "Agent", detail = "Updated evidence age" } } }),
		"stable cosmetic rows refresh through native events")
	check(f.state.spec.request_id == request and f.state.spec.form_nonce == nonce and f.focus == focus and f.count == 1,
		"cosmetic update neither resets correlation nor reopens or focuses the pane")
	event(f.state, { ev = "select", id = "main.field:choice", item = "main.choice:choice:1" })
	local result = f.state.result
	check(f.forms.update(f.cx, 9, { choices = { { choice_key = "record:one", label = "Agent", detail = "Another age update" } } })
		and f.state.result == result, "host cosmetic refresh preserves a row click already in flight")
	check(not f.forms.update(f.cx, 9, { choices = { { choice_key = "record:other", label = "Other" } } }), "different choice identity cannot reuse a captured row index")
	f.forms.tick(f.cx); check(selected == row and f.forms.active(9, "refresh"), "preserved in-flight click resolves to its original captured choice")
	f.forms.cancel(f.cx, 9)
end
do
	local f = fixture(); local received = 0
	f.forms.input(f.cx, 9, nil, { value = "Retained" }, function() received += 1 end)
	f.panes[9] = nil; action(f.state, "form-action", "submit"); f.forms.tick(f.cx)
	check(received == 0 and f.forms.active(9) and f.state.result == nil and f.state.values.text == "Retained" and f.state.notice ~= nil,
		"removed source refuses Save explicitly while retaining and unlocking the exact draft")
	action(f.state, "form-cancel"); f.forms.tick(f.cx)
	check(not f.forms.active(9) and f.panes[20] == nil and f.state.closed and received == 0,
		"Close exits the owned draft without invoking a stale source consumer")
end
do
	local f = fixture(); local received, values = 0, nil
	local draft = spec(); draft.fields = {}
	for i = 1, 96 do table.insert(draft.fields, { id = "entry_" .. i, kind = "text", label = "Entry " .. i, value = "retained-" .. i }) end
	draft.fields[1].value = string.rep("λ", 20000)
	f.forms.open(f.cx, 9, nil, draft, function(cx, submitted)
		received += 1; values = submitted; f.forms.update(cx, 9, { notice = "Received; keep editing." })
	end)
	check(action(f.state, "form-action", "save"), "native form can submit a complete large draft")
	f.forms.tick(f.cx); f.forms.tick(f.cx)
	check(received == 1 and values.entry_96 == "retained-96" and values.entry_1 == draft.fields[1].value,
		"native draft transport preserves many fields and long text without applying report decoder limits")
	check(f.state.result == nil and not f.state.busy and f.state.values.entry_96 == "retained-96",
		"large draft acknowledgement keeps the same editor usable and does not duplicate delivery")
end
do
	local f = fixture(); local writes = 0
	f.forms.open(f.cx, 9, nil, spec(), function() writes += 1 end)
	action(f.state, "form-action", "save")
	check(not click_action(f.state, "form-action=save"), "an outstanding receipt disables duplicate Save")
	f.source_current = false
	check(click_action(f.state, "form-cancel") and f.state.result.phase == "cancelled", "Close supersedes an unread Save receipt")
	f.forms.tick(f.cx)
	check(writes == 0 and f.closed == 1 and not f.forms.active(9), "source ownership change cannot trap Close or dispatch the superseded Save")
end
do
	local f = fixture(); local writes = 0
	f.forms.open(f.cx, 9, nil, spec(), function() writes += 1 end)
	action(f.state, "form-action", "save"); f.forms.tick(f.cx); f.forms.tick(f.cx)
	check(writes == 1 and f.state.result ~= nil, "an unacknowledged consumer receives Save only once")
	f.connected = false; action(f.state, "form-cancel"); f.forms.tick(f.cx)
	check(writes == 1 and f.closed == 1, "Close can settle its exact local carrier after host readiness changes without replaying an issued write")
end
do
	local f = fixture()
	f.forms.open(f.cx, 9, nil, spec(), function() end)
	f.state.spec.form_nonce = "replacement-draft"; action(f.state, "form-cancel"); f.forms.tick(f.cx); f.forms.cancel(f.cx, 9)
	check(not f.closed and f.forms.active(9), "neither Close receipt nor programmatic cancellation closes a foreign live draft")
	f.forms.open(f.cx, 9, nil, spec(), function() end)
	f.panes[20].host = 7; action(f.state, "form-cancel"); f.forms.tick(f.cx)
	check(not f.closed, "a matching draft nonce cannot close a carrier moved onto another host")
	f.panes[20].host = nil; f.forms.tick(f.cx)
	check(f.closed == 1, "the unchanged native form closes once its own host binding is verified again")
end
do
	local f = fixture({ source = 4503599627370537, form = 4503599627370540 }); local saves = 0
	f.forms.open(f.cx, f.source, nil, spec(), function(cx)
		saves += 1; f.forms.update(cx, f.source, { errors = { text = "Retained refusal" } })
	end)
	action(f.state, "form-action", "save"); f.forms.tick(f.cx); f.forms.tick(f.cx)
	change(f.state, "enabled", true); change(f.state, "enabled", false); change(f.state, "enabled", true)
	check(saves == 1 and f.state.result == nil and f.state.values.enabled and f.state.errors.text ~= nil,
		"large exact Lua remote ids survive refusal ACK and a real off-on-off-on switch path")
	action(f.state, "form-cancel"); f.forms.tick(f.cx)
	check(f.closed == 1 and f.panes[f.source] ~= nil, "Close preserves its high-id source and removes only its distinct high-id form")
end
do
	local f = fixture(); local received = 0
	f.forms.open(f.cx, 9, nil, spec(), function() received += 1 end)
	edit(f.state, "text", 0, 5, "Retained draft")
	local host_reads, window_reads = #listed, #window_listed
	check(click_action(f.state, "form-browse=desktop"), "rendered desktop Browse dispatches without submitting settings")
	local stale = runtime.json.decode(runtime.json.encode(f.state.result)); f.forms.tick(f.cx)
	check(f.state.browser.scope == "desktop" and f.state.browser.path == "/desktop" and #listed == host_reads and #window_listed == window_reads + 1,
		"desktop Browse returns a native inline chooser from only the window filesystem")
	local row = find_node(def.view(f.state, {}).main, function(node) return node.p and node.p.key == "row:desktop" end)
	check(find_node(row, function(node) return node.p and node.p.key == "browser:desktop" end) ~= nil,
		"Browse renders its chooser inside the clicked path field rather than offscreen at the end of settings")
	check(click_action(f.state, "form-file=1"), "window-computer file row dispatches its selected entry")
	f.forms.tick(f.cx)
	check(f.state.values.desktop == "/desktop/window-file.md" and f.state.values.text == "Retained draft" and f.state.browser == nil and received == 0,
		"native desktop Browse roundtrip changes only its field and never invokes the save consumer")
	f.state.result = stale; f.forms.tick(f.cx)
	check(f.state.values.desktop == "/desktop/window-file.md" and #window_listed == window_reads + 2, "a delayed Browse receipt cannot replay listing or change the chosen path")
	f.state.result = nil
	check(click_action(f.state, "form-browse=desktop"), "Browse accepts an existing selected file as its starting location")
	f.forms.tick(f.cx)
	check(f.state.browser.path == "/desktop" and #listed == host_reads, "a file starting location opens its own window-computer parent, never the host")
	check(click_action(f.state, "form-browse-cancel") and f.state.browser == nil, "Cancel browse retains the selected field and restores the same draft")
end
do
	local draft = spec(); draft.groups = { { id = "advanced", label = "Danger", tone = "error", separator_after = true } }
	table.insert(draft.fields, { id = "intro", kind = "note", group = "advanced", value = "Available", tone = "success", strong = true, space_before = true })
	draft.actions = { { id = "first", label = "First", after_field = "intro", group = "advanced" },
		{ id = "second", label = "Second", after_field = "intro", group = "advanced" } }
	local s = def.init({}, { runtime.json.encode(draft) }, nil); local tree = def.view(s, {}).main
	local group = find_node(tree, function(node) return node.p and node.p.key == "group:advanced" end)
	local positions = {}; for i, child in group.c do if child.p and child.p.key then positions[child.p.key] = i end end
	local note = find_node(group, function(node) return span_text(node) == "Available" end)
	local danger = find_node(group, function(node) return span_text(node) == "Danger" end)
	check(positions["action:first"] == positions["row:intro"] + 1 and positions["action:second"] == positions["row:intro"] + 2
		and group.c[positions["row:intro"] - 1].k == "spacer" and note.p.spans[1].s == "strong success"
		and danger.p.spans[1].s == "error" and find_node(tree, function(node) return node.k == "rule" end) ~= nil,
		"native presentation places both contextual actions immediately after their field, with native spacing, semantic styles and divider")
	check(click_action(s, "form-action=first") and s.result.action == "first", "a contextual action uses the ordinary once-only nonce receipt path")
end
do
	local draft = spec()
	draft.groups = { { id = "outer", label = "Outer", collapsed = true }, { id = "inner", label = "Inner", parent = "outer", collapsed = true } }
	draft.fields[1].group = "inner"
	table.insert(draft.fields, { id = "formula", label = "Formula", kind = "math", value = "x\\geq y", copyable = true })
	local s = def.init({}, { runtime.json.encode(draft) }, nil)
	ack(s, { errors = { text = "Correct this value" }, notice = "Refused" })
	local tree = def.view(s, {}).main
	local row = find_node(tree, function(node) return node.p and node.p.key == "row:text" end)
	check(not s.collapsed.outer and not s.collapsed.inner and row.p.error ~= nil and row.p.tone == "error"
		and s.values.text == "A😀雪Z", "error ACK exposes nested invalid controls with native error state and intact input")
	local formula = find_node(tree, function(node) return node.k == "math" end)
	check(formula and formula.p.display and formula.p.actions.menu[1].id == "copy",
		"native formula retains a real copy action without becoming an editable policy field")
	check(click_action(s, "form-action=save") and s.result.request_id == s.spec.request_id,
		"validation retains reachable save action bound to current request")
end
for _, drop_ack in { false, true } do
	local f = fixture(); local writes, outgoing = 0, {}
	function f.cx.session:event(id, ev)
		check(id == f.form, "queued ACK retains the exact native form id"); table.insert(outgoing, ev)
	end
	f.forms.open(f.cx, 9, nil, spec(), function(cx, _, chosen)
		if chosen == "save" then writes += 1; f.forms.update(cx, 9, { busy = true, notice = "Waiting for save receipt." })
		else f.forms.cancel(cx, 9) end
	end)
	action(f.state, "form-action", "save"); f.forms.tick(f.cx)
	check(writes == 1 and #outgoing == 1, "Save is delivered once while its request-rotating ACK is still in transit")
	action(f.state, "form-cancel")
	local cancellation = runtime.json.decode(runtime.json.encode(f.state.result))
	f.state.result.form_nonce = "foreign"; f.forms.tick(f.cx)
	check(not f.closed and writes == 1 and f.forms.active(9), "an obsolete request id does not let a foreign nonce cancel the owned draft")
	f.state.result = cancellation
	if drop_ack then table.remove(outgoing, 1) end
	f.forms.tick(f.cx)
	check(f.closed == 1 and writes == 1 and not f.forms.active(9),
		"verified draft Close wins despite an obsolete request id, whether the rotating ACK is delayed or permanently lost")
	while #outgoing > 0 do event(f.state, table.remove(outgoing, 1)) end
	f.forms.tick(f.cx)
	check(f.state.closed and f.closed == 1 and writes == 1
		and find_node(def.view(f.state, {}).main, function(node) return node.k == "input" or node.k == "switch" end) == nil,
		"late ACK delivery neither reopens the closed editor nor replays its already-delivered Save")
	if drop_ack then check(f.state.result == nil, "with the rotating ACK lost, the final Close ACK settles the original host request") end
end
do
	local s = state(); action(s, "form-action", "save"); action(s, "form-cancel")
	check(s.closed and s.result.phase == "cancelled" and find_node(def.view(s, {}).main, function(node) return node.k == "input" or node.k == "switch" end) == nil,
		"Close ends its local editor immediately even when no window/source consumer exists")
	ack(s, { busy = true, next_request_id = "late-ack" })
	check(s.closed and s.result.phase == "cancelled" and s.result.request_id == "late-ack",
		"an in-flight acknowledgement cannot reopen a locally closed draft or erase its nonce-bound cancellation")
end
return "form_ui: " .. tostring(checks) .. " checks"
