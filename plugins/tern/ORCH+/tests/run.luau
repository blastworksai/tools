-- Tern Lua entrypoint: run.luau <plugin-directory> <group[/section][,...]>
local root, selection = ...
assert(type(root) == "string" and root ~= "", "pass the plugin directory")
assert(type(selection) == "string" and selection ~= "", "pass bounded group/section selections; run the remaining groups in separate callbacks")
local allowed = { state = true, transport = true, authority = true, dispatch = true, reports = true, gates = true, health = true, workflow = true }
local groups, seen = {}, {}
for selector in string.gmatch(selection, "[^,]+") do
	local name, section = string.match(selector, "^([a-z_]+)/([a-z_]+)$")
	name = name or selector
	assert(allowed[name] == true, "unknown test group: " .. selector)
	assert(not seen[selector], "duplicate test selection: " .. selector)
	seen[selector] = true
	table.insert(groups, { name = name, section = section })
end
assert(#groups > 0, "select at least one test group")
local results = {}
for _, group in groups do
	local name = group.name
	local chunk = assert(loadstring(tern.fs.read(root .. "/tests/" .. name .. ".luau"), "tests/" .. name))
	setfenv(chunk, setmetatable({}, { __index = getfenv() }))
	local result = chunk(root, group.section)
	assert(type(result) == "string", "test group must return its check summary: " .. name)
	table.insert(results, result)
end
return table.concat(results, "\n")
