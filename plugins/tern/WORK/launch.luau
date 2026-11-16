--!strict
local M = {}

local MAX_ARGUMENTS = 64
local MAX_ARGUMENT_BYTES = 4096
local POSIX_LIMIT = 32768
local WINDOWS_LIMIT = 7000

local RESERVED = {}
for word in string.gmatch("! { } [[ ]] case do done elif else esac fi for if in then until while time function select coproc", "%S+") do
	RESERVED[word] = true
end

local function valid_os(value: any): boolean
	return value == "linux" or value == "macos" or value == "windows"
end

local function valid_argument(value: any): boolean
	return type(value) == "string" and #value <= MAX_ARGUMENT_BYTES
		and string.find(value, "[%z\1-\31\127]") == nil and utf8.len(value) ~= nil
end

function M.validate_agent(value: any): (any?, string?)
	if type(value) ~= "table" or (value.kind ~= "acp" and value.kind ~= "cli") or not valid_os(value.os) then
		return nil, "WORK host agent has an invalid kind or execution OS"
	end
	if type(value.argv) ~= "table" or #value.argv == 0 or #value.argv > MAX_ARGUMENTS then
		return nil, "WORK host agent argv must be a nonempty bounded array"
	end
	local argv = {}
	local count = 0
	for key, argument in pairs(value.argv) do
		if type(key) ~= "number" or key % 1 ~= 0 or key < 1 or key > #value.argv or not valid_argument(argument) then
			return nil, "WORK host agent argv is not a dense UTF-8 string array"
		end
		count += 1
	end
	if count ~= #value.argv then return nil, "WORK host agent argv has gaps" end
	for index, argument in ipairs(value.argv) do argv[index] = argument end
	if string.find(argv[1], "%S") == nil then return nil, "WORK host agent executable is empty" end
	return { kind = value.kind, argv = argv, os = value.os }, nil
end

function M.decode_agent(text: any, decode: any): (any?, string?)
	if type(text) ~= "string" or type(decode) ~= "function" then return nil, "WORK host agent payload is missing" end
	local ok, value = pcall(decode, text)
	if not ok then return nil, "WORK host agent payload is not valid JSON" end
	return M.validate_agent(value)
end

local function posix_quote(value: string): string
	return "'" .. string.gsub(value, "'", "'\\''") .. "'"
end

local function posix_word(value: string, executable: boolean): string
	if value ~= "" and string.match(value, "^[%w_%-%.,/:=@+%%]+$") ~= nil and not RESERVED[value]
		and not (executable and string.find(value, "=", 1, true))
	then
		return value
	end
	return posix_quote(value)
end

function M.windows_argument(value: string): string
	local escaped = string.gsub(value, '(\\*)"', function(slashes)
		return slashes .. slashes .. '\\"'
	end)
	escaped = string.gsub(escaped, "(\\+)$", "%1%1")
	return '"' .. escaped .. '"'
end

local ALPHABET = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"
local function base64(value: string): string
	local result = {}
	for index = 1, #value, 3 do
		local a, b, c = string.byte(value, index, index + 2)
		local number = a * 65536 + (b or 0) * 256 + (c or 0)
		local function digit(shift: number): string
			return string.sub(ALPHABET, math.floor(number / shift) % 64 + 1, math.floor(number / shift) % 64 + 1)
		end
		table.insert(result, digit(262144))
		table.insert(result, digit(4096))
		table.insert(result, if b ~= nil then digit(64) else "=")
		table.insert(result, if c ~= nil then digit(1) else "=")
	end
	return table.concat(result)
end

local function utf16le(value: string): string?
	if utf8.len(value) == nil then return nil end
	local bytes = {}
	for _, codepoint in utf8.codes(value) do
		if codepoint >= 65536 then
			codepoint -= 65536
			local high = 55296 + math.floor(codepoint / 1024)
			local low = 56320 + codepoint % 1024
			table.insert(bytes, string.char(high % 256, math.floor(high / 256), low % 256, math.floor(low / 256)))
		else
			table.insert(bytes, string.char(codepoint % 256, math.floor(codepoint / 256)))
		end
	end
	return table.concat(bytes)
end

local POWERSHELL_PREFIX = "$ErrorActionPreference='Stop';try{$d=[Text.Encoding]::UTF8.GetString([Convert]::FromBase64String('"
local POWERSHELL_SUFFIX = "'))|ConvertFrom-Json;$found=@(Get-Command -Name ([Management.Automation.WildcardPattern]::Escape($d.executable)) -CommandType Application,ExternalScript -ErrorAction Stop);if($found.Count -ne 1){throw 'Launch command did not resolve to one executable or script'};$file=$found[0].Source;$ext=[IO.Path]::GetExtension($file).ToLowerInvariant();if($ext -eq '.cmd' -or $ext -eq '.bat'){throw 'WORK does not launch batch files; configure a native .exe or PowerShell script'};$p=New-Object Diagnostics.ProcessStartInfo;$p.UseShellExecute=$false;$p.WorkingDirectory=(Get-Location).ProviderPath;if($ext -eq '.ps1'){$engine=if($PSVersionTable.PSEdition -eq 'Desktop'){'powershell.exe'}else{'pwsh.exe'};$p.FileName=[IO.Path]::Combine($PSHOME,$engine);$p.Arguments='-NoLogo -NoProfile -File \"'+$file+'\" '+$d.arguments}else{$p.FileName=$file;$p.Arguments=$d.arguments};$child=[Diagnostics.Process]::Start($p);$child.WaitForExit();$code=$child.ExitCode;$child.Dispose();exit $code}catch{[Console]::Error.WriteLine($_.Exception.Message);exit 1}"

local function windows_command(argv: { string }, json_encode: any): (string?, string?)
	if type(json_encode) ~= "function" then return nil, "WORK Windows launcher needs JSON encoding" end
	local executable = string.lower(argv[1])
	if string.match(executable, "%.cmd$") ~= nil or string.match(executable, "%.bat$") ~= nil then
		return nil, "WORK does not launch .cmd/.bat files on Windows; configure a native .exe or PowerShell script"
	end
	local native = {}
	for index = 2, #argv do table.insert(native, M.windows_argument(argv[index])) end
	local encode_ok, data = pcall(json_encode, {
		executable = argv[1],
		arguments = table.concat(native, " "),
	})
	if not encode_ok or type(data) ~= "string" then return nil, "WORK could not encode the Windows launch" end
	local wrapper = POWERSHELL_PREFIX .. base64(data) .. POWERSHELL_SUFFIX
	local wide = utf16le(wrapper)
	if wide == nil then return nil, "WORK Windows launcher is not valid UTF-8" end
	local command = "powershell.exe -NoLogo -NoProfile -EncodedCommand " .. base64(wide)
	if #command > WINDOWS_LIMIT then return nil, "WORK Windows launch exceeds the native command limit" end
	return command, nil
end

function M.command(agent: any, json_encode: any): (string?, string?)
	local valid, problem = M.validate_agent(agent)
	if valid == nil then return nil, problem end
	local parts = {}
	if valid.os == "windows" then return windows_command(valid.argv, json_encode) end
	for index, argument in ipairs(valid.argv) do table.insert(parts, posix_word(argument, index == 1)) end
	local command = table.concat(parts, " ")
	if #command > POSIX_LIMIT then return nil, "WORK launch exceeds the native command limit" end
	return command, nil
end

return M
