-- The window and host lifecycles behind board sync, driven through the same libraries window.luau and host.luau call.
local settings = require("../lib/settings")
local sync_pane = require("../lib/sync_pane")
local selection = require("../lib/host_selection")
local sync_gate = require("../lib/sync_gate")
local sync_status = require("../lib/sync_status")
local function cand(pane, remote) return { pane = pane, label = "p" .. pane, remote = remote, live = true } end
local cands = { cand(1, false), cand(2, false) }
local ui = {
    el = function(tag, props) return { tag = tag, props = props } end,
    row = function(c) return { row = c } end, col = function(c) return { col = c } end,
    text = function(spans) return { text = spans } end, span = function(t) return t end, rule = function() return { rule = true } end,
}
local function flat(node, out)
    out = out or {}
    if type(node) ~= "table" then table.insert(out, tostring(node)); return out end
    if node.props and node.props.text then table.insert(out, node.props.text) end
    for _, key in { "col", "row", "text" } do for _, child in node[key] or {} do flat(child, out) end end
    return out
end
-- One shared plugin KV, as every window sees it.
local function sharedKv() local d = {}; return { get = function(k) return d[k] end, set = function(k, v) d[k] = v end } end
-- A window's settings pane, drawn the way window.luau paints it.
local function pane(kv, memo)
    local s = settings.load(kv)
    memo.observe(s, if s.attach then true else nil)
    return table.concat(flat(settings.draw(ui, s, settings.eligible(s, cands), nil, memo.extra(s, cands))), "\n")
end
-- A bare memo wired the way window.luau wires it (gate + repaint request).
local function newMemo() return sync_pane.new({ gate = sync_gate.new(), repaint = function() end }) end
local function change(kv, act, value)
    local before = settings.load(kv)
    settings.save(kv, settings.apply(before, act, value, cands), before)
end

-- A window as window.luau builds it: the real status line (zero-delay repaint timers), memo and gate, a pane that
-- draws from them, and `tick` running the same observe -> decide -> succeeded path as syncTick.
local function windowFixture(kv)
    local f = { timers = {}, paints = 0, shown = "" }
    f.gate = sync_gate.new()
    f.status = sync_status.new({
        timer = function(_ms, fn) table.insert(f.timers, fn) end,
        pane = function(_cx) return 9 end,
        paint = function(_cx, _pane) f.paints += 1; f.draw() end,
    })
    f.memo = sync_pane.new({ gate = f.gate, repaint = function() f.status.repaint() end })
    function f.draw()
        local s = settings.load(kv)
        f.shown = table.concat(flat(settings.draw(ui, s, settings.eligible(s, cands), f.status.get(), f.memo.extra(s, cands))), "\n")
    end
    function f.flush() local queued = f.timers; f.timers = {}; for _, fn in queued do fn({}) end end
    f.syncs = 0
    -- session -> { panel, entry } for sessions whose view is open; a session missing from it has no view.
    function f.tick(views, now)
        local s = settings.load(kv)
        if settings.mode(s) ~= "glitch-sync" then return end
        local target
        for _, c in settings.eligible(s, cands) do if c.pane == s.attach then target = c end end
        f.memo.observe(s, target)
        local v = target and views[target.pane]
        local verdict, detail = f.memo.decide(s, target, if v then "match" else "none", if v then v.panel else nil, if v then v.entry else nil, now, false)
        if verdict == "blocked" then f.status.set(detail); return end
        if verdict == "skip" then return end
        f.syncs += 1
        f.memo.succeeded(target.pane, detail, v.entry.rev, f.gate.generation(), 0, now, v.title, "/boards/" .. v.title .. ".md")
        f.status.set("Board \"" .. v.title .. "\" synced · 0 change(s)")
    end
    return f
end
local function planOf(id)
    return { schema = 2, plan_id = id, title = id, current = "impl", checkpoints = {
        { id = "ui", text = "UI", state = "active", tasks = { { id = "impl", text = "Implement", state = "active", items = {
            { id = "impl-step", kind = "step", text = "Do it", state = "pending" } } } } } } }
end

return {
    {"a board that is gone because another window moved the attachment is repainted away even when the blocker text is identical", function()
        local kv = sharedKv()
        change(kv, "glitch", "on"); change(kv, "sync", "on"); change(kv, "attach", "1")
        local a = windowFixture(kv)
        local x = { panel = 10, entry = { rev = 1, plan = planOf("plan-0123456789ab") }, title = "Plan X" }
        a.tick({ [1] = x }, 1000)
        a.draw()
        assert(a.shown:find("Plan X", 1, true) and a.shown:find("Open board", 1, true), a.shown)
        -- X's plan is no longer readable: the blocker is the publication wait; the cached board stays beside it.
        a.tick({ [1] = { panel = 10, entry = nil, title = "Plan X" } }, 2000); a.flush(); a.draw()
        assert(a.status.get():find("Waiting for this session to publish", 1, true), tostring(a.status.get()))
        assert(a.shown:find("Open board", 1, true), a.shown)
        change(kv, "attach", "2") -- window B selects unpublished Y
        a.tick({ [2] = { panel = 11, entry = nil, title = "Plan Y" } }, 3000) -- same blocker text as before
        local before = a.paints
        a.flush()
        assert(a.paints > before, "the stale board was never repainted away")
        assert(not a.shown:find("Plan X", 1, true) and not a.shown:find("Open board", 1, true), a.shown)
    end},
    {"returning to an unchanged, previously synced session brings its board and success status back", function()
        local kv = sharedKv()
        change(kv, "glitch", "on"); change(kv, "sync", "on"); change(kv, "attach", "1")
        local a = windowFixture(kv)
        local x = { panel = 10, entry = { rev = 1, plan = planOf("plan-0123456789ab") }, title = "Plan X" }
        a.tick({ [1] = x }, 1000)
        assert(a.syncs == 1)
        a.tick({ [1] = x }, 2000)
        assert(a.syncs == 1, "an unchanged revision must not sync again")
        change(kv, "attach", "2")
        a.tick({ [2] = { panel = 11, entry = nil, title = "Plan Y" } }, 3000) -- blocker for unpublished Y
        change(kv, "attach", "1") -- X again, its plan unchanged
        a.tick({ [1] = x }, 4000)
        assert(a.syncs == 2, "the revision gate still matched: the board was never restored")
        a.flush(); a.draw()
        assert(a.status.get():find("synced", 1, true), tostring(a.status.get()))
        assert(a.shown:find("Board: Plan X", 1, true) and a.shown:find("Open board", 1, true), a.shown)
    end},
    {"a view that closes and returns for the same session restores the success status", function()
        local kv = sharedKv()
        change(kv, "glitch", "on"); change(kv, "sync", "on"); change(kv, "attach", "1")
        local a = windowFixture(kv)
        local x = { panel = 10, entry = { rev = 1, plan = planOf("plan-0123456789ab") }, title = "Plan X" }
        a.tick({ [1] = x }, 1000)
        a.tick({}, 2000) -- the view is closed: "No plan view is open"
        assert(a.status.get():find("No plan view", 1, true))
        a.tick({ [1] = x }, 3000) -- reopened, plan unchanged
        assert(a.syncs == 2 and a.status.get():find("synced", 1, true), tostring(a.status.get()))
    end},
    {"a view saved while it waits for a plan resumes waiting after a reload", function()
        local valid = function(src) return type(src) == "table" and type(src.path) == "string" end
        local waiting = { discover_pid = 4242, discovery_label = "Local · host" }
        local saved = selection.saveState(waiting)
        assert(saved.schema == 2 and saved.discover_pid == 4242 and saved.label == "Local · host")
        local restored = selection.restoreState(saved, valid)
        assert(selection.hasWork(restored), "a reloaded waiting view has nothing to read")
        assert(restored.discover_pid == 4242 and restored.discovery_label == "Local · host" and restored.source == nil)
        -- the old behaviour: nothing saved, nothing to read, and the window still believes the view serves the session
        assert(not selection.hasWork(selection.restoreState({ schema = 2 }, valid)))
        -- a plan found later saves its source, which wins over the waiting record
        local found = selection.restoreState(selection.saveState({ source = { path = "/p.md" }, plan_id = "plan-abc", discover_pid = 4242 }), valid)
        assert(found.source and found.plan_id == "plan-abc" and found.discover_pid == nil)
        for _, bad in { { schema = 2, discover_pid = -1 }, { schema = 2, discover_pid = 1.5 }, { schema = 2, discover_pid = "9" },
            { schema = 2, discover_pid = 5, label = 7 }, { schema = 1, discover_pid = 5 } } do
            assert(not selection.hasWork(selection.restoreState(bad, valid)), "an unusable save must restore nothing")
        end
    end},
    {"another window moving the shared attachment never leaves this window showing the old session's board", function()
        local kv = sharedKv()
        change(kv, "glitch", "on"); change(kv, "sync", "on"); change(kv, "attach", "1")
        local a = newMemo()
        a.record(1, "Plan X", "/boards/x.md")
        local shown = pane(kv, a)
        assert(shown:find("Board: Plan X", 1, true) and shown:find("Open board", 1, true))
        change(kv, "attach", "2") -- window B attaches session 2, which has no plan yet
        local after = pane(kv, a)
        assert(not after:find("Plan X", 1, true) and not after:find("Open board", 1, true), after)
        assert(a.boardFor(settings.load(kv)) == nil)
        change(kv, "attach", "1") -- back to session 1: its board is shown again only after this window syncs it again
        assert(not pane(kv, a):find("Open board", 1, true))
        a.record(1, "Plan X", "/boards/x.md")
        assert(pane(kv, a):find("Board: Plan X", 1, true))
    end},
    {"a closed attachment forgets the board, and sync turned off hides it", function()
        local kv = sharedKv()
        change(kv, "glitch", "on"); change(kv, "sync", "on"); change(kv, "attach", "1")
        local a = newMemo()
        a.record(1, "Plan X", "/boards/x.md")
        a.observe(settings.load(kv), nil) -- the attached session closed
        assert(a.boardFor(settings.load(kv)) == nil)
        a.record(1, "Plan X", "/boards/x.md")
        change(kv, "sync", "off")
        assert(a.boardFor(settings.load(kv)) == nil)
    end},
    {"an unpublished session with sync On keeps its plan view waiting and syncs once the plan is published", function()
        local kv = sharedKv()
        change(kv, "glitch", "on"); change(kv, "sync", "on"); change(kv, "attach", "1")
        kv.set("target/77", 1) -- the window bound view panel 77 to session 1
        local none = { ok = true, state = "none" }
        local function patient() return settings.waitsForPublication(settings.load(kv), kv.get("target/77")) end
        assert(patient())
        for _ = 1, 5 do
            local step = selection.discoveryStep(0, true, none, patient())
            assert(step.action == "wait" and step.message:find("keeps looking", 1, true), step.action)
        end
        local published = { ok = true, state = "active", source = { path = "/p.md", plan_id = "plan-abc", publication = { k = 1 } } }
        local step = selection.discoveryStep(0, true, published, patient())
        assert(step.action == "active" and step.source.plan_id == "plan-abc")
    end},
    {"a plan view that is not the sync target still closes with the notice", function()
        local kv = sharedKv()
        change(kv, "glitch", "on"); change(kv, "attach", "1") -- sync Off
        kv.set("target/77", 1)
        local none = { ok = true, state = "none" }
        assert(selection.discoveryStep(0, true, none, settings.waitsForPublication(settings.load(kv), kv.get("target/77"))).action == "none")
        change(kv, "sync", "on")
        assert(settings.waitsForPublication(settings.load(kv), kv.get("target/77")))
        assert(not settings.waitsForPublication(settings.load(kv), 2), "a view for another session must not wait")
        assert(not settings.waitsForPublication(settings.load(kv), nil))
        change(kv, "sync", "off") -- sync turned off while waiting: the next answer closes the view
        assert(selection.discoveryStep(0, true, none, settings.waitsForPublication(settings.load(kv), 1)).action == "none")
    end},
    {"the missing-view blocker tells the owner what to do", function()
        local s = { glitch = true, sync = true, board = true, attach = 1 }
        local msg = settings.syncBlocker(s, cand(1, false), "none", false)
        assert(msg:find("Pick the session again under Attach to", 1, true), msg)
    end},
}
