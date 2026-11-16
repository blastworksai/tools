-- Updater pure-module contracts in an isolated real Tern Luau VM.
local groups = { "version", "manifest", "source", "requires", "state", "journal", "resolution", "background", "observe", "remote" }
local selection = {}
local path = tern.plugin.dir .. "/updater/tests/selection.json"
if tern.fs.exists(path) then
	local values = tern.json.decode(tern.fs.read(path, 4096))
	assert(type(values) == "table" and #values > 0, "Empty native suite selection")
	for _, name in ipairs(values) do
		assert(table.find(groups, name) ~= nil and not selection[name], "Unknown or duplicate native suite group")
		selection[name] = true
	end
else
	for _, name in ipairs(groups) do selection[name] = true end
end
local tests, selected = {}, {}
for _, name in ipairs(groups) do
	if selection[name] then
		table.insert(selected, name)
		for _, test in require("./" .. name .. "_test") do table.insert(tests, test) end
	end
end
local passed, failures = 0, {}
for _, test in tests do
	local ok, reason = pcall(test[2])
	if ok then passed += 1 else table.insert(failures, tostring(test[1]) .. ": " .. tostring(reason)) end
end
return { passed = passed, failures = failures, selected_groups = selected }
