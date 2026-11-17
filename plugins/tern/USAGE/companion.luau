--!strict
-- Owner-local stdlib launcher only. No HTTP, authority-file reads or shell.
-- Callbacks are (successful envelope | nil, {code,message} | nil, fresh cx | nil).
-- Unload releases only this VM's client lease. The service's bounded lease expiry
-- remains authoritative when unload or a process callback cannot finish.
local companion = {}
local MAX_BODY = 1048576
local PROBE_MS = 3000
local ENSURE_MS = 390000
local REQUEST_MS = 30000
local PROBE = 'import json,sys;print(json.dumps({"major":sys.version_info[0],"minor":sys.version_info[1]}))'
-- Fixed user-facing text per code; companion-supplied text never crosses this
-- boundary. Service codes mirror usage_service/protocol.py MESSAGES.
local MESSAGES: { [string]: string } = {
	-- Launcher-local failures.
	cancelled = "The USAGE operation was cancelled.",
	timeout = "The USAGE operation timed out.",
	spawn_failed = "The local USAGE launcher could not start.",
	decode_failed = "The local USAGE launcher returned an invalid response.",
	response_too_large = "The local USAGE response exceeds its size limit.",
	python_required = "Python 3.11 or newer was not found.",
	unsupported_platform = "The USAGE companion is unavailable on this platform.",
	configuration_unavailable = "USAGE could not read its interpreter configuration.",
	-- Companion service errors.
	snapshot_rejected = "The snapshot was rejected.",
	snapshot_too_large = "The snapshot exceeds the configured size limit.",
	invalid_request = "The request is invalid.",
	unauthorized = "Authorization is required.",
	forbidden = "This operation is not authorized.",
	conflict = "The request conflicts with existing state.",
	replay = "The publication is older than accepted state.",
	capacity = "Coverage is incomplete because a configured limit was reached.",
	not_found = "The requested record is unavailable.",
	expired = "The request has expired.",
	web_login_expired = "The provider login has expired. Sign in again with the provider's own CLI.",
	source_remote = "Runs on another machine over SSH; USAGE reads it only on that machine.",
	api_key_login = "Signed in with an API key, which has no subscription quota.",
	web_login_forbidden = "The provider refused this login's usage request. Sign in again with the provider's own CLI to grant usage access.",
	source_unreachable = "The sharing source is unreachable.",
	pin_mismatch = "The sharing certificate does not match the paired identity.",
	address_in_use = "The sharing port is already in use on this machine.",
	address_unavailable = "The sharing address is not available on this machine.",
	bind_failed = "USAGE could not listen on the sharing address.",
	setup_required = "USAGE setup is required.",
	companion_unavailable = "The local USAGE companion is unavailable.",
	incompatible_version = "The companion and package versions do not match.",
	migration_conflict = "Existing installation identities conflict; neither was changed.",
	internal_error = "USAGE could not complete the operation.",
	unsupported_tern = "This Tern installation does not support source collection.",
	source_context_ambiguous = "The source profile cannot be identified unambiguously.",
	source_capture_too_large = "The current source capture exceeds the size limit.",
	source_profile_invalid = "The source profile configuration is invalid.",
	source_profile_unavailable = "The source profile is unavailable.",
	source_profile_stale = "The source profile changed; confirm its current identity.",
	source_helper_unverified = "The source helper does not match this installation.",
	source_metadata_disabled = "Headless usage reads are off; choose Allow headless usage reads in USAGE Setup.",
	source_roster_invalid = "SPAWN's account list is invalid. Check its configuration in SPAWN.",
	source_roster_unavailable = "SPAWN's account list could not be read.",
	source_roster_version = "This SPAWN source version is unsupported; update USAGE. Accounts were not changed.",
	display_disabled = "Enable Show usage in ORCH+ in USAGE Setup.",
	local_login_unavailable = "No usable local provider login is available.",
	vendor_usage_unavailable = "The provider's usage endpoint cannot currently prove this allowance.",
	source_timeout = "The provider usage read exceeded its deadline.",
	source_usage_unavailable = "The provider quota is unavailable.",
	source_configuration_changed = "SPAWN changed during refresh; request a new reading.",
	export_disabled = "Enable read-only capacity export in USAGE Setup.",
	export_revoked = "Capacity authorization changed; request a new snapshot after owner approval.",
	evidence_changed = "Capacity evidence changed; assemble a new complete snapshot.",
	incomplete = "Assemble every snapshot page before current validation.",
	binding_unavailable = "This SPAWN account has no current headless reading with a provider identity; refresh, then bind it.",
	binding_changed = "The SPAWN account or its reading changed; choose Bind SPAWN accounts again.",
}
-- Why a first-start bootstrap failed, keyed by the launcher's fixed `state` value. The
-- launcher never supplies text; only a pattern-checked package pin and interpreter
-- version may be interpolated.
local STATES: { [string]: string } = {
	dependency_consent_required = "USAGE has not installed its private dependencies yet. Open USAGE Setup and choose Install private dependencies.",
	dependency_install_failed = "USAGE could not install its private dependencies. Check Python and PyPI access, then retry in USAGE Setup.",
	dependency_network_failed = "USAGE could not reach PyPI to install its private dependencies. Check the network or proxy, then retry in USAGE Setup.",
	dependency_hash_mismatch = "A downloaded dependency did not match USAGE's pinned hash, so nothing was installed. Retry in USAGE Setup; report it if it repeats.",
	dependency_wheel_unavailable = "This Python has no prebuilt wheel for a USAGE dependency. Install Python 3.12, then choose Select existing Python interpreter in USAGE Setup (usage_python).",
	python_venv_unavailable = "This Python cannot create a private environment (venv or ensurepip is missing). Install the python3-venv package, or choose another interpreter in USAGE Setup (usage_python).",
	python_311_required = "Python 3.11 or newer is required; choose a newer interpreter in USAGE Setup (usage_python).",
	platform_unsupported = "The USAGE companion is unavailable on this platform.",
	start_failed = "The USAGE companion process could not start. Open USAGE Diagnostics.",
	start_timeout = "The USAGE companion process did not become ready in time. Open USAGE Diagnostics.",
}
local INSTALLING = "USAGE is installing its private dependencies for the first time; this can take a few minutes."
type Failure = { code: string, message: string, specific: boolean?, state: string? }
type Callback = (any?, Failure?, any?) -> ()
type Job = {
	generation: number, deadline: number, callback: Callback, done: boolean,
	timer: any?, dispatch: any?,
}
local generation = 0
local pending: { [Job]: boolean } = {}
local selected: { string }? = nil
local clientId: string? = nil
local clientKind: string? = nil
local leaseId: string? = nil
local leasePrefix: { string }? = nil
local closed = false
-- Cause of the latest bootstrap outcome in this VM, so later requests report it instead of
-- the generic "unavailable"; one automatic install per VM, so a failure is never a retry loop.
local bootstrapNote: Failure? = nil
local autoInstallTried = false

-- The install road differs by operating system, so the one sentence after the fixed text does too.
local PYTHON_ROAD: { [string]: string } = {
	windows = " Install it from python.org, then open USAGE Setup.",
	macos = " Install it from python.org or with Homebrew, then open USAGE Setup.",
	linux = " Install it with venv support using your distribution's package manager, then open USAGE Setup.",
}

local function failure(code: string): Failure
	local known = if MESSAGES[code] ~= nil then code else "internal_error"
	local message = MESSAGES[known]
	if known == "python_required" then message ..= PYTHON_ROAD[tern.runtime.os] or " Open USAGE Setup." end
	return { code = known, message = message }
end

local function validPin(value: any): boolean
	return type(value) == "string" and #value <= 100
		and (value:match("^[%w][%w%._%-]*$") ~= nil or value:match("^[%w][%w%._%-]*==[%w%.!%+_%-]+$") ~= nil)
end

-- The code stays the service's own; only the message is refined, and only from fixed text.
local function failureOf(code: string, value: any): Failure
	local base = failure(code)
	if (code ~= "setup_required" and code ~= "companion_unavailable") or type(value.state) ~= "string" then return base end
	local text = STATES[value.state]
	if text == nil then return base end
	if value.state == "dependency_wheel_unavailable" and validPin(value.package)
		and type(value.python) == "string" and value.python:match("^%d+%.%d+$") ~= nil then
		text = string.format("Python %s has no prebuilt wheel for %s. Install Python 3.12, then choose Select existing Python interpreter in USAGE Setup (usage_python).",
			value.python, value.package)
	end
	return { code = base.code, message = text, specific = true, state = value.state }
end

local function finish(job: Job, value: any?, err: Failure?, cx: any?)
	if job.done then return end
	job.done = true
	pending[job] = nil
	if job.timer ~= nil then job.timer:cancel(); job.timer = nil end
	if job.dispatch ~= nil then job.dispatch:cancel(); job.dispatch = nil end
	if job.generation ~= generation then value = nil; err = failure("cancelled") end
	-- A caller exception must not become a spawn error or a second completion.
	local ok = pcall(job.callback, value, err, if tern.context == "window" then cx else nil)
	if not ok then tern.log.warn("USAGE callback_failed") end
end

local function deferFailure(job: Job, code: string)
	if job.dispatch ~= nil then job.dispatch:cancel() end
	job.dispatch = tern.timer(0, function(cx)
		job.dispatch = nil
		finish(job, nil, failure(code), cx)
	end)
end

local function newJob(callback: Callback, timeout: number): Job
	local job: Job = { generation = generation, deadline = tern.now() + timeout, callback = callback, done = false }
	if closed then deferFailure(job, "cancelled"); return job end
	pending[job] = true
	job.timer = tern.timer(timeout, function(cx)
		job.timer = nil
		finish(job, nil, failure("timeout"), cx)
	end)
	return job
end

local function live(job: Job): boolean
	return not closed and not job.done and job.generation == generation
end

local function run(job: Job, argv: { string }, stdin: string?, timeout: number, done: (any?, string?, any?) -> ())
	if not live(job) then return end
	local remaining = math.floor(job.deadline - tern.now())
	if remaining <= 0 then deferFailure(job, "timeout"); return end
	local settled = false
	local ok = pcall(function()
		tern.process.run(argv, { cwd = tern.plugin.data, stdin = stdin, timeout_ms = math.min(timeout, remaining) }, function(result, cx)
			if settled or not live(job) then return end
			settled = true
			if result.timed_out then done(nil, "timeout", cx)
			else done(result, nil, cx) end
		end)
	end)
	if not ok and not settled and live(job) then
		settled = true
		-- A spawn exception has no callback cx; obtain one from a Tern timer.
		job.dispatch = tern.timer(0, function(cx)
			job.dispatch = nil
			if live(job) then done(nil, "spawn_failed", cx) end
		end)
	end
end

local function executable(value: any): boolean
	return type(value) == "string" and #value > 0 and #value <= 4096
		and value:sub(1, 1) ~= "-" and not value:find("%c")
end

local function candidates(): ({ { string } }?, string?)
	local os = tern.runtime.os
	if os ~= "linux" and os ~= "macos" and os ~= "windows" then return nil, "unsupported_platform" end
	local ok, configured = pcall(tern.kv.get, "usage_python")
	if not ok then return nil, "configuration_unavailable" end
	if configured ~= nil then
		if executable(configured) then return { { configured } }, nil end
		if type(configured) == "table" and (#configured == 1 or #configured == 2) and executable(configured[1]) then
			for key in configured do
				if key ~= 1 and key ~= 2 then return nil, "invalid_request" end
			end
			if #configured == 1 or (configured[1] == "py" and configured[2] == "-3") then
				return { table.clone(configured) }, nil
			end
		end
		return nil, "invalid_request"
	end
	if os == "macos" then -- No bare python3 here: Apple's /usr/bin/python3 shim can open the developer-tools installer dialog.
		return { { "/opt/homebrew/bin/python3" }, { "/usr/local/bin/python3" },
		{ "/Library/Frameworks/Python.framework/Versions/Current/bin/python3" } }, nil end
	if os == "linux" then return { { "python3" } }, nil end
	local paths = { { "py", "-3" }, { "python3" }, { "python" } }
	-- Standard python.org per-user and all-user installs work without GUI PATH.
	for _, variable in { "LOCALAPPDATA", "ProgramFiles", "ProgramFiles(x86)" } do
		local base = tern.getenv(variable)
		if executable(base) then
			for minor = 15, 11, -1 do
				local directory = if variable == "LOCALAPPDATA" then "/Programs/Python/Python3" else "/Python3"
				table.insert(paths, { (base :: string) .. directory .. tostring(minor) .. "/python.exe" })
			end
		end
	end
	return paths, nil
end

local function discover(job: Job, done: ({ string }, any?) -> ())
	if selected ~= nil then done(table.clone(selected), nil); return end
	local paths, err = candidates()
	if paths == nil then deferFailure(job, err or "python_required"); return end
	local index = 0
	local function nextCandidate()
		if not live(job) then return end
		index += 1
		local candidate = paths[index]
		if candidate == nil then deferFailure(job, "python_required"); return end
		local prefix = table.clone(candidate)
		table.insert(prefix, "-I")
		table.insert(prefix, "-B")
		local argv = table.clone(prefix)
		table.insert(argv, "-c")
		table.insert(argv, PROBE)
		run(job, argv, nil, PROBE_MS, function(result, _, cx)
			if result ~= nil and result.status == 0 and type(result.stdout) == "string" and #result.stdout <= 256 then
				local decoded, version = pcall(tern.json.decode, result.stdout)
				if decoded and type(version) == "table" and version.major == 3 and type(version.minor) == "number"
					and version.minor >= 11 and version.minor < math.huge and version.minor % 1 == 0 then
					selected = prefix
					done(table.clone(prefix), cx)
					return
				end
			end
			nextCandidate()
		end)
	end
	nextCandidate()
end

local function launch(job: Job, command: string, input: any)
	if command == "rpc" then
		local inner = job.callback
		job.callback = function(value: any?, err: Failure?, cx: any?)
			if err ~= nil and err.code == "companion_unavailable" and not err.specific and bootstrapNote ~= nil then
				err = bootstrapNote
			end
			inner(value, err, cx)
		end
	end
	local encoded, stdin = pcall(tern.json.encode, input)
	if not encoded then deferFailure(job, "invalid_request"); return end
	if #stdin > MAX_BODY then deferFailure(job, "snapshot_too_large"); return end
	discover(job, function(argv)
		if command == "ensure" or (command == "rpc" and input.operation == "register_client") then
			leasePrefix = table.clone(argv)
		end
		table.insert(argv, tern.plugin.dir .. "/usage_service.py")
		table.insert(argv, command)
		table.insert(argv, "--data-root")
		table.insert(argv, tern.plugin.data .. "/companion")
		run(job, argv, stdin, if command == "ensure" then ENSURE_MS else REQUEST_MS, function(result, err, cx)
			if err ~= nil then finish(job, nil, failure(err), cx); return end
			if type(result.stdout) ~= "string" then finish(job, nil, failure("decode_failed"), cx); return end
			-- The launcher writes one trailing newline outside its bounded JSON body.
			local raw = result.stdout
			if #raw > MAX_BODY + 1 then finish(job, nil, failure("response_too_large"), cx); return end
			if raw:sub(-1) == "\n" then raw = raw:sub(1, -2) end
			if #raw > MAX_BODY then finish(job, nil, failure("response_too_large"), cx); return end
			local decoded, value = pcall(tern.json.decode, raw)
			if not decoded or type(value) ~= "table" or type(value.ok) ~= "boolean" then
				finish(job, nil, failure(if result.status ~= 0 then "companion_unavailable" else "decode_failed"), cx)
				return
			end
			if not value.ok then
				local code = if type(value.error) == "table" and type(value.error.code) == "string" then value.error.code else "internal_error"
				finish(job, nil, failureOf(code, value), cx)
			elseif result.status ~= 0 then finish(job, nil, failure("companion_unavailable"), cx)
			elseif command == "ensure" and (value.protocol ~= 1 or value.schema ~= 1) then
				finish(job, nil, failure("incompatible_version"), cx)
			elseif command == "ensure" then
				if type(value.device_id) ~= "string" or #value.device_id ~= 36 or type(value.build) ~= "string" then
					finish(job, nil, failure("decode_failed"), cx); return
				end
				-- Only public startup metadata crosses the launcher boundary.
				finish(job, { ok = true, state = "ready", device_id = value.device_id, build = value.build,
					protocol = value.protocol, schema = value.schema, lock_digest = value.lock_digest,
					source_digest = value.source_digest }, nil, cx)
			else finish(job, value, nil, cx) end
		end)
	end)
end

local function clientLease(): string
	if leaseId == nil then
		-- Logical window/host names recur after reload. A late old release must
		-- never remove the replacement VM's independently renewed lease.
		leaseId = string.format("%s:%d:%08x:%08x", clientKind or "client", os.time(),
			math.random(1, 2147483647), math.random(1, 2147483647))
	end
	return leaseId :: string
end

local function releaseLease()
	local id, prefix = leaseId, leasePrefix
	leaseId, leasePrefix = nil, nil
	if id == nil or prefix == nil then return end
	local argv = table.clone(prefix)
	table.insert(argv, tern.plugin.dir .. "/usage_service.py")
	table.insert(argv, "rpc")
	table.insert(argv, "--data-root")
	table.insert(argv, tern.plugin.data .. "/companion")
	-- process.run starts synchronously and its bounded child survives VM unload.
	-- Do not discover/install/start a service or wait for a callback here.
	local ok = pcall(function()
		tern.process.run(argv, { cwd = tern.plugin.data, timeout_ms = REQUEST_MS,
			stdin = tern.json.encode({ operation = "unregister_client", payload = { client_id = id } }) }, function() end)
	end)
	if not ok then tern.log.warn("USAGE client_release_deferred") end
end

-- Configure before ensure; changing clients cancels the preceding owner's work.
function companion.set_client(id: string, kind: string)
	if id ~= clientId or kind ~= clientKind then companion.invalidate() end
	clientId, clientKind = id, kind
end

-- install_dependencies=true is only supplied by an explicit Setup action.
-- A configured usage_python is authoritative: invalid/missing never falls back.
function companion.ensure(callback: Callback, options: any?)
	local job = newJob(callback, ENSURE_MS)
	if closed then return end
	if type(clientId) ~= "string" or #clientId < 1 or #clientId > 160 or not clientId:match("^[%w_.:%-]+$")
		or (clientKind ~= "host" and clientKind ~= "window" and clientKind ~= "setup") then
		deferFailure(job, "invalid_request"); return
	end
	if options ~= nil then
		if type(options) ~= "table" then deferFailure(job, "invalid_request"); return end
		for key, value in options do
			if (key ~= "install_dependencies" and key ~= "auto_install") or type(value) ~= "boolean" then
				deferFailure(job, "invalid_request"); return
			end
		end
	end
	local install = options ~= nil and options.install_dependencies == true
	-- The owner's install of the plugin is the request: the host half bootstraps once per plugin
	-- load on Linux, Windows and macOS (an unsupported OS fails in candidates()). Setup stays the retry road.
	if options ~= nil and options.auto_install == true and clientKind == "host" and not autoInstallTried then
		autoInstallTried = true
		install = true
		bootstrapNote = { code = "setup_required", message = INSTALLING, specific = true }
	end
	local inner = job.callback
	job.callback = function(value: any?, err: Failure?, cx: any?)
		if value ~= nil then bootstrapNote = nil
		elseif err ~= nil and err.code ~= "cancelled" then
			-- A check that did not try to install reports "consent required" whenever no environment
			-- exists; that must not replace the cause of the install that did fail.
			if not install and err.state == "dependency_consent_required" and bootstrapNote ~= nil then
				err = bootstrapNote
			else
				bootstrapNote = if err.specific then err else nil
			end
		end
		inner(value, err, cx)
	end
	launch(job, "ensure", { client_id = clientLease(), client_kind = clientKind, install_dependencies = install })
end

function companion.renew(callback: Callback)
	local job = newJob(callback, REQUEST_MS)
	if closed then return end
	if clientId == nil or (clientKind ~= "host" and clientKind ~= "window") then
		deferFailure(job, "invalid_request"); return
	end
	launch(job, "rpc", { operation = "register_client",
		payload = { client_id = clientLease(), kind = clientKind, ttl_seconds = 90 } })
end

function companion.request(operation: string, payload: any, callback: Callback)
	local job = newJob(callback, REQUEST_MS)
	if closed then return end
	if type(operation) ~= "string" or #operation > 64 or not operation:match("^[a-z][a-z_]*$") or type(payload) ~= "table" then
		deferFailure(job, "invalid_request"); return
	end
	launch(job, "rpc", { operation = operation, payload = payload })
end

function companion.invalidate()
	generation += 1
	releaseLease()
	selected = nil
	for job in pending do
		if job.timer ~= nil then job.timer:cancel(); job.timer = nil end
		deferFailure(job, "cancelled")
	end
end

function companion.unload()
	if closed then return end
	closed = true
	companion.invalidate()
end

function companion.on_unload(callback: (any?) -> ()): boolean
	local ok, err = pcall(tern.on, "unload", callback)
	if ok then return true end
	-- Older native runtimes reject this newer documented event. Only that
	-- exact capability rejection permits lease expiry instead of registration.
	local unsupported = if tern.context == "host" then 'tern.on: unknown host event "unload" ('
		elseif tern.context == "window" then 'tern.on: unknown window event `unload`' else nil
	-- Native registration failures are userdata, with their diagnostic exposed
	-- by tostring. Keep the original object for every non-capability failure.
	local rendered = tostring(err)
	if unsupported ~= nil and rendered:find(unsupported, 1, true) ~= nil then
		tern.log.warn("USAGE unload event unavailable; abandoned companion client leases expire automatically")
		return false
	end
	error(err, 0)
end

return companion
