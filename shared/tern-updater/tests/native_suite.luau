-- Updater pure-module contracts in an isolated real Tern Luau VM.
local tests = require("./version_test")
for _, name in { "./manifest_test", "./source_test", "./requires_test", "./confirm_test", "./state_test" } do
	for _, test in require(name) do table.insert(tests, test) end
end
local passed, failures = 0, {}
for _, test in tests do
	local ok, reason = pcall(test[2])
	if ok then passed += 1 else table.insert(failures, tostring(test[1]) .. ": " .. tostring(reason)) end
end
return { passed = passed, failures = failures }
