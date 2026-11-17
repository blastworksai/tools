-- One-way Glitch plan -> Tern board projection. Blastworks.ai; MIT.
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
-- A plan syncs to a board only up to this many managed entities (checkpoints, tasks and items together). Tern's
-- board read returns at most 500 cards and cannot page, so two complete copies of a plan written by two windows
-- must still fit in one read: then every duplicate is visible and the ordinary repair removes it. Viewing a plan
-- is bounded by view.MAX_ENTITIES (500) and is not affected.
sync.MAX_SYNC_ENTITIES = 250
sync.TOO_BIG = "This plan has more than 250 checkpoints, tasks and steps, so TODO will not sync it to a board. Viewing it still works."
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
-- same board -> no operations. When a lane holds more cards than one read returned (the board
-- API reads at most 500 and cannot page inside a lane) the unseen cards might already be the
-- ones we would add, so a truncated read only yields operations that are safe on what was seen:
-- removals (duplicates, retired entities), moves, checks and edits; never an add or a new lane.
-- Each removal shrinks the board until a later read sees it whole. Returns ops and whether the
-- read was truncated, or nil plus a reason when nothing safe can be done on a truncated board.
local TRUNCATED = "The board holds more cards than one read returns; TODO will not sync it."
function sync.diff(desired: { any }, snapshot: any): ({ any }?, string?, boolean?)
    local lanes, managed, extras, truncated = {}, {}, {}, false
    for _, lane in snapshot.lanes or {} do
        if (lane.more or 0) > 0 then truncated = true end
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
        if not lanes[lane] and not truncated then
            local used = false
            for _, d in desired do if d.lane == lane then used = true end end
            if used then table.insert(ops, { op = "add_lane", title = lane }) end
        end
    end
    for _, d in desired do
        wanted[d.id] = true
        local current = managed[d.id]
        if not current then
            if not truncated then table.insert(ops, { op = "add", id = d.id, card = { lane = d.lane, text = d.text, tags = d.tags } }) end
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
    if truncated and #ops == 0 then return nil, TRUNCATED end
    return ops, nil, truncated
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
local READ_ROWS = 500
local MAX_SHRINK_PASSES = 8 -- passes that only shrink a truncated board; each one removed or fixed cards
local active: { [any]: boolean } = {}

-- Reads the board, applies the operations one at a time, and reads again: when a write fails
-- (native ids are invalid after a reload), and after every pass that wrote, to verify. The
-- verify read is what repairs two windows that read the same board and both added the same
-- cards: each window's last read comes after its own last write, the diff is deterministic
-- (the first card per id stays, the rest go), so the board converges on one card per id.
-- Writes to one board never overlap inside this window. Never touches the canonical plan.
-- `cx` is the window context of the call that started the sync. It is valid for that call only:
-- every later step runs inside an await callback and uses the fresh context that callback
-- receives (tern.d.luau Awaitable.next). `enabled` is asked before each read and write, so
-- turning sync off stops a pass that is already running. done(ok, problem, operations)
-- Nothing is read or written for a plan over sync.MAX_SYNC_ENTITIES.
function sync.apply(cx: any, spec: any, plan: any, done: (ok: boolean, problem: string?, count: number) -> (), enabled: (() -> boolean)?)
    local shrinks = 0
    if #view.entities(plan) > sync.MAX_SYNC_ENTITIES then done(false, sync.TOO_BIG, 0); return end
    if active[spec] then done(false, "A board sync is already running.", 0); return end
    active[spec] = true
    local desired = sync.desired(plan)
    local total = 0
    local function finish(ok: boolean, problem: string?)
        active[spec] = nil
        done(ok, problem, total)
    end
    local function allowed(): boolean
        if enabled == nil then return true end
        local ok, value = pcall(enabled)
        return ok and value == true
    end
    local STOPPED = "Board sync was turned off."
    local function pass(live: any, attempt: number)
        if not allowed() then finish(false, STOPPED); return end
        local started, reading = pcall(function() return live.board:read(spec, { rows = READ_ROWS }) end)
        if not started then finish(false, "Could not read the board: " .. tostring(reading)); return end
        reading:next(function(snapshot, err, fresh)
            local now = fresh or live
            if err or type(snapshot) ~= "table" then finish(false, "Could not read the board: " .. tostring(err)); return end
            local ops, why, truncated = sync.diff(desired, snapshot)
            if not ops then finish(false, why); return end
            if #ops == 0 then finish(true, nil); return end
            local function step(current: any, index: number)
                if index > #ops then
                    if truncated then
                        shrinks += 1
                        if shrinks > MAX_SHRINK_PASSES then finish(false, TRUNCATED); return end
                        pass(current, attempt)
                        return
                    end
                    if attempt >= RETRIES then finish(false, "The board kept changing while TODO synced it; it will retry."); return end
                    pass(current, attempt + 1)
                    return
                end
                if not allowed() then finish(false, STOPPED); return end
                local op = ops[index]
                local ok, pending = pcall(call, current.board, spec, op)
                local function failed(reason: any, after: any)
                    if attempt < RETRIES then pass(after, attempt + 1)
                    else finish(false, "Board write failed after " .. tostring(RETRIES) .. " reads: " .. tostring(reason)) end
                end
                if not ok then failed(pending, current); return end
                pending:next(function(result, problem, fresh2)
                    local after = fresh2 or current
                    if problem or result == false then failed(problem or "refused", after); return end
                    total += 1
                    step(after, index + 1)
                end)
            end
            step(now, 1)
        end)
    end
    pass(cx, 1)
end

return sync
