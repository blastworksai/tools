--!strict
-- Pure persisted launch lifecycle. No Tern API, clock, command, or persistence calls.
--
-- Boundary: validate() checks a decoded store without repairing or copying it.
-- Mutators consume that validated state and canonical records/observations. The host
-- clones its durable state before calling them, persists the candidate, then replies.
-- A rejected mutation changes nothing; each accepted observation advances revision
-- once, even when its phase is unchanged. Request replay belongs to the authority.
--
-- Identity is (scope, observer_id, pane), never pane alone. scope is the host-derived
-- session key, not a client's numeric session alias. The observer is the stable
-- host executor identity; desktop observers only own request/allocation receipts.
-- Native pane IDs are display-only in Window snapshots and never Window API IDs.
-- A bound native pane cannot be replaced on an existing attempt.
--
-- Starting is a reservation, not proof of execution. Unknown retains the reservation
-- on close, disconnect, or unverified reload. Only terminal evidence or explicit
-- resolve releases it. A retained failed shell never becomes a running provider.
-- No attempt is automatically evicted, and IDs are never reused after cleanup.
local M = {}

export type Attempt = {
	id: string,
	record_id: string,
	scope: string,
	observer_id: string,
	sequence: number,
	mode: string,
	phase: string,
	unresolved: boolean,
	purpose: string?,
	pane: number?,
	exit_status: number?,
	error_category: string?,
	diagnostic: string?,
}

export type State = {
	version: number,
	next_attempt: number,
	revision: number,
	attempts: { Attempt },
}

export type Observation = {
	phase: string,
	scope: string?,
	pane: number?,
	exit_status: number?,
	error_category: string?,
	diagnostic: string?,
}

local MAX_ATTEMPTS = 128
local MAX_INTEGER = 9007199254740991
local ACTIVE: { [string]: boolean } = {
	Starting = true,
	Running = true,
	["Waiting for input"] = true,
}
local PHASES: { [string]: boolean } = {
	Starting = true,
	Running = true,
	["Waiting for input"] = true,
	Exited = true,
	Failed = true,
	Unknown = true,
}
local MODES: { [string]: string } = {
	["native-agent"] = "Native OMP",
	["local-terminal"] = "Terminal",
	["ssh-command"] = "SSH terminal",
}
local CATEGORIES: { [string]: boolean } = {
	["host-unavailable"] = true,
	["host-mismatch"] = true,
	["command-not-found"] = true,
	["permission-denied"] = true,
	["sign-in-required"] = true,
	["command-exit"] = true,
	unknown = true,
}
local STATE_FIELDS = { version = true, next_attempt = true, revision = true, attempts = true }
local ATTEMPT_FIELDS = {
	id = true, record_id = true, scope = true, observer_id = true, sequence = true,
	mode = true, phase = true, unresolved = true, pane = true, exit_status = true,
	error_category = true, diagnostic = true, purpose = true,
}
local OBSERVATION_FIELDS = {
	phase = true, scope = true, pane = true, exit_status = true,
	error_category = true, diagnostic = true,
}

local function integer(value: any, minimum: number): boolean
	return type(value) == "number" and value >= minimum and value <= MAX_INTEGER and value % 1 == 0
end

local function identity(value: any, maximum: number): boolean
	return type(value) == "string" and #value > 0 and #value <= maximum and not value:find("%c")
end

local function fields(value: any, allowed: { [string]: boolean }): boolean
	for key in value do
		if type(key) ~= "string" or allowed[key] ~= true then return false end
	end
	return true
end

local function terminal(phase: string): boolean
	return phase == "Exited" or phase == "Failed"
end

local function blocking(attempt: Attempt): boolean
	return ACTIVE[attempt.phase] == true or attempt.unresolved
end

local function find(state: State, id: string): Attempt?
	for _, attempt in state.attempts do
		if attempt.id == id then return attempt end
	end
	return nil
end

local function evidence_error(value: any): string?
	if value.pane ~= nil and not integer(value.pane, 0) then return "invalid-pane" end
	if value.exit_status ~= nil and not integer(value.exit_status, -MAX_INTEGER) then return "invalid-exit-status" end
	if value.error_category ~= nil and (type(value.error_category) ~= "string" or CATEGORIES[value.error_category] ~= true) then
		return "invalid-error-category"
	end
	-- Diagnostics are bounded summaries supplied by the observer, not pane output.
	-- Do not classify text, SSH 255, or waiting input as authentication/connectivity.
	if value.diagnostic ~= nil and (type(value.diagnostic) ~= "string" or #value.diagnostic > 4096) then
		return "invalid-diagnostic"
	end
	if value.exit_status ~= nil and not terminal(value.phase) then return "exit-status-without-exit" end
	return nil
end

function M.new(): State
	return { version = 1, next_attempt = 1, revision = 0, attempts = {} }
end

-- Returns the same validated object, or nil + a stable reason. Never resets a
-- future/corrupt store. Empty attempts={} is valid even after all history is cleared.
function M.validate(value: any): (State?, string?)
	if type(value) ~= "table" then return nil, "invalid-launch-state" end
	if value.version ~= 1 then return nil, "unsupported-launch-state-version" end
	if not fields(value, STATE_FIELDS) then return nil, "unexpected-state-field" end
	if not integer(value.next_attempt, 1) or not integer(value.revision, 0) then return nil, "invalid-state-counter" end
	if type(value.attempts) ~= "table" then return nil, "invalid-attempts" end
	local count = 0
	for key in value.attempts do
		if not integer(key, 1) then return nil, "invalid-attempt-index" end
		count += 1
		if count > MAX_ATTEMPTS then return nil, "capacity" end
	end
	local last_id = 0
	for index = 1, count do
		local attempt = value.attempts[index]
		if type(attempt) ~= "table" or not fields(attempt, ATTEMPT_FIELDS) then return nil, "invalid-attempt" end
		if type(attempt.id) ~= "string" then return nil, "invalid-attempt-id" end
		local digits = attempt.id:match("^attempt%-([1-9]%d*)$")
		local id = if digits then tonumber(digits) else nil
		if id == nil or not integer(id, 1) or id <= last_id or id >= value.next_attempt then return nil, "invalid-attempt-id" end
		-- Numeric conversion must not accept rounded decimal IDs or leading zeroes.
		if string.format("%.0f", id) ~= digits then return nil, "invalid-attempt-id" end
		last_id = id
		if not identity(attempt.record_id, 256) or not identity(attempt.scope, 2048) or not identity(attempt.observer_id, 256) then
			return nil, "invalid-attempt-identity"
		end
		if not integer(attempt.sequence, 0) then return nil, "invalid-sequence" end
		if attempt.mode ~= "Native OMP" and attempt.mode ~= "Terminal" and attempt.mode ~= "SSH terminal" then
			return nil, "invalid-mode"
		end
		if attempt.purpose ~= nil and attempt.purpose ~= "managed" and (attempt.purpose ~= "setup" or attempt.mode ~= "Native OMP") then return nil, "invalid-purpose" end
		if type(attempt.phase) ~= "string" or PHASES[attempt.phase] ~= true then return nil, "invalid-phase" end
		if type(attempt.unresolved) ~= "boolean" then return nil, "invalid-reservation" end
		if (ACTIVE[attempt.phase] == true and not attempt.unresolved) or (terminal(attempt.phase) and attempt.unresolved) then
			return nil, "invalid-reservation"
		end
		local err = evidence_error(attempt)
		if err then return nil, err end
		if attempt.phase == "Exited" and attempt.exit_status ~= nil and attempt.exit_status ~= 0 then
			return nil, "nonzero-successful-exit"
		end
		if (attempt.phase == "Running" or attempt.phase == "Waiting for input") and attempt.pane == nil then
			return nil, "unbound-live-attempt"
		end
		if attempt.pane ~= nil and blocking(attempt) then
			for earlier = 1, index - 1 do
				local other = value.attempts[earlier]
				if blocking(other) and other.scope == attempt.scope and other.observer_id == attempt.observer_id and other.pane == attempt.pane then
					return nil, "pane-already-bound"
				end
			end
		end
	end
	return value, nil
end

-- reserve returns an aliased attempt in the caller's candidate. Admission outcomes
-- skip/capacity/review do not allocate IDs or change revisions. Roster disabled is
-- skip; an explicit setup helper is independent of roster enabled/duplicate policy.
-- Helpers retain the real record ID but never block ordinary roster admission.
function M.reserve(state: State, record: any, scope: string, observer_id: string, purpose: string?): (Attempt?, string?)
	if purpose ~= nil and purpose ~= "launch" and purpose ~= "setup" and purpose ~= "managed" then return nil, "invalid-purpose" end
	local setup = purpose == "setup"
	if record.review_required == true or (setup and record.backend ~= "native-agent") then return nil, "review" end
	if not setup and record.enabled == false then return nil, "skip" end
	if not identity(record.id, 256) or not identity(scope, 2048) or not identity(observer_id, 256) then
		return nil, "invalid-attempt-identity"
	end
	local mode = MODES[record.backend]
	if mode == nil or (record.backend == "native-agent" and string.lower(record.provider) ~= "omp") then return nil, "review" end
	if record.duplicate_policy ~= "allow" and record.duplicate_policy ~= "skip" then return nil, "review" end
	if not setup and record.duplicate_policy == "skip" then
		for _, attempt in state.attempts do
			if attempt.purpose ~= "setup" and attempt.record_id == record.id and attempt.scope == scope and blocking(attempt) then return nil, "skip" end
		end
	end
	if #state.attempts >= MAX_ATTEMPTS or state.next_attempt >= MAX_INTEGER or state.revision >= MAX_INTEGER then
		return nil, "capacity"
	end
	local attempt: Attempt = {
		id = "attempt-" .. string.format("%.0f", state.next_attempt),
		record_id = record.id,
		scope = scope,
		observer_id = observer_id,
		sequence = 0,
		mode = mode,
		phase = "Starting",
		unresolved = true,
		purpose = if setup then "setup" elseif purpose == "managed" then "managed" else nil,
	}
	table.insert(state.attempts, attempt)
	state.next_attempt += 1
	state.revision += 1
	return attempt, nil
end

-- Accepted transitions:
-- Starting -> any phase (including a missed start followed immediately by exit).
-- Running/Waiting -> each other, Unknown, Exited, Failed; never back to Starting.
-- Unresolved Unknown -> any phase after the owning observer revalidates membership.
-- Resolved Unknown -> terminal evidence only; stale activity cannot resurrect it.
-- Exited -> Failed permits late failure correction. Failed cannot become success.
-- Terminal -> Unknown on close/loss consumes sequence but retains terminal evidence.
-- Same-phase observations may bind/enrich metadata without changing liveness.
-- All errors (missing-attempt, scope/pane fences, invalid evidence,
-- illegal-transition, capacity) leave both attempt and state counters unchanged.
-- The host executor is the only observer; each accepted observation advances sequence.
function M.observe(state: State, attempt_id: string, observation: Observation): (boolean, string?)
	local attempt = find(state, attempt_id)
	if attempt == nil then return false, "missing-attempt" end
	local sequence = attempt.sequence + 1
	if type(observation) ~= "table" or not fields(observation, OBSERVATION_FIELDS) then return false, "invalid-observation" end
	if observation.scope ~= nil and observation.scope ~= attempt.scope then return false, "scope-mismatch" end
	if type(observation.phase) ~= "string" or PHASES[observation.phase] ~= true then return false, "invalid-phase" end
	local err = evidence_error(observation)
	if err then return false, err end
	if observation.pane ~= nil and attempt.pane ~= nil and observation.pane ~= attempt.pane then return false, "pane-mismatch" end
	local pane = observation.pane or attempt.pane
	local phase = observation.phase
	if phase == "Exited" and observation.exit_status ~= nil and observation.exit_status ~= 0 then phase = "Failed" end
	if (phase == "Running" or phase == "Waiting for input") and pane == nil then return false, "unbound-live-attempt" end
	if terminal(attempt.phase) then
		if phase == "Unknown" then
			-- Disappearance cannot erase proven completion or its diagnostics.
			if state.revision >= MAX_INTEGER then return false, "capacity" end
			attempt.sequence = sequence
			state.revision += 1
			return true, nil
		end
		if not terminal(phase) or (attempt.phase == "Failed" and phase ~= "Failed") then return false, "illegal-transition" end
	elseif attempt.phase == "Unknown" and not attempt.unresolved then
		if phase ~= "Unknown" and not terminal(phase) then return false, "resolved-attempt" end
	elseif phase == "Starting" and attempt.phase ~= "Starting" and attempt.phase ~= "Unknown" then
		return false, "illegal-transition"
	end
	local unresolved = not terminal(phase) and not (attempt.phase == "Unknown" and not attempt.unresolved)
	if pane ~= nil and unresolved then
		for _, other in state.attempts do
			if other.id ~= attempt.id and blocking(other) and other.scope == attempt.scope and other.observer_id == attempt.observer_id and other.pane == pane then
				return false, "pane-already-bound"
			end
		end
	end
	if state.revision >= MAX_INTEGER then return false, "capacity" end
	local previous_phase = attempt.phase
	attempt.pane = pane
	attempt.phase = phase
	attempt.unresolved = unresolved
	attempt.sequence = sequence
	if observation.exit_status ~= nil then attempt.exit_status = observation.exit_status end
	if observation.error_category ~= nil then
		attempt.error_category = observation.error_category
	elseif phase == "Failed" then
		if observation.exit_status ~= nil and observation.exit_status ~= 0 then
			attempt.error_category = "command-exit"
		elseif previous_phase ~= "Failed" or attempt.error_category == nil then
			attempt.error_category = "unknown"
		end
	elseif phase == "Exited" or phase == "Running" or phase == "Waiting for input" then
		attempt.error_category = nil
	end
	-- First terminal evidence supersedes liveness/connectivity diagnostics; repeated
	-- terminal observations retain their existing diagnostic unless replaced.
	if observation.diagnostic ~= nil then
		attempt.diagnostic = observation.diagnostic
	elseif (terminal(phase) and previous_phase ~= phase) or phase == "Running" or phase == "Waiting for input" then
		attempt.diagnostic = nil
	end
	state.revision += 1
	return true, nil
end

-- Explicit user inspection only. This never closes a pane and never invents exit 0.
-- Idempotent on already released history; terminal diagnostics remain untouched.
function M.resolve(state: State, attempt_id: string): (boolean, string?)
	local attempt = find(state, attempt_id)
	if attempt == nil then return false, "missing-attempt" end
	if not blocking(attempt) then return true, nil end
	if state.revision >= MAX_INTEGER then return false, "capacity" end
	attempt.phase = "Unknown"
	attempt.unresolved = false
	state.revision += 1
	return true, nil
end

-- Only the authority can establish that a managed Exited attempt is no longer
-- needed by an unsettled bridge reference. Missing evidence keeps it protected.
local function removable(attempt: Attempt, settled: {[string]: boolean}?): boolean
	return not blocking(attempt) and (attempt.purpose ~= "managed"
		or attempt.phase == "Exited" and settled ~= nil and settled[attempt.id] == true)
end
function M.clear_history(state: State, settled: {[string]: boolean}?): (number?, string?)
	local removed = 0
	for _, attempt in state.attempts do
		if removable(attempt, settled) then removed += 1 end
	end
	if removed == 0 then return 0, nil end
	if state.revision >= MAX_INTEGER then return nil, "capacity" end
	local destination = 1
	local old_length = #state.attempts
	for source = 1, old_length do
		local attempt = state.attempts[source]
		if not removable(attempt, settled) then
			state.attempts[destination] = attempt
			destination += 1
		end
	end
	for index = old_length, destination, -1 do table.remove(state.attempts, index) end
	state.revision += 1
	return removed, nil
end

-- Keeps the newest `keep` attempts that clear_history would remove (by admission
-- order) and removes older ones. Blocking attempts never count and never go.
function M.trim_history(state: State, keep: number, settled: {[string]: boolean}?): (number?, string?)
	local excess = -keep
	for _, attempt in state.attempts do
		if removable(attempt, settled) then excess += 1 end
	end
	if excess <= 0 then return 0, nil end
	if state.revision >= MAX_INTEGER then return nil, "capacity" end
	local removed, destination = excess, 1
	local old_length = #state.attempts
	for source = 1, old_length do
		local attempt = state.attempts[source]
		if removable(attempt, settled) and excess > 0 then
			excess -= 1
		else
			state.attempts[destination] = attempt
			destination += 1
		end
	end
	for index = old_length, destination, -1 do table.remove(state.attempts, index) end
	state.revision += 1
	return removed, nil
end

-- IDs are looked up on every render, so late results replace earlier batch counts.
-- Optional caller outcomes are {outcome="Skipped"|"Blocked", reason=string}; these
-- are request outcomes, not persisted phases. Repeated IDs count once. Missing IDs
-- (for example explicitly cleared history) count as missing, never as success.
-- nil selects all retained attempts. total includes outcomes and missing IDs;
-- unresolved is a subset of phase counts. No "spawned" or authenticated inference.
function M.aggregate(state: State, attempt_ids: { any }?): { [string]: number }
	local counts: { [string]: number } = {
		Starting = 0, Running = 0, ["Waiting for input"] = 0,
		Exited = 0, Failed = 0, Unknown = 0,
		Skipped = 0, Blocked = 0, total = 0, unresolved = 0, missing = 0,
	}
	if attempt_ids == nil then
		for _, attempt in state.attempts do
			counts[attempt.phase] += 1
			counts.total += 1
			if attempt.unresolved then counts.unresolved += 1 end
		end
		return counts
	end
	local seen: { [string]: boolean } = {}
	for _, entry in attempt_ids do
		if type(entry) == "string" then
			if not seen[entry] then
				seen[entry] = true
				counts.total += 1
				local attempt = find(state, entry)
				if attempt then
					counts[attempt.phase] += 1
					if attempt.unresolved then counts.unresolved += 1 end
				else
					counts.missing += 1
				end
			end
		else
			assert(type(entry) == "table" and (entry.outcome == "Skipped" or entry.outcome == "Blocked"), "aggregate expects attempt IDs or validated request outcomes")
			counts[entry.outcome] += 1
			counts.total += 1
		end
	end
	return counts
end

local EXECUTION_FIELDS = {
	id = true, attempt_id = true, record_id = true, purpose = true,
	config_revision = true, observer_id = true, session_key = true, native_session = true,
	token = true, ticket = true, stage = true, provider = true, account_label = true,
	backend = true, placement = true, cwd = true, pane_reused = true,
	setup_run_id = true, initial_prompt = true, native_pane = true, native_window = true,
	native_tab = true, shell_program = true,
}
local EXECUTION_STAGES = {
	admitted = true, claimed = true, submission_intent = true, submitted = true,
	running = true, completed = true, failed = true, unknown = true, resolved = true,
}
local function bounded_text(value: any, maximum: number): boolean
	return type(value) == "string" and #value > 0 and #value <= maximum and not value:find("%z")
end

-- The wire carries only immutable display/placement data and an exact inert
-- ticket. No command renderer or private approved-record copy crosses this seam.
function M.validate_execution_projection(value: any): (any?, string?)
	if type(value) ~= "table" or not fields(value, EXECUTION_FIELDS) then return nil, "invalid-execution-job" end
	local digits = if type(value.id) == "string" then value.id:match("^attempt%-([1-9]%d*)$") else nil
	local number = if digits then tonumber(digits) else nil
	if not number or not integer(number, 1) or string.format("%.0f", number) ~= digits or value.attempt_id ~= value.id then
		return nil, "invalid-execution-identity"
	end
	if not identity(value.record_id, 96) or not identity(value.observer_id, 256)
		or not identity(value.session_key, 2048) or not integer(value.native_session, 0)
		or not integer(value.config_revision, 0) or not identity(value.token, 384)
		or value.ticket ~= "exit 125 # SPAWN:" .. value.token then
		return nil, "invalid-execution-identity"
	end
	if EXECUTION_STAGES[value.stage] ~= true or type(value.pane_reused) ~= "boolean" then
		return nil, "invalid-execution-stage"
	end
	if not bounded_text(value.provider, 256) or not value.provider:find("%S")
		or not bounded_text(value.account_label, 32000) or not bounded_text(value.cwd, 32000)
		or MODES[value.backend] == nil then
		return nil, "invalid-execution-display"
	end
	if value.backend == "native-agent" and string.lower(value.provider) ~= "omp" then return nil, "invalid-native-provider" end
	if value.placement ~= "tab" and value.placement ~= "split" and value.placement ~= "replace_if_alone" then
		return nil, "invalid-execution-placement"
	end
	if value.purpose == "setup" then
		if value.backend ~= "native-agent" or value.placement ~= "tab"
			or not identity(value.setup_run_id, 256) or not bounded_text(value.initial_prompt, 32000) then
			return nil, "invalid-setup-execution"
		end
	elseif value.purpose ~= "launch" or value.setup_run_id ~= nil or value.initial_prompt ~= nil then
		return nil, "invalid-execution-purpose"
	end
	if value.native_pane ~= nil then
		if not integer(value.native_pane, 0) or type(value.native_window) ~= "string"
			or #value.native_window > 256 or value.native_window:find("%c")
			or not bounded_text(value.shell_program, 8192) then return nil, "invalid-native-binding" end
	elseif value.native_window ~= nil or value.shell_program ~= nil or value.native_tab ~= nil then
		return nil, "incomplete-native-binding"
	end
	if value.native_tab ~= nil and not integer(value.native_tab, 0) then return nil, "invalid-native-tab" end
	return value, nil
end

return M
