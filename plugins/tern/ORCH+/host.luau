--!strict
local state = require("./state")
local views = require("./views")
local dispatch = require("./dispatch")
local codec = require("./wire/codec")
local protocol = require("./dispatch_protocol")
local rulings = require("./document_rulings")
local discovery = require("./updater/discovery")
local source_adapter = require("./source_adapter")
local Channel = require("./channel/channel")
local UPGRADE_KEY = "authority_state_v4_original"
local STORE_KEY = "authority_state"
local INITIALIZED_KEY = "authority_state_initialized"
local MAX_AUTHORITY_BYTES = 8 * 1024 * 1024
local CONTROL_RESERVE_BYTES = 512 * 1024
local SETTLEMENT = { bind_coordinator = true, request_retirement = true, begin_recovery = true, confirm_recovery = true, release_controller = true, release_coordinator = true, dispatch_reconcile = true }
local OBSERVATION = { observe_owner = true, mark_uncertain = true }
local function settlement(event: any): boolean
	return SETTLEMENT[event.kind] == true or (event.kind == "dispatch" and event.command ~= "queue" and event.command ~= "catalog" and event.command ~= "reply" and event.command ~= "capacity")
end
local UNSAVED_OBSERVATION = "A fresh safety observation could not be persisted. Release and recovery are blocked in this runtime; repair storage/capacity and restart for fresh inspection."
local boot = string.format("host-%d-%08x-%08x", os.time(), math.random(1, 2147483647), math.random(1, 2147483647))
local function host_clock(): any
	return { now_ms = math.floor(os.time() * 1000), mono_ms = tern.now(), epoch = boot }
end
-- Operator intents (window-side controls) are bounded and one-shot: the consuming window settles
-- one; an intent no window took within INTENT_TTL_MS expires visibly, never later.
local INTENT_LIMIT = dispatch.NATIVE_COMMAND_BYTES
local INTENT_TTL_MS = 30000

-- Detect removed, externally changed or corrupt persisted authority before overwriting it.
local function same_value(left: any, right: any, depth: number): boolean
	if type(left) ~= type(right) or depth > 16 then return false end
	if type(left) ~= "table" then return left == right end
	for key, value in left do
		if not same_value(value, right[key], depth + 1) then return false end
	end
	for key in right do if left[key] == nil then return false end end
	return true
end

-- The host VM is the only writer. A candidate never becomes authority until set returns.
local function new_authority(storage: any, clock: any?): any
	-- `persisted`: the exact JSON text of `registry` as last saved, from the capacity encode.
	local authority: any = { registry = nil, status = "unloaded", diagnostic = nil, raw = nil, established = false, uncommitted_observation = false, persisted = nil }
	local function problem(code: string, message: string): any
		authority.diagnostic = message
		return { ok = false, code = code, message = message }
	end
	local function observation_failure(event: any, failure: any): any
		if OBSERVATION[event.kind] or (event.kind == "dispatch" and (event.command == "result" or event.command == "lost" or event.command == "observe")) then
			authority.uncommitted_observation = true
			authority.diagnostic = UNSAVED_OBSERVATION
			failure.message = tostring(failure.message or failure.code) .. " " .. UNSAVED_OBSERVATION
		end
		return failure
	end
	local function capacity(candidate: any, ordinary: boolean): (any?, boolean, string?)
		local ok, encoded
		local limit = MAX_AUTHORITY_BYTES - (if ordinary then CONTROL_RESERVE_BYTES else 0)
		dispatch.trim_summaries(candidate, limit)
		ok, encoded = pcall(tern.json.encode, candidate)
		if not ok then return problem("serialization_failed", "Authority could not be encoded."), false, nil end
		if #encoded > limit then
			return problem("capacity_reached", "Authority storage capacity reached. Ordinary operations cannot consume the retirement/recovery reserve; unresolved ownership is retained."), false, nil
		end
		return nil, #encoded > MAX_AUTHORITY_BYTES - CONTROL_RESERVE_BYTES, encoded
	end
	local function remember(registry: any, text: string?)
		authority.persisted = if text ~= nil then { registry = registry, text = text } else nil
	end
	-- Equal JSON text proves the stored value is the saved registry (both round-trip through
	-- kv JSON). Differing text (key order, an external write) falls back to the deep compare.
	local function stored_text_matches(raw: any): boolean
		local saved = authority.persisted
		if saved == nil or saved.registry ~= authority.registry then return false end
		local ok, text = pcall(tern.json.encode, raw)
		if not ok then return false end
		if text == saved.text then return true end
		if saved.decoded_text == nil then
			-- kv.get returns decoded JSON; compare against the saved text in that same decoded form.
			local decoded, value = pcall(tern.json.decode, saved.text)
			local encoded, again = false, nil
			if decoded then encoded, again = pcall(tern.json.encode, value) end
			saved.decoded_text = if encoded then again else false
		end
		return text == saved.decoded_text
	end
	-- Installation evidence, not a completed-operation history. Any non-null value fences
	-- first use; the root alone owns namespace and exact migration source identity.
	local function initialization_marker(backfill: boolean): (any?, any?)
		local ok, marker = pcall(storage.get, INITIALIZED_KEY)
		if not ok then
			authority.status = "marker_unreadable"
			authority.registry, authority.persisted = nil, nil
			authority.migration_qualification, authority.migration_pair = nil, nil
			return nil, problem("store_unreadable", "Authority initialization evidence could not be read. Repair storage before using or initializing authority.")
		end
		if marker ~= nil then authority.established = true end
		if marker == nil and backfill then
			if not pcall(storage.set, INITIALIZED_KEY, true) then
				authority.status = "marker_save_failed"
				authority.registry, authority.persisted = nil, nil
				authority.migration_qualification, authority.migration_pair = nil, nil
				return nil, problem("persistence_failed", "Authority initialization evidence could not be saved. The existing source is retained; repair storage and reload before proceeding.")
			end
			marker = true
			authority.established = true
		end
		return marker, nil
	end
	function authority:load(): any
		self.registry, self.persisted, self.raw = nil, nil, nil
		self.migration_source, self.migration_source_hash = nil, nil
		self.migration_qualification, self.migration_pair = nil, nil
		local ok, raw = pcall(storage.get, STORE_KEY)
		if not ok then
			self.status = "unreadable"
			return problem("store_unreadable", "Authority store could not be read. Restore or repair its backup; no authority was replaced.")
		end
		self.raw = raw
		if raw ~= nil then self.established = true end
		local _, marker_failure = initialization_marker(raw ~= nil)
		if marker_failure then return marker_failure end
		if raw == nil then
			self.status = if self.established then "missing_established" else "missing"
			return problem("store_missing", "No authority store found. If this installation had owners, restore its backup; do not initialize a replacement.")
		end
		local candidate, diagnostic = state.rehydrate(raw)
		if candidate == nil then
			local legacy = state.migration_source(raw)
			if legacy then
				self.status = "migration_required"
				self.migration_namespace = self.migration_namespace or state.new_namespace()
				self.migration_source = legacy
				self.migration_source_hash = codec.sha256(codec.dispatch_source_bytes(raw))
				return problem("migration_required", "Existing authority validated. Explicit paired native migration is required; immutable grants and unresolved obligations must remain blocked.")
			end
			self.status = "quarantined"
			return problem(if type(diagnostic) == "table" then diagnostic.code else "invalid_store",
				if type(diagnostic) == "table" then diagnostic.message else "Stored authority is quarantined; restore a valid backup. No empty authority was substituted.")
		end
		local full, _, encoded = capacity(candidate, false)
		if full ~= nil then
			self.status = "quarantined"
			return full
		end
		if type(diagnostic) == "table" and diagnostic.upgrade_required then
			local read_ok, existing = pcall(storage.get, UPGRADE_KEY)
			if not read_ok then self.status = "upgrade_backup_failed"; return problem("upgrade_backup_failed", "The pre-upgrade original could not be read; authority remains unchanged.") end
			local backup, failure = state.upgrade_backup(raw, existing)
			if not backup then self.status = "upgrade_backup_failed"; return failure end
			if existing == nil and not pcall(storage.set, UPGRADE_KEY, backup) then
				self.status = "upgrade_backup_failed"; return problem("upgrade_backup_failed", "The pre-upgrade original could not be preserved; authority remains unchanged.")
			end
			local confirmed, original = pcall(storage.get, UPGRADE_KEY)
			local unchanged, current = pcall(storage.get, STORE_KEY)
			if not confirmed or not same_value(original, raw, 0) or not unchanged or not same_value(current, raw, 0) then
				self.status = "upgrade_backup_failed"; return problem("upgrade_backup_failed", "Pre-upgrade preservation readback changed; no v5 authority was written.")
			end
		end
		local saved = pcall(storage.set, STORE_KEY, candidate)
		if not saved then
			self.status = "restore_save_failed"
			return problem("persistence_failed", "Restored ownership could not be persisted. No restored grant is exposed; retry the store read after repairing storage.")
		end
		local read_ok, committed = pcall(storage.get, STORE_KEY)
		if not read_ok or not same_value(committed, candidate, 0) then
			self.status = "restore_readback_failed"
			return problem("persistence_failed", "Restored authority readback could not be confirmed. The original is retained for evidence, never executable rollback.")
		end
		self.registry = candidate
		remember(candidate, encoded)
		self.established = true
		self.status = "ready"
		self.diagnostic = if self.uncommitted_observation then UNSAVED_OBSERVATION else nil
		return { ok = true, code = "restored", revision = candidate.revision }
	end
	function authority:window_readback(namespace: any, revision: any, archive: any): any
		if self.status ~= "ready" or not self.registry or self.registry.version ~= 5
			or namespace ~= self.registry.authority_namespace or revision ~= self.registry.revision then
			return problem("stale_revision", "Read the current compatible authority projection before completing upgrade preservation.")
		end
		local ok, original = pcall(storage.get, UPGRADE_KEY)
		if not ok then return problem("upgrade_backup_failed", "Upgrade evidence could not be read.") end
		if original == nil then return { ok = true, code = "upgrade_complete" } end
		local read_ok, committed = pcall(storage.get, STORE_KEY)
		if not read_ok or not same_value(committed, self.registry, 0) then return problem("store_changed", "Committed v5 readback changed; the original is retained.") end
		local archived, confirmed = pcall(archive, original)
		if not archived or confirmed ~= true then return problem("upgrade_archive_failed", "Private upgrade evidence could not be confirmed; the temporary original is retained.") end
		local still_ok, retained = pcall(storage.get, UPGRADE_KEY)
		if not still_ok or not same_value(retained, original, 0) then return problem("upgrade_backup_conflict", "Upgrade original changed during archival.") end
		if not pcall(storage.set, UPGRADE_KEY, nil) then return problem("upgrade_archive_failed", "Private evidence is preserved; temporary original removal failed.") end
		local removed, value = pcall(storage.get, UPGRADE_KEY)
		if not removed or value ~= nil then return problem("upgrade_archive_failed", "Temporary upgrade evidence removal could not be confirmed.") end
		return { ok = true, code = "upgrade_complete" }
	end
	function authority:initialize(verified_first_use: boolean): any
		if self.status ~= "missing" or self.established or verified_first_use ~= true then
			return problem("initialization_refused", "Initialization is only for explicitly verified first use, never lost or quarantined ownership.")
		end
		local ok, raw = pcall(storage.get, STORE_KEY)
		if not ok or raw ~= nil then
			self.status = "store_changed"
			return problem("store_changed", "The store changed or became unreadable. Recheck it before proceeding.")
		end
		local marker, marker_failure = initialization_marker(false)
		if marker_failure then return marker_failure end
		if marker ~= nil then
			self.status = "missing_established"
			return problem("initialization_refused", "Authority was previously initialized. Restore its original store instead of creating a replacement.")
		end
		local candidate = state.new_registry()
		local full, _, encoded = capacity(candidate, true)
		if full ~= nil then return full end
		if not pcall(storage.set, STORE_KEY, candidate) then
			self.status = "initialization_save_failed"
			return problem("persistence_failed", "Initialization persistence could not be confirmed. No authority was exposed; repair storage and reload the exact saved source before proceeding.")
		end
		-- First use saves the root before its marker, and publishes neither until both
		-- writes succeed. An interrupted pair must reload this exact saved root.
		self.raw, self.established = candidate, true
		local _, saved_marker_failure = initialization_marker(true)
		if saved_marker_failure then return saved_marker_failure end
		self.registry = candidate
		remember(candidate, encoded)
		self.established = true
		self.status = "ready"
		self.diagnostic = nil
		return { ok = true, code = "initialized", revision = candidate.revision }
	end
	function authority:create(event: any, defaults_revision: any): any
		if self.status ~= "ready" or not self.registry or self.uncommitted_observation then return problem("authority_unavailable", "Repair authority before creating an orchestration.") end
		if event.authority_namespace ~= self.registry.authority_namespace or event.expected_revision ~= self.registry.revision then return problem("stale_revision", "Authority changed since creation was requested; review the current orchestration list.") end
		if defaults_revision ~= nil and defaults_revision ~= self.registry.installation_defaults.revision then return problem("stale_defaults", "Default settings changed. Review them before creating this orchestration.") end
		local now = (clock or host_clock)()
		local candidate, response = state.apply(self.registry, event, now)
		if not candidate or not response.ok then return response end
		candidate, response = state.apply(candidate, { kind = "admit_controller", request_id = event.request_id .. "-admit",
			orch_session_id = event.orch_session_id, authority_namespace = candidate.authority_namespace,
			expected_revision = candidate.revision, pane_binding = event.binding }, now)
		if not candidate or not response.ok then return response end
		local full, _, encoded = capacity(candidate, true)
		if full then return full end
		if not state.valid(candidate) then return problem("invalid_candidate", "The new orchestration failed validation.") end
		local ok, current = pcall(storage.get, STORE_KEY)
		if not ok or not same_value(current, self.registry, 0) then return problem("store_changed", "Authority changed before orchestration creation.") end
		if not pcall(storage.set, STORE_KEY, candidate) then self.status = "creation_save_failed"; return problem("persistence_failed", "Creation could not be confirmed. Reload the saved authority before trying another creation.") end
		self.registry = candidate; remember(candidate, encoded)
		response.orch_session_id = event.orch_session_id
		return response
	end
	function authority:apply(event: any): any
		if self.status ~= "ready" or self.registry == nil then
			return problem("authority_unavailable", "Repair or restore the authority store before changing ownership.")
		end
		-- The external-change check guards the write below. Refusals, exact replays and no-op
		-- answers never write, so they skip it. An unchanged store is matched natively against
		-- the saved JSON text; only a text mismatch pays the O(registry) Lua deep compare.
		local function store_unchanged(): any?
			local ok, raw = pcall(storage.get, STORE_KEY)
			if ok and raw ~= nil and (stored_text_matches(raw) or same_value(raw, self.registry, 0)) then return nil end
			self.status = "store_changed"
			return problem("store_changed", "Authority storage disappeared or changed. Ownership remains occupied; restore/recheck before continuing.")
		end
		local now = (clock or host_clock)()
		local candidate, response = state.apply(self.registry, event, now)
		if candidate == nil then
			if response.code == "capacity_reached" then return observation_failure(event, response) end
			return response
		end
		if candidate == self.registry then return response end
		if self.uncommitted_observation and (SETTLEMENT[event.kind] or event.kind == "dispatch") then
			return problem("uncommitted_observation", UNSAVED_OBSERVATION)
		end
		local full, uses_reserve, encoded = capacity(candidate, not settlement(event) and event.kind ~= "observe_owner")
		if full ~= nil then return observation_failure(event, full) end
		if uses_reserve then
			-- Byte capacity can hit reserve before the outcome count does. Reuse the
			-- reducer's exact no-progress/serialization policy; no first candidate escaped.
			local reserved = table.clone(now); reserved.reserved_capacity = true
			candidate, response = state.apply(self.registry, event, reserved)
			if candidate == nil then
				if response.code == "capacity_reached" then return observation_failure(event, response) end
				return response
			end
			local ok, text = pcall(tern.json.encode, candidate)
			encoded = if ok then text else nil
		end
		if not state.valid(candidate) then
			return observation_failure(event, problem("invalid_candidate", "Authority candidate failed validation; no state was published."))
		end
		local changed = store_unchanged()
		if changed ~= nil then return changed end
		if not pcall(storage.set, STORE_KEY, candidate) then
			return observation_failure(event, problem("persistence_failed", "Ownership change was not saved. The previous owner and recovery intent remain authoritative."))
		end
		self.registry = candidate
		remember(candidate, encoded)
		self.diagnostic = if self.uncommitted_observation then UNSAVED_OBSERVATION else nil
		return response
	end
	function authority:qualify(event: any, peer_proof: any, peer_selection: any): any
		if self.status ~= "ready" or not self.registry or self.uncommitted_observation then
			return problem("authority_unavailable", "Repair the existing authority before pairing stores.")
		end
		local candidate, response = state.qualify_current(self.registry, event, peer_proof, peer_selection)
		if candidate == nil or candidate == self.registry then return response end
		if not state.valid(candidate) then return problem("invalid_candidate", "Paired candidate validation failed.") end
		local full, _, encoded = capacity(candidate, false)
		if full then return full end
		local ok, raw = pcall(storage.get, STORE_KEY)
		if not ok or raw == nil or not (stored_text_matches(raw) or same_value(raw, self.registry, 0)) then
			self.status = "store_changed"
			return problem("store_changed", "Authority changed during native pairing; no store was replaced.")
		end
		if not pcall(storage.set, STORE_KEY, candidate) then return problem("persistence_failed", "Pairing was not persisted.") end
		self.registry = candidate
		remember(candidate, encoded)
		return response
	end
	function authority:migration_evidence(intent: any, peer: any): (any?, any?)
		if self.status ~= "ready" and self.status ~= "migration_required" then
			return nil, problem("authority_unavailable", "Repair and reload the exact authority source before migration.")
		end
		local source = self.registry or self.raw
		local namespace = if self.registry then self.registry.authority_namespace else self.migration_namespace
		if not source or type(peer) ~= "table" or intent.authority_namespace ~= namespace or intent.expected_revision ~= source.revision
			or (not self.registry and intent.source_sha256 ~= self.migration_source_hash) then
			return nil, problem("stale_revision", "Migration intent no longer names the exact source. Read both native sources again.")
		end
		local own, diagnostic
		for key in peer do if key ~= "proof" and key ~= "selection" then return nil, problem("invalid_peer", "Qualification has unknown fields.") end end
		if self.registry then own, diagnostic = state.migration_proof(source, peer.selection)
		else own, diagnostic = state.legacy_migration_proof(source, namespace, peer.selection) end
		if not own then return nil, diagnostic end
		local read_ok, stored = pcall(storage.get, STORE_KEY)
		local encoded_ok, stored_bytes = pcall(codec.dispatch_source_bytes, stored)
		if not read_ok or not encoded_ok or type(stored_bytes) ~= "string" or codec.sha256(stored_bytes) ~= own.source_sha256 then
			return nil, problem("store_changed", "The complete persisted source changed; no stale qualification was published.")
		end
		local _, marker_failure = initialization_marker(true)
		if marker_failure then return nil, marker_failure end
		local pair = { schema = 1, kind = "migration", orch = own, spawn = peer.proof }
		if not codec.validate_dispatch_compatibility(pair) then return nil, problem("migration_blocked", "Complete independently validated peer proof is required.") end
		self.migration_qualification = { proof = own, selection = dispatch.migration_selection(source) }
		self.migration_pair = pair
		return pair, nil
	end
	function authority:migrate(operation: string, intent: any, peer: any): any
		if self.uncommitted_observation then return problem("authority_unavailable", UNSAVED_OBSERVATION) end
		local pair, failure = self:migration_evidence(intent, peer)
		if not pair then return failure end
		if operation == "inspect" then return { ok = true, code = "migration_observed", message = "Independent current source proofs published. Update / reconnect verifies both owners before advancing the paired update." } end
		if self.registry and not self.registry.migration and operation == "prepare" then
			local response = self:qualify({ kind = "qualify_current", request_id = intent.request_id,
				authority_namespace = intent.authority_namespace, expected_revision = intent.expected_revision }, peer.proof, peer.selection)
			if response.ok then self:migration_evidence({ authority_namespace = self.registry.authority_namespace, expected_revision = self.registry.revision }, peer) end
			return response
		end
		local candidate, response
		if operation == "prepare" and not self.registry then
			candidate, response = state.prepare_migration(self.raw, intent.authority_namespace, peer.proof, peer.selection)
		elseif operation == "finish" and self.registry then
			candidate, response = state.finish_migration(self.registry, pair, peer.selection)
		else return problem("migration_blocked", "This source is not in the selected migration phase.") end
		if not candidate then return response end
		if not state.valid(candidate) then return problem("invalid_candidate", "Migration candidate failed complete validation.") end
		local full, _, encoded = capacity(candidate, false)
		if full then return full end
		local ok, raw = pcall(storage.get, STORE_KEY)
		local encoded_ok, source_bytes = pcall(codec.dispatch_source_bytes, raw)
		if not ok or not encoded_ok or type(source_bytes) ~= "string" or codec.sha256(source_bytes) ~= pair.orch.source_sha256 then
			return problem("store_changed", "The complete source changed after observation. No candidate was persisted.")
		end
		if not pcall(storage.set, STORE_KEY, candidate) then return problem("persistence_failed", "Migration was not persisted; the source remains authoritative.") end
		self.registry, self.raw, self.status, self.established = candidate, candidate, "ready", true
		self.migration_qualification = nil
		remember(candidate, encoded)
		self:migration_evidence({ authority_namespace = candidate.authority_namespace, expected_revision = candidate.revision }, peer)
		return response
	end
	return authority
end

local authority = new_authority(tern.kv)
local contexts: { [number]: any } = {}
local serial = 0
local function nonce(): string
	serial += 1
	return boot .. "-" .. tostring(serial)
end
-- While an event is being handled, nested render requests are ignored; `event` below then
-- renders every block only when committed authority changed, else just the originating block
-- when its own view-visible state changed (window drivers read its result/receipt surfaces).
local handling_event = false
-- A forgotten orchestration leaves no selection, scoped result or saved id behind. Only a successfully LOADED authority
-- (ready, with the installation-level notice naming this exact session and the session truly gone) may authorize this:
-- missing, corrupt or unreadable storage never clears anything.
local FORGOTTEN_VIEW_FIELDS = { "scoped_results", "dispatch_command_result", "dispatch_action", "recovery",
	"attestation", "close_armed", "relay_notice", "creation_ready", "setup_result", "migration_result", "orchestration_result", "forget" }
-- Any session id the loaded authority no longer holds is cleared with its scoped results. A forgotten orchestration clears at
-- once and shows the completion notice; any other absent id (an ordinary close) is kept for a short grace so the closed bridge
-- view can still release through its session_closed alias, and is never written to saved data.
local ABSENT_GRACE_MS = 5000
local function authority_lacks(view: any): boolean
	local registry = authority.registry
	return authority.status == "ready" and registry ~= nil and view.orch_session_id ~= nil and registry.sessions[view.orch_session_id] == nil
end
local function normalize_view(view: any)
	if not authority_lacks(view) then view.absent_since = nil; return end
	local forgotten = authority.registry.forgotten
	if forgotten == nil or forgotten.orch_session_id ~= view.orch_session_id then
		if view.absent_since == nil then view.absent_since = tern.now(); return end
		if tern.now() - view.absent_since < ABSENT_GRACE_MS then return end
	else
		view.notice = require("./forget_text").DONE
	end
	for _, field in FORGOTTEN_VIEW_FIELDS do view[field] = nil end
	view.orch_session_id, view.absent_since = nil, nil
end
local function render_all()
	if handling_event then return end
	for _, entry in contexts do normalize_view(entry.view); entry.cx:render() end
end
local function authority_signature(): string
	return tostring(authority.status) .. "\0" .. tostring(authority.diagnostic) .. "\0" .. tostring(authority.uncommitted_observation)
end
local function view_signature(view: any): string?
	-- Current-control bookkeeping never changes the visible presentation.
	local visible = table.clone(view); visible.actions = nil; visible.action_serial = nil
	visible.action_order = nil; visible.action_incarnation = nil; visible.action_previous = nil
	visible.navigation_actions = nil; visible.navigation_scope = nil
	local ok, encoded = pcall(tern.json.encode, visible)
	return if ok then encoded else nil
end
local function decode(value: any): any?
	if type(value) ~= "string" or #value > 8192 then return nil end
	local result = codec.strict_decode(value, 8192)
	return if type(result) == "table" then result else nil
end
local function session_for(view: any): any?
	return if authority.registry ~= nil and view.orch_session_id ~= nil then authority.registry.sessions[view.orch_session_id] else nil
end
-- The window an assist intent must run in: the continued origin's window, named by the session's command
-- cursor while it belongs to the active controller owner/generation. With no cursor yet, or a controller
-- restored uncertain (no live origin to prefer), nil keeps assistance open to any window showing it.
local function assist_window(view: any): any?
	local session = session_for(view)
	local owner = if session then session.controller else nil
	if not owner or owner.phase ~= "active" or not authority.registry.dispatch then return nil end
	local cursor = (authority.registry.dispatch.command_cursors or {})[view.orch_session_id]
	local origin = if type(cursor) == "table" then cursor.origin else nil
	if type(origin) ~= "table" or origin.owner_id ~= owner.owner_id or origin.owner_generation ~= owner.generation then return nil end
	return { window_key = origin.window_key, window_epoch = origin.window_epoch, native_session_id = origin.native_session_id, window_host_id = origin.window_host_id }
end
local function binding(view: any): any
	return { host_pane_id = tostring(view.pane), alias_nonce = view.alias_nonce }
end
-- Plain reasons for refusals whose reducer text is not owner-facing.
local REFUSAL_TEXT = { policy_too_large = "Settings too large — shorten templates or guidance." }
local function action(view: any, event: any, defer_render: boolean?): any
	event.request_id = event.request_id or nonce()
	local response = table.clone(authority:apply(event))
	if response.ok == false and REFUSAL_TEXT[response.code] then response.message = REFUSAL_TEXT[response.code] end
	response.request_id = event.request_id
	view.notice = tostring(response.message or response.code)
	if not defer_render then render_all() end
	return response
end
local function owner_event(view: any, entry: any, kind: string): any
	return {
		kind = kind, orch_session_id = entry.orch_session_id, target = entry.target,
		authority_namespace = entry.authority_namespace, expected_revision = entry.expected_revision or entry.revision,
		expected_owner_id = entry.owner_id, expected_generation = entry.generation,
	}
end
local function confirmation(view: any, entry: any, field: string): any
	local intent = entry.intent
	if intent == nil or intent ~= view[field] then
		view.notice = "Confirmation expired. Inspect and confirm the current intent."
		render_all()
		return nil
	end
	return intent
end
local function dispatch_consumer(origin: any): any
	local session = authority.registry.sessions[origin.logical_session_id]
	return { authority_namespace = authority.registry.authority_namespace, logical_session_id = origin.logical_session_id,
		admission_seq = if session then session.admission_seq else nil, origin = table.clone(origin) }
end
local function capture_dispatch(view: any, response: any, receipt: any?, consumer: any?)
	if type(response.action_id) ~= "string" then return end
	local pending = if authority.registry then authority.registry.dispatch.actions[response.action_id] else nil
	if not receipt and not pending then return end
	view.scoped_results = view.scoped_results or {}
	local retained = view.scoped_results[response.action_id] or {}
	retained.result = response
	if receipt then retained.receipt = receipt end
	if consumer then retained.consumer = consumer
	elseif pending and not retained.consumer then
		local projected = dispatch.project(authority.registry, view.orch_session_id, view.alias_nonce, response.action_id).actions[response.action_id]
		retained.consumer = dispatch_consumer(if projected then projected.execution_origin else pending.request.origin_binding)
	end
	view.scoped_results[response.action_id] = retained
end
local function consumer_retired(consumer: any): boolean
	local registry = authority.registry
	if not consumer or not registry or registry.authority_namespace ~= consumer.authority_namespace then return false end
	local session = registry.sessions[consumer.logical_session_id]
	-- Session identities never return after confirmed closure. Unknown/unloaded authority is not proof.
	if not session then return true end
	if session.admission_seq ~= consumer.admission_seq then return false end
	local origin = consumer.origin
	if session.generation_floor >= origin.owner_generation then return true end
	local cursor = registry.dispatch.command_cursors[consumer.logical_session_id]
	return cursor ~= nil and cursor.continued_epoch ~= nil and not same_value(cursor.origin, origin, 0)
end
local function prune_scopes()
	for _, context in contexts do
		local result = context.view.orchestration_result
		-- Only loaded authority proves a created session was removed, regardless of the view's current selection.
		if authority.status == "ready" and authority.registry and result and result.ok and result.orch_session_id
			and authority.registry.sessions[result.orch_session_id] == nil then
			context.view.orchestration_result = nil
		end
		for action_id, retained in context.view.scoped_results or {} do
			if consumer_retired(retained.consumer) or (authority.registry and authority.registry.dispatch.actions[action_id] == nil and not retained.receipt) then
				context.view.scoped_results[action_id] = nil
			end
		end
	end
end
local PANE_STATES = { idle = true, working = true, waiting_input = true, exited = true, unknown = true }
local function bounded_text(value: any, maximum: number, empty: boolean?): boolean
	return type(value) == "string" and (empty or #value > 0) and #value <= maximum and utf8.len(value) ~= nil
end
local function dispatch_notice(input: any): any?
	if type(input) ~= "table" or not bounded_text(input.message, 1024)
		or (input.level ~= "error" and input.level ~= "info" and input.level ~= "success")
		or (input.context ~= nil and input.context ~= "catalog")
		or (input.code ~= nil and not bounded_text(input.code, 128))
		or (input.detail ~= nil and not bounded_text(input.detail, 2048)) then return nil end
	return { message = input.message, level = input.level, context = input.context, code = input.code, detail = input.detail }
end
local function session_panes(input: any): any?
	-- Window-side observation pushed for display only: bounded current-session agent panes, never identity.
	if type(input) ~= "table" or input.version ~= 1 or not bounded_text(input.native_session_id, 256) or not bounded_text(input.window_host_id, 256)
		or not bounded_text(input.window_epoch, 256) or type(input.panes) ~= "table" or #input.panes > 64
		or type(input.more) ~= "number" or input.more < 0 or input.more % 1 ~= 0 then return nil end
	for key in input do
		if not table.find({ "version", "source_nonce", "native_session_id", "window_host_id", "window_epoch", "panes", "more" }, key) then return nil end
	end
	for _, row in input.panes do
		if type(row) ~= "table" or type(row.pane) ~= "number" or row.pane < 0 or row.pane % 1 ~= 0 or not bounded_text(row.title, 64, true)
			or not PANE_STATES[row.state] or (row.worker_id ~= nil and not (bounded_text(row.worker_id, 96) and row.worker_id:match("^[A-Za-z0-9_-]+$"))) then return nil end
		if row.exit_code ~= nil and (type(row.exit_code) ~= "number" or row.exit_code % 1 ~= 0
			or math.abs(row.exit_code) > 9007199254740991 or row.state ~= "exited") then return nil end
		for key in row do if not table.find({ "pane", "title", "state", "worker_id", "exit_code" }, key) then return nil end end
		row.key = string.format("%d@%s@%s@%s", row.pane, input.window_epoch, input.native_session_id, input.window_host_id)
	end
	return input
end
local function setup_decode(value: any): any?
	if type(value) ~= "string" or #value > INTENT_LIMIT then return nil end
	local input = codec.strict_decode(value, INTENT_LIMIT)
	return if type(input) == "table" then input else nil
end
local function setup_fields(value: any, allowed: { string }): boolean
	if type(value) ~= "table" then return false end
	for key in value do if not table.find(allowed, key) then return false end end
	return true
end
local function publish_intent(view: any, entry: any)
	if entry.navigation then
		-- A menu click begins a fresh choice; it never submits a stored effect.
		-- Do not mutate the stable display descriptor or its shared request.
		entry = table.clone(entry)
		entry.request = table.clone(entry.request)
		entry.request.authority_namespace = if authority.registry then authority.registry.authority_namespace else nil
		entry.request.expected_revision = if authority.registry then authority.registry.revision else nil
	end
	local intent = { version = 1, source_nonce = view.alias_nonce, serial = nonce(),
		kind = if entry.kind == "operator-intent" then "dispatch" elseif entry.kind == "setup-intent" then "setup" else "assist",
		request = if entry.kind == "setup-intent" then { command = entry.command, source_nonce = view.alias_nonce, native_window = entry.native_window,
			authority_namespace = entry.authority_namespace, expected_revision = entry.expected_revision, source_sha256 = entry.source_sha256 } else entry.request,
		window = if entry.kind == "assist-intent" then assist_window(view) else nil }
	local ok, bytes = pcall(tern.json.encode, intent)
	if not ok or #bytes > INTENT_LIMIT then
		view.notice = "REFUSED: this control's request exceeds the " .. tostring(INTENT_LIMIT) .. "-byte intent bound; nothing ran."
		return
	end
	view.operator_intent = intent; view.operator_intent_at = tern.now()
end
local function open_defaults(view: any, native_window: string?)
	if authority.status == "missing" and not authority.established then
		local response = authority:initialize(true)
		if not response.ok then view.notice = response.message or response.code; render_all(); return end
	end
	if authority.status ~= "ready" or not authority.registry then
		view.notice = "Restore the existing authority before changing defaults. No orchestration or replacement authority was created."
		render_all(); return
	end
	view.config_open = true
	publish_intent(view, { kind = "setup-intent", command = "defaults", native_window = native_window,
		authority_namespace = authority.registry.authority_namespace, expected_revision = authority.registry.revision })
	render_all()
end
local function page_entry(view: any, value: any)
	local page = decode(value)
	if not setup_fields(page, { "kind", "page", "native_window" }) or page.kind ~= "page" or page.page ~= "readiness"
		or not bounded_text(page.native_window, 256, true) or page.native_window:find("%z") then
		view.notice = "REFUSED: invalid native readiness page entry; nothing ran."
		return
	end
	view.config_open = true
	publish_intent(view, { kind = "setup-intent", command = "readiness", native_window = page.native_window })
end
local function setup_catalog_cursor(value: any): boolean
	-- Match SPAWN's closed catalog cursor, not an opaque text token.
	if not setup_fields(value, { "revision", "index" }) then return false end
	return type(value.revision) == "number" and value.revision >= 0 and value.revision <= 9007199254740991 and value.revision % 1 == 0
		and type(value.index) == "number" and value.index >= 1 and value.index <= 9007199254740991 and value.index % 1 == 0
end
local function setup_origin(value: any, view: any): boolean
	if not setup_fields(value, { "host_pane_id", "window_key", "window_epoch", "native_session_id", "window_host_id" })
		or value.host_pane_id ~= tostring(view.pane) then return false end
	for _, key in { "host_pane_id", "window_key", "native_session_id", "window_host_id" } do
		if not bounded_text(value[key], 256, key == "window_key") or value[key]:find("%z") then return false end
	end
	return bounded_text(value.window_epoch, 96) and value.window_epoch:match("^[A-Za-z0-9_-]+$") ~= nil
end
local function setup_result(view: any, input: any, result: any)
	view.setup_result = table.clone(result)
	view.setup_result.request_id = input.request_id
	view.notice = tostring(result.message or result.code)
	render_all()
end

local function repository_refs(bytes: string): (any?, string?)
	if #bytes > 262144 then return nil, "The local reference list is too large. Choose an explicit existing branch/ref." end
	local heads, advertised, branches = {}, {}, {}
	for line in bytes:gmatch("[^\r\n]+") do
		local ref, symbolic = line:match("^([^\t]+)\t(.*)$")
		if not ref or #ref > 256 or ref:find("%c") then return nil, "Git returned an unsupported reference list." end
		if ref:match("^refs/heads/.+") then heads[ref] = true end
		local remote = ref:match("^(refs/remotes/.+)/HEAD$")
		if remote and symbolic:sub(1, #remote + 1) == remote .. "/" then
			local target = "refs/heads/" .. symbolic:sub(#remote + 2)
			if #target <= 256 and not target:find("%c") then advertised[target] = true end
		end
	end
	for ref in heads do table.insert(branches, ref) end
	table.sort(branches)
	local defaults, unique = 0, nil
	for ref in advertised do defaults += 1; unique = ref end
	local target = if defaults == 1 and heads[unique] then unique
		elseif defaults == 0 and #branches == 1 then branches[1] else nil
	local reason = if target then (if defaults == 1 then "Repository default found from local remote-HEAD metadata." else "Only one local branch is recorded; review the suggested target before saving.")
		elseif defaults > 1 then "Remotes advertise different default branches. Choose the intended existing target."
		elseif defaults == 1 then "The advertised default branch is not available as a local branch. Choose an existing target, or make that branch available outside ORCH+."
		else "No unambiguous repository default is recorded locally. Choose the intended existing target."
	local clipped = #branches > 64
	while #branches > 64 do table.remove(branches) end
	return { branches = branches, default_ref = target, message = reason, branches_clipped = clipped }, nil
end
local function read_repository_refs(view: any, input: any, done: any)
	view.setup_probe = input.request_id
	local started, failure = pcall(function()
		tern.process.run({ "git", "-C", input.cwd, "for-each-ref", "--format=%(refname)%09%(symref)", "refs/heads", "refs/remotes" },
			{ timeout_ms = 10000 }, function(observed: any)
				if view.setup_probe ~= input.request_id or contexts[view.pane] == nil then return end
				view.setup_probe = nil
				if observed.status ~= 0 or observed.timed_out or observed.truncated or observed.stdout_truncated then
					done(nil, "This folder has no readable local Git repository. Text and research need no repository; choose a code folder only when needed.")
				else
					local refs, problem = repository_refs(observed.stdout or "")
					done(refs, problem)
				end
			end)
	end)
	if not started then view.setup_probe = nil; done(nil, "Local Git discovery could not start: " .. tostring(failure):gsub("%c", " "):sub(1, 300)) end
end
-- The host probes its own Git, never the desktop's possibly different machine.
-- Probe observations are view-local until the ordinary expected-revision writer saves them.
local function probe_repository(view: any, input: any, complete: any?)
	local function refuse(message: string)
		local response = { ok = false, code = "repository_unavailable", message = message }
		if complete then complete(response) else setup_result(view, input, response) end
	end
	if not setup_fields(input, { "source_nonce", "request_id", "cwd", "target_ref" })
		or not bounded_text(input.cwd, 512) or input.cwd:find("%c")
		or not (input.cwd:sub(1, 1) == "/" or input.cwd:match("^%a:[\\/]"))
		or not bounded_text(input.target_ref, 256, true) or input.target_ref:find("%c") or input.target_ref:sub(1, 1) == "-" then
		refuse("Choose an absolute repository directory and a named target branch."); return
	end
	if input.target_ref == "" then
		read_repository_refs(view, input, function(refs: any, problem: string?)
			if not refs then refuse(problem or "Could not read local repository references."); return end
			if not refs.default_ref then
				local response = { ok = false, code = "repository_target_required", message = refs.message,
					branches = refs.branches, branches_clipped = refs.branches_clipped }
				if complete then complete(response) else setup_result(view, input, response) end
				return
			end
			local detected = table.clone(input); detected.target_ref = refs.default_ref
			probe_repository(view, detected, complete)
		end)
		return
	end
	view.setup_repository = nil
	view.setup_probe = input.request_id
	local target = if input.target_ref:sub(1, 5) == "refs/" then input.target_ref else "refs/heads/" .. input.target_ref
	local repository = { cwd = input.cwd, target_ref = target }
	local steps = {
		{ argv = { "git", "check-ref-format", target } },
		{ argv = { "git", "-C", input.cwd, "rev-parse", "--path-format=absolute", "--show-toplevel" }, field = "repo_root" },
		{ argv = { "git", "-C", input.cwd, "rev-parse", "--path-format=absolute", "--git-common-dir" }, field = "common_dir" },
		{ argv = { "git", "-C", input.cwd, "rev-parse", "--verify", "--end-of-options", target .. "^{commit}" }, field = "head_revision" },
	}
	local function run(index: number)
		if view.setup_probe ~= input.request_id or contexts[view.pane] == nil then return end
		local step = steps[index]
		if step == nil then
			view.setup_probe = nil
			repository.cwd = repository.repo_root
			view.setup_repository = repository
			local response = { ok = true, code = "repository_verified", repository = repository,
				message = "Repository and target branch verified by Git on the execution host." }
			if complete then complete(response) else setup_result(view, input, response) end
			return
		end
		local ok, failure = pcall(function()
			tern.process.run(step.argv, { timeout_ms = 10000 }, function(result: any)
				if view.setup_probe ~= input.request_id or contexts[view.pane] == nil then return end
				if result.status ~= 0 or result.timed_out or result.truncated or result.stdout_truncated then
					view.setup_probe = nil
					refuse("Git could not verify this repository/target: " .. tostring(result.stderr or ""):gsub("%c", " "):sub(1, 512))
					return
				end
				if step.field then
					local value = (result.stdout or ""):gsub("[\r\n]+$", "")
					if not bounded_text(value, 512) or value:find("%c")
						or (step.field == "head_revision" and ((#value ~= 40 and #value ~= 64) or not value:match("^[a-f0-9]+$")))
						or (step.field ~= "head_revision" and not (value:sub(1, 1) == "/" or value:match("^%a:[\\/]"))) then
						view.setup_probe = nil; refuse("Git returned unsupported repository evidence."); return
					end
					repository[step.field] = value
				end
				run(index + 1)
			end)
		end)
		if not ok then view.setup_probe = nil; refuse("Git probe could not start: " .. tostring(failure):gsub("%c", " "):sub(1, 512)) end
	end
	run(1)
end

local function readiness_host(view: any, input: any, prepare: boolean)
	if view.readiness_pending then
		setup_result(view, input, { ok = false, code = "readiness_pending", message = "The execution-host readiness operation is still pending; it was not repeated." }); return
	end
	if not setup_fields(input, if prepare then { "source_nonce", "request_id" } else { "source_nonce", "request_id", "orch_project_id" }) then return end
	view.readiness_pending = input.request_id
	local function live(): boolean return contexts[view.pane] ~= nil and contexts[view.pane].view == view and view.readiness_pending == input.request_id end
	local function done(response: any)
		if not live() then return end
		view.readiness_pending = nil
		setup_result(view, input, response)
	end
	if not prepare then
		local project = if authority.registry and authority.registry.dispatch then authority.registry.dispatch.projects[input.orch_project_id] else nil
		local repository = if project then project.repository else nil
		local owned = view.readiness_repository
		if not project or project.logical_session_id ~= view.orch_session_id or not repository or not owned
			or repository.cwd ~= owned.cwd or repository.repo_root ~= owned.repo_root or repository.common_dir ~= owned.common_dir
			or repository.target_ref ~= "refs/heads/main" then
			done({ ok = false, code = "readiness_unowned", message = "Only this host-created readiness checkout can be verified here." }); return
		end
		local ok = pcall(function()
			tern.process.run({ "git", "-C", owned.cwd, "show", "refs/heads/main:readiness.txt" }, { timeout_ms = 10000 }, function(result: any)
				if not live() then return end
				local current = if authority.registry and authority.registry.dispatch then authority.registry.dispatch.projects[input.orch_project_id] else nil
				local matched = current and same_value(current.repository, repository, 0)
				local passed = matched and result.status == 0 and not result.timed_out and not result.truncated
					and not result.stdout_truncated and type(result.stdout) == "string" and result.stdout:match("^ready%s*$") ~= nil
				done({ ok = passed == true, readiness_passed = passed == true, code = if passed then "readiness_passed" else "readiness_failed",
					message = if passed then "The execution-host target contains the real readiness artifact." else "The readiness target readback or project association did not match." })
			end)
		end)
		if not ok then done({ ok = false, code = "readiness_unavailable", message = "Execution-host Git readback could not start." }) end
		return
	end
	local path = tern.plugin.data .. "/readiness-" .. nonce()
	local made = pcall(tern.fs.mkdir, path)
	if not made then done({ ok = false, code = "readiness_unavailable", message = "The host-private readiness directory could not be created." }); return end
	local steps = {
		{ "git", "init", "--initial-branch=main", path },
		{ "git", "-C", path, "config", "--local", "user.name", "ORCH readiness" },
		{ "git", "-C", path, "config", "--local", "user.email", "orch-readiness@localhost" },
		{ "git", "-C", path, "-c", "user.name=ORCH readiness", "-c", "user.email=orch-readiness@localhost", "commit", "--allow-empty", "-m", "Readiness baseline" },
	}
	local function step(index: number)
		if not live() then return end
		if not steps[index] then
			probe_repository(view, { source_nonce = view.alias_nonce, request_id = input.request_id, cwd = path, target_ref = "refs/heads/main" }, function(response: any)
				if response.ok then view.readiness_repository = response.repository end
				done(response)
			end)
			return
		end
		local ok = pcall(function()
			tern.process.run(steps[index], { timeout_ms = 10000 }, function(result: any)
				if not live() then return end
				if result.status ~= 0 or result.timed_out or result.truncated or result.stdout_truncated then
					done({ ok = false, code = "readiness_unavailable", message = "The fixed execution-host Git preparation failed; its private directory is retained." }); return
				end
				step(index + 1)
			end)
		end)
		if not ok then done({ ok = false, code = "readiness_unavailable", message = "Execution-host Git preparation could not start." }) end
	end
	step(1)
end

local function setup_command(view: any, input: any)
	if input.setup_origin ~= nil and not setup_origin(input.setup_origin, view) then
		setup_result(view, input, { ok = false, code = "invalid_origin", message = "Setup origin does not identify this native host view." }); return
	end
	if input.kind == "catalog_request" then
		local request = input.request
		if not setup_fields(input, { "kind", "source_nonce", "request_id", "request", "expected_revision", "authority_namespace", "expected_config_revision", "setup_origin" })
			or not setup_fields(request, { "schema", "origin", "op", "request_id", "action_id", "setup_origin", "cursor" })
			or request.schema ~= 2 or request.origin ~= "orchplus" or request.op ~= "catalog"
			or not bounded_text(request.request_id, 128) or not bounded_text(request.action_id, 128)
			or not setup_origin(request.setup_origin, view)
			or (input.setup_origin ~= nil and not same_value(input.setup_origin, request.setup_origin, 0))
			or (request.cursor ~= nil and not setup_catalog_cursor(request.cursor)) then
			setup_result(view, input, { ok = false, code = "invalid_catalog_request", message = "Setup catalog requires the exact live native view origin." }); return
		end
		view.setup_catalog_request = request
		setup_result(view, input, { ok = true, code = "catalog_requested" })
		return
	elseif input.kind == "catalog_clear" then
		if not setup_fields(input, { "kind", "source_nonce", "request_id", "expected_revision", "authority_namespace", "expected_config_revision", "setup_origin" }) then return end
		view.setup_catalog_request = nil
		setup_result(view, input, { ok = true, code = "catalog_cleared" })
		return
	end
	if input.kind ~= "installation_defaults" and input.kind ~= "setup_lifecycle" then return end
	local event = table.clone(input); event.source_nonce = nil; event.setup_origin = nil
	setup_result(view, input, authority:apply(event))
end
-- Native document intents share the authority transaction. Only this host supplies B0/B1 and
-- filesystem/native-incarnation proof; window buffers are observations, never durable confirmation.
local native_executable: string? = nil
local function native_clients(done: (any?, string?) -> ())
	local function inspect(path: string)
		local env = { TERN_PANE = "", TERN_PANE_SOCKET = "", TERN_WINDOW_KEY = "", TERN_WINDOW_SOCKET = "" }
		local socket = tern.getenv("TERN_DAEMON_SOCKET")
		if tern.runtime.os == "linux" then
			local ok, bytes = pcall(tern.fs.read, "/proc/self/cmdline", 32768)
			if ok then
				local take = false
				for word in bytes:gmatch("[^%z]+") do
					if take then socket = word; break end
					if word == "--socket" then take = true
					elseif word:sub(1, 9) == "--socket=" then socket = word:sub(10); break end
				end
			end
		end
		if socket then env.TERN_DAEMON_SOCKET = socket end
		tern.process.run({ path, "inspect", "--json" }, { timeout_ms = 5000, env = env }, function(result: any)
			if result.status ~= 0 or result.timed_out or result.truncated or result.stdout_truncated
				or type(result.stdout) ~= "string" or #result.stdout > 2000000 then done(nil, "Complete native client inspection is unavailable."); return end
			local ok, value = pcall(tern.json.decode, result.stdout)
			if not ok or type(value) ~= "table" or type(value.clients) ~= "table" or value.complete == false or value.truncated == true then
				done(nil, "Native client inventory is incomplete."); return
			end
			local count = 0
			for index, client in value.clients do
				count += 1
				if type(index) ~= "number" or index % 1 ~= 0 or index < 1 or index > #value.clients or type(client) ~= "table" then
					done(nil, "Native client inventory is not a complete array."); return
				end
			end
			if count ~= #value.clients then done(nil, "Native client inventory has holes."); return end
			done(value.clients, nil)
		end)
	end
	if native_executable then inspect(native_executable); return end
	local argv, why = discovery.argv(tern.runtime.os, tern.getenv("SystemRoot") or tern.getenv("WINDIR"))
	if not argv then done(nil, tostring(why)); return end
	tern.process.run(argv, { timeout_ms = 5000 }, function(result: any)
		if result.status ~= 0 or result.timed_out then done(nil, "Native executable discovery failed."); return end
		local path, failure = discovery.path(result.stdout)
		if not path then done(nil, tostring(failure)); return end
		native_executable = path
		inspect(path)
	end)
end
local function existing_document(path: string, done: (boolean) -> ())
	if not rulings.absolute(path) or path:find("[/\\]%.%.?[/\\]") or path:find("[/\\]%.%.?$")
		or (tern.runtime.os ~= "windows" and path:find("//", 1, true)) then done(false); return end
	local argv
	if tern.runtime.os == "windows" then
		local root = tern.getenv("SystemRoot") or tern.getenv("WINDIR")
		if not root then done(false); return end
		argv = { root .. "\\System32\\WindowsPowerShell\\v1.0\\powershell.exe", "-NoProfile", "-NonInteractive", "-Command",
			"$ErrorActionPreference='Stop'; $p=$env:ORCHPLUS_DOCUMENT_PATH; $i=Get-Item -LiteralPath $p -Force; if($i.PSIsContainer -or $i.LinkType -or [IO.Path]::GetFullPath($p) -cne $i.FullName){exit 1}; if(($i.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0){exit 1}; $i=$i.Directory; while($i){if(($i.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0){exit 1}; $i=$i.Parent}; exit 0" }
	else
		argv = { "/bin/sh", "-c", "p=$1; [ \"$(find \"$p\" -prune -type f -links 1 -print)\" = \"$p\" ] || exit 1; while [ \"$p\" != / ]; do [ ! -L \"$p\" ] || exit 1; p=${p%/*}; [ -n \"$p\" ] || p=/; done", "orchplus-existing-document", path }
	end
	tern.process.run(argv, { timeout_ms = 5000, env = if tern.runtime.os == "windows" then { ORCHPLUS_DOCUMENT_PATH = path } else nil },
		function(result: any) done(result.status == 0 and not result.timed_out) end)
end
local function ruling_command(view: any, input: any)
	local origin = input.origin
	if not dispatch.origin(origin) or origin.host_pane_id ~= tostring(view.pane) or origin.alias_nonce ~= view.alias_nonce
		or origin.logical_session_id ~= view.orch_session_id or type(input.request_id) ~= "string" then return end
	local function result(value: any)
		value.request_id = input.request_id
		view.ruling_result = value; view.notice = tostring(value.message or value.code)
		render_all()
	end
	local function refused(code: string, message: string) result({ ok = false, code = code, message = message }) end
	local session = session_for(view)
	local owner = if session then session.controller else nil
	if not owner or owner.owner_id ~= origin.owner_id or owner.generation ~= origin.owner_generation or owner.phase ~= "active" then return end
	local d = authority.registry.dispatch
	local gate = if d and input.gate_id then d.gates[input.gate_id] else nil
	local obligation = if gate then gate.ruling else nil
	local associate = input.command == "associate_document"
	local work = if d and input.worker_id then d.workers[input.worker_id] else nil
	local path = if associate then input.path elseif obligation then obligation.path else nil
	if not path or not rulings.absolute(path) or (associate and (not work or work.logical_session_id ~= view.orch_session_id))
		or (not associate and (not gate or gate.revision ~= input.gate_revision or not obligation)) then
		refused("ruling_unavailable", "The selected existing-document association or gate changed."); return
	end
	if not table.find({ "ruling_inspect", "ruling_prepare", "ruling_observe", "ruling_reissue", "ruling_remote", "associate_document" }, input.command) then return end
	if associate then
		existing_document(path, function(existing: boolean)
			local readable = if existing then pcall(tern.fs.read, path, codec.LIMITS.logical) else false
			if not readable then refused("document_missing", "The selected host document must already exist, be unaliased, and be readable."); return end
			result(authority:apply({ kind = "dispatch", command = "associate_document", request_id = input.request_id,
				orch_session_id = origin.logical_session_id, origin = origin, controller_pane = tostring(view.pane),
				authority_namespace = input.authority_namespace, expected_revision = input.expected_revision, command_seq = input.command_seq,
				worker_id = input.worker_id, path = path, evidence = { existing = true } }))
		end)
		return
	end
	local function inspected(clients: any, why: string?)
		if not clients then refused("writer_unproved", why or "Native writer unavailable."); return end
		local writer = if input.writer and input.writer.kind == "worker" then input.writer else nil
		local previous = if obligation and obligation.intent then obligation.intent.writer else nil
		if input.writer_ended_verified == true or input.no_late_write_verified == true or input.command == "ruling_reissue" then
			if not previous or not rulings.same_writer(input.previous_writer, previous) then
				refused("writer_unproved", "The ended-writer proof must name the exact original intent incarnation."); return
			end
		end
		local previous_alive = previous ~= nil and previous.kind == "worker"
		if previous and previous.kind == "worker" then
			local old = d.workers[previous.worker_id]
			if old and old.worker_generation == previous.worker_generation and old.stopped
				and table.find({ "absent", "exited" }, old.stopped.observation) and input.operator_verified == true then
				previous_alive = false
				for _, pending in d.actions do if pending.worker_id == old.worker_id then previous_alive = true end end
			end
		end
		for _, client in clients do
			if (not input.writer or input.writer.kind ~= "worker") and client.kind == "window" and client.window == origin.window_key then
				local candidate = { kind = "window", window_key = client.window, conn = client.conn, since = client.since }
				if writer or not rulings.valid_writer(candidate) then refused("writer_unproved", "Native window incarnation is ambiguous."); return end
				writer = candidate
			end
			if previous and previous.kind == "window" and client.kind == "window" and client.window == previous.window_key
				and client.conn == previous.conn and client.since == previous.since then previous_alive = true end
		end
		if not writer then refused("writer_unproved", "The exact native window is no longer connected."); return end
		if input.writer and input.writer.kind == "window" and not rulings.same_writer(input.writer, writer) then
			refused("writer_unproved", "Window incarnation changed; the previous write remains unresolved."); return
		end
		existing_document(path, function(existing: boolean)
			if not existing then refused("document_missing", "Existing regular document identity is unproved (missing, aliased, linked or inaccessible)."); return end
			if input.command == "ruling_inspect" then result({ ok = true, code = "ruling_inspected", writer = writer, path = path }); return end
			local ok, bytes = pcall(tern.fs.read, path, codec.LIMITS.logical)
			if not ok then refused("document_missing", "Host cannot read the existing document within the native bound."); return end
			local remote_attested = input.writer and input.writer.kind == "worker" and input.remote_buffer_attested == true
				and input.operator_verified == true
			local evidence = { disk_bytes = bytes, buffer_bytes = input.buffer_bytes,
				buffer_observed = if input.writer and input.writer.kind == "worker" then remote_attested else input.buffer_observed == true,
				buffer_attestation = if remote_attested then "owner_verified_remote_single_writer_no_dirty_buffer" else nil,
				existing = true, identity_proven = true, same_machine = input.same_machine == true, quiescent = input.operator_verified == true,
				previous_writer = if previous then table.clone(previous) else nil,
				writer_ended = previous ~= nil and not previous_alive and input.writer_ended_verified == true,
				no_write_can_complete = previous ~= nil and not previous_alive and input.writer_ended_verified == true and input.no_late_write_verified == true }
			for _, candidate in d.workers do
				local associated = rulings.association(candidate, d.plans)
				if associated == path and candidate.phase ~= "retired" and not candidate.stopped and candidate.mailbox_handle then
					local preferred = { kind = "worker", worker_id = candidate.worker_id, worker_generation = candidate.worker_generation }
					if evidence.preferred_worker and not rulings.same_writer(evidence.preferred_worker, preferred) then
						refused("writer_unproved", "Several live workers may own this document; settle ownership first."); return
					end
					evidence.preferred_worker = preferred
				end
			end
			local selected = input.writer or writer
			if selected.kind == "worker" and input.command ~= "ruling_observe" and input.command ~= "ruling_reissue"
				and (not evidence.preferred_worker or not rulings.same_writer(selected, evidence.preferred_worker)) then
				refused("writer_unproved", "Use the existing document-owning authorized worker."); return
			end
			local event = { kind = "dispatch", command = input.command, request_id = input.request_id, orch_session_id = origin.logical_session_id,
				origin = origin, controller_pane = tostring(view.pane), authority_namespace = input.authority_namespace, expected_revision = input.expected_revision,
				command_seq = input.command_seq }
			event.gate_id = input.gate_id; event.gate_revision = input.gate_revision
			if input.command == "ruling_remote" then event.worker_id = selected.worker_id
			else event.writer = selected; event.evidence = evidence end
			result(authority:apply(event))
		end)
	end
	if input.writer and input.writer.kind == "worker" then
		if not rulings.valid_writer(input.writer) then return end
		inspected({}, nil)
	else native_clients(inspected) end
end
local function discover_sources(view: any, input: any)
	local io = { read = tern.fs.read, decode = tern.json.decode, encode = tern.json.encode }
	local projection = if authority.registry and view.orch_session_id then dispatch.project(authority.registry, view.orch_session_id, view.alias_nonce) else nil
	local policy = if projection and projection.workflow then projection.workflow.policy else nil
	local result: any = { ok = true, request_id = input.request_id, projects = {}, plans = {}, templates = if policy then policy.templates else {} }
	if input.work_selection ~= nil then
		local selected = input.work_selection
		result.templates = {}
		if not policy or not policy.glitch_integration or not policy.work_on_enabled
			or not setup_fields(selected, { "workspace_id", "workspace_path", "glitch_root", "source_kind", "source_locator" }) then
			result = { ok = false, code = "work_unavailable", message = "Enable Glitch integration and Work On before choosing work." }
		else
			local catalog, failure = source_adapter.load_projects(selected.glitch_root, tern.runtime.os, io)
			local workspace = nil
			if catalog then for _, row in catalog.items do
				if row.id == selected.workspace_id and row.path == selected.workspace_path then workspace = row; break end
			end end
			if not workspace then result = failure or { ok = false, code = "workspace_changed", message = "That workspace is no longer active in WORK. Select a current workspace." }
			elseif selected.source_kind == "workspace" and selected.source_locator == workspace.path then
				result.work_selection = { kind = "context", workspace_id = workspace.id, name = workspace.name,
					path = workspace.path, revision = codec.sha256(tern.json.encode(workspace)) }
			elseif selected.source_kind == "plan_file" and type(selected.source_locator) == "string" then
				local filename = selected.source_locator:match("^" .. catalog.root:gsub("([^%w])", "%%%1") .. "/plans/([^/\\]+%.md)$")
				local readable, bytes = false, nil
				if filename then readable, bytes = pcall(tern.fs.read, selected.source_locator, 1048576) end
				local discovered = if readable then source_adapter.discover_plans(catalog, { { name = filename, bytes = bytes } }) else nil
				local plan = if discovered then discovered.items[1] else nil
				if not plan or plan.workspace_id ~= workspace.id then
					result = { ok = false, code = "work_source_changed", message = "The selected plan is unavailable, archived or belongs to another workspace. Choose it again in WORK." }
				else result.work_selection = { kind = "plan_file", path = plan.path, revision = plan.revision } end
			else result = { ok = false, code = "work_source_invalid", message = "WORK returned no current workspace or supported plan." } end
		end
	elseif input.path ~= nil then
		result.templates = {}
		local source, failure = source_adapter.read_plan(input.path, input.revision, io)
		if not source then result = failure
		elseif input.metadata_only == true then
			result.source = { kind = source.kind, path = source.path, revision = source.revision, plan = { title = source.plan.title } }
		elseif input.offset ~= nil then
			local offset = input.offset
			local bytes = tern.json.encode(source)
			if type(offset) ~= "number" or offset < 0 or offset % 1 ~= 0 or offset >= #bytes
				or (offset > 0 and input.revision == nil) then
				result = { ok = false, code = "source_page_invalid", message = "Read source pages in order at the pinned source revision." }
			else
				local last = math.min(offset + 16000, #bytes)
				while last < #bytes and bytes:byte(last + 1) >= 128 and bytes:byte(last + 1) < 192 do last -= 1 end
				local chunk = bytes:sub(offset + 1, last)
				if utf8.len(chunk) == nil then result = { ok = false, code = "source_page_invalid", message = "Source page offset must preserve UTF-8 boundaries." }
				else result.source_page = { path = source.path, revision = source.revision, offset = offset, bytes = chunk,
					next_offset = if last < #bytes then last else nil, total_bytes = #bytes, sha256 = codec.sha256(bytes) } end
			end
		else result.source = source end
	end
	result.request_id = input.request_id
	result.templates = result.templates or (if policy then policy.templates else {}) or {}
	local plans = {}
	for _, row in result.plans or {} do table.insert(plans, row.plan) end
	result.classes = source_adapter.class_choices(plans, result.templates)
	-- Discovery lists are metadata, not copies of every full parsed workflow. Explicit path
	-- paging above makes all supported plan contents available without growing a frame.
	for _, row in result.plans or {} do row.plan = { title = row.plan.title } end
	local ok, encoded = pcall(tern.json.encode, result)
	if ok and input.path == nil and input.offset ~= nil and result.ok then
		-- Correlation is outside the pinned discovery bytes: each page has a fresh request id.
		local request_id = result.request_id
		result.request_id = nil
		encoded = tern.json.encode(result)
		local revision, offset = codec.sha256(encoded), input.offset
		if type(offset) ~= "number" or offset < 0 or offset % 1 ~= 0 or offset >= #encoded
			or (offset > 0 and input.revision ~= revision) then
			result = { ok = false, request_id = request_id, code = "source_revision_changed", message = "Discovery changed. Read a new complete catalog before choosing work." }
		else
			local last = math.min(offset + 16000, #encoded)
			while last < #encoded and encoded:byte(last + 1) >= 128 and encoded:byte(last + 1) < 192 do last -= 1 end
			local chunk = encoded:sub(offset + 1, last)
			if utf8.len(chunk) == nil then result = { ok = false, request_id = request_id, code = "source_page_invalid", message = "Invalid discovery page boundary." }
			else result = { ok = true, request_id = request_id, discovery_page = { revision = revision, sha256 = revision,
				offset = offset, bytes = chunk, next_offset = if last < #encoded then last else nil, total_bytes = #encoded } } end
		end
		ok, encoded = pcall(tern.json.encode, result)
	end
	if not ok or #encoded > codec.LIMITS.logical then result = { ok = false, request_id = input.request_id, code = "source_too_large", message = "Read this supported source through bounded source-discover pages starting at offset 0." } end
	view.source_discovery = result
	render_all()
end
local function discover_repository(view: any, input: any)
	if not setup_fields(input, { "source_nonce", "request_id", "orch_project_id", "cwd", "cwd_candidates" })
		or not bounded_text(input.orch_project_id, 128) or type(input.cwd_candidates) ~= "table" or #input.cwd_candidates > 16 then return end
	if input.cwd ~= nil and input.cwd ~= "" and not source_adapter.normalize_root(input.cwd, tern.runtime.os) then
		setup_result(view, input, { ok = false, code = "repository_folder_required", message = "Choose an absolute project folder on the execution host." }); return
	end
	local projected = dispatch.project(authority.registry, view.orch_session_id, view.alias_nonce)
	local project = projected.projects[input.orch_project_id]
	if not project then setup_result(view, input, { ok = false, code = "project_changed", message = "Choose a current project." }); return end
	local folders, ranked, best = {}, {}, nil
	local function add(value: any, rank: number)
		local path = source_adapter.normalize_root(value, tern.runtime.os)
		if not path or #path > 512 then return end
		if ranked[path] then ranked[path] = math.min(ranked[path], rank); return end
		if #folders >= 32 then return end
		ranked[path] = rank; table.insert(folders, path)
		best = if best then math.min(best, rank) else rank
	end
	if input.cwd ~= nil and input.cwd ~= "" then add(input.cwd, 0)
	elseif project.repository then add(project.repository.cwd, 0) end
	for _, source in project.sources or {} do
		if source.kind == "manual" then add(source.ref, 1)
		elseif source.kind == "plan" and projected.workflow.policy.glitch_integration then
			local plan_path = source_adapter.normalize_root(source.ref, tern.runtime.os)
			local root: string?, filename: string?
			if plan_path then root, filename = plan_path:match("^(.*)/plans/([^/\\]+%.md)$") end
			if root then
				local io = { read = tern.fs.read, decode = tern.json.decode, encode = tern.json.encode }
				local catalog = source_adapter.load_projects(root, tern.runtime.os, io)
				local readable, bytes = pcall(tern.fs.read, plan_path, 1048576)
				local plans = if catalog and readable then source_adapter.discover_plans(catalog, { { name = filename, bytes = bytes } }) else nil
				local plan = if plans then plans.items[1] else nil
				if plan and (source.revision == nil or source.revision == plan.revision) and plan.workspace_id then
					for _, workspace in catalog.items do if workspace.id == plan.workspace_id then add(workspace.path, 1) end end
				end
			end
		end
	end
	for _, path in project.folder_candidates or {} do add(path, 2) end
	for _, path in input.cwd_candidates do add(path, 2) end
	local chosen, count = nil, 0
	for _, path in folders do if ranked[path] == best then chosen = path; count += 1 end end
	if count ~= 1 then
		setup_result(view, input, { ok = false, code = if count == 0 then "repository_folder_required" else "repository_folder_ambiguous",
			folders = folders, message = if count == 0 then "No code folder is recorded for this project. Text and research need no repository."
				else "This project has several known working-copy folders. Select the project folder; agent working copies remain separately tracked." })
		return
	end
	read_repository_refs(view, { request_id = input.request_id, cwd = chosen }, function(refs: any, problem: string?)
		setup_result(view, input, { ok = refs ~= nil, code = if refs then "repository_discovered" else "repository_not_found",
			cwd = chosen, folders = folders, branches = if refs then refs.branches else {}, default_ref = if refs then refs.default_ref else nil,
			branches_clipped = if refs then refs.branches_clipped else false,
			message = problem or (if refs then refs.message else nil) })
	end)
end

local function archive_upgrade(original: any): boolean
	local bytes = tern.json.encode(original)
	local directory = tern.plugin.data .. "/upgrade-evidence"
	tern.fs.mkdir(directory)
	local path = directory .. "/v4-" .. codec.sha256(bytes) .. ".json"
	if tern.fs.exists(path) then return tern.fs.read(path, MAX_AUTHORITY_BYTES) == bytes end
	tern.fs.write(path, bytes)
	return tern.fs.read(path, MAX_AUTHORITY_BYTES) == bytes
end

-- The carrier grants no authority. Native receive capabilities stay outside saved view state.
local relay: any = { endpoint = nil, error = nil, views = {}, sequence = 0, unresolved = {} }
local RELAY_CALLBACKS = { ["spawn.setup_catalog"] = true, ["spawn.authorize"] = true, ["spawn.control_authorize"] = true,
	["spawn.claim"] = true, ["spawn.begin"] = true, ["spawn.result"] = true, ["spawn.wakeclaim"] = true,
	["spawn.wakebegin"] = true, ["spawn.wakeresult"] = true, ["spawn.wakedefer"] = true, ["spawn.migration"] = true }
local RELAY_ROUTES = { ["spawn.response"] = "response", ["spawn.execution"] = "execution", ["spawn.current"] = "current",
	["spawn.control"] = "control", ["spawn.catalog"] = "catalog" }
local function relay_token(value: any, maximum: number): boolean
	return type(value) == "string" and #value > 0 and #value <= maximum and value:match("^[A-Za-z0-9_.%-]+$") ~= nil
end
function relay.failure(view: any, code: string, lane: any?)
	local global_code = if next(relay.unresolved) ~= nil then "unreconciled_peer_result" else code
	local changed = view.spawn_relay.error ~= global_code or (lane and lane.error ~= code)
	if lane then lane.error, lane.held = code, true end
	view.spawn_relay.held, view.spawn_relay.error = true, global_code
	view.relay_notice = "Orchestration connection is held (" .. global_code .. "). Inspect the connection before continuing; no action was retried."
	local context = contexts[view.pane]
	if changed and not handling_event and context and context.view == view then context.cx:render() end
end
function relay.attach(view: any)
	if not relay.endpoint and not relay.error then
		relay.endpoint, relay.error = Channel.open({ plugin_id = "orchplus", plugin_data = tern.plugin.data, incarnation = boot,
			fs = tern.fs, json = tern.json, base64 = tern.base64 })
	end
	relay.sequence += 1
	local id = string.format("r-%08x-%x", math.random(1, 2147483647), relay.sequence)
	view.spawn_relay = { schema = 1, peer = "spawn", host_pane_id = tostring(view.pane), source_nonce = view.alias_nonce,
		relay_endpoint = id, relay_boot = boot, lanes = {}, releases = {} }
	view.usage_relay = { schema = 1, peer = "usage", host_pane_id = tostring(view.pane), source_nonce = view.alias_nonce,
		relay_endpoint = id, relay_boot = boot }
	view.spawn_relay_frames, view.usage_relay_frames = {}, {}
	relay.views[id] = { view = view, lanes = {}, reads = {}, releases = {} }
	if relay.error then relay.failure(view, relay.error.code) end
	if next(relay.unresolved) ~= nil then relay.failure(view, "unreconciled_peer_result") end
end
function relay.native(view: any): boolean
	if contexts[view.pane] == nil or contexts[view.pane].view ~= view then return false end
	for _, pane in tern.pane.list() do
		if pane.pane == view.pane and pane.program == "orchplus.orchestrator" then return true end
	end
	return false
end
function relay.source(view: any, origin: any): any?
	if not relay.native(view) or type(origin) ~= "table" or origin.host_pane_id ~= tostring(view.pane) then return nil end
	if dispatch.origin(origin) then
		if origin.alias_nonce ~= view.alias_nonce or origin.logical_session_id ~= view.orch_session_id then return nil end
		local session = session_for(view)
		local owner = if session then session.controller else nil
		local closing = if session and session.close then session.close.control_origin else nil
		if not (owner and owner.owner_id == origin.owner_id and owner.generation == origin.owner_generation
			and owner.pane_binding and owner.pane_binding.alias_nonce == view.alias_nonce)
			and not (closing and same_value(closing.binding, origin, 0)) then return nil end
	elseif not codec.validate_dispatch_setup_origin(origin) then return nil end
	return { schema = 1, relay_endpoint = view.spawn_relay.relay_endpoint, relay_boot = boot, host_pane_id = tostring(view.pane),
		source_nonce = view.alias_nonce, origin = origin, desktop_proof = "delegated_native_window", host_program = "orchplus.orchestrator" }
end
function relay.send(view: any, lane: any, peer: string, route: string, binding_value: string, act: string, bytes: string, execution_proof: any?): boolean
	local previous = lane.sent[act]
	if previous and previous.bytes == bytes and previous.binding == binding_value then return true end
	if RELAY_CALLBACKS[act] then
		local proof = execution_proof
		local current = lane.metadata.messages.execution
		local retained = if current then lane.received[current.incarnation .. ":" .. current.id] else nil
		if not setup_fields(proof, { "id", "incarnation" }) or not current or proof.id ~= current.id
			or proof.incarnation ~= current.incarnation or not retained or retained.acked or retained.consumed
			or retained.message.body == "" then
			view.relay_notice = "A native callback did not match the current execution receipt; it was not forwarded."
			return false
		end
	end
	if not relay.endpoint then relay.failure(view, "channel_unavailable", lane.metadata); return false end
	lane.pending = lane.pending or {}
	local attempt = lane.pending[act]
	if attempt and (attempt.bytes ~= bytes or attempt.binding ~= binding_value) then
		relay.failure(view, "pending_send_conflict", lane.metadata); return false
	end
	if not attempt then
		relay.sequence += 1
		attempt = { bytes = bytes, binding = binding_value, id = "m-" .. tostring(relay.sequence) }
		lane.pending[act] = attempt
	end
	local receipt, failure = relay.endpoint.send({ peer = peer, route = route, binding = binding_value,
		id = attempt.id, body = bytes, priority = if RELAY_CALLBACKS[act] or act == "release" then "settlement" else nil })
	if not receipt then
		if peer == "usage" and lane.usage_kind == "display" and failure.code == "backpressure" then
			relay.usage_failure(view, "display", failure.code)
		else relay.failure(view, failure.code, lane.metadata) end
		return false
	end
	lane.sent[act], lane.pending[act] = attempt, nil
	return true
end
function relay.disposed(message: any)
	local key = message.incarnation .. ":" .. message.id
	if not relay.unresolved[key] then return end
	relay.unresolved[key] = nil
	if next(relay.unresolved) ~= nil then return end
	for _, entry in relay.views do
		local view = entry.view
		if view.spawn_relay.error == "unreconciled_peer_result" then
			local held_code
			for _, lane in view.spawn_relay.lanes do if lane.held then held_code = lane.error or "relay_held"; break end end
			if held_code then relay.failure(view, held_code)
			else
				view.spawn_relay.held, view.spawn_relay.error = nil, nil
				view.relay_notice = "The connection response is accounted for. Existing work and uncertain outcomes are unchanged."
				if not handling_event and contexts[view.pane] then contexts[view.pane].cx:render() end
			end
		end
	end
end
function relay.ack(view: any, retained: any): boolean
	if retained.acked then return true end
	local ok, failure = relay.endpoint.ack(retained.message)
	if not ok then relay.failure(view, failure.code); return false end
	retained.acked = true
	relay.disposed(retained.message)
	return true
end
function relay.response_body(bytes: any): any?
	-- Classification is not request adoption. Validate the complete frame and closed body
	-- before deciding whether an unbound/stale response is an observation or an effect.
	-- The correlated decoder below still requires the real retained request for effects.
	if type(bytes) ~= "string" or #bytes > codec.LIMITS.bridge_status or bytes:sub(1, #codec.DISPATCH.prefix) ~= codec.DISPATCH.prefix then return nil end
	local frame = codec.strict_decode(bytes:sub(#codec.DISPATCH.prefix + 1), codec.LIMITS.bridge_status)
	if not setup_fields(frame, { "schema", "op", "request_id", "complete", "body_bytes", "body_sha256", "body_json" })
		or frame.schema ~= 2 or frame.complete ~= true or type(frame.body_json) ~= "string"
		or frame.body_bytes ~= #frame.body_json or frame.body_sha256 ~= codec.sha256(frame.body_json) then return nil end
	local limit = if frame.op == "status" then codec.LIMITS.bridge_status else codec.DISPATCH.limit
	if #bytes > limit then return nil end
	local body, problem, shapes = codec.strict_decode(frame.body_json, limit)
	if problem or not codec.validate_dispatch_response_body(body, shapes)
		or body.op ~= frame.op or body.request_id ~= frame.request_id then return nil end
	return body
end
function relay.consumed_result(body: any, registry: any): boolean
	if not body or not registry or body.authority_namespace ~= registry.authority_namespace
		or not registry.compatibility or body.spawn_namespace ~= registry.compatibility.spawn_namespace
		or body.authority_revision > registry.revision or type(body.request_serial) ~= "number" then return false end
	local session = registry.sessions[body.logical_session_id]
	if not session or body.admission_seq ~= session.admission_seq
		or body.request_serial >= session.next_request_serial then return false end
	local floor, consumed = dispatch.ack_progress(registry, body.logical_session_id)
	return body.request_serial < floor or table.find(consumed, body.request_serial) ~= nil
end
function relay.observed_control(message: any): boolean
	if message.route ~= "spawn.response" then return false end
	local sequence = tonumber(message.id:match("^r%-(%d+)$"))
	if not sequence or sequence % 1 ~= 0 or sequence < 1 then return false end
	-- A committed current-route observation can settle its exact retained old control,
	-- even when that result names the preceding window's now-absent carrier binding.
	-- Proofs remain live-lane scoped; no completion history or effect adoption is added.
	for _, endpoint in relay.views do
		for _, lane in endpoint.lanes do
			local proof = lane.observed_control
			if proof and message.incarnation == proof.peer_boot and sequence < proof.sequence
				and codec.decode_dispatch_response(message.body, proof.request) ~= nil then return true end
		end
	end
	return false
end
-- The dedicated forget protocol has its own frame and closed schema. Its responses are read-only observations from the host's
-- point of view: classification never adopts a request, and a lost completion is recovered by an idempotent authenticated retry.
function relay.forget_body(bytes: any): any?
	if type(bytes) ~= "string" or #bytes > codec.FORGET.limit or bytes:sub(1, #codec.FORGET.prefix) ~= codec.FORGET.prefix then return nil end
	local body, problem = codec.strict_decode(bytes:sub(#codec.FORGET.prefix + 1), codec.FORGET.limit)
	if problem or not codec.validate_forget_response(body) then return nil end
	return body
end
local FORGET_ACTS = { discard_capability = true, discard_preview = true, discard_session = true }
function relay.retirable_projection(message: any): boolean
	-- Execution still needs the peer's exact consumption proof. Results can retire
	-- only as read-only observations or after durable domain consumption.
	if message.route == "spawn.execution" then return false end
	if message.body == "" or message.route == "spawn.current" then return true end
	if message.route ~= "spawn.response" then return false end
	if relay.forget_body(message.body) ~= nil then return true end
	local body = relay.response_body(message.body)
	if body ~= nil and table.find({ "catalog", "owner_status", "status", "mailbox_inventory", "mailbox_allocation" }, body.op) ~= nil then return true end
	if authority.status ~= "ready" or authority.uncommitted_observation
		or not (relay.consumed_result(body, authority.registry) or relay.observed_control(message)) then return false end
	local saved, current = pcall(tern.kv.get, STORE_KEY)
	return saved and same_value(current, authority.registry, 0)
end
function relay.reject(message: any, code: string, view: any?): boolean
	if view then
		local endpoint = relay.views[view.spawn_relay.relay_endpoint]
		local lane_id = message.binding:match("^[^:]+:([^:]+)$")
		local lane = if endpoint and lane_id then endpoint.lanes[lane_id] else nil
		relay.failure(view, code, if lane then lane.metadata else nil)
	end
	-- Rejecting an execution projection cannot retire its SPAWN claim. It is never
	-- published here. An effect RESULT additionally needs an independently retained
	-- exact ORCH obligation; no new outcome ledger or inferred completion is created.
	if message.route == "spawn.response" and message.body ~= "" then
		local body = relay.response_body(message.body)
		local readonly = relay.forget_body(message.body) ~= nil or body and table.find({ "catalog", "owner_status", "status", "mailbox_inventory", "mailbox_allocation" }, body.op)
		if not readonly then
			local registry = authority.registry
			local pending = if body and registry and registry.dispatch then registry.dispatch.actions[body.action_id] else nil
			local exact = if pending then codec.decode_dispatch_response(message.body, pending.request) else nil
			local saved, current = pcall(tern.kv.get, STORE_KEY)
			if (not exact and not relay.consumed_result(body, registry) and not relay.observed_control(message))
				or authority.status ~= "ready" or authority.uncommitted_observation
				or not saved or not same_value(current, registry, 0) then
				-- Only live, unacknowledged carrier identities; never an outcome ledger.
				relay.unresolved[message.incarnation .. ":" .. message.id] = true
				for _, entry in relay.views do
					relay.failure(entry.view, "unreconciled_peer_result")
				end
				return false
			end
		end
	end
	local ok, failure = relay.endpoint.ack(message)
	if not ok and view then relay.failure(view, failure.code) end
	if ok then relay.disposed(message) end
	return ok
end
function relay.promote_execution(view: any, lane_id: string, lane: any): boolean
	local current = lane.metadata.messages.execution
	local retained = if current then lane.received[current.incarnation .. ":" .. current.id] else nil
	if retained and not retained.acked and not retained.consumed and retained.message.body ~= "" then return false end
	local changed = false
	while true do
		local selected, selected_key
		for key, candidate in lane.received do
			if candidate.message.route == "spawn.execution" and candidate.message.incarnation == lane.metadata.peer_boot
				and not candidate.acked and not candidate.consumed
				and (not selected or candidate.sequence < selected.sequence) then selected, selected_key = candidate, key end
		end
		if not selected then return changed end
		local message = selected.message
		if selected.sequence <= (lane.sequences.execution or 0) then
			if not relay.reject(message, "superseded_peer_projection") then return changed end
			lane.received[selected_key] = nil
			continue
		end
		changed = changed or not current or current.id ~= message.id or current.incarnation ~= message.incarnation
		lane.metadata.messages.execution = { id = message.id, incarnation = message.incarnation, route = message.route, binding = message.binding }
		view.spawn_relay_frames[lane_id].execution = message.body
		if message.body ~= "" then lane.sequences.execution = selected.sequence; return changed end
		if not relay.ack(view, selected) then return changed end
		lane.sequences.execution = selected.sequence
		lane.received[selected_key] = nil
	end
end
function relay.migration_peer(view: any, input: any): boolean
	local proof = input.relay_proof
	if not setup_fields(proof, { "relay_endpoint", "lane_id", "peer_boot", "receipt" })
		or proof.relay_endpoint ~= view.spawn_relay.relay_endpoint or not relay_token(proof.lane_id, 24)
		or not setup_fields(proof.receipt, { "id", "incarnation" }) then return false end
	local endpoint = relay.views[proof.relay_endpoint]
	local lane = if endpoint and endpoint.view == view then endpoint.lanes[proof.lane_id] else nil
	if not lane or lane.metadata.held or proof.peer_boot ~= lane.metadata.peer_boot
		or proof.receipt.incarnation ~= proof.peer_boot or not relay.source(view, lane.source.origin)
		or not same_value(input.setup_origin, lane.source.origin, 0)
		or view.spawn_relay.held then return false end
	local current = lane.metadata.messages.current
	if not current or current.id ~= proof.receipt.id or current.incarnation ~= proof.receipt.incarnation
		or current.route ~= "spawn.current" or current.binding ~= proof.relay_endpoint .. ":" .. proof.lane_id then return false end
	local frames = view.spawn_relay_frames[proof.lane_id]
	local projection = if frames then codec.strict_decode(frames.current, 65536) else nil
	local result = if type(projection) == "table" then projection.migration_response else nil
	if not setup_fields(result, { "request_json", "operation", "response", "source" })
		or not table.find({ "source", "inspect", "prepare", "finish" }, result.operation)
		or not setup_fields(result.response, { "ok", "value" }) or result.response.ok ~= true
		or not setup_fields(result.response.value, { "proof", "selection", "compatibility" }) or type(result.source) ~= "table"
		or not codec.validate_dispatch_migration_qualification(result.source.qualification, "spawn")
		or not same_value(input.peer, result.source.qualification, 0) then return false end
	if not same_value(result.response.value.proof, result.source.qualification.proof, 0)
		or not same_value(result.response.value.selection, result.source.qualification.selection, 0) then return false end
	if projection.protocol ~= result.source.protocol or projection.phase ~= result.source.phase
		or projection.spawn_namespace ~= result.source.spawn_namespace
		or projection.authority_revision ~= result.source.authority_revision
		or not same_value(projection.qualification, result.source.qualification, 0) then return false end
	local request = codec.decode_dispatch_request(result.request_json)
	return request ~= nil and request.op == "catalog" and same_value(request.setup_origin, lane.source.origin, 0)
		and view.setup_catalog_request ~= nil and same_value(request, view.setup_catalog_request, 0)
end
function relay.creation_current(view: any, creation: any): boolean
	if not setup_fields(creation, { "request_id", "orch_session_id", "owner_id", "generation", "authority_namespace", "source_nonce" })
		or authority.status ~= "ready" or authority.uncommitted_observation then return false end
	local result, session = view.orchestration_result, session_for(view)
	local owner = if session then session.controller else nil
	if not result or result.ok ~= true or result.code ~= "controller_granted" or not owner
		or creation.authority_namespace ~= authority.registry.authority_namespace or creation.source_nonce ~= view.alias_nonce
		or creation.orch_session_id ~= view.orch_session_id or result.request_id ~= creation.request_id
		or result.orch_session_id ~= creation.orch_session_id or result.owner_id ~= creation.owner_id
		or result.generation ~= creation.generation or owner.owner_id ~= creation.owner_id or owner.generation ~= creation.generation
		or owner.phase ~= "active" or owner.owner_active ~= true or not same_value(owner.pane_binding, binding(view), 0)
		or session.phase ~= "open" or session.admitted ~= nil then return false end
	local ok, current = pcall(tern.kv.get, STORE_KEY)
	return ok and same_value(current, authority.registry, 0)
end
function relay.spawn_event(view: any, input: any)
	if not setup_fields(input, { "schema", "source_nonce", "relay_endpoint", "relay_boot", "lane_id", "peer_boot", "act", "bytes" })
		or input.schema ~= 1 or input.source_nonce ~= view.alias_nonce or input.relay_endpoint ~= view.spawn_relay.relay_endpoint
		or input.relay_boot ~= boot or not relay_token(input.lane_id, 24) or type(input.bytes) ~= "string" or #input.bytes > 65536 then return end
	local endpoint = relay.views[input.relay_endpoint]
	if input.act == "release_ack" then
		local receipt = endpoint.releases[input.lane_id]
		if input.bytes ~= "{}" or not receipt or input.peer_boot ~= receipt.peer_boot or not relay.native(view)
			or receipt.source.source_nonce ~= view.alias_nonce or receipt.source.host_pane_id ~= tostring(view.pane)
			or receipt.source.relay_endpoint ~= input.relay_endpoint or receipt.source.relay_boot ~= boot then return end
		for index, retained in view.spawn_relay.releases do
			if retained.lane_id == input.lane_id and retained.peer_boot == input.peer_boot then table.remove(view.spawn_relay.releases, index); break end
		end
		endpoint.releases[input.lane_id] = nil
		return
	end
	local lane = endpoint.lanes[input.lane_id]
	if input.act == "bind" or input.act == "rebind" then
		if endpoint.releases[input.lane_id] then relay.failure(view, "release_receipt_pending"); return end
		local origin = codec.strict_decode(input.bytes, 65536)
		local source = relay.source(view, origin)
		if not source then relay.failure(view, "source_unverified"); return end
		source.lane_id = input.lane_id
		if lane and not same_value(lane.source, source, 0) then relay.failure(view, "binding_changed", lane.metadata); return end
		if input.act == "rebind" then
			if not lane then relay.failure(view, "binding_missing"); return end
			if not (lane.pending and lane.pending.bind) then
				if not lane.bind_answered then relay.failure(view, "bind_pending", lane.metadata); return end
				lane.sent.bind, lane.bind_answered, lane.metadata.peer_boot = nil, false, nil
				lane.metadata.bind_id = nil
				lane.metadata.messages, view.spawn_relay_frames[input.lane_id] = {}, {}
			end
		end
		if not lane then
			if #view.spawn_relay.lanes + #view.spawn_relay.releases >= 32 then relay.failure(view, "lane_backpressure"); return end
			local metadata = { lane_id = input.lane_id, messages = {} }
			lane = { source = source, metadata = metadata, sent = {}, received = {} }
			endpoint.lanes[input.lane_id] = lane
			table.insert(view.spawn_relay.lanes, metadata)
			view.spawn_relay_frames[input.lane_id] = {}
		end
		local previous = lane.sent.bind
		if relay.send(view, lane, "spawn", "spawn.request", input.relay_endpoint .. ":" .. input.lane_id .. ":bind", "bind", tern.json.encode(source))
			and lane.sent.bind ~= previous then lane.bind_answered = false end
		return
	end
	if not lane or not relay.native(view) or input.peer_boot ~= lane.metadata.peer_boot then
		relay.failure(view, "stale_relay"); return
	end
	if input.act == "ack" then
		local proof = codec.strict_decode(input.bytes, 8192)
		if not setup_fields(proof, { "route", "id", "incarnation" }) or proof.route == "spawn.execution" then return end
		if not relay_token(proof.id, 80) or not relay_token(proof.incarnation, 80) then return end
		local key = proof.incarnation .. ":" .. proof.id
		local retained = lane.received[key]
		if retained and retained.message.route == "spawn.response" and retained.message.body ~= "" then
			local response = relay.response_body(retained.message.body)
			if relay.forget_body(retained.message.body) == nil and (not response or not table.find({ "catalog", "owner_status", "status", "mailbox_inventory", "mailbox_allocation" }, response.op)) then return end
		end
		if retained and retained.message.route == proof.route and retained.message.incarnation == proof.incarnation
			and relay.ack(view, retained) then lane.received[key] = nil end
		return
	end
	if not relay.source(view, lane.source.origin) then relay.failure(view, "source_changed", lane.metadata); return end
	if not relay_token(input.peer_boot, 64) or type(input.act) ~= "string" then return end
	local execution_proof
	if input.act == "release" then
		if input.bytes ~= "{}" then return end
		lane.release_requested = true
	else
		local request, migration
		if RELAY_CALLBACKS[input.act] then
			local callback = codec.strict_decode(input.bytes, 65536)
			if type(callback) ~= "table" or type(callback.request_json) ~= "string" then return end
			request = codec.decode_dispatch_request(callback.request_json)
			execution_proof = callback.relay_execution
		elseif input.act == "migration" then
			migration = codec.strict_decode(input.bytes, 65536)
			if not setup_fields(migration, { "schema", "request_json", "operation", "expected", "peer", "creation" })
				or migration.schema ~= 1 or not table.find({ "source", "bootstrap", "inspect", "prepare", "finish" }, migration.operation)
				or type(migration.request_json) ~= "string" then return end
			if migration.operation == "source" then
				if migration.expected ~= nil or migration.peer ~= nil or migration.creation ~= nil then return end
			elseif migration.operation == "bootstrap" then
				if migration.expected ~= nil or migration.peer ~= nil or not relay.creation_current(view, migration.creation) then return end
			elseif migration.creation ~= nil or type(migration.expected) ~= "table" or type(migration.peer) ~= "table" then return end
			request = codec.decode_dispatch_request(migration.request_json)
			if not request or request.op ~= "catalog" or not view.setup_catalog_request
				or not same_value(request, view.setup_catalog_request, 0)
				or not same_value(request.setup_origin, lane.source.origin, 0) then return end
		elseif FORGET_ACTS[input.act] then
			-- Own decoder end to end. The owner identity (without its window epoch) must be this lane's bound source.
			request = codec.decode_forget_request(input.bytes)
			local o = lane.source.origin
			if not request or request.op ~= input.act or request.logical_session_id ~= o.logical_session_id or request.controller_pane ~= lane.source.host_pane_id then return end
			for _, name in { "owner_id", "owner_generation", "host_pane_id", "alias_nonce", "window_key", "native_session_id", "window_host_id" } do
				if request.owner[name] ~= o[name] then relay.failure(view, "origin_changed", lane.metadata); return end
			end
			if input.act == "discard_session" and (next(relay.unresolved) ~= nil or view.spawn_relay.held or lane.metadata.held) then
				relay.failure(view, "relay_held", lane.metadata); return
			end
			local proof = ""
			if input.act == "discard_session" then
				-- The host, not the window, proves the exact bytes are the request this authority persisted for the session.
				local persisted = authority.registry and view.orch_session_id and authority.registry.sessions[view.orch_session_id]
				persisted = persisted and persisted.close and persisted.close.forget
				if not persisted or persisted.request_bytes ~= input.bytes then
					view.relay_notice = "Forgetting was not forwarded: its request is not the one this orchestration persisted."
					return
				end
				proof = ":" .. codec.sha256(input.bytes)
			end
			local sent = relay.send(view, lane, "spawn", "spawn.request", input.relay_endpoint .. ":" .. input.lane_id .. ":" .. input.act .. ":" .. input.peer_boot .. proof, input.act, input.bytes, nil)
			return
		else request = codec.decode_dispatch_request(input.bytes) end
		if not request or (not RELAY_CALLBACKS[input.act] and not migration and request.op ~= input.act) then return end
		if not RELAY_CALLBACKS[input.act] and ((migration and migration.operation ~= "source")
			or not table.find({ "catalog", "owner_status", "status", "mailbox_inventory", "mailbox_allocation" }, request.op))
			and (next(relay.unresolved) ~= nil or view.spawn_relay.held or lane.metadata.held) then
			relay.failure(view, "relay_held", lane.metadata); return
		end
		local origin = request.setup_origin or request.origin_binding or (if request.control_origin then request.control_origin.binding else nil)
		if not same_value(origin, lane.source.origin, 0) then relay.failure(view, "origin_changed", lane.metadata); return end
	end
	local sent = relay.send(view, lane, "spawn", "spawn.request", input.relay_endpoint .. ":" .. input.lane_id .. ":" .. input.act .. ":" .. input.peer_boot, input.act, input.bytes, execution_proof)
	if sent and input.act == "release" then lane.metadata.release_held = nil end
end
function relay.usage_failure(view: any, kind: string, code: string)
	if kind == "display" then
		view.usage_relay.display_error = code
	else relay.failure(view, code) end
end
function relay.usage_event(view: any, input: any)
	if not setup_fields(input, { "schema", "source_nonce", "relay_endpoint", "relay_boot", "kind", "act", "bytes" })
		or input.schema ~= 1 or input.source_nonce ~= view.alias_nonce or input.relay_endpoint ~= view.usage_relay.relay_endpoint
		or input.relay_boot ~= boot or (input.kind ~= "capacity" and input.kind ~= "display")
		or type(input.bytes) ~= "string" or #input.bytes > 65536 or not relay.native(view) then return end
	local endpoint = relay.views[input.relay_endpoint]
	local retained = endpoint.reads[input.kind]
	if input.act == "ack" then
		local proof = codec.strict_decode(input.bytes, 8192)
		if retained and retained.received and setup_fields(proof, { "route", "id", "incarnation" })
			and proof.id == retained.received.message.id and proof.route == retained.received.message.route
			and proof.incarnation == retained.received.message.incarnation then relay.ack(view, retained.received) end
		return
	end
	if input.act ~= "request" then return end
	local request = codec.strict_decode(input.bytes, 65536)
	if type(request) ~= "table" or request.version ~= 1 or not bounded_text(request.request_id, 128)
		or not table.find({ "snapshot", "page", "validate" }, request.op) then return end
	if retained and retained.request_id == request.request_id then
		if retained.bytes ~= input.bytes then relay.usage_failure(view, input.kind, "read_conflict") end
		return
	end
	if retained and not (retained.received and retained.received.acked) then relay.usage_failure(view, input.kind, "read_pending"); return end
	relay.sequence += 1
	local binding_value = input.relay_endpoint .. ":usage:" .. input.kind .. ":" .. tostring(relay.sequence)
	retained = { request_id = request.request_id, op = request.op, bytes = input.bytes, binding = binding_value, sent = {}, metadata = {},
		usage_kind = input.kind, source_nonce = view.alias_nonce, at = tern.now() }
	endpoint.reads[input.kind] = retained
	view.usage_relay[input.kind], view.usage_relay_frames[input.kind] = nil, nil
	relay.send(view, retained, "usage", "usage." .. input.kind .. ".request", binding_value, "request", input.bytes)
end
function relay.receive(message: any)
	if message.peer == "spawn" then
		if message.route == "spawn.source" and message.binding == "spawn-host" then
			local announcement = codec.strict_decode(message.body, 65536)
			if not setup_fields(announcement, { "schema", "kind", "peer_boot" }) or announcement.schema ~= 1
				or announcement.kind ~= "host_boot" or announcement.peer_boot ~= message.incarnation then
				relay.reject(message, "invalid_boot_announcement"); return
			end
			for _, candidate in relay.views do
				for lane_id, retained in candidate.lanes do
					if retained.metadata.peer_boot and retained.metadata.peer_boot ~= message.incarnation and retained.previous_boot ~= message.incarnation then
						retained.metadata.messages, candidate.view.spawn_relay_frames[lane_id] = {}, {}
						retained.previous_boot = retained.metadata.peer_boot
						retained.metadata.peer_boot, retained.sent.bind = nil, nil
						retained.metadata.bind_id = nil
						relay.failure(candidate.view, "peer_reloaded", retained.metadata)
						if contexts[candidate.view.pane] then contexts[candidate.view.pane].cx:render() end
					end
				end
			end
			relay.reject(message, "boot_observed"); return
		end
		local endpoint_id, lane_id = message.binding:match("^([A-Za-z0-9_.%-]+):([A-Za-z0-9_.%-]+)$")
		local endpoint = if endpoint_id then relay.views[endpoint_id] else nil
		local lane = if endpoint then endpoint.lanes[lane_id] else nil
		if not lane then relay.reject(message, "unbound_reply"); return end
		local view = endpoint.view
		local source = relay.source(view, lane.source.origin)
		if not source then relay.reject(message, "source_changed", view); return end
		source.lane_id = lane_id
		if not same_value(source, lane.source, 0) then relay.reject(message, "source_changed", view); return end
		local sequence = tonumber(message.id:match("^r%-(%d+)$"))
		if not sequence or sequence < 1 or sequence % 1 ~= 0 then relay.reject(message, "invalid_peer_sequence", view); return end
		if message.route == "spawn.source" then
			local proof = codec.strict_decode(message.body, 65536)
			if type(proof) == "table" and proof.kind == "held" then
				if setup_fields(proof, { "schema", "kind", "relay_endpoint", "lane_id", "peer_boot", "error", "rejected_message" })
					and proof.schema == 1 and proof.relay_endpoint == endpoint_id and proof.lane_id == lane_id
					and proof.peer_boot == message.incarnation and relay_token(proof.error, 128) then
					local rejected = proof.rejected_message
					local current = false
					if setup_fields(rejected, { "id", "incarnation" }) and rejected.incarnation == boot then
						for _, sent in lane.sent do if sent.id == rejected.id then current = true; break end end
						if lane.sent.bind and lane.sent.bind.id == rejected.id then lane.bind_answered = true end
						if proof.error == "release_held" and proof.peer_boot == lane.metadata.peer_boot
							and lane.sent.release and lane.sent.release.id == rejected.id then
							lane.metadata.release_held = true
							lane.release_requested, lane.sent.release = nil, nil
							relay.reject(message, "release_held")
							contexts[view.pane].cx:render()
							return
						end
					end
					relay.reject(message, proof.error, if current then view else nil)
				else relay.reject(message, "invalid_peer_advisory", view) end
				return
			end
			if not setup_fields(proof, { "schema", "relay_endpoint", "relay_boot", "lane_id", "host_pane_id", "source_nonce", "peer_boot", "error", "consumed_execution", "revoked_execution", "released", "bind_request" })
				or proof.schema ~= 1 or proof.relay_endpoint ~= endpoint_id or proof.relay_boot ~= boot or proof.lane_id ~= lane_id
				or proof.host_pane_id ~= tostring(view.pane) or proof.source_nonce ~= view.alias_nonce
				or proof.peer_boot ~= message.incarnation or not relay_token(proof.peer_boot, 64)
				or (proof.error ~= nil and not relay_token(proof.error, 128)) or (proof.released ~= nil and proof.released ~= true) then relay.reject(message, "invalid_peer_source", view); return end
			local bind = lane.sent.bind
			if not bind or not setup_fields(proof.bind_request, { "id", "incarnation" }) or proof.bind_request.id ~= bind.id
				or proof.bind_request.incarnation ~= boot then relay.reject(message, "stale_bind_proof"); return end
			lane.bind_answered = true
			if lane.metadata.peer_boot and lane.metadata.peer_boot ~= proof.peer_boot then
				lane.metadata.messages = {}; view.spawn_relay_frames[lane_id] = {}
				lane.metadata.peer_boot, lane.sent.bind = nil, nil
				lane.metadata.bind_id = nil
				relay.reject(message, "peer_reloaded", view); return
			end
			lane.metadata.peer_boot = proof.peer_boot
			lane.metadata.bind_id = proof.bind_request.id
			if lane.bound_boot ~= proof.peer_boot then lane.sequences = {}; lane.source_sequence = 0; lane.bound_boot = proof.peer_boot end
			if sequence > (lane.source_sequence or 0) then
				lane.source_sequence = sequence
				if proof.error then relay.failure(view, proof.error, lane.metadata)
				elseif lane.metadata.held then
					lane.metadata.held, lane.metadata.error = nil, nil
					local held = next(relay.unresolved) ~= nil
					for _, sibling in view.spawn_relay.lanes do if sibling.held then held = true end end
					if not held then
						view.spawn_relay.held, view.spawn_relay.error = nil, nil
						view.relay_notice = "The orchestration connection is restored. Retained managed work still follows its normal reconciliation rules."
					end
				end
			end
			local revoked_key
			if proof.revoked_execution ~= nil then
				local revoked = proof.revoked_execution
				if not setup_fields(revoked, { "id", "incarnation" }) or not relay_token(revoked.id, 80)
					or revoked.incarnation ~= proof.peer_boot then relay.reject(message, "invalid_revocation_proof", view); return end
				revoked_key = revoked.incarnation .. ":" .. revoked.id
				local previous = lane.received[revoked_key]
				-- Leave an early proof in the carrier until its exact execution arrives.
				-- Neither a timeout nor a missing receipt is evidence of retirement.
				if not previous then return end
				local body = previous.message.body:match("^SPAWN_EXECUTION v2 (.+)$")
				local execution = if body then codec.strict_decode(body, 65536) else nil
				if previous.message.route ~= "spawn.execution" or previous.message.incarnation ~= proof.peer_boot
					or type(execution) ~= "table" or execution.schema ~= 2 or execution.kind ~= "control_authorize" then
					relay.reject(message, "invalid_revocation_proof", view); return
				end
				-- This only retires a producer-invalidated callback carrier. It does not
				-- consume a domain result or grant permission to repeat any native effect.
				if not relay.ack(view, previous) then return end
				local current = lane.metadata.messages.execution
				if current and current.id == revoked.id and current.incarnation == revoked.incarnation then
					lane.metadata.messages.execution, view.spawn_relay_frames[lane_id].execution = nil, nil
				end
			end
			if proof.consumed_execution then
				local consumed = proof.consumed_execution
				if not setup_fields(consumed, { "id", "incarnation" }) or not relay_token(consumed.id, 80)
					or consumed.incarnation ~= proof.peer_boot then relay.failure(view, "invalid_consumption_proof", lane.metadata); return end
				local key = consumed.incarnation .. ":" .. consumed.id
				local previous = lane.received[key]
				if previous and previous.message.route == "spawn.execution" and previous.message.incarnation == consumed.incarnation
					and consumed.incarnation == proof.peer_boot then
					previous.consumed = true
					local current = lane.metadata.messages.execution
					if current and current.id == consumed.id and current.incarnation == consumed.incarnation then
						lane.metadata.messages.execution, view.spawn_relay_frames[lane_id].execution = nil, nil
					end
					if not relay.ack(view, previous) then return end
					lane.received[key] = nil
					relay.promote_execution(view, lane_id, lane)
				end
			end
			if proof.released == true then
				if not lane.release_requested then relay.failure(view, "unexpected_release", lane.metadata); return end
				for _, previous in lane.received do
					if previous.message.route == "spawn.response" then
						if not relay.reject(previous.message, "released_lane_result") then return end
					elseif not relay.ack(view, previous) then return end
				end
				if not relay.ack(view, { message = message }) then return end
				local receipt = { lane_id = lane_id, peer_boot = proof.peer_boot }
				endpoint.releases[lane_id] = { peer_boot = proof.peer_boot, source = lane.source }
				table.insert(view.spawn_relay.releases, receipt)
				for index, item in view.spawn_relay.lanes do if item == lane.metadata then table.remove(view.spawn_relay.lanes, index); break end end
				view.spawn_relay_frames[lane_id], endpoint.lanes[lane_id] = nil, nil
			else
				-- Keep the exact retired identity through proof-ACK backpressure, rather
				-- than maintaining a completion ledger or losing an early proof.
				if not relay.ack(view, { message = message }) then return end
				if revoked_key then
					lane.received[revoked_key] = nil
					relay.promote_execution(view, lane_id, lane)
				end
			end
			contexts[view.pane].cx:render()
			return
		end
		local kind = RELAY_ROUTES[message.route]
		local key = message.incarnation .. ":" .. message.id
		if not kind or lane.metadata.peer_boot ~= message.incarnation then
			if relay.reject(message, "stale_peer_reply") then lane.received[key] = nil end
			return
		end
		local retained = lane.received[key]
		if retained then
			if kind == "execution" then
				if relay.promote_execution(view, lane_id, lane) then contexts[view.pane].cx:render() end
			elseif sequence < (lane.sequences[kind] or 0) and relay.retirable_projection(message)
				and relay.ack(view, retained) then lane.received[key] = nil end
			return
		end
		local current = lane.metadata.messages[kind]
		if current and current.id == message.id and current.incarnation == message.incarnation then return end
		if kind == "execution" and sequence <= (lane.sequences.execution or 0) then
			-- A consumption proof earlier in this receive batch may have retired
			-- this exact frame already. Producer settlement can remove its file
			-- before the duplicate ACK; never reinsert it ahead of newer work.
			relay.reject(message, "superseded_peer_projection")
			return
		end
		lane.received[key] = { message = message, sequence = sequence }
		lane.sequences = lane.sequences or {}
		if kind == "execution" then
			relay.promote_execution(view, lane_id, lane)
			contexts[view.pane].cx:render()
			return
		end
		if sequence <= (lane.sequences[kind] or 0) then
			if relay.reject(message, "superseded_peer_projection") then lane.received[key] = nil end
			return
		end
		lane.sequences[kind] = sequence
		lane.metadata.messages[kind] = { id = message.id, incarnation = message.incarnation, route = message.route, binding = message.binding }
		view.spawn_relay_frames[lane_id][kind] = message.body
		-- A superseded observation or durably consumed result no longer needs a
		-- carrier slot. Unsettled effects still require their domain receipt.
		local previous_key = if current then current.incarnation .. ":" .. current.id else nil
		local previous = if previous_key then lane.received[previous_key] else nil
		if previous and relay.retirable_projection(previous.message) and relay.ack(view, previous) then lane.received[previous_key] = nil end
		if message.body == "" and relay.ack(view, lane.received[key]) then lane.received[key] = nil end
		contexts[view.pane].cx:render()
	elseif message.peer == "usage" then
		for _, endpoint in relay.views do
			for kind, read in endpoint.reads do
				if read.binding ~= message.binding or message.route ~= "usage." .. kind .. ".response" then continue end
				local view = endpoint.view
				if read.received then
					-- Delivery repeats until the actual window ACK. It is still bound,
					-- not an orphan that the host may acknowledge on the consumer's behalf.
					if same_value(read.received.message, message, 0) then return end
					relay.usage_failure(view, kind, "read_conflict")
					relay.reject(message, "read_conflict", if kind == "display" then nil else view)
					if contexts[view.pane] then contexts[view.pane].cx:render() end
					return
				end
				local body = codec.strict_decode(message.body, 65536)
				if not relay.native(view) or view.alias_nonce ~= read.source_nonce or type(body) ~= "table"
					or body.version ~= 1 or body.request_id ~= read.request_id or body.op ~= read.op or (kind ~= "display" and read.timed_out) then
					if kind == "display" then
						relay.usage_failure(view, kind, "invalid_usage_response")
						relay.reject(message, "invalid_usage_response")
						if contexts[view.pane] then contexts[view.pane].cx:render() end
						return
					end
					read.received = { message = message }
					if relay.reject(message, "invalid_usage_response", view) then read.received.acked = true end
					if contexts[view.pane] then contexts[view.pane].cx:render() end
					return
				end
				read.received = { message = message }
				if kind == "display" then view.usage_relay.display_error = nil end
				view.usage_relay[kind] = { request_id = read.request_id, peer_boot = message.incarnation,
					message = { id = message.id, incarnation = message.incarnation, route = message.route, binding = message.binding } }
				view.usage_relay_frames[kind] = message.body
				contexts[view.pane].cx:render()
				return
			end
		end
		relay.reject(message, "unbound_usage_read")
	end
end
function relay.pump()
	if not relay.endpoint then return end
	local messages, failure = relay.endpoint.receive(4)
	for _, message in messages do relay.receive(message) end
	local _, settled_failure = relay.endpoint.settle(4)
	for id, endpoint in relay.views do
		local view = endpoint.view
		if contexts[view.pane] == nil then relay.views[id] = nil; continue end
		local problem = failure or settled_failure
		if problem and view.spawn_relay.error ~= problem.code then relay.failure(view, problem.code); contexts[view.pane].cx:render() end
		for kind, read in endpoint.reads do
			if not read.received and not read.timed_out and tern.now() - read.at > 30000 then
				read.timed_out = true; relay.usage_failure(view, kind, "usage_read_timeout"); contexts[view.pane].cx:render()
			end
		end
	end
end
local relay_timer: any = nil
local function arm_relay()
	if relay_timer then return end
	relay_timer = tern.timer(if next(relay.views) then 100 else 1000, function()
		relay_timer = nil
		relay.pump()
		arm_relay()
	end)
end
local function relay_decode(value: any): any?
	if type(value) ~= "string" or #value > 400 * 1024 then return nil end
	local ok, parsed = pcall(tern.json.decode, value)
	if not ok or type(parsed) ~= "table" then return nil end
	local encoded, bytes = pcall(tern.json.encode, parsed)
	return if encoded and bytes == value then parsed else nil
end
function relay.handled(view: any, origin: any, bytes: any, response: any, control: any?)
	if not response.ok or type(bytes) ~= "string" or not relay.native(view) then return end
	local endpoint = relay.views[view.spawn_relay.relay_endpoint]
	local observed
	if control and response.code == "control_observed" and authority.status == "ready" and not authority.uncommitted_observation then
		local saved, current = pcall(tern.kv.get, STORE_KEY)
		if saved and same_value(current, authority.registry, 0) then
			for _, lane in endpoint.lanes do
				if not same_value(origin, lane.source.origin, 0) then continue end
				for _, retained in lane.received do
					if retained.message.route == "spawn.response" and retained.message.body == bytes then
						observed = { request = control, sequence = retained.sequence, peer_boot = retained.message.incarnation }
						break
					end
				end
			end
		end
	end
	for _, lane in endpoint.lanes do
		if observed and same_value(origin, lane.source.origin, 0) then
			-- One live-lane proof, not a completion history. Release/reload discards it.
			lane.observed_control = observed
		end
		for id, retained in lane.received do
			local exact = same_value(origin, lane.source.origin, 0) and retained.message.route ~= "spawn.execution"
				and retained.message.body == bytes
			if (exact or (observed and relay.observed_control(retained.message))) and relay.ack(view, retained) then
				lane.received[id] = nil
			end
		end
	end
end
local function inbox_observation(registry: any, session_id: string, input: any, archive: boolean): any
	local location, problem = dispatch.inbox_location(registry, session_id, input.orch_project_id)
	local response: any = { request_id = input.request_id, ok = false }
	if not location then response.message = if type(problem) == "table" then problem.message else problem
	else
		response.folder, response.orch_project_id = location.path, location.orch_project_id
		local name = input.name
		if name == nil and not archive then
			local ok, names = pcall(tern.fs.list, location.path)
			local offset = input.offset or 0
			if not ok or type(names) ~= "table" or #names > 4096 or type(offset) ~= "number" or offset < 0 or offset % 1 ~= 0 then
				response.message = "The execution-host inbox could not be listed within its 4096-entry bound."
			else
				local files = {}
				for _, entry in names do
					if type(entry) == "string" and #entry <= 255 and entry:sub(1, 1) ~= "." and not entry:find("[%c/\\]")
						and (entry:lower():sub(-3) == ".md" or entry:lower():sub(-4) == ".txt") then table.insert(files, entry) end
				end
				response.names = {}
				for index = offset + 1, math.min(offset + 128, #files) do table.insert(response.names, files[index]) end
				response.next_offset = if offset + 128 < #files then offset + 128 else nil
				response.ok = true
			end
		elseif bounded_text(name, 255) and name:sub(1, 1) ~= "." and not name:find("[%c/\\]")
			and (name:lower():sub(-3) == ".md" or name:lower():sub(-4) == ".txt") then
			local path = location.path .. "/" .. name
			local ok, bytes = pcall(tern.fs.read, path, 32768)
			if not ok then response.message = "The inbox file is unavailable, larger than 32 KiB or not a regular file; it stays untaken."
			else
				local hash = codec.sha256(bytes)
				response.name, response.content_sha256 = name, hash
				if not archive then response.ok = true
				else
					local record = if registry.dispatch and registry.dispatch.intakes then registry.dispatch.intakes[input.intake_id] else nil
					if not record or record.logical_session_id ~= session_id or record.kind ~= "inbox" or record.state ~= "accepted"
						or record.path ~= path or record.revision ~= hash or input.content_sha256 ~= hash then
						response.message = "Only the exact accepted inbox version can be archived. The current file was not removed."
					else
						local archived, failure = pcall(function()
							local directory = location.path .. "/.orchplus-taken"
							local destination = directory .. "/" .. input.intake_id .. "-" .. name
							tern.fs.mkdir(directory)
							if tern.fs.exists(destination) then
								if tern.fs.read(destination, 32768) ~= bytes then error("An archive with different content already exists.") end
							else tern.fs.write(destination, bytes) end
							if tern.fs.read(destination, 32768) ~= bytes or tern.fs.read(path, 32768) ~= bytes then error("The inbox or archive changed during verification.") end
							tern.fs.remove(path)
						end)
						response.ok, response.archived = archived, archived
						if not archived then response.message = "Accepted work is retained, but the source could not be archived: " .. tostring(failure):sub(1, 300) end
					end
				end
			end
		else response.message = "Choose one supported file directly inside the configured execution-host inbox." end
	end
	return response
end

local function handle(view: any, ev: any, cx: any)
	if ev.ev ~= "action" then return end
	if ev.act == "inbox-observe" or ev.act == "inbox-archive" then
		local input = setup_decode(ev.value)
		if setup_fields(input, { "source_nonce", "request_id", "origin", "orch_project_id", "name", "content_sha256", "intake_id", "offset" })
			and input.source_nonce == view.alias_nonce and bounded_text(input.request_id, 128)
			and dispatch.origin(input.origin) and relay.source(view, input.origin) and authority.status == "ready" then
			view.inbox_observation = inbox_observation(authority.registry, view.orch_session_id, input, ev.act == "inbox-archive")
			render_all()
		end
		return
	end
	if ev.act == "spawn_relay" or ev.act == "usage_relay" then
		local input = relay_decode(ev.value)
		if input then
			if ev.act == "spawn_relay" then relay.spawn_event(view, input) else relay.usage_event(view, input) end
		end
		return
	end
	if ev.act == "defaults-open" then
		local input = setup_decode(ev.value)
		if setup_fields(input, { "source_nonce", "native_window" }) and input.source_nonce == view.alias_nonce
			and bounded_text(input.native_window, 256, true) and not input.native_window:find("%z")
			and relay.native(view) then open_defaults(view, input.native_window) end
		return
	end
	if ev.act == "orchestration-create" then
		local input = setup_decode(ev.value)
		if not input or input.source_nonce ~= view.alias_nonce or not bounded_text(input.name, 160) or not bounded_text(input.request_id, 128) then return end
		if authority.status == "missing" and not authority.established then
			local initialized = authority:initialize(true)
			if not initialized.ok then
				initialized.request_id = input.request_id
				view.orchestration_result = initialized; view.dispatch_command_result = initialized
				view.notice = initialized.message or initialized.code; render_all(); return
			end
			input.authority_namespace, input.expected_revision = authority.registry.authority_namespace, authority.registry.revision
		end
		local response = authority:create({ kind = "register_session", request_id = nonce(), orch_session_id = nonce(),
			name = input.name, binding = binding(view), authority_namespace = input.authority_namespace,
			expected_revision = input.expected_revision }, input.defaults_revision)
		response.request_id = input.request_id
		view.dispatch_command_result = response; view.notice = response.message or response.code
		view.orchestration_result = response
		if response.ok then
			view.orch_session_id = response.orch_session_id
			view.scoped_results = nil
			view.config_open = false
		end
		render_all(); return
	end
	if ev.act == "source-discover" then
		local input = setup_decode(ev.value)
		if input and input.source_nonce == view.alias_nonce and bounded_text(input.request_id, 128) then discover_sources(view, input) end
		return
	elseif ev.act == "upgrade-window-readback" then
		local input = decode(ev.value)
		if input and input.source_nonce == view.alias_nonce and input.version == 5 then
			view.upgrade_result = authority:window_readback(input.authority_namespace, input.revision, archive_upgrade)
		end
		return
	elseif ev.act == "decision-context" then
		local input = setup_decode(ev.value)
		local event = if input then input.event else nil
		if input and input.source_nonce == view.alias_nonce and type(event) == "table" and dispatch.origin(event.origin)
			and event.origin.alias_nonce == view.alias_nonce and event.origin.host_pane_id == tostring(view.pane)
			and event.orch_session_id == view.orch_session_id and authority.registry then
			local session = session_for(view)
			local cursor = if authority.registry.dispatch then (authority.registry.dispatch.command_cursors or {})[view.orch_session_id] else nil
			if not session or not session.controller or session.controller.phase ~= "active"
				or not cursor or not same_value(cursor.origin, event.origin, 0) then return end
			view.decision_context_result = { request_id = input.request_id, decision_context = dispatch.decision_context(authority.registry, event), revision = authority.registry.revision }
			render_all()
		end
		return
	end
	if ev.act == "ruling-command" then
		local input = setup_decode(ev.value)
		if input and input.source_nonce == view.alias_nonce then ruling_command(view, input) end
		return
	elseif ev.act == "ruling-clear" then
		local input = decode(ev.value)
		if input and input.source_nonce == view.alias_nonce and view.ruling_result and view.ruling_result.request_id == input.request_id then view.ruling_result = nil end
		return
	end
	if ev.act == "page-entry" then
		if ev.id == "main" then page_entry(view, ev.value) end
		return
	end
	if ev.act == "setup-readiness-prepare" or ev.act == "setup-readiness-verify" then
		local input = setup_decode(ev.value)
		if input and input.source_nonce == view.alias_nonce and bounded_text(input.request_id, 128) then
			readiness_host(view, input, ev.act == "setup-readiness-prepare")
		end
		return
	end
	if ev.act == "setup-command" or ev.act == "setup-repository-probe" or ev.act == "setup-repository-discover" then
		local input = setup_decode(ev.value)
		if not input or input.source_nonce ~= view.alias_nonce or not bounded_text(input.request_id, 128) then return end
		local catalog_read = ev.act == "setup-command" and (input.kind == "catalog_request" or input.kind == "catalog_clear")
		if authority.status ~= "ready" and not catalog_read then
			setup_result(view, input, { ok = false, code = "authority_unavailable", message = "Open your saved orchestration or restore its settings before saving changes." })
		elseif ev.act == "setup-repository-discover" then discover_repository(view, input)
		elseif ev.act == "setup-repository-probe" then probe_repository(view, input)
		else setup_command(view, input) end
		return
	end
	if ev.act == "config-open-request" then
		-- Files-pane entry: display mode only; edits still require the admitted controller.
		view.config_open = true
		render_all()
		return
	elseif ev.act == "config-panes" then
		local input = decode(ev.value)
		local observed = if input and input.source_nonce == view.alias_nonce then session_panes(input) else nil
		if observed then
			view.session_panes = observed
			view.conversation_panes = observed.panes
			render_all()
		end
		return
	end
	if ev.act == "dispatch-release-scope" then
		local input = decode(ev.value)
		local retained = if input and view.scoped_results then view.scoped_results[input.action_id] else nil
		local receipt = if retained then retained.receipt else nil
		local delivery = receipt and receipt.grant_id ~= nil and receipt.grant_id == input.grant_id
			and receipt.response_sha256 == input.response_sha256
		local withdrawal = receipt and receipt.withdrawal_request_id ~= nil and receipt.withdrawal_request_id == input.withdrawal_request_id
			and receipt.worker_id == input.worker_id
		if input and input.source_nonce == view.alias_nonce and (delivery or withdrawal) then
			view.scoped_results[input.action_id] = nil
			render_all()
		end
		return
	end
	if ev.act == "dispatch-select" then
		local input = decode(ev.value)
		local retained = if input and authority.registry and authority.registry.dispatch then authority.registry.dispatch.actions[input.action_id] else nil
		if retained and input.source_nonce == view.alias_nonce and retained.request.origin_binding.alias_nonce == view.alias_nonce
			and retained.request.origin_binding.host_pane_id == tostring(view.pane) then
			view.dispatch_action = input.action_id; view.dispatch_result = nil
			view.dispatch_command_result = nil -- Explicit operator selection supersedes the previous command.
			if view.scoped_results and view.scoped_results[input.action_id] then view.scoped_results[input.action_id].result = nil end
			render_all()
		end
		return
	end
	if ev.act == "migration-command" then
		if type(ev.value) ~= "string" or #ev.value > codec.LIMITS.logical then return end
		local input = codec.strict_decode(ev.value, codec.LIMITS.logical)
		if not setup_fields(input, { "source_nonce", "setup_origin", "operation", "intent", "peer", "relay_proof" })
			or input.source_nonce ~= view.alias_nonce or not setup_origin(input.setup_origin, view)
			or not table.find({ "inspect", "prepare", "finish" }, input.operation) or type(input.intent) ~= "table" then return end
		local result = if relay.migration_peer(view, input) then authority:migrate(input.operation, input.intent, input.peer)
			else { ok = false, code = "stale_migration_peer", message = "The current SPAWN migration observation changed or was refused. Read both actual sources again before continuing." }
		view.migration_result = table.clone(result); view.migration_result.request_id = input.intent.request_id
		view.notice = tostring(result.message or result.code)
		render_all()
		return
	end
	if ev.act == "qualify-current" then
		if type(ev.value) ~= "string" or #ev.value > codec.LIMITS.logical then return end
		local input = codec.strict_decode(ev.value, codec.LIMITS.logical)
		if not input or input.source_nonce ~= view.alias_nonce or not dispatch.origin(input.origin)
			or input.origin.alias_nonce ~= view.alias_nonce or input.origin.host_pane_id ~= tostring(view.pane)
			or input.origin.logical_session_id ~= view.orch_session_id or type(input.peer) ~= "table" then return end
		local session = session_for(view)
		local owner = if session then session.controller else nil
		if not owner or owner.owner_id ~= input.origin.owner_id or owner.generation ~= input.origin.owner_generation
			or not owner.pane_binding or owner.pane_binding.alias_nonce ~= view.alias_nonce then return end
		-- The native window authenticated the exact SPAWN role/surface on this host. The dedicated
		-- state entrypoint independently validates our source and derives the matching identities.
		if not setup_fields(input.peer, { "proof", "selection" }) then return end
		view.dispatch_command_result = authority:qualify(input.event, input.peer.proof, input.peer.selection)
		view.notice = tostring(view.dispatch_command_result.message or view.dispatch_command_result.code)
		render_all()
		return
	end
	if ev.act == "forget-state" then
		-- Window-side progress of "Forget this orchestration…": a closed set of stages and bounded blocker rows, never free text.
		local input = decode(ev.value)
		if type(input) ~= "table" or not table.find({ "idle", "checking", "blocked", "pending" }, input.stage) then return end
		local blockers: { any } = {}
		local participants: { any } = {}
		local function rows(source: any, out: { any }, kinds: { string }?)
			if type(source) ~= "table" then return end
			for _, row in source do
				if #out >= 8 then break end
				if type(row) == "table" and (kinds == nil or table.find(kinds, row.kind))
					and type(row.agent) == "string" and #row.agent <= 96 and type(row.host) == "string" and #row.host <= 256 then
					table.insert(out, { kind = row.kind, agent = row.agent, host = row.host })
				end
			end
		end
		if input.stage == "blocked" then
			rows(input.blockers, blockers, { "unobservable", "uncertain" })
			rows(input.participants, participants)
		end
		local omitted = if type(input.omitted) == "number" and input.omitted >= 0 and input.omitted % 1 == 0 then input.omitted else 0
		local blockers_omitted = if input.stage == "blocked" and type(input.blockers_omitted) == "number" and input.blockers_omitted >= 0 and input.blockers_omitted % 1 == 0 then input.blockers_omitted else 0
		view.forget = if input.stage == "idle" then nil else { stage = input.stage, blockers = blockers, participants = participants, omitted = omitted, blockers_omitted = blockers_omitted, pending = input.pending == true }
		render_all()
		return
	end
	if ev.act == "authority-command" or ev.act == "authority-operator-command" then
		local input = decode(ev.value)
		local event = if input then input.event else nil
		local operator = ev.act == "authority-operator-command"
		if not input or input.source_nonce ~= view.alias_nonce or not dispatch.origin(input.origin)
			or input.origin.alias_nonce ~= view.alias_nonce or input.origin.host_pane_id ~= tostring(view.pane)
			or input.origin.logical_session_id ~= view.orch_session_id
			or not event or event.orch_session_id ~= view.orch_session_id
			or not table.find({ "begin_close", "release_controller", "confirm_close", "begin_forget", "supersede_forget", "complete_forget" }, event.kind) then return end
		if operator and event.kind ~= "release_controller" then return end
		local session = session_for(view)
		local owner = if session then session.controller else nil
		local closing = if session and session.close then session.close.control_origin else nil
		local active = owner and owner.owner_id == input.origin.owner_id and owner.generation == input.origin.owner_generation
			and owner.pane_binding and owner.pane_binding.alias_nonce == view.alias_nonce
		if not active and not (closing and same_value(closing.binding, input.origin, 0)) then return end
		if (event.kind == "begin_close" or event.kind == "begin_forget" or event.kind == "supersede_forget")
			and (not event.control_origin or not same_value(event.control_origin.binding, input.origin, 0)) then return end
		if event.kind == "release_controller" and ((not operator and not session.close) or event.expected_owner_id ~= input.origin.owner_id
			or event.expected_generation ~= input.origin.owner_generation) then return end
		local notice = view.notice
		local response = action(view, event)
		if operator then view.dispatch_command_result = response
		else
			view.dispatch_background_result = response
			if event.kind ~= "complete_forget" then view.notice = notice end -- the completion notice stays
		end
		return
	end
	if ev.act == "dispatch-command" or ev.act == "dispatch-operator-command" then
		local input = setup_decode(ev.value)
		if input and input.command ~= "policy" and input.command ~= "cancel_work" and input.command ~= "observe_allocation" and input.command ~= "bridge_result" and input.command ~= "bridge_observe" and input.command ~= "source_request" and #ev.value > 8192 then return end
		if input == nil or input.kind ~= "dispatch" or input.command == "intake" or not dispatch.origin(input.origin)
			or input.origin.host_pane_id ~= tostring(view.pane) or input.origin.alias_nonce ~= view.alias_nonce
			or input.orch_session_id ~= view.orch_session_id then return end
		local operator = ev.act == "dispatch-operator-command"
		-- Document obligations settle only through the dedicated `ruling-command` route, which reads the
		-- buffer and disk itself; caller-supplied evidence on this generic route is never trusted.
		if type(input.command) == "string" and (input.command:sub(1, 7) == "ruling_" or input.command == "associate_document") then return end
		if operator and not table.find({ "catalog", "queue", "poll", "reply", "retry", "retire", "finish", "rollover", "reconcile_restored", "continue_controller", "continue_worker", "policy", "pause", "resume", "answer", "cancel_gate", "recheck_gate", "dismiss_refusal",
			"cancel_landing", "move_landing", "landing_lost", "reconcile_landing", "capacity", "cancel_work", "recheck_report", "enrol", "readback_publication",
			"new_project", "project_start", "project_start_retry", "project_associate", "associate_conversation", "detach_conversation", "project_repository", "project_finish", "project_reopen", "delete_history",
			"plan_import", "board_intake", "inbox_intake", "template_start", "source_request",
			"bridge_control", "bridge_result", "bridge_observe", "close_handover", "migrate_families", "cleanup_notice" }, input.command) then return end
		if not operator and input.command == "enrol" then return end
		if input.command == "cleanup_notice" then
			local proof = input.inventory_proof
			local endpoint = if view.spawn_relay then relay.views[view.spawn_relay.relay_endpoint] else nil
			local lane = if endpoint and type(proof) == "table" and type(proof.lane_id) == "string" then endpoint.lanes[proof.lane_id] else nil
			local receipt = if type(proof) == "table" then proof.receipt else nil
			local retained = if lane and type(receipt) == "table" then lane.received[tostring(receipt.incarnation) .. ":" .. tostring(receipt.id)] else nil
			local query = if type(proof) == "table" and type(proof.query_json) == "string" then codec.decode_dispatch_request(proof.query_json) else nil
			local response = if retained and query then codec.decode_dispatch_response(retained.message.body, query) else nil
			if not lane or not query or query.op ~= "mailbox_inventory" or not same_value(query.origin_binding, input.origin, 0)
				or not same_value(lane.source.origin, input.origin, 0) or not relay.source(view, input.origin)
				or proof.peer_boot ~= lane.metadata.peer_boot or not retained or retained.message.route ~= "spawn.response"
				or retained.message.incarnation ~= proof.peer_boot or not response or response.status ~= "inventory" then
				view.dispatch_command_result = { ok = false, request_id = input.request_id, command = input.command,
					code = "inventory_unconfirmed", message = "Communication files could not be observed from this current connection. No cleanup summary was marked complete; it will be checked on your next interaction." }
				view.notice = view.dispatch_command_result.message; render_all(); return
			end
			input.inventory_proof = nil
			for _, key in { "observed_at_ms", "open_files", "stale_files", "mailboxes" } do input[key] = response.payload[key] end
			input.observation_unavailable = nil
		end
		if input.command == "project_repository" then
			local repository = if type(input.repository) == "table" then table.clone(input.repository) else nil
			if repository then repository.queue_route = nil end
			if not repository or not same_value(repository, view.setup_repository, 0) then
				view.dispatch_command_result = { ok = false, request_id = input.request_id, command = input.command, code = "repository_unverified", message = "Verify this project checkout and target on the execution host before associating it." }
				view.conversation_result = { source_nonce = view.alias_nonce, orch_session_id = input.orch_session_id, result = view.dispatch_command_result }
				view.notice = view.dispatch_command_result.message; render_all(); return
			end
			-- A retained probe is not current filesystem evidence. Recheck immediately before
			-- this metadata commit, retaining the submitted strict revision throughout.
			probe_repository(view, { source_nonce = view.alias_nonce, request_id = input.request_id,
				cwd = repository.cwd, target_ref = repository.target_ref }, function(verified: any)
				local response = verified
				if verified.ok then
					if same_value(verified.repository, repository, 0) then response = action(view, input, true)
					else response = { ok = false, code = "repository_changed", message = "The checkout or target changed. Review fresh repository evidence before associating it." } end
				end
				response.request_id, response.command = input.request_id, input.command
				view.conversation_result = { source_nonce = view.alias_nonce, orch_session_id = input.orch_session_id, result = response }
				view.dispatch_command_result = response; view.notice = response.message or response.code; render_all()
			end)
			return
		elseif input.command == "board_intake" and source_adapter.is_plan_mirror(input.tags) then
			view.dispatch_command_result = { ok = false, request_id = input.request_id, code = "plan_mirror", message = "Plan mirror cards are presentation only; start their original plan instead." }
			view.notice = view.dispatch_command_result.message; render_all(); return
		end
		local notice = view.notice
		-- Capture only existing grantless scopes before withdrawal consumes their actions. The
		-- successful command below supplies each watching window an ephemeral, correlated receipt.
		local withdrawing = {}
		if input.command == "cancel_work" and authority.registry then
			for id, pending in authority.registry.dispatch.actions do
				if pending.worker_id == input.worker_id and pending.claim == nil
					and pending.request.origin_binding.logical_session_id == input.orch_session_id then withdrawing[id] = true end
			end
		end
		local control
		if (input.command == "bridge_result" or input.command == "bridge_observe") and authority.registry then
			local session = authority.registry.sessions[input.orch_session_id]
			control = if session and session.bridge_control then session.bridge_control.request else nil
		end
		local response = action(view, input, true)
		relay.handled(view, input.origin, input.response_bytes, response, control)
		response.action_id = response.action_id or input.action_id
		response.grant_id = input.grant_id or (if response.claim then response.claim.grant_id else nil)
		response.command = input.command
		if not operator and input.command == "poll" then
			response.worker_id = input.worker_id
			view.dispatch_poll_result = response
		end
		-- An idle poll still owes its window a receipt, but changes no authority or visible notice.
		if not operator and response.ok and response.code == "mailbox_idle" and response.action_id == nil then
			view.notice = notice
			return
		end
		-- cancel_work is not workflow-only: withdrawing a rejected launch queues its mailbox retirement,
		-- which the window drives from this command result like any other queued effect.
		local control_command = table.find({ "bridge_control", "bridge_result", "bridge_observe" }, input.command) ~= nil
		local workflow_only = control_command or table.find({ "observe", "observe_allocation", "observe_conversation", "policy", "pause", "resume", "answer", "cancel_gate", "recheck_gate", "dismiss_refusal", "continue_controller",
			"cancel_landing", "move_landing", "landing_lost", "reconcile_landing", "capacity", "sweep", "cleanup_notice", "plan_import", "board_intake", "inbox_intake", "template_start" }, input.command) ~= nil
		workflow_only = workflow_only or table.find({ "new_project", "project_start", "project_start_retry", "project_associate", "associate_conversation", "detach_conversation", "project_repository", "project_finish", "project_reopen", "delete_history", "source_request" }, input.command) ~= nil
		if input.command == "observe_allocation" then view.dispatch_allocation_result = response end
		if control_command then
			view.dispatch_control_result = response
		end
		if operator and not control_command then
			view.dispatch_command_result = response
			if not workflow_only then view.dispatch_driver_result = response end
		end
		-- The conversation composer serializes these commands per source. Keep its exact
		-- completion separate from housekeeping and effect-driver receipts until the next
		-- conversation command; a later cleanup summary cannot strand the completed job.
		if operator and table.find({ "new_project", "project_start", "project_start_retry", "project_associate", "associate_conversation",
			"detach_conversation", "project_repository", "project_finish", "project_reopen" }, input.command) then
			local creation = view.orchestration_result
			view.conversation_result = { source_nonce = view.alias_nonce, orch_session_id = input.orch_session_id, result = response,
				creation_request_id = if input.command == "new_project" and creation and creation.ok == true
					and creation.orch_session_id == input.orch_session_id then creation.request_id else nil }
		end
		if not operator or control_command then view.dispatch_background_result = response; view.notice = notice end
		if (not operator or response.ok) and not workflow_only then view.dispatch_result = response end
		if response.ok and response.action_id then view.dispatch_action = response.action_id end
		if not workflow_only then capture_dispatch(view, response) end
		if response.ok and input.command == "cancel_work" then
			for _, context in contexts do
				for id in withdrawing do
					local retained = (context.view.scoped_results or {})[id]
					if retained and retained.consumer and retained.consumer.authority_namespace == input.authority_namespace
						and retained.consumer.logical_session_id == input.orch_session_id and authority.registry.dispatch.actions[id] == nil then
						retained.receipt = { action_id = id, worker_id = input.worker_id, withdrawal_request_id = input.request_id,
							authority_namespace = input.authority_namespace, logical_session_id = input.orch_session_id }
						retained.result = response
					end
				end
			end
		end
		render_all()
		return
	elseif type(ev.act) == "string" and ev.act:sub(1, 16) == "dispatch-result/" then
		if authority.registry == nil then return end
		local envelope = setup_decode(ev.value)
		if not setup_fields(envelope, { "authority_namespace", "expected_revision", "response_bytes" })
			or type(envelope.response_bytes) ~= "string" or #envelope.response_bytes > codec.DISPATCH.limit then return end
		local bytes = envelope.response_bytes
		local prefix = codec.DISPATCH.prefix
		if bytes:sub(1, #prefix) ~= prefix then return end
		local frame = codec.strict_decode(bytes:sub(#prefix + 1), codec.DISPATCH.limit)
		if not frame then return end
		for id, pending in (authority.registry.dispatch or { actions = {} }).actions do
			local request = pending.request
			if request.request_id == frame.request_id and request.origin_binding.host_pane_id == tostring(view.pane)
				and request.origin_binding.alias_nonce == view.alias_nonce and request.origin_binding.logical_session_id == view.orch_session_id
				and pending.claim ~= nil then
				local projected = dispatch.project(authority.registry, view.orch_session_id, view.alias_nonce, id).actions[id]
				local execution_origin = if projected then projected.execution_origin or request.origin_binding else nil
				if not execution_origin or ev.act:sub(17) ~= pending.claim.grant_id .. "/" .. execution_origin.window_epoch then return end
				local grant_id = pending.claim.grant_id
				local response_sha256 = codec.sha256(bytes)
				local consumer = dispatch_consumer(execution_origin)
				local notice = view.notice
				local response = action(view, { kind = "dispatch", request_id = protocol.result_request_id(grant_id, execution_origin.window_epoch, envelope), command = "result", action_id = id,
					orch_session_id = request.origin_binding.logical_session_id, origin = execution_origin,
					authority_namespace = envelope.authority_namespace, expected_revision = envelope.expected_revision,
					controller_pane = projected.execution_controller_pane or request.controller_pane,
					executor = pending.claim.executor, grant_id = grant_id, response_bytes = bytes }, true)
				view.notice = notice
				relay.handled(view, execution_origin, bytes, response)
				response.action_id = id; response.grant_id = grant_id; response.command = "result"
				view.dispatch_result = response
				if response.ok then
					view.dispatch_receipt = { action_id = id, grant_id = grant_id, response_sha256 = response_sha256 }
				end
				capture_dispatch(view, response, if response.ok then view.dispatch_receipt else nil, consumer)
				render_all()
				return
			end
		end
		return
	elseif ev.act == "recovery-steps" then
		-- Window-computed reload checklist: display only, never authority or attestation.
		local input = decode(ev.value)
		if not input or input.source_nonce ~= view.alias_nonce or type(input.steps) ~= "table" or #input.steps > 24 then return end
		local steps = {}
		for _, step in input.steps do
			if type(step) ~= "table" or not bounded_text(step.label, 256) or (step.detail ~= nil and not bounded_text(step.detail, 512)) then return end
			table.insert(steps, { label = step.label, detail = step.detail })
		end
		view.recovery_steps = { steps = steps }
		render_all()
		return
	elseif ev.act == "dispatch-notice" then
		local input = decode(ev.value)
		local incoming = dispatch_notice(input)
		if incoming and input.source_nonce == view.alias_nonce and not same_value(view.notice, incoming, 0) then
			-- Keep severity with its message: later ordinary host notices replace the whole value.
			view.notice = incoming
			render_all()
		end
		return
	elseif ev.act == "idle-wake" then
		-- The window's idle-wake helper state (window.luau idle_wake): display only, never authority.
		local input = decode(ev.value)
		if not input or input.source_nonce ~= view.alias_nonce or (input.state ~= "active" and input.state ~= "idle" and input.state ~= "unavailable")
			or (input.detail ~= nil and not bounded_text(input.detail, 256)) then return end
		view.idle_wake = if input.state == "idle" then nil else { state = input.state, detail = input.detail }
		render_all()
		return
	end
	if ev.act == "assistance-result" then
		local input = decode(ev.value)
		if input == nil or input.source_nonce ~= view.alias_nonce or type(input.message) ~= "string" or #input.message > 2048 then return end
		local session = session_for(view)
		local owner = if session ~= nil and (input.target == "controller" or input.target == "orchestrator") then session[input.target] else nil
		if input.orch_session_id ~= view.orch_session_id or input.authority_namespace ~= authority.registry.authority_namespace
			or owner == nil or owner.owner_id ~= input.owner_id or owner.generation ~= input.generation
			or authority.registry.revision ~= input.expected_revision then
			view.notice = "Ignored stale assistance result; the owner changed."
			return
		end
		view.notice = input.message
		-- A missing window alias is uncertainty, never proof that an owner stopped.
		if input.observation == "active" or input.observation == "unavailable" then
			local event = owner_event(view, input, "observe_owner")
			event.evidence = "observed"
			if input.observation == "active" then
				event.status = "Same-host window alias observed; " .. string.sub(input.message, 1, 180)
				event.owner_active = true
			else
				event.status = "unavailable"
			end
			event.request_id = nonce()
			local response = authority:apply(event)
			if response.ok then render_all() else view.notice = tostring(response.message or response.code) end
		end
		return
	end
	if ev.act == "operator-intent-done" then
		-- The consuming window settles the one-shot intent; a stale or foreign serial changes nothing.
		local input = decode(ev.value)
		local intent = view.operator_intent
		if input and intent and input.source_nonce == intent.source_nonce and input.serial == intent.serial then
			view.operator_intent = nil; view.operator_intent_at = nil
		end
		return
	end
	local entry = view.actions[ev.value]
	if ev.act ~= "control" then return end
	if entry == nil then
		local session = session_for(view)
		local owner = if session then session.controller else nil
		view.refusal = { ok = false, code = if owner then "controller_slot_occupied" else "stale_action",
			owner_id = if owner then owner.owner_id else nil, generation = if owner then owner.generation else nil,
			orch_session_id = view.orch_session_id, revision = if authority.registry then authority.registry.revision else nil }
		view.notice = if owner then "REFUSED: the displayed action is stale and this controller slot is occupied by " .. owner.owner_id
			.. " / generation " .. tostring(owner.generation) .. " / phase " .. owner.phase .. ". Inspect or reveal the current owner; no action was retried."
			else "REFUSED: this displayed action expired after the view changed. Inspect the current state and choose a current action; nothing was retried."
		render_all()
		return
	end
	view.refusal = nil
	if entry.kind == "setup-intent" and entry.command == "defaults" then open_defaults(view); return end
	if entry.kind == "operator-intent" or entry.kind == "assist-intent" or entry.kind == "setup-intent" then
		-- Window-side controls (pickers, prompts, panes) run in the window. Publish the exact stored
		-- request as a bounded one-shot intent; the window re-validates everything before acting.
		publish_intent(view, entry)
		return
	end
	if entry.kind == "advanced-toggle" then view.advanced_open = not view.advanced_open; render_all(); return
	elseif entry.kind == "finished-toggle" then view.finished_open = not view.finished_open; render_all(); return
	elseif entry.kind == "project-select" then view.orch_project_id = entry.orch_project_id; render_all(); return end
	if entry.kind == "config-open" or entry.kind == "config-close" then
		-- Viewing Config is display-only; unbound/duplicate views render it read-only with the reason.
		view.config_open = entry.kind == "config-open"
		render_all()
	elseif entry.kind == "workflow-select" then
		view.workflow_worker = entry.worker_id
		view.workflow_gates = 0; view.workflow_thread = 0
		render_all()
	elseif entry.kind == "workflow-page" then
		local plan_id = entry.name:match("^plan (.+)$")
		if entry.name == "gates" then view.workflow_gates = entry.page
		elseif plan_id then view.workflow_plans = view.workflow_plans or {}; view.workflow_plans[plan_id] = entry.page
		else view.workflow_thread = entry.page end
		render_all()
	elseif entry.kind == "dispatch-acknowledge" then
		local retained = view.dispatch_command_result
		if retained and retained.request_id == entry.request_id and retained.ok == false then
			retained.acknowledged = true
			render_all()
		end
	elseif entry.kind == "recheck-store" then
		if authority.status ~= "ready" then authority:load() end
		view.notice = authority.diagnostic or "Authority store ready."
		render_all()
	elseif entry.kind == "initialize-arm" then
		view.initialize_armed = true
	elseif entry.kind == "initialize-confirm" then
		if view.initialize_armed then
			local response = authority:initialize(true)
			view.notice = response.message or response.code
			view.initialize_armed = false
			render_all()
		end
	elseif entry.kind == "select" then
		if authority.registry ~= nil and authority.registry.sessions[entry.orch_session_id] ~= nil then
			if view.orch_session_id ~= entry.orch_session_id then view.scoped_results = nil end
			view.orch_session_id = entry.orch_session_id
			view.recovery = nil
		end
	elseif entry.kind == "close-unowned-arm" then
		view.close_armed = { orch_session_id = entry.orch_session_id, authority_namespace = entry.authority_namespace,
			expected_revision = entry.expected_revision, close_id = nonce() }
	elseif entry.kind == "close-unowned-confirm" then
		local intent = confirmation(view, entry, "close_armed")
		if not intent then return end
		view.close_armed = nil
		local session = if intent and authority.registry then authority.registry.sessions[intent.orch_session_id] else nil
		if not session or session.controller or session.orchestrator or session.admission_seq then
			view.notice = "Session acquired an owner or peer admission; use its explicit controller close path."; return
		end
		local response = action(view, { kind = "begin_close", orch_session_id = intent.orch_session_id,
			authority_namespace = intent.authority_namespace, expected_revision = intent.expected_revision, close_id = intent.close_id })
		if response.ok then
			-- Successful begin creates the distinct confirmation intent, never upgrades a failed attempt.
			response = action(view, { kind = "confirm_close", orch_session_id = intent.orch_session_id,
				authority_namespace = intent.authority_namespace, expected_revision = response.revision, close_id = intent.close_id })
			if response.ok and view.orch_session_id == intent.orch_session_id then view.orch_session_id = nil end
		end
	elseif entry.kind == "register-arm" then
		view.register_armed = { authority_namespace = entry.authority_namespace, expected_revision = entry.expected_revision,
			orch_session_id = nonce(), name = "Logical session " .. nonce(), binding = binding(view) }
	elseif entry.kind == "register-confirm" then
		local intent = confirmation(view, entry, "register_armed")
		if not intent then return end
		local response = action(view, { kind = "register_session", authority_namespace = intent.authority_namespace,
			expected_revision = intent.expected_revision, orch_session_id = intent.orch_session_id, name = intent.name, binding = intent.binding })
		if response.ok then view.orch_session_id = response.orch_session_id; view.scoped_results = nil end
		view.register_armed = false
	elseif entry.kind == "admit" then
		action(view, { kind = "admit_controller", orch_session_id = entry.orch_session_id, pane_binding = binding(view),
			authority_namespace = entry.authority_namespace, expected_revision = entry.expected_revision })
	elseif entry.kind == "executor-arm" then
		view.executor_confirmation = table.clone(entry)
		view.executor_confirmation.intent_id = nonce()
	elseif entry.kind == "executor-confirm" then
		local retained = confirmation(view, entry, "executor_confirmation")
		if not retained then return end
		view.executor_confirmation = nil
		action(view, { kind = "dispatch_reconcile", orch_session_id = retained.orch_session_id, action_id = retained.action_id,
			authority_namespace = retained.authority_namespace, expected_revision = retained.expected_revision, executor = retained.executor, operator_verified = true,
			reason = "Operator independently verified this exact retained executor and any delayed native launch are stopped or reconciled." })
	elseif entry.kind == "attest" or entry.kind == "attest-executors" then
		view.attestation = table.clone(entry)
		view.attestation.intent_id = nonce()
	elseif entry.kind == "attest-confirm" or entry.kind == "attest-executors-confirm" then
		local previous = confirmation(view, entry, "attestation")
		if not previous then return end
		view.attestation = nil
		if entry.kind ~= previous.kind .. "-confirm"
			or authority.registry == nil or previous.revision ~= authority.registry.revision then
			view.notice = "Attestation expired because ownership changed. Inspect and recheck again."
			return
		end
		local event = owner_event(view, previous, "observe_owner")
		event.status = if previous.kind == "attest-executors" then "Operator independently verified unavailable owner and every retained unconfirmed executor stopped or reconciled"
			else "Operator independently verified unavailable owner stopped; no pending executors"
		event.owner_active = false
		event.pending_executors = 0
		event.evidence = "operator_attested"
		event.operator_verified = true
		if previous.kind == "attest-executors" then event.executors_verified = true end
		action(view, event)
	elseif entry.kind == "begin-recovery" then
		local event = owner_event(view, entry, "begin_recovery")
		event.expected_revision = entry.revision
		local response = action(view, event)
		if response.ok then
			view.recovery = { target = entry.target, owner_id = entry.owner_id, generation = entry.generation, revision = response.revision,
				authority_namespace = entry.authority_namespace, expected_revision = response.revision, orch_session_id = entry.orch_session_id, intent_id = response.intent_id }
		end
	elseif entry.kind == "confirm-recovery" then
		local recovery = confirmation(view, entry, "recovery")
		if not recovery then return end
		local event = owner_event(view, recovery, "confirm_recovery")
		event.expected_revision = recovery.revision
		event.intent_id = recovery.intent_id
		event.operator_verified = true
		event.evidence = "operator_attested"
		local response = action(view, event)
		if response.ok then view.recovery = nil end
	end
end

-- Renders follow what an event actually changed: duplicate replays, refusals and no-op
-- answers that leave authority and this view's visible state unchanged render nothing.
local function handle_event(view: any, ev: any, cx: any)
	local registry, global, visible = authority.registry, authority_signature(), view_signature(view)
	handling_event = true
	local ok, failure = pcall(handle, view, ev, cx)
	handling_event = false
	if authority.registry ~= registry or authority_signature() ~= global then
		render_all()
	else
		local after = view_signature(view)
		if visible == nil or after == nil or after ~= visible then cx:render() end
	end
	if not ok then error(failure, 0) end
end

local timer: any = nil
local function arm()
	if timer ~= nil then return end
	timer = tern.timer(1000, function()
		timer = nil
		arm()
		-- Host lifecycle IDs are never translated to window aliases or worker identities.
		local live = {}
		for _, pane in tern.pane.list() do live[pane.pane] = true end
		for pane, entry in contexts do
			if not live[pane] then contexts[pane] = nil
			elseif entry.view.operator_intent ~= nil and tern.now() - (entry.view.operator_intent_at or 0) > INTENT_TTL_MS then
				entry.view.operator_intent = nil; entry.view.operator_intent_at = nil
				entry.view.notice = "A clicked control was not confirmed by a window showing this controller in its admitted session within 30 s; it will not run later. Check the current state, then use a current control. After a reload, run ORCH+ Continue controller in this window from the palette first."
				entry.cx:render()
			end
		end
		if authority.status == "ready" then
			local before = authority.registry
			authority:apply({ kind = "workflow_tick", authority_namespace = before.authority_namespace, expected_revision = before.revision })
			if authority.registry ~= before then render_all() end
		end
	end)
end

local definition: BlockDef<any> = {
	font = "sans",
	init = function(cx: BlockCx, args: { string }, saved: any): any
		if authority.status == "unloaded" then authority:load() end
		arm()
		-- The Files-pane button opens new views directly in Config mode.
		local view: any = { pane = cx.pane, alias_nonce = nonce(), actions = {}, action_serial = 0, config_open = type(args) == "table" and args[1] == "config" }
		if authority.status == "missing" then
			local preview = state.new_registry("preview")
			view.setup_preview = { setup = preview.setup, installation_defaults = preview.installation_defaults }
		end
		if type(saved) == "table" then
			if saved.established == true then authority.established = true end
			if authority.status == "missing" and authority.established then authority.status = "missing_established" end
			if saved.pane == cx.pane and type(saved.alias_nonce) == "string" and #saved.alias_nonce <= 128 then view.alias_nonce = saved.alias_nonce end
			if type(saved.orch_session_id) == "string" and #saved.orch_session_id <= 128 then view.orch_session_id = saved.orch_session_id end
			if type(saved.dispatch_command_result) == "table" then view.dispatch_command_result = saved.dispatch_command_result end
			if type(saved.notice) == "string" then view.notice = saved.notice
			else view.notice = dispatch_notice(saved.notice) end
			if type(saved.relay_notice) == "string" and #saved.relay_notice <= 512 then view.relay_notice = saved.relay_notice end
		end
		normalize_view(view)
		-- Native page args are a one-shot launch request, never restored from saved block args.
		if saved == nil and view.config_open and args[2] ~= nil then page_entry(view, args[2]) end
		contexts[cx.pane] = { cx = cx, view = view }
		relay.attach(view)
		arm_relay()
		return view
	end,
	title = function(_view: any): string return "ORCHESTRATED WORK" end,
	view = function(view: any, _cx: BlockCx): BlockView
		normalize_view(view)
		view.host_pane_titles = {}
		for _, pane in tern.pane.list() do view.host_pane_titles[tostring(pane.pane)] = pane.title end
		local root = authority.registry or authority.migration_source
		view.migration = nil
		if root then
			local qualification = authority.migration_qualification
			if qualification and qualification.proof.source_revision ~= root.revision then qualification = nil end
			view.migration = { protocol = 2, source_nonce = view.alias_nonce, host_pane_id = tostring(view.pane),
				phase = if not authority.registry then "legacy" elseif authority.registry.migration then "prepared" else "stable",
				authority_namespace = if authority.registry then authority.registry.authority_namespace else authority.migration_namespace,
				authority_revision = root.revision, source_sha256 = if qualification then qualification.proof.source_sha256 elseif not authority.registry then authority.migration_source_hash else nil,
				compatibility = if authority.registry and authority.registry.compatibility then authority.registry.compatibility
					elseif qualification then authority.migration_pair elseif authority.registry then authority.registry.migration else nil,
				qualification = qualification, result = view.migration_result }
		end
		prune_scopes()
		local projection = if authority.registry ~= nil then state.project(authority.registry, { orch_session_id = view.orch_session_id }) else nil
		if projection ~= nil and view.orch_session_id ~= nil then
			projection.dispatch = dispatch.project(authority.registry, view.orch_session_id, view.alias_nonce, view.dispatch_action, view.scoped_results)
			if view.migration then
				projection.dispatch.compatibility = authority.registry.compatibility or view.migration.compatibility
			end
		end
		return { main = views.render(view, projection, authority.status, if authority.uncommitted_observation then UNSAVED_OBSERVATION else authority.diagnostic) }
	end,
	event = handle_event,
	save = function(view: any): any
		normalize_view(view)
		return { pane = view.pane, alias_nonce = view.alias_nonce, orch_session_id = if authority_lacks(view) then nil else view.orch_session_id, established = authority.established,
			dispatch_command_result = view.dispatch_command_result, notice = view.notice, relay_notice = view.relay_notice }
	end,
}
tern.block.define("orchestrator", definition)
require("./form_host").register()
tern.on("pane_exited", function(ev: any, _cx: EffectCx) contexts[ev.pane] = nil end)
tern.on("title", function(_ev: any, _cx: EffectCx) render_all() end)
arm() -- Module reload does not emit window_start; rearm independently of any view.
require("./updater/host").register()
require("./status/status_prompt").host_serve()
return { new_authority = new_authority, inbox_observation = inbox_observation, repository_refs = repository_refs }
