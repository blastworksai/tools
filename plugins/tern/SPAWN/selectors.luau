-- Model and effort selectors. One capability table is the only place that names a
-- CLI's flags; argv flags are DERIVED from a record's `model` and `effort` fields.
-- Only flags that each CLI's own --help declares are listed. A CLI without a verified
-- effort flag has no `effort` entry and shows no effort control. Pure: no I/O, no requires.
--   codex   effort: only the generic `-c key=value` exists in --help and its values are unverified.
--   kimi    effort: no flag in --help (in-session switch only).
--   grok    effort: `--reasoning-effort` exists but --help lists no values.
-- Those three are not supported yet. Add an `effort` entry only after the values are proven.
local Selectors = {}
local MAX_MODEL = 200
local SCALE = { "low", "medium", "high", "xhigh", "max" }
local CLIS = {
	claude = { model = { flag = "--model" }, effort = { flag = "--effort", values = SCALE } },
	codex = { model = { flag = "-m", also = { "--model" } } },
	kimi = { model = { flag = "-m", also = { "--model" } } },
	grok = { model = { flag = "-m", also = { "--model" } } },
	agy = { model = { flag = "--model" }, effort = { flag = "--effort", values = SCALE } },
	muse = {
		model = { flag = "--model" },
		effort = { flag = "--reasoning-effort", also = { "--effort" }, values = { "none", "minimal", "low", "medium", "high", "xhigh", "max", "ultra" } },
	},
	-- OMP's help writes its options as --model=<value> and --thinking=<value>.
	omp = {
		model = { flag = "--model", joined = true },
		effort = { flag = "--thinking", joined = true, values = { "off", "minimal", "low", "medium", "high", "xhigh", "max", "auto" } },
	},
}
local ALIASES = { antigravity = "agy" }
local function base(path: any): string?
	if type(path) ~= "string" then return nil end
	local name = path:lower():gsub("\\", "/"):match("([^/]+)$")
	if name == nil then return nil end
	return (name:gsub("%.exe$", ""))
end
-- The CLI is named by the record's provider, else by the executable it launches.
function Selectors.cli_key(provider: any, executable: any): string?
	local key = base(provider)
	key = ALIASES[key or ""] or key
	if key ~= nil and CLIS[key] then return key end
	key = base(executable)
	key = ALIASES[key or ""] or key
	if key ~= nil and CLIS[key] then return key end
	return nil
end
function Selectors.record_key(record: any): string?
	local executable = record.fresh_executable
	if executable == nil and type(record.command) == "string" then executable = record.command:match("^%s*(%S+)") end
	if record.fresh_native_default then executable = "omp" end
	return Selectors.cli_key(record.provider, executable)
end
function Selectors.supports_model(key: string?): boolean
	return key ~= nil and CLIS[key] ~= nil
end
-- The effort values this CLI really accepts; nil when it has no verified effort flag.
function Selectors.efforts(key: string?): { string }?
	local cli = if key ~= nil then CLIS[key] else nil
	if cli == nil or cli.effort == nil then return nil end
	return table.clone(cli.effort.values)
end
function Selectors.model_error(model: any): string?
	if type(model) ~= "string" or model:find("%S") == nil then return "Model must be an exact model id, not empty" end
	if #model > MAX_MODEL then return "Model id is longer than " .. tostring(MAX_MODEL) .. " bytes" end
	if model:find("%c") or utf8.len(model) == nil then return "Model id must not contain control characters" end
	if model:sub(1, 1) == "-" then return "Model id must not start with -" end
	return nil
end
function Selectors.effort_error(key: string?, effort: any): string?
	if type(effort) ~= "string" or effort == "" then return "Effort must be one of the values this CLI lists" end
	local values = Selectors.efforts(key)
	if values == nil then return "This CLI has no verified effort setting yet; leave effort empty" end
	if not table.find(values, effort) then return "Effort for " .. tostring(key) .. " must be one of: " .. table.concat(values, ", ") end
	return nil
end
-- argv words derived from the fields. Empty when nothing is chosen or the CLI is unknown.
function Selectors.flags(key: string?, model: any, effort: any): { string }
	local cli = if key ~= nil then CLIS[key] else nil
	local flags = {}
	if cli == nil then return flags end
	local function add(entry, value)
		if entry.joined then table.insert(flags, entry.flag .. "=" .. value) else table.insert(flags, entry.flag); table.insert(flags, value) end
	end
	if model ~= nil then add(cli.model, model) end
	if effort ~= nil and cli.effort ~= nil then add(cli.effort, effort) end
	return flags
end
local function names(entry: any): { string }
	local list = { entry.flag }
	for _, name in ipairs(entry.also or {}) do table.insert(list, name) end
	return list
end
-- The first hand-typed flag in `words` that the derived flags would duplicate, or nil.
function Selectors.duplicate(key: string?, words: { string }, model: any, effort: any): string?
	local cli = if key ~= nil then CLIS[key] else nil
	if cli == nil then return nil end
	local function find(entry)
		for _, word in ipairs(words) do
			for _, name in ipairs(names(entry)) do
				if word == name or word:sub(1, #name + 1) == name .. "=" then return name end
			end
		end
		return nil
	end
	if model ~= nil then
		local hit = find(cli.model)
		if hit then return hit end
	end
	if effort ~= nil and cli.effort ~= nil then return find(cli.effort) end
	return nil
end
-- Insert flags into argv at the task slot (or the end), before any `--` that follows the
-- program. `first` is the index where the program's own arguments start (after a sudo
-- wrapper). Returns the new argv and the task slot moved to match.
function Selectors.apply(argv: { string }, flags: { string }, slot: number?, first: number?): ({ string }, number?)
	if #flags == 0 then return argv, slot end
	local at = if slot ~= nil then slot else #argv + 1
	for index = first or 1, #argv do
		if argv[index] == "--" then
			if index < at then at = index end
			break
		end
	end
	for offset, word in ipairs(flags) do table.insert(argv, at + offset - 1, word) end
	return argv, if slot ~= nil then slot + #flags else nil
end
return Selectors
