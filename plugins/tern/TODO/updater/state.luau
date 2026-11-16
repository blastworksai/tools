-- Vendored from shared/tern-updater by sync.py; edit there, then run sync.py.
-- Pure updater transitions. Deadlines describe uncertainty; they never release ownership.
local Version = require("./version")
local Journal = require("./journal")
local State = {}
State.INTERVAL = 21600
State.PENDING_TIMEOUT = 600
State.ORCH = "ORCH+ reconnects automatically after reload; unresolved ownership or interrupted operations remain paused for recovery"

local function cache(record)
	local out = {}
	if type(record) == "table" then
		if type(record.checked_at) == "number" then out.checked_at = record.checked_at end
		if type(record.remote) == "string" then out.remote = record.remote end
		if type(record.notified) == "string" then out.notified = record.notified end
	end
	return out
end
local function compare(installed, remote)
	if type(installed) ~= "string" or type(remote) ~= "string" then return "unknown" end
	local order = Version.compare(installed, remote)
	return if order == -1 then "update" elseif order == 0 then "current" elseif order == 1 then "ahead" else "unknown"
end
function State.due(record, now)
	local at = cache(record).checked_at
	return at == nil or now < at or now - at >= State.INTERVAL
end
function State.outcome(record, installed)
	local remote = cache(record).remote
	return if remote == nil then "none" else compare(installed, remote)
end
function State.after_check(record, now, installed, remote, err, name)
	local out = cache(record)
	out.checked_at = now
	if err ~= nil then return out, "error", nil end
	out.remote = if type(remote) == "string" then remote else nil
	local outcome = compare(installed, out.remote)
	if outcome == "update" and out.notified ~= out.remote then
		out.notified = out.remote
		return out, outcome, { level = "info", text = `{name} {out.remote} is available (you have {installed})` }
	end
	return out, outcome, nil
end
local function text(value, limit)
	return type(value) == "string" and value ~= "" and #value <= limit and not value:find("%z")
end
local PHASES = { planned = true, probing = true, installing = true, observing = true, unknown = true, result = true }
local RESULTS = { verified = true, mismatch = true, failed = true, not_updated = true, resolved_unknown = true }
local function optional_boolean(value)
	return value == nil or type(value) == "boolean"
end
local function command_valid(command)
	if type(command) ~= "table" or type(command.serial) ~= "number"
		or command.serial < 1 or command.serial % 1 ~= 0 or not text(command.kind, 64)
		or not text(command.line, 32768) then return false end
	if not optional_boolean(command.completed) or not optional_boolean(command.timed_out)
		or not optional_boolean(command.spawn_failed) or not optional_boolean(command.encoded_output) then return false end
	if command.completed == true and (type(command.status) ~= "number" or command.status % 1 ~= 0) then return false end
	if command.identity ~= nil and (type(command.identity) ~= "table" or type(command.identity.pid) ~= "number"
		or command.identity.pid < 1 or command.identity.pid % 1 ~= 0
		or type(command.identity.started) ~= "number" or command.identity.started < 0) then return false end
	if command.argv ~= nil then
		if type(command.argv) ~= "table" or #command.argv < 1 or #command.argv > 256 then return false end
		local count = 0
		for index, argument in pairs(command.argv) do
			if type(index) ~= "number" or index % 1 ~= 0 or index < 1 or index > #command.argv
				or type(argument) ~= "string" or #argument > 32768 or argument:find("%z") then return false end
			count += 1
		end
		if count ~= #command.argv then return false end
	end
	return true
end
local function resolution_valid(record)
	local reference = record.payload.resolving
	if reference == nil then return true end
	if record.phase ~= "resolving" or type(reference) ~= "table" or not text(reference.name, 255)
		or reference.name == "." or reference.name == ".." or reference.name:find("[/\\]")
		or (reference.kind ~= "self" and reference.kind ~= "takeover" and reference.kind ~= "unknown" and reference.kind ~= "cleanup")
		or not optional_boolean(reference.owner_stopped_attested) or not optional_boolean(reference.operation_stopped_attested)
		or (reference.owner ~= nil and not Journal.owner_valid(reference.owner)) then return false end
	if reference.name ~= Journal.filename(record.owner) and type(reference.bytes_base64) ~= "string" then return false end
	return reference.bytes_base64 == nil or type(reference.bytes_base64) == "string"
end
function State.valid(record)
	if not Journal.valid(record) or not resolution_valid(record)
		or type(record.payload.targets) ~= "table" or #record.payload.targets > 2 then return false end
	if record.payload.legacy ~= nil and (type(record.payload.legacy) ~= "table"
		or record.phase ~= "resolving" or record.payload.legacy.owner_stopped_attested ~= true
		or record.payload.legacy.operation_stopped_attested ~= true) then return false end
	local count, seen = 0, {}
	for index, target in pairs(record.payload.targets) do
		if type(index) ~= "number" or index % 1 ~= 0 or index < 1 or index > #record.payload.targets
			or type(target) ~= "table" or not text(target.id, 128) or seen[target.id]
			or (target.kind ~= "local" and target.kind ~= "remote") or not text(target.label, 256)
			or not text(target.source, 4096) or not text(target.preview, 128) or not text(target.from, 128)
			or not PHASES[target.phase] then return false end
		if target.result ~= nil and (type(target.result) ~= "table" or not RESULTS[target.result.kind]
			or not text(target.result.text, 1024) or (target.result.presented ~= nil and type(target.result.presented) ~= "boolean")) then return false end
		if target.command ~= nil and not command_valid(target.command) then return false end
		if target.install ~= nil and (not command_valid(target.install) or target.install.kind ~= "install") then return false end
		if not optional_boolean(target.unknown_attempt) then return false end
		if target.plugins_dir ~= nil and not text(target.plugins_dir, 4096) then return false end
		if target.route ~= nil and (type(target.route) ~= "table"
			or (target.route.socket ~= false and not text(target.route.socket, 4096))
			or (target.route.config ~= false and not text(target.route.config, 4096))) then return false end
		if target.kind == "remote" and (target.command ~= nil or target.install ~= nil)
			and (type(target.host) ~= "table" or type(target.host.id) ~= "number"
				or type(target.pane) ~= "number" or type(target.platform) ~= "table"
				or (target.platform.kind ~= "posix" and target.platform.kind ~= "powershell")) then return false end
		seen[target.id], count = true, count + 1
	end
	return count == #record.payload.targets
end
function State.resolver_dependencies(store, original)
	local allowed, cursor, seen = { [original.name] = true }, original, {}
	for _ = 1, Journal.MAX_FILES do
		if seen[cursor.name] then return nil, "Resolver references form a cycle; all records were preserved" end
		seen[cursor.name] = true
		if cursor.record ~= nil and (not State.valid(cursor.record) or Journal.filename(cursor.record.owner) ~= cursor.name) then
			return nil, "Resolver payload or filename identity is malformed; all records were preserved"
		end
		local reference = cursor.record and cursor.record.payload.resolving
		if reference == nil or reference.name == cursor.name then return allowed end
		allowed[reference.name] = true
		local unpacked, expected = pcall(tern.base64.decode, reference.bytes_base64)
		if not unpacked or type(expected) ~= "string" then return nil, "The retained dependency-byte fence is unreadable" end
		local next_row = store.read(reference.name)
		if next_row.bytes == nil then
			local rows, err = store.scan()
			if rows == nil then return nil, err end
			for _, row in ipairs(rows) do
				if row.name == reference.name then return nil, "The updater dependency is unreadable, not absent" end
			end
			-- Explicitly unknown original bytes are a terminal obligation, not a
			-- trusted resolver graph. Their proven absence needs no reconstruction.
			if reference.kind == "unknown" then return allowed end
			local decoded, value = pcall(tern.json.decode, expected)
			if not decoded or not State.valid(value) or Journal.filename(value.owner) ~= reference.name then
				return nil, "The retained resolver dependency is malformed or has a different owner"
			end
			next_row = { name = reference.name, bytes = expected, record = value }
		elseif next_row.bytes ~= expected then
			return nil, "An updater dependency changed while resolution was pending"
		end
		if reference.kind == "unknown" then return allowed end
		if next_row.record == nil then return nil, "The updater resolver dependency is malformed" end
		cursor = next_row
	end
	return nil, "Resolver dependency chain exceeds its bound"
end
local function clone(record)
	local out = table.clone(record)
	out.revision = record.revision + 1
	out.payload = table.clone(record.payload)
	out.payload.targets = {}
	for _, target in ipairs(record.payload.targets) do table.insert(out.payload.targets, table.clone(target)) end
	return out
end
function State.target(record, id)
	if not State.valid(record) then return nil end
	for _, target in ipairs(record.payload.targets) do if target.id == id then return target end end
	return nil
end
function State.begin(owner, attempt, now, targets, orch)
	local record = { schema = 2, owner = owner, attempt = attempt, revision = 0, phase = "claiming",
		payload = { started_at = now, targets = targets, orch = orch == true } }
	if not State.valid(record) or #targets == 0 then return nil, "Invalid updater attempt" end
	return record
end
function State.command(record, id, kind, line, now, argv)
	local current = State.target(record, id)
	if current == nil or current.result ~= nil then return nil, "Updater target is no longer pending" end
	if kind == "install" and record.phase == "resolving" then return nil, "Outcome resolution cannot launch an installer" end
	local out = clone(record)
	local target = State.target(out, id)
	target.command = { kind = kind, line = line, serial = if current.command then current.command.serial + 1 else 1,
		started_at = now, argv = argv }
	target.phase = if kind == "install" then "installing" else "probing"
	if kind == "install" then target.install = table.clone(target.command) end
	out.phase = if record.phase == "resolving" then "resolving" else "pending"
	if not State.valid(out) then return nil, "Invalid updater command" end
	return out
end
function State.command_result(record, id, attempt, serial, result)
	local current = State.target(record, id)
	if current == nil or record.attempt ~= attempt or current.command == nil or current.command.serial ~= serial
		or current.command.completed == true then return nil, "Updater completion belongs to an older command" end
	if type(result) ~= "table" or type(result.status) ~= "number" then return nil, "Native command completion is unavailable" end
	local out = clone(record)
	local target = State.target(out, id)
	target.command = table.clone(current.command)
	target.command.completed = true
	target.command.status = result.status
	target.command.timed_out = result.timed_out == true
	target.command.spawn_failed = result.spawn_failed == true
	target.phase = if result.timed_out then "unknown" else "observing"
	if current.command.kind == "install" then
		target.install = table.clone(target.command)
		-- A callback proves this invocation ended, not reload health or descendant health.
		target.install.completion = if result.spawn_failed then "not_started" else "native_callback"
	end
	return out
end
function State.patch_target(record, id, patch)
	if State.target(record, id) == nil then return nil, "Updater target is unavailable" end
	local out = clone(record)
	local target = State.target(out, id)
	for key, value in pairs(patch) do target[key] = value end
	if not State.valid(out) then return nil, "Invalid updater target transition" end
	return out
end
local function health_problem(target, observed)
	local requirements = observed.requirements
	if type(requirements) ~= "table" or requirements.observed ~= true then return "Installed requirements have not been read" end
	if requirements.satisfied ~= true then return requirements.problem or "Installed requirements are not satisfied" end
	local host = observed.host
	if type(host) ~= "table" or host.observed ~= true then return "Running host catalog is unavailable" end
	if host.status ~= "ready" or host.version ~= target.preview then return "Running host catalog does not match the preview" end
	if host.paused == true or host.problems == true then return "Running host reports paused hooks or plugin problems" end
	if target.kind == "local" then
		local window = observed.window
		if type(window) ~= "table" or window.registered ~= true or window.version ~= target.preview then
			return "This window has not registered the preview's updater entry point"
		end
		if window.paused == true then return "This window reports paused plugin hooks" end
	end
	return nil
end
local function terminal(target, kind, text, detail)
	target.phase = "result"
	target.result = { kind = kind, text = text, detail = detail, presented = false }
end
-- `observed.targets[id]` keeps invocation, package, actual requirements, host and
-- this-window evidence separate. A version string alone cannot settle an attempt.
function State.reconcile(record, now, observed, name)
	if not State.valid(record) then return nil, "Updater record is not valid" end
	if type(observed) ~= "table" or type(observed.targets) ~= "table" then return nil, "Structured updater observations are required" end
	local out = clone(record)
	for _, target in ipairs(out.payload.targets) do
		local evidence = observed.targets[target.id]
		if target.result == nil and type(evidence) == "table" then
			target.observed = evidence
			local installed = evidence.installed
			if evidence.operation == "running" then
				target.phase, target.reason = "installing", "The original installer is still running"
			elseif evidence.operation ~= "stopped" then
				target.phase, target.reason = "unknown", "Original installer quiescence is not proven"
			elseif type(installed) ~= "table" or installed.observed ~= true or not text(installed.version, 128) then
				target.phase, target.reason = "unknown", "Installed package version is not observable"
			elseif installed.version ~= target.preview then
				if installed.version ~= target.from then
					terminal(target, "mismatch", `{name} on {target.label}: preview {target.preview}, installed {installed.version}`,
						"Installed version differs from the approved preview; no exact-preview success is claimed")
				elseif target.install and target.install.completed and not target.install.timed_out and target.install.status ~= 0 then
					terminal(target, "failed", `{name} installer failed on {target.label}; observed version {installed.version}`,
						"No claim that package bytes were unchanged")
				else
					target.phase, target.reason = "unknown", "The previous version is present; that does not prove unchanged package bytes"
				end
			else
				local problem = health_problem(target, evidence)
				if problem ~= nil then
					target.phase, target.reason = "unknown", problem
				else
					terminal(target, "verified", `{name} {target.preview} installed on {target.label}`,
						"Actual requirements satisfied; host catalog ready. "
						.. (if target.kind == "local" then "This window's updater entry registered. " else "Remote window registration not claimed. ")
						.. (if evidence.host.hooks_observed == true then "Host hooks observed. " else "Host hook-pause diagnostics unavailable. ")
						.. "Other windows and same-version byte identity are not verified")
				end
			end
		end
		if target.result == nil and type(out.payload.started_at) == "number"
			and now - out.payload.started_at >= State.PENDING_TIMEOUT then
			target.deadline_elapsed = true
			-- Keep the target and its complete ownership/command evidence.
		end
	end
	if not State.valid(out) then return nil, "Updater observations exceed the saved-state contract" end
	return out
end
function State.not_started(record, id, reason)
	local current = State.target(record, id)
	if current == nil or current.install ~= nil or (current.command and current.command.kind == "install") then
		return nil, "An attempted install cannot be classified as not started"
	end
	local out = clone(record)
	terminal(State.target(out, id), "not_updated", current.label .. " was not updated", reason)
	return out
end
function State.resolve(record, id, observation, attest_stopped)
	local current = State.target(record, id)
	if current == nil or current.result ~= nil then return nil, "Updater target is no longer unresolved" end
	if type(observation) ~= "table" or observation.operation == "running" then return nil, "The original installer is still running or unobserved" end
	if observation.operation ~= "stopped" and attest_stopped ~= true then return nil, "Explicit original-operation-stopped attestation is required" end
	local out = clone(record)
	local target = State.target(out, id)
	target.observed = observation
	terminal(target, "resolved_unknown", current.label .. " update outcome explicitly resolved as unverified",
		if observation.operation == "stopped" then "Fresh invocation-quiescence evidence; installation health remains unverified"
		else "Owner attested that the original operation stopped; installation health remains unverified")
	return out
end
function State.presented(record, id)
	local current = State.target(record, id)
	if current == nil or current.result == nil then return nil, "No updater outcome is ready to present" end
	local out = clone(record)
	local target = State.target(out, id)
	target.result = table.clone(current.result)
	target.result.presented = true
	return out
end
function State.finished(record)
	if not State.valid(record) or #record.payload.targets == 0 then return false end
	for _, target in ipairs(record.payload.targets) do
		if target.result == nil or target.result.presented ~= true then return false end
	end
	return true
end
return State
