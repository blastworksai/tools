-- Native host executable/socket discovery and bounded CLI calls. CodexBWAI; MIT.
-- Reused from this repository’s reviewed SPAWN/native_cli.luau. No pane input.
local Native = {}
local executable = nil
local MAX_ID = 9007199254740991

local function integer(value)
	return type(value) == "number" and value >= 1 and value <= MAX_ID and value % 1 == 0
end
local function opaque(value, max, empty)
	return type(value) == "string" and #value <= max and (empty or #value > 0) and not value:find("%c")
end
local function absolute(value)
	return opaque(value, 4096, false) and (value:sub(1, 1) == "/" or value:match("^%a:[/\\]") ~= nil or value:sub(1, 2) == "\\\\")
end
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
	if tern.runtime.os == "linux" then return { "/bin/sh", "-c", '/usr/bin/readlink /proc/$PPID/exe' }, nil end
	if tern.runtime.os == "macos" then return { "/bin/sh", "-c", '/bin/ps -p "$PPID" -o comm=' }, nil end
	if tern.runtime.os == "windows" then
		local system = tern.getenv("SystemRoot") or tern.getenv("WINDIR")
		if not absolute(system) then return nil, "The host's absolute Windows system directory is unavailable" end
		return { system .. "\\System32\\WindowsPowerShell\\v1.0\\powershell.exe", "-NoLogo", "-NoProfile", "-NonInteractive", "-Command",
			"$ErrorActionPreference='Stop'; $self=Get-CimInstance Win32_Process -Filter ('ProcessId='+$PID); $parent=Get-CimInstance Win32_Process -Filter ('ProcessId='+$self.ParentProcessId); [Console]::WriteLine($parent.ExecutablePath)" }, nil
	end
	return nil, "Native executable discovery is not verified on this host"
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
		local path = result.stdout:gsub("\r?\n$", "")
		if not absolute(path) then finish(nil, "Native executable discovery did not return one absolute path", fresh); return end
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
