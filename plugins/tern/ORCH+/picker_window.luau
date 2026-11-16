--!strict
-- Window-only presentation. SPAWN remains the record authority; usage.display is never capacity.
-- new(api): node(cx,source,key,role), surface/read_surface(cx,pane,block,role,key,max),
-- transport(cx,source,block,args), catalog(cx,source,origin,cursor,context)->request_id,
-- snapshot(cx,source,action_id?), fresh(cx,source,origin), current(cx,source,origin), notice, id.
-- pick(cx,source,origin,{placeholder?,need?,exclude?,allow_none?},done(cx,record?,index));
-- load(cx,source,origin,done(cx,full_catalog?,problem?,metadata?)) collects without opening UI;
-- ensure(cx,source,origin,record_id,done(cx,record?,full_catalog?,problem?,metadata?)) rereads its
-- selected page after load. The full catalog is presentation, not routing permission.
-- tick(cx) also drains abandoned display reads; active() describes presentation only.
-- cancel(cx,source) closes only this owned picker, never an issued read.
local M = {}
local POLL_MS, TIMEOUT_MS, MAX_RECORDS = 15000, 30000, 256
local provider_display = require("./provider_display")
local function text(value: any): boolean return type(value) == "string" and value:find("%S") ~= nil end
local function integer(value: any): boolean return type(value) == "number" and value >= 0 and value % 1 == 0 and value < 9007199254740992 end
local function same_catalog(a: any, b: any): boolean
	return a ~= nil and b ~= nil and a.namespace == b.namespace and a.host_key == b.host_key
		and a.config_revision == b.config_revision and a.revision == b.revision
end
local function eligible(row: any, options: any): boolean
	return type(row) == "table" and text(row.id) and integer(row.revision) and row.enabled == true and row.eligible == true
		and (row.cwd == nil or type(row.cwd) == "string") and table.find({ "tab", "split", "replace_if_alone" }, row.placement) ~= nil
		and type(row.capabilities) == "table" and table.find(row.capabilities, "report-files-v1") ~= nil
		and (options.need == nil or table.find(row.capabilities, options.need) ~= nil)
		and (options.need ~= "project-start-v1" or table.find(row.capabilities, "coordinator-control-v1") ~= nil)
		and not (options.exclude and options.exclude[row.id])
end
local function catalog_valid(index: any): boolean
	return type(index) == "table" and index.loaded == true and text(index.namespace) and text(index.host_key)
		and integer(index.config_revision) and integer(index.revision) and type(index.records) == "table" and #index.records <= MAX_RECORDS
end
local function same_record(a: any, b: any): boolean
	return a.id == b.id and a.revision == b.revision and a.cwd == b.cwd and a.placement == b.placement
		and a.definition_revision == b.definition_revision and a.backend == b.backend
end
local function bound(row: any, catalog: any, usage: any): boolean
	return type(usage) == "table" and text(usage.definition_revision) and usage.record_id == row.id
		and usage.record_revision == row.revision and usage.namespace == catalog.namespace
		and usage.host_key == catalog.host_key and usage.config_revision == catalog.config_revision
		and (row.definition_revision == nil or usage.definition_revision == row.definition_revision)
end
local function usage_text(row: any, index: any, readings: any, now: number, status: string): string
	local reading = readings[row.id]
	if not bound(row, index, reading) then return "Usage unavailable" .. (if status == "disabled" then " · enable Show usage in ORCH+ in USAGE" else "") end
	if string.lower(row.provider or "") == "omp" and not text(reading.underlying_record_id) then return "Usage unavailable · underlying subscription not linked" end
	if type(reading.used) ~= "number" or reading.used ~= reading.used or reading.used < 0 or reading.used > 100 then return "Usage unavailable" end
	if not table.find({ "fresh", "stale", "last_known", "reset_passed", "login" }, reading.state) then return "Usage unavailable" end
	local observation = reading.observed_at_ms
	if not integer(observation) or observation == 0 or observation > now then return "Usage unavailable · observation time unknown" end
	local age = now - observation
	local fresh = reading.state == "fresh" and age < 900000
	local reset = integer(reading.resets_at_ms) and reading.resets_at_ms > 0 and reading.resets_at_ms <= now
	local state = if reset or reading.state == "reset_passed" then "reset passed; last known" elseif fresh then "current"
		elseif reading.state == "login" then "login needed; last known" elseif reading.state == "last_known" then "last known" else "stale"
	return string.format("%.0f%% used · %s · %dm ago", reading.used, state, math.floor(age / 60000))
end
M.eligible, M.usage_text = eligible, usage_text
function M.new(api: any): any
	local pending: any = {}
	local loaded: any = {}
	local display_reads: any = {}
	local clear_usage: any
	local surface = api.read_surface or api.surface
	local function index(cx: any, source: number): any return api.node(cx, source, "catalog-index", "orchplus.catalog") end
	-- Setup can use the same real in-pane selector with a pre-controller catalog relay.
	local function current(cx: any, s: any): boolean
		return if s.adapter then s.adapter.current(cx) else api.current(cx, s.source, s.origin)
	end
	local function catalog_index(cx: any, s: any): any
		return if s.adapter then s.adapter.index(cx) else index(cx, s.source)
	end
	local function owned(_cx: any, s: any): boolean
		return s.load_done ~= nil or s.ensure_done ~= nil or api.forms.active(s.source, s.token)
	end
	local function cancel(cx: any, source: number)
		local s = pending[source]; pending[source] = nil
		if s then clear_usage(s, "unavailable") end
		if s and not s.load_done and not s.ensure_done and api.forms.active(source, s.token) then api.forms.cancel(cx, source) end
		if s and s.load_done then s.load_done(cx, nil, "Agent loading was cancelled.")
		elseif s and s.ensure_done then s.ensure_done(cx, nil, nil, "Agent selection was cancelled.") end
	end
	local function deliver(cx: any, s: any, record: any, catalog: any)
		pending[s.source] = nil
		clear_usage(s, "unavailable")
		-- Consumers may inspect ownership or immediately reuse this pane for their next form.
		s.done(cx, record, catalog)
		if pending[s.source] == nil and api.forms.active(s.source, s.token) then api.forms.cancel(cx, s.source) end
	end
	local select_record: any
	local function show(cx: any, s: any)
		if s.load_done or s.ensure_done then return end
		if s.drawn and not api.forms.active(s.source, s.token) then
			clear_usage(s, "unavailable"); pending[s.source] = nil
			api.notice(cx, s.source, s.origin.alias_nonce, "Agent selection was interrupted by another view. Reopen the selector; nothing was launched.", "error")
			return false
		end
		local items = {}
		local bound_title = s.options.pane_title
		if s.options.pane_binding and api.pane then
			bound_title = provider_display.pane_title(api.pane(cx, s.source, tonumber(s.options.pane_binding.pane_id), s.origin))
		end
		if s.phase == "ready" then
			for position, record in s.records do
				local account = if text(record.account_label) then record.account_label else "account unknown"
				local title = if s.options.pane_binding then bound_title else bound_title or (if api.agent_titles then api.agent_titles(cx, s.source, record.id, s.origin) else nil)
				table.insert(items, { label = provider_display.name(record.provider) .. " · " .. account .. " — " .. (title or "No active pane"),
					icon = provider_display.icon(record.provider),
					detail = usage_text(record, s.index, s.readings, math.floor(os.time() * 1000), s.usage_status)
						.. (if s.options.selected and table.find(s.options.selected, record.id) then " · selected" else ""),
					position = position, choice_key = "record:" .. record.id })
			end
			if s.options.allow_none then table.insert(items, { label = s.options.none_label or "None", none = true, choice_key = "none" }) end
		end
		local fingerprint = tern.json.encode({ phase = s.phase, message = s.message, items = items })
		if fingerprint == s.drawn then return true end
		if s.phase == "ready" and s.presented_phase == "ready" and #items > 0 then
			-- Cosmetic observation ages must never reopen/focus a form or rotate a pending click.
			if api.forms.update(cx, s.source, { choices = items }) then s.drawn = fingerprint end
			return true
		end
		if (s.phase == "failed" or s.phase == "changed") and api.forms.active(s.source, s.token) then
			local updated = api.forms.update(cx, s.source, { busy = false, description = s.message, description_tone = "error" })
			if updated then s.drawn, s.presented_phase = fingerprint, s.phase end
			return updated
		end
		if s.phase == "selecting" then
			if not api.forms.update(cx, s.source, { busy = true, notice = s.message }) or not api.forms.active(s.source, s.token) then
				if api.forms.active(s.source, s.token) then deliver(cx, s, nil, nil)
				else clear_usage(s, "unavailable"); pending[s.source] = nil end
				api.notice(cx, s.source, s.origin.alias_nonce, "The selected agent could not retain its native form while being checked. Reopen the selector; nothing was launched.", "error")
				return false
			end
			s.drawn, s.presented_phase = fingerprint, s.phase
			return true
		end
		if s.phase == "ready" and #items > 0 then
			api.forms.choose(cx, s.source, s.origin, { title = s.options.placeholder or "Choose an agent", placeholder = s.message, items = items, tag = s.token, retain = true },
				function(fresh: any, choice: any)
					if pending[s.source] ~= s then return end
					if not choice then cancel(fresh, s.source); return end
					if choice.none then
						deliver(fresh, s, nil, s.index); return
					end
					select_record(fresh, s, choice.position)
				end)
		else
			api.forms.open(cx, s.source, s.origin, { title = s.options.placeholder or "Choose an agent", description = s.message,
				description_tone = if s.phase == "failed" or s.phase == "changed" then "error" else nil, fields = {}, tag = s.token,
				actions = if s.phase == "ready" then { { id = "spawn", label = "Open SPAWN setup" } }
					elseif not s.adapter then { { id = "check_connection", label = "Check connection" } } else {} },
				function(fresh: any, _values: any, action: string)
					if pending[s.source] ~= s then return end
					cancel(fresh, s.source)
					if action == "spawn" and api.open_spawn then api.open_spawn(fresh, s.source) end
					if action == "check_connection" then api.control(fresh, s.source, "check_connection", s.origin) end
				end)
		end
		if not api.forms.active(s.source, s.token) then
			clear_usage(s, "unavailable"); pending[s.source] = nil
			api.notice(cx, s.source, s.origin.alias_nonce, "The native agent selector could not open on this host. Reopen ORCH+ and choose an agent again; nothing was launched.", "error")
			return false
		end
		s.drawn, s.presented_phase = fingerprint, s.phase
		return true
	end
	local function fail(cx: any, s: any, phase: string, message: string, catalog_failure: boolean?)
		clear_usage(s, "unavailable")
		local detail = message
		if #detail > 2048 then detail = detail:sub(1, (utf8.offset(detail, 501) or (#detail + 1)) - 1) .. "…" end
		local metadata = if catalog_failure then { context = "catalog", code = "catalog_unconfirmed", detail = detail } else nil
		if metadata then
			message, phase = "Couldn’t load your agents. No agent was started.", "failed"
		end
		s.phase, s.message, s.wait = phase, message, nil
		if s.load_done then
			local done = s.load_done; pending[s.source] = nil
			done(cx, nil, message, metadata)
			return
		end
		if s.ensure_done then
			local done = s.ensure_done; pending[s.source] = nil
			done(cx, nil, nil, message, metadata)
			return
		end
		show(cx, s)
		api.notice(cx, s.source, s.origin.alias_nonce, message, "error", nil, metadata)
	end
	local function issue_catalog(cx: any, s: any): boolean
		local wait = s.wait
		if wait.request_id then return true end
		local context = api.node(cx, s.source, "decision-context-result", "orchplus.decision")
		if not context or context.request_id ~= wait.context_request then return false end
		if not text(context.decision_context) then
			fail(cx, s, "changed", "The agent catalog's connection changed. Choose an agent again; nothing was started.", true)
			return false
		end
		local request = api.catalog(cx, s.source, wait.origin, wait.cursor, context.decision_context)
		if type(request) ~= "string" then
			fail(cx, s, "failed", "Could not load available agents. Finish the current operation or open SPAWN setup, then choose an agent again.", true)
			return false
		end
		wait.request_id = request
		return true
	end
	local function request_catalog(cx: any, s: any, cursor: any, selecting: boolean?)
		if s.adapter then
			local wait = { cursor = cursor, started = tern.now(), selecting = selecting == true }
			s.wait = wait
			s.adapter.request(cx, cursor, function(page: any, problem: string?)
				if pending[s.source] ~= s or s.wait ~= wait then return end
				wait.page, wait.problem = page, problem
			end)
			return
		end
		local origin = api.fresh(cx, s.source, s.origin)
		local started = tern.now()
		local request = api.decision(cx, s.source, origin, "catalog", { bytes = cursor })
		if type(request) ~= "string" then fail(cx, s, "changed", "The agent catalog's connection changed. Choose an agent again; nothing was started.", true); return end
		s.wait = { context_request = request, origin = origin, cursor = cursor, started = started, selecting = selecting == true }
		issue_catalog(cx, s)
	end
	clear_usage = function(s: any, status: string)
		-- Presentation may end; an issued read retains its immutable request and
		-- native endpoint until an exact late response can be drained.
		if s.usage and display_reads[s.source] == s.usage then s.usage.abandoned = true end
		s.readings, s.usage, s.usage_status = {}, nil, status
	end
	local function start_usage(s: any)
		if display_reads[s.source] then return end
		s.usage = { started = tern.now(), rows = {}, seen = {}, count = 0 }
		s.next_usage = tern.now() + POLL_MS
	end
	local function usage_step(cx: any, s: any)
		local reader = s.usage
		if not reader then return end
		if tern.now() - reader.started >= POLL_MS then clear_usage(s, "unavailable"); return end
		if not reader.pane then
			reader.pane = api.transport(cx, s.source, "usage.display", {}, s.origin)
			if not reader.pane then clear_usage(s, "unavailable"); return end
		end
		local node, bytes = surface(cx, reader.pane, "usage.display", "usage-display-response", "usage-display-response", 65536)
		if type(reader.pane) == "table" and reader.pane.peer_changed then
			clear_usage(s, "unavailable"); s.next_usage = tern.now(); return
		end
		if not node then clear_usage(s, "unavailable"); return end
		if not reader.request then
			local op = if not reader.revision then "snapshot" elseif reader.complete then "validate" else "page"
			local request = { version = 1, request_id = api.id(), op = op,
				revision = if op ~= "snapshot" then reader.revision else nil, cursor = if op == "page" then reader.cursor else nil }
			reader.request = request
			display_reads[s.source] = reader
			if not api.event(cx, reader.pane, { act = "usage.display", value = tern.json.encode(request) }) then
				display_reads[s.source] = nil
				clear_usage(s, "unavailable")
			end
			return
		end
		if bytes == nil then return end
		if type(bytes) ~= "string" or #bytes > 65536 then clear_usage(s, "unavailable"); return end
		local ok, response = pcall(tern.json.decode, bytes)
		if not ok or type(response) ~= "table" or response.version ~= 1 or response.display_only ~= true then clear_usage(s, "unavailable"); return end
		if response.request_id == reader.request.request_id and response.op == reader.request.op
			and type(response.ok) == "boolean" and type(response.status) == "string" and response.status ~= "pending" then
			if not api.ack(cx, reader.pane, "display") then return end
			display_reads[s.source] = nil
		end
		-- A revoked/error response clears old display even if another reader received it first.
		if response.ok == false and response.status ~= "pending" and response.status ~= "request_required" then
			clear_usage(s, if response.status == "export_disabled" or response.status == "display_disabled" or response.status == "disabled" then "disabled" else "unavailable"); return
		end
		local request = reader.request
		if response.request_id ~= request.request_id or response.op ~= request.op or response.status == "pending" then return end
		if response.ok ~= true or response.status ~= "current" or not text(response.revision)
			or (reader.revision and response.revision ~= reader.revision) or type(response.records) ~= "table" or #response.records > 16 then clear_usage(s, "unavailable"); return end
		if request.op == "validate" then
			if response.complete ~= true or response.next_cursor ~= nil or #response.records ~= 0 then clear_usage(s, "unavailable"); return end
			s.readings, s.usage, s.usage_status = reader.rows, nil, "current"
			return
		end
		reader.revision = response.revision
		for _, row in response.records do
			if type(row) ~= "table" or not text(row.record_id) or not text(row.definition_revision) or not text(row.namespace)
				or not text(row.host_key) or not integer(row.config_revision) or not integer(row.record_revision)
				or not text(row.scope_id) or not text(row.state) then clear_usage(s, "unavailable"); return end
			reader.count += 1
			if reader.count > MAX_RECORDS then clear_usage(s, "unavailable"); return end
			-- Different scopes with the same record ID are not ambiguous if only one exact source joins.
			local record = s.by_id[row.record_id]
			if record and bound(record, s.index, row) then
				if reader.seen[row.record_id] then clear_usage(s, "unavailable"); return end
				reader.seen[row.record_id], reader.rows[row.record_id] = true, row
			end
		end
		local offset = request.cursor or 0
		if response.complete == true then
			if response.next_cursor ~= nil then clear_usage(s, "unavailable"); return end
			reader.complete = true
		elseif response.complete == false and #response.records == 16 and response.next_cursor == offset + 16 and response.next_cursor < MAX_RECORDS then
			reader.cursor = response.next_cursor
		else clear_usage(s, "unavailable"); return end
		reader.request = nil
	end
	local function catalog_step(cx: any, s: any)
		local wait = s.wait
		if not wait then return end
		if tern.now() - wait.started > TIMEOUT_MS then fail(cx, s, "failed", "Loading available agents timed out.", true); return end
		local page
		if s.adapter then
			if wait.problem then fail(cx, s, "failed", wait.problem, true); return end
			page = wait.page
			if not page then return end
		else
			if not issue_catalog(cx, s) then return end
			local data = api.snapshot(cx, s.source, wait.action_id)
			if not data then return end
			if not wait.action_id then
				local receipt = if data.command_result and data.command_result.request_id == wait.request_id then data.command_result
					elseif data.driver_result and data.driver_result.request_id == wait.request_id then data.driver_result
					elseif data.result and data.result.request_id == wait.request_id then data.result else nil
				if not receipt then return end
				if receipt.ok ~= true then fail(cx, s, "failed", "The catalog request was refused: " .. tostring(receipt.message or receipt.code), true); return end
				wait.action_id = receipt.action_id
				if not wait.action_id then return end
				data = api.snapshot(cx, s.source, wait.action_id)
			end
			local outcome = if data then data.result else nil
			if not outcome or outcome.action_id ~= wait.action_id then return end
			if outcome.code == "pending" then return end
			-- Concurrent commits can refuse a claim or result delivery while the
			-- driver continues the same live read. Neither receipt is a catalog failure.
			if outcome.code == "stale_revision" and (outcome.command == "result"
				or (outcome.command == "claim" and data.action and data.action.action_id == wait.action_id)) then return end
			if outcome.ok == false or outcome.code == "bridge_rejected" or outcome.code == "transport_backpressure" or outcome.code == "effect_uncertain" then
				fail(cx, s, "failed", "The catalog outcome was not confirmed: " .. tostring(outcome.message or outcome.code), true); return
			end
			if outcome.code ~= "bridge_committed" then return end
			page = index(cx, s.source)
		end
		if not catalog_valid(page) then fail(cx, s, "missing", "Available agents could not be read.", true); return end
		if s.index and not same_catalog(s.index, page) then fail(cx, s, "changed", "Available agents changed while the picker was open.", true); return end
		s.wait = nil
		if wait.selecting then
			local selected
			for _, row in page.records do if row.id == s.selection.id then selected = row; break end end
			if not selected or not same_record(selected, s.selection) or not eligible(selected, s.options) then
				fail(cx, s, "unavailable", "The selected agent is unavailable or changed. Choose an agent again; no other agent was substituted."); return
			end
			local record = table.clone(selected); record.catalog_revision = page.revision
			if s.ensure_done then
				local done, catalog = s.ensure_done, s.full_catalog
				pending[s.source] = nil
				done(cx, record, catalog, nil)
				return
			end
			deliver(cx, s, record, page)
			return
		end
		s.index = page
		for _, row in page.records do
			if type(row) ~= "table" or not text(row.id) or s.seen[row.id] then fail(cx, s, "failed", "The agent catalog contains inconsistent pages.", true); return end
			s.seen[row.id] = true; s.count += 1
			if s.count > MAX_RECORDS then fail(cx, s, "failed", "The agent catalog exceeds the supported size.", true); return end
			table.insert(s.all_records, table.clone(row))
			if eligible(row, s.options) then
				local record = table.clone(row); record.catalog_revision = page.revision
				s.by_id[row.id], s.pages[row.id] = record, { cursor = wait.cursor }
				table.insert(s.records, record)
			end
		end
		if page.next_cursor ~= nil then
			local cursor = page.next_cursor
			if type(cursor) ~= "table" or cursor.revision ~= page.revision or not integer(cursor.index) or cursor.index < 2
				or cursor.index <= (if wait.cursor then wait.cursor.index else 1) or s.page_count >= MAX_RECORDS then
				fail(cx, s, "failed", "The agent catalog paging response is inconsistent.", true); return
			end
			s.page_count += 1; request_catalog(cx, s, cursor); return
		end
		if s.load_done then
			local catalog = table.clone(page)
			catalog.records, catalog.next_cursor = s.all_records, nil
			loaded[s.source] = { catalog = catalog, by_id = s.by_id, pages = s.pages }
			local done = s.load_done; pending[s.source] = nil
			done(cx, catalog, nil)
			return
		end
		s.phase = "ready"
		s.message = if #s.records == 0 then "No agents are ready for this role. Open SPAWN to prepare an agent; saved accounts have not been removed."
			else "Choose an agent. This list shows saved accounts and current pane names. Usage is shown when available."
		if #s.records > 0 then start_usage(s) end
		show(cx, s)
	end
	local function tick(cx: any)
		for source, reader in display_reads do
			if not reader.abandoned then continue end
			local node, bytes = surface(cx, reader.pane, "usage.display", "usage-display-response", "usage-display-response", 65536)
			-- The helper restarted: the old incarnation's reply can never arrive, so the retained read is released.
			if type(reader.pane) == "table" and reader.pane.peer_changed then display_reads[source] = nil; continue end
			if not node or type(bytes) ~= "string" or #bytes > 65536 then continue end
			local ok, response = pcall(tern.json.decode, bytes)
			if ok and type(response) == "table" and response.version == 1 and response.display_only == true
				and response.request_id == reader.request.request_id and response.op == reader.request.op
				and type(response.ok) == "boolean" and type(response.status) == "string" and response.status ~= "pending"
				and api.ack(cx, reader.pane, "display") then display_reads[source] = nil end
		end
		for source, s in pending do
			if not owned(cx, s) then
				clear_usage(s, "unavailable"); pending[source] = nil
				if s.phase == "selecting" then api.notice(cx, source, s.origin.alias_nonce, "The agent selection was interrupted before its catalog check finished. Nothing was launched.", "error") end
				continue
			end
			if not current(cx, s) then
				if s.load_done or s.ensure_done then fail(cx, s, "changed", "The catalog's controller context changed; nothing was selected.")
				else cancel(cx, source) end
				continue
			end
			if s.hidden then s.hidden = nil; show(cx, s) end
			local ok = pcall(function()
				catalog_step(cx, s)
				if pending[source] ~= s or s.phase ~= "ready" then return end
				local observed = catalog_index(cx, s)
				if not catalog_valid(observed) or not same_catalog(observed, s.index) then fail(cx, s, "changed", "Available agents changed. Choose an agent again; nothing was started."); return end
				if #s.records > 0 and tern.now() >= s.next_usage then
					if s.usage ~= nil then clear_usage(s, "unavailable") end
					start_usage(s)
				end
				usage_step(cx, s)
				show(cx, s)
			end)
			if not ok and pending[source] == s then fail(cx, s, "failed", "The agent picker could not read its native view. Reopen it; nothing was started.") end
		end
	end
	select_record = function(cx: any, s: any, position: any)
		if not current(cx, s) or s.phase ~= "ready" then cancel(cx, s.source); return end
		local record = if integer(position) then s.records[position] else nil
		if not record then return end
		local observed = catalog_index(cx, s)
		if not catalog_valid(observed) or not same_catalog(observed, s.index) then
			fail(cx, s, "changed", "Available agents changed. Choose an agent again; nothing was started."); return
		end
		s.selection, s.phase, s.message = record, "selecting", "Checking that your selected agent is still available…"
		clear_usage(s, "unavailable")
		if not show(cx, s) then return end
		request_catalog(cx, s, s.pages[record.id].cursor, true)
	end
	local function start(cx: any, source: number, origin: any, options: any, done: any, load_done: any?)
		local adapter = if options then options.catalog_adapter else nil
		if not (if adapter then adapter.current(cx) else api.current(cx, source, origin)) then
			if load_done then load_done(cx, nil, "The catalog's controller context is unavailable.") end
			return
		end
		cancel(cx, source)
		loaded[source] = nil
		local s = { source = source, origin = origin, adapter = adapter, options = options or {}, done = done, load_done = load_done,
			token = "ORCH+ agent picker " .. api.id(), phase = "loading", message = "Loading available agents…",
			records = {}, all_records = {}, by_id = {}, pages = {}, seen = {}, count = 0, page_count = 1,
			readings = {}, usage_status = "unavailable", next_usage = 0 }
		pending[source] = s
		if not load_done and not show(cx, s) then return end
		if not adapter and index(cx, source) == nil then fail(cx, s, "missing", "Available agents could not be read.", true); return end
		request_catalog(cx, s, nil)
	end
	return {
		pick = function(cx: any, source: number, origin: any, options: any, done: any) start(cx, source, origin, options, done, nil) end,
		load = function(cx: any, source: number, origin: any, done: any) start(cx, source, origin, {}, nil, done) end,
		ensure = function(cx: any, source: number, origin: any, record_id: string, done: any)
			local saved = loaded[source]
			if not api.current(cx, source, origin) or not saved or not saved.by_id[record_id]
				or not same_catalog(saved.catalog, index(cx, source)) then
				done(cx, nil, nil, "The selected agent is unavailable or changed. Load available agents again; nothing was started.")
				return
			end
			cancel(cx, source)
			local s = { source = source, origin = origin, options = {}, ensure_done = done,
				selection = saved.by_id[record_id], index = saved.catalog, full_catalog = saved.catalog, phase = "selecting" }
			pending[source] = s
			request_catalog(cx, s, saved.pages[record_id].cursor, true)
		end,
		tick = tick, cancel = cancel, active = function(): boolean return next(pending) ~= nil end,
	}
end
return M
