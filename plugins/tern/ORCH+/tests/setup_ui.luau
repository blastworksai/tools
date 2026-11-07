-- Native setup UI behavioral tests; no provider process is launched by this fixture.
local root = ...
local runtime, environment = tern, getfenv()
local clock = 0
local setup_runtime = setmetatable({ now = function() return clock end }, { __index = runtime })
local modules = {}
local function load(name)
	name = name:gsub("^%./", "")
	if modules[name] ~= nil then return modules[name] end
	local chunk = assert(loadstring(runtime.fs.read(root .. "/" .. name .. ".luau"), name))
	setfenv(chunk, setmetatable({ require = load, tern = if name == "setup_window" then setup_runtime else runtime }, { __index = environment }))
	local result = chunk(); modules[name] = result; return result
end
local module, dispatch, codec, state = load("setup_window"), load("dispatch"), load("wire/codec"), load("state")
local function frame(body, change)
	local bytes = runtime.json.encode(body)
	local envelope = { schema = 1, op = body.op, request_id = body.request_id, complete = true,
		body_bytes = #bytes, body_sha256 = codec.sha256(bytes), body_json = bytes }
	if change then change(envelope) end
	return "SPAWN_DISPATCH v1 " .. runtime.json.encode(envelope)
end
local checks = 0
local function check(value, message) assert(value, message); checks += 1 end
local function copy(value)
	if type(value) ~= "table" then return value end
	local out = {}; for key, child in value do out[key] = copy(child) end; return out
end
local function same(a, b)
	if type(a) ~= type(b) then return false end
	if type(a) ~= "table" then return a == b end
	for k, v in a do if not same(v, b[k]) then return false end end
	for k in b do if a[k] == nil then return false end end
	return true
end
local function fixture(registry)
	registry = registry or state.new_registry()
	registry.installation_defaults.revision = 4; registry.setup.config_revision = 4
	local data = { version = 1, source_nonce = "view", host_pane_id = "host-pane", setup = copy(registry.setup),
		installation_defaults = copy(registry.installation_defaults) }
	local f = { registry = registry, data = data, picks = {}, prompts = {}, events = {}, event_panes = {}, toasts = {},
		new_blocks = {}, focused = {}, navigation = {}, host_id = 2, session_id = 3, window = "",
		panes = { [9] = { pane = 9, tab = 1, block = "orchplus.orchestrator" } },
		pane_hosts = { [9] = 2 }, hosts = { [2] = { id = 2, state = "connected", kind = "local" },
			[7] = { id = 7, state = "connected", kind = "remote" } },
		membership = { [1] = 3, [2] = 4, [3] = 3 }, hidden = {}, listed = {} }
	local cx = { session = {}, hosts = {}, sessions = {}, layout = {} }; f.cx = cx
	function cx.session:pane(id) return f.panes[id] end
	function cx.session:panes()
		local rows = {}; for _, pane in f.panes do table.insert(rows, pane) end
		for _, pane in f.listed do table.insert(rows, pane) end
		return rows
	end
	function cx.session:view(id) return if f.panes[id] and not f.hidden[id] then { id = "main" } else nil end
	function cx.layout:focus(id)
		table.insert(f.focused, id); table.insert(f.navigation, { kind = "focus", pane = id })
		if f.focus_error then error("native focus refused") end
	end
	function cx.session:event(pane, event)
		if event.act == "page-entry" then
			table.insert(f.navigation, { kind = "event", pane = pane, event = event })
			if f.event_error then error("native event refused") end
		end
		table.insert(f.event_panes, pane)
		table.insert(f.events, event)
		local value = runtime.json.decode(event.value)
		if value.kind == "catalog_request" then f.catalog_request = value.request; f.issued_catalog_request = value.request end
		if value.kind == "catalog_clear" then f.catalog_request = nil end
	end
	function cx.hosts:current() return f.hosts[f.host_id] end
	function cx.sessions:current() return { id = f.session_id } end
	function cx:window_key() return f.window end
	function cx:pick(options) table.insert(f.picks, options); return { next = function(_, fn) f.answer = fn end } end
	function cx:prompt(options) table.insert(f.prompts, options); return { next = function(_, fn) f.answer = fn end } end
	function cx:toast(_, title, message) table.insert(f.toasts, { title, message }) end
	function cx:new_block(block, args, how, opts)
		local call = { block = block, args = args, how = how, opts = opts }
		table.insert(f.new_blocks, call)
		if block == "spawn.spawner" then
			table.insert(f.navigation, { kind = "new", call = call })
			if f.new_error then error("native launch refused") end
			return if f.unavailable then nil else 11
		end
		return 10
	end
	local serial = 0
	f.ui = module.new({ surface = function(_, _, block, _, key)
		if key == "setup-index" then return {}, if f.no_index then nil else runtime.json.encode(data) end
		if key == "setup-catalog-request" and f.catalog_request then return {}, runtime.json.encode(f.catalog_request) end
		if block == "spawn.dispatch" then return { id = "main" }, f.catalog_reply end
		return nil, nil
	end,
		decode = runtime.json.decode, decode_setup_response = dispatch.decode_setup_response,
		copy = copy, same = same, epoch = "epoch", id = function() serial += 1; return "request-" .. serial end,
		host = function(_, pane) return f.hosts[f.pane_hosts[pane]] end, membership = function() return f.membership end,
		family = function(provider) return ({ Claude = "anthropic", Codex = "openai" })[provider] end })
	function f:choose(position) self.answer(self.picks[#self.picks].items[position], nil, cx) end
	function f:commit()
		local request = runtime.json.decode(self.events[#self.events].value)
		request.source_nonce = nil; request.setup_origin = nil
		local next_registry, result = state.apply(self.registry, request)
		if next_registry then self.registry = next_registry end
		self.data.installation_defaults = copy(self.registry.installation_defaults)
		self.data.setup = copy(self.registry.setup)
		self.data.setup_result = copy(result); self.data.setup_result.request_id = request.request_id
		return result
	end
	return f
end
local f = fixture()
f.ui.start(f.cx, 9, "defaults"); f:choose(1)
check(#f.picks[#f.picks].items == 3, "review policy has exactly three explicit modes")
f:choose(3)
check(#f.prompts == 1 and #f.events == 0, "review-disabled draft asks actual repository before committing")
check(f.data.installation_defaults.policy.require_code_review == true, "window draft cannot mutate saved installation defaults")
local dismissed = fixture(); dismissed.ui.start(dismissed.cx, 9, "dismiss")
local event = runtime.json.decode(dismissed.events[1].value)
check(event.kind == "setup_lifecycle" and event.state == "dismissed" and event.expected_revision == 4, "dismissal uses revision-fenced authority writer without controller")
local stale = fixture(); stale.ui.start(stale.cx, 9, "defaults"); stale.data.source_nonce = "replacement"; stale:choose(1)
check(#stale.events == 0 and #stale.toasts == 1, "view incarnation change refuses pending picker instead of writing new authority")
local refused = fixture(); refused.ui.start(refused.cx, 9, "dismiss")
local request = runtime.json.decode(refused.events[1].value)
refused.data.setup_result = { request_id = request.request_id, ok = false, code = "revision_conflict" }
refused.ui.tick(refused.cx); refused.ui.tick(refused.cx)
check(#refused.events == 1 and #refused.toasts == 1, "conflicted write surfaces refusal without replay")
local records = {
	{ id = "builder", provider = "Claude", revision = 1, enabled = true, eligible = true, unsupported = {}, capabilities = { "report-files-v1", "check-runner-v1", "release-manager-v1" } },
	{ id = "release", provider = "Codex", revision = 1, enabled = true, eligible = true, unsupported = {}, capabilities = { "report-files-v1", "release-manager-v1" } },
	{ id = "reviewer", provider = "Codex", revision = 1, enabled = true, eligible = true, unsupported = {}, capabilities = { "report-files-v1" } },
}
local function probe_fixture(mode, existing)
	local f = existing or fixture()
	if not existing then f.ui.start(f.cx, 9, "defaults"); f:choose(1) end
	f:choose(mode)
	f.answer("/repo", nil, f.cx); f.answer("refs/heads/main", nil, f.cx); f:choose(2)
	local probe = runtime.json.decode(f.events[#f.events].value)
	f.data.setup_result = { request_id = probe.request_id, ok = true, repository = {
		cwd = "/repo", repo_root = "/repo", common_dir = "/repo/.git", target_ref = "refs/heads/main", head_revision = string.rep("a", 40) } }
	return f
end
local function catalog_body(f, rows)
	local request = assert(f.catalog_request)
	return { schema = 1, op = "catalog", request_id = request.request_id, action_id = request.action_id, setup_origin = copy(request.setup_origin),
		status = "catalog", payload = { catalog_version = 2, revision = 1, config_revision = 1, namespace = "spawn-fixture", host_key = "fixture-host", records = copy(rows),
			setup = { schema = 1, state = "completed", config_revision = 1, readiness = { state = "not_run", config_revision = 1, summary = "" } } } }
end
local function roles_fixture(mode, rows, existing, change)
	local f = probe_fixture(mode, existing)
	f.ui.tick(f.cx)
	local body = catalog_body(f, rows)
	f.catalog_body = body
	f.catalog_reply = if change then change(body) else frame(body)
	f.ui.tick(f.cx)
	return f
end
local function offered(f, id)
	for position, item in f.picks[#f.picks].items do if item.record and item.record.id == id then return position end end
	return nil
end
local function saved_defaults(f)
	for _, event in f.events do
		local value = runtime.json.decode(event.value)
		if value.kind == "installation_defaults" then return value.defaults end
	end
	return nil
end
for _, mode in { 2, 3 } do
	local f = roles_fixture(mode, records)
	f:choose(assert(offered(f, "builder")))
	check(offered(f, "builder") == nil and offered(f, "release") ~= nil,
		"a dual-capability builder is not selectable as its release manager")
	f:choose(assert(offered(f, "release")))
	if mode == 2 then
		check(offered(f, "builder") == nil and offered(f, "release") == nil and offered(f, "reviewer") ~= nil,
			"reviewer picker excludes both the builder and selected signer")
		f:choose(assert(offered(f, "reviewer")))
	end
	f:choose(1); f:choose(1)
	local saved = assert(saved_defaults(f), "role selections did not reach installation writer")
	check(saved.builder_record == "builder" and saved.policy.release_manager_record == "release"
		and (if mode == 2 then saved.policy.reviewer_records[1] == "reviewer" else #saved.policy.reviewer_records == 0),
		"native role choices save a usable separated signer and only the review roles required by policy")
end
local no_reviewer = roles_fixture(2, { records[1], records[2] })
no_reviewer:choose(assert(offered(no_reviewer, "builder"))); no_reviewer:choose(assert(offered(no_reviewer, "release")))
check(#no_reviewer.toasts == 1 and saved_defaults(no_reviewer) == nil,
	"no independent reviewer surfaces a refusal before defaults or setup completion can be saved")
local no_signer = roles_fixture(3, { records[1] })
no_signer:choose(assert(offered(no_signer, "builder")))
check(#no_signer.toasts == 1 and saved_defaults(no_signer) == nil,
	"review off still refuses a catalog whose only signer is the builder")
local unknown_records = copy(records); unknown_records[1].provider = "OMP"; unknown_records[3].provider = "OMP"
local declared = roles_fixture(2, unknown_records)
declared:choose(assert(offered(declared, "builder")))
check(#declared.prompts == 3 and saved_defaults(declared) == nil,
	"same-family review still collects the unknown builder's declared provider family")
declared.answer("openai", nil, declared.cx)
declared:choose(assert(offered(declared, "release"))); declared:choose(assert(offered(declared, "reviewer")))
check(#declared.prompts == 4, "same-family review collects the unknown independent reviewer's family")
declared.answer("anthropic", nil, declared.cx); declared:choose(1); declared:choose(1)
local declared_defaults = assert(saved_defaults(declared))
check(declared_defaults.policy.family_map.builder == "openai" and declared_defaults.policy.family_map.reviewer == "anthropic",
	"declared families reach the same authoritative installation-defaults writer")
local disabled = roles_fixture(3, unknown_records)
disabled:choose(assert(offered(disabled, "builder"))); disabled:choose(assert(offered(disabled, "release")))
disabled:choose(1); disabled:choose(1)
check(#disabled.prompts == 2 and saved_defaults(disabled) ~= nil,
	"review off does not gate setup on unknown provider families")
local function select_review_free_roles(f)
	f:choose(assert(offered(f, "builder"))); f:choose(assert(offered(f, "release")))
	f:choose(1); f:choose(1)
end
local prepared = roles_fixture(3, records)
select_review_free_roles(prepared)
check(prepared:commit().ok, "real defaults reducer accepts the wizard's verified repository and separated roles")
for _, finish in { 1, 2 } do
	local registry = copy(prepared.registry); registry.setup.state = "in_progress"
	local resumed = fixture(registry)
	resumed.ui.start(resumed.cx, 9, "setup"); resumed:choose(1)
	local resume_result = resumed:commit()
	check(resume_result.code == "no_progress" and resume_result.config_revision == 4,
		"resuming an in-progress wizard returns the unchanged authoritative revision")
	resumed.ui.tick(resumed.cx)
	roles_fixture(3, records, resumed)
	select_review_free_roles(resumed)
	local save_request = runtime.json.decode(resumed.events[#resumed.events].value)
	check(save_request.expected_revision == 4, "resume and repository probe preserve the acknowledged revision for saving")
	local save_result = resumed:commit()
	check(save_result.code == "no_progress" and save_result.config_revision == 4,
		"identical defaults complete through the real no-op writer without a predicted increment")
	resumed.ui.tick(resumed.cx); resumed:choose(finish)
	local completion = runtime.json.decode(resumed.events[#resumed.events].value)
	check(completion.expected_revision == 4, "completion uses the identical-defaults acknowledgement revision")
	local completion_result = resumed:commit()
	check(completion_result.ok and (if finish == 1 then completion_result.code == "setup_saved" else completion_result.code == "no_progress"),
		"both completion and no-op finish-later are accepted by the existing authority")
	resumed.ui.tick(resumed.cx)
	check(#resumed.toasts == 1 and resumed.toasts[1][1] == "ORCH+ setup saved",
		"successful completion, including no-op completion, reaches the visible wizard callback")
end
local concurrent = fixture()
concurrent.ui.start(concurrent.cx, 9, "setup"); concurrent:choose(1)
local own_result = concurrent:commit()
check(own_result.config_revision == 5, "changed lifecycle acknowledgement carries its actual new revision")
local external, external_result = state.apply(concurrent.registry,
	{ kind = "setup_lifecycle", request_id = "external-edit", expected_revision = 5, state = "dismissed" })
check(external ~= nil and external_result.config_revision == 6, "another settings window changes the authority after our acknowledgement")
concurrent.registry = external; concurrent.data.installation_defaults = copy(external.installation_defaults)
concurrent.data.setup = copy(external.setup)
concurrent.ui.tick(concurrent.cx)
roles_fixture(3, records, concurrent); select_review_free_roles(concurrent)
check(runtime.json.decode(concurrent.events[#concurrent.events].value).expected_revision == 5,
	"wizard adopts its correlated reply revision, never the newer projected revision")
local conflict = concurrent:commit(); concurrent.ui.tick(concurrent.cx)
check(conflict.code == "stale_revision" and #concurrent.toasts == 1 and saved_defaults(concurrent) ~= nil,
	"external edits remain revision conflicts rather than being silently overwritten")
local missing_revision = fixture(); missing_revision.ui.start(missing_revision.cx, 9, "dismiss")
missing_revision.data.setup_result = { request_id = runtime.json.decode(missing_revision.events[1].value).request_id, ok = true }
missing_revision.ui.tick(missing_revision.cx)
check(#missing_revision.toasts == 1 and missing_revision.toasts[1][1] == "ORCH+ setup",
	"configuration writes without authoritative revisions cannot report success")

-- Issued work is observed while hidden, but only a visible, unchanged source can continue.
local function quiet_snapshot(f)
	return { #f.events, #f.picks, #f.prompts, #f.new_blocks, #f.navigation, #f.toasts }
end
local function quiet(f, before, message)
	check(same(quiet_snapshot(f), before), message)
end
for _, missing_surface in { false, true } do
	local hidden_probe = probe_fixture(3)
	local before = quiet_snapshot(hidden_probe)
	hidden_probe.hidden[9] = true; hidden_probe.no_index = missing_surface
	hidden_probe.ui.tick(hidden_probe.cx)
	if not missing_surface then hidden_probe.data.setup_result = { request_id = "other-window", ok = false } end
	clock += 30001
	hidden_probe.ui.tick(hidden_probe.cx)
	quiet(hidden_probe, before, "hidden issued repository probe neither launches catalog nor repeats probe")
	hidden_probe.hidden[9] = nil; hidden_probe.no_index = false
	hidden_probe.ui.tick(hidden_probe.cx)
	check(#hidden_probe.new_blocks == 1 and hidden_probe.catalog_request ~= nil
		and runtime.json.decode(hidden_probe.events[#hidden_probe.events].value).expected_revision == 4,
		"repository evidence survives hidden/missing surface and elapsed deadline without predicting a revision")
	local resumed = quiet_snapshot(hidden_probe)
	hidden_probe.ui.tick(hidden_probe.cx)
	check(#hidden_probe.events == resumed[1] + 1 and hidden_probe.events[#hidden_probe.events].act == "catalog",
		"reveal sends only the new catalog operation, never the repository probe again")
	local sent = quiet_snapshot(hidden_probe)
	hidden_probe.ui.tick(hidden_probe.cx)
	quiet(hidden_probe, sent, "issued catalog dispatch is not duplicated on subsequent ticks")
	hidden_probe.catalog_reply = frame(catalog_body(hidden_probe, records))
	hidden_probe.ui.tick(hidden_probe.cx); select_review_free_roles(hidden_probe)
	local saved = assert(saved_defaults(hidden_probe))
	check(saved.repository.cwd == "/repo" and saved.repository.target_ref == "refs/heads/main"
		and saved.repository.queue_route == "orch_queue", "retained probe evidence, not a later projection, reaches the defaults writer")
end

local hidden_write = fixture()
hidden_write.ui.start(hidden_write.cx, 9, "setup"); hidden_write:choose(1)
local write_result = hidden_write:commit()
hidden_write.hidden[9] = true
local write_before = quiet_snapshot(hidden_write)
hidden_write.ui.tick(hidden_write.cx)
-- The host projection can move on after this window observes its own acknowledgement.
hidden_write.data.setup_result = { request_id = "other-window", ok = true, config_revision = 99 }
hidden_write.data.installation_defaults.revision = 99
hidden_write.no_index = true; clock += 30001
hidden_write.ui.tick(hidden_write.cx)
quiet(hidden_write, write_before, "acknowledged hidden config write causes no prompts, navigation or repeated mutation")
hidden_write.hidden[9] = nil; hidden_write.no_index = false
hidden_write.ui.tick(hidden_write.cx)
check(#hidden_write.picks == write_before[2] + 1 and #hidden_write.events == write_before[1],
	"reveal consumes the cached config acknowledgement once and opens review policy")
local write_resumed = quiet_snapshot(hidden_write)
hidden_write.ui.tick(hidden_write.cx)
quiet(hidden_write, write_resumed, "config acknowledgement callback does not run twice")
roles_fixture(3, records, hidden_write); select_review_free_roles(hidden_write)
check(runtime.json.decode(hidden_write.events[#hidden_write.events].value).expected_revision == write_result.config_revision,
	"continued defaults save uses the issued write's acknowledgement, not a newer projected revision")

local hidden_unread_write = fixture()
hidden_unread_write.ui.start(hidden_unread_write.cx, 9, "dismiss"); hidden_unread_write:commit()
hidden_unread_write.hidden[9] = true; hidden_unread_write.no_index = true
local unread_before = quiet_snapshot(hidden_unread_write)
clock += 30001; hidden_unread_write.ui.tick(hidden_unread_write.cx)
quiet(hidden_unread_write, unread_before, "missing hidden surface does not discard an issued config write")
hidden_unread_write.hidden[9] = nil; hidden_unread_write.no_index = false
hidden_unread_write.ui.tick(hidden_unread_write.cx); hidden_unread_write.ui.tick(hidden_unread_write.cx)
check(#hidden_unread_write.events == 1 and #hidden_unread_write.toasts == 1
	and hidden_unread_write.toasts[1][1] == "Setup dismissed",
	"already-available config acknowledgement wins over elapsed timeout when its surface returns")

for _, paginated in { false, true } do
	local hidden_catalog = probe_fixture(3)
	hidden_catalog.ui.tick(hidden_catalog.cx); hidden_catalog.ui.tick(hidden_catalog.cx)
	local first_request = copy(hidden_catalog.catalog_request)
	local body = catalog_body(hidden_catalog, if paginated then { records[1] } else records)
	if paginated then body.payload.next_cursor = { revision = 1, index = 2 } end
	hidden_catalog.hidden[9] = true; hidden_catalog.no_index = true
	hidden_catalog.catalog_reply = frame(body)
	local before = quiet_snapshot(hidden_catalog)
	clock += 30001
	hidden_catalog.ui.tick(hidden_catalog.cx)
	hidden_catalog.catalog_reply = nil
	hidden_catalog.ui.tick(hidden_catalog.cx)
	quiet(hidden_catalog, before, "hidden framed catalog response is retained without clearing, paginating or prompting")
	hidden_catalog.hidden[9] = nil; hidden_catalog.no_index = false
	hidden_catalog.ui.tick(hidden_catalog.cx)
	local clear = runtime.json.decode(hidden_catalog.events[before[1] + 1].value)
	check(clear.kind == "catalog_clear" and clear.expected_revision == 4,
		"reveal clears the acknowledged catalog request using the original expected revision")
	if paginated then
		check(#hidden_catalog.events == before[1] + 2 and hidden_catalog.catalog_request.request_id ~= first_request.request_id
			and same(hidden_catalog.catalog_request.cursor, body.payload.next_cursor),
			"reveal requests exactly the next page rather than replaying the acknowledged page")
		hidden_catalog.catalog_reply = frame(catalog_body(hidden_catalog, { records[2], records[3] }))
		hidden_catalog.ui.tick(hidden_catalog.cx)
	end
	check(hidden_catalog.catalog_request == nil and offered(hidden_catalog, "builder") ~= nil
		and #hidden_catalog.picks == before[2] + 1,
		"retained catalog pages clear pending host publication and open one role picker")
	local revealed = quiet_snapshot(hidden_catalog)
	hidden_catalog.ui.tick(hidden_catalog.cx); hidden_catalog.ui.tick(hidden_catalog.cx)
	quiet(hidden_catalog, revealed, "catalog consumption, clear and role picker have no duplicate effects")
end

for _, variant in { "nonce", "host-pane", "closed", "block", "host", "session", "window" } do
	local changed = fixture(); changed.ui.start(changed.cx, 9, "dismiss"); changed:commit()
	changed.hidden[9] = true
	changed.ui.tick(changed.cx) -- Cache the actual acknowledgement before identity is lost.
	changed.no_index = true
	if variant == "nonce" then changed.data.source_nonce = "replacement"
	elseif variant == "host-pane" then changed.data.host_pane_id = "replacement"
	elseif variant == "closed" then changed.panes[9] = nil
	elseif variant == "block" then changed.panes[9].block = "spawn.spawner"
	elseif variant == "host" then changed.pane_hosts[9] = 7
	elseif variant == "session" then changed.panes[9].tab = 2
	else changed.window = "replacement" end
	local before = quiet_snapshot(changed)
	changed.ui.tick(changed.cx)
	changed.no_index = false; changed.hidden[9] = nil
	changed.ui.tick(changed.cx); changed.ui.tick(changed.cx)
	quiet(changed, before, variant .. ": actual source identity loss discards even an already-observed acknowledgement")
end

local switched = fixture(); switched.ui.start(switched.cx, 9, "dismiss"); switched:commit()
switched.host_id = 7; switched.session_id = 4; switched.no_index = true
local switched_before = quiet_snapshot(switched)
switched.ui.tick(switched.cx)
quiet(switched, switched_before, "changing current UI host/session does not continue an issued write")
switched.host_id = 2; switched.session_id = 3; switched.no_index = false
switched.ui.tick(switched.cx); switched.ui.tick(switched.cx)
check(#switched.events == 1 and #switched.toasts == 1 and switched.toasts[1][1] == "Setup dismissed",
	"unchanged captured source resumes once after returning to its original UI scope")

for _, operation in { "write", "catalog" } do
	local timed = if operation == "write" then fixture() else probe_fixture(3)
	if operation == "write" then timed.ui.start(timed.cx, 9, "dismiss")
	else timed.ui.tick(timed.cx); timed.ui.tick(timed.cx) end
	timed.hidden[9] = true
	local before = quiet_snapshot(timed)
	clock += 30001; timed.ui.tick(timed.cx)
	quiet(timed, before, "elapsed hidden operation does not emit timeout UI or catalog mutations")
	timed.hidden[9] = nil; timed.ui.tick(timed.cx); timed.ui.tick(timed.cx)
	check(#timed.toasts == 1 and #timed.events == before[1] + (if operation == "catalog" then 1 else 0)
		and (operation ~= "catalog" or timed.catalog_request == nil),
		"unanswered operation retains the original bounded timeout on reveal, with no fabricated success or replay")
end

local hidden_choice = fixture(); hidden_choice.ui.start(hidden_choice.cx, 9, "defaults")
hidden_choice.hidden[9] = true; hidden_choice:choose(1)
hidden_choice.hidden[9] = nil; hidden_choice.ui.tick(hidden_choice.cx)
check(#hidden_choice.events == 0 and #hidden_choice.picks == 1 and #hidden_choice.toasts == 1,
	"hidden stale UI choice is refused, not saved for silent continuation on reveal")

for _, malformed in {
	{ "unframed JSON", function(body) return runtime.json.encode(body) end },
	{ "truncated frame", function(body) return frame(body):sub(1, -2) end },
	{ "wrong length", function(body) return frame(body, function(envelope) envelope.body_bytes += 1 end) end },
	{ "wrong digest", function(body) return frame(body, function(envelope) envelope.body_sha256 = string.rep("0", 64) end) end },
	{ "incomplete frame", function(body) return frame(body, function(envelope) envelope.complete = false end) end },
	{ "frame request mismatch", function(body) return frame(body, function(envelope) envelope.request_id = "other" end) end },
	{ "body request mismatch", function(body) body.request_id = "other"; return frame(body) end },
	{ "action mismatch", function(body) body.action_id = "other"; return frame(body) end },
	{ "origin mismatch", function(body) body.setup_origin.window_epoch = "other"; return frame(body) end },
	{ "controller authority", function(body) body.controller_generation = 1; return frame(body) end },
	{ "unknown body field", function(body) body.extra = true; return frame(body) end },
	{ "missing catalog identity", function(body) body.payload.namespace = nil; return frame(body) end },
	{ "mismatched setup revision", function(body) body.payload.setup.config_revision = 2; return frame(body) end },
	{ "invalid readiness", function(body) body.payload.setup.readiness.state = "assumed"; return frame(body) end },
	{ "unknown catalog field", function(body) body.payload.extra = true; return frame(body) end },
	{ "invalid cursor", function(body) body.payload.next_cursor = { revision = 1, index = 0 }; return frame(body) end },
	{ "invalid record", function(body) body.payload.records[1].unsupported = nil; return frame(body) end },
} do
	local invalid = roles_fixture(3, records, nil, malformed[2])
	check(#invalid.picks == 3 and offered(invalid, "builder") == nil and saved_defaults(invalid) == nil,
		malformed[1] .. " cannot advance the wizard into role selection or save defaults")
	invalid.catalog_reply = frame({ schema = 1, op = "catalog", request_id = invalid.catalog_request.request_id,
		action_id = invalid.catalog_request.action_id, setup_origin = invalid.catalog_request.setup_origin,
		status = "rejected", error = { code = "storage_error", message = "Restore the SPAWN store" } })
	invalid.ui.tick(invalid.cx)
	check(#invalid.toasts == 1 and invalid.toasts[1][2]:find("Restore the SPAWN store", 1, true) ~= nil,
		malformed[1] .. ": subsequent correlated framed prerequisite refusal reaches the visible wizard error")
end
local closed_variant = roles_fixture(3, records)
check(dispatch.decode_response(closed_variant.catalog_reply, closed_variant.issued_catalog_request) == nil,
	"controller response decoder remains closed to setup-origin responses")
local mixed_request = copy(closed_variant.issued_catalog_request); mixed_request.controller_generation = 1
check(dispatch.decode_setup_response(closed_variant.catalog_reply, mixed_request) == nil,
	"setup decoder refuses a request mixing controller and pre-controller authority")
-- Native navigation is an inert page entry, independent of authority initialization.
local page = { kind = "page", page = "managed", native_window = "" }
local function target(f, id, tab, host)
	f.panes[id] = { pane = id, block = "spawn.spawner", tab = tab }
	f.pane_hosts[id] = host or 2
end
local function incomplete_catalog()
	return roles_fixture(3, records, nil, function(body)
		body.payload.setup.state = "in_progress"
		return frame(body)
	end)
end
local function prepare_navigation(path)
	local f = if path == "catalog" then incomplete_catalog() else fixture()
	if path == "wizard" then f.ui.start(f.cx, 9, "setup") end
	local function go()
		if path == "direct" then f.ui.start(f.cx, 9, "spawn")
		else f:choose(if path == "wizard" then 2 else 1) end
	end
	return f, go
end
local function assert_new_page(f, before, message)
	check(#f.navigation == 1 and f.navigation[1].kind == "new" and #f.focused == 0
		and #f.events == before, message .. ": opens one inert page without event/mutation")
	local call = f.navigation[1].call
	check(call.block == "spawn.spawner" and #call.args == 1 and same(runtime.json.decode(call.args[1]), page)
		and call.how == "beside" and same(call.opts, { target = 9, focus = true }),
		message .. ": exact owner page and native source-anchored placement")
end
for _, path in { "direct", "wizard", "catalog" } do
	local fresh, go = prepare_navigation(path)
	local before, saved = #fresh.events, copy(fresh.registry)
	go()
	assert_new_page(fresh, before, path)
	check(same(fresh.registry, saved), path .. ": navigation does not complete setup or change authority")
	fresh.ui.tick(fresh.cx); fresh.ui.tick(fresh.cx)
	check(#fresh.navigation == 1, path .. ": no delayed navigation replay")

	local visible, reveal = prepare_navigation(path)
	target(visible, 20, 3)
	-- Unsuitable panes do not make the single suitable view ambiguous.
	target(visible, 21, 1, 7); target(visible, 22, 2); target(visible, 23, nil)
	target(visible, 24, 1); visible.hidden[24] = true
	local events_before = #visible.events
	reveal()
	check(#visible.navigation == 2 and visible.navigation[1].kind == "focus"
		and visible.navigation[1].pane == 20 and visible.navigation[2].kind == "event"
		and visible.navigation[2].pane == 20 and #visible.events == events_before + 1,
		path .. ": focuses only the current host/session visible target before owner entry")
	local entry = visible.events[#visible.events]
	check(entry.ev == "action" and entry.id == "main" and entry.act == "page-entry"
		and same(runtime.json.decode(entry.value), page), path .. ": existing target gets only closed page-entry")

	for _, variant in { "foreign-host", "foreign-session", "parked", "unknown-tab", "hidden", "closed", "wrong-block", "ambiguous" } do
		local other, navigate = prepare_navigation(path)
		target(other, 20, 1)
		if variant == "foreign-host" then other.pane_hosts[20] = 7
		elseif variant == "foreign-session" then other.panes[20].tab = 2
		elseif variant == "parked" then other.panes[20].tab = nil; other.panes[20].parked = true
		elseif variant == "unknown-tab" then other.panes[20].tab = 99
		elseif variant == "hidden" then other.hidden[20] = true
		elseif variant == "closed" then other.listed = { copy(other.panes[20]) }; other.panes[20] = nil
		elseif variant == "wrong-block" then other.panes[20].block = "spawn.dispatch"
		elseif variant == "ambiguous" then target(other, 21, 3) end
		local count = #other.events
		navigate()
		assert_new_page(other, count, path .. "/" .. variant)
	end

	for _, variant in { "closed", "wrong-block", "parked", "hidden", "unknown-tab", "foreign-host",
		"foreign-session", "disconnected", "current-host", "current-session", "nonce", "origin", "window", "no-index",
		"moved-host-scope", "moved-session-scope" } do
		-- Direct navigation has no asynchronous source identity to outlive.
		if path == "direct" and table.find({ "nonce", "origin", "window", "no-index", "moved-host-scope", "moved-session-scope" }, variant) then continue end
		local moved, navigate = prepare_navigation(path)
		target(moved, 20, 1)
		if variant == "closed" then moved.panes[9] = nil
		elseif variant == "wrong-block" then moved.panes[9].block = "spawn.spawner"
		elseif variant == "parked" then moved.panes[9].tab = nil; moved.panes[9].parked = true
		elseif variant == "hidden" then moved.hidden[9] = true
		elseif variant == "unknown-tab" then moved.panes[9].tab = 99
		elseif variant == "foreign-host" then moved.pane_hosts[9] = 7
		elseif variant == "foreign-session" then moved.panes[9].tab = 2
		elseif variant == "disconnected" then moved.hosts[2].state = "disconnected"
		elseif variant == "current-host" then moved.host_id = 7
		elseif variant == "current-session" then moved.session_id = 4
		elseif variant == "nonce" then moved.data.source_nonce = "replacement"
		elseif variant == "origin" then moved.data.host_pane_id = "replacement"
		elseif variant == "window" then moved.window = "other"
		elseif variant == "no-index" then moved.no_index = true
		elseif variant == "moved-host-scope" then
			moved.host_id = 7; moved.pane_hosts[9] = 7; moved.pane_hosts[20] = 7
		elseif variant == "moved-session-scope" then
			moved.session_id = 4; moved.membership[1] = 4
		end
		local count, saved = #moved.events, copy(moved.registry)
		navigate(); moved.ui.tick(moved.cx); moved.ui.tick(moved.cx)
		check(#moved.navigation == 0 and #moved.events == count and #moved.toasts == 1 and same(moved.registry, saved),
			path .. "/" .. variant .. ": stale source visibly refuses without navigation, write or replay")
	end

	for _, variant in { "unavailable", "new-error", "focus-error", "event-error" } do
		local failed, navigate = prepare_navigation(path)
		if variant == "unavailable" then failed.unavailable = true
		elseif variant == "new-error" then failed.new_error = true
		elseif variant == "focus-error" then target(failed, 20, 1); failed.focus_error = true
		else target(failed, 20, 1); failed.event_error = true end
		local count = #failed.new_blocks
		navigate()
		local attempts = #failed.navigation
		failed.ui.tick(failed.cx); failed.ui.tick(failed.cx)
		check(#failed.toasts == 1 and #failed.navigation == attempts
			and #failed.new_blocks == count + (if variant == "unavailable" or variant == "new-error" then 1 else 0),
			path .. "/" .. variant .. ": visible native failure with no fallback launch or automatic replay")
	end
end
local cold = fixture(); cold.data.installation_defaults = nil; cold.no_index = true
cold.ui.start(cold.cx, 9, "spawn")
assert_new_page(cold, 0, "uninitialized ORCH authority")
check(#cold.toasts == 0 and #cold.picks == 0, "direct navigation needs a live source, not installed defaults or initialization consent")
local named_window = fixture(); named_window.window = "window-2"
named_window.ui.start(named_window.cx, 9, "spawn")
check(same(runtime.json.decode(named_window.new_blocks[1].args[1]),
	{ kind = "page", page = "managed", native_window = "window-2" }), "new owner page receives actual nonempty native window key")

return "setup_ui: " .. tostring(checks) .. " checks"
