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
-- Per CLI: the helper text for the free-text Model and Effort fields (the CLI's own flags), and, only
-- where the CLI's own --help documents a headless read-only listing, the argv that lists its models.
-- Findings (18 Nov 2026, each CLI's --help and a read-only run): grok `models` lists offline; agy
-- `models` needs a signed-in account; omp `models --json` lists the account's catalog; claude, codex,
-- kimi and muse have no model-list command (claude lists models only inside a session, codex has no
-- list subcommand, kimi `provider list` shows counts only, muse `model-profile` needs an id).
local HELP = {
	claude = "Passed as --model (an alias such as sonnet or a full model name); effort is --effort. Empty keeps Claude's own default.",
	codex = "Passed as -m / --model. Codex has no verified effort flag here. Empty keeps Codex's own default.",
	kimi = "Passed as -m / --model (a model alias from your Kimi config). Kimi has no effort flag. Empty keeps Kimi's own default.",
	grok = "Passed as -m / --model. Grok's --reasoning-effort is not offered yet. Empty keeps Grok's own default.",
	agy = "Passed as --model; effort is --effort. Empty keeps Agy's own default.",
	muse = "Passed as --model; effort is --reasoning-effort. Empty keeps Muse's own default.",
	omp = "Passed as --model= (fuzzy, or provider/id); effort is --thinking=. Empty keeps OMP's own default.",
}
local LISTERS = {
	grok = { "grok", "models" },
	agy = { "agy", "models" },
	omp = { "omp", "models", "--json", "--no-extensions" },
}
local ALIASES = { antigravity = "agy" }
-- The ONE program-name normalization (also used by config.luau for ordinary launches): lower case,
-- last path part, launcher suffix removed. Ordinary launch detection (ACP servers, sudo) strips the
-- 0.6.6 list .exe/.cmd/.bat and nothing else, so records without model or effort behave as before.
-- The provider label is normalized the same way with { ps1 = true } (SKILLS-211's shim rule, kept harmless).
local SUFFIXES = { "%.exe$", "%.cmd$", "%.bat$" }
function Selectors.basename(value: string, options: { ps1: boolean? }?): string
	local normalized = string.gsub(value, "\\", "/")
	local name = string.lower(string.match(normalized, "([^/]+)$") or normalized)
	for _, suffix in ipairs(SUFFIXES) do name = string.gsub(name, suffix, "") end
	if options ~= nil and options.ps1 == true then name = string.gsub(name, "%.ps1$", "") end
	return name
end
local function base(path: any): string?
	if type(path) ~= "string" then return nil end
	return Selectors.basename(path, { ps1 = true })
end
local function known(name: string?): string?
	if name == nil then return nil end
	name = ALIASES[name] or name
	if CLIS[name] then return name end
	return nil
end
-- The CLI a record's provider names, or nil for any other provider. SKILLS-213: this is the one selector
-- identity (model and effort flags, the Agent settings controls, the model listing); the program's file name
-- never decides it, so a second install or a wrapper may be named anything.
function Selectors.provider_key(provider: any): string?
	return known(base(provider))
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
-- Helper text naming this CLI's model and effort flags (free-text field), or nil for an unknown CLI.
function Selectors.helper(key: string?): string?
	return if key ~= nil then HELP[key] else nil
end
-- The read-only argv that lists this CLI's models headlessly, or nil when it has none.
function Selectors.lister(key: string?): { string }?
	local argv = if key ~= nil then LISTERS[key] else nil
	return if argv ~= nil then table.clone(argv) else nil
end
-- Model ids from a listing's stdout, in order, deduplicated; empty when nothing usable was printed
-- (not signed in, an error, an unknown format); `decode` is the JSON decoder for omp. Only ids passing model_error are kept, so a listing
-- can never offer a value the editor would refuse. Pure.
function Selectors.parse_models(key: string?, output: any, decode: ((string) -> any)?): { string }
	local ids, seen = {}, {}
	if type(output) ~= "string" or #output > 262144 then return ids end
	local function add(value: any)
		if type(value) == "string" and Selectors.model_error(value) == nil and not seen[value] then seen[value] = true; table.insert(ids, value) end
	end
	if key == "omp" then
		-- omp --json prints {"models":[...]}; an entry is an id string or a table with `id`.
		if decode == nil then return ids end
		local ok, data = pcall(decode, output)
		if ok and type(data) == "table" and type(data.models) == "table" then
			for _, entry in ipairs(data.models) do add(if type(entry) == "table" then entry.id else entry) end
		end
		return ids
	end
	for line in string.gmatch(output, "[^\r\n]+") do
		-- grok: "  * grok-4.6 (default)" and "  - grok-4.5": a bullet, one id, an optional note.
		local id = string.match(line, "^%s*[%*%-]%s+([^%s]+)%s*$") or string.match(line, "^%s*[%*%-]%s+([^%s]+)%s+%b()%s*$")
		add(id)
	end
	return ids
end
-- What an agent picker may offer for a catalog row named only by its provider: nil when that provider is not
-- one of the seven CLIs (no Model or Effort field); otherwise the CLI key and the effort values it really
-- accepts (nil when it has no verified effort flag). SPAWN still validates every override itself.
function Selectors.picker_choices(provider: any): { key: string, efforts: { string }? }?
	local key = Selectors.provider_key(provider)
	if key == nil then return nil end
	return { key = key, efforts = Selectors.efforts(key) }
end
function Selectors.model_error(model: any): string?
	if type(model) ~= "string" or model:find("%S") == nil then return "Model must be an exact model id, not empty" end
	if #model > MAX_MODEL then return "Model id is longer than " .. tostring(MAX_MODEL) .. " bytes" end
	if model:find("%c") or utf8.len(model) == nil then return "Model id must not contain control characters" end
	if model:sub(1, 1) == "-" then return "Model id must not start with -" end
	-- Real ids are letters, digits and . _ - : / @ + (and [1m]-style suffixes). Anything else, notably
	-- & | < > ^ % ! " ' ` $ ( ) ; , and spaces, is refused: a .cmd/.bat/.ps1 shim re-reads its arguments
	-- through cmd.exe or PowerShell, so the value must never carry a character those shells act on.
	if model:find("[^%w%._:/@+%-%[%]]") then return "Model id may contain only letters, digits and . _ - : / @ + [ ] (no spaces or shell characters)" end
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
-- `model` is passed only when the caller hands it as a selector (record.model_selector).
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
-- The program's own option region: from `first` up to its own `--` (text after it is positional).
function Selectors.region(argv: { string }, first: number?): { string }
	local words = {}
	for index = first or 1, #argv do
		if argv[index] == "--" then break end
		table.insert(words, argv[index])
	end
	return words
end
-- The first hand-typed flag in `words` that the derived flags would duplicate, or nil.
function Selectors.duplicate(key: string?, words: { string }, model: any, effort: any): string?
	local cli = if key ~= nil then CLIS[key] else nil
	if cli == nil then return nil end
	local function find(entry)
		for _, word in ipairs(words) do
			for _, name in ipairs(names(entry)) do
				if word == name or word:sub(1, #name + 1) == name .. "=" then return name end
				-- A short flag also takes its value attached (-mVALUE). Such a word is refused as a
				-- duplicate even if it might be a boolean cluster (-mv): refusing is the safe side, and
				-- every short flag in the table takes a value, so a CLI reads -mv as -m v anyway.
				if name:find("^%-%a$") and #word > 2 and word:sub(1, 2) == name then return name end
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
-- wrapper). If the word just before the task slot is an option (--prompt, -p), the task is
-- that option's value, so the flags go BEFORE that option and the pair stays adjacent. A
-- positional task, or one after `--`, has no such option and is unchanged. Returns the new
-- argv and the task slot moved to match.
function Selectors.apply(argv: { string }, flags: { string }, slot: number?, first: number?): ({ string }, number?)
	if #flags == 0 then return argv, slot end
	local at = if slot ~= nil then slot else #argv + 1
	if slot ~= nil and at - 1 >= (first or 1) then
		local owner = argv[at - 1]
		if owner:sub(1, 1) == "-" and owner ~= "--" and owner ~= "-" then at = at - 1 end
	end
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
