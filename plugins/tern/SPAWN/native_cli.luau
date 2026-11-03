-- Native observation/readiness only. No provider launch, PATH mutation or pane input.
-- Fresh spawn metadata routes execution probes; initial inventory discovers this
-- VM's actual executable rather than borrowing an inherited pane or a PATH binary.
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
local function route_valid(route)
	return type(route) == "table" and absolute(route.executable) and absolute(route.socket)
		and window_key(route.window) and integer(route.pane)
end

function Native.from_spawn(spec)
	local env = if type(spec) == "table" then spec.env else nil
	if type(env) ~= "table" then return nil, "Fresh native spawn routing is missing" end
	local pane = if type(env.TERN_PANE) == "string" then tonumber(env.TERN_PANE) else nil
	local route = { executable = env.TERN_EXE, socket = env.TERN_PANE_SOCKET, window = env.TERN_WINDOW_KEY, pane = pane }
	if not route_valid(route) then return nil, "Fresh native executable, socket, pane or window identity is invalid" end
	return route, nil
end

-- Linux proof is this process's boot/PID/start-ticks, not an inherited shell PID.
-- Other platforms may execute fresh work, but cannot claim verified epoch recovery.
function Native.process_identity(pid)
	if tern.runtime.os ~= "linux" then return nil, "Verified process epoch is unavailable on this host" end
	if pid ~= nil and not integer(pid) then return nil, "Invalid native process id" end
	local ok, result = pcall(function()
		local stat = tern.fs.read("/proc/" .. (if pid == nil then "self" else string.format("%.0f", pid)) .. "/stat", 16384)
		local process, rest = stat:match("^(%d+) %(.+%) (.+)$")
		if process == nil or (pid ~= nil and tonumber(process) ~= pid) then error("Process identity changed") end
		local index, started = 0, nil
		for field in rest:gmatch("%S+") do index += 1; if index == 20 then started = field; break end end
		if started == nil or not started:match("^%d+$") then error("Process start ticks are missing") end
		local boot = tern.fs.read("/proc/sys/kernel/random/boot_id", 128):gsub("%s+$", "")
		if #boot ~= 36 or not boot:match("^[%x%-]+$") then error("Boot identity is invalid") end
		return boot .. ":" .. process .. ":" .. started
	end)
	if not ok then return nil, "Could not verify native process epoch: " .. tostring(result) end
	return result, nil
end
function Native.epoch()
	return Native.process_identity(nil)
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
	local route = if options ~= nil then options.route else nil
	if route ~= nil and (not route_valid(route) or window ~= route.window) then error("Native operation routing does not match its fresh host window") end
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
		local socket = if route ~= nil then route.socket else initial_socket()
		if socket ~= nil then env.TERN_DAEMON_SOCKET = socket end
		tern.process.run(argv, { timeout_ms = remaining(), env = env }, function(result, fresh)
			finish(result, if tern.now() > deadline then "Native operation deadline elapsed" else nil, fresh)
		end)
	end
	if route ~= nil then run(route.executable); return end
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
local function target(route, session, pane)
	if not route_valid(route) or not integer(session) or not integer(pane) or route.pane ~= pane then error("Native operation requires the bound host session and pane") end
	return string.format("%.0f/%.0f", session, pane)
end
function Native.process(route, session, pane, options, callback)
	local opts = { route = route, timeout_ms = if options then options.timeout_ms else 5000 }
	execute(route.window, opts, { "process", target(route, session, pane), "--json" }, callback)
end
function Native.wait_prompt(route, session, pane, options, callback)
	local timeout = if options and options.timeout_ms then options.timeout_ms else 10000
	local opts = { route = route, timeout_ms = timeout }
	execute(route.window, opts, { "wait", target(route, session, pane), "--until", "prompt", "--timeout", tostring(math.max(1, math.floor(timeout / 1000))), "--json" }, callback)
end

return Native
