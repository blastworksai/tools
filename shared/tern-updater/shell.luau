-- Generated from plugins/tern/SPAWN/backend.luau by updater sync.py; edit the serializer there.
local Backend = {}
local POSIX_LIMIT, WINDOWS_LIMIT = 32768, 7000

local function text(value: any, limit: number): boolean
	return type(value) == "string" and #value <= limit and not value:find("%z") and utf8.len(value) ~= nil
end
local function nonblank(value: any): boolean
	return type(value) == "string" and value:find("%S") ~= nil
end
function Backend.posix_quote(value: string): string
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
return Backend
