--!strict
-- Generic native UI operations only; ORCH/SPAWN keep their real runtime drivers.
local directory = tern.plugin.data
pcall(tern.fs.mkdir, directory)
local last
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
local FOCUS_INPUT = { open=true, focus=true, close=true, click=true, click_gate=true, preference=true, event=true }
local function operation(command, cx)
	if command.pane and FOCUS_INPUT[command.op] then cx.layout:focus(command.pane) end
	if command.op == "open" then
		local args = command.args or {}
		if command.kind == "spawn.spawner" then args = { tern.json.encode({ kind = "context", host = cx.hosts:current(), native_window = cx:window_key() }) } end
		return assert(cx:new_block(command.kind, args, "tab"), "native block unavailable: " .. command.kind)
	elseif command.op == "focus" then return true
	elseif command.op == "close" then cx.layout:close(command.pane); return true
	elseif command.op == "surface" then
		return cx.session:surface(command.pane, { root = command.root, nodes = 1000, depth = 20, max_chars = 64000 })
	elseif command.op == "click" or command.op == "click_gate" then
		local tree = cx.session:surface(command.pane, { nodes = 1000, depth = 20, max_chars = 64000 })
		assert(type(tree) == "table", "native surface unavailable")
		local found = {}
		if command.op == "click_gate" then
			local button = gate_button(tree.main, command.gate_id, command.label)
			if button then table.insert(found, button) end
		else buttons(tree.main, command.label, found) end
		assert(#found == 1, "expected exactly one native button: " .. command.label .. "; found " .. #found)
		local node = found[1]
		local action = node.p.actions.click
		local act, value = action:match("^([^=]+)=(.*)$")
		cx.session:event(command.pane, { ev = "action", id = node.id, act = act or action, value = value })
		return { label = command.label, event = action, node = node.id }
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
	elseif command.op == "agents" then
		local result = {}
		for _, agent in cx.agents:list() do
			table.insert(result, { pane = agent.pane, model = agent.model, command = agent.command, cwd = agent.cwd,
				state = agent.state, delivery_error = agent.delivery_error })
		end
		return result
	elseif command.op == "context" then return { host = cx.hosts:current(), session = cx.sessions:current(), window = cx:window_key() }
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
			local ok, result = pcall(operation, command, cx)
			tern.fs.write(directory .. "/response.json", tern.json.encode({ id = last, ok = ok, result = if ok then result else nil, error = if ok then nil else tostring(result) }))
		end
	end
	tern.timer(25, tick)
end
tern.fs.write(directory .. "/ready.json", tern.json.encode({ ready = true }))
tern.timer(25, tick)
