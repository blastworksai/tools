--!strict
-- Pure supported Markdown plan importer. No native effects: the execution host reads plan files,
-- while desktop boards remain window-owned. Only DECLARED structure is read; completion
-- comes only from explicit state/checklist data, including delimited TERN-SESSION metadata.
-- Ordinary prose in `## Progress` never creates work or completion.
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
local codec = require("./wire/codec")
local quota = require("./quota")
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
local function advance_fence(line: string, fence: string?, size: number): (string?, number, boolean)
	local inside = fence ~= nil
	local indent, run, rest = line:match("^( *)(`+)(.*)$")
	if not run then indent, run, rest = line:match("^( *)(~+)(.*)$") end
	if run and #indent <= 3 and #run >= 3 then
		local char = run:sub(1, 1)
		if not fence and (char ~= "`" or not rest:find("`", 1, true)) then return char, #run, true end
		if fence == char and #run >= size and rest:match("^%s*$") then return nil, 0, true end
	end
	return fence, size, inside
end

M.RULINGS_OPEN = "<!-- orchplus-operator-rulings v1 -->"
M.RULINGS_CLOSE = "<!-- /orchplus-operator-rulings v1 -->"

-- Byte positions are intentional: removing metadata must not normalize executable bytes.
-- Fence delimiters obey the Markdown length/character rule, including indented examples.
function M.split_rulings(bytes: any): (any?, any?)
	if type(bytes) ~= "string" or utf8.len(bytes) == nil or bytes:find("%z") then
		return nil, problem("invalid_input", "Document must be NUL-free UTF-8.")
	end
	local position, fence, fence_size = 1, nil, 0
	local block, entry_marker, entry_lines = nil, nil, {}
	local entries, seen = {}, {}
	local mixed, line_ending = false, nil
	local function malformed(message: string): (any?, any?)
		return nil, problem("invalid_rulings", message)
	end
	local function finish_entry(): boolean
		if not entry_marker or #entry_lines < 2 then return false end
		entries[entry_marker] = table.concat(entry_lines, "\n")
		return true
	end
	while position <= #bytes do
		local lf = bytes:find("\n", position, true)
		local stop = if lf then lf - 1 else #bytes
		local eol = if lf then "\n" else ""
		if lf and bytes:sub(stop, stop) == "\r" then stop -= 1; eol = "\r\n" end
		local line = bytes:sub(position, stop)
		if eol ~= "" then
			if line_ending and line_ending ~= eol then mixed = true else line_ending = eol end
		end
		if line:find("\r", 1, true) then mixed = true end
		if block and not block.end_byte then
			if line == M.RULINGS_CLOSE then
				if eol ~= block.eol or not finish_entry() then return malformed("Ruling block needs quoted entries and a matching final newline.") end
				block.close_byte, block.end_byte = position, lf
			elseif line == M.RULINGS_OPEN then
				return malformed("Duplicate ruling delimiter.")
			else
				if eol ~= block.eol or line:sub(1, 2) ~= "> " or line:sub(3):find("[<>`]") then
					return malformed("Every ruling entry line must be quoted and escaped.")
				end
				local marker = line:match("^> (orchplus%-ruling:[A-Za-z0-9_-]+:[A-Za-z0-9_-]+)$")
				if marker then
					if #marker > 256 then return malformed("Ruling marker exceeds its bound.") end
					if seen[marker] then return nil, problem("duplicate_entry", "A ruling marker occurs more than once.") end
					if entry_marker and not finish_entry() then return malformed("Ruling marker has no entry text.") end
					seen[marker], entry_marker, entry_lines = true, marker, {}
				elseif not entry_marker then
					return malformed("Ruling text must begin with an authority-scoped entry marker.")
				end
				table.insert(entry_lines, line)
			end
		elseif not fence and (line == M.RULINGS_OPEN or line == M.RULINGS_CLOSE) then
			if block and line == M.RULINGS_OPEN then return nil, problem("duplicate_entry", "Multiple outside-fence ruling blocks require owner review.") end
			if block or line == M.RULINGS_CLOSE then return malformed("Ruling delimiters must occur exactly once and in order.") end
			if eol == "" or position <= #eol or bytes:sub(position - #eol, position - 1) ~= eol then
				return malformed("Ruling block is missing its own leading separator.")
			end
			block = { start_byte = position - #eol, eol = eol, entries = entries }
		else
			fence, fence_size = advance_fence(line, fence, fence_size)
		end
		position = if lf then lf + 1 else #bytes + 1
	end
	if block then
		if not block.end_byte then return malformed("Ruling block has no closing delimiter.") end
		if mixed then return malformed("Mixed line endings make ruling metadata ambiguous.") end
		return { content = bytes:sub(1, block.start_byte - 1) .. bytes:sub(block.end_byte + 1), block = block }, nil
	end
	return { content = bytes, unterminated_fence = fence ~= nil }, nil
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
	return { id = id, title = title, files = {}, checks = {}, steps = {}, filechanges = {}, validationchecks = {},
		independent = false, sequential_why = nil, class = nil, template_id = nil, systems = {}, flags = {},
		lines = { line }, marker_independent = false, unparsed_files = false }
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
		for _, file in ipairs(t.filechanges) do
			if file.path:sub(1, #home_prefix) == home_prefix then file.path = file.path:sub(#home_prefix + 1) end
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
		local action = line:match("^#+%s+(%u+)")
		for _, p in paths do
			table.insert(t.files, p)
			if #t.filechanges < M.MAX_FILES then
				table.insert(t.filechanges, { id = "file-" .. codec.sha256((action or "") .. "\n" .. p):sub(1, 24), path = p, action = action })
			end
		end
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
	if not key then key, value = line:match("^%s*[%-%*]?%s*(%u+):%s*(.-)%s*$") end
	local after = line:match("^%s*AFTER%s+([^;%.]+)")
	if key == "AFTER" or key == "DEPENDS" then after = value end
	if after then
		t.depends_on = t.depends_on or {}
		for id in after:gmatch("[A-Za-z0-9_%-]+") do
			if id ~= "and" and not table.find(t.depends_on, id) then table.insert(t.depends_on, id) end
		end
	end
	if key == "VALIDATE" then
		for i, item in validate_items(value :: string) do
			local cmd = validate_command(item, i == 1)
			local argv = if cmd then M.split_argv(cmd) else nil
			if not argv then flag(t.flags, "check_unparsed")
			elseif #t.checks >= M.MAX_CHECKS then flag(t.flags, "checks_truncated")
			else
				local id = t.id .. "-c" .. tostring(#t.checks + 1)
				table.insert(t.checks, { check_id = id, argv = argv })
				table.insert(t.validationchecks, { id = id, text = cmd, argv = table.clone(argv) })
			end
		end
	elseif key == "STATE" then
		local state = unquote(value :: string):lower()
		if state == "pending" or state == "active" or state == "done" or state == "blocked" or state == "paused" then t.state = state
		else flag(t.flags, "state_invalid") end
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

local STATES = { pending = true, active = true, done = true, blocked = true, paused = true }
local function identity(kind: string, parent: string, value: string): string
	return kind .. "-" .. codec.sha256(parent .. "\n" .. value):sub(1, 24)
end
local function normalized(value: string): string
	return trim(value):gsub("%*%*", ""):gsub("%s+", " "):lower()
end
-- Execution-content identity is also used by the host to reconcile legacy plans.
-- Displayed CP numbers, generated ids, source completion and check-id prefixes
-- are deliberately absent; changed instructions/scope/check argv remain distinct.
function M.task_identity(cp: any, task: any): string
	local body, fence, fence_size = {}, nil, 0
	for i, raw in ipairs((task.text or ""):split("\n")) do
		local line = raw:gsub("\r$", "")
		if i == 1 and heading(line) then continue end
		local fenced
		fence, fence_size, fenced = advance_fence(line, fence, fence_size)
		if not fenced then
			if line:match("^%s*[%-%*]?%s*%*%*STATE%*%*:%s*") or line:match("^%s*[%-%*]?%s*STATE:%s*") then continue end
			line = line:gsub("^(%s*[%-%*]%s+)%[[ xX]%]", "%1[ ]")
		end
		table.insert(body, line)
	end
	while #body > 0 and trim(body[#body]) == "" do table.remove(body) end
	-- Decoded native arrays have protected metatables. Copy only arrays we sort;
	-- leave the source metadata and immutable command arguments untouched.
	local files, systems, checks = tern.json.array(), tern.json.array(), {}
	for i, file in ipairs(task.files or {}) do files[i] = file end
	for i, system in ipairs(task.systems or {}) do systems[i] = system end
	table.sort(files); table.sort(systems)
	for _, check in ipairs(task.checks or {}) do table.insert(checks, check.argv) end
	return "source-" .. quota.digest({ checkpoint = normalized(cp.title), title = normalized(task.title), body = table.concat(body, "\n"),
		files = files, systems = systems, checks = checks, class = task.class, template_id = task.template_id,
		independent = task.independent == true, sequential_why = task.sequential_why, depends_on = task.depends_on or {} })
end
local function rekey_task(task: any, id: string)
	local replacements = {}
	for i, check in ipairs(task.checks) do
		local next_id = id .. "-c" .. tostring(i)
		replacements[check.check_id] = next_id; check.check_id = next_id
	end
	task.id = id
	for _, node in ipairs(task.steps) do node.id = identity("step", id, node.text) end
	for _, node in ipairs(task.filechanges) do node.id = identity("file", id, node.action .. "\n" .. node.path) end
	for _, node in ipairs(task.validationchecks) do node.id = replacements[node.id] or identity("check", id, node.text) end
end
-- Only the explicitly delimited native session schema supplies progress. In particular,
-- prose under Progress is not interpreted. Text matching precedes numeric ids: native
-- checkpoint ids survive heading renumbering and may no longer equal the displayed CP.
local function session_states(bytes: string): (any?, any?)
	local lines, inside, seen, fence, size, fence_size = {}, false, false, nil, 0, 0
	for _, raw in bytes:split("\n") do
		local line = raw:gsub("\r$", "")
		if not fence and line == "<!-- TERN-SESSION:START -->" then
			if seen then return nil, problem("session_invalid", "Multiple TERN-SESSION blocks are ambiguous.") end
			seen, inside = true, true
		elseif inside and line == "<!-- TERN-SESSION:END -->" then
			inside = false
		elseif inside then
			if not line:match("^%s*```") then
				size += #line + 1
				if size > 131072 then return nil, problem("session_invalid", "TERN-SESSION metadata exceeds 128 KiB.") end
				table.insert(lines, line)
			end
		else
			fence, fence_size = advance_fence(line, fence, fence_size)
		end
	end
	if inside then return nil, problem("session_invalid", "TERN-SESSION block is not closed.") end
	if not seen then return {}, nil end
	local ok, value = pcall(tern.json.decode, table.concat(lines, "\n"))
	if not ok or type(value) ~= "table" or value.schema ~= 1 or type(value.checkpoints) ~= "table" or #value.checkpoints > M.MAX_CHECKPOINTS then
		return nil, problem("session_invalid", "TERN-SESSION needs schema 1 and bounded explicit checkpoints.")
	end
	local ids = {}
	for _, cp in ipairs(value.checkpoints) do
		if type(cp) ~= "table" or type(cp.id) ~= "string" or not cp.id:match("^[A-Za-z0-9_%-]+$") or #cp.id > 40
			or ids[cp.id] or not STATES[cp.state] or (cp.text ~= nil and type(cp.text) ~= "string") then
			return nil, problem("session_invalid", "TERN-SESSION checkpoint identities/states must be explicit and unique.")
		end
		ids[cp.id] = true
	end
	return value.checkpoints, nil
end
local function checkpoint_header(text: string): (number?, string?)
	local n, rest = text:match("^[Cc][Hh][Ee][Cc][Kk][Pp][Oo][Ii][Nn][Tt]%s+(%d+)(.*)$")
	if n then
		if rest ~= "" and not rest:sub(1, 1):match("[%s:]") then return nil, nil end
		rest = trim(rest)
		return tonumber(n), dash_title(rest) or rest:match("^:%s*(.+)$")
	end
	n, rest = text:match("^[Cc][Pp](%d+)(.*)$")
	if not n then n, rest = text:match("^[Cc](%d+)(.*)$") end
	if not n or (rest ~= "" and not rest:sub(1, 1):match("[%s:]")) then return nil, nil end
	rest = trim(rest)
	if rest == "" then return tonumber(n), nil end
	local title = dash_title(rest) or rest:match("^:%s*(.+)$")
	return if title then tonumber(n) else nil, title
end
local function subsection(line: string): string?
	local _, h = heading(line)
	local value = normalized(h or line:gsub("^%s*%*%*", ""):gsub("%*%*:?%s*$", ""):gsub(":%s*$", ""))
	if value == "steps" or value == "implementation steps" then return "steps" end
	if value == "file changes" or value == "filechanges" or value == "files" then return "files" end
	if value == "validation checks" or value == "validationchecks" or value == "validation" or value == "checks" then return "checks" end
	return nil
end
local function concrete_line(t: any, line: string)
	local part = subsection(line)
	if part then t.part = part; return end
	if heading(line) then t.part = nil; return end
	local mark, body = line:match("^%s*[%-%*]%s+%[([ xX])%]%s+(.+)$")
	local state = if mark then (if mark:lower() == "x" then "done" else "pending") else nil
	if not body then body = line:match("^%s*%d+[%.%)]%s+(.+)$") or line:match("^%s*[%-%*]%s+(.+)$") end
	if not body then return end
	if t.part == "files" then
		local action, path = body:match("^(%u+)%s+(.+)$")
		local paths, bad = paths_in(path or body)
		if bad then flag(t.flags, "file_unparsed") end
		for _, p in paths do
			if #t.filechanges < M.MAX_FILES then
				table.insert(t.files, p)
				table.insert(t.filechanges, { id = identity("file", t.id, (action or "") .. "\n" .. p), path = p, action = if ACTIONS[action] then action else "UPDATE", state = state })
			end
		end
	elseif t.part == "checks" then
		if #t.validationchecks >= M.MAX_CHECKS then flag(t.flags, "checks_truncated"); return end
		local cmd = validate_command(body, true)
		local argv = if cmd then M.split_argv(cmd) else nil
		local id = identity("check", t.id, body)
		table.insert(t.validationchecks, { id = id, text = body, argv = argv, state = state })
		if argv and #t.checks < M.MAX_CHECKS then table.insert(t.checks, { check_id = id, argv = argv }) end
	elseif mark or t.part == "steps" then
		if #t.steps >= 256 then flag(t.flags, "steps_truncated"); return end
		table.insert(t.steps, { id = identity("step", t.id, body), text = body, state = state })
	end
end

-- parse(bytes) -> plan | nil, problem{ok=false, code, message}
function M.parse(bytes: any): (any, any)
	if type(bytes) ~= "string" then return nil, problem("invalid_input", "Plan bytes must be a string.") end
	if #bytes > M.MAX_BYTES then return nil, problem("too_large", "Plan file exceeds 1 MiB.") end
	if utf8.len(bytes) == nil or bytes:find("%z") then return nil, problem("invalid_input", "Plan file is not NUL-free UTF-8.") end
	local split, ruling_problem = M.split_rulings(bytes)
	if not split then return nil, ruling_problem end
	bytes = split.content
	local states, state_problem = session_states(bytes)
	if not states then return nil, state_problem end
	local title, home = nil, nil
	local checkpoints, plan_flags, seen_ids, action_groups = {}, {}, {}, {}
	local checkpoint, task, section, fence = nil, nil, nil, nil
	local tasks, session, checkpoint_level, fence_size = 0, false, 0, 0
	local function close_task()
		if task then
			if checkpoint.session and type(checkpoint.session.tasks) == "table" then
				for _, row in ipairs(checkpoint.session.tasks) do
					if type(row) == "table" and row.id == task.id and STATES[row.state] then task.state = row.state end
				end
			end
			task.part, task.action_owned = nil, nil
			table.insert(checkpoint.tasks, task); task = nil
		end
	end
	local function close_checkpoint()
		close_task()
		if checkpoint then
			checkpoint.session = nil
			if #checkpoint.tasks == 0 then flag(checkpoint.flags, "no_tasks") end
			table.insert(checkpoints, checkpoint); checkpoint = nil
		end
	end
	local function begin_task(id: string, name: string, line: string): any?
		if seen_ids[id] then return problem("duplicate_task", "Task identity repeats for '" .. name .. "' (" .. id .. "). Give ambiguous work distinct explicit Task ids before adding it.") end
		if tasks >= M.MAX_TASKS then return problem("too_many_tasks", "A plan may hold at most 64 tasks.") end
		close_task(); seen_ids[id] = true; tasks += 1; task = new_task(id, name, line)
		return nil
	end
	for _, raw in bytes:split("\n") do
		local line = raw:gsub("\r$", "")
		if line == "<!-- TERN-SESSION:START -->" and not fence then session = true; continue end
		if session then if line == "<!-- TERN-SESSION:END -->" then session = false end; continue end
		local fenced
		fence, fence_size, fenced = advance_fence(line, fence, fence_size)
		local level, text = nil, nil
		if not fenced then level, text = heading(line) end
		local n, cp_title = nil, nil
		if level and section ~= "Progress" then n, cp_title = checkpoint_header(text) end
		if n and checkpoint and level > checkpoint_level and not text:lower():match("^checkpoint%s") then n, cp_title = nil, nil end
		if n then
			if not cp_title then return nil, problem("checkpoint_header_invalid", "Checkpoint heading needs a number and title: " .. line) end
			close_checkpoint()
			local last = checkpoints[#checkpoints]
			if last and n <= last.n then return nil, problem("checkpoint_order", "Checkpoint numbers must strictly increase: " .. line) end
			if #checkpoints >= M.MAX_CHECKPOINTS then return nil, problem("too_many_checkpoints", "A plan may hold at most 30 checkpoints.") end
			checkpoint = { id = identity("checkpoint", "", normalized(cp_title)), n = n, title = cp_title, tasks = {}, flags = {} }
			checkpoint_level = level
			local matched = {}
			for _, row in ipairs(states) do
				if row.text and (normalized(row.text) == normalized(text) or normalized(row.text) == normalized(cp_title)) then table.insert(matched, row) end
			end
			if #matched == 0 then
				for _, row in ipairs(states) do
					local label = if row.text then checkpoint_header(row.text) else nil
					if label == n then table.insert(matched, row) end
				end
			end
			if #matched == 0 then
				for _, row in ipairs(states) do if normalized(row.id) == "cp" .. tostring(n) then table.insert(matched, row) end end
			end
			if #matched > 1 then return nil, problem("session_invalid", "Checkpoint matches multiple explicit session states.") end
			if #matched == 1 then checkpoint.id, checkpoint.state, checkpoint.session = matched[1].id, matched[1].state, matched[1] end
			continue
		end
		if level and level <= 2 and not action_target(line) then
			close_checkpoint(); section = if level == 2 then text else nil
			if level == 1 and not title then title = text:match("^Feature:%s*(.+)$") end
			continue
		end
		if section == "Progress" then continue end
		if section == "Build choices" and not fenced then
			local h = line:match("^home:%s*(.-)%s*$")
			if h then if home ~= nil then flag(plan_flags, "home_ambiguous") else home = h end end
		end
		local task_id, task_title = nil, nil
		if checkpoint and level and text:match("^Task%s+") and normalized(text) ~= "task format guidelines" then
			local id, rest = text:match("^Task%s+(%S+)%s+(.+)$")
			task_title = if rest then dash_title(rest) else nil
			if task_title then task_id = id
			elseif id and id:find("%d") then return nil, problem("task_header_invalid", "Task id needs a dash and title: " .. line)
			else
				task_title = trim(text:sub(5):gsub("^[:%-]%s*", ""))
				task_title = dash_title(task_title) or task_title
				task_id = identity("task", checkpoint.id, normalized(task_title))
			end
		elseif checkpoint and level then
			local id, rest = text:match("^(%S+)%s+(.+)$")
			if id and id:match("^[A-Za-z]*%d+[A-Za-z0-9_%-]*$") then
				task_title = dash_title(rest) or (if id:match("^[Cc][Pp]?%d") then trim(rest) else nil)
				if task_title then task_id = id end
			end
		end
		if task_id then
			if #task_id > M.MAX_TASK_ID or not task_id:match("^[A-Za-z0-9_%-]+$") then return nil, problem("task_id_invalid", "Task IDs are 1-32 letters, digits, '_' or '-': " .. line) end
			local err = begin_task(task_id, task_title, line); if err then return nil, err end
			local declared_action = task_title:match("^(%u+)%s")
			if declared_action and ACTIONS[declared_action] then task_line(task, "### " .. task_title, false) end
			continue
		end
		local target = action_target(line)
		if checkpoint and target and not fenced and (not task or task.action_owned) then
			local declared = paths_in(target)
			local declared_identity = if #declared > 0 then table.concat(declared, "\n") else target
			local base = identity("file", checkpoint.id, (line:match("^#+%s+(%u+)") or "") .. "\n" .. declared_identity)
			local group = action_groups[base] or {}; action_groups[base] = group
			local occurrence = #group + 1
			local id = base .. (if occurrence > 1 then "-" .. tostring(occurrence) else "")
			local err = begin_task(id, line:gsub("^#+%s+", ""), line); if err then return nil, err end
			table.insert(group, task); task.action_owned = true
			local declaration = line:gsub("`[^`]*`", "")
			for _, dash in ipairs(DASHES) do
				local start = declaration:find(" " .. dash .. " ", 1, true)
				if start then
					local marker = trim(declaration:sub(start + #dash + 2))
					if marker == "INDEPENDENT" or marker:match("^INDEPENDENT[%s%.]") or marker:match("^%*%*INDEPENDENT%*%*") then task.marker_independent = true end
				end
			end
			task_line(task, line, fenced)
			continue
		end
		if task then
			table.insert(task.lines, line)
			task_line(task, line, fenced)
			if not fenced then concrete_line(task, line) end
		end
	end
	close_checkpoint()
	if not title then return nil, problem("no_title", "Plan has no '# Feature: <title>' heading.") end
	if #checkpoints == 0 then return nil, problem("no_checkpoints", "Plan declares no supported Checkpoint, CP or C sections.") end
	local project_hint, home_prefix = nil, nil
	if home and not table.find(plan_flags, "home_ambiguous") then
		local kind, name = home:match("^(%a+):([%w%._%-]+)$")
		if kind and HOME_KINDS[kind] then
			project_hint = { kind = kind, name = name }
			if kind == "workspace" then home_prefix = "workspaces/" .. name .. "/" end
		else flag(plan_flags, "home_invalid") end
	end
	for _, cp in ipairs(checkpoints) do for _, t in ipairs(cp.tasks) do
		finish_task(t, home_prefix); t.source_identity = M.task_identity(cp, t)
	end end
	for base, group in pairs(action_groups) do
		if #group < 2 then continue end
		local counts, occurrences = {}, {}
		for _, t in ipairs(group) do counts[t.source_identity] = (counts[t.source_identity] or 0) + 1 end
		for _, t in ipairs(group) do
			local semantic = t.source_identity
			occurrences[semantic] = (occurrences[semantic] or 0) + 1
			local id = identity("file", base, semantic)
			if counts[semantic] > 1 then
				t.identity_ambiguous = true; flag(t.flags, "identity_ambiguous")
				id ..= if occurrences[semantic] > 1 then "-" .. tostring(occurrences[semantic]) else ""
			end
			rekey_task(t, id)
		end
	end
	local by_id, cp_ids = {}, {}
	for _, cp in ipairs(checkpoints) do
		if cp_ids[cp.id] then return nil, problem("checkpoint_identity_ambiguous", "Checkpoint titles need distinct semantic identities or explicit TERN-SESSION ids.") end
		cp_ids[cp.id] = true
		for _, t in ipairs(cp.tasks) do
			if by_id[t.id] then return nil, problem("duplicate_task", "Task identities collide; use distinct explicit Task ids.") end
			if table.find(t.flags, "state_invalid") then return nil, problem("state_invalid", "Task has an unsupported explicit state.") end
			for _, field in ipairs({ "steps", "filechanges", "validationchecks" }) do
				local seen = {}
				for _, node in ipairs(t[field]) do
					local value = if field == "filechanges" then node.path else node.text
					if #value > (if field == "filechanges" then M.MAX_FILE_BYTES else 4096) then
						return nil, problem("hierarchy_invalid", "A declared step, file change or validation check exceeds its source bound.")
					end
					local occurrence = seen[node.id] or 0; seen[node.id] = occurrence + 1
					if occurrence > 0 then node.id = identity("item", node.id, tostring(occurrence + 1)) end
				end
			end
			by_id[t.id] = t
		end
	end
	local edges, earlier_checkpoints = {}, {}
	for _, cp in ipairs(checkpoints) do
		local earlier = {}
		for _, t in ipairs(cp.tasks) do
			local dependencies = table.clone(earlier_checkpoints)
			for _, predecessor in ipairs(earlier) do
				if not t.independent or not predecessor.independent then table.insert(dependencies, predecessor.id) end
			end
			for _, id in ipairs(t.depends_on or {}) do table.insert(dependencies, id) end
			edges[t.id] = dependencies; table.insert(earlier, t)
		end
		for _, t in ipairs(cp.tasks) do table.insert(earlier_checkpoints, t.id) end
	end
	local visiting, visited = {}, {}
	local function visit(id: string): boolean
		if visiting[id] or not by_id[id] then return false end
		if visited[id] then return true end
		visiting[id] = true
		if #(by_id[id].depends_on or {}) > M.MAX_TASKS then return false end
		for _, dependency in ipairs(edges[id]) do if not visit(dependency) then return false end end
		visiting[id], visited[id] = nil, true
		return true
	end
	for id in pairs(by_id) do if not visit(id) then return nil, problem("dependency_invalid", "Task dependencies must refer to existing tasks without cycles.") end end
	return { title = title, plan_revision = codec.sha256(bytes), project_hint = project_hint, flags = plan_flags, checkpoints = checkpoints }, nil
end

return M
