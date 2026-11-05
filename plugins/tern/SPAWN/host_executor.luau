-- Host-only ticket execution. Authority owns persistence; this module owns effects.
local Resolution = require("./launch_resolution")
local Native = require("./native_cli")
local Executor = {}
local function nonempty(value: any): string?
	return if type(value) == "string" and value:match("%S") ~= nil then value else nil
end
local function posix_quote(value: string): string
	return "'" .. value:gsub("'", "'\\''") .. "'"
end
local function powershell_quote(value: string): string
	return "'" .. value:gsub("'", "''") .. "'"
end
-- CreateProcess receives one command-line string. Quote each argv element using
-- the Windows CRT rules instead of PowerShell 5's lossy native argument binder.
local function windows_argument(value: string): string
	local escaped = value:gsub('(\\*)"', function(slashes) return slashes .. slashes .. '\\"' end)
	escaped = escaped:gsub("(\\+)$", "%1%1")
	return '"' .. escaped .. '"'
end
local CMD_META = {}
for char in string.gmatch('()[]%!^"`<>&|;, *?', ".") do CMD_META[char] = true end
local function cmd_escape(value: string): string
	return (value:gsub(".", function(char) return if CMD_META[char] then "^" .. char else char end))
end
local function powershell_invocation(words: any): string
	local native, batch = {}, {}
	for index = 2, #words do
		local argument = windows_argument(words[index])
		table.insert(native, argument)
		-- cmd parses once to enter a batch file and again when its arguments
		-- are forwarded. Preserve both passes, including literal % and !.
		-- Algorithm: github.com/moxystudio/node-cross-spawn/lib/util/escape.js
		table.insert(batch, cmd_escape(cmd_escape(argument)))
	end
	local arguments = powershell_quote(table.concat(native, " "))
	local batch_arguments = powershell_quote(table.concat(batch, " "))
	-- Only the final short native process carries the real child status to
	-- Tern's shell integration. Assignment or an outer scriptblock masks it.
	-- All launcher variables/settings are scoped; native console handles and
	-- the parent's interactive shell remain intact.
	return "& ([IO.Path]::Combine([Environment]::GetFolderPath('System'),'cmd.exe')) /d /c ('exit ' + (& { "
		.. "$ErrorActionPreference='Stop'; try { "
		.. "$found=@(Get-Command -Name ([System.Management.Automation.WildcardPattern]::Escape(" .. powershell_quote(words[1]) .. ")) -CommandType Application,ExternalScript -ErrorAction Stop); "
		.. "if($found.Count -ne 1){throw 'Launch command did not resolve to one executable or script'}; "
		.. "$file=$found[0].Source; $ext=[IO.Path]::GetExtension($file).ToLowerInvariant(); "
		.. "$psi=New-Object System.Diagnostics.ProcessStartInfo; $psi.UseShellExecute=$false; $psi.WorkingDirectory=(Get-Location).ProviderPath; "
		.. "if($ext -eq '.cmd' -or $ext -eq '.bat'){ "
		.. "$psi.FileName=[IO.Path]::Combine([Environment]::GetFolderPath('System'),'cmd.exe'); "
		.. "$psi.Arguments='/d /v:off /s /c \"'+[regex]::Replace($file,'([()\\[\\]%!^\"`<>&|;, *?])','^$1')+' '+" .. batch_arguments .. "+'\"' "
		.. "} elseif($ext -eq '.ps1'){ "
		.. "$engine=if($PSVersionTable.PSEdition -eq 'Desktop'){'powershell.exe'}else{'pwsh.exe'}; "
		.. "$psi.FileName=[IO.Path]::Combine($PSHOME,$engine); $psi.Arguments='-NoLogo -NoProfile -File \"'+$file+'\" '+" .. arguments .. " "
		.. "} else { $psi.FileName=$file; $psi.Arguments=" .. arguments .. " }; "
		.. "$p=[System.Diagnostics.Process]::Start($psi); $p.WaitForExit(); $code=$p.ExitCode; $p.Dispose(); return $code "
		.. "} catch { [Console]::Error.WriteLine($_.Exception.Message); return 1 } }))"
end
local function shell_kind(program: string, host_os: string): (string?, string?)
	local shell = string.lower(program:gsub("\\", "/")):match("([^/]+)$") or ""
	if shell == "pwsh" or shell == "pwsh.exe" or shell == "powershell" or shell == "powershell.exe" then return "powershell", nil end
	if host_os ~= "windows" and (shell == "bash" or shell == "zsh" or shell == "sh" or shell == "dash" or shell == "ksh") then return "posix", nil end
	return nil, "The execution host's shell is not verified for safe invocation (" .. program .. "); review its shell settings"
end
local RESERVED = {}
for word in string.gmatch("! { } [[ ]] case do done elif else esac fi for if in then until while time function select coproc", "%S+") do RESERVED[word] = true end
-- Simple words stay readable; anything else, including a command word that the
-- shell would take as an assignment, keeps full POSIX quoting.
local function posix_word(word: string, command: boolean): string
	if word ~= "" and word:match("^[%w_%-%.,/:=@+%%]+$") ~= nil and not RESERVED[word] and not (command and word:find("=", 1, true)) then return word end
	return posix_quote(word)
end
local function invocation(words: any, shell: string): string
	local parts = {}
	if shell == "powershell" then return powershell_invocation(words) end
	for index, word in words do table.insert(parts, posix_word(word, index == 1)) end
	return table.concat(parts, " ")
end
function Executor.render(record: any, program: string, host_os: string, initial_prompt: string?): (string?, string?)
	local shell, err = shell_kind(program, host_os)
	if shell == nil then return nil, err end
	local resolved, resolution_error = Resolution.resolve(record, "ordinary", shell)
	if resolved == nil then return nil, resolution_error end
	record = resolved.record
	-- The host submits one invocation to its retained integrated shell. Native
	-- OMP launch on a Windows host has not been verified.
	if record.backend == "native-agent" and shell ~= "posix" then
		return nil, "Native OMP's execution-host launch shell is not verified. Use a reviewed POSIX host or manual Config recovery; no prompt was sent."
	end
	if record.backend == "native-agent" then
		local prompt = if initial_prompt ~= nil then initial_prompt else record.prompt
		if nonempty(prompt) ~= nil then table.insert(resolved.arguments, prompt) end
	end
	local selected, user_error = Resolution.select_user(resolved, shell)
	if not selected then return nil, user_error end
	local words = resolved.arguments
	table.insert(words, 1, resolved.executable)
	if record.backend == "ssh-command" then
		local remote = invocation(words, "posix")
		local cwd = nonempty(record.cwd)
		if cwd == "~" then remote = 'cd "$HOME" && ' .. remote
		elseif cwd ~= nil and cwd:sub(1, 2) == "~/" then remote = 'cd "$HOME/"' .. posix_quote(cwd:sub(3)) .. " && " .. remote
		elseif cwd ~= nil then remote = "cd " .. posix_quote(cwd) .. " && " .. remote end
		local ssh, ssh_error = Resolution.ssh_arguments(record, remote, true)
		if ssh == nil then return nil, ssh_error end
		words = ssh
		table.insert(words, 1, "ssh")
	end
	local line = invocation(words, shell)
	-- Pane input is a terminal, not an argv API. Literal control keys can edit
	-- or interrupt a quoted command before the shell parses it. Preserve LF
	-- inside shell quotes, but refuse other terminal controls rather than
	-- silently changing approved arguments or prompts.
	if line:find("[%z\1-\9\11-\31\127]") then return nil, "The approved invocation contains terminal control bytes; no command was sent" end
	-- Tern names a POSIX command by its first word; this unquoted assignment
	-- gives each provider a stable icon name without changing argv.
	local provider = string.lower(if type(record.provider) == "string" then record.provider else ""):gsub("[^a-z0-9_%-]", "")
	if shell == "posix" and provider ~= "" then line = "SPAWN_PROVIDER=" .. provider .. " " .. line end
	return line, nil
end

local Authority, on_change = nil, nil
local installed = false
local attached, tracks, by_pane = {}, {}, {}
local prepared, expiring = {}, {}
local TERMINAL = { completed = true, failed = true, resolved = true }
local MAX_JSON = 2000000

local function notify(binding, problem)
	if on_change ~= nil then on_change(binding, problem) end
end
local function key(binding, id)
	return binding.session_key .. "\0" .. id
end
local function current(track)
	local job, err = Authority.execution_job(track.binding, track.id)
	if job == nil then
		track.stopped = true
		if by_pane[track.route.pane] == track then by_pane[track.route.pane] = nil end
		tracks[key(track.binding, track.id)] = nil
		if err ~= nil then notify(track.binding, err) end
	end
	return job
end
local function update(track, job, patch, observation)
	local value, err = Authority.update_execution(track.binding, job.id, job.stage, patch, observation)
	if value == nil then notify(track.binding, err); return nil, err end
	notify(track.binding)
	return value
end
local function fail_job(track, message, category)
	local job = current(track)
	if job == nil or TERMINAL[job.stage] then return end
	local stage = if job.stage == "admitted" or job.stage == "claimed" then "failed" else "unknown"
	update(track, job, { stage = stage }, {
		phase = if stage == "failed" then "Failed" else "Unknown",
		error_category = category or "host-unavailable", diagnostic = message:sub(1, 4096),
	})
end
local function uncertain(track, message)
	local job = current(track)
	if job == nil or TERMINAL[job.stage] then return end
	update(track, job, { stage = "unknown" }, { phase = "Unknown", error_category = "host-unavailable", diagnostic = message:sub(1, 4096) })
end
local function decode(result, err)
	if err ~= nil then return nil, err end
	if type(result) ~= "table" then return nil, "Native observation returned no process result" end
	if result.timed_out then return nil, "Native observation exceeded its deadline" end
	if result.status ~= 0 then return nil, "Native observation failed with status " .. tostring(result.status) .. ": " .. tostring(result.stderr):sub(1, 2048) end
	if type(result.stdout) ~= "string" or #result.stdout > MAX_JSON then return nil, "Native observation is missing or exceeds its bounded size" end
	local ok, value = pcall(tern.json.decode, result.stdout)
	if not ok or type(value) ~= "table" then return nil, "Native observation returned invalid JSON" end
	return value, nil
end
local function basename(value)
	return if type(value) == "string" then (value:gsub("\\", "/"):lower():match("([^/]+)$") or "") else ""
end
local function route_for(job)
	local native = job.native
	return { executable = native.executable, socket = native.socket, window = native.window_key, pane = native.pane }
end
local function register(binding, job, owned)
	local id = key(binding, job.id)
	if tracks[id] ~= nil then return tracks[id] end
	local route = route_for(job)
	local previous = by_pane[route.pane]
	if previous ~= nil and current(previous) ~= nil then
		notify(binding, "A native pane is already tracked by another retained host job")
		return nil
	end
	local track = { binding = binding, id = job.id, route = route, owned = owned, trusted = false, started = false, stopped = false }
	tracks[id], by_pane[route.pane] = track, track
	return track
end
local function detach_observer(track)
	track.trusted, track.bound, track.owned = false, false, false
	if by_pane[track.route.pane] == track then by_pane[track.route.pane] = nil end
end
local function prune(binding)
	local jobs, err = Authority.execution_jobs(binding)
	if jobs == nil then notify(binding, err); return end
	local retained = {}
	for _, job in ipairs(jobs) do retained[job.id] = true end
	for id, track in pairs(tracks) do
		if track.binding.session_key == binding.session_key and not retained[track.id] then
			detach_observer(track)
			track.stopped = true
			tracks[id] = nil
		end
	end
end
local function invoke(track, operation, callback)
	local ok, err = pcall(operation, callback)
	if not ok then fail_job(track, "Could not start native observation: " .. tostring(err)) end
end
local function membership(track, callback)
	invoke(track, function(done)
		Native.inspect(track.route.window, { route = track.route, timeout_ms = 5000 }, done)
	end, function(result, err)
		local value, problem = decode(result, err)
		if value == nil then callback(nil, problem); return end
		local job = current(track)
		if job == nil then return end
		if type(value.sessions) ~= "table" then callback(nil, "Native session inventory is unavailable"); return end
		local found, count = nil, 0
		for _, session in ipairs(value.sessions) do
			for _, tab in ipairs(session.tabs or {}) do
				for _, block in ipairs(tab.blocks or {}) do
					if block.id == track.route.pane then
						count += 1
						found = { session = session.id, tab = tab.id, block = block }
					end
				end
			end
		end
		if count ~= 1 or found.session ~= job.native_session then callback(nil, "The bound native pane is not uniquely in the approved original session"); return end
		if found.block.command ~= job.ticket or found.block.program ~= job.native.program then callback(nil, "The native pane does not retain its exact host ticket and shell"); return end
		if type(found.block.args) ~= "table" or next(found.block.args) ~= nil then callback(nil, "The native ticket filter did not retain an integrated shell"); return end
		if found.block.exited ~= nil or found.block.live == false then callback(nil, "The retained native shell has exited"); return end
		callback(found, nil)
	end)
end
local function process(track, callback)
	invoke(track, function(done)
		Native.process(track.route, track.binding.native_session, track.route.pane, { timeout_ms = 5000 }, done)
	end, function(result, err)
		local value, problem = decode(result, err)
		if value == nil then callback(nil, problem); return end
		if value.pane ~= track.route.pane or type(value.child) ~= "table" or type(value.child.argv) ~= "table" or type(value.child.pid) ~= "number" or value.child.pid < 1 or value.child.pid % 1 ~= 0 then callback(nil, "Native process observation does not identify the retained shell"); return end
		local job = current(track)
		if job == nil then return end
		-- Windows process inspection supplies the executable name but no argv.
		local child_program = nonempty(value.child.argv[1]) or nonempty(value.child.name)
		if basename(child_program) ~= basename(job.native.program) then callback(nil, "The retained native child is not the approved host shell"); return end
		callback(value, nil)
	end)
end
local function foreground_identity(value)
	if type(value.foreground) ~= "table" or type(value.foreground.pid) ~= "number" or value.foreground.pid < 1 or value.foreground.pid % 1 ~= 0 or value.foreground.pid == value.child.pid then return nil end
	return Native.process_identity(value.foreground.pid)
end
local function still_active(job)
	return job.stage == "submission_intent" or job.stage == "submitted" or job.stage == "running" or job.stage == "unknown"
end
local function capture_provider(track)
	tern.timer(50, function()
		local job = current(track)
		if job == nil or not still_active(job) or job.pane_reused or not track.trusted then return end
		process(track, function(value, problem)
			local fresh = current(track)
			if fresh == nil or not still_active(fresh) or fresh.pane_reused then return end
			if value == nil then uncertain(track, problem); return end
			local identity = foreground_identity(value)
			if identity == nil then
				-- A fast provider can already have returned before this callback.
				-- Only its real completion event may supply an exit status.
				if value.foreground == nil or value.foreground.pid == value.child.pid then uncertain(track, "Provider start was observed, but no current provider or matching completion is available") end
				return
			end
			if fresh.process_identity ~= nil and fresh.process_identity ~= identity then
				update(track, fresh, { stage = "unknown", pane_reused = true }, { phase = "Unknown", diagnostic = "The pane now contains a different provider process; the original outcome is unknown" })
				return
			end
			update(track, fresh, { process_identity = identity })
		end)
	end)
end
local function submit(track)
	local job = current(track)
	if job == nil or job.stage ~= "claimed" or job.pane_reused then return end
	local epoch = Native.epoch()
	if epoch ~= nil then
		job = update(track, job, { epoch = epoch })
		if job == nil then fail_job(track, "The host epoch could not be recorded before execution"); return end
	end
	membership(track, function(found, problem)
		if found == nil then fail_job(track, problem, "host-mismatch"); return end
		invoke(track, function(done)
			Native.wait_prompt(track.route, job.native_session, track.route.pane, { timeout_ms = 10000 }, done)
		end, function(result, err)
			local ready, readiness_error = decode(result, err)
			if ready == nil or ready.block ~= track.route.pane or ready.status ~= nil then fail_job(track, readiness_error or "The retained shell did not reach its native integrated prompt"); return end
			-- Fence membership again after the asynchronous readiness wait.
			membership(track, function(final, membership_error)
				if final == nil then fail_job(track, membership_error, "host-mismatch"); return end
				process(track, function(value, process_error)
					if value == nil then fail_job(track, process_error); return end
					if type(value.foreground) ~= "table" or value.foreground.pid ~= value.child.pid then fail_job(track, "The retained shell is no longer at an idle execution boundary"); return end
					local fresh = current(track)
					if fresh == nil or fresh.stage ~= "claimed" or fresh.pane_reused then return end
					local record, record_error = Authority.execution_record(track.binding, fresh.id)
					if record == nil then fail_job(track, "Provider submission was refused before input: " .. tostring(record_error)); return end
					local line, render_error = Executor.render(record, fresh.native.program, tern.runtime.os, fresh.initial_prompt)
					if line == nil then fail_job(track, render_error, "command-exit"); return end
					local intent, intent_error = update(track, fresh, { stage = "submission_intent", native_tab = final.tab, command = line })
					if intent == nil then fail_job(track, "Provider submission was refused before input: " .. tostring(intent_error)); return end
					track.trusted = true
					-- Persistence precedes the only provider effect. An exception or
					-- lost callback is uncertainty, never permission to repeat input.
					local wrote, write_error = pcall(tern.pane.write, track.route.pane, line .. "\r")
					if not wrote then uncertain(track, "Provider submission may be incomplete: " .. tostring(write_error)); return end
					local submitted, submit_error = Authority.update_execution(track.binding, intent.id, "submission_intent", { stage = "submitted" })
					if submitted ~= nil then notify(track.binding); return end
					local newer = current(track)
					if newer ~= nil and newer.stage == "submission_intent" then uncertain(track, "Provider input was written, but its durable submission update failed: " .. tostring(submit_error))
					elseif newer ~= nil then notify(track.binding) end
				end)
			end)
		end)
	end)
end

-- Match the complete harmless command in the actual shell command argument.
-- This accepts both observed {-c,ticket} and {-l,-c,ticket}, not an arity guess.
function Executor.ticket_argument(spec)
	if type(spec) ~= "table" or type(spec.args) ~= "table" or #spec.args > 256 then return nil end
	local ticket = nil
	for index, value in ipairs(spec.args) do
		if type(value) == "string" and value:sub(1, #"exit 125 # SPAWN:") == "exit 125 # SPAWN:" then
			if ticket ~= nil or index ~= #spec.args then return nil end
			local flag = spec.args[index - 1]
			if type(flag) ~= "string" or (flag:lower() ~= "-c" and flag:lower() ~= "-command") then return nil end
			ticket = value
		end
	end
	return ticket
end
local function spawn(spec)
	local ticket = Executor.ticket_argument(spec)
	if ticket == nil then return nil end
	local entry = prepared[ticket]
	if entry == nil then return nil end
	local binding, job = entry.binding, entry.job
	local shell, shell_error = shell_kind(spec.program, tern.runtime.os)
	local route, routing_error = Native.from_spawn(spec)
	if shell == nil or route == nil then
		tern.timer(50, function()
			local failed, err = Authority.update_execution(binding, job.id, "admitted", { stage = "failed" }, { phase = "Failed", error_category = "host-mismatch", diagnostic = shell_error or routing_error })
			notify(binding, if failed == nil then err else nil)
		end)
		return nil
	end
	-- The native filter has only 50 ms, including storage calls. Capture once
	-- in memory here; durable claim and all journal work run after it returns.
	local id = key(binding, job.id)
	if tracks[id] ~= nil or by_pane[route.pane] ~= nil then return nil end
	local track = { binding = binding, id = job.id, route = route, owned = true, trusted = false, started = false, stopped = false }
	tracks[id], by_pane[route.pane], prepared[ticket] = track, track, nil
	local program = spec.program
	local scheduled = pcall(tern.timer, 50, function()
		local claimed, claim_error = Authority.claim_execution(binding, job.id, {
			pane = route.pane, window_key = route.window, program = program, executable = route.executable, socket = route.socket,
		})
		if claimed == nil then
			fail_job(track, "Host claim was refused before execution: " .. tostring(claim_error))
			return
		end
		prune(binding)
		notify(binding)
		submit(track)
	end)
	if not scheduled then
		tracks[id], by_pane[route.pane] = nil, nil
		return nil
	end
	spec.args = {}
	spec.cwd = job.cwd
	return spec
end

local function command_started(event)
	local track = by_pane[event.pane]
	if track == nil or not (track.owned or track.bound) then return end
	local job = current(track)
	if job == nil then return end
	if event.line ~= job.command or TERMINAL[job.stage] or track.started then
		local patch, observation = { pane_reused = true }, nil
		if not TERMINAL[job.stage] then
			patch.stage = if job.command == nil then "failed" else "unknown"
			observation = { phase = if patch.stage == "failed" then "Failed" else "Unknown", diagnostic = "An unrelated command started in this retained pane; no further provider input is permitted" }
		end
		update(track, job, patch, observation)
		return
	end
	if not track.trusted or job.pane_reused or not still_active(job) then return end
	track.started = true
	if update(track, job, { stage = "running" }, { phase = "Running" }) ~= nil then capture_provider(track) end
end
local function command_finished(event)
	local track = by_pane[event.pane]
	if track == nil or not track.trusted then return end
	local job = current(track)
	if job == nil or job.command == nil or event.line ~= job.command or job.pane_reused or job.stage == "completed" or job.stage == "failed" then return end
	if type(event.status) ~= "number" or event.status % 1 ~= 0 or math.abs(event.status) > 9007199254740991 then uncertain(track, "Native completion did not include a valid exit status"); return end
	update(track, job, { stage = "completed" }, {
		phase = if event.status == 0 then "Exited" else "Failed", exit_status = event.status,
		error_category = if event.status == 0 then nil else "command-exit",
	})
end
local function pane_exited(event)
	local track = by_pane[event.pane]
	if track == nil or not (track.owned or track.bound) then return end
	fail_job(track, "The retained native pane exited without a matching provider completion; no provider exit status can be inferred")
end
local function recover(track, job)
	local epoch = Native.epoch()
	if job.epoch == nil or epoch == nil or job.epoch ~= epoch then
		detach_observer(track)
		uncertain(track, "The daemon epoch is different or unverifiable after reload; execution will not be repeated")
		return
	end
	membership(track, function(found, problem)
		if found == nil then detach_observer(track); uncertain(track, problem); return end
		track.bound = true
		local fresh = current(track)
		if fresh == nil then return end
		if fresh.stage == "completed" or fresh.stage == "failed" then track.trusted = true; return end
		if fresh.process_identity == nil then uncertain(track, "No verified provider process identity survived reload; execution will not be repeated"); return end
		process(track, function(value, process_error)
			if value == nil then uncertain(track, process_error); return end
			local latest = current(track)
			if latest == nil then return end
			if foreground_identity(value) ~= latest.process_identity then uncertain(track, "The original provider process is not verifiably active after reload; its completion is unknown"); return end
			track.trusted, track.started = true, true
			if latest.stage ~= "resolved" and update(track, latest, { stage = "running" }, { phase = "Running", diagnostic = "The same host provider process was verified after reload" }) == nil then return end
		end)
	end)
end
function Executor.attach(binding)
	if not installed then error("Host executor must be installed before attaching authority") end
	local recovering = not attached[binding.session_key]
	for ticket, entry in pairs(prepared) do
		if entry.binding.session_key == binding.session_key then prepared[ticket] = nil end
	end
	local jobs, err = Authority.execution_jobs(binding)
	if jobs == nil then attached[binding.session_key] = nil; notify(binding, err); return end
	attached[binding.session_key] = true
	for _, job in ipairs(jobs) do
		-- Managed reservations have no ticket and cannot enter this executor.
		if type(job.ticket) ~= "string" then continue end
		if job.stage == "admitted" and tracks[key(binding, job.id)] == nil then
			prepared[job.ticket] = { binding = binding, job = job }
			-- An unclaimed ticket becomes Unknown at its deadline without waiting
			-- for another refresh: the reload path runs the authority's expiry.
			if not expiring[job.ticket] then
				expiring[job.ticket] = true
				local delay = math.max(1, job.admitted_at + Authority.ADMISSION_SECONDS + 1 - os.time())
				tern.timer(delay * 1000, function() expiring[job.ticket] = nil; notify(binding) end)
			end
		elseif recovering and job.native ~= nil then
			local track = register(binding, job, false)
			if track ~= nil then recover(track, job) end
		end
	end
end
function Executor.install(authority, changed)
	if installed then error("Host executor hooks are already installed") end
	Authority, on_change, installed = authority, changed, true
	tern.on("spawn", spawn)
	tern.on("command_started", command_started)
	tern.on("command_finished", command_finished)
	tern.on("pane_exited", pane_exited)
	-- Recovery never enters submit(); only a fresh successful spawn claim can.
	tern.timer(1, function()
		local bindings, err = Authority.execution_bindings()
		if bindings == nil then notify(nil, err); return end
		for _, binding in ipairs(bindings) do Executor.attach(binding) end
	end)
end

return Executor
