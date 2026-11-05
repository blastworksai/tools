--!strict
-- Pure USAGE capacity consumer and quota routing rule (plan §7). No native effects, provider
-- calls, credential reads or USAGE private state: the window reads USAGE's public native
-- `usage.capacity` block; this module only verifies, normalizes and ranks that evidence.
local codec = require("./transport")
local M = {}
local MAX = 9007199254740991
M.BLOCK = "usage.capacity"
M.ACTION = "usage.capacity"
M.NODE = "usage-capacity-response"
M.PREFIX = "USAGE_CAPACITY v1\n"
-- USAGE permits 8 MiB/256 pages; ORCH+ accepts at most 2 MiB and fails closed (unknown evidence)
-- above that rather than truncating. The SHA-256 runs in Luau inside 50 ms window callbacks, so it
-- is incremental: at most HASH_BLOCKS_PER_STEP 64-byte blocks (16 KiB) per step, resumed per tick.
M.MAX_DOCUMENT_BYTES = 2 * 1024 * 1024
M.HASH_BLOCKS_PER_STEP = 256
M.MAX_PAGES = 256
M.MAX_PAGE_BYTES = 32768
M.MAX_RESPONSE_CHARS = 262144
M.MAX_RECORDS = 24
M.CLOCK_SKEW_MS = 60000
-- A claim must carry a USAGE `validate` result this recent (host wall clock).
M.VALIDATION_WINDOW_MS = 30000
M.STALE_AFTER_MS = 900000
local COORDINATOR = "coordinator-control-v1"

M.REASONS = table.freeze({
	no_evidence = "No USAGE capacity evidence is recorded for this session.",
	evidence_expired = "The USAGE evidence lease expired; a fresh snapshot is required.",
	not_in_evidence = "This record was not part of the normalized USAGE evidence set.",
	unbound = "USAGE declares no exact SPAWN binding (namespace, host, config revision, record ID) for this record.",
	ambiguous = "More than one distinct USAGE binding or source matches this record.",
	binding_unverified = "The USAGE account has no verified profile binding (failed, last-known or unproven readings carry no routing proof).",
	source_missing = "The publishing USAGE source is not in the evidence set.",
	source_stale = "The publishing USAGE source is stale.",
	source_offline = "The publishing USAGE source is offline.",
	source_unreachable = "The publishing USAGE source is unreachable.",
	source_not_measured = "The publishing USAGE source has not measured yet.",
	source_status_unknown = "The publishing USAGE source status is unknown.",
	source_generation_changed = "The USAGE source or profile generation changed since publication.",
	clock_skew = "USAGE flagged clock skew for the publishing source.",
	local_roster_changed = "The local SPAWN roster no longer matches the published binding.",
	reading_missing = "A bound USAGE reading is missing.",
	identity_mismatch = "A bound reading's canonical identity is outside the verified profile binding.",
	no_windows = "The bound readings carry no quota windows.",
	unavailable = "A bound quota window is unavailable or only last-known.",
	unit_unknown = "Quota units are not percentages.",
	conflict = "Equally fresh observations of one window/pool disagree.",
	future_timestamp = "An observation is timestamped in the future.",
	stale = "The newest bound observation is older than the allowed evidence age.",
	reset_passed = "A quota window's reset time passed; fresh evidence is required (no refill is inferred).",
	exhausted = "Remaining quota is exhausted.",
	below_reserve = "Remaining quota is at or below the configured reserve.",
	malformed = "The USAGE evidence for this record is malformed.",
})
local STATES = { known = true, unknown = true }

local function closed(v: any, keys: string): boolean
	if type(v) ~= "table" or v == tern.json.null then return false end
	local allowed = {}; for k in keys:gmatch("%S+") do allowed[k] = true end
	for k in v do if not allowed[k] then return false end end
	return true
end
local function str(v: any, n: number): boolean return type(v) == "string" and #v > 0 and #v <= n and utf8.len(v) ~= nil end
local function int(v: any, minimum: number?, maximum: number?): boolean
	return type(v) == "number" and v == v and v % 1 == 0 and v >= (minimum or 0) and v <= (maximum or MAX)
end
local function digest(v: any): boolean return type(v) == "string" and #v == 64 and v:match("^[0-9a-f]+$") ~= nil end
local function short(v: any): boolean return type(v) == "string" and #v == 16 and v:match("^[0-9a-f]+$") ~= nil end
local function opaque(v: any): boolean return type(v) == "string" and #v > 0 and #v <= 128 and v:match("^[%w_.:%-]+$") ~= nil end
local function null(v: any): any if v == tern.json.null then return nil end; return v end
local function problem(code: string, message: string): any return { ok = false, code = code, message = message } end
local function list(v: any): { any }
	if type(v) ~= "table" or v == tern.json.null then return {} end
	return v
end

-- Deterministic encoding for digests only (sorted keys); never a wire format.
local function canonical(v: any): string
	if type(v) ~= "table" then return tern.json.encode(v) end
	local n = #v
	local keys, sequential = {}, true
	for k in v do table.insert(keys, k); if type(k) ~= "number" or k < 1 or k > n or k % 1 ~= 0 then sequential = false end end
	if sequential and #keys == n and n > 0 then
		local parts = {}
		for i = 1, n do parts[i] = canonical(v[i]) end
		return "[" .. table.concat(parts, ",") .. "]"
	end
	table.sort(keys, function(a, b) return tostring(a) < tostring(b) end)
	local parts = {}
	for _, k in keys do table.insert(parts, tern.json.encode(tostring(k)) .. ":" .. canonical(v[k])) end
	return "{" .. table.concat(parts, ",") .. "}"
end
M.canonical = canonical
function M.digest(v: any): string return codec.sha256(canonical(v)) end

-- Routing-relevant policy only: pause, scheduling and exclusions never invalidate a routing decision.
-- Plan §7 strict schema: initial_dispatch, worker_rollover and coordinator_rollover each carry an
-- explicit record allowlist and independent provider/account/model substitution booleans.
M.SCOPES = { "initial_dispatch", "worker_rollover", "coordinator_rollover" }
M.ROUTING_KEYS = { "quota_routing", "quota_reserve_pct", "quota_max_age_ms", "concurrency_limit" }
for _, scope in M.SCOPES do
	for _, suffix in { "_records", "_provider", "_account", "_model" } do table.insert(M.ROUTING_KEYS, scope .. suffix) end
end
M.MAX_CONCURRENCY = 32
-- SPAWN exposes only owner-entered `selector_evidence` text, never a typed verification status, so
-- every record's model/profile selector is reported as unverified. It is evidence, not enforcement.
function M.selector_state(row: any): string
	return if type(row) == "table" and type(row.selector_evidence) == "string" and #row.selector_evidence > 0 then "unverified_owner_text" else "unverified_absent"
end
function M.policy_digest(p: any): string
	local out = {}
	for _, key in M.ROUTING_KEYS do out[key] = p[key] end
	return M.digest(out)
end

-------------------------------------------------------------------------------
-- Wire: bounded request, strict response decode and complete-page assembly.
-------------------------------------------------------------------------------
function M.request(op: string, request_id: string, revision: string?, cursor: string?): string?
	if not opaque(request_id) or (op ~= "snapshot" and op ~= "page" and op ~= "validate") then return nil end
	local body: any = { version = 1, request_id = request_id, op = op }
	if op ~= "snapshot" then if not digest(revision) then return nil end; body.revision = revision end
	if op == "page" then if not opaque(cursor) then return nil end; body.cursor = cursor end
	local bytes = tern.json.encode(body)
	return if #bytes <= 4096 then bytes else nil
end

-- Returns the decoded response, or nil plus a typed problem. `pending`/`uncorrelated` mean wait.
function M.decode_response(text: any, expected: any): (any?, any?)
	if type(text) ~= "string" or #text > M.MAX_RESPONSE_CHARS or text:sub(1, #M.PREFIX) ~= M.PREFIX then
		return nil, problem("incompatible", "USAGE capacity v1 response framing is required.")
	end
	local ok, r = pcall(tern.json.decode, text:sub(#M.PREFIX + 1))
	if not ok or type(r) ~= "table" or r.version ~= 1 then return nil, problem("incompatible", "USAGE capacity response is not version 1 JSON.") end
	if r.request_id ~= expected.request_id or r.op ~= expected.op then return nil, problem("uncorrelated", "Waiting for the correlated USAGE response.") end
	if r.ok ~= true then
		local status = if str(r.status, 96) then r.status else "invalid_response"
		if status == "pending" then return nil, problem("pending", "USAGE capacity request is pending.") end
		return nil, problem(status, if str(r.message, 512) then r.message else "USAGE refused the capacity request.")
	end
	if expected.op == "validate" then
		if not closed(r, "version request_id op ok status revision auth_revision validated_at_ms expires_at_ms") or r.status ~= "current"
			or not digest(r.revision) or r.revision ~= expected.revision or not str(r.auth_revision, 256)
			or not int(r.validated_at_ms) or not int(r.expires_at_ms) then return nil, problem("invalid_response", "USAGE validate response is malformed.") end
		return r, nil
	end
	r.next_cursor = null(r.next_cursor)
	if not closed(r, "version request_id op ok status revision auth_revision issued_at_ms expires_at_ms index count size data next_cursor complete incomplete")
		or r.status ~= "ok" or not digest(r.revision) or (expected.revision ~= nil and r.revision ~= expected.revision) or not str(r.auth_revision, 256)
		or not int(r.issued_at_ms) or not int(r.expires_at_ms) or not int(r.count, 1, M.MAX_PAGES) or not int(r.index, 0, r.count - 1)
		or not int(r.size, 1) or type(r.data) ~= "string" or #r.data > M.MAX_PAGE_BYTES or utf8.len(r.data) == nil
		or type(r.complete) ~= "boolean" or r.complete ~= (r.index + 1 == r.count) or r.incomplete ~= false
		or (r.complete and r.next_cursor ~= nil) or (not r.complete and not opaque(r.next_cursor)) then
		return nil, problem("invalid_response", "USAGE capacity page is malformed.")
	end
	return r, nil
end

function M.assembly(first: any): (any?, any?)
	if first.index ~= 0 then return nil, problem("assembly_order", "Assembly must start at page 0.") end
	if first.size > M.MAX_DOCUMENT_BYTES then return nil, problem("too_large", "USAGE capacity document exceeds the ORCH+ consumer bound.") end
	local hash = codec.sha256_begin()
	codec.sha256_feed(hash, first.data)
	return { revision = first.revision, auth_revision = first.auth_revision, issued_at_ms = first.issued_at_ms, expires_at_ms = first.expires_at_ms,
		size = first.size, count = first.count, parts = { first.data }, bytes = #first.data, complete = first.complete, next_cursor = first.next_cursor,
		hash = hash, hashed = false }, nil
end
function M.add_page(a: any, page: any): (boolean, any?)
	if a.complete or page.index ~= #a.parts or page.revision ~= a.revision or page.auth_revision ~= a.auth_revision or page.size ~= a.size
		or page.count ~= a.count or page.issued_at_ms ~= a.issued_at_ms or page.expires_at_ms ~= a.expires_at_ms then
		return false, problem("page_mismatch", "A page does not continue the same immutable revision in index order.")
	end
	if a.hash.busy then return false, problem("hash_interrupted", "An interrupted hashing step discarded this assembly.") end
	a.bytes += #page.data
	if a.bytes > a.size then return false, problem("size_mismatch", "Pages exceed the declared document size.") end
	table.insert(a.parts, page.data); a.complete = page.complete; a.next_cursor = page.next_cursor
	codec.sha256_feed(a.hash, page.data); a.hashed = false
	return true, nil
end
-- One bounded hashing step over the bytes delivered so far. Returns true once every delivered
-- byte is hashed (more pages may still arrive). An interrupted earlier step fails closed.
function M.hash_step(a: any, max_blocks: number?): (boolean, any?)
	if a.hash.busy then return false, problem("hash_interrupted", "An interrupted hashing step discarded this assembly.") end
	if not a.hashed then a.hashed = codec.sha256_step(a.hash, max_blocks or M.HASH_BLOCKS_PER_STEP) end
	return a.hashed, nil
end
-- Verify byte length and the incrementally stepped SHA-256, then parse. Callers step `hash_step`
-- until it returns true first (across callbacks); an unhashed assembly is `hash_pending`.
function M.finish(a: any): (any?, any?)
	if not a.complete or #a.parts ~= a.count then return nil, problem("incomplete", "Not every page of the revision was delivered.") end
	if a.bytes ~= a.size then return nil, problem("size_mismatch", "Assembled byte length differs from the declared size.") end
	if a.hash.busy then return nil, problem("hash_interrupted", "An interrupted hashing step discarded this assembly.") end
	if not a.hashed then return nil, problem("hash_pending", "The assembled bytes are not fully hashed yet.") end
	a.digest = a.digest or codec.sha256_digest(a.hash)
	if a.digest ~= a.revision then return nil, problem("integrity_mismatch", "Assembled bytes do not hash to the revision.") end
	local raw = table.concat(a.parts)
	if #raw ~= a.size then return nil, problem("size_mismatch", "Assembled byte length differs from the declared size.") end
	local ok, document = pcall(tern.json.decode, raw)
	if not ok or type(document) ~= "table" or document.version ~= 1 or document.complete ~= true or document.incomplete ~= false
		or document.auth_revision ~= a.auth_revision or type(document.records) ~= "table" or type(document.sources) ~= "table" then
		return nil, problem("invalid_document", "USAGE capacity document is not a complete version-1 snapshot.")
	end
	return document, nil
end

-------------------------------------------------------------------------------
-- Normalization: per SPAWN record -> exact USAGE binding and freshest windows.
-------------------------------------------------------------------------------
local SOURCE_REASONS = { stale = "source_stale", offline = "source_offline", source_unreachable = "source_unreachable", not_yet_measured = "source_not_measured" }
local function sorted_ids(v: any): { string }?
	if type(v) ~= "table" or v == tern.json.null then return nil end
	local out = {}
	for _, item in v do if type(item) ~= "string" then return nil end; table.insert(out, item) end
	table.sort(out); return out
end
local function same_list(a: { string }?, b: { string }?): boolean
	if not a or not b or #a ~= #b then return false end
	for i = 1, #a do if a[i] ~= b[i] then return false end end
	return true
end
local function same_join(j: any, join: any): boolean
	return type(j) == "table" and j.namespace == join.namespace and j.host_key == join.host_key and j.config_revision == join.config_revision
end
local function current_account(document: any, join: any, account_id: string): any
	local roster = document.current_roster
	if type(roster) ~= "table" then return nil end
	local found = nil
	for _, scope in list(roster.scopes) do
		if type(scope) == "table" and same_join(scope.spawn_join, join) then
			for _, account in list(scope.accounts) do
				if type(account) == "table" and account.id == account_id then
					if found then return nil end
					found = account
				end
			end
		end
	end
	return found
end
local function window_key(w: any): string
	return (if w.key == "weekly" then "seven_day" else tostring(w.key)) .. "|" .. tostring(w.pool)
end
-- One publication/scope/account match -> (binding identity, windows) or a reason code.
local function evaluate(document: any, sources: any, join: any, m: any, now_ms: number, stale_after: number): (any?, string?)
	local pub, scope, account = m.publication, m.scope, m.account
	local binding = account.profile_binding
	if type(binding) ~= "table" or not str(binding.handle, 256) or not int(binding.generation) then return nil, "binding_unverified" end
	local canonical_ids = sorted_ids(binding.canonical_ids)
	if not canonical_ids or #canonical_ids == 0 then return nil, "binding_unverified" end
	local source = sources[pub.subject_source_id]
	if source == nil then return nil, "source_missing" end
	if source == false then return nil, "ambiguous" end
	if source.status ~= "current" then return nil, SOURCE_REASONS[source.status] or "source_status_unknown" end
	if source.generation ~= pub.generation or source.profile_generation ~= pub.profile_generation then return nil, "source_generation_changed" end
	if source.clock_skew == true then return nil, "clock_skew" end
	if pub.subject_source_id == document.current_source_id then
		local current = current_account(document, join, account.id)
		local proof = if type(current) == "table" then current.profile_binding else nil
		if type(proof) ~= "table" or current.definition_revision ~= account.definition_revision or proof.handle ~= binding.handle
			or proof.generation ~= binding.generation or not same_list(sorted_ids(proof.canonical_ids), canonical_ids) then
			return nil, "local_roster_changed"
		end
	end
	local snapshot = pub.snapshot
	if not int(snapshot.as_of_ms) then return nil, "malformed" end
	if snapshot.as_of_ms > now_ms + M.CLOCK_SKEW_MS then return nil, "future_timestamp" end
	if now_ms - snapshot.as_of_ms > stale_after then return nil, "stale" end
	local readings = {}
	for _, reading in list(snapshot.readings) do if type(reading) == "table" and type(reading.id) == "string" then readings[reading.id] = reading end end
	local allowed = {}; for _, id in canonical_ids do allowed[id] = true end
	local ids = list(account.reading_ids)
	if #ids == 0 then return nil, "reading_missing" end
	local windows = {}
	for _, reading_id in ids do
		local reading = readings[reading_id]
		if not reading then return nil, "reading_missing" end
		if not allowed[reading.canonical_id] then return nil, "identity_mismatch" end
		local seen = 0
		for _, w in list(reading.windows) do
			seen += 1
			if type(w) ~= "table" then return nil, "malformed" end
			if null(w.unavailable_reason) ~= nil or null(w.last_known_reason) ~= nil then return nil, "unavailable" end
			if type(w.remaining) ~= "number" or w.remaining ~= w.remaining or w.remaining < 0 or w.remaining > 100 then return nil, "unit_unknown" end
			if not int(w.observed_at_ms) then return nil, "malformed" end
			local reset = null(w.resets_at_ms)
			if reset ~= nil and not int(reset) then return nil, "malformed" end
			table.insert(windows, { key = window_key(w), weekly = w.key == "seven_day" or w.key == "weekly", remaining = w.remaining, observed_at_ms = w.observed_at_ms, resets_at_ms = reset })
		end
		if seen == 0 then return nil, "no_windows" end
	end
	local identity = table.concat({ tostring(pub.subject_source_id), tostring(scope.id), tostring(account.id), binding.handle,
		string.format("%.0f", binding.generation), tostring(pub.generation), tostring(pub.profile_generation), table.concat(canonical_ids, "\n") }, "\0")
	return { binding = codec.sha256(identity):sub(1, 16), principal = codec.sha256(table.concat(canonical_ids, "\n")):sub(1, 16), windows = windows }, nil
end

-- document: verified USAGE snapshot; meta: assembly + validate result; index: the routing index
-- (catalog join and candidate record IDs/revisions). Missing/stale/revoked/unbound = unknown.
function M.normalize(document: any, meta: any, index: any, now_ms: number): any
	local stale_after = if int(document.stale_after_ms, 1) then math.min(document.stale_after_ms, M.STALE_AFTER_MS) else M.STALE_AFTER_MS
	local join = { namespace = index.namespace, host_key = index.host_key, config_revision = index.config_revision }
	local evidence: any = { version = 1, revision = meta.revision, auth_revision = meta.auth_revision, issued_at_ms = meta.issued_at_ms,
		expires_at_ms = math.min(meta.expires_at_ms, meta.validation.expires_at_ms), validated_at_ms = meta.validation.validated_at_ms,
		namespace = index.namespace, host_key = index.host_key, config_revision = index.config_revision, stale_after_ms = stale_after, records = {} }
	local sources = {}
	for _, s in list(document.sources) do
		if type(s) == "table" and type(s.source_id) == "string" then
			sources[s.source_id] = if sources[s.source_id] == nil then s else false
		end
	end
	local wanted, matches = {}, {}
	for _, r in index.records do wanted[r.id] = true; matches[r.id] = {} end
	for _, pub in list(document.records) do
		local snapshot = if type(pub) == "table" then pub.snapshot else nil
		local roster = if type(snapshot) == "table" then snapshot.roster else nil
		if type(roster) ~= "table" then continue end
		for _, scope in list(roster.scopes) do
			if type(scope) ~= "table" or not same_join(scope.spawn_join, join) then continue end
			for _, account in list(scope.accounts) do
				if type(account) == "table" and type(account.id) == "string" and wanted[account.id] then
					table.insert(matches[account.id], { publication = pub, scope = scope, account = account })
				end
			end
		end
	end
	local unit_known = document.quota_unit == "percent"
	for _, r in index.records do
		local entry: any = { id = r.id, revision = r.revision, state = "unknown" }
		local found = matches[r.id]
		if not unit_known then entry.reason = "unit_unknown"
		elseif #found == 0 then entry.reason = "unbound"
		else
			local valid, first_reason = {}, nil
			for _, m in found do
				local value, reason = evaluate(document, sources, join, m, now_ms, stale_after)
				if value then table.insert(valid, value) elseif not first_reason then first_reason = reason end
			end
			if #valid == 0 then entry.reason = first_reason or "malformed"
			else
				local binding = valid[1].binding
				for _, v in valid do if v.binding ~= binding then entry.reason = "ambiguous" end end
				if not entry.reason then
					-- Newest valid observation per window/pool; equal-time disagreement is a conflict.
					local newest = {}
					for _, v in valid do
						for _, w in v.windows do
							local prior = newest[w.key]
							if not prior or w.observed_at_ms > prior.observed_at_ms then newest[w.key] = w
							elseif w.observed_at_ms == prior.observed_at_ms and (w.remaining ~= prior.remaining or w.resets_at_ms ~= prior.resets_at_ms) then entry.reason = "conflict" end
						end
					end
					if not entry.reason then
						local remaining, observed, n = 101, MAX, 0
						local reset: number?, weekly: number? = nil, nil
						for _, w in newest do
							n += 1
							if w.observed_at_ms > now_ms + M.CLOCK_SKEW_MS then entry.reason = "future_timestamp" end
							remaining = math.min(remaining, w.remaining); observed = math.min(observed, w.observed_at_ms)
							if w.resets_at_ms then
								reset = if reset then math.min(reset, w.resets_at_ms) else w.resets_at_ms
								if w.weekly then weekly = if weekly then math.min(weekly, w.resets_at_ms) else w.resets_at_ms end
							end
						end
						if not entry.reason then
							if now_ms - observed > stale_after then entry.reason = "stale"
							elseif reset and reset <= now_ms then entry.reason = "reset_passed"
							else
								entry.state = "known"; entry.remaining_pct = remaining; entry.observed_at_ms = observed
								entry.reset_at_ms = reset; entry.weekly_reset_ms = weekly; entry.windows = n
								entry.binding = binding; entry.principal = valid[1].principal
							end
						end
					end
				end
			end
		end
		table.insert(evidence.records, entry)
	end
	return evidence
end

-- Host-side strict shape check of the window-normalized evidence (bounded command payload).
function M.valid_evidence(e: any): boolean
	if not closed(e, "version revision auth_revision issued_at_ms expires_at_ms validated_at_ms namespace host_key config_revision stale_after_ms records")
		or e.version ~= 1 or not digest(e.revision) or not str(e.auth_revision, 256) or not int(e.issued_at_ms) or not int(e.expires_at_ms)
		or not int(e.validated_at_ms) or not str(e.namespace, 256) or not str(e.host_key, 256) or not int(e.config_revision)
		or not int(e.stale_after_ms, 1, M.STALE_AFTER_MS) or type(e.records) ~= "table" or #e.records > M.MAX_RECORDS then return false end
	local n, seen = 0, {}
	for _ in e.records do n += 1 end
	if n ~= #e.records then return false end
	for _, r in e.records do
		if not closed(r, "id revision state reason remaining_pct observed_at_ms reset_at_ms weekly_reset_ms windows binding principal")
			or not str(r.id, 96) or seen[r.id] or not int(r.revision) or not STATES[r.state] then return false end
		seen[r.id] = true
		if r.state == "unknown" then
			if not M.REASONS[r.reason] or r.remaining_pct ~= nil or r.binding ~= nil or r.principal ~= nil or r.windows ~= nil
				or r.observed_at_ms ~= nil or r.reset_at_ms ~= nil or r.weekly_reset_ms ~= nil then return false end
		elseif r.reason ~= nil or type(r.remaining_pct) ~= "number" or r.remaining_pct ~= r.remaining_pct or r.remaining_pct < 0 or r.remaining_pct > 100
			or not int(r.observed_at_ms) or (r.reset_at_ms ~= nil and not int(r.reset_at_ms)) or (r.weekly_reset_ms ~= nil and not int(r.weekly_reset_ms))
			or not int(r.windows, 1, 4096) or not short(r.binding) or not short(r.principal) then return false end
	end
	return true
end

-------------------------------------------------------------------------------
-- Assessment and the deterministic routing rule.
-------------------------------------------------------------------------------
local function entry_for(evidence: any, id: string, revision: number): any
	for _, r in (if evidence then evidence.records else {}) do if r.id == id and r.revision == revision then return r end end
	return nil
end
-- sufficient iff fresh, identity-bound and remaining_pct is strictly above the reserve on every
-- applicable window (USAGE's model_mapping is "unknown", so every bound window applies).
function M.assess(evidence: any, id: string, revision: number, p: any, now_ms: number): any
	local function unknown(reason: string): any return { status = "unknown", reason = reason } end
	if not evidence then return unknown("no_evidence") end
	if evidence.expires_at_ms <= now_ms then return unknown("evidence_expired") end
	local entry = entry_for(evidence, id, revision)
	if not entry then return unknown("not_in_evidence") end
	if entry.state ~= "known" then return unknown(entry.reason) end
	local out = { remaining_pct = entry.remaining_pct, weekly_reset_ms = entry.weekly_reset_ms, observed_at_ms = entry.observed_at_ms,
		binding = entry.binding, principal = entry.principal }
	local function with(status: string, reason: string?): any out.status = status; out.reason = reason; return out end
	if entry.observed_at_ms > now_ms + M.CLOCK_SKEW_MS then return with("unknown", "future_timestamp") end
	if now_ms - entry.observed_at_ms > math.min(p.quota_max_age_ms, evidence.stale_after_ms) then return with("unknown", "stale") end
	if entry.reset_at_ms and entry.reset_at_ms <= now_ms then return with("unknown", "reset_passed") end
	if entry.remaining_pct <= 0 then return with("insufficient", "exhausted") end
	if entry.remaining_pct <= p.quota_reserve_pct then return with("insufficient", "below_reserve") end
	return with("sufficient", nil)
end

local function record_tuple(row: any, assessed: any?): any
	return { id = row.id, revision = row.revision, provider = row.provider, account = row.account_label, profile = row.profile_variant,
		model = row.model_variant, principal = if assessed then assessed.principal else nil }
end
-- Changes relative to the owner-selected record. Account identity counts as changed unless both
-- records are bound to the same USAGE principal with the same labels/profile (labels never prove sameness).
local function needs(from: any, to: any): any
	return { provider = (from.provider or "") ~= (to.provider or ""), model = (from.model or "") ~= (to.model or ""),
		account = (from.account or "") ~= (to.account or "") or (from.profile or "") ~= (to.profile or "")
			or from.principal == nil or from.principal ~= to.principal }
end
M.needs = needs
local function permitted(p: any, need: any, scope: string): boolean
	return (not need.provider or p[scope .. "_provider"] == true) and (not need.account or p[scope .. "_account"] == true)
		and (not need.model or p[scope .. "_model"] == true)
end
local function need_text(need: any): string?
	local out = {}
	for _, key in { "provider", "account", "model" } do if need[key] then table.insert(out, key) end end
	return if #out > 0 then table.concat(out, ",") else nil
end

-- input = { policy, scope?, catalog, evidence, requested = {id, revision}, coordinator, cwd, placement, now_ms, bound }
-- scope: initial_dispatch (default) | worker_rollover | coordinator_rollover; each has its own
-- allowlist and substitution permissions (rollover successors prefer the predecessor's record).
-- outcome: selected | held | owner_gate. Order (plan §7): eligibility and explicit allowlist, then
-- quota constraints, then owner preference (the explicitly selected record first; allowlisted
-- alternatives share one rank, ordered by earlier weekly reset, then record ID).
function M.decide(input: any): any
	local p, c = input.policy, input.catalog
	local scope = input.scope or "initial_dispatch"
	local rows = {}
	for _, row in (if c then c.records else {}) do rows[row.id] = rows[row.id] or {}; table.insert(rows[row.id], row) end
	local function find(id: string, revision: number?): any
		for _, row in rows[id] or {} do if revision == nil or row.revision == revision then return row end end
		return nil
	end
	local requested = find(input.requested.id, input.requested.revision)
	local candidates: { any } = {}
	local decision: any = { outcome = "held", candidates = candidates }
	if not requested then
		decision.reason = { code = "catalog_changed", message = "The " .. (if scope == "initial_dispatch" then "owner-selected" else "predecessor's") .. " record/revision is absent from the current catalog." }
		return decision
	end
	local function eligible(row: any): string?
		if not row.eligible or row.enabled ~= true then return "Record is not eligible/enabled for managed dispatch." end
		if row.cwd ~= input.cwd or row.placement ~= input.placement then return "Configured cwd/placement differ from this work." end
		if input.coordinator and not table.find(row.capabilities or {}, COORDINATOR) then return "Coordinator start requires coordinator-control-v1." end
		return nil
	end
	local requested_assessed = if p.quota_routing then M.assess(input.evidence, requested.id, requested.revision, p, input.now_ms) else nil
	local from = record_tuple(requested, requested_assessed)
	if not p.quota_routing then
		-- Explicit selection exactly as without routing.
		table.insert(candidates, { id = requested.id, revision = requested.revision, rank = 0, status = "explicit" })
		decision.outcome = "selected"; decision.record = requested; decision.switched = false; decision.authority = "explicit"
		return decision
	end
	table.insert(candidates, { id = requested.id, revision = requested.revision, rank = 0, status = requested_assessed.status,
		reason = requested_assessed.reason, remaining_pct = requested_assessed.remaining_pct, weekly_reset_ms = requested_assessed.weekly_reset_ms,
		rejection = eligible(requested) })
	if requested_assessed.status == "sufficient" and not candidates[1].rejection then
		decision.outcome = "selected"; decision.record = requested; decision.switched = false; decision.authority = "requested_sufficient"
		return decision
	end
	local alternatives = {}
	if not input.bound then
		for _, id in p[scope .. "_records"] do
			local row = find(id, nil)
			if not row then
				table.insert(candidates, { id = id, rank = 1, status = "unknown", reason = "not_in_evidence", rejection = "Allowlisted record is absent from the current catalog page." })
				continue
			end
			local assessed = M.assess(input.evidence, row.id, row.revision, p, input.now_ms)
			local to = record_tuple(row, assessed)
			local need = needs(from, to)
			local item = { id = row.id, revision = row.revision, rank = 1, status = assessed.status, reason = assessed.reason,
				remaining_pct = assessed.remaining_pct, weekly_reset_ms = assessed.weekly_reset_ms, needs = need_text(need), rejection = eligible(row) }
			table.insert(candidates, item)
			if item.status == "sufficient" and not item.rejection then table.insert(alternatives, { item = item, row = row, need = need, to = to }) end
		end
	end
	table.sort(alternatives, function(a, b)
		local ra, rb = a.item.weekly_reset_ms or MAX, b.item.weekly_reset_ms or MAX
		return ra < rb or (ra == rb and a.row.id < b.row.id)
	end)
	for _, alt in alternatives do
		if permitted(p, alt.need, scope) then
			decision.outcome = "selected"; decision.record = alt.row; decision.switched = true; decision.authority = "policy"
			decision.from = from; decision.to = alt.to; decision.needs = need_text(alt.need)
			decision.reason = { code = "policy_substitution", message = requested.id .. " is " .. requested_assessed.status .. " (" .. tostring(requested_assessed.reason)
				.. "); Config's " .. scope:gsub("_", "-") .. " allowlist and " .. (decision.needs or "no") .. " substitution permission select " .. alt.row.id .. "." }
			return decision
		end
	end
	if #alternatives > 0 then
		local alt = alternatives[1]
		decision.outcome = "owner_gate"; decision.record = alt.row; decision.switched = true; decision.from = from; decision.to = alt.to
		decision.denied = need_text(alt.need)
		decision.reason = { code = "fallback_denied", message = "The selected record is " .. requested_assessed.status .. " (" .. tostring(requested_assessed.reason)
			.. "); " .. alt.row.id .. " has sufficient quota but Config does not permit a " .. tostring(decision.denied) .. " change. Owner decision required." }
		return decision
	end
	decision.reason = { code = "quota_" .. requested_assessed.status, message = "No allowed record has sufficient fresh quota: "
		.. requested.id .. " is " .. requested_assessed.status .. " (" .. (M.REASONS[requested_assessed.reason or ""] or tostring(candidates[1].rejection or requested_assessed.reason)) .. ")."
		.. (if input.bound then " The provisioned record cannot change." else "") }
	return decision
end
return M
