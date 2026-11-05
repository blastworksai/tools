--!strict

-- Pure report-files-v1 codecs. Parsing/reassembly is not durable acceptance or an ACK.
-- SPAWN owns files; the later workflow reducer owns sequence cursors and committed receipts.
local M = {}
local MAX_INTEGER = 9007199254740991
local LIMITS = table.freeze({ wire = 8192, chunk = 4096, control = 2048, bridge = 8192,
	logical = 65536, slice = 2048, chunks = 32, depth = 12, values = 2048,
	array_entries = 256, object_fields = 64, payload_string = 32768,
	assemblies = 4, reassembly_bytes = 262144 })
M.LIMITS = LIMITS

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
function M.strict_decode(bytes: any, maximum: number?): (any?, any?, any?)
	local limit = maximum or LIMITS.logical
	if not integer(limit, 1, LIMITS.logical) then return nil, failure("invalid_schema", "Invalid decoding bound."), nil end
	if type(bytes) ~= "string" or #bytes == 0 then return nil, failure("invalid_schema", "Expected complete JSON bytes."), nil end
	if #bytes > limit then return nil, failure("oversize", "Encoded JSON exceeds its transport limit."), nil end
	local valid_utf8, length = pcall(utf8.len, bytes)
	if not valid_utf8 or length == nil or bytes:sub(1, 3) == "\239\187\191" then
		return nil, failure("invalid_schema", "JSON must be UTF-8 without a BOM."), nil
	end
	local cursor, values = 1, 0
	local shapes: any = {}
	local function bad() error("invalid JSON", 0) end
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
		if values > LIMITS.values then bad() end
		space()
		local byte = bytes:byte(cursor)
		if byte == 34 then return string_value() end
		if byte == 123 or byte == 91 then
			local object = byte == 123
			local result = if object then {} else tern.json.array()
			shapes[result] = if object then "object" else "array"
			local closer = if object then 125 else 93
			cursor += 1
			space()
			if bytes:byte(cursor) == closer then cursor += 1 return result end
			local entries = 0
			while true do
				entries += 1
				if entries > (if object then LIMITS.object_fields else LIMITS.array_entries) then bad() end
				if object then
					local key = string_value()
					if #key > 64 or result[key] ~= nil then bad() end
					space()
					if bytes:byte(cursor) ~= 58 then bad() end
					cursor += 1
					result[key] = parse(depth + 1)
				else table.insert(result, parse(depth + 1)) end
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
		bad()
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

function M.sha256(bytes: string): string
	local bits = #bytes * 8
	local padded = bytes .. "\128" .. string.rep("\0", (55 - #bytes) % 64)
		.. word_bytes(math.floor(bits / MOD)) .. word_bytes(bits % MOD)
	local h = { 0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a, 0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19 }
	local w = table.create(64, 0)
	for first = 1, #padded, 64 do
		for index = 1, 16 do
			local a, b, c, d = padded:byte(first + (index - 1) * 4, first + (index - 1) * 4 + 3)
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
	return string.format("%08x%08x%08x%08x%08x%08x%08x%08x", h[1], h[2], h[3], h[4], h[5], h[6], h[7], h[8])
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
local B = { logical_session_id = id, worker_id = id, worker_generation = positive, launch_request_id = id, work_id = id }
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
local REPORT_KINDS = enum("REGISTER", "READY", "ACCEPTED", "HEARTBEAT", "WAITING", "BLOCKED", "ASK", "CHECKPOINT", "REVIEW_READY", "REVIEW_RESULT", "DONE", "ROLLOVER_REQUEST", "LANDING_REQUEST", "LANDING_RESULT", "COORDINATOR_RELEASE", "reply_ack", "COORDINATOR_PROPOSAL")
local CAPABILITIES = enum("report-files-v1", "native-ask-v1", "worker-poll-v1", "argv-v1", "coordinator-control-v1")
local function report_payload(report: any, shapes: any): boolean
	local p, kind = report.payload, report.kind
	local references = function(v: any): boolean return array(v, short, shapes) end
	-- Optional worker self-report of omp's displayed context usage, matching ORCH+ transport.
	local context = function(v: any): boolean return integer(v, 0, 100) end
	local texts = function(v: any): boolean return array(v, long, shapes) end
	if kind == "REGISTER" then
		if not object(p, { capabilities = function(v: any): boolean return array(v, CAPABILITIES, shapes, 1, 5) end }, {}, shapes) then return false end
		local seen = {}
		for _, capability in p.capabilities do if seen[capability] then return false end seen[capability] = true end
		return seen["report-files-v1"] == true
	elseif kind == "READY" then return object(p, { state = enum("idle") }, { summary = short, context_used_pct = context }, shapes)
	elseif kind == "ACCEPTED" then return object(p, { assignment_sha256 = digest }, {}, shapes)
	elseif kind == "HEARTBEAT" then return object(p, { state = enum("working", "idle", "waiting", "blocked") }, { summary = short, request_id = id, context_used_pct = context }, shapes)
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
			{ plan_ref = short, plan_revision = short, request_id = id }, shapes) and ((p.plan_ref == nil) == (p.plan_revision == nil))
	elseif kind == "REVIEW_READY" then return object(p, { checkpoint_id = id, artifact_revision = short }, { summary = short }, shapes)
	elseif kind == "REVIEW_RESULT" then return object(p, { artifact_revision = short, outcome = enum("approved", "changes_required"), evidence = references }, { summary = short }, shapes)
	elseif kind == "DONE" then return object(p, { checkpoint_id = id, artifact_revision = short, summary = long }, {}, shapes)
	elseif kind == "ROLLOVER_REQUEST" then return object(p, { checkpoint_id = id, reason = short }, {}, shapes)
	elseif kind == "LANDING_REQUEST" then
		return object(p, { checkpoint_id = id, project_id = id, repo_ref = short, target_ref = short, target_revision = short,
			source_ref = short, source_revision = short }, { summary = short }, shapes)
	elseif kind == "LANDING_RESULT" then
		-- Kept exactly in step with ORCH+ transport: outcome-specific fields are required or forbidden.
		if not object(p, { landing_id = id, grant_id = id, project_id = id, repo_ref = short, target_ref = short, target_revision = short,
			source_revision = short, outcome = enum("landed", "rejected", "stale_target", "uncertain"), evidence = references },
			{ result_revision = short, observed_target_revision = short, reason = short, pr_ref = short, summary = short }, shapes) then return false end
		return (p.outcome == "landed") == (p.result_revision ~= nil) and (p.outcome == "stale_target") == (p.observed_target_revision ~= nil)
			and (p.outcome ~= "stale_target" or p.observed_target_revision ~= p.target_revision)
			and (if p.outcome == "landed" then p.reason == nil elseif p.outcome == "stale_target" then true else p.reason ~= nil)
	elseif kind == "COORDINATOR_PROPOSAL" then
		if not object(p, { owner_id = id, owner_generation = positive, activation_token = digest, proposal_id = id,
			kind = enum("dispatch", "report", "review", "rollover", "landing"), work_id = id, project_id = id },
			{ checkpoint_id = id, record_id = short, record_revision = function(v: any): boolean return integer(v, 0) end, prompt = long }, shapes) then return false end
		if p.kind == "dispatch" then return p.checkpoint_id == nil and p.record_id ~= nil and p.record_revision ~= nil and p.prompt ~= nil end
		return p.record_id == nil and p.record_revision == nil and p.prompt == nil and ((p.kind == "report") == (p.checkpoint_id == nil))
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
	local action_optional = raw.kind == "CHECKPOINT" or raw.kind == "DONE" or raw.kind == "WAITING" or raw.kind == "BLOCKED"
	if (raw.action_id == nil) ~= (raw.action_revision == nil) or (action_required and raw.action_id == nil)
		or (not action_required and not action_optional and raw.action_id ~= nil) then return nil, failure("invalid_schema", "Invalid action correlation fields.") end
	if (raw.handover_id == nil) ~= (raw.handover_token == nil) or (raw.kind ~= "ACCEPTED" and raw.handover_id ~= nil) then
		return nil, failure("invalid_schema", "Invalid handover correlation fields.")
	end
	if raw.kind == "reply_ack" and #bytes > LIMITS.control then return nil, failure("oversize", "Reserved reply acknowledgement exceeds its control limit.") end
	if not binding_matches(raw, expected, true) or not id(expected.mailbox_handle) then return nil, failure("binding_mismatch", "Report differs from the provisioned enrolment.") end
	if (raw.kind == "COORDINATOR_RELEASE" or raw.kind == "COORDINATOR_PROPOSAL") and (type(expected.capabilities) ~= "table"
		or table.find(expected.capabilities, "coordinator-control-v1") == nil) then
		return nil, failure("binding_mismatch", "Coordinator control requires its provisioned capability.")
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

function M.decode_reply(bytes: any, expected: any): (any?, any?)
	local raw, diagnostic, shapes = M.strict_decode(bytes)
	if diagnostic ~= nil then return nil, diagnostic end
	if not object(raw, schema({ version = function(v: any): boolean return v == 1 end, message_id = id, reply_seq = positive,
		action_id = id, action_revision = positive, kind = enum("assignment", "report_request", "owner_decision", "landing_grant", "landing_refresh", "coordinator_activation", "coordinator_retirement"), payload = any_table }),
		{ gate_id = id, gate_revision = positive }, shapes) then return nil, failure("invalid_schema", "Invalid reply envelope.") end
	local p, valid = raw.payload, false
	if raw.kind == "assignment" then valid = object(p, { assignment_ref = short, assignment_sha256 = digest, instructions = long }, {}, shapes)
	elseif raw.kind == "report_request" then valid = object(p, { request_id = id, requested_kind = enum("HEARTBEAT", "CHECKPOINT"), reason = short }, {}, shapes)
	elseif raw.kind == "owner_decision" then valid = object(p, { choice_id = id, answer = long }, {}, shapes)
	elseif raw.kind == "landing_grant" then valid = object(p, { landing_id = id, grant_id = id, project_id = id, checkpoint_id = id, repo_ref = short,
		target_ref = short, target_revision = short, source_ref = short, source_revision = short }, {}, shapes)
	elseif raw.kind == "landing_refresh" then valid = object(p, { landing_id = id, project_id = id, repo_ref = short, target_ref = short,
		expected_revision = short, current_revision = short, reason = short }, {}, shapes)
	elseif raw.kind == "coordinator_activation" then valid = object(p, { owner_id = id, owner_generation = positive, activation_token = digest, instructions = long }, {}, shapes)
	elseif raw.kind == "coordinator_retirement" then valid = object(p, { owner_id = id, owner_generation = positive, activation_token = digest, reason = short }, {}, shapes) end
	if not valid or (raw.kind == "owner_decision" and (raw.gate_id == nil or raw.gate_revision == nil))
		or (raw.kind ~= "owner_decision" and (raw.gate_id ~= nil or raw.gate_revision ~= nil)) then return nil, failure("invalid_schema", "Invalid closed reply payload or gate fields.") end
	if raw.kind == "report_request" and #bytes > LIMITS.control then return nil, failure("oversize", "Report-request reply exceeds its control limit.") end
	if not binding_matches(raw, expected, false) then return nil, failure("binding_mismatch", "Reply differs from its recipient binding.") end
	if (raw.kind == "coordinator_activation" or raw.kind == "coordinator_retirement")
		and (type(expected.capabilities) ~= "table" or table.find(expected.capabilities, "coordinator-control-v1") == nil) then
		return nil, failure("binding_mismatch", "Coordinator control requires its provisioned capability.")
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
	if not binding_matches(raw, expected, false) then return nil, failure("binding_mismatch", "ACK differs from its report binding.") end
	for _, key in { "event_id", "seq", "event_sha256" } do
		if expected[key] == nil or raw[key] ~= expected[key] then return nil, failure("binding_mismatch", "ACK does not match the retained exact report bytes.") end
	end
	for _, key in { "committed_revision", "receipt_chain_sha256" } do
		if expected[key] ~= nil and raw[key] ~= expected[key] then return nil, failure("binding_mismatch", "ACK differs from the recorded receipt.") end
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
	local raw = previous:gsub("..", function(pair: string): string return string.char(tonumber(pair, 16)) end)
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

function M.begin_assembly(pool: any, bytes: any, expected: any, object_sha256: any): (any?, any?)
	local manifest, diagnostic = verified_object(bytes, object_sha256)
	if diagnostic ~= nil then return nil, diagnostic end
	if manifest.type ~= "manifest" then return nil, failure("invalid_schema", "Begin reassembly with a complete manifest.") end
	if type(expected) ~= "table" or manifest.mailbox_handle ~= expected.mailbox_handle then return nil, failure("binding_mismatch", "Manifest is for another mailbox.") end
	for key, validate in B do if not validate(expected[key]) then return nil, failure("binding_mismatch", "Missing provisioned message binding.") end end
	if manifest.direction == "report" and not token(expected.enrolment_token) then return nil, failure("binding_mismatch", "Missing provisioned report token.") end
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
	for _, key in { "mailbox_handle", "direction", "slot", "message_id", "message_sha256", "count" } do
		if chunk[key] ~= manifest[key] then return nil, failure("content_conflict", "Chunk identity differs from its immutable manifest.") end
	end
	local decoded = base64(chunk.data_b64, 2732)
	local expected_length = if chunk.index < chunk.count then LIMITS.slice else manifest.message_bytes - (manifest.count - 1) * LIMITS.slice
	if #decoded ~= expected_length then return nil, failure("incomplete", "Chunk length does not match the manifest.") end
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
		if #logical_bytes ~= manifest.message_bytes or M.sha256(logical_bytes) ~= manifest.message_sha256 then return nil, failure("content_conflict", "Whole-message original-byte digest differs from the manifest.") end
		local logical, err
		if manifest.direction == "report" then logical, err = M.decode_report(logical_bytes, expected) else logical, err = M.decode_reply(logical_bytes, expected) end
		if err ~= nil then return nil, err end
		local slot = if manifest.direction == "report" then logical.seq else logical.reply_seq
		local message_id = if manifest.direction == "report" then logical.event_id else logical.message_id
		if slot ~= manifest.slot or message_id ~= manifest.message_id then return nil, failure("binding_mismatch", "Logical envelope differs from its framing identity.") end
		M.discard_assembly(pool, chunk.mailbox_handle)
		return { ok = true, complete = true, envelope = logical, bytes = logical_bytes, sha256 = manifest.message_sha256, direction = manifest.direction }, nil
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

return M
