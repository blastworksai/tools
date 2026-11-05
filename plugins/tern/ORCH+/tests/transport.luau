-- Run with the plugin directory, using the same isolated loader as state tests.
local root = ...
assert(type(root) == "string", "pass the plugin directory")
local runtime, environment = tern, getfenv()
local modules = {}
local function load(name)
	name = name:gsub("^%./", "")
	if modules[name] ~= nil then return modules[name] end
	local chunk = assert(loadstring(runtime.fs.read(root .. "/" .. name .. ".luau"), name))
	setfenv(chunk, setmetatable({ require = load, tern = runtime }, { __index = environment }))
	local module = chunk()
	modules[name] = module
	return module
end
local transport = load("transport")
local checks = 0
local function check(condition, message)
	assert(condition, message)
	checks += 1
end
local function encode(value) return runtime.json.encode(value) end
local function clone(value) return runtime.json.decode(encode(value)) end
local function rejected(value, diagnostic, code, message)
	check(value == nil and diagnostic ~= nil and diagnostic.ok == false and diagnostic.code == code, message .. ": " .. tostring(diagnostic and diagnostic.code))
end
local hash = transport.sha256
check(hash("") == "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855", "SHA empty standard vector")
check(hash("abc") == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad", "SHA abc standard vector")
check(hash("abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq") == "248d6a61d20638b8e5c026930c3e6039a33ce45964ff2167f6ecedd419db06c1", "SHA multi-block standard vector")
for size, expected in {
	[55] = "9f4390f8d30c2dd92ec9f095b65e2b9ae9b0a925a5258e241c9f1e910f734318",
	[56] = "b35439a4ac6f0948b6d6f9e3c6af0f5f590ce20f1bde7090ef7970686ec6738a",
	[64] = "ffe054fe7ae0cb6dc65c3af9b61d5209f439851db43d0ba5997337df154668eb",
} do check(hash(string.rep("a", size)) == expected, "SHA padding boundary " .. tostring(size)) end
local binary = {}
for byte = 0, 255 do table.insert(binary, string.char(byte)) end
check(hash(table.concat(binary)) == "40aff2e9d2d8922e47afd4648e6967497158785fbd1da870e7110266bf944880", "SHA hashes raw binary, not text or Base64")

for _, bytes in {
	'{"a":1,"a":2}', '{"a":1,"\\u0061":2}', '{"a":null}', '[null]', 'null',
	'{"a":01}', '{"a":1.}', '{"a":1e}', '{"a":1e999}', '{"a":NaN}', '{"a":true,}',
	'[] trailing', '\239\187\191{}', '{"a":"\255"}', '{"a":"\\uD800"}', '{"a":"\\uDC00"}',
} do
	local value, diagnostic = transport.strict_decode(bytes)
	rejected(value, diagnostic, "invalid_schema", "strict parser rejects invalid/ambiguous JSON")
end
check(transport.strict_decode('{"a":"\\uD83D\\uDE00","b":false,"c":-0.25e2}') ~= nil, "valid Unicode pair, boolean and JSON number parsed")
local value, diagnostic = transport.strict_decode("{}" .. string.rep(" ", 8190), 8192)
check(value ~= nil, "8192-byte generic wire JSON boundary allowed")
value, diagnostic = transport.strict_decode("{}" .. string.rep(" ", 8191), 8192)
rejected(value, diagnostic, "oversize", "8193-byte wire JSON rejected before parsing")
value, diagnostic = transport.strict_decode(string.rep("[", 13) .. "0" .. string.rep("]", 13))
rejected(value, diagnostic, "invalid_schema", "JSON depth bound enforced")
value, diagnostic = transport.strict_decode("[" .. string.rep("0,", 256) .. "0]")
rejected(value, diagnostic, "invalid_schema", "array bound enforced")
local many_fields = {}
for index = 1, 65 do table.insert(many_fields, '"k' .. tostring(index) .. '":0') end
value, diagnostic = transport.strict_decode("{" .. table.concat(many_fields, ",") .. "}")
rejected(value, diagnostic, "invalid_schema", "object field bound enforced")
local many_values = "[" .. table.concat(table.create(8, "[" .. table.concat(table.create(256, "0"), ",") .. "]"), ",") .. "]"
value, diagnostic = transport.strict_decode(many_values)
rejected(value, diagnostic, "invalid_schema", "total value bound enforced")

local binding = { logical_session_id = "session_1", worker_id = "worker_1", worker_generation = 1,
	launch_request_id = "launch_1", work_id = "work_1", enrolment_token = "abcdefghijklmnop", mailbox_handle = "mailbox_1" }
local function report(kind, payload, extra, target_binding)
	local selected = target_binding or binding
	local result = { version = 3, logical_session_id = selected.logical_session_id, worker_id = selected.worker_id,
		worker_generation = selected.worker_generation, launch_request_id = selected.launch_request_id, work_id = selected.work_id,
		enrolment_token = selected.enrolment_token, seq = 1, event_id = hash(selected.mailbox_handle .. ":report:1"), kind = kind, payload = payload }
	if extra then for key, child in extra do result[key] = child end end
	return result
end
local zero_hash = string.rep("0", 64)
local list = runtime.json.array
local fixtures = {
	{ "REGISTER", { capabilities = list({ "report-files-v1", "native-ask-v1" }) } },
	{ "READY", { state = "idle", summary = "Ready" } },
	{ "ACCEPTED", { assignment_sha256 = zero_hash } },
	{ "HEARTBEAT", { state = "working" } },
	{ "WAITING", { reason = "Waiting for a decision", request_id = "question_1" } },
	{ "BLOCKED", { reason = "Blocked", evidence = list({ "artifact/ref" }) } },
	{ "ASK", { question = "Which option?", options = list({ { id = "yes", label = "Proceed" } }) } },
	{ "CHECKPOINT", { checkpoint_id = "cp_1", task_ref = "task/ref", project_id = "project_1", worktree_ref = "tree/ref", artifact_revision = "abc",
		completed = list({ "Finished work" }), remaining = list(), holds = list(), checks = list({ { check_id = "unit", artifact_revision = "abc", outcome = "passed", evidence_ref = "checks/ref" } }),
		plan_ref = "plan/ref", plan_revision = "3" } },
	{ "REVIEW_READY", { checkpoint_id = "cp_1", artifact_revision = "abc" } },
	{ "REVIEW_RESULT", { artifact_revision = "abc", outcome = "approved", evidence = list() }, { action_id = "review_1", action_revision = 1 } },
	{ "DONE", { checkpoint_id = "cp_1", artifact_revision = "abc", summary = "Complete" } },
	{ "ROLLOVER_REQUEST", { checkpoint_id = "cp_1", reason = "Fresh context needed" } },
	{ "LANDING_RESULT", { landing_id = "landing_1", grant_id = "grant_1", project_id = "project_1", repo_ref = "repo/ref", target_ref = "main", target_revision = "base",
		source_revision = "abc", outcome = "landed", result_revision = "def", evidence = list() }, { action_id = "landing_1", action_revision = 1 } },
	{ "reply_ack", { message_id = "reply_1", reply_seq = 1, reply_sha256 = zero_hash, status = "recorded" }, { action_id = "action_1", action_revision = 1 } },
	{ "LANDING_REQUEST", { checkpoint_id = "cp_1", project_id = "project_1", repo_ref = "repo/ref", target_ref = "main", target_revision = "base",
		source_ref = "work/branch", source_revision = "abc", summary = "Ready to land" } },
}
for _, fixture in fixtures do
	local decoded, err = transport.decode_report(encode(report(fixture[1], fixture[2], fixture[3])), binding)
	check(decoded ~= nil and err == nil and decoded.kind == fixture[1], "closed report schema " .. fixture[1])
end
local good = report("ACCEPTED", { assignment_sha256 = zero_hash })
local bytes = encode(good)
local mutated = clone(good)
mutated.pane = 42
value, diagnostic = transport.decode_report(encode(mutated), binding)
rejected(value, diagnostic, "invalid_schema", "report pane claims forbidden")
mutated = clone(good)
mutated.kind = "owner_decision"
value, diagnostic = transport.decode_report(encode(mutated), binding)
rejected(value, diagnostic, "invalid_schema", "worker cannot send owner approval")
mutated = clone(good)
mutated.payload.command = "do-not-execute"
value, diagnostic = transport.decode_report(encode(mutated), binding)
rejected(value, diagnostic, "invalid_schema", "payload command injection forbidden")
for _, field in { "logical_session_id", "worker_id", "launch_request_id", "work_id", "enrolment_token" } do
	mutated = clone(good)
	mutated[field] = if field == "enrolment_token" then "changed_token_1234" else "other"
	value, diagnostic = transport.decode_report(encode(mutated), binding)
	rejected(value, diagnostic, "binding_mismatch", "wrong report binding " .. field)
end
mutated = clone(good)
mutated.worker_generation = 2
value, diagnostic = transport.decode_report(encode(mutated), binding)
rejected(value, diagnostic, "binding_mismatch", "mixed worker generation rejected")
mutated = clone(good)
mutated.seq = 9007199254740992
value, diagnostic = transport.decode_report(encode(mutated), binding)
rejected(value, diagnostic, "invalid_schema", "sequence overflow rejected")
mutated = clone(good)
mutated.event_id = "invented"
value, diagnostic = transport.decode_report(encode(mutated), binding)
rejected(value, diagnostic, "binding_mismatch", "event identity derives from exact mailbox and sequence")
mutated = clone(good)
mutated.action_id, mutated.action_revision = "unexpected", 1
value, diagnostic = transport.decode_report(encode(mutated), binding)
rejected(value, diagnostic, "invalid_schema", "action fields forbidden for ordinary acceptance")
mutated = report("REVIEW_RESULT", { artifact_revision = "abc", outcome = "approved", evidence = list() }, { action_id = "missing-revision" })
value, diagnostic = transport.decode_report(encode(mutated), binding)
rejected(value, diagnostic, "invalid_schema", "result requires complete action correlation")
mutated = clone(good)
mutated.handover_id, mutated.handover_token = "handover_1", "handover_token_123"
value, diagnostic = transport.decode_report(encode(mutated), binding)
rejected(value, diagnostic, "binding_mismatch", "ordinary acceptance cannot invent rollover binding")
local rollover_binding = clone(binding)
rollover_binding.handover_id, rollover_binding.handover_token = mutated.handover_id, mutated.handover_token
check(transport.decode_report(encode(mutated), rollover_binding) ~= nil, "issued rollover pair accepted")
value, diagnostic = transport.decode_report(bytes, rollover_binding)
rejected(value, diagnostic, "binding_mismatch", "rollover acceptance must carry both issued handover fields")
for _, capabilities in { list({ "report-files-v1", "report-files-v1" }), list({ "report-files-v1", "unknown" }), list({ "argv-v1" }), {} } do
	value, diagnostic = transport.decode_report(encode(report("REGISTER", { capabilities = capabilities })), binding)
	rejected(value, diagnostic, "invalid_schema", "REGISTER capabilities are bounded, unique, known and array-shaped")
end
local restricted_binding = clone(binding)
restricted_binding.capabilities = { "report-files-v1" }
value, diagnostic = transport.decode_report(encode(report("REGISTER", { capabilities = list({ "report-files-v1", "native-ask-v1" }) })), restricted_binding)
rejected(value, diagnostic, "binding_mismatch", "declaration cannot expand provisioned capabilities")
value, diagnostic = transport.decode_report(encode(report("BLOCKED", { reason = string.rep("x", 32769) })), binding)
rejected(value, diagnostic, "invalid_schema", "payload string byte limit enforced")
value, diagnostic = transport.decode_report(encode(report("ASK", { question = "Which?", options = {} })), binding)
rejected(value, diagnostic, "invalid_schema", "empty object cannot impersonate an options array")
mutated = clone(fixtures[8][2])
mutated.plan_revision = nil
value, diagnostic = transport.decode_report(encode(report("CHECKPOINT", mutated)), binding)
rejected(value, diagnostic, "invalid_schema", "checkpoint plan reference requires matching revision")
mutated = clone(fixtures[13][2])
mutated.result_revision = nil
value, diagnostic = transport.decode_report(encode(report("LANDING_RESULT", mutated, fixtures[13][3])), binding)
rejected(value, diagnostic, "invalid_schema", "landed result requires actual resulting revision")
-- Landing results: outcome-specific fields are required or forbidden exactly as SPAWN validates them.
local landing_base = fixtures[13][2]
local function landing_case(change, extra)
	local payload = clone(landing_base); payload.result_revision = nil
	for key, child in change do payload[key] = child end
	return transport.decode_report(encode(report("LANDING_RESULT", payload, extra or fixtures[13][3])), binding)
end
for _, accepted in {
	{ outcome = "landed", result_revision = "def", pr_ref = "pr/1", summary = "Merged" },
	{ outcome = "rejected", reason = "Conflicts in shared file" },
	{ outcome = "stale_target", observed_target_revision = "moved" },
	{ outcome = "stale_target", observed_target_revision = "moved", reason = "Target advanced" },
	{ outcome = "uncertain", reason = "Push timed out" },
} do
	check(landing_case(accepted) ~= nil, "landing result outcome " .. accepted.outcome .. " parses with its exact fields")
end
for _, refused in {
	{ { outcome = "landed", result_revision = "def", reason = "extra" }, "landed forbids a reason" },
	{ { outcome = "rejected" }, "rejected requires a reason" },
	{ { outcome = "rejected", reason = "x", result_revision = "def" }, "only landed carries a resulting revision" },
	{ { outcome = "stale_target" }, "stale target requires the observed head" },
	{ { outcome = "stale_target", observed_target_revision = "base" }, "stale target observed head must differ from the expected head" },
	{ { outcome = "uncertain" }, "uncertain requires a reason" },
	{ { outcome = "failed", reason = "legacy" }, "legacy failed outcome is not part of the landing contract" },
	{ { outcome = "landed", result_revision = "def", landing_id = "bad id" }, "landing ID is a closed identifier" },
	{ { outcome = "landed", result_revision = "def", command = "git merge" }, "no command field can ride on a result" },
} do
	local value, diagnostic = landing_case(refused[1])
	rejected(value, diagnostic, "invalid_schema", refused[2])
end
value, diagnostic = landing_case({ outcome = "landed", result_revision = "def" }, {})
rejected(value, diagnostic, "invalid_schema", "landing result requires the exact grant action correlation")
value, diagnostic = transport.decode_report(encode(report("LANDING_REQUEST", fixtures[15][2], { action_id = "landing_1", action_revision = 1 })), binding)
rejected(value, diagnostic, "invalid_schema", "landing request is not a correlated result")
for _, field in { "checkpoint_id", "project_id", "repo_ref", "target_ref", "target_revision", "source_ref", "source_revision" } do
	mutated = clone(fixtures[15][2]); mutated[field] = nil
	value, diagnostic = transport.decode_report(encode(report("LANDING_REQUEST", mutated)), binding)
	rejected(value, diagnostic, "invalid_schema", "landing request requires exact " .. field)
end
-- Landing evidence is worker-attested: exact revision, run checks, no failures and no holds.
local function landing_checkpoint(change)
	local payload = clone(fixtures[8][2]); payload.plan_ref = nil; payload.plan_revision = nil
	for key, child in change or {} do payload[key] = child end
	return { kind = "CHECKPOINT", payload = payload }
end
local verified = transport.verify_landing(landing_checkpoint(), "abc")
check(verified and verified.attestation == "worker-attested" and verified.artifact_revision == "abc", "fresh passed checks verify landing evidence")
for _, case in {
	{ nil, "def", "verification_stale", "checkpoint for another revision" },
	{ { checks = list() }, "abc", "verification_missing", "no required checks" },
	{ { checks = list({ { check_id = "unit", artifact_revision = "abc", outcome = "not_run", evidence_ref = "r" } }) }, "abc", "verification_missing", "not_run check" },
	{ { checks = list({ { check_id = "unit", artifact_revision = "abc", outcome = "failed", evidence_ref = "r" } }) }, "abc", "verification_failed", "failed check" },
	{ { checks = list({ { check_id = "unit", artifact_revision = "old", outcome = "passed", evidence_ref = "r" } }) }, "abc", "verification_stale", "check for another revision" },
	{ { holds = list({ "Owner hold" }) }, "abc", "hold_present", "checkpoint hold" },
} do
	local value, problem = transport.verify_landing(landing_checkpoint(case[1]), case[2])
	check(value == nil and problem.code == case[3], "landing evidence blocks: " .. case[4])
end
local missing, missing_problem = transport.verify_landing(nil, "abc")
check(missing == nil and missing_problem.code == "checkpoint_missing", "absent checkpoint blocks landing")

local function reply(kind, payload)
	return { version = 1, logical_session_id = binding.logical_session_id, worker_id = binding.worker_id,
		worker_generation = binding.worker_generation, launch_request_id = binding.launch_request_id, work_id = binding.work_id,
		message_id = "message_1", reply_seq = 1, action_id = "action_1", action_revision = 1, kind = kind, payload = payload }
end
for _, fixture in {
	{ "assignment", { assignment_ref = "task/ref", assignment_sha256 = zero_hash, instructions = "Use the explicit assignment." } },
	{ "report_request", { request_id = "request_1", requested_kind = "HEARTBEAT", reason = "Status requested" } },
	{ "owner_decision", { choice_id = "choice_1", answer = "Proceed" } },
	{ "landing_grant", { landing_id = "landing_1", grant_id = "grant_1", project_id = "project_1", checkpoint_id = "cp_1", repo_ref = "repo/ref",
		target_ref = "main", target_revision = "base", source_ref = "work/branch", source_revision = "abc" } },
	{ "landing_refresh", { landing_id = "landing_1", project_id = "project_1", repo_ref = "repo/ref", target_ref = "main",
		expected_revision = "base", current_revision = "moved", reason = "Target moved; refresh against current_revision." } },
} do
	local candidate = reply(fixture[1], fixture[2])
	if candidate.kind == "owner_decision" then candidate.gate_id, candidate.gate_revision = "gate_1", 1 end
	check(transport.decode_reply(encode(candidate), binding) ~= nil, "closed reply schema " .. candidate.kind)
end
local reply_value = reply("owner_decision", { choice_id = "choice_1", answer = "Proceed" })
value, diagnostic = transport.decode_reply(encode(reply_value), binding)
rejected(value, diagnostic, "invalid_schema", "owner reply requires explicit gate revision")
reply_value = reply("report_request", { request_id = "request_1", requested_kind = "CHECKPOINT", reason = "Status" })
local reply_bytes = encode(reply_value)
value, diagnostic = transport.decode_reply(reply_bytes .. string.rep(" ", 2049 - #reply_bytes), binding)
rejected(value, diagnostic, "oversize", "report-request reserved control limit enforced")
reply_value = reply("landing_grant", { project_id = "project_1", target_ref = "main", source_revision = "abc", checkpoint_id = "cp_1", grant_id = "grant_1" })
value, diagnostic = transport.decode_reply(encode(reply_value), binding)
rejected(value, diagnostic, "invalid_schema", "landing grant must name the exact landing, repository, expected head and source ref")
reply_value = reply("landing_refresh", { landing_id = "landing_1", project_id = "project_1", repo_ref = "repo/ref", target_ref = "main", expected_revision = "base",
	reason = "Target moved" })
value, diagnostic = transport.decode_reply(encode(reply_value), binding)
rejected(value, diagnostic, "invalid_schema", "landing refresh must name the current target head")

local initial = transport.receipt_chain(binding.mailbox_handle)
check(initial == "c625fb3a7e3ffb10011664ce99a1179c3d5201df36904c7e15b8f452359dd1c4", "receipt chain initial independent fixture")
local chain = transport.receipt_chain(binding.mailbox_handle, initial, { seq = 1, event_id = good.event_id, event_sha256 = zero_hash, committed_revision = 7 })
check(chain == "ce75035eb224e67de9a164b6b211442c4760ae49318968c9eb0129c0301d418c", "receipt chain hashes raw previous digest plus exact tuple")
local ack = { version = 1, logical_session_id = binding.logical_session_id, worker_id = binding.worker_id,
	worker_generation = 1, launch_request_id = binding.launch_request_id, work_id = binding.work_id, event_id = good.event_id,
	seq = 1, event_sha256 = hash(bytes), committed_revision = 7, disposition = "accepted", receipt_chain_sha256 = chain }
local ack_binding = clone(binding)
ack_binding.event_id, ack_binding.seq, ack_binding.event_sha256 = good.event_id, 1, hash(bytes)
check(transport.decode_ack(encode(ack), ack_binding) ~= nil, "complete exact-byte receipt accepted by decoder only")
local changed_ack = clone(ack)
changed_ack.event_sha256 = zero_hash
value, diagnostic = transport.decode_ack(encode(changed_ack), ack_binding)
rejected(value, diagnostic, "binding_mismatch", "changed-byte ACK is not permission to retire data")
changed_ack = clone(ack)
changed_ack.disposition = "rejected"
value, diagnostic = transport.decode_ack(encode(changed_ack), ack_binding)
rejected(value, diagnostic, "invalid_schema", "negative receipt cannot masquerade as accepted ACK")
value, diagnostic = transport.decode_ack(encode(ack):sub(1, -2), ack_binding)
rejected(value, diagnostic, "invalid_schema", "partial ACK rejected")
local watermark = clone(binding)
watermark.version, watermark.type, watermark.through_seq, watermark.receipt_chain_sha256 = 1, "receipt_watermark", 1, chain
check(transport.decode_watermark(encode(watermark), binding) ~= nil, "independent watermark schema decoded")
watermark.through_seq = 0
value, diagnostic = transport.decode_watermark(encode(watermark), binding)
rejected(value, diagnostic, "invalid_schema", "published watermark must confirm a positive prefix")

local framed, frame_error = transport.frame(bytes, "report", binding)
check(framed ~= nil and frame_error == nil and #framed.chunks == 1, "small messages always framed")
local pool = transport.new_reassembler()
value, diagnostic = transport.push_chunk(pool, framed.chunks[1], binding, hash(framed.chunks[1]))
rejected(value, diagnostic, "incomplete", "chunk without complete manifest has no logical delivery")
check(transport.begin_assembly(pool, framed.manifest, binding, hash(framed.manifest)) ~= nil, "complete manifest starts reassembly")
local complete = transport.push_chunk(pool, framed.chunks[1], binding, hash(framed.chunks[1]))
check(complete.complete == true and complete.bytes == bytes and complete.sha256 == hash(bytes), "complete message retains exact original bytes")
check(pool.active == 0 and pool.bytes == 0, "completed assembly releases only in-memory buffers")
local reply_frame = transport.frame(reply_bytes, "reply", binding)
check(transport.begin_assembly(pool, reply_frame.manifest, binding, hash(reply_frame.manifest)) ~= nil, "reply manifest starts")
complete = transport.push_chunk(pool, reply_frame.chunks[1], binding, hash(reply_frame.chunks[1]))
check(complete.complete == true and complete.direction == "reply", "reply uses same complete framing path")

local split_report = report("BLOCKED", { reason = "__SPLIT__" })
local split_template = encode(split_report)
local position = assert(split_template:find("__SPLIT__", 1, true))
local prefix = split_template:sub(1, position - 1)
local split_bytes = prefix .. string.rep("x", 2047 - #prefix) .. "\195\169" .. string.rep("x", 3000) .. split_template:sub(position + #"__SPLIT__")
local split_frame = transport.frame(split_bytes, "report", binding)
check(split_frame ~= nil and #split_frame.chunks >= 3, "UTF-8 message produces multiple raw slices")
local first_chunk = runtime.json.decode(split_frame.chunks[1])
local first_raw = runtime.base64.decode(first_chunk.data_b64)
check(#first_raw == 2048 and first_raw:byte(2048) == 195, "raw slice intentionally ends halfway through Unicode character")
transport.begin_assembly(pool, split_frame.manifest, binding, hash(split_frame.manifest))
local part = transport.push_chunk(pool, split_frame.chunks[1], binding, hash(split_frame.chunks[1]))
check(part.complete == false, "partial logical message yields no report")
local repeated = transport.push_chunk(pool, split_frame.chunks[1], binding, hash(split_frame.chunks[1]))
check(repeated.code == "already_received" and pool.bytes == 2048, "exact duplicate chunk does not allocate twice")
local reencoded = split_frame.chunks[1] .. " "
value, diagnostic = transport.push_chunk(pool, reencoded, binding, hash(reencoded))
rejected(value, diagnostic, "content_conflict", "same parsed chunk with changed wire bytes conflicts")
local conflicting = runtime.json.decode(split_frame.chunks[2])
conflicting.message_sha256 = zero_hash
local conflicting_bytes = encode(conflicting)
value, diagnostic = transport.push_chunk(pool, conflicting_bytes, binding, hash(conflicting_bytes))
rejected(value, diagnostic, "content_conflict", "mixed message identity cannot join assembly")
local switched_binding = clone(binding)
switched_binding.worker_generation = 2
value, diagnostic = transport.push_chunk(pool, split_frame.chunks[2], switched_binding, hash(split_frame.chunks[2]))
rejected(value, diagnostic, "binding_mismatch", "generation cannot change during async reassembly")
local last = #split_frame.chunks
part = transport.push_chunk(pool, split_frame.chunks[last], binding, hash(split_frame.chunks[last]))
check(part.complete == false, "missing middle chunk is incomplete even with final chunk present")
for index = 2, last - 1 do complete = transport.push_chunk(pool, split_frame.chunks[index], binding, hash(split_frame.chunks[index])) end
check(complete.complete == true and complete.bytes == split_bytes, "out-of-order complete chunk set reassembles exact UTF-8 bytes")

local maximum_bytes = bytes .. string.rep(" ", 65536 - #bytes)
local maximum = transport.frame(maximum_bytes, "report", binding)
check(maximum ~= nil and #maximum.chunks == 32, "65536 original bytes fit exactly 32 chunks")
transport.begin_assembly(pool, maximum.manifest, binding, hash(maximum.manifest))
for _, wire in maximum.chunks do complete = transport.push_chunk(pool, wire, binding, hash(wire)) end
check(complete.complete == true and #complete.bytes == 65536, "maximum logical message remains complete, not truncated")
value, diagnostic = transport.frame(maximum_bytes .. " ", "report", binding)
rejected(value, diagnostic, "oversize", "65537 logical bytes refused before framing")

for _, encoded_b64 in { "YQ", "YQ==\n", "YQ--", "YR==", "====" } do
	local malformed = runtime.json.decode(framed.chunks[1])
	malformed.data_b64 = encoded_b64
	value, diagnostic = transport.decode_object(encode(malformed))
	rejected(value, diagnostic, "invalid_schema", "Base64 must be standard, padded, whitespace-free and canonical")
end
local bad_manifest = runtime.json.decode(framed.manifest)
bad_manifest.count = 2
value, diagnostic = transport.decode_object(encode(bad_manifest))
rejected(value, diagnostic, "invalid_schema", "manifest count exactly covers bytes")
value, diagnostic = transport.decode_object(framed.manifest .. string.rep(" ", 2049 - #framed.manifest))
rejected(value, diagnostic, "oversize", "manifest stricter 2048-byte limit enforced")
local padded_chunk = split_frame.chunks[1] .. string.rep(" ", 4096 - #split_frame.chunks[1])
check(transport.decode_object(padded_chunk) ~= nil, "4096-byte chunk wire boundary allowed")
value, diagnostic = transport.decode_object(padded_chunk .. " ")
rejected(value, diagnostic, "oversize", "4097-byte chunk rejected")
bad_manifest = runtime.json.decode(framed.manifest)
bad_manifest.message_sha256 = zero_hash
local bad_wire = encode(bad_manifest)
transport.begin_assembly(pool, bad_wire, binding, hash(bad_wire))
local bad_chunk = runtime.json.decode(framed.chunks[1])
bad_chunk.message_sha256 = zero_hash
bad_wire = encode(bad_chunk)
value, diagnostic = transport.push_chunk(pool, bad_wire, binding, hash(bad_wire))
rejected(value, diagnostic, "content_conflict", "whole-message digest recomputed independently of wire digest")
check(pool.bytes == 0, "rejected final chunk does not mutate partial buffer")
transport.discard_assembly(pool, binding.mailbox_handle)
do
	local invalid = report("HEARTBEAT", { state = "not-a-valid-worker-state" })
	local invalid_bytes = encode(invalid)
	local manifest = runtime.json.decode(framed.manifest)
	local chunk = runtime.json.decode(framed.chunks[1])
	manifest.message_bytes = #invalid_bytes; manifest.message_sha256 = hash(invalid_bytes); manifest.count = 1
	chunk.message_sha256 = manifest.message_sha256; chunk.data_b64 = runtime.base64.encode(invalid_bytes); chunk.count = 1
	local manifest_bytes, chunk_bytes = encode(manifest), encode(chunk)
	assert(transport.begin_assembly(pool, manifest_bytes, binding, hash(manifest_bytes)))
	value, diagnostic = transport.push_chunk(pool, chunk_bytes, binding, hash(chunk_bytes))
	check(value == nil and diagnostic.completed_bytes == invalid_bytes and diagnostic.completed_sha256 == hash(invalid_bytes),
		"fully assembled hash-verified rejected envelope exposes transport-completion evidence without accepting payload")
	check(pool.bytes == 0, "completed invalid envelope does not mutate partial assembly")
	transport.discard_assembly(pool, binding.mailbox_handle)
end
for index = 1, 4 do
	local other = clone(binding)
	other.mailbox_handle = "mailbox_capacity_" .. tostring(index)
	local object = transport.frame(encode(report("READY", { state = "idle" }, nil, other)), "report", other)
	check(transport.begin_assembly(pool, object.manifest, other, hash(object.manifest)) ~= nil, "bounded host assembly slot " .. tostring(index))
end
value, diagnostic = transport.begin_assembly(pool, framed.manifest, binding, hash(framed.manifest))
rejected(value, diagnostic, "full", "fifth concurrent assembly refused without dropping predecessors")
check(pool.active == 4, "host assembly limit does not grow on rejection")

local selected = { stream = "report", slot = 1, part = "manifest" }
local next_selector = { stream = "report", slot = 1, part = "chunk", index = 1 }
local page_bytes = transport.project_page(framed.manifest, selected, next_selector)
check(page_bytes ~= nil and #page_bytes <= 8192, "single-object bridge projection bounded after Base64 nesting")
local page = transport.decode_page(page_bytes, selected)
check(page.bytes == framed.manifest and page.complete == true and page.next_selector.index == 1, "complete page recovers exact object bytes and contiguous selector")
local boundary_page = page_bytes .. string.rep(" ", 8192 - #page_bytes)
check(transport.decode_page(boundary_page, selected) ~= nil, "8192-byte complete bridge page allowed")
value, diagnostic = transport.decode_page(boundary_page .. " ", selected)
rejected(value, diagnostic, "oversize", "outer bridge 8193 bytes refused")
local bad_page = runtime.json.decode(page_bytes)
bad_page.complete = false
value, diagnostic = transport.decode_page(encode(bad_page), selected)
rejected(value, diagnostic, "invalid_schema", "clipped/incomplete native surface cannot become complete data")
bad_page = runtime.json.decode(page_bytes)
bad_page.next_selector.slot = 2
value, diagnostic = transport.decode_page(encode(bad_page), selected)
rejected(value, diagnostic, "binding_mismatch", "continuation cannot leave immutable message")
bad_page = runtime.json.decode(page_bytes)
bad_page.object_sha256 = zero_hash
value, diagnostic = transport.decode_page(encode(bad_page), selected)
rejected(value, diagnostic, "content_conflict", "outer per-object exact-byte hash verified")
bad_page = runtime.json.decode(page_bytes)
bad_page.object_bytes += 1
value, diagnostic = transport.decode_page(encode(bad_page), selected)
rejected(value, diagnostic, "incomplete", "declared byte count catches truncated page")
local chunk_selector = { stream = "report", slot = 1, part = "chunk", index = 1 }
check(transport.project_page(padded_chunk, chunk_selector) ~= nil, "maximum-size chunk still fits nested bridge projection")
local controlled = clone(binding); controlled.capabilities = { "report-files-v1", "coordinator-control-v1" }
for _, kind in { "HEARTBEAT", "CHECKPOINT" } do
	local payload = clone(if kind == "HEARTBEAT" then fixtures[4][2] else fixtures[8][2]); payload.request_id = "progress-request"
	check(transport.decode_report(encode(report(kind, payload)), binding) ~= nil, kind .. " closes progress-request correlation")
	payload.request_id = false
	check(transport.decode_report(encode(report(kind, payload)), binding) == nil, kind .. " rejects non-ID correlation")
end
for _, kind in { "dispatch", "report", "review", "rollover", "landing" } do
	local p = { owner_id = "owner", owner_generation = 1, activation_token = zero_hash, proposal_id = "proposal",
		kind = kind, work_id = "work_1", project_id = "project" }
	if kind == "dispatch" then p.record_id = "configured native"; p.record_revision = 0; p.prompt = "Explicit task"
	elseif kind ~= "report" then p.checkpoint_id = "checkpoint" end
	check(transport.decode_report(encode(report("COORDINATOR_PROPOSAL", p)), controlled) ~= nil, "typed proposal " .. kind .. " parses under provisioned capability")
	check(transport.decode_report(encode(report("COORDINATOR_PROPOSAL", p)), binding) == nil, "proposal cannot grant its own coordinator capability")
	p.command = "merge"
	check(transport.decode_report(encode(report("COORDINATOR_PROPOSAL", p)), controlled) == nil, "proposal forbids executable command data")
	p.command = nil; p.activation_token = "wrong"
	check(transport.decode_report(encode(report("COORDINATOR_PROPOSAL", p)), controlled) == nil, "proposal requires exact token shape")
end
-- Rollover checkpoint verification is worker-attested completeness/freshness/outcome, never execution.
do
	local function checkpoint(checks)
		return { kind = "CHECKPOINT", payload = { checkpoint_id = "cp", task_ref = "task", project_id = "project", worktree_ref = "tree", artifact_revision = "rev-2",
			completed = { "done" }, remaining = { "next" }, holds = {}, checks = checks, request_id = "rollover-request" } }
	end
	local verified = transport.verify_checkpoint(checkpoint({ { check_id = "unit", artifact_revision = "rev-2", outcome = "passed", evidence_ref = "unit" } }), "rollover-request")
	check(verified ~= nil and verified.attestation == "worker-attested" and verified.artifact_revision == "rev-2", "fresh passed outcome verifies as worker-attested")
	local value, diagnostic = transport.verify_checkpoint(checkpoint({ { check_id = "unit", artifact_revision = "rev-2", outcome = "passed", evidence_ref = "unit" },
		{ check_id = "project-artifact", artifact_revision = "rev-2", outcome = "failed", evidence_ref = "artifact" } }), "rollover-request")
	rejected(value, diagnostic, "verification_failed", "a failed required check blocks rollover even beside passed checks")
	value, diagnostic = transport.verify_checkpoint(checkpoint({ { check_id = "unit", artifact_revision = "rev-1", outcome = "passed", evidence_ref = "unit" } }), "rollover-request")
	rejected(value, diagnostic, "verification_stale", "check for another artifact revision blocks rollover")
	value, diagnostic = transport.verify_checkpoint(checkpoint({ { check_id = "unit", artifact_revision = "rev-2", outcome = "not_run", evidence_ref = "unit" } }), "rollover-request")
	rejected(value, diagnostic, "verification_missing", "not_run is absent evidence")
	value, diagnostic = transport.verify_checkpoint(checkpoint({}), "rollover-request")
	rejected(value, diagnostic, "verification_missing", "summary without verification outcomes blocks")
	value, diagnostic = transport.verify_checkpoint(checkpoint({ { check_id = "unit", artifact_revision = "rev-2", outcome = "passed", evidence_ref = "unit" } }), "other-request")
	rejected(value, diagnostic, "checkpoint_stale", "checkpoint answering another request cannot hand over")
	value, diagnostic = transport.verify_checkpoint({ kind = "HEARTBEAT", payload = { state = "idle" } }, "rollover-request")
	rejected(value, diagnostic, "checkpoint_missing", "non-checkpoint report cannot hand over")
end
return "PASS " .. tostring(checks) .. " report transport checks"
