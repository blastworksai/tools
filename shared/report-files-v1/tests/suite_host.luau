--!strict
-- Host-only runner: the native 2-second budget is unchanged. JSON calls are the
-- existing fixture yield seams; a callback spends at most 100 ms between seams.
local native = tern
local config = native.json.decode(native.fs.read(native.plugin.dir .. "/run.json"))
local results = native.json.array()
local position, resumes = 0, 0
local task, thread, slice_started
local function persist(done)
	native.fs.write(native.plugin.data .. "/suite-results.json", native.json.encode({ done = done, results = results, resumes = resumes, current = task }))
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
	local prefix, suffix
	if task.family == "shared" then
		prefix, suffix = "shared/" .. task.consumer .. "/" .. task.case_id .. ": ", " checks passed"
	elseif task.family == "orch" then
		local endings = { state = " ownership state checks", transport = " report transport checks", authority = " authority assertions" }
		if endings[task.group] then prefix, suffix = "PASS ", endings[task.group]
		else
			local section = if task.section then "/" .. task.section elseif task.group == "dispatch" then "" else "/all"
			prefix, suffix = task.group .. section .. ": ", " checks passed"
		end
	elseif task.group == "authority" then prefix, suffix = "PASS " .. task.section .. " ", " SPAWN authority checks"
	elseif task.group == "backend" or task.group == "behavior" then prefix, suffix = "PASS ", " SPAWN " .. task.group .. " checks"
	elseif task.group == "mailbox" then prefix, suffix = "mailbox checks: ", ""
	else
		local section = if task.group == "dispatch" and task.section then "/" .. task.section else ""
		prefix, suffix = "PASS " .. task.group .. section .. " ", ""
	end
	local function literal(text) return (text:gsub("(%W)", "%%%1")) end
	return tonumber(value:match("^" .. literal(prefix) .. "([1-9]%d*)" .. literal(suffix) .. "$"))
end
local function step()
	slice_started = native.now()
	if thread == nil then
		position += 1
		task = config.tasks[position]
		if task == nil then persist(true); return end
		thread = coroutine.create(function()
			local path = if task.family == "shared" then native.plugin.dir .. "/corpus_runner.luau" else task.root .. "/tests/run.luau"
			local chunk = assert(loadstring(native.fs.read(path), path))
			setfenv(chunk, environment())
			if task.family == "shared" then return chunk(task.root, task.consumer, task.case_id) end
			if task.family == "orch" then return chunk(task.root, task.group .. (if task.section then "/" .. task.section else "")) end
			return chunk(task.root, task.group, task.section)
		end)
	end
	resumes += 1
	local ok, value = coroutine.resume(thread)
	if not ok or coroutine.status(thread) == "dead" then
		local count = if ok then check_count(value) else nil
		table.insert(results, { id = task.id, passed = count ~= nil, checks = count, summary = tostring(value),
			error = if not ok then tostring(value) elseif count == nil then "Unexpected or zero-check suite summary" else nil })
		thread = nil
		persist(false)
	end
	native.timer(1, step)
end
pcall(native.fs.mkdir, native.plugin.data)
persist(false)
native.timer(1, step)
