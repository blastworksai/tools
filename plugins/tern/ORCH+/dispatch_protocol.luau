--!strict
-- Shared window/host contracts. Loading the UI must not compile the workflow reducer.
local codec = require("./wire/codec")
local M = {}
M.POLICY_BYTES = 49152 -- Aggregate canonical JSON policy bound, including escaped text.
M.NATIVE_COMMAND_BYTES = 65536 -- Existing native setup-event budget; SPAWN's bridge stays 8192 bytes.
M.SOURCE_INPUT_BYTES = 2048
M.MANAGED_GENERATION_BUDGET = 16 -- Shared SPAWN mailbox allocation domain, not a logical-task or per-account limit.
M.DESKTOP_BOARD_PATH_BYTES = 4096
M.NATIVE_BOARD_ID_BYTES = 6 * M.DESKTOP_BOARD_PATH_BYTES + 128 -- Opaque native JSON identity, including escaped full path and bounded model/row framing.

-- No native or mailbox-file effect; SPAWN only records these operations' own outcome.
M.READ_ONLY_OPS = { catalog = true, mailbox_read = true }
-- These answers are consumed by the host, not delivered as worker owner_decision messages.
M.HOST_GATES = { quota_fallback = true, loop_cap = true, stale_claim = true, shared_checkout = true,
	file_overlap = true, scope = true, legacy_grant_outstanding = true, reviewer_unavailable = true,
	family_unknown = true, intake = true, label_unknown = true }


-- One immutable observation identity per exact envelope, including its authority fence.
function M.result_request_id(grant_id: string, window_epoch: string, envelope: any): string
	return "result-" .. codec.sha256(codec.dispatch_source_bytes({
		grant_id = grant_id, window_epoch = window_epoch, authority_namespace = envelope.authority_namespace,
		expected_revision = envelope.expected_revision, response_sha256 = codec.sha256(envelope.response_bytes),
	}))
end

function M.decode_response(bytes: any, request: any): (any?, any?)
	if type(request) ~= "table" or request.setup_origin ~= nil then
		return nil, { ok = false, code = "invalid_schema", message = "Controller responses require the original controller request." }
	end
	return codec.decode_dispatch_response(bytes, request)
end

function M.decode_setup_response(bytes: any, request: any): (any?, any?)
	if type(request) ~= "table" or request.op ~= "catalog" or request.setup_origin == nil then
		return nil, { ok = false, code = "invalid_schema", message = "Setup responses require the original pre-controller catalog request." }
	end
	return codec.decode_dispatch_response(bytes, request)
end

return M
