--!strict
-- Shared settings shapes/defaults; never load the authority/workflow reducer in the window.
local protocol = require("./dispatch_protocol")
local quota = require("./quota")
local M: any = { keys = {}, APPROVABLE = { "dispatch", "report", "review", "landing" }, MAX_BYTES = protocol.POLICY_BYTES }
local config = M
local MAX = 9007199254740991
local function closed(v: any, keys: string): boolean
	if type(v) ~= "table" or v == tern.json.null then return false end
	local allowed = {}; for k in keys:gmatch("%S+") do allowed[k] = true end
	for k in v do if not allowed[k] then return false end end; return true
end
local function id(v: any): boolean return type(v) == "string" and #v > 0 and #v <= 96 and v:match("^[A-Za-z0-9_-]+$") ~= nil end
local function str(v: any, n: number, empty: boolean?): boolean return type(v) == "string" and (empty or #v > 0) and #v <= n and utf8.len(v) ~= nil and not v:find("%z") end
local function pos(v: any): boolean return type(v) == "number" and v >= 1 and v <= MAX and v % 1 == 0 end
local function count(v: any): number local n = 0; for _ in v do n += 1 end; return n end
-- Reusable settings contain no live identity, repository target or one-off grant.
local DEFAULT_POLICY = { paused = false, poll_ms = 300000, report_request_ms = 900000, stale_ms = 1800000, automatic_reports = false,
	auto_rollover = true, rollover_threshold_pct = 0, rollover_include_coordinator = false, quota_routing = false, excluded_workers = {},
	quota_reserve_pct = 10, quota_max_age_ms = 0, initial_dispatch_enabled = false, initial_dispatch_records = {}, initial_dispatch_provider = false,
	initial_dispatch_account = false, sweep_enabled = true, sweep_time = "03:00:00",
	worker_rollover_enabled = false, worker_rollover_records = {}, worker_rollover_provider = false, worker_rollover_account = false,
	coordinator_rollover_enabled = false, coordinator_rollover_records = {}, coordinator_rollover_provider = false, coordinator_rollover_account = false,
	concurrency_limit = 4, loop_cap = 5, review_rounds = 5, stale_claim_min = 120, require_code_review = true, require_other_family = true,
	reviewer_records = {}, merge_actor_mode = "worker", release_manager_record = "", preferred_worker_record = "", preferred_orchestrator_record = "",
	checkout_roots = {}, track_checkout_roots = true, auto_approve_kinds = { "dispatch", "report", "review", "landing" }, merge_coordination = true,
	glitch_integration = false, work_on_enabled = true,
	board_path = "", board_lanes = { queued = "Todo", running = "Doing", review = "Review", done = "Done" },
	inbox_folder = "", auto_start_projects = false,
	templates = {} }
M.defaults = DEFAULT_POLICY

-- Distinct ascending lists: worker IDs (`ids`) or an explicit record allowlist (no wildcard entries).
local function record_set(v: any, maximum: number, ids: boolean?): boolean
	if not config.list(v, maximum) then return false end
	for i, entry in v do if not (if ids then id(entry) else config.record(entry)) or (i > 1 and v[i - 1] >= entry) then return false end end
	return true
end
-- Desktop-local wall-clock, including seconds.
local function sweep_clock(v: any): boolean
	if type(v) ~= "string" or #v ~= 8 then return false end
	local hour, minute, second = v:match("^(%d%d):(%d%d):(%d%d)$")
	return hour ~= nil and (tonumber(hour) or 99) <= 23 and (tonumber(minute) or 99) <= 59 and (tonumber(second) or 99) <= 59
end
-- Config v4 value shapes (Contract B). Slugs are lowercase identifiers (family, class, template id).
function config.slug(v: any, n: number): boolean return type(v) == "string" and #v >= 1 and #v <= n and v:match("^[a-z][a-z0-9%-]*$") ~= nil end
function config.record(v: any): boolean return str(v, 96) and v:find("[%*%?]") == nil end
-- Explicit record list in the owner's order: distinct, no wildcards (order is meaningful, e.g. reviewer preference).
function config.records_ordered(v: any, maximum: number): boolean
	if not config.list(v, maximum) then return false end
	for i, record_id in v do if not config.record(record_id) or table.find(v, record_id) ~= i then return false end end
	return true
end
function config.absolute(v: any, n: number): boolean return str(v, n) and (v:sub(1, 1) == "/" or v:match("^%a:[\\/]") ~= nil) end
function config.relative(v: any, n: number): boolean
	if not str(v, n) or v:sub(1, 1) == "/" or v:sub(1, 1) == "\\" or v:match("^%a:") ~= nil then return false end
	for part in v:gmatch("[^/\\]+") do if part == ".." then return false end end
	return true
end
function config.list(v: any, maximum: number): boolean
	if type(v) ~= "table" or v == tern.json.null or #v > maximum or count(v) ~= #v then return false end
	for k in v do if type(k) ~= "number" or k < 1 or k > #v or k % 1 ~= 0 then return false end end
	return true
end
function config.texts(v: any, maximum: number, n: number, minimum: number?): boolean
	if not config.list(v, maximum) or #v < (minimum or 0) then return false end
	for _, entry in v do if not str(entry, n) then return false end end
	return true
end
function config.template(t: any): boolean
	return next(config.template_errors(t)) == nil
end
function config.custom_fields(value: any): boolean
	if type(value) ~= "table" or value == tern.json.null or count(value) > 16 then return false end
	for name, default in value do if M.custom_field_error(name, default) then return false end end
	return true
end
function M.custom_field_error(name: any, value: any): string?
	if name == "input" or not config.slug(name, 32) then return "Use 1 to 32 lowercase letters, digits or hyphens, starting with a letter; input is reserved." end
	if not str(value, 2048, true) then return "Enter text of at most 2048 bytes." end
	return nil
end
function config.template_errors(t: any): any
	local errors = {}
	if not closed(t, "id title prompt output next class custom_fields") then return { id = "Reopen this template to restore its supported fields." } end
	local function field(key: string, valid: boolean, help: string) if not valid then errors[key] = help end end
	field("id", config.slug(t.id, 32), "Use 1 to 32 lowercase letters, digits or hyphens, starting with a letter.")
	field("title", str(t.title, 80), "Enter a title of 1 to 80 bytes.")
	field("output", config.relative(t.output, 256), "Enter a relative output path of 1 to 256 bytes, without parent-directory (..) segments.")
	field("class", t.class == nil or config.slug(t.class, 32), "Leave blank or use 1 to 32 lowercase letters, digits or hyphens, starting with a letter.")
	field("next", t.next == "" or (config.slug(t.next, 32) and t.next ~= t.id), "Choose another template or leave blank.")
	local custom = config.custom_fields(t.custom_fields)
	if not custom then
		if type(t.custom_fields) ~= "table" or t.custom_fields == tern.json.null or count(t.custom_fields) > 16 then
			errors.prompt = "Use at most 16 custom fields."
		else
			local names = {}
			for name in t.custom_fields do table.insert(names, name) end
			table.sort(names, function(a, b) return tostring(a) < tostring(b) end)
			for index, name in names do
				local problem = M.custom_field_error(name, t.custom_fields[name])
				if problem then errors["custom_value_" .. tostring(index)] = problem end
			end
		end
	end
	local prompt = str(t.prompt, 4096)
	if prompt then
		local _, inputs = t.prompt:gsub("{input}", "")
		prompt = inputs == 1
		if custom then for name in (t.prompt .. (if type(t.output) == "string" then t.output else "")):gmatch("{([^{}]+)}") do
			if name ~= "input" and t.custom_fields[name] == nil then prompt = false end
		end end
	end
	field("prompt", prompt, "Enter 1 to 4096 bytes with exactly one {input}; define every other {field} used by the prompt or output.")
	return errors
end
-- The reducer and forms share this field-level authority; list normalization belongs at input.
function M.policy_errors(p: any): any
	local errors = {}
	if type(p) ~= "table" or p == tern.json.null then return { _policy = "Reopen settings to restore a complete settings form." } end
	local function require_field(key: string, valid: boolean, help: string)
		if not valid then errors[key] = help end
	end
	local function whole(key: string, minimum: number, maximum: number, help: string)
		local v = p[key]
		require_field(key, type(v) == "number" and v >= minimum and v <= maximum and v % 1 == 0, help)
	end
	for key, default in DEFAULT_POLICY do
		if type(default) == "boolean" then require_field(key, type(p[key]) == "boolean", "Choose On or Off.") end
	end
	for key in p do if DEFAULT_POLICY[key] == nil then errors._policy = "Remove unsupported settings by reopening this form." end end
	whole("poll_ms", 1000, 3600000, "Enter a polling interval from 00:01 to 60:00.")
	whole("report_request_ms", 5000, 86400000, "Enter a report interval from 00:05 to 1440:00.")
	whole("stale_ms", 1, 86400000, "Enter a stale-report interval no longer than 1440:00.")
	if errors.stale_ms == nil and errors.report_request_ms == nil and p.stale_ms < p.report_request_ms then
		errors.stale_ms = "Use a stale-report interval at least as long as the report interval."
	end
	whole("rollover_threshold_pct", 0, 99, "Choose the calculated default or enter a whole percentage from 1 to 99.")
	whole("quota_reserve_pct", 0, 99, "Enter a whole percentage from 0 to 99.")
	local age = p.quota_max_age_ms
	require_field("quota_max_age_ms", age == 0 or (pos(age) and age >= 60000 and age <= 31536000000),
		"Turn the override Off, or enter an age from 1/60 to 8760 hours.")
	whole("concurrency_limit", 0, quota.MAX_CONCURRENCY, "Enter a whole work limit from 0 to " .. tostring(quota.MAX_CONCURRENCY) .. ".")
	whole("loop_cap", 1, 10, "Enter a whole loop limit from 1 to 10.")
	whole("review_rounds", 1, 10, "Enter a whole review-round limit from 1 to 10.")
	local stale = p.stale_claim_min
	require_field("stale_claim_min", type(stale) == "number" and stale >= 0 and stale <= 1440
		and math.abs(stale * 60 - math.floor(stale * 60 + 0.5)) < 0.000001, "Enter a claim age as hh:mm:ss, from 00:00:00 to 24:00:00.")
	require_field("sweep_time", sweep_clock(p.sweep_time), "Enter a time as hh:mm:ss, from 00:00:00 to 23:59:59.")
	require_field("excluded_workers", record_set(p.excluded_workers, 32, true), "Choose at most 32 distinct workers.")
	for _, scope in quota.SCOPES do
		require_field(scope .. "_records", record_set(p[scope .. "_records"], quota.MAX_RECORDS), "Choose distinct allowed agents; do not repeat an agent.")
	end
	require_field("reviewer_records", config.records_ordered(p.reviewer_records, 8), "Choose at most 8 distinct reviewers, in preference order.")
	for _, key in { "release_manager_record", "preferred_worker_record", "preferred_orchestrator_record" } do
		require_field(key, p[key] == "" or config.record(p[key]), "Choose a saved agent or leave this choice empty.")
	end
	require_field("merge_actor_mode", p.merge_actor_mode == "worker" or p.merge_actor_mode == "selected_record", "Choose Same agent as worker or a selected release manager.")
	if p.require_code_review == false and p.require_other_family == true then
		errors.require_other_family = "Enable code review first, or turn review by another provider Off."
	end
	for _, key in { "board_path", "inbox_folder" } do
		local maximum = if key == "board_path" then protocol.DESKTOP_BOARD_PATH_BYTES else 512
		require_field(key, p[key] == "" or config.absolute(p[key], maximum) or config.relative(p[key], maximum),
			"Leave blank or choose a path of at most " .. tostring(maximum) .. " bytes, without parent-directory (..) segments.")
	end
	local roots = config.list(p.checkout_roots, 8)
	if roots then for i, path in p.checkout_roots do
		if not config.absolute(path, 512) or table.find(p.checkout_roots, path) ~= i then roots = false; break end
	end end
	require_field("checkout_roots", roots, "Choose at most 8 distinct absolute working-copy folders, each at most 512 bytes.")
	local approvals = config.list(p.auto_approve_kinds, #config.APPROVABLE)
	if approvals then
		local last = 0
		for _, kind in p.auto_approve_kinds do
			local index = table.find(config.APPROVABLE, kind)
			if not index or index <= last then approvals = false; break end
			last = index
		end
	end
	require_field("auto_approve_kinds", approvals, "Choose distinct approval kinds in dispatch, report, review, landing order.")
	local lanes = closed(p.board_lanes, "queued running review done")
	if lanes then for _, key in { "queued", "running", "review", "done" } do if not str(p.board_lanes[key], 64) then lanes = false; break end end end
	require_field("board_lanes", lanes, "Use the standard board layout; each lane name must contain 1 to 64 bytes.")
	local templates, seen = config.list(p.templates, 16), {}
	require_field("templates", templates, "Use at most 16 templates.")
	if templates then
		for i, t in p.templates do
			local prefix = "template_" .. tostring(i) .. "_"
			for key, help in config.template_errors(t) do errors[prefix .. key] = help end
			if type(t) == "table" and type(t.id) == "string" then
				if seen[t.id] then errors[prefix .. "id"] = "Use a distinct template name." end
				seen[t.id] = true
			end
		end
		for i, t in p.templates do
			if type(t) == "table" and type(t.next) == "string" and t.next ~= "" and not seen[t.next] then
				errors["template_" .. tostring(i) .. "_next"] = "Choose an existing template or leave blank."
			end
		end
	end
	if next(errors) == nil and not config.fits(p) then errors.templates = "Shorten templates so all settings fit within " .. tostring(config.MAX_BYTES) .. " bytes." end
	return errors
end
function config.fits(p: any): boolean return #quota.canonical(p) <= config.MAX_BYTES end
return M
