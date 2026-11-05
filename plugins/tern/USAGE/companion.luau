--!strict
-- Owner-local stdlib launcher only. No HTTP, authority-file reads or shell.
-- Callbacks are (successful envelope | nil, {code,message} | nil, fresh cx | nil).
-- invalidate completes outstanding calls as cancelled; it cannot kill running
-- Tern processes, so every process also has a Tern timeout and stale callbacks drop.
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
	python_required = "Python 3.11 or newer is required; open USAGE Setup.",
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
type Failure = { code: string, message: string }
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

local function failure(code: string): Failure
	local known = if MESSAGES[code] ~= nil then code else "internal_error"
	return { code = known, message = MESSAGES[known] }
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
	pending[job] = true
	job.timer = tern.timer(timeout, function(cx)
		job.timer = nil
		finish(job, nil, failure("timeout"), cx)
	end)
	return job
end

local function live(job: Job): boolean
	return not job.done and job.generation == generation
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
	if os == "macos" then return { { "python3" }, { "/opt/homebrew/bin/python3" }, { "/usr/local/bin/python3" } }, nil end
	if os == "linux" then return { { "python3" } }, nil end
	local paths = { { "py", "-3" }, { "python3" }, { "python" } }
	-- Standard python.org per-user and all-user installs work without GUI PATH.
	for _, variable in { "LOCALAPPDATA", "ProgramFiles", "ProgramFiles(x86)" } do
		local base = tern.getenv(variable)
		if executable(base) then
			for minor = 15, 11, -1 do
				local directory = if variable == "LOCALAPPDATA" then "/Programs/Python/Python3" else "/Python3"
				table.insert(paths, { base .. directory .. tostring(minor) .. "/python.exe" })
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
	local encoded, stdin = pcall(tern.json.encode, input)
	if not encoded then deferFailure(job, "invalid_request"); return end
	if #stdin > MAX_BODY then deferFailure(job, "snapshot_too_large"); return end
	discover(job, function(argv)
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
				finish(job, nil, failure(code), cx)
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

-- Configure before ensure; changing clients cancels the preceding owner's work.
function companion.set_client(id: string, kind: string)
	if id ~= clientId or kind ~= clientKind then companion.invalidate() end
	clientId, clientKind = id, kind
end

-- install_dependencies=true is only supplied by an explicit Setup action.
-- A configured usage_python is authoritative: invalid/missing never falls back.
function companion.ensure(callback: Callback, options: any?)
	local job = newJob(callback, ENSURE_MS)
	if type(clientId) ~= "string" or #clientId < 1 or #clientId > 160 or not clientId:match("^[%w_.:%-]+$")
		or (clientKind ~= "host" and clientKind ~= "window" and clientKind ~= "setup") then
		deferFailure(job, "invalid_request"); return
	end
	if options ~= nil then
		if type(options) ~= "table" then deferFailure(job, "invalid_request"); return end
		for key, value in options do
			if key ~= "install_dependencies" or type(value) ~= "boolean" then deferFailure(job, "invalid_request"); return end
		end
	end
	launch(job, "ensure", { client_id = clientId, client_kind = clientKind,
		install_dependencies = options ~= nil and options.install_dependencies == true })
end

function companion.request(operation: string, payload: any, callback: Callback)
	local job = newJob(callback, REQUEST_MS)
	if type(operation) ~= "string" or #operation > 64 or not operation:match("^[a-z][a-z_]*$") or type(payload) ~= "table" then
		deferFailure(job, "invalid_request"); return
	end
	launch(job, "rpc", { operation = operation, payload = payload })
end

function companion.invalidate()
	generation += 1
	selected = nil
	for job in pending do
		if job.timer ~= nil then job.timer:cancel(); job.timer = nil end
		deferFailure(job, "cancelled")
	end
end

return companion
