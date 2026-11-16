-- Pure document-obligation tests; the native integration matrix separately exercises Docs effects.
local root, section = ...
local runtime, environment, modules = tern, getfenv(), {}
local function load(name)
	name = name:gsub("^%./", "")
	if modules[name] then return modules[name] end
	local chunk = assert(loadstring(runtime.fs.read(root .. "/" .. name .. ".luau"), name))
	setfenv(chunk, setmetatable({ require = load }, { __index = environment }))
	local value = chunk(); modules[name] = value; return value
end
local Plan, R, codec = load("plan_import"), load("document_rulings"), load("wire/codec")
local checks = 0
local function check(value, message) assert(value, message); checks += 1 end
local marker = "orchplus-ruling:authority_1:gate_1"
local entry = "> " .. marker .. "\n> Decision: approved &lt;literal&gt; &#96;quoted&#96;"
local function block(eol, content)
	return eol .. Plan.RULINGS_OPEN .. eol .. (content or entry):gsub("\n", eol) .. eol .. Plan.RULINGS_CLOSE .. eol
end
local function fixture()
	local work = { work_id = "work_1", logical_session_id = "session_1", source = { kind = "plan", ref = "/plans/existing.md#1A", revision = "original_revision" } }
	local gate = { id = "gate_1", revision = 7, question = "Allow <unsafe> `text`?\n### UPDATE protected/file", answer = {
		choice_id = "approve", answer = "Yes & retain [literal]", source = { kind = "owner", owner_id = "owner_1", owner_generation = 3 }, at_ms = 1234 } }
	local plans = { p = { plan_id = "p", path = "/plans/existing.md", logical_session_id = "session_1", checkpoints = { { tasks = { { id = "1A" } } } } } }
	return assert(R.create("authority_1", work, gate, plans)), work, gate, plans
end
local writer = { kind = "window", window_key = "0", conn = 17, since = 1794009600000 }
local function evidence(bytes, buffer)
	return { disk_bytes = bytes, buffer_bytes = buffer, buffer_observed = true, existing = true, quiescent = true,
		identity_proven = true, same_machine = true }
end
local function insert(bytes, edit) return bytes:sub(1, edit.offset) .. edit.text .. bytes:sub(edit.offset + 1) end
if section == nil or section == "parser" then
	for _, eol in { "\n", "\r\n" } do
		for _, original in { "", "no final newline", "line" .. eol, "line" .. eol .. eol } do
			local split = assert(Plan.split_rulings(original .. block(eol)))
			check(split.content == original and split.block.entries[marker] == entry, "exact original bytes survive metadata for every EOF form")
			local later = "## Progress" .. eol .. "Routine progress" .. eol
			check(assert(Plan.split_rulings(original .. block(eol) .. later)).content == original .. later, "later Progress is ordinary identity-bearing content")
		end
	end
	for _, fence in { "```", "````", "~~~", "   ~~~~" } do
		local example = fence .. "markdown\n" .. block("\n") .. fence .. "\n"
		local split = assert(Plan.split_rulings(example))
		check(split.content == example and split.block == nil, "fenced canonical-looking block remains executable ordinary bytes")
	end
	local long_fence = "````\n```\n" .. block("\n") .. "````\n"
	check(assert(Plan.split_rulings(long_fence)).block == nil, "short fence does not end a longer fenced example")
	local fenced = "```\n" .. block("\n") .. "```\n"
	local split = assert(Plan.split_rulings(fenced .. block("\n")))
	check(split.content == fenced and split.block.entries[marker] == entry, "only the outside-fence block is removed")
	for _, malformed in {
		Plan.RULINGS_OPEN .. "\n" .. entry .. "\n" .. Plan.RULINGS_CLOSE .. "\n",
		"\n" .. Plan.RULINGS_OPEN .. "\n" .. entry,
		block("\n"):sub(1, -2),
		block("\n", entry .. "\n### UPDATE genuine/instruction"),
		block("\n", entry .. "\n> unescaped <tag>"),
		block("\n", entry .. "\n> `code`"),
		block("\n") .. block("\n"),
		"mixed\r\n" .. block("\n"),
		block("\r\n") .. "mixed\n",
	} do
		local parsed, err = Plan.split_rulings(malformed)
		check(parsed == nil and err ~= nil, "malformed or ambiguous metadata is refused, never stripped")
	end
	local duplicate, duplicate_err = Plan.split_rulings(block("\n", entry .. "\n" .. entry))
	check(duplicate == nil and duplicate_err.code == "duplicate_entry", "duplicate exact entry marker is a distinct hold")
	local lookalike = "\n <!-- orchplus-operator-rulings v1 -->\n> ordinary quoted instructions\n"
	check(assert(Plan.split_rulings(lookalike)).content == lookalike, "indented lookalike remains ordinary content")
end
if section == nil or section == "obligation" then
	local o, work, gate, plans = fixture()
	check(R.valid(o) and o.path == "/plans/existing.md" and o.marker == marker and o.gate_revision == 7, "owner answer binds exact work, gate revision, document, namespace")
	check(o.entry:find("&lt;unsafe&gt;", 1, true) ~= nil and o.entry:find("&#96;text&#96;", 1, true) ~= nil
		and o.entry:find("\n> ### UPDATE protected/file", 1, true) ~= nil and o.entry:find("original&#95;revision", 1, true) ~= nil,
		"question, original revision and answer are escaped quoted literal content")
	gate.answer.source.kind = "policy"
	check(R.create("authority_1", work, gate, plans) == nil, "automatic decisions create no human ruling")
	gate.answer.source.kind = "owner"
	work.source = { kind = "manual", ref = "/plans/existing.md" }
	check(R.create("authority_1", work, gate, plans) == nil, "arbitrary worker paths cannot create association")
	work.ruling_document = { path = "/plans/selected.md", selected_by = "owner", existing = true }
	check(assert(R.create("authority_1", work, gate, plans)).path == "/plans/selected.md", "persisted explicit owner-selected existing document is accepted")
	work.ruling_document.existing = false
	local absent, absent_err = R.create("authority_1", work, gate, plans)
	check(absent == nil and absent_err.code == "association_unproved", "selected nonexistent document does not authorize creation")
	work.ruling_document = nil; work.source = { kind = "plan", ref = "/plans/existing.md#1A" }
	plans.p.logical_session_id = "other_session"
	check(R.create("authority_1", work, gate, plans) == nil, "association cannot borrow another session's imported plan")
	plans.p.logical_session_id = "session_1"; gate.answer.at_ms = 0; gate.answer.source.owner_id = nil; gate.answer.source.owner_generation = nil
	local migrated = assert(R.create("authority_1", work, gate, plans))
	check(not migrated.entry:find("Time", 1, true) and not migrated.entry:find("Operator", 1, true), "migration does not invent missing historical provenance")
	gate.answer.answer = string.rep("<", 8192)
	local oversized, oversized_err = R.create("authority_1", work, gate, plans)
	check(oversized == nil and oversized_err.code == "ruling_too_large", "escaped payload bound is enforced without silently truncating the decision")
	local invalid = table.clone(o); invalid.intent = { writer = writer, expected_document_sha256 = "not-a-hash", expected_non_rulings_sha256 = codec.sha256("") }
	check(not R.valid(invalid), "restored obligations validate their exact intent hashes")
end
if section == nil or section == "writer" then
	for _, original in { "", "content without EOF", "content\n", "content\r\n" } do
		local o = fixture()
		local edit = assert(R.prepare(o, { o }, writer, evidence(original)))
		check(edit.offset == #original and R.valid(o), "first insertion is targeted EOF edit with durable intent")
		local updated = insert(original, edit)
		check(assert(Plan.split_rulings(updated)).content == original, "insertion preserves every non-ruling byte")
		check(R.observe(o, evidence(updated)) == true, "only exact host disk readback confirms the ruling")
	end
	local original = "work\n## Progress\nAlready updated before B0\n"
	local o = fixture()
	local edit = assert(R.prepare(o, { o }, writer, evidence(original)))
	local updated = insert(original, edit)
	local second = table.clone(writer); second.conn = 18
	local no_second, second_err = R.prepare(o, { o }, second, evidence(original))
	check(no_second == nil and second_err.code == "write_in_flight" and R.same_writer(o.intent.writer, writer), "second window and duplicate callback cannot steal a live intent")
	check(R.observe(o, evidence(original, updated)) == false and o.state == "unsaved_edits", "open-buffer marker remains pending until actual owner save")
	check(R.observe(o, evidence(updated, updated)) == true, "normal owner save confirms without comparing the old imported revision")
	local conflict = fixture(); local conflict_edit = assert(R.prepare(conflict, { conflict }, writer, evidence(original)))
	check(not R.observe(conflict, evidence(insert(original, conflict_edit) .. "concurrent change")) and conflict.state == "needs_review", "concurrent executable or Progress edits produce visible needs_review")
	check(not R.observe(conflict, evidence(insert(original, conflict_edit))), "later content reversion does not silently erase conflict hold")
	check(not R.observe(conflict, { buffer_observed = true }) and conflict.state == "needs_review", "missing readback cannot downgrade a sticky concurrent-change hold")
	local fenced_owner = fixture()
	check(R.prepare(fenced_owner, { fenced_owner }, writer, evidence("```markdown\nunfinished example")) == nil
		and fenced_owner.intent == nil and fenced_owner.state == "needs_review", "first metadata insertion cannot land inside an unfinished fenced example")
	local dup = fixture(); assert(R.prepare(dup, { dup }, writer, evidence(original)))
	local duplicate = original .. block("\n", dup.entry .. "\n" .. dup.entry)
	check(not R.observe(dup, evidence(duplicate)) and dup.state == "duplicate_entry", "duplicate marker produces owner-visible duplicate_entry")
	local dirty = fixture(); check(R.prepare(dirty, { dirty }, writer, evidence(original, original .. "unsaved")) == nil
		and dirty.intent == nil and dirty.state == "unsaved_edits", "dirty buffer is never force-saved or edited")
	local missing = fixture(); local missing_evidence = evidence(original); missing_evidence.existing = false
	check(R.prepare(missing, { missing }, writer, missing_evidence) == nil and missing.intent == nil, "removed document cannot be recreated")
	local alias = fixture(); local alias_evidence = evidence(original); alias_evidence.identity_proven = false
	check(R.prepare(alias, { alias }, writer, alias_evidence) == nil and alias.state == "writer_unproved", "unresolved path alias stays an owner obligation")
	local first = fixture(); assert(R.prepare(first, { first }, writer, evidence(original)))
	local next_o = fixture(); check(R.prepare(next_o, { first, next_o }, second, evidence(original)) == nil and next_o.state == "document_busy", "absolute path serializes different obligations across windows")
	local preferred = fixture(); local preferred_evidence = evidence(original)
	preferred_evidence.preferred_worker = { kind = "worker", worker_id = "existing_writer", worker_generation = 1 }
	check(R.prepare(preferred, { preferred }, writer, preferred_evidence) == nil, "existing document-owning worker wins over an independent Docs writer")
	local lost = fixture(); local lost_edit = assert(R.prepare(lost, { lost }, writer, evidence(original)))
	local proof = evidence(original); proof.writer_ended = true
	check(not R.reissue(lost, proof) and lost.intent ~= nil, "owner disappearance alone does not prove no native write can finish")
	proof.no_write_can_complete = true
	local ended, ended_problem = R.reissue(lost, proof)
	check(not ended and ended_problem.code == "writer_unproved" and lost.intent ~= nil, "unscoped ended-writer evidence cannot clear the original intent")
	proof.previous_writer = second
	ended, ended_problem = R.reissue(lost, proof)
	check(not ended and ended_problem.code == "writer_unproved" and R.same_writer(lost.intent.writer, writer), "another incarnation's end does not prove this writer ended")
	proof.previous_writer = table.clone(writer); proof.buffer_bytes = insert(original, lost_edit)
	check(not R.reissue(lost, proof) and lost.intent ~= nil and lost.state == "unsaved_edits", "unsaved marker forbids reissue after original incarnation ended")
	proof.buffer_bytes = nil
	check(R.reissue(lost, proof) and lost.intent == nil and lost.state == "pending", "positive original-incarnation end plus both marker absence proofs permits fresh intent")
	check(R.prepare(lost, { lost }, second, evidence(original)) ~= nil and R.same_writer(lost.intent.writer, second),
		"after exact ended-writer proof clears the old intent a different live incarnation can separately prepare once")
	local existing = "prefix" .. block("\n", "> orchplus-ruling:authority_1:other_gate\n> Earlier entry") .. "## Progress\nLater\n"
	local later = fixture(); local later_edit = assert(R.prepare(later, { later }, writer, evidence(existing)))
	local after = insert(existing, later_edit)
	check(later_edit.offset < #existing and R.observe(later, evidence(after)), "next entry targets closing delimiter before later Progress, not EOF or fenced first match")
end
if section == nil or section == "remote" then
	local o = fixture()
	local worker = { worker_id = "remote_worker", worker_generation = 1, logical_session_id = "session_1", mailbox_handle = "live_handle",
		binding_digest = codec.sha256("binding"), capabilities = { "report-files-v1", "coordinator-control-v1" } }
	local remote = { kind = "worker", worker_id = worker.worker_id, worker_generation = worker.worker_generation }
	local proof = evidence("existing"); proof.same_machine = false
	assert(R.prepare(o, { o }, remote, proof))
	local payload = assert(R.remote_payload(o, worker))
	local fields = 0; for _ in payload do fields += 1 end
	check(fields == 5 and payload.path == o.path and payload.marker == o.marker and payload.entry == o.entry
		and payload.expected_document_sha256 == codec.sha256("existing"), "remote payload is exactly the canonical five fields bound to B0")
	worker.capabilities = { "report-files-v1" }
	local old, old_err = R.remote_payload(o, worker)
	check(old == nil and old_err.code == "unsupported_capability" and #worker.capabilities == 1, "old provision never gains coordinator-control from current configuration")
	worker.capabilities = { "coordinator-control-v1" }; worker.worker_generation = 2
	check(R.remote_payload(o, worker) == nil, "remote writer is bound to exact provisioned incarnation")
	check(not R.observe(o, evidence("existing")) and o.intent ~= nil, "remote receipt ACK alone does not satisfy authoritative disk confirmation")
end
if section == nil or section == "parser" then
	-- Source-shape guard: the harness cannot run Windows PowerShell, so assert the injection class is absent.
	-- A path inside `-Command` text is executed as PowerShell; it must travel as an environment variable.
	local host = runtime.fs.read(root .. "/host.luau")
	local at = assert(host:find('"-Command"', 1, true), "the Windows document check still uses powershell")
	local script = host:sub(at, host:find("\n", host:find("\n", at, true) + 1, true))
	check(host:find('ORCHPLUS_DOCUMENT_PATH = path', 1, true) and script:find("$env:ORCHPLUS_DOCUMENT_PATH", 1, true),
		"the Windows document path travels as data in an environment variable")
	check(not script:find("%f[%w_]path%s*}") and not script:find('" ..', 1, true) and not script:find(".. path", 1, true),
		"the Windows document path is never appended to -Command text")
end
assert(section == nil or table.find({ "parser", "obligation", "writer", "remote" }, section), "unknown ruling test section")
return "rulings: " .. tostring(checks) .. " checks"
