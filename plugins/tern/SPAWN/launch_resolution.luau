-- Shared configuration/argv/identity resolution, without shell observation or effects.
-- Ordinary resume and managed fresh contracts are explicit; prompts and quoting
-- belong to their executors. Select the local user after inserting any prompt.
local Config = require("./config")
local Selectors = require("./selectors")
local Resolution = {}
local function nonblank(value: any): boolean
	return type(value) == "string" and value:find("%S") ~= nil
end
local function text(value: any, limit: number): boolean
	return type(value) == "string" and #value <= limit and not value:find("%z") and utf8.len(value) ~= nil
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
		return record.backend == "native-agent" and string.lower(record.provider) == "omp" and record.profile == nil
	end
	return record.fresh_executable ~= nil and record.fresh_arguments ~= nil
end
-- Model and effort flags come from the record's fields through one capability table.
-- A record with neither field keeps its argv exactly. The flags go at the task slot (or the
-- end), after any sudo wrapper, and move the slot so the task text still lands where it was set.
local function derive(record: any, executable: string, argv: { string }, slot: number?): ({ string }, number?, string?)
	if not Config.selectors_active(record) then return argv, slot, nil end
	-- The CLI is the record's provider (SKILLS-213), never the program's file name; the program's own
	-- option region (after a literal sudo is unwrapped) is still where the flags go.
	local _, first = Config.program_of(executable, argv)
	local key = Selectors.provider_key(record.provider)
	-- A requested model or effort is never dropped silently: a provider outside the seven refuses.
	if key == nil then return argv, slot, "Model and effort need a known CLI as the provider (Claude, Codex, Kimi, Grok, Agy, Muse or OMP). The provider is " .. tostring(record.provider) .. "; clear model and effort, or set the provider to the CLI this agent runs." end
	-- A flag the saved arguments already carry in the program's option region wins: never a second copy.
	local region = Selectors.region(argv, first)
	local model = if record.model_selector == true then record.model else nil
	local effort = record.effort
	if model ~= nil and Selectors.duplicate(key, region, model, nil) then model = nil end
	if effort ~= nil and Selectors.duplicate(key, region, nil, effort) then effort = nil end
	local flags = Selectors.flags(key, model, effort)
	if #flags == 0 then return argv, slot, nil end
	local applied, moved = Selectors.apply(argv, flags, slot, first)
	return applied, moved, nil
end
-- Fresh terminal argv with the derived flags and the matching task slot, for callers that
-- insert the task themselves and compare what actually started.
function Resolution.fresh_argv(record: any): ({ string }, number?)
	local argv, slot = derive(record, record.fresh_executable or "", table.clone(record.fresh_arguments or {}), if record.backend == "native-agent" then nil else record.task_argument_index)
	return argv, slot
end
function Resolution.resolve(source: any, mode: string, shell: string): (any?, string?)
	if mode ~= "ordinary" and mode ~= "fresh" then return nil, "Choose ordinary or fresh launch resolution explicitly" end
	local record, err = Config.validate_record(source)
	if record == nil then return nil, err end
	if record.review_required then return nil, record.review_reason end
	local executable, argv, slot
	if mode == "fresh" then
		if not Resolution.fresh_available(record) then return nil, "No explicit fresh executable/argv contract for this record" end
		if record.fresh_native_default then executable, argv = "omp", {} else executable, argv = record.fresh_executable, table.clone(record.fresh_arguments) end
		if record.backend ~= "native-agent" then slot = record.task_argument_index end
		local derive_error
		argv, slot, derive_error = derive(record, executable, argv, slot)
		if derive_error ~= nil then return nil, derive_error end
	else
		if not nonblank(record.command) then return nil, "Review this account's launch command" end
		local words, parse_error = Config.command_words(record.command, if record.backend == "ssh-command" then "posix" else shell)
		if words == nil or #words == 0 then return nil, parse_error or "Command is empty" end
		executable = table.remove(words, 1)
		argv = words
		for _, argument in ipairs(record.arguments) do table.insert(argv, argument) end
		local derive_error
		argv, _, derive_error = derive(record, executable, argv, nil)
		if derive_error ~= nil then return nil, derive_error end
	end
	return { record = record, executable = executable, arguments = argv, task_argument_index = slot }, nil
end
-- A bare `sudo -u account -- cli` reads none of the account's login files, so PATH additions such as
-- ~/.local/bin, /usr/local/bin and tokens exported in ~/.profile are missing. The launch therefore takes the road
-- the owner walks by hand: `sudo -i -u account`, then `cd <folder>`, then `exec <program> <arguments>`. sudo -i
-- enters the account's own login shell (named by the account database, with sudo's secure_path and the account's
-- profiles), so no shell discovery, PATH override or getent/dscl call is needed here.
-- sudo -i does not pass its command through untouched: it backslash-escapes every byte except letters, digits,
-- `_`, `-` and `$`, drops an escaped newline, and leaves `$` live, so the login shell would expand `$HOME` in an
-- argument. Only words that are plain data survive that, so the approved program and arguments travel as ONE
-- word of single-quoted shell text in which `\`, `$`, `%` and newline are replaced by octal escapes. A constant
-- /bin/sh script (written without `$` before a live character, so the login shell leaves it alone) decodes the
-- word with printf and evals it, which ends in `exec`. sudo -i starts in the account's home, so the launch folder
-- is carried too: inside the text when the caller knows it, or, when the line is typed into the pane that already
-- stands there, as a marker word the renderers turn into the typing shell's own octal encoding of "$PWD" (computed
-- in the first shell pass, before sudo, so a dollar or newline in a folder name reaches the login shell as data).
Resolution.PWD = "\0spawn-pwd"
local LOGIN_SCRIPT = [==[eval "$(printf "${1}")"]==]
-- ${1} is the pane folder as \ooo escapes; the sentinel x keeps printf's command substitution from eating a trailing newline.
local LOGIN_SCRIPT_PWD = [==[d=$(printf "${1}x"); [ "${d}" != x ] || exit 1; cd -- "${d%x}" || exit 1; eval "$(printf "${2}")"]==]
local function octal(text: string): string
	return (string.gsub(text, "[\\$%%\n]", function(char) return string.format("\\%03o", string.byte(char)) end))
end
local SHELL_TARGETS = { sh = true, bash = true, dash = true, zsh = true, ksh = true }
local function sh_quote(word: string): string
	return "'" .. (string.gsub(word, "'", "'\\''")) .. "'"
end
-- Replaces argv[at..] (the program and its arguments) with the login wrapper carrying them as encoded text, and
-- makes the sudo call a login (`-i`). A program named like an option would be read by `exec` as one, so it is
-- never wrapped (callers refuse it).
local function login_wrap(argv: {string}, at: number, cwd: string?)
	local quoted = {}
	for index = at, #argv do table.insert(quoted, sh_quote(argv[index])) end
	for index = #argv, at, -1 do argv[index] = nil end
	local text = "exec " .. table.concat(quoted, " ")
	local words
	if cwd ~= nil then
		words = { "/bin/sh", "-c", LOGIN_SCRIPT, "spawn-login", octal("cd -- " .. sh_quote(cwd) .. " && " .. text) }
	else
		words = { "/bin/sh", "-c", LOGIN_SCRIPT_PWD, "spawn-login", Resolution.PWD, octal(text) }
	end
	for _, word in ipairs(words) do table.insert(argv, word) end
end
-- The same login road for a fixed prerequisite or helper command (preparation checks), so a tool found on the
-- account's login PATH at discovery is the one preparation finds. The folder is the root: these commands read no
-- relative path, and sudo -i would otherwise start them in the account's home.
function Resolution.login_argv(user: string, argv: {string}, cwd: string?): {string}
	local wrapped = table.clone(argv)
	login_wrap(wrapped, 1, cwd or "/")
	local out = { "sudo", "-n", "-i", "-u", user, "--" }
	for _, word in ipairs(wrapped) do table.insert(out, word) end
	return out
end
-- One parser for literal sudo forms, shared with record validation so the two cannot disagree.
local parse_sudo = Config.parse_sudo
function Resolution.select_user(resolved: any, shell: string, noninteractive: boolean?, cwd: string?): (boolean, string?)
	local record, executable, argv = resolved.record, resolved.executable, resolved.arguments
	if record.backend == "ssh-command" then return true, nil end
	local configured = nonblank(record.user)
	if not configured then
		-- No configured user: a reviewed literal sudo form (one selector, a target program) still enters the
		-- login shell; anything else keeps its argv exactly as approved.
		if shell ~= "posix" or executable:match("([^/]+)$") ~= "sudo" then return true, nil end
		local selected, index, login = parse_sudo(argv)
		if selected == nil or argv[index] == nil or argv[index] == "" or argv[index]:find("=", 1, true) or argv[index]:sub(1, 1) == "-" then return true, nil end
		if not login and not SHELL_TARGETS[argv[index]:match("([^/]+)$")] then login_wrap(argv, index, cwd); table.insert(argv, 1, "-i") end
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
		if not login and not SHELL_TARGETS[argv[index]:match("([^/]+)$")] then login_wrap(argv, index, cwd); table.insert(argv, 1, "-i") end
		if noninteractive then table.insert(argv,1,"-n") end
	else
		if executable:sub(1, 1) == "-" then return false, "The program name must not start with -" end
		local wrapped = { "-u", record.user, "--", executable }
		for _, argument in ipairs(argv) do table.insert(wrapped, argument) end
		if not SHELL_TARGETS[executable:match("([^/]+)$")] then login_wrap(wrapped, 4, cwd); table.insert(wrapped, 1, "-i") end
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
