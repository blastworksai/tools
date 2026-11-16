-- Pure consumer regressions; invoke through the existing Tern test runner in bounded sections.
local root, section = ...
local runtime, environment = tern, getfenv()
local function loader(directory)
	local modules = {}
	local function load(name)
		name = name:gsub("^%./", "")
		if modules[name] then return modules[name] end
		local chunk = assert(loadstring(runtime.fs.read(directory .. "/" .. name .. ".luau"), name))
		setfenv(chunk, setmetatable({ require = load }, { __index = environment }))
		local value = chunk(); modules[name] = value; return value
	end
	return load
end
local load = loader(root)
local adapter, parser, quota = load("source_adapter"), load("plan_import"), load("quota")
local codec = load("wire/codec")
local checks = 0
local function check(ok, message) assert(ok, message); checks += 1 end
local function same(a, b) return quota.digest(a) == quota.digest(b) end
local function rejected(value, err, code)
	check(value == nil and err and err.code == code, "expected refusal " .. code .. ", got " .. tostring(err and err.code))
end
local function plan_bytes(home)
	return "# Feature: Neutral research\n\n## Build choices\n" .. (home or "") .. [[
## Implementation
### Checkpoint 1 — Research
#### Task A1 — Gather evidence
**INDEPENDENT**
**CLASS**: research
Collect public references.
#### Task A2 — Compare evidence
**INDEPENDENT**
**CLASS**: research
Compare public references.
#### Task A3 — Synthesize findings
SEQUENTIAL: Wait for both research tasks.
**CLASS**: writing
Write a reasoned synthesis.
### Checkpoint 2 — Review
#### Task B1 — Review synthesis
**INDEPENDENT**
**CLASS**: review
Review the synthesis.
]]
end
local function snapshot(cards)
	return { path = "/desktop/My board.md", phase = "ready", more = 0, lanes = { { id = "lane", title = "Work", more = 0, complete = false, cards = cards or {} } } }
end
local function native_tags(value)
	local tags = {}
	for tag in value:gmatch("#([A-Za-z0-9_%-]+)") do if not table.find(tags, tag) then table.insert(tags, tag) end end
	return tags
end
local function materialize(description)
	local cards = {}
	for i, create in ipairs(description.creates) do
		table.insert(cards, { id = "native-card-" .. tostring(i), text = create.card.text, tags = native_tags(create.card.text), done = false })
	end
	return snapshot(cards)
end
local function project(plan, path, board, lane, yield_step)
	local navigation = adapter.plan_link_base(string.rep("a", 24), path, codec.sha256(board.path))
	return adapter.plan_to_board(plan, path, board, lane, yield_step, navigation)
end
local function projection(value)
	local url = value:match("%((tern://orchplus%-plan%?[^%)]+)%)")
	return if url then adapter.parse_plan_link(url) else nil
end
if section == nil or section == "registry" then
	local work_load = loader(root .. "/../WORK")
	local projects, config = work_load("projects"), work_load("config")
	local fixtures = {
		'[]', '{}', '{"workspaces":[]}', '{"workspaces":{}}', '{"workspaces":[{"status":"active","path":"alpha"}]}',
		'{"workspaces":{"zeta":{"status":"active","path":"zeta","remote":"https://github.com/example/zeta.git"},"alpha":{"status":"active","path":"alpha","kind":"research"},"old":{"status":"archived","path":"old"},"mirror":{"status":"mirror","path":"mirror"},"tree":{"status":"worktree","path":"tree"},"bad":{"status":"active","path":"../escape"},"Bad":{"status":"active","path":"bad"},"failed":{"status":"failed","path":"failed"}}}',
		'{"workspaces":{"alpha":{"status":"active","path":"shared"},"beta":{"status":"active","path":"shared"}}}',
		'{"workspaces":{"alpha":{"status":"active","path":"alpha","remote":"https://example.com/not-github","kind":""}}}',
	}
	for _, bytes in ipairs(fixtures) do
		local value = runtime.json.decode(bytes)
		local expected = projects.decode_registry(value, "/Glitch root/")
		local actual = adapter.decode_registry(value, "/Glitch root/", runtime.json.encode)
		check((expected == nil) == (actual == nil), "both actual decoders agree on registry acceptance")
		if expected then check(same(expected, actual), "same fixture has identical active-project paths, remotes and ordering") end
	end
	local roots = { "/", "/opt/Glitch root/", "C:\\Users\\Name\\Glitch\\", "\\\\server\\share\\", "relative", "/bad/../root", "/a..b", "/bad\nroot" }
	for _, os in ipairs({ "linux", "windows", "macos" }) do for _, value in ipairs(roots) do
		if value ~= "/a..b" then check(adapter.normalize_root(value, os) == config.normalize_root(value, os), "root semantics match WORK on " .. os) end
	end end
	check(adapter.normalize_root("/a..b/") == "/a..b" and adapter.normalize_root("/") == "/" and adapter.normalize_root("C:\\") == "C:/",
		"real roots and ordinary dotted directory names survive normalization")
	local reads = {}
	local catalog = assert(adapter.load_projects("/root/", "linux", {
		read = function(path, maximum)
			table.insert(reads, path); check(maximum == 4 * 1024 * 1024, "registry read bounded")
			return '{"workspaces":{"alpha":{"status":"active","path":"alpha"}}}'
		end,
		decode = runtime.json.decode, encode = runtime.json.encode,
	}))
	check(#reads == 1 and reads[1] == "/root/workspaces/registry.json", "listing requires no WORK agent/config read")
	check(catalog.items[1].path == "/root/workspaces/alpha", "host root determines execution workspace")
	local bad, err = adapter.load_projects("/root", "linux", { read = function() error("missing") end })
	rejected(bad, err, "registry_unreadable")
	bad, err = adapter.load_projects("/root", "linux", { read = function() return "not JSON" end, decode = runtime.json.decode })
	rejected(bad, err, "registry_invalid")
end
if section == nil or section == "plans" then
	local catalog = { root = "/host/glitch", items = { { id = "alpha", path = "/host/glitch/workspaces/alpha" } } }
	local bytes = plan_bytes("home: workspace:alpha\n")
	local result = adapter.discover_plans(catalog, {
		{ name = "unrelated-name.md", bytes = bytes }, { name = "old-archive.md", bytes = bytes },
		{ name = "archive/old.md", bytes = bytes }, { name = "../escape.md", bytes = bytes },
		{ name = "neutral.md", bytes = plan_bytes() }, { name = "archived-project.md", bytes = plan_bytes("home: workspace:old\n") },
		{ name = "ambiguous.md", bytes = plan_bytes("home: workspace:alpha\nhome: workspace:other\n") },
		{ name = "notes.md", bytes = "# Notes\n- do something\n" },
	})
	check(#result.items == 4 and #result.rejected == 1, "only supported root plans become candidates; archive/path escapes ignored")
	local by_path = {}; for _, item in ipairs(result.items) do by_path[item.path] = item end
	check(by_path["/host/glitch/plans/unrelated-name.md"].workspace_id == "alpha", "association uses metadata, never filename")
	check(by_path["/host/glitch/plans/neutral.md"].needs_project_choice, "neutral supported schema asks association")
	check(by_path["/host/glitch/plans/archived-project.md"].needs_project_choice, "inactive home is not execution authority")
	check(by_path["/host/glitch/plans/ambiguous.md"].needs_project_choice, "multiple home declarations cannot silently choose first")
	local ambiguous = by_path["/host/glitch/plans/ambiguous.md"].plan
	check(ambiguous.project_hint == nil and table.find(ambiguous.flags, "home_ambiguous"), "ambiguous home cannot strip task paths as if verified")
	local duplicate = adapter.discover_plans(catalog, { { name = "same.md", bytes = bytes }, { name = "same.md", bytes = bytes } })
	check(#duplicate.items == 0 and duplicate.rejected[1].code == "duplicate_path", "ambiguous listing does not pick arbitrary version")
	local source = assert(adapter.read_plan("/host/neutral.md", nil, { read = function(_, maximum) check(maximum == parser.MAX_BYTES, "plan read bounded"); return plan_bytes() end }))
	check(source.kind == "plan_file" and source.plan.project_hint == nil, "Glitch-off neutral plan works without registry")
	local bad, err = adapter.read_plan("/host/neutral.md", "old", { read = function() return plan_bytes() end })
	rejected(bad, err, "source_changed")
	local choices = adapter.class_choices({ source.plan }, { { class = "analysis" } })
	check(#choices == 4 and choices[1].id == "analysis", "class counts derive actual source metadata without static execution routes")
	local found = {}; for _, choice in ipairs(choices) do found[choice.id] = choice end
	check(found.research.count == 2 and found.build == nil, "task class counts reflect parsed work, not a hardcoded build class")
	local plan = assert(parser.parse(bytes))
	check(plan.checkpoints[1].tasks[1].independent and not plan.checkpoints[1].tasks[3].independent, "source retains execution ordering")
	local restored = runtime.json.decode(runtime.json.encode(plan))
	local restored_bytes = runtime.json.encode(restored)
	for cp_index, cp in ipairs(restored.checkpoints) do for task_index, task in ipairs(cp.tasks) do
		check(parser.task_identity(cp, task) == plan.checkpoints[cp_index].tasks[task_index].source_identity,
			"native decoded file/system/argv arrays retain complete semantic identity")
	end end
	check(runtime.json.encode(restored) == restored_bytes, "semantic reconciliation never sorts or strips original native task metadata")
	local declared = [[# Feature: Observed plan conventions
## C0 — Preparation
### UPDATE app/setup.luau — INDEPENDENT
- VALIDATE: `demo setup`
## CP1 — Delivery
### A1 — Build the feature
**INDEPENDENT**
#### Steps
1. Read the source contract
- [x] Resolve the declared input
#### File changes
- [ ] UPDATE app/feature.luau
#### Validation checks
- [ ] `demo check`
### Task Release notes
**AFTER**: A1
**STATE**: paused
This prose describes the work but does not create a new executable task.
## Progress
Everything is done, including a supposed extra task and every validation.
]]
	local metadata = { schema = 1, checkpoints = { { id = "cp0", text = "Preparation", state = "done" },
		{ id = "cp7", text = "CP1 — Delivery", state = "active" } } }
	local state_block = "\n<!-- TERN-SESSION:START -->\n```json\n" .. runtime.json.encode(metadata) .. "\n```\n<!-- TERN-SESSION:END -->\n"
	local observed = assert(parser.parse(declared .. state_block))
	check(#observed.checkpoints == 2 and observed.checkpoints[1].n == 0 and observed.checkpoints[2].id == "cp7"
		and observed.checkpoints[1].state == "done" and observed.checkpoints[2].state == "active",
		"real C0/CP1 headings and explicit TERN-SESSION identity survive checkpoint renumbering")
	local first, second = observed.checkpoints[1].tasks[1], observed.checkpoints[2].tasks
	check(first.independent and first.files[1] == "app/setup.luau" and first.checks[1].argv[1] == "demo",
		"file-action-owned tasks carry declared ownership and plain explicit validation commands")
	check(#second == 2 and second[1].id == "A1" and #second[1].steps == 2 and #second[1].filechanges == 1
		and #second[1].validationchecks == 1 and second[2].state == "paused" and second[2].depends_on[1] == "A1",
		"named tasks, concrete lower structure and explicit dependency/state remain separate from prose")
	check(second[1].state == nil and second[1].steps[1].state == nil and second[1].steps[2].state == "done",
		"Progress prose completes nothing and a checked step does not finish its parent or sibling")
	local literals = [[# Feature: Literal plan examples
## CP1 — Examples
### UPDATE app/example.luau
````text
**STATE**: pending
```
### Task A9 — Literal example, not executable work
- [ ] Literal checkbox
<!-- TERN-SESSION:START -->
{"schema":999}
<!-- TERN-SESSION:END -->
````
#### Steps
- [ ] Implement the actual example
]]
	local literal_plan = assert(parser.parse(literals))
	local changed_literal = assert(parser.parse(literals:gsub("%*%*STATE%*%*: pending", "**STATE**: done")))
	check(#literal_plan.checkpoints[1].tasks == 1 and literal_plan.checkpoints[1].tasks[1].state == nil
		and #literal_plan.checkpoints[1].tasks[1].steps == 1,
		"shorter inner fences cannot turn literal task/session/state examples into execution or explicit progress")
	check(literal_plan.checkpoints[1].tasks[1].source_identity ~= changed_literal.checkpoints[1].tasks[1].source_identity,
		"literal STATE content remains a semantic instruction change, not completion-only bookkeeping")
	local stable = assert(parser.parse(declared:gsub("This prose", "Additional source discussion. This prose") .. state_block))
	check(stable.checkpoints[1].tasks[1].id == first.id and stable.checkpoints[2].tasks[2].id == second[2].id,
		"unrelated source prose cannot renumber action-owned or named tasks")
	local modern = assert(parser.parse(runtime.fs.read(root .. "/tests/fixtures/plan-modern.md")))
	local legacy = assert(parser.parse(runtime.fs.read(root .. "/tests/fixtures/plan-legacy.md")))
	check(#modern.checkpoints == 8 and #legacy.checkpoints[3].tasks == 2, "modern/legacy fixtures retain named work and legacy untasked file actions gain real owned tasks")
	local shapes = [[# Feature: Real heading distinctions
## STEP-BY-STEP TASKS
### Task Format Guidelines
This is schema guidance, not executable work.
### CP0 — Core
#### CP0-T1 CREATE app/first.luau
Implement the first declared file.
#### CP4a — Linked ticket
Investigate this declared work item.
#### C4 model
Compare the selected model.
### Checkpoint 1: Follow through
#### Task Report findings
Write the findings.
]]
	local heading_plan = assert(parser.parse(shapes))
	check(#heading_plan.checkpoints == 2 and #heading_plan.checkpoints[1].tasks == 3 and heading_plan.checkpoints[2].n == 1
		and heading_plan.checkpoints[1].tasks[1].id == "CP0-T1" and heading_plan.checkpoints[1].tasks[1].files[1] == "app/first.luau",
		"Task Format Guidelines is not work; CP0-T1/CP4a/C4 model are tasks while Checkpoint N: is a real separator")
	local session40 = "\n<!-- TERN-SESSION:START -->\n```json\n" .. runtime.json.encode({ schema = 1,
		checkpoints = { { id = string.rep("p", 40), text = "Core", state = "pending" } } }) .. "\n```\n<!-- TERN-SESSION:END -->"
	check(#assert(parser.parse(shapes .. session40)).checkpoints[1].id == 40, "genuine native TODO checkpoint identities retain their supported forty characters")
	local function renumbered(offset, inserted)
		return "# Feature: Stable source identity\n" .. (if inserted then "### CP1 — New prerequisite\n### UPDATE app/prerequisite.luau\nPrepare the prerequisite.\n" else "")
			.. "### CP" .. tostring(1 + offset) .. " — Stable research\n#### Task Explore alternatives\nCompare the alternatives.\n"
			.. "### CP" .. tostring(2 + offset) .. " — Stable implementation\n### UPDATE app/stable.luau\nImplement the accepted alternative.\n- VALIDATE: `demo stable`\n"
	end
	local original, inserted = assert(parser.parse(renumbered(0, false))), assert(parser.parse(renumbered(1, true)))
	for i = 1, 2 do
		local old_cp, new_cp = original.checkpoints[i], inserted.checkpoints[i + 1]
		check(old_cp.id == new_cp.id and old_cp.tasks[1].id == new_cp.tasks[1].id and old_cp.tasks[1].source_identity == new_cp.tasks[1].source_identity,
			"checkpoint insertion/renumbering preserves named/action logical identity and exact execution-content identity")
		local legacy_cp, legacy_task = table.clone(old_cp), table.clone(old_cp.tasks[1])
		legacy_cp.id, legacy_cp.n = "cp-legacy", 99; legacy_task.id, legacy_task.state = "legacy-task", "done"
		legacy_task.source_identity = nil
		check(parser.task_identity(legacy_cp, legacy_task) == new_cp.tasks[1].source_identity, "the exported reconciler computes the same identity from genuine legacy-shaped stored fields")
		local changed_task = table.clone(legacy_task); changed_task.text ..= "\nDifferent executable instructions."
		check(parser.task_identity(legacy_cp, changed_task) ~= new_cp.tasks[1].source_identity, "changed execution instructions cannot masquerade as old managed proof")
	end
	local function repeated_actions(bodies)
		local value = "# Feature: Repeated actual file owners\n### C3 — Shared native plugin\n"
		for _, body in ipairs(bodies) do value ..= "### UPDATE plugins/tern\n" .. body .. "\n" end
		return assert(parser.parse(value))
	end
	local repeated_owners, reversed_owners = repeated_actions({ "Intake owner.", "Conversation owner." }), repeated_actions({ "Conversation owner.", "Intake owner." })
	check(repeated_owners.checkpoints[1].tasks[1].id == reversed_owners.checkpoints[1].tasks[2].id
		and repeated_owners.checkpoints[1].tasks[2].id == reversed_owners.checkpoints[1].tasks[1].id,
		"the approved repeated file-action shape parses and distinct owner bodies retain identities when reordered")
	local ambiguous = repeated_actions({ "Intake owner.", "Conversation owner.", "Intake owner." })
	check(ambiguous.checkpoints[1].tasks[1].identity_ambiguous == true and ambiguous.checkpoints[1].tasks[3].identity_ambiguous == true
		and ambiguous.checkpoints[1].tasks[2].identity_ambiguous == nil,
		"identical repeated work is explicitly ambiguous for the host's managed-association hold, never silently rebound by ordinal")
	local cycle = [[# Feature: Invalid dependencies
### Checkpoint 1 — Work
#### Task A1 — First
**AFTER**: A2
#### Task A2 — Second
]]
	bad, err = parser.parse(cycle); rejected(bad, err, "dependency_invalid")
	bad, err = parser.parse(cycle:gsub("A2\n####", "missing\n####")); rejected(bad, err, "dependency_invalid")
	bad, err = parser.parse(declared .. "\n<!-- TERN-SESSION:START -->\n{not json}\n<!-- TERN-SESSION:END -->")
	rejected(bad, err, "session_invalid")
end
if section == nil or section == "board" then
	local plan = assert(parser.parse(plan_bytes()))
	local before = quota.digest(plan)
	local description = assert(project(plan, "/host/plan.md", snapshot(), "Work"))
	check(#description.creates == 7 and #description.updates == 0, "native board contains plan, checkpoints and tasks as separately addressable cards")
	check(quota.digest(plan) == before, "presentation cannot mutate source execution")
	local by_id = {}; for _, item in ipairs(description.creates) do by_id[item.task_id] = item end
	check(not by_id.A2.card.text:find("After:", 1, true), "parallel tasks do not acquire false dependency")
	for _, predecessor in ipairs(plan.checkpoints[1].tasks) do
		check(by_id.B1.card.text:find(predecessor.title, 1, true), "checkpoint joins retain human-readable prerequisite tasks")
		if predecessor.id ~= "A3" then check(by_id.A3.card.text:find(predecessor.title, 1, true), "dependent tasks retain their human-readable prerequisite tasks") end
	end
	local root_card, cp_card = description.creates[1], description.creates[2]
	check(cp_card.card.text:find(plan.title, 1, true) and by_id.A1.card.text:find(plan.checkpoints[1].title, 1, true),
		"separate checkpoint and task cards retain visible human parent relationships")
	for _, item in ipairs(description.creates) do
		local metadata = assert(projection(item.card.text))
		local visible = item.card.text:gsub("%[([^%]]*)%]%((tern://orchplus%-plan%?[^%)]+)%)", "%1")
		check(metadata.node_id == item.task_id and metadata.path == "/host/plan.md" and metadata.board_key == codec.sha256(snapshot().path)
			and not visible:find(metadata.baseline, 1, true) and not visible:find(metadata.node_id, 1, true)
			and not visible:find(metadata.path, 1, true) and item.card.tags == nil,
			"actual projection identity and baseline remain in a bound native hyperlink, not visible card metadata or the lossy tag setter")
	end
	check(#root_card.task_id > parser.MAX_TASK_ID and #cp_card.task_id > parser.MAX_TASK_ID,
		"administrative board identities cannot collide with an executable task named plan or checkpoint")
	local destinations = {}
	for _, item in ipairs(description.creates) do destinations[item.card.lane] = true end
	local other_source = assert(project(plan, "/host/another-plan.md", snapshot(), "Work"))
	for _, item in ipairs(other_source.creates) do destinations[item.card.lane] = true end
	local destination_count = 0; for _ in pairs(destinations) do destination_count += 1 end
	check(destination_count == 2 and root_card.card.lane ~= by_id.A1.card.lane,
		"multiple plans and checkpoints share overview and task lanes instead of multiplying columns per source or task")
	local board = materialize(description)
	local repeated = assert(project(plan, "/host/plan.md", board, "Different lane"))
	check(#repeated.creates == 0 and #repeated.updates == 0 and #repeated.unchanged == 7, "unchanged automatic synchronization neither duplicates cards nor changes human lane")
	do
		local tagged_bytes = "# Feature: Source hashtags\n## CP1 — Evidence\n### Task A1 — Read facts\nRead #source carefully · tail #tail\n"
		local tagged = assert(parser.parse(tagged_bytes))
		local initial = assert(project(tagged, "/host/hashtags.md", snapshot(), "Work"))
		local native = materialize(initial)
		local unchanged = assert(project(tagged, "/host/hashtags.md", native, "Work"))
		check(#unchanged.unchanged == 3 and #unchanged.conflicts == 0 and #unchanged.updates == 0,
			"native full-text tag readback matches hash-proven source descriptions without perpetual human conflicts")
		local target
		for i, item in ipairs(initial.creates) do if item.task_id == "A1" then target = native.lanes[1].cards[i] end end
		target.text ..= " #human"; target.tags = native_tags(target.text)
		local changed = assert(parser.parse(tagged_bytes:gsub("carefully", "differently")))
		local delta = assert(project(changed, "/host/hashtags.md", native, "Work"))
		local patch = assert(delta.updates[1]).fields
		check(#delta.updates == 1 and patch.text:find("Read #source differently · tail #tail", 1, true)
			and patch.text:find(" #human", 1, true), "real source edits preserve inline/trailing source hashtags and human footer metadata")
		target.text, target.tags = patch.text, native_tags(patch.text)
		local _, source_count = target.text:gsub(" #source", ""); local _, tail_count = target.text:gsub(" #tail", "")
		local settled = assert(project(changed, "/host/hashtags.md", native, "Work"))
		check(source_count == 1 and tail_count == 1 and #settled.updates == 0 and #settled.conflicts == 0,
			"source-body hashtags are not copied into metadata suffixes or duplicated on the next native poll")
		local no_source_tag = assert(parser.parse(tagged_bytes:gsub("#source", "the facts")))
		local removed_tag = assert(project(no_source_tag, "/host/hashtags.md", native, "Work"))
		check(not removed_tag.updates[1].fields.text:find(" #source", 1, true) and removed_tag.updates[1].fields.text:find(" #human", 1, true),
			"removing a source-body hashtag does not retain it as invented human metadata or lose an actual human tag")
		-- Actual native explicit-tag edits relocate body hashtags. That changes
		-- meaningful source text; it is not permission for an automatic overwrite.
		target.text = target.text:gsub("Read #source differently", "Read  differently"):gsub("tail #tail", "tail") .. " #source #tail"
		target.tags = native_tags(target.text)
		local edited = assert(project(changed, "/host/hashtags.md", native, "Work"))
		check(#edited.conflicts == 1 and edited.conflicts[1].code == "human_edit" and #edited.updates == 0,
			"native hashtag relocation or any meaningful human body change remains a real conflict")
		local marker_plan = assert(parser.parse(tagged_bytes:gsub("#tail", "#orchplus-plan-mirror")))
		local marker_native = materialize(assert(project(marker_plan, "/host/marker.md", snapshot(), "Work")))
		local marker_delta = assert(project(marker_plan, "/host/marker.md", marker_native, "Work"))
		check(#marker_delta.unchanged == 3 and #marker_delta.conflicts == 0,
			"a literal trailing source-body marker remains source content without being mistaken for ownership metadata")
		for _, row in ipairs(marker_native.lanes[1].cards) do
			if row.text:find("#orchplus-plan-mirror", 1, true) then
				row.text = row.text:gsub("projection=2", "projection=3"); row.tags = native_tags(row.text)
			end
		end
		local invalid, err = project(marker_plan, "/host/marker.md", marker_native, "Work")
		rejected(invalid, err, "projection_invalid")
	end
	do
		local metadata = assert(projection(description.creates[1].card.text))
		check(metadata.nav_url == adapter.plan_link_base(string.rep("a", 24), "/host/plan.md", codec.sha256(snapshot().path)),
			"projection navigation retains the exact owning scope, execution-host source and desktop board")
		for _, changed_url in ipairs({ metadata.url .. "&extra=ignored", metadata.url .. "&done=true",
			(metadata.url:gsub("projection=2", "projection=3")), (metadata.url:gsub("node=[^&]+", "node=%%ZZ")) }) do
			check(adapter.parse_plan_link(changed_url) == nil, "unknown, duplicate, unsupported or malformed projection metadata is refused")
		end
		local invalid, err = adapter.plan_to_board(plan, "/host/plan.md", snapshot(), "Work", nil,
			adapter.plan_link_base(string.rep("a", 24), "/host/plan.md", codec.sha256("/desktop/Other.md")))
		rejected(invalid, err, "source_invalid")
		local damaged = materialize(description)
		damaged.lanes[1].cards[1].text = damaged.lanes[1].cards[1].text:gsub("projection=2", "projection=3")
		check(#assert(adapter.board_intakes(damaged)) == 0, "an edited projection address never becomes a second executable intake")
		invalid, err = project(plan, "/host/plan.md", damaged, "Work")
		rejected(invalid, err, "projection_invalid")
		local navigation = adapter.plan_link_base(string.rep("a", 24), "/host/plan.md")
		local human = snapshot({ { id = "human-link", text = "Compare sources [Reference](" .. navigation .. ")", tags = {}, done = false } })
		check(#assert(adapter.board_intakes(human)) == 1, "ordinary human source links without projection ownership remain normal intake")
	end
	do
		local legacy_path = "/host/legacy.md"
		local legacy_plan = assert(parser.parse("# Feature: Retained legacy source\n## CP1 — Evidence\n### Task A1 — Gather facts\nRead old evidence.\n"))
		local native = materialize(assert(project(legacy_plan, legacy_path, snapshot(), "Work")))
		local target
		for _, row in ipairs(native.lanes[1].cards) do if assert(projection(row.text)).node_id == "A1" then target = row end end
		local old_body = "Gather facts · Source: " .. legacy_path .. " · Node: A1 · Read old evidence. · [Open execution-host plan]("
			.. adapter.plan_link_base(string.rep("a", 24), legacy_path) .. ")"
		target.text = old_body .. " #orchplus-plan-mirror #orchplus-source-" .. codec.sha256(legacy_path) .. "-A1 #orchplus-base-"
			.. codec.sha256(old_body) .. " #orchplus-revision-" .. legacy_plan.plan_revision .. " #orchplus-kind-task #human"
		target.tags = native_tags(target.text)
		local legacy_text = target.text
		local migrated = assert(project(legacy_plan, legacy_path, native, "Work"))
		local migration = assert(migrated.updates[1])
		check(#migrated.updates == 1 and #migrated.creates == 0 and migration.task_id == "A1" and projection(migration.fields.text)
			and migration.fields.tags == nil and #native_tags(migration.fields.text) == 1 and native_tags(migration.fields.text)[1] == "human",
			"baseline-proved legacy cards migrate through text-only native edit, retaining human metadata without visible machine tags")
		target.text = legacy_text:gsub("Read old evidence", "Read human evidence"); target.tags = native_tags(target.text)
		local edited = assert(project(legacy_plan, legacy_path, native, "Work"))
		check(#edited.updates == 0 and #edited.creates == 0 and #edited.conflicts == 1 and edited.conflicts[1].code == "human_edit"
			and #native_tags(edited.conflicts[1].proposed_fields.text) == 1,
			"an unproved legacy baseline requires a real human-edit decision and never carries obsolete machine tags into its proposal")
		check(#assert(adapter.board_intakes(native)) == 0, "both current projections and kept legacy mirrors remain presentation-only intake")
	end
	do
		local long_path = "/desktop/" .. string.rep(string.rep('"', 250) .. "/", 16) .. string.rep('"', 62) .. "/Board.md"
		local empty = snapshot(); empty.path = long_path
		local native = materialize(assert(project(plan, "/host/plan.md", empty, "Work"))); native.path = long_path
		for i, row in ipairs(native.lanes[1].cards) do row.id = runtime.json.encode({ long_path, 9007199254740991, 9007199254740991 - i }) end
		local delta = assert(project(plan, "/host/plan.md", native, "Work"))
		check(#long_path == 4096 and #native.lanes[1].cards[1].id > 8192 and #delta.unchanged == 7,
			"full path-derived native opaque identities survive synchronization without arbitrary short limits or truncation")
		native.lanes[1].cards[1].text_clipped = true
		local clipped, clipped_error = project(plan, "/host/plan.md", native, "Work")
		rejected(clipped, clipped_error, "board_incomplete")
	end
	local prose_revision = assert(parser.parse(plan_bytes() .. "\n## Progress\nA bookkeeping note, not completion.\n"))
	local prose_only = assert(project(prose_revision, "/host/plan.md", board, "Work"))
	check(prose_revision.plan_revision ~= plan.plan_revision and #prose_only.updates == 0 and #prose_only.creates == 0 and #prose_only.unchanged == 7,
		"whole-file Progress-only revisions create no native edits or completion changes")
	local yielded, completed = 0, nil
	local co = coroutine.create(function()
		completed = assert(project(plan, "/host/plan.md", board, "Different lane", function() yielded += 1; coroutine.yield() end))
	end)
	while coroutine.status(co) ~= "dead" do
		check(completed == nil, "suspended synchronization exposes no partial effects")
		local ok, err = coroutine.resume(co); assert(ok, err)
	end
	check(yielded >= 12 and same(completed, repeated), "bounded cooperative work preserves exact synchronization result")
	check(#assert(adapter.board_intakes(board)) == 0, "none of the hierarchy mirror levels become independent executable intake")
	local card
	for i, item in ipairs(description.creates) do if item.task_id == "A1" then card = board.lanes[1].cards[i] end end
	card.done = true; card.due = "2030-01-01"; card.text ..= " #human-priority"; table.insert(card.tags, "human-priority")
	local changed = assert(parser.parse(plan_bytes():gsub("Collect public references%.", "Collect primary public references.")))
	local updates = assert(project(changed, "/host/plan.md", board, "Work"))
	check(#updates.creates == 0 and #updates.updates == 1, "only a substantively changed description is edited; unrelated source revision tags do not rewrite every native card")
	local patch
	for _, item in ipairs(updates.updates) do if item.task_id == "A1" then patch = item.fields end end
	check(table.find(native_tags(patch.text), "human-priority") and patch.tags == nil and patch.due == nil and patch.done == nil and patch.lane == nil,
		"descriptions preserve human tags, due dates and lane; native check is a separate supported API")
	card.text ..= " Human clarification"
	local conflict = assert(project(changed, "/host/plan.md", board, "Work"))
	check(#conflict.conflicts == 1 and conflict.conflicts[1].code == "human_edit" and #conflict.updates == 0
		and conflict.conflicts[1].proposed_fields.text:find(" #human-priority", 1, true), "human text is never overwritten and a real decision cannot quietly delete its human tag metadata")
	local same_conflict = assert(project(assert(parser.parse(plan_bytes():gsub("Collect public references%.", "Collect primary public references.") .. "\n## Progress\nAnother bookkeeping note.\n")), "/host/plan.md", board, "Work"))
	check(same_conflict.conflicts[1].signature == conflict.conflicts[1].signature, "unchanged human conflict content retains its decision identity across Progress-only revisions")
	local copy = table.clone(card); copy.id = "duplicate-card"; table.insert(board.lanes[1].cards, copy)
	local duplicated = assert(project(plan, "/host/plan.md", board, "Work"))
	check(duplicated.conflicts[1].code == "duplicate_provenance" and #duplicated.creates == 0, "duplicate provenance is a real conflict, not guessed identity")
	table.remove(board.lanes[1].cards)
	local removed = table.clone(plan); removed.checkpoints = { plan.checkpoints[1] }
	local removal = assert(project(removed, "/host/plan.md", board, "Work"))
	check(#removal.removed == 2, "removed checkpoint and child task remain visible retained history, not silently deleted")
	local retired = 0; for _, item in ipairs(removal.updates) do local metadata = projection(item.fields.text); if metadata and metadata.retired then retired += 1 end end
	check(retired == 2, "unmodified removed hierarchy cards get explicit historical provenance")
	local lower = assert(parser.parse([[# Feature: Concrete source
## CP1 — Delivery
### Task A1 — Change a file
**STATE**: active
#### Steps
- [x] Read the contract
- [ ] Implement the change
#### File changes
- [ ] UPDATE app/source.luau
#### Validation checks
- [ ] `demo check`
]]))
	local hierarchy = assert(project(lower, "/host/concrete.md", snapshot(), "Work"))
	check(#hierarchy.creates == 7, "steps, files and checks are all independent native presentation cards")
	local kinds, checked = {}, 0
	for _, item in ipairs(hierarchy.creates) do
		local metadata = assert(projection(item.card.text)); kinds[metadata.kind] = true
		if item.done == true then checked += 1 end
	end
	check(kinds.step and kinds.file and kinds.check and checked == 1, "only the explicitly checked source step gets completed native progress")
	local native = materialize(hierarchy)
	for i, item in ipairs(hierarchy.creates) do if item.done ~= nil then native.lanes[1].cards[i].done = item.done end end
	local pending = assert(parser.parse([[# Feature: Concrete source
## CP1 — Delivery
### Task A1 — Change a file
**STATE**: done
#### Steps
- [x] Read the contract
- [ ] Implement the change
#### File changes
- [ ] UPDATE app/source.luau
#### Validation checks
- [ ] `demo check`
]]))
	local progress = assert(project(pending, "/host/concrete.md", native, "Work"))
	local done_task
	for _, item in ipairs(progress.updates) do if item.task_id == "A1" then done_task = item end end
	check(done_task.done == true and #progress.creates == 0, "explicit task progress changes native check without fabricating child completion")
	board.more = 1
	local bad, err = project(plan, "/host/plan.md", board, "Work")
	rejected(bad, err, "board_incomplete")
	board.more = 0; board.lanes[1].more = 1
	bad, err = adapter.board_intakes(board); rejected(bad, err, "board_incomplete")
	local independent = snapshot({ { id = "one", text = "Research this question", tags = { "research" }, done = false },
		{ id = "two", text = "Research this question", tags = { "research" }, done = false },
		{ id = "done", text = "Completed research", tags = {}, done = true },
		{ id = "partial-mirror", text = "Mirror without main marker", tags = { "orchplus-source-old" }, done = false } })
	local intakes = assert(adapter.board_intakes(independent))
	check(#intakes == 1 and intakes[1].card_id == "one", "independent intake deduplicates and excludes all mirror provenance")
	check(intakes[1].text_sha256 == quota.digest({ text = independent.lanes[1].cards[1].text, tags = { "research" } }), "native intake uses host's canonical source digest")
	check(not adapter.is_plan_mirror({ "research", "orchplus-user" }), "ordinary human tags remain independent intake")
	local native_board = runtime.json.decode(runtime.json.encode(independent))
	local native_intakes = assert(adapter.board_intakes(native_board))
	check(native_intakes[1].text_sha256 == intakes[1].text_sha256 and native_intakes[1].tags[1] == "research",
		"native protected board tags survive intact through intake digest and command fields")
	local native_empty = runtime.json.decode(runtime.json.encode(snapshot({ { id = "empty", text = "Native task without tags", tags = runtime.json.array(), done = false } })))
	check(runtime.json.encode(assert(adapter.board_intakes(native_empty))[1].tags) == "[]",
		"empty native tag arrays retain array shape in the actual intake payload")
end
if section == nil or section == "template" then
	local template = { id = "research", title = "Research", prompt = "Investigate {input}", output = "notes/result.md", next = "", class = "research" }
	local revision = quota.digest(template)
	local source = assert(adapter.template_source(template, revision, "A neutral question"))
	check(source.kind == "template" and source.input == "A neutral question" and source.template_id == "research", "neutral template produces passive source without a Glitch workspace")
	check(source.command == nil and source.started == nil and source.prompt == nil, "template source carries no executable authority or fabricated task")
	local bad, err = adapter.template_source(template, "stale", "Question"); rejected(bad, err, "source_changed")
	bad, err = adapter.template_source(template, revision, "  "); rejected(bad, err, "input_invalid")
	local unsafe = table.clone(template); unsafe.output = "../outside.md"
	bad, err = adapter.template_source(unsafe, quota.digest(unsafe), "Question"); rejected(bad, err, "template_invalid")
	local invalid = table.clone(template); invalid.prompt = "{input} and {input}"
	bad, err = adapter.template_source(invalid, quota.digest(invalid), "Question"); rejected(bad, err, "template_invalid")
	local windows = table.clone(template); windows.output = "notes\\result.md"
	check(adapter.template_source(windows, quota.digest(windows), "Question") ~= nil, "existing relative Windows template output remains supported")
	local custom = table.clone(template); custom.custom_fields = { audience = "engineers", topic = "" }; custom.prompt = "Investigate {input} for {audience} about {topic}"; custom.output = "notes/{audience}.md"
	local selected = assert(adapter.template_source(custom, quota.digest(custom), "The question", { audience = "designers", topic = "native UI" }))
	check(selected.custom_fields.audience == "designers" and selected.custom_fields.topic == "native UI", "per-invocation custom values survive as real template command inputs")
	bad, err = adapter.template_source(custom, quota.digest(custom), "The question", { audience = "../escape" }); rejected(bad, err, "input_invalid")
	bad, err = adapter.template_source(custom, quota.digest(custom), "The question", { unknown = "ignored?" }); rejected(bad, err, "input_invalid")
	local defaults_only = assert(adapter.template_source(custom, quota.digest(custom), "The question", {}))
	local partial = assert(adapter.template_source(custom, quota.digest(custom), "The question", { audience = "designers" }))
	check(next(defaults_only.custom_fields) == nil and partial.custom_fields.audience == "designers" and partial.custom_fields.topic == nil,
		"effective defaults validate this template but are not materialized as invocation overrides for the next template")
	bad, err = adapter.template_source(custom, quota.digest(custom), string.rep("x", 2049)); rejected(bad, err, "input_invalid")
end
assert(section == nil or section == "registry" or section == "plans" or section == "board" or section == "template", "unknown source adapter section")
return "source_adapter/" .. tostring(section or "all") .. ": " .. tostring(checks) .. " checks"
