-- Pure schema-2 review. Callers retain raw bytes/source bindings and revalidate at
-- confirmation; authority alone resolves existing IDs and commits the import.
local Config = require("./config")
local Review = {}

type Field = { label: string, value: string }
type Row = { id: string, label: string, fields: { Field } }

local RECORD_FIELDS = {
	{ "id", "Record ID" }, { "provider", "Provider" }, { "account_label", "Account" },
	{ "provider_family", "Underlying AI provider" }, { "backend", "Backend" }, { "enabled", "Enabled" },
	{ "placement", "Placement" }, { "command", "Command" }, { "arguments", "Arguments" },
	{ "cwd", "Working directory" }, { "prompt", "Prompt" }, { "host", "SSH host" },
	{ "user", "SSH user" }, { "key_path", "SSH key path" },
	{ "review_required", "Review required" }, { "review_reason", "Review reason" },
	{ "fresh_executable", "Fresh executable" }, { "fresh_arguments", "Fresh arguments" },
	{ "fresh_native_default", "Fresh native default" }, { "task_argument_index", "Task argument index" },
	{ "host_shell", "Host shell" }, { "target_os", "Target OS" }, { "target_shell", "Target shell" },
	{ "argv_contract", "Argument contract" }, { "model", "Model" }, { "profile", "Profile" },
	{ "variant_id", "Variant ID" }, { "capacity_binding", "Capacity binding" },
	{ "capacity_limit", "Capacity limit" }, { "selector_evidence", "Selector evidence" },
}
local MAILBOX_FIELDS = {
	{ "permitted_root", "Mailbox permitted root" }, { "helper_path", "Mailbox helper path" },
	{ "producer_helper_path", "Mailbox producer helper path" }, { "worker_identity", "Mailbox worker identity" },
	{ "evidence_ref", "Mailbox evidence reference" }, { "verified", "Mailbox verified" },
	{ "wake", "Mailbox wake route" },
}

local function field(fields: { Field }, label: string, value: any)
	if value ~= nil then
		table.insert(fields, { label = label, value = if value == "" then "(empty string)" else tostring(value) })
	end
end

local function list(fields: { Field }, label: string, values: { string })
	field(fields, label, if #values == 0 then "None" else tostring(#values) .. " entries")
	for index, value in ipairs(values) do field(fields, label .. " [" .. tostring(index) .. "]", value) end
end

local function row(record: any): Row
	local fields: { Field } = {}
	for _, spec in ipairs(RECORD_FIELDS) do
		local value = record[spec[1]]
		if spec[1] == "arguments" or spec[1] == "fresh_arguments" then
			if value ~= nil then list(fields, spec[2], value) end
		else
			field(fields, spec[2], value)
		end
	end
	local mailbox = record.mailbox
	if mailbox ~= nil then
		field(fields, "Mailbox", "Configured")
		for _, spec in ipairs(MAILBOX_FIELDS) do field(fields, spec[2], mailbox[spec[1]]) end
		if mailbox.producer ~= nil then
			field(fields, "Mailbox producer", "Configured")
			for _, name in ipairs({ "read", "write", "hash", "journal", "poll" }) do
				field(fields, "Mailbox producer " .. name, mailbox.producer[name])
			end
		end
		if mailbox.capabilities ~= nil then list(fields, "Mailbox capabilities", mailbox.capabilities) end
	end
	return { id = record.id, label = record.account_label, fields = fields }
end

local function run_id(value: any): boolean
	return type(value) == "string" and #value > 0 and #value <= 256
		and string.find(value, "%S") ~= nil and string.find(value, "%c") == nil
end

function Review.prepare(decoded_result: any, expected_run_id: any): (any?, string?)
	if not run_id(expected_run_id) then return nil, "A valid expected setup run ID is required" end
	if type(decoded_result) ~= "table" then return nil, "Setup result must be a schema-2 object" end
	for key in pairs(decoded_result) do
		if key ~= "schema" and key ~= "setup_run_id" and key ~= "confirmed" and key ~= "agents" then
			return nil, "Setup result contains an unsupported field"
		end
	end
	if decoded_result.schema ~= 2 then return nil, "Setup result must use schema 2" end
	if not run_id(decoded_result.setup_run_id) or decoded_result.setup_run_id ~= expected_run_id then
		return nil, "Setup result does not match the expected setup run"
	end
	if decoded_result.confirmed ~= true then return nil, "Setup result requires confirmed:true before review" end
	local records, reason = Config.validate_records(decoded_result.agents)
	if records == nil then return nil, reason end
	local rows: { Row } = {}
	for index, record in ipairs(records) do rows[index] = row(record) end
	return { setup_run_id = decoded_result.setup_run_id, records = records, rows = rows }, nil
end

-- The helper's approval names the exact roster and its checks, so SPAWN saves and
-- prepares automatically after a bound submission. This pure plan only decides
-- WHAT the automatic flow may do; it never approves a paid check the roster does
-- not declare, and optional provider readiness exercises are never part of it.
function Review.automatic_plan(records: any): any
	local enabled, native = 0, {}
	local blocked: string? = nil
	for _, record in ipairs(if type(records) == "table" then records else {}) do
		if record.enabled then
			enabled += 1
			if record.review_required or record.backend == "ssh-command" then
				blocked = "An agent needs its launch settings or execution route reviewed before it can be prepared"
			end
			if record.backend == "native-agent" then
				table.insert(native, tostring(record.provider) .. " — " .. tostring(record.account_label)
					.. " (model: " .. tostring(record.model or "saved CLI settings/default") .. ")")
			end
		end
	end
	if enabled == 0 then return { action = "save_only", enabled = 0, native = {}, reason = "No enabled agents to prepare" } end
	if blocked ~= nil then return { action = "save_only", enabled = enabled, native = native, reason = blocked } end
	return { action = "prepare", enabled = enabled, native = native, reason = nil }
end

return Review
