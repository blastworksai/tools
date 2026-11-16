--!strict
-- Host-only runner: the native 2-second budget is unchanged. JSON calls are the
-- existing fixture yield seams; a callback spends at most 100 ms between seams.
local native = tern
local config = native.json.decode(native.fs.read(native.plugin.dir .. "/run.json"))
local results = native.json.array()
local position, resumes = 0, 0
local task, thread, slice_started, task_started
local MAX_SUITE_MS = 60000
local function persist(done)
	native.fs.write(native.plugin.data .. "/suite-results.json", native.json.encode({ done = done, results = results, resumes = resumes, current = if thread ~= nil then task else nil }))
end
local function environment()
	local runtime = table.clone(native)
	runtime.json = table.clone(native.json)
	for _, name in { "encode", "decode" } do
		local original = native.json[name]
		runtime.json[name] = function(...)
			if native.now() - slice_started >= 100 then coroutine.yield() end
			return original(...)
		end
	end
	return setmetatable({ tern = runtime }, { __index = getfenv() })
end
local function check_count(value)
	if type(value) ~= "string" then return nil end
	-- Suite prose is diagnostic, not an assertion contract. Existing runners
	-- report a positive count either after PASS [group] or after a label colon.
	-- Require that count; do not pin incidental descriptions such as "checks"
	-- versus "assertions", group names or section labels.
	local count = value:match("^PASS%s+([1-9]%d*)%f[%D]")
		or value:match("^PASS%s+%S+%s+([1-9]%d*)%f[%D]")
		or value:match("^[^:\n]+:%s+([1-9]%d*)%f[%D]")
	return if count then tonumber(count) else nil
end
local function step()
	slice_started = native.now()
	if thread == nil then
		position += 1
		task = config.tasks[position]
		if task == nil then persist(true); return end
		task_started = native.now()
		thread = coroutine.create(function()
			local path = if task.family == "shared" then native.plugin.dir .. "/corpus_runner.luau"
				elseif task.family == "usage" or task.family == "work" then task.root .. "/tests/" .. task.group .. ".luau"
				else task.root .. "/tests/run.luau"
			local chunk = assert(loadstring(native.fs.read(path), path))
			setfenv(chunk, environment())
			if task.family == "shared" then return chunk(task.root, task.consumer, task.case_id) end
			if task.family == "usage" or task.family == "work" then return chunk(task.root) end
			if task.family == "orch" then return chunk(task.root, task.group .. (if task.section then "/" .. task.section else "")) end
			return chunk(task.root, task.group, task.section)
		end)
		persist(false)
	end
	resumes += 1
	local ok, value
	if native.now() - task_started >= MAX_SUITE_MS then
		ok, value = false, "Suite exceeded its 60-second wall-time bound: " .. task.id
	else
		ok, value = coroutine.resume(thread)
	end
	if not ok or coroutine.status(thread) == "dead" then
		local count = if ok then check_count(value) else nil
		local passed = ok and (if task.family == "work" then value == true else count ~= nil)
		table.insert(results, { id = task.id, passed = passed, checks = count, summary = tostring(value),
			elapsed_ms = native.now() - task_started,
			error = if not ok then tostring(value) elseif not passed then "Unexpected or zero-check suite summary" else nil })
		thread = nil
		persist(false)
	end
	native.timer(1, step)
end
pcall(native.fs.mkdir, native.plugin.data)
persist(false)
native.timer(1, step)
