-- Exact bytes, including malformed UTF-8, come from the maintained shared corpus.
local root, consumer, case_id = ...
local environment, modules = getfenv(), {}
local function load(name, base)
	name = (base or "") .. name:gsub("^%./", "")
	if modules[name] then return modules[name] end
	local chunk = assert(loadstring(tern.fs.read(root .. "/" .. name .. ".luau"), name))
	local dir = name:match("^(.*/)")
	setfenv(chunk, setmetatable({ require = function(n) return load(n, dir) end }, { __index = environment }))
	local value = chunk(); modules[name] = value; return value
end
local codec = load(consumer)
local corpus = tern.json.decode(tern.fs.read(tern.plugin.dir .. "/corpus.json"))
local case
for _, entry in corpus.cases do if entry.id == case_id then case = entry; break end end
assert(case, "unknown corpus case " .. tostring(case_id))
local binding = case.binding or corpus.binding
local function bytes(encoded) return tern.base64.decode(encoded) end
local function restore(state) return tern.json.decode(tern.json.encode(state)) end
local value, diagnostic
if case.op == "assembly" then
	local raw = bytes(case.manifest_b64)
	local state
	state, diagnostic = codec.assembly_start(raw, case.manifest_sha256 or codec.sha256(raw), binding)
	value = state
	if state then
		for ordinal, index in case.pushes do
			local chunk = bytes(case.chunks_b64[index])
			local override = case.chunk_sha256 and (case.chunk_sha256[tostring(index)] or case.chunk_sha256[index])
			value, diagnostic = codec.assembly_push(state, chunk, override or codec.sha256(chunk), binding)
			if not value then break end
			if case.restore_after == ordinal then state = restore(state) end
		end
	end
elseif case.op == "frame" then
	local raw = bytes(case.bytes_b64)
	value, diagnostic = codec.frame(raw, case.direction or "report", binding)
	if value then
		local state = assert(codec.assembly_start(value.manifest, codec.sha256(value.manifest), binding))
		for _, chunk in value.chunks do
			local pushed, why = codec.assembly_push(state, chunk, codec.sha256(chunk), binding)
			assert(pushed, why and why.code)
			state = restore(state)
			if pushed.complete then assert(pushed.bytes == raw, "roundtrip changed exact bytes") end
			value = pushed
		end
		assert(value.complete, "framed message never completed")
	end
else
	local raw = bytes(case.bytes_b64)
	if case.trailing_spaces then raw ..= string.rep(" ", case.trailing_spaces) end
	if case.op == "strict_decode" then value, diagnostic = codec.strict_decode(raw, case.maximum)
	elseif case.op == "decode_report" or case.op == "decode_reply" then value, diagnostic = codec[case.op](raw, binding)
	elseif case.op == "decode_object" or case.op == "decode_manifest" or case.op == "decode_dispatch_request" or case.op == "dispatch_managed_digest" then value, diagnostic = codec[case.op](raw)
	elseif case.op == "decode_page" then value, diagnostic = codec.decode_page(raw, case.selector)
	elseif case.op == "decode_dispatch_response" then
		value, diagnostic = codec.decode_dispatch_response(raw, case.request)
	elseif case.op == "encode_dispatch_response" then
		local body = assert(codec.strict_decode(raw))
		value, diagnostic = codec.encode_dispatch_response(body)
		if value and case.request then assert(codec.decode_dispatch_response(value, case.request), "encoded response did not roundtrip") end
	elseif case.op == "dispatch_projection" then
		local proof = assert(codec.strict_decode(raw))
		value = if codec.validate_dispatch_projection(proof, case.request, bytes(case.request_bytes_b64), case.last_revision,
			case.claim, case.spawn_claim) then proof else nil
	elseif case.op == "dispatch_compatibility" then
		local proof, problem, shapes = codec.strict_decode(raw)
		diagnostic = problem
		value = if proof and codec.validate_dispatch_compatibility(proof, shapes)
			and (not case.require_ready or codec.dispatch_compatibility_ready(proof)) then proof else nil
	elseif case.op == "dispatch_migration_selection" then
		local selection, problem, shapes = codec.strict_decode(raw)
		diagnostic = problem
		value = if selection and codec.validate_dispatch_migration_selection(selection, if case.native then nil else shapes) then selection else nil
	elseif case.op == "dispatch_migration_qualification" then
		local qualification, problem, shapes = codec.strict_decode(raw)
		diagnostic = problem
		value = if qualification and codec.validate_dispatch_migration_qualification(qualification, case.owner,
			if case.native then nil else shapes) then qualification else nil
	elseif case.op == "dispatch_source_digest" then
		local source = assert(codec.strict_decode(raw))
		value = codec.sha256(codec.dispatch_source_bytes(source))
	else error("unsupported corpus op " .. tostring(case.op)) end
end
assert((value ~= nil) == case.expect.ok, case.id .. ": unexpected acceptance; " .. tostring(diagnostic and diagnostic.code))
if case.id == "c3-response-nested-current-outcome" then
	-- Exercise the two real transport budgets with a schema-valid ordinary result,
	-- not whitespace or an invalid large field masquerading as retained evidence.
	local original, original_request
	for _, entry in corpus.cases do
		if entry.id == "c3-encode-full-frame-bound" then original = assert(codec.strict_decode(bytes(entry.bytes_b64))) end
		if entry.id == "c3-response-current-launch-all-fields" then original_request = entry.request end
	end
	assert(original and original_request)
	local identity = original.payload.effective_identity
	identity.model = string.rep("m", 4096)
	local low, high, maximum = 1, 4096, 0
	while low <= high do
		local middle = math.floor((low + high) / 2)
		identity.account_label = string.rep("a", middle)
		if codec.encode_dispatch_response(original) then maximum = middle; low = middle + 1 else high = middle - 1 end
	end
	assert(maximum > 0 and maximum < 4096, "ordinary boundary was not reached")
	identity.account_label = string.rep("a", maximum)
	local original_wire = assert(codec.encode_dispatch_response(original))
	assert(#original_wire == codec.LIMITS.bridge and codec.decode_dispatch_response(original_wire, original_request),
		"ordinary response must fit its complete 8192-byte frame")
	local inspection = restore(value)
	inspection.payload.outcome = original
	local inspection_wire = assert(codec.encode_dispatch_response(inspection))
	assert(#inspection_wire > codec.LIMITS.bridge and #inspection_wire <= codec.LIMITS.bridge_status,
		"status must fit the original plus its inspection envelope")
	local found = assert(codec.decode_dispatch_response(inspection_wire, case.request))
	assert(codec.encode_dispatch_response(found.payload.outcome) == original_wire, "inspection changed original bytes")
	assert(codec.decode_dispatch_response(inspection_wire .. string.rep(" ", codec.LIMITS.bridge_status - #inspection_wire), case.request),
		"status must accept its complete boundary")
	assert(codec.decode_dispatch_response(inspection_wire .. string.rep(" ", codec.LIMITS.bridge_status - #inspection_wire + 1), case.request) == nil,
		"status must reject bytes beyond its complete boundary")
	assert(codec.decode_dispatch_response(original_wire .. " ", original_request) == nil,
		"ordinary responses must not inherit the inspection allowance")
	assert(codec.decode_dispatch_request(tern.json.encode(case.request) .. string.rep(" ", codec.LIMITS.bridge)) == nil,
		"status requests must retain the ordinary request allowance")
	local function framed(body)
		local body_json = tern.json.encode(body)
		return codec.DISPATCH.prefix .. tern.json.encode({ schema = 2, op = body.op, request_id = body.request_id,
			complete = true, body_bytes = #body_json, body_sha256 = codec.sha256(body_json), body_json = body_json })
	end
	local function rejects_original(outcome)
		local invalid = restore(inspection)
		invalid.payload.outcome = outcome
		local wire = framed(invalid)
		assert(#wire <= codec.LIMITS.bridge_status, "invalid original must reach schema validation inside the status budget")
		assert(codec.encode_dispatch_response(invalid) == nil and codec.decode_dispatch_response(wire, case.request) == nil,
			"inspection must reject invalid retained originals in both directions")
		local body, problem, shapes = codec.strict_decode(tern.json.encode(invalid), codec.LIMITS.bridge_status)
		assert(body and not problem and not codec.validate_dispatch_response_body(body, shapes),
			"inspection-only body validation must enforce the original operation's bound")
	end
	identity.account_label ..= "a"
	assert(codec.encode_dispatch_response(original) == nil, "one additional ordinary byte must reject")
	rejects_original(original)
	local malformed = restore(found.payload.outcome)
	malformed.unexpected = true
	rejects_original(malformed)
	rejects_original(value)
end
if case.expect.sha256 then assert(value == case.expect.sha256, case.id .. ": canonical digest differs") end
if case.expect.code then
	local got = if diagnostic then diagnostic.code elseif value then value.code else nil
	local allowed = corpus.diagnostics[case.expect.code]
	assert(got == case.expect.code or allowed and table.find(allowed.luau, got), case.id .. ": diagnostic " .. tostring(got))
end
if case.expect.completed_bytes_b64 then
	assert(value == nil and diagnostic and diagnostic.completed_bytes == bytes(case.expect.completed_bytes_b64),
		case.id .. ": rejected complete bytes were not retained exactly")
end
return "shared/" .. consumer .. "/" .. case.id .. ": 1 checks passed"
