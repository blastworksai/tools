--!strict
-- Pure existing-document obligations. The authority persists these with the live gate; native
-- ownership/existence observations come from the host, never from a worker's CHECKPOINT.
local Plan = require("./plan_import")
local codec = require("./wire/codec")
local M = {}
local function problem(code: string, message: string): any return { ok = false, code = code, message = message } end
local function text(v: any, max: number): boolean
	return type(v) == "string" and #v > 0 and #v <= max and utf8.len(v) ~= nil and not v:find("%z")
end
local function id(v: any): boolean return text(v, 128) and v:match("^[A-Za-z0-9_-]+$") ~= nil end
local function integer(v: any): boolean return type(v) == "number" and v >= 0 and v <= 9007199254740991 and v % 1 == 0 end
local function closed(v: any, keys: string): boolean
	if type(v) ~= "table" or v == tern.json.null then return false end
	for key in v do if not (" " .. keys .. " "):find(" " .. tostring(key) .. " ", 1, true) then return false end end
	return true
end
local function digest(v: any): boolean return type(v) == "string" and #v == 64 and v:match("^[a-f0-9]+$") ~= nil end
function M.absolute(path: any): boolean
	return text(path, 4096) and not path:find("%c") and (path:sub(1, 1) == "/" or path:match("^%a:[/\\]") ~= nil or path:match("^\\\\[^\\]+\\[^\\]+") ~= nil)
end
function M.valid_writer(w: any): boolean
	if type(w) ~= "table" then return false end
	if w.kind == "window" then
		return closed(w, "kind window_key conn since") and type(w.window_key) == "string" and #w.window_key <= 256
			and integer(w.conn) and integer(w.since)
	end
	return w.kind == "worker" and closed(w, "kind worker_id worker_generation") and id(w.worker_id)
		and integer(w.worker_generation) and w.worker_generation > 0
end
local function same_writer(a: any, b: any): boolean
	if not M.valid_writer(a) or not M.valid_writer(b) or a.kind ~= b.kind then return false end
	if a.kind == "window" then return a.window_key == b.window_key and a.conn == b.conn and a.since == b.since end
	return a.worker_id == b.worker_id and a.worker_generation == b.worker_generation
end
M.same_writer = same_writer
local function escape(value: string): string
	return (value:gsub("&", "&amp;"):gsub("<", "&lt;"):gsub(">", "&gt;"):gsub("`", "&#96;")
		:gsub("%*", "&#42;"):gsub("_", "&#95;"):gsub("%[", "&#91;"):gsub("%]", "&#93;")
		:gsub(":", "&#58;"):gsub("\r\n", "\n"):gsub("\r", "\n"))
end
local function quoted(label: string, value: any): string
	return "> " .. label .. escape(tostring(value)):gsub("\n", "\n> ")
end
function M.association(work: any, plans: any): (string?, any?)
	local explicit = work.ruling_document
	if explicit ~= nil then
		if closed(explicit, "path selected_by existing") and explicit.selected_by == "owner" and explicit.existing == true and M.absolute(explicit.path) then return explicit.path, nil end
		return nil, problem("association_unproved", "Select an existing document explicitly; a worker-supplied path is not an association.")
	end
	local source = work.source
	if not source or source.kind ~= "plan" or type(source.ref) ~= "string" then return nil, nil end
	local selected
	for _, plan in plans or {} do
		if plan.logical_session_id == work.logical_session_id and M.absolute(plan.path) then
			for _, cp in plan.checkpoints do for _, task in cp.tasks do
				if source.ref == plan.path .. "#" .. task.id then
					if selected and selected ~= plan.path then return nil, problem("association_unproved", "The work has ambiguous document associations.") end
					selected = plan.path
				end
			end end
		end
	end
	return selected, nil
end
function M.create(namespace: string, work: any, gate: any, plans: any): (any?, any?)
	local answer = gate.answer
	if not answer or not answer.source or answer.source.kind ~= "owner" then return nil, nil end
	local path, err = M.association(work, plans)
	if not path then return nil, err end
	if not id(namespace) or not id(gate.id) then return nil, problem("invalid_ruling", "Authority and gate identity must support a scoped ruling marker.") end
	local marker = "orchplus-ruling:" .. namespace .. ":" .. gate.id
	local lines = { "> " .. marker, quoted("Question: ", gate.question), quoted("Decision: ", answer.choice_id .. " — " .. answer.answer),
		quoted("Work: ", work.work_id), quoted("Gate revision: ", gate.revision) }
	if work.source and work.source.revision then table.insert(lines, quoted("Work revision: ", work.source.revision)) end
	if answer.source.owner_id then table.insert(lines, quoted("Operator owner: ", answer.source.owner_id)) end
	if answer.source.owner_generation then table.insert(lines, quoted("Operator generation: ", answer.source.owner_generation)) end
	if answer.at_ms and answer.at_ms > 0 then table.insert(lines, quoted("Time (epoch ms): ", answer.at_ms)) end
	local entry = table.concat(lines, "\n")
	if #entry > 8192 then return nil, problem("ruling_too_large", "The escaped document entry exceeds 8192 bytes; shorten the gate answer before submitting it.") end
	return { path = path, marker = marker, entry = entry, state = "pending", gate_id = gate.id, gate_revision = gate.revision,
		work_id = work.work_id, logical_session_id = work.logical_session_id }, nil
end
local STATES = { pending = true, writing = true, unsaved_edits = true, needs_review = true, duplicate_entry = true,
	writer_unproved = true, document_missing = true, document_busy = true, unsupported_capability = true }
function M.valid(o: any): boolean
	if not closed(o, "path marker entry state gate_id gate_revision work_id logical_session_id intent") or not M.absolute(o.path)
		or not id(o.gate_id) or not integer(o.gate_revision) or o.gate_revision == 0 or not id(o.work_id) or not id(o.logical_session_id)
		or not text(o.marker, 256) or not o.marker:match("^orchplus%-ruling:[A-Za-z0-9_-]+:" .. o.gate_id:gsub("%-", "%%-") .. "$")
		or not text(o.entry, 8192) or not STATES[o.state] then return false end
	local split = Plan.split_rulings("\n" .. Plan.RULINGS_OPEN .. "\n" .. o.entry .. "\n" .. Plan.RULINGS_CLOSE .. "\n")
	if not split or split.block.entries[o.marker] ~= o.entry then return false end
	local n = 0; for _ in split.block.entries do n += 1 end; if n ~= 1 then return false end
	local intent = o.intent
	return intent == nil or (closed(intent, "writer expected_document_sha256 expected_non_rulings_sha256") and M.valid_writer(intent.writer)
		and digest(intent.expected_document_sha256) and digest(intent.expected_non_rulings_sha256))
end
local function hold(o: any, code: string, message: string): (any?, any?)
	if o.state ~= "duplicate_entry" and (o.state ~= "needs_review" or code == "duplicate_entry") then o.state = code end
	return nil, problem(o.state, message)
end
local function inspect(bytes: any, o: any): (any?, any?)
	if type(bytes) ~= "string" then return nil, problem("document_missing", "The existing document cannot be read.") end
	local split, err = Plan.split_rulings(bytes)
	if not split then return nil, err end
	local entry = if split.block then split.block.entries[o.marker] else nil
	return { split = split, entry = entry }, nil
end
-- The host supplies fresh full disk bytes and an explicit live-buffer observation. No buffer means
-- buffer_observed=true with buffer_bytes absent, NOT failure to inspect a possibly dirty buffer.
local function observations(o: any, evidence: any): (any?, any?, any?)
	local disk, err = inspect(evidence.disk_bytes, o)
	if not disk then return nil, nil, err end
	if evidence.buffer_observed ~= true then return nil, nil, problem("writer_unproved", "Inspect the native live buffer before writing or confirming.") end
	local buffer
	if evidence.buffer_bytes ~= nil then
		buffer, err = inspect(evidence.buffer_bytes, o)
		if not buffer then return nil, nil, err end
	end
	return disk, buffer, nil
end
local function observation_hold(o: any, err: any): (any?, any?)
	local code = if err.code == "duplicate_entry" then "duplicate_entry" elseif err.code == "document_missing" then "document_missing"
		elseif err.code == "writer_unproved" then "writer_unproved" else "needs_review"
	return hold(o, code, err.message)
end
function M.prepare(o: any, obligations: any, writer: any, evidence: any): (any?, any?)
	if o.intent then return nil, problem("write_in_flight", "The original one-shot intent may still complete; inspect it, never append again.") end
	if o.state == "needs_review" or o.state == "duplicate_entry" then return nil, problem(o.state, "The owner must review this document; no automatic repair is permitted.") end
	if evidence.existing ~= true then return hold(o, "document_missing", "Only an existing document may receive this entry.") end
	if not M.valid_writer(writer) or evidence.identity_proven ~= true or (writer.kind == "window" and evidence.same_machine ~= true)
		or (evidence.preferred_worker and not same_writer(writer, evidence.preferred_worker)) then
		return hold(o, "writer_unproved", "Use the existing document-owning writer; unresolved aliases or ownership remain pending.")
	end
	if evidence.quiescent ~= true then return hold(o, "document_busy", "The existing document is not quiescent.") end
	for _, other in obligations do
		if other ~= o and other.path == o.path and other.intent then return hold(o, "document_busy", "Another live ruling owns this document's writer.") end
	end
	if not o.intent and o.state == "writing" then return hold(o, "needs_review", "A writing obligation lost its intent; do not reconstruct an executable write.") end
	local disk, buffer, err = observations(o, evidence)
	if not disk then return observation_hold(o, err) end
	if disk.split.unterminated_fence then return hold(o, "needs_review", "Close the document's fenced example before appending outside-fence metadata.") end
	if evidence.buffer_bytes ~= nil and evidence.buffer_bytes ~= evidence.disk_bytes then return hold(o, "unsaved_edits", "Document has unsaved edits.") end
	if disk.entry then return hold(o, "needs_review", "The marker already exists without this live write intent; inspect it rather than append.") end
	local block, eol = disk.split.block, "\n"
	if block then eol = block.eol
	else
		local without_crlf = evidence.disk_bytes:gsub("\r\n", "")
		if without_crlf:find("\r", 1, true) or (evidence.disk_bytes:find("\r\n", 1, true) and without_crlf:find("\n", 1, true)) then
			return hold(o, "needs_review", "Mixed line endings need owner review before inserting metadata.")
		end
		if evidence.disk_bytes:find("\r\n", 1, true) then eol = "\r\n" end
	end
	local document_hash, non_rulings_hash = codec.sha256(evidence.disk_bytes), codec.sha256(disk.split.content)
	o.intent = { writer = table.clone(writer), expected_document_sha256 = document_hash, expected_non_rulings_sha256 = non_rulings_hash }
	o.state = "writing"
	local entry = o.entry:gsub("\n", eol)
	return { offset = if block then block.close_byte - 1 else #evidence.disk_bytes,
		text = if block then entry .. eol else eol .. Plan.RULINGS_OPEN .. eol .. entry .. eol .. Plan.RULINGS_CLOSE .. eol,
		expected_document_sha256 = document_hash, expected_non_rulings_sha256 = non_rulings_hash }, nil
end
function M.observe(o: any, evidence: any): (boolean, any?)
	if not o.intent then return false, problem("write_not_issued", "No live write intent can be confirmed.") end
	local disk, buffer, err = observations(o, evidence)
	if not disk then local _, held = observation_hold(o, err); return false, held end
	if o.state == "needs_review" or o.state == "duplicate_entry" then return false, problem(o.state, "Owner review is required; observing later bytes cannot erase the conflict.") end
	if codec.sha256(disk.split.content) ~= o.intent.expected_non_rulings_sha256
		or (buffer and codec.sha256(buffer.split.content) ~= o.intent.expected_non_rulings_sha256) then
		local _, held = hold(o, "needs_review", "Non-ruling document bytes changed after B0; no automatic rewrite or repair."); return false, held
	end
	if (disk.entry and disk.entry ~= o.entry) or (buffer and buffer.entry and buffer.entry ~= o.entry) then
		local _, held = hold(o, "needs_review", "The marker's entry differs from the exact owner ruling."); return false, held
	end
	if evidence.buffer_bytes ~= nil and evidence.buffer_bytes ~= evidence.disk_bytes then
		local _, held = hold(o, "unsaved_edits", "Document has unsaved edits; wait for normal owner save or autosave."); return false, held
	end
	if disk.entry == o.entry then return true, nil end
	o.state = "writing"
	return false, nil
end
function M.reissue(o: any, evidence: any): (boolean, any?)
	if not o.intent or evidence.writer_ended ~= true or evidence.no_write_can_complete ~= true then
		return false, problem("write_in_flight", "Prove the original owning incarnation ended and no native write can still complete.")
	end
	if not same_writer(o.intent.writer, evidence.previous_writer) then
		return false, problem("writer_unproved", "End-of-writer evidence must name the exact original owning incarnation.")
	end
	local disk, buffer, err = observations(o, evidence)
	if not disk then local _, held = observation_hold(o, err); return false, held end
	if o.state == "needs_review" or o.state == "duplicate_entry" then return false, problem(o.state, "Owner review is required before any further write.") end
	if disk.entry or (buffer and buffer.entry) then
		local _, held = hold(o, if buffer and not disk.entry then "unsaved_edits" else "needs_review", "An existing disk or unsaved buffer marker forbids another append."); return false, held
	end
	if evidence.buffer_bytes ~= nil and evidence.buffer_bytes ~= evidence.disk_bytes then
		local _, held = hold(o, "unsaved_edits", "Document has unsaved edits."); return false, held
	end
	if codec.sha256(disk.split.content) ~= o.intent.expected_non_rulings_sha256 then
		local _, held = hold(o, "needs_review", "Document content changed while the original writer was unresolved."); return false, held
	end
	o.intent, o.state = nil, "pending"
	return true, nil
end
function M.remote_payload(o: any, worker: any): (any?, any?)
	if not worker or not worker.mailbox_handle or not worker.binding_digest or not table.find(worker.capabilities or {}, "coordinator-control-v1") then
		return nil, problem("unsupported_capability", "This existing worker has no provisioned coordinator-control-v1 proof; no capability is backfilled.")
	end
	local writer = { kind = "worker", worker_id = worker.worker_id, worker_generation = worker.worker_generation }
	if worker.logical_session_id ~= o.logical_session_id or not o.intent or not same_writer(o.intent.writer, writer) then
		return nil, problem("writer_unproved", "The authorized existing worker must own this exact document intent.")
	end
	return { path = o.path, marker = o.marker, entry = o.entry, expected_document_sha256 = o.intent.expected_document_sha256,
		expected_non_rulings_sha256 = o.intent.expected_non_rulings_sha256 }, nil
end
return M
