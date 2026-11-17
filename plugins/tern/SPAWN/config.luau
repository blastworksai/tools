-- Pure configuration boundary. The caller owns backup and durable replacement:
-- when changed is true, preserve the original store before committing result.store.
-- No discovery, process launch, credential access or persistence belongs here.
local Config = {}
local MAX_RECORDS = 32
local MAX_TEXT = 32000
local MAX_ARGUMENTS = 256
local REVIEW_COMMAND = "Review this account's launch command"

local FIELDS = {
	id = true, provider = true, provider_family = true, account_label = true, backend = true,
	enabled = true, placement = true,
	command = true, arguments = true, cwd = true, prompt = true,
	host = true, user = true, key_path = true, review_required = true, review_reason = true,
	fresh_executable = true, fresh_arguments = true, fresh_native_default = true, task_argument_index = true,
	host_shell = true, target_os = true, target_shell = true, mailbox = true,
	model = true, profile = true, variant_id = true, capacity_binding = true, capacity_limit = true,
	selector_evidence = true,
	argv_contract = true,
}
local LEGACY_FIELDS = {
	acp_capable = true, acp_enabled = true, acp_available = true,
	include_cli_twin = true, cli_twin = true, cli_command = true, cli_arguments = true,
}
-- Retired fields: accepted from stored records, imports and setup results, then
-- dropped, so older rosters and setup prompts keep working and nothing re-emits them.
local RETIRED_FIELDS = { duplicate_policy = true, include_all = true }

local function nonblank(value: string): boolean
	return string.find(value, "%S") ~= nil
end

local function text(value: any, limit: number): boolean
	return type(value) == "string" and #value <= limit and string.find(value, "%z") == nil
end

-- Declaration describes the underlying provider, never the running account/model.
local PROVIDER_FAMILIES = {
	claude = "anthropic", anthropic = "anthropic", codex = "openai", openai = "openai",
	kimi = "moonshot", grok = "xai", agy = "google", antigravity = "google", muse = "meta",
}
function Config.provider_family(provider: any, declaration: any): (string?, string?)
	local known = if type(provider) == "string" then PROVIDER_FAMILIES[string.lower(provider)] else nil
	if declaration == nil or declaration == "" then return known, nil end
	if not text(declaration, 96) or not nonblank(declaration) or declaration:find("%c") or utf8.len(declaration)==nil then
		return nil, "Underlying provider must be nonblank text of at most 96 bytes without control characters"
	end
	local normalized = string.lower((declaration:gsub("^%s+", ""):gsub("%s+$", "")))
	normalized = PROVIDER_FAMILIES[normalized] or normalized
	if type(provider)=="string" and string.lower(provider)=="omp" and normalized=="omp" then return nil,"OMP requires its underlying AI provider, not the wrapper name" end
	return normalized, nil
end

local function array_length(value: any, limit: number): (number?, string?)
	if type(value) ~= "table" then return nil, "Expected an array" end
	local count = 0
	local highest = 0
	for key in pairs(value) do
		if type(key) ~= "number" or key < 1 or key % 1 ~= 0 or key > limit then
			return nil, "Expected a dense array with at most " .. tostring(limit) .. " entries"
		end
		count += 1
		highest = math.max(highest, key)
	end
	if highest ~= count then return nil, "Array entries must not have gaps" end
	return count, nil
end

-- This is the existing host editor's shell-like syntax, not an execution shell.
-- Single-quoted backslashes are literal; empty quoted arguments are retained.
function Config.parse_arguments(value: any): ({ string }?, string?)
	if not text(value, MAX_TEXT) then return nil, "Argument text is invalid or too long" end
	local result: { string } = {}
	local token = ""
	local quote: string? = nil
	local escaped = false
	local have_token = false
	for index = 1, #value do
		local char = string.sub(value, index, index)
		if escaped then
			token ..= char
			escaped = false
			have_token = true
		elseif char == "\\" and quote ~= "'" then
			escaped = true
			have_token = true
		elseif quote ~= nil then
			if char == quote then quote = nil else token ..= char end
			have_token = true
		elseif char == "'" or char == '"' then
			quote = char
			have_token = true
		elseif string.match(char, "%s") ~= nil then
			if have_token then
				table.insert(result, token)
				if #result > MAX_ARGUMENTS then return nil, "Too many arguments" end
				token, have_token = "", false
			end
		else
			token ..= char
			have_token = true
		end
	end
	if escaped then return nil, "Arguments end with an escape" end
	if quote ~= nil then return nil, "Arguments contain an unterminated quote" end
	if have_token then table.insert(result, token) end
	if #result > MAX_ARGUMENTS then return nil, "Too many arguments" end
	return result, nil
end

function Config.render_arguments(arguments: { string }): string
	local result: { string } = {}
	for index, value in ipairs(arguments) do
		if value ~= "" and string.match(value, "^[A-Za-z0-9_./:@%%+=,-]+$") ~= nil then
			result[index] = value
		else
			local escaped = string.gsub(value, '[\\"$`]', function(char) return "\\" .. char end)
			result[index] = '"' .. escaped .. '"'
		end
	end
	return table.concat(result, " ")
end

local function arguments(value: any, legacy: boolean): ({ string }?, string?)
	if value == nil then return {}, nil end
	if legacy and type(value) == "string" then return Config.parse_arguments(value) end
	local length, err = array_length(value, MAX_ARGUMENTS)
	if length == nil then return nil, err end
	local result: { string } = {}
	for index = 1, length do
		if not text(value[index], MAX_TEXT) then return nil, "Arguments must be bounded strings without null bytes" end
		result[index] = value[index]
	end
	return result, nil
end

local function basename(value: string): string
	local normalized = string.gsub(value, "\\", "/")
	local name = string.lower(string.match(normalized, "([^/]+)$") or normalized)
	return (string.gsub(string.gsub(string.gsub(name, "%.exe$", ""), "%.cmd$", ""), "%.bat$", ""))
end

local SERVERS = {
	["claude-agent-acp"] = true, ["claude-code-acp"] = true,
	["codex-acp"] = true, ["gemini-acp"] = true,
}
local WRAPPERS = {
	sudo = true, su = true, env = true, ssh = true, doas = true,
	bash = true, sh = true, zsh = true, fish = true, cmd = true,
	powershell = true, pwsh = true, node = true, npx = true,
	bun = true, uv = true, uvx = true, python = true, python3 = true,
}

-- Inspect command positions, never arbitrary argument values. Wrapped commands
-- with server-shaped tokens are ambiguous: preserve them for explicit review.
local function invocation(command: string?, argv: { string }): (string, { string }?)
	if command == nil or not nonblank(command) then return "missing", nil end
	local words = Config.parse_arguments(command)
	if words == nil or #words == 0 or words[1] == "" then return "ambiguous", nil end
	local program = basename(words[1])
	if SERVERS[program] then return "server", words end
	local first = if #words > 1 then words[2] else argv[1]
	if (program == "omp" or program == "kimi") and first == "acp" then
		return if program == "omp" then "omp-server" else "server", words
	end
	if program == "gemini" and first == "--experimental-acp" then return "server", words end
	if WRAPPERS[program] then
		for _, sequence in ipairs({ words, argv }) do
			for _, word in ipairs(sequence) do
				if SERVERS[basename(word)] or word == "acp" or word == "--acp" or word == "--experimental-acp" then
					return "ambiguous", words
				end
				-- Shell strings remain opaque, including operators adjoining a
				-- program name. Lexical hints only block; they never authorize a
				-- rewrite or treat a nested shell expression as understood.
				local normalized = string.gsub(word, "\\", "/")
				for part in string.gmatch(normalized, "[%w_./:@%-]+") do
					if SERVERS[basename(part)] or part == "acp" or part == "--acp" or part == "--experimental-acp" then
						return "ambiguous", words
					end
				end
			end
		end
	elseif program == "omp" or program == "kimi" then
		-- A leading option can consume the next token. Without the provider's
		-- complete option grammar, never guess whether a later token is a mode.
		if first ~= nil and string.sub(first, 1, 1) == "-" then
			for _, sequence in ipairs({ words, argv }) do
				for _, word in ipairs(sequence) do
					if word == "acp" or word == "--acp" then return "ambiguous", words end
				end
			end
		end
	end
	return "ordinary", words
end

local function same_arguments(left: { string }, right: { string }): boolean
	if #left ~= #right then return false end
	for index, value in ipairs(left) do
		if value ~= right[index] then return false end
	end
	return true
end

local function mark_review(record: any, reason: string)
	record.review_required = true
	-- Existing custom review notes survive another load.
	if record.review_reason == nil then record.review_reason = reason end
end

-- Managed declarations are configuration, not evidence collected by SPAWN.
-- Absence stays absent: neither migration nor normalization grants a capability.
local function managed_fields(source: any, record: any): string?
	for _, field in ipairs({ "fresh_executable", "host_shell", "target_shell", "model", "profile", "variant_id", "capacity_binding", "selector_evidence" }) do
		local value = source[field]
		if value ~= nil then
			if not text(value, 4096) or not nonblank(value) then return field .. " must be nonempty bounded text" end
			record[field] = value
		end
	end
	if source.target_os ~= nil then
		if source.target_os ~= "linux" and source.target_os ~= "macos" and source.target_os ~= "windows" then return "Unsupported target OS" end
		record.target_os = source.target_os
	end
	if source.argv_contract ~= nil then
		if source.argv_contract ~= "windows-crt" then return "Unsupported argv contract" end
		record.argv_contract = source.argv_contract
	end
	if source.fresh_native_default ~= nil then
		if type(source.fresh_native_default) ~= "boolean" then return "fresh_native_default must be true or false" end
		if source.fresh_native_default and (record.backend ~= "native-agent" or string.lower(record.provider) ~= "omp") then return "Native fresh default requires Native OMP" end
		record.fresh_native_default = source.fresh_native_default
	end
	if (source.fresh_executable == nil) ~= (source.fresh_arguments == nil) then return "Fresh executable and arguments must be configured together" end
	if source.fresh_arguments ~= nil then
		local argv, err = arguments(source.fresh_arguments, false)
		if argv == nil then return err end
		if source.fresh_native_default then return "Choose one explicit fresh launch contract" end
		record.fresh_arguments = argv
	end
	for _, field in ipairs({ "task_argument_index", "capacity_limit" }) do
		local value = source[field]
		local maximum = if field == "task_argument_index" then MAX_ARGUMENTS + 1 else 9007199254740991
		if value ~= nil then
			if type(value) ~= "number" or value < 1 or value > maximum or value % 1 ~= 0 then return field .. " must be a positive bounded integer" end
			record[field] = value
		end
	end
	if source.mailbox ~= nil then
		local value = source.mailbox
		if type(value) ~= "table" then return "Mailbox must be an object" end
		local fields = { permitted_root = true, helper_path = true, producer_helper_path = true, worker_identity = true, producer = true, capabilities = true, evidence_ref = true, verified = true, wake = true }
		for field in pairs(value) do if not fields[field] then return "Unsupported mailbox field" end end
		local mailbox = {}
		for _, field in ipairs({ "permitted_root", "helper_path", "producer_helper_path", "worker_identity", "evidence_ref" }) do
			if value[field] ~= nil then
				if not text(value[field], 4096) or not nonblank(value[field]) then return "Mailbox " .. field .. " must be nonempty bounded text" end
				mailbox[field] = value[field]
			end
		end
		for _, field in ipairs({ "permitted_root", "helper_path", "producer_helper_path" }) do
			local path = mailbox[field]
			if path ~= nil and string.sub(path, 1, 1) ~= "/" and string.match(path, "^[A-Za-z]:[\\/]") == nil and string.sub(path, 1, 2) ~= "\\\\" then return "Mailbox paths must be absolute" end
		end
		if value.verified ~= nil then
			if type(value.verified) ~= "boolean" then return "Mailbox verified must be true or false" end
			mailbox.verified = value.verified
		end
		if value.wake ~= nil then
			if value.wake ~= "native-ask-v1" and value.wake ~= "worker-poll-v1" then return "Unsupported mailbox wake route" end
			mailbox.wake = value.wake
		end
		if value.producer ~= nil then
			if type(value.producer) ~= "table" then return "Mailbox producer must be an object" end
			mailbox.producer = {}
			local allowed = { read = true, write = true, hash = true, journal = true, poll = true }
			for field, claim in pairs(value.producer) do
				if not allowed[field] or type(claim) ~= "boolean" then return "Unsupported producer capability" end
				mailbox.producer[field] = claim
			end
		end
		if value.capabilities ~= nil then
			local length, err = array_length(value.capabilities, 8)
			if length == nil then return err end
			local allowed = { ["report-files-v1"] = true, ["native-ask-v1"] = true, ["worker-poll-v1"] = true, ["argv-v1"] = true, ["coordinator-control-v1"] = true, ["check-runner-v1"] = true, ["release-manager-v1"] = true, ["project-start-v1"] = true }
			local seen = {}
			mailbox.capabilities = {}
			for index = 1, length do
				local capability = value.capabilities[index]
				if not allowed[capability] or seen[capability] then return "Unsupported or duplicate mailbox capability" end
				seen[capability] = true
				mailbox.capabilities[index] = capability
			end
		end
		record.mailbox = mailbox
	end
	return nil
end

local function normalize(source: any, legacy: boolean): (any?, string?)
	if type(source) ~= "table" then return nil, "Record must be an object" end
	for field in pairs(source) do
		if not FIELDS[field] and not RETIRED_FIELDS[field] and not (legacy and LEGACY_FIELDS[field]) then
			return nil, "Record contains an unsupported field: " .. string.sub(string.gsub(tostring(field), "%c", "?"), 1, 40)
		end
	end
	if not text(source.id, 96) or not nonblank(source.id) or string.find(source.id, "%c") ~= nil then
		return nil, "Record ID must be nonempty text of at most 96 bytes without control characters"
	end
	if not text(source.provider, 256) or not nonblank(source.provider) then return nil, "Provider is required" end
	local backend = source.backend
	if backend ~= "native-agent" and backend ~= "local-terminal" and backend ~= "ssh-command" then
		return nil, "Choose Native OMP, Terminal, or SSH terminal"
	end
	local record: any = { id = source.id, provider = source.provider, backend = backend }
	if source.provider_family~=nil and source.provider_family~="" then
		local family, family_error = Config.provider_family(source.provider, source.provider_family)
		if family_error then return nil, family_error end
		record.provider_family = family
	end
	for _, field in ipairs({ "account_label", "command", "cwd", "prompt", "host", "user", "key_path", "placement", "review_reason" }) do
		local value = source[field]
		if value ~= nil then
			if not text(value, MAX_TEXT) then return nil, field .. " must be bounded text without null bytes" end
			if value ~= "" then record[field] = value end
		end
	end
	if record.account_label == nil then record.account_label = source.provider end
	for _, field in ipairs({ "enabled", "review_required" }) do
		if source[field] ~= nil and type(source[field]) ~= "boolean" then return nil, field .. " must be true or false" end
	end
	record.enabled = if source.enabled == nil then true else source.enabled
	if source.review_required == true then record.review_required = true end
	if record.review_reason ~= nil and not record.review_required then return nil, "A review reason requires a blocked record" end
	if record.review_required and (record.review_reason == nil or not nonblank(record.review_reason)) then
		record.review_reason = REVIEW_COMMAND
	end
	if record.placement ~= nil and record.placement ~= "tab" and record.placement ~= "split" and record.placement ~= "replace_if_alone" then
		return nil, "Placement must be tab, split, or replace_if_alone"
	end
	record.placement = record.placement or "tab"
	local argv, err = arguments(source.arguments, legacy)
	if argv == nil then return nil, err end
	record.arguments = argv
	-- A program named like an option (`-a`) would be read as an option by the launch wrapper's exec.
	if not legacy and record.command ~= nil then
		local words = Config.parse_arguments(record.command)
		if words ~= nil and words[1] ~= nil then
			local target = words[1]
			if basename(target) == "sudo" then
				local rest = {}
				for index = 2, #words do table.insert(rest, words[index]) end
				for _, argument in ipairs(argv) do table.insert(rest, argument) end
				for index, argument in ipairs(rest) do
					if argument == "--" then target = rest[index + 1] or ""; break end
				end
			end
			if target:sub(1, 1) == "-" then return nil, "The program name must not start with -" end
		end
	end
	local managed_error = managed_fields(source, record)
	if managed_error ~= nil then return nil, managed_error end

	local native_omp = backend == "native-agent" and string.lower(source.provider) == "omp"
	if legacy then
		for _, field in ipairs({ "acp_capable", "acp_enabled", "acp_available", "include_cli_twin", "cli_twin" }) do
			if source[field] ~= nil and type(source[field]) ~= "boolean" then return nil, "Invalid saved launch option" end
		end
		if source.cli_command ~= nil and not text(source.cli_command, MAX_TEXT) then return nil, "Invalid saved alternate command" end
		local alternate_args, alternate_error = arguments(source.cli_arguments, true)
		if alternate_args == nil then return nil, alternate_error end
		local alternate = if type(source.cli_command) == "string" and nonblank(source.cli_command) then source.cli_command else nil
		local kind, words = invocation(record.command, argv)
		if backend == "native-agent" and not native_omp then
			record.backend = "local-terminal"
			local alternate_kind = invocation(alternate, alternate_args)
			if alternate ~= nil and alternate_kind == "ordinary" and (kind == "server" or kind == "omp-server" or kind == "missing") then
				-- Keep the explicit pair together, including an empty argument list.
				record.command, record.arguments = alternate, alternate_args
			elseif kind == "missing" and alternate ~= nil then
				record.command, record.arguments = alternate, alternate_args
				mark_review(record, REVIEW_COMMAND)
			elseif alternate ~= nil and (alternate ~= record.command or not same_arguments(argv, alternate_args)) then
				mark_review(record, REVIEW_COMMAND)
			elseif kind ~= "ordinary" then
				mark_review(record, REVIEW_COMMAND)
			end
		elseif native_omp and kind == "omp-server" and words ~= nil then
			-- Only the immediate subcommand of a direct OMP executable is proven.
			-- Preserve all other tokens, including later arguments named the same.
			if #words > 1 then
				table.remove(words, 2)
				record.command = Config.render_arguments(words)
			else
				table.remove(record.arguments, 1)
			end
		elseif kind ~= "ordinary" then
			mark_review(record, REVIEW_COMMAND)
		end
	end

	local kind = invocation(record.command, record.arguments)
	if kind ~= "ordinary" then
		if legacy then mark_review(record, REVIEW_COMMAND)
		elseif not record.review_required then return nil, REVIEW_COMMAND end
	end
	if record.backend == "ssh-command" and (record.host == nil or not nonblank(record.host)) then
		if legacy then mark_review(record, "Review this account's SSH destination")
		elseif not record.review_required then return nil, "SSH terminal requires a destination" end
	end
	return record, nil
end

function Config.validate_record(value: any): (any?, string?)
	return normalize(value, false)
end

local function normalize_records(value: any, legacy: boolean): ({ any }?, string?)
	local length, err = array_length(value, MAX_RECORDS)
	if length == nil then return nil, err end
	local records = {}
	local seen = {}
	for index = 1, length do
		local record, record_error = normalize(value[index], legacy)
		if record == nil then return nil, "Record " .. tostring(index) .. ": " .. tostring(record_error) end
		if seen[record.id] then return nil, "Duplicate record ID: " .. record.id end
		seen[record.id] = true
		records[index] = record
	end
	return records, nil
end

function Config.validate_records(value: any): ({ any }?, string?)
	return normalize_records(value, false)
end

local function shallow_copy(value: any): any
	local copy = {}
	for key, item in pairs(value) do copy[key] = item end
	return copy
end

local function equal(left: any, right: any): boolean
	if type(left) ~= type(right) then return false end
	if type(left) ~= "table" then return left == right end
	for key, value in pairs(left) do
		if not equal(value, right[key]) then return false end
	end
	for key in pairs(right) do
		if left[key] == nil then return false end
	end
	return true
end

-- Only the active bucket is migrated. Other buckets are retained byte-for-byte
-- as values; callers must not mutate those shared tables. Unknown schemas anywhere
-- refuse replacement, so opening an older client cannot downgrade another host.
function Config.migrate(saved: any, host_key: any): (any?, string?)
	if not text(host_key, 1024) or not nonblank(host_key) then return nil, "Execution host identity is required" end
	local store: any
	local bucket: any
	local legacy = false
	local fresh = saved == nil
	if fresh then
		store = { schema = 2, hosts = {} }
	elseif type(saved) ~= "table" then
		return nil, "Saved configuration is invalid; the original has not been changed"
	elseif saved.schema == 1 then
		if saved.hosts ~= nil then return nil, "Legacy configuration has conflicting host data" end
		store = shallow_copy(saved)
		store.schema, store.agents = 2, nil
		store.hosts = {}
		bucket = saved
		legacy = true
	elseif saved.schema == 2 then
		if type(saved.hosts) ~= "table" then return nil, "Saved host configuration is invalid" end
		for key, other in pairs(saved.hosts) do
			if not text(key, 1024) or not nonblank(key) or type(other) ~= "table" then return nil, "Saved host bucket is invalid" end
			if other.schema ~= 1 and other.schema ~= 2 then
				return nil, "Unsupported saved host schema; preserve the original and use a compatible SPAWN version"
			end
			local _, bucket_error = array_length(other.agents, MAX_RECORDS)
			if bucket_error ~= nil then return nil, "Saved host bucket: " .. bucket_error end
		end
		store = shallow_copy(saved)
		store.hosts = shallow_copy(saved.hosts)
		bucket = saved.hosts[host_key]
		legacy = bucket ~= nil and bucket.schema == 1
	else
		return nil, "Unsupported saved configuration schema; preserve the original and use a compatible SPAWN version"
	end
	local records, err = normalize_records(if bucket == nil then {} else bucket.agents, legacy)
	if records == nil then return nil, err end
	local duplicated_flat = not fresh and saved.schema == 2 and saved.agents ~= nil
	if duplicated_flat then
		local flat_records, flat_error = normalize_records(saved.agents, true)
		if flat_records == nil then return nil, "Saved flat roster: " .. tostring(flat_error) end
		if not equal(flat_records, records) then
			return nil, "Saved flat and host-scoped rosters conflict; preserve both and explicitly select the intended records before importing"
		end
		-- Identical canonical copies need no account selection. In particular,
		-- historical empty objects and arrays both represent an empty argument list.
		store.agents = nil
	end
	local next_bucket = if bucket == nil then {} else shallow_copy(bucket)
	next_bucket.schema, next_bucket.agents = 2, records
	store.hosts[host_key] = next_bucket
	local changed = fresh or legacy or duplicated_flat or bucket == nil or not equal(bucket, next_bucket)
	local review_required = false
	for _, record in ipairs(records) do
		if record.review_required then review_required = true end
	end
	local notices = {}
	if legacy or duplicated_flat then table.insert(notices, "SPAWN now keeps one launch configuration per account.") end
	if review_required then table.insert(notices, "Some accounts need settings review before they can launch.") end
	return {
		store = store, records = records, notices = notices,
		review_required = review_required, changed = changed,
	}, nil
end
-- Native JSON omits null object members. Like WORK's raw configuration door,
-- reject unquoted null rather than allowing an unknown field to disappear.
function Config.decode_setup_json(bytes: any): (any?, string?)
	if type(bytes)~="string" or #bytes==0 or #bytes>120000 or bytes:find("%z") or utf8.len(bytes)==nil then
		return nil,"Setup JSON must be complete UTF-8 within 120000 bytes"
	end
	local ok,value=pcall(tern.json.decode,bytes)
	if not ok or type(value)~="table" then return nil,"Setup result is not a JSON object" end
	local quoted,escaped=false,false
	for index=1,#bytes do
		local byte=string.byte(bytes,index)
		if quoted then
			if escaped then escaped=false
			elseif byte==92 then escaped=true
			elseif byte==34 then quoted=false end
		elseif byte==34 then quoted=true
		elseif byte==110 and bytes:sub(index,index+3)=="null" then return nil,"Setup JSON must omit unused fields, not contain null values" end
	end
	return value,nil
end

return Config
