--!strict
-- Read-only view of SPAWN's saved agents on this host, and the command line WORK
-- runs for a chosen one. SPAWN owns the roster: WORK never writes it and takes no
-- part in SPAWN's launch bookkeeping (reservations, duplicate policy, Running agents).
local M = {}

local ROSTER_MAX_BYTES = 4 * 1024 * 1024
-- Menu rows send their id as the action name; `=` would split it, so ids stay plain.
local RECORD_ID = "^[%w][%w_%-]*$"

M.ICONS = {
	claude = "provider-anthropic",
	codex = "provider-openai-codex",
	kimi = "provider-kimi-code",
	muse = "provider-meta",
	agy = "provider-google-antigravity",
	grok = "provider:xai",
	omp = "pi-mark",
}
local FALLBACK_ICON = "sparkle"

-- Provider CLIs that take an interactive session's first prompt on their command
-- line, and the words before it. Anything else (a seat wrapper, Kimi, a custom
-- CLI) gets the prompt typed into its pane once it is up.
local PROMPT_WORDS: { [string]: { string } } = {
	claude = {}, codex = {}, grok = {}, muse = {}, omp = {}, agy = { "-i" },
}

local RESERVED = {}
for word in string.gmatch("! { } [[ ]] case do done elif else esac fi for if in then until while time function select coproc", "%S+") do
	RESERVED[word] = true
end

local function nonempty(value: any): string?
	if type(value) ~= "string" or string.find(value, "%S") == nil then return nil end
	return value
end

-- SPAWN's command field syntax: shell-like words, single-quoted backslashes literal.
function M.words(value: string): { string }?
	local result: { string } = {}
	local token, quote, escaped, have = "", nil :: string?, false, false
	for index = 1, #value do
		local char = string.sub(value, index, index)
		if escaped then
			token ..= char; escaped = false; have = true
		elseif char == "\\" and quote ~= "'" then
			escaped = true; have = true
		elseif quote ~= nil then
			if char == quote then quote = nil else token ..= char end
			have = true
		elseif char == "'" or char == '"' then
			quote = char; have = true
		elseif string.match(char, "%s") ~= nil then
			if have then table.insert(result, token); token, have = "", false end
		else
			token ..= char; have = true
		end
	end
	if escaped or quote ~= nil then return nil end
	if have then table.insert(result, token) end
	return result
end

local function quote(word: string): string
	return "'" .. string.gsub(word, "'", "'\\''") .. "'"
end

local function posix_word(word: string, first: boolean): string
	if word ~= "" and string.match(word, "^[%w_%-%.,/:=@+%%]+$") ~= nil and not RESERVED[word]
		and not (first and string.find(word, "=", 1, true))
	then
		return word
	end
	return quote(word)
end

local function join(words: { string }): string
	local parts = {}
	for index, word in ipairs(words) do table.insert(parts, posix_word(word, index == 1)) end
	return table.concat(parts, " ")
end

local function program(word: string): string
	local name = string.lower(string.match(string.gsub(word, "\\", "/"), "([^/]+)$") or word)
	return (string.gsub(name, "%.exe$", ""))
end

-- The POSIX command line for `record` with `prompt`, and how the prompt arrives:
-- "argument" (already on the line) or "type" (WORK types it once the agent is up).
function M.render(record: any, prompt: string): (string?, string?, string?)
	local command = nonempty(record.command)
	if command == nil then return nil, nil, "No launch command saved in SPAWN" end
	local words = M.words(command)
	if words == nil or #words == 0 then return nil, nil, "SPAWN's launch command can't be read" end
	-- The command field's last word is the executable (any wrapper such as sudo comes first).
	local executable = program(words[#words])
	for _, argument in ipairs(record.arguments or {}) do
		if type(argument) ~= "string" then return nil, nil, "SPAWN's arguments can't be read" end
		table.insert(words, argument)
	end
	local prompt_words = PROMPT_WORDS[executable]
	local delivery = "type"
	if prompt_words ~= nil then
		for _, word in ipairs(prompt_words) do table.insert(words, word) end
		table.insert(words, prompt)
		delivery = "argument"
	end

	if record.backend == "ssh-command" then
		local host = nonempty(record.host)
		if host == nil then return nil, nil, "No SSH destination saved in SPAWN" end
		local remote = join(words)
		local cwd = nonempty(record.cwd)
		if cwd == "~" then
			remote = 'cd "$HOME" && ' .. remote
		elseif cwd ~= nil and string.sub(cwd, 1, 2) == "~/" then
			remote = 'cd "$HOME/"' .. quote(string.sub(cwd, 3)) .. " && " .. remote
		elseif cwd ~= nil then
			remote = "cd " .. quote(cwd) .. " && " .. remote
		end
		local destination = if nonempty(record.user) ~= nil then record.user .. "@" .. host else host
		words = { "ssh", "-t" }
		if nonempty(record.key_path) ~= nil then table.insert(words, "-i"); table.insert(words, record.key_path) end
		table.insert(words, "--"); table.insert(words, destination); table.insert(words, remote)
	elseif nonempty(record.user) ~= nil and program(words[1]) ~= "sudo" then
		local wrapped = { "sudo", "-u", record.user, "-H", "--" }
		for _, word in ipairs(words) do table.insert(wrapped, word) end
		words = wrapped
	end

	local line = join(words)
	if string.find(line, "[%z\1-\9\11-\31\127]") then
		return nil, nil, "SPAWN's launch command contains control characters"
	end
	-- SPAWN registers provider tab icons for this command name.
	local provider = string.gsub(string.lower(tostring(record.provider or "")), "[^a-z0-9_%-]", "")
	if provider ~= "" then line = "SPAWN_PROVIDER=" .. provider .. " " .. line end
	return line, delivery, nil
end

local function disabled_reason(record: any, host_os: string): string?
	if host_os == "windows" then return "WORK starts SPAWN agents on Linux and macOS hosts only" end
	if record.enabled ~= true then return "Disabled in SPAWN Config" end
	if record.review_required == true then
		return nonempty(record.review_reason) or "Needs command review in SPAWN Config"
	end
	return nil
end

local function agent(record: any, host_os: string): any?
	if type(record) ~= "table" or type(record.id) ~= "string" or string.match(record.id, RECORD_ID) == nil then
		return nil
	end
	local provider = nonempty(record.provider) or "Agent"
	local suffix = nonempty(record.account_label)
	return {
		id = record.id,
		label = if suffix ~= nil then provider .. " — " .. suffix else provider,
		icon = M.ICONS[string.lower(provider)] or FALLBACK_ICON,
		disabled = disabled_reason(record, host_os),
		record = record,
	}
end

-- SPAWN's host store: kv.json `authority` holds `config = {schema = 2, hosts = {[host_key] = {agents}}}`.
function M.decode(store: any, host_os: string)
	local authority = if type(store) == "table" then store.authority else nil
	local config = if type(authority) == "table" then authority.config else nil
	local hosts = if type(config) == "table" and config.schema == 2 then config.hosts else nil
	local bucket = if type(hosts) == "table" and type(authority.host_key) == "string" then hosts[authority.host_key] else nil
	if type(bucket) ~= "table" or type(bucket.agents) ~= "table" then
		return { agents = {}, problem = "SPAWN's saved agents are in a format WORK can't read; using the default agent." }
	end
	local agents = {}
	for _, record in ipairs(bucket.agents) do
		local item = agent(record, host_os)
		if item ~= nil then table.insert(agents, item) end
	end
	return { agents = agents }
end

-- SPAWN keeps its roster in its own plugin data, beside WORK's on the same host.
function M.roster_path(): string?
	local data = string.gsub(tern.plugin.data, "\\", "/")
	local parent = string.match(data, "^(.*)/[^/]+/*$")
	if parent == nil then return nil end
	return parent .. "/spawn/kv.json"
end

-- nil when SPAWN has never stored anything on this host (not installed).
function M.load(): any?
	local path = M.roster_path()
	if path == nil then return nil end
	local exists_ok, exists = pcall(tern.fs.exists, path)
	if not exists_ok or exists ~= true then return nil end
	local read_ok, text = pcall(tern.fs.read, path, ROSTER_MAX_BYTES)
	if not read_ok or type(text) ~= "string" then
		return { agents = {}, problem = "Could not read SPAWN's saved agents; using the default agent." }
	end
	local decode_ok, store = pcall(tern.json.decode, text)
	if not decode_ok then
		return { agents = {}, problem = "SPAWN's saved agents are not valid JSON; using the default agent." }
	end
	return M.decode(store, tern.runtime.os)
end

function M.find(roster: any, id: string): any?
	if roster == nil then return nil end
	for _, item in ipairs(roster.agents) do
		if item.id == id then return item end
	end
	return nil
end

return M
