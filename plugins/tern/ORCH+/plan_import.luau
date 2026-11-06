--!strict
-- Pure `/glitch-plan` importer (plan D10, Task 6A). No native effects: the window reads the file,
-- the host calls `parse(bytes)` and stores the result. Only DECLARED structure is read; completion
-- is never inferred from prose or `## Progress` (that section is skipped entirely).
--
-- Provenance: action headers follow the /glitch-plan checker (plan_check.py)
--   _ACTION_HEADER = ^#{1,6}\s+(?:CREATE|UPDATE|ADD|REMOVE|REFACTOR|MIRROR|DELETE|MOVE)\s+(.+?)\s*$  (MULTILINE)
-- translated to Luau patterns per line. Cases Luau patterns cannot express, and how they are handled:
--   * alternation: the keyword is captured as `%u+` and checked against ACTIONS; because Python
--     requires `\s` right after the keyword, `CREATED x` / `UPDATEx` fail in both.
--   * `#{1,6}`: captured as `#+` and its length checked (7+ hashes cannot match in Python either).
--   * Python `\s` also matches Unicode spaces (NBSP …) and, in `^#{1,6}\s+`, a newline, so a header
--     split across lines (`###` alone, keyword on the next line) matches there and not here; Luau
--     `%s` is ASCII whitespace and matching is per line.
--   * plan_check scans fenced code too; action headers are therefore also read inside fences here.
-- Target paths: plan_check's `_paths_in` (backtick spans, else the whole target; brace expansions
-- skipped) and `_looks_like_path`, except that a leading `/` or drive letter is kept (plan_check's
-- token class drops it) and any `.ext` suffix counts, not only plan_check's extension list.
local codec = require("./transport")
local M = {}
M.MAX_BYTES = 1024 * 1024
M.MAX_CHECKPOINTS = 30
M.MAX_TASKS = 64
M.MAX_FILES = 64
M.MAX_FILE_BYTES = 256
M.MAX_CHECKS = 16
M.MAX_ARGV = 16
M.MAX_ARG_BYTES = 512
M.MAX_SYSTEMS = 16
M.MAX_SYSTEM_BYTES = 80
M.MAX_TASK_ID = 32
local ACTIONS = { CREATE = true, UPDATE = true, ADD = true, REMOVE = true, REFACTOR = true, MIRROR = true, DELETE = true, MOVE = true }
local DOTFILES = { [".gitignore"] = true, [".gitattributes"] = true, [".env"] = true, [".env.example"] = true }
local HOME_KINDS = { workspace = true, ["local"] = true, skill = true }
local DASHES = { "—", "–", "-" }

local function problem(code: string, message: string): any return { ok = false, code = code, message = message } end
local function trim(s: string): string return (s:match("^%s*(.-)%s*$")) :: string end
local function flag(list: { string }, name: string) if not table.find(list, name) then table.insert(list, name) end end
local function slug(v: string, n: number): boolean return #v >= 1 and #v <= n and v:match("^[a-z][a-z0-9%-]*$") ~= nil end
local function unquote(v: string): string
	local inner = v:match("^`([^`]*)`$")
	return trim(inner or v)
end

-- `<sep> <title>` after a checkpoint number or task id; em dash per convention, en dash or hyphen tolerated.
local function dash_title(rest: string): string?
	for _, sep in DASHES do
		if rest:sub(1, #sep) == sep and rest:sub(#sep + 1, #sep + 1):match("%s") then
			local title = trim(rest:sub(#sep + 1))
			if title ~= "" then return title end
		end
	end
	return nil
end

-- Heading level and text for column-0 ATX headings, else nil.
local function heading(line: string): (number?, string?)
	local hashes, text = line:match("^(#+)%s+(.-)%s*$")
	if not hashes or #hashes > 6 then return nil, nil end
	return #hashes, text
end

-- plan_check `_ACTION_HEADER`: returns the target (group 1) of a declared action header.
local function action_target(line: string): string?
	local hashes, keyword, target = line:match("^(#+)%s+(%u+)%s+(.-)%s*$")
	if not hashes or #hashes > 6 or not ACTIONS[keyword] or target == "" then return nil end
	return target
end
M.action_target = action_target -- exported for the plan_check contract-drift test (tests/workflow.luau)

local function looks_like_path(t: string): boolean
	if t == "" then return false end
	local low = t:lower()
	return t:find("/", 1, true) ~= nil or t:find("\\", 1, true) ~= nil or DOTFILES[low] == true or low:match("%.[%w]+$") ~= nil
end

-- Declared path tokens of one action target; `bad` is true when nothing usable was declared.
local function paths_in(target: string): ({ string }, boolean)
	local candidates: { string } = {}
	for span in target:gmatch("`([^`]+)`") do table.insert(candidates, span) end
	if #candidates == 0 then candidates = { target } end
	local out: { string }, bad = {}, false
	for _, c in candidates do
		if c:find("[{}]") then bad = true; continue end
		for token in c:gmatch("%S+") do
			local t = token:gsub("^[%*~]+", ""):gsub("[%*~,;:]+$", ""):gsub("%.+$", "")
			if looks_like_path(t) and not table.find(out, t) then table.insert(out, t) end
		end
	end
	return out, bad or #out == 0
end

-- Whitespace-separated argv; single or double quotes group (and are removed). No escapes, no
-- expansion. Returns nil for unbalanced quotes, an empty argument, or a Contract G bound overflow.
function M.split_argv(cmd: string): { string }?
	if utf8.len(cmd) == nil then return nil end
	local argv: { string }, current: { string } = {}, {}
	local quote: string?, started = nil, false
	for _, cp in utf8.codes(cmd) do
		local ch = utf8.char(cp)
		if quote then
			if ch == quote then quote = nil else table.insert(current, ch) end
		elseif ch == "'" or ch == '"' then
			quote = ch; started = true
		elseif ch:match("^%s$") then
			if started then table.insert(argv, table.concat(current)); current = {}; started = false end
		else
			table.insert(current, ch); started = true
		end
	end
	if quote then return nil end
	if started then table.insert(argv, table.concat(current)) end
	if #argv == 0 or #argv > M.MAX_ARGV then return nil end
	for _, a in argv do if a == "" or #a > M.MAX_ARG_BYTES then return nil end end
	return argv
end

-- Split a VALIDATE value on `,`/`;` outside backticks and parentheses.
local function validate_items(v: string): { string }
	local items, start, depth, tick = {}, 1, 0, false
	for i = 1, #v do
		local c = v:sub(i, i)
		if c == "`" then tick = not tick
		elseif not tick and c == "(" then depth += 1
		elseif not tick and c == ")" and depth > 0 then depth -= 1
		elseif not tick and depth == 0 and (c == "," or c == ";") then
			table.insert(items, v:sub(start, i - 1)); start = i + 1
		end
	end
	table.insert(items, v:sub(start))
	return items
end

-- Remove one trailing `(…)` (outside backticks) and trailing periods.
local function strip_tail(item: string): string
	local s = trim(item):gsub("%.+$", "")
	if s:sub(-1) == ")" then
		local depth, tick = 0, false
		for i = #s, 1, -1 do
			local c = s:sub(i, i)
			if c == "`" then tick = not tick
			elseif not tick and c == ")" then depth += 1
			elseif not tick and c == "(" then
				depth -= 1
				if depth == 0 then s = trim(s:sub(1, i - 1)):gsub("%.+$", ""); break end
			end
		end
	end
	return trim(s)
end

-- One VALIDATE item → command text, or nil (unparsed). An item is exactly one backtick span; the
-- first item of a line may carry a plain-word qualifier (`native`, `native groups`), later items
-- may start with `and`. Any other prose makes the item unparsed — it is never executed.
local function validate_command(item: string, first: boolean): string?
	local s = strip_tail(item)
	if not first then s = s:gsub("^and%s+", "") end
	local prefix, cmd = s:match("^([^`]*)`([^`]+)`$")
	if not prefix then return nil end
	if prefix ~= "" and not (first and prefix:match("^%a[%a ]*%s$")) then return nil end
	return trim(cmd)
end

local function new_task(id: string, title: string, line: string): any
	return { id = id, title = title, files = {}, checks = {}, independent = false, sequential_why = nil,
		class = nil, template_id = nil, systems = {}, flags = {}, lines = { line }, marker_independent = false, unparsed_files = false }
end

local function finish_task(t: any, home_prefix: string?)
	-- Markers: INDEPENDENT only when SEQUENTIAL is absent; neither → sequential by default and flagged.
	if t.marker_independent and t.sequential_why then flag(t.flags, "marker_conflict")
	elseif t.marker_independent then t.independent = true
	elseif not t.sequential_why then flag(t.flags, "sequential_default") end
	if home_prefix then
		for i, f in t.files do
			if f:sub(1, #home_prefix) == home_prefix and #f > #home_prefix then t.files[i] = f:sub(#home_prefix + 1)
			else flag(t.flags, "file_outside_home") end
		end
	end
	local files = {}
	for _, f in t.files do
		if #f > M.MAX_FILE_BYTES then flag(t.flags, "file_unparsed")
		elseif not table.find(files, f) then
			if #files >= M.MAX_FILES then flag(t.flags, "files_truncated") else table.insert(files, f) end
		end
	end
	t.files = files
	if t.unparsed_files then flag(t.flags, "file_unparsed") end
	if #files == 0 then flag(t.flags, "no_files") end
	if #t.checks == 0 and not table.find(t.flags, "check_unparsed") then flag(t.flags, "no_checks") end
	while #t.lines > 0 and trim(t.lines[#t.lines]) == "" do table.remove(t.lines) end
	t.text = table.concat(t.lines, "\n")
	t.lines = nil; t.marker_independent = nil; t.unparsed_files = nil
end

-- Per-task line: action headers, markers, VALIDATE, CLASS, TEMPLATE, SYSTEMS.
local function task_line(t: any, line: string, fenced: boolean)
	local target = action_target(line)
	if target then
		local paths, bad = paths_in(target)
		for _, p in paths do table.insert(t.files, p) end
		if bad then t.unparsed_files = true end
		return
	end
	if fenced then return end
	if line:match("^%s*%*%*INDEPENDENT%*%*") then t.marker_independent = true; return end
	local why = line:match("^%s*SEQUENTIAL:%s*(.-)%s*$")
	if why then
		if why ~= "" and not t.sequential_why then t.sequential_why = why end
		return
	end
	local key, value = line:match("^%s*[%-%*]?%s*%*%*(%u+)%*%*:%s*(.-)%s*$")
	if key == "VALIDATE" then
		for i, item in validate_items(value :: string) do
			local cmd = validate_command(item, i == 1)
			local argv = if cmd then M.split_argv(cmd) else nil
			if not argv then flag(t.flags, "check_unparsed")
			elseif #t.checks >= M.MAX_CHECKS then flag(t.flags, "checks_truncated")
			else table.insert(t.checks, { check_id = t.id .. "-c" .. tostring(#t.checks + 1), argv = argv }) end
		end
	elseif key == "CLASS" then
		local v = unquote(value :: string)
		if slug(v, 32) and not t.class then t.class = v else flag(t.flags, "class_invalid") end
	elseif key == "TEMPLATE" then
		local v = unquote(value :: string)
		if slug(v, 32) and not t.template_id then t.template_id = v else flag(t.flags, "template_invalid") end
	elseif key == "SYSTEMS" then
		for entry in ((value :: string) .. ","):gmatch("([^,]*),") do
			local v = unquote(entry)
			if v == "" or #v > M.MAX_SYSTEM_BYTES or #t.systems >= M.MAX_SYSTEMS then flag(t.flags, "systems_invalid")
			elseif not table.find(t.systems, v) then table.insert(t.systems, v) end
		end
	end
end

-- parse(bytes) -> plan | nil, problem{ok=false, code, message}
function M.parse(bytes: any): (any, any)
	if type(bytes) ~= "string" then return nil, problem("invalid_input", "Plan bytes must be a string.") end
	if #bytes > M.MAX_BYTES then return nil, problem("too_large", "Plan file exceeds 1 MiB.") end
	if utf8.len(bytes) == nil or bytes:find("%z") then return nil, problem("invalid_input", "Plan file is not NUL-free UTF-8.") end
	local title: string? = nil
	local home: string? = nil
	local checkpoints: { any }, plan_flags: { string }, seen_ids: { [string]: boolean } = {}, {}, {}
	local checkpoint: any, task: any = nil, nil
	local section: string? = nil -- current level-2 heading text
	local fence: string? = nil
	local tasks = 0
	local function close_task() if task then table.insert(checkpoint.tasks, task); task = nil end end
	local function close_checkpoint()
		close_task()
		if checkpoint then
			if #checkpoint.tasks == 0 then flag(checkpoint.flags, "no_tasks") end
			table.insert(checkpoints, checkpoint); checkpoint = nil
		end
	end
	for _, raw in bytes:split("\n") do
		local line = if raw:sub(-1) == "\r" then raw:sub(1, -2) else raw
		local level: number?, text: string? = nil, nil
		local fenced = fence ~= nil
		local marker = line:match("^%s*(```+)") or line:match("^%s*(~~~+)")
		if marker then
			if not fence then fence = marker:sub(1, 1); fenced = true
			elseif marker:sub(1, 1) == fence then fence = nil; fenced = true end
		end
		if not fenced then level, text = heading(line) end
		if level and level <= 2 then
			close_checkpoint()
			section = if level == 2 then text else nil
			if level == 1 and not title then
				local t = (text :: string):match("^Feature:%s*(.-)$")
				if t and t ~= "" then title = t end
			end
			continue
		end
		if section == "Progress" then continue end
		if section == "Build choices" and not fenced then
			local h = line:match("^home:%s*(.-)%s*$")
			if h and not home then home = h end
		end
		if level == 3 and (text :: string):match("^Checkpoint %d") then
			local n, rest = (text :: string):match("^Checkpoint (%d+)%s+(.+)$")
			local cp_title = if rest then dash_title(rest) else nil
			if not cp_title then return nil, problem("checkpoint_header_invalid", "Checkpoint header must read '### Checkpoint <n> — <title>': " .. line) end
			close_checkpoint()
			local number = tonumber(n) :: number
			local last = checkpoints[#checkpoints]
			if last and number <= last.n then return nil, problem("checkpoint_order", "Checkpoint numbers must strictly increase: " .. line) end
			if #checkpoints >= M.MAX_CHECKPOINTS then return nil, problem("too_many_checkpoints", "A plan may hold at most 30 checkpoints.") end
			checkpoint = { n = number, title = cp_title, tasks = {}, flags = {} }
			continue
		end
		local task_id: string?, task_rest: string? = nil, nil
		if level == 4 then task_id, task_rest = (text :: string):match("^Task (%S+)%s+(.+)$") end
		local task_title = if task_rest then dash_title(task_rest) else nil
		-- A level-4 `Task <id-with-digit> …` heading is a task header and must be well formed;
		-- other `#### Task …` prose headings without the dash form stay ordinary task content.
		if task_id and (task_title or (task_id :: string):find("%d")) then
			local id = task_id :: string
			if not task_title then return nil, problem("task_header_invalid", "Task header must read '#### Task <id> — <title>': " .. line) end
			if not checkpoint then return nil, problem("task_outside_checkpoint", "Task header outside any checkpoint: " .. line) end
			if #(id :: string) > M.MAX_TASK_ID or not (id :: string):match("^[A-Za-z0-9_%-]+$") then
				return nil, problem("task_id_invalid", "Task IDs are 1-32 letters, digits, '_' or '-': " .. line)
			end
			if seen_ids[id] then return nil, problem("duplicate_task", "Task ID appears twice: " .. (id :: string)) end
			if tasks >= M.MAX_TASKS then return nil, problem("too_many_tasks", "A plan may hold at most 64 tasks.") end
			close_task()
			seen_ids[id] = true; tasks += 1
			task = new_task(id :: string, task_title, line)
			continue
		end
		if task then
			table.insert(task.lines, line)
			task_line(task, line, fenced)
		elseif checkpoint and action_target(line) then
			flag(checkpoint.flags, "untasked_actions")
		end
	end
	close_checkpoint()
	if not title then return nil, problem("no_title", "Plan has no '# Feature: <title>' heading.") end
	if #checkpoints == 0 then return nil, problem("no_checkpoints", "Plan declares no '### Checkpoint <n> — <title>' sections.") end
	local project_hint: any = nil
	local home_prefix: string? = nil
	if home then
		local kind, name = home:match("^(%a+):([%w%._%-]+)$")
		if kind and HOME_KINDS[kind] then
			project_hint = { kind = kind, name = name }
			if kind == "workspace" then home_prefix = "workspaces/" .. (name :: string) .. "/" end
		else
			flag(plan_flags, "home_invalid")
		end
	end
	for _, cp in checkpoints do for _, t in cp.tasks do finish_task(t, home_prefix) end end
	return { title = title, plan_revision = codec.sha256(bytes), project_hint = project_hint, flags = plan_flags, checkpoints = checkpoints }, nil
end

return M
