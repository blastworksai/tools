--!strict
-- Source discovery/transformation only. IO is injected; native board effects belong to the window.
local parser = require("./plan_import")
local codec = require("./wire/codec")
local quota = require("./quota")
local protocol = require("./dispatch_protocol")
local M = {}
local function hash(bytes: string, yield_step: (() -> ())?): string
	if not yield_step then return codec.sha256(bytes) end
	local state = codec.sha256_begin()
	codec.sha256_feed(state, bytes)
	repeat
		local drained = codec.sha256_step(state, 32)
		yield_step()
	until drained
	return codec.sha256_digest(state)
end
local function problem(code: string, message: string): any
	return { ok = false, code = code, message = message }
end
local function text(v: any, max: number): boolean
	return type(v) == "string" and #v > 0 and #v <= max and utf8.len(v) ~= nil and not v:find("%z")
end
local function valid_text(v: any): boolean
	return type(v) == "string" and v ~= "" and not v:find("[%c]", 1)
end
local function slug(v: any): boolean
	return valid_text(v) and v:match("^[a-z0-9][a-z0-9%-]*$") ~= nil
end
local function class(v: any): boolean
	return text(v, 32) and v:match("^[a-z][a-z0-9%-]*$") ~= nil
end
local function child(root: string, name: string): string
	return root .. (if root:sub(-1) == "/" then "" else "/") .. name
end
-- Absolute host/desktop paths, with an optional actual-machine OS guard. A '..'
-- segment is refused; ordinary dotted directory names are not traversal.
function M.normalize_root(value: any, host_os: string?): string?
	if type(value) ~= "string" or value == "" or value:find("[%c]", 1) then return nil end
	local windows_path = value:match("^%a:[\\/]") ~= nil or value:sub(1, 2) == "\\\\"
	local windows = host_os == "windows" or (host_os == nil and windows_path)
	local root = if windows then value:gsub("\\", "/") else value
	if root:sub(1, 1) ~= "/" and (not windows or root:match("^%a:/") == nil) then return nil end
	for segment in root:gmatch("[^/]+") do if segment == ".." then return nil end end
	root = root:gsub("/+$", "")
	if root == "" then return "/" end
	if windows and root:match("^%a:$") then return root .. "/" end
	return root
end
local function object(value: any, encode: any): boolean
	if type(value) ~= "table" then return false end
	local empty = true
	for key in pairs(value) do if type(key) ~= "string" then return false end; empty = false end
	if not empty then return true end
	local ok, bytes = pcall(encode, value)
	return ok and bytes == "{}"
end
-- Exact WORK/projects.decode_registry filtering, path construction and ordering;
-- no launch-agent configuration is read or required.
function M.decode_registry(value: any, root: string, encode: any): (any?, any?)
	if not object(value, encode) or not object(value.workspaces, encode) then
		return nil, problem("registry_invalid", "Workspace registry is invalid.")
	end
	if not valid_text(root) then return nil, problem("registry_invalid", "Workspace registry root is invalid.") end
	local catalog: any = { root = root, items = {} }
	for key, entry in pairs(value.workspaces) do
		if slug(key) and type(entry) == "table" and entry.status == "active" and slug(entry.path) then
			local remote = if type(entry.remote) == "string" and entry.remote:match("^https://github%.com/[^%s%c\"'<>]+$") then entry.remote:gsub("%.git$", "") else nil
			table.insert(catalog.items, { id = key, name = key, kind = if valid_text(entry.kind) then entry.kind else "workspace",
				path = child(root, "workspaces/" .. entry.path), remote = remote })
		end
	end
	table.sort(catalog.items, function(a, b)
		local left, right = a.name:lower(), b.name:lower()
		return if left == right then a.id < b.id else left < right
	end)
	return catalog, nil
end
function M.load_projects(root: any, host_os: string?, io: any): (any?, any?)
	local normalized = M.normalize_root(root, host_os)
	if not normalized then return nil, problem("root_invalid", "Choose an absolute Glitch root on the execution host without '..'.") end
	local ok, bytes = pcall(io.read, child(normalized, "workspaces/registry.json"), 4 * 1024 * 1024)
	if not ok or type(bytes) ~= "string" or #bytes > 4 * 1024 * 1024 then return nil, problem("registry_unreadable", "Could not read the execution host's workspace registry.") end
	local decoded, value = pcall(io.decode, bytes)
	if not decoded then return nil, problem("registry_invalid", "Workspace registry is not valid JSON.") end
	return M.decode_registry(value, normalized, io.encode)
end
function M.discover_plans(catalog: any, files: {any}): any
	local result: any = { items = {}, rejected = {} }
	local seen = {}
	for _, file in ipairs(files) do
		local name = file.name
		if type(name) ~= "string" or name:find("[%c/\\]") or name:sub(1, 1) == "." or name:sub(-3):lower() ~= ".md" or name:lower():sub(-11) == "-archive.md" then continue end
		if seen[name] then
			table.insert(result.rejected, { name = name, code = "duplicate_path", message = "Plan listing contains the same path twice." })
			for index = #result.items, 1, -1 do if result.items[index].path == child(catalog.root, "plans/" .. name) then table.remove(result.items, index) end end
			continue
		end
		seen[name] = true
		local plan, err = parser.parse(file.bytes)
		if not plan then table.insert(result.rejected, { name = name, code = err.code, message = err.message }); continue end
		local matches = {}
		if plan.project_hint and plan.project_hint.kind == "workspace" and not table.find(plan.flags, "home_ambiguous") then
			for _, item in ipairs(catalog.items) do if item.id == plan.project_hint.name then table.insert(matches, item) end end
		end
		table.insert(result.items, { path = child(catalog.root, "plans/" .. name), title = plan.title, revision = plan.plan_revision,
			plan = plan, workspace_id = if #matches == 1 then matches[1].id else nil, needs_project_choice = #matches ~= 1 })
	end
	table.sort(result.items, function(a, b) return if a.title == b.title then a.path < b.path else a.title < b.title end)
	return result
end
function M.read_plan(path: any, expected_revision: string?, io: any): (any?, any?)
	if not M.normalize_root(path, io.host_os or tern.runtime.os) then return nil, problem("path_invalid", "Plan selection must name an absolute path on the actual execution host.") end
	local ok, bytes = pcall(io.read, path, parser.MAX_BYTES)
	if not ok then return nil, problem("plan_unreadable", "Could not read the selected execution-host plan.") end
	local plan, err = parser.parse(bytes)
	if not plan then return nil, err end
	if expected_revision and expected_revision ~= plan.plan_revision then return nil, problem("source_changed", "Plan changed since selection; inspect the current plan before adding it.") end
	return { kind = "plan_file", path = path, revision = plan.plan_revision, plan = plan }, nil
end
function M.class_choices(plans: {any}, templates: {any}?): {any}
	local counts = {}
	local function add(value: any)
		if class(value) then counts[value] = (counts[value] or 0) + 1 end
	end
	for _, plan in ipairs(plans) do for _, cp in ipairs(plan.checkpoints) do for _, task in ipairs(cp.tasks) do add(task.class) end end end
	for _, template in ipairs(templates or {}) do add(template.class) end
	local choices = {}
	for id, count in pairs(counts) do
		local label = id:gsub("%-", " "); label = label:sub(1, 1):upper() .. label:sub(2)
		table.insert(choices, { id = id, label = label, count = count })
	end
	table.sort(choices, function(a, b) return a.id < b.id end)
	return choices
end
local MIRROR = "orchplus-plan-mirror"
local PROVENANCE = "orchplus-source-"
local BASE = "orchplus-base-"
local REVISION = "orchplus-revision-"
local LINK_PREFIX = "tern://orchplus-plan?"
local KINDS = { plan = true, checkpoint = true, task = true, step = true, file = true, check = true, history = true }
local function encoded(value: string): string
	return value:gsub("[^%w%-_%.~]", function(byte) return string.format("%%%02X", string.byte(byte)) end)
end
local function decoded(value: string): string?
	if value:gsub("%%[%x][%x]", ""):find("%", 1, true) then return nil end
	return value:gsub("%%(%x%x)", function(byte) return string.char(tonumber(byte, 16) :: number) end)
end
local function hex(value: any, size: number): boolean
	return type(value) == "string" and #value == size and value:match("^[a-f0-9]+$") ~= nil
end
-- This is a real first-party navigation locator, not a hidden HTML/tag channel.
-- Only the native link label is displayed; the address binds its source and view.
function M.plan_link_base(scope: string, path: string, board_key: string?): string
	return LINK_PREFIX .. "scope=" .. scope .. "&path=" .. encoded(path) .. (if board_key then "&board=" .. board_key else "")
end
function M.parse_plan_link(url: any): any?
	if not text(url, 20000) or url:sub(1, #LINK_PREFIX) ~= LINK_PREFIX then return nil end
	local fields = {}
	for pair in (url:sub(#LINK_PREFIX + 1) .. "&"):gmatch("(.-)&") do
		local key, value = pair:match("^([a-z]+)=([^&]*)$")
		if not key or fields[key] ~= nil then return nil end
		fields[key] = value
	end
	local path = if fields.path then decoded(fields.path) else nil
	if not hex(fields.scope, 24) or not path or not M.normalize_root(path) or (fields.board and not hex(fields.board, 64)) then return nil end
	local nav = M.plan_link_base(fields.scope, path, fields.board)
	if fields.projection == nil then
		if nav ~= url then return nil end
		return { scope = fields.scope, path = path, board_key = fields.board, nav_url = nav }
	end
	local node = if fields.node then decoded(fields.node) else nil
	if fields.projection ~= "2" or not fields.board or not text(node, 256) or not node:match("^[A-Za-z0-9_%-]+$")
		or not KINDS[fields.kind] or not hex(fields.base, 64) or not hex(fields.rev, 64)
		or not table.find({ "none", "true", "false" }, fields.done) or not table.find({ "0", "1" }, fields.retired) then return nil end
	local canonical = nav .. "&projection=2&node=" .. encoded(node) .. "&kind=" .. fields.kind .. "&base=" .. fields.base
		.. "&rev=" .. fields.rev .. "&done=" .. fields.done .. "&retired=" .. fields.retired
	if canonical ~= url then return nil end
	return { projection = 2, scope = fields.scope, path = path, board_key = fields.board, nav_url = nav, node_id = node,
		kind = fields.kind, baseline = fields.base, revision = fields.rev,
		done = if fields.done == "none" then nil else fields.done, retired = fields.retired == "1", url = url }
end
local function projection_links(value: string): {any}
	local links = {}
	for first, label, url, after in value:gmatch("()%[([^%]]*)%]%((tern://orchplus%-plan%?[^%s%)]+)%)()") do
		local link = M.parse_plan_link(url)
		if link and link.projection == 2 then
			link.first, link.after, link.label = first, after, label; table.insert(links, link)
		end
	end
	return links
end
function M.is_plan_mirror(tags: any, card_text: string?): boolean
	if card_text then
		-- Malformed/edited projection addresses must not become independent jobs.
		for url in card_text:gmatch("tern://orchplus%-plan%?[^%s]+") do
			if url:match("[?&]projection=") then return true end
		end
	end
	if type(tags) ~= "table" then return false end
	for _, tag in pairs(tags) do
		if type(tag) == "string" and (tag == MIRROR or tag:sub(1, #PROVENANCE) == PROVENANCE or tag:sub(1, #BASE) == BASE
			or tag:sub(1, #REVISION) == REVISION or tag:sub(1, 14) == "orchplus-kind-" or tag:sub(1, 14) == "orchplus-done-" or tag == "orchplus-retired") then return true end
	end
	return false
end
local function reserved(tag: string): boolean
	return tag == MIRROR or tag:sub(1, #PROVENANCE) == PROVENANCE or tag:sub(1, #BASE) == BASE or tag:sub(1, #REVISION) == REVISION
end
local function board_cards(snapshot: any, yield_step: (() -> ())?, maximum: number?): (any?, any?)
	if type(snapshot) ~= "table" or not text(snapshot.path, protocol.DESKTOP_BOARD_PATH_BYTES) or snapshot.phase == "failed" or snapshot.phase == "loading"
		or snapshot.more ~= 0 or type(snapshot.lanes) ~= "table" then
		return nil, problem("board_incomplete", "Read the complete desktop board before importing or mirroring tasks.")
	end
	local cards, ids = {}, {}
	for _, lane in ipairs(snapshot.lanes) do
		if type(lane) ~= "table" or lane.more ~= 0 or type(lane.cards) ~= "table" then return nil, problem("board_incomplete", "Board contains unread cards.") end
		for _, card in ipairs(lane.cards) do
			if yield_step then yield_step() end
			if type(card) ~= "table" or not text(card.id, protocol.NATIVE_BOARD_ID_BYTES) or not text(card.text, 32768 + 64 * 257) or type(card.tags) ~= "table" or type(card.done) ~= "boolean" or ids[card.id] then
				return nil, problem("board_invalid", "Board cards must have unique native IDs, text, tags and completion state.")
			end
			if card.text_clipped == true then return nil, problem("board_incomplete", "A native board card description was clipped; its full text is required before synchronization.") end
			if #card.tags > 64 then return nil, problem("board_invalid", "Board card has too many tags.") end
			for _, tag in ipairs(card.tags) do if not text(tag, 256) then return nil, problem("board_invalid", "Invalid board tag.") end end
			ids[card.id] = true; table.insert(cards, card)
			if #cards > (maximum or 4096) then return nil, problem("board_too_large", "The complete board exceeds the supported card bound (" .. tostring(maximum or 4096) .. ").") end
		end
	end
	return cards, nil
end
function M.board_intakes(snapshot: any, yield_step: (() -> ())?): (any?, any?)
	local cards, err = board_cards(snapshot, yield_step)
	if not cards then return nil, err end
	local out, seen = {}, {}
	for _, card in ipairs(cards) do
		if yield_step then yield_step() end
		if card.done or M.is_plan_mirror(card.tags, card.text) then continue end
		if #card.text > 4096 or not card.text:find("%S") then return nil, problem("card_too_large", "Independent board tasks need nonblank text of at most 4096 bytes.") end
		local digest = hash(quota.canonical({ text = card.text, tags = card.tags }), yield_step)
		if not seen[digest] then
			seen[digest] = true
			local tags = tern.json.array(); for i, tag in ipairs(card.tags) do tags[i] = tag end
			table.insert(out, { card_id = card.id, text = card.text, tags = tags, text_sha256 = digest })
		end
	end
	return out, nil
end
function M.template_source(template: any, revision: any, input: any, custom_fields: any?): (any?, any?)
	local allowed = { id = true, title = true, prompt = true, output = true, next = true, class = true, custom_fields = true }
	if type(template) ~= "table" then return nil, problem("template_invalid", "Choose a saved template.") end
	for key in pairs(template) do if not allowed[key] then return nil, problem("template_invalid", "Unknown template field.") end end
	if not class(template.id) or not text(template.title, 80) or not text(template.prompt, 4096)
		or not text(template.output, 256) or template.output:sub(1, 1) == "/" or template.output:sub(1, 1) == "\\" or template.output:match("^%a:")
		or (template.class ~= nil and not class(template.class))
		or not (template.next == "" or (class(template.next) and template.next ~= template.id)) then
		return nil, problem("template_invalid", "Template does not match the supported saved-template schema.")
	end
	for segment in template.output:gmatch("[^/\\]+") do if segment == ".." then return nil, problem("template_invalid", "Template output must remain relative.") end end
	local defaults, values, overrides, count = template.custom_fields or {}, {}, {}, 0
	if type(defaults) ~= "table" or (custom_fields ~= nil and type(custom_fields) ~= "table") then return nil, problem("template_invalid", "Template fields must be named values.") end
	for name, default in pairs(defaults) do
		count += 1
		if not class(name) or name == "input" or type(default) ~= "string" or #default > 2048 or utf8.len(default) == nil or default:find("%z") or count > 16 then
			return nil, problem("template_invalid", "Template has an invalid custom field.")
		end
		values[name] = default
	end
	for name, value in pairs(custom_fields or {}) do
		if defaults[name] == nil or type(value) ~= "string" or #value > 2048 or utf8.len(value) == nil or value:find("%z") then return nil, problem("input_invalid", "Unknown or invalid template field.") end
		values[name], overrides[name] = value, value
	end
	local _, inputs = template.prompt:gsub("{input}", "")
	if inputs ~= 1 then return nil, problem("template_invalid", "Template prompt needs exactly one {input} placeholder.") end
	for name in (template.prompt .. "\n" .. template.output):gmatch("{([^{}]+)}") do
		if name ~= "input" and defaults[name] == nil then return nil, problem("template_invalid", "Template references an unknown field.") end
	end
	if revision ~= quota.digest(template) then return nil, problem("source_changed", "Saved template changed since selection.") end
	if not text(input, protocol.SOURCE_INPUT_BYTES) or not input:find("%S") then return nil, problem("input_invalid", "Template input must be nonblank text of at most " .. tostring(protocol.SOURCE_INPUT_BYTES) .. " bytes.") end
	local output = template.output:gsub("{([^{}]+)}", function(name) return if name == "input" then input else values[name] end)
	if #output > 256 or output == "" or output:find("[%c]") or output:sub(1, 1) == "/" or output:sub(1, 1) == "\\" or output:match("^%a:") then
		return nil, problem("input_invalid", "Expanded template output must be a relative file path.")
	end
	for segment in output:gmatch("[^/\\]+") do if segment == ".." then return nil, problem("input_invalid", "Expanded template output must remain relative.") end end
	return { kind = "template", template_id = template.id, revision = revision, input = input, custom_fields = overrides }, nil
end
local DONE = "orchplus-done-"
local function generated_tags(tag: string): boolean
	return reserved(tag) or tag:sub(1, #DONE) == DONE or tag:sub(1, 14) == "orchplus-kind-" or tag == "orchplus-retired"
end
-- Migration-only reader for the old controlled hash footer. New native text-only
-- writes keep provenance in the source URL, preserving body hashtags.
local function legacy_representation(card: any, yield_step: (() -> ())?): any?
	local delimiter, from, boundary = " #" .. MIRROR .. " ", 1, nil
	while true do
		local at = card.text:find(delimiter, from, true)
		if not at then break end
		boundary, from = at, at + 1
	end
	if not boundary then return nil end
	local result: any = { body = card.text:sub(1, boundary - 1), extras = {} }
	local known, seen, count = {}, {}, 0
	for _, tag in ipairs(card.tags) do known[tag] = true end
	for token in card.text:sub(boundary + 1):gmatch("%S+") do
		count += 1
		local tag = token:sub(2)
		if count > 64 or token:sub(1, 1) ~= "#" or not known[tag] then return nil end
		local key, value
		if tag == MIRROR then key, value = "mirror", true
		elseif tag:sub(1, #PROVENANCE) == PROVENANCE then key, value = "source_tag", tag
		elseif tag:sub(1, #BASE) == BASE then key, value = "baseline", tag:sub(#BASE + 1)
		elseif tag:sub(1, #REVISION) == REVISION then key, value = "revision", tag:sub(#REVISION + 1)
		elseif tag:sub(1, #DONE) == DONE then
			key, value = "done", tag:sub(#DONE + 1)
			if value ~= "true" and value ~= "false" then return nil end
		elseif tag:sub(1, 14) == "orchplus-kind-" then key, value = "kind", tag:sub(15)
		elseif tag == "orchplus-retired" then key, value = "retired", true
		else table.insert(result.extras, tag) end
		if key then
			if seen[key] then return nil end
			seen[key], result[key] = true, value
		end
	end
	if not result.mirror or not result.source_tag or not result.baseline or not result.revision
		or #result.baseline ~= 64 or not result.baseline:match("^[a-f0-9]+$")
		or #result.revision ~= 64 or not result.revision:match("^[a-f0-9]+$") or (result.kind and not KINDS[result.kind]) then return nil end
	result.legacy = true
	result.untouched = result.baseline == hash(result.body, yield_step)
	return result
end
local function projection_representation(card: any, link: any, yield_step: (() -> ())?): any
	local result = table.clone(link)
	local prefix = card.text:sub(1, link.first - 1)
	local separator = " · "
	local canonical_prefix = prefix:sub(-#separator) == separator
	result.body = if canonical_prefix then prefix:sub(1, #prefix - #separator) else prefix
	result.extras = {}
	local known, suffix_valid = {}, true
	for _, tag in ipairs(card.tags) do known[tag] = true end
	for token in card.text:sub(link.after):gmatch("%S+") do
		local tag = token:sub(2)
		if token:sub(1, 1) ~= "#" or not known[tag] then suffix_valid = false; break end
		table.insert(result.extras, tag)
	end
	result.untouched = canonical_prefix and (link.label == "Source plan" or link.label == "Open plan") and suffix_valid and result.baseline == hash(result.body, yield_step)
	return result
end
local function native_text(body: string, nav: string, node: string, baseline: string, revision: string, kind: string, done: boolean?, extras: {string}, retired: boolean?): string
	local url = nav .. "&projection=2&node=" .. encoded(node) .. "&kind=" .. kind .. "&base=" .. baseline
		.. "&rev=" .. revision .. "&done=" .. (if done == nil then "none" else tostring(done)) .. "&retired=" .. (if retired then "1" else "0")
	local parts = { body, "· [Source plan](" .. url .. ")" }
	for _, tag in ipairs(extras) do table.insert(parts, "#" .. tag) end
	return table.concat(parts, " ")
end
local function preview(value: string, maximum: number): string
	local single = value:gsub("[\r\n]", " · ")
	local cut = utf8.offset(single, maximum + 1)
	return if cut then single:sub(1, cut - 1) .. "…" else single
end
local function task_description(task: any): string
	local lines, fence = {}, nil
	for _, raw in ipairs(task.text:split("\n")) do
		local line = raw:match("^%s*(.-)%s*$") :: string
		local marker = line:match("^(```+)") or line:match("^(~~~+)")
		if marker then
			if not fence then fence = marker elseif marker:sub(1, 1) == fence:sub(1, 1) and #marker >= #fence then fence = nil end
			continue
		end
		if fence or line:match("^#+%s") or line:match("^%*%*INDEPENDENT%*%*") or line:match("^[%-%*]?%s*%*%*[%u_]+%*%*:")
			or line:match("^[%-%*]?%s*[%u_]+:") then continue end
		if line == "" then if #lines > 0 then break end; continue end
		if line:match("^[%-%*]%s+%[[ xX]%]") then break end
		table.insert(lines, line)
	end
	return preview(table.concat(lines, " "), 160)
end
-- Native boards are flat cards and lanes, not an imaginary editable nested tree.
-- Human card content stays compact. Machine provenance lives in the source
-- locator; only its native link label is displayed. All edits remain text-only.
-- Only task nodes remain executable in the host graph.
function M.plan_to_board(plan: any, path: string, snapshot: any, lane: string, yield_step: (() -> ())?, source_url: string?): (any?, any?)
	if not M.normalize_root(path, nil) or not text(lane, 256) then return nil, problem("source_invalid", "Select a plan path and destination lane.") end
	local cards, err = board_cards(snapshot, yield_step, 32768)
	if not cards then return nil, err end
	local navigation = M.parse_plan_link(source_url)
	if not navigation or navigation.projection or navigation.path ~= path or navigation.board_key ~= hash(snapshot.path, yield_step) then
		return nil, problem("source_invalid", "Plan presentation needs its current scoped desktop-board navigation locator.")
	end
	local path_digest = hash(path, yield_step)
	local prefix = PROVENANCE .. path_digest .. "-"
	local indexed, source_cards, representations, legacy_cards = {}, {}, {}, {}
	for _, card in ipairs(cards) do
		if yield_step then yield_step() end
		local links = projection_links(card.text)
		if #links > 0 then
			for _, link in ipairs(links) do
				if link.path ~= path or link.scope ~= navigation.scope then continue end
				local id = link.node_id
				indexed[id] = indexed[id] or {}; table.insert(indexed[id], card)
				table.insert(source_cards, { task_id = id, card_id = card.id })
				if #links == 1 then
					local representation = projection_representation(card, link, yield_step)
					representation.source_tag = prefix .. id
					representation.untouched = representation.untouched and link.board_key == navigation.board_key
					representations[card.id] = representation
				end
			end
		else
			legacy_cards[card.id] = M.is_plan_mirror(card.tags)
			if M.is_plan_mirror(nil, card.text) then
				return nil, problem("projection_invalid", "A linked card's source address was edited or is malformed. Restore its genuine link or choose a separate board; no card was overwritten or imported.")
			end
			-- Migration reader only. A valid old BASE proves the old full description;
			-- edited legacy cards keep their content until the owner makes a decision.
			local representation = legacy_representation(card, yield_step)
			representations[card.id] = representation
			for _, tag in ipairs(card.tags) do
				if tag:sub(1, #prefix) == prefix and (not representation or representation.source_tag == tag) then
					local id = tag:sub(#prefix + 1)
					indexed[id] = indexed[id] or {}; table.insert(indexed[id], card)
					table.insert(source_cards, { task_id = id, card_id = card.id })
				end
			end
		end
	end
	local nodes, present, titles = {}, {}, {}
	local overview_lane = lane
	local function add(id: string, kind: string, title: string, parent: string?, body: string?, state: string?, destination: string?)
		if yield_step then yield_step() end
		local label = if kind == "step" then "Step: " elseif kind == "file" then "File: " elseif kind == "check" then "Check: " else ""
		local parts = { label .. preview(title, 96) }
		if parent then
			table.insert(parts, (if kind == "step" or kind == "file" or kind == "check" then "Task: " else "Within: ") .. preview(titles[parent], 72))
		end
		if state == "blocked" then table.insert(parts, "Blocked")
		elseif state == "paused" then table.insert(parts, "Paused")
		elseif state == "active" then table.insert(parts, "In progress") end
		if body and body ~= "" then table.insert(parts, preview(body, 160)) end
		local generated = table.concat(parts, " · ")
		table.insert(nodes, { id = id, kind = kind, text = generated, state = state, lane = destination or overview_lane })
		present[id] = true
		titles[id] = title
	end
	-- Administrative identities are longer than any executable task id. Adding a
	-- user task named 'plan' can never rebind a retained plan/checkpoint mirror.
	local plan_id = "plan-structure-" .. path_digest:sub(1, 24)
	local cp_ids = {}
	for _, cp in ipairs(plan.checkpoints) do table.insert(cp_ids, "checkpoint-structure-" .. hash(cp.id or tostring(cp.n), yield_step):sub(1, 24)) end
	local count, task_titles = 0, {}
	for _, cp in ipairs(plan.checkpoints) do for _, task in ipairs(cp.tasks) do count += 1; task_titles[task.id] = task.title end end
	local overview = tostring(#plan.checkpoints) .. (if #plan.checkpoints == 1 then " checkpoint" else " checkpoints")
		.. " · " .. tostring(count) .. (if count == 1 then " task" else " tasks")
	add(plan_id, "plan", plan.title, nil, overview, nil)
	local previous = {}
	for cp_index, cp in ipairs(plan.checkpoints) do
		local cp_id = cp_ids[cp_index]
		add(cp_id, "checkpoint", "Checkpoint " .. tostring(cp.n) .. " — " .. cp.title, plan_id,
			tostring(#cp.tasks) .. (if #cp.tasks == 1 then " task" else " tasks"), cp.state)
		local earlier = {}
		for _, task in ipairs(cp.tasks) do
			local task_lane = "Todo"
			local dependencies = table.clone(previous)
			for _, predecessor in ipairs(earlier) do if not task.independent or not predecessor.independent then table.insert(dependencies, predecessor.id) end end
			for _, id in ipairs(task.depends_on or {}) do if not table.find(dependencies, id) then table.insert(dependencies, id) end end
			local lower = {}
			local function child(kind: string, id: string, title: string, state: string?)
				local key = task.id .. "-" .. kind .. "-" .. id
				table.insert(lower, { id = key, kind = kind, title = title, state = state })
			end
			for _, step in ipairs(task.steps or {}) do child("step", step.id, step.text, step.state) end
			for _, file in ipairs(task.filechanges or {}) do child("file", file.id, (file.action or "UPDATE") .. " " .. file.path, file.state) end
			if #(task.filechanges or {}) == 0 then for _, file in ipairs(task.files) do child("file", hash(file, yield_step):sub(1, 24), file, nil) end end
			for _, check in ipairs(task.validationchecks or {}) do child("check", check.id, check.text, check.state) end
			if #(task.validationchecks or {}) == 0 then for _, check in ipairs(task.checks) do child("check", check.check_id, table.concat(check.argv, " "), nil) end end
			local names = {}; for _, id in ipairs(dependencies) do table.insert(names, task_titles[id]) end
			local description = task_description(task)
			local body = if #names > 0 then "After: " .. preview(table.concat(names, ", "), 96) else ""
			if description ~= "" then body ..= (if body ~= "" then " · " else "") .. description end
			add(task.id, "task", task.title, cp_id, body, task.state, task_lane)
			for _, row in ipairs(lower) do add(row.id, row.kind, row.title, task.id, nil, row.state, task_lane) end
			table.insert(earlier, task)
		end
		for _, task in ipairs(cp.tasks) do table.insert(previous, task.id) end
	end
	local result: any = { source = { path = path, revision = plan.plan_revision }, creates = {}, updates = {}, unchanged = {}, conflicts = {}, removed = {} }
	for _, node in ipairs(nodes) do
		if yield_step then yield_step() end
		local id, generated = node.id, node.text
		local source_tag, baseline = prefix .. id, hash(generated, yield_step)
		local done = if node.state then node.state == "done" else nil
		local matches = indexed[id] or {}
		if #matches > 1 then
			local card_ids = {}; for _, card in ipairs(matches) do table.insert(card_ids, card.id) end
			table.insert(result.conflicts, { task_id = id, code = "duplicate_provenance", card_ids = card_ids })
		elseif #generated > 32768 or #source_tag > 256 then table.insert(result.conflicts, { task_id = id, code = "card_too_large" })
		else
			local card, extras = matches[1], {}
			local representation = if card then representations[card.id] else nil
			if representation and representation.untouched then extras = representation.extras
			elseif card then
				-- Ownership of edited text is unproved. An explicit overwrite decision
				-- may replace that text, but never quietly delete its human tag metadata.
				for _, tag in ipairs(card.tags) do if not legacy_cards[card.id] or not generated_tags(tag) then table.insert(extras, tag) end end
			end
			local payload = native_text(generated, source_url :: string, id, baseline, plan.plan_revision, node.kind, done, extras)
			local fields = { text = payload }
			if #extras > 64 or #payload > 32768 then
				table.insert(result.conflicts, { task_id = id, card_id = if card then card.id else nil, code = "card_too_large" })
			elseif not card then
				table.insert(result.creates, { task_id = id, done = done, check_required = done == true, card = { lane = node.lane, text = payload } })
			elseif not representation or not representation.untouched or representation.source_tag ~= source_tag
				or (representation.done ~= nil and representation.done ~= tostring(card.done)) or (representation.done == nil and done == false and card.done) then
				table.insert(result.conflicts, { task_id = id, card_id = card.id, code = "human_edit", current_text = card.text,
					current_done = card.done, proposed_text = generated, proposed_done = done, proposed_fields = fields })
			elseif not representation.legacy and representation.body == generated and (done == nil or done == card.done) then table.insert(result.unchanged, id)
			else table.insert(result.updates, { task_id = id, card_id = card.id, fields = fields, done = done, check_required = done ~= nil and done ~= card.done }) end
		end
	end
	for _, source in ipairs(source_cards) do
		if yield_step then yield_step() end
		if not present[source.task_id] then
			table.insert(result.removed, source)
			local matches = indexed[source.task_id]
			if #matches ~= 1 then
				table.insert(result.conflicts, { task_id = source.task_id, code = "duplicate_provenance" })
				continue
			end
			local card = matches[1]
			local representation = representations[card.id]
			if representation and representation.retired and not representation.legacy then
				table.insert(result.unchanged, source.task_id)
			elseif not representation or not representation.untouched or representation.source_tag ~= prefix .. source.task_id then
				-- Source deletion never authorizes deleting or replacing human text.
				table.insert(result.conflicts, { task_id = source.task_id, card_id = card.id, code = "removed_human_edit", current_text = card.text })
			else
				local title = if representation.legacy then representation.body:match("^(.-) · Source: ") or representation.body else representation.body
				if representation.legacy then title = title:gsub("^%[Removed from source — retained history%] · ", "") end
				local generated = "Removed from plan · " .. preview(title, 120)
				local payload = native_text(generated, source_url :: string, source.task_id, hash(generated, yield_step),
					plan.plan_revision, representation.kind or "history", nil, representation.extras, true)
				if #representation.extras > 64 or #payload > 32768 then table.insert(result.conflicts, { task_id = source.task_id, card_id = card.id, code = "card_too_large" })
				else table.insert(result.updates, { task_id = source.task_id, card_id = card.id, fields = { text = payload } }) end
			end
		end
	end
	for _, conflict in ipairs(result.conflicts) do
		local content = table.clone(conflict)
		-- The bare proposed description already carries content changes; the full
		-- native payload additionally carries the irrelevant whole-file revision.
		content.proposed_fields = nil
		local representation = if conflict.card_id then representations[conflict.card_id] else nil
		if representation then
			content.current_text = representation.body
			content.current_metadata = { source_tag = representation.source_tag, baseline = representation.baseline,
				kind = representation.kind, done = representation.done, retired = representation.retired, extras = representation.extras }
		end
		conflict.signature = hash(quota.canonical(content), yield_step)
	end
	return result, nil
end
return M
