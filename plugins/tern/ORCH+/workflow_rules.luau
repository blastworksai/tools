--!strict
-- ORCH+ workflow policy over decoded wire facts.
local M = {}

local function failure(code: string, message: string): any
	return { ok = false, code = code, message = message }
end

local function id(value: any): boolean
	return type(value) == "string" and #value >= 1 and #value <= 96 and value:match("^[A-Za-z0-9_-]+$") ~= nil
end

-- Required checks must exist for the exact artifact revision and all must have passed: not_run is
-- absent evidence and failed evidence blocks too. Checks are worker-attested: completeness,
-- freshness and outcome are checked, nothing is executed and no default project verifier is invented.
local function checks_problem(p: any, subject: string, action: string): any?
	if type(p.checks) ~= "table" or #p.checks == 0 then
		return failure("verification_missing", "At least one required verification outcome is needed for the " .. subject .. " artifact revision.")
	end
	for _, check in p.checks do
		if check.artifact_revision ~= p.artifact_revision then
			return failure("verification_stale", "Check " .. check.check_id .. " is not fresh for the " .. subject .. " artifact revision.")
		end
		if check.outcome == "not_run" then
			return failure("verification_missing", "Check " .. check.check_id .. " was not run; absent required evidence blocks " .. action .. ".")
		end
		if check.outcome == "failed" then
			return failure("verification_failed", "Check " .. check.check_id .. " failed for this artifact revision; failed evidence blocks " .. action .. ".")
		end
	end
	return nil
end

-- Rollover handover verification over an already decoded CHECKPOINT (worker-attested).
function M.verify_checkpoint(report: any, request_id: any): (any?, any?)
	if type(report) ~= "table" or report.kind ~= "CHECKPOINT" or type(report.payload) ~= "table" then
		return nil, failure("checkpoint_missing", "A structured CHECKPOINT is required; a summary alone cannot hand over work.")
	end
	local p = report.payload
	if not id(request_id) or p.request_id ~= request_id then
		return nil, failure("checkpoint_stale", "The checkpoint must echo this rollover's exact request_id.")
	end
	if type(p.completed) ~= "table" or type(p.remaining) ~= "table" or #p.completed + #p.remaining == 0 then
		return nil, failure("checkpoint_incomplete", "The checkpoint must state completed and/or remaining work.")
	end
	local problem = checks_problem(p, "handed-over", "rollover")
	if problem then return nil, problem end
	return { attestation = "worker-attested", checkpoint_id = p.checkpoint_id, artifact_revision = p.artifact_revision }, nil
end

-- Landing independently requires every declared helper check at the exact source revision.
-- Review policy selects an additional proof predicate, never an alternative to those checks.
function M.verify_landing_proof(input: any): (any?, any?)
	local revision, results = input.source_revision, input.check_results or {}
	local refs = tern.json.array()
	for _, check in input.checks or {} do
		local r = results[check.check_id]
		if r == nil then
			return nil, failure("check_missing", "Declared check " .. check.check_id .. " has no helper-run CHECK_RESULT; run it with the SPAWN helper.")
		end
		if r.head ~= revision then
			return nil, failure("check_stale", "Check " .. check.check_id .. " ran at " .. tostring(r.head) .. ", not the requested source revision; run it again.")
		end
		if r.exit_code ~= 0 then
			return nil, failure("check_failed", "Check " .. check.check_id .. " exited " .. tostring(r.exit_code) .. " at this revision; reviewer approval cannot override failed checks.")
		end
		table.insert(refs, check.check_id .. ":" .. r.output_sha256)
	end
	if not input.require_code_review then
		return { mode = "review_disabled", artifact_revision = revision, check_refs = refs }, nil
	end
	local review = input.review
	if review == nil or review.reviewer_role ~= "reviewer" then
		return nil, failure("review_required", "Code review is required: an ORCH+ reviewer worker must approve this exact revision.")
	end
	if review.reviewer_worker_id == input.builder_worker_id then
		return nil, failure("reviewer_is_builder", "The builder cannot review its own revision.")
	end
	if review.reviewer_record_id ~= nil and review.reviewer_record_id == input.builder_record_id then
		return nil, failure("reviewer_record_is_builder", "The reviewer must run on a record other than the builder's.")
	end
	if review.artifact_revision ~= revision then
		return nil, failure("review_stale", "The approved review is for another artifact revision.")
	end
	if review.outcome ~= "approved" then
		return nil, failure("review_not_approved", "The review requires changes; landing waits for approval of this revision.")
	end
	if input.require_other_family then
		if input.builder_family == nil or review.reviewer_family == nil then
			return nil, failure("family_unknown", "Declare both underlying provider families in SPAWN before cross-family proof can hold.")
		end
		if input.builder_family == review.reviewer_family then
			return nil, failure("family_same", "Cross-family review requires a different declared provider family.")
		end
	end
	return { mode = if input.require_other_family then "cross_family_review" else "helper_checks",
		artifact_revision = revision, review_id = review.review_id, check_refs = refs }, nil
end

-- The reviewer is never a merge actor. Worker mode explicitly authorizes the existing builder;
-- selected-record mode retains the separate signer restriction.
function M.verify_signer(input: any): any?
	local record = input.release_manager_record_id
	if input.mode ~= "worker" and input.mode ~= "selected_record" then return failure("merge_actor_mode", "Choose the existing worker or a selected release actor explicitly.") end
	if input.mode == "worker" and (input.builder_record_id == nil or record ~= input.builder_record_id) then
		return failure("merge_actor_not_builder", "Worker mode grants only the exact builder's configured record; another actor requires selected-record mode.")
	end
	if input.mode == "selected_record" and input.builder_record_id ~= nil and record == input.builder_record_id then
		return failure("release_manager_is_builder", "The release manager's record " .. tostring(record) .. " is the builder's record; the signer must be another record, so no grant is issued.")
	end
	if input.reviewer_record_id ~= nil and record == input.reviewer_record_id then
		return failure("release_manager_is_reviewer", "The release manager's record " .. tostring(record) .. " is the approving reviewer's record; signer and reviewer must differ, so no grant is issued.")
	end
	return nil
end

-- Lexical path facts (Task 2D GOTCHA): collapse `//`, resolve `.`/`..`, strip the trailing `/`,
-- `\` → `/` and a lower-case drive letter for Windows absolute paths. Symlinks and aliases are
-- never resolved here; only the helper's CHECKOUT worktree_path/common_dir name the real checkout.
function M.normalize_path(p: string): string
	local s, prefix = p, ""
	if s:match("^%a:[/\\]") or s:match("^%a:$") or s:sub(1, 2) == "\\\\" then
		s = s:gsub("\\", "/")
		if s:match("^%a:") then prefix = s:sub(1, 2):lower(); s = s:sub(3) else prefix = "//"; s = s:sub(3) end
	end
	local absolute_path = prefix ~= "" or s:sub(1, 1) == "/"
	local parts = {}
	for segment in s:gmatch("[^/]+") do
		if segment == "." then continue end
		if segment == ".." then
			if #parts > 0 and parts[#parts] ~= ".." then table.remove(parts)
			elseif not absolute_path then table.insert(parts, "..") end
		else table.insert(parts, segment) end
	end
	local body = table.concat(parts, "/")
	if prefix == "//" then return "//" .. body end
	if absolute_path then return prefix .. "/" .. body end
	return body
end
-- `p` equals or lies under `root` (both normalized here), segment-aware.
function M.path_within(root: string, p: string): boolean
	root, p = M.normalize_path(root), M.normalize_path(p)
	if root == p then return true end
	if root == "" then return p:sub(1, 1) ~= "/" and p:sub(1, 2) ~= ".." and p:match("^%a:") == nil end
	if root:sub(-1) == "/" then return p:sub(1, #root) == root end
	return p:sub(1, #root + 1) == root .. "/"
end
local WILDCARD = "[%*%?%[{]"
-- Glob intersection: compare literal prefixes up to the first wildcard; exact or ancestor match overlaps.
function M.globs_overlap(a: string, b: string): boolean
	a, b = M.normalize_path(a), M.normalize_path(b)
	local ia, ib = a:find(WILDCARD), b:find(WILDCARD)
	if not ia and not ib then return M.path_within(a, b) or M.path_within(b, a) end
	local pa = if ia then a:sub(1, ia - 1) else a
	local pb = if ib then b:sub(1, ib - 1) else b
	if ia and ib then return pa:sub(1, #pb) == pb or pb:sub(1, #pa) == pa end
	local literal, prefix = if ia then pb else pa, if ia then pa else pb
	return literal:sub(1, #prefix) == prefix or prefix:sub(1, #literal + 1) == literal .. "/"
end
-- `*` and `?` stay within one segment, `**` crosses segments (`**/` also matches none).
-- Failed (gi, si) states are memoized, so matching is bounded by |glob| x |path| states and never backtracks combinatorially.
local function glob_match(g: string, s: string, gi: number, si: number, failed: { [number]: boolean }): boolean
	local key = gi * (#s + 2) + si
	if failed[key] then return false end
	while gi <= #g do
		local c = g:sub(gi, gi)
		if c == "*" then
			local double = g:sub(gi + 1, gi + 1) == "*"
			local after = gi + (if double then 2 else 1)
			if double and g:sub(after, after) == "/" and glob_match(g, s, after + 1, si, failed) then return true end
			for k = si, #s + 1 do
				if glob_match(g, s, after, k, failed) then return true end
				if not double and s:sub(k, k) == "/" then break end
			end
			failed[key] = true
			return false
		elseif c == "?" then
			if si > #s or s:sub(si, si) == "/" then failed[key] = true; return false end
		elseif s:sub(si, si) ~= c then failed[key] = true; return false end
		gi += 1; si += 1
	end
	if si > #s then return true end
	failed[key] = true
	return false
end
-- A changed file is in scope when a scope entry names it or an ancestor directory (literal), or a
-- glob matches it or an ancestor. `[`/`{` classes and globs with more than 8 wildcards are not
-- supported and match nothing, so such a scope entry never widens what a worker may change.
function M.path_in_scope(entry: string, p: string): boolean
	entry, p = M.normalize_path(entry), M.normalize_path(p)
	local first = entry:find(WILDCARD)
	if not first then return M.path_within(entry, p) end
	local _, wildcards = entry:gsub("[%*%?]", "")
	if entry:find("[%[{]") or wildcards > 8 then return false end
	if glob_match(entry, p, 1, 1, {}) then return true end
	for index = #p, 1, -1 do
		if p:sub(index, index) == "/" and glob_match(entry, p:sub(1, index - 1), 1, 1, {}) then return true end
	end
	return false
end


return M
