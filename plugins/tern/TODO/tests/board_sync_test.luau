-- Board projection: pure desired/diff plus the serialized apply, against a fake board
-- that can mutate, reload (invalidating native ids) and hold unrelated user cards.
local sync = require("../lib/board_sync")
local claim = require("../lib/board_claim")
local gate = require("../lib/sync_gate")

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
        local count = 0
        for _, l in self.lanes do count += #l.cards end
        return ready({ path = "x", total = count, lanes = out }) end
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


-- SKILLS-182: two windows and the 500-card read boundary.
local view = require("../lib/plan_view")

-- A valid nested plan (at most 30 checkpoints, 20 tasks each, 30 items each) with exactly n entities, all pending.
local function nestedPlan(n)
    local p = { schema = 2, plan_id = "plan-0123456789ab", title = "Big", checkpoints = {} }
    local count, cp = 0, 0
    while count < n and cp < 30 do
        cp += 1; count += 1
        local c = { id = "cp" .. cp, text = "Checkpoint " .. cp, state = "pending", tasks = {} }
        table.insert(p.checkpoints, c)
        for t = 1, 4 do
            if count >= n then break end
            count += 1
            local task = { id = "cp" .. cp .. "-t" .. t, text = "Task " .. t, state = "pending", items = {} }
            table.insert(c.tasks, task)
            for i = 1, 3 do
                if count >= n then break end
                count += 1
                table.insert(task.items, { id = "cp" .. cp .. "-t" .. t .. "-i" .. i, kind = "step", text = "Step " .. i, state = "pending" })
            end
        end
    end
    return p
end
local function cardCount(b) local n = 0; for _, l in b.lanes do n += #l.cards end; return n end
local function assertOnePerId(b, want)
    local n = 0
    for id, count in b.managed() do assert(count == 1, "duplicate " .. id); n += 1 end
    assert(n == want, n)
end

-- Awaitables that complete later: a read sees the board when it is issued, a write lands when it completes.
local function asyncBoard(b, queue)
    local wrapped = {}
    for _, name in { "read", "add_lane", "add", "move", "check", "edit", "remove" } do
        wrapped[name] = function(_, ...)
            local args = { ... }
            if name == "read" then
                local inner = b[name](b, table.unpack(args))
                return { next = function(_, fn) table.insert(queue, function() inner:next(fn) end) end }
            end
            return { next = function(_, fn) table.insert(queue, function() b[name](b, table.unpack(args)):next(fn) end) end }
        end
    end
    return wrapped
end
local function drain(queue) for _ = 1, 1000000 do local fn = table.remove(queue, 1); if not fn then return end; fn() end; error("queue never settled") end

-- kv.json as Tern keeps it: every VM caches the whole file and rewrites the whole file, so a VM holding an old
-- copy drops other VMs' keys. `rewriteStale` is that drop.
local function harness()
    local h = { disk = {}, ver = 0, ms = 0, timers = {} }
    local function clone(t) local out = {}; for k, v in t do out[k] = if type(v) == "table" then table.clone(v) else v end; return out end
    function h.snapshot() return clone(h.disk) end
    function h.rewriteStale(old) h.disk = clone(old); h.ver += 1 end
    function h.peek(key) return h.disk[key] end
    local function vm()
        local cache, seen = {}, -1
        local function load() if seen ~= h.ver then cache = clone(h.disk); seen = h.ver end end
        return {
            get = function(key) load(); local v = cache[key]; if type(v) == "table" then return table.clone(v) end; return v end,
            set = function(key, value) load(); cache[key] = value; h.disk = clone(cache); h.ver += 1; seen = h.ver end,
        }
    end
    function h.env(name, cx)
        return {
            kv = vm(), now = function() return h.ms / 1000 end, token = function() return name end,
            timer = function(ms, fn) table.insert(h.timers, { at = h.ms + ms, fn = function() fn(cx) end }) end,
        }
    end
    function h.run(isDone)
        for _ = 1, 100000 do
            if isDone() or #h.timers == 0 then return end
            local best = 1
            for i, t in h.timers do if t.at < h.timers[best].at then best = i end end
            local t = table.remove(h.timers, best)
            h.ms = math.max(h.ms, t.at)
            t.fn()
        end
        error("harness did not settle")
    end
    return h
end

-- One window's claim-then-sync, as window.lua's syncTick does it.
local function window(h, board, name, p, results, tracker, crash)
    local cx = { board = board }
    local env = h.env(name, cx)
    claim.acquire(env, cx, "board.md", function(fresh, token, release)
        tracker.inside += 1; tracker.max = math.max(tracker.max, tracker.inside)
        if crash then tracker.inside -= 1; results[name] = { ok = false, problem = "crashed" }; return end
        -- (each real window is its own VM, so each has its own in-window lock; the spec only names it here)
        sync.apply(fresh, "board.md#" .. name, p, function(ok, problem, count)
            tracker.inside -= 1
            release()
            results[name] = { ok = ok, problem = problem, count = count }
        end, function() return claim.holds(env, "board.md", token) end)
    end, function(reason) results[name] = { ok = false, problem = reason } end)
    return env
end

local tests = {
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

local extra = {
    {"the 500-entity fixture is a valid plan", function()
        local p = nestedPlan(500)
        assert(view.validate(p) == nil, view.validate(p))
        assert(#sync.desired(p) == 500)
    end},
    {"two windows with no claim racing a 500-entity plan: the hidden duplicate half is found and the board ends with 500 cards", function()
        local b = fakeBoard()
        local bp = nestedPlan(500)
        local other
        -- The other window read the empty board too; it writes its whole batch just before ours.
        b.onFirstWrite = function()
            sync.apply({ board = b }, "other.md", bp, function(ok, problem) other = { ok = ok, problem = problem } end)
        end
        local r = run(b, bp)
        assert(other and other.ok, other and other.problem)
        assert(r.ok, r.problem)
        assert(cardCount(b) == 500, cardCount(b))
        assertOnePerId(b, 500)
    end},
    {"a stale grant lets a second window add while the first window's last add is pending: 501 cards are repaired", function()
        local b, h, q = fakeBoard(), harness(), {}
        local full, short = nestedPlan(500), nestedPlan(499)
        assert(run(b, short).ok and cardCount(b) == 499)
        claim.host_serve(h.env("host"))
        local results, tracker = {}, { inside = 0, max = 0 }
        -- A: claims, reads 499, and has the final add pending.
        local ea = window(h, asyncBoard(b, q), "A", full, results, tracker)
        h.run(function() return #q > 0 end)
        local snapshotBeforeGrant = {}
        table.remove(q, 1)() -- A read completes; its add is queued, not landed
        assert(#q == 1 and cardCount(b) == 499, "q=" .. #q)
        -- A stale whole-file rewrite drops A's grant.
        h.rewriteStale(snapshotBeforeGrant)
        assert(not claim.holds(ea, "board.md", "A"))
        -- B is granted the board and reads the same 499 cards.
        window(h, asyncBoard(b, q), "B", full, results, tracker)
        h.run(function() return #q > 1 end)
        -- B reads the same 499 cards and queues its add behind A's.
        table.remove(q, 2)()
        assert(#q == 2 and cardCount(b) == 499)
        table.remove(q, 1)() -- A's add lands
        table.remove(q, 1)() -- B's add lands
        assert(cardCount(b) == 501, cardCount(b))
        drain(q)
        h.run(function() return results.A and results.B end)
        drain(q)
        assert(results.A and results.B, "both windows finished")
        assert(cardCount(b) == 500, cardCount(b))
        assertOnePerId(b, 500)
    end},
    {"a healthy board past the read limit because of the owner's own cards is never thinned", function()
        local b = fakeBoard()
        local p = nestedPlan(500)
        assert(run(b, p).ok)
        for i = 1, 3 do b.user("Pending", "mine " .. i) end
        local before = cardCount(b)
        local r = run(b, p)
        assert(not r.ok and r.problem:find("more cards", 1, true))
        assert(cardCount(b) == before, "no card may be removed from a board that merely holds many cards")
    end},
    {"claim: two windows racing a 500-entity plan end with exactly 500 cards, one writer at a time", function()
        local b, h = fakeBoard(), harness()
        local bp = nestedPlan(500)
        claim.host_serve(h.env("host"))
        local results, tracker = {}, { inside = 0, max = 0 }
        window(h, b, "A", bp, results, tracker)
        window(h, b, "B", bp, results, tracker)
        h.run(function() return results.A and results.B end)
        assert(results.A and results.A.ok, results.A and results.A.problem)
        assert(results.B and results.B.ok, results.B and results.B.problem)
        assert(cardCount(b) == 500, cardCount(b))
        assert(tracker.max == 1, tracker.max)
        assertOnePerId(b, 500)
        assert(results.A.count + results.B.count == 500, "the second window found the board already complete")
    end},
    {"claim: a window that died holding the board does not block it past the lease", function()
        local b, h = fakeBoard(), harness()
        local bp = nestedPlan(5)
        claim.host_serve(h.env("host"))
        local results, tracker = {}, { inside = 0, max = 0 }
        window(h, b, "dead", bp, results, tracker, true)
        h.run(function() return results.dead end)
        for _ = 1, 10 do
            results.B = nil
            window(h, b, "B", bp, results, tracker)
            h.run(function() return results.B end)
            if results.B and results.B.ok then break end
            assert(h.ms < claim.LEASE_S * 1000, "still refused after the lease ran out")
        end
        assert(results.B and results.B.ok, results.B and results.B.problem)
        assert(h.ms >= claim.LEASE_S * 1000, h.ms)
        assert(cardCount(b) == 5)
    end},
    {"claim: a window is refused (fail closed) when no host ever answers", function()
        local b, h = fakeBoard(), harness()
        local results, tracker = {}, { inside = 0, max = 0 }
        window(h, b, "A", nestedPlan(5), results, tracker)
        h.run(function() return results.A end)
        assert(results.A and not results.A.ok and cardCount(b) == 0)
    end},
    {"claim: a holder that lost its grant stops writing", function()
        local b, h = fakeBoard(), harness()
        claim.host_serve(h.env("host"))
        local cx = { board = b }
        local env = h.env("A", cx)
        local result
        claim.acquire(env, cx, "board.md", function(fresh, token)
            b.onFirstWrite = function() h.rewriteStale({}) end
            sync.apply(fresh, "board.md#A", plan(), function(ok, problem) result = { ok = ok, problem = problem } end,
                function() return claim.holds(env, "board.md", token) end)
        end, function(reason) result = { ok = false, problem = reason } end)
        h.run(function() return result end)
        assert(result and not result.ok and b.writes == 1, b.writes)
    end},
    {"re-enabling sync forgets the cached revision, so a hand-edited card is repaired", function()
        local b = fakeBoard()
        local p = plan()
        local g = gate.new()
        local key = "7:" .. p.plan_id
        local on = { schema = 1, glitch = true, board = true, sync = true, attach = 7 }
        local off = { schema = 1, glitch = true, board = true, sync = false, attach = 7 }
        local function tick(rev)
            if g.matches(key, rev) then return "skipped" end
            local gen = g.generation()
            local r = run(b, p); assert(r.ok, r.problem); g.mark(key, rev, gen); return "synced"
        end
        assert(tick(1) == "synced" and tick(1) == "skipped")
        g.settingsChanged(on, off)
        local d = sync.desired(p)
        local gone = "todo-id-" .. d[1].id
        for _, l in b.lanes do
            for i = #l.cards, 1, -1 do if table.find(l.cards[i].tags, gone) then table.remove(l.cards, i) end end
        end
        assert(b.laneOf(d[1].id) == nil)
        local victim = b.lanes[1].cards[1] or b.lanes[2].cards[1]
        victim.text = "tampered"
        g.settingsChanged(off, on)
        assert(tick(1) == "synced", "same plan revision must still reconcile after sync is turned on")
        assertOnePerId(b, #d)
        assert(tick(1) == "skipped")
    end},
    {"a pass that was already running when sync was turned off and on cannot re-mark the revision", function()
        local b, q = fakeBoard(), {}
        local p = plan()
        local g = gate.new()
        local key = "7:" .. p.plan_id
        local on = { schema = 1, glitch = true, board = true, sync = true, attach = 7 }
        local off = { schema = 1, glitch = true, board = true, sync = false, attach = 7 }
        run(b, p)
        local gen = g.generation()
        local finished
        -- the pass is at its final verification read; that completion is delayed
        sync.apply({ board = asyncBoard(b, q) }, "board.md", p, function(ok) finished = ok end)
        assert(#q == 1 and finished == nil)
        g.settingsChanged(on, off)
        local d = sync.desired(p)
        local gone = "todo-id-" .. d[1].id
        for _, l in b.lanes do
            for i = #l.cards, 1, -1 do if table.find(l.cards[i].tags, gone) then table.remove(l.cards, i) end end
        end
        g.settingsChanged(off, on)
        drain(q)
        assert(finished == true, "the delayed pass read a snapshot that was correct when it was taken")
        local marked = g.mark(key, 1, gen)
        assert(marked == false and not g.matches(key, 1), "the stale completion must not mark the revision")
    end},
    {"switching the attached session also forgets the cached revision", function()
        local g = gate.new()
        local a = { schema = 1, glitch = true, board = true, sync = true, attach = 7 }
        local c = { schema = 1, glitch = true, board = true, sync = true, attach = 9 }
        g.mark("k", 1, g.generation())
        g.settingsChanged(a, a); assert(g.matches("k", 1))
        g.settingsChanged(a, c); assert(not g.matches("k", 1))
    end},
}
for _, t in extra do table.insert(tests, t) end
return tests
