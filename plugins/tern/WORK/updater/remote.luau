-- Vendored from shared/tern-updater by sync.py; edit there, then run sync.py.
-- Remote installs use a native host terminal. Only exact structured completion
-- and bounded command output count; agent chat and uncorrelated scrollback never do.
local Shell = require("./shell")
local Observe = require("./observe")
local Remote = {}
local MAX_OUTPUT = 64000
local function equal(a, b, depth)
	if type(a) ~= type(b) or depth > 12 then return false end
	if type(a) ~= "table" then return a == b end
	for key, value in pairs(a) do if not equal(value, b[key], depth + 1) then return false end end
	for key in pairs(b) do if a[key] == nil then return false end end
	return true
end
function Remote.snapshot(host)
	if type(host) ~= "table" or host.kind ~= "remote" or host.state ~= "connected"
		or type(host.id) ~= "number" or type(host.address) ~= "string" or host.address == ""
		or type(host.identity) ~= "table" or next(host.identity) == nil then return nil, "Remote host identity is not observable" end
	local identity = { id = host.id, name = host.name, address = host.address, identity = host.identity,
		fingerprint = if host.detail then host.detail.fingerprint else nil }
	local ok, bytes = pcall(tern.json.encode, identity)
	if not ok or #bytes > 8192 then return nil, "Remote host identity exceeds the observation bound" end
	return identity
end
function Remote.host(cx, identity)
	if type(identity) ~= "table" or type(identity.id) ~= "number" then return nil, "Original remote host identity is unavailable" end
	local ok, hosts = pcall(cx.hosts.list, cx.hosts)
	if not ok or type(hosts) ~= "table" then return nil, "Native host inventory is unavailable" end
	for _, host in ipairs(hosts) do
		if host.id == identity.id then
			local current, err = Remote.snapshot(host)
			if current == nil then return nil, err end
			if not equal(current, identity, 0) then return nil, "Remote host identity changed" end
			return host
		end
	end
	return nil, "The original remote host is not attached"
end
function Remote.pane(cx, target)
	local host, err = Remote.host(cx, target.host)
	if host == nil then return nil, err end
	local belongs = false
	for _, pane in ipairs(host.panes or {}) do if pane == target.pane then belongs = true; break end end
	if not belongs then return nil, "The saved terminal does not belong to the original remote host" end
	local ok, pane = pcall(cx.session.pane, cx.session, target.pane)
	if not ok or type(pane) ~= "table" or pane.kind ~= "terminal" then return nil, "The original native terminal is unavailable" end
	return pane
end
function Remote.ready(cx, target)
	local pane, err = Remote.pane(cx, target)
	if pane == nil then return nil, err end
	if pane.running ~= nil or pane.at_prompt ~= true or pane.exited ~= nil or pane.error ~= nil then
		return nil, "The original native terminal is not at a usable prompt"
	end
	-- pane.last is legitimately absent before the first command.
	return pane
end
function Remote.platform(program)
	if type(program) ~= "string" then return nil, "Remote login shell is unknown" end
	local name = program:lower():gsub("\\", "/"):match("([^/]+)$") or ""
	local os = if name == "cmd" or name == "cmd.exe" or name == "pwsh" or name == "pwsh.exe"
		or name == "powershell" or name == "powershell.exe" then "windows" else "linux"
	local kind, err = Shell.shell_kind(os, program)
	if kind == nil then return nil, err end
	return { os = os, shell = program, kind = kind }
end
local function encoded_powershell(script)
	local encoded, err = Shell.utf16le(script)
	if encoded == nil then return nil, err end
	local line = "powershell.exe -NoLogo -NoProfile -EncodedCommand " .. tern.base64.encode(encoded)
	if #line > 7000 then return nil, "Remote command exceeds the Windows command bound" end
	return line
end
local function nonce_valid(nonce)
	return type(nonce) == "string" and #nonce <= 160 and nonce:match("^[A-Za-z0-9:._%-]+$") ~= nil
end
local READ_COMMAND = 'set -eu; value=$("$@"); printf "%s" "$value" | base64'
local PS_READ = "$ErrorActionPreference='Stop';try{$d=[Text.Encoding]::UTF8.GetString([Convert]::FromBase64String('"
local PS_READ_END = "'))|ConvertFrom-Json;$p=New-Object Diagnostics.ProcessStartInfo;$p.FileName=$d.executable;$p.Arguments=$d.arguments;$p.UseShellExecute=$false;$p.RedirectStandardOutput=$true;$c=[Diagnostics.Process]::Start($p);$output=$c.StandardOutput.ReadToEnd();$c.WaitForExit();$status=$c.ExitCode;$c.Dispose();if($status -ne 0){exit $status};[Console]::Write([Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($output)));exit 0}catch{[Console]::Error.WriteLine($_.Exception.Message);exit 1}"
-- Read-only CLI output is base64-transported: terminal line wrapping cannot alter
-- JSON string bytes. Native install itself is not hidden behind this read wrapper.
function Remote.command(platform, argv, nonce, encoded_output)
	if not nonce_valid(nonce) or type(argv) ~= "table" or #argv < 1 then return nil, "Invalid remote command correlation" end
	local executable, args = argv[1], {}
	for index = 2, #argv do table.insert(args, argv[index]) end
	if platform.kind == "posix" then
		if encoded_output then
			local words = { "-c", READ_COMMAND, "updater-observe" }
			for _, argument in ipairs(argv) do table.insert(words, argument) end
			executable, args = "sh", words
		end
		local line, err = Shell.serialize(executable, args, nil, platform.os, platform.shell)
		if line == nil then return nil, err end
		line ..= " # updater:" .. nonce
		if #line > 32768 then return nil, "Remote command exceeds the POSIX command bound" end
		return line
	end
	if encoded_output then
		local quoted = {}
		for _, argument in ipairs(args) do table.insert(quoted, Shell.windows_argument(argument)) end
		local data = tern.json.encode({ executable = executable, arguments = table.concat(quoted, " ") })
		return encoded_powershell("# updater:" .. nonce .. "\n" .. PS_READ .. tern.base64.encode(data) .. PS_READ_END)
	end
	-- Prepend a closed ASCII correlation comment to the reviewed UTF-16 script;
	-- its argv handling and exit status remain byte-for-byte unchanged.
	local line, err = Shell.serialize(executable, args, nil, platform.os, platform.shell)
	if line == nil then return nil, err end
	local prefix = "powershell.exe -NoLogo -NoProfile -EncodedCommand "
	if line:sub(1, #prefix) ~= prefix then return nil, "Reviewed Windows command shape changed" end
	local bytes = tern.base64.decode(line:sub(#prefix + 1))
	local result = prefix .. tern.base64.encode(assert(Shell.utf16le("# updater:" .. nonce .. "\n")) .. bytes)
	if #result > 7000 then return nil, "Remote command exceeds the Windows command bound" end
	return result
end
function Remote.completion(cx, target, command)
	local pane, err = Remote.pane(cx, target)
	if pane == nil then return nil, err end
	if pane.running ~= nil then return nil, "The original terminal command is still running", "running" end
	local last = pane.last
	if type(last) ~= "table" or last.line ~= command.line or type(last.status) ~= "number"
		or type(last.took_ms) ~= "number" or last.took_ms < 0 or pane.at_prompt ~= true then
		return nil, "Native completion does not match the exact journaled command", "unknown"
	end
	return last
end
function Remote.await(cx, target, command, encoded_output, cb)
	local pane, pane_error = Remote.pane(cx, target)
	if pane == nil then cb(nil, pane_error, cx); return end
	local ok, raised = pcall(function()
		cx.session:settle(target.pane, 120000):next(function(output, err, fresh)
			local now = fresh or cx
			if err ~= nil then cb(nil, "Native terminal completion is unavailable; the command was not retyped", now); return end
			local completion, completion_error = Remote.completion(now, target, command)
			if completion == nil then cb(nil, completion_error, now); return end
			local read_ok, view = pcall(now.session.read, now.session, target.pane, { as = "table", lines = 2000, max_chars = MAX_OUTPUT })
			if not read_ok or type(view) ~= "table" or view.kind ~= "terminal" or view.more ~= 0
				or view.chars_clipped == true or type(output) ~= "string" or #output >= MAX_OUTPUT then
				cb(nil, "Native terminal output is clipped or not safely observable", now); return
			end
			if encoded_output and completion.status == 0 then
				local decoded, bytes = pcall(tern.base64.decode, output)
				if not decoded or #bytes > MAX_OUTPUT then cb(nil, "Remote observation encoding is incomplete", now); return end
				output = bytes
			end
			cb({ status = completion.status, stdout = output, stderr = "", timed_out = false, native_completion = true }, nil, now)
		end)
	end)
	if not ok then cb(nil, "Native terminal observation failed: " .. tostring(raised):sub(1, 200), cx) end
end
local POSIX_FILES = [=[set -eu
root=$1; id=$2
[ ! -e "$root/$id.path" ] && [ ! -L "$root/$id.path" ]
[ -d "$root/$id" ] && [ ! -L "$root/$id" ] && [ -r "$root/$id" ] && [ -x "$root/$id" ]
for file in plugin.toml requires.json; do
  path=$root/$id/$file
  [ ! -L "$path" ]
  if [ -f "$path" ]; then
    [ "$(wc -c < "$path")" -le 16384 ]
    printf '%s:present\n' "$file"
    base64 < "$path"
    printf '\n:END\n'
  elif [ -e "$path" ]; then exit 1
  else printf '%s:absent\n' "$file"
  fi
done]=]
local PS_FILES_END = "'))|ConvertFrom-Json;$root=Join-Path $d.root $d.id;if(Test-Path -LiteralPath (Join-Path $d.root ($d.id+'.path'))){throw 'Development link'};$dir=Get-Item -LiteralPath $root -Force;if(!$dir.PSIsContainer -or ($dir.Attributes -band [IO.FileAttributes]::ReparsePoint)){throw 'Unsafe package directory'};foreach($name in @('plugin.toml','requires.json')){$path=Join-Path $root $name;if(Test-Path -LiteralPath $path){$f=Get-Item -LiteralPath $path -Force;if($f.PSIsContainer -or ($f.Attributes -band [IO.FileAttributes]::ReparsePoint) -or $f.Length -gt 16384){throw 'Unsafe or oversized observation'};[Console]::WriteLine($name+':present');[Console]::WriteLine([Convert]::ToBase64String([IO.File]::ReadAllBytes($path)));[Console]::WriteLine(':END')}else{[Console]::WriteLine($name+':absent')}};exit 0}catch{[Console]::Error.WriteLine($_.Exception.Message);exit 1}"
function Remote.files_command(platform, root, id, nonce)
	if type(root) ~= "string" or #root > 4096 or type(id) ~= "string" or not id:match("^[a-z0-9][a-z0-9._%-]*$") or not nonce_valid(nonce) then
		return nil, "Invalid remote package observation path"
	end
	if platform.kind == "posix" then return Remote.command(platform, { "sh", "-c", POSIX_FILES, "updater-files", root, id }, nonce, false) end
	local data = tern.json.encode({ root = root, id = id })
	return encoded_powershell("# updater:" .. nonce .. "\n" .. PS_READ .. tern.base64.encode(data) .. PS_FILES_END)
end
function Remote.files(result, id)
	if type(result) ~= "table" or result.status ~= 0 or result.timed_out or type(result.stdout) ~= "string" or #result.stdout >= MAX_OUTPUT then
		return nil, "Remote package observation did not complete"
	end
	local text = result.stdout:gsub("\r\n", "\n")
	local values, at = {}, 1
	for _, name in ipairs({ "plugin.toml", "requires.json" }) do
		local absent = name .. ":absent\n"
		local present = name .. ":present\n"
		if text:sub(at, at + #absent - 1) == absent then
			values[name], at = false, at + #absent
		elseif text:sub(at, at + #present - 1) == present then
			local finish = text:find("\n:END\n", at + #present, true)
			if finish == nil then return nil, "Remote package observation is clipped" end
			local decoded, bytes = pcall(tern.base64.decode, text:sub(at + #present, finish - 1))
			if not decoded or #bytes > 16384 then return nil, "Remote package bytes are unreadable or oversized" end
			values[name], at = bytes, finish + #"\n:END\n"
		else return nil, "Remote package observation has ambiguous boundaries" end
	end
	if text:sub(at):find("%S") then return nil, "Unexpected data follows remote package observation" end
	return Observe.package(values["plugin.toml"], values["requires.json"], values["requires.json"] == false, id)
end
return Remote
