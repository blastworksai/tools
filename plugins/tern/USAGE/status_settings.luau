--!strict
-- The status-bar section of USAGE Configuration. The window owns the preference and the
-- roster; it pushes a bounded snapshot to each configuration block (`ACTION` event), and the
-- block reports a click back as a `usage://status/...` link the window validates against its
-- current roster. The block never reads or writes the preference itself, so it also works in a
-- window attached to a remote host.
local presentation = require("./presentation")
local prefs_module = require("./status_preferences")
local M = {}
M.ACTION = "status_state"
M.MASTER_LABEL = "Show usage statistics in status bar?"
M.HEADING = "Per-Agent Status Bar selection:"
M.WARNING = "Don’t overcrowd your status bar."
M.OMP_REASON = "No independent usage allowance"
M.FULL_REASON = "Selection full"
M.MAX_STATE_BYTES = 65536

-- What the window pushes: master state, every current account with its choice, OMP records.
function M.snapshot(prefs: any, model: any): any
	local set = prefs_module.selected_set(prefs)
	local accounts = tern.json.array()
	local chosen = 0
	local rows = presentation.ordered_accounts(model.accounts)
	for _, row in rows do
		if prefs_module.row_selected(set, row) then chosen += 1 end
	end
	for _, row in rows do
		if #accounts >= prefs_module.MAX_ROSTER then break end
		if #row.id <= prefs_module.MAX_ID then
			local picked = prefs_module.row_selected(set, row)
			table.insert(accounts, { id = row.id, label = presentation.status_label(row), selected = picked,
				full = (not picked) and chosen >= prefs_module.MAX_SELECTED })
		end
	end
	local consumers = tern.json.array()
	for _, consumer in model.consumers or {} do
		if #consumers >= prefs_module.MAX_ROSTER then break end
		table.insert(consumers, { id = consumer.id, label = "OMP: " .. tostring(consumer.label) })
	end
	return { version = 1, enabled = prefs.enabled, pending = not prefs.migration_complete, accounts = accounts, consumers = consumers }
end

local function text(value: any, maximum: number): boolean
	return type(value) == "string" and #value > 0 and #value <= maximum and not value:find("%c")
end

-- A pushed snapshot, validated and bounded; nil when malformed.
function M.decode(raw: any): any?
	if type(raw) ~= "string" or #raw > M.MAX_STATE_BYTES then return nil end
	local ok, value = pcall(tern.json.decode, raw)
	if not ok or type(value) ~= "table" or value.version ~= 1 or type(value.enabled) ~= "boolean"
		or type(value.pending) ~= "boolean" or type(value.accounts) ~= "table" or type(value.consumers) ~= "table"
		or #value.accounts > prefs_module.MAX_ROSTER or #value.consumers > prefs_module.MAX_ROSTER then return nil end
	local accounts, consumers = {}, {}
	for _, row in ipairs(value.accounts) do
		if type(row) ~= "table" or not text(row.id, prefs_module.MAX_ID) or not text(row.label, 2048)
			or type(row.selected) ~= "boolean" or type(row.full) ~= "boolean" then return nil end
		table.insert(accounts, { id = row.id, label = row.label, selected = row.selected, full = row.full })
	end
	for _, row in ipairs(value.consumers) do
		if type(row) ~= "table" or not text(row.id, prefs_module.MAX_ID) or not text(row.label, 2048) then return nil end
		table.insert(consumers, { id = row.id, label = row.label })
	end
	return { enabled = value.enabled, pending = value.pending, accounts = accounts, consumers = consumers }
end

function M.master_url(on: boolean): string
	return "usage://status/master/" .. (if on then "on" else "off")
end

function M.account_url(id: string, on: boolean, encode: (string) -> string): string
	return "usage://status/account/" .. encode(id) .. "/" .. (if on then "on" else "off")
end

-- Window side: a status link's path after `usage://status/`, parsed.
-- Returns { kind = "sync" | "master" | "account", on = boolean?, id = string? } or nil.
function M.parse_link(path: string, decode: (string) -> string?): any?
	if path == "sync" then return { kind = "sync" } end
	local master = path:match("^master/(%a+)$")
	if master == "on" or master == "off" then return { kind = "master", on = master == "on" } end
	local encoded, flag = path:match("^account/(.+)/(%a+)$")
	if encoded ~= nil and (flag == "on" or flag == "off") then
		local id = decode(encoded)
		if id ~= nil then return { kind = "account", id = id, on = flag == "on" } end
	end
	return nil
end

local function checkbox(name: string, key: string, checked: boolean, disabled: boolean, label: string, value: string?, reason: string?): any
	local ui = tern.ui
	local attrs: { [string]: any } = { ["aria-label"] = label }
	local children = {
		ui.el("input", { type = "checkbox", name = name, value = value, id = key, checked = checked, disabled = disabled, attrs = attrs }),
		ui.el("span", { text = label }),
	}
	if reason ~= nil then table.insert(children, ui.el("span", { text = " · " .. reason })) end
	return ui.el("label", { attrs = { role = "usage-status-row" } }, children)
end

-- `status` is a decoded snapshot, or nil before the window has pushed one.
function M.view(status: any?): any
	local ui = tern.ui
	local children: { any } = {}
	if status == nil then
		table.insert(children, ui.text(ui.span("Status bar", "strong")))
		table.insert(children, ui.text(ui.span("Loading status bar settings…", "muted")))
		return ui.node("col", { role = "usage-status-settings", gap = "xs" }, children)
	end
	table.insert(children, checkbox("status_master", "usage-status-master", status.enabled, false, M.MASTER_LABEL, nil, nil))
	table.insert(children, ui.text(ui.span(M.HEADING, "strong")))
	table.insert(children, ui.text(ui.span(M.WARNING, "muted")))
	if status.pending then
		table.insert(children, ui.text(ui.span("Waiting for the account list to carry over your earlier status bar choice.", "muted")))
	end
	for index, row in status.accounts do
		table.insert(children, checkbox("status_account", "usage-status-account-" .. tostring(index), row.selected,
			(not status.enabled) or status.pending or (row.full and not row.selected), row.label, row.id,
			if row.full and not row.selected then M.FULL_REASON else nil))
	end
	for index, row in status.consumers do
		table.insert(children, checkbox("status_omp", "usage-status-omp-" .. tostring(index), false, true, row.label, nil, M.OMP_REASON))
	end
	if #status.accounts == 0 and #status.consumers == 0 then
		table.insert(children, ui.text(ui.span(presentation.EMPTY_TEXT, "muted")))
	end
	return ui.node("col", { role = "usage-status-settings", gap = "xs" }, children)
end

-- Block side: a `change` event from a status control, as the link it asks the window for.
-- Controls that are disabled never reach here, and the window revalidates anyway.
function M.link_for_event(event: any, encode: (string) -> string): string?
	if event.ev ~= "change" or type(event.checked) ~= "boolean" then return nil end
	if event.name == "status_master" then return M.master_url(event.checked) end
	if event.name == "status_account" and type(event.value) == "string" and #event.value > 0 then
		return M.account_url(event.value, event.checked, encode)
	end
	return nil
end

return M
