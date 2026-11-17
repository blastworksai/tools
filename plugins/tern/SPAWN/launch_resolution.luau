-- Shared configuration/argv/identity resolution, without shell observation or effects.
-- Ordinary resume and managed fresh contracts are explicit; prompts and quoting
-- belong to their executors. Select the local user after inserting any prompt.
local Config = require("./config")
local Resolution = {}
local function nonblank(value: any): boolean
	return type(value) == "string" and value:find("%S") ~= nil
end
local function text(value: any, limit: number): boolean
	return type(value) == "string" and #value <= limit and not value:find("%z") and utf8.len(value) ~= nil
end
local function command_words(command: string, shell: string): ({string}?, string?)
	-- Windows paths are literal; POSIX command parsing would eat backslashes.
	-- Ordinary SSH still targets the released POSIX shell contract.
	if shell == "powershell" and command:find("\\", 1, true) then
		local path = command:match('^"(.*)"$') or command:match("^'(.*)'$") or command
		local lower = path:lower()
		if lower:match("%.exe$") or lower:match("%.cmd$") or lower:match("%.bat$") or lower:match("%.ps1$") then return { path }, nil end
		return nil, "Use an exact Windows executable path and put its arguments in Arguments"
	end
	return Config.parse_arguments(command)
end
-- Setup has no ordinary record or argv reinterpretation. Native agents:start
-- consumes the effective Tern command verbatim and owns prompt delivery.
function Resolution.setup_default(command: any, cwd: any, host_os: any): (any?, string?)
	if not nonblank(command) then return nil, "Set a default agent in Tern settings, then try setup again." end
	if not text(command,32000) or not text(cwd,8192) or not nonblank(cwd) or cwd:find("%c")
		or not (cwd:sub(1,1)=="/" or cwd:match("^%a:[/\\]") or cwd:sub(1,2)=="\\\\") then
		return nil, "Guided setup needs the exact default command and an absolute execution-host working directory"
	end
	-- This selects the explicitly named helper interpreter, not the shell or
	-- provider behind the user-trusted command. ComSpec is not PowerShell proof.
	local shell=if host_os=="windows" then "powershell" elseif host_os=="linux" or host_os=="macos" then "posix" else nil
	if shell==nil then return nil, "The execution host platform has no supported explicit setup submission helper" end
	return {command=command,cwd=cwd,shell=shell},nil
end
function Resolution.fresh_available(record: any): boolean
	if record.fresh_native_default == true then
		return record.backend == "native-agent" and string.lower(record.provider) == "omp" and record.model == nil and record.profile == nil
	end
	return record.fresh_executable ~= nil and record.fresh_arguments ~= nil
end
function Resolution.resolve(source: any, mode: string, shell: string): (any?, string?)
	if mode ~= "ordinary" and mode ~= "fresh" then return nil, "Choose ordinary or fresh launch resolution explicitly" end
	local record, err = Config.validate_record(source)
	if record == nil then return nil, err end
	if record.review_required then return nil, record.review_reason end
	local executable, argv
	if mode == "fresh" then
		if not Resolution.fresh_available(record) then return nil, "No explicit fresh executable/argv contract for this record" end
		if record.fresh_native_default then executable, argv = "omp", {} else executable, argv = record.fresh_executable, table.clone(record.fresh_arguments) end
	else
		if not nonblank(record.command) then return nil, "Review this account's launch command" end
		local words, parse_error = command_words(record.command, if record.backend == "ssh-command" then "posix" else shell)
		if words == nil or #words == 0 then return nil, parse_error or "Command is empty" end
		executable = table.remove(words, 1)
		argv = words
		for _, argument in ipairs(record.arguments) do table.insert(argv, argument) end
	end
	return { record = record, executable = executable, arguments = argv }, nil
end
-- A bare `sudo -u account -- cli` reads none of the account's login files, so PATH additions such as
-- ~/.local/bin and tokens exported in ~/.profile are missing. The account's login shell is entered, chosen
-- from its passwd entry (getent, or dscl on macOS) and never from the environment, which sudo may preserve.
-- `sudo -i` is not used: it leaves `$` unescaped for the login shell, so `$HOME` in an argument would expand.
-- The approved program and arguments travel as one fully single-quoted command text, run by the login shell
-- AFTER its profile: a profile can neither move the folder (the launch folder is restored from $0) nor replace
-- the argv (the text does not use positional parameters). Every lookup runs with a fixed PATH set first, so a
-- caller-controlled PATH (sudoers without secure_path) cannot supply getent; the login shell's own profile then
-- builds the real PATH, and the plain /bin/sh fallback gets the original PATH back. A shell that is not a known one (nologin, false) or
-- a missing passwd tool falls back to /bin/sh with the same text, as before the login shell was added.
local LOGIN_SCRIPT = [==[o=$PATH; PATH=/usr/bin:/bin:/usr/sbin:/sbin; export PATH; u=$(id -un); d=$PWD; sh=$(getent passwd "$u" 2>/dev/null | cut -d: -f7); [ -n "$sh" ] || sh=$(dscl . -read "/Users/$u" UserShell 2>/dev/null | sed -n 's/^UserShell: //p'); case "${sh##*/}" in bash|zsh|sh|dash|ksh) [ -x "$sh" ] && exec "$sh" -lc "$1" "$d";; esac; PATH=$o; export PATH; exec /bin/sh -c "$1" "$d"]==]
local SHELL_TARGETS = { sh = true, bash = true, dash = true, zsh = true, ksh = true }
local function sh_quote(word: string): string
	return "'" .. (string.gsub(word, "'", "'\\''")) .. "'"
end
-- Replaces argv[at..] (the program and its arguments) with the login wrapper carrying them as quoted text.
-- A program named like an option would be read by `exec` as one, so it is never wrapped (callers refuse it).
local function login_wrap(argv: {string}, at: number)
	local quoted = {}
	for index = at, #argv do table.insert(quoted, sh_quote(argv[index])) end
	for index = #argv, at, -1 do argv[index] = nil end
	for _, word in ipairs({ "/bin/sh", "-c", LOGIN_SCRIPT, "spawn-login", 'cd -- "$0" || exit 1; exec ' .. table.concat(quoted, " ") }) do table.insert(argv, word) end
end
local SUDO_FLAGS = { ["-H"] = true, ["-n"] = true, ["-E"] = true, ["-i"] = true, ["-s"] = true, ["-S"] = true, ["-k"] = true, ["-K"] = true, ["-b"] = true, ["-P"] = true }
-- Literal sudo argv: the selected account, the index of the target program, whether it is already a login shell.
local function parse_sudo(argv: {string}): (string?, number, boolean, string?)
	local selected, index, login = nil, 1, false
	while index <= #argv do
		local argument = argv[index]
		if argument == "--" then index += 1; break end
		if argument:sub(1, 1) ~= "-" then break end
		local selector = argument:match("^%-%-user=(.+)$") or argument:match("^%-u(.+)$")
		if argument == "-u" or argument == "--user" then index += 1; selector = argv[index] end
		if selector ~= nil then
			if selected ~= nil then return nil, index, login, "Configured sudo has ambiguous OS-user selectors" end
			selected = selector
		elseif not SUDO_FLAGS[argument] then
			return nil, index, login, "Configured sudo identity options require review"
		elseif argument == "-i" or argument == "-s" then
			login = true
		end
		index += 1
	end
	return selected, index, login, nil
end
function Resolution.select_user(resolved: any, shell: string, noninteractive: boolean?): (boolean, string?)
	local record, executable, argv = resolved.record, resolved.executable, resolved.arguments
	if record.backend == "ssh-command" then return true, nil end
	local configured = nonblank(record.user)
	if not configured then
		-- No configured user: a reviewed literal sudo form (one selector, a target program) still enters the
		-- login shell; anything else keeps its argv exactly as approved.
		if shell ~= "posix" or executable:match("([^/]+)$") ~= "sudo" then return true, nil end
		local selected, index, login = parse_sudo(argv)
		if selected == nil or argv[index] == nil or argv[index] == "" or argv[index]:find("=", 1, true) or argv[index]:sub(1, 1) == "-" then return true, nil end
		if not login and not SHELL_TARGETS[argv[index]:match("([^/]+)$")] then login_wrap(argv, index) end
		if noninteractive then table.insert(argv, 1, "-n") end
		return true, nil
	end
	if shell ~= "posix" then return false, "Windows OS-user launch is unsupported; no current-user fallback" end
	if executable:match("([^/]+)$") == "sudo" then
		-- Stop at the target executable: its arguments are not sudo options.
		-- Unknown options can consume argv or change identity, so require review.
		local selected, index, login, problem = parse_sudo(argv)
		if problem ~= nil then return false, problem end
		if selected ~= record.user or argv[index] == nil or argv[index] == "" or argv[index]:find("=", 1, true) then
			return false, "Configured sudo does not explicitly select the configured OS user"
		end
		if argv[index]:sub(1, 1) == "-" then return false, "The program name must not start with -" end
		if not login and not SHELL_TARGETS[argv[index]:match("([^/]+)$")] then login_wrap(argv, index) end
		if noninteractive then table.insert(argv,1,"-n") end
	else
		if executable:sub(1, 1) == "-" then return false, "The program name must not start with -" end
		local wrapped = { "-u", record.user, "-H", "--", executable }
		for _, argument in ipairs(argv) do table.insert(wrapped, argument) end
		if not SHELL_TARGETS[executable:match("([^/]+)$")] then login_wrap(wrapped, 5) end
		if noninteractive then table.insert(wrapped,1,"-n") end
		resolved.executable, resolved.arguments = "sudo", wrapped
	end
	return true, nil
end
local function ssh_user(value: any): boolean
	return text(value, 256) and nonblank(value) and not value:find("[%s%c@]") and value:sub(1, 1) ~= "-"
end
function Resolution.ssh_arguments(record: any, remote: string, interactive: boolean?): ({string}?, string?)
	if not text(record.host, 4096) or not nonblank(record.host) or record.host:find("[%s%c]") or record.host:sub(1, 1) == "-" then return nil, "SSH destination is invalid" end
	local destination = record.host
	local embedded, host = destination:match("^(.-)@(.*)$")
	if embedded ~= nil and (not ssh_user(embedded) or host == "" or host:sub(1, 1) == "-" or host:find("@", 1, true)) then return nil, "SSH destination identity is invalid" end
	if nonblank(record.user) then
		if not ssh_user(record.user) then return nil, "SSH user is invalid" end
		if embedded ~= nil then return nil, "SSH destination and user contain ambiguous identity selectors" end
		destination = record.user .. "@" .. destination
	elseif record.user ~= nil and type(record.user) ~= "string" then
		return nil, "SSH user is invalid"
	end
	local args = {}
	if interactive then table.insert(args, "-t") end
	if nonblank(record.key_path) then table.insert(args, "-i"); table.insert(args, record.key_path) end
	-- Do not bypass host-key verification or invent authentication options.
	table.insert(args, "--"); table.insert(args, destination); table.insert(args, remote)
	return args, nil
end
return Resolution
