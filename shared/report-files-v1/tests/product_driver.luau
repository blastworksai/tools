--!strict
-- Generic native UI operations only; ORCH/SPAWN keep their real runtime drivers.
local directory = tern.plugin.data
pcall(tern.fs.mkdir, directory)
local last
local focus_revisions = {}
tern.on("focus", function(_event, cx)
	local key = cx:window_key()
	focus_revisions[key] = (focus_revisions[key] or 0) + 1
end)
local function text(node)
	local p = node.p or {}
	if type(p.text) == "string" then return p.text end
	local out = {}
	for _, span in p.spans or {} do table.insert(out, if type(span) == "string" then span else span.t or "") end
	return table.concat(out)
end
local function buttons(node, label, found)
	if type(node) ~= "table" then return end
	if node.p and node.p.actions and node.p.actions.click and text(node) == label then table.insert(found, node) end
	for _, child in node.c or {} do buttons(child, label, found) end
end
local function command_buttons(node, command, found)
	if type(node) ~= "table" then return end
	local p = node.p or {}
	local attrs = p.attrs or {}
	if p.actions and p.actions.click and not p.disabled and not attrs.disabled
		and attrs["data-orchplus-command"] == command.command
		and (command.worker_id == nil or attrs["data-orchplus-worker"] == command.worker_id) then
		table.insert(found, node)
	end
	for _, child in node.c or {} do command_buttons(child, command, found) end
end
local function gate_button(node, gate, label)
	if type(node) ~= "table" then return nil, false end
	local contains = text(node):sub(1, #gate + 12) == gate .. " / revision "
	for _, child in node.c or {} do
		local button, found = gate_button(child, gate, label)
		if button then return button, true end
		contains = contains or found
	end
	if contains then
		local found = {}; buttons(node, label, found)
		if #found == 1 then return found[1], true end
	end
	return nil, contains
end
local function preferences(node, found)
	if type(node) ~= "table" then return end
	if node.p and node.p.sections and node.p.pages then table.insert(found, node) end
	for _, child in node.c or {} do preferences(child, found) end
end
local ASYNC = {}
local FOCUS_INPUT = { open=true, focus=true, close=true, click=true, click_gate=true, click_command=true, preference=true, event=true }
local function operation(command, cx, done)
	if command.pane and FOCUS_INPUT[command.op] then cx.layout:focus(command.pane) end
	if command.op == "open" then
		local args = command.args or {}
		if command.kind == "spawn.spawner" then args = { tern.json.encode({ kind = "context", host = cx.hosts:current(), native_window = cx:window_key() }) } end
		return assert(cx:new_block(command.kind, args, "tab"), "native block unavailable: " .. command.kind)
	elseif command.op == "focus" then return true
	elseif command.op == "close" then cx.layout:close(command.pane); return true
	elseif command.op == "surface" then
		return cx.session:surface(command.pane, { root = command.root, nodes = command.nodes or 1000,
			depth = command.depth or 20, max_chars = command.max_chars or 64000 })
	elseif command.op == "click" or command.op == "click_gate" or command.op == "click_command" then
		local tree = cx.session:surface(command.pane, { nodes = 1000, depth = 20, max_chars = 64000 })
		assert(type(tree) == "table", "native surface unavailable")
		local found = {}
		if command.op == "click_gate" then
			local button = gate_button(tree.main, command.gate_id, command.label)
			if button then table.insert(found, button) end
		elseif command.op == "click_command" then command_buttons(tree.main, command, found)
		else
			-- Canvas pickers expose their actual visible controls in the dock.
			buttons(tree.main, command.label, found)
			buttons(tree.dock, command.label, found)
		end
		assert(#found == 1, "expected exactly one enabled native control: " .. tostring(command.label or command.command) .. "; found " .. #found)
		local node = found[1]
		local action = node.p.actions.click
		local act, value = action:match("^([^=]+)=(.*)$")
		cx.session:event(command.pane, { ev = "action", id = node.id, act = act or action, value = value })
		return { label = text(node), event = action, node = node.id, command = command.command }
	elseif command.op == "preferences" or command.op == "preference" then
		local tree = cx.session:surface(command.pane, { nodes = 1000, depth = 20, max_chars = 64000 })
		if type(tree)~="table" then
			if command.op=="preferences" then return {pending=true} end
			error("native preferences surface is not yet available; no event sent")
		end
		local found = {}; preferences(tree.main, found)
		if #found==0 and command.op=="preferences" then return {pending=true} end
		assert(#found == 1, "expected one visible native preferences node")
		local node = found[1]
		if command.op == "preferences" then return { id = node.id, properties = node.p } end
		if command.page then
			local page
			for _, candidate in node.p.pages do if candidate.id == command.page then page = candidate end end
			assert(page, "page is not exposed by the native preferences")
			cx.session:event(command.pane, { ev = "action", id = node.id, act = "page", value = page.id })
			return { page = page.id, node = node.id }
		end
		local matches = {}
		for _, section in node.p.sections do
			if section.page == nil or section.page == node.p.page then
				for _, row in section.rows do
					if row.id == command.row or (command.label and row.label == command.label) then table.insert(matches, row) end
				end
			end
		end
		assert(#matches == 1, "expected one visible native preference row: " .. tostring(command.row or command.label))
		local row = matches[1]
		assert(not row.disabled, "native preference is disabled: " .. tostring(row.disabled))
		local control = row.control
		local event = { id = node.id, item = row.id }
		if control.k == "action" then
			event.ev = "action"; event.act = control.act
		elseif control.k == "choice" then
			local eligible = false
			for _, option in control.options do if option.value == command.value then eligible = true end end
			assert(eligible, "value not offered by native choice")
			event.ev = "change"; event.value = command.value
		elseif control.k == "switch" then
			assert(type(command.value) == "boolean", "switch requires boolean")
			event.ev = "change"; event.value = command.value
		elseif control.k == "text" then
			assert(type(command.value) == "string", "text requires string")
			event.ev = "activate"
			cx.session:event(command.pane, event)
			return { row = row.id, editing = true, previous = control.value, node = node.id }
		else error("unsupported visible native preference control " .. tostring(control.k)) end
		cx.session:event(command.pane, event)
		return { row = row.id, event = event, node = node.id }
	elseif command.op == "event" then
		cx.session:event(command.pane, command.event); return true
	elseif command.op == "settings" then return cx.settings:set_many(command.values)
	elseif command.op == "panes" then return cx.session:panes()
	elseif command.op == "pane_read" then return cx.session:read(command.pane)
	elseif command.op == "doc_open" then return cx.docs:open(command.path, { how = "tab" })
	elseif command.op == "doc_read" then
		cx.docs:read(command.path):next(done)
		return ASYNC
	elseif command.op == "doc_edit" then
		cx.docs:edit(command.path, command.spec):next(done)
		return ASYNC
	elseif command.op == "agents" then
		local result = {}
		for _, agent in cx.agents:list() do
			table.insert(result, { pane = agent.pane, model = agent.model, command = agent.command, cwd = agent.cwd,
				state = agent.state, delivery_error = agent.delivery_error })
		end
		return result
	elseif command.op == "session_create" then
		return cx.sessions:create({ name = command.name, cwd = command.cwd })
	elseif command.op == "session_switch" then
		assert(type(command.session) == "number", "session_switch requires an observed exact numeric session id")
		cx.sessions:switch(command.session)
		return cx.sessions:current()
	elseif command.op == "context" then return { host = cx.hosts:current(), session = cx.sessions:current(), window = cx:window_key(), focused = cx.session:focused(), focus_revision = focus_revisions[cx:window_key()] or 0 }
	else error("unknown product UI operation " .. tostring(command.op)) end
end
local announced = false
local function tick(cx)
	if not announced then
		local key = cx:window_key()
		local suffix = key:gsub(".", function(character) return string.format("%02x", string.byte(character)) end)
		tern.fs.write(directory .. "/ready-window-" .. (if suffix == "" then "initial" else suffix) .. ".json",
			tern.json.encode({ window_key = key, session = cx.sessions:current(), host = cx.hosts:current() }))
		announced = true
	end
	local exists, bytes = pcall(tern.fs.read, directory .. "/command.json")
	if exists then
		local decoded, command = pcall(tern.json.decode, bytes)
		if decoded and command.id ~= last and (command.window_key == nil or command.window_key == cx:window_key()) then
			last = command.id
			local function respond(value, failure)
				tern.fs.write(directory .. "/response.json", tern.json.encode({
					id = command.id, ok = failure == nil, result = if failure == nil then value else nil,
					error = if failure == nil then nil else tostring(failure),
				}))
			end
			local ok, result = pcall(operation, command, cx, respond)
			if not ok then respond(nil, result)
			elseif result ~= ASYNC then respond(result, nil) end
		end
	end
	tern.timer(25, tick)
end
tern.fs.write(directory .. "/ready.json", tern.json.encode({ ready = true }))
tern.timer(25, tick)
