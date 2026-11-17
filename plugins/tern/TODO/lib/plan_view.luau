-- English-first native checklist, derived from Felipe Carneiro's MIT session-list renderer.
-- Interactive plans only. CodexBWAI, COMMANDER-993.
-- Schema 1 is checkpoints only. Schema 2 nests checkpoint -> task -> file/step/validation item.
-- validate() is the host-side twin of bin/todo.py validate(): the host draws only a plan that
-- passes it, so a helper that drifts cannot put an unchecked shape on screen.
local view = {}

local STATES = { pending = true, active = true, blocked = true, done = true }
local KINDS = { file = "File", step = "Step", validation = "Check" }
local MAX_CHECKPOINTS, MAX_TASKS, MAX_ITEMS, MAX_ENTITIES = 30, 20, 30, 500
view.MAX_ENTITIES = MAX_ENTITIES

local function known(entity, allowed)
    for key in entity do if not allowed[key] then return false end end
    return true
end
-- Code points Python's str.strip() removes (str.isspace), so schema-1 text length agrees with
-- bin/todo.py: the Lua %s class is ASCII-only and would count a U+00A0 edge as content.
local function isSpace(cp: number): boolean
    return (cp >= 9 and cp <= 13) or (cp >= 0x1C and cp <= 0x20) or cp == 0x85 or cp == 0xA0 or cp == 0x1680
        or (cp >= 0x2000 and cp <= 0x200A) or cp == 0x2028 or cp == 0x2029 or cp == 0x202F or cp == 0x205F or cp == 0x3000
end
local function text(value, limit)
    if type(value) ~= "string" or utf8.len(value) == nil then return false end
    local first, last, count = nil, nil, 0
    for _, cp in utf8.codes(value) do
        count += 1
        if not isSpace(cp) then
            if first == nil then first = count end
            last = count
        end
    end
    if first == nil then return false end
    local length = last - first + 1
    return length >= 1 and length <= limit
end
local function entity(item, label, extra, ids, active)
    if type(item) ~= "table" or type(item.id) ~= "string" or not item.id:match("^[a-z][a-z0-9_%-]*$") or #item.id > 40 or ids.seen[item.id] ~= nil then
        return label .. " ids must be stable and unique across the whole plan"
    end
    local allowed = { id = true, text = true, state = true, reason = true }
    for key in extra do allowed[key] = true end
    if not known(item, allowed) then return label .. " has an unsupported field" end
    if not text(item.text, 240) then return label .. " text must contain 1-240 characters" end
    if type(item.state) ~= "string" or not STATES[item.state] then return "unsupported " .. label .. " state" end
    if item.reason ~= nil and not text(item.reason, 400) then return "blocked reason must contain 1-400 characters" end
    if (item.state == "blocked") ~= (item.reason ~= nil) then return "only blocked " .. label .. "s carry a required reason" end
    if ids.count >= MAX_ENTITIES then return "too many checkpoints, tasks and steps" end
    ids.seen[item.id] = item.state; ids.count += 1
    if item.state == "active" then table.insert(active, item.id) end
    return nil
end

-- Returns nil when the plan is a valid closed shape, else the first reason.
function view.validate(plan: any): string?
    if type(plan) ~= "table" or type(plan.checkpoints) ~= "table" then return "Source returned an invalid checkpoint report." end
    if type(plan.plan_id) ~= "string" or not plan.plan_id:match("^plan%-%x%x%x%x%x%x%x%x%x%x%x%x$") or not text(plan.title, 160) then
        return "Source returned an invalid checkpoint report."
    end
    if plan.schema ~= 1 and plan.schema ~= 2 then return "unsupported checkpoint schema" end
    if not known(plan, { schema = true, plan_id = true, title = true, current = true, checkpoints = true }) then return "checkpoint block has an unsupported field" end
    if #plan.checkpoints < 1 or #plan.checkpoints > MAX_CHECKPOINTS then return "use 1-30 agreed checkpoints" end
    -- Ids live in their own table: a plan id such as "count" must not collide with the counter.
    local ids: any, active = { count = 0, seen = {} }, {}
    for _, checkpoint in plan.checkpoints do
        local problem = entity(checkpoint, "checkpoint", if plan.schema == 2 then { tasks = true } else {}, ids, active)
        if problem then return problem end
        local tasks = checkpoint.tasks or {}
        if type(tasks) ~= "table" or #tasks > MAX_TASKS then return "a checkpoint holds at most 20 tasks" end
        for _, task in tasks do
            problem = entity(task, "task", { items = true }, ids, active)
            if problem then return problem end
            local items = task.items or {}
            if type(items) ~= "table" or #items > MAX_ITEMS then return "a task holds at most 30 items" end
            for _, item in items do
                if type(item) ~= "table" or not KINDS[item.kind] then return "an item needs kind file, step or validation" end
                problem = entity(item, "item", { kind = true, path = true }, ids, active)
                if problem then return problem end
                if (item.kind == "file") ~= (item.path ~= nil) then return "only file items carry a required path" end
                if item.path ~= nil and not text(item.path, 240) then return "file path must contain 1-240 characters" end
            end
        end
    end
    local current = plan.current
    if current ~= nil and (type(current) ~= "string" or (ids.seen[current] ~= "active" and ids.seen[current] ~= "blocked")) then
        return "current must name an active/blocked entity, or be null"
    end
    -- Parallel builders may leave several entities active at once; current is optional focus on one active/blocked entity.
    return nil
end

-- Flat, ordered list of every entity: { id, kind, parent, depth, text, state, reason, path }.
-- kind is checkpoint | task | file | step | validation. Order is plan order; ids are the identity.
function view.entities(plan: any): { any }
    local out = {}
    for _, cp in plan.checkpoints do
        table.insert(out, { id = cp.id, kind = "checkpoint", depth = 1, text = cp.text, state = cp.state, reason = cp.reason })
        for _, task in cp.tasks or {} do
            table.insert(out, { id = task.id, kind = "task", parent = cp.id, depth = 2, text = task.text, state = task.state, reason = task.reason })
            for _, item in task.items or {} do
                table.insert(out, { id = item.id, kind = item.kind, parent = task.id, depth = 3, text = item.text, state = item.state, reason = item.reason, path = item.path })
            end
        end
    end
    return out
end

-- Per-kind { done, total } so the header shows real progress, never an inferred one.
function view.totals(plan: any): any
    local totals = {}
    for _, kind in { "checkpoint", "task", "file", "step", "validation" } do totals[kind] = { done = 0, total = 0 } end
    for _, e in view.entities(plan) do
        totals[e.kind].total += 1
        if e.state == "done" then totals[e.kind].done += 1 end
    end
    return totals
end

local function progress(plan: any): string
    local totals = view.totals(plan)
    local parts = { "Checkpoints " .. totals.checkpoint.done .. "/" .. totals.checkpoint.total }
    for _, pair in { { "task", "Tasks" }, { "file", "Files" }, { "step", "Steps" }, { "validation", "Checks" } } do
        local t = totals[pair[1]]
        if t.total > 0 then table.insert(parts, pair[2] .. " " .. t.done .. "/" .. t.total) end
    end
    return table.concat(parts, " · ")
end

local PREFIX = { "", "  ▸ ", "      · " }
local function row(plan: any, e: any): any
    local label = if e.depth == 3 then KINDS[e.kind] .. " · " .. e.text else e.text
    local note = e.reason
    if e.path then note = if note then note .. " · " .. e.path else e.path end
    return { id = e.id, text = (if plan.current == e.id then "Current · " else "") .. PREFIX[e.depth] .. label, status = e.state, note = note }
end

-- The one hidden, keyed node the window reads through the pane surface (lib/plan_publish says what it holds).
-- It is a node of this view, so it is read the same way whichever machine the session runs on.
function view.syncNode(ui, text: string)
    local node = ui.text(text)
    node.p = node.p or {}
    node.p.key = "plan-sync"
    node.p.role = "todo.plan"
    node.p.hidden = true
    return node
end

-- `sync` (optional): the text of the hidden plan-sync node, drawn with every state of the view.
function view.draw(ui, plan, source, errorText, updated, sync)
    local function main(children)
        if sync then table.insert(children, view.syncNode(ui, sync)) end
        return {main = ui.col(children)}
    end
    if errorText then
        return main({
            ui.node("checklist", {mode = "full", phases = {{id = "error", items = {{id = "error", text = "Plan unavailable", status = "blocked", note = errorText}}}}}),
        })
    end
    if not plan then
        return main({
            ui.text({ui.span("Reading the selected interactive plan…", "muted")}),
        })
    end
    local footer = {
        ui.text({ui.span(source, "muted")}),
        ui.text({ui.span("Read-only plan view · Last read " .. tostring(updated), "muted")}),
    }
    local detailed = false
    for _, cp in plan.checkpoints do if cp.tasks and #cp.tasks > 0 then detailed = true end end
    if not detailed then
        local items, done = {}, 0
        for _, cp in plan.checkpoints do
            table.insert(items, row(plan, { id = cp.id, depth = 1, text = cp.text, state = cp.state, reason = cp.reason }))
            if cp.state == "done" then done += 1 end
        end
        return main({
            ui.text({ui.span(plan.title .. " · " .. tostring(done) .. "/" .. tostring(#items), "muted")}),
            -- Use the same unframed native checklist family as OMP's ACP todos.
            ui.node("checklist", {mode = "full", phases = {{id = "checkpoints", items = items}}}),
            footer[1], footer[2],
        })
    end
    -- One disclosure group per checkpoint keeps ownership: its tasks and their steps stay under it.
    local children = { ui.text({ui.span(plan.title .. " · " .. progress(plan), "muted")}) }
    local head, groupId, items = nil, nil, nil
    local function close()
        if head then table.insert(children, ui.section(head, { ui.node("checklist", {mode = "full", phases = {{id = groupId, items = items}}}) })) end
    end
    for _, e in view.entities(plan) do
        if e.depth == 1 then
            close()
            head, groupId, items = { ui.span(e.text, "muted") }, e.id, {}
        end
        table.insert(items, row(plan, e))
    end
    close()
    table.insert(children, footer[1]); table.insert(children, footer[2])
    return main(children)
end

return view
