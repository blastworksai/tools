-- One-way Glitch plan -> Tern board projection. CodexBWAI; MIT.
-- Pure model (desired/diff/initialMarkdown) plus one serialized effect (apply).
-- Identity is the canonical entity id carried in a `todo-id-<id>` tag, never the card
-- title or a native card id (those are invalid after a board reload). Only cards that
-- carry that tag are ever touched; every other card on the board is left alone.
-- Outcomes: rename -> text edited in place; reorder -> no board change (lane order is
-- not managed); done/blocked/active -> moved to its lane; removed entity -> its card is
-- removed; a different plan id -> a different board file, the old board is untouched.
local view = require("./plan_view")
local sync = {}

sync.LANES = { pending = "Pending", active = "Active", blocked = "Blocked", done = "Done" }
sync.LANE_ORDER = { "Pending", "Active", "Blocked", "Done" }
local ID_TAG = "todo-id-"
local KIND_LABEL = { checkpoint = "Checkpoint", task = "Task", file = "File", step = "Step", validation = "Check" }

local function oneLine(value: string): string
    return (value:gsub("%s+", " "):match("^ ?(.-) ?$"))
end

-- Absolute board file for a plan; `data` is tern.plugin.data. Nothing ever shares a board between plans.
function sync.boardPath(data: string, planId: string): string
    return data .. "/boards/" .. planId .. ".md"
end

function sync.initialMarkdown(plan: any): string
    local lines = { "# TODO · " .. oneLine(plan.title), "" }
    for _, lane in sync.LANE_ORDER do table.insert(lines, "## " .. lane); table.insert(lines, "") end
    return table.concat(lines, "\n")
end

-- The managed cards a plan should have, in plan order.
function sync.desired(plan: any): { any }
    local entities = view.entities(plan)
    local byId, out = {}, {}
    for _, e in entities do byId[e.id] = e end
    for _, e in entities do
        local trail, parent = {}, e.parent and byId[e.parent]
        while parent do table.insert(trail, 1, oneLine(parent.text)); parent = parent.parent and byId[parent.parent] end
        local label = "[" .. KIND_LABEL[e.kind] .. "] " .. oneLine(e.text)
        if #trail > 0 then label ..= " (in " .. table.concat(trail, " › ") .. ")" end
        if e.reason then label ..= " — Blocked: " .. oneLine(e.reason) end
        if e.path then label ..= " — " .. oneLine(e.path) end
        local tags = { "todo", ID_TAG .. e.id, "todo-kind-" .. e.kind }
        if e.parent then table.insert(tags, "todo-in-" .. e.parent) end
        table.insert(out, { id = e.id, kind = e.kind, parent = e.parent, state = e.state, lane = sync.LANES[e.state], text = label, tags = tags })
    end
    return out
end

local function managedId(card: any): string?
    for _, tag in card.tags or {} do
        if tag:sub(1, #ID_TAG) == ID_TAG then return tag:sub(#ID_TAG + 1) end
    end
    return nil
end
local function sameTags(a: { string }, b: { string }): boolean
    local left, right = table.clone(a), table.clone(b)
    table.sort(left); table.sort(right)
    return table.concat(left, "\0") == table.concat(right, "\0")
end

-- Operations that turn `snapshot` (a BoardSnapshot) into the desired cards. Same plan and
-- same board -> no operations. Returns ops, or nil plus a reason when the board cannot be
-- reconciled faithfully (a lane holds more cards than one read returned).
function sync.diff(desired: { any }, snapshot: any): ({ any }?, string?)
    local lanes, managed, extras = {}, {}, {}
    for _, lane in snapshot.lanes or {} do
        if (lane.more or 0) > 0 then return nil, "The board holds more cards than one read returns; TODO will not sync it." end
        if lane.title then lanes[lane.title] = true end
        for _, card in lane.cards do
            local id = managedId(card)
            if id then
                if managed[id] then table.insert(extras, card) else managed[id] = { card = card, lane = lane.title } end
            end
        end
    end
    local ops, wanted = {}, {}
    for _, lane in sync.LANE_ORDER do
        if not lanes[lane] then
            local used = false
            for _, d in desired do if d.lane == lane then used = true end end
            if used then table.insert(ops, { op = "add_lane", title = lane }) end
        end
    end
    for _, d in desired do
        wanted[d.id] = true
        local current = managed[d.id]
        if not current then
            table.insert(ops, { op = "add", id = d.id, card = { lane = d.lane, text = d.text, tags = d.tags } })
        else
            local card = current.card
            if current.lane ~= d.lane then
                table.insert(ops, { op = "move", id = d.id, card = card.id, lane = d.lane })
            elseif card.done ~= (d.state == "done") then
                table.insert(ops, { op = "check", id = d.id, card = card.id, done = d.state == "done" })
            end
            if card.text ~= d.text or not sameTags(card.tags or {}, d.tags) then
                table.insert(ops, { op = "edit", id = d.id, card = card.id, fields = { text = d.text, tags = d.tags } })
            end
        end
    end
    for id, current in managed do
        if not wanted[id] then table.insert(ops, { op = "remove", id = id, card = current.card.id }) end
    end
    for _, card in extras do table.insert(ops, { op = "remove", id = managedId(card), card = card.id }) end
    return ops, nil
end

local function call(board: any, spec: any, op: any): any
    if op.op == "add_lane" then return board:add_lane(spec, { title = op.title })
    elseif op.op == "add" then return board:add(spec, op.card)
    elseif op.op == "move" then return board:move(op.card, op.lane)
    elseif op.op == "check" then return board:check(op.card, op.done)
    elseif op.op == "edit" then return board:edit(op.card, op.fields)
    else return board:remove(op.card) end
end

local RETRIES = 3
local active: { [any]: boolean } = {}

-- Reads the board, applies the operations one at a time, and re-reads when any write fails
-- (native ids are invalid after a reload). Writes to one board never overlap. Never touches
-- the canonical plan. done(ok, problem, operations)
function sync.apply(board: any, spec: any, plan: any, done: (ok: boolean, problem: string?, count: number) -> ())
    if active[spec] then done(false, "A board sync is already running.", 0); return end
    active[spec] = true
    local desired = sync.desired(plan)
    local total = 0
    local function finish(ok: boolean, problem: string?)
        active[spec] = nil
        done(ok, problem, total)
    end
    local function pass(attempt: number)
        local started, reading = pcall(function() return board:read(spec, { rows = 500 }) end)
        if not started then finish(false, "Could not read the board: " .. tostring(reading)); return end
        reading:next(function(snapshot, err)
            if err or type(snapshot) ~= "table" then finish(false, "Could not read the board: " .. tostring(err)); return end
            local ops, why = sync.diff(desired, snapshot)
            if not ops then finish(false, why); return end
            local function step(index: number)
                if index > #ops then finish(true, nil); return end
                local op = ops[index]
                local ok, pending = pcall(call, board, spec, op)
                local function failed(reason: any)
                    if attempt < RETRIES then pass(attempt + 1)
                    else finish(false, "Board write failed after " .. tostring(RETRIES) .. " reads: " .. tostring(reason)) end
                end
                if not ok then failed(pending); return end
                pending:next(function(result, problem)
                    if problem or result == false then failed(problem or "refused"); return end
                    total += 1
                    step(index + 1)
                end)
            end
            step(1)
        end)
    end
    pass(1)
end

return sync
