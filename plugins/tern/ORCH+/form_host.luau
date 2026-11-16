--!strict
-- UI drafts only. This block never reads or writes orchestration authority.
local M = {}
local MAX = 262144
local function clone(value: any): any
	if type(value) ~= "table" then return value end
	local out = if #value > 0 or getmetatable(value) ~= nil then tern.json.array() else {}
	for k, v in value do out[k] = clone(v) end; return out
end
local function decode(bytes: any): any?
	if type(bytes) ~= "string" or #bytes > MAX then return nil end
	local ok, value = pcall(tern.json.decode, bytes); return if ok and type(value) == "table" then value else nil
end
local function boundary(text: string, units: number): number?
	if type(units) ~= "number" or units < 0 or units % 1 ~= 0 then return nil end
	local count = 0
	for byte, code in utf8.codes(text) do
		if count == units then return byte end
		count += if code > 65535 then 2 else 1
		if count > units then return nil end
	end
	return if count == units then #text + 1 else nil
end
local function length(text: string): number
	local n = 0; for _, code in utf8.codes(text) do n += if code > 65535 then 2 else 1 end; return n
end
local function field(state: any, id: any): any?
	if type(id) ~= "string" then return nil end
	local key = id:match("field:(.+)$") or id
	for _, item in state.spec.fields or {} do if item.id == key then return item end end
	return nil
end
local function visible(state: any, item: any): boolean
	if item.hidden == true then return false end
	if type(item.visible_when) == "string" then return state.values[item.visible_when] == true end
	if type(item.visible_when) == "table" then
		return state.values[item.visible_when.id] == item.visible_when.value
	end
	return true
end
local function disabled(state: any, item: any): boolean
	return state.closed == true or state.needs_resume == true or state.busy == true or state.result ~= nil or item.disabled == true or type(item.disabled) == "string"
		or type(item.enabled_by) == "string" and state.values[item.enabled_by] ~= true
end
local function editable(state: any, item: any): boolean
	if not item or disabled(state, item) or not visible(state, item) or item.readonly == true
		or (item.kind ~= nil and item.kind ~= "text" and item.kind ~= "number" and item.kind ~= "path" and item.kind ~= "editor")
		or type(state.values[item.id]) ~= "string" then return false end
	local parent = item.group
	for _ = 1, #(state.spec.groups or {}) + 1 do
		if parent == nil then return true end
		if state.collapsed[parent] then return false end
		local found = false
		for _, group in state.spec.groups or {} do
			if group.id == parent then parent = group.parent; found = true; break end
		end
		if not found then return false end
	end
	return false
end
local function load(state: any, spec: any)
	if type(spec) ~= "table" or type(spec.form_nonce) ~= "string" or type(spec.request_id) ~= "string"
		or type(spec.fields) ~= "table" or #spec.fields > 1024 then return end
		state.disclosures = state.disclosures or {}
		if state.spec and type(state.spec.tag) == "string" then state.disclosures[state.spec.tag] = state.collapsed end
		local retained = if type(spec.tag) == "string" then state.disclosures[spec.tag] else nil
	state.spec = spec; state.values = {}; state.cursors = {}; state.anchors = {}; state.undo = {}; state.errors = spec.errors or {}
	state.collapsed = {}; state.result = nil; state.busy = false; state.closed = false; state.needs_resume = false; state.notice = spec.notice; state.notice_tone = spec.notice_tone; state.focus = nil
	state.browser = nil; state.select = nil
	for _, item in spec.fields do
		if type(item.id) == "string" then
			state.values[item.id] = if item.kind == "number" then tostring(item.value or "") else clone(item.value)
		end
	end
	for _, group in spec.groups or {} do
		state.collapsed[group.id] = if retained and retained[group.id] ~= nil then retained[group.id] else group.collapsed == true
	end
end
local function remember(state: any, id: string)
	local history = state.undo[id] or {}; state.undo[id] = history
	if #history >= 30 then table.remove(history, 1) end
	table.insert(history, { value = clone(state.values[id]), cursor = state.cursors[id], anchor = state.anchors[id] })
end
local function undo(state: any, item: any): boolean
	local history = state.undo[item.id]; local old = if history then table.remove(history) else nil
	if not old then return false end
	state.values[item.id] = old.value; state.cursors[item.id] = old.cursor; state.anchors[item.id] = old.anchor; return true
end
local function key_edit(state: any, key: any, cx: any): boolean
	local item = field(state, state.focus)
	if not editable(state, item) then return false end
	if key.name == "escape" then
		state.anchors[item.id] = nil; state.focus = nil; cx:frame({ { "focus", tern.json.null } }); return true
	end
	if (key.ctrl or key.meta) and not key.alt and not key.shift and key.name == "z" then return undo(state, item) end
	local text = state.values[item.id]
	local cursor = state.cursors[item.id] or length(text)
	local byte = boundary(text, cursor); if not byte then return false end
	local anchor = state.anchors[item.id]
	local anchor_byte = if anchor ~= nil then boundary(text, anchor) else byte
	if not anchor_byte then return false end
	if (key.ctrl or key.meta) and not key.alt and not key.shift and key.name == "a" then
		local last = length(text); local first = if last > 0 then 0 else nil
		if anchor == first and cursor == last then return false end
		state.anchors[item.id] = first; state.cursors[item.id] = last; return true
	end
	if key.ctrl or key.alt or key.meta then return false end
	local selected = anchor ~= nil and anchor ~= cursor
	local navigation = key.name == "left" or key.name == "right" or key.name == "home" or key.name == "end"
	if navigation then
		local target = cursor
		if selected and not key.shift and (key.name == "left" or key.name == "right") then
			target = if key.name == "left" then math.min(anchor, cursor) else math.max(anchor, cursor)
		elseif key.name == "left" and byte > 1 then
			local previous = utf8.offset(text, -1, byte)
			if previous then target -= if utf8.codepoint(text, previous) > 65535 then 2 else 1 end
		elseif key.name == "right" and byte <= #text then
			target += if utf8.codepoint(text, byte) > 65535 then 2 else 1
		elseif key.name == "home" or key.name == "end" then
			local target_byte = if key.name == "home" then (text:sub(1, byte - 1):match(".*\n()") or 1) else (text:find("\n", byte, true) or #text + 1)
			target = length(text:sub(1, target_byte - 1))
		end
		local next_anchor = if key.shift then anchor or cursor else nil
		if next_anchor == target then next_anchor = nil end
		if target == cursor and next_anchor == anchor then return false end
		state.cursors[item.id] = target; state.anchors[item.id] = next_anchor; return true
	end
	if key.shift and key.text == nil then return false end
	local from, to = math.min(byte, anchor_byte), math.max(byte, anchor_byte)
	local inserted, next_cursor = "", if selected then math.min(anchor, cursor) else cursor
	if key.name == "backspace" then
		if not selected then
			if byte == 1 then return false end
			local previous = utf8.offset(text, -1, byte); if not previous then return false end
			from = previous; next_cursor -= if utf8.codepoint(text, previous) > 65535 then 2 else 1
		end
	elseif key.name == "delete" then
		if not selected then
			if byte > #text then return false end
			to = utf8.offset(text, 2, byte) or #text + 1
		end
	elseif key.name == "enter" then
		if item.kind ~= "editor" then return false end
		inserted = "\n"; next_cursor += 1
	elseif type(key.text) == "string" and key.text ~= "" then
		if utf8.len(key.text) == nil then return false end
		inserted = key.text; next_cursor += length(inserted)
	else return false end
	if #text - (to - from) + #inserted > 65536 then return false end
	remember(state, item.id)
	state.values[item.id] = text:sub(1, from - 1) .. inserted .. text:sub(to)
	state.cursors[item.id] = next_cursor; state.anchors[item.id] = nil; return true
end
local function publish(state: any, action: string, phase: string, values: boolean, field_id: string?, path: string?, browse_mode: string?)
	-- Closing a draft supersedes an unacknowledged UI receipt, not an issued write.
	-- Otherwise a refused/unread Save would also disable the only way out.
	if state.closed or phase ~= "cancelled" and (state.result ~= nil or state.busy) then return end
	local result = { form_nonce = state.spec.form_nonce, request_id = state.spec.request_id, phase = phase, action = action,
		values = if values then clone(state.values) else nil, field = field_id, path = path, browse_mode = browse_mode }
	if #tern.json.encode(result) > MAX then state.notice = "The complete form exceeds the native size bound. Shorten long fields before saving."; return end
	state.result = result
end
local function browser(state: any, item: any, path: string, initial: boolean?)
	if item.scope ~= "host" then return end
	local ok, entries = pcall(tern.fs.list, path)
	if not ok and initial then
		local parent = path:gsub("[/\\]+$", ""):match("^(.*)[/\\][^/\\]+$")
		if parent == "" then parent = "/" elseif parent and parent:match("^%a:$") then parent ..= "/" end
		if parent then
			local listed, rows = pcall(tern.fs.list, parent)
			if listed then path = parent; ok = true; entries = rows end
		end
	end
	if not ok then state.errors[item.id] = "Cannot list this execution-host folder: " .. tostring(entries):sub(1, 200); return end
	state.errors[item.id] = nil
	local rows = {}; for i, name in entries do if i > 128 then break end; table.insert(rows, name) end
	state.browser = { id = item.id, path = path, rows = rows, clipped = #entries > 128 }
end
local definition: any = {
	font = "sans", features = { "edit", "undo" },
	init = function(_cx: any, args: any, saved: any): any
		local state = { spec = { title = "ORCH+", fields = {} }, values = {}, cursors = {}, anchors = {}, errors = {}, undo = {}, collapsed = {} }
		if type(saved) == "table" and saved.schema == 1 and type(saved.spec) == "table" then
			load(state, saved.spec)
			if state.spec.form_nonce == saved.spec.form_nonce and type(saved.values) == "table" then
				for id, value in saved.values do if field(state, id) then state.values[id] = clone(value) end end
				state.cursors = clone(saved.cursors or {}); state.errors = clone(saved.errors or {})
				state.notice_tone = if next(state.errors) ~= nil or saved.notice_tone == "error" then "error" else nil
				state.collapsed = clone(saved.collapsed or {}); state.disclosures = clone(saved.disclosures or {})
				state.closed = saved.closed == true
				state.needs_resume = not state.closed
				state.notice = if saved.submission_pending then "Draft restored, disconnected. The previous submission was not replayed; inspect saved settings before submitting again." else "Draft restored, disconnected. Reopen the source settings to reconnect. " .. tostring(saved.notice or "")
			end
		else load(state, decode(args[1])) end
		-- Results and pending writes are deliberately not restored as executable UI events.
		state.result = nil; state.busy = false; return state
	end,
	save = function(state: any): any
		return { schema = 1, spec = clone(state.spec), values = clone(state.values), cursors = clone(state.cursors),
			errors = clone(state.errors), collapsed = clone(state.collapsed), disclosures = clone(state.disclosures),
			notice = state.notice, notice_tone = state.notice_tone, closed = state.closed == true, submission_pending = state.result ~= nil or state.busy == true }
	end,
	title = function(state: any): string return state.spec.title or "ORCH+" end,
	view = function(state: any, _cx: any): any
		local ui = tern.ui
		local result = ui.text(tern.json.encode(state.result or { form_nonce = state.spec.form_nonce, request_id = state.spec.request_id, phase = if state.needs_resume then "restored" else "editing" }))
		result.p = result.p or {}; result.p.key = "form-result"; result.p.role = "orchplus.form.result"; result.p.hidden = true
		if state.closed then return { main = ui.col({ ui.text(state.spec.title or "ORCH+"), ui.text(state.notice or "Editing finished."), result }) } end
		local children = { ui.button("Close", { actions = { click = "form-cancel" } }), ui.text(state.spec.title or "ORCH+") }
		if state.spec.description then table.insert(children, ui.text(ui.span(state.spec.description, state.spec.description_tone or ""))) end
		if state.notice then table.insert(children, ui.text(ui.span(state.notice, state.notice_tone or ""))) end
		local function render(item: any): any?
			if not visible(state, item) then return nil end
			local id = "field:" .. item.id; local value = state.values[item.id]; local off = disabled(state, item)
			local control
			if item.kind == "switch" then control = ui.node("switch", { key = id, label = item.label, on = value == true, disabled = off })
			elseif item.kind == "select" then
				local options = clone(item.options or {})
				for _, option in options do if type(option.enabled_by) == "string" and state.values[option.enabled_by] ~= true then option.disabled = true end end
				control = ui.node("select", { key = id, options = options, value = tostring(value or ""), disabled = off, open = state.select == item.id })
			elseif item.kind == "choice_list" then
				local rows = {}
				for i, option in item.options or {} do
					local reason = if type(option.disabled) == "string" then option.disabled else option.disabled_reason
					table.insert(rows, ui.node("item", { key = "choice:" .. item.id .. ":" .. i, label = option.label,
						detail = if reason then (option.detail or "") .. (if option.detail then " — " else "") .. reason else option.detail,
						icon = option.icon, disabled = off or option.disabled ~= nil and option.disabled ~= false }))
				end
				control = ui.node("list", { key = id, empty = "No available choices", max = { lines = 14 } }, rows)
			elseif item.kind == "checklist" then
				local checks = {}; for i, option in item.options or {} do
					local toggle = ui.node("switch", { key = id .. ":option:" .. tostring(i), label = option.label, on = table.find(value or {}, option.value) ~= nil, disabled = off or option.disabled })
					table.insert(checks, if option.icon then ui.row({ ui.node("icon", { name = option.icon }), toggle }) else toggle)
				end; control = ui.col(checks)
			elseif item.kind == "math" then
				control = ui.node("math", { key = id, text = tostring(value or ""), display = true,
					actions = if item.copyable then { menu = { { id = "copy", label = "Copy formula" } } } else nil })
			elseif item.kind == "note" then
				local style = (if item.strong then "strong" else "") .. (if item.tone == "success" or item.tone == "error" then " " .. item.tone else "")
				control = ui.text(ui.span(tostring(value or item.help or ""), style))
			else
				local props: any = { key = id, text = tostring(value or ""), cursor = state.cursors[item.id], anchor = state.anchors[item.id], readonly = off or item.readonly == true,
					unit = item.unit, placeholder = item.placeholder, maxLines = 8 }
				if item.copyable then props.buttons = { { act = "copy", icon = "copy", label = "Copy" } } end
				control = ui.node(if item.kind == "editor" then "editor" else "input", props)
				if item.kind == "path" and (item.scope == "host" or item.scope == "desktop") then
					control.p.grow, control.p.basis, control.p.min = 1, 0, { w = 0 }
					local browse_button = ui.button("Browse", { actions = { click = "form-browse=" .. item.id }, disabled = off, shrink = 0 })
					control = ui.row({ control, browse_button })
				end
			end
			local controls = { control }
			if item.kind == "path" and state.browser and state.browser.id == item.id then
				local b = state.browser
				local items = { ui.text((if b.scope == "desktop" then "Window computer: " else "Execution host: ") .. b.path),
					ui.button("Parent folder", { actions = { click = "form-parent" }, disabled = off }),
					ui.button("Use this folder", { actions = { click = "form-use-folder" }, disabled = off }),
					ui.button("Cancel browse", { actions = { click = "form-browse-cancel" }, disabled = off }) }
				for i, name in b.rows do table.insert(items, ui.button(name, { actions = { click = "form-file=" .. tostring(i) }, disabled = off })) end
				if b.clipped then table.insert(items, ui.text("First 128 entries. Enter a narrower path to browse more.")) end
				local chooser = ui.col(items); chooser.p.key = "browser:" .. item.id; table.insert(controls, chooser)
			end
			return ui.node("field", { key = "row:" .. item.id, label = if item.kind == "switch" then nil else item.label,
				hint = item.help, error = state.errors[item.id], tone = if state.errors[item.id] then "error" else item.tone }, controls)
		end
		local function action_node(action: any): any
			return ui.button(action.label, { key = "action:" .. action.id, actions = { click = "form-action=" .. action.id },
				disabled = action.disabled or state.needs_resume or state.busy or state.result ~= nil })
		end
		local function group(id: any, target: any)
			for _, item in state.spec.fields or {} do if item.group == id then
				local node = render(item)
				if node then
					if item.space_before then table.insert(target, ui.node("spacer", { key = "space:" .. item.id, size = "lg" })) end
					table.insert(target, node)
					for _, action in state.spec.actions or {} do
						if action.after_field == item.id and not action.hidden then table.insert(target, action_node(action)) end
					end
				end
			end end
			if id ~= nil then for _, action in state.spec.actions or {} do
				if action.group == id and action.after_field == nil and not action.hidden then table.insert(target, action_node(action)) end
			end end
			for _, entry in state.spec.groups or {} do if entry.parent == id then
				local click = { click = "form-group=" .. entry.id }
				local prefix = if state.collapsed[entry.id] then "▸ " else "▾ "
				local header = ui.button(prefix .. entry.label, { actions = click })
				if entry.tone == "success" or entry.tone == "error" then
					local label = ui.text(ui.span(entry.label, entry.tone)); label.p.actions = click
					header = ui.row({ ui.button(prefix, { actions = click, title = entry.label }), label })
				end
				local inner = { header }
				if not state.collapsed[entry.id] then group(entry.id, inner) end
				local container = ui.col(inner); container.p.key = "group:" .. entry.id
				table.insert(target, container)
				if entry.separator_after then table.insert(target, ui.rule("")) end
			end end
		end
		group(nil, children)
		local actions = {}; for _, action in state.spec.actions or { { id = "save", label = "Save", submit = true } } do
			if action.group == nil and action.after_field == nil and not action.hidden then table.insert(actions, action_node(action)) end
		end; table.insert(children, ui.col(actions))
		table.insert(children, result); return { main = ui.col(children) }
	end,
	event = function(state: any, ev: any, _cx: any)
		if ev.ev == "action" and ev.act == "form-open" then load(state, decode(ev.value)); return end
		if ev.ev == "action" and (ev.act == "form-refresh" or ev.act == "form-resume") then
			local value = decode(ev.value)
			if not value or value.form_nonce ~= state.spec.form_nonce or value.request_id ~= state.spec.request_id or state.closed then return end
			if ev.act == "form-resume" then
				state.needs_resume = false; state.busy = value.busy == true
				state.notice = "Draft reconnected. Review your entered values before saving."
			elseif state.result == nil and not state.busy and not state.needs_resume and type(value.options) == "table" then
				local choice = state.spec.fields[1]
				if choice and choice.kind == "choice_list" and #choice.options == #value.options then choice.options = value.options end
			end
			return
		end
		if ev.ev == "action" and ev.act == "form-ack" then
			local value = decode(ev.value)
			if not value or value.form_nonce ~= state.spec.form_nonce or value.request_id ~= state.spec.request_id then return end
			local cancelling = state.result ~= nil and state.result.phase == "cancelled" and state.result.action == "cancel"
			state.result = nil; state.errors = value.errors or {}; state.notice = value.notice; state.busy = value.busy == true
			state.notice_tone = if value.notice_tone == "error" or next(state.errors) ~= nil then "error" else nil
			for id in state.errors do
				local item = field(state, id)
				local parent = if item then item.group else nil
				for _ = 1, #(state.spec.groups or {}) do
					if not parent then break end
					state.collapsed[parent] = false
					local next_parent = nil
					for _, entry in state.spec.groups or {} do if entry.id == parent then next_parent = entry.parent; break end end
					parent = next_parent
				end
			end
			state.closed = state.closed == true or value.closed == true
			if type(value.description) == "string" then
				state.spec.description = value.description
				state.spec.description_tone = if value.description_tone == "error" then "error" elseif value.description_tone == "info" then "info" else nil
			end
			state.needs_resume = false
			if type(value.next_request_id) == "string" then state.spec.request_id = value.next_request_id end
			-- An ACK already in transit may rotate the request after Close was
			-- clicked. Carry that cancellation forward; never erase the user's exit.
			if cancelling and value.closed ~= true then
				state.result = { form_nonce = state.spec.form_nonce, request_id = state.spec.request_id, phase = "cancelled", action = "cancel" }
			end
			if type(value.values) == "table" then for id, text in value.values do if field(state, id) then state.values[id] = clone(text) end end end
			if value.browser == false then state.browser = nil
			elseif type(value.browser) == "table" then state.browser = clone(value.browser) end
			return
		end
		if state.closed then return end
		if ev.ev == "select" or ev.ev == "activate" then
			local id: any, index: any = nil, nil
			if type(ev.item) == "string" then id, index = ev.item:match("choice:(.+):(%d+)$") end
			local choice = if id then field(state, id) else nil
			local option = if choice and index then choice.options[tonumber(index)] else nil
			if choice and choice.kind == "choice_list" and option and not option.disabled and visible(state, choice) and not disabled(state, choice) then
				state.values[choice.id] = option.value; publish(state, choice.action or "choose", "submitted", true)
			end
			return
		end
		local item = field(state, ev.id or ev.item)
		if ev.ev == "focus" and type(ev.id) == "string" and editable(state, item) then
			state.focus = item.id
			state.anchors = {}
			state.cursors[item.id] = state.cursors[item.id] or length(state.values[item.id])
			_cx:frame({ { "focus", ev.id } }); return
		end
		if ev.ev == "edit" and editable(state, item) then
			local text = state.values[item.id]; local from, to = ev["from"], ev.to
			if type(text) ~= "string" or ev.len ~= length(text) or type(ev.text) ~= "string" or utf8.len(ev.text) == nil then return end
			local a, b = boundary(text, from), boundary(text, to)
			if not a or not b or b < a or #text - (b - a) + #ev.text > 65536 then return end
			local value = text:sub(1, a - 1) .. ev.text .. text:sub(b)
			if boundary(value, ev.cursor) == nil then return end
			if value ~= text then remember(state, item.id); state.values[item.id] = value end
			state.cursors[item.id] = ev.cursor; state.anchors[item.id] = nil; return
		end
		if ev.ev == "undo" and editable(state, item) then
			undo(state, item); return
		end
		local raw = ev.id or ev.item or ""; local key, option = raw:match("field:(.+):option:(%d+)$")
		if key then item = field(state, key) end
		if ev.ev == "change" and item and visible(state, item) and not disabled(state, item) then
			if option and item.kind == "checklist" then
				local entry = item.options[tonumber(option)]; if not entry or entry.disabled then return end
				remember(state, item.id); local selected = clone(state.values[item.id] or {}); local pos = table.find(selected, entry.value)
				if ev.value == true and not pos then table.insert(selected, entry.value) elseif ev.value == false and pos then table.remove(selected, pos) end
				state.values[item.id] = selected
			elseif item.kind == "switch" and type(ev.value) == "boolean" then remember(state, item.id); state.values[item.id] = ev.value
			elseif item.kind == "select" then
				for _, entry in item.options or {} do if entry.value == ev.value and not entry.disabled and (not entry.enabled_by or state.values[entry.enabled_by] == true) then remember(state, item.id); state.values[item.id] = ev.value; state.select = nil; break end end
			end; return
		end
		if ev.ev == "toggle" and item and not disabled(state, item) then state.select = if ev.open then item.id else nil; return end
		if ev.ev ~= "action" then return end
		if ev.ev == "action" and type(ev.act) == "string" and ev.act:match("^form%-") and ev.value ~= nil and not ev.act:find("=", 1, true) then
			ev = clone(ev); ev.act = ev.act .. "=" .. tostring(ev.value)
		end
		if ev.act == "form-cancel" then
			if state.needs_resume then state.closed = true; state.notice = "Editing closed. Reopen settings from ORCH+."; _cx:exit(0)
			else
				publish(state, "cancel", "cancelled", false)
				-- Ending this local editor never depends on a window consumer or a
				-- live source. Keep only its receipt for verified native pane cleanup.
				state.closed = true; state.busy = false; state.focus = nil
				state.notice = "Editing closed. Return to ORCH+ to continue."
			end
			return
		end
		local collapse = type(ev.act) == "string" and ev.act:match("^form%-group=(.+)$")
		if collapse then state.collapsed[collapse] = not state.collapsed[collapse]; return end
		local browse = type(ev.act) == "string" and ev.act:match("^form%-browse=(.+)$")
		if browse then
			local f = field(state, browse); local value = state.values[browse]
			if f and f.kind == "path" and visible(state, f) and not disabled(state, f) then
				local absolute = type(value) == "string" and (value:match("^[/\\]") or value:match("^%a:"))
				if f.scope == "desktop" then publish(state, "browse", "browse", false, f.id, if absolute then value else nil, "initial")
				else browser(state, f, if absolute then value else f.browse_root or tern.plugin.data, true) end
			end
			return
		end
		if state.browser and not state.busy and state.result == nil then
			local b = state.browser; local f = field(state, b.id)
			if not f or disabled(state, f) or not visible(state, f) then return end
			if ev.act == "form-browse-cancel" then state.browser = nil; return end
			if ev.act == "form-parent" then
				if b.scope == "desktop" then publish(state, "browse", "browse", false, b.id, b.path .. "/..", "list")
				else browser(state, f, b.path .. "/..") end
				return
			end
			if ev.act == "form-use-folder" then remember(state, b.id); state.values[b.id] = b.path; state.browser = nil; return end
			local position = type(ev.act) == "string" and ev.act:match("^form%-file=(%d+)$")
			if position and b.rows[tonumber(position)] then
				local path = b.path .. "/" .. b.rows[tonumber(position)]
				if b.scope == "desktop" then publish(state, "browse", "browse", false, b.id, path, "entry"); return end
				local ok = pcall(tern.fs.list, path)
				if ok then browser(state, f, path) else remember(state, b.id); state.values[b.id] = path; state.browser = nil end; return
			end
		end
		local action = type(ev.act) == "string" and ev.act:match("^form%-action=(.+)$")
		if action then for _, entry in state.spec.actions or { { id = "save", submit = true } } do if entry.id == action and not entry.disabled then publish(state, action, if entry.submit then "submitted" else "action", entry.submit == true); break end end end
	end,
	key = key_edit,
}
M.definition = definition
M.utf16_boundary = boundary
function M.register() tern.block.define("form", definition) end
return M
