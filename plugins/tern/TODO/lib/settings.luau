-- TODO settings: closed model, eligibility and the pane view. CodexBWAI; MIT.
-- Pure apart from load/save (plugin KV). The window owns every effect.
local settings = {}

settings.KEY = "settings"
settings.EMPTY = "No TODO source is enabled. Turn on the Tern Board option or enable Glitch integration in TODO Settings."
settings.GLITCH_NOTE = "/glitch-plan progress will be shown in the TODO pane."
-- A fresh installation: Glitch off, native board on, no sync, nothing attached.
settings.DEFAULTS = { schema = 1, glitch = false, board = true, sync = false }

-- Closed validation with safe defaults: unknown keys are dropped, a wrong type falls back.
function settings.normalize(raw: any): any
    local out = { schema = 1, glitch = settings.DEFAULTS.glitch, board = settings.DEFAULTS.board, sync = settings.DEFAULTS.sync }
    if type(raw) ~= "table" then return out end
    for _, key in { "glitch", "board", "sync" } do
        if type(raw[key]) == "boolean" then out[key] = raw[key] end
    end
    local attach = raw.attach
    if type(attach) == "number" and attach >= 1 and attach <= 9007199254740991 and attach % 1 == 0 then out.attach = attach end
    return out
end

-- Storage: one KV key per field ("settings.<field>"), over the legacy whole-object key
-- "settings" that earlier versions wrote. Two windows changing different fields therefore
-- never overwrite each other: a save writes only the fields its change touched.
-- A cleared attach is stored as false (a missing key would fall back to the legacy object).
local FIELDS = { "glitch", "board", "sync", "attach" }
local function fieldKey(name: string): string return settings.KEY .. "." .. name end

function settings.load(kv: any): any
    local ok, raw = pcall(kv.get, settings.KEY)
    local merged = {}
    if ok and type(raw) == "table" then for key, value in raw do merged[key] = value end end
    for _, name in FIELDS do
        local fok, value = pcall(kv.get, fieldKey(name))
        if fok and value ~= nil then merged[name] = if value == false and name == "attach" then nil else value end
    end
    return settings.normalize(merged)
end
-- `before` is the settings the change started from. With it, only fields that differ from
-- `before` are written; without it every field is written.
function settings.save(kv: any, value: any, before: any?): boolean
    local after = settings.normalize(value)
    local base = if before ~= nil then settings.normalize(before) else nil
    return (pcall(function()
        for _, name in FIELDS do
            if base == nil or after[name] ~= base[name] then
                local stored = after[name]
                if name == "attach" and stored == nil then stored = false end
                kv.set(fieldKey(name), stored)
            end
        end
    end))
end

-- The one source this configuration shows: "glitch-sync" | "glitch" | "native-board" | "none".
function settings.mode(s: any): string
    if s.glitch then return if s.sync then "glitch-sync" else "glitch" end
    return if s.board then "native-board" else "none"
end
-- Only the native board needs a session on this computer: it opens TODO.md in the session's own folder,
-- and cx.board is desktop/local only. Glitch sync writes its board into this plugin's own data folder, so
-- it never depends on where the session runs; turning sync on must not change which sessions can be attached.
function settings.needsLocal(s: any): boolean
    return settings.mode(s) == "native-board"
end

-- candidates: { pane, label, detail?, remote, live } built by the window from current panes.
-- Stale, closed and ineligible panes never come back; remote panes are left out only for the native board.
function settings.eligible(s: any, candidates: { any }): { any }
    local out, needsLocal = {}, settings.needsLocal(s)
    if settings.mode(s) == "none" then return out end
    for _, c in candidates do
        if c.live and not (needsLocal and c.remote) then table.insert(out, c) end
    end
    return out
end
-- How many live sessions the current mode leaves out (so the pane can say why the list is short).
function settings.hiddenCount(s: any, candidates: { any }): number
    if settings.mode(s) == "none" then return 0 end
    local live = 0
    for _, c in candidates do if c.live then live += 1 end end
    return live - #settings.eligible(s, candidates)
end
-- Multi-device: the window reads a remote session's plan through the plan view's own pane (lib/plan_read). When it
-- cannot, the one honest thing to say is the limit.
settings.REMOTE_ONLY = "Board sync for this session works only when the session runs on this window's machine."
settings.TOO_LARGE = "This plan is too large to sync to the board."
settings.REMOTE_TOO_LARGE = "This plan is too large to read from another machine. " .. settings.REMOTE_ONLY
settings.NO_VIEW = "No plan view is open for this session. Pick the session again under Attach to to open it."
-- Should a plan view that finds no published plan keep waiting (instead of closing with a notice)?
-- Only when sync is on and this view serves the attached session: the plan may be published later, and the
-- board must then start without the owner selecting the session again. `bound` = the session this view was opened for.
function settings.waitsForPublication(s: any, bound: any): boolean
    return settings.mode(s) == "glitch-sync" and type(bound) == "number" and s.attach == bound
end
-- Why sync is not producing a board right now, in plain words; nil when nothing blocks it.
-- target: the attached candidate (or nil); view: "none" | "match" | "other"; planSeen: this window holds a valid plan;
-- why: with no plan, "too_large" (the view's plan passes the node cap) or "unreadable" (the view's node could not be read).
function settings.syncBlocker(s: any, target: any, view: string, planSeen: boolean, why: string?): string?
    if not s.attach then return "Sync is on. Pick a session under Attach to; its plan goes to the board." end
    if not target then return "The attached session is no longer open. Pick another under Attach to." end
    if view == "other" then return "This tab's plan view serves another session. Select the session again in TODO Settings." end
    if view ~= "match" then return settings.NO_VIEW end
    if not planSeen then
        if why == "too_large" then return if target.remote then settings.REMOTE_TOO_LARGE else settings.TOO_LARGE end
        if why == "unreadable" and target.remote then return settings.REMOTE_ONLY end
        return "Waiting for this session to publish a plan (/glitch-plan)."
    end
    return nil
end
function settings.isEligible(s: any, candidates: { any }, pane: any): boolean
    if type(pane) ~= "number" then return false end
    for _, c in settings.eligible(s, candidates) do if c.pane == pane then return true end end
    return false
end

-- Pure transition for a canvas action. A control never changes more than its own field, and an
-- attach that the new mode makes ineligible is dropped here, not after the user selects it.
function settings.apply(s: any, act: string, value: string?, candidates: { any }): any
    local out = settings.normalize(s)
    out.attach = s.attach
    local on = value == "on"
    if act == "glitch" then out.glitch = on
    elseif act == "board" then out.board = on
    elseif act == "sync" then out.sync = on
    elseif act == "attach" then out.attach = tonumber(value) end
    if not settings.isEligible(out, candidates, out.attach) then out.attach = nil end
    return out
end

local function choice(ui: any, label: string, current: boolean, act: string): any
    local function button(text: string, selected: boolean, value: string): any
        return ui.el("button", { text = (if selected then "● " else "○ ") .. text, actions = { click = act .. "=" .. value }, attrs = { ["aria-pressed"] = if selected then "true" else "false" } })
    end
    return ui.row({ ui.text({ ui.span(label, "strong") }), button("On", current, "on"), button("Off", not current, "off") })
end

-- The settings pane. `candidates` are already filtered by settings.eligible.
-- extra (optional): hidden = sessions the mode leaves out; board = { title, path } of the synced board.
function settings.draw(ui: any, s: any, eligible: { any }, status: string?, extra: any?): any
    local hidden = if extra and type(extra.hidden) == "number" then extra.hidden else 0
    local nodes = {}
    table.insert(nodes, ui.text({ ui.span("Attach to", "strong") }))
    if #eligible == 0 then
        local empty = "No eligible session is open for this mode."
        if settings.mode(s) == "none" then empty = settings.EMPTY
        elseif hidden > 0 then empty = "No session on this computer is open. " .. string.format("%.0f", hidden) .. " session(s) on other hosts cannot be used: this board is a file in the session's own folder, on this computer." end
        table.insert(nodes, ui.text({ ui.span(empty, "muted") }))
    else
        for _, c in eligible do
            local picked = s.attach == c.pane
            table.insert(nodes, ui.el("button", { text = (if picked then "● " else "○ ") .. c.label .. (if c.detail then " · " .. c.detail else ""), actions = { click = "attach=" .. string.format("%.0f", c.pane) }, attrs = { ["aria-pressed"] = if picked then "true" else "false" } }))
        end
    end
    table.insert(nodes, ui.rule({}))
    table.insert(nodes, choice(ui, "Do you use Glitch?", s.glitch, "glitch"))
    if s.glitch then
        table.insert(nodes, ui.text({ ui.span(settings.GLITCH_NOTE, "muted") }))
        table.insert(nodes, choice(ui, "Sync Glitch Plan to Tern Board?", s.sync, "sync"))
    else
        table.insert(nodes, choice(ui, "Show the session's folder as a Tern Board?", s.board, "board"))
        if not s.board then table.insert(nodes, ui.text({ ui.span(settings.EMPTY, "muted") })) end
    end
    if s.glitch and s.sync and extra and extra.board then
        table.insert(nodes, ui.text({ ui.span("Board: " .. extra.board.title, "strong") }))
        table.insert(nodes, ui.el("button", { text = "Open board", actions = { click = "openboard=go" } }))
    end
    if status then table.insert(nodes, ui.text({ ui.span(status, "muted") })) end
    return ui.col(nodes)
end

return settings
