--!strict

-- Pure executable discovery shared by native callers. Runners own deadlines, caching,
-- environment, process callbacks and host/window routing; discovery owns none of them.
local Discovery = {}

function Discovery.absolute(value: any): boolean
	return type(value) == "string" and #value > 0 and #value <= 4096 and not value:find("%c")
		and (value:sub(1, 1) == "/" or value:match("^%a:[/\\]") ~= nil or value:sub(1, 2) == "\\\\")
end

function Discovery.argv(os: string, system_root: any): (any?, string?)
	if os == "linux" then return { "/bin/sh", "-c", '/usr/bin/readlink /proc/$PPID/exe' }, nil end
	if os == "macos" then return { "/bin/sh", "-c", '/bin/ps -p "$PPID" -o comm=' }, nil end
	if os == "windows" then
		if not Discovery.absolute(system_root) then return nil, "The host's absolute Windows system directory is unavailable" end
		return { system_root .. "\\System32\\WindowsPowerShell\\v1.0\\powershell.exe", "-NoLogo", "-NoProfile", "-NonInteractive", "-Command",
			"$ErrorActionPreference='Stop'; $self=Get-CimInstance Win32_Process -Filter ('ProcessId='+$PID); $parent=Get-CimInstance Win32_Process -Filter ('ProcessId='+$self.ParentProcessId); [Console]::WriteLine($parent.ExecutablePath)" }, nil
	end
	return nil, "Native executable discovery is not verified on this host"
end

function Discovery.path(stdout: any): (string?, string?)
	if type(stdout) == "string" then
		local path = stdout:gsub("\r?\n$", "")
		if Discovery.absolute(path) then return path, nil end
	end
	return nil, "Native executable discovery did not return one absolute path"
end

return Discovery
