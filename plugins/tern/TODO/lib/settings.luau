-- TODO settings: closed model, eligibility and the pane view. CodexBWAI; MIT.
-- Pure apart from load/save (plugin KV). The window owns every effect.
local settings = {}

settings.KEY = "settings"
settings.EMPTY = "No TODO source is enabled. Turn on Board or enable Glitch integration in TODO Settings."
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

function settings.load(kv: any): any
    local ok, raw = pcall(kv.get, settings.KEY)
    return settings.normalize(if ok then raw else nil)
end
function settings.save(kv: any, value: any): boolean
    return (pcall(kv.set, settings.KEY, settings.normalize(value)))
end

-- The one source this configuration shows: "glitch-sync" | "glitch" | "native-board" | "none".
function settings.mode(s: any): string
    if s.glitch then return if s.sync then "glitch-sync" else "glitch" end
    return if s.board then "native-board" else "none"
end
-- Board modes need cx.board, which is desktop/local only.
function settings.needsLocal(s: any): boolean
    local mode = settings.mode(s)
    return mode == "native-board" or mode == "glitch-sync"
end

-- candidates: { pane, label, detail?, remote, live } built by the window from current panes.
-- Stale, closed and ineligible panes never come back; remote panes only for plain Glitch viewing.
function settings.eligible(s: any, candidates: { any }): { any }
    local out, needsLocal = {}, settings.needsLocal(s)
    if settings.mode(s) == "none" then return out end
    for _, c in candidates do
        if c.live and not (needsLocal and c.remote) then table.insert(out, c) end
    end
    return out
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
function settings.draw(ui: any, s: any, eligible: { any }, status: string?): any
    local nodes = {}
    table.insert(nodes, ui.text({ ui.span("Attach to", "strong") }))
    if #eligible == 0 then
        table.insert(nodes, ui.text({ ui.span(if settings.mode(s) == "none" then settings.EMPTY else "No eligible session is open for this mode.", "muted") }))
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
        table.insert(nodes, choice(ui, "Board", s.board, "board"))
        if not s.board then table.insert(nodes, ui.text({ ui.span(settings.EMPTY, "muted") })) end
    end
    if status then table.insert(nodes, ui.text({ ui.span(status, "muted") })) end
    return ui.col(nodes)
end

return settings
