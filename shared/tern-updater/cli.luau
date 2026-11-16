-- Native commands are observations or the one journaled install; never implicit retries.
local Discovery = require("./discovery")
local Journal = require("./journal")
local Cli = {}
local executable, waiting = nil, nil

local function first_line(value)
	return (tostring(value or ""):match("[^\r\n]+") or ""):sub(1, 200)
end
function Cli.route()
	local socket = tern.getenv("TERN_DAEMON_SOCKET")
	-- The launched process's explicit connection outranks inherited shell context.
	if tern.runtime.os == "linux" then
		local ok, command = pcall(tern.fs.read, "/proc/self/cmdline", 65536)
		if ok then
			local words = {}
			for word in command:gmatch("[^%z]+") do table.insert(words, word) end
			for index, word in ipairs(words) do
				if word == "--socket" and Discovery.absolute(words[index + 1]) then socket = words[index + 1]; break end
			end
		end
	end
	local config = tern.getenv("TERN_CONFIG_DIR")
	return { socket = if socket and socket ~= "" then socket else false, config = if config and config ~= "" then config else false }
end
local function environment(route)
	return { STENCIL_LOG = "off", TERN_PANE = "", TERN_PANE_SOCKET = "", TERN_WINDOW_KEY = "", TERN_WINDOW_SOCKET = "",
		TERN_DAEMON_SOCKET = if route and route.socket then route.socket else nil,
		TERN_CONFIG_DIR = if route and route.config then route.config else nil }
end
function Cli.run(argv, timeout_ms, route, cb)
	local ok, err = pcall(tern.process.run, argv, { timeout_ms = timeout_ms, env = environment(route) }, function(result, cx)
		cb(result, nil, cx)
	end)
	if not ok then cb(nil, "Couldn't start " .. tostring(argv[1]) .. ": " .. first_line(err), nil) end
end
function Cli.complete(result)
	return type(result) == "table" and result.status == 0 and result.timed_out ~= true
		and result.truncated ~= true and result.stdout_truncated ~= true
		and type(result.stdout) == "string" and #result.stdout <= 2097152
end
function Cli.json(result)
	if not Cli.complete(result) then return nil, "Native command did not produce a complete successful result" end
	local ok, value = pcall(tern.json.decode, result.stdout)
	if not ok or type(value) ~= "table" then return nil, "Native command did not return one JSON object" end
	return value
end
function Cli.executable(cb)
	if executable ~= nil then cb(executable, nil, nil); return end
	if waiting ~= nil then table.insert(waiting, cb); return end
	local system = if tern.runtime.os == "windows" then tern.getenv("SystemRoot") or tern.getenv("WINDIR") else nil
	local argv, problem = Discovery.argv(tern.runtime.os, system)
	if argv == nil then cb(nil, problem, nil); return end
	waiting = { cb }
	-- Discovery intentionally retains the process's own TERN_EXE environment.
	local ok, raised = pcall(tern.process.run, argv, { timeout_ms = 10000, env = { STENCIL_LOG = "off" } }, function(result, cx)
		local path, err = nil, nil
		if not Cli.complete(result) then err = "Couldn't locate the running Tern executable: " .. first_line(result.stderr)
		else path, err = Discovery.path(result.stdout) end
		if path ~= nil then executable = path end
		local callbacks = waiting or {}
		waiting = nil
		for _, callback in ipairs(callbacks) do callback(path, err, cx) end
	end)
	if not ok then
		local callbacks = waiting or {}
		waiting = nil
		for _, callback in ipairs(callbacks) do callback(nil, "Executable discovery failed: " .. first_line(raised), nil) end
	end
end
function Cli.inspect(exe, route, cb)
	Cli.run({ exe, "inspect", "--json" }, 10000, route, function(result, err, cx)
		if err ~= nil then cb(nil, err, cx); return end
		local rows, problem = Journal.inventory(result, tern.json.decode)
		cb(rows, problem, cx)
	end)
end
function Cli.identity(exe, cx, cb)
	local route, key = Cli.route(), cx:window_key()
	Cli.inspect(exe, route, function(rows, err, fresh)
		if rows == nil then cb(nil, err, fresh); return end
		local owner, problem = Journal.incarnation(key, route, rows)
		cb(owner, problem, fresh)
	end)
end
function Cli.plugins_dir(exe, route, cb)
	Cli.run({ exe, "plugin", "dir", "--json" }, 10000, route, function(result, err, cx)
		if err ~= nil then cb(nil, err, cx); return end
		local value, problem = Cli.json(result)
		if value == nil or not Discovery.absolute(value.dir) then cb(nil, problem or "Native plugin directory is not absolute", cx); return end
		cb(value.dir, nil, cx)
	end)
end
function Cli.linked(plugins_dir, id)
	local ok, names = pcall(tern.fs.list, plugins_dir)
	if not ok or type(names) ~= "table" then return nil, "Couldn't verify development-link protection" end
	for _, name in ipairs(names) do if name == id .. ".path" then return true end end
	return false
end
function Cli.parse_catalog(value)
	if type(value) ~= "table" or type(value.plugins) ~= "table" or #value.plugins > 1024
		or value.complete == false or value.truncated == true then return nil, "Native plugin catalog is incomplete" end
	local out = { plugins = {}, versions = {}, problems = false }
	local count = 0
	for index, plugin in pairs(value.plugins) do
		if type(index) ~= "number" or index % 1 ~= 0 or index < 1 or index > #value.plugins
			or type(plugin) ~= "table" or type(plugin.id) ~= "string" or #plugin.id > 128
			or type(plugin.version) ~= "string" or #plugin.version > 128 or out.plugins[plugin.id] ~= nil then
			return nil, "Native plugin catalog has ambiguous entries"
		end
		out.plugins[plugin.id] = plugin
		out.versions[plugin.id] = plugin.version
		count += 1
	end
	if count ~= #value.plugins then return nil, "Native plugin catalog has gaps" end
	if value.problems ~= nil then
		if type(value.problems) ~= "table" then return nil, "Native plugin problems are unreadable" end
		out.problems = next(value.problems) ~= nil
	end
	return out
end
function Cli.catalog(exe, route, cb)
	Cli.inspect(exe, route, function(windows, inspect_error, inspect_cx)
		if windows == nil then cb(nil, inspect_error or "Running daemon identity is unavailable", inspect_cx); return end
		Cli.run({ exe, "plugin", "list", "--json" }, 10000, route, function(result, err, cx)
			if err ~= nil then cb(nil, err, cx); return end
			local value, problem = Cli.json(result)
			if value == nil then cb(nil, problem, cx); return end
			local catalog, catalog_error = Cli.parse_catalog(value)
			if catalog ~= nil then catalog.daemon_observed = true end
			cb(catalog, catalog_error, cx)
		end)
	end)
end
function Cli.tern_version(exe, route, cb)
	Cli.run({ exe, "--version" }, 10000, route, function(result, err, cx)
		if err ~= nil or not Cli.complete(result) then cb(nil, err or "Native Tern version is unavailable", cx); return end
		cb(result.stdout, nil, cx)
	end)
end
function Cli.git_available(route, cb)
	Cli.run({ "git", "--version" }, 10000, route, function(result, err, cx)
		cb(err == nil and Cli.complete(result), cx)
	end)
end
function Cli.install_argv(exe, src)
	return { exe, "plugin", "install", src, "--force", "--json" }
end
function Cli.install(exe, src, route, cb)
	Cli.run(Cli.install_argv(exe, src), 180000, route, function(result, err, cx)
		if err ~= nil then
			cb({ status = -1, stdout = "", stderr = err, timed_out = false, spawn_failed = true }, cx)
		else cb(result, cx) end
	end)
end
local function same_argv(a, b)
	if #a ~= #b then return false end
	for index, word in ipairs(a) do if word ~= b[index] then return false end end
	return true
end
-- An uncapped inventory can prove the original native installer absent. A command
-- callback proves only that invocation ended; neither is descendant-health proof.
function Cli.process_inventory(inventory, argv, identity)
	if type(inventory) ~= "table" or inventory["local"] ~= true or type(inventory.processes) ~= "table" then
		return { operation = "unknown", reason = "Native process inventory is unavailable" }
	end
	local unknown = if inventory.more ~= 0 or inventory.total ~= #inventory.processes or type(inventory.sample) ~= "number"
		then "Native process inventory is incomplete" else nil
	local count, seen = 0, {}
	for index, process in pairs(inventory.processes) do
		if type(index) ~= "number" or index < 1 or index > #inventory.processes or index % 1 ~= 0
			or type(process) ~= "table" or type(process.pid) ~= "number" or process.pid < 1 or process.pid % 1 ~= 0
			or type(process.started) ~= "number" or process.started < 0 or seen[process.pid]
			or type(process.command) ~= "table" or #process.command == 0 then
			unknown = "Native process identity is unreadable"
			continue
		end
		seen[process.pid], count = true, count + 1
		local words, valid = 0, true
		for slot, word in pairs(process.command) do
			if type(slot) ~= "number" or slot < 1 or slot > #process.command or slot % 1 ~= 0 or type(word) ~= "string" then valid = false end
			words += 1
		end
		if not valid or words ~= #process.command then
			unknown = "Native process argv is incomplete"
			continue
		end
		local executable_name = (process.command[1] or ""):lower():gsub("\\", "/"):match("([^/]+)$")
		local installer = (executable_name == "tern" or executable_name == "tern.exe")
			and process.command[2] == "plugin" and process.command[3] == "install"
		if (argv ~= nil and same_argv(process.command, argv)) or (argv == nil and installer)
			or (identity and process.pid == identity.pid and process.started == identity.started) then
			return { operation = "running", evidence = "native_process_inventory", identity = { pid = process.pid, started = process.started } }
		end
		if installer and (process.command[4] == nil or process.command[4]:sub(1, 1) == "-") then
			unknown = "Installer argv cannot be correlated exactly"
		end
	end
	if count ~= #inventory.processes then unknown = "Native process inventory has gaps" end
	if unknown then return { operation = "unknown", reason = unknown } end
	return { operation = "stopped", evidence = "complete_native_process_inventory", sampled_at = inventory.sample }
end
function Cli.processes(cx, argv, identity, cb)
	local ok, err = pcall(function()
		cx.procs:list({ limit = 5000, sort = "pid" }):next(function(value, problem, fresh)
			if problem ~= nil then cb({ operation = "unknown", reason = "Native process inventory failed" }, fresh); return end
			cb(Cli.process_inventory(value, argv, identity), fresh)
		end)
	end)
	if not ok then cb({ operation = "unknown", reason = "Native process inventory is unavailable: " .. first_line(err) }, cx) end
end
return Cli
