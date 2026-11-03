-- Run only in a dedicated real Tern desktop, without a model request:
-- assert(loadstring(tern.fs.read(DRIVER_PATH)))(PLUGIN_DIR, { "accounts", "snapshot" }, RUN_ID)
-- The launcher supplies every discovered fixture; this file is not itself a suite.
local root, suites, run_id = ...
assert(type(root) == "string" and #root > 0, "pass the plugin directory")
assert(type(suites) == "table" and #suites > 0, "pass a nonempty suite array")
assert(type(run_id) == "string" and run_id:match("^[a-zA-Z0-9_%-]+$"), "pass a unique run id")

local results, seen = tern.json.array(), {}
local passed, failed, checks = 0, 0, 0
for _, suite in suites do
	assert(type(suite) == "string" and suite:match("^[a-z][a-z0-9_]*$") and suite ~= "run_luau", "invalid fixture name")
	assert(not seen[suite], "duplicate fixture: " .. suite)
	seen[suite] = true
	-- Fixtures retain their own real-module loaders and synthetic I/O boundaries.
	-- Let the desktop scheduler reset its callback budget between independent suites.
	if type(await) == "function" then await(tern.sleep(0)) end
	local ok, result = pcall(function()
		return assert(loadstring(tern.fs.read(root .. "/tests/" .. suite .. ".luau")))(root)
	end)
	local count = nil
	if ok and type(result) == "string" then
		count = tonumber(result:match("^PASS (%d+) .+$") or result:match("^PASS " .. suite .. ": (%d+) checks$"))
		if result:upper():match("%f[%a]SKIP%a*%f[%A]") then count = nil end
	end
	if count ~= nil and count > 0 then
		passed += 1
		checks += count
		table.insert(results, { suite = suite, status = "PASS", checks = count, result = result })
	else
		failed += 1
		table.insert(results, { suite = suite, status = "FAIL", checks = 0,
			error = if ok then "Missing positive PASS/check result: " .. tostring(result) else tostring(result) })
	end
end
return "USAGE_VERIFY " .. tern.json.encode({ version = 1, run_id = run_id,
	status = if failed == 0 then "PASS" else "FAIL", results = results,
	suites = #suites, passed = passed, failed = failed, checks = checks })
