-- Runs the running Tern executable for the updater (window half only).
-- Executable discovery is shared; this window runner retains its own callback/cache semantics.
-- No `--window` flag and no PATH in `env`: every call acts on this machine's
-- plugins folder, and the folder watch reloads this machine's daemon and windows.
local Cli = {}
local Discovery = require("./discovery")
local absolute = Discovery.absolute

local executable = nil
local waiting = nil


-- The window's own STENCIL_LOG is inherited; it would put the CLI's log lines in front
-- of the real error on stderr, so Tern CLI calls run with logging off.
local QUIET = { STENCIL_LOG = "off" }

-- Runs argv; cb(result, nil, cx) on completion, or cb(nil, err) when the spawn raised.
-- Every callback below also passes the fresh window cx (nil after a spawn error) last.
local function run(argv, timeout_ms, cb, env)
	local ok, err = pcall(tern.process.run, argv, { timeout_ms = timeout_ms, env = env }, function(result, cx)
		cb(result, nil, cx)
	end)
	if not ok then cb(nil, "Couldn't start " .. tostring(argv[1]) .. ": " .. tostring(err), nil) end
end

local function first_line(text)
	return (tostring(text or ""):match("[^\r\n]+") or ""):sub(1, 200)
end

function Cli.executable(cb)
	if executable ~= nil then cb(executable, nil); return end
	if waiting ~= nil then table.insert(waiting, cb); return end
	local system = if tern.runtime.os == "windows" then tern.getenv("SystemRoot") or tern.getenv("WINDIR") else nil
	local argv, problem = Discovery.argv(tern.runtime.os, system)
	if argv == nil then cb(nil, problem); return end
	waiting = { cb }
	run(argv, 10000, function(result, err, cx)
		local path = nil
		if err == nil then
			if result.timed_out then
				err = "Tern executable discovery timed out"
			elseif result.status ~= 0 then
				err = "Couldn't locate the running Tern executable: status " .. tostring(result.status) .. " · " .. first_line(result.stderr)
			else
				path, err = Discovery.path(result.stdout)
			end
		end
		if path ~= nil then executable = path end
		local callbacks = waiting or {}
		waiting = nil
		for _, callback in callbacks do callback(path, err, cx) end
	end)
end

local function decode(text)
	local ok, value = pcall(tern.json.decode, text)
	if ok and type(value) == "table" then return value end
	return nil
end

function Cli.plugins_dir(exe, cb)
	run({ exe, "plugin", "dir", "--json" }, 10000, function(result, err, cx)
		if err ~= nil then cb(nil, err, cx); return end
		if result.status ~= 0 then cb(nil, "tern plugin dir failed: " .. first_line(result.stderr), cx); return end
		local value = decode(result.stdout)
		if value == nil or not absolute(value.dir) then cb(nil, "tern plugin dir gave no absolute dir", cx); return end
		cb(value.dir, nil, cx)
	end, QUIET)
end

function Cli.linked(plugins_dir, id)
	local ok, exists = pcall(tern.fs.exists, plugins_dir .. "/" .. id .. ".path")
	return ok and exists == true
end

function Cli.tern_version(exe, cb)
	run({ exe, "--version" }, 10000, function(result, err, cx)
		if err ~= nil or result.status ~= 0 then cb(nil, cx); return end
		cb(result.stdout, cx)
	end, QUIET)
end

function Cli.plugin_versions(exe, cb)
	run({ exe, "plugin", "list", "--json" }, 10000, function(result, err, cx)
		if err ~= nil then cb(nil, err, cx); return end
		if result.status ~= 0 then cb(nil, "tern plugin list failed: " .. first_line(result.stderr), cx); return end
		local value = decode(result.stdout)
		if value == nil or type(value.plugins) ~= "table" then cb(nil, "tern plugin list gave no plugins", cx); return end
		local map = {}
		for _, plugin in value.plugins do
			if type(plugin) == "table" and type(plugin.id) == "string" and type(plugin.version) == "string" then
				map[plugin.id] = plugin.version
			end
		end
		cb(map, nil, cx)
	end, QUIET)
end

function Cli.git_available(cb)
	run({ "git", "--version" }, 10000, function(result, err, cx)
		cb(err == nil and result.status == 0, cx)
	end)
end

-- cb(result, cx): a spawn failure arrives as status -1 with the error as stderr.
function Cli.install(exe, src, cb)
	run({ exe, "plugin", "install", src, "--force", "--json" }, 180000, function(result, err, cx)
		if err ~= nil then
			cb({ status = -1, stdout = "", stderr = err, timed_out = false }, cx)
			return
		end
		cb(result, cx)
	end, QUIET)
end

return Cli
