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
local SUDO_FLAGS = { ["-H"] = true, ["-n"] = true, ["-E"] = true, ["-i"] = true, ["-s"] = true, ["-S"] = true, ["-k"] = true, ["-K"] = true, ["-b"] = true, ["-P"] = true }
function Resolution.select_user(resolved: any, shell: string): (boolean, string?)
	local record, executable, argv = resolved.record, resolved.executable, resolved.arguments
	if record.backend == "ssh-command" or not nonblank(record.user) then return true, nil end
	if shell ~= "posix" then return false, "Windows OS-user launch is unsupported; no current-user fallback" end
	if executable:match("([^/]+)$") == "sudo" then
		-- Stop at the target executable: its arguments are not sudo options.
		-- Unknown options can consume argv or change identity, so require review.
		local selected, index = nil, 1
		while index <= #argv do
			local argument = argv[index]
			if argument == "--" then index += 1; break end
			if argument:sub(1, 1) ~= "-" then break end
			local selector = argument:match("^%-%-user=(.+)$") or argument:match("^%-u(.+)$")
			if argument == "-u" or argument == "--user" then index += 1; selector = argv[index] end
			if selector ~= nil then
				if selected ~= nil then return false, "Configured sudo has ambiguous OS-user selectors" end
				selected = selector
			elseif not SUDO_FLAGS[argument] then
				return false, "Configured sudo identity options require review"
			end
			index += 1
		end
		if selected ~= record.user or argv[index] == nil or argv[index] == "" or argv[index]:find("=", 1, true) then
			return false, "Configured sudo does not explicitly select the configured OS user"
		end
	else
		local wrapped = { "-u", record.user, "-H", "--", executable }
		for _, argument in ipairs(argv) do table.insert(wrapped, argument) end
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
