-- Managed fresh-launch/setup construction and canonical serializer/mailbox helpers.
-- Ordinary launches use host_executor tickets; only resolution is shared.
local Resolution = require("./launch_resolution")
local Config = require("./config")
local Backend = {}
local POSIX_LIMIT, WINDOWS_LIMIT = 32768, 7000

local function text(value: any, limit: number): boolean
	return type(value) == "string" and #value <= limit and not value:find("%z") and utf8.len(value) ~= nil
end
local function nonblank(value: any): boolean
	return type(value) == "string" and value:find("%S") ~= nil
end
function Backend.posix_quote(value: string): string
	-- The one marker word of an OS-user launch typed into the pane that already stands in the launch folder (records cannot hold NUL).
	-- The typing shell encodes $PWD as \ooo octal escapes, so sudo -i and the login shell only ever see safe characters.
	if value == Resolution.PWD then return [==["$(printf %s "$PWD" | od -An -v -to1 | tr -s ' \n' '\n\n' | sed '/^$/d;s/^/\\/' | tr -d '\n')"]==] end
	return "'" .. value:gsub("'", "'\\''") .. "'"
end
function Backend.powershell_quote(value: string): string
	return "'" .. value:gsub("'", "''") .. "'"
end
function Backend.windows_argument(value: string): string
	local escaped = value:gsub('(\\*)"', function(slashes) return slashes .. slashes .. '\\"' end)
	escaped = escaped:gsub("(\\+)$", "%1%1")
	return '"' .. escaped .. '"'
end
function Backend.utf16le(value: string): (string?, string?)
	if utf8.len(value) == nil then return nil, "Invalid UTF-8" end
	local bytes = {}
	for _, code in utf8.codes(value) do
		if code >= 65536 then
			code -= 65536
			local high, low = 55296 + math.floor(code / 1024), 56320 + code % 1024
			table.insert(bytes, string.char(high % 256, math.floor(high / 256), low % 256, math.floor(low / 256)))
		else
			table.insert(bytes, string.char(code % 256, math.floor(code / 256)))
		end
	end
	return table.concat(bytes), nil
end
function Backend.shell_kind(os: string, shell: string): (string?, string?)
	if os ~= "linux" and os ~= "macos" and os ~= "windows" then return nil, "Unsupported execution OS" end
	if not text(shell, 4096) then return nil, "Execution shell is required" end
	local name = shell:lower():gsub("\\", "/"):match("([^/]+)$") or ""
	if os == "windows" and (name == "pwsh" or name == "pwsh.exe" or name == "powershell" or name == "powershell.exe" or name == "cmd" or name == "cmd.exe") then return "powershell", nil end
	if os ~= "windows" and (name == "posix" or name == "sh" or name == "bash" or name == "zsh" or name == "dash" or name == "ksh") then return "posix", nil end
	return nil, "Execution shell is not supported for literal argv"
end
local function bounded(command: string, os: string): (string?, string?)
	if #command > (if os == "windows" then WINDOWS_LIMIT else POSIX_LIMIT) then return nil, "Encoded command exceeds the platform limit" end
	return command, nil
end
local CMD_META = {}
for char in string.gmatch('()[]%!^"`<>&|;, *?', ".") do CMD_META[char] = true end
function Backend.cmd_escape(value: string): string
	return (value:gsub(".", function(char) return if CMD_META[char] then "^" .. char else char end))
end
-- This reviewed wrapper is fixed code. The only interpolated bytes are standard
-- Base64 of a separate UTF-8 JSON object, never executable task/report text.
-- ProcessStartInfo avoids PowerShell 5's lossy native argv binding. Batch launch
-- retains the baseline double cmd escaping; native executables use CRT escaping.
local POWERSHELL_PREFIX = "$ErrorActionPreference='Stop';try{$d=[Text.Encoding]::UTF8.GetString([Convert]::FromBase64String('"
local POWERSHELL_SUFFIX = "'))|ConvertFrom-Json;if($d.cwd){Set-Location -LiteralPath $d.cwd};$f=@(Get-Command -Name ([Management.Automation.WildcardPattern]::Escape($d.executable)) -CommandType Application,ExternalScript -ErrorAction Stop);if($f.Count -ne 1){throw 'Executable is ambiguous'};$file=$f[0].Source;$ext=[IO.Path]::GetExtension($file).ToLowerInvariant();$p=New-Object Diagnostics.ProcessStartInfo;$p.UseShellExecute=$false;$p.WorkingDirectory=(Get-Location).ProviderPath;if($ext -eq '.cmd' -or $ext -eq '.bat'){$p.FileName=[IO.Path]::Combine([Environment]::GetFolderPath('System'),'cmd.exe');$p.Arguments='/d /v:off /s /c \"'+[regex]::Replace($file,'([()\\[\\]%!^\"`<>&|;, *?])','^$1')+' '+$d.batch+'\"'}elseif($ext -eq '.ps1'){$engine=if($PSVersionTable.PSEdition -eq 'Desktop'){'powershell.exe'}else{'pwsh.exe'};$p.FileName=[IO.Path]::Combine($PSHOME,$engine);$p.Arguments='-NoLogo -NoProfile -File \"'+$file+'\" '+$d.arguments}else{$p.FileName=$file;$p.Arguments=$d.arguments};$child=[Diagnostics.Process]::Start($p);$child.WaitForExit();$code=$child.ExitCode;$child.Dispose();exit $code}catch{[Console]::Error.WriteLine($_.Exception.Message);exit 1}"
-- Managed CRT executables need neither shell-script discovery nor a duplicate
-- cmd-escaped argument payload. Console handles remain inherited.
local CRT_SUFFIX = "'))|ConvertFrom-Json;$p=New-Object Diagnostics.ProcessStartInfo;$p.UseShellExecute=$false;$p.FileName=$d.executable;$p.Arguments=$d.arguments;$p.WorkingDirectory=if($d.cwd){$d.cwd}else{(Get-Location).ProviderPath};$c=[Diagnostics.Process]::Start($p);$c.WaitForExit();$code=$c.ExitCode;$c.Dispose();exit $code}catch{[Console]::Error.WriteLine($_.Exception.Message);exit 1}"

function Backend.serialize(executable: string, args: {string}, cwd: string?, os: string, shell: string, crt_only: boolean?): (string?, string?)
	local kind, err = Backend.shell_kind(os, shell)
	if kind == nil then return nil, err end
	if not text(executable, POSIX_LIMIT) or not nonblank(executable) then return nil, "Executable must be literal nonempty UTF-8 text" end
	if type(args) ~= "table" or #args > 257 then return nil, "Invalid argument array" end
	local count = 0
	for key, value in pairs(args) do
		if type(key) ~= "number" or key % 1 ~= 0 or key < 1 or key > #args or not text(value, POSIX_LIMIT) then return nil, "Arguments must be a dense bounded UTF-8 string array" end
		count += 1
	end
	if count ~= #args then return nil, "Argument array has gaps" end
	if cwd ~= nil and (not text(cwd, POSIX_LIMIT) or not nonblank(cwd)) then return nil, "Working directory must be nonempty UTF-8 text" end
	if kind == "posix" then
		local words = { Backend.posix_quote(executable) }
		for _, argument in ipairs(args) do table.insert(words, Backend.posix_quote(argument)) end
		local command = table.concat(words, " ")
		if cwd ~= nil then command = "cd -- " .. Backend.posix_quote(cwd) .. " && " .. command end
		return bounded(command, os)
	end
	if crt_only and not executable:lower():match("%.exe$") then return nil, "CRT-only serialization requires an explicit .exe" end
	local native, batch = {}, {}
	for _, argument in ipairs(args) do
		local quoted = Backend.windows_argument(argument)
		table.insert(native, quoted)
		if not crt_only then table.insert(batch, Backend.cmd_escape(Backend.cmd_escape(quoted))) end
	end
	local data = tern.json.encode({ executable = executable, arguments = table.concat(native, " "), batch = if crt_only then nil else table.concat(batch, " "), cwd = cwd })
	local wrapper = POWERSHELL_PREFIX .. tern.base64.encode(data) .. (if crt_only then CRT_SUFFIX else POWERSHELL_SUFFIX)
	local utf16 = assert(Backend.utf16le(wrapper))
	local encoded = tern.base64.encode(utf16)
	return bounded("powershell.exe -NoLogo -NoProfile -EncodedCommand " .. encoded, os)
end

-- Preparation adopts only literal same-host account routing, never shell code.
-- removed counts argv entries through the wrapped executable (for task slots).
local ROUTE_WRAPPERS={sudo=true,su=true,doas=true,runuser=true,env=true,ssh=true,sh=true,bash=true,dash=true,zsh=true,ksh=true}
function Backend.same_host_route(executable,arguments,user)
	user=user or ''
	local argv=table.clone(arguments);local removed=0
	if executable:match('([^/]+)$')=='sudo' then
		local selected=nil;local index=1
		while index<=#argv do
			local word=argv[index]
			if word=='--' then index+=1;break end
			if word:sub(1,1)~='-' then break end
			local value=word:match('^%-%-user=(.+)$') or word:match('^%-u(.+)$')
			if word=='-u' or word=='--user' then index+=1;value=argv[index] end
			if value then
				if selected then return nil,'Same-host sudo route has ambiguous OS-user selectors' end
				selected=value
			elseif word~='-n' and word~='-H' then return nil,'Review this same-host sudo route explicitly; only literal -n, -H and OS-user selection are supported' end
			index+=1
		end
		if not selected or selected=='' or selected:sub(1,1)=='-' or selected:find('[%s%c:/]') or not argv[index] or argv[index]=='' then return nil,'Same-host sudo route must explicitly select an existing OS account and executable' end
		if user~='' and user~=selected then return nil,'Configured OS user conflicts with the literal sudo account selector' end
		user=selected;executable=argv[index];removed=index
		local remaining={};for i=index+1,#argv do table.insert(remaining,argv[i]) end;argv=remaining
	end
	local name=executable:match('([^/]+)$')
	if executable=='' or executable:find('%c') or executable:sub(1,1)=='-' or executable:find('=',1,true) or ROUTE_WRAPPERS[name] then return nil,'Same-host route requires an actual literal worker executable; nested, shell, environment and remote wrappers require explicit review' end
	return {executable=executable,arguments=argv,user=user,removed=removed},nil
end

-- Mailbox adapters use this same identity-fenced SSH transport constructor.
Backend.ssh_arguments = Resolution.ssh_arguments
Backend.login_argv = Resolution.login_argv
local SETUP_LIMIT = 32000

local function setup_text(value: any, limit: number): boolean
	return type(value) == "string" and #value <= limit and not value:find("%z")
end
-- The packaged skill is provider-neutral. Run authority is appended by the host,
-- never inferred from assistant text or from a submitted confirmed=true flag.
function Backend.setup_prompt(records: any, run_id: any, host_key: any, session_key: any, setup: any, skill: any, shell: any): (string?, string?)
	local canonical, err = Config.validate_records(records)
	if not canonical then return nil, err end
	if not setup_text(run_id, 256) or not nonblank(run_id)
		or not setup_text(host_key, 1024) or not nonblank(host_key)
		or not setup_text(session_key, 2048) or not nonblank(session_key)
		or type(setup) ~= "table" or not setup_text(setup.result_path, 8192)
		or not setup_text(setup.binding, 256) or not setup_text(skill, SETUP_LIMIT)
		or type(setup.native_session)~="number" or setup.native_session<0 or setup.native_session%1~=0
		or type(setup.host_config_pane)~="number" or setup.host_config_pane<1 or setup.host_config_pane%1~=0
		or not setup_text(setup.window,256) or setup.config_dir~=nil and not setup_text(setup.config_dir,8192) then
		return nil, "Guided setup needs its original run, execution host, binding and skill"
	end
	local quote = if shell == "posix" then Backend.posix_quote elseif shell == "powershell" then Backend.powershell_quote else nil
	if quote == nil then return nil, "The execution host shell is not supported for the explicit setup submission helper" end
	local envelope = tern.json.encode({schema=1,kind="spawn-setup-result",setup_run_id=run_id,binding=setup.binding,path=setup.result_path})
	if #envelope>4096 then return nil,"Setup helper envelope exceeds the Config block's 4096-byte input bound; no native effect was admitted" end
	local words = {"send",string.format("%.0f/%.0f",setup.native_session,setup.host_config_pane),"paste",envelope,"--window",setup.window,"--json"}
	local helper
	if shell=="posix" then
		local command={}
		for _,word in ipairs(words) do table.insert(command,quote(word)) end
		helper='TERN_DAEMON_SOCKET="${TERN_PANE_SOCKET:?Native Tern daemon socket is missing}" '
			..(if setup.config_dir~=nil then "TERN_CONFIG_DIR="..quote(setup.config_dir).." " else "")
			..'"${TERN_EXE:?Native Tern executable is missing}" '..table.concat(command," ")
	else
		local native_arguments={}
		for _,word in ipairs(words) do table.insert(native_arguments,Backend.windows_argument(word)) end
		helper="& { if ([string]::IsNullOrWhiteSpace($env:TERN_EXE) -or [string]::IsNullOrWhiteSpace($env:TERN_PANE_SOCKET)) { throw 'Native Tern executable or daemon socket is missing' }; "
			.."$start=New-Object System.Diagnostics.ProcessStartInfo; $start.UseShellExecute=$false; $start.FileName=$env:TERN_EXE; "
			.."$start.Arguments="..quote(table.concat(native_arguments," ")).."; $start.EnvironmentVariables['TERN_DAEMON_SOCKET']=$env:TERN_PANE_SOCKET; "
			..(if setup.config_dir~=nil then "$start.EnvironmentVariables['TERN_CONFIG_DIR']="..quote(setup.config_dir).."; " else "")
			.."$child=[System.Diagnostics.Process]::Start($start); try { $child.WaitForExit(); if ($child.ExitCode -ne 0) { throw 'SPAWN helper delivery failed; inspect native review before doing anything else' } } finally { $child.Dispose() } }"
	end
	local prompt = skill .. "\n\nImmutable SPAWN run context:\n" .. tern.json.encode({
		setup_run_id=run_id,host_key=host_key,session_key=session_key,binding=setup.binding,
		result_path=setup.result_path,config_dir=setup.config_dir,existing_records=canonical,
		glitch_installation=setup.glitch_installation,
		questions_script=setup.questions_script,
	}) .. "\nHelper interpreter: "..(if shell=="powershell" then "PowerShell (not cmd.exe)" else "POSIX shell")
		..". Use the native agent process's injected TERN_EXE and TERN_PANE_SOCKET; missing values refuse, never substitute a PATH executable or default daemon."
		.."\nWrite the complete schema-2 JSON to that exact result_path, then run this exact submission command once:\n"
		.. helper .. "\nDelivery is not acceptance. SPAWN opens the settings review for approval in the bound setup pane. Follow its visible approval and preparation flow; do not send the user through per-agent resource or verification steps. A durable roster-save receipt confirms only that the exact reviewed settings were committed and read back, not that preparation or provider login passed. Report SPAWN SETUP SUCCESSFUL only after observing completed preparation and saving. Otherwise name the exact remaining action or failed check; never claim success or say NO DECISION NEEDED from delivery alone."
	if #prompt > SETUP_LIMIT then return nil, "Guided setup context exceeds 32000 bytes; use Advanced manual recovery" end
	return prompt, nil
end
local function windows_fresh_error(record: any, executable: string?): string?
	if record.argv_contract ~= "windows-crt" then return "Managed Windows launch requires an explicit windows-crt argv contract" end
	local name = (executable or ""):lower():gsub("\\", "/"):match("([^/]+)$") or ""
	-- Extensionless names can resolve through PATHEXT to batch shims.
	if not name:match("%.exe$") then return "Managed Windows launch requires an explicit native .exe, not a script or batch shim" end
	if name == "cmd.exe" or name == "powershell.exe" or name == "pwsh.exe" then return "Managed Windows assignment cannot target a command-interpreting shell" end
	return nil
end

-- These are configured launch facts only. Mailbox eligibility additionally needs
-- its adapter's durable identity/probe/producer evidence; this does not grant it.
function Backend.eligibility(record: any): any
	local fresh = Resolution.fresh_available(record)
	local input = record.backend == "native-agent" or (record.task_argument_index ~= nil and record.fresh_arguments ~= nil and record.task_argument_index <= #record.fresh_arguments + 1)
	local target = record.backend ~= "ssh-command" or (record.target_os ~= nil and record.target_shell ~= nil and Backend.shell_kind(record.target_os, record.target_shell) ~= nil)
	if record.target_os == "windows" and windows_fresh_error(record, record.fresh_executable) ~= nil then target = false end
	return { fresh = fresh, input = input, target = target, configured = fresh and input and target and record.enabled ~= false and not record.review_required, runtime_verified = false }
end

function Backend.build(record: any, host: any, options: any?): (any?, string?)
	if options == nil or options.fresh ~= true then return nil, "Managed backend requires explicit fresh=true; ordinary launches use host tickets" end
	local host_kind, shell_error = Backend.shell_kind(host.host_os, host.host_shell)
	if host_kind == nil then return nil, shell_error end
	local resolved, err = Resolution.resolve(record, "fresh", host_kind)
	if resolved == nil then return nil, err end
	record = resolved.record
	if host_kind == "posix" and record.backend ~= "ssh-command" and record.mailbox then
		local execution_user = record.user
		if resolved.executable:match("([^/]+)$") == "sudo" then
			local route, route_error = Backend.same_host_route(resolved.executable, resolved.arguments, execution_user)
			if not route then return nil, route_error end
			execution_user = route.user
		end
		if nonblank(execution_user) and execution_user ~= record.mailbox.worker_identity then
			return nil, "The launch account differs from the prepared agent connection. Prepare this agent again before starting it."
		end
	end
	if record.host_shell ~= nil then
		local configured_kind = Backend.shell_kind(host.host_os, record.host_shell)
		if configured_kind ~= host_kind then return nil, "Configured execution shell does not match the observed host" end
	end
	if record.backend == "native-agent" and host_kind ~= "posix" then return nil, "Native OMP launch is not verified on this execution shell" end
	local target_os, target_shell = host.host_os, host.host_shell
	if record.backend == "ssh-command" then
		if record.target_os == nil or record.target_shell == nil then return nil, "Managed SSH requires explicit target OS and shell" end
		target_os, target_shell = record.target_os, record.target_shell
	elseif record.target_os ~= nil and record.target_os ~= target_os then
		return nil, "Configured target OS does not match the execution host"
	end
	if record.backend ~= "ssh-command" and record.target_shell ~= nil then
		local configured_kind = Backend.shell_kind(target_os, record.target_shell)
		if configured_kind ~= host_kind then return nil, "Configured target shell does not match the execution host" end
	end
	local prompt = options.prompt
	if not text(prompt, POSIX_LIMIT) or not nonblank(prompt) then return nil, "Managed launch requires one explicit nonempty UTF-8 assignment" end
	if options.cwd == nil or options.placement == nil then return nil, "Managed cwd and placement must be explicit" end
	local cwd, placement = options.cwd, options.placement
	if not text(cwd, POSIX_LIMIT) or not nonblank(cwd) then return nil, "Working directory must be nonempty UTF-8 text" end
	if record.backend ~= "native-agent" and placement == "replace_if_alone" then return nil, "Managed terminal replace_if_alone placement is unsupported" end
	if placement ~= "tab" and placement ~= "split" and placement ~= "replace_if_alone" then return nil, "Unsupported placement" end
	if target_os == "windows" then
		local contract_error = windows_fresh_error(record, resolved.executable)
		if contract_error ~= nil then return nil, contract_error end
	end
	local capabilities = {}
	if record.backend ~= "native-agent" then
		local slot = record.task_argument_index
		if slot == nil or slot > #resolved.arguments + 1 then return nil, "Terminal prompt requires a configured argv-v1 insertion slot" end
		table.insert(resolved.arguments, slot, prompt)
		table.insert(capabilities, "argv-v1")
	end
	local selected, user_error = Resolution.select_user(resolved, host_kind, true, cwd)
	if not selected then return nil, user_error end
	-- Native/local cwd belongs to pane/start options, not a second cd.
	-- Managed remote cwd is literal, unlike ordinary SSH's home shorthand.
	local serialized_cwd = if record.backend == "ssh-command" then cwd else nil
	local command, command_error = Backend.serialize(resolved.executable, resolved.arguments, serialized_cwd, target_os, target_shell, true)
	if command == nil then return nil, command_error end
	if record.backend == "ssh-command" then
		local ssh, ssh_error = Backend.ssh_arguments(record, command, true)
		if ssh == nil then return nil, ssh_error end
		command, command_error = Backend.serialize(if host.host_os == "windows" then "ssh.exe" else "ssh", ssh, nil, host.host_os, host.host_shell, true)
		if command == nil then return nil, command_error end
	end
	return { command = command, cwd = if record.backend == "ssh-command" then "." else cwd, placement = placement, backend = record.backend, prompt = if record.backend == "native-agent" then prompt else nil, capabilities = capabilities }, nil
end
return Backend
