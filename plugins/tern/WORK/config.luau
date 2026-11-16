--!strict
local Config = {}

local MAX_ARGV = 64
local MAX_ARGV_BYTES = 4096
local CONFIG_FIELDS = { glitch_root = true, agent = true }
local AGENT_FIELDS = { kind = true, argv = true }

local function fields_only(value: any, allowed: { [string]: boolean }): boolean
	for key in pairs(value) do
		if type(key) ~= "string" or not allowed[key] then return false end
	end
	return true
end

function Config.decode(text: string, decode: (string) -> any): (any?, string?)
	local ok, value = pcall(decode, text)
	if not ok or type(value) ~= "table" then
		return nil, "WORK configuration is not a JSON object"
	end
	-- Native JSON drops null object members. No WORK field accepts null, and
	-- dropping an unknown member would let Setup destructively rewrite it.
	local quoted, escaped = false, false
	for index = 1, #text do
		local byte = string.byte(text, index)
		if quoted then
			if escaped then escaped = false
			elseif byte == 92 then escaped = true
			elseif byte == 34 then quoted = false end
		elseif byte == 34 then
			quoted = true
		elseif byte == 110 and string.sub(text, index, index + 3) == "null" then
			return nil, "WORK configuration must not contain null values"
		end
	end
	return value, nil
end

function Config.normalize_root(value: any, host_os: string?): string?
	if type(value) ~= "string" or value == "" or string.find(value, "[%c]", 1) ~= nil
		or string.find(value, "..", 1, true) ~= nil
	then
		return nil
	end

	local windows_path = string.match(value, "^%a:[\\/]") ~= nil or string.sub(value, 1, 2) == "\\\\"
	local windows = host_os == "windows" or (host_os == nil and windows_path)
	local root = if windows then string.gsub(value, "\\", "/") else value
	if string.sub(root, 1, 1) ~= "/" and (not windows or string.match(root, "^%a:/") == nil) then
		return nil
	end
	root = string.gsub(root, "/+$", "")
	if root == "" then return "/" end
	if windows and string.match(root, "^%a:$") ~= nil then return root .. "/" end
	return root
end

local function normalize_argv(value: any): ({ string }?, string?)
	if type(value) ~= "table" then return nil, "agent.argv must be an array, not a command string" end
	local count = 0
	local highest = 0
	for key in pairs(value) do
		if type(key) ~= "number" or key < 1 or key % 1 ~= 0 or key > MAX_ARGV then
			return nil, "agent.argv must be a dense array with at most 64 entries"
		end
		count += 1
		highest = math.max(highest, key)
	end
	if count == 0 or highest ~= count then
		return nil, "agent.argv must be a nonempty dense array"
	end

	local argv: { string } = {}
	for index = 1, count do
		local argument = value[index]
		if type(argument) ~= "string" or #argument > MAX_ARGV_BYTES or string.find(argument, "[%c]", 1) ~= nil then
			return nil, "agent.argv entries must be strings of at most 4096 bytes without control characters"
		end
		if index == 1 and argument == "" then return nil, "agent.argv[1] must not be empty" end
		argv[index] = argument
	end
	return argv, nil
end

function Config.validate(value: any, host_os: string?): (any?, string?)
	if type(value) ~= "table" or not fields_only(value, CONFIG_FIELDS) then
		return nil, "WORK configuration must be an object with glitch_root and agent"
	end
	local root = Config.normalize_root(value.glitch_root, host_os)
	if root == nil then
		return nil, "Set glitch_root to an absolute Glitch folder without '..'"
	end
	if value.agent == nil then return nil, "setup_required" end
	if type(value.agent) ~= "table" or not fields_only(value.agent, AGENT_FIELDS) then
		return nil, "agent must be an object with kind and argv"
	end
	if value.agent.kind ~= "acp" and value.agent.kind ~= "cli" then
		return nil, "agent.kind must be 'acp' or 'cli'"
	end
	local argv, err = normalize_argv(value.agent.argv)
	if argv == nil then return nil, err end
	return {
		glitch_root = root,
		agent = { kind = value.agent.kind, argv = argv },
	}, nil
end

return Config
