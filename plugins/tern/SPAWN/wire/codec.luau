-- Vendored from shared/report-files-v1 by sync.py; edit there, then run sync.py.
--!strict

-- Pure report-files-v1 codecs. Parsing/reassembly is not durable acceptance or an ACK.
-- SPAWN owns files; the workflow reducer owns sequence cursors and committed receipts.
local M = {}
local MAX_INTEGER = 9007199254740991
-- `array_parse` bounds any JSON array the parser admits (CHECKOUT changed_files reaches 512);
-- `array_entries` stays the default bound for a schema array that names no explicit maximum.
local LIMITS = table.freeze({ wire = 8192, chunk = 4096, control = 2048, bridge = 8192, bridge_status = 16384,
	logical = 65536, slice = 2048, chunks = 32, depth = 12, values = 2048,
	array_entries = 256, array_parse = 512, object_fields = 64, payload_string = 32768,
	assemblies = 4, reassembly_bytes = 262144, manifest = 4096 })
M.LIMITS = LIMITS
M.OPEN_CONVERSATION_ASSIGNMENT = "Open an orchestrated conversation. Preserve this conversation's existing task and context, if any. Enrol using the supplied instructions, then wait for the user's task. Do not create, edit or delete files merely to open this conversation."
-- Local migration projection only, never report/reply/bridge allowance. Closed maximal
-- SessionIdentity has 13 parser values; WorkerIdentity has 41 (all optional fields,
-- nested origin/pane and seven capabilities). Root/schema/two arrays add four.
-- 16 KiB/session and 32 KiB/worker conservatively cover every bounded string/key
-- even when each character is JSON-unicode-escaped; 256 bytes cover the root.
local MIGRATION_LIMITS = table.freeze({ sessions = 64, workers = 256,
	managed_bytes = 64 * 16384 + 256 * 32768 + 256, managed_values = 64 * 13 + 256 * 41 + 4 })
M.MIGRATION_LIMITS = MIGRATION_LIMITS

local function failure(code: string, message: string): any
	return { ok = false, code = code, message = message }
end

local function integer(value: any, minimum: number, maximum: number?): boolean
	return type(value) == "number" and value == value and value >= minimum
		and value <= (maximum or MAX_INTEGER) and value % 1 == 0
end

local function id(value: any): boolean
	return type(value) == "string" and #value >= 1 and #value <= 96 and value:match("^[A-Za-z0-9_-]+$") ~= nil
end

local function token(value: any): boolean
	return type(value) == "string" and #value >= 16 and #value <= 128 and value:match("^[A-Za-z0-9_-]+$") ~= nil
end

local function digest(value: any): boolean
	return type(value) == "string" and #value == 64 and value:match("^[0-9a-f]+$") ~= nil
end

local function text(value: any, maximum: number): boolean
	return type(value) == "string" and #value > 0 and #value <= maximum
end

local function clone(value: any): any
	if type(value) ~= "table" then return value end
	local result = {}
	for key, child in value do result[key] = clone(child) end
	return result
end

local function equal(left: any, right: any): boolean
	if type(left) ~= type(right) then return false end
	if type(left) ~= "table" then return left == right end
	for key, value in left do if not equal(value, right[key]) then return false end end
	for key in right do if left[key] == nil then return false end end
	return true
end

-- Parse JSON here instead of letting native null-dropping/key-overwriting erase evidence.
-- Shapes distinguish {} from [], including empty containers, without leaking metatables.
local function strict_decode(bytes: any, maximum: number?, managed_projection: boolean?): (any?, any?, any?)
	local ceiling = if managed_projection then MIGRATION_LIMITS.managed_bytes else LIMITS.logical
	local limit = maximum or ceiling
	if not integer(limit, 1, ceiling) then return nil, failure("invalid_schema", "Invalid decoding bound."), nil end
	if type(bytes) ~= "string" or #bytes == 0 then return nil, failure("invalid_schema", "Expected complete JSON bytes."), nil end
	if #bytes > limit then return nil, failure("oversize", "Encoded JSON exceeds its transport limit."), nil end
	local valid_utf8, length = pcall(utf8.len, bytes)
	if not valid_utf8 or length == nil or bytes:sub(1, 3) == "\239\187\191" then
		return nil, failure("invalid_schema", "JSON must be UTF-8 without a BOM."), nil
	end
	local cursor, values = 1, 0
	local shapes: any = {}
	local function bad(): never return error("invalid JSON", 0) end
	local function space()
		while true do
			local byte = bytes:byte(cursor)
			if byte ~= 32 and byte ~= 9 and byte ~= 10 and byte ~= 13 then return end
			cursor += 1
		end
	end
	local function string_value(): string
		if bytes:byte(cursor) ~= 34 then bad() end
		local first = cursor
		cursor += 1
		while cursor <= #bytes do
			local byte = bytes:byte(cursor)
			if byte == 34 then
				cursor += 1
				local decoded = tern.json.decode(bytes:sub(first, cursor - 1))
				if type(decoded) ~= "string" or #decoded > LIMITS.payload_string or utf8.len(decoded) == nil then bad() end
				return decoded
			elseif byte < 32 then bad()
			elseif byte == 92 then
				local escape = bytes:sub(cursor + 1, cursor + 1)
				if escape == "u" then
					local hex = bytes:sub(cursor + 2, cursor + 5)
					if #hex ~= 4 or hex:match("^[0-9a-fA-F]+$") == nil then bad() end
					local code = tonumber(hex, 16)
					cursor += 6
					if code >= 0xD800 and code <= 0xDBFF then
						local low = bytes:sub(cursor + 2, cursor + 5)
						if bytes:sub(cursor, cursor + 1) ~= "\\u" or #low ~= 4 or low:match("^[0-9a-fA-F]+$") == nil then bad() end
						local low_code = tonumber(low, 16)
						if low_code < 0xDC00 or low_code > 0xDFFF then bad() end
						cursor += 6
					elseif code >= 0xDC00 and code <= 0xDFFF then bad() end
				elseif escape == '"' or escape == "\\" or escape == "/" or escape == "b" or escape == "f" or escape == "n" or escape == "r" or escape == "t" then
					cursor += 2
				else bad() end
			else cursor += 1 end
		end
		bad()
		return ""
	end
	local function digit(): boolean
		local byte = bytes:byte(cursor)
		return byte ~= nil and byte >= 48 and byte <= 57
	end
	local parse: any
	parse = function(depth: number): any
		if depth > LIMITS.depth then bad() end
		values += 1
		if values > (if managed_projection then MIGRATION_LIMITS.managed_values else LIMITS.values) then bad() end
		space()
		local byte = bytes:byte(cursor)
		if byte == 34 then return string_value() end
		if byte == 123 or byte == 91 then
			local object = byte == 123
			local result: { [string]: unknown } | { unknown } = if object then {} else tern.json.array()
			shapes[result] = if object then "object" else "array"
			local closer = if object then 125 else 93
			cursor += 1
			space()
			if bytes:byte(cursor) == closer then cursor += 1 return result end
			local entries = 0
			while true do
				entries += 1
				if entries > (if object then LIMITS.object_fields else LIMITS.array_parse) then bad() end
				if object then
					local members = result :: { [string]: unknown }
					local key = string_value()
					if #key > 64 or members[key] ~= nil then bad() end
					space()
					if bytes:byte(cursor) ~= 58 then bad() end
					cursor += 1
					members[key] = parse(depth + 1)
				else table.insert(result :: { unknown }, parse(depth + 1)) end
				space()
				if bytes:byte(cursor) == closer then cursor += 1 return result end
				if bytes:byte(cursor) ~= 44 then bad() end
				cursor += 1
				space()
			end
		elseif bytes:sub(cursor, cursor + 3) == "true" then cursor += 4 return true
		elseif bytes:sub(cursor, cursor + 4) == "false" then cursor += 5 return false
		elseif byte == 45 or digit() then
			local first = cursor
			if byte == 45 then cursor += 1 end
			if not digit() then bad() end
			if bytes:byte(cursor) == 48 then cursor += 1 else repeat cursor += 1 until not digit() end
			if bytes:byte(cursor) == 46 then
				cursor += 1
				if not digit() then bad() end
				repeat cursor += 1 until not digit()
			end
			local exponent = bytes:byte(cursor)
			if exponent == 69 or exponent == 101 then
				cursor += 1
				if bytes:byte(cursor) == 43 or bytes:byte(cursor) == 45 then cursor += 1 end
				if not digit() then bad() end
				repeat cursor += 1 until not digit()
			end
			local number = tonumber(bytes:sub(first, cursor - 1))
			if number == nil or number ~= number or number == math.huge or number == -math.huge then bad() end
			return number
		end
		-- In particular, null is forbidden even for optional members.
		return bad()
	end
	local ok, result = pcall(function()
		local value = parse(1)
		space()
		if cursor <= #bytes then bad() end
		return value
	end)
	if not ok then return nil, failure("invalid_schema", "Malformed, duplicate-key, null-bearing or over-complex JSON."), nil end
	return result, nil, shapes
end
function M.strict_decode(bytes: any, maximum: number?): (any?, any?, any?)
	return strict_decode(bytes, maximum, false)
end

local K = {
	0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5, 0x3956c25b, 0x59f111f1, 0x923f82a4, 0xab1c5ed5,
	0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3, 0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174,
	0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc, 0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
	0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7, 0xc6e00bf3, 0xd5a79147, 0x06ca6351, 0x14292967,
	0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13, 0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85,
	0xa2bfe8a1, 0xa81a664b, 0xc24b8b70, 0xc76c51a3, 0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
	0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5, 0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f, 0x682e6ff3,
	0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208, 0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2,
}
local band, bxor, bnot, rshift, rotate = bit32.band, bit32.bxor, bit32.bnot, bit32.rshift, bit32.rrotate
local MOD = 4294967296
local function word_bytes(word: number): string
	return string.char(band(rshift(word, 24), 255), band(rshift(word, 16), 255), band(rshift(word, 8), 255), band(word, 255))
end

-- One 64-byte block of `s` at `first` into the state words `h`, using the schedule scratch `w`.
local function compress(h: { number }, w: { number }, s: string, first: number)
	for index = 1, 16 do
		local a, b, c, d = s:byte(first + (index - 1) * 4, first + (index - 1) * 4 + 3)
		w[index] = a * 16777216 + b * 65536 + c * 256 + d
	end
	for index = 17, 64 do
		local x, y = w[index - 15], w[index - 2]
		w[index] = (w[index - 16] + bxor(rotate(x, 7), rotate(x, 18), rshift(x, 3)) + w[index - 7]
			+ bxor(rotate(y, 17), rotate(y, 19), rshift(y, 10))) % MOD
	end
	local a, b, c, d, e, f, g, hh = h[1], h[2], h[3], h[4], h[5], h[6], h[7], h[8]
	for index = 1, 64 do
		local t1 = (hh + bxor(rotate(e, 6), rotate(e, 11), rotate(e, 25)) + bxor(band(e, f), band(bnot(e), g)) + K[index] + w[index]) % MOD
		local t2 = (bxor(rotate(a, 2), rotate(a, 13), rotate(a, 22)) + bxor(band(a, b), band(a, c), band(b, c))) % MOD
		hh, g, f, e, d, c, b, a = g, f, e, (d + t1) % MOD, c, b, a, (t1 + t2) % MOD
	end
	h[1], h[2], h[3], h[4] = (h[1] + a) % MOD, (h[2] + b) % MOD, (h[3] + c) % MOD, (h[4] + d) % MOD
	h[5], h[6], h[7], h[8] = (h[5] + e) % MOD, (h[6] + f) % MOD, (h[7] + g) % MOD, (h[8] + hh) % MOD
end
local function initial(): { number }
	return { 0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a, 0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19 }
end
-- Pad the final partial block (fewer than 64 bytes) of a `length`-byte message and hex the digest.
local function final(h: { number }, w: { number }, tail: string, length: number): string
	local bits = length * 8
	local padded = tail .. "\128" .. string.rep("\0", (55 - #tail) % 64) .. word_bytes(math.floor(bits / MOD)) .. word_bytes(bits % MOD)
	for first = 1, #padded, 64 do compress(h, w, padded, first) end
	return string.format("%08x%08x%08x%08x%08x%08x%08x%08x", h[1], h[2], h[3], h[4], h[5], h[6], h[7], h[8])
end

function M.sha256(bytes: string): string
	local h, w = initial(), table.create(64, 0)
	local whole = #bytes - #bytes % 64
	for first = 1, whole, 64 do compress(h, w, bytes, first) end
	return final(h, w, bytes:sub(whole + 1), #bytes)
end

-- Resumable SHA-256 for inputs too large to hash inside one window callback. `sha256_feed`
-- only queues bytes; `sha256_step` compresses at most `max_blocks` 64-byte blocks and returns
-- true once every queued full block is hashed; `sha256_digest` then pads the tail. A step that
-- is interrupted (budget trip) leaves `busy` set, and every later call refuses that state.
function M.sha256_begin(): any
	return { h = initial(), w = table.create(64, 0), queue = {}, head = 1, tail = 0, current = "", pos = 1, length = 0, busy = false, finished = false }
end
function M.sha256_feed(state: any, bytes: string)
	assert(not state.busy and not state.finished, "sha256 state was interrupted or already finished")
	if #bytes == 0 then return end
	-- Explicit tail index: consumed slots are nil, so `#queue`/table.insert would reuse slot 1.
	state.tail += 1; state.queue[state.tail] = bytes; state.length += #bytes
end
function M.sha256_step(state: any, max_blocks: number): boolean
	assert(not state.busy and not state.finished, "sha256 state was interrupted or already finished")
	state.busy = true
	local h, w, queue = state.h, state.w, state.queue
	local current, pos, head, blocks = state.current, state.pos, state.head, 0
	while true do
		if #current - pos + 1 >= 64 then
			if blocks >= max_blocks then break end
			compress(h, w, current, pos); pos += 64; blocks += 1
		else
			local nextpart = queue[head]
			if nextpart == nil then break end
			queue[head] = nil; head += 1
			current = current:sub(pos) .. nextpart; pos = 1
		end
	end
	state.current, state.pos, state.head = current, pos, head
	local drained = queue[head] == nil and #current - pos + 1 < 64
	state.busy = false
	return drained
end
function M.sha256_digest(state: any): string
	assert(not state.busy and not state.finished, "sha256 state was interrupted or already finished")
	assert(state.queue[state.head] == nil and #state.current - state.pos + 1 < 64, "sha256 input not fully stepped")
	state.finished = true -- One-shot: the state words are consumed by the padding.
	return final(state.h, state.w, state.current:sub(state.pos), state.length)
end

local function object(raw: any, required: any, optional: any, shapes: any): boolean
	if type(raw) ~= "table" or shapes[raw] ~= "object" then return false end
	for key in raw do if not required[key] and not optional[key] then return false end end
	for key, validate in required do if not validate(raw[key]) then return false end end
	for key, validate in optional do if raw[key] ~= nil and not validate(raw[key]) then return false end end
	return true
end
local function positive(value: any): boolean return integer(value, 1) end
local function short(value: any): boolean return text(value, 1024) end
local function long(value: any): boolean return text(value, LIMITS.payload_string) end
local function any_table(value: any): boolean return type(value) == "table" end
local function enum(...: string): (any) -> boolean
	local choices = {}
	for _, value in { ... } do choices[value] = true end
	return function(value: any): boolean return type(value) == "string" and choices[value] == true end
end
local B: { [string]: (unknown) -> boolean } = { logical_session_id = id, worker_id = id, worker_generation = positive, launch_request_id = id, work_id = id }
local function schema(extra: any, enrolment: boolean?): any
	local result = table.clone(B)
	if enrolment then result.enrolment_token = token end
	for key, value in extra do result[key] = value end
	return result
end
local function array(raw: any, validate: any, shapes: any, minimum: number?, maximum: number?): boolean
	if type(raw) ~= "table" or shapes[raw] ~= "array" or #raw < (minimum or 0) or #raw > (maximum or LIMITS.array_entries) then return false end
	for _, value in raw do if not validate(value) then return false end end
	return true
end
local function binding_matches(raw: any, expected: any, enrolment: boolean): boolean
	if type(expected) ~= "table" then return false end
	for key, validate in B do if not validate(expected[key]) or raw[key] ~= expected[key] then return false end end
	return not enrolment or (token(expected.enrolment_token) and raw.enrolment_token == expected.enrolment_token)
end
local REPORT_KINDS = enum("REGISTER", "READY", "ACCEPTED", "HEARTBEAT", "WAITING", "BLOCKED", "ASK", "CHECKPOINT", "REVIEW_READY", "REVIEW_RESULT", "DONE", "ROLLOVER_REQUEST", "LANDING_REQUEST", "LANDING_RESULT", "reply_ack", "COORDINATOR_RELEASE", "COORDINATOR_PROPOSAL",
	"CHECK_RESULT", "CHECKOUT", "LABEL", "DEPLOY_RESULT", "PROJECT_START_CLAIM")
local CAPABILITIES = enum("report-files-v1", "native-ask-v1", "worker-poll-v1", "argv-v1", "coordinator-control-v1", "check-runner-v1", "release-manager-v1", "project-start-v1")
-- Missing provisioned capability is unsupported_capability in both packaged consumers.
-- Identity mismatches remain binding_mismatch; neither classification grants authority.
local REQUIRES = { COORDINATOR_RELEASE = "coordinator-control-v1", COORDINATOR_PROPOSAL = "coordinator-control-v1",
	CHECK_RESULT = "check-runner-v1", CHECKOUT = "check-runner-v1", DEPLOY_RESULT = "release-manager-v1",
	coordinator_activation = "coordinator-control-v1", coordinator_retirement = "coordinator-control-v1",
	landing_grant = "release-manager-v1", deploy_grant = "release-manager-v1", record_ruling = "coordinator-control-v1",
	project_start = "project-start-v1", PROJECT_START_CLAIM = "project-start-v1" }
local function authorized(kind: string, expected: any): boolean
	local capability = REQUIRES[kind]
	if kind == "project_start" or kind == "PROJECT_START_CLAIM" then
		return type(expected.capabilities) == "table" and table.find(expected.capabilities, "project-start-v1") ~= nil
			and table.find(expected.capabilities, "coordinator-control-v1") ~= nil
	end
	return capability == nil or (type(expected.capabilities) == "table" and table.find(expected.capabilities, capability) ~= nil)
end
-- Git object names (SHA-1 or SHA-256 repositories), class/family names and exit codes shared by both directions.
local function revision(v: any): boolean return type(v) == "string" and (#v == 40 or #v == 64) and v:match("^[0-9a-f]+$") ~= nil end
local function class_name(v: any): boolean return type(v) == "string" and #v <= 32 and v:match("^[a-z][a-z0-9-]*$") ~= nil end
local function family(v: any): boolean return type(v) == "string" and #v <= 24 and v:match("^[a-z][a-z0-9-]*$") ~= nil end
local function exit_code(v: any): boolean return integer(v, -2147483648, 4294967295) end
local function absolute(v: any): boolean
	return text(v, 4096) and v:find("%z") == nil and (v:sub(1, 1) == "/" or v:match("^%a:[/\\]") ~= nil or v:sub(1, 2) == "\\\\")
end
local function relative(v: any): boolean
	if not text(v, 256) or v:find("[%z\\]") ~= nil or v:sub(1, 1) == "/" or v:match("^%a:") ~= nil then return false end
	for segment in (v .. "/"):gmatch("([^/]*)/") do if segment == ".." then return false end end
	return true
end
local function unique(list: any, key: string?): boolean
	local seen = {}
	for _, entry in list do
		local value = if key then entry[key] else entry
		if seen[value] then return false end
		seen[value] = true
	end
	return true
end
local function findings(v: any, shapes: any): boolean
	local finding = function(f: any): boolean return object(f, { finding_id = id, path = short, summary = function(s: any): boolean return text(s, 400) end },
		{ line = positive }, shapes) end
	return array(v, finding, shapes, 0, 32) and unique(v, "finding_id")
end
-- Runtime context occupancy, not billed input/output totals. Baseline is optional on the
-- wire: percentage overrides need only current/window; calculated mode also needs first turn.
function M.valid_context_snapshot(v: any): boolean
	if type(v) ~= "table" then return false end
	for key in v do if key ~= "current_tokens" and key ~= "window_tokens" and key ~= "first_turn_tokens" and key ~= "observed_at_ms" then return false end end
	return integer(v.window_tokens, 1) and integer(v.current_tokens, 0, v.window_tokens) and integer(v.observed_at_ms, 0)
		and (v.first_turn_tokens == nil or integer(v.first_turn_tokens, 0, v.window_tokens))
end

local function report_payload(report: any, shapes: any): boolean
	local p, kind = report.payload, report.kind
	local references = function(v: any): boolean return array(v, short, shapes) end
	local context = function(v: any): boolean return integer(v, 0, 100) end
	local snapshot = function(v: any): boolean return type(v) == "table" and shapes[v] == "object" and M.valid_context_snapshot(v) end
	local function measured(): boolean return p.context_used_pct == nil or p.context_snapshot == nil end
	local texts = function(v: any): boolean return array(v, long, shapes) end
	if kind == "REGISTER" then
		if not object(p, { capabilities = function(v: any): boolean return array(v, CAPABILITIES, shapes, 1, 8) end }, {}, shapes) then return false end
		local seen = {}
		for _, capability in p.capabilities do if seen[capability] then return false end seen[capability] = true end
		return seen["report-files-v1"] == true
	elseif kind == "READY" then return object(p, { state = enum("idle") }, { summary = short, context_used_pct = context, context_snapshot = snapshot }, shapes) and measured()
	elseif kind == "ACCEPTED" then return object(p, { assignment_sha256 = digest }, {}, shapes)
	elseif kind == "HEARTBEAT" then return object(p, { state = enum("working", "idle", "waiting", "blocked") }, { summary = short, request_id = id, context_used_pct = context, context_snapshot = snapshot }, shapes) and measured()
	elseif kind == "WAITING" then return object(p, { reason = short }, { request_id = id }, shapes)
	elseif kind == "BLOCKED" then return object(p, { reason = long }, { evidence = references }, shapes)
	elseif kind == "ASK" then
		local option = function(v: any): boolean return object(v, { id = id, label = short }, {}, shapes) end
		if not object(p, { question = long, options = function(v: any): boolean return array(v, option, shapes, 1, 16) end }, { evidence = references }, shapes) then return false end
		local seen = {}
		for _, entry in p.options do if seen[entry.id] then return false end seen[entry.id] = true end
		return true
	elseif kind == "CHECKPOINT" then
		local check = function(v: any): boolean return object(v, { check_id = id, artifact_revision = short,
			outcome = enum("passed", "failed", "not_run"), evidence_ref = short }, {}, shapes) end
		return object(p, { checkpoint_id = id, task_ref = short, project_id = id, worktree_ref = short, artifact_revision = short,
			completed = texts, remaining = texts, holds = texts, checks = function(v: any): boolean return array(v, check, shapes) end },
			{ plan_ref = short, plan_revision = short, request_id = id, context_used_pct = context, context_snapshot = snapshot }, shapes)
			and ((p.plan_ref == nil) == (p.plan_revision == nil)) and measured()
	elseif kind == "REVIEW_READY" then return object(p, { checkpoint_id = id, artifact_revision = short }, { summary = short }, shapes)
	elseif kind == "REVIEW_RESULT" then
		return object(p, { review_id = id, round = positive, artifact_revision = short, outcome = enum("approved", "changes_required"),
			findings = function(v: any): boolean return findings(v, shapes) end }, { summary = short }, shapes)
	elseif kind == "DONE" then return object(p, { checkpoint_id = id, artifact_revision = short, summary = long }, { output_ref = relative }, shapes)
	elseif kind == "CHECK_RESULT" then
		return object(p, { check_id = id, argv_sha256 = digest, exit_code = exit_code, output_sha256 = digest, head = revision,
			ran_at_ms = function(v: any): boolean return integer(v, 0) end }, {}, shapes)
	elseif kind == "CHECKOUT" then
		local path = function(v: any): boolean return text(v, 4096) and v:find("%z") == nil end
		if not object(p, { worktree_path = absolute, common_dir = absolute, branch = function(v: any): boolean return text(v, 256) end, head = revision,
			changed_files = function(v: any): boolean return array(v, path, shapes, 0, 512) and unique(v) end,
			changed_overflow = function(v: any): boolean return type(v) == "boolean" end, changed_total = function(v: any): boolean return integer(v, 0) end,
			dirty = function(v: any): boolean return type(v) == "boolean" end }, { base = revision }, shapes) then return false end
		-- A sorted prefix may be shorter than 512 when the full list would exceed the logical report bound.
		return p.changed_total >= #p.changed_files and p.changed_overflow == (p.changed_total > #p.changed_files)
	elseif kind == "LABEL" then return object(p, { work_ref = short, class = class_name }, { reason = short }, shapes)
	elseif kind == "DEPLOY_RESULT" then
		return object(p, { deploy_id = id, attempt_id = id, landing_id = id, outcome = enum("deployed", "held", "not_applicable", "failed"),
			revision = short, evidence = function(v: any): boolean return array(v, short, shapes, 0, 16) end }, { reason = short }, shapes)
	elseif kind == "ROLLOVER_REQUEST" then return object(p, { checkpoint_id = id, reason = short }, {}, shapes)
	elseif kind == "LANDING_REQUEST" then
		-- Exact artifact (source ref + revision, pinned by a retained checkpoint) onto an exact target
		-- (repository, ref and expected head revision). A request is data, never a grant.
		return object(p, { checkpoint_id = id, project_id = id, repo_ref = short, target_ref = short, target_revision = short,
			source_ref = short, source_revision = short }, { summary = short }, shapes)
	elseif kind == "LANDING_RESULT" then
		-- Echoes the exact landing_grant; landed names the resulting head, stale_target the observed
		-- moved head, rejected/uncertain a reason. Nothing here is native proof of a merge.
		if not object(p, { landing_id = id, grant_id = id, project_id = id, repo_ref = short, target_ref = short, target_revision = short,
			source_revision = short, outcome = enum("landed", "rejected", "stale_target", "uncertain"), evidence = references },
			{ result_revision = short, observed_target_revision = short, reason = short, pr_ref = short, summary = short }, shapes) then return false end
		return (p.outcome == "landed") == (p.result_revision ~= nil) and (p.outcome == "stale_target") == (p.observed_target_revision ~= nil)
			and (p.outcome ~= "stale_target" or p.observed_target_revision ~= p.target_revision)
			and (if p.outcome == "landed" then p.reason == nil elseif p.outcome == "stale_target" then true else p.reason ~= nil)
	elseif kind == "COORDINATOR_PROPOSAL" then
		if p.kind == "new_work" or p.kind == "add_source" then
			local nonblank = function(v: any, maximum: number): boolean
				return text(v, maximum) and v:find("%z") == nil and v:find("%S") ~= nil
			end
			local required: any = { owner_id = id, owner_generation = positive, activation_token = digest,
				proposal_id = id, kind = enum("new_work", "add_source") }
			local optional: any = { orch_project_id = id,
				new_project_name = function(v: any): boolean return nonblank(v, 160) end }
			if p.kind == "new_work" then
				local bounded_text = function(maximum: number): (any) -> boolean
					return function(v: any): boolean return text(v, maximum) and v:find("%z") == nil end
				end
				local check = function(v: any): boolean
					return object(v, { check_id = id,
						argv = function(a: any): boolean return array(a, bounded_text(512), shapes, 1, 16) end }, {}, shapes)
				end
				required.record_id, required.record_revision = short, function(v: any): boolean return integer(v, 0) end
				required.prompt = function(v: any): boolean return nonblank(v, LIMITS.payload_string) end
				required.scope = function(v: any): boolean
					return object(v, {
						paths = function(a: any): boolean return array(a, bounded_text(256), shapes, 0, 64) end,
						systems = function(a: any): boolean return array(a, bounded_text(80), shapes, 0, 16) end }, {}, shapes)
				end
				required.checks = function(v: any): boolean return array(v, check, shapes, 0, 16) and unique(v, "check_id") end
				optional.base_ref, optional.repository_id = bounded_text(256), id
				optional.target_ref, optional.target_revision = bounded_text(256), revision
			else
				local source_revision = function(v: any): boolean return nonblank(v, 1024) end
				required.source = function(v: any): boolean
					if type(v) ~= "table" then return false end
					if v.kind == "plan_file" or v.kind == "board" then
						return object(v, { kind = enum("plan_file", "board"), path = absolute, revision = source_revision }, {}, shapes)
					end
					return object(v, { kind = enum("template"), template_id = id, revision = source_revision,
						input = function(value: any): boolean return nonblank(value, LIMITS.payload_string) end }, {
						custom_fields = function(fields: any): boolean
							if type(fields) ~= "table" or shapes[fields] ~= "object" then return false end
							local count = 0
							for name, value in fields do
								count += 1
								if count > 16 or type(name) ~= "string" or #name > 32 or name == "input"
									or name:match("^[a-z][a-z0-9-]*$") == nil or type(value) ~= "string"
									or #value > 2048 or value:find("%z") ~= nil then return false end
							end
							return true
						end,
					}, shapes)
				end
			end
			if not object(p, required, optional, shapes) or ((p.orch_project_id == nil) == (p.new_project_name == nil)) then return false end
			return p.kind ~= "new_work" or ((p.target_ref == nil) == (p.target_revision == nil)
				and (p.target_ref == nil or p.repository_id ~= nil))
		end
		if not object(p, { owner_id = id, owner_generation = positive, activation_token = digest, proposal_id = id,
			kind = enum("dispatch", "report", "review", "rollover", "landing"), work_id = id, project_id = id },
			{ checkpoint_id = id, record_id = short, record_revision = function(v: any): boolean return integer(v, 0) end, prompt = long }, shapes) then return false end
		if p.kind == "dispatch" then return p.checkpoint_id == nil and p.record_id ~= nil and p.record_revision ~= nil and p.prompt ~= nil end
		return p.record_id == nil and p.record_revision == nil and p.prompt == nil and ((p.kind == "report") == (p.checkpoint_id == nil))
	elseif kind == "PROJECT_START_CLAIM" then
		return object(p, { owner_id = id, owner_generation = positive, activation_token = digest,
			orch_project_id = id, project_revision = positive, decision_context = digest }, {}, shapes)
	elseif kind == "COORDINATOR_RELEASE" then
		return object(p, { owner_id = id, owner_generation = positive, activation_token = digest,
			quiescent = function(v: any): boolean return v == true end }, {}, shapes)
	elseif kind == "reply_ack" then return object(p, { message_id = id, reply_seq = positive, reply_sha256 = digest, status = enum("recorded") }, {}, shapes) end
	return false
end

function M.decode_report(bytes: any, expected: any): (any?, any?)
	local raw, diagnostic, shapes = M.strict_decode(bytes)
	if diagnostic ~= nil then return nil, diagnostic end
	local required = schema({ version = function(v: any): boolean return v == 3 end, event_id = id, seq = positive, kind = REPORT_KINDS, payload = any_table }, true)
	if not object(raw, required, { action_id = id, action_revision = positive, handover_id = id, handover_token = token }, shapes)
		or not report_payload(raw, shapes) then return nil, failure("invalid_schema", "Invalid closed report schema.") end
	local action_required = raw.kind == "REVIEW_RESULT" or raw.kind == "LANDING_RESULT" or raw.kind == "reply_ack" or raw.kind == "COORDINATOR_RELEASE"
		or raw.kind == "LABEL" or raw.kind == "DEPLOY_RESULT" or raw.kind == "PROJECT_START_CLAIM"
	local action_optional = raw.kind == "CHECKPOINT" or raw.kind == "DONE" or raw.kind == "WAITING" or raw.kind == "BLOCKED"
	if (raw.action_id == nil) ~= (raw.action_revision == nil) or (action_required and raw.action_id == nil)
		or (not action_required and not action_optional and raw.action_id ~= nil) then return nil, failure("invalid_schema", "Invalid action correlation fields.") end
	if (raw.handover_id == nil) ~= (raw.handover_token == nil) or (raw.kind ~= "ACCEPTED" and raw.handover_id ~= nil) then
		return nil, failure("invalid_schema", "Invalid handover correlation fields.")
	end
	if raw.kind == "reply_ack" and #bytes > LIMITS.control then return nil, failure("oversize", "Reserved reply acknowledgement exceeds its control limit.") end
	if not binding_matches(raw, expected, true) or not id(expected.mailbox_handle) then return nil, failure("binding_mismatch", "Report differs from the provisioned enrolment.") end
	if not authorized(raw.kind, expected) then
		return nil, failure("unsupported_capability", raw.kind .. " requires its explicitly provisioned capability " .. REQUIRES[raw.kind] .. ".")
	end
	if raw.event_id ~= M.sha256(expected.mailbox_handle .. ":report:" .. string.format("%.0f", raw.seq)) then return nil, failure("binding_mismatch", "Report event ID does not match its mailbox sequence.") end
	if raw.kind == "ACCEPTED" and (raw.handover_id ~= expected.handover_id or raw.handover_token ~= expected.handover_token
		or (expected.assignment_sha256 ~= nil and raw.payload.assignment_sha256 ~= expected.assignment_sha256)) then
		return nil, failure("binding_mismatch", "Acceptance differs from the issued assignment or handover.")
	end
	if raw.kind == "REGISTER" and expected.capabilities ~= nil then
		for _, capability in raw.payload.capabilities do
			if table.find(expected.capabilities, capability) == nil then return nil, failure("binding_mismatch", "A report cannot grant an unprovisioned capability.") end
		end
	end
	return raw, nil
end

-- Authenticated assignment manifest (Contract G).
function M.decode_manifest(bytes: any): (any?, any?)
	if type(bytes) == "string" and #bytes > LIMITS.manifest then return nil, failure("manifest_too_large", "Assignment manifest exceeds 4096 bytes.") end
	local raw, diagnostic, shapes = M.strict_decode(bytes, LIMITS.manifest)
	if diagnostic ~= nil then return nil, diagnostic end
	local bounded = function(n: number): (any) -> boolean return function(v: any): boolean return text(v, n) and v:find("%z") == nil end end
	local check = function(v: any): boolean return object(v, { check_id = id, argv = function(a: any): boolean return array(a, bounded(512), shapes, 1, 16) end }, {}, shapes) end
	local scope = function(v: any): boolean return object(v, { paths = function(a: any): boolean return array(a, bounded(256), shapes, 0, 64) end,
		systems = function(a: any): boolean return array(a, bounded(80), shapes, 0, 16) end }, {}, shapes) end
	if not object(raw, { checks = function(v: any): boolean return array(v, check, shapes, 0, 16) and unique(v, "check_id") end,
		files = function(v: any): boolean return array(v, bounded(256), shapes, 0, 64) end, scope = scope }, { base_ref = bounded(256) }, shapes) then
		return nil, failure("invalid_schema", "Invalid closed assignment manifest.")
	end
	return raw, nil
end

-- Canonical manifest bytes (sorted keys, arrays always arrays) for {checks, files, scope, base_ref?}.
-- SPAWN writes these exact bytes as manifest.json and binds their sha256; ORCH+ never runs argv.
function M.encode_manifest(m: any): (string?, any?)
	local function strings(list: any): string
		local parts = {}
		for index, value in list or {} do parts[index] = tern.json.encode(value) end
		return "[" .. table.concat(parts, ",") .. "]"
	end
	local checks = {}
	for index, check in m.checks or {} do
		checks[index] = '{"argv":' .. strings(check.argv) .. ',"check_id":' .. tern.json.encode(check.check_id) .. "}"
	end
	local scope = m.scope or {}
	local bytes = "{" .. (if m.base_ref ~= nil then '"base_ref":' .. tern.json.encode(m.base_ref) .. "," else "")
		.. '"checks":[' .. table.concat(checks, ",") .. '],"files":' .. strings(m.files)
		.. ',"scope":{"paths":' .. strings(scope.paths) .. ',"systems":' .. strings(scope.systems) .. "}}"
	local _, problem = M.decode_manifest(bytes)
	if problem then return nil, problem end
	return bytes, nil
end

function M.decode_reply(bytes: any, expected: any): (any?, any?)
	local raw, diagnostic, shapes = M.strict_decode(bytes)
	if diagnostic ~= nil then return nil, diagnostic end
	if not object(raw, schema({ version = function(v: any): boolean return v == 1 end, message_id = id, reply_seq = positive,
		action_id = id, action_revision = positive, kind = enum("assignment", "report_request", "owner_decision", "landing_grant", "landing_refresh", "coordinator_activation", "coordinator_retirement",
			"review_request", "rework", "deploy_grant", "label_request", "record_ruling", "project_start"), payload = any_table }),
		{ gate_id = id, gate_revision = positive }, shapes) then return nil, failure("invalid_schema", "Invalid reply envelope.") end
	local p, valid = raw.payload, false
	if raw.kind == "assignment" then valid = object(p, { assignment_ref = short, assignment_sha256 = digest, instructions = long }, {}, shapes)
	elseif raw.kind == "report_request" then valid = object(p, { request_id = id, requested_kind = enum("HEARTBEAT", "CHECKPOINT"), reason = short }, {}, shapes)
	elseif raw.kind == "owner_decision" then valid = object(p, { choice_id = id, answer = long }, {}, shapes)
	elseif raw.kind == "project_start" then valid = object(p, { owner_id = id, owner_generation = positive, activation_token = digest,
		orch_project_id = id, project_revision = positive, decision_context = digest }, {}, shapes)
	elseif raw.kind == "coordinator_activation" then valid = object(p, { owner_id = id, owner_generation = positive, activation_token = digest, instructions = long }, {}, shapes)
	elseif raw.kind == "coordinator_retirement" then valid = object(p, { owner_id = id, owner_generation = positive, activation_token = digest, reason = short }, {}, shapes)
	elseif raw.kind == "record_ruling" then
		local function marker(v: any): boolean
			return type(v) == "string" and #v <= 256 and v:match("^orchplus%-ruling:[A-Za-z0-9_-]+:[A-Za-z0-9_-]+$") ~= nil
		end
		local function entry(v: any): boolean
			if not text(v, 8192) or v:find("[%z\r]") or v:sub(-1) == "\n" then return false end
			for line in (v .. "\n"):gmatch("(.-)\n") do
				if line:sub(1, 2) ~= "> " or line:find("[<>`]", 3) then return false end
			end
			return true
		end
		valid = object(p, { path = absolute, marker = marker, entry = entry,
			expected_document_sha256 = digest, expected_non_rulings_sha256 = digest }, {}, shapes)
			and p.marker:match(":([^:]+)$") == raw.gate_id
	elseif raw.kind == "landing_grant" then
		valid = object(p, { landing_id = id, grant_id = id, project_id = id, checkpoint_id = id, repo_ref = short,
			target_ref = short, target_revision = short, source_ref = short, source_revision = short, builder_work_id = id,
			proof = function(v: any): boolean return object(v, { mode = enum("cross_family_review", "helper_checks", "review_disabled"), artifact_revision = short,
				check_refs = function(r: any): boolean return array(r, short, shapes, 0, 16) end }, { review_id = id }, shapes) end },
			{ review_id = id, reviewer_family = family }, shapes)
			and (if p.proof.mode == "review_disabled" then p.review_id == nil and p.reviewer_family == nil and p.proof.review_id == nil
				else p.review_id ~= nil and p.reviewer_family ~= nil and p.proof.review_id == p.review_id)
	elseif raw.kind == "landing_refresh" then valid = object(p, { landing_id = id, project_id = id, repo_ref = short, target_ref = short,
		expected_revision = short, current_revision = short, reason = short }, {}, shapes)
	elseif raw.kind == "review_request" then
		valid = object(p, { review_id = id, round = positive, question_id = enum("implements_task_v1"), builder_work_id = id, task_ref = short,
			source_ref = short, artifact_revision = short, scope_paths = function(v: any): boolean return array(v, function(s: any): boolean return text(s, 256) end, shapes, 0, 64) end,
			findings_prev = function(v: any): boolean return findings(v, shapes) end }, { plan_ref = short, plan_revision = short }, shapes)
			and ((p.plan_ref == nil) == (p.plan_revision == nil))
	elseif raw.kind == "rework" then
		local failed = function(v: any): boolean return object(v, { check_id = id, exit_code = exit_code }, {}, shapes) end
		valid = object(p, { round = positive, artifact_revision = short, failed_checks = function(v: any): boolean return array(v, failed, shapes, 0, 16) end,
			findings = function(v: any): boolean return findings(v, shapes) end }, { review_id = id }, shapes)
	elseif raw.kind == "deploy_grant" then valid = object(p, { deploy_id = id, attempt_id = id, landing_id = id, revision = short, target_ref = short }, {}, shapes)
	elseif raw.kind == "label_request" then
		valid = object(p, { work_ref = short, classes = function(v: any): boolean return array(v, class_name, shapes, 1, 32) and unique(v) end, text = long }, {}, shapes) end
	local gated = raw.kind == "owner_decision" or raw.kind == "record_ruling"
	if not valid or (gated and (raw.gate_id == nil or raw.gate_revision == nil))
		or (not gated and (raw.gate_id ~= nil or raw.gate_revision ~= nil)) then return nil, failure("invalid_schema", "Invalid closed reply payload or gate fields.") end
	if raw.kind == "report_request" and #bytes > LIMITS.control then return nil, failure("oversize", "Report-request reply exceeds its control limit.") end
	if not binding_matches(raw, expected, false) then return nil, failure("binding_mismatch", "Reply differs from its recipient binding.") end
	if not authorized(raw.kind, expected) then
		return nil, failure("unsupported_capability", raw.kind .. " requires its explicitly provisioned capability " .. REQUIRES[raw.kind] .. ".")
	end
	return raw, nil
end

local function control(bytes: any, watermark: boolean): (any?, any?)
	local raw, diagnostic, shapes = M.strict_decode(bytes, LIMITS.control)
	if diagnostic ~= nil then return nil, diagnostic end
	local extra = if watermark then { version = function(v: any): boolean return v == 1 end, type = enum("receipt_watermark"),
		mailbox_handle = id, through_seq = positive, receipt_chain_sha256 = digest }
		else { version = function(v: any): boolean return v == 1 end, event_id = id, seq = positive, event_sha256 = digest,
			committed_revision = positive, disposition = enum("accepted"), receipt_chain_sha256 = digest }
	if not object(raw, schema(extra, watermark), {}, shapes) then return nil, failure("invalid_schema", "Invalid receipt control schema.") end
	return raw, nil
end

function M.decode_ack(bytes: any, expected: any): (any?, any?)
	local raw, diagnostic = control(bytes, false)
	if diagnostic ~= nil then return nil, diagnostic end
	local acknowledgement = raw :: { [string]: unknown }
	if not binding_matches(raw, expected, false) then return nil, failure("binding_mismatch", "ACK differs from its report binding.") end
	for _, key in { "event_id", "seq", "event_sha256" } do
		if expected[key] == nil or acknowledgement[key] ~= expected[key] then return nil, failure("binding_mismatch", "ACK does not match the retained exact report bytes.") end
	end
	for _, key in { "committed_revision", "receipt_chain_sha256" } do
		if expected[key] ~= nil and acknowledgement[key] ~= expected[key] then return nil, failure("binding_mismatch", "ACK differs from the recorded receipt.") end
	end
	return raw, nil
end

function M.decode_watermark(bytes: any, expected: any): (any?, any?)
	local raw, diagnostic = control(bytes, true)
	if diagnostic ~= nil then return nil, diagnostic end
	if not binding_matches(raw, expected, true) or raw.mailbox_handle ~= expected.mailbox_handle then return nil, failure("binding_mismatch", "Watermark differs from its enrolled generation.") end
	return raw, nil
end

function M.receipt_chain(mailbox_handle: any, previous: any?, receipt: any?): (string?, any?)
	if not id(mailbox_handle) then return nil, failure("invalid_schema", "Invalid mailbox handle.") end
	if previous == nil and receipt == nil then return M.sha256("report-files-v1\n" .. mailbox_handle .. "\n"), nil end
	if not digest(previous) or type(receipt) ~= "table" or not positive(receipt.seq) or not id(receipt.event_id)
		or not digest(receipt.event_sha256) or not positive(receipt.committed_revision) then return nil, failure("invalid_schema", "Invalid receipt chain tuple.") end
	local raw = (previous :: string):gsub("..", function(pair: string): string return string.char(tonumber(pair, 16) :: number) end)
	return M.sha256(raw .. string.format("%.0f", receipt.seq) .. "\n" .. receipt.event_id .. "\n" .. receipt.event_sha256
		.. "\n" .. string.format("%.0f", receipt.committed_revision) .. "\n"), nil
end

local function base64(encoded: any, maximum: number): string?
	if type(encoded) ~= "string" or #encoded == 0 or #encoded > maximum or #encoded % 4 ~= 0
		or encoded:match("^[A-Za-z0-9+/]*=?=?$") == nil then return nil end
	local ok, decoded = pcall(tern.base64.decode, encoded)
	if not ok or tern.base64.encode(decoded) ~= encoded then return nil end
	return decoded
end

function M.decode_object(bytes: any): (any?, any?)
	local raw, diagnostic, shapes = M.strict_decode(bytes, LIMITS.wire)
	if diagnostic ~= nil then return nil, diagnostic end
	if type(raw) ~= "table" then return nil, failure("invalid_schema", "Expected a mailbox object.") end
	if raw.type == "receipt_watermark" then return control(bytes, true) end
	if raw.type == nil then return control(bytes, false) end
	local required: any = { transport = enum("report-files-v1"), version = function(v: any): boolean return v == 1 end,
		type = enum("chunk", "manifest"), mailbox_handle = id, direction = enum("report", "reply"), slot = positive,
		message_id = id, message_sha256 = digest, count = function(v: any): boolean return integer(v, 1, LIMITS.chunks) end }
	if raw.type == "manifest" then
		required.message_bytes = function(v: any): boolean return integer(v, 1, LIMITS.logical) end
		if #bytes > LIMITS.control then return nil, failure("oversize", "Manifest exceeds its control limit.") end
		if not object(raw, required, {}, shapes) or raw.count ~= math.ceil(raw.message_bytes / LIMITS.slice) then return nil, failure("invalid_schema", "Manifest count does not exactly cover its logical bytes.") end
	elseif raw.type == "chunk" then
		required.index = function(v: any): boolean return integer(v, 1, LIMITS.chunks) end
		required.data_b64 = function(v: any): boolean return type(v) == "string" end
		if #bytes > LIMITS.chunk then return nil, failure("oversize", "Chunk exceeds its wire limit.") end
		if not object(raw, required, {}, shapes) or raw.index > raw.count then return nil, failure("invalid_schema", "Invalid chunk identity or index.") end
		local decoded = base64(raw.data_b64, 2732)
		if decoded == nil or #decoded < 1 or #decoded > LIMITS.slice or (raw.index < raw.count and #decoded ~= LIMITS.slice) then
			return nil, failure("invalid_schema", "Chunk has noncanonical Base64 or the wrong raw slice length.")
		end
	else return nil, failure("invalid_schema", "Unknown mailbox object type.") end
	return raw, nil
end

function M.frame(bytes: any, direction: any, expected: any): (any?, any?)
	if direction ~= "report" and direction ~= "reply" then return nil, failure("invalid_schema", "Invalid framing direction.") end
	if type(expected) ~= "table" or not id(expected.mailbox_handle) then return nil, failure("binding_mismatch", "Framing requires a provisioned mailbox handle.") end
	local logical, diagnostic
	if direction == "report" then logical, diagnostic = M.decode_report(bytes, expected) else logical, diagnostic = M.decode_reply(bytes, expected) end
	if diagnostic ~= nil then return nil, diagnostic end
	local common = { transport = "report-files-v1", version = 1, mailbox_handle = expected.mailbox_handle, direction = direction,
		slot = if direction == "report" then logical.seq else logical.reply_seq,
		message_id = if direction == "report" then logical.event_id else logical.message_id,
		message_sha256 = M.sha256(bytes), count = math.ceil(#bytes / LIMITS.slice) }
	local chunks = tern.json.array()
	for index = 1, common.count do
		local chunk = table.clone(common)
		chunk.type, chunk.index = "chunk", index
		chunk.data_b64 = tern.base64.encode(bytes:sub((index - 1) * LIMITS.slice + 1, index * LIMITS.slice))
		local encoded = tern.json.encode(chunk)
		if #encoded > LIMITS.chunk then return nil, failure("oversize", "Encoded chunk does not fit its transport bound.") end
		table.insert(chunks, encoded)
	end
	local manifest = table.clone(common)
	manifest.type, manifest.message_bytes = "manifest", #bytes
	local encoded = tern.json.encode(manifest)
	if #encoded > LIMITS.control then return nil, failure("oversize", "Encoded manifest does not fit its transport bound.") end
	return { manifest = encoded, chunks = chunks, message_sha256 = common.message_sha256, message_bytes = #bytes }, nil
end

function M.new_reassembler(): any
	return { assemblies = {}, active = 0, bytes = 0 }
end

local function verified_object(bytes: any, object_sha256: any): (any?, any?)
	if not digest(object_sha256) or type(bytes) ~= "string" or #bytes > LIMITS.wire then return nil, failure("invalid_schema", "A bounded object and exact wire digest are required.") end
	if M.sha256(bytes) ~= object_sha256 then return nil, failure("content_conflict", "Wire object digest differs from its complete original bytes.") end
	return M.decode_object(bytes)
end

-- Shared completion gate for persisted sequential reads and in-memory publication validation.
-- Only digest-proven bytes are returned on a semantic rejection; they are not an intake or ACK.
local function complete_message(manifest: any, logical_bytes: string, expected: any): (any?, any?)
	if #logical_bytes ~= manifest.message_bytes or M.sha256(logical_bytes) ~= manifest.message_sha256 then
		return nil, failure("content_conflict", "Whole-message original-byte digest differs from the manifest.")
	end
	local logical, err
	if manifest.direction == "report" then logical, err = M.decode_report(logical_bytes, expected)
	else logical, err = M.decode_reply(logical_bytes, expected) end
	if err == nil then
		local slot = if manifest.direction == "report" then logical.seq else logical.reply_seq
		local message_id = if manifest.direction == "report" then logical.event_id else logical.message_id
		if slot ~= manifest.slot or message_id ~= manifest.message_id then
			err = failure("binding_mismatch", "Logical envelope differs from its framing identity.")
		end
	end
	if err ~= nil then
		err.completed_bytes = logical_bytes; err.completed_sha256 = manifest.message_sha256
		return nil, err
	end
	return { ok = true, complete = true, envelope = logical, bytes = logical_bytes,
		sha256 = manifest.message_sha256, direction = manifest.direction }, nil
end

local function manifest_binding(manifest: any, expected: any): any?
	if manifest.type ~= "manifest" then return failure("invalid_schema", "Begin reassembly with a complete manifest.") end
	if type(expected) ~= "table" or manifest.mailbox_handle ~= expected.mailbox_handle then
		return failure("binding_mismatch", "Manifest is for another mailbox.")
	end
	for key, validate in B do
		if not validate(expected[key]) then return failure("binding_mismatch", "Missing provisioned message binding.") end
	end
	if manifest.direction == "report" and not token(expected.enrolment_token) then
		return failure("binding_mismatch", "Missing provisioned report token.")
	end
	return nil
end

local function chunk_slice(chunk: any, manifest: any): (string?, any?)
	for _, key in { "mailbox_handle", "direction", "slot", "message_id", "message_sha256", "count" } do
		if chunk[key] ~= manifest[key] then return nil, failure("content_conflict", "Chunk identity differs from its immutable manifest.") end
	end
	local decoded = base64(chunk.data_b64, 2732)
	local length = if chunk.index < manifest.count then LIMITS.slice else manifest.message_bytes - (manifest.count - 1) * LIMITS.slice
	if decoded == nil or #decoded ~= length then return nil, failure("incomplete", "Chunk length does not match the manifest.") end
	return decoded, nil
end

-- The owner persists this state with its active read, and caps simultaneous states at
-- LIMITS.assemblies and total logical bytes at LIMITS.reassembly_bytes. Base64 slices,
-- never raw partial UTF-8, cross the JSON persistence boundary. No cursor/ACK is owned here.
function M.assembly_start(bytes: any, object_sha256: any, expected: any): (any?, any?)
	local manifest, diagnostic = verified_object(bytes, object_sha256)
	if diagnostic ~= nil then return nil, diagnostic end
	local mismatch = manifest_binding(manifest, expected)
	if mismatch then return nil, mismatch end
	local encoded, binding_bytes = pcall(tern.json.encode, expected)
	if not encoded then return nil, failure("invalid_schema", "Assembly binding must be JSON serializable.") end
	local binding, problem = M.strict_decode(binding_bytes, LIMITS.control)
	if problem then return nil, problem end
	return { version = 1, manifest = manifest, manifest_bytes = bytes, manifest_sha256 = object_sha256,
		binding = binding, next_index = 1, slices = tern.json.array(), object_digests = tern.json.array(), bytes = 0 }, nil
end

-- Validate/hash only the arriving object. Previously accepted slices are decoded once,
-- at completion, and the whole original message is hashed once before semantic intake.
-- Pending success mutates state; failures and completion leave the persisted prefix alone.
function M.assembly_push(state: any, bytes: any, object_sha256: any, expected: any): (any?, any?)
	if type(state) ~= "table" or state.version ~= 1 or type(state.manifest) ~= "table"
		or not integer(state.next_index, 1, LIMITS.chunks) or not integer(state.bytes, 0, LIMITS.logical)
		or type(state.slices) ~= "table" or type(state.object_digests) ~= "table"
		or #state.slices ~= state.next_index - 1 or #state.object_digests ~= state.next_index - 1 then
		return nil, failure("invalid_schema", "Invalid persisted assembly prefix.")
	end
	if not equal(state.binding, expected) then return nil, failure("binding_mismatch", "Provisioned generation changed during reassembly.") end
	local manifest = state.manifest
	if not integer(manifest.count, 1, LIMITS.chunks) or not integer(manifest.message_bytes, 1, LIMITS.logical)
		or manifest.count ~= math.ceil(manifest.message_bytes / LIMITS.slice) or state.next_index > manifest.count
		or state.bytes ~= (state.next_index - 1) * LIMITS.slice then
		return nil, failure("invalid_schema", "Persisted assembly exceeds its manifest bounds.")
	end
	local chunk, diagnostic = verified_object(bytes, object_sha256)
	if diagnostic ~= nil then return nil, diagnostic end
	if chunk.type ~= "chunk" then return nil, failure("invalid_schema", "Expected a complete chunk object.") end
	local decoded, problem = chunk_slice(chunk, manifest)
	if decoded == nil then return nil, problem end
	if chunk.index < state.next_index then
		if state.slices[chunk.index] ~= chunk.data_b64 or state.object_digests[chunk.index] ~= object_sha256 then
			return nil, failure("content_conflict", "A repeated chunk changed its exact wire bytes.")
		end
		return { ok = true, complete = false, code = "already_received" }, nil
	end
	if chunk.index ~= state.next_index then return nil, failure("incomplete", "Chunk skips the next persisted slice.") end
	if chunk.index == manifest.count then
		local pieces = table.create(manifest.count)
		for index = 1, state.next_index - 1 do
			local piece = base64(state.slices[index], 2732)
			if piece == nil or #piece ~= LIMITS.slice then return nil, failure("invalid_schema", "Invalid persisted Base64 slice.") end
			pieces[index] = piece
		end
		pieces[chunk.index] = decoded
		return complete_message(manifest, table.concat(pieces), expected)
	end
	state.slices[chunk.index] = chunk.data_b64
	state.object_digests[chunk.index] = object_sha256
	state.bytes += #decoded
	state.next_index += 1
	return { ok = true, complete = false, code = "incomplete" }, nil
end

function M.begin_assembly(pool: any, bytes: any, expected: any, object_sha256: any): (any?, any?)
	local manifest, diagnostic = verified_object(bytes, object_sha256)
	if diagnostic ~= nil then return nil, diagnostic end
	local mismatch = manifest_binding(manifest, expected)
	if mismatch then return nil, mismatch end
	local prior = pool.assemblies[manifest.mailbox_handle]
	if prior ~= nil then
		if prior.manifest_bytes == bytes and equal(prior.binding, expected) then return { ok = true, code = "already_started" }, nil end
		return nil, failure("content_conflict", "One different message already occupies this generation's reassembly slot.")
	end
	if pool.active >= LIMITS.assemblies then return nil, failure("full", "Host reassembly slots are full; retain source bytes.") end
	pool.assemblies[manifest.mailbox_handle] = { manifest = manifest, manifest_bytes = bytes, binding = clone(expected), chunks = {}, object_digests = {}, received = 0, bytes = 0 }
	pool.active += 1
	return { ok = true, code = "started" }, nil
end

function M.discard_assembly(pool: any, mailbox_handle: any): boolean
	local assembly = pool.assemblies[mailbox_handle]
	if assembly == nil then return false end
	pool.bytes -= assembly.bytes
	pool.active -= 1
	pool.assemblies[mailbox_handle] = nil
	return true
end

function M.push_chunk(pool: any, bytes: any, expected: any, object_sha256: any): (any?, any?)
	local chunk, diagnostic = verified_object(bytes, object_sha256)
	if diagnostic ~= nil then return nil, diagnostic end
	if chunk.type ~= "chunk" then return nil, failure("invalid_schema", "Expected a complete chunk object.") end
	local assembly = pool.assemblies[chunk.mailbox_handle]
	if assembly == nil then return nil, failure("incomplete", "No validated manifest is pending for this mailbox.") end
	if not equal(assembly.binding, expected) then return nil, failure("binding_mismatch", "Provisioned generation changed during reassembly.") end
	local manifest = assembly.manifest
	local decoded, problem = chunk_slice(chunk, manifest)
	if decoded == nil then return nil, problem end
	local prior = assembly.chunks[chunk.index]
	if prior ~= nil then
		if prior ~= decoded or assembly.object_digests[chunk.index] ~= object_sha256 then return nil, failure("content_conflict", "A repeated chunk changed its exact wire bytes.") end
		return { ok = true, complete = false, code = "already_received" }, nil
	end
	if pool.bytes + #decoded > LIMITS.reassembly_bytes then return nil, failure("full", "Host raw reassembly byte budget is full.") end
	if assembly.received + 1 == manifest.count then
		-- Validate completion before changing the partial assembly, including the final
		-- chunk. Rejected bytes never become a partially accepted logical report.
		local pieces = table.clone(assembly.chunks)
		pieces[chunk.index] = decoded
		local logical_bytes = table.concat(pieces, "", 1, manifest.count)
		local completed, problem = complete_message(manifest, logical_bytes, expected)
		if problem ~= nil then return nil, problem end
		M.discard_assembly(pool, chunk.mailbox_handle)
		return completed, nil
	end
	assembly.chunks[chunk.index] = decoded
	assembly.object_digests[chunk.index] = object_sha256
	assembly.received += 1
	assembly.bytes += #decoded
	pool.bytes += #decoded
	return { ok = true, complete = false, code = "incomplete" }, nil
end

local function selector(raw: any, shapes: any): boolean
	if type(raw) ~= "table" then return false end
	if raw.stream == "report" or raw.stream == "reply" then
		return object(raw, { stream = enum("report", "reply"), slot = positive, part = enum("manifest", "chunk") },
			{ index = function(v: any): boolean return integer(v, 1, LIMITS.chunks) end }, shapes)
			and ((raw.part == "chunk") == (raw.index ~= nil))
	elseif raw.stream == "ack" then return object(raw, { stream = enum("ack"), slot = positive }, {}, shapes)
	elseif raw.stream == "watermark" then return object(raw, { stream = enum("watermark") }, { through_seq = positive }, shapes) end
	return false
end
local function selector_matches(value: any, selected: any): boolean
	if selected.stream == "report" or selected.stream == "reply" then
		return value.direction == selected.stream and value.slot == selected.slot and value.type == selected.part and value.index == selected.index
	elseif selected.stream == "ack" then return value.type == nil and value.seq == selected.slot
	else return value.type == "receipt_watermark" and (selected.through_seq == nil or value.through_seq == selected.through_seq) end
end
local function continuation(selected: any, following: any): boolean
	if selected.stream ~= "report" and selected.stream ~= "reply" then return false end
	if following.stream ~= selected.stream or following.slot ~= selected.slot or following.part ~= "chunk" then return false end
	return following.index == (if selected.part == "manifest" then 1 else selected.index + 1)
end

-- These are mailbox_read payloads; SPAWN's outer operation/action correlation is a
-- separate bridge contract. Never infer a successful read from a clipped surface.
function M.decode_page(bytes: any, expected_selector: any): (any?, any?)
	local raw, diagnostic, shapes = M.strict_decode(bytes, LIMITS.bridge)
	if diagnostic ~= nil then return nil, diagnostic end
	if not object(raw, { object_b64 = function(v: any): boolean return type(v) == "string" end, object_sha256 = digest,
		object_bytes = function(v: any): boolean return integer(v, 1, LIMITS.wire) end,
		selector = function(v: any): boolean return selector(v, shapes) end, complete = function(v: any): boolean return v == true end },
		{ next_selector = function(v: any): boolean return selector(v, shapes) end }, shapes) then return nil, failure("invalid_schema", "Read page must contain one complete bounded object.") end
	if not equal(raw.selector, expected_selector) then return nil, failure("binding_mismatch", "Read page differs from the requested immutable selector.") end
	if raw.next_selector ~= nil and not continuation(raw.selector, raw.next_selector) then return nil, failure("binding_mismatch", "Continuation leaves the requested message or skips a part.") end
	local object_bytes = base64(raw.object_b64, math.ceil(LIMITS.wire / 3) * 4)
	if object_bytes == nil or #object_bytes ~= raw.object_bytes then return nil, failure("incomplete", "Read page is truncated or has invalid Base64.") end
	local value, err = verified_object(object_bytes, raw.object_sha256)
	if err ~= nil then return nil, err end
	if not selector_matches(value, raw.selector) then return nil, failure("binding_mismatch", "Object does not match its selector.") end
	if raw.next_selector ~= nil and raw.next_selector.index > value.count then return nil, failure("binding_mismatch", "Continuation exceeds the manifest chunk count.") end
	return { object = value, bytes = object_bytes, sha256 = raw.object_sha256, selector = raw.selector, next_selector = raw.next_selector, complete = true }, nil
end

function M.project_page(bytes: any, selected: any, next_selector: any?): (string?, any?)
	if type(bytes) ~= "string" or #bytes > LIMITS.wire then return nil, failure("oversize", "Mailbox object exceeds its wire limit.") end
	local encoded = tern.json.encode({ object_b64 = tern.base64.encode(bytes), object_sha256 = M.sha256(bytes), object_bytes = #bytes,
		selector = selected, next_selector = next_selector, complete = true })
	if #encoded > LIMITS.bridge then return nil, failure("oversize", "Encoded bridge page exceeds its outer byte limit.") end
	local _, diagnostic = M.decode_page(encoded, selected)
	if diagnostic ~= nil then return nil, diagnostic end
	return encoded, nil
end

-- Managed dispatch v2. This is a byte/shape boundary, not admission or native authority.
-- Native membership, freshness, store validation and durable commits belong to the hosts.
M.DISPATCH = table.freeze({ schema = 2, prefix = "SPAWN_DISPATCH v2 ", node = "spawn-dispatch-response",
	role = "spawn.dispatch.response", limit = LIMITS.bridge, consumed = 32, outstanding = 32 })
local zero = function(v: any): boolean return integer(v, 0) end
local boolean = function(v: any): boolean return type(v) == "boolean" end
local yes = function(v: any): boolean return v == true end
local function bounded(n: number, empty: boolean?): (any) -> boolean
	return function(v: any): boolean
		return type(v) == "string" and #v <= n and (empty == true or #v > 0)
			and not v:find("%z") and utf8.len(v) ~= nil
	end
end
local opaque, emptyopaque, namespace = bounded(256), bounded(256, true), bounded(128)
local decimal = function(v: any): boolean return type(v) == "string" and #v <= 32 and v:match("^%d+$") ~= nil end
local record_id = function(v: any): boolean return bounded(96)(v) and v:find("%S") ~= nil and not v:find("%c") end
local function provider_family(v: any): boolean
	return record_id(v) and v == v:lower()
end
-- Native projections are ordinary tables. Wire calls ALWAYS supply strict_decode's shapes.
local function fields(v: any, required: any, optional: any, shapes: any?): boolean
	if shapes then return object(v, required, optional, shapes) end
	if type(v) ~= "table" then return false end
	for k in v do if not required[k] and not optional[k] then return false end end
	for k, check in required do if not check(v[k]) then return false end end
	for k, check in optional do if v[k] ~= nil and not check(v[k]) then return false end end
	return true
end
function M.validate_dispatch_origin(v: any, shapes: any?): boolean
	return fields(v, { logical_session_id = id, owner_id = id, owner_generation = positive,
		host_pane_id = opaque, alias_nonce = opaque, window_key = emptyopaque, window_epoch = id,
		native_session_id = opaque, window_host_id = opaque }, {}, shapes)
end
function M.validate_dispatch_setup_origin(v: any, shapes: any?): boolean
	return fields(v, { host_pane_id = opaque, window_key = emptyopaque, window_epoch = id,
		native_session_id = opaque, window_host_id = opaque }, {}, shapes)
end
function M.validate_dispatch_pane(v: any, shapes: any?): boolean
	return fields(v, { pane_id = decimal, window_epoch = id, window_key = emptyopaque,
		native_session_id = opaque, window_host_id = opaque }, {}, shapes)
end
function M.validate_dispatch_authority(v: any, expected_namespace: any?, minimum_revision: any?, shapes: any?): boolean
	return fields(v, { authority_namespace = namespace, authority_revision = zero }, {}, shapes)
		and (expected_namespace == nil or v.authority_namespace == expected_namespace)
		and (minimum_revision == nil or (zero(minimum_revision) and v.authority_revision >= minimum_revision))
end
function M.validate_spawn_claim(v: any, native: boolean?, shapes: any?): boolean
	local required: any = { spawn_namespace = namespace, claim_nonce = token }
	if native then required.executor_id = id; required.boot = id end
	return fields(v, required, {}, shapes)
end
function M.validate_dispatch_claim(v: any, shapes: any?): boolean
	return fields(v, { executor = id, grant_id = id, epoch = positive },
		{ spawn_claim = function(s: any): boolean return M.validate_spawn_claim(s, false, shapes) end }, shapes)
end
function M.validate_dispatch_control_origin(v: any, shapes: any?): boolean
	if not fields(v, { kind = enum("active", "closing"), binding = function(b: any): boolean return M.validate_dispatch_origin(b, shapes) end,
		controller_pane = decimal }, { close_id = id }, shapes) then return false end
	return (v.kind == "closing") == (v.close_id ~= nil)
end
local function recovery(v: any, shapes: any?): boolean
	return fields(v, { recovery_id = id, phase = enum("fenced", "confirmed"), generation_floor = zero }, {}, shapes)
end
function M.validate_dispatch_control(v: any, shapes: any?): boolean
	if not fields(v, { phase = enum("open", "closing"), generation_floor = zero, request_floor = positive,
		next_request_serial = positive, last_authority_revision = zero },
		{ binding = function(b: any): boolean return M.validate_dispatch_origin(b, shapes) end,
			recovery = function(r: any): boolean return recovery(r, shapes) end, close_id = id }, shapes) then return false end
	return v.request_floor <= v.next_request_serial and (v.binding == nil or v.binding.owner_generation > v.generation_floor)
		and (v.phase == "closing") == (v.close_id ~= nil)
		and (v.recovery == nil or v.recovery.generation_floor == v.generation_floor)
end
local function store_projection(v: any, legacy_orch: boolean, shapes: any?): boolean
	if not fields(v, { source_schema = positive, source_revision = zero, source_sha256 = digest,
		candidate_namespace = namespace, protocol = function(p: any): boolean return p == 1 or p == 2 end,
		state = enum("ready", "blocked", "missing"), phase = enum("stable", "prepared"),
		managed_sha256 = digest, pending_immutable = zero, blockers = zero }, { source_namespace = namespace }, shapes) then return false end
	if v.source_namespace == nil and not (legacy_orch and (v.source_schema == 2 or v.source_schema == 3) and v.protocol == 1) then return false end
	return v.protocol ~= 2 or v.source_namespace == v.candidate_namespace
end
-- Selection is compact native migration metadata, not a peer-provided identity inventory.
-- Without parser evidence, roundtrip native JSON so {} cannot masquerade as an empty [].
function M.validate_dispatch_migration_selection(v: any, shapes: any?): boolean
	if shapes == nil then
		local ok, bytes = pcall(tern.json.encode, v)
		if not ok then return false end
		local problem
		v, problem, shapes = M.strict_decode(bytes)
		if problem then return false end
	end
	local function sorted_ids(list: any, maximum: number): boolean
		if not array(list, id, shapes, 0, maximum) then return false end
		local previous = ""
		for _, value in list do if value <= previous then return false end; previous = value end
		return true
	end
	return object(v, {
		logical_session_ids = function(list: any): boolean return sorted_ids(list, MIGRATION_LIMITS.sessions) end,
		mailbox_handles = function(list: any): boolean return sorted_ids(list, MIGRATION_LIMITS.workers) end }, {}, shapes)
end
function M.validate_dispatch_migration_qualification(v: any, owner: string, shapes: any?): boolean
	if owner ~= "orch" and owner ~= "spawn" then return false end
	return fields(v, {
		proof = function(p: any): boolean return store_projection(p, owner == "orch", shapes) end,
		selection = function(s: any): boolean return M.validate_dispatch_migration_selection(s, shapes) end }, {}, shapes)
end
function M.validate_dispatch_compatibility(v: any, shapes: any?): boolean
	if type(v) ~= "table" then return false end
	if v.kind == "current" then
		return fields(v, { schema = function(s: any): boolean return s == 1 end, kind = enum("current"),
			protocol = function(p: any): boolean return p == 2 end, authority_namespace = namespace, spawn_namespace = namespace }, {}, shapes)
	end
	return fields(v, { schema = function(s: any): boolean return s == 1 end, kind = enum("migration"),
		orch = function(s: any): boolean return store_projection(s, true, shapes) end,
		spawn = function(s: any): boolean return store_projection(s, false, shapes) end }, {}, shapes)
end
local function compatibility_names(v: any): (string, string)
	if v.kind == "current" then return v.authority_namespace, v.spawn_namespace end
	return v.orch.candidate_namespace, v.spawn.candidate_namespace
end
-- This only classifies already-authenticated projections; it never validates either store.
function M.dispatch_compatibility_ready(v: any): boolean
	if not M.validate_dispatch_compatibility(v) then return false end
	-- Compact metadata carries no store-validation proof. The native owners independently
	-- establish stable/current paired stores before calling this protocol classifier.
	if v.kind == "current" then return true end
	for _, s in { v.orch, v.spawn } do
		if s.protocol ~= 2 or s.state ~= "ready" or s.phase ~= "stable" or s.pending_immutable ~= 0 or s.blockers ~= 0 then return false end
	end
	return v.orch.managed_sha256 == v.spawn.managed_sha256
end
local function serials(v: any, next_serial: any, shapes: any): boolean
	if not positive(next_serial) or not array(v, positive, shapes, 0, M.DISPATCH.consumed) then return false end
	local previous = 0
	for _, serial in v do
		if serial <= previous or serial >= next_serial then return false end
		previous = serial
	end
	return true
end
local CONTROL_OP = enum("admit_session", "reconcile_session", "close_session")
local OBSERVE_OP = enum("owner_status", "status", "mailbox_inventory", "mailbox_allocation")
local ACTION_OP = enum("catalog", "declare_provider_families", "launch", "adopt", "enrol", "accept", "stop", "native_wake", "attach_worker",
	"mailbox_provision", "mailbox_read", "mailbox_publish_ack", "mailbox_publish_reply", "mailbox_retire")
local function dispatch_op(v: any): boolean return CONTROL_OP(v) or OBSERVE_OP(v) or ACTION_OP(v) end
local function dispatch_response_limit(op: any): number
	return if op == "status" then LIMITS.bridge_status else LIMITS.bridge
end
local function cursor(v: any, shapes: any): boolean return object(v, { revision = zero, index = positive }, {}, shapes) end
local function allocation_target(v: any, shapes: any): boolean
	return object(v, { logical_session_id = id, worker_id = id, worker_generation = positive,
		launch_request_id = id, work_id = id, enrolment_sha256 = digest }, {}, shapes)
end
local function enrolment(v: any, shapes: any): boolean
	return object(v, { worker_id = id, worker_generation = positive, enrolment_token = token, assignment_sha256 = digest },
		{ handover_id = id, handover_token = token, coordinator_owner_id = id, coordinator_generation = positive }, shapes)
		and ((v.handover_id == nil) == (v.handover_token == nil))
		and ((v.coordinator_owner_id == nil) == (v.coordinator_generation == nil))
end
local function request_schema(r: any, shapes: any): (boolean, string?)
	if type(r) ~= "table" or shapes[r] ~= "object" then return false, "invalid_schema" end
	if r.schema ~= 2 then return false, "unsupported_protocol" end
	local required: any = { schema = function(v: any): boolean return v == 2 end, origin = enum("orchplus"),
		op = dispatch_op, request_id = id, action_id = id }
	local optional: any = {}
	if r.op == "catalog" and r.setup_origin ~= nil then
		required.setup_origin = function(v: any): boolean return M.validate_dispatch_setup_origin(v, shapes) end
		optional.cursor = function(v: any): boolean return cursor(v, shapes) end
		return object(r, required, optional, shapes), "invalid_schema"
	end
	required.authority_namespace, required.logical_session_id, required.admission_seq = namespace, id, positive
	if CONTROL_OP(r.op) then
		required.authority_revision = zero
		required.control_origin = function(v: any): boolean return M.validate_dispatch_control_origin(v, shapes) end
		required.compatibility = function(v: any): boolean return M.validate_dispatch_compatibility(v, shapes) end
		required.generation_floor = zero
		required.next_request_serial, required.settled_before = positive, positive
		required.consumed = function(v: any): boolean return serials(v, r.next_request_serial, shapes) end
		if r.op == "reconcile_session" then
			optional.outstanding_cursor = function(v: any): boolean
				return object(v, { after_serial = zero, through_serial = zero }, {}, shapes) and v.after_serial <= v.through_serial
			end
			required.page_limit = function(v: any): boolean return integer(v, 1, M.DISPATCH.outstanding) end
		end
		if r.op == "close_session" then required.close_id = id end
		if not object(r, required, optional, shapes) or r.settled_before > r.next_request_serial then return false, "invalid_schema" end
		local authority_namespace = compatibility_names(r.compatibility)
		if r.control_origin.binding.logical_session_id ~= r.logical_session_id or authority_namespace ~= r.authority_namespace
			or (r.compatibility.kind == "migration" and r.compatibility.orch.source_revision ~= r.authority_revision) then return false, "binding_mismatch" end
		if r.control_origin.kind == "closing" and (r.op ~= "close_session" or r.control_origin.close_id ~= r.close_id) then return false, "invalid_schema" end
		return true
	end
	required.origin_binding = function(v: any): boolean return M.validate_dispatch_origin(v, shapes) end
	required.controller_pane, required.controller_generation = decimal, positive
	if OBSERVE_OP(r.op) then
		if r.op == "status" then required.target_request_id = id; required.target_request_serial = positive end
		if r.op == "mailbox_inventory" then
			required.stale_ms = function(v: any): boolean return integer(v, 1, 315360000000) end
		end
		if r.op == "mailbox_allocation" then
			required.target = function(v: any): boolean
				return allocation_target(v, shapes) and v.logical_session_id == r.logical_session_id
			end
		end
	else
		required.request_serial, required.next_request_serial, required.settled_before = positive, positive, positive
		required.consumed = function(v: any): boolean return serials(v, r.next_request_serial, shapes) end
	end
	local pane = function(v: any): boolean return M.validate_dispatch_pane(v, shapes) end
	if r.op == "catalog" then optional.cursor = function(v: any): boolean return cursor(v, shapes) end
	elseif r.op == "declare_provider_families" then
		required.record_revision = zero
		required.declarations = function(v: any): boolean
			if not array(v, function(row: any): boolean
				return object(row, { record_id = record_id, provider_family = provider_family }, {}, shapes)
			end, shapes, 1, 32) then return false end
			local seen = {}
			for _, row in v do
				if seen[row.record_id] then return false end
				seen[row.record_id] = true
			end
			return true
		end
	elseif r.op == "launch" or r.op == "adopt" or r.op == "enrol" then
		required.record_id, required.record_revision, required.work_id = record_id, zero, id
		required.prompt = function(v: any): boolean return bounded(32768)(v) and v:find("%S") ~= nil end
		required.mailbox_handle = id
		required.enrolment = function(v: any): boolean return enrolment(v, shapes) end
		if r.op == "launch" then
			required.cwd, required.placement, required.fresh = bounded(2048), enum("tab", "split", "replace_if_alone"), yes
			optional.presentation = enum("user_new_tab", "coordinator_adjacent", "background")
			optional.execution_cwd = absolute
			-- Per-launch model/effort override. Present only when the owner chose one; a request without
			-- either is byte for byte what it was. SPAWN applies the CLI capability table to both.
			optional.model = function(v: any): boolean return bounded(200)(v) and not v:find("%c") and v:sub(1, 1) ~= "-" end
			optional.effort = function(v: any): boolean return bounded(32)(v) and v:match("^[a-z]+$") ~= nil end
		elseif r.op == "enrol" then
			required.pane_binding, required.delivery, required.preserve_context = pane, enum("native_ask", "clipboard"), yes
		else required.pane_binding = pane; required.attestation = enum("operator_verified_exact_agent_pane") end
	elseif r.op == "accept" or r.op == "stop" or r.op == "attach_worker" then
		required.target_request_id, required.target_action_id, required.pane_binding = id, id, pane
		required.worker_id, required.worker_generation, required.enrolment_token, required.work_id = id, positive, token, id
		if r.op == "accept" then
			required.event_id, required.seq, required.event_sha256 = id, positive, digest
			optional.handover_id, optional.handover_token = id, token
		elseif r.op == "attach_worker" then
			required.previous_origin_binding = function(v: any): boolean return M.validate_dispatch_origin(v, shapes) end
			required.previous_pane_binding, required.attestation = pane, enum("old_executors_stopped_or_retired", "same_native_conversation_no_pending_effects", "same_terminal_process_no_pending_effects")
		end
	elseif r.op == "native_wake" then required.target_request_id, required.target_action_id = id, id
	elseif ACTION_OP(r.op) and r.op:sub(1, 8) == "mailbox_" then
		for k, validate in B do required[k] = validate end
		required.enrolment_token = token
		if r.op == "mailbox_provision" then
			required.record_id, required.record_revision, required.capability = record_id, zero, enum("report-files-v1")
			optional.handover_id, optional.handover_sha256, optional.manifest = id, digest, long
		else
			required.handle, required.expected_generation = id, positive
			if r.op == "mailbox_read" then required.selector = function(v: any): boolean return selector(v, shapes) end
			elseif r.op == "mailbox_publish_ack" then required.receipt_revision, required.ack_b64, required.ack_sha256 = positive, bounded(2732), digest
			elseif r.op == "mailbox_publish_reply" then
				required.message_id, required.reply_seq, required.action_revision, required.reply_sha256 = id, positive, positive, digest
				required.part, required.object_b64, required.object_sha256 = enum("chunk", "manifest"), bounded(5464), digest
				optional.index = function(v: any): boolean return integer(v, 1, LIMITS.chunks) end
			elseif r.op == "mailbox_retire" then
				required.mode, required.settlement_revision, required.report_floor = enum("compact", "retire"), positive, zero
				required.report_chain_sha256, required.reply_floor, required.grant_id = digest, zero, id
				optional.withdrawn_starts = function(v: any): boolean
					if r.mode ~= "retire" or not array(v, function(entry: any): boolean
						return object(entry, { reply_seq = positive, message_id = id, message_sha256 = digest }, {}, shapes)
					end, shapes, 1, 8) then return false end
					local previous = r.reply_floor
					for _, entry in v do
						if entry.reply_seq <= previous then return false end
						previous = entry.reply_seq
					end
					return true
				end
			end
		end
	end
	if not object(r, required, optional, shapes) then return false, "invalid_schema" end
	if r.controller_generation ~= r.origin_binding.owner_generation or r.logical_session_id ~= r.origin_binding.logical_session_id then return false, "binding_mismatch" end
	if ACTION_OP(r.op) and (r.request_serial >= r.next_request_serial or r.settled_before > r.request_serial
		or table.find(r.consumed, r.request_serial) ~= nil) then return false, "invalid_schema" end
	if r.op == "accept" and ((r.handover_id == nil) ~= (r.handover_token == nil))
		or r.op == "mailbox_provision" and ((r.handover_id == nil) ~= (r.handover_sha256 == nil))
		or r.op == "mailbox_publish_reply" and ((r.part == "chunk") ~= (r.index ~= nil))
		or (r.op == "adopt" or r.op == "enrol") and (r.enrolment.handover_id ~= nil or r.enrolment.coordinator_owner_id ~= nil)
		or r.op == "enrol" and r.prompt ~= M.OPEN_CONVERSATION_ASSIGNMENT
		or r.op == "launch" and ((r.execution_cwd ~= nil and r.cwd ~= r.execution_cwd)
			or ((r.presentation == "user_new_tab" or r.presentation == "coordinator_adjacent") and r.placement ~= "tab")) then return false, "invalid_schema" end
	return true
end
function M.decode_dispatch_request(bytes: any): (any?, any?)
	local r, problem, shapes = M.strict_decode(bytes, LIMITS.bridge)
	if problem then return nil, problem end
	local valid, code = request_schema(r, shapes)
	if not valid then return nil, failure(code or "invalid_schema", "Invalid or incompatible closed dispatch request.") end
	return r, nil
end
-- Fresh curated action proof. Callers still read the current native node and establish membership;
-- neither this predicate nor a request's formerly-valid projection authorizes cached execution.
function M.validate_dispatch_projection(v: any, r: any, request_bytes: any, last_revision: any, expected_claim: any?, spawn_claim: any?): boolean
	if type(r) ~= "table" or not ACTION_OP(r.op) or r.setup_origin ~= nil or type(request_bytes) ~= "string"
		or #request_bytes > LIMITS.bridge or not zero(last_revision) then return false end
	local decoded = M.decode_dispatch_request(request_bytes)
	if decoded == nil or not equal(decoded, r) then return false end
	if not fields(v, { authority_namespace = namespace, authority_revision = zero, logical_session_id = id,
		admission_seq = positive, request_serial = positive, action_id = id, request_sha256 = digest,
		phase = enum("claimed"), reconciliation_only = function(x: any): boolean return x == false end,
		execution_origin = M.validate_dispatch_origin, execution_controller_pane = decimal, claim = M.validate_dispatch_claim }, {}, nil) then return false end
	if v.authority_namespace ~= r.authority_namespace or v.authority_revision < last_revision
		or v.logical_session_id ~= r.logical_session_id or v.admission_seq ~= r.admission_seq
		or v.request_serial ~= r.request_serial or v.action_id ~= r.action_id or v.request_sha256 ~= M.sha256(request_bytes)
		or not equal(v.execution_origin, r.origin_binding) or v.execution_controller_pane ~= r.controller_pane
		or v.claim.executor ~= r.origin_binding.window_epoch then return false end
	if expected_claim ~= nil then
		if not M.validate_dispatch_claim(expected_claim) or v.claim.executor ~= expected_claim.executor
			or v.claim.grant_id ~= expected_claim.grant_id or v.claim.epoch ~= expected_claim.epoch then return false end
		-- The peer commit adds its witness AFTER SPAWN captured the base grant. Compare that
		-- base exactly, then the witness separately; otherwise a valid first commit deadlocks begin.
		if expected_claim.spawn_claim ~= nil and not equal(v.claim.spawn_claim, expected_claim.spawn_claim) then return false end
	end
	if spawn_claim ~= nil and (not M.validate_spawn_claim(spawn_claim, true) or not equal(v.claim.spawn_claim,
		{ spawn_namespace = spawn_claim.spawn_namespace, claim_nonce = spawn_claim.claim_nonce })) then return false end
	return true
end

local CATEGORY = enum("current_admission", "admission_refused", "admission_absent", "stale_authority", "stale_revision",
	"stale_binding", "current_result", "already_consumed", "unknown_effect", "claim_mismatch", "migration_blocked", "unsupported_protocol")
M.DISPATCH_CATEGORIES = table.freeze({ "current_admission", "admission_refused", "admission_absent", "stale_authority",
	"stale_revision", "stale_binding", "current_result", "already_consumed", "unknown_effect", "claim_mismatch",
	"migration_blocked", "unsupported_protocol" })
local REFUSAL = enum("admission_refused", "stale_authority", "stale_revision", "stale_binding", "migration_blocked", "unsupported_protocol")
local function public_error(v: any, shapes: any): boolean
	return object(v, { code = bounded(96) }, { message = bounded(512, true), detail = bounded(512, true) }, shapes)
end
local function outstanding(v: any, shapes: any): boolean
	local entry = function(e: any): boolean
		return object(e, { request_serial = positive, request_id = id, action_id = id, op = ACTION_OP,
			phase = enum("pending", "claimed", "launching", "current_result", "uncertain") }, {}, shapes)
	end
	if not object(v, { after_serial = zero, through_serial = zero, next_after_serial = zero, complete = boolean,
		entries = function(e: any): boolean return array(e, entry, shapes, 0, M.DISPATCH.outstanding) end }, {}, shapes)
		or v.after_serial > v.through_serial then return false end
	local previous = v.after_serial
	for _, e in v.entries do
		if e.request_serial <= previous or e.request_serial > v.through_serial then return false end
		previous = e.request_serial
	end
	return if v.complete then v.next_after_serial == v.through_serial
		else #v.entries > 0 and v.next_after_serial == previous and previous < v.through_serial
end
local function provisioned_payload(p: any, shapes: any): boolean
	local limits = function(v: any): boolean return object(v, { mailbox_bytes = positive, mailbox_files = positive,
		host_bytes = positive, host_files = positive, generations = positive, registry_bytes = positive,
		reserved_bytes = positive, deadline_ms = positive, concurrency = positive }, {}, shapes) end
	return object(p, { handle = id, binding_digest = digest,
		capabilities = function(v: any): boolean return array(v, CAPABILITIES, shapes, 0, 8) and unique(v) end,
		limits = limits, identity = function(v: any): boolean return object(v, { worker = bounded(4096) }, {}, shapes) end },
		{ manifest_sha256 = digest }, shapes)
end
local function result_payload(b: any, shapes: any, request: any?): boolean
	local p, status, op = b.payload, b.status, b.op
	local obj = function(v: any): boolean return type(v) == "table" and shapes[v] == "object" end
	if status == "rejected" then return p == nil and b.error ~= nil end
	if status ~= "uncertain" and b.error ~= nil then return false end
	if status == "full" then
		return object(p, { resource = id, current = zero, limit = positive },
			{ retryable = boolean, effect_started = boolean }, shapes)
			and ((p.retryable == nil) == (p.effect_started == nil))
	end
	if status == "stopped" then return op == "stop" and object(p, {
		pane_binding = function(v: any): boolean return M.validate_dispatch_pane(v, shapes) end,
		observation = enum("absent", "exited") }, {}, shapes) and (request == nil or equal(p.pane_binding, request.pane_binding)) end
	if status == "attached" then
		return op == "attach_worker" and object(p, { pane_binding = function(v: any): boolean return M.validate_dispatch_pane(v, shapes) end,
			previous_origin_binding = function(v: any): boolean return M.validate_dispatch_origin(v, shapes) end,
			previous_pane_binding = function(v: any): boolean return M.validate_dispatch_pane(v, shapes) end }, {}, shapes)
			and (request == nil or (equal(p.pane_binding, request.pane_binding) and equal(p.previous_origin_binding, request.previous_origin_binding)
				and equal(p.previous_pane_binding, request.previous_pane_binding)))
	end
	if status == "found" then
		if op ~= "status" or not object(p, { outcome = obj }, {}, shapes) then return false end
		local o = p.outcome
		return ACTION_OP(o.op) and o.spawn_namespace == b.spawn_namespace and o.authority_namespace == b.authority_namespace
			and o.logical_session_id == b.logical_session_id and o.admission_seq == b.admission_seq
			and (request == nil or (o.request_id == request.target_request_id and o.request_serial == request.target_request_serial))
	end
	if op == "mailbox_allocation" and status == "allocation" then
		local allocation = function(v: any): boolean
			if type(v) ~= "table" then return false end
			if v.state == "none" then return object(v, { state = enum("none") }, {}, shapes) end
			return object(v, { state = enum("retained"),
				provision = function(value: any): boolean return provisioned_payload(value, shapes) end }, {}, shapes)
		end
		return object(p, { target = function(v: any): boolean return allocation_target(v, shapes) end,
			allocation = allocation }, {}, shapes) and p.target.logical_session_id == b.logical_session_id
			and (request == nil or equal(p.target, request.target))
	end
	-- Policy and durable effects remain in their owners; all wire containers are closed here.
	local allowed = {
		catalog = { catalog = true }, launch = { resolved = true, claimed = true, launching = true, awaiting_acceptance = true, accepted = true },
		declare_provider_families = { resolved = true },
		mailbox_inventory = { inventory = true },
		mailbox_allocation = { allocation = true },
		adopt = { resolved = true, claimed = true, launching = true, awaiting_acceptance = true, accepted = true },
		enrol = { resolved = true, claimed = true, launching = true, awaiting_acceptance = true, accepted = true },
		accept = { accepted = true }, stop = { resolved = true, claimed = true, launching = true },
		native_wake = { resolved = true, claimed = true, launching = true, submitted = true },
		mailbox_provision = { provisioned = true }, mailbox_read = { read = true, missing = true, incomplete = true, gap = true, compacted = true },
		mailbox_publish_ack = { published = true, already_published = true, already_compacted = true, incomplete = true, missing = true },
		mailbox_publish_reply = { published = true, already_published = true, already_compacted = true, incomplete = true, missing = true },
		mailbox_retire = { compacted = true, retired = true },
	}
	if status ~= "pending" and status ~= "uncertain" and not (allowed[op] and allowed[op][status]) then return false end
	if status == "pending" then return p == nil or object(p, { operation_id = id }, {}, shapes)
		or object(p, { authorization_required = yes }, {}, shapes) end
	if op == "mailbox_inventory" then
		return status == "inventory" and object(p, {
			observed_at_ms = zero,
			open_files = function(v: any): boolean return integer(v, 0, 1000000) end,
			stale_files = function(v: any): boolean return integer(v, 0, 1000000) end,
			mailboxes = function(v: any): boolean return integer(v, 0, 32) end,
		}, {}, shapes) and p.stale_files <= p.open_files
	end
	local caps = function(v: any): boolean return array(v, CAPABILITIES, shapes, 0, 7) and unique(v) end
	local pane = function(v: any): boolean return M.validate_dispatch_pane(v, shapes) end
	local identity = function(v: any): boolean
		return object(v, {}, { backend = bounded(96), provider = bounded(96), account_label = bounded(4096),
			identity_status = enum("configured_not_verified"), model = bounded(4096), profile = bounded(4096),
			variant_id = bounded(4096), capacity_binding = bounded(4096), capacity_limit = positive }, shapes)
	end
	if status == "catalog" then
		local readiness = function(v: any): boolean return object(v, { state = enum("not_run", "passed", "failed", "unavailable"),
			config_revision = zero, summary = bounded(1024, true) }, {}, shapes) end
		local setup = function(v: any): boolean return object(v, { schema = function(s: any): boolean return s == 1 end,
			state = enum("not_started", "in_progress", "completed", "dismissed", "adopted_existing"), config_revision = zero,
			readiness = readiness }, {}, shapes) end
		local row = function(v: any): boolean
			return object(v, { id = record_id, revision = zero, eligible = boolean, capabilities = caps,
				unsupported = function(s: any): boolean return array(s, bounded(4096), shapes) end }, {
				provider = bounded(96), provider_family = provider_family, account_label = bounded(4096), backend = bounded(96), enabled = boolean,
				model_variant = bounded(4096), profile_variant = bounded(4096), selector_evidence = bounded(4096),
				capacity_binding = bounded(4096), cwd = bounded(4096), placement = enum("tab", "split", "replace_if_alone"),
				capability_evidence = bounded(4096), effective_identity = identity }, shapes)
		end
		local required: any = { catalog_version = function(v: any): boolean return v == 2 end, setup = setup, revision = zero,
			config_revision = zero, records = function(v: any): boolean return array(v, row, shapes) end }
		-- Independent first-use inspection must not initialize or invent a SPAWN authority.
		-- Missing established authority is a storage refusal, never this empty setup result.
		if b.setup_origin ~= nil and type(p) == "table" and p.namespace == nil and p.host_key == nil then
			return object(p, required, {}, shapes) and p.revision == 0 and p.config_revision == 0
				and p.setup.state == "not_started" and p.setup.config_revision == 0
				and p.setup.readiness.state == "not_run" and p.setup.readiness.config_revision == 0 and #p.records == 0
		end
		required.namespace, required.host_key = namespace, bounded(1024)
		return object(p, required, { next_cursor = function(v: any): boolean return cursor(v, shapes) end }, shapes)
			and p.config_revision == p.revision and p.setup.config_revision == p.revision
			and (p.next_cursor == nil or p.next_cursor.revision == p.revision)
	end
	if op == "declare_provider_families" and status == "resolved" then
		if not object(p, { config_revision = zero,
			applied = function(v: any): boolean return integer(v, 0, 32) end,
			families = function(v: any): boolean
				return array(v, function(row: any): boolean
					return object(row, { record_id = record_id, provider_family = provider_family }, {}, shapes)
				end, shapes, 1, 32) and unique(v, "record_id")
			end,
		}, {}, shapes) or p.applied > #p.families then return false end
		if request == nil then return true end
		if #p.families ~= #request.declarations then return false end
		local requested = {}
		for _, row in request.declarations do requested[row.record_id] = true end
		for _, row in p.families do if not requested[row.record_id] then return false end end
		return true
	end
	if (op == "launch" or op == "adopt" or op == "enrol") and p ~= nil then
		if not object(p, { record_id = record_id, record_revision = zero, effective_identity = identity, capabilities = caps,
			prompt_delivery = enum("submitted_not_accepted", "not_submitted", "copied_not_accepted") }, { pane_binding = pane }, shapes)
			or (request ~= nil and (p.record_id ~= request.record_id or p.record_revision ~= request.record_revision)) then return false end
		if p.prompt_delivery == "copied_not_accepted" then return op == "enrol" and (request == nil or request.delivery == "clipboard") end
		return op ~= "enrol" or request == nil or request.delivery ~= "clipboard" or p.prompt_delivery == "not_submitted"
	end
	if status == "accepted" then return op == "accept" and object(p, { target_request_id = id, pane_binding = pane }, {}, shapes)
		and (request == nil or (p.target_request_id == request.target_request_id and equal(p.pane_binding, request.pane_binding))) end
	if status == "provisioned" then return provisioned_payload(p, shapes) end
	if status == "read" then return object(p, { object_b64 = bounded(5464), object_sha256 = digest,
		object_bytes = function(v: any): boolean return integer(v, 1, LIMITS.wire) end,
		selector = function(v: any): boolean return selector(v, shapes) end, complete = yes },
		{ next_selector = function(v: any): boolean return selector(v, shapes) end }, shapes)
		and (request == nil or equal(p.selector, request.selector)) end
	if status == "gap" then return object(p, { expected_seq = positive }, {}, shapes) end
	if p ~= nil and (op == "native_wake" or op == "mailbox_publish_ack" or op == "mailbox_publish_reply") then
		if not object(p, { wake_status = enum("awaiting_window", "claimed", "launching", "submitted", "uncertain"), wake_effect_started = boolean },
			{ wake_target_request_id = id, wake_target_action_id = id }, shapes) then return false end
		if op == "native_wake" then return p.wake_target_request_id == nil and p.wake_target_action_id == nil end
		return ((p.wake_target_request_id == nil) == (p.wake_target_action_id == nil))
			and (p.wake_status ~= "awaiting_window" or p.wake_effect_started ~= false or p.wake_target_request_id ~= nil)
	end
	return p == nil and (status == "uncertain" or status == "resolved" or status == "claimed" or status == "launching"
		or status == "submitted" or status == "missing" or status == "incomplete" or status == "compacted"
		or status == "retired" or status == "published" or status == "already_published" or status == "already_compacted")
end
local function response_schema(b: any, shapes: any, request: any?): boolean
	if type(b) ~= "table" then return false end
	local op: string = b.op
	local required: any = { schema = function(v: any): boolean return v == 2 end, op = dispatch_op,
		request_id = id, action_id = id, category = CATEGORY, status = bounded(96) }
	local optional: any = { payload = function(v: any): boolean return type(v) == "table" and shapes[v] == "object" end,
		error = function(v: any): boolean return public_error(v, shapes) end }
	if op == "catalog" and b.setup_origin ~= nil then
		required.setup_origin = function(v: any): boolean return M.validate_dispatch_setup_origin(v, shapes) end
		if b.category ~= "current_result" then return false end
	else
		required.authority_namespace, required.logical_session_id, required.admission_seq = namespace, id, positive
		required.spawn_namespace, required.authority_revision = namespace, zero
		if CONTROL_OP(op) then
			required.control_origin = function(v: any): boolean return M.validate_dispatch_control_origin(v, shapes) end
			if op == "close_session" then required.close_id = id end
		else
			required.origin_binding = function(v: any): boolean return M.validate_dispatch_origin(v, shapes) end
			required.controller_generation = positive
			if ACTION_OP(op) then required.request_serial = positive end
		end
	end
	if not object(b, required, optional, shapes) then return false end
	if b.origin_binding and (b.origin_binding.logical_session_id ~= b.logical_session_id or b.origin_binding.owner_generation ~= b.controller_generation) then return false end
	if b.control_origin then
		if b.control_origin.binding.logical_session_id ~= b.logical_session_id then return false end
		if b.control_origin.kind == "closing" then
			if op ~= "close_session" or b.control_origin.close_id ~= b.close_id then return false end
		end
	end
	if request then
		for _, k in { "op", "request_id", "action_id", "setup_origin", "authority_namespace", "logical_session_id", "admission_seq",
			"request_serial", "origin_binding", "controller_generation", "control_origin", "close_id" } do
			if not equal(b[k], request[k]) then return false end
		end
	end
	local p = b.payload
	if REFUSAL(b.category) then return b.status == "rejected" and p == nil and b.error ~= nil and b.error.code == b.category end
	if b.category == "claim_mismatch" then return b.status == "uncertain" and p == nil and b.error ~= nil and b.error.code == "claim_mismatch" end
	if b.category == "unknown_effect" then return (b.status == "missing" or b.status == "uncertain") and p == nil end
	if b.category == "already_consumed" then return (ACTION_OP(op) or op == "status") and b.status == "already_consumed" and p == nil and b.error == nil end
	if b.category == "current_admission" or b.category == "admission_absent" then
		if not CONTROL_OP(op) then
			if op ~= "owner_status" then return false end
		end
		if b.error ~= nil then return false end
		local payload_required: any = { admission_cursor = zero, compatibility = function(v: any): boolean return M.validate_dispatch_compatibility(v, shapes) end }
		if b.category == "current_admission" then
			payload_required.control = function(v: any): boolean return M.validate_dispatch_control(v, shapes) end
			if op == "reconcile_session" then payload_required.outstanding = function(v: any): boolean return outstanding(v, shapes) end end
			local statuses = { admit_session = "admitted", reconcile_session = "reconciled", close_session = "closing", owner_status = "owner_status" }
			if b.status ~= statuses[op] then return false end
		elseif b.status ~= (if op == "close_session" then "closed" else "absent") then return false end
		if not object(p, payload_required, {}, shapes) then return false end
		local authority_namespace, spawn_namespace = compatibility_names(p.compatibility)
		if authority_namespace ~= b.authority_namespace or spawn_namespace ~= b.spawn_namespace then return false end
		if request and CONTROL_OP(request.op) then
			local _, expected_spawn_namespace = compatibility_names(request.compatibility)
			if b.spawn_namespace ~= expected_spawn_namespace then return false end
		end
		if p.control and (p.admission_cursor < b.admission_seq or p.control.binding and p.control.binding.logical_session_id ~= b.logical_session_id
			or op == "close_session" and (p.control.phase ~= "closing" or p.control.close_id ~= b.close_id)) then return false end
		if p.outstanding and request then
			local c = request.outstanding_cursor
			if p.outstanding.after_serial ~= (if c then c.after_serial else 0)
				or (c ~= nil and p.outstanding.through_serial ~= c.through_serial) or #p.outstanding.entries > request.page_limit then return false end
		end
		return true
	end
	if CONTROL_OP(op) or op == "owner_status" or not result_payload(b, shapes, request) then return false end
	if b.status == "found" then
		-- Only action outcomes are permitted above. Re-encode under that operation's
		-- ordinary framed bound; inspection must not smuggle an oversized original.
		return M.encode_dispatch_response(p.outcome) ~= nil
	end
	return true
end
-- Persisted legacy inspection is not a new wire response: added inspection-only
-- fields must not be charged against protocol 2's framed transport limit.
function M.validate_dispatch_response_body(body: any, shapes: any): boolean
	return response_schema(body, shapes, nil)
end
function M.encode_dispatch_response(body: any): (string?, any?)
	local ok, bytes = pcall(tern.json.encode, body)
	if not ok then return nil, failure("invalid_schema", "Response must be serializable JSON.") end
	local limit = dispatch_response_limit(if type(body) == "table" then body.op else nil)
	local decoded, problem, shapes = M.strict_decode(bytes, limit)
	if problem then return nil, problem end
	if not response_schema(decoded, shapes, nil) then return nil, failure("invalid_schema", "Invalid closed dispatch response.") end
	local wire = M.DISPATCH.prefix .. tern.json.encode({ schema = 2, op = body.op, request_id = body.request_id, complete = true,
		body_bytes = #bytes, body_sha256 = M.sha256(bytes), body_json = bytes })
	if #wire > limit then return nil, failure("oversize", "Complete framed dispatch response exceeds its operation's byte limit.") end
	return wire, nil
end
function M.decode_dispatch_response(bytes: any, request: any): (any?, any?)
	if type(bytes) ~= "string" then return nil, failure("invalid_schema", "Expected complete dispatch response bytes.") end
	local ok, encoded = pcall(tern.json.encode, request)
	if not ok then return nil, failure("invalid_schema", "Expected the original dispatch request.") end
	local valid_request, request_problem = M.decode_dispatch_request(encoded)
	if not valid_request then return nil, request_problem end
	local limit = dispatch_response_limit(valid_request.op)
	if #bytes > limit then return nil, failure("oversize", "Complete framed dispatch response exceeds its operation's byte limit.") end
	if bytes:sub(1, #M.DISPATCH.prefix) ~= M.DISPATCH.prefix then return nil, failure("unsupported_protocol", "Managed dispatch requires protocol 2.") end
	local frame, problem, shapes = M.strict_decode(bytes:sub(#M.DISPATCH.prefix + 1), limit)
	if problem then return nil, problem end
	if not object(frame, { schema = function(v: any): boolean return v == 2 end, op = dispatch_op, request_id = id,
		complete = yes, body_bytes = positive, body_sha256 = digest, body_json = bounded(limit) }, {}, shapes)
		or #frame.body_json ~= frame.body_bytes or M.sha256(frame.body_json) ~= frame.body_sha256 then
		return nil, failure("bridge_incomplete", "Response framing, complete bytes or digest differs.")
	end
	if #bytes > dispatch_response_limit(frame.op) then
		return nil, failure("oversize", "Complete framed dispatch response exceeds its operation's byte limit.")
	end
	local b, body_problem, body_shapes = M.strict_decode(frame.body_json, dispatch_response_limit(frame.op))
	if body_problem then return nil, body_problem end
	if not response_schema(b, body_shapes, nil) then return nil, failure("invalid_schema", "Invalid closed dispatch response.") end
	if frame.op ~= b.op or frame.request_id ~= b.request_id or not response_schema(b, body_shapes, request) then
		return nil, failure("binding_mismatch", "Response differs from the original request or target.")
	end
	return b, nil
end

-- Cross-peer identity evidence is not source-store evidence. Owners select the SPAWN-admitted
-- subset independently from their validated stores; unresolved orphaned work blocks migration.
-- Arrays must already be sorted. Missing capability proof remains absent, never config-derived.
function M.decode_dispatch_managed_projection(bytes: any): (any?, any?, any?)
	local raw, problem, shapes = strict_decode(bytes, MIGRATION_LIMITS.managed_bytes, true)
	if problem then return nil, problem end
	local function sorted(list: any, key: string): boolean
		local previous = ""
		for _, v in list do if v[key] <= previous then return false end; previous = v[key] end
		return true
	end
	local function capabilities(v: any): boolean
		if not array(v, CAPABILITIES, shapes, 1, 8) then return false end
		local previous = ""
		for _, c in v do if c <= previous then return false end; previous = c end
		return table.find(v, "report-files-v1") ~= nil
	end
	local session = function(v: any): boolean
		return object(v, { logical_session_id = id }, {
			binding = function(b: any): boolean return M.validate_dispatch_origin(b, shapes) end,
			controller_pane = decimal }, shapes)
			and ((v.binding == nil) == (v.controller_pane == nil))
			and (v.binding == nil or v.binding.logical_session_id == v.logical_session_id)
	end
	local worker = function(v: any): boolean
		return object(v, { logical_session_id = id, worker_id = id, worker_generation = positive, launch_request_id = id,
			work_id = id, enrolment_sha256 = digest, mailbox_handle = id, record_id = record_id, record_revision = zero,
			binding_digest = digest, mailbox_live = boolean }, {
			manifest_sha256 = digest, handover_id = id, handover_sha256 = digest, capabilities = capabilities,
			execution_origin = function(b: any): boolean return M.validate_dispatch_origin(b, shapes) end,
			execution_controller_pane = decimal, pane_binding = function(p: any): boolean return M.validate_dispatch_pane(p, shapes) end,
			stopped = enum("absent", "exited") }, shapes)
			and ((v.handover_id == nil) == (v.handover_sha256 == nil))
			and ((v.execution_origin == nil) == (v.execution_controller_pane == nil))
			and (v.execution_origin == nil or v.execution_origin.logical_session_id == v.logical_session_id)
			and (v.pane_binding == nil or v.execution_origin ~= nil) and (v.stopped == nil or v.pane_binding ~= nil)
	end
	if not object(raw, { schema = function(v: any): boolean return v == 1 end,
		sessions = function(v: any): boolean return array(v, session, shapes, 0, MIGRATION_LIMITS.sessions) and sorted(v, "logical_session_id") end,
		workers = function(v: any): boolean return array(v, worker, shapes, 0, MIGRATION_LIMITS.workers) and sorted(v, "mailbox_handle") end }, {}, shapes) then
		return nil, failure("invalid_schema", "Invalid canonical managed identity projection.")
	end
	local sessions = {}
	for _, s in raw.sessions do sessions[s.logical_session_id] = true end
	for _, w in raw.workers do
		if not sessions[w.logical_session_id] then return nil, failure("binding_mismatch", "Managed mailbox has no compared admission.") end
	end
	return raw, nil, shapes
end
function M.dispatch_managed_digest(bytes: any): (string?, any?)
	local raw, problem, shapes = M.decode_dispatch_managed_projection(bytes)
	if problem then return nil, problem end
	local decoded_shapes = shapes :: { [{}]: "array" | "object" }
	local function canonical(v: any): string
		if type(v) ~= "table" then return tern.json.encode(v) end
		local parts = {}
		if decoded_shapes[v] == "array" then
			for _, child in v do table.insert(parts, canonical(child)) end
			return "[" .. table.concat(parts, ",") .. "]"
		end
		local keys = {}
		for key in v do table.insert(keys, key) end
		table.sort(keys)
		for _, key in keys do table.insert(parts, tern.json.encode(key) .. ":" .. canonical(v[key])) end
		return "{" .. table.concat(parts, ",") .. "}"
	end
	return M.sha256("orchplus-managed-identities-v1\n" .. canonical(raw)), nil
end

-- Only call after the owning store validator succeeds. Typed keys distinguish array indices
-- from object keys; empty native tables are equivalent under that already-validated schema.
-- This is semantic SOURCE evidence, never the original immutable request byte hash.
-- Return bytes so large stores use the existing resumable SHA API outside a window callback.
function M.dispatch_source_bytes(source: any): string
	local active = {}
	local function canonical(v: any): string
		local kind = type(v)
		if kind ~= "table" then
			assert(kind == "string" or kind == "boolean" or (kind == "number" and v == v and v ~= math.huge and v ~= -math.huge),
				"source store must be validated JSON values")
			return kind .. ":" .. tern.json.encode(v)
		end
		assert(not active[v], "source store cannot contain cycles")
		active[v] = true
		local keys, parts = {}, { "{" }
		for key in v do
			assert(type(key) == "string" or type(key) == "number", "source store keys must be validated")
			table.insert(keys, key)
		end
		table.sort(keys, function(a: any, b: any): boolean return type(a) .. tostring(a) < type(b) .. tostring(b) end)
		for _, key in keys do table.insert(parts, canonical(key) .. "=" .. canonical(v[key]) .. ";") end
		table.insert(parts, "}"); active[v] = nil
		return table.concat(parts)
	end
	return "orchplus-source-state-v1\n" .. canonical(source)
end

return M
