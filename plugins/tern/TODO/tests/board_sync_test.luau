-- Board projection: pure desired/diff plus the serialized apply, against a fake board
-- that can mutate, reload (invalidating native ids) and hold unrelated user cards.
local sync = require("../lib/board_sync")

local function plan(planId, tweak)
    local p = {
        schema = 2, plan_id = planId or "plan-0123456789ab", title = "Detailed", current = "impl",
        checkpoints = {
            { id = "model", text = "Model", state = "done", tasks = {
                { id = "parse", text = "Parser", state = "done", items = {
                    { id = "parse-file", kind = "file", path = "bin/todo.py", text = "Edit validate", state = "done" },
                    { id = "parse-check", kind = "validation", text = "Tests pass", state = "done" } } } } },
            { id = "ui", text = "UI", state = "active", tasks = {
                { id = "impl", text = "Implement", state = "active", items = {
                    { id = "impl-step", kind = "step", text = "Wait for owner", state = "blocked", reason = "Owner choice" },
                    { id = "impl-file", kind = "file", path = "window.luau", text = "Segment", state = "pending" } } } } },
        },
    }
    if tweak then tweak(p) end
    return p
end

-- Fake BoardCx: synchronous awaitables, opaque ids, Done lane checks cards.
local function fakeBoard()
    local b = { lanes = {}, n = 0, writes = 0, failNext = 0 }
    local function ready(value, err) return { next = function(_, fn) fn(value, err); return nil end } end
    local function newId() b.n += 1; return "n" .. b.n end
    local function lane(title) for _, l in b.lanes do if l.title == title then return l end end end
    local function find(id)
        for _, l in b.lanes do for i, c in l.cards do if c.id == id then return l, i, c end end end
    end
    function b.user(title, text, card) local l = lane(title); table.insert(l.cards, { id = newId(), text = text, done = false, tags = {} }) end
    -- Enforces the real read limit (tern.d.luau BoardCx.read: rows default 25, max 500): rows is
    -- clamped to 500, cards past it come back as the lane's `more`, and a lane cannot be paged.
    b.maxRows = 500
    function b:read(_, opts) local out, left = {}, math.min((opts and opts.rows) or 25, self.maxRows)
        for _, l in self.lanes do local cards = {}
            for _, c in l.cards do
                if left > 0 then left -= 1; table.insert(cards, { id = c.id, text = c.text, done = c.done, tags = table.clone(c.tags) }) end
            end
            table.insert(out, { id = l.id, title = l.title, complete = false, more = #l.cards - #cards, cards = cards }) end
        return ready({ path = "x", lanes = out }) end
    local function guard()
        if b.onFirstWrite then local hook = b.onFirstWrite; b.onFirstWrite = nil; hook() end
        if b.failNext > 0 then b.failNext -= 1; return true end; b.writes += 1; return false end
    function b:add_lane(_, o) if guard() then return ready(nil, "boom") end table.insert(self.lanes, { id = newId(), title = o.title, cards = {} }); return ready("l") end
    function b:add(_, c) if guard() then return ready(nil, "boom") end
        local l = lane(c.lane); if not l then return ready(nil, "no lane") end
        local id = newId(); table.insert(l.cards, { id = id, text = c.text, tags = c.tags or {}, done = c.lane == "Done" }); return ready(id) end
    function b:move(id, to) if guard() then return ready(nil, "boom") end
        local l, i, c = find(id); if not c then return ready(nil, "stale id") end
        table.remove(l.cards, i); table.insert(lane(to).cards, c); c.done = to == "Done"; return ready(true) end
    function b:check(id, done) if guard() then return ready(nil, "boom") end local _, _, c = find(id); if not c then return ready(nil, "stale id") end c.done = done; return ready(true) end
    function b:edit(id, f) if guard() then return ready(nil, "boom") end local _, _, c = find(id); if not c then return ready(nil, "stale id") end
        c.text = f.text or c.text; c.tags = f.tags or c.tags; return ready(true) end
    function b:remove(id) if guard() then return ready(nil, "boom") end local l, i = find(id); if not l then return ready(nil, "stale id") end table.remove(l.cards, i); return ready(true) end
    function b.reload() for _, l in b.lanes do for _, c in l.cards do c.id = newId() end end end
    function b.managed() local out = {}
        for _, l in b.lanes do for _, c in l.cards do for _, t in c.tags do
            if t:sub(1, 8) == "todo-id-" then out[t:sub(9)] = (out[t:sub(9)] or 0) + 1; c.lane = l.title end end end end
        return out end
    function b.laneOf(id) for _, l in b.lanes do for _, c in l.cards do for _, t in c.tags do if t == "todo-id-" .. id then return l.title end end end end end
    for _, t in sync.LANE_ORDER do table.insert(b.lanes, { id = newId(), title = t, cards = {} }) end
    return b
end

local function run(b, p)
    local result
    sync.apply({ board = b }, "board.md", p, function(ok, problem, count) result = { ok = ok, problem = problem, count = count } end)
    assert(result, "apply must finish synchronously against the fake board")
    return result
end
-- A window context that is valid only for the call that made it: once any awaitable of the
-- board resolves, the original context is dead and only the fresh one handed to next() works.
local function expiringCx(b)
    local state = { expired = false }
    local fresh = { board = {} }
    local original = { board = {} }
    for _, name in { "read", "add_lane", "add", "move", "check", "edit", "remove" } do
        original.board[name] = function(_, ...)
            if state.expired then error("expired window context") end
            local pending = b[name](b, ...)
            return { next = function(_, fn) state.expired = true; pending:next(function(v, e) fn(v, e, fresh) end) end }
        end
        fresh.board[name] = function(_, ...)
            local pending = b[name](b, ...)
            return { next = function(_, fn) pending:next(function(v, e) fn(v, e, fresh) end) end }
        end
    end
    return original
end
local function total(p) return #sync.desired(p) end

return {
    {"projection covers every entity once with its canonical id, kind, parent and state lane", function()
        local d = sync.desired(plan())
        assert(#d == 8, #d)
        local byId = {}
        for _, c in d do assert(byId[c.id] == nil, "duplicate " .. c.id); byId[c.id] = c end
        assert(byId["parse-file"].lane == "Done" and byId["impl"].lane == "Active" and byId["impl-step"].lane == "Blocked" and byId["impl-file"].lane == "Pending")
        assert(byId["parse-file"].parent == "parse" and byId["impl"].parent == "ui" and byId["ui"].parent == nil)
        assert(byId["impl-step"].text:find("Blocked: Owner choice", 1, true) and byId["impl-step"].text:find("(in UI › Implement)", 1, true))
        assert(byId["parse-file"].text:find("bin/todo.py", 1, true))
        local hasId = false
        for _, t in byId["impl"].tags do if t == "todo-id-impl" then hasId = true end end
        assert(hasId)
    end},
    {"first apply creates every card; the same plan again is a no-op (idempotent)", function()
        local b = fakeBoard()
        local r = run(b, plan())
        assert(r.ok and r.count == 8, r.problem)
        for id, n in b.managed() do assert(n == 1, id) end
        local writes = b.writes
        local again = run(b, plan())
        assert(again.ok and again.count == 0 and b.writes == writes, "second pass wrote")
    end},
    {"every state lands in its dedicated lane and moves in place when the state changes", function()
        local b = fakeBoard(); run(b, plan())
        assert(b.laneOf("impl-file") == "Pending")
        for _, to in { "active", "blocked", "done", "pending" } do
            local p = plan(nil, function(p)
                p.checkpoints[2].tasks[1].state = "pending"; p.current = nil
                local item = p.checkpoints[2].tasks[1].items[2]; item.state = to
                if to == "blocked" then item.reason = "Waiting" end
                if to == "active" then p.current = "impl-file" end
            end)
            assert(run(b, p).ok)
            local want = ({ active = "Active", blocked = "Blocked", done = "Done", pending = "Pending" })[to]
            assert(b.laneOf("impl-file") == want, to .. " -> " .. tostring(b.laneOf("impl-file")))
            for id, n in b.managed() do assert(n == 1, "duplicate " .. id) end
        end
    end},
    {"rename edits in place; reorder changes nothing; no duplicates", function()
        local b = fakeBoard(); run(b, plan())
        local renamed = plan(nil, function(p) p.checkpoints[2].tasks[1].text = "Implement v2" end)
        local r = run(b, renamed)
        assert(r.ok and r.count >= 1)
        for id, n in b.managed() do assert(n == 1, id) end
        local reordered = plan(nil, function(p) p.checkpoints[2].tasks[1].text = "Implement v2"; local i = p.checkpoints[2].tasks[1].items; i[1], i[2] = i[2], i[1] end)
        assert(run(b, reordered).count == 0)
    end},
    {"removing an entity removes only its managed card; unrelated cards survive", function()
        local b = fakeBoard()
        b.user("Pending", "my own card")
        b.user("Done", "another")
        run(b, plan())
        local smaller = plan(nil, function(p) table.remove(p.checkpoints[2].tasks[1].items, 2) end)
        assert(run(b, smaller).ok)
        assert(b.managed()["impl-file"] == nil and b.managed()["impl-step"] == 1)
        local mine = 0
        for _, l in b.lanes do for _, c in l.cards do if c.text == "my own card" or c.text == "another" then mine += 1 end end end
        assert(mine == 2)
    end},
    {"a native id invalidated by a board reload is re-read and retried", function()
        local b = fakeBoard(); run(b, plan())
        local snapshot = b:read()
        b.reload()
        local stale = plan(nil, function(p) p.checkpoints[1].tasks[1].items[1].state = "pending"; p.checkpoints[1].tasks[1].state = "pending"; p.checkpoints[1].state = "pending" end)
        -- Simulate the reload landing between read and write: first write fails with a stale id.
        b.failNext = 1
        local r = run(b, stale)
        assert(r.ok, r.problem)
        assert(b.laneOf("parse-file") == "Pending")
        for id, n in b.managed() do assert(n == 1, id) end
        assert(snapshot ~= nil)
    end},
    {"repeated write failures stop after bounded retries and report the problem", function()
        local b = fakeBoard(); b.failNext = 100
        local r = run(b, plan())
        assert(not r.ok and r.problem:find("Board write failed", 1, true))
    end},
    {"duplicate managed cards (a race) collapse to one", function()
        local b = fakeBoard(); run(b, plan())
        local d = sync.desired(plan())[1]
        table.insert(b.lanes[4].cards, { id = "dup", text = "x", done = true, tags = table.clone(d.tags) })
        assert(run(b, plan()).ok)
        for id, n in b.managed() do assert(n == 1, id) end
    end},
    {"a different plan id targets a different board file and never touches the old one", function()
        assert(sync.boardPath("/d", "plan-0123456789ab") ~= sync.boardPath("/d", "plan-ffffffffffff"))
        local a, c = fakeBoard(), fakeBoard()
        run(a, plan("plan-0123456789ab")); local before = total(plan())
        run(c, plan("plan-ffffffffffff"))
        local count = 0
        for _ in a.managed() do count += 1 end
        assert(count == before)
    end},
    {"a board with unread cards is refused rather than half-synced", function()
        local ops, why = sync.diff(sync.desired(plan()), { lanes = { { title = "Pending", more = 3, cards = {} } } })
        assert(ops == nil and why)
    end},
    {"a missing lane is created before cards are added", function()
        local ops = sync.diff(sync.desired(plan()), { lanes = { { title = "Pending", more = 0, cards = {} } } })
        local lanes = 0
        for _, op in ops do if op.op == "add_lane" then lanes += 1 end end
        assert(lanes == 3 and ops[1].op == "add_lane")
    end},
    {"initial markdown has the four lanes", function()
        local md = sync.initialMarkdown(plan())
        for _, lane in sync.LANE_ORDER do assert(md:find("## " .. lane, 1, true)) end
    end},
    {"every continuation uses the fresh window context, never the expired initiating one", function()
        local b = fakeBoard()
        local result
        sync.apply(expiringCx(b), "board.md", plan(), function(ok, problem, count) result = { ok = ok, problem = problem, count = count } end)
        assert(result and result.ok, result and result.problem)
        assert(result.count == 8)
        for id, n in b.managed() do assert(n == 1, id) end
    end},
    {"two windows that read the same board and both add leave one card per id", function()
        local b = fakeBoard()
        -- The other window reads the still-empty board and writes everything just before ours does.
        b.onFirstWrite = function()
            local other
            sync.apply({ board = b }, "other-window.md", plan(), function(ok, problem) other = { ok = ok, problem = problem } end)
            assert(other and other.ok, other and other.problem)
        end
        local r = run(b, plan())
        assert(r.ok, r.problem)
        local n = 0
        for id, count in b.managed() do assert(count == 1, "duplicate " .. id); n += 1 end
        assert(n == total(plan()))
    end},
    {"a 300-entity plan raced by two windows (600 cards, past the 500-row read) still converges to one card per id", function()
        local function big() return plan(nil, function(p)
            p.checkpoints = {}
            for i = 1, 300 do table.insert(p.checkpoints, { id = "c" .. i, text = "Checkpoint " .. i, state = "pending" }) end
        end) end
        local b = fakeBoard()
        local bp = big()
        assert(#sync.desired(bp) == 300)
        -- both windows read the empty board and each queue every add, interleaved
        for _, d in sync.desired(bp) do
            b:add("x", { lane = d.lane, text = d.text, tags = d.tags }); b:add("x", { lane = d.lane, text = d.text, tags = d.tags })
        end
        local total = 0
        for _, l in b.lanes do total += #l.cards end
        assert(total == 600, total)
        local r = run(b, bp)
        assert(r.ok, r.problem)
        local n = 0
        for id, count in b.managed() do assert(count == 1, "duplicate " .. id); n += 1 end
        assert(n == 300, n)
    end},
    {"a truncated read never adds or creates lanes, but still removes duplicates it can see", function()
        local d = sync.desired(plan())
        local dupTags = table.clone(d[1].tags)
        local ops, why, truncated = sync.diff(d, { lanes = { { title = "Pending", more = 5, cards = {
            { id = "a", text = "x", done = false, tags = table.clone(dupTags) },
            { id = "b", text = "x", done = false, tags = table.clone(dupTags) } } } } })
        assert(ops and truncated and not why)
        for _, op in ops do assert(op.op ~= "add" and op.op ~= "add_lane", op.op) end
        local removed = false
        for _, op in ops do if op.op == "remove" and op.card == "b" then removed = true end end
        assert(removed)
    end},
    {"turning sync off stops a pass that is already running", function()
        local b = fakeBoard()
        local on = true
        b.onFirstWrite = function() on = false end
        local result
        sync.apply({ board = b }, "board.md", plan(), function(ok, problem, count) result = { ok = ok, problem = problem, count = count } end, function() return on end)
        assert(result and not result.ok and result.problem:find("turned off", 1, true), result and result.problem)
        assert(b.writes == 1, b.writes)
    end},
    {"sync that is already off never reads the board", function()
        local b = fakeBoard()
        local reads = 0
        local original = b.read
        function b.read(self, ...) reads += 1; return original(self, ...) end
        local result
        sync.apply({ board = b }, "board.md", plan(), function(ok) result = ok end, function() return false end)
        assert(result == false and reads == 0 and b.writes == 0)
    end},
}
