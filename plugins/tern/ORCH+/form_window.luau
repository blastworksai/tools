--!strict
-- A native pane is a draft carrier, never an execution or policy authority.
local M = {}
local MAX = 262144
-- Native draft JSON uses the form carrier's bound, not report-files-v1's smaller
-- transport, object-member and string limits. It carries no execution authority.
local function decode(bytes: any): any?
	if type(bytes) ~= "string" or #bytes > MAX then return nil end
	local ok, value = pcall(tern.json.decode, bytes); return if ok and type(value) == "table" then value else nil
end
function M.new(api: any): any
	local forms: any = {}; local panes: any = {}
	local function binding(cx: any, source: number, connected: boolean?): any?
		local pane, host = cx.session:pane(source), api.host(cx, source)
		local membership = api.membership(cx)
		-- Pane identifiers stay in the native API's representation; never round-trip
		-- attached-host pane ids through JSON or tonumber to find a draft.
		if not pane or pane.parked or pane.tab == nil or membership[pane.tab] == nil or not host
			or connected ~= false and host.state ~= "connected" then return nil end
		return { window_key = cx:window_key(), native_session_id = tostring(membership[pane.tab]), window_host_id = tostring(host.id) }
	end
	local function current(cx: any, s: any): boolean
		local b = binding(cx, s.source)
		if not b or not api.same(b, s.binding) then return false end
		if cx.hosts and (tostring(cx.hosts:current().id) ~= b.window_host_id or cx.hosts:current().state ~= "connected") then return false end
		if cx.sessions and tostring(cx.sessions:current().id) ~= b.native_session_id then return false end
		return not api.current or api.current(cx, s.source, s.origin)
	end
	local function carrier(cx: any, s: any): boolean
		local pane = cx.session:pane(s.pane)
		return pane ~= nil and pane.block == "orchplus.form" and api.same(binding(cx, s.pane, false), s.binding)
	end
	local function receipt(cx: any, s: any): any?
		if not carrier(cx, s) then return nil end
		local _, bytes = api.surface(cx, s.pane, "orchplus.form", "orchplus.form.result", "form-result", MAX)
		local value = decode(bytes)
		return if value and value.form_nonce == s.spec.form_nonce then value else nil
	end
	local function event(cx: any, pane: number, act: string, value: any)
		cx.session:event(pane, { ev = "action", id = "main", act = act, value = tern.json.encode(value) })
	end
	local function update(cx: any, source: number, value: any): boolean
		-- ACKs change only this nonce-bound draft. The consumer, not its carrier,
		-- validates current source authority before issuing any write.
		local s = forms[source]; if not s or not receipt(cx, s) then return false end
		if value.choices ~= nil then
			for key in value do if key ~= "choices" then return false end end
			if s.busy or s.delivered or type(value.choices) ~= "table" then return false end
			local choice = s.spec.fields[1]
			if not choice or choice.kind ~= "choice_list" or #choice.options ~= #value.choices then return false end
			local options = {}
			for i, row in value.choices do
				if type(row.choice_key) ~= "string" or row.choice_key ~= choice.options[i].choice_key then return false end
				table.insert(options, { value = choice.options[i].value, choice_key = row.choice_key, label = row.label or row.title,
					detail = row.detail, icon = row.icon, group = row.group, disabled = row.disabled, disabled_reason = row.disabled_reason })
			end
			local payload = { form_nonce = s.spec.form_nonce, request_id = s.spec.request_id, options = options }
			if #tern.json.encode(payload) > MAX then return false end
			for i, option in options do choice.options[i] = option end
			event(cx, s.pane, "form-refresh", payload); return true
		end
		local next_id = api.id()
		local payload = { form_nonce = s.spec.form_nonce, request_id = s.spec.request_id, next_request_id = next_id }
		for key, entry in value do payload[key] = entry end
		-- Rotate the request binding before accepting another submission. A delayed surface
		-- containing the acknowledged result cannot repeat a write while its ACK is in flight.
		s.busy = value.busy == true
		event(cx, s.pane, "form-ack", payload); s.spec.request_id = next_id; s.delivered = false; return true
	end
	local function open(cx: any, source: number, origin: any, spec: any, done: any): number?
		local b = binding(cx, source)
		if not b then cx:toast("error", "ORCH+", "The source pane is not connected. No form was opened."); return nil end
		if origin and (origin.window_key ~= nil and origin.window_key ~= b.window_key
			or origin.window_host_id ~= nil and tostring(origin.window_host_id) ~= b.window_host_id
			or origin.native_session_id ~= nil and tostring(origin.native_session_id) ~= b.native_session_id) then return nil end
		if cx.hosts and (cx.hosts:current().state ~= "connected" or tostring(cx.hosts:current().id) ~= b.window_host_id)
			or cx.sessions and tostring(cx.sessions:current().id) ~= b.native_session_id then return nil end
		local retained = {}; for k, v in spec do retained[k] = v end
		retained.form_nonce = api.id(); retained.request_id = api.id()
		local bytes = tern.json.encode(retained)
		if #bytes > MAX then cx:toast("error", "ORCH+", "This complete form exceeds the native size bound."); return nil end
		local pane = panes[source]
		local old = if pane then cx.session:pane(pane) else nil
		local host = if old then api.host(cx, pane) else nil
		local membership = api.membership(cx)
		if not old or old.parked or old.block ~= "orchplus.form" or not host or host.state ~= "connected"
			or tostring(host.id) ~= b.window_host_id or old.tab == nil or tostring(membership[old.tab]) ~= b.native_session_id then pane = nil end
		if pane then event(cx, pane, "form-open", retained); cx.layout:focus(pane)
		else pane = cx:new_block("orchplus.form", { bytes }, "beside", { target = source, focus = true }) end
		if not pane then cx:toast("error", "ORCH+", "The native form block is unavailable on this host. Update ORCH+ on that host."); return nil end
		panes[source] = pane
		forms[source] = { source = source, pane = pane, origin = origin, binding = b, spec = retained, done = done, delivered = false }
		return pane
	end
	local function cancel(cx: any, source: number)
		local s = forms[source]; if not s then return end
		local pane = cx.session:pane(s.pane)
		if not pane then forms[source] = nil; panes[source] = nil; return end
		-- A numeric pane id or matching block kind alone is not ownership. The
		-- current native carrier AND its exact live draft nonce must still agree.
		local value = receipt(cx, s)
		if not value then return end
		forms[source] = nil; panes[source] = nil
		event(cx, s.pane, "form-ack", { form_nonce = s.spec.form_nonce, request_id = value.request_id,
			closed = true, notice = "Editing finished. Return to the source pane to continue." })
		cx.layout:close(s.pane)
		if current(cx, s) then cx.layout:focus(source) end
	end
	local function deliver(cx: any, source: number, opts: any, done: any, value: any)
		local retained = forms[source]
		if not retained then return end
		update(cx, source, { busy = true, notice = "Selection received. Waiting for the next step…" })
		done(cx, value)
		-- A synchronous submenu replaces this exact record and reuses its pane. An
		-- asynchronous owner opts in to retaining the disabled pane until it settles.
		if forms[source] == retained and opts.retain ~= true then cancel(cx, source) end
	end
	local function choose(cx: any, source: number, origin: any, opts: any, done: any): number?
		local options = {}; local items = table.clone(opts.items or {}); local count = 0
		for i, row in items do count += 1; if count > 512 then break end
			table.insert(options, { value = tostring(i), label = row.label or row.title or tostring(i), disabled = row.disabled,
				icon = row.icon, detail = row.detail, group = row.group, disabled_reason = row.disabled_reason, choice_key = row.choice_key })
		end
		return open(cx, source, origin, { tag = opts.tag, title = opts.title or opts.placeholder or "Choose", description = opts.description,
			fields = { { id = "choice", kind = "choice_list", label = opts.placeholder or "Choice", options = options, action = "choose" } },
			actions = { { id = "choose", submit = true, hidden = true, disabled = #options == 0 } } }, function(fresh: any, values: any, action: string)
			if action == "cancel" then deliver(fresh, source, {}, done, nil); return end
			local i = if values then tonumber(values.choice) else nil
			if not i or i % 1 ~= 0 or not options[i] or not items[i] or options[i].disabled then update(fresh, source, { errors = { choice = "Choose an available item." } }); return end
			deliver(fresh, source, opts, done, items[i])
		end)
	end
	local function input(cx: any, source: number, origin: any, opts: any, done: any): number?
		return open(cx, source, origin, { tag = opts.tag, title = opts.title or opts.placeholder or "Enter a value", description = opts.description,
			fields = { { id = "text", label = opts.label or opts.placeholder or "Value", kind = if opts.multiline then "editor" else "text", value = opts.value or "" } },
			actions = { { id = "submit", label = opts.confirm_label or "Continue", submit = true } } }, function(fresh: any, values: any, action: string)
			if action == "cancel" then deliver(fresh, source, {}, done, nil); return end
			if not values or type(values.text) ~= "string" then update(fresh, source, { errors = { text = "Enter a text value." } }); return end
			if opts.validate then
				local problem = opts.validate(values.text)
				if problem then update(fresh, source, { errors = { text = tostring(problem) } }); return end
			end
			deliver(fresh, source, opts, done, values.text)
		end)
	end
	local function browse(cx: any, source: number, s: any, result: any)
		local item
		for _, entry in s.spec.fields do if entry.id == result.field then item = entry; break end end
		if result.action ~= "browse" or not item or item.kind ~= "path" or item.scope ~= "desktop" or item.hidden or item.readonly or item.disabled then
			update(cx, source, { notice = "This path chooser is unavailable. Your draft is retained.", busy = false }); return
		end
		local path = if type(result.path) == "string" and result.path ~= "" then result.path else item.browse_root or tern.plugin.data
		-- This is the window VM: these entries can only come from the computer
		-- running Tern. Return them to the same inline chooser, never a host fallback.
		local ok, entries = pcall(tern.fs.list, path)
		if not ok and result.browse_mode == "initial" then
			local parent = path:gsub("[/\\]+$", ""):match("^(.*)[/\\][^/\\]+$")
			if parent == "" then parent = "/" elseif parent and parent:match("^%a:$") then parent ..= "/" end
			if parent then
				local listed, rows = pcall(tern.fs.list, parent)
				if listed then path = parent; ok = true; entries = rows end
			end
		end
		if not ok then
			if result.browse_mode == "entry" then
				update(cx, source, { busy = false, values = { [item.id] = path }, browser = false })
			else
				update(cx, source, { busy = false, errors = { [item.id] = "Cannot list this window-computer folder: " .. tostring(entries):sub(1, 200) } })
			end
			return
		end
		local rows = {}; for i, name in entries do if i > 128 then break end; table.insert(rows, name) end
		update(cx, source, { busy = false, browser = { id = item.id, path = path, rows = rows, clipped = #entries > 128, scope = "desktop" } })
	end
	local function tick(cx: any)
		for source, s in forms do
			local result = receipt(cx, s)
			if not result then continue end
			if result.phase == "cancelled" and result.action == "cancel" then
				-- receipt() has verified the carrier and draft nonce. A lost ACK
				-- may strand its old request id; cancellation authorizes no write.
				-- Local draft cancellation is not a source operation. A moved,
				-- reloaded or unavailable source must never trap its own editor.
				if current(cx, s) then s.done(cx, nil, "cancel", result) end
				if forms[source] == s then cancel(cx, source) end
				continue
			end
			if result.request_id ~= s.spec.request_id then continue end
			if result.phase == "restored" then
				if current(cx, s) then
					event(cx, s.pane, "form-resume", { form_nonce = s.spec.form_nonce, request_id = s.spec.request_id, busy = s.busy == true })
					s.delivered = false
				end
				continue
			end
			if s.delivered then continue end
			if result.phase == "browse" then s.delivered = true; browse(cx, source, s, result); continue end
			if result.phase ~= "submitted" and result.phase ~= "action" then continue end
			if not current(cx, s) then
				update(cx, source, { busy = false, notice = "The source pane or native connection changed. No operation was sent. Your draft is retained; reopen current settings before saving." })
				continue
			end
			local allowed = false
			for _, action in s.spec.actions or { { id = "save", submit = true } } do
				if action.id == result.action and not action.disabled and (action.submit == true) == (result.phase == "submitted") then allowed = true end
			end
			if not allowed or result.phase == "submitted" and type(result.values) ~= "table" then
				update(cx, source, { busy = false, notice = "This form action is unavailable or incomplete. Nothing was sent; your draft is retained." }); continue
			end
			s.delivered = true
			s.done(cx, if result.phase == "submitted" then result.values else nil, result.action, result)
		end
	end
	return { open = open, choose = choose, input = input, tick = tick, cancel = cancel,
		active = function(source: number, tag: string?): boolean
			local s = forms[source]; return s ~= nil and (tag == nil or s.spec.tag == tag)
		end,
		-- The open form's name, for a notice that says why work is waiting.
		title = function(source: number): string?
			local s = forms[source]; if not s then return nil end
			local name = s.spec.title or s.spec.placeholder
			return if type(name) == "string" and name ~= "" then name else nil
		end, update = update,
		focus = function(cx: any, source: number): boolean
			local s = forms[source]; if not s or not current(cx, s) then return false end
			local pane = cx.session:pane(s.pane)
			if not pane or pane.parked or pane.block ~= "orchplus.form" or not api.same(binding(cx, s.pane), s.binding) then return false end
			cx.layout:focus(s.pane); return true
		end }
end
return M
