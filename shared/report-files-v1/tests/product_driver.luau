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
local function operation(command, cx)
	if command.op == "open" then
		local args = command.args or {}
		if command.kind == "spawn.spawner" then args = { tern.json.encode({ kind = "context", host = cx.hosts:current(), native_window = cx:window_key() }) } end
		return assert(cx:new_block(command.kind, args, "tab"), "native block unavailable: " .. command.kind)
	elseif command.op == "surface" then
		return cx.session:surface(command.pane, { root = command.root, nodes = 1000, depth = 20, max_chars = 64000 })
	elseif command.op == "click" then
		local tree = cx.session:surface(command.pane, { nodes = 1000, depth = 20, max_chars = 64000 })
		assert(type(tree) == "table", "native surface unavailable")
		local found = {}; buttons(tree.main, command.label, found)
		assert(#found == 1, "expected exactly one native button: " .. command.label .. "; found " .. #found)
		local node = found[1]
		local action = node.p.actions.click
		local act, value = action:match("^([^=]+)=(.*)$")
		cx.session:event(command.pane, { ev = "action", id = node.id, act = act or action, value = value })
		return { label = command.label, event = action, node = node.id }
	elseif command.op == "event" then
		cx.session:event(command.pane, command.event); return true
	elseif command.op == "action" then
		cx:action(command.action); return true
	elseif command.op == "settings" then return cx.settings:set_many(command.values)
	elseif command.op == "panes" then return cx.session:panes()
	elseif command.op == "context" then return { host = cx.hosts:current(), session = cx.sessions:current(), window = cx:window_key() }
	else error("unknown product UI operation " .. tostring(command.op)) end
end
local function tick(cx)
	local exists, bytes = pcall(tern.fs.read, directory .. "/command.json")
	if exists then
		local decoded, command = pcall(tern.json.decode, bytes)
		if decoded and command.id ~= last then
			last = command.id
			local ok, result = pcall(operation, command, cx)
			tern.fs.write(directory .. "/response.json", tern.json.encode({ id = last, ok = ok, result = if ok then result else nil, error = if ok then nil else tostring(result) }))
		end
	end
	tern.timer(25, tick)
end
tern.fs.write(directory .. "/ready.json", tern.json.encode({ ready = true }))
tern.timer(25, tick)
