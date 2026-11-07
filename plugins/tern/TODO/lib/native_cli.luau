-- Native host executable/socket discovery and bounded CLI calls. CodexBWAI; MIT.
-- Discovery is vendored with the updater; this module retains TODO's runner.
local Discovery = require("../updater/discovery")
local Native = {}
local executable = nil
local MAX_ID = 9007199254740991

local function integer(value)
	return type(value) == "number" and value >= 1 and value <= MAX_ID and value % 1 == 0
end
local function opaque(value, max, empty)
	return type(value) == "string" and #value <= max and (empty or #value > 0) and not value:find("%c")
end
local absolute = Discovery.absolute
local function window_key(value)
	return opaque(value, 256, true)
end
local function initial_socket()
	-- An explicitly selected daemon socket outranks inherited environment. This
	-- read is metadata of the calling Tern process, never another pane's environ.
	if tern.runtime.os == "linux" then
		local ok, command = pcall(tern.fs.read, "/proc/self/cmdline", 32768)
		if ok then
			local daemon, next_socket = false, false
			for word in command:gmatch("[^%z]+") do
				if next_socket then return if absolute(word) then word else nil end
				if word == "daemon" then daemon = true end
				if daemon and word == "--socket" then next_socket = true end
				if daemon and word:sub(1, 9) == "--socket=" then
					local value = word:sub(10); return if absolute(value) then value else nil
				end
			end
		end
	end
	local value = tern.getenv("TERN_DAEMON_SOCKET")
	return if absolute(value) then value else nil
end
local function discovery_argv()
	return Discovery.argv(tern.runtime.os, tern.getenv("SystemRoot") or tern.getenv("WINDIR"))
end

local function execute(window, options, arguments, callback)
	if window ~= nil and not window_key(window) then error("Native inspection requires an opaque native window key") end
	if type(callback) ~= "function" then error("Native operation requires a callback") end
	local timeout = if options == nil or options.timeout_ms == nil then 5000 else options.timeout_ms
	if type(timeout) ~= "number" or timeout ~= timeout or timeout == math.huge or timeout < 1 or timeout > 60000 then error("Native operation requires timeout_ms between 1 and 60000") end

	local deadline, completed = tern.now() + timeout, false
	local function finish(result, err, fresh)
		if completed then return end
		completed = true
		callback(result, err, fresh)
	end
	local function remaining()
		local value = math.floor(deadline - tern.now())
		if value < 1 then error("Native operation deadline elapsed before the process could start") end
		return value
	end
	local function run(path)
		local argv = { path }
		for _, word in ipairs(arguments) do table.insert(argv, word) end
		if window ~= nil then table.insert(argv, "--window"); table.insert(argv, window) end
		local env = { TERN_PANE = "", TERN_PANE_SOCKET = "", TERN_WINDOW_KEY = "", TERN_WINDOW_SOCKET = "" }
		local socket = initial_socket()
		if socket ~= nil then env.TERN_DAEMON_SOCKET = socket end
		tern.process.run(argv, { timeout_ms = remaining(), env = env }, function(result, fresh)
			finish(result, if tern.now() > deadline then "Native operation deadline elapsed" else nil, fresh)
		end)
	end
	if executable ~= nil then run(executable); return end
	local argv, problem = discovery_argv()
	if argv == nil then error(problem) end
	tern.process.run(argv, { timeout_ms = remaining() }, function(result, fresh)
		if result.timed_out or tern.now() > deadline then finish(nil, "Native executable discovery exceeded its deadline", fresh); return end
		if result.status ~= 0 then finish(nil, "Could not locate the running Tern executable: status " .. tostring(result.status) .. " · " .. result.stderr:sub(1, 2048), fresh); return end
		local path, path_error = Discovery.path(result.stdout)
		if path == nil then finish(nil, path_error, fresh); return end
		executable = path
		local ok, err = pcall(run, path)
		if not ok then finish(nil, "Could not start native operation: " .. tostring(err), fresh) end
	end)
end

-- Existing inventory callback contract is retained: (ProcessResult?, error?, freshCx?).
function Native.inspect(window, options, callback)
	execute(window, options, { "inspect", "--json" }, callback)
end
function Native.process(window, session, pane, options, callback)
    if not integer(session) or not integer(pane) then error("Invalid native session or pane") end
    execute(window, options, {"process", string.format("%.0f/%.0f", session, pane), "--json"}, callback)
end
return Native
